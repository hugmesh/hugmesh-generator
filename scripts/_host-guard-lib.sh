#!/usr/bin/env bash
# _host-guard-lib.sh — SOURCED helper: never mutate the operator's real system.
#
# WHY THIS EXISTS
# Every ARM builder (frite/rpi5/orangepi5/orangepi-zero2/orangepi-zero2w/
# orangepi-zero3/orangepi3-lts/orangepi4-lts/jetson)
# seeds HOST
# /etc/portage files and runs a HOST `emerge`, and _dracut-cross-lib.sh registers
# a KERNEL-GLOBAL binfmt_misc interpreter. All of that is correct and REQUIRED
# inside the ephemeral builder container — it is why the fleet builds work at all
# (#360/#366/#373/#380). None of it is acceptable on a real machine: the seed
# writes `*/* PYTHON_TARGETS: python3_12 python3_13`, a WILDCARD, system-wide
# python-target change, and the emerge installs/rebuilds packages on a live root.
#
# Until 2026-07-17 the only guard was `[ "$(id -u)" -eq 0 ] && [ -d /etc/portage ]`
# — no container check anywhere. It never fired only by accident: build_driver.py's
# preflight() unconditionally BLOCKED every native build, an accidental shield.
# PR #382 fixed that blocker, so the next native ARM build would have dispatched
# and reconfigured the operator's desktop. This library is that missing check.
#
# THE CONTRACT (fail SAFE): the container predicate is a WHITELIST of positive
# proofs whose fallthrough is `return 1`. Every unknown runtime — a bare chroot,
# an unrecognised sandbox, a future container engine, a stripped image — lands on
# "this is a host" and mutates NOTHING. The only failure mode is a false NEGATIVE
# inside some exotic container, which costs a fail-fast error carrying a
# copy-pasteable emerge line. The inverse (a false POSITIVE on a live desktop) is
# the bug being fixed here and cannot be allowed, so every accepted signal is
# either container-runtime-created or baked into our own image — none is settable
# by an unprivileged caller of the builder script.
#
# WHY /.dockerenv IS LOAD-BEARING (measured, not assumed). Probed inside the
# operator's existing hugmesh-builder:latest — an image that PREDATES this
# library, which must keep building the fleet with no rebuild:
#     /.dockerenv                       -> PRESENT
#     /run/.containerenv                -> absent
#     /etc/hugmesh-builder-container -> absent (image predates this PR)
#     $container / $HUGMESH_BUILDER  -> unset
# /.dockerenv is the ONLY signal a stale image already carries, and the Docker
# DAEMON creates it in every container — it is not baked into the image, so it
# cannot go stale. That is what keeps today's fleet builds working unchanged.
#
# REJECTED SIGNAL — `grep -q docker /proc/1/cgroup`, the classic heuristic.
# Mutation-proven dead: measured inside hugmesh-builder:latest,
# `head -1 /proc/1/cgroup` returns `0::/` (cgroup v2 unified) — no "docker"
# substring. Relying on it would have declared the FLEET CONTAINER a host and
# bricked every build. Do not add it back.
#
# REJECTED SIGNAL — an ENV var as authorization, INCLUDING the systemd/OCI
# `container=docker|podman|lxc|...` convention. An env var is forgeable by any
# caller and, worse, is STRIPPED by sudo/pkexec — the exact path the Studio's
# native build takes (build_driver.py _elevation_prefix). It would fail OPEN on a
# host that happens to export it and fail CLOSED under the Studio's own
# elevation. The baked marker is therefore a FILE, not an ENV.
# This library shipped with a `container=` arm in review and it was cut: it made
# the audited claim above FALSE, and was mutation-proven to write the `*/*
# PYTHON_TARGETS` wildcard on a marker-less root with `container=docker` exported
# and NO warning — while the deliberate hatch below grants the same power noisily.
# Nothing is lost: the file markers cover docker/podman/buildah, and a bare
# chroot/nspawn runner has HUGMESH_ASSUME_CONTAINER=1, which warns.
#
# Following scripts/_dracut-cross-lib.sh's precedent, this file is meant to be
# SOURCED, never executed:
#     source "$(dirname "${BASH_SOURCE[0]}")/_host-guard-lib.sh"
# It does NOT set shell options — the sourcing script owns `set -euo pipefail`.
# It defines functions + constants only (no top-level side effects beyond the
# double-source guard below), so sourcing it is safe and idempotent.
#
# Public API:
#   hostguard_in_container      — predicate: are we PROVABLY in a container?
#   hostguard_container_reason  — echo which marker fired (honest logging)
#   hostguard_mutation_allowed  — predicate: may we mutate THIS root? (+override)
#   hostguard_require_host_portage — READ-ONLY: does the host already satisfy the
#                                    portage config the build needs? Never writes.
#   hostguard_require_host_tools   — host-tool preflight; fail fast natively.
#   hostguard_ensure_cross_gpep517 — HOST gpep517 floor for cross-built python
#                                    C extensions (upgraded in the container;
#                                    exact commands + return 1 on a real host).

