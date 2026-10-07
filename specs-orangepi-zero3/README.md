# specs-orangepi-zero3 — Orange Pi Zero 3 (Allwinner H618, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> Zero 3 has ever booted an image produced by this repo. Every H618 fact below
> (DTB and U-Boot defconfig names, kernel Kconfig symbols, driver maturity and,
> above all, the HDMI/display-driver gap) is one of two kinds. Either it was
> **researched by fetching the live mainline Linux and U-Boot upstream source
> trees** (the board's own DTS, its shared `sun50i-h616-orangepi-zero.dtsi` and
> its U-Boot defconfig were re-fetched for THIS port), or it is **inherited from
> the Zero 2W and Zero 2 siblings' research** (`specs-orangepi-zero2w/README.md`
> is the direct template, with the same H618 SoC; also
> `specs-orangepi-zero2/README.md`). Each inherited claim is marked as such.
> Nothing is **verified on hardware**; there is no H618 hardware in this
> sandbox. Treat it like `specs-jetson/` and `specs-orangepi5/`, which are also
> unvalidated. It builds and is internally consistent (`--print-plan` is clean
> across the whole flag matrix), but **do not trust it to boot** until a real
> board confirms it end to end.

## How this differs from the Zero 2W template (read this before trusting any inherited claim)

This platform is a faithful derivation of `specs-orangepi-zero2w` +
`build-orangepi-zero2w-stage4.sh` (the SAME-SoC H618 sibling, the nearest
possible template; that tree is itself derived from the H616 Zero 2). These are
the differences, all verified for this port unless marked inherited:

- **SoC: the SAME H618.** Unlike the earlier ports in this family, the SoC does
  not change. Mainline U-Boot handles it with the SAME machine support
  (`CONFIG_MACH_SUN50I_H616=y`, CONFIRMED by fetching the live
  `configs/orangepi_zero3_defconfig`), and the mainline kernel DTS carries the
  same `allwinner,sun50i-h618` compatible (CONFIRMED by fetching the live
  `sun50i-h618-orangepi-zero3.dts`). So everything the siblings' research says
  about the H616/H618 display engine (DE33) applies unchanged, and the
  headless-only decision carries over.
- **DTS lineage: back to the Zero 2's shared dtsi.** The fetched
  `sun50i-h618-orangepi-zero3.dts` includes `sun50i-h616-orangepi-zero.dtsi`
  (the SAME shared board dtsi the Zero 2 uses) plus `sun50i-h616-cpu-opp.dtsi`.
  The Zero 2W includes `sun50i-h616.dtsi` directly instead. So at the devicetree
  level this board is closer to a "Zero 2 with H618 + LPDDR4" than to the Zero
  2W, even though the Zero 2W is the same-SoC template.
- **ONBOARD Gigabit Ethernet is BACK — the biggest functional difference.** The
  Zero 2W dropped the Ethernet jack (its images are USB-Ethernet-first). The
  Zero 3 restores it. CONFIRMED: the fetched mainline
  `sun50i-h618-orangepi-zero3.dts` enables `&emac0` with
  `phy-mode = "rgmii-rxid"`, `allwinner,tx-delay-ps = <700>` and
  `phy-supply = <&reg_dldo1>`. It also sets
  `motorcomm,clk-out-frequency-hz = <125000000>` on the shared dtsi's RGMII PHY
  node. So the external PHY is a **Motorcomm YT8531**, NOT the Zero 2's Realtek
  RTL8211F. Both halves are mainline (`CONFIG_DWMAC_SUN8I` +
  `CONFIG_MOTORCOMM_PHY`; see `kernel/hardened-appliance.config`), and the
  fetched U-Boot defconfig pairs them the same way (`CONFIG_SUN8I_EMAC=y` +
  `CONFIG_PHY_MOTORCOMM=y`). This restores the family's blob-free
  boot+network chain, which the Zero 2W had to degrade to boot-only, and the
  appliance is **Ethernet-first** again, like the Zero 2.
