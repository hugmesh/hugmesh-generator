#!/usr/bin/env bash
# _kernel-cache-lib.sh — SOURCED helper: the signed-kernel ARTIFACT CACHE (G4).
#
# WHY THIS EXISTS
# ---------------
# #439 (binpkg pools) and the shared-asset root (G1/G2/G3, scripts/_shared-assets-lib.sh)
# stopped the fleet re-downloading seeds and re-compiling PACKAGES. The kernel was still
# rebuilt — and re-signed — from scratch for EVERY image, even when nothing that decides
# the kernel had changed. The operator's framing: "binaries will all be signed by the
# same keys across devices for the kernel", i.e. a kernel built for a board under a given
# config and a given signing identity is the SAME artifact for every image of that board.
#
# THE CACHE KEY — and why the signing key is IN it
# ------------------------------------------------
# kc_cache_key() is the ONE key-derivation function (kept alone and tested so no caller
# can invent a second, weaker spelling). It hashes FOUR components, all required:
#
#   1. board          the board key (rpi5 / rpi4 / x86 / jetson …) — different -mcpu,
#                     different defconfig, different DTBs. Never the build subdir.
#   2. kver           the kernel VERSION token (source tree, e.g. linux-6.18.9-gentoo).
#   3. config-digest  a content hash of the kernel .config seed AND every fragment
#                     appended to it, in the order they are appended.
#   4. signing-key-fp a fingerprint of the SIGNING IDENTITY in effect.
#
# Component 4 is the one that is easy to leave out and expensive to get wrong. The whole
# premise of reuse here is "the same keys sign every device". The corollary is that when
# the fleet is RE-KEYED, every cached artifact was signed by a RETIRED key — and a cache
# keyed only on board+version+config would hand those back forever, silently. Re-keying
# is exactly the moment you most need the cache to miss. So the key identity is part of
# the cache key, and a build whose signing identity cannot be established does not get a
# degraded key: it gets a MISS.
#
# FAIL-CLOSED, NEVER A PARTIAL KEY
# --------------------------------
# kc_cache_key returns non-zero (printing nothing) unless ALL FOUR components are present
# and well-formed. Callers treat "no key" as MISS, so an unavailable component can only
# ever cost a rebuild — it can never widen what a cache entry is allowed to match.
#
# KEY MATERIAL NEVER TOUCHES THE CACHE
# ------------------------------------
#   * kc_key_fingerprint reads a signing input and emits ONLY a SHA-256 over its PUBLIC
#     half — the DER of an X.509 certificate, or the DER SubjectPublicKeyInfo derived
#     from a key. The private half is never printed, never copied, never stored.
#   * The manifest records that fingerprint and nothing else about the key: no path, no
#     subject, no serial, no key file.
#   * kc_store REFUSES to admit any payload file containing a PEM private-key header, so
#     a builder that mistakenly points the cache at a key directory fails loudly instead
#     of publishing key material into a shared, fleet-visible directory.
#
# A CACHE IS NOT A GATE BYPASS
# ----------------------------
# Restoring a kernel replaces the COMPILE, never a CHECK. The artifact-integrity gates
# (the x86 disk-initramfs/seal gates, the cross builders' requested-atom payload gate)
# sit OUTSIDE the cache branch in every builder and run identically on a hit and on a
# miss. tests/scripts/test-kernel-artifact-cache.sh asserts that by MUTATION: it deletes
# the gate from the hit path and requires the bad sysroot to then sail through.
#
# CACHE ENTRIES ARE VALIDATED, NEVER TRUSTED
# ------------------------------------------
# Same posture as the seed cache next door: kc_lookup re-checks the manifest's four
# components against what THIS build derived, and re-hashes every payload file, on every
# hit. A truncated, hand-edited, half-written or foreign entry is pruned and reported as
# a MISS — it can never be restored into a sysroot.
#
# It is meant to be SOURCED, never executed. Requires scripts/_shared-assets-lib.sh
# (sa_component_ok / sa_lock_run) — the path-safety and flock discipline are reused, not
# re-implemented.

