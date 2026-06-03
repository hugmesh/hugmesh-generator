#!/usr/bin/env bash
# build-x86-host-stage4.sh
# Build a hardened Gentoo amd64 stage4 + bootable ISO for the "snapdragon-host"
# node: a headless Kubernetes worker that joins the pki Pi control-plane and
# hosts ArgoCD + the snapdragon.games namespace + backend workloads, using a
# vendor-agnostic open GPU stack (Mesa/Vulkan) exposed to containers.
#
# NATIVE build — run on an amd64 Gentoo host (no crossdev). It chroots into the
# sysroot to emerge, so it needs root. Reuses the arch-agnostic specs/ (KEYS
# provisioning engine, OpenRC services, k8s config, GitOps payload) plus the
# amd64-specific specs-x86/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-x86"      # amd64-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"       # arch-agnostic specs (etc/, cluster/)

# ── Defaults ───────────────────────────────────────────────────────
WORK_DIR=""
JOBS="$(nproc)"
REL_VERSION="2026.0"
HOSTNAME=""
ROLE="host"
CLUSTER_DOMAIN="snapdragon.systems"
BRAND="snapdragon"
BRAND_TITLE="Snapdragon Systems"
ORG="Snapdragon-Systems"
CONFIG_FILE=""
TIMEZONE="UTC"
DEFAULT_USER="snap"
DEFAULT_USER_PASS="snapdragon"
ROOT_PASS="snapdragon"
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-hardened-openrc.txt"
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false
SKIP_KERNEL=false
SKIP_ISO=false
SKIP_CLEAN=false
RESUME=false
LIVE_ISO=true

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; BOLD=$'\033[1m'; RST=$'\033[0m'
banner(){ echo -e "\n${CYAN}${BOLD}==> $1${RST}"; }
info(){ echo -e "${GREEN}    $1${RST}"; }
warn(){ echo -e "${YEL}    WARNING: $1${RST}"; }
err(){ echo -e "${RED}    ERROR: $1${RST}" >&2; }

usage() {
cat <<EOF
build-x86-host-stage4.sh — hardened Gentoo amd64 k8s/GPU worker image.

  -w, --work-dir DIR        Build dir. Default: ./x86-host-build
  -j, --jobs N              Parallel jobs. Default: $(nproc)
  -v, --version STR         Version stamp. Default: ${REL_VERSION}
  -H, --hostname NAME       Hostname. Default: ${HOSTNAME}
  -T, --timezone ZONE       Timezone. Default: ${TIMEZONE}
      --cluster-domain D    Default: ${CLUSTER_DOMAIN}
  -u, --user NAME           Fallback user. Default: ${DEFAULT_USER}
      --user-password PASS  Default: ${DEFAULT_USER_PASS}
      --root-password PASS  Default: ${ROOT_PASS}
      --headscale-version V Default: ${HEADSCALE_VERSION}
      --tailscale-version V Default: ${TAILSCALE_VERSION}
      --seed-url URL        amd64 stage3 index URL.
      --skip-mesh           Don't install headscale/tailscale.
      --skip-tailscale      headscale only.
      --skip-kernel         Don't build the kernel.
      --skip-iso            Stage4 tarball only.
      --skip-clean          Keep docs/headers/symbols.
      --no-live-iso         Build a data+installer ISO (boot from a live USB)
                            instead of a self-booting live ISO.
      --resume              Reuse an existing sysroot.
  -h, --help                This help.

Run on an amd64 Gentoo host, as root. The produced ISO is bootable on a PC;
the bundled install-x86.sh writes the image to disk (UEFI + BIOS GRUB).
EOF
exit "${1:-0}"
}

