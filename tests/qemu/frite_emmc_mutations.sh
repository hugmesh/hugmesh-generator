#!/usr/bin/env bash
# Mutation battery for launch_arm_medium_test.sh + frite_emmc_layout_test.sh.
# BREAKS PRODUCTION (launch-arm.sh, frite-emmc-install.sh), runs the suite that
# should notice, and demands RED. Every mutation is verified to have ACTUALLY
# changed the file — a replacement that matched nothing would otherwise
# "survive" and look like coverage. Not wired into CI: it edits tracked files
# and restores them. Same shape as loop_preflight_mutations.sh.
#
#   bash tests/qemu/frite_emmc_mutations.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${HERE}/launch-arm.sh"
DRIVER="${HERE}/frite-emmc-install.sh"
SUITE_L="${HERE}/launch_arm_medium_test.sh"
SUITE_D="${HERE}/frite_emmc_layout_test.sh"
BAK_L="$(mktemp)"; cp "${LAUNCHER}" "${BAK_L}"
BAK_D="$(mktemp)"; cp "${DRIVER}" "${BAK_D}"
restore() { cp "${BAK_L}" "${LAUNCHER}"; cp "${BAK_D}" "${DRIVER}"; }
trap 'restore; rm -f "${BAK_L}" "${BAK_D}"' EXIT

SURVIVED=0; CAUGHT=0
mutate() { # mutate FILE SUITE NAME OLD NEW
    local file="$1" suite="$2" name="$3" old="$4" new="$5" bak
    restore
    case "${file}" in "${LAUNCHER}") bak="${BAK_L}" ;; *) bak="${BAK_D}" ;; esac
    OLD="${old}" NEW="${new}" python3 -I - "${file}" <<'PY' || { printf '  ERROR %s: mutation did not apply (pattern count != 1)\n' "${name}"; SURVIVED=$((SURVIVED+1)); return; }
import os, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old, new = os.environ['OLD'], os.environ['NEW']
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
    if cmp -s "${file}" "${bak}"; then
        printf '  ERROR %s: file unchanged after mutation\n' "${name}"; SURVIVED=$((SURVIVED+1)); return
    fi
    if bash "${suite}" >/dev/null 2>&1; then
        printf '  SURVIVED %s  <-- the suite passed on broken production\n' "${name}"
        SURVIVED=$((SURVIVED+1))
    else
        printf '  caught   %s\n' "${name}"
        CAUGHT=$((CAUGHT+1))
    fi
}

echo "mutation battery — break production, demand RED"
echo "-- launch-arm.sh (suite: launch_arm_medium_test.sh) --"
mutate "${LAUNCHER}" "${SUITE_L}" 'L1 -dtb comes back unconditionally (the original defect)' \
  '[ -z "${DTB}" ]    || QEMU_ARGS+=(-dtb "${DTB}")' \
  'QEMU_ARGS+=(-dtb "${DTB:-${BOARD_DTB}}")'
mutate "${LAUNCHER}" "${SUITE_L}" 'L2 console rewrite disabled (board UART ttyAML0 kept)' \
  '            console=tty[A-Za-z]*) continue ;;' \
  '            console=ttyNEVER*) continue ;;'
mutate "${LAUNCHER}" "${SUITE_L}" 'L3 ttyAMA0 appended FIRST instead of last' \
  "    printf '%s console=ttyAMA0,115200\\n' \"\${out}\"" \
  "    printf 'console=ttyAMA0,115200 %s\\n' \"\${out}\""
mutate "${LAUNCHER}" "${SUITE_L}" 'L4 medium drive writable' \
  'QEMU_ARGS+=(-drive "file=${MEDIUM},format=raw,if=none,id=medium,readonly=on")' \
  'QEMU_ARGS+=(-drive "file=${MEDIUM},format=raw,if=none,id=medium")'
mutate "${LAUNCHER}" "${SUITE_L}" 'L5 medium on virtio even for --medium-bus usb' \
  '        usb)    QEMU_ARGS+=(-device usb-storage,bus=xhci.0,drive=medium,removable=on) ;;' \
  '        usb)    QEMU_ARGS+=(-device virtio-blk-pci,drive=medium) ;;'
mutate "${LAUNCHER}" "${SUITE_L}" 'L6 a second xhci controller for --gpu' \
  '    QEMU_ARGS+=(-device virtio-gpu-pci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0)' \
  '    QEMU_ARGS+=(-device qemu-xhci,id=xhci -device virtio-gpu-pci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0)'
mutate "${LAUNCHER}" "${SUITE_L}" 'L7 boot-partition-size 128K rule dropped' \
  '    [ $(( EMMC_BOOT_SIZE % 131072 )) -eq 0 ] && [ "${EMMC_BOOT_SIZE}" -le $(( 255 * 131072 )) ] \' \
  '    [ $(( EMMC_BOOT_SIZE % 1 )) -eq 0 ] && [ "${EMMC_BOOT_SIZE}" -le $(( 255 * 131072 )) ] \'
mutate "${LAUNCHER}" "${SUITE_L}" 'L8 ISO magic probed at the wrong byte' \
  'od -An -c -j 32769 -N 5' \
  'od -An -c -j 32770 -N 5'
mutate "${LAUNCHER}" "${SUITE_L}" 'L9 -initrd never passed' \
  '[ -z "${INITRD}" ] || QEMU_ARGS+=(-initrd "${INITRD}")' \
  ':'
