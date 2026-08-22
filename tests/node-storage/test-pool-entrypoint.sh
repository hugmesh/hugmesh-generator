#!/usr/bin/env bash
# test-pool-entrypoint.sh — `keys-provision --pool` must actually provision a pool.
# Unprivileged, no disks, no root, no cluster: bash + jq + python3 + coreutils.
#
# THE DEFECT THIS PINS. hugmesh-node-storage-reconcile step 5b runs
#     HUGMESH_PROVISION_MANIFEST=<pool-manifest> bash /etc/keys-provision/provision.sh --pool
# every 60 seconds. main() ignored its argv completely, so on the only machine state that
# matters — an already-provisioned node with the KEYS USB long gone — the run went:
#     === keys-provision starting ===
#     Already provisioned (…). Skipping.
#     WARNING: No partition labelled 'KEYS' found after 15s.
#     WARNING: Continuing without external provisioning data.
# and `return 0` — before a single line of storage work. A registered pool was never
# provisioned on any node. Every string a grep could ask for (`--pool`, the pool marker,
# provision_storage) was present and correct, which is why the shipped guard was green.
# The one state that did NOT return early was worse: with a KEYS stick still inserted,
# `--pool` ran the WHOLE first-boot flow and then called provision_storage with NO
# argument — the USB's manifest, across the SYSTEM disks.
#
# So this test asserts EFFECT: a pool device that ends up mounted and in /etc/fstab with
# `,nofail`, from the agent's own call site, against a sandbox fake root. Presence of a
# string proves nothing here and is never asserted.
#
# The sandbox (tests/node-storage/provision-sandbox.sh) runs the REAL provision.sh with
# its absolute paths relocated into a throwaway root and a CLOSED PATH of stubs — see
# that file's header for the two rewrites it makes and why they do not weaken the test.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/node-storage/provision-sandbox.sh
source "${HERE}/provision-sandbox.sh"

PROV="${REPO}/specs/etc/keys-provision/provision.sh"
AGENT="${REPO}/specs/usr/sbin/hugmesh-node-storage-reconcile"

for t in bash jq python3; do
    command -v "${t}" >/dev/null 2>&1 || {
        echo "FATAL: ${t} required (refusing to skip — a skipping gate never guards)" >&2; exit 2; }
