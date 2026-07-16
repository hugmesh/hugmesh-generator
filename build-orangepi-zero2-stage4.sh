#!/usr/bin/env bash
# Build a hardened Gentoo aarch64 HEADLESS APPLIANCE image for the Orange Pi
# Zero 2 (Allwinner H616) using the same crossdev toolchain + shared mesh/
# provisioning plumbing as the Frite/Pi5/Orange-Pi-5/x86 client images.
#
# ── EXPERIMENTAL PLATFORM — READ THIS FIRST (see specs-orangepi-zero2/README.md) ──
# No physical Orange Pi Zero 2 has ever booted an image from this repo. Every
# H616-specific fact below (boot chain, DTB/U-Boot-defconfig names, driver
# maturity) is RESEARCHED (direct fetch of live mainline Linux/U-Boot upstream
# source trees, not just secondary claims about them), NOT hardware-verified in
# this environment — there is no H616 hardware, and this sandbox may also lack
# the network access needed for a real cross-emerge (check before assuming
# otherwise). Treat this with the SAME EXPERIMENTAL posture
# build-jetson-stage4.sh / build-orangepi5-stage4.sh carry: buildable and
# internally consistent (--print-plan clean across the whole flag matrix), NOT
# proven to boot.
#
# ── WHY HEADLESS-ONLY — NOT a desktop role, ever (read this before "fixing" it) ──
# The board DOES have a physical Micro-HDMI 2.0a port — this is NOT a
# "no video hardware" situation. But mainline Linux has ZERO display-driver
# support for the H616's display engine (DE33): drivers/gpu/drm/sun4i/ ships no
# DE33/H616-capable driver (only the older sun8i_mixer.c-class DE2/DE3
# hardware), and sun50i-h616.dtsi has NO &hdmi/&tcon/mixer/display-engine nodes
# at all (confirmed by fetching the live upstream tree at research time — the
# out-of-tree DE33 mixer/CSC/plane patch series was still mid-review, "second
# series out of tree", as of a Nov-2025-dated post, with the REMAINING patches
# for a full display pipeline explicitly described as "will be sent once this
# series is merged"). The only place working HDMI exists is Allwinner's own
# never-upstreamed legacy-BSP kernel fork (a WHOLE alternate kernel tree, not
# just an extra firmware blob), or an Armbian community backport of that
# out-of-tree patch series onto their own sunxi-6.12 kernel — whose most recent
# activity (as of the research behind this file) was a BOOT FREEZE regression
# on this EXACT board (Orange Pi Zero 2/Zero 3), a GPU-power-domain hang, and a
# follow-up bugfix PR whose fix was to REMOVE the incomplete patch, not to
# stabilize it. Carrying an entire alternate out-of-tree kernel just for one
# board's display would be a materially heavier, more fragile commitment than
# every other platform in this repo requires (even Orange Pi 5's HDMI, gated
# behind "kernel must be >= 6.13", and Frite's Amlogic FIP/BL31, are each just
# ONE proprietary blob dropped into an otherwise-mainline build — not a whole
# alternate kernel). If mainline ever lands full DE33 display support, this
# scope decision should be REVISITED (see specs-orangepi-zero2/README.md) — do
# not silently keep building headless out of habit once that changes.
#
# So: this image ships NO X11/desktop package, NO GPU/DRM kernel config, NO
# framebuffer console beyond the serial UART — see
# specs-orangepi-zero2/kernel/hardened-appliance.config's header for the exact
# same reasoning restated at the point a future contributor is most likely to
# be tempted to copy-paste GPU config in from another platform's fragment.
#
# WHY a separate builder (not a flag on another platform's script): a
# different SoC vendor generation (Allwinner H616, not Amlogic GXL/Rockchip
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
# ── BOOT CHAIN — a genuine project FIRST: no proprietary blob at all ──────────
# Rockchip (Orange Pi 5) needs rkbin's DDR-init + TF-A BL31 blobs. Amlogic
# (Frite) needs a FIP/BL31 blob. Every OTHER arm64 platform in this repo needs
# AT LEAST ONE proprietary boot blob. The H616 does NOT: mainline U-Boot ships
# a GENUINELY NATIVE, community-reverse-engineered DRAM-init driver for this
# exact SoC (configs/orangepi_zero2_defconfig selects CONFIG_SUNXI_DRAM_H616_*
# training parameters — CONFIRMED by fetching that defconfig from the live
# upstream U-Boot tree; no closed "boot0" blob is loaded or required at any
# stage). Combined with a genuinely open RTL8211F Gigabit Ethernet PHY (also
# fully mainline, drivers/net/phy/realtek/), this is the FIRST platform in this
# repo with a completely blob-free boot+network chain. WiFi (Unisoc UWE5622 in
# an Allwinner "AW859A" module) is the one rough edge here — CONFIRMED no
# mainline kernel.org driver exists for it at all — but this appliance is
# Ethernet-first by design, so that gap does not block anything this image does.
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
#   installer — a LIVE image that ALSO carries install-orangepi-zero2.sh + the
#               stage4, to write the appliance to a microSD card/USB stick
#               (the SAME one it booted from, or a second one — see the
#               installer's own header; this board has NO eMMC and NO NVMe/
#               PCIe at all, so microSD/USB is the ONLY persistent storage
#               class). The default below builds BOTH (--flavor both).
#
# ── ON-DEVICE LUKS FORMAT MODEL (mirrors Frite/Orange-Pi-5, NOT RPi5/Jetson) ──
# install-orangepi-zero2.sh runs FROM WITHIN the booted LIVE/INSTALLER session,
# ON THE ACTUAL Orange Pi Zero 2 board that will later unlock the root at
# every boot — because this board's boot chain (U-Boot + extlinux distro-boot
# scanning a microSD/USB stick directly) makes the produced image genuinely
# bootable on real hardware, unlike RPi5's installer ISO (explicitly documented
# as NOT bootable on the Pi 5 itself). Because format-time and unlock-time
# hardware are the SAME machine here, cryptsetup's argon2id PBKDF
# auto-benchmark is TRUSTWORTHY and install-orangepi-zero2.sh deliberately does
# NOT pin --pbkdf-memory/--iter-time/--pbkdf-parallel (unlike install.sh (RPi5)
# / build-jetson-stage4.sh, which must pin those params because their
# format-host != their unlock-host). This is the SAME genuine architectural
# judgment call Orange Pi 5's Phase 7 made for the same underlying reason (a
# live+installer image that boots on the board itself) — see
# specs-orangepi-zero2/README.md if it ever needs revisiting. The SECOND
# hard-won LUKS lesson (rd.luks.uuid= MUST pair with rd.luks.name=<uuid>=
# cryptroot, or root=/dev/mapper/cryptroot never resolves) is applied in
# install-orangepi-zero2.sh exactly like every other platform's installer.
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
#   in-tree H616 DTB name still matches whatever gentoo-sources version is
#   checked out; the cross-generated dmsquash-live initramfs actually mounting
#   the squashfs and booting on a real board; the microSD/USB install; whether
#   the mainline U-Boot DRAM-init training parameters in orangepi_zero2_defconfig
#   are still correct for every RAM SKU (512MB/1GB/1.5GB/2GB DDR3) this board
#   ships in. These steps MIRROR the proven Frite/Orange-Pi-5 flow but cannot be
#   end-to-end tested here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-orangepi-zero2"   # aarch64/Orange-Pi-Zero-2-specific specs
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
# shellcheck source=scripts/_dracut-cross-lib.sh
source "${SCRIPT_DIR}/scripts/_dracut-cross-lib.sh"

WORK_DIR=""
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-orangepizero2}"   # per-arch isolation (never shares another sysroot)
CROSS_TARGET="aarch64-unknown-linux-gnu"
REL_VERSION="2026.0"

# ── Board values (NO --board axis: this is ONE specific board, unlike Frite's
# 3-board / Orange Pi 5's 2-board tables) — overridable directly via
# --cpu/--dtb/--defconfig/--uboot-defconfig for the rare case a fork of this
# board needs a different value, exactly like every other platform's escape
# hatch. ─────────────────────────────────────────────────────────────────────
OPIZ2_CPU="cortex-a53"                              # H616: quad Cortex-A53, no big.LITTLE split
OPIZ2_DEFCONFIG="defconfig"                         # generic arm64 mainline kernel defconfig
OPIZ2_KERNEL_IMG="Image"
# DTB path CONFIRMED against upstream arch/arm64/boot/dts/allwinner/ (the file
# is sun50i-h616-orangepi-zero2.dts, including sun50i-h616-orangepi-zero.dtsi +
# sun50i-h616-cpu-opp.dtsi).
OPIZ2_DTB="allwinner/sun50i-h616-orangepi-zero2.dtb"
# U-Boot defconfig CONFIRMED against upstream U-Boot configs/ (contains native
# CONFIG_DRAM_SUNXI_*/CONFIG_SUNXI_DRAM_H616_DDR3_1333 DRAM-training parameters
# — no blob reference of any kind; see the header's "boot chain" note).
OPIZ2_UBOOT_DEFCONFIG="orangepi_zero2_defconfig"

