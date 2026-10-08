# specs-orangepi4-lts — Orange Pi 4 LTS (Rockchip RK3399, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> 4 LTS has ever booted an image produced by this repo. We **checked every
> RK3399 fact below (DTB name, U-Boot defconfig, kernel Kconfig symbols, driver
> choices) by fetching the upstream source tree it comes from**: the Linux DTS/
> DTSI and Kconfig files, U-Boot's `configs/` directory, and ARM Trusted
> Firmware's `plat/` tree. We did not infer them from secondary claims. So the
> *symbol spellings and node facts* are reliable, but the port is not verified
> on hardware. There is no RK3399 hardware here, and this sandbox may also lack
> the network access for a real cross-emerge. Treat it like `specs-jetson/`,
> which is also unvalidated. It builds and is internally consistent
> (`--print-plan` is clean across the whole flag matrix), but **do not trust it
> to boot** until a real board confirms it end to end.

## How this differs from the Orange Pi 5 template (read this before trusting any inherited claim)

This tree was forked from `specs-orangepi5/` (RK3588) because that is the repo's
DESKTOP-CAPABLE template. **The taxonomy carried over correctly; almost none of
the hardware facts did.** RK3399 and RK3588 are different SoC generations, and
they differ in nearly every subsystem that decides whether the board boots at
all. The following were all WRONG when inherited verbatim and have been
corrected. Do not "restore" any of them:

| Subsystem | Orange Pi 5 / RK3588 (inherited) | Orange Pi 4 LTS / RK3399 (correct) |
|---|---|---|
| GPU kernel driver | `DRM_PANTHOR` (Mali-G610, Valhall/CSF) | **`DRM_PANFROST`** (Mali-T860, Midgard) |
| Display controller | `ROCKCHIP_VOP2` + `DW_HDMI_QP` | **`ROCKCHIP_VOP`** (v1) + **`ROCKCHIP_DW_HDMI`** |
| eMMC host | `MMC_SDHCI_OF_DWCMSHC` | **`MMC_SDHCI_OF_ARASAN`** |
| SD / SDIO host | (same DWCMSHC) | **`MMC_DW` + `MMC_DW_ROCKCHIP`** |
| Ethernet | `R8169` (PCIe Realtek RTL8125) | **`STMMAC_ETH` + `STMMAC_PLATFORM` + `DWMAC_ROCKCHIP`** (integrated GMAC) |
| PCIe controller | `PCIE_ROCKCHIP_DW_HOST` (DesignWare) | **`PCIE_ROCKCHIP_HOST`** (non-DesignWare) |
| NVMe / M.2 | M.2 slot, NVMe root supported | **no M.2 slot at all** — NVMe removed |
| Boot blobs | Rockchip rkbin DDR blob + rkbin/fork BL31 **required** | **BLOB-FREE** — mainline U-Boot TPL + mainline TF-A BL31 |
| Crypto engine | `CRYPTO_DEV_ROCKCHIP2`, "accelerates LUKS via xts(aes)" | **deliberately not enabled** — see below |
| WiFi | AP6275P, mainline support ROUGH | **in-DTB brcmfmac, enabled upstream** |
| RAM | 4/8/16/32GB SKUs | **4GB LPDDR4, single SKU** |

Any one of the inherited GPU, eMMC/SD or ethernet symbols would have been fatal
on its own: no display, no bootable storage, or no network.

The crypto-engine case needs a longer note, because the inherited reason was
*specifically* about LUKS. The RK3588 fork enabled `CRYPTO_DEV_ROCKCHIP2`
because it registers `xts(aes)`, "exactly LUKS's cipher". The v1 driver that
would apply to RK3399, `CRYPTO_DEV_ROCKCHIP`, says in its own upstream Kconfig
help only "cbc/ecb chainmode, and aes/des/des3_ede cipher mode". It has **no
xts**, so it cannot accelerate LUKS2 at all. Enabling it would buy nothing and
add attack surface. FDE relies only on the ARMv8 Crypto Extensions
(`CRYPTO_AES_ARM64_CE_BLK`).

## What this adds

A lean, hardened LXDE **light desktop** client image for the Orange Pi 4 LTS. It
is a **client device**, like Frite, not a K8s cluster node. It reuses the SAME
aarch64 cross toolchain and shared `specs/` mesh/provisioning/sshd plumbing as
every other client image (Frite/RPi5-desktop/Jetson-desktop/Orange Pi 5):
headscale/tailscale mesh join, hardened key-only sshd, and KEYS-USB first-boot
provisioning. It supports `--standalone` (local user, no mesh, build-time
password) and `--encrypt-root` (LUKS2 full-disk encryption) from the start.

