#!/usr/bin/env bash
# frite-emmc-install.sh — prove that the Libre Computer Frite INSTALLER medium
# installs onto the board's eMMC and that the eMMC then boots ON ITS OWN to a
# greeter a person can log in at. Operator requirement (2026-11-04): "on le
# frite, make sure installer image can install to the emmc".
#
# Two phases on the HOST qemu-system-aarch64 (>= 9.1: the `emmc` device; the
# runner image's QEMU 7.2 has only sd-card), driven through launch-arm.sh:
#
#   phase A  boot the installer medium (its own Image + dmsquash-live initrd +
#            extlinux APPEND, no board DTB) with
#              * the medium as usb-storage behind qemu-xhci  -> /dev/sda, the way
#                a real stick appears (--medium-bus virtio is the fallback);
#              * a raw file as an eMMC behind sdhci-pci       -> /dev/mmcblk0 +
#                mmcblk0boot0/boot1, type MMC — what La Frite's module is
#                (meson-gxl-s805x-libretech-ac.dts enables sd_emmc_c only, no mmc
#                aliases, so the eMMC really is mmcblk0 there);
#              * a per-run KEYS stick (make-test-keys.sh) whose users.json makes a
#                login with a generated password (for the greeter) and a generated
#                ssh key (for the assertions) — the same provisioning every other
#                emulated device uses, so no credential is scraped off a console.
#            Then assert the storage topology the installer must see, run
#            install-frite.sh unattended against the DETECTED eMMC, power off.
#   between  check_emmc_layout: read the installed eMMC from the host (the user
#            area starts at 2*boot-size + rpmb-size inside the backing file —
#            hw/sd/sd.c sd_part_offset) and assert the layout a real board's
#            u-boot needs: MBR with a non-zero disk id, FAT p1 (bootable) carrying
#            extlinux/extlinux.conf + Image + the board FDT (+ initrd.img when the
#            config names one), APPEND root=PARTUUID=<diskid>-02 (or the LUKS
#            spelling), ext4 p2 (or a LUKS2 header) whose fstab no longer says
#            LABEL=FRITE_ROOT, and security.selinux xattrs on the installed tree.
#            This is also the OFFLINE test (--check-layout) for what emulation
#            cannot prove — the layout itself does not depend on the SoC.
#   phase B  detach the medium; boot the eMMC ALONE with the kernel + initrd +
#            APPEND lifted off ITS OWN /extlinux/extlinux.conf, --gpu, the same
#            KEYS stick. Assert ssh, Xorg + lightdm, a DRM device, screendump the
#            greeter, type the generated password through QMP send-key, screendump
#            again, assert the session processes (lxsession/openbox) run as the
#            user and the two screenshots differ.
#
# WHAT THIS CANNOT PROVE (say so, every time): the Amlogic boot ROM -> SPI-NOR
# u-boot -> eMMC boot order (La Frite's u-boot may prefer USB), u-boot's own mmc
# numbering, that the meson-gxl FDT matches the silicon, meson DRM/lima HDMI,
# eMMC HS timing. -M virt has none of that. The layout check + real hardware do.
#
# NAMED FAILURES, not timeouts. The guest kernel is the Frite's (arm64 defconfig
# + specs-frite/kernel/hardened-desktop.config); if it lacks CONFIG_MMC_SDHCI_PCI
# there is no /dev/mmcblk0, if it lacks DRM_VIRTIO_GPU there is no card0 — each
# is reported by name so the fixer knows which fragment line to add.
#
# Credentials: the password and ssh key are generated per run under RUN_DIR
# (0600, deleted unless --keep) and never printed. The LUKS passphrase for an
# --encrypt-root medium is likewise generated (or --luks-pass) and typed at the
# dracut prompt through the launcher's --serial-sock, never logged.
#
#   bash tests/qemu/frite-emmc-install.sh --medium out/<brand>-frite-la-frite-arm64-desktop-*.installer.iso
#   bash tests/qemu/frite-emmc-install.sh --check-layout emmc.raw --user-offset 8388608
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAUNCHER="${SCRIPT_DIR}/launch-arm.sh"
MAKE_KEYS="${SCRIPT_DIR}/make-test-keys.sh"

PLATFORM="frite"
BOARD="${BOARD:-la-frite}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/out}"
RUN_DIR=""
MEDIUM=""
MEDIUM_BUS="usb"
EMMC_USER_SIZE=$(( 8 * 1024 * 1024 * 1024 ))   # the eMMC's user area (La Frite ships 8/16/32 GB modules)
EMMC_BOOT_SIZE=4194304                          # 4 MiB x2 boot partitions, like the module
EMMC_RPMB_SIZE=0
MEM="1024"                                      # the 1 GB La Frite SKU
SMP="2"
SSH_PORT="2222"
TIMEOUT="3600"                                  # per phase; aarch64 TCG is slow
LOGIN_TIMEOUT="300"
USER_NAME="frite"
LUKS_PASS=""
PHASE="both"                                    # a | b | both
KEEP=false
WAIT_IDLE=true
ALLOW_UNLABELLED=false
CHECK_LAYOUT=""
CHECK_USER_OFFSET=""
CHECK_FDT=""

