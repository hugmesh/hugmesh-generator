#!/usr/bin/env bash
# test-gen-stack-db-env.sh — the local stack's per-role DB passwords are generated per
# checkout, never spelled in a committed compose file, and an EXISTING volume keeps
# the value it was initialised with.
#
# hugmesh-generator#857: tests/stack/compose*.yaml spelled 28 password values, 26 of
# them equal to the role's own name. They now read ${KEY:?...} from the gitignored
# tests/stack/.env, which tests/stack/gen-stack-db-env.sh writes (keys:
# tests/stack/stack-db-passwords.tsv). The literal-value scan itself is
# tests/scripts/test-compose-no-literal-passwords.sh; this suite proves the resolver
# and its wiring.
#
# Proves, with no docker daemon and no network (a docker STUB answers the volume and
# container probes; a compose STUB records what make runs):
#   (1) a fresh checkout gets one 48-hex value PER KEY in a 0600 file, every key
#       distinct, and nothing secret is printed;
#   (2) CREATE, NEVER ROTATE: a second run leaves the file byte-identical, and a key
#       already present wins over any adoption path;
#   (3) a missing key next to an EXISTING volume adopts the value its container was
#       created with, else the pre-2026-11-04 literal from the table; the warning goes
#       to stderr and never carries the value; keys whose volumes do not exist still
#       get fresh values in the same run;
#   (3b) docker that cannot answer writes NOTHING and fails;
#   (4) a value a connection string would read differently is refused (in the file
#       and from a container); dotenv `export` and quotes are read as compose reads them;
#   (5) the file is SHARED: an operator's lines and gen-route-access-env.sh's block
#       survive every write and --remove; --remove deletes the file only when nothing
#       else is left; a symlinked .env stays a link;
#   (6) --read is READ ONLY (never writes, never asks docker); --keys lists the table;
#       --rotate-sql prints steps but no value;
#   (7) the table and the compose files agree: every ${KEY:?} the compose files read
#       is a table key and every table key is read; each row's service sets its
#       ctr_env from that same key and mounts the row's volume (so adoption reads
#       the right container); no ${KEY:-literal} fallback is left;
#   (8) the Makefile: every target that builds, creates, stops or writes to the
#       stack depends on the stack-db-env ensure step, and the read-only ones
#       (ps/logs/onion) do not; STACK_ENV passes every key; stack-down/stack-clean
#       strip the keys only AFTER `down -v`; BEHAVIOURALLY a resolver failure stops
#       make stack-up before compose runs, and compose gets exactly the file's value;
#   (9) with docker compose installed: compose.local.yaml renders with a generated
#       .env and FAILS without one, naming the resolver (SKIP when compose is absent;
#       (7) pins the same property statically);
#   (10) scripts/stack-up.ps1 (the Windows path, no make, no bash) resolves the same
#       keys; with pwsh on PATH its block is RUN against a stub docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GEN="${HERE}/gen-stack-db-env.sh"
TABLE="${HERE}/stack-db-passwords.tsv"

P=0; F=0; S=0
ok()   { echo "  ok   $*"; P=$((P + 1)); }
bad()  { echo "  FAIL $*"; F=$((F + 1)); }
skip() { echo "  SKIP $*"; S=$((S + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
[ -f "${GEN}" ] && [ -f "${TABLE}" ] || { echo "  FAIL ${GEN} or ${TABLE} missing"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mapfile -t KEYS < <(bash "${GEN}" --keys)
NK="${#KEYS[@]}"

# A docker stub. STUB_VOLUMES: space-separated volume names that exist ("down" = the
# daemon cannot be reached). STUB_CTR_<service with - as _>=<value>: that compose
# service's container exists in project STUB_PROJECT (default hugmesh-local) and was
# created with <ctr_env>=<value>; "<none>" = it exists without that variable. Every
# call is logged to STUB_LOG when set.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_LOG:-}" ] || echo "docker $*" >> "${STUB_LOG}"
if [ "${STUB_VOLUMES:-}" = down ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1
fi
case "$1 $2" in
  "volume inspect")
    case " ${STUB_VOLUMES:-} " in *" $3 "*) echo '[{"Name": "x"}]'; exit 0 ;; esac
    echo "Error response from daemon: get $3: no such volume" >&2; exit 1 ;;
  "ps -a")
    proj=""; svc=""
    for a in "$@"; do
      case "${a}" in
        label=com.docker.compose.project=*) proj="${a#label=com.docker.compose.project=}" ;;
        label=com.docker.compose.service=*) svc="${a#label=com.docker.compose.service=}" ;;
      esac
    done
    [ "${proj}" = "${STUB_PROJECT:-hugmesh-local}" ] || exit 0
    var="STUB_CTR_$(printf '%s' "${svc}" | tr -- '-' '_')"
    [ -n "${!var+x}" ] && echo "cid-${svc}"
    exit 0 ;;
  "inspect -f")
    svc="${4#cid-}"
    var="STUB_CTR_$(printf '%s' "${svc}" | tr -- '-' '_')"
    envname="${STUB_CTR_ENV:-POSTGRES_PASSWORD}"
    printf 'PATH=/usr/bin\nPOSTGRES_USER=x\n'
    [ "${!var}" = "<none>" ] || printf '%s=%s\n' "${envname}" "${!var}"
    exit 0 ;;
esac
exit 99
EOF
chmod +x "${WORK}/bin/docker"

gen() { # gen <env-file> [args] : the resolver against the stub; env passes through
  STACK_DB_ENV_FILE="$1" DOCKER="${WORK}/bin/docker" bash "${GEN}" "${@:2}"
}
val() { sed -n "s/^$2=//p" "$1" | tail -1; }
row() { awk -F'\t' -v k="$1" '$1 == k' "${TABLE}"; }

echo "== local stack DB passwords: generated per checkout, adopted for existing volumes =="

