#!/usr/bin/env bash
# launch-x86.sh — boot the golden x86_64 host .img under qemu-system-x86_64
# (q35 + OVMF/UEFI) for interactive / scripted testing.
#
# Unlike the Pi launcher, x86 is fully self-booting: the .img is a UEFI GPT disk
# (p1 ESP FAT32 with GRUB-EFI installed --removable as /EFI/BOOT/BOOTX64.EFI,
# p2 ext4 root LAST — see specs-x86/installer/install-x86.sh). OVMF firmware
# finds the removable bootloader and GRUB boots the kernel off the ESP, exactly
# like real hardware. We pass NO -kernel/-append: the firmware + GRUB chain runs.
#
# We protect the golden image and let growroot demonstrate expansion the same
# way as launch-pi.sh: a per-run qcow2 overlay (backing-file = the raw .img)
# resized to OVERLAY_SIZE. OVMF needs writable NVRAM, so we also copy OVMF_VARS
# per run (CODE stays read-only pflash).
#
# This host has a usable /dev/kvm, so we default to accel=kvm:tcg (-cpu host)
# and fall back to TCG automatically if /dev/kvm is missing/unusable.
#
# ── Shared artifact autodetect convention (mirrors flash-disk.sh) ───────────
# Same resolution order as launch-pi.sh so one WORK_DIR/role selects one
# artifact everywhere:
#   1. --img FILE                                       explicit
#   2. ${WORK_DIR}/snapdragon-host-*-${ROLE}-*.img       (newest, role match)
#   3. ${WORK_DIR}/snapdragon-host-*.img / snapdragon-x86-*.img
#   4. ${WORK_DIR}/*.img (excluding kernel/initramfs/squashfs)
# WORK_DIR defaults to ${REPO}/x86-host-build (build-x86-host-stage4.sh's
# work dir; see its line `WORK_DIR="$(pwd)/x86-host-build"`); override with -w.
# No external kernel is needed — the image self-boots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── OVMF firmware (host paths from the design notes) ────────────────────────
OVMF_DIR="${OVMF_DIR:-/usr/share/edk2/OvmfX64}"
OVMF_CODE="${OVMF_CODE:-${OVMF_DIR}/OVMF_CODE.fd}"
OVMF_VARS="${OVMF_VARS:-${OVMF_DIR}/OVMF_VARS.fd}"

# ── Defaults ───────────────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-${REPO_DIR}/x86-host-build}"
ROLE="${ROLE:-host}"
IMG=""                         # explicit .img (else autodetect)
RUN_DIR=""                     # scratch dir for overlay/vars/pidfile/console
OVERLAY_SIZE="16G"             # qcow2 overlay grows so growroot can expand
MEM="4096"                     # x86 host image is heavier than the Pi
SMP="4"
ACCEL="kvm:tcg"                # try KVM, fall back to TCG
QEMU_CPU="host"                # overridden to a portable model if KVM unusable
QEMU_MACHINE="q35"
# Forwarded host ports -> guest service ports (same map as launch-pi.sh).
SSH_PORT="2222"                # host -> guest 22
UI_PORT="8443"                 # host -> guest 443  (cluster UI ingress; matches e2e baseURL)
HTTP_PORT="8080"               # host -> guest 80   (ingress http)
API_PORT="6443"                # host -> guest 6443 (kube-apiserver)
HS_PORT="8081"                 # host -> guest 8080 (headscale)
TIMEOUT="900"                  # KVM boot is fast; generous for TCG fallback
KEEP=false                     # keep RUN_DIR (and overlay) on exit
FOREGROUND=false               # -nographic in the foreground instead of -daemonize
KEYS_IMG=""                    # optional FAT32 "KEYS" disk (client/provisioning tests)
GPU_DEV=false                  # attach a virtio-gpu (desktop/client images render a greeter)

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Boots the golden x86_64 host .img under qemu-system-x86_64 q35 + OVMF/UEFI.
  The image self-boots via its ESP (GRUB-EFI --removable) — no -kernel needed.
  A per-run qcow2 overlay + per-run OVMF_VARS keep the golden image pristine and
  let growroot demonstrate expansion.

Artifact selection (shared with flash-disk.sh / launch-pi.sh):
  -w, --work-dir DIR   Dir to autodetect the .img from. Default: ${WORK_DIR}
  -r, --role ROLE      Role to select. Default: ${ROLE}
      --img FILE       Explicit golden .img (skips autodetect).

Firmware:
      --ovmf-code FILE OVMF_CODE.fd (read-only pflash). Default: ${OVMF_CODE}
      --ovmf-vars FILE OVMF_VARS.fd template (copied per run). Default: ${OVMF_VARS}

