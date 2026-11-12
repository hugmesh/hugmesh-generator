#!/usr/bin/env bash
# test-frite-install-layout.sh — the OFFLINE proof of the Frite media and of the
# eMMC layout the installer writes, for everything QEMU cannot boot.
#
# WHY THIS EXISTS. No Frite image had ever been built or booted on this
# infrastructure, and a real board is the only thing that can prove the Amlogic
# boot ROM -> u-boot -> extlinux chain. What CAN be proven here, rootless and in
# seconds, is the shape of what that chain reads:
#
#   MEDIUM   build-frite-stage4.sh used to emit the LIVE / INSTALLER media as plain
#            ISO9660 (`xorriso -as mkisofs`, no partition table). u-boot's
#            distro-boot scans PARTITIONS for /extlinux/extlinux.conf through its
#            FAT/ext drivers and has no ISO9660 driver, so the media could not boot
#            on the board. The builder now assembles a raw .img (MBR + one FAT32
#            partition at 4 MiB) with `build_frite_medium` — ROOTLESS, from regular
#            files — and that EXACT function is extracted from the builder and
#            executed below on a fixture tree, then read back with sfdisk, blkid
#            and mtools.
#   eMMC     specs-frite/installer/install-frite.sh partitions the target with
#            ONE sfdisk write carrying an explicit disk id (p1 at 8 MiB, clear of
#            the Amlogic BL2/FIP), rewrites root= in extlinux.conf through
#            ${ROOT_ARG} and rewrites the two LABEL= lines of /etc/fstab. Its
#            layout constants, sfdisk write, ROOT_ARG/FSTAB_ROOT assignments and
#            sed lines are extracted from the script and run against regular
#            files (sfdisk on a file, mkfs.vfat on a file, mke2fs
#            -d populating ext4 from a directory): root= must equal the PARTUUID
#            of partition 2 as blkid and sfdisk independently report it, the FDT
#            and kernel must be on the FAT, fstab must be rewritten, and the
#            xattrs the stage4 carries must reach the ext4 root.
#   STAGE4   the builder's own pack section (one `tar --xattrs` with no
#            `2>/dev/null ||` fallback) is executed on a fixture sysroot; the
#            archive must carry the xattrs and the builder must gate the sysroot
#            (slx_label_tree) and the tarball (slx_tar_label_gate) fail-closed.
#   FLAGS    `--standalone --with-tailscale` must keep the tailnet (situation 2 of
#            the operator's matrix: on a tailnet, no mesh association) — the real
#            posture block is executed both ways; the post-build hint must not
#            hard-code /dev/mmcblk0.
#
# WHAT IT DOES NOT PROVE. The security.selinux namespace: an unprivileged process
# cannot set security.* xattrs (measured: setfattr -> Operation not permitted;
# tar extracts them silently dropped), so the carrier here is user.* — the same
# tar/mke2fs plumbing, a namespace the build-time gate (slx_tar_label_gate) does
# check with real labels. Nor the Amlogic boot ROM, the SPI-NOR u-boot's boot
# order, u-boot's mmc numbering or the board FDT: those need hardware.
#
# Overrides for mutation runs: FRITE_BUILDER, FRITE_INSTALLER, FRITE_FSTAB,
# FRITE_EXTLINUX_TMPL point the checks at a modified copy.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${FRITE_BUILDER:-${REPO}/build-frite-stage4.sh}"
INSTALLER="${FRITE_INSTALLER:-${REPO}/specs-frite/installer/install-frite.sh}"
FSTAB="${FRITE_FSTAB:-${REPO}/specs-frite/etc/fstab}"
TMPL="${FRITE_EXTLINUX_TMPL:-${REPO}/specs-frite/boot/extlinux.conf.tmpl}"
LIB="${REPO}/scripts/_builder-resume-lib.sh"
# shellcheck source=../lib/guard-preflight.sh
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools bash awk sed grep tar xz sfdisk blkid mkfs.vfat mcopy mdir mtype mlabel \
    mke2fs debugfs getfattr setfattr du dd truncate stat od head cut sort sha256sum
for f in "${BUILDER}" "${INSTALLER}" "${FSTAB}" "${TMPL}" "${LIB}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/frite-layout.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
export MTOOLS_SKIP_CHECK=1
has() { grep -F -q -- "$2" "$1"; }
MiB=$((1024 * 1024))

echo "== frite media + eMMC install layout (offline) =="

# ═════════════════════════ 1. static pins on the builder ══════════════════════
echo "-- 1) builder: raw media, labelling, one fatal xattr pack --"
bash -n "${BUILDER}" && ok "builder parses (bash -n)" || bad "builder does not parse"
MEDIUM_SRC="$(awk '/^FRITE_MEDIUM_P1_MIB=/ {on=1} on {print} on && /^}$/ {exit}' "${BUILDER}")"
if printf '%s\n' "${MEDIUM_SRC}" | grep '^build_frite_medium() {' >/dev/null; then
    ok "build_frite_medium() is defined (sliced $(printf '%s\n' "${MEDIUM_SRC}" | wc -l) lines)"
else
    bad "could not slice FRITE_MEDIUM_P1_MIB= .. build_frite_medium() from the builder"
fi
grep -E -q 'build_frite_medium "\$\{live_root\}" FRITE_LIVE "\$\{LIVE_PATH\}"' "${BUILDER}" \
    && ok "LIVE medium is assembled by build_frite_medium with label FRITE_LIVE" \
    || bad "LIVE medium is not assembled by build_frite_medium / label FRITE_LIVE"
