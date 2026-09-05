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
# Designed to run on a Gentoo host. Requires root — NOT for a loop mount (the
# rootfs is built with `mkfs.ext4 -d` since 2026-08-26; see build_rootfs()) but
# because unpacking a stage4 with its ownership and its security.* xattrs
# intact needs CAP_CHOWN + CAP_SYS_ADMIN. Tools: qemu-system-aarch64,
# mkfs.ext4 and debugfs (e2fsprogs >= 1.43, for -d), mkfs.vfat, ssh,
# ssh-keygen, truncate, tar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# THE role vocabulary (scripts/_roles-lib.sh) — the same declaration the builders
# read. It is already concatenated into the GUEST-side assertion bundle below; the
# HOST side needs it too, because the stage4 auto-pick globs on the role token.
# shellcheck source=scripts/_roles-lib.sh
source "${REPO_DIR}/scripts/_roles-lib.sh"

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

[ "$(id -u)" -eq 0 ] || die "run as root (the stage4 untar needs to restore ownership and security.* xattrs): sudo $0 ..."
# debugfs is required, not optional: it is how build_rootfs() asserts POSTCONDITIONS
# on the finished image (populated? labelled?) without mounting it. Dropping it to a
# "skip if missing" would put the vacuous pass back exactly where it was.
for t in qemu-system-aarch64 mkfs.ext4 debugfs mkfs.vfat ssh ssh-keygen truncate tar; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done

# ── Locate artifacts ───────────────────────────────────────────────
# Absolutize user-supplied paths: helpers (make-test-keys.sh) and long-running
# subshells must not depend on the invocation cwd for relative -w/--stage4.
WORK_DIR="$(readlink -f "${WORK_DIR}")"
[ -n "${STAGE4}" ] && STAGE4="$(readlink -f "${STAGE4}")"
[ -n "${KERNEL}" ] && KERNEL="$(readlink -f "${KERNEL}")"
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
# autodetect_stage4 <work-dir> <role> — the stage4 tarball for a role.
#
# A function, not an inline block, so tests/scripts/test-role-key-spelling.sh can
# extract and exercise the real body the way it already does for the launchers'
# autodetect_img.
#
# hugmesh_role_shadow_filter is not optional here either: `-${role}-` is a PREFIX
# match, so `-backend-` also matches …-backend-gpu-….stage4.tar.xz, and this
# globber is unanchored (no platform token) and mtime-ordered — a work dir that
# also holds an x86 GPU build hands the GPU stage4 to a `--role backend` run.
autodetect_stage4() {
    local _w
    _w="$1"
    local _role
    _role="$2"
    local _s
    _s="$(ls -1t "${_w}"/stage4-*-"${_role}"-k8s-*.tar.xz 2>/dev/null | hugmesh_role_shadow_filter "${_role}" | head -1 || true)"
    # Current builder naming: <brand>-rpi5-arm64-<role>-<env>-<ts>.stage4.tar.xz
    # (also look one level up: images land in the -w parent, sysroot in <work>).
    local _d
    for _d in "${_w}" "${_w}/.."; do
        [ -n "${_s}" ] && break
        _s="$(ls -1t "${_d}"/*-"${_role}"-*.stage4.tar.xz 2>/dev/null | hugmesh_role_shadow_filter "${_role}" | head -1 || true)"
    done
    # Role-BLIND last resort: it has already given up on the role, so it is not
    # filtered.
    [ -n "${_s}" ] || _s="$(ls -1t "${_w}"/stage4-*.tar.xz 2>/dev/null | head -1 || true)"
    printf '%s\n' "${_s}"
}

if [ -z "${STAGE4}" ]; then
    STAGE4="$(autodetect_stage4 "${WORK_DIR}" "${ROLE}")"
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
    # No umount here any more: build_rootfs() mounts nothing, so there is no
    # loop device and no mountpoint to unwind. The old `umount ${TEST_DIR}/mnt
    # || true` was also the reason a leaked loop device stayed leaked — it hid
    # its own failure.
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

