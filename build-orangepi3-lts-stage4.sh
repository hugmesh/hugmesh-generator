#!/usr/bin/env bash
# Build a hardened Gentoo aarch64 HEADLESS APPLIANCE image for the Orange Pi
# 3 LTS (Allwinner H6) using the same crossdev toolchain + shared mesh/
# provisioning plumbing as the Frite/Pi5/Orange-Pi-5/x86 client images.
#
# ── EXPERIMENTAL PLATFORM — READ THIS FIRST (see specs-orangepi3-lts/README.md) ──
# No physical Orange Pi 3 LTS has ever booted an image from this repo. Every
# H6-specific fact below (boot chain, DTB/U-Boot-defconfig names, driver
# maturity) is RESEARCHED (direct fetch of live mainline Linux/U-Boot upstream
# source trees, not just secondary claims about them), NOT hardware-verified in
# this environment — there is no H6 hardware, and this sandbox may also lack
# the network access needed for a real cross-emerge (check before assuming
# otherwise). Treat this with the SAME EXPERIMENTAL posture
# build-jetson-stage4.sh / build-orangepi5-stage4.sh carry: buildable and
# internally consistent (--print-plan clean across the whole flag matrix), NOT
# proven to boot.
#
# ── WHY HEADLESS-ONLY — a SCOPE decision here, NOT the H616 siblings' hard gap ──
# HONESTY NOTE: the Zero 2/Zero 2W/Zero 3 siblings are headless because
# mainline has no working DE33 display pipeline — a hard driver gap. The H6 is
# NOT in that situation: mainline drivers/gpu/drm/sun4i/ carries BOTH an H6
# DE3 mixer ("allwinner,sun50i-h6-de3-mixer-0" in sun8i_mixer.c) and the H6
# DW-HDMI wrapper ("allwinner,sun50i-h6-dw-hdmi" in sun8i_dw_hdmi.c), and the
# mainline sun50i-h6-orangepi-3.dts ships an ENABLED &hdmi node (all CONFIRMED
# by direct fetch for this port). This platform is headless anyway, for three
# reasons (full trail in specs-orangepi3-lts/README.md): (1) the mainline H6
# display pipeline is real but rough for an appliance-grade default, and it
# would run on BORROWED wiring — the DTB this image boots is the PLAIN Orange
# Pi 3's (mainline has NO -lts DTS at all), so even the display wiring is only
# ASSUMED to match the LTS revision; (2) template parity — this is a faithful
# derivation of the Zero 2 headless appliance: ONE role, a flavor axis only,
# no desktop/board axis anywhere in the four build channels; (3) appliance
# profile — an SSH-only mesh/VPN utility node. If a real board validates the
# mainline H6 display path on the LTS revision, revisiting this scope is
# LEGITIMATE here (unlike on the H616 siblings) — but do it as a deliberate
# scope change, not by copy-pasting another platform's GPU/X11 config.
#
# So: this image ships NO X11/desktop package, NO GPU/DRM kernel config, NO
# framebuffer console beyond the serial UART — see
# specs-orangepi3-lts/kernel/hardened-appliance.config's header for the exact
# same reasoning restated at the point a future contributor is most likely to
# be tempted to copy-paste GPU config in from another platform's fragment.
#
# WHY a separate builder (not a flag on another platform's script): a
# different SoC vendor generation (Allwinner H6, not Amlogic GXL/Rockchip
# RK3588/BCM2712/Tegra234) with its OWN, genuinely notable boot-chain property
# (see below), its own DTB/U-Boot-defconfig names, and — uniquely among every
# platform in this repo — an architecturally DIFFERENT kind of client than the
# desktop-role platforms: a lean, hardened, SSH-only network appliance (think:
# a small VPN/mesh gateway node, a tiny home-lab utility box), not "yet another
# desktop that happens to have no GUI." Naming throughout (this ROLE default,
# the CLI help text, artifact names, the Studio role label) says "appliance",
# never "desktop", so a future maintainer never wonders why this is the one
# platform in the repo with no desktop option at all — it isn't a stripped-down
# desktop, it was never meant to have one.
#
# ── BOOT CHAIN — the family's blob-free-boot trait carries over ───────────────
# Rockchip (Orange Pi 5) needs rkbin's DDR-init + TF-A BL31 blobs. Amlogic
# (Frite) needs a FIP/BL31 blob. The H6 does NOT: mainline U-Boot ships a
# GENUINELY NATIVE DRAM-init driver for this exact SoC
# (configs/orangepi_3_defconfig selects CONFIG_SUNXI_DRAM_H6_LPDDR3=y —
# CONFIRMED by fetching that defconfig from the live upstream U-Boot tree; no
# closed "boot0" blob is loaded or required at any stage; TF-A BL31 is needed
# but is open source). TWO honest degradations vs the Zero 2 template though:
# (a) that defconfig is the PLAIN Orange Pi 3's — mainline has NO
# orangepi_3_lts_defconfig (hard 404, confirmed) — so the LTS revision boots
# on the plain board's support, and (b) the blob-free chain is BOOT-ONLY here,
# NOT boot+network: the mainline sun50i-h6-orangepi-3.dts ships NO ethernet
# node at all (confirmed by direct fetch — the OPi3 enable-ethernet DT patch
# never landed, and the LTS swapped the PHY to a Motorcomm YT8531C besides),
# so the physical GbE jack is DEAD on the DTB this image boots. This appliance
# is USB-Ethernet-first (the Zero 2W posture): USB-CDC/RTL8152/AX88179 classes
# in the kernel fragment, with the all-mainline dwmac-sun8i+PHY stack kept
# inert for a user-supplied -lts DTS overlay. WiFi (the LTS's Unisoc UWE5622)
# remains CONFIRMED to have no mainline kernel.org driver at all.
#
# ONE role (a headless network appliance — NOT a desktop, and NOT a K8s
# cluster node with a --role axis of cluster-node choices — matching Frite/
# Orange-Pi-5's "one client-device role" shape). Full --standalone (local user,
# no mesh, LUKS2 FDE on install) and --encrypt-root support from day one,
# following the Frite/Orange-Pi-5 on-device LUKS format model (see below).
#
# Two image FLAVORS, both produced by this one generation option (toggle):
#   live      — boots-and-runs ephemerally off microSD/USB: squashfs rootfs in
#               RAM, no persistence.
#   installer — a LIVE image that ALSO carries install-orangepi3-lts.sh + the
#               stage4, to write the appliance to the onboard 8GB eMMC (a
#               storage class the Zero 2 template lacks — mainline enables
#               this board's mmc2), a microSD card, or a USB stick (the SAME
#               one it booted from, or a second one — see the installer's own
#               header; no NVMe — the H6's quirky PCIe is unusable in
#               mainline). The default below builds BOTH (--flavor both).
#
# ── ON-DEVICE LUKS FORMAT MODEL (mirrors Frite/Orange-Pi-5, NOT RPi5/Jetson) ──
# install-orangepi3-lts.sh runs FROM WITHIN the booted LIVE/INSTALLER session,
# ON THE ACTUAL Orange Pi 3 LTS board that will later unlock the root at
# every boot — because this board's boot chain (U-Boot + extlinux distro-boot
# scanning a microSD/USB stick directly) makes the produced image genuinely
# bootable on real hardware, unlike RPi5's installer ISO (explicitly documented
# as NOT bootable on the Pi 5 itself). Because format-time and unlock-time
# hardware are the SAME machine here, cryptsetup's argon2id PBKDF
# auto-benchmark is TRUSTWORTHY and install-orangepi3-lts.sh deliberately does
# NOT pin --pbkdf-memory/--iter-time/--pbkdf-parallel (unlike install.sh (RPi5)
# / build-jetson-stage4.sh, which must pin those params because their
# format-host != their unlock-host). This is the SAME genuine architectural
# judgment call Orange Pi 5's Phase 7 made for the same underlying reason (a
# live+installer image that boots on the board itself) — see
# specs-orangepi3-lts/README.md if it ever needs revisiting. The SECOND
# hard-won LUKS lesson (rd.luks.uuid= MUST pair with rd.luks.name=<uuid>=
# cryptroot, or root=/dev/mapper/cryptroot never resolves) is applied in
# install-orangepi3-lts.sh exactly like every other platform's installer.
#
# Run as root (sudo): the cross-emerge merges into the sysroot's vdb and writes
# the host emerge log/cache, so real root is required (fakeroot is NOT enough).
#
# ── VERIFIED vs NEEDS-HARDWARE (read this) ─────────────────────────────────────
# VERIFIED HERE: bash -n syntax; option parsing; the DTB/U-Boot-defconfig
#   values (researched against upstream U-Boot/Linux naming, including a direct
#   fetch of the actual defconfig/devicetree files); that it reuses the shared
#   specs/ provisioning + mesh exactly like every other client image; template
#   rendering (LIVE emits `INITRD /initrd.img`, plaintext INSTALLER does not,
#   `--encrypt-root` INSTALLER emits the disk-boot initramfs line); that the
#   Frite/Pi5/x86/Jetson/Orange-Pi-5 paths are untouched.
# NEEDS REAL HARDWARE / A FULL GENTOO CROSS-BUILD TO VERIFY: the actual aarch64
#   cross-emerge of this package set; the mainline kernel build + whether the
#   in-tree H6 DTB name still matches whatever gentoo-sources version is
#   checked out; whether the PLAIN OPi3's U-Boot defconfig + DTB actually boot
#   the LTS revision at all (the port's central bet — see the README); the
#   cross-generated dmsquash-live initramfs actually mounting the squashfs and
#   booting on a real board; the microSD/eMMC/USB install; whether the mainline
#   U-Boot LPDDR3 training parameters in orangepi_3_defconfig hold on the LTS's
#   single 2GB LPDDR3 SKU. These steps MIRROR the proven Frite/Orange-Pi-5 flow
#   but cannot be end-to-end tested here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-orangepi3-lts"   # aarch64/Orange-Pi-3-LTS-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"               # arch-agnostic specs (mesh, provisioning, sshd)

# Supply-chain download verification (OWASP). Shared helper so the stage3 seed,
# headscale, and tailscale fetches are GPG/checksum-verified by ONE audited
# implementation instead of trusting a bare `curl`. See scripts/_download-lib.sh.
# shellcheck source=scripts/_download-lib.sh
source "${SCRIPT_DIR}/scripts/_download-lib.sh"
# Shared /etc/shadow password-KDF helper (ph_crypt_hash): yescrypt ($y$) where
# the build host's libcrypt provably supports it, SHA-512 crypt ($6$) fallback.
# shellcheck source=scripts/_passhash-lib.sh
source "${SCRIPT_DIR}/scripts/_passhash-lib.sh"

# Cross-dracut helper: qemu-aarch64 binfmt registration + the availability
# predicate the --encrypt-root fail-fast preflight and the qemu-chroot initramfs
# strategy rely on. Shared so the ARM boards do not drift on the load-bearing
# bit. See scripts/_dracut-cross-lib.sh.
# Host-safety guard: the container predicate gating every HOST-mutating step
# (the /etc/portage seeds + the host emerge below, and _dracut-cross-lib.sh's
# kernel-global binfmt registration). Fail-safe: an unproven runtime is treated
# as the operator's real machine and nothing is written. See
# scripts/_host-guard-lib.sh.
# shellcheck source=scripts/_host-guard-lib.sh
source "${SCRIPT_DIR}/scripts/_host-guard-lib.sh"
# Per-board binpkg-pool fingerprint guard (shared-binpkg track): the load-bearing
# SIGILL safety net — REFUSES --usepkg reuse of a pool whose (CHOST + exact
# CFLAGS/-mcpu + profile) fingerprint != this build's. All aarch64 boards share
# CHOST but differ in -mcpu, and portage's --binpkg-respect-use ignores CFLAGS.
# shellcheck source=scripts/_binpkg-pool-lib.sh
source "${SCRIPT_DIR}/scripts/_binpkg-pool-lib.sh"
# Shared build-asset root (stage3 seed cache + fleet distfiles + per-BOARD binpkg
# pool) and its flock discipline — the ONE resolver every builder uses, so the path
# logic is not duplicated across ten scripts. See scripts/_shared-assets-lib.sh and
# docs/SHARED-BINPKG.md.
# shellcheck source=scripts/_shared-assets-lib.sh
source "${SCRIPT_DIR}/scripts/_shared-assets-lib.sh"
# Seed-derived PYTHON_TARGETS/PYTHON_SINGLE_TARGET (pt_apply_seed_targets).
# A frozen python3_NN literal is a BUG — see docs/PYTHON-TARGETS-SEED-DRIFT.md.
# shellcheck source=scripts/_python-targets-lib.sh
source "${SCRIPT_DIR}/scripts/_python-targets-lib.sh"
# shellcheck source=scripts/_portage-config-lib.sh
source "${SCRIPT_DIR}/scripts/_portage-config-lib.sh"
# ── BEGIN shared block: SELinux node-policy lib ───────────────────────────────
# shellcheck source=scripts/_selinux-policy-lib.sh
source "${SCRIPT_DIR}/scripts/_selinux-policy-lib.sh"
# ── END shared block: SELinux node-policy lib ─────────────────────────────────
# Requested-atom completeness gate (cross-build twin of build-x86-host-stage4.sh's
# in-chroot gate, PR #461/#465): after the --keep-going payload emerge, every
# requested atom must be in the TARGET sysroot's vdb or the build fails listing
# the gaps — the binary assert below it misses anything without a probed binary
# (the exact hole that shipped firewalld-less rpi5 images, see the lib header).
# The kernel tier also closes THIS builder's worst degradation: a failed
# sys-kernel/gentoo-sources emerge used to warn-skip Phase 3 and exit 0 with an
# UNBOOTABLE kernel-less artifact.
# shellcheck source=scripts/_payload-gate-lib.sh
source "${SCRIPT_DIR}/scripts/_payload-gate-lib.sh"
# ── BEGIN shared block: emerge-plan preview (lib) ─────────────────────────────
# Read-only --pretend plan preview emitted immediately before the multi-package
# emerge sections (system + image) so the Studio can list what WILL be
# installed up front — portage prints no resolved plan during a normal merge,
# so the list must come from a deliberate pretend pass. Host-side source (the
# cross lane emerges from the host; x86 stages the same lib into its chroot).
# Opt out with --no-emerge-plan; every failure path inside the lib WARNs and
# returns 0 — a cosmetic preview never costs an image. See
# docs/EMERGE-PLAN-PREVIEW.md for the honest cost discussion.
# shellcheck source=scripts/_emerge-plan-lib.sh
source "${SCRIPT_DIR}/scripts/_emerge-plan-lib.sh"
# ── END shared block: emerge-plan preview (lib) ───────────────────────────────
# shellcheck source=scripts/_dracut-cross-lib.sh
source "${SCRIPT_DIR}/scripts/_dracut-cross-lib.sh"

# NODE-STORAGE bake: bake_node_storage() — ONE definition of the four-file bake for
# every builder, so tests/node-storage/test-bake-coverage.sh can EXECUTE it against a
# sandbox sysroot instead of grepping this file for strings that a comment, a wrong
# destination or a dead branch all leave untouched.
# shellcheck source=scripts/_node-storage-bake-lib.sh
source "${SCRIPT_DIR}/scripts/_node-storage-bake-lib.sh"

WORK_DIR=""
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-orangepi3-lts}"   # per-arch isolation (never shares another sysroot)
DISTDIR_SRC="${SNAP_DISTDIR_SRC:-}"   # --distdir DIR / SNAP_DISTDIR_SRC env: shared READ-ONLY distfiles cache (arch-independent sources → safe fleet-wide). Empty = private per-build DISTDIR only.
# --shared-assets DIR / --no-shared-assets (env: HUGMESH_SHARED_ASSETS): the fleet's
# SHARED build-asset root — stage3 seed cache, distfiles, and the per-BOARD binpkg
# pool. Empty ⇒ "${WORK_DIR}/shared", which the Makefile's `-v $(WORK_DIR):/out`
# docker mount already covers (no new mount). --no-shared-assets restores the legacy
# per-BUILD_ROOT seed/distfiles/pkgdir paths byte-for-byte.
SHARED_ASSETS_DIR="${HUGMESH_SHARED_ASSETS:-}"
SHARED_ASSETS_ENABLED=true
PACKAGES_ONLY=false   # --packages-only: prebuild the per-board binpkg pool then exit BEFORE image assembly (kernel/img/iso/tar). Host/CI build-phase flag, NOT a Studio ImageConfig field.
# --allow-missing-packages : accept a KNOWINGLY degraded image. The payload emerge
# runs --keep-going; the requested-atom completeness gate after it then FAILS the
# build when any requested atom did not actually install. Escape hatch only —
# never a Studio field. NB: it can NOT bypass the kernel tier (a kernel-less
# image is unbootable, not degraded; --skip-kernel is the only kernel opt-out).
ALLOW_MISSING_PACKAGES=false
# --no-emerge-plan : skip the read-only `--pretend` plan-preview pass that runs
# before the system and image emerges (scripts/_emerge-plan-lib.sh). The pass
# is a SECOND full dependency resolution per planned section — real, unmeasured
# cost, see docs/EMERGE-PLAN-PREVIEW.md — whose only product is the Studio's
# up-front "packages that WILL be installed" list. Build-phase opt-out in the
# --allow-missing-packages class (never a Studio field); the emission itself is
# failure-tolerant either way (WARN + no plan, never an aborted build).
EMERGE_PLAN_ENABLED=true
CROSS_TARGET="aarch64-unknown-linux-gnu"
REL_VERSION="2026.0"

# ── Board values (NO --board axis: this is ONE specific board, unlike Frite's
# 3-board / Orange Pi 5's 2-board tables) — overridable directly via
# --cpu/--dtb/--defconfig/--uboot-defconfig for the rare case a fork of this
# board needs a different value, exactly like every other platform's escape
# hatch. ─────────────────────────────────────────────────────────────────────
OPI3LTS_CPU="cortex-a53"                              # H6: quad Cortex-A53, no big.LITTLE split
OPI3LTS_DEFCONFIG="defconfig"                         # generic arm64 mainline kernel defconfig
OPI3LTS_KERNEL_IMG="Image"
# DTB path CONFIRMED against upstream arch/arm64/boot/dts/allwinner/ (the file
# is sun50i-h6-orangepi-3.dts, including sun50i-h6.dtsi + sun50i-h6-cpu-opp.dtsi
# — the PLAIN Orange Pi 3's: mainline has NO -lts DTS, see the README's
# board-constants delta).
OPI3LTS_DTB="allwinner/sun50i-h6-orangepi-3.dtb"
# U-Boot defconfig CONFIRMED against upstream U-Boot configs/ (contains native
# CONFIG_SUNXI_DRAM_H6_LPDDR3=y training — no blob reference of any kind; the
# PLAIN Orange Pi 3's defconfig: orangepi_3_lts_defconfig does NOT exist
# upstream, confirmed hard-404 — see the header's "boot chain" note).
OPI3LTS_UBOOT_DEFCONFIG="orangepi_3_defconfig"

JOBS="$(nproc)"
SKIP_KERNEL=false
SKIP_CLEAN=false
RESUME=false
IMAGE_ONLY=false          # skip Phase 1-3 entirely; go straight to Phase 4 image assembly

# ── Image flavors (the LIVE / INSTALLER toggle) ────────────────────
# both (DEFAULT) = produce the LIVE squashfs image AND the INSTALLER image.
OPI3LTS_FLAVOR="both"                             # live | installer | both
ROOT_MiB=2048                                   # ext4 root size for the installer's persistent build (lean appliance, no desktop payload)
GROW_POLICY="fill"
COMPRESS_IMG=false
EXTRA_PACKAGES=""
PACKAGES_ADD=""          # --packages-add : atoms to add on top of the derived set
PACKAGES_DROP=""         # --packages-drop: default-set atoms to remove (mandatory floor honored)
TIMEZONE="UTC"
HOSTNAME=""
ROLE="appliance"                                # this image's role marker — a HEADLESS APPLIANCE, never "desktop"
CLUSTER_DOMAIN="hugmesh.systems"
# Orchestration superdomain (WS-SUPER-B): the mesh control plane's MagicDNS suffix every
# node joins. "" = builder default (legacy byte-identical). The Studio emits --superdomain
# <effective> only for MESH builds; permanently internal, never the go-live apex.
SUPERDOMAIN=""
BRAND="hugmesh"
BRAND_TITLE="HugMesh Systems"
ORG="hugmesh-net"
# ENV (test|prod) selector — kept for parity with the cluster builders (it
# shapes the same branding/creds knobs), BUT this image is a LEAN HEADLESS
# APPLIANCE, NOT a K8s cluster node: it bakes NO specs/cluster GitOps tree and
# therefore has NO installed-services ConfigMap, NO optional-services gate, NO
# public ingress. Mirrors build-frite-stage4.sh / build-orangepi5-stage4.sh's
# identical ENV rationale.
ENV="test"
CONFIG_FILE=""
DEFAULT_USER="orangepi3lts"
# NO baked default password. Real creds come from the KEYS USB ($6$ hashes in
# users.json via keys-provision). On a keyless boot the first-boot finaliser
# mints a RANDOM one-time password and locks root — see the OWASP "default
# creds baked into image" fix.
#
# ── Standalone posture (mirrors build-x86-host-stage4.sh / build-frite-stage4.sh
# / build-orangepi5-stage4.sh) ──────────────────────────────────────────────
# --standalone composes onto this image: no mesh, a normal local user logs in
# over SSH with a password set at build time instead of the KEYS-USB-
# provisioned account, and (via --encrypt-root, auto-on for --standalone) the
# INSTALLED root is LUKS2 full-disk encrypted — install-orangepi3-lts.sh does
# the actual partition/format/unlock at install time, never baked into the
# build artifact. See docs/STANDALONE-DESKTOP.md.
STANDALONE=false        # --standalone : local user, no mesh, LUKS2 FDE on install
LOCAL_USER=""           # --local-user NAME : the standalone local login account
LOCAL_USER_PASS=""      # --local-pass PASS : plaintext; hashed at build, never baked raw
ENCRYPT_ROOT=false      # --encrypt-root : installer LUKS2-encrypts the target root; auto-on for --standalone
LUKS_PASS=""            # --luks-pass : OPTIONAL unattended passphrase (lands on the installer ISO — warned)

# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ──────────
# The LTS board's ONBOARD radio (a Unisoc UWE5622 WiFi+BT combo module, per
# the vendor sheet — the plain OPi3's Broadcom AP6256 nodes in the mainline
# DTB bind nothing on it) has NO mainline kernel.org driver at all — not even
# a rough one (CONFIRMED, inherited from the Zero 2/Zero 2W research). No
# onboard-radio kernel module is even built here (see
# kernel/hardened-appliance.config) — the flags below only matter if a USB
# WiFi/Bluetooth dongle with its OWN already-mainlined driver is attached
# (harden_radios() blacklists the generic cfg80211/mac80211/bluetooth/btusb
# modules regardless, same posture as every other platform). USB Ethernet +
# the tailnet are this appliance's primary, reliable network path (the onboard
# GbE jack is dead on the mainline DTB — see the header).
ENABLE_WIFI="${ENABLE_WIFI:-false}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-false}"
# Root SSH login DISABLED by default (hardened); opt back in with --permit-root-login.
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-no}"
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt"
# Default to the shipped Gentoo release-eng key so builds work without network
# access to a keyserver (keys.openpgp.org can be unreachable). Override with
# DLV_OFFLINE_KEYRING=<file> or DLV_KEYSERVER=<url> to use a different source.
DLV_OFFLINE_KEYRING="${DLV_OFFLINE_KEYRING:-${SCRIPT_DIR}/scripts/gentoo-release-key.asc}"

# Mesh VPN (installed as upstream static arm64 binaries, not emerged) — IDENTICAL
# to the Frite/Pi5/Orange-Pi-5 client images so this board joins the same
# headscale/tailscale mesh.
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false

# --print-plan: resolve + validate everything, print the machine-greppable build
# plan (one PLAN_KEY=VALUE per line) and exit 0 BEFORE any mutation (no root, no
# disk writes, no network). The CLI/make/menu/Studio channels + the build-matrix
# harness (tests/build-matrix/check.sh) verify every flag combo through it.
PRINT_PLAN=false

# U-Boot: UNLIKE every other arm64 platform in this repo, this board needs NO
# proprietary blob at all (see the header's "boot chain" note) — mainline
# U-Boot alone has a native DRAM-init driver for this SoC. We still fetch a
# prebuilt board U-Boot image via --uboot-url when given (or warn otherwise),
# mirroring the Frite/Orange-Pi-5 escape hatch, rather than attempting a real
# from-source U-Boot cross-build here — that IS a realistic future enhancement
# now that no blob is required (unlike Frite/Orange-Pi-5, where a from-source
# build alone would still not be flashable), but is out of scope for this pass
# given no hardware exists in this environment to validate a from-source build
# against. See specs-orangepi3-lts/README.md.
OPI3LTS_UBOOT_URL="${OPI3LTS_UBOOT_URL:-}"          # optional: prebuilt board u-boot.bin URL
SKIP_UBOOT=false

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'
BOLD='\033[1m'; RESET='\033[0m'
banner() { echo -e "\n${CYAN}${BOLD}==> $1${RESET}"; }
info()   { echo -e "${GREEN}    $1${RESET}"; }
warn()   { echo -e "${YELLOW}    WARNING: $1${RESET}"; }
err()    { echo -e "${RED}    ERROR: $1${RESET}" >&2; }

usage() {
cat <<'MANEOF'
NAME
    build-orangepi3-lts-stage4.sh - Build a hardened Gentoo aarch64 HEADLESS
    APPLIANCE image for the Orange Pi 3 LTS (Allwinner H6), with LIVE +
    INSTALLER flavors, joined to the HugMesh Tailscale mesh.
    EXPERIMENTAL — hardware validation pending (see specs-orangepi3-lts/README.md).

SYNOPSIS
    build-orangepi3-lts-stage4.sh [OPTIONS]

DESCRIPTION
    Cross-compiles a lean, hardened, HEADLESS Gentoo appliance (SSH-only — NO
    X11/desktop package, NO GPU/DRM kernel config; see the header for WHY:
    unlike the H616 siblings this is a SCOPE decision, not a driver gap) for
    the Orange Pi 3 LTS, reusing the aarch64 cross path and the SHARED mesh + KEYS-USB
    provisioning engine. The image joins headscale/tailscale and honors the
    hardened, key-only SSH posture exactly like the Frite/Pi5/Orange-Pi-5/x86
    client images. This platform has ONE role (a headless appliance) — there is
    no --role axis with cluster-node choices, and no --board axis (one board).

OPTIONS
  Board (overrides — this is ONE board, not a table; see the header)
    -c, --cpu CPU        GCC -mcpu/-mtune (default cortex-a53).
    -d, --defconfig N    Kernel base defconfig (default: defconfig, mainline arm64).
    --dtb PATH           Override the in-tree DTB (default
                         allwinner/sun50i-h6-orangepi-3.dtb).
    --uboot-defconfig N  U-Boot defconfig (default orangepi_3_defconfig).
    --uboot-url URL      Prebuilt board u-boot.bin to vendor into the image
                         (OPTIONAL here — unlike every other arm64 platform in
                         this repo, this board's mainline U-Boot needs NO
                         proprietary blob; see the header).
    --skip-uboot         Do not fetch/stage u-boot (you provide it separately).

  Flavor (the LIVE / INSTALLER toggle)
    --flavor F          live | installer | both (DEFAULT both).
                        live      = boots ephemerally off microSD/USB.
                        installer = live image + install-orangepi3-lts.sh to
                                    write the appliance to microSD/USB (the
                                    SAME medium it booted from, or a second
                                    one — this board has no eMMC/NVMe).
    --live              shorthand for --flavor live.
    --installer         shorthand for --flavor installer.

  Branding / env / system  (same knobs as the other builders)
    --brand / --brand-title / --org / --cluster-domain / --env test|prod
    -H hostname / -T timezone / -u user
    (--user-password / --root-password are DEPRECATED no-ops: no password is
     baked in; keyless boot mints a random one-time password + locks root)
    -C, --config FILE   drop-in brand.conf profile (sourced; CLI overrides it).

  Image
    --img-size MiB      ext4 root size baked into the installer's stage4 (default 2048).
    --grow fill|none|<size>   first-boot grow policy (default fill).
    --compress          xz -9 the finished image(s).
    -p PKGS             extra packages appended to the stage4.

  Mesh / radios  (same as the Frite/Pi5/Orange-Pi-5 builders)
    --headscale-version / --tailscale-version / --skip-mesh / --skip-tailscale
    --enable-wifi / --enable-bluetooth   (off by default; the ONBOARD radio has
                                          NO mainline driver at all regardless —
                                          see the header)

  Standalone (local user, no mesh, LUKS2 FDE on install)
    --standalone         No mesh; a local user logs in over SSH with a
                          build-time password instead of the KEYS-USB-
                          provisioned account. Auto-enables --encrypt-root and
                          forces the INSTALLER flavor on (--flavor live alone
                          has no install step).
    --local-user NAME    The standalone local login account (default: --user).
    --local-pass PASS    Plaintext; hashed at build (yescrypt, $6$ fallback), never
                          baked raw. Omit it and a random one-time password is
                          minted + printed once at first boot instead.
    --encrypt-root        install-orangepi3-lts.sh LUKS2-encrypts the target
                          root and prompts for a passphrase at install time
                          (ON-DEVICE format — see the header note); auto-on
                          for --standalone. Composable onto a plain (non
                          --standalone) build too.
    --luks-pass PASS      OPTIONAL unattended install-time passphrase — lands
                          on the installer image in plaintext (0600); prefer
                          the interactive install-time prompt.

  Phases
    --skip-kernel / --skip-clean / --resume
    --allow-missing-packages
                        Ship the image even if some requested packages failed to
                        merge: the completeness gate warns instead of failing.
                        Cannot bypass the kernel check (a kernel-less image
                        cannot boot; use --skip-kernel to deliberately build
                        without one). Read the missing-atom list first.

    --no-emerge-plan
                        Skip the read-only --pretend plan preview emitted
                        before the system and image emerges (the Studio's
                        up-front resolved-package list). Saves one extra
                        dependency resolution per planned section; the
                        build itself is identical with or without it.

  General
    -w, --work-dir DIR  products land here (default ./out).
    --distdir DIR       reuse a shared READ-ONLY distfiles cache (or SNAP_DISTDIR_SRC
                        env); arch-independent sources, safe fleet-wide. New fetches
                        still land in the private build tree. Empty = private only.
    --shared-assets DIR ONE fleet-wide asset root: stage3 seed cache
                        (<DIR>/seed/<arch>), distfiles (<DIR>/distfiles) and the
                        per-BOARD binpkg pool (<DIR>/pkgdir/<board-key>). Default
                        <work-dir>/shared; env HUGMESH_SHARED_ASSETS. The cached seed
                        is RE-VERIFIED (signed DIGESTS) on every reuse.
    --no-shared-assets  opt out — private seed/distfiles/pkgdir under the build tree.
    -j, --jobs N        parallel jobs (default nproc).
    --print-plan        resolve + validate all flags, print the build plan
                        (PLAN_KEY=VALUE lines) and exit 0 — no root, no writes,
                        no network. Invalid combinations exit non-zero.
    -h, --help

EXAMPLES
    # Default: headless appliance, BOTH live + installer
    ./build-orangepi3-lts-stage4.sh

    # Live image only, joins the tailnet mesh
    ./build-orangepi3-lts-stage4.sh --flavor live

    # Standalone hardened appliance: local user over SSH, LUKS2 FDE on install
    ./build-orangepi3-lts-stage4.sh --standalone --local-user alice

    # Brand it, vendor a prebuilt U-Boot (optional — no blob needed here)
    ./build-orangepi3-lts-stage4.sh --brand acme --cluster-domain acme.example \
        --uboot-url https://example/u-boot-orangepi3-lts.bin

NOTES
    EXPERIMENTAL — this platform has never booted on real hardware from this
    repo. See specs-orangepi3-lts/README.md for the full research-confidence
    breakdown (boot chain, Ethernet, WiFi, storage, and — most importantly —
    why this platform is HEADLESS-ONLY) before trusting any image this builder
    produces.

    HEADLESS-ONLY: a SCOPE decision on this board (the H6 display pipeline
    exists in mainline but is partial, and this image would boot it on the
    PLAIN OPi3's DTB — mainline has no -lts DTS; see the header + README).
    This image ships NO X11/desktop package and NO GPU/DRM kernel config —
    see specs-orangepi3-lts/README.md before "fixing" that.

    Storage: microSD, the onboard 8GB eMMC (a class the Zero 2 template
    lacks), or USB — no NVMe (the H6's quirky PCIe is unusable in mainline).
    U-Boot on this board needs NO proprietary blob (the family trait — see
    the header); --uboot-url is an OPTIONAL convenience,
    not a hard requirement the way it is on Frite/Orange-Pi-5.
MANEOF
exit 0
}

# ── Drop-in brand profile (sourced before CLI; CLI flags override it) ──
for ((_i = 1; _i <= $#; _i++)); do
    case "${!_i}" in -C|--config) _j=$((_i + 1)); CONFIG_FILE="${!_j}" ;; esac
done
if [ -z "${CONFIG_FILE}" ] && [ -f "$(pwd)/brand.conf" ]; then CONFIG_FILE="$(pwd)/brand.conf"; fi
if [ -n "${CONFIG_FILE}" ]; then
    [ -f "${CONFIG_FILE}" ] || { err "config file not found: ${CONFIG_FILE}"; exit 1; }
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
    echo "Loaded brand profile: ${CONFIG_FILE} (brand=${BRAND}, domain=${CLUSTER_DOMAIN})"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir)        WORK_DIR="$2";              shift 2 ;;
        --distdir)            DISTDIR_SRC="$2";           shift 2 ;;
        --shared-assets)      SHARED_ASSETS_DIR="$2";  shift 2 ;;
        --no-shared-assets)   SHARED_ASSETS_ENABLED=false;      shift   ;;
        --packages-only)      PACKAGES_ONLY=true;         shift ;;
        # Accept an image whose requested package set did not fully merge (the
        # completeness gate warns instead of failing; kernel tier stays fatal).
        --allow-missing-packages) ALLOW_MISSING_PACKAGES=true; shift ;;
        # Skip the read-only --pretend plan preview (see EMERGE_PLAN_ENABLED).
        --no-emerge-plan) EMERGE_PLAN_ENABLED=false; shift ;;
        --build-subdir)       BUILD_SUBDIR="$2";          shift 2 ;;
        -s|--specs-dir)       SPECS_DIR="$2";             shift 2 ;;
        -t|--target)          CROSS_TARGET="$2";          shift 2 ;;
        -j|--jobs)            JOBS="$2";                  shift 2 ;;
        -c|--cpu)             OPI3LTS_CPU="$2";              shift 2 ;;
        -d|--defconfig)       OPI3LTS_DEFCONFIG="$2";       shift 2 ;;
        --dtb)                OPI3LTS_DTB="$2";             shift 2 ;;
        --uboot-defconfig)    OPI3LTS_UBOOT_DEFCONFIG="$2"; shift 2 ;;
        --uboot-url)          OPI3LTS_UBOOT_URL="$2";       shift 2 ;;
        --skip-uboot)         SKIP_UBOOT=true;            shift   ;;
        --flavor)             OPI3LTS_FLAVOR="$2";          shift 2 ;;
        --live)               OPI3LTS_FLAVOR="live";        shift   ;;
        --installer)          OPI3LTS_FLAVOR="installer";   shift   ;;
        -v|--version)         REL_VERSION="$2";           shift 2 ;;
        --seed-url)           SEED_STAGE3_URL="$2";       shift 2 ;;
        -H|--hostname)        HOSTNAME="$2";              shift 2 ;;
        -r|--role)            ROLE="$2";                  shift 2 ;;
        -C|--config)          CONFIG_FILE="$2";           shift 2 ;;  # sourced above
        --env)                ENV="$2";                   shift 2 ;;
        --cluster-domain|--domain) CLUSTER_DOMAIN="$2";   shift 2 ;;
        --superdomain) SUPERDOMAIN="$2"; shift 2 ;;
        --brand)              BRAND="$2";                 shift 2 ;;
        --brand-title)        BRAND_TITLE="$2";           shift 2 ;;
        --org)                ORG="$2";                   shift 2 ;;
        -T|--timezone)        TIMEZONE="$2";              shift 2 ;;
        -u|--user)            DEFAULT_USER="$2";          shift 2 ;;
        --standalone)         STANDALONE=true;            shift   ;;
        --local-user)         LOCAL_USER="$2";             shift 2 ;;
        --local-pass|--local-user-password) LOCAL_USER_PASS="$2"; shift 2 ;;
        --encrypt-root)       ENCRYPT_ROOT=true;          shift   ;;
        --luks-pass|--root-unlock-pass) LUKS_PASS="$2";   shift 2 ;;
        # DEPRECATED no-ops: images no longer bake a fallback password (random
        # one-time password is minted at first boot; real creds come from KEYS).
        --user-password)      warn "--user-password is ignored: no password is baked into the image (random first-boot fallback + KEYS provisioning)"; shift 2 ;;
        --root-password)      warn "--root-password is ignored: root is locked on keyless boot; set root via the KEYS USB users.json hash"; shift 2 ;;
        -p|--extra-packages)  EXTRA_PACKAGES="$2";        shift 2 ;;
        # User package deltas (validated + mandatory-floor-checked below); -p stays
        # the frozen legacy extra-packages spelling, --packages-add is the new one.
        --packages-add)       PACKAGES_ADD="$2";          shift 2 ;;
        --packages-drop)      PACKAGES_DROP="$2";         shift 2 ;;
        --headscale-version)  HEADSCALE_VERSION="$2";     shift 2 ;;
        --tailscale-version)  TAILSCALE_VERSION="$2";     shift 2 ;;
        --enable-wifi)        ENABLE_WIFI=true;           shift   ;;
        --enable-bluetooth)   ENABLE_BLUETOOTH=true;      shift   ;;
        --permit-root-login)  PERMIT_ROOT_LOGIN="$2";     shift 2 ;;
        --skip-mesh)          SKIP_MESH=true;             shift   ;;
        --skip-tailscale)     SKIP_TAILSCALE=true;        shift   ;;
        --skip-kernel)        SKIP_KERNEL=true;           shift   ;;
        --image-only)         IMAGE_ONLY=true; SKIP_KERNEL=true; shift ;;
        --img-size)           ROOT_MiB="$2";              shift 2 ;;
        --grow)               GROW_POLICY="$2";           shift 2 ;;
        --no-grow)            GROW_POLICY="none";         shift   ;;
        --compress)           COMPRESS_IMG=true;          shift   ;;
        --skip-clean)         SKIP_CLEAN=true;            shift   ;;
        --resume)             RESUME=true;                shift   ;;
        --print-plan)         PRINT_PLAN=true;            shift   ;;
        -h|--help)            usage                               ;;
        --)                   shift; break                        ;;
        -*) err "Unknown option: $1"; echo "    Run with --help for usage." >&2; exit 1 ;;
        *)  err "Unexpected argument: $1"; echo "    Run with --help for usage." >&2; exit 1 ;;
    esac
done

# Default work directory: ./out under CWD (local + gitignored)
[ -z "${WORK_DIR}" ] && WORK_DIR="$(pwd)/out"

# ── Validate flavor / env / grow ───────────────────────────────────
case "${OPI3LTS_FLAVOR}" in
    live|installer|both) ;;
    *) err "--flavor must be: live | installer | both (got '${OPI3LTS_FLAVOR}')"; exit 1 ;;
esac
case "${ENV}" in
    test|prod) ;;
    *) err "--env must be one of: test | prod (got '${ENV}')"; exit 1 ;;
esac
GROW_POLICY="$(printf '%s' "${GROW_POLICY}" | tr '[:upper:]' '[:lower:]')"
case "${GROW_POLICY}" in
    fill|none|off|no|false|0) ;;
    *[0-9]g|*[0-9]m|*[0-9]k|*[0-9]t|*[0-9]gib|*[0-9]mib|*[0-9]kib|*[0-9]%|*[0-9]) ;;
    *) err "--grow must be: fill | none | <size> (e.g. 16G, 12000M, 50%)  (got '${GROW_POLICY}')"; exit 1 ;;
esac

BUILD_LIVE=false; BUILD_INSTALLER=false
case "${OPI3LTS_FLAVOR}" in
    live)      BUILD_LIVE=true ;;
    installer) BUILD_INSTALLER=true ;;
    both)      BUILD_LIVE=true; BUILD_INSTALLER=true ;;
esac

if [ -z "${HOSTNAME}" ]; then
    case "${ROLE}" in
        appliance|generic) HOSTNAME="${BRAND}-orangepi3-lts" ;;
        *)                 HOSTNAME="${BRAND}-${ROLE}" ;;
    esac
fi

# ── STANDALONE posture (composable — this image already never bakes a k8s/
# cluster tree, so --standalone only needs to turn mesh off, set up a local
# user, and force disk encryption + the installer flavor — mirrors
# build-frite-stage4.sh / build-orangepi5-stage4.sh's STANDALONE posture block
# exactly) ───────────────────────────────────────────────────────────────────
if ${STANDALONE}; then
    SKIP_MESH=true
    SKIP_TAILSCALE=true
    [ -z "${LOCAL_USER}" ] && LOCAL_USER="${DEFAULT_USER}"
    ENCRYPT_ROOT=true           # the INSTALLED system is LUKS2 full-disk encrypted
    BUILD_INSTALLER=true        # guarantee the installer artifact (the FDE path)
    info "STANDALONE appliance: no mesh; local user '${LOCAL_USER}' over SSH; LUKS2 FDE on install"
fi
# --encrypt-root composed onto a plain (non-standalone) build also needs the
# installer flavor — LUKS is laid down by install-orangepi3-lts.sh, not the
# live medium.
${ENCRYPT_ROOT} && BUILD_INSTALLER=true

# ── Standalone local-user password → build-time hash (never baked in plaintext,
# mirrors build-x86-host-stage4.sh / build-frite-stage4.sh / build-orangepi5-stage4.sh) ──
LOCAL_PASSHASH=""
if ${STANDALONE} || [ -n "${LOCAL_USER}" ] || [ -n "${LOCAL_USER_PASS}" ]; then
    [ -n "${LOCAL_USER}" ] && DEFAULT_USER="${LOCAL_USER}"
    if [ -n "${LOCAL_USER_PASS}" ]; then
        command -v openssl >/dev/null 2>&1 || { err "--local-pass needs openssl on the build host (app-crypt/... / dev-libs/openssl)"; exit 1; }
        # ph_crypt_hash (scripts/_passhash-lib.sh): yescrypt ($y$) when the build
        # host's libcrypt round-trips it, else SHA-512 crypt ($6$). This hash is
        # what a stolen-device attacker cracks offline — docs/CRYPTO-AUDIT.md row 12.
        LOCAL_PASSHASH="$(ph_crypt_hash "${LOCAL_USER_PASS}")"
        LOCAL_USER_PASS=""   # scrub the plaintext from the environment immediately
        case "${LOCAL_PASSHASH}" in
            '$y$'*) info "Standalone local user '${DEFAULT_USER}': password hashed at build time (yescrypt; plaintext not baked)." ;;
            *)      info "Standalone local user '${DEFAULT_USER}': password hashed at build time (SHA-512 crypt fallback — build-host libcrypt lacks yescrypt; plaintext not baked)." ;;
        esac
    else
        ${STANDALONE} && warn "Standalone build with no --local-pass: a RANDOM one-time password is minted at first boot (printed once to console)."
    fi
