#!/usr/bin/env bash
# test-gen-route-access-env.sh — the local stack's route-access-db OWNER password
# is generated per checkout, never spelled in a committed file, and reaches EVERY
# compose caller.
#
# Until 2026-10-29 compose.local.yaml set route-access-db's POSTGRES_PASSWORD and
# all four gateways' ROUTE_ACCESS_R2DBC_URL to the owner role's own name, the same
# word the cluster manifest shipped for a week in June. Now the value is the
# ROUTE_ACCESS_DB_PASSWORD key of the gitignored tests/stack/.env (compose's own
# auto-loaded env file), which tests/stack/gen-route-access-env.sh writes.
#
# Proves, with no docker daemon, no network and no real compose run (a docker STUB
# answers the volume and container probes, a compose STUB records what make runs):
#   (1) a fresh checkout gets a 48-hex value in a 0600 file, and --print emits
#       exactly that value and nothing else;
#   (2) CREATE, NEVER ROTATE: a second run keeps the value;
#   (3) a missing key next to an EXISTING route-access-pg volume adopts the value
#       the project's route-access-db container was created with, or the old default
#       when no container is left, and says so on stderr only; docker that cannot
#       answer writes nothing and fails; the old .route-access-db.env is migrated;
#   (4) a value the r2dbc URL would decode differently is refused; dotenv quoting
#       and `export` are read the way compose reads them;
#   (5) the file is SHARED: an operator's other lines survive every write, the mode
#       is tightened to 0600, --remove strips only this key (and deletes the file only
#       when nothing else is left);
#   (5b) a SYMLINKED .env stays a symlink: the target gets the key (atomically, in
#       its own directory) and --remove never deletes the shared target;
#   (6) compose.local.yaml reads ${ROUTE_ACCESS_DB_PASSWORD:-} in all five places and
#       spells no route-access-db password; tests/stack/.env is gitignored;
#   (6b) an EMPTY value fails loud: the route-access-env-check one-shot (which
#       route-access-db and all four URL consumers depend on) exits 1 naming the
#       generator, and the JAVA_TOOL_OPTIONS start guard makes the four JVMs refuse
#       to start; neither ever carries the value itself;
#   (7) the Makefile: stack-up (the target that creates containers) depends on the
#       stack-route-access-env ensure step and the read-only targets do not;
#       BEHAVIOURALLY a generator failure stops make stack-up before compose runs, a
#       read-only target neither writes the file nor asks docker, and a present key
#       reaches compose even over an exported empty variable;
#       stack-down/stack-clean strip the key only AFTER `down -v`;
#   (8) scripts/stack-up.ps1 (the Windows path) follows the same contract; with pwsh
#       on PATH (GitHub's ubuntu runners have it) its block is RUN against a stub.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GEN="${HERE}/gen-route-access-env.sh"
COMPOSE="${HERE}/compose.local.yaml"

P=0; F=0; S=0
ok()   { echo "  ok   $*"; P=$((P + 1)); }
bad()  { echo "  FAIL $*"; F=$((F + 1)); }
skip() { echo "  SKIP $*"; S=$((S + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A docker stub. STUB_VOLUME_EXISTS=1 the volume exists, 0 docker answers "no such
# volume" (the real CLI's wording), down = the daemon cannot be reached.
# STUB_CONTAINER_PW set = a route-access-db container exists, created with that
# POSTGRES_PASSWORD. Every call is logged to STUB_LOG when set.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_LOG:-}" ] || echo "docker $*" >> "${STUB_LOG}"
if [ "${STUB_VOLUME_EXISTS:-0}" = down ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1
fi
case "$1 $2" in
  "volume inspect")
    [ "${STUB_VOLUME_EXISTS:-0}" = 1 ] && { echo '[{"Name": "x"}]'; exit 0; }
    echo "Error response from daemon: get $3: no such volume" >&2; exit 1 ;;
  "ps -a")
    case "$*" in *"com.docker.compose.service=route-access-db"*) ;; *) exit 98 ;; esac
    [ -z "${STUB_CONTAINER_PW+x}" ] || echo "c0ffee000001"
    exit 0 ;;
  "inspect -f")
    printf 'PATH=/usr/bin\nPOSTGRES_DB=gateway\nPOSTGRES_PASSWORD=%s\nPOSTGRES_USER=gateway\n' "${STUB_CONTAINER_PW}"
    exit 0 ;;
esac
exit 99
EOF
chmod +x "${WORK}/bin/docker"

gen() { # gen <env-file> <volume-exists 0|1|down> [args] -> runs the generator
  local f="$1" v="$2"; shift 2
  ROUTE_ACCESS_DB_ENV="${f}" ROUTE_ACCESS_DB_LEGACY_ENV="${f}.legacy" \
    DOCKER="${WORK}/bin/docker" STUB_VOLUME_EXISTS="${v}" bash "${GEN}" "$@"
}
file_val() { sed -n 's/^ROUTE_ACCESS_DB_PASSWORD=//p' "$1" | tail -1; }
n_keys() { grep -c 'ROUTE_ACCESS_DB_PASSWORD' "$1"; }