# shellcheck disable=SC2317
if [ -n "${_HOST_GUARD_LIB_SOURCED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_HOST_GUARD_LIB_SOURCED=1

# ── Pinned constants (ONE audited copy) ────────────────────────────
# The marker Dockerfile.build's FINAL stage bakes. Redundant with /.dockerenv
# under Docker; it earns its keep under podman-with-a-scrubbed-/run and makes the
# container's self-identification greppable/auditable by the sync test.
HOSTGUARD_MARKER_FILE="/etc/hugmesh-builder-container"
HOSTGUARD_DOCKER_MARKER="/.dockerenv"
HOSTGUARD_PODMAN_MARKER="/run/.containerenv"

# ── Logging (self-contained; colour only on a TTY) ─────────────────
# Kept independent of the sourcing script's info/warn/err so the library is safe
# to source before those are defined.
if [ -t 2 ]; then
    _HG_YEL=$'\033[33m'; _HG_GRN=$'\033[32m'; _HG_RED=$'\033[31m'; _HG_RST=$'\033[0m'
else
    _HG_YEL=''; _HG_GRN=''; _HG_RED=''; _HG_RST=''
fi
_hg_warn() { printf '%s[host-guard] WARN:%s %s\n'  "${_HG_YEL}" "${_HG_RST}" "$*" >&2; }
_hg_info() { printf '%s[host-guard]%s %s\n'        "${_HG_GRN}" "${_HG_RST}" "$*" >&2; }
_hg_err()  { printf '%s[host-guard] ERROR:%s %s\n' "${_HG_RED}" "${_HG_RST}" "$*" >&2; }

# hostguard_in_container — predicate: 0 iff we can PROVE this root is disposable.
# Whitelist of positive proofs; the fallthrough is "treat as HOST". Produces no
# output. NEVER consults HUGMESH_ASSUME_CONTAINER (see
# hostguard_mutation_allowed) — this answers "what am I?", not "what may I do?".
hostguard_in_container() {
    # Docker: the daemon creates this in EVERY container. The one signal the
    # operator's existing (stale) builder image already carries.
    [ -e "${HOSTGUARD_DOCKER_MARKER}" ] && return 0
    # Podman/Buildah: runtime-created, same role as /.dockerenv.
    [ -e "${HOSTGUARD_PODMAN_MARKER}" ] && return 0
    # Our own baked marker (fresh images; podman with a scrubbed /run).
    [ -e "${HOSTGUARD_MARKER_FILE}" ] && return 0
    # NO ENV VAR ARM HERE — deliberately. The systemd/OCI `container=` convention
    # looks tempting, but an env var is FORGEABLE by any caller, so honouring it
    # would let `container=docker` alone authorize the wildcard write on a real
    # desktop — the exact bug this library exists to close. Docker/podman/buildah
    # are already covered by the two runtime-CREATED file markers above; a bare
    # chroot/nspawn CI runner uses the documented, WARNING escape hatch
    # (HUGMESH_ASSUME_CONTAINER=1 in hostguard_mutation_allowed) instead, which
    # grants the same power but says so out loud. If nspawn/lxc detection is ever
    # genuinely wanted, corroborate it with a runtime-CREATED FILE (nspawn writes
    # /run/systemd/container) and route it through that warning path — never let an
    # env var alone reach a host emerge. A guard test pins this arm out.
    return 1
}

# hostguard_container_reason — echo the marker that proved containment (or
# "unproven"). For honest logging only; never a decision input.
hostguard_container_reason() {
    if   [ -e "${HOSTGUARD_DOCKER_MARKER}" ]; then printf '%s (docker daemon)\n' "${HOSTGUARD_DOCKER_MARKER}"
    elif [ -e "${HOSTGUARD_PODMAN_MARKER}" ]; then printf '%s (podman)\n'        "${HOSTGUARD_PODMAN_MARKER}"
    elif [ -e "${HOSTGUARD_MARKER_FILE}" ];   then printf '%s (baked builder marker)\n' "${HOSTGUARD_MARKER_FILE}"
    else printf 'unproven\n'
    fi
}

# hostguard_mutation_allowed — predicate: may this root be mutated (host
# /etc/portage writes, host emerge, kernel-global binfmt registration)?
#
# The ESCAPE HATCH lives here and ONLY here, deliberately noisy and separately
# named: a CI runner in a bare chroot/nspawn needs a documented way in, but a
# silent, env-forgeable path into `emerge` on a live desktop is exactly the bug
# this library exists to fix. Off by default; warns on EVERY use.
hostguard_mutation_allowed() {
    if hostguard_in_container; then
        return 0
    fi
    if [ "${HUGMESH_ASSUME_CONTAINER:-}" = "1" ]; then
        _hg_warn "HUGMESH_ASSUME_CONTAINER=1 — operator override: treating this root as disposable. Host /etc/portage and installed packages MAY BE MODIFIED."
        return 0
    fi
    return 1
}

# ── READ-ONLY host portage inspection ──────────────────────────────
# _hg_live_lines <path> — print the non-comment, non-blank lines of a portage
# config location, which may be a FILE or a DIRECTORY (portage accepts both).
# Read-only; silent and empty when the path does not exist.
_hg_live_lines() {
    local p="$1"
    [ -e "${p}" ] || return 0
    if [ -d "${p}" ]; then
        find "${p}" -type f -exec cat {} + 2>/dev/null
    else
        cat "${p}" 2>/dev/null
    fi | sed -e 's/#.*$//' -e '/^[[:space:]]*$/d'
}

# _hg_atom_listed <path> <atom> — 0 iff a LIVE line at <path> names <atom>.
# Anchored at the start of the line (portage atoms lead their line, modulo
# leading whitespace and an optional version operator/prefix) so a commented-out
# or merely-mentioned atom never counts as satisfied.
# NOTE: `/` is NOT an ERE metacharacter — escaping it emits "grep: warning:
# stray \ before /" on GNU grep and is meaningless elsewhere. The atoms here are
# fixed literals from this file, so only `.` needs quoting; the category/name
# form (dev-python/setuptools-scm) contains no other metacharacter.
_hg_atom_listed() {
    local p="$1" atom="$2"
    _hg_live_lines "${p}" | grep -E "^[[:space:]]*[<>=~!]*${atom//./\\.}(-[0-9][^[:space:]]*)?([[:space:]]|$)" >/dev/null
}

# _hg_use_listed <path> <atom> <flag> — 0 iff a LIVE line at <path> names <atom>
# and carries <flag> (not negated).
_hg_use_listed() {
    local p="$1" atom="$2" flag="$3"
    _hg_live_lines "${p}" | grep -E "^[[:space:]]*[<>=~!]*${atom//./\\.}(-[0-9][^[:space:]]*)?[[:space:]]" \
        | grep -E "[[:space:]]${flag}([[:space:]]|$)" >/dev/null
}

# hostguard_require_host_portage — READ-ONLY verification that the HOST already
# carries the portage configuration the cross build needs. Writes NOTHING, ever.
# Returns 0 (host already satisfies it -> proceed) or 1 after printing the exact
# per-atom shortfall plus a copy-pasteable block the operator can review and run
# THEMSELVES. There is deliberately no --yes-mutate-my-host flag.
#
# THE ASYMMETRY THAT MATTERS MOST: the container seed writes
# `*/* PYTHON_TARGETS: python3_12 python3_13`. That is correct in a throwaway
# container and is a system-wide reconfiguration of a real desktop. So the native
# branch does NOT grep for the wildcard and MUST NEVER print it as advice — it
# probes the host's EFFECTIVE PYTHON_TARGETS read-only via `portageq` instead,
# and advises a PER-PACKAGE fix.
hostguard_require_host_portage() {
    local kw_dir="/etc/portage/package.accept_keywords"
    local use_dir="/etc/portage/package.use"
    local -a miss_kw=() miss_use=()
    local atom

    # keywords — the host-side build-backend chain + the SELinux 3.11 window.
    for atom in dev-python/vcs-versioning dev-python/setuptools-scm \
                sys-libs/libsepol sys-libs/libselinux sys-libs/libsemanage \
                sys-apps/policycoreutils; do
        _hg_atom_listed "${kw_dir}" "${atom}" || miss_kw+=("${atom}")
    done

    # USE — the python-bindings halves the host policy tools need, and pam[audit].
    _hg_use_listed "${use_dir}" sys-libs/libselinux python || miss_use+=("sys-libs/libselinux python")
    _hg_use_listed "${use_dir}" sys-process/audit  python  || miss_use+=("sys-process/audit python")
    _hg_use_listed "${use_dir}" sys-libs/pam       audit   || miss_use+=("sys-libs/pam audit")

    # PYTHON_TARGETS — probe the EFFECTIVE value read-only; never grep for, and
    # never advise, the `*/*` wildcard.
    local pt="" pt_ok=1
    if command -v portageq >/dev/null 2>&1; then
        pt="$(portageq envvar PYTHON_TARGETS 2>/dev/null || true)"
        case " ${pt} " in *" python3_12 "*) pt_ok=0 ;; esac
    else
        # No portageq -> cannot prove the target is enabled. Fail safe: report it.
        pt_ok=1
    fi

    if [ "${#miss_kw[@]}" -eq 0 ] && [ "${#miss_use[@]}" -eq 0 ] && [ "${pt_ok}" -eq 0 ]; then
        _hg_info "HOST portage config already satisfies the cross build (keywords + USE + PYTHON_TARGETS) — nothing to seed."
        return 0
    fi

    _hg_err "This build needs HOST portage config that your system does not have yet."
    _hg_err "It would change YOUR system, so this build will NOT write it. Review and apply it yourself:"
    if [ "${#miss_kw[@]}" -ne 0 ]; then
        _hg_err ""
        _hg_err "  MISSING ~amd64/** keywords: ${miss_kw[*]}"
        _hg_err "  sudo mkdir -p ${kw_dir} && sudo tee ${kw_dir}/hugmesh-host-build-backends <<'EOF'"
        _hg_err "  dev-python/vcs-versioning **"
        _hg_err "  dev-python/setuptools-scm **"
        _hg_err "  sys-libs/libsepol ~amd64"
        _hg_err "  sys-libs/libselinux ~amd64"
        _hg_err "  sys-libs/libsemanage ~amd64"
        _hg_err "  sys-apps/policycoreutils ~amd64"
        _hg_err "  EOF"
    fi
    if [ "${#miss_use[@]}" -ne 0 ]; then
        _hg_err ""
        _hg_err "  MISSING USE flags: ${miss_use[*]}"
        _hg_err "  sudo mkdir -p ${use_dir} && sudo tee ${use_dir}/hugmesh-host-build-backends <<'EOF'"
        _hg_err "  sys-libs/libselinux python"
        _hg_err "  sys-process/audit python"
        _hg_err "  sys-libs/pam audit"
        _hg_err "  EOF"
    fi
    if [ "${pt_ok}" -ne 0 ]; then
        _hg_err ""
        if [ -n "${pt}" ]; then
            _hg_err "  Your PYTHON_TARGETS (${pt}) lacks python3_12, which the host-side build-backend"
        else
            _hg_err "  Your PYTHON_TARGETS could not be read (portageq unavailable); python3_12 is required by the host-side build-backend"
        fi
        _hg_err "  chain (setuptools-scm/vcs-versioning) needs. Set it PER-PACKAGE for that chain."
        _hg_err "  Do NOT apply a '*/*' PYTHON_TARGETS wildcard to a live system — the build"
        _hg_err "  container does that only because it is thrown away afterwards."
    fi
    _hg_err ""
    _hg_err "  Or (RECOMMENDED) build in the container instead, which touches nothing on this host:"
    _hg_err "      make docker-image && make <target>"
    return 1
}

