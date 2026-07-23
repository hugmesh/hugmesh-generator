#!/usr/bin/env bash
# e2e-headwind-entrypoint.sh — offline end-to-end test of the DERIVED Headwind
# entrypoint (specs/cluster/manifests/headwind/docker/docker-entrypoint.sh)
# against the REAL vendored templates. Until now its escaping/render/wait/exec
# behavior was proven only by a one-off manual `docker build` + smoke run; this
# makes that proof a repeatable CI gate — no docker, no network, no root.
#
# What runs REAL: the entrypoint script itself (only its two absolute path
# constants are re-pointed into a sandbox, with a drift guard proving the
# constants still exist verbatim first), the vendored context/init.sql/log4j/
# email templates, the sed render pipeline with its three escaping layers
# (esc/xml/sql), umask 0600 handling, the psql wait loop, and the final
# `exec "$@"`. Stubbed via PATH shims: psql (fails twice, then succeeds;
# records argv + PGPASSWORD env separately) and sleep (no-op, so the wait loop
# is fast). The Tomcat CMD is a stub that records its argv AND its own PID —
# PID equality with the launched process proves exec (PID-1 signal handling),
# not a child spawn.
#
# The XML oracle is python3's strict XML parser standing in for Tomcat's: the
# rendered ROOT.xml must PARSE and the decoded JDBC.password attribute must
# round-trip the hostile original byte-for-byte. A negative control proves the
# oracle rejects a raw-spliced (unescaped) fixture, so a green parse means
# something.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EP="${REPO}/specs/cluster/manifests/headwind/docker/docker-entrypoint.sh"
TPL="${REPO}/specs/cluster/manifests/headwind/docker/templates"
[ -f "${EP}" ]  || { echo "  FAIL entrypoint missing: ${EP}"; exit 1; }
[ -d "${TPL}" ] || { echo "  FAIL vendored templates missing: ${TPL}"; exit 1; }
for t in python3 sed; do command -v "${t}" >/dev/null || { echo "SKIP: need ${t}"; exit 0; }; done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT

echo "== headwind docker-entrypoint.sh: offline e2e =="

# ── sandbox: re-point ONLY the two path constants (drift-guarded) ──────────────
grep -q '^HMDM_DIR=/opt/hmdm$' "${EP}" && grep -q '^TOMCAT_DIR=/usr/local/tomcat$' "${EP}" \
    || { echo "  FAIL path-constant drift: HMDM_DIR/TOMCAT_DIR lines changed — update this test deliberately"; exit 1; }
mkdir -p "${SB}/opt/hmdm" "${SB}/usr/local/tomcat" "${SB}/bin"
cp -r "${TPL}" "${SB}/opt/hmdm/templates"
sed -e "s|^HMDM_DIR=/opt/hmdm$|HMDM_DIR=${SB}/opt/hmdm|" \
    -e "s|^TOMCAT_DIR=/usr/local/tomcat$|TOMCAT_DIR=${SB}/usr/local/tomcat|" \
    "${EP}" > "${SB}/entrypoint.sh"
chmod +x "${SB}/entrypoint.sh"

# ── PATH shims ────────────────────────────────────────────────────────────────
# psql: exits 1 on the first two calls (exercising the wait loop), then 0.
# Records argv and the PGPASSWORD env value in SEPARATE files so the test can
# prove the password travels ONLY via env, never argv.
cat > "${SB}/bin/psql" <<STUB
#!/bin/sh
echo "\$@" >> "${SB}/psql.argv"
printf '%s\n' "\${PGPASSWORD:-UNSET}" >> "${SB}/psql.env"
N=\$(wc -l < "${SB}/psql.argv")
[ "\$N" -ge 3 ] && exit 0
exit 1
STUB
cat > "${SB}/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
# catalina stub: records argv + its own PID (exec proof).
cat > "${SB}/bin/catalina-stub" <<STUB
#!/bin/sh
echo "\$\$" > "${SB}/cmd.pid"
echo "\$@" > "${SB}/cmd.argv"
exit 0
STUB
chmod +x "${SB}/bin/psql" "${SB}/bin/sleep" "${SB}/bin/catalina-stub"

# Hostile-but-legal single-line values: sed-replacement metachars (\ & |), XML
# metachars (< > ' "), an SQL quote, spaces. (Newlines are out of contract —
# upstream's sed render never supported them.)
HOSTILE_PASS='p@ss|w&r<d>'\''"\5 end'
run_ep() {  # run_ep [extra VAR=VAL...] -- cmd...
    env PATH="${SB}/bin:${PATH}" \
        SQL_HOST=headwind-db.example SQL_PORT=5432 SQL_BASE=headwind SQL_USER=headwind \
        SQL_PASS="${HOSTILE_PASS}" PROTOCOL=http BASE_DOMAIN=superadmin.hugmesh.systems \
        ADMIN_EMAIL="o'brien&co@example.com" "$@"
}

