#!/usr/bin/env bash
# launch-arm.sh — boot a golden aarch64 .img for the NON-Pi ARM builders
# (frite / jetson / orangepi5 / orangepizero2[w] / orangepizero3 / orangepi3-lts /
# orangepi4-lts) under qemu-system-aarch64 -M virt
# by loading its kernel DIRECTLY (-kernel Image -append 'root=...').
#
# This is the generalization of launch-pi.sh to the four ARM platforms the Pi
# launcher never covered. QEMU has NO Amlogic/Rockchip/Tegra/Allwinner machine
# and ships none of their vendor firmware, so — exactly as with the Pi — we
# cannot run the real SoC firmware -> u-boot -> kernel chain. Instead we boot the
# board's own mainline kernel Image against the SAME ext4 .img the board boots
# from. All the builders emit boot/Image (the same artifact as the Pi), so the
# rootfs that boots on real silicon also boots here.
#
# NO -dtb (2026-11-04). This launcher used to hand QEMU the BOARD's DTB
# (meson-gxl / rk3588 / tegra234 / sun50i). With -kernel, a -dtb REPLACES the
# device tree QEMU synthesises for -M virt, and the board DTB describes none of
# virt's hardware: no PL011 at 0x09000000, no PCIe ECAM, no virtio-mmio, no GICv3
# at virt's addresses. The guest kernel therefore found no console, no disk and no
# NIC — a launcher defect reported as "experimental board inconclusive". The
# default is now QEMU's own DT; --dtb FILE is still honoured as an explicit opt-in
# (with a warning) for anyone booting a DTB that really does describe virt.
# The board's FDT name stays in the table (BOARD_DTB): the Frite installer proof
# checks that the medium / the installed FAT carries it, it just never reaches
# QEMU.
#
# This host is x86_64 with NO aarch64 KVM, so the guest runs under TCG (pure
# emulation) — keep TIMEOUT generous. EXPERIMENTAL boards (frite/jetson/orangepi)
# may be INCONCLUSIVE under -M virt (no vendor firmware, mainline-only drivers) —
# the matrix driver treats that as a soft-pass, not a FAIL (see run-matrix-e2e.sh).
#
# Per-board (kernel, DTB name, -cpu) come from the SAME tables the builders use
# (build-<platform>-stage4.sh select_board): the DTB path is the drift-free key.
#
# ── Frite media + eMMC target (2026-11-04, operator requirement: "on le frite,
# make sure installer image can install to the emmc") ──────────────────────
# The Frite builder emits no .img: its LIVE and INSTALLER flavours are MEDIA
# (ISO9660 today; a raw MBR+FAT image is the planned u-boot-bootable form) that
# carry /Image, /initrd.img (dmsquash-live), /extlinux/extlinux.conf and /dtb/.
#   --medium FILE      boot that medium: kernel + initrd + the DEFAULT label's
#                      APPEND are lifted off it (ISO via xorriso/bsdtar, MBR+FAT
#                      via sfdisk+mtools, partitionless FAT via mtools) and the
#                      medium is attached as usb-storage behind qemu-xhci — the
#                      same bus a real USB stick lands on (/dev/sda in the guest).
#                      --medium-bus virtio is the fallback for an initramfs
#                      without USB storage drivers.
#   --emmc FILE        attach FILE as an eMMC behind sdhci-pci (QEMU >= 9.1
#                      `emmc` device, NOT in the runner image's QEMU 7.2): the
#                      guest sees /dev/mmcblk0 (+ mmcblk0boot0/1, rpmb) exactly
#                      like La Frite's onboard module. The backing file is
#                      [boot0][boot1][rpmb][user area] — the user area starts at
#                      2*--emmc-boot-size + --emmc-rpmb-size (hw/sd/sd.c
#                      sd_part_offset), which anyone reading the file from the
#                      host must add. No overlay: the file IS the install target.
#   --extlinux FILE    take the kernel cmdline from this extlinux.conf (the
#                      installed eMMC's own /extlinux/extlinux.conf for phase B).
#   --gpu              virtio-gpu-pci + usb-kbd + usb-tablet so the lightdm
#                      greeter is drawn and QMP `screendump` captures it
#                      (-display none stays: the dump comes from the virtual
#                      framebuffer, no host display needed). With --display
#                      spice it adds nothing: the door's own virtio-gpu-pci,edid=on
#                      + usb-kbd + usb-tablet are that GPU (as on launch-x86.sh).
# Every one of these is default-off: without them the argv is byte-identical to
# the golden-.img path, minus the -dtb that never belonged there.
# tests/qemu/frite-emmc-install.sh is the two-phase driver on top of this.
#
# ── Shared artifact autodetect convention (mirrors launch-pi.sh / flash-disk.sh) ──
# One WORK_DIR/platform/board/role selects one artifact everywhere:
#   1. --img FILE                                            explicit, wins
#   2. ${WORK_DIR}/*-${platform}-${board}-arm64-${role}-*.img (newest)
#   3. ${WORK_DIR}/*-${platform}-*.img                        (newest)
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
IMG=""                         # explicit .img (else autodetect; optional with --medium/--emmc)
KERNEL=""                      # explicit kernel Image (else autodetect / from --medium)
INITRD=""                      # explicit initramfs (else from --medium's INITRD line)
DTB=""                         # explicit DTB: ONLY then is -dtb passed (see header)
MEDIUM=""                      # Frite live/installer medium (ISO9660 or MBR+FAT / FAT)
MEDIUM_BUS="usb"               # usb (qemu-xhci + usb-storage, like a real stick) | virtio
EXTLINUX=""                    # take APPEND from this extlinux.conf (phase B: the eMMC's own)
EMMC=""                        # raw backing file for the sdhci-pci/emmc target
EMMC_BOOT_SIZE="4194304"       # bytes per eMMC boot partition (La Frite module: 4 MiB)
EMMC_RPMB_SIZE="0"             # bytes for the RPMB partition (0 = none)
GPU=false                      # --gpu: virtio-gpu-pci + usb-kbd + usb-tablet
BUILD_SUBDIR=""                # per-arch build subdir (else per-platform default)
RUN_DIR=""                     # scratch dir for the overlay/pidfile/console
KERNEL_IMG_NAME="Image"        # the ARM builders install boot/Image (not kernel_2712.img)
ROOT_PART="/dev/vda2"          # p1=firmware/boot, p2=ext4 root (same layout as the Pi)
OVERLAY_SIZE="16G"             # qcow2 overlay grows so growroot can expand
# What --img IS. "raw" (default) is a golden build artifact; "qcow2" is a STANDALONE
# save (run-qemu-docker.sh --save-device / core/emulation_save.py) booted again —
# boot-from-save. Either way the per-run overlay below is the only file qemu writes.
IMG_FORMAT="raw"
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
SERIAL_SOCK=""                 # optional unix socket for the guest UART (--serial-sock); empty keeps -serial file:
# ── Mesh (multi-node) L2 — issue #48, parity with launch-x86.sh, all default-off ─
# --mesh-net attaches a SECOND virtio NIC on a shared QEMU socket L2 so several
# emulated nodes see each other (kubeadm init + joins); the slirp user NIC above
# is untouched. Without --mesh-net the QEMU argv stays byte-identical. Spelled
# character-for-character as launch-x86.sh's landed block on purpose: one flag
# name, one SPEC grammar and one MAC rule across all three launchers, so
# mesh-cluster.sh and run-qemu-docker.sh can drive a mixed-arch mesh without
# knowing which launcher a row lands on.
MESH_NET=""                    # ADDR:PORT (mcast) | mcast=A:P | listen=H:P | connect=H:P
MESH_MAC=""                    # explicit MAC for the mesh NIC (unique per node on the L2)
MESH_ID=""                     # small node index 1..255 deriving the default MAC
# ── Display door (opt-in) — all default-off ──────────────────────────────────
# --display spice opens ONE door: SPICE over TCP on DISPLAY_LISTEN:SPICE_PORT,
# protected by a per-run password that QEMU reads from a FILE as a secret OBJECT.
# Never password= : that shows in `ps` and in the tee'd launch.log. Without
# --display the QEMU argv stays byte-identical (tests/qemu/display_argv_test.sh).
DISPLAY_MODE="none"            # none | spice
DISPLAY_LISTEN="127.0.0.1"     # -spice addr=; 0.0.0.0 is only sane INSIDE the runner container
SPICE_PORT=""                  # -spice port= (required with --display spice)
DISPLAY_SECRET=""              # FILE holding the per-run password (required with --display spice)
VNC_SOCK=""                    # optional -vnc unix:PATH browser (noVNC) fallback, same secret
# --virt-dtb asserts the default (no -dtb: QEMU generates the virt machine DTB). A board DTB
# describes the board's SoC, not virt's PCIe root and the virtio devices on it,
# so a display-mode boot (virtio-gpu, xhci, virtio-serial) needs the generated one.
VIRT_DTB=false

