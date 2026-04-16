#!/usr/bin/env bash
# build-rpi5-stage4.sh
# Build a hardened Gentoo aarch64 (RPi 5) stage4 ISO with Kubernetes
# using crossdev toolchain on x86_64
#
# No root/sudo required for the build itself.
# The bundled install.sh (inside the ISO) requires root on the target.
set -euo pipefail

# ── Resolve SCRIPT_DIR (where specs/ lives) ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs"

# ── Defaults ───────────────────────────────────────────────────────
WORK_DIR=""
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
EXTRA_PACKAGES=""
TIMEZONE="UTC"
HOSTNAME="gentoo-rpi5"
DEFAULT_USER="pi"
DEFAULT_USER_PASS="raspberry"
ROOT_PASS="gentoo"
PCIE_GEN3=false
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt"

# ── Colors ─────────────────────────────────────────────────────────
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

# ── Usage / man page ──────────────────────────────────────────────
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
    with a hardened kernel, AppArmor, auditing, and a full Kubernetes
    stack (containerd, kubelet, kubeadm, kubectl, CNI plugins).

    No root or sudo is required for the build.  All intermediate and
    output files are written under the work directory.  The bundled
    install.sh inside the ISO does require root on the machine that
    writes the image to an SD card or NVMe drive.

    All configuration is stored in individual spec files under the
    specs/ directory next to this script.  Edit them before building
    to customise the image without touching the build script itself.

    specs/
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
    │   ├── fstab                       Filesystem table
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
    │   │   └── kubelet                 OpenRC init script
    │   ├── ssh/sshd_config.d/
    │   │   └── hardened.conf           Hardened SSH config
    │   └── local.d/
    │       └── 01-firstboot.start.tmpl First-boot script (templated)
    ├── kernel/
    │   └── hardened-k8s.config         Kernel config fragment
    └── installer/
        └── install.sh                  SD/NVMe installer (ships in ISO)

OPTIONS
  Directories
    -w, --work-dir DIR
        Base directory for all build artifacts (sysroot, tarballs,
        ISO, caches).  Default: ./rpi5-stage4-build (created under
        the current working directory).

    -s, --specs-dir DIR
        Path to the specs/ directory.  Default: specs/ next to
        this script.  Use this to point at a customised copy.

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
        to specs/portage/packages.list at build time.

  Phases
    --skip-kernel
        Skip kernel compilation.  Useful when iterating on userspace
        packages only.

    --skip-iso
        Skip ISO generation.  Only produce the stage4 tarball.

    --skip-clean
        Do not strip binaries or remove docs/headers from the
        sysroot.  Useful for development images.

    --resume
        Resume a previous build.  Skips seed tarball extraction if
        the sysroot is already populated and passes --update to
        cross-emerge.

  General
    -h, --help
        Show this help and exit.

EXAMPLES
    # Minimal invocation — build everything with defaults
    ./build-rpi5-stage4.sh

    # Specify a work directory on a fast NVMe scratch disk
    ./build-rpi5-stage4.sh -w /mnt/nvme/rpi-build

    # Use a customised specs directory
    ./build-rpi5-stage4.sh -s ~/my-rpi5-specs

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
        -s ./specs \
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
    <work-dir>/
        sysroot/            Cross-compiled root filesystem
        distfiles/          Portage source archives
        pkgdir/             Binary packages
        isoroot/            ISO staging area
        stage4-*.tar.xz     Final stage4 tarball
        gentoo-*.iso        Bootable ISO with installer
        build.log           Full build log

NOTES
    The cross-toolchain (crossdev) must already be installed and
    built for the target triplet before running this script.

    All host tools (xorrisofs, curl, tar, file, etc.) must be
    present in PATH.

    All configuration lives in the specs/ directory.  Copy it,
    edit the files you need, and pass --specs-dir to use your
    version.  Files ending in .tmpl contain @@VARIABLE@@ markers
    that are replaced at build time.  Plain files are copied as-is.

    The bundled install.sh inside the ISO requires root privileges
    to partition, format, and mount block devices.

SEE ALSO
    crossdev(1), emerge(1), catalyst(1), kubeadm(1)

MANEOF
exit 0
}

# ── Option parsing ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir)        WORK_DIR="$2";           shift 2 ;;
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
        -T|--timezone)        TIMEZONE="$2";           shift 2 ;;
        -u|--user)            DEFAULT_USER="$2";       shift 2 ;;
        --user-password)      DEFAULT_USER_PASS="$2";  shift 2 ;;
        --root-password)      ROOT_PASS="$2";          shift 2 ;;
        -p|--extra-packages)  EXTRA_PACKAGES="$2";     shift 2 ;;
        --skip-kernel)        SKIP_KERNEL=true;        shift   ;;
        --skip-iso)           SKIP_ISO=true;           shift   ;;
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

