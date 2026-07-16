#!/usr/bin/env bash
# _download-lib.sh — SOURCED helper library for VERIFIED remote downloads.
#
# OWASP supply-chain hardening: the image builders fetch a Gentoo stage3 seed
# tarball, the headscale control-plane binary, and the tailscale client tarball
# from the public internet. Before this library, those artifacts were curl'd and
# installed WITHOUT cryptographic verification — a MITM or a compromised mirror
# could silently inject a backdoored binary into every shipped image.
#
# This file factors the verification into ONE audited implementation so each
# builder (build-rpi5-stage4.sh, build-frite-stage4.sh, …) calls the SAME code
# instead of each re-implementing (or forgetting) the checks.
#
# It is meant to be SOURCED, never executed:
#     source "$(dirname "${BASH_SOURCE[0]}")/_download-lib.sh"
#
# It does NOT call `set -euo pipefail` itself — the sourcing script owns the
# shell options. It defines functions only (no top-level side effects beyond
# the double-source guard below), so sourcing it is safe and idempotent.
#
# Public API:
#   dlv_require_tools <tool>...
#       — die unless every named tool is on PATH (curl, gpg, sha256sum, …).
#
#   dlv_fetch <url> <dest>
#       — curl -fL the URL to <dest>; die on any HTTP/transport error. Removes a
#         truncated partial file on failure so a retry/cache check is clean.
#
#   dlv_verify_sha256 <file> <expected_hex>
#       — recompute sha256 of <file>; die (non-zero) on mismatch, log OK on match.
#
#   dlv_verify_sha512 <file> <expected_hex>
#       — recompute sha512 of <file>; die on mismatch.
#
#   dlv_verify_from_sumsfile <file> <basename> <sumsfile> [algo]
#       — look <basename> up in a publisher checksum manifest (tailscale
#         SHA256SUMS / headscale checksums.txt: "<hex>  <name>" lines), then
#         verify <file> against that hash. algo defaults to sha256. Dies if the
#         basename is absent from the manifest (fail-closed) or the hash differs.
#
#   dlv_import_key <keyfile|fingerprint> [keyserver]
#       — import a GPG public key into an EPHEMERAL keyring exported as
#         DLV_GNUPGHOME. Accepts a local ASCII-armored keyfile OR a fingerprint
#         to pull from a keyserver. Call dlv_gpg_cleanup when done.
#
#   dlv_gpg_verify <signature_file> <signed_file>
#       — gpg --verify in the ephemeral keyring; die on a bad/absent signature.
#
#   dlv_verify_stage3 <tarball> <digests_url> [signing_key] [keyserver]
#       — the Gentoo stage3 flow: fetch <tarball>.DIGESTS (+ .DIGESTS.asc when
#         present), GPG-verify the DIGESTS against the Gentoo release-engineering
#         key, then verify the tarball's SHA512 (preferred) or SHA256 against the
#         DIGESTS. Dies on signature OR checksum mismatch. The expected key
#         fingerprint defaults to the Gentoo autobuild signing key and can be
#         overridden via the signing_key arg or DLV_GENTOO_KEY env.
#
#   dlv_gpg_cleanup
#       — remove the ephemeral GNUPGHOME created by dlv_import_key.
#
#   dlv_verify_sshsig <file> <sig> <allowed_signers> <identity> <namespace> [expected_key_fp]
#       — verify an OpenSSH sshsig signature (`ssh-keygen -Y verify`) against a
#         pinned allowed_signers file (GrapheneOS factory images use this). When
#         <expected_key_fp> is non-empty, first assert every key in the
#         allowed_signers file carries that SHA256 fingerprint (fail-closed
#         tamper check — catches a replaced AND an appended key). Dies on any
#         failure, logs OK on success.
#
# Tunables (env, set by the caller before sourcing or before a call):
#   DLV_QUIET=1                 suppress dlv_info chatter (errors still show)
#   DLV_GENTOO_KEY=<fpr>        override the Gentoo release-eng key fingerprint
#   DLV_KEYSERVER=<url>         override the keyserver used for fingerprint pulls
#   DLV_OFFLINE_KEYRING=<file>  ASCII-armored key bundle to import instead of a
#                               keyserver pull (air-gapped builds)
#   DLV_LOCAL_KEYRING=<file>    extra local keyring to try (after the host-vendored
#                               /usr/share/openpgp-keys/gentoo-release.*) before any
#                               network keyserver