grep -E -q 'build_frite_medium "\$\{inst_root\}" FRITE_INST "\$\{INSTALLER_PATH\}"' "${BUILDER}" \
    && ok "INSTALLER medium is assembled by build_frite_medium with label FRITE_INST" \
    || bad "INSTALLER medium is not assembled by build_frite_medium / label FRITE_INST"
grep -E -q 'LIVE_PATH="\$\{WORK_DIR\}/\$\{ART_PREFIX\}\.live\.img"' "${BUILDER}" \
    && grep -E -q 'INSTALLER_PATH="\$\{WORK_DIR\}/\$\{ART_PREFIX\}\.installer\.img"' "${BUILDER}" \
    && ok "the deliverables are <prefix>.live.img / <prefix>.installer.img" \
    || bad "the media are not named .live.img / .installer.img"
# ISO9660 only behind --medium-iso: every xorriso invocation sits in wrap_frite_iso.
n_xorriso="$(grep -c 'xorriso -as mkisofs' "${BUILDER}")"
if [ "${n_xorriso}" -eq 1 ] && awk '/^wrap_frite_iso\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "${BUILDER}" | grep 'xorriso -as mkisofs' >/dev/null \
   && grep -q -- '--medium-iso)' "${BUILDER}"; then
    ok "ISO9660 is opt-in: one xorriso call, inside wrap_frite_iso, behind --medium-iso"
else
    bad "ISO9660 is not strictly opt-in (${n_xorriso} xorriso call(s); wrap_frite_iso / --medium-iso)"
fi
INST_APPEND="$(grep -o 'root=live:LABEL=FRITE_INST[^"]*' "${BUILDER}" | head -n 1)"
[ -n "${INST_APPEND}" ] && ! has "${BUILDER}" 'LABEL=FRITE_INSTALL' \
    && ok "installer medium cmdline uses the 11-char FAT label FRITE_INST (never FRITE_INSTALL)" \
    || bad "installer medium cmdline/label: '${INST_APPEND:-none}' (FRITE_INSTALL present: $(has "${BUILDER}" 'LABEL=FRITE_INSTALL' && echo yes || echo no))"

# Labelling + gates, in order: label the sysroot before the pack, gate the tarball after it.
l_label="$(grep -n 'slx_label_tree "\${SYSROOT}" "\${SLX_TYPE}"' "${BUILDER}" | head -n 1 | cut -d: -f1)"
l_gate="$(grep -n 'slx_label_gate "\${SYSROOT}" sysroot "\${SLX_PROBE_TABLE}" --census' "${BUILDER}" | head -n 1 | cut -d: -f1)"
l_pack="$(grep -n '^hmr_pack_owner_args "\${SYSROOT}"$' "${BUILDER}" | head -n 1 | cut -d: -f1)"
l_tgate="$(grep -n 'slx_tar_label_gate "\${STAGE4_TARBALL}" stage4 "\${SLX_PROBE_TABLE}"' "${BUILDER}" | head -n 1 | cut -d: -f1)"
if [ -n "${l_label}" ] && [ -n "${l_gate}" ] && [ -n "${l_pack}" ] && [ -n "${l_tgate}" ] \
   && [ "${l_label}" -lt "${l_pack}" ] && [ "${l_gate}" -lt "${l_pack}" ] && [ "${l_pack}" -lt "${l_tgate}" ]; then
    ok "sysroot is labelled (slx_label_tree :${l_label}) and gated (:${l_gate}) before the pack (:${l_pack}); the tarball is gated after it (slx_tar_label_gate :${l_tgate})"
else
    bad "labelling/gating order: label=${l_label:-none} gate=${l_gate:-none} pack=${l_pack:-none} tar-gate=${l_tgate:-none}"
fi
# Both gates are fail-closed: the line after each `|| {` carries exit 1.
sed -n "${l_gate:-0},$(( ${l_gate:-0} + 1 ))p" "${BUILDER}" | grep 'refusing to pack an unlabelled image.*exit 1' >/dev/null \
    && ok "labelling failure refuses to pack (exit 1)" || bad "labelling failure does not exit 1"
sed -n "${l_tgate:-0},$(( ${l_tgate:-0} + 1 ))p" "${BUILDER}" | grep 'exit 1' >/dev/null \
    && ok "stage4 label gate failure is fatal (exit 1)" || bad "stage4 label gate failure is not fatal"
grep -q 'refusing to pack a host binary into the image' "${BUILDER}" \
    && ok "a staged host qemu interpreter left in the sysroot refuses the pack" \
    || bad "no refusal for a staged host qemu interpreter in the sysroot"

PACK_SRC="$(awk '/^hmr_pack_owner_args "\$\{SYSROOT\}"$/ {on=1}
                 on && /^info "Stage4 tarball:/ {exit}
                 on {print}' "${BUILDER}")"
# Code lines only: the section's comment explains the old fallback by quoting it.
PACK_CODE="$(printf '%s\n' "${PACK_SRC}" | grep -v '^[[:space:]]*#')"
nt="$(printf '%s\n' "${PACK_CODE}" | grep -c -F 'tar -C "${SYSROOT}"')"
if [ "${nt}" -eq 1 ] && printf '%s\n' "${PACK_CODE}" | grep -- "--xattrs --xattrs-include='\*\.\*'" >/dev/null \
   && ! printf '%s\n' "${PACK_CODE}" | grep -F '2>/dev/null ||' >/dev/null \
   && printf '%s\n' "${PACK_CODE}" | grep 'exit 1' >/dev/null; then
    ok "pack section: ONE tar, --xattrs --xattrs-include='*.*', no '2>/dev/null ||' fallback, fatal"
