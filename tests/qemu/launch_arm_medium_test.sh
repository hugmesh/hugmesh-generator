#!/usr/bin/env bash
# launch_arm_medium_test.sh — HERMETIC tests for launch-arm.sh's Frite medium /
# eMMC / --gpu path and for the -dtb drop. Boots nothing, needs no root: real
# media are built as files (ISO9660 via xorriso, MBR+FAT via sfdisk + mformat at
# an offset, bare FAT via mformat), the launcher runs against a PATH stub of
# qemu-system-aarch64 that records its argv, and every assertion is on that argv
# or on the bytes the launcher lifted off the medium.
#
#   bash tests/qemu/launch_arm_medium_test.sh
#
# WHY (2026-11-04). The Frite builder emits no .img, only ISO media; launch-arm.sh
# looked for *.img, read DTBs from boot/dtbs/ and — for every one of its eight
# boards — passed the BOARD's DTB to -M virt, which replaces QEMU's own device
# tree with one that describes no virt hardware (no PL011, no PCIe, no virtio):
# no console, no disk, no NIC, filed as "experimental board inconclusive". The
# Frite eMMC-install proof (frite-emmc-install.sh) needs the medium booted with
# its own kernel/initrd/APPEND, an sdhci-pci eMMC target and a GPU for the
# greeter screenshot. This suite pins each of those argv facts.
#
# WHAT IT DOES NOT PROVE. No guest runs: whether the Frite kernel has
# CONFIG_MMC_SDHCI_PCI / DRM_VIRTIO_GPU, whether dracut finds the medium on USB,
# whether the greeter draws — those are the prover's, with the real medium.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${HERE}/launch-arm.sh"
[ -f "${LAUNCHER}" ] || { echo "cannot find ${LAUNCHER}" >&2; exit 2; }

PASS=0; FAIL=0; SKIP=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

# NO SILENT SKIPS: the fixtures ARE the test.
MISSING=""
for t in mformat mcopy minfo mdir sfdisk xorriso cmp od awk; do
    command -v "${t}" >/dev/null 2>&1 || MISSING="${MISSING} ${t}"
done
if [ -n "${MISSING}" ]; then
    echo "SKIPPING LOUDLY — launch_arm_medium_test.sh cannot run: missing${MISSING}." >&2
    echo "  mtools + util-linux (sfdisk) + xorriso + diffutils build the media this suite asserts against." >&2
    exit 2
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"

# ── Stubs: record argv; answer `-device help` like a QEMU that has emmc ───────
cat > "${BIN}/qemu-system-aarch64" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-device" ] && [ "${2:-}" = "help" ]; then
    printf 'name "sdhci-pci", bus PCI\nname "emmc", bus sd-bus, desc "eMMC"\nname "virtio-gpu-pci", bus PCI\n'
    exit 0