mutate "${LAUNCHER}" "${SUITE_L}" 'L10 APPEND taken from the FIRST label, not DEFAULT' \
  '            if (def != "" && (def in val)) { print val[def]; exit }' \
  '            if (0) { print val[def]; exit }'
mutate "${LAUNCHER}" "${SUITE_L}" 'L11 emmc device check accepts any QEMU' \
  "    qemu-system-aarch64 -device help 2>/dev/null | grep -E '^name \"emmc\"' >/dev/null \\" \
  "    true \\"
mutate "${LAUNCHER}" "${SUITE_L}" 'L12 read-only eMMC file accepted' \
  '    [ -w "${EMMC}" ] || die' \
  '    [ -r "${EMMC}" ] || die'
mutate "${LAUNCHER}" "${SUITE_L}" 'L13 overlay disk attached even without --img' \
  'if [ -n "${IMG}" ]; then
    QEMU_ARGS+=(-drive "file=${OVERLAY},format=qcow2,if=none,id=hd0"' \
  'if true; then
    QEMU_ARGS+=(-drive "file=${OVERLAY},format=qcow2,if=none,id=hd0"'
mutate "${LAUNCHER}" "${SUITE_L}" 'L14 user-area offset forgets the RPMB' \
  '    EMMC_USER_OFFSET=$(( 2 * EMMC_BOOT_SIZE + EMMC_RPMB_SIZE ))' \
  '    EMMC_USER_OFFSET=$(( 2 * EMMC_BOOT_SIZE ))'

echo "-- frite-emmc-install.sh --check-layout (suite: frite_emmc_layout_test.sh) --"
mutate "${DRIVER}" "${SUITE_D}" 'D1 disk id 00000000 accepted' \
  '    [ "${id}" != "00000000" ] && ok "layout: MBR disk identifier' \
  '    [ -n "${id}" ] && ok "layout: MBR disk identifier'
mutate "${DRIVER}" "${SUITE_D}" 'D2 root=PARTUUID checked by prefix only (any partition, any disk)' \
  '        [[ " ${append} " == *" root=PARTUUID=${id}-02 "* ]] \' \
  '        [[ " ${append} " == *" root=PARTUUID="* ]] \'
mutate "${DRIVER}" "${SUITE_D}" 'D3 FDT file existence not checked' \
  '        fat_has "${raw}" "${p1off}" "${fdt_line#/}" && ok "layout: the FDT file' \
  '        true && ok "layout: the FDT file'
mutate "${DRIVER}" "${SUITE_D}" 'D4 fstab LABEL= check inverted away' \
  "    if printf '%s\\n' \"\${fstab}\" | grep -E '^[[:space:]]*LABEL=FRITE_(ROOT|BOOT)' >/dev/null; then" \
  "    if false; then"
mutate "${DRIVER}" "${SUITE_D}" 'D5 xattr check satisfied by any count' \
  '    elif [ "${labelled}" -eq "${probed}" ]; then' \
  '    elif [ "${labelled}" -le "${probed}" ]; then'
mutate "${DRIVER}" "${SUITE_D}" 'D6 user-area offset ignored for the MBR read' \
  '    mbr_sig_ok "${raw}" "${off}" && ok "layout: MBR signature' \
  '    mbr_sig_ok "${raw}" 0 && ok "layout: MBR signature'
mutate "${DRIVER}" "${SUITE_D}" 'D7 p1 may start anywhere' \
  '    [ "${p1s:-0}" -ge 2048 ] && ok' \
  '    [ "${p1s:-0}" -ge 0 ] && ok'
mutate "${DRIVER}" "${SUITE_D}" 'D8 rd.luks.name no longer required' \
  '        [[ " ${append} " == *" rd.luks.uuid="* ]] && [[ " ${append} " == *" rd.luks.name="*"=cryptroot "* ]] \' \
  '        [[ " ${append} " == *" rd.luks.uuid="* ]] \'
mutate "${DRIVER}" "${SUITE_D}" 'D9 extlinux.conf presence not checked' \
  '    if fat_has "${raw}" "${p1off}" "extlinux/extlinux.conf"; then' \
  '    if true; then'
mutate "${DRIVER}" "${SUITE_D}" 'D10 LUKS header not checked' \
  '        [ "$(od -An -c -j "${p2off}" -N 4 "${raw}" 2>/dev/null | tr -d '"'"' '"'"')" = "LUKS" ] \' \
  '        true \'
mutate "${DRIVER}" "${SUITE_D}" 'D11 --allow-unlabelled silently passes (no WARN)' \
  '        soft "layout: security.selinux present on' \
  '        ok "layout: security.selinux present on'
mutate "${DRIVER}" "${SUITE_D}" 'D12 board FDT name hardcoded to la-frite' \
    '    [ -n "${CHECK_FDT}" ] || CHECK_FDT="$(board_fdt "${BOARD}")"' \
    '    [ -n "${CHECK_FDT}" ] || CHECK_FDT="amlogic/meson-gxl-s805x-libretech-ac.dtb"'
mutate "${DRIVER}" "${SUITE_D}" 'D13 summary exits 0 on failures' \
  '    [ "${FAIL}" -eq 0 ]
}' \
  '    true
}'

echo
echo "== caught ${CAUGHT}, survived ${SURVIVED} =="
[ "${SURVIVED}" -eq 0 ]
