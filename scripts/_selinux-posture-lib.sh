#!/usr/bin/env bash
# _selinux-posture-lib.sh — SOURCED helper: whether an image carries SELinux,
# said the same way by every builder's summary and by publish-images.sh.
#
# Operator decision, 2026-11-12 (hugmesh-generator#1045, lane R2 = #1059):
# riscv64 images ship labelled "no SELinux". Gentoo ships no hardened or SELinux
# profile for riscv; the riscv64 builder uses the plain rv64/lp64d profile. Every
# other architecture keeps the hardened/selinux profile.
#
# The architecture list below is pinned to the device catalog's per-arch
# `selinux` flag (studio/hugmesh_studio/core/device-catalog.json) by
# tests/scripts/test-riscv64-no-selinux.sh, so the two can never disagree.
#
# Pure functions, no side effects, nothing read but the file named. Safe to
# source under `set -euo pipefail`.

# Architectures whose images carry no SELinux. Both spellings a builder uses
# for the same CPU match (the catalog id and the artifact-name token are both
# riscv64).
HUGMESH_NO_SELINUX_ARCHES="riscv64"

# The words every surface uses. Kept identical to device_catalog.NO_SELINUX.
HUGMESH_NO_SELINUX_TEXT="no SELinux"
HUGMESH_NO_SELINUX_WHY="Gentoo ships no hardened or SELinux profile for riscv"

# selinux_arch_has <arch> — 0 when images for <arch> carry SELinux, 1 when not.
# <arch> is a catalog arch id (x86-64, arm64, riscv64) or an artifact-name
# token (amd64, arm64, riscv64).
selinux_arch_has() {
    local arch a
    arch="${1:?selinux_arch_has: arch}"
    for a in ${HUGMESH_NO_SELINUX_ARCHES}; do
        [ "${arch}" = "${a}" ] && return 1
    done
    return 0
}

# selinux_arch_json <arch> — the JSON boolean publish-manifest.json records.
selinux_arch_json() {
    if selinux_arch_has "${1:?selinux_arch_json: arch}"; then
        printf 'true'
    else
        printf 'false'
    fi
}

# selinux_profile_has <parent-file> — 0 when the portage profile/parent file
# selects SELinux (a hardened/selinux profile or a features/selinux stack), 1
# when no line does. A missing file returns 2.
selinux_profile_has() {
    local f line
    f="${1:?selinux_profile_has: profile parent file}"
    [ -f "${f}" ] || return 2
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        case "${line}" in
            */selinux|*/selinux/|*/selinux[[:space:]]*) return 0 ;;
        esac
    done < "${f}"
    return 1
}

# selinux_summary_line <arch> <specs-dir> — the build summary's SELinux line.
# The words come from the profile the build actually selected
# (<specs-dir>/portage/profile/parent, the file every builder reads for
# make.profile). When the profile and the architecture's posture disagree, the
# line says so instead of claiming either. Always returns 0: a summary line
# must never abort a finished build (the static guard is what refuses drift).
selinux_summary_line() {
    local arch specs parent prof has
    arch="${1:?selinux_summary_line: arch}"
    specs="${2:?selinux_summary_line: specs dir}"
    parent="${specs}/portage/profile/parent"
    prof=""
    if [ -f "${parent}" ]; then
        prof="$(sed -e 's/#.*//' -e 's/^gentoo://' "${parent}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')" || prof=""
    fi
    has=0
    selinux_profile_has "${parent}" || has=$?
    if [ "${has}" -eq 2 ]; then
        echo "  SELinux:          UNKNOWN — ${parent} is missing"
    elif selinux_arch_has "${arch}"; then
        if [ "${has}" -eq 0 ]; then
            echo "  SELinux:          yes — hardened/selinux profile (${prof})"
        else
            echo "  SELinux:          MISSING — ${arch} images must carry SELinux but the profile (${prof}) selects none"
        fi
    else
        if [ "${has}" -eq 0 ]; then
            echo "  SELinux:          WRONG — ${arch} ships ${HUGMESH_NO_SELINUX_TEXT}, yet the profile (${prof}) selects SELinux"
        else
            echo "  SELinux:          ${HUGMESH_NO_SELINUX_TEXT} — ${arch} ships without it (${HUGMESH_NO_SELINUX_WHY}); profile ${prof}"
        fi
    fi
    return 0
}
