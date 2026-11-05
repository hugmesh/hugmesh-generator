#!/usr/bin/env bash
# test-frite-kernel-emulation-symbols.sh — the Frite kernel fragment carries, and
# Kconfig KEEPS, the symbols that let the Frite installer be proven in QEMU.
#
# THE DEFECT THIS EXISTS TO STOP (mapped 2026-11-04). No Frite image had ever been
# booted anywhere: the fragment (specs-frite/kernel/hardened-desktop.config, applied
# on top of the generic arm64 defconfig by build-frite-stage4.sh) enabled the Amlogic
# eMMC host, meson DRM and USB, and NOTHING an emulator can present. Resolved against
# linux-7.3.0's arm64 defconfig, the shipped fragment left
#     # CONFIG_MMC_SDHCI_PCI is not set      -> QEMU's `emmc` (behind sdhci-pci) invisible
#     # CONFIG_DRM_VIRTIO_GPU is not set     -> no KMS head: no greeter, no screendump
#     # CONFIG_VIRTIO_INPUT is not set       -> no keyboard to type the login
# so "install the Frite image onto the eMMC and boot it to the greeter" could not be
# exercised without the board. The installed PLAINTEXT root boots with NO initramfs
# (root=PARTUUID on the eMMC), which is why the eMMC host driver must be =y, never =m.
#
# TWO TIERS, because a fragment line is a REQUEST and olddefconfig grants it only when
# every dependency is on — and prunes it with no message otherwise:
#   static   (always; bash + grep + sed, busybox-clean)
#     1) each emulation symbol is requested =y, exactly once, with no contradicting
#        `=m` / `is not set` line anywhere in the fragment;
#     2) the derivation inputs of USB_XHCI_PCI (a promptless `default y` that CANNOT
#        be requested in a fragment) are intact: USB_XHCI_HCD=y requested, and no
#        `is not set` for PCI / USB_PCI / USB_XHCI_HCD / USB_XHCI_PCI / USB_STORAGE;
#     3) no `is not set` for a dependency of the emulation block (MMC, MMC_SDHCI, DRM,
#        VIRTIO, VIRTIO_MENU, INPUT, PCI);
#     4) build-frite-stage4.sh really consumes THIS fragment through merge_config.sh
#        (the consumer is read, never edited here).
#   resolution (when a clean kernel SOURCE tree is at hand: $1, $KSRC, or the newest
#        /usr/src/linux-* with arch/arm64/configs/defconfig; needs gcc make flex bison)
#     5) arm64 defconfig + merge_config.sh -m + olddefconfig — the builder's exact
#        sequence — leaves every emulation symbol =y, plus the derived
#        USB_XHCI_PCI=y and DRM_VIRTIO_GPU_KMS=y;
#     6) NEGATIVE CONTROL: the same resolve with `# CONFIG_PCI is not set` layered on
#        top must DROP MMC_SDHCI_PCI / VIRTIO_PCI / USB_XHCI_PCI — proving this tier
#        can see a prune at all (a resolve that cannot fail proves nothing);
#     7) every other `CONFIG_X=y` the fragment requests that did NOT survive is
#        printed as a NOTE (informational: those belong to other guards).
#   Without a tree the resolution tier prints a loud NOTE ... SKIPPED and the static
#   tier's verdict stands (the tests/build-arm-payload-gates.sh shape). CI images
#   carry no kernel tree; run this on a Gentoo host for tier 2.
#
# No network, no root, no docker, no cross-compiler: Kconfig resolution is host-native.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
FRAG="${FRITE_FRAG:-${REPO}/specs-frite/kernel/hardened-desktop.config}"
BUILDER="${REPO}/build-frite-stage4.sh"

