#!/usr/bin/env bash
# build-frite-stage4.sh
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

# ── Resolve SCRIPT_DIR (where the spec trees live) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-frite"    # aarch64/Frite-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"       # arch-agnostic specs (mesh, provisioning, sshd)

# ── Defaults ───────────────────────────────────────────────────────
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
ENV="test"
CONFIG_FILE=""
DEFAULT_USER="frite"
DEFAULT_USER_PASS="frite"
ROOT_PASS="gentoo"

# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ──
# The Frite boards have NO onboard WiFi/Bluetooth, so these default OFF and only
# matter if a USB radio dongle is attached. Ethernet + the tailnet are unaffected.
ENABLE_WIFI="${ENABLE_WIFI:-false}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-false}"
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt"

# Mesh VPN (installed as upstream static arm64 binaries, not emerged) — IDENTICAL
# to the Pi5 client image so the Frite joins the same headscale/tailscale mesh.
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false

# u-boot: the Frite needs a flashable u-boot built from mainline + Amlogic's
# proprietary FIP/BL31 blobs. We do NOT vendor those blobs here (licensing); the
# builder DOWNLOADS the prebuilt, board-specific Tow-Boot/u-boot image when a URL
# is given, else it WARNS and leaves a slot for the operator to drop one in.
FRITE_UBOOT_URL="${FRITE_UBOOT_URL:-}"          # optional: prebuilt board u-boot.bin URL
SKIP_UBOOT=false

# ── Colors ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'
BOLD='\033[1m'; RESET='\033[0m'
banner() { echo -e "\n${CYAN}${BOLD}==> $1${RESET}"; }
info()   { echo -e "${GREEN}    $1${RESET}"; }
warn()   { echo -e "${YELLOW}    WARNING: $1${RESET}"; }
err()    { echo -e "${RED}    ERROR: $1${RESET}" >&2; }

# ── Usage ──────────────────────────────────────────────────────────
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
    -H hostname / -T timezone / -u user / --user-password / --root-password
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

# ── Option parsing ─────────────────────────────────────────────────
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
        --user-password)      DEFAULT_USER_PASS="$2";     shift 2 ;;
        --root-password)      ROOT_PASS="$2";             shift 2 ;;
        -p|--extra-packages)  EXTRA_PACKAGES="$2";        shift 2 ;;
        --headscale-version)  HEADSCALE_VERSION="$2";     shift 2 ;;
        --tailscale-version)  TAILSCALE_VERSION="$2";     shift 2 ;;
        --enable-wifi)        ENABLE_WIFI=true;           shift   ;;
        --enable-bluetooth)   ENABLE_BLUETOOTH=true;      shift   ;;
        --skip-mesh)          SKIP_MESH=true;             shift   ;;
        --skip-tailscale)     SKIP_TAILSCALE=true;        shift   ;;
        --skip-kernel)        SKIP_KERNEL=true;           shift   ;;
        --img-size)           ROOT_MiB="$2";              shift 2 ;;
        --grow)               GROW_POLICY="$2";           shift 2 ;;
        --no-grow)            GROW_POLICY="none";         shift   ;;
        --compress)           COMPRESS_IMG=true;          shift   ;;
        --skip-clean)         SKIP_CLEAN=true;            shift   ;;
        --resume)             RESUME=true;                shift   ;;
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

# Default hostname
if [ -z "${HOSTNAME}" ]; then
    case "${ROLE}" in
        desktop|generic) HOSTNAME="${BRAND}-frite" ;;
        *)               HOSTNAME="${BRAND}-${ROLE}" ;;
    esac
fi

# Derived paths
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

