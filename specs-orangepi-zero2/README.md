# specs-orangepi-zero2 — Orange Pi Zero 2 (Allwinner H616, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> Zero 2 has ever booted an image produced by this repo. Every H616 fact below
> (DTB and U-Boot defconfig names, kernel Kconfig symbols, driver maturity and,
> above all, the HDMI/display-driver gap) was **researched by fetching the live
> mainline Linux and U-Boot upstream source trees** at research time, not just
> secondary claims about them. None of it is **verified on hardware**. There is
> no H616 hardware, and no network access to cross-emerge a real Gentoo tree, in
> this sandbox. Treat it like `specs-jetson/` and `specs-orangepi5/`, which are
> also unvalidated. It builds and is internally consistent (`--print-plan` is
> clean across the whole flag matrix), but **do not trust it to boot** until a
> real board confirms it end to end.

## Why this is the ONE platform in the repo with no desktop option — read this first

The Zero 2 is the template for the other headless Orange Pi platforms. The Zero
2W and Zero 3 inherit this page's research; the 3 LTS is headless too. Frite, Orange
Pi 5, Orange Pi 4 LTS, the RPi5 desktop role and the Jetson desktop role ship a
lean LXDE-class desktop. The Zero 2 does not, and never will. The reason is
concrete and researched. It is not neglect:

- The board **does** have a physical Micro-HDMI 2.0a port (confirmed against
  official specs/schematic and the upstream devicetree's own board-description
  comment). This is **not** a "no video hardware" situation.