```sh
./build-orangepi4-lts-stage4.sh                                    # both live+installer
./build-orangepi4-lts-stage4.sh --flavor live                      # live image only
./build-orangepi4-lts-stage4.sh --standalone --local-user alice    # local-only desktop, LUKS2 FDE on install
./build-orangepi4-lts-stage4.sh --encrypt-root --print-plan        # dry-run plan (no root)
```

## Why this is a DESKTOP platform (unlike the Zero 2W / Zero 3 / 3 LTS appliances)

The Zero 2, Zero 2W, Zero 3 and 3 LTS are headless appliances. That was never a
house style. Each had a specific reason (H616/H618: no working mainline display
pipeline; H6/3 LTS: a deliberate scope call on borrowed wiring). **RK3399 is in
neither situation**, and the upstream device tree says so:

- `&gpu` is **enabled** and declares `compatible = "rockchip,rk3399-mali",
  "arm,mali-t860"`. That is a Midgard T860, which the in-tree `panfrost` DRM
  driver and Mesa's `panfrost` Gallium driver both support.
- `&hdmi` is **enabled** (`"rockchip,rk3399-dw-hdmi"`).
- **Both** display controllers are enabled: `&vopb`
  (`"rockchip,rk3399-vop-big"`) and `&vopl` (`"rockchip,rk3399-vop-lit"`).

So this board gets the FULL light-desktop taxonomy: `ROLE="desktop"`,
`packages-desktop.list`, `hardened-desktop.config`, LXDE + lightdm. That matches
`build-orangepi5-stage4.sh`, not the appliance shape.

## Single-board platform (no `--board` axis)

Unlike Orange Pi 5, this platform accepts exactly one `--board` value,
`orange-pi-4-lts`. Mainline has exactly **one** Orange Pi RK3399 device tree and
**one** U-Boot defconfig for the whole Orange Pi 4 / 4B / 4 LTS family. A
multi-board axis would map every choice to the same cpu/dtb/uboot values: a fake
axis that implies a hardware distinction the build cannot express. `matrix.tsv`
models this as it does the other single-board platforms, with a literal `-` in
the board column.

The variants do differ, but the build cannot see it. The LTS adds 16GB onboard
eMMC and SPI-NOR flash over the base Orange Pi 4, and the 4B adds an RK1808 AI
accelerator. The eMMC-vs-SD choice is an **install-time** target, which
`install-orangepi4-lts.sh` already handles by device path.

| Board | Chip | Notable I/O | Status |
|---|---|---|---|
| `orange-pi-4-lts` (**only value**) | RK3399 | 2x Cortex-A72 + 4x Cortex-A53, Mali-T860 MP4, 4GB LPDDR4, 16GB eMMC + microSD, gigabit ethernet (SoC GMAC), onboard WiFi/BT, HDMI | EXPERIMENTAL |

## Boot chain (researched — every leg fetched from upstream)

```
Rockchip BootROM
  -> U-Boot TPL      (mainline NATIVE DRAM init: drivers/ram/rockchip/
                      sdram_rk3399.c — CONFIRMED present upstream.
                      NO rkbin DDR blob, unlike RK3588)
  -> U-Boot SPL      (loads BL31; the defconfig sets
                      CONFIG_SPL_ATF_NO_PLATFORM_PARAM=y)
  -> TF-A BL31       (MAINLINE ARM Trusted Firmware, plat/rockchip/rk3399 —
                      CONFIRMED present upstream. Open source, NOT a blob)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD / eMMC / USB) for /extlinux/extlinux.conf — the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh
                  use, NOT RPi5's config.txt model and NOT UEFI/GRUB
```

**This board's whole boot chain is BLOB-FREE.** That is the biggest practical
difference from the RK3588 boards. The Orange Pi 5 port needs Rockchip's
proprietary rkbin DDR-init blob and a non-mainline TF-A. This one needs neither.

Confirmed upstream artifacts:

- U-Boot defconfig: **`orangepi-rk3399_defconfig`** exists (HTTP 200). It sets
  `CONFIG_DEFAULT_DEVICE_TREE="rockchip/rk3399-orangepi"`,
  `CONFIG_ROCKCHIP_RK3399=y`, `CONFIG_TPL=y` and
  `CONFIG_SPL_ATF_NO_PLATFORM_PARAM=y`. There is **no**
  `orangepi_4_lts_defconfig` and no `orangepi4-rk3399_defconfig` (both HTTP 404).