[ -f "${FRAG}" ] || { echo "  FAIL fragment ${FRAG} missing"; exit 1; }
[ -f "${BUILDER}" ] || { echo "  FAIL builder ${BUILDER} missing"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# The emulation block: what QEMU -M virt needs the Frite kernel to drive.
#   MMC_SDHCI_PCI  QEMU `emmc` behind `sdhci-pci` (the eMMC install target)
#   DRM_VIRTIO_GPU virtio-gpu-pci KMS head (greeter + QMP screendump)
#   VIRTIO_INPUT   virtio keyboard/tablet (typing the login)
#   VIRTIO_PCI     transport for the two above
#   PCI, MMC_SDHCI dependencies of the three *_PCI symbols (defconfig sets them;
#                  pinned so a --defconfig override cannot prune the block)
EMU_SYMBOLS=(
  CONFIG_MMC_SDHCI_PCI
  CONFIG_DRM_VIRTIO_GPU
  CONFIG_VIRTIO_INPUT
  CONFIG_VIRTIO_PCI
  CONFIG_PCI
  CONFIG_MMC_SDHCI
)
# Derived after olddefconfig (promptless / default y on the symbols above).
DERIVED_SYMBOLS=(
  CONFIG_USB_XHCI_PCI
  CONFIG_DRM_VIRTIO_GPU_KMS
)
# Must never be negated in the fragment: inputs of USB_XHCI_PCI and of the block.
NEVER_UNSET=(
  CONFIG_PCI
  CONFIG_USB_PCI
  CONFIG_USB_XHCI_HCD
  CONFIG_USB_XHCI_PCI
  CONFIG_USB_STORAGE
  CONFIG_MMC
  CONFIG_MMC_SDHCI
  CONFIG_DRM
  CONFIG_VIRTIO
  CONFIG_VIRTIO_MENU
  CONFIG_INPUT
)
# Requested =y lines the USB medium path needs (the installer boots from usb-storage
# behind qemu-xhci; on the board, from the real USB stick).
USB_INPUTS=(
  CONFIG_USB_XHCI_HCD
  CONFIG_USB_STORAGE
)

# count_exact <literal-line>  -> number of lines equal to it (0 is not an error)
count_exact(){ local n; n="$(grep -cxF -- "$1" "${FRAG}")" || n=0; printf '%s\n' "${n}"; }
# count_re <ERE>              -> number of lines matching it
count_re(){ local n; n="$(grep -cE -- "$1" "${FRAG}")" || n=0; printf '%s\n' "${n}"; }

echo "== Frite kernel fragment: QEMU emulation symbols (eMMC target, KMS head, input) =="

echo "-- 1) each emulation symbol is requested =y, once, uncontradicted --"
for s in "${EMU_SYMBOLS[@]}"; do
    n_y="$(count_exact "${s}=y")"
    n_m="$(count_exact "${s}=m")"
    n_unset="$(count_re "^# ${s} is not set[[:space:]]*$")"
    n_other="$(count_re "^${s}=")"      # any assignment, including =y
    if [ "${n_y}" -eq 1 ] && [ "${n_m}" -eq 0 ] && [ "${n_unset}" -eq 0 ] && [ "${n_other}" -eq 1 ]; then
        ok "${s}=y requested exactly once (no =m / is-not-set / second assignment)"
    else
        bad "${s}: =y lines ${n_y}, =m lines ${n_m}, 'is not set' lines ${n_unset}, assignments ${n_other} (want 1/0/0/1)"
    fi
done

echo "-- 2) USB medium path and USB_XHCI_PCI derivation inputs are intact --"
for s in "${USB_INPUTS[@]}"; do
    n_y="$(count_exact "${s}=y")"
    n_other="$(count_re "^${s}=")"
    if [ "${n_y}" -eq 1 ] && [ "${n_other}" -eq 1 ]; then
        ok "${s}=y requested exactly once"
    else
        bad "${s}: =y lines ${n_y}, assignments ${n_other} (want 1/1)"
    fi
done
for s in "${NEVER_UNSET[@]}"; do
    n_unset="$(count_re "^# ${s} is not set[[:space:]]*$")"
    n_m="$(count_exact "${s}=m")"
    if [ "${n_unset}" -eq 0 ] && [ "${n_m}" -eq 0 ]; then
        ok "${s} is never negated or demoted to =m"
    else
        bad "${s}: 'is not set' lines ${n_unset}, =m lines ${n_m} — would prune the emulation block or USB_XHCI_PCI silently"
    fi
done
# USB_XHCI_PCI is promptless: a `CONFIG_USB_XHCI_PCI=y` request would be accepted
# today and silently ignored the day its default changes. It must stay DERIVED.
if [ "$(count_re '^CONFIG_USB_XHCI_PCI=')" -eq 0 ]; then
    ok "CONFIG_USB_XHCI_PCI is left derived (not requested: promptless default y)"
else
    bad "CONFIG_USB_XHCI_PCI is requested in the fragment; it is promptless — guard its inputs, do not request it"
fi

echo "-- 3) the builder consumes this fragment through merge_config.sh --"
if grep -E 'merge_config\.sh -m \.config "\$\{SPECS_DIR\}/kernel/hardened-desktop\.config"' "${BUILDER}" >/dev/null; then
    ok "build-frite-stage4.sh merges \${SPECS_DIR}/kernel/hardened-desktop.config with merge_config.sh -m"
else
    bad "build-frite-stage4.sh no longer merges kernel/hardened-desktop.config via merge_config.sh — this fragment would be dead"
fi
if grep -E '^SPECS_DIR=.*specs-frite' "${BUILDER}" >/dev/null \
   || grep -E 'SPECS_DIR="?\$\{?[A-Z_]*\}?/specs-frite"?' "${BUILDER}" >/dev/null; then
    ok "SPECS_DIR in build-frite-stage4.sh points at specs-frite"
else
    bad "cannot find SPECS_DIR=.../specs-frite in build-frite-stage4.sh (fragment path may have moved)"
fi

echo "-- 4) resolution: defconfig + merge_config -m + olddefconfig on a real tree --"
find_tree(){
    local cand
    if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return; fi
    if [ -n "${KSRC:-}" ]; then printf '%s\n' "${KSRC}"; return; fi
    for cand in $(ls -d /usr/src/linux-* 2>/dev/null | sort -V | tac); do
        [ -f "${cand}/arch/arm64/configs/defconfig" ] || continue
        [ -e "${cand}/.config" ] && continue
        [ -d "${cand}/include/config" ] && continue
        printf '%s\n' "${cand}"; return
    done
}
TREE="$(find_tree "${1:-}")"
tree_usable=true
if [ -z "${TREE}" ] || [ "${TREE}" = none ]; then
    tree_usable=false
elif [ ! -f "${TREE}/arch/arm64/configs/defconfig" ] || [ ! -f "${TREE}/scripts/kconfig/merge_config.sh" ]; then
    echo "  NOTE ${TREE} has no arch/arm64/configs/defconfig or scripts/kconfig/merge_config.sh"; tree_usable=false
elif [ -e "${TREE}/.config" ] || [ -d "${TREE}/include/config" ]; then
    echo "  NOTE ${TREE} was configured in place (.config/include/config present); Kbuild refuses O= against it"; tree_usable=false
else
    for t in gcc make flex bison; do
        command -v "${t}" >/dev/null 2>&1 || { echo "  NOTE ${t} not installed (Kconfig needs it)"; tree_usable=false; }
    done
fi

if ! ${tree_usable}; then
    echo "  NOTE no clean arm64-capable kernel source tree — resolution tier SKIPPED (static tier above still ran; pass a tree as \$1 or KSRC=)"
else
    echo "  tree: ${TREE}"
    WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/frite-emu-resolve.XXXXXX")" || { bad "mktemp failed"; WORK=""; }
    [ -n "${WORK}" ] && trap 'rm -rf "${WORK}"' EXIT
    # resolve <name> [extra fragment...]  -> ${WORK}/<name>/.config, 0 on success
    resolve(){
        local name="$1"; shift
        local out="${WORK}/${name}"
        mkdir -p "${out}"
        make -s -C "${TREE}" ARCH=arm64 O="${out}" defconfig >"${out}/defconfig.log" 2>&1 \
            || { bad "${name}: make ARCH=arm64 defconfig failed (see ${out}/defconfig.log)"; return 1; }
        ( cd "${out}" && ARCH=arm64 bash "${TREE}/scripts/kconfig/merge_config.sh" -m -O "${out}" "${out}/.config" "${FRAG}" "$@" ) >"${out}/merge.log" 2>&1 \
            || { bad "${name}: merge_config.sh failed (see ${out}/merge.log)"; return 1; }
        make -s -C "${TREE}" ARCH=arm64 O="${out}" olddefconfig >"${out}/olddefconfig.log" 2>&1 \
            || { bad "${name}: make olddefconfig failed (see ${out}/olddefconfig.log)"; return 1; }
    }
    val(){ sed -n "s/^$2=\(.*\)\$/\1/p" "${WORK}/$1/.config"; }

    if [ -n "${WORK}" ] && resolve shipped; then
        for s in "${EMU_SYMBOLS[@]}"; do
            [ "$(val shipped "${s}")" = y ] && ok "resolved: ${s}=y survives olddefconfig" \
                || bad "resolved: ${s} did NOT survive olddefconfig (got '$(val shipped "${s}")') — the builder would ship a kernel without it, silently"
        done
        for s in "${DERIVED_SYMBOLS[@]}"; do
            [ "$(val shipped "${s}")" = y ] && ok "resolved: derived ${s}=y" \
                || bad "resolved: derived ${s} is '$(val shipped "${s}")', not y"
        done
        # 7) informational: anything else the fragment asked for that Kconfig refused.
        lost=0
        while IFS= read -r line; do
            case "${line}" in CONFIG_*=y) ;; *) continue ;; esac
            if ! grep -qxF -- "${line}" "${WORK}/shipped/.config"; then
                sym="${line%%=*}"
                echo "  NOTE requested ${line} resolved to '$(val shipped "${sym}")' on ${TREE##*/} (not this guard's symbol; see its own guard)"
                lost=$((lost+1))
            fi
        done < "${FRAG}"
        [ "${lost}" -eq 0 ] && echo "  NOTE every =y line of the fragment survived on ${TREE##*/}"
    fi

    # 6) negative control: the tier must be able to SEE a prune.
    if [ -n "${WORK}" ]; then
        printf '# CONFIG_PCI is not set\n' > "${WORK}/no-pci.config"
        if resolve nopci "${WORK}/no-pci.config"; then
            dropped=0
            for s in CONFIG_MMC_SDHCI_PCI CONFIG_VIRTIO_PCI CONFIG_USB_XHCI_PCI; do
                [ "$(val nopci "${s}")" != y ] && dropped=$((dropped+1))
            done
            [ "${dropped}" -eq 3 ] && ok "control: with PCI off, MMC_SDHCI_PCI / VIRTIO_PCI / USB_XHCI_PCI are all dropped (this tier can see a prune)" \
                || bad "control: with PCI off only ${dropped}/3 PCI symbols were dropped — this resolve cannot distinguish a prune from a keep"
        fi
    fi
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