# Drop-in brand profile (sourced before CLI; CLI overrides). Auto-detect ./brand.conf.
for ((_i = 1; _i <= $#; _i++)); do
    case "${!_i}" in -C|--config) _j=$((_i + 1)); CONFIG_FILE="${!_j}" ;; esac
done
if [ -z "${CONFIG_FILE}" ] && [ -f "$(pwd)/brand.conf" ]; then CONFIG_FILE="$(pwd)/brand.conf"; fi
if [ -n "${CONFIG_FILE}" ]; then
    [ -f "${CONFIG_FILE}" ] || { err "config file not found: ${CONFIG_FILE}"; exit 1; }
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"; info "Loaded brand profile: ${CONFIG_FILE}"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        -v|--version) REL_VERSION="$2"; shift 2 ;;
        -H|--hostname) HOSTNAME="$2"; shift 2 ;;
        -T|--timezone) TIMEZONE="$2"; shift 2 ;;
        -C|--config) CONFIG_FILE="$2"; shift 2 ;;
        --cluster-domain|--domain) CLUSTER_DOMAIN="$2"; shift 2 ;;
        --brand) BRAND="$2"; shift 2 ;;
        --brand-title) BRAND_TITLE="$2"; shift 2 ;;
        --org) ORG="$2"; shift 2 ;;
        -u|--user) DEFAULT_USER="$2"; shift 2 ;;
        --user-password) DEFAULT_USER_PASS="$2"; shift 2 ;;
        --root-password) ROOT_PASS="$2"; shift 2 ;;
        --headscale-version) HEADSCALE_VERSION="$2"; shift 2 ;;
        --tailscale-version) TAILSCALE_VERSION="$2"; shift 2 ;;
        --seed-url) SEED_STAGE3_URL="$2"; shift 2 ;;
        --skip-mesh) SKIP_MESH=true; shift ;;
        --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
        --skip-kernel) SKIP_KERNEL=true; shift ;;
        --skip-iso) SKIP_ISO=true; shift ;;
        --skip-clean) SKIP_CLEAN=true; shift ;;
        --no-live-iso) LIVE_ISO=false; shift ;;
        --resume) RESUME=true; shift ;;
        -h|--help) usage 0 ;;
        *) err "Unknown option: $1"; usage 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { err "Run as root (chroot emerge + ISO build need it)."; exit 1; }
[ -z "${WORK_DIR}" ] && WORK_DIR="$(pwd)/x86-host-build"
[ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-host"
SYSROOT="${WORK_DIR}/sysroot"
ISO_DIR="${WORK_DIR}/isoroot"
CHOST="x86_64-pc-linux-gnu"

render_template() {
    sed -e "s|@@CHOST@@|${CHOST}|g" -e "s|@@JOBS@@|${JOBS}|g" \
        -e "s|@@WORK_DIR@@|${WORK_DIR}|g" -e "s|@@HOSTNAME@@|${HOSTNAME}|g" \
        -e "s|@@TIMEZONE@@|${TIMEZONE}|g" -e "s|@@DEFAULT_USER@@|${DEFAULT_USER}|g" \
        -e "s|@@DEFAULT_USER_PASS@@|${DEFAULT_USER_PASS}|g" -e "s|@@ROOT_PASS@@|${ROOT_PASS}|g" \
        -e "s|@@BRAND@@|${BRAND}|g" -e "s|@@BRAND_TITLE@@|${BRAND_TITLE}|g" \
        -e "s|@@DOMAIN@@|${CLUSTER_DOMAIN}|g" -e "s|@@ORG@@|${ORG}|g" \
        "$1" > "$2"
}

# Rebrand the baked cluster tree (no-op for default snapdragon naming).
rebrand_sysroot() {
    if [ "${BRAND}" = "snapdragon" ] && [ "${CLUSTER_DOMAIN}" = "snapdragon.systems" ] \
       && [ "${ORG}" = "Snapdragon-Systems" ] && [ "${BRAND_TITLE}" = "Snapdragon Systems" ]; then
        info "Branding: default (snapdragon) — no rebrand"; return 0
    fi
    banner "Rebranding baked config -> brand=${BRAND} domain=${CLUSTER_DOMAIN} org=${ORG}"
    local org_lc; org_lc="$(echo "${ORG}" | tr '[:upper:]' '[:lower:]')"
    local f
    while IFS= read -r -d '' f; do
        sed -i \
            -e "s|Snapdragon Systems|${BRAND_TITLE}|g" \
            -e "s|snapdragon-systems/|${org_lc}/|g" \
            -e "s|Snapdragon-Systems|${ORG}|g" \
            -e "s|snapdragon\.systems|${CLUSTER_DOMAIN}|g" \
            -e "s|snapdragon-|${BRAND}-|g" \
            "${f}"
    done < <(find "${SYSROOT}/var/lib/snapdragon/cluster" "${SYSROOT}/etc/snapdragon" -type f -print0 2>/dev/null)
}

# ── 0. Prereqs ─────────────────────────────────────────────────────
banner "Verifying prerequisites"
[ -d "${SPECS_DIR}" ]   || { err "Missing ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Missing ${SHARED_SPECS}"; exit 1; }
for t in curl tar file; do command -v "$t" >/dev/null || { err "missing tool: $t"; exit 1; }; done
if ! ${SKIP_ISO}; then
    if ${LIVE_ISO}; then
        for t in grub-mkrescue mksquashfs xorriso; do
            command -v "$t" >/dev/null || { warn "missing ${t}; falling back to --no-live-iso"; LIVE_ISO=false; break; }
        done
    fi
    ${LIVE_ISO} || command -v xorriso >/dev/null || warn "no xorriso; data ISO will be a plain tree"
fi

# ── 1. Directories ─────────────────────────────────────────────────
banner "Preparing build directories"
mkdir -p "${WORK_DIR}"/{distfiles,pkgdir} "${SYSROOT}" "${ISO_DIR}"
info "Work dir: ${WORK_DIR}"

# ── 2. Seed stage3 ─────────────────────────────────────────────────
banner "Fetching amd64 hardened stage3 seed"
# The index is PGP-signed; select the stage3 tarball line, ignoring armor/comments.
STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
STAGE3_LOCAL="${WORK_DIR}/$(basename "${STAGE3_FILE}")"
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_FILE}"
[ -f "${STAGE3_LOCAL}" ] || { info "Downloading $(basename "${STAGE3_FILE}")"; curl -L -o "${STAGE3_LOCAL}" "${STAGE3_URL}"; }