echo "== route-access-db owner password: generated, never committed, every caller =="

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
sum_before="$(sha256sum < "${E1}")"
out2="$(gen "${E1}" 0 --print 2>/dev/null)"
if [ "${out2}" = "${v1}" ] && [ "$(sha256sum < "${E1}")" = "${sum_before}" ]; then ok "second run keeps the value and leaves the file byte-identical"; else bad "second run ROTATED or rewrote the password"; fi
out2b="$(STUB_CONTAINER_PW=other gen "${E1}" 1 --print 2>/dev/null)"
if [ "${out2b}" = "${v1}" ]; then ok "an existing key wins over the volume/container adoption path"; else bad "an existing key was replaced because a volume exists"; fi

echo "-- 3) a volume older than the key keeps the password it was initialised with --"
# The old compose default was the route-access-db service's own POSTGRES_USER.
owner="$(python3 - "${COMPOSE}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\n  route-access-db:\n(.*?)\n  [a-z]", s, re.S)
u = re.search(r"POSTGRES_USER:\s*(\S+)", m.group(1)) if m else None
print(u.group(1) if u else "")
PY
)"
E3="${WORK}/legacy.env"
out3="$(gen "${E3}" 1 --print 2>"${WORK}/err3")"; rc=$?
if [ -z "${owner}" ]; then
  bad "could not read route-access-db's POSTGRES_USER from compose.local.yaml"
elif [ "${rc}" -eq 0 ] && [ "${out3}" = "${owner}" ]; then ok "no container left: adopted the owner role's name (the pre-2026-10-29 default)"; else bad "rc=${rc}: did not adopt the pre-existing volume's password"; fi
if grep -q 'WARNING' "${WORK}/err3" && grep -q 'ANOTHER checkout' "${WORK}/err3" && ! grep -q 'WARNING' <<<"${out3}"; then ok "the warning (naming the other-checkout risk) goes to stderr, never into the value"; else bad "adoption warning missing from stderr or leaked into stdout"; fi
if grep -q '^# adopted' "${E3}"; then ok "the file records that it was adopted"; else bad "file does not record the adoption"; fi
E3a="${WORK}/ctr.env"
ctr_pw="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718"
out3a="$(STUB_CONTAINER_PW="${ctr_pw}" gen "${E3a}" 1 --print 2>"${WORK}/err3a")"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${out3a}" = "${ctr_pw}" ] && [ "$(file_val "${E3a}")" = "${ctr_pw}" ]; then ok "a route-access-db container exists: adopted ITS password (a second checkout of a random-valued stack)"; else bad "rc=${rc}: did not adopt the existing container's password"; fi
if grep -q 'adopted from the existing' "${E3a}" && grep -q WARNING "${WORK}/err3a" && ! grep -qF "${ctr_pw}" "${WORK}/err3a"; then ok "container adoption is recorded and warned about without echoing the value"; else bad "container adoption not recorded/warned, or the value was echoed on stderr"; fi
E3u="${WORK}/ctr-unsafe.env"
out3u="$(STUB_CONTAINER_PW='ab+cd' gen "${E3u}" 1 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -ne 0 ] && [ -z "${out3u}" ] && [ ! -e "${E3u}" ]; then ok "an unsafe container value is refused, nothing written"; else bad "an unsafe container value was adopted (rc=${rc})"; fi
E3e="${WORK}/ctr-empty.env"
out3e="$(STUB_CONTAINER_PW= gen "${E3e}" 1 --print 2>"${WORK}/err3e")"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${out3e}" = "${owner}" ] && grep -q 'created with an EMPTY value' "${WORK}/err3e"; then ok "a container created with an EMPTY value (a failed hand-run up) is not adopted; the warning says why"; else bad "empty-valued container: rc=${rc}, got len ${#out3e}, stderr: $(head -2 "${WORK}/err3e" | tr '\n' '|')"; fi
E3p="${WORK}/proj.env"; : > "${WORK}/log3p"
STUB_LOG="${WORK}/log3p" ROUTE_ACCESS_DB_PROJECT=other-proj gen "${E3p}" 1 >/dev/null 2>&1
if grep -q 'volume inspect other-proj_route-access-pg' "${WORK}/log3p" && grep -q 'com.docker.compose.project=other-proj' "${WORK}/log3p"; then ok "ROUTE_ACCESS_DB_PROJECT pins both the volume and the container probe"; else bad "the project pin did not reach the probes: $(tr '\n' '|' < "${WORK}/log3p")"; fi

echo "-- 3b) docker that cannot answer is not read as 'no volume' --"
E3b="${WORK}/down.env"
out3b="$(gen "${E3b}" down --print 2>"${WORK}/err3b")"; rc=$?
if [ "${rc}" -ne 0 ] && [ -z "${out3b}" ] && [ ! -e "${E3b}" ]; then ok "daemon unreachable: fails (rc=${rc}), prints nothing, writes no file"; else bad "daemon unreachable: rc=${rc}, file $( [ -e "${E3b}" ] && echo WRITTEN || echo absent)"; fi
E3c="${WORK}/nocli.env"
out3c="$(ROUTE_ACCESS_DB_ENV="${E3c}" ROUTE_ACCESS_DB_LEGACY_ENV="${E3c}.legacy" DOCKER="${WORK}/no-such-docker" bash "${GEN}" --print 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [[ "${out3c}" =~ ^[0-9a-f]{48}$ ]]; then ok "no docker CLI at all (a CI runner): mints a fresh value"; else bad "no docker CLI: rc=${rc}, no fresh value"; fi

echo "-- 3c) the earlier revision's .route-access-db.env is migrated, not re-minted --"
E3m="${WORK}/mig.env"; legacy_pw="0123456789abcdef0123456789abcdef0123456789abcdef"
printf '# old\nROUTE_ACCESS_DB_PASSWORD=%s\n' "${legacy_pw}" > "${E3m}.legacy"
out3m="$(gen "${E3m}" 1 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${out3m}" = "${legacy_pw}" ] && [ ! -e "${E3m}.legacy" ]; then ok "legacy value moved into .env and the old file deleted (no volume guess)"; else bad "legacy migration: rc=${rc}, legacy file $( [ -e "${E3m}.legacy" ] && echo KEPT || echo gone)"; fi

