#!/usr/bin/env bash
# launch-pi.sh — boot the golden aarch64 RPi 5 .img under qemu-system-aarch64
# (-M virt) for interactive / scripted testing.
#
# QEMU has NO BCM2712 machine and ships no Raspberry Pi UEFI firmware, so we
# canNOT run the real RPi firmware -> u-boot -> kernel chain. Instead we boot
# the kernel DIRECTLY (-kernel kernel_2712.img -append 'root=/dev/vda2 ...')
# against the SAME ext4 .img the Pi boots from. The image's kernel carries
# virtio + PL011, so the rootfs that boots on real silicon also boots here.
#
# Unlike run-qemu-test.sh (which fabricates a throwaway ext4 from a stage4 and a
# synthetic KEYS disk to assert provisioning), this launcher boots the REAL,
# already-provisioned golden .img — the persistent ext4 root artifact that
# flash-disk.sh writes to SD/USB/NVMe. To keep the golden image pristine and let
# growroot demonstrate expansion, we never touch it directly: we layer a
# per-run qcow2 overlay (backing-file = the raw .img) resized to OVERLAY_SIZE so
# growroot has free space to grow the root partition into on first boot.
#
# This host is x86_64 with no aarch64 KVM, so the guest runs under TCG (pure
# emulation) — keep TIMEOUT generous. Requires root only because losetup -P /
# loop ops are not needed here at all: this script needs NO root for the QEMU
# launch itself; only the optional --grow path or a root-owned WORK_DIR may.
#
# ── Shared artifact autodetect convention (mirrors flash-disk.sh) ───────────
# Both launchers and flash-disk.sh resolve the OS .img the same way so one
# WORK_DIR/role selects one artifact everywhere:
#
#   1. --img FILE                     explicit, wins over everything
#   2. ${WORK_DIR}/snapdragon-rpi5-arm64-${ROLE}-*.img   (newest, role match)
#   3. ${WORK_DIR}/snapdragon-rpi5-*.img                 (newest, any role)
#   4. ${WORK_DIR}/*.img (excluding *initramfs*/*kernel*) (newest)
#
# WORK_DIR defaults to ${REPO}/rpi5-stage4-build (same as the build scripts).
# The kernel is taken from <work>/sysroot/boot or <work>/isoroot/boot, matching
# run-qemu-test.sh, or extracted from the image's /boot via --kernel-from-img.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Defaults ───────────────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-${REPO_DIR}/rpi5-stage4-build}"
ROLE="${ROLE:-pki}"
IMG=""                         # explicit .img (else autodetect)
KERNEL=""                      # explicit kernel (else autodetect)
RUN_DIR=""                     # scratch dir for the overlay/pidfile/console
KERNEL_IMG_NAME="kernel_2712.img"
ROOT_PART="/dev/vda2"          # PARTUUID image: p1=firmware/boot, p2=ext4 root
OVERLAY_SIZE="16G"             # qcow2 overlay grows so growroot can expand
MEM="2048"
SMP="2"
QEMU_CPU="cortex-a76"          # match the Pi 5 core; TCG, no KVM on this host
QEMU_MACHINE="virt,gic-version=3"
# Forwarded host ports -> guest service ports. Guest exposes ingress-nginx on
# 80/443 (hostPort), kube-apiserver on 6443, headscale on 8080, sshd on 22.
SSH_PORT="2222"                # host -> guest 22
UI_PORT="8443"                 # host -> guest 443  (cluster UI ingress; matches e2e baseURL)
HTTP_PORT="8080"               # host -> guest 80   (ingress http)
API_PORT="6443"                # host -> guest 6443 (kube-apiserver)
HS_PORT="8081"                 # host -> guest 8080 (headscale)
TIMEOUT="2400"                 # generous: aarch64 TCG first boot is slow
KEEP=false                     # keep RUN_DIR (and overlay) on exit
FOREGROUND=false               # -nographic in the foreground instead of -daemonize
EXTRA_APPEND=""                # extra kernel cmdline appended verbatim
KEYS_IMG=""                    # optional FAT32 "KEYS" disk (provisioning tests)

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Boots the golden aarch64 RPi 5 .img under qemu-system-aarch64 -M virt by
  loading its kernel directly (QEMU has no BCM2712 / RPi UEFI). A per-run qcow2
  overlay protects the golden image and lets growroot demonstrate expansion.

