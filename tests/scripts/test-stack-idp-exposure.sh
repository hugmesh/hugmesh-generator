#!/usr/bin/env bash
# test-stack-idp-exposure.sh — the local mesh's identity provider is not a LAN door,
# and its admin is not left on Casdoor's factory-default password (NEW-15).
#
# THE DEFECT. `make stack-up` (and the Studio's local mesh, which runs it) published
# Casdoor :8000, tuwunel :8008 and Mastodon :3000/:4000 on EVERY host interface
# (tests/stack/compose.real.yaml, included by compose.local.yaml), and nothing ever
# changed the password casbin/casdoor gives its built-in admin on an empty database:
# tests/stack/seed-e2e.sh and derive-games-admin.sh DEFAULTED to it. Any machine on
# the LAN could sign in to the mesh's identity provider as its admin (create admins,
# rewrite applications, write user properties).
#
# Proves, with bash + python3 stdlib + curl + jq, no docker and no network (the
# Casdoor here is tests/scripts/casdoor_stub.py on 127.0.0.1):
#   (1) every port tests/stack/compose*.yaml publishes, and the Studio's generated
#       own-Casdoor overlay, names a host IP that defaults to loopback, except the
#       front doors (compose_published_ports.py DOORS, each with a reason, none an
#       identity provider); the IdP/homeserver publishes spell STACK_BIND_ADDR, the
#       documented opt-in; not vacuous;
#   (2) negative and positive controls for that scanner, incl. a stale door entry;
#   (3) a host IP removed from, or a 0.0.0.0 default put into, a COPY of the real
#       compose.real.yaml turns (1) red;
#   (4) no script, Makefile or Python file defaults the Casdoor admin password to a
#       literal (${CASDOOR_ADMIN_PASS:-x}, :=x, environ.get(..., "x")); controls;
#   (5) tests/stack/gen-casdoor-admin-env.sh: mints 48 hex once, 0600, keeps it, keeps
#       other lines, --read never writes, a symlinked file stays a symlink, a
#       factory-default or unsafe value in the file is refused;
#   (6) seed-e2e.sh's casdoor_admin_session(), LIFTED from the real file and run
#       against the stub: a factory-fresh admin is moved onto the generated value and
#       the default is PROVEN refused; a seeded one costs one login and no write; an
#       unknown one stops with no write; the throttle stops it as a lockout; a
#       set-password that does not persist or is denied stops it, and so does a
#       login that answers ok but yields no admin session;
#   (7) the real seed-e2e.sh refuses an exported factory default before any network
#       call, and its default resolution writes only CASDOOR_ADMIN_ENV_FILE;
#   (8) derive-games-admin.sh reads the generated value, never mints one, and its
#       --fixture mode needs none.
# No password value is ever printed by the code under test; (9) sweeps the output.
# shellcheck disable=SC2015  # A && ok || bad is the assertion idiom this repo's guards use.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCAN="${HERE}/compose_published_ports.py"
STUB="${HERE}/casdoor_stub.py"
STACK="${REPO}/tests/stack"
GEN="${STACK}/gen-casdoor-admin-env.sh"
SEED="${STACK}/seed-e2e.sh"
DERIVE="${STACK}/derive-games-admin.sh"

P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

for t in bash python3 curl jq timeout sha256sum; do
  command -v "${t}" >/dev/null 2>&1 || { echo "  FAIL ${t} is required (refusing to skip)"; exit 2; }
