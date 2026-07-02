#!/usr/bin/env bash
# Build a hardened Gentoo aarch64 LIGHT-DESKTOP image for the Libre Computer
# Le/La Frite family (Amlogic GXL: S805X / S905X) using the same crossdev
# toolchain + shared mesh/provisioning plumbing as the Pi5/x86 client images.
#
# WHY a separate builder (not a flag on build-rpi5-stage4.sh): the Frite boots a
# fundamentally different chain — mainline u-boot (libretech-ac/-cc) + extlinux,
# the kernel's OWN Amlogic DTB, NO raspberrypi-firmware and (on La Frite) NO
# microSD slot. It is also a different PURPOSE: a LEAN DESKTOP client, not a K8s
# cluster node. Forking the Pi5 K8s flow keeps both paths simple and unbroken.
#
# This image JOINS THE TAILSCALE MESH exactly like the other client images: it
# ships the SAME shared specs/ provisioning engine (keys-provision), the SAME
# headscale/tailscale binaries (upstream static arm64), the SAME hardened sshd
# (key-only, prohibit-password — NO broad SSH access baked in), and honors the
# device-license registry posture (sshd obeys the per-node principals provisioned
# from the KEYS USB). See specs/etc/keys-provision/provision.sh + docs/SECURITY.md.
#
# Two image FLAVORS, both produced by this one generation option (toggle):
#   live      — boots-and-runs ephemerally off USB (La Frite has no SD) or SD
#               (Le Potato): squashfs rootfs in RAM, no persistence.
#   installer — a LIVE image that ALSO carries install-frite.sh + the stage4, to
#               write the light desktop to ONBOARD storage (eMMC, or SD on Le
#               Potato). The default below builds BOTH (--flavor both).
#
# Board VARIANTS (--board): la-frite (S805X, default; 512MB & 1GB RAM SKUs are the
# SAME image), le-potato (S905X), sweet-potato (S905X-CC-V2). Each selects its DTB
# + u-boot defconfig + boot-media policy. See the BOARD TABLE below.
#
# Run as root (sudo): the cross-emerge merges into the sysroot's vdb and writes
# the host emerge log/cache, so real root is required (fakeroot is NOT enough).
#
# ── VERIFIED vs NEEDS-HARDWARE (read this) ─────────────────────────────────────
# VERIFIED HERE: bash -n syntax; option parsing; the board table + DTB/defconfig
#   mapping; that it reuses the shared specs/ provisioning + mesh exactly like the
#   Pi5 builder; template rendering (live emits `INITRD /initrd.img`, installer
#   does not); that the Pi5/x86 paths are untouched.
# NEEDS REAL HARDWARE / A FULL GENTOO CROSS-BUILD TO VERIFY: the actual aarch64
#   cross-emerge of the LXDE stack; the mainline kernel build + the in-tree
#   meson-gxl DTB names; the u-boot FIP/BL31 signing (needs Amlogic proprietary
#   blobs); the cross-generated dmsquash-live initramfs ACTUALLY mounting the
#   squashfs as the ephemeral overlay root and booting off USB on a real La Frite;
#   the eMMC install. These steps are written to MIRROR the proven Pi5 flow but
#   cannot be end-to-end tested in this environment (no board, no full Gentoo
#   builder).
#
# LIVE-BOOT FIX (Phase 4 §11b + §13): earlier the LIVE cmdline set dracut
# directives (root=live:/rd.live.*) but NO initramfs was built and NO INITRD line
# was emitted, so the squashfs was never mounted and the LIVE image was unbootable
# by design. The LIVE flavor now pulls in sys-kernel/dracut (packages-live.list),
# GENERATES a dmsquash-live initramfs against the built module tree, stages it as
# /initrd.img next to the kernel, and the extlinux render emits the matching
# `INITRD /initrd.img`. The INSTALLER flavor is unchanged (real partitioned root).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-frite"    # aarch64/Frite-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"       # arch-agnostic specs (mesh, provisioning, sshd)

# Supply-chain download verification (OWASP). Shared helper so the stage3 seed,
# headscale, and tailscale fetches are GPG/checksum-verified by ONE audited
# implementation instead of trusting a bare `curl`. See scripts/_download-lib.sh.
# shellcheck source=scripts/_download-lib.sh
source "${SCRIPT_DIR}/scripts/_download-lib.sh"

WORK_DIR=""
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-frite}"   # per-arch isolation (never shares the Pi/x86 sysroot)
CROSS_TARGET="aarch64-unknown-linux-gnu"
REL_VERSION="2026.0"

# ── BOARD TABLE ────────────────────────────────────────────────────
# Selected by --board. Each board sets the GCC CPU, the kernel base defconfig, the
# in-tree Amlogic DTB to ship, the u-boot defconfig, and a human description. RAM
# SKUs are NOT a board axis: La Frite 512MB and 1GB are the SAME image (RAM is
# auto-detected); the 512MB SKU just leans on zram (configured below).
FRITE_BOARD="la-frite"                          # la-frite | le-potato | sweet-potato
FRITE_DEFCONFIG="defconfig"                     # generic arm64 mainline defconfig
FRITE_KERNEL_IMG="Image"
# Board-derived values. Left EMPTY here; select_board() fills any the operator did
# NOT override on the CLI. An explicit --cpu/--dtb/--uboot-defconfig sets these
# non-empty BEFORE select_board runs, and select_board only fills empties — so an
# explicit flag always wins regardless of flag order vs --board.
RPI_CPU=""                                      # all GXL boards are quad Cortex-A53
FRITE_DTB=""
FRITE_UBOOT_DEFCONFIG=""
FRITE_BOARD_DESC=""
FRITE_HAS_SD=false                              # set per-board (La Frite has NO microSD slot)

JOBS="$(nproc)"
SKIP_KERNEL=false
SKIP_CLEAN=false
RESUME=false
IMAGE_ONLY=false          # skip Phase 1-3 entirely; go straight to Phase 4 image assembly

# ── Image flavors (the LIVE / INSTALLER toggle) ────────────────────
# both (DEFAULT) = produce the LIVE squashfs image AND the INSTALLER image.
FRITE_FLAVOR="both"                             # live | installer | both
DESKTOP="light"                                 # light (DEFAULT) | none (headless base)
ROOT_MiB=3072                                   # ext4 root size for the installer's persistent build
GROW_POLICY="fill"
COMPRESS_IMG=false
EXTRA_PACKAGES=""
TIMEZONE="UTC"
HOSTNAME=""
ROLE="desktop"                                  # this image's role marker (client desktop)
CLUSTER_DOMAIN="snapdragon.systems"
BRAND="snapdragon"
BRAND_TITLE="Snapdragon Systems"
ORG="Snapdragon-Systems"
# ENV (test|prod) selector — kept for parity with the cluster builders (it shapes
# the same branding/creds knobs), BUT this Frite image is a LEAN DESKTOP CLIENT,
# NOT a K8s cluster node: it bakes NO specs/cluster GitOps tree (see the
# rebrand_sysroot note below) and therefore has NO installed-services ConfigMap,
# NO optional-services gate, and NO public ingress. The Anubis PUBLIC PoW-shield
# ENV policy (prod-on / test-off + the fe-gateway ingress reroute) lives ONLY in
# the cluster builders that bake specs/cluster — build-rpi5-stage4.sh (done here)
# and the PROTECTED build-x86-host-stage4.sh (flagged in PR #107). Nothing for the
# desktop client to render, so no _opt_render_installed_services exists here.
ENV="test"
CONFIG_FILE=""
DEFAULT_USER="frite"
# NO baked default password. Real creds come from the KEYS USB ($6$ hashes in
# users.json via keys-provision). On a keyless boot the first-boot finaliser
# (specs/etc/local.d/01-firstboot.start.tmpl) mints a RANDOM one-time password
# and locks root — see the OWASP "default creds baked into image" fix.

# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ──
# The Frite boards have NO onboard WiFi/Bluetooth, so these default OFF and only
# matter if a USB radio dongle is attached. Ethernet + the tailnet are unaffected.
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
# to the Pi5 client image so the Frite joins the same headscale/tailscale mesh.
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false

# --print-plan: resolve + validate everything, print the machine-greppable build
# plan (one PLAN_KEY=VALUE per line) and exit 0 BEFORE any mutation (no root, no
# disk writes, no network). The CLI/make/menu/Studio channels + the build-matrix
# harness (tests/build-matrix/check.sh) verify every role/flag combo through it.
PRINT_PLAN=false

# u-boot: the Frite needs a flashable u-boot built from mainline + Amlogic's
# proprietary FIP/BL31 blobs. We do NOT vendor those blobs here (licensing); the
# builder DOWNLOADS the prebuilt, board-specific Tow-Boot/u-boot image when a URL
# is given, else it WARNS and leaves a slot for the operator to drop one in.
FRITE_UBOOT_URL="${FRITE_UBOOT_URL:-}"          # optional: prebuilt board u-boot.bin URL
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
    build-frite-stage4.sh - Build a hardened Gentoo aarch64 LIGHT-DESKTOP image
    for the Libre Computer Le/La Frite family (Amlogic GXL), with LIVE +
    INSTALLER flavors, joined to the Snapdragon Tailscale mesh.

SYNOPSIS
    build-frite-stage4.sh [OPTIONS]

DESCRIPTION
    Cross-compiles a lean Gentoo desktop (LXDE-class, NOT Plasma+gaming) for the
    Amlogic S805X (La Frite) / S905X (Le Potato / Sweet Potato) SBCs, reusing the
    aarch64 cross path and the SHARED mesh + KEYS-USB provisioning engine. The
    image joins headscale/tailscale and honors the hardened, key-only SSH posture
    exactly like the Pi5/x86 client images.

OPTIONS
  Board
    --board NAME        la-frite (DEFAULT, S805X, AML-S805X-AC — both RAM SKUs),
                        le-potato (S905X, AML-S905X-CC),
                        sweet-potato (S905X, AML-S905X-CC-V2).
    -c, --cpu CPU       GCC -mcpu/-mtune (default cortex-a53 — all GXL boards).
    -d, --defconfig N   Kernel base defconfig (default: defconfig, mainline arm64).
    --dtb PATH          Override the in-tree DTB (e.g.
                        amlogic/meson-gxl-s805x-libretech-ac.dtb).
    --uboot-defconfig N u-boot defconfig (default per board, e.g. libretech-ac).
    --uboot-url URL     Prebuilt, FIP-signed board u-boot.bin to vendor into the
                        image (mainline u-boot alone is NOT flashable on GXL).
    --skip-uboot        Do not fetch/stage u-boot (you provide it separately).

  Flavor (the LIVE / INSTALLER toggle)
    --flavor F          live | installer | both (DEFAULT both).
                        live      = boots ephemerally off USB (La Frite) / SD.
                        installer = live image + install-frite.sh to write the
                                    desktop to onboard eMMC/SD.
    --live              shorthand for --flavor live.
    --installer         shorthand for --flavor installer.

  Desktop
    --desktop light|none   light (DEFAULT) = the LEAN LXDE desktop set;
                           none = headless base (no X) — base packages only.

  Branding / env / system  (same knobs as the other builders)
    --brand / --brand-title / --org / --cluster-domain / --env test|prod
    -H hostname / -T timezone / -u user
    (--user-password / --root-password are DEPRECATED no-ops: no password is
     baked in; keyless boot mints a random one-time password + locks root)
    -C, --config FILE   drop-in brand.conf profile (sourced; CLI overrides it).

  Image
    --img-size MiB      ext4 root size baked into the installer's stage4 (default 3072).
    --grow fill|none|<size>   first-boot grow policy (default fill).
    --compress          xz -9 the finished image(s).
    -p PKGS             extra packages appended to the stage4.

  Mesh / radios  (same as the Pi5 builder)
    --headscale-version / --tailscale-version / --skip-mesh / --skip-tailscale
    --enable-wifi / --enable-bluetooth   (off by default; the boards have no radio)

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
    # Default: La Frite, light desktop, BOTH live + installer
    ./build-frite-stage4.sh

    # Le Potato (the pricier S905X sibling), live image only
    ./build-frite-stage4.sh --board le-potato --flavor live

    # La Frite, brand it, vendor a prebuilt FIP-signed u-boot
    ./build-frite-stage4.sh --brand acme --cluster-domain acme.example \
        --uboot-url https://example/u-boot-amls805x.bin

NOTES
    La Frite (AML-S805X-AC) has NO microSD slot: the LIVE root runs off USB and
    the INSTALLER targets the eMMC module. Le Potato / Sweet Potato DO have SD.
    The 512MB and 1GB La Frite RAM SKUs are the SAME image (RAM auto-detected);
    the 512MB SKU leans on the zram swap configured at first boot.

    u-boot on Amlogic GXL needs proprietary FIP/BL31 blobs to be flashable —
    mainline u-boot alone is not. Provide a prebuilt board image via --uboot-url
    (e.g. a Tow-Boot release) or drop one into the staged boot tree afterwards.
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
        --board)              FRITE_BOARD="$2";           shift 2 ;;
        -c|--cpu)             RPI_CPU="$2";               shift 2 ;;
        -d|--defconfig)       FRITE_DEFCONFIG="$2";       shift 2 ;;
        --dtb)                FRITE_DTB="$2";             shift 2 ;;
        --uboot-defconfig)    FRITE_UBOOT_DEFCONFIG="$2"; shift 2 ;;
        --uboot-url)          FRITE_UBOOT_URL="$2";       shift 2 ;;
        --skip-uboot)         SKIP_UBOOT=true;            shift   ;;
        --flavor)             FRITE_FLAVOR="$2";          shift 2 ;;
        --live)               FRITE_FLAVOR="live";        shift   ;;
        --installer)          FRITE_FLAVOR="installer";   shift   ;;
        --desktop)            DESKTOP="$2";               shift 2 ;;
        -v|--version)         REL_VERSION="$2";           shift 2 ;;
        --seed-url)           SEED_STAGE3_URL="$2";       shift 2 ;;
        -H|--hostname)        HOSTNAME="$2";              shift 2 ;;
        -r|--role)            ROLE="$2";                  shift 2 ;;
        -C|--config)          CONFIG_FILE="$2";           shift 2 ;;  # sourced above
        --env)                ENV="$2";                   shift 2 ;;
        --cluster-domain|--domain) CLUSTER_DOMAIN="$2";   shift 2 ;;
        --brand)              BRAND="$2";                 shift 2 ;;
        --brand-title)        BRAND_TITLE="$2";           shift 2 ;;
        --org)                ORG="$2";                   shift 2 ;;
        -T|--timezone)        TIMEZONE="$2";              shift 2 ;;
        -u|--user)            DEFAULT_USER="$2";          shift 2 ;;
        # DEPRECATED no-ops: images no longer bake a fallback password (random
        # one-time password is minted at first boot; real creds come from KEYS).
        --user-password)      warn "--user-password is ignored: no password is baked into the image (random first-boot fallback + KEYS provisioning)"; shift 2 ;;
        --root-password)      warn "--root-password is ignored: root is locked on keyless boot; set root via the KEYS USB users.json hash"; shift 2 ;;
        -p|--extra-packages)  EXTRA_PACKAGES="$2";        shift 2 ;;
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

