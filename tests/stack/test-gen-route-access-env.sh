#!/usr/bin/env bash
# test-gen-route-access-env.sh — the local stack's route-access-db OWNER password
# is generated per checkout, never spelled in a committed file.
#
# Until 2026-10-29 compose.local.yaml set route-access-db's POSTGRES_PASSWORD and
# all four gateways' ROUTE_ACCESS_R2DBC_URL to the owner role's own name, the same
# word the cluster manifest shipped for a week in June. Now the value lives in the
# gitignored tests/stack/.route-access-db.env, which tests/stack/gen-route-access-env.sh
# creates and the Makefile's STACK_ENV threads into every compose call.
#
# Proves, with no docker, no network and no compose run (a docker STUB answers the
# one volume probe):
#   (1) a fresh checkout gets a 48-hex value in a 0600 file, and --print emits
#       exactly that value and nothing else;
#   (2) CREATE, NEVER ROTATE: a second run keeps the value (the volume keeps the
#       password it was initialised with);
#   (3) a missing file next to an EXISTING route-access-pg volume adopts the old
#       default instead of locking the gateways out, and says so on stderr only;
#       docker that cannot answer (daemon down) writes nothing and fails;
#   (4) a hand-edited value that is not URL-unreserved is refused (it would be
#       URL-decoded differently inside the r2dbc URL);
#   (5) compose.local.yaml reads ${ROUTE_ACCESS_DB_PASSWORD:-} in all five places
#       (POSTGRES_PASSWORD + four gateway URLs) and spells no route-access-db
#       password; the file is gitignored;
#   (6) the Makefile wiring: `make -n stack-up` carries the generator's command
#       substitution on the compose lines (and therefore never a value), and
#       stack-down/stack-clean delete the file only AFTER `down -v`;
#   (7) scripts/stack-up.ps1 (the Windows path, which calls compose directly)
#       exports the same variable from the same file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GEN="${HERE}/gen-route-access-env.sh"
COMPOSE="${HERE}/compose.local.yaml"

P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A docker stub for the one volume probe: STUB_VOLUME_EXISTS=1 the volume exists,
# 0 docker answers "no such volume" (the real CLI's wording), down = the daemon
# cannot be reached.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "volume inspect" ] || exit 99
case "${STUB_VOLUME_EXISTS:-0}" in
  1) echo '[{"Name": "x"}]' ;;
  down) echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1 ;;
  *) echo "Error response from daemon: get $3: no such volume" >&2; exit 1 ;;
esac
EOF
chmod +x "${WORK}/bin/docker"

gen() { # gen <env-file> <volume-exists 0|1> [--print] -> runs the generator
  local f="$1" v="$2"; shift 2
  ROUTE_ACCESS_DB_ENV="${f}" DOCKER="${WORK}/bin/docker" STUB_VOLUME_EXISTS="${v}" bash "${GEN}" "$@"
}
file_val() { sed -n 's/^ROUTE_ACCESS_DB_PASSWORD=//p' "$1" | tail -1; }

echo "== route-access-db owner password: generated, never committed =="

echo "-- 1) fresh checkout: a random URL-safe value in a 0600 file --"
E1="${WORK}/fresh.env"
out1="$(gen "${E1}" 0 --print 2>"${WORK}/err1")"; rc=$?
v1="$(file_val "${E1}" 2>/dev/null)"
if [ "${rc}" -eq 0 ] && [[ "${v1}" =~ ^[0-9a-f]{48}$ ]]; then ok "file holds a 48-hex value"; else bad "rc=${rc}, value not 48 hex (len ${#v1})"; fi
if [ "${out1}" = "${v1}" ]; then ok "--print emits exactly the stored value"; else bad "--print output (len ${#out1}) differs from the file's value"; fi
if [ ! -s "${WORK}/err1" ]; then ok "--print is silent on stderr for a fresh volume"; else bad "unexpected stderr: $(head -1 "${WORK}/err1")"; fi
mode="$(stat -c %a "${E1}" 2>/dev/null)"
if [ "${mode}" = 600 ]; then ok "file mode is 0600"; else bad "file mode is ${mode:-missing}, want 600"; fi
E1b="${WORK}/fresh2.env"; gen "${E1b}" 0 >/dev/null 2>&1
if [ "$(file_val "${E1b}")" != "${v1}" ]; then ok "two checkouts get different values"; else bad "two fresh runs minted the SAME value"; fi