done
for f in "${SCAN}" "${STUB}" "${GEN}" "${SEED}" "${DERIVE}"; do
  [ -r "${f}" ] || { echo "  FAIL ${f} is missing"; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-stack-idp-exposure.XXXXXX")"
STUB_PID=""
stub_down() { if [ -n "${STUB_PID}" ]; then kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; STUB_PID=""; fi; }
trap 'stub_down; rm -rf "${WORK}"' EXIT
ALLOUT="${WORK}/all-output.log"; : > "${ALLOUT}"

# The real checkout's tests/stack/.env must be exactly as it was when we are done.
REAL_ENV="${STACK}/.env"
env_fingerprint() { if [ -e "${REAL_ENV}" ]; then sha256sum "${REAL_ENV}" | cut -d' ' -f1; else echo absent; fi; }
REAL_ENV_BEFORE="$(env_fingerprint)"

echo "== NEW-15: the local mesh's identity provider is loopback-only and not on its factory admin password =="

# ═════ 1) the real tree ══════════════════════════════════════════════════════
echo "-- 1) every published port names a loopback-default host IP --"
shopt -s nullglob
files=("${STACK}"/compose*.yaml)
shopt -u nullglob
[ "${#files[@]}" -ge 10 ] && ok "${#files[@]} compose files found by the glob" \
  || bad "only ${#files[@]} compose files found (expected >= 10)"
# The Studio's own-Casdoor overlay is generated, never committed: render it for two
# domains from the REAL module (stdlib only) so its template is checked too.
OVERLAY="${WORK}/compose.own-domains.yaml"
if (cd "${REPO}/studio" && python3 -I -c '
import sys
sys.path.insert(0, ".")
from hugmesh_studio.core import own_casdoor
sys.stdout.write(own_casdoor.compose_overlay(("acme.example", "team.acme.example")))
') > "${OVERLAY}" 2>"${WORK}/overlay.err" && [ -s "${OVERLAY}" ]; then
  ok "rendered the Studio's own-Casdoor overlay from studio/hugmesh_studio/core/own_casdoor.py"
else
  bad "could not render the own-Casdoor overlay: $(head -3 "${WORK}/overlay.err")"
fi
args=()
for f in "${files[@]}"; do args+=("${f}=${f#"${REPO}/"}"); done
out="$(python3 "${SCAN}" --count "${args[@]}" "${OVERLAY}=studio-own-casdoor-overlay" 2>&1)"; rc=$?
summary="$(tail -1 <<<"${out}")"
if [ "${rc}" -eq 0 ]; then ok "no publish without a loopback-default host IP (${summary})"
else bad "publishes that bind every interface (rc=${rc}):"; sed 's/^/         /' <<<"${out}"; fi
published="$(sed -n 's/.*published=\([0-9]*\).*/\1/p' <<<"${summary}")"
idp="$(sed -n 's/.* idp=\([0-9]*\).*/\1/p' <<<"${summary}")"
# 2026-11-11: 11 committed publishes (7 of them identity provider / homeserver /
# social server) + 2 from the two-domain overlay.
[ "${published:-0}" -ge 12 ] && ok "vacuity floor: ${published} published ports read (>= 12)" \
  || bad "only ${published:-0} published ports read: the scanner is not seeing the files"
[ "${idp:-0}" -ge 9 ] && ok "vacuity floor: ${idp} identity-provider/homeserver publishes judged (>= 9)" \
  || bad "only ${idp:-0} identity-provider/homeserver publishes judged (casdoor, casdoor-brandb, 2 own-domain, tuwunel, mastodon-web/-streaming, akkoma, phpbb)"
stale="$(sed -n 's/.*doors_stale=\(.*\)$/\1/p' <<<"${summary}")"
[ -z "${stale}" ] && ok "every front-door exception still publishes (no stale entry)" \
  || bad "front-door exceptions that no longer occur: ${stale}"
# The opt-in is ONE documented knob, not whatever variable a file happens to use.
for spec in "compose.real.yaml:4" "compose.brand-b.yaml:1" "compose.alt-social.yaml:2"; do
  f="${spec%%:*}"; want="${spec##*:}"
  n="$(grep -c -F '${STACK_BIND_ADDR:-127.0.0.1}:' "${STACK}/${f}" || true)"
  [ "${n}" -ge "${want}" ] && ok "${f}: ${n} publish(es) on \${STACK_BIND_ADDR:-127.0.0.1} (>= ${want})" \
    || bad "${f}: ${n} publish(es) on \${STACK_BIND_ADDR:-127.0.0.1}, expected >= ${want}"
done
n="$(grep -c -F '${STACK_BIND_ADDR:-127.0.0.1}:' "${OVERLAY}" || true)"
[ "${n}" -eq 2 ] && ok "the own-Casdoor overlay publishes both domains on \${STACK_BIND_ADDR:-127.0.0.1}" \
  || bad "the own-Casdoor overlay has ${n} STACK_BIND_ADDR publish(es), expected 2"

# ═════ 2) scanner controls ═══════════════════════════════════════════════════
echo "-- 2) negative and positive controls for the port scanner --"
neg() { # neg <name> <compose-file-basename> <yaml body> <expected-fragment>
  mkdir -p "${WORK}/neg-$1"
  printf '%s\n' "$3" > "${WORK}/neg-$1/$2"
  local o r
  o="$(python3 "${SCAN}" "${WORK}/neg-$1/$2=$2" 2>&1)"; r=$?
  if [ "${r}" -eq 1 ] && grep -F -- "$4" <<<"${o}" >/dev/null; then ok "neg $1: reported"
  else bad "neg $1: NOT reported (rc=${r}): ${o:-<no output>}"; fi
}
neg bare-flow compose.x.yaml $'services:\n  casdoor:\n    image: casbin/casdoor:3.80.0\n    ports: ["8000:8000"]' 'casdoor: an identity provider'
neg bare-block compose.x.yaml $'services:\n  tuwunel:\n    image: ghcr.io/matrix-construct/tuwunel:v1.7.0\n    ports:\n      # a comment\n      - "8008:8008"' 'tuwunel: an identity provider'
neg container-only compose.x.yaml $'services:\n  web:\n    image: nginx\n    ports: ["80"]' "web: port '80' names no host IP"
neg no-default compose.x.yaml $'services:\n  casdoor:\n    image: casbin/casdoor\n    ports: ["${STACK_BIND_ADDR}:8000:8000"]' 'has no loopback default'
neg empty-default compose.x.yaml $'services:\n  casdoor:\n    image: casbin/casdoor\n    ports: ["${STACK_BIND_ADDR:-}:8000:8000"]' 'EMPTY default'
neg wild-default compose.x.yaml $'services:\n  casdoor:\n    image: casbin/casdoor\n    ports: ["${STACK_BIND_ADDR:-0.0.0.0}:8000:8000"]' 'defaults to 0.0.0.0, not loopback'
neg wild-literal compose.x.yaml $'services:\n  mastodon-web:\n    image: ghcr.io/mastodon/mastodon:v4.3.1\n    ports: ["0.0.0.0:3000:3000"]' 'is not loopback'
neg long-syntax compose.x.yaml $'services:\n  casdoor:\n    image: casbin/casdoor\n    ports:\n      - target: 8000\n        published: 8000' 'long-syntax port entry'
neg override-tag compose.x.yaml $'services:\n  akkoma:\n    image: x/akkoma:1\n    ports: !override ["4001:4000"]' 'akkoma: an identity provider'
neg idp-as-door compose.local.yaml $'services:\n  hugmesh-fe-gateway:\n    image: casbin/casdoor:3.80.0\n    ports: ["8088:8080"]' 'hugmesh-fe-gateway: an identity provider'
neg new-service compose.local.yaml $'services:\n  something-new:\n    image: busybox\n    ports: ["9999:9999"]' "something-new: port '9999:9999' names no host IP"
mkdir -p "${WORK}/pos"
cat > "${WORK}/pos/compose.local.yaml" <<'EOF'
services:
  casdoor:
    image: casbin/casdoor:3.80.0
    ports: ["${STACK_BIND_ADDR:-127.0.0.1}:8000:8000"]   # a trailing comment
  tuwunel:
    image: ghcr.io/matrix-construct/tuwunel:v1.7.0
    ports:
      - "127.0.0.1:8008:8008"
      - '[::1]:8448:8448'
  hugmesh-fe-gateway:
    image: x/gateway
    ports:
      - "${PUBLIC_HOST_PORT:-8088}:8080"
  hugmesh-https-front:
    ports: ["${PUBLIC_HTTPS_PORT:-8488}:8443"]
  hugmesh-anubis:
    ports: ["${ANUBIS_HOST_PORT:-8923}:8923"]
  tor:
    ports: ["127.0.0.1:${TOR_SOCKS_HOST_PORT:-9050}:9050"]
EOF
o="$(python3 "${SCAN}" --count "${WORK}/pos/compose.local.yaml=compose.local.yaml" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && grep -F 'published=7 ' <<<"${o}" >/dev/null && grep -F 'doors_stale=' <<<"${o}" | grep -E 'doors_stale=$' >/dev/null \
  && ok "pos: loopback literals, [::1], \${VAR:-127.0.0.1} and the three doors pass, all 7 counted" \
  || bad "pos: allowed shapes reported or miscounted (rc=${rc}): $(tr '\n' '|' <<<"${o}")"
printf 'services:\n  casdoor:\n    image: casbin/casdoor\n    ports: ["127.0.0.1:8000:8000"]\n' > "${WORK}/pos/compose.local.yaml"
o="$(python3 "${SCAN}" --count "${WORK}/pos/compose.local.yaml=compose.local.yaml" 2>&1)"
grep -F 'doors_stale=compose.local.yaml:hugmesh-anubis' <<<"${o}" >/dev/null \
  && ok "a door exception whose door is gone is reported stale" \
  || bad "stale door exceptions not reported: $(tail -1 <<<"${o}")"

# ═════ 3) the real files, broken on copies ═══════════════════════════════════
echo "-- 3) a host IP removed from, or 0.0.0.0 defaulted into, the REAL compose.real.yaml is caught --"
mut_port() { # mut_port <name> <old> <new> <expected-fragment>
  rm -rf "${WORK}/mut"; mkdir -p "${WORK}/mut"
  cp "${files[@]}" "${WORK}/mut/"
  OLD="$2" NEW="$3" python3 - "${WORK}/mut/compose.real.yaml" <<'PY' || { bad "mut $1: could not apply (the anchor is gone)"; return; }
import os, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old, new = os.environ["OLD"], os.environ["NEW"]
if s.count(old) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
  cmp -s "${STACK}/compose.real.yaml" "${WORK}/mut/compose.real.yaml" && { bad "mut $1: the copy did not change"; return; }
  local margs=() f o r
  for f in "${WORK}"/mut/compose*.yaml; do margs+=("${f}=tests/stack/$(basename "${f}")"); done
  o="$(python3 "${SCAN}" "${margs[@]}" 2>&1)"; r=$?
  [ "${r}" -eq 1 ] && grep -F -- "$4" <<<"${o}" >/dev/null && ok "mut $1: caught" \
    || bad "mut $1: NOT caught (rc=${r}): ${o:-<no output>}"
}
mut_port casdoor-bare 'ports: ["${STACK_BIND_ADDR:-127.0.0.1}:8000:8000"]' 'ports: ["8000:8000"]' 'compose.real.yaml'
mut_port casdoor-wild 'ports: ["${STACK_BIND_ADDR:-127.0.0.1}:8000:8000"]' 'ports: ["${STACK_BIND_ADDR:-0.0.0.0}:8000:8000"]' 'defaults to 0.0.0.0'
mut_port mastodon-bare 'ports: ["${STACK_BIND_ADDR:-127.0.0.1}:4000:4000"]' 'ports: ["4000:4000"]' 'mastodon-streaming'

# ═════ 4) no literal default for the Casdoor admin password ══════════════════
echo "-- 4) no script defaults the Casdoor admin password to a literal --"
cat > "${WORK}/literal_scan.py" <<'PY'
import re, sys
# Every ${CASDOOR_ADMIN_PASS<op>...} expansion is judged (counted as a ref); a finding
# is a DEFAULT (:- - := =) whose value is non-empty. :? / ? (required) never is.
SH = re.compile(r"\$\{(CASDOOR_ADMIN_PASS(?:WORD)?)(:?[-=?])([^}]*)\}")
# os.environ.get("CASDOOR_ADMIN_PASS", "x") / getenv(..., "x") with a non-empty x.
PY_RE = re.compile(r"""(?:get|getenv|setdefault)\(\s*["'](CASDOOR_ADMIN_PASS(?:WORD)?)["']\s*,\s*(["'])(.+?)\2""")
findings, refs = [], 0
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for n, line in enumerate(text.splitlines(), 1):
        for m in SH.finditer(line):
            refs += 1
            if not m.group(2).endswith("?") and m.group(3) != "":
                findings.append(f"{path}:{n}: {m.group(1)} defaults to a literal")
        for m in PY_RE.finditer(line):
            refs += 1
            findings.append(f"{path}:{n}: {m.group(1)} defaults to a literal")
print("\n".join(findings))
print(f"refs={refs} findings={len(findings)}")
sys.exit(1 if findings else 0)
PY
# This suite and its mutation battery spell the defect on purpose; nothing else may.
if git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t lfiles < <(git -C "${REPO}" ls-files -co --exclude-standard -- '*.sh' '*.bash' '*.py' '*.mk' 'Makefile' '*.ps1' \
                          | grep -v -F -e 'tests/scripts/test-stack-idp-exposure.sh' \
                              -e 'tests/scripts/stack_idp_exposure_mutations.sh' | sed "s|^|${REPO}/|")
else
  mapfile -t lfiles < <(find "${REPO}" -path "${REPO}/.git" -prune -o -path "${REPO}/.stack-src" -prune -o -type f \
                          \( -name '*.sh' -o -name '*.py' -o -name 'Makefile' -o -name '*.ps1' \) -print \
                          | grep -v -F -e 'tests/scripts/test-stack-idp-exposure.sh' \
                              -e 'tests/scripts/stack_idp_exposure_mutations.sh')
fi
o="$(python3 "${WORK}/literal_scan.py" "${lfiles[@]}" 2>&1)"; rc=$?
lsum="$(tail -1 <<<"${o}")"
[ "${rc}" -eq 0 ] && ok "no literal default in ${#lfiles[@]} scripts (${lsum})" \
  || { bad "a script defaults the Casdoor admin password to a literal:"; sed 's/^/         /' <<<"${o}"; }
refs="$(sed -n 's/^refs=\([0-9]*\).*/\1/p' <<<"${lsum}")"
# seed-e2e.sh, derive-games-admin.sh, seed-accounts.sh, seed-personas.sh and
# verify-seeded-identities.sh each expand it once (5 on 2026-11-11).
[ "${refs:-0}" -ge 4 ] && ok "vacuity floor: ${refs} admin-password expansions judged (>= 4)" \
  || bad "only ${refs:-0} admin-password expansions judged: the scan is not seeing the seeders"
cat > "${WORK}/lit-neg.sh" <<'EOF'
CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-123}"
: "${CASDOOR_ADMIN_PASSWORD:=hunter2}"
AP="${CASDOOR_ADMIN_PASS-admin}"
EOF
printf 'import os\npw = os.environ.get("CASDOOR_ADMIN_PASS", "123")\n' > "${WORK}/lit-neg.py"
o="$(python3 "${WORK}/literal_scan.py" "${WORK}/lit-neg.sh" "${WORK}/lit-neg.py" 2>&1)"
[ "$(sed -n 's/.*findings=\([0-9]*\).*/\1/p' <<<"$(tail -1 <<<"${o}")")" = 4 ] \
  && ok "neg: :-x, :=x, -x and environ.get(..., x) are each reported (4)" \
  || bad "neg: planted literal defaults not all reported: $(tr '\n' '|' <<<"${o}")"
printf 'A="${CASDOOR_ADMIN_PASS:-}"\nB="${CASDOOR_ADMIN_PASS:?required}"\nC="${CASDOOR_ADMIN_PASS}"\n' > "${WORK}/lit-pos.sh"
python3 "${WORK}/literal_scan.py" "${WORK}/lit-pos.sh" >/dev/null 2>&1 \
  && ok "pos: :-<empty>, :?msg and a bare reference are not literals" \
  || bad "pos: an allowed shape was reported as a literal"
# The REAL seed, with its pre-NEW-15 literal default put back, is caught.
sed 's/^CASDOOR_ADMIN_PASS="\${CASDOOR_ADMIN_PASS:-}"$/CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS:-123}"/' "${SEED}" > "${WORK}/seed-mut.sh"
if cmp -s "${SEED}" "${WORK}/seed-mut.sh"; then bad "mut seed-literal: could not put the literal back (anchor gone)"
else
  python3 "${WORK}/literal_scan.py" "${WORK}/seed-mut.sh" >/dev/null 2>&1 \
    && bad "mut seed-literal: the restored literal default in seed-e2e.sh was NOT caught" \
    || ok "mut seed-literal: seed-e2e.sh with its old literal default is caught"
fi

# ═════ 5) the generator ══════════════════════════════════════════════════════
echo "-- 5) gen-casdoor-admin-env.sh: mint once, keep, never print except on request --"
G5="${WORK}/g5"; mkdir -p "${G5}"
printf 'OPERATOR_OVERRIDE=keep-me\n# a comment of theirs\n' > "${G5}/.env"
chmod 644 "${G5}/.env"
o="$(CASDOOR_ADMIN_ENV_FILE="${G5}/.env" bash "${GEN}" 2>&1)"; rc=$?
printf '%s\n' "${o}" >> "${ALLOUT}"
v1="$(sed -n 's/^CASDOOR_ADMIN_PASSWORD=//p' "${G5}/.env")"
[ "${rc}" -eq 0 ] && [[ "${v1}" =~ ^[0-9a-f]{48}$ ]] && ok "ensure mints 48 hex into the file" \
  || bad "ensure: rc=${rc}, value shape wrong (len ${#v1})"
[ "$(stat -c '%a' "${G5}/.env")" = 600 ] && ok "the file is 0600 afterwards (was 0644)" || bad "mode $(stat -c '%a' "${G5}/.env")"
grep -qx 'OPERATOR_OVERRIDE=keep-me' "${G5}/.env" && grep -qx '# a comment of theirs' "${G5}/.env" \
  && ok "the operator's other lines are kept" || bad "the operator's lines were lost"
grep -F -- "${v1}" <<<"${o}" >/dev/null && bad "ensure printed the value" || ok "ensure does not print the value"
v2="$(CASDOOR_ADMIN_ENV_FILE="${G5}/.env" bash "${GEN}" --print 2>/dev/null)"
v3="$(CASDOOR_ADMIN_ENV_FILE="${G5}/.env" bash "${GEN}" --read 2>/dev/null)"
[ "${v2}" = "${v1}" ] && [ "${v3}" = "${v1}" ] && ok "--print and --read return the SAME value (create, never rotate)" \
  || bad "the value changed between runs"
[ "$(grep -c '^CASDOOR_ADMIN_PASSWORD=' "${G5}/.env")" = 1 ] && ok "exactly one key line after three runs" || bad "duplicate key lines"
o="$(CASDOOR_ADMIN_ENV_FILE="${G5}/none.env" bash "${GEN}" --read 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ -z "${o}" ] && [ ! -e "${G5}/none.env" ] && ok "--read with no file prints nothing and writes nothing" \
  || bad "--read side effects: rc=${rc}, file $( [ -e "${G5}/none.env" ] && echo created || echo absent)"
printf 'CASDOOR_ADMIN_PASSWORD=123\n' > "${G5}/factory.env"
o="$(CASDOOR_ADMIN_ENV_FILE="${G5}/factory.env" bash "${GEN}" --print 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ! grep -qx '123' <<<"${o}" && ok "a factory-default value in the file is refused, not handed out" \
  || bad "the factory default in the file was accepted (rc=${rc})"
o="$(CASDOOR_ADMIN_ENV_FILE="${G5}/factory.env" bash "${GEN}" --read 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "--read refuses it too" || bad "--read handed out the factory default"
printf "CASDOOR_ADMIN_PASSWORD='a b'\n" > "${G5}/unsafe.env"
CASDOOR_ADMIN_ENV_FILE="${G5}/unsafe.env" bash "${GEN}" --read >/dev/null 2>&1 \
  && bad "a value with a space was accepted" || ok "a value outside [A-Za-z0-9._~-] is refused"
mkdir -p "${G5}/shared"; printf 'X=1\n' > "${G5}/shared/env"; ln -s "${G5}/shared/env" "${G5}/link.env"
CASDOOR_ADMIN_ENV_FILE="${G5}/link.env" bash "${GEN}" >/dev/null 2>&1
[ -L "${G5}/link.env" ] && grep -q '^CASDOOR_ADMIN_PASSWORD=' "${G5}/shared/env" && grep -qx 'X=1' "${G5}/shared/env" \
  && ok "a symlinked file stays a symlink and its target gets the key" || bad "the symlink was replaced or its target not written"
CASDOOR_ADMIN_ENV_FILE="${G5}/.env" bash "${GEN}" --bogus >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 2 ] && ok "an unknown argument is a usage error (rc 2)" || bad "unknown argument rc=${rc}"

