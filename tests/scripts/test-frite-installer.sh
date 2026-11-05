#!/usr/bin/env bash
# test-frite-installer.sh — specs-frite/installer/install-frite.sh EXECUTED end to
# end against fixtures (eMMC install correctness + unattended mode).
#
# THE DEFECTS (2026-11-04 desktop map). The Frite installer could not put a
# self-booting system on the eMMC: no unattended mode (a `read` confirm plus LUKS
# prompts), the target taken verbatim (a partition, mmcblk0boot0, a mounted disk
# or the live medium itself were all accepted), no wipe of stale signatures and
# no verified MBR disk id although root= relies on PARTUUID=<diskid>-02, a
# `tar --xattrs ... 2>/dev/null || tar` that silently re-extracted WITHOUT labels,
# a boot-tree copy under `2>/dev/null || true` with a fallback to the live /boot
# (which has no DTB and no extlinux), root=/fstab rewrites that were skipped
# silently when blkid returned nothing, and no way to put u-boot into the eMMC
# user area on Le Potato / Sweet Potato.
#
# WHAT RUNS HERE. The real installer, as root (`id` stubbed), with the block tools
# it drives stubbed on PATH (lsblk, findmnt, wipefs, mkfs.*, mount, umount,
# cryptsetup, blkid, partprobe, udevadm) and the tools whose output matters REAL:
# sfdisk writes the real MBR into a sparse disk file, dd writes the real u-boot
# bytes, GNU tar extracts the real stage4 with its xattrs, getfattr/python3/tar
# probe the real label (user.selinux stands in for security.selinux through the
# FRITE_LABEL_XATTR seam, because this process cannot write security.*). Each
# stub appends its argv to a log, so ORDER is asserted (wipe before table before
# u-boot...), not prose.
#
# Sections:
#   A  happy paths: plaintext auto-detected eMMC, encrypted with --luks-pass,
#      attended confirm typed / refused
#   B  refusals, each BEFORE anything is written: partition, boot0, rpmb, mounted,
#      swap, the live medium (partition source and whole-disk source), no/too many
#      MMC disks, encrypted unattended without a passphrase, missing boot files
#   C  the write path: tar failure aborts and cleans up; unlabelled stage4 gets
#      /.autorelabel, a labelled one does not; unreadable or stale PARTUUIDs abort;
#      a fstab the rewrite cannot reach aborts; u-boot lands at the Amlogic offset
#      and an oversized blob is refused
#   D  OFFLINE LAYOUT PROOF with real tools: sfdisk -d of the written MBR (8 MiB
#      p1, bootable, type c/83, non-zero id), a real FAT built at p1's offset with
#      mtools holding every file extlinux names, a real ext4 of the root tree
#      whose fstab/xattrs read back with debugfs
#   E  mutation battery: fifteen defects planted in a COPY of the installer, each
#      must turn the scenario that covers it RED (cmp proves each copy changed)
#
# Needs: bash, GNU tar, xz, sfdisk + od + awk, python3 (label probe fallback),
# mtools + e2fsprogs (debugfs) for D. setfattr for the labelled lanes (loud SKIP
# otherwise). No root, no loop devices, no network. Exits 2 when a REQUIRED tool
# is absent rather than passing vacuously.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INST="${FRITE_INSTALLER:-${REPO}/specs-frite/installer/install-frite.sh}"
TMPL="${REPO}/specs-frite/boot/extlinux.conf.tmpl"
CMDLINE="${REPO}/specs-frite/boot/cmdline.base"
FSTAB_SPEC="${REPO}/specs-frite/etc/fstab"

P=0; F=0; S=0
ok()   { echo "  PASS $*"; P=$((P+1)); }
bad()  { echo "  FAIL $*"; F=$((F+1)); }
skip() { echo "  SKIP $* (NOT counted as a pass)"; S=$((S+1)); }

for f in "${INST}" "${TMPL}" "${CMDLINE}" "${FSTAB_SPEC}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
    if [ "$(tr -d '\000' < "${f}" | wc -c)" -ne "$(wc -c < "${f}")" ]; then
        echo "  FAIL ${f#"${REPO}"/} contains a NUL byte — grep would fail open on it"; exit 1
    fi
done
missing=""
for b in bash tar xz sfdisk od awk python3 dd cmp sed; do command -v "$b" >/dev/null 2>&1 || missing="${missing} $b"; done
tar --version 2>/dev/null | head -1 | grep -F 'GNU tar' >/dev/null || missing="${missing} GNU-tar"
[ -z "${missing}" ] || { echo "  SKIPPED-LOUDLY: required tool(s) absent:${missing} — this guard checked NOTHING"; exit 2; }
bash -n "${INST}" || { echo "  FAIL ${INST} does not parse"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
REAL_SFDISK="$(command -v sfdisk)"; REAL_DD="$(command -v dd)"
export REAL_SFDISK REAL_DD

# ── Can this filesystem carry user.* xattrs? (the labelled lanes need it) ─────
HAVE_XATTR=false
if command -v setfattr >/dev/null 2>&1 && : > "${TMP}/xprobe" && setfattr -n user.selinux -v t "${TMP}/xprobe" 2>/dev/null; then
    HAVE_XATTR=true
fi

# ── Stubs ────────────────────────────────────────────────────────────────────
STUB="${TMP}/stub"; mkdir -p "${STUB}"
LOG="${TMP}/calls.log"
logcall() { printf '%s %s\n' "$(basename "$0")" "$*" >> "${STUB_LOG}"; }
export -f logcall
# All of these only record their argv.
for t in wipefs partprobe udevadm sync sleep mkfs.vfat mkfs.ext4 mount umount; do
    printf '#!/usr/bin/env bash\nlogcall "$@"\nexit 0\n' > "${STUB}/${t}"
done
cat > "${STUB}/id" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOS
# lsblk: driven by STUB_LSBLK_TABLE, lines "<name> <type> <pkname|-> <mountpoint|->"
cat > "${STUB}/lsblk" <<'EOS'
#!/usr/bin/env bash
logcall "$@"
cols=""; dev=""; nodeps=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) cols="$2"; shift 2 ;;
        -*o*) cols="$2"; case "$1" in *d*) nodeps=1 ;; esac; shift 2 ;;
        -d*) nodeps=1; shift ;;
        -*) shift ;;
        *) dev="$1"; shift ;;
    esac
