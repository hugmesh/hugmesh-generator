# specs-jetson/installer — flashing an Orin (tegraflash is OUT-OF-BAND)

The RPi5 takes a `dd` of the .img to SD, and the x86 hosts take an installer
ISO. A Jetson has TWO things that can need flashing, and only ONE of them is
this repo's artifact:

## 1. The ROOTFS (this repo's artifact) — normal path, no tegraflash

On an Orin devkit whose QSPI firmware is already current (JetPack 5/6-era UEFI,
true for every Orin Nano Super devkit), the UEFI distro-boots our image directly:

```sh
# microSD or NVMe-over-USB adapter on any Linux box:
xz -dc hugmesh-jetson-orin-nano-arm64-edge-ai-test-<ts>.img.xz | \
    sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
# or:  sudo scripts/flash-disk.sh --arch arm64 --role edge-ai /dev/sdX
```

The `.img.xz` exists only when you built with `--compress`. Without it, write the plain `.img` with the same `dd` command.

Insert the card or NVMe and power on. UEFI's L4TLauncher finds
`/boot/extlinux/extlinux.conf` on the `JETSON_ROOT` partition and boots it.
First boot runs the SAME KEYS-USB provisioning as every other node image.

## 2. The QSPI FIRMWARE + the L4T/BSP stack — recovery-mode tegraflash (out-of-band)

You need this only when (a) the devkit's QSPI firmware predates UEFI
distro-boot, or (b) you are moving the node to the `--kernel-flavor l4t` stack
(CUDA). This is NVIDIA's `tegraflash`/`l4t_initrd_flash` flow. It is
**documented, not automated** here: the downloads are EULA-gated, and the
physical board must be in recovery mode.

1. Download "Jetson Linux" (L4T) and the sample rootfs for your JetPack release
   from developer.nvidia.com. Unpack to `Linux_for_Tegra/`.
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
   Then layer the HugMesh stage4 (`*.stage4.tar.xz`) over the L4T rootfs. The
   provisioning and mesh plumbing does not depend on arch or kernel flavor.

Until step 4 is validated on hardware, `build-jetson-stage4.sh --kernel-flavor
l4t` exits with a hard error pointing here.