usage() {
cat <<EOF
Usage: $0 --medium FILE [OPTIONS]
       $0 --check-layout RAW [--user-offset BYTES] [--fdt amlogic/....dtb] [--allow-unlabelled]

  Two-phase proof that the Frite INSTALLER medium installs to an emulated eMMC
  and the eMMC then boots alone to a greeter you can log in at (see the header).

Medium / board:
      --medium FILE        INSTALLER medium (ISO9660 or MBR+FAT). Default: newest
                           *-frite-<board>-arm64-*.installer.{img,iso} under --work-dir.
      --medium-bus B       usb (default; /dev/sda) | virtio.
  -b, --board BOARD        la-frite (default) | le-potato | sweet-potato (FDT name).
  -w, --work-dir DIR       Where media are autodetected. Default: ${WORK_DIR}
      --run-dir DIR        Scratch (eMMC file, KEYS, logs, screenshots). Default: <work>/frite-emmc-run

eMMC:
      --emmc-size BYTES    User area. Default: ${EMMC_USER_SIZE} (8 GiB).
      --emmc-boot-size B   Per boot partition. Default: ${EMMC_BOOT_SIZE}.
      --emmc-rpmb-size B   RPMB. Default: ${EMMC_RPMB_SIZE}.

Guest / login:
  -m, --mem MB             Default: ${MEM} (the 1 GB SKU).   --smp N   Default: ${SMP}
      --ssh-port P         Default: ${SSH_PORT}
      --user NAME          Login name provisioned via KEYS. Default: ${USER_NAME} ([a-z0-9], QMP-typeable).
      --luks-pass PASS     Passphrase for an encrypt-root medium (default: generated per run).
  -t, --timeout SEC        Per phase. Default: ${TIMEOUT}
      --login-timeout SEC  Greeter login -> session processes. Default: ${LOGIN_TIMEOUT}

Lifecycle:
      --phase a|b|both     Default: both (b reuses <run-dir>/emmc.raw from a previous a).
      --keep               Keep RUN_DIR (eMMC file, KEYS stick + its credentials).
      --no-wait-idle       Do not wait for other qemu-system / builder containers to finish
                           (the machine rule is ONE build/QEMU at a time).
      --allow-unlabelled   Report missing security.selinux xattrs as WARN, not FAIL.

Offline layout check (no boot, no root):
      --check-layout RAW   Assert the installed-eMMC layout on RAW (a file or the
                           host-visible user area) and exit.
      --user-offset BYTES  Where the user area starts inside RAW (an emmc backing
                           file: 2*boot-size + rpmb-size). Default: 0.
      --fdt PATH           Board FDT the FAT must carry (default: from --board).
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --medium)          MEDIUM="$2"; shift 2 ;;
        --medium-bus)      MEDIUM_BUS="$2"; shift 2 ;;
        -b|--board)        BOARD="$2"; shift 2 ;;
        -w|--work-dir)     WORK_DIR="$2"; shift 2 ;;
        --run-dir)         RUN_DIR="$2"; shift 2 ;;
        --emmc-size)       EMMC_USER_SIZE="$2"; shift 2 ;;
        --emmc-boot-size)  EMMC_BOOT_SIZE="$2"; shift 2 ;;
        --emmc-rpmb-size)  EMMC_RPMB_SIZE="$2"; shift 2 ;;
        -m|--mem)          MEM="$2"; shift 2 ;;
        --smp)             SMP="$2"; shift 2 ;;
        --ssh-port)        SSH_PORT="$2"; shift 2 ;;
        --user)            USER_NAME="$2"; shift 2 ;;
        --luks-pass)       LUKS_PASS="$2"; shift 2 ;;
        -t|--timeout)      TIMEOUT="$2"; shift 2 ;;
        --login-timeout)   LOGIN_TIMEOUT="$2"; shift 2 ;;
        --phase)           PHASE="$2"; shift 2 ;;
        --keep)            KEEP=true; shift ;;
        --no-wait-idle)    WAIT_IDLE=false; shift ;;
        --allow-unlabelled) ALLOW_UNLABELLED=true; shift ;;
        --check-layout)    CHECK_LAYOUT="$2"; shift 2 ;;
        --user-offset)     CHECK_USER_OFFSET="$2"; shift 2 ;;
        --fdt)             CHECK_FDT="$2"; shift 2 ;;
        -h|--help)         usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[frite-emmc]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[frite-emmc] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[frite-emmc] ERROR:${RST} $*" >&2; exit 1; }

PASS=0; FAIL=0; WARNED=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
soft() { WARNED=$((WARNED+1)); printf '  WARN %s\n' "$1" >&2; }

# The board FDT name — launch-arm.sh's table is the single source (it mirrors the
# builder's select_board); read it there rather than carry a second copy here.
board_fdt() {
    local b="$1"
    sed -n "s|^[[:space:]]*frite:${b})[[:space:]]*DEF_DTB=\"\([^\"]*\)\".*|\1|p" "${LAUNCHER}" | head -1
}

# ── Host-side readers for a raw MBR disk at a byte offset ───────────────────
# No loop device, no root: od reads the partition table, mtools reads the FAT at
# @@offset, debugfs reads the ext4 through its '?offset=' io option. All three
# also work on the emmc backing file once the user-area offset is added.
le32() { # le32 FILE BYTE_OFFSET -> decimal
    od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' '
}
u8() { od -An -tu1 -j "$2" -N 1 "$1" 2>/dev/null | tr -d ' '; }
mbr_sig_ok()   { [ "$(od -An -tx1 -j $(( $2 + 510 )) -N 2 "$1" 2>/dev/null | tr -d ' ')" = "55aa" ]; }
mbr_disk_id()  { printf '%08x' "$(le32 "$1" $(( $2 + 440 )))"; }
# part_field FILE OFF N boot|type|start|size (N = 1..4)
part_field() {
    local f="$1" off="$2" n="$3" e
    e=$(( off + 446 + (n - 1) * 16 ))
    case "$4" in
        boot)  u8 "${f}" "${e}" ;;
        type)  u8 "${f}" $(( e + 4 )) ;;
        start) le32 "${f}" $(( e + 8 )) ;;
        size)  le32 "${f}" $(( e + 12 )) ;;
    esac
}
fat_has()  { MTOOLS_SKIP_CHECK=1 mdir -i "$1@@$2" "::$3" >/dev/null 2>&1; }
fat_cat()  { MTOOLS_SKIP_CHECK=1 mtype -i "$1@@$2" "::$3" 2>/dev/null; }
ext_cat()  { debugfs -R "cat $3" "$1?offset=$2" 2>/dev/null; }
ext_ea()   { debugfs -R "ea_list $3" "$1?offset=$2" 2>/dev/null; }
# The same DEFAULT-label field reader launch-arm.sh uses (kept identical).
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

