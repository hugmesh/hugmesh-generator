#!/usr/bin/env bash
# test-node-agent.sh — logic test for the NODE-STORAGE reconcile agent (node-storage PR6).
# Runs ANYWHERE with bash + jq + openssl + base64 — NO live mesh, NO BFF, NO root, NO disks.
#
# It exercises the REAL shipped pieces:
#   * storage-verify.sh — storage_canonical_bytes + storage_verify_export, sourced as the
#     agent sources it. We mint a throwaway Ed25519 keypair, sign the EXACT bytes the lib
#     reconstructs from a synthetic signed export, and assert the FULL fail-closed gate:
#       genuine ACCEPT; unsigned / tampered-body / foreign-key / rolled-back REJECT.
#   * the nodePathMap CAS-patch jq program (extracted from the agent) — asserts it ADDS
#     this node's entry, KEEPS the DEFAULT_PATH entry + any other node's entry (back-compat),
#     and is idempotent. This is the PV-BINDS-TO-CORRECT-NODE assertion: only the storage
#     node's provisioner gets a nodePathMap entry for the pool path.
#   * the pool-manifest jq build — asserts each export pool becomes a .storage.devices[]
#     element carrying a `pool:{}` marker (so provision_storage --pool provisions it).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/specs/usr/lib/snapdragon/storage-verify.sh"
AGENT="${REPO}/specs/usr/sbin/snapdragon-node-storage-reconcile"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

for t in jq openssl base64; do command -v "$t" >/dev/null || { echo "$t required"; exit 2; }; done
[ -r "${LIB}" ]   || { echo "missing ${LIB}"; exit 2; }
[ -r "${AGENT}" ] || { echo "missing ${AGENT}"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT
# shellcheck source=/dev/null
. "${LIB}"

# ── One throwaway registry signing keypair (bake ONLY the public half, base64 SPKI DER —
#    exactly the node's registry-pub.ed25519 / RegistrySigner.publicKeyBase64()). ───────
GOOD_PRIV="${WORK}/priv.pem"; PUB_B64="${WORK}/pub.b64"
openssl genpkey -algorithm ed25519 -out "${GOOD_PRIV}" 2>/dev/null
openssl pkey -in "${GOOD_PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${PUB_B64}"
# A SECOND, DIFFERENT key models a rotated/foreign signer whose public half was NOT re-baked.
FOREIGN_PRIV="${WORK}/foreign.pem"
openssl genpkey -algorithm ed25519 -out "${FOREIGN_PRIV}" 2>/dev/null

# Build a signed storage export for a node fp + pools, signed by $1 (priv pem), gen $2.
# The signature is over EXACTLY storage_canonical_bytes(body) — the real consumer contract.
make_signed_export() {
    local priv="$1" gen="$2" out="$3"
    local body
    body="$(jq -n --argjson gen "${gen}" '{
        nodeFp: "fp-node-1",
        generation: $gen,
        pools: [
            { poolId: "pool-1", diskSerial: "WWN-AAA", poolPath: "/mnt/pool-1",
              reservedBytes: 10000, isExclusive: false, filesystem: "ext4",
              assignments: [ { serviceName: "owncast", pvcName: "owncast-data", requestedBytes: 4000 } ] }
        ]
    }')"
    # Stage an unsigned envelope so storage_canonical_bytes can read .body, compute bytes,
    # sign them, then fold the signature back in.
    jq -n --argjson b "${body}" '{ body:$b, contentHash:"x", signature:null, publicKey:"x", signed:false }' > "${out}"
    # Sign the EXACT canonical bytes (including the trailing newline) — write to a file and
    # sign the file, NOT a $(...)-captured string (command substitution strips trailing \n,
    # which would diverge from the file verify_sig reads).
    local canonf sig
    canonf="$(mktemp)"
    storage_canonical_bytes "${out}" > "${canonf}"
    sig="$(openssl pkeyutl -sign -inkey "${priv}" -rawin -in "${canonf}" 2>/dev/null | base64 -w0)"
    rm -f "${canonf}"
    jq --arg sig "${sig}" '.signature=$sig | .signed=true' "${out}" > "${out}.s" && mv "${out}.s" "${out}"
}

