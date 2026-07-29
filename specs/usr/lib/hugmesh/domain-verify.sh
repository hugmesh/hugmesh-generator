# shellcheck shell=bash
# domain-verify.sh — the consumer-half verifier for the SIGNED CROSS-DOMAIN DOMAIN-REGISTRY
# export (the generator domain_registry -> brand-repo bridge, #4). SOURCES the shared
# registry-verify.sh for the IDENTICAL detached-Ed25519 verify (verify_sig) + strict-monotonic
# rollback guard (check_monotonic) + signed-envelope check (rv_signed/rv_signature/rv_gen), so a
# crypto/rollback divergence can NEVER arise between the device-license, node-storage, egress-VPN
# and domain-registry consumers. Only the CANONICAL-BYTES reconstruction differs (the domain
# export body is a cross-domain set of domain entries, not operators/pools/vpn-configs), so this
# file adds ONLY domain_canonical_bytes + domain_verify_export.
#
# It implements the consumer half of THE DOMAIN-REGISTRY EXPORT CONTRACT
# (hugmesh-admin-bff-api DomainRegistryExportService.canonicalBytes, #118), which MUST match
# BYTE FOR BYTE:
#
#   canonical bytes = line-oriented UTF-8:
#       v1-domain\n
#       node=<body.node>\n
#       generation=<long>\n
#     then, IN ARRAY ORDER (the server already sorted entries by clusterDomain — we do NOT
#     re-sort), ONE TAB-separated line per domain entry:
#       dom=<clusterDomain>\tbrand=<brand>\torg=<org>\tca=<caRef>\tns=<nsPrefix>\tcasdoor=<casdoorOrg>\tmesh=<meshTag>\tca_prov=<true|false>\tappset=<true|false>\tgen=<generation>\n
#
#   nz(): a null field becomes the empty string (jq's // "" mirrors the Java nz()).
#   booleans render as Java true/false lowercase (jq's tostring on a bool).
#
# NOTE on the body: the domain export is CROSS-DOMAIN by design (the full registered set, not a
# per-node slice), so — unlike device-registry's ?mesh= guard — there is NO meshId field in the
# body and the consumer does NOT apply a mesh guard. The ?node= query param is PROVENANCE-only.
#
# Every function is FAIL-CLOSED: any malformed input, missing tool, or verify failure returns
# non-zero (the bridge keeps its last-good cache / emits NOTHING — no CA, no brand repo).
#
# VALIDATION STATUS: the canonical reconstruction is round-trip tested off-node against the Java
# DomainRegistryExportService.canonicalBytes shape (tests/domain-registry/test-domain-reconcile-verify.sh
# mints a throwaway Ed25519 key, signs the EXACT bytes this reconstructs, and asserts verify
# accepts the genuine + rejects unsigned/tampered/foreign/rolled-back). End-to-end equality with a
# LIVE BFF payload can only be confirmed on a booted node against a running admin-bff (see the PR
# body VERIFIED-vs-NEEDS-NODE matrix). If the JVM ever emits a field this reconstruction does not
# mirror, verify FAILS CLOSED.

_dv_have() { command -v "$1" >/dev/null 2>&1; }

# Source the shared registry verifier (verify_sig / check_monotonic / rv_signed / rv_signature /
# rv_gen). Resolved relative to this file so it works from the image path AND the test repo path
# (identical pattern to storage-verify.sh:42-49).
_dv_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if   [ -r "${_dv_self_dir}/registry-verify.sh" ]; then
    # shellcheck source=/dev/null
    . "${_dv_self_dir}/registry-verify.sh"
elif [ -r /usr/lib/hugmesh/registry-verify.sh ]; then
    # shellcheck source=/dev/null
    . /usr/lib/hugmesh/registry-verify.sh
else
    echo "domain-verify: registry-verify.sh missing" >&2
    return 1
fi

# ── domain_canonical_bytes <export.json> -> stdout ─────────────────────────────────
# Reconstruct DomainRegistryExportService.canonicalBytes from the signed envelope JSON. Emits
# the EXACT bytes the detached signature covers. Non-zero (prints nothing) on parse error.
# Mirrors the proven jq -j idiom from registry-verify.sh:55 / storage-verify.sh:54 — raw output,
# no trailing newline, explicit "\n"/"\t" so the bytes are deterministic + locale-independent.
domain_canonical_bytes() {
    local export_json="$1"
    [ -n "${export_json}" ] && [ -r "${export_json}" ] || return 1
    _dv_have jq || return 1
    jq -j -e '
        (.body // error("no body")) as $b
        | "v1-domain\n"
        + "node=" + (($b.node // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + ( ([ $b.entries[]?
              | "dom=" + (.clusterDomain // "")
              + "\tbrand=" + (.brand // "")
              + "\torg=" + (.org // "")
              + "\tca=" + (.caRef // "")
              + "\tns=" + (.nsPrefix // "")
              + "\tcasdoor=" + (.casdoorOrg // "")
              + "\tmesh=" + (.meshTag // "")
              + "\tca_prov=" + ((.caProvisioned // false)|tostring)
              + "\tappset=" + ((.appsetRegistered // false)|tostring)
              + "\tgen=" + ((.generation // 0)|tostring)
              + "\n"
            ]) | add // "" )
    ' "${export_json}" 2>/dev/null
}

# ── domain_verify_export <export.json> <pubkey-b64-file> [strict-gen-file] -> rc ──
# FULL fail-closed acceptance gate for the domain-registry reconcile (mirror of
# storage_verify_export):
#   (1) envelope signed (rv_signed) and carries a signature;
#   (2) reconstruct DOMAIN canonical bytes + verify the detached Ed25519 signature against the
#       BAKED public key (verify_sig, shared — the advertised .publicKey is IGNORED for trust);
#   (3) [optional] strict monotonicity (candidate gen > last-good) via check_monotonic.
# Prints NOTHING; returns 0 only on full acceptance.
domain_verify_export() {
    local export_json="$1" pub_b64_file="$2" strict_gen_file="${3:-}"
    rv_signed "${export_json}" || return 1
    local sig canon_tmp gen rc=1
    sig="$(rv_signature "${export_json}")" || return 1
    [ -n "${sig}" ] || return 1
    canon_tmp="$(mktemp 2>/dev/null)" || return 1
    if ! domain_canonical_bytes "${export_json}" > "${canon_tmp}" 2>/dev/null; then
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

# ── dv_node <export.json> -> stdout (the body.node provenance fp) ───────────────────
dv_node() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _dv_have jq || return 1
    jq -r -e '.body.node // empty' "${export_json}" 2>/dev/null
}