echo "-- 2) create, never rotate --"
out2="$(gen "${E1}" 0 --print 2>/dev/null)"
if [ "${out2}" = "${v1}" ] && [ "$(file_val "${E1}")" = "${v1}" ]; then ok "second run keeps the value"; else bad "second run ROTATED the password (a kept volume would lock the gateways out)"; fi
out2b="$(gen "${E1}" 1 --print 2>/dev/null)"
if [ "${out2b}" = "${v1}" ]; then ok "an existing file wins over the legacy-volume path"; else bad "an existing file was replaced because a volume exists"; fi

echo "-- 3) a volume older than the file keeps its old password --"
E3="${WORK}/legacy.env"
out3="$(gen "${E3}" 1 --print 2>"${WORK}/err3")"; rc=$?
# The old compose default was the route-access-db service's own POSTGRES_USER.
owner="$(python3 - "${COMPOSE}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\n  route-access-db:\n(.*?)\n  [a-z]", s, re.S)
u = re.search(r"POSTGRES_USER:\s*(\S+)", m.group(1)) if m else None
print(u.group(1) if u else "")
PY
)"
if [ -z "${owner}" ]; then
  bad "could not read route-access-db's POSTGRES_USER from compose.local.yaml"
elif [ "${rc}" -eq 0 ] && [ "${out3}" = "${owner}" ]; then ok "adopted the owner role's name for a pre-existing volume"; else bad "rc=${rc}: did not adopt the pre-existing volume's password"; fi
if grep -q 'WARNING' "${WORK}/err3" && ! grep -q 'WARNING' <<<"${out3}"; then ok "the adoption warning goes to stderr, never into the value"; else bad "adoption warning missing from stderr or leaked into stdout"; fi
if grep -q '^# adopted' "${E3}"; then ok "the file records that it was adopted"; else bad "file does not record the adoption"; fi

echo "-- 3b) docker that cannot answer is not read as 'no volume' --"
E3b="${WORK}/down.env"
out3b="$(gen "${E3b}" down --print 2>"${WORK}/err3b")"; rc=$?
if [ "${rc}" -ne 0 ] && [ -z "${out3b}" ] && [ ! -e "${E3b}" ]; then ok "daemon unreachable: fails (rc=${rc}), prints nothing, writes no file"; else bad "daemon unreachable: rc=${rc}, file $( [ -e "${E3b}" ] && echo WRITTEN || echo absent)"; fi
E3c="${WORK}/nocli.env"
out3c="$(ROUTE_ACCESS_DB_ENV="${E3c}" DOCKER="${WORK}/no-such-docker" bash "${GEN}" --print 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [[ "${out3c}" =~ ^[0-9a-f]{48}$ ]]; then ok "no docker CLI at all (a CI runner): mints a fresh value"; else bad "no docker CLI: rc=${rc}, no fresh value"; fi

echo "-- 4) a value the r2dbc URL would decode differently is refused --"
E4="${WORK}/bad.env"; printf 'ROUTE_ACCESS_DB_PASSWORD=ab+cd/ef\n' > "${E4}"
out4="$(gen "${E4}" 0 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -ne 0 ] && [ -z "${out4}" ]; then ok "a '+' or '/' in the file fails loudly (rc=${rc}) and prints nothing"; else bad "an unsafe value was passed on (rc=${rc})"; fi

