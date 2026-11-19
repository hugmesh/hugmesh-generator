#!/usr/bin/env bash
# test-tor-node-rotation.sh — a node gives ONE Tor domain a new onion address when the
# signed export asks for it (hugmesh-generator#652).
#
# specs/usr/sbin/hugmesh-tor-reconcile is EXECUTED in a sandbox node root
# (HUGMESH_TOR_ROOT) with rc-service / tor / id / chown / sleep stubbed on a hermetic
# PATH (the seams tests/scripts/test-tor-node-contract.sh uses). The stub `rc-service tor
# reload` does what real tor does on a reload: it mints a key, and a NEW name, for every
# HiddenServiceDir left without one. The canonical-bytes half (tor-verify.sh) is checked
# against reference strings, with and without rotation lines.
#
# Pinned: a request rotates only that domain (key, export) and records its count; the
# same count again does nothing and a higher one rotates again; a reload that mints
# nothing puts the old key back, exports it again and records nothing; the boot oneshot
# never rotates; a request for an unlisted domain or a malformed line is ignored; key
# folders past the retention window are pruned; a body with no rotations has exactly the
# canonical bytes it had before this change.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/hugmesh-tor-reconcile"
VERIFY="${REPO}/specs/usr/lib/hugmesh/tor-verify.sh"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tor-rot.XXXXXX")"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK}"' EXIT

for t in bash jq; do command -v "${t}" >/dev/null || { echo "FAIL host lacks ${t}"; exit 1; }; done

# ── the hermetic PATH ─────────────────────────────────────────────────────────────
TOOLS="${WORK}/tools"; mkdir -p "${TOOLS}"
for t in basename cat chmod cmp cp cut date dirname find install mkdir mktemp mv rm sort tr; do
    p="$(command -v "${t}")" || { echo "FAIL host lacks ${t}"; exit 1; }
    ln -s "${p}" "${TOOLS}/${t}"