echo "-- 1) fresh checkout: one random value per key, 0600, nothing printed --"
if [ "${NK}" -ge 14 ]; then ok "${NK} keys in the table"; else bad "only ${NK} keys in the table (expected >= 14)"; fi
E1="${WORK}/fresh.env"
gen "${E1}" >"${WORK}/out1" 2>"${WORK}/err1"; rc=$?
nhex=0; for k in "${KEYS[@]}"; do [[ "$(val "${E1}" "${k}")" =~ ^[0-9a-f]{48}$ ]] && nhex=$((nhex + 1)); done
if [ "${rc}" -eq 0 ] && [ "${nhex}" -eq "${NK}" ]; then ok "every key (${NK}) holds a 48-hex value"; else bad "rc=${rc}: ${nhex} of ${NK} keys hold a 48-hex value"; fi
ndist="$(for k in "${KEYS[@]}"; do val "${E1}" "${k}"; echo; done | sort -u | grep -c .)"
if [ "${ndist}" -eq "${NK}" ]; then ok "all ${NK} values are distinct (no shared password across roles)"; else bad "only ${ndist} distinct values for ${NK} keys"; fi
mode="$(stat -c %a "${E1}" 2>/dev/null)"
if [ "${mode}" = 600 ]; then ok "file mode is 0600"; else bad "file mode is ${mode:-missing}, want 600"; fi
leak=0; for k in "${KEYS[@]}"; do v="$(val "${E1}" "${k}")"; grep -qF "${v}" "${WORK}/out1" "${WORK}/err1" && leak=1; done
if [ "${leak}" -eq 0 ] && [ ! -s "${WORK}/err1" ]; then ok "no value reaches stdout/stderr, and a fresh run is silent on stderr"; else bad "a value was printed, or stderr was not empty: $(head -1 "${WORK}/err1")"; fi
E1b="${WORK}/fresh2.env"; gen "${E1b}" >/dev/null 2>&1
if [ "$(val "${E1b}" FEDERATION_DB_PASSWORD)" != "$(val "${E1}" FEDERATION_DB_PASSWORD)" ]; then ok "two checkouts get different values"; else bad "two fresh runs minted the SAME value"; fi
legacy_hit=0
while IFS=$'\t' read -r k _ _ _ l; do
  case "${k}" in ""|\#*) continue ;; esac
  [ "$(val "${E1}" "${k}")" = "${l}" ] && legacy_hit=1
done < "${TABLE}"
if [ "${legacy_hit}" -eq 0 ]; then ok "no fresh value equals its legacy literal (the role name)"; else bad "a fresh volume got the legacy literal"; fi

echo "-- 2) create, never rotate --"
sum="$(sha256sum < "${E1}")"
gen "${E1}" >/dev/null 2>&1
if [ "$(sha256sum < "${E1}")" = "${sum}" ]; then ok "second run leaves the file byte-identical"; else bad "second run rewrote the file"; fi
STUB_VOLUMES="hugmesh-local_federation-pg" STUB_CTR_federation_db=ffffffff gen "${E1}" >/dev/null 2>&1
if [ "$(sha256sum < "${E1}")" = "${sum}" ]; then ok "a key already present wins over adoption (volume + container present)"; else bad "a present key was replaced because a volume exists"; fi

echo "-- 3) existing volumes keep the value they were initialised with --"
E3="${WORK}/adopt.env"
ctr_pw="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718"
STUB_VOLUMES="hugmesh-local_federation-pg hugmesh-local_admin-bff-pg hugmesh-local_tuwunel" \
  STUB_CTR_federation_db="${ctr_pw}" \
  gen "${E3}" >"${WORK}/out3" 2>"${WORK}/err3"; rc=$?
fed="$(val "${E3}" FEDERATION_DB_PASSWORD)"; adm="$(val "${E3}" ADMIN_BFF_DB_PASSWORD)"
svc="$(val "${E3}" SVC_PASSWORD)"; fbf="$(val "${E3}" FORUM_BFF_DB_PASSWORD)"
if [ "${rc}" -eq 0 ] && [ "${fed}" = "${ctr_pw}" ]; then ok "federation-pg exists + container present: adopted the container's POSTGRES_PASSWORD"; else bad "rc=${rc}: container value not adopted"; fi
if [ "${adm}" = "$(row ADMIN_BFF_DB_PASSWORD | cut -f5)" ]; then ok "admin-bff-pg exists, no container left: adopted the pre-2026-11-04 literal from the table"; else bad "legacy literal not adopted for an orphaned volume"; fi
if [ "${svc}" = "$(row SVC_PASSWORD | cut -f5)" ]; then ok "SVC_PASSWORD: the tuwunel volume exists -> the old broker password is kept"; else bad "SVC_PASSWORD was minted although the tuwunel volume exists"; fi
if [[ "${fbf}" =~ ^[0-9a-f]{48}$ ]]; then ok "a key whose volume does not exist still gets a fresh value in the same run"; else bad "forum-bff (no volume) did not get a fresh value"; fi
nwarn="$(grep -c '^WARNING' "${WORK}/err3")"
if [ "${nwarn}" -eq 3 ] && ! grep -qF "${ctr_pw}" "${WORK}/err3" "${WORK}/out3"; then ok "3 adoption warnings on stderr, none carries the value"; else bad "warnings: ${nwarn} (want 3), or a value was echoed"; fi
if grep -q -- '--rotate-sql' "${WORK}/err3"; then ok "the warning names the rotation one-shot"; else bad "the warning does not say how to rotate"; fi
# A legacy-literal adoption is only right for a pre-2026-11-04 volume: a later volume
# whose .env line was lost gets locked out, so that warning must not promise the
# stack keeps working, and must say to restore the value (measured in the PR #929
# review: a minted volume + a lost .env adopted the literal and auth failed).
n_restore="$(grep -c 'put that value back' "${WORK}/err3")"; n_keeps="$(grep -c 'keeps working as before' "${WORK}/err3")"
if [ "${n_restore}" -eq 2 ] && [ "${n_keeps}" -eq 1 ]; then ok "the 2 legacy-literal adoptions say to restore a lost generated value; only the container adoption says the stack keeps working"; else bad "restore hints ${n_restore} (want 2), 'keeps working' ${n_keeps} (want 1, the container adoption)"; fi
if grep -q '^# FEDERATION_DB_PASSWORD: adopted from the existing' "${E3}" && grep -q '^# ADMIN_BFF_DB_PASSWORD: adopted: volume' "${E3}"; then ok "the file records where each adopted value came from"; else bad "adoption origin not recorded"; fi
E3p="${WORK}/proj.env"
STUB_PROJECT=hugmesh-real STACK_DB_PROJECT=hugmesh-real STUB_VOLUMES="hugmesh-real_casdoor-pg" STUB_CTR_casdoor_db="${ctr_pw}" \
  gen "${E3p}" >/dev/null 2>&1
