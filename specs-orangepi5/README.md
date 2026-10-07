# specs-orangepi5 — Orange Pi 5 / Orange Pi 5 Plus (Rockchip RK3588/RK3588S, arm64)

> **Status: EXPERIMENTAL — HARDWARE VALIDATION PENDING.** No physical Orange Pi
> 5 or Orange Pi 5 Plus has ever booted an image produced by this repo. Every
> RK3588/RK3588S-specific fact below (DTB names, U-Boot defconfigs, kernel
> Kconfig symbols, driver maturity) is **researched** (web search + kernel/Mesa/
> U-Boot upstream docs, cross-checked against a Gentoo user's own RK3588S
> write-up), **not hardware-verified in this environment** — there is no RK3588
> hardware, and no network access to actually cross-emerge a real Gentoo tree,
> available in this sandbox. Treat this exactly like `specs-jetson/` was
> treated: it is also unvalidated. Buildable and internally
> consistent (`--print-plan` clean across the whole role/board/flag matrix),
> but **do not trust it to boot** until a real board confirms it end-to-end.

## What this adds

A lean, hardened LXDE **light desktop** client image for the Orange Pi 5 family
— a **client device**, like Frite, not a K8s cluster node. Reuses the SAME
aarch64 cross toolchain + shared `specs/` mesh/provisioning/sshd plumbing as
every other client image (Frite/RPi5-desktop/Jetson-desktop): headscale/
tailscale mesh join, hardened key-only sshd, KEYS-USB first-boot provisioning,
and — from day one — full `--standalone` (local user, no mesh, build-time
password) and `--encrypt-root` (LUKS2 full-disk encryption) support.

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
Mali-G610 MP4, ~6 TOPS NPU) — the difference is peripheral I/O only. RK3588S
drops native HDMI input, one of two HDMI 2.1 outputs, one of two DP1.4 outputs,
all four PCIe3.0 lanes, and one PCIe2.0 lane relative to RK3588. This is why
the Plus (RK3588, the fuller chip) is the safer/more-capable default: it is
strictly a superset of the base board's I/O, and the extra 2.5GbE + PCIe/NVMe
capability is exactly what the task's headline features want to showcase.

Both boards default to `--flavor both` (LIVE + INSTALLER, mirroring Frite) and
the single `desktop` role (no `--role` axis with cluster-node choices — this is
explicitly a client-device board, like Frite, per the standalone-desktop plan).

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

