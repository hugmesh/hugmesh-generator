# specs-orangepi5 — Orange Pi 5 / Orange Pi 5 Plus (Rockchip RK3588/RK3588S, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> 5 or Orange Pi 5 Plus has ever booted an image produced by this repo. Every
> RK3588/RK3588S fact below (DTB names, U-Boot defconfigs, kernel Kconfig
> symbols, driver maturity) is **researched** from web search, upstream
> kernel/Mesa/U-Boot docs, and a Gentoo user's own RK3588S write-up. None of it
> is **verified on hardware**. There is no RK3588 hardware, and no network
> access to cross-emerge a real Gentoo tree, in this sandbox. Treat it like
> `specs-jetson/`, which is also unvalidated. It builds and is internally
> consistent (`--print-plan` is clean across the whole role/board/flag matrix),
> but **do not trust it to boot** until a real board confirms it end to end.

## What this adds

A lean, hardened LXDE **light desktop** client image for the Orange Pi 5 family.
It is a **client device**, like Frite, not a K8s cluster node. It reuses the SAME
aarch64 cross toolchain and shared `specs/` mesh/provisioning/sshd plumbing as
every other client image (Frite/RPi5-desktop/Jetson-desktop): headscale/
tailscale mesh join, hardened key-only sshd, and KEYS-USB first-boot
provisioning. It supports `--standalone` (local user, no mesh, build-time
password) and `--encrypt-root` (LUKS2 full-disk encryption) from the start.

```sh
./build-orangepi5-stage4.sh                                   # Orange Pi 5 Plus (default), both live+installer
./build-orangepi5-stage4.sh --board orange-pi-5                # the smaller-I/O sibling (RK3588S)
./build-orangepi5-stage4.sh --standalone --local-user alice     # local-only desktop, LUKS2 FDE on install
./build-orangepi5-stage4.sh --encrypt-root --print-plan         # dry-run plan (no root)
```

## Board table (`--board`)

| `--board` | Chip | Notable I/O | Status |
|---|---|---|---|
| `orange-pi-5-plus` (**DEFAULT**) | RK3588 (full) | dual 2.5GbE (RTL8125, PCIe), PCIe3.0x4 M.2 NVMe, M.2 E-key WiFi slot, dual HDMI 2.1 + HDMI input, eMMC/microSD | EXPERIMENTAL |
| `orange-pi-5` | RK3588S | single lower-speed NIC (SKU-dependent), no PCIe3.0x4 (fewer PCIe lanes overall), single HDMI 2.1 output, no HDMI input, eMMC/microSD | EXPERIMENTAL |

**Chip confirmation (HIGH confidence):** RK3588 and RK3588S share an *identical*
CPU/GPU/NPU core (4x Cortex-A76 @ up to 2.4GHz + 4x Cortex-A55 @ up to 1.8GHz,
Mali-G610 MP4, ~6 TOPS NPU). Only the peripheral I/O differs. Relative to the
RK3588, the RK3588S drops native HDMI input, one of two HDMI 2.1 outputs, one of
two DP1.4 outputs, all four PCIe3.0 lanes, and one PCIe2.0 lane. So the Plus
(full RK3588) is the default: it is a superset of the base board's I/O, and the
extra 2.5GbE and PCIe/NVMe are what the headline features need.

Both boards default to `--flavor both` (LIVE + INSTALLER, as on Frite) and the
single `desktop` role. This is a client-device board, like Frite: there is no
`--role` axis with cluster-node choices.

## Boot chain (researched — see confidence notes)

