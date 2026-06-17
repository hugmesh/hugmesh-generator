# shellcheck shell=bash
# vpn-verify.sh — SHARED, sourced verification helper for the egress-VPN signed
# per-node export. The consumer half of THE VPN EXPORT CONTRACT
# (snapdragon-admin-bff-api VpnExportService): it reconstructs the canonical bytes
# the detached Ed25519 signature covers and verifies them against the BAKED
# key-USB public half (the SAME registry-pub.ed25519 Layer-B uses — never re-bake).
#
# It CLONES /usr/lib/snapdragon/registry-verify.sh (the device-license-registry
# verifier) byte-for-byte in approach — only the canonical reconstruction differs
# (the v1-vpn body shape vs the v1 device-registry body). Every function is
# FAIL-CLOSED: any malformed input, missing tool, or verify failure returns
# non-zero (the agent keeps its last-good cache / leaves the service as-is).
#
#   canonical bytes = line-oriented UTF-8 (must match VpnExportService.canonicalBytes
#   BYTE FOR BYTE):
#       v1-vpn\n
#       node=<machineKeyFp>\n
#       generation=<long>\n
#     then ONE line per egress entry, in ARRAY ORDER (server already sorted by
#     configName — we DO NOT re-sort):
#       cfg=<name>\tkind=<kind>\tsecret=<secretRef>\tendpoint=<ep>\tservices=<csv>\n
#
#   detached Ed25519 signature over EXACTLY those bytes; strict-monotonic
#   generation rollback guard (gen MUST be > last-good).
#
# NOTE on validation status: the canonical reconstruction + the openssl Ed25519
# verify path are syntactically validated + round-trip-tested off-node; end-to-end
# equality with a LIVE BFF /export payload can only be confirmed on a booted node
# against a running admin-bff-api. If the JVM ever emits a field this does not
# mirror, verify FAILS CLOSED.

_vv_have() { command -v "$1" >/dev/null 2>&1; }