- **RAM: same LPDDR4 story.** SKUs are 1GB/1.5GB/2GB/4GB LPDDR4. The fetched
  U-Boot defconfig selects `CONFIG_SUNXI_DRAM_H616_LPDDR4=y` +
  `CONFIG_DRAM_CLK=792` + native `CONFIG_DRAM_SUNXI_TPR*`/`DX_ODT`/... training
  parameters (CONFIRMED by direct fetch; the VALUES are this board's own, not
  byte-identical to the Zero 2W's). It is still **fully native, no blob**.
- **PMIC: same AXP313** (`CONFIG_AXP313_POWER=y` in the fetched defconfig). It
  matters only at the U-Boot level; no builder knob depends on it.
- **Storage: same class.** 16MB SPI NOR (bootloader-sized, U-Boot only, per the
  vendor's spec sheet), no eMMC, no NVMe/PCIe. microSD/USB remains the ONLY
  persistent storage class, so the single-storage-class installer model carries
  over.
- **USB: USB-C power/OTG + a full-size USB2 Type-A host port** (plus USB2 pins on
  the expansion header) instead of the Zero 2W's 2x Type-C. The port
  arrangement is per the vendor's spec sheet (not DTS-verifiable). The same
  musb/ehci/ohci sunxi symbol set applies through the shared dtsi (inherited).
- **HDMI connector: Micro-HDMI** (per the vendor's spec sheet; the Zero 2W's is
  Mini-HDMI). This changes nothing: there is still no mainline driver to put
  pixels on either connector (see the scope section below).
- **WiFi/BT: same gap.** A Unisoc UWE5622 combo module (per the vendor's own
  spec sheet for this board; the same die as the Zero 2's "AW859A" package). The
  siblings' CONFIRMED finding that no mainline kernel.org driver exists applies
  here too (inherited).
- **Board constants:** DTB `allwinner/sun50i-h618-orangepi-zero3.dtb`; U-Boot
  defconfig `orangepi_zero3_defconfig` (both CONFIRMED by direct fetch of the
  live upstream trees for this port). Serial console `ttyS0,115200` (CONFIRMED
  against the fetched shared dtsi's own `aliases`/`chosen` nodes:
  `serial0 = &uart0`, `stdout-path = "serial0:115200n8"`).

Everything else is deliberately near-identical to the template: the flavor axis,
the standalone/encrypt-root posture, the on-device LUKS model, the package set,
the hardened kernel posture and the no-desktop-ever scope. Do not "fix" a
difference between the two trees without checking which board it belongs to.

## Why this is a platform with no desktop option — read this first

Frite, Orange Pi 5, Orange Pi 4 LTS, the RPi5 desktop role and the Jetson
desktop role ship a lean LXDE-class desktop. This one does not, and never will.
The reason is concrete and researched. It is not neglect. The trail below is the
Zero 2 sibling's research, carried through the Zero 2W template. It applies
verbatim, because the H618 carries the SAME DE33 display engine:

- The board **does** have a physical Micro-HDMI port. This is **not** a "no
  video hardware" situation.
- Mainline Linux has **zero display-driver support** for the H616/H618 display
  engine (DE33) as of the research behind the sibling platforms (inherited). It
  was re-confirmed structurally for this port: the fetched
  `sun50i-h618-orangepi-zero3.dts` and its shared dtsi carry no
  `&hdmi`/`&tcon`/`&mixer`/display-engine node of any kind.
  - `drivers/gpu/drm/sun4i/` (torvalds/linux, `master`) has driver files for the
    OLDER sun4i/sun6i/sun8i DE2/DE3-class hardware (`sun8i_mixer.c`,
    `sun8i_dw_hdmi.c`, `sun8i_hdmi_phy.c`, ...) and **nothing** named
    `de33`/anything H616/H618-specific.
  - A Nov-2025-dated post on the DE33 mixer/CSC/plane-binding patch series
    called it "a second series out of tree". It said the patches for **a full
    display pipeline** (including HDMI) "will be sent once this series is
    merged".
  - Working HDMI on this board family exists only in Allwinner's own
    never-upstreamed legacy-BSP kernel fork (a **whole alternate kernel tree**),
    or in an **Armbian community backport** of the out-of-tree DE33 patch
    series. That backport's PR history (`armbian/build` #7752 + #7947 "BUGFIX:
    Remove the incomplete patch") shows **boot freezes** on this board family
    (Orange Pi Zero 2/**Zero 3**; this very board is named in that history), a
    GPU-power-domain hang, and a fix that **removed** the patch instead of
    stabilizing it.
- Carrying a whole alternate out-of-tree kernel for one board's display would
  cost far more, and break more easily, than anything else in this repo.
- WiFi (Unisoc UWE5622) is **also** out-of-tree only (inherited CONFIRMED
  finding: no mainline kernel.org driver at all).
- On the plus side, this board keeps the family's **fully open-source,
  blob-free boot chain**. Mainline U-Boot has **native**,
  community-reverse-engineered H616-family DRAM init, here in its LPDDR4 flavor
  (CONFIRMED for this board by fetching `orangepi_zero3_defconfig`:
  `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, native training parameters, no closed
  "boot0" blob at all, unlike Frite and Orange Pi 5, which need vendor blobs).
  Unlike the Zero 2W, it adds **onboard Gigabit Ethernet on a fully-mainline
  driver pair** (dwmac-sun8i + Motorcomm YT8531). That is the profile of a lean,
  hardened, **SSH-only network appliance**.

**If mainline Linux lands full DE33 display support** (watch the `dri-devel`
list and `linux-sunxi.org`'s H616/H618 pages), revisit this decision. Do not
keep building headless out of habit once that changes, and do not turn this
platform into a desktop role by copying another platform's GPU/X11 config
without re-confirming the display situation first.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi Zero 3.
The closest analogue in this repo is its own template,
`build-orangepi-zero2w-stage4.sh` (see the differences section above), and beyond
that `build-orangepi-zero2-stage4.sh` and `build-frite-stage4.sh --desktop
none`. There is no `--desktop`/`--role` toggle at all. It reuses the SAME
aarch64 cross toolchain and shared `specs/` mesh/provisioning/sshd plumbing as
every other client image: headscale/tailscale mesh join, hardened key-only sshd,
and KEYS-USB first-boot provisioning. It supports `--standalone` (local user over
SSH, no mesh, build-time password) and `--encrypt-root` (LUKS2 full-disk
encryption) from the start.

```sh
./build-orangepi-zero3-stage4.sh                              # both live+installer
./build-orangepi-zero3-stage4.sh --flavor live                 # live only
./build-orangepi-zero3-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi-zero3-stage4.sh --encrypt-root --print-plan   # dry-run plan (no root)
```

There is no `--board` axis either (Frite has 3 boards, Orange Pi 5 has 2). This
is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig` are
direct overrides, not entries in a board table.

## Boot chain (researched — see confidence notes)

```
Allwinner BootROM
  -> U-Boot SPL   (NATIVE H616-family LPDDR4 DRAM-init driver — NO blob. Same
                    property as the Zero 2/Zero 2W siblings:
                    Frite needs Amlogic FIP/BL31, Orange Pi 5 needs Rockchip
                    rkbin DDR-init + TF-A BL31 blobs. This board's mainline
                    U-Boot alone can train DRAM.)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD/USB) for /extlinux/extlinux.conf -- the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh use
```

U-Boot defconfig (CONFIRMED by fetching `configs/orangepi_zero3_defconfig` from
`u-boot/u-boot` upstream for THIS port): it contains
`CONFIG_DEFAULT_DEVICE_TREE="allwinner/sun50i-h618-orangepi-zero3"`,
`CONFIG_MACH_SUN50I_H616=y`, `CONFIG_DRAM_CLK=792`,
`CONFIG_DRAM_SUNXI_DX_ODT`/`DX_DRI`/`CA_DRI`/`ODT_EN`/`TPR6`/`TPR10`/`TPR11`/
`TPR12`, `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, `CONFIG_AXP313_POWER=y`, plus
`CONFIG_SUN8I_EMAC=y` + `CONFIG_PHY_MOTORCOMM=y` for the onboard GbE. These are
all **native training parameters**, with no blob reference of any kind. Mainline
kernel DTB (CONFIRMED by fetching `arch/arm64/boot/dts/allwinner/` upstream for
THIS port): `sun50i-h618-orangepi-zero3.dts` (model "OrangePi Zero3", compatible
`xunlong,orangepi-zero3`/`allwinner,sun50i-h618`; includes
`sun50i-h616-orangepi-zero.dtsi` + `sun50i-h616-cpu-opp.dtsi`). Serial debug
console (CONFIRMED against the fetched shared dtsi's own `chosen`/`aliases`
nodes: `aliases { serial0 = &uart0; }`,
`chosen { stdout-path = "serial0:115200n8"; }`): `ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **HDMI/display driver gap** — HIGH confidence, inherited from the Zero 2 and
   Zero 2W siblings' research (same DE33 engine). The absence of any display node
   was re-confirmed for this port by direct fetch of the DTS and shared dtsi. The
   most important finding in this port. Re-verify it before you revisit the
   headless-only decision; the Armbian boot-freeze history names the Zero 3
   explicitly.
2. **Boot chain / no-blob DRAM init** — HIGH confidence, re-confirmed for THIS
   board. We fetched `orangepi_zero3_defconfig` from the live upstream U-Boot
   tree and inspected its LPDDR4 DRAM-training symbols. No blob load or
   reference of any kind is present.
3. **Networking** — HIGH confidence, and DIFFERENT from the Zero 2W template:
   **onboard Gigabit Ethernet is back**. The fetched mainline DTS enables
   `&emac0` in `rgmii-rxid` mode against a Motorcomm YT8531 PHY on the shared
   dtsi's mdio node. The driver pair is fully mainline: `CONFIG_DWMAC_SUN8I` +
   `CONFIG_MOTORCOMM_PHY` (built by `kernel/hardened-appliance.config`).
   **VERIFY** at build time that the checked-out kernel's Motorcomm driver covers
   the YT8531 (it entered mainline later than the YT8511). The repo pins no
   gentoo-sources version (`specs-orangepi-zero3/portage/packages.list:24`), so
   the kernel is whatever Portage resolves at build time. The check matters most
   for custom `--defconfig` overrides.
4. **WiFi** — CONFIRMED gap (inherited). The onboard Unisoc UWE5622 module
   (identity per the vendor's own spec sheet for this board) has **no mainline
   kernel.org driver at all**. This appliance ships **no** onboard-radio kernel
   module (see `kernel/hardened-appliance.config`). A USB WiFi/Bluetooth dongle
   with its OWN mainlined driver would still work. `harden_radios()` in the
   builder blacklists the generic cfg80211/mac80211/bluetooth/btusb modules by
   default regardless. Onboard Ethernet and the tailnet are this appliance's
   primary, reliable path.
5. **Storage** — HIGH confidence. No eMMC, no NVMe/PCIe on this SoC tier.
   microSD (or USB) is the only persistent storage class. The onboard **16MB SPI
   NOR** (per the vendor's spec sheet; same size as the Zero 2W's) is
   bootloader-sized. It can carry U-Boot itself (`--write-uboot-spi` in the
   installer), never a rootfs.
6. **CPU / hardware crypto** — HIGH confidence. The H618 is a quad-core
   Cortex-A53 (no big.LITTLE split; an H616 die revision with a larger L2
   cache). So `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions) applies
   as on the siblings: a guaranteed CPU-instruction AES accelerator, used for
   LUKS2's `xts(aes)` cipher on `--encrypt-root` builds. We claim no dedicated
   hardware crypto *engine* for this SoC tier.
7. **RAM SKUs** — HIGH confidence. The board ships in 1GB/1.5GB/2GB/4GB LPDDR4
   SKUs. RAM is auto-detected and one image serves all of them. A zram swap is
   set up at first boot to help the smallest SKU, as on the siblings.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax. `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency: artifact names, kernel
fragment and effective flavor all agree). That the DTB and U-Boot-defconfig
values match upstream U-Boot/Linux naming, including a direct fetch of the
actual `orangepi_zero3_defconfig`, `sun50i-h618-orangepi-zero3.dts` and
`sun50i-h616-orangepi-zero.dtsi` files for this port. That this is a purely
additive new-platform change (no existing builder/specs tree touched). That it
reuses the shared `specs/` provisioning and mesh like every other client image.
Template rendering: LIVE emits `INITRD /initrd.img`, plaintext INSTALLER does
not, and `--encrypt-root` INSTALLER emits the disk-boot initramfs line. A hard
build-time guard refuses to ship a kernel with
`CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE` set, which protects the headless-only
scope from an accidental regression.

**NEEDS REAL HARDWARE (or at least a full Gentoo cross-build environment, which
this sandbox lacks):** the aarch64 cross-emerge of this package set against THIS
platform's package/USE set. The mainline kernel build, and whether the in-tree
H618 DTB name above still matches the gentoo-sources version checked out.
Whether a microSD/USB-written LIVE/INSTALLER image boots via distro-boot on real
hardware. Whether the `orangepi_zero3_defconfig` DRAM-training parameters work
across EVERY RAM SKU (1GB/1.5GB/2GB/4GB LPDDR4). The crypto/LUKS2 read/write
path. The onboard GbE linking and passing traffic on the YT8531 PHY, including
the `CONFIG_MOTORCOMM_PHY` binding. Whether the board's boot-select behavior
prefers the onboard SPI NOR or the microSD byte-offset U-Boot location (both are
plausible sunxi conventions, and neither could be checked without hardware).
These steps MIRROR the proven Frite/Orange-Pi-5 flow (through the Zero 2W
template) but cannot be tested end to end here: no board and no full Gentoo
builder. Network access here was enough to fetch upstream source files, NOT to
run a real cross-emerge.

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module names the mapper
   device `luks-<uuid>` instead of the name `root=` expects (`cryptroot`), and
   `root=/dev/mapper/cryptroot` never resolves. `install-orangepi-zero3.sh` sets
   both, mirroring Frite, RPi5, Orange Pi 5, the Zero 2 and the Zero 2W. (The
   Jetson builder has the same code, but it refuses `--encrypt-root`.)
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows the Zero 2W's/Zero 2's/Frite's/Orange-Pi-5's **on-device**
   model, not RPi5's **cross-host** model. `install-orangepi-zero3.sh` runs from
   WITHIN the booted LIVE/INSTALLER session, ON the Orange Pi Zero 3 that will
   unlock the root at every boot. So cryptsetup's argon2id auto-benchmark is
   trustworthy and deliberately NOT pinned. If operators for this board turn out
   to `dd` the image from a PC and never live-boot the installer ON the board,
   the call must flip to the pinned model. The sibling READMEs flag the same
   risk. Next reviewer: check this.

## Single storage class — no eMMC, no NVMe

Frite has an eMMC module or microSD, and Orange Pi 5 has eMMC, microSD or NVMe.
This board has exactly **one** persistent storage class: microSD (or USB). There
is no "boot from USB, install to eMMC" split. `install-orangepi-zero3.sh`
installs to a **second** microSD/USB device (the safer choice: the LIVE medium
stays bootable as a rescue disk) **or** to the **same** device the LIVE image
booted from. The live session runs entirely from a squashfs+tmpfs overlay in
RAM, so repartitioning the boot medium under it does not corrupt the running
session. The installer asks for an extra confirmation on a same-device install
but does not block it. This is **untested on real hardware**; see the checklist
below.

## Front-end wiring (all-options-in-all-menus)

Under the all-options-in-all-menus rule: `make orangepizero3`,
`make orangepizero3-live` and `make orangepizero3-installer` (the same
single-dedicated-platform pattern as `frite`/`orangepi5`/`orangepizero2`/
`orangepizero2w`, not a role loop); `scripts/build-menu.sh`'s architecture picker
and a dedicated flavor screen (no board sub-menu, because there is one board);
the Studio (`studio/hugmesh_studio/core/config.py`'s
`BUILDER_SCRIPTS`/`ROLE_CHOICES`/`_orangepizero3_args()`, labelled as a
**headless appliance**, not a desktop); and `tests/build-matrix/matrix.tsv` +
`check.sh`. All of them reach this platform through the same `--print-plan`
contract as every other builder.

## Hardware-validation checklist (flip Status when done)

1. Assemble/obtain a real U-Boot build for `orangepi_zero3_defconfig` and
   confirm it boots to a serial console (`ttyS0,115200`) with NO blob — this is
   the platform family's headline claim and the first thing to actually prove.
2. Boot the LIVE image off microSD/USB on a real Orange Pi Zero 3; confirm
   the dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi-zero3.sh` against a microSD card (both the
   same-device and second-device paths) and confirm the installed system boots
   — PLAINTEXT first, then `--encrypt-root`.
4. Confirm the onboard Gigabit Ethernet actually links and passes traffic —
   i.e. that the checked-out kernel's `CONFIG_MOTORCOMM_PHY` driver binds the
   YT8531 and the dwmac-sun8i RGMII timing (`rgmii-rxid`, 700ps tx-delay from
   the DTS) is right on real silicon — load-bearing for an SSH-only appliance.
5. Confirm the board really has no usable HDMI output on this kernel (i.e.
   confirm the headless-only decision is still correct) — and if mainline DE33
   support has landed since this research, flag it prominently for a scope
   revisit rather than silently continuing headless.
6. Confirm the DRAM-init training parameters in `orangepi_zero3_defconfig`
   actually work across all four RAM SKUs (1GB/1.5GB/2GB/4GB LPDDR4).
7. Confirm whether this board's boot-select behavior prefers the onboard 16MB
   SPI NOR or a fixed microSD byte offset for U-Boot (both `--write-uboot-spi`
   and a from-source U-Boot cross-build are realistic next steps given the
   no-blob boot chain).

## Cross-references
- The template this platform is derived from (same-SoC H618 sibling, nearest
  possible analogue; read its README alongside this one):
  `specs-orangepi-zero2w/README.md`.
- The family's H616 grandparent (whose shared dtsi this board's DTS includes,
  and whose onboard-GbE Ethernet-first posture this board restores):
  `specs-orangepi-zero2/README.md`.
- Closest architectural sibling for the mesh/provisioning/SSH plumbing:
  `build-frite-stage4.sh`'s `DESKTOP=none` headless-base code path.
- Closest architectural sibling for the LUKS on-device model and the
  confidence-graded README structure: `specs-orangepi5/README.md`.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