# check_emmc_layout RAW USER_OFFSET FDT_NAME [OUT_DIR]
# Asserts the installed layout and, when OUT_DIR is given, lifts Image /
# initrd.img / extlinux.conf off the FAT for phase B. Counts into PASS/FAIL.
check_emmc_layout() {
    local raw="$1" off="$2" fdt="$3" out="${4:-}"
    local id p1s p1z p2s p2z p1type p2type p1boot p1off p2off conf append linux initrd luks=false
    [ -f "${raw}" ] || { bad "layout: ${raw} does not exist"; return 0; }
    [[ "${off}" =~ ^[0-9]+$ ]] || { bad "layout: user offset must be a byte count (got '${off}')"; return 0; }
    mbr_sig_ok "${raw}" "${off}" && ok "layout: MBR signature 55AA at +${off}" \
        || { bad "layout: no MBR signature at +${off} (wrong user-area offset, or nothing was installed)"; return 0; }
    id="$(mbr_disk_id "${raw}" "${off}")"
    [ "${id}" != "00000000" ] && ok "layout: MBR disk identifier ${id} is non-zero (root=PARTUUID=${id}-NN needs it)" \
        || bad "layout: MBR disk identifier is 00000000 — PARTUUID=<id>-02 can never match"
    p1boot="$(part_field "${raw}" "${off}" 1 boot)"; p1type="$(part_field "${raw}" "${off}" 1 type)"
    p1s="$(part_field "${raw}" "${off}" 1 start)";  p1z="$(part_field "${raw}" "${off}" 1 size)"
    p2type="$(part_field "${raw}" "${off}" 2 type)"
    p2s="$(part_field "${raw}" "${off}" 2 start)";  p2z="$(part_field "${raw}" "${off}" 2 size)"
    case "${p1type}" in 11|12|6|14) ok "layout: p1 is a FAT partition type (0x$(printf %02x "${p1type}"))" ;;
        *) bad "layout: p1 partition type 0x$(printf %02x "${p1type:-0}") is not FAT (u-boot distro-boot scans FAT/ext for extlinux)" ;; esac
    [ "${p1boot}" = "128" ] && ok "layout: p1 carries the boot flag" || bad "layout: p1 has no boot flag"
    [ "${p1s:-0}" -ge 2048 ] && ok "layout: p1 starts at sector ${p1s} (>= 1 MiB: room for an Amlogic u-boot in the user area)" \
        || bad "layout: p1 starts at sector ${p1s:-?} (< 1 MiB; a u-boot written to the user area would overlap it)"
    [ "${p2type}" = "131" ] && ok "layout: p2 is a Linux partition (0x83)" || bad "layout: p2 partition type 0x$(printf %02x "${p2type:-0}") is not 0x83"
    [ "${p1z:-0}" -gt 0 ] && [ "${p2z:-0}" -gt 0 ] || { bad "layout: empty partition(s): p1 ${p1z:-0} sectors, p2 ${p2z:-0} sectors"; return 0; }
    p1off=$(( off + p1s * 512 )); p2off=$(( off + p2s * 512 ))

    # ── p1: the boot tree u-boot's extlinux reads ──
    MTOOLS_SKIP_CHECK=1 minfo -i "${raw}@@${p1off}" >/dev/null 2>&1 && ok "layout: p1 is a FAT filesystem" \
        || { bad "layout: p1 is not a FAT filesystem"; return 0; }
    if fat_has "${raw}" "${p1off}" "extlinux/extlinux.conf"; then
        ok "layout: p1 carries /extlinux/extlinux.conf"
    else
        bad "layout: p1 has no /extlinux/extlinux.conf — the board's u-boot has nothing to boot (install-frite.sh's boot-tree copy failed silently?)"
        return 0
    fi
    conf="$(mktemp)"; fat_cat "${raw}" "${p1off}" "extlinux/extlinux.conf" > "${conf}"
    linux="$(extlinux_field "${conf}" LINUX)"; linux="${linux:-/Image}"
    fat_has "${raw}" "${p1off}" "${linux#/}" && ok "layout: kernel ${linux} is on p1" || bad "layout: extlinux LINUX ${linux} is missing from p1"
    local fdt_line; fdt_line="$(extlinux_field "${conf}" FDT)"
    if [ -z "${fdt_line}" ]; then
        bad "layout: extlinux.conf has no FDT line (mandatory on Amlogic GXL, kernel >= 5.8)"
    else
        [ "${fdt_line}" = "/dtb/${fdt}" ] && ok "layout: FDT line names the board DTB (${fdt})" \
            || bad "layout: FDT line is '${fdt_line}', expected /dtb/${fdt} for ${BOARD}"
        fat_has "${raw}" "${p1off}" "${fdt_line#/}" && ok "layout: the FDT file ${fdt_line} exists on p1" \
            || bad "layout: FDT file ${fdt_line} is MISSING from p1 (boot-tree copy without dtb/: the board would not boot)"
    fi
    initrd="$(extlinux_field "${conf}" INITRD)"
    if [ -n "${initrd}" ]; then
        fat_has "${raw}" "${p1off}" "${initrd#/}" && ok "layout: INITRD ${initrd} exists on p1" || bad "layout: INITRD ${initrd} named but missing from p1"
    fi
    append="$(extlinux_field "${conf}" APPEND)"
    [ -n "${append}" ] && ok "layout: APPEND present" || bad "layout: no APPEND line"
    case " ${append} " in
        *" root=LABEL="*) bad "layout: APPEND still says root=LABEL=… — install-frite.sh never re-pointed root= (its PARTUUID rewrite was skipped)" ;;
    esac
    if [[ " ${append} " == *" root=/dev/mapper/cryptroot "* ]]; then
        luks=true
        [[ " ${append} " == *" rd.luks.uuid="* ]] && [[ " ${append} " == *" rd.luks.name="*"=cryptroot "* ]] \
            && ok "layout: encrypted root — rd.luks.uuid= and rd.luks.name=…=cryptroot are on APPEND" \
            || bad "layout: root=/dev/mapper/cryptroot without rd.luks.uuid=/rd.luks.name= (dracut would name the mapper luks-<uuid>)"
        [ -n "${initrd}" ] || bad "layout: encrypted root but no INITRD line (nothing can unlock it)"
    else
        [[ " ${append} " == *" root=PARTUUID=${id}-02 "* ]] \
            && ok "layout: APPEND root=PARTUUID=${id}-02 matches the MBR id and partition 2" \
            || bad "layout: APPEND root= is '$(printf '%s\n' "${append}" | tr ' ' '\n' | grep '^root=' | head -1)', expected root=PARTUUID=${id}-02"
    fi
    [[ " ${append} " == *" lsm="* ]] && ok "layout: APPEND keeps the lsm= posture" \
        || bad "layout: APPEND lost the lsm= posture from cmdline.base"
    if [ -n "${out}" ]; then
        mkdir -p "${out}"
        cp "${conf}" "${out}/extlinux.conf"
        MTOOLS_SKIP_CHECK=1 mcopy -n -i "${raw}@@${p1off}" "::${linux#/}" "${out}/Image" 2>/dev/null || true
        [ -z "${initrd}" ] || MTOOLS_SKIP_CHECK=1 mcopy -n -i "${raw}@@${p1off}" "::${initrd#/}" "${out}/initrd.img" 2>/dev/null || true
    fi
    rm -f "${conf}"

    # ── p2: the installed root ──
    if ${luks}; then
        [ "$(od -An -c -j "${p2off}" -N 4 "${raw}" 2>/dev/null | tr -d ' ')" = "LUKS" ] \
            && ok "layout: p2 carries a LUKS header" || bad "layout: APPEND says LUKS but p2 has no LUKS header"
        info "layout: encrypted root — fstab/xattr checks need the passphrase; they run in phase B over ssh"
        return 0
    fi
    local fstab
    fstab="$(ext_cat "${raw}" "${p2off}" /etc/fstab || true)"
    [ -n "${fstab}" ] && ok "layout: p2 is ext4 with an /etc/fstab" || { bad "layout: p2 is not a readable ext4 root (no /etc/fstab)"; return 0; }
    if printf '%s\n' "${fstab}" | grep -E '^[[:space:]]*LABEL=FRITE_(ROOT|BOOT)' >/dev/null; then
        bad "layout: /etc/fstab still mounts LABEL=FRITE_ROOT/FRITE_BOOT — install-frite.sh's fstab rewrite was skipped"
    else
        ok "layout: /etc/fstab no longer references LABEL=FRITE_ROOT/FRITE_BOOT"
    fi
    printf '%s\n' "${fstab}" | grep -E "^[[:space:]]*PARTUUID=${id}-02[[:space:]]" >/dev/null \
        && ok "layout: /etc/fstab mounts / by PARTUUID=${id}-02" || bad "layout: /etc/fstab does not mount / by PARTUUID=${id}-02"
    printf '%s\n' "${fstab}" | grep -E "^[[:space:]]*PARTUUID=${id}-01[[:space:]]" >/dev/null \
        && ok "layout: /etc/fstab mounts /boot by PARTUUID=${id}-01" || bad "layout: /etc/fstab does not mount /boot by PARTUUID=${id}-01"
    local f labelled=0 probed=0
    for f in /etc/passwd /bin/sh /etc/fstab; do
        ext_cat "${raw}" "${p2off}" "${f}" >/dev/null 2>&1 || continue
        probed=$((probed+1))
        ext_ea "${raw}" "${p2off}" "${f}" | grep -E '^[[:space:]]*security\.selinux' >/dev/null && labelled=$((labelled+1))
    done
    if [ "${probed}" -eq 0 ]; then
        bad "layout: none of /etc/passwd /bin/sh /etc/fstab exist on p2 — the stage4 was not extracted"
    elif [ "${labelled}" -eq "${probed}" ]; then
        ok "layout: security.selinux xattrs survived the install on ${probed}/${probed} probed files"
    elif ${ALLOW_UNLABELLED}; then
        soft "layout: security.selinux present on ${labelled}/${probed} probed files (--allow-unlabelled: the Frite stage4 is not labelled at build time yet)"
    else
        bad "layout: security.selinux xattrs on only ${labelled}/${probed} probed files — labels were not preserved (tar without --xattrs, or an unlabelled stage4; --allow-unlabelled downgrades this)"
    fi
}

