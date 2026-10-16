# specs-orangepi-zero2w — Orange Pi Zero 2W (Allwinner H618, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> Zero 2W has ever booted an image produced by this repo. Every H618 fact below
> (DTB and U-Boot defconfig names, kernel Kconfig symbols, driver maturity and,
> above all, the HDMI/display-driver gap) is one of two kinds. Either it was
> **researched by fetching the live mainline Linux and U-Boot upstream source
> trees** (the board's own DTS and U-Boot defconfig were re-fetched for THIS
> port), or it is **inherited from the Zero 2 sibling's research**
> (`specs-orangepi-zero2/README.md`). The H618 is an H616 die revision with a
> larger L2 cache, and mainline treats both through the same H616 platform
> support. Each inherited claim is marked as such. Nothing is **verified on
> hardware**; there is no H618 hardware in this sandbox. Treat it like
> `specs-jetson/` and `specs-orangepi5/`, which are also unvalidated. It builds
> and is internally consistent (`--print-plan` is clean across the whole flag
> matrix), but **do not trust it to boot** until a real board confirms it end to
> end.

## How this differs from the Zero 2 template (read this before trusting any inherited claim)

This platform is a faithful derivation of `specs-orangepi-zero2` +
`build-orangepi-zero2-stage4.sh` (the H616 sibling, the nearest possible
template). These are the differences, all verified for this port unless marked
inherited:

- **SoC: H618, not H616.** An H616 die revision with a larger L2 cache (1MB).
  Mainline U-Boot handles it with the SAME machine support
  (`CONFIG_MACH_SUN50I_H616=y`, CONFIRMED by fetching the live
  `configs/orangepi_zero2w_defconfig`). The mainline kernel DTS includes the
  SAME `sun50i-h616.dtsi` (CONFIRMED by fetching the live
  `sun50i-h618-orangepi-zero2w.dts`). So everything the sibling's research says
  about the H616's display engine (DE33) applies unchanged, and the
  headless-only decision carries over.
- **RAM: LPDDR4, not DDR3.** SKUs are 1GB/1.5GB/2GB/4GB LPDDR4 (no 512MB SKU).
  The U-Boot defconfig selects `CONFIG_SUNXI_DRAM_H616_LPDDR4=y` +
  `CONFIG_DRAM_CLK=792` + native `CONFIG_DRAM_SUNXI_TPR*` training parameters
  (CONFIRMED by direct fetch). It is still **fully native, no blob**, so the
  sibling's blob-free boot chain survives the RAM change.
- **NO onboard Ethernet — the biggest functional difference.** The Zero 2 pairs
  the H616 EMAC with an onboard RTL8211F PHY for Gigabit Ethernet. The Zero 2W
  **dropped the Ethernet jack**. CONFIRMED: the mainline
  `sun50i-h618-orangepi-zero2w.dts` has **no** `&emac`/ethernet node of any
  kind. The vendor's optional 24-pin expansion board adds a 100M port, but
  mainline does not wire that up either. So the sibling's blob-free
  boot+**network** chain becomes a blob-free **boot** chain here, and this
  appliance is **USB-Ethernet-first**. The kernel fragment builds the common
  fully-mainline USB Ethernet adapter drivers (usbnet/CDC-ECM/CDC-NCM,
  RTL8152/8153, AX88179) in place of the sibling's onboard-EMAC config, which
  would be dead config on this board.
- **PMIC: AXP313** (`CONFIG_AXP313_POWER=y` in the fetched defconfig), a
  different regulator arrangement than the Zero 2's. It matters only at the
  U-Boot level; no builder knob depends on it.
- **Storage: 16MB SPI NOR** (bootloader-sized, U-Boot only) instead of the Zero
  2's 2MiB part. Still no eMMC and no NVMe/PCIe. microSD/USB remains the ONLY
  persistent storage class, so the single-storage-class installer model carries
  over.
- **USB: 2x USB2 Type-C** (one power/OTG, one host) instead of the Zero 2's
  USB-A + OTG micro port. The same musb/ehci/ohci sunxi symbol set applies
  (inherited).
- **WiFi/BT: same gap.** A Unisoc UWE5622 combo module (the same die as the Zero
  2's "AW859A" package; module identity is per the vendor's own spec sheet). The
  sibling's CONFIRMED finding that no mainline kernel.org driver exists applies
  here too (inherited).