usage() {
cat <<EOF
Usage: $0 --platform PLAT [--board BOARD] [OPTIONS]

  Boots a golden aarch64 .img for a non-Pi ARM builder under
  qemu-system-aarch64 -M virt by loading its kernel directly (QEMU has no
  Amlogic/Rockchip/Tegra/Allwinner machine / vendor firmware; the guest runs on
  QEMU's own virt device tree, never the board DTB). A per-run qcow2 overlay
  protects the golden image and lets growroot demonstrate expansion.
  Frite has no .img: boot its LIVE/INSTALLER medium with --medium and install
  onto an emulated eMMC with --emmc (see tests/qemu/frite-emmc-install.sh).

Platform / board:
  -p, --platform PLAT  frite | jetson | orangepi5 | orangepizero2 | orangepizero2w | orangepizero3 | orangepi3-lts | orangepi4-lts. Default: ${PLATFORM}
  -b, --board BOARD    Board id (la-frite|le-potato|sweet-potato | orin-nano[-4gb]|
                       orin-nx-8gb|orin-nx-16gb | orange-pi-5[-plus]). Empty on zero2/zero2w/zero3.

Artifact selection (shared with launch-pi.sh / flash-disk.sh):
  -w, --work-dir DIR   Dir to autodetect the .img/kernel/DTB from. Default: ${WORK_DIR}
  -r, --role ROLE      Role to select. Default: ${ROLE}
      --img FILE       Explicit golden .img (skips autodetect). Optional with --medium/--emmc.
      --kernel FILE    Explicit kernel Image (default: <work>/<subdir>/{sysroot,isoroot}/boot/${KERNEL_IMG_NAME},
                       or /${KERNEL_IMG_NAME} lifted off --medium).
      --initrd FILE    Explicit initramfs (default: none; with --medium, its INITRD line).
      --dtb FILE       Pass -dtb FILE. DEFAULT: NO -dtb — QEMU's own virt device tree.
                       A board DTB passed here replaces that DT and the guest finds
                       no console/disk/NIC; only for a DTB that describes -M virt.
      --build-subdir D Per-arch build subdir (default: per-platform snap-build-<platform>).

Frite media / eMMC target (all default-off; see the header):
      --medium FILE    LIVE/INSTALLER medium (ISO9660, MBR+FAT or bare FAT) carrying
                       /${KERNEL_IMG_NAME}, /initrd.img, /extlinux/extlinux.conf. Boots its
                       DEFAULT label (APPEND verbatim, FDT line dropped, the board UART
                       console rewritten to ttyAMA0) with the medium attached read-only.
      --medium-bus B   usb (default: qemu-xhci + usb-storage => /dev/sda) | virtio (/dev/vdX).
      --extlinux FILE  Take the kernel cmdline from FILE's DEFAULT label instead of
                       root=${ROOT_PART} (phase B: the installed eMMC's own extlinux.conf).
      --emmc FILE      Raw eMMC backing file -> sdhci-pci + emmc (QEMU >= 9.1; host
                       QEMU, not the runner image). Guest: /dev/mmcblk0 + boot0/1.
                       Written in place (it is the install target) — no overlay.
      --emmc-boot-size BYTES   Per-boot-partition size (default ${EMMC_BOOT_SIZE}; 128K-multiple, <= 32640K).
      --emmc-rpmb-size BYTES   RPMB size (default ${EMMC_RPMB_SIZE}; 128K-multiple, <= 16384K).
      --gpu            virtio-gpu-pci + usb-kbd + usb-tablet (greeter drawn; QMP screendump).
                       With --display spice it is folded into the door's GPU.

QEMU / guest:
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --cpu CPU        QEMU -cpu (default: per-board; TCG-safe cortex-a53/a76).
      --machine M      QEMU -machine. Default: ${QEMU_MACHINE}
      --root PART      root= device. Default: ${ROOT_PART}
      --append STR     Extra kernel cmdline (appended verbatim).
      --overlay-size SZ  qcow2 overlay size. Default: ${OVERLAY_SIZE}
      --img-format F   raw (default: a golden build .img) | qcow2 (a STANDALONE save
                       from run-qemu-docker.sh --save-device, booted again). qcow2 puts
                       the per-run overlay over the SAVE with -F qcow2, so the save is
                       never written; it is not resized (it already carries the size
                       the original run grew it to).
      --run-dir DIR    Scratch dir for overlay/pidfile/console. Default: <work>/qemu-run-arm

Mesh (multi-node) networking — issue #48; all default-off:
      --mesh-net SPEC  Attach a SECOND virtio NIC on a shared QEMU socket L2 so
                       emulated nodes see each other. SPEC: ADDR:PORT (UDP
                       multicast, the n-node form — same SPEC on every node),
                       or an explicit mcast=A:P / listen=H:P / connect=H:P
                       (2-node point-to-point socket). The slirp user NIC and
                       its hostfwds are untouched.
      --mesh-mac MAC   MAC for the mesh NIC (must be unique per node on the L2).
      --mesh-id N      Node index 1..255 deriving the default MAC
                       52:54:00:6d:65:NN. Give --mesh-mac OR --mesh-id, not both.

Display door (a window that RESIZES the guest; all default-off):
      --display MODE   none (default) | spice. spice adds virtio-gpu-pci,edid=on,
                       the vdagent virtserialport, qemu-xhci + usb-tablet +
                       usb-kbd, and the SPICE server. Open it with remote-viewer.
      --display-listen ADDR  -spice addr=. Default: ${DISPLAY_LISTEN} (0.0.0.0 is
                       for the runner container's OWN netns only).
      --spice-port N   -spice port= (required with --display spice).
      --display-secret FILE  File holding the per-run password, handed to QEMU
                       as a secret OBJECT (required; never on the command line).
      --vnc-socket PATH  Also serve VNC on the unix socket PATH (noVNC browser
                       fallback: scale-only, 8-char DES auth from the same file).
      --virt-dtb       Assert the default (no -dtb, QEMU generates the virt DTB);
                       refused together with --dtb. Display mode relies on it.

Port forwards (host -> guest): --ssh-port/--ui-port/--http-port/--api-port/--hs-port
Lifecycle: -t/--timeout SEC, --keys-img FILE, --foreground, --keep, -h/--help
      --qmp PATH       Listen for QMP on the unix socket PATH (pause/resume/reset/
                       powerdown of the running guest). Omitted => -monitor none.
      --serial-sock P  Guest UART on the unix socket P (server, no wait; console.log
                       still written via logfile=). Lets a driver answer the dracut
                       LUKS prompt. Omitted => -serial file:console.log, as before.

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
        --img-format)      IMG_FORMAT="$2"; shift 2 ;;
        --kernel)          KERNEL="$2"; shift 2 ;;
        --initrd)          INITRD="$2"; shift 2 ;;
        --dtb)             DTB="$2"; shift 2 ;;
        --medium)          MEDIUM="$2"; shift 2 ;;
        --medium-bus)      MEDIUM_BUS="$2"; shift 2 ;;
        --extlinux)        EXTLINUX="$2"; shift 2 ;;
        --emmc)            EMMC="$2"; shift 2 ;;
        --emmc-boot-size)  EMMC_BOOT_SIZE="$2"; shift 2 ;;
        --emmc-rpmb-size)  EMMC_RPMB_SIZE="$2"; shift 2 ;;
        --gpu)             GPU=true; shift ;;
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
        --mesh-net)        MESH_NET="$2"; shift 2 ;;
        --mesh-mac)        MESH_MAC="$2"; shift 2 ;;
        --mesh-id)         MESH_ID="$2"; shift 2 ;;
        --qmp)             QMP_SOCK="$2"; shift 2 ;;
        --serial-sock)     SERIAL_SOCK="$2"; shift 2 ;;
        --display)         DISPLAY_MODE="$2"; shift 2 ;;
        --display-listen)  DISPLAY_LISTEN="$2"; shift 2 ;;
        --spice-port)      SPICE_PORT="$2"; shift 2 ;;
        --display-secret)  DISPLAY_SECRET="$2"; shift 2 ;;
        --vnc-socket)      VNC_SOCK="$2"; shift 2 ;;
        --virt-dtb)        VIRT_DTB=true; shift ;;
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
# The board's FDT NAME (what extlinux's FDT line must point at on the medium /
# the installed FAT). It is deliberately NOT the -dtb default: see the header.
BOARD_DTB="${DEF_DTB}"
[ -n "${QEMU_CPU}" ]     || QEMU_CPU="${DEF_CPU}"
[ -n "${BUILD_SUBDIR}" ] || BUILD_SUBDIR="${DEF_SUBDIR}"