- Kernel DTB: **`rockchip/rk3399-orangepi.dtb`**. The arm64 rockchip `Makefile`
  has exactly one line matching both `rk3399` and `orangepi`:
  `dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3399-orangepi.dtb`. There is **no**
  `rk3399-orangepi-4-lts.dtb`.
- Board DTS model string: `"Orange Pi RK3399 Board"`, compatible
  `"xunlong,rk3399-orangepi", "rockchip,rk3399"`.

**Consequence:** the image boots the *shared* Orange Pi RK3399 device tree. Any
LTS-only peripheral that the base Orange Pi 4 device tree does not describe is
not configured by this image.

This builder does **not** compile U-Boot itself. The blob-free chain would make
that possible, but it is not implemented. `--uboot-url` vendors a prebuilt image;
without it the builder warns and leaves the slot empty.

## Research findings by topic (confidence-graded)

1. **SoC identity** — HIGH. RK3399, 2x Cortex-A72 + 4x Cortex-A53. Both CPU
   compatibles (`arm,cortex-a72`, `arm,cortex-a53`) are confirmed in the fetched
   `rk3399-base.dtsi`. This drives `-mcpu=cortex-a72.cortex-a53`.
2. **Boot chain** — HIGH on the shape and on the blob-free claim. Both the U-Boot
   native DRAM driver and the mainline TF-A rk3399 platform port were confirmed
   present by direct fetch. **Not verified on hardware**: that a USB-written
   LIVE/INSTALLER medium boots through this distro-boot path on a real board.
   That is inferred from Frite's proven pattern.
3. **GPU / display** — HIGH on driver identity. The Mali-T860 is Midgard, so
   `panfrost` (kernel) and `panfrost` (Mesa Gallium) are both correct. The
   confusing RK3588 kernel/userspace naming split does **not** apply here. This
   port is also *less* version-sensitive than the RK3588 one: the RK3588's "HDMI
   is not functional before Linux 6.13" hazard does not apply, because the RK3399
   display stack has been mainline for years. **Not verified**: that a picture
   appears.
4. **Ethernet** — HIGH, and the easiest correction to miss. The board DTS enables
   `&gmac` with `phy-mode = "rgmii"`, and `rk3399-base.dtsi` declares it
   `compatible = "rockchip,rk3399-gmac"`. That is a Synopsys DesignWare MAC
   driven by stmmac plus the Rockchip glue. It is an **integrated** MAC, not a
   PCIe NIC, so the inherited `R8169` was not just suboptimal but inert. In
   contrast, on the Orange Pi 3 LTS port the shared mainline DTB has no usable
   ethernet node at all. Here onboard gigabit is wired up upstream.
5. **WiFi / Bluetooth** — MEDIUM-HIGH, and *better* than the Orange Pi 5's
   situation. `rk3399-orangepi.dts` has an enabled `&sdio0` with a
   `brcm,bcm4329-fmac` `wifi@1` child (brcmfmac) and an enabled `&uart0` with a
   `brcm,bcm43438-bt` bluetooth child (hci_uart). Both were confirmed by direct
   fetch. So WiFi is off by default here only because of the fleet's hardened
   posture, not to work around a driver gap. **UNVERIFIED**: brcmfmac needs a
   matching per-board firmware+NVRAM blob from linux-firmware at runtime, and
   nobody has checked whether the file this module wants is present. Note that
   `MMC_DW_ROCKCHIP` is a prerequisite, because the radio hangs off SDIO.
6. **Hardware crypto** — HIGH that the inherited reason does not carry over; see
   the note under the differences table. Not enabled.
7. **Storage** — HIGH on the driver split (Arasan for eMMC, dw_mmc-rockchip for
   SD/SDIO), from the upstream MMC Kconfig. **UNVERIFIED**: which device node the
   onboard eMMC enumerates as (`mmcblk0` vs `mmcblk1`). The installer takes the
   target device as an argument so nobody has to guess at build time.
8. **No NVMe** — HIGH. The Orange Pi 4 LTS has no M.2/PCIe slot, so the inherited
   NVMe install target, kernel driver and documentation were all removed. The
   RK3399 SoC does have a PCIe controller; `PCIE_ROCKCHIP_HOST` is enabled only
   for platform completeness.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax on the builder and the installer.
`--print-plan` across the flag matrix (internal consistency: artifact names,
kernel fragment and board-derived values all agree). That the DTB and
U-Boot-defconfig names exist upstream *and that the `-lts` variants do not*. That
every kernel Kconfig symbol written into `hardened-desktop.config` exists in the
upstream Kconfig file it belongs to. That this is a purely additive new-platform
change. That it reuses the shared `specs/` provisioning and mesh like every other
client image.