# ═════ 6) seed-e2e.sh's admin reconcile, lifted from the real file ═══════════
echo "-- 6) casdoor_admin_session (lifted from the REAL seed-e2e.sh) against the stub --"
LIFT="${WORK}/lifted.sh"
{ grep -E '^(CASDOOR_BOOTSTRAP_PASSWORD|CASDOOR_ADMIN_LOCKOUT_MARKER|CASDOOR_LOGIN_MSG)=' "${SEED}"
  awk '/^casdoor_try_login\(\) \{/,/^}/' "${SEED}"
  grep -E '^casdoor_locked_out\(\) ' "${SEED}"
  awk '/^die_casdoor_lockout\(\) \{/,/^}/' "${SEED}"
  awk '/^casdoor_admin_session\(\) \{/,/^}/' "${SEED}"
} > "${LIFT}"
for fn in casdoor_try_login casdoor_locked_out die_casdoor_lockout casdoor_admin_session; do
  grep -q "^${fn}() " "${LIFT}" && ok "lifted ${fn}() from seed-e2e.sh" || bad "seed-e2e.sh has no ${fn}()"
done
grep -q '^CASDOOR_BOOTSTRAP_PASSWORD=' "${LIFT}" && ok "lifted the named bootstrap credential" || bad "no CASDOOR_BOOTSTRAP_PASSWORD in seed-e2e.sh"
cat > "${WORK}/drive.sh" <<'EOF'
set -euo pipefail
log() { echo "[seed-e2e] $*"; }
die() { echo "seed-e2e.sh: UNMET DEPENDENCY: $*" >&2; exit 2; }
CASDOOR_ADMIN_USER=admin
CJ="$(mktemp "${TMPDIR:-/tmp}/drive-cj.XXXXXX")"
# shellcheck disable=SC1090
. "${LIFT}"
casdoor_admin_session "${CASDOOR_URL}"
name="$(curl -s -b "${CJ}" "${CASDOOR_URL}/api/get-account" | jq -r '.data.name // empty')"
[ "${name}" = admin ] && echo "DRIVE: session in CJ is admin"
EOF
DESIRED="fixture-idpx-desired-7c1e-never-printed"
OTHER="fixture-idpx-other-0b9d-never-printed"
stub_up() { # stub_up <mode> <admin-password> [extra env...]
  stub_down
  rm -f "${WORK}/port" "${WORK}/journal"
  env STUB_MODE="$1" STUB_ADMIN_PASSWORD="$2" STUB_ADMIN_USER=admin \
      STUB_PORT_FILE="${WORK}/port" STUB_JOURNAL="${WORK}/journal" "${@:3}" \
      python3 "${STUB}" >"${WORK}/stub.log" 2>&1 &
  STUB_PID=$!
  local i
  for i in $(seq 1 100); do
    [ -s "${WORK}/port" ] && { CD="http://127.0.0.1:$(cat "${WORK}/port")"; return 0; }
    kill -0 "${STUB_PID}" 2>/dev/null || break
    sleep 0.1
  done
  bad "the stub Casdoor did not come up: $(head -3 "${WORK}/stub.log")"; return 1
}
drive() { # drive <admin-password-the-seed-wants> -> ${DOUT}, ${DRC}
  DOUT="$(env LIFT="${LIFT}" CASDOOR_URL="${CD}" CASDOOR_ADMIN_PASS="$1" timeout 60 bash "${WORK}/drive.sh" 2>&1)"; DRC=$?
  printf '%s\n' "${DOUT}" >> "${ALLOUT}"
}
logins()  { jq -r 'select(.path=="/api/login") | .result' "${WORK}/journal" 2>/dev/null | grep -c "^$1\$" || true; }
setpws()  { jq -r 'select(.path=="/api/set-password") | .path' "${WORK}/journal" 2>/dev/null | grep -c . || true; }
raw_login() { # raw_login <password> -> 0 when the stub accepts it as the admin
  STUB_PW="$1" jq -nc '{application:"app-built-in",organization:"built-in",username:"admin",password:env.STUB_PW,type:"login",autoSignin:true}' \
    | curl -s --max-time 5 "${CD}/api/login" -H 'content-type: application/json' --data-binary @- | jq -e '.status=="ok"' >/dev/null 2>&1
}

