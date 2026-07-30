#!/usr/bin/env bash
# _binpkg-pool-lib.sh — SOURCED helper: per-board binpkg-pool fingerprint guard.
# Shared-binpkg track, Lane 4d. Sourced by all eight stage4 builders.
#
# WHY THIS EXISTS — THE LOAD-BEARING SIGILL SAFETY NET (over directory isolation).
# Binpkg reuse (`--usepkg`) is ONLY safe when {CHOST, exact CFLAGS/-mcpu, CXXFLAGS,
# profile, gcc/libc ABI} match. portage's `--binpkg-respect-use=y` validates USE
# ONLY — it does NOT compare CHOST/CFLAGS/-mcpu. Every aarch64 board shares
# CHOST=aarch64-unknown-linux-gnu but differs in -mcpu (rpi5 cortex-a76 / rpi4 a72 /
# rpi3 a53 / frite a53 / jetson a78ae / opi5 a76.a55 / opiz2 a53). A binpkg tuned for
# cortex-a76 (ARMv8.2-A: LSE atomics, dotprod) run on an a53/a72 (ARMv8.0-A) SIGILLs
# at runtime. Directory isolation (per-board BUILD_SUBDIR ⇒ per-board pkgdir) is the
# primary guard, but a stray env override, a mis-set --build-subdir, or a shared
# custom pool could still point two ABI-incompatible builds at one pkgdir. This
# guard is the belt-and-suspenders: it stamps each pool with a fingerprint of its
# ABI-defining make.conf values and REFUSES `--usepkg` reuse when an existing pool's
# fingerprint != the current build's. It is the only thing in the whole pipeline
# that actually compares CFLAGS before reuse.
#
# The rendered make.conf is the source of truth: for the cross builders CFLAGS is
# `-mcpu=<board-cpu> ...` (post @@RPI_CPU@@ substitution), so the fingerprint DOES
# capture the -mcpu that portage ignores. Also flip the fingerprint on any
# CHOST/CFLAGS/CXXFLAGS/profile change, and (per the invalidation rules) whenever a
# correctness pin like INSTALL_MASK/package.mask changes materially — the caller
# passes those in as an extra salt when relevant (e.g. the gettext .mo fix).