if [ "$(val "${E3p}" CASDOOR_DB_PASSWORD)" = "${ctr_pw}" ]; then ok "STACK_DB_PROJECT picks the project probed (up-real.sh's hugmesh-real)"; else bad "STACK_DB_PROJECT=hugmesh-real did not adopt from that project"; fi
E3n="${WORK}/nopw.env"
STUB_VOLUMES="hugmesh-local_wiki-bff-pg" STUB_CTR_wiki_bff_db="<none>" gen "${E3n}" >/dev/null 2>"${WORK}/err3n"
if [ "$(val "${E3n}" WIKI_BFF_DB_PASSWORD)" = "$(row WIKI_BFF_DB_PASSWORD | cut -f5)" ] && grep -q 'carries no POSTGRES_PASSWORD' "${WORK}/err3n"; then ok "a container WITHOUT the variable falls back to the legacy literal and says why"; else bad "container without POSTGRES_PASSWORD: $(head -1 "${WORK}/err3n")"; fi

echo "-- 3b) docker that cannot answer is not read as 'no volume' --"
E3d="${WORK}/down.env"
STUB_VOLUMES=down gen "${E3d}" >/dev/null 2>"${WORK}/err3d"; rc=$?
if [ "${rc}" -ne 0 ] && [ ! -e "${E3d}" ] && grep -q 'NOTHING was written' "${WORK}/err3d"; then ok "daemon unreachable: rc=${rc}, nothing written, the message says so"; else bad "daemon unreachable: rc=${rc}, file $( [ -e "${E3d}" ] && echo WRITTEN || echo absent)"; fi

echo "-- 4) values a connection string would read differently --"
E4="${WORK}/unsafe.env"
STUB_VOLUMES="hugmesh-local_federation-pg" STUB_CTR_federation_db='ab+cd' gen "${E4}" >/dev/null 2>&1; rc=$?
if [ "${rc}" -ne 0 ] && [ ! -e "${E4}" ]; then ok "an unsafe container value is refused, nothing written"; else bad "an unsafe container value was adopted (rc=${rc})"; fi
cp "${E1}" "${E4}"; sed -i 's/^TUBE_BFF_DB_PASSWORD=.*/TUBE_BFF_DB_PASSWORD=a b@c/' "${E4}"
gen "${E4}" >/dev/null 2>"${WORK}/err4"; rc=$?
if [ "${rc}" -ne 0 ] && grep -q 'TUBE_BFF_DB_PASSWORD' "${WORK}/err4" && ! grep -qF 'a b@c' "${WORK}/err4"; then ok "an unsafe value in the file is refused by name, not echoed"; else bad "unsafe file value: rc=${rc}"; fi
gen "${E4}" --read TUBE_BFF_DB_PASSWORD >/dev/null 2>&1; rc=$?
if [ "${rc}" -ne 0 ]; then ok "--read refuses it too"; else bad "--read passed an unsafe value"; fi
E4q="${WORK}/quoted.env"
printf 'export FEDERATION_DB_PASSWORD = "q1w2e3"\n' > "${E4q}"
gen "${E4q}" >/dev/null 2>&1
if [ "$(gen "${E4q}" --read FEDERATION_DB_PASSWORD)" = q1w2e3 ] && [ "$(grep -c FEDERATION_DB_PASSWORD= "${E4q}")" -eq 1 ]; then ok "an operator's \`export KEY = \"v\"\` is read as compose reads it, kept, and not duplicated"; else bad "dotenv quoting/export not honoured"; fi

echo "-- 5) the file is shared --"
E5="${WORK}/shared.env"
cat > "${E5}" <<'EOF'
# operator's own line
HUG_WEB_LOCALES=de,fr
# >>> route-access-db owner password (tests/stack/gen-route-access-env.sh) >>>
ROUTE_ACCESS_DB_PASSWORD=0123456789abcdef
# <<< route-access-db owner password <<<
EOF
cp "${E5}" "${WORK}/shared.orig"; chmod 644 "${E5}"
gen "${E5}" >/dev/null 2>&1
if head -5 "${E5}" | cmp -s - "${WORK}/shared.orig"; then ok "the operator's lines and the route-access block survive, ahead of ours"; else bad "other lines were changed"; fi
if [ "$(stat -c %a "${E5}")" = 600 ]; then ok "an operator-made 0644 file is tightened to 0600"; else bad "mode left at $(stat -c %a "${E5}")"; fi
gen "${E5}" --remove >/dev/null 2>&1
if cmp -s "${E5}" "${WORK}/shared.orig"; then ok "--remove strips only this script's block"; else bad "--remove left: $(tr '\n' '|' < "${E5}")"; fi
gen "${E1b}" --remove >/dev/null 2>&1
if [ ! -e "${E1b}" ]; then ok "--remove deletes a file that held only these keys"; else bad "--remove left a file holding nothing"; fi
mkdir -p "${WORK}/shared-dir" "${WORK}/co/tests"; printf 'OTHER=1\n' > "${WORK}/shared-dir/real.env"
ln -s ../shared-dir/real.env "${WORK}/co/link.env"
gen "${WORK}/co/link.env" >/dev/null 2>&1
if [ -L "${WORK}/co/link.env" ] && [[ "$(val "${WORK}/shared-dir/real.env" SVC_PASSWORD)" =~ ^[0-9a-f]{48}$ ]]; then ok "a symlinked .env stays a link and its target gets the keys"; else bad "symlink replaced or target not written"; fi
gen "${WORK}/co/link.env" --remove >/dev/null 2>&1
if [ -L "${WORK}/co/link.env" ] && [ "$(cat "${WORK}/shared-dir/real.env")" = "OTHER=1" ]; then ok "--remove through the link strips the keys, keeps link and target"; else bad "--remove through a link broke it"; fi
if find "${WORK}" -name '*.tmp.*' | grep . >/dev/null; then bad "a temp file was left behind"; else ok "no temp file left behind"; fi