# ── 3. Extract ─────────────────────────────────────────────────────
banner "Extracting stage3"
if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then
    info "Sysroot populated and --resume — skipping extraction"
else
    tar -C "${SYSROOT}" --xattrs-include='*.*' -xpf "${STAGE3_LOCAL}" 2>/dev/null || \
        tar -C "${SYSROOT}" -xpf "${STAGE3_LOCAL}"
fi

# ── 4. Install spec files ──────────────────────────────────────────
banner "Installing spec files"
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,profile,env}
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"
cp "${SPECS_DIR}/portage/profile/parent"              "${SYSROOT}/etc/portage/profile/parent"
# Copy every file in these portage config dirs (so added spec files always land).
cp "${SPECS_DIR}/portage/package.accept_keywords/"*   "${SYSROOT}/etc/portage/package.accept_keywords/"
cp "${SPECS_DIR}/portage/package.use/"*               "${SYSROOT}/etc/portage/package.use/"

# Shared (arch-agnostic) etc/ specs
mkdir -p "${SYSROOT}/etc/"{sysctl.d,modules-load.d,containerd,kubernetes,init.d,ssh/sshd_config.d,local.d,headscale,keys-provision} \
         "${SYSROOT}/var/lib/kubelet" "${SYSROOT}/usr/sbin"
cp "${SHARED_SPECS}/etc/sysctl.d/10-hardened.conf"    "${SYSROOT}/etc/sysctl.d/"
cp "${SHARED_SPECS}/etc/sysctl.d/99-kubernetes.conf"  "${SYSROOT}/etc/sysctl.d/"
cp "${SHARED_SPECS}/etc/modules-load.d/kubernetes.conf" "${SYSROOT}/etc/modules-load.d/"
cp "${SHARED_SPECS}/etc/containerd/config.toml"       "${SYSROOT}/etc/containerd/"
cp "${SHARED_SPECS}/etc/kubernetes/kubeadm-config.yaml" "${SYSROOT}/etc/kubernetes/"
cp "${SHARED_SPECS}/etc/kubernetes/kubelet-config.yaml" "${SYSROOT}/var/lib/kubelet/config.yaml"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/hardened.conf" "${SYSROOT}/etc/ssh/sshd_config.d/"
cp "${SHARED_SPECS}/etc/headscale/config.yaml"        "${SYSROOT}/etc/headscale/"
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh"  "${SYSROOT}/usr/sbin/keys-provision"; chmod +x "${SYSROOT}/usr/sbin/keys-provision"
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-backup"  "${SYSROOT}/usr/local/sbin/snapdragon-backup"; chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-backup"
for svc in containerd kubelet headscale tailscaled keys-provision; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"; chmod +x "${SYSROOT}/etc/init.d/${svc}"
done
render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"

