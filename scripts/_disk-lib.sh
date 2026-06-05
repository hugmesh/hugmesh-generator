#!/usr/bin/env bash
# _disk-lib.sh — SOURCED helper library for the Snapdragon disk-flashing layer.
#
# Factors out the destructive-block-device safety that make-keys-usb.sh
# pioneered (typed-device-path confirmation, child unmount, partition-name
# resolution for sdX/nvme/mmcblk/loop) so flash-disk.sh and make-keys-usb.sh
# share ONE audited implementation.
#
# This file is meant to be SOURCED, never executed:
#     source "$(dirname "${BASH_SOURCE[0]}")/_disk-lib.sh"
#
# It does NOT call `set -euo pipefail` itself — the sourcing script owns the
# shell options. It defines functions only (no top-level side effects beyond
# the guard below), so sourcing it is safe and idempotent.
#
# Public API:
#   dl_require_root                 — die unless EUID 0
#   dl_confirm_destroy <dev>        — typed-device-path confirmation (honors DL_NO_CONFIRM)
#   dl_unmount_children <dev>       — umount every mounted partition of <dev>
#   dl_partdev <dev> <n>            — echo the Nth partition device node
#   dl_wait_settle [dev]            — partprobe + udev settle after partitioning
#   dl_require_tools <tool>...      — die if any tool is missing
#   dl_is_block <dev>               — true if <dev> is a block device
#   dl_die / dl_warn / dl_info / dl_step — logging helpers (stderr for die/warn)
#
# Tunables (env, set by the caller before/after sourcing):
#   DL_NO_CONFIRM=1   skip the interactive typed-path confirmation
#   DL_QUIET=1        suppress dl_info/dl_step chatter (errors/warnings still show)

# Guard against double-sourcing. This file is meant to be sourced; `return`
# only works in that context, so fall back to `exit` if someone runs it.
# shellcheck disable=SC2317  # the `exit 0` is reachable only when run directly
if [ -n "${_DISK_LIB_SOURCED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_DISK_LIB_SOURCED=1

# ── Logging ────────────────────────────────────────────────────────
# Colour only when stderr is a TTY, so logs/pipes stay clean.
if [ -t 2 ]; then
    _DL_RED=$'\033[0;31m'; _DL_GRN=$'\033[0;32m'
    _DL_CYN=$'\033[0;36m'; _DL_YEL=$'\033[0;33m'; _DL_RST=$'\033[0m'
else
    _DL_RED=''; _DL_GRN=''; _DL_CYN=''; _DL_YEL=''; _DL_RST=''
fi

dl_info() { [ -n "${DL_QUIET:-}" ] && return 0; echo "${_DL_GRN}[disk]${_DL_RST} $*"; }
dl_step() { [ -n "${DL_QUIET:-}" ] && return 0; echo "${_DL_CYN}==> $*${_DL_RST}"; }
dl_warn() { echo "${_DL_YEL}[disk] WARN:${_DL_RST} $*" >&2; }
dl_die()  { echo "${_DL_RED}[disk] ERROR:${_DL_RST} $*" >&2; exit 1; }

# ── Preconditions ──────────────────────────────────────────────────

# dl_require_root — abort unless running as uid 0 (loop/partition/dd ops need it).
dl_require_root() {
    [ "$(id -u)" -eq 0 ] || dl_die "run as root (block-device + loop ops need it): re-run with sudo."
}

# dl_require_tools <tool>... — abort if any named tool is not on PATH.
dl_require_tools() {
    local t missing=()
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ "${#missing[@]}" -eq 0 ] || dl_die "missing required tools: ${missing[*]}"
}

# dl_is_block <dev> — succeed iff <dev> is a block special file.
dl_is_block() {
    [ -n "${1:-}" ] && [ -b "$1" ]
}

# ── Partition-name resolution ──────────────────────────────────────