else
    bad "pack section shape: ${nt} tar line(s); xattrs/fallback/fatal check failed:"; printf '%s\n' "${PACK_SRC}" | sed 's/^/      | /'
fi

# --standalone --with-tailscale: the REAL posture block, executed both ways.
POSTURE="$(awk '/^# ── STANDALONE posture/ {on=1} on && /^if \$\{STANDALONE\}; then/ {s=1} s {print} s && /^fi$/ {exit}' "${BUILDER}")"
[ -n "${POSTURE}" ] || bad "could not slice the STANDALONE posture block"
run_posture() {  # MESH_FORCED -> "SKIP_MESH SKIP_TAILSCALE"
    ( STANDALONE=true; MESH_FORCED="$1"; SKIP_MESH=false; SKIP_TAILSCALE=false; LOCAL_USER=""; DEFAULT_USER=u; ENCRYPT_ROOT=false; BUILD_INSTALLER=false
      SSO_FORCED=""; SKIP_SSO=false   # the greeter-SSO posture (#878) shares this block
      info() { :; }; err() { :; }
      eval "${POSTURE}"; echo "${SKIP_MESH} ${SKIP_TAILSCALE} ${ENCRYPT_ROOT} ${BUILD_INSTALLER}" )
}
[ "$(run_posture "")" = "true true true true" ] \
    && ok "--standalone alone: mesh+tailscale OFF, FDE + installer forced" \
    || bad "--standalone alone gave '$(run_posture "")' (want 'true true true true')"
[ "$(run_posture on)" = "false false true true" ] \
    && ok "--standalone --with-tailscale: tailnet stays ON (situation 2: tailnet, no mesh association), FDE + installer still forced" \
    || bad "--standalone --with-tailscale gave '$(run_posture on)' (want 'false false true true')"
grep -E -q -- '--with-tailscale\)[[:space:]]+SKIP_MESH=false; SKIP_TAILSCALE=false; MESH_FORCED=on' "${BUILDER}" \
    && ok "--with-tailscale is parsed (MESH_FORCED=on, x86 parity)" || bad "--with-tailscale is not parsed as MESH_FORCED=on"

# The post-build hint: detection, never a hard-coded device.
HINT="$(awk '/=== Post-build ===/ {on=1} on {print}' "${BUILDER}")"
if ! printf '%s\n' "${HINT}" | grep 'install-frite.sh /dev/mmcblk0' >/dev/null \
   && printf '%s\n' "${HINT}" | grep '/sys/block/mmcblk' >/dev/null && printf '%s\n' "${HINT}" | grep 'device/type' >/dev/null \
   && printf '%s\n' "${HINT}" | grep 'sudo bash /run/initramfs/live/install-frite.sh' >/dev/null; then
    ok "post-build hint detects the eMMC (/sys/block/mmcblkN/device/type = MMC) instead of hard-coding /dev/mmcblk0, and runs the installer via bash (FAT keeps no exec bit)"
else
    bad "post-build hint still hard-codes the device or lacks the detection recipe"
fi

# fstab: the installer's sed anchors, exactly one each, unindented.
[ "$(grep -c '^LABEL=FRITE_BOOT' "${FSTAB}")" -eq 1 ] && [ "$(grep -c '^LABEL=FRITE_ROOT' "${FSTAB}")" -eq 1 ] \
    && ok "fstab carries exactly one ^LABEL=FRITE_BOOT and one ^LABEL=FRITE_ROOT line (the installer's sed anchors)" \
    || bad "fstab anchors: $(grep -c '^LABEL=FRITE_BOOT' "${FSTAB}") FRITE_BOOT / $(grep -c '^LABEL=FRITE_ROOT' "${FSTAB}") FRITE_ROOT lines"

# ═════════════════ 2. the stage4 pack, executed (xattrs survive) ══════════════
echo "-- 2) the builder's pack section, executed on a fixture sysroot --"
SR="${WORK}/sysroot"
mkdir -p "${SR}/etc" "${SR}/usr/bin" "${SR}/proc" "${SR}/sys" "${SR}/dev" "${SR}/run" "${SR}/tmp" "${SR}/var/cache" "${SR}/usr/src/linux"
printf 'root:x:0:0::/root:/bin/sh\n' > "${SR}/etc/passwd"; printf 'root:x:0:\n' > "${SR}/etc/group"
cp "${FSTAB}" "${SR}/etc/fstab"
setfattr -n user.hugmesh.probe -v passwd_file_t "${SR}/etc/passwd"
printf '#!/bin/sh\n' > "${SR}/usr/bin/init"; chmod +x "${SR}/usr/bin/init"
: > "${SR}/tmp/leak"; : > "${SR}/usr/src/linux/leak"
setfattr -n user.hugmesh.probe -v etc_t "${SR}/etc/fstab" || bad "setfattr user.* on the fixture failed"
setfattr -n user.hugmesh.probe -v init_exec_t "${SR}/usr/bin/init"
STAGE4="${WORK}/fixture.stage4.tar.xz"
cat > "${WORK}/runpack.sh" <<'EOF'
set -euo pipefail
LIB="$1"; SYSROOT="$2"; STAGE4_TARBALL="$3"; SEC="$4"
info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }; err(){ echo "ERR: $*" >&2; }
. "${LIB}"
. "${SEC}"
EOF
printf '%s\n' "${PACK_SRC}" > "${WORK}/pack-section.sh"
if bash "${WORK}/runpack.sh" "${LIB}" "${SR}" "${STAGE4}" "${WORK}/pack-section.sh" >"${WORK}/pack.log" 2>&1 && [ -s "${STAGE4}" ]; then
    ok "pack section ran (rc=0) and produced $(stat -c %s "${STAGE4}") bytes"