- Mainline Linux has **zero display-driver support** for the H616's display
  engine (DE33) as of the research behind this platform. Confirmed by fetching
  the live upstream trees:
  - `drivers/gpu/drm/sun4i/` (torvalds/linux, `master`) has driver files for the
    OLDER sun4i/sun6i/sun8i DE2/DE3-class hardware (`sun8i_mixer.c`,
    `sun8i_dw_hdmi.c`, `sun8i_hdmi_phy.c`, ...) and **nothing** named
    `de33`/`hdmi_h616`/anything H616-specific.
  - `arch/arm64/boot/dts/allwinner/sun50i-h616.dtsi` (the H616 SoC-level
    devicetree) has **no** `&hdmi`, `&tcon`, `&mixer`, or display-engine node
    of any kind.
  - A Nov-2025-dated post on the DE33 mixer/CSC/plane-binding patch series
    called it "a second series out of tree" that aims to "properly introduce"
    DE33 support. It said the patches for **a full display pipeline**
    (including HDMI) "will be sent once this series is merged". So the full
    pipeline was not even specified then, let alone merged.
  - Working HDMI on this board exists only in Allwinner's own never-upstreamed
    legacy-BSP kernel fork (a **whole alternate kernel tree**, not an extra
    firmware blob), or in an **Armbian community backport** of the out-of-tree
    DE33 patch series onto their sunxi-6.12 kernel branch. That backport's PR
    history (`armbian/build` #7752 added the `drm sun4i-de33` driver and HDMI
    support; #7947, "BUGFIX: Remove the incomplete patch", followed) shows **boot
    freezes** on this exact board (Orange Pi Zero 2/Zero 3), a GPU-power-domain
    hang traced to a wrongly applied patch, and a fix that **removed** the patch
    instead of stabilizing it. Even the best out-of-tree attempt is not stable.
- Carrying a whole alternate out-of-tree kernel for one board's display would
  cost far more, and break more easily, than anything else in this repo. Even
  Orange Pi 5's HDMI (gated on "kernel must be >= 6.13") and Frite's Amlogic
  FIP/BL31 are each just **one** proprietary or out-of-tree piece in an
  otherwise-mainline build.
- WiFi (a Unisoc UWE5622 die inside an Allwinner "AW859A" combo module) is
  **also** out-of-tree only. No mainline kernel.org driver exists at all, a
  bigger gap than Orange Pi 5's AP6275P, which at least has an upstream
  brcmfmac-class driver with known rough edges.
- On the plus side, this board has a **fully open-source, blob-free boot
  chain**. Mainline U-Boot has **native**, community-reverse-engineered H616
  DRAM init (no closed "boot0" blob at all, unlike Frite and Orange Pi 5, which
  each need a vendor blob; the Orange Pi 3 LTS and 4 LTS chains are blob-free
  too). Onboard Gigabit Ethernet uses a Realtek RTL8211F PHY (fully mainline).
  The board is tiny, cheap and low-power. That is the profile of a lean,
  hardened, **SSH-only network appliance**: a small VPN/mesh gateway, a tiny
  home-lab utility box. That is the scope this builder targets.

**If mainline Linux lands full DE33 display support** (watch the `dri-devel`
list and `linux-sunxi.org`'s H616 page), revisit this decision. A desktop role
could become viable. Do not keep building headless out of habit once that
changes, and do not turn this platform into a desktop role by copying another
platform's GPU/X11 config without re-confirming the display situation first.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi Zero 2.
The closest analogue in this repo is `build-frite-stage4.sh --desktop none` (its
headless-base mode), except that this platform has **no other mode**. There is
no `--desktop`/`--role` toggle at all, because this board never has a desktop
option. It reuses the SAME aarch64 cross toolchain and shared `specs/`
mesh/provisioning/sshd plumbing as every other client image: headscale/tailscale
mesh join, hardened key-only sshd, and KEYS-USB first-boot provisioning. It
supports `--standalone` (local user over SSH, no mesh, build-time password) and
`--encrypt-root` (LUKS2 full-disk encryption) from the start.

```sh
./build-orangepi-zero2-stage4.sh                              # both live+installer
./build-orangepi-zero2-stage4.sh --flavor live                 # live only
./build-orangepi-zero2-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi-zero2-stage4.sh --encrypt-root --print-plan   # dry-run plan (no root)
```

There is no `--board` axis either (Frite has 3 boards, Orange Pi 5 has 2). This
is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig` are
direct overrides, not entries in a board table.

## Boot chain (researched — see confidence notes)

```
Allwinner BootROM
  -> U-Boot SPL   (NATIVE H616 DRAM-init driver — NO blob. This is the
                    difference from Frite and Orange Pi 5: Frite needs
                    Amlogic FIP/BL31, Orange Pi 5 needs
                    Rockchip rkbin DDR-init + TF-A BL31 blobs. This board's
                    mainline U-Boot alone can train DRAM.)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD/USB) for /extlinux/extlinux.conf -- the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh use
```

U-Boot defconfig (CONFIRMED by fetching `configs/orangepi_zero2_defconfig` from
`u-boot/u-boot` upstream): it contains `CONFIG_DRAM_SUNXI_DX_ODT`/
`CONFIG_DRAM_SUNXI_DX_DRI`/`CONFIG_DRAM_SUNXI_CA_DRI`/`CONFIG_DRAM_SUNXI_TPR6`/
`CONFIG_DRAM_SUNXI_TPR10`/`CONFIG_SUNXI_DRAM_H616_DDR3_1333=y`. These are all
**native training parameters**, with no blob reference of any kind. Mainline
kernel DTB (CONFIRMED against `arch/arm64/boot/dts/allwinner/` upstream):
`sun50i-h616-orangepi-zero2.dts` (includes `sun50i-h616-orangepi-zero.dtsi` +
`sun50i-h616-cpu-opp.dtsi`). Serial debug console (CONFIRMED against the live
`sun50i-h616-orangepi-zero.dtsi`'s own `chosen`/`aliases` nodes:
`aliases { serial0 = &uart0; }`, `chosen { stdout-path = "serial0:115200n8"; }`):
`ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **HDMI/display driver gap** — HIGH confidence, and the most important finding
   in this port (full trail in the first section). Re-verify it before you
   revisit the headless-only decision.
2. **Boot chain / no-blob DRAM init** — HIGH confidence. We fetched
   `orangepi_zero2_defconfig` from the live upstream U-Boot tree and inspected
   its DRAM-training symbols. No blob load or reference of any kind is present.
   This is a real project first.
3. **Ethernet (RTL8211F PHY + H616 EMAC)** — HIGH confidence. The upstream
   devicetree's own board-description comment confirms the onboard Gigabit
   Ethernet: "1Gbps Ethernet port (via RTL8211F PHY)". The MAC-side driver is
   `CONFIG_DWMAC_SUN8I` (Allwinner sun8i/sun50i GMAC glue,
   `drivers/net/ethernet/stmicro/stmmac/dwmac-sun8i.c`). The PHY driver is
   `CONFIG_REALTEK_PHY` (`drivers/net/phy/realtek/`, covering the RTL821x/RTL822x
   family including the RTL8211F). Both are CONFIRMED mainline. **VERIFY** that
   the Kconfig split still matches the kernel tree checked out at build time:
   upstream moved the Realtek PHY driver into its own `drivers/net/phy/realtek/`
   subdirectory at some point. The Kconfig *symbol name* (`CONFIG_REALTEK_PHY`)
   is confirmed unchanged, but the file layout can drift.
4. **WiFi** — CONFIRMED gap. The onboard Unisoc UWE5622 die (packaged inside an
   Allwinner "AW859A" WiFi+BT module) has **no mainline kernel.org driver at
   all**, not even a rough one. This appliance ships **no** onboard-radio kernel
   module (see `kernel/hardened-appliance.config`), rather than carry dead
   module config for hardware that mainline cannot drive. A USB WiFi/Bluetooth
   dongle with its OWN mainlined driver would still work through whatever the
   base arm64 defconfig builds. `harden_radios()` in the builder blacklists the
   generic cfg80211/mac80211/bluetooth/btusb modules by default regardless (the
   same hardened posture as every platform). Ethernet and the tailnet are this
   appliance's primary, reliable path, by design.
5. **Storage** — HIGH confidence. This board has **no eMMC** (the original 2019
   announcement mentioned an optional eMMC SKU; the shipping product has none)
   and **no NVMe/PCIe at all** on this SoC tier. Storage is microSD, plus a
   small onboard 2MiB bootable SPI NOR flash that can carry U-Boot itself (as on
   La Frite). Confirmed against the upstream devicetree's board-description
   comment ("MicroSD slot, 2MiB bootable SPI NOR flash") and multiple
   independent spec sources.
6. **CPU / hardware crypto** — HIGH confidence. The H616 is a quad-core
   Cortex-A53 (no big.LITTLE split, unlike Orange Pi 5's RK3588
   cortex-a76.cortex-a55 mix). It is the SAME core as Orange Pi 5's LITTLE
   cluster, so `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions)
   applies the same way. It is a guaranteed CPU-instruction AES accelerator,
   used for LUKS2's `xts(aes)` cipher on `--encrypt-root` builds. We claim no
   dedicated hardware crypto *engine* (distinct from the CPU's Crypto
   Extensions) for this SoC tier. The H616 is a much smaller chip than the
   RK3588, and the fragment does not assume one.
7. **RAM SKUs** — HIGH confidence. The board ships in 512MB/1GB/1.5GB/2GB DDR3
   SKUs. RAM is auto-detected and one image serves all of them (as on La Frite's
   512MB/1GB SKUs). A zram swap is set up at first boot to help the smallest SKU.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax. `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency: artifact names, kernel
fragment and effective flavor all agree). That the DTB and U-Boot-defconfig
values match upstream U-Boot/Linux naming as researched above, including a
direct fetch of the actual files. That this is a purely additive new-platform
change (no existing builder/specs tree touched). That it reuses the shared
`specs/` provisioning and mesh like every other client image. Template
rendering: LIVE emits `INITRD /initrd.img`, plaintext INSTALLER does not, and
`--encrypt-root` INSTALLER emits the disk-boot initramfs line. A hard build-time
guard refuses to ship a kernel with `CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE`
set, which protects the headless-only scope from an accidental regression.