# Guard against double-sourcing. `return` only works when sourced; fall back to
# `exit` if someone runs the file directly.
# shellcheck disable=SC2317
if [ -n "${_DOWNLOAD_LIB_SOURCED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_DOWNLOAD_LIB_SOURCED=1

# ── Logging ────────────────────────────────────────────────────────
# Colour only when stderr is a TTY, so logs/pipes stay clean.
if [ -t 2 ]; then
    _DLV_RED=$'\033[31m'; _DLV_GRN=$'\033[32m'; _DLV_YEL=$'\033[33m'; _DLV_RST=$'\033[0m'
else
    _DLV_RED=''; _DLV_GRN=''; _DLV_YEL=''; _DLV_RST=''
fi
dlv_die()  { printf '%s[verify-download] ERROR:%s %s\n' "${_DLV_RED}" "${_DLV_RST}" "$*" >&2; return 1; }
dlv_warn() { printf '%s[verify-download] WARN:%s %s\n'  "${_DLV_YEL}" "${_DLV_RST}" "$*" >&2; }
dlv_info() { [ -n "${DLV_QUIET:-}" ] || printf '%s[verify-download]%s %s\n' "${_DLV_GRN}" "${_DLV_RST}" "$*" >&2; }

# The Gentoo "Automated Weekly Release Key" used to sign the autobuild
# stage3/index artifacts on distfiles.gentoo.org. Pinned here as the trust
# anchor; override with DLV_GENTOO_KEY (or pass arg 3 to dlv_verify_stage3) only
# if Gentoo rotates it. Full fingerprint, not a short key id (short ids collide).
DLV_GENTOO_KEY="${DLV_GENTOO_KEY:-13EBBDBEDE7A12775DFDB1BABB572E0E2D182910}"
DLV_KEYSERVER="${DLV_KEYSERVER:-hkps://keys.openpgp.org}"

# ── Tooling ────────────────────────────────────────────────────────
dlv_require_tools() {
    local missing=() t
    for t in "$@"; do
        command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        dlv_die "missing required tool(s): ${missing[*]}"
        return 1
    fi
    return 0
}

# ── Fetch ──────────────────────────────────────────────────────────
# curl -fL <url> -o <dest>; -f makes a 4xx/5xx a non-zero exit, -L follows
# redirects. On failure remove the (possibly truncated) <dest> so a later
# `[ -f dest ]` cache check does not treat garbage as a good cached file.
dlv_fetch() {
    local url="$1" dest="$2"
    dlv_require_tools curl || return 1
    dlv_info "fetching ${url}"
    # --retry hardens against the transient-blip class: a single hiccup fetching a
    # small checksum/DIGESTS/sidecar (Phase 2.5 / stage3 verify) otherwise aborts a
    # whole role build that had already passed @system + payload. Mirrors the
    # retry flags the binary (headscale/tailscale) downloads already use.
    if ! curl -fL --proto '=https' --tlsv1.2 \
              --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors \
              -o "${dest}" "${url}"; then
        rm -f "${dest}"
        dlv_die "download failed: ${url}"
        return 1
    fi
    return 0
}

# ── Checksums ──────────────────────────────────────────────────────
# Pick the right *sum tool; tolerate the macOS `shasum -a N` form too.
_dlv_sha() {
    local algo="$1" file="$2"
    case "${algo}" in
        sha256)
            if command -v sha256sum >/dev/null 2>&1; then sha256sum "${file}" | awk '{print $1}';
            elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "${file}" | awk '{print $1}';
            else dlv_die "no sha256 tool (sha256sum/shasum)"; return 1; fi ;;
        sha512)
            if command -v sha512sum >/dev/null 2>&1; then sha512sum "${file}" | awk '{print $1}';
            elif command -v shasum >/dev/null 2>&1; then shasum -a 512 "${file}" | awk '{print $1}';
            else dlv_die "no sha512 tool (sha512sum/shasum)"; return 1; fi ;;
        *) dlv_die "unsupported algo: ${algo}"; return 1 ;;
    esac
}