else
    bad "pack section failed:"; sed 's/^/      | /' "${WORK}/pack.log"
fi
# GNU tar -tv marks an entry carrying xattrs with '*' after the mode.
if tar --xattrs --xattrs-include='*' -tvf "${STAGE4}" 2>/dev/null | awk '$NF == "./etc/fstab" && substr($1, 11, 1) == "*" {f=1} END {exit !f}'; then
    ok "stage4 archive carries the xattr on ./etc/fstab ('*' in tar -tv)"
else
    bad "stage4 archive lost the xattr on ./etc/fstab"
fi
tar -tf "${STAGE4}" | grep -E '^\./(tmp/leak|usr/src/linux/leak)$' >/dev/null \
    && bad "pack excludes are not applied (./tmp/* or ./usr/src leaked)" \
    || ok "pack excludes applied (./tmp/*, ./usr/src not in the archive)"
# A mutated pack line (the old fallback shape) must be caught by the static pin above,
# so prove the pin can fail: rewrite the section the old way and re-run the shape test.
MUT="$(printf '%s\n' "${PACK_CODE}" | sed "s/|| { err/2>\/dev\/null || tar -C \"\${SYSROOT}\" -cJf \"\${STAGE4_TARBALL}\" . || { err/")"
if printf '%s\n' "${MUT}" | grep -F '2>/dev/null ||' >/dev/null; then
    ok "negative control: the pack-shape pin rejects a reintroduced '2>/dev/null || tar' fallback"
else
    bad "negative control: could not synthesise the fallback shape (pin would be untestable)"
fi

# ═════════════ 3. the medium: build_frite_medium, executed and read back ═══════
echo "-- 3) build_frite_medium executed on an installer fixture tree --"
DTB="amlogic/meson-gxl-s805x-libretech-ac.dtb"
# render the REAL extlinux template, the way the builder does (token substitution).
render() {  # TMPL OUT INITRD_LINE APPEND
    sed -e "s|@@FRITE_KERNEL_IMG@@|Image|g" -e "s|@@FRITE_DTB@@|${DTB}|g" \
        -e "s|@@FRITE_INITRD_LINE@@|$3|g" -e "s|@@FRITE_APPEND@@|$4|g" -e "s|@@BRAND_TITLE@@|Fixture|g" "$1" > "$2"
}
BASE_CMDLINE="$(cat "${REPO}/specs-frite/boot/cmdline.base")"
mk_tree() {  # DIR [no-fdt]
    local t="$1"
    rm -rf "${t}"; mkdir -p "${t}"/{LiveOS,extlinux,dtb/amlogic,stage4,boot/extlinux,boot/dtb/amlogic,uboot}
    head -c "${MiB}" /dev/urandom > "${t}/Image"; head -c 20000 /dev/urandom > "${t}/dtb/${DTB}"
    head -c 65536 /dev/urandom > "${t}/initrd.img"; head -c $((3 * MiB)) /dev/urandom > "${t}/LiveOS/squashfs.img"
    render "${TMPL}" "${t}/extlinux/extlinux.conf" "    INITRD /initrd.img" "${BASE_CMDLINE} ${INST_APPEND}"
    cp "${STAGE4}" "${t}/stage4/"
    cp "${t}/Image" "${t}/boot/Image"; cp "${t}/dtb/${DTB}" "${t}/boot/dtb/${DTB}"; cp "${t}/initrd.img" "${t}/boot/initrd.img"
    render "${TMPL}" "${t}/boot/extlinux/extlinux.conf" "    INITRD /initrd.img" "${BASE_CMDLINE} root=LABEL=FRITE_ROOT"
    cp "${INSTALLER}" "${t}/install-frite.sh"; : > "${t}/encrypt-root"
    [ "${2:-}" = no-fdt ] && rm -f "${t}/dtb/${DTB}"
    return 0
}
UBOOT="${WORK}/u-boot.bin"; head -c 700000 /dev/urandom > "${UBOOT}"
TREE="${WORK}/inst"; mk_tree "${TREE}"
{
    echo 'info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }; err(){ echo "ERR: $*" >&2; }'
    printf '%s\n' "${MEDIUM_SRC}"
} > "${WORK}/medium-fn.sh"
run_medium() {  # TREE LABEL OUT [UBOOT] -> rc, log in ${WORK}/medium.log
    bash -c '. "$1"; shift; build_frite_medium "$@"' _ "${WORK}/medium-fn.sh" "$@" >"${WORK}/medium.log" 2>&1
}
IMG="${WORK}/fixture.installer.img"
if run_medium "${TREE}" FRITE_INST "${IMG}" "${UBOOT}"; then
    ok "build_frite_medium rc=0: $(grep -o 'MBR, p1 FAT32.*' "${WORK}/medium.log" | head -n 1)"
else
    bad "build_frite_medium failed:"; sed 's/^/      | /' "${WORK}/medium.log"
