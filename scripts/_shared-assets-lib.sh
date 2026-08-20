#!/usr/bin/env bash
# _shared-assets-lib.sh — SOURCED helper: the ONE resolver for the fleet's shared
# build-asset root (stage3 seeds, distfiles, binpkg pools) + its concurrency locks.
# Shared-build-assets track (G1/G2/G3). Sourced by all ten stage4 builders.
#
# WHY THIS EXISTS
# ---------------
# #439 gave every board a per-board binpkg pool and a read-only shared distfiles
# cache, but both are keyed off BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}":
#
#   * G1 — the stage3 SEED is cached at "${BUILD_ROOT}/<stage3-basename>". Any build
#     with a fresh BUILD_SUBDIR re-downloads a ~250 MB tarball.
#   * G2 — the binpkg POOL is "${BUILD_ROOT}/pkgdir". The Studio derives
#     BUILD_SUBDIR="wl-<entry-id>" per worklist entry (worklist.py: build_subdir), and
#     entry ids are per-session, so EVERY GUI build got a brand-new EMPTY pool. #439's
#     per-board reuse only ever materialised for make-driven builds.
#   * G3 — there was no shared root at all.
#
# The per-entry build TREE isolation (wl-<id> sysroot/staging/log) is a deliberate,
# tested invariant and is NOT touched here: only the three genuinely shareable assets
# move out of the per-entry tree.
#
# WHERE THE ROOT LIVES — and why that matters for docker
# ------------------------------------------------------
# Default: "${WORK_DIR}/shared". The Makefile's DOCKER_RUN mounts -v $(WORK_DIR):/out,
# so a root under WORK_DIR is already reachable in-container with NO new mount. The
# Studio is the one caller that must be explicit: a GUI run's WORK_DIR is the PER-SESSION
# dir "<out>/sessions/<id>", so "${WORK_DIR}/shared" would be per-session (i.e. useless).
# The BuildDriver therefore passes --shared-assets <out>/shared (and, under docker, mounts
# it read-WRITE and rewrites the flag). Resolution order:
#
#   1. an explicit --shared-assets DIR  (argv; the Studio's channel)
#   2. $HUGMESH_SHARED_ASSETS           (env override — a pool outside WORK_DIR)
#   3. "${WORK_DIR}/shared"             (default; already inside the docker mount)
#
# and --no-shared-assets (or HUGMESH_SHARED_ASSETS=off) opts out entirely: seeds,
# distfiles and pool fall back to the legacy per-BUILD_ROOT paths, byte-for-byte.
#
# SAFETY — this library never weakens a check
# -------------------------------------------
#   * Seeds are re-VERIFIED on every reuse. sa_seed_acquire runs the caller's verifier
#     (dlv_verify_stage3: signed DIGESTS + SHA512/256) on the file it is about to hand
#     back, cache HIT or fresh download. A poisoned cache is therefore caught by the
#     same code that catches a poisoned mirror. On failure the file is discarded, ONE
#     re-fetch is attempted, and a second failure FAILS CLOSED (no path is printed, so
#     the caller cannot unpack anything).
#   * Seeds are keyed per-ARCH (<root>/seed/<arch>/) AND the basename must NAME that
#     arch, so an amd64 seed can never be handed to an arm64 build even if someone
#     drops it in the wrong directory.
#   * Pools still go through _binpkg-pool-lib.sh's pool_fingerprint_guard — widening
#     reuse is exactly why that guard exists. sa_pool_guard wraps the preflight in the
#     pool lock so two builds cannot race the stamp.
#   * Mutation of the shared root is serialised with flock (sa_lock_run), re-entrant so
#     a single build cannot deadlock against itself. A shared pool additionally takes a
#     LONG-LIVED exclusive writer lock (sa_pool_hold): portage has no
#     binpkg-multi-instance here, so two concurrent writers into one pool corrupt it —
#     that was invalidation rule #3 in docs/SHARED-BINPKG.md, and sharing pools across
#     Studio entries is what makes it reachable.
#
# It is meant to be SOURCED, never executed. It defines functions + defaults only.