QEMU / guest:
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --accel A        QEMU -machine accel. Default: ${ACCEL}
      --cpu CPU        QEMU -cpu. Default: ${QEMU_CPU} (auto -> portable if no KVM)
      --machine M      QEMU -machine type. Default: ${QEMU_MACHINE}
      --overlay-size SZ  qcow2 overlay size (qemu-img resize). Default: ${OVERLAY_SIZE}
      --run-dir DIR    Scratch dir for overlay/vars/pidfile/console. Default: <work>/qemu-run-x86
      --keys-img FILE  Attach a FAT32 "KEYS" disk (provisioning/client tests).
      --gpu            Attach a virtio-GPU (client/desktop greeter rendering).

Port forwards (host -> guest):
      --ssh-port PORT  host -> guest 22.   Default: ${SSH_PORT}
      --ui-port PORT   host -> guest 443.  Default: ${UI_PORT}
      --http-port PORT host -> guest 80.   Default: ${HTTP_PORT}
      --api-port PORT  host -> guest 6443. Default: ${API_PORT}
      --hs-port PORT   host -> guest 8080. Default: ${HS_PORT}

Lifecycle:
  -t, --timeout SEC    Boot/SSH wait budget (info only here). Default: ${TIMEOUT}
      --foreground     Run -nographic attached to this terminal (no -daemonize).
      --keep           Don't delete the run dir / overlay on exit.
  -h, --help           Show this help.

Examples:
  $0 --foreground
  $0 --img /var/tmp/snap/snapdragon-host-amd64-2026.0.img --ui-port 9443
  $0 --accel tcg --cpu max          # force pure emulation
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir)   WORK_DIR="$2"; shift 2 ;;
        -r|--role)       ROLE="$2"; shift 2 ;;
        --img)           IMG="$2"; shift 2 ;;
        --ovmf-code)     OVMF_CODE="$2"; shift 2 ;;
        --ovmf-vars)     OVMF_VARS="$2"; shift 2 ;;
        -m|--mem)        MEM="$2"; shift 2 ;;
        --smp)           SMP="$2"; shift 2 ;;
        --accel)         ACCEL="$2"; shift 2 ;;
        --cpu)           QEMU_CPU="$2"; shift 2 ;;
        --machine)       QEMU_MACHINE="$2"; shift 2 ;;
        --overlay-size)  OVERLAY_SIZE="$2"; shift 2 ;;
        --run-dir)       RUN_DIR="$2"; shift 2 ;;
        --ssh-port)      SSH_PORT="$2"; shift 2 ;;
        --ui-port)       UI_PORT="$2"; shift 2 ;;
        --http-port)     HTTP_PORT="$2"; shift 2 ;;
        --api-port)      API_PORT="$2"; shift 2 ;;
        --hs-port)       HS_PORT="$2"; shift 2 ;;
        -t|--timeout)    TIMEOUT="$2"; shift 2 ;;
        --keys-img)      KEYS_IMG="$2"; shift 2 ;;
        --gpu)           GPU_DEV=true; shift ;;
        --foreground)    FOREGROUND=true; shift ;;
        --keep)          KEEP=true; shift ;;
        -h|--help)       usage 0 ;;
        *)               echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[launch-x86]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[launch-x86] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[launch-x86] ERROR:${RST} $*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || die "missing qemu-system-x86_64"
command -v qemu-img           >/dev/null || die "missing qemu-img"