summary() {
    echo
    echo "== RESULT: ${PASS} passed, ${FAIL} failed, ${WARNED} warned =="
    [ "${FAIL}" -eq 0 ]
}

# ── Offline mode ─────────────────────────────────────────────────────────────
if [ -n "${CHECK_LAYOUT}" ]; then
    for t in od mdir mtype mcopy minfo debugfs awk; do
        command -v "${t}" >/dev/null 2>&1 || die "--check-layout needs ${t} (mtools + e2fsprogs)"
    done
    [ -n "${CHECK_FDT}" ] || CHECK_FDT="$(board_fdt "${BOARD}")"
    [ -n "${CHECK_FDT}" ] || die "no FDT known for board ${BOARD} (pass --fdt)"
    step "Offline eMMC layout check: ${CHECK_LAYOUT} (user area at +${CHECK_USER_OFFSET:-0}, FDT ${CHECK_FDT})"
    check_emmc_layout "${CHECK_LAYOUT}" "${CHECK_USER_OFFSET:-0}" "${CHECK_FDT}"
    summary; exit $?
fi

# ── Online preflight ─────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] || die "run as a normal user: nothing here needs root (mtools/debugfs read the images, QEMU runs unprivileged)"
case "${PHASE}" in a|b|both) ;; *) die "--phase must be a, b or both" ;; esac
for t in qemu-system-aarch64 qemu-img ssh ssh-keygen mformat mcopy mdir mtype minfo mkfs.vfat sfdisk debugfs od python3 awk; do
    command -v "${t}" >/dev/null 2>&1 || die "missing ${t}"
done
qemu-system-aarch64 -device help 2>/dev/null | grep -E '^name "emmc"' >/dev/null \
    || die "this qemu-system-aarch64 has no 'emmc' device: need QEMU >= 9.1 on the HOST (the runner image's 7.2 only has sd-card)"
[ -x "${LAUNCHER}" ] || [ -f "${LAUNCHER}" ] || die "missing ${LAUNCHER}"
[ -f "${MAKE_KEYS}" ] || die "missing ${MAKE_KEYS}"
[[ "${USER_NAME}" =~ ^[a-z][a-z0-9]{0,31}$ ]] || die "--user must be [a-z][a-z0-9]* (it is typed through QMP send-key, unshifted)"
FDT_NAME="$(board_fdt "${BOARD}")"; [ -n "${FDT_NAME}" ] || die "no FDT known for board ${BOARD} in launch-arm.sh's table"

if [ -z "${MEDIUM}" ] && [ "${PHASE}" != "b" ]; then
    MEDIUM="$(ls -1t "${WORK_DIR}"/*-frite-"${BOARD}"-arm64-*.installer.img "${WORK_DIR}"/*-frite-"${BOARD}"-arm64-*.installer.iso 2>/dev/null | head -1 || true)"
    [ -n "${MEDIUM}" ] || die "no installer medium under ${WORK_DIR} (*-frite-${BOARD}-arm64-*.installer.{img,iso}); pass --medium"