# Default work directory: ./rpi5-stage4-build under CWD
if [ -z "${WORK_DIR}" ]; then
    WORK_DIR="$(pwd)/rpi5-stage4-build"
fi

# Derived paths
SYSROOT="${WORK_DIR}/sysroot"
ISO_DIR="${WORK_DIR}/isoroot"
LOG_FILE="${WORK_DIR}/build.log"

# ── Template helper ────────────────────────────────────────────────
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
        -e "s|@@WORK_DIR@@|${WORK_DIR}|g" \
        -e "s|@@RPI_KERNEL_IMG@@|${RPI_KERNEL_IMG}|g" \
        -e "s|@@PCIE_LINE@@|${PCIE_LINE}|g" \
        -e "s|@@HOSTNAME@@|${HOSTNAME}|g" \
        -e "s|@@TIMEZONE@@|${TIMEZONE}|g" \
        -e "s|@@DEFAULT_USER@@|${DEFAULT_USER}|g" \
        -e "s|@@DEFAULT_USER_PASS@@|${DEFAULT_USER_PASS}|g" \
        -e "s|@@ROOT_PASS@@|${ROOT_PASS}|g" \
        "${src}" > "${dst}"
}

# ── 0. Verify prerequisites ───────────────────────────────────────
banner "Verifying prerequisites"

# Check specs directory
if [ ! -d "${SPECS_DIR}" ]; then
    err "Specs directory not found: ${SPECS_DIR}"
    err "Expected to find it next to this script, or pass --specs-dir."
    exit 1
fi
info "Specs directory: ${SPECS_DIR}"

# Check toolchain
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    if ! command -v "${tool}" &>/dev/null; then
        err "${tool} not found in PATH."
        exit 1
    fi
done

if ! ${SKIP_ISO} && ! command -v xorrisofs &>/dev/null; then
    err "xorrisofs not found in PATH (needed for ISO generation)."
    err "Pass --skip-iso to skip, or install dev-libs/libisoburn."
    exit 1
fi

info "Cross-compiler: $(${CROSS_TARGET}-gcc --version | head -1)"
info "Jobs: ${JOBS}"

# ── 1. Directory layout ───────────────────────────────────────────
banner "Preparing build directories"

mkdir -p "${WORK_DIR}"/{distfiles,pkgdir,log}
mkdir -p "${SYSROOT}"
mkdir -p "${ISO_DIR}"

info "Work directory: ${WORK_DIR}"
info "Sysroot:        ${SYSROOT}"

# Start build log
exec > >(tee -a "${LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE}"

# ── 2. Fetch seed stage3 ──────────────────────────────────────────
banner "Fetching latest arm64 stage3 seed tarball"

STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | grep -v '^#' | head -1 | awk '{print $1}')
STAGE3_BASENAME=$(basename "${STAGE3_FILE}")
STAGE3_FULL_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/${STAGE3_FILE}"
STAGE3_LOCAL="${WORK_DIR}/${STAGE3_BASENAME}"

if [ ! -f "${STAGE3_LOCAL}" ]; then
    info "Downloading ${STAGE3_BASENAME}..."
    curl -L -o "${STAGE3_LOCAL}" "${STAGE3_FULL_URL}"
else
    info "Using cached ${STAGE3_BASENAME}"
fi

# ── 3. Extract seed stage3 into sysroot ────────────────────────────
banner "Extracting seed stage3 into sysroot"

if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then
    info "Sysroot already populated and --resume set, skipping extraction"
else
    tar -C "${SYSROOT}" \
        --xattrs-include='*.*' \
        -xpf "${STAGE3_LOCAL}" 2>/dev/null || \
    tar -C "${SYSROOT}" -xpf "${STAGE3_LOCAL}"
    info "Extracted into ${SYSROOT}"
fi

# ── 4. Install spec files into sysroot portage ─────────────────────
banner "Installing spec files into sysroot (hardened profile)"

# Compute PCIE_LINE for templates
if ${PCIE_GEN3}; then
    PCIE_LINE="dtparam=pciex1_gen=3"
else
    PCIE_LINE="# dtparam=pciex1_gen=3"
fi

# Portage directories
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,package.mask,profile,env,package.env,repos.conf}