fi

# ── Charset allowlists for brand/identity/kernel/toolchain fields (fail-closed) ──
# (mirrors build-frite-stage4.sh / build-rpi5-stage4.sh / build-orangepi5-stage4.sh)
# These values come from CLI flags or a sourced brand.conf and flow into
# render_template's sed program (build of make.conf, 01-firstboot.start,
# extlinux.conf) and into rebrand_sysroot's `sed -i` over the baked
# /etc/hugmesh tree — and OPI3LTS_CPU/CROSS_TARGET land in make.conf, which
# portage SOURCES as shell on the (root) build host. The rendered first-boot
# script runs useradd/chpasswd with DEFAULT_USER as ROOT on the device. Reject
# anything outside a strict charset at this earliest boundary so a value
# carrying sed/shell metacharacters, a quote, or a newline can never reach a
# render sink or a sourced KEY=VALUE file. Escaping at the render sink
# (_sed_rep_escape) is defense-in-depth on top of this. Each regex below
# ACCEPTS every legitimate default (brand=hugmesh, org=hugmesh-net,
# domain=hugmesh.systems, user=orangepi3lts, cpu=cortex-a53,
# target=aarch64-unknown-linux-gnu, title "HugMesh Systems"); HOSTNAME is
# derived from the validated brand above.
_require_match() {  # <human-name> <value> <regex>
    [[ "$2" =~ $3 ]] || { err "invalid $1: '$2' (must match ${3})"; exit 1; }
}
# DNS label (slug): lowercase alnum, internal hyphens, 1..63 chars.
_RE_SLUG='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
# Org slug: like a slug but allow upper-case (e.g. HugMesh-Systems).
_RE_ORG='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
# DNS name: dot-joined labels (case-insensitive), no trailing dot.
_RE_DNS='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
# POSIX-ish username: leading [a-z_], then [a-z0-9_-], <=32 chars.
_RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
# Brand title: printable, allow space + a small safe punctuation set; NO quote,
# backslash, dollar, backtick, pipe, ampersand, semicolon, angle/paren/newline.
_RE_TITLE='^[A-Za-z0-9 ._-]{1,64}$'
# GCC -mcpu/-mtune value: alnum + . _ + - (e.g. cortex-a53, native).
_RE_CPU='^[A-Za-z0-9._+-]+$'
# GNU target triplet: alnum + _ . - (e.g. aarch64-unknown-linux-gnu).
_RE_TRIPLET='^[A-Za-z0-9_.-]+$'

_require_match "--brand"          "${BRAND}"          "${_RE_SLUG}"
_require_match "--org"            "${ORG}"            "${_RE_ORG}"
_require_match "--cluster-domain" "${CLUSTER_DOMAIN}" "${_RE_DNS}"
[ -n "${SUPERDOMAIN}" ] && _require_match "--superdomain" "${SUPERDOMAIN}" "${_RE_DNS}"
_require_match "--hostname"       "${HOSTNAME}"       "${_RE_DNS}"
_require_match "--user"           "${DEFAULT_USER}"   "${_RE_USER}"
_require_match "--brand-title"    "${BRAND_TITLE}"    "${_RE_TITLE}"
_require_match "--cpu"            "${OPI3LTS_CPU}"       "${_RE_CPU}"
_require_match "--target"         "${CROSS_TARGET}"   "${_RE_TRIPLET}"
# ROLE is a hostname/marker only (see its declaration above — this platform is
# ONE role, not a desktop and not a k8s cluster node with a --role axis), and
# usage() documents no -r/--role option at all, but the parser entry still
# exists and feeds ART_PREFIX/STAGE4_TARBALL/LIVE_PATH/INSTALLER_PATH
# unescaped, unlike every other identity input above — allow-list it the same
# way, fail-closed like the rest of this block.
_require_match "--role"           "${ROLE}"           "${_RE_SLUG}"

BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"

# ── Shared build assets (one root for seed + distfiles + binpkg pool) ─────
# The three genuinely shareable assets move OUT of the per-entry build tree; the
# tree itself (sysroot/staging/log under BUILD_ROOT) stays isolated exactly as before,
# which is the invariant the Studio's wl-<entry-id> subdir encodes.
#   seed      <root>/seed/<arch>/        re-verified on EVERY reuse (never trusted)
#   distfiles <root>/distfiles/          arch-independent sources, safe fleet-wide
#   pkgdir    <root>/pkgdir/<board-key>  per-BOARD — the SIGILL-safe pool key
# The pool key is the BOARD's default subdir, NOT ${BUILD_SUBDIR}: the Studio passes
# --build-subdir wl-<entry-id> per worklist entry, so keying the pool on the subdir is
# precisely what made every GUI build start from an EMPTY pool and recompile the world.
# Widening reuse is safe only because every pool access still goes through the #439
# fingerprint guard (sa_pool_guard): a board whose ABI fingerprint differs is REFUSED.
BOARD_POOL_KEY="snap-build-orangepi3-lts"
SHARED_ROOT="$(sa_root "${WORK_DIR}" "${SHARED_ASSETS_DIR}")"
if [ -n "${SHARED_ROOT}" ]; then
    POOL_DIR="$(sa_pool_dir "${SHARED_ROOT}" "${BOARD_POOL_KEY}")" \
        || { echo "ERROR: cannot resolve a shared binpkg pool for '${BOARD_POOL_KEY}'" >&2; exit 1; }
    SHARED_DISTDIR="$(sa_distfiles_dir "${SHARED_ROOT}")"
    SHARED_SEED_DIR="$(sa_seed_dir "${SHARED_ROOT}" "arm64")" \
        || { echo "ERROR: cannot resolve the shared stage3 seed dir" >&2; exit 1; }
else
    POOL_DIR="${BUILD_ROOT}/pkgdir"   # legacy private pool (--no-shared-assets)
    SHARED_DISTDIR=""
    SHARED_SEED_DIR="${BUILD_ROOT}"
fi
SYSROOT="${BUILD_ROOT}/sysroot"
STAGE_DIR="${BUILD_ROOT}/staging"     # boot tree + ISO/installer staging
LOG_FILE="${WORK_DIR}/build.log"
# Per-image log (fix D, session 20260716-160638-f8c153): the session-shared
# build.log above is tee -a APPENDED by every builder of a multi-image
# worklist, and a builder that dies before its redirect leaves nothing at all
# — 8 of that session's 9 images left no usable on-disk log. Each run ALSO
# tees to its own per-image file, derived from the EXISTING --build-subdir
# argv (Studio worklist runs pass wl-<entry-id> -> /out/build-<entry-id>.log;
# standalone CLI runs get build-snap-build-<board>.log). No new flags, no
# argv change; uniqueness is the worklist's own entry-id collision invariant.
IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log"
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Image / artifact name prefix.
ART_PREFIX="${BRAND}-orangepi3-lts-arm64-${ROLE}-${ENV}-${BUILD_TS}"

if [ "${ENV}" = "prod" ]; then
    echo -e "${RED}${BOLD}"
    echo "############################################################################"
    echo "##   BUILDING PROD Orange Pi 3 LTS image for ${CLUSTER_DOMAIN}"
    echo "##   - bakes the REAL public domain; mesh/Casdoor creds from the keys USB ##"
    echo "############################################################################"
    echo -e "${RESET}"
else
    info "Build ENV: test (LAN-first; mesh + Casdoor login provisioned from the KEYS USB)"
fi
echo -e "${YELLOW}${BOLD}    EXPERIMENTAL PLATFORM: this board has never been booted with an image"
echo -e "    from this repo. See specs-orangepi3-lts/README.md before trusting this build.${RESET}"
info "Board: Orange Pi 3 LTS (Allwinner H6, quad Cortex-A53) — HEADLESS APPLIANCE"
info "DTB:   ${OPI3LTS_DTB}   u-boot: ${OPI3LTS_UBOOT_DEFCONFIG}"
info "Flavor: ${OPI3LTS_FLAVOR}  (live=${BUILD_LIVE} installer=${BUILD_INSTALLER})"
info "Build stamp: ${BUILD_TS} (brand=${BRAND})"

# Escape a value so it is safe to place on the REPLACEMENT (right-hand) side of a
# sed `s|LHS|RHS|` command that uses `|` as the delimiter. Without this a value
# containing the delimiter `|`, the match-reference metachar `&`, a backslash, or a
# newline can terminate the s-command, append an extra sed command, or inject a new
# line into the rendered artifact (make.conf/extlinux.conf/01-firstboot.start, which
# are sourced/executed as root). Order matters: escape backslash FIRST, then `&`
# and the `|` delimiter, then forbid embedded newlines (defense-in-depth at the sink
# — the identity/brand vars are also allowlist-validated up front).
_sed_rep_escape() {
    local v="$1"
    v="${v//\\/\\\\}"   # backslash -> \\
    v="${v//&/\\&}"     # & (whole-match ref) -> \&
    v="${v//|/\\|}"     # | (delimiter)       -> \|
    case "${v}" in
        *$'\n'*) err "sed replacement contains a newline (refusing to render): '${1}'"; exit 1 ;;
    esac
    printf '%s' "${v}"
}

# ── Template helper (mirrors the Frite/Pi5/Orange-Pi-5 render_template) ────
# All brand/domain/identity/kernel substitutions go through _sed_rep_escape so a
# value carrying sed metacharacters cannot corrupt or inject into the s-program.
render_template() {
    local src="$1" dst="$2"
    local cbuild
    cbuild="$(portageq envvar CHOST 2>/dev/null || gcc -dumpmachine)"
    sed \
        -e "s|@@CBUILD@@|$(_sed_rep_escape "${cbuild}")|g" \
        -e "s|@@CROSS_TARGET@@|$(_sed_rep_escape "${CROSS_TARGET}")|g" \
        -e "s|@@OPI3LTS_CPU@@|$(_sed_rep_escape "${OPI3LTS_CPU}")|g" \
        -e "s|@@JOBS@@|$(_sed_rep_escape "${JOBS}")|g" \
        -e "s|@@WORK_DIR@@|$(_sed_rep_escape "${BUILD_ROOT}")|g" \
        -e "s|@@OPI3LTS_KERNEL_IMG@@|$(_sed_rep_escape "${OPI3LTS_KERNEL_IMG}")|g" \
        -e "s|@@OPI3LTS_DTB@@|$(_sed_rep_escape "${OPI3LTS_DTB}")|g" \
        -e "s|@@OPI3LTS_INITRD_LINE@@|$(_sed_rep_escape "${OPI3LTS_INITRD_LINE:-#}")|g" \
        -e "s|@@OPI3LTS_APPEND@@|$(_sed_rep_escape "${OPI3LTS_APPEND:-}")|g" \
        -e "s|@@HOSTNAME@@|$(_sed_rep_escape "${HOSTNAME}")|g" \
        -e "s|@@TIMEZONE@@|$(_sed_rep_escape "${TIMEZONE}")|g" \
        -e "s|@@DEFAULT_USER@@|$(_sed_rep_escape "${DEFAULT_USER}")|g" \
        -e "s|@@STANDALONE@@|$(_sed_rep_escape "${STANDALONE}")|g" \
        -e "s|@@LOCAL_PASSHASH@@|$(_sed_rep_escape "${LOCAL_PASSHASH}")|g" \
        -e "s|@@BRAND@@|$(_sed_rep_escape "${BRAND}")|g" \
        -e "s|@@BRAND_TITLE@@|$(_sed_rep_escape "${BRAND_TITLE}")|g" \
        -e "s|@@DOMAIN@@|$(_sed_rep_escape "${CLUSTER_DOMAIN}")|g" \
        -e "s|@@ORG@@|$(_sed_rep_escape "${ORG}")|g" \
        -e "s|@@ENV@@|$(_sed_rep_escape "${ENV}")|g" \
        "${src}" > "${dst}"
}

# ── harden_radios (same posture as every other platform) ───────────────────
# WiFi + Bluetooth OFF by default. UNLIKE Orange Pi 5 (a real, if rough,
# mainline driver for its onboard radio), this board's onboard Unisoc
# UWE5622 combo chip has NO mainline driver AT ALL (see the header) — no
# onboard-radio kernel module is even built (kernel/hardened-appliance.config),
# so this blacklist is pure defense-in-depth for a USB WiFi/Bluetooth dongle
# that happens to use an already-mainlined driver.
harden_radios() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/modprobe.d" "${sysroot}/etc/local.d" \
             "${sysroot}/etc/NetworkManager/conf.d"
    local bl="${sysroot}/etc/modprobe.d/hugmesh-radio-blacklist.conf"; : > "${bl}"
    local act="${sysroot}/etc/local.d/02-radio-hardening.start"
    {
        echo "#!/bin/sh"
        echo "# Radio hardening (build-orangepi3-lts-stage4.sh). WiFi/Bluetooth OFF by default."
        echo "command -v rfkill >/dev/null 2>&1 || exit 0"
    } > "${act}"
    if [ "${ENABLE_WIFI}" != "true" ]; then
        { echo "blacklist cfg80211"; echo "blacklist mac80211"; } >> "${bl}"
        { echo "rfkill block wifi 2>/dev/null || true"
          echo "command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off 2>/dev/null || true"; } >> "${act}"
        printf '[main]\n# WiFi off by default; managed=ethernet only.\n' \
            > "${sysroot}/etc/NetworkManager/conf.d/10-no-wifi.conf"
        info "WiFi DISABLED by default (hardened posture; the onboard radio has NO mainline driver regardless — see the header). Re-enable: --enable-wifi (only matters for a USB dongle)."
    fi
    if [ "${ENABLE_BLUETOOTH}" != "true" ]; then
        { echo "blacklist bluetooth"; echo "blacklist btusb"; } >> "${bl}"
        echo "rfkill block bluetooth 2>/dev/null || true" >> "${act}"
    fi
    echo "rm -f /etc/local.d/02-radio-hardening.start" >> "${act}"
    chmod +x "${act}"
    [ -s "${bl}" ] || echo "# (no radios blacklisted)" > "${bl}"
}

write_growfs_conf() {
    local dest="$1"; mkdir -p "$(dirname "${dest}")"
    cat > "${dest}" <<GROWFS_EOF
# growfs.conf — first-boot root-grow policy (read by the growroot service).
#   GROW=fill | none | <size>  (e.g. 16G, 12000M, 50%)
GROW=${GROW_POLICY}
GROWFS_EOF
}

# Configure a small zram swap at first boot — this is a small-RAM appliance
# board (a single 2GB LPDDR3 SKU per the vendor sheet), so a capped zram swap
# is cheap headroom. Mirrors La Frite's 512MB SKU handling / the Zero 2
# template's multi-SKU rationale, degraded to the single-SKU case.
write_zram_firstboot() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/local.d"
    cat > "${sysroot}/etc/local.d/03-zram-swap.start" <<'ZRAM_EOF'
#!/bin/sh
# zram swap — sized to half of RAM, capped at 512M. Cheap headroom on this
# single-2GB-SKU appliance board. Idempotent; best-effort (no zram = skip).
[ -e /sys/class/zram-control ] || modprobe zram 2>/dev/null || exit 0
grep -q '/dev/zram0' /proc/swaps 2>/dev/null && exit 0
mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
half=$(( mem_kb / 2 )); cap=$(( 512 * 1024 ))
[ "${half}" -gt "${cap}" ] && half="${cap}"
[ "${half}" -gt 0 ] || exit 0
echo "${half}K" > /sys/block/zram0/disksize 2>/dev/null || exit 0
mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null || true
ZRAM_EOF
    chmod +x "${sysroot}/etc/local.d/03-zram-swap.start"
}

# ── rebrand_sysroot (lightweight: this image has no cluster GitOps tree) ──
rebrand_sysroot() {
    [ "${BRAND}" = "hugmesh" ] && [ "${CLUSTER_DOMAIN}" = "hugmesh.systems" ] && return 0
    banner "Rebranding baked config -> brand=${BRAND} domain=${CLUSTER_DOMAIN} org=${ORG}"
    local org_lc; org_lc="$(echo "${ORG}" | tr '[:upper:]' '[:lower:]')"
    # All of these land on the REPLACEMENT side of `sed s|..|VALUE|` across the baked
    # /etc/hugmesh tree (config the device reads as root); escape sed metacharacters
    # so a tainted brand/domain/org/title cannot inject a second sed command or corrupt
    # the output. Up-front allowlists already forbid the worst chars; this is the
    # sink-side second layer (matches build-x86-host-stage4.sh's rebrand_sysroot).
    local _btitle _org _domain _brand _hproj
    _btitle="$(_sed_rep_escape "${BRAND_TITLE}")"
    _org="$(_sed_rep_escape "${ORG}")"
    _domain="$(_sed_rep_escape "${CLUSTER_DOMAIN}")"
    _brand="$(_sed_rep_escape "${BRAND}")"
    # Harbor image-project segment (registry.<host>/<project>/<svc>). Defaults to the
    # brand; the HARBOR_PROJECT env is a first-class seam for a differently-named project.
    _hproj="$(_sed_rep_escape "${HARBOR_PROJECT:-${BRAND}}")"
    local f
    while IFS= read -r -d '' f; do
        # FROZEN k8s label-KEY / API-group namespace `snapdragon.systems/<suffix>` must NOT
        # rebrand (it is compiled into operators/JVM and used as node/pod selectors). Every
        # KEY form is preceded by a YAML-structural boundary (line-start, space, {, (, comma,
        # quote, backtick); every HOST/URL form is preceded by a dot or slash. Protect the KEY
        # namespace behind a sentinel (first two -e), rebrand hosts/URLs/emails/CORS in the
        # middle, then restore the KEY namespace verbatim (last -e). The sentinel contains
        # neither `hugmesh.systems` nor `hugmesh-`, so the middle rules skip it.
        sed -i \
            -e "s|^hugmesh\.systems/|@@SDSYSKEY@@/|g" \
            -e "s|\([ {(,\"'\`]\)hugmesh\.systems/|\1@@SDSYSKEY@@/|g" \
            -e "s|HugMesh Systems|${_btitle}|g" \
            -e "s|hugmesh-net|${_org}|g" \
            -e "s|hugmesh\.systems|${_domain}|g" \
            -e "s|\(registry\.[A-Za-z0-9.-]*\)/hugmesh/|\1/${_hproj}/|g" \
            -e "s|hugmesh-|${_brand}-|g" \
            -e "s|@@SDSYSKEY@@/|hugmesh.systems/|g" \
            "${f}"
    done < <(find "${SYSROOT}/etc/hugmesh" -type f -print0 2>/dev/null)
}

# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation ──────────
# Runs AFTER full arg parsing / flavor+env validation / allowlist checks /
# artifact resolution, but BEFORE the prereq probes, mkdir, tee-redirect, network
# fetches or any sysroot write. No root required. One stable KEY=VALUE per line
# (grep '^PLAN_'); exit 0. Invalid flag combos never reach this point — the
# validation above already exited non-zero, which is exactly what the
# tests/build-matrix harness relies on. NO secrets are echoed here.

# ── user package deltas: validate + enforce the tier-1 mandatory floor ─────────
# Before --print-plan and any mutation, so a malformed atom or an illegal drop
# fails LOUDLY at the boundary. Atom charset mirrors core/validate.py exactly.
_PKG_ATOM_RE='^[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+._-]+$'
_validate_pkg_atoms() { # LABEL VALUE
    local _lbl="$1" _a; local -a _arr
    read -ra _arr <<< "$2"
    for _a in "${_arr[@]}"; do
        [[ "${_a}" =~ ${_PKG_ATOM_RE} ]] || { err "invalid ${_lbl} atom: '${_a}' — want a category/name atom (e.g. app-editors/vim)"; exit 1; }
    done
}
_validate_pkg_atoms --packages-add  "${PACKAGES_ADD}"
_validate_pkg_atoms --packages-drop "${PACKAGES_DROP}"
# Tier-1 mandatory atoms (the payload essentials this appliance builder always
# ships). Dropping one is rejected (Decision #5: tier-2 defaults are droppable;
# tier-1 essentials are hard-locked).
SNAP_MANDATORY_ATOMS="sys-block/parted app-misc/jq net-misc/networkmanager"
if [ -n "${PACKAGES_DROP}" ]; then
    read -ra _drop_check <<< "${PACKAGES_DROP}"
    for _d in "${_drop_check[@]}"; do
        for _m in ${SNAP_MANDATORY_ATOMS}; do
            [ "${_d}" = "${_m}" ] && { err "refusing to --packages-drop mandatory-payload atom '${_d}' — tier-1 essential"; exit 1; }
        done
    done
fi

