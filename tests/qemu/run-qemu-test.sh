#!/usr/bin/env bash
# run-qemu-test.sh — boot a built Gentoo RPi 5 image under qemu-system-aarch64
# (-M virt) with a synthetic FAT32 "KEYS" disk, then assert that first-boot
# provisioning worked: users created from KEYS, sshd up, headscale running,
# the Kubernetes stack present and config staged.
#
# This validates the SOFTWARE stack (rootfs + provisioning + services). It
# does NOT emulate RPi 5 firmware/PCIe — QEMU has no BCM2712 machine. The
# image's kernel carries virtio + PL011 so the SAME Image boots under -M virt.
#
# Designed to run on a Gentoo host. Requires root (loop-mounts + extracts a
# stage4 with xattrs). Tools: qemu-system-aarch64, mkfs.ext4, mkfs.vfat,
# ssh, ssh-keygen, truncate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Defaults ───────────────────────────────────────────────────────
WORK_DIR="${REPO_DIR}/rpi5-stage4-build"
ROLE="pki"
KERNEL=""
STAGE4=""
TEST_DIR=""
MEM="2048"
SMP="2"
SSH_PORT="2222"
# 1800s, not 900: first boot runs provision_selinux()'s full-filesystem setfiles
# relabel before sshd starts (keys-provision is `before sshd`), and that relabel
# is slow under aarch64 TCG emulation. SELinux boots permissive, so the longer
# wait is harmless — it just gives a good image head-room to become reachable.
TIMEOUT="1800"
QEMU_CPU="max"
QEMU_MACHINE="virt,gic-version=3"
KEEP=false
KERNEL_IMG_NAME="kernel_2712.img"

usage() {
cat <<EOF
Usage: sudo $0 [OPTIONS]

  -w, --work-dir DIR   Build work dir to pull artifacts from. Default: ${WORK_DIR}
  -r, --role ROLE      Image role to test (pki|backend|frontend|generic). Default: pki
      --kernel FILE    Kernel Image (default: <work>/isoroot/boot/${KERNEL_IMG_NAME}
                       or <work>/sysroot/boot/${KERNEL_IMG_NAME}).
      --stage4 FILE    stage4 tarball (default: newest matching the role in <work>).
      --test-dir DIR   Scratch dir for VM disks/logs. Default: <work>/qemu-test
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --ssh-port PORT  Host port forwarded to guest :22. Default: ${SSH_PORT}
  -t, --timeout SEC    Max seconds to wait for SSH. Default: ${TIMEOUT}
      --cpu CPU        QEMU -cpu. Default: ${QEMU_CPU}
      --machine M      QEMU -machine. Default: ${QEMU_MACHINE}
      --keep           Don't delete the scratch dir / VM on exit.
  -h, --help           Show this help.
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
        -r|--role)     ROLE="$2"; shift 2 ;;
        --kernel)      KERNEL="$2"; shift 2 ;;
        --stage4)      STAGE4="$2"; shift 2 ;;
        --test-dir)    TEST_DIR="$2"; shift 2 ;;
        -m|--mem)      MEM="$2"; shift 2 ;;
        --smp)         SMP="$2"; shift 2 ;;
        --ssh-port)    SSH_PORT="$2"; shift 2 ;;
        -t|--timeout)  TIMEOUT="$2"; shift 2 ;;
        --cpu)         QEMU_CPU="$2"; shift 2 ;;
        --machine)     QEMU_MACHINE="$2"; shift 2 ;;
        --keep)        KEEP=true; shift ;;
        -h|--help)     usage 0 ;;
        *)             echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info()  { echo "${GREEN}[qemu-test]${RST} $*"; }
