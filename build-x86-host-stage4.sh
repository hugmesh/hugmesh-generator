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
# Per-arch build subdirectory under WORK_DIR. The heavy, ARCH-SPECIFIC build
# tree (sysroot, ISO staging, distfiles, pkgdir, seed/binary downloads) lives
# under WORK_DIR/${BUILD_SUBDIR} so the amd64 (x86) and aarch64 (Pi) builds NEVER
# share a sysroot when they run against the same WORK_DIR (e.g. build-all-roles).
# Override with --build-subdir NAME or BUILD_SUBDIR=NAME in the env. The finished
# PRODUCTS (.img/.iso/.fs.tar.xz/stage4/keys-*) still land in WORK_DIR itself.
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-x86}"
JOBS="$(nproc)"
REL_VERSION="2026.0"
HOSTNAME=""
ROLE="be+gpu"          # default role (= the legacy 'host'); 'host' is accepted as an alias
GPU=true               # derived from ROLE below; gates Mesa/Vulkan + DRM kernel + VIDEO_CARDS
CLUSTER_DOMAIN="snapdragon.systems"
BRAND="snapdragon"
BRAND_TITLE="Snapdragon Systems"
ORG="Snapdragon-Systems"
# Games portal domain. DEFAULT serves games as a SUBDOMAIN of the primary domain
# (games.<CLUSTER_DOMAIN>) until the real .games TLD is obtained; flip to the TLD
# later with GAMES_DOMAIN=<brand>.games. The default literal "games.snapdragon.systems"
# composes with rebrand_sysroot (its snapdragon.systems->CLUSTER_DOMAIN rule turns
# it into games.<CLUSTER_DOMAIN>); a custom value is rebrand-neutral. Drives the
# games host + OIDC issuer/redirects via parameterize_games_domain(). See
# docs/OPTIONAL-SERVICES.md.
GAMES_DOMAIN="games.snapdragon.systems"
# OPTIONAL services selected on this image (space-separated subset of:
# akkoma tuwunel phpbb games). Built-in default = ALL on. brand.conf may narrow
# it; the --optional-services flag overrides both (built-in < brand.conf < flag).
# Each unselected slug is pruned from the baked GitOps tree by
# gate_optional_services(). See specs/cluster/optional-services.yaml.
OPTIONAL_SERVICES="akkoma tuwunel phpbb games"
# ── Build ENV selector (BAKED into the image) ──────────────────────
# test (DEFAULT, local-first/safe): LAN-only — cluster wildcard DNS ON, the
#   go-live cloudflared/external-dns/ACME app is PRUNED from the baked apps/,
#   OAuth/SMTP/Cloudflare optional/absent. Internal cluster-CA TLS only.
# prod: bakes the REAL public domain — public DNS / Cloudflare, ACME ALLOWED on
#   top of the internal CA, OAuth/SMTP/Cloudflare expected from the keys USB. The
#   build prints a LOUD announced banner because it bakes the real domain.
# The chosen ENV is written to /etc/snapdragon/env and gates which ArgoCD apps
# survive in the baked /var/lib/snapdragon/cluster/apps tree (gate_env_apps).
ENV="test"
# Pinned first-party release tag for ENV=prod. The prod tag-rewrite in
# gate_env_apps replaces every floating `:dev` first-party image tag with this so
# the prod-hygiene gate (scripts/validate-prod-hygiene.sh) finds no floating tag.
# Default = a deterministic build stamp; override with --release-tag.
RELEASE_TAG="${RELEASE_TAG:-$(date -u +%Y%m%d)}"
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
SKIP_CLEAN=false
RESUME=false
# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ───
# WiFi + Bluetooth are OFF by default to shrink the attack surface: at first boot
# rfkill blocks both radios, their kernel modules are blacklisted, and no wifi/
# bluetooth service is enabled. ETHERNET + the Tailscale tailnet are UNAFFECTED
# (NetworkManager still manages wired; tailscaled still runs). Re-enable per build
# with ENABLE_WIFI=true / ENABLE_BLUETOOTH=true (env/brand.conf) or the
# --enable-wifi / --enable-bluetooth flags. Precedence: built-in (false) <
# brand.conf < CLI flag.
ENABLE_WIFI="${ENABLE_WIFI:-false}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-false}"
# ── Artifact selection (mirrors rpi5): .img is now the DEFAULT deliverable ──
BUILD_IMG=true          # produce the flashable raw .img (DEFAULT)
ROOT_MiB=8192           # ext4 root partition size in the .img (growroot expands it on first boot)
GROW_POLICY="fill"      # first-boot grow policy baked into /etc/growfs.conf: fill|none|<size>
COMPRESS_IMG=false      # xz -9 the finished .img
LIVE_ISO=true           # self-booting live squashfs ISO (DEFAULT; --no-live-iso to skip)
INSTALLER_ISO=false     # stage4 + install-x86.sh data ISO (opt-in: --installer-iso)
BUILD_TAR=true          # also emit the mounted-filesystem tarball (.fs.tar.xz)

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; BOLD=$'\033[1m'; RST=$'\033[0m'
banner(){ echo -e "\n${CYAN}${BOLD}==> $1${RST}"; }
info(){ echo -e "${GREEN}    $1${RST}"; }
warn(){ echo -e "${YEL}    WARNING: $1${RST}"; }
err(){ echo -e "${RED}    ERROR: $1${RST}" >&2; }

usage() {
cat <<EOF
build-x86-host-stage4.sh — hardened Gentoo amd64 k8s/GPU worker image.

  -w, --work-dir DIR        Products dir (.img/.iso/.fs.tar.xz/stage4/keys-*).
                            Default: ./out  (local + gitignored)
  --build-subdir NAME       Per-arch subdir under --work-dir for the heavy build
                            tree (sysroot/distfiles/pkgdir/ISO staging). Default:
                            snap-build-x86 (or BUILD_SUBDIR=NAME). Keeps the amd64
                            build from sharing a sysroot with the Pi (aarch64)
                            build under a shared --work-dir (build-all-roles.sh).
  -j, --jobs N              Parallel jobs. Default: $(nproc)
  -v, --version STR         Version stamp. Default: ${REL_VERSION}
  -r, --role ROLE           pki | be | fe | be+gpu | omnibus  (host = be+gpu alias).
                            Default: ${ROLE}. Gates GPU stack, labels, init/join.
  -H, --hostname NAME       Hostname. Default: derived from --role.
  -T, --timezone ZONE       Timezone. Default: ${TIMEZONE}
      --env test|prod       Build ENV, BAKED into the image. Default: ${ENV}.
                            test = LAN-only (cluster wildcard DNS; cloudflared/ACME
                            pruned; OAuth/SMTP optional). prod = real public domain
                            (Cloudflare/ACME allowed; creds from keys USB) — prints
                            a LOUD announced banner before building.
      --cluster-domain D    Default: ${CLUSTER_DOMAIN}
  -u, --user NAME           Fallback user. Default: ${DEFAULT_USER}
      --user-password PASS  Default: ${DEFAULT_USER_PASS}
      --root-password PASS  Default: ${ROOT_PASS}
      --headscale-version V Default: ${HEADSCALE_VERSION}
      --tailscale-version V Default: ${TAILSCALE_VERSION}
      --seed-url URL        amd64 stage3 index URL.
      --enable-wifi         Re-enable WiFi (DISABLED by default: rfkill block +
                            blacklisted modules + no service). Ethernet + the
                            tailnet are unaffected. (env/brand.conf: ENABLE_WIFI=true)
      --enable-bluetooth    Re-enable Bluetooth (DISABLED by default: rfkill block
                            + blacklisted modules + no bluetooth service).
                            (env/brand.conf: ENABLE_BLUETOOTH=true)
      --skip-mesh           Don't install headscale/tailscale.
      --skip-tailscale      headscale only.
      --skip-kernel         Don't build the kernel.
      --skip-clean          Keep docs/headers/symbols.
  Artifacts (.img + live ISO are the DEFAULT; installer ISO is opt-in):
      --no-img              Don't build the raw .img.
      --img-size MiB        ext4 root size in the .img (built COMPACT, not
                            padded to the USB). Default: ${ROOT_MiB}.
      --grow V              First-boot grow policy baked in (/etc/growfs.conf):
                            fill (DEFAULT, fill the whole USB/SD/NVMe) | none
                            (keep compact) | <size> e.g. 16G, 12000M, 50%.
                            Override per-device via growfs.conf on the ESP or a
                            growfs=<v> kernel cmdline token (no rebuild).
      --no-grow             Shorthand for --grow none.
      --compress            xz -9 the finished .img.
      --live-iso            Force-build the self-booting live squashfs ISO (DEFAULT).
      --no-live-iso         Skip the live ISO (clean disable; no installer ISO implied).
      --installer-iso       Also build a stage4 + install-x86.sh data ISO.
      --no-tar              Don't emit the mounted-filesystem tarball (.fs.tar.xz).
      --resume              Reuse an existing sysroot.
  -h, --help                This help.

Run on an amd64 Gentoo host, as root. The default deliverables are a UEFI GPT
.img (ESP + ext4 root, GRUB-EFI --removable, growroot-expandable) that boots a
PC directly, a self-booting live squashfs ISO (--no-live-iso to skip), and the
mounted-filesystem tarball (--no-tar to skip). --installer-iso additionally
bundles install-x86.sh to write the layout to disk.
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
        --build-subdir) BUILD_SUBDIR="$2"; shift 2 ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        -v|--version) REL_VERSION="$2"; shift 2 ;;
        -r|--role) ROLE="$2"; shift 2 ;;
        -H|--hostname) HOSTNAME="$2"; shift 2 ;;
        -T|--timezone) TIMEZONE="$2"; shift 2 ;;
        -C|--config) CONFIG_FILE="$2"; shift 2 ;;
        --env) ENV="$2"; shift 2 ;;
        --release-tag) RELEASE_TAG="$2"; shift 2 ;;
        --cluster-domain|--domain) CLUSTER_DOMAIN="$2"; shift 2 ;;
        --brand) BRAND="$2"; shift 2 ;;
        --brand-title) BRAND_TITLE="$2"; shift 2 ;;
        --org) ORG="$2"; shift 2 ;;
        --games-domain) GAMES_DOMAIN="$2"; shift 2 ;;
        --optional-services) OPTIONAL_SERVICES="$2"; shift 2 ;;
        -u|--user) DEFAULT_USER="$2"; shift 2 ;;
        --user-password) DEFAULT_USER_PASS="$2"; shift 2 ;;
        --root-password) ROOT_PASS="$2"; shift 2 ;;
        --headscale-version) HEADSCALE_VERSION="$2"; shift 2 ;;
        --tailscale-version) TAILSCALE_VERSION="$2"; shift 2 ;;
        --seed-url) SEED_STAGE3_URL="$2"; shift 2 ;;
        --enable-wifi) ENABLE_WIFI=true; shift ;;
        --enable-bluetooth) ENABLE_BLUETOOTH=true; shift ;;
        --skip-mesh) SKIP_MESH=true; shift ;;
        --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
        --skip-kernel) SKIP_KERNEL=true; shift ;;
        --skip-clean) SKIP_CLEAN=true; shift ;;
        # ── Artifact selection ──
        --img) BUILD_IMG=true; shift ;;
        --no-img) BUILD_IMG=false; shift ;;
        --img-size) ROOT_MiB="$2"; shift 2 ;;
        --grow)     GROW_POLICY="$2"; shift 2 ;;
        --no-grow)  GROW_POLICY="none"; shift ;;
        --compress) COMPRESS_IMG=true; shift ;;
        --live-iso) LIVE_ISO=true; shift ;;
        --installer-iso) INSTALLER_ISO=true; shift ;;
        --tar) BUILD_TAR=true; shift ;;
        --no-tar) BUILD_TAR=false; shift ;;
        # --no-live-iso cleanly disables the (now-default) live ISO. It does NOT
        # imply the installer ISO — pass --installer-iso explicitly for that.
        --no-live-iso) LIVE_ISO=false; shift ;;
        # Legacy alias: --skip-iso meant "stage4 only". The .img is now the default
        # deliverable; this simply ensures no ISO is built (already the default).
        --skip-iso|--no-iso) LIVE_ISO=false; INSTALLER_ISO=false; shift ;;
        --resume) RESUME=true; shift ;;
        -h|--help) usage 0 ;;
        *) err "Unknown option: $1"; usage 1 ;;
    esac