# Plain-copy portage specs
cp "${SPECS_DIR}/portage/profile/parent"                  "${SYSROOT}/etc/portage/profile/parent"
cp "${SPECS_DIR}/portage/profile/use.mask"                "${SYSROOT}/etc/portage/profile/use.mask"
cp "${SPECS_DIR}/portage/package.accept_keywords/rpi"     "${SYSROOT}/etc/portage/package.accept_keywords/rpi"
cp "${SPECS_DIR}/portage/package.accept_keywords/kubernetes" "${SYSROOT}/etc/portage/package.accept_keywords/kubernetes"
cp "${SPECS_DIR}/portage/package.use/rpi5"                "${SYSROOT}/etc/portage/package.use/rpi5"
cp "${SPECS_DIR}/portage/package.use/kubernetes"          "${SYSROOT}/etc/portage/package.use/kubernetes"
cp "${SPECS_DIR}/portage/package.env/kubernetes"          "${SYSROOT}/etc/portage/package.env/kubernetes"

# Templated portage specs
render_template "${SPECS_DIR}/portage/make.conf.tmpl"     "${SYSROOT}/etc/portage/make.conf"
render_template "${SPECS_DIR}/portage/env/cross-go.conf.tmpl" "${SYSROOT}/etc/portage/env/cross-go.conf"

# Boot files
mkdir -p "${SYSROOT}/boot"
render_template "${SPECS_DIR}/boot/config.txt.tmpl"       "${SYSROOT}/boot/config.txt"
cp "${SPECS_DIR}/boot/cmdline.txt"                        "${SYSROOT}/boot/cmdline.txt"

# /etc config files
cp "${SPECS_DIR}/etc/fstab"                               "${SYSROOT}/etc/fstab"

mkdir -p "${SYSROOT}/etc/modules-load.d"
cp "${SPECS_DIR}/etc/modules-load.d/kubernetes.conf"      "${SYSROOT}/etc/modules-load.d/kubernetes.conf"

mkdir -p "${SYSROOT}/etc/sysctl.d"
cp "${SPECS_DIR}/etc/sysctl.d/10-hardened.conf"           "${SYSROOT}/etc/sysctl.d/10-hardened.conf"
cp "${SPECS_DIR}/etc/sysctl.d/99-kubernetes.conf"         "${SYSROOT}/etc/sysctl.d/99-kubernetes.conf"

mkdir -p "${SYSROOT}/etc/containerd"
cp "${SPECS_DIR}/etc/containerd/config.toml"              "${SYSROOT}/etc/containerd/config.toml"

mkdir -p "${SYSROOT}/var/lib/kubelet"
cp "${SPECS_DIR}/etc/kubernetes/kubelet-config.yaml"      "${SYSROOT}/var/lib/kubelet/config.yaml"

mkdir -p "${SYSROOT}/etc/kubernetes"
cp "${SPECS_DIR}/etc/kubernetes/kubeadm-config.yaml"      "${SYSROOT}/etc/kubernetes/kubeadm-config.yaml"

mkdir -p "${SYSROOT}/etc/init.d"
cp "${SPECS_DIR}/etc/init.d/containerd"                   "${SYSROOT}/etc/init.d/containerd"
cp "${SPECS_DIR}/etc/init.d/kubelet"                      "${SYSROOT}/etc/init.d/kubelet"
chmod +x "${SYSROOT}/etc/init.d/containerd" "${SYSROOT}/etc/init.d/kubelet"

mkdir -p "${SYSROOT}/etc/ssh/sshd_config.d"
cp "${SPECS_DIR}/etc/ssh/sshd_config.d/hardened.conf"     "${SYSROOT}/etc/ssh/sshd_config.d/hardened.conf"

mkdir -p "${SYSROOT}/etc/local.d"
render_template "${SPECS_DIR}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
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
for svc in sshd NetworkManager cronie haveged containerd kubelet auditd apparmor local; do
    ln -sf "/etc/init.d/${svc}" "${SYSROOT}/etc/runlevels/default/${svc}" 2>/dev/null || true
done

info "Profile: $(cat "${SYSROOT}/etc/portage/profile/parent")"

# ── 5. Cross-emerge helper ────────────────────────────────────────
cross_emerge() {
    ROOT="${SYSROOT}" \
    SYSROOT="${SYSROOT}" \
    PORTAGE_CONFIGROOT="${SYSROOT}" \
    "${CROSS_TARGET}-emerge" \
        --jobs="${JOBS}" \
        --load-average="${JOBS}" \
        --with-bdeps=n \
        "$@"
}

# ── 6. Build @system ──────────────────────────────────────────────
banner "Phase 1: Cross-building @system (hardened)"