done
name="$(basename "${dev}")"
tbl="${STUB_LSBLK_TABLE}"
case "${cols}" in
    TYPE)        awk -v n="${name}" '$1==n {print $2}' "${tbl}" ;;
    PKNAME)      awk -v n="${name}" '$1==n && $3!="-" {print $3}' "${tbl}" ;;
    MOUNTPOINTS|MOUNTPOINT)
                 awk -v n="${name}" '($1==n || $3==n) && $4!="-" {print $4}' "${tbl}" ;;
    NAME)        if [ "${nodeps}" = 1 ]; then printf '%s\n' "${dev}"; else
                     printf '%s\n' "${dev}"; awk -v n="${name}" -v d="${FRITE_DEV_DIR}" '$3==n {print d "/" $1}' "${tbl}"; fi ;;
    NAME,SIZE,TYPE,RM,MODEL)
                 awk -v d="${FRITE_DEV_DIR}" '$3=="-" {printf "%s/%s 7.3G %s 0 fixture\n", d, $1, $2}' "${tbl}" ;;
    *) echo "lsblk stub: unhandled columns '${cols}'" >&2; exit 1 ;;
esac
EOS
cat > "${STUB}/findmnt" <<'EOS'
#!/usr/bin/env bash
logcall "$@"
[ -n "${STUB_LIVE_SRC:-}" ] && printf '%s\n' "${STUB_LIVE_SRC}"
exit 0
EOS
cat > "${STUB}/sfdisk" <<'EOS'
#!/usr/bin/env bash
logcall "$@"
if [ "${STUB_SFDISK_DROP_ID:-0}" = 1 ]; then
    grep -v '^label-id' | "${REAL_SFDISK}" "$@"      # a table whose id the script did not choose
else
    exec "${REAL_SFDISK}" "$@"
fi
EOS
cat > "${STUB}/dd" <<'EOS'
#!/usr/bin/env bash
logcall "$@"
exec "${REAL_DD}" "$@"
EOS
cat > "${STUB}/cryptsetup" <<'EOS'
#!/usr/bin/env bash
logcall "$@"
case "$1" in
    luksFormat) cat >/dev/null ;;
    open)  cat >/dev/null; : > "${FRITE_DM_DIR}/cryptroot" ;;
    close) rm -f "${FRITE_DM_DIR}/cryptroot" ;;
esac
exit 0
EOS
# blkid: PARTUUID is DERIVED from the disk file's real MBR bytes (as the kernel
# would), UUIDs are fixed per device. STUB_BLKID_EMPTY=1 answers nothing;
# STUB_BLKID_STALE=1 answers from a "cache" (a previous disk's id) — and a call
# WITHOUT `-c /dev/null` always answers from that cache.
cat > "${STUB}/blkid" <<'EOS'
#!/usr/bin/env bash
logcall "$@"
tag=""; dev=""; nocache=0
while [ $# -gt 0 ]; do
    case "$1" in
        -c) [ "$2" = /dev/null ] && nocache=1; shift 2 ;;
        -s) tag="$2"; shift 2 ;;
        -o) shift 2 ;;
        *) dev="$1"; shift ;;
    esac
done
[ "${STUB_BLKID_EMPTY:-0}" = 1 ] && exit 2
name="$(basename "${dev}")"
case "${tag}" in
    PARTUUID)
        disk="${name%p[0-9]*}"; n="${name##*p}"
        if [ "${nocache}" = 1 ] && [ "${STUB_BLKID_STALE:-0}" != 1 ]; then
            id="$(od -An -tx1 -j440 -N4 "${FRITE_DEV_DIR}/${disk}" | awk '{printf "%s%s%s%s", $4, $3, $2, $1}')"
        else
            id="deadbeef"
        fi
        printf '%s-%02d\n' "${id}" "${n}" ;;
    UUID)
        case "${name}" in
            cryptroot) echo "0f0f0f0f-1111-2222-3333-444444444444" ;;
            *p2)       echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ;;
            *)         exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
