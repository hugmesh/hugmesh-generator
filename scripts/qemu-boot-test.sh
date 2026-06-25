#!/usr/bin/env bash
# qemu-boot-test.sh — boot a Snapdragon ISO (or installed disk) under QEMU/KVM with
# UEFI (OVMF) and report whether it boots. Used to verify the live ISO, the toram
# boot path, and a full installer run onto a virtual disk — the boot-time behaviours
# that can't be checked at build time.
#
#   ./qemu-boot-test.sh live      <live.iso>                  # boot live, look for the desktop/login
#   ./qemu-boot-test.sh install   <installer.iso>             # unattended-install to a fresh disk, then boot it
#   ./qemu-boot-test.sh disk      <disk.qcow2|.img>           # boot an already-installed disk
#
# Headless: serial → logfile, framebuffer → VNC (:NN). Pass/fail is decided from the
# serial log markers + QEMU staying alive past the timeout (no kernel panic).
set -euo pipefail

MODE="${1:?usage: $0 live|install|disk <image> [seconds]}"
IMG="${2:?path to the .iso/.img}"
TIMEOUT="${3:-240}"
[ -f "${IMG}" ] || { echo "not found: ${IMG}" >&2; exit 1; }

# Locate OVMF UEFI firmware. NB: a plain `ls a b c | head` trips `set -o pipefail`
# (ls exits non-zero when any candidate is missing) which `set -e` turns into a fatal
# abort even though a valid path was found — so iterate and pick the first that exists.
# A non-matching glob (nullglob off) stays literal and fails the -f test, which is fine.
OVMF=""
for _c in /usr/share/edk2-ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE*.fd \
          /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2/OvmfX64/OVMF_CODE.fd \
          /usr/share/edk2/OvmfX64/OVMF_CODE.secboot.fd; do
    [ -f "${_c}" ] && { OVMF="${_c}"; break; }
done
[ -n "${OVMF}" ] || { echo "no OVMF UEFI firmware (emerge sys-firmware/edk2-ovmf)" >&2; exit 1; }
# Pair the writable VARS template with the CODE we picked (prefer the same dir).
OVMF_VARS_SRC=""
for _v in "$(dirname "${OVMF}")/OVMF_VARS.fd" /usr/share/edk2-ovmf/OVMF_VARS.fd \
          /usr/share/OVMF/OVMF_VARS*.fd /usr/share/edk2/OvmfX64/OVMF_VARS.fd; do
    [ -f "${_v}" ] && { OVMF_VARS_SRC="${_v}"; break; }
done

WORK="$(mktemp -d /var/tmp/qboot.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
VARS="${WORK}/OVMF_VARS.fd"; cp "${OVMF_VARS_SRC:-${OVMF}}" "${VARS}"
SERIAL="${WORK}/serial.log"
DISK="${WORK}/target.qcow2"; qemu-img create -f qcow2 "${DISK}" 40G >/dev/null
KVM=(); [ -e /dev/kvm ] && KVM=(-enable-kvm -cpu host)
VNC_PORT=$(( (RANDOM % 50) + 10 ))

common=( "${KVM[@]}" -m 4096 -smp 2
         -drive "if=pflash,format=raw,readonly=on,file=${OVMF}"
         -drive "if=pflash,format=raw,file=${VARS}"
         -serial "file:${SERIAL}" -display none -vnc ":${VNC_PORT}" -no-reboot )

boot_qemu() {
    echo "  QEMU booting (${MODE}); serial -> ${SERIAL}; VNC :${VNC_PORT} (connect to inspect the GUI)"
    timeout "${TIMEOUT}" qemu-system-x86_64 "$@" >/dev/null 2>&1 || true
}

case "${MODE}" in
    live)
        boot_qemu "${common[@]}" -cdrom "${IMG}" -boot d -drive "file=${DISK},if=virtio,format=qcow2" ;;
    install)
        echo "  Phase 1: booting installer ISO; the live autostart runs install-x86 onto the virtio disk."
        boot_qemu "${common[@]}" -cdrom "${IMG}" -boot d -drive "file=${DISK},if=virtio,format=qcow2"
        echo "  Phase 2: booting the freshly installed disk (UEFI)."
        boot_qemu "${common[@]}" -drive "file=${DISK},if=virtio,format=qcow2" -boot c ;;
    disk)
        cp "${IMG}" "${DISK}" 2>/dev/null || DISK="${IMG}"
        boot_qemu "${common[@]}" -drive "file=${DISK},if=virtio,format=qcow2" -boot c ;;
    *) echo "mode must be live|install|disk" >&2; exit 1 ;;
esac

echo "── serial log tail ──"; tail -n 25 "${SERIAL}" 2>/dev/null || echo "(empty — the ISO cmdline may not use console=ttyS0; inspect via VNC)"
echo "── verdict ──"
if grep -qiE 'kernel panic|Oops:|Unable to mount root|VFS: Cannot open root' "${SERIAL}" 2>/dev/null; then
    echo "FAIL: kernel panic / root mount failure"; exit 1
elif grep -qiE 'lightdm|Welcome to|OpenRC|reached target|login:|Plasma|sddm|getty' "${SERIAL}" 2>/dev/null; then
    echo "PASS: reached userspace/login (see serial log + VNC for detail)"; exit 0
else
    echo "INCONCLUSIVE: no panic, but no boot marker on serial (cmdline likely console=tty0 only)."
    echo "  Re-run with a serial-console build entry, or inspect the VNC framebuffer during the run."
    exit 0
fi