echo "-- 4) values compose and the r2dbc URL would read differently --"
E4="${WORK}/bad.env"; printf 'ROUTE_ACCESS_DB_PASSWORD=ab+cd/ef\n' > "${E4}"
out4="$(gen "${E4}" 0 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -ne 0 ] && [ -z "${out4}" ]; then ok "a '+' or '/' in the file fails loudly (rc=${rc}) and prints nothing"; else bad "an unsafe value was passed on (rc=${rc})"; fi
E4q="${WORK}/quoted.env"; printf 'export ROUTE_ACCESS_DB_PASSWORD = "deadbeef42"\r\n' > "${E4q}"
out4q="$(gen "${E4q}" 0 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${out4q}" = deadbeef42 ]; then ok "export prefix, spaces, quotes and CRLF are read like compose's dotenv"; else bad "dotenv spelling misread: rc=${rc} got '${out4q}'"; fi
E4e="${WORK}/empty.env"; printf 'FOO=1\nROUTE_ACCESS_DB_PASSWORD=\n' > "${E4e}"
out4e="$(gen "${E4e}" 0 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [[ "${out4e}" =~ ^[0-9a-f]{48}$ ]] && [ "$(n_keys "${E4e}")" -eq 1 ]; then ok "an EMPTY key is filled in place (one key line left, not two)"; else bad "empty key: rc=${rc}, $(n_keys "${E4e}") key lines"; fi

E4r="${WORK}/read-none.env"; : > "${WORK}/log4r"
out4r="$(STUB_LOG="${WORK}/log4r" gen "${E4r}" 1 --read 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -z "${out4r}" ] && [ ! -e "${E4r}" ] && [ ! -s "${WORK}/log4r" ]; then ok "--read with no key prints nothing, writes nothing, never asks docker"; else bad "--read with no key: rc=${rc}, file $( [ -e "${E4r}" ] && echo WRITTEN || echo absent), docker calls $(wc -l < "${WORK}/log4r")"; fi
out4r2="$(gen "${E4q}" 0 --read 2>/dev/null)"
if [ "${out4r2}" = deadbeef42 ]; then ok "--read prints an existing key"; else bad "--read did not print the existing key"; fi
gen "${E4}" 0 --read >/dev/null 2>&1; rc=$?
if [ "${rc}" -ne 0 ]; then ok "--read refuses an unsafe key (rc=${rc})"; else bad "--read passed an unsafe key on"; fi

echo "-- 5) the file is shared: the operator's lines survive --"
E5="${WORK}/operator.env"
printf '# my overrides\nPUBLIC_HOST_PORT=9999\nCOMPOSE_PROFILES=social\n\nHUG_WEB_LOCALES="de,fr"\n' > "${E5}"
chmod 644 "${E5}"
cp "${E5}" "${WORK}/operator.orig"
v5="$(gen "${E5}" 0 --print 2>/dev/null)"
if head -c "$(stat -c %s "${WORK}/operator.orig")" "${E5}" | cmp -s - "${WORK}/operator.orig"; then ok "every operator line is kept verbatim, the key is appended after them"; else bad "the operator's lines were changed"; fi
if [ "$(stat -c %a "${E5}")" = 600 ]; then ok "an operator-made 0644 .env is tightened to 0600 once it holds the credential"; else bad "mode is $(stat -c %a "${E5}"), want 600"; fi
if [ "$(file_val "${E5}")" = "${v5}" ] && [ "$(n_keys "${E5}")" -eq 1 ]; then ok "exactly one key line, holding the printed value"; else bad "$(n_keys "${E5}") key lines"; fi
gen "${E5}" 0 --remove >/dev/null 2>&1
if cmp -s "${E5}" "${WORK}/operator.orig"; then ok "--remove gives the operator's file back byte for byte"; else bad "--remove left the operator's file different: $(diff "${WORK}/operator.orig" "${E5}" | head -3 | tr '\n' '|')"; fi
gen "${E1}" 0 --remove >/dev/null 2>&1
if [ ! -e "${E1}" ]; then ok "--remove deletes a file that held only this key"; else bad "--remove left a file that held only this key"; fi
if gen "${WORK}/never.env" 0 --remove >/dev/null 2>&1 && [ ! -e "${WORK}/never.env" ]; then ok "--remove with no file is a quiet no-op"; else bad "--remove with no file failed or created one"; fi
E5k="${WORK}/own-key.env"; printf 'ROUTE_ACCESS_DB_PASSWORD=operatorchosen1\nX=1\n' > "${E5k}"; chmod 600 "${E5k}"
s5k="$(sha256sum < "${E5k}")"
out5k="$(gen "${E5k}" 1 --print 2>/dev/null)"
if [ "${out5k}" = operatorchosen1 ] && [ "$(sha256sum < "${E5k}")" = "${s5k}" ]; then ok "an operator-set valid key is used and the file is not rewritten"; else bad "an operator-set key was replaced or the file rewritten"; fi

