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
# emulation) — keep TIMEOUT generous. NOTHING here needs root: the QEMU launch
# never did, and since 2026-08-26 neither does --kernel-from-img, which reads the
# image's FAT boot partition at a byte offset with mtools instead of claiming a
# loop device (see the long note above that block). Only a root-owned WORK_DIR
# can still force a sudo.
#
# ── Shared artifact autodetect convention (mirrors flash-disk.sh) ───────────
# Both launchers and flash-disk.sh resolve the OS .img the same way so one
# WORK_DIR/role selects one artifact everywhere:
#
#   1. --img FILE                     explicit, wins over everything
#   2. ${WORK_DIR}/hugmesh-rpi5-arm64-${ROLE}-*.img   (newest, role match)
#   3. ${WORK_DIR}/hugmesh-rpi5-*.img                 (newest, any role)
#   4. ${WORK_DIR}/*.img (excluding *initramfs*/*kernel*) (newest)
#
# WORK_DIR defaults to ${REPO}/rpi5-stage4-build (same as the build scripts).
# The kernel is taken from <work>/sysroot/boot or <work>/isoroot/boot, matching
# run-qemu-test.sh, or extracted from the image's /boot via --kernel-from-img.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# THE role vocabulary (scripts/_roles-lib.sh) — same declaration the builders read.
# shellcheck source=scripts/_roles-lib.sh
source "${REPO_DIR}/scripts/_roles-lib.sh"

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
QMP_SOCK=""                    # optional QMP unix socket (--qmp); empty keeps -monitor none
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

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Boots the golden aarch64 RPi 5 .img under qemu-system-aarch64 -M virt by
  loading its kernel directly (QEMU has no BCM2712 / RPi UEFI). A per-run qcow2
  overlay protects the golden image and lets growroot demonstrate expansion.

Artifact selection (shared with flash-disk.sh / launch-x86.sh):
  -w, --work-dir DIR   Dir to autodetect the .img/kernel from. Default: ${WORK_DIR}
  -r, --role ROLE      Role to select (pki|backend|frontend|generic|desktop; the
                       old short spellings be/fe are accepted). Default: ${ROLE}
      --img FILE       Explicit golden .img (skips autodetect).
      --kernel FILE    Explicit kernel Image (default: <work>/{sysroot,isoroot}/boot/${KERNEL_IMG_NAME}).
      --kernel-from-img  Extract ${KERNEL_IMG_NAME} from the image's FAT boot
                         partition with mtools, read straight out of the .img at
                         a byte offset. NO root, no loop device, no mount — so it
                         works unprivileged and inside a container.

QEMU / guest:
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --cpu CPU        QEMU -cpu. Default: ${QEMU_CPU}
      --machine M      QEMU -machine. Default: ${QEMU_MACHINE}
      --root PART      root= device for the kernel cmdline. Default: ${ROOT_PART}
      --append STR     Extra kernel cmdline (appended verbatim).
      --overlay-size SZ  qcow2 overlay size (qemu-img resize). Default: ${OVERLAY_SIZE}
      --run-dir DIR    Scratch dir for overlay/pidfile/console. Default: <work>/qemu-run-pi

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

Port forwards (host -> guest):
      --ssh-port PORT  host -> guest 22.   Default: ${SSH_PORT}
      --ui-port PORT   host -> guest 443.  Default: ${UI_PORT}
      --http-port PORT host -> guest 80.   Default: ${HTTP_PORT}
      --api-port PORT  host -> guest 6443. Default: ${API_PORT}
      --hs-port PORT   host -> guest 8080. Default: ${HS_PORT}

Lifecycle:
  -t, --timeout SEC    Boot/SSH wait budget (info only here). Default: ${TIMEOUT}
      --keys-img FILE  Attach a FAT32 "KEYS" disk (provisioning tests).
      --qmp PATH       Listen for QMP on the unix socket PATH (pause/resume/reset/
                       powerdown of the running guest). Omitted => -monitor none.
      --foreground     Run -nographic attached to this terminal (no -daemonize).
      --keep           Don't delete the run dir / overlay on exit.
  -h, --help           Show this help.

