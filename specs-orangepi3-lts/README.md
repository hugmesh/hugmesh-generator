# specs-orangepi3-lts — Orange Pi 3 LTS (Allwinner H6, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> 3 LTS has ever booted an image produced by this repo. Every H6 fact below (DTB
> and U-Boot defconfig names, kernel Kconfig symbols, driver maturity, the
> Ethernet/devicetree gap and the display-scope reasoning) is one of two kinds.
> Either it was **researched by fetching the live mainline Linux and U-Boot
> upstream source trees** (the plain OPi3's DTS, `configs/orangepi_3_defconfig`,
> the `arch/arm64/boot/dts/allwinner/` DTB Makefile and the `sun4i-drm`
> mixer/HDMI drivers were all re-fetched for THIS port), or it is **inherited
> from the Zero 2/Zero 2W/Zero 3 siblings' research**
> (`specs-orangepi-zero2/README.md` is the direct template). Each inherited
> claim is marked as such. Nothing is **verified on hardware**; there is no H6
> hardware in this sandbox. Treat it like `specs-jetson/` and
> `specs-orangepi5/`, which are also unvalidated. It builds and is internally
> consistent (`--print-plan` is clean across the whole flag matrix), but **do
> not trust it to boot** until a real board confirms it end to end.

## How this differs from the Zero 2 template (read this before trusting any inherited claim)

This platform is a faithful derivation of `specs-orangepi-zero2` +
`build-orangepi-zero2-stage4.sh` (the sunxi HEADLESS-APPLIANCE template). It has
MORE differences than any other port in the family, because it steps BACK a SoC
generation (H6, 2019) instead of sideways (H616→H618). All are verified for this
port unless marked inherited:

- **SoC: Allwinner H6, NOT the H616 family.** Mainline U-Boot handles it with its
  own machine support (`CONFIG_MACH_SUN50I_H6=y`, CONFIRMED by fetching the live
  `configs/orangepi_3_defconfig`). The mainline kernel DTS is the H6's own
  lineage (`sun50i-h6.dtsi` + `sun50i-h6-cpu-opp.dtsi`), unrelated to the Zero
  2's `sun50i-h616-orangepi-zero.dtsi`. It is the same quad Cortex-A53 CPU
  class, so the `-mcpu=cortex-a53` toolchain posture carries over.
- **BOARD CONSTANTS ARE BORROWED FROM THE PLAIN ORANGE PI 3 — the most important
  difference.** Mainline has NO `-lts` support anywhere. U-Boot `configs/` has no
  `orangepi_3_lts_defconfig`, and the kernel's `allwinner/` DTB Makefile has no
  `sun50i-h6-orangepi-3-lts.dtb` (both CONFIRMED by direct fetch for this port:
  the U-Boot raw file is a hard 404, and the DTB Makefile lists only
  `sun50i-h6-orangepi-3.dtb`). So this image boots the PLAIN Orange Pi 3's
  `orangepi_3_defconfig` + `allwinner/sun50i-h6-orangepi-3.dtb`, and depends on
  the LTS revision being boot-compatible with them (same SoC, same LPDDR3 class,
  same UART; the vendor markets the LTS as the OPi3's long-term-support
  respin). Where the two revisions differ, the mismatch is called out below:
  WiFi/BT chip, Ethernet PHY, eMMC size. An out-of-tree `-lts` DTS exists
  (Armbian carries one). The extlinux `FDT` line makes dropping it in easy, but
  this repo ships ONLY mainline artifacts.