# ── Template helper (mirrors the Pi5 render_template) ──────────────
render_template() {
    local src="$1" dst="$2"
    local cbuild
    cbuild="$(portageq envvar CHOST 2>/dev/null || gcc -dumpmachine)"
    sed \
        -e "s|@@CBUILD@@|${cbuild}|g" \
        -e "s|@@CROSS_TARGET@@|${CROSS_TARGET}|g" \
        -e "s|@@RPI_CPU@@|${RPI_CPU}|g" \
        -e "s|@@JOBS@@|${JOBS}|g" \
        -e "s|@@WORK_DIR@@|${BUILD_ROOT}|g" \
        -e "s|@@FRITE_KERNEL_IMG@@|${FRITE_KERNEL_IMG}|g" \
        -e "s|@@FRITE_DTB@@|${FRITE_DTB}|g" \
        -e "s|@@FRITE_INITRD_LINE@@|${FRITE_INITRD_LINE:-#}|g" \
        -e "s|@@FRITE_APPEND@@|${FRITE_APPEND:-}|g" \
        -e "s|@@HOSTNAME@@|${HOSTNAME}|g" \
        -e "s|@@TIMEZONE@@|${TIMEZONE}|g" \
        -e "s|@@DEFAULT_USER@@|${DEFAULT_USER}|g" \
        -e "s|@@DEFAULT_USER_PASS@@|${DEFAULT_USER_PASS}|g" \
        -e "s|@@ROOT_PASS@@|${ROOT_PASS}|g" \
        -e "s|@@BRAND@@|${BRAND}|g" \
        -e "s|@@BRAND_TITLE@@|${BRAND_TITLE}|g" \
        -e "s|@@DOMAIN@@|${CLUSTER_DOMAIN}|g" \
        -e "s|@@ORG@@|${ORG}|g" \
        -e "s|@@ENV@@|${ENV}|g" \
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
    local f
    while IFS= read -r -d '' f; do
        sed -i \
            -e "s|Snapdragon Systems|${BRAND_TITLE}|g" \
            -e "s|Snapdragon-Systems|${ORG}|g" \
            -e "s|snapdragon\.systems|${CLUSTER_DOMAIN}|g" \
            -e "s|snapdragon-|${BRAND}-|g" \
            "${f}"
    done < <(find "${SYSROOT}/etc/snapdragon" -type f -print0 2>/dev/null)
}

# ── 0. Verify prerequisites ───────────────────────────────────────
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
# The LIVE/INSTALLER images need mksquashfs + xorriso to wrap the squashfs ISO.
if ${BUILD_LIVE} || ${BUILD_INSTALLER}; then
    for t in mksquashfs xorriso; do
        command -v "$t" >/dev/null || warn "missing ${t} — the live/installer image step will warn + skip"
    done
fi
info "Cross-compiler: $(${CROSS_TARGET}-gcc --version | head -1)"
info "Jobs: ${JOBS}"

# ── 1. Directory layout ───────────────────────────────────────────
banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir,log} "${SYSROOT}" "${STAGE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE}"

# ── 2. Fetch + extract seed stage3 ─────────────────────────────────
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

# ── 3. Install spec files into sysroot portage ─────────────────────
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
cp "${SPECS_DIR}/portage/package.accept_keywords/"* "${SYSROOT}/etc/portage/package.accept_keywords/"
cp "${SPECS_DIR}/portage/package.use/"*             "${SYSROOT}/etc/portage/package.use/"
cp "${SPECS_DIR}/portage/package.env/"*             "${SYSROOT}/etc/portage/package.env/"
cp "${SPECS_DIR}/portage/env/"*.conf               "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"

# /etc config files
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
cp "${SHARED_SPECS}/etc/headscale/policy.hujson" "${SYSROOT}/etc/headscale/policy.hujson"

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
mkdir -p "${SYSROOT}/etc/local.d"
if [ -f "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" ]; then
    render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
    chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"
fi
harden_radios "${SYSROOT}"
write_zram_firstboot "${SYSROOT}"

# Hostname / timezone / locale
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
# headscale on this node is a CLIENT of the fleet control server (it does NOT host
# the control plane — that lives on the pki node), so we do NOT add headscale to
# the default runlevel here; only the tailscale CLIENT runs.
if ! ${SKIP_MESH} && ! ${SKIP_TAILSCALE}; then
    DEFAULT_SVCS+=(tailscaled)