# Lowercase + strip whitespace so a hex compare is case/space insensitive.
_dlv_norm_hex() { printf '%s' "$1" | tr 'A-F' 'a-f' | tr -cd '0-9a-f'; }

_dlv_verify_hash() {
    local algo="$1" file="$2" expected="$3" actual
    [ -f "${file}" ] || { dlv_die "file to verify does not exist: ${file}"; return 1; }
    expected="$(_dlv_norm_hex "${expected}")"
    [ -n "${expected}" ] || { dlv_die "empty expected ${algo} for ${file} (fail-closed)"; return 1; }
    actual="$(_dlv_sha "${algo}" "${file}")" || return 1
    actual="$(_dlv_norm_hex "${actual}")"
    if [ "${actual}" != "${expected}" ]; then
        dlv_die "${algo} MISMATCH for ${file}
          expected: ${expected}
          actual:   ${actual}
        refusing to use a tampered/corrupt artifact."
        return 1
    fi
    dlv_info "${algo} OK: $(basename "${file}")"
    return 0
}

dlv_verify_sha256() { _dlv_verify_hash sha256 "$1" "$2"; }
dlv_verify_sha512() { _dlv_verify_hash sha512 "$1" "$2"; }

# Verify <file> against a single-hash sidecar file (the tailscale convention:
# fetch "<artifact-url>.sha256", which is one line that is either just the hex,
# or the usual "<hex>  <name>" pair). We take the first whitespace-delimited
# token as the hash. <hashfile> must exist (caller fetches it). algo=sha256.
dlv_verify_sha256_sidecar() {
    local file="$1" hashfile="$2" expected
    [ -f "${hashfile}" ] || { dlv_die "sha256 sidecar missing: ${hashfile}"; return 1; }
    expected="$(awk 'NF{print $1; exit}' "${hashfile}")"
    _dlv_verify_hash sha256 "${file}" "${expected}"
}