# _bpl_mc_get VAR MAKECONF -> value of the LAST `VAR=...` assignment, quotes stripped.
_bpl_mc_get() {
    [ -f "$2" ] || { printf ''; return 0; }
    sed -n "s/^[[:space:]]*$1=//p" "$2" | tail -1 \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

# pool_fingerprint_string CHOST COMMON_FLAGS CFLAGS CXXFLAGS PROFILE [SALT] -> hash.
# Stable across runs; differs whenever any ABI-defining component differs.
pool_fingerprint_string() {
    printf 'CHOST=%s\nCOMMON_FLAGS=%s\nCFLAGS=%s\nCXXFLAGS=%s\nPROFILE=%s\nSALT=%s\n' \
        "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" \
        | sha256sum | awk '{print $1}'
}

# pool_fingerprint_of MAKECONF [PROFILE] [SALT] -> hash on stdout (empty if the
# make.conf does not exist yet — the caller treats "" as "unknown, skip the guard").
pool_fingerprint_of() {
    local mc="$1" prof="${2:-}" salt="${3:-}"
    [ -f "${mc}" ] || { printf ''; return 0; }
    local chost common cflags cxxflags
    chost="$(_bpl_mc_get CHOST "${mc}")"
    common="$(_bpl_mc_get COMMON_FLAGS "${mc}")"
    cflags="$(_bpl_mc_get CFLAGS "${mc}")"
    cxxflags="$(_bpl_mc_get CXXFLAGS "${mc}")"
    pool_fingerprint_string "${chost}" "${common}" "${cflags}" "${cxxflags}" "${prof}" "${salt}"
}

# pool_fingerprint_guard PKGDIR FP -> preflight over an existing pool.
#   FP empty                      -> return 0 (unknown fingerprint; nothing to compare).
#   no stamp + EMPTY pool         -> write FP fresh, return 0 (normal fresh-pool path).
#   no stamp + pool HAS binpkgs   -> write FP fresh but WARN LOUDLY, return 0. An
#       unstamped pool that already holds binaries pre-dates this guard (a pool built
#       on an older tree, or a pool an operator manually pointed two boards at). We can
#       NOT tell which board built those binaries — adopting them under this build's key
#       is only safe if they are same-board. Hard-refusing would destroy every legitimate
#       pre-guard same-board cache on first rollout, so we adopt-with-a-loud-warning: the
#       risk is made VISIBLE (with the flush command) without nuking valid caches. The
#       PRIMARY defense remains the per-board directory split (each board its own pkgdir).
#   stamp == FP                   -> return 0 (safe to reuse).
#   stamp != FP                   -> print a LOUD message to stderr, return 1 (caller aborts).
# The stamp file is `${PKGDIR}/.hugmesh-pool-fingerprint`.
# _pool_has_binpkgs PKGDIR -> 0 if the pool already holds binary packages (Packages
# index or any gpkg/tbz2/xpak), else 1. Used to decide adopt-silently vs adopt-with-warning.
_pool_has_binpkgs() {
    local d="${1%/}"
    [ -s "${d}/Packages" ] && return 0
    local f
    for f in "${d}"/*.gpkg.tar "${d}"/*.tbz2 "${d}"/*.xpak; do
        [ -e "${f}" ] && return 0
    done
    # binpkgs also nest under <category>/<pkg>.{gpkg.tar,tbz2}
    [ -n "$(find "${d}" -maxdepth 3 \( -name '*.gpkg.tar' -o -name '*.tbz2' \) -print -quit 2>/dev/null)" ] && return 0
    return 1
}
pool_fingerprint_guard() {
    local pkgdir="$1" fp="${2:-}" fpfile
    fpfile="${pkgdir%/}/.hugmesh-pool-fingerprint"
    [ -n "${fp}" ] || return 0
    mkdir -p "${pkgdir}" 2>/dev/null || true
    if [ -f "${fpfile}" ]; then
        local existing; existing="$(cat "${fpfile}" 2>/dev/null || true)"
        if [ "${existing}" = "${fp}" ]; then
            return 0
        fi
        {
            echo "FATAL: binpkg pool ABI MISMATCH at ${pkgdir}"
            echo "  existing pool fingerprint: ${existing:-<empty>}"
            echo "  this build's fingerprint:  ${fp}"
            echo "  A pool is keyed by (CHOST + exact CFLAGS/-mcpu + CXXFLAGS + profile)."
            echo "  Reusing binpkgs built for a DIFFERENT key would SIGILL at runtime —"
            echo "  portage's --usepkg/--binpkg-respect-use checks USE ONLY, never CFLAGS."
            echo "  REFUSING --usepkg reuse of this pool. Fix by ONE of:"
            echo "    * build this board into its OWN --build-subdir / pkgdir (the default), or"
            echo "    * flush the stale pool:  rm -rf '${pkgdir}'"
        } >&2
        return 1
    fi
    # No stamp yet. If the pool ALREADY holds binpkgs of unknown provenance, adopt but
    # WARN — an unstamped non-empty pool is exactly the first-rollout / manually-shared
    # case where the guard would otherwise be silently inert.
    if _pool_has_binpkgs "${pkgdir}"; then
        {
            echo "WARNING: adopting an UNSTAMPED binpkg pool that already holds binaries: ${pkgdir}"
            echo "  fingerprint now stamped: ${fp}"
            echo "  These binaries pre-date the ABI fingerprint guard, so their build key"
            echo "  (CHOST + CFLAGS/-mcpu + profile) is UNKNOWN. If this pool was ever populated"
            echo "  by a DIFFERENT board (e.g. two boards pointed at the same --build-subdir),"
            echo "  reusing them would SIGILL at runtime. If it is a same-board pool this is safe."
            echo "  If unsure, flush it:  rm -rf '${pkgdir}'   (a fresh pool recompiles once, then reuses)."
        } >&2
    fi
    printf '%s\n' "${fp}" > "${fpfile}" 2>/dev/null || true
    return 0
}

# pool_fingerprint_preflight PKGDIR MAKECONF [PROFILE] [SALT] -> convenience wrapper:
# compute the current build's fingerprint from the rendered make.conf and guard the
# pool. Returns non-zero (with the loud message already printed) on an ABI mismatch;
# the builder wraps this with `|| { err ...; exit 1; }`.
pool_fingerprint_preflight() {
    local pkgdir="$1" mc="$2" prof="${3:-}" salt="${4:-}" fp
    fp="$(pool_fingerprint_of "${mc}" "${prof}" "${salt}")"
    pool_fingerprint_guard "${pkgdir}" "${fp}"
}