EOS
chmod +x "${STUB}"/*

# ── Fixtures ─────────────────────────────────────────────────────────────────
DTB_REL="amlogic/meson-gxl-s805x-libretech-ac.dtb"
render_extlinux() {   # <out> <initrd-line> — the real template + cmdline.base, rendered as the builder does
    local out="$1" initrd="$2"
    sed -e "s|@@FRITE_KERNEL_IMG@@|Image|g" -e "s|@@FRITE_DTB@@|${DTB_REL}|g" \
        -e "s|@@BRAND_TITLE@@|Fixture|g" -e "s|@@FRITE_INITRD_LINE@@|${initrd}|" \
        -e "s|@@FRITE_APPEND@@|$(cat "${CMDLINE}") root=LABEL=FRITE_ROOT|" "${TMPL}" > "${out}"
}
# make_tree <dir> <labelled yes|no> <encrypted yes|no> [fstab-variant]
make_tree() {
    local dir="$1" labelled="$2" enc="$3" fstab="${4:-spec}" sys="${TMP}/sysroot-$$"
    rm -rf "${dir}" "${sys}"; mkdir -p "${dir}"/{stage4,boot/extlinux,boot/dtb/amlogic,uboot} "${sys}"/{usr/bin,etc,bin}
    printf '#!/bin/sh\nexit 0\n' > "${sys}/usr/bin/init"; chmod +x "${sys}/usr/bin/init"
    printf 'hello\n' > "${sys}/bin/hello"
    case "${fstab}" in
        spec)     cp "${FSTAB_SPEC}" "${sys}/etc/fstab" ;;
        nolabels) printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${sys}/etc/fstab" ;;
        rootonly) grep -v '^LABEL=FRITE_BOOT' "${FSTAB_SPEC}" > "${sys}/etc/fstab" ;;
    esac
    if [ "${labelled}" = yes ]; then
        setfattr -n user.selinux -v 'system_u:object_r:init_exec_t:s0' "${sys}/usr/bin/init"
        setfattr -n user.selinux -v 'system_u:object_r:bin_t:s0' "${sys}/bin/hello"
    fi
    tar -C "${sys}" --xattrs --xattrs-include='*.*' -cJf "${dir}/stage4/fixture.stage4.tar.xz" .
    head -c 65536 /dev/urandom > "${dir}/boot/Image"
    head -c 4096 /dev/urandom > "${dir}/boot/dtb/${DTB_REL}"
    if [ "${enc}" = yes ]; then
        head -c 8192 /dev/urandom > "${dir}/boot/initrd.img"
        : > "${dir}/encrypt-root"
        render_extlinux "${dir}/boot/extlinux/extlinux.conf" "    INITRD /initrd.img"
    else
        render_extlinux "${dir}/boot/extlinux/extlinux.conf" "    # (installed system boots a real partitioned rootfs)"
    fi
    cp "${INST}" "${dir}/install-frite.sh"; chmod +x "${dir}/install-frite.sh"
    rm -rf "${sys}"
}
# make_env: a fresh sysfs/proc/dev/mnt world per run
ENV_ROOT=""; DEVDIR=""; SYSFS=""; PROCD=""; MNTD=""; DMD=""; LSBLK_TABLE=""
DISK_MIB=288; DISK_SECTORS=$((DISK_MIB * 2048))
make_env() {
    ENV_ROOT="${TMP}/env"; rm -rf "${ENV_ROOT}"
    DEVDIR="${ENV_ROOT}/dev"; SYSFS="${ENV_ROOT}/sys"; PROCD="${ENV_ROOT}/proc"; MNTD="${ENV_ROOT}/mnt"; DMD="${ENV_ROOT}/dev/mapper"
    mkdir -p "${DEVDIR}" "${DMD}" "${SYSFS}/block" "${SYSFS}/class/block" "${PROCD}/device-tree" "${MNTD}"
    # La Frite-like: mmcblk0 is the eMMC (MMC) with boot0/boot1/rpmb; sda is the USB stick the live session booted from.
    # Only the install target needs the real layout (p1 8..264 MiB + a root tail):
    # DISK_MIB sparse. The rest are refused before any byte is read, so they stay
    # tiny — on a filesystem without sparse files (eCryptfs) a 1 GiB truncate is
    # a 1 GiB write.
    for d in mmcblk0 mmcblk0boot0 mmcblk0boot1 mmcblk0rpmb sda; do
        mkdir -p "${SYSFS}/block/${d}/device"
        truncate -s 1M "${DEVDIR}/${d}"
    done
    truncate -s "${DISK_MIB}M" "${DEVDIR}/mmcblk0"
    echo MMC > "${SYSFS}/block/mmcblk0/device/type"
    for p in mmcblk0p1 mmcblk0p2 sda1; do mkdir -p "${SYSFS}/class/block/${p}"; : > "${SYSFS}/class/block/${p}/partition"; : > "${DEVDIR}/${p}"; done
    printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n' > "${PROCD}/swaps"
    printf 'libretech,aml-s805x-ac\0amlogic,s805x\0amlogic,meson-gxl\0' > "${PROCD}/device-tree/compatible"
    LSBLK_TABLE="${ENV_ROOT}/lsblk.table"
    cat > "${LSBLK_TABLE}" <<EOT
mmcblk0 disk - -
mmcblk0boot0 disk - -
mmcblk0boot1 disk - -
mmcblk0rpmb disk - -
mmcblk0p1 part mmcblk0 -
mmcblk0p2 part mmcblk0 -
sda disk - -
sda1 part sda /run/initramfs/live
EOT
    : > "${LOG}"
}
add_sd() {    # a second MMC-type disk (Le Potato: probe order) or an SD card
    local name="$1" type="$2"
    mkdir -p "${SYSFS}/block/${name}/device"; echo "${type}" > "${SYSFS}/block/${name}/device/type"
    truncate -s "${DISK_MIB}M" "${DEVDIR}/${name}"; printf '%s disk - -\n' "${name}" >> "${LSBLK_TABLE}"
}

CUR_INST=""    # the installer under test for this scenario (the real one, or a mutant)
OUT="${TMP}/run.out"
run_inst() {   # <tree> <args...>  (stdin from RUN_STDIN or /dev/null); stdout+stderr -> ${OUT}
    local tree="$1"; shift
    local script="${tree}/install-frite.sh"
    cp "${CUR_INST:-${INST}}" "${script}"; chmod +x "${script}"   # ALWAYS: a mutant copy must not leak into the next scenario
    rm -rf "${MNTD}"; mkdir -p "${MNTD}"
    PATH="${STUB}:${PATH}" STUB_LOG="${LOG}" STUB_LSBLK_TABLE="${LSBLK_TABLE}" \
    STUB_LIVE_SRC="${STUB_LIVE_SRC:-${DEVDIR}/sda1}" STUB_BLKID_EMPTY="${STUB_BLKID_EMPTY:-0}" \
    STUB_BLKID_STALE="${STUB_BLKID_STALE:-0}" STUB_SFDISK_DROP_ID="${STUB_SFDISK_DROP_ID:-0}" \
    FRITE_SYSFS="${SYSFS}" FRITE_PROC="${PROCD}" FRITE_MNT="${MNTD}" FRITE_DM_DIR="${DMD}" FRITE_DEV_DIR="${DEVDIR}" \
    FRITE_LIVE_MOUNT=/run/initramfs/live FRITE_LABEL_XATTR=user.selinux FRITE_TEST_ALLOW_FILE_DEV=1 \
    timeout 120 bash "${script}" "$@" < "${RUN_STDIN:-/dev/null}" > "${OUT}" 2>&1
}
disk_id() { od -An -tx1 -j440 -N4 "$1" | awk '{printf "%s%s%s%s", $4, $3, $2, $1}'; }
called()  { grep -E "^$1( |$)" "${LOG}" >/dev/null; }
line_of() { grep -nE "^$1( |$)" "${LOG}" | head -1 | cut -d: -f1; }
before()  { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
out_has() { grep -F -- "$1" "${OUT}" >/dev/null; }
nothing_written() { ! called wipefs && ! called sfdisk && ! called dd && ! called mkfs.vfat && ! called 'cryptsetup luksFormat'; }

# ── Scenario functions: return 0 when the installer behaved as REQUIRED. They
# serve section A-C as positive assertions and section E as mutation probes. ──
T_PLAIN="${TMP}/tree-plain"; T_ENC="${TMP}/tree-enc"; T_UNLAB="${TMP}/tree-unlab"
T_ROOTONLY="${TMP}/tree-rootonly"; T_NOLAB="${TMP}/tree-nolab"

sc_plain_happy() {       # unattended, auto-detected eMMC, plaintext; everything in order and read back
    make_env; run_inst "${T_PLAIN}" --yes || return 1
    local id; id="$(disk_id "${DEVDIR}/mmcblk0")"
    out_has "Auto-selected the eMMC: ${DEVDIR}/mmcblk0" || return 1
    [ "${id}" != "00000000" ] || return 1
    called "wipefs -a ${DEVDIR}/mmcblk0" && before "wipefs -a ${DEVDIR}/mmcblk0" "sfdisk" || return 1
    before "sfdisk" "mkfs.vfat" && before "mkfs.vfat" "mount" && before "mount" "umount" || return 1
    [ -x "${MNTD}/frite-root/usr/bin/init" ] && [ -f "${MNTD}/frite-root/etc/fstab" ] || return 1
    [ -f "${MNTD}/frite-boot/Image" ] && [ -f "${MNTD}/frite-boot/dtb/${DTB_REL}" ] && [ -f "${MNTD}/frite-boot/extlinux/extlinux.conf" ] || return 1
    grep -E "^[[:space:]]*APPEND .* root=PARTUUID=${id}-02( |$)" "${MNTD}/frite-boot/extlinux/extlinux.conf" >/dev/null || return 1
    grep -E "^PARTUUID=${id}-01[[:space:]]+/boot[[:space:]]" "${MNTD}/frite-root/etc/fstab" >/dev/null || return 1
    grep -E "^PARTUUID=${id}-02[[:space:]]+/[[:space:]]" "${MNTD}/frite-root/etc/fstab" >/dev/null || return 1
    ! grep -E '^LABEL=FRITE_' "${MNTD}/frite-root/etc/fstab" >/dev/null || return 1
    called "umount ${MNTD}/frite-boot" && called "umount ${MNTD}/frite-root" || return 1
    ! called 'cryptsetup' || return 1
    [ ! -e "${MNTD}/frite-root/.autorelabel" ] || return 1          # labelled stage4: no relabel request
    out_has "SELinux labels present (/usr/bin/init system_u:object_r:init_exec_t:s0)" || return 1
    return 0
}
sc_enc_happy() {         # encrypted, --luks-pass, explicit device
    make_env; run_inst "${T_ENC}" --yes --luks-pass 'Correct-Horse-9' "${DEVDIR}/mmcblk0" || return 1
    local id; id="$(disk_id "${DEVDIR}/mmcblk0")"
    called "cryptsetup luksFormat --type luks2" && before "sfdisk" "cryptsetup luksFormat" || return 1
    called "cryptsetup open ${DEVDIR}/mmcblk0p2 cryptroot -" && before "cryptsetup open" "mkfs.ext4" || return 1
    called "mkfs.ext4 -F -L FRITE_ROOT ${DMD}/cryptroot" || return 1
    grep -E "root=/dev/mapper/cryptroot rd.luks.uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee rd.luks.name=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee=cryptroot( |$)" \
        "${MNTD}/frite-boot/extlinux/extlinux.conf" >/dev/null || return 1
    [ -f "${MNTD}/frite-boot/initrd.img" ] || return 1
    grep -E '^cryptroot UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee none luks$' "${MNTD}/frite-root/etc/crypttab" >/dev/null || return 1
    grep -E "^UUID=0f0f0f0f-1111-2222-3333-444444444444[[:space:]]+/[[:space:]]" "${MNTD}/frite-root/etc/fstab" >/dev/null || return 1
    grep -E "^PARTUUID=${id}-01[[:space:]]+/boot[[:space:]]" "${MNTD}/frite-root/etc/fstab" >/dev/null || return 1
    before "umount ${MNTD}/frite-root" "cryptsetup close cryptroot" || return 1
    [ ! -e "${DMD}/cryptroot" ] || return 1
    ! grep -rF 'Correct-Horse-9' "${OUT}" "${LOG}" >/dev/null || return 1   # the passphrase never reaches output or argv logs
    return 0
}
sc_enc_unattended_nopass() {   # must stop BEFORE the disk, with the reason
    make_env; run_inst "${T_ENC}" --yes "${DEVDIR}/mmcblk0" && return 1
    out_has "no LUKS passphrase" && nothing_written
}
sc_attended_refuse() {   # a confirm that is not the device path aborts
    make_env; printf 'y\n' > "${TMP}/stdin.y"
    RUN_STDIN="${TMP}/stdin.y" run_inst "${T_PLAIN}" "${DEVDIR}/mmcblk0" && return 1
    out_has "Aborted." && nothing_written
}
sc_attended_confirm() {  # typing the device path proceeds
    make_env; printf '%s\n' "${DEVDIR}/mmcblk0" > "${TMP}/stdin.dev"
    RUN_STDIN="${TMP}/stdin.dev" run_inst "${T_PLAIN}" "${DEVDIR}/mmcblk0" || return 1
    called sfdisk && out_has "==> Done."
}
sc_refuse() {            # <dev-basename> <expected text> [env...] — refused, nothing written
    local dev="$1" want="$2"; shift 2
    make_env
    run_inst "${T_PLAIN}" --yes "${DEVDIR}/${dev}" && return 1
    out_has "${want}" && nothing_written
}
sc_refuse_partition() { sc_refuse mmcblk0p1 "is a PARTITION"; }
sc_refuse_boot0()     { sc_refuse mmcblk0boot0 "HARDWARE boot partition"; }
sc_refuse_rpmb()      { sc_refuse mmcblk0rpmb "Replay-Protected"; }
sc_refuse_missing()   { sc_refuse mmcblk9 "does not exist"; }
sc_refuse_live_part() { STUB_LIVE_SRC="${DEVDIR}/sda1" sc_refuse sda "is the medium this live session booted from"; }
sc_refuse_live_disk() { STUB_LIVE_SRC="${DEVDIR}/sda" sc_refuse sda "is the medium this live session booted from"; }
sc_refuse_mounted() {
    make_env; sed -i 's|^mmcblk0p2 part mmcblk0 -$|mmcblk0p2 part mmcblk0 /mnt/old|' "${LSBLK_TABLE}"
    run_inst "${T_PLAIN}" --yes "${DEVDIR}/mmcblk0" && return 1
    out_has "is MOUNTED at /mnt/old" && nothing_written
}
sc_refuse_swap() {
    make_env; printf '%s/mmcblk0p2 partition 1048572 0 -2\n' "${DEVDIR}" >> "${PROCD}/swaps"
    run_inst "${T_PLAIN}" --yes "${DEVDIR}/mmcblk0" && return 1
    out_has "is active SWAP" && nothing_written
}
sc_detect_none() {       # the only mmcblk is an SD card -> no auto-select, candidates listed
    make_env; echo SD > "${SYSFS}/block/mmcblk0/device/type"
    run_inst "${T_PLAIN}" --yes && return 1
    out_has "No eMMC found" && out_has "Block devices seen from this live session:" && out_has "${DEVDIR}/mmcblk0 7.3G disk" && nothing_written
}
sc_detect_two() {        # Le Potato with two MMC-type disks -> name it
    make_env; add_sd mmcblk1 MMC
    run_inst "${T_PLAIN}" --yes && return 1
    out_has "More than one MMC-type disk" && nothing_written
}
sc_detect_skips_sd() {   # an SD card next to the eMMC does not confuse auto-detection
    make_env; add_sd mmcblk1 SD
    run_inst "${T_PLAIN}" --yes || return 1
    out_has "Auto-selected the eMMC: ${DEVDIR}/mmcblk0"
}
sc_missing_fdt() {       # the DTB extlinux names is absent from the medium -> stop before the disk
    make_env; local t="${TMP}/tree-nofdt"; rm -rf "${t}"; cp -r "${T_PLAIN}" "${t}"; rm -f "${t}/boot/dtb/${DTB_REL}"
    run_inst "${t}" --yes && return 1
    out_has "boot file(s) missing from the installer medium" && out_has "${DTB_REL}" && nothing_written
}
sc_missing_initrd_line() {   # --encrypt against a medium whose extlinux has no INITRD line
    make_env; run_inst "${T_PLAIN}" --yes --encrypt --luks-pass x "${DEVDIR}/mmcblk0" && return 1
    out_has "has no INITRD line" && nothing_written
}
sc_tar_fail() {          # a corrupt stage4: abort, no boot staging, mounts undone
    make_env; local t="${TMP}/tree-badtar"; rm -rf "${t}"; cp -r "${T_PLAIN}" "${t}"
    head -c 3000 /dev/urandom > "${t}/stage4/fixture.stage4.tar.xz"
    run_inst "${t}" --yes && return 1
    out_has "extracting" && out_has "failed" || return 1
    [ ! -e "${MNTD}/frite-boot/extlinux/extlinux.conf" ] || return 1
    called "umount ${MNTD}/frite-root" && before "mount" "umount" && out_has "aborted (exit"
}
sc_unlabelled_autorelabel() {   # no labels in the stage4 -> relabel request on the target
    make_env; run_inst "${T_UNLAB}" --yes || return 1
    [ -e "${MNTD}/frite-root/.autorelabel" ] && out_has "carried no SELinux labels"
}
sc_blkid_empty() {
    make_env; STUB_BLKID_EMPTY=1 run_inst "${T_PLAIN}" --yes && return 1
    out_has "PARTUUID of ${DEVDIR}/mmcblk0p1 reads '<none>'" && ! out_has "==> Done."
}
sc_blkid_stale() {       # blkid answering from a cache (another disk's id) must not reach root=
    make_env; STUB_BLKID_STALE=1 run_inst "${T_PLAIN}" --yes && return 1
    out_has "reads 'deadbeef-01'" && ! grep -rF 'deadbeef' "${MNTD}/frite-boot" "${MNTD}/frite-root/etc/fstab" >/dev/null 2>&1
}
sc_sfdisk_dropped_id() { # the table on disk does not carry the id the script chose -> abort before mkfs
    make_env; STUB_SFDISK_DROP_ID=1 run_inst "${T_PLAIN}" --yes && return 1
    out_has "MBR disk id on" && out_has "reads back as" && ! called mkfs.vfat
}
sc_fstab_rootonly() {    # a fstab the BOOT rewrite cannot reach -> abort, never 'Done'
    make_env; run_inst "${T_ROOTONLY}" --yes && return 1
    out_has "fstab rewrite of" && out_has "did not take" && ! out_has "==> Done."
}
sc_fstab_nolabels() {
    make_env; run_inst "${T_NOLAB}" --yes && return 1
    out_has "has no LABEL=FRITE_BOOT / LABEL=FRITE_ROOT lines" && ! out_has "==> Done."
}
sc_uboot_media() {       # the blob lands at sector 1 + 444 header bytes, BEFORE the table, id intact
    make_env; local t="${TMP}/tree-uboot" blob; rm -rf "${t}"; cp -r "${T_PLAIN}" "${t}"
    blob="${t}/uboot/u-boot.bin"; head -c 1048576 /dev/urandom > "${blob}"
    run_inst "${t}" --yes --write-uboot-media "${DEVDIR}/mmcblk0" || return 1
    called "dd if=${blob} of=${DEVDIR}/mmcblk0 bs=512 skip=1 seek=1 conv=fsync,notrunc" || return 1
    called "dd if=${blob} of=${DEVDIR}/mmcblk0 bs=1 count=444 conv=fsync,notrunc" || return 1
    before "wipefs -a ${DEVDIR}/mmcblk0" "dd" && before "dd" "sfdisk" || return 1
    # header copy in sector 0 (bytes 0..439) and the body from sector 1 — busybox cmp has no -i/-n, so dd the ranges out
    "${REAL_DD}" if="${blob}" bs=1 count=440 status=none > "${TMP}/h.blob"; "${REAL_DD}" if="${DEVDIR}/mmcblk0" bs=1 count=440 status=none > "${TMP}/h.disk"
    cmp -s "${TMP}/h.blob" "${TMP}/h.disk" || return 1
    "${REAL_DD}" if="${blob}" bs=512 skip=1 status=none > "${TMP}/b.blob"; "${REAL_DD}" if="${DEVDIR}/mmcblk0" bs=512 skip=1 count=2047 status=none > "${TMP}/b.disk"
    cmp -s "${TMP}/b.blob" "${TMP}/b.disk" || return 1
    local id; id="$(disk_id "${DEVDIR}/mmcblk0")"
    [ "${id}" != "00000000" ] && grep -F "root=PARTUUID=${id}-02" "${MNTD}/frite-boot/extlinux/extlinux.conf" >/dev/null || return 1
    out_has "identifies as La Frite" || return 1     # the fixture device-tree says aml-s805x-ac: warned, not refused
    [ "$("${REAL_SFDISK}" -d "${DEVDIR}/mmcblk0" | awk '/^label-id:/ {print $2}')" = "0x${id}" ]
}
sc_uboot_too_big() {     # a blob that would overlap p1 is refused before the disk is touched
    make_env; local t="${TMP}/tree-ubootbig"; rm -rf "${t}"; cp -r "${T_PLAIN}" "${t}"
    head -c $((8 * 1024 * 1024 + 1)) /dev/urandom > "${t}/uboot/u-boot.bin"
    run_inst "${t}" --yes --write-uboot-media "${DEVDIR}/mmcblk0" && return 1
    out_has "would overlap the boot partition" && nothing_written
}
sc_uboot_missing() {
    make_env; run_inst "${T_PLAIN}" --yes --write-uboot-media "${DEVDIR}/mmcblk0" && return 1
    out_has "is missing (build with --uboot-url" && nothing_written
}
sc_cli() {
    make_env
    run_inst "${T_PLAIN}" --help && out_has "Usage:" || return 1
    run_inst "${T_PLAIN}" --bogus && return 1
    out_has "unknown option: --bogus" || return 1
    run_inst "${T_PLAIN}" --yes "${DEVDIR}/mmcblk0" "${DEVDIR}/sda" && return 1
    out_has "more than one target device" && nothing_written
}

# ── Build the fixture trees ──────────────────────────────────────────────────
if ${HAVE_XATTR}; then
    make_tree "${T_PLAIN}" yes no
    make_tree "${T_ENC}" yes yes
    make_tree "${T_ROOTONLY}" yes no rootonly
    make_tree "${T_NOLAB}" yes no nolabels
else
    make_tree "${T_PLAIN}" no no
    make_tree "${T_ENC}" no yes
    make_tree "${T_ROOTONLY}" no no rootonly
    make_tree "${T_NOLAB}" no no nolabels
fi
make_tree "${T_UNLAB}" no no

echo "== A. happy paths =="
if ${HAVE_XATTR}; then
    sc_plain_happy && ok "plaintext, unattended, auto-detected eMMC: wipe -> table -> mkfs -> mount -> tar -> boot tree -> root=PARTUUID/fstab read back -> umount; labelled stage4 leaves no /.autorelabel" \
        || { bad "plaintext happy path"; sed 's/^/      | /' "${OUT}" | tail -25; }
    sc_enc_happy && ok "encrypted with --luks-pass: luksFormat/open after the table, mapper root formatted, rd.luks.uuid/name + crypttab + UUID fstab, close after umount, passphrase never in output" \
        || { bad "encrypted happy path"; sed 's/^/      | /' "${OUT}" | tail -25; }
else
    skip "A happy paths need user.* xattrs on ${TMP} (setfattr absent or refused) — the labelled lanes did not run"
fi
sc_attended_confirm && ok "attended: typing the device path confirms and the install proceeds" || bad "attended confirm"
sc_attended_refuse && ok "attended: 'y' is not a confirmation (the device path is) — aborted, nothing written" || bad "attended refuse"

echo "== B. refusals, each before anything is written =="
sc_refuse_partition   && ok "a partition (mmcblk0p1) is refused" || bad "partition not refused: $(tail -3 "${OUT}")"
sc_refuse_boot0       && ok "mmcblk0boot0 (eMMC hardware boot partition) is refused" || bad "boot0 not refused: $(tail -3 "${OUT}")"
sc_refuse_rpmb        && ok "mmcblk0rpmb is refused" || bad "rpmb not refused: $(tail -3 "${OUT}")"
sc_refuse_missing     && ok "a device that does not exist is refused" || bad "missing device: $(tail -3 "${OUT}")"
sc_refuse_live_part   && ok "the disk behind the live medium (mounted from its partition sda1) is refused" || bad "live medium (partition source): $(tail -3 "${OUT}")"
sc_refuse_live_disk   && ok "the live medium mounted as a whole disk (sda, how QEMU's usb-storage ISO shows up) is refused" || bad "live medium (disk source): $(tail -3 "${OUT}")"
sc_refuse_mounted     && ok "a disk with a mounted partition is refused" || bad "mounted: $(tail -3 "${OUT}")"
sc_refuse_swap        && ok "a disk with active swap is refused" || bad "swap: $(tail -3 "${OUT}")"
sc_detect_none        && ok "no MMC-type disk (only an SD card): no auto-select, candidates listed with lsblk" || bad "detect none: $(tail -5 "${OUT}")"
sc_detect_two         && ok "two MMC-type disks: no auto-select" || bad "detect two: $(tail -3 "${OUT}")"
sc_detect_skips_sd    && ok "an SD card (type SD) beside the eMMC does not block auto-detection" || bad "detect skips sd: $(tail -3 "${OUT}")"
sc_enc_unattended_nopass && ok "encrypted + --yes without --luks-pass or a seeded file stops before the disk with the reason" || bad "unattended nopass: $(tail -3 "${OUT}")"
sc_missing_fdt        && ok "the FDT named by extlinux missing from the medium: stop before the disk" || bad "missing fdt: $(tail -3 "${OUT}")"
sc_missing_initrd_line && ok "--encrypt on a medium whose extlinux has no INITRD line: stop before the disk" || bad "missing initrd line: $(tail -3 "${OUT}")"
sc_cli                && ok "--help exits 0 with usage; an unknown option and two devices are refused" || bad "cli: $(tail -3 "${OUT}")"

echo "== C. the write path =="
sc_tar_fail           && ok "a corrupt stage4 aborts: tar's failure is fatal, no boot tree staged, the mounts are undone" || bad "tar failure: $(tail -5 "${OUT}")"
sc_unlabelled_autorelabel && ok "an unlabelled stage4 gets /.autorelabel on the target + a warning" || bad "unlabelled autorelabel: $(tail -3 "${OUT}")"
sc_blkid_empty        && ok "blkid returning nothing for PARTUUID aborts (never 'Done' with root=LABEL left in place)" || bad "blkid empty: $(tail -3 "${OUT}")"
sc_blkid_stale        && ok "a stale cached PARTUUID (another disk's id) aborts and never reaches root=/fstab" || bad "blkid stale: $(tail -3 "${OUT}")"
sc_sfdisk_dropped_id  && ok "a table whose disk id is not the one chosen aborts before mkfs" || bad "sfdisk dropped id: $(tail -3 "${OUT}")"
sc_fstab_rootonly     && ok "a fstab the /boot rewrite cannot reach aborts after the rewrite is read back" || bad "fstab rootonly: $(tail -3 "${OUT}")"
sc_fstab_nolabels     && ok "a fstab without LABEL=FRITE_* lines aborts" || bad "fstab nolabels: $(tail -3 "${OUT}")"
sc_uboot_media        && ok "--write-uboot-media: blob body at sector 1 + 444 header bytes at sector 0, written after the wipe and before the table; bytes 0..439 are the blob's, 440..443 the chosen id; La Frite warned not refused" || bad "uboot media: $(tail -5 "${OUT}")"
sc_uboot_too_big      && ok "--write-uboot-media with a blob larger than p1's 8 MiB start is refused before the disk" || bad "uboot too big: $(tail -3 "${OUT}")"
sc_uboot_missing      && ok "--write-uboot-media without a staged blob is refused before the disk" || bad "uboot missing: $(tail -3 "${OUT}")"

echo "== D. offline layout proof (real sfdisk / mtools / e2fsprogs on the written image) =="
if ${HAVE_XATTR} && sc_plain_happy; then
    DISK="${DEVDIR}/mmcblk0"; ID="$(disk_id "${DISK}")"
    dump="$("${REAL_SFDISK}" -d "${DISK}")"
    p1="$(printf '%s\n' "${dump}" | grep -E '^[^ ]+1 :')"; p2="$(printf '%s\n' "${dump}" | grep -E '^[^ ]+2 :')"
    printf '%s\n' "${dump}" | grep -E "^label-id: 0x${ID}$" >/dev/null && ok "D: MBR label-id 0x${ID} is non-zero and is the id in root=PARTUUID" || bad "D: label-id: $(printf '%s\n' "${dump}" | grep label-id)"
    printf '%s' "${p1}" | grep -E 'start= *16384, size= *524288, type=c, bootable' >/dev/null && ok "D: p1 starts at sector 16384 (8 MiB, clear of the Amlogic BL2+FIP region), 256 MiB, type c, bootable" || bad "D: p1: ${p1}"
    printf '%s' "${p2}" | grep -E 'start= *540672, size= *[0-9]+, type=83' >/dev/null && ok "D: p2 starts right after p1 (sector 540672), type 83" || bad "D: p2: ${p2}"
    printf '%s' "${p2}" | grep -E "size= *$((DISK_SECTORS - 540672))," >/dev/null && ok "D: p2 runs to the end of the disk (${DISK_SECTORS} sectors)" || bad "D: p2 size: ${p2}"
    if command -v mformat >/dev/null && command -v mcopy >/dev/null && command -v mtype >/dev/null; then
        FAT="${TMP}/p1.fat"; rm -f "${FAT}"; truncate -s $((524288 * 512)) "${FAT}"
        if mformat -i "${FAT}" -F -v FRITE_BOOT :: 2>"${TMP}/mformat.err" && mcopy -i "${FAT}" -s "${MNTD}/frite-boot/"* :: 2>"${TMP}/mcopy.err"; then
            "${REAL_DD}" if="${FAT}" of="${DISK}" bs=512 seek=16384 conv=notrunc status=none
            OFF=$((16384 * 512)); good=true
            for f in extlinux/extlinux.conf Image "dtb/${DTB_REL}"; do
                mdir -i "${DISK}@@${OFF}" "::/$(dirname "${f}")" 2>/dev/null | grep -iF "$(basename "${f}" | cut -c1-8)" >/dev/null || { good=false; bad "D: ${f} not on the FAT at p1's offset"; }
            done
            ${good} && ok "D: a real FAT32 at p1's offset holds extlinux.conf, the Image and the FDT extlinux names"
            mtype -i "${DISK}@@${OFF}" ::/extlinux/extlinux.conf 2>/dev/null | grep -F "root=PARTUUID=${ID}-02" >/dev/null \
                && ok "D: extlinux.conf read back off the FAT at p1's offset carries root=PARTUUID=${ID}-02" || bad "D: extlinux.conf on the FAT lacks root=PARTUUID=${ID}-02"
            mtype -i "${DISK}@@${OFF}" ::/extlinux/extlinux.conf 2>/dev/null | grep -E "^[[:space:]]*FDT /dtb/${DTB_REL}$" >/dev/null \
                && ok "D: the FDT line names /dtb/${DTB_REL}, which is on the FAT" || bad "D: FDT line"
        else
            skip "D: mformat/mcopy failed on this host ($(head -c 200 "${TMP}/mformat.err" "${TMP}/mcopy.err" 2>/dev/null | tr '\n' ' '))"
        fi
    else
        skip "D: mtools (mformat/mcopy/mtype) absent — the FAT-at-offset proof did not run"
    fi
    if command -v mke2fs >/dev/null && command -v debugfs >/dev/null; then
        E2="${TMP}/p2.ext4"; rm -f "${E2}"
        if mke2fs -q -F -t ext4 -L FRITE_ROOT -d "${MNTD}/frite-root" "${E2}" 64M >"${TMP}/mke2fs.out" 2>&1; then
            debugfs -R 'cat /etc/fstab' "${E2}" 2>/dev/null | grep -E "^PARTUUID=${ID}-02[[:space:]]+/[[:space:]]" >/dev/null \
                && ok "D: fstab read back from a real ext4 of the root tree mounts / by PARTUUID=${ID}-02" || bad "D: ext4 fstab"
            debugfs -R 'cat /etc/fstab' "${E2}" 2>/dev/null | grep -E '^LABEL=FRITE_' >/dev/null \
                && bad "D: ext4 fstab still carries LABEL=FRITE_*" || ok "D: no LABEL=FRITE_* placeholder survives in the ext4 fstab"
            ea="$(debugfs -R 'ea_list /usr/bin/init' "${E2}" 2>/dev/null || true)"
            if printf '%s' "${ea}" | grep -F 'user.selinux' >/dev/null; then
                ok "D: /usr/bin/init on the real ext4 carries its label xattr (tar --xattrs preserved it through the install)"
            elif printf '%s' "${ea}" | grep -iE 'unknown request|Unknown' >/dev/null || [ -z "${ea}" ]; then
                skip "D: this debugfs has no ea_list — xattr survival on ext4 not read back here"
            else
                bad "D: /usr/bin/init lost its label xattr on the ext4: ${ea}"
            fi
        else
            skip "D: mke2fs -d failed here ($(head -c 200 "${TMP}/mke2fs.out" | tr '\n' ' '))"
        fi
    else
        skip "D: mke2fs/debugfs absent — the ext4 read-back did not run"
    fi
else
    skip "D: needs the plaintext happy path (user.* xattrs)"
fi

echo "== E. mutation battery: each planted defect must turn its scenario RED =="
mutate() {   # <name> <sed expr> -> path of the mutated copy on stdout; rc 1 (reason on stderr) if the text is unchanged or broken
    local m="${TMP}/mut-$1.sh"
    sed -e "$2" "${INST}" > "${m}" || { echo "sed failed" >&2; return 1; }
    if cmp -s "${m}" "${INST}"; then echo "the sed expression changed nothing" >&2; return 1; fi
    bash -n "${m}" 2>&1 | sed 's/^/      | /' >&2
    bash -n "${m}" 2>/dev/null || { echo "the mutated copy does not parse" >&2; return 1; }
    printf '%s\n' "${m}"
}
probe() {    # <name> <scenario fn> <sed expr> <what the planted defect is>
    local name="$1" fn="$2" expr="$3" what="$4" m
    # mutate runs in a command substitution (a subshell): its verdict must come
    # back as the exit status, or a mutation that never applied would be SILENT.
    if ! m="$(mutate "${name}" "${expr}" 2> "${TMP}/mut.err")"; then
        bad "${name}: mutation did not apply ($(tr '\n' ' ' < "${TMP}/mut.err"))"; return
    fi
    if [ "${fn}" = "sc_plain_happy" ] || [ "${fn}" = "sc_enc_happy" ] || [ "${fn}" = "sc_uboot_media" ]; then
        ${HAVE_XATTR} || { skip "${name}: needs the xattr lanes"; return; }
    fi
    if CUR_INST="${m}" "${fn}"; then
        bad "${name}: ${what} — SURVIVED (the scenario still passed)"
    else
        ok "${name}: ${what} — caught"
    fi
    CUR_INST=""
}
probe M01-no-xattrs      sc_plain_happy  "s/tar -C \"\${MNT_ROOT}\" --xattrs --xattrs-include='\*\.\*' -xJf/tar -C \"\${MNT_ROOT}\" -xJf/" \
      "tar extracts without --xattrs (labels lost, the old silent fallback)"
probe M02-no-wipe        sc_plain_happy  '/^wipefs -a "\${DEV}" >\/dev\/null || die/d' \
      "the whole-disk wipefs removed (stale signatures survive)"
probe M03-no-id-verify   sc_sfdisk_dropped_id '/^\[ "\${GOT_ID}" = "\${DISK_ID}" \]/d; /^    || die "MBR disk id on/d' \
      "the MBR disk id read-back removed"
probe M04-no-bootfile-gate sc_missing_fdt  's/^require_boot_files() {.*/&\n    return 0/' \
      "the boot-file existence check neutered (a FAT without the FDT would be written)"
