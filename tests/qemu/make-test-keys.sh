#!/usr/bin/env bash
# make-test-keys.sh — pack a directory into a FAT32 image labelled KEYS,
# suitable for attaching to QEMU as a virtio disk to emulate the USB KEYS
# provisioning stick.
#
# Usage: make-test-keys.sh <keys-dir> <out-image> [size-mb]
# Requires root (loop-mount) OR mtools (mcopy) if present.
set -euo pipefail

SRC="${1:?usage: $0 <keys-dir> <out-image> [size-mb]}"
OUT="${2:?usage: $0 <keys-dir> <out-image> [size-mb]}"
SIZE_MB="${3:-64}"
LABEL="KEYS"

[ -d "${SRC}" ] || { echo "ERROR: keys dir not found: ${SRC}" >&2; exit 1; }
command -v mkfs.vfat >/dev/null || { echo "ERROR: need mkfs.vfat (sys-fs/dosfstools)" >&2; exit 1; }

rm -f "${OUT}"
truncate -s "${SIZE_MB}M" "${OUT}"
mkfs.vfat -F 32 -n "${LABEL}" "${OUT}" >/dev/null

if command -v mcopy >/dev/null 2>&1; then
    # No root needed
    ( cd "${SRC}" && for e in *; do mcopy -s -i "${OUT}" "${e}" "::/"; done )
else
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: need root (or mtools) to populate ${OUT}" >&2; exit 1; }
    MNT="$(mktemp -d)"
    trap 'umount "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true' EXIT
    mount -o loop "${OUT}" "${MNT}"
    cp -rT "${SRC}" "${MNT}/"
    sync
fi
echo "Wrote KEYS image: ${OUT} (${SIZE_MB} MB, label ${LABEL})"
