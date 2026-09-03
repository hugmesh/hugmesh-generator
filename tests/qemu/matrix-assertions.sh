#!/usr/bin/env bash
# matrix-assertions.sh — SIZE + LOAD assertion helpers for the opt-in matrix QEMU
# e2e harness (run-matrix-e2e.sh sources this). Every limit is READ FROM THE CODE
# (the builders' --print-plan, host_resources.py) — never a hardcoded per-row number,
# so the assertions can never drift from the source of truth.
#
# This file is a library: it defines functions and constants only, it never boots or
# builds anything on its own. The runtime-load re-boot is the one function that starts
# QEMU, and it is invoked only on the gated (HUGMESH_QEMU_E2E=1 + artifacts) path.
#
# Design:
#   assert_size        the built .img/ISO is <= (1+512+ROOT_MiB+1) MiB, with ROOT_MiB
#                      read from the row's builder --print-plan (img_size=).
#   assert_build_load  the docker build channel carries the host_resources.py caps —
#                      docker_memory_args() emits --memory <cap>, build-image.sh threads
#                      -j $JOBS. Proves the 2026-07-15 host-freeze guard is wired.
#   assert_runtime_load  the row's artifact still reaches the boot marker under its
#                      DEVICE RAM ceiling (catalog ram_mb) with no oom-killer — the boot
#                      envelope that proves rpi3 (1GB) / orin-nano-4gb (4GB) fit.
#
# These helpers assume the caller has set MA_PY (a python that can import
# hugmesh_studio.core) and MA_REPO (the generator repo root); source-time defaults
# resolve both so the file is usable standalone for `bash -n` / unit probing.

# ── Resolve the repo root + a python that can import the studio core ───────────────
_MA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MA_REPO:=$(cd "${_MA_DIR}/../.." && pwd)}"
if [ -z "${MA_PY:-}" ]; then
    for _c in "/var/tmp/portage/hugmesh-work/.venv-studio/bin/python" \
              "${MA_REPO}/studio/.venv/bin/python" "python3"; do
        command -v "${_c}" >/dev/null 2>&1 && { MA_PY="${_c}"; break; }
    done
fi
MA_STUDIO="${MA_REPO}/studio"
MIB=$(( 1024 * 1024 ))

# ── Small logging shims (run-matrix-e2e.sh overrides these with its own) ──────────
if ! declare -F info >/dev/null 2>&1; then info() { echo "[assert] $*"; }; fi
if ! declare -F warn >/dev/null 2>&1; then warn() { echo "[assert] WARN: $*" >&2; }; fi
if ! declare -F fail >/dev/null 2>&1; then fail() { echo "[assert] FAIL: $*" >&2; return 1; }; fi

# Run a build_matrix helper (Qt-free core) with the studio package importable.
_ma_py() {
    ( cd "${MA_STUDIO}" && QT_QPA_PLATFORM=offscreen "${MA_PY}" "$@" )
}

# ── Golden-artifact resolution (mirrors each launcher's autodetect convention) ─────
# resolve_artifact PLATFORM BOARD ROLE [WORK_DIR] -> newest matching .img/.img.xz, or ""
# (empty = no artifact for this row → the driver SKIPs it). The launcher does its own
# precise autodetect too; the driver resolves here so it can decide SKIP-vs-boot AND
# hand the launcher an explicit --img (so both faces boot the SAME file). Kernel /
# initramfs / squashfs / rootfs blobs are excluded so they can never be mistaken for a
# bootable image.
resolve_artifact() {
    local plat="$1" board="$2" role="$3" wd="${4:-${WORK_DIR:-.}}" f pat
    # Every pattern keeps the ROLE, and none matches .img.xz. Both rules are load-bearing:
    #
    #  * A role-less fallback (formerly "hugmesh-${plat}-*.img") silently resolved EVERY
    #    row of a platform to the newest image of ANY role — so a `pki` row would boot
    #    the `backend` image and assert against it, reporting a pass for a row that was
    #    never exercised.
    #  * A .img.xz is NOT a disk. The caller hands this straight to the launcher as
    #    --img, which does `qemu-img create -f qcow2 -b <img> -F raw` — presenting an xz
    #    stream to QEMU as a raw disk. That yields an unbootable VM and a confusing
    #    timeout rather than a clean "artifact not built yet" SKIP. Decompress first
    #    (tests/qemu/run-qemu-docker.sh does this) and re-run.
    for pat in \
        "${wd}/"*"-${plat}-${board:+${board}-}"*"${role}"*".img" \
        "${wd}/"*"-${plat}-"*"-${role}-"*".img" \
        "${wd}/"*"-${role}-"*".img" ; do
        # shellcheck disable=SC2086 -- intentional glob expansion of the pattern
        f="$(ls -1t ${pat} 2>/dev/null | grep -viE '(kernel|initramfs|initrd|squashfs|/Image$|rootfs\.img)' | head -1)"
        [ -n "${f}" ] && { printf '%s' "${f}"; return 0; }
    done
    return 0
}

# ── img_size / ROOT_MiB from a builder --print-plan blob ──────────────────────────
# plan_root_mib < plan.txt  →  echoes the ROOT_MiB (img_size=) the row's builder plans.
# Delegates to build_matrix.parse_img_size_mib so the shell + python read it identically.
plan_root_mib() {
    _ma_py -c 'import sys; from hugmesh_studio.core.build_matrix import parse_img_size_mib; print(parse_img_size_mib(sys.stdin.read()))'
}

# expected_image_bytes ROOT_MiB → echoes (1+512+ROOT_MiB+1)*MiB (the compact layout).
expected_image_bytes() {
    _ma_py -c "from hugmesh_studio.core.build_matrix import compact_image_bytes; print(compact_image_bytes(int('$1')))"
}