**NEEDS REAL HARDWARE (or at least a full Gentoo cross-build environment, which
this sandbox lacks):** the aarch64 cross-emerge of this package set against THIS
platform's package/USE set. The mainline kernel build, and whether the in-tree
H616 DTB name above still matches the gentoo-sources version checked out.
Whether a microSD/USB-written LIVE/INSTALLER image boots via distro-boot on real
hardware. Whether the `orangepi_zero2_defconfig` DRAM-training parameters work
across EVERY RAM SKU (512MB/1GB/1.5GB/2GB). The crypto/LUKS2 read/write path.
The Ethernet PHY linking at gigabit. Whether the board's boot-select strap reads
U-Boot from the onboard SPI NOR or straight from the microSD card at a fixed
byte offset (both are plausible sunxi conventions, and neither could be checked
without hardware). These steps MIRROR the proven Frite/Orange-Pi-5 flow but
cannot be tested end to end here: no board, no full Gentoo builder, and this
sandbox may also lack network access for a real cross-emerge (check before
assuming otherwise).

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module names the mapper
   device `luks-<uuid>` instead of the name `root=` expects (`cryptroot`), and
   `root=/dev/mapper/cryptroot` never resolves. `install-orangepi-zero2.sh` sets
   both, mirroring Frite, RPi5 and Orange Pi 5. (The Jetson builder has the same
   code, but it refuses `--encrypt-root`.) The x86 installer sets only
   `rd.luks.uuid=` (`install-x86.sh:224`). Treat that as an x86 bug and do NOT
   copy it.
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows Frite's/Orange-Pi-5's **on-device** model, not RPi5's
   **cross-host** model. `install-orangepi-zero2.sh` runs from WITHIN the booted
   LIVE/INSTALLER session, ON the Orange Pi Zero 2 that will unlock the root at
   every boot. The same board formats the volume and later reads it, so
   cryptsetup's argon2id auto-benchmark is trustworthy and deliberately NOT
   pinned. Orange Pi 5 made the same call for the same reason: a live+installer
   image that boots on the board itself, unlike RPi5's installer ISO, which is
   documented as NOT bootable on the Pi 5. If operators for this board turn out
   to `dd` the image from a PC and never live-boot the installer ON the board,
   the call must flip to the pinned model. Orange Pi 5's README flags the same
   risk. Next reviewer: check this.

