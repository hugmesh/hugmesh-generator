# specs-orangepi-zero2w — Orange Pi Zero 2W (Allwinner H618, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> Zero 2W has ever booted an image produced by this repo. Every H618-specific
> fact below (DTB/U-Boot-defconfig names, kernel Kconfig symbols, driver
> maturity, and — most importantly — the HDMI/display-driver gap) is either
> **researched by directly fetching the live mainline Linux/U-Boot upstream
> source trees** (the board's own DTS and U-Boot defconfig were re-fetched and
> re-confirmed for THIS port) or **inherited from the Zero 2 sibling's research**
> (`specs-orangepi-zero2/README.md` — the H618 is an H616 die revision with a
> larger L2 cache; mainline treats both via the same H616 platform support, and
> each inherited claim is marked as such below). **Not hardware-verified in
> this environment** — there is no H618 hardware available in this sandbox.
> Treat this exactly like `specs-jetson/`/`specs-orangepi5/` were treated
> and are also unvalidated: buildable and internally
> consistent (`--print-plan` clean across the whole flag matrix), but **do not
> trust it to boot** until a real board confirms it end-to-end.

## How this differs from the Zero 2 template (read this before trusting any inherited claim)

This platform is a deliberate, faithful derivation of `specs-orangepi-zero2` +
`build-orangepi-zero2-stage4.sh` (the H616 sibling — the nearest possible
template). The honest deltas, all verified for this port unless marked
inherited:

- **SoC: H618, not H616.** An H616 die revision with a larger L2 cache (1MB).
  Mainline U-Boot handles it via the SAME machine support
  (`CONFIG_MACH_SUN50I_H616=y` — CONFIRMED by fetching the live
  `configs/orangepi_zero2w_defconfig`), and the mainline kernel DTS includes
  the SAME `sun50i-h616.dtsi` (CONFIRMED by fetching the live
  `sun50i-h618-orangepi-zero2w.dts`). Everything the sibling's research says
  about the H616's display engine (DE33) therefore applies unchanged — the
  headless-only scope decision carries over intact.
- **RAM: LPDDR4, not DDR3.** SKUs are 1GB/1.5GB/2GB/4GB LPDDR4 (no 512MB SKU).
  The U-Boot defconfig selects `CONFIG_SUNXI_DRAM_H616_LPDDR4=y` +
  `CONFIG_DRAM_CLK=792` + native `CONFIG_DRAM_SUNXI_TPR*` training parameters
  (CONFIRMED by direct fetch) — still **fully native, no blob**, so the
  sibling's headline blob-free-boot-chain claim survives the RAM change.
- **NO onboard Ethernet — the biggest functional difference.** The Zero 2
  pairs the H616 EMAC with an onboard RTL8211F PHY for Gigabit Ethernet; the
  Zero 2W **dropped the Ethernet jack entirely**. CONFIRMED: the mainline
  `sun50i-h618-orangepi-zero2w.dts` has **no** `&emac`/ethernet node of any
  kind. The vendor's optional 24-pin expansion board adds a 100M port, but
  mainline does not wire that up either. So the sibling's "blob-free
  boot+**network** chain" claim honestly degrades to a blob-free **boot**
  chain here, and this appliance is **USB-Ethernet-first**: the kernel
  fragment builds the common fully-mainline USB Ethernet adapter drivers
  (usbnet/CDC-ECM/CDC-NCM, RTL8152/8153, AX88179) instead of the sibling's
  onboard-EMAC config (which would be dead config on this board).
- **PMIC: AXP313** (`CONFIG_AXP313_POWER=y` in the fetched defconfig) — a
  different regulator arrangement than the Zero 2's. Boot-relevant only at
  the U-Boot level; no builder knob depends on it.
- **Storage: 16MB SPI NOR** (bootloader-sized, U-Boot only) instead of the
  Zero 2's 2MiB part; still no eMMC and no NVMe/PCIe — microSD/USB remains the
  ONLY persistent storage class, so the single-storage-class installer model
  carries over unchanged.
- **USB: 2x USB2 Type-C** (one power/OTG, one host) instead of the Zero 2's
  USB-A + OTG micro port. Same musb/ehci/ohci sunxi symbol set (inherited).