JOBS="$(nproc)"
SKIP_KERNEL=false
SKIP_CLEAN=false
RESUME=false
IMAGE_ONLY=false          # skip Phase 1-3 entirely; go straight to Phase 4 image assembly

# ── Image flavors (the LIVE / INSTALLER toggle) ────────────────────
# both (DEFAULT) = produce the LIVE squashfs image AND the INSTALLER image.
OPIZ2_FLAVOR="both"                             # live | installer | both
ROOT_MiB=2048                                   # ext4 root size for the installer's persistent build (lean appliance, no desktop payload)
GROW_POLICY="fill"
COMPRESS_IMG=false
EXTRA_PACKAGES=""
PACKAGES_ADD=""          # --packages-add : atoms to add on top of the derived set
PACKAGES_DROP=""         # --packages-drop: default-set atoms to remove (mandatory floor honored)
TIMEZONE="UTC"
HOSTNAME=""
ROLE="appliance"                                # this image's role marker — a HEADLESS APPLIANCE, never "desktop"
CLUSTER_DOMAIN="snapdragon.systems"
# Orchestration superdomain (WS-SUPER-B): the mesh control plane's MagicDNS suffix every
# node joins. "" = builder default (legacy byte-identical). The Studio emits --superdomain
# <effective> only for MESH builds; permanently internal, never the go-live apex.
SUPERDOMAIN=""
BRAND="snapdragon"
BRAND_TITLE="Snapdragon Systems"
ORG="Snapdragon-Systems"
# ENV (test|prod) selector — kept for parity with the cluster builders (it
# shapes the same branding/creds knobs), BUT this image is a LEAN HEADLESS
# APPLIANCE, NOT a K8s cluster node: it bakes NO specs/cluster GitOps tree and
# therefore has NO installed-services ConfigMap, NO optional-services gate, NO
# public ingress. Mirrors build-frite-stage4.sh / build-orangepi5-stage4.sh's
# identical ENV rationale.
ENV="test"
CONFIG_FILE=""
DEFAULT_USER="orangepizero2"
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
# INSTALLED root is LUKS2 full-disk encrypted — install-orangepi-zero2.sh does
# the actual partition/format/unlock at install time, never baked into the
# build artifact. See docs/STANDALONE-DESKTOP.md.
STANDALONE=false        # --standalone : local user, no mesh, LUKS2 FDE on install
LOCAL_USER=""           # --local-user NAME : the standalone local login account
LOCAL_USER_PASS=""      # --local-pass PASS : plaintext; hashed at build, never baked raw
ENCRYPT_ROOT=false      # --encrypt-root : installer LUKS2-encrypts the target root; auto-on for --standalone
LUKS_PASS=""            # --luks-pass : OPTIONAL unattended passphrase (lands on the installer ISO — warned)

# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ──────────
# The board's ONBOARD radio (a Unisoc UWE5622 die in an Allwinner "AW859A"
# WiFi+BT module) has NO mainline kernel.org driver at all — not even a rough
# one (CONFIRMED; a stronger gap than Orange Pi 5's AP6275P, which at least has
# an upstream brcmfmac-class driver with known rough edges). No onboard-radio
# kernel module is even built here (see kernel/hardened-appliance.config) — the
# flags below only matter if a USB WiFi/Bluetooth dongle with its OWN
# already-mainlined driver is attached (harden_radios() blacklists the generic
# cfg80211/mac80211/bluetooth/btusb modules regardless, same posture as every
# other platform). Ethernet + the tailnet are this appliance's primary,
# reliable network path.
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
# against. See specs-orangepi-zero2/README.md.
OPIZ2_UBOOT_URL="${OPIZ2_UBOOT_URL:-}"          # optional: prebuilt board u-boot.bin URL
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
    build-orangepi-zero2-stage4.sh - Build a hardened Gentoo aarch64 HEADLESS
    APPLIANCE image for the Orange Pi Zero 2 (Allwinner H616), with LIVE +
    INSTALLER flavors, joined to the Snapdragon Tailscale mesh.
    EXPERIMENTAL — hardware validation pending (see specs-orangepi-zero2/README.md).

SYNOPSIS
    build-orangepi-zero2-stage4.sh [OPTIONS]

DESCRIPTION
    Cross-compiles a lean, hardened, HEADLESS Gentoo appliance (SSH-only — NO
    X11/desktop package, NO GPU/DRM kernel config; see the header for WHY: the
    H616's display engine has zero mainline driver support) for the Orange Pi
    Zero 2, reusing the aarch64 cross path and the SHARED mesh + KEYS-USB
    provisioning engine. The image joins headscale/tailscale and honors the
    hardened, key-only SSH posture exactly like the Frite/Pi5/Orange-Pi-5/x86
    client images. This platform has ONE role (a headless appliance) — there is
    no --role axis with cluster-node choices, and no --board axis (one board).

OPTIONS
  Board (overrides — this is ONE board, not a table; see the header)
    -c, --cpu CPU        GCC -mcpu/-mtune (default cortex-a53).
    -d, --defconfig N    Kernel base defconfig (default: defconfig, mainline arm64).
    --dtb PATH           Override the in-tree DTB (default
                         allwinner/sun50i-h616-orangepi-zero2.dtb).
    --uboot-defconfig N  U-Boot defconfig (default orangepi_zero2_defconfig).
    --uboot-url URL      Prebuilt board u-boot.bin to vendor into the image
                         (OPTIONAL here — unlike every other arm64 platform in
                         this repo, this board's mainline U-Boot needs NO
                         proprietary blob; see the header).
    --skip-uboot         Do not fetch/stage u-boot (you provide it separately).

  Flavor (the LIVE / INSTALLER toggle)
    --flavor F          live | installer | both (DEFAULT both).
                        live      = boots ephemerally off microSD/USB.
                        installer = live image + install-orangepi-zero2.sh to
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
    --encrypt-root        install-orangepi-zero2.sh LUKS2-encrypts the target
                          root and prompts for a passphrase at install time
                          (ON-DEVICE format — see the header note); auto-on
                          for --standalone. Composable onto a plain (non
                          --standalone) build too.
    --luks-pass PASS      OPTIONAL unattended install-time passphrase — lands
                          on the installer image in plaintext (0600); prefer
                          the interactive install-time prompt.

  Phases
    --skip-kernel / --skip-clean / --resume

  General
    -w, --work-dir DIR  products land here (default ./out).
    -j, --jobs N        parallel jobs (default nproc).
    --print-plan        resolve + validate all flags, print the build plan
                        (PLAN_KEY=VALUE lines) and exit 0 — no root, no writes,
                        no network. Invalid combinations exit non-zero.
    -h, --help

EXAMPLES
    # Default: headless appliance, BOTH live + installer
    ./build-orangepi-zero2-stage4.sh

    # Live image only, joins the tailnet mesh
    ./build-orangepi-zero2-stage4.sh --flavor live

    # Standalone hardened appliance: local user over SSH, LUKS2 FDE on install
    ./build-orangepi-zero2-stage4.sh --standalone --local-user alice

    # Brand it, vendor a prebuilt U-Boot (optional — no blob needed here)
    ./build-orangepi-zero2-stage4.sh --brand acme --cluster-domain acme.example \
        --uboot-url https://example/u-boot-orangepizero2.bin

NOTES
    EXPERIMENTAL — this platform has never booted on real hardware from this
    repo. See specs-orangepi-zero2/README.md for the full research-confidence
    breakdown (boot chain, Ethernet, WiFi, storage, and — most importantly —
    why this platform is HEADLESS-ONLY) before trusting any image this builder
    produces.

    HEADLESS-ONLY: this board's Micro-HDMI port has NO working mainline Linux
    display driver (the H616's DE33 display engine has zero DRM support
    upstream). This image ships NO X11/desktop package and NO GPU/DRM kernel
    config, ever — see specs-orangepi-zero2/README.md for the full research.

    This board has NO eMMC and NO NVMe/PCIe — microSD (or USB) is the ONLY
    persistent storage class. U-Boot on this board needs NO proprietary blob
    (a project first — see the header); --uboot-url is an OPTIONAL convenience,
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
        --build-subdir)       BUILD_SUBDIR="$2";          shift 2 ;;
        -s|--specs-dir)       SPECS_DIR="$2";             shift 2 ;;
        -t|--target)          CROSS_TARGET="$2";          shift 2 ;;
        -j|--jobs)            JOBS="$2";                  shift 2 ;;
        -c|--cpu)             OPIZ2_CPU="$2";              shift 2 ;;
        -d|--defconfig)       OPIZ2_DEFCONFIG="$2";       shift 2 ;;
        --dtb)                OPIZ2_DTB="$2";             shift 2 ;;
        --uboot-defconfig)    OPIZ2_UBOOT_DEFCONFIG="$2"; shift 2 ;;
        --uboot-url)          OPIZ2_UBOOT_URL="$2";       shift 2 ;;
        --skip-uboot)         SKIP_UBOOT=true;            shift   ;;
        --flavor)             OPIZ2_FLAVOR="$2";          shift 2 ;;
        --live)               OPIZ2_FLAVOR="live";        shift   ;;
        --installer)          OPIZ2_FLAVOR="installer";   shift   ;;
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
case "${OPIZ2_FLAVOR}" in
    live|installer|both) ;;
    *) err "--flavor must be: live | installer | both (got '${OPIZ2_FLAVOR}')"; exit 1 ;;
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
case "${OPIZ2_FLAVOR}" in
    live)      BUILD_LIVE=true ;;
    installer) BUILD_INSTALLER=true ;;
    both)      BUILD_LIVE=true; BUILD_INSTALLER=true ;;