```
Rockchip BootROM
  -> U-Boot TPL/SPL  (needs a Rockchip DDR-init blob from rkbin, e.g.
                       rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.09.bin — the
                       RK3588 analogue of Frite's Amlogic FIP/BL31 blob;
                       mainline U-Boot source alone cannot initialize DRAM)
  -> TF-A BL31        (mainline ARM Trusted Firmware does NOT yet support
                       RK3588 upstream; BL31 comes from Rockchip's rkbin
                       prebuilt blob, or a community TF-A fork (e.g. Collabora's)
                       — same "vendor blob needed" situation as Frite's Amlogic
                       FIP, NOT vendored here for the same licensing reason)
  -> U-Boot proper
  -> distro-boot: scans the first partition of whatever block device it finds
                  (microSD / eMMC / USB / NVMe) for /extlinux/extlinux.conf
                  -- CONFIRMED this is the SAME mechanism build-frite-stage4.sh
                  uses, NOT RPi5's raspberrypi-firmware config.txt model and
                  NOT UEFI/GRUB (a UEFI path DOES exist for RK3588 via the
                  community edk2-rk3588 project, but is NOT the default/
                  mainline path this builder targets)
```

U-Boot defconfigs (CONFIRMED against upstream U-Boot `configs/`):
`orangepi-5-rk3588s_defconfig` (Orange Pi 5) / `orangepi-5-plus-rk3588_defconfig`
(Orange Pi 5 Plus). Mainline DTBs (CONFIRMED against `arch/arm64/boot/dts/
rockchip/` upstream): `rockchip/rk3588s-orangepi-5.dtb` /
`rockchip/rk3588-orangepi-5-plus.dtb`. Serial debug console (CONFIRMED, multiple
independent sources): `ttyS2,1500000n8`.

