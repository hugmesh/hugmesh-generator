#!/usr/bin/env bash
# test-degrade.sh — logic test for the NODE-STORAGE graceful-degrade detection (node-storage
# PR8). Runs ANYWHERE with bash + jq. NO disks, NO root. Sources the REAL reconcile agent
# (its main() is guarded behind BASH_SOURCE, so sourcing defines the functions WITHOUT running
# the flow), stubs is_mounted + the ack curl, and asserts:
#   * a pool whose poolPath is NOT mounted is flagged DEGRADED and acked state=degraded;
#   * a pool whose poolPath IS mounted is NOT flagged (and not acked degraded);
#   * the node stays up either way (the function never exits non-zero in a way that faults).
# Also asserts the PDB + migration Job stub manifests have the safe posture (minAvailable + a
# suspended/inert migration Job).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/snapdragon-node-storage-reconcile"
OVERLAY="${REPO}/specs/cluster/manifests/node-storage-placement"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "${AGENT}" ] || { echo "missing ${AGENT}"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== node-storage PR8: graceful degrade =="

# Source the agent (main() guarded => functions only). Provide the helpers it expects.
log()  { :; }
warn() { :; }
have() { command -v "$1" >/dev/null 2>&1; }
BFF_URL=""; MTLS_CA=""; MTLS_CERT=""; MTLS_KEY=""
# Record ack calls.
ACKLOG="${WORK}/acks"; : > "${ACKLOG}"
# shellcheck source=/dev/null
. "${AGENT}"
# Override the ack to record instead of curl (the sourced agent defines ack_pool_state; we
# re-define AFTER sourcing so our version wins).
ack_pool_state() { echo "$1 $2" >> "${ACKLOG}"; }

# A two-pool export: pool-up (mounted) + pool-down (mount lost).
cat > "${WORK}/export.json" <<'JSON'
{ "body": { "nodeFp": "fp-1", "generation": 7, "pools": [
  { "poolId": "pool-up",   "poolPath": "/mnt/up",   "diskSerial": "A", "reservedBytes": 10, "isExclusive": false, "filesystem": "ext4", "assignments": [] },
  { "poolId": "pool-down", "poolPath": "/mnt/down", "diskSerial": "B", "reservedBytes": 10, "isExclusive": false, "filesystem": "ext4", "assignments": [] }
]}}
JSON

# Stub is_mounted: /mnt/up is mounted, /mnt/down is NOT (disk removed).
is_mounted() { case "$1" in /mnt/up) return 0;; *) return 1;; esac; }

degraded_ids="$(detect_degraded_pools "${WORK}/export.json")"; rc=$?

# pool-down flagged degraded; pool-up not.
echo "${degraded_ids}" | grep -q "pool-down" \
    && ok "mount-lost pool (pool-down) flagged DEGRADED" \
    || bad "pool-down should be flagged degraded (got: ${degraded_ids})"
echo "${degraded_ids}" | grep -q "pool-up" \
    && bad "pool-up (mounted) must NOT be flagged degraded" \
    || ok "mounted pool (pool-up) NOT flagged (still applied)"

# the degraded pool was acked state=degraded (UI chip turns red).
grep -q "^pool-down degraded$" "${ACKLOG}" \
    && ok "degraded pool acked state=degraded to the BFF (UI surfaces it)" \
    || bad "pool-down should be acked degraded (acks: $(cat "${ACKLOG}"))"
grep -q "^pool-up degraded$" "${ACKLOG}" \
    && bad "pool-up must NOT be acked degraded" \
    || ok "pool-up not acked degraded"

# detect returns non-zero WHEN any pool degraded (so callers can branch), but main wraps it
# with `|| true` so the node never faults. Confirm the rc signal.
[ "${rc}" -ne 0 ] \
    && ok "detect_degraded_pools signals rc!=0 when a pool is degraded (main wraps with || true => node stays up)" \
    || bad "expected non-zero rc when a pool is degraded"

# all-mounted case: no degraded, rc 0.
is_mounted() { return 0; }
: > "${ACKLOG}"
none="$(detect_degraded_pools "${WORK}/export.json")"; rc2=$?
[ -z "${none}" ] && [ "${rc2}" -eq 0 ] && [ ! -s "${ACKLOG}" ] \
    && ok "all pools mounted -> none degraded, rc 0, no degraded acks" \
    || bad "all-mounted should be clean (ids='${none}' rc=${rc2})"

# ── PDB + migration Job stub posture ──────────────────────────────────────────
pdb="${OVERLAY}/pdb.yaml"; mig="${OVERLAY}/node-storage-migrate.yaml"
[ -r "${pdb}" ] && [ -r "${mig}" ] || { bad "missing pdb.yaml / node-storage-migrate.yaml"; }
python3 - "${pdb}" "${mig}" <<'PY' || F=$((F+1))
import sys, yaml
pdb = yaml.safe_load(open(sys.argv[1])); mig = yaml.safe_load(open(sys.argv[2]))
import_ok = True
def check(c,m):
    global import_ok
    print("  PASS "+m) if c else (print("  FAIL "+m) or globals().__setitem__('import_ok',False))
check(pdb.get("kind")=="PodDisruptionBudget" and pdb["spec"].get("minAvailable")==1,
      "PDB minAvailable:1 blocks a silent drain of a node-pinned service")
check(mig.get("kind")=="Job" and mig["spec"].get("suspend") is True and mig["spec"].get("backoffLimit")==0,
      "migration Job ships INERT (suspend:true, backoffLimit:0) — never auto-runs")
ns = mig["spec"]["template"]["spec"]["nodeSelector"]
check("kubernetes.io/hostname" in ns, "migration Job is node-pinned (source node) for the rsync")
sys.exit(0 if import_ok else 1)
PY
[ $? -eq 0 ] && P=$((P+3)) || true

echo
echo "node-storage PR8 degrade: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