fi
[ "${DESKTOP}" = "light" ] && DEFAULT_SVCS+=(display-manager)
for svc in "${DEFAULT_SVCS[@]}"; do
    ln -sf "/etc/init.d/${svc}" "${SYSROOT}/etc/runlevels/default/${svc}" 2>/dev/null || true
done

info "Profile: ${PROFILE_PATH}"

# ── 4. Cross-emerge helper ────────────────────────────────────────
cross_emerge() {
    mkdir -p "${BUILD_ROOT}/log" "${BUILD_ROOT}/edb"
    ROOT="${SYSROOT}" SYSROOT="${SYSROOT}" PORTAGE_CONFIGROOT="${SYSROOT}" \
    EMERGE_LOG_DIR="${BUILD_ROOT}/log" PORTAGE_DEPCACHEDIR="${BUILD_ROOT}/edb" \
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

# ── 5. Build @system ──────────────────────────────────────────────
banner "Phase 1: Cross-building @system (hardened)"
cross_emerge --oneshot --update sys-apps/baselayout
cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" @system \
    || warn "@system had package failures (--keep-going); continuing"

# ── 6. Build stage4 packages (base + light desktop) ───────────────
banner "Phase 2: Cross-building stage4 packages"
mapfile -t STAGE4_PACKAGES < <(grep -v '^\s*#' "${SPECS_DIR}/portage/packages.list" | grep -v '^\s*$')
if [ "${DESKTOP}" = "light" ]; then
    info "Light desktop selected — appending packages-light-desktop.list"
    mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
        grep -v '^\s*#' "${SPECS_DIR}/portage/packages-light-desktop.list" | grep -v '^\s*$')
fi
# LIVE flavor only: pull in sys-kernel/dracut so the builder can generate a
# dmsquash-live initramfs (the bare kernel cannot mount root=live:/rd.live.* —
# that is a dracut job). The INSTALLER flavor boots a real partitioned rootfs and
# does NOT need this, so dracut stays out of the always-installed base set.
if ${BUILD_LIVE}; then
    info "LIVE flavor selected — appending packages-live.list (dracut for the live initramfs)"
    mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
        grep -v '^\s*#' "${SPECS_DIR}/portage/packages-live.list" | grep -v '^\s*$')
fi
if [ -n "${EXTRA_PACKAGES}" ]; then
    read -ra _extras <<< "${EXTRA_PACKAGES}"
    STAGE4_PACKAGES+=("${_extras[@]}")
    info "Extra packages: ${EXTRA_PACKAGES}"
fi
info "Package count: ${#STAGE4_PACKAGES[@]}"
if ! cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${STAGE4_PACKAGES[@]}"; then
    warn "Batch emerge failed (unsatisfiable atom?); retrying per-package so the rest still install"
    for _pkg in "${STAGE4_PACKAGES[@]}"; do
        cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${_pkg}" \
            || warn "  skipped ${_pkg}"
    done
fi