echo "-- 6) --read / --keys / --rotate-sql --"
: > "${WORK}/log6"
E6="${WORK}/read.env"
o="$(STUB_LOG="${WORK}/log6" gen "${E6}" --read FEDERATION_DB_PASSWORD 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -z "${o}" ] && [ ! -e "${E6}" ] && [ ! -s "${WORK}/log6" ]; then ok "--read with no file: prints nothing, writes nothing, never asks docker"; else bad "--read side effects: rc=${rc}, docker calls $(wc -l < "${WORK}/log6")"; fi
if [ "$(gen "${E1}" --read ADMIN_BFF_DB_PASSWORD)" = "$(val "${E1}" ADMIN_BFF_DB_PASSWORD)" ]; then ok "--read prints exactly the stored value"; else bad "--read output differs from the file"; fi
gen "${E1}" --read NOT_A_KEY >/dev/null 2>&1; rc=$?
if [ "${rc}" -eq 2 ]; then ok "--read of an unknown key is a usage error"; else bad "--read NOT_A_KEY rc=${rc}"; fi
o="$(gen "${E1}" --rotate-sql ADMIN_BFF_DB_PASSWORD 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q 'ALTER ROLE CURRENT_USER PASSWORD' <<<"${o}" && grep -q 'service=admin-bff-db' <<<"${o}" && ! grep -qF "$(val "${E1}" ADMIN_BFF_DB_PASSWORD)" <<<"${o}"; then ok "--rotate-sql names the right container and the ALTER ROLE, never the value"; else bad "--rotate-sql output wrong (rc=${rc})"; fi
o="$(gen "${E1}" --rotate-sql SVC_PASSWORD 2>&1)"
if grep -q 'stack-down' <<<"${o}" && ! grep -q 'ALTER ROLE' <<<"${o}"; then ok "--rotate-sql SVC_PASSWORD says it is not a role password"; else bad "--rotate-sql SVC_PASSWORD offered an ALTER ROLE"; fi

echo "-- 7) the table and the compose files agree --"
parity="$(python3 - "${HERE}" "${TABLE}" <<'PY'
import glob, os, re, sys
stack, table = sys.argv[1], sys.argv[2]
rows = []
for ln in open(table, encoding="utf-8"):
    if not ln.strip() or ln.startswith("#"):
        continue
    k, svc, cenv, vols, legacy = ln.rstrip("\n").split("\t")
    rows.append((k, svc, cenv, vols.split(), legacy))
keys = {r[0] for r in rows}
used, fallbacks, wrongmsg = set(), [], []
texts = {}
for p in sorted(glob.glob(os.path.join(stack, "compose*.yaml"))):
    s = open(p, encoding="utf-8").read()
    texts[os.path.basename(p)] = s
    for m in re.finditer(r"\$\{([A-Z0-9_]+)(:?[?-])([^}]*)\}", s):
        name, op, rest = m.groups()
        if name in keys:
            if op.endswith("-"):
                fallbacks.append(f"{os.path.basename(p)}:{name}")
            elif "gen-stack-db-env.sh" not in rest:
                wrongmsg.append(f"{os.path.basename(p)}:{name}")
            used.add(name)
allt = "\n".join(texts.values())
bad_rows = []
for k, svc, cenv, vols, legacy in rows:
    # The service's blocks (an overlay file may name it again): from "  <svc>:" to
    # the next 2-space key. One of them must set ctr_env from the key.
    blks = [m.group(1) for m in re.finditer(r"(?m)^  " + re.escape(svc) + r":\n((?:(?:    |\s*\n|\s*#).*\n?)*)", allt)]
    if not blks:
        bad_rows.append(f"{k}: service {svc} not found"); continue
    if not any(re.search(r"(?<![A-Za-z0-9_])" + re.escape(cenv) + r":\s*\"?\$\{" + re.escape(k) + r":\?", b) for b in blks):
        bad_rows.append(f"{k}: {svc} does not set {cenv} from ${{{k}:?}}")
    for v in vols:
        if not re.search(r"(?m)^  " + re.escape(v) + r":", allt):
            bad_rows.append(f"{k}: volume {v} not declared")
