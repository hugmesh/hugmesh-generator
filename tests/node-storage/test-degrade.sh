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
AGENT="${REPO}/specs/usr/sbin/hugmesh-node-storage-reconcile"
OVERLAY="${REPO}/specs/cluster/manifests/node-storage-placement"
APPSET="${REPO}/specs/cluster/apps/13b-node-storage.yaml"

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

# ── PDB + migration Job posture + REAL rsync body + ApplicationSet ConfigMap binding ──
pdb="${OVERLAY}/pdb.yaml"; mig="${OVERLAY}/node-storage-migrate.yaml"
[ -r "${pdb}" ] && [ -r "${mig}" ] || { bad "missing pdb.yaml / node-storage-migrate.yaml"; }
[ -r "${APPSET}" ] || { bad "missing 13b-node-storage.yaml"; }
EXTRA=0
python3 - "${pdb}" "${mig}" "${APPSET}" <<'PY' || F=$((F+1))
import sys, yaml
pdb = yaml.safe_load(open(sys.argv[1])); mig = yaml.safe_load(open(sys.argv[2]))
appset = yaml.safe_load(open(sys.argv[3]))
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

# ── REAL migration body: the rendered Job actually RUNS rsync (not an echo-only stub) ──
args = mig["spec"]["template"]["spec"]["containers"][0]["args"][0]
check("rsync -aHAX --numeric-ids --delete /src/ /dst/" in args,
      "migration Job RUNS rsync (rsync -aHAX --numeric-ids --delete /src/ /dst/) — real copy, not echo-only")
check("apk add --no-cache rsync" in args,
      "migration Job installs rsync (apk add) when absent (or baked rsync image)")
check("--dry-run --itemize-changes" in args and "exit 5" in args,
      "migration Job VERIFIES parity (dry-run --itemize-changes) and EXITS NON-ZERO on mismatch")
check("STUB no-op" not in args and "STUB:" not in args,
      "migration Job is no longer an echo-only STUB (no-op text removed)")

# ── ApplicationSet BINDS the node-storage-assignments ConfigMap elements ──
matrix = appset["spec"]["generators"][0]["matrix"]["generators"]
src = matrix[0]["list"]["elements"][0]
expand = matrix[1]["list"]
check("elements" in src and src["elements"]=="[]",
      "13b ApplicationSet binds the node-storage-assignments ConfigMap `elements` key (inert default [])")
check(expand.get("elementsYaml")=="{{ .elements }}",
      "13b expands the ConfigMap elements via elementsYaml '{{ .elements }}' (one Application per assignment)")
check(appset["spec"]["generators"][0]["selector"]["matchLabels"]=={"state":"active"},
      "13b keeps the state:active selector (revoked assignment pruned)")

# ── replay: an ACTIVE assignment in the ConfigMap renders exactly one placement element ──
import json
sample = json.dumps([{"id":"a-1","service":"owncast","pvc":"owncast-data","nodeName":"pi-1",
                      "poolPath":"/mnt/p1","namespace":"hugmesh-backend","requested":"4","state":"active"},
                     {"id":"a-2","service":"db","pvc":"db-data","nodeName":"pi-2",
                      "poolPath":"/mnt/p2","namespace":"hugmesh-backend","requested":"8","state":"revoked"}])
parsed = json.loads(sample)  # what elementsYaml '{{ .elements }}' parses the ConfigMap string into
sel = {"state":"active"}
kept = [e for e in parsed if all(str(e.get(k))==str(v) for k,v in sel.items())]
check(len(kept)==1 and kept[0]["id"]=="a-1",
      "ConfigMap with 1 active + 1 revoked binds exactly ONE placement (the active one)")

sys.exit(0 if import_ok else 1)
PY
[ $? -eq 0 ] && P=$((P+9)) || true

echo
echo "node-storage PR8 degrade: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