# ── 7. Install mesh VPN (headscale + tailscale) — same as Pi5 ─────
if ${SKIP_MESH}; then
    banner "Phase 2.5: SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Phase 2.5: Installing mesh VPN (headscale + tailscale)"
    HS_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_arm64"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
    if curl -fL -o "${HS_BIN}" "${HS_URL}"; then
        chmod +x "${HS_BIN}"
        file "${HS_BIN}" | grep -q 'ELF.*aarch64' || warn "headscale binary is not aarch64"
        info "headscale installed: /usr/bin/headscale"
    else
        warn "Could not fetch headscale ${HEADSCALE_VERSION}; the headscale service will be inert."
    fi
    if ${SKIP_TAILSCALE}; then
        info "Skipping tailscale client (--skip-tailscale)"
    else
        TS_URL="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        TS_TGZ="${BUILD_ROOT}/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        if curl -fL -o "${TS_TGZ}" "${TS_URL}"; then
            TS_TMP="$(mktemp -d)"
            tar -C "${TS_TMP}" -xzf "${TS_TGZ}"
            TS_SUB="$(find "${TS_TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
            install -Dm0755 "${TS_SUB}/tailscale"  "${SYSROOT}/usr/bin/tailscale"
            install -Dm0755 "${TS_SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
            rm -rf "${TS_TMP}"
            info "tailscale installed: /usr/bin/tailscale, /usr/sbin/tailscaled"
        else
            warn "Could not fetch tailscale ${TAILSCALE_VERSION}; the tailscaled service will be inert."
        fi
    fi
fi

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
        while IFS= read -r line; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            read -r action rest <<< "${line}"
            eval "scripts/config --${action} ${rest}"
        done < "${SPECS_DIR}/kernel/hardened-desktop.config"
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
        if [ ! -f "${SYSROOT}/boot/dtb/${FRITE_DTB}" ]; then
            warn "Selected DTB ${FRITE_DTB} not found in the built tree — verify the in-tree name for this kernel."
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

# ── 10. Clean sysroot ─────────────────────────────────────────────
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

# ── 11. Stage the boot tree (kernel + DTB + extlinux.conf) ────────
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

    # Prefer the sysroot's own dracut (matches the target's module/tool versions);
    # fall back to a host dracut. Either is pointed at the target module tree.
    local sysroot_dracut="${SYSROOT}/usr/bin/dracut"
    if [ -x "${sysroot_dracut}" ] && command -v sh >/dev/null; then
        sh "${sysroot_dracut}" --force --no-hostonly \
            --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            --modules "${mods}" "${out}" 2>/dev/null && [ -s "${out}" ] && {
                FRITE_LIVE_INITRD="${out}"
                info "Live initramfs staged: ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut did not produce an initramfs; trying a host dracut."
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
if ${BUILD_LIVE} && ! ${SKIP_KERNEL}; then
    build_live_initramfs || warn "Live initramfs not built — see warnings above."
fi

# ── 12. Package the stage4 tarball ────────────────────────────────
banner "Phase 4: Packaging stage4 tarball"
STAGE4_TARBALL="${WORK_DIR}/${ART_PREFIX}.stage4.tar.xz"
tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner --owner=0 --group=0 \
    --exclude='./usr/src' --exclude='./var/cache' --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" . 2>/dev/null || \
tar -C "${SYSROOT}" --numeric-owner --owner=0 --group=0 \
    --exclude='./usr/src' --exclude='./var/cache' --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" .
info "Stage4 tarball: ${STAGE4_TARBALL} ($(du -sh "${STAGE4_TARBALL}" | cut -f1))"

# ── 13. Build the LIVE image (squashfs rootfs; boots ephemerally) ──
LIVE_PATH="(not built)"
INSTALLER_PATH="(not built)"

build_live_iso() {
    # The LIVE flavor: a bootable medium (USB on La Frite, SD on Le Potato) that
    # runs the rootfs ephemerally from a squashfs in RAM. We stage:
    #   /  Image, /dtb/..., /extlinux/extlinux.conf  (boot tree)
    #   /  LiveOS/squashfs.img                        (the rootfs)
    # u-boot (SPI/SD) + extlinux find squashfs.img and the kernel mounts it
    # read-only with an overlay (kernel has SQUASHFS + OVERLAY_FS + LOOP).
    command -v mksquashfs >/dev/null || { warn "mksquashfs missing — skipping LIVE image."; return 0; }
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
    # Stage the dmsquash-live initramfs next to the kernel (extlinux INITRD line).
    cp "${FRITE_LIVE_INITRD}" "${live_root}/initrd.img"

    info "Squashing the rootfs (LIVE) ..."
    mksquashfs "${SYSROOT}" "${live_root}/LiveOS/squashfs.img" \
        -noappend -comp xz -e boot/dtb 2>/dev/null \
        || mksquashfs "${SYSROOT}" "${live_root}/LiveOS/squashfs.img" -noappend

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
    ${COMPRESS_IMG} && [ -f "${LIVE_PATH}" ] && { xz -T0 -9 -f "${LIVE_PATH}"; LIVE_PATH="${LIVE_PATH}.xz"; }
}

# ── 14. Build the INSTALLER image (live + install-frite.sh + stage4) ──
build_installer_iso() {
    # The INSTALLER flavor: the LIVE boot tree PLUS the stage4 tarball + the
    # install-frite.sh script, so an operator boots it (off USB) and writes the
    # light desktop to onboard eMMC/SD. Reuses the same boot tree as LIVE.
    command -v xorriso >/dev/null || { warn "xorriso missing — skipping INSTALLER image."; return 0; }
    [ -f "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" ] || { warn "no kernel in boot stage — skipping INSTALLER image."; return 0; }

    local inst_root="${STAGE_DIR}/installer"
    rm -rf "${inst_root}"; mkdir -p "${inst_root}"/{stage4,boot,uboot}
    # Boot tree (kernel + DTB + extlinux) so the installer medium itself boots.
    cp "${BOOT_STAGE}/${FRITE_KERNEL_IMG}" "${inst_root}/boot/"
    cp -r "${BOOT_STAGE}/dtb" "${inst_root}/boot/" 2>/dev/null || true
    mkdir -p "${inst_root}/boot/extlinux"
    FRITE_INITRD_LINE="    # (installer boots the same lean kernel)"
    FRITE_APPEND="${APPEND_BASE} root=LABEL=FRITE_ROOT"
    render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${inst_root}/boot/extlinux/extlinux.conf"
    # Payload: the stage4 + the installer + any staged u-boot.
    cp "${STAGE4_TARBALL}" "${inst_root}/stage4/"
    cp "${SPECS_DIR}/installer/install-frite.sh" "${inst_root}/install-frite.sh"
    chmod +x "${inst_root}/install-frite.sh"
    [ -f "${STAGE_DIR}/uboot/u-boot.bin" ] && cp "${STAGE_DIR}/uboot/u-boot.bin" "${inst_root}/uboot/" 2>/dev/null || true

    INSTALLER_PATH="${WORK_DIR}/${ART_PREFIX}.installer.iso"
    xorriso -as mkisofs -o "${INSTALLER_PATH}" -volid FRITE_INSTALL -joliet -rock "${inst_root}" \
        && info "INSTALLER image: ${INSTALLER_PATH} ($(du -sh "${INSTALLER_PATH}" | cut -f1))" \
        || { warn "xorriso failed; leaving the installer tree at ${inst_root}"; INSTALLER_PATH="${inst_root} (tree)"; }
    ${COMPRESS_IMG} && [ -f "${INSTALLER_PATH}" ] && { xz -T0 -9 -f "${INSTALLER_PATH}"; INSTALLER_PATH="${INSTALLER_PATH}.xz"; }
}

if ${BUILD_LIVE}; then
    banner "Phase 5: Building LIVE image (boots-and-runs ephemerally off USB/SD)"
    build_live_iso
fi
if ${BUILD_INSTALLER}; then
    banner "Phase 6: Building INSTALLER image (writes the light desktop to eMMC/SD)"
    build_installer_iso
fi

# ── 15. Summary ───────────────────────────────────────────────────
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
echo "  INSTALLER: boot the installer medium, then run  install-frite.sh /dev/mmcblk0  to"
echo "             write the light desktop to onboard eMMC (or SD on Le Potato)."
echo "  u-boot:    on Amlogic GXL u-boot needs proprietary FIP/BL31 blobs — provide a"
echo "             prebuilt signed image via --uboot-url (e.g. Tow-Boot) if not already flashed."
echo ""