print(len(keys), len(used))
print(" ".join(sorted(keys - used)))
print(" ".join(sorted(fallbacks)))
print(" ".join(sorted(wrongmsg)))
print(" | ".join(bad_rows))
PY
)"
counts="$(sed -n 1p <<<"${parity}")"; unused="$(sed -n 2p <<<"${parity}")"; fb="$(sed -n 3p <<<"${parity}")"
wm="$(sed -n 4p <<<"${parity}")"; br="$(sed -n 5p <<<"${parity}")"
if [ "${counts%% *}" = "${counts##* }" ] && [ -z "${unused}" ] && [ "${counts%% *}" -ge 14 ]; then ok "every table key (${counts%% *}) is read by a compose file"; else bad "keys ${counts%% *}, read ${counts##* }; unread: ${unused:-?}"; fi
if [ -z "${fb}" ]; then ok "no table key has a \${KEY:-fallback}"; else bad "fallbacks: ${fb}"; fi
if [ -z "${wm}" ]; then ok "every \${KEY:?} message names gen-stack-db-env.sh"; else bad "messages not naming the resolver: ${wm}"; fi
if [ -z "${br}" ]; then ok "each row's service sets its ctr_env from that key and its volumes exist (adoption reads the right container)"; else bad "${br}"; fi
undeclared="$(python3 - "${HERE}" "${TABLE}" <<'PY'
import glob, os, re, sys
keys = {l.split("\t")[0] for l in open(sys.argv[2], encoding="utf-8") if l.strip() and not l.startswith("#")}
known = keys | {"ROUTE_ACCESS_DB_PASSWORD"}
out = set()
for p in glob.glob(os.path.join(sys.argv[1], "compose*.yaml")):
    # (?<!\$): a $${VAR} is a shell variable inside a command, not compose's.
    for m in re.finditer(r"(?<!\$)\$\{([A-Z0-9_]*PASS[A-Z0-9_]*)[:?}+-]", open(p, encoding="utf-8").read()):
        if m.group(1) not in known and not m.group(1).endswith("_ENABLED"):
            out.add(m.group(1))
print(" ".join(sorted(out)))
PY
)"
if [ -z "${undeclared}" ]; then ok "no compose file reads a *PASS* variable the resolver does not own (or route-access)"; else bad "password variables nobody generates: ${undeclared}"; fi
if git -C "${REPO}" check-ignore -q tests/stack/.env 2>/dev/null; then ok "tests/stack/.env is gitignored"; else bad "tests/stack/.env is NOT gitignored"; fi

echo "-- 8) Makefile wiring --"
MK="${REPO}/Makefile"
wiring="$(python3 - "${MK}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
# A target that runs compose on the stack files with any verb but ps/logs, or the
# route-access reconcile (it writes to the running stack), must ensure the keys;
# a read-only one (ps/logs only) must not, so looking never mints or adopts.
# A read-only one passes STACK_READ_ENV (placeholders for unset keys, so `ps`/`logs`
# get past ${KEY:?} before the resolver ever ran); nothing else may, since a
# placeholder must never reach a container.
users, missing, readers, extra, notread, leaked = 0, [], 0, [], [], []
ENVS = ("$(STACK_ENV)", "$(STACK_READ_ENV)")
for m in re.finditer(r"^([A-Za-z0-9_.-]+):([^=\n][^\n]*)\n((?:\t[^\n]*\n|[ \t]*#[^\n]*\n)*)", s, re.M):
    name, prereqs, body = m.group(1), m.group(2).split("##")[0].split(), m.group(3)
    if name.startswith("."):
        continue
    rec = [ln for ln in body.splitlines() if ln.startswith("\t")]
    comp = [ln for ln in rec if any(e in ln for e in ENVS) and "$(COMPOSE_CMD)" in ln and "$(STACK_COMPOSE)" in ln]
    recon = any(any(e in ln for e in ENVS) and "route-access-reconcile.sh" in ln for ln in rec)
    if not comp and not recon:
        continue
    readonly = comp and not recon and all(re.search(r"\s(ps|logs)(\s|$)", ln) for ln in comp)
    if readonly:
        readers += 1
        if "stack-db-env" in prereqs:
            extra.append(name)
        if any("$(STACK_READ_ENV)" not in ln for ln in comp):
            notread.append(name)
    else:
        users += 1
        if "stack-db-env" not in prereqs:
            missing.append(name)
        if any("$(STACK_READ_ENV)" in ln for ln in rec):
            leaked.append(name)
print(users)
print(" ".join(missing))
print(readers)
print(" ".join(extra))
print(" ".join(notread))
print(" ".join(leaked))
PY
)"
nu="$(sed -n 1p <<<"${wiring}")"; miss="$(sed -n 2p <<<"${wiring}")"
nr="$(sed -n 3p <<<"${wiring}")"; extra="$(sed -n 4p <<<"${wiring}")"
if [ "${nu}" -ge 6 ] && [ -z "${miss}" ]; then ok "every target that builds, creates, stops or writes to the stack (${nu}) depends on stack-db-env"; else bad "ensuring targets: ${nu}; missing the stack-db-env prerequisite: ${miss:-?}"; fi
if [ "${nr}" -ge 3 ] && [ -z "${extra}" ]; then ok "none of the ${nr} read-only targets (ps/logs/onion) runs the resolver"; else bad "read-only targets: ${nr}; run the resolver anyway: ${extra:-?}"; fi
notread="$(sed -n 5p <<<"${wiring}")"; leaked="$(sed -n 6p <<<"${wiring}")"
if [ "${nr}" -ge 3 ] && [ -z "${notread}" ]; then ok "every read-only target runs compose with STACK_READ_ENV (a missing key does not blind ps/logs/onion)"; else bad "read-only targets without STACK_READ_ENV: ${notread:-?}"; fi
if [ -z "${leaked}" ]; then ok "no target that builds, creates, stops or writes uses STACK_READ_ENV (a placeholder never reaches a container)"; else bad "STACK_READ_ENV used by a writing target: ${leaked}"; fi
if awk '/^stack-db-env:/{s=1;next} s&&/^\t/{sub(/^\t/,"");print;exit}' "${MK}" | grep -E '^@?bash tests/stack/gen-stack-db-env\.sh$' >/dev/null; then ok "stack-db-env runs the resolver as its own (status-checked) recipe line"; else bad "stack-db-env does not run the resolver as a plain recipe line"; fi
if command -v make >/dev/null 2>&1; then
  up="$(cd "${REPO}" && timeout 60 make -n -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env -o stack-route-access-env stack-up 2>/dev/null)"
  n_compose="$(grep -c ' compose -f tests/stack/compose.local.yaml' <<<"${up}")"
  n_all="$(grep ' compose -f tests/stack/compose.local.yaml' <<<"${up}" | python3 -c '