esac

if [ -z "${HOSTNAME}" ]; then
    case "${ROLE}" in
        appliance|generic) HOSTNAME="${BRAND}-orangepizero2" ;;
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
# installer flavor — LUKS is laid down by install-orangepi-zero2.sh, not the
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
# /etc/snapdragon tree — and OPIZ2_CPU/CROSS_TARGET land in make.conf, which
# portage SOURCES as shell on the (root) build host. The rendered first-boot
# script runs useradd/chpasswd with DEFAULT_USER as ROOT on the device. Reject
# anything outside a strict charset at this earliest boundary so a value
# carrying sed/shell metacharacters, a quote, or a newline can never reach a
# render sink or a sourced KEY=VALUE file. Escaping at the render sink
# (_sed_rep_escape) is defense-in-depth on top of this. Each regex below
# ACCEPTS every legitimate default (brand=snapdragon, org=Snapdragon-Systems,
# domain=snapdragon.systems, user=orangepizero2, cpu=cortex-a53,
# target=aarch64-unknown-linux-gnu, title "Snapdragon Systems"); HOSTNAME is
# derived from the validated brand above.
_require_match() {  # <human-name> <value> <regex>
    [[ "$2" =~ $3 ]] || { err "invalid $1: '$2' (must match ${3})"; exit 1; }
}
# DNS label (slug): lowercase alnum, internal hyphens, 1..63 chars.
_RE_SLUG='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
# Org slug: like a slug but allow upper-case (e.g. Snapdragon-Systems).
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
_require_match "--cpu"            "${OPIZ2_CPU}"       "${_RE_CPU}"
_require_match "--target"         "${CROSS_TARGET}"   "${_RE_TRIPLET}"
# ROLE is a hostname/marker only (see its declaration above — this platform is
# ONE role, not a desktop and not a k8s cluster node with a --role axis), and
# usage() documents no -r/--role option at all, but the parser entry still
# exists and feeds ART_PREFIX/STAGE4_TARBALL/LIVE_PATH/INSTALLER_PATH
# unescaped, unlike every other identity input above — allow-list it the same
# way, fail-closed like the rest of this block.
_require_match "--role"           "${ROLE}"           "${_RE_SLUG}"

BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"
SYSROOT="${BUILD_ROOT}/sysroot"
STAGE_DIR="${BUILD_ROOT}/staging"     # boot tree + ISO/installer staging
LOG_FILE="${WORK_DIR}/build.log"
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Image / artifact name prefix.
ART_PREFIX="${BRAND}-orangepizero2-arm64-${ROLE}-${ENV}-${BUILD_TS}"

if [ "${ENV}" = "prod" ]; then
    echo -e "${RED}${BOLD}"
    echo "############################################################################"
    echo "##   BUILDING PROD Orange Pi Zero 2 image for ${CLUSTER_DOMAIN}"
    echo "##   - bakes the REAL public domain; mesh/Casdoor creds from the keys USB ##"
    echo "############################################################################"
    echo -e "${RESET}"
else
    info "Build ENV: test (LAN-first; mesh + Casdoor login provisioned from the KEYS USB)"