# THE PAYLOAD MUST BE ROLE-ACCURATE. This block hardcoded enabled:true for EVERY
# role, while the product links headscale into the default runlevel ONLY for the
# identity/control roles — rpi5 pki|generic (build-rpi5-stage4.sh:3980-3982) and
# x86 pki|omnibus — and explicitly `rm -f`s the symlink for every other role
# (build-rpi5-stage4.sh:4044). So `--role backend` asked for a service the image
# is designed not to run, which failed the headscale assertions on all four rpi5
# rows (matrix triage 2026-08-13) and now also false-FAILs assertions.sh's
# role/manifest cross-check on a PERFECTLY CORRECT backend image. Same derivation
# docker-entrypoint.sh:787-790 has carried since that triage.
HS_ENABLED=false
case "${ROLE}" in
    pki|generic|omnibus) HS_ENABLED=true ;;
esac

cat > "${KEYS_SRC}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "hugmesh-test",
  "timezone": "UTC",
  "headscale": { "enabled": ${HS_ENABLED}, "config_file": "headscale/config.yaml" },
  "tailscale": { "enabled": false },
  "kubernetes": { "role": "control-plane", "bootstrap": false },
  "hugmesh": { "role": "${ROLE}", "cluster_domain": "hugmesh.local",
                  "gitops": { "enabled": false } }
}
EOF

step "Building FAT32 KEYS image"
"${SCRIPT_DIR}/make-test-keys.sh" "${KEYS_SRC}" "${KEYSIMG}" 64

# ── Root filesystem image ──────────────────────────────────────────
# NO LOOP MOUNT, DELIBERATELY. Until 2026-08-26 this section was three
# unchecked commands in a row:
#
#     mkfs.ext4 -q -F "${ROOTFS}"
#     mount -o loop "${ROOTFS}" "${TEST_DIR}/mnt"
#     tar -C "${TEST_DIR}/mnt" --xattrs-include='*.*' -xpf "${STAGE4}" 2>/dev/null || \
#         tar -C "${TEST_DIR}/mnt" -xpf "${STAGE4}"
#
# with no `|| die` on any of them, no lock and no retry around the loop
# allocation, and it then HELD that loop device for the entire boot + assert
# window (TIMEOUT defaults to 1800s). /dev/loop* is a global, HOST-wide
# resource even from inside a container: run-qemu-docker.sh fans several rows
# out at once into --privileged containers that all share the host's loop
# devices. A `mount` that lost that race did not stop anything — the tar then
# landed in ${TEST_DIR}/mnt on the CONTAINER's own filesystem, the rootfs image
# stayed the empty ext4 mkfs had just made, and the guest failed to boot for
# reasons that pointed nowhere near this line.
#
# mkfs.ext4 -d populates the filesystem straight from a staging DIRECTORY, so
# stage4 mode needs no loop device at all. -d landed in e2fsprogs 1.43 (2016)
# and copies extended attributes along with the files it walks
# (misc/create_inode.c, set_inode_xattr) — that is what carries the stage4's
# security.selinux labels into the image. docker/Dockerfile.qemu-runner
# installs Debian bookworm's e2fsprogs (1.47.0); the gate below refuses loudly
# on anything older rather than producing an empty rootfs and a mystery boot
# failure. The trade is peak disk: the staging tree and the image both exist
# for the duration of the mkfs, so the tree is deleted the moment the
# postconditions have passed.

