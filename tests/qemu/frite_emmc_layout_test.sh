#!/usr/bin/env bash
# frite_emmc_layout_test.sh — HERMETIC tests for frite-emmc-install.sh
# --check-layout, the OFFLINE test of the installed-eMMC layout: the part of the
# Frite eMMC install that emulation cannot prove end to end (QEMU has no Amlogic
# boot ROM / SPI-NOR u-boot / meson u-boot mmc numbering) but that does not
# depend on the SoC at all — what u-boot's distro-boot reads off the eMMC.
#
# Boots nothing, needs no root, no loop device: each fixture is a REAL two-
# partition MBR disk built as a file (sfdisk on the file, mformat/mcopy at the
# partition's byte offset, mke2fs -E offset -d, debugfs ea_set for the SELinux
# label), then broken in exactly one way per case. The checker must stay green
# on the good layout, go red on every broken one, and keep working when the
# whole layout sits at a user-area OFFSET inside an eMMC backing file (QEMU's
# emmc device puts 2*boot-partition-size + rpmb bytes in front of the user area).
#
#   bash tests/qemu/frite_emmc_layout_test.sh
#
# WHAT IT DOES NOT PROVE: that install-frite.sh actually PRODUCES the good
# layout (that is the two-phase run with the real medium), or that a real
# La Frite's u-boot boots it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${HERE}/frite-emmc-install.sh"
[ -f "${DRIVER}" ] || { echo "cannot find ${DRIVER}" >&2; exit 2; }

PASS=0; FAIL=0; LAST_LOG=""
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

MISSING=""
for t in sfdisk mformat mcopy mdir mtype minfo mke2fs debugfs od awk cmp; do
    command -v "${t}" >/dev/null 2>&1 || MISSING="${MISSING} ${t}"
done
if [ -n "${MISSING}" ]; then
    echo "SKIPPING LOUDLY — frite_emmc_layout_test.sh cannot run: missing${MISSING}." >&2
    echo "  util-linux (sfdisk) + mtools + e2fsprogs (mke2fs, debugfs) build the layouts this suite asserts against." >&2
    exit 2
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
FDT="amlogic/meson-gxl-s805x-libretech-ac.dtb"
DISK_ID="5ab0c0de"
P1_START=2048; P1_SIZE=32768; P2_START=34816; TOTAL_SECTORS=131072   # 64 MiB

# make_layout OUT [opts...]   opts: root=<APPEND root tokens> | no-fdt-file | no-conf |
#   id=<8 hex> | fstab-label | no-xattr | p2-zero | luks | p1-start=<sector> | no-initrd-file
make_layout() {
    local out="$1"; shift
    local root="" did="${DISK_ID}" fdt_file=true conf=true fstab_label=false xattr=true p2=ext4 initrd_line="" initrd_file=true p1s="${P1_START}" o
    for o in "$@"; do
        case "${o}" in
            root=*)        root="${o#root=}" ;;
            no-fdt-file)   fdt_file=false ;;
            no-conf)       conf=false ;;
            id=*)          did="${o#id=}" ;;
            fstab-label)   fstab_label=true ;;
            no-xattr)      xattr=false ;;
            p2-zero)       p2=zero ;;
            luks)          p2=luks; initrd_line="    INITRD /initrd.img" ;;
            no-initrd-file) initrd_file=false ;;
            p1-start=*)    p1s="${o#p1-start=}" ;;
            *) echo "make_layout: bad opt ${o}" >&2; return 1 ;;
        esac
    done
    [ -n "${root}" ] || root="root=PARTUUID=${did}-02"
    local p2s=$(( p1s + P1_SIZE )) p1off p2off tree root_tree
    p1off=$(( p1s * 512 )); p2off=$(( p2s * 512 ))
    rm -f "${out}"; truncate -s $(( TOTAL_SECTORS * 512 )) "${out}"
    printf 'label: dos\nlabel-id: 0x%s\nstart=%s,size=%s,type=c,bootable\nstart=%s,type=83\n' \
        "${did}" "${p1s}" "${P1_SIZE}" "${p2s}" | sfdisk -q "${out}" >/dev/null 2>&1 || return 1
    # sfdisk refuses/randomises a zero id: write the zero bytes ourselves.
    [ "${did}" != "00000000" ] || printf '\0\0\0\0' | dd of="${out}" bs=1 seek=440 conv=notrunc status=none
    mformat -i "${out}@@${p1off}" -F -T "${P1_SIZE}" -v FRITE_BOOT :: >/dev/null 2>&1 || return 1
    tree="${TMP}/tree.$$"; rm -rf "${tree}"; mkdir -p "${tree}/extlinux" "${tree}/dtb/amlogic"
    echo kernel > "${tree}/Image"
    ${fdt_file} && echo dtb > "${tree}/dtb/${FDT}"
    { [ -n "${initrd_line}" ] && ${initrd_file}; } && echo initrd > "${tree}/initrd.img"
    if ${conf}; then
        cat > "${tree}/extlinux/extlinux.conf" <<EOF
