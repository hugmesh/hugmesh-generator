# shellcheck shell=bash
# tor-verify.sh — the consumer-half verifier for the SIGNED PER-NODE TOR EXPORT
# (hugmesh-admin-bff-api#108 / #112, consumed by /usr/sbin/hugmesh-tor-export-sync,
# hugmesh-generator#629). SOURCES the shared registry-verify.sh for the IDENTICAL
# detached-Ed25519 verify (verify_sig), strict-monotonic rollback guard (check_monotonic)
# and signed-envelope checks (rv_signed / rv_signature), exactly as storage-verify.sh
# does, so a crypto or rollback divergence can never arise between the device-license,
# node-storage and Tor consumers. (registry-verify.sh is baked into every rpi5 AND x86
# node image; vpn-verify.sh is not, so it is not the base here.) Only the CANONICAL-BYTES
# reconstruction differs, so this file adds tor_canonical_bytes + tor_verify_export and
# a few field getters.
#
# THE TOR EXPORT CONTRACT (hugmesh-admin-bff-api TorExportService.canonicalBytes, pinned
# by TorExportServiceTest.canonicalBytes_spellTheContract) — MUST match BYTE FOR BYTE.
# It is NOT JSON (so there is no field-order ambiguity). Line-oriented UTF-8, every line
# ends in "\n":
#
#   v1-tor\n
#   node=<machineKeyFp>\n
#   generation=<long>\n
#   upstream-managed=<true|false>\n
#   upstream=<host:port or empty>\n
#   domains-managed=<true|false>\n
#   domain=<slug>\n            (one per slug, in ARRAY ORDER — the server already
#                               sorted them; we do NOT re-sort)
#
#   nz(): a null string becomes the empty string (jq's // "" mirrors this); a null
#   boolean is read as false; a null generation as 0.
#
# The signature is a detached Ed25519 over exactly those bytes, verified against the
# BAKED key-USB public half /etc/hugmesh/registry/registry-pub.ed25519 (base64 X.509
# SPKI DER == RegistrySigner.publicKeyBase64()). The envelope's contentHash is SHA-256
# over the same bytes; it is not checked here (the signature covers the bytes).
#
# Every function is FAIL-CLOSED: any malformed input, missing tool, or verify failure
# returns non-zero (the agent keeps the last-good files and changes nothing).
#
# VALIDATION STATUS: round-trip tested off-node (tests/scripts/test-tor-export-sync.sh
# asserts the reconstruction against a reference string, mints a throwaway Ed25519 key,
# signs those exact bytes and drives the agent through accept / unsigned / tampered /
# foreign-key / rolled-back). End-to-end equality with a LIVE admin-bff payload can only
# be confirmed on a booted tor node. If the JVM ever emits a field this reconstruction
# does not mirror, verify FAILS CLOSED.

_tv_have() { command -v "$1" >/dev/null 2>&1; }

# Source the shared registry verifier (verify_sig / check_monotonic / rv_signed /
# rv_signature / rv_gen). Resolved relative to this file so it works from the image path
# AND the test repo path.
_tv_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -r "${_tv_self_dir}/registry-verify.sh" ]; then
    # shellcheck source=/dev/null
    . "${_tv_self_dir}/registry-verify.sh"
elif [ -r /usr/lib/hugmesh/registry-verify.sh ]; then
    # shellcheck source=/dev/null
    . /usr/lib/hugmesh/registry-verify.sh
fi

# ── tor_canonical_bytes <export.json> -> stdout ────────────────────────────────────
# Reconstruct TorExportService.canonicalBytes from the signed envelope JSON. Emits the
# EXACT bytes the detached signature covers. Non-zero (prints nothing) on any parse
# error => the caller fail-closes. jq -j (raw, no trailing newline) + explicit "\n".
tor_canonical_bytes() {
    local export_json
    export_json="$1"
    [ -n "${export_json}" ] && [ -r "${export_json}" ] || return 1
    _tv_have jq || return 1
    jq -j -e '
        (.body // error("no body")) as $b
        | "v1-tor\n"
        + "node=" + (($b.node // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + "upstream-managed=" + (($b.upstreamManaged // false)|tostring) + "\n"
        + "upstream=" + (($b.upstream // "")|tostring) + "\n"
        + "domains-managed=" + (($b.domainsManaged // false)|tostring) + "\n"
        + ( ([ ($b.domains // [])[] | "domain=" + (.|tostring) + "\n" ]) | add // "" )
    ' "${export_json}" 2>/dev/null
}

# Field getters (empty / non-zero on error). Booleans print "true" or "false".
tor_gen()              { jq -r -e '.body.generation // empty' "$1" 2>/dev/null; }
tor_node()             { jq -r -e '.body.node // empty' "$1" 2>/dev/null; }
tor_upstream_managed() { jq -r '.body.upstreamManaged // false' "$1" 2>/dev/null; }
tor_upstream()         { jq -r '.body.upstream // ""' "$1" 2>/dev/null; }
tor_domains_managed()  { jq -r '.body.domainsManaged // false' "$1" 2>/dev/null; }
# One slug per line, array order, nothing else (an empty list prints nothing).
tor_domains()          { jq -r '(.body.domains // [])[] | tostring' "$1" 2>/dev/null; }

# ── tor_verify_export <export.json> <pubkey-b64-file> [strict-gen-file] -> rc ───────
# The FULL fail-closed acceptance gate: (1) signed (signed==true && signature!=null);
# (2) reconstruct the canonical bytes + verify the detached Ed25519 against the BAKED
# key; (3) [optional] STRICT monotonicity (gen > last-good). Prints NOTHING; 0 only on
# full acceptance. Identical in shape to verify_export / storage_verify_export.
tor_verify_export() {
    local export_json pub_b64_file strict_gen_file sig canon_tmp gen rc
    export_json="$1"; pub_b64_file="$2"; strict_gen_file="${3:-}"; rc=1
    declare -F rv_signed >/dev/null 2>&1 || return 1   # registry-verify.sh not sourced
    rv_signed "${export_json}" || return 1
    sig="$(rv_signature "${export_json}")" || return 1
    [ -n "${sig}" ] || return 1
    canon_tmp="$(mktemp 2>/dev/null)" || return 1
    if ! tor_canonical_bytes "${export_json}" > "${canon_tmp}" 2>/dev/null; then
        rm -f "${canon_tmp}"; return 1
    fi
    [ -s "${canon_tmp}" ] || { rm -f "${canon_tmp}"; return 1; }
    if verify_sig "${canon_tmp}" "${sig}" "${pub_b64_file}"; then rc=0; fi
    rm -f "${canon_tmp}"
    [ "${rc}" -eq 0 ] || return 1
    if [ -n "${strict_gen_file}" ]; then
        gen="$(tor_gen "${export_json}")" || return 1
        check_monotonic "${gen}" "${strict_gen_file}" || return 1
    fi
    return 0
}