case "${MEDIUM_BUS}" in usb|virtio) ;; *) die "--medium-bus must be usb or virtio (got: ${MEDIUM_BUS})" ;; esac

# ── Tool checks (arg-parse + autodetect stay usable without these) ──────────
command -v qemu-system-aarch64 >/dev/null || die "missing qemu-system-aarch64"
command -v qemu-img            >/dev/null || die "missing qemu-img"
case "${IMG_FORMAT}" in
    raw) ;;
    # A save is only ever named explicitly: autodetect finds GOLDEN images, and a
    # raw golden opened as qcow2 would fail at boot instead of here.
    qcow2) [ -n "${IMG}" ] || die "--img-format qcow2 needs an explicit --img (the saved .qcow2); autodetect only finds golden images" ;;
    *) die "--img-format must be raw or qcow2, got '${IMG_FORMAT}'" ;;
esac

# ── Medium helpers: what kind of medium, and lift one file off it ────────────
# Format is decided by MAGIC, never by extension: the Frite builder emits
# .installer.iso today and the u-boot-bootable fix turns that into a raw MBR+FAT
# .installer.img; both must work here without a rename.
#   iso : "CD001" at byte 0x8001 (ISO9660 primary volume descriptor)
#   mbr : 55 AA at 510 and a FAT partition found through sfdisk (regular file ok)
#   fat : a bare FAT filesystem at offset 0 (minfo accepts it)
medium_kind() {
    local f="$1"
    if [ "$(od -An -c -j 32769 -N 5 "${f}" 2>/dev/null | tr -d ' ')" = "CD001" ]; then
        echo iso; return 0
    fi
    if [ "$(od -An -tx1 -j 510 -N 2 "${f}" 2>/dev/null | tr -d ' ')" = "55aa" ]; then
        echo mbr; return 0
    fi
    if MTOOLS_SKIP_CHECK=1 minfo -i "${f}" >/dev/null 2>&1; then
        echo fat; return 0
    fi
    echo unknown; return 1
}
# First FAT partition's byte offset inside an MBR image (sfdisk works on files).
medium_fat_offset() {
    local f="$1" start size off
    while read -r start size; do
        [ -n "${start}" ] && [ -n "${size}" ] || continue
        [ "${size}" -gt 0 ] 2>/dev/null || continue
        off=$((start * 512))
        MTOOLS_SKIP_CHECK=1 minfo -i "${f}@@${off}" >/dev/null 2>&1 || continue
        printf '%s\n' "${off}"; return 0
    done < <(sfdisk -d "${f}" 2>/dev/null \
        | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*size=[[:space:]]*\([0-9]\+\).*/\1 \2/p')
    return 1
}
# medium_extract MEDIUM /path/in/medium OUT — exit 1 (and no OUT) when absent.
medium_extract() {
    local f="$1" p="$2" out="$3" kind off
    kind="$(medium_kind "${f}")" || die "cannot tell what ${f} is (not ISO9660, not MBR+FAT, not FAT)"
    rm -f "${out}"
    case "${kind}" in
        iso)
            if command -v xorriso >/dev/null 2>&1; then
                xorriso -osirrox on -indev "${f}" -extract "${p}" "${out}" >/dev/null 2>&1 || { rm -f "${out}"; return 1; }
            elif command -v bsdtar >/dev/null 2>&1; then
                bsdtar -xOf "${f}" "${p#/}" > "${out}" 2>/dev/null || { rm -f "${out}"; return 1; }
            else
                die "reading an ISO9660 medium needs xorriso or bsdtar (libarchive) on PATH"
            fi
            ;;
        mbr)
            off="$(medium_fat_offset "${f}")" || die "no FAT partition in ${f} (an MBR medium must carry its boot tree on a FAT partition)"
            MTOOLS_SKIP_CHECK=1 mcopy -n -i "${f}@@${off}" "::${p}" "${out}" 2>/dev/null || { rm -f "${out}"; return 1; }
            ;;
        fat)
            MTOOLS_SKIP_CHECK=1 mcopy -n -i "${f}" "::${p}" "${out}" 2>/dev/null || { rm -f "${out}"; return 1; }
            ;;
    esac
    [ -s "${out}" ] || { rm -f "${out}"; return 1; }
}
# extlinux_field FILE FIELD — FIELD (APPEND|INITRD|FDT|LINUX) of the DEFAULT
# label (or the first label when there is no DEFAULT). Prints nothing if absent.
extlinux_field() {
    local f="$1" field="$2"
    awk -v want="${field}" '
        BEGIN { IGNORECASE = 1 }
        /^[[:space:]]*#/ { next }
        tolower($1) == "default" { def = $2; next }
        tolower($1) == "label"   { lbl = $2; if (first == "") first = lbl; next }
        {
            if (tolower($1) != tolower(want)) next
            v = $0; sub(/^[[:space:]]*[A-Za-z]+[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
            val[lbl] = v
        }
        END {
            if (def != "" && (def in val)) { print val[def]; exit }
            if (first != "" && (first in val)) { print val[first]; exit }
        }' "${f}"
}
# The board's UART (ttyAML0 on Amlogic, ttyS2 on Rockchip, ...) does not exist on
# -M virt. Drop every console=tty<letters><n> token (keeping console=tty1-style
# VTs) and put console=ttyAMA0 LAST, so /dev/console — where firstboot, dracut
# and keys-provision print — is the serial log the driver scrapes.
rewrite_console() {
    local tok out=""
    for tok in $1; do
        case "${tok}" in
            console=tty[A-Za-z]*) continue ;;
        esac
        out="${out:+${out} }${tok}"
    done
    printf '%s console=ttyAMA0,115200\n' "${out}"
}

# ── Resolve the .img (shared autodetect) ────────────────────────────────────
# Artifact prefixes (build-<platform>-stage4.sh ART_PREFIX): frite/jetson/opi5 are
# ${BRAND}-${platform}-${board}-arm64-${role}-${env}-*, zero2 is boardless.
autodetect_img() {
    local d="$1" plat="$2" board="$3" role="$4" c pat_board
    pat_board="${board:+${board}-}"
    for c in \
        "${d}"/*-"${plat}"-"${pat_board}"arm64-"${role}"-*.img \
        "${d}"/*-"${plat}"-*-"${role}"-*.img \
        "${d}"/*-"${plat}"-*.img ; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    ls -1t "${d}"/*.img 2>/dev/null \
        | grep -ivE '(kernel|initramfs|initrd|squashfs)' | head -1 || true
}

# A medium or an eMMC target is a root of its own: the golden .img is optional
# then (and still attached when given).
if [ -z "${IMG}" ] && [ -z "${MEDIUM}" ] && [ -z "${EMMC}" ]; then
    IMG="$(autodetect_img "${WORK_DIR}" "${PLATFORM}" "${BOARD}" "${ROLE}")"
    [ -n "${IMG}" ] && [ -f "${IMG}" ] || die \
        "no golden .img found (pass --img, or build one into ${WORK_DIR}; Frite has media, not .img — pass --medium). platform=${PLATFORM} board=${BOARD} role=${ROLE}"
fi
[ -z "${IMG}" ] || [ -f "${IMG}" ] || die "golden .img not found: ${IMG}"
[ -z "${MEDIUM}" ] || [ -f "${MEDIUM}" ] || die "medium not found: ${MEDIUM}"
[ -z "${EXTLINUX}" ] || [ -f "${EXTLINUX}" ] || die "extlinux.conf not found: ${EXTLINUX}"
[ -z "${INITRD}" ] || [ -f "${INITRD}" ] || die "initrd not found: ${INITRD}"

[ -n "${RUN_DIR}" ] || RUN_DIR="${WORK_DIR}/qemu-run-arm"
OVERLAY="${RUN_DIR}/run.qcow2"
CONSOLE="${RUN_DIR}/console.log"
PIDFILE="${RUN_DIR}/qemu.pid"
mkdir -p "${RUN_DIR}"

# ── Lift the boot tree off the medium (kernel, initrd, extlinux.conf) ────────
# The medium's own extlinux.conf is the authority on how it boots (root=live:...
# rd.live.* for the dmsquash-live squashfs); taking it from the file beats
# re-spelling it here and drifting from the builder.
MEDIUM_KIND=""
if [ -n "${MEDIUM}" ]; then
    MEDIUM_KIND="$(medium_kind "${MEDIUM}")" || die "cannot tell what ${MEDIUM} is (not ISO9660, not MBR+FAT, not FAT)"
    info "medium : ${MEDIUM} (${MEDIUM_KIND}, bus=${MEDIUM_BUS})"
    if [ -z "${EXTLINUX}" ]; then
        medium_extract "${MEDIUM}" "/extlinux/extlinux.conf" "${RUN_DIR}/medium-extlinux.conf" \
            || die "medium ${MEDIUM} carries no /extlinux/extlinux.conf — not a Frite live/installer medium"
        EXTLINUX="${RUN_DIR}/medium-extlinux.conf"
    fi
    if [ -z "${KERNEL}" ]; then
        _linux="$(extlinux_field "${EXTLINUX}" LINUX)"; _linux="${_linux:-/${KERNEL_IMG_NAME}}"
        medium_extract "${MEDIUM}" "${_linux}" "${RUN_DIR}/medium-${KERNEL_IMG_NAME}" \
            || die "medium ${MEDIUM} carries no ${_linux} (extlinux LINUX line)"
        KERNEL="${RUN_DIR}/medium-${KERNEL_IMG_NAME}"
    fi
    if [ -z "${INITRD}" ]; then
        _initrd="$(extlinux_field "${EXTLINUX}" INITRD)"
        if [ -n "${_initrd}" ]; then
            medium_extract "${MEDIUM}" "${_initrd}" "${RUN_DIR}/medium-initrd.img" \
                || die "medium ${MEDIUM}: extlinux names INITRD ${_initrd} but the medium has no such file"
            INITRD="${RUN_DIR}/medium-initrd.img"
        fi
    fi
fi

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
(pass --kernel, or --medium to lift it off a Frite medium). QEMU -M virt boots the mainline kernel directly — no vendor firmware chain."

# ── -dtb is opt-in. An explicit --dtb must exist; the board DTB is never implied. ──
# --virt-dtb (display_argv_test's spelling) states the default out loud: QEMU -M
# virt generates a DTB describing the machine it models (PCIe root, virtio-gpu/
# xhci/serial), which no board DTB can. An explicit --dtb alongside it is a
# contradiction, not a preference.
if ${VIRT_DTB}; then
    [ -z "${DTB}" ] || die "--dtb and --virt-dtb contradict each other (got --dtb ${DTB})"
fi
if [ -n "${DTB}" ]; then
    [ -f "${DTB}" ] || die "DTB not found: ${DTB} (--dtb is an explicit opt-in; the default is QEMU's own virt device tree)"
    warn "--dtb ${DTB}: this REPLACES QEMU's -M virt device tree. A board DTB (${BOARD_DTB}) describes none of virt's hardware — expect no console/disk/NIC unless this DTB really describes virt."
fi

# ── eMMC target preflight (hw/sd/sd.c rules, checked HERE where the caller sees them) ──
EMMC_USER_OFFSET=0
if [ -n "${EMMC}" ]; then
    [ -f "${EMMC}" ] || die "--emmc backing file not found: ${EMMC}"
    [ -w "${EMMC}" ] || die "--emmc ${EMMC} is not writable (QEMU rejects a read-only drive on the sd-bus, and it is the install target)"
    [[ "${EMMC_BOOT_SIZE}" =~ ^[0-9]+$ ]] && [[ "${EMMC_RPMB_SIZE}" =~ ^[0-9]+$ ]] \
        || die "--emmc-boot-size/--emmc-rpmb-size must be byte counts (got: ${EMMC_BOOT_SIZE} / ${EMMC_RPMB_SIZE})"
    [ $(( EMMC_BOOT_SIZE % 131072 )) -eq 0 ] && [ "${EMMC_BOOT_SIZE}" -le $(( 255 * 131072 )) ] \
        || die "--emmc-boot-size ${EMMC_BOOT_SIZE}: QEMU wants a multiple of 128K no larger than 32640K"
    [ $(( EMMC_RPMB_SIZE % 131072 )) -eq 0 ] && [ "${EMMC_RPMB_SIZE}" -le $(( 128 * 131072 )) ] \
        || die "--emmc-rpmb-size ${EMMC_RPMB_SIZE}: QEMU wants a multiple of 128K no larger than 16384K"
    _emmc_bytes="$(stat -c %s "${EMMC}")"
    EMMC_USER_OFFSET=$(( 2 * EMMC_BOOT_SIZE + EMMC_RPMB_SIZE ))
    _user=$(( _emmc_bytes - EMMC_USER_OFFSET ))
    [ "${_user}" -gt 0 ] || die "--emmc ${EMMC} (${_emmc_bytes} bytes) is smaller than its boot+rpmb partitions (${EMMC_USER_OFFSET} bytes)"
    if [ "${_user}" -gt $(( 2 * 1024 * 1024 * 1024 )) ]; then
        [ $(( _user % 512 )) -eq 0 ] || die "--emmc user area (${_user} bytes) must be a multiple of 512"
    else
        [ $(( _user & (_user - 1) )) -eq 0 ] || die "--emmc user area (${_user} bytes, <= 2 GiB) must be a power of 2"
    fi
    qemu-system-aarch64 -device help 2>/dev/null | grep -E '^name "emmc"' >/dev/null \
        || die "this qemu-system-aarch64 has no 'emmc' device (QEMU >= 9.1; the runner image's 7.2 only has sd-card) — run on the host QEMU"
    info "emmc   : ${EMMC} (${_emmc_bytes} bytes; boot0/1 ${EMMC_BOOT_SIZE} each, rpmb ${EMMC_RPMB_SIZE}; user area at +${EMMC_USER_OFFSET})"
fi

info "platform: ${PLATFORM} board:${BOARD:-<none>} role:${ROLE}"
info "img    : ${IMG:-<none>}"
info "kernel : ${KERNEL}"
info "initrd : ${INITRD:-<none>}"
info "dtb    : ${DTB:-<none: QEMU generates the virt DTB> (board FDT name: ${BOARD_DTB})}"
info "run dir: ${RUN_DIR}"

# ── Per-run qcow2 overlay (keeps the golden .img pristine) ───────────────────
# The overlay is DELETED and recreated just below, so --img must never be this
# run's own overlay path — with --img-format qcow2 that would be the save itself.
[ -z "${IMG}" ] || [ "$(readlink -m "${IMG}")" != "$(readlink -m "${OVERLAY}")" ] \
    || die "--img ${IMG} is this run's own overlay path (${OVERLAY}); it would be deleted before boot — point --img at the save, and --run-dir somewhere else"
rm -f "${OVERLAY}"
if [ -n "${IMG}" ]; then
    case "${IMG_FORMAT}" in
        raw)
            step "Creating qcow2 overlay over the golden image (resized to ${OVERLAY_SIZE})"
            qemu-img create -f qcow2 -b "${IMG}" -F raw "${OVERLAY}" >/dev/null
            qemu-img resize "${OVERLAY}" "${OVERLAY_SIZE}" >/dev/null ;;
        qcow2)
            # BOOT FROM A SAVE. The save is a standalone qcow2 (no backing file); it
            # becomes the overlay's READ-ONLY backing, so every guest write lands in
            # ${OVERLAY} and the save itself is never written — the same promise the
            # golden gets. No resize: the save's virtual size IS the overlay size the
            # original run grew it to, and qemu-img refuses to shrink without --shrink.
            [ "$(head -c 4 "${IMG}" | od -An -tx1 | tr -d ' \n')" = "514649fb" ] \
                || die "--img-format qcow2: ${IMG} is not a qcow2 image (no QFI magic) — pass the .qcow2 a save wrote"
            step "Creating qcow2 overlay over the SAVED disk (read-only backing; the save is never written)"
            qemu-img create -f qcow2 -b "${IMG}" -F qcow2 "${OVERLAY}" >/dev/null ;;
    esac
fi

cleanup() {
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

# ── The board's OWN security posture, read from its cmdline.base ──────────────
# We boot with -kernel/-append, so this string REPLACES the image's cmdline
# entirely. That makes a hardcoded posture here actively misleading: this launcher
# used to append `lsm=lockdown,yama,selinux,bpf lockdown=integrity` for ALL eight
# non-Pi boards, when none of them shipped lockdown in its cmdline.base or built
# CONFIG_SECURITY_LOCKDOWN_LSM (they now do, with `lsm=lockdown,yama,selinux` and no
# bpf). Every in-guest LSM/lockdown assertion was therefore grading the harness's
# own literal instead of the image — it could not fail.
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

# ── Kernel cmdline ───────────────────────────────────────────────────────────
# With an extlinux.conf in hand (the medium's, or --extlinux = the installed
# eMMC's own) its DEFAULT label's APPEND is the cmdline, verbatim but for the
# board UART -> ttyAMA0 rewrite: it already carries cmdline.base's posture
# (render_template's APPEND_BASE) plus the root= the image was built to boot —
# root=live:LABEL=FRITE_INSTALL on a medium, root=PARTUUID=<disk>-02 or
# root=/dev/mapper/cryptroot rd.luks.* on an installed eMMC. The FDT line is
# the board's business (u-boot loads it); QEMU never sees it.
# Otherwise: ext4 root on vda2, PL011 console — the golden-.img path, unchanged.
if [ -n "${EXTLINUX}" ]; then
    _append="$(extlinux_field "${EXTLINUX}" APPEND)"
    [ -n "${_append}" ] || die "${EXTLINUX}: no APPEND line under its DEFAULT label"
    _fdt="$(extlinux_field "${EXTLINUX}" FDT)"
    [ -z "${_fdt}" ] || info "extlinux FDT ${_fdt} is the board's (u-boot loads it); not passed to QEMU"
    CMDLINE="$(rewrite_console "${_append}")"
    info "cmdline from ${EXTLINUX}"
else
    CMDLINE="root=${ROOT_PART} rootfstype=ext4 rw rootwait console=ttyAMA0,115200 net.ifnames=0 \
${LSM_APPEND} cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 \
systemd.unified_cgroup_hierarchy=1 slab_nomerge init_on_alloc=1 randomize_kstack_offset=on"
fi
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
    -kernel "${KERNEL}"
)
[ -z "${DTB}" ]    || QEMU_ARGS+=(-dtb "${DTB}")
[ -z "${INITRD}" ] || QEMU_ARGS+=(-initrd "${INITRD}")
QEMU_ARGS+=(-append "${CMDLINE}")
if [ -n "${IMG}" ]; then
    QEMU_ARGS+=(-drive "file=${OVERLAY},format=qcow2,if=none,id=hd0"
                -device virtio-blk-pci,drive=hd0)
fi
QEMU_ARGS+=(
    -netdev "${HOSTFWD}"
    -device virtio-net-pci,netdev=net0
    -pidfile "${PIDFILE}"
)
# --gpu with --display spice is FOLDED into the display door (#955), the way
# launch-x86.sh folds it into virtio-vga: the door below already brings
# virtio-gpu-pci,edid=on + its own qemu-xhci + usb-tablet + usb-kbd, and --gpu's
# devices on top of it gave the guest TWO GPUs (two heads, the viewer showing a
# blank one) and TWO xhci controllers with two keyboards and two tablets.
GPU_DEVICES=${GPU}
[ "${DISPLAY_MODE}" = spice ] && GPU_DEVICES=false
# ONE xhci controller, shared by the USB medium and the --gpu input devices.
NEED_XHCI=false
{ [ -n "${MEDIUM}" ] && [ "${MEDIUM_BUS}" = usb ]; } && NEED_XHCI=true
${GPU_DEVICES} && NEED_XHCI=true
${NEED_XHCI} && QEMU_ARGS+=(-device qemu-xhci,id=xhci)
if [ -n "${MEDIUM}" ]; then
    QEMU_ARGS+=(-drive "file=${MEDIUM},format=raw,if=none,id=medium,readonly=on")
    case "${MEDIUM_BUS}" in
        usb)    QEMU_ARGS+=(-device usb-storage,bus=xhci.0,drive=medium,removable=on) ;;
        virtio) QEMU_ARGS+=(-device virtio-blk-pci,drive=medium) ;;
    esac
fi
if [ -n "${EMMC}" ]; then
    _emmc_dev="emmc,drive=emmc,boot-partition-size=${EMMC_BOOT_SIZE}"
    [ "${EMMC_RPMB_SIZE}" -eq 0 ] || _emmc_dev+=",rpmb-partition-size=${EMMC_RPMB_SIZE}"
    QEMU_ARGS+=(-drive "file=${EMMC},format=raw,if=none,id=emmc"
                -device sdhci-pci,sd-spec-version=3
                -device "${_emmc_dev}")
fi
if ${GPU_DEVICES}; then
    QEMU_ARGS+=(-device virtio-gpu-pci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0)
    info "gpu    : virtio-gpu-pci + usb-kbd + usb-tablet (QMP screendump captures the greeter)"
elif ${GPU}; then
    info "gpu    : --gpu folded into the display door's virtio-gpu-pci,edid=on (no second GPU, xhci, keyboard or tablet)"
fi
if [ -n "${KEYS_IMG}" ]; then
    [ -f "${KEYS_IMG}" ] || die "keys-img not found: ${KEYS_IMG}"
    QEMU_ARGS+=(-drive "file=${KEYS_IMG},format=raw,if=none,id=keys,readonly=on"
                -device virtio-blk-pci,drive=keys)
    info "keys   : ${KEYS_IMG} (attached as a virtio KEYS disk)"
fi
# Optional display door. ONE door: SPICE over TCP on DISPLAY_LISTEN:SPICE_PORT,
# protected by a per-run password that QEMU reads from DISPLAY_SECRET as a secret
# OBJECT (-object secret,file=), so the password never appears in argv, ps, the
# launch log or this script's output — only the file's PATH is printed. The
# vdagent virtserialport is what lets remote-viewer / spicy RESIZE the guest to
# the window (monitors-config); -vnc unix: is the opt-in browser (noVNC)
# fallback, which only scales. The daemonized launch below keeps -display none:
# SPICE/VNC are servers, not a local -display. x86 gets -vga none + virtio-vga
# (VGA-compatible, so OVMF GOP and GRUB render too); aarch64 gets
# virtio-gpu-pci,edid=on. Default-off: without --display the QEMU argv is
# byte-identical to before these flags existed (tests/qemu/display_argv_test.sh).
# Identical across launch-x86.sh / launch-arm.sh / launch-pi.sh apart from
# DISPLAY_GPU_ARGS, which is the per-platform line right above the case.
DISPLAY_GPU_ARGS=(-device virtio-gpu-pci,edid=on)
case "${DISPLAY_MODE}" in
    none)
        [ -z "${SPICE_PORT}" ] && [ -z "${DISPLAY_SECRET}" ] && [ -z "${VNC_SOCK}" ] \
            || die "--spice-port/--display-secret/--vnc-socket make no sense without --display spice"
        ;;
    spice)
        [[ "${SPICE_PORT}" =~ ^[0-9]+$ ]] && [ "${SPICE_PORT}" -ge 1 ] && [ "${SPICE_PORT}" -le 65535 ] \
            || die "--display spice needs --spice-port N (1..65535; got: '${SPICE_PORT}')"
        [ -n "${DISPLAY_SECRET}" ] \
            || die "--display spice needs --display-secret FILE (the per-run password lives in a file, never on the command line)"
        [ -s "${DISPLAY_SECRET}" ] || die "--display-secret file is missing or empty: ${DISPLAY_SECRET}"
        # spice-server's ticket is at most 60 bytes and QEMU 7.2 ignores the
        # set-ticket return, so a longer file would leave the door with NO ticket
        # and every connection refused, silently. Size only; the bytes are never read.
        [ "$(wc -c < "${DISPLAY_SECRET}")" -le 60 ] \
            || die "--display-secret file is longer than SPICE's 60-byte ticket limit: ${DISPLAY_SECRET}"
        [ -n "${DISPLAY_LISTEN}" ] || die "--display-listen must not be empty"
        QEMU_ARGS+=(-object "secret,id=hmdisp,file=${DISPLAY_SECRET},format=raw"
                    -spice "port=${SPICE_PORT},addr=${DISPLAY_LISTEN},password-secret=hmdisp,agent-mouse=on"
                    -device virtio-serial-pci
                    -chardev spicevmc,id=vdagent,name=vdagent
                    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
                    -device qemu-xhci -device usb-tablet -device usb-kbd
                    "${DISPLAY_GPU_ARGS[@]}")
        info "display: spice on ${DISPLAY_LISTEN}:${SPICE_PORT} (password in ${DISPLAY_SECRET})"
        if [ -n "${VNC_SOCK}" ]; then
            mkdir -p "$(dirname "${VNC_SOCK}")" || die "cannot create the --vnc-socket dir for ${VNC_SOCK}"
            # Same AF_UNIX sun_path limit as --qmp below: QEMU rejects longer paths
            # and, daemonized, the error would only ever reach the launch log.
            [ "${#VNC_SOCK}" -le 107 ] || die \
                "--vnc-socket path is ${#VNC_SOCK} bytes; AF_UNIX allows at most 107: ${VNC_SOCK}"
            QEMU_ARGS+=(-object "secret,id=hmvnc,file=${DISPLAY_SECRET},format=raw"
                        -vnc "unix:${VNC_SOCK},password-secret=hmvnc")
            info "display: vnc fallback on unix:${VNC_SOCK} (first 8 chars of the same password; scale-only)"
        fi
        ;;
    *) die "--display must be none or spice (got: ${DISPLAY_MODE})" ;;
esac
# Optional shared mesh L2 (issue #48) — a SECOND virtio NIC on a QEMU socket
# netdev so several emulated nodes form one broadcast domain (kubeadm init on one
# node, kubeadm join from the others; tests/qemu/mesh-cluster.sh is the 3-node
# driver and run-qemu-docker.sh --mesh-net the containerized fleet lane). The
# UDP-multicast form needs NO listener ordering: every node passes the SAME
# ADDR:PORT and joins the group; listen=/connect= is the 2-node point-to-point
# socket alternative. The slirp NIC keeps its hostfwds, so per-node SSH/API
# forwards keep working unchanged. Default-off: without --mesh-net the QEMU argv
# is byte-identical to before these flags existed. Identical to launch-x86.sh's
# block — mixed-arch meshes need the arches to agree flag for flag.
if [ -z "${MESH_NET}" ]; then
    [ -z "${MESH_MAC}" ] && [ -z "${MESH_ID}" ] \
        || die "--mesh-mac/--mesh-id make no sense without --mesh-net"
else
    case "${MESH_NET}" in
        mcast=*:*|listen=*:*|connect=*:*) MESH_NETDEV="socket,id=mesh0,${MESH_NET}" ;;
        *=*) die "--mesh-net mode must be mcast=/listen=/connect= (got: ${MESH_NET})" ;;
        *:*) MESH_NETDEV="socket,id=mesh0,mcast=${MESH_NET}" ;;
        *)   die "--mesh-net wants ADDR:PORT (mcast) or mcast=A:P/listen=H:P/connect=H:P (got: ${MESH_NET})" ;;
    esac
    [ -n "${MESH_MAC}" ] && [ -n "${MESH_ID}" ] \
        && die "give --mesh-mac OR --mesh-id, not both"
    if [ -z "${MESH_MAC}" ]; then
        # Derive a stable locally-administered unicast MAC from the node index
        # (52:54:00 is the QEMU OUI; 6d:65 = "me" for mesh). Two nodes sharing a
        # MAC on the same L2 silently black-hole each other's frames, so the
        # driver hands every node a distinct --mesh-id.
        _mid="${MESH_ID:-1}"
        [[ "${_mid}" =~ ^[0-9]+$ ]] && [ "${_mid}" -ge 1 ] && [ "${_mid}" -le 255 ] \
            || die "--mesh-id must be an integer 1..255 (got: ${MESH_ID})"
        MESH_MAC="$(printf '52:54:00:6d:65:%02x' "${_mid}")"
    fi
    [[ "${MESH_MAC}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] \
        || die "--mesh-mac is not a MAC address: ${MESH_MAC}"
    # A multicast/broadcast MAC (odd first octet) is not a valid NIC address.
    [ $(( 0x${MESH_MAC%%:*} & 1 )) -eq 0 ] \
        || die "--mesh-mac ${MESH_MAC} is a multicast MAC (first octet must be even)"
    QEMU_ARGS+=(-netdev "${MESH_NETDEV}"
                -device "virtio-net-pci,netdev=mesh0,mac=${MESH_MAC}")
    info "mesh   : ${MESH_NETDEV} mac=${MESH_MAC} (shared L2 — emulated nodes see each other)"
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
    # --serial-sock: the guest UART on a unix socket (logfile= keeps console.log
    # byte-for-byte what -serial file: wrote) so a driver can TYPE at the console —
    # the dracut LUKS passphrase prompt of an --encrypt-root install has no other
    # input. Without it: -serial file:, exactly as before.
    if [ -n "${SERIAL_SOCK}" ]; then
        [ "${#SERIAL_SOCK}" -le 107 ] || die "--serial-sock path is ${#SERIAL_SOCK} bytes; AF_UNIX allows at most 107: ${SERIAL_SOCK}"
        mkdir -p "$(dirname "${SERIAL_SOCK}")" || die "cannot create the --serial-sock dir for ${SERIAL_SOCK}"
        SERIAL_ARGS=(-chardev "socket,id=ser0,path=${SERIAL_SOCK},server=on,wait=off,logfile=${CONSOLE}" -serial chardev:ser0)
    else
        SERIAL_ARGS=(-serial "file:${CONSOLE}")
    fi
    qemu-system-aarch64 "${QEMU_ARGS[@]}" \
        -display none "${SERIAL_ARGS[@]}" -monitor none -daemonize
    info "QEMU pid $(cat "${PIDFILE}" 2>/dev/null || echo '?'); console -> ${CONSOLE}"
    info "SSH in with:  ssh -p ${SSH_PORT} <user>@localhost"
    info "Stop with  :  kill \$(cat ${PIDFILE})"
    KEEP=true; trap - EXIT
fi