# (6a) the fresh volume: the admin is on the factory default.
if stub_up ok 123; then
  drive "${DESIRED}"
  [ "${DRC}" -eq 0 ] && grep -q 'DRIVE: session in CJ is admin' <<<"${DOUT}" \
    && ok "(6a) fresh: an admin session results (rc 0)" || bad "(6a) fresh: rc=${DRC}: $(tail -2 <<<"${DOUT}")"
  [ "$(setpws)" = 1 ] && ok "(6a) fresh: exactly one /api/set-password" || bad "(6a) fresh: $(setpws) set-password call(s)"
  grep -q 'moved off the factory default' <<<"${DOUT}" && ok "(6a) fresh: says it moved the admin off the factory default" \
    || bad "(6a) fresh: no 'moved off the factory default' line"
  # The exposure is the default still working: assert it does not, from OUTSIDE the seed.
  raw_login 123 && bad "(6a) fresh: the factory default STILL signs in after the seed" \
    || ok "(6a) fresh: the factory default no longer signs in"
  raw_login "${DESIRED}" && ok "(6a) fresh: the generated value signs in" || bad "(6a) fresh: the generated value does not sign in"
  w="$(logins wrong)"
  # 1 (generated, before the move) + 1 (the proof the default is refused) + 1 (raw_login 123 above)
  [ "${w}" -le 3 ] && ok "(6a) fresh: wrong-password budget respected (${w} incl. this test's own probe)" \
    || bad "(6a) fresh: ${w} wrong-password attempts"
