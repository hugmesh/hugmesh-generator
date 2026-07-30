# specs-orangepi-zero3 — Orange Pi Zero 3 (Allwinner H618, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> Zero 3 has ever booted an image produced by this repo. Every H618-specific
> fact below (DTB/U-Boot-defconfig names, kernel Kconfig symbols, driver
> maturity, and — most importantly — the HDMI/display-driver gap) is either
> **researched by directly fetching the live mainline Linux/U-Boot upstream
> source trees** (the board's own DTS, its shared `sun50i-h616-orangepi-zero.dtsi`,
> and its U-Boot defconfig were re-fetched and re-confirmed for THIS port) or
> **inherited from the Zero 2W/Zero 2 siblings' research**
> (`specs-orangepi-zero2w/README.md` — the direct template, same H618 SoC — and
> `specs-orangepi-zero2/README.md`; each inherited claim is marked as such
> below). **Not hardware-verified in this environment** — there is no H618
> hardware available in this sandbox. Treat this exactly like
> `specs-jetson/`/`specs-orangepi5/` were treated before their own
> hardware-validation passes: buildable and internally consistent
> (`--print-plan` clean across the whole flag matrix), but **do not trust it to
> boot** until a real board confirms it end-to-end.

## How this differs from the Zero 2W template (read this before trusting any inherited claim)

This platform is a deliberate, faithful derivation of `specs-orangepi-zero2w` +
`build-orangepi-zero2w-stage4.sh` (the SAME-SoC H618 sibling — the nearest
possible template; that tree is itself a derivation of the H616 Zero 2). The
honest deltas, all verified for this port unless marked inherited:

- **SoC: the SAME H618.** Unlike every previous port in this family, the SoC
  does not change at all — mainline U-Boot handles it via the SAME machine
  support (`CONFIG_MACH_SUN50I_H616=y` — CONFIRMED by fetching the live
  `configs/orangepi_zero3_defconfig`), and the mainline kernel DTS carries the
  same `allwinner,sun50i-h618` compatible (CONFIRMED by fetching the live
  `sun50i-h618-orangepi-zero3.dts`). Everything the siblings' research says
  about the H616/H618 display engine (DE33) applies unchanged — the
  headless-only scope decision carries over intact.
- **DTS lineage: back to the Zero 2's shared dtsi.** The fetched
  `sun50i-h618-orangepi-zero3.dts` includes `sun50i-h616-orangepi-zero.dtsi` —
  the SAME shared board dtsi the Zero 2 uses — plus `sun50i-h616-cpu-opp.dtsi`
  (the Zero 2W instead includes `sun50i-h616.dtsi` directly). So at the
  devicetree level this board is closer to a "Zero 2 with H618 + LPDDR4" than
  to the Zero 2W, even though the Zero 2W is the same-SoC template.
- **ONBOARD Gigabit Ethernet is BACK — the biggest functional difference.**
  The Zero 2W dropped the Ethernet jack entirely (its images are
  USB-Ethernet-first); the Zero 3 restores it. CONFIRMED: the fetched mainline
  `sun50i-h618-orangepi-zero3.dts` enables `&emac0` with
  `phy-mode = "rgmii-rxid"`, `allwinner,tx-delay-ps = <700>`,
  `phy-supply = <&reg_dldo1>`, and sets
  `motorcomm,clk-out-frequency-hz = <125000000>` on the shared dtsi's RGMII PHY
  node — i.e. the external PHY is a **Motorcomm YT8531**, NOT the Zero 2's
  Realtek RTL8211F. Both halves are mainline (`CONFIG_DWMAC_SUN8I` +
  `CONFIG_MOTORCOMM_PHY` — see `kernel/hardened-appliance.config`), and the
  fetched U-Boot defconfig pairs the same way (`CONFIG_SUN8I_EMAC=y` +
  `CONFIG_PHY_MOTORCOMM=y`). This restores the family's headline **blob-free
  boot+network chain** claim that the Zero 2W had to honestly degrade to
  boot-only — and this appliance is **Ethernet-first** again, like the Zero 2.