# ── HOST tool preflight ────────────────────────────────────────────
# hostguard_require_host_tools <artifact-label> <emerge-atoms> [--hint <text>] [--soft] -- <tool> [tool...]
#
# Each <tool> may be an alternatives group written `a|b` (satisfied if EITHER
# resolves) — e.g. `mksquashfs|tar2sqfs`.
#
# <emerge-atoms> is interpolated straight into `emerge ${atoms}`, so it must be
# ARGV ONLY — bare atoms separated by spaces. Prose belongs in --hint. (Shipped in
# review as `"sys-fs/squashfs-tools   (or ...-ng for tar2sqfs)"`, which emitted a
# "copy-pasteable" line that was a bash syntax error on paste.)
#
# --soft: for sites with a genuine, SUPPORTED fallback — never exit; report and
# let the caller degrade. Use it ONLY where the fallback is a real deliverable the
# build already reports (x86 --installer-iso leaves an installable TREE, which
# main reports as `INSTALLER_ISO_PATH=... (tree; no xorriso to wrap an ISO)`).
# Without --soft the native branch EXITS, which is right where the artifact is
# genuinely lost (.img, --live-iso) and WRONG where a supported outcome exists —
# converting a build that previously SUCCEEDED into exit 1.
#
# Returns 0            — every tool resolved; proceed silently.
# Returns 1            — a tool is missing AND (we are in a container OR --soft):
#                        the caller keeps TODAY'S behavior (warn + disable/degrade),
#                        so a stale image can never be broken by this guard. Gating
#                        the HARD failure on containment is deliberate and keeps the
#                        blast radius at zero: every tool below was measured
#                        PRESENT in hugmesh-builder:latest, so the native
#                        branch is unreachable during fleet builds.
# Exits 1              — a tool is missing on a real host and the artifact would be
#                        LOST: name the artifact, the missing tools and the
#                        copy-pasteable emerge, then stop BEFORE the long work
#                        rather than warn-and-silently-drop a requested artifact
#                        hours later.
hostguard_require_host_tools() {
    local label="$1" atoms="$2"; shift 2
    local hint="" soft=0
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        case "$1" in
            --hint) hint="$2"; shift 2 ;;
            --soft) soft=1; shift ;;
            *) shift ;;
        esac
    done
    [ "${1:-}" = "--" ] && shift

    local -a missing=()
    local group alt found
    for group in "$@"; do
        found=1
        local IFS='|'
        for alt in ${group}; do
            if command -v "${alt}" >/dev/null 2>&1; then found=0; break; fi
        done
        unset IFS
        [ "${found}" -eq 0 ] || missing+=("${group}")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    # Container: preserve today's exact behavior (caller warns + disables).
    hostguard_in_container && return 1

    local m pretty=()
    for m in "${missing[@]}"; do pretty+=("${m//|/ or }"); done

    # Soft site: a supported fallback exists, so say what is missing and how to get
    # it, then hand back to the caller to degrade. NEVER exit — a build that works
    # today must not start failing because we learned to name its missing tool.
    if [ "${soft}" -eq 1 ]; then
        _hg_warn "${label}: not installed on the BUILD HOST: ${pretty[*]} — continuing with the documented fallback."
        _hg_warn "For the full artifact, install on the BUILD host: emerge ${atoms}"
        [ -n "${hint}" ] && _hg_warn "${hint}"
        return 1
    fi

    _hg_err "${label} needs these tools on the BUILD HOST, and they are not installed: ${pretty[*]}"
    _hg_err "Install on the BUILD host: emerge ${atoms}"
    [ -n "${hint}" ] && _hg_err "${hint}"
    _hg_err "Or build in the container instead, which touches nothing on this host: make docker-image"
    exit 1
}