fi
# (6b) a seeded volume: one login, no write.
if stub_up ok "${DESIRED}"; then
  drive "${DESIRED}"
  [ "${DRC}" -eq 0 ] && [ "$(setpws)" = 0 ] && [ "$(logins ok)" = 1 ] && [ "$(logins wrong)" = 0 ] \
    && ok "(6b) seeded: one login, no set-password, no wrong attempt" \
    || bad "(6b) seeded: rc=${DRC} set-password=$(setpws) ok=$(logins ok) wrong=$(logins wrong)"
fi
# (6c) moved onto a value this checkout does not hold: stop, change nothing.
if stub_up ok "${OTHER}"; then
  drive "${DESIRED}"
  [ "${DRC}" -ne 0 ] && grep -q 'BOTH this checkout' <<<"${DOUT}" && [ "$(setpws)" = 0 ] && [ "$(logins wrong)" = 2 ] \
    && ok "(6c) unknown admin password: stops with the two ways out, no write, exactly 2 wrong attempts" \
    || bad "(6c) unknown: rc=${DRC} set-password=$(setpws) wrong=$(logins wrong): $(tail -1 <<<"${DOUT}")"
  raw_login "${OTHER}" && ok "(6c) the admin's real password was left alone" || bad "(6c) the admin's password was changed"