- **Board constants:** DTB `allwinner/sun50i-h618-orangepi-zero2w.dtb`; U-Boot
  defconfig `orangepi_zero2w_defconfig` (both CONFIRMED by direct fetch of the
  live upstream trees for this port). Serial console `ttyS0,115200` (CONFIRMED
  against the fetched DTS's own `aliases`/`chosen` nodes).

Everything else is deliberately near-identical to the template: the flavor axis,
the standalone/encrypt-root posture, the on-device LUKS model, the package set,
the hardened kernel posture and the no-desktop-ever scope. Do not "fix" a
difference between the two trees without checking which board it belongs to.

## Why this is a platform with no desktop option — read this first

Frite, Orange Pi 5, Orange Pi 4 LTS, the RPi5 desktop role and the Jetson
desktop role ship a lean LXDE-class desktop. This one does not, and never will.
The reason is concrete and researched. It is not neglect. The trail below is the
Zero 2 sibling's research. It applies verbatim, because the H618 carries the
SAME DE33 display engine and the Zero 2W's own DTS includes the same
`sun50i-h616.dtsi`:

- The board **does** have a physical Mini-HDMI port. This is **not** a "no
  video hardware" situation.
- Mainline Linux has **zero display-driver support** for the H616/H618 display
  engine (DE33) as of the research behind the sibling platform (inherited). It
  was re-confirmed structurally for this port: the fetched
  `sun50i-h618-orangepi-zero2w.dts` includes `sun50i-h616.dtsi`, which has no
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
    (Orange Pi Zero 2/Zero 3, the same H616/H618 DE33 generation as the Zero
    2W), a GPU-power-domain hang, and a fix that **removed** the patch instead
    of stabilizing it.
- Carrying a whole alternate out-of-tree kernel for one board's display would
  cost far more, and break more easily, than anything else in this repo.
- WiFi (Unisoc UWE5622) is **also** out-of-tree only (inherited CONFIRMED
  finding: no mainline kernel.org driver at all).
- On the plus side, this board keeps the family's **fully open-source,
  blob-free boot chain**. Mainline U-Boot has **native**,
  community-reverse-engineered H616-family DRAM init, here in its LPDDR4 flavor
  (CONFIRMED for this board by fetching `orangepi_zero2w_defconfig`:
  `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, native training parameters, no closed
  "boot0" blob at all, unlike Frite and Orange Pi 5, which need vendor blobs).
  It is an even tinier, cheaper and lower-power board than the Zero 2. It is
  still a good lean, hardened, **SSH-only network appliance**. The catch is that
  wired networking now needs a USB Ethernet adapter (or the expansion board).

**If mainline Linux lands full DE33 display support** (watch the `dri-devel`
list and `linux-sunxi.org`'s H616/H618 pages), revisit this decision. Do not
keep building headless out of habit once that changes, and do not turn this
platform into a desktop role by copying another platform's GPU/X11 config
without re-confirming the display situation first.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi Zero 2W.
The closest analogue in this repo is its own template,
`build-orangepi-zero2-stage4.sh` (see the differences section above), and beyond
that `build-frite-stage4.sh --desktop none`. There is no `--desktop`/`--role`
toggle at all. It reuses the SAME aarch64 cross toolchain and shared `specs/`
mesh/provisioning/sshd plumbing as every other client image: headscale/tailscale
mesh join, hardened key-only sshd, and KEYS-USB first-boot provisioning. It
supports `--standalone` (local user over SSH, no mesh, build-time password) and
`--encrypt-root` (LUKS2 full-disk encryption) from the start.

```sh
./build-orangepi-zero2w-stage4.sh                              # both live+installer
./build-orangepi-zero2w-stage4.sh --flavor live                 # live only
./build-orangepi-zero2w-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi-zero2w-stage4.sh --encrypt-root --print-plan   # dry-run plan (no root)
```

There is no `--board` axis either (Frite has 3 boards, Orange Pi 5 has 2). This
is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig` are
direct overrides, not entries in a board table.

## Boot chain (researched — see confidence notes)

```
Allwinner BootROM
  -> U-Boot SPL   (NATIVE H616-family LPDDR4 DRAM-init driver — NO blob. Same
                    property as the Zero 2 sibling: Frite needs
                    Amlogic FIP/BL31, Orange Pi 5 needs Rockchip rkbin
                    DDR-init + TF-A BL31 blobs. This board's mainline U-Boot
                    alone can train DRAM.)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD/USB) for /extlinux/extlinux.conf -- the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh use
```

U-Boot defconfig (CONFIRMED by fetching `configs/orangepi_zero2w_defconfig` from
`u-boot/u-boot` upstream for THIS port): it contains
`CONFIG_DEFAULT_DEVICE_TREE="allwinner/sun50i-h618-orangepi-zero2w"`,
`CONFIG_MACH_SUN50I_H616=y`, `CONFIG_DRAM_CLK=792`,
`CONFIG_DRAM_SUNXI_DX_ODT`/`DX_DRI`/`CA_DRI`/`ODT_EN`/`TPR6`/`TPR10`/`TPR11`/
`TPR12`, `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, `CONFIG_AXP313_POWER=y`. These are
all **native training parameters**, with no blob reference of any kind. Mainline
kernel DTB (CONFIRMED by fetching `arch/arm64/boot/dts/allwinner/` upstream for
THIS port): `sun50i-h618-orangepi-zero2w.dts` (model "OrangePi Zero 2W",
compatible `xunlong,orangepi-zero2w`/`allwinner,sun50i-h618`; includes
`sun50i-h616.dtsi` + `sun50i-h616-cpu-opp.dtsi`). Serial debug console
(CONFIRMED against the fetched DTS's own `chosen`/`aliases` nodes:
`aliases { serial0 = &uart0; }`, `chosen { stdout-path = "serial0:115200n8"; }`):
`ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **HDMI/display driver gap** — HIGH confidence, inherited from the Zero 2
   sibling's research (same DE33 engine, same `sun50i-h616.dtsi`; the include
   was re-confirmed for this port by direct fetch). The most important finding
   in this port. Re-verify it before you revisit the headless-only decision.
2. **Boot chain / no-blob DRAM init** — HIGH confidence, re-confirmed for THIS
   board. We fetched `orangepi_zero2w_defconfig` from the live upstream U-Boot
   tree and inspected its LPDDR4 DRAM-training symbols. No blob load or
   reference of any kind is present.
3. **Networking** — HIGH confidence, and DIFFERENT from the sibling: **no
   onboard Ethernet at all**. The fetched mainline DTS has no `&emac`/ethernet
   node, and vendor specs list Ethernet only on the optional 24-pin expansion
   board (100M). Wired networking is a **USB Ethernet adapter** with its own
   mainline driver (usbnet/CDC classes, RTL8152/8153, AX88179, all built by
   `kernel/hardened-appliance.config`). **VERIFY** that the adapter you deploy
   binds on the kernel checked out at build time.
4. **WiFi** — CONFIRMED gap (inherited). The onboard Unisoc UWE5622 die (the
   same die as the Zero 2's "AW859A" module) has **no mainline kernel.org driver
   at all**. This appliance ships **no** onboard-radio kernel module (see
   `kernel/hardened-appliance.config`). A USB WiFi/Bluetooth dongle with its OWN
   mainlined driver would still work. `harden_radios()` in the builder
   blacklists the generic cfg80211/mac80211/bluetooth/btusb modules by default
   regardless. USB Ethernet and the tailnet are this appliance's primary,
   reliable path.
5. **Storage** — HIGH confidence. No eMMC, no NVMe/PCIe on this SoC tier.
   microSD (or USB) is the only persistent storage class. The onboard **16MB SPI
   NOR** (larger than the Zero 2's 2MiB part) is bootloader-sized. It can carry
   U-Boot itself (`--write-uboot-spi` in the installer), never a rootfs.
6. **CPU / hardware crypto** — HIGH confidence. The H618 is a quad-core
   Cortex-A53 (no big.LITTLE split; an H616 die revision with a larger L2
   cache). So `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions) applies
   as on the sibling: a guaranteed CPU-instruction AES accelerator, used for
   LUKS2's `xts(aes)` cipher on `--encrypt-root` builds. We claim no dedicated
   hardware crypto *engine* for this SoC tier.
7. **RAM SKUs** — HIGH confidence. The board ships in 1GB/1.5GB/2GB/4GB LPDDR4
   SKUs. RAM is auto-detected and one image serves all of them. A zram swap is
   set up at first boot to help the smallest SKU, as on the sibling.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax. `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency: artifact names, kernel
fragment and effective flavor all agree). That the DTB and U-Boot-defconfig
values match upstream U-Boot/Linux naming, including a direct fetch of the
actual `orangepi_zero2w_defconfig` and `sun50i-h618-orangepi-zero2w.dts` files
for this port. That this is a purely additive new-platform change (no existing
builder/specs tree touched). That it reuses the shared `specs/` provisioning and
mesh like every other client image. Template rendering: LIVE emits
`INITRD /initrd.img`, plaintext INSTALLER does not, and `--encrypt-root`
INSTALLER emits the disk-boot initramfs line. A hard build-time guard refuses to
ship a kernel with `CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE` set, which protects
the headless-only scope from an accidental regression.

**NEEDS REAL HARDWARE (or at least a full Gentoo cross-build environment, which
this sandbox lacks):** the aarch64 cross-emerge of this package set against THIS
platform's package/USE set. The mainline kernel build, and whether the in-tree
H618 DTB name above still matches the gentoo-sources version checked out.
Whether a microSD/USB-written LIVE/INSTALLER image boots via distro-boot on real
hardware. Whether the `orangepi_zero2w_defconfig` DRAM-training parameters work
across EVERY RAM SKU (1GB/1.5GB/2GB/4GB LPDDR4). The crypto/LUKS2 read/write
path. A USB Ethernet adapter linking and passing traffic. Whether the board's
boot-select behavior prefers the onboard SPI NOR or the microSD byte-offset
U-Boot location (both are plausible sunxi conventions, and neither could be
checked without hardware). These steps MIRROR the proven Frite/Orange-Pi-5 flow
(through the Zero 2 template) but cannot be tested end to end here: no board and
no full Gentoo builder. Network access here was enough to fetch upstream source
files, NOT to run a real cross-emerge.

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module names the mapper
   device `luks-<uuid>` instead of the name `root=` expects (`cryptroot`), and
   `root=/dev/mapper/cryptroot` never resolves. `install-orangepi-zero2w.sh`
   sets both, mirroring Frite, RPi5, Orange Pi 5 and the Zero 2. (The Jetson
   builder has the same code, but it refuses `--encrypt-root`.)
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows the Zero 2's/Frite's/Orange-Pi-5's **on-device** model, not
   RPi5's **cross-host** model. `install-orangepi-zero2w.sh` runs from WITHIN the
   booted LIVE/INSTALLER session, ON the Orange Pi Zero 2W that will unlock the
   root at every boot. So cryptsetup's argon2id auto-benchmark is trustworthy
   and deliberately NOT pinned. If operators for this board turn out to `dd` the
   image from a PC and never live-boot the installer ON the board, the call must
   flip to the pinned model. The sibling READMEs flag the same risk. Next
   reviewer: check this.

## Single storage class — no eMMC, no NVMe

Frite has an eMMC module or microSD, and Orange Pi 5 has eMMC, microSD or NVMe.
This board has exactly **one** persistent storage class: microSD (or USB). There
is no "boot from USB, install to eMMC" split. `install-orangepi-zero2w.sh`
installs to a **second** microSD/USB device (the safer choice: the LIVE medium
stays bootable as a rescue disk) **or** to the **same** device the LIVE image
booted from. The live session runs entirely from a squashfs+tmpfs overlay in
RAM, so repartitioning the boot medium under it does not corrupt the running
session. The installer asks for an extra confirmation on a same-device install
but does not block it. This is **untested on real hardware**; see the checklist
below.

## Front-end wiring (all-options-in-all-menus)

Under the all-options-in-all-menus rule: `make orangepizero2w`,
`make orangepizero2w-live` and `make orangepizero2w-installer` (the same
single-dedicated-platform pattern as `frite`/`orangepi5`/`orangepizero2`, not a
role loop); `scripts/build-menu.sh`'s architecture picker and a dedicated flavor
screen (no board sub-menu, because there is one board); the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepizero2w_args()`, labelled as a **headless appliance**, not a desktop);
and `tests/build-matrix/matrix.tsv` + `check.sh`. All of them reach this platform
through the same `--print-plan` contract as every other builder.

## Hardware-validation checklist (flip Status when done)

1. Assemble/obtain a real U-Boot build for `orangepi_zero2w_defconfig` and
   confirm it boots to a serial console (`ttyS0,115200`) with NO blob — this is
   the platform family's headline claim and the first thing to actually prove.
2. Boot the LIVE image off microSD/USB on a real Orange Pi Zero 2W; confirm
   the dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi-zero2w.sh` against a microSD card (both the
   same-device and second-device paths) and confirm the installed system boots
   — PLAINTEXT first, then `--encrypt-root`.
4. Confirm a USB Ethernet adapter (RTL8152/8153- or AX88179-class, and the
   generic CDC classes) actually links and passes traffic — this board has NO
   onboard Ethernet, so this replaces the sibling's onboard-GbE checklist item
   and is load-bearing for an SSH-only appliance.
5. Confirm the board really has no usable HDMI output on this kernel (i.e.
   confirm the headless-only decision is still correct) — and if mainline DE33
   support has landed since this research, flag it prominently for a scope
   revisit rather than silently continuing headless.
6. Confirm the DRAM-init training parameters in `orangepi_zero2w_defconfig`
   actually work across all four RAM SKUs (1GB/1.5GB/2GB/4GB LPDDR4).
7. Confirm whether this board's boot-select behavior prefers the onboard 16MB
   SPI NOR or a fixed microSD byte offset for U-Boot (both `--write-uboot-spi`
   and a from-source U-Boot cross-build are realistic next steps given the
   no-blob boot chain).

## Cross-references
- The template this platform is derived from (H616 sibling, nearest possible
  analogue; read its README alongside this one): `specs-orangepi-zero2/README.md`.
- Closest architectural sibling for the mesh/provisioning/SSH plumbing:
  `build-frite-stage4.sh`'s `DESKTOP=none` headless-base code path.
- Closest architectural sibling for the LUKS on-device model and the
  confidence-graded README structure: `specs-orangepi5/README.md`.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