cross_emerge --oneshot --update sys-apps/baselayout
cross_emerge --update --deep --newuse @system

# ── 7. Build stage4 packages ──────────────────────────────────────
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
cross_emerge --update "${STAGE4_PACKAGES[@]}"

# ── 8. Cross-compile the kernel ───────────────────────────────────
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
            scripts/config "--${action}" ${rest}
        done < "${SPECS_DIR}/kernel/hardened-k8s.config"

        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" olddefconfig

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

# ── 9. Clean sysroot ──────────────────────────────────────────────
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

# ── 10. Package stage4 tarball ─────────────────────────────────────
banner "Phase 4: Packaging stage4 tarball"

STAGE4_TARBALL="${WORK_DIR}/stage4-${CROSS_TARGET}-rpi5-hardened-k8s-${REL_VERSION}.tar.xz"

tar -C "${SYSROOT}" \
    --xattrs-include='*.*' \
    --numeric-owner \
    --exclude='./usr/src' \
    --exclude='./var/cache' \
    --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" . 2>/dev/null || \
tar -C "${SYSROOT}" \
    --numeric-owner \
    --exclude='./usr/src' \
    --exclude='./var/cache' \
    --exclude='./tmp/*' \
    -cJf "${STAGE4_TARBALL}" .

info "Stage4 tarball: ${STAGE4_TARBALL}"
info "Size: $(du -sh "${STAGE4_TARBALL}" | cut -f1)"

# ── 11. Build bootable ISO ─────────────────────────────────────────
if ${SKIP_ISO}; then
    banner "Phase 5: SKIPPED (--skip-iso)"
    ISO_PATH="(not built)"
else
    banner "Phase 5: Building bootable ISO"

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

    # Stage4 tarball
    cp "${STAGE4_TARBALL}" "${ISO_DIR}/stage4/"

    # Installer script from spec file
    cp "${SPECS_DIR}/installer/install.sh" "${ISO_DIR}/install.sh"
    chmod +x "${ISO_DIR}/install.sh"

    ISO_PATH="${WORK_DIR}/gentoo-rpi5-arm64-hardened-k8s-${REL_VERSION}.iso"

    xorrisofs \
        -o "${ISO_PATH}" \
        -volid "GENTOO_RPI5_K8S" \
        -joliet -rock \
        "${ISO_DIR}"

    info "ISO created: ${ISO_PATH}"
    info "Size: $(du -sh "${ISO_PATH}" | cut -f1)"
fi

# ── 12. Summary ────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}=============================================="
echo "  RPi 5 Hardened + Kubernetes Stage4 Complete"
echo "==============================================${RESET}"
echo ""
echo "  Board:            Raspberry Pi 5 (${RPI_DTB_PREFIX} / ${RPI_CPU})"
echo "  Profile:          $(cat "${SYSROOT}/etc/portage/profile/parent")"
echo "  Kernel:           ${RPI_DEFCONFIG} + specs/kernel/hardened-k8s.config"
echo "  Hostname:         ${HOSTNAME}"
echo "  Timezone:         ${TIMEZONE}"
echo "  Serial console:   ttyAMA10 (RP1 UART)"
echo "  PCIe Gen 3:       ${PCIE_GEN3}"
echo ""
echo "  Hardening:"
echo "    - PIE/SSP/FORTIFY_SOURCE compiler flags"
echo "    - AppArmor LSM (kernel + userspace)"
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
echo "  Artifacts:"
echo "    Work directory:  ${WORK_DIR}"
echo "    Sysroot:         ${SYSROOT}"
echo "    Stage4 tarball:  ${STAGE4_TARBALL}"
echo "    ISO:             ${ISO_PATH}"
echo "    Binary packages: ${WORK_DIR}/pkgdir"
echo "    Build log:       ${LOG_FILE}"
echo ""
echo "  Default credentials:"
echo "    root:${ROOT_PASS}   ${DEFAULT_USER}:${DEFAULT_USER_PASS}"
echo ""
echo "  Spec files used:"
echo "    ${SPECS_DIR}/"
echo ""
echo "  === Post-install ==="
echo "  1. Boot RPi 5, change all default passwords"
echo "  2. Add SSH pubkeys to ${DEFAULT_USER} and root"
echo "  3. kubeadm init --config /etc/kubernetes/kubeadm-config.yaml"
echo "  4. Install CNI (Flannel, Cilium, Calico, etc.)"
echo "  5. Join workers: kubeadm join <cp>:6443 --token <t> --discovery-token-ca-cert-hash <h>"
echo ""