- **RAM: same LPDDR4 story.** SKUs are 1GB/1.5GB/2GB/4GB LPDDR4, and the
  fetched U-Boot defconfig selects `CONFIG_SUNXI_DRAM_H616_LPDDR4=y` +
  `CONFIG_DRAM_CLK=792` + native `CONFIG_DRAM_SUNXI_TPR*`/`DX_ODT`/... training
  parameters (CONFIRMED by direct fetch; the parameter VALUES are this board's
  own, not byte-identical to the Zero 2W's) — still **fully native, no blob**.
- **PMIC: same AXP313** (`CONFIG_AXP313_POWER=y` in the fetched defconfig).
  Boot-relevant only at the U-Boot level; no builder knob depends on it.
- **Storage: same class.** 16MB SPI NOR (bootloader-sized, U-Boot only — per
  the vendor's spec sheet), no eMMC, no NVMe/PCIe — microSD/USB remains the
  ONLY persistent storage class, so the single-storage-class installer model
  carries over unchanged.
- **USB: USB-C power/OTG + a full-size USB2 Type-A host port** (+ USB2 pins on
  the expansion header) instead of the Zero 2W's 2x Type-C — port arrangement
  per the vendor's spec sheet (not DTS-verifiable). Same musb/ehci/ohci sunxi
  symbol set via the shared dtsi (inherited).
- **HDMI connector: Micro-HDMI** (per the vendor's spec sheet; the Zero 2W's
  is Mini-HDMI) — immaterial: there is still no mainline driver to put pixels
  on either connector (see the scope section below).
- **WiFi/BT: same gap.** A Unisoc UWE5622 combo module (per the vendor's own
  spec sheet for this board — the same die as the Zero 2's "AW859A" package) —
  the siblings' CONFIRMED finding that no mainline kernel.org driver exists
  applies to this board too (inherited).
- **Board constants:** DTB `allwinner/sun50i-h618-orangepi-zero3.dtb`; U-Boot
  defconfig `orangepi_zero3_defconfig` (both CONFIRMED by direct fetch of the
  live upstream trees for this port). Serial console `ttyS0,115200`
  (CONFIRMED against the fetched shared dtsi's own `aliases`/`chosen` nodes:
  `serial0 = &uart0`, `stdout-path = "serial0:115200n8"`).

Everything else — flavor axis, standalone/encrypt-root posture, on-device LUKS
model, package set, hardened kernel posture, no-desktop-ever scope — is
intentionally byte-similar to the template; do not "fix" a difference between
the two trees without checking which board it actually belongs to.

## Why this is a platform with no desktop option — read this first

Every other client-device platform in this repo (Frite, Orange Pi 5, RPi5's
desktop role, Jetson's desktop role) ships a lean LXDE-class desktop. This one
does not, and never will, for a concrete, researched reason — not because
nobody got around to it (the trail below is the Zero 2 sibling's research,
carried through the Zero 2W template; it applies verbatim because the H618
carries the SAME DE33 display engine):

- The board **does** have a physical Micro-HDMI port. This is **not** a "no
  video hardware" situation.
- Mainline Linux has **zero display-driver support** for the H616/H618 display
  engine (DE33) as of the research behind the sibling platforms (inherited;
  re-confirmed structurally for this port: the fetched
  `sun50i-h618-orangepi-zero3.dts` + its shared dtsi carry no
  `&hdmi`/`&tcon`/`&mixer`/display-engine node of any kind):
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
    freezes** on this exact board family (Orange Pi Zero 2/**Zero 3** — this
    very board is named in that history), a GPU-power-domain hang, and a
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
  `orangepi_zero3_defconfig`: `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, native
  training parameters, no closed "boot0" blob at all, unlike **every other**
  ARM platform in this repo) — AND, unlike the Zero 2W, pairs it with
  **onboard Gigabit Ethernet on a fully-mainline driver pair**
  (dwmac-sun8i + Motorcomm YT8531). That is exactly the profile of a good,
  lean, hardened, **SSH-only network appliance**.

**If mainline Linux ever lands full DE33 display support** (watch the
`dri-devel` list / `linux-sunxi.org`'s H616/H618 pages), this scope decision
should be **revisited** — do not silently keep building headless out of habit
once that changes; and do not "fix" this platform into a desktop role by
copy-pasting another platform's GPU/X11 config without re-confirming the
display situation first.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi Zero
3 — architecturally the closest analogue in this repo is its own template,
`build-orangepi-zero2w-stage4.sh` (see the delta section above), and beyond
that `build-orangepi-zero2-stage4.sh` and `build-frite-stage4.sh --desktop
none`. There is no `--desktop`/`--role` toggle here at all. Reuses the SAME
aarch64 cross toolchain + shared `specs/` mesh/provisioning/sshd plumbing as
every other client image: headscale/tailscale mesh join, hardened key-only
sshd, KEYS-USB first-boot provisioning, and — from day one — full
`--standalone` (local user over SSH, no mesh, build-time password) and
`--encrypt-root` (LUKS2 full-disk encryption) support.

```sh
./build-orangepi-zero3-stage4.sh                              # both live+installer
./build-orangepi-zero3-stage4.sh --flavor live                 # live only
./build-orangepi-zero3-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi-zero3-stage4.sh --encrypt-root --print-plan   # dry-run plan (no root)
```

No `--board` axis either (unlike Frite's 3 boards / Orange Pi 5's 2 boards):
this is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig`
are direct overrides rather than entries in a board table.

## Boot chain (researched — see confidence notes)

```
Allwinner BootROM
  -> U-Boot SPL   (NATIVE H616-family LPDDR4 DRAM-init driver — NO blob. Same
                    project-first property as the Zero 2/Zero 2W siblings:
                    Frite needs Amlogic FIP/BL31, Orange Pi 5 needs Rockchip
                    rkbin DDR-init + TF-A BL31 blobs. This board's mainline
                    U-Boot alone can train DRAM.)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD/USB) for /extlinux/extlinux.conf -- the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh use
```

U-Boot defconfig (CONFIRMED by fetching the live file from `u-boot/u-boot`
upstream `configs/orangepi_zero3_defconfig` for THIS port): contains
`CONFIG_DEFAULT_DEVICE_TREE="allwinner/sun50i-h618-orangepi-zero3"`,
`CONFIG_MACH_SUN50I_H616=y`, `CONFIG_DRAM_CLK=792`,
`CONFIG_DRAM_SUNXI_DX_ODT`/`DX_DRI`/`CA_DRI`/`ODT_EN`/`TPR6`/`TPR10`/`TPR11`/
`TPR12`, `CONFIG_SUNXI_DRAM_H616_LPDDR4=y`, `CONFIG_AXP313_POWER=y`, plus
`CONFIG_SUN8I_EMAC=y` + `CONFIG_PHY_MOTORCOMM=y` for the onboard GbE — all
**native training parameters**, no blob reference of any kind. Mainline kernel
DTB (CONFIRMED by fetching `arch/arm64/boot/dts/allwinner/` upstream for THIS
port): `sun50i-h618-orangepi-zero3.dts` (model "OrangePi Zero3", compatible
`xunlong,orangepi-zero3`/`allwinner,sun50i-h618`; includes
`sun50i-h616-orangepi-zero.dtsi` + `sun50i-h616-cpu-opp.dtsi`). Serial debug
console (CONFIRMED against the fetched shared dtsi's own `chosen`/`aliases`
nodes: `aliases { serial0 = &uart0; }`,
`chosen { stdout-path = "serial0:115200n8"; }`): `ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **HDMI/display driver gap** — HIGH confidence, inherited from the Zero
   2/Zero 2W siblings' research (same DE33 engine; the absence of any display
   node re-confirmed for this port by direct fetch of the DTS + shared dtsi).
   The single most important, load-bearing finding in this port. Re-verify
   before ever revisiting the headless-only scope decision — the Armbian
   boot-freeze history names the Zero 3 explicitly.
2. **Boot chain / no-blob DRAM init** — HIGH confidence, re-confirmed for THIS
   board: `orangepi_zero3_defconfig` was fetched directly from the live
   upstream U-Boot tree and its LPDDR4 DRAM-training symbols inspected; no
   blob load/reference of any kind is present.
3. **Networking** — HIGH confidence, and DIFFERENT from the Zero 2W template:
   **onboard Gigabit Ethernet is back** (the fetched mainline DTS enables
   `&emac0` in `rgmii-rxid` mode against a Motorcomm YT8531 PHY on the shared
   dtsi's mdio node). Driver pair is fully mainline: `CONFIG_DWMAC_SUN8I` +
   `CONFIG_MOTORCOMM_PHY` (built by `kernel/hardened-appliance.config`).
   **VERIFY** at build time that the checked-out kernel's Motorcomm driver
   covers the YT8531 (it entered mainline later than the YT8511 — any
   gentoo-sources this repo pins is far newer, but the note is load-bearing
   for custom `--defconfig` overrides).
4. **WiFi** — CONFIRMED gap (inherited). The onboard Unisoc UWE5622 module
   (module identity per the vendor's own spec sheet for this board) has **no
   mainline kernel.org driver at all**. This appliance ships **no**
   onboard-radio kernel module (see `kernel/hardened-appliance.config`). A USB
   WiFi/Bluetooth dongle with its OWN already-mainlined driver would still
   work; `harden_radios()` in the builder blacklists the generic
   cfg80211/mac80211/bluetooth/btusb modules by default regardless. Onboard
   Ethernet + the tailnet are this appliance's primary, reliable path.
5. **Storage** — HIGH confidence. No eMMC, no NVMe/PCIe on this SoC tier;
   microSD (or USB) is the only persistent storage class. The onboard **16MB
   SPI NOR** (per the vendor's spec sheet — same size as the Zero 2W's) is
   bootloader-sized — it can carry U-Boot itself (`--write-uboot-spi` in the
   installer), never a rootfs.
6. **CPU / hardware crypto** — HIGH confidence. H618 is a quad-core Cortex-A53
   (no big.LITTLE split; an H616 die revision with a larger L2 cache) — so
   `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions) applies exactly
   as on the siblings: a guaranteed CPU-instruction AES accelerator, used for
   LUKS2's `xts(aes)` cipher on `--encrypt-root` builds. No dedicated hardware
   crypto *engine* is claimed for this SoC tier.
7. **RAM SKUs** — HIGH confidence. This board ships in 1GB/1.5GB/2GB/4GB
   LPDDR4 SKUs (RAM is auto-detected, same image across all of them); a zram
   swap is configured at first boot to help the smallest SKU, same as the
   siblings.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax; `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency — reported artifact
names / kernel fragment / effective flavor all agree); that the DTB/U-Boot-
defconfig values match upstream U-Boot/Linux naming (including a direct fetch
of the actual `orangepi_zero3_defconfig`, `sun50i-h618-orangepi-zero3.dts`,
and `sun50i-h616-orangepi-zero.dtsi` files for this port, not just secondary
claims); that this is a purely additive new-platform change (no existing
builder/specs tree touched); that it reuses the shared `specs/` provisioning +
mesh exactly like every other client image; template rendering (LIVE emits
`INITRD /initrd.img`, plaintext INSTALLER does not, `--encrypt-root` INSTALLER
emits the disk-boot initramfs line); a hard build-time guard that refuses to
ship a kernel with `CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE` set (protects the
headless-only scope decision against an accidental future regression).

**NEEDS REAL HARDWARE (or at minimum a full Gentoo cross-build environment
this sandbox does not have) TO VERIFY:** the actual aarch64 cross-emerge of
this package set against THIS platform's package/USE set; the mainline kernel
build + whether the in-tree H618 DTB name above still matches whatever
gentoo-sources version is checked out; whether a microSD/USB-written LIVE/
INSTALLER image genuinely boots via distro-boot on real hardware; the
`orangepi_zero3_defconfig` DRAM-training parameters actually working across
EVERY RAM SKU (1GB/1.5GB/2GB/4GB LPDDR4) this board ships in; the crypto/LUKS2
read/write path actually working; the onboard GbE actually linking and passing
traffic on the YT8531 PHY (`CONFIG_MOTORCOMM_PHY` binding included); whether
the board's boot-select behavior prefers the onboard SPI NOR or the microSD
byte-offset U-Boot location (both are plausible sunxi conventions and this was
not verifiable without hardware). These steps are written to MIRROR the proven
Frite/Orange-Pi-5 flow (via the Zero 2W template) but cannot be end-to-end
tested in this environment (no board, no full Gentoo builder — network access
here sufficed to fetch upstream source files, NOT to run a real cross-emerge).

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module defaults the
   mapper device to `luks-<uuid>` instead of the name `root=` actually expects
   (`cryptroot`), and `root=/dev/mapper/cryptroot` never resolves —
   `install-orangepi-zero3.sh` sets both, mirroring Frite/RPi5/Jetson/
   Orange-Pi-5/Zero-2/Zero-2W exactly.
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows the Zero 2W's/Zero 2's/Frite's/Orange-Pi-5's **on-device**
   model, not RPi5's/Jetson's **cross-host** model: `install-orangepi-zero3.sh`
   runs from WITHIN the booted LIVE/INSTALLER session, ON THE ACTUAL Orange Pi
   Zero 3 board that will later unlock the root at every boot — so cryptsetup's
   argon2id auto-benchmark is trustworthy and deliberately NOT pinned. If
   real-world operator practice for this board turns out to differ (e.g.
   operators routinely `dd` the image from a PC and never actually live-boot
   the installer ON the board), this judgment call would need to flip to the
   pinned model — flagged here explicitly for the next reviewer, exactly as
   the sibling READMEs flag it.

## Single storage class — no eMMC, no NVMe

Unlike Frite (eMMC module / microSD) or Orange Pi 5 (eMMC/microSD/NVMe), this
board has exactly **one** persistent storage class: microSD (or USB). There is
no "boot from USB, install to eMMC" split available — `install-orangepi-zero3.sh`
supports installing to a **second** microSD/USB device (the safer choice — the
LIVE medium stays bootable as a rescue disk) **or** the **same** device the
LIVE image booted from (the live session already runs entirely from a
squashfs+tmpfs overlay in RAM, so repartitioning the boot medium underneath it
does not corrupt the running session). The installer adds an extra
confirmation prompt when it detects a same-device install, but does not block
it. This is genuinely **untested on real hardware** — see the checklist below.

## Front-end wiring (all-options-in-all-menus)

Per the all-options-in-all-menus standing rule: `make orangepizero3`,
`make orangepizero3-live`, `make orangepizero3-installer` (mirroring the
`frite`/`orangepi5`/`orangepizero2`/`orangepizero2w` single-dedicated-platform
pattern, not a role-loop), `scripts/build-menu.sh`'s architecture picker + a
dedicated flavor screen (no board sub-menu — there is only one board), the
Studio (`studio/hugmesh_studio/core/config.py`'s
`BUILDER_SCRIPTS`/`ROLE_CHOICES`/`_orangepizero3_args()`, labelled explicitly
as a **headless appliance**, not a desktop), and
`tests/build-matrix/matrix.tsv` + `check.sh` all reach this platform through
the same `--print-plan` contract as every other builder.

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
  possible analogue — read its README alongside this one):
  `specs-orangepi-zero2w/README.md`.
- The family's H616 grandparent (whose shared dtsi this board's DTS includes,
  and whose onboard-GbE Ethernet-first posture this board restores):
  `specs-orangepi-zero2/README.md`.
- Closest architectural sibling for the mesh/provisioning/SSH plumbing:
  `build-frite-stage4.sh`'s `DESKTOP=none` headless-base code path.
- Closest architectural sibling for the LUKS on-device model + research-
  confidence-graded README structure: `specs-orangepi5/README.md` (Phase 7).
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