# ── HOST gpep517 floor for cross-built python C extensions ─────────
# hostguard_ensure_cross_gpep517 [portage-etc-dir]
#
# WHY: in an ARM cross build portage's distutils-r1 eclass builds every python
# wheel with the HOST interpreter and the HOST gpep517, passing
# `--sysroot ${SYSROOT}` (cross_emerge sets SYSROOT). Under --sysroot, gpep517
# before 23 swaps sysconfig.get_config_vars for a function that takes NO
# arguments; setuptools-84's bundled distutils calls get_config_vars(*names)
# while it sets up the C compiler. Every python C extension then dies with
#     TypeError: patch_sysconfig.<locals>.patched_config_vars() takes
#     0 positional arguments but 9 were given
# which portage reports only as "Wheel build failed". In the 2026-09-24
# builder image gpep517-20 is the only amd64-stable version and setuptools-84
# is stable, so sys-libs/libselinux (python USE is profile-forced on
# hardened/selinux) and dev-python/pypax fail in @system, and everything that
# needs them is skipped: every ARM board, every role (rpi5 run 2026-10-21,
# 37 libselinux attempts). Pure-python packages never reach build_ext, which
# is why most python packages still cross-built fine in the same run.
# gpep517-23 made the replacement `patched_config_vars(*args)`. 22 is NOT
# enough: replayed against the failed sysroot, gpep517-22 fails identically.
#
# x86 is not affected and must not call this: its emerges run inside
# `chroot ${SYSROOT}`, where gpep517 is the sysroot's own copy.
#
# Container (hostguard_mutation_allowed + root): accept ~amd64 for the floor
# atom in a dedicated file and emerge it (pure python, one ~31 KiB source
# tarball; reuses the host-bdep binpkg pool when the builder wired one), then
# re-check. Real host: write nothing, print the exact commands, return 1.
# Returns 0 when the floor is met. The argument exists only so a test can
# point the keyword write at a scratch dir; builders call it with none.
HOSTGUARD_GPEP517_FLOOR='>=dev-python/gpep517-23'
HOSTGUARD_GPEP517_KW_FILE='hugmesh-host-gpep517'

