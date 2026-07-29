# specs-orangepi-zero2 — Orange Pi Zero 2 (Allwinner H616, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> Zero 2 has ever booted an image produced by this repo. Every H616-specific
> fact below (DTB/U-Boot-defconfig names, kernel Kconfig symbols, driver
> maturity, and — most importantly — the HDMI/display-driver gap) is
> **researched by directly fetching the live mainline Linux/U-Boot upstream
> source trees at research time** (not just secondary claims about them), **not
> hardware-verified in this environment** — there is no H616 hardware, and no
> network access to actually cross-emerge a real Gentoo tree, available in this
> sandbox. Treat this exactly like `specs-jetson/`/`specs-orangepi5/` were
> treated before their own hardware-validation passes: buildable and internally
> consistent (`--print-plan` clean across the whole flag matrix), but **do not
> trust it to boot** until a real board confirms it end-to-end.

## Why this is the ONE platform in the repo with no desktop option — read this first

Every other client-device platform in this repo (Frite, Orange Pi 5, RPi5's
desktop role, Jetson's desktop role) ships a lean LXDE-class desktop. This one
does not, and never will, for a concrete, researched reason — not because
nobody got around to it:

- The board **does** have a physical Micro-HDMI 2.0a port (confirmed against
  official specs/schematic and the upstream devicetree's own board-description
  comment). This is **not** a "no video hardware" situation.
- Mainline Linux has **zero display-driver support** for the H616's display
  engine (DE33) as of the research behind this platform. Confirmed by directly
  fetching the live upstream trees:
  - `drivers/gpu/drm/sun4i/` (torvalds/linux, `master`) ships driver files for
    the OLDER sun4i/sun6i/sun8i DE2/DE3-class hardware (`sun8i_mixer.c`,
    `sun8i_dw_hdmi.c`, `sun8i_hdmi_phy.c`, ...) and **nothing** named
    `de33`/`hdmi_h616`/anything H616-specific.
  - `arch/arm64/boot/dts/allwinner/sun50i-h616.dtsi` (the H616 SoC-level
    devicetree) has **no** `&hdmi`, `&tcon`, `&mixer`, or display-engine node
    of any kind.
  - The dedicated DE33 mixer/CSC/plane-binding patch series was, as of a
    Nov-2025-dated post on the series itself, still **"a second series out of
    tree"** aiming to "properly introduce" DE33 support, with the remaining
    patches for **a full display pipeline** (including HDMI) explicitly
    described as "will be sent once this series is merged" — i.e. not even
    fully specified yet, let alone merged, as of that date.
  - The only place working HDMI on this board exists at all is Allwinner's own
    never-upstreamed legacy-BSP kernel fork (a **whole alternate kernel tree**,
    not just an extra firmware blob), or an **Armbian community backport** of
    the out-of-tree DE33 patch series onto their own sunxi-6.12 kernel branch.
    That backport's own PR history (`armbian/build` #7752 adding the
    `drm sun4i-de33` driver + HDMI support, followed by #7947, "BUGFIX: Remove
    the incomplete patch") shows **boot freezes on this exact board** (Orange
    Pi Zero 2/Zero 3), a GPU-power-domain hang traced to an incorrectly-applied
    patch, and a fix that **removed** the problematic patch rather than
    stabilizing it. Even the best available out-of-tree attempt is not stable.
- Carrying an entire alternate out-of-tree kernel just for one board's display
  would be a materially heavier, more fragile commitment than every other
  platform in this repo requires — even Orange Pi 5's HDMI (gated behind
  "kernel must be >= 6.13") and Frite's Amlogic FIP/BL31 are each just **one**
  proprietary/out-of-tree piece dropped into an otherwise-mainline build, not a
  whole alternate kernel tree.
- WiFi (a Unisoc UWE5622 die inside an Allwinner "AW859A" combo module) is
  **also** out-of-tree-only — confirmed no mainline kernel.org driver exists at
  all, a stronger gap than Orange Pi 5's AP6275P (which at least has an
  upstream brcmfmac-class driver with known rough edges).
- Countervailing strength: this board has a **genuinely fully open-source,
  blob-free boot chain** — mainline U-Boot has **native**,
  community-reverse-engineered H616 DRAM init (no closed "boot0" blob at all,
  unlike **every other** ARM platform in this repo, which each need at least
  one proprietary blob) — confirmed onboard Gigabit Ethernet via a Realtek
  RTL8211F PHY (fully mainline), and it is a genuinely tiny/cheap/low-power
  board. That is exactly the profile of a good, lean, hardened, **SSH-only
  network appliance** — a small VPN/mesh gateway node, a tiny home-lab utility
  box — which is exactly the scope this builder targets.