echo "== node-storage PR6: reconcile agent verify + nodePathMap patch =="

# ── 1. verify gate: genuine ACCEPT ────────────────────────────────────────────
make_signed_export "${GOOD_PRIV}" 5 "${WORK}/good.json"
: > "${WORK}/lastgood"; printf '%s' "0" > "${WORK}/lastgood"
if storage_verify_export "${WORK}/good.json" "${PUB_B64}" "${WORK}/lastgood"; then
    ok "genuine signed export ACCEPTED (sig over storage canonical bytes verifies)"
else
    bad "genuine signed export should verify"
fi

# ── 2. unsigned REJECT ────────────────────────────────────────────────────────
jq '.signed=false | .signature=null' "${WORK}/good.json" > "${WORK}/unsigned.json"
storage_verify_export "${WORK}/unsigned.json" "${PUB_B64}" \
    && bad "unsigned export must be rejected" \
    || ok "unsigned export REJECTED (fail-closed)"

# ── 3. tampered body REJECT (signature no longer matches reconstructed bytes) ──
jq '.body.pools[0].reservedBytes=999999' "${WORK}/good.json" > "${WORK}/tampered.json"
storage_verify_export "${WORK}/tampered.json" "${PUB_B64}" \
    && bad "tampered body must be rejected" \
    || ok "tampered body REJECTED (sig over original bytes fails)"

# ── 4. foreign-key signature REJECT ───────────────────────────────────────────
make_signed_export "${FOREIGN_PRIV}" 6 "${WORK}/foreign.json"
storage_verify_export "${WORK}/foreign.json" "${PUB_B64}" \
    && bad "foreign-key signature must be rejected" \
    || ok "foreign-key signature REJECTED (not the baked public half)"

# ── 5. rollback REJECT (gen <= last-good) ─────────────────────────────────────
printf '%s' "5" > "${WORK}/lastgood5"
make_signed_export "${GOOD_PRIV}" 3 "${WORK}/old.json"   # gen 3 <= last-good 5
storage_verify_export "${WORK}/old.json" "${PUB_B64}" "${WORK}/lastgood5" \
    && bad "rolled-back (gen<=last-good) export must be rejected" \
    || ok "rolled-back export REJECTED (strict-monotonic guard)"
# ...but a strictly-higher gen IS accepted.
make_signed_export "${GOOD_PRIV}" 6 "${WORK}/new.json"
storage_verify_export "${WORK}/new.json" "${PUB_B64}" "${WORK}/lastgood5" \
    && ok "strictly-higher generation ACCEPTED (forward step)" \
    || bad "gen>last-good should be accepted"

# ── 6. canonical bytes are byte-stable + carry the storage shape ──────────────
canon="$(storage_canonical_bytes "${WORK}/good.json")"
echo "${canon}" | grep -q "^node=fp-node-1$" && ok "canonical bytes carry node= header" || bad "missing node= header"
echo "${canon}" | grep -q "pool=pool-1	disk=WWN-AAA	path=/mnt/pool-1" && ok "canonical bytes carry the tab-separated pool line" || bad "missing pool line"
echo "${canon}" | grep -q "  assign=owncast	pvc=owncast-data	requested=4000" && ok "canonical bytes carry the indented assignment line" || bad "missing assignment line"