# ── select_board: map --board to its DTB / defconfigs / media policy ──
# Only fills values the operator did NOT set on the CLI (they are empty unless a
# flag set them), so an explicit --cpu/--dtb/--uboot-defconfig always wins.
select_board() {
    local cpu dtb uboot desc has_sd
    case "${FRITE_BOARD}" in
        la-frite)
            cpu="cortex-a53"; dtb="amlogic/meson-gxl-s805x-libretech-ac.dtb"
            uboot="libretech-ac_defconfig"; has_sd=false
            desc="Libre Computer La Frite (AML-S805X-AC, Amlogic S805X)"
            ;;
        le-potato)
            cpu="cortex-a53"; dtb="amlogic/meson-gxl-s905x-libretech-cc.dtb"
            uboot="libretech-cc_defconfig"; has_sd=true
            desc="Libre Computer Le Potato (AML-S905X-CC, Amlogic S905X)"
            ;;
        sweet-potato)
            cpu="cortex-a53"; dtb="amlogic/meson-gxl-s905x-libretech-cc-v2.dtb"
            uboot="libretech-cc-v2_defconfig"; has_sd=true
            desc="Libre Computer Sweet Potato (AML-S905X-CC-V2, Amlogic S905X)"
            ;;
        *) err "--board must be one of: la-frite | le-potato | sweet-potato (got '${FRITE_BOARD}')"; exit 1 ;;
    esac
    [ -z "${RPI_CPU}" ]               && RPI_CPU="${cpu}"
    [ -z "${FRITE_DTB}" ]             && FRITE_DTB="${dtb}"
    [ -z "${FRITE_UBOOT_DEFCONFIG}" ] && FRITE_UBOOT_DEFCONFIG="${uboot}"
    FRITE_BOARD_DESC="${desc}"
    FRITE_HAS_SD="${has_sd}"
}
select_board

# ── Validate flavor / desktop / env / grow ─────────────────────────
case "${FRITE_FLAVOR}" in
    live|installer|both) ;;
    *) err "--flavor must be: live | installer | both (got '${FRITE_FLAVOR}')"; exit 1 ;;
esac
case "${DESKTOP}" in
    light|none) ;;
    *) err "--desktop must be: light | none (got '${DESKTOP}')"; exit 1 ;;
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
case "${FRITE_FLAVOR}" in
    live)      BUILD_LIVE=true ;;
    installer) BUILD_INSTALLER=true ;;
    both)      BUILD_LIVE=true; BUILD_INSTALLER=true ;;
esac

# La Frite has no SD: surface the live-off-USB reality (informational, not fatal).
if [ "${FRITE_HAS_SD}" = "false" ] && ${BUILD_LIVE}; then
    info "La Frite has NO microSD slot — the LIVE image boots off USB (u-boot in SPI NOR)."
fi

if [ -z "${HOSTNAME}" ]; then
    case "${ROLE}" in
        desktop|generic) HOSTNAME="${BRAND}-frite" ;;
        *)               HOSTNAME="${BRAND}-${ROLE}" ;;
    esac
fi

# ── Charset allowlists for brand/identity/kernel/toolchain fields (fail-closed) ──
# (mirrors build-rpi5-stage4.sh) These values come from CLI flags or a sourced
# brand.conf and flow into render_template's sed program (build of make.conf,
# 01-firstboot.start, extlinux.conf) and into rebrand_sysroot's `sed -i` over the
# baked /etc/snapdragon tree — and RPI_CPU/CROSS_TARGET land in make.conf, which
# portage SOURCES as shell on the (root) build host. The rendered first-boot
# script runs useradd/chpasswd with DEFAULT_USER as ROOT on the device. Reject
# anything outside a strict charset at this earliest boundary so a value carrying
# sed/shell metacharacters, a quote, or a newline can never reach a render sink or
# a sourced KEY=VALUE file. Escaping at the render sink (_sed_rep_escape) is
# defense-in-depth on top of this. Each regex below ACCEPTS every legitimate
# default (brand=snapdragon, org=Snapdragon-Systems, domain=snapdragon.systems,
# user=frite, cpu=cortex-a53, target=aarch64-unknown-linux-gnu, title
# "Snapdragon Systems"); HOSTNAME is derived from the validated brand above.
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
_require_match "--hostname"       "${HOSTNAME}"       "${_RE_DNS}"
_require_match "--user"           "${DEFAULT_USER}"   "${_RE_USER}"
_require_match "--brand-title"    "${BRAND_TITLE}"    "${_RE_TITLE}"
_require_match "--cpu"            "${RPI_CPU}"        "${_RE_CPU}"
_require_match "--target"         "${CROSS_TARGET}"   "${_RE_TRIPLET}"

BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"
SYSROOT="${BUILD_ROOT}/sysroot"
STAGE_DIR="${BUILD_ROOT}/staging"     # boot tree + ISO/installer staging
LOG_FILE="${WORK_DIR}/build.log"
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Image / artifact name prefix (board in the name so flash-disk autodetect works).
ART_PREFIX="${BRAND}-frite-${FRITE_BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}"

if [ "${ENV}" = "prod" ]; then
    echo -e "${RED}${BOLD}"
    echo "############################################################################"
    echo "##   BUILDING PROD Frite image for ${CLUSTER_DOMAIN}"
    echo "##   - bakes the REAL public domain; mesh/Casdoor creds from the keys USB ##"
    echo "############################################################################"
    echo -e "${RESET}"
else
    info "Build ENV: test (LAN-first; mesh + Casdoor login provisioned from the KEYS USB)"
fi
info "Board: ${FRITE_BOARD_DESC}"
info "DTB:   ${FRITE_DTB}   u-boot: ${FRITE_UBOOT_DEFCONFIG}"
info "Flavor: ${FRITE_FLAVOR}  (live=${BUILD_LIVE} installer=${BUILD_INSTALLER})  Desktop: ${DESKTOP}"
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