**If mainline Linux ever lands full DE33 display support** (watch the
`dri-devel` list / `linux-sunxi.org`'s H616 page), this scope decision should
be **revisited** — a desktop role could become viable. Do not silently keep
building headless out of habit once that changes; and do not "fix" this
platform into a desktop role by copy-pasting another platform's GPU/X11 config
without re-confirming the display situation first.

## What this adds

A lean, hardened, **headless network appliance** image for the Orange Pi Zero
2 — architecturally the closest analogue in this repo is
`build-frite-stage4.sh --desktop none` (its headless-base mode), except this
platform has **no other mode**: there is no `--desktop`/`--role` toggle here at
all, because this board never has a desktop option. Reuses the SAME aarch64
cross toolchain + shared `specs/` mesh/provisioning/sshd plumbing as every
other client image: headscale/tailscale mesh join, hardened key-only sshd,
KEYS-USB first-boot provisioning, and — from day one — full `--standalone`
(local user over SSH, no mesh, build-time password) and `--encrypt-root`
(LUKS2 full-disk encryption) support.

```sh
./build-orangepi-zero2-stage4.sh                              # both live+installer
./build-orangepi-zero2-stage4.sh --flavor live                 # live only
./build-orangepi-zero2-stage4.sh --standalone --local-user alice  # local-only appliance, LUKS2 FDE on install
./build-orangepi-zero2-stage4.sh --encrypt-root --print-plan   # dry-run plan (no root)
```

No `--board` axis either (unlike Frite's 3 boards / Orange Pi 5's 2 boards):
this is one specific board, so `--cpu`/`--dtb`/`--defconfig`/`--uboot-defconfig`
are direct overrides rather than entries in a board table.

## Boot chain (researched — see confidence notes)

```
Allwinner BootROM
  -> U-Boot SPL   (NATIVE H616 DRAM-init driver — NO blob. This is the
                    project-first difference from every other arm64 platform
                    here: Frite needs Amlogic FIP/BL31, Orange Pi 5 needs
                    Rockchip rkbin DDR-init + TF-A BL31 blobs. This board's
                    mainline U-Boot alone can train DRAM.)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD/USB) for /extlinux/extlinux.conf -- the SAME
                  mechanism build-frite-stage4.sh / build-orangepi5-stage4.sh use
```

U-Boot defconfig (CONFIRMED by fetching the live file from `u-boot/u-boot`
upstream `configs/orangepi_zero2_defconfig`): contains
`CONFIG_DRAM_SUNXI_DX_ODT`/`CONFIG_DRAM_SUNXI_DX_DRI`/`CONFIG_DRAM_SUNXI_CA_DRI`/
`CONFIG_DRAM_SUNXI_TPR6`/`CONFIG_DRAM_SUNXI_TPR10`/
`CONFIG_SUNXI_DRAM_H616_DDR3_1333=y` — all **native training parameters**, no
blob reference of any kind. Mainline kernel DTB (CONFIRMED against
`arch/arm64/boot/dts/allwinner/` upstream):
`sun50i-h616-orangepi-zero2.dts` (includes `sun50i-h616-orangepi-zero.dtsi` +
`sun50i-h616-cpu-opp.dtsi`). Serial debug console (CONFIRMED against the live
`sun50i-h616-orangepi-zero.dtsi`'s own `chosen`/`aliases` nodes:
`aliases { serial0 = &uart0; }`, `chosen { stdout-path = "serial0:115200n8"; }`):
`ttyS0,115200`.

## Research findings by topic (confidence-graded)

1. **HDMI/display driver gap** — HIGH confidence, and the single most
   important, load-bearing finding in this whole port (see the section above
   for the full trail). Re-verify this specifically before ever revisiting the
   headless-only scope decision.
2. **Boot chain / no-blob DRAM init** — HIGH confidence. The
   `orangepi_zero2_defconfig` file was fetched directly from the live upstream
   U-Boot tree and its DRAM-training symbols inspected; no blob load/reference
   of any kind is present. This is a genuine, celebratable project first.
3. **Ethernet (RTL8211F PHY + H616 EMAC)** — HIGH confidence. The board's
   onboard Gigabit Ethernet is confirmed via the upstream devicetree's own
   board-description comment ("1Gbps Ethernet port (via RTL8211F PHY)"). The
   MAC-side driver is `CONFIG_DWMAC_SUN8I` (Allwinner sun8i/sun50i GMAC glue,
   `drivers/net/ethernet/stmicro/stmmac/dwmac-sun8i.c`) and the PHY driver is
   `CONFIG_REALTEK_PHY` (`drivers/net/phy/realtek/`, covering the RTL821x/
   RTL822x family including the RTL8211F) — both CONFIRMED mainline. **VERIFY**
   the exact Kconfig split still matches whatever kernel tree is actually
   checked out at build time — the Realtek PHY driver was refactored into its
   own `drivers/net/phy/realtek/` subdirectory upstream at some point; the
   Kconfig *symbol name* (`CONFIG_REALTEK_PHY`) is confirmed unchanged, but the
   underlying file layout is a real point of drift to re-check.
4. **WiFi** — CONFIRMED gap. The onboard Unisoc UWE5622 die (packaged inside an
   Allwinner "AW859A" WiFi+BT module) has **no mainline kernel.org driver at
   all** — not even a rough one. This appliance ships **no** onboard-radio
   kernel module at all (see `kernel/hardened-appliance.config`) rather than
   carrying dead module config for hardware nothing in mainline can drive. A
   USB WiFi/Bluetooth dongle with its OWN already-mainlined driver would still
   work via whatever the base arm64 defconfig already builds; `harden_radios()`
   in the builder blacklists the generic cfg80211/mac80211/bluetooth/btusb
   modules by default regardless (same hardened posture as every other
   platform). Ethernet + the tailnet are this appliance's primary, reliable
   path — by design, not as a workaround.
5. **Storage** — HIGH confidence. This board has **no eMMC** (the original 2019
   announcement mentioned an optional eMMC SKU; the shipping product does not
   include one) and **no NVMe/PCIe at all** on this SoC tier. Storage is
   microSD (plus a small onboard 2MiB bootable SPI NOR flash that can carry
   U-Boot itself, mirroring La Frite's SPI-NOR U-Boot placement) — confirmed
   against the upstream devicetree's board-description comment ("MicroSD slot,
   2MiB bootable SPI NOR flash") and multiple independent spec sources.
6. **CPU / hardware crypto** — HIGH confidence. H616 is a quad-core Cortex-A53
   (no big.LITTLE split, unlike Orange Pi 5's RK3588 cortex-a76.cortex-a55
   mix) — the SAME core Orange Pi 5's LITTLE cluster uses, so
   `CONFIG_CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions) applies the same
   way: a guaranteed CPU-instruction AES accelerator, used for LUKS2's
   `xts(aes)` cipher on `--encrypt-root` builds. No dedicated hardware crypto
   *engine* (distinct from the CPU's own Crypto Extensions) is claimed for this
   SoC tier — H616 is a much smaller chip than RK3588 and this fragment does
   not assume one.
7. **RAM SKUs** — HIGH confidence. This board ships in 512MB/1GB/1.5GB/2GB DDR3
   SKUs (RAM is auto-detected, same image across all of them — mirrors La
   Frite's 512MB/1GB SKU handling); a zram swap is configured at first boot to
   help the smallest SKU.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax; `--print-plan` across the flavor ×
standalone × encrypt-root matrix (internal consistency — reported artifact
names / kernel fragment / effective flavor all agree); that the DTB/U-Boot-
defconfig values match upstream U-Boot/Linux naming as researched above
(including a direct fetch of the actual files, not just secondary claims);
that this is a purely additive new-platform change (no existing builder/specs
tree touched); that it reuses the shared `specs/` provisioning + mesh exactly
like every other client image; template rendering (LIVE emits
`INITRD /initrd.img`, plaintext INSTALLER does not, `--encrypt-root` INSTALLER
emits the disk-boot initramfs line); a hard build-time guard that refuses to
ship a kernel with `CONFIG_DRM`/`CONFIG_FRAMEBUFFER_CONSOLE` set (protects the
headless-only scope decision against an accidental future regression).

**NEEDS REAL HARDWARE (or at minimum a full Gentoo cross-build environment
this sandbox does not have) TO VERIFY:** the actual aarch64 cross-emerge of
this package set against THIS platform's package/USE set; the mainline kernel
build + whether the in-tree H616 DTB name above still matches whatever
gentoo-sources version is checked out; whether a microSD/USB-written LIVE/
INSTALLER image genuinely boots via distro-boot on real hardware; the
`orangepi_zero2_defconfig` DRAM-training parameters actually working across
EVERY RAM SKU (512MB/1GB/1.5GB/2GB) this board ships in; the crypto/LUKS2
read/write path actually working; the Ethernet PHY actually linking at
gigabit; whether the board's boot-select strap defaults to reading U-Boot from
the onboard SPI NOR or directly from the microSD card at a fixed byte offset
(both are plausible sunxi conventions and this was not verifiable without
hardware). These steps are written to MIRROR the proven Frite/Orange-Pi-5 flow
but cannot be end-to-end tested in this environment (no board, no full Gentoo
builder, and this sandbox may also lack network access for a real
cross-emerge — check before assuming otherwise).

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module defaults the
   mapper device to `luks-<uuid>` instead of the name `root=` actually expects
   (`cryptroot`), and `root=/dev/mapper/cryptroot` never resolves —
   `install-orangepi-zero2.sh` sets both, mirroring Frite/RPi5/Jetson/
   Orange-Pi-5 exactly (x86 is the one sibling that appears to be missing this
   pairing — treated as an x86 bug to NOT copy, not a pattern to follow).
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows Frite's/Orange-Pi-5's **on-device** model, not RPi5's/
   Jetson's **cross-host** model: `install-orangepi-zero2.sh` runs from WITHIN
   the booted LIVE/INSTALLER session, ON THE ACTUAL Orange Pi Zero 2 board
   that will later unlock the root at every boot (the same board formats it
   and later reads it) — so cryptsetup's argon2id auto-benchmark is
   trustworthy and deliberately NOT pinned. This is the SAME genuine
   architectural judgment call Orange Pi 5's Phase 7 made for the identical
   underlying reason (a live+installer image that boots on the board itself,
   unlike RPi5's installer ISO, which is explicitly documented as NOT bootable
   on the Pi 5 itself). If real-world operator practice for this board turns
   out to differ (e.g. operators routinely `dd` the image from a PC and never
   actually live-boot the installer ON the board), this judgment call would
   need to flip to the pinned model — flagged here explicitly for the next
   reviewer, exactly as Orange Pi 5's README flags it for that platform.

## Single storage class — no eMMC, no NVMe (a genuinely different situation
   from every sibling)

Unlike Frite (eMMC module / microSD) or Orange Pi 5 (eMMC/microSD/NVMe), this
board has exactly **one** persistent storage class: microSD (or USB). There is
no "boot from USB, install to eMMC" split available — `install-orangepi-zero2.sh`
supports installing to a **second** microSD/USB device (the safer choice — the
LIVE medium stays bootable as a rescue disk) **or** the **same** device the
LIVE image booted from (the live session already runs entirely from a
squashfs+tmpfs overlay in RAM, so repartitioning the boot medium underneath it
does not corrupt the running session — this mirrors how many live-CD-style
installers "install to the disk you booted from" work in practice). The
installer adds an extra confirmation prompt when it detects a same-device
install, but does not block it. This is genuinely **untested on real
hardware** — see the checklist below.

## Front-end wiring (all-options-in-all-menus)

Per the all-options-in-all-menus standing rule: `make orangepizero2`,
`make orangepizero2-live`, `make orangepizero2-installer` (mirroring the
`frite`/`orangepi5` single-dedicated-platform pattern, not a role-loop),
`scripts/build-menu.sh`'s architecture picker + a dedicated flavor screen (no
board sub-menu — there is only one board), the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepizero2_args()`, labelled explicitly as a **headless appliance**, not a
desktop), and `tests/build-matrix/matrix.tsv` + `check.sh` all reach this
platform through the same `--print-plan` contract as every other builder.

## Hardware-validation checklist (flip Status when done)

1. Assemble/obtain a real U-Boot build for `orangepi_zero2_defconfig` and
   confirm it boots to a serial console (`ttyS0,115200`) with NO blob — this is
   the platform's headline claim and the first thing to actually prove.
2. Boot the LIVE image off microSD/USB on a real Orange Pi Zero 2; confirm the
   dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi-zero2.sh` against a microSD card (both the
   same-device and second-device paths) and confirm the installed system boots
   — PLAINTEXT first, then `--encrypt-root`.
4. Confirm Gigabit Ethernet actually links and passes traffic via `r8169`-class
   `dwmac-sun8i` + the RTL8211F PHY.
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
  `build-frite-stage4.sh`'s `DESKTOP=none` headless-base code path (the
  ancestor idea this platform makes permanent rather than conditional).
- Closest architectural sibling for the LUKS on-device model + research-
  confidence-graded README structure: `specs-orangepi5/README.md` (Phase 7).
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
