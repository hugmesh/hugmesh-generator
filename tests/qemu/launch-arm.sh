#!/usr/bin/env bash
# launch-arm.sh — boot a golden aarch64 .img for the NON-Pi ARM builders
# (frite / jetson / orangepi5 / orangepizero2[w] / orangepizero3 / orangepi3-lts /
# orangepi4-lts) under qemu-system-aarch64 -M virt
# by loading its kernel DIRECTLY (-kernel Image -dtb <board.dtb> -append 'root=...').
#
# This is the generalization of launch-pi.sh to the four ARM platforms the Pi
# launcher never covered. QEMU has NO Amlogic/Rockchip/Tegra/Allwinner machine
# and ships none of their vendor firmware, so — exactly as with the Pi — we
# cannot run the real SoC firmware -> u-boot -> kernel chain. Instead we boot the
# board's own mainline kernel Image + its in-tree DTB against the SAME ext4 .img
# the board boots from. All four builders emit boot/Image + a board DTB (the same
# artifacts as the Pi), so the rootfs that boots on real silicon also boots here.
#
# This host is x86_64 with NO aarch64 KVM, so the guest runs under TCG (pure
# emulation) — keep TIMEOUT generous. EXPERIMENTAL boards (frite/jetson/orangepi)
# may be INCONCLUSIVE under -M virt (no vendor firmware, mainline-only drivers) —
# the matrix driver treats that as a soft-pass, not a FAIL (see run-matrix-e2e.sh).
#
# Per-board (kernel, DTB, -cpu) come from the SAME tables the builders use
# (build-<platform>-stage4.sh select_board): the DTB path is the drift-free key.
#
# ── Shared artifact autodetect convention (mirrors launch-pi.sh / flash-disk.sh) ──
# One WORK_DIR/platform/board/role selects one artifact everywhere:
#   1. --img FILE                                            explicit, wins
#   2. ${WORK_DIR}/hugmesh-${platform}-${board}-arm64-${role}-*.img (newest)
#   3. ${WORK_DIR}/hugmesh-${platform}-*.img                        (newest)
#   4. ${WORK_DIR}/*.img (excluding kernel/initramfs/squashfs blobs)   (newest)
# WORK_DIR defaults to ${REPO}/out (the ARM builders' own default work dir); the
# kernel + DTB are taken from <work>/${BUILD_SUBDIR}/{sysroot,isoroot}/boot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Defaults ───────────────────────────────────────────────────────────────
PLATFORM="${PLATFORM:-frite}"  # frite | jetson | orangepi5 | orangepizero2 | orangepizero2w | orangepizero3 | orangepi3-lts | orangepi4-lts
BOARD="${BOARD:-}"             # board id (empty on the boardless zero2/zero2w/zero3 platforms)
WORK_DIR="${WORK_DIR:-${REPO_DIR}/out}"
ROLE="${ROLE:-desktop}"
IMG=""                         # explicit .img (else autodetect)
KERNEL=""                      # explicit kernel Image (else autodetect)
DTB=""                         # explicit DTB (else per-board default from the table)
BUILD_SUBDIR=""                # per-arch build subdir (else per-platform default)
RUN_DIR=""                     # scratch dir for the overlay/pidfile/console
KERNEL_IMG_NAME="Image"        # the ARM builders install boot/Image (not kernel_2712.img)
ROOT_PART="/dev/vda2"          # p1=firmware/boot, p2=ext4 root (same layout as the Pi)
OVERLAY_SIZE="16G"             # qcow2 overlay grows so growroot can expand
MEM="2048"
SMP="2"
QEMU_CPU=""                    # per-board default (TCG, no KVM on this host)
QEMU_MACHINE="virt,gic-version=3"
SSH_PORT="2222"                # host -> guest 22
UI_PORT="8443"                 # host -> guest 443
HTTP_PORT="8080"               # host -> guest 80
API_PORT="6443"                # host -> guest 6443
HS_PORT="8081"                 # host -> guest 8080
TIMEOUT="2400"                 # generous: aarch64 TCG first boot is slow
KEEP=false
FOREGROUND=false
EXTRA_APPEND=""
KEYS_IMG=""
QMP_SOCK=""                    # optional QMP unix socket (--qmp); empty keeps -monitor none