# ── Template helper (mirrors the Pi5 render_template) ──────────────
# All brand/domain/identity/kernel substitutions go through _sed_rep_escape so a
# value carrying sed metacharacters cannot corrupt or inject into the s-program.
render_template() {
    local src="$1" dst="$2"
    local cbuild
    cbuild="$(portageq envvar CHOST 2>/dev/null || gcc -dumpmachine)"
    sed \
        -e "s|@@CBUILD@@|$(_sed_rep_escape "${cbuild}")|g" \
        -e "s|@@CROSS_TARGET@@|$(_sed_rep_escape "${CROSS_TARGET}")|g" \
        -e "s|@@RPI_CPU@@|$(_sed_rep_escape "${RPI_CPU}")|g" \
        -e "s|@@JOBS@@|$(_sed_rep_escape "${JOBS}")|g" \
        -e "s|@@WORK_DIR@@|$(_sed_rep_escape "${BUILD_ROOT}")|g" \
        -e "s|@@FRITE_KERNEL_IMG@@|$(_sed_rep_escape "${FRITE_KERNEL_IMG}")|g" \
        -e "s|@@FRITE_DTB@@|$(_sed_rep_escape "${FRITE_DTB}")|g" \
        -e "s|@@FRITE_INITRD_LINE@@|$(_sed_rep_escape "${FRITE_INITRD_LINE:-#}")|g" \
        -e "s|@@FRITE_APPEND@@|$(_sed_rep_escape "${FRITE_APPEND:-}")|g" \
        -e "s|@@HOSTNAME@@|$(_sed_rep_escape "${HOSTNAME}")|g" \
        -e "s|@@TIMEZONE@@|$(_sed_rep_escape "${TIMEZONE}")|g" \
        -e "s|@@DEFAULT_USER@@|$(_sed_rep_escape "${DEFAULT_USER}")|g" \
        -e "s|@@BRAND@@|$(_sed_rep_escape "${BRAND}")|g" \
        -e "s|@@BRAND_TITLE@@|$(_sed_rep_escape "${BRAND_TITLE}")|g" \
        -e "s|@@DOMAIN@@|$(_sed_rep_escape "${CLUSTER_DOMAIN}")|g" \
        -e "s|@@ORG@@|$(_sed_rep_escape "${ORG}")|g" \
        -e "s|@@ENV@@|$(_sed_rep_escape "${ENV}")|g" \
        "${src}" > "${dst}"
}

# ── harden_radios (identical posture to the Pi5 builder) ───────────
# WiFi + Bluetooth OFF by default. The Frite boards have no onboard radio, so
# this only matters for a USB dongle; Ethernet + the tailnet are never touched.
harden_radios() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/modprobe.d" "${sysroot}/etc/local.d" \
             "${sysroot}/etc/NetworkManager/conf.d"
    local bl="${sysroot}/etc/modprobe.d/snapdragon-radio-blacklist.conf"; : > "${bl}"
    local act="${sysroot}/etc/local.d/02-radio-hardening.start"
    {
        echo "#!/bin/sh"
        echo "# Radio hardening (build-frite-stage4.sh). WiFi/Bluetooth OFF by default."
        echo "command -v rfkill >/dev/null 2>&1 || exit 0"
    } > "${act}"
    if [ "${ENABLE_WIFI}" != "true" ]; then
        { echo "blacklist cfg80211"; echo "blacklist mac80211"; } >> "${bl}"
        { echo "rfkill block wifi 2>/dev/null || true"
          echo "command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off 2>/dev/null || true"; } >> "${act}"
        printf '[main]\n# WiFi off by default; managed=ethernet only.\n' \
            > "${sysroot}/etc/NetworkManager/conf.d/10-no-wifi.conf"
        info "WiFi DISABLED by default (the boards have no onboard radio). Re-enable: --enable-wifi."
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

# Configure a small zram swap at first boot (the 512MB La Frite SKU leans on it).
write_zram_firstboot() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/local.d"
    cat > "${sysroot}/etc/local.d/03-zram-swap.start" <<'ZRAM_EOF'
#!/bin/sh
# zram swap — sized to half of RAM, capped at 512M. Benefits the 512MB La Frite
# SKU most; harmless on the 1GB SKU. Idempotent; best-effort (no zram = skip).
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
    local _btitle _org _domain _brand
    _btitle="$(_sed_rep_escape "${BRAND_TITLE}")"
    _org="$(_sed_rep_escape "${ORG}")"
    _domain="$(_sed_rep_escape "${CLUSTER_DOMAIN}")"
    _brand="$(_sed_rep_escape "${BRAND}")"
    local f
    while IFS= read -r -d '' f; do
        sed -i \
            -e "s|Snapdragon Systems|${_btitle}|g" \
            -e "s|Snapdragon-Systems|${_org}|g" \
            -e "s|snapdragon\.systems|${_domain}|g" \
            -e "s|snapdragon-|${_brand}-|g" \
            "${f}"
    done < <(find "${SYSROOT}/etc/snapdragon" -type f -print0 2>/dev/null)
}

# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation ──────────
# Runs AFTER full arg parsing / board+flavor+env validation / allowlist checks /
# artifact resolution, but BEFORE the prereq probes, mkdir, tee-redirect, network
# fetches or any sysroot write. No root required. One stable KEY=VALUE per line
# (grep '^PLAN_'); exit 0. Invalid role/flag combos never reach this point — the
# validation above already exited non-zero, which is exactly what the
# tests/build-matrix harness relies on. NO secrets are echoed here.
if ${PRINT_PLAN}; then
    _plan() { printf 'PLAN_%s=%s\n' "$1" "$2"; }
    _plan BUILDER            "build-frite-stage4.sh"
    _plan PLATFORM           "frite"
    _plan ARCH               "arm64"
    _plan ROLE               "${ROLE}"
    _plan ENV                "${ENV}"
    _plan BOARD              "${FRITE_BOARD}"
    _plan BOARD_DESC         "${FRITE_BOARD_DESC}"
    _plan DTB                "${FRITE_DTB}"
    _plan UBOOT_DEFCONFIG    "${FRITE_UBOOT_DEFCONFIG}"
    _plan FLAVOR             "${FRITE_FLAVOR}"
    _plan DESKTOP            "${DESKTOP}"
    _plan GPU_DRIVER         "lima"   # Amlogic GXL Mali-450 → mainline lima (fixed for this platform)
    _ARTS="stage4.tar.xz"
    ${BUILD_LIVE}      && _ARTS="${_ARTS},live.iso"
    ${BUILD_INSTALLER} && _ARTS="${_ARTS},installer.iso"
    _plan ARTIFACTS          "${_ARTS}"
    _plan ARTIFACT_PREFIX    "${BRAND}-frite-${FRITE_BOARD}-arm64-${ROLE}-${ENV}-<timestamp>"
    _plan WORK_DIR           "${WORK_DIR}"
    _plan JOBS               "${JOBS}"
    _plan BRAND              "${BRAND}"
    _plan CLUSTER_DOMAIN     "${CLUSTER_DOMAIN}"
    _plan HOSTNAME           "${HOSTNAME}"
    _plan OPTIONAL_SERVICES  "none"   # lean desktop client: no baked cluster tree
    _plan MESH               "$(${SKIP_MESH} && echo skip || echo "headscale=${HEADSCALE_VERSION},tailscale=$(${SKIP_TAILSCALE} && echo skip || echo "${TAILSCALE_VERSION}")")"
    _plan KERNEL             "mainline-arm64 (defconfig=${FRITE_DEFCONFIG} + hardened-desktop.config)"
    _plan FLAGS_EFFECTIVE    "env=${ENV} board=${FRITE_BOARD} flavor=${FRITE_FLAVOR} desktop=${DESKTOP} img_size=${ROOT_MiB} grow=${GROW_POLICY} compress=${COMPRESS_IMG} resume=${RESUME} skip_kernel=${SKIP_KERNEL} skip_uboot=${SKIP_UBOOT} skip_mesh=${SKIP_MESH} skip_tailscale=${SKIP_TAILSCALE} permit_root_login=${PERMIT_ROOT_LOGIN} enable_wifi=${ENABLE_WIFI} enable_bluetooth=${ENABLE_BLUETOOTH}"
    exit 0
fi

banner "Verifying prerequisites"
[ -d "${SPECS_DIR}" ]    || { err "Frite specs directory not found: ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Shared specs directory not found: ${SHARED_SPECS}"; exit 1; }
info "Frite specs:  ${SPECS_DIR}"
info "Shared specs: ${SHARED_SPECS}"
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    command -v "${tool}" &>/dev/null || { err "${tool} not found in PATH."; exit 1; }
done
# Host SELinux policy build tools (same rationale as the Pi5 builder: selinux-base
# src_compile uses the HOST checkpolicy/semodule_package; cross copies can't run).
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
# package.provided: skip Rust-based packages that can't cross-compile to aarch64
# without the aarch64-unknown-linux-gnu stdlib target (absent from system rust).
[ -f "${SPECS_DIR}/portage/profile/package.provided" ] && \
    cp "${SPECS_DIR}/portage/profile/package.provided" "${SYSROOT}/etc/portage/profile/package.provided"
