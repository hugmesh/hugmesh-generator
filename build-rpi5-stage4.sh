#!/usr/bin/env bash
# build-rpi5-stage4.sh
# Build a hardened Gentoo aarch64 (RPi 5) stage4 ISO with Kubernetes
# using crossdev toolchain on x86_64
#
# Run as root (sudo): the cross-emerge merges into the sysroot's vdb and writes
# the host emerge log/cache, so real root is required (fakeroot is NOT enough).
# The bundled install.sh (inside the ISO) also requires root on the target.
set -euo pipefail

# Mirrors the x86 host builder's split: SPECS_DIR holds the aarch64/RPi5-specific
# specs (portage, boot, kernel, installer, fstab), SHARED_SPECS holds the
# arch-agnostic specs shared with the x86 build (etc/, cluster/, usr/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-rpi5"     # aarch64/RPi5-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"       # arch-agnostic specs (etc/, cluster/, usr/)

WORK_DIR=""
# Per-arch build subdirectory under WORK_DIR. The heavy, ARCH-SPECIFIC build
# tree (sysroot, ISO staging, distfiles, pkgdir, seed/binary downloads) lives
# under WORK_DIR/${BUILD_SUBDIR} so the aarch64 (Pi) and amd64 (x86) builds NEVER
# share a sysroot when they run against the same WORK_DIR (e.g. build-all-roles).
# Override with --build-subdir NAME or BUILD_SUBDIR=NAME in the env. The finished
# PRODUCTS (.img/.iso/.fs.tar.xz/stage4/keys-*) still land in WORK_DIR itself.
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-pi5}"
CROSS_TARGET="aarch64-unknown-linux-gnu"
REL_VERSION="2026.0"
RPI_CPU="cortex-a76"
RPI_DEFCONFIG="bcm2712_defconfig"
RPI_DTB_PREFIX="bcm2712"
RPI_KERNEL_IMG="kernel_2712.img"
JOBS="$(nproc)"
SKIP_KERNEL=false
SKIP_ISO=false
SKIP_CLEAN=false
RESUME=false

# Output artifact: the raw partitioned .img is the ONLY default Pi artifact — it
# is the Pi's bootable, read-write, run-off-USB live system (RPi firmware boots
# the FAT partition; a Pi cannot boot a 9660 ISO, and there is no installer for
# the Pi). The installer ISO remains available as an opt-in transport via --iso.
BUILD_IMG=true          # produce the flashable raw .img (the Pi live USB)
BUILD_ISO=false         # no installer/ISO by default for the Pi (--iso to force)
BUILD_TAR=true          # also emit the mounted-filesystem tarball (.fs.tar.xz)
ROOT_MiB=6144           # ext4 root partition size in the .img (growroot expands it on first boot)
GROW_POLICY="fill"      # first-boot grow policy baked into /etc/growfs.conf: fill|none|<size> (see growroot)
SD_ONLY=false           # use literal /dev/mmcblk0p2 instead of PARTUUID/LABEL identity
COMPRESS_IMG=false      # xz -9 the finished .img
EXTRA_PACKAGES=""
TIMEZONE="UTC"
HOSTNAME=""
ROLE="generic"          # generic | pki | backend | frontend
CLUSTER_DOMAIN="snapdragon.systems"
BRAND="snapdragon"                  # name slug (namespaces, gateways, hostnames)
BRAND_TITLE="Snapdragon Systems"    # human-readable title
ORG="Snapdragon-Systems"            # GitHub org / image namespace
# Games portal domain. DEFAULT = SUBDOMAIN of the primary (games.<CLUSTER_DOMAIN>)
# until the real .games TLD is obtained; flip with GAMES_DOMAIN=<brand>.games. The
# default literal composes with rebrand_sysroot (snapdragon.systems->CLUSTER_DOMAIN).
# Drives the games host + OIDC issuer/redirects via parameterize_games_domain().
GAMES_DOMAIN="games.snapdragon.systems"
# OPTIONAL services selected on this image (subset of: akkoma tuwunel phpbb games).
# Built-in default = ALL on; brand.conf narrows; --optional-services overrides both
# (built-in < brand.conf < flag). Unselected slugs are pruned by gate_optional_services.
OPTIONAL_SERVICES="akkoma tuwunel phpbb games"
# ── Build ENV selector (BAKED into the image) ──────────────────────
# test (DEFAULT, local-first/safe): LAN-only — cluster wildcard DNS ON, the
#   go-live cloudflared/external-dns/ACME app is PRUNED from the baked apps/,
#   OAuth/SMTP/Cloudflare optional/absent. Internal cluster-CA TLS only.
# prod: bakes the REAL public domain — public DNS / Cloudflare, ACME ALLOWED on
#   top of the internal CA, OAuth/SMTP/Cloudflare from the keys USB. A LOUD
#   announced banner prints before the build because it bakes the real domain.
ENV="test"
CONFIG_FILE=""                      # optional drop-in brand profile (sourced)
DEFAULT_USER="pi"
DEFAULT_USER_PASS="raspberry"
ROOT_PASS="gentoo"
PCIE_GEN3=false
# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ───
# WiFi + Bluetooth are OFF by default to shrink the attack surface: at first boot
# rfkill blocks both radios, their kernel modules are blacklisted, and no wifi/
# bluetooth service is enabled. ETHERNET + the Tailscale tailnet are UNAFFECTED.
# Re-enable per build with ENABLE_WIFI=true / ENABLE_BLUETOOTH=true (env/brand.conf)
# or --enable-wifi / --enable-bluetooth. Precedence: built-in (false) < brand.conf
# < CLI flag. (On the Pi 5 the onboard radio is the brcmfmac/Cypress chip.)
ENABLE_WIFI="${ENABLE_WIFI:-false}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-false}"
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt"

# Mesh VPN (installed as upstream static arm64 binaries, not emerged)
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}==> $1${RESET}"; }
info()   { echo -e "${GREEN}    $1${RESET}"; }
warn()   { echo -e "${YELLOW}    WARNING: $1${RESET}"; }
err()    { echo -e "${RED}    ERROR: $1${RESET}" >&2; }