# ── Resolve the .img (shared autodetect) ────────────────────────────────────
autodetect_img() {
    local d="$1" role="$2" c
    for c in \
        "${d}"/snapdragon-host-*-"${role}"-*.img \
        "${d}"/snapdragon-host-*.img \
        "${d}"/snapdragon-x86-*.img \
        "${d}"/snapdragon-*-"${role}"-*.img ; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    ls -1t "${d}"/*.img 2>/dev/null \
        | grep -ivE '(kernel|initramfs|initrd|squashfs)' | head -1 || true
}

if [ -z "${IMG}" ]; then
    IMG="$(autodetect_img "${WORK_DIR}" "${ROLE}")"
fi
[ -n "${IMG}" ] && [ -f "${IMG}" ] || die \
    "no golden .img found (pass --img, or build one into ${WORK_DIR}). role=${ROLE}"
[ -f "${OVMF_CODE}" ] || die "OVMF_CODE not found: ${OVMF_CODE} (pass --ovmf-code)"
[ -f "${OVMF_VARS}" ] || die "OVMF_VARS not found: ${OVMF_VARS} (pass --ovmf-vars)"

# ── KVM detection: drop to TCG (and a portable CPU) when KVM is unusable ─────
if [[ "${ACCEL}" == *kvm* ]]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        info "/dev/kvm usable — accelerating with KVM (-cpu ${QEMU_CPU})"
    else
        warn "/dev/kvm not usable — falling back to TCG"
        ACCEL="tcg"
    fi
fi
# '-cpu host' requires KVM. If the effective accel has no KVM (whether by
# fallback above or an explicit --accel tcg), remap the default host model to a
# portable one so TCG doesn't reject the launch.
if [[ "${ACCEL}" != *kvm* ]] && [ "${QEMU_CPU}" = "host" ]; then
    QEMU_CPU="max"
fi

[ -n "${RUN_DIR}" ] || RUN_DIR="${WORK_DIR}/qemu-run-x86"
OVERLAY="${RUN_DIR}/run.qcow2"
VARS="${RUN_DIR}/OVMF_VARS.fd"
CONSOLE="${RUN_DIR}/console.log"
PIDFILE="${RUN_DIR}/qemu.pid"

info "img    : ${IMG}"
info "ovmf   : ${OVMF_CODE} (ro) + ${OVMF_VARS} (per-run copy)"
info "run dir: ${RUN_DIR}"

# ── Per-run qcow2 overlay + writable OVMF_VARS ───────────────────────────────
mkdir -p "${RUN_DIR}"
rm -f "${OVERLAY}" "${VARS}"
step "Creating qcow2 overlay over the golden image (resized to ${OVERLAY_SIZE})"
qemu-img create -f qcow2 -b "${IMG}" -F raw "${OVERLAY}" >/dev/null
qemu-img resize "${OVERLAY}" "${OVERLAY_SIZE}" >/dev/null
cp "${OVMF_VARS}" "${VARS}"

cleanup() {
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

HOSTFWD="user,id=net0"
HOSTFWD+=",hostfwd=tcp::${SSH_PORT}-:22"
HOSTFWD+=",hostfwd=tcp::${UI_PORT}-:443"
HOSTFWD+=",hostfwd=tcp::${HTTP_PORT}-:80"
HOSTFWD+=",hostfwd=tcp::${API_PORT}-:6443"
HOSTFWD+=",hostfwd=tcp::${HS_PORT}-:8080"

QEMU_ARGS=(
    -machine "${QEMU_MACHINE},accel=${ACCEL}" -cpu "${QEMU_CPU}" -smp "${SMP}" -m "${MEM}"
    -no-reboot
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${VARS}"
    -drive "file=${OVERLAY},format=qcow2,if=none,id=hd0"
    -device virtio-blk-pci,drive=hd0
    -netdev "${HOSTFWD}"
    -device virtio-net-pci,netdev=net0
    -pidfile "${PIDFILE}"
)
# Optional KEYS provisioning disk (FAT32, label KEYS) — second virtio-blk disk the
# keys-provision first-boot engine discovers by label (client/provisioning tests).
if [ -n "${KEYS_IMG}" ]; then
    [ -f "${KEYS_IMG}" ] || die "keys-img not found: ${KEYS_IMG}"
    QEMU_ARGS+=(-drive "file=${KEYS_IMG},format=raw,if=none,id=keys,readonly=on"
                -device virtio-blk-pci,drive=keys)
    info "keys   : ${KEYS_IMG} (attached as a virtio KEYS disk)"
fi
# Optional virtio-GPU so client/desktop images can bring up Xorg (modesetting) +
# the lightdm greeter; node images don't need it (serial console only).
if ${GPU_DEV}; then
    QEMU_ARGS+=(-device virtio-gpu-pci)
    info "gpu    : virtio-gpu attached (desktop/greeter rendering)"
fi

# -enable-kvm is implied by accel=kvm; only add it explicitly when KVM is in use.
[[ "${ACCEL}" == *kvm* ]] && QEMU_ARGS+=(-enable-kvm)

step "Booting QEMU (machine=${QEMU_MACHINE}, accel=${ACCEL}, cpu=${QEMU_CPU}, ${SMP} vCPU, ${MEM}M)"
info "forwards: ssh:${SSH_PORT}->22 ui:${UI_PORT}->443 http:${HTTP_PORT}->80 api:${API_PORT}->6443 hs:${HS_PORT}->8080"

if ${FOREGROUND}; then
    info "foreground console (Ctrl-A X to quit). Budget ~${TIMEOUT}s for first boot."
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}" -nographic -serial mon:stdio
else
    # NB: -nographic conflicts with -daemonize in QEMU. Detach I/O explicitly
    # (-display none -serial file: -monitor none) and daemonize instead.
    qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -display none -serial "file:${CONSOLE}" -monitor none -daemonize
    info "QEMU pid $(cat "${PIDFILE}" 2>/dev/null || echo '?'); console -> ${CONSOLE}"
    info "SSH in with:  ssh -p ${SSH_PORT} <user>@localhost"
    info "Stop with  :  kill \$(cat ${PIDFILE})"
    # Daemonized: do NOT let the EXIT trap kill the VM we just backgrounded.
    KEEP=true; trap - EXIT
fi