- **ONBOARD Gigabit Ethernet is DEAD on the mainline DTB — USB-Ethernet-first.**
  The physical GbE jack is real, but CONFIRMED by direct fetch: the mainline
  `sun50i-h6-orangepi-3.dts` has NO ethernet/`&emac`/mdio node at all. The plain
  OPi3's enable-ethernet patch (an RTL8211E behind TWO supplies that must rise
  together, which mainline's single `phy-supply` binding cannot express cleanly)
  was posted repeatedly (as recently as a Dec-2023 v5 series) and never landed.
  On top of that, the LTS revision swapped the PHY to a Motorcomm YT8531C (vendor
  sheet / Armbian's `-lts` DTS), so even that unlanded patch pins the WRONG PHY
  for this board. So this appliance is **USB-Ethernet-first**, the Zero 2W
  sibling's posture and NOT the Zero 2 template's Ethernet-first one. The kernel
  fragment ships the USB-CDC/RTL8152/AX88179 class set as the primary path. It
  also keeps the (inert-by-default, all-mainline) `dwmac-sun8i` + Motorcomm/
  Realtek PHY stack, so a user-supplied `-lts` DTS or overlay lights the jack up
  without a kernel rebuild. See the Networking section of
  `kernel/hardened-appliance.config`.
- **Onboard 8GB eMMC EXISTS — a storage-class ADDITION over the template.** The
  Zero 2/Zero 2W/Zero 3 are microSD-only. This board has a soldered 8GB eMMC, and
  the mainline DTS enables its `mmc2` host (CONFIRMED by direct fetch). So
  `install-orangepi3-lts.sh` gains the eMMC as a first-class install target, as
  on Frite. Still no NVMe: the H6's PCIe controller is known to be non-compliant
  (quirky address-window hardware, unusable in mainline without out-of-tree
  hacks) and is treated as absent.
- **USB3 is REAL — an addition over the USB2-only H616 template.** The mainline
  DTS enables `&dwc3` + `&usb3phy` (CONFIRMED by direct fetch;
  `CONFIG_PHY_SUN50I_USB3=y` is likewise in the fetched U-Boot defconfig). So the
  kernel fragment adds xhci/dwc3/the H6 USB3 PHY. This matters here: USB Ethernet
  is the primary network path, and a USB3-attached GbE adapter is the fastest
  reliable NIC this board can have.
- **RAM: a single 2GB LPDDR3 SKU** (vendor sheet), trained by U-Boot's NATIVE H6
  LPDDR3 driver (`CONFIG_SUNXI_DRAM_H6_LPDDR3=y`, CONFIRMED in the fetched
  defconfig). These are the PLAIN OPi3's training values (see the board-constants
  item above). The template's multi-SKU zram reasoning shrinks to a plain
  "small-RAM appliance" rationale.
