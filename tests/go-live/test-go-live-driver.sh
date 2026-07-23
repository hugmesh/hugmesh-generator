#!/usr/bin/env bash
# test-go-live-driver.sh — offline logic test for the go-live wizard foundation:
# the shared driver (specs/usr/sbin/hugmesh-go-live) + the provider registry
# (specs/usr/lib/hugmesh/go-live-providers.sh), exercised end-to-end by the
# one fully-implemented provider (byo-domain).
#
# Runs ANYWHERE with just bash — NO root, NO network, NO live /etc. It points the
# driver's GL_ETC_HUGMESH seam at a throwaway dir so it can never touch the
# host's /etc/hugmesh, mirroring how the reconcile tests use DR_*/*_ENV seams.
# named-checkzone is used ONLY if present (else a grep-based zone sanity check).
#
# Asserts the wizard's contract:
#   (a) status/list reflect the baked context + the provider catalogue.
#   (b) plan is a DRY-RUN: byo-domain emits its 5 artifacts, and the marker is
#       NEVER written by plan.
#   (c) the emitted BIND zone is well-formed (SOA+NS+A) and the CSV/record set
#       carry the ingress IP.
#   (d) FAIL-SAFE: commit on a non-TTY WITHOUT --yes refuses and writes nothing.
#   (e) commit --yes writes the marker (effective posture -> public).
#   (f) --persist-public also bakes release-state=public.
#   (g) rollback removes the marker; --revert-release-state restores internal.
#   (h) a stub provider still emits its marked STUB placeholder.
#   (i) tunnel-cname mode yields CNAMEs for sub-labels + an ALIAS-annotated apex.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="${REPO}/specs/usr/sbin/hugmesh-go-live"
LIB="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"