# shellcheck disable=SC2317
if [ -n "${_KERNEL_CACHE_LIB_SOURCED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_KERNEL_CACHE_LIB_SOURCED=1

# On-disk entry format. Bump when the manifest or payload layout changes: a mismatched
# format is a MISS + prune, so old entries retire themselves instead of being mis-read.
KC_FORMAT="${KC_FORMAT:-1}"

# ── logging (own prefix, mirrors the shared-assets lib) ───────────────────────
if [ -t 2 ]; then
    _KC_RED=$'\033[31m'; _KC_GRN=$'\033[32m'; _KC_YEL=$'\033[33m'; _KC_RST=$'\033[0m'
else
    _KC_RED=''; _KC_GRN=''; _KC_YEL=''; _KC_RST=''
fi
kc_err()  { printf '%s[kernel-cache] ERROR:%s %s\n' "${_KC_RED}" "${_KC_RST}" "$*" >&2; }
kc_warn() { printf '%s[kernel-cache] WARN:%s %s\n'  "${_KC_YEL}" "${_KC_RST}" "$*" >&2; }
kc_info() { [ -n "${KC_QUIET:-}" ] || printf '%s[kernel-cache]%s %s\n' "${_KC_GRN}" "${_KC_RST}" "$*" >&2; }

# ── prerequisites ─────────────────────────────────────────────────────────────
# The shared-assets lib owns path-component safety and the flock discipline. Reuse it;
# a second copy of either would be a second thing to get wrong.
kc_require_sa() {
    command -v sa_component_ok >/dev/null 2>&1 && command -v sa_lock_run >/dev/null 2>&1 && return 0
    kc_err "_shared-assets-lib.sh is not sourced — refusing to touch the kernel cache"
    kc_err "(path-component safety and the flock discipline live there and are not duplicated here)."
    return 1
}

# ── digests ───────────────────────────────────────────────────────────────────
kc_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}'
    else return 1
    fi
}
kc_sha256_file() {
    [ -f "${1:-}" ] && [ -r "$1" ] || return 1
    kc_sha256_stdin < "$1"
}
kc_size_of() {
    [ -f "${1:-}" ] || return 1
    wc -c < "$1" 2>/dev/null | tr -d ' \n'
}

# ── enablement ────────────────────────────────────────────────────────────────
# kc_enabled — rc 0 when the kernel artifact cache is ON for this build.
# --no-kernel-cache sets KERNEL_CACHE_ENABLED=false; HUGMESH_KERNEL_CACHE=off|0|no|none
# is the env spelling of the same opt-out (same shape as --no-shared-assets).
kc_enabled() {
    case "${KERNEL_CACHE_ENABLED:-true}" in false|0|no|off) return 1 ;; esac
    case "${HUGMESH_KERNEL_CACHE:-}" in off|0|no|none|false) return 1 ;; esac
    return 0
}

# kc_root <shared-asset-root> -> "<root>/kernel", or "" when unavailable/off.
# The cache lives INSIDE the shared asset root on purpose: it inherits that root's
# resolution (flag > env > <WORK_DIR>/shared), its docker reachability, and its
# opt-out. --no-shared-assets therefore also disables this cache — sharing kernels
# while refusing to share anything else would be an incoherent promise.
kc_root() {
    local sroot="${1:-}"
    kc_enabled || { printf ''; return 0; }
    [ -n "${sroot}" ] || { printf ''; return 0; }
    printf '%s/kernel' "${sroot%/}"
}

# ── component 4: the signing identity ─────────────────────────────────────────
# kc_key_fingerprint <file> -> "x509:<sha256>" or "spki:<sha256>" on stdout.
#
# PUBLIC HALF ONLY. For a certificate this is SHA-256 over its DER encoding (the same
# quantity `openssl x509 -fingerprint -sha256` prints). For a key file — including a
# PRIVATE key — it is SHA-256 over the DER SubjectPublicKeyInfo, i.e. over the PUBLIC
# half that openssl derives; the private half is never emitted, stored or logged.
# The tag distinguishes the two so a cert and the bare key that signed it cannot be
# conflated into one identity.
# rc 1 (printing nothing) when the file is absent/unreadable/not a recognisable signing
# input, or when openssl is missing — every one of those is "component unavailable",
# which the caller must turn into a MISS.
# SHA-256 of the EMPTY input. A failed `openssl ... | sha256sum` pipeline still emits
# this — which once made THIS function report a garbage file as a perfectly good
# "x509:e3b0c442…" identity, i.e. every unreadable key would have collapsed onto ONE
# shared cache key. Every digest below is therefore checked against it explicitly, in
# addition to the openssl probe that now gates each branch.
_KC_EMPTY_SHA256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