echo "-- 5b) a symlinked .env stays a symlink; the shared target is updated --"
mkdir -p "${WORK}/shared" "${WORK}/co"
SL_T="${WORK}/shared/real.env"; SL="${WORK}/co/.env"
printf 'FOO=1\n' > "${SL_T}"; cp "${SL_T}" "${WORK}/real.orig"
ln -s ../shared/real.env "${SL}"
v5b="$(gen "${SL}" 0 --print 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -L "${SL}" ] && [ "$(readlink "${SL}")" = ../shared/real.env ]; then ok "ensure keeps .env a symlink (same relative target)"; else bad "ensure replaced the symlink (rc=${rc}, $( [ -L "${SL}" ] && echo link || echo regular-file))"; fi
if [ "$(file_val "${SL_T}")" = "${v5b}" ] && [ "$(head -1 "${SL_T}")" = FOO=1 ] && [ "$(stat -c %a "${SL_T}")" = 600 ]; then ok "the TARGET holds the key after the operator's line, mode 0600"; else bad "target not updated: mode $(stat -c %a "${SL_T}"), first line '$(head -1 "${SL_T}")'"; fi
if find "${WORK}/shared" "${WORK}/co" -name '*.tmp.*' | grep . >/dev/null; then bad "a temp file was left behind"; else ok "no temp file left in either directory"; fi
if [ "$(gen "${SL}" 0 --print 2>/dev/null)" = "${v5b}" ]; then ok "a second run through the link reads the same value (never rotated)"; else bad "a second run through the link rotated the value"; fi
gen "${SL}" 0 --remove >/dev/null 2>&1
if [ -L "${SL}" ] && cmp -s "${SL_T}" "${WORK}/real.orig"; then ok "--remove through the link strips only the key from the target, link kept"; else bad "--remove through the link: $( [ -L "${SL}" ] && echo link || echo NOT-a-link), target: $(tr '\n' '|' < "${SL_T}")"; fi
: > "${SL_T}"; gen "${SL}" 0 >/dev/null 2>&1; gen "${SL}" 0 --remove >/dev/null 2>&1
if [ -L "${SL}" ] && [ -e "${SL_T}" ] && ! grep '[^[:space:]]' "${SL_T}" >/dev/null; then ok "--remove of a key-only shared target empties it, never deletes it or the link"; else bad "--remove deleted the shared target or the link, or left the key"; fi
CH="${WORK}/co/chain.env"; ln -s .env "${CH}"
gen "${CH}" 0 >/dev/null 2>&1
if [ -L "${CH}" ] && [ -L "${SL}" ] && [[ "$(file_val "${SL_T}")" =~ ^[0-9a-f]{48}$ ]]; then ok "a chain of links resolves to the final target"; else bad "a chain of links was not followed"; fi
DG="${WORK}/co/dangling.env"; ln -s "${WORK}/nowhere/x.env" "${DG}"
gen "${DG}" 0 >/dev/null 2>&1; rc=$?
if [ "${rc}" -ne 0 ] && [ -L "${DG}" ] && [ ! -e "${WORK}/nowhere" ]; then ok "a link into a missing directory fails (rc=${rc}) and writes nothing"; else bad "dangling link into a missing dir: rc=${rc}"; fi
DN="${WORK}/co/new.env"; ln -s ../shared/new.env "${DN}"
gen "${DN}" 0 >/dev/null 2>&1; rc=$?
if [ "${rc}" -eq 0 ] && [ -L "${DN}" ] && [ -f "${WORK}/shared/new.env" ]; then ok "a link to a not-yet-existing file creates the target, link kept"; else bad "link to a new file: rc=${rc}"; fi

echo "-- 6) compose.local.yaml spells no route-access-db password --"
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
for f in tests/stack/.env tests/stack/.route-access-db.env; do
  if git -C "${REPO}" check-ignore -q "${f}"; then ok "${f} is gitignored"; else bad "${f} is NOT gitignored"; fi
done
if grep -q 'ROUTE_ACCESS_DB_ENV:-${HERE}/.env}' "${GEN}"; then ok "the generator's default file is tests/stack/.env (compose's auto-loaded file)"; else bad "the generator does not default to tests/stack/.env"; fi

echo "-- 6b) an EMPTY value fails loud instead of running the gateways without it --"
python3 - "${COMPOSE}" "${WORK}/check.sh" > "${WORK}/loud.kv" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
def block(name):
    m = re.search(r"\n  " + re.escape(name) + r":\n(.*?)(?=\n  [A-Za-z0-9][A-Za-z0-9_.-]*:\n|\nvolumes:)", s, re.S)
    return m.group(1) if m else ""
# Code lines only: the comment block above the NEXT service sits inside this span.
chk = "\n".join(l for l in block("route-access-env-check").splitlines()
                if not l.lstrip().startswith("#"))
print("check=" + ("yes" if chk else "no"))
print("restart_no=" + ("yes" if re.search(r'^    restart:\s*"no"', chk, re.M) else "no"))
print("set_only=" + ("yes" if "ROUTE_ACCESS_DB_PASSWORD_SET: ${ROUTE_ACCESS_DB_PASSWORD:+yes}" in chk
                     and "${ROUTE_ACCESS_DB_PASSWORD:-" not in chk
                     and "${ROUTE_ACCESS_DB_PASSWORD}" not in chk else "no"))
