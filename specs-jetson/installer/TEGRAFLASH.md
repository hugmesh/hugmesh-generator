# specs-jetson/installer — flashing an Orin (tegraflash is OUT-OF-BAND)

Unlike the RPi5 (`dd` the .img to SD) and the x86 hosts (installer ISO), a
Jetson has TWO distinct things that can need flashing, and only ONE of them is
this repo's artifact:

## 1. The ROOTFS (this repo's artifact) — normal path, no tegraflash

On any Orin devkit whose QSPI firmware is already current (shipped with
JetPack 5/6-era UEFI — true for every Orin Nano Super devkit), the UEFI
distro-boots our image directly:

```sh
# microSD or NVMe-over-USB adapter on any Linux box:
xz -dc hugmesh-jetson-orin-nano-arm64-edge_ai-test-<ts>.img.xz | \
    sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
# or:  sudo scripts/flash-disk.sh --arch arm64 --role edge_ai /dev/sdX
```

Insert the card / NVMe, power on: UEFI's L4TLauncher finds
`/boot/extlinux/extlinux.conf` on the `JETSON_ROOT` partition and boots it.
First boot then runs the SAME KEYS-USB provisioning as every other node image.

## 2. The QSPI FIRMWARE + the L4T/BSP stack — recovery-mode tegraflash (out-of-band)

Required only when (a) the devkit's QSPI firmware predates UEFI distro-boot, or
(b) you are moving the node to the `--kernel-flavor l4t` stack (CUDA). This is
NVIDIA's `tegraflash`/`l4t_initrd_flash` flow and is deliberately **documented,
not automated** here (EULA-gated downloads; needs the physical board in
recovery mode):

1. Download "Jetson Linux" (L4T) + the sample rootfs for your JetPack release
   from developer.nvidia.com; unpack to `Linux_for_Tegra/`.
2. Put the devkit in FORCE RECOVERY (jumper FC REC → GND, or hold the recovery
   button while powering on) and connect the USB-C port to the host.
3. Update QSPI only (keeps our rootfs on SD/NVMe):
   ```sh
   sudo ./flash.sh --no-systemimg -c bootloader/generic/cfg/flash_t234_qspi.xml \
        jetson-orin-nano-devkit internal
   ```
4. (L4T flavor, future) Full BSP flash to NVMe:
   ```sh
   sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
        -c tools/kernel_flash/flash_l4t_external.xml jetson-orin-nano-devkit nvme0n1p1
   ```
   then layer the HugMesh stage4 (`*.stage4.tar.xz`) over the L4T rootfs —
   the provisioning/mesh plumbing is arch- and kernel-flavor-agnostic.

Until step 4 is hardware-validated, `build-jetson-stage4.sh --kernel-flavor
l4t` exits with a hard error pointing here.