fi
[ -z "${MEDIUM}" ] || [ -f "${MEDIUM}" ] || die "medium not found: ${MEDIUM}"

[ -n "${RUN_DIR}" ] || RUN_DIR="${WORK_DIR}/frite-emmc-run"
mkdir -p "${RUN_DIR}"; chmod 0700 "${RUN_DIR}"
EMMC="${RUN_DIR}/emmc.raw"
EMMC_USER_OFFSET=$(( 2 * EMMC_BOOT_SIZE + EMMC_RPMB_SIZE ))
KEYS_DIR="${RUN_DIR}/keys"; KEYS_IMG="${RUN_DIR}/keys.img"
SSH_KEY="${RUN_DIR}/id_ed25519"
PASS_FILE="${RUN_DIR}/login-password"
QEMU_PID=""
cleanup() {
    [ -n "${QEMU_PID}" ] && kill "${QEMU_PID}" 2>/dev/null || true
    if ! ${KEEP}; then
        rm -f "${EMMC}" "${KEYS_IMG}" "${SSH_KEY}" "${SSH_KEY}.pub" "${PASS_FILE}" "${RUN_DIR}/luks-passphrase"
        rm -rf "${KEYS_DIR}"
    fi
}
trap cleanup EXIT

# ONE build / ONE QEMU at a time across the machine (operator rule): wait, poll
# every 2 minutes, up to 4 hours, for every other qemu-system and every
# hugmesh-builder / hugmesh-qemu-runner container to be gone.
wait_idle() {
    local deadline=$(( SECONDS + 4 * 3600 )) busy
    while :; do
        busy=""
        pgrep -x 'qemu-system-aarch64' >/dev/null 2>&1 && busy="qemu-system-aarch64"
        pgrep -x 'qemu-system-x86_64'  >/dev/null 2>&1 && busy="${busy:+${busy} }qemu-system-x86_64"
        if command -v docker >/dev/null 2>&1; then
            local c; c="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -E 'hugmesh-builder|hugmesh-qemu-runner' | head -3 | tr '\n' ' ' || true)"
            [ -z "${c}" ] || busy="${busy:+${busy} }${c}"
        fi
        [ -z "${busy}" ] && return 0
        [ "${SECONDS}" -lt "${deadline}" ] || die "still busy after 4 h: ${busy}"
        info "waiting for the machine to be idle (${busy}) — next poll in 2 min"
        sleep 120
    done
}

# ── QMP + serial helpers (python3 on the host; the runner's perl trick is for a
# container that has no python — this driver never runs there) ───────────────
qmp() { # qmp SOCK COMMAND [JSON-ARGS]
    python3 -I - "$1" "$2" "${3:-{\}}" <<'PY'
import json, socket, sys
path, cmd, args = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
s = socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(path); f = s.makefile("rw")
json.loads(f.readline())                               # greeting
def run(c, a):
    f.write(json.dumps({"execute": c, "arguments": a}) + "\n"); f.flush()
    while True:
        d = json.loads(f.readline())
        if "return" in d or "error" in d: return d
run("qmp_capabilities", {})
r = run(cmd, args)
print(json.dumps(r))
sys.exit(0 if "return" in r else 1)
PY
}
screendump() { # screendump SOCK OUT_BASENAME -> prints the file written
    local sock="$1" base="$2"
    if qmp "${sock}" screendump "{\"filename\": \"${base}.png\", \"format\": \"png\"}" >/dev/null 2>&1 && [ -s "${base}.png" ]; then
        printf '%s\n' "${base}.png"; return 0
    fi
    rm -f "${base}.png"
    qmp "${sock}" screendump "{\"filename\": \"${base}.ppm\"}" >/dev/null && [ -s "${base}.ppm" ] \
        && { printf '%s\n' "${base}.ppm"; return 0; }
    return 1
}
# Type STRING + Return through QMP send-key. Only [a-z0-9] (unshifted qcodes).
type_keys() {
    local sock="$1" s="$2" i ch
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:i:1}"
        case "${ch}" in
            [a-z0-9]) ;;
            *) die "type_keys: '${ch}' is not [a-z0-9]" ;;
        esac
        qmp "${sock}" send-key "{\"keys\":[{\"type\":\"qcode\",\"data\":\"${ch}\"}]}" >/dev/null || return 1
        sleep 0.3
    done
    qmp "${sock}" send-key '{"keys":[{"type":"qcode","data":"ret"}]}' >/dev/null
}
# Write a line to the serial socket (the dracut passphrase prompt).
serial_write() { # serial_write SOCK TEXT
    python3 -I - "$1" "$2" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.5); s.close()
PY
}
images_differ() { # images_differ A B  (same format; raw byte compare past the header)
    ! cmp -s "$1" "$2"
}

SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
gssh() { ssh "${SSH_OPTS[@]}" "${USER_NAME}@localhost" "$@"; }

# wait_boot CONSOLE PHASE — ssh answers, or a NAMED console failure, or timeout.
wait_boot() {
    local console="$1" phase="$2" deadline=$(( SECONDS + TIMEOUT )) luks_sent=false
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if gssh true 2>/dev/null; then return 0; fi
        if [ -f "${console}" ]; then
            if grep -E 'Kernel panic - not syncing' "${console}" >/dev/null; then
                bad "${phase}: guest kernel panicked (see ${console})"; return 1
            fi
            # A plaintext install boots with NO initramfs: a kernel without
            # CONFIG_MMC_SDHCI_PCI never sees mmcblk0 and, with rootwait on the
            # cmdline, waits for root FOREVER — no panic, no dracut line. That must
            # be a named failure, not an hour-long timeout.
            if grep -E 'Waiting for root device|VFS: Unable to mount root fs|VFS: Cannot open root device' "${console}" >/dev/null; then
                bad "${phase}: the kernel cannot find its root device (phase B: no /dev/mmcblk0 — the Frite kernel lacks CONFIG_MMC_SDHCI_PCI, or root=PARTUUID does not match the eMMC's MBR id; see ${console})"; return 1
            fi
            if grep -E 'Entering emergency mode|Could not boot|dracut-initqueue.*(timeout|Warning: .*root)' "${console}" >/dev/null; then
                bad "${phase}: dracut gave up — the initramfs did not find its root (phase A: the medium on bus=${MEDIUM_BUS}; retry --medium-bus virtio if the live initramfs lacks USB storage drivers. phase B: root=PARTUUID on the eMMC — CONFIG_MMC_SDHCI_PCI missing?)"; return 1
            fi
            if ! ${luks_sent} && [ -n "${LUKS_PASS}" ] && [ -n "${SERIAL_SOCK:-}" ] \
               && grep -E 'Please enter passphrase|passphrase for' "${console}" >/dev/null; then
                info "${phase}: answering the dracut LUKS prompt"
                serial_write "${SERIAL_SOCK}" "${LUKS_PASS}" || warn "could not write to ${SERIAL_SOCK}"
                luks_sent=true
            fi
        fi
        [ -z "${QEMU_PID}" ] || kill -0 "${QEMU_PID}" 2>/dev/null || { bad "${phase}: QEMU exited before ssh answered (see ${console})"; return 1; }
        sleep 10
    done
    bad "${phase}: no ssh within ${TIMEOUT}s (console: ${console})"; return 1
}