fi
P1_OFF=$((4 * MiB))
[ "$(od -An -tx1 -j 510 -N 2 "${IMG}" | tr -d ' ')" = "55aa" ] && ok "MBR boot signature 55AA at 510" || bad "no MBR signature at 510"
DUMP="$(sfdisk -d "${IMG}" 2>/dev/null)"
p1="$(printf '%s\n' "${DUMP}" | grep -E '^[^ ]+1 :' | head -n 1)"
if printf '%s' "${p1}" | grep "start= *$(( P1_OFF / 512 ))," >/dev/null; then ok "p1 starts at sector $(( P1_OFF / 512 )) (4 MiB: room for the Amlogic u-boot at sector 1)"; else bad "p1 line: '${p1}'"; fi
printf '%s' "${p1}" | grep 'type=c' >/dev/null && ok "p1 type 0x0c (FAT32 LBA)" || bad "p1 type is not 0x0c: '${p1}'"
printf '%s' "${p1}" | grep 'bootable' >/dev/null && ok "p1 bootable flag set" || bad "p1 is not flagged bootable"
[ "$(printf '%s\n' "${DUMP}" | grep -c -E '^[^ ]+[0-9]+ :')" -eq 1 ] && ok "exactly one partition" || bad "partition count != 1"
[ "$(blkid -p -O "${P1_OFF}" -o value -s TYPE "${IMG}")" = vfat ] && ok "blkid at p1: vfat" || bad "blkid at p1 is not vfat"
FAT_LABEL="$(blkid -p -O "${P1_OFF}" -o value -s LABEL "${IMG}")"
CONF_LABEL="$(mtype -i "${IMG}@@${P1_OFF}" ::/extlinux/extlinux.conf 2>/dev/null | grep -o 'root=live:LABEL=[^ ]*' | head -n 1 | cut -d= -f3)"
[ -n "${FAT_LABEL}" ] && [ "${FAT_LABEL}" = "${CONF_LABEL}" ] \
    && ok "FAT label '${FAT_LABEL}' == the root=live:LABEL= token in the medium's own extlinux.conf" \
    || bad "FAT label '${FAT_LABEL:-none}' vs extlinux root=live:LABEL=${CONF_LABEL:-none}"
for want in /Image /initrd.img "/dtb/${DTB}" /LiveOS/squashfs.img "/stage4/$(basename "${STAGE4}")" /boot/extlinux/extlinux.conf "/boot/dtb/${DTB}" /boot/initrd.img /install-frite.sh /encrypt-root; do
    mdir -i "${IMG}@@${P1_OFF}" "::${want}" >/dev/null 2>&1 && ok "on the FAT: ${want}" || bad "missing on the FAT: ${want}"
done
FDT_IN_CONF="$(mtype -i "${IMG}@@${P1_OFF}" ::/extlinux/extlinux.conf 2>/dev/null | awk '$1 == "FDT" {print $2; exit}')"   # the DEFAULT label's (first); the SELinux rescue/test labels repeat it
[ "${FDT_IN_CONF}" = "/dtb/${DTB}" ] && ok "extlinux FDT line names the staged DTB (${FDT_IN_CONF})" || bad "extlinux FDT line: '${FDT_IN_CONF}'"
# u-boot in the user area, u-boot doc/board/amlogic order: sectors from 1, then 444 bytes.
# byte-range digests (busybox cmp has no -i/-n; sha256sum is in both userlands)
dig() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | sha256sum | cut -d' ' -f1; }
[ "$(dig "${UBOOT}" 0 444)" = "$(dig "${IMG}" 0 444)" ] && ok "u-boot: first 444 bytes of the blob are at offset 0" || bad "u-boot: first 444 bytes differ"
[ "$(dig "${UBOOT}" 512 $(( 700000 - 512 )))" = "$(dig "${IMG}" 512 $(( 700000 - 512 )))" ] && ok "u-boot: blob from sector 1 is at sector 1" || bad "u-boot: sector-1 payload differs"
[ "$(od -An -tx1 -j 510 -N 2 "${IMG}" | tr -d ' ')" = "55aa" ] && printf '%s' "$(sfdisk -d "${IMG}" 2>/dev/null | grep -E '^[^ ]+1 :')" | grep "start= *$(( P1_OFF / 512 ))," >/dev/null \
    && ok "partition table + signature survived the u-boot write" || bad "u-boot write damaged the MBR"
[ 700000 -lt "${P1_OFF}" ] && ok "u-boot blob (700000 B) ends below p1 (${P1_OFF} B)" || bad "fixture blob overlaps p1"
# without a blob: nothing at sector 0..7 but the MBR
IMG2="${WORK}/fixture.live.img"; T2="${WORK}/live"; mk_tree "${T2}"
render "${TMPL}" "${T2}/extlinux/extlinux.conf" "    INITRD /initrd.img" "${BASE_CMDLINE} root=live:LABEL=FRITE_LIVE rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
if run_medium "${T2}" FRITE_LIVE "${IMG2}"; then
    [ "$(od -v -An -tx1 -N 440 "${IMG2}" | tr -d ' \n' | tr -d 0)" = "" ] && ok "no u-boot blob: bootstrap area is zero" || bad "no u-boot blob: bootstrap area is not zero"
    [ "$(blkid -p -O "${P1_OFF}" -o value -s LABEL "${IMG2}")" = FRITE_LIVE ] && ok "LIVE medium label FRITE_LIVE" || bad "LIVE medium label wrong"
else
    bad "build_frite_medium (live, no u-boot) failed:"; sed 's/^/      | /' "${WORK}/medium.log"
fi