Examples:
  $0 --role pki --foreground
  $0 --img /var/tmp/snap/hugmesh-rpi5-arm64-pki-2026.0.img --ui-port 9443
  $0 --kernel-from-img --role backend          # no kernel in WORK_DIR (no sudo needed)
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
        --mesh-net)        MESH_NET="$2"; shift 2 ;;
        --mesh-mac)        MESH_MAC="$2"; shift 2 ;;
        --mesh-id)         MESH_ID="$2"; shift 2 ;;
        --qmp)             QMP_SOCK="$2"; shift 2 ;;
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
    local d="$1"
    local role="$2"
    local c
    local r
    # Canonical spelling first, then every declared alias: an image built as
    # hugmesh-rpi5-arm64-be-… keeps its name and is still the backend image.
    for r in $(hugmesh_role_aliases_of "${role}"); do
        for c in \
            "${d}"/hugmesh-rpi5-*-"${r}"-*.img \
            "${d}"/hugmesh-*-"${r}"-*.img ; do
            c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
            [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
        done
    done
    for c in "${d}"/hugmesh-rpi5-*.img ; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { printf '%s\n' "${c}"; return 0; }
    done
    # Last resort: any *.img that is not a kernel/initramfs blob.
    ls -1t "${d}"/*.img 2>/dev/null \
        | grep -ivE '(kernel|initramfs|initrd|squashfs)' | head -1 || true
}

# ONE normalization point, before anything reads ROLE.
ROLE="$(hugmesh_role_validate "${ROLE}" rpi5)" || exit 1
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

# ── --kernel-from-img: pull the kernel out of the image's boot partition ─────
# WHY THIS IS NO LONGER A LOOP MOUNT (2026-08-26). Until today this block read:
#
#     [ "$(id -u)" -eq 0 ] || die "--kernel-from-img needs root (losetup -P)"
#     LOOP="$(losetup -P --show -f "${IMG}")"
#     mount "${LOOP}p1" "${RUN_DIR}/boot-mnt" || mount "${LOOP}p2" ...
#
# and it could NEVER have worked inside the runner container — not even as root,
# which is what the refusal message implied was enough. `losetup -P` asks the
# KERNEL to scan the partition table, and the kernel materialises the resulting
# /dev/loopNpM nodes on the HOST devtmpfs. A container's /dev is a CREATION-TIME
# SNAPSHOT of the host's device nodes, so a node born after the container started
# never appears inside it: ${LOOP}p1 is simply absent and the mount fails with
# ENOENT. The old code then reported that as "could not mount image boot
# partition", i.e. as a defect in the image. tests/qemu/docker-entrypoint.sh has
# carried a comment saying exactly this directly above its own extractor for as
# long as that extractor has existed; this launcher never got the memo. (The
# sibling fix on docker-entrypoint.sh — the one that made `run-qemu-docker.sh
# --platform rpi5 --jobs 2` stop failing two of three rows — carries the full
# incident write-up, timestamps included.)
#
# The replacement reads the FAT boot partition straight out of the image FILE at
# a byte offset: `mcopy -n -i IMG@@OFFSET ::kernel_2712.img dest`. No loop
# device, no partition node, no mount, no privilege and no host-wide lock — so it
# behaves identically for an unprivileged user on the host and for any user
# inside a container, and any number of extractions can run at once. That is the
# path every image this launcher actually boots takes: the Pi builders put
# kernel_2712.img on the FAT32 boot partition (build-rpi5-stage4.sh /
# specs-rpi5/installer/install.sh).

# Enumerate every partition's (start, size) in 512-byte sectors, one pair per
# line. Shared by BOTH passes below so they can never disagree about which
# partitions exist. Spelled character-for-character as docker-entrypoint.sh's
# partition_offsets(): one image layout, one parse, across launcher and harness.
partition_offsets() {
    sfdisk -d "${IMG}" 2>/dev/null \
        | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*size=[[:space:]]*\([0-9]\+\).*/\1 \2/p'
}

# PASS 1 — mtools. Unprivileged, mountless, lock-free; the only pass that runs
# for a normal Pi image.
extract_kernel_mtools() {
    local want
    want="$1"
    local start size off cand dest
    dest="${RUN_DIR}/${want}"
    # Both binaries or neither: with minfo missing, the FAT probe below would
    # reject EVERY partition and this pass would report "no FAT boot partition"
    # for an image that has one. Fail the pass outright instead, so the caller's
    # diagnostic names the missing package rather than blaming the image.
    command -v mcopy >/dev/null 2>&1 || return 1
    command -v minfo >/dev/null 2>&1 || return 1
    while read -r start size; do
        [ -n "${start}" ] && [ -n "${size}" ] || continue
        [ "${size}" -gt 0 ] 2>/dev/null || continue
        off=$((start * 512))
        # minfo is the cheap "is this even FAT?" probe — it fails on the ext4
        # root partition without touching stdout, so a non-FAT partition costs
        # one header read rather than one failed mcopy per candidate path.
        # PURELY AN OPTIMISATION, and knowingly untested as such: the mutation
        # battery removed this line and the suite stayed green, because without
        # it mcopy simply fails on a non-FAT partition and the loop continues to
        # the next one. It is an equivalent mutant, not a coverage hole.
        MTOOLS_SKIP_CHECK=1 minfo -i "${IMG}@@${off}" >/dev/null 2>&1 || continue
        for cand in "::${want}" "::boot/${want}"; do
            # -n: overwrite the destination without prompting. A non-zero exit is
            # the "try the next candidate" signal (the source path is absent).
            MTOOLS_SKIP_CHECK=1 mcopy -n -i "${IMG}@@${off}" "${cand}" "${dest}" \
                2>/dev/null || continue
            # A ZERO-BYTE result means mcopy "succeeded" on something that is not
            # a kernel. Treat it as a miss: QEMU accepts an empty -kernel without
            # complaint and then simply never boots, which turns a one-second
            # failure here into an unexplained boot timeout ~40 minutes into a
            # TCG run. There is deliberately NO rm here — the single cleanup on
            # the failure path below owns deleting a rejected candidate. An `rm`
            # in both places was the first spelling of this and it made each of
            # the two lines an EQUIVALENT MUTANT of the other: the mutation
            # battery removed either one alone and the suite stayed green,
            # because whichever survived still deleted the same file.
            if [ ! -s "${dest}" ]; then continue; fi
            printf '%s\n' "${dest}"
            return 0
        done
    done < <(partition_offsets)
    # SINGLE cleanup for every way this pass can miss: a rejected zero-byte hit,
    # and — the case the zero-byte guard cannot see — an mcopy that failed PART
    # WAY THROUGH and left a truncated file behind. Leaving either one in RUN_DIR
    # hands the next reader something that looks exactly like a kernel.
    rm -f "${dest}" 2>/dev/null || true
    return 1
}