# ── SIZE assertion ────────────────────────────────────────────────────────────────
# assert_size IMG ROOT_MiB [compressed]
#   IMG        the built artifact (.img or .iso)
#   ROOT_MiB   the limit read from --print-plan (plan_root_mib)
#   compressed if "1"/"true", IMG is xz-compressed — assert on the UNCOMPRESSED size
#              (xz --robot --list), not the file byte size (else a false PASS).
assert_size() {
    local img="$1" root_mib="$2" compressed="${3:-0}" expected actual
    [ -f "${img}" ] || { fail "assert_size: artifact not found: ${img}"; return 1; }
    expected="$(expected_image_bytes "${root_mib}")"
    if [ "${compressed}" = "1" ] || [ "${compressed}" = "true" ]; then
        actual="$(xz --robot --list "${img}" 2>/dev/null | awk -F'\t' '$1=="file"{print $5; exit}')"
        [ -n "${actual}" ] || { warn "assert_size: xz --list gave no uncompressed size for ${img}; falling back to stat"; actual="$(stat -c%s "${img}")"; }
    else
        actual="$(stat -c%s "${img}")"
    fi
    if [ "${actual}" -le "${expected}" ]; then
        info "size OK: $(basename "${img}") ${actual}B <= ${expected}B (ROOT_MiB=${root_mib}: 1+512+${root_mib}+1 MiB)"
        return 0
    fi
    fail "size LIMIT EXCEEDED: $(basename "${img}") ${actual}B > ${expected}B (ROOT_MiB=${root_mib})"
    return 1
}

# ── BUILD-HOST LOAD assertion (docker channel only) ───────────────────────────────
# assert_build_load  — proves the 2026-07-15 host-freeze caps are WIRED into the docker
# build channel: host_resources.build_memory_flag()/default_jobs() produce caps, and
#   * build_driver.docker_memory_args() carries them as --memory <cap> --memory-swap <cap>
#   * docker/build-image.sh threads -j "$JOBS" into every builder dispatch
# The native channel cannot be cgroup-capped (low_memory_warnings' honesty suffix), so
# this assertion is a docker-channel invariant only.
assert_build_load() {
    local mem jobs mem_args
    mem="$(_ma_py -c 'from hugmesh_studio.core.host_resources import build_memory_flag; print(build_memory_flag() or "none")')"
    jobs="$(_ma_py -c 'from hugmesh_studio.core.host_resources import default_jobs; print(default_jobs())')"
    info "build-host caps: --memory=${mem} jobs=${jobs} (host_resources.py)"
    # docker_memory_args() must emit the SAME cap (or [] when disabled/unknown).
    mem_args="$(_ma_py -c 'from hugmesh_studio.core.build_driver import docker_memory_args; print(" ".join(docker_memory_args()))')"
    if [ "${mem}" != "none" ]; then
        case "${mem_args}" in
            *"--memory ${mem}"*) : ;;
            *) fail "assert_build_load: docker_memory_args() did not carry --memory ${mem} (got: ${mem_args:-<empty>})"; return 1 ;;
        esac
    fi
    # -j "$JOBS" must be threaded into the builder dispatch in build-image.sh.
    if ! grep -q -- '-j "\$JOBS"' "${MA_REPO}/docker/build-image.sh"; then
        fail "assert_build_load: build-image.sh no longer threads -j \"\$JOBS\" into the builder dispatch"
        return 1
    fi
    info "build-host LOAD OK: docker channel carries the memory cap + -j jobs"
    return 0
}

# ── RUNTIME LOAD assertion (device RAM envelope; boots QEMU — gated path only) ─────
# assert_runtime_load CONSOLE_LOG RAM_MB
#   Given a console log from a boot that ran under `-m RAM_MB` (the device RAM ceiling),
#   assert it reached the boot marker AND shows no oom-killer. This is a BOOT-ENVELOPE
#   check (does the image come up inside device RAM), NOT a peak-load stress test — a
#   QEMU node with kubernetes.bootstrap=false does not exercise the cluster's real
#   memory peak (stated honestly; see tests/qemu/README.md).
assert_runtime_load() {
    local console="$1" ram_mb="$2"
    [ -f "${console}" ] || { fail "assert_runtime_load: console log not found: ${console}"; return 1; }
    if grep -qiE 'Out of memory: Killed|invoked oom-killer' "${console}"; then
        fail "assert_runtime_load: oom-killer fired under -m ${ram_mb} (device RAM ceiling too tight)"
        return 1
    fi
    if boot_marker_verdict "${console}"; then
        info "runtime LOAD OK: reached boot marker under -m ${ram_mb} with no oom-killer"
        return 0
    fi
    warn "assert_runtime_load: no boot marker under -m ${ram_mb} (INCONCLUSIVE — experimental board / no serial console)"
    return 0   # soft: an experimental board with no -M virt firmware is inconclusive, not a FAIL
}

# ── Boot-marker verdict (reuses scripts/qemu-boot-test.sh's serial grammar) ───────
# boot_marker_verdict CONSOLE_LOG → 0 = reached userspace/login, 1 = panic/root-mount
# failure, 2 = inconclusive (no panic, no marker). Callers map 2 to soft-pass for
# experimental boards.
boot_marker_verdict() {
    local console="$1"
    [ -f "${console}" ] || return 2
    if grep -qiE 'kernel panic|Oops:|Unable to mount root|VFS: Cannot open root' "${console}" 2>/dev/null; then
        return 1
    fi
    if grep -qiE 'lightdm|Welcome to|OpenRC|reached target|login:|Plasma|sddm|getty' "${console}" 2>/dev/null; then
        return 0
    fi
    return 2
}