## Single storage class — no eMMC, no NVMe (a genuinely different situation
   from every sibling)

Frite has an eMMC module or microSD, and Orange Pi 5 has eMMC, microSD or NVMe.
This board has exactly **one** persistent storage class: microSD (or USB). There
is no "boot from USB, install to eMMC" split. `install-orangepi-zero2.sh`
installs to a **second** microSD/USB device (the safer choice: the LIVE medium
stays bootable as a rescue disk) **or** to the **same** device the LIVE image
booted from. The live session runs entirely from a squashfs+tmpfs overlay in
RAM, so repartitioning the boot medium under it does not corrupt the running
session. Many live-CD-style installers work this way. The installer asks for an
extra confirmation on a same-device install but does not block it. This is
**untested on real hardware**; see the checklist below.

## Front-end wiring (all-options-in-all-menus)

Under the all-options-in-all-menus rule: `make orangepizero2`,
`make orangepizero2-live` and `make orangepizero2-installer` (the same
single-dedicated-platform pattern as `frite`/`orangepi5`, not a role loop);
`scripts/build-menu.sh`'s architecture picker and a dedicated flavor screen (no
board sub-menu, because there is one board); the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepizero2_args()`, labelled as a **headless appliance**, not a desktop);
and `tests/build-matrix/matrix.tsv` + `check.sh`. All of them reach this platform
through the same `--print-plan` contract as every other builder.

## Hardware-validation checklist (flip Status when done)

1. Assemble/obtain a real U-Boot build for `orangepi_zero2_defconfig` and
   confirm it boots to a serial console (`ttyS0,115200`) with NO blob — this is
   the platform's headline claim and the first thing to actually prove.
2. Boot the LIVE image off microSD/USB on a real Orange Pi Zero 2; confirm the
   dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi-zero2.sh` against a microSD card (both the
   same-device and second-device paths) and confirm the installed system boots
   — PLAINTEXT first, then `--encrypt-root`.
4. Confirm Gigabit Ethernet actually links and passes traffic via `dwmac-sun8i`
   (`CONFIG_DWMAC_SUN8I`) + the RTL8211F PHY (`CONFIG_REALTEK_PHY`).
5. Confirm the board really has no usable HDMI output on this kernel (i.e.
   confirm the headless-only decision is still correct) — and if mainline DE33
   support has landed since this research, flag it prominently for a scope
   revisit rather than silently continuing headless.
6. Confirm the DRAM-init training parameters in `orangepi_zero2_defconfig`
   actually work across all four RAM SKUs (512MB/1GB/1.5GB/2GB DDR3).
7. Confirm whether this board's boot-select strap defaults to SPI NOR or a
   fixed microSD byte offset for U-Boot (both `--write-uboot-spi` and a
   from-source U-Boot cross-build are realistic next steps given the no-blob
   boot chain).

## Cross-references
- Closest architectural sibling for the mesh/provisioning/SSH plumbing:
  `build-frite-stage4.sh`'s `DESKTOP=none` headless-base code path (the idea
  this platform makes permanent instead of conditional).
- Closest architectural sibling for the LUKS on-device model and the
  confidence-graded README structure: `specs-orangepi5/README.md`.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