We do **not** vendor the rkbin DDR-init/BL31 blobs here (licensing — same
rationale as Frite's Amlogic FIP/BL31). The builder downloads a prebuilt,
board-specific U-Boot image when `--uboot-url` is given, else it warns and
leaves a slot for the operator to drop one in (identical mechanism to Frite's
`--uboot-url`).

## Research findings by topic (confidence-graded)

1. **Chip variant** — HIGH confidence. See board table above.
2. **Boot chain** — MEDIUM-HIGH confidence on the chain shape (TPL/SPL+rkbin
   DDR blob -> TF-A BL31 (rkbin/community fork) -> U-Boot -> extlinux distro-
   boot); HIGH confidence that extlinux/distro-boot (not UEFI, not config.txt)
   is the mainline mechanism, since this matches Frite's architecture exactly
   and every source consulted describes U-Boot scanning `/extlinux/
   extlinux.conf`. **Not hardware-verified**: whether a USB-stick-written LIVE/
   INSTALLER medium (this builder's `xorriso -as mkisofs` ISO, same as Frite)
   actually boots via this exact distro-boot path on a real board — this is an
   architectural inference from Frite's proven pattern, not a confirmed fact
   for THIS SoC.
3. **NVMe boot** — MEDIUM confidence, IMPROVED vs. prior project research. A
   documented working pattern exists ("Booting an Orange Pi 5 from NVMe"):
   U-Boot lives on SPI NOR/eMMC/SD and loads the kernel from there; the NVMe
   device is then used as the ROOT filesystem. This is NOT the same claim as
   "U-Boot's own SPL/TPL can cold-boot directly off NVMe" (narrower, less
   verified) — this builder only relies on the kernel-side NVMe driver
   (`CONFIG_BLK_DEV_NVME`) plus the installer accepting an `nvme0n1`-style
   target device (the SAME generic `*nvme*` partition-prefix handling
   Frite/RPi5's installers already use), which is a safe, well-understood
   pattern regardless of the cold-boot nuance above.
4. **WiFi** — CONFIRMED gap, matches prior project research. The common
   onboard/M.2 WiFi module (Broadcom/Cypress AP6275P, SDIO, brcmfmac-class) has
   ROUGH mainline support as of the research behind this platform: reports of
   association succeeding but no data path, device-tree overlay detection
   issues, and ongoing (2024-2025) patch activity that has not fully landed.
   WiFi stays **OFF by default** (same `harden_radios()` posture as every other
   platform), and unlike Frite (which has literally no radio hardware),
   `--enable-wifi` here toggles a module that may simply not associate
   reliably — this is flagged loudly in the kernel fragment and the builder.
5. **Hardware crypto acceleration** — CONFIRMED to exist and be mainlined,
   contradicting the prior "no acceleration yet" note. RK3588 has a dedicated
   Rockchip crypto engine (2 cipher/hash pipelines); the mainline
   `CRYPTO_DEV_ROCKCHIP2` driver ("Rockchip cryptographic offloader V2",
   covering RK3566/RK3568/RK3588) registers `ecb(aes)`/`cbc(aes)`/`xts(aes)`/
   SHA family/SM3 — `xts(aes)` is exactly LUKS's cipher. CONFIDENCE: MEDIUM on
   completeness (the driver is relatively new upstream, initial submission
   late 2023, algorithm coverage grew across revisions) — kept as an
   *additive, optional* accelerator (`CONFIG_CRYPTO_DEV_ROCKCHIP2=m`) on top of
   the GUARANTEED accelerator this fragment actually relies on:
   `CRYPTO_AES_ARM64_CE_BLK` (ARMv8 Crypto Extensions, a CPU-instruction
   accelerator both the Cortex-A76 and Cortex-A55 cores implement).
6. **GPU / display** — HIGH confidence, and a real naming gotcha worth
   documenting explicitly: the Mali-G610 MP4's mainline KERNEL driver is
   **Panthor** (merged Linux v6.10 — Panfrost is the OLDER driver for
   Bifrost/Midgard Mali, not this GPU), but the MESA/Gentoo USERSPACE Gallium
   driver keeps the name **"panfrost"** even after being extended to drive
   Panthor-kernel hardware (OpenGL ES 3.1 conformant on Mali-G610 as of Mesa
   24.1.1) — so `VIDEO_CARDS="panfrost"` in make.conf.tmpl is correct despite
   the kernel side being named differently; do not "fix" this naming split by
   accident later. Display (VOP2 + the RK3588 "HDMI QP" PHY variant) is the
   single most VERSION-SENSITIVE item in this whole port: mainline HDMI output
   was reportedly not functional before Linux 6.13. **Whatever gentoo-sources
   version this builder's cross-build actually pulls MUST be >= 6.13 or HDMI
   output may simply not work** — this is called out in
   `kernel/hardened-desktop.config` as the item most likely to bite on real
   hardware.
7. **Orange Pi 5 Plus dual 2.5GbE** — HIGH confidence. Realtek RTL8125
   (PCIe-attached), handled by the in-tree mainline `r8169` driver (RTL8125
   support has been in `r8169` for many kernel releases now — no out-of-tree
   Realtek `r8125` driver needed).
8. **General mainline kernel support level** — RK3588 mainline support has
   matured substantially through 2023-2025 but unevenly across subsystems:
   DTBs for the Orange Pi 5 family landed across several kernel versions (the
   5 Plus DTB earlier, a 5B DTB as late as October 2024); the Panthor GPU
   driver merged in 6.10; the Rockchip crypto-v2 driver submitted late 2023;
   HDMI/VOP2 display only reportedly usable from 6.13; WiFi (AP6275P) still
   rough as of the most recent (2024-2025) reports found. **Practical
   recommendation: target as recent a gentoo-sources kernel as is available at
   build time** — an older kernel will build and probably boot to a serial
   console, but will likely be missing working HDMI output and full crypto
   acceleration.

## What is verified vs. what needs real hardware

**VERIFIED HERE:** `bash -n` syntax; `--print-plan` across the full board ×
flavor × desktop × standalone × encrypt-root matrix (internal consistency —
reported artifact names / kernel fragment / board-derived values all agree);
that the board table + DTB/U-Boot-defconfig mapping matches upstream U-Boot/
Linux naming as researched above; that this is a purely additive new-platform
change (no existing builder/specs tree touched); that it reuses the shared
`specs/` provisioning + mesh exactly like every other client image; template
rendering (LIVE emits `INITRD /initrd.img`, plaintext INSTALLER does not,
`--encrypt-root` INSTALLER emits the disk-boot initramfs line).

**NEEDS REAL HARDWARE (or at minimum a full Gentoo cross-build environment
this sandbox does not have) TO VERIFY:** the actual aarch64 cross-emerge of the
LXDE stack against THIS platform's package/USE set; the mainline kernel build
+ whether the in-tree RK3588/RK3588S DTB names above still match whatever
gentoo-sources version is checked out; the U-Boot TPL/SPL+BL31 blob assembly
(needs the real Rockchip rkbin blobs, which we do not vendor); whether a
USB-written LIVE/INSTALLER ISO genuinely boots via distro-boot on real
hardware; HDMI/VOP2 display actually producing a picture; Panthor+Mesa
panfrost actually accelerating the LXDE session; the crypto engine driver
actually registering and accelerating LUKS reads/writes; WiFi associating at
all; NVMe as an install target and as a boot-capable root. These steps are
written to MIRROR the proven Frite/RPi5 flow but cannot be end-to-end tested in
this environment (no board, no full Gentoo builder, and this sandbox may also
lack network access for a real cross-emerge — check before assuming
otherwise).

## LUKS2 full-disk encryption — the two hard-won lessons, applied here

1. **`rd.luks.uuid=` MUST pair with `rd.luks.name=<uuid>=<mapper-name>`.**
   Without the paired `rd.luks.name=`, dracut's `crypt` module defaults the
   mapper device to `luks-<uuid>` instead of the name `root=` actually expects
   (`cryptroot`), and `root=/dev/mapper/cryptroot` never resolves —
   `install-orangepi5.sh` sets both, mirroring Frite and RPi5 (the Jetson builder
   has the same code, but it refuses `--encrypt-root`, so no Jetson build reaches
   it). The x86 installer sets only `rd.luks.uuid=` (`install-x86.sh:224`) —
   treated as an x86 bug to NOT copy, not a pattern to follow.
2. **PBKDF pinning depends on WHERE the LUKS format actually runs.** This
   platform follows Frite's **on-device** model, not RPi5's **cross-host** model: `install-orangepi5.sh` runs from WITHIN the booted
   LIVE/INSTALLER session, ON THE ACTUAL Orange Pi 5 board that will later
   unlock the root at every boot (the same board formats it and later reads
   it) — so cryptsetup's argon2id auto-benchmark is trustworthy and
   deliberately NOT pinned. This is a genuine architectural judgment call
   (documented in `install-orangepi5.sh`'s header) based on this platform
   sharing Frite's live-bootable-ISO-on-real-hardware boot chain (U-Boot +
   extlinux distro-boot scanning a USB stick directly) rather than RPi5's
   situation, where the produced ISO is explicitly documented as NOT bootable
   on the Pi 5 itself (so a human runs the installer from a SEPARATE PC with
   an SD-card reader, and the PBKDF must be pinned to
   `--pbkdf-memory 262144 --iter-time 2000 --pbkdf-parallel 4` so the LUKS
   header's cost matches the WEAKER target hardware, not the writing host). If
   real-world operator practice for this board turns out to differ (e.g.
   operators routinely `dd` the ISO from a PC and never actually live-boot the
   installer ON the board), this judgment call would need to flip to the
   pinned model — flagged here explicitly for the next reviewer.

## Front-end wiring (all-options-in-all-menus)

Per the all-options-in-all-menus standing rule: `make orangepi5`,
`make orangepi5-live`, `make orangepi5-installer` (mirroring the `frite`/
`frite-live`/`frite-installer` pattern — a single dedicated platform, not a
role-loop the way RPi5's 3-cluster-role target is), `scripts/build-menu.sh`'s
architecture picker + a dedicated board/flavor/desktop screen, the Studio
(`studio/hugmesh_studio/core/config.py`'s `BUILDER_SCRIPTS`/`ROLE_CHOICES`/
`_orangepi5_args()`), and `tests/build-matrix/matrix.tsv` + `check.sh` all
reach this platform through the same `--print-plan` contract as every other
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
  context is inline in `build-frite-stage4.sh`'s own header. `specs-jetson/README.md`
  was this file's template.
- Hardware-profile / EXPERIMENTAL precedent: `specs-jetson/README.md`.
- Standalone posture: `docs/STANDALONE-DESKTOP.md`.