import sys
keys = sys.argv[1].split()
lines = sys.stdin.read().splitlines()
print(sum(all(f"{k}=\"${{{k}:-$(bash tests/stack/gen-stack-db-env.sh --read {k})}}\"" in ln for k in keys) for ln in lines))' "${KEYS[*]}")"
  if [ "${n_compose}" -ge 2 ] && [ "${n_all}" -eq "${n_compose}" ]; then ok "every compose line of stack-up (${n_compose}) passes all ${NK} keys explicitly (an --env-file would disable .env)"; else bad "${n_all} of ${n_compose} stack-up compose lines pass every key"; fi
  first_gen="$(grep -n '^bash tests/stack/gen-stack-db-env.sh$' <<<"${up}" | head -1 | cut -d: -f1)"
  first_cmp="$(grep -n ' compose -f tests/stack/compose.local.yaml' <<<"${up}" | head -1 | cut -d: -f1)"
  if [ -n "${first_gen}" ] && [ -n "${first_cmp}" ] && [ "${first_gen}" -lt "${first_cmp}" ]; then ok "make -n stack-up runs the ensure step before the first compose call"; else bad "ensure step at '${first_gen:-none}', first compose at '${first_cmp:-none}'"; fi
  if grep -qE '_PASSWORD=[0-9a-f]{16,}' <<<"${up}"; then bad "make -n prints a password VALUE"; else ok "make -n prints the substitution, never a value"; fi
  for tgt in stack-down stack-clean; do
    rec="$(cd "${REPO}" && timeout 60 make -n "${tgt}" 2>/dev/null)"
    dv="$(grep -n 'down -v' <<<"${rec}" | head -1 | cut -d: -f1)"
    rm_="$(grep -n 'gen-stack-db-env.sh --remove' <<<"${rec}" | head -1 | cut -d: -f1)"
    ens="$(grep -n '^bash tests/stack/gen-stack-db-env.sh$' <<<"${rec}" | head -1 | cut -d: -f1)"
    if [ -n "${dv}" ] && [ -n "${rm_}" ] && [ -n "${ens}" ] && [ "${ens}" -lt "${dv}" ] && [ "${rm_}" -gt "${dv}" ]; then ok "${tgt}: ensure before down -v (compose needs the keys to tear down), --remove after"; else bad "${tgt}: ensure '${ens:-none}', down -v '${dv:-none}', --remove '${rm_:-none}'"; fi
  done
  halt="$(cd "${REPO}" && timeout 60 make -n stack-halt 2>/dev/null)"
  if grep -q 'gen-stack-db-env.sh --remove' <<<"${halt}"; then bad "stack-halt strips the keys (it keeps the volumes)"; else ok "stack-halt keeps the keys (it keeps the volumes)"; fi

  # Behavioural: real make with a recording compose stub; env file redirected to WORK.
  cat > "${WORK}/bin/compose-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${FEDERATION_DB_PASSWORD-<unset>}" "${SVC_PASSWORD-<unset>}" >> "${COMPOSE_STUB_LOG}"
EOF
  chmod +x "${WORK}/bin/compose-stub"
  E8="${WORK}/make.env"; L8="${WORK}/compose.log"; : > "${L8}"
  mk8() { # mk8 <volumes> <make args…>
    local v="$1"; shift
    (cd "${REPO}" && STACK_DB_ENV_FILE="${E8}" DOCKER="${WORK}/bin/docker" STUB_VOLUMES="${v}" \
       COMPOSE_STUB_LOG="${L8}" FEDERATION_DB_PASSWORD= SVC_PASSWORD= \
       timeout 60 make --no-print-directory "$@" COMPOSE_CMD="${WORK}/bin/compose-stub")
  }
  mk8 down -o stack-clone -o stack-certs -o stack-m2-check -o stack-mastodon-env -o stack-route-access-env stack-up >/dev/null 2>&1; rc=$?
  if [ "${rc}" -ne 0 ] && [ ! -s "${L8}" ] && [ ! -e "${E8}" ]; then ok "resolver failure (daemon unreachable) STOPS make stack-up (rc=${rc}) before compose runs"; else bad "resolver failure: make stack-up rc=${rc}, compose ran $(wc -l < "${L8}") time(s)"; fi
  mk8 "" stack-db-env >/dev/null 2>&1
  mk8 "" stack-halt >"${WORK}/make8.out" 2>&1; rc=$?
  f8="$(val "${E8}" FEDERATION_DB_PASSWORD 2>/dev/null)"; s8="$(val "${E8}" SVC_PASSWORD 2>/dev/null)"
  if [ "${rc}" -eq 0 ] && [[ "${f8}" =~ ^[0-9a-f]{48}$ ]] && [ "$(cat "${L8}")" = "${f8} ${s8}" ]; then ok "compose got exactly the file's values, even with EMPTY ones exported in the shell"; else bad "key present: rc=${rc}, compose log $(wc -l < "${L8}") line(s)"; fi
  if grep -qF "${f8:-no-value}" "${WORK}/make8.out"; then bad "make's output echoes a password value"; else ok "make's own output never contains a value"; fi
  # The read-only targets on a .env WITHOUT the keys (the operator's state the day
  # #857 lands: only ROUTE_ACCESS_DB_PASSWORD is there). Before round 2 compose got
  # empty values and ps/logs stopped on ${KEY:?}; now it gets the placeholder, and
  # nothing is minted.
  E8r="${WORK}/read.env"; printf 'ROUTE_ACCESS_DB_PASSWORD=abc123\n' > "${E8r}"; : > "${L8}"
  PH="$(sed -n 's/^STACK_DB_READ_PLACEHOLDER := //p' "${MK}")"
  for tgt in stack-ps stack-logs; do
    (cd "${REPO}" && STACK_DB_ENV_FILE="${E8r}" DOCKER="${WORK}/bin/docker" STUB_VOLUMES=down \
       COMPOSE_STUB_LOG="${L8}" FEDERATION_DB_PASSWORD= SVC_PASSWORD= \
       timeout 60 make --no-print-directory "${tgt}" COMPOSE_CMD="${WORK}/bin/compose-stub" >/dev/null 2>&1); rc=$?
    got="$(tail -1 "${L8}")"
    if [ "${rc}" -eq 0 ] && [ -n "${PH}" ] && [ "${got}" = "${PH} ${PH}" ] && [ "$(cat "${E8r}")" = "ROUTE_ACCESS_DB_PASSWORD=abc123" ]; then
      ok "${tgt} on a .env without the keys: compose gets the placeholder for each, the file is untouched, docker is never asked"
    else
      bad "${tgt} on a .env without the keys: rc=${rc}, compose saw '${got:-nothing}' (want '${PH:-?} ${PH:-?}'), file now $(wc -l < "${E8r}") line(s)"
    fi
  done
  : > "${L8}"
  (cd "${REPO}" && STACK_DB_ENV_FILE="${E8}" COMPOSE_STUB_LOG="${L8}" FEDERATION_DB_PASSWORD= SVC_PASSWORD= \
     timeout 60 make --no-print-directory stack-ps COMPOSE_CMD="${WORK}/bin/compose-stub" >/dev/null 2>&1); rc=$?
  if [ "${rc}" -eq 0 ] && [ "$(cat "${L8}")" = "${f8} ${s8}" ]; then ok "stack-ps on a .env WITH the keys passes the file's values, not the placeholder"; else bad "stack-ps with keys: rc=${rc}, compose log '$(head -c 40 "${L8}")'"; fi