# _kc_pub_digest <tag> <openssl-args...> — run an openssl DER-emitting invocation and
# hash its output, returning rc 1 unless it produced REAL bytes.
_kc_pub_digest() {
    local tag="$1"; shift
    local d
    d="$(openssl "$@" 2>/dev/null | kc_sha256_stdin 2>/dev/null)" || return 1
    [ -n "${d}" ] || return 1
    [ "${d}" != "${_KC_EMPTY_SHA256}" ] || return 1
    printf '%s:%s' "${tag}" "${d}"
}

kc_key_fingerprint() {
    local f="${1:-}" out=''
    [ -n "${f}" ] && [ -f "${f}" ] && [ -r "${f}" ] || return 1
    [ -s "${f}" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    # Each branch is GATED on a `-noout` probe first: a pipeline's exit status is the
    # tail's, so without the probe a failed openssl silently yields the empty digest.
    if openssl x509 -in "${f}" -noout 2>/dev/null; then
        out="$(_kc_pub_digest x509 x509 -in "${f}" -outform DER)" && { printf '%s' "${out}"; return 0; }
    fi
    if openssl x509 -inform DER -in "${f}" -noout 2>/dev/null; then
        out="$(_kc_pub_digest x509 x509 -inform DER -in "${f}" -outform DER)" && { printf '%s' "${out}"; return 0; }
    fi
    # Key file: hash the PUBLIC half only (never the private half).
    if openssl pkey -in "${f}" -pubout -noout 2>/dev/null; then
        out="$(_kc_pub_digest spki pkey -in "${f}" -pubout -outform DER)" && { printf '%s' "${out}"; return 0; }
    fi
    if openssl pkey -pubin -in "${f}" -noout 2>/dev/null; then
        out="$(_kc_pub_digest spki pkey -pubin -in "${f}" -outform DER)" && { printf '%s' "${out}"; return 0; }
    fi
    return 1
}

# kc_signing_fingerprint [candidate...] -> the fingerprint of the signing identity.
#
# $HUGMESH_KERNEL_SIGNING_CERT, when set, is the SOLE source: an operator who names the
# fleet identity explicitly must not be silently downgraded to some other key that
# happens to be lying around, so a bad explicit value FAILS (=> MISS) rather than
# falling through. Otherwise the caller's candidates are tried in order and the first
# that yields a fingerprint wins.
kc_signing_fingerprint() {
    local c fp
    if [ -n "${HUGMESH_KERNEL_SIGNING_CERT:-}" ]; then
        if fp="$(kc_key_fingerprint "${HUGMESH_KERNEL_SIGNING_CERT}")" && [ -n "${fp}" ]; then
            printf '%s' "${fp}"; return 0
        fi
        kc_warn "HUGMESH_KERNEL_SIGNING_CERT=${HUGMESH_KERNEL_SIGNING_CERT} is not a readable"
        kc_warn "certificate or key — refusing to fall back to a different signing identity."
        return 1
    fi
    for c in "$@"; do
        [ -n "${c}" ] || continue
        if fp="$(kc_key_fingerprint "${c}")" && [ -n "${fp}" ]; then
            printf '%s' "${fp}"; return 0
        fi
    done
    return 1
}

# ── component 3: the kernel config + its fragments ────────────────────────────
# kc_config_digest <file>... -> one hash over the ORDERED set of config inputs.
# Framed per file (index + size + content hash) rather than a bare `cat`, so two
# different fragment splits cannot produce one digest by concatenation ambiguity.
# A missing/unreadable/EMPTY input is "component unavailable" -> rc 1 -> MISS.
kc_config_digest() {
    local f i=0 h sz out=''
    [ "$#" -gt 0 ] || return 1
    for f in "$@"; do
        [ -n "${f}" ] && [ -f "${f}" ] && [ -r "${f}" ] || return 1
        h="$(kc_sha256_file "${f}")" || return 1
        sz="$(kc_size_of "${f}")"    || return 1
        [ -n "${h}" ] && [ -n "${sz}" ] && [ "${sz}" != 0 ] || return 1
        out="${out}F ${i} ${sz} ${h}"$'\n'
        i=$((i + 1))
    done
    printf '%s' "${out}" | kc_sha256_stdin
}

# ── component 2: the kernel version token ─────────────────────────────────────
# kc_kver_from_srctree <dir> -> a path-safe kernel version token, derived BEFORE the
# build (the cache must be consulted before deciding to compile). Prefers the source
# tree's own name (linux-6.18.9-gentoo); falls back to the Makefile's
# VERSION.PATCHLEVEL.SUBLEVEL[EXTRAVERSION]. rc 1 when neither is available.
kc_kver_from_srctree() {
    local d="${1:-}" base v p s e tok
    [ -n "${d}" ] && [ -d "${d}" ] || return 1
    base="$(basename -- "${d%/}")"
    case "${base}" in
        linux-?*) if sa_component_ok "${base}"; then printf '%s' "${base}"; return 0; fi ;;
    esac
    [ -f "${d}/Makefile" ] || return 1
    v="$(awk -F'= *' '/^VERSION[[:space:]]*=/{print $2; exit}'    "${d}/Makefile" 2>/dev/null | tr -d ' \r')"
    p="$(awk -F'= *' '/^PATCHLEVEL[[:space:]]*=/{print $2; exit}' "${d}/Makefile" 2>/dev/null | tr -d ' \r')"
    s="$(awk -F'= *' '/^SUBLEVEL[[:space:]]*=/{print $2; exit}'   "${d}/Makefile" 2>/dev/null | tr -d ' \r')"
    e="$(awk -F'= *' '/^EXTRAVERSION[[:space:]]*=/{print $2; exit}' "${d}/Makefile" 2>/dev/null | tr -d ' \r')"
    [ -n "${v}" ] && [ -n "${p}" ] || return 1
    tok="linux-${v}.${p}.${s:-0}${e}"
    sa_component_ok "${tok}" || return 1
    printf '%s' "${tok}"
}