done

# ── Validate role; derive GPU, hostname, node labels and init/join intent ──
# Node labels/taints are applied at RUNTIME by provision.sh from the KEYS stick;
# the image only bakes: the /etc/snapdragon/role marker, the OpenRC service set,
# the GPU stack (or not), and headscale-in-runlevel. The label/init hints below
# are recorded for the build summary + gen-provision-keys.sh guidance.
case "${ROLE}" in
    host) ROLE="be+gpu" ;;   # legacy alias
esac
ROLE_HEADSCALE=false         # headscale runs in the runlevel (pki/omnibus)
ROLE_K8S="worker"            # kubeadm join vs init vs single-node
ROLE_LABELS=""               # informational: node labels the KEYS stick should set
case "${ROLE}" in
    pki)
        GPU=false; ROLE_HEADSCALE=true; ROLE_K8S="control-plane"
        ROLE_LABELS="snapdragon.systems/pki=true (+ role=pki via provision.sh)"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-pki" ;;
    be)
        GPU=false; ROLE_K8S="worker"
        ROLE_LABELS="snapdragon.systems/backend=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-be" ;;
    fe)
        GPU=false; ROLE_K8S="worker"
        ROLE_LABELS="snapdragon.systems/frontend=true"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-fe" ;;
    be+gpu)
        GPU=true; ROLE_K8S="worker"
        ROLE_LABELS="snapdragon.systems/backend=true,snapdragon.systems/compute=gpu"
        # Keep the legacy 'host' hostname for back-compat with flashers/launchers.
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-host" ;;
    omnibus)
        GPU=true; ROLE_HEADSCALE=true; ROLE_K8S="single-node"
        ROLE_LABELS="snapdragon.systems/pki=true,snapdragon.systems/backend=true,snapdragon.systems/frontend=true,snapdragon.systems/compute=gpu"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-omnibus" ;;
    *)
        err "--role must be one of: pki | be | fe | be+gpu | omnibus  (host = be+gpu alias)"
        exit 1 ;;
esac

# ── Validate/normalize the first-boot grow policy (baked into /etc/growfs.conf) ──
# fill (DEFAULT) | none/off/0 (keep the compact flashed layout) | concrete size
# (16G, 12000M, 50% ...). Concrete sizes pass through to resize2fs on the node.
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
    # expects Cloudflare/OAuth/SMTP creds from the keys USB. Make it impossible
    # to miss that this is NOT a throwaway LAN image.
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
    echo -e "${RST}"
else
    info "Build ENV: test (LAN-first; cluster wildcard DNS; cloudflared/ACME pruned)"
fi

[ "$(id -u)" -eq 0 ] || { err "Run as root (chroot emerge + ISO build need it)."; exit 1; }
[ -z "${WORK_DIR}" ] && WORK_DIR="$(pwd)/out"
[ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-host"
# BUILD_ROOT = the per-arch heavy build tree under WORK_DIR (default
# WORK_DIR/snap-build-x86). The sysroot, ISO staging, distfiles, pkgdir, seed
# tarball and downloads all live here so the amd64 build never collides with the
# aarch64 (Pi) build that shares the same WORK_DIR. Finished PRODUCTS
# (.img/.iso/.fs.tar.xz/stage4) still go to WORK_DIR (see STAGE4/IMG_PATH below).
BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"
SYSROOT="${BUILD_ROOT}/sysroot"
ISO_DIR="${BUILD_ROOT}/isoroot"
CHOST="x86_64-pc-linux-gnu"

# Single, sortable UTC build stamp shared by EVERY artifact of this run, so the
# .img / .iso / stage4 / fs tarball all carry the same identifier. Computed once
# here at build start. Artifacts are named:
#   ${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.<ext>
# (the ${BRAND}- prefix + role token keep the QEMU launcher's and flash-disk.sh's
#  'snapdragon-x86-*' / 'snapdragon-*-<role>-*' autodetect globs matching.)
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"
info "Build stamp: ${BUILD_TS} (UTC; brand=${BRAND}, env=${ENV})"

# GPU-derived make.conf tokens (gate the open Mesa/Vulkan stack + DRI drivers).
if ${GPU}; then
    GPU_USE="vulkan vaapi vdpau gbm egl gles2"
    VIDEO_CARDS="amdgpu radeonsi intel iris nouveau"
else
    GPU_USE=""
    VIDEO_CARDS=""
fi

# Reconcile the legacy SKIP_ISO switch with the new opt-in ISO design: an ISO
# build runs only when --live-iso or --installer-iso was requested. The prereq
# check + Phase-10 gate key off SKIP_ISO, so keep it as the negation of "any ISO".
if ${LIVE_ISO} || ${INSTALLER_ISO}; then SKIP_ISO=false; else SKIP_ISO=true; fi

render_template() {
    sed -e "s|@@CHOST@@|${CHOST}|g" -e "s|@@JOBS@@|${JOBS}|g" \
        -e "s|@@WORK_DIR@@|${BUILD_ROOT}|g" -e "s|@@HOSTNAME@@|${HOSTNAME}|g" \
        -e "s|@@TIMEZONE@@|${TIMEZONE}|g" -e "s|@@DEFAULT_USER@@|${DEFAULT_USER}|g" \
        -e "s|@@DEFAULT_USER_PASS@@|${DEFAULT_USER_PASS}|g" -e "s|@@ROOT_PASS@@|${ROOT_PASS}|g" \
        -e "s|@@BRAND@@|${BRAND}|g" -e "s|@@BRAND_TITLE@@|${BRAND_TITLE}|g" \
        -e "s|@@DOMAIN@@|${CLUSTER_DOMAIN}|g" -e "s|@@ORG@@|${ORG}|g" \
        -e "s|@@ENV@@|${ENV}|g" \
        -e "s|@@GPU_USE@@|${GPU_USE}|g" -e "s|@@VIDEO_CARDS@@|${VIDEO_CARDS}|g" \
        "$1" > "$2"
}

# ── harden_radios <sysroot> ───────────────────────────────────────────────────
# WiFi + Bluetooth are DISABLED BY DEFAULT (hardened posture). For each radio
# left OFF (ENABLE_WIFI / ENABLE_BLUETOOTH = false) we (a) blacklist its kernel
# modules in /etc/modprobe.d/ so they don't autoload, and (b) drop a first-boot
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
        echo "# Radio hardening (generated by build-*-stage4.sh). WiFi/Bluetooth are"
        echo "# OFF by default; rfkill-block them at boot. Ethernet + tailnet untouched."
        echo "command -v rfkill >/dev/null 2>&1 || exit 0"
    } > "${act}"

    if [ "${ENABLE_WIFI}" != "true" ]; then
        {
            echo "# WiFi disabled by default (ENABLE_WIFI=false) — hardened posture."
            echo "blacklist cfg80211"
            echo "blacklist mac80211"
            echo "blacklist iwlwifi"
            echo "blacklist ath"
            echo "blacklist brcmfmac"
            echo "blacklist rtw88_core"
        } >> "${bl}"
        {
            echo "rfkill block wifi 2>/dev/null || true"
            echo "command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off 2>/dev/null || true"
        } >> "${act}"
        # Keep NetworkManager from managing/auto-enabling WiFi (wired stays managed).
        printf '[device]\nwifi.scan-rand-mac-address=yes\n\n[main]\n# WiFi disabled by default; managed=ethernet only.\n' \
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
            echo "blacklist btintel"
            echo "blacklist btrtl"
            echo "blacklist btbcm"
        } >> "${bl}"
        echo "rfkill block bluetooth 2>/dev/null || true" >> "${act}"
        info "Bluetooth DISABLED by default (rfkill block + blacklist + no service). Re-enable with --enable-bluetooth."
    else
        info "Bluetooth ENABLED (--enable-bluetooth / ENABLE_BLUETOOTH=true)."
    fi

    echo "rm -f /etc/local.d/02-radio-hardening.start" >> "${act}"
    chmod +x "${act}"
    # If both radios are enabled, the blacklist + action are inert; leave a note.
    [ -s "${bl}" ] || echo "# (no radios blacklisted — both WiFi and Bluetooth enabled)" > "${bl}"
}