else
  bad "make is not installed — section 8 asserted nothing"
fi

echo "-- 9) docker compose renders with a generated .env and fails without one --"
if docker compose version >/dev/null 2>&1; then
  # A COPY of tests/stack, so the checkout's own .env is neither read nor written.
  mkdir -p "${WORK}/render"
  cp -a "${HERE}/." "${WORK}/render/stack/"
  rm -f "${WORK}/render/stack/.env"
  : > "${WORK}/render/stack/.mastodon.env"
  rdr() { (cd "${WORK}/render" && env -u COMPOSE_PROJECT_NAME $(printf -- '-u %s ' "${KEYS[@]}") ROUTE_ACCESS_DB_PASSWORD=guard \
            docker compose -p db-env-guard -f stack/compose.local.yaml "$@"); }
  rdr config >/dev/null 2>"${WORK}/err9"; rc=$?
  if [ "${rc}" -ne 0 ] && grep -E 'required variable [A-Z_]+_PASSWORD is missing a value: run tests/stack/gen-stack-db-env.sh' "${WORK}/err9" >/dev/null; then ok "no .env: compose config FAILS (rc=${rc}) and names the resolver"; else bad "no .env: rc=${rc}: $(head -2 "${WORK}/err9" | tr '\n' '|')"; fi
  rdr ps >/dev/null 2>&1; rc=$?
  if [ "${rc}" -ne 0 ]; then ok "no .env: even \`ps\` refuses (why every make target runs stack-db-env first)"; else bad "no .env: ps passed — the interpolation is not required"; fi
  STACK_DB_ENV_FILE="${WORK}/render/stack/.env" DOCKER="${WORK}/bin/docker" bash "${GEN}" >/dev/null 2>&1
  rdr --profile social --profile phpbb --profile akkoma --profile brandb --profile games config >"${WORK}/cfg9" 2>"${WORK}/err9b"; rc=$?
  if [ "${rc}" -eq 0 ] && [ -s "${WORK}/cfg9" ]; then ok "with a generated .env, compose config renders every profile (rc=0)"; else bad "with .env: rc=${rc}: $(head -2 "${WORK}/err9b" | tr '\n' '|')"; fi
  fv="$(val "${WORK}/render/stack/.env" FEDERATION_DB_PASSWORD)"
  nf="$(grep -cF "${fv}" "${WORK}/cfg9")"
  if [ "${nf}" -ge 3 ]; then ok "the generated FEDERATION_DB_PASSWORD reaches federation-db and the federation API's r2dbc + liquibase fields (${nf})"; else bad "the generated value appears ${nf} time(s) in the render"; fi
  if python3 - "${WORK}/cfg9" "${TABLE}" <<'PY'
import re, sys
cfg = open(sys.argv[1], encoding="utf-8").read()
for ln in open(sys.argv[2], encoding="utf-8"):
    if not ln.strip() or ln.startswith("#"):
        continue
    legacy = ln.rstrip("\n").split("\t")[4]
    if re.search(r"(?i)(PASS[A-Z_]*|password)[:=]\s*\"?" + re.escape(legacy) + r"\b", cfg):
        sys.exit(1)
PY
  then ok "no rendered password field carries a legacy literal"; else bad "a legacy literal is still rendered as a password"; fi
else
  skip "docker compose is not installed: section 7 pins the same property statically"
fi