Artifact selection (shared with flash-disk.sh / launch-x86.sh):
  -w, --work-dir DIR   Dir to autodetect the .img/kernel from. Default: ${WORK_DIR}
  -r, --role ROLE      Role to select (pki|backend|frontend|generic). Default: ${ROLE}
      --img FILE       Explicit golden .img (skips autodetect).
      --kernel FILE    Explicit kernel Image (default: <work>/{sysroot,isoroot}/boot/${KERNEL_IMG_NAME}).
      --kernel-from-img  Extract ${KERNEL_IMG_NAME} from the image's ESP/boot (needs root: losetup -P).

QEMU / guest:
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --cpu CPU        QEMU -cpu. Default: ${QEMU_CPU}
      --machine M      QEMU -machine. Default: ${QEMU_MACHINE}
      --root PART      root= device for the kernel cmdline. Default: ${ROOT_PART}
      --append STR     Extra kernel cmdline (appended verbatim).
      --overlay-size SZ  qcow2 overlay size (qemu-img resize). Default: ${OVERLAY_SIZE}
      --run-dir DIR    Scratch dir for overlay/pidfile/console. Default: <work>/qemu-run-pi

Port forwards (host -> guest):
      --ssh-port PORT  host -> guest 22.   Default: ${SSH_PORT}
      --ui-port PORT   host -> guest 443.  Default: ${UI_PORT}
      --http-port PORT host -> guest 80.   Default: ${HTTP_PORT}
      --api-port PORT  host -> guest 6443. Default: ${API_PORT}
      --hs-port PORT   host -> guest 8080. Default: ${HS_PORT}

Lifecycle:
  -t, --timeout SEC    Boot/SSH wait budget (info only here). Default: ${TIMEOUT}
      --keys-img FILE  Attach a FAT32 "KEYS" disk (provisioning tests).
      --foreground     Run -nographic attached to this terminal (no -daemonize).
      --keep           Don't delete the run dir / overlay on exit.
  -h, --help           Show this help.

Examples:
  $0 --role pki --foreground
  $0 --img /var/tmp/snap/snapdragon-rpi5-arm64-pki-2026.0.img --ui-port 9443
  sudo $0 --kernel-from-img --role backend     # no kernel in WORK_DIR
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir)     WORK_DIR="$2"; shift 2 ;;
        -r|--role)         ROLE="$2"; shift 2 ;;
        --img)             IMG="$2"; shift 2 ;;
        --kernel)          KERNEL="$2"; shift 2 ;;
        --kernel-from-img) KERNEL="@from-img@"; shift ;;
        -m|--mem)          MEM="$2"; shift 2 ;;
        --smp)             SMP="$2"; shift 2 ;;
        --cpu)             QEMU_CPU="$2"; shift 2 ;;
        --machine)         QEMU_MACHINE="$2"; shift 2 ;;
        --root)            ROOT_PART="$2"; shift 2 ;;
        --append)          EXTRA_APPEND="$2"; shift 2 ;;
        --overlay-size)    OVERLAY_SIZE="$2"; shift 2 ;;
        --run-dir)         RUN_DIR="$2"; shift 2 ;;
        --ssh-port)        SSH_PORT="$2"; shift 2 ;;
        --ui-port)         UI_PORT="$2"; shift 2 ;;
        --http-port)       HTTP_PORT="$2"; shift 2 ;;
        --api-port)        API_PORT="$2"; shift 2 ;;
        --hs-port)         HS_PORT="$2"; shift 2 ;;
        -t|--timeout)      TIMEOUT="$2"; shift 2 ;;
        --keys-img)        KEYS_IMG="$2"; shift 2 ;;
        --foreground)      FOREGROUND=true; shift ;;
        --keep)            KEEP=true; shift ;;
        -h|--help)         usage 0 ;;
        *)                 echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[launch-pi]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[launch-pi] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[launch-pi] ERROR:${RST} $*" >&2; exit 1; }