echo "-- 3b) build_frite_medium refusals (each must fail, leave no image) --"
refuses() {  # LABEL TREE [UBOOT] — expect rc != 0 and no out image
    local out="${WORK}/neg.img"; rm -f "${out}"
    if run_medium "$2" "$1" "${out}" "${3:-}"; then echo "rc0"; else [ -e "${out}" ] && echo "left-image" || echo "refused"; fi
}
[ "$(refuses FRITE_INSTALL "${TREE}")" = refused ] && ok "refuses a 12-char FAT label (FRITE_INSTALL)" || bad "accepted a 12-char label"
T3="${WORK}/t3"; mk_tree "${T3}"; sed -i 's/LABEL=FRITE_INST/LABEL=FRITE_OTHER/' "${T3}/extlinux/extlinux.conf"
[ "$(refuses FRITE_INST "${T3}")" = refused ] && ok "refuses an extlinux root=live:LABEL= that does not match the medium label" || bad "accepted a label mismatch (dracut would never find the squashfs)"
T4="${WORK}/t4"; mk_tree "${T4}" no-fdt
[ "$(refuses FRITE_INST "${T4}")" = refused ] && ok "refuses a tree whose FDT (named by extlinux) is missing" || bad "accepted a tree without its FDT"
T5="${WORK}/t5"; mk_tree "${T5}"; truncate -s 4G "${T5}/stage4/huge.tar.xz"
[ "$(refuses FRITE_INST "${T5}")" = refused ] && ok "refuses a 4 GiB file (FAT32 limit) up front" || bad "accepted a >= 4 GiB file"
BIGUB="${WORK}/big-uboot.bin"; truncate -s $(( 4 * MiB )) "${BIGUB}"
[ "$(refuses FRITE_INST "${TREE}" "${BIGUB}")" = refused ] && ok "refuses a u-boot blob that would overlap p1" || bad "accepted a u-boot blob overlapping p1"
T6="${WORK}/t6"; mk_tree "${T6}"; rm -f "${T6}/extlinux/extlinux.conf"
[ "$(refuses FRITE_INST "${T6}")" = refused ] && ok "refuses a tree with no /extlinux/extlinux.conf" || bad "accepted a tree u-boot could not boot"

# ═══════ 4. the eMMC layout install-frite.sh writes, as regular files ═════════
echo "-- 4) eMMC layout: the installer's sfdisk write + root=/fstab rewrite, executed on files --"
EMMC="${WORK}/emmc.img"; truncate -s 512M "${EMMC}"
# The layout constants and the ONE sfdisk write (#877), sliced from the installer.
LAYOUT_VARS="$(grep -E '^(P1_START_MIB|P1_END_MIB|SECTOR)=' "${INSTALLER}")"
P1_BYTES_LINE="$(grep -E '^P1_START_BYTES=' "${INSTALLER}")"
SFDISK_SRC="$(awk '/^P1_START_S=/ {on=1} on {print} on && /sfdisk failed to write the partition table/ {exit}' "${INSTALLER}")"
DISKID_FN="$(awk '/^mbr_disk_id\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "${INSTALLER}")"
if [ "$(printf '%s\n' "${LAYOUT_VARS}" | grep -c .)" -eq 3 ] && [ -n "${P1_BYTES_LINE}" ] \
   && printf '%s\n' "${SFDISK_SRC}" | grep -F 'label-id: 0x%s' >/dev/null \
   && printf '%s\n' "${SFDISK_SRC}" | grep -F '| sfdisk ' >/dev/null && [ -n "${DISKID_FN}" ]; then
    ok "sliced the installer's layout constants, its ONE sfdisk write (explicit label-id) and mbr_disk_id()"
else
    bad "could not slice the installer's layout constants / sfdisk write / mbr_disk_id()"
fi
DISK_ID="$(od -An -tx1 -N4 /dev/urandom | awk '{printf "%s%s%s%s\n", $1, $2, $3, $4}')"
[ "${DISK_ID}" != 00000000 ] || DISK_ID="5a5a5a5a"
( DEV="${EMMC}"; ENCRYPT=false; die() { echo "DIE: $*" >&2; exit 1; }
  eval "${LAYOUT_VARS}"; eval "${P1_BYTES_LINE}"; eval "${SFDISK_SRC}" ) >"${WORK}/sfdisk.log" 2>&1 \
    && ok "installer's sfdisk write ran on a file" || { bad "sfdisk write failed:"; sed 's/^/      | /' "${WORK}/sfdisk.log"; }
EXPECT_P1_START="$( eval "${LAYOUT_VARS}"; eval "${P1_BYTES_LINE}"; echo $(( P1_START_BYTES / SECTOR )) )"
EDUMP="$(sfdisk -d "${EMMC}" 2>/dev/null)"
e1="$(printf '%s\n' "${EDUMP}" | grep -E '^[^ ]+1 :')"; e2="$(printf '%s\n' "${EDUMP}" | grep -E '^[^ ]+2 :')"
printf '%s' "${e1}" | grep 'type=c' >/dev/null && printf '%s' "${e1}" | grep 'bootable' >/dev/null && ok "eMMC p1: FAT32 LBA, bootable" || bad "eMMC p1: '${e1}'"
printf '%s' "${e2}" | grep 'type=83' >/dev/null && ok "eMMC p2: Linux (0x83)" || bad "eMMC p2: '${e2}'"
P1_START="$(printf '%s' "${e1}" | sed -n 's/.*start= *\([0-9]*\),.*/\1/p')"; P1_SIZE="$(printf '%s' "${e1}" | sed -n 's/.*size= *\([0-9]*\),.*/\1/p')"
P2_START="$(printf '%s' "${e2}" | sed -n 's/.*start= *\([0-9]*\),.*/\1/p')"; P2_SIZE="$(printf '%s' "${e2}" | sed -n 's/.*size= *\([0-9]*\),.*/\1/p')"
[ "${P1_START}" = $(( 8 * MiB / 512 )) ] && [ "${P1_START}" = "${EXPECT_P1_START}" ] \
    && ok "eMMC p1 starts at 8 MiB (sector ${P1_START}), as install-frite.sh partitions (clear of the Amlogic BL2/FIP)" \
    || bad "eMMC p1 start: '${P1_START}' (want $(( 8 * MiB / 512 )); installer's P1_START_BYTES/SECTOR = '${EXPECT_P1_START}')"