if ${PRINT_PLAN}; then
    _plan() { printf 'PLAN_%s=%s\n' "$1" "$2"; }
    _plan BUILDER            "build-orangepi3-lts-stage4.sh"
    _plan PLATFORM           "orangepi3-lts"
    _plan ARCH               "arm64"
    _plan ROLE               "${ROLE}"
    _plan ENV                "${ENV}"
    _plan DTB                "${OPI3LTS_DTB}"
    _plan UBOOT_DEFCONFIG    "${OPI3LTS_UBOOT_DEFCONFIG}"
    # Effective flavor derived from the post-cascade BUILD_LIVE/BUILD_INSTALLER
    # booleans, NOT the raw --flavor enum: --standalone/--encrypt-root force
    # BUILD_INSTALLER=true regardless of what --flavor was passed, so echoing the
    # raw OPI3LTS_FLAVOR here would misreport (e.g. --flavor live --encrypt-root
    # actually builds live+installer, not live-only).
    if ${BUILD_LIVE} && ${BUILD_INSTALLER}; then _EFF_FLAVOR="both"
    elif ${BUILD_INSTALLER}; then _EFF_FLAVOR="installer"
    else _EFF_FLAVOR="live"
    fi
    _plan FLAVOR             "${_EFF_FLAVOR}"
    # NO GPU/display driver at all, ever — this is the ONE platform in the repo
    # where this key is explicitly "none" rather than a real driver name (see
    # the header's HDMI/mainline-driver research).
    _plan GPU_DRIVER         "none"
    _ARTS="stage4.tar.xz"
    ${BUILD_LIVE}      && _ARTS="${_ARTS},live.iso"
    ${BUILD_INSTALLER} && _ARTS="${_ARTS},installer.iso"
    _plan ARTIFACTS          "${_ARTS}"
    _plan ARTIFACT_PREFIX    "${BRAND}-orangepi3-lts-arm64-${ROLE}-${ENV}-<timestamp>"
    _plan WORK_DIR           "${WORK_DIR}"
    # Per-board binpkg pool + prebuild mode (shared-binpkg). Additive PLAN_ keys.
    _plan PKGDIR             "${POOL_DIR}"
    # Shared build assets: the root, the per-arch seed cache, the fleet distfiles and
    # the per-BOARD pool key — so EVERY channel's plan states exactly what is reused
    # (the Studio's command preview included). Additive PLAN_ keys.
    _plan SHARED_ASSETS      "${SHARED_ROOT:-off}"
    _plan SHARED_SEED_DIR    "${SHARED_SEED_DIR}"
    _plan SHARED_DISTDIR     "${SHARED_DISTDIR:-none}"
    _plan POOL_KEY           "${BOARD_POOL_KEY}"
    _plan PACKAGES_ONLY      "$(${PACKAGES_ONLY} && echo 1 || echo 0)"
    _plan JOBS               "${JOBS}"
    _plan BRAND              "${BRAND}"
    _plan CLUSTER_DOMAIN     "${CLUSTER_DOMAIN}"
    _plan SUPERDOMAIN        "${SUPERDOMAIN}"
    _plan HOSTNAME           "${HOSTNAME}"
    _plan OPTIONAL_SERVICES  "none"   # lean headless appliance: no baked cluster tree
    _plan MESH               "$(${SKIP_MESH} && echo skip || echo "headscale=${HEADSCALE_VERSION},tailscale=$(${SKIP_TAILSCALE} && echo skip || echo "${TAILSCALE_VERSION}")")"
    _plan STANDALONE         "${STANDALONE}"
    _plan ENCRYPT_ROOT       "${ENCRYPT_ROOT}"
    _plan LUKS_PASS          "$([ -n "${LUKS_PASS}" ] && echo REDACTED || echo none)"
    _plan LOCAL_USER         "${LOCAL_USER:-$DEFAULT_USER}"
    _plan LOCAL_PASS         "$([ -n "${LOCAL_PASSHASH}" ] && echo REDACTED || echo none)"
    _plan KERNEL             "mainline-arm64 (defconfig=${OPI3LTS_DEFCONFIG} + hardened-appliance.config)"
    _plan FLAGS_EFFECTIVE    "env=${ENV} flavor=${_EFF_FLAVOR} img_size=${ROOT_MiB} grow=${GROW_POLICY} compress=${COMPRESS_IMG} resume=${RESUME} skip_kernel=${SKIP_KERNEL} skip_uboot=${SKIP_UBOOT} skip_mesh=${SKIP_MESH} skip_tailscale=${SKIP_TAILSCALE} permit_root_login=${PERMIT_ROOT_LOGIN} enable_wifi=${ENABLE_WIFI} enable_bluetooth=${ENABLE_BLUETOOTH} standalone=${STANDALONE} encrypt_root=${ENCRYPT_ROOT}"
    exit 0
fi

# ── Stage4 package-set resolver (single source of truth) ──────────────────────
# Factored VERBATIM from the former inline Phase-2 assembly so the
# prerequisites-time qemu preflight and Phase 2 resolve the IDENTICAL package
# set — ONE assembly, no drift. Atoms are printed one per line on stdout;
# the informational lines go to stderr (suppressed with arg "quiet", which
# the preflight uses). All inputs (role/flavor flags, EXTRA_PACKAGES,
# PACKAGES_ADD/PACKAGES_DROP — validated up front) are resolved before the
# "Verifying prerequisites" banner, so this is callable at t=0.
resolve_stage4_packages() {
    local _rsp_quiet="${1:-}"
    _rsp_info() { [ "${_rsp_quiet}" = "quiet" ] || info "$1" >&2; }
    local STAGE4_PACKAGES _extras _padd _pdrop _kept _p _d _skip _pkg
    STAGE4_PACKAGES=()
    mapfile -t STAGE4_PACKAGES < <(grep -v '^\s*#' "${SPECS_DIR}/portage/packages.list" | grep -v '^\s*$')
    # NO desktop package list, EVER — unlike every other platform in this repo
    # (which either always has a desktop set, or gates one behind --desktop), this
    # board has no packages-desktop.list / packages-light-desktop.list at all. The
    # base packages.list above IS the whole appliance. See the builder header.
    # LIVE *and* INSTALLER flavors: pull in sys-kernel/dracut so the builder can
    # generate a dmsquash-live initramfs (the bare kernel cannot mount
    # root=live:/rd.live.* — that is a dracut job). The INSTALLER medium is itself a
    # LIVE boot (it must come up so the operator can run install-orangepi3-lts.sh
    # — see that script's own header), so it needs the same initramfs. dracut stays
    # out of the always-installed base set and is added here for both bootable
    # flavors.
    if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
        _rsp_info "Bootable flavor selected — appending packages-live.list (dracut for the live initramfs)"
        mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
            grep -v '^\s*#' "${SPECS_DIR}/portage/packages-live.list" | grep -v '^\s*$')
    fi
    if ${ENCRYPT_ROOT}; then
        # --encrypt-root: cryptsetup is what install-orangepi3-lts.sh runs
        # (luksFormat/open/close) on the TARGET hardware at install time — needed
        # in the installed stage4 payload itself, not just the build host. dracut
        # (for the disk-boot initramfs that unlocks the LUKS root) is already
        # pulled in above via packages-live.list whenever BUILD_INSTALLER is true,
        # which --encrypt-root forces on below.
        _rsp_info "--encrypt-root selected — appending sys-fs/cryptsetup"
        STAGE4_PACKAGES+=("sys-fs/cryptsetup")
    fi
    if [ -n "${EXTRA_PACKAGES}" ]; then
        read -ra _extras <<< "${EXTRA_PACKAGES}"
        STAGE4_PACKAGES+=("${_extras[@]}")
        _rsp_info "Extra packages: ${EXTRA_PACKAGES}"
    fi
    # User package deltas (--packages-add / --packages-drop): adds appended, drops
    # filtered from the resolved set (validated + mandatory-floor-checked up front).
    if [ -n "${PACKAGES_ADD}" ]; then
        read -ra _padd <<< "${PACKAGES_ADD}"
        STAGE4_PACKAGES+=("${_padd[@]}")
        _rsp_info "Added packages (--packages-add): ${PACKAGES_ADD}"
    fi
    if [ -n "${PACKAGES_DROP}" ]; then
        read -ra _pdrop <<< "${PACKAGES_DROP}"
        _kept=()
        for _p in "${STAGE4_PACKAGES[@]}"; do
            _skip=false
            for _d in "${_pdrop[@]}"; do [ "${_p}" = "${_d}" ] && { _skip=true; break; }; done
            ${_skip} || _kept+=("${_p}")
        done
        STAGE4_PACKAGES=("${_kept[@]}")
        _rsp_info "Dropped packages (--packages-drop): ${PACKAGES_DROP}"
    fi
    [ "${#STAGE4_PACKAGES[@]}" -eq 0 ] || printf '%s\n' "${STAGE4_PACKAGES[@]}"
}

banner "Verifying prerequisites"
[ -d "${SPECS_DIR}" ]    || { err "Orange Pi 3 LTS specs directory not found: ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Shared specs directory not found: ${SHARED_SPECS}"; exit 1; }
info "Orange Pi 3 LTS specs: ${SPECS_DIR}"
info "Shared specs:           ${SHARED_SPECS}"
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    command -v "${tool}" &>/dev/null || { err "${tool} not found in PATH."; exit 1; }
done

# ── Cross-dracut (--encrypt-root) fail-FAST preflight ───────────────
# An --encrypt-root Orange Pi 3 LTS installer needs an arm64 disk-boot
# initramfs, generated by chrooting into the target sysroot under qemu-aarch64.
# Detect a usable qemu-aarch64 NOW rather than after the multi-hour @stage4/kernel
# build. Runs only on a real build (after --print-plan), so matrix.tsv stays
# byte-identical. The post-build refusal remains the fail-SAFE backstop.
if ${ENCRYPT_ROOT} && ${BUILD_INSTALLER} && { ! ${SKIP_KERNEL} || ${IMAGE_ONLY}; }; then
    dracut_cross_register_qemu || true
    if ! dracut_cross_preflight_ok; then
        err "--encrypt-root on ${BRAND}-orangepi3-lts-${ROLE} (if this build came from a multi-image mesh worklist, THIS node image is the affected one) needs the arm64 disk-boot initramfs, but no usable cross-dracut strategy is available: ${DRACUT_CROSS_BINFMT_NODE} is not registered and/or $(dracut_cross_qemu_interp) is missing/not executable."
        err "Fix: rebuild the builder image so it ships a static qemu-aarch64 (make docker-image — Dockerfile.build FINAL stage now emerges app-emulation/qemu[static-user] QEMU_USER_TARGETS=aarch64) AND run the build in a --privileged container so binfmt_misc can be mounted/registered. Refusing now BEFORE the multi-hour @stage4/kernel build rather than after."
        exit 1
    fi
    info "cross-dracut preflight OK: qemu-${DRACUT_CROSS_QEMU_ARCH} registered ($(dracut_cross_qemu_interp)); the arm64 disk-boot initramfs is buildable via qemu-chroot."
fi

# ── General missing-qemu preflight (t=0 instead of t=40min) ─────────
# tdb/talloc/samba/cifs-utils configure with waf, which EXECUTES cross-built
# test binaries via the kernel's binfmt_misc qemu-aarch64 interpreter. When
# that interpreter is unusable in THIS container they fail ~40min into Phase 2
# ("Checking simple C program: not found") and silently DROP from the payload,
# surfacing only as the payload-incomplete assert hours later (real jetson
# edge_ai failure, session 20260716-160638-f8c153). Refuse up front IFF the
# resolved package set actually contains one of the pinned waf-family atoms
# (see DRACUT_CROSS_TARGET_EXEC_ATOMS in scripts/_dracut-cross-lib.sh);
# a missing qemu must NEVER block a build that would succeed, so a waf-free
# set only WARNs. Runs only on a real build (after --print-plan), same as the
# --encrypt-root fail-fast above.
dracut_cross_register_qemu || true   # idempotent; the same attempt the real build makes
if ! dracut_cross_preflight_ok; then
    _exec_blockers="$(resolve_stage4_packages quiet | dracut_cross_target_exec_blockers | tr '\n' ' ')"
    _exec_blockers="${_exec_blockers% }"
    if [ -n "${_exec_blockers}" ]; then
        err "${_exec_blockers} build by EXECUTING cross-compiled test binaries (waf configure — the tdb/talloc/samba/cifs-utils family) but qemu-aarch64 is unusable in THIS container: ${DRACUT_CROSS_BINFMT_NODE} is not registered and/or $(dracut_cross_qemu_interp) is missing/not executable. They would fail ~40min in and be silently dropped from the payload (payload-incomplete assert)."
        err "Fix: rebuild the builder image so it ships a static qemu-aarch64 (make docker-image — Dockerfile.build FINAL stage emerges app-emulation/qemu[static-user] QEMU_USER_TARGETS=aarch64) AND run the build in a --privileged container so binfmt_misc can be mounted/registered. Refusing now BEFORE the multi-hour cross build rather than after."
        exit 1
    fi
    warn "qemu-aarch64 unusable in this container — no target-exec (waf-family) packages in the resolved set; continuing."
fi
unset _exec_blockers

# Host-side (container /) build-backend keyword acceptance. The cross-emerge
# resolves build-time deps (BDEPEND) against the CONTAINER's own /etc/portage —
# an amd64 root — so the sysroot's specs-*/portage/package.accept_keywords
# files CANNOT cover the host-side installs (the emerge.log "to /" batch).
# dev-python/vcs-versioning (setuptools-scm's backend, pulled transitively by
# the fleet SELinux toolchain) is keyworded amd64-first upstream: in the tree
# window before amd64 stabilization the host half of the chain dies with
# "masked by: ~amd64 keyword" even though the sysroot side is accepted (the
# post-#352 frite failure). Accept it host-side too (** — pure python,
# arch-independent), mirroring the HOSTSELINUX package.use pre-seed precedent.
# HOST-MUTATION SITE. The seed below rewrites /etc/portage on whatever root this
# runs as — including "*/* PYTHON_TARGETS: python3_12 python3_13", a WILDCARD,
# system-wide python-target change. That is correct in the throwaway builder
# container (it is why the fleet builds work) and WRONG on the operator's real
# machine, so the container proof — not merely root+/etc/portage — gates it.
if hostguard_mutation_allowed; then
    mkdir -p /etc/portage/package.accept_keywords
    cat > /etc/portage/package.accept_keywords/hugmesh-host-build-backends <<'HOSTKW'
# setuptools-scm's vcs-versioning backend: pure-python/arch-independent, often
# keyworded amd64-first upstream. HOST-side twin of the sysroot's
# package.accept_keywords/setuptools-scm-backend (see that file's rationale).
dev-python/vcs-versioning **
# setuptools-scm itself: the container-stable 10.0.5 fails its own wheel
# REBUILD once vcs-versioning-2 is installed ("unable to detect version",
# real jetson host-side failure 2026-07-16); the working 10.2.x is ~amd64.
dev-python/setuptools-scm **
# HOST twins of the sysroot's SELinux userspace toolchain: libselinux-3.11's
# and policycoreutils-3.11's pkg_postinst invoke HOST sefcontext_compile /
# semodule against the ROOT!=/ merge ("sefcontext_compile: command not found"
# -> die "Failed to recompile contexts"; "semodule: command not found" ->
# die "Failed to rebuild policy store mcs" — real jetson edge_ai cross-build
# failure, session 20260716-160638-f8c153). The build container ships neither
# tool, and the 3.11 SELinux userspace is still ~amd64, so accept the window
# host-side; host tool versions should be >= the target's 3.11 policy
# toolchain (exact 3.11 parity preferred).
sys-libs/libsepol ~amd64
sys-libs/libselinux ~amd64
# policycoreutils-3.11 RDEPENDs >=sys-libs/libsemanage-3.11 (pretend-resolve
# proven in the throwaway builder container; 3.10 stays masked otherwise).
sys-libs/libsemanage ~amd64
sys-apps/policycoreutils ~amd64
HOSTKW
    info "Pre-seeded HOST /etc/portage/package.accept_keywords: vcs-versioning (build-backend)"
    # The tree's default PYTHON_TARGETS has moved past the container's
    # dev-lang/python:3.12 — the same host-side BDEPEND batch then aborts on
    # "The following USE changes are necessary to proceed:
    #  >=dev-python/…  python_targets_python3_12" (empirically reproduced against
    # the failed 2026-07-16 jetson sysroot). HOST twin of the sysroot's
    # package.use/python-targets seed — see that file's full rationale.
    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/hugmesh-host-build-backends <<'HOSTPYUSE'