cp "${SPECS_DIR}/portage/package.accept_keywords/"* "${SYSROOT}/etc/portage/package.accept_keywords/"
cp "${SPECS_DIR}/portage/package.use/"*             "${SYSROOT}/etc/portage/package.use/"
cp "${SPECS_DIR}/portage/package.env/"*             "${SYSROOT}/etc/portage/package.env/"
cp "${SPECS_DIR}/portage/env/"*.conf               "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"

cp "${SPECS_DIR}/etc/fstab" "${SYSROOT}/etc/fstab"

# ── Shared (arch-agnostic) mesh + provisioning + sshd — the SAME plumbing the
# Pi5/x86 client images use, so the Frite joins the SAME mesh with the SAME
# key-only SSH + device-license posture. ────────────────────────────
mkdir -p "${SYSROOT}/etc/init.d"
for svc in growroot headscale tailscaled keys-provision; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"
    chmod +x "${SYSROOT}/etc/init.d/${svc}"
done
write_growfs_conf "${SYSROOT}/etc/growfs.conf"

mkdir -p "${SYSROOT}/etc/headscale"
cp "${SHARED_SPECS}/etc/headscale/config.yaml"   "${SYSROOT}/etc/headscale/config.yaml"
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
# Same INERT-on-core plumbing the Pi5/x86 images bake: provision_device_registry()
# ACTIVATES it only when owner_type=ADMIN, so a SUPERADMIN/core Frite keeps the #66
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
# The SAME poller the Pi5/x86 images bake: keeps a client device's binaries fresh
# from the tailnet binhost over the VPN. provision_update() bakes the /etc/cron.d
# cadence timer + the boot oneshot is linked into the default runlevel below, but
# the poller is DEFAULT-OFF / INERT: it does NOTHING until a superadmin opts in by
# setting enabled:true in the snapdragon-update-policy ConfigMap (fail-safe-to-OFF —
# an absent/unreachable policy means NO pull). cronie + OpenRC (not systemd).
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-update"     "${SYSROOT}/usr/local/sbin/snapdragon-update"
chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-update"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-update"         "${SYSROOT}/etc/init.d/snapdragon-update"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-update"
# ── Domain-registry -> brand-repo bridge (#4) — DEFAULT-OFF, baked-but-INERT ─────
# Bake the reconcile agent + its verify lib (domain-verify.sh) + the OpenRC service
# + the two generators for PARITY with the rpi5/x86 host images. Frite is a
# single-board appliance, NOT a k8s cluster node (it bakes no cluster GitOps tree)
# and has no _opt_selected gate, so — exactly like the egress-VPN reconcile above —
# the agent is NEVER linked into a runlevel here (inert-by-omission). REUSES the
# baked registry-pub.ed25519 (never re-bake). Even if hand-enabled it fail-closes
# without a real key + transport, and with no cluster there is nothing to drive.
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
echo "${ENV}"            > "${SYSROOT}/etc/snapdragon/env"
echo "frite:${FRITE_BOARD}" > "${SYSROOT}/etc/snapdragon/board"
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/snapdragon/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/snapdragon/headscale-url"
fi
rebrand_sysroot

# First-boot finaliser (shared template) + radio hardening + zram swap.
# Rendered UNCONDITIONALLY (like the rpi5/x86 siblings): the finaliser is what
# wires up first-boot provisioning, so a missing template is a hard error rather
# than a silently-skipped image that never finalises.
mkdir -p "${SYSROOT}/etc/local.d"
[ -f "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" ] || {
    err "missing first-boot finaliser template: ${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl"; exit 1; }
render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"
harden_radios "${SYSROOT}"

# Root SSH login DISABLED by default (hardened). Authoritative sshd drop-in (00- prefix
# => sshd takes the FIRST PermitRootLogin) from PERMIT_ROOT_LOGIN (no | prohibit-password |
# yes; default no). hardened.conf 'PermitRootLogin no' stays a fail-safe backstop; the
# non-root KEYS admin user is the entry point, so this never bricks a node.
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
        info "Root SSH login DISABLED by default. Admin via the non-root KEYS user; re-enable with --permit-root-login yes."
    else
        info "Root SSH login set to '${val}' (--permit-root-login / PERMIT_ROOT_LOGIN=${val})."
    fi
}
configure_root_login "${SYSROOT}"
write_zram_firstboot "${SYSROOT}"

echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"
echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${SYSROOT}/etc/localtime"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"

# OpenRC service links — mesh + provisioning everywhere; the desktop session is
# started by the display manager (lightdm) when --desktop light.
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
if [ "${DESKTOP}" = "light" ]; then
    # lightdm + its greeter + a modern X session need a running system bus (dbus)
    # and a seat/login manager (elogind), plus the display-manager OpenRC service.
    # Without dbus+elogind the greeter/session bring-up is unreliable.
    DEFAULT_SVCS+=(dbus elogind display-manager)
    # gui-libs/display-manager-init's /etc/init.d/display-manager reads this conf to
    # decide WHICH DM to launch; lightdm ships no OpenRC service of its own. Without
    # it the service falls back to xdm and the image boots to a bare console / wrong
    # greeter (the packages-light-desktop.list comment promised the builder writes it
    # but nothing did). Keeps dbus+elogind (superset of the parallel main fix).
    mkdir -p "${SYSROOT}/etc/conf.d"
    echo 'DISPLAYMANAGER="lightdm"' > "${SYSROOT}/etc/conf.d/display-manager"
    # Wire the greeter + default session explicitly: with only lightdm-gtk-greeter
    # installed the stock greeter-session (example-gtk-gnome) is absent → blank
    # greeter. openbox is the light session. (CONFIG_PROTECT keeps this pre-emerge.)
    mkdir -p "${SYSROOT}/etc/lightdm"
    cat > "${SYSROOT}/etc/lightdm/lightdm.conf" <<'LIGHTDM'
[LightDM]
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=LXDE
LIGHTDM
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

# Don't cross-rebuild the toolchain (fails under crossdev). Same as the Pi5 build.
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
if [ "${DESKTOP}" = "light" ]; then
    info "Light desktop selected — appending packages-light-desktop.list"
    mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
        grep -v '^\s*#' "${SPECS_DIR}/portage/packages-light-desktop.list" | grep -v '^\s*$')
fi
# LIVE *and* INSTALLER flavors: pull in sys-kernel/dracut so the builder can
# generate a dmsquash-live initramfs (the bare kernel cannot mount
# root=live:/rd.live.* — that is a dracut job). The INSTALLER medium is itself a
# LIVE boot (it must come up so the operator can run install-frite.sh — see
# install-frite.sh's own header), so it needs the same initramfs. dracut stays out
# of the always-installed base set and is added here for both bootable flavors.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    info "Bootable flavor selected — appending packages-live.list (dracut for the live initramfs)"
    mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
        grep -v '^\s*#' "${SPECS_DIR}/portage/packages-live.list" | grep -v '^\s*$')