usage() {
cat <<EOF
Usage: $0 --platform PLAT [--board BOARD] [OPTIONS]

  Boots a golden aarch64 .img for a non-Pi ARM builder under
  qemu-system-aarch64 -M virt by loading its kernel + DTB directly (QEMU has no
  Amlogic/Rockchip/Tegra/Allwinner machine / vendor firmware). A per-run qcow2
  overlay protects the golden image and lets growroot demonstrate expansion.

Platform / board:
  -p, --platform PLAT  frite | jetson | orangepi5 | orangepizero2 | orangepizero2w | orangepizero3 | orangepi3-lts | orangepi4-lts. Default: ${PLATFORM}
  -b, --board BOARD    Board id (la-frite|le-potato|sweet-potato | orin-nano[-4gb]|
                       orin-nx-8gb|orin-nx-16gb | orange-pi-5[-plus]). Empty on zero2/zero2w/zero3.

Artifact selection (shared with launch-pi.sh / flash-disk.sh):
  -w, --work-dir DIR   Dir to autodetect the .img/kernel/DTB from. Default: ${WORK_DIR}
  -r, --role ROLE      Role to select. Default: ${ROLE}
      --img FILE       Explicit golden .img (skips autodetect).
      --kernel FILE    Explicit kernel Image (default: <work>/<subdir>/{sysroot,isoroot}/boot/${KERNEL_IMG_NAME}).
      --dtb FILE       Explicit DTB (default: the board's in-tree DTB from the builder table).
      --build-subdir D Per-arch build subdir (default: per-platform snap-build-<platform>).

QEMU / guest:
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --cpu CPU        QEMU -cpu (default: per-board; TCG-safe cortex-a53/a76).
      --machine M      QEMU -machine. Default: ${QEMU_MACHINE}
      --root PART      root= device. Default: ${ROOT_PART}
      --append STR     Extra kernel cmdline (appended verbatim).
      --overlay-size SZ  qcow2 overlay size. Default: ${OVERLAY_SIZE}
      --run-dir DIR    Scratch dir for overlay/pidfile/console. Default: <work>/qemu-run-arm

Port forwards (host -> guest): --ssh-port/--ui-port/--http-port/--api-port/--hs-port
Lifecycle: -t/--timeout SEC, --keys-img FILE, --foreground, --keep, -h/--help
      --qmp PATH       Listen for QMP on the unix socket PATH (pause/resume/reset/
                       powerdown of the running guest). Omitted => -monitor none.

Examples:
  $0 --platform frite --board la-frite --role desktop --foreground
  $0 --platform jetson --board orin-nano-4gb --img /var/tmp/snap/...-jetson-orin-nano-4gb-*.img
  $0 --platform orangepizero2 --role appliance
  $0 --platform orangepizero2w --role appliance
  $0 --platform orangepizero3 --role appliance
  $0 --platform orangepi3-lts --role appliance
  $0 --platform orangepi4-lts --role desktop
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--platform)     PLATFORM="$2"; shift 2 ;;
        -b|--board)        BOARD="$2"; shift 2 ;;
        -w|--work-dir)     WORK_DIR="$2"; shift 2 ;;
        -r|--role)         ROLE="$2"; shift 2 ;;
        --img)             IMG="$2"; shift 2 ;;
        --kernel)          KERNEL="$2"; shift 2 ;;
        --dtb)             DTB="$2"; shift 2 ;;
        --build-subdir)    BUILD_SUBDIR="$2"; shift 2 ;;
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
        --qmp)             QMP_SOCK="$2"; shift 2 ;;
        --foreground)      FOREGROUND=true; shift ;;
        --keep)            KEEP=true; shift ;;
        -h|--help)         usage 0 ;;
        *)                 echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[launch-arm]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[launch-arm] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[launch-arm] ERROR:${RST} $*" >&2; exit 1; }