names = re.findall(r"^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*$", s, re.M)
consumers = sorted(n for n in set(names) if "ROUTE_ACCESS_R2DBC_URL:" in block(n))
print("consumers=" + ",".join(consumers))
dep = "route-access-env-check: { condition: service_completed_successfully }"
print("missing_dep=" + ",".join(n for n in consumers + ["route-access-db"] if dep not in block(n)))
guard = ('JAVA_TOOL_OPTIONS: "-${ROUTE_ACCESS_DB_PASSWORD:+Dhugmesh.guard.}'
         'XX:+ROUTE_ACCESS_DB_PASSWORD_REQUIRED.see.tests/stack/gen-route-access-env.sh"')
print("missing_guard=" + ",".join(n for n in consumers if guard not in block(n)))
print("guards=" + str(s.count(guard)))
print("leaky=" + str(sum(1 for l in s.splitlines()
                         if "JAVA_TOOL_OPTIONS:" in l and re.search(r"\$\{ROUTE_ACCESS_DB_PASSWORD(:?-|\})", l))))
m = re.search(r"\n    command:\n      - \|\n((?:        [^\n]*\n)+)", chk)
body = "".join(l[8:] + "\n" for l in (m.group(1).splitlines() if m else []))
open(sys.argv[2], "w", encoding="utf-8").write(body.replace("$$", "$"))
PY
kv() { sed -n "s/^$1=//p" "${WORK}/loud.kv"; }
if [ "$(kv check)" = yes ] && [ "$(kv restart_no)" = yes ]; then ok "a route-access-env-check one-shot (restart: \"no\") exists"; else bad "no route-access-env-check one-shot (check=$(kv check), restart_no=$(kv restart_no))"; fi
if [ "$(kv set_only)" = yes ]; then ok "the check only sees whether the value is set (:+), never the value"; else bad "the check service can see the password value"; fi
if [ "$(kv consumers)" = "hugmesh-admin-bff-api,hugmesh-be-gateway,hugmesh-fe-gateway,hugmesh-pki-gateway" ]; then ok "the four ROUTE_ACCESS_R2DBC_URL consumers are found"; else bad "consumers found: '$(kv consumers)'"; fi
if [ -z "$(kv missing_dep)" ]; then ok "route-access-db and all four consumers depend on the check completing"; else bad "missing the check dependency: $(kv missing_dep)"; fi
if [ -z "$(kv missing_guard)" ] && [ "$(kv guards)" = 4 ]; then ok "all four consumers carry the JAVA_TOOL_OPTIONS start guard"; else bad "start guard missing on: '$(kv missing_guard)' ($(kv guards) guards)"; fi
if [ "$(kv leaky)" = 0 ]; then ok "no JAVA_TOOL_OPTIONS can carry the password (only :+ is used)"; else bad "$(kv leaky) JAVA_TOOL_OPTIONS line(s) interpolate the value itself"; fi
ck_out="$(ROUTE_ACCESS_DB_PASSWORD_SET= sh "${WORK}/check.sh" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -F 'bash tests/stack/gen-route-access-env.sh' <<<"${ck_out}" >/dev/null; then ok "the check's script, value EMPTY: exits 1 and names the generator command"; else bad "check script with an empty value: rc=${rc}, out: $(head -2 <<<"${ck_out}" | tr '\n' '|')"; fi
ROUTE_ACCESS_DB_PASSWORD_SET=yes sh "${WORK}/check.sh" >/dev/null 2>&1; rc=$?
if [ "${rc}" -eq 0 ]; then ok "the check's script, value set: exits 0"; else bad "check script with a value: rc=${rc}"; fi
if docker compose version >/dev/null 2>&1; then
  # compose renders without a daemon. Empty: the four consumers get the failing JVM
  # option. Set: the no-op property, and the value reaches neither guard.
  r_empty="$(cd "${WORK}" && ROUTE_ACCESS_DB_PASSWORD= docker compose -p ra-guard-test -f "${COMPOSE}" config 2>/dev/null)"
  r_set="$(cd "${WORK}" && ROUTE_ACCESS_DB_PASSWORD=feedc0de0123 docker compose -p ra-guard-test -f "${COMPOSE}" config 2>/dev/null)"
  n_bad="$(grep -c 'JAVA_TOOL_OPTIONS: -XX:+ROUTE_ACCESS_DB_PASSWORD_REQUIRED' <<<"${r_empty}")"
  n_ok="$(grep -c 'JAVA_TOOL_OPTIONS: -Dhugmesh.guard.XX:+ROUTE_ACCESS_DB_PASSWORD_REQUIRED' <<<"${r_set}")"
  if [ "${n_bad}" = 4 ] && [ "${n_ok}" = 4 ]; then ok "compose renders the failing JVM option when empty (4) and the no-op property when set (4)"; else bad "rendered guards: empty ${n_bad}/4, set ${n_ok}/4"; fi
  if grep -E 'JAVA_TOOL_OPTIONS|ROUTE_ACCESS_DB_PASSWORD_SET' <<<"${r_set}" | grep -F feedc0de0123 >/dev/null; then bad "the value leaked into JAVA_TOOL_OPTIONS or the check"; else ok "the set value reaches neither JAVA_TOOL_OPTIONS nor the check"; fi