echo "-- 5) compose.local.yaml spells no route-access-db password --"
n_ref="$(grep -c '\${ROUTE_ACCESS_DB_PASSWORD:-}' "${COMPOSE}")"
if [ "${n_ref}" -eq 5 ]; then ok "5 references to \${ROUTE_ACCESS_DB_PASSWORD:-} (POSTGRES_PASSWORD + 4 gateway URLs)"; else bad "${n_ref} references, want 5"; fi
n_url="$(grep -c 'ROUTE_ACCESS_R2DBC_URL: "r2dbc:postgresql://gateway:\${ROUTE_ACCESS_DB_PASSWORD:-}@route-access-db:5432/gateway"' "${COMPOSE}")"
if [ "${n_url}" -eq 4 ]; then ok "all 4 gateway URLs interpolate it"; else bad "${n_url} gateway URLs interpolate it, want 4"; fi
lit="$(python3 - "${COMPOSE}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
# any r2dbc/postgres URL to route-access-db whose password is a LITERAL
print(len(re.findall(r"postgres(?:ql)?://[^:/\s]+:(?!\$\{)[^@\s]+@route-access-db", s)))
m = re.search(r"\n  route-access-db:\n(.*?)\n  [a-z]", s, re.S)
blk = m.group(1) if m else ""
pw = re.search(r"POSTGRES_PASSWORD:\s*(\S+)", blk)
print(pw.group(1) if pw else "MISSING")
PY
)"
if [ "$(sed -n 1p <<<"${lit}")" = 0 ]; then ok "no route-access-db URL carries a literal password"; else bad "$(sed -n 1p <<<"${lit}") route-access-db URL(s) carry a literal password"; fi
if [ "$(sed -n 2p <<<"${lit}")" = '${ROUTE_ACCESS_DB_PASSWORD:-}' ]; then ok "route-access-db POSTGRES_PASSWORD is the variable"; else bad "route-access-db POSTGRES_PASSWORD is not the variable"; fi
if git -C "${REPO}" check-ignore -q tests/stack/.route-access-db.env; then ok "tests/stack/.route-access-db.env is gitignored"; else bad "tests/stack/.route-access-db.env is NOT gitignored"; fi

echo "-- 6) Makefile wiring (make -n: the recipe make would run, nothing executed) --"
if command -v make >/dev/null 2>&1; then
  up="$(cd "${REPO}" && timeout 60 make -n -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env stack-up 2>/dev/null)"
  sub='ROUTE_ACCESS_DB_PASSWORD="$(bash tests/stack/gen-route-access-env.sh --print)"'
  n_compose="$(grep -c ' compose -f tests/stack/compose.local.yaml' <<<"${up}")"
  n_sub="$(grep ' compose -f tests/stack/compose.local.yaml' <<<"${up}" | grep -cF "${sub}")"
  if [ "${n_compose}" -ge 2 ] && [ "${n_sub}" -eq "${n_compose}" ]; then ok "every compose line of stack-up (${n_compose}) carries the generator substitution"; else bad "${n_sub} of ${n_compose} stack-up compose lines carry the generator substitution"; fi
  if grep 'route-access-reconcile.sh' <<<"${up}" | grep -F "${sub}" >/dev/null; then ok "the route-access reconcile step carries it too"; else bad "the reconcile step does not carry ROUTE_ACCESS_DB_PASSWORD"; fi
  if grep -qE 'ROUTE_ACCESS_DB_PASSWORD=[0-9a-f]{16,}' <<<"${up}"; then bad "make -n prints a password VALUE"; else ok "make -n prints the substitution, never a value"; fi
  for tgt in stack-down stack-clean; do
    rec="$(cd "${REPO}" && timeout 60 make -n "${tgt}" 2>/dev/null)"
    dv="$(grep -n 'down -v' <<<"${rec}" | head -1 | cut -d: -f1)"
    rm_="$(grep -n 'rm -f tests/stack/.route-access-db.env' <<<"${rec}" | head -1 | cut -d: -f1)"
    if [ -n "${dv}" ] && [ -n "${rm_}" ] && [ "${rm_}" -gt "${dv}" ]; then ok "${tgt} deletes the file after down -v"; else bad "${tgt}: down -v at '${dv:-none}', rm at '${rm_:-none}'"; fi
  done
  halt="$(cd "${REPO}" && timeout 60 make -n stack-halt 2>/dev/null)"
  if grep -q 'rm -f tests/stack/.route-access-db.env' <<<"${halt}"; then bad "stack-halt deletes the file (it keeps the volume)"; else ok "stack-halt keeps the file (it keeps the volume)"; fi
else
  bad "make is not installed — section 6 asserted nothing"
fi

echo "-- 7) Windows path (scripts/stack-up.ps1) --"
PS1="${REPO}/scripts/stack-up.ps1"
if grep -q "Join-Path \$StackDir '.route-access-db.env'" "${PS1}" && grep -q '\$env:ROUTE_ACCESS_DB_PASSWORD = \$routeAccessPw' "${PS1}"; then
  ok "stack-up.ps1 exports ROUTE_ACCESS_DB_PASSWORD from tests\\stack\\.route-access-db.env"
else
  bad "stack-up.ps1 does not thread ROUTE_ACCESS_DB_PASSWORD (compose would get an empty password)"
fi
if grep -q 'RandomNumberGenerator' "${PS1}"; then ok "stack-up.ps1 mints with a CSPRNG"; else bad "stack-up.ps1 does not use a CSPRNG"; fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