# Keep the python3.12 target enabled for host-side (BDEPEND "to /") installs —
# twin of the sysroot's package.use/python-targets (see that file's rationale).
# python3_13 is enabled ALONGSIDE 3_12: the builder image's installed python
# ecosystem (setuptools/jaraco-*/hatch-vcs) was built with the 3_13 target, and
# a 3_12-only seed flips -python3_13 on every rebuild, wedging the resolver in
# a setuptools-scm slot conflict (empirically hit by the host SELinux-3.11
# tools emerge below; additive 3_12+3_13 resolves cleanly).
*/* PYTHON_TARGETS: python3_12 python3_13
# The 3.12 tooling cascade pulls host dev-lang/python:3.12 → util-linux[pam] →
# pam-1.7.2, whose pambase→passwdqc chain requires pam[audit] (twin of the
# sysroot's package.use/pam-audit; harmless in the ephemeral build container).
sys-libs/pam audit
# Host emerge of sys-apps/policycoreutils-3.11 (HOST_POLICY_TOOLS below) needs
# the python-bindings halves of its dep chain: policycoreutils ->
# libselinux[python] and selinux-python -> audit[python] (autounmask output of
# the pretend resolve in the throwaway builder container; same two lines the
# k8s-only hugmesh-cross-host-selinux seed carries, but the host policy
# tools are needed for EVERY SELinux cross build, not just k8s roles).
sys-libs/libselinux python
sys-process/audit python
HOSTPYUSE
    info "Pre-seeded HOST /etc/portage/package.use: PYTHON_TARGETS python3_12 (build-backend chain)"
elif [ "$(id -u)" -eq 0 ] && [ -d /etc/portage ]; then
    # Native root on a real host: VERIFY read-only, never write. Proceeds when the
    # host already satisfies the config; else fails fast with a reviewable command.
    hostguard_require_host_portage || exit 1
else
    info "Not root / no /etc/portage — HOST portage seed skipped (the cross emerge will use the existing config)."
fi

# Host SELinux policy build tools (same rationale as every other builder:
# selinux-base src_compile uses the HOST checkpolicy/semodule_package; cross
# copies can't run).
HOST_POLICY_TOOLS=()
command -v checkpolicy      &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/checkpolicy)
# checkmodule (same package as checkpolicy) is what compiles specs/selinux/*.te
# in scripts/_selinux-policy-lib.sh — probe it by NAME so a host that somehow has
# one binary and not the other is caught here, not mid-compile.
command -v checkmodule      &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/checkpolicy)
command -v semodule_package &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/semodule-utils)
command -v m4               &>/dev/null || HOST_POLICY_TOOLS+=(sys-devel/m4)
# HOST tool halves of the sysroot's SELinux 3.11 userspace (see the HOSTKW
# ~amd64 window above): the libselinux/policycoreutils pkg_postinst phases run
# these on the ROOT!=/ merge (session 20260716-160638-f8c153).
command -v sefcontext_compile &>/dev/null || HOST_POLICY_TOOLS+=(sys-libs/libselinux)
command -v semodule           &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/policycoreutils)
if [ "${#HOST_POLICY_TOOLS[@]}" -ne 0 ]; then
    readarray -t HOST_POLICY_TOOLS < <(printf '%s\n' "${HOST_POLICY_TOOLS[@]}" | sort -u)
    if hostguard_mutation_allowed && [ "$(id -u)" -eq 0 ] && command -v emerge &>/dev/null; then
        warn "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]} — emerging natively"
        # EMERGE-GROUP BANNER (tools): checkpolicy/semodule-utils/m4/libselinux/
        # policycoreutils are BUILD-HOST helpers the sysroot's SELinux merges shell
        # out to — they never ship in the image — so they are the 'tools' group, not
        # 'system'. Conditional (only when a tool is missing AND we may mutate the
        # host), which the Studio's forward-only phase matcher steps over cleanly.
        banner "Emerge group: tools"
        emerge --noreplace --quiet "${HOST_POLICY_TOOLS[@]}" \
            || { err "Failed to install host SELinux build tools (${HOST_POLICY_TOOLS[*]})."; exit 1; }
    else
        err "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]}"
        err "Install on the BUILD host: emerge sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4 sys-libs/libselinux sys-apps/policycoreutils (accept ~amd64 for the SELinux 3.11 window: libsepol/libselinux/policycoreutils)"
        exit 1
    fi
fi
# The LIVE/INSTALLER images need a squasher (mksquashfs, or tar2sqfs from
# squashfs-tools-ng) + xorriso to wrap the squashfs ISO.
# NATIVE HOST-TOOL PREFLIGHT: in the builder container this keeps TODAY'S
# behavior verbatim (warn now, skip the image later — both tools were measured
# present in hugmesh-builder:latest, so the hard path is unreachable during
# fleet builds). On a real host, warning up front and then silently skipping a
# requested image hours later is dishonest — fail fast with the exact emerge.
# xorriso is asymmetric and the preflight must not flatten that: --flavor installer
# hard-errors later without it ("cannot build the INSTALLER ISO"), so failing fast
# is strictly better; a LIVE-only build instead leaves a supported LIVE TREE it
# reports as "(tree; no xorriso to wrap an ISO)", so that site is --soft. Failing
# fast there would turn a build that SUCCEEDS today into exit 1.
if ${BUILD_INSTALLER}; then
    hostguard_require_host_tools "the installer ISO (--flavor installer)" "dev-libs/libisoburn" \
            -- xorriso \
        || warn "missing xorriso — the installer image step will warn + skip"
elif ${BUILD_LIVE}; then
    hostguard_require_host_tools "the LIVE ISO" "dev-libs/libisoburn" --soft \
            --hint "Without it the LIVE medium is left as an unwrapped tree." \
            -- xorriso \
        || warn "missing xorriso — the LIVE image will be left as a tree"
fi
# The squasher is NOT soft: without it the live rootfs cannot be built at all
# (installer hard-errors; LIVE dies mid-squash), so the artifact is genuinely lost.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    hostguard_require_host_tools "the live/installer image" \
            "sys-fs/squashfs-tools" \
            --hint "Or emerge sys-fs/squashfs-tools-ng instead (its tar2sqfs also works)." \
            -- "mksquashfs|tar2sqfs" \
        || warn "missing mksquashfs AND tar2sqfs — the live/installer image step will warn + skip"
fi
info "Cross-compiler: $(${CROSS_TARGET}-gcc --version | head -1)"
info "Jobs: ${JOBS}"

banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir,log} "${SYSROOT}" "${STAGE_DIR}"
# Shared asset root: create the pool + distfiles dirs and take the pool's LONG-LIVED
# single-writer lock before anything can populate them. sa_pool_hold is what makes
# docs/SHARED-BINPKG.md invalidation rule #3 enforceable now that one pool serves many
# worklist entries: the tree has no binpkg-multi-instance, so two concurrent writers
# into one pkgdir overwrite each other's package instances.
if [ -n "${SHARED_ROOT}" ]; then
    mkdir -p "${POOL_DIR}" "${SHARED_DISTDIR}" "${SHARED_SEED_DIR}" \
        || { err "cannot create the shared asset root ${SHARED_ROOT}"; exit 1; }
    sa_pool_hold "${POOL_DIR}" || { err "shared binpkg pool busy (see above) — aborting."; exit 1; }
    info "$(sa_describe "${SHARED_ROOT}" "arm64" "${POOL_DIR}")"
fi
exec > >(tee -a "${LOG_FILE}" "${IMAGE_LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE} (session-shared) + ${IMAGE_LOG_FILE} (this image)"
# Run banner: the shared log interleaves runs (append) and a RESTART appends to
# the per-image log too — keep every chunk attributable to its run.
echo "==== ${BUILD_SUBDIR#wl-} (${BUILD_SUBDIR}) start ${BUILD_TS} brand=${BRAND} role=${ROLE} env=${ENV} ===="

banner "Fetching stage3 seed (arm64)"
STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
STAGE3_BASENAME=$(basename "${STAGE3_FILE}")
STAGE3_FULL_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/${STAGE3_FILE}"
# Stage3 seed: ONE per-arch cache under the shared root instead of a fresh ~250 MB
# download for every BUILD_SUBDIR (a Studio wl-<id> tree re-fetched it EVERY time).
# sa_seed_acquire re-runs the FULL supply-chain verification (dlv_verify_stage3:
# GPG-signed DIGESTS + SHA512/SHA256) on the file it hands back — cache HIT or fresh
# download — so a poisoned cache is caught by exactly the code that catches a poisoned
# mirror. Caching must never turn "verified once" into "trusted forever". Fail-closed:
# an unverifiable seed is discarded, re-fetched ONCE, and a second failure aborts.
# Per-arch keying (dir AND basename) makes an amd64 seed unusable by this arm64 build.
STAGE3_PRIVATE="${BUILD_ROOT}/${STAGE3_BASENAME}"
banner "Verifying stage3 seed signature + checksum"
if ! STAGE3_LOCAL="$(sa_seed_acquire "${SHARED_ROOT}" "arm64" "${STAGE3_BASENAME}" \
        "${STAGE3_FULL_URL}" "${STAGE3_PRIVATE}")"; then
    err "stage3 seed unavailable or failed verification (bad signature or checksum) — aborting."
    err "If Gentoo rotated its signing key, set DLV_GENTOO_KEY=<fingerprint>; for an"
    err "air-gapped build set DLV_OFFLINE_KEYRING=<keyfile>. Refusing unverified seed."
    exit 1
fi
info "stage3 seed verified: ${STAGE3_LOCAL}"

banner "Extracting stage3 into sysroot"
if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then
    info "Sysroot already populated and --resume set, skipping extraction"
else
    TAR_X=(--exclude='./dev/*')
    [ "$(id -u)" -ne 0 ] && TAR_X+=(--no-same-owner)
    tar -C "${SYSROOT}" --xattrs-include='*.*' "${TAR_X[@]}" -xpf "${STAGE3_LOCAL}" 2>/dev/null || \
    tar -C "${SYSROOT}" "${TAR_X[@]}" -xpf "${STAGE3_LOCAL}"
    mkdir -p "${SYSROOT}/dev"
    info "Extracted into ${SYSROOT} (device nodes skipped; devtmpfs at boot)"
fi

banner "Installing spec files into sysroot (hardened profile)"
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,package.mask,profile,env,package.env,repos.conf}
GENTOO_REPO="$(portageq get_repo_path / gentoo 2>/dev/null || echo /var/db/repos/gentoo)"
cat > "${SYSROOT}/etc/portage/repos.conf/gentoo.conf" <<EOF
[DEFAULT]
main-repo = gentoo
[gentoo]
location = ${GENTOO_REPO}
EOF
PROFILE_PATH="$(sed 's/^gentoo://' "${SPECS_DIR}/portage/profile/parent" | tr -d '[:space:]')"
[ -d "${GENTOO_REPO}/profiles/${PROFILE_PATH}" ] || { err "profile not found: ${GENTOO_REPO}/profiles/${PROFILE_PATH}"; exit 1; }
ln -sfn "${GENTOO_REPO}/profiles/${PROFILE_PATH}" "${SYSROOT}/etc/portage/make.profile"
cp "${SPECS_DIR}/portage/profile/use.mask"          "${SYSROOT}/etc/portage/profile/use.mask"
# package.provided: OPTIONAL — this platform has no GTK/browser stack pulling
# in Rust-based cross-compile exclusions, so specs-orangepi3-lts ships none;
# only copy it if a future addition needs one.
[ -f "${SPECS_DIR}/portage/profile/package.provided" ] && \
    cp "${SPECS_DIR}/portage/profile/package.provided" "${SYSROOT}/etc/portage/profile/package.provided"
pcs_sync_dir "${SPECS_DIR}/portage/package.accept_keywords" "${SYSROOT}/etc/portage/package.accept_keywords"
pcs_sync_dir "${SPECS_DIR}/portage/package.use" "${SYSROOT}/etc/portage/package.use"
pcs_sync_dir "${SPECS_DIR}/portage/package.env" "${SYSROOT}/etc/portage/package.env"
cp "${SPECS_DIR}/portage/env/"*.conf               "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"
# Derive PYTHON_TARGETS/PYTHON_SINGLE_TARGET from the seed's own installed
# interpreter set (superset invariant — never a frozen literal). Fails the
# build rather than guessing. Analysis: docs/PYTHON-TARGETS-SEED-DRIFT.md.
pt_apply_seed_targets "${SYSROOT}" "build-orangepi3-lts" \
    || { err "could not derive PYTHON_TARGETS from the stage3 seed (see above)"; exit 1; }
# ── Shared build assets in the rendered make.conf — SB-SHARED-ASSETS-BEGIN ───
# PKGDIR/DISTDIR are rendered from @@WORK_DIR@@ (= ${BUILD_ROOT}), which is PER-ENTRY
# under the Studio (wl-<id>) — that is the whole G2 bug. Re-assign both to the shared
# root here: make.conf is bash-sourced by portage, so the LAST assignment wins (the
# same idiom the PORTAGE_RO_DISTDIRS append below already uses), and no new @@MARKER@@
# has to be threaded through nine spec trees.
#   * PKGDIR  -> the per-BOARD pool; still gated by the #439 fingerprint preflight.
#   * DISTDIR -> the fleet-wide distfiles dir. Distfiles are arch-independent SOURCE
#     tarballs and portage verifies every one against the ebuild Manifest, so a single
#     writable fleet cache is safe (portage takes its own per-file fetch lock).
if [ -n "${SHARED_ROOT}" ]; then
    {
        printf '\n# --- hugmesh shared build assets (scripts/_shared-assets-lib.sh) ---\n'
        printf 'PKGDIR="%s"\n'  "${POOL_DIR}"
        printf 'DISTDIR="%s"\n' "${SHARED_DISTDIR}"
    } >> "${SYSROOT}/etc/portage/make.conf"
    info "Shared assets: PKGDIR=${POOL_DIR} DISTDIR=${SHARED_DISTDIR}"
fi
# SB-SHARED-ASSETS-END
# Shared READ-ONLY distfiles (Lane 3) — SB-RO-DISTFILES-BEGIN
# distfiles are arch-independent SOURCE tarballs, so ONE fleet-wide cache is safe
# across every board (NO ABI/-mcpu risk — mirrors the x86 builder's
# PORTAGE_RO_DISTDIRS reuse). --distdir DIR (or SNAP_DISTDIR_SRC in the env)
# exposes that cache READ-ONLY: new fetches still land in this build's PRIVATE
# ${BUILD_ROOT}/distfiles (DISTDIR), so the shared pool is never written. Unlike
# x86 (which emerges INSIDE a chroot and bind-mounts the dir under the sysroot),
# this builder emerges on the HOST with PORTAGE_CONFIGROOT=${SYSROOT}, so
# PORTAGE_RO_DISTDIRS points straight at the host path. A set-but-bad path WARNs
# and is ignored (correct artifact, just re-downloads) — mirrors x86's shape-check.
# A --distdir that resolves to the SHARED distfiles dir is ALREADY this build's DISTDIR
# (see the SB-SHARED-ASSETS block above); listing it again as PORTAGE_RO_DISTDIRS would
# name one directory twice. Drop the duplicate rather than emit it.
if [ -n "${SHARED_DISTDIR}" ] && [ "${DISTDIR_SRC%/}" = "${SHARED_DISTDIR%/}" ]; then
    DISTDIR_SRC=""
fi
if [ -n "${DISTDIR_SRC}" ] && [ ! -d "${DISTDIR_SRC}" ]; then
    warn "--distdir: not a directory: ${DISTDIR_SRC} — IGNORING it (sources re-download into ${BUILD_ROOT}/distfiles)."
elif [ -n "${DISTDIR_SRC}" ]; then
    grep -q 'PORTAGE_RO_DISTDIRS' "${SYSROOT}/etc/portage/make.conf" 2>/dev/null \
        || printf 'PORTAGE_RO_DISTDIRS="%s"\n' "${DISTDIR_SRC}" >> "${SYSROOT}/etc/portage/make.conf"
    info "Distfiles: reusing shared cache ${DISTDIR_SRC} via PORTAGE_RO_DISTDIRS (read-only; new fetches -> ${BUILD_ROOT}/distfiles)"
fi
# SB-RO-DISTFILES-END

cp "${SPECS_DIR}/etc/fstab" "${SYSROOT}/etc/fstab"

# LUKS2 root (--encrypt-root): persist crypt-module support into any FUTURE
# dracut regeneration on the installed system (e.g. a post-install kernel
# rebuild), not just the disk-boot initramfs this build generates directly.
if ${ENCRYPT_ROOT}; then
    mkdir -p "${SYSROOT}/etc/dracut.conf.d"
    cp "${SPECS_DIR}/etc/dracut.conf.d/60-hugmesh-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/"
fi

# ── Shared (arch-agnostic) mesh + provisioning + sshd — the SAME plumbing every
# other client image uses, so this board joins the SAME mesh with the SAME
# key-only SSH + device-license posture. ────────────────────────────────────
mkdir -p "${SYSROOT}/etc/init.d"
for svc in growroot headscale tailscaled keys-provision; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"
    chmod +x "${SYSROOT}/etc/init.d/${svc}"
done
write_growfs_conf "${SYSROOT}/etc/growfs.conf"

mkdir -p "${SYSROOT}/etc/headscale"
cp "${SHARED_SPECS}/etc/headscale/config.yaml"   "${SYSROOT}/etc/headscale/config.yaml"
# WS-SUPER-B: template the node's headscale MagicDNS suffix to the orchestration
# superdomain so the baked config agrees with the KEYS/provision channel. "" = the
# checked-in default (headnet.internal); provision.json stays authoritative at first boot.
if [ -n "${SUPERDOMAIN}" ] && [ -f "${SYSROOT}/etc/headscale/config.yaml" ]; then
    sed -i "s|^  base_domain: .*|  base_domain: ${SUPERDOMAIN}|" "${SYSROOT}/etc/headscale/config.yaml"
    info "Templated headscale base_domain -> ${SUPERDOMAIN} (orchestration superdomain)"
fi
# Layer-A: bake the BOOTSTRAP policy AS the initial policy.hujson (NO any-to-any
# :22 hole; KEEPS the k8s CIDR data-plane rule). First verified Layer-A sync
# re-renders it from policy.hujson.tmpl. (See build-x86-host-stage4.sh rationale.)
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson" "${SYSROOT}/etc/headscale/policy.hujson"

mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/var/lib/keys-provision"
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh" "${SYSROOT}/usr/sbin/keys-provision"
chmod +x "${SYSROOT}/usr/sbin/keys-provision"

# Hardened, key-only sshd (NO broad SSH access; PermitRootLogin prohibit-password,
# PasswordAuthentication no). The device-license registry is enforced via the
# per-node principals provisioned from the KEYS USB by keys-provision.
mkdir -p "${SYSROOT}/etc/ssh/sshd_config.d"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/hardened.conf" "${SYSROOT}/etc/ssh/sshd_config.d/hardened.conf"

# ── Layer-B device-license-registry sshd enforcement (ADMIN/mesh-extension) ─────
# Same INERT-on-core plumbing every other client image bakes: provision_device_registry()
# ACTIVATES it only when owner_type=ADMIN, so a SUPERADMIN/core node keeps the #66
# owner-key path. Enforcement conf + break-glass + cron are STAGED under
# /etc/hugmesh/registry (installed on ADMIN nodes only; the conf gate-flips on
# the first verified sync).
mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/usr/lib/hugmesh" \
         "${SYSROOT}/etc/hugmesh/registry" "${SYSROOT}/var/lib/hugmesh/device-registry"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-authorized-keys-lookup" "${SYSROOT}/usr/sbin/hugmesh-authorized-keys-lookup"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-device-registry-sync"   "${SYSROOT}/usr/sbin/hugmesh-device-registry-sync"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-authorized-keys-lookup" "${SYSROOT}/usr/sbin/hugmesh-device-registry-sync"
cp "${SHARED_SPECS}/usr/lib/hugmesh/registry-verify.sh"      "${SYSROOT}/usr/lib/hugmesh/registry-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-device-registry-sync" "${SYSROOT}/etc/init.d/hugmesh-device-registry-sync"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-device-registry-sync"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/device-registry.conf" "${SYSROOT}/etc/hugmesh/registry/device-registry.conf"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/break-glass.conf"     "${SYSROOT}/etc/hugmesh/registry/break-glass.conf"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-device-registry-sync" "${SYSROOT}/etc/hugmesh/registry/cron-device-registry-sync"

# ── Layer-A device-license-registry headscale policy (CONTROL/pki node only) ────
# provision_headscale_policy_sync() ACTIVATES these only when headscale.enabled
# (the control node). Inert on a non-control node. REUSES Layer-B's registry-verify.sh
# + baked registry-pub.ed25519 (no duplication).
cp "${SHARED_SPECS}/usr/sbin/gen-headscale-policy.sh"          "${SYSROOT}/usr/sbin/gen-headscale-policy.sh"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-headscale-forcetags"   "${SYSROOT}/usr/sbin/hugmesh-headscale-forcetags"
chmod +x "${SYSROOT}/usr/sbin/gen-headscale-policy.sh" "${SYSROOT}/usr/sbin/hugmesh-headscale-forcetags"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-policy-sync"         "${SYSROOT}/etc/init.d/hugmesh-policy-sync"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-policy-sync"
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson"     "${SYSROOT}/etc/headscale/policy.bootstrap.hujson"
cp "${SHARED_SPECS}/etc/headscale/policy.hujson.tmpl"          "${SYSROOT}/etc/headscale/policy.hujson.tmpl"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-policy-sync"         "${SYSROOT}/etc/hugmesh/registry/cron-policy-sync"

# ── NODE-STORAGE reconcile (signed per-node export consumer) — enabled by keys-provision ──
# The pull-half twin of hugmesh-device-registry-sync (boot oneshot + 60s cron
# convergence floor). storage-verify.sh SOURCES Layer-B's registry-verify.sh (the
# IDENTICAL detached-Ed25519 verify + strict-monotonic rollback guard; REUSES the
# baked registry-pub.ed25519 — never re-bake). INERT with no registered pool: the
# signed per-node export is the EMPTY body, so the agent provisions NOTHING. The
# cron drop-in is STAGED at /etc/hugmesh/registry (keys-provision rc-update adds
# the boot oneshot + places the cron into /etc/cron.d on every mesh node).
# The bake itself lives in scripts/_node-storage-bake-lib.sh — see its header for
# why it is a function and not seven pasted lines.
bake_node_storage "${SYSROOT}" "${SHARED_SPECS}" \
    || { err "node-storage bake failed (see above)"; exit 1; }

# ── Egress VPN (split-tunnel, fail-closed) — node-level, DEFAULT-OFF ────────────
# Bake the OpenRC service + the split-tunnel runner into every node image; INERT
# until enabled (not linked into a runlevel here; no active.conf => runner no-op).
cp "${SHARED_SPECS}/etc/init.d/hugmesh-egress-vpn" "${SYSROOT}/etc/init.d/hugmesh-egress-vpn"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-egress-vpn"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-vpn-runner"   "${SYSROOT}/usr/sbin/hugmesh-vpn-runner"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-vpn-runner"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-vpn-mark"     "${SYSROOT}/usr/sbin/hugmesh-vpn-mark"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-vpn-mark"
mkdir -p "${SYSROOT}/etc/hugmesh/vpn"; chmod 0700 "${SYSROOT}/etc/hugmesh/vpn"

# ── Egress-VPN reconcile bridge (signed per-node export consumer) — DEFAULT-OFF ─
# Bake the reconcile agent + verify lib + OpenRC service; INERT until enabled
# (REUSES the baked registry-pub.ed25519; the cron is staged for the gate).
cp "${SHARED_SPECS}/usr/sbin/hugmesh-vpn-reconcile" "${SYSROOT}/usr/sbin/hugmesh-vpn-reconcile"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-vpn-reconcile"
cp "${SHARED_SPECS}/usr/lib/hugmesh/vpn-verify.sh" "${SYSROOT}/usr/lib/hugmesh/vpn-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-vpn-reconcile" "${SYSROOT}/etc/init.d/hugmesh-vpn-reconcile"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-vpn-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-vpn-reconcile" "${SYSROOT}/etc/hugmesh/registry/cron-vpn-reconcile"

# ── Opt-in host-binary auto-update (binpkg deltas from the binhost) ─────────────
# The SAME poller every other client image bakes: keeps a client device's
# binaries fresh from the tailnet binhost over the VPN. provision_update() bakes
# the /etc/cron.d cadence timer + the boot oneshot is linked into the default
# runlevel below, but the poller is DEFAULT-OFF / INERT: it does NOTHING until a
# superadmin opts in by setting enabled:true in the hugmesh-update-policy
# ConfigMap (fail-safe-to-OFF — an absent/unreachable policy means NO pull).
# cronie + OpenRC (not systemd).
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/hugmesh-update"     "${SYSROOT}/usr/local/sbin/hugmesh-update"
chmod +x "${SYSROOT}/usr/local/sbin/hugmesh-update"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-update"         "${SYSROOT}/etc/init.d/hugmesh-update"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-update"
# ── Domain-registry -> brand-repo bridge (#4) — DEFAULT-OFF, baked-but-INERT ─────
# Bake the reconcile agent + its verify lib (domain-verify.sh) + the OpenRC service
# + the two generators for PARITY with every other client/host image. This
# platform is a single-board appliance, NOT a k8s cluster node (it bakes no
# cluster GitOps tree) and has no _opt_selected gate, so — exactly like the
# egress-VPN reconcile above — the agent is NEVER linked into a runlevel here
# (inert-by-omission). REUSES the baked registry-pub.ed25519 (never re-bake).
# Even if hand-enabled it fail-closes without a real key + transport, and with
# no cluster there is nothing to drive.
cp "${SHARED_SPECS}/usr/sbin/hugmesh-domain-reconcile" "${SYSROOT}/usr/sbin/hugmesh-domain-reconcile"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-domain-reconcile"
cp "${SHARED_SPECS}/usr/lib/hugmesh/domain-verify.sh" "${SYSROOT}/usr/lib/hugmesh/domain-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-domain-reconcile" "${SYSROOT}/etc/init.d/hugmesh-domain-reconcile"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-domain-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-domain-reconcile" "${SYSROOT}/etc/hugmesh/registry/cron-domain-reconcile"
mkdir -p "${SYSROOT}/usr/share/hugmesh/generator/scripts" "${SYSROOT}/usr/share/hugmesh/generator/templates"
cp "${SCRIPT_DIR}/scripts/gen-keystores.sh"  "${SYSROOT}/usr/share/hugmesh/generator/scripts/gen-keystores.sh"
cp "${SCRIPT_DIR}/generate-brand-repos.sh"   "${SYSROOT}/usr/share/hugmesh/generator/generate-brand-repos.sh"
cp -r "${SCRIPT_DIR}/templates/."            "${SYSROOT}/usr/share/hugmesh/generator/templates/"
chmod +x "${SYSROOT}/usr/share/hugmesh/generator/scripts/gen-keystores.sh" "${SYSROOT}/usr/share/hugmesh/generator/generate-brand-repos.sh"

# Node role + domain + env markers (read by keys-provision / first-boot).
mkdir -p "${SYSROOT}/etc/hugmesh"
echo "${ROLE}"           > "${SYSROOT}/etc/hugmesh/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/hugmesh/cluster-domain"
# Orchestration superdomain (WS-SUPER-B): record the mesh plane the image joins.
if [ -n "${SUPERDOMAIN}" ]; then
    echo "${SUPERDOMAIN}" > "${SYSROOT}/etc/hugmesh/superdomain"
    info "Baked orchestration superdomain -> /etc/hugmesh/superdomain (${SUPERDOMAIN})"
fi
echo "${ENV}"            > "${SYSROOT}/etc/hugmesh/env"
echo "orangepi3-lts"     > "${SYSROOT}/etc/hugmesh/board"
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/hugmesh/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/hugmesh/headscale-url"
fi
if ${STANDALONE}; then
    # STANDALONE appliance: bake the marker so keys-provision skips all
    # mesh-seeking no-ops and a normal LOCAL USER logs in over SSH with the
    # build-set password (mirrors build-x86-host-stage4.sh / build-frite-stage4.sh
    # / build-orangepi5-stage4.sh).
    echo "true" > "${SYSROOT}/etc/hugmesh/standalone"
    info "Standalone appliance: local user '${DEFAULT_USER}' over SSH, no mesh."
fi
rebrand_sysroot

# First-boot finaliser (shared template) + radio hardening + zram swap.
# Rendered UNCONDITIONALLY (like every other sibling): the finaliser is what
# wires up first-boot provisioning, so a missing template is a hard error
# rather than a silently-skipped image that never finalises.
mkdir -p "${SYSROOT}/etc/local.d"
[ -f "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" ] || {
    err "missing first-boot finaliser template: ${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl"; exit 1; }
render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"
harden_radios "${SYSROOT}"

# Root SSH login DISABLED by default (hardened). Authoritative sshd drop-in (00- prefix
# => sshd takes the FIRST PermitRootLogin) from PERMIT_ROOT_LOGIN (no | prohibit-password |
# yes; default no). hardened.conf 'PermitRootLogin no' stays a fail-safe backstop; the
# non-root KEYS admin user (or, --standalone, the local user) is the entry point, so
# this never bricks a node.
configure_root_login() {
    local sysroot="$1"
    local val="${PERMIT_ROOT_LOGIN:-no}"
    case "${val}" in no|yes|prohibit-password) ;; *) val=no ;; esac
    mkdir -p "${sysroot}/etc/ssh/sshd_config.d"
    {
        echo "# Generated by build-*-stage4.sh from PERMIT_ROOT_LOGIN. Root SSH login is"
        echo "# DISABLED by default; re-enable with --permit-root-login yes. 00- => authoritative."
        echo "PermitRootLogin ${val}"
    } > "${sysroot}/etc/ssh/sshd_config.d/00-root-login.conf"
    if [ "${val}" = "no" ]; then
        info "Root SSH login DISABLED by default. Admin via the non-root KEYS/local user; re-enable with --permit-root-login yes."
    else
        info "Root SSH login set to '${val}' (--permit-root-login / PERMIT_ROOT_LOGIN=${val})."
    fi
}
configure_root_login "${SYSROOT}"
# --standalone: re-enable SSH password auth for the LOCAL (non-root) user only.
# This platform is HEADLESS (no lightdm/GUI at all — see specs-orangepi3-lts/
# README.md), unlike every other standalone-capable platform in this repo,
# which has a physical GUI console as its primary local login surface. hardened.conf's
# PasswordAuthentication no + no SSH key ever provisioned for LOCAL_USER in
# standalone mode (no mesh, so no KEYS-USB authorized_keys distribution either)
# would otherwise make the local user's password COMPLETELY unusable for
# login — neither password-SSH nor pubkey-SSH would work, leaving a physical
# serial-console cable as the only way in, contradicting this platform's own
# "local user, no mesh" == "SSH/console login" promise (docs/STANDALONE-DESKTOP.md).
# Same 00- drop-in precedence trick as configure_root_login above (sshd takes
# the FIRST PasswordAuthentication it sees; 00- sorts before hardened.conf).
# PermitRootLogin is UNAFFECTED — root SSH login stays governed by
# configure_root_login()/PERMIT_ROOT_LOGIN exactly as on every other platform.
if ${STANDALONE}; then
    {
        echo "# Generated by build-orangepi3-lts-stage4.sh for --standalone: this platform"
        echo "# is HEADLESS (no GUI console), and standalone mode never provisions an SSH"
        echo "# key for the local user (no mesh => no KEYS-USB authorized_keys), so"
        echo "# password auth is the only way to actually reach the box. 00- => authoritative"
        echo "# over hardened.conf's PasswordAuthentication no. Root login is unaffected —"
        echo "# see 00-root-login.conf / --permit-root-login."
        echo "PasswordAuthentication yes"
    } > "${SYSROOT}/etc/ssh/sshd_config.d/00-standalone-password-auth.conf"
    info "STANDALONE: SSH password auth ENABLED for the local (non-root) user — this headless platform has no other local login surface without it."
fi
write_zram_firstboot "${SYSROOT}"

echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"
echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${SYSROOT}/etc/localtime"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"

# OpenRC service links — mesh + provisioning + SSH. NO display-manager / dbus /
# elogind service EVER on this platform (no desktop session exists to start —
# mirrors build-frite-stage4.sh's --desktop none headless-base runlevel
# exactly, made PERMANENT here rather than conditional, since this board has
# no other mode).
mkdir -p "${SYSROOT}/etc/runlevels/default"
DEFAULT_SVCS=(sshd NetworkManager cronie haveged growroot keys-provision local)
# Opt-in host-binary auto-update: link the boot oneshot into the default runlevel
# UNCONDITIONALLY (every client image) as PLUMBING. The cadence cron is baked by
# provision_update() at first boot, but the poller is DEFAULT-OFF — inert until a
# superadmin sets enabled:true in the hugmesh-update-policy ConfigMap.
DEFAULT_SVCS+=(hugmesh-update)
# headscale on this node is a CLIENT of the fleet control server (it does NOT host
# the control plane — that lives on the pki node), so we do NOT add headscale to
# the default runlevel here; only the tailscale CLIENT runs.
if ! ${SKIP_MESH} && ! ${SKIP_TAILSCALE}; then
    DEFAULT_SVCS+=(tailscaled)
fi
for svc in "${DEFAULT_SVCS[@]}"; do
    ln -sf "/etc/init.d/${svc}" "${SYSROOT}/etc/runlevels/default/${svc}" 2>/dev/null || true
done

info "Profile: ${PROFILE_PATH}"

cross_emerge() {
    mkdir -p "${BUILD_ROOT}/log" "${BUILD_ROOT}/edb" "${BUILD_ROOT}/tmp"
    ROOT="${SYSROOT}" SYSROOT="${SYSROOT}" PORTAGE_CONFIGROOT="${SYSROOT}" \
    EMERGE_LOG_DIR="${BUILD_ROOT}/log" PORTAGE_DEPCACHEDIR="${BUILD_ROOT}/edb" \
    PORTAGE_TMPDIR="${BUILD_ROOT}/tmp" \
    "${CROSS_TARGET}-emerge" --jobs="${JOBS}" --load-average="${JOBS}" --with-bdeps=n \
        --usepkg=y --binpkg-respect-use=y "$@"
    # --usepkg=y: CONSUME the binpkgs FEATURES=buildpkg already produces, so
    # re-runs / multi-role builds don't recompile the arm64 world from source
    # (mirrors the Pi5 builder). SAFE: PKGDIR is ${POOL_DIR} under this
    # board's OWN BUILD_SUBDIR (snap-build-orangepi3-lts) — reuse is same-board
    # only, never across boards (different -mcpu ⇒ SIGILL). --binpkg-respect-use=y
    # rejects a binpkg whose recorded USE ≠ the current config (rebuilds it).
}

# Don't cross-rebuild the toolchain (fails under crossdev). Same as every sibling.
REBUILD_TOOLCHAIN="${REBUILD_TOOLCHAIN:-false}"
if ${REBUILD_TOOLCHAIN}; then
    CROSS_EXCLUDE=()
else
    CROSS_EXCLUDE=(--exclude sys-devel/gcc --exclude sys-devel/gcc-config
                   --exclude sys-libs/glibc --exclude sys-devel/binutils)
fi

mkdir -p "${SYSROOT}/dev"
for _devspec in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
    _devname="${_devspec%% *}"; _devargs="${_devspec#* }"
    [[ -e "${SYSROOT}/dev/${_devname}" ]] || mknod -m 666 "${SYSROOT}/dev/${_devname}" ${_devargs}
done
unset _devspec _devname _devargs

if ${IMAGE_ONLY}; then
    banner "SKIPPED @system (--image-only)"
    banner "SKIPPED role payload (--image-only)"
else

banner "Emerging @system (hardened, cross-compiled)"
# ── binpkg-pool fingerprint preflight (shared-binpkg SIGILL guard) ─────────────
# Before the FIRST --usepkg cross_emerge consumes ${POOL_DIR}, verify the
# pool's fingerprint (CHOST + exact CFLAGS/-mcpu + CXXFLAGS + profile, read from the
# rendered make.conf) matches THIS build. portage's --binpkg-respect-use checks USE
# only, never CFLAGS — so this is the ONLY check that catches a cross-board (different
# -mcpu) pool being reused, which would SIGILL at runtime. Fresh pool ⇒ stamped;
# mismatch ⇒ abort. Belt-and-suspenders over the per-board BUILD_SUBDIR isolation.
# sa_pool_guard runs that SAME preflight under the pool lock (two builds must not
# race the stamp file) — the guard itself is never bypassed.
sa_pool_guard "${POOL_DIR}" "${SYSROOT}/etc/portage/make.conf" "${PROFILE_PATH:-}" \
    || { err "binpkg pool ABI mismatch (see above) — refusing --usepkg reuse."; exit 1; }

# ── EMERGE-GROUP BANNER (system) ──────────────────────────────────────────────
# Tells the Studio which of image|tools|dependencies|system|world the FOLLOWING
# ">>> Emerging (N of M) cat/pn-ver" stream belongs to, so the GUI sub-lists
# packages under the right group. This builder produces CLIENT images only (it
# has no node-role axis — -r/--role is a marker-only escape hatch): they are
# mesh-affiliated by default and standalone with --standalone (which flips
# SKIP_MESH/SKIP_TAILSCALE, see the STANDALONE posture block above). The posture
# only changes which atoms resolve_stage4_packages() returns and whether the
# LATER Phase 2.5 mesh-VPN step runs — never WHICH emerge invocations exist —
# so this one banner set covers the platform's mesh AND standalone builds alike.
# ONE banner per contiguous run of the same group (a group is a SECTION of the
# stream; the parser holds it until the next transition), so baselayout and
# @system share this one rather than emitting a meaningless second step.
# baselayout + @system are the base layer/profile set — 'system', not payload.
# ── BEGIN shared block: emerge-plan preview (system) ──────────────────────────
# Read-only --pretend pass with the SAME argument vector as the @system merge
# below (check.sh's EPL bucket pins the textual parity), emitted BEFORE the
# banner so the Studio knows the resolved list up front. The baselayout oneshot
# shares the banner but is ONE known atom — the @system resolution is the list
# worth previewing. Never fatal: every failure path inside emerge_plan_emit
# prints an honest unavailable line and returns 0.
emerge_plan_emit system cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" @system
# ── END shared block: emerge-plan preview (system) ────────────────────────────
banner "Emerge group: system"
cross_emerge --oneshot --update sys-apps/baselayout
cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" @system \
    || warn "@system had package failures (--keep-going); continuing"

banner "Emerging role payload (stage4, cross-compiled)"
# Resolved via resolve_stage4_packages() (defined above "Verifying
# prerequisites") — the SAME single-sourced resolver the qemu preflight
# consulted at t=0, so the two can never drift.
mapfile -t STAGE4_PACKAGES < <(resolve_stage4_packages)
# The package set is MANDATORY: an empty list means the grep/specs path is broken
# and we would emerge nothing and emit a payload-less stage4.
[ -s "${SPECS_DIR}/portage/packages.list" ] || { err "packages.list is empty/missing: ${SPECS_DIR}/portage/packages.list"; exit 1; }
[ "${#STAGE4_PACKAGES[@]}" -gt 0 ] || { err "no stage4 packages resolved from the package lists — refusing to build a payload-less image."; exit 1; }
info "Package count: ${#STAGE4_PACKAGES[@]}"
# EMERGE-GROUP BANNER (image): STAGE4_PACKAGES IS the role package set — the image
# payload. The per-package retry loop below is the SAME group (it re-runs the very
# atoms this batch just failed on), so it deliberately does NOT re-announce.
# ── BEGIN shared block: emerge-plan preview (image) ───────────────────────────
# Same-argument --pretend preview of the payload batch merge below (EPL-pinned
# parity, one line vs the batch line's if-wrapper). Runs AFTER @system so the
# plan is resolved against the same sysroot state the payload merge will see.
# Never fatal — unavailable line + return 0 on any failure. The per-package
# retry loop below re-runs atoms from this same list, so it gets no second
# preview.
emerge_plan_emit image cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${STAGE4_PACKAGES[@]}"
# ── END shared block: emerge-plan preview (image) ─────────────────────────────
banner "Emerge group: image"
if ! cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${STAGE4_PACKAGES[@]}"; then
    warn "Batch emerge failed (unsatisfiable atom?); retrying per-package so the rest still install"
    for _pkg in "${STAGE4_PACKAGES[@]}"; do
        cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${_pkg}" \
            || warn "  skipped ${_pkg}"
    done
fi

# ── Post-emerge payload assert (mirrors the x86 "stage4 payload incomplete"
# guard) ──────────────────────────────────────────────────────────────────
# The @system/packages.list emerges above are warn-only (--keep-going + the
# per-package retry), so a broken package set would otherwise silently produce a
# HOLLOW stage4. Assert the role-defining binaries actually landed in the sysroot
# and fail LOUDLY listing any that are missing. CROSS-COMPILE: these are aarch64
# target binaries, so we use FILE-EXISTENCE checks across the usual bindirs (NOT
# `command -v`, which would test the host).
have_in_sysroot() {
    # $1 = binary basename; true if it exists in any of the target's bindirs.
    local b="$1" d
    for d in usr/bin usr/sbin bin sbin usr/local/bin usr/local/sbin; do
        [ -e "${SYSROOT}/${d}/${b}" ] && return 0
    done
    return 1
}
# Base payload (always required): networking + login + base utils. NO desktop
# binaries in this list, ever, on this platform (Xorg/openbox/lightdm/... —
# see the builder header for why this board never has any of those).
REQUIRED_BINS=(NetworkManager nmcli sshd nano)
# Bootable flavors (LIVE or INSTALLER): dracut must be present to GENERATE the
# dmsquash-live initramfs that both media boot from.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    REQUIRED_BINS+=(dracut)
fi
# LUKS2 root (--encrypt-root): cryptsetup must be present in the LIVE environment
# for install-orangepi3-lts.sh's ENCRYPT branch to format/open the encrypted root.
if ${ENCRYPT_ROOT}; then
    REQUIRED_BINS+=(cryptsetup)
fi
payload_missing=""
for _b in "${REQUIRED_BINS[@]}"; do
    have_in_sysroot "${_b}" || payload_missing="${payload_missing} ${_b}"
done
if [ -n "${payload_missing}" ]; then
    err "stage4 payload incomplete — missing role-defining binaries in ${SYSROOT}:${payload_missing}"
    err "       the packages.list emerge did not complete; review the emerge output above."
    exit 1
fi
info "stage4 payload assert OK (${#REQUIRED_BINS[@]} role binaries present)."

# ── REQUESTED-ATOM COMPLETENESS GATE (scripts/_payload-gate-lib.sh) ───────────
# The binary assert above only covers a HANDFUL of role-defining commands, so a
# package that fails under --keep-going ships a SILENTLY DEGRADED image that
# still looks like a clean build (the class that shipped firewalld-less rpi5
# images in session 20260719-103006-a775c2 — see the lib header). Every atom we
# asked for must be in the TARGET sysroot's vdb — cross_emerge() merges with
# ROOT="${SYSROOT}", so that is the vdb the gate queries (never the host's).
# The kernel tier (sys-kernel/gentoo-sources) fails the build even under
# --allow-missing-packages: without it Phase 3 warn-skipped and this builder
# exited 0 with an UNBOOTABLE kernel-less artifact (the LIVE flavor silently
# skipped, only the stage4 tarball emitted). Fail HERE, before the mesh fetch
# and the multi-minute kernel phase, while the emerge output is still on
# screen. --skip-kernel is the only sanctioned kernel opt-out.
_kernel_gate_atom="sys-kernel/gentoo-sources"
${SKIP_KERNEL} && _kernel_gate_atom=""
requested_atom_gate "${SYSROOT}" "${BUILD_ROOT}" "build-orangepi3-lts" \
    "${ALLOW_MISSING_PACKAGES}" "${_kernel_gate_atom}" "${STAGE4_PACKAGES[@]}" \
    || { err "requested-atom completeness gate failed (see the missing-atom list above)."; exit 1; }

# ── --packages-only: prebuild the binpkg pool, then STOP before image assembly ──
# The cross_emerge above populated PKGDIR (${POOL_DIR}) under
# FEATURES=buildpkg, and the payload assert just confirmed the pool built the role
# set. In --packages-only mode we exit NOW — before mesh, the kernel, the boot tree
# and the stage4 tarball — so the ONLY output is the per-board binpkg pool a later
# per-role image build reuses via --usepkg (guarded by the fingerprint preflight).
# The pool lives in ${POOL_DIR} (outside the sysroot), so it is never
# stripped. We emit NOTHING image-shaped.
if ${PACKAGES_ONLY}; then
    info "--packages-only: per-board binpkg pool prebuilt at ${POOL_DIR} — skipping image assembly (PLAN_PACKAGES_ONLY=1)"
    exit 0
fi

# ── 7. Install mesh VPN (headscale + tailscale) — same as every sibling ─────
if ${SKIP_MESH}; then
    banner "SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Installing mesh VPN (headscale + tailscale, arm64)"
    # Pinned versions + publisher checksum verification (headscale checksums.txt /
    # tailscale <tgz>.sha256): ABORT on any sha256 mismatch so a tampered binary
    # cannot reach the mesh runlevel. file(1) ELF-arch check kept as defense-in-depth.
    HS_REL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}"
    HS_URL="${HS_REL}/headscale_${HEADSCALE_VERSION}_linux_arm64"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
    # Fetch failure is FATAL (mirrors every sibling): the image bakes mesh
    # plumbing and this is the only place the binary is staged — a network
    # blip must NOT silently ship a mesh-less image. Opt out explicitly with
    # --skip-mesh.
    if ! curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors -o "${HS_BIN}" "${HS_URL}"; then
        err "headscale ${HEADSCALE_VERSION} fetch failed (${HS_URL}) — the image bakes the mesh; aborting (use --skip-mesh to opt out)."; exit 1
    fi
    HS_SUMS="${BUILD_ROOT}/headscale_${HEADSCALE_VERSION}_checksums.txt"
    if ! dlv_fetch "${HS_REL}/checksums.txt" "${HS_SUMS}" \
       || ! dlv_verify_from_sumsfile "${HS_BIN}" "headscale_${HEADSCALE_VERSION}_linux_arm64" "${HS_SUMS}" sha256; then
        rm -f "${HS_BIN}"
        err "headscale ${HEADSCALE_VERSION} checksum verification FAILED — refusing to ship an unverified control-plane binary."; exit 1
    fi
    chmod +x "${HS_BIN}"
    file "${HS_BIN}" | grep -q 'ELF.*aarch64' || { err "headscale binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
    info "headscale installed + sha256-verified: /usr/bin/headscale"
    if ${SKIP_TAILSCALE}; then
        info "Skipping tailscale client (--skip-tailscale)"
    else
        TS_URL="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        TS_TGZ="${BUILD_ROOT}/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        # Fetch failure is FATAL: tailscaled is enabled in the default runlevel, so a
        # missing binary = a dead service on a mesh-less node. Opt out with
        # --skip-tailscale (or --skip-mesh).
        if ! curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors -o "${TS_TGZ}" "${TS_URL}"; then
            err "tailscale ${TAILSCALE_VERSION} fetch failed (${TS_URL}) — tailscaled is enabled in the runlevel; aborting (use --skip-tailscale to opt out)."; exit 1
        fi
        TS_SHA="${TS_TGZ}.sha256"
        if ! dlv_fetch "${TS_URL}.sha256" "${TS_SHA}" \
           || ! dlv_verify_sha256_sidecar "${TS_TGZ}" "${TS_SHA}"; then
            rm -f "${TS_TGZ}"
            err "tailscale ${TAILSCALE_VERSION} checksum verification FAILED — refusing to ship an unverified mesh client."; exit 1
        fi
        TS_TMP="$(mktemp -d)"
        tar -C "${TS_TMP}" -xzf "${TS_TGZ}"
        TS_SUB="$(find "${TS_TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
        install -Dm0755 "${TS_SUB}/tailscale"  "${SYSROOT}/usr/bin/tailscale"
        install -Dm0755 "${TS_SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
        rm -rf "${TS_TMP}"
        # Both binaries MUST be aarch64 (mirrors every sibling) — only after this
        # is the tailscaled runlevel link backed by a real, correct-arch binary.
        file "${SYSROOT}/usr/bin/tailscale"   | grep -q 'ELF.*aarch64' || { err "tailscale binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
        file "${SYSROOT}/usr/sbin/tailscaled" | grep -q 'ELF.*aarch64' || { err "tailscaled binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
        info "tailscale installed + sha256-verified: /usr/bin/tailscale, /usr/sbin/tailscaled"
    fi
fi

fi  # IMAGE_ONLY skip of Phase 1+2

# ── 8. Cross-compile the kernel (mainline; ship the Allwinner DTB) ──
# OPI3LTS_KVER is captured here (from `make kernelrelease`) so Phase 4 can point
# dracut --kver at the EXACT module tree this build installs under
# ${SYSROOT}/lib/modules/. Empty if the kernel is skipped/unbuilt.
OPI3LTS_KVER=""
if ${SKIP_KERNEL}; then
    banner "SKIPPED kernel (--skip-kernel)"
else
    banner "Building hardened kernel (cross-compiled)"
    KERNEL_SRC=$(find "${SYSROOT}/usr/src/" -maxdepth 1 -name 'linux-*' -type d 2>/dev/null | sort -V | tail -1)
    if [ -z "${KERNEL_SRC}" ]; then
        # No source tree despite the completeness gate proving gentoo-sources is
        # in the vdb (or the gate being bypassed). ONE legitimate shape: a
        # --resume onto a sysroot whose clean phase already removed /usr/src/*
        # but whose /boot still carries the previously-built kernel — reuse it.
        # Anything else used to warn-skip here and exit 0 with an UNBOOTABLE
        # kernel-less artifact (LIVE silently skipped, stage4-only output).
        if [ -f "${SYSROOT}/boot/${OPI3LTS_KERNEL_IMG}" ]; then
            warn "No kernel source tree under ${SYSROOT}/usr/src — but a previously-built kernel"
            warn "exists at /boot/${OPI3LTS_KERNEL_IMG} (cleaned --resume sysroot); reusing it."
        else
            err "No kernel source tree under ${SYSROOT}/usr/src AND no previously-built kernel at"
            err "${SYSROOT}/boot/${OPI3LTS_KERNEL_IMG} — nothing to boot; refusing to continue toward"
            err "a kernel-less artifact. (sys-kernel/gentoo-sources must merge, or pass"
            err "--skip-kernel to a sysroot that already carries a kernel.)"
            exit 1
        fi
    else
        info "Building kernel from ${KERNEL_SRC} (defconfig: ${OPI3LTS_DEFCONFIG}, CPU: ${OPI3LTS_CPU})"
        pushd "${KERNEL_SRC}" >/dev/null
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" "${OPI3LTS_DEFCONFIG}"
        # merge_config.sh properly handles Kconfig dependency resolution when
        # adding options absent from the base defconfig (unlike scripts/config +
        # olddefconfig which silently drops symbols whose selections/selects
        # haven't been evaluated yet in the defconfig ordering).
        ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" \
            bash scripts/kconfig/merge_config.sh -m .config "${SPECS_DIR}/kernel/hardened-appliance.config"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" olddefconfig
        # Refuse to ship a kernel that silently lost SELinux (fleet posture guard).
        for must in CONFIG_SECURITY_SELINUX CONFIG_SECURITY_SELINUX_BOOTPARAM; do
            grep -q "^${must}=y" .config || { err "SELinux kernel option ${must} not enabled after olddefconfig"; exit 1; }
        done
        grep -q '^CONFIG_LSM="yama,selinux,bpf"$' .config || { err "CONFIG_LSM malformed (expected yama,selinux,bpf)"; exit 1; }
        # Refuse to ship a kernel that silently lost LUKS2/dm-crypt support for
        # --encrypt-root builds (CONFIG_MD/BLK_DEV_DM/DM_CRYPT depend on each other
        # transitively — a --defconfig override lacking CONFIG_MD would otherwise
        # drop them with no build-time signal, producing an unbootable/non-
        # unlocking encrypted root only discoverable on real hardware).
        if ${ENCRYPT_ROOT}; then
            for must in CONFIG_MD CONFIG_BLK_DEV_DM CONFIG_DM_CRYPT; do
                grep -q "^${must}=y" .config || { err "--encrypt-root requires ${must}=y but it did not survive olddefconfig (check --defconfig)"; exit 1; }
            done
        fi
        # Refuse to ship a kernel that grew DRM/framebuffer config — this
        # platform is HEADLESS-ONLY BY DESIGN (see the builder header); a
        # future --defconfig override or a stray CONFIG_PROTECT-restored
        # fragment silently re-enabling CONFIG_DRM would contradict the
        # explicit architecture decision documented above and in
        # specs-orangepi3-lts/README.md, so this is a hard build-time guard,
        # not just a comment.
        for must_not in CONFIG_DRM CONFIG_FRAMEBUFFER_CONSOLE; do
            if grep -q "^${must_not}=y" .config; then
                err "${must_not}=y is set but this platform is HEADLESS-ONLY (a deliberate scope decision — see specs-orangepi3-lts/README.md). Refusing to ship a kernel that silently grew display config; check --defconfig / any local fragment overrides."
                exit 1
            fi
        done
        # The kernelrelease string is the module-tree dir name (lib/modules/<kver>),
        # which dracut needs as --kver for the live initramfs.
        OPI3LTS_KVER="$(make -s ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" kernelrelease 2>/dev/null | tail -1)"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" -j"${JOBS}" Image modules dtbs
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" INSTALL_MOD_PATH="${SYSROOT}" modules_install
        mkdir -p "${SYSROOT}/boot/dtb/allwinner"
        cp arch/arm64/boot/Image "${SYSROOT}/boot/${OPI3LTS_KERNEL_IMG}"
        # Ship the FULL Allwinner DTB tree (the board DTB is selected by extlinux's
        # FDT line).
        cp -r arch/arm64/boot/dts/allwinner "${SYSROOT}/boot/dtb/" 2>/dev/null || \
            cp arch/arm64/boot/dts/allwinner/*.dtb "${SYSROOT}/boot/dtb/allwinner/" 2>/dev/null || true
        # The board FDT is MANDATORY: extlinux's FDT line points at it and the
        # board will NOT boot without it. We just built the kernel, so a missing
        # DTB is a hard error, not a warning.
        if [ ! -f "${SYSROOT}/boot/dtb/${OPI3LTS_DTB}" ]; then
            err "Selected DTB ${OPI3LTS_DTB} not found under ${SYSROOT}/boot/dtb after the kernel build — the board would not boot. Verify the in-tree DTB name for this kernel (Allwinner devicetree naming has moved before — see specs-orangepi3-lts/README.md)."
            exit 1
        fi
        popd >/dev/null
        info "Kernel build complete (Image + Allwinner DTBs staged under /boot)."
    fi
fi

# ── 9. U-Boot for the board (NO proprietary blob needed — see the header) ──
if ${SKIP_UBOOT}; then
    banner "SKIPPED bootloader (--skip-uboot)"
else
    banner "Staging bootloader (u-boot ${OPI3LTS_UBOOT_DEFCONFIG})"
    mkdir -p "${STAGE_DIR}/uboot"
    if [ -n "${OPI3LTS_UBOOT_URL}" ]; then
        if curl -fL -o "${STAGE_DIR}/uboot/u-boot.bin" "${OPI3LTS_UBOOT_URL}"; then
            info "u-boot staged from ${OPI3LTS_UBOOT_URL} -> ${STAGE_DIR}/uboot/u-boot.bin"
        else
            warn "Could not fetch u-boot from ${OPI3LTS_UBOOT_URL}; image will have no bootloader staged."
        fi
    else
        warn "No --uboot-url given. UNLIKE every other arm64 platform in this repo, this"
        warn "board's mainline U-Boot needs NO proprietary blob at all (a genuinely native,"
        warn "native H6 LPDDR3 DRAM-init driver — see the header). A real"
        warn "from-source build ('make ${OPI3LTS_UBOOT_DEFCONFIG}' against mainline U-Boot) is"
        warn "realistic here but not attempted by this builder (no hardware to validate"
        warn "against in this environment — see specs-orangepi3-lts/README.md). Provide a"
        warn "prebuilt u-boot.bin via --uboot-url, or drop one into ${STAGE_DIR}/uboot/"
        warn "before flashing."
    fi
fi

if ${SKIP_CLEAN}; then
    banner "SKIPPED sysroot clean (--skip-clean)"
else
    banner "Cleaning sysroot"
    rm -rf "${SYSROOT}"/usr/share/doc/* "${SYSROOT}"/usr/share/man/* \
           "${SYSROOT}"/usr/share/info/* "${SYSROOT}"/usr/src/* \
           "${SYSROOT}"/var/cache/distfiles/* "${SYSROOT}"/var/tmp/* "${SYSROOT}"/tmp/*
    find "${SYSROOT}"/{usr/bin,usr/sbin,usr/lib64,lib64} -type f -executable 2>/dev/null | while read -r f; do
        file "$f" | grep -q 'ELF.*aarch64' && "${CROSS_TARGET}-strip" --strip-unneeded "$f" 2>/dev/null || true
    done
    info "Sysroot cleaned and binaries stripped."
fi

banner "Staging the boot tree"
BOOT_STAGE="${STAGE_DIR}/boot"
rm -rf "${BOOT_STAGE}"; mkdir -p "${BOOT_STAGE}/extlinux" "${BOOT_STAGE}/dtb"
APPEND_BASE="$(cat "${SPECS_DIR}/boot/cmdline.base")"
if [ -f "${SYSROOT}/boot/${OPI3LTS_KERNEL_IMG}" ]; then
    cp "${SYSROOT}/boot/${OPI3LTS_KERNEL_IMG}" "${BOOT_STAGE}/"
    cp -r "${SYSROOT}/boot/dtb/." "${BOOT_STAGE}/dtb/" 2>/dev/null || true
else
    # Kernel-less at boot staging with the kernel phase ENABLED means Phase 3
    # was supposed to stage /boot/${OPI3LTS_KERNEL_IMG} this run and did not —
    # everything downstream (extlinux, LIVE, INSTALLER) is dead weight. Only
    # --skip-kernel makes a kernel-less boot tree a deliberate operator choice
    # (stage4-tarball-only build).
    if ${SKIP_KERNEL}; then
        warn "Kernel ${OPI3LTS_KERNEL_IMG} not in sysroot (--skip-kernel) — the boot tree will be incomplete."
    else
        err "Kernel ${OPI3LTS_KERNEL_IMG} not in sysroot after the kernel phase — the boot tree"
        err "would be incomplete and every bootable artifact dead. Review Phase 3 above."
        exit 1
    fi
fi

# ── 11b. Build the LIVE dmsquash-live initramfs (mirrors build-frite-stage4.sh
# / build-orangepi5-stage4.sh) ─────────────────────────────────────────────
# WHY: the LIVE flavor's cmdline uses dracut directives — root=live:/rd.live.*.
# Those are interpreted by a dracut dmsquash-live initramfs, NOT by a bare
# kernel. Without an INITRD the kernel would never find/mount the squashfs as
# the ephemeral overlay root and the LIVE image would be UNBOOTABLE. So for the
# LIVE flavor we GENERATE a real initramfs here (dmsquash-live module) and
# stage it next to the kernel; the extlinux render then emits the matching
# `INITRD /initrd.img` line. The INSTALLER flavor's DISK-boot tree boots a real
# partitioned root and gets NO live initramfs UNLESS --encrypt-root (see
# build_disk_initramfs below) — see build_installer_iso.
#
# Cross-build note (NEEDS-HARDWARE to fully confirm): dracut is a POSIX-sh/python
# generator, so we run it as a HOST tool pointed at the aarch64 SYSROOT's module
# tree (the tools it packs INTO the initramfs are the target's own aarch64
# binaries, which is correct). We prefer the sysroot's own dracut script, falling
# back to a host dracut with --kmoddir. This is structurally validated here
# (bash -n, arg shape) but the actual cross-generated initramfs can only be
# proven to boot on a real Orange Pi 3 LTS board with a full Gentoo cross-build.
OPI3LTS_LIVE_INITRD=""        # set non-empty once the live initramfs is staged
build_live_initramfs() {
    [ -f "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" ] || {
        warn "no kernel in boot stage — cannot build the live initramfs; LIVE image will NOT boot."
        return 1; }
    # Resolve the kernel module dir to target. Prefer the captured kernelrelease;
    # otherwise fall back to the single module tree modules_install just created.
    local kver="${OPI3LTS_KVER}"
    if [ -z "${kver}" ] || [ ! -d "${SYSROOT}/lib/modules/${kver}" ]; then
        kver="$(find "${SYSROOT}/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
    fi
    [ -n "${kver}" ] && [ -d "${SYSROOT}/lib/modules/${kver}" ] || {
        warn "no module tree under ${SYSROOT}/lib/modules — cannot build the live initramfs; LIVE image will NOT boot."
        return 1; }

    local out="${BOOT_STAGE}/initrd.img"
    local mods="dmsquash-live base udev-rules rootfs-block"
    info "Generating live initramfs (dracut dmsquash-live, kver=${kver}) ..."

    local sysroot_dracut="${SYSROOT}/usr/bin/dracut"

    # Ensure qemu-aarch64 is registered in binfmt_misc (idempotent, non-fatal;
    # kernel-global, so it must be (re)done at run time — see _dracut-cross-lib.sh).
    dracut_cross_register_qemu || true

    # ── Strategy 1: qemu-chroot (correct for cross-builds) ─────────────────────
    # binfmt_misc + qemu-aarch64 lets us chroot into the aarch64 sysroot and run
    # dracut natively — the result is a correct aarch64 initramfs without a real
    # board. Requires qemu-user registered in binfmt_misc for aarch64.
    local _qemu_interp
    _qemu_interp="$(grep '^interpreter' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null | awk '{print $2}')"
    if [ -n "${_qemu_interp}" ] && [ -x "${_qemu_interp}" ] && [ -x "${sysroot_dracut}" ]; then
        local _mounts=() _qemu_staged=false
        _opiz2_umount() {
            local m
            for m in "${_mounts[@]}"; do umount -l "${m}" 2>/dev/null || true; done
            # Remove the host qemu binary we staged inside the sysroot (if any).
            ${_qemu_staged} && rm -f "${SYSROOT}${_qemu_interp}" 2>/dev/null || true
        }
        trap '_opiz2_umount' RETURN
        mkdir -p "${SYSROOT}/proc" "${SYSROOT}/sys" "${SYSROOT}/dev"
        mount --bind /proc "${SYSROOT}/proc" && _mounts+=("${SYSROOT}/proc") || true
        mount --bind /sys  "${SYSROOT}/sys"  && _mounts+=("${SYSROOT}/sys")  || true
        mount --bind /dev  "${SYSROOT}/dev"  && _mounts+=("${SYSROOT}/dev")  || true
        # The kernel resolves the binfmt_misc interpreter RELATIVE TO THE CHROOT ROOT.
        # dracut is a bash script → kernel execs aarch64 /bin/bash → binfmt_misc
        # intercepts → looks for /usr/bin/qemu-aarch64 INSIDE the sysroot, not on
        # the host. Copy the host static binary in so the kernel can find it.
        mkdir -p "${SYSROOT}$(dirname "${_qemu_interp}")"
        if cp "${_qemu_interp}" "${SYSROOT}${_qemu_interp}" 2>/dev/null; then
            _qemu_staged=true
        else
            warn "Could not stage qemu interpreter into sysroot; chroot may fail."
        fi
        info "Running dracut via qemu-chroot (kver=${kver}) ..."
        _dracut_out="$(chroot "${SYSROOT}" /usr/bin/dracut --force --no-hostonly \
            --kver "${kver}" --modules "${mods}" /boot/initrd.img 2>&1)"
        printf '%s\n' "${_dracut_out}" | head -60
        if [ -s "${SYSROOT}/boot/initrd.img" ]; then
            cp "${SYSROOT}/boot/initrd.img" "${out}"
            OPI3LTS_LIVE_INITRD="${out}"
            _opiz2_umount; trap - RETURN
            info "Live initramfs staged (qemu-chroot): ${out} ($(du -h "${out}" | cut -f1))"
            return 0
        fi
        warn "qemu-chroot dracut did not produce an initramfs; falling back."
        _opiz2_umount; trap - RETURN
    fi

    # ── Strategy 2: run the sysroot dracut script on the host sh ───────────────
    # Dracut is a bash script; running it on the host works only if it doesn't
    # need to exec aarch64 binaries from the sysroot. Usually fails silently.
    if [ -x "${sysroot_dracut}" ] && command -v sh >/dev/null; then
        sh "${sysroot_dracut}" --force --no-hostonly \
            --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            --modules "${mods}" "${out}" 2>/dev/null && [ -s "${out}" ] && {
                OPI3LTS_LIVE_INITRD="${out}"
                info "Live initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce an initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            --modules "${mods}" "${out}" 2>/dev/null && [ -s "${out}" ] && {
                OPI3LTS_LIVE_INITRD="${out}"
                info "Live initramfs staged (host dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
    fi
    warn "Could not generate the live initramfs (no usable dracut). The LIVE image"
    warn "would be UNBOOTABLE without it — ensure sys-kernel/dracut is in the live"
    warn "package set and the kernel module tree exists. (Needs the full cross-build.)"
    return 1
}
# Both bootable flavors need the dmsquash-live initramfs (the INSTALLER medium is
# itself a live boot — see build_installer_iso).
if { ${BUILD_LIVE} || ${BUILD_INSTALLER}; } && { ! ${SKIP_KERNEL} || ${IMAGE_ONLY}; }; then
    build_live_initramfs || warn "Live initramfs not built — see warnings above."
fi

# ── DISK-BOOT initramfs (--encrypt-root only) — unlocks the LUKS2 root ────────
# The installed system boots WITHOUT any initramfs today (bare kernel mounts
# root= directly) — fine for a plaintext root, but a LUKS2 root must be
# unlocked BEFORE mount, which needs an initramfs stage. Reuses the exact same
# cross-build strategies as build_live_initramfs() (same script, same proven
# qemu-chroot/host-sh/host-dracut fallback chain) but non-hostonly with the
# dracut "crypt" module (device-mapper + cryptsetup's crypt hook) instead of
# dmsquash-live — this initramfs is generic (--no-hostonly), NOT the live
# medium's ephemeral squashfs-boot initramfs, and is staged separately so the
# two are never confused. install-orangepi3-lts.sh copies it into place; the
# ACTUAL root=/rd.luks.uuid= cmdline is filled in there too (the LUKS UUID does
# not exist until install-orangepi3-lts.sh formats the target partition).
# Mirrors build-frite-stage4.sh / build-orangepi5-stage4.sh's identical Phase
# 3.5 exactly.
OPI3LTS_DISK_INITRD=""        # set non-empty once the disk-boot initramfs is staged
build_disk_initramfs() {
    [ -f "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" ] || {
        warn "no kernel in boot stage — cannot build the disk-boot initramfs; an --encrypt-root install would NOT boot."
        return 1; }
    local kver="${OPI3LTS_KVER}"
    if [ -z "${kver}" ] || [ ! -d "${SYSROOT}/lib/modules/${kver}" ]; then
        kver="$(find "${SYSROOT}/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
    fi
    [ -n "${kver}" ] && [ -d "${SYSROOT}/lib/modules/${kver}" ] || {
        warn "no module tree under ${SYSROOT}/lib/modules — cannot build the disk-boot initramfs; an --encrypt-root install would NOT boot."
        return 1; }

    local out="${BOOT_STAGE}/disk-initrd.img"
    info "Generating disk-boot initramfs (dracut --add crypt, kver=${kver}) ..."

    local sysroot_dracut="${SYSROOT}/usr/bin/dracut"

    # Ensure qemu-aarch64 is registered in binfmt_misc (idempotent, non-fatal;
    # kernel-global, so it must be (re)done at run time — see _dracut-cross-lib.sh).
    dracut_cross_register_qemu || true

    # ── Strategy 1: qemu-chroot (correct for cross-builds) ─────────────────────
    local _qemu_interp
    _qemu_interp="$(grep '^interpreter' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null | awk '{print $2}')"
    if [ -n "${_qemu_interp}" ] && [ -x "${_qemu_interp}" ] && [ -x "${sysroot_dracut}" ]; then
        local _mounts=() _qemu_staged=false
        _opiz2_disk_umount() {
            local m
            for m in "${_mounts[@]}"; do umount -l "${m}" 2>/dev/null || true; done
            ${_qemu_staged} && rm -f "${SYSROOT}${_qemu_interp}" 2>/dev/null || true
        }
        trap '_opiz2_disk_umount' RETURN
        mkdir -p "${SYSROOT}/proc" "${SYSROOT}/sys" "${SYSROOT}/dev"
        mount --bind /proc "${SYSROOT}/proc" && _mounts+=("${SYSROOT}/proc") || true
        mount --bind /sys  "${SYSROOT}/sys"  && _mounts+=("${SYSROOT}/sys")  || true
        mount --bind /dev  "${SYSROOT}/dev"  && _mounts+=("${SYSROOT}/dev")  || true
        mkdir -p "${SYSROOT}$(dirname "${_qemu_interp}")"
        if cp "${_qemu_interp}" "${SYSROOT}${_qemu_interp}" 2>/dev/null; then
            _qemu_staged=true
        else
            warn "Could not stage qemu interpreter into sysroot; chroot may fail."
        fi
        info "Running dracut via qemu-chroot (kver=${kver}) ..."
        _dracut_out="$(chroot "${SYSROOT}" /usr/bin/dracut --force --no-hostonly \
            --add crypt --kver "${kver}" /boot/disk-initrd.img 2>&1)"
        printf '%s\n' "${_dracut_out}" | head -60
        if [ -s "${SYSROOT}/boot/disk-initrd.img" ]; then
            cp "${SYSROOT}/boot/disk-initrd.img" "${out}"
            OPI3LTS_DISK_INITRD="${out}"
            _opiz2_disk_umount; trap - RETURN
            info "Disk-boot initramfs staged (qemu-chroot): ${out} ($(du -h "${out}" | cut -f1))"
            return 0
        fi
        warn "qemu-chroot dracut did not produce a disk-boot initramfs; falling back."
        _opiz2_disk_umount; trap - RETURN
    fi

    # ── Strategy 2: run the sysroot dracut script on the host sh ───────────────
    if [ -x "${sysroot_dracut}" ] && command -v sh >/dev/null; then
        sh "${sysroot_dracut}" --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                OPI3LTS_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce a disk-boot initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                OPI3LTS_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
    fi
    warn "Could not generate the disk-boot initramfs (no usable dracut). An"
    warn "--encrypt-root install would be UNBOOTABLE without it."
    return 1
}
if ${ENCRYPT_ROOT} && ${BUILD_INSTALLER} && { ! ${SKIP_KERNEL} || ${IMAGE_ONLY}; }; then
    build_disk_initramfs || true
    if [ -z "${OPI3LTS_DISK_INITRD}" ] || [ ! -s "${OPI3LTS_DISK_INITRD}" ]; then
        err "--encrypt-root requires the disk-boot initramfs (see warnings above) — refusing to build a payload that cannot boot an encrypted root."
        exit 1
    fi
fi

# ── BEGIN shared block: SELinux node-policy modules ───────────────────────────
# Compile specs/selinux/*.te into .pp ON THE X86 BUILD HOST and install them into
# ${SYSROOT}/usr/share/selinux/<type>/ — the exact directory provision_selinux()
# already globs at first boot (`semodule -s "${type}" -i /usr/share/selinux/
# "${type}"/*.pp`, specs/etc/keys-provision/provision.sh:2563), so this needs NO
# provision.sh change. NEVER compiled on the target: checkmodule/semodule_package/
# m4 are x86 BUILD-host binaries, the same reason selinux-base builds base.pp here
# and defers only the load. Placed at this point because the sysroot is complete
# (payload emerged, kernel/bootloader staged, both arms of the sysroot clean done)
# and nothing has been packaged or imaged yet.
# The image still boots PERMISSIVE: the enforce-gate service ships INERT (not in
# any runlevel, /etc/conf.d/selinux-enforce-gate SELINUX_ENFORCE_GATE=no) unless
# HUGMESH_SELINUX_ENFORCE_GATE=1 is set at build time. See the lib header for why.
slx_stage_node_policy "${SYSROOT}" "${SHARED_SPECS}" \
    || { err "SELinux node-policy staging failed (see above) — refusing to ship an image whose policy modules did not build."; exit 1; }
# ── END shared block: SELinux node-policy modules ─────────────────────────────

banner "Packaging stage4 tarball"
STAGE4_TARBALL="${WORK_DIR}/${ART_PREFIX}.stage4.tar.xz"
tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner --owner=0 --group=0 \
    --exclude='./usr/src' --exclude='./var/cache' --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" . 2>/dev/null || \
tar -C "${SYSROOT}" --numeric-owner --owner=0 --group=0 \
    --exclude='./usr/src' --exclude='./var/cache' --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" .
info "Stage4 tarball: ${STAGE4_TARBALL} ($(du -sh "${STAGE4_TARBALL}" | cut -f1))"

LIVE_PATH="(not built)"
INSTALLER_PATH="(not built)"

build_live_iso() {
    # The LIVE flavor: a bootable medium (microSD/USB) that runs the rootfs
    # ephemerally from a squashfs in RAM. We stage:
    #   /  Image, /dtb/..., /extlinux/extlinux.conf  (boot tree)
    #   /  LiveOS/squashfs.img                        (the rootfs)
    # U-Boot (SD/USB) + extlinux find squashfs.img and the kernel mounts it
    # read-only with an overlay (kernel has SQUASHFS + OVERLAY_FS + LOOP).
    if ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        warn "mksquashfs/tar2sqfs missing — skipping LIVE image."; return 0
    fi
    if [ ! -f "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" ]; then
        # The LIVE flavor was REQUESTED (we are only called under BUILD_LIVE).
        # Skipping it with exit 0 is exactly the silent-degradation class this
        # file keeps re-shipping: the run ends "complete" with LIVE "(not
        # built)". Only --skip-kernel makes that a deliberate operator choice —
        # the INSTALLER twin of this check (build_installer_iso) already errs.
        ${SKIP_KERNEL} || { err "no kernel in boot stage — the requested LIVE image cannot boot. The kernel phase was enabled; review it above."; exit 1; }
        warn "no kernel in boot stage (--skip-kernel) — skipping LIVE image."; return 0
    fi

    # The LIVE flavor is unbootable without the dmsquash-live initramfs (the
    # cmdline below is all dracut directives). Refuse to package a LIVE image that
    # has no initramfs rather than ship a known-dead boot.
    if [ -z "${OPI3LTS_LIVE_INITRD}" ] || [ ! -s "${OPI3LTS_LIVE_INITRD}" ]; then
        # The LIVE cmdline is ALL dracut directives (root=live:/rd.live.*) — no
        # initramfs means no bootable LIVE medium, period. This used to skip
        # with exit 0 ("LIVE image: (not built)") while the INSTALLER twin of
        # this exact check errs — same posture now, unless --skip-kernel made
        # the whole boot half a deliberate non-goal.
        if ! ${SKIP_KERNEL}; then
            err "No live initramfs was generated (Phase 4 §11b). The requested LIVE image"
            err "would NOT boot (root=live:/rd.live.* need a dracut dmsquash-live initramfs)."
            err "Ensure the dracut cross-generation above succeeded (qemu-user binfmt on the"
            err "build host), or use --flavor installer / --skip-kernel deliberately."
            exit 1
        fi
        warn "No live initramfs was generated (--skip-kernel). Skipping the LIVE image."
        return 0
    fi

    local live_root="${STAGE_DIR}/live"
    rm -rf "${live_root}"; mkdir -p "${live_root}/LiveOS" "${live_root}/extlinux" "${live_root}/dtb"
    cp "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" "${live_root}/"
    cp -r "${BOOT_STAGE}/dtb/." "${live_root}/dtb/" 2>/dev/null || true
    # The board FDT MUST be on the medium — extlinux's FDT line references it and the
    # board will not boot without it. Refuse to package a DTB-less LIVE image.
    [ -f "${live_root}/dtb/${OPI3LTS_DTB}" ] || { err "LIVE image: board DTB ${OPI3LTS_DTB} missing from ${live_root}/dtb — refusing to package a non-booting medium."; exit 1; }
    # Stage the dmsquash-live initramfs next to the kernel (extlinux INITRD line).
    cp "${OPI3LTS_LIVE_INITRD}" "${live_root}/initrd.img"

    info "Squashing the rootfs (LIVE) ..."
    if command -v mksquashfs >/dev/null; then
        mksquashfs "${SYSROOT}" "${live_root}/LiveOS/squashfs.img" \
            -noappend -comp xz -e boot/dtb 2>/dev/null \
            || mksquashfs "${SYSROOT}" "${live_root}/LiveOS/squashfs.img" -noappend
    else
        # squashfs-tools-ng fallback: tar stream with the same boot/dtb exclude.
        tar -C "${SYSROOT}" --numeric-owner --exclude='./boot/dtb' -cpf - . \
            | tar2sqfs -q -c xz -j "${JOBS}" "${live_root}/LiveOS/squashfs.img"
    fi

    # extlinux for the LIVE boot: emit the INITRD line so u-boot loads the
    # dmsquash-live initramfs, which then mounts LiveOS/squashfs.img as the
    # read-only base and stacks a tmpfs overlay = the ephemeral root.
    OPI3LTS_INITRD_LINE="    INITRD /initrd.img"
    OPI3LTS_APPEND="${APPEND_BASE} root=live:LABEL=OPI3LTS_LIVE rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${live_root}/extlinux/extlinux.conf"

    if command -v xorriso >/dev/null; then
        LIVE_PATH="${WORK_DIR}/${ART_PREFIX}.live.iso"
        xorriso -as mkisofs -o "${LIVE_PATH}" -volid OPI3LTS_LIVE -joliet -rock "${live_root}" \
            && info "LIVE image: ${LIVE_PATH} ($(du -sh "${LIVE_PATH}" | cut -f1))" \
            || { warn "xorriso failed; leaving the LIVE tree at ${live_root}"; LIVE_PATH="${live_root} (tree)"; }
    else
        LIVE_PATH="${live_root} (tree; no xorriso to wrap an ISO)"
        warn "no xorriso — LIVE tree left at ${live_root}"
    fi
    # if-form (NOT a trailing &&-chain): the &&-chain returns 1 when COMPRESS_IMG is
    # false (the default), which under `set -e` would abort the script right here —
    # killing the INSTALLER phase and the summary. Return 0 explicitly on success.
    if ${COMPRESS_IMG} && [ -f "${LIVE_PATH}" ]; then
        xz -T0 -9 -f "${LIVE_PATH}"; LIVE_PATH="${LIVE_PATH}.xz"
    fi
    return 0
}

build_installer_iso() {
    # The INSTALLER flavor: a LIVE-booting medium (the operator boots it off
    # microSD/USB, gets a running system, then runs install-orangepi3-lts.sh
    # to write the appliance to microSD/USB — see that script's own header,
    # including the ON-DEVICE LUKS format rationale and the same-device-as-
    # boot-medium handling).
    #
    # WHY THIS IS A LIVE BOOT, not a bare kernel: the medium's extlinux boots
    # ephemerally from a squashfs (exactly like the LIVE flavor) so the
    # installer can actually run; the disk's `root=LABEL=OPI3L_ROOT` cmdline
    # belongs on the PAYLOAD boot tree we stage for install-orangepi3-lts.sh
    # to copy onto the target, NOT on the medium itself (mirrors
    # build-frite-stage4.sh's / build-orangepi5-stage4.sh's build_installer_iso
    # exactly).
    command -v xorriso >/dev/null || { err "xorriso missing — cannot build the INSTALLER ISO. Install xorriso or drop --flavor installer."; exit 1; }
    [ -f "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" ] || { err "no kernel in boot stage — the INSTALLER medium cannot boot. Build the kernel (drop --skip-kernel)."; exit 1; }
    if ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        err "mksquashfs/tar2sqfs missing — cannot build the INSTALLER medium's live rootfs. Install squashfs-tools (or squashfs-tools-ng)."; exit 1
    fi
    # The medium boots root=live:/rd.live.* — those are dracut directives, so the
    # dmsquash-live initramfs is MANDATORY. Refuse to emit a known-dead installer
    # rather than a silent, unbootable one (mirrors the LIVE gate).
    if [ -z "${OPI3LTS_LIVE_INITRD}" ] || [ ! -s "${OPI3LTS_LIVE_INITRD}" ]; then
        err "No live initramfs was generated (Phase 4 §11b). The INSTALLER medium boots"
        err "from a squashfs (root=live:/rd.live.*) and is UNBOOTABLE without a dracut"
        err "dmsquash-live initramfs. Ensure sys-kernel/dracut emerged and the kernel"
        err "module tree exists (do not pass --skip-kernel for the installer flavor)."
        exit 1
    fi

    local inst_root="${STAGE_DIR}/installer"
    rm -rf "${inst_root}"; mkdir -p "${inst_root}"/{LiveOS,extlinux,dtb,stage4,boot,uboot}

    # ── The medium's OWN live boot (kernel + DTB + dmsquash-live initramfs) ──
    cp "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" "${inst_root}/"
    cp -r "${BOOT_STAGE}/dtb/." "${inst_root}/dtb/" 2>/dev/null || true
    [ -f "${inst_root}/dtb/${OPI3LTS_DTB}" ] || { err "INSTALLER medium: board DTB ${OPI3LTS_DTB} missing from ${inst_root}/dtb — refusing to package a non-booting medium."; exit 1; }
    cp "${OPI3LTS_LIVE_INITRD}" "${inst_root}/initrd.img"

    info "Squashing the rootfs (INSTALLER live medium) ..."
    if command -v mksquashfs >/dev/null; then
        mksquashfs "${SYSROOT}" "${inst_root}/LiveOS/squashfs.img" \
            -noappend -comp xz -e boot/dtb 2>/dev/null \
            || mksquashfs "${SYSROOT}" "${inst_root}/LiveOS/squashfs.img" -noappend
    else
        tar -C "${SYSROOT}" --numeric-owner --exclude='./boot/dtb' -cpf - . \
            | tar2sqfs -q -c xz -j "${JOBS}" "${inst_root}/LiveOS/squashfs.img"
    fi
    [ -s "${inst_root}/LiveOS/squashfs.img" ] || { err "INSTALLER medium: squashfs.img was not produced — aborting."; exit 1; }

    # The medium's extlinux boots the squashfs ephemerally (OPI3LTS_INSTALL volid).
    OPI3LTS_INITRD_LINE="    INITRD /initrd.img"
    OPI3LTS_APPEND="${APPEND_BASE} root=live:LABEL=OPI3LTS_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/extlinux/extlinux.conf"

    # ── The INSTALL PAYLOAD that install-orangepi3-lts.sh consumes from its
    # own dir ──────────────────────────────────────────────────────────────
    # install-orangepi3-lts.sh reads ${SCRIPT_DIR}/stage4/*.tar.xz and copies
    # ${SCRIPT_DIR}/boot/ (the DISK boot tree) onto the target's FAT.
    # dmsquash-live mounts the medium at /run/initramfs/live, so the operator
    # runs /run/initramfs/live/install-orangepi3-lts.sh.
    cp "${STAGE4_TARBALL}" "${inst_root}/stage4/"
    # The disk boot tree: kernel + DTB + extlinux with the INSTALLED root cmdline
    # (root=LABEL=OPI3L_ROOT, no live initramfs unless --encrypt-root).
    # install-orangepi3-lts.sh re-points root= at the target's PARTUUID/LUKS
    # UUID after partitioning.
    mkdir -p "${inst_root}/boot/extlinux" "${inst_root}/boot/dtb"
    cp "${BOOT_STAGE}/${OPI3LTS_KERNEL_IMG}" "${inst_root}/boot/"
    cp -r "${BOOT_STAGE}/dtb/." "${inst_root}/boot/dtb/" 2>/dev/null || true
    [ -f "${inst_root}/boot/dtb/${OPI3LTS_DTB}" ] || { err "INSTALLER payload: disk-boot DTB ${OPI3LTS_DTB} missing from ${inst_root}/boot/dtb — the installed system would not boot. Aborting."; exit 1; }
    # --encrypt-root: ship the crypt-capable disk-boot initramfs so
    # install-orangepi3-lts.sh's LUKS branch has something to unlock a LUKS
    # root with. root=LABEL=OPI3L_ROOT stays the baked default either way —
    # install-orangepi3-lts.sh rewrites it to root=/dev/mapper/cryptroot
    # rd.luks.uuid=<uuid> ONLY when it actually formats an encrypted root.
    if ${ENCRYPT_ROOT}; then
        [ -n "${OPI3LTS_DISK_INITRD}" ] && [ -s "${OPI3LTS_DISK_INITRD}" ] || {
            err "--encrypt-root: no disk-boot initramfs was generated (Phase 3.5) — refusing to package an installer that cannot boot an encrypted root."; exit 1; }
        cp "${OPI3LTS_DISK_INITRD}" "${inst_root}/boot/initrd.img"
        OPI3LTS_INITRD_LINE="    INITRD /initrd.img"
    else
        OPI3LTS_INITRD_LINE="    # (installed system boots a real partitioned rootfs)"
    fi
    OPI3LTS_APPEND="${APPEND_BASE} root=LABEL=OPI3L_ROOT"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/boot/extlinux/extlinux.conf"
    cp "${SPECS_DIR}/installer/install-orangepi3-lts.sh" "${inst_root}/install-orangepi3-lts.sh"
    chmod +x "${inst_root}/install-orangepi3-lts.sh"
    [ -f "${STAGE_DIR}/uboot/u-boot.bin" ] && cp "${STAGE_DIR}/uboot/u-boot.bin" "${inst_root}/uboot/" 2>/dev/null || true
    # ── LUKS2 FDE marker + OPTIONAL seeded passphrase for
    # install-orangepi3-lts.sh ── Mirrors every other installer's marker
    # convention exactly.
    if ${ENCRYPT_ROOT}; then
        : > "${inst_root}/encrypt-root"   # marker: installer LUKS2-encrypts the target root
        info "INSTALLER image: encrypt-root marker set (install-orangepi3-lts.sh prompts for the root-unlock passphrase)."
        if [ -n "${LUKS_PASS}" ]; then
            printf '%s' "${LUKS_PASS}" > "${inst_root}/luks-passphrase"; chmod 600 "${inst_root}/luks-passphrase"
            warn "INSTALLER image carries an unattended LUKS passphrase (luks-passphrase, 0600) — anyone with the image can read it. Prefer the interactive install-time prompt."
        fi
    fi

    INSTALLER_PATH="${WORK_DIR}/${ART_PREFIX}.installer.iso"
    xorriso -as mkisofs -o "${INSTALLER_PATH}" -volid OPI3LTS_INSTALL -joliet -rock "${inst_root}" \
        && info "INSTALLER image: ${INSTALLER_PATH} ($(du -sh "${INSTALLER_PATH}" | cut -f1))" \
        || { warn "xorriso failed; leaving the installer tree at ${inst_root}"; INSTALLER_PATH="${inst_root} (tree)"; }
    # if-form (NOT a trailing &&-chain): see build_live_iso — the &&-chain returns 1
    # under the default COMPRESS_IMG=false and would abort the caller under set -e.
    if ${COMPRESS_IMG} && [ -f "${INSTALLER_PATH}" ]; then
        xz -T0 -9 -f "${INSTALLER_PATH}"; INSTALLER_PATH="${INSTALLER_PATH}.xz"
    fi
    return 0
}

if ${BUILD_LIVE}; then
    banner "Building LIVE image (boots-and-runs ephemerally off microSD/USB)"
    build_live_iso
fi
if ${BUILD_INSTALLER}; then
    banner "Building INSTALLER image (writes the appliance to microSD/USB)"
    build_installer_iso
fi

echo ""
echo -e "${CYAN}${BOLD}=============================================="
echo "  Orange Pi 3 LTS — Headless Appliance Complete (EXPERIMENTAL)"
echo "==============================================${RESET}"
echo ""
echo -e "${YELLOW}  EXPERIMENTAL: never booted on real hardware from this repo.${RESET}"
echo "  See specs-orangepi3-lts/README.md before trusting this image."
echo ""
echo "  Board:            Orange Pi 3 LTS (Allwinner H6, quad Cortex-A53)"
echo "  DTB:              ${OPI3LTS_DTB}"
echo "  u-boot defconfig: ${OPI3LTS_UBOOT_DEFCONFIG}  (NO proprietary blob needed — a project first)"
echo "  Role:             ${ROLE}  — HEADLESS APPLIANCE (no display, ever; see the header)"
echo "  Flavor:           ${OPI3LTS_FLAVOR}"
echo "  ENV:              ${ENV}   (cluster domain: ${CLUSTER_DOMAIN})"
echo "  Brand:            ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}"
echo "  Hostname:         ${HOSTNAME}"
echo "  Standalone:       ${STANDALONE}   Encrypt-root (LUKS2): ${ENCRYPT_ROOT}"
echo ""
echo "  Mesh + provisioning (SAME as every other client image):"
echo "    - headscale ${HEADSCALE_VERSION} + tailscale ${TAILSCALE_VERSION} (joins the fleet tailnet)"
echo "    - First-boot KEYS-USB provisioning (users, ssh keys, Casdoor login, certs)"
echo "    - Hardened sshd: key-only, prohibit-password (NO broad SSH baked in;"
echo "      device-license registry enforced via per-node principals)"
echo ""
echo "  Artifacts:"
echo "    Work directory:   ${WORK_DIR}"
echo "    Stage4 tarball:   ${STAGE4_TARBALL}"
echo "    LIVE image:       ${LIVE_PATH}"
echo "    INSTALLER image:  ${INSTALLER_PATH}"
echo ""
echo "  === Post-build ==="
echo "  LIVE:      write ${LIVE_PATH##*/} to a microSD card/USB stick and boot."
echo "  INSTALLER: write ${INSTALLER_PATH##*/} to microSD/USB and boot it (it boots LIVE"
echo "             off the squashfs); the medium auto-mounts at /run/initramfs/live, then run"
echo "               sudo /run/initramfs/live/install-orangepi3-lts.sh /dev/mmcblk0"
echo "             to write the appliance to a microSD card (the SAME one it booted from, or"
echo "             a second card/stick — see install-orangepi3-lts.sh's header)."
echo "  u-boot:    this board needs NO proprietary blob (unlike every other arm64 platform"
echo "             in this repo) — provide a prebuilt image via --uboot-url, or (a realistic"
echo "             future option) cross-build mainline U-Boot from source yourself."
echo ""