# Verify <file> against a publisher checksum manifest that lists one
# "<hex>  <name>" (or "<hex> *<name>") line per artifact — the format emitted by
# `sha256sum`, tailscale's SHA256SUMS, and headscale's checksums.txt. We match on
# <basename> and FAIL CLOSED if it is absent (an attacker who strips our line
# must not be able to skip the check).
dlv_verify_from_sumsfile() {
    local file="$1" name="$2" sumsfile="$3" algo="${4:-sha256}" line expected
    [ -f "${sumsfile}" ] || { dlv_die "checksum manifest missing: ${sumsfile}"; return 1; }
    # Match the exact basename at end-of-line, tolerating the binary-mode '*'.
    line="$(grep -E "[[:space:]][*]?${name//./\\.}\$" "${sumsfile}" | head -n1)"
    [ -n "${line}" ] || { dlv_die "no ${algo} entry for '${name}' in ${sumsfile} (fail-closed)"; return 1; }
    expected="$(printf '%s' "${line}" | awk '{print $1}')"
    _dlv_verify_hash "${algo}" "${file}" "${expected}"
}

# ── GPG ────────────────────────────────────────────────────────────
# Build an ephemeral keyring so we never touch the caller's ~/.gnupg, and so the
# trust set is EXACTLY the key(s) we import (nothing the host happens to trust).
DLV_GNUPGHOME=""
# Acquire the signing key into the ephemeral keyring, RESILIENTLY. Order of trust:
#   1. an explicit DLV_OFFLINE_KEYRING bundle (air-gapped builds);
#   2. a local keyfile passed as the key arg;
#   3. for a fingerprint: the HOST-VENDORED Gentoo release keyring
#      (/usr/share/openpgp-keys/gentoo-release.{asc,gpg}, or DLV_LOCAL_KEYRING) —
#      tried BEFORE any network so a flaky keyserver cannot stall the build;
#   4. the requested keyserver, then resilient fallbacks.
# Every path is VERIFIED with `gpg --list-keys "${key}"` after import: keys.openpgp.org
# serves keys with unverified UIDs STRIPPED and returns nonzero, which used to make
# `--recv-keys` "fail" and abort the whole stage3 seed verification (every arm64 Pi +
# Frite role). The post-import check makes "imported but unusable" fail-closed and lets
# us fall through to the next source instead of dying.
dlv_import_key() {
    local key="$1" keyserver="${2:-${DLV_KEYSERVER}}"
    dlv_require_tools gpg || return 1
    DLV_GNUPGHOME="$(mktemp -d)" || { dlv_die "mktemp -d failed"; return 1; }
    chmod 700 "${DLV_GNUPGHOME}"
    export GNUPGHOME="${DLV_GNUPGHOME}"

    # 1) Explicit offline keyring bundle.
    if [ -n "${DLV_OFFLINE_KEYRING:-}" ] && [ -f "${DLV_OFFLINE_KEYRING}" ]; then
        dlv_info "importing signing key from offline bundle ${DLV_OFFLINE_KEYRING}"
        gpg --batch --import "${DLV_OFFLINE_KEYRING}" >/dev/null 2>&1 && return 0
        dlv_die "failed to import offline key bundle"; return 1
    fi
    # 2) A local keyfile passed as the key arg.
    if [ -f "${key}" ]; then
        dlv_info "importing signing key from ${key}"
        gpg --batch --import "${key}" >/dev/null 2>&1 && return 0
        dlv_die "failed to import key file ${key}"; return 1
    fi
    # 3) Fingerprint: prefer a host-vendored keyring (offline, UID-complete).
    local f
    for f in /usr/share/openpgp-keys/gentoo-release.asc \
             /usr/share/openpgp-keys/gentoo-release.gpg \
             "${DLV_LOCAL_KEYRING:-}"; do
        [ -n "${f}" ] && [ -f "${f}" ] || continue
        if gpg --batch --import "${f}" >/dev/null 2>&1 \
           && gpg --batch --list-keys "${key}" >/dev/null 2>&1; then
            dlv_info "imported signing key ${key} from local keyring ${f}"
            return 0
        fi
    done
    # 4) Keyserver(s): the requested one, then resilient fallbacks. VERIFY presence
    #    after each (a UID-stripped keys.openpgp.org reply must NOT count as success).
    local ks
    for ks in "${keyserver}" hkps://keyserver.ubuntu.com hkps://pgp.mit.edu; do
        [ -n "${ks}" ] || continue
        dlv_info "fetching signing key ${key} from ${ks}"
        if gpg --batch --keyserver "${ks}" --recv-keys "${key}" >/dev/null 2>&1 \
           && gpg --batch --list-keys "${key}" >/dev/null 2>&1; then
            return 0
        fi
        dlv_warn "keyserver ${ks} did not yield a usable ${key}; trying next"
    done
    dlv_die "could not obtain signing key ${key} (offline keyring + keyservers all failed)"
    return 1
}

dlv_gpg_cleanup() {
    if [ -n "${DLV_GNUPGHOME:-}" ] && [ -d "${DLV_GNUPGHOME}" ]; then
        rm -rf "${DLV_GNUPGHOME}"
    fi
    DLV_GNUPGHOME=""
    unset GNUPGHOME
}

dlv_gpg_verify() {
    local sig="$1" signed="$2"
    dlv_require_tools gpg || return 1
    [ -f "${sig}" ]    || { dlv_die "signature file missing: ${sig}"; return 1; }
    [ -f "${signed}" ] || { dlv_die "signed file missing: ${signed}"; return 1; }
    if ! gpg --batch --verify "${sig}" "${signed}" >/dev/null 2>&1; then
        dlv_die "GPG signature verification FAILED for ${signed} (sig ${sig})"
        return 1
    fi
    dlv_info "GPG signature OK: $(basename "${signed}")"
    return 0
}

# ── Gentoo stage3 ──────────────────────────────────────────────────
# <tarball>      already-downloaded stage3 .tar.xz
# <digests_url>  URL of the matching .DIGESTS (we also try .DIGESTS.asc)
# [signing_key]  fingerprint or keyfile (defaults to DLV_GENTOO_KEY)
# [keyserver]    override keyserver
#
# Flow: fetch DIGESTS(.asc); if a detached/clearsigned .asc is available,
# GPG-verify it against the pinned Gentoo key; then extract the SHA512 (or
# SHA256) line for the tarball's basename from the DIGESTS and verify the file.
# Dies on ANY failure (missing key, bad signature, absent/mismatched checksum).
dlv_verify_stage3() {
    local tarball="$1" digests_url="$2" key="${3:-${DLV_GENTOO_KEY}}" keyserver="${4:-${DLV_KEYSERVER}}"
    local base tmpd digests asc
    dlv_require_tools curl gpg awk grep || return 1
    [ -f "${tarball}" ] || { dlv_die "stage3 tarball missing: ${tarball}"; return 1; }
    base="$(basename "${tarball}")"
    tmpd="$(mktemp -d)" || { dlv_die "mktemp -d failed"; return 1; }
    digests="${tmpd}/$(basename "${digests_url}")"
    asc="${digests}.asc"

    dlv_fetch "${digests_url}" "${digests}" || { rm -rf "${tmpd}"; return 1; }

    # 1) Authenticity: GPG-verify the DIGESTS. The .asc may be detached (signs
    #    the .DIGESTS) — fetch it best-effort; its ABSENCE is fatal because an
    #    unsigned DIGESTS gives an attacker free rein to rewrite the checksums.
    dlv_import_key "${key}" "${keyserver}" || { rm -rf "${tmpd}"; return 1; }
    if dlv_fetch "${digests_url}.asc" "${asc}" 2>/dev/null && [ -s "${asc}" ]; then
        if ! dlv_gpg_verify "${asc}" "${digests}"; then
            dlv_gpg_cleanup; rm -rf "${tmpd}"
            dlv_die "stage3 DIGESTS signature did not verify — aborting build."
            return 1
        fi
    elif gpg --batch --verify "${digests}" >/dev/null 2>&1; then
        # Some mirrors ship a CLEARSIGNED .DIGESTS (signature inline).
        dlv_info "GPG signature OK (clearsigned DIGESTS)"
    else
        dlv_gpg_cleanup; rm -rf "${tmpd}"
        dlv_die "no verifiable signature for ${base}.DIGESTS (.asc absent and DIGESTS not clearsigned) — refusing unverified stage3."
        return 1
    fi
    dlv_gpg_cleanup

    # 2) Integrity: pull the SHA512 (preferred) or SHA256 for our basename from
    #    the DIGESTS. Gentoo DIGESTS group lines as:
    #        # SHA512 HASH
    #        <hex>  <filename>
    #    so we find the hash line whose filename == our basename, looking back at
    #    the preceding "# <ALGO>" marker to know which algorithm it is.
    local want_algo="" want_hash=""
    # Prefer SHA512 if present for this basename; else fall back to SHA256.
    want_hash="$(awk -v f="${base}" '
        /^#[[:space:]]*SHA512/ { algo="sha512"; next }
        /^#[[:space:]]*SHA256/ { algo="sha256"; next }
        /^#/ { algo=""; next }
        { for (i=1;i<=NF;i++) if ($i==f && algo=="sha512") { print $1; exit } }
    ' "${digests}")"
    if [ -n "${want_hash}" ]; then
        want_algo="sha512"
    else
        want_hash="$(awk -v f="${base}" '
            /^#[[:space:]]*SHA512/ { algo="sha512"; next }
            /^#[[:space:]]*SHA256/ { algo="sha256"; next }
            /^#/ { algo=""; next }
            { for (i=1;i<=NF;i++) if ($i==f && algo=="sha256") { print $1; exit } }
        ' "${digests}")"
        [ -n "${want_hash}" ] && want_algo="sha256"
    fi
    if [ -z "${want_hash}" ]; then
        rm -rf "${tmpd}"
        dlv_die "no SHA512/SHA256 entry for '${base}' in DIGESTS (fail-closed)."
        return 1
    fi

    if ! _dlv_verify_hash "${want_algo}" "${tarball}" "${want_hash}"; then
        rm -rf "${tmpd}"
        dlv_die "stage3 tarball checksum did not match the signed DIGESTS — aborting build."
        return 1
    fi
    rm -rf "${tmpd}"
    dlv_info "stage3 verified (signed DIGESTS + ${want_algo}): ${base}"
    return 0
}

# ── OpenSSH signatures (sshsig) ────────────────────────────────────
# <file>             the artifact the signature covers (read via stdin redirect)
# <sig>              the detached .sig produced by `ssh-keygen -Y sign`
# <allowed_signers>  pinned "principal keytype base64" file ('#' comments OK)
# <identity>         the principal to verify as (e.g. contact@grapheneos.org)
# <namespace>        the sshsig namespace (e.g. "factory images")
# [expected_key_fp]  optional SHA256:… fingerprint double-pin
#
# The fingerprint pre-check runs against EVERY key line in the allowed_signers
# file: `-Y verify` accepts ANY listed key for the principal, so an attacker who
# can append a line (not just replace one) would otherwise get a valid verify
# with their own key. Fail-closed: unparseable/missing keys die too.
dlv_verify_sshsig() {
    local file="$1" sig="$2" signers="$3" identity="$4" namespace="$5" expected_fp="${6:-}"
    dlv_require_tools ssh-keygen || return 1
    [ -f "${file}" ]    || { dlv_die "file to verify does not exist: ${file}"; return 1; }
    [ -f "${sig}" ]     || { dlv_die "sshsig signature missing: ${sig}"; return 1; }
    [ -f "${signers}" ] || { dlv_die "allowed_signers file missing: ${signers}"; return 1; }

    if [ -n "${expected_fp}" ]; then
        # ssh-keygen -lf prints "bits SHA256:… principal (TYPE)" per key line and
        # skips '#' comments (verified against OpenSSH 10.3).
        local fps fp
        fps="$(ssh-keygen -lf "${signers}" 2>/dev/null | awk '{print $2}')"
        if [ -z "${fps}" ]; then
            dlv_die "could not fingerprint any key in ${signers} (fail-closed)"
            return 1
        fi
        for fp in ${fps}; do
            if [ "${fp}" != "${expected_fp}" ]; then
                dlv_die "allowed_signers key fingerprint MISMATCH for ${signers}
          expected: ${expected_fp}
          found:    ${fp}
        the pinned signer file may have been TAMPERED with — refusing to verify."
                return 1
            fi
        done
    fi

    if ! ssh-keygen -Y verify -f "${signers}" -I "${identity}" -n "${namespace}" \
            -s "${sig}" < "${file}" >/dev/null 2>&1; then
        dlv_die "sshsig verification FAILED for ${file}
          sig:       ${sig}
          identity:  ${identity}
          namespace: ${namespace}
        refusing to use an artifact that does not verify."
        return 1
    fi
    dlv_info "sshsig OK: $(basename "${file}") (identity=${identity}, namespace='${namespace}')"
    return 0
}
