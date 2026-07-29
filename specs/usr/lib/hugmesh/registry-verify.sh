# shellcheck shell=bash
# registry-verify.sh — SHARED, sourced verification helper for the device-license
# registry (Layer-B sshd enforcement). Sourced by BOTH:
#
#   * /usr/sbin/hugmesh-authorized-keys-lookup   (the AuthorizedKeysCommand)
#   * /usr/sbin/hugmesh-device-registry-sync     (the fetch/cache agent)
#
# so a divergence in canonicalisation can NEVER cause an accept/deny split between
# the two consumers. Every function here is FAIL-CLOSED: any malformed input,
# missing tool, or verify failure returns non-zero (caller denies / keeps cache).
#
# It implements the consumer half of THE EXPORT CONTRACT
# (hugmesh-admin-bff-api PR #28):
#
#   canonical bytes = line-oriented UTF-8:
#       v1\n
#       mesh=<meshId>\n
#       generation=<long>\n
#     then ONE sorted TAB-separated line per authorized operator:
#       op=<operator>\tfp=<machineKeyFp>\thost=<hostname>\tvia=<via>\tkeys=<csv>\n
#
#   detached Ed25519 signature over EXACTLY those bytes; verified against the
#   BAKED key-USB public half (NOT the envelope's advertised publicKey field);
#   strict-monotonic generation rollback guard (gen MUST be > last-good).
#
# The reconstruction below MUST match DeviceRegistryExportService.canonicalBytes
# BYTE FOR BYTE (verified against the merged Java on main):
#   - "v1\n", "mesh=<id>\n", "generation=<long>\n" header lines;
#   - operators are ALREADY sorted server-side (op, fp, via) and emitted in array
#     order — we DO NOT re-sort (re-sorting could diverge from the JVM collator);
#   - per operator: op=, \t, fp=, \t, host=<hostname> (the ACTUAL hostname via
#     nz(op.hostname()) — NOT empty; the prompt's "host=\t" shorthand is wrong,
#     the Java emits host=<value>), \t, via=, \t, keys=<comma-joined>, \n;
#   - nz(): a null field becomes the empty string (jq's // "" mirrors this).
#
# NOTE on validation status: the canonical reconstruction + the openssl Ed25519
# verify path are SYNTACTICALLY validated here and round-trip-tested off-node, but
# end-to-end equality with a LIVE BFF /export payload can only be confirmed on a
# booted node against a running admin-bff-api (see the PR body VERIFIED-vs-NEEDS-
# NODE matrix). If the JVM ever emits a field this reconstruction does not mirror,
# verify FAILS CLOSED (deny / keep cache) — never fails open.

# Tools we rely on (all present in the OpenRC node image: jq + openssl 3 are used
# throughout provision.sh / gen-cluster-secrets.sh). Any missing tool => fail-closed.
_rv_have() { command -v "$1" >/dev/null 2>&1; }