- **WiFi/BT: same gap.** A Unisoc UWE5622 combo module (the same die as the
  Zero 2's "AW859A" package) — the sibling's CONFIRMED finding that no
  mainline kernel.org driver exists applies to this board too (inherited; the
  module identity is per the vendor's own spec sheet).
- **Board constants:** DTB `allwinner/sun50i-h618-orangepi-zero2w.dtb`; U-Boot
  defconfig `orangepi_zero2w_defconfig` (both CONFIRMED by direct fetch of the
  live upstream trees for this port). Serial console `ttyS0,115200`
  (CONFIRMED against the fetched DTS's own `aliases`/`chosen` nodes).

Everything else — flavor axis, standalone/encrypt-root posture, on-device LUKS
model, package set, hardened kernel posture, no-desktop-ever scope — is
intentionally byte-similar to the template; do not "fix" a difference between
the two trees without checking which board it actually belongs to.

## Why this is a platform with no desktop option — read this first

Frite, Orange Pi 5, Orange Pi 4 LTS, the RPi5 desktop role and the Jetson
desktop role ship a lean LXDE-class desktop. This one does not, and never will,
for a concrete, researched reason — not because
nobody got around to it (the trail below is the Zero 2 sibling's research; it
applies verbatim because the H618 carries the SAME DE33 display engine and the
Zero 2W's own DTS includes the same `sun50i-h616.dtsi`):

- The board **does** have a physical Mini-HDMI port. This is **not** a "no
  video hardware" situation.
- Mainline Linux has **zero display-driver support** for the H616/H618 display
  engine (DE33) as of the research behind the sibling platform (inherited;
  re-confirmed structurally for this port: the fetched
  `sun50i-h618-orangepi-zero2w.dts` includes `sun50i-h616.dtsi`, which has
  no `&hdmi`/`&tcon`/`&mixer`/display-engine node of any kind):
  - `drivers/gpu/drm/sun4i/` (torvalds/linux, `master`) ships driver files for
    the OLDER sun4i/sun6i/sun8i DE2/DE3-class hardware (`sun8i_mixer.c`,
    `sun8i_dw_hdmi.c`, `sun8i_hdmi_phy.c`, ...) and **nothing** named
    `de33`/anything H616/H618-specific.
  - The dedicated DE33 mixer/CSC/plane-binding patch series was, as of a
    Nov-2025-dated post on the series itself, still **"a second series out of
    tree"**, with the remaining patches for **a full display pipeline**
    (including HDMI) explicitly described as "will be sent once this series is
    merged".
  - The only place working HDMI on this board family exists at all is
    Allwinner's own never-upstreamed legacy-BSP kernel fork (a **whole
    alternate kernel tree**), or an **Armbian community backport** of the
    out-of-tree DE33 patch series — whose own PR history (`armbian/build`
    #7752 + #7947 "BUGFIX: Remove the incomplete patch") shows **boot
    freezes** on this exact board family (Orange Pi Zero 2/Zero 3 — the same
    H616/H618 DE33 generation as the Zero 2W), a GPU-power-domain hang, and a
    fix that **removed** the problematic patch rather than stabilizing it.
- Carrying an entire alternate out-of-tree kernel just for one board's display
  would be a materially heavier, more fragile commitment than every other
  platform in this repo requires.
- WiFi (Unisoc UWE5622) is **also** out-of-tree-only (inherited CONFIRMED
  finding — no mainline kernel.org driver at all).
- Countervailing strength: this board keeps the family's **genuinely fully
  open-source, blob-free boot chain** — mainline U-Boot has **native**,
  community-reverse-engineered H616-family DRAM init, here in its LPDDR4
  flavor (CONFIRMED for this exact board by fetching
  `orangepi_zero2w_defconfig`: `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, native
  training parameters, no closed "boot0" blob at all, unlike Frite and Orange Pi 5, which need
  vendor blobs). It is an even tinier/cheaper/lower-power board
  than the Zero 2. That is still the profile of a good, lean, hardened,
  **SSH-only network appliance** — with the honest caveat that wired
  networking now needs a USB Ethernet adapter (or the expansion board).

**If mainline Linux ever lands full DE33 display support** (watch the
`dri-devel` list / `linux-sunxi.org`'s H616/H618 pages), this scope decision
should be **revisited** — do not silently keep building headless out of habit
once that changes; and do not "fix" this platform into a desktop role by
copy-pasting another platform's GPU/X11 config without re-confirming the
display situation first.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi Zero
2W — architecturally the closest analogue in this repo is its own template,
`build-orangepi-zero2-stage4.sh` (see the delta section above), and beyond
that `build-frite-stage4.sh --desktop none`. There is no `--desktop`/`--role`
toggle here at all. Reuses the SAME aarch64 cross toolchain + shared `specs/`
mesh/provisioning/sshd plumbing as every other client image: headscale/
tailscale mesh join, hardened key-only sshd, KEYS-USB first-boot provisioning,
and — from day one — full `--standalone` (local user over SSH, no mesh,
build-time password) and `--encrypt-root` (LUKS2 full-disk encryption)
support.

```sh
./build-orangepi-zero2w-stage4.sh                              # both live+installer
./build-orangepi-zero2w-stage4.sh --flavor live                 # live only
./build-orangepi-zero2w-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi-zero2w-stage4.sh --encrypt-root --print-plan   # dry-run plan (no root)
```

No `--board` axis either (unlike Frite's 3 boards / Orange Pi 5's 2 boards):
this is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig`
are direct overrides rather than entries in a board table.

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

U-Boot defconfig (CONFIRMED by fetching the live file from `u-boot/u-boot`
upstream `configs/orangepi_zero2w_defconfig` for THIS port): contains
`CONFIG_DEFAULT_DEVICE_TREE="allwinner/sun50i-h618-orangepi-zero2w"`,
`CONFIG_MACH_SUN50I_H616=y`, `CONFIG_DRAM_CLK=792`,
`CONFIG_DRAM_SUNXI_DX_ODT`/`DX_DRI`/`CA_DRI`/`ODT_EN`/`TPR6`/`TPR10`/`TPR11`/
`TPR12`, `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, `CONFIG_AXP313_POWER=y` — all
**native training parameters**, no blob reference of any kind. Mainline kernel
DTB (CONFIRMED by fetching `arch/arm64/boot/dts/allwinner/` upstream for THIS
port): `sun50i-h618-orangepi-zero2w.dts` (model "OrangePi Zero 2W", compatible
`xunlong,orangepi-zero2w`/`allwinner,sun50i-h618`; includes `sun50i-h616.dtsi`
+ `sun50i-h616-cpu-opp.dtsi`). Serial debug console (CONFIRMED against the
fetched DTS's own `chosen`/`aliases` nodes: `aliases { serial0 = &uart0; }`,
`chosen { stdout-path = "serial0:115200n8"; }`): `ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **HDMI/display driver gap** — HIGH confidence, inherited from the Zero 2
   sibling's research (same DE33 engine, same `sun50i-h616.dtsi` — the
   inclusion re-confirmed for this port by direct fetch). The single most
   important, load-bearing finding in this port. Re-verify before ever
   revisiting the headless-only scope decision.
2. **Boot chain / no-blob DRAM init** — HIGH confidence, re-confirmed for THIS
   board: `orangepi_zero2w_defconfig` was fetched directly from the live
   upstream U-Boot tree and its LPDDR4 DRAM-training symbols inspected; no
   blob load/reference of any kind is present.
3. **Networking** — HIGH confidence, and DIFFERENT from the sibling: **no
   onboard Ethernet at all** (the fetched mainline DTS has no `&emac`/ethernet
   node; vendor specs list Ethernet only via the optional 24-pin expansion
   board, 100M). Wired networking is a **USB Ethernet adapter** with its own
   mainline driver (usbnet/CDC classes, RTL8152/8153, AX88179 — all fully
   mainline, built by `kernel/hardened-appliance.config`). **VERIFY** the
   exact adapter you deploy with actually binds on the checked-out kernel.
4. **WiFi** — CONFIRMED gap (inherited). The onboard Unisoc UWE5622 die (the
   same die the Zero 2's "AW859A" module carries) has **no mainline
   kernel.org driver at all**. This appliance ships **no** onboard-radio
   kernel module (see `kernel/hardened-appliance.config`). A USB
   WiFi/Bluetooth dongle with its OWN already-mainlined driver would still
   work; `harden_radios()` in the builder blacklists the generic
   cfg80211/mac80211/bluetooth/btusb modules by default regardless. USB
   Ethernet + the tailnet are this appliance's primary, reliable path.
5. **Storage** — HIGH confidence. No eMMC, no NVMe/PCIe on this SoC tier;
   microSD (or USB) is the only persistent storage class. The onboard **16MB
   SPI NOR** (larger than the Zero 2's 2MiB part) is bootloader-sized — it can
   carry U-Boot itself (`--write-uboot-spi` in the installer), never a rootfs.
6. **CPU / hardware crypto** — HIGH confidence. H618 is a quad-core Cortex-A53
   (no big.LITTLE split; an H616 die revision with a larger L2 cache) — so
   `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions) applies exactly
   as on the sibling: a guaranteed CPU-instruction AES accelerator, used for
   LUKS2's `xts(aes)` cipher on `--encrypt-root` builds. No dedicated hardware
   crypto *engine* is claimed for this SoC tier.
7. **RAM SKUs** — HIGH confidence. This board ships in 1GB/1.5GB/2GB/4GB
   LPDDR4 SKUs (RAM is auto-detected, same image across all of them); a zram
   swap is configured at first boot to help the smallest SKU, same as the
   sibling.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax; `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency — reported artifact
names / kernel fragment / effective flavor all agree); that the DTB/U-Boot-
defconfig values match upstream U-Boot/Linux naming (including a direct fetch
of the actual `orangepi_zero2w_defconfig` and `sun50i-h618-orangepi-zero2w.dts`
files for this port, not just secondary claims); that this is a purely
additive new-platform change (no existing builder/specs tree touched); that it
reuses the shared `specs/` provisioning + mesh exactly like every other client
image; template rendering (LIVE emits `INITRD /initrd.img`, plaintext
INSTALLER does not, `--encrypt-root` INSTALLER emits the disk-boot initramfs
line); a hard build-time guard that refuses to ship a kernel with
`CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE` set (protects the headless-only
scope decision against an accidental future regression).

**NEEDS REAL HARDWARE (or at minimum a full Gentoo cross-build environment
this sandbox does not have) TO VERIFY:** the actual aarch64 cross-emerge of
this package set against THIS platform's package/USE set; the mainline kernel
build + whether the in-tree H618 DTB name above still matches whatever
gentoo-sources version is checked out; whether a microSD/USB-written LIVE/
INSTALLER image genuinely boots via distro-boot on real hardware; the
`orangepi_zero2w_defconfig` DRAM-training parameters actually working across
EVERY RAM SKU (1GB/1.5GB/2GB/4GB LPDDR4) this board ships in; the crypto/LUKS2
read/write path actually working; a USB Ethernet adapter actually linking and
passing traffic; whether the board's boot-select behavior prefers the onboard
SPI NOR or the microSD byte-offset U-Boot location (both are plausible sunxi
conventions and this was not verifiable without hardware). These steps are
written to MIRROR the proven Frite/Orange-Pi-5 flow (via the Zero 2 template)
but cannot be end-to-end tested in this environment (no board, no full Gentoo
builder — network access here sufficed to fetch upstream source files, NOT to
run a real cross-emerge).

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module defaults the
   mapper device to `luks-<uuid>` instead of the name `root=` actually expects
   (`cryptroot`), and `root=/dev/mapper/cryptroot` never resolves —
   `install-orangepi-zero2w.sh` sets both, mirroring Frite, RPi5, Orange Pi 5 and the Zero 2. (The Jetson builder has
   the same code, but it refuses `--encrypt-root`.)
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows the Zero 2's/Frite's/Orange-Pi-5's **on-device** model,
   not RPi5's **cross-host** model: `install-orangepi-zero2w.sh` runs
   from WITHIN the booted LIVE/INSTALLER session, ON THE ACTUAL Orange Pi Zero
   2W board that will later unlock the root at every boot — so cryptsetup's
   argon2id auto-benchmark is trustworthy and deliberately NOT pinned. If
   real-world operator practice for this board turns out to differ (e.g.
   operators routinely `dd` the image from a PC and never actually live-boot
   the installer ON the board), this judgment call would need to flip to the
   pinned model — flagged here explicitly for the next reviewer, exactly as
   the sibling READMEs flag it.

## Single storage class — no eMMC, no NVMe

Unlike Frite (eMMC module / microSD) or Orange Pi 5 (eMMC/microSD/NVMe), this
board has exactly **one** persistent storage class: microSD (or USB). There is
no "boot from USB, install to eMMC" split available — `install-orangepi-zero2w.sh`
supports installing to a **second** microSD/USB device (the safer choice — the
LIVE medium stays bootable as a rescue disk) **or** the **same** device the
LIVE image booted from (the live session already runs entirely from a
squashfs+tmpfs overlay in RAM, so repartitioning the boot medium underneath it
does not corrupt the running session). The installer adds an extra
confirmation prompt when it detects a same-device install, but does not block
it. This is genuinely **untested on real hardware** — see the checklist below.

## Front-end wiring (all-options-in-all-menus)

Per the all-options-in-all-menus standing rule: `make orangepizero2w`,
`make orangepizero2w-live`, `make orangepizero2w-installer` (mirroring the
`frite`/`orangepi5`/`orangepizero2` single-dedicated-platform pattern, not a
role-loop), `scripts/build-menu.sh`'s architecture picker + a dedicated flavor
screen (no board sub-menu — there is only one board), the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepizero2w_args()`, labelled explicitly as a **headless appliance**, not
a desktop), and `tests/build-matrix/matrix.tsv` + `check.sh` all reach this
platform through the same `--print-plan` contract as every other builder.

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
  analogue — read its README alongside this one): `specs-orangepi-zero2/README.md`.
- Closest architectural sibling for the mesh/provisioning/SSH plumbing:
  `build-frite-stage4.sh`'s `DESKTOP=none` headless-base code path.
- Closest architectural sibling for the LUKS on-device model + research-
  confidence-graded README structure: `specs-orangepi5/README.md` (Phase 7).
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
