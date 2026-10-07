# specs-jetson/boot — Orin boot flow + DTB notes

## How an Orin boots (vs the RPi5 / Frite)

| | RPi5 | Frite (Amlogic GXL) | **Jetson Orin** |
|---|---|---|---|
| Firmware | Broadcom bootrom + `config.txt` | u-boot in SPI/SD (needs FIP blobs) | **NVIDIA UEFI (edk2-nvidia) in QSPI-NOR** |
| Boot config | `config.txt`/`cmdline.txt` on FAT | `/extlinux/extlinux.conf` | **`/boot/extlinux/extlinux.conf`** (L4TLauncher UEFI app) |
| We build the bootloader? | no (firmware pkg) | vendored u-boot.bin | **no — QSPI firmware is out-of-band** (`tegraflash`, recovery mode; see `../installer/TEGRAFLASH.md`) |

The practical upshot: the image this builder produces is a **rootfs with
`/boot/extlinux/extlinux.conf`** (rendered from `extlinux.conf.tmpl` +
`cmdline.base`) on an ext4 partition labeled `JETSON_ROOT`, written to
microSD or NVMe. A devkit whose QSPI firmware is current (JetPack 5/6 era,
UEFI boot) will distro-boot it directly. No u-boot phase exists.

## Orin Nano Developer Kit DTB (mainline)

The mainline kernel ships the devkit DT at:

```
arch/arm64/boot/dts/nvidia/tegra234-p3768-0000+p3767-0005.dtb
```

* `p3768-0000` — the Orin Nano Developer Kit carrier board
* `p3767-0005` — the Orin Nano (8 GB, no-eMMC devkit) module

Other Orin modules on the same carrier. Three have a `--board` value (all marked UNTESTED in the builder); the Orin Nano 8 GB p3767-0003 module is reachable only through `--dtb`:

| Module | `--board` | DTB |
|---|---|---|
| Orin NX 16 GB (p3767-0000) | `orin-nx-16gb` | `nvidia/tegra234-p3768-0000+p3767-0000.dtb` |
| Orin NX 8 GB (p3767-0001) | `orin-nx-8gb` | `nvidia/tegra234-p3768-0000+p3767-0001.dtb` |
| Orin Nano 8 GB (p3767-0003) | none (use `--dtb`) | `nvidia/tegra234-p3768-0000+p3767-0003.dtb` |
| Orin Nano 4 GB (p3767-0004) | `orin-nano-4gb` | `nvidia/tegra234-p3768-0000+p3767-0004.dtb` |

The builder copies the whole `nvidia/` DTB dir into `/boot/dtb/nvidia/` and the
extlinux `FDT` line selects the board file — the SAME kernel-owns-the-DTB
policy as the Frite (never boot the firmware's stale DT against a different
kernel).

## Console

The Orin's primary serial console is the Tegra Combined UART, `ttyTCU0`
(`cmdline.base` sets it). It is exposed on the devkit's debug header and over
the USB-C flashing port.