[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
[ -r "${LIB}" ]    || { echo "  FAIL registry lib missing: ${LIB}"; exit 1; }
command -v bash >/dev/null || { echo "SKIP: need bash"; exit 0; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

ETC="${WORK}/etc"; OUT="${WORK}/out"
mkdir -p "${ETC}" "${OUT}"
DOMAIN="example.com"
printf '%s\n' "${DOMAIN}" > "${ETC}/cluster-domain"
printf 'internal\n'       > "${ETC}/release-state"
MARKER="${ETC}/go-live"

# Always invoke the driver with the seams pointing at the throwaway tree, stdin
# from /dev/null so the "non-TTY" fail-safe path is exercised by default.
gl() { GL_ETC_HUGMESH="${ETC}" GL_PROVIDERS_LIB="${LIB}" bash "${DRIVER}" "$@" </dev/null 2>&1; }

echo "== go-live wizard foundation: offline driver + byo-domain emit test =="

# (a) status + list ------------------------------------------------------------
out="$(gl status)"
echo "${out}" | grep -q "release-state:       internal" && echo "${out}" | grep -q "go-live marker:      absent" \
    && ok "status reflects internal + no marker" || { bad "status wrong"; echo "${out}"; }
echo "${out}" | grep -q "effective posture:   internal" && ok "effective posture internal by default" || bad "effective posture not internal"

out="$(gl list)"
echo "${out}" | grep -qE '^byo-domain .* full ' && ok "list marks byo-domain full" || { bad "byo-domain not full in list"; echo "${out}"; }
# After the consolidation every provider is fully implemented — none list as stub.
echo "${out}" | grep -qE '^cloudflare-tunnel .* full ' && ok "list marks cloudflare-tunnel full" || { bad "cloudflare-tunnel not full"; echo "${out}"; }
echo "${out}" | grep -q ' stub ' && bad "a provider still lists as stub after consolidation" || ok "no provider lists as stub"
for want in duckdns tailscale-funnel router-portforward; do
    echo "${out}" | grep -qE "^${want} .* full " && ok "list includes ${want} (full)" || bad "list missing/!full ${want}"
done

# (b) plan is a DRY-RUN: emits artifacts, NEVER writes the marker ---------------
gl plan --provider byo-domain --ingress-ip 203.0.113.10 --out-dir "${OUT}" >/dev/null
for f in records.txt records.csv "${DOMAIN}.zone" deeplinks.txt instructions.txt; do
    [ -s "${OUT}/${f}" ] && ok "plan emitted ${f}" || bad "plan did NOT emit ${f}"
done
[ ! -e "${MARKER}" ] && ok "plan did NOT write the go-live marker (dry-run)" || bad "plan WROTE the marker — dry-run violated!"

# (c) zone + csv + record-set content -----------------------------------------
zone="${OUT}/${DOMAIN}.zone"
grep -q "IN[[:space:]]*SOA" "${zone}" && grep -q "IN[[:space:]]*NS" "${zone}" \
    && grep -qE "^@[[:space:]]+IN[[:space:]]+A[[:space:]]+203\.0\.113\.10" "${zone}" \
    && ok "zone has SOA + NS + apex A" || { bad "zone malformed"; cat "${zone}"; }
grep -qE "^api[[:space:]]+IN[[:space:]]+A[[:space:]]+203\.0\.113\.10" "${zone}" && ok "zone has api A record" || bad "zone missing api A"
if command -v named-checkzone >/dev/null 2>&1; then
    if named-checkzone "${DOMAIN}" "${zone}" >/dev/null 2>&1; then ok "named-checkzone accepts the zone"; else bad "named-checkzone rejected the zone"; named-checkzone "${DOMAIN}" "${zone}"; fi
else
    ok "named-checkzone absent — grep-based zone sanity only (SKIP strict parse)"
fi
head -1 "${OUT}/records.csv" | grep -qx 'name,type,value,ttl,proxied' && ok "csv header correct" || bad "csv header wrong"
grep -q ',A,203.0.113.10,300,false' "${OUT}/records.csv" && ok "csv carries the ingress IP row" || bad "csv missing ingress row"
grep -q '203.0.113.10' "${OUT}/records.txt" && ok "record set carries the ingress IP" || bad "record set missing ingress IP"
# The 4 promised hostnames (apex + api/matrix/mastodon).
for h in "${DOMAIN}." "api.${DOMAIN}." "matrix.${DOMAIN}." "mastodon.${DOMAIN}."; do
    grep -q "^${h//./\\.}" "${OUT}/records.txt" && ok "record set has ${h}" || bad "record set missing ${h}"
done

# (d) FAIL-SAFE: commit on a non-TTY WITHOUT --yes refuses + writes nothing -----
out="$(gl commit --provider byo-domain)"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -e "${MARKER}" ] && ok "commit without --yes on non-TTY refused (fail-safe), no marker" \
    || { bad "commit without --yes did NOT fail-safe (rc=${rc}, marker exists=$([ -e "${MARKER}" ] && echo y || echo n))"; echo "${out}"; }

# (e) commit --yes writes the marker; effective posture -> public --------------
gl commit --provider byo-domain --yes >/dev/null
[ -e "${MARKER}" ] && ok "commit --yes wrote the go-live marker" || bad "commit --yes did NOT write the marker"
gl status | grep -q "effective posture:   public" && ok "effective posture public after commit" || bad "effective posture not public after commit"
# release-state NOT persisted unless asked.
grep -qx 'internal' "${ETC}/release-state" && ok "commit left release-state=internal (marker-only)" || bad "commit unexpectedly changed release-state"

# (f) --persist-public bakes release-state=public ------------------------------
gl commit --provider byo-domain --yes --persist-public >/dev/null
grep -qx 'public' "${ETC}/release-state" && ok "--persist-public baked release-state=public" || bad "--persist-public did NOT persist"

# (g) rollback removes the marker; --revert-release-state restores internal ----
gl rollback --yes >/dev/null
[ ! -e "${MARKER}" ] && ok "rollback removed the marker" || bad "rollback did NOT remove the marker"
# release-state still public (persisted) -> still effectively public.
gl status | grep -q "effective posture:   public" && ok "still public after marker-only rollback (release-state persisted)" || bad "posture not public after marker-only rollback"
gl rollback --yes --revert-release-state >/dev/null
grep -qx 'internal' "${ETC}/release-state" && ok "--revert-release-state restored internal" || bad "--revert-release-state did NOT restore internal"
gl status | grep -q "effective posture:   internal" && ok "fully rolled back to internal" || bad "not internal after full rollback"

# (h) cloudflare-tunnel emits a real CNAME record set + token-drop guide --------
CFOUT="${WORK}/cfout"; mkdir -p "${CFOUT}"
gl plan --provider cloudflare-tunnel --tunnel-cname abc123.cfargotunnel.com --out-dir "${CFOUT}" >/dev/null
[ ! -e "${CFOUT}/STUB-cloudflare-tunnel.txt" ] && ok "cloudflare-tunnel no longer emits a STUB placeholder" || bad "cloudflare-tunnel still emits STUB"
grep -qx 'type,name,content,ttl,proxied' "${CFOUT}/records.csv" 2>/dev/null && ok "cloudflare-tunnel emits records.csv" || bad "cloudflare-tunnel records.csv missing/wrong"
grep -q "^CNAME,${DOMAIN},abc123\.cfargotunnel\.com,300,true" "${CFOUT}/records.csv" && ok "cloudflare-tunnel apex CNAME autofilled to the tunnel" || { bad "cloudflare-tunnel apex CNAME missing"; cat "${CFOUT}/records.csv"; }
grep -q "^CNAME,api\.${DOMAIN},abc123\.cfargotunnel\.com" "${CFOUT}/records.csv" && ok "cloudflare-tunnel api CNAME autofilled" || bad "cloudflare-tunnel api CNAME missing"
grep -q 'cloudflared/tunnel-token' "${CFOUT}/token-drop.txt" 2>/dev/null && ok "cloudflare-tunnel names the keys-layout token dest" || bad "cloudflare-tunnel token-drop guide missing"

# (h2) duckdns emits a REAL updater + cron; no token in argv; safe interpolation -
DDOUT="${WORK}/ddout"; mkdir -p "${DDOUT}"
gl plan --provider duckdns --ddns-subdomain myhome --out-dir "${DDOUT}" >/dev/null
[ -x "${DDOUT}/ddns-update.sh" ] && ok "duckdns emits an executable ddns-update.sh" || bad "duckdns updater missing/not executable"
[ -s "${DDOUT}/ddns.cron" ] && grep -q '\*/5 .* root /usr/local/sbin/hugmesh-ddns-update' "${DDOUT}/ddns.cron" && ok "duckdns emits the root cron drop-in" || bad "duckdns cron drop-in missing/wrong"
bash -n "${DDOUT}/ddns-update.sh" && ok "emitted ddns-update.sh parses (bash -n)" || bad "emitted ddns-update.sh has a syntax error"
grep -q "SUBDOMAIN=myhome" "${DDOUT}/ddns-update.sh" && ok "duckdns updater carries the validated subdomain" || bad "duckdns updater missing subdomain"
# The token is read from a keys-layout FILE at runtime, never embedded / in argv.
grep -q 'TOKEN_FILE=' "${DDOUT}/ddns-update.sh" && ! grep -qi 'token=[A-Za-z0-9]' "${DDOUT}/ddns-update.sh" \
    && ok "duckdns updater reads the token from a file (never embedded)" || bad "duckdns updater may embed a token"

# (h3) SECURITY regression guard: a non-label --ddns-subdomain is REJECTED and NO
# root cron updater is written (ported #286 command-injection fix).
EVILOUT="${WORK}/evilout"; mkdir -p "${EVILOUT}"
out="$(gl plan --provider duckdns --ddns-subdomain 'a$(touch pwned).b' --out-dir "${EVILOUT}")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -e "${EVILOUT}/ddns-update.sh" ] && [ ! -e "${WORK}/pwned" ] && [ ! -e "pwned" ] \
    && ok "malicious --ddns-subdomain rejected; no updater written, no injection" \
    || { bad "malicious --ddns-subdomain NOT rejected safely (rc=${rc})"; echo "${out}"; }
rm -f pwned "${WORK}/pwned" 2>/dev/null

# (h3b) SECURITY regression guard: --keys-dir feeds the DDNS TOKEN_FILE path baked
# into the emitted ROOT-cron updater. A command-substitution payload must be (1)
# rejected at the driver door AND (2) even if the emit fn is reached directly,
# %q-quoted so the updater treats it as a literal path and never executes it.
KDIR_PWN="${WORK}/keysdir-pwned"; rm -f "${KDIR_PWN}"
# (1) driver door: hostile --keys-dir rejected, no updater, no injection.
KEVIL="${WORK}/kevil"; mkdir -p "${KEVIL}"
out="$(gl plan --provider duckdns --ddns-subdomain myhome --keys-dir "\$(touch ${KDIR_PWN})" --out-dir "${KEVIL}")"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -e "${KEVIL}/ddns-update.sh" ] && [ ! -e "${KDIR_PWN}" ] \
    && ok "malicious --keys-dir rejected at the driver door; no updater, no injection" \
    || { bad "malicious --keys-dir NOT rejected safely (rc=${rc})"; echo "${out}"; }