# ── canonical_bytes <export.json> -> stdout ────────────────────────────────────
# Reconstruct DeviceRegistryExportService.canonicalBytes from the signed envelope
# JSON. Emits the EXACT bytes the detached signature covers. Returns non-zero (and
# prints nothing) on any parse error => caller fail-closes.
#
# We use jq -j (raw, no trailing newline) + explicit "\n"/"\t" so byte output is
# deterministic and not subject to locale or printf quirks. The body lives under
# .body (SignedExport.body == ExportBody{meshId, generation, operators[]}).
canonical_bytes() {
    local export_json="$1"
    [ -n "${export_json}" ] && [ -r "${export_json}" ] || return 1
    _rv_have jq || return 1

    # jq program: emit the header, then one line per operator in ARRAY ORDER
    # (the server already sorted them; we must NOT re-sort). `// ""` mirrors the
    # Java nz() null->"" coercion. keyFingerprints joined by "," with no spaces.
    # We assert the body shape is present; a missing .body/.body.operators makes
    # the program error (set -e style via `// empty` guards) => non-zero exit.
    jq -j -e '
        (.body // error("no body")) as $b
        | "v1\n"
        + "mesh=" + (($b.meshId // "")|tostring) + "\n"
        + "generation=" + (($b.generation // 0)|tostring) + "\n"
        + ( ([$b.operators[]?
              | "op=" + (.operator // "")
              + "\tfp=" + (.machineKeyFp // "")
              + "\thost=" + (.hostname // "")
              + "\tvia=" + (.via // "")
              + "\tkeys=" + ((.keyFingerprints // []) | join(","))
              + "\n"
            ]) | add // "" )
    ' "${export_json}" 2>/dev/null
}

# ── verify_sig <canonical-file> <sig-b64> <pubkey-spki-der-b64-file> -> rc ──────
# Verify a detached Ed25519 signature (base64) over the canonical bytes file using
# the BAKED public verifying half. The pubkey file holds base64 of the X.509
# SubjectPublicKeyInfo DER (exactly RegistrySigner.publicKeyBase64() ==
# Base64(publicKey.getEncoded())). Returns 0 iff the signature verifies; non-zero
# (fail-closed) on ANY error: missing tool, empty sig, malformed key, bad sig.
#
# openssl 3 path (validated off-node): reconstruct the pubkey PEM from the base64
# SPKI DER, then `openssl pkeyutl -verify -pubin -rawin` over the raw canonical
# bytes (Ed25519 is a one-shot raw-input scheme — NO pre-hash, matching the JVM
# Signature("Ed25519").update(body)/verify(sig)).
verify_sig() {
    local canonical="$1" sig_b64="$2" pub_b64_file="$3"
    [ -n "${canonical}" ] && [ -r "${canonical}" ] || return 1
    [ -n "${sig_b64}" ] || return 1
    [ -n "${pub_b64_file}" ] && [ -r "${pub_b64_file}" ] || return 1
    _rv_have openssl || return 1
    _rv_have base64 || return 1

    local tmp pub_pem sig_bin rc=1
    tmp="$(mktemp -d 2>/dev/null)" || return 1
    pub_pem="${tmp}/pub.pem"
    sig_bin="${tmp}/sig.bin"

    # Reconstruct the public key: base64 SPKI DER -> PEM. A malformed/foreign key
    # (e.g. a rotated signing key whose public half was NOT re-baked here) fails
    # here OR at verify => fail-closed (fleet lockout to break-glass by design;
    # see the signing-key-rotation runbook dependency in the PR body).
    if ! base64 -d "${pub_b64_file}" 2>/dev/null \
            | openssl pkey -pubin -inform DER -out "${pub_pem}" 2>/dev/null; then
        rm -rf "${tmp}"; return 1
    fi
    # Decode the detached signature.
    if ! printf '%s' "${sig_b64}" | base64 -d > "${sig_bin}" 2>/dev/null; then
        rm -rf "${tmp}"; return 1
    fi
    # Detached Ed25519 verify over the RAW canonical bytes.
    if openssl pkeyutl -verify -pubin -inkey "${pub_pem}" \
            -rawin -in "${canonical}" -sigfile "${sig_bin}" >/dev/null 2>&1; then
        rc=0
    fi
    rm -rf "${tmp}"
    return "${rc}"
}

# ── check_monotonic <candidate-gen> <last-good-file> -> rc ─────────────────────
# STRICT-monotonic rollback guard. Returns 0 iff the candidate generation is a
# valid forward step:
#   * accept iff candidate > last-good (strictly greater);
#   * an absent/empty/non-numeric last-good file is treated as -1 (so the FIRST
#     ever sync with gen>=0 is accepted);
#   * a non-numeric candidate is REJECTED (fail-closed).
# Note the asymmetry vs the LOOKUP: the SYNC agent uses this strict ">" guard to
# decide whether to ACCEPT a freshly-fetched export (reject gen <= last-good). The
# LOOKUP separately rejects a CACHED export whose gen is < its recorded last-good
# (tamper/rollback of the on-disk cache) — see the lookup for that check.
check_monotonic() {
    local cand="$1" last_good_file="$2" last="-1"
    case "${cand}" in
        ''|*[!0-9]*) return 1 ;;   # non-numeric / empty candidate => reject
    esac
    if [ -n "${last_good_file}" ] && [ -r "${last_good_file}" ]; then
        last="$(tr -dc '0-9' < "${last_good_file}" 2>/dev/null)"
        [ -n "${last}" ] || last="-1"
    fi
    # strict greater-than (integer compare)
    [ "${cand}" -gt "${last}" ] 2>/dev/null
}

# ── rv_gen <export.json> -> stdout (generation) ────────────────────────────────
# Convenience: extract the body generation as a bare integer (or empty on error).
rv_gen() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _rv_have jq || return 1
    jq -r -e '.body.generation // empty' "${export_json}" 2>/dev/null
}

# ── rv_mesh <export.json> -> stdout (meshId) ───────────────────────────────────
rv_mesh() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _rv_have jq || return 1
    jq -r -e '.body.meshId // empty' "${export_json}" 2>/dev/null
}

# ── rv_signed <export.json> -> rc ──────────────────────────────────────────────
# 0 iff the envelope claims to be signed AND carries a non-null signature. An
# unsigned (signed=false / signature=null) export is REJECTED upstream
# (fail-closed): the BFF serves unsigned only when it has no signing key.
rv_signed() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _rv_have jq || return 1
    [ "$(jq -r '.signed // false' "${export_json}" 2>/dev/null)" = "true" ] || return 1
    [ "$(jq -r 'if .signature == null then "null" else "ok" end' "${export_json}" 2>/dev/null)" = "ok" ]
}

# ── rv_signature <export.json> -> stdout (base64 sig) ──────────────────────────
rv_signature() {
    local export_json="$1"
    [ -r "${export_json}" ] || return 1
    _rv_have jq || return 1
    jq -r -e '.signature // empty' "${export_json}" 2>/dev/null
}

# ── verify_export <export.json> <pubkey-b64-file> [strict-gen-file] -> rc ───────
# The FULL fail-closed acceptance gate shared by the lookup and the sync agent:
#   (1) envelope must be signed (signed==true && signature!=null);
#   (2) reconstruct canonical bytes and verify the detached Ed25519 signature
#       against the BAKED public key;
#   (3) [optional] if strict-gen-file is given, enforce STRICT monotonicity
#       (candidate gen > last-good) — the SYNC agent passes it; the LOOKUP omits
#       it (the lookup does its own gen >= last-good cache-rollback check, since a
#       cache that merely EQUALS last-good is the steady state and must be usable).
# Prints NOTHING; returns 0 only on full acceptance.
verify_export() {
    local export_json="$1" pub_b64_file="$2" strict_gen_file="${3:-}"
    rv_signed "${export_json}" || return 1

    local sig canon_tmp gen rc=1
    sig="$(rv_signature "${export_json}")" || return 1
    [ -n "${sig}" ] || return 1

    canon_tmp="$(mktemp 2>/dev/null)" || return 1
    if ! canonical_bytes "${export_json}" > "${canon_tmp}" 2>/dev/null; then
        rm -f "${canon_tmp}"; return 1
    fi
    # A zero-length canonical reconstruction is a parse failure => fail-closed.
    [ -s "${canon_tmp}" ] || { rm -f "${canon_tmp}"; return 1; }

    if verify_sig "${canon_tmp}" "${sig}" "${pub_b64_file}"; then
        rc=0
    fi
    rm -f "${canon_tmp}"
    [ "${rc}" -eq 0 ] || return 1

    if [ -n "${strict_gen_file}" ]; then
        gen="$(rv_gen "${export_json}")" || return 1
        check_monotonic "${gen}" "${strict_gen_file}" || return 1
    fi
    return 0
}