# Cluster GitOps payload + role markers
mkdir -p "${SYSROOT}/etc/snapdragon" "${SYSROOT}/var/lib/snapdragon"
echo "${ROLE}"           > "${SYSROOT}/etc/snapdragon/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/snapdragon/cluster-domain"
cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/snapdragon/cluster"
rebrand_sysroot

# Identity, locale, CNI dirs
echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"; echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"
mkdir -p "${SYSROOT}/opt/cni/bin" "${SYSROOT}/etc/cni/net.d" "${SYSROOT}/var/lib/keys-provision"

# Runlevels (headless: no headscale here — that lives on the pki Pi)
mkdir -p "${SYSROOT}/etc/runlevels/default"
SVCS=(sshd NetworkManager cronie haveged keys-provision containerd kubelet auditd local)
${SKIP_MESH} || ${SKIP_TAILSCALE} || SVCS+=(tailscaled)
for s in "${SVCS[@]}"; do ln -sf "/etc/init.d/${s}" "${SYSROOT}/etc/runlevels/default/${s}" 2>/dev/null || true; done

# ── 5. Chroot setup + native emerge ────────────────────────────────
banner "Native emerge inside chroot"

# Guard: chrooting needs an amd64 sysroot. A common mistake is reusing the same
# --work-dir as the RPi (aarch64) cross-build — then --resume keeps the foreign
# sysroot and `chroot /bin/bash` dies with a confusing "No such file or directory".
if [ -e "${SYSROOT}/bin/bash" ] && ! file -L "${SYSROOT}/bin/bash" 2>/dev/null | grep -qE 'x86-64|x86_64'; then
    err "Sysroot ${SYSROOT} is NOT amd64 (looks like a foreign arch — e.g. the RPi aarch64 build)."
    err "Use a SEPARATE --work-dir for the x86 build (e.g. -w /var/tmp/snap-x86-build),"
    err "or remove the stale sysroot:  rm -rf '${SYSROOT}'  (then re-run without --resume)."
    exit 1
fi

cp -L /etc/resolv.conf "${SYSROOT}/etc/resolv.conf" 2>/dev/null || true
mount_chroot() {
    mount -t proc none "${SYSROOT}/proc"
    mount --rbind /sys  "${SYSROOT}/sys";  mount --make-rslave "${SYSROOT}/sys"
    mount --rbind /dev  "${SYSROOT}/dev";  mount --make-rslave "${SYSROOT}/dev"
    mount --rbind /run  "${SYSROOT}/run";  mount --make-rslave "${SYSROOT}/run"
    # Reuse the host's portage tree if present (much faster than webrsync)
    if [ -d /var/db/repos/gentoo ]; then
        mkdir -p "${SYSROOT}/var/db/repos/gentoo"
        mount --bind /var/db/repos/gentoo "${SYSROOT}/var/db/repos/gentoo"
        HOST_REPO_MOUNTED=true
    else
        HOST_REPO_MOUNTED=false
    fi
}
umount_chroot() {
    ${HOST_REPO_MOUNTED:-false} && umount -l "${SYSROOT}/var/db/repos/gentoo" 2>/dev/null || true
    for m in run dev sys proc; do umount -lR "${SYSROOT}/$m" 2>/dev/null || true; done
}
trap umount_chroot EXIT
mount_chroot

PKGS=$(grep -v '^\s*#' "${SPECS_DIR}/portage/packages.list" | grep -v '^\s*$' | tr '\n' ' ')

# A stage4 keeps the (already-built, hardened) seed toolchain — we do NOT want
# @world to drag in a brand-new gcc/glibc/binutils (e.g. a bleeding-edge
# gcc-16.x that may not even compile). Exclude the toolchain by default; opt in
# with REBUILD_TOOLCHAIN=true. --keep-going so one optional package can't abort
# the whole image.
REBUILD_TOOLCHAIN="${REBUILD_TOOLCHAIN:-false}"
if ${REBUILD_TOOLCHAIN}; then
    EMERGE_EXCLUDE=""
    info "Toolchain rebuild ENABLED (REBUILD_TOOLCHAIN=true)"