fi
# (6d) the account is already throttled: one attempt, named a lockout, no write.
if stub_up lockout 123 STUB_LOCKOUT_AFTER=0; then
  drive "${DESIRED}"
  [ "${DRC}" -ne 0 ] && grep -q 'sign-in throttle' <<<"${DOUT}" && grep -q 'do NOT change' <<<"${DOUT}" \
    && [ "$(logins locked)" = 1 ] && [ "$(setpws)" = 0 ] \
    && ok "(6d) throttled: stops as a LOCKOUT after one attempt, no write" \
    || bad "(6d) throttled: rc=${DRC} locked=$(logins locked) set-password=$(setpws): $(tail -1 <<<"${DOUT}")"
fi
# (6e) the throttle trips on the first wrong attempt: no second password tried after it.
if stub_up lockout 123 STUB_LOCKOUT_AFTER=1; then
  drive "${DESIRED}"
  [ "${DRC}" -ne 0 ] && grep -q 'sign-in throttle' <<<"${DOUT}" && [ "$(setpws)" = 0 ] \
    && [ "$(( $(logins wrong) + $(logins locked) ))" -le 2 ] \
    && ok "(6e) throttled mid-run: stops as a LOCKOUT, never retried past the ban" \
    || bad "(6e) rc=${DRC} wrong=$(logins wrong) locked=$(logins locked) set-password=$(setpws)"