usage() {
cat <<'MANEOF'
NAME
    build-rpi5-stage4.sh - Build a hardened Gentoo aarch64 stage4 ISO
    with Kubernetes for Raspberry Pi 5, using a crossdev toolchain on
    an x86_64 host.

SYNOPSIS
    build-rpi5-stage4.sh [OPTIONS]

DESCRIPTION
    Cross-compiles a complete Gentoo Linux stage4 image targeting the
    Raspberry Pi 5 (BCM2712 / Cortex-A76).  The resulting image ships
    with a hardened kernel, SELinux, auditing, and a full Kubernetes
    stack (containerd, kubelet, kubeadm, kubectl, CNI plugins).

    Run as root (sudo).  The cross-emerge merges into the sysroot's
    package database and writes the host emerge log/cache, so real root
    is required (fakeroot is not sufficient).  Most output files are
    written under the work directory.  The bundled install.sh inside the
    ISO also requires root on the machine that writes the image.

    Configuration lives in two spec trees next to this script, mirroring
    the x86 host builder's layout: specs-rpi5/ holds the aarch64/RPi5-
    specific specs and specs/ holds the arch-agnostic specs shared with
    the x86 build.  Edit them before building to customise the image
    without touching the build script itself.

    specs-rpi5/                     aarch64/RPi5-specific (this build only)
    ├── portage/                    Portage configuration
    │   ├── make.conf.tmpl              Main portage config (templated)
    │   ├── packages.list               Stage4 package list
    │   ├── profile/
    │   │   ├── parent                  Gentoo profile selection
    │   │   └── use.mask                Global USE mask
    │   ├── package.accept_keywords/
    │   │   ├── rpi                     RPi firmware keywords
    │   │   └── kubernetes              K8s stack keywords
    │   ├── package.use/
    │   │   ├── rpi5                    RPi 5 USE flags
    │   │   └── kubernetes              K8s USE flags
    │   ├── env/
    │   │   └── cross-go.conf.tmpl      Go cross-compile env (templated)
    │   └── package.env/
    │       └── kubernetes              Package-to-env mapping
    ├── boot/
    │   ├── config.txt.tmpl             RPi boot config (templated)
    │   └── cmdline.txt                 Kernel command line
    ├── etc/
    │   └── fstab                       Filesystem table (RPi /boot firmware)
    ├── kernel/
    │   └── hardened-k8s.config         Kernel config fragment
    └── installer/
        └── install.sh                  SD/NVMe installer (ships in ISO)

    specs/                          arch-agnostic (shared with the x86 build)
    ├── etc/
    │   ├── modules-load.d/
    │   │   └── kubernetes.conf         K8s kernel modules
    │   ├── sysctl.d/
    │   │   ├── 10-hardened.conf        Hardened sysctl
    │   │   └── 99-kubernetes.conf      K8s sysctl
    │   ├── containerd/
    │   │   └── config.toml             containerd config
    │   ├── kubernetes/
    │   │   ├── kubeadm-config.yaml     kubeadm defaults
    │   │   └── kubelet-config.yaml     Hardened kubelet config
    │   ├── init.d/
    │   │   ├── containerd              OpenRC init script
    │   │   ├── kubelet                 OpenRC init script
    │   │   ├── headscale               OpenRC init script
    │   │   ├── tailscaled              OpenRC init script
    │   │   └── keys-provision          OpenRC first-boot service
    │   ├── headscale/
    │   │   └── config.yaml             Default headscale config
    │   ├── keys-provision/
    │   │   └── provision.sh            USB KEYS provisioning engine
    │   ├── ssh/sshd_config.d/
    │   │   └── hardened.conf           Hardened SSH config
    │   └── local.d/
    │       └── 01-firstboot.start.tmpl First-boot finaliser (templated)
    ├── usr/local/sbin/
    │   └── snapdragon-backup           etcd + PostgreSQL backup engine
    └── cluster/                    ArgoCD app-of-apps + GitOps payload

OPTIONS
  Directories
    -w, --work-dir DIR
        Base directory for the finished PRODUCTS (.img, .iso,
        .fs.tar.xz, stage4, keys-*).  Default: ./out (created under
        the current working directory; local + gitignored).

    --build-subdir NAME
        Per-arch subdirectory under --work-dir that holds the heavy,
        ARCH-SPECIFIC build tree (sysroot, ISO staging, distfiles,
        pkgdir, seed tarball, emerge caches).  Default: snap-build-pi5
        (also settable via BUILD_SUBDIR=NAME).  This keeps the aarch64
        (Pi) and amd64 (x86) builds from ever sharing a sysroot when
        they run against the same --work-dir (e.g. build-all-roles.sh).

    -s, --specs-dir DIR
        Path to the aarch64/RPi5-specific specs directory.  Default:
        specs-rpi5/ next to this script.  Use this to point at a
        customised copy.  (The arch-agnostic specs/ tree is always read
        from next to this script.)

  Toolchain
    -t, --target TUPLE
        Cross-compilation target triplet.
        Default: aarch64-unknown-linux-gnu

    -j, --jobs N
        Number of parallel make/emerge jobs.
        Default: $(nproc)  (all available cores)

  Board / CPU
    -c, --cpu CPU
        GCC -mcpu / -mtune value.
        Default: cortex-a76  (RPi 5)
        Common values: cortex-a53 (RPi 3), cortex-a72 (RPi 4)

    -d, --defconfig NAME
        Kernel defconfig to use.
        Default: bcm2712_defconfig  (RPi 5)
        Common values: bcmrpi3_defconfig (RPi 3),
                       bcm2711_defconfig (RPi 4)

    --dtb-prefix PREFIX
        Device-tree blob filename prefix.
        Default: bcm2712

    --kernel-img NAME
        Output kernel image filename for /boot.
        Default: kernel_2712.img

    --pcie-gen3
        Uncomment dtparam=pciex1_gen=3 in config.txt to force
        PCIe Gen 3 for NVMe.  Not all drives are stable at Gen 3;
        test yours first.

  Image
    -v, --version STRING
        Release version stamp used in filenames and the ISO volume ID.
        Default: 2026.0

  Artifacts
        By default the build produces a raw, partitioned, flashable .img
        (a FAT32 /boot + ext4 root, ready for `dd`/Imager).  The installer
        ISO is no longer built unless explicitly requested.

    --img
        Produce the raw .img.  This is the DEFAULT.

    --no-img
        Do not produce the .img (e.g. when you only want the ISO).

    --iso
        ALSO produce the bootable installer ISO (in addition to the .img).

    --both
        Produce both the .img and the installer ISO.

    --img-size MiB
        Size (in MiB) of the ext4 root partition baked into the .img. The
        .img is built COMPACT — only as large as this root plus the 512MiB
        boot partition and alignment — so it flashes fast and is NOT padded
        to the size of the target USB. growroot then expands the root to fill
        the medium (or the --grow cap) on first boot, so this only needs to
        fit the stage4 plus a little headroom.
        Default: 6144

    --grow fill|none|<size>
        First-boot grow policy baked into the image (/etc/growfs.conf, read
        by the growroot service). The LAST partition is the growable one.
          fill    (DEFAULT) expand the root to fill the WHOLE USB/SD/NVMe.
          none    do not grow — keep the compact flashed layout (use as
                  little of the medium as needed).
          <size>  cap the root filesystem at an absolute size, e.g. 16G,
                  12000M or 50% (percent of the device); the remaining tail
                  is left free for a separate data partition.
        Override per-device WITHOUT rebuilding: edit GROW= in growfs.conf on
        the FAT /boot partition, or add a growfs=<value> token to the kernel
        cmdline (cmdline.txt). Precedence: cmdline > /boot/growfs.conf >
        /etc/growfs.conf > built-in fill.
        Default: fill

    --sd-only
        Bake a fixed root=/dev/mmcblk0p2 (and device-path fstab) into the
        .img instead of resolving the root by PARTUUID/LABEL.  Use only for
        SD-card-only images; the PARTUUID default also boots from USB/NVMe.

    --compress
        xz -9 the finished .img (produces <img>.xz).

    --seed-url URL
        URL to the latest-stage3 index file used to locate the seed
        tarball.
        Default: (Gentoo arm64 OpenRC autobuilds)

  System
    -H, --hostname NAME
        Target system hostname.
        Default: gentoo-rpi5

    -T, --timezone ZONE
        Target system timezone (e.g. America/New_York).
        Default: UTC

    -u, --user NAME
        Default non-root user created on first boot.
        Default: pi

    --user-password PASS
        Password for the default user (change on first boot!).
        Default: raspberry

    --root-password PASS
        Root password (change on first boot!).
        Default: gentoo

  Packages
    -p, --extra-packages "PKG1 PKG2 ..."
        Space-separated list of additional Gentoo packages to
        cross-emerge into the stage4 image.  These are appended
        to specs-rpi5/portage/packages.list at build time.

  Mesh VPN (headscale + tailscale)
        Headscale (the self-hosted Tailscale control server) and the
        tailscale client are installed as upstream static aarch64
        binaries rather than emerged, so no overlay is required.

    --headscale-version VER
        Headscale release to install (from GitHub releases).
        Default: 0.23.0

    --tailscale-version VER
        Tailscale client release to install (from pkgs.tailscale.com).
        Default: 1.78.1

    --skip-tailscale
        Install headscale only; omit the tailscale client.

    --skip-mesh
        Do not install headscale or tailscale at all.

    --enable-wifi
        Re-enable WiFi. DISABLED by default (rfkill block + blacklisted modules
        + no service); Ethernet + the tailnet are unaffected.
        (env/brand.conf: ENABLE_WIFI=true)

    --enable-bluetooth
        Re-enable Bluetooth. DISABLED by default (rfkill block + blacklisted
        modules + no bluetooth service). (env/brand.conf: ENABLE_BLUETOOTH=true)

  Phases
    --skip-kernel
        Skip kernel compilation.  Useful when iterating on userspace
        packages only.

    --skip-iso
        Alias for --no-iso: do not build the installer ISO (the default).
        Retained for backwards compatibility; with the .img default this
        means "img only".

    --skip-clean
        Do not strip binaries or remove docs/headers from the
        sysroot.  Useful for development images.

    --resume
        Resume a previous build.  Skips seed tarball extraction if
        the sysroot is already populated and passes --update to
        cross-emerge.

  Build ENV (baked into the image)
    --env test|prod
        Select the build ENV, BAKED into the image at /etc/snapdragon/env.
        Default: test.
        test = LAN-only: the cluster wildcard-DNS app (09-lan-dns.yaml) is kept
               and authoritative; the go-live cloudflared/ACME app is pruned;
               OAuth/SMTP/Cloudflare optional/absent. Internal cluster-CA only.
        prod = bakes the REAL public domain: the cloudflared/external-dns/ACME
               go-live app is kept (creds from the keys USB) and the LAN wildcard
               DNS app is pruned. ACME is ADDITIVE to the internal cluster CA.
               Prints a LOUD announced banner before building.

  General
    -h, --help
        Show this help and exit.

EXAMPLES
    # Minimal invocation — build everything with defaults
    ./build-rpi5-stage4.sh

    # Specify a work directory on a fast NVMe scratch disk
    ./build-rpi5-stage4.sh -w /mnt/nvme/rpi-build

    # Use a customised RPi5-specific specs directory
    ./build-rpi5-stage4.sh -s ~/my-specs-rpi5

    # Use 8 jobs, set hostname, add packages, force PCIe Gen 3
    ./build-rpi5-stage4.sh \
        -j 8 \
        -H k8s-node-01 \
        -T America/New_York \
        --pcie-gen3 \
        -p "app-misc/tmux sys-fs/btrfs-progs net-misc/chrony"

    # Build for RPi 4 instead of RPi 5
    ./build-rpi5-stage4.sh \
        -c cortex-a72 \
        -d bcm2711_defconfig \
        --dtb-prefix bcm2711 \
        --kernel-img kernel8.img

    # Resume a failed build, skip ISO, keep debug symbols
    ./build-rpi5-stage4.sh \
        -w ~/rpi5-stage4-build \
        --resume \
        --skip-iso \
        --skip-clean

    # Full production build with all options
    ./build-rpi5-stage4.sh \
        -w /var/tmp/rpi5-build \
        -s ./specs-rpi5 \
        -t aarch64-unknown-linux-gnu \
        -j 16 \
        -c cortex-a76 \
        -d bcm2712_defconfig \
        --dtb-prefix bcm2712 \
        --kernel-img kernel_2712.img \
        --pcie-gen3 \
        -v 2026.1 \
        -H k8s-master \
        -T Europe/London \
        -u admin \
        --user-password 'Ch@ng3Me!' \
        --root-password 'S3cur3R00t!' \
        -p "app-misc/tmux net-misc/chrony sys-fs/btrfs-progs dev-vcs/git"

EXIT STATUS
    0   Build completed successfully.
    1   Missing dependency, invalid option, or build failure.

FILES
    <work-dir>/                     finished products (shared with the x86 build)
        <brand>-rpi5-arm64-<role>-<env>-<stamp>.img         Flashable raw image (default)
        <brand>-rpi5-arm64-<role>-<env>-<stamp>.iso         Bootable ISO with installer (opt-in)
        <brand>-rpi5-arm64-<role>-<env>-<stamp>.fs.tar.xz   Exact root filesystem tarball
        <brand>-rpi5-arm64-<role>-<env>-<stamp>.stage4.tar.xz   Final stage4 tarball
        keys-<role>/                Per-role provisioning keys (build-all-roles)
        build.log                   Full build log
    <work-dir>/snap-build-pi5/      per-arch heavy build tree (--build-subdir)
        sysroot/                    Cross-compiled aarch64 root filesystem
        distfiles/                  Portage source archives
        pkgdir/                     Binary packages
        isoroot/                    ISO staging area
        log/  edb/                  emerge log + dep-metadata cache

    Output artifacts are named (all share one UTC build stamp):
        <brand>-rpi5-arm64-<role>-<env>-<UTC-stamp>.img            Flashable disk image (default)
        <brand>-rpi5-arm64-<role>-<env>-<UTC-stamp>.stage4.tar.xz  Final stage4 tarball
        <brand>-rpi5-arm64-<role>-<env>-<UTC-stamp>.fs.tar.xz      Mounted-tree filesystem tarball
        <brand>-rpi5-arm64-<role>-<env>-<UTC-stamp>.iso           Bootable ISO with installer (--iso)
    e.g. snapdragon-rpi5-arm64-frontend-test-20260610T193045Z.img
    The <brand> prefix + <role>/<env> tokens keep the QEMU launchers and
    flash-disk.sh autodetect globs matching.

NOTES
    The cross-toolchain (crossdev) must already be installed and
    built for the target triplet before running this script.

    All host tools (xorrisofs, curl, tar, file, etc.) must be
    present in PATH.

    Configuration lives in two trees: specs-rpi5/ (aarch64/RPi5-
    specific) and specs/ (arch-agnostic, shared with the x86 build).
    Copy specs-rpi5/, edit the files you need, and pass --specs-dir to
    use your version.  Files ending in .tmpl contain @@VARIABLE@@
    markers that are replaced at build time.  Plain files are copied
    as-is.

    The bundled install.sh inside the ISO requires root privileges
    to partition, format, and mount block devices.

SEE ALSO
    crossdev(1), emerge(1), catalyst(1), kubeadm(1)

MANEOF
exit 0
}

# ── Drop-in brand profile (sourced before CLI; CLI flags override it) ──
# Pre-scan for --config/-C; otherwise auto-detect ./brand.conf in the CWD.
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
        -w|--work-dir)        WORK_DIR="$2";           shift 2 ;;
        --build-subdir)       BUILD_SUBDIR="$2";       shift 2 ;;
        -s|--specs-dir)       SPECS_DIR="$2";          shift 2 ;;
        -t|--target)          CROSS_TARGET="$2";       shift 2 ;;
        -j|--jobs)            JOBS="$2";               shift 2 ;;
        -c|--cpu)             RPI_CPU="$2";            shift 2 ;;
        -d|--defconfig)       RPI_DEFCONFIG="$2";      shift 2 ;;
        --dtb-prefix)         RPI_DTB_PREFIX="$2";     shift 2 ;;
        --kernel-img)         RPI_KERNEL_IMG="$2";     shift 2 ;;
        --pcie-gen3)          PCIE_GEN3=true;          shift   ;;
        -v|--version)         REL_VERSION="$2";        shift 2 ;;
        --seed-url)           SEED_STAGE3_URL="$2";    shift 2 ;;
        -H|--hostname)        HOSTNAME="$2";           shift 2 ;;
        -r|--role)            ROLE="$2";               shift 2 ;;
        -C|--config)          CONFIG_FILE="$2";        shift 2 ;;  # sourced above
        --env)                ENV="$2";                shift 2 ;;
        --cluster-domain|--domain) CLUSTER_DOMAIN="$2"; shift 2 ;;
        --brand)              BRAND="$2";              shift 2 ;;
        --brand-title)        BRAND_TITLE="$2";        shift 2 ;;
        --org)                ORG="$2";                shift 2 ;;
        --games-domain)       GAMES_DOMAIN="$2";       shift 2 ;;
        --optional-services)  OPTIONAL_SERVICES="$2";  shift 2 ;;
        -T|--timezone)        TIMEZONE="$2";           shift 2 ;;
        -u|--user)            DEFAULT_USER="$2";       shift 2 ;;
        --user-password)      DEFAULT_USER_PASS="$2";  shift 2 ;;
        --root-password)      ROOT_PASS="$2";          shift 2 ;;
        -p|--extra-packages)  EXTRA_PACKAGES="$2";     shift 2 ;;
        --headscale-version)  HEADSCALE_VERSION="$2";  shift 2 ;;
        --tailscale-version)  TAILSCALE_VERSION="$2";  shift 2 ;;
        --enable-wifi)        ENABLE_WIFI=true;        shift   ;;
        --enable-bluetooth)   ENABLE_BLUETOOTH=true;   shift   ;;
        --skip-mesh)          SKIP_MESH=true;          shift   ;;
        --skip-tailscale)     SKIP_TAILSCALE=true;     shift   ;;
        --skip-kernel)        SKIP_KERNEL=true;        shift   ;;
        --img)                BUILD_IMG=true;          shift   ;;
        --no-img)             BUILD_IMG=false;         shift   ;;
        --iso)                BUILD_ISO=true;          shift   ;;
        --both)               BUILD_IMG=true; BUILD_ISO=true; shift ;;
        --img-size)           ROOT_MiB="$2";           shift 2 ;;
        --grow)               GROW_POLICY="$2";        shift 2 ;;
        --no-grow)            GROW_POLICY="none";      shift   ;;
        --sd-only)            SD_ONLY=true;            shift   ;;
        --compress)           COMPRESS_IMG=true;       shift   ;;
        --tar)                BUILD_TAR=true;          shift   ;;
        --no-tar)             BUILD_TAR=false;         shift   ;;
        # --skip-iso / --no-iso: don't build the installer ISO (now the default).
        --skip-iso|--no-iso)  BUILD_ISO=false;         shift   ;;
        --skip-clean)         SKIP_CLEAN=true;         shift   ;;
        --resume)             RESUME=true;             shift   ;;
        -h|--help)            usage                           ;;
        --)                   shift; break                    ;;
        -*)
            err "Unknown option: $1"
            echo "    Run with --help for usage." >&2
            exit 1
            ;;
        *)
            err "Unexpected argument: $1"
            echo "    Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# Default work directory: ./out under CWD (local + gitignored)