# ── Per-board table: (default DTB, TCG-safe -cpu, default build subdir). ─────
# Keyed by the matrix `board` column; the DTB paths mirror each builder's own
# select_board() table (the drift-free key). QEMU -M virt only models a fixed set
# of cores, so big.LITTLE / a78ae SoCs map to the nearest TCG-emulable core
# (cortex-a53 for the A53 boards, cortex-a76 for the A76/A78 class).
board_defaults() {
    local plat="$1" board="$2"
    case "${plat}:${board}" in
        frite:la-frite)     DEF_DTB="amlogic/meson-gxl-s805x-libretech-ac.dtb";  DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-frite" ;;
        frite:le-potato)    DEF_DTB="amlogic/meson-gxl-s905x-libretech-cc.dtb";  DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-frite" ;;
        frite:sweet-potato) DEF_DTB="amlogic/meson-gxl-s905x-libretech-cc-v2.dtb"; DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-frite" ;;
        jetson:orin-nano)   DEF_DTB="nvidia/tegra234-p3768-0000+p3767-0005.dtb"; DEF_CPU="cortex-a76"; DEF_SUBDIR="snap-build-jetson" ;;
        jetson:orin-nano-4gb) DEF_DTB="nvidia/tegra234-p3768-0000+p3767-0004.dtb"; DEF_CPU="cortex-a76"; DEF_SUBDIR="snap-build-jetson" ;;
        jetson:orin-nx-8gb) DEF_DTB="nvidia/tegra234-p3768-0000+p3767-0001.dtb"; DEF_CPU="cortex-a76"; DEF_SUBDIR="snap-build-jetson" ;;
        jetson:orin-nx-16gb) DEF_DTB="nvidia/tegra234-p3768-0000+p3767-0000.dtb"; DEF_CPU="cortex-a76"; DEF_SUBDIR="snap-build-jetson" ;;
        orangepi5:orange-pi-5)      DEF_DTB="rockchip/rk3588s-orangepi-5.dtb";      DEF_CPU="cortex-a76"; DEF_SUBDIR="snap-build-orangepi5" ;;
        orangepi5:orange-pi-5-plus) DEF_DTB="rockchip/rk3588-orangepi-5-plus.dtb"; DEF_CPU="cortex-a76"; DEF_SUBDIR="snap-build-orangepi5" ;;
        orangepizero2:*)    DEF_DTB="allwinner/sun50i-h616-orangepi-zero2.dtb";   DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-orangepizero2" ;;
        orangepizero2w:*)   DEF_DTB="allwinner/sun50i-h618-orangepi-zero2w.dtb"; DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-orangepizero2w" ;;
        orangepizero3:*)   DEF_DTB="allwinner/sun50i-h618-orangepi-zero3.dtb"; DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-orangepizero3" ;;
        orangepi3-lts:*)   DEF_DTB="allwinner/sun50i-h6-orangepi-3.dtb"; DEF_CPU="cortex-a53"; DEF_SUBDIR="snap-build-orangepi3-lts" ;;
        # RK3399: mainline has ONE Orange Pi RK3399 DTB and no -lts variant, so
        # this boots the shared rk3399-orangepi.dtb. CPU is the A72 big core.
        orangepi4-lts:*)   DEF_DTB="rockchip/rk3399-orangepi.dtb"; DEF_CPU="cortex-a72"; DEF_SUBDIR="snap-build-orangepi4-lts" ;;
        *) die "no board table entry for platform=${plat} board=${board} (pass --dtb/--cpu/--build-subdir explicitly)" ;;
    esac
}
board_defaults "${PLATFORM}" "${BOARD}"
[ -n "${DTB}" ]          || DTB="${DEF_DTB}"
[ -n "${QEMU_CPU}" ]     || QEMU_CPU="${DEF_CPU}"
[ -n "${BUILD_SUBDIR}" ] || BUILD_SUBDIR="${DEF_SUBDIR}"

# ── Tool checks (arg-parse + autodetect stay usable without these) ──────────
command -v qemu-system-aarch64 >/dev/null || die "missing qemu-system-aarch64"
command -v qemu-img            >/dev/null || die "missing qemu-img"