We do **not** vendor the rkbin DDR-init and BL31 blobs, for the same licensing
reason as Frite's Amlogic FIP/BL31. With `--uboot-url`, the builder downloads a
prebuilt, board-specific U-Boot image. Without it, the builder warns and leaves
a slot for you to drop one in (the same mechanism as Frite's `--uboot-url`).

## Research findings by topic (confidence-graded)

1. **Chip variant** — HIGH confidence. See the board table above.
2. **Boot chain** — MEDIUM-HIGH confidence on the shape (TPL/SPL + rkbin DDR
   blob -> TF-A BL31 (rkbin or community fork) -> U-Boot -> extlinux
   distro-boot). HIGH confidence that extlinux/distro-boot (not UEFI, not
   config.txt) is the mainline mechanism: it matches Frite's architecture, and
   every source consulted describes U-Boot scanning `/extlinux/extlinux.conf`.
   **Not verified on hardware**: whether a USB-written LIVE/INSTALLER medium
   (this builder's `xorriso -as mkisofs` ISO, same as Frite) boots through this
   path on a real board. That is inferred from Frite's proven pattern, not
   confirmed for this SoC.
3. **NVMe boot** — MEDIUM confidence, better than prior project research. A
   documented working pattern exists ("Booting an Orange Pi 5 from NVMe"):
   U-Boot lives on SPI NOR/eMMC/SD and loads the kernel from there, and the
   NVMe device holds the ROOT filesystem. That is a narrower, better-verified
   claim than "U-Boot's own SPL/TPL can cold-boot directly off NVMe". This
   builder relies only on the kernel's NVMe driver (`CONFIG_BLK_DEV_NVME`) and on
   the installer accepting an `nvme0n1`-style target device (the same generic
   `*nvme*` partition-prefix handling the Frite and RPi5 installers use).
4. **WiFi** — CONFIRMED gap, matching prior project research. The common
   onboard/M.2 WiFi module (Broadcom/Cypress AP6275P, SDIO, brcmfmac-class) has
   ROUGH mainline support as of the research behind this platform: reports of
   association succeeding with no data path, device-tree overlay detection
   issues, and ongoing (2024-2025) patches that have not fully landed. WiFi is
   **OFF by default** (the same `harden_radios()` posture as every platform).
   Unlike Frite, which has no radio hardware, `--enable-wifi` here toggles a
   module that may not associate reliably. The kernel fragment and the builder
   both say so.
5. **Hardware crypto acceleration** — CONFIRMED to exist and be mainlined,
   contradicting the prior "no acceleration yet" note. RK3588 has a dedicated
   Rockchip crypto engine (2 cipher/hash pipelines). The mainline
   `CRYPTO_DEV_ROCKCHIP2` driver ("Rockchip cryptographic offloader V2",
   covering RK3566/RK3568/RK3588) registers `ecb(aes)`/`cbc(aes)`/`xts(aes)`/
   the SHA family/SM3. `xts(aes)` is the LUKS cipher. CONFIDENCE: MEDIUM on
   completeness (the driver is new upstream: first submitted late 2023, with
   algorithm coverage growing across revisions). It is an *additive, optional*
   accelerator (`CONFIG_CRYPTO_DEV_ROCKCHIP2=m`). The accelerator this fragment
   relies on is `CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions, a
   CPU-instruction accelerator that both the Cortex-A76 and Cortex-A55 cores
   implement).
6. **GPU / display** — HIGH confidence, with a naming trap worth recording. The
   Mali-G610 MP4's mainline KERNEL driver is **Panthor** (merged in Linux v6.10).
   Panfrost is the OLDER driver for Bifrost/Midgard Mali, not this GPU. But the
   MESA/Gentoo USERSPACE Gallium driver keeps the name **"panfrost"** after being
   extended to drive Panthor-kernel hardware (OpenGL ES 3.1 conformant on
   Mali-G610 as of Mesa 24.1.1). So `VIDEO_CARDS="panfrost"` in make.conf.tmpl
   is correct even though the kernel side has another name. Do not "fix" the
   split. Display (VOP2 and the RK3588 "HDMI QP" PHY variant) is the most
   VERSION-SENSITIVE item in this port: mainline HDMI output was reportedly not
   functional before Linux 6.13. **The gentoo-sources version this builder's
   cross-build pulls MUST be >= 6.13, or HDMI output may not work.**
   `kernel/hardened-desktop.config` calls this out as the item most likely to
   bite on real hardware.
7. **Orange Pi 5 Plus dual 2.5GbE** — HIGH confidence. Realtek RTL8125
   (PCIe-attached), handled by the in-tree mainline `r8169` driver. RTL8125
   support has been in `r8169` for many kernel releases, so no out-of-tree
   Realtek `r8125` driver is needed.
8. **General mainline kernel support level** — RK3588 mainline support has
   matured through 2023-2025, unevenly across subsystems. DTBs for the Orange
   Pi 5 family landed across several kernel versions (the 5 Plus DTB earlier, a
   5B DTB as late as October 2024). The Panthor GPU driver merged in 6.10. The
   Rockchip crypto-v2 driver was submitted in late 2023. HDMI/VOP2 display is
   reportedly usable only from 6.13. WiFi (AP6275P) is still rough in the most
   recent (2024-2025) reports found. **Use as recent a gentoo-sources kernel as
   is available at build time.** An older kernel will build and probably boot to
   a serial console, but will likely lack working HDMI output and full crypto
   acceleration.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax. `--print-plan` across the full board ×
flavor × desktop × standalone × encrypt-root matrix (internal consistency:
artifact names, kernel fragment and board-derived values all agree). That the
board table and the DTB/U-Boot-defconfig mapping match upstream U-Boot/Linux
naming as researched above. That this is a purely additive new-platform change
(no existing builder/specs tree touched). That it reuses the shared `specs/`
provisioning and mesh like every other client image. Template rendering: LIVE
emits `INITRD /initrd.img`, plaintext INSTALLER does not, and `--encrypt-root`
INSTALLER emits the disk-boot initramfs line.

**NEEDS REAL HARDWARE (or at least a full Gentoo cross-build environment, which
this sandbox lacks):** the aarch64 cross-emerge of the LXDE stack against THIS
platform's package/USE set. The mainline kernel build, and whether the in-tree
RK3588/RK3588S DTB names above still match the gentoo-sources version checked
out. The U-Boot TPL/SPL + BL31 blob assembly (needs the Rockchip rkbin blobs,
which we do not vendor). Whether a USB-written LIVE/INSTALLER ISO boots via
distro-boot on real hardware. HDMI/VOP2 producing a picture. Panthor + Mesa
panfrost accelerating the LXDE session. The crypto engine driver registering
and accelerating LUKS reads and writes. WiFi associating at all. NVMe as an
install target and as a boot-capable root. These steps MIRROR the proven
Frite/RPi5 flow but cannot be tested end to end here: no board, no full Gentoo
builder, and this sandbox may also lack network access for a real cross-emerge
(check before assuming otherwise).

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module names the mapper
   device `luks-<uuid>` instead of the name `root=` expects (`cryptroot`), and
   `root=/dev/mapper/cryptroot` never resolves. `install-orangepi5.sh` sets both,
   mirroring Frite and RPi5 (the Jetson builder has the same code, but it
   refuses `--encrypt-root`, so no Jetson build reaches it). The x86 installer
   sets only `rd.luks.uuid=` (`install-x86.sh:224`). Treat that as an x86 bug and
   do NOT copy it.
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows Frite's **on-device** model, not RPi5's **cross-host** model.
   `install-orangepi5.sh` runs from WITHIN the booted LIVE/INSTALLER session, ON
   the Orange Pi 5 that will unlock the root at every boot. The same board
   formats the volume and later reads it, so cryptsetup's argon2id auto-benchmark
   is trustworthy and deliberately NOT pinned. This judgment call is documented
   in `install-orangepi5.sh`'s header. It rests on this platform sharing Frite's
   live-bootable-ISO-on-real-hardware boot chain (U-Boot + extlinux distro-boot
   scanning a USB stick directly). RPi5 differs: its ISO is documented as NOT
   bootable on the Pi 5 itself, so a human runs the installer from a SEPARATE PC
   with an SD-card reader. There the PBKDF must be pinned to
   `--pbkdf-memory 262144 --iter-time 2000 --pbkdf-parallel 4`, so the LUKS
   header's cost matches the WEAKER target hardware, not the writing host. If
   operators for this board turn out to `dd` the ISO from a PC and never
   live-boot the installer ON the board, the call must flip to the pinned model.
   Next reviewer: check this.

## Front-end wiring (all-options-in-all-menus)

Under the all-options-in-all-menus rule: `make orangepi5`, `make orangepi5-live`
and `make orangepi5-installer` (the same pattern as `frite`/`frite-live`/
`frite-installer`: one dedicated platform, not a role loop like RPi5's 3
cluster-role target); `scripts/build-menu.sh`'s architecture picker and a
dedicated board/flavor/desktop screen; the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepi5_args()`); and `tests/build-matrix/matrix.tsv` + `check.sh`. All of
them reach this platform through the same `--print-plan` contract as every other
builder.

## Hardware-validation checklist (flip Status when done)

1. Assemble a real U-Boot TPL/SPL+BL31 image from Rockchip's rkbin blobs (or a
   community TF-A fork) for the target board and confirm it boots to a serial
   console (`ttyS2,1500000n8`).
2. Boot the LIVE image off USB on a real Orange Pi 5 Plus and a real Orange Pi
   5; confirm the dmsquash-live initramfs actually mounts the squashfs.
3. Run `install-orangepi5.sh` against onboard eMMC/microSD (and, on the Plus,
   NVMe) and confirm the installed system boots — PLAINTEXT first, then
   `--encrypt-root`.
4. Confirm HDMI output actually displays a picture (this is the single most
   version-sensitive claim in this port — see the GPU/display research note).
5. Confirm the LXDE session comes up with Panthor/Mesa-panfrost acceleration,
   not a software fallback.
6. Confirm dual 2.5GbE (Plus) enumerates via `r8169` and both links negotiate.
7. Attempt `--enable-wifi` and document the actual current AP6275P/brcmfmac
   behavior on real hardware (associates? passes traffic? neither?).

## Cross-references
- Closest architectural sibling: Frite. It has no `specs-frite/README.md`; its
  context is inline in `build-frite-stage4.sh`'s own header.
  `specs-jetson/README.md` was this file's template.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