fi
printf '%s\n' "$@" > "${STUB_ARGV_OUT:?}"
exit 0
STUB
cat > "${BIN}/qemu-img" <<'STUB'
#!/usr/bin/env bash
echo "qemu-img $*" >> "${STUB_QEMU_IMG_LOG:?}"
exit 0
STUB
chmod +x "${BIN}"/*

# ── Fixture: the boot tree a Frite INSTALLER medium carries ──────────────────
FDT="amlogic/meson-gxl-s805x-libretech-ac.dtb"
TREE="${TMP}/tree"; mkdir -p "${TREE}/extlinux" "${TREE}/dtb/amlogic" "${TREE}/LiveOS"
head -c 4096 /dev/urandom > "${TREE}/Image"
head -c 8192 /dev/urandom > "${TREE}/initrd.img"
echo "dtb" > "${TREE}/dtb/${FDT}"
echo "squash" > "${TREE}/LiveOS/squashfs.img"
APPEND_BASE="console=ttyAML0,115200 console=tty1 rootwait lsm=lockdown,yama,selinux lockdown=integrity selinux=1 audit=1 cgroup_enable=memory"
cat > "${TREE}/extlinux/extlinux.conf" <<EOF
# rendered by build-frite-stage4.sh
DEFAULT frite
TIMEOUT 20
MENU TITLE Brand — Libre Computer Frite

LABEL rescue
    MENU LABEL rescue (not the default)
    LINUX /Image
    APPEND root=/dev/null rescue

LABEL frite
    MENU LABEL Brand light desktop
    LINUX /Image
    FDT /dtb/${FDT}
    INITRD /initrd.img
    APPEND ${APPEND_BASE} root=live:LABEL=FRITE_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1
EOF

# ISO9660 (what the builder emits today)
ISO="${TMP}/brand-frite-la-frite-arm64-desktop-prod-1.installer.iso"
xorriso -as mkisofs -quiet -o "${ISO}" -V FRITE_INSTALL -joliet -rock "${TREE}" 2>/dev/null \
    || { echo "cannot build the ISO fixture" >&2; exit 2; }
# MBR + FAT32 partition at 1 MiB (the u-boot-bootable form the builder fix will emit)
MBR="${TMP}/brand-frite-la-frite-arm64-desktop-prod-2.installer.img"
truncate -s 40M "${MBR}"
printf 'label: dos\nlabel-id: 0x5ab0c0de\nstart=2048,size=65536,type=c,bootable\n' | sfdisk -q "${MBR}" >/dev/null 2>&1 \
    || { echo "cannot partition the MBR fixture" >&2; exit 2; }
mformat -i "${MBR}@@1048576" -F -T 65536 -v FRITE_INSTALL :: >/dev/null 2>&1 || { echo "cannot mformat the MBR fixture" >&2; exit 2; }
( cd "${TREE}" && MTOOLS_SKIP_CHECK=1 mcopy -s -i "${MBR}@@1048576" Image initrd.img extlinux dtb LiveOS :: ) || { echo "cannot populate the MBR fixture" >&2; exit 2; }
# Bare FAT (no partition table)
FAT="${TMP}/bare.fat"
truncate -s 32M "${FAT}"
mformat -i "${FAT}" -F -v FRITE_INSTALL :: >/dev/null 2>&1 || { echo "cannot mformat the bare FAT fixture" >&2; exit 2; }
( cd "${TREE}" && MTOOLS_SKIP_CHECK=1 mcopy -s -i "${FAT}" Image initrd.img extlinux dtb :: ) || exit 2
# A lying extension: MBR+FAT bytes named .iso (format is decided by magic)
LIAR="${TMP}/liar.iso"; cp "${MBR}" "${LIAR}"
# An ISO with no extlinux.conf at all
BARE_TREE="${TMP}/bare-tree"; mkdir -p "${BARE_TREE}"; echo x > "${BARE_TREE}/README"
NOCONF="${TMP}/noconf.iso"; xorriso -as mkisofs -quiet -o "${NOCONF}" -V X -joliet -rock "${BARE_TREE}" 2>/dev/null
# Golden-path bits
GOLD="${TMP}/brand-frite-la-frite-arm64-desktop-prod-3.img"; truncate -s 1M "${GOLD}"
KERNEL="${TMP}/Image"; cp "${TREE}/Image" "${KERNEL}"
DTBFILE="${TMP}/board.dtb"; echo dtb > "${DTBFILE}"
# eMMC backing files
EMMC="${TMP}/emmc.raw"; truncate -s $(( 8 * 1024 * 1024 * 1024 + 2 * 4194304 )) "${EMMC}"
EMMC_RO="${TMP}/emmc-ro.raw"; truncate -s $(( 8 * 1024 * 1024 * 1024 + 2 * 4194304 )) "${EMMC_RO}"; chmod 0444 "${EMMC_RO}"
EMMC_TINY="${TMP}/emmc-tiny.raw"; truncate -s 4194304 "${EMMC_TINY}"
EMMC_NP2="${TMP}/emmc-np2.raw"; truncate -s $(( 1536 * 1024 * 1024 + 2 * 4194304 )) "${EMMC_NP2}"   # 1.5 GiB user area: <= 2 GiB and not a power of 2

N=0
run() { # run OUT [launcher args...] -> exit code; argv in OUT, log in OUT.log
    local out="$1"; shift
    N=$((N+1))
    rm -f "${out}"
    PATH="${BIN}:${PATH}" STUB_ARGV_OUT="${out}" STUB_QEMU_IMG_LOG="${out}.qemu-img" \
        bash "${LAUNCHER}" --platform frite --board la-frite --run-dir "${TMP}/run${N}" --keep "$@" > "${out}.log" 2>&1
}
argv_has()    { grep -qxF -- "$2" "$1"; }
argv_count()  { grep -cxF -- "$2" "$1"; }
append_of()   { awk 'p { print; exit } $0 == "-append" { p = 1 }' "$1"; }
val_after()   { awk -v k="$2" 'p { print; exit } $0 == k { p = 1 }' "$1"; }

echo "== 1) the -dtb drop: default argv boots QEMU's own virt device tree =="
run "${TMP}/a1" --img "${GOLD}" --kernel "${KERNEL}" \
    && _ok "golden .img + --kernel, no --dtb: exits 0" || { _bad "golden path failed"; sed 's/^/    | /' "${TMP}/a1.log"; }
argv_has "${TMP}/a1" "-dtb" && _bad "default argv carries -dtb (the board DTB replaces virt's DT: no console/disk/NIC)" || _ok "default argv has NO -dtb"
grep -q 'board FDT name: amlogic/meson-gxl-s805x-libretech-ac.dtb' "${TMP}/a1.log" && _ok "the board FDT NAME is still known (for the layout checks)" || _bad "board FDT name not reported"
append_of "${TMP}/a1" | grep '^root=/dev/vda2 rootfstype=ext4 rw rootwait console=ttyAMA0,115200 net.ifnames=0 lsm=lockdown,yama,selinux lockdown=integrity selinux=1 audit=1 ' >/dev/null \
    && _ok "golden-path cmdline unchanged (root=/dev/vda2 ... + cmdline.base posture)" || _bad "golden-path cmdline changed: $(append_of "${TMP}/a1")"
for tok in -initrd qemu-xhci,id=xhci virtio-gpu-pci sdhci-pci,sd-spec-version=3 usb-storage,bus=xhci.0,drive=medium,removable=on; do
    argv_has "${TMP}/a1" "${tok}" && _bad "DEFAULT-OFF violated: ${tok} on the flagless argv" || _ok "default-off: no ${tok}"
done
argv_has "${TMP}/a1" "virtio-blk-pci,drive=hd0" && _ok "golden overlay disk still attached" || _bad "golden overlay disk missing"
grep -q 'qemu-img create' "${TMP}/a1.qemu-img" && _ok "golden path still builds its qcow2 overlay" || _bad "overlay not created"

run "${TMP}/a2" --img "${GOLD}" --kernel "${KERNEL}" --dtb "${DTBFILE}" \
    && _ok "--dtb FILE: exits 0 (explicit opt-in)" || _bad "--dtb FILE failed"
[ "$(val_after "${TMP}/a2" -dtb)" = "${DTBFILE}" ] && _ok "--dtb FILE is passed to QEMU verbatim" || _bad "--dtb not passed"
grep -q 'REPLACES QEMU' "${TMP}/a2.log" && _ok "--dtb warns that it replaces virt's device tree" || _bad "--dtb opt-in is silent"
run "${TMP}/a3" --img "${GOLD}" --kernel "${KERNEL}" --dtb "${TMP}/does-not-exist.dtb" \
    && _bad "--dtb to a missing file exited 0" || _ok "--dtb to a missing file dies"
grep -q 'board.dtb\|dtbs/' "${TMP}/a1.log" && _bad "launcher still mentions a boot/dtbs lookup on the default path" || _ok "no boot/dtbs/ lookup on the default path"

echo "== 2) --medium: kernel + initrd + APPEND lifted off the medium, medium on USB =="
for m in "${ISO}" "${MBR}" "${FAT}" "${LIAR}"; do
    kind="$(basename "${m}")"
    run "${TMP}/m-${kind}" --medium "${m}" \
        && _ok "--medium ${kind}: exits 0 (no --img, no --kernel)" || { _bad "--medium ${kind} failed"; sed 's/^/    | /' "${TMP}/m-${kind}.log"; continue; }
    cmp -s "$(val_after "${TMP}/m-${kind}" -kernel)" "${TREE}/Image" && _ok "${kind}: -kernel is byte-for-byte the medium's /Image" || _bad "${kind}: -kernel is not the medium's Image"
    cmp -s "$(val_after "${TMP}/m-${kind}" -initrd)" "${TREE}/initrd.img" && _ok "${kind}: -initrd is byte-for-byte the medium's /initrd.img (INITRD line)" || _bad "${kind}: -initrd wrong/missing"
    argv_has "${TMP}/m-${kind}" "-dtb" && _bad "${kind}: -dtb leaked onto a medium boot" || _ok "${kind}: no -dtb"
    a="$(append_of "${TMP}/m-${kind}")"
    lost=""
    for tok in root=live:LABEL=FRITE_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1; do
        case " ${a} " in *" ${tok} "*) ;; *) lost="${lost} ${tok}" ;; esac
    done
    [ -z "${lost}" ] && _ok "${kind}: APPEND keeps the DEFAULT label's root=live:/rd.live.* verbatim" || _bad "${kind}: APPEND lost${lost}: ${a}"
    case " ${a} " in *" rescue "*|*"root=/dev/null"*) _bad "${kind}: APPEND came from the NON-default label" ;; *) _ok "${kind}: APPEND is the DEFAULT label's, not the first label's" ;; esac
    lost=""
    for tok in lsm=lockdown,yama,selinux lockdown=integrity selinux=1 audit=1; do
        case " ${a} " in *" ${tok} "*) ;; *) lost="${lost} ${tok}" ;; esac
    done
    [ -z "${lost}" ] && _ok "${kind}: APPEND keeps the cmdline.base posture" || _bad "${kind}: posture tokens lost:${lost}"
    case " ${a} " in *"console=ttyAML0"*) _bad "${kind}: the board UART console=ttyAML0 survived (does not exist on -M virt)" ;; *) _ok "${kind}: console=ttyAML0 dropped" ;; esac
    case "${a}" in *" console=ttyAMA0,115200") _ok "${kind}: console=ttyAMA0,115200 is LAST (/dev/console = the serial log)" ;; *) _bad "${kind}: console=ttyAMA0 not last: ${a}" ;; esac
    case " ${a} " in *" console=tty1 "*) _ok "${kind}: console=tty1 (the VT) kept" ;; *) _bad "${kind}: console=tty1 dropped" ;; esac
    case " ${a} " in *"FDT"*|*"/dtb/"*) _bad "${kind}: the FDT line leaked into the cmdline" ;; *) _ok "${kind}: FDT line not in the cmdline" ;; esac
    [ "$(argv_count "${TMP}/m-${kind}" "qemu-xhci,id=xhci")" = 1 ] && _ok "${kind}: exactly one qemu-xhci" || _bad "${kind}: qemu-xhci count $(argv_count "${TMP}/m-${kind}" "qemu-xhci,id=xhci")"
    argv_has "${TMP}/m-${kind}" "usb-storage,bus=xhci.0,drive=medium,removable=on" && _ok "${kind}: medium is usb-storage on the xhci bus" || _bad "${kind}: no usb-storage device"
    argv_has "${TMP}/m-${kind}" "file=${m},format=raw,if=none,id=medium,readonly=on" && _ok "${kind}: medium drive is read-only" || _bad "${kind}: medium drive not readonly=on"
    argv_has "${TMP}/m-${kind}" "virtio-blk-pci,drive=hd0" && _bad "${kind}: a golden overlay disk appeared without --img" || _ok "${kind}: no golden overlay disk"
done
grep -q 'liar.iso (mbr' "${TMP}/m-liar.iso.log" && _ok "format decided by MAGIC: MBR bytes named .iso are read as mbr" || _bad "a .iso-named MBR image was not detected as mbr"

run "${TMP}/mv" --medium "${ISO}" --medium-bus virtio \
    && _ok "--medium-bus virtio: exits 0" || _bad "--medium-bus virtio failed"
argv_has "${TMP}/mv" "virtio-blk-pci,drive=medium" && _ok "virtio bus: medium on virtio-blk" || _bad "virtio bus: no virtio-blk medium"
argv_has "${TMP}/mv" "qemu-xhci,id=xhci" && _bad "virtio bus without --gpu still emits an xhci" || _ok "virtio bus without --gpu: no xhci"
run "${TMP}/mb" --medium "${ISO}" --medium-bus floppy && _bad "--medium-bus floppy accepted" || _ok "--medium-bus floppy rejected"
run "${TMP}/mn" --medium "${NOCONF}" && _bad "a medium without extlinux.conf booted" || _ok "a medium without /extlinux/extlinux.conf is refused"
grep -q 'extlinux' "${TMP}/mn.log" && _ok "...and the refusal names extlinux.conf" || _bad "refusal does not say why"
run "${TMP}/mk" --medium "${ISO}" --kernel "${KERNEL}" && [ "$(val_after "${TMP}/mk" -kernel)" = "${KERNEL}" ] \
    && _ok "--kernel FILE wins over the medium's Image" || _bad "--kernel not honoured with --medium"

echo "== 3) --gpu =="
run "${TMP}/g1" --medium "${ISO}" --gpu && _ok "--medium + --gpu exits 0" || _bad "--gpu failed"
for tok in virtio-gpu-pci usb-kbd,bus=xhci.0 usb-tablet,bus=xhci.0; do
    argv_has "${TMP}/g1" "${tok}" && _ok "--gpu: ${tok}" || _bad "--gpu: ${tok} missing"
done
[ "$(argv_count "${TMP}/g1" "qemu-xhci,id=xhci")" = 1 ] && _ok "--gpu + USB medium share ONE qemu-xhci" || _bad "--gpu + USB medium: $(argv_count "${TMP}/g1" "qemu-xhci,id=xhci") xhci controllers"
argv_has "${TMP}/g1" "none" && [ "$(val_after "${TMP}/g1" -display)" = "none" ] && _ok "--gpu keeps -display none (screendump reads the virtual framebuffer)" || _bad "--gpu changed -display"
run "${TMP}/g2" --img "${GOLD}" --kernel "${KERNEL}" --gpu && [ "$(argv_count "${TMP}/g2" "qemu-xhci,id=xhci")" = 1 ] \
    && _ok "--gpu alone (no medium) brings its own single xhci for the input devices" || _bad "--gpu alone: xhci missing/duplicated"

echo "== 4) --emmc: sdhci-pci + emmc, preflight per hw/sd/sd.c =="
run "${TMP}/e1" --medium "${ISO}" --emmc "${EMMC}" && _ok "--emmc 8 GiB + 2x4 MiB boot: exits 0" || { _bad "--emmc failed"; sed 's/^/    | /' "${TMP}/e1.log"; }
argv_has "${TMP}/e1" "sdhci-pci,sd-spec-version=3" && _ok "sdhci-pci host controller" || _bad "no sdhci-pci"
argv_has "${TMP}/e1" "emmc,drive=emmc,boot-partition-size=4194304" && _ok "emmc device with boot-partition-size=4194304" || _bad "emmc device missing/wrong: $(grep '^emmc' "${TMP}/e1" || true)"
argv_has "${TMP}/e1" "file=${EMMC},format=raw,if=none,id=emmc" && _ok "eMMC backing file attached raw, writable, no overlay" || _bad "eMMC drive wrong"
grep -q 'user area at +8388608' "${TMP}/e1.log" && _ok "reports the user-area offset (2*boot) a host reader must add" || _bad "user-area offset not reported"
run "${TMP}/e2" --medium "${ISO}" --emmc "${EMMC}" --emmc-rpmb-size 131072 \
    && argv_has "${TMP}/e2" "emmc,drive=emmc,boot-partition-size=4194304,rpmb-partition-size=131072" \
    && _ok "--emmc-rpmb-size lands on the device" || _bad "rpmb size not passed"
grep -q 'user area at +8519680' "${TMP}/e2.log" && _ok "user-area offset includes the RPMB" || _bad "offset ignores rpmb"
# chmod 0444 makes a file unwritable to everyone EXCEPT root (CAP_DAC_OVERRIDE):
# as root `[ -w ]` is true and QEMU really can open it read-write, so the
# launcher is right to accept it and the case cannot be built. The CI leg runs
# as root in alpine:3; this case runs on any non-root run (and in
# frite_emmc_mutations.sh, which kills L12 there). Said by name, never silent.
if [ -w "${EMMC_RO}" ]; then
    SKIP=$((SKIP+1))
    printf '  SKIP read-only eMMC refusal: running as uid %s, chmod 0444 cannot make a file unwritable to it\n' "$(id -u)" >&2
else
    run "${TMP}/e3" --medium "${ISO}" --emmc "${EMMC_RO}" && _bad "a read-only eMMC file was accepted (QEMU rejects it on the sd-bus)" || _ok "read-only eMMC file refused"
    grep -q 'is not writable' "${TMP}/e3.log" && _ok "...refused by the writability preflight, by name" || _bad "read-only eMMC refused, but not by the writability check: $(grep ERROR "${TMP}/e3.log" || true)"
fi
# 131584 = 128K + 512: keeps the user area 512-aligned, so ONLY the 128K rule can refuse it.
run "${TMP}/e4" --medium "${ISO}" --emmc "${EMMC}" --emmc-boot-size 131584 && _bad "boot size 131584 (not a 128K multiple) accepted" || _ok "boot size not a 128K multiple refused"
grep -q 'multiple of 128K' "${TMP}/e4.log" && _ok "...by the 128K rule, by name" || _bad "refused, but not by the 128K rule: $(grep ERROR "${TMP}/e4.log" || true)"
run "${TMP}/e5" --medium "${ISO}" --emmc "${EMMC}" --emmc-boot-size $(( 256 * 131072 )) && _bad "boot size > 32640K accepted" || _ok "boot size > 32640K refused"
run "${TMP}/e6" --medium "${ISO}" --emmc "${EMMC_TINY}" && _bad "eMMC smaller than its boot partitions accepted" || _ok "eMMC smaller than boot partitions refused"
run "${TMP}/e7" --medium "${ISO}" --emmc "${EMMC_NP2}" && _bad "1.5 GiB user area (<= 2 GiB, not a power of 2) accepted" || _ok "<= 2 GiB non-power-of-2 user area refused"
run "${TMP}/e8" --medium "${ISO}" --emmc "${EMMC}" --emmc-rpmb-size 100 && _bad "rpmb 100 accepted" || _ok "rpmb not a 128K multiple refused"
# a QEMU without the emmc device must be refused up front
mkdir -p "${TMP}/oldbin"; cat > "${TMP}/oldbin/qemu-system-aarch64" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-device" ] && [ "${2:-}" = "help" ]; then printf 'name "sd-card", bus sd-bus\n'; exit 0; fi
printf '%s\n' "$@" > "${STUB_ARGV_OUT:?}"; exit 0
STUB
cp "${BIN}/qemu-img" "${TMP}/oldbin/"; chmod +x "${TMP}/oldbin"/*
PATH="${TMP}/oldbin:${PATH}" STUB_ARGV_OUT="${TMP}/e9" STUB_QEMU_IMG_LOG="${TMP}/e9.qemu-img" bash "${LAUNCHER}" --platform frite --board la-frite --run-dir "${TMP}/run-old" --keep --medium "${ISO}" --emmc "${EMMC}" > "${TMP}/e9.log" 2>&1 \
    && _bad "a QEMU with only sd-card (the runner's 7.2) was allowed to attach an emmc" || _ok "a QEMU without the emmc device is refused"
grep -q "7.2" "${TMP}/e9.log" && _ok "...naming the runner image's QEMU 7.2" || _bad "refusal does not point at the runner's QEMU"

echo "== 5) --extlinux (phase B: the eMMC's own config, no medium, no .img) =="
cat > "${TMP}/emmc-extlinux.conf" <<EOF
DEFAULT frite
LABEL frite
    LINUX /Image
    FDT /dtb/${FDT}
    APPEND ${APPEND_BASE} root=PARTUUID=5ab0c0de-02
EOF
run "${TMP}/x1" --emmc "${EMMC}" --kernel "${KERNEL}" --extlinux "${TMP}/emmc-extlinux.conf" --gpu \
    && _ok "--emmc + --kernel + --extlinux (no --img, no --medium): exits 0" || { _bad "phase-B shape failed"; sed 's/^/    | /' "${TMP}/x1.log"; }
a="$(append_of "${TMP}/x1")"
case " ${a} " in *" root=PARTUUID=5ab0c0de-02 "*) _ok "phase B cmdline: root=PARTUUID from the eMMC's extlinux" ;; *) _bad "phase B cmdline lost root=PARTUUID: ${a}" ;; esac
case " ${a} " in *"root=/dev/vda2"*) _bad "phase B cmdline fell back to root=/dev/vda2" ;; *) _ok "no root=/dev/vda2 on the phase-B cmdline" ;; esac
case "${a}" in *" console=ttyAMA0,115200") _ok "phase B: console rewritten to ttyAMA0 (last)" ;; *) _bad "phase B console not rewritten" ;; esac
argv_has "${TMP}/x1" "-initrd" && _bad "an -initrd appeared with no INITRD line and no --initrd" || _ok "no -initrd without an INITRD line"
argv_has "${TMP}/x1" "virtio-blk-pci,drive=hd0" && _bad "overlay disk appeared without --img" || _ok "no overlay disk without --img"
[ -s "${TMP}/x1.qemu-img" ] && _bad "qemu-img was called with no --img" || _ok "qemu-img not called without --img"
argv_has "${TMP}/x1" "usb-storage,bus=xhci.0,drive=medium,removable=on" && _bad "the medium is still attached in phase B" || _ok "no medium attached (the eMMC boots alone)"
run "${TMP}/x2" --emmc "${EMMC}" --kernel "${KERNEL}" --initrd "${TREE}/initrd.img" --extlinux "${TMP}/emmc-extlinux.conf" \
    && [ "$(val_after "${TMP}/x2" -initrd)" = "${TREE}/initrd.img" ] && _ok "--initrd FILE passed as -initrd" || _bad "--initrd not honoured"
run "${TMP}/x3" --kernel "${KERNEL}" --extlinux "${TMP}/emmc-extlinux.conf" && _bad "--extlinux with no root disk at all booted" || _ok "no --img/--medium/--emmc: refused (nothing to boot)"
printf 'LABEL frite\n    LINUX /Image\n' > "${TMP}/no-append.conf"
run "${TMP}/x4" --emmc "${EMMC}" --kernel "${KERNEL}" --extlinux "${TMP}/no-append.conf" && _bad "an extlinux.conf without APPEND booted" || _ok "extlinux.conf without APPEND refused"

echo "== 6) --serial-sock =="
run "${TMP}/s1" --medium "${ISO}" --serial-sock "${TMP}/run-s/serial.sock" && _ok "--serial-sock exits 0" || _bad "--serial-sock failed"
grep -q "^socket,id=ser0,path=${TMP}/run-s/serial.sock,server=on,wait=off,logfile=" "${TMP}/s1" && _ok "serial on a unix socket chardev with logfile=console.log" || _bad "serial chardev wrong: $(grep '^socket' "${TMP}/s1" || true)"
argv_has "${TMP}/s1" "chardev:ser0" && _ok "-serial chardev:ser0" || _bad "-serial not on the chardev"
grep -q '^file:' "${TMP}/a1" && _ok "without --serial-sock the serial is still -serial file:" || _bad "default serial changed"

# A skip is legitimate ONLY as root; anywhere else it is lost coverage.
if [ "${SKIP}" -gt 0 ] && [ "$(id -u)" != 0 ]; then
    _bad "${SKIP} case(s) skipped while running as uid $(id -u): only root may skip the read-only eMMC case"
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (named above) =="
[ "${FAIL}" -eq 0 ]