_hg_host_portage() {
    # The floor is about the BUILD HOST's root, never the sysroot: drop any
    # cross-root variables a caller might have exported.
    env -u ROOT -u SYSROOT -u PORTAGE_CONFIGROOT -u EROOT -u ESYSROOT -u BROOT "$@"
}

hostguard_ensure_cross_gpep517() {
    local etc="${1:-/etc/portage}"
    local floor="${HOSTGUARD_GPEP517_FLOOR}"
    local kw_dir="${etc}/package.accept_keywords"
    local kw_file="${kw_dir}/${HOSTGUARD_GPEP517_KW_FILE}"

    if ! command -v portageq >/dev/null 2>&1; then
        _hg_err "portageq not found: cannot check the HOST gpep517 version that every cross-built python C extension needs (${floor})."
        return 1
    fi
    if _hg_host_portage portageq has_version / "${floor}" >/dev/null 2>&1; then
        return 0
    fi

    if hostguard_mutation_allowed && [ "$(id -u)" -eq 0 ] && command -v emerge >/dev/null 2>&1; then
        _hg_info "HOST gpep517 is older than 23: cross-built python C extensions (libselinux, pypax, libsemanage, setools) would fail with 'Wheel build failed'. Installing ${floor} in this builder container."
        mkdir -p "${kw_dir}" || return 1
        {
            printf '%s\n' "# Auto-written by the ARM stage4 builder (_host-guard-lib.sh hostguard_ensure_cross_gpep517)."
            printf '%s\n' "# gpep517 < 23 breaks every cross-built python C extension with setuptools >= 84."
            printf '%s\n' "${floor} ~amd64"
        } > "${kw_file}" || return 1
        if ! _hg_host_portage emerge --oneshot --quiet --usepkg=y --binpkg-respect-use=y "${floor}"; then
            _hg_err "Failed to install HOST ${floor}. Without it every cross-built python C extension fails (Wheel build failed)."
            return 1
        fi
        if ! _hg_host_portage portageq has_version / "${floor}" >/dev/null 2>&1; then
            _hg_err "emerge returned success but HOST gpep517 is still older than 23; refusing to start a cross build that would fail at @system."
            return 1
        fi
        _hg_info "HOST gpep517 now satisfies ${floor}."
        return 0
    fi

    _hg_err "HOST gpep517 is older than 23. Every cross-built python C extension (libselinux, pypax, libsemanage, setools) would fail with 'Wheel build failed' at @system."
    _hg_err "This build will NOT change your system. Review and run on the BUILD host yourself:"
    _hg_err "  sudo mkdir -p ${kw_dir}"
    _hg_err "  echo '${floor} ~amd64' | sudo tee ${kw_file}"
    _hg_err "  sudo emerge --oneshot '${floor}'"
    _hg_err "Or build in the container instead, which touches nothing on this host:"
    _hg_err "      make docker-image && make <target>"
    return 1
}
