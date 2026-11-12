#!/bin/bash
# _x86-kernel-install.sh <jobs> <root-label> <uki-name> [kernel-tree] — compile and install
# the x86 kernel from an ALREADY-ASSERTED .config: bzImage + modules, modules_install,
# make install (the unversioned /boot/vmlinuz), the disk initramfs and the UNSIGNED UKI
# (/boot/<uki-name minus .efi>-unsigned.efi). Signing is NOT here: it happens on the host,
# outside the sysroot, so the key never enters the image (build-x86-host-stage4.sh's
# "Secure Boot" block, scripts/kernel-reconfig-x86.sh's strict signer).
#
# Two callers, ONE recipe, run inside the sysroot chroot:
#   * build-x86-host-stage4.sh's kernel phase, right after _x86-kernel-asserts.sh;
#   * scripts/kernel-reconfig-x86.sh apply, after the operator's menuconfig edit passed
#     the same asserts. It exports INSTALL_MOD_STRIP=1 (kbuild reads it from the
#     environment), so modules are debug-stripped BEFORE modules_install signs them —
#     the builder strips them later, in its clean step, instead.
# Moved here from the builder's heredoc, not copied: an edited kernel must be built,
# installed and wrapped exactly as a fresh one is, or the repackaged image is a
# different product than the build that preceded it.
set -eo pipefail
JOBS="${1:?usage: _x86-kernel-install.sh <jobs> <root-label> <uki-name> [kernel-tree]}"
ROOT_LABEL="${2:?usage: _x86-kernel-install.sh <jobs> <root-label> <uki-name> [kernel-tree]}"
UKI_NAME="${3:?usage: _x86-kernel-install.sh <jobs> <root-label> <uki-name> [kernel-tree]}"
cd "${4:-/usr/src/linux}"
make -j${JOBS} bzImage modules
make modules_install
# 'make install' copies bzImage/System.map/config to /boot FIRST, then falls
# through arch/x86/boot/install.sh's bootloader probe (no installkernel(8) in
# the image, no lilo) and prints a harmless "Cannot find LILO." as its last
# gasp. Filter that one cosmetic line: the shell is bash -eo pipefail, so a
# REAL make-install failure still aborts via the pipeline status; the '|| true'
# only absorbs grep's status-1 when every line was filtered.
make install 2>&1 | { grep -vF 'Cannot find LILO.' || true; }
# Disk-boot initramfs (NOT the live dmsquash-live one): a normal, generic
# (--no-hostonly) dracut image so the persistent ext4 GPT root mounts on real
# hardware AND in VMs. Named initramfs-<kver>.img to match the grub.cfg the .img
# builder writes. The live ISO builds its own initramfs-live.img separately.
KVER="$(make -s kernelrelease 2>/dev/null || ls /lib/modules | sort -V | tail -1)"
if command -v dracut >/dev/null; then
    # --add crypt: the LUKS2 root the installer can lay down is unlocked
    # from /etc/crypttab + the rd.luks cmdline in this initramfs. Harmless on a
    # plaintext-root image (no crypttab → no unlock attempted). See dracut.conf.d.
    dracut --force --no-hostonly \
        --add crypt \
        --add-drivers "ext4 vfat nvme ahci sd_mod usb_storage uas virtio_blk virtio_pci virtio_net dm_crypt" \
        --kver "${KVER}" "/boot/initramfs-${KVER}.img" \
        || echo "[build-x86] WARN: dracut (disk initramfs) failed; the .img may not boot"
else
    echo "[build-x86] WARN: dracut not installed; no disk initramfs (sys-kernel/dracut should be in packages.list)"