fi
# (6f) set-password answers ok but does not persist: the default-refused proof catches it.
if stub_up setpw-noop 123; then
  drive "${DESIRED}"
  [ "${DRC}" -ne 0 ] && grep -q 'STILL signs in' <<<"${DOUT}" \
    && ok "(6f) a set-password that did not persist is caught by the default-refused proof" \
    || bad "(6f) setpw-noop: rc=${DRC}: $(tail -1 <<<"${DOUT}")"
fi
# (6g) set-password is denied: stops, says the admin is still exposed.
if stub_up deny-writes 123; then
  drive "${DESIRED}"
  [ "${DRC}" -ne 0 ] && grep -q 'STILL on the factory default' <<<"${DOUT}" \
    && ok "(6g) a denied set-password stops the seed and says the admin is still on the default" \
    || bad "(6g) deny-writes: rc=${DRC}: $(tail -1 <<<"${DOUT}")"
fi
stub_down
# (6h) /api/login says ok but hands out no admin session (casdoor-init once reconciled
# anonymously behind an unchecked login): the seed must stop, not carry on as nobody.
cat > "${WORK}/anon_stub.py" <<'ANON'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._send({"status": "ok", "msg": "", "data": "built-in/admin"})
    def do_GET(self):
        self._send({"status": "error", "msg": "Please login first", "data": None})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
ANON
rm -f "${WORK}/anon.port"
python3 "${WORK}/anon_stub.py" "${WORK}/anon.port" >/dev/null 2>&1 &
STUB_PID=$!
for _ in $(seq 1 100); do [ -s "${WORK}/anon.port" ] && break; sleep 0.1; done
if [ -s "${WORK}/anon.port" ]; then
  CD="http://127.0.0.1:$(cat "${WORK}/anon.port")"
  drive "${DESIRED}"
  [ "${DRC}" -ne 0 ] && grep -q "session resolves to 'nobody'" <<<"${DOUT}" \
    && ok "(6h) a login that yields no admin session stops the seed (proven by /api/get-account)" \
    || bad "(6h) an ok-but-anonymous login was accepted: rc=${DRC}: $(tail -1 <<<"${DOUT}")"
else
  bad "(6h) the anonymous-session stub did not come up"
fi
stub_down

# ═════ 7) the real seed-e2e.sh: resolution and refusal ═══════════════════════
echo "-- 7) seed-e2e.sh resolves its admin password safely --"
S7="${WORK}/s7"; mkdir -p "${S7}/bin"
# The seed preflights `command -v docker` (its social legs exec into containers);
# none of that is reached here, so a no-op shim keeps the run identical with or
# without a docker CLI on the box.
printf '#!/bin/sh\nexit 0\n' > "${S7}/bin/docker"; chmod +x "${S7}/bin/docker"
o="$(env PATH="${S7}/bin:${PATH}" CASDOOR_ADMIN_PASS=123 CASDOOR_ADMIN_ENV_FILE="${S7}/never.env" E2E_CREDENTIALS_FILE="${S7}/creds" \
       CASDOOR_URL=http://127.0.0.1:1 FRONT_DOOR=http://127.0.0.1:1 SEED_WAIT_S=0 SEED_WORKDIR="${S7}/w" \
       timeout 60 bash "${SEED}" 2>&1)"; rc=$?