done
STUB="${WORK}/stub"; mkdir -p "${STUB}"
# rc-service: `status` exits $STATE_DIR/status (default 0 = running); `reload` mints a
# fresh name (letter from $STATE_DIR/letters, one per reload) in every empty
# HiddenServiceDir unless $STATE_DIR/no-remint exists.
cat > "${STUB}/rc-service" <<'EOF'
#!/bin/bash
echo "$*" >> "${STATE_DIR}/rc.log"
case "$2" in
    status) exit "$(cat "${STATE_DIR}/status" 2>/dev/null || echo 0)" ;;
    reload)
        [ -f "${STATE_DIR}/no-remint" ] && exit 0
        n=$(( $(cat "${STATE_DIR}/reloads" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STATE_DIR}/reloads"
        c="$(printf 'nopqrstuvw' | cut -c"${n}")"
        for d in "${HUGMESH_TOR_ROOT}/var/lib/tor/hugmesh-onion.d"/*/; do
            [ -d "${d}" ] || continue
            [ -s "${d}hostname" ] && continue
            printf '%s.onion\n' "$(printf "%056d" 0 | tr 0 "${c}")" > "${d}hostname"
            : > "${d}hs_ed25519_secret_key"
        done
        exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit "$(cat "${STATE_DIR}/verify" 2>/dev/null || echo 0)"\n' > "${STUB}/tor"
printf '#!/bin/bash\nexit 0\n' > "${STUB}/id"
printf '#!/bin/bash\nexit 0\n' > "${STUB}/chown"
printf '#!/bin/bash\nexit 0\n' > "${STUB}/sleep"
chmod +x "${STUB}"/*

on() { printf '%s.onion' "$(printf "%056d" 0 | tr 0 "$1")"; }
ONION_A="$(on a)"; ONION_S="$(on s)"; ONION_B="$(on b)"

# node NAME — a sandbox node: primary and two domain keys minted, tor running, the
# domains file listing both, the agent's torrc already written once (so a run is a
# steady-state cron run).
node() {
    R="${WORK}/node-$1"; STATE_DIR="${WORK}/state-$1"; export STATE_DIR
    mkdir -p "${R}/var/lib/tor/hugmesh-onion" "${R}/var/lib/tor/hugmesh-onion.d/shop" \
             "${R}/var/lib/tor/hugmesh-onion.d/brandb" "${R}/etc/hugmesh/tor" "${R}/var/log" "${STATE_DIR}"
    echo "${ONION_A}" > "${R}/var/lib/tor/hugmesh-onion/hostname"
    echo "${ONION_S}" > "${R}/var/lib/tor/hugmesh-onion.d/shop/hostname"
    : > "${R}/var/lib/tor/hugmesh-onion.d/shop/hs_ed25519_secret_key"
    echo "${ONION_B}" > "${R}/var/lib/tor/hugmesh-onion.d/brandb/hostname"
    printf 'shop\nbrandb\n' > "${R}/etc/hugmesh/tor/domains"
    run_agent                                    # the first run writes the torrc and exports
    : > "${STATE_DIR}/rc.log"; rm -f "${STATE_DIR}/reloads"
}
run_agent() {
    env -u RC_SVCNAME HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_WAIT_TRIES=3 STATE_DIR="${STATE_DIR}" \
        PATH="${STUB}:${TOOLS}" /bin/bash "${AGENT}" >/dev/null 2>&1
    AGENT_RC=$?
}
run_boot() {
    RC_SVCNAME=hugmesh-tor-reconcile HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_WAIT_TRIES=3 STATE_DIR="${STATE_DIR}" \
        PATH="${STUB}:${TOOLS}" /bin/bash "${AGENT}" >/dev/null 2>&1
}
exported() { tr -d '[:space:]' < "${R}/var/lib/hugmesh/tor/$1.hostname" 2>/dev/null; }
applied()  { tr -d '[:space:]' < "${R}/var/lib/hugmesh/tor-rotations/$1" 2>/dev/null; }
retired()  { ls -1 "${R}/var/lib/tor/hugmesh-onion.d/.retired" 2>/dev/null; }
reloads()  { grep -c -F 'tor reload' "${STATE_DIR}/rc.log" 2>/dev/null; }

echo "== R. hugmesh-tor-reconcile: rotation on request"
node r1
[ "$(exported shop)" = "${ONION_S}" ] && ok "R0 the setup exported shop's address" || bad "R0 setup: shop exported '$(exported shop)'"
echo "shop 1" > "${R}/etc/hugmesh/tor/rotations"
run_agent
NEW1="$(on n)"
[ "${AGENT_RC}" -eq 0 ] && ok "R1 agent exits 0" || bad "R1 agent exited ${AGENT_RC}"
[ "$(exported shop)" = "${NEW1}" ] && ok "R1 shop exports its NEW address" || bad "R1 shop exports '$(exported shop)'"
[ "$(applied shop)" = 1 ] && ok "R1 the request count is recorded" || bad "R1 recorded '$(applied shop)'"
[ "$(exported brandb)" = "${ONION_B}" ] && [ "$(tr -d '[:space:]' < "${R}/var/lib/tor/hugmesh-onion.d/brandb/hostname")" = "${ONION_B}" ] \
    && ok "R1 the other domain's key and export are untouched" || bad "R1 brandb changed"
[ "$(tr -d '[:space:]' < "${R}/var/lib/hugmesh/tor/hostname")" = "${ONION_A}" ] \
    && ok "R1 the mesh's own (primary) address is untouched" || bad "R1 primary changed"
r="$(retired)"
[ "$(printf '%s\n' "${r}" | grep -c '^shop-')" -eq 1 ] \
    && [ "$(tr -d '[:space:]' < "${R}/var/lib/tor/hugmesh-onion.d/.retired/${r}/hostname")" = "${ONION_S}" ] \
    && [ -e "${R}/var/lib/tor/hugmesh-onion.d/.retired/${r}/hs_ed25519_secret_key" ] \
    && ok "R1 the old key is kept aside, not deleted" || bad "R1 retired: '${r}'"
[ "$(reloads)" -eq 1 ] && ok "R1 exactly one reload" || bad "R1 reloads: $(reloads)"

: > "${STATE_DIR}/rc.log"; run_agent
[ "$(exported shop)" = "${NEW1}" ] && [ "$(reloads)" -eq 0 ] \
    && ok "R2 the same count again changes nothing (no reload)" || bad "R2 shop '$(exported shop)', reloads $(reloads)"

sleep_real="$(command -v sleep)"; "${sleep_real}" 1.1   # a distinct retired folder name
echo "shop 2" > "${R}/etc/hugmesh/tor/rotations"; run_agent
[ "$(exported shop)" = "$(on o)" ] && [ "$(applied shop)" = 2 ] && [ "$(retired | grep -c '^shop-')" -eq 2 ] \
    && ok "R3 a higher count rotates again" || bad "R3 shop '$(exported shop)', applied '$(applied shop)'"

node r4; touch "${STATE_DIR}/no-remint"
echo "shop 1" > "${R}/etc/hugmesh/tor/rotations"; run_agent
[ "$(exported shop)" = "${ONION_S}" ] \
    && [ "$(tr -d '[:space:]' < "${R}/var/lib/tor/hugmesh-onion.d/shop/hostname")" = "${ONION_S}" ] \
    && [ -e "${R}/var/lib/tor/hugmesh-onion.d/shop/hs_ed25519_secret_key" ] \
    && ok "R4 a reload that mints nothing puts the old key back and exports it again" \
    || bad "R4 shop exports '$(exported shop)'"
[ -z "$(applied shop)" ] && ok "R4 nothing is recorded, so the next run tries again" || bad "R4 recorded '$(applied shop)'"
[ -z "$(retired)" ] && ok "R4 no key left aside" || bad "R4 retired: $(retired)"

node r5; echo "shop 1" > "${R}/etc/hugmesh/tor/rotations"; run_boot
[ "$(exported shop)" = "${ONION_S}" ] && [ -z "$(applied shop)" ] \
    && ok "R5 the boot oneshot never rotates" || bad "R5 boot rotated: '$(exported shop)'"

node r6
# a key folder that is NOT a listed domain (delisted earlier: its key stays), with an address
mkdir -p "${R}/var/lib/tor/hugmesh-onion.d/other"; echo "$(on g)" > "${R}/var/lib/tor/hugmesh-onion.d/other/hostname"
printf 'other 3\nshop x\nBAD 1\nshop\n# shop 9\n' > "${R}/etc/hugmesh/tor/rotations"; run_agent
[ "$(exported shop)" = "${ONION_S}" ] && [ -z "$(retired)" ] && [ "$(reloads)" -eq 0 ] \
    && [ "$(tr -d '[:space:]' < "${R}/var/lib/tor/hugmesh-onion.d/other/hostname")" = "$(on g)" ] \
    && ok "R6 unlisted domains and malformed lines are ignored" || bad "R6 rotated: '$(exported shop)'"

node r7; old="${R}/var/lib/tor/hugmesh-onion.d/.retired/shop-20200101T000000Z"
mkdir -p "${old}"; touch -d '2020-01-01 00:00:00' "${old}"
echo "shop 1" > "${R}/etc/hugmesh/tor/rotations"; run_agent
[ ! -e "${old}" ] && [ "$(retired | grep -c '^shop-')" -eq 1 ] \
    && ok "R7 key folders past the retention window are pruned" || bad "R7 retired: $(retired | tr '\n' ' ')"

echo "== V. tor-verify.sh canonical bytes"
# shellcheck source=/dev/null
. "${VERIFY}"
body() { printf '{"body":{"node":"fp1","generation":7,"upstreamManaged":false,"upstream":"","domainsManaged":true,"domains":["brandb","shop"]%s}}' "$1" > "${WORK}/e.json"; }
REF=$'v1-tor\nnode=fp1\ngeneration=7\nupstream-managed=false\nupstream=\ndomains-managed=true\ndomain=brandb\ndomain=shop\n'
body ""
[ "$(tor_canonical_bytes "${WORK}/e.json"; printf x)" = "${REF}x" ] \
    && ok "V1 a body without rotations has exactly the old canonical bytes" || bad "V1 bytes changed"
body ',"rotations":[]'
[ "$(tor_canonical_bytes "${WORK}/e.json"; printf x)" = "${REF}x" ] \
    && ok "V2 an empty rotation list adds nothing" || bad "V2 bytes changed"
body ',"rotations":[{"slug":"shop","count":2},{"slug":"brandb","count":1}]'
[ "$(tor_canonical_bytes "${WORK}/e.json"; printf x)" = "${REF}rotate=shop:2"$'\n'"rotate=brandb:1"$'\n'"x" ] \
    && ok "V3 rotations append one rotate=<slug>:<count> line each, in array order" || bad "V3: $(tor_canonical_bytes "${WORK}/e.json" | tail -3 | tr '\n' '|')"
[ "$(tor_rotations "${WORK}/e.json" | tr '\n' '|')" = "shop 2|brandb 1|" ] \
    && ok "V4 tor_rotations reads them as '<slug> <count>' lines" || bad "V4: $(tor_rotations "${WORK}/e.json" | tr '\n' '|')"

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