if [ -z "${WORK_DIR}" ]; then
    WORK_DIR="$(pwd)/out"
fi

# Reconcile the legacy SKIP_ISO switch with the new BUILD_ISO design. The ISO is
# now opt-in: SKIP_ISO is simply the negation of BUILD_ISO so the existing
# prerequisite check (xorrisofs) and the Phase 5 gate keep working unchanged.
if ${BUILD_ISO}; then SKIP_ISO=false; else SKIP_ISO=true; fi

# Validate role and derive a default hostname from it
case "${ROLE}" in
    generic|pki|backend|frontend) ;;
    *) echo "ERROR: --role must be one of: generic pki backend frontend" >&2; exit 1 ;;
esac
if [ -z "${HOSTNAME}" ]; then
    case "${ROLE}" in
        generic) HOSTNAME="gentoo-rpi5" ;;
        *)       HOSTNAME="${BRAND}-${ROLE}" ;;
    esac
fi

# ── Validate/normalize the first-boot grow policy (baked into /etc/growfs.conf) ──
# fill (DEFAULT, fill the whole medium) | none/off/0 (keep compact) | a concrete
# size (16G, 12000M, 50% ...). Concrete sizes are passed through to resize2fs on
# the node at first boot, so we only sanity-check the shape here.
GROW_POLICY="$(printf '%s' "${GROW_POLICY}" | tr '[:upper:]' '[:lower:]')"
case "${GROW_POLICY}" in
    fill|none|off|no|false|0) ;;
    *[0-9]g|*[0-9]m|*[0-9]k|*[0-9]t|*[0-9]gib|*[0-9]mib|*[0-9]kib|*[0-9]%|*[0-9]) ;;
    *) err "--grow must be: fill | none | <size> (e.g. 16G, 12000M, 50%)  (got '${GROW_POLICY}')"; exit 1 ;;
esac

# ── Validate + announce the build ENV (baked into the image) ──────────────
case "${ENV}" in
    test|prod) ;;
    *) err "--env must be one of: test | prod  (got '${ENV}')"; exit 1 ;;
esac
if [ "${ENV}" = "prod" ]; then
    # LOUD announced banner — a prod image bakes the REAL public domain and
    # expects Cloudflare/OAuth/SMTP creds from the keys USB.
    echo -e "${RED}${BOLD}"
    echo "############################################################################"
    echo "##                                                                        ##"
    echo "##   BUILDING PROD IMAGE for ${CLUSTER_DOMAIN}"
    echo "##                                                                        ##"
    echo "##   - bakes the REAL public domain (no .test wildcard DNS authority)     ##"
    echo "##   - Cloudflare / external-dns / ACME go-live app is KEPT (creds: USB)  ##"
    echo "##   - OAuth / SMTP expected from the keys USB                            ##"
    echo "##   - internal cluster-CA TLS still applies (ACME is additive)           ##"
    echo "##                                                                        ##"
    echo "##   For a LAN test image use:  --env test  (or 'make local')             ##"
    echo "##                                                                        ##"
    echo "############################################################################"
    echo -e "${RESET}"
else
    info "Build ENV: test (LAN-first; cluster wildcard DNS; cloudflared/ACME pruned)"
fi

# Derived paths
# BUILD_ROOT = the per-arch heavy build tree under WORK_DIR (default
# WORK_DIR/snap-build-pi5). The sysroot, ISO staging, distfiles, pkgdir, seed
# tarball and emerge caches all live here so the aarch64 build never collides
# with the amd64 build that shares the same WORK_DIR. Finished PRODUCTS
# (.img/.iso/.fs.tar.xz/stage4) still go to WORK_DIR (see STAGE4_TARBALL/IMG_PATH
# below) so build-all-roles.sh + the Makefile + make-keys-usb keep finding them.
BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"
SYSROOT="${BUILD_ROOT}/sysroot"
ISO_DIR="${BUILD_ROOT}/isoroot"
LOG_FILE="${WORK_DIR}/build.log"

# Single, sortable UTC build stamp shared by EVERY artifact of this run, so the
# .img / .iso / stage4 / fs tarball all carry the same identifier. Computed once
# here at build start. Artifacts are named:
#   ${BRAND}-rpi5-arm64-${ROLE}-${ENV}-${BUILD_TS}.<ext>
# (the ${BRAND}- prefix + role token keep the QEMU launchers' and flash-disk.sh's
#  'snapdragon-rpi5-*-<role>-*' / '*-<role>-*' autodetect globs matching.)
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"
info "Build stamp: ${BUILD_TS} (UTC; brand=${BRAND}, env=${ENV})"

# Copies a file, replacing @@VAR@@ markers with shell variable values.
# Usage: render_template <src> <dst>
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
        -e "s|@@RPI_KERNEL_IMG@@|${RPI_KERNEL_IMG}|g" \
        -e "s|@@PCIE_LINE@@|${PCIE_LINE}|g" \
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

# WiFi + Bluetooth are DISABLED BY DEFAULT (hardened posture). For each radio
# left OFF (ENABLE_WIFI / ENABLE_BLUETOOTH = false) we (a) blacklist its kernel
# modules in /etc/modprobe.d/ so they don't autoload (on the Pi 5 the onboard
# radio is the brcmfmac/Cypress chip + btbcm), and (b) drop a first-boot
# /etc/local.d action that rfkill-blocks it and (for WiFi) tells NetworkManager
# to leave wlan unmanaged. ETHERNET + the Tailscale tailnet are NEVER touched.
# Idempotent + best-effort at runtime (missing rfkill/nmcli = skipped).
harden_radios() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/modprobe.d" "${sysroot}/etc/local.d" \
             "${sysroot}/etc/NetworkManager/conf.d"
    local bl="${sysroot}/etc/modprobe.d/snapdragon-radio-blacklist.conf"
    : > "${bl}"
    local act="${sysroot}/etc/local.d/02-radio-hardening.start"

    {
        echo "#!/bin/sh"
        echo "# Radio hardening (generated by build-rpi5-stage4.sh). WiFi/Bluetooth are"
        echo "# OFF by default; rfkill-block them at boot. Ethernet + tailnet untouched."
        echo "command -v rfkill >/dev/null 2>&1 || exit 0"
    } > "${act}"

    if [ "${ENABLE_WIFI}" != "true" ]; then
        {
            echo "# WiFi disabled by default (ENABLE_WIFI=false) — hardened posture."
            echo "blacklist cfg80211"
            echo "blacklist mac80211"
            echo "blacklist brcmfmac"
            echo "blacklist brcmutil"
        } >> "${bl}"
        {
            echo "rfkill block wifi 2>/dev/null || true"
            echo "command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off 2>/dev/null || true"
        } >> "${act}"
        printf '[main]\n# WiFi disabled by default; managed=ethernet only.\n' \
            > "${sysroot}/etc/NetworkManager/conf.d/10-no-wifi.conf"
        info "WiFi DISABLED by default (rfkill block + blacklist + NM no-wifi). Re-enable with --enable-wifi."
    else
        info "WiFi ENABLED (--enable-wifi / ENABLE_WIFI=true)."
    fi

    if [ "${ENABLE_BLUETOOTH}" != "true" ]; then
        {
            echo "# Bluetooth disabled by default (ENABLE_BLUETOOTH=false) — hardened posture."
            echo "blacklist bluetooth"
            echo "blacklist btusb"
            echo "blacklist btbcm"
            echo "blacklist hci_uart"
        } >> "${bl}"
        echo "rfkill block bluetooth 2>/dev/null || true" >> "${act}"
        info "Bluetooth DISABLED by default (rfkill block + blacklist + no service). Re-enable with --enable-bluetooth."
    else
        info "Bluetooth ENABLED (--enable-bluetooth / ENABLE_BLUETOOTH=true)."
    fi

    echo "rm -f /etc/local.d/02-radio-hardening.start" >> "${act}"
    chmod +x "${act}"
    [ -s "${bl}" ] || echo "# (no radios blacklisted — both WiFi and Bluetooth enabled)" > "${bl}"
}

# Emit the first-boot grow policy file consumed by the growroot service. GROW=
# carries fill|none|<size>; the comment header documents the per-device overrides
# so an operator editing the copy on the FAT /boot needs no external docs.
write_growfs_conf() {
    local dest="$1"
    mkdir -p "$(dirname "${dest}")"
    cat > "${dest}" <<GROWFS_EOF
# growfs.conf — first-boot root-grow policy (read by the growroot service).
#   GROW=fill    grow the root to fill the WHOLE USB/SD/NVMe (DEFAULT)
#   GROW=none    do not grow; keep the compact flashed layout
#   GROW=<size>  cap the root filesystem, e.g. 16G, 12000M, 50% (% of device)
# Precedence (first wins): kernel cmdline growfs=<v> > this file on /boot >
#   /etc/growfs.conf (baked) > built-in fill. Edit this copy on the FAT /boot
#   partition to retune a single flashed medium without rebuilding the image.
GROW=${GROW_POLICY}
GROWFS_EOF
}

