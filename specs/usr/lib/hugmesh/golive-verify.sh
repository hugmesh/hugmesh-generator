# shellcheck shell=bash
# golive-verify.sh — the consumer-half verifier for the SIGNED go-live-intent
# export (admin-bff-api GoLiveExportService, PR #200). SOURCES the shared
# registry-verify.sh for the IDENTICAL detached-Ed25519 verify (verify_sig) +
# strict-monotonic rollback guard (check_monotonic) + signed-envelope check
# (rv_signed/rv_signature/rv_gen) — the SAME bean (RegistrySigner) signs both the
# domain-registry and go-live exports, so a crypto/rollback divergence can NEVER
# arise between the two consumers. Only the CANONICAL-BYTES reconstruction differs
# (a set of go-live intents, not domain entries), so this file adds ONLY
# golive_canonical_bytes + golive_verify_export — a direct structural clone of
# domain-verify.sh, same idiom.
#
# It implements the consumer half of THE GO-LIVE EXPORT CONTRACT
# (hugmesh-admin-bff-api GoLiveExportService.canonicalBytes, PR #200), which
# MUST match BYTE FOR BYTE:
#
#   canonical bytes = line-oriented UTF-8:
#       v1-golive\n
#       node=<body.node>\n
#       generation=<long>\n
#     then, IN ARRAY ORDER (the server already sorted entries by clusterDomain —
#     we do NOT re-sort), ONE TAB-separated line per RECORDED intent entry:
#       dom=<clusterDomain>\tstate=<targetState>\tmodel=<exposureModel>\tprovider=<provider>\tby=<requestedBy>\tintent=<intentId>\tgen=<generation>\n
#
#   nz(): a null field becomes the empty string (jq's // "" mirrors the Java nz()).
#
# SEMANTICS (GoLiveExportModels.java / GoLiveIntent.java class docs — NOT
# byte-format, but load-bearing for the agent that calls this):
#   - targetState is exactly "public" (write the go-live marker) or "internal"
#     (remove it — rollback rides the SAME intent path, no separate mechanism).
#   - the export carries only currently-RECORDED intents (at most one per domain,
#     enforced server-side by supersede-on-record); a WITHDRAWN or already-APPLIED
#     intent is OMITTED. ABSENCE of an entry for a domain means "nothing NEW to
#     apply" — a fail-closed consumer must NOT infer marker deletion from absence,
#     only from an EXPLICIT targetState=internal entry.
#   - generation is the max over ALL rows (including withdrawn/applied), so it
#     still advances even when entries[] is empty — the monotonic guard below
#     still works on a steady-state (no pending intent) export.
#
# Every function is FAIL-CLOSED: any malformed input, missing tool, or verify
# failure returns non-zero (the caller keeps its last-good cache / applies
# NOTHING).
#
# VALIDATION STATUS: the canonical reconstruction is a structural mirror of
# domain-verify.sh's (itself round-trip tested against the Java shape, see that
# file's header) and of the Java canonicalBytes() source read directly off
# origin/main for this file's authorship. End-to-end equality with a LIVE BFF
# payload can only be confirmed on a booted node against a running admin-bff-api.
# If the JVM ever emits a field this reconstruction does not mirror, verify FAILS
# CLOSED (never applies a go-live/rollback action).

_gv_have() { command -v "$1" >/dev/null 2>&1; }

# Source the shared registry verifier (verify_sig / check_monotonic / rv_signed /
# rv_signature / rv_gen). Resolved relative to this file so it works from the
# image path AND the test repo path (identical pattern to domain-verify.sh).
_gv_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if   [ -r "${_gv_self_dir}/registry-verify.sh" ]; then
    # shellcheck source=/dev/null
    . "${_gv_self_dir}/registry-verify.sh"
elif [ -r /usr/lib/hugmesh/registry-verify.sh ]; then
    # shellcheck source=/dev/null
    . /usr/lib/hugmesh/registry-verify.sh
else
    echo "golive-verify: registry-verify.sh missing" >&2
    return 1
fi

# ── golive_canonical_bytes <export.json> -> stdout ─────────────────────────────
# Reconstruct GoLiveExportService.canonicalBytes from the signed envelope JSON.
# Emits the EXACT bytes the detached signature covers. Non-zero (prints nothing)
# on parse error.
golive_canonical_bytes() {
    local export_json="$1"
    [ -n "${export_json}" ] && [ -r "${export_json}" ] || return 1
    _gv_have jq || return 1
    jq -j -e '
        (.body // error("no body")) as $b
        | "v1-golive\n"
        + "node=" + (($b.node // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + ( ([ $b.entries[]?
              | "dom=" + (.clusterDomain // "")
              + "\tstate=" + (.targetState // "")
              + "\tmodel=" + (.exposureModel // "")
              + "\tprovider=" + (.provider // "")
              + "\tby=" + (.requestedBy // "")
              + "\tintent=" + (.intentId // "")
              + "\tgen=" + ((.generation // 0)|tostring)
              + "\n"
            ]) | add // "" )
    ' "${export_json}" 2>/dev/null
}

# ── golive_verify_export <export.json> <pubkey-b64-file> [strict-gen-file] -> rc ─
# FULL fail-closed acceptance gate for the go-live reconcile (mirror of
# domain_verify_export):
#   (1) envelope signed (rv_signed) and carries a signature;
#   (2) reconstruct GO-LIVE canonical bytes + verify the detached Ed25519
#       signature against the BAKED public key (verify_sig, shared — the
#       advertised .publicKey is IGNORED for trust);
#   (3) [optional] strict monotonicity (candidate gen > last-good) via
#       check_monotonic.
# Prints NOTHING; returns 0 only on full acceptance.
golive_verify_export() {
    local export_json="$1" pub_b64_file="$2" strict_gen_file="${3:-}"
    rv_signed "${export_json}" || return 1
    local sig canon_tmp gen rc=1
    sig="$(rv_signature "${export_json}")" || return 1
    [ -n "${sig}" ] || return 1
    canon_tmp="$(mktemp 2>/dev/null)" || return 1
    if ! golive_canonical_bytes "${export_json}" > "${canon_tmp}" 2>/dev/null; then
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

# ── gv_node <export.json> -> stdout (the body.node provenance fp) ──────────────
gv_node() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _gv_have jq || return 1
    jq -r -e '.body.node // empty' "${export_json}" 2>/dev/null
}

# ── gv_entry_for_domain <export.json> <clusterDomain> -> stdout (one JSON object, or nothing) ─
# Extract the SINGLE entry (if any) matching this node's own CLUSTER_DOMAIN. A
# node's go-live marker is single-tenant (one host, one domain) — unlike the
# cross-domain export body, which may (in a multi-brand deployment) carry entries
# for domains this node does not own; the agent must act ONLY on its own domain's
# entry and ignore the rest. Prints nothing (and returns 1) when absent — the
# caller's absence-means-no-op contract (see file header) starts here.
gv_entry_for_domain() {
    local export_json="$1" dom="$2"
    [ -r "${export_json}" ] && [ -n "${dom}" ] || return 1
    _gv_have jq || return 1
    jq -e --arg dom "${dom}" '
        (.body.entries // []) | map(select(.clusterDomain == $dom)) | first // empty
    ' "${export_json}" 2>/dev/null
}