done
[ -r "${PROV}" ]  || { echo "FATAL: missing ${PROV}" >&2; exit 2; }
[ -r "${AGENT}" ] || { echo "FATAL: missing ${AGENT}" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# ── prepare_node <sandbox> <provision.sh to stage> ─────────────────────────────
# A node in the state the reconcile agent actually finds: already provisioned (DONE
# marker written), no KEYS media anywhere, one attached pool disk and one system disk,
# and a pool-manifest of the shape the agent's build_pool_manifest() emits (the pool
# device carries a `pool:{}` marker; the system device does not).
prepare_node() {
    local sb="$1" src="$2"
    ps_stage "${sb}" "${src}" 2>/dev/null || return 1
    : > "${sb}/dev/pooldisk"
    : > "${sb}/dev/sysdisk"
    cat > "${sb}/var/lib/hugmesh/node-storage/pool-manifest.json" <<JSON
{"storage":{"devices":[
  {"match":"${sb}/dev/pooldisk","mountpoint":"${sb}/srv/pool0","filesystem":"ext4",
   "format":false,"encrypt":true,"pool":{"id":"pool-1","exclusive":true,"reserved_bytes":0}},
  {"match":"${sb}/dev/sysdisk","mountpoint":"${sb}/srv/data","filesystem":"ext4",
   "format":false,"encrypt":true}
]}}
JSON
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${sb}/var/lib/keys-provision/done"
    return 0
}

echo "== node-storage: keys-provision --pool actually provisions a pool =="

# ── 1. the agent's exact invocation, on an already-provisioned node ────────────
SB="${WORK}/node"
prepare_node "${SB}" "${PROV}" || { echo "  FAIL sandbox staging"; exit 1; }
HUGMESH_PROVISION_MANIFEST="${SB}/var/lib/hugmesh/node-storage/pool-manifest.json" \
    ps_run "${SB}" --pool
RC=$?

if ps_log "${SB}" mount | grep "${SB}/dev/pooldisk ${SB}/srv/pool0" >/dev/null; then
    ok "the pool device was MOUNTED at its pool path (rc=${RC})"
else
    bad "the pool device was never mounted — --pool did no pool work. Run log:
$(sed 's/^/        /' "${SB}/log/run.out")"
fi
if grep -q "${SB}/srv/pool0" "${SB}/etc/fstab"; then
    ok "the pool is persisted in /etc/fstab"
else
    bad "no /etc/fstab entry for the pool: [$(cat "${SB}/etc/fstab")]"
fi
if grep "${SB}/srv/pool0" "${SB}/etc/fstab" | grep 'nofail' >/dev/null; then
    ok "the pool's fstab entry carries ,nofail (a removed pool disk degrades, never blocks boot)"
else
    bad "the pool's fstab entry MUST carry ,nofail: [$(grep "${SB}/srv/pool0" "${SB}/etc/fstab")]"
fi
if grep -q "${SB}/srv/data" "${SB}/etc/fstab" || ps_log "${SB}" mount | grep 'sysdisk' >/dev/null; then
    bad "--pool touched the SYSTEM disk — pool mode must skip every device without a pool marker"
else
    ok "the system disk (no pool marker) was left alone"
fi

# ── 2. --pool is not the first-boot flow ──────────────────────────────────────
if grep -q '=== keys-provision starting ===' "${SB}/log/run.out"; then
    bad "--pool fell into the first-boot flow (users/network/kubeadm) instead of the pool entry point"
else
    ok "--pool ran ONLY the pool entry point (no first-boot flow)"
fi
if [ -n "$(ps_log "${SB}" rc-update)" ]; then
    bad "--pool changed runlevels: $(ps_log "${SB}" rc-update | tr '\n' ',')"
else
    ok "--pool enabled no services and rewrote no runlevel"
fi

# ── 3. the call comes from the AGENT, not from this test ──────────────────────
# Source the real reconcile agent (its `if BASH_SOURCE == $0` guard makes that safe),
# point its PROVISION at the sandbox copy, and let provision_pools() build the command
# line itself. Nothing here says "--pool"; if the agent stops passing it, or stops
# exporting HUGMESH_PROVISION_MANIFEST, the pool stops appearing.
SB2="${WORK}/agent"
prepare_node "${SB2}" "${PROV}" || { echo "  FAIL sandbox staging"; exit 1; }
(
    PATH="${SB2}/bin"; export PATH
    # shellcheck source=/dev/null
    source "${AGENT}" >/dev/null 2>&1
    PROVISION="${SB2}/provision.sh"
    POOL_MANIFEST="${SB2}/var/lib/hugmesh/node-storage/pool-manifest.json"
    NS_PROVISION_CMD=""          # the DEFAULT command line is what is under test
    provision_pools
) > "${SB2}/log/agent.out" 2>&1
if ps_log "${SB2}" mount | grep "${SB2}/dev/pooldisk ${SB2}/srv/pool0" >/dev/null; then
    ok "the agent's own provision_pools() reaches the pool work end to end"
else
    bad "the agent's provision_pools() did not provision the pool. Agent output:
$(sed 's/^/        /' "${SB2}/log/agent.out")"
fi

# ── 4. inert cases: no manifest, and a manifest path that is not absolute ──────
SB3="${WORK}/nomanifest"
prepare_node "${SB3}" "${PROV}" || { echo "  FAIL sandbox staging"; exit 1; }
rm -f "${SB3}/var/lib/hugmesh/node-storage/pool-manifest.json"
HUGMESH_PROVISION_MANIFEST="${SB3}/var/lib/hugmesh/node-storage/pool-manifest.json" \
    ps_run "${SB3}" --pool
RC=$?
if [ "${RC}" -eq 0 ] && [ ! -s "${SB3}/etc/fstab" ]; then
    ok "no pool manifest -> clean no-op exit 0 (the agent runs this on every poolless node)"
else
    bad "no-manifest run should be a clean no-op (rc=${RC}, fstab=[$(cat "${SB3}/etc/fstab")])"
fi

SB4="${WORK}/relpath"
prepare_node "${SB4}" "${PROV}" || { echo "  FAIL sandbox staging"; exit 1; }
( cd "${SB4}" && HUGMESH_PROVISION_MANIFEST="var/lib/hugmesh/node-storage/pool-manifest.json" \
    PATH="${SB4}/bin" bash "${SB4}/provision.sh" --pool ) > "${SB4}/log/run.out" 2>&1
RC=$?
if [ "${RC}" -ne 0 ] && [ ! -s "${SB4}/etc/fstab" ]; then
    ok "a non-absolute manifest path is REFUSED (rc=${RC}) and provisions nothing"
else
    bad "a relative manifest path must be refused (rc=${RC}, fstab=[$(cat "${SB4}/etc/fstab")])"
fi

# ── NEGATIVE CONTROL ──────────────────────────────────────────────────────────
# Remove the --pool dispatch from main(), which reproduces the pre-fix control flow
# EXACTLY, and require check 1 to stop passing. Without this the whole file could be
# passing for some sandbox-specific reason and nobody would know.
echo
echo "-- negative control: with main()'s --pool dispatch removed, the pool must NOT appear --"
NEG="${WORK}/prefix-provision.sh"
python3 - "${PROV}" "${NEG}" <<"PY"
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
old = '    if [ "${1:-}" = "--pool" ]; then\n        provision_storage_pool\n        return $?\n    fi\n'
assert old in t, "main()'s --pool dispatch not found — update the negative control"
open(dst, "w", encoding="utf-8").write(t.replace(old, "", 1))
PY
SB5="${WORK}/prefix"
if prepare_node "${SB5}" "${NEG}"; then
    HUGMESH_PROVISION_MANIFEST="${SB5}/var/lib/hugmesh/node-storage/pool-manifest.json" \
        ps_run "${SB5}" --pool
    if ps_log "${SB5}" mount | grep 'pooldisk' >/dev/null; then
        bad "negative control: the pool was provisioned WITHOUT the dispatch — this test proves nothing"
    else
        ok "negative control: without the dispatch, --pool provisions nothing (that was main's behaviour)"
    fi
else
    bad "negative control staging failed"
fi

echo
echo "node-storage --pool entry point: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
