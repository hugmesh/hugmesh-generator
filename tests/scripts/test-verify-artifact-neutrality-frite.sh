#!/usr/bin/env bash
# test-verify-artifact-neutrality-frite.sh — the brand-neutrality gate
# (scripts/verify-artifact-neutrality.sh) must READ the frite media.
#
# Since #881 the frite builder's LIVE and INSTALLER media are raw images,
# <prefix>.live.img / <prefix>.installer.img: an MBR plus one FAT32 partition at
# 4 MiB (u-boot distro-boot has no ISO9660 driver). The gate globbed only
# gentoo-*.live.iso / *.installer.iso for media, and its gentoo-*.img glob sent the
# FAT media to the installed-disk section, which demands a GENTOO_ESP and an
# EFI/BOOT/bootx64.efi that a u-boot medium never carries: a neutral medium was
# FAILed for the wrong reason, and nothing in its FAT tree, extlinux.conf,
# squashfs or embedded stage4 was ever looked at.
#
# Hermetic: the media are built here with mtools (mformat/mcopy) and a
# hand-written MBR — no root, no loop devices, no mkfs. The gate runs its readers
# in a "builder" container; a docker shim on PATH runs those commands on the host
# instead (the read-only /a mount becomes the host directory), and the squashfs is
# a text listing that the shim's unsquashfs prints for `-l`. What is under test is
# the gate's routing and verdicts, not mtools or squashfs-tools.
#
# Run: bash tests/scripts/test-verify-artifact-neutrality-frite.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${REPO}/scripts/verify-artifact-neutrality.sh"
[ -f "${GATE}" ] || { echo "  FAIL gate missing: ${GATE}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# Fail CLOSED on a missing tool: a skipped leg here would read as "the gate
# checks frite media" while asserting nothing.
missing=""
for t in mformat mcopy mdir mtype file strings xorriso xz od dd truncate; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
done
if [ -n "${missing}" ]; then
    echo "  FAIL required tools missing:${missing}"
    echo "== done: 0 passed, 1 failed =="
    exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
echo "== verify-artifact-neutrality.sh: frite raw media =="

# ── the builder-container shim ───────────────────────────────────────────────
SHIM="${WORK}/shim"; BLD="${WORK}/builder-bin"
mkdir -p "${SHIM}" "${BLD}"
cat > "${SHIM}/docker" <<'SH'
#!/usr/bin/env bash
# `docker image inspect IMG` -> present; `docker run --rm --network=none -v SRC:/a:ro
# IMG cmd args...` -> cmd args on the host, /a/<x> rewritten to SRC/<x>.
case "${1:-}" in
    image) exit 0 ;;
    run)
        shift; vol=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --rm|--network=*) shift ;;
                -v) vol="${2%%:*}"; shift 2 ;;
                *) break ;;
            esac
        done
        shift   # the image name
        args=()
        for a in "$@"; do
            case "$a" in /a/*) a="${vol}/${a#/a/}" ;; esac
            args+=("$a")
        done
        PATH="${SHIM_BUILDER_BIN}:${PATH}" exec "${args[@]}"
        ;;
esac
exit 1
SH
cat > "${BLD}/unsquashfs" <<'SH'
#!/usr/bin/env bash
# fixture squashfs = its own listing, one path per line
[ "${1:-}" = "-l" ] && [ -f "${2:-}" ] && exec cat "$2"
exit 1
SH
chmod +x "${SHIM}/docker" "${BLD}/unsquashfs"

# ── fixtures ─────────────────────────────────────────────────────────────────
STEM="gentoo-frite-aml-s905x-cc-arm64-desktop-prod-20261105T010203Z"
P1_SECTOR=8192            # 4 MiB, build_frite_medium's FRITE_MEDIUM_P1_MIB
FAT_SECTORS=81920         # 40 MiB: enough clusters for a real FAT32

le32() {  # le32 <n> — 4 little-endian bytes as printf escapes
    printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) \
        $(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 ))
}

# mk_medium <out.img> <label> <tree-dir> [ptype-hex]
mk_medium() {
    local out="$1" label="$2" tree="$3" ptype="${4:-0c}" fat="$1.fat"
    rm -f "${fat}" "${out}"
    MTOOLS_SKIP_CHECK=1 mformat -i "${fat}" -C -T "${FAT_SECTORS}" -c 1 -F -v "${label}" :: \
        || { echo "fixture: mformat failed"; return 1; }
    MTOOLS_SKIP_CHECK=1 mcopy -i "${fat}" -s -m -Q "${tree}"/* ::/ \
        || { echo "fixture: mcopy failed"; return 1; }
    truncate -s $(( (P1_SECTOR + FAT_SECTORS) * 512 )) "${out}"
    # one primary entry: bootable, type ${ptype}, LBA start, sector count; then 55AA
    # shellcheck disable=SC2059
    printf "\\x80\\x00\\x00\\x00\\x${ptype}\\x00\\x00\\x00$(le32 "${P1_SECTOR}")$(le32 "${FAT_SECTORS}")" \
        | dd of="${out}" bs=1 seek=446 conv=notrunc status=none
    printf '\x55\xaa' | dd of="${out}" bs=1 seek=510 conv=notrunc status=none
    dd if="${fat}" of="${out}" bs=512 seek="${P1_SECTOR}" conv=notrunc status=none
    rm -f "${fat}"
}

# mk_tree <dir> <live|installer> <label> — what build-frite-stage4.sh lays on the FAT
mk_tree() {
    local d="$1" kind="$2" label="$3"
    mkdir -p "${d}/extlinux" "${d}/LiveOS" "${d}/dtb/amlogic"
    printf 'kernel\n' > "${d}/Image"
    printf 'initrd\n' > "${d}/initrd.img"
    printf 'fdt\n' > "${d}/dtb/amlogic/meson-gxl-s905x-libretech-cc.dtb"
    cat > "${d}/extlinux/extlinux.conf" <<EOF
DEFAULT frite
LABEL frite
    LINUX /Image
    FDT /dtb/amlogic/meson-gxl-s905x-libretech-cc.dtb
    INITRD /initrd.img
    APPEND console=ttyAML0,115200 root=live:LABEL=${label} rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img
EOF
    printf 'squashfs-root\nsquashfs-root/etc\nsquashfs-root/etc/gentoo-release\nsquashfs-root/usr/bin/bash\n' \
        > "${d}/LiveOS/squashfs.img"
    if [ "${kind}" = installer ]; then
        mkdir -p "${d}/stage4" "${d}/boot"
        printf 'stage4\n' > "${d}/stage4/${STEM}.stage4.tar.xz"
        printf '#!/bin/sh\n' > "${d}/install-frite.sh"
    fi
}

# run_gate <dir> — the gate under the shim; echoes output, returns its rc
run_gate() {
    PATH="${SHIM}:${PATH}" SHIM_BUILDER_BIN="${BLD}" \
        bash "${GATE}" --workdir="${WORK}" "$1" hugmesh-builder-shim 2>&1
}

# case_dir <name> <mutator-fn|-> — a dir with a neutral live + installer medium,
# the mutator applied to the trees before the media are built
case_dir() {
    local name="$1" mut="$2" d="${WORK}/case-$1"
    mkdir -p "${d}"
    rm -rf "${WORK}/t-live" "${WORK}/t-inst"
    mk_tree "${WORK}/t-live" live FRITE_LIVE
    mk_tree "${WORK}/t-inst" installer FRITE_INST
    [ "${mut}" = - ] || "${mut}" "${WORK}/t-live" "${WORK}/t-inst"
    mk_medium "${d}/${STEM}.live.img" FRITE_LIVE "${WORK}/t-live" "${PTYPE:-0c}" || return 1
    mk_medium "${d}/${STEM}.installer.img" FRITE_INST "${WORK}/t-inst" "${PTYPE:-0c}" || return 1
    echo "${d}"
}

# ── 1. neutral media: the gate reads them and passes ─────────────────────────
D="$(case_dir neutral -)" || { bad "fixture build failed"; D=""; }
out="$(run_gate "${D}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "neutral frite media pass the gate (rc=0)" \
    || bad "neutral frite media FAILED the gate (rc=${rc}): $(echo "${out}" | grep '^FAIL' | head -5 | tr '\n' ' ')"
for k in live installer; do
    b="${STEM}.${k}.img"
    echo "${out}" | grep -F "PASS: ${b}: no hugmesh-named paths in the FAT tree" >/dev/null \
        && ok "${k}: the FAT tree was listed and swept" || bad "${k}: the FAT tree was never swept"
    echo "${out}" | grep -F "PASS: ${b}: extlinux.conf is hugmesh-free" >/dev/null \
        && ok "${k}: extlinux.conf was read off the FAT" || bad "${k}: extlinux.conf was not read"
    echo "${out}" | grep -F "PASS: ${b} squashfs: no /etc/hugmesh marker tree" >/dev/null \
        && ok "${k}: the squashfs on the FAT was swept" || bad "${k}: the squashfs was not swept"
    echo "${out}" | grep -F "PASS: ${b}: FAT volume label is hugmesh-free" >/dev/null \
        && ok "${k}: FAT label checked" || bad "${k}: FAT label not checked"
    echo "${out}" | grep -F "${b}: ESP volume label" >/dev/null \
        && bad "${k}: the medium was fed to the installed-disk (GPT/ESP) section" \
        || ok "${k}: not mistaken for an installed disk image"
done
echo "${out}" | grep -F "PASS: ${STEM}.installer.img: embedded stage4 tarball is gentoo-named" >/dev/null \
    && ok "installer: embedded stage4 name checked" || bad "installer: embedded stage4 name not checked"

# ── 2. branded content on the FAT must FAIL the gate ─────────────────────────
expect_fail() {  # expect_fail <label> <fail-line-regex> <mutator>
    local label="$1" want="$2" mut="$3" d out rc
    d="$(case_dir "${mut}" "${mut}")" || { bad "${label}: fixture build failed"; return; }
    out="$(run_gate "${d}")"; rc=$?
    if [ "${rc}" -eq 0 ]; then bad "${label}: gate PASSED a branded medium"; return; fi
    echo "${out}" | grep -E "^FAIL: .*${want}" >/dev/null && ok "${label}" \
        || bad "${label}: rc=${rc} but not for /${want}/: $(echo "${out}" | grep '^FAIL' | head -3 | tr '\n' ' ')"
}
m_tree()   { printf 'x\n' > "$1/hugmesh-firstboot.sh"; }
m_conf()   { sed -i 's/^    APPEND /    APPEND hugmesh.role=desktop /' "$1/extlinux/extlinux.conf"; }
m_sq()     { printf 'squashfs-root/etc/hugmesh\nsquashfs-root/etc/hugmesh/mesh.conf\n' >> "$2/LiveOS/squashfs.img"; }
m_stage4() { mv "$2/stage4/${STEM}.stage4.tar.xz" "$2/stage4/hugmesh-frite.stage4.tar.xz"; }
m_nost4()  { rm -rf "$2/stage4"; }
m_nosq()   { rm -f "$1/LiveOS/squashfs.img"; }
expect_fail "hugmesh-named file in the live FAT tree FAILs"   'hugmesh-named paths in the FAT tree' m_tree
expect_fail "hugmesh token in the live extlinux.conf FAILs"   'hugmesh token in extlinux.conf' m_conf
expect_fail "hugmesh marker tree in the installer squashfs FAILs" 'squashfs: /etc/hugmesh marker tree present' m_sq
expect_fail "non-gentoo stage4 on the installer FAILs"        'non-gentoo-named file under /stage4' m_stage4
expect_fail "installer medium without /stage4 FAILs"          'carries no /stage4' m_nost4
expect_fail "live medium without its squashfs FAILs (never a silent skip)" 'no squashfs found in the FAT tree' m_nosq

# ── 3. a medium whose MBR has no FAT partition is FAILed, not skipped ─────────
d="$(PTYPE=83 case_dir nofat -)" || bad "nofat fixture build failed"
out="$(run_gate "${d}")"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep -E '^FAIL: .*no FAT partition in the MBR' >/dev/null \
    && ok "no FAT partition in the MBR FAILs (the tree was NOT checked)" \
    || bad "a medium with no FAT partition was not FAILed (rc=${rc})"

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