launch() { # launch RUN_SUBDIR LAUNCHER-ARGS...
    local sub="$1"; shift
    local rd="${RUN_DIR}/${sub}"
    rm -rf "${rd}"; mkdir -p "${rd}"
    QMP_SOCK="${rd}/qmp.sock"; SERIAL_SOCK="${rd}/serial.sock"; CONSOLE="${rd}/console.log"
    # set +e around the tee'd pipeline: under set -e a non-zero launcher would
    # kill THIS script on the pipeline itself, the die below would never run, and
    # the EXIT trap would delete emmc.raw + the KEYS stick before anyone read
    # launch.log (docker-entrypoint.sh does the same around run-qemu-test.sh).
    local lrc
    set +e
    bash "${LAUNCHER}" --platform "${PLATFORM}" --board "${BOARD}" \
        --run-dir "${rd}" --keep --mem "${MEM}" --smp "${SMP}" --ssh-port "${SSH_PORT}" \
        --keys-img "${KEYS_IMG}" --gpu --qmp "${QMP_SOCK}" --serial-sock "${SERIAL_SOCK}" \
        --emmc "${EMMC}" --emmc-boot-size "${EMMC_BOOT_SIZE}" --emmc-rpmb-size "${EMMC_RPMB_SIZE}" \
        "$@" 2>&1 | tee "${rd}/launch.log"
    lrc=${PIPESTATUS[0]}
    set -e
    [ "${lrc}" -eq 0 ] || die "launch-arm.sh failed (rc=${lrc}; see ${rd}/launch.log)"
    QEMU_PID="$(cat "${rd}/qemu.pid" 2>/dev/null || true)"
    [ -n "${QEMU_PID}" ] || die "no qemu.pid under ${rd}"
}
stop_guest() { # orderly poweroff, then kill
    local i
    gssh 'sudo poweroff' >/dev/null 2>&1 || true
    for i in $(seq 1 60); do kill -0 "${QEMU_PID}" 2>/dev/null || break; sleep 5; done
    kill "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=""
}

# ── Per-run credentials + KEYS stick ─────────────────────────────────────────
# [a-z0-9] only: typed through QMP send-key (unshifted qcodes) and at the dracut
# prompt. No `tr </dev/urandom | head` — under pipefail that pipeline is a SIGPIPE
# coin flip and `set -e` would kill the run on the losing side.
gen_secret() { python3 -I -c 'import secrets,string,sys; print("".join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range(int(sys.argv[1]))))' "$1"; }
make_keys() {
    step "Generating per-run credentials + KEYS stick (${KEYS_IMG})"
    rm -rf "${KEYS_DIR}"; mkdir -p "${KEYS_DIR}/ssh"
    ssh-keygen -q -t ed25519 -N '' -C "frite-emmc-install" -f "${SSH_KEY}" </dev/null
    local pw; pw="$(gen_secret 14)"
    ( umask 077; printf '%s' "${pw}" > "${PASS_FILE}" )
    if [ -z "${LUKS_PASS}" ]; then LUKS_PASS="$(gen_secret 20)"; fi
    ( umask 077; printf '%s' "${LUKS_PASS}" > "${RUN_DIR}/luks-passphrase" )
    local pub; pub="$(cat "${SSH_KEY}.pub")"
    cat > "${KEYS_DIR}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "frite-emmc-qemu",
  "timezone": "UTC",
  "headscale": { "enabled": false },
  "tailscale": { "enabled": false },
  "kubernetes": { "role": "none", "bootstrap": false },
  "hugmesh": { "role": "desktop", "gitops": { "enabled": false } }
}
EOF
    ( umask 077; cat > "${KEYS_DIR}/users.json" <<EOF
{
  "users": [
    {
      "name": "${USER_NAME}",
      "comment": "frite eMMC install proof",
      "groups": ["wheel", "audio", "video", "usb", "input"],
      "shell": "/bin/bash",
      "uid": 1000,
      "sudo": true,
      "sudo_nopasswd": true,
      "password": "${pw}",
      "ssh_authorized_keys": ["${pub}"]
    }
  ]
}
EOF
    )
    bash "${MAKE_KEYS}" "${KEYS_DIR}" "${KEYS_IMG}" 64 >/dev/null
    chmod 0600 "${KEYS_IMG}"
    info "login user ${USER_NAME}: password in ${PASS_FILE} (0600), ssh key ${SSH_KEY} — neither is printed"
}