else
  skip "docker compose is not installed: the guard was parsed, not rendered"
fi

echo "-- 7) Makefile wiring --"
MK="${REPO}/Makefile"
# Static: a target whose recipe CREATES containers (`compose … up`) depends on the
# ensure step; a target that only reads (ps, logs, halt, down, …) must NOT, so that
# looking at a stack never mints or adopts a password (or probes docker for one).
wiring="$(python3 - "${MK}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
creators, missing, readers, extra = 0, [], 0, []
for m in re.finditer(r"^([A-Za-z0-9_.-]+):([^=\n][^\n]*)\n((?:\t[^\n]*\n|[ \t]*#[^\n]*\n)*)", s, re.M):
    name, prereqs, body = m.group(1), m.group(2).split("##")[0].split(), m.group(3)
    if name.startswith("."):
        continue
    rec = [ln for ln in body.splitlines() if ln.startswith("\t")]
    if not any("$(STACK_ENV)" in ln for ln in rec):
        continue
    if any(re.search(r"\$\(COMPOSE_CMD\).*\s(up|run|create)(\s|$)", ln) for ln in rec):
        creators += 1
        if "stack-route-access-env" not in prereqs:
            missing.append(name)
    else:
        readers += 1
        if "stack-route-access-env" in prereqs:
            extra.append(name)
print(creators, readers)
print(" ".join(missing))
print(" ".join(extra))
PY
)"
counts="$(sed -n 1p <<<"${wiring}")"; miss="$(sed -n 2p <<<"${wiring}")"; extra="$(sed -n 3p <<<"${wiring}")"
if [ "${counts%% *}" -ge 1 ] && [ -z "${miss}" ]; then ok "every container-creating STACK_ENV target (${counts%% *}) depends on stack-route-access-env"; else bad "creating targets: ${counts%% *}; missing the ensure prerequisite: ${miss:-?}"; fi
if [ "${counts##* }" -ge 7 ] && [ -z "${extra}" ]; then ok "none of the ${counts##* } read-only STACK_ENV targets runs the generator"; else bad "read-only targets: ${counts##* }; run the generator anyway: ${extra:-?}"; fi
if grep -qE '^stack-route-access-env:' "${MK}" && awk '/^stack-route-access-env:/{s=1;next} s&&/^\t/{sub(/^\t/,"");print;exit}' "${MK}" | grep -E '^@?bash tests/stack/gen-route-access-env\.sh$' >/dev/null; then ok "the ensure step runs the generator as its own (status-checked) recipe line"; else bad "stack-route-access-env does not run the generator as a plain recipe line"; fi
if command -v make >/dev/null 2>&1; then
  up="$(cd "${REPO}" && timeout 60 make -n -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env stack-up 2>/dev/null)"
  sub='ROUTE_ACCESS_DB_PASSWORD="$(bash tests/stack/gen-route-access-env.sh --read)"'
  n_compose="$(grep -c ' compose -f tests/stack/compose.local.yaml' <<<"${up}")"
  n_sub="$(grep ' compose -f tests/stack/compose.local.yaml' <<<"${up}" | grep -cF "${sub}")"
  if [ "${n_compose}" -ge 2 ] && [ "${n_sub}" -eq "${n_compose}" ]; then ok "every compose line of stack-up (${n_compose}) passes the value explicitly"; else bad "${n_sub} of ${n_compose} stack-up compose lines pass the value"; fi
  first_gen="$(grep -n '^bash tests/stack/gen-route-access-env.sh$' <<<"${up}" | head -1 | cut -d: -f1)"
  first_cmp="$(grep -n ' compose -f tests/stack/compose.local.yaml' <<<"${up}" | head -1 | cut -d: -f1)"
  if [ -n "${first_gen}" ] && [ -n "${first_cmp}" ] && [ "${first_gen}" -lt "${first_cmp}" ]; then ok "make -n stack-up runs the ensure step before the first compose call"; else bad "ensure step at '${first_gen:-none}', first compose at '${first_cmp:-none}'"; fi
  if grep 'route-access-reconcile.sh' <<<"${up}" | grep -F "${sub}" >/dev/null; then ok "the route-access reconcile step carries it too"; else bad "the reconcile step does not carry ROUTE_ACCESS_DB_PASSWORD"; fi
  if grep -qE 'ROUTE_ACCESS_DB_PASSWORD=[0-9a-f]{16,}' <<<"${up}"; then bad "make -n prints a password VALUE"; else ok "make -n prints the substitution, never a value"; fi
  for tgt in stack-down stack-clean; do
    rec="$(cd "${REPO}" && timeout 60 make -n "${tgt}" 2>/dev/null)"
    dv="$(grep -n 'down -v' <<<"${rec}" | head -1 | cut -d: -f1)"
    rm_="$(grep -n 'gen-route-access-env.sh --remove' <<<"${rec}" | head -1 | cut -d: -f1)"
    if [ -n "${dv}" ] && [ -n "${rm_}" ] && [ "${rm_}" -gt "${dv}" ]; then ok "${tgt} strips the key (--remove) after down -v"; else bad "${tgt}: down -v at '${dv:-none}', --remove at '${rm_:-none}'"; fi
  done
  if grep -q 'rm -f tests/stack/.env' <<<"${rec}"; then bad "stack-clean deletes tests/stack/.env wholesale (an operator's other lines)"; else ok "nothing deletes tests/stack/.env wholesale"; fi
  halt="$(cd "${REPO}" && timeout 60 make -n stack-halt 2>/dev/null)"
  if grep -q -- '--remove' <<<"${halt}"; then bad "stack-halt strips the key (it keeps the volume)"; else ok "stack-halt keeps the key (it keeps the volume)"; fi

  # Behavioural: run REAL make on stack-ps with a recording compose stub and the
  # docker stub, the env file redirected into WORK. Nothing reaches a daemon.
  cat > "${WORK}/bin/compose-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${ROUTE_ACCESS_DB_PASSWORD-<unset>}" >> "${COMPOSE_STUB_LOG}"