printf '%s\n' "${o}" >> "${ALLOUT}"
[ "${rc}" -eq 2 ] && grep -q "factory-default password. Refusing" <<<"${o}" && [ ! -e "${S7}/creds" ] \
  && ok "an exported factory default is refused before anything runs (rc 2, no run started)" \
  || bad "exported factory default: rc=${rc}, creds $( [ -e "${S7}/creds" ] && echo written || echo absent): $(tail -1 <<<"${o}")"
o="$(env -u CASDOOR_ADMIN_PASS PATH="${S7}/bin:${PATH}" CASDOOR_ADMIN_ENV_FILE="${S7}/admin.env" E2E_CREDENTIALS_FILE="${S7}/creds" \
       CASDOOR_URL=http://127.0.0.1:1 FRONT_DOOR=http://127.0.0.1:1 SEED_WAIT_S=0 SEED_WORKDIR="${S7}/w" \
       timeout 60 bash "${SEED}" 2>&1)"; rc=$?
printf '%s\n' "${o}" >> "${ALLOUT}"
[ "${rc}" -ne 0 ] && grep -q 'Casdoor http://127.0.0.1:1/ is not answering' <<<"${o}" \
  && grep -Eq '^CASDOOR_ADMIN_PASSWORD=[0-9a-f]{48}$' "${S7}/admin.env" \
  && ok "unset: the seed mints its admin password into CASDOOR_ADMIN_ENV_FILE (then stops at the dead Casdoor)" \
  || bad "unset: rc=${rc}, env file $( [ -e "${S7}/admin.env" ] && echo present || echo absent): $(tail -1 <<<"${o}")"

# ═════ 8) derive-games-admin.sh reads, never mints ═══════════════════════════
echo "-- 8) derive-games-admin.sh reads the generated value and never mints one --"
D8="${WORK}/d8"; mkdir -p "${D8}"
o="$(env -u CASDOOR_ADMIN_PASS CASDOOR_ADMIN_ENV_FILE="${D8}/none.env" CASDOOR_URL=http://127.0.0.1:1 \
       timeout 60 bash "${DERIVE}" --dry-run 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && grep -q 'make stack-seed' <<<"${o}" && [ ! -e "${D8}/none.env" ] \
  && ok "no password anywhere: stops naming make stack-seed, writes no file" \
  || bad "no password: rc=${rc}, file $( [ -e "${D8}/none.env" ] && echo created || echo absent): $(tail -1 <<<"${o}")"
printf '{"ROLE_GAMES":[],"ROLE_ADMIN":[],"ROLE_MOD":[],"ROLE_GAMES_ADMIN":[]}\n' > "${D8}/fixture.json"
o="$(env -u CASDOOR_ADMIN_PASS CASDOOR_ADMIN_ENV_FILE="${D8}/none.env" timeout 60 bash "${DERIVE}" --fixture "${D8}/fixture.json" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "${D8}/none.env" ] && ok "--fixture needs no password and touches no file" \
  || bad "--fixture: rc=${rc}: $(tail -1 <<<"${o}")"
if stub_up ok "${DESIRED}"; then
  printf 'CASDOOR_ADMIN_PASSWORD=%s\n' "${DESIRED}" > "${D8}/admin.env"
  o="$(env -u CASDOOR_ADMIN_PASS CASDOOR_ADMIN_ENV_FILE="${D8}/admin.env" CASDOOR_URL="${CD}" \
         timeout 60 bash "${DERIVE}" --dry-run 2>&1)"; rc=$?
  printf '%s\n' "${o}" >> "${ALLOUT}"
  [ "$(logins ok)" -ge 1 ] && [ "$(logins wrong)" = 0 ] && [ "$(setpws)" = 0 ] \
    && ok "unset: signs in with the file's value (no wrong attempt, no write)" \
    || bad "unset with a file: ok=$(logins ok) wrong=$(logins wrong) set-password=$(setpws) rc=${rc}"
  stub_down
fi

# ═════ 9) secrets and side effects ═══════════════════════════════════════════
echo "-- 9) no password in any output; the checkout's tests/stack/.env untouched --"
leaked=""
for v in "${DESIRED}" "${OTHER}" "${v1:-unset-v1}"; do
  grep -F -q -- "${v}" "${ALLOUT}" && leaked="${leaked} ${v:0:8}..."
done
[ -z "${leaked}" ] && ok "no admin password value appears in any captured output" || bad "leaked into output:${leaked}"
[ "$(env_fingerprint)" = "${REAL_ENV_BEFORE}" ] && ok "the checkout's tests/stack/.env is exactly as before (${REAL_ENV_BEFORE:0:12})" \
  || bad "this suite changed the checkout's tests/stack/.env"

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