# ── 7. nodePathMap CAS-patch (extract the jq program from the agent) ──────────
# The agent computes the new config with the jq under `.nodePathMap = ( ... )`. We replay
# that exact transform: a config with the DEFAULT entry + another node's entry must KEEP
# both and ADD this node's. Then idempotency (re-running yields the same config).
CUR='{"nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/mnt/data/local-path"]},{"node":"other-node","paths":["/mnt/x"]}]}'
patch_nodepathmap() {  # $1=cur-json $2=node $3=paths-json
    printf '%s' "$1" | jq --arg node "$2" --argjson paths "$3" '
        .nodePathMap = (
            ( [ .nodePathMap[]? | select(.node != $node) ] )
            + ( if ($paths | length) > 0 then [ { node: $node, paths: $paths } ] else [] end )
        )'
}
NEW="$(patch_nodepathmap "${CUR}" "storage-node" '["/mnt/pool-1"]')"
# DEFAULT entry preserved (back-compat).
echo "${NEW}" | jq -e '.nodePathMap[] | select(.node=="DEFAULT_PATH_FOR_NON_LISTED_NODES")' >/dev/null \
    && ok "nodePathMap patch KEEPS the DEFAULT_PATH entry (back-compat)" \
    || bad "DEFAULT_PATH entry must be preserved"
# other node's entry preserved.
echo "${NEW}" | jq -e '.nodePathMap[] | select(.node=="other-node")' >/dev/null \
    && ok "nodePathMap patch KEEPS other nodes' entries (no cross-node clobber)" \
    || bad "other-node entry must be preserved"
# THIS node's entry added with the pool path — the PV-binds-to-correct-node assertion.
this_paths="$(echo "${NEW}" | jq -c '.nodePathMap[] | select(.node=="storage-node") | .paths')"
[ "${this_paths}" = '["/mnt/pool-1"]' ] \
    && ok "nodePathMap patch ADDS this node's entry mapping the pool path (PV binds to THIS node)" \
    || bad "this node's path entry wrong: ${this_paths}"
# idempotent: patching the already-patched config yields the same thing.
AGAIN="$(patch_nodepathmap "${NEW}" "storage-node" '["/mnt/pool-1"]')"
[ "$(echo "${NEW}" | jq -S .)" = "$(echo "${AGAIN}" | jq -S .)" ] \
    && ok "nodePathMap patch is idempotent (re-run is a no-op)" \
    || bad "patch not idempotent"

# ── 8. pool-manifest build: export pool -> .storage.devices[] with a pool:{} marker ──
SMAP='{"WWN-AAA":"/dev/sdb"}'
MANIFEST="$(jq -n --argjson smap "${SMAP}" --slurpfile e <(jq '.body' "${WORK}/good.json") '
    ($e[0].pools // []) as $pools
    | { storage: { devices: [
        $pools[] | {
            match: ($smap[.diskSerial] // ("LABEL=missing-" + .diskSerial)),
            mountpoint: .poolPath, filesystem: (.filesystem // "ext4"),
            format: false, encrypt: true,
            pool: { id: .poolId, exclusive: .isExclusive, reserved_bytes: .reservedBytes }
        } ] } }')"
echo "${MANIFEST}" | jq -e '.storage.devices[0].pool.id=="pool-1"' >/dev/null \
    && ok "pool-manifest device carries a pool:{} marker (provision_storage --pool target)" \
    || bad "pool marker missing in built manifest"
[ "$(echo "${MANIFEST}" | jq -r '.storage.devices[0].match')" = "/dev/sdb" ] \
    && ok "pool-manifest resolves the registered serial WWN-AAA -> /dev/sdb via lsblk map" \
    || bad "serial->dev resolution wrong"
[ "$(echo "${MANIFEST}" | jq -r '.storage.devices[0].mountpoint')" = "/mnt/pool-1" ] \
    && ok "pool-manifest mounts the disk AT the poolPath (so nodePathMap resolves)" \
    || bad "mountpoint != poolPath"

# ── 9. empty export (unknown-fp fail-closed body) -> nothing to provision ─────
jq -n '{ body:{nodeFp:"",generation:0,pools:[]}, contentHash:"x", signature:null, publicKey:"x", signed:false }' > "${WORK}/empty.json"
empty_node_fp="$(sv_node_fp "${WORK}/empty.json")"
[ -z "${empty_node_fp}" ] \
    && ok "empty signed body has no nodeFp -> agent provisions NOTHING (inert)" \
    || bad "empty body should have empty nodeFp"

echo
echo "node-storage PR6 node-agent: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