probe M05-uboot-seek0    sc_uboot_media  's/bs=512 skip=1 seek=1 conv=fsync,notrunc/bs=512 skip=1 seek=0 conv=fsync,notrunc/' \
      "u-boot body written at sector 0 instead of the Amlogic offset (sector 1)"
probe M06-no-live-refusal sc_refuse_live_disk 's/die "\${dev} is the medium this live session booted from/: "${dev} is the medium this live session booted from/' \
      "the live-medium refusal removed (the running installer could be erased)"
probe M07-no-autorelabel sc_unlabelled_autorelabel '/touch "\${MNT_ROOT}\/.autorelabel"/d' \
      "the /.autorelabel request for an unlabelled stage4 removed"
probe M08-no-fstab-readback sc_fstab_rootonly 's/^    die "fstab rewrite of \${FSTAB_DST} did not take/    : "fstab rewrite of ${FSTAB_DST} did not take/' \
      "the fstab rewrite read-back removed (a sed that matched nothing passes)"
probe M09-no-partition-refusal sc_refuse_partition 's#class/block/\${name}/partition#class/block/${name}/no-such-file#' \
      "the partition refusal looks at the wrong sysfs file"
probe M10-no-unattended-pass sc_enc_unattended_nopass 's/die "unattended encrypted install but no LUKS passphrase/: "unattended encrypted install but no LUKS passphrase/' \
      "the unattended-without-passphrase stop removed (would block on a prompt)"