# PASS 2 — offset mount. ONLY reachable for an image whose boot directory sits on
# a filesystem mtools cannot read (ext4 /boot instead of a FAT boot partition).
# Note it mounts BY BYTE OFFSET rather than via /dev/loopNpM: same result, no
# partition device nodes required, and it therefore behaves identically on the
# host and in a container that HAS a usable loop device. It still needs
# CAP_SYS_ADMIN and a free loop device, so it is strictly a fallback and the
# refusal below spells out why a container may not be able to reach it at all.
extract_kernel_offset_mount() {
    local want
    want="$1"
    local mnt start size dest found
    found=""
    dest="${RUN_DIR}/${want}"
    mnt="${RUN_DIR}/boot-mnt"
    mkdir -p "${mnt}"
    umount "${mnt}" 2>/dev/null || true
    while read -r start size; do
        [ -n "${start}" ] && [ -n "${size}" ] || continue
        [ "${size}" -gt 0 ] 2>/dev/null || continue
        mount -o "ro,offset=$((start * 512)),sizelimit=$((size * 512))" \
              "${IMG}" "${mnt}" 2>/dev/null || continue
        if cp "${mnt}/${want}" "${dest}" 2>/dev/null \
           || cp "${mnt}/boot/${want}" "${dest}" 2>/dev/null; then
            # Same zero-byte rule as PASS 1 — an empty -kernel is a boot timeout
            # dressed up as a mystery, not a kernel.
            if [ -s "${dest}" ]; then found="${dest}"; else rm -f "${dest}"; fi
        fi
        umount "${mnt}" 2>/dev/null || true
        if [ -n "${found}" ]; then break; fi
    done < <(partition_offsets)
    rmdir "${mnt}" 2>/dev/null || true
    [ -n "${found}" ] || return 1
    printf '%s\n' "${found}"
}

if [ "${KERNEL}" = "@from-img@" ]; then
    mkdir -p "${RUN_DIR}"
    command -v sfdisk >/dev/null \
        || die "--kernel-from-img needs sfdisk (util-linux) to read ${IMG}'s partition table"
    step "Extracting ${KERNEL_IMG_NAME} from ${IMG} (mtools at a byte offset — no loop device, no root)"
    KERNEL=""
    if command -v mcopy >/dev/null && command -v minfo >/dev/null; then
        KERNEL="$(extract_kernel_mtools "${KERNEL_IMG_NAME}" || true)"
    else
        warn "mtools (mcopy + minfo) is not installed — the unprivileged FAT pass cannot run"
    fi
    FALLBACK_STATE="did not run (this process is not uid 0)"
    if [ -z "${KERNEL}" ] && [ "$(id -u)" -eq 0 ]; then
        warn "no FAT partition held ${KERNEL_IMG_NAME}; trying the privileged offset mount (non-FAT /boot)"
        KERNEL="$(extract_kernel_offset_mount "${KERNEL_IMG_NAME}" || true)"
        FALLBACK_STATE="ran as root and also failed"
    fi
    [ -n "${KERNEL}" ] || die "could not extract ${KERNEL_IMG_NAME} from ${IMG}.
  * the unprivileged mtools pass found no FAT partition holding ::${KERNEL_IMG_NAME}
    or ::boot/${KERNEL_IMG_NAME} (if 'mcopy' is missing, install mtools — that pass
    is the supported route and it needs no privilege at all);
  * the privileged offset-mount fallback ${FALLBACK_STATE}.
  IN A CONTAINER the fallback is expected to be unusable EVEN AS ROOT, so 'run it
  with sudo' is not the answer here: it needs CAP_SYS_ADMIN and a free loop device,
  and a container's /dev is a creation-time snapshot of the host's, so a loop node
  the kernel creates later never appears inside it. In a container the routes are
  (a) install mtools so the FAT pass above can run, or (b) extract the kernel
  outside and pass it with --kernel."
    info "extracted ${KERNEL} ($(wc -c < "${KERNEL}") bytes)"
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