# shellcheck disable=SC2317
if [ -n "${_SHARED_ASSETS_LIB_SOURCED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_SHARED_ASSETS_LIB_SOURCED=1

# ── logging (own prefix; never collides with the builders' info/warn/err) ──────
if [ -t 2 ]; then
    _SA_RED=$'\033[31m'; _SA_GRN=$'\033[32m'; _SA_YEL=$'\033[33m'; _SA_RST=$'\033[0m'
else
    _SA_RED=''; _SA_GRN=''; _SA_YEL=''; _SA_RST=''
fi
sa_err()  { printf '%s[shared-assets] ERROR:%s %s\n' "${_SA_RED}" "${_SA_RST}" "$*" >&2; }
sa_warn() { printf '%s[shared-assets] WARN:%s %s\n'  "${_SA_YEL}" "${_SA_RST}" "$*" >&2; }
sa_info() { [ -n "${SA_QUIET:-}" ] || printf '%s[shared-assets]%s %s\n' "${_SA_GRN}" "${_SA_RST}" "$*" >&2; }

# How long sa_lock_run waits for a contended lock before giving up (seconds).
SA_LOCK_WAIT="${SA_LOCK_WAIT:-1800}"

# ── path components ───────────────────────────────────────────────────────────
# Every shared path is built from operator-supplied components (arch, board key).
# Reject anything that could escape the root or confuse a shell/flag parser.
sa_component_ok() {
    local c="$1"
    case "${c}" in
        ""|.|..|-*|*/*|*$'\n'*|*..*) return 1 ;;
    esac
    case "${c}" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# sa_norm_arch <arch> -> the Gentoo autobuild arch token used in seed basenames.
sa_norm_arch() {
    case "${1:-}" in
        amd64|x86_64|x86)  printf 'amd64' ;;
        arm64|aarch64)     printf 'arm64' ;;
        *)                 printf '%s' "${1:-}" ;;
    esac
}

# ── root / sub-root resolution ────────────────────────────────────────────────
# sa_enabled — rc 0 when sharing is ON for this build. The builder sets
# SHARED_ASSETS_ENABLED=false for --no-shared-assets; HUGMESH_SHARED_ASSETS=off|0|none
# is the env spelling of the same opt-out.
sa_enabled() {
    case "${SHARED_ASSETS_ENABLED:-true}" in false|0|no|off) return 1 ;; esac
    case "${HUGMESH_SHARED_ASSETS:-}" in off|0|no|none|false) return 1 ;; esac
    return 0
}

# sa_root <work_dir> [explicit] -> the shared-asset root, or "" when sharing is off.
# Precedence: explicit argv > $HUGMESH_SHARED_ASSETS > <work_dir>/shared.
sa_root() {
    local work_dir="${1:-}" explicit="${2:-}"
    sa_enabled || { printf ''; return 0; }
    if [ -n "${explicit}" ]; then printf '%s' "${explicit%/}"; return 0; fi
    if [ -n "${HUGMESH_SHARED_ASSETS:-}" ]; then printf '%s' "${HUGMESH_SHARED_ASSETS%/}"; return 0; fi
    [ -n "${work_dir}" ] || { printf ''; return 0; }
    printf '%s/shared' "${work_dir%/}"
}

# sa_seed_dir <root> <arch>          -> <root>/seed/<arch>
sa_seed_dir() {
    local root="${1%/}" arch; arch="$(sa_norm_arch "${2:-}")"
    [ -n "${root}" ] || { printf ''; return 1; }
    sa_component_ok "${arch}" || { sa_err "refusing unsafe arch component '${2:-}'"; return 1; }
    printf '%s/seed/%s' "${root}" "${arch}"
}

# sa_distfiles_dir <root>            -> <root>/distfiles  (arch-independent sources)
sa_distfiles_dir() {
    local root="${1%/}"
    [ -n "${root}" ] || { printf ''; return 1; }
    printf '%s/distfiles' "${root}"
}

# sa_pool_dir <root> <board-key>     -> <root>/pkgdir/<board-key>
# The key is the BOARD (snap-build-pi4, snap-build-jetson, …) — NEVER the build subdir:
# per docs/SHARED-BINPKG.md the pool key must be per-board (-mcpu ⇒ SIGILL), and the
# whole point of G2 is that a Studio wl-<id> subdir must NOT fragment the pool.
sa_pool_dir() {
    local root="${1%/}" key="${2:-}"
    [ -n "${root}" ] || { printf ''; return 1; }
    sa_component_ok "${key}" || { sa_err "refusing unsafe pool key '${key}'"; return 1; }
    printf '%s/pkgdir/%s' "${root}" "${key}"
}

# ── locking ───────────────────────────────────────────────────────────────────
# sa_lock_run <lockfile> <cmd...> — run cmd under an exclusive flock on <lockfile>,
# RE-ENTRANT: if this shell already holds that lock the command runs directly instead
# of blocking on itself (a single build must never deadlock against its own lock).
# Lockfiles are SIBLINGS of the guarded dir/file, never inside it — the same discipline
# build-x86-host-stage4.sh's acquire_build_lock uses, so a cleanup that deletes the
# guarded tree cannot delete a held lock out from under a waiter.
_SA_LOCKS_HELD="${_SA_LOCKS_HELD:-}"
sa_lock_run() {
    local lock="${1:-}"; shift || true
    [ -n "${lock}" ] || { sa_err "sa_lock_run: no lockfile"; return 2; }
    [ "$#" -gt 0 ]   || { sa_err "sa_lock_run: no command"; return 2; }
    case "|${_SA_LOCKS_HELD}|" in
        *"|${lock}|"*) "$@"; return $? ;;   # already held by THIS shell → run inline
    esac
    if ! command -v flock >/dev/null 2>&1; then
        sa_err "flock(1) not found (util-linux) — refusing to mutate the shared asset root"
        sa_err "without exclusion (two builds would corrupt the seed cache / binpkg pool)."
        sa_err "Install util-linux, or re-run with --no-shared-assets for private assets."
        return 1
    fi
    mkdir -p "$(dirname "${lock}")" 2>/dev/null || true
    local fd rc=0
    if ! exec {fd}>>"${lock}"; then sa_err "cannot open lockfile ${lock}"; return 1; fi
    if ! flock -w "${SA_LOCK_WAIT}" "${fd}"; then
        sa_err "timed out after ${SA_LOCK_WAIT}s waiting for ${lock}"
        sa_err "holder: $(cat "${lock}" 2>/dev/null || echo '<unreadable>')"
        exec {fd}>&-
        return 1
    fi
    printf 'pid=%s started=%s\n' "$$" "$(date -u +%FT%TZ 2>/dev/null || echo '?')" >"${lock}" 2>/dev/null || true
    _SA_LOCKS_HELD="${_SA_LOCKS_HELD}|${lock}"
    "$@" || rc=$?
    _SA_LOCKS_HELD="${_SA_LOCKS_HELD/"|${lock}"/}"
    exec {fd}>&-
    return "${rc}"
}

# sa_pool_hold <pooldir> — take a LONG-LIVED exclusive writer lock on a shared pool,
# held for the life of the build (the kernel drops it when the process dies, so a
# crashed build can never wedge the next one). NON-blocking: an emerge is hours long,
# so a silent multi-hour wait would be worse than a fast, actionable failure.
#
# Needed because sharing a pool across worklist entries makes docs/SHARED-BINPKG.md
# invalidation rule #3 REACHABLE: the tree has no binpkg-multi-instance, so two
# concurrent writers into one pkgdir overwrite each other's package instances.
sa_pool_hold() {
    local pool="${1%/}" lock
    [ -n "${pool}" ] || return 0
    [ -n "${_SA_POOL_LOCK_FD:-}" ] && return 0     # idempotent within one build
    lock="${pool}.writer.lock"
    command -v flock >/dev/null 2>&1 || {
        sa_err "flock(1) not found (util-linux) — cannot guard the shared binpkg pool ${pool}"
        return 1
    }
    mkdir -p "$(dirname "${lock}")" 2>/dev/null || true
    local fd
    if ! exec {fd}>>"${lock}"; then sa_err "cannot open pool lockfile ${lock}"; return 1; fi
    if ! flock -n "${fd}"; then
        sa_err "another build is already writing the shared binpkg pool ${pool}"
        sa_err "holder: $(cat "${lock}" 2>/dev/null || echo '<unreadable>')"
        sa_err "The tree has no binpkg-multi-instance: two writers overwrite each other's"
        sa_err "package instances (docs/SHARED-BINPKG.md invalidation rule #3). Wait for the"
        sa_err "other build, or re-run this one with --no-shared-assets (private pool)."
        exec {fd}>&-
        return 1
    fi
    printf 'pid=%s pool=%s started=%s\n' "$$" "${pool}" "$(date -u +%FT%TZ 2>/dev/null || echo '?')" \
        >"${lock}" 2>/dev/null || true
    _SA_POOL_LOCK_FD="${fd}"
    return 0
}

# sa_pool_guard <pooldir> <makeconf> [profile] [salt] — the #439 fingerprint preflight,
# run UNDER the pool lock so two builds cannot race the stamp file. Never bypasses the
# guard: a fingerprint mismatch still returns non-zero with pool_fingerprint_guard's
# own loud SIGILL/ABI message, and the caller aborts.
sa_pool_guard() {
    local pool="${1%/}" mc="$2" prof="${3:-}" salt="${4:-}"
    command -v pool_fingerprint_preflight >/dev/null 2>&1 || {
        sa_err "pool_fingerprint_preflight not sourced — refusing to touch a shared pool"
        return 1
    }
    sa_lock_run "${pool}.stamp.lock" pool_fingerprint_preflight "${pool}" "${mc}" "${prof}" "${salt}"
}

# ── ARM host-side BDEPEND binpkg pool (PR #72 §4 design) ──────────────────────
# Cross builds merge every BDEPEND "to /" — the BUILD CONTAINER's own root — under
# the crossdev wrapper's --root-deps=rdeps, and wave 1 (#46) measured 33–49 such
# host tools source-compiled per arm image with no pool at all (the container's
# default PKGDIR dies with the container). Those tools are amd64 binaries EXECUTED
# BY THE BUILDER; the target board's -mcpu is irrelevant to them, so ONE leg
# serves every arm board:
#
#     <root>/pkgdir/host-amd64-bdep
#
# keyed by the HOST's identity (host make.conf ABI values + host profile + the
# builder-toolchain salt), NEVER the target's. The wiring is HOST-side only:
# PKGDIR + FEATURES are appended to the HOST /etc/portage/make.conf (behind
# hostguard_mutation_allowed, like every other host-mutation site), never to the
# target make.conf — the target config root (PORTAGE_CONFIGROOT=${SYSROOT}) keeps
# its own per-board PKGDIR, so a target binpkg can never land in (or be taken
# from) the host leg.
#
# LOCKING — why this leg uses binpkg-multi-instance INSTEAD of sa_pool_hold:
# host bdeps merge to / DURING the hours-long target cross-emerge (the "to /"
# batch), so the leg's write window IS the target emerge. Holding the
# single-writer lock across it would serialize all arm builds of DIFFERENT
# boards end-to-end on one lock (the exact failure #72's design forbids), and
# releasing it before the target emerge would leave the actual writes unguarded.
# FEATURES=binpkg-multi-instance — on the HOST config only, the design's stated
# alternative — makes concurrent writers safe: each build packs its own build-id
# instance and portage serializes the Packages-index update under its own index
# lock. The stamp file is still raced-guarded by the sa_lock_run stamp lock.
SA_HOST_BDEP_POOL_KEY="host-amd64-bdep"

# sa_host_bdep_pool_dir <root> -> <root>/pkgdir/host-amd64-bdep ('' when sharing off)
sa_host_bdep_pool_dir() {
    [ -n "${1:-}" ] || { printf ''; return 1; }
    sa_pool_dir "$1" "${SA_HOST_BDEP_POOL_KEY}"
}

# sa_host_profile [configroot] -> the HOST's resolved profile path ('' if none).
# This is the profile component of the host-leg fingerprint — the BUILDER's own
# /etc/portage/make.profile, NOT the spec-derived target PROFILE_PATH.
sa_host_profile() {
    readlink -f "${1:-/etc/portage}/make.profile" 2>/dev/null || printf ''
}

# sa_host_bdep_pool_salt -> the builder-identity salt for the host-leg fingerprint.
# #72's design keys the leg on the builder-image digest so a rebuilt/upgraded
# builder flushes the leg instead of mixing gcc/libc ABIs. The image digest is not
# observable from inside a container, so the operator/CI channel for the exact
# digest is HUGMESH_HOST_BDEP_SALT (set it on EVERY launch channel or on none —
# mixed spellings flush the leg on every alternation). The default derives the
# identity from the ABI carriers themselves — the HOST gcc and glibc versions —
# which is precisely what an image rebuild changes when it matters, and does NOT
# change on a rebuild that keeps the toolchain (no spurious flush).
sa_host_bdep_pool_salt() {
    if [ -n "${HUGMESH_HOST_BDEP_SALT:-}" ]; then
        printf '%s' "${HUGMESH_HOST_BDEP_SALT}"
        return 0
    fi
    local gccv glibcv
    gccv="$( { gcc -dumpfullversion 2>/dev/null || gcc -dumpversion 2>/dev/null; } | head -1)"
    glibcv="$(ldd --version 2>/dev/null | head -1)"
    printf 'builder-toolchain:gcc=%s:glibc=%s' "${gccv:-unknown}" "${glibcv:-unknown}"
}

# _sa_host_bdep_flush_restamp <pool> <makeconf> <profile> <salt> — empty the leg
# (stale-ABI host binpkgs AND the old stamp) and restamp it with this build's
# fingerprint. Runs UNDER the stamp lock (caller wraps in sa_lock_run).
_sa_host_bdep_flush_restamp() {
    local pool="${1:?}"
    find "${pool}" -mindepth 1 -delete 2>/dev/null || return 1
    pool_fingerprint_preflight "${pool}" "${2:-}" "${3:-}" "${4:-}"
}

# sa_host_bdep_pool_guard <pool> <host-makeconf> <profile> <salt> — the same
# pool_fingerprint_preflight (so the #44-style stamp MIGRATION mechanics apply
# unchanged: an empty→non-empty profile respelling of an ABI-identical leg is
# restamped loudly, exactly once), but with FLUSH-on-mismatch semantics instead
# of refuse-on-mismatch: a stale HOST tool is a build-time hazard on the builder
# itself, not a shipped-image SIGILL, and a mismatch here means "the builder
# identity changed" — the old binpkgs are garbage by definition, so the leg is
# emptied and restamped (loudly) rather than bricking every arm build until an
# operator hand-flushes a shared directory.
sa_host_bdep_pool_guard() {
    local pool="${1%/}" mc="${2:-}" prof="${3:-}" salt="${4:-}" out
    command -v pool_fingerprint_preflight >/dev/null 2>&1 || {
        sa_err "pool_fingerprint_preflight not sourced — refusing to touch the host bdep pool"
        return 1
    }
    [ -n "${pool}" ] || { sa_err "sa_host_bdep_pool_guard: no pool dir"; return 1; }
    mkdir -p "${pool}" 2>/dev/null || { sa_err "cannot create host bdep pool ${pool}"; return 1; }
    out="$(mktemp)" || return 1
    if sa_lock_run "${pool}.stamp.lock" pool_fingerprint_preflight "${pool}" "${mc}" "${prof}" "${salt}" 2>"${out}"; then
        cat "${out}" >&2         # surface MIGRATING / unstamped-adoption notices unchanged
        rm -f "${out}"
        return 0
    fi
    {
        echo "[shared-assets] NOTICE: FLUSHING the host-side bdep binpkg pool ${pool}"
        echo "  Its stamp no longer matches this builder's host identity (rebuilt/upgraded"
        echo "  builder image, changed host profile, or changed host make.conf flags)."
        echo "  Host bdeps are amd64 tools EXECUTED BY THE BUILDER — stale ones must not be"
        echo "  mixed across gcc/libc ABIs, but unlike a target pool this is not a"
        echo "  shipped-image SIGILL hazard, so the leg is emptied and restamped instead of"
        echo "  refusing the build. Preflight said:"
        sed 's/^/    | /' "${out}"
    } >&2
    rm -f "${out}"
    sa_lock_run "${pool}.stamp.lock" _sa_host_bdep_flush_restamp "${pool}" "${mc}" "${prof}" "${salt}" \
        || { sa_err "could not flush/restamp the host bdep pool ${pool}"; return 1; }
    return 0
}

# sa_host_bdep_pool_wire <pool> <host-makeconf> [profile] [salt] — guard the leg
# (flush-on-mismatch, above) and wire the HOST make.conf at it, idempotently and
# VALUE-AWARE: the check is "is the LAST PKGDIR assignment already this leg?",
# not a marker grep — a container reused with a DIFFERENT shared root must get a
# fresh block, and make.conf is last-assignment-wins, so appending again IS the
# correct update. profile/salt default to the real host's (sa_host_profile /
# sa_host_bdep_pool_salt); tests inject fixtures.
# Returns non-zero (leg unusable — caller builds unpooled) without ever having
# wired a make.conf at an unguarded pool.
sa_host_bdep_pool_wire() {
    local pool="${1%/}" mc="${2:-/etc/portage/make.conf}" prof salt
    prof="${3-$(sa_host_profile)}"
    salt="${4-$(sa_host_bdep_pool_salt)}"
    [ -n "${pool}" ] || { sa_err "sa_host_bdep_pool_wire: no pool dir"; return 1; }
    [ -f "${mc}" ]   || { sa_err "sa_host_bdep_pool_wire: host make.conf missing: ${mc}"; return 1; }
    sa_host_bdep_pool_guard "${pool}" "${mc}" "${prof}" "${salt}" || return 1
    if [ "$(_bpl_mc_get PKGDIR "${mc}")" != "${pool}" ]; then
        {
            printf '\n# hugmesh-host-bdep-pool: host-side BDEPEND binpkg pool (ARM cross builds).\n'
            printf '# BDEPENDs merge "to /" (--root-deps=rdeps): amd64 tools run by THIS builder,\n'
            printf '# so one pool serves every arm board. HOST make.conf ONLY — the target\n'
            printf '# make.conf keeps its own per-board PKGDIR (SIGILL isolation). buildpkg packs\n'
            printf '# every host bdep; binpkg-multi-instance keeps concurrent arm builds safe\n'
            printf '# (portage serializes the Packages index under its own lock).\n'
            printf 'PKGDIR="%s"\n' "${pool}"
            printf 'FEATURES="${FEATURES} buildpkg binpkg-multi-instance"\n'
        } >> "${mc}" || { sa_err "cannot wire ${mc} at the host bdep pool"; return 1; }
    fi
    return 0
}

# ── stage3 seed cache (G1) ────────────────────────────────────────────────────
# sa_seed_basename_matches_arch <arch> <basename> — the ARCH KEYING assertion.
# The directory already keys per-arch; this makes a MISFILED seed (an amd64 tarball
# dropped into seed/arm64/) unusable too, so a wrong-arch seed can never be unpacked.
sa_seed_basename_matches_arch() {
    local want base="${2:-}"
    want="$(sa_norm_arch "${1:-}")"
    [ -n "${want}" ] && [ -n "${base}" ] || return 1
    case "${base}" in
        stage3-"${want}"-*|*-"${want}"-*) return 0 ;;
    esac
    return 1
}

# The default fetcher — the same curl invocation (and retry hardening) the builders
# used inline before this library. Overridable via SA_FETCH_CMD (the hermetic tests
# inject a fixture copier; a build never reaches the network in the sandbox).
sa_fetch_default() { # <url> <dest>
    command -v curl >/dev/null 2>&1 || { sa_err "curl not found"; return 1; }
    curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 \
         --retry-connrefused --retry-all-errors -o "$2" "$1"
}

# _sa_fetch_into <url> <dest> — runs UNDER the seed lock. Re-checks presence (another
# build may have won the race while we waited), downloads to a .part sibling, then
# renames — so a killed download can never leave a truncated file that looks cached.
_sa_fetch_into() {
    local url="$1" dest="$2" part="$2.part.$$"
    if [ -f "${dest}" ]; then sa_info "seed appeared while waiting for the lock: ${dest}"; return 0; fi
    sa_info "downloading seed -> ${dest}"
    if ! "${SA_FETCH_CMD:-sa_fetch_default}" "${url}" "${part}"; then
        rm -f "${part}"
        sa_err "seed download failed: ${url}"
        return 1
    fi
    mv -f "${part}" "${dest}" || { rm -f "${part}"; sa_err "could not install ${dest}"; return 1; }
    return 0
}

# sa_seed_acquire <root> <arch> <basename> <url> <fallback_path>
#   Prints the path of a VERIFIED stage3 seed on stdout; returns non-zero (printing
#   nothing) when it cannot produce one.
#
#   <root> ""  → sharing off: the seed lives at <fallback_path> (legacy behaviour).
#   Otherwise  → <root>/seed/<arch>/<basename>, reused across every build of that arch.
#
#   Verification runs on EVERY call — cache hit or fresh download — via
#   "${SA_VERIFY_CMD:-dlv_verify_stage3}" <file> <url>.DIGESTS. That is the whole
#   supply-chain point: caching must not turn "verified once" into "trusted forever".
#   A file that fails is deleted, re-fetched ONCE, and re-verified; a second failure
#   fails closed.
sa_seed_acquire() {
    local root="${1:-}" arch="${2:-}" base="${3:-}" url="${4:-}" fallback="${5:-}"
    local verify="${SA_VERIFY_CMD:-dlv_verify_stage3}"
    local target="" seeddir=""

    case "${base}" in
        ""|*/*|.*) sa_err "refusing suspicious stage3 basename '${base}'"; return 1 ;;
    esac
    if ! sa_seed_basename_matches_arch "${arch}" "${base}"; then
        sa_err "stage3 seed '${base}' does not name arch '$(sa_norm_arch "${arch}")' —"
        sa_err "refusing it. A foreign-arch seed must never be unpacked (per-arch keying)."
        return 1
    fi

    if [ -n "${root}" ]; then
        if seeddir="$(sa_seed_dir "${root}" "${arch}")" && [ -n "${seeddir}" ] \
           && mkdir -p "${seeddir}" 2>/dev/null; then
            target="${seeddir}/${base}"
        else
            sa_warn "cannot use shared seed dir under ${root} — falling back to ${fallback}"
            target="${fallback}"
        fi
    else
        target="${fallback}"
    fi
    [ -n "${target}" ] || { sa_err "no seed destination"; return 1; }
    mkdir -p "$(dirname "${target}")" 2>/dev/null || true

    local attempt
    for attempt in 1 2; do
        if [ -f "${target}" ]; then
            sa_info "stage3 seed cache HIT: ${target} (re-verifying — a cache is never trusted)"
        else
            sa_lock_run "${target}.lock" _sa_fetch_into "${url}" "${target}" || return 1
        fi
        if "${verify}" "${target}" "${url}.DIGESTS"; then
            printf '%s\n' "${target}"
            return 0
        fi
        sa_err "stage3 seed FAILED verification: ${target}"
        sa_lock_run "${target}.lock" rm -f "${target}"
        if [ "${attempt}" = 1 ]; then
            sa_warn "discarded the unverified seed; re-fetching ONCE from ${url}"
        fi
    done
    sa_err "stage3 seed did not verify after a re-fetch — refusing to unpack an"
    sa_err "unverified tarball (fail-closed). A poisoned cache or mirror is the"
    sa_err "expected cause; inspect ${target%/*} before retrying."
    return 1
}

# ── summary line (so every channel's log states what is being reused) ─────────
# sa_describe <root> <arch> <pool> — one human line for the build banner / --print-plan.
sa_describe() {
    local root="${1:-}" arch="${2:-}" pool="${3:-}"
    if [ -z "${root}" ]; then
        printf 'shared build assets: DISABLED (private seed/distfiles/pkgdir under the build tree)'
        return 0
    fi
    printf 'shared build assets: root=%s seed=%s/seed/%s distfiles=%s/distfiles pkgdir=%s' \
        "${root}" "${root}" "$(sa_norm_arch "${arch}")" "${root}" "${pool:-<private>}"
}