fi
echo -e "${YELLOW}${BOLD}    EXPERIMENTAL PLATFORM: this board has never been booted with an image"
echo -e "    from this repo. See specs-orangepi-zero2/README.md before trusting this build.${RESET}"
info "Board: Orange Pi Zero 2 (Allwinner H616, quad Cortex-A53) — HEADLESS APPLIANCE"
info "DTB:   ${OPIZ2_DTB}   u-boot: ${OPIZ2_UBOOT_DEFCONFIG}"
info "Flavor: ${OPIZ2_FLAVOR}  (live=${BUILD_LIVE} installer=${BUILD_INSTALLER})"
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
        -e "s|@@OPIZ2_CPU@@|$(_sed_rep_escape "${OPIZ2_CPU}")|g" \
        -e "s|@@JOBS@@|$(_sed_rep_escape "${JOBS}")|g" \
        -e "s|@@WORK_DIR@@|$(_sed_rep_escape "${BUILD_ROOT}")|g" \
        -e "s|@@OPIZ2_KERNEL_IMG@@|$(_sed_rep_escape "${OPIZ2_KERNEL_IMG}")|g" \
        -e "s|@@OPIZ2_DTB@@|$(_sed_rep_escape "${OPIZ2_DTB}")|g" \
        -e "s|@@OPIZ2_INITRD_LINE@@|$(_sed_rep_escape "${OPIZ2_INITRD_LINE:-#}")|g" \
        -e "s|@@OPIZ2_APPEND@@|$(_sed_rep_escape "${OPIZ2_APPEND:-}")|g" \
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
# UWE5622/AW859A combo chip has NO mainline driver AT ALL (see the header) — no
# onboard-radio kernel module is even built (kernel/hardened-appliance.config),
# so this blacklist is pure defense-in-depth for a USB WiFi/Bluetooth dongle
# that happens to use an already-mainlined driver.
harden_radios() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/modprobe.d" "${sysroot}/etc/local.d" \
             "${sysroot}/etc/NetworkManager/conf.d"
    local bl="${sysroot}/etc/modprobe.d/snapdragon-radio-blacklist.conf"; : > "${bl}"
    local act="${sysroot}/etc/local.d/02-radio-hardening.start"
    {
        echo "#!/bin/sh"
        echo "# Radio hardening (build-orangepi-zero2-stage4.sh). WiFi/Bluetooth OFF by default."
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

# Configure a small zram swap at first boot — this board's RAM SKUs run as low
# as 512MB (512MB/1GB/1.5GB/2GB DDR3, auto-detected), so zram benefits the
# smallest SKUs a lot; harmless on the larger ones. Mirrors La Frite's 512MB
# SKU handling.
write_zram_firstboot() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/local.d"
    cat > "${sysroot}/etc/local.d/03-zram-swap.start" <<'ZRAM_EOF'
#!/bin/sh
# zram swap — sized to half of RAM, capped at 512M. Benefits the smallest RAM
# SKU (512MB) most; harmless on the larger ones. Idempotent; best-effort (no
# zram = skip).
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
    [ "${BRAND}" = "snapdragon" ] && [ "${CLUSTER_DOMAIN}" = "snapdragon.systems" ] && return 0
    local org_lc; org_lc="$(echo "${ORG}" | tr '[:upper:]' '[:lower:]')"
    # All of these land on the REPLACEMENT side of `sed s|..|VALUE|` across the baked
    # /etc/snapdragon tree (config the device reads as root); escape sed metacharacters
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
        # neither `snapdragon.systems` nor `snapdragon-`, so the middle rules skip it.
        sed -i \
            -e "s|^snapdragon\.systems/|@@SDSYSKEY@@/|g" \
            -e "s|\([ {(,\"'\`]\)snapdragon\.systems/|\1@@SDSYSKEY@@/|g" \
            -e "s|Snapdragon Systems|${_btitle}|g" \
            -e "s|Snapdragon-Systems|${_org}|g" \
            -e "s|snapdragon\.systems|${_domain}|g" \
            -e "s|\(registry\.[A-Za-z0-9.-]*\)/snapdragon/|\1/${_hproj}/|g" \
            -e "s|snapdragon-|${_brand}-|g" \
            -e "s|@@SDSYSKEY@@/|snapdragon.systems/|g" \
            "${f}"
    done < <(find "${SYSROOT}/etc/snapdragon" -type f -print0 2>/dev/null)
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
    _plan BUILDER            "build-orangepi-zero2-stage4.sh"
    _plan PLATFORM           "orangepizero2"
    _plan ARCH               "arm64"
    _plan ROLE               "${ROLE}"
    _plan ENV                "${ENV}"
    _plan DTB                "${OPIZ2_DTB}"
    _plan UBOOT_DEFCONFIG    "${OPIZ2_UBOOT_DEFCONFIG}"
    # Effective flavor derived from the post-cascade BUILD_LIVE/BUILD_INSTALLER
    # booleans, NOT the raw --flavor enum: --standalone/--encrypt-root force
    # BUILD_INSTALLER=true regardless of what --flavor was passed, so echoing the
    # raw OPIZ2_FLAVOR here would misreport (e.g. --flavor live --encrypt-root
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
    _plan ARTIFACT_PREFIX    "${BRAND}-orangepizero2-arm64-${ROLE}-${ENV}-<timestamp>"
    _plan WORK_DIR           "${WORK_DIR}"
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
    _plan KERNEL             "mainline-arm64 (defconfig=${OPIZ2_DEFCONFIG} + hardened-appliance.config)"
    _plan FLAGS_EFFECTIVE    "env=${ENV} flavor=${_EFF_FLAVOR} img_size=${ROOT_MiB} grow=${GROW_POLICY} compress=${COMPRESS_IMG} resume=${RESUME} skip_kernel=${SKIP_KERNEL} skip_uboot=${SKIP_UBOOT} skip_mesh=${SKIP_MESH} skip_tailscale=${SKIP_TAILSCALE} permit_root_login=${PERMIT_ROOT_LOGIN} enable_wifi=${ENABLE_WIFI} enable_bluetooth=${ENABLE_BLUETOOTH} standalone=${STANDALONE} encrypt_root=${ENCRYPT_ROOT}"
    exit 0
fi

banner "Verifying prerequisites"
[ -d "${SPECS_DIR}" ]    || { err "Orange Pi Zero 2 specs directory not found: ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Shared specs directory not found: ${SHARED_SPECS}"; exit 1; }
info "Orange Pi Zero 2 specs: ${SPECS_DIR}"
info "Shared specs:           ${SHARED_SPECS}"
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    command -v "${tool}" &>/dev/null || { err "${tool} not found in PATH."; exit 1; }
done

# ── Cross-dracut (--encrypt-root) fail-FAST preflight ───────────────
# An --encrypt-root Orange Pi Zero 2 installer needs an arm64 disk-boot
# initramfs, generated by chrooting into the target sysroot under qemu-aarch64.
# Detect a usable qemu-aarch64 NOW rather than after the multi-hour @stage4/kernel
# build. Runs only on a real build (after --print-plan), so matrix.tsv stays
# byte-identical. The post-build refusal remains the fail-SAFE backstop.
if ${ENCRYPT_ROOT} && ${BUILD_INSTALLER} && { ! ${SKIP_KERNEL} || ${IMAGE_ONLY}; }; then
    dracut_cross_register_qemu || true
    if ! dracut_cross_preflight_ok; then
        err "--encrypt-root on ${BRAND}-orange-pi-zero2-${ROLE} (if this build came from a multi-image mesh worklist, THIS node image is the affected one) needs the arm64 disk-boot initramfs, but no usable cross-dracut strategy is available: ${DRACUT_CROSS_BINFMT_NODE} is not registered and/or $(dracut_cross_qemu_interp) is missing/not executable."
        err "Fix: rebuild the builder image so it ships a static qemu-aarch64 (make docker-image — Dockerfile.build FINAL stage now emerges app-emulation/qemu[static-user] QEMU_USER_TARGETS=aarch64) AND run the build in a --privileged container so binfmt_misc can be mounted/registered. Refusing now BEFORE the multi-hour @stage4/kernel build rather than after."
        exit 1
    fi
    info "cross-dracut preflight OK: qemu-${DRACUT_CROSS_QEMU_ARCH} registered ($(dracut_cross_qemu_interp)); the arm64 disk-boot initramfs is buildable via qemu-chroot."
fi

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
if [ "$(id -u)" -eq 0 ] && [ -d /etc/portage ]; then
    mkdir -p /etc/portage/package.accept_keywords
    cat > /etc/portage/package.accept_keywords/snapdragon-host-build-backends <<'HOSTKW'
# setuptools-scm's vcs-versioning backend: pure-python/arch-independent, often
# keyworded amd64-first upstream. HOST-side twin of the sysroot's
# package.accept_keywords/setuptools-scm-backend (see that file's rationale).
dev-python/vcs-versioning **
# setuptools-scm itself: the container-stable 10.0.5 fails its own wheel
# REBUILD once vcs-versioning-2 is installed ("unable to detect version",
# real jetson host-side failure 2026-07-16); the working 10.2.x is ~amd64.
dev-python/setuptools-scm **
HOSTKW
    info "Pre-seeded HOST /etc/portage/package.accept_keywords: vcs-versioning (build-backend)"
    # The tree's default PYTHON_TARGETS has moved past the container's
    # dev-lang/python:3.12 — the same host-side BDEPEND batch then aborts on
    # "The following USE changes are necessary to proceed:
    #  >=dev-python/…  python_targets_python3_12" (empirically reproduced against
    # the failed 2026-07-16 jetson sysroot). HOST twin of the sysroot's
    # package.use/python-targets seed — see that file's full rationale.
    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/snapdragon-host-build-backends <<'HOSTPYUSE'
# Keep the python3.12 target enabled for host-side (BDEPEND "to /") installs —
# twin of the sysroot's package.use/python-targets (see that file's rationale).
*/* PYTHON_TARGETS: python3_12
# The 3.12 tooling cascade pulls host dev-lang/python:3.12 → util-linux[pam] →
# pam-1.7.2, whose pambase→passwdqc chain requires pam[audit] (twin of the
# sysroot's package.use/pam-audit; harmless in the ephemeral build container).
sys-libs/pam audit
HOSTPYUSE
    info "Pre-seeded HOST /etc/portage/package.use: PYTHON_TARGETS python3_12 (build-backend chain)"
fi

# Host SELinux policy build tools (same rationale as every other builder:
# selinux-base src_compile uses the HOST checkpolicy/semodule_package; cross
# copies can't run).
HOST_POLICY_TOOLS=()
command -v checkpolicy      &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/checkpolicy)
command -v semodule_package &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/semodule-utils)
command -v m4               &>/dev/null || HOST_POLICY_TOOLS+=(sys-devel/m4)
if [ "${#HOST_POLICY_TOOLS[@]}" -ne 0 ]; then
    readarray -t HOST_POLICY_TOOLS < <(printf '%s\n' "${HOST_POLICY_TOOLS[@]}" | sort -u)
    if [ "$(id -u)" -eq 0 ] && command -v emerge &>/dev/null; then
        warn "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]} — emerging natively"
        emerge --noreplace --quiet "${HOST_POLICY_TOOLS[@]}" \
            || { err "Failed to install host SELinux build tools (${HOST_POLICY_TOOLS[*]})."; exit 1; }
    else
        err "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]}"
        err "Install on the BUILD host: emerge sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4"
        exit 1
    fi
fi
# The LIVE/INSTALLER images need a squasher (mksquashfs, or tar2sqfs from
# squashfs-tools-ng) + xorriso to wrap the squashfs ISO.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    command -v xorriso >/dev/null || warn "missing xorriso — the live/installer image step will warn + skip"
    if ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        warn "missing mksquashfs AND tar2sqfs — the live/installer image step will warn + skip"
    fi
fi
info "Cross-compiler: $(${CROSS_TARGET}-gcc --version | head -1)"
info "Jobs: ${JOBS}"

banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir,log} "${SYSROOT}" "${STAGE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE}"

banner "Fetching latest arm64 stage3 seed tarball"
STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
STAGE3_BASENAME=$(basename "${STAGE3_FILE}")
STAGE3_FULL_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/${STAGE3_FILE}"
STAGE3_LOCAL="${BUILD_ROOT}/${STAGE3_BASENAME}"
if [ ! -f "${STAGE3_LOCAL}" ]; then
    info "Downloading ${STAGE3_BASENAME}..."
    curl -L -o "${STAGE3_LOCAL}" "${STAGE3_FULL_URL}"
else
    info "Using cached ${STAGE3_BASENAME}"
fi

# SUPPLY-CHAIN: verify the seed (signed DIGESTS + SHA512/SHA256) before trusting
# it; ABORT on any signature/checksum mismatch. See scripts/_download-lib.sh.
banner "Verifying stage3 seed signature + checksum"
if ! dlv_verify_stage3 "${STAGE3_LOCAL}" "${STAGE3_FULL_URL}.DIGESTS"; then
    rm -f "${STAGE3_LOCAL}"
    err "stage3 seed failed verification (bad signature or checksum) — aborting."
    err "If Gentoo rotated its signing key, set DLV_GENTOO_KEY=<fingerprint>; for an"
    err "air-gapped build set DLV_OFFLINE_KEYRING=<keyfile>. Refusing unverified seed."
    exit 1
fi

banner "Extracting seed stage3 into sysroot"
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
# in Rust-based cross-compile exclusions, so specs-orangepi-zero2 ships none;
# only copy it if a future addition needs one.
[ -f "${SPECS_DIR}/portage/profile/package.provided" ] && \
    cp "${SPECS_DIR}/portage/profile/package.provided" "${SYSROOT}/etc/portage/profile/package.provided"
cp "${SPECS_DIR}/portage/package.accept_keywords/"* "${SYSROOT}/etc/portage/package.accept_keywords/"
cp "${SPECS_DIR}/portage/package.use/"*             "${SYSROOT}/etc/portage/package.use/"
cp "${SPECS_DIR}/portage/package.env/"*             "${SYSROOT}/etc/portage/package.env/"
cp "${SPECS_DIR}/portage/env/"*.conf               "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"

cp "${SPECS_DIR}/etc/fstab" "${SYSROOT}/etc/fstab"

# LUKS2 root (--encrypt-root): persist crypt-module support into any FUTURE
# dracut regeneration on the installed system (e.g. a post-install kernel
# rebuild), not just the disk-boot initramfs this build generates directly.
if ${ENCRYPT_ROOT}; then
    mkdir -p "${SYSROOT}/etc/dracut.conf.d"
    cp "${SPECS_DIR}/etc/dracut.conf.d/60-snapdragon-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/"
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
# /etc/snapdragon/registry (installed on ADMIN nodes only; the conf gate-flips on
# the first verified sync).
mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/usr/lib/snapdragon" \
         "${SYSROOT}/etc/snapdragon/registry" "${SYSROOT}/var/lib/snapdragon/device-registry"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-authorized-keys-lookup" "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-device-registry-sync"   "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup" "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/usr/lib/snapdragon/registry-verify.sh"      "${SYSROOT}/usr/lib/snapdragon/registry-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/device-registry.conf" "${SYSROOT}/etc/snapdragon/registry/device-registry.conf"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/break-glass.conf"     "${SYSROOT}/etc/snapdragon/registry/break-glass.conf"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/snapdragon/registry/cron-device-registry-sync"

# ── Layer-A device-license-registry headscale policy (CONTROL/pki node only) ────
# provision_headscale_policy_sync() ACTIVATES these only when headscale.enabled
# (the control node). Inert on a non-control node. REUSES Layer-B's registry-verify.sh
# + baked registry-pub.ed25519 (no duplication).
cp "${SHARED_SPECS}/usr/sbin/gen-headscale-policy.sh"          "${SYSROOT}/usr/sbin/gen-headscale-policy.sh"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-headscale-forcetags"   "${SYSROOT}/usr/sbin/snapdragon-headscale-forcetags"
chmod +x "${SYSROOT}/usr/sbin/gen-headscale-policy.sh" "${SYSROOT}/usr/sbin/snapdragon-headscale-forcetags"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-policy-sync"         "${SYSROOT}/etc/init.d/snapdragon-policy-sync"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-policy-sync"
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson"     "${SYSROOT}/etc/headscale/policy.bootstrap.hujson"
cp "${SHARED_SPECS}/etc/headscale/policy.hujson.tmpl"          "${SYSROOT}/etc/headscale/policy.hujson.tmpl"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-policy-sync"         "${SYSROOT}/etc/snapdragon/registry/cron-policy-sync"

# ── Egress VPN (split-tunnel, fail-closed) — node-level, DEFAULT-OFF ────────────
# Bake the OpenRC service + the split-tunnel runner into every node image; INERT
# until enabled (not linked into a runlevel here; no active.conf => runner no-op).
cp "${SHARED_SPECS}/etc/init.d/snapdragon-egress-vpn" "${SYSROOT}/etc/init.d/snapdragon-egress-vpn"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-egress-vpn"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-vpn-runner"   "${SYSROOT}/usr/sbin/snapdragon-vpn-runner"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-vpn-runner"
mkdir -p "${SYSROOT}/etc/snapdragon/vpn"; chmod 0700 "${SYSROOT}/etc/snapdragon/vpn"

# ── Egress-VPN reconcile bridge (signed per-node export consumer) — DEFAULT-OFF ─
# Bake the reconcile agent + verify lib + OpenRC service; INERT until enabled
# (REUSES the baked registry-pub.ed25519; the cron is staged for the gate).
cp "${SHARED_SPECS}/usr/sbin/snapdragon-vpn-reconcile" "${SYSROOT}/usr/sbin/snapdragon-vpn-reconcile"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-vpn-reconcile"
cp "${SHARED_SPECS}/usr/lib/snapdragon/vpn-verify.sh" "${SYSROOT}/usr/lib/snapdragon/vpn-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-vpn-reconcile" "${SYSROOT}/etc/init.d/snapdragon-vpn-reconcile"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-vpn-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-vpn-reconcile" "${SYSROOT}/etc/snapdragon/registry/cron-vpn-reconcile"

# ── Opt-in host-binary auto-update (binpkg deltas from the binhost) ─────────────
# The SAME poller every other client image bakes: keeps a client device's
# binaries fresh from the tailnet binhost over the VPN. provision_update() bakes
# the /etc/cron.d cadence timer + the boot oneshot is linked into the default
# runlevel below, but the poller is DEFAULT-OFF / INERT: it does NOTHING until a
# superadmin opts in by setting enabled:true in the snapdragon-update-policy
# ConfigMap (fail-safe-to-OFF — an absent/unreachable policy means NO pull).
# cronie + OpenRC (not systemd).
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-update"     "${SYSROOT}/usr/local/sbin/snapdragon-update"
chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-update"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-update"         "${SYSROOT}/etc/init.d/snapdragon-update"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-update"
# ── Domain-registry -> brand-repo bridge (#4) — DEFAULT-OFF, baked-but-INERT ─────
# Bake the reconcile agent + its verify lib (domain-verify.sh) + the OpenRC service
# + the two generators for PARITY with every other client/host image. This
# platform is a single-board appliance, NOT a k8s cluster node (it bakes no
# cluster GitOps tree) and has no _opt_selected gate, so — exactly like the
# egress-VPN reconcile above — the agent is NEVER linked into a runlevel here
# (inert-by-omission). REUSES the baked registry-pub.ed25519 (never re-bake).
# Even if hand-enabled it fail-closes without a real key + transport, and with
# no cluster there is nothing to drive.
cp "${SHARED_SPECS}/usr/sbin/snapdragon-domain-reconcile" "${SYSROOT}/usr/sbin/snapdragon-domain-reconcile"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-domain-reconcile"
cp "${SHARED_SPECS}/usr/lib/snapdragon/domain-verify.sh" "${SYSROOT}/usr/lib/snapdragon/domain-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-domain-reconcile" "${SYSROOT}/etc/init.d/snapdragon-domain-reconcile"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-domain-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-domain-reconcile" "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile"
mkdir -p "${SYSROOT}/usr/share/snapdragon/generator/scripts" "${SYSROOT}/usr/share/snapdragon/generator/templates"
cp "${SCRIPT_DIR}/scripts/gen-keystores.sh"  "${SYSROOT}/usr/share/snapdragon/generator/scripts/gen-keystores.sh"
cp "${SCRIPT_DIR}/generate-brand-repos.sh"   "${SYSROOT}/usr/share/snapdragon/generator/generate-brand-repos.sh"
cp -r "${SCRIPT_DIR}/templates/."            "${SYSROOT}/usr/share/snapdragon/generator/templates/"
chmod +x "${SYSROOT}/usr/share/snapdragon/generator/scripts/gen-keystores.sh" "${SYSROOT}/usr/share/snapdragon/generator/generate-brand-repos.sh"

# Node role + domain + env markers (read by keys-provision / first-boot).
mkdir -p "${SYSROOT}/etc/snapdragon"
echo "${ROLE}"           > "${SYSROOT}/etc/snapdragon/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/snapdragon/cluster-domain"
# Orchestration superdomain (WS-SUPER-B): record the mesh plane the image joins.
if [ -n "${SUPERDOMAIN}" ]; then
    echo "${SUPERDOMAIN}" > "${SYSROOT}/etc/snapdragon/superdomain"
    info "Baked orchestration superdomain -> /etc/snapdragon/superdomain (${SUPERDOMAIN})"
fi
echo "${ENV}"            > "${SYSROOT}/etc/snapdragon/env"
echo "orangepizero2"     > "${SYSROOT}/etc/snapdragon/board"
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/snapdragon/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/snapdragon/headscale-url"
fi
if ${STANDALONE}; then
    # STANDALONE appliance: bake the marker so keys-provision skips all
    # mesh-seeking no-ops and a normal LOCAL USER logs in over SSH with the
    # build-set password (mirrors build-x86-host-stage4.sh / build-frite-stage4.sh
    # / build-orangepi5-stage4.sh).
    echo "true" > "${SYSROOT}/etc/snapdragon/standalone"
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
# This platform is HEADLESS (no lightdm/GUI at all — see specs-orangepi-zero2/
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
        echo "# Generated by build-orangepi-zero2-stage4.sh for --standalone: this platform"
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
# superadmin sets enabled:true in the snapdragon-update-policy ConfigMap.
DEFAULT_SVCS+=(snapdragon-update)
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
    "${CROSS_TARGET}-emerge" --jobs="${JOBS}" --load-average="${JOBS}" --with-bdeps=n "$@"
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
    banner "Phase 1: SKIPPED (--image-only)"
    banner "Phase 2: SKIPPED (--image-only)"
else

banner "Phase 1: Cross-building @system (hardened)"
cross_emerge --oneshot --update sys-apps/baselayout
cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" @system \
    || warn "@system had package failures (--keep-going); continuing"

banner "Phase 2: Cross-building stage4 packages"
mapfile -t STAGE4_PACKAGES < <(grep -v '^\s*#' "${SPECS_DIR}/portage/packages.list" | grep -v '^\s*$')
# NO desktop package list, EVER — unlike every other platform in this repo
# (which either always has a desktop set, or gates one behind --desktop), this
# board has no packages-desktop.list / packages-light-desktop.list at all. The
# base packages.list above IS the whole appliance. See the builder header.
# LIVE *and* INSTALLER flavors: pull in sys-kernel/dracut so the builder can
# generate a dmsquash-live initramfs (the bare kernel cannot mount
# root=live:/rd.live.* — that is a dracut job). The INSTALLER medium is itself a
# LIVE boot (it must come up so the operator can run install-orangepi-zero2.sh
# — see that script's own header), so it needs the same initramfs. dracut stays
# out of the always-installed base set and is added here for both bootable
# flavors.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    info "Bootable flavor selected — appending packages-live.list (dracut for the live initramfs)"
    mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
        grep -v '^\s*#' "${SPECS_DIR}/portage/packages-live.list" | grep -v '^\s*$')
fi
if ${ENCRYPT_ROOT}; then
    # --encrypt-root: cryptsetup is what install-orangepi-zero2.sh runs
    # (luksFormat/open/close) on the TARGET hardware at install time — needed
    # in the installed stage4 payload itself, not just the build host. dracut
    # (for the disk-boot initramfs that unlocks the LUKS root) is already
    # pulled in above via packages-live.list whenever BUILD_INSTALLER is true,
    # which --encrypt-root forces on below.
    info "--encrypt-root selected — appending sys-fs/cryptsetup"
    STAGE4_PACKAGES+=("sys-fs/cryptsetup")
fi
if [ -n "${EXTRA_PACKAGES}" ]; then
    read -ra _extras <<< "${EXTRA_PACKAGES}"
    STAGE4_PACKAGES+=("${_extras[@]}")
    info "Extra packages: ${EXTRA_PACKAGES}"
fi
# User package deltas (--packages-add / --packages-drop): adds appended, drops
# filtered from the resolved set (validated + mandatory-floor-checked up front).
if [ -n "${PACKAGES_ADD}" ]; then
    read -ra _padd <<< "${PACKAGES_ADD}"
    STAGE4_PACKAGES+=("${_padd[@]}")
    info "Added packages (--packages-add): ${PACKAGES_ADD}"
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
    info "Dropped packages (--packages-drop): ${PACKAGES_DROP}"
fi
# The package set is MANDATORY: an empty list means the grep/specs path is broken
# and we would emerge nothing and emit a payload-less stage4.
[ -s "${SPECS_DIR}/portage/packages.list" ] || { err "packages.list is empty/missing: ${SPECS_DIR}/portage/packages.list"; exit 1; }
[ "${#STAGE4_PACKAGES[@]}" -gt 0 ] || { err "no stage4 packages resolved from the package lists — refusing to build a payload-less image."; exit 1; }
info "Package count: ${#STAGE4_PACKAGES[@]}"
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
# for install-orangepi-zero2.sh's ENCRYPT branch to format/open the encrypted root.
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

# ── 7. Install mesh VPN (headscale + tailscale) — same as every sibling ─────
if ${SKIP_MESH}; then
    banner "Phase 2.5: SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Phase 2.5: Installing mesh VPN (headscale + tailscale)"
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
    if ! curl -fL -o "${HS_BIN}" "${HS_URL}"; then
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
        if ! curl -fL -o "${TS_TGZ}" "${TS_URL}"; then
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
# OPIZ2_KVER is captured here (from `make kernelrelease`) so Phase 4 can point
# dracut --kver at the EXACT module tree this build installs under
# ${SYSROOT}/lib/modules/. Empty if the kernel is skipped/unbuilt.
OPIZ2_KVER=""
if ${SKIP_KERNEL}; then
    banner "Phase 3: SKIPPED (--skip-kernel)"
else
    banner "Phase 3: Cross-compiling hardened kernel"
    KERNEL_SRC=$(find "${SYSROOT}/usr/src/" -maxdepth 1 -name 'linux-*' -type d 2>/dev/null | sort -V | tail -1)
    if [ -z "${KERNEL_SRC}" ]; then
        warn "No kernel sources found in sysroot — ensure sys-kernel/gentoo-sources installed. Skipping kernel."
    else
        info "Building kernel from ${KERNEL_SRC} (defconfig: ${OPIZ2_DEFCONFIG}, CPU: ${OPIZ2_CPU})"
        pushd "${KERNEL_SRC}" >/dev/null
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" "${OPIZ2_DEFCONFIG}"
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
        # specs-orangepi-zero2/README.md, so this is a hard build-time guard,
        # not just a comment.
        for must_not in CONFIG_DRM CONFIG_FRAMEBUFFER_CONSOLE; do
            if grep -q "^${must_not}=y" .config; then
                err "${must_not}=y is set but this platform is HEADLESS-ONLY (H616 has no mainline display driver — see specs-orangepi-zero2/README.md). Refusing to ship a kernel that silently grew display config; check --defconfig / any local fragment overrides."
                exit 1
            fi
        done
        # The kernelrelease string is the module-tree dir name (lib/modules/<kver>),
        # which dracut needs as --kver for the live initramfs.
        OPIZ2_KVER="$(make -s ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" kernelrelease 2>/dev/null | tail -1)"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" -j"${JOBS}" Image modules dtbs
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" INSTALL_MOD_PATH="${SYSROOT}" modules_install
        mkdir -p "${SYSROOT}/boot/dtb/allwinner"
        cp arch/arm64/boot/Image "${SYSROOT}/boot/${OPIZ2_KERNEL_IMG}"
        # Ship the FULL Allwinner DTB tree (the board DTB is selected by extlinux's
        # FDT line).
        cp -r arch/arm64/boot/dts/allwinner "${SYSROOT}/boot/dtb/" 2>/dev/null || \
            cp arch/arm64/boot/dts/allwinner/*.dtb "${SYSROOT}/boot/dtb/allwinner/" 2>/dev/null || true
        # The board FDT is MANDATORY: extlinux's FDT line points at it and the
        # board will NOT boot without it. We just built the kernel, so a missing
        # DTB is a hard error, not a warning.
        if [ ! -f "${SYSROOT}/boot/dtb/${OPIZ2_DTB}" ]; then
            err "Selected DTB ${OPIZ2_DTB} not found under ${SYSROOT}/boot/dtb after the kernel build — the board would not boot. Verify the in-tree DTB name for this kernel (Allwinner devicetree naming has moved before — see specs-orangepi-zero2/README.md)."
            exit 1
        fi
        popd >/dev/null
        info "Kernel build complete (Image + Allwinner DTBs staged under /boot)."
    fi
fi

# ── 9. U-Boot for the board (NO proprietary blob needed — see the header) ──
if ${SKIP_UBOOT}; then
    banner "Phase 3.5: SKIPPED u-boot (--skip-uboot)"
else
    banner "Phase 3.5: Staging u-boot (${OPIZ2_UBOOT_DEFCONFIG})"
    mkdir -p "${STAGE_DIR}/uboot"
    if [ -n "${OPIZ2_UBOOT_URL}" ]; then
        if curl -fL -o "${STAGE_DIR}/uboot/u-boot.bin" "${OPIZ2_UBOOT_URL}"; then
            info "u-boot staged from ${OPIZ2_UBOOT_URL} -> ${STAGE_DIR}/uboot/u-boot.bin"
        else
            warn "Could not fetch u-boot from ${OPIZ2_UBOOT_URL}; image will have no bootloader staged."
        fi
    else
        warn "No --uboot-url given. UNLIKE every other arm64 platform in this repo, this"
        warn "board's mainline U-Boot needs NO proprietary blob at all (a genuinely native,"
        warn "community-reverse-engineered H616 DRAM-init driver — see the header). A real"
        warn "from-source build ('make ${OPIZ2_UBOOT_DEFCONFIG}' against mainline U-Boot) is"
        warn "realistic here but not attempted by this builder (no hardware to validate"
        warn "against in this environment — see specs-orangepi-zero2/README.md). Provide a"
        warn "prebuilt u-boot.bin via --uboot-url, or drop one into ${STAGE_DIR}/uboot/"
        warn "before flashing."
    fi
fi

if ${SKIP_CLEAN}; then
    banner "Cleaning: SKIPPED (--skip-clean)"
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

banner "Phase 4: Staging the boot tree"
BOOT_STAGE="${STAGE_DIR}/boot"
rm -rf "${BOOT_STAGE}"; mkdir -p "${BOOT_STAGE}/extlinux" "${BOOT_STAGE}/dtb"
APPEND_BASE="$(cat "${SPECS_DIR}/boot/cmdline.base")"
if [ -f "${SYSROOT}/boot/${OPIZ2_KERNEL_IMG}" ]; then
    cp "${SYSROOT}/boot/${OPIZ2_KERNEL_IMG}" "${BOOT_STAGE}/"
    cp -r "${SYSROOT}/boot/dtb/." "${BOOT_STAGE}/dtb/" 2>/dev/null || true
else
    warn "Kernel ${OPIZ2_KERNEL_IMG} not in sysroot — the boot tree will be incomplete."
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
# proven to boot on a real Orange Pi Zero 2 board with a full Gentoo cross-build.
OPIZ2_LIVE_INITRD=""        # set non-empty once the live initramfs is staged
build_live_initramfs() {
    [ -f "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" ] || {
        warn "no kernel in boot stage — cannot build the live initramfs; LIVE image will NOT boot."
        return 1; }
    # Resolve the kernel module dir to target. Prefer the captured kernelrelease;
    # otherwise fall back to the single module tree modules_install just created.
    local kver="${OPIZ2_KVER}"
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
            OPIZ2_LIVE_INITRD="${out}"
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
                OPIZ2_LIVE_INITRD="${out}"
                info "Live initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce an initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            --modules "${mods}" "${out}" 2>/dev/null && [ -s "${out}" ] && {
                OPIZ2_LIVE_INITRD="${out}"
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
# two are never confused. install-orangepi-zero2.sh copies it into place; the
# ACTUAL root=/rd.luks.uuid= cmdline is filled in there too (the LUKS UUID does
# not exist until install-orangepi-zero2.sh formats the target partition).
# Mirrors build-frite-stage4.sh / build-orangepi5-stage4.sh's identical Phase
# 3.5 exactly.
OPIZ2_DISK_INITRD=""        # set non-empty once the disk-boot initramfs is staged
build_disk_initramfs() {
    [ -f "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" ] || {
        warn "no kernel in boot stage — cannot build the disk-boot initramfs; an --encrypt-root install would NOT boot."
        return 1; }
    local kver="${OPIZ2_KVER}"
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
            OPIZ2_DISK_INITRD="${out}"
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
                OPIZ2_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce a disk-boot initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                OPIZ2_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
    fi
    warn "Could not generate the disk-boot initramfs (no usable dracut). An"
    warn "--encrypt-root install would be UNBOOTABLE without it."
    return 1
}
if ${ENCRYPT_ROOT} && ${BUILD_INSTALLER} && { ! ${SKIP_KERNEL} || ${IMAGE_ONLY}; }; then
    build_disk_initramfs || true
    if [ -z "${OPIZ2_DISK_INITRD}" ] || [ ! -s "${OPIZ2_DISK_INITRD}" ]; then
        err "--encrypt-root requires the disk-boot initramfs (see warnings above) — refusing to build a payload that cannot boot an encrypted root."
        exit 1
    fi
fi

banner "Phase 4: Packaging stage4 tarball"
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
    [ -f "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" ] || { warn "no kernel in boot stage — skipping LIVE image."; return 0; }

    # The LIVE flavor is unbootable without the dmsquash-live initramfs (the
    # cmdline below is all dracut directives). Refuse to package a LIVE image that
    # has no initramfs rather than ship a known-dead boot.
    if [ -z "${OPIZ2_LIVE_INITRD}" ] || [ ! -s "${OPIZ2_LIVE_INITRD}" ]; then
        warn "No live initramfs was generated (Phase 4 §11b). The LIVE image would NOT"
        warn "boot (root=live:/rd.live.* need a dracut dmsquash-live initramfs). Skipping"
        warn "the LIVE image. Build with dracut available, or use --flavor installer."
        return 0
    fi

    local live_root="${STAGE_DIR}/live"
    rm -rf "${live_root}"; mkdir -p "${live_root}/LiveOS" "${live_root}/extlinux" "${live_root}/dtb"
    cp "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" "${live_root}/"
    cp -r "${BOOT_STAGE}/dtb/." "${live_root}/dtb/" 2>/dev/null || true
    # The board FDT MUST be on the medium — extlinux's FDT line references it and the
    # board will not boot without it. Refuse to package a DTB-less LIVE image.
    [ -f "${live_root}/dtb/${OPIZ2_DTB}" ] || { err "LIVE image: board DTB ${OPIZ2_DTB} missing from ${live_root}/dtb — refusing to package a non-booting medium."; exit 1; }
    # Stage the dmsquash-live initramfs next to the kernel (extlinux INITRD line).
    cp "${OPIZ2_LIVE_INITRD}" "${live_root}/initrd.img"

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
    OPIZ2_INITRD_LINE="    INITRD /initrd.img"
    OPIZ2_APPEND="${APPEND_BASE} root=live:LABEL=OPIZ2_LIVE rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${live_root}/extlinux/extlinux.conf"

    if command -v xorriso >/dev/null; then
        LIVE_PATH="${WORK_DIR}/${ART_PREFIX}.live.iso"
        xorriso -as mkisofs -o "${LIVE_PATH}" -volid OPIZ2_LIVE -joliet -rock "${live_root}" \
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
    # microSD/USB, gets a running system, then runs install-orangepi-zero2.sh
    # to write the appliance to microSD/USB — see that script's own header,
    # including the ON-DEVICE LUKS format rationale and the same-device-as-
    # boot-medium handling).
    #
    # WHY THIS IS A LIVE BOOT, not a bare kernel: the medium's extlinux boots
    # ephemerally from a squashfs (exactly like the LIVE flavor) so the
    # installer can actually run; the disk's `root=LABEL=OPIZ2_ROOT` cmdline
    # belongs on the PAYLOAD boot tree we stage for install-orangepi-zero2.sh
    # to copy onto the target, NOT on the medium itself (mirrors
    # build-frite-stage4.sh's / build-orangepi5-stage4.sh's build_installer_iso
    # exactly).
    command -v xorriso >/dev/null || { err "xorriso missing — cannot build the INSTALLER ISO. Install xorriso or drop --flavor installer."; exit 1; }
    [ -f "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" ] || { err "no kernel in boot stage — the INSTALLER medium cannot boot. Build the kernel (drop --skip-kernel)."; exit 1; }
    if ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        err "mksquashfs/tar2sqfs missing — cannot build the INSTALLER medium's live rootfs. Install squashfs-tools (or squashfs-tools-ng)."; exit 1
    fi
    # The medium boots root=live:/rd.live.* — those are dracut directives, so the
    # dmsquash-live initramfs is MANDATORY. Refuse to emit a known-dead installer
    # rather than a silent, unbootable one (mirrors the LIVE gate).
    if [ -z "${OPIZ2_LIVE_INITRD}" ] || [ ! -s "${OPIZ2_LIVE_INITRD}" ]; then
        err "No live initramfs was generated (Phase 4 §11b). The INSTALLER medium boots"
        err "from a squashfs (root=live:/rd.live.*) and is UNBOOTABLE without a dracut"
        err "dmsquash-live initramfs. Ensure sys-kernel/dracut emerged and the kernel"
        err "module tree exists (do not pass --skip-kernel for the installer flavor)."
        exit 1
    fi

    local inst_root="${STAGE_DIR}/installer"
    rm -rf "${inst_root}"; mkdir -p "${inst_root}"/{LiveOS,extlinux,dtb,stage4,boot,uboot}

    # ── The medium's OWN live boot (kernel + DTB + dmsquash-live initramfs) ──
    cp "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" "${inst_root}/"
    cp -r "${BOOT_STAGE}/dtb/." "${inst_root}/dtb/" 2>/dev/null || true
    [ -f "${inst_root}/dtb/${OPIZ2_DTB}" ] || { err "INSTALLER medium: board DTB ${OPIZ2_DTB} missing from ${inst_root}/dtb — refusing to package a non-booting medium."; exit 1; }
    cp "${OPIZ2_LIVE_INITRD}" "${inst_root}/initrd.img"

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

    # The medium's extlinux boots the squashfs ephemerally (OPIZ2_INSTALL volid).
    OPIZ2_INITRD_LINE="    INITRD /initrd.img"
    OPIZ2_APPEND="${APPEND_BASE} root=live:LABEL=OPIZ2_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/extlinux/extlinux.conf"

    # ── The INSTALL PAYLOAD that install-orangepi-zero2.sh consumes from its
    # own dir ──────────────────────────────────────────────────────────────
    # install-orangepi-zero2.sh reads ${SCRIPT_DIR}/stage4/*.tar.xz and copies
    # ${SCRIPT_DIR}/boot/ (the DISK boot tree) onto the target's FAT.
    # dmsquash-live mounts the medium at /run/initramfs/live, so the operator
    # runs /run/initramfs/live/install-orangepi-zero2.sh.
    cp "${STAGE4_TARBALL}" "${inst_root}/stage4/"
    # The disk boot tree: kernel + DTB + extlinux with the INSTALLED root cmdline
    # (root=LABEL=OPIZ2_ROOT, no live initramfs unless --encrypt-root).
    # install-orangepi-zero2.sh re-points root= at the target's PARTUUID/LUKS
    # UUID after partitioning.
    mkdir -p "${inst_root}/boot/extlinux" "${inst_root}/boot/dtb"
    cp "${BOOT_STAGE}/${OPIZ2_KERNEL_IMG}" "${inst_root}/boot/"
    cp -r "${BOOT_STAGE}/dtb/." "${inst_root}/boot/dtb/" 2>/dev/null || true
    [ -f "${inst_root}/boot/dtb/${OPIZ2_DTB}" ] || { err "INSTALLER payload: disk-boot DTB ${OPIZ2_DTB} missing from ${inst_root}/boot/dtb — the installed system would not boot. Aborting."; exit 1; }
    # --encrypt-root: ship the crypt-capable disk-boot initramfs so
    # install-orangepi-zero2.sh's LUKS branch has something to unlock a LUKS
    # root with. root=LABEL=OPIZ2_ROOT stays the baked default either way —
    # install-orangepi-zero2.sh rewrites it to root=/dev/mapper/cryptroot
    # rd.luks.uuid=<uuid> ONLY when it actually formats an encrypted root.
    if ${ENCRYPT_ROOT}; then
        [ -n "${OPIZ2_DISK_INITRD}" ] && [ -s "${OPIZ2_DISK_INITRD}" ] || {
            err "--encrypt-root: no disk-boot initramfs was generated (Phase 3.5) — refusing to package an installer that cannot boot an encrypted root."; exit 1; }
        cp "${OPIZ2_DISK_INITRD}" "${inst_root}/boot/initrd.img"
        OPIZ2_INITRD_LINE="    INITRD /initrd.img"
    else
        OPIZ2_INITRD_LINE="    # (installed system boots a real partitioned rootfs)"
    fi
    OPIZ2_APPEND="${APPEND_BASE} root=LABEL=OPIZ2_ROOT"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/boot/extlinux/extlinux.conf"
    cp "${SPECS_DIR}/installer/install-orangepi-zero2.sh" "${inst_root}/install-orangepi-zero2.sh"
    chmod +x "${inst_root}/install-orangepi-zero2.sh"
    [ -f "${STAGE_DIR}/uboot/u-boot.bin" ] && cp "${STAGE_DIR}/uboot/u-boot.bin" "${inst_root}/uboot/" 2>/dev/null || true
    # ── LUKS2 FDE marker + OPTIONAL seeded passphrase for
    # install-orangepi-zero2.sh ── Mirrors every other installer's marker
    # convention exactly.
    if ${ENCRYPT_ROOT}; then
        : > "${inst_root}/encrypt-root"   # marker: installer LUKS2-encrypts the target root
        info "INSTALLER image: encrypt-root marker set (install-orangepi-zero2.sh prompts for the root-unlock passphrase)."
        if [ -n "${LUKS_PASS}" ]; then
            printf '%s' "${LUKS_PASS}" > "${inst_root}/luks-passphrase"; chmod 600 "${inst_root}/luks-passphrase"
            warn "INSTALLER image carries an unattended LUKS passphrase (luks-passphrase, 0600) — anyone with the image can read it. Prefer the interactive install-time prompt."
        fi
    fi

    INSTALLER_PATH="${WORK_DIR}/${ART_PREFIX}.installer.iso"
    xorriso -as mkisofs -o "${INSTALLER_PATH}" -volid OPIZ2_INSTALL -joliet -rock "${inst_root}" \
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
    banner "Phase 5: Building LIVE image (boots-and-runs ephemerally off microSD/USB)"
    build_live_iso
fi
if ${BUILD_INSTALLER}; then
    banner "Phase 6: Building INSTALLER image (writes the appliance to microSD/USB)"
    build_installer_iso
fi

echo ""
echo -e "${CYAN}${BOLD}=============================================="
echo "  Orange Pi Zero 2 — Headless Appliance Complete (EXPERIMENTAL)"
echo "==============================================${RESET}"
echo ""
echo -e "${YELLOW}  EXPERIMENTAL: never booted on real hardware from this repo.${RESET}"
echo "  See specs-orangepi-zero2/README.md before trusting this image."
echo ""
echo "  Board:            Orange Pi Zero 2 (Allwinner H616, quad Cortex-A53)"
echo "  DTB:              ${OPIZ2_DTB}"
echo "  u-boot defconfig: ${OPIZ2_UBOOT_DEFCONFIG}  (NO proprietary blob needed — a project first)"
echo "  Role:             ${ROLE}  — HEADLESS APPLIANCE (no display, ever; see the header)"
echo "  Flavor:           ${OPIZ2_FLAVOR}"
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
echo "               sudo /run/initramfs/live/install-orangepi-zero2.sh /dev/mmcblk0"
echo "             to write the appliance to a microSD card (the SAME one it booted from, or"
echo "             a second card/stick — see install-orangepi-zero2.sh's header)."
echo "  u-boot:    this board needs NO proprietary blob (unlike every other arm64 platform"
echo "             in this repo) — provide a prebuilt image via --uboot-url, or (a realistic"
echo "             future option) cross-build mainline U-Boot from source yourself."
echo ""