step()  { echo "${CYAN}==> $*${RST}"; }
warn()  { echo "${YEL}[qemu-test] WARN:${RST} $*"; }
die()   { echo "${RED}[qemu-test] ERROR:${RST} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (loop-mount + stage4 extraction need it): sudo $0 ..."
for t in qemu-system-aarch64 mkfs.ext4 mkfs.vfat ssh ssh-keygen truncate; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done

# ── Locate artifacts ───────────────────────────────────────────────
[ -n "${TEST_DIR}" ] || TEST_DIR="${WORK_DIR}/qemu-test"
if [ -z "${KERNEL}" ]; then
    # Per-arch build subdir first (snap-build-pi5); bare paths kept as a fallback
    # for trees built before the per-arch split.
    PI_BUILD_SUBDIR="${PI_BUILD_SUBDIR:-snap-build-pi5}"
    for c in "${WORK_DIR}/${PI_BUILD_SUBDIR}/isoroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/${PI_BUILD_SUBDIR}/sysroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/isoroot/boot/${KERNEL_IMG_NAME}" \
             "${WORK_DIR}/sysroot/boot/${KERNEL_IMG_NAME}"; do
        [ -f "${c}" ] && { KERNEL="${c}"; break; }
    done
fi
[ -n "${KERNEL}" ] && [ -f "${KERNEL}" ] || die "kernel Image not found (pass --kernel). Did you build without --skip-kernel?"
if [ -z "${STAGE4}" ]; then
    STAGE4="$(ls -1t "${WORK_DIR}"/stage4-*-"${ROLE}"-k8s-*.tar.xz 2>/dev/null | head -1 || true)"
    [ -n "${STAGE4}" ] || STAGE4="$(ls -1t "${WORK_DIR}"/stage4-*.tar.xz 2>/dev/null | head -1 || true)"
fi
[ -n "${STAGE4}" ] && [ -f "${STAGE4}" ] || die "stage4 tarball not found (pass --stage4)."

info "kernel  : ${KERNEL}"
info "stage4  : ${STAGE4}"
info "test dir: ${TEST_DIR}"

rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
ROOTFS="${TEST_DIR}/rootfs.img"
KEYSIMG="${TEST_DIR}/keys.img"
CONSOLE="${TEST_DIR}/console.log"
SSHKEY="${TEST_DIR}/id_ed25519"
QEMU_PIDFILE="${TEST_DIR}/qemu.pid"

cleanup() {
    [ -f "${QEMU_PIDFILE}" ] && kill "$(cat "${QEMU_PIDFILE}")" 2>/dev/null || true
    umount "${TEST_DIR}/mnt" 2>/dev/null || true
    if ! ${KEEP}; then rm -rf "${TEST_DIR}"; fi
}
trap cleanup EXIT

# ── Test SSH key + KEYS payload ────────────────────────────────────
step "Generating test SSH key + KEYS provisioning payload"
ssh-keygen -t ed25519 -N '' -C tester@qemu -f "${SSHKEY}" >/dev/null
PUBKEY="$(cat "${SSHKEY}.pub")"

KEYS_SRC="${TEST_DIR}/keys"
mkdir -p "${KEYS_SRC}/ssh" "${KEYS_SRC}/headscale"
cp "${REPO_DIR}/specs/etc/headscale/config.yaml" "${KEYS_SRC}/headscale/config.yaml"

cat > "${KEYS_SRC}/users.json" <<EOF
{
  "users": [
    {
      "name": "tester",
      "comment": "QEMU integration test user",
      "groups": ["wheel", "audio", "video", "usb"],
      "shell": "/bin/bash",
      "uid": 1000,
      "sudo": true,
      "sudo_nopasswd": true,
      "ssh_authorized_keys": ["${PUBKEY}"]
    }
  ],
  "root": { "ssh_authorized_keys": ["${PUBKEY}"] }
}
EOF

cat > "${KEYS_SRC}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "snapdragon-test",
  "timezone": "UTC",
  "headscale": { "enabled": true, "config_file": "headscale/config.yaml" },
  "tailscale": { "enabled": false },
  "kubernetes": { "role": "control-plane", "bootstrap": false },
  "snapdragon": { "role": "${ROLE}", "cluster_domain": "snapdragon.local",
                  "gitops": { "enabled": false } }
}
EOF

step "Building FAT32 KEYS image"
"${SCRIPT_DIR}/make-test-keys.sh" "${KEYS_SRC}" "${KEYSIMG}" 64