# ── THE key derivation — one function, nothing else may derive a key ──────────
# kc_cache_key <board> <kver> <config-digest> <signing-key-fp> -> <sha256>
#
# ALL FOUR are required. Empty, whitespace-only or newline-bearing components are
# refused outright (rc 1, nothing printed) — a caller must never be able to reach a
# 3-component key that would match entries built under a different 4th component.
# Components are LABELLED and newline-separated before hashing, so no reshuffling of
# characters between adjacent components can collide two different builds onto one key.
kc_cache_key() {
    local board="${1:-}" kver="${2:-}" cfg="${3:-}" fp="${4:-}" c
    if [ "$#" -ne 4 ]; then
        kc_err "kc_cache_key needs exactly 4 components (board kver config-digest key-fp); got $#"
        return 1
    fi
    for c in "${board}" "${kver}" "${cfg}" "${fp}"; do
        case "${c}" in
            ''|*[$'\n\t']*) return 1 ;;
        esac
        case "${c}" in
            ' '*|*' ') return 1 ;;
        esac
    done
    # board additionally becomes a DIRECTORY component; keep it traversal-safe.
    sa_component_ok "${board}" || { kc_err "refusing unsafe board component '${board}'"; return 1; }
    printf 'kernel-cache-format=%s\nboard=%s\nkver=%s\nconfig-digest=%s\nsigning-key-fp=%s\n' \
        "${KC_FORMAT}" "${board}" "${kver}" "${cfg}" "${fp}" | kc_sha256_stdin
}

# kc_entry_dir <kernel-cache-root> <board> <key> -> <root>/<board>/<key>
kc_entry_dir() {
    local root="${1%/}" board="${2:-}" key="${3:-}"
    [ -n "${root}" ] || { printf ''; return 1; }
    sa_component_ok "${board}" || { kc_err "refusing unsafe board component '${board}'"; return 1; }
    sa_component_ok "${key}"   || { kc_err "refusing unsafe cache key '${key}'"; return 1; }
    printf '%s/%s/%s' "${root}" "${board}" "${key}"
}