# ── Phase A ──────────────────────────────────────────────────────────────────
phase_a() {
    step "Phase A: boot the installer medium with an emulated eMMC target"
    rm -f "${EMMC}"
    truncate -s $(( EMMC_USER_SIZE + EMMC_USER_OFFSET )) "${EMMC}"
    info "eMMC backing file ${EMMC}: user area ${EMMC_USER_SIZE} bytes at +${EMMC_USER_OFFSET} (2 x ${EMMC_BOOT_SIZE} boot + ${EMMC_RPMB_SIZE} rpmb)"
    launch phase-a --medium "${MEDIUM}" --medium-bus "${MEDIUM_BUS}" --timeout "${TIMEOUT}"
    local console="${CONSOLE}" sock="${QMP_SOCK}"
    wait_boot "${console}" "phase A" || { stop_guest; return 0; }
    ok "phase A: live medium booted, KEYS user ${USER_NAME} answers ssh"
    screendump "${sock}" "${RUN_DIR}/phase-a-live" >/dev/null && ok "phase A: screenshot of the live session saved" || soft "phase A: screendump failed"

    # Storage topology the installer must see.
    local t
    t="$(gssh 'cat /sys/block/mmcblk0/device/type 2>/dev/null' || true)"
    if [ "${t}" = "MMC" ]; then
        ok "phase A: /dev/mmcblk0 is an MMC (eMMC) device, like La Frite's module"
    else
        bad "phase A: no /dev/mmcblk0 of type MMC in the guest (got '${t:-<none>}') — the Frite kernel lacks CONFIG_MMC_SDHCI_PCI (specs-frite/kernel/hardened-desktop.config), or the sdhci-pci host did not probe"
        stop_guest; return 0
    fi
    gssh 'test -e /sys/block/mmcblk0boot0 && test -e /sys/block/mmcblk0boot1' \
        && ok "phase A: mmcblk0boot0/boot1 exist (boot partitions, ${EMMC_BOOT_SIZE} bytes each)" \
        || bad "phase A: mmcblk0boot0/1 missing — the installer must refuse them as targets, so they have to exist here"
    local gsize; gsize="$(gssh 'cat /sys/block/mmcblk0/size' || echo 0)"
    [ $(( gsize * 512 )) -eq "${EMMC_USER_SIZE}" ] && ok "phase A: mmcblk0 user area is ${EMMC_USER_SIZE} bytes (boot partitions excluded)" \
        || bad "phase A: mmcblk0 reports $(( gsize * 512 )) bytes, expected ${EMMC_USER_SIZE}"
    local mmcs; mmcs="$(gssh 'for b in /sys/block/mmcblk*; do case "$b" in *boot*|*rpmb*) continue;; esac; [ "$(cat $b/device/type 2>/dev/null)" = MMC ] && basename "$b"; done' || true)"
    [ "$(printf '%s\n' "${mmcs}" | grep -c . || true)" -eq 1 ] && [ "${mmcs}" = "mmcblk0" ] \
        && ok "phase A: exactly one MMC-type block device, and it is mmcblk0 (the La Frite layout)" \
        || bad "phase A: MMC-type block devices: '${mmcs}' (expected exactly mmcblk0)"
    local live; live="$(gssh 'findmnt -no SOURCE /run/initramfs/live 2>/dev/null' || true)"
    case "${MEDIUM_BUS}" in
        usb)    [[ "${live}" == /dev/sd* ]] && ok "phase A: the medium is mounted from ${live} (usb-storage, as a real stick)" || bad "phase A: /run/initramfs/live is '${live:-<unmounted>}', expected /dev/sdX (usb-storage)" ;;
        virtio) [[ "${live}" == /dev/vd* ]] && ok "phase A: the medium is mounted from ${live} (virtio)" || bad "phase A: /run/initramfs/live is '${live:-<unmounted>}', expected /dev/vdX" ;;
    esac
    gssh 'test -x /run/initramfs/live/install-frite.sh && test -d /run/initramfs/live/stage4 && test -f /run/initramfs/live/boot/extlinux/extlinux.conf' \
        && ok "phase A: the medium carries install-frite.sh, stage4/ and boot/extlinux/extlinux.conf" \
        || { bad "phase A: the medium lacks install-frite.sh / stage4/ / boot/extlinux — not an INSTALLER medium"; stop_guest; return 0; }
    local encrypted=false
    gssh 'test -f /run/initramfs/live/encrypt-root' && encrypted=true
    ${encrypted} && info "phase A: encrypt-root marker present — the install will be LUKS2 (passphrase typed at the dracut prompt in phase B)"

    # The installer. --yes is taken when the script advertises it (another fix
    # group adds it); the interactive confirm is answered on stdin otherwise.
    step "Phase A: running install-frite.sh against the detected eMMC (/dev/mmcblk0)"
    # Everything the installer asks is answered on STDIN, in the order it asks:
    # the ERASE confirm (unless --yes exists, then it never asks) and, for an
    # encrypt-root medium, the passphrase twice. The passphrase never touches
    # argv (ps) or the log.
    local yes_flag="" stdin_lines=""
    gssh 'grep -E -- "--yes|--unattended" /run/initramfs/live/install-frite.sh >/dev/null' && yes_flag="--yes"
    [ -n "${yes_flag}" ] || stdin_lines="y"$'\n'
    ${encrypted} && stdin_lines="${stdin_lines}${LUKS_PASS}"$'\n'"${LUKS_PASS}"$'\n'
    local rc=0
    printf '%s' "${stdin_lines}" | gssh "sudo /run/initramfs/live/install-frite.sh ${yes_flag} /dev/mmcblk0" > "${RUN_DIR}/phase-a/install.log" 2>&1 || rc=$?
    stdin_lines=""
    if [ "${rc}" -eq 0 ] && grep -E '==> Done' "${RUN_DIR}/phase-a/install.log" >/dev/null; then
        ok "phase A: install-frite.sh exited 0 and reported Done (log: ${RUN_DIR}/phase-a/install.log)"
    else
        bad "phase A: install-frite.sh exited ${rc} (log: ${RUN_DIR}/phase-a/install.log)"
    fi
    gssh 'sync' || true
    stop_guest
    ok "phase A: guest powered off; the medium is now detached"
}