else
    EMERGE_EXCLUDE="--exclude sys-devel/gcc --exclude sys-libs/glibc --exclude sys-devel/binutils"
    info "Keeping seed toolchain (set REBUILD_TOOLCHAIN=true to rebuild gcc/glibc/binutils)"
fi

chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
export MAKEOPTS="-j${JOBS}"
if [ ! -d /var/db/repos/gentoo/metadata ] && ! mountpoint -q /var/db/repos/gentoo; then
    emerge-webrsync
fi
emerge --oneshot --update --newuse sys-apps/baselayout || true
# Apply our profile/USE across @world without churning the toolchain.
emerge --update --deep --newuse --keep-going ${EMERGE_EXCLUDE} @world \
    || echo "[build-x86] WARN: @world had package failures (--keep-going); continuing"
# Ensure the stage4 package set is present (deps included).
emerge --update --deep --newuse --keep-going ${EMERGE_EXCLUDE} ${PKGS} \
    || echo "[build-x86] WARN: some stage4 packages failed; review the emerge output"
CHROOT

# ── 6. Mesh VPN (amd64 static binaries) ────────────────────────────
if ${SKIP_MESH}; then
    banner "Mesh VPN SKIPPED"
else
    banner "Installing mesh VPN (headscale + tailscale, amd64)"
    if curl -fL -o "${SYSROOT}/usr/bin/headscale" \
        "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"; then
        chmod +x "${SYSROOT}/usr/bin/headscale"; info "headscale installed"
    else warn "headscale fetch failed"; fi
    if ! ${SKIP_TAILSCALE}; then
        TGZ="${WORK_DIR}/tailscale_${TAILSCALE_VERSION}_amd64.tgz"
        if curl -fL -o "${TGZ}" "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz"; then
            TMP="$(mktemp -d)"; tar -C "${TMP}" -xzf "${TGZ}"
            SUB="$(find "${TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
            install -Dm0755 "${SUB}/tailscale" "${SYSROOT}/usr/bin/tailscale"
            install -Dm0755 "${SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
            rm -rf "${TMP}"; info "tailscale installed"
        else warn "tailscale fetch failed"; fi
    fi
fi

# ── 7. Kernel (hardened gentoo-sources + GPU/k8s fragment) ─────────
if ${SKIP_KERNEL}; then
    banner "Kernel SKIPPED"
else
    banner "Building hardened kernel (gentoo-sources + GPU/k8s fragment)"
    cp "${SPECS_DIR}/kernel/hardened-k8s-gpu.config" "${SYSROOT}/tmp/k.config"
    chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
cd /usr/src/linux
make defconfig
while IFS= read -r line; do
    [[ "\${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "\${line// }" ]] && continue
    read -r action rest <<< "\${line}"
    scripts/config "--\${action}" \${rest}
done < /tmp/k.config
make olddefconfig
make -j${JOBS} bzImage modules
make modules_install
make install
CHROOT
    rm -f "${SYSROOT}/tmp/k.config"
    info "Kernel built and installed to ${SYSROOT}/boot"
fi

# ── 8. Clean ───────────────────────────────────────────────────────
umount_chroot; trap - EXIT
if ! ${SKIP_CLEAN}; then
    banner "Cleaning sysroot"
    rm -rf "${SYSROOT}"/usr/share/{doc,man,info}/* "${SYSROOT}"/var/cache/distfiles/* \
           "${SYSROOT}"/var/tmp/* "${SYSROOT}"/tmp/* 2>/dev/null || true
fi

# ── 9. Stage4 tarball ──────────────────────────────────────────────
banner "Packaging stage4 tarball"
STAGE4="${WORK_DIR}/stage4-amd64-snapdragon-host-${REL_VERSION}.tar.xz"
tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' -cJf "${STAGE4}" . 2>/dev/null || \
tar -C "${SYSROOT}" --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' -cJf "${STAGE4}" .
info "Stage4: ${STAGE4} ($(du -sh "${STAGE4}" | cut -f1))"

# ── 10. ISO ────────────────────────────────────────────────────────
ISO_PATH="(not built)"
if ! ${SKIP_ISO}; then
    KVER="$(ls "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1)"
    VMLINUZ="$(ls -1 "${SYSROOT}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1 || true)"
    ISO_PATH="${WORK_DIR}/gentoo-x86-snapdragon-host-${REL_VERSION}.iso"

    if ${LIVE_ISO} && [ -n "${VMLINUZ}" ] && [ -n "${KVER}" ]; then
        banner "Building bootable LIVE ISO (grub-mkrescue + squashfs)"
        # Live initramfs (dmsquash-live) built inside the chroot.
        mount_chroot; trap umount_chroot EXIT
        chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT || warn "dracut step failed"
command -v dracut >/dev/null && dracut --force --no-hostonly \
    --add "dmsquash-live" \
    --add-drivers "squashfs iso9660 loop sr_mod usb_storage ahci nvme" \
    --kver "${KVER}" /boot/initramfs-live.img || echo "dracut not installed"
CHROOT
        umount_chroot; trap - EXIT

        mkdir -p "${ISO_DIR}/boot/grub" "${ISO_DIR}/LiveOS"
        cp "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
        [ -f "${SYSROOT}/boot/initramfs-live.img" ] && cp "${SYSROOT}/boot/initramfs-live.img" "${ISO_DIR}/boot/initramfs.img"
        info "Squashing rootfs (this can take a while)..."
        mksquashfs "${SYSROOT}" "${ISO_DIR}/LiveOS/squashfs.img" \
            -comp zstd -e proc sys dev run var/cache/distfiles >/dev/null
        cat > "${ISO_DIR}/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0
menuentry "Snapdragon Host (live/install)" {
    linux /boot/vmlinuz root=live:CDLABEL=SNAPDRAGON_HOST rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img console=tty0
    initrd /boot/initramfs.img
}
EOF
        grub-mkrescue -o "${ISO_PATH}" "${ISO_DIR}" -volid SNAPDRAGON_HOST 2>/dev/null \
            && info "Bootable live ISO: ${ISO_PATH}" \
            || { warn "grub-mkrescue failed; falling back to data ISO"; LIVE_ISO=false; }
    fi

    if ! ${LIVE_ISO}; then
        banner "Building data + installer ISO (boot from a Gentoo live USB to install)"
        mkdir -p "${ISO_DIR}/stage4"
        cp "${STAGE4}" "${ISO_DIR}/stage4/"
        cp "${SPECS_DIR}/installer/install-x86.sh" "${ISO_DIR}/install-x86.sh"; chmod +x "${ISO_DIR}/install-x86.sh"
        if command -v xorriso >/dev/null; then
            xorriso -as mkisofs -o "${ISO_PATH}" -volid SNAPDRAGON_HOST -joliet -rock "${ISO_DIR}"
            info "Data ISO: ${ISO_PATH}"
        else
            ISO_PATH="${ISO_DIR}  (tree; no xorriso to wrap an ISO)"
            warn "xorriso missing — left an installable tree at ${ISO_DIR}"
        fi
    fi
fi

# ── 11. Summary ────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}=== Snapdragon x86_64 Host (hardened k8s/GPU worker) ===${RST}"
echo "  Profile:    $(cat "${SYSROOT}/etc/portage/profile/parent")"
echo "  Role:       ${ROLE}   (cluster domain: ${CLUSTER_DOMAIN})"
echo "  Brand:      ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}${CONFIG_FILE:+   (profile: ${CONFIG_FILE})}"
echo "  GPU:        vendor-agnostic Mesa/Vulkan (amdgpu/i915/nouveau)"
echo "  Joins:      pki Pi control-plane (via USB KEYS, kubernetes.role=worker)"
echo "  Hosts:      ArgoCD + snapdragon-games + backend (node label compute=gpu)"
echo "  Stage4:     ${STAGE4}"
echo "  ISO:        ${ISO_PATH}"
echo ""
echo "  Provision a KEYS stick for this node with:"
echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-host   # then edit:"
echo "    snapdragon.role=games, node_labels { snapdragon.systems/compute: gpu }"