fi
if [ -n "${EXTRA_PACKAGES}" ]; then
    read -ra _extras <<< "${EXTRA_PACKAGES}"
    STAGE4_PACKAGES+=("${_extras[@]}")
    info "Extra packages: ${EXTRA_PACKAGES}"
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
# Base payload (always required): networking + login + base utils.
REQUIRED_BINS=(NetworkManager nmcli sshd nano)
# Light desktop: the display server + LXDE session + the lightdm display manager
# (the runlevel enables `display-manager` only when DESKTOP=light — see above).
if [ "${DESKTOP}" = "light" ]; then
    REQUIRED_BINS+=(Xorg openbox lxsession pcmanfm lightdm)
fi
# Bootable flavors (LIVE or INSTALLER): dracut must be present to GENERATE the
# dmsquash-live initramfs that both media boot from.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    REQUIRED_BINS+=(dracut)
fi
payload_missing=""
for _b in "${REQUIRED_BINS[@]}"; do
    have_in_sysroot "${_b}" || payload_missing="${payload_missing} ${_b}"
done
if [ -n "${payload_missing}" ]; then
    err "stage4 payload incomplete — missing role-defining binaries in ${SYSROOT}:${payload_missing}"
    err "       the packages.list/light-desktop emerge did not complete; review the emerge output above."
    exit 1
fi
# display-manager OpenRC service: enabled in the runlevel for DESKTOP=light, so the
# init script (from gui-libs/display-manager-init) MUST exist or the image boots to
# a console with a dead service link. Assert it now that the desktop set emerged.
if [ "${DESKTOP}" = "light" ] && [ ! -e "${SYSROOT}/etc/init.d/display-manager" ]; then
    err "DESKTOP=light enables the 'display-manager' service but ${SYSROOT}/etc/init.d/display-manager is missing"
    err "       (gui-libs/display-manager-init did not emerge) — the desktop would boot to a console. Aborting."
    exit 1
fi
info "stage4 payload assert OK (${#REQUIRED_BINS[@]} role binaries present)."