EOF
  chmod +x "${WORK}/bin/compose-stub"
  E7="${WORK}/make.env"; L7="${WORK}/compose.log"; : > "${L7}"
  mk7() { # mk7 <volume-state> <make args…> : real make, env file in WORK, stubs only
    local v="$1"; shift
    (cd "${REPO}" && ROUTE_ACCESS_DB_ENV="${E7}" ROUTE_ACCESS_DB_LEGACY_ENV="${E7}.legacy" \
       DOCKER="${WORK}/bin/docker" STUB_VOLUME_EXISTS="${v}" COMPOSE_STUB_LOG="${L7}" ROUTE_ACCESS_DB_PASSWORD= \
       timeout 60 make --no-print-directory "$@" COMPOSE_CMD="${WORK}/bin/compose-stub")
  }
  mk7 down -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env stack-up >/dev/null 2>&1; rc=$?
  if [ "${rc}" -ne 0 ] && [ ! -s "${L7}" ] && [ ! -e "${E7}" ]; then ok "generator failure (daemon unreachable) STOPS make stack-up (rc=${rc}) before compose runs"; else bad "generator failure: make stack-up rc=${rc}, compose ran $(wc -l < "${L7}") time(s)"; fi
  : > "${WORK}/log7"
  STUB_LOG="${WORK}/log7" mk7 1 stack-ps >/dev/null 2>&1; rc=$?
  if [ "${rc}" -eq 0 ] && [ ! -e "${E7}" ] && [ ! -s "${WORK}/log7" ] && [ "$(cat "${L7}")" = "" ]; then ok "a read-only target (stack-ps) with no key: no file written, docker never asked, compose ran with an empty value"; else bad "stack-ps with no key: rc=${rc}, file $( [ -e "${E7}" ] && echo WRITTEN || echo absent), docker calls $(wc -l < "${WORK}/log7")"; fi
  : > "${L7}"
  mk7 0 stack-route-access-env >/dev/null 2>&1
  mk7 0 stack-ps >"${WORK}/make7.out" 2>&1; rc=$?
  v7="$(file_val "${E7}" 2>/dev/null)"
  if [ "${rc}" -eq 0 ] && [[ "${v7}" =~ ^[0-9a-f]{48}$ ]] && [ "$(cat "${L7}")" = "${v7}" ]; then ok "with the key present, compose got exactly the file's value, even with an EMPTY one exported in the shell"; else bad "key present: rc=${rc}, compose saw len $(head -c 200 "${L7}" | wc -c), file len ${#v7}"; fi
  if grep -qF "${v7:-no-value}" "${WORK}/make7.out"; then bad "make's output echoes the password value"; else ok "make's own output never contains the value"; fi
else
  bad "make is not installed — section 7 asserted nothing"
fi

echo "-- 8) Windows path (scripts/stack-up.ps1) --"
PS1="${REPO}/scripts/stack-up.ps1"
if grep -q "Join-Path \$StackDir '.env'" "${PS1}" && grep -q '\$env:ROUTE_ACCESS_DB_PASSWORD = \$routeAccessPw' "${PS1}"; then
  ok "stack-up.ps1 reads tests\\stack\\.env and exports ROUTE_ACCESS_DB_PASSWORD"
else
  bad "stack-up.ps1 does not thread ROUTE_ACCESS_DB_PASSWORD from tests\\stack\\.env"
fi
if grep -q 'RandomNumberGenerator' "${PS1}"; then ok "stack-up.ps1 mints with a CSPRNG"; else bad "stack-up.ps1 does not use a CSPRNG"; fi
if grep -qF "$(sed -n 's/^BEGIN_MARK="\(.*\)"$/\1/p' "${GEN}")" "${PS1}" && grep -qF "$(sed -n 's/^END_MARK="\(.*\)"$/\1/p' "${GEN}")" "${PS1}"; then ok "stack-up.ps1 writes the same block markers as the generator"; else bad "stack-up.ps1's block markers drifted from the generator's"; fi
if command -v pwsh >/dev/null 2>&1; then
  # Run the ps1's route-access block (from its first line to the clone step) with
  # docker replaced by a PowerShell function, in a scratch StackDir.
  python3 - "${PS1}" "${WORK}/ra-block.ps1" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
a = s.index("# route-access-db OWNER password: compose.local.yaml reads")
b = s.index("# ── 1. Clone / update all repos")
open(sys.argv[2], "w", encoding="utf-8").write(s[a:b])
PY
  cat > "${WORK}/harness.ps1" <<'EOF'