# build_rootfs ROOTFS_IMG STAGE4_TARBALL STAGING_DIR
# Fabricates ${ROOTFS_IMG} from ${STAGE4_TARBALL} without mounting anything.
# Every step is checked; every failure is fatal and named.
build_rootfs() {
    # bash 5.3 localises every name in a `local a=$1 b=$a` list BEFORE assigning
    # any of them, so a later name referring to an earlier one dies under set -u
    # (green on CI's bash 5.2, dead on this box). Declare, then assign.
    local rootfs
    local stage4
    local stage
    local xlog
    local mkfs_v
    local probe
    local ea
    rootfs="$1"
    stage4="$2"
    stage="$3"
    xlog="${stage}-extract.log"

    mkfs_v="$(mkfs.ext4 -V 2>&1 | sed -n 's/^mke2fs \([0-9][0-9.]*\).*$/\1/p' | head -1)"
    [ -n "${mkfs_v}" ] || die "could not read the e2fsprogs version from 'mkfs.ext4 -V'"
    [ "$(printf '1.43\n%s\n' "${mkfs_v}" | sort -V | head -1)" = "1.43" ] \
        || die "e2fsprogs ${mkfs_v} is too old for 'mkfs.ext4 -d' (need >= 1.43). Upgrade sys-fs/e2fsprogs; do NOT reintroduce loop-mounting here."

    rm -rf "${stage}"
    mkdir -p "${stage}" || die "cannot create staging dir ${stage}"

    # THE XATTR TAR'S STDERR IS NOT DISCARDED ANY MORE. It used to be `2>/dev/null
    # || <plain tar>`, so a stage4 extracted WITHOUT its security.selinux labels
    # looked exactly like a successful one — and the ~10 SELinux assertions in
    # assertions.sh then graded that unlabelled rootfs and passed it. The plain
    # tar is still the last-ditch fallback (a rootfs with no labels still boots
    # and still exercises provisioning), but it is now impossible to reach
    # quietly: the reason tar gave is replayed to stderr and the run is marked.
    info "extracting stage4 into ${stage} (xattrs preserved)"
    STAGE4_XATTRS=yes
    if ! tar -C "${stage}" --xattrs-include='*.*' -xpf "${stage4}" 2>"${xlog}"; then
        STAGE4_XATTRS=no
        warn "XATTR-PRESERVING EXTRACTION FAILED — falling back to a PLAIN untar."
        warn "The resulting rootfs will carry NO security.selinux labels, and the"
        warn "SELinux assertions are graded against a rootfs-is-labelled"
        warn "precondition (tests/qemu/assertions.sh) that will FAIL on it."
        warn "tar said:"
        sed -n '1,40p' "${xlog}" >&2
        tar -C "${stage}" -xpf "${stage4}" \
            || die "plain stage4 extraction failed too — see ${xlog}"
    elif [ -s "${xlog}" ]; then
        # Succeeded, but said something. Non-fatal tar warnings have preceded
        # real damage here before; they are shown, never swallowed.
        warn "stage4 extraction succeeded with warnings:"
        sed -n '1,40p' "${xlog}" >&2
    fi

    # QEMU-appropriate fstab + serial getty (the on-disk fstab targets mmcblk/NVMe).
    # mkdir -p first and `|| die` after: with errexit on, a tarball that unpacked
    # without an /etc would otherwise abort the whole script on a bare redirection
    # error with no diagnosis attached to it.
    mkdir -p "${stage}/etc" || die "cannot create ${stage}/etc"
    cat > "${stage}/etc/fstab" <<'EOF'
/dev/vda   /     ext4    defaults,noatime   0 1
tmpfs      /tmp  tmpfs   defaults,nosuid,nodev,noexec,size=256m 0 0
tmpfs      /run  tmpfs   defaults,nosuid,nodev,mode=0755 0 0
EOF
    [ -s "${stage}/etc/fstab" ] || die "failed to write the QEMU fstab into ${stage}"
    # grep -q on a FILE ARGUMENT has no upstream pipeline stage, so the
    # pipefail/SIGPIPE coin-flip that has bitten this repo does not apply here.
    if ! grep -q ttyAMA0 "${stage}/etc/inittab" 2>/dev/null; then
        echo 's0:12345:respawn:/sbin/agetty -L 115200 ttyAMA0 vt100' >> "${stage}/etc/inittab"
    fi

    # Env seam (ROOTFS_SIZE), same shape as the SELINUX_* seams in
    # assertions.sh: tests/qemu/stage4_rootfs_test.sh drives build_rootfs() for
    # real against tiny fixtures, and a 6G sparse image per mutation leg would
    # cost real metadata blocks on a box whose / is the tightest mount here.
    # In the guest path the default is always what runs.
    truncate -s "${ROOTFS_SIZE:-6G}" "${rootfs}" || die "truncate failed for ${rootfs}"
    # Same mkfs options as the old path (-q -F) plus -d: the inode budget and
    # every other default are unchanged, so a stage4 that fit before still fits.
    mkfs.ext4 -q -F -d "${stage}" "${rootfs}" \
        || die "mkfs.ext4 -d failed to build ${rootfs} from ${stage} (out of space or inodes?)"

    # ── Postconditions on the RENDERED IMAGE, not on mkfs's exit code ───────
    # mkfs.ext4 exits 0 for an empty filesystem just as happily as for a
    # populated one, so "it returned success" says nothing. debugfs reads the
    # image directly (no mount, no loop), which makes these assertions about the
    # artefact that is about to be booted rather than about a renderer's rc.
    #
    # TWO SEPARATE FACTS ARE ASSERTED, because either one alone is weak:
    #  1. /etc/fstab is in there  — proves mkfs -d copied the staging tree at all.
    #     On its own it proves nothing about the TARBALL: this function writes
    #     that fstab itself, so it exists even when the stage4 unpacked nowhere.
    #  2. a file that can only have come OUT of the stage4 is in there. A list,
    #     not a single path: /sbin may be a usrmerge symlink and the init
    #     implementation differs across roles, so pinning one name would turn a
    #     healthy image into a fatal error. Missing EVERY one of them is the
    #     failure this catches — an image holding only what we wrote into it.
    probe="$(debugfs -R 'stat /etc/fstab' "${rootfs}" 2>/dev/null || true)"
    printf '%s\n' "${probe}" | grep -E '^Inode: [0-9]+' >/dev/null \
        || die "rootfs postcondition FAILED: /etc/fstab is not in ${rootfs} — mkfs.ext4 -d copied nothing at all."
    local found
    found=""
    for probe in ${ROOTFS_PROBE_PATHS:-/sbin/init /usr/sbin/init /bin/sh /bin/bash /etc/passwd /etc/shadow}; do
        if debugfs -R "stat ${probe}" "${rootfs}" 2>/dev/null | grep -E '^Inode: [0-9]+' >/dev/null; then
            found="${probe}"; break
        fi
    done
    [ -n "${found}" ] \
        || die "rootfs postcondition FAILED: ${rootfs} contains NONE of ${ROOTFS_PROBE_PATHS:-/sbin/init /usr/sbin/init /bin/sh /bin/bash /etc/passwd /etc/shadow} — the image holds only what this script wrote into it, so the stage4 never landed. Do not boot it."

    # The SELinux labels are the whole reason this extraction preserves xattrs.
    # Checked on the stage4-owned file found above, never on /etc/fstab — that
    # one this script writes itself and it says nothing about the tarball.
    ea="$(debugfs -R "ea_list ${found}" "${rootfs}" 2>/dev/null || true)"
    if printf '%s\n' "${ea}" | grep -F 'security.selinux' >/dev/null; then
        info "rootfs carries security.selinux (checked on ${found} via debugfs ea_list)"
    else
        warn "ROOTFS IS UNLABELLED: no security.selinux on ${found} in ${rootfs}"
        warn "(xattr tar path: ${STAGE4_XATTRS}). The guest's SELinux assertions"
        warn "are gated on a rootfs-is-labelled precondition and will FAIL loudly"
        warn "rather than passing vacuously against an unlabelled tree."
    fi

    # Reclaim the staging tree now — it is a second full copy of the rootfs and
    # nothing after this point reads it. --keep leaves it for post-mortems.
    if ! ${KEEP}; then rm -rf "${stage}"; fi
}

step "Building ext4 rootfs from stage4 (no loop device; this can take a minute)"
build_rootfs "${ROOTFS}" "${STAGE4}" "${TEST_DIR}/rootfs-stage"

# ── Boot QEMU ──────────────────────────────────────────────────────
step "Booting QEMU (machine=${QEMU_MACHINE}, cpu=${QEMU_CPU}, mem=${MEM}M)"
CMDLINE="root=/dev/vda rw rootwait console=ttyAMA0,115200 net.ifnames=0 \
lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1 \
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 \
systemd.unified_cgroup_hierarchy=1 slab_nomerge"

qemu-system-aarch64 \
    -machine "${QEMU_MACHINE}" -cpu "${QEMU_CPU}" -smp "${SMP}" -m "${MEM}" \
    -display none -no-reboot \
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
# The role vocabulary rides IN FRONT of the assertions: assertions.sh is piped into
# the guest and has nothing to source there, and its role-topology section must fold
# an older image's `be`/`fe`/`be+gpu` marker rather than reject it.
cat "${SCRIPT_DIR}/../../scripts/_roles-lib.sh" "${SCRIPT_DIR}/assertions.sh" \
    | ssh "${SSH_OPTS[@]}" tester@localhost 'sudo bash -s' 
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