DEFAULT frite
TIMEOUT 20
LABEL frite
    MENU LABEL Brand light desktop
    LINUX /Image
    FDT /dtb/${FDT}
${initrd_line}
    APPEND console=ttyAML0,115200 console=tty1 rootwait lsm=lockdown,yama,selinux lockdown=integrity selinux=1 audit=1 ${root}
EOF
    fi
    ( cd "${tree}" && MTOOLS_SKIP_CHECK=1 mcopy -s -i "${out}@@${p1off}" ./* :: ) >/dev/null 2>&1 || return 1
    case "${p2}" in
        ext4)
            root_tree="${TMP}/root.$$"; rm -rf "${root_tree}"; mkdir -p "${root_tree}/etc" "${root_tree}/bin"
            if ${fstab_label}; then
                printf 'LABEL=FRITE_ROOT\t/\text4\tdefaults\t0 1\nLABEL=FRITE_BOOT\t/boot\tvfat\tdefaults\t0 2\n' > "${root_tree}/etc/fstab"
            else
                printf 'PARTUUID=%s-02\t/\text4\tdefaults\t0 1\nPARTUUID=%s-01\t/boot\tvfat\tdefaults\t0 2\n' "${did}" "${did}" > "${root_tree}/etc/fstab"
            fi
            printf 'root:x:0:0:root:/root:/bin/bash\n' > "${root_tree}/etc/passwd"
            printf '#!/bin/sh\n' > "${root_tree}/bin/sh"
            mke2fs -q -t ext4 -L FRITE_ROOT -E "offset=${p2off}" -d "${root_tree}" "${out}" $(( (TOTAL_SECTORS - p2s) / 2 ))k >/dev/null 2>&1 || return 1
            if ${xattr}; then
                for f in /etc/passwd /bin/sh /etc/fstab; do
                    debugfs -w -R "ea_set ${f} security.selinux system_u:object_r:etc_t:s0" "${out}?offset=${p2off}" >/dev/null 2>&1 || return 1
                done
            fi
            ;;
        luks) printf 'LUKS\xba\xbe' | dd of="${out}" bs=1 seek="${p2off}" conv=notrunc status=none ;;
        zero) : ;;
    esac
}

check() { # check NAME OUT [driver flags...] -> rc; the log lands in LAST_LOG (no subshell)
    local name="$1" out="$2"; shift 2
    LAST_LOG="${TMP}/${name}.log"
    bash "${DRIVER}" --check-layout "${out}" "$@" > "${LAST_LOG}" 2>&1
}
expect_green() { # expect_green NAME OUT [flags]
    local name="$1"; shift
    if check "${name}" "$@" && grep -q ', 0 failed' "${LAST_LOG}"; then
        _ok "${name}: green"
    else
        _bad "${name}: expected green"; grep -E 'FAIL|ERROR' "${LAST_LOG}" | sed 's/^/    | /'
    fi
}
expect_red() { # expect_red NAME OUT MESSAGE-REGEX [flags]
    local name="$1" out="$2" re="$3"; shift 3
    local rc=0
    check "${name}" "${out}" "$@" || rc=$?
    if [ "${rc}" -ne 0 ] && grep -qE "FAIL .*${re}" "${LAST_LOG}"; then
        _ok "${name}: red, naming it (${re})"
    else
        _bad "${name}: expected red with a FAIL matching /${re}/ (rc=${rc})"; grep -E 'FAIL|ERROR|RESULT' "${LAST_LOG}" | sed 's/^/    | /'
    fi
}

echo "== 1) the good layout =="
make_layout "${TMP}/good.raw" || { echo "cannot build the good fixture" >&2; exit 2; }
expect_green good "${TMP}/good.raw"
grep -q "root=PARTUUID=${DISK_ID}-02 matches" "${TMP}/good.log" && _ok "good: the root=PARTUUID check names the MBR id" || _bad "good: PARTUUID check not reported"
grep -q 'security.selinux xattrs survived' "${TMP}/good.log" && _ok "good: xattr check passed on 3/3 files" || _bad "good: xattr check not reported"
grep -q 'FDT file /dtb/amlogic/meson-gxl-s805x-libretech-ac.dtb exists' "${TMP}/good.log" && _ok "good: FDT file presence asserted" || _bad "good: FDT check missing"

echo "== 2) the layout at a user-area OFFSET (an emmc backing file) =="
OFF=$(( 2 * 4194304 + 131072 ))   # 2 x 4 MiB boot + 128 KiB rpmb
{ head -c "${OFF}" /dev/zero; cat "${TMP}/good.raw"; } > "${TMP}/padded.raw"
expect_green padded-with-offset "${TMP}/padded.raw" --user-offset "${OFF}"
expect_red padded-without-offset "${TMP}/padded.raw" 'no MBR signature'
expect_red good-wrong-offset "${TMP}/good.raw" 'no MBR signature' --user-offset 4096
check bad-offset "${TMP}/good.raw" --user-offset abc && _bad "non-numeric offset accepted" || _ok "a non-numeric --user-offset is refused"

echo "== 3) one defect per fixture: each must go RED by name =="
make_layout "${TMP}/label.raw"  root=root=LABEL=FRITE_ROOT  && expect_red root-label-left  "${TMP}/label.raw"  'root=LABEL'
make_layout "${TMP}/p1root.raw" "root=root=PARTUUID=${DISK_ID}-01" && expect_red root-points-at-p1 "${TMP}/p1root.raw" "expected root=PARTUUID=${DISK_ID}-02"
make_layout "${TMP}/otherid.raw" "root=root=PARTUUID=deadbeef-02" && expect_red root-other-disk-id "${TMP}/otherid.raw" "expected root=PARTUUID=${DISK_ID}-02"
make_layout "${TMP}/nofdt.raw"  no-fdt-file                 && expect_red fdt-file-missing  "${TMP}/nofdt.raw"  'FDT file .* MISSING'
make_layout "${TMP}/noconf.raw" no-conf                     && expect_red no-extlinux-conf  "${TMP}/noconf.raw" 'no /extlinux/extlinux.conf'
make_layout "${TMP}/idzero.raw" id=00000000                 && expect_red disk-id-zero      "${TMP}/idzero.raw" 'disk identifier is 00000000'
[ "$(grep -c 'FAIL' "${TMP}/disk-id-zero.log")" = 1 ] && _ok "disk-id-zero: the zero id is the ONLY failure (root=/fstab agree with it)" || _bad "disk-id-zero: more than one FAIL — the fixture is not minimal"
make_layout "${TMP}/fstab.raw"  fstab-label                 && expect_red fstab-not-rewritten "${TMP}/fstab.raw" 'fstab still mounts LABEL='
make_layout "${TMP}/noxattr.raw" no-xattr                   && expect_red xattrs-lost       "${TMP}/noxattr.raw" 'security.selinux xattrs on only 0/3'
expect_green xattrs-lost-but-allowed "${TMP}/noxattr.raw" --allow-unlabelled
grep -q 'WARN .*allow-unlabelled' "${TMP}/xattrs-lost-but-allowed.log" && _ok "--allow-unlabelled still WARNs" || _bad "--allow-unlabelled is silent"
make_layout "${TMP}/p2zero.raw" p2-zero                     && expect_red p2-not-ext4       "${TMP}/p2zero.raw" 'not a readable ext4'
make_layout "${TMP}/low.raw"    p1-start=64                 && expect_red p1-below-1MiB     "${TMP}/low.raw"    'starts at sector 64'
bash "${DRIVER}" --check-layout "${TMP}/good.raw" --board le-potato > "${TMP}/board.log" 2>&1
grep -q "expected /dtb/amlogic/meson-gxl-s905x-libretech-cc.dtb" "${TMP}/board.log" && _ok "--board le-potato expects THAT board's FDT (table shared with launch-arm.sh)" || _bad "board FDT not taken from the launcher table"

echo "== 4) encrypted root (LUKS2 p2) =="
make_layout "${TMP}/luks.raw" luks "root=root=/dev/mapper/cryptroot rd.luks.uuid=1111-2222 rd.luks.name=1111-2222=cryptroot" \
    && expect_green luks-good "${TMP}/luks.raw"
grep -q 'p2 carries a LUKS header' "${TMP}/luks-good.log" && _ok "luks: header asserted" || _bad "luks: header not asserted"
make_layout "${TMP}/luks-noname.raw" luks "root=root=/dev/mapper/cryptroot rd.luks.uuid=1111-2222" \
    && expect_red luks-no-rd-luks-name "${TMP}/luks-noname.raw" 'rd.luks.name='
make_layout "${TMP}/luks-noinitrd.raw" luks no-initrd-file "root=root=/dev/mapper/cryptroot rd.luks.uuid=1111-2222 rd.luks.name=1111-2222=cryptroot" \
    && expect_red luks-initrd-file-missing "${TMP}/luks-noinitrd.raw" 'INITRD /initrd.img named but missing'
make_layout "${TMP}/luks-noheader.raw" "root=root=/dev/mapper/cryptroot rd.luks.uuid=1111-2222 rd.luks.name=1111-2222=cryptroot" \
    && expect_red luks-cmdline-plain-p2 "${TMP}/luks-noheader.raw" 'no LUKS header'

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