echo "-- 10) Windows path (scripts/stack-up.ps1) --"
PS1="${REPO}/scripts/stack-up.ps1"
if grep -F 'stack-db-passwords.tsv' "${PS1}" >/dev/null; then ok "stack-up.ps1 reads the same key table"; else bad "stack-up.ps1 does not read stack-db-passwords.tsv"; fi
dl="$(grep -n 'docker compose -f \$Compose .*down -v' "${PS1}" | head -1 | cut -d: -f1)"
el="$(grep -n 'Ensure-StackDbEnv' "${PS1}" | sed -n 2p | cut -d: -f1)"
if [ -n "${dl}" ] && [ -n "${el}" ] && [ "${el}" -lt "${dl}" ]; then ok "-Down ensures the keys before \`down -v\` (compose needs them to tear down)"; else bad "-Down: ensure at '${el:-none}', down -v at '${dl:-none}'"; fi
PWSH="${PWSH:-pwsh}"
if command -v "${PWSH%% *}" >/dev/null 2>&1; then
  # Run ONLY the DB-password functions, cut out of the real file between markers.
  python3 - "${PS1}" "${WORK}/dbfuncs.ps1" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = s.index("# >>> stack-db-env (twin of tests/stack/gen-stack-db-env.sh) >>>")
b = s.index("# <<< stack-db-env <<<")
open(sys.argv[2], "w", encoding="utf-8").write(s[a:b])
PY
  cat > "${WORK}/harness.ps1" <<'EOF'
param([string]$StackDir, [string]$Mode = 'ensure')
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-EnvAtomic([string]$Target, [string[]]$Lines) { [System.IO.File]::WriteAllLines($Target, $Lines, $Utf8NoBom) }
$DotEnv = Join-Path $StackDir '.env'
. (Join-Path $PSScriptRoot 'dbfuncs.ps1')
if ($Mode -eq 'remove') { Remove-StackDbEnv } else { Ensure-StackDbEnv }
EOF
  SD="${WORK}/ps/stack"; mkdir -p "${SD}"; cp "${TABLE}" "${SD}/"
  printf 'OTHER=1\n' > "${SD}/.env"
  PATH="${WORK}/bin:${PATH}" ${PWSH} -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" >"${WORK}/ps.out" 2>&1; rc=$?
  nh=0; for k in "${KEYS[@]}"; do [[ "$(tr -d '\r' < "${SD}/.env" | sed -n "s/^${k}=//p")" =~ ^[0-9a-f]{48}$ ]] && nh=$((nh + 1)); done
  ps_ok=0
  if [ "${rc}" -eq 0 ] && [ "${nh}" -eq "${NK}" ] && [ "$(head -1 "${SD}/.env" | tr -d '\r')" = OTHER=1 ]; then ok "pwsh: every key minted, the operator's line kept"; ps_ok=1; else bad "pwsh fresh: rc=${rc}, ${nh}/${NK} keys: $(head -3 "${WORK}/ps.out" | tr '\n' '|')"; fi
  if head -c3 "${SD}/.env" | od -An -tx1 | grep 'ef bb bf' >/dev/null; then bad "pwsh wrote a UTF-8 BOM"; else ok "pwsh writes no BOM"; fi
  sum="$(sha256sum < "${SD}/.env")"
  PATH="${WORK}/bin:${PATH}" STUB_VOLUMES="hugmesh-local_federation-pg" STUB_CTR_federation_db=ffff ${PWSH} -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" >/dev/null 2>&1
  if [ "${ps_ok}" -eq 1 ] && [ "$(sha256sum < "${SD}/.env")" = "${sum}" ]; then ok "pwsh: never rotates a present key"; else bad "pwsh rewrote a present key"; fi
  PATH="${WORK}/bin:${PATH}" ${PWSH} -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" -Mode remove >/dev/null 2>&1
  if [ "${ps_ok}" -eq 1 ] && [ "$(tr -d '\r' < "${SD}/.env")" = OTHER=1 ]; then ok "pwsh -Down strips only the keys"; else bad "pwsh remove left: $(tr '\n' '|' < "${SD}/.env")"; fi
  rm -f "${SD}/.env"
  PATH="${WORK}/bin:${PATH}" STUB_VOLUMES="hugmesh-local_federation-pg hugmesh-local_admin-bff-pg" STUB_CTR_federation_db="${ctr_pw}" \
    ${PWSH} -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" >"${WORK}/ps3.out" 2>&1
  pf="$(tr -d '\r' < "${SD}/.env" | sed -n 's/^FEDERATION_DB_PASSWORD=//p')"; pa="$(tr -d '\r' < "${SD}/.env" | sed -n 's/^ADMIN_BFF_DB_PASSWORD=//p')"
  if [ "${pf}" = "${ctr_pw}" ] && [ "${pa}" = "$(row ADMIN_BFF_DB_PASSWORD | cut -f5)" ]; then ok "pwsh: adopts the container's value, else the legacy literal"; else bad "pwsh adoption wrong: $(head -3 "${WORK}/ps3.out" | tr '\n' '|')"; fi
  if grep -qF "${ctr_pw}" "${WORK}/ps3.out" || ! grep -q 'adopted from the existing federation-db container' "${WORK}/ps3.out"; then bad "pwsh echoed an adopted value, or printed no adoption warning"; else ok "pwsh: adoption warnings are printed and carry no value"; fi
  rm -f "${SD}/.env"
  PATH="${WORK}/bin:${PATH}" STUB_VOLUMES=down ${PWSH} -NoProfile -File "${WORK}/harness.ps1" -StackDir "${SD}" >/dev/null 2>&1; rc=$?
  if [ "${rc}" -ne 0 ] && [ ! -e "${SD}/.env" ]; then ok "pwsh: docker that cannot answer writes nothing and stops"; else bad "pwsh with docker down: rc=${rc}, file $( [ -e "${SD}/.env" ] && echo WRITTEN || echo absent)"; fi
else
  skip "pwsh is not installed: stack-up.ps1's block was only grepped, not run"
fi

echo
echo "${P} passed, ${F} failed, ${S} skipped"
[ "${F}" -eq 0 ]
