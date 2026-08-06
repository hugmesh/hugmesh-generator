#!/usr/bin/env bash
# test-bake-coverage.sh — bake/enable coverage guard for the NODE-STORAGE agent.
# Runs ANYWHERE with bash + grep — NO builds, NO root, NO docker.
#
# The agent once lived ONLY in specs/ and was baked into ZERO images. This guard makes
# that regression impossible to reintroduce silently:
#
#   1. EVERY build-*-stage4.sh (GLOBBED — a future builder is covered the day it lands)
#      must install all FOUR agent files into the sysroot (the reconcile agent, the
#      storage-verify lib, the OpenRC oneshot, the staged cron drop-in) and chmod +x
#      the two executables.
#   2. provision.sh must ENABLE the agent: rc-update add the boot oneshot, place the
#      staged cron into /etc/cron.d, warn (never brick) on a stale image missing the
#      baked files — and main() must actually CALL provision_node_storage.
#   3. The staged-cron basename is a CROSS-FILE contract (builders WRITE it under
#      /etc/hugmesh/registry, provision.sh READS it back) — asserted from provision.sh's
#      side against every builder, so a rename on either side goes red.
#   4. The four spec sources exist (a cp from a missing spec fails the real build late;
#      this fails it here, early).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== node-storage bake-coverage: every builder bakes, provision.sh enables =="

# ── (4) spec sources ────────────────────────────────────────────────────────────
for f in \
    specs/usr/sbin/hugmesh-node-storage-reconcile \
    specs/usr/lib/hugmesh/storage-verify.sh \
    specs/etc/init.d/hugmesh-node-storage-reconcile \
    specs/etc/cron.d/hugmesh-node-storage-reconcile; do
    [ -r "${REPO}/${f}" ] && ok "spec source present: ${f}" || bad "spec source MISSING: ${f}"
done

# ── (1) every builder bakes all four files (+ executable bits) ──────────────────
shopt -s nullglob
BUILDERS=( "${REPO}"/build-*-stage4.sh )
shopt -u nullglob
n="${#BUILDERS[@]}"
[ "${n}" -ge 10 ] \
    && ok "found ${n} device builders (>= the 10 known images)" \
    || bad "expected >= 10 build-*-stage4.sh builders, found ${n}"

for b in "${BUILDERS[@]}"; do
    name="$(basename "${b}")"
    miss=""
    grep -q '/usr/sbin/hugmesh-node-storage-reconcile"' "${b}"                 || miss="${miss} sbin-agent"
    grep -q '/usr/lib/hugmesh/storage-verify.sh"' "${b}"                       || miss="${miss} verify-lib"
    grep -q '/etc/init.d/hugmesh-node-storage-reconcile"' "${b}"               || miss="${miss} init.d-oneshot"
    grep -q '/etc/hugmesh/registry/cron-node-storage-reconcile"' "${b}"        || miss="${miss} staged-cron"
    grep -q 'chmod +x.*/usr/sbin/hugmesh-node-storage-reconcile' "${b}"        || miss="${miss} chmod-sbin"
    grep -q 'chmod +x.*/etc/init.d/hugmesh-node-storage-reconcile' "${b}"      || miss="${miss} chmod-init.d"
    if [ -z "${miss}" ]; then
        ok "${name} bakes all 4 node-storage files (+x on agent + oneshot)"
    else
        bad "${name} missing node-storage bake refs:${miss}"
    fi
done

# ── (2) provision.sh enables the agent ──────────────────────────────────────────
[ -r "${PROV}" ] || { bad "cannot read ${PROV}"; echo; echo "node-storage bake-coverage: ${P} passed, $((F)) failed"; exit 1; }

grep -q '^provision_node_storage() {' "${PROV}" \
    && ok "provision.sh defines provision_node_storage()" \
    || bad "provision.sh does NOT define provision_node_storage()"
grep -Eq '^[[:space:]]+provision_node_storage' "${PROV}" \
    && ok "main() calls provision_node_storage (defined-but-never-called would be a dead enable)" \
    || bad "provision_node_storage is never CALLED from main()"
grep -q 'rc-update add hugmesh-node-storage-reconcile default' "${PROV}" \
    && ok "provision.sh rc-update adds the boot oneshot into the default runlevel" \
    || bad "provision.sh missing 'rc-update add hugmesh-node-storage-reconcile default'"
grep -q '/etc/cron.d/hugmesh-node-storage-reconcile' "${PROV}" \
    && ok "provision.sh installs the 60s cron into /etc/cron.d" \
    || bad "provision.sh never places the staged cron into /etc/cron.d"
grep -q 'hugmesh-node-storage-reconcile missing from image' "${PROV}" \
    && ok "provision.sh carries the missing-binary warn (stale image degrades, never bricks)" \
    || bad "provision.sh missing the missing-binary warn pattern"

# ── (3) staged-cron basename: cross-file contract (provision.sh side vs builders) ──
# Read the basename provision.sh actually LOOKS FOR under ${reg_dir} and assert every
# builder STAGES exactly that name under /etc/hugmesh/registry — a rename on either
# side (builder or provision.sh) turns this red.
staged="$(grep -o '{reg_dir}/cron-node-storage[a-z-]*' "${PROV}" | head -1 | sed 's|.*/||')"
if [ -n "${staged}" ]; then
    ok "provision.sh reads staged cron basename '${staged}'"
    for b in "${BUILDERS[@]}"; do
        grep -q "/etc/hugmesh/registry/${staged}\"" "${b}" \
            || bad "$(basename "${b}") does not stage '${staged}' under /etc/hugmesh/registry (name drift)"
    done
else
    bad "cannot extract the staged-cron basename provision.sh reads (idiom drift?)"
fi

echo
echo "node-storage bake-coverage: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