# ── (a) full run: render + wait + exec ────────────────────────────────────────
# `exec env` collapses the background subshell into the env->sh->CMD chain so
# $! IS the entrypoint's PID — that makes the (f1) exec proof exact.
( exec env PATH="${SB}/bin:${PATH}" \
      SQL_HOST=headwind-db.example SQL_PORT=5432 SQL_BASE=headwind SQL_USER=headwind \
      SQL_PASS="${HOSTILE_PASS}" PROTOCOL=http BASE_DOMAIN=superadmin.hugmesh.systems \
      ADMIN_EMAIL="o'brien&co@example.com" \
      "${SB}/entrypoint.sh" "${SB}/bin/catalina-stub" run > "${SB}/run1.log" 2>&1 ) &
EP_PID=$!
wait "${EP_PID}"; RC=$?
ROOT_XML="${SB}/usr/local/tomcat/conf/Catalina/localhost/ROOT.xml"
INIT_SQL="${SB}/usr/local/tomcat/work/init.sql"
[ "${RC}" -eq 0 ] && ok "(a) entrypoint exits 0" || bad "(a) entrypoint rc=${RC}: $(tail -3 "${SB}/run1.log")"

# ── (b) ROOT.xml: exists, 0600, strict-XML-parses, password round-trips ───────
if [ -f "${ROOT_XML}" ]; then
    MODE="$(stat -c '%a' "${ROOT_XML}" 2>/dev/null || stat -f '%Lp' "${ROOT_XML}")"
    [ "${MODE}" = "600" ] && ok "(b1) ROOT.xml is 0600 (holds SQL_PASS)" || bad "(b1) ROOT.xml mode ${MODE}, want 600"
    ROUND="$(python3 - "${ROOT_XML}" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()          # strict parse == Tomcat's bar
vals = {p.get("name"): p.get("value") for p in root.iter("Parameter")}
print(vals.get("JDBC.password", "<missing>"))
print(vals.get("JDBC.url", "<missing>"))
print(vals.get("base.url", "<missing>"))
PY
)" && XMLRC=0 || XMLRC=1
    if [ "${XMLRC}" -eq 0 ]; then
        ok "(b2) ROOT.xml parses as strict XML"
        GOT_PASS="$(printf '%s\n' "${ROUND}" | sed -n 1p)"
        GOT_URL="$(printf '%s\n' "${ROUND}" | sed -n 2p)"
        GOT_BASE="$(printf '%s\n' "${ROUND}" | sed -n 3p)"
        [ "${GOT_PASS}" = "${HOSTILE_PASS}" ] \
            && ok "(b3) JDBC.password round-trips the hostile value byte-for-byte" \
            || bad "(b3) password mangled: got '${GOT_PASS}' want '${HOSTILE_PASS}'"
        [ "${GOT_URL}" = "jdbc:postgresql://headwind-db.example:5432/headwind" ] \
            && ok "(b4) JDBC.url assembled from SQL_HOST/PORT/BASE" || bad "(b4) JDBC.url: ${GOT_URL}"
        [ "${GOT_BASE}" = "http://superadmin.hugmesh.systems" ] \
            && ok "(b5) base.url = PROTOCOL://BASE_DOMAIN" || bad "(b5) base.url: ${GOT_BASE}"
    else
        bad "(b2) ROOT.xml is NOT well-formed XML (Tomcat would refuse the context)"
    fi
    grep -q '_SQL_PASS_\|_SHARED_SECRET_\|_BASE_DOMAIN_' "${ROOT_XML}" \
        && bad "(b6) unsubstituted placeholders remain in ROOT.xml" \
        || ok "(b6) no unsubstituted placeholders in ROOT.xml"
else
    bad "(b) ROOT.xml was not rendered"
fi

# ── (c) negative control: the XML oracle rejects a RAW splice ─────────────────
# Hand-build what the render WOULD produce without the xml() layer; the parser
# must refuse it — otherwise (b2)/(b3) prove nothing.
printf '<Context><Parameter name="JDBC.password" value="%s"/></Context>' "${HOSTILE_PASS}" > "${SB}/raw.xml"
if python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "${SB}/raw.xml" 2>/dev/null; then
    bad "(c) oracle accepted a raw-spliced attribute — control is vacuous"
else
    ok "(c) negative control fires: raw (unescaped) splice is rejected by the parser"
fi

# ── (d) init.sql: SQL-quote doubling + URL rewrite + placeholder sweep ────────
if [ -f "${INIT_SQL}" ]; then
    grep -q "o''brien&co@example.com" "${INIT_SQL}" \
        && ok "(d1) ADMIN_EMAIL quote is doubled for the SQL literal" \
        || bad "(d1) ADMIN_EMAIL not quote-doubled"
    grep -q 'h-mdm\.com' "${INIT_SQL}" \
        && bad "(d2) upstream h-mdm.com URLs remain in init.sql" \
        || ok "(d2) zero h-mdm.com URLs remain (rewritten onto our base URL)"
    grep -q 'http://superadmin\.hugmesh\.systems' "${INIT_SQL}" \
        && ok "(d3) catalog URLs rewritten onto PROTOCOL://BASE_DOMAIN" \
        || bad "(d3) rewritten base URL absent from init.sql"
    grep -q '_ADMIN_EMAIL_\|_HMDM_VERSION_\|_HMDM_VARIANT_' "${INIT_SQL}" \
        && bad "(d4) unsubstituted placeholders remain in init.sql" \
        || ok "(d4) no unsubstituted placeholders in init.sql"