param([string]$StackDir, [string]$Mode, [string]$CtrPw, [switch]$Down)
$ErrorActionPreference = 'Stop'
$Compose = Join-Path $StackDir 'compose.local.yaml'
function docker {
  $a = $args -join ' '
  if ($a -like 'volume inspect*') {
    if ($Mode -eq 'exists') { $global:LASTEXITCODE = 0; return '[{}]' }
    $global:LASTEXITCODE = 1; return 'Error response from daemon: get x: no such volume'
  }
  if ($a -like 'ps -a*') { $global:LASTEXITCODE = 0; if ($CtrPw) { return 'c0ffee' }; return }
  if ($a -like 'inspect -f*') { $global:LASTEXITCODE = 0; return @('PATH=/x', "POSTGRES_PASSWORD=$CtrPw") }
  if ($a -like 'compose*down -v') { $global:LASTEXITCODE = 0; return }
  throw "unexpected docker $a"
}
. (Join-Path $PSScriptRoot 'ra-block.ps1')
if (-not $Down) { Write-Output "PW=$env:ROUTE_ACCESS_DB_PASSWORD" }
EOF
  SD="${WORK}/ps-stack"; mkdir -p "${SD}"
  printf '# mine\nPUBLIC_HOST_PORT=9999\n' > "${SD}/.env"; cp "${SD}/.env" "${WORK}/ps.orig"
  o="$(pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode absent 2>&1)"
  pv="$(file_val "${SD}/.env")"
  if [[ "${pv}" =~ ^[0-9a-f]{48}$ ]] && grep -qx "PW=${pv}" <<<"${o}" && head -2 "${SD}/.env" | cmp -s - "${WORK}/ps.orig"; then ok "pwsh: fresh value merged after the operator's lines and exported"; else bad "pwsh fresh: $(head -3 <<<"${o}" | tr '\n' '|')"; fi
  if head -c3 "${SD}/.env" | od -An -tx1 | grep 'ef bb bf' >/dev/null; then bad "pwsh wrote a UTF-8 BOM (compose would misread the first key)"; else ok "pwsh writes no BOM"; fi
  pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode absent -Down >/dev/null 2>&1
  if cmp -s <(tr -d '\r' < "${SD}/.env") "${WORK}/ps.orig"; then ok "pwsh -Down strips only the key"; else bad "pwsh -Down left: $(tr '\n' '|' < "${SD}/.env")"; fi
  rm -f "${SD}/.env"
  o="$(pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode exists -CtrPw "${ctr_pw}" 2>&1)"
  if grep -qx "PW=${ctr_pw}" <<<"${o}"; then ok "pwsh: adopts the existing container's password"; else bad "pwsh container adoption: $(head -3 <<<"${o}" | tr '\n' '|')"; fi
  rm -f "${SD}/.env"
  o="$(pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode exists 2>&1)"
  if grep -qx "PW=${owner}" <<<"${o}"; then ok "pwsh: no container left -> the pre-2026-10-29 default"; else bad "pwsh role-name adoption: $(head -3 <<<"${o}" | tr '\n' '|')"; fi
  # A symlinked .env (shared by checkouts): the TARGET gets the key, the link survives,
  # -Down strips only the key and empties (never deletes) a key-only shared target.
  rm -f "${SD}/.env"; mkdir -p "${WORK}/ps-shared"
  printf '# shared\nPUBLIC_HOST_PORT=9999\n' > "${WORK}/ps-shared/real.env"; cp "${WORK}/ps-shared/real.env" "${WORK}/ps-shared.orig"
  ln -s ../ps-shared/real.env "${SD}/.env"
  o="$(pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode absent 2>&1)"
  pv="$(file_val "${WORK}/ps-shared/real.env")"
  if [ -L "${SD}/.env" ] && [ "$(readlink "${SD}/.env")" = ../ps-shared/real.env ] && [[ "${pv}" =~ ^[0-9a-f]{48}$ ]] && grep -qx "PW=${pv}" <<<"${o}"; then ok "pwsh: a symlinked .env stays a link and its target gets the key"; else bad "pwsh symlink: $( [ -L "${SD}/.env" ] && echo link || echo NOT-a-link), $(head -3 <<<"${o}" | tr '\n' '|')"; fi
  if find "${SD}" "${WORK}/ps-shared" -name '*.tmp.*' | grep . >/dev/null; then bad "pwsh left a temp file behind"; else ok "pwsh leaves no temp file"; fi
  pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode absent -Down >/dev/null 2>&1
  if [ -L "${SD}/.env" ] && cmp -s <(tr -d '\r' < "${WORK}/ps-shared/real.env") "${WORK}/ps-shared.orig"; then ok "pwsh -Down through the link strips only the key, link kept"; else bad "pwsh -Down through the link: $( [ -L "${SD}/.env" ] && echo link || echo NOT-a-link)"; fi
  : > "${WORK}/ps-shared/real.env"
  pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode absent >/dev/null 2>&1
  pwsh -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode absent -Down >/dev/null 2>&1
  if [ -L "${SD}/.env" ] && [ -e "${WORK}/ps-shared/real.env" ] && ! grep '[^[:space:]]' "${WORK}/ps-shared/real.env" >/dev/null; then ok "pwsh -Down of a key-only shared target empties it, never deletes it"; else bad "pwsh -Down deleted the shared target or the link, or left the key"; fi
else
  skip "pwsh is not installed: stack-up.ps1's block was only grepped, not run"
fi

echo "== RESULT: ${P} passed, ${F} failed, ${S} skipped =="
[ "${F}" -eq 0 ]