# ── Resolve the .img (shared autodetect) ────────────────────────────────────
# Artifact prefixes (build-<platform>-stage4.sh ART_PREFIX): frite/jetson/opi5 are
# ${BRAND}-${platform}-${board}-arm64-${role}-${env}-*, zero2 is boardless.
autodetect_img() {
    local d="$1" plat="$2" board="$3" role="$4" c pat_board
    pat_board="${board:+${board}-}"
    for c in \
        "${d}"/hugmesh-"${plat}"-"${pat_board}"arm64-"${role}"-*.img \
        "${d}"/hugmesh-"${plat}"-*-"${role}"-*.img \
        "${d}"/hugmesh-"${plat}"-*.img ; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    ls -1t "${d}"/*.img 2>/dev/null \
        | grep -ivE '(kernel|initramfs|initrd|squashfs)' | head -1 || true
}

if [ -z "${IMG}" ]; then
    IMG="$(autodetect_img "${WORK_DIR}" "${PLATFORM}" "${BOARD}" "${ROLE}")"
fi
[ -n "${IMG}" ] && [ -f "${IMG}" ] || die \
    "no golden .img found (pass --img, or build one into ${WORK_DIR}). platform=${PLATFORM} board=${BOARD} role=${ROLE}"

# ── Resolve the kernel Image (the ARM builders keep it under the per-arch subdir) ──
if [ -z "${KERNEL}" ]; then
    for c in "${WORK_DIR}/${BUILD_SUBDIR}/sysroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/${BUILD_SUBDIR}/isoroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/sysroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/isoroot/boot/${KERNEL_IMG_NAME}"; do
        [ -f "${c}" ] && { KERNEL="${c}"; break; }
    done
fi
[ -n "${KERNEL}" ] && [ -f "${KERNEL}" ] || die \
    "kernel ${KERNEL_IMG_NAME} not found under ${WORK_DIR}/${BUILD_SUBDIR}/{sysroot,isoroot}/boot \
(pass --kernel). QEMU -M virt boots the mainline kernel directly — no vendor firmware chain."

# ── Resolve the DTB. The compiled .dtb lives beside the kernel under boot/dtbs/. ──
if [ ! -f "${DTB}" ]; then
    kdir="$(dirname "${KERNEL}")"
    for c in "${kdir}/dtbs/${DTB}" "${kdir}/${DTB}" "${kdir}/dtbs/$(basename "${DTB}")"; do
        [ -f "${c}" ] && { DTB="${c}"; break; }
    done
fi
[ -f "${DTB}" ] || die \
    "DTB not found: ${DTB} (pass --dtb; expected the board's compiled .dtb beside the kernel under boot/dtbs/)."

[ -n "${RUN_DIR}" ] || RUN_DIR="${WORK_DIR}/qemu-run-arm"
OVERLAY="${RUN_DIR}/run.qcow2"
CONSOLE="${RUN_DIR}/console.log"
PIDFILE="${RUN_DIR}/qemu.pid"

info "platform: ${PLATFORM} board:${BOARD:-<none>} role:${ROLE}"
info "img    : ${IMG}"
info "kernel : ${KERNEL}"
info "dtb    : ${DTB}"
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

# ── The board's OWN security posture, read from its cmdline.base ──────────────
# We boot with -kernel/-append, so this string REPLACES the image's cmdline
# entirely. That makes a hardcoded posture here actively misleading: this launcher
# used to append `lsm=lockdown,yama,selinux,bpf lockdown=integrity` for ALL eight
# non-Pi boards, none of which ships lockdown in its cmdline.base or builds
# CONFIG_SECURITY_LOCKDOWN_LSM. Every in-guest LSM/lockdown assertion was therefore
# grading the harness's own literal instead of the image — it could not fail.
# Take the security tokens from the board's real cmdline.base; root=/console= stay
# QEMU-specific below because -M virt has neither the board's storage nor its UART.
specs_dir_for() {
    case "$1" in
        frite)          echo "specs-frite" ;;
        jetson)         echo "specs-jetson" ;;
        orangepi5)      echo "specs-orangepi5" ;;
        orangepizero2)  echo "specs-orangepi-zero2" ;;
        orangepizero2w) echo "specs-orangepi-zero2w" ;;
        orangepizero3)  echo "specs-orangepi-zero3" ;;
        orangepi3-lts)  echo "specs-orangepi3-lts" ;;
        orangepi4-lts)  echo "specs-orangepi4-lts" ;;
        *)              echo "" ;;
    esac
}
BOARD_CMDLINE_BASE="${REPO_DIR}/$(specs_dir_for "${PLATFORM}")/boot/cmdline.base"
[ -f "${BOARD_CMDLINE_BASE}" ] \
    || die "no cmdline.base for platform=${PLATFORM} (looked in ${BOARD_CMDLINE_BASE}) — refusing to boot with a hardcoded security posture the image may not have"
LSM_APPEND="$(tr ' ' '\n' < "${BOARD_CMDLINE_BASE}" \
    | grep -E '^(lsm=|lockdown=|selinux=|audit=)' | tr '\n' ' ' | sed 's/ *$//')"
[ -n "${LSM_APPEND}" ] \
    || die "${BOARD_CMDLINE_BASE} carries no lsm=/selinux=/audit= tokens — the image has no asserted security posture to reproduce"
info "board security posture from cmdline.base: ${LSM_APPEND}"

# ── Kernel cmdline: ext4 root on vda2, PL011/8250 console ─────────────────────
CMDLINE="root=${ROOT_PART} rootfstype=ext4 rw rootwait console=ttyAMA0,115200 net.ifnames=0 \
${LSM_APPEND} cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 \
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
    -kernel "${KERNEL}" -dtb "${DTB}" -append "${CMDLINE}"
    -drive "file=${OVERLAY},format=qcow2,if=none,id=hd0"
    -device virtio-blk-pci,drive=hd0
    -netdev "${HOSTFWD}"
    -device virtio-net-pci,netdev=net0
    -pidfile "${PIDFILE}"
)
if [ -n "${KEYS_IMG}" ]; then
    [ -f "${KEYS_IMG}" ] || die "keys-img not found: ${KEYS_IMG}"
    QEMU_ARGS+=(-drive "file=${KEYS_IMG},format=raw,if=none,id=keys,readonly=on"
                -device virtio-blk-pci,drive=keys)
    info "keys   : ${KEYS_IMG} (attached as a virtio KEYS disk)"
fi
# Optional QMP control socket. Without --qmp nothing changes: the daemonized
# launch below still passes -monitor none, so a booted guest cannot be steered at
# all. With it, a controller gets an endpoint for stop / cont / system_reset /
# system_powerdown on the SAME qemu the assertions ran against.
# 'nowait' is load-bearing, not decoration: with `server` alone QEMU prints
# "QEMU waiting for connection on: ..." and blocks before starting, so the
# -daemonize below never returns (checked here against qemu-system-x86_64 10.2.3:
# server,nowait daemonizes with the socket already bound; plain server hung until
# it was killed). A leftover socket at PATH is harmless — QEMU replaces it on
# bind and unlinks it again when the guest exits.
if [ -n "${QMP_SOCK}" ]; then
    # Daemonized as root inside the runner container, where only RUN_DIR is
    # guaranteed to exist — create the parent rather than assume the caller did.
    mkdir -p "$(dirname "${QMP_SOCK}")" || die "cannot create the --qmp socket dir for ${QMP_SOCK}"
    # AF_UNIX sun_path is 108 bytes including the NUL, and QEMU rejects longer
    # paths outright ("UNIX socket path '...' is too long / Path must be less
    # than 108 bytes"). Daemonized, that error would only ever reach the launch
    # log, so fail here where the caller still sees the offending path.
    [ "${#QMP_SOCK}" -le 107 ] || die \
        "--qmp path is ${#QMP_SOCK} bytes; AF_UNIX allows at most 107: ${QMP_SOCK}"
    QEMU_ARGS+=(-qmp "unix:${QMP_SOCK},server,nowait")
    info "qmp    : ${QMP_SOCK} (pause/resume/reset/powerdown)"
fi

step "Booting QEMU (machine=${QEMU_MACHINE}, cpu=${QEMU_CPU}, ${SMP} vCPU, ${MEM}M; TCG — slow)"
info "forwards: ssh:${SSH_PORT}->22 ui:${UI_PORT}->443 http:${HTTP_PORT}->80 api:${API_PORT}->6443 hs:${HS_PORT}->8080"

if ${FOREGROUND}; then
    info "foreground console (Ctrl-A X to quit). Budget ~${TIMEOUT}s for first boot under TCG."
    exec qemu-system-aarch64 "${QEMU_ARGS[@]}" -nographic -serial mon:stdio
else
    qemu-system-aarch64 "${QEMU_ARGS[@]}" \
        -display none -serial "file:${CONSOLE}" -monitor none -daemonize
    info "QEMU pid $(cat "${PIDFILE}" 2>/dev/null || echo '?'); console -> ${CONSOLE}"
    info "SSH in with:  ssh -p ${SSH_PORT} <user>@localhost"
    info "Stop with  :  kill \$(cat ${PIDFILE})"
    KEEP=true; trap - EXIT
fi