# dl_partdev <dev> <n> — print the device node for the Nth partition of <dev>.
#
# Handles the kernel's two naming schemes:
#   /dev/sda      -> /dev/sda1            (plain suffix)
#   /dev/nvme0n1  -> /dev/nvme0n1p1       ('p' separator)
#   /dev/mmcblk0  -> /dev/mmcblk0p1       ('p' separator)
#   /dev/loop0    -> /dev/loop0p1         ('p' separator, losetup -P)
# The rule: if the base name ends in a digit, insert a 'p'.
dl_partdev() {
    local dev="${1:?dl_partdev: device required}"
    local n="${2:?dl_partdev: partition number required}"
    local base="${dev%/}"
    if [[ "${base}" =~ [0-9]$ ]]; then
        printf '%s' "${base}p${n}"
    else
        printf '%s' "${base}${n}"
    fi
}

# ── Unmount ────────────────────────────────────────────────────────

# dl_unmount_children <dev> — unmount every mountpoint backed by <dev> or any of
# its partitions, so the disk can be repartitioned / dd'd safely. Best-effort:
# never fails the caller (returns 0) but warns on a stubborn mount.
dl_unmount_children() {
    local dev="${1:?dl_unmount_children: device required}"
    dl_is_block "${dev}" || return 0

    # Collect mountpoints from the device subtree (the device itself may be
    # mounted if someone mounted the whole disk; partitions are the common case).
    local mp
    while IFS= read -r mp; do
        [ -n "${mp}" ] || continue
        if umount "${mp}" 2>/dev/null; then
            dl_info "unmounted ${mp}"
        elif umount -l "${mp}" 2>/dev/null; then
            # Lazy unmount for busy bind/overlay leftovers.
            dl_info "lazily unmounted ${mp}"
        else
            dl_warn "could not unmount ${mp} (still busy?)"
        fi
    done < <(lsblk -ln -o MOUNTPOINT "${dev}" 2>/dev/null | grep -v '^$' || true)

    # Also deactivate any swap living on the device's partitions.
    local part
    while IFS= read -r part; do
        [ -n "${part}" ] || continue
        swapoff "/dev/${part}" 2>/dev/null || true
    done < <(lsblk -ln -o NAME,FSTYPE "${dev}" 2>/dev/null | awk '$2=="swap"{print $1}' || true)

    return 0
}

# ── Settle ─────────────────────────────────────────────────────────

# dl_wait_settle [dev] — flush the kernel partition table view after writing one.
# Re-reads <dev>'s table (partprobe) then waits for udev to create/refresh the
# partition nodes, so a subsequent mkfs on a fresh partition node won't ENOENT.
dl_wait_settle() {
    local dev="${1:-}"
    sync
    if [ -n "${dev}" ] && dl_is_block "${dev}"; then
        partprobe "${dev}" 2>/dev/null || true
    fi
    # udevadm settle is the reliable barrier; the sleeps are belt-and-suspenders
    # for environments without a running udev (loop devices in containers).
    udevadm settle 2>/dev/null || sleep 1
}

# ── Confirmation ───────────────────────────────────────────────────

# dl_confirm_destroy <dev> — show the device and demand the operator type its
# exact path before any destructive write. Honors DL_NO_CONFIRM=1 (for CI /
# scripted use) but still prints what it WOULD destroy.
dl_confirm_destroy() {
    local dev="${1:?dl_confirm_destroy: device required}"

    echo "${_DL_YEL}About to ERASE all data on ${dev}:${_DL_RST}" >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "${dev}" >&2 2>/dev/null || true

    if [ -n "${DL_NO_CONFIRM:-}" ]; then
        dl_warn "DL_NO_CONFIRM set — skipping interactive confirmation for ${dev}"
        return 0
    fi

    local reply
    read -rp "Type the device path to confirm destruction: " reply
    [ "${reply}" = "${dev}" ] || dl_die "confirmation '${reply}' != '${dev}' — aborted."
}