# ── 7. Install mesh VPN (headscale + tailscale) — same as Pi5 ─────
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
    # Fetch failure is FATAL (mirrors x86/rpi5): the image bakes mesh plumbing and
    # this is the only place the binary is staged — a network blip must NOT silently
    # ship a mesh-less image. Opt out explicitly with --skip-mesh.
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
        # Both binaries MUST be aarch64 (mirrors x86/rpi5) — only after this is the
        # tailscaled runlevel link backed by a real, correct-arch binary.
        file "${SYSROOT}/usr/bin/tailscale"   | grep -q 'ELF.*aarch64' || { err "tailscale binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
        file "${SYSROOT}/usr/sbin/tailscaled" | grep -q 'ELF.*aarch64' || { err "tailscaled binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
        info "tailscale installed + sha256-verified: /usr/bin/tailscale, /usr/sbin/tailscaled"
    fi
fi

fi  # IMAGE_ONLY skip of Phase 1+2

# ── 8. Cross-compile the kernel (mainline; ship the Amlogic DTB) ──
# FRITE_KVER is captured here (from `make kernelrelease`) so Phase 4 can point
# dracut --kver at the EXACT module tree this build installs under
# ${SYSROOT}/lib/modules/. Empty if the kernel is skipped/unbuilt.
FRITE_KVER=""
if ${SKIP_KERNEL}; then
    banner "Phase 3: SKIPPED (--skip-kernel)"
else
    banner "Phase 3: Cross-compiling hardened kernel"
    KERNEL_SRC=$(find "${SYSROOT}/usr/src/" -maxdepth 1 -name 'linux-*' -type d 2>/dev/null | sort -V | tail -1)
    if [ -z "${KERNEL_SRC}" ]; then
        warn "No kernel sources found in sysroot — ensure sys-kernel/gentoo-sources installed. Skipping kernel."
    else
        info "Building kernel from ${KERNEL_SRC} (defconfig: ${FRITE_DEFCONFIG}, CPU: ${RPI_CPU})"
        pushd "${KERNEL_SRC}" >/dev/null
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" "${FRITE_DEFCONFIG}"
        # merge_config.sh properly handles Kconfig dependency resolution when
        # adding options absent from the base defconfig (unlike scripts/config +
        # olddefconfig which silently drops symbols whose selections/selects
        # haven't been evaluated yet in the defconfig ordering).
        ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" \
            bash scripts/kconfig/merge_config.sh -m .config "${SPECS_DIR}/kernel/hardened-desktop.config"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" olddefconfig
        # Refuse to ship a kernel that silently lost SELinux (fleet posture guard).
        for must in CONFIG_SECURITY_SELINUX CONFIG_SECURITY_SELINUX_BOOTPARAM; do
            grep -q "^${must}=y" .config || { err "SELinux kernel option ${must} not enabled after olddefconfig"; exit 1; }
        done
        grep -q '^CONFIG_LSM="yama,selinux,bpf"$' .config || { err "CONFIG_LSM malformed (expected yama,selinux,bpf)"; exit 1; }
        # The kernelrelease string is the module-tree dir name (lib/modules/<kver>),
        # which dracut needs as --kver for the live initramfs.
        FRITE_KVER="$(make -s ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" kernelrelease 2>/dev/null | tail -1)"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" -j"${JOBS}" Image modules dtbs
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" INSTALL_MOD_PATH="${SYSROOT}" modules_install
        mkdir -p "${SYSROOT}/boot/dtb/amlogic"
        cp arch/arm64/boot/Image "${SYSROOT}/boot/${FRITE_KERNEL_IMG}"
        # Ship the FULL Amlogic DTB tree (the board DTB is selected by extlinux's
        # FDT line). On La Frite (kernel >=5.8) the kernel's OWN DTB is mandatory.
        cp -r arch/arm64/boot/dts/amlogic "${SYSROOT}/boot/dtb/" 2>/dev/null || \
            cp arch/arm64/boot/dts/amlogic/*.dtb "${SYSROOT}/boot/dtb/amlogic/" 2>/dev/null || true
        # The board FDT is MANDATORY on Amlogic GXL (kernel >=5.8): extlinux's FDT
        # line points at it and the board will NOT boot without it. We just built the
        # kernel, so a missing DTB is a hard error, not a warning.
        if [ ! -f "${SYSROOT}/boot/dtb/${FRITE_DTB}" ]; then
            err "Selected DTB ${FRITE_DTB} not found under ${SYSROOT}/boot/dtb after the kernel build — the board would not boot. Verify the in-tree DTB name for this kernel."
            exit 1
        fi
        popd >/dev/null
        info "Kernel build complete (Image + Amlogic DTBs staged under /boot)."
    fi
fi

# ── 9. u-boot for the board (needs Amlogic FIP/BL31 — see notes) ──
if ${SKIP_UBOOT}; then
    banner "Phase 3.5: SKIPPED u-boot (--skip-uboot)"
else
    banner "Phase 3.5: Staging u-boot (${FRITE_UBOOT_DEFCONFIG})"
    mkdir -p "${STAGE_DIR}/uboot"
    if [ -n "${FRITE_UBOOT_URL}" ]; then
        if curl -fL -o "${STAGE_DIR}/uboot/u-boot.bin" "${FRITE_UBOOT_URL}"; then
            info "u-boot staged from ${FRITE_UBOOT_URL} -> ${STAGE_DIR}/uboot/u-boot.bin"
        else
            warn "Could not fetch u-boot from ${FRITE_UBOOT_URL}; image will have no bootloader staged."
        fi
    else
        warn "No --uboot-url given. Amlogic GXL u-boot needs proprietary FIP/BL31 blobs to be"
        warn "flashable — mainline u-boot alone is NOT. Provide a prebuilt, signed board image"
        warn "(e.g. a Tow-Boot release for ${FRITE_BOARD}) via --uboot-url, or drop one into"
        warn "${STAGE_DIR}/uboot/ before flashing. (La Frite: u-boot lives in SPI NOR.)"
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
if [ -f "${SYSROOT}/boot/${FRITE_KERNEL_IMG}" ]; then
    cp "${SYSROOT}/boot/${FRITE_KERNEL_IMG}" "${BOOT_STAGE}/"
    cp -r "${SYSROOT}/boot/dtb/." "${BOOT_STAGE}/dtb/" 2>/dev/null || true
else
    warn "Kernel ${FRITE_KERNEL_IMG} not in sysroot — the boot tree will be incomplete."
fi

# ── 11b. Build the LIVE dmsquash-live initramfs (the boot fix) ─────
# WHY: the LIVE flavor's cmdline uses dracut directives — root=live:LABEL=...,
# rd.live.dir=/LiveOS, rd.live.squashimg=squashfs.img. Those are interpreted by a
# dracut dmsquash-live initramfs, NOT by a bare kernel. Without an INITRD the
# kernel would never find/mount the squashfs as the ephemeral overlay root and
# the LIVE image would be UNBOOTABLE. So for the LIVE flavor we GENERATE a real
# initramfs here (dmsquash-live module) and stage it next to the kernel; the
# extlinux render then emits the matching `INITRD /initrd.img` line. The INSTALLER
# flavor boots a real partitioned root (root=LABEL=FRITE_ROOT) and gets NO live
# initramfs — see build_installer_iso (it leaves FRITE_INITRD a comment).
#
# Cross-build note (NEEDS-HARDWARE to fully confirm): dracut is a POSIX-sh/python
# generator, so we run it as a HOST tool pointed at the aarch64 SYSROOT's module
# tree (the tools it packs INTO the initramfs are the target's own aarch64
# binaries, which is correct). We prefer the sysroot's own dracut script, falling
# back to a host dracut with --kmoddir. This is structurally validated here
# (bash -n, arg shape) but the actual cross-generated initramfs can only be
# proven to boot on a real La Frite board with a full Gentoo cross-build.
FRITE_LIVE_INITRD=""        # set non-empty once the live initramfs is staged
build_live_initramfs() {
    [ -f "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" ] || {
        warn "no kernel in boot stage — cannot build the live initramfs; LIVE image will NOT boot."
        return 1; }
    # Resolve the kernel module dir to target. Prefer the captured kernelrelease;
    # otherwise fall back to the single module tree modules_install just created.
    local kver="${FRITE_KVER}"
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

    # ── Strategy 1: qemu-chroot (correct for cross-builds) ─────────────────────
    # binfmt_misc + qemu-aarch64 lets us chroot into the aarch64 sysroot and run
    # dracut natively — the result is a correct aarch64 initramfs without a real
    # board. Requires qemu-user registered in binfmt_misc for aarch64.
    local _qemu_interp
    _qemu_interp="$(grep '^interpreter' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null | awk '{print $2}')"
    if [ -n "${_qemu_interp}" ] && [ -x "${_qemu_interp}" ] && [ -x "${sysroot_dracut}" ]; then
        local _mounts=() _qemu_staged=false
        _frite_umount() {
            local m
            for m in "${_mounts[@]}"; do umount -l "${m}" 2>/dev/null || true; done
            # Remove the host qemu binary we staged inside the sysroot (if any).
            ${_qemu_staged} && rm -f "${SYSROOT}${_qemu_interp}" 2>/dev/null || true
        }
        trap '_frite_umount' RETURN
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
        chroot "${SYSROOT}" /usr/bin/dracut --force --no-hostonly \
            --kver "${kver}" --modules "${mods}" /boot/initrd.img 2>&1 | head -60
        if [ -s "${SYSROOT}/boot/initrd.img" ]; then
            cp "${SYSROOT}/boot/initrd.img" "${out}"
            FRITE_LIVE_INITRD="${out}"
            _frite_umount; trap - RETURN
            info "Live initramfs staged (qemu-chroot): ${out} ($(du -h "${out}" | cut -f1))"
            return 0
        fi
        warn "qemu-chroot dracut did not produce an initramfs; falling back."
        _frite_umount; trap - RETURN
    fi

    # ── Strategy 2: run the sysroot dracut script on the host sh ───────────────
    # Dracut is a bash script; running it on the host works only if it doesn't
    # need to exec aarch64 binaries from the sysroot. Usually fails silently.
    if [ -x "${sysroot_dracut}" ] && command -v sh >/dev/null; then
        sh "${sysroot_dracut}" --force --no-hostonly \
            --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            --modules "${mods}" "${out}" 2>/dev/null && [ -s "${out}" ] && {
                FRITE_LIVE_INITRD="${out}"
                info "Live initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce an initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            --modules "${mods}" "${out}" 2>/dev/null && [ -s "${out}" ] && {
                FRITE_LIVE_INITRD="${out}"
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
    # The LIVE flavor: a bootable medium (USB on La Frite, SD on Le Potato) that
    # runs the rootfs ephemerally from a squashfs in RAM. We stage:
    #   /  Image, /dtb/..., /extlinux/extlinux.conf  (boot tree)
    #   /  LiveOS/squashfs.img                        (the rootfs)
    # u-boot (SPI/SD) + extlinux find squashfs.img and the kernel mounts it
    # read-only with an overlay (kernel has SQUASHFS + OVERLAY_FS + LOOP).
    if ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        warn "mksquashfs/tar2sqfs missing — skipping LIVE image."; return 0
    fi
    [ -f "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" ] || { warn "no kernel in boot stage — skipping LIVE image."; return 0; }

    # The LIVE flavor is unbootable without the dmsquash-live initramfs (the
    # cmdline below is all dracut directives). Refuse to package a LIVE image that
    # has no initramfs rather than ship a known-dead boot.
    if [ -z "${FRITE_LIVE_INITRD}" ] || [ ! -s "${FRITE_LIVE_INITRD}" ]; then
        warn "No live initramfs was generated (Phase 4 §11b). The LIVE image would NOT"
        warn "boot (root=live:/rd.live.* need a dracut dmsquash-live initramfs). Skipping"
        warn "the LIVE image. Build with dracut available, or use --flavor installer."
        return 0
    fi

    local live_root="${STAGE_DIR}/live"
    rm -rf "${live_root}"; mkdir -p "${live_root}/LiveOS" "${live_root}/extlinux" "${live_root}/dtb"
    cp "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" "${live_root}/"
    cp -r "${BOOT_STAGE}/dtb/." "${live_root}/dtb/" 2>/dev/null || true
    # The board FDT MUST be on the medium — extlinux's FDT line references it and the
    # board will not boot without it. Refuse to package a DTB-less LIVE image.
    [ -f "${live_root}/dtb/${FRITE_DTB}" ] || { err "LIVE image: board DTB ${FRITE_DTB} missing from ${live_root}/dtb — refusing to package a non-booting medium."; exit 1; }
    # Stage the dmsquash-live initramfs next to the kernel (extlinux INITRD line).
    cp "${FRITE_LIVE_INITRD}" "${live_root}/initrd.img"

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
    FRITE_INITRD_LINE="    INITRD /initrd.img"
    FRITE_APPEND="${APPEND_BASE} root=live:LABEL=FRITE_LIVE rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${live_root}/extlinux/extlinux.conf"

    if command -v xorriso >/dev/null; then
        LIVE_PATH="${WORK_DIR}/${ART_PREFIX}.live.iso"
        xorriso -as mkisofs -o "${LIVE_PATH}" -volid FRITE_LIVE -joliet -rock "${live_root}" \
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
    # The INSTALLER flavor: a LIVE-booting medium (the operator boots it off USB,
    # gets a running system, then runs install-frite.sh to write the light desktop
    # to onboard eMMC/SD — see install-frite.sh's own header).
    #
    # WHY THIS IS A LIVE BOOT, not a bare kernel: the previous version emitted the
    # medium's extlinux with `root=LABEL=FRITE_ROOT` and NO initramfs. But
    # FRITE_ROOT is the label install-frite.sh creates on the TARGET disk — it does
    # NOT exist on the installer medium, so that medium was UNBOOTABLE (it could
    # never find a root). The medium must boot ephemerally from a squashfs (exactly
    # like the LIVE flavor) so the installer can actually run; the disk's
    # `root=LABEL=FRITE_ROOT` cmdline belongs on the PAYLOAD boot tree we stage for
    # install-frite.sh to copy onto the target, NOT on the medium itself.
    command -v xorriso >/dev/null || { err "xorriso missing — cannot build the INSTALLER ISO. Install xorriso or drop --flavor installer."; exit 1; }
    [ -f "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" ] || { err "no kernel in boot stage — the INSTALLER medium cannot boot. Build the kernel (drop --skip-kernel)."; exit 1; }
    if ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        err "mksquashfs/tar2sqfs missing — cannot build the INSTALLER medium's live rootfs. Install squashfs-tools (or squashfs-tools-ng)."; exit 1
    fi
    # The medium boots root=live:/rd.live.* — those are dracut directives, so the
    # dmsquash-live initramfs is MANDATORY. Refuse to emit a known-dead installer
    # rather than the previous silent, unbootable one (mirrors the LIVE gate).
    if [ -z "${FRITE_LIVE_INITRD}" ] || [ ! -s "${FRITE_LIVE_INITRD}" ]; then
        err "No live initramfs was generated (Phase 4 §11b). The INSTALLER medium boots"
        err "from a squashfs (root=live:/rd.live.*) and is UNBOOTABLE without a dracut"
        err "dmsquash-live initramfs. Ensure sys-kernel/dracut emerged and the kernel"
        err "module tree exists (do not pass --skip-kernel for the installer flavor)."
        exit 1
    fi

    local inst_root="${STAGE_DIR}/installer"
    rm -rf "${inst_root}"; mkdir -p "${inst_root}"/{LiveOS,extlinux,dtb,stage4,boot,uboot}

    # ── The medium's OWN live boot (kernel + DTB + dmsquash-live initramfs) ──
    cp "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" "${inst_root}/"
    cp -r "${BOOT_STAGE}/dtb/." "${inst_root}/dtb/" 2>/dev/null || true
    [ -f "${inst_root}/dtb/${FRITE_DTB}" ] || { err "INSTALLER medium: board DTB ${FRITE_DTB} missing from ${inst_root}/dtb — refusing to package a non-booting medium."; exit 1; }
    cp "${FRITE_LIVE_INITRD}" "${inst_root}/initrd.img"

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

    # The medium's extlinux boots the squashfs ephemerally (FRITE_INSTALL volid).
    FRITE_INITRD_LINE="    INITRD /initrd.img"
    FRITE_APPEND="${APPEND_BASE} root=live:LABEL=FRITE_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/extlinux/extlinux.conf"

    # ── The INSTALL PAYLOAD that install-frite.sh consumes from its own dir ──
    # install-frite.sh reads ${SCRIPT_DIR}/stage4/*.tar.xz and copies ${SCRIPT_DIR}/boot/
    # (the DISK boot tree) onto the target's FAT. dmsquash-live mounts the medium at
    # /run/initramfs/live, so the operator runs /run/initramfs/live/install-frite.sh.
    cp "${STAGE4_TARBALL}" "${inst_root}/stage4/"
    # The disk boot tree: kernel + DTB + extlinux with the INSTALLED root cmdline
    # (root=LABEL=FRITE_ROOT, no live initramfs). install-frite.sh re-points root= at
    # the target's PARTUUID after partitioning.
    mkdir -p "${inst_root}/boot/extlinux" "${inst_root}/boot/dtb"
    cp "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" "${inst_root}/boot/"
    cp -r "${BOOT_STAGE}/dtb/." "${inst_root}/boot/dtb/" 2>/dev/null || true
    [ -f "${inst_root}/boot/dtb/${FRITE_DTB}" ] || { err "INSTALLER payload: disk-boot DTB ${FRITE_DTB} missing from ${inst_root}/boot/dtb — the installed system would not boot. Aborting."; exit 1; }
    FRITE_INITRD_LINE="    # (installed system boots a real partitioned rootfs)"
    FRITE_APPEND="${APPEND_BASE} root=LABEL=FRITE_ROOT"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/boot/extlinux/extlinux.conf"
    cp "${SPECS_DIR}/installer/install-frite.sh" "${inst_root}/install-frite.sh"
    chmod +x "${inst_root}/install-frite.sh"
    [ -f "${STAGE_DIR}/uboot/u-boot.bin" ] && cp "${STAGE_DIR}/uboot/u-boot.bin" "${inst_root}/uboot/" 2>/dev/null || true

    INSTALLER_PATH="${WORK_DIR}/${ART_PREFIX}.installer.iso"
    xorriso -as mkisofs -o "${INSTALLER_PATH}" -volid FRITE_INSTALL -joliet -rock "${inst_root}" \
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
    banner "Phase 5: Building LIVE image (boots-and-runs ephemerally off USB/SD)"
    build_live_iso
fi
if ${BUILD_INSTALLER}; then
    banner "Phase 6: Building INSTALLER image (writes the light desktop to eMMC/SD)"
    build_installer_iso
fi

echo ""
echo -e "${CYAN}${BOLD}=============================================="
echo "  Libre Computer Frite — Light Desktop Complete"
echo "==============================================${RESET}"
echo ""
echo "  Board:            ${FRITE_BOARD_DESC}"
echo "  DTB:              ${FRITE_DTB}"
echo "  u-boot defconfig: ${FRITE_UBOOT_DEFCONFIG}"
echo "  Desktop:          ${DESKTOP} (LEAN LXDE-class — NOT Plasma+gaming)"
echo "  Flavor:           ${FRITE_FLAVOR}"
echo "  Role:             ${ROLE}   (cluster domain: ${CLUSTER_DOMAIN})"
echo "  ENV:              ${ENV}"
echo "  Brand:            ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}"
echo "  Hostname:         ${HOSTNAME}"
echo ""
echo "  Mesh + provisioning (SAME as the other client images):"
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
echo "  RAM SKU note: La Frite 512MB and 1GB are the SAME image (RAM auto-detected);"
echo "  the 512MB SKU leans on the zram swap configured at first boot."
echo ""
echo "  === Post-build ==="
echo "  LIVE:      write ${LIVE_PATH##*/} to a USB stick (La Frite has no SD) and boot."
echo "  INSTALLER: write ${INSTALLER_PATH##*/} to USB and boot it (it boots LIVE off the"
echo "             squashfs); the medium auto-mounts at /run/initramfs/live, then run"
echo "               sudo /run/initramfs/live/install-frite.sh /dev/mmcblk0"
echo "             to write the light desktop to onboard eMMC (or SD on Le Potato)."
echo "  u-boot:    on Amlogic GXL u-boot needs proprietary FIP/BL31 blobs — provide a"
echo "             prebuilt signed image via --uboot-url (e.g. Tow-Boot) if not already flashed."
echo ""