- **WiFi/BT: same gap as the template, in a different package.** The LTS's
  onboard radio is a Unisoc UWE5622 combo module (vendor sheet; the same die as
  the Zero 2's "AW859A" package). CONFIRMED-no-mainline-driver applies unchanged
  (inherited). One extra wrinkle: the PLAIN OPi3 shipped a Broadcom AP6256, so
  the mainline DTB's `brcm` WiFi (mmc1) and BCM4345C5 BT (uart1) nodes bind
  NOTHING on the LTS's Unisoc part. They are inert, not wrong.
- **No SPI NOR in the DTB.** The template boards expose a mainline SPI NOR
  boot-flash node. The mainline OPi3 DTS enables NO `&spi` node at all (CONFIRMED
  by direct fetch), so the kernel fragment DROPS the SPI/MTD symbols the template
  carries, and `--write-uboot-spi` falls into its no-op warning path on the stock
  image. Whether the LTS even solders a NOR chip is unclear from the vendor
  sheet, so it is flagged for hardware validation.
- **Display: headless is a DECISION here, not a hard driver gap.** The
  justification differs from the template's; see the next section. Do not copy
  display claims between the H616 siblings and this tree in either direction.
- **Board constants:** DTB `allwinner/sun50i-h6-orangepi-3.dtb`; U-Boot defconfig
  `orangepi_3_defconfig` (both the PLAIN OPi3's, as above; both CONFIRMED to
  exist by direct fetch of the live upstream trees). Serial console
  `ttyS0,115200` (CONFIRMED against the fetched DTS's own `aliases`/`chosen`
  nodes: `serial0 = &uart0`, `stdout-path = "serial0:115200n8"`).

Everything else is deliberately near-identical to the template: the flavor axis,
the standalone/encrypt-root posture, the on-device LUKS model, the package set,
the hardened kernel posture and the no-desktop scope. Do not "fix" a difference
between the two trees without checking which board it belongs to.

## Why this platform has no desktop option — read this first (DIFFERENT reasoning than the H616 siblings')

The Zero 2/Zero 2W/Zero 3 are headless because mainline has no working display
pipeline for their DE33 display engine, a hard gap. **That reason does NOT
transfer to the H6, and copying it here would be false.** CONFIRMED by direct
fetch for this port: mainline `drivers/gpu/drm/sun4i/` has both an H6 DE3 mixer
(`allwinner,sun50i-h6-de3-mixer-0` in `sun8i_mixer.c`) and the H6 DW-HDMI wrapper
(`allwinner,sun50i-h6-dw-hdmi` in `sun8i_dw_hdmi.c`), and the mainline
`sun50i-h6-orangepi-3.dts` has an ENABLED `&hdmi` node with a real
`hdmi-connector`. Mainline can, at least nominally, put pixels on this board's
HDMI port.

This platform stays a HEADLESS APPLIANCE anyway, for three reasons:

1. **Partial support, on borrowed wiring.** The H6 display pipeline in mainline
   is real but has board-specific rough edges on this family (the OPi3's DDC bus
   sits behind a PH2-gated regulator, and HDMI quirks on H6 boards are a long
   story). No GPU/accel story exists that this image would use. And, decisively,
   the DTB is the PLAIN OPi3's, so even the display wiring is only ASSUMED to
   match the LTS revision (see the board-constants item above). An EXPERIMENTAL
   platform must not ship a desktop on an unvalidated display path.
2. **Template parity.** This is a faithful derivation of the Zero 2 headless
   appliance: ONE role, a flavor axis only, no `--desktop`/`--role`/`--board`
   toggle in any of the four build channels. Adding a desktop axis would be a
   redesign, not a port.
3. **Appliance profile.** A small, cheap, low-power, SSH-only mesh/VPN utility
   node. This is the same scope the whole sunxi family in this repo targets.

**If a real board later validates the mainline H6 display path on the LTS
revision**, revisiting this scope is LEGITIMATE here in a way it is not for the
H616 siblings. Do it as a deliberate scope change (new role axis, new package
lists, new kernel fragment posture), not by copying another platform's GPU/X11
config. The builder's hard guard against `CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE`
protects the CURRENT scope from accidental drift, as on the template.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi 3 LTS.
The closest analogue in this repo is `build-frite-stage4.sh --desktop none` (its
headless-base mode), except that this platform has **no other mode**. There is no
`--desktop`/`--role` toggle at all. It reuses the SAME aarch64 cross toolchain
and shared `specs/` mesh/provisioning/sshd plumbing as every other client image:
headscale/tailscale mesh join, hardened key-only sshd, and KEYS-USB first-boot
provisioning. It supports `--standalone` (local user over SSH, no mesh,
build-time password) and `--encrypt-root` (LUKS2 full-disk encryption) from the
start.

```sh
./build-orangepi3-lts-stage4.sh                                  # both live+installer
./build-orangepi3-lts-stage4.sh --flavor live                    # live only
./build-orangepi3-lts-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi3-lts-stage4.sh --encrypt-root --print-plan      # dry-run plan (no root)
```

There is no `--board` axis either (Frite has 3 boards, Orange Pi 5 has 2). This
is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig` are
direct overrides, not entries in a board table.

## Boot chain (researched — see confidence notes)

```
Allwinner BootROM
  -> U-Boot SPL   (NATIVE H6 LPDDR3 DRAM-init driver — NO blob. Same
                    blob-free-boot family trait as the Zero 2 template:
                    U-Boot's own drivers/ram sunxi H6 code trains DRAM;
                    TF-A BL31 is required but is open source, not a blob.)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD/eMMC/USB) for /extlinux/extlinux.conf -- the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh use
```

U-Boot defconfig (CONFIRMED by fetching `configs/orangepi_3_defconfig` from
`u-boot/u-boot` upstream): `CONFIG_MACH_SUN50I_H6=y`,
`CONFIG_SUNXI_DRAM_H6_LPDDR3=y` (native training, with no blob reference of any
kind), `CONFIG_PHY_SUN50I_USB3=y`, default devicetree `sun50i-h6-orangepi-3`.
Mainline kernel DTB (CONFIRMED against the live `arch/arm64/boot/dts/allwinner/`
Makefile): `sun50i-h6-orangepi-3.dtb`. NO `-lts` variant exists (see the
board-constants item above). Serial debug console (CONFIRMED against the fetched
DTS's own `chosen`/`aliases` nodes): `ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **Board-constants delta (no mainline `-lts` support)** — HIGH confidence, and
   the most important finding in this port. By direct fetch,
   `configs/orangepi_3_lts_defconfig` is a hard 404 in the live U-Boot tree, and
   the kernel's `allwinner/` DTB Makefile lists only `sun50i-h6-orangepi-3.dtb`.
   Everything this image boots is the PLAIN OPi3's board support.
2. **Boot chain / no-blob DRAM init** — HIGH confidence. We fetched
   `orangepi_3_defconfig` from the live upstream U-Boot tree.
   `CONFIG_SUNXI_DRAM_H6_LPDDR3=y` is native training code, with no blob load or
   reference of any kind. The family's blob-free-boot trait carries over (the
   framing is inherited from the Zero 2 README; the H6 symbol is confirmed
   here).