# ── Root filesystem image ──────────────────────────────────────────
step "Building ext4 rootfs and extracting stage4 (this can take a minute)"
truncate -s 6G "${ROOTFS}"
mkfs.ext4 -q -F "${ROOTFS}"
mkdir -p "${TEST_DIR}/mnt"
mount -o loop "${ROOTFS}" "${TEST_DIR}/mnt"
tar -C "${TEST_DIR}/mnt" --xattrs-include='*.*' -xpf "${STAGE4}" 2>/dev/null || \
    tar -C "${TEST_DIR}/mnt" -xpf "${STAGE4}"

# QEMU-appropriate fstab + serial getty (the on-disk fstab targets mmcblk/NVMe)
cat > "${TEST_DIR}/mnt/etc/fstab" <<'EOF'
/dev/vda   /     ext4    defaults,noatime   0 1
tmpfs      /tmp  tmpfs   defaults,nosuid,nodev,noexec,size=256m 0 0
tmpfs      /run  tmpfs   defaults,nosuid,nodev,mode=0755 0 0
EOF
if ! grep -q ttyAMA0 "${TEST_DIR}/mnt/etc/inittab" 2>/dev/null; then
    echo 's0:12345:respawn:/sbin/agetty -L 115200 ttyAMA0 vt100' >> "${TEST_DIR}/mnt/etc/inittab"
fi
sync
umount "${TEST_DIR}/mnt"

# ── Boot QEMU ──────────────────────────────────────────────────────
step "Booting QEMU (machine=${QEMU_MACHINE}, cpu=${QEMU_CPU}, mem=${MEM}M)"
CMDLINE="root=/dev/vda rw rootwait console=ttyAMA0,115200 net.ifnames=0 \
lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1 \
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 \
systemd.unified_cgroup_hierarchy=1 slab_nomerge"

qemu-system-aarch64 \
    -machine "${QEMU_MACHINE}" -cpu "${QEMU_CPU}" -smp "${SMP}" -m "${MEM}" \
    -nographic -no-reboot \
    -kernel "${KERNEL}" -append "${CMDLINE}" \
    -drive file="${ROOTFS}",format=raw,if=none,id=hd0 -device virtio-blk-pci,drive=hd0 \
    -drive file="${KEYSIMG}",format=raw,if=none,id=keys0 -device virtio-blk-pci,drive=keys0 \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
    -serial "file:${CONSOLE}" -monitor none -pidfile "${QEMU_PIDFILE}" -daemonize

info "QEMU pid $(cat "${QEMU_PIDFILE}" 2>/dev/null || echo '?'); console -> ${CONSOLE}"

# ── Wait for SSH ───────────────────────────────────────────────────
SSH_OPTS=(-i "${SSHKEY}" -p "${SSH_PORT}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
step "Waiting up to ${TIMEOUT}s for SSH (tester@localhost:${SSH_PORT})"
deadline=$((SECONDS + TIMEOUT)); up=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if ! kill -0 "$(cat "${QEMU_PIDFILE}")" 2>/dev/null; then
        warn "QEMU exited early — see console below"; break
    fi
    if ssh "${SSH_OPTS[@]}" tester@localhost true 2>/dev/null; then up=true; break; fi
    sleep 5
done

if ! ${up}; then
    echo "----- last 60 lines of console -----"
    tail -n 60 "${CONSOLE}" 2>/dev/null || true
    die "guest did not become reachable over SSH within ${TIMEOUT}s"
fi
info "SSH is up; running assertions"

# ── Assertions ─────────────────────────────────────────────────────
ssh "${SSH_OPTS[@]}" tester@localhost 'sudo bash -s' < "${SCRIPT_DIR}/assertions.sh"
RESULT=$?

step "Powering down guest"
ssh "${SSH_OPTS[@]}" tester@localhost 'sudo poweroff' 2>/dev/null || true
sleep 3

if [ "${RESULT}" -eq 0 ]; then
    info "${GREEN}INTEGRATION TEST PASSED${RST}"
else
    warn "integration test FAILED (see assertions above and ${CONSOLE})"
fi
exit "${RESULT}"