# ── vpn_canonical_bytes <export.json> -> stdout ────────────────────────────────
# Reconstruct VpnExportService.canonicalBytes from the signed envelope JSON. Emits
# the EXACT bytes the detached signature covers. Non-zero (prints nothing) on any
# parse error => caller fail-closes. jq -j (raw, no trailing newline) + explicit
# "\n"/"\t" so output is deterministic. The body lives under .body
# (SignedVpnExport.body == VpnExportBody{node, generation, entries[]}).
vpn_canonical_bytes() {
    local export_json="$1"
    [ -n "${export_json}" ] && [ -r "${export_json}" ] || return 1
    _vv_have jq || return 1
    jq -j -e '
        (.body // error("no body")) as $b
        | "v1-vpn\n"
        + "node=" + (($b.node // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + ( ([$b.entries[]?
              | "cfg=" + (.configName // "")
              + "\tkind=" + (.kind // "")
              + "\tsecret=" + (.secretRef // "")
              + "\tendpoint=" + (.endpoint // "")
              + "\tservices=" + ((.serviceSlugs // []) | join(","))
              + "\n"
            ]) | add // "" )
    ' "${export_json}" 2>/dev/null
}

# ── vpn_verify_sig <canonical-file> <sig-b64> <pubkey-b64-file> -> rc ──────────
# Verify a detached Ed25519 signature (base64) over the canonical bytes file using
# the BAKED public verifying half (base64 X.509 SPKI DER == RegistrySigner.
# publicKeyBase64()). 0 iff the signature verifies; non-zero (fail-closed) on ANY
# error. Identical openssl-3 path to registry-verify.sh's verify_sig.
vpn_verify_sig() {
    local canonical="$1" sig_b64="$2" pub_b64_file="$3"
    [ -n "${canonical}" ] && [ -r "${canonical}" ] || return 1
    [ -n "${sig_b64}" ] || return 1
    [ -n "${pub_b64_file}" ] && [ -r "${pub_b64_file}" ] || return 1
    _vv_have openssl || return 1
    _vv_have base64 || return 1

    local tmp pub_pem sig_bin rc=1
    tmp="$(mktemp -d 2>/dev/null)" || return 1
    pub_pem="${tmp}/pub.pem"
    sig_bin="${tmp}/sig.bin"
    if ! base64 -d "${pub_b64_file}" 2>/dev/null \
            | openssl pkey -pubin -inform DER -out "${pub_pem}" 2>/dev/null; then
        rm -rf "${tmp}"; return 1
    fi
    if ! printf '%s' "${sig_b64}" | base64 -d > "${sig_bin}" 2>/dev/null; then
        rm -rf "${tmp}"; return 1
    fi
    if openssl pkeyutl -verify -pubin -inkey "${pub_pem}" \
            -rawin -in "${canonical}" -sigfile "${sig_bin}" >/dev/null 2>&1; then
        rc=0
    fi
    rm -rf "${tmp}"
    return "${rc}"
}

# ── vpn_check_monotonic <candidate-gen> <last-good-file> -> rc ─────────────────
# STRICT-monotonic rollback guard. 0 iff candidate > last-good (strictly). An
# absent/empty/non-numeric last-good is treated as -1 (first sync of gen>=0
# accepted); a non-numeric candidate is REJECTED (fail-closed). Identical to
# registry-verify.sh's check_monotonic.
vpn_check_monotonic() {
    local cand="$1" last_good_file="$2" last="-1"
    case "${cand}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ -n "${last_good_file}" ] && [ -r "${last_good_file}" ]; then
        last="$(tr -dc '0-9' < "${last_good_file}" 2>/dev/null)"
        [ -n "${last}" ] || last="-1"
    fi
    [ "${cand}" -gt "${last}" ] 2>/dev/null
}

vpn_gen()  { jq -r -e '.body.generation // empty' "$1" 2>/dev/null; }
vpn_node() { jq -r -e '.body.node // empty' "$1" 2>/dev/null; }

# ── vpn_signed <export.json> -> rc ─────────────────────────────────────────────
# 0 iff the envelope claims signed AND carries a non-null signature. Unsigned is
# REJECTED (fail-closed): the BFF serves unsigned only when it has no signing key.
vpn_signed() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _vv_have jq || return 1
    [ "$(jq -r '.signed // false' "${export_json}" 2>/dev/null)" = "true" ] || return 1
    [ "$(jq -r 'if .signature == null then "null" else "ok" end' "${export_json}" 2>/dev/null)" = "ok" ]
}

vpn_signature() { jq -r -e '.signature // empty' "$1" 2>/dev/null; }

# ── vpn_verify_export <export.json> <pubkey-b64-file> [strict-gen-file] -> rc ──
# The FULL fail-closed acceptance gate: (1) signed; (2) reconstruct canonical bytes
# + verify the detached Ed25519 against the BAKED key; (3) [optional] STRICT
# monotonicity (gen > last-good). Prints NOTHING; 0 only on full acceptance.
vpn_verify_export() {
    local export_json="$1" pub_b64_file="$2" strict_gen_file="${3:-}"
    vpn_signed "${export_json}" || return 1
    local sig canon_tmp gen rc=1
    sig="$(vpn_signature "${export_json}")" || return 1
    [ -n "${sig}" ] || return 1
    canon_tmp="$(mktemp 2>/dev/null)" || return 1
    if ! vpn_canonical_bytes "${export_json}" > "${canon_tmp}" 2>/dev/null; then
        rm -f "${canon_tmp}"; return 1
    fi
    [ -s "${canon_tmp}" ] || { rm -f "${canon_tmp}"; return 1; }
    if vpn_verify_sig "${canon_tmp}" "${sig}" "${pub_b64_file}"; then rc=0; fi
    rm -f "${canon_tmp}"
    [ "${rc}" -eq 0 ] || return 1
    if [ -n "${strict_gen_file}" ]; then
        gen="$(vpn_gen "${export_json}")" || return 1
        vpn_check_monotonic "${gen}" "${strict_gen_file}" || return 1
    fi
    return 0
}