else
    bad "(d) init.sql was not rendered"
fi

# ── (e) wait loop + secret custody ────────────────────────────────────────────
WAITS="$(grep -c 'Waiting for the PostgreSQL database' "${SB}/run1.log" || true)"
[ "${WAITS}" -eq 2 ] && ok "(e1) psql wait loop retried exactly twice before success" \
                     || bad "(e1) expected 2 wait lines, got ${WAITS}"
if grep -qF "${HOSTILE_PASS}" "${SB}/psql.argv"; then
    bad "(e2) SQL_PASS leaked onto psql argv"
else
    ok "(e2) SQL_PASS never on psql argv"
fi
LAST_ENV="$(tail -1 "${SB}/psql.env")"
[ "${LAST_ENV}" = "${HOSTILE_PASS}" ] && ok "(e3) SQL_PASS reached psql via PGPASSWORD env" \
                                      || bad "(e3) PGPASSWORD not delivered (got '${LAST_ENV}')"

# ── (f) exec proof + CMD passthrough ──────────────────────────────────────────
if [ -f "${SB}/cmd.pid" ] && [ "$(cat "${SB}/cmd.pid")" = "${EP_PID}" ]; then
    ok "(f1) CMD runs via exec (same PID as the entrypoint — PID-1 signals intact)"
else
    bad "(f1) CMD PID $(cat "${SB}/cmd.pid" 2>/dev/null) != entrypoint PID ${EP_PID} (not exec'd)"
fi
[ "$(cat "${SB}/cmd.argv" 2>/dev/null)" = "run" ] && ok "(f2) CMD argv passed through" \
                                                  || bad "(f2) CMD argv mangled"

# ── (g) idempotence + FORCE_RECONFIGURE ───────────────────────────────────────
echo "<!-- marker -->" >> "${ROOT_XML}"
run_ep "${SB}/entrypoint.sh" "${SB}/bin/catalina-stub" run >/dev/null 2>&1
grep -q 'marker' "${ROOT_XML}" && ok "(g1) second run leaves an existing ROOT.xml untouched" \
                               || bad "(g1) second run rewrote ROOT.xml (should be idempotent)"
run_ep env FORCE_RECONFIGURE=true "${SB}/entrypoint.sh" "${SB}/bin/catalina-stub" run >/dev/null 2>&1
grep -q 'marker' "${ROOT_XML}" && bad "(g2) FORCE_RECONFIGURE=true did not re-render ROOT.xml" \
                               || ok "(g2) FORCE_RECONFIGURE=true re-renders ROOT.xml"

# ── (h) fail-closed on missing required env (set -u) ──────────────────────────
SB2="$(mktemp -d)"
mkdir -p "${SB2}/opt/hmdm" "${SB2}/usr/local/tomcat"
cp -r "${TPL}" "${SB2}/opt/hmdm/templates"
sed -e "s|^HMDM_DIR=/opt/hmdm$|HMDM_DIR=${SB2}/opt/hmdm|" \
    -e "s|^TOMCAT_DIR=/usr/local/tomcat$|TOMCAT_DIR=${SB2}/usr/local/tomcat|" \
    "${EP}" > "${SB2}/entrypoint.sh"
chmod +x "${SB2}/entrypoint.sh"
if env PATH="${SB}/bin:${PATH}" SQL_PORT=5432 SQL_BASE=h SQL_USER=h SQL_PASS=p \
       PROTOCOL=http BASE_DOMAIN=d ADMIN_EMAIL=a@b \
       "${SB2}/entrypoint.sh" "${SB}/bin/catalina-stub" run > "${SB2}/h.log" 2>&1; then
    bad "(h) missing SQL_HOST did not fail"
else
    # The failure must be the deliberate up-front validation, not an incidental
    # set -u abort AFTER an empty-host ROOT.xml was already written (the bug
    # this test originally caught: an unset var inside a $() render kills only
    # the subshell, and the outer sed still writes a complete-looking config
    # that the [ ! -f ] idempotence guard then pins across restarts).
    if [ -f "${SB2}/usr/local/tomcat/conf/Catalina/localhost/ROOT.xml" ]; then
        bad "(h1) a broken ROOT.xml was left behind on failure"
    else
        ok "(h1) missing SQL_HOST fails closed with no partial ROOT.xml"
    fi
    grep -q 'required env SQL_HOST' "${SB2}/h.log" \
        && ok "(h2) failure names the missing variable" \
        || bad "(h2) no deliberate validation error in output: $(head -2 "${SB2}/h.log")"
fi
rm -rf "${SB2}"

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