# ── Tool checks (arg-parse + autodetect stay usable without these) ──────────
command -v qemu-system-aarch64 >/dev/null || die "missing qemu-system-aarch64"
command -v qemu-img            >/dev/null || die "missing qemu-img"

# ── Resolve the .img (shared autodetect) ────────────────────────────────────
autodetect_img() {
    local d="$1" role="$2" c
    for c in \
        "${d}"/snapdragon-rpi5-*-"${role}"-*.img \
        "${d}"/snapdragon-rpi5-*.img \
        "${d}"/snapdragon-*-"${role}"-*.img ; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    # Last resort: any *.img that is not a kernel/initramfs blob.
    ls -1t "${d}"/*.img 2>/dev/null \
        | grep -ivE '(kernel|initramfs|initrd|squashfs)' | head -1 || true
}

if [ -z "${IMG}" ]; then
    IMG="$(autodetect_img "${WORK_DIR}" "${ROLE}")"
fi
[ -n "${IMG}" ] && [ -f "${IMG}" ] || die \
    "no golden .img found (pass --img, or build one into ${WORK_DIR}). role=${ROLE}"

# ── Resolve the kernel (run-qemu-test.sh convention) ────────────────────────
# The Pi build keeps its sysroot/isoroot under a per-arch subdir
# (${WORK_DIR}/${PI_BUILD_SUBDIR:-snap-build-pi5}); the bare ${WORK_DIR}/sysroot
# paths are kept as a fallback for trees built before the per-arch split.
if [ -z "${KERNEL}" ]; then
    PI_BUILD_SUBDIR="${PI_BUILD_SUBDIR:-snap-build-pi5}"
    for c in "${WORK_DIR}/${PI_BUILD_SUBDIR}/sysroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/${PI_BUILD_SUBDIR}/isoroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/sysroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/isoroot/boot/${KERNEL_IMG_NAME}"; do
        [ -f "${c}" ] && { KERNEL="${c}"; break; }
    done
fi

[ -n "${RUN_DIR}" ] || RUN_DIR="${WORK_DIR}/qemu-run-pi"
OVERLAY="${RUN_DIR}/run.qcow2"
CONSOLE="${RUN_DIR}/console.log"
PIDFILE="${RUN_DIR}/qemu.pid"

# If asked to pull the kernel out of the image, do it now (needs root: losetup -P).
if [ "${KERNEL}" = "@from-img@" ]; then
    [ "$(id -u)" -eq 0 ] || die "--kernel-from-img needs root (losetup -P): sudo $0 ..."
    command -v losetup >/dev/null || die "missing losetup"
    mkdir -p "${RUN_DIR}/boot-mnt"
    KERNEL="${RUN_DIR}/${KERNEL_IMG_NAME}"
    step "Extracting ${KERNEL_IMG_NAME} from ${IMG} (losetup -P)"
    LOOP="$(losetup -P --show -f "${IMG}")"
    # shellcheck disable=SC2064
    trap "umount '${RUN_DIR}/boot-mnt' 2>/dev/null || true; losetup -d '${LOOP}' 2>/dev/null || true" EXIT
    mount "${LOOP}p1" "${RUN_DIR}/boot-mnt" 2>/dev/null \
        || mount "${LOOP}p2" "${RUN_DIR}/boot-mnt" || die "could not mount image boot partition"
    cp "${RUN_DIR}/boot-mnt/${KERNEL_IMG_NAME}" "${KERNEL}" 2>/dev/null \
        || cp "${RUN_DIR}/boot-mnt/boot/${KERNEL_IMG_NAME}" "${KERNEL}" \
        || die "no ${KERNEL_IMG_NAME} inside image"
    umount "${RUN_DIR}/boot-mnt"; losetup -d "${LOOP}"; trap - EXIT
fi

[ -n "${KERNEL}" ] && [ -f "${KERNEL}" ] || die \
    "kernel ${KERNEL_IMG_NAME} not found (pass --kernel or --kernel-from-img). \
QEMU boots the Pi kernel directly — it cannot use the RPi firmware chain."

info "img    : ${IMG}"
info "kernel : ${KERNEL}"
info "run dir: ${RUN_DIR}"

# ── Per-run qcow2 overlay (keeps the golden .img pristine) ───────────────────
mkdir -p "${RUN_DIR}"
rm -f "${OVERLAY}"
step "Creating qcow2 overlay over the golden image (resized to ${OVERLAY_SIZE})"
qemu-img create -f qcow2 -b "${IMG}" -F raw "${OVERLAY}" >/dev/null
qemu-img resize "${OVERLAY}" "${OVERLAY_SIZE}" >/dev/null

cleanup() {
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

# ── Kernel cmdline: PARTUUID image, ext4 root on vda2, PL011 console ─────────
# Mirrors specs-rpi5/boot/cmdline.txt hardening so the emulated boot matches silicon.
CMDLINE="root=${ROOT_PART} rootfstype=ext4 rw rootwait console=ttyAMA0,115200 net.ifnames=0 \
lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 \
systemd.unified_cgroup_hierarchy=1 slab_nomerge init_on_alloc=1 randomize_kstack_offset=on"
[ -n "${EXTRA_APPEND}" ] && CMDLINE="${CMDLINE} ${EXTRA_APPEND}"

HOSTFWD="user,id=net0"
HOSTFWD+=",hostfwd=tcp::${SSH_PORT}-:22"
HOSTFWD+=",hostfwd=tcp::${UI_PORT}-:443"
HOSTFWD+=",hostfwd=tcp::${HTTP_PORT}-:80"
HOSTFWD+=",hostfwd=tcp::${API_PORT}-:6443"
HOSTFWD+=",hostfwd=tcp::${HS_PORT}-:8080"

QEMU_ARGS=(
    -machine "${QEMU_MACHINE}" -cpu "${QEMU_CPU}" -smp "${SMP}" -m "${MEM}"
    -no-reboot
    -kernel "${KERNEL}" -append "${CMDLINE}"
    -drive "file=${OVERLAY},format=qcow2,if=none,id=hd0"
    -device virtio-blk-pci,drive=hd0
    -netdev "${HOSTFWD}"
    -device virtio-net-pci,netdev=net0
    -pidfile "${PIDFILE}"
)
# Optional KEYS provisioning disk (FAT32, label KEYS) — second virtio-blk disk the
# keys-provision first-boot engine discovers by label (fresh / re-provision tests).
if [ -n "${KEYS_IMG}" ]; then
    [ -f "${KEYS_IMG}" ] || die "keys-img not found: ${KEYS_IMG}"
    QEMU_ARGS+=(-drive "file=${KEYS_IMG},format=raw,if=none,id=keys,readonly=on"
                -device virtio-blk-pci,drive=keys)
    info "keys   : ${KEYS_IMG} (attached as a virtio KEYS disk)"
fi

step "Booting QEMU (machine=${QEMU_MACHINE}, cpu=${QEMU_CPU}, ${SMP} vCPU, ${MEM}M; TCG — slow)"
info "forwards: ssh:${SSH_PORT}->22 ui:${UI_PORT}->443 http:${HTTP_PORT}->80 api:${API_PORT}->6443 hs:${HS_PORT}->8080"

if ${FOREGROUND}; then
    info "foreground console (Ctrl-A X to quit). Budget ~${TIMEOUT}s for first boot under TCG."
    exec qemu-system-aarch64 "${QEMU_ARGS[@]}" -nographic -serial mon:stdio
else
    # NB: -nographic conflicts with -daemonize in QEMU. Detach I/O explicitly
    # (-display none -serial file: -monitor none) and daemonize instead.
    qemu-system-aarch64 "${QEMU_ARGS[@]}" \
        -display none -serial "file:${CONSOLE}" -monitor none -daemonize
    info "QEMU pid $(cat "${PIDFILE}" 2>/dev/null || echo '?'); console -> ${CONSOLE}"
    info "SSH in with:  ssh -p ${SSH_PORT} <user>@localhost"
    info "Stop with  :  kill \$(cat ${PIDFILE})"
    # Daemonized: do NOT let the EXIT trap kill the VM we just backgrounded.
    KEEP=true; trap - EXIT
fi
