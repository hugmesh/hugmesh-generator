# shellcheck shell=bash
# storage-verify.sh — the consumer-half verifier for the SIGNED PER-NODE NODE-STORAGE
# export (node-storage reconcile, Layer-B). SOURCES the shared registry-verify.sh for the
# IDENTICAL detached-Ed25519 verify (verify_sig) + strict-monotonic rollback guard
# (check_monotonic) + signed-envelope check (rv_signed/rv_signature), so a crypto/rollback
# divergence can NEVER arise between the device-license and node-storage consumers. Only the
# CANONICAL-BYTES reconstruction differs (the storage export body is pools+assignments, not
# operators), so this file adds ONLY storage_canonical_bytes + storage_verify_export.
#
# It implements the consumer half of THE STORAGE EXPORT CONTRACT
# (snapdragon-admin-bff-api NodeStorageExportService.canonicalBytes), which MUST match BYTE
# FOR BYTE:
#
#   canonical bytes = line-oriented UTF-8:
#       v1\n
#       node=<machine_key_fp>\n
#       generation=<long>\n
#     then, IN ARRAY ORDER (server already sorted pools by poolId, assignments by
#     serviceName — we do NOT re-sort), per pool:
#       pool=<poolId>\tdisk=<diskSerial>\tpath=<poolPath>\treserved=<long>\texclusive=<bool>\tfs=<filesystem>\n
#     and, indented two spaces, per assignment of that pool:
#       \x20\x20assign=<serviceName>\tpvc=<pvcName>\trequested=<long>\n
#
#   nz(): a null field becomes the empty string (jq's // "" mirrors this).
#
# Every function is FAIL-CLOSED: any malformed input, missing tool, or verify failure
# returns non-zero (caller keeps its last-good cache / does NOT provision).
#
# VALIDATION STATUS: the canonical reconstruction is round-trip tested off-node against the
# Java NodeStorageExportService.canonicalBytes shape (tests/node-storage/test-node-agent.sh
# mints a throwaway Ed25519 key, signs the EXACT bytes this reconstructs, and asserts
# verify accepts the genuine + rejects unsigned/tampered/foreign/rolled-back). End-to-end
# equality with a LIVE BFF payload can only be confirmed on a booted node against a running
# admin-bff (see the PR body VERIFIED-vs-NEEDS-NODE matrix). If the JVM ever emits a field
# this reconstruction does not mirror, verify FAILS CLOSED.

_sv_have() { command -v "$1" >/dev/null 2>&1; }

# Source the shared registry verifier (verify_sig / check_monotonic / rv_signed /
# rv_signature / rv_gen). Resolved relative to this file so it works from the image path
# AND the test repo path.
_sv_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -r "${_sv_self_dir}/registry-verify.sh" ]; then
    # shellcheck source=/dev/null
    . "${_sv_self_dir}/registry-verify.sh"
elif [ -r /usr/lib/snapdragon/registry-verify.sh ]; then
    # shellcheck source=/dev/null
    . /usr/lib/snapdragon/registry-verify.sh
fi

# ── storage_canonical_bytes <export.json> -> stdout ────────────────────────────────
# Reconstruct NodeStorageExportService.canonicalBytes from the signed envelope JSON. Emits
# the EXACT bytes the detached signature covers. Non-zero (prints nothing) on parse error.
storage_canonical_bytes() {
    local export_json="$1"
    [ -n "${export_json}" ] && [ -r "${export_json}" ] || return 1
    _sv_have jq || return 1
    jq -j -e '
        (.body // error("no body")) as $b
        | "v1\n"
        + "node=" + (($b.nodeFp // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + ( ([ $b.pools[]?
              | ( "pool=" + (.poolId // "")
                + "\tdisk=" + (.diskSerial // "")
                + "\tpath=" + (.poolPath // "")
                + "\treserved=" + ((.reservedBytes // 0)|tostring)
                + "\texclusive=" + ((.isExclusive // false)|tostring)
                + "\tfs=" + (.filesystem // "")
                + "\n" )
              + ( ([ .assignments[]?
                    | "  assign=" + (.serviceName // "")
                    + "\tpvc=" + (.pvcName // "")
                    + "\trequested=" + ((.requestedBytes // 0)|tostring)
                    + "\n"
                  ]) | add // "" )
            ]) | add // "" )
    ' "${export_json}" 2>/dev/null
}

# ── storage_verify_export <export.json> <pubkey-b64-file> [strict-gen-file] -> rc ──
# FULL fail-closed acceptance gate for the node-storage reconcile:
#   (1) envelope signed (rv_signed) and carries a signature;
#   (2) reconstruct STORAGE canonical bytes + verify the detached Ed25519 signature against
#       the BAKED public key (verify_sig, shared);
#   (3) [optional] strict monotonicity (candidate gen > last-good) via check_monotonic.
# Prints NOTHING; returns 0 only on full acceptance.
storage_verify_export() {
    local export_json="$1" pub_b64_file="$2" strict_gen_file="${3:-}"
    rv_signed "${export_json}" || return 1
    local sig canon_tmp gen rc=1
    sig="$(rv_signature "${export_json}")" || return 1
    [ -n "${sig}" ] || return 1
    canon_tmp="$(mktemp 2>/dev/null)" || return 1
    if ! storage_canonical_bytes "${export_json}" > "${canon_tmp}" 2>/dev/null; then
        rm -f "${canon_tmp}"; return 1
    fi
    [ -s "${canon_tmp}" ] || { rm -f "${canon_tmp}"; return 1; }
    if verify_sig "${canon_tmp}" "${sig}" "${pub_b64_file}"; then rc=0; fi
    rm -f "${canon_tmp}"
    [ "${rc}" -eq 0 ] || return 1
    if [ -n "${strict_gen_file}" ]; then
        gen="$(rv_gen "${export_json}")" || return 1
        check_monotonic "${gen}" "${strict_gen_file}" || return 1
    fi
    return 0
}

# ── sv_node_fp <export.json> -> stdout (the node machine_key_fp in the body) ───────
sv_node_fp() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _sv_have jq || return 1
    jq -r -e '.body.nodeFp // empty' "${export_json}" 2>/dev/null
}