[ -n "${P1_START}" ] && [ -n "${P1_SIZE}" ] && [ "${P2_START}" = "$(( P1_START + P1_SIZE ))" ] \
    && ok "eMMC p2 starts right after p1 (sector ${P2_START})" || bad "eMMC p2 start '${P2_START}' != p1 end"
PTUUID="$(blkid -p -o value -s PTUUID "${EMMC}")"
LABEL_ID="$(printf '%s\n' "${EDUMP}" | sed -n 's/^label-id: 0x//p')"
if [ -n "${PTUUID}" ] && [ "${PTUUID}" != 00000000 ] && [ "${PTUUID}" = "${LABEL_ID}" ] && [ "${PTUUID}" = "${DISK_ID}" ]; then
    ok "MBR disk id ${PTUUID} is the installer's explicit id, non-zero, and blkid/sfdisk agree (PARTUUIDs are ${PTUUID}-01 / ${PTUUID}-02)"
else
    bad "disk id: wrote '${DISK_ID}', blkid '${PTUUID}' sfdisk '${LABEL_ID}'"
fi
GOT_DISK_ID="$( eval "${DISKID_FN}"; mbr_disk_id "${EMMC}" )"
[ "${GOT_DISK_ID}" = "${DISK_ID}" ] \
    && ok "the installer's own mbr_disk_id() reads the id back (its post-write verification would pass)" \
    || bad "mbr_disk_id() reads '${GOT_DISK_ID}', wrote ${DISK_ID}"
ROOT_PARTUUID="${PTUUID}-02"; BOOT_PARTUUID="${PTUUID}-01"
# The installer's own root=/fstab rewrite (#877): the ROOT_ARG / FSTAB_ROOT
# assignments of both branches, the extlinux sed and the LABEL=FRITE_* fstab sed.
ROOT_ARG_PLAIN="$(grep -E '^[[:space:]]*ROOT_ARG="root=PARTUUID=' "${INSTALLER}" | head -n 1)"
ROOT_ARG_LUKS="$(grep -E '^[[:space:]]*ROOT_ARG="root=/dev/mapper/cryptroot ' "${INSTALLER}" | head -n 1)"
FSTAB_ROOT_PLAIN="$(grep -E '^[[:space:]]*FSTAB_ROOT="PARTUUID=' "${INSTALLER}" | head -n 1)"
ROOT_SED="$(grep -F 'sed -i -E "s#root=[^ ]+#${ROOT_ARG}#" "${EXTLINUX_DST}"' "${INSTALLER}")"
FSTAB_SED="$(awk '/^sed -i -E \\$/ {on=1} on {print} on && /"\$\{FSTAB_DST\}"$/ {exit}' "${INSTALLER}")"
if [ -n "${ROOT_ARG_PLAIN}" ] && [ -n "${ROOT_ARG_LUKS}" ] && [ -n "${FSTAB_ROOT_PLAIN}" ] \
   && [ "$(printf '%s\n' "${ROOT_SED}" | grep -c .)" -eq 1 ] \
   && printf '%s\n' "${FSTAB_SED}" | grep -F 'LABEL=FRITE_BOOT' >/dev/null \
   && printf '%s\n' "${FSTAB_SED}" | grep -F 'LABEL=FRITE_ROOT' >/dev/null; then
    ok "sliced the installer's ROOT_ARG= (plaintext + LUKS), FSTAB_ROOT=, root= sed and LABEL=FRITE_* fstab sed"
else
    bad "could not slice the installer's rewrite (ROOT_ARG plain='${ROOT_ARG_PLAIN}' luks='${ROOT_ARG_LUKS}' FSTAB_ROOT='${FSTAB_ROOT_PLAIN}' root-sed lines=$(printf '%s\n' "${ROOT_SED}" | grep -c .) fstab-sed='${FSTAB_SED}')"