# ── prune ─────────────────────────────────────────────────────────────────────
# kc_prune <entry-dir> <reason> — remove a bad/incomplete entry, HONESTLY logged.
# Silently ignoring a corrupt entry would leave it to be re-examined (and re-reported)
# by every future build; deleting it quietly would hide a real problem.
kc_prune() {
    local entry="${1%/}" reason="${2:-unspecified}"
    [ -n "${entry}" ] || return 0
    case "${entry}" in /|/*/) return 0 ;; esac
    [ -e "${entry}" ] || return 0
    kc_warn "pruning kernel-cache entry ${entry}: ${reason}"
    rm -rf -- "${entry}" 2>/dev/null || {
        kc_warn "could not remove ${entry} (permissions?) — it will keep MISSING, never be used"
        return 1
    }
    return 0
}

# ── lookup ────────────────────────────────────────────────────────────────────
# kc_manifest_get <manifest> <field> -> the field's value (first occurrence).
# A top-level function rather than a closure over kc_lookup's locals: a function
# defined inside a function is GLOBAL in bash, so a closure would outlive its own
# variables and misread the next caller's manifest.
kc_manifest_get() {
    [ -f "${1:-}" ] || return 1
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# kc_lookup <root> <board> <key> <kver> <config-digest> <key-fp>
#   Prints the entry directory on a VALIDATED hit; rc 1 (nothing printed) on a miss.
#
# The four components are already folded into <key>, and they are ALSO re-checked
# against the manifest here. That redundancy is the point: it catches an entry that was
# hand-copied, restored from a backup of another fleet, or written by a build whose key
# derivation differed — cases where the directory name alone would "match".
kc_lookup() {
    local root="${1:-}" board="${2:-}" key="${3:-}" kver="${4:-}" cfg="${5:-}" fp="${6:-}"
    local entry man line n h sz have_file=0
    kc_require_sa || return 1
    [ -n "${root}" ] || return 1
    entry="$(kc_entry_dir "${root}" "${board}" "${key}")" || return 1
    [ -n "${entry}" ] || return 1
    [ -d "${entry}" ] || return 1

    man="${entry}/manifest"
    if [ ! -s "${man}" ]; then
        kc_prune "${entry}" "no manifest (interrupted write?)"
        return 1
    fi

    if [ "$(kc_manifest_get "${man}" kernel-cache-format)" != "${KC_FORMAT}" ]; then
        kc_prune "${entry}" "manifest format $(kc_manifest_get "${man}" kernel-cache-format) != ${KC_FORMAT} (cache layout changed)"
        return 1
    fi
    # Component agreement. Reported individually so the log says WHICH one moved.
    if [ "$(kc_manifest_get "${man}" board)" != "${board}" ]; then
        kc_prune "${entry}" "board mismatch (manifest '$(kc_manifest_get "${man}" board)' vs build '${board}')"; return 1
    fi
    if [ "$(kc_manifest_get "${man}" kver)" != "${kver}" ]; then
        kc_prune "${entry}" "kernel version mismatch (manifest '$(kc_manifest_get "${man}" kver)' vs build '${kver}')"; return 1
    fi
    if [ "$(kc_manifest_get "${man}" config-digest)" != "${cfg}" ]; then
        kc_prune "${entry}" "kernel config digest mismatch (config or a fragment changed)"; return 1
    fi
    if [ "$(kc_manifest_get "${man}" signing-key-fp)" != "${fp}" ]; then
        kc_prune "${entry}" "SIGNING KEY mismatch — entry was signed under a different (retired?) key"
        return 1
    fi
    if [ "$(kc_manifest_get "${man}" cache-key)" != "${key}" ]; then
        kc_prune "${entry}" "cache-key in manifest does not match its own directory"; return 1
    fi

    # Payload integrity: every recorded file must exist at the recorded size and hash.
    while IFS= read -r line; do
        case "${line}" in file\ *) ;; *) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        n="${2:-}"; h="${3:-}"; sz="${4:-}"
        if [ -z "${n}" ] || [ -z "${h}" ] || [ -z "${sz}" ]; then
            kc_prune "${entry}" "malformed manifest file line"; return 1
        fi
        if ! sa_component_ok "${n}"; then
            kc_prune "${entry}" "unsafe payload name '${n}' in manifest"; return 1
        fi
        if [ ! -f "${entry}/payload/${n}" ]; then
            kc_prune "${entry}" "payload file '${n}' recorded but missing (incomplete entry)"; return 1
        fi
        if [ "$(kc_size_of "${entry}/payload/${n}")" != "${sz}" ]; then
            kc_prune "${entry}" "payload file '${n}' is the wrong size (truncated)"; return 1
        fi
        if [ "$(kc_sha256_file "${entry}/payload/${n}")" != "${h}" ]; then
            kc_prune "${entry}" "payload file '${n}' FAILED its sha256 (corrupt)"; return 1
        fi
        have_file=1
    done < "${man}"

    if [ "${have_file}" != 1 ]; then
        kc_prune "${entry}" "manifest records no payload files"; return 1
    fi
    printf '%s' "${entry}"
    return 0
}

# ── store ─────────────────────────────────────────────────────────────────────
# kc_refuse_key_material <file> — rc 1 when the file carries a PEM private-key header.
# The cache is a shared, fleet-visible directory; a builder that mis-points a payload at
# a key directory must fail loudly here rather than publish key material.
kc_refuse_key_material() {
    local f="${1:-}"
    [ -f "${f}" ] || return 0
    if LC_ALL=C grep -qa -- '-----BEGIN .*PRIVATE KEY-----' "${f}" 2>/dev/null; then
        return 1
    fi
    return 0
}

# _kc_store_locked <entry> <board> <key> <kver> <cfg> <fp> <tag> <name=path>...
_kc_store_locked() {
    local entry="$1" board="$2" key="$3" kver="$4" cfg="$5" fp="$6" tag="$7"; shift 7
    local tmp="${entry}.tmp.$$" spec n p h sz
    rm -rf -- "${tmp}" 2>/dev/null || true
    mkdir -p "${tmp}/payload" || { kc_err "cannot create ${tmp}"; return 1; }
    : > "${tmp}/manifest" || { kc_err "cannot write manifest in ${tmp}"; rm -rf -- "${tmp}"; return 1; }
    {
        printf 'kernel-cache-format=%s\n' "${KC_FORMAT}"
        printf 'board=%s\n'               "${board}"
        printf 'kver=%s\n'                "${kver}"
        printf 'config-digest=%s\n'       "${cfg}"
        printf 'signing-key-fp=%s\n'      "${fp}"
        printf 'cache-key=%s\n'           "${key}"
        printf 'created=%s\n'             "$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
        printf 'builder=%s\n'             "${tag}"
    } >> "${tmp}/manifest"

    for spec in "$@"; do
        n="${spec%%=*}"; p="${spec#*=}"
        if [ -z "${n}" ] || [ "${n}" = "${spec}" ] || [ -z "${p}" ]; then
            kc_err "kc_store: bad payload spec '${spec}' (want name=path)"; rm -rf -- "${tmp}"; return 1
        fi
        sa_component_ok "${n}" || { kc_err "kc_store: unsafe payload name '${n}'"; rm -rf -- "${tmp}"; return 1; }
        if [ ! -f "${p}" ] || [ ! -s "${p}" ]; then
            kc_err "kc_store: payload '${n}' missing or empty at ${p} — refusing to cache a partial kernel"
            rm -rf -- "${tmp}"; return 1
        fi
        if ! kc_refuse_key_material "${p}"; then
            kc_err "kc_store: payload '${n}' (${p}) contains a PEM PRIVATE KEY header."
            kc_err "The kernel cache is a shared directory and must never hold key material. Refusing."
            rm -rf -- "${tmp}"; return 1
        fi
        cp -f -- "${p}" "${tmp}/payload/${n}" || { kc_err "kc_store: cannot copy ${p}"; rm -rf -- "${tmp}"; return 1; }
        h="$(kc_sha256_file "${tmp}/payload/${n}")"; sz="$(kc_size_of "${tmp}/payload/${n}")"
        if [ -z "${h}" ] || [ -z "${sz}" ]; then
            kc_err "kc_store: cannot digest ${n}"; rm -rf -- "${tmp}"; return 1
        fi
        printf 'file %s %s %s\n' "${n}" "${h}" "${sz}" >> "${tmp}/manifest"
    done

    # Publish atomically: an interrupted store leaves a .tmp sibling (ignored by lookup,
    # which only ever reads <root>/<board>/<key>), never a half-populated entry.
    rm -rf -- "${entry}" 2>/dev/null || true
    if ! mv -f -- "${tmp}" "${entry}"; then
        kc_err "kc_store: could not publish ${entry}"; rm -rf -- "${tmp}"; return 1
    fi
    return 0
}

# kc_store <root> <board> <key> <kver> <cfg> <fp> <tag> <name=path>...
kc_store() {
    local root="${1:-}" board="${2:-}" key="${3:-}" entry
    kc_require_sa || return 1
    [ "$#" -ge 8 ] || { kc_err "kc_store: need root board key kver cfg fp tag and >=1 payload"; return 1; }
    [ -n "${root}" ] || return 1
    entry="$(kc_entry_dir "${root}" "${board}" "${key}")" || return 1
    mkdir -p "$(dirname "${entry}")" 2>/dev/null || { kc_err "cannot create $(dirname "${entry}")"; return 1; }
    shift 3
    sa_lock_run "${entry}.lock" _kc_store_locked "${entry}" "${board}" "${key}" "$@"
}

# ── restore ───────────────────────────────────────────────────────────────────
# kc_restore <entry> <name=dest>... — copy validated payload files out of a HIT entry.
# Refuses a name the manifest does not record (so a caller cannot invent a payload the
# entry never validated). Parent directories are created; existing files are replaced.
kc_restore() {
    local entry="${1%/}"; shift || true
    local spec n d
    [ -n "${entry}" ] && [ -d "${entry}" ] || { kc_err "kc_restore: no entry"; return 1; }
    [ "$#" -gt 0 ] || { kc_err "kc_restore: nothing to restore"; return 1; }
    for spec in "$@"; do
        n="${spec%%=*}"; d="${spec#*=}"
        if [ -z "${n}" ] || [ "${n}" = "${spec}" ] || [ -z "${d}" ]; then
            kc_err "kc_restore: bad spec '${spec}' (want name=dest)"; return 1
        fi
        if ! grep -q "^file ${n} " "${entry}/manifest" 2>/dev/null; then
            kc_err "kc_restore: '${n}' is not a recorded payload of ${entry}"; return 1
        fi
        mkdir -p "$(dirname "${d}")" 2>/dev/null || true
        cp -f -- "${entry}/payload/${n}" "${d}" || { kc_err "kc_restore: cannot write ${d}"; return 1; }
    done
    return 0
}

# ── payload packing (shared by every builder, so none of them hand-rolls tar) ─
# A cached kernel is not one file: it is /boot products (vmlinuz, initramfs, System.map,
# config, the unsigned UKI, DTBs) plus a whole /lib/modules/<kver> tree. Packing them as
# SELF-DESCRIBING tars means restore does not have to know <kver> or the board's kernel
# image filename — it just unpacks into the same directory the pack came from.

# kc_names_matching <dir> <glob>... -> basenames of existing entries, one per line.
# Globs are expanded HERE (not by the caller) so a non-matching glob contributes
# nothing instead of leaking a literal '*' into a tar argument list.
kc_names_matching() {
    local dir="${1%/}"; shift || true
    local g p n
    [ -d "${dir}" ] || return 0
    for g in "$@"; do
        for p in "${dir}"/${g}; do
            [ -e "${p}" ] || continue
            n="$(basename -- "${p}")"
            sa_component_ok "${n}" || continue
            printf '%s\n' "${n}"
        done
    done
}

# kc_pack <out.tar> <dir> <name>... — tar the NAMED entries of <dir>, relative to <dir>.
# rc 1 when no name was given or tar failed, so a caller can never publish an empty
# payload as if it were a kernel.
kc_pack() {
    local out="${1:-}" dir="${2:-}"; shift 2 || true
    [ -n "${out}" ] && [ -d "${dir}" ] && [ "$#" -gt 0 ] || return 1
    command -v tar >/dev/null 2>&1 || { kc_err "tar(1) not found — cannot pack kernel artifacts"; return 1; }
    rm -f -- "${out}"
    tar -C "${dir}" -cf "${out}" -- "$@" 2>/dev/null || { rm -f -- "${out}"; return 1; }
    [ -s "${out}" ] || { rm -f -- "${out}"; return 1; }
    return 0
}

# kc_unpack <tar> <dir> — restore a packed payload into <dir> (created if needed).
kc_unpack() {
    local tarf="${1:-}" dir="${2:-}"
    [ -f "${tarf}" ] && [ -n "${dir}" ] || return 1
    command -v tar >/dev/null 2>&1 || { kc_err "tar(1) not found — cannot restore kernel artifacts"; return 1; }
    mkdir -p "${dir}" || return 1
    tar -C "${dir}" -xf "${tarf}" || return 1
    return 0
}

# ── summary line for the build banner / --print-plan ─────────────────────────
kc_describe() {
    local root="${1:-}" board="${2:-}" key="${3:-}"
    if [ -z "${root}" ]; then
        printf 'signed-kernel cache: DISABLED (kernel is rebuilt and re-signed for this image)'
        return 0
    fi
    if [ -z "${key}" ]; then
        printf 'signed-kernel cache: root=%s board=%s key=<unavailable — always a MISS>' \
            "${root}" "${board:-?}"
        return 0
    fi
    printf 'signed-kernel cache: root=%s board=%s key=%s' "${root}" "${board:-?}" "${key}"
}