fi
# Unified Kernel Image (UKI) for Secure Boot: bundles kernel+initramfs+cmdline
# as a single signed PE/EFI binary. Requires dracut[uefi] + systemd-utils[boot]
# (owns the sd-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub) + CONFIG_EFI_STUB.
# The host-side signing step below signs it with the org key; build_img() installs
# it to the ESP. NOTE: the output path expands HOST-side (unquoted heredoc) from
# UKI_NAME so it matches the sign step's UKI_UNSIGNED for BOTH the branded
# (hugmesh-unsigned.efi) and UNAFFILIATED (gentoo-unsigned.efi) names.
# --kernel-image /boot/vmlinuz is REQUIRED: 'make install' above ran with no
# installkernel(8) (see the LILO note), so arch/x86/boot/install.sh wrote an
# UNVERSIONED /boot/vmlinuz — dracut's determine_kernel_image() probes only
# versioned paths (/lib/modules/<kver>/vmlinuz, /boot/vmlinuz-<kver>, ...) and
# dies "Can't find a kernel image" without the flag; the WARN below would then
# swallow that and the SB chain would silently degrade to GRUB+vmlinuz
# (live-proven on the real desktop sysroot: exact invocation failed without
# the flag, produced a valid PE32+ UKI with it).
# (This block used to live inside the builder's UNQUOTED <<CHROOT heredoc, where a
# backtick even in a comment was command substitution; the builder's OWN heredoc keeps
# that rule — see its NB note — but this file is a plain script.)
#
# root= MUST be baked in here. GRUB's 'chainloader' hands a UKI NO external cmdline,
# so unlike the GRUB 'linux' menuentry — which appends root=PARTUUID=... at build_img
# time — the UKI is only bootable if it carries root= itself. GRUB_CMDLINE_LINUX is the
# APPEND half by design and never contains one, so the UKI shipped without it: the
# kernel started and dracut then died "FATAL: No or empty root= argument" and dropped to
# a debug shell. That is every x86 image of the 2026-08-07 session (matrix triage
# 2026-08-13); it was masked until now by a separate GRUB defect that stopped the UKI
# entry from ever being reached.
#
# LABEL=, not PARTUUID=: the partition UUIDs are minted by 'parted' inside build_img()
# and only read back afterwards (see mkpart/_fld root_uuid), which happens long AFTER
# this UKI is built AND signed — so a PARTUUID is simply not knowable here, and
# rewriting .cmdline post-signing would invalidate the signature. ${ROOT_LABEL} is a
# build-time constant that build_img passes to 'mkfs.ext4 -L', so it is stable and
# known now. dracut already carries the ext4 driver (--add-drivers below) to mount it.
CMDLINE="root=LABEL=${ROOT_LABEL} ro $(. /etc/default/grub 2>/dev/null; printf '%s' "${GRUB_CMDLINE_LINUX:-lsm=lockdown,yama,selinux,bpf lockdown=integrity selinux=1 audit=1}")"
# Drained, never `grep -q`: this is bash -o pipefail, and grep -q exiting on the first
# match SIGPIPEs dracut --help, which turns a FOUND --uefi into a failed pipeline and
# skips the UKI without a word (the same coin flip every other guard here was fixed for).
if command -v dracut >/dev/null && dracut --help 2>/dev/null | grep -- '--uefi' >/dev/null; then
    dracut --force --no-hostonly --uefi \
        --add crypt \
        --add-drivers "ext4 vfat nvme ahci sd_mod usb_storage uas virtio_blk virtio_pci virtio_net dm_crypt" \
        --kernel-cmdline "${CMDLINE}" \
        --kernel-image /boot/vmlinuz \
        --kver "${KVER}" "/boot/${UKI_NAME%.efi}-unsigned.efi" \
        && echo "[build-x86] UKI built: /boot/${UKI_NAME%.efi}-unsigned.efi" \
        || echo "[build-x86] WARN: dracut --uefi failed; UKI not built (secure boot chain needs manual rebuild)"
else
    echo "[build-x86] INFO: dracut --uefi not available; UKI skipped (add 'uefi' USE to sys-kernel/dracut)"
fi