# ── Phase B ──────────────────────────────────────────────────────────────────
phase_b() {
    step "Between phases: offline layout check of the installed eMMC (${EMMC}, user area at +${EMMC_USER_OFFSET})"
    [ -s "${EMMC}" ] || { bad "phase B: no eMMC backing file ${EMMC} (run phase a first)"; return 0; }
    local bdir="${RUN_DIR}/phase-b-boot"; rm -rf "${bdir}"
    check_emmc_layout "${EMMC}" "${EMMC_USER_OFFSET}" "${FDT_NAME}" "${bdir}"
    [ -s "${bdir}/Image" ] || { bad "phase B: could not lift the kernel off the eMMC's FAT — nothing to boot"; return 0; }
    [ -s "${bdir}/extlinux.conf" ] || { bad "phase B: no extlinux.conf lifted off the eMMC"; return 0; }

    step "Phase B: boot the eMMC ALONE (its own kernel + APPEND; no medium)"
    local initrd_args=()
    [ -s "${bdir}/initrd.img" ] && initrd_args=(--initrd "${bdir}/initrd.img")
    launch phase-b --kernel "${bdir}/Image" --extlinux "${bdir}/extlinux.conf" "${initrd_args[@]}" --timeout "${TIMEOUT}"
    local console="${CONSOLE}" sock="${QMP_SOCK}"
    wait_boot "${console}" "phase B" || { stop_guest; return 0; }
    ok "phase B: the installed eMMC booted on its own and ${USER_NAME} answers ssh"
    local rootsrc; rootsrc="$(gssh 'findmnt -no SOURCE /' || true)"
    case "${rootsrc}" in
        /dev/mmcblk0p2|/dev/mapper/cryptroot) ok "phase B: / is mounted from ${rootsrc}" ;;
        *) bad "phase B: / is mounted from '${rootsrc}', expected /dev/mmcblk0p2 or /dev/mapper/cryptroot" ;;
    esac
    gssh 'test ! -e /run/initramfs/live' && ok "phase B: no live medium mounted — this is the eMMC, not the installer" || bad "phase B: /run/initramfs/live exists: the guest is still running the live medium"
    gssh 'test -c /dev/dri/card0' && ok "phase B: a DRM device exists (virtio-gpu)" \
        || bad "phase B: no /dev/dri/card0 — the Frite kernel lacks CONFIG_DRM_VIRTIO_GPU (and VIRTIO_INPUT); the greeter cannot be drawn here"
    local i greeter=false
    for i in $(seq 1 30); do
        gssh 'pgrep -x lightdm >/dev/null && pgrep -x Xorg >/dev/null && pgrep -f lightdm-gtk-greeter >/dev/null' && { greeter=true; break; }
        sleep 10
    done
    ${greeter} && ok "phase B: lightdm + Xorg + lightdm-gtk-greeter are running" || bad "phase B: no lightdm/Xorg/greeter processes after 300s"
    local shot1 shot2
    shot1="$(screendump "${sock}" "${RUN_DIR}/phase-b-greeter" || true)"
    [ -n "${shot1}" ] && ok "phase B: greeter screenshot ${shot1}" || bad "phase B: greeter screendump failed"

    step "Phase B: logging in at the greeter (QMP send-key)"
    local pw; pw="$(cat "${PASS_FILE}")"
    local logged=false
    # lightdm-gtk-greeter with one user: the user is preselected and the password
    # entry has focus — password + Return. If the greeter shows a username entry
    # instead, that typed the password where the name goes; the second attempt
    # types the name, Return, then the password.
    type_keys "${sock}" "${pw}"
    for i in $(seq 1 $(( LOGIN_TIMEOUT / 5 ))); do
        gssh "pgrep -u ${USER_NAME} -x openbox >/dev/null || pgrep -u ${USER_NAME} -x lxsession >/dev/null" && { logged=true; break; }
        sleep 5
    done
    if ! ${logged}; then
        info "phase B: no session after password-only; retrying with username + Return + password"
        type_keys "${sock}" "${USER_NAME}"; sleep 2; type_keys "${sock}" "${pw}"
        for i in $(seq 1 $(( LOGIN_TIMEOUT / 5 ))); do
            gssh "pgrep -u ${USER_NAME} -x openbox >/dev/null || pgrep -u ${USER_NAME} -x lxsession >/dev/null" && { logged=true; break; }
            sleep 5
        done
    fi
    sleep 5
    shot2="$(screendump "${sock}" "${RUN_DIR}/phase-b-session" || true)"
    if ${logged}; then
        ok "phase B: greeter accepted the password — ${USER_NAME}'s session is up"
        gssh "pgrep -u ${USER_NAME} -x openbox >/dev/null" && ok "phase B: openbox runs as ${USER_NAME}" || bad "phase B: openbox is not running as ${USER_NAME}"
        gssh "pgrep -u ${USER_NAME} -x lxsession >/dev/null || pgrep -u ${USER_NAME} -x lxpanel >/dev/null" && ok "phase B: lxsession/lxpanel runs as ${USER_NAME}" || soft "phase B: no lxsession/lxpanel for ${USER_NAME} (openbox-only session?)"
        gssh "loginctl list-sessions --no-legend 2>/dev/null | grep -E '[[:space:]]${USER_NAME}[[:space:]]+seat0' >/dev/null" \
            && ok "phase B: elogind has a seat0 session for ${USER_NAME}" || soft "phase B: no elogind seat0 session listed for ${USER_NAME}"
        [ -n "${shot2}" ] && ok "phase B: session screenshot ${shot2}" || bad "phase B: session screendump failed"
        if [ -n "${shot1}" ] && [ -n "${shot2}" ]; then
            images_differ "${shot1}" "${shot2}" && ok "phase B: the screen changed between greeter and session" || bad "phase B: greeter and session screenshots are byte-identical — nothing was drawn"
        fi
    else
        bad "phase B: no openbox/lxsession for ${USER_NAME} within ${LOGIN_TIMEOUT}s of typing the password (greeter: ${shot1:-none}; after: ${shot2:-none})"
    fi
    stop_guest
}

# ── Main ─────────────────────────────────────────────────────────────────────
${WAIT_IDLE} && wait_idle
info "board ${BOARD} (FDT ${FDT_NAME}); medium ${MEDIUM:-<none: phase b>}; run dir ${RUN_DIR}"
echo "  CANNOT PROVE here: Amlogic boot ROM -> SPI-NOR u-boot -> eMMC boot order, u-boot's mmc numbering,"
echo "  the meson-gxl FDT against the silicon, meson DRM/lima HDMI, eMMC HS timing. The layout check +"
echo "  real hardware cover those."
case "${PHASE}" in
    a)    make_keys; phase_a ;;
    b)    [ -s "${KEYS_IMG}" ] && [ -s "${SSH_KEY}" ] && [ -s "${PASS_FILE}" ] || die "--phase b needs the KEYS stick + credentials of a --keep'd phase a under ${RUN_DIR}"
          [ -s "${RUN_DIR}/luks-passphrase" ] && LUKS_PASS="$(cat "${RUN_DIR}/luks-passphrase")"
          phase_b ;;
    both) make_keys; phase_a; [ "${FAIL}" -eq 0 ] && phase_b || warn "skipping phase B: phase A already failed" ;;
esac
echo
info "artefacts: ${RUN_DIR}/phase-a/console.log ${RUN_DIR}/phase-a/install.log ${RUN_DIR}/phase-b/console.log ${RUN_DIR}/phase-b-*.{png,ppm}"
summary