probe M11-no-mounted-refusal sc_refuse_mounted 's/|| die "\${dev} (or a partition of it) is MOUNTED/|| : "${dev} (or a partition of it) is MOUNTED/' \
      "the mounted-disk refusal removed"
probe M12-no-boot0-refusal sc_refuse_boot0 's/^        \*boot\[0-9\]) die /        *boot[0-9]) : /' \
      "the eMMC boot0/boot1 refusal removed"
probe M13-no-uboot-room  sc_uboot_too_big 's/^    \[ "\${UBOOT_SIZE}" -le "\${P1_START_BYTES}" \] \\$/    true \\/' \
      "the u-boot room check removed (a blob overlapping p1 would be written)"
probe M14-blkid-cached   sc_plain_happy  's/blkid -c \/dev\/null -s/blkid -s/' \
      "blkid asked WITH its cache (a previous disk's PARTUUID answers)"
probe M15-no-partuuid-check sc_blkid_stale '/^\[ "\${got}" = "\${BOOT_PARTUUID}" \]/d; /^\[ "\${got}" = "\${ROOT_PARTUUID}" \]/d' \
      "the PARTUUID-matches-disk-id check removed (a stale id reaches root=)"

echo ""
echo "== ${P} passed, ${F} failed, ${S} skipped =="
[ "${F}" -eq 0 ]