fi
# run_rewrite FILE KIND [LUKS_UUID] — the installer's own lines, executed on FILE.
run_rewrite() {
    ( LUKS_UUID="${3:-}"
      case "$2" in
          extlinux) EXTLINUX_DST="$1"; eval "${ROOT_ARG_PLAIN}"; eval "${ROOT_SED}" ;;
          luks)     EXTLINUX_DST="$1"; eval "${ROOT_ARG_LUKS}";  eval "${ROOT_SED}" ;;
          fstab)    FSTAB_DST="$1";    eval "${FSTAB_ROOT_PLAIN}"; eval "${FSTAB_SED}" ;;
          *)        exit 2 ;;
      esac )
}
# p1: FAT boot from the installer tree's boot/ payload, root= rewritten
BOOT_T="${WORK}/boot-stage"; rm -rf "${BOOT_T}"; cp -r "${TREE}/boot" "${BOOT_T}"
run_rewrite "${BOOT_T}/extlinux/extlinux.conf" extlinux || bad "the installer's root= rewrite failed on the fixture"
BFAT="${WORK}/boot.fat"; mkfs.vfat -C -F 32 -n FRITE_BOOT "${BFAT}" $(( P1_SIZE / 2 )) >/dev/null || bad "mkfs.vfat for the eMMC boot partition failed"
mcopy -i "${BFAT}" -s -m -Q "${BOOT_T}"/* ::/ || bad "mcopy into the eMMC boot FAT failed"
dd if="${BFAT}" of="${EMMC}" bs=512 seek="${P1_START}" conv=notrunc status=none
# p2: ext4 root populated from the stage4 (xattrs on), fstab rewritten
ROOT_T="${WORK}/root-stage"; rm -rf "${ROOT_T}"; mkdir -p "${ROOT_T}"
tar -C "${ROOT_T}" --xattrs --xattrs-include='*' -xpf "${STAGE4}" || bad "stage4 extraction failed"
run_rewrite "${ROOT_T}/etc/fstab" fstab || bad "the installer's fstab rewrite failed on the fixture"
REXT="${WORK}/root.ext4"
mke2fs -q -F -t ext4 -L FRITE_ROOT -d "${ROOT_T}" "${REXT}" $(( P2_SIZE / 2 ))k >"${WORK}/mke2fs.log" 2>&1 || { bad "mke2fs -d failed:"; sed 's/^/      | /' "${WORK}/mke2fs.log"; }
dd if="${REXT}" of="${EMMC}" bs=512 seek="${P2_START}" conv=notrunc status=none
# read back
[ "$(blkid -p -O $(( P1_START * 512 )) -o value -s LABEL "${EMMC}")" = FRITE_BOOT ] && ok "eMMC p1 is vfat FRITE_BOOT" || bad "eMMC p1 label/type wrong"
[ "$(blkid -p -O $(( P2_START * 512 )) -o value -s TYPE "${EMMC}")" = ext4 ] && [ "$(blkid -p -O $(( P2_START * 512 )) -o value -s LABEL "${EMMC}")" = FRITE_ROOT ] \
    && ok "eMMC p2 is ext4 FRITE_ROOT" || bad "eMMC p2 label/type wrong"
ROOT_TOKEN="$(mtype -i "${EMMC}@@$(( P1_START * 512 ))" ::/extlinux/extlinux.conf 2>/dev/null | grep -o 'root=[^ ]*' | head -n 1)"
[ "${ROOT_TOKEN}" = "root=PARTUUID=${PTUUID}-02" ] && ok "installed extlinux.conf: ${ROOT_TOKEN} == partition 2's PARTUUID" || bad "installed extlinux root token: '${ROOT_TOKEN}' (want root=PARTUUID=${PTUUID}-02)"
for want in /Image "/dtb/${DTB}" /initrd.img /extlinux/extlinux.conf; do
    mdir -i "${EMMC}@@$(( P1_START * 512 ))" "::${want}" >/dev/null 2>&1 && ok "eMMC boot FAT has ${want}" || bad "eMMC boot FAT lacks ${want}"
done
FSTAB_OUT="$(debugfs -R 'cat /etc/fstab' "${REXT}" 2>/dev/null)"
printf '%s\n' "${FSTAB_OUT}" | grep -E "^PARTUUID=${PTUUID}-01[[:space:]]+/boot[[:space:]]+vfat" >/dev/null \
    && printf '%s\n' "${FSTAB_OUT}" | grep -E "^PARTUUID=${PTUUID}-02[[:space:]]+/[[:space:]]+ext4" >/dev/null \
    && ! printf '%s\n' "${FSTAB_OUT}" | grep '^LABEL=FRITE_' >/dev/null \
    && ok "installed fstab mounts /boot and / by PARTUUID ${PTUUID}-01 / -02 (no LABEL= placeholder left)" \
    || { bad "installed fstab not rewritten:"; printf '%s\n' "${FSTAB_OUT}" | grep -v '^#' | sed 's/^/      | /'; }
debugfs -R 'ea_list /etc/passwd' "${REXT}" 2>/dev/null | grep 'user.hugmesh.probe.*passwd_file_t' >/dev/null \
    && ok "xattr on /etc/passwd survived stage4 -> extract -> mke2fs -d into the ext4 root" || bad "xattr on /etc/passwd did not reach the ext4 root"
debugfs -R 'ea_list /usr/bin/init' "${REXT}" 2>/dev/null | grep 'user.hugmesh.probe.*init_exec_t' >/dev/null \
    && ok "xattr on /usr/bin/init survived into the ext4 root" || bad "xattr on /usr/bin/init did not reach the ext4 root"
# NOT asserted on purpose: /etc/fstab. The installer rewrites it with `sed -i`,
# which writes a NEW file; whether its label survives depends on the target's
# sed carrying SELinux support and a loaded policy (GNU sed copies the context
# only then). Measured here: the user.* xattr is gone after sed -i on this host.
if debugfs -R 'ea_list /etc/fstab' "${REXT}" 2>/dev/null | grep 'user.hugmesh.probe' >/dev/null; then
    echo "  NOTE /etc/fstab kept its xattr across sed -i on this host"
else
    echo "  NOTE /etc/fstab lost its xattr across the installer's sed -i on this host (a label-preserving rewrite in install-frite.sh is the installer group's call)"
fi
# LUKS branch of the same rewrite
LUKS_UUID="0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"
cp "${TREE}/boot/extlinux/extlinux.conf" "${WORK}/luks.conf"; run_rewrite "${WORK}/luks.conf" luks "${LUKS_UUID}"
grep -q "root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot" "${WORK}/luks.conf" \
    && grep -q '^    INITRD /initrd.img' "${WORK}/luks.conf" \
    && ok "LUKS rewrite: root=/dev/mapper/cryptroot + rd.luks.uuid + rd.luks.name=…=cryptroot, with the INITRD line the encrypted payload carries" \
    || bad "LUKS rewrite wrong: $(grep -o 'root=.*' "${WORK}/luks.conf")"
# The medium's p1 (4 MiB) and the installer's p1 (8 MiB) both clear the u-boot image.
[ $(( P1_START * 512 )) -gt 700000 ] && ok "installer's p1 at ${P1_START} sectors clears a 700000-byte GXL u-boot image" || bad "installer's p1 overlaps the u-boot image area"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