**NEEDS REAL HARDWARE (or at least a full Gentoo cross-build environment, which
this sandbox lacks):** the aarch64 cross-emerge of the LXDE stack. The mainline
kernel build, and whether the in-tree DTB name still matches the gentoo-sources
version checked out. Whether a USB-written LIVE/INSTALLER ISO boots via
distro-boot. HDMI producing a picture. Panfrost + Mesa accelerating the LXDE
session instead of falling back to software. Gigabit ethernet negotiating. WiFi
associating and passing traffic (and whether its firmware blob is present). eMMC
and microSD install targets. LUKS2 unlock at boot.

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module names the mapper
   device `luks-<uuid>` instead of the name `root=` expects (`cryptroot`), and
   `root=/dev/mapper/cryptroot` never resolves. `install-orangepi4-lts.sh` sets
   both, mirroring Frite and RPi5 (the Jetson builder has the same code, but it
   refuses `--encrypt-root`). The x86 installer sets only `rd.luks.uuid=`
   (`install-x86.sh:224`). Treat that as an x86 bug and do NOT copy it.
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows Frite's **on-device** model, not RPi5's **cross-host** model.
   `install-orangepi4-lts.sh` runs from WITHIN the booted LIVE/INSTALLER session,
   ON the Orange Pi 4 LTS that will unlock the root at every boot. The same board
   formats the volume and later reads it, so cryptsetup's argon2id auto-benchmark
   is trustworthy and deliberately NOT pinned. This judgment call is documented
   in `install-orangepi4-lts.sh`'s header. It rests on this platform sharing
   Frite's live-bootable-ISO-on-real-hardware boot chain (U-Boot + extlinux
   distro-boot scanning a USB stick directly). RPi5 differs: its ISO is
   documented as NOT bootable on the Pi 5 itself, so a human runs the installer
   from a SEPARATE PC with an SD-card reader. There the PBKDF must be pinned to
   `--pbkdf-memory 262144 --iter-time 2000 --pbkdf-parallel 4`, so the LUKS
   header's cost matches the WEAKER target hardware, not the writing host. If
   operators for this board turn out to `dd` the ISO from a PC and never
   live-boot the installer ON the board, the call must flip to the pinned model.
   Next reviewer: check this.

## Front-end wiring (all-options-in-all-menus)

Under the all-options-in-all-menus rule: `make orangepi4-lts`,
`make orangepi4-lts-live` and `make orangepi4-lts-installer` (the same pattern as
`frite`/`frite-live`/`frite-installer`: one dedicated platform, not a role loop
like RPi5's 3-cluster-role target); `scripts/build-menu.sh`'s architecture picker
and a dedicated flavor/desktop screen; the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepi4lts_args()`); and `tests/build-matrix/matrix.tsv` + `check.sh`. All of
them reach this platform through the same `--print-plan` contract as every other
builder.

## Hardware-validation checklist (flip Status when done)

1. Build mainline U-Boot from `orangepi-rk3399_defconfig` with a mainline TF-A
   rk3399 BL31 (no vendor blobs needed) and confirm it boots to a serial
   console.
2. Boot the LIVE image off USB/microSD on a real Orange Pi 4 LTS; confirm the
   dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi4-lts.sh` against the onboard eMMC and against microSD,
   and confirm the installed system boots — PLAINTEXT first, then
   `--encrypt-root`. Record which node the eMMC actually is.
4. Confirm HDMI output displays a picture (VOP + dw-hdmi).
5. Confirm the LXDE session comes up with panfrost acceleration, not a software
   fallback (`glxinfo`/`dmesg | grep panfrost`).
6. Confirm onboard gigabit ethernet enumerates via `dwmac-rockchip`/stmmac and
   links at 1000Mb/s.
7. Attempt `--enable-wifi` and document actual brcmfmac behaviour, including
   whether the required firmware/NVRAM files are present in linux-firmware.
8. Confirm `--write-uboot-spi` against this board's SPI NOR (the LTS is
   documented as having it, unlike the Orange Pi 5) — or record the correct
   sector offset if it boots from an eMMC/SD offset instead.

## Cross-references
- Desktop-taxonomy template this tree was forked from: `specs-orangepi5/README.md`
  (RK3588; read the differences table above before copying anything back).
- The other "borrowed mainline DTB" Orange Pi port: `specs-orangepi3-lts/README.md`.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