# ── ENV app-gate (deterministic prune of the BAKED apps/ tree) ─────────────
# ArgoCD recurses specs/cluster/apps with recurse:true, so physically removing
# a YAML from the baked copy is the gate (no live-cluster conditional needed).
# Operates ONLY on ${SYSROOT}/var/lib/snapdragon/cluster/apps — never the repo.
#   prod => prune the LAN wildcard-DNS app (public DNS is authoritative instead).
#   test => prune the go-live cloudflared app (no Cloudflare/ACME on a LAN). The
#           LAN wildcard-DNS app is kept ONLY for a `.test` domain, so it can
#           never become authoritative for a real public domain (e.g. a default
#           ENV=test build still on snapdragon.systems keeps neither edge).
# ── OPTIONAL-SERVICE gate ───────────────────────────────────────────────────
# Prune every OPTIONAL service (akkoma/tuwunel/phpbb/games) NOT selected in
# OPTIONAL_SERVICES from the baked GitOps tree, enumerated by
# specs/cluster/optional-services.yaml. Same `rm -f` design as gate_env_apps
# (removing a baked Application IS the gate; ArgoCD recurse:true never
# instantiates it). Arch-neutral — identical logic on arm64/amd64; the gate
# operates on the shared specs/cluster tree both builders bake. For each
# unselected slug it removes the owned apps + manifests dir, its per-service ESO
# file (+ kustomization line), its gateway HOST routes + route-access rows (so a
# matched route to a deleted upstream cannot 502 and a leftover role row cannot
# stale-grant). Shared social-ui is removed only when BOTH homeservers go.
#
# ⚠ RUNTIME NOTE: build-time prune only stops the bootstrap seed; the live
# cluster syncs apps/ from the gitops repo. True runtime add/remove uses the
# installed-services ConfigMap + the optional-services ApplicationSet
# (apps/13a-optional-services.yaml). See docs/OPTIONAL-SERVICES.md.
#
# ⚠ CROSS-REPO TODO (gateway wave): CanonicalSeed.java (snapdragon-gateway) +
# the cloudflared configmap reserved hostnames must stay in sync with the rows
# pruned here. NOT edited by this build (separate repo / image rebuild).
_opt_selected() {
    local s; for s in ${OPTIONAL_SERVICES}; do [ "${s}" = "$1" ] && return 0; done
    return 1
}
gate_optional_services() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    local apps="${tree}/apps"
    [ -d "${apps}" ] || return 0
    local slug
    for slug in akkoma tuwunel phpbb games; do
        _opt_selected "${slug}" && continue
        info "OPTIONAL_SERVICES: '${slug}' NOT selected — pruning it from the baked tree"
        case "${slug}" in
            akkoma)
                rm -f "${apps}/30-akkoma.yaml"
                rm -rf "${tree}/manifests/akkoma"
                rm -f "${tree}/manifests/external-secrets/akkoma-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" akkoma-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" mastodon-oauth mastodon-api mastodon-web
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/api/v1/pleroma/admin/**' '/api/pleroma/admin/**' '/pleroma/admin/**'
                ;;
            tuwunel)
                rm -f "${apps}/30-tuwunel.yaml"
                rm -rf "${tree}/manifests/tuwunel"
                rm -f "${tree}/manifests/external-secrets/tuwunel-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tuwunel-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" matrix-api matrix-wellknown matrix
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/_matrix/**' '/.well-known/matrix/**' '/_synapse/**'
                ;;
            phpbb)
                rm -f "${apps}/30-phpbb.yaml" "${apps}/38-forum-bff-db.yaml" \
                      "${apps}/39-forum-bff-api.yaml" "${apps}/49-forum-ui.yaml"
                rm -rf "${tree}/manifests/forum"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" forum-ui snapdragon-forum-bff-api snapdragon-forum-bff-api-moderation
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/social/forum/**' '/bff/forum/admin/**' '/bff/forum/moderation/**' '/bff/forum/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/api/forum/admin/**'
                ;;
            games)
                rm -f "${apps}/06-casdoor-games.yaml" "${apps}/50-games.yaml"
                rm -rf "${tree}/manifests/games" "${tree}/manifests/casdoor-games"
                _opt_drop_route     "${apps}/20-gateway-be.yaml" games
                _opt_drop_extrahost "${apps}/20-gateway-be.yaml" games.
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/games/api/admin/**' '/games/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/games/admin/**'
                ;;
        esac
    done
    if ! _opt_selected akkoma && ! _opt_selected tuwunel; then
        rm -f "${apps}/45-social-ui.yaml"
        info "OPTIONAL_SERVICES: both homeservers deselected — pruned shared apps/45-social-ui.yaml"
    fi
    # Repair a possible trailing comma if the LAST VALUES row of an INSERT was pruned.
    _opt_fix_trailing_comma "${tree}/manifests/route-access/initdb/20-schema.sql"
    _opt_render_installed_services
}
# Fix the dangling trailing comma left when the LAST VALUES row of an INSERT was
# pruned: rewrite the trailing '),' of the final data row before 'ON CONFLICT' to ')'.
_opt_fix_trailing_comma() {
    local f="$1"
    [ -f "${f}" ] || return 0
    awk '
        { lines[NR]=$0 }
        END {
            oc=0
            for (i=NR; i>=1; i--) { if (lines[i] ~ /ON CONFLICT/) { oc=i; break } }
            if (oc>0) {
                for (i=oc-1; i>=1; i--) {
                    if (lines[i] ~ /^[[:space:]]*\(.*\)[[:space:]]*,([[:space:]]*--.*)?$/) {
                        sub(/\)[[:space:]]*,/, ")", lines[i]); break
                    }
                    if (lines[i] ~ /^[[:space:]]*\(.*\)([[:space:]]*--.*)?$/) break
                }
            }
            for (i=1;i<=NR;i++) print lines[i]
        }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
_opt_drop_kustomize_line() {
    local f="$1" res="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+${res}([[:space:]].*)?\$|d" "${f}"
}
_opt_drop_route() {
    local f="$1"; shift
    [ -f "${f}" ] || return 0
    local rid
    for rid in "$@"; do
        awk -v rid="${rid}" '
            BEGIN { skip=0; ind=-1 }
            {
                line=$0
                match(line, /^ */); cur=RLENGTH
                if (skip) {
                    if (line ~ /^ *- id:/ && cur<=ind) { skip=0 }
                    else if (line !~ /^ *$/ && cur<=ind && line !~ /^ *#/) { skip=0 }
                    else { next }
                }
                if (line ~ ("^ *- id: " rid "$")) { skip=1; ind=cur; next }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
_opt_drop_extrahost() {
    local f="$1" prefix="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+\"?${prefix}[^[:space:]\"]*\"?[[:space:]]*\$|d" "${f}"
}
_opt_drop_rows() {
    local f="$1" gw="$2"; shift 2
    [ -f "${f}" ] || return 0
    local pat
    for pat in "$@"; do
        awk -v gw="${gw}" -v pat="${pat}" '
            BEGIN { needle = "(\x27" gw "\x27" }
            {
                line=$0
                t=line; sub(/^[[:space:]]+/, "", t)
                if (index(t, needle)==1) {
                    rest=t; sub(/^\([[:space:]]*\x27[^\x27]*\x27[[:space:]]*,[[:space:]]*\x27/, "", rest)
                    q=index(rest, "\x27")
                    if (q>0 && substr(rest,1,q-1)==pat) { next }
                }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
_opt_render_installed_services() {
    local cm="${SYSROOT}/var/lib/snapdragon/cluster/manifests/policy/installed-services-configmap.yaml"
    [ -f "${cm}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        sed -i -E "s#^([[:space:]]*)${slug}:[[:space:]]*\"(true|false)\"#\\1${slug}: \"${val}\"#" "${cm}"
    done
    info "OPTIONAL_SERVICES: rendered installed-services ConfigMap (selected: ${OPTIONAL_SERVICES:-none})"
}
# Parameterize the games-realm OIDC identity on GAMES_DOMAIN (rebrand_sysroot does
# not touch .games). Runs UNCONDITIONALLY and BEFORE rebrand so the default literal
# games.snapdragon.systems composes with snapdragon.systems->CLUSTER_DOMAIN; a custom
# GAMES_DOMAIN is rebrand-neutral. Fixes iss-strict games login on the subdomain default.
parameterize_games_domain() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    [ -d "${tree}" ] || return 0
    local f n=0
    # URL-SCHEME-ANCHORED: only rewrite snapdragon.games when it is a HOST (right
    # after the // of https://...), so the games-realm origin/issuer/redirect/website
    # URLs flip to ${GAMES_DOMAIN} while the canonical IMAGE repo paths
    # (snapdragon-systems/snapdragon.games-backend, .../snapdragon.games/backend) are
    # left untouched.
    while IFS= read -r -d '' f; do
        if grep -q '//id\.snapdragon\.games\|//snapdragon\.games' "${f}" 2>/dev/null; then
            sed -i -E \
                -e "s|//id\\.snapdragon\\.games|//id.${GAMES_DOMAIN}|g" \
                -e "s|//snapdragon\\.games|//${GAMES_DOMAIN}|g" \
                "${f}"
            n=$((n+1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sql' \) -print0 2>/dev/null)
    info "Games domain: parameterized games host URLs -> ${GAMES_DOMAIN} in ${n} file(s)"
    # If the operator set a CUSTOM GAMES_DOMAIN (e.g. the real <brand>.games TLD),
    # the games PUBLIC host (gateway-be route host + ingress extraHost) must follow
    # it; the default "games.snapdragon.systems" otherwise composes with rebrand.
    if [ "${GAMES_DOMAIN}" != "games.snapdragon.systems" ]; then
        local be="${tree}/apps/20-gateway-be.yaml"
        [ -f "${be}" ] && sed -i -E "s#games\\.snapdragon\\.systems#${GAMES_DOMAIN}#g" "${be}"
        info "Games domain: custom GAMES_DOMAIN — games host rewritten to ${GAMES_DOMAIN}"
    fi
}

gate_env_apps() {
    local apps="${SYSROOT}/var/lib/snapdragon/cluster/apps"
    [ -d "${apps}" ] || return 0
    if [ "${ENV}" = "prod" ]; then
        rm -f "${apps}/09-lan-dns.yaml" && \
            info "ENV=prod: pruned LAN wildcard-DNS app 09-lan-dns.yaml from the baked tree"
        return 0
    fi
    # ENV=test
    rm -f "${apps}/12-cloudflared.yaml" && \
        info "ENV=test: pruned go-live app 12-cloudflared.yaml from the baked tree"
    case "${CLUSTER_DOMAIN}" in
        *.test) info "ENV=test: LAN wildcard DNS authoritative for ${CLUSTER_DOMAIN}" ;;
        *) rm -f "${apps}/09-lan-dns.yaml" && \
               warn "ENV=test but domain '${CLUSTER_DOMAIN}' is not .test — pruned 09-lan-dns.yaml so it cannot hijack a real domain (use brands/local.conf / 'make local' for a .test LAN build)" ;;
    esac
}

# Rewrites the cluster GitOps payload + role markers from the default
# "snapdragon"/"snapdragon.systems" naming to ${BRAND}/${CLUSTER_DOMAIN}/${ORG}.
# Internal install paths (/var/lib/snapdragon, /etc/snapdragon) and the
# provisioning JSON key are intentionally NOT touched (tool vendor namespace).
rebrand_sysroot() {
    if [ "${BRAND}" = "snapdragon" ] && [ "${CLUSTER_DOMAIN}" = "snapdragon.systems" ] \
       && [ "${ORG}" = "Snapdragon-Systems" ] && [ "${BRAND_TITLE}" = "Snapdragon Systems" ]; then
        info "Branding: default (snapdragon) — no rebrand"
        return 0
    fi
    banner "Rebranding baked config -> brand=${BRAND} domain=${CLUSTER_DOMAIN} org=${ORG}"
    local org_lc; org_lc="$(echo "${ORG}" | tr '[:upper:]' '[:lower:]')"
    local roots=("${SYSROOT}/var/lib/snapdragon/cluster" "${SYSROOT}/etc/snapdragon")
    local f
    while IFS= read -r -d '' f; do
        sed -i \
            -e "s|Snapdragon Systems|${BRAND_TITLE}|g" \
            -e "s|snapdragon-systems/|${org_lc}/|g" \
            -e "s|Snapdragon-Systems|${ORG}|g" \
            -e "s|//id\.snapdragon\.games|//id.${GAMES_DOMAIN}|g" \
            -e "s|//snapdragon\.games|//${GAMES_DOMAIN}|g" \
            -e "s|snapdragon\.systems|${CLUSTER_DOMAIN}|g" \
            -e "s|snapdragon-|${BRAND}-|g" \
            "${f}"
    done < <(find "${roots[@]}" -type f -print0 2>/dev/null)
    info "Rebrand complete (compound names like '${BRAND}-systems-web' may want review)."
}

banner "Verifying prerequisites"

# Check spec directories (arch-specific + shared)
if [ ! -d "${SPECS_DIR}" ]; then
    err "RPi5 specs directory not found: ${SPECS_DIR}"
    err "Expected to find it next to this script, or pass --specs-dir."
    exit 1
fi
if [ ! -d "${SHARED_SPECS}" ]; then
    err "Shared specs directory not found: ${SHARED_SPECS}"
    err "Expected to find specs/ next to this script."
    exit 1
fi
info "RPi5 specs:   ${SPECS_DIR}"
info "Shared specs: ${SHARED_SPECS}"

# Check toolchain
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    if ! command -v "${tool}" &>/dev/null; then
        err "${tool} not found in PATH."
        exit 1
    fi
done

# ── Host SELinux policy build tools ────────────────────────────────
# sec-policy/selinux-base's src_compile runs refpolicy's `emake base`, which
# assembles base.pp with the HOST binaries checkpolicy/checkmodule (sys-apps/
# checkpolicy) AND semodule_package (sys-apps/semodule-utils). refpolicy
# hardcodes their absolute /usr/bin paths (Makefile SEMOD_PKG ?= $(BINDIR)/
# semodule_package), so they must exist on the x86 BUILD host — a cross/target
# copy is aarch64 and can't run here, and --with-bdeps=n means portage won't
# pull the ebuild BDEPEND anyway (selinux-base's BDEPEND even omits semodule-
# utils). Without semodule_package, `emake base` dies and selinux-base fails
# src_compile, so NO .pp ships and keys-provision has nothing to load at first
# boot. Provision them natively here. Building base.pp at compile time loads
# nothing into a kernel (selinux-base has no pkg_postinst); the policy-store
# load stays deferred to first boot (provision_selinux). Build runs as root.
#
# containerd[selinux] (selinux is profile-FORCED on the hardened/selinux profile) pulls
# the docker/container SELinux policy, whose resolution drags in a HOST selinux-python/
# policycoreutils toolchain to compile + manage the .pp modules. Those are CBUILD/x86
# packages — note the ABI_X86 + host PYTHON_TARGETS=3.12/3.13/3.14 in the emerge plan —
# so they read the HOST's /etc/portage, NOT the cross sysroot's (PORTAGE_CONFIGROOT only
# governs the aarch64 ROOT). That toolchain needs libselinux[python]+audit[python], but
# the host config carries no such pre-seed and cross_emerge runs WITHOUT --autounmask, so
# the whole chain (and thus app-containers/containerd, a payload-MANDATORY binary) is
# silently SKIPPED and trips the stage4 assert. Pre-seed the HOST config so the host
# selinux toolchain can build with python. (specs-rpi5/portage/package.use/selinux covers
# the TARGET libselinux/audit; this covers the HOST x86 build tools — distinct configs.)
if [ "$(id -u)" -eq 0 ]; then
    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/snapdragon-cross-host-selinux <<'HOSTSELINUX'
# Auto-written by build-rpi5-stage4.sh (rpi5 CROSS build). The HOST x86 selinux-python/
# policycoreutils toolchain — pulled to compile the docker/container policy that
# containerd[selinux] requires — needs python bindings. Without this the cross_emerge
# (no --autounmask) silently skips containerd. Safe to delete on a non-build host.
sys-libs/libselinux python
sys-process/audit    python
HOSTSELINUX
    info "Pre-seeded HOST /etc/portage/package.use: libselinux[python]+audit[python] (containerd selinux toolchain)"
fi

HOST_POLICY_TOOLS=()
command -v checkpolicy       &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/checkpolicy)
command -v checkmodule       &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/checkpolicy)
command -v semodule_package  &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/semodule-utils)
command -v m4                &>/dev/null || HOST_POLICY_TOOLS+=(sys-devel/m4)
if [ "${#HOST_POLICY_TOOLS[@]}" -ne 0 ]; then
    readarray -t HOST_POLICY_TOOLS < <(printf '%s\n' "${HOST_POLICY_TOOLS[@]}" | sort -u)
    if [ "$(id -u)" -eq 0 ] && command -v emerge &>/dev/null; then
        warn "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]} — emerging natively"
        # NATIVE host emerge (no ROOT/SYSROOT/PORTAGE_CONFIGROOT overrides):
        # these are x86 build tools, NOT part of the aarch64 sysroot.
        emerge --noreplace --quiet "${HOST_POLICY_TOOLS[@]}" \
            || { err "Failed to install host SELinux build tools (${HOST_POLICY_TOOLS[*]})."; \
                 err "selinux-base src_compile (emake base) needs host checkpolicy + semodule_package."; exit 1; }
    else
        err "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]}"
        err "Install on the BUILD host (NOT the sysroot): emerge sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4"
        err "selinux-base's 'emake base' assembles base.pp with the host checkpolicy/checkmodule/semodule_package."
        exit 1
    fi
fi
info "Host SELinux policy build tools present (checkpolicy, checkmodule, semodule_package, m4)"

if ! ${SKIP_ISO} && ! command -v xorrisofs &>/dev/null; then
    err "xorrisofs not found in PATH (needed for ISO generation)."
    err "Pass --skip-iso to skip, or install dev-libs/libisoburn."
    exit 1
fi

info "Cross-compiler: $(${CROSS_TARGET}-gcc --version | head -1)"
info "Jobs: ${JOBS}"

banner "Preparing build directories"

mkdir -p "${WORK_DIR}"
mkdir -p "${BUILD_ROOT}"/{distfiles,pkgdir,log}
mkdir -p "${SYSROOT}"
# The isoroot is per-run OUTPUT staging, never an input: a stale tree from a
# previous run used to poison build_img with an old kernel/config.txt and
# accumulate timestamped stage4 tarballs the installer then picked arbitrarily
# (unsorted find | head -1). Start every run clean.
rm -rf "${ISO_DIR}"
mkdir -p "${ISO_DIR}"

info "Work directory: ${WORK_DIR}  (products land here)"
info "Build root:     ${BUILD_ROOT}  (per-arch sysroot/distfiles/pkgdir)"
info "Sysroot:        ${SYSROOT}"

# Start build log
exec > >(tee -a "${LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE}"

banner "Fetching latest arm64 stage3 seed tarball"

# The index is PGP-signed; select the stage3 tarball line, ignoring armor/comments.
STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
STAGE3_BASENAME=$(basename "${STAGE3_FILE}")
STAGE3_FULL_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/${STAGE3_FILE}"
# Per-arch: the aarch64 seed must not be reused by (or clobber) the amd64 build.
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
    # A non-resume build over an ALREADY-POPULATED sysroot must start CLEAN.
    # `tar -xpf` only OVERLAYS the stage3 — it never deletes the leftovers of a
    # prior attempt. Stacking attempts leaves a HYBRID sysroot whose libraries
    # carry stale, DANGLING .so dev symlinks: once a rebuild bumps a soname,
    # libgpg-error.so still points at the gone libgpg-error.so.0.41.2 and
    # libunistring.so.5 at the gone 5.2.0, so the cross-linker dies
    # "cannot find -lgpg-error" / "libunistring.so.5 not found" on @system
    # packages (pinentry, elfutils via libpsl, gnutls...). Wipe first so every
    # library is installed exactly once with a symlink that matches its soname.
    # (Mirrors the x86 builder's 894584e wipe-before-extract.)
    if [ -f "${SYSROOT}/etc/gentoo-release" ]; then
        warn "Sysroot already populated and NOT --resume: wiping for a clean stage3 extract (stale dangling .so symlinks otherwise break the cross-link of pinentry/elfutils/gnutls)"
        rm -rf "${SYSROOT:?}"
        mkdir -p "${SYSROOT}"
    fi
    # The stage3 carries /dev device nodes (mknod) + root ownership. A non-root
    # cross-build can't create those, so skip device nodes on extract (the
    # target populates /dev via devtmpfs at boot) and don't try to chown. The
    # final stage4 tarball is forced to root ownership below, so the on-disk
    # build-user ownership here doesn't matter. (Harmless when run as root too.)
    TAR_X=(--exclude='./dev/*')
    [ "$(id -u)" -ne 0 ] && TAR_X+=(--no-same-owner)
    tar -C "${SYSROOT}" --xattrs-include='*.*' "${TAR_X[@]}" -xpf "${STAGE3_LOCAL}" 2>/dev/null || \
    tar -C "${SYSROOT}" "${TAR_X[@]}" -xpf "${STAGE3_LOCAL}"
    mkdir -p "${SYSROOT}/dev"
    info "Extracted into ${SYSROOT} (device nodes skipped; devtmpfs at boot)"
fi

banner "Installing spec files into sysroot (hardened profile)"

# Compute PCIE_LINE for templates
if ${PCIE_GEN3}; then
    PCIE_LINE="dtparam=pciex1_gen=3"
else
    PCIE_LINE="# dtparam=pciex1_gen=3"
fi

# Portage directories
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,package.mask,profile,env,package.env,repos.conf}

# Point the sysroot at the HOST's gentoo ebuild repo (absolute path) so the
# cross-emerge — run with PORTAGE_CONFIGROOT=${SYSROOT} — can resolve the
# profile + ebuilds. The stage3 ships a *relative* make.profile symlink that
# resolves inside the (repo-less) sysroot and yields "profile is invalid".
GENTOO_REPO="$(portageq get_repo_path / gentoo 2>/dev/null || echo /var/db/repos/gentoo)"
cat > "${SYSROOT}/etc/portage/repos.conf/gentoo.conf" <<EOF
[DEFAULT]
main-repo = gentoo
[gentoo]
location = ${GENTOO_REPO}
EOF
# Select the profile via an ABSOLUTE make.profile symlink derived from
# profile/parent (strip the "gentoo:" repo prefix). use.mask is layered on top
# as a local override (NOT a base-profile selector).
PROFILE_PATH="$(sed 's/^gentoo://' "${SPECS_DIR}/portage/profile/parent" | tr -d '[:space:]')"
[ -d "${GENTOO_REPO}/profiles/${PROFILE_PATH}" ] || { err "profile not found: ${GENTOO_REPO}/profiles/${PROFILE_PATH}"; exit 1; }
ln -sfn "${GENTOO_REPO}/profiles/${PROFILE_PATH}" "${SYSROOT}/etc/portage/make.profile"
cp "${SPECS_DIR}/portage/profile/use.mask"                "${SYSROOT}/etc/portage/profile/use.mask"
# Copy every file in these portage config dirs (so added spec files always land).
cp "${SPECS_DIR}/portage/package.accept_keywords/"*       "${SYSROOT}/etc/portage/package.accept_keywords/"
cp "${SPECS_DIR}/portage/package.use/"*                   "${SYSROOT}/etc/portage/package.use/"
cp "${SPECS_DIR}/portage/package.env/"*                   "${SYSROOT}/etc/portage/package.env/"
# Plain (non-templated) per-package env files, e.g. python-cross.conf. The .tmpl
# env files (cross-go.conf) are rendered separately just below.
cp "${SPECS_DIR}/portage/env/"*.conf                      "${SYSROOT}/etc/portage/env/" 2>/dev/null || true

# Templated portage specs
render_template "${SPECS_DIR}/portage/make.conf.tmpl"     "${SYSROOT}/etc/portage/make.conf"
render_template "${SPECS_DIR}/portage/env/cross-go.conf.tmpl" "${SYSROOT}/etc/portage/env/cross-go.conf"

# Boot files: config.txt + cmdline.txt are written AFTER Phase 2 (see below),
# NOT here. sys-boot/raspberrypi-firmware's pkg_preinst hard-dies if it finds a
# pre-existing /boot/config.txt or /boot/cmdline.txt (it owns those paths), so
# pre-placing them made the firmware fail to merge — leaving the image with no
# boot firmware (start4.elf, fixup4.dat, …) and therefore unbootable on a Pi 5.
mkdir -p "${SYSROOT}/boot"
# Clear any stale copies left by a previous interrupted/broken run, so the
# firmware preinst can merge cleanly even on --resume of a dirty sysroot. Our
# templated versions are (re)written after Phase 2.
rm -f "${SYSROOT}/boot/config.txt" "${SYSROOT}/boot/cmdline.txt"

# /etc config files
# fstab is RPi-specific (mounts the /boot firmware partition) -> SPECS_DIR.
cp "${SPECS_DIR}/etc/fstab"                               "${SYSROOT}/etc/fstab"

# Everything below is arch-agnostic and shared with the x86 build -> SHARED_SPECS.
mkdir -p "${SYSROOT}/etc/modules-load.d"
cp "${SHARED_SPECS}/etc/modules-load.d/kubernetes.conf"   "${SYSROOT}/etc/modules-load.d/kubernetes.conf"

mkdir -p "${SYSROOT}/etc/sysctl.d"
cp "${SHARED_SPECS}/etc/sysctl.d/10-hardened.conf"        "${SYSROOT}/etc/sysctl.d/10-hardened.conf"
cp "${SHARED_SPECS}/etc/sysctl.d/99-kubernetes.conf"      "${SYSROOT}/etc/sysctl.d/99-kubernetes.conf"

mkdir -p "${SYSROOT}/etc/containerd"
cp "${SHARED_SPECS}/etc/containerd/config.toml"           "${SYSROOT}/etc/containerd/config.toml"

mkdir -p "${SYSROOT}/var/lib/kubelet"
cp "${SHARED_SPECS}/etc/kubernetes/kubelet-config.yaml"   "${SYSROOT}/var/lib/kubelet/config.yaml"

mkdir -p "${SYSROOT}/etc/kubernetes"
cp "${SHARED_SPECS}/etc/kubernetes/kubeadm-config.yaml"   "${SYSROOT}/etc/kubernetes/kubeadm-config.yaml"

mkdir -p "${SYSROOT}/etc/init.d"
for svc in growroot containerd kubelet headscale tailscaled keys-provision; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"
    chmod +x "${SYSROOT}/etc/init.d/${svc}"
done

# First-boot grow policy (read by the growroot service). Default "fill" => the
# root expands to fill the whole USB/SD/NVMe on first boot; --grow none keeps the
# compact flashed layout; --grow <size> caps the root filesystem. A copy is also
# dropped on the FAT /boot in build_img so it can be edited per-device after a
# flash without rebuilding. Precedence at boot: kernel cmdline growfs= >
# /boot/growfs.conf > /etc/growfs.conf > built-in fill.
write_growfs_conf "${SYSROOT}/etc/growfs.conf"

# Headscale default config + fleet full-mesh ACL (overridable from KEYS USB).
# policy.hujson is referenced by config.yaml (policy.mode: file) and applied by
# keys-provision via `headscale policy set`.
mkdir -p "${SYSROOT}/etc/headscale"
cp "${SHARED_SPECS}/etc/headscale/config.yaml"            "${SYSROOT}/etc/headscale/config.yaml"
# Layer-A: bake the BOOTSTRAP policy AS the initial policy.hujson (NO any-to-any
# :22 hole; KEEPS the k8s CIDR data-plane rule). First verified Layer-A sync
# re-renders it from policy.hujson.tmpl. (See build-x86-host-stage4.sh rationale.)
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson" "${SYSROOT}/etc/headscale/policy.hujson"

# KEYS-USB provisioning engine
mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/var/lib/keys-provision"
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh"      "${SYSROOT}/usr/sbin/keys-provision"
chmod +x "${SYSROOT}/usr/sbin/keys-provision"

# Backup engine (etcd + PostgreSQL -> attached storage / network share)
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-backup"     "${SYSROOT}/usr/local/sbin/snapdragon-backup"
chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-backup"

mkdir -p "${SYSROOT}/etc/ssh/sshd_config.d"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/hardened.conf"  "${SYSROOT}/etc/ssh/sshd_config.d/hardened.conf"

# ── Layer-B device-license-registry sshd enforcement (ADMIN/mesh-extension) ─────
# Bake the SOLE-key-source plumbing into the rootfs. These files are INERT on a
# SUPERADMIN/core node: provision_device_registry() only ACTIVATES them (installs
# the conf into sshd_config.d, enables the service+cron) when owner_type=ADMIN, so
# baking them unconditionally does NOT alter the #66 owner-key path on core nodes.
# The enforcement drop-in (device-registry.conf) + break-glass.conf + the cron are
# STAGED under /etc/snapdragon/registry so provision installs them on ADMIN nodes
# only (device-registry.conf is gate-flipped on the first verified sync).
mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/usr/lib/snapdragon" \
         "${SYSROOT}/etc/snapdragon/registry" "${SYSROOT}/var/lib/snapdragon/device-registry"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-authorized-keys-lookup" "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-device-registry-sync"   "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup" "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/usr/lib/snapdragon/registry-verify.sh"      "${SYSROOT}/usr/lib/snapdragon/registry-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"
# Staged (NOT placed into sshd_config.d / cron.d here — provision installs them on
# ADMIN nodes only; device-registry.conf is gate-flipped on first verified sync).
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

# ── Egress-VPN reconcile bridge (signed per-node export consumer) — DEFAULT-OFF ─
# Bake the reconcile agent + its verify lib + the OpenRC service into every node
# image. INERT until enabled (the optional-services gate enables the service + cron
# when the egress-VPN service is selected; with no transport/assignment it is a
# verified no-op). REUSES the baked registry-pub.ed25519 (Layer-B's key — never
# re-bake). The cron drop-in is STAGED at /etc/snapdragon/registry (the gate places
# it into /etc/cron.d on selection), mirroring the device-registry-sync staging.
cp "${SHARED_SPECS}/usr/sbin/snapdragon-vpn-reconcile" "${SYSROOT}/usr/sbin/snapdragon-vpn-reconcile"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-vpn-reconcile"
cp "${SHARED_SPECS}/usr/lib/snapdragon/vpn-verify.sh" "${SYSROOT}/usr/lib/snapdragon/vpn-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-vpn-reconcile" "${SYSROOT}/etc/init.d/snapdragon-vpn-reconcile"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-vpn-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-vpn-reconcile" "${SYSROOT}/etc/snapdragon/registry/cron-vpn-reconcile"

mkdir -p "${SYSROOT}/etc/snapdragon"
echo "${ROLE}"           > "${SYSROOT}/etc/snapdragon/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/snapdragon/cluster-domain"
# Runtime ENV marker (test|prod). Read by bootstrap/provision; also documents
# the image's posture. test => LAN wildcard DNS authoritative; prod => public.
echo "${ENV}"            > "${SYSROOT}/etc/snapdragon/env"
# Bake the brand's mesh control-server URL so keys-provision can read it at
# first boot (env does not survive to first boot). Empty = local-first: the
# control node defaults server_url to its own LAN IP (resolve_endpoint).
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/snapdragon/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/snapdragon/headscale-url"
fi
if [ -d "${SHARED_SPECS}/cluster" ]; then
    mkdir -p "${SYSROOT}/var/lib/snapdragon"
    cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/snapdragon/cluster"
    info "Installed cluster GitOps payload (role=${ROLE})"
    parameterize_games_domain  # rewrite .games -> ${GAMES_DOMAIN} (BEFORE rebrand; fixes games OIDC iss on the subdomain default)
    gate_env_apps              # prune ENV-specific ArgoCD apps from the baked copy
    gate_optional_services     # prune OPTIONAL services (akkoma/tuwunel/phpbb/games) not in OPTIONAL_SERVICES
fi

# Apply the configured brand/domain to the baked tree (no-op for defaults).
# Runs AFTER gate_env_apps so the surviving lan-dns/cloudflared manifests get
# their snapdragon.systems -> ${CLUSTER_DOMAIN} rewrite too.
rebrand_sysroot

mkdir -p "${SYSROOT}/etc/local.d"
render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"

# Hostname, timezone, locale
echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"
echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${SYSROOT}/etc/localtime"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"

# CNI / containerd directories
mkdir -p "${SYSROOT}/opt/cni/bin"
mkdir -p "${SYSROOT}/etc/cni/net.d"
mkdir -p "${SYSROOT}/etc/containerd/certs.d"

# OpenRC service links
mkdir -p "${SYSROOT}/etc/runlevels/default"
# growroot expands the root fs to fill the medium on first boot; it orders itself
# before keys-provision so provisioning sees the full disk (no-op in containers).
DEFAULT_SVCS=(sshd NetworkManager cronie haveged growroot keys-provision containerd kubelet auditd local)
# headscale runs on the PKI/identity node (and on a generic all-in-one image)
if [ "${ROLE}" = "pki" ] || [ "${ROLE}" = "generic" ]; then
    DEFAULT_SVCS+=(headscale)
fi
# tailscale client everywhere unless the mesh / client is skipped
if ! ${SKIP_MESH} && ! ${SKIP_TAILSCALE}; then
    DEFAULT_SVCS+=(tailscaled)
fi
for svc in "${DEFAULT_SVCS[@]}"; do
    ln -sf "/etc/init.d/${svc}" "${SYSROOT}/etc/runlevels/default/${svc}" 2>/dev/null || true
done

# ── Radio hardening: WiFi + Bluetooth DISABLED BY DEFAULT ──────────────────
# Shrink the attack surface — by default neither radio comes up (modprobe.d
# blacklist + first-boot rfkill block + NM leaves WiFi unmanaged). ETHERNET +
# the Tailscale tailnet are UNTOUCHED. ENABLE_WIFI / ENABLE_BLUETOOTH re-enable.
harden_radios "${SYSROOT}"

info "Profile: ${PROFILE_PATH}"

cross_emerge() {
    # Keep emerge's log + dependency-metadata cache inside the work dir instead
    # of the host's /var/log + /var/cache/edb (which are root-owned). Still needs
    # to run as root: portage merges into the sysroot vdb and writes host caches.
    mkdir -p "${BUILD_ROOT}/log" "${BUILD_ROOT}/edb"
    # LANG/LC_ALL: a working locale (stage3 has none) or btrfs-progs etc. die with
    # "locale.Error: unsupported locale setting". --jobs=1: SERIALIZE package
    # builds — the payload's Go packages (kubelet/runc/cni-plugins...) were
    # OOM-killed at high concurrency on x86; one cross-Go build at a time keeps
    # RAM bounded (override with CROSS_EMERGE_JOBS). (Mirrors the x86 builder.)
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    ROOT="${SYSROOT}" \
    SYSROOT="${SYSROOT}" \
    PORTAGE_CONFIGROOT="${SYSROOT}" \
    EMERGE_LOG_DIR="${BUILD_ROOT}/log" \
    PORTAGE_DEPCACHEDIR="${BUILD_ROOT}/edb" \
    "${CROSS_TARGET}-emerge" \
        --jobs="${CROSS_EMERGE_JOBS:-1}" \
        --load-average="${JOBS}" \
        --with-bdeps=n \
        "$@"
}

banner "Phase 1: Cross-building @system (hardened)"

# A cross-built stage4 must NOT (cross-)rebuild the toolchain. Cross-building a
# target gcc/glibc/binutils and their target libs fails under crossdev with
# "configure: error: C compiler cannot create executables" (the build can't run
# freshly-built target binaries on the x86 host). The crossdev cross-compiler
# already provides the toolchain and the seed stage3 provides the target libc,
# so keep them as-is. Opt back in (rarely works) with REBUILD_TOOLCHAIN=true.
REBUILD_TOOLCHAIN="${REBUILD_TOOLCHAIN:-false}"
if ${REBUILD_TOOLCHAIN}; then
    CROSS_EXCLUDE=()
    warn "Toolchain rebuild ENABLED — cross-building gcc/glibc/binutils (usually fails)"
else
    CROSS_EXCLUDE=(--exclude sys-devel/gcc --exclude sys-devel/gcc-config
                   --exclude sys-libs/glibc --exclude sys-devel/binutils)
    info "Keeping crossdev/seed toolchain (set REBUILD_TOOLCHAIN=true to cross-rebuild it)"
fi

cross_emerge --oneshot --update sys-apps/baselayout
cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" @system \
    || warn "@system had package failures (--keep-going); continuing"

banner "Phase 2: Cross-building stage4 packages"

# Read package list from spec file, stripping comments and blanks
mapfile -t STAGE4_PACKAGES < <(
    grep -v '^\s*#' "${SPECS_DIR}/portage/packages.list" | grep -v '^\s*$'
)

# Append user-specified extra packages
if [ -n "${EXTRA_PACKAGES}" ]; then
    read -ra _extras <<< "${EXTRA_PACKAGES}"
    STAGE4_PACKAGES+=("${_extras[@]}")
    info "Extra packages: ${EXTRA_PACKAGES}"
fi

info "Package count: ${#STAGE4_PACKAGES[@]}"
# A single unsatisfiable atom (bad name, REQUIRED_USE, masked dep) fails the
# WHOLE batch dependency calc — and --keep-going can't rescue a calc failure,
# so nothing installs (incl. raspberrypi-sources → no kernel). If the batch
# fails, fall back to per-package emerges so one bad atom can't sink the rest.
if ! cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${STAGE4_PACKAGES[@]}"; then
    warn "Batch emerge failed (unsatisfiable atom?); retrying per-package so the rest still install"
    for _pkg in "${STAGE4_PACKAGES[@]}"; do
        cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${_pkg}" \
            || warn "  skipped ${_pkg}"
    done
fi

# The packages.list payload is MANDATORY for a usable role image — fail LOUDLY
# if the core set is missing rather than ship a payload-less stage4. The
# '|| warn' emerges above are allowed to continue (so one bad atom can't sink
# the whole list), which means THIS is the gate: the exact silent-failure
# class that shipped hollow x86 images for weeks (see build-x86-host-stage4.sh's
# matching "stage4 payload incomplete" assert). Binaries are aarch64, so test
# for file presence in the sysroot rather than command -v.
_payload_missing=""
for _b in kubelet kubeadm kubectl containerd NetworkManager nmcli sshd auditd crond jq parted flashrom rpi-eeprom-update; do
    _found=false
    for _d in usr/bin usr/sbin bin sbin; do
        if [ -e "${SYSROOT}/${_d}/${_b}" ]; then _found=true; break; fi
    done
    ${_found} || _payload_missing="${_payload_missing} ${_b}"
done
if [ -n "${_payload_missing}" ]; then
    err "stage4 payload incomplete — missing:${_payload_missing}"
    err "packages.list did not fully merge; review the emerge output above."
    exit 1
fi
info "Stage4 payload verified (kubelet kubeadm kubectl containerd NetworkManager nmcli sshd auditd crond jq parted flashrom rpi-eeprom-update)"

# ── 7a. Boot config (AFTER firmware is merged) ─────────────────────
# Written now — not in the spec-install phase — so raspberrypi-firmware's
# pkg_preinst didn't die on a pre-existing /boot/config.txt|cmdline.txt. Our
# templated versions are authoritative and overlay the firmware's defaults.
if [ -d "${SYSROOT}/boot" ]; then
    render_template "${SPECS_DIR}/boot/config.txt.tmpl" "${SYSROOT}/boot/config.txt"
    cp "${SPECS_DIR}/boot/cmdline.txt"                  "${SYSROOT}/boot/cmdline.txt"
    info "Boot config written (config.txt + cmdline.txt) over the firmware defaults"
fi

if ${SKIP_MESH}; then
    banner "Phase 2.5: SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Phase 2.5: Installing mesh VPN (headscale + tailscale)"

    HS_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_arm64"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
    info "Fetching headscale ${HEADSCALE_VERSION}..."
    if curl -fL -o "${HS_BIN}" "${HS_URL}"; then
        chmod +x "${HS_BIN}"
        file "${HS_BIN}" | grep -q 'ELF.*aarch64' || {
            rm -f "${HS_BIN}"
            err "headscale binary is not aarch64 — check --headscale-version"
            exit 1
        }
        info "headscale installed: /usr/bin/headscale"
    else
        rm -f "${HS_BIN}"   # curl -o may leave a truncated file behind
        err "headscale ${HEADSCALE_VERSION} fetch failed — the image enables the headscale"
        err "service in the default runlevel, so this would ship an inert mesh control plane."
        err "Retry, or pass --skip-mesh to opt out of the mesh VPN entirely."
        exit 1
    fi

    if ${SKIP_TAILSCALE}; then
        info "Skipping tailscale client (--skip-tailscale)"
    else
        TS_URL="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        TS_TGZ="${BUILD_ROOT}/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        info "Fetching tailscale ${TAILSCALE_VERSION}..."
        if curl -fL -o "${TS_TGZ}" "${TS_URL}"; then
            TS_TMP="$(mktemp -d)"
            tar -C "${TS_TMP}" -xzf "${TS_TGZ}"
            TS_SUB="$(find "${TS_TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
            install -Dm0755 "${TS_SUB}/tailscale"  "${SYSROOT}/usr/bin/tailscale"
            install -Dm0755 "${TS_SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
            rm -rf "${TS_TMP}"
            info "tailscale installed: /usr/bin/tailscale, /usr/sbin/tailscaled"
        else
            err "tailscale ${TAILSCALE_VERSION} fetch failed — the image enables tailscaled"
            err "in the default runlevel, so this would ship an inert mesh client."
            err "Retry, or pass --skip-tailscale (or --skip-mesh) to opt out."
            exit 1
        fi
    fi
fi

if ${SKIP_KERNEL}; then
    banner "Phase 3: SKIPPED (--skip-kernel)"
else
    banner "Phase 3: Cross-compiling hardened kernel"

    KERNEL_SRC=$(find "${SYSROOT}/usr/src/" -maxdepth 1 -name 'linux-*raspberrypi*' -type d 2>/dev/null | sort -V | tail -1)
    if [ -z "${KERNEL_SRC}" ]; then
        warn "No raspberrypi-sources found in sysroot, skipping kernel build."
        warn "You will need to provide a kernel separately."
    else
        info "Building kernel from ${KERNEL_SRC}..."
        info "Defconfig: ${RPI_DEFCONFIG}  CPU: ${RPI_CPU}"
        info "Config fragment: ${SPECS_DIR}/kernel/hardened-k8s.config"
        pushd "${KERNEL_SRC}" >/dev/null

        # Start from board defconfig
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" "${RPI_DEFCONFIG}"

        # Apply config fragment from spec file
        while IFS= read -r line; do
            # Skip comments and blank lines
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue

            # Parse: "enable CONFIG_FOO" / "module CONFIG_FOO" / etc.
            read -r action rest <<< "${line}"
            eval "scripts/config --${action} ${rest}"
        done < "${SPECS_DIR}/kernel/hardened-k8s.config"

        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" olddefconfig

        # Refuse to ship a kernel that silently lost SELinux or its KSPP
        # hardening (e.g. a defconfig bump dropping a dep that olddefconfig
        # then prunes), mirroring the x86 build's guard — stable, long-standing
        # KSPP/LSM symbols only. A malformed CONFIG_LSM == SELinux disabled.
        for must in CONFIG_SECURITY_SELINUX CONFIG_SECURITY_SELINUX_BOOTPARAM \
                    CONFIG_STACKPROTECTOR_STRONG CONFIG_FORTIFY_SOURCE \
                    CONFIG_HARDENED_USERCOPY; do
            grep -q "^${must}=y" .config || { err "hardened kernel option ${must} not enabled after olddefconfig"; exit 1; }
        done
        grep -q '^CONFIG_LSM="yama,selinux,bpf"$' .config || { err "CONFIG_LSM malformed (expected yama,selinux,bpf); SELinux would not activate"; exit 1; }

        # Build
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" -j"${JOBS}" \
            Image modules dtbs

        # Install
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" \
            INSTALL_MOD_PATH="${SYSROOT}" modules_install

        mkdir -p "${SYSROOT}/boot/overlays"
        cp arch/arm64/boot/Image "${SYSROOT}/boot/${RPI_KERNEL_IMG}"
        cp arch/arm64/boot/dts/broadcom/${RPI_DTB_PREFIX}*.dtb "${SYSROOT}/boot/"
        cp arch/arm64/boot/dts/overlays/*.dtb* "${SYSROOT}/boot/overlays/" 2>/dev/null || true
        cp arch/arm64/boot/dts/overlays/README "${SYSROOT}/boot/overlays/" 2>/dev/null || true

        popd >/dev/null
        info "Kernel build complete."
    fi
fi

if ${SKIP_CLEAN}; then
    banner "Cleaning: SKIPPED (--skip-clean)"
else
    banner "Cleaning sysroot"

    rm -rf "${SYSROOT}"/usr/share/doc/*
    rm -rf "${SYSROOT}"/usr/share/man/*
    rm -rf "${SYSROOT}"/usr/share/info/*
    rm -rf "${SYSROOT}"/usr/include/*
    rm -rf "${SYSROOT}"/usr/src/*
    rm -rf "${SYSROOT}"/var/cache/distfiles/*
    rm -rf "${SYSROOT}"/var/tmp/*
    rm -rf "${SYSROOT}"/tmp/*

    find "${SYSROOT}"/{usr/bin,usr/sbin,usr/lib64,lib64} \
        -type f -executable 2>/dev/null | while read -r f; do
        file "$f" | grep -q 'ELF.*aarch64' && "${CROSS_TARGET}-strip" --strip-unneeded "$f" 2>/dev/null || true
    done

    info "Sysroot cleaned and binaries stripped."
fi

banner "Phase 4: Packaging stage4 tarball"

STAGE4_TARBALL="${WORK_DIR}/${BRAND}-rpi5-arm64-${ROLE}-${ENV}-${BUILD_TS}.stage4.tar.xz"

# Force root ownership in the archive (--owner/--group=0): a non-root build owns
# the sysroot as the build user, but the installed system must be root-owned.
tar -C "${SYSROOT}" \
    --xattrs-include='*.*' \
    --numeric-owner --owner=0 --group=0 \
    --exclude='./usr/src' \
    --exclude='./var/cache' \
    --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" . 2>/dev/null || \
tar -C "${SYSROOT}" \
    --numeric-owner --owner=0 --group=0 \
    --exclude='./usr/src' \
    --exclude='./var/cache' \
    --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" .

info "Stage4 tarball: ${STAGE4_TARBALL}"
info "Size: $(du -sh "${STAGE4_TARBALL}" | cut -f1)"

# ── 10b. Build a raw, flashable .img (DEFAULT artifact) ────────────
# Produces a partitioned disk image (FAT32 /boot + ext4 root) that boots a Pi 5
# directly — no installer step. Same naming as the ISO so the flasher/launchers
# autodetect it. growroot expands the (last) ext4 partition to fill the medium
# on first boot, so ROOT_MiB only needs to fit the stage4 plus headroom.
#
# Runs entirely as root (the build is already privileged): losetup, mkfs, mount
# and xattr-preserving extraction all require it. A cleanup trap tears down the
# mounts and the loop device on ANY failure or early return.
IMG_PATH="(not built)"
FS_TAR_PATH="(not built)"
build_img() {
    local img_size_mib loop boot_part root_part
    local root_mnt
    local p2_uuid p1_uuid
    loop=""; root_mnt=""

    IMG_PATH="${WORK_DIR}/${BRAND}-rpi5-arm64-${ROLE}-${ENV}-${BUILD_TS}.img"

    # 1MiB alignment gap + 512MiB FAT boot + ROOT_MiB ext4 root + 1MiB slack.
    img_size_mib=$(( 1 + 512 + ROOT_MiB + 1 ))

    # Teardown helper — registered on ERR/EXIT so a failure mid-build never leaks
    # a mounted filesystem or an orphaned loop device.
    _img_cleanup() {
        local rc=$?
        set +e
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}/boot" && umount "${root_mnt}/boot"
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}" && umount "${root_mnt}"
        [ -n "${loop}" ] && losetup "${loop}" &>/dev/null && losetup -d "${loop}"
        [ -n "${root_mnt}" ] && rmdir "${root_mnt}" 2>/dev/null
        return "${rc}"
    }
    trap '_img_cleanup' ERR EXIT

    info "Image size: ${img_size_mib} MiB (1 gap + 512 FAT + ${ROOT_MiB} ext4 + 1 slack)"
    rm -f "${IMG_PATH}"
    truncate -s "${img_size_mib}MiB" "${IMG_PATH}"

    # msdos table: p1 FAT32 boot (1..513MiB, boot flag), p2 ext4 root (513..100%).
    # p2 is LAST so growroot can expand it to the end of the medium on first boot.
    parted -s "${IMG_PATH}" mklabel msdos
    parted -s "${IMG_PATH}" mkpart primary fat32 1MiB 513MiB
    parted -s "${IMG_PATH}" set 1 boot on
    parted -s "${IMG_PATH}" mkpart primary ext4 513MiB 100%

    loop="$(losetup --show -fP "${IMG_PATH}")"
    boot_part="${loop}p1"
    root_part="${loop}p2"
    # Settle the partition device nodes that losetup -P just created.
    udevadm settle &>/dev/null || sleep 1

    info "Formatting ${boot_part} (FAT32 RPI_BOOT) and ${root_part} (ext4 RPI_ROOT)"
    mkfs.vfat -F 32 -n RPI_BOOT "${boot_part}"
    mkfs.ext4 -q -L RPI_ROOT -F "${root_part}"

    root_mnt="$(mktemp -d "${BUILD_ROOT}/img-root.XXXXXX")"
    mount "${root_part}" "${root_mnt}"

    # Extract the stage4 into the ext4 root. Mirror install.sh's xattr fallback:
    # try xattr-preserving extraction, fall back to a plain one if the FS/tar
    # can't carry the security.* attrs.
    info "Extracting stage4 into ${root_mnt}"
    tar -C "${root_mnt}" --xattrs-include='*.*' -xpf "${STAGE4_TARBALL}" 2>/dev/null || \
    tar -C "${root_mnt}" -xpf "${STAGE4_TARBALL}"

    # The /boot firmware lives on the FAT partition. Mount the FAT over the root's
    # /boot mountpoint and move the firmware there, so the ext4 /boot is just a
    # mountpoint (no duplicate firmware burning ext4 space).
    rm -rf "${root_mnt:?}/boot"
    mkdir -p "${root_mnt}/boot"
    mount "${boot_part}" "${root_mnt}/boot"

    # Populate /boot from the sysroot's boot tree (kernel_2712.img, config.txt,
    # cmdline.txt, bcm2712*.dtb, overlays/, firmware) — the same files the ISO
    # stages. ${SYSROOT}/boot is ALWAYS the authoritative, freshly-built source.
    # (The isoroot is staged AFTER this phase and is wiped at run start — a
    # leftover tree from a previous run once silently shipped a stale kernel.)
    local boot_src="${SYSROOT}/boot"
    info "Staging boot files from ${boot_src}"
    cp "${boot_src}/${RPI_KERNEL_IMG}"        "${root_mnt}/boot/"
    cp "${boot_src}/config.txt"               "${root_mnt}/boot/"
    cp "${boot_src}/cmdline.txt"              "${root_mnt}/boot/"
    cp "${boot_src}/"${RPI_DTB_PREFIX}*.dtb   "${root_mnt}/boot/" 2>/dev/null || true
    cp -r "${boot_src}/overlays"              "${root_mnt}/boot/" 2>/dev/null || true
    for fw in bootcode.bin fixup*.dat start*.elf; do
        cp "${SYSROOT}/boot/${fw}"            "${root_mnt}/boot/" 2>/dev/null || true
    done

    # The copies above are failure-tolerant (some files are board-optional),
    # but a boot partition without a device tree is UNBOOTABLE — the Pi
    # firmware needs a matching DTB to even start the kernel. Pi 3/4 boards
    # additionally need the GPU firmware (start*.elf/fixup*.dat); the Pi 5
    # boots from EEPROM. Assert the boot-mandatory payload landed instead of
    # shipping a brickable .img with exit 0.
    if ! ls "${root_mnt}/boot/"${RPI_DTB_PREFIX}*.dtb >/dev/null 2>&1; then
        err "no ${RPI_DTB_PREFIX}*.dtb on the .img boot partition — the image would be unbootable"
        err "(kernel-phase DTB install failed or the sysroot boot tree is incomplete)"
        exit 1
    fi
    if [ "${RPI_DTB_PREFIX}" != "bcm2712" ]; then
        if ! ls "${root_mnt}/boot/"start*.elf  >/dev/null 2>&1 || \
           ! ls "${root_mnt}/boot/"fixup*.dat >/dev/null 2>&1; then
            err "GPU firmware (start*.elf / fixup*.dat) missing from the .img boot partition —"
            err "${RPI_DTB_PREFIX} boards cannot boot without it (did sys-boot/raspberrypi-firmware merge?)"
            exit 1
        fi
    fi

    # Drop a per-device-editable growfs.conf on the FAT /boot so an operator can
    # retune the first-boot grow (fill|none|<size>) on a flashed card WITHOUT a
    # rebuild. growroot reads /boot/growfs.conf ahead of the baked /etc copy.
    write_growfs_conf "${root_mnt}/boot/growfs.conf"

    # ── Root identity ─────────────────────────────────────────────────
    # Default: address the root (and /boot) by PARTUUID/LABEL so the image boots
    # unchanged from SD, USB or NVMe. --sd-only bakes the fixed mmcblk0p2 path.
    if ${SD_ONLY}; then
        info "Root identity: /dev/mmcblk0p2 (--sd-only; device-path fstab)"
        # cmdline.txt already ships root=/dev/mmcblk0p2; fstab already mounts the
        # mmcblk0p1/p2 device paths — nothing to rewrite.
    else
        p2_uuid="$(blkid -s PARTUUID -o value "${root_part}")"
        p1_uuid="$(blkid -s PARTUUID -o value "${boot_part}")"
        info "Root identity: PARTUUID=${p2_uuid} (boot PARTUUID=${p1_uuid})"

        # Rewrite root= in the cmdline.txt that landed on the FAT partition,
        # preserving every other token on the line.
        sed -i -E \
            "s#root=[^ ]+#root=PARTUUID=${p2_uuid}#; s#rootfstype=[^ ]+#rootfstype=ext4#" \
            "${root_mnt}/boot/cmdline.txt"
        grep -q 'rootfstype=' "${root_mnt}/boot/cmdline.txt" || \
            sed -i -E "s#(root=PARTUUID=${p2_uuid})#\1 rootfstype=ext4#" "${root_mnt}/boot/cmdline.txt"
        grep -q 'rootwait'    "${root_mnt}/boot/cmdline.txt" || \
            sed -i -E "s#(root=PARTUUID=${p2_uuid})#\1 rootwait#" "${root_mnt}/boot/cmdline.txt"

        # Rewrite the ext4 root's /etc/fstab to mount /boot and / by identity.
        sed -i -E \
            -e "s#^/dev/mmcblk0p1#PARTUUID=${p1_uuid}#" \
            -e "s#^/dev/mmcblk0p2#PARTUUID=${p2_uuid}#" \
            "${root_mnt}/etc/fstab"
    fi

    # ── Filesystem tarball ────────────────────────────────────────────
    # Capture the FULLY-MOUNTED tree (ext4 root with the FAT /boot mounted in
    # place) as one tar, so it can be untarred onto pre-mounted partitions (mount
    # the boot/EFI partition at /boot first) to provision a disk without dd. tar
    # crosses the /boot mountpoint by default, so the firmware is captured at
    # /boot/*. This is the .img's exact final filesystem (PARTUUID fstab + cmdline
    # baked in) — the rootfs "as if mounted".
    if ${BUILD_TAR}; then
        local fs_tar="${WORK_DIR}/${BRAND}-rpi5-arm64-${ROLE}-${ENV}-${BUILD_TS}.fs.tar.xz"
        info "Filesystem tarball (mounted tree) -> ${fs_tar}"
        tar -C "${root_mnt}" --xattrs --xattrs-include='*.*' --numeric-owner -cpf - . 2>/dev/null \
            | xz -T0 -6 > "${fs_tar}" \
          || tar -C "${root_mnt}" --numeric-owner -cpf - . | xz -T0 -6 > "${fs_tar}"
        FS_TAR_PATH="${fs_tar}"
    fi

    sync
    umount "${root_mnt}/boot"
    umount "${root_mnt}"
    rmdir  "${root_mnt}"; root_mnt=""
    losetup -d "${loop}"; loop=""

    # Disarm the trap — the happy path tore everything down cleanly.
    trap - ERR EXIT

    if ${COMPRESS_IMG}; then
        info "Compressing image (xz -T0 -9)..."
        xz -T0 -9 -f "${IMG_PATH}"
        IMG_PATH="${IMG_PATH}.xz"
    fi

    info "Image created: ${IMG_PATH}"
    info "Size: $(du -sh "${IMG_PATH}" | cut -f1)"
}

if ${BUILD_IMG}; then
    banner "Phase 5: Building raw .img"
    # The .img is the DEFAULT artifact — the only directly bootable Pi
    # deliverable, and the .fs.tar.xz is produced inside build_img too. A
    # missing kernel means the build already failed (raspberrypi-sources
    # didn't merge or the kernel phase didn't run): fail LOUDLY instead of
    # printing the success banner over a deliverable-less run.
    if [ ! -f "${SYSROOT}/boot/${RPI_KERNEL_IMG}" ]; then
        err "Kernel ${RPI_KERNEL_IMG} not in sysroot — cannot build the .img (the default artifact)."
        err "Ensure sys-kernel/raspberrypi-sources installed and the kernel phase ran"
        err "(don't pass --skip-kernel). Pass --no-img for a stage4-tarball-only build."
        exit 1
    fi
    build_img
else
    banner "Phase 5: SKIPPED .img (--no-img)"
fi

if ${SKIP_ISO}; then
    banner "Phase 6: SKIPPED installer ISO (default; pass --iso to build it)"
    ISO_PATH="(not built)"
else
    banner "Phase 6: Building bootable installer ISO"

    # A bootable ISO needs the kernel. The ISO is opt-in (--iso), so if it was
    # requested and the kernel is absent (kernel build skipped or
    # raspberrypi-sources failed to install) the run cannot deliver what was
    # asked for — fail loudly rather than warn-and-skip.
    if [ ! -f "${SYSROOT}/boot/${RPI_KERNEL_IMG}" ]; then
        err "Kernel ${RPI_KERNEL_IMG} not in sysroot — cannot build the requested ISO."
        err "Ensure sys-kernel/raspberrypi-sources installed and the kernel phase ran"
        err "(don't pass --skip-kernel), or drop --iso for a tarball/.img-only build."
        exit 1
    else

    mkdir -p "${ISO_DIR}"/{boot,stage4,EFI/BOOT}

    # Boot files from sysroot
    cp "${SYSROOT}/boot/${RPI_KERNEL_IMG}" "${ISO_DIR}/boot/"
    cp "${SYSROOT}/boot/config.txt"        "${ISO_DIR}/boot/"
    cp "${SYSROOT}/boot/cmdline.txt"       "${ISO_DIR}/boot/"
    cp "${SYSROOT}/boot/"${RPI_DTB_PREFIX}*.dtb "${ISO_DIR}/boot/" 2>/dev/null || true
    cp -r "${SYSROOT}/boot/overlays"       "${ISO_DIR}/boot/" 2>/dev/null || true

    for fw in bootcode.bin fixup*.dat start*.elf; do
        cp "${SYSROOT}/boot/${fw}" "${ISO_DIR}/boot/" 2>/dev/null || true
    done

    # Same boot-mandatory assert as the .img: no DTB on the ISO boot tree means
    # the installed system can't boot, and the copies above are '|| true'.
    if ! ls "${ISO_DIR}/boot/"${RPI_DTB_PREFIX}*.dtb >/dev/null 2>&1; then
        err "no ${RPI_DTB_PREFIX}*.dtb in the ISO boot tree — the installed image would be unbootable"
        exit 1
    fi

    # Stage4 tarball — the staging dir must hold EXACTLY this run's tarball:
    # names embed BUILD_TS, and the bundled installer picks one with an
    # unsorted `find | head -1`. Belt-and-braces with the run-start isoroot
    # wipe (covers a future code path that repopulates within one run).
    rm -f "${ISO_DIR}/stage4/"*.tar.xz
    cp "${STAGE4_TARBALL}" "${ISO_DIR}/stage4/"

    # Installer script from spec file
    cp "${SPECS_DIR}/installer/install.sh" "${ISO_DIR}/install.sh"
    chmod +x "${ISO_DIR}/install.sh"

    ISO_PATH="${WORK_DIR}/${BRAND}-rpi5-arm64-${ROLE}-${ENV}-${BUILD_TS}.iso"
    VOLID="$(echo "GENTOO_RPI5_${ROLE}_K8S" | tr '[:lower:]' '[:upper:]' | cut -c1-32)"

    xorrisofs \
        -o "${ISO_PATH}" \
        -volid "${VOLID}" \
        -joliet -rock \
        "${ISO_DIR}"

    info "ISO created: ${ISO_PATH}"
    info "Size: $(du -sh "${ISO_PATH}" | cut -f1)"
    fi   # end kernel-present check
fi

echo ""
echo -e "${CYAN}${BOLD}=============================================="
echo "  RPi 5 Hardened + Kubernetes Stage4 Complete"
echo "==============================================${RESET}"
echo ""
echo "  Board:            Raspberry Pi 5 (${RPI_DTB_PREFIX} / ${RPI_CPU})"
echo "  Profile:          ${PROFILE_PATH}"
echo "  Kernel:           ${RPI_DEFCONFIG} + specs-rpi5/kernel/hardened-k8s.config"
echo "  Role:             ${ROLE}   (cluster domain: ${CLUSTER_DOMAIN})"
echo "  ENV:              ${ENV}   $([ "${ENV}" = test ] && echo '(LAN-first: cluster wildcard DNS; cloudflared/ACME pruned)' || echo '(PROD: public domain; Cloudflare/ACME; creds from keys USB)')"
echo "  Brand:            ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}${CONFIG_FILE:+   (profile: ${CONFIG_FILE})}"
echo "  Hostname:         ${HOSTNAME}"
echo "  Timezone:         ${TIMEZONE}"
echo "  Serial console:   ttyAMA10 (RP1 UART)"
echo "  PCIe Gen 3:       ${PCIE_GEN3}"
echo ""
echo "  Hardening:"
echo "    - PIE/SSP/FORTIFY_SOURCE compiler flags"
echo "    - SELinux LSM (kernel + userspace; per-pod MCS container isolation)"
echo "    - ASLR / KASLR / stack protector / slab hardening"
echo "    - Hardened sysctl (ptrace, dmesg, kptr restricted)"
echo "    - SSH: key-only, no root password login"
echo "    - /boot nosuid,nodev,noexec  /tmp tmpfs restricted"
echo "    - Audit subsystem enabled"
echo ""
echo "  Kubernetes:"
echo "    - containerd + runc (CRI runtime)"
echo "    - kubelet + kubeadm + kubectl"
echo "    - CNI plugins in /opt/cni/bin"
echo "    - Cgroup v2 + full netfilter/IPVS/eBPF stack"
echo "    - OverlayFS for container layers"
echo "    - Kubelet: anon-auth off, webhook auth, seccomp default"
echo ""
echo "  Mesh VPN + provisioning:"
echo "    - headscale ${HEADSCALE_VERSION} (control server) + tailscale ${TAILSCALE_VERSION}"
echo "    - First-boot provisioning from a USB FAT32 'KEYS' partition"
echo "      (users, ssh keys, passwords, certs, headscale/k8s config)"
echo "    - keys-provision engine: /usr/sbin/keys-provision"
echo ""
echo "  Artifacts:"
echo "    Work directory:  ${WORK_DIR}  (products land here)"
echo "    Build root:      ${BUILD_ROOT}  (per-arch sysroot/distfiles/pkgdir)"
echo "    Sysroot:         ${SYSROOT}"
echo "    Stage4 tarball:  ${STAGE4_TARBALL}"
echo "    Image (.img):    ${IMG_PATH}"
echo "    ISO:             ${ISO_PATH}"
echo "    Binary packages: ${BUILD_ROOT}/pkgdir"
echo "    Build log:       ${LOG_FILE}"
echo ""
echo "  Default credentials:"
echo "    root:${ROOT_PASS}   ${DEFAULT_USER}:${DEFAULT_USER_PASS}"
echo ""
echo "  Spec files used:"
echo "    ${SPECS_DIR}/   (aarch64/RPi5-specific)"
echo "    ${SHARED_SPECS}/   (arch-agnostic, shared with x86)"
echo ""
echo "  === Post-install ==="
echo "  1. Boot RPi 5, change all default passwords"
echo "  2. Add SSH pubkeys to ${DEFAULT_USER} and root"
echo "  3. kubeadm init --config /etc/kubernetes/kubeadm-config.yaml"
echo "  4. Install CNI (Flannel, Cilium, Calico, etc.)"
echo "  5. Join workers: kubeadm join <cp>:6443 --token <t> --discovery-token-ca-cert-hash <h>"
echo ""