# ── write_growfs_conf <dest> ──────────────────────────────────────────────────
# Emit the first-boot grow policy file consumed by the growroot service (GROW=
# fill|none|<size>). The comment header documents the per-device overrides so an
# operator editing the copy on the ESP needs no external docs.
write_growfs_conf() {
    local dest="$1"
    mkdir -p "$(dirname "${dest}")"
    cat > "${dest}" <<GROWFS_EOF
# growfs.conf — first-boot root-grow policy (read by the growroot service).
#   GROW=fill    grow the root to fill the WHOLE USB/SSD/NVMe (DEFAULT)
#   GROW=none    do not grow; keep the compact flashed layout
#   GROW=<size>  cap the root filesystem, e.g. 16G, 12000M, 50% (% of device)
# Precedence (first wins): kernel cmdline growfs=<v> > this file on the ESP >
#   /etc/growfs.conf (baked) > built-in fill. Edit this copy on the ESP to
#   retune a single flashed medium without rebuilding the image.
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
# Pin first-party FLOATING image tags (`:dev`) to the pinned RELEASE_TAG for prod
# so the prod-hygiene gate finds no floating tag, and PRUNE the ENV=test e2e
# harness wave (the test-runner app + its test-only manifests) from the baked
# prod tree. Runs ONLY for ENV=prod (called from gate_env_apps). Conservative sed:
# only first-party image lines (image: ...snapdragon-.../...-{api,ui,bff,web,gateway}:dev
# + the akkoma/tuwunel pins) are rewritten; third-party `:dev`-less images untouched.
rewrite_prod_image_tags() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    [ -d "${tree}" ] || return 0
    local n=0 f
    while IFS= read -r -d '' f; do
        # Any first-party image (its repo path contains 'snapdragon') tagged :dev
        # -> :RELEASE_TAG. Matches `image: <registry>/snapdragon.../<name>:dev`.
        # The repo-path char class EXCLUDES ':' so the greedy match stops before
        # the ':dev' tag (image repo paths carry no ':' except a registry port,
        # which our first-party images do not use).
        if grep -qE 'image:[[:space:]]*[^[:space:]:]*snapdragon[^[:space:]:]*:dev([[:space:]]|$)' "${f}" 2>/dev/null; then
            sed -i -E "s|(image:[[:space:]]*[^[:space:]:]*snapdragon[^[:space:]:]*):dev|\\1:${RELEASE_TAG}|g" "${f}"
            n=$((n+1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
    info "ENV=prod: pinned first-party :dev image tags -> :${RELEASE_TAG} in ${n} file(s)"
    # Prune the ENV=test e2e harness (forbidden in prod by the hygiene gate's
    # tier:test rule). NOTE: the pen-test is now DEV/CI-pipeline-only (a per-repo
    # ArgoCD CI stage + a build option), NOT a deployed cluster wave — there is no
    # pentest-runner app/manifest to prune anymore.
    rm -f "${SYSROOT}/var/lib/snapdragon/cluster/apps/99-test-runner.yaml" \
          "${SYSROOT}/var/lib/snapdragon/cluster/apps/00-app-of-apps-waved.yaml" 2>/dev/null || true
    rm -rf "${SYSROOT}/var/lib/snapdragon/cluster/manifests/test-runner" 2>/dev/null || true
    info "ENV=prod: pruned the test-runner wave (apps/99-test-runner.yaml + manifests/test-runner) from the baked tree"
    # STATIC prod-hygiene self-check over the BAKED tree — hard-fail the build if
    # any dev-only server / tier:test resource / floating :dev tag survived the
    # prune + rewrite above. (The RUNTIME leg — the seam/seal/live-pod probe — is
    # the ArgoCD PreSync hook Job apps/00-prod-hygiene.yaml runs in-cluster.)
    local hygiene="${SCRIPT_DIR}/scripts/validate-prod-hygiene.sh"
    if [ -x "${hygiene}" ] || [ -f "${hygiene}" ]; then
        if bash "${hygiene}" "${tree}"; then
            info "ENV=prod: prod-hygiene static gate PASSED on the baked tree"
        else
            err "ENV=prod: prod-hygiene static gate FAILED on the baked tree (a dev-only server / test harness / floating :dev tag survived) — refusing to build a prod image"
            exit 1
        fi
    else
        warn "prod-hygiene gate script not found at ${hygiene}; skipping the static self-check"
    fi
}

# ── OPTIONAL-SERVICE gate ───────────────────────────────────────────────────
# Prune every OPTIONAL service (akkoma/tuwunel/phpbb/games) NOT selected in
# OPTIONAL_SERVICES from the baked GitOps tree, enumerated by
# specs/cluster/optional-services.yaml. Mirrors the gate_env_apps `rm -f` design
# (physically removing a baked YAML IS the gate: ArgoCD recurse:true never
# instantiates a removed Application). For each unselected slug it removes the
# owned apps/*.yaml + manifests dir, its per-service ESO file (+ its kustomization
# line), its gateway HOST routes (apps/20-gateway-*.yaml) and route-access rows
# (route-access/initdb/20-schema.sql) so a matched route to a deleted upstream
# cannot 502 and a leftover role row cannot stale-grant. Shared apps (social-ui,
# serving BOTH homeservers) are removed only when ALL owners are deselected.
#
# ⚠ RUNTIME NOTE: build-time prune only stops the ONE-TIME bootstrap seed; the
# live cluster syncs apps/ from the gitops repo. True runtime add/remove uses the
# installed-services ConfigMap + the optional-services ApplicationSet
# (apps/13a-optional-services.yaml). See docs/OPTIONAL-SERVICES.md.
#
# ⚠ CROSS-REPO TODO (gateway wave): CanonicalSeed.java (snapdragon-gateway) bakes
# a route-access floor + the cloudflared configmap hardcodes matrix./mastodon.
# reserved hostnames — keep those in sync with the rows pruned here. NOT edited by
# this build (separate repo / image rebuild).
_opt_selected() {
    # $1 = slug; returns 0 if selected (present in OPTIONAL_SERVICES), else 1.
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
    # Shared social-ui (matrix + mastodon micro-frontends in ONE app) — remove only
    # when BOTH homeservers are deselected (otherwise the surviving platform keeps
    # its UI; the federation manifest greys out the absent one).
    if ! _opt_selected akkoma && ! _opt_selected tuwunel; then
        rm -f "${apps}/45-social-ui.yaml"
        info "OPTIONAL_SERVICES: both homeservers deselected — pruned shared apps/45-social-ui.yaml"
    fi
    # Repair a possible trailing comma: if pruning removed the LAST VALUES row of an
    # INSERT (the one that ended with ')' not '),'), the new last row ends with ','
    # -> a fatal trailing comma before ON CONFLICT. Re-terminate the last data row.
    _opt_fix_trailing_comma "${tree}/manifests/route-access/initdb/20-schema.sql"
    # Re-render the installed-services ConfigMap from the surviving selection so the
    # runtime ApplicationSet + admin console see the build-time install-state.
    _opt_render_installed_services
}
# Fix the dangling trailing comma left when the LAST VALUES row of an INSERT was
# pruned: rewrite the trailing '),' of the final data row before 'ON CONFLICT' to
# ')'. Operates only on the data row immediately preceding the ON CONFLICT line.
_opt_fix_trailing_comma() {
    local f="$1"
    [ -f "${f}" ] || return 0
    awk '
        { lines[NR]=$0 }
        END {
            # find the ON CONFLICT line; walk back to the last VALUES data row.
            oc=0
            for (i=NR; i>=1; i--) { if (lines[i] ~ /ON CONFLICT/) { oc=i; break } }
            if (oc>0) {
                for (i=oc-1; i>=1; i--) {
                    if (lines[i] ~ /^[[:space:]]*\(.*\)[[:space:]]*,([[:space:]]*--.*)?$/) {
                        # strip the comma right after the closing paren of this row.
                        sub(/\)[[:space:]]*,/, ")", lines[i]); break
                    }
                    if (lines[i] ~ /^[[:space:]]*\(.*\)([[:space:]]*--.*)?$/) break  # already terminated
                }
            }
            for (i=1;i<=NR;i++) print lines[i]
        }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Drop a `- <resource>` line from a kustomize resources: list.
_opt_drop_kustomize_line() {
    local f="$1" res="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+${res}([[:space:]].*)?\$|d" "${f}"
}
# Delete one or more Spring-Cloud-Gateway route blocks (a `- id: <rid>` item plus
# its indented continuation lines) from a baked gateway app's helm values.
_opt_drop_route() {
    local f="$1"; shift
    [ -f "${f}" ] || return 0
    local rid
    for rid in "$@"; do
        awk -v rid="${rid}" '
            BEGIN { skip=0; ind=-1 }
            {
                line=$0
                # indentation of this line (leading spaces)
                match(line, /^ */); cur=RLENGTH
                if (skip) {
                    # a comment ABOVE the next sibling can attach; stop skipping
                    # once we reach a line at or below the captured item indent
                    # that begins a new list item or a shallower key.
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
# Drop the `- <host-prefix>...` extraHosts entry (+ any leading comment block) for
# a games-style host from a gateway app's ingress.extraHosts.
_opt_drop_extrahost() {
    local f="$1" prefix="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+\"?${prefix}[^[:space:]\"]*\"?[[:space:]]*\$|d" "${f}"
}
# Delete gateway_route_access INSERT VALUES rows matching (gateway, url_pattern)
# from the baked schema.sql. Rows are `  ('<gw>', '<pat>', 'ROLE', bool), -- ...`.
# Uses awk with LITERAL substring matching (the url_patterns carry ** / . which are
# regex metachars) on the row's leading `('<gw>', '<pat>',` so only the data rows
# are removed and the surrounding comments are left intact.
_opt_drop_rows() {
    local f="$1" gw="$2"; shift 2
    [ -f "${f}" ] || return 0
    local pat
    for pat in "$@"; do
        awk -v gw="${gw}" -v pat="${pat}" '
            BEGIN { needle = "(\x27" gw "\x27" }   # ('gw'   (x27 = single quote)
            {
                line=$0
                # Strip leading whitespace for the prefix test.
                t=line; sub(/^[[:space:]]+/, "", t)
                if (index(t, needle)==1) {
                    # This is a VALUES row for THIS gateway; check the url_pattern is
                    # the 2nd quoted field and equals pat exactly.
                    rest=t; sub(/^\([[:space:]]*\x27[^\x27]*\x27[[:space:]]*,[[:space:]]*\x27/, "", rest)
                    # rest now begins with the url_pattern; cut at its closing quote.
                    q=index(rest, "\x27")
                    if (q>0 && substr(rest,1,q-1)==pat) { next }
                }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
# Render manifests/policy/installed-services-configmap.yaml install-state booleans
# from the surviving OPTIONAL_SERVICES selection (the runtime ApplicationSet +
# admin console read this). Idempotent: rewrites the data: block in place.
_opt_render_installed_services() {
    local cm="${SYSROOT}/var/lib/snapdragon/cluster/manifests/policy/installed-services-configmap.yaml"
    [ -f "${cm}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        # '#'-delimited so the (true|false) alternation does not collide with the delimiter.
        sed -i -E "s#^([[:space:]]*)${slug}:[[:space:]]*\"(true|false)\"#\\1${slug}: \"${val}\"#" "${cm}"
    done
    info "OPTIONAL_SERVICES: rendered installed-services ConfigMap (selected: ${OPTIONAL_SERVICES:-none})"
}
# Parameterize the games-realm OIDC identity on GAMES_DOMAIN. rebrand_sysroot does
# NOT touch the .games literals (its rules match snapdragon.systems / snapdragon-),
# so the games host + issuer + redirects would otherwise stay snapdragon.games and
# break iss-strict JWT validation under the subdomain default. Runs UNCONDITIONALLY
# (even for the default brand) and BEFORE rebrand_sysroot so the default literal
# games.snapdragon.systems composes with the snapdragon.systems->CLUSTER_DOMAIN
# rule. A custom GAMES_DOMAIN (e.g. <brand>.games) is rebrand-neutral.
parameterize_games_domain() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    [ -d "${tree}" ] || return 0
    local f n=0
    # URL-SCHEME-ANCHORED: only rewrite snapdragon.games when it is a HOST (right
    # after the // of https://...), so the games-realm origin/issuer/redirect/website
    # URLs flip to ${GAMES_DOMAIN} while the canonical IMAGE repo paths
    # (snapdragon-systems/snapdragon.games-backend, .../snapdragon.games/backend) are
    # left untouched. id.snapdragon.games -> id.${GAMES_DOMAIN}; bare host -> ${GAMES_DOMAIN}.
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
    # The games PUBLIC host literal (gateway-be route host + ingress extraHost) is
    # "games.snapdragon.systems" so it composes with the snapdragon.systems ->
    # CLUSTER_DOMAIN rebrand into games.<CLUSTER_DOMAIN> = the DEFAULT GAMES_DOMAIN.
    # If the operator set a CUSTOM GAMES_DOMAIN (e.g. the real <brand>.games TLD),
    # the host must follow it instead of the subdomain default — rewrite it here,
    # BEFORE rebrand (which would otherwise only map the snapdragon.systems suffix).
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
        rewrite_prod_image_tags
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
            -e "s|//id\.snapdragon\.games|//id.${GAMES_DOMAIN}|g" \
            -e "s|//snapdragon\.games|//${GAMES_DOMAIN}|g" \
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
# .img builder tools (default deliverable) — losetup/mkfs/parted/grub-install must
# be present and the build must run as root (already enforced). grub-install must
# support the x86_64-efi target for the GRUB-EFI --removable install.
if ${BUILD_IMG}; then
    for t in parted losetup mkfs.vfat mkfs.ext4 blkid grub-install; do
        command -v "$t" >/dev/null || { warn "missing ${t}; disabling .img build"; BUILD_IMG=false; break; }
    done
    if ${BUILD_IMG} && [ ! -d /usr/lib/grub/x86_64-efi ]; then
        warn "grub x86_64-efi target not found (/usr/lib/grub/x86_64-efi); .img will not be UEFI-bootable"
        warn "rebuild sys-boot/grub with GRUB_PLATFORMS containing efi-64"
    fi
fi
if ${LIVE_ISO}; then
    for t in grub-mkrescue xorriso; do
        command -v "$t" >/dev/null || { warn "missing ${t}; disabling --live-iso"; LIVE_ISO=false; break; }
    done
    # Either mksquashfs (sys-fs/squashfs-tools) or tar2sqfs (sys-fs/squashfs-tools-ng)
    # can squash the rootfs; the squash step below picks whichever is present.
    if ${LIVE_ISO} && ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; then
        warn "missing mksquashfs AND tar2sqfs; disabling --live-iso"; LIVE_ISO=false
    fi
fi
if ${INSTALLER_ISO}; then
    command -v xorriso >/dev/null || warn "no xorriso; installer ISO will be left as a plain tree"
fi

# ── 1. Directories ─────────────────────────────────────────────────
banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir} "${SYSROOT}" "${ISO_DIR}"
info "Work dir:   ${WORK_DIR}  (products land here)"
info "Build root: ${BUILD_ROOT}  (per-arch sysroot/distfiles/pkgdir)"

# ── 2. Seed stage3 ─────────────────────────────────────────────────
banner "Fetching amd64 hardened stage3 seed"
# The index is PGP-signed; select the stage3 tarball line, ignoring armor/comments.
STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
# Per-arch: the amd64 seed must not be reused by (or clobber) the aarch64 build.
STAGE3_LOCAL="${BUILD_ROOT}/$(basename "${STAGE3_FILE}")"
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_FILE}"
[ -f "${STAGE3_LOCAL}" ] || { info "Downloading $(basename "${STAGE3_FILE}")"; curl -L -o "${STAGE3_LOCAL}" "${STAGE3_URL}"; }

# ── 3. Extract ─────────────────────────────────────────────────────
banner "Extracting stage3"
if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then
    info "Sysroot populated and --resume — skipping extraction"
else
    # A non-resume build must start from a CLEAN sysroot. Extracting stage3 OVER a
    # populated tree leaves stale packages (e.g. extra python slots, old kubelet)
    # in var/db/pkg — a HYBRID db that breaks dep resolution (observed: 3 python
    # slots surviving + libselinux[python] conflicts). Wipe first so the extract
    # is pristine. (Warm reuse is the explicit --resume path above.)
    if [ -f "${SYSROOT}/etc/gentoo-release" ]; then
        warn "Non-resume build over a populated sysroot — wiping for a clean stage3 extract"
        rm -rf "${SYSROOT}"; mkdir -p "${SYSROOT}"
    fi
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
# package.use: copy all role-independent files; the GPU-only 'gpu' file (Mesa
# vulkan/vaapi video_cards_*) is copied ONLY for GPU roles so a headless image
# never references VIDEO_CARDS it isn't building.
for puf in "${SPECS_DIR}/portage/package.use/"*; do
    [ "$(basename "${puf}")" = "gpu" ] && ! ${GPU} && continue
    cp "${puf}" "${SYSROOT}/etc/portage/package.use/"
done

# x86 GRUB cmdline (SELinux LSM + KSPP hardening). Disable os-prober so a
# grub-mkconfig (installer / chroot) can never enumerate the host's other disks.
mkdir -p "${SYSROOT}/etc/default"
cp "${SPECS_DIR}/etc/default/grub"                    "${SYSROOT}/etc/default/grub"
grep -q '^GRUB_DISABLE_OS_PROBER=' "${SYSROOT}/etc/default/grub" || \
    echo 'GRUB_DISABLE_OS_PROBER=true' >> "${SYSROOT}/etc/default/grub"

# PARTUUID-token fstab (mounts / + /boot/efi by PARTUUID, plus hardening tmpfs).
# The .img builder and install-x86.sh substitute __ROOT_PARTUUID__/__ESP_PARTUUID__.
cp "${SPECS_DIR}/etc/fstab"                           "${SYSROOT}/etc/fstab"

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
# Layer-A: bake the BOOTSTRAP policy AS the initial /etc/headscale/policy.hujson
# (NO any-to-any tag:snapdragon->tag:snapdragon:* :22 hole; KEEPS the k8s CIDR
# data-plane rule + a single conservative @@TS_SSH_USER@@ ssh rule). The #66
# full-mesh policy.hujson is intentionally NOT baked here — its any-to-any :22 hole
# must not exist at any time. The first verified Layer-A sync wholesale re-renders
# this from policy.hujson.tmpl. (provision_headscale also restages this from
# policy.bootstrap.hujson at provision time as a belt-and-braces.)
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson" "${SYSROOT}/etc/headscale/policy.hujson"   # Layer-A bootstrap (policy.mode: file)
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh"  "${SYSROOT}/usr/sbin/keys-provision"; chmod +x "${SYSROOT}/usr/sbin/keys-provision"
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-backup"  "${SYSROOT}/usr/local/sbin/snapdragon-backup"; chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-backup"
for svc in containerd kubelet headscale tailscaled keys-provision growroot; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"; chmod +x "${SYSROOT}/etc/init.d/${svc}"
done

# ── Layer-B device-license-registry sshd enforcement (ADMIN/mesh-extension) ─────
# INERT on a SUPERADMIN/core host: provision_device_registry() ACTIVATES it only
# when owner_type=ADMIN. Enforcement conf + break-glass + cron STAGED under
# /etc/snapdragon/registry (installed on ADMIN nodes only; conf gate-flips on first
# verified sync).
mkdir -p "${SYSROOT}/usr/lib/snapdragon" "${SYSROOT}/etc/snapdragon/registry" "${SYSROOT}/var/lib/snapdragon/device-registry"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-authorized-keys-lookup" "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup"; chmod +x "${SYSROOT}/usr/sbin/snapdragon-authorized-keys-lookup"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-device-registry-sync"   "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync";   chmod +x "${SYSROOT}/usr/sbin/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/usr/lib/snapdragon/registry-verify.sh"      "${SYSROOT}/usr/lib/snapdragon/registry-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"; chmod +x "${SYSROOT}/etc/init.d/snapdragon-device-registry-sync"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/device-registry.conf" "${SYSROOT}/etc/snapdragon/registry/device-registry.conf"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/break-glass.conf"     "${SYSROOT}/etc/snapdragon/registry/break-glass.conf"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-device-registry-sync" "${SYSROOT}/etc/snapdragon/registry/cron-device-registry-sync"

# ── Layer-A device-license-registry headscale policy (CONTROL/pki node only) ────
# CENTRALIZED: provision_headscale_policy_sync() ACTIVATES these only when
# headscale.enabled==true (the control node). The renderer + forced-tag pass + the
# bootstrap policy + the render template are baked into every host image (inert on
# a non-control node); REUSES the SAME registry-verify.sh + baked
# registry-pub.ed25519 as Layer-B (no duplication).
cp "${SHARED_SPECS}/usr/sbin/gen-headscale-policy.sh"          "${SYSROOT}/usr/sbin/gen-headscale-policy.sh";          chmod +x "${SYSROOT}/usr/sbin/gen-headscale-policy.sh"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-headscale-forcetags"   "${SYSROOT}/usr/sbin/snapdragon-headscale-forcetags";   chmod +x "${SYSROOT}/usr/sbin/snapdragon-headscale-forcetags"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-policy-sync"         "${SYSROOT}/etc/init.d/snapdragon-policy-sync";         chmod +x "${SYSROOT}/etc/init.d/snapdragon-policy-sync"
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson"     "${SYSROOT}/etc/headscale/policy.bootstrap.hujson"
cp "${SHARED_SPECS}/etc/headscale/policy.hujson.tmpl"          "${SYSROOT}/etc/headscale/policy.hujson.tmpl"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-policy-sync"         "${SYSROOT}/etc/snapdragon/registry/cron-policy-sync"

render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"

# First-boot grow policy (read by the growroot service). Default "fill" => the
# root expands to fill the whole USB/SSD/NVMe on first boot; --grow none keeps the
# compact flashed layout; --grow <size> caps the root filesystem. A copy is also
# dropped on the ESP in build_img so it can be edited per-device after a flash.
write_growfs_conf "${SYSROOT}/etc/growfs.conf"

# Cluster GitOps payload + role markers
mkdir -p "${SYSROOT}/etc/snapdragon" "${SYSROOT}/var/lib/snapdragon"
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
cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/snapdragon/cluster"
parameterize_games_domain  # rewrite .games -> ${GAMES_DOMAIN} (BEFORE rebrand; fixes games OIDC iss on the subdomain default)
gate_env_apps             # prune ENV-specific ArgoCD apps from the baked copy
gate_optional_services    # prune OPTIONAL services (akkoma/tuwunel/phpbb/games) not in OPTIONAL_SERVICES
rebrand_sysroot           # rewrites snapdragon.systems -> ${CLUSTER_DOMAIN} (incl. lan-dns/cloudflared/games)

# Identity, locale, CNI dirs
echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"; echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"
mkdir -p "${SYSROOT}/opt/cni/bin" "${SYSROOT}/etc/cni/net.d" "${SYSROOT}/var/lib/keys-provision"

# Runlevels. growroot expands the ext4 root to fill the medium on first boot and
# orders itself before keys-provision (so provisioning sees the full disk).
# headscale (identity/mesh control server) runs only on the pki / omnibus nodes;
# worker roles (be/fe/be+gpu) reach the mesh as a tailscale client.
mkdir -p "${SYSROOT}/etc/runlevels/default"
SVCS=(sshd NetworkManager cronie haveged growroot keys-provision containerd kubelet auditd local)
${ROLE_HEADSCALE} && SVCS+=(headscale)
${SKIP_MESH} || ${SKIP_TAILSCALE} || SVCS+=(tailscaled)
for s in "${SVCS[@]}"; do ln -sf "/etc/init.d/${s}" "${SYSROOT}/etc/runlevels/default/${s}" 2>/dev/null || true; done

# ── Radio hardening: WiFi + Bluetooth DISABLED BY DEFAULT ──────────────────
# Shrink the attack surface — by default neither radio comes up: their kernel
# modules are blacklisted (modprobe.d) and a first-boot local.d action rfkill-
# blocks them + tells NetworkManager to leave WiFi unmanaged. ETHERNET + the
# Tailscale tailnet are UNTOUCHED. ENABLE_WIFI / ENABLE_BLUETOOTH (knobs/flags)
# re-enable each. NetworkManager bluetooth/bluez services are not in SVCS, so
# nothing extra is enabled when they stay off.
harden_radios "${SYSROOT}"

# ── 5. Chroot setup + native emerge ────────────────────────────────
banner "Native emerge inside chroot"

# Guard: chrooting needs an amd64 sysroot. The amd64 and aarch64 builds now keep
# their sysroots in SEPARATE per-arch subdirs (snap-build-x86 vs snap-build-pi5),
# so a shared --work-dir no longer collides. This guard only trips if someone
# overrode --build-subdir to point both arches at the SAME subdir, or hand-built
# a foreign sysroot here; then `chroot /bin/bash` would die with a confusing
# "No such file or directory".
if [ -e "${SYSROOT}/bin/bash" ] && ! file -L "${SYSROOT}/bin/bash" 2>/dev/null | grep -qE 'x86-64|x86_64'; then
    err "Sysroot ${SYSROOT} is NOT amd64 (looks like a foreign arch — e.g. the RPi aarch64 build)."
    err "The x86 build uses its own --build-subdir (default snap-build-x86); make sure it does"
    err "NOT match the Pi build's subdir (snap-build-pi5), or use a separate --work-dir."
    err "Or remove the stale sysroot:  rm -rf '${SYSROOT}'  (then re-run without --resume)."
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
    # Package build scratch on a NON-eCryptfs filesystem. The work dir often lives
    # on eCryptfs (/home/.Private), whose ~143-char filename limit makes Go builds
    # (kubelet/runc/cni-plugins/containerd — long vendored/cache paths) die with
    # "File name too long". Bind the chroot's /var/tmp/portage onto a host xfs dir
    # so package builds dodge the limit; INSTALLED files (short names) still land in
    # the eCryptfs sysroot fine. Only kicks in when the sysroot is actually eCryptfs.
    PORTAGE_SCRATCH_MOUNTED=false
    if df -T "${SYSROOT}" 2>/dev/null | awk 'NR==2{exit($2=="ecryptfs"?0:1)}'; then
        local scratch="/var/tmp/snap-portage-${BUILD_SUBDIR}"
        local availg; availg=$(df -BG --output=avail /var/tmp 2>/dev/null | tail -1 | tr -dc '0-9')
        [ "${availg:-99}" -lt 15 ] && warn "only ${availg}G free on /var/tmp (xfs) for build scratch; a large parallel build may fill it (EMERGE_JOBS is held low to bound this)."
        mkdir -p "${scratch}" "${SYSROOT}/var/tmp/portage"
        mount --bind "${scratch}" "${SYSROOT}/var/tmp/portage" && PORTAGE_SCRATCH_MOUNTED=true
        info "Build scratch -> non-eCryptfs xfs ${scratch} (eCryptfs 143-char filename-limit workaround)"
    fi
}
umount_chroot() {
    ${PORTAGE_SCRATCH_MOUNTED:-false} && umount -l "${SYSROOT}/var/tmp/portage" 2>/dev/null || true
    ${HOST_REPO_MOUNTED:-false} && umount -l "${SYSROOT}/var/db/repos/gentoo" 2>/dev/null || true
    for m in run dev sys proc; do umount -lR "${SYSROOT}/$m" 2>/dev/null || true; done
}
trap umount_chroot EXIT
mount_chroot

# Base package set; the vendor-agnostic GPU stack (Mesa/Vulkan/libva) is appended
# ONLY for GPU roles (be+gpu / omnibus) so pki/be/fe images stay slim.
PKG_LISTS=("${SPECS_DIR}/portage/packages.list")
${GPU} && PKG_LISTS+=("${SPECS_DIR}/portage/packages-gpu.list")
PKGS=$(grep -hv '^\s*#' "${PKG_LISTS[@]}" | grep -v '^\s*$' | tr '\n' ' ')
${GPU} && info "GPU role: including Mesa/Vulkan stack (packages-gpu.list)" \
        || info "Headless role: skipping Mesa/Vulkan stack"

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

# Package-level emerge parallelism, MEMORY-BOUNDED. EMERGE_JOBS concurrent
# packages, each make -j${JOBS} -l${JOBS}. C builds self-throttle on the shared
# system load via -l (all makes read the same loadavg). Go builds (kubelet, runc,
# cni-plugins, containerd, nerdctl) IGNORE make's jobserver and -l, defaulting to
# GOMAXPROCS=ncpu — so several concurrent Go builds each spawning 28-way blew past
# 32 GB RAM and the OOM killer failed 6 diverse packages at once. Cap both: fewer
# concurrent packages (JOBS/7) AND a hard GOMAXPROCS so Go can't grab the machine.
# Held LOW (2): package build scratch is bind-mounted onto the 20 GB xfs / (the
# eCryptfs filename-limit workaround in mount_chroot), so few concurrent package
# builds keeps peak scratch within that budget — and also bounds the Go-build RAM
# that OOM-killed the payload. The kernel builds in /usr/src (sysroot), not here.
# EMERGE_JOBS=1: SERIALIZE package builds. At 2 concurrent, the payload's 8 Go
# packages (kubelet/runc/cni-plugins/containerd/nerdctl/cri-tools/...) overlapped
# and their shared-runtime recompiles were OOM-KILLED (silent death, no compiler
# error — confirmed). One package at a time means a single Go build has the whole
# 32 GB, so concurrent-build OOM is structurally impossible. Also keeps the
# bind-mounted scratch within the 20 GB xfs / budget. (Raise once known-good.)
EMERGE_JOBS=1
GO_PROCS=$(( JOBS / 7 )); [ "${GO_PROCS}" -lt 2 ] && GO_PROCS=2
chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
export MAKEOPTS="-j${JOBS} -l${JOBS}"
export EMERGE_DEFAULT_OPTS="--jobs ${EMERGE_JOBS} --load-average ${JOBS} --usepkg=y --binpkg-respect-use=y"
# Bound Go's self-managed parallelism (it ignores MAKEOPTS/-l) so even a single
# kubelet/runc build doesn't spike RAM → OOM-killed compile.
export GOMAXPROCS=${GO_PROCS}
export GOFLAGS="-p=${GO_PROCS}"
# A working locale: the stage3 has none configured, so build steps that call
# setlocale (e.g. sys-fs/btrfs-progs' docs/python tooling) die with
# "locale.Error: unsupported locale setting". C.UTF-8 is built into glibc (no
# locale-gen needed) and is always valid.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# Build chroot: /boot/efi exists in the baked fstab but is never mounted here.
# Without this, mount-boot.eclass (linux-firmware, grub-themes) dies in
# pkg_pretend ("/boot/efi not mounted") and ABORTS the ENTIRE package-set
# emerge before anything merges — producing a payload-less stage4.
export DONT_MOUNT_BOOT=1
# Refresh ld.so.cache up front so any libs INHERITED from a warm/reused sysroot
# (e.g. an interrupted prior run that merged sqlite but never ran ldconfig) are
# resolvable before the python-dependent package emerge needs them — otherwise
# wheel builds die on "libsqlite3.so.0: cannot open shared object file".
ldconfig 2>/dev/null || true
if [ ! -d /var/db/repos/gentoo/metadata ] && ! mountpoint -q /var/db/repos/gentoo; then
    emerge-webrsync
fi
emerge --oneshot --update --newuse sys-apps/baselayout || true
# Apply our profile/USE across @world without churning the toolchain.
emerge --update --deep --newuse --keep-going ${EMERGE_EXCLUDE} @world \
    || echo "[build-x86] WARN: @world had package failures (--keep-going); continuing"
# Ensure the stage4 package set is present (deps included).
# --autounmask-continue auto-applies any required USE-flag change and continues
# the merge (so a dep needing e.g. a USE flag doesn't ABORT resolution the way a
# bare emerge does), but --autounmask-keep-keywords / -keep-masks keep keyword &
# mask decisions EXPLICIT — those are pre-seeded in package.accept_keywords for a
# reproducible hardened build rather than silently pulling unstable/masked pkgs.
emerge --update --deep --newuse --keep-going \
    --autounmask-continue=y --autounmask-keep-keywords=y --autounmask-keep-masks=y \
    ${EMERGE_EXCLUDE} ${PKGS} \
    || { echo "[build-x86] WARN: some stage4 packages failed; review the emerge output"
         # DIAGNOSTIC: --autounmask-continue is NOT applying needed USE changes in
         # this chroot, so resolution dies one conflict at a time. A PRETEND
         # --autounmask pass computes the COMPLETE set of USE changes the payload
         # needs in one go — dump it so they can all be pre-seeded into the
         # package.use specs at once instead of whack-a-mole.
         echo "[build-x86] ===== AUTOUNMASK-PRETEND: full USE/keyword changes the payload needs ====="
         emerge --pretend --autounmask=y --autounmask-write=n --autounmask-backtrack=y \
             --keep-going ${EMERGE_EXCLUDE} ${PKGS} 2>&1 \
             | grep -E 'USE changes|keyword changes|^# |^>=|^<|^=|Change USE|necessary|masked by' \
             || true
         echo "[build-x86] ===== END AUTOUNMASK-PRETEND ====="; }
# Rebuild the dynamic-linker cache: with sandbox/postinst hooks disabled in this
# chroot, ldconfig can be skipped after a merge, leaving e.g. libsqlite3.so.0
# present on disk but absent from /etc/ld.so.cache — python wheel builds then die
# with "libsqlite3.so.0: cannot open shared object file" and cascade-fail the
# whole python-dependent package set. Refresh it explicitly before depending on it.
ldconfig 2>/dev/null || true
# The packages.list payload is MANDATORY for a usable role image — fail LOUDLY
# if the core set is missing rather than emit a payload-less stage4 (this
# happened silently for every x86 role until the DONT_MOUNT_BOOT fix above).
missing=""
for b in grub-install dracut parted jq nmcli kubelet kubeadm containerd; do
    command -v "\${b}" >/dev/null || missing="\${missing} \${b}"
done
if [ -n "\${missing}" ]; then
    echo "[build-x86] ERROR: stage4 payload incomplete — missing:\${missing}"
    echo "[build-x86]        packages.list did not merge; review the emerge output above."
    exit 1
fi
CHROOT

# ── 6. Mesh VPN (amd64 static binaries) ────────────────────────────
if ${SKIP_MESH}; then
    banner "Mesh VPN SKIPPED"
else
    banner "Installing mesh VPN (headscale + tailscale, amd64)"
    if curl -fL -o "${SYSROOT}/usr/bin/headscale" \
        "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"; then
        chmod +x "${SYSROOT}/usr/bin/headscale"; info "headscale installed"
    else err "headscale fetch failed — the image enables its service in the runlevel; aborting (use --skip-mesh to opt out)"; exit 1; fi
    if ! ${SKIP_TAILSCALE}; then
        TGZ="${BUILD_ROOT}/tailscale_${TAILSCALE_VERSION}_amd64.tgz"
        if curl -fL -o "${TGZ}" "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz"; then
            TMP="$(mktemp -d)"; tar -C "${TMP}" -xzf "${TGZ}"
            SUB="$(find "${TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
            install -Dm0755 "${SUB}/tailscale" "${SYSROOT}/usr/bin/tailscale"
            install -Dm0755 "${SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
            rm -rf "${TMP}"; info "tailscale installed"
        else err "tailscale fetch failed — tailscaled is enabled in the runlevel; aborting (use --skip-tailscale to opt out)"; exit 1; fi
    fi
fi

# ── 7. Kernel (Gentoo HARDENED kernel) ─────────────────────────────
# sys-kernel/hardened-sources (grsecurity) was removed from Gentoo in 2017. The
# modern Gentoo hardened kernel = sys-kernel/gentoo-sources built under the
# hardened profile (PIE/SSP toolchain) with the KSPP + SELinux hardening config
# fragment applied below. This step is SELF-SUFFICIENT + idempotent: the main
# package emerge may have aborted, so it re-ensures the sources + /usr/src/linux
# symlink exist before building, and fails loudly if core hardening didn't take.
if ${SKIP_KERNEL}; then
    banner "Kernel SKIPPED"
else
    banner "Building Gentoo hardened kernel (gentoo-sources + KSPP/SELinux + k8s fragment)"
    # Base (role-independent) hardening+k8s fragment; append the DRM driver block
    # ONLY for GPU roles. Headless roles keep just the virtio-gpu console FB.
    cp "${SPECS_DIR}/kernel/hardened-k8s.config" "${SYSROOT}/tmp/k.config"
    if ${GPU}; then
        cat "${SPECS_DIR}/kernel/gpu.config" >> "${SYSROOT}/tmp/k.config"
        info "Kernel: appending GPU/DRM fragment (gpu.config)"
    else
        info "Kernel: headless (no AMD/Intel/Nouveau DRM drivers)"
    fi
    chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
# (Re)ensure the hardened kernel sources are installed and /usr/src/linux is set
# — independent of whether the main stage4 emerge completed.
if [ ! -e /usr/src/linux/Makefile ]; then
    emerge --noreplace --quiet-build sys-kernel/gentoo-sources \
        || emerge --quiet-build sys-kernel/gentoo-sources
fi
eselect kernel set 1 || true
if [ ! -e /usr/src/linux/Makefile ]; then
    echo "[build-x86] ERROR: /usr/src/linux is not set up (sys-kernel/gentoo-sources missing)"; exit 1
fi
cd /usr/src/linux
make defconfig
while IFS= read -r line; do
    [[ "\${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "\${line// }" ]] && continue
    read -r action rest <<< "\${line}"
    eval "scripts/config --\${action} \${rest}"
done < /tmp/k.config
make olddefconfig
# Refuse to ship a kernel that silently lost its hardening (e.g. a symbol that
# olddefconfig pruned for an unmet dep). Stable, long-standing KSPP/LSM symbols.
for must in CONFIG_SECURITY_SELINUX CONFIG_STACKPROTECTOR_STRONG CONFIG_FORTIFY_SOURCE CONFIG_HARDENED_USERCOPY; do
    grep -q "^\${must}=y" .config || { echo "[build-x86] ERROR: hardened kernel option \${must} not enabled after olddefconfig"; exit 1; }
done
# SELinux only activates if CONFIG_LSM is a clean, well-formed string. x86 has no
# lsm= on the GRUB cmdline to override a corrupted builtin, so a stray quote here
# would silently ship SELinux DISABLED. Assert the exact intended value.
grep -q '^CONFIG_LSM="yama,selinux,bpf"\$' .config || { echo "[build-x86] ERROR: CONFIG_LSM malformed (expected yama,selinux,bpf); SELinux would not activate"; exit 1; }
make -j${JOBS} bzImage modules
make modules_install
make install
# Disk-boot initramfs (NOT the live dmsquash-live one): a normal, generic
# (--no-hostonly) dracut image so the persistent ext4 GPT root mounts on real
# hardware AND in VMs. Named initramfs-<kver>.img to match the grub.cfg the .img
# builder writes. The live ISO builds its own initramfs-live.img separately.
KVER="\$(make -s kernelrelease 2>/dev/null || ls /lib/modules | sort -V | tail -1)"
if command -v dracut >/dev/null; then
    dracut --force --no-hostonly \
        --add-drivers "ext4 vfat nvme ahci sd_mod usb_storage uas virtio_blk virtio_pci virtio_net" \
        --kver "\${KVER}" "/boot/initramfs-\${KVER}.img" \
        || echo "[build-x86] WARN: dracut (disk initramfs) failed; the .img may not boot"
else
    echo "[build-x86] WARN: dracut not installed; no disk initramfs (sys-kernel/dracut should be in packages.list)"
fi
CHROOT
    rm -f "${SYSROOT}/tmp/k.config"
    info "Gentoo hardened kernel + disk-boot initramfs installed to ${SYSROOT}/boot"
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
# Filename-safe role tag. be+gpu keeps the legacy 'host' tag so existing
# flashers/launchers/gen-provision-keys examples that reference 'host' keep
# working; the other roles get their own (filesystem-friendly) names.
case "${ROLE}" in
    be+gpu) ROLE_TAG="host" ;;
    *)      ROLE_TAG="${ROLE}" ;;
esac
STAGE4="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.stage4.tar.xz"
# Multi-threaded xz (-T0) over the tar stream — -cJf is single-threaded and
# left 27 cores idle on the multi-GB sysroot; mirrors the fs.tar codepath below.
# --exclude=./usr/src: the kernel was built in /usr/src/linux (its modules +
# vmlinuz are already installed to /lib/modules + /boot), so the multi-GB build
# tree (.o/.cmd objects) is pure cruft in the image — and baking it in overflowed
# the fixed ROOT_MiB ext4 root partition ("No space left on device" mid-.img
# population). The rpi5 builder already strips it (rm /usr/src/* + --exclude); match it.
tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude='./home/magus' -cpf - . 2>/dev/null \
    | xz -T0 -6 > "${STAGE4}" \
  || tar -C "${SYSROOT}" --numeric-owner \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude='./home/magus' -cpf - . | xz -T0 -6 > "${STAGE4}"
info "Stage4: ${STAGE4} ($(du -sh "${STAGE4}" | cut -f1))"

# ── 10. Raw .img (DEFAULT deliverable) ─────────────────────────────
# UEFI GPT image mirroring the rpi5 build_img, adapted MBR->GPT + a GRUB-EFI
# --removable install. Layout: p1 ESP FAT32 (/boot/efi, holds /EFI/BOOT/BOOTX64.EFI
# + grub.cfg) + p2 ext4 root (LAST so growroot expands it). Boots any UEFI PC the
# image is dd'd onto (no NVRAM entry — --no-nvram + --removable fallback path).
#
# Runs entirely as root (the build is already privileged): losetup, mkfs, mount,
# grub-install and xattr-preserving extraction all require it. A cleanup trap
# tears down the ESP+root mounts and the loop device on ANY failure/early return.
IMG_PATH="(not built)"
INSTALLER_ISO_PATH="(not built)"
FS_TAR_PATH="(not built)"
build_img() {
    local img_size_mib loop esp_part root_part root_mnt esp_uuid root_uuid kver vmlinuz initrd
    loop=""; root_mnt=""

    IMG_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.img"

    # 1MiB alignment gap + 512MiB ESP + ROOT_MiB ext4 root + 1MiB slack.
    img_size_mib=$(( 1 + 512 + ROOT_MiB + 1 ))

    _img_cleanup() {
        local rc=$?
        set +e
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}/boot/efi" && umount "${root_mnt}/boot/efi"
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}" && umount "${root_mnt}"
        [ -n "${loop}" ] && losetup "${loop}" &>/dev/null && losetup -d "${loop}"
        [ -n "${root_mnt}" ] && rmdir "${root_mnt}" 2>/dev/null
        return "${rc}"
    }
    trap '_img_cleanup' ERR EXIT

    info "Image size: ${img_size_mib} MiB (1 gap + 512 ESP + ${ROOT_MiB} ext4 + 1 slack)"
    rm -f "${IMG_PATH}"
    truncate -s "${img_size_mib}MiB" "${IMG_PATH}"

    # GPT: p1 ESP FAT32 (esp flag), p2 ext4 root (513..100%). p2 is LAST so
    # growroot can expand it to the end of the medium on first boot. Pure UEFI —
    # no BIOS-boot partition (the adopted design is UEFI-only for the .img).
    parted -s "${IMG_PATH}" mklabel gpt
    parted -s "${IMG_PATH}" mkpart ESP fat32 1MiB 513MiB
    parted -s "${IMG_PATH}" set 1 esp on
    parted -s "${IMG_PATH}" mkpart root ext4 513MiB 100%

    loop="$(losetup --show -fP "${IMG_PATH}")"
    esp_part="${loop}p1"
    root_part="${loop}p2"
    udevadm settle &>/dev/null || sleep 1

    info "Formatting ${esp_part} (FAT32 SNAP_ESP) and ${root_part} (ext4 SNAP_ROOT)"
    mkfs.vfat -F 32 -n SNAP_ESP "${esp_part}"
    mkfs.ext4 -q -L SNAP_ROOT -F "${root_part}"

    root_mnt="$(mktemp -d "${BUILD_ROOT}/img-root.XXXXXX")"
    mount "${root_part}" "${root_mnt}"

    info "Extracting stage4 into ${root_mnt}"
    tar -C "${root_mnt}" --xattrs-include='*.*' -xpf "${STAGE4}" 2>/dev/null || \
    tar -C "${root_mnt}" -xpf "${STAGE4}"

    # Mount the ESP at /boot/efi (the kernel/initramfs stay on the ext4 /boot per
    # the fstab; the ESP holds only /EFI/BOOT/BOOTX64.EFI + grub.cfg).
    mkdir -p "${root_mnt}/boot/efi"
    mount "${esp_part}" "${root_mnt}/boot/efi"

    # ── Root identity (PARTUUID for the kernel/fstab; fs-UUID for grub search) ──
    esp_uuid="$(blkid -s PARTUUID -o value "${esp_part}")"
    root_uuid="$(blkid -s PARTUUID -o value "${root_part}")"
    local root_fsuuid; root_fsuuid="$(blkid -s UUID -o value "${root_part}")"
    info "Root identity: root PARTUUID=${root_uuid}  ESP PARTUUID=${esp_uuid}"
    # The stage4 already carries specs-x86/etc/fstab with the two tokens; rewrite
    # them to the real PARTUUIDs of this image.
    sed -i -e "s/__ROOT_PARTUUID__/${root_uuid}/g" -e "s/__ESP_PARTUUID__/${esp_uuid}/g" \
        "${root_mnt}/etc/fstab"

    # ── Locate the kernel + disk initramfs on the ext4 /boot ──────────
    kver="$(ls "${root_mnt}/lib/modules" 2>/dev/null | sort -V | tail -1)"
    vmlinuz="$(ls -1 "${root_mnt}/boot/vmlinuz-"* "${root_mnt}/boot/vmlinuz" 2>/dev/null | sort -V | tail -1 || true)"
    initrd="$(ls -1 "${root_mnt}/boot/initramfs-"*.img 2>/dev/null | grep -v 'initramfs-live' | sort -V | tail -1 || true)"
    vmlinuz="${vmlinuz##*/}"; initrd="${initrd##*/}"

    # ── GRUB-EFI --removable into the ESP (host-safe: --no-nvram) ──────
    # Writes ${ESP}/EFI/BOOT/BOOTX64.EFI (removable fallback path) + ${root}/boot/grub.
    # No host NVRAM entry, no os-prober — safe to run against a loop-mounted image.
    info "Installing GRUB-EFI (--removable, --no-nvram) into the image ESP"
    # Bootloader install failure must be FATAL: the .img is the default
    # deliverable and an empty ESP means a brick announced as success.
    grub-install --target=x86_64-efi \
        --efi-directory="${root_mnt}/boot/efi" \
        --boot-directory="${root_mnt}/boot" \
        --removable --no-nvram \
        --modules="part_gpt fat ext2 normal linux search search_fs_uuid configfile gzio all_video" \
        || { err "grub-install FAILED — .img would not be UEFI-bootable"; exit 1; }
    [ -f "${root_mnt}/boot/efi/EFI/BOOT/BOOTX64.EFI" ] \
        || { err "ESP has no EFI/BOOT/BOOTX64.EFI after grub-install — refusing to ship a non-booting .img"; exit 1; }

    # ── Hand-written grub.cfg (no grub-mkconfig => no host os-prober/chroot) ──
    # Source the hardened cmdline from the grub defaults so the .img and the live
    # ISO share ONE cmdline (lsm=,selinux=1,audit=1,cgroup,slab,ASLR hardening).
    local cmdline=""
    if [ -f "${root_mnt}/etc/default/grub" ]; then
        cmdline="$(. "${root_mnt}/etc/default/grub"; printf '%s' "${GRUB_CMDLINE_LINUX:-}")"
    fi
    [ -z "${cmdline}" ] && cmdline="lsm=yama,selinux,bpf selinux=1 audit=1"
    mkdir -p "${root_mnt}/boot/grub"
    {
        echo "set timeout=5"
        echo "set default=0"
        echo "insmod part_gpt"
        echo "insmod ext2"
        echo "insmod search_fs_uuid"
        echo "menuentry \"${BRAND_TITLE} (${ROLE})\" {"
        echo "    search --no-floppy --fs-uuid --set=root ${root_fsuuid}"
        if [ -n "${vmlinuz}" ]; then
            echo "    linux /boot/${vmlinuz} root=PARTUUID=${root_uuid} ro ${cmdline}"
            [ -n "${initrd}" ] && echo "    initrd /boot/${initrd}"
        else
            echo "    # WARNING: no vmlinuz found under /boot at build time"
        fi
        echo "}"
    } > "${root_mnt}/boot/grub/grub.cfg"

    # Drop a per-device-editable growfs.conf on the ESP so an operator can retune
    # the first-boot grow (fill|none|<size>) on a flashed disk WITHOUT a rebuild.
    # growroot reads /boot/efi/growfs.conf ahead of the baked /etc copy.
    write_growfs_conf "${root_mnt}/boot/efi/growfs.conf"

    # ── Filesystem tarball ────────────────────────────────────────────
    # Capture the FULLY-MOUNTED tree (ext4 root with the FAT ESP mounted at
    # /boot/efi) as one tar, so it can be untarred onto pre-mounted partitions
    # (mount the ESP at /boot/efi first) to provision a disk without dd. tar
    # crosses the /boot/efi mountpoint by default, so the ESP contents
    # (EFI/BOOT/BOOTX64.EFI + grub.cfg) are captured at /boot/efi/*. This is the
    # .img's exact final filesystem (PARTUUID fstab + grub.cfg baked in) — the
    # rootfs "as if mounted". Mirrors the rpi5 build's FS-tarball step.
    if ${BUILD_TAR}; then
        local fs_tar="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.fs.tar.xz"
        info "Filesystem tarball (mounted tree) -> ${fs_tar}"
        tar -C "${root_mnt}" --xattrs --xattrs-include='*.*' --numeric-owner -cpf - . 2>/dev/null \
            | xz -T0 -6 > "${fs_tar}" \
          || tar -C "${root_mnt}" --numeric-owner -cpf - . | xz -T0 -6 > "${fs_tar}"
        FS_TAR_PATH="${fs_tar}"
    fi

    sync
    umount "${root_mnt}/boot/efi"
    umount "${root_mnt}"
    rmdir  "${root_mnt}"; root_mnt=""
    losetup -d "${loop}"; loop=""
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
    banner "Building raw .img (UEFI GPT: ESP + ext4 root, GRUB-EFI --removable)"
    # A bootable image needs a kernel on the ext4 /boot. Guard like the ISO path:
    # if no vmlinuz is present (kernel skipped / build failed), skip rather than crash.
    if [ -z "$(ls -1 "${SYSROOT}/boot/vmlinuz-"* "${SYSROOT}/boot/vmlinuz" 2>/dev/null)" ]; then
        warn "No vmlinuz in ${SYSROOT}/boot — skipping .img (don't pass --skip-kernel)."
        IMG_PATH="(not built — kernel missing)"
    else
        build_img
    fi
else
    banner "SKIPPED .img (--no-img)"
fi

# ── 11. ISOs (live + installer, both opt-in) ───────────────────────
ISO_PATH="(not built)"
if ! ${SKIP_ISO}; then
    KVER="$(ls "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1)"
    VMLINUZ="$(ls -1 "${SYSROOT}/boot/vmlinuz-"* "${SYSROOT}/boot/vmlinuz" 2>/dev/null | sort -V | tail -1 || true)"

    if ${LIVE_ISO} && [ -n "${VMLINUZ}" ] && [ -n "${KVER}" ]; then
        ISO_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.live.iso"
        banner "Building bootable LIVE ISO (grub-mkrescue + squashfs)"
        # Live initramfs (dmsquash-live) built inside the chroot.
        mount_chroot; trap umount_chroot EXIT
        chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT || warn "live-initramfs dracut step FAILED (live ISO will be skipped)"
if ! command -v dracut >/dev/null; then
    echo "[build-x86] ERROR: dracut not installed in sysroot"; exit 1
fi
dracut --force --no-hostonly \
    --add "dmsquash-live" \
    --add-drivers "squashfs iso9660 loop sr_mod usb_storage ahci nvme" \
    --kver "${KVER}" /boot/initramfs-live.img
CHROOT
        umount_chroot; trap - EXIT

        if [ ! -s "${SYSROOT}/boot/initramfs-live.img" ]; then
            err "no live initramfs was generated — a live ISO without it cannot boot (root=live:/rd.live.* are dracut directives). Skipping live ISO."
            ISO_PATH="(not built — live initramfs missing)"
            SKIP_LIVE_PACK=true
        else
            SKIP_LIVE_PACK=false
        fi
        if ! ${SKIP_LIVE_PACK}; then
        mkdir -p "${ISO_DIR}/boot/grub" "${ISO_DIR}/LiveOS"
        cp "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
        cp "${SYSROOT}/boot/initramfs-live.img" "${ISO_DIR}/boot/initramfs.img"
        info "Squashing rootfs (this can take a while)..."
        if command -v mksquashfs >/dev/null; then
            mksquashfs "${SYSROOT}" "${ISO_DIR}/LiveOS/squashfs.img" \
                -comp zstd -e proc sys dev run var/cache/distfiles home/magus >/dev/null
        else
            # squashfs-tools-ng fallback: same excludes, xz (kernel has SQUASHFS_XZ).
            tar -C "${SYSROOT}" --numeric-owner \
                --exclude='./proc' --exclude='./sys' --exclude='./dev' \
                --exclude='./run' --exclude='./var/cache/distfiles' --exclude='./home/magus' \
                -cpf - . | tar2sqfs -q -c xz -j "${JOBS}" "${ISO_DIR}/LiveOS/squashfs.img"
        fi
        # Unify the cmdline with the .img: source GRUB_CMDLINE_LINUX from the same
        # grub defaults (full KSPP/LSM/audit/cgroup hardening), not a short literal.
        LIVE_CMDLINE="$(. "${SPECS_DIR}/etc/default/grub"; printf '%s' "${GRUB_CMDLINE_LINUX:-lsm=yama,selinux,bpf selinux=1}")"
        cat > "${ISO_DIR}/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0
menuentry "${BRAND_TITLE} ${ROLE} (live)" {
    linux /boot/vmlinuz root=live:CDLABEL=SNAPDRAGON_LIVE rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img console=tty0 ${LIVE_CMDLINE}
    initrd /boot/initramfs.img
}
EOF
        grub-mkrescue -o "${ISO_PATH}" "${ISO_DIR}" -volid SNAPDRAGON_LIVE 2>/dev/null \
            && info "Bootable live ISO: ${ISO_PATH}" \
            || { warn "grub-mkrescue failed; live ISO not produced"; ISO_PATH="(not built — grub-mkrescue failed)"; }
        fi
    elif ${LIVE_ISO}; then
        warn "Live ISO requested but no vmlinuz/modules present — skipping (don't pass --skip-kernel)"
    fi

    if ${INSTALLER_ISO}; then
        INSTALLER_ISO_PATH="${WORK_DIR}/${BRAND}-x86-amd64-${ROLE_TAG}-${ENV}-${BUILD_TS}.installer.iso"
        banner "Building installer ISO (stage4 + install-x86.sh; boot a live USB to install)"
        INST_DIR="${BUILD_ROOT}/isoroot-installer"
        rm -rf "${INST_DIR}"; mkdir -p "${INST_DIR}/stage4"
        cp "${STAGE4}" "${INST_DIR}/stage4/"
        cp "${SPECS_DIR}/installer/install-x86.sh" "${INST_DIR}/install-x86.sh"; chmod +x "${INST_DIR}/install-x86.sh"
        cp "${SPECS_DIR}/etc/fstab" "${INST_DIR}/fstab.template" 2>/dev/null || true
        if command -v xorriso >/dev/null; then
            xorriso -as mkisofs -o "${INSTALLER_ISO_PATH}" -volid SNAPDRAGON_INSTALL -joliet -rock "${INST_DIR}"
            info "Installer ISO: ${INSTALLER_ISO_PATH}"
            [ "${ISO_PATH}" = "(not built)" ] && ISO_PATH="${INSTALLER_ISO_PATH}"
        else
            INSTALLER_ISO_PATH="${INST_DIR}  (tree; no xorriso to wrap an ISO)"
            warn "xorriso missing — left an installable tree at ${INST_DIR}"
            [ "${ISO_PATH}" = "(not built)" ] && ISO_PATH="${INSTALLER_ISO_PATH}"
        fi
    fi
fi

# ── 12. Summary ────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}=== ${BRAND_TITLE} x86_64 (hardened k8s, role=${ROLE}) ===${RST}"
echo "  Profile:    $(cat "${SYSROOT}/etc/portage/profile/parent")"
echo "  Kernel:     $(${SKIP_KERNEL} && echo 'skipped' || echo 'Gentoo hardened (gentoo-sources + hardened profile + KSPP/SELinux config)')"
echo "  Role:       ${ROLE}   (cluster domain: ${CLUSTER_DOMAIN})"
echo "  ENV:        ${ENV}   $([ "${ENV}" = test ] && echo '(LAN-first: cluster wildcard DNS; cloudflared/ACME pruned)' || echo '(PROD: public domain; Cloudflare/ACME; creds from keys USB)')"
echo "  Brand:      ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}${CONFIG_FILE:+   (profile: ${CONFIG_FILE})}"
echo "  GPU:        $(${GPU} && echo 'vendor-agnostic Mesa/Vulkan (amdgpu/i915/nouveau) + DRM kernel' || echo 'headless (no Mesa/Vulkan, virtio-gpu console only)')"
echo "  k8s:        ${ROLE_K8S}  (init/join/single-node is applied at runtime by the KEYS stick)"
echo "  Labels:     ${ROLE_LABELS}  (set on the KEYS stick: .snapdragon.node_labels)"
echo "  headscale:  $(${ROLE_HEADSCALE} && echo 'in runlevel (identity/mesh control server)' || echo 'no (tailscale client only)')"
echo "  Work dir:   ${WORK_DIR}  (products below); build root: ${BUILD_ROOT}"
echo "  Stage4:     ${STAGE4}"
echo "  Image:      ${IMG_PATH}"
echo "  FS tarball: ${FS_TAR_PATH}"
echo "  Live ISO:   ${ISO_PATH}"
echo "  Installer:  ${INSTALLER_ISO_PATH}"
echo ""
echo "  growroot expands the ext4 root to fill the medium on first boot."
echo "  Default artifact = the .img (dd it to a disk/USB; UEFI GPT, GRUB-EFI removable)."
echo ""
echo "  Provision a KEYS stick for this node with:"
case "${ROLE}" in
    pki)     echo "    ./scripts/gen-provision-keys.sh -r pki -o keys-${ROLE_TAG}        # control-plane (kubeadm init)" ;;
    be)      echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-${ROLE_TAG}    # worker; label snapdragon.systems/backend=true" ;;
    fe)      echo "    ./scripts/gen-provision-keys.sh -r frontend -o keys-${ROLE_TAG}   # worker; label snapdragon.systems/frontend=true" ;;
    be+gpu)  echo "    ./scripts/gen-provision-keys.sh -r backend -o keys-${ROLE_TAG}    # worker; edit:";
             echo "    snapdragon.role=games, node_labels { snapdragon.systems/compute: gpu }" ;;
    omnibus) echo "    ./scripts/gen-provision-keys.sh -r pki -o keys-${ROLE_TAG}        # single-node CP; all labels (pki/backend/frontend/compute=gpu)" ;;
esac