3. **Ethernet** — HIGH confidence, NEGATIVE finding. The mainline
   `sun50i-h6-orangepi-3.dts` has no ethernet/`&emac`/mdio node at all (direct
   fetch plus an exhaustive grep). The enable-ethernet DT patch history (RTL8211E
   dual-supply problem; v5 as late as Dec 2023) never landed. The LTS's PHY is a
   different chip again (Motorcomm YT8531C, per the vendor sheet and Armbian's
   `-lts` DTS; NOT verifiable in mainline). So the appliance is
   USB-Ethernet-first (the Zero 2W precedent). The inert onboard-GbE driver
   stack stays in, honestly labeled, for user-supplied DTS overlays.
4. **WiFi** — CONFIRMED gap (inherited from the Zero 2/Zero 2W research, plus the
   vendor sheet for the LTS's module). Unisoc UWE5622 has no mainline kernel.org
   driver at all. This image ships NO onboard-radio kernel module (see
   `kernel/hardened-appliance.config`), and `harden_radios()` blacklists the
   generic radio stack by default regardless. The DTB's Broadcom wifi/bt nodes
   (the plain OPi3's AP6256) are inert on the LTS's part.
5. **Storage** — HIGH confidence. microSD (`mmc0`) + onboard 8GB eMMC (`mmc2`,
   enabled in the fetched DTS) + USB. No NVMe (the H6's PCIe is non-compliant
   and unusable in mainline; this is inherited common knowledge, treated as
   absent). The DTS has no SPI node (direct fetch), so no mainline-visible NOR
   flash. That is a real difference from every sunxi sibling in this repo.
6. **USB3** — HIGH confidence. `&dwc3` + `&usb3phy` are enabled in the fetched
   DTS, and `CONFIG_PHY_SUN50I_USB3` is present in both the fetched U-Boot
   defconfig and the kernel fragment. It matters because the primary NIC is USB.
7. **CPU / hardware crypto** — HIGH confidence. The H6 is a quad-core Cortex-A53
   (the same core class as the template board and Orange Pi 5's LITTLE cluster).
   So `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions) applies the same
   way: a guaranteed CPU-instruction AES accelerator for LUKS2's `xts(aes)`. We
   claim or assume no dedicated crypto engine.
8. **RAM** — MEDIUM confidence (vendor sheet, not DT-verifiable): a single 2GB
   LPDDR3 SKU. The fetched defconfig's LPDDR3 training values are the PLAIN
   OPi3's. Whether they hold on the LTS's memory layout is something only real
   hardware can prove (see the checklist).
9. **Display** — HIGH confidence that mainline H6 DE3/DW-HDMI support EXISTS
   (direct fetch of the `sun8i_mixer.c`/`sun8i_dw_hdmi.c` compatibles and the
   DTS's enabled `&hdmi` node). Headless stays a deliberate scope decision; see
   the dedicated section above. Do NOT carry the H616 siblings' "zero display
   support" claim into this tree.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax. `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency: artifact names, kernel
fragment and effective flavor all agree). That the DTB and U-Boot-defconfig
values match upstream U-Boot/Linux naming as researched above, including a
direct fetch of the actual files. That this is a purely additive new-platform
change (no existing builder/specs tree behavior changed). That it reuses the
shared `specs/` provisioning and mesh like every other client image. Template
rendering: LIVE emits `INITRD /initrd.img`, plaintext INSTALLER does not, and
`--encrypt-root` INSTALLER emits the disk-boot initramfs line. A hard build-time
guard refuses to ship a kernel with `CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE`
set, which protects the headless scope from accidental drift.

**NEEDS REAL HARDWARE (or at least a full Gentoo cross-build environment, which
this sandbox lacks):** the aarch64 cross-emerge of this package set against THIS
platform's package/USE set. The mainline kernel build, and whether the in-tree H6
DTB name above still matches the gentoo-sources version checked out. **Whether
the PLAIN OPi3's U-Boot defconfig + DTB boot the LTS revision at all** (the
port's central bet). Whether a microSD/eMMC/USB-written LIVE/INSTALLER image
boots via distro-boot. Whether the `orangepi_3_defconfig` LPDDR3 training
parameters hold on the LTS's 2GB memory layout. The crypto/LUKS2 read/write path.
USB Ethernet (and, with a user-supplied `-lts` DTS, whether the onboard YT8531C
jack can link). The eMMC's real `mmcblkN` index. Whether the LTS solders a NOR
chip at all. These steps MIRROR the proven Frite/Orange-Pi-5 flow but cannot be
tested end to end here.

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module names the mapper
   device `luks-<uuid>` instead of the name `root=` expects (`cryptroot`), and
   `root=/dev/mapper/cryptroot` never resolves. `install-orangepi3-lts.sh` sets
   both, mirroring Frite, RPi5 and Orange Pi 5. (The Jetson builder has the same
   code, but it refuses `--encrypt-root`.) The x86 installer sets only
   `rd.luks.uuid=` (`install-x86.sh:224`). Treat that as an x86 bug and do NOT
   copy it.
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows Frite's/Orange-Pi-5's **on-device** model, not RPi5's
   **cross-host** model. `install-orangepi3-lts.sh` runs from WITHIN the booted
   LIVE/INSTALLER session, ON the Orange Pi 3 LTS that will unlock the root at
   every boot. The same board formats the volume and later reads it, so
   cryptsetup's argon2id auto-benchmark is trustworthy and deliberately NOT
   pinned. Orange Pi 5 made the same call for the same reason. If operators for
   this board turn out to `dd` the image from a PC and never live-boot the
   installer ON the board, the call must flip to the pinned model. Orange Pi 5's
   README flags the same risk. Next reviewer: check this.

## Storage classes — microSD / onboard 8GB eMMC / USB (an ADDITION over the template)

The Zero 2 template is microSD-only. This board HAS an onboard 8GB eMMC
(mainline-enabled `mmc2`; see the differences section), so
`install-orangepi3-lts.sh` installs to any of three targets. The **eMMC** is
recommended where 8GB fits the appliance, and the LIVE microSD stays bootable as
a rescue disk. The others are a **second** microSD/USB device, or the **same**
device the LIVE image booted from. The live session runs entirely from a
squashfs+tmpfs overlay in RAM, so repartitioning the boot medium under it does
not corrupt the running session. The installer asks for an extra confirmation on
a same-device install but does not block it. No NVMe ever (H6 PCIe; see the
differences section). All of this is **untested on real hardware**; see the
checklist below.

## Front-end wiring (all-options-in-all-menus)

Under the all-options-in-all-menus rule: `make orangepi3-lts`,
`make orangepi3-lts-live` and `make orangepi3-lts-installer` (the same
single-dedicated-platform pattern as `orangepizero2`, not a role loop);
`scripts/build-menu.sh`'s architecture picker and a dedicated flavor screen (no
board sub-menu, because there is one board); the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepi3lts_args()`, labelled as a **headless appliance**, not a desktop); and
`tests/build-matrix/matrix.tsv` + `check.sh`. All of them reach this platform
through the same `--print-plan` contract as every other builder.

## Hardware-validation checklist (flip Status when done)

1. Confirm the PLAIN OPi3's `orangepi_3_defconfig` U-Boot actually boots the
   LTS revision to a serial console (`ttyS0,115200`) — the port's central bet,
   and blob-free if it works. If it does not, an out-of-tree `-lts`
   defconfig/DTS (Armbian's) is the fallback to document.
2. Boot the LIVE image off microSD/USB on a real Orange Pi 3 LTS; confirm the
   dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi3-lts.sh` against the onboard eMMC AND a microSD card
   (same-device and second-device paths) and confirm the installed system
   boots — PLAINTEXT first, then `--encrypt-root`; record the eMMC's real
   `mmcblkN` index.
4. Confirm USB Ethernet (CDC + RTL8152/AX88179 classes) links and passes
   traffic — it is the appliance's primary network path.
5. With a user-supplied `-lts` DTS (e.g. Armbian's), confirm whether the
   onboard YT8531C GbE jack links via `dwmac-sun8i` + `CONFIG_MOTORCOMM_PHY`
   — and document the DTS provenance if adopted.
6. Confirm the LPDDR3 training parameters hold on the LTS's 2GB layout
   (stress the RAM, not just boot).
7. Confirm whether the LTS solders a NOR chip at all, and whether its
   boot-select reads U-Boot from a fixed microSD/eMMC byte offset (the common
   sunxi convention; `--write-uboot-spi` is a no-op on the stock DTB — see
   the installer header).
8. Re-check the display situation ON the LTS revision before ever revisiting
   the headless scope (see the dedicated section above — the reasoning here
   is scope, not a hard gap, and must be revisited honestly).

## Cross-references
- Direct template: `specs-orangepi-zero2/README.md` +
  `build-orangepi-zero2-stage4.sh` (sunxi headless-appliance pattern).
- Network posture precedent (USB-Ethernet-first): `specs-orangepi-zero2w/README.md`.
- Closest architectural sibling for the LUKS on-device model and the
  confidence-graded README structure: `specs-orangepi5/README.md`.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