# (2) emit-level %q defense: bypass the door, drive glp_emit_duckdns directly with a
# hostile GL_KEYS_DIR, run the emitted updater as the root cron would — it must NOT fire.
KEMIT="${WORK}/kemit"; mkdir -p "${KEMIT}"
( set +e
  # shellcheck source=/dev/null
  . "${LIB}"
  GL_DDNS_SERVICE=duckdns GL_DDNS_SUBDOMAIN=myhome GL_DOMAIN="${DOMAIN}" \
    GL_KEYS_DIR="\$(touch ${KDIR_PWN})" glp_emit_duckdns "${KEMIT}" >/dev/null 2>&1
  DDNS_TOKEN_FILE= bash "${KEMIT}/ddns-update.sh" >/dev/null 2>&1
)
[ ! -e "${KDIR_PWN}" ] \
    && ok "emitted updater treats a hostile --keys-dir as a literal path (%q defense, no injection)" \
    || bad "emit-level %q defense FAILED: hostile --keys-dir executed as root-cron would"
rm -f "${KDIR_PWN}" 2>/dev/null

# (h4) tailscale-funnel / router-portforward emit guidance, NO DNS record set ----
for prov in tailscale-funnel router-portforward; do
    POUT="${WORK}/pout-${prov}"; mkdir -p "${POUT}"
    gl plan --provider "${prov}" --out-dir "${POUT}" >/dev/null
    [ -s "${POUT}/instructions.txt" ] && [ -s "${POUT}/deeplinks.txt" ] && [ ! -e "${POUT}/records.csv" ] \
        && ok "${prov} emits guidance + deep-links, no DNS record set" || bad "${prov} emit wrong"
done

# (i) tunnel-cname mode: sub-labels get CNAME, apex annotated ALIAS ------------
CNOUT="${WORK}/cnout"; mkdir -p "${CNOUT}"
gl plan --provider byo-domain --tunnel-cname edge.tunnel.example.net --out-dir "${CNOUT}" >/dev/null
grep -qE "^api[[:space:]]+IN[[:space:]]+CNAME[[:space:]]+edge\.tunnel\.example\.net" "${CNOUT}/${DOMAIN}.zone" \
    && ok "tunnel-cname: sub-label emits CNAME" || { bad "tunnel-cname: no CNAME"; cat "${CNOUT}/${DOMAIN}.zone"; }
grep -qi 'ALIAS' "${CNOUT}/${DOMAIN}.zone" && ok "tunnel-cname: apex annotated ALIAS (apex CNAME illegal)" || bad "tunnel-cname: apex not ALIAS-annotated"

# (j) unknown provider is rejected --------------------------------------------
gl plan --provider not-a-provider --out-dir "${WORK}/x" >/dev/null 2>&1 && bad "unknown provider was accepted" || ok "unknown provider rejected"

echo
echo "== go-live wizard test: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
