#!/usr/bin/env bash
# build-rpi5-stage4.sh
# Build a hardened Gentoo aarch64 stage4 ISO with Kubernetes for a Raspberry
# Pi Foundation board (--board rpi5 [DEFAULT, BCM2712/Cortex-A76] | rpi4
# [BCM2711/Cortex-A72] | rpi3 [BCM2837/Cortex-A53, DESKTOP-ONLY]) using
# crossdev toolchain on x86_64.
#
# WHY one script, not a separate builder (Phase 6): Pi 4 and Pi 5 share the
# Raspberry Pi Foundation's EEPROM/config.txt/device-tree-overlay boot model
# closely enough (same firmware family, same raspberrypi-sources kernel tree,
# same installer/LUKS2/desktop-role machinery) that a --board axis is the right
# call, mirroring how build-jetson-stage4.sh's --board picks an Orin SKU. Only
# genuinely board-DIFFERENT values (defconfig, DTB prefix, CPU tuning, a few
# RP1-vs-BCM2711 hardware Kconfig lines, the serial console device, the
# rpi-eeprom USE flag) are gated on --board; everything else — the desktop
# role (Phase 3), --encrypt-root LUKS2 (Phase 2b), the mesh/provisioning
# plumbing — is shared, board-agnostic machinery reused as-is.
#
# --board rpi3 (Phase 8) is MORE architecturally different than Pi 4 was from
# Pi 5: no flashable EEPROM at all (boots via bootcode.bin+start.elf read
# straight off the FAT boot partition by the GPU boot ROM — see the
# dev-embedded/rpi-eeprom exclusion below), no PCIe/xHCI/NVMe at all (USB +
# USB-attached Ethernet ride the SoC's Synopsys DWC2 controller instead — see
# specs-rpi5/kernel/bcm2837-pi3.config), and VideoCore IV instead of VI/VII
# (same vc4/v3d DRM driver pair as Pi 4/5, but needs an explicit
# dtoverlay=vc4-kms-v3d — see config.txt.tmpl's VC4_OVERLAY_LINE). Only 1GB of
# RAM is not enough headroom for this repo's hardened SELinux/containerd/
# kubelet k8s stack, so --board rpi3 is DESKTOP-ONLY: it hard-errors on every
# --role except desktop (see the BOARD-gate check right after role validation
# below) instead of silently building a Pi 3 k8s node that fails mysteriously
# at runtime from OOM.
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
# predicate the --encrypt-root fail-fast preflight and build_disk_initramfs()'s
# Strategy 1 (qemu-chroot) rely on. Shared so rpi5/frite/opi5/opi-zero2/jetson do
# not drift on the load-bearing bit. See scripts/_dracut-cross-lib.sh.
# Host-safety guard: the container predicate gating every HOST-mutating step
# (the /etc/portage seeds + the host emerge below, and _dracut-cross-lib.sh's
# kernel-global binfmt registration). Fail-safe: an unproven runtime is treated
# as the operator's real machine and nothing is written. See
# scripts/_host-guard-lib.sh.
# shellcheck source=scripts/_host-guard-lib.sh
source "${SCRIPT_DIR}/scripts/_host-guard-lib.sh"
# shellcheck source=scripts/_dracut-cross-lib.sh
source "${SCRIPT_DIR}/scripts/_dracut-cross-lib.sh"

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
# ── BOARD TABLE (--board rpi5 [DEFAULT] | rpi4 | rpi3 [desktop-only]) ──────
# Selected by --board. Fills the GCC CPU + kernel defconfig + DTB prefix + boot
# kernel-image filename. Mirrors build-jetson-stage4.sh's JETSON_BOARD/
# select_board() pattern: RPI_CPU/RPI_DEFCONFIG/RPI_DTB_PREFIX/RPI_KERNEL_IMG
# start EMPTY here and are filled by select_board() (called right after arg
# parsing) ONLY when the operator did NOT already set them explicitly via
# -c/-d/--dtb-prefix/--kernel-img — an explicit override always wins, board or
# no board. rpi5 stays the DEFAULT so every existing invocation (no --board
# flag at all) resolves to EXACTLY the same values as before this axis existed.
BOARD="rpi5"                              # rpi5 (DEFAULT, BCM2712/Cortex-A76) | rpi4 (BCM2711/Cortex-A72) | rpi3 (BCM2837/Cortex-A53, desktop-only)
BOARD_DESC=""                             # derived by select_board() (--print-plan/banner display only)
RPI_CPU=""
RPI_DEFCONFIG=""
RPI_DTB_PREFIX=""
RPI_KERNEL_IMG=""
JOBS="$(nproc)"
SKIP_KERNEL=false
RPI_KVER=""              # captured from `make kernelrelease` in the kernel phase
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
ROOT_MiB=9216           # ext4 root partition size in the .img (growroot expands it on first boot)
GROW_POLICY="fill"      # first-boot grow policy baked into /etc/growfs.conf: fill|none|<size> (see growroot)
SD_ONLY=false           # use literal /dev/mmcblk0p2 instead of PARTUUID/LABEL identity
COMPRESS_IMG=false      # xz -9 the finished .img
EXTRA_PACKAGES=""
PACKAGES_ADD=""          # --packages-add : atoms to add on top of the derived set
PACKAGES_DROP=""         # --packages-drop: default-set atoms to remove (mandatory floor honored)
TIMEZONE="UTC"
HOSTNAME=""
ROLE="generic"          # generic | pki | backend | frontend | desktop
DESKTOP="none"          # derived: 'light' for --role desktop, else none (--print-plan/banner display only)
CLUSTER_DOMAIN="snapdragon.systems"
# Orchestration superdomain (WS-SUPER-B): the mesh control plane's MagicDNS suffix every
# node joins. "" = builder default (legacy byte-identical). The Studio emits --superdomain
# <effective> only for MESH builds; permanently internal, never the go-live apex.
SUPERDOMAIN=""
BRAND="snapdragon"                  # name slug (namespaces, gateways, hostnames)
BRAND_TITLE="Snapdragon Systems"    # human-readable title
ORG="Snapdragon-Systems"            # GitHub org / image namespace
# Games portal domain. DEFAULT = SUBDOMAIN of the primary (games.<CLUSTER_DOMAIN>)
# until the real .games TLD is obtained; flip with GAMES_DOMAIN=<brand>.games. The
# default literal composes with rebrand_sysroot (snapdragon.systems->CLUSTER_DOMAIN).
# Drives the games host + OIDC issuer/redirects via parameterize_games_domain().
GAMES_DOMAIN="games.snapdragon.systems"
# ── DEFAULT-INCLUSION POLICY (user 2026-06-17) ───────────────────────
# USER_LEVEL_SERVICES is the SINGLE source-of-truth set of user-level OPTIONAL
# slugs (matches specs/cluster/optional-services.yaml; excludes the non-user-level
# infra slugs egress-vpn / tor / workloadConsole / anubis). It is what
# OPTIONAL_SERVICES=all / --all-services expands to.
USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio"
# OPTIONAL services selected on this image (subset of USER_LEVEL_SERVICES).
#   DEFAULT-ON  (the built-in default when NO selection is given): akkoma tuwunel phpbb.
#   DEFAULT-OFF (must be specifically added): games owncast tube (and any future
#               user-level service) — pruned unless explicitly selected.
# FULL-SET sentinel: OPTIONAL_SERVICES=all (or --all-services) expands to EVERY
# user-level slug (USER_LEVEL_SERVICES) just before EXCLUDE_SERVICES subtracts, so
# `all` + EXCLUDE_SERVICES="games" still drops games. GAMES IS OPT-IN / OFF BY
# DEFAULT — the games subdomain (games.<CLUSTER_DOMAIN>) + casdoor-games + games
# app-store are baked only when games is explicitly selected (--enable-games /
# ENABLE_GAMES=true, by listing 'games' in --optional-services, or via 'all').
# brand.conf narrows; --optional-services overrides both (built-in < brand.conf <
# flag). Unselected slugs are pruned by gate_optional_services.
OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"
# EXCLUDE_SERVICES — the SUBTRACTIVE build-time exclusion knob (brand.conf /
# --exclude-services). Any user-level slug listed here is REMOVED from the final
# selection AFTER all positive sources (built-in default, brand.conf
# OPTIONAL_SERVICES, --optional-services, the games opt-in) are resolved, so it is
# pruned from the baked tree by gate_optional_services no matter how it got
# selected. This is the one knob that can turn OFF an on-by-default service
# (akkoma/tuwunel/phpbb) without having to re-enumerate the whole positive list.
# Example (brand.conf): EXCLUDE_SERVICES="phpbb tuwunel"  (forum-less + Matrix-less).
# Equivalent to listing the slug as a "-<slug>"/"no-<slug>" negative token in
# OPTIONAL_SERVICES; EXCLUDE_SERVICES is just the readable, dedicated list form.
EXCLUDE_SERVICES="${EXCLUDE_SERVICES:-}"
# MANAGED_SERVICES — the MANAGED BACKING SERVICES selection (brand.conf / env), a
# WHITESPACE-separated list of `id=endpoint` tokens (commas are literal — a kafka
# endpoint is a comma-list of brokers) (e.g. "kafka=msk-broker:9098
# postgres-admin-bff=my.rds.amazonaws.com:5432"). Each id names a backing service
# (see specs/cluster/backing-services.yaml) whose in-mesh workload is pruned and
# whose consumer endpoint is repointed at <endpoint> by gate_backing_services().
# EMPTY (default) = SELF-HOSTED, byte-identical mainline (the #1 invariant). CLI
# --managed-service id=endpoint APPENDS to this. Tier-3 (docs-only) ids are
# fail-closed refused; creds are operator-supplied via gen-cluster-secrets, never
# argv/git. See docs/MANAGED-SERVICES.md.
MANAGED_SERVICES="${MANAGED_SERVICES:-}"
# Games opt-in toggle. --enable-games / ENABLE_GAMES=true folds 'games' into
# OPTIONAL_SERVICES (post-arg-parse, idempotent), baking the games subdomain.
ENABLE_GAMES="${ENABLE_GAMES:-false}"
# ── Build ENV selector (BAKED into the image) ──────────────────────
# test (DEFAULT, local-first/safe): LAN-only — cluster wildcard DNS ON, the
#   go-live cloudflared/external-dns/ACME app is PRUNED from the baked apps/,
#   OAuth/SMTP/Cloudflare optional/absent. Internal cluster-CA TLS only.
# prod: bakes the REAL public domain — public DNS / Cloudflare, ACME ALLOWED on
#   top of the internal CA, OAuth/SMTP/Cloudflare from the keys USB. A LOUD
#   announced banner prints before the build because it bakes the real domain.
ENV="test"
# ── Release-state selector (BAKED into the image, gates gate_env_apps()/
# bake_host_firewall() ingress+firewall posture) ────────────────────
# internal (DEFAULT, safe): public ingress-nginx pruned, gateways forced to
#   the nginx-internal class, tier-ingress NetworkPolicy admits only
#   ingress-nginx-internal, host nftables firewall drops inbound 80/443 from
#   outside the tailnet unless /etc/snapdragon/go-live exists.
# public: the above restrictions are lifted (rebuild-time go-live).
RELEASE_STATE="internal"
CONFIG_FILE=""                      # optional drop-in brand profile (sourced)
DEFAULT_USER="pi"
# NO baked default password. Real creds come from the KEYS USB ($6$ hashes in
# users.json via keys-provision). On a keyless boot the first-boot finaliser
# (specs/etc/local.d/01-firstboot.start.tmpl) mints a RANDOM one-time password
# and locks root — see the OWASP "default creds baked into image" fix.
#
# ── Standalone posture (mirrors build-x86-host-stage4.sh) ──────────
# --standalone composes onto --role desktop (the only client role): no mesh, a
# normal local user logs in with a password set at build time instead of the
# KEYS-USB-provisioned account. Every OTHER --role (generic/pki/backend/
# frontend) is a k8s cluster node, so --standalone hard-errors on those.
STANDALONE=false        # --standalone : local user, no mesh, LUKS2-encrypted root
LOCAL_USER=""           # --local-user NAME : the standalone local login account
LOCAL_USER_PASS=""      # --local-pass PASS : plaintext; hashed at build, never baked raw
ROLE_CLIENT=false       # true for --role desktop; false for the k8s cluster-node roles
# ── LUKS2 root encryption — independently triggerable from --standalone,
# same as build-x86-host-stage4.sh/build-frite-stage4.sh: encrypts the ROOT of
# whatever --role is being built today (generic/pki/backend/frontend/desktop).
# Install-time only (parted+luksFormat+ mkfs+extract, see
# specs-rpi5/installer/install.sh) — the DEFAULT .img stays
# plaintext (it is written directly by build_img(), no install step), so
# --encrypt-root forces the installer ISO (--iso) which DOES encrypt.
ENCRYPT_ROOT=false      # --encrypt-root : LUKS2-encrypt the root partition (installer path only)
LUKS_PASS=""            # --luks-pass PASS : plaintext; never baked, seeded into the ISO 0600 if given
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
# Root SSH login DISABLED by default (hardened); opt back in with --permit-root-login.
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-no}"
# ── Mesh-node identity provider (I6; docs/IDENTITY-PROVIDERS.md) ─────────────
# casdoor (the NATIVE DEFAULT) changes NOTHING — every sysroot byte is identical
# to before the axis existed. --idp entra|aws|oidc (+ --idp-issuer/--idp-client-id
# [--idp-jwks]) switches token VALIDATION to an external OIDC provider: idp.conf
# bake + post-rebrand issuer/JWKS rewrite + Casdoor-app gating + README-IDP.md
# (mirrors build-x86-host-stage4.sh byte-for-byte).
IDP="${IDP:-casdoor}"
IDP_ISSUER="${IDP_ISSUER:-}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-}"
IDP_JWKS="${IDP_JWKS:-}"
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt"

# Mesh VPN (installed as upstream static arm64 binaries, not emerged)
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false

# --print-plan: resolve + validate everything, print the machine-greppable build
# plan (one PLAN_KEY=VALUE per line) and exit 0 BEFORE any mutation (no root, no
# disk writes, no network). The CLI/make/menu/Studio channels + the build-matrix
# harness (tests/build-matrix/check.sh) verify every role/flag combo through it.
PRINT_PLAN=false

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
    with Kubernetes for a Raspberry Pi Foundation board (--board rpi5
    [DEFAULT] | rpi4 | rpi3 [desktop-only]), using a crossdev toolchain
    on an x86_64 host.

SYNOPSIS
    build-rpi5-stage4.sh [OPTIONS]

DESCRIPTION
    Cross-compiles a complete Gentoo Linux stage4 image targeting
    Raspberry Pi 5 (BCM2712 / Cortex-A76, the DEFAULT), Raspberry Pi 4
    (BCM2711 / Cortex-A72, --board rpi4), or Raspberry Pi 3 (BCM2837 /
    Cortex-A53, --board rpi3).  The resulting image ships with a
    hardened kernel, SELinux, auditing, and — on Pi 5/Pi 4 cluster-node
    roles — a full Kubernetes stack (containerd, kubelet, kubeadm,
    kubectl, CNI plugins).

    --board rpi3 is DESKTOP-ONLY (1GB RAM is not enough headroom for
    this repo's hardened SELinux/containerd/kubelet k8s stack on top of
    it): it must be combined with --role desktop, and hard-errors on
    every other --role (generic/pki/backend/frontend).

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
    │   │   ├── rpi5                    RPi USE flags (rpi-eeprom pi4|pi5 board-flipped;
    │   │   │                           EXCLUDED entirely for --board rpi3, no EEPROM at all)
    │   │   └── kubernetes              K8s USE flags
    │   ├── env/
    │   │   └── cross-go.conf.tmpl      Go cross-compile env (templated)
    │   └── package.env/
    │       └── kubernetes              Package-to-env mapping
    ├── boot/
    │   ├── config.txt.tmpl             RPi boot config (templated)
    │   └── cmdline.txt.tmpl            Kernel command line (templated: console UART)
    ├── etc/
    │   └── fstab                       Filesystem table (RPi /boot firmware)
    ├── kernel/
    │   ├── hardened-k8s.config         Universal base fragment (all 3 boards)
    │   ├── rp1-pi5.config              Additive: RP1-only hw (--board rpi5)
    │   ├── bcm2711-pi4.config          Additive: BCM2711-native hw (--board rpi4)
    │   ├── bcm2837-pi3.config          Additive: DWC2 USB/USB-Ethernet/BCM2835
    │   │                               GPIO-header hw (--board rpi3)
    │   └── desktop.config              Additive: --role desktop (all 3 boards)
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
    --board rpi5|rpi4|rpi3
        Selects the board table that derives --cpu/--defconfig/--dtb-prefix/
        --kernel-img (and the board-appropriate kernel Kconfig fragment +
        serial console) all at once. An explicit -c/-d/--dtb-prefix/
        --kernel-img still overrides whatever --board would have picked.
        Default: rpi5  (every invocation with no --board flag is 100%
        unaffected by this axis)
          rpi5  Raspberry Pi 5 (BCM2712, Cortex-A76) — the historical default.
          rpi4  Raspberry Pi 4 (BCM2711, Cortex-A72). No RP1 southbridge (its
                GPIO/I2C/SPI are native BCM2711 silicon instead — see
                specs-rpi5/kernel/bcm2711-pi4.config), no user-facing PCIe/NVMe
                on the standard Model B, VideoCore VI (shares the DRM_V3D/
                DRM_VC4 driver pair with Pi 5's VideoCore VII).
          rpi3  Raspberry Pi 3 (BCM2837, Cortex-A53, 1GB RAM). DESKTOP-ONLY —
                must be combined with --role desktop; hard-errors on every
                other role (1GB RAM is not enough headroom for this repo's
                hardened SELinux/containerd/kubelet k8s stack). No flashable
                EEPROM at all (boots via bootcode.bin+start.elf; dev-embedded/
                rpi-eeprom is excluded entirely, not just left unflashed — see
                specs-rpi5/kernel/bcm2837-pi3.config), no PCIe/xHCI/NVMe (USB +
                USB-attached Ethernet ride the SoC's Synopsys DWC2 controller
                instead), VideoCore IV (same DRM_V3D/DRM_VC4 driver pair as
                Pi 4/5, but needs an explicit dtoverlay=vc4-kms-v3d — HIGH
                UNCERTAINTY, not verified against real Pi 3 hardware in this
                sandbox; see bcm2837-pi3.config's header).

    -c, --cpu CPU
        GCC -mcpu / -mtune value.
        Default: derived from --board (cortex-a76 for rpi5, cortex-a72 for
                 rpi4, cortex-a53 for rpi3)
        Common values: cortex-a53 (RPi 3), cortex-a72 (RPi 4), cortex-a76 (RPi 5)

    -d, --defconfig NAME
        Kernel defconfig to use.
        Default: derived from --board (bcm2712_defconfig for rpi5,
                 bcm2711_defconfig for rpi4, bcmrpi3_defconfig for rpi3)
        Common values: bcmrpi3_defconfig (RPi 3),
                       bcm2711_defconfig (RPi 4)

    --dtb-prefix PREFIX
        Device-tree blob filename prefix.
        Default: derived from --board (bcm2712 for rpi5, bcm2711 for rpi4,
                 bcm2837 for rpi3)

    --kernel-img NAME
        Output kernel image filename for /boot.
        Default: derived from --board (kernel_2712.img for rpi5, kernel8.img
                 for rpi4/rpi3 — the standard 64-bit RPi kernel image name
                 shared by every 64-bit-capable board before Pi 5)

    --pcie-gen3
        Uncomment dtparam=pciex1_gen=3 in config.txt to force
        PCIe Gen 3 for NVMe.  Not all drives are stable at Gen 3;
        test yours first. Meaningful on --board rpi5 ONLY — the standard Pi 4
        Model B has no user-facing PCIe slot (a --board rpi4 build warns and
        ignores this flag) and Pi 3 (BCM2837) has no PCIe controller at all
        (a --board rpi3 build likewise warns and ignores this flag).

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
        Default: 9216

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
        Default: gentoo-<board>  (gentoo-rpi5 for --board rpi5 [DEFAULT],
                 gentoo-rpi4 for --board rpi4) — --role generic only; every
                 other --role defaults to <brand>-<role>. (--board rpi3 is
                 desktop-only, so its hostname always follows the
                 <brand>-<role> default; "gentoo-rpi3" is unreachable since
                 --role generic + --board rpi3 hard-errors before this default
                 is ever computed.)

    -T, --timezone ZONE
        Target system timezone (e.g. America/New_York).
        Default: UTC

    -u, --user NAME
        Default non-root user created on first boot.
        Default: pi

    --user-password PASS   (DEPRECATED, ignored)
    --root-password PASS   (DEPRECATED, ignored)
        No password is baked into the image. Real credentials come from the
        KEYS USB ($6$ hashes in users.json via keys-provision). On a keyless
        boot the first-boot finaliser mints a RANDOM one-time password for the
        default user (printed to the console) and LOCKS root. These flags are
        accepted but ignored so old call sites do not break.

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

    --standalone
        Standalone posture: no mesh; a local user logs in with a build-time
        password instead of the KEYS-USB-provisioned account. Forces
        --encrypt-root (LUKS2-encrypted root via the installer ISO). Composes
        onto --role desktop (the only client role) — every OTHER --role
        (generic/pki/backend/frontend) is a k8s cluster node, so
        --standalone hard-errors on those.

    --local-user NAME
        The standalone local login account (default: --user).

    --local-pass PASS
        Plaintext; hashed at build (yescrypt, $6$ fallback), never baked raw. Omit
        it and a random one-time password is minted + printed once at first
        boot instead.

    --encrypt-root
        LUKS2-encrypt the root partition (installer ISO path only; the
        default .img stays plaintext). Automatically forced on by
        --standalone.

    --luks-pass PASS
        Plaintext passphrase for the encrypted root; seeded 0600 into the ISO
        if given. Omit it and install.sh prompts interactively on the target
        (or the install host — see specs-rpi5/installer/install.sh's header).

    --enable-wifi
        Re-enable WiFi. DISABLED by default (rfkill block + blacklisted modules
        + no service); Ethernet + the tailnet are unaffected.
        (env/brand.conf: ENABLE_WIFI=true)

    --enable-bluetooth
        Re-enable Bluetooth. DISABLED by default (rfkill block + blacklisted
        modules + no bluetooth service). (env/brand.conf: ENABLE_BLUETOOTH=true)

    --enable-games
        Bake the Snapdragon Game Studio optional service + games.<CLUSTER_DOMAIN>
        subdomain. OPT-IN; OFF by default. Equivalent to adding 'games' to
        --optional-services. (env/brand.conf: ENABLE_GAMES=true)

    --optional-services "<slugs>"
        The SUBSET of user-level OPTIONAL services to bake (allow-list). Choose from
        akkoma tuwunel phpbb games owncast tube, or the literal "all" (every
        user-level slug). Unlisted slugs are pruned from the baked GitOps tree by
        gate_optional_services. Built-in DEFAULT (no selection given) is
        "akkoma tuwunel phpbb"; games/owncast/tube are DEFAULT-OFF (opt-in).
        (env/brand.conf: OPTIONAL_SERVICES; OPTIONAL_SERVICES=all = the full set)

    --all-services
        Bake EVERY user-level OPTIONAL service (akkoma tuwunel phpbb games owncast
        tube) — the FULL-SET shortcut, equivalent to --optional-services all.
        EXCLUDE_SERVICES still subtracts (e.g. --all-services with
        --exclude-services "games" bakes everything but games).
        NOTE: the INFRA-level slugs (egress-vpn, tor, workloadConsole, anubis) are
        NOT included by "all" — add them explicitly via OPTIONAL_SERVICES / brand.conf.

    Tor v3 onion (hidden) service — add the slug "tor" to OPTIONAL_SERVICES (or
        brand.conf) to bake the node-level Tor onion service: net-vpn/tor + a reconcile
        agent that exposes the in-cluster fe-gateway as a v3 .onion (INBOUND reach with
        no public IP / DDNS). The v3 onion keypair is minted + persisted OFF-GIT under
        /var/lib/tor/snapdragon-onion on first boot. DEFAULT-OFF; node-scoped (no effect
        on CLIENT roles). Exclude with --exclude-services tor.

    --with-edge-ai-tts / --no-edge-ai-tts
        Bake the edge-ai-tts voice-synthesis API (Piper TTS + an even-split viseme
        timeline for the VN voice feature, consumed by matrix-ui). CPU-only,
        self-contained — NO edge-ai dependency (unlike edge-ai-analysis), so it
        schedules with or without the GPU model server. Equivalent to adding
        'edge-ai-tts' to --optional-services. A SEPARATE container image
        (DEFAULT-OFF; keep off until it is built+pushed).

    --exclude-services "<slugs>"
        The SUBTRACTIVE build-time exclusion list: force-OFF these user-level slugs
        no matter how they were selected (default / brand.conf / --optional-services
        / --enable-games). Applied LAST. Each excluded slug's Application + manifests
        + gateway routes + route-access rows are pruned and its installed-services
        ConfigMap + 13a ApplicationSet flag is rendered "false" (graceful degrade).
        Example: --exclude-services "phpbb tuwunel". (env/brand.conf: EXCLUDE_SERVICES)

    --idp P
        Identity provider the baked services TRUST: casdoor (DEFAULT — the
        built-in IdP, zero change) | entra (Azure Entra ID) | aws (AWS Cognito) |
        oidc (any other OIDC provider). External mode bakes /etc/snapdragon/
        idp.conf, rewrites the baked tree's issuer/JWKS pins, gates the Casdoor
        apps out and drops README-IDP.md stating what does NOT work externally
        (native /bff/login, MFA stamping, roles/groups, signup-gate — see
        docs/IDENTITY-PROVIDERS.md). Fail-closed validation.

    --idp-issuer URL
        External OIDC issuer (https:// — REQUIRED unless --idp casdoor; must
        byte-match the token `iss` claim).

    --idp-client-id ID
        External OIDC client id (a PUBLIC identifier; REQUIRED unless --idp
        casdoor. Client SECRETS are never flags — they ride KEYS/Vault).

    --idp-jwks URL
        External JWKS override. Empty derives per provider: entra
        <issuer>/discovery/v2.0/keys, aws <issuer>/.well-known/jwks.json,
        oidc <issuer>/.well-known/jwks.

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
    --print-plan
        Resolve + validate all flags, print the build plan (PLAN_KEY=VALUE
        lines) and exit 0 — no root, no writes, no network. Invalid
        role/flag combinations exit non-zero.

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

    # Build for RPi 4 instead of RPi 5 (--board derives cpu/defconfig/dtb-prefix/
    # kernel-img all at once; any of -c/-d/--dtb-prefix/--kernel-img still overrides)
    ./build-rpi5-stage4.sh --board rpi4

    # RPi 4 desktop client, --standalone (LUKS2 FDE, no mesh) — reuses the SAME
    # Phase 3 desktop role + Phase 2b LUKS2 machinery Pi 5 already has
    ./build-rpi5-stage4.sh --board rpi4 --role desktop --standalone --local-user alice

    # RPi 3 desktop client (1GB RAM; DESKTOP-ONLY — --role anything else hard-errors)
    ./build-rpi5-stage4.sh --board rpi3 --role desktop --standalone --local-user alice

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
        -p "app-misc/tmux net-misc/chrony sys-fs/btrfs-progs dev-vcs/git"

EXIT STATUS
    0   Build completed successfully.
    1   Missing dependency, invalid option, or build failure.

FILES
    <work-dir>/                     finished products (shared with the x86 build)
        <brand>-<board>-arm64-<role>-<env>-<stamp>.img         Flashable raw image (default)
        <brand>-<board>-arm64-<role>-<env>-<stamp>.iso         Bootable ISO with installer (opt-in)
        <brand>-<board>-arm64-<role>-<env>-<stamp>.fs.tar.xz   Exact root filesystem tarball
        <brand>-<board>-arm64-<role>-<env>-<stamp>.stage4.tar.xz   Final stage4 tarball
        keys-<role>/                Per-role provisioning keys (build-all-roles)
        build.log                   Full build log
    <work-dir>/snap-build-pi5/      per-arch heavy build tree (--build-subdir; shared by
                                     ALL THREE boards — rpi5/rpi4/rpi3 are all aarch64)
        sysroot/                    Cross-compiled aarch64 root filesystem
        distfiles/                  Portage source archives
        pkgdir/                     Binary packages
        isoroot/                    ISO staging area
        log/  edb/                  emerge log + dep-metadata cache

    <board> is "rpi5" (DEFAULT), "rpi4" (--board rpi4), or "rpi3" (--board rpi3,
    desktop-only). Output artifacts are named (all share one UTC build stamp):
        <brand>-<board>-arm64-<role>-<env>-<UTC-stamp>.img            Flashable disk image (default)
        <brand>-<board>-arm64-<role>-<env>-<UTC-stamp>.stage4.tar.xz  Final stage4 tarball
        <brand>-<board>-arm64-<role>-<env>-<UTC-stamp>.fs.tar.xz      Mounted-tree filesystem tarball
        <brand>-<board>-arm64-<role>-<env>-<UTC-stamp>.iso           Bootable ISO with installer (--iso)
    e.g. snapdragon-rpi5-arm64-frontend-test-20260610T193045Z.img (--board rpi5, DEFAULT)
         snapdragon-rpi4-arm64-frontend-test-20260610T193045Z.img (--board rpi4)
         snapdragon-rpi3-arm64-desktop-test-20260610T193045Z.img  (--board rpi3, desktop-only)
    The <brand> prefix + <board>/<role>/<env> tokens keep the QEMU launchers and
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
        --board)              BOARD="$2";              shift 2 ;;
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
        --superdomain) SUPERDOMAIN="$2"; shift 2 ;;
        --release-state)      RELEASE_STATE="$2";      shift 2 ;;
        --brand)              BRAND="$2";              shift 2 ;;
        --brand-title)        BRAND_TITLE="$2";        shift 2 ;;
        --org)                ORG="$2";                shift 2 ;;
        --games-domain)       GAMES_DOMAIN="$2";       shift 2 ;;
        --optional-services)  OPTIONAL_SERVICES="$2";  shift 2 ;;
        --all-services)       OPTIONAL_SERVICES="all"; shift   ;;
        --exclude-services)   EXCLUDE_SERVICES="$2";   shift 2 ;;
        # Managed backing service (repeatable): --managed-service id=endpoint APPENDS
        # to MANAGED_SERVICES. Point one in-mesh datastore at a hosted cloud endpoint
        # (see specs/cluster/backing-services.yaml + docs/MANAGED-SERVICES.md).
        --managed-service)    MANAGED_SERVICES="${MANAGED_SERVICES:+${MANAGED_SERVICES} }$2"; shift 2 ;;
        -T|--timezone)        TIMEZONE="$2";           shift 2 ;;
        -u|--user)            DEFAULT_USER="$2";       shift 2 ;;
        --standalone)         STANDALONE=true;         shift   ;;
        --local-user)         LOCAL_USER="$2";          shift 2 ;;
        --local-pass|--local-user-password) LOCAL_USER_PASS="$2"; shift 2 ;;
        --encrypt-root)       ENCRYPT_ROOT=true;       shift   ;;
        --luks-pass|--root-unlock-pass) LUKS_PASS="$2"; shift 2 ;;
        # DEPRECATED no-ops: images no longer bake a fallback password (random
        # one-time password is minted at first boot; real creds come from KEYS).
        # Accepted-and-ignored so existing callers/CI do not break.
        --user-password)      warn "--user-password is ignored: no password is baked into the image (random first-boot fallback + KEYS provisioning)"; shift 2 ;;
        --root-password)      warn "--root-password is ignored: root is locked on keyless boot; set root via the KEYS USB users.json hash"; shift 2 ;;
        -p|--extra-packages)  EXTRA_PACKAGES="$2";     shift 2 ;;
        # User package deltas (validated + mandatory-floor-checked below); -p stays
        # the frozen legacy extra-packages spelling, --packages-add is the new one.
        --packages-add)       PACKAGES_ADD="$2";       shift 2 ;;
        --packages-drop)      PACKAGES_DROP="$2";      shift 2 ;;
        --headscale-version)  HEADSCALE_VERSION="$2";  shift 2 ;;
        --tailscale-version)  TAILSCALE_VERSION="$2";  shift 2 ;;
        --enable-wifi)        ENABLE_WIFI=true;        shift   ;;
        --enable-bluetooth)   ENABLE_BLUETOOTH=true;   shift   ;;
        --permit-root-login)  PERMIT_ROOT_LOGIN="$2";  shift 2 ;;
        --enable-games)       ENABLE_GAMES=true;       shift   ;;
        # Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate).
        # Folds 'character-studio' into OPTIONAL_SERVICES (idempotent).
        --with-character-studio) WANT_CHARACTER_STUDIO=true;  shift ;;
        --no-character-studio)   WANT_CHARACTER_STUDIO=false; shift ;;
        # edge-ai-tts (VN voice synthesis, B3) — OPTIONAL, DEFAULT-OFF. CPU-only,
        # self-contained (NO edge-ai dependency, unlike edge-ai-analysis). Folds
        # 'edge-ai-tts' into OPTIONAL_SERVICES (idempotent).
        --with-edge-ai-tts)   WANT_EDGE_AI_TTS=true;  shift ;;
        --no-edge-ai-tts)     WANT_EDGE_AI_TTS=false; shift ;;
        # Mesh-node identity provider (I6) — casdoor DEFAULT = zero change; external
        # providers validated fail-closed below (see _validate_idp).
        --idp)                IDP="$2";               shift 2 ;;
        --idp-issuer)         IDP_ISSUER="$2";        shift 2 ;;
        --idp-client-id)      IDP_CLIENT_ID="$2";     shift 2 ;;
        --idp-jwks)           IDP_JWKS="$2";          shift 2 ;;
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
        --print-plan)         PRINT_PLAN=true;         shift   ;;
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

# Comma tolerance: accept "akkoma,tuwunel" (the CSV spelling GUIs/configs tend to
# emit) as well as the native space-separated list — normalized HERE, right after
# arg parse, so every downstream word-split (`for s in ${OPTIONAL_SERVICES}`,
# `case " ${OPTIONAL_SERVICES} "`) sees clean slugs. Mirrors EXCLUDE_SERVICES.
OPTIONAL_SERVICES="${OPTIONAL_SERVICES//,/ }"

# FULL-SET sentinel: OPTIONAL_SERVICES=all (or --all-services, which sets the same
# token) expands to EVERY user-level slug. Done HERE — after arg parse, before the
# games opt-in fold and BEFORE EXCLUDE_SERVICES subtracts — so `all` is just a
# positive allow-list of the whole set and EXCLUDE_SERVICES still removes from it
# (e.g. OPTIONAL_SERVICES=all + EXCLUDE_SERVICES="games owncast" => everything but
# games/owncast). A bare `all` anywhere in the list expands the whole token to the
# full set (operators write `all`, not `all akkoma`).
case " ${OPTIONAL_SERVICES} " in
    *" all "*)
        OPTIONAL_SERVICES="${USER_LEVEL_SERVICES}"
        info "OPTIONAL_SERVICES: 'all' sentinel expanded to every user-level slug: ${OPTIONAL_SERVICES}"
        ;;
esac

# Games is OPT-IN (off by default): fold it into the selection when --enable-games
# / ENABLE_GAMES=true. Idempotent — a no-op when 'games' is already listed (e.g. via
# --optional-services). When games stays unselected, gate_optional_services() prunes
# the games apps + the games.<domain> subdomain extrahost from the baked tree.
if [ "${ENABLE_GAMES}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" games "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} games" ;;
    esac
fi

# Character Studio (VN) opt-in fold: --with-character-studio folds 'character-studio'
# into OPTIONAL_SERVICES (idempotent). DEFAULT-OFF; never auto-selected. When it stays
# unselected, gate_optional_services() prunes the slug's app/manifests/route/row.
if [ "${WANT_CHARACTER_STUDIO:-}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" character-studio "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} character-studio" ;;
    esac
fi

# edge-ai-tts (VN voice synthesis) opt-in fold: --with-edge-ai-tts folds
# 'edge-ai-tts' into OPTIONAL_SERVICES (idempotent). DEFAULT-OFF; never
# auto-selected. UNLIKE edge-ai-analysis it has NO edge-ai dependency (CPU-only,
# self-contained) — no dependency-drop guard needed. When it stays unselected,
# gate_optional_services() prunes the slug's app/manifests/route/row.
if [ "${WANT_EDGE_AI_TTS:-}" = "true" ]; then
    case " ${OPTIONAL_SERVICES} " in
        *" edge-ai-tts "*) ;;
        *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES} edge-ai-tts" ;;
    esac
fi

# EXCLUDE_SERVICES — apply the SUBTRACTIVE build-time exclusion LAST, so a slug
# listed here is force-OFF regardless of how it became selected (built-in default,
# brand.conf, --optional-services, or the games opt-in). gate_optional_services
# then prunes every excluded slug's Application/manifests/routes/rows from the
# baked tree and _opt_render_installed_services renders it installed:"false" in
# BOTH the ConfigMap and the 13a ApplicationSet, so the rest of the stack degrades
# gracefully. A slug may legitimately appear in EXCLUDE_SERVICES even if it was
# never selected (idempotent no-op). Whitespace/comma separated.
if [ -n "${EXCLUDE_SERVICES//[[:space:],]/}" ]; then
    _excl_x=""
    for _x in ${EXCLUDE_SERVICES//,/ }; do
        _kept=""
        for _s in ${OPTIONAL_SERVICES}; do
            [ "${_s}" = "${_x}" ] || _kept="${_kept} ${_s}"
        done
        OPTIONAL_SERVICES="${_kept# }"
        _excl_x="${_excl_x} ${_x}"
    done
    info "OPTIONAL_SERVICES: EXCLUDE_SERVICES removed:${_excl_x} (final selection: ${OPTIONAL_SERVICES:-none})"
    unset _excl_x _x _s _kept
fi

# Default work directory: ./out under CWD (local + gitignored)
if [ -z "${WORK_DIR}" ]; then
    WORK_DIR="$(pwd)/out"
fi

# ── select_board: map --board to its defconfig / DTB prefix / CPU / kernel-img ──
# Only fills values the operator did NOT set on the CLI (mirrors
# build-jetson-stage4.sh's select_board()), so an explicit -c/-d/--dtb-prefix/
# --kernel-img always wins regardless of --board. rpi5 is the DEFAULT, so a run
# with no --board flag at all resolves to EXACTLY the same RPI_CPU/RPI_DEFCONFIG/
# RPI_DTB_PREFIX/RPI_KERNEL_IMG this script hardcoded before this axis existed —
# every existing invocation stays 100% unaffected.
select_board() {
    local cpu defconfig dtb kimg desc
    case "${BOARD}" in
        rpi5)
            cpu="cortex-a76"; defconfig="bcm2712_defconfig"; dtb="bcm2712"; kimg="kernel_2712.img"
            desc="Raspberry Pi 5 (BCM2712, Cortex-A76)"
            ;;
        rpi4)
            cpu="cortex-a72"; defconfig="bcm2711_defconfig"; dtb="bcm2711"; kimg="kernel8.img"
            desc="Raspberry Pi 4 (BCM2711, Cortex-A72)"
            ;;
        rpi3)
            # kernel8.img: the same "any 64-bit-capable Pi" image name Pi 4 uses
            # (Pi 5 is the only board that needs its own kernel_2712.img) — Pi 3
            # (BCM2837) is 64-bit-CAPABLE (Cortex-A53), unlike the EOL'd/skipped
            # Pi 2, so this build stays arm64/aarch64 throughout, same cross
            # toolchain as rpi4/rpi5, no 32-bit ARMv7 branch.
            cpu="cortex-a53"; defconfig="bcmrpi3_defconfig"; dtb="bcm2837"; kimg="kernel8.img"
            desc="Raspberry Pi 3 (BCM2837, Cortex-A53, 1GB RAM) — DESKTOP-ONLY"
            ;;
        *) err "--board must be one of: rpi5 | rpi4 | rpi3 (got '${BOARD}')"; exit 1 ;;
    esac
    [ -z "${RPI_CPU}" ]        && RPI_CPU="${cpu}"
    [ -z "${RPI_DEFCONFIG}" ]  && RPI_DEFCONFIG="${defconfig}"
    [ -z "${RPI_DTB_PREFIX}" ] && RPI_DTB_PREFIX="${dtb}"
    [ -z "${RPI_KERNEL_IMG}" ] && RPI_KERNEL_IMG="${kimg}"
    BOARD_DESC="${desc}"
}
select_board

# Reconcile the legacy SKIP_ISO switch with the new BUILD_ISO design. The ISO is
# now opt-in: SKIP_ISO is simply the negation of BUILD_ISO so the existing
# prerequisite check (xorrisofs) and the Phase 5 gate keep working unchanged.
if ${BUILD_ISO}; then SKIP_ISO=false; else SKIP_ISO=true; fi

# Validate role and derive a default hostname from it
case "${ROLE}" in
    generic|pki|backend|frontend) ;;
    desktop) ROLE_CLIENT=true; DESKTOP="light" ;;
    *) echo "ERROR: --role must be one of: generic pki backend frontend desktop" >&2; exit 1 ;;
esac

# ── --board rpi3 is DESKTOP-ONLY (Phase 8) ─────────────────────────────────
# Every other --role (generic/pki/backend/frontend) is a k8s cluster node —
# containerd+kubelet+kubeadm+the hardened SELinux/audit stack on top of only
# 1GB of RAM is not a build this script will produce quietly. Hard-error here,
# BEFORE any prereq probe/mkdir/network fetch/sysroot write, so a Pi 3 k8s
# node can never be built and then fail mysteriously at runtime from OOM.
if [ "${BOARD}" = "rpi3" ] && ! ${ROLE_CLIENT}; then
    err "--board rpi3 only composes onto --role desktop (got --role ${ROLE}) — 1GB RAM is not enough headroom for this repo's hardened SELinux/containerd/kubelet k8s stack on a cluster-node role."
    echo "    Build --board rpi3 --role desktop, or pick --board rpi4/rpi5 for a cluster-node role." >&2
    exit 1
fi

# Client-desktop make.conf USE (appended LAST in make.conf.tmpl so it overrides
# the hardened headless -X/-gtk posture for --role desktop only; mirrors
# build-x86-host-stage4.sh's CLIENT_USE mechanism). k8s cluster-node roles
# leave both empty — headless nodes run no X server.
if ${ROLE_CLIENT}; then
    CLIENT_USE="X gtk dbus elogind udev"
    INPUT_DEVICES="libinput"   # Xorg keyboard/mouse/touchpad (via x11-base/xorg-drivers)
else
    CLIENT_USE=""
    INPUT_DEVICES=""
fi

if [ -z "${HOSTNAME}" ]; then
    case "${ROLE}" in
        # "gentoo-${BOARD}" -> "gentoo-rpi5" unchanged for the DEFAULT board.
        generic) HOSTNAME="gentoo-${BOARD}" ;;
        *)       HOSTNAME="${BRAND}-${ROLE}" ;;
    esac
fi

# ── STANDALONE posture (composable onto --role desktop only — every OTHER
# --role is a k8s cluster node, so this hard-errors on those) ──────────────
if ${STANDALONE}; then
    ${ROLE_CLIENT} || { err "--standalone only composes onto --role desktop (got --role ${ROLE})"; exit 1; }
    SKIP_MESH=true
    SKIP_TAILSCALE=true
    ENCRYPT_ROOT=true        # guarantee the installer artifact (the FDE path)
    [ -z "${LOCAL_USER}" ] && LOCAL_USER="${DEFAULT_USER}"
    info "STANDALONE desktop: no mesh; local user '${LOCAL_USER}'; LUKS2-encrypted root (installer ISO)"
fi

# --encrypt-root independent of --standalone: forces the installer ISO, since
# encryption happens at INSTALL time (specs-rpi5/installer/install.sh), not by
# writing the default .img directly. The plaintext .img (if also produced)
# remains a quick-flash, UNENCRYPTED option — --encrypt-root does not affect it.
if ${ENCRYPT_ROOT}; then
    if ! ${BUILD_ISO}; then
        warn "--encrypt-root forces the installer ISO on (encryption only happens via the installer path) — overriding --skip-iso/default."
    fi
    BUILD_ISO=true
    SKIP_ISO=false
    if ${BUILD_IMG}; then
        warn "--encrypt-root only encrypts the INSTALLER ISO's target — the default .img (if built) stays PLAINTEXT. Pass --no-img to build the ISO only."
    fi
fi

# ── Standalone local-user password → build-time hash (never baked in plaintext,
# mirrors build-x86-host-stage4.sh) ─────────────────────────────────────────
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
# These values come from CLI flags or a sourced brand.conf and flow into
# render_template's sed program (build of make.conf, cross-go.conf, config.txt,
# 01-firstboot.start) — and RPI_CPU/CROSS_TARGET land in make.conf, which portage
# SOURCES as shell on the (root) build host. Reject anything outside a strict
# charset at this earliest boundary so a value carrying sed/shell metacharacters,
# a quote, or a newline can never reach a render sink or a sourced KEY=VALUE file.
# Escaping at the render sink (_sed_rep_escape) is defense-in-depth on top of this.
# Each regex below ACCEPTS every legitimate default (brand=snapdragon,
# org=Snapdragon-Systems, domain=snapdragon.systems, user=pi, cpu=cortex-a76,
# target=aarch64-unknown-linux-gnu, kernel_2712.img, title "Snapdragon Systems").
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
# GCC -mcpu/-mtune value (finding #11): alnum + . _ + - (e.g. cortex-a76, native).
_RE_CPU='^[A-Za-z0-9._+-]+$'
# GNU target triplet (finding #11): alnum + _ . - (e.g. aarch64-unknown-linux-gnu).
_RE_TRIPLET='^[A-Za-z0-9_.-]+$'
# Kernel image filename: a single path-free filename component.
_RE_KIMG='^[A-Za-z0-9._-]+$'

_require_match "--brand"         "${BRAND}"          "${_RE_SLUG}"
_require_match "--org"           "${ORG}"            "${_RE_ORG}"
_require_match "--cluster-domain" "${CLUSTER_DOMAIN}" "${_RE_DNS}"
# Orchestration superdomain: DNS-validated like --cluster-domain, only when set.
[ -n "${SUPERDOMAIN}" ] && _require_match "--superdomain" "${SUPERDOMAIN}" "${_RE_DNS}"
_require_match "--games-domain"  "${GAMES_DOMAIN}"   "${_RE_DNS}"
_require_match "--hostname"      "${HOSTNAME}"       "${_RE_DNS}"
_require_match "--user"          "${DEFAULT_USER}"   "${_RE_USER}"
_require_match "--brand-title"   "${BRAND_TITLE}"    "${_RE_TITLE}"
_require_match "--cpu"           "${RPI_CPU}"        "${_RE_CPU}"
_require_match "--target"        "${CROSS_TARGET}"   "${_RE_TRIPLET}"
_require_match "--kernel-img"    "${RPI_KERNEL_IMG}" "${_RE_KIMG}"

# ── Mesh-node IdP (I6): fail-closed validation + per-provider JWKS derivation ──
# Mirrors build-x86-host-stage4.sh / studio core/config.validate_identity
# byte-for-byte: unknown provider dies; casdoor (the default) with ANY external
# field dies (byte-identity invariant); external without an https issuer + client
# id dies. Charset allowlists exclude everything shell/sed-meaningful — the values
# land in the root-baked idp.conf AND the replacement side of the issuer rewrite.
_IDP_URL_RE='^https://[A-Za-z0-9][A-Za-z0-9._:/%=+-]*$'
_IDP_CLIENT_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$'
_validate_idp() {
    case "${IDP}" in
        casdoor)
            [ -n "${IDP_ISSUER}" ]    && { err "--idp-issuer is set but --idp is 'casdoor' (the built-in default) — clear it or pick --idp entra|aws|oidc"; exit 1; }
            [ -n "${IDP_CLIENT_ID}" ] && { err "--idp-client-id is set but --idp is 'casdoor' (the built-in default) — clear it or pick --idp entra|aws|oidc"; exit 1; }
            [ -n "${IDP_JWKS}" ]      && { err "--idp-jwks is set but --idp is 'casdoor' (the built-in default) — clear it or pick --idp entra|aws|oidc"; exit 1; }
            ;;
        entra|aws|oidc)
            [[ "${IDP_ISSUER}" =~ ${_IDP_URL_RE} ]] \
                || { err "--idp ${IDP} requires an https:// --idp-issuer (got '${IDP_ISSUER}') — the issuer is the token-validation trust anchor and must be TLS"; exit 1; }
            [[ "${IDP_CLIENT_ID}" =~ ${_IDP_CLIENT_ID_RE} ]] \
                || { err "--idp ${IDP} requires --idp-client-id (allowlist [A-Za-z0-9._:/-], max 128; got '${IDP_CLIENT_ID}')"; exit 1; }
            if [ -n "${IDP_JWKS}" ]; then
                [[ "${IDP_JWKS}" =~ ${_IDP_URL_RE} ]] \
                    || { err "--idp-jwks must be an https:// URL (got '${IDP_JWKS}') — leave empty to derive the provider default"; exit 1; }
            fi
            ;;
        *)
            err "unknown --idp '${IDP}' (known: casdoor entra aws oidc)"
            exit 1
            ;;
    esac
    # Explicit success: the casdoor arm's last `[ -n … ]` legitimately evaluates
    # false, and under `set -e` a rc=1 falling out of the function would abort the
    # whole build for the DEFAULT provider.
    return 0
}
_idp_default_jwks() {
    # The documented per-provider JWKS derivation off the issuer (used when
    # --idp-jwks is empty): entra publishes at /discovery/v2.0/keys, Cognito at
    # /.well-known/jwks.json; a generic OIDC provider gets the Casdoor-shaped
    # /.well-known/jwks the baked tree already pins (override if yours differs).
    case "${IDP}" in
        entra) printf '%s/discovery/v2.0/keys' "${IDP_ISSUER%/}" ;;
        aws)   printf '%s/.well-known/jwks.json' "${IDP_ISSUER%/}" ;;
        oidc)  printf '%s/.well-known/jwks' "${IDP_ISSUER%/}" ;;
        *)     printf '' ;;
    esac
}
_validate_idp
if [ "${IDP}" != "casdoor" ] && [ -z "${IDP_JWKS}" ]; then
    IDP_JWKS="$(_idp_default_jwks)"
    info "IdP: --idp-jwks empty — derived the ${IDP} default: ${IDP_JWKS}"
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

# ── Validate the release-state posture (baked into the image) ─────────────
case "${RELEASE_STATE}" in
    internal|public) ;;
    *) err "--release-state must be one of: internal | public  (got '${RELEASE_STATE}')"; exit 1 ;;
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
# Per-image log (fix D, session 20260716-160638-f8c153): the session-shared
# build.log above is tee -a APPENDED by every builder of a multi-image
# worklist, and a builder that dies before its redirect leaves nothing at all
# — 8 of that session's 9 images left no usable on-disk log. Each run ALSO
# tees to its own per-image file, derived from the EXISTING --build-subdir
# argv (Studio worklist runs pass wl-<entry-id> -> /out/build-<entry-id>.log;
# standalone CLI runs get build-snap-build-<board>.log). No new flags, no
# argv change; uniqueness is the worklist's own entry-id collision invariant.
IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log"

# Single, sortable UTC build stamp shared by EVERY artifact of this run, so the
# .img / .iso / stage4 / fs tarball all carry the same identifier. Computed once
# here at build start. Artifacts are named:
#   ${BRAND}-${BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}.<ext>
# (${BOARD} is "rpi5" [DEFAULT], "rpi4", or "rpi3" [desktop-only] — the
#  ${BRAND}- prefix + role token keep the QEMU launchers' and flash-disk.sh's
#  generic 'snapdragon-*-<role>-*' autodetect glob matching regardless of
#  board; only launch-pi.sh's FIRST-preference rpi5-specific glob is
#  board-specific, and it falls through to that same generic pattern for a
#  --board rpi4/rpi3 artifact.)
BUILD_TS="$(date -u +%Y%m%dT%H%M%SZ)"
info "Build stamp: ${BUILD_TS} (UTC; brand=${BRAND}, env=${ENV})"

# Escape a value so it is safe to place on the REPLACEMENT (right-hand) side of a
# sed `s|LHS|RHS|` command that uses `|` as the delimiter. Without this a value
# containing the delimiter `|`, the match-reference metachar `&`, a backslash, or a
# newline can terminate the s-command, append an extra sed command, or inject a new
# line into the rendered artifact (config.txt/make.conf/01-firstboot.start, which
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

# Copies a file, replacing @@VAR@@ markers with shell variable values.
# Usage: render_template <src> <dst>
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
        -e "s|@@RPI_KERNEL_IMG@@|$(_sed_rep_escape "${RPI_KERNEL_IMG}")|g" \
        -e "s|@@PCIE_LINE@@|$(_sed_rep_escape "${PCIE_LINE}")|g" \
        -e "s|@@VC4_OVERLAY_LINE@@|$(_sed_rep_escape "${VC4_OVERLAY_LINE}")|g" \
        -e "s|@@INITRAMFS_LINE@@|$(_sed_rep_escape "${INITRAMFS_LINE}")|g" \
        -e "s|@@BOARD_DESC@@|$(_sed_rep_escape "${BOARD_DESC}")|g" \
        -e "s|@@CONSOLE_UART@@|$(_sed_rep_escape "${CONSOLE_UART}")|g" \
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
        -e "s|@@CLIENT_USE@@|$(_sed_rep_escape "${CLIENT_USE}")|g" \
        -e "s|@@INPUT_DEVICES@@|$(_sed_rep_escape "${INPUT_DEVICES}")|g" \
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
    # edge-ai-analysis dependsOn edge-ai: drop it if the model server is not selected
    # (its prune case then runs) — never ship the wrapper with no upstream.
    case " ${OPTIONAL_SERVICES} " in
        *" edge-ai-analysis "*)
            case " ${OPTIONAL_SERVICES} " in
                *" edge-ai "*) ;;
                *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES//edge-ai-analysis/}"
                   warn "edge-ai-analysis requires edge-ai — dropping it (no model server selected)" ;;
            esac ;;
    esac
    for slug in akkoma tuwunel phpbb games owncast tube character-studio headwind attestation-server egress-vpn tor workloadConsole edge-ai edge-ai-analysis edge-ai-tts; do
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
                # ── GAMES APP-STORE (games-services control plane) — degrade with games ──
                # The app-store rides the games slug (it needs the games namespace up), so
                # deselecting games prunes the WHOLE control plane: the 13c instances
                # ApplicationSet + the games-instances namespace/isolation manifests, the two
                # intersection-sync Jobs (+ their casdoor/kustomization lines), the be-gateway
                # HTTP-console route, and the games-services route-access rows (be + fe).
                rm -f "${apps}/13c-games-instances.yaml"
                rm -rf "${tree}/manifests/games-instances"
                rm -f "${tree}/manifests/casdoor/games-services-admin-sync-job.yaml" \
                      "${tree}/manifests/casdoor/games-services-runner-sync-job.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" games-services-admin-sync-job.yaml
                _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" games-services-runner-sync-job.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" games-servers-console
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/bff/superadmin/games-services/**' '/bff/games-services/instances/**' \
                    '/bff/games-services/catalog/**' '/games/servers/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/admin/games-services/**'
                ;;
            owncast)
                # Owncast live-streaming — GPU-gated x86 service (DEFAULT-OFF). Owns its
                # bootstrap Application + manifests dir + its fe-gateway BFF route-access
                # rows (no gateway HOST route + no per-service ESO today). When deselected
                # the user/admin live-stream panels grey out (installed-services "false").
                rm -f "${apps}/52-owncast.yaml"
                rm -rf "${tree}/manifests/owncast"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" snapdragon-owncast-bff-api
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/bff/owncast/admin/**' '/bff/owncast/**'
                ;;
            character-studio)
                # Character Studio (VN) — FRONTEND micro-frontend remote (DEFAULT-OFF, admin
                # gate). Owns its bootstrap Application + manifests dir + its ONE fe-gateway
                # path route (character-studio-ui) + its ONE route-access row (no gateway
                # HOST + no per-service ESO + no BFF in this slug). When deselected the host
                # greys the /character-studio entry out (installed-services "false").
                rm -f "${apps}/49b-character-studio-ui.yaml"
                rm -rf "${tree}/manifests/character-studio"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" character-studio-ui
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/character-studio/**'
                ;;
            tube)
                # LocalTube (YouTube archive) — GPU-gated x86 service (DEFAULT-OFF). Owns
                # its bootstrap Application + manifests dir + its per-service ESO file
                # (tube-externalsecrets.yaml; standalone, not in the ESO kustomization) +
                # its fe/be route-access rows. When deselected the tube panel greys out.
                rm -f "${apps}/53-tube.yaml"
                rm -rf "${tree}/manifests/tube"
                rm -f "${tree}/manifests/external-secrets/tube-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tube-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-fe.yaml" snapdragon-tube-bff-api tube-content
                _opt_drop_route "${apps}/20-gateway-be.yaml" tube-content
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-fe-gateway \
                    '/bff/tube/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/tube/content/**'
                ;;
            egress-vpn)
                # NODE service (not a cluster Application). Prune the per-service
                # NetworkPolicy interaction (file + kustomization line) so no
                # vpn-egress label is ever honoured; the node-package prune + the
                # reconcile service-link SKIP are handled OUTSIDE this loop
                # (filter_node_packages / link_node_services) since they touch the
                # rootfs, not the GitOps tree.
                rm -f "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" egress-vpn-interaction.yaml
                ;;
            tor)
                # NODE service (DISTRO tor daemon + a reconcile agent), not a cluster
                # Application. Prune the per-service NetworkPolicy interaction (file +
                # kustomization line) so no tor-onion label is ever honoured; the
                # net-vpn/tor package omission + the service-link SKIP are handled OUTSIDE
                # this loop (they touch the rootfs, not the GitOps tree).
                rm -f "${tree}/manifests/networkpolicy/tor-onion-marked.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" tor-onion-marked.yaml
                ;;
            workloadConsole)
                # The WORKLOAD CONSOLE is RBAC + route-access ONLY (the BFF endpoints live in
                # the always-present admin-bff). Deselecting it prunes the two-SA RBAC
                # Application + its manifests (so the SA tokens are never minted) AND the two
                # route-access rows, so the gateway 404s the whole /bff/{admin,superadmin}/
                # workloads/** prefix. The admin-bff ALSO ships dark independently
                # (app.workload-console.enabled=false), so even an un-pruned tree is inert.
                rm -f "${apps}/14-workload-console-rbac.yaml"
                rm -rf "${tree}/manifests/workload-console-rbac"
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
                ;;
            headwind)
                # Headwind MDM (managed phones) — DEFAULT-OFF, admin-only devops
                # service (Harbor/superadmin posture). Owns its bootstrap Application +
                # manifests dir + per-service ESO file + TWO routes on the EXISTING
                # tailnet superadmin-gateway (NOT be/fe — no gatewayHost of its own)
                # + their route-access rows. When deselected the superadmin console's
                # Headwind entry greys out (installed-services "false").
                rm -f "${apps}/23-headwind.yaml"
                rm -rf "${tree}/manifests/headwind"
                rm -f "${tree}/manifests/external-secrets/headwind-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" headwind-externalsecrets.yaml
                _opt_drop_route "${apps}/22-gateway-superadmin.yaml" headwind-console headwind-checkin
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-superadmin-gateway \
                    '/hmdm/manage/**' '/hmdm/rest/**'
                ;;
            attestation-server)
                # AttestationServer (GrapheneOS Hardware Trust Root) — DEFAULT-OFF,
                # admin-only devops service (Harbor/superadmin posture). Owns its
                # bootstrap Application + manifests dir + per-service ESO file +
                # THREE routes on the EXISTING tailnet superadmin-gateway (NOT be/fe
                # — no gatewayHost of its own) + their route-access rows. When
                # deselected the superadmin console's AttestationServer entry greys
                # out (installed-services "false").
                rm -f "${apps}/24-attestation-server.yaml"
                rm -rf "${tree}/manifests/attestation-server"
                rm -f "${tree}/manifests/external-secrets/attestation-server-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" attestation-server-externalsecrets.yaml
                _opt_drop_route "${apps}/22-gateway-superadmin.yaml" attestation-auditor attestation-status attestation-console
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-superadmin-gateway \
                    '/attest/auditor/**' '/attest/api/status' '/attest/api/create-account' '/attest/api/**'
                ;;
            edge-ai)
                # Edge-AI GPU inference service (DEFAULT-OFF, GPU-gated). Owns its
                # bootstrap Application + manifests dir + the ai.<domain> be-gateway
                # host route + its /v1/** route-access row. When deselected the AI
                # panels grey out (installed-services "false"). The nvidia-device-plugin
                # (apps/01d) is NOT optional and is never pruned (harmless w/o GPU nodes).
                rm -f "${apps}/54-edge-ai.yaml"
                rm -rf "${tree}/manifests/edge-ai"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/v1/**'
                ;;
            edge-ai-analysis)
                # Task analysis API in front of edge-ai (DEFAULT-OFF, dependsOn edge-ai).
                # Owns app 55 + manifests/edge-ai-analysis + the /v1/analyze/** route +
                # route-access row. Image is a separate build artifact.
                rm -f "${apps}/55-edge-ai-analysis.yaml"
                rm -rf "${tree}/manifests/edge-ai-analysis"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-analysis
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/v1/analyze/**'
                ;;
            edge-ai-tts)
                # Piper TTS + viseme timeline (VN voice, B3) — DEFAULT-OFF, NO
                # dependsOn (CPU-only, self-contained; unlike edge-ai-analysis it
                # schedules with or without edge-ai). Owns app 55b +
                # manifests/edge-ai-tts + the /v1/synthesize/** route + route-access
                # row. Image is a separate build artifact.
                rm -f "${apps}/55b-edge-ai-tts.yaml"
                rm -rf "${tree}/manifests/edge-ai-tts"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-tts
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
                    '/v1/synthesize/**'
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
    # Seed each per-slug OptionalService CR's `enabled` from the SAME selection so the
    # (dark-by-default) admin-bff OptionalServiceReconciler's desired-state baseline
    # matches this build (a USB built WITHOUT a slug ships its CR enabled:false).
    _opt_render_optionalservice_cr
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
                    # Stop skipping once we reach ANY non-blank line at or below the
                    # captured item indent — including a comment, since a trailing
                    # comment block at this indent may document the NEXT surviving
                    # route rather than the one being removed (excluding comments
                    # from this check would silently swallow that documentation).
                    if (line !~ /^ *$/ && cur<=ind) { skip=0 }
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
# An operator can EXPLICITLY DESELECT a slug by listing a negative token in
# OPTIONAL_SERVICES / --optional-services: either "-<slug>" or "no-<slug>". This
# is what lets a PROD build turn OFF an otherwise on-by-default service (anubis):
# absence alone cannot mean "off" in prod, since the default list never names
# anubis. The negative token always loses to nothing (it ONLY suppresses an
# implicit default); an explicit positive "<slug>" still wins (handled by the
# caller checking _opt_selected first).
_opt_explicitly_deselected() {
    local s
    for s in ${OPTIONAL_SERVICES}; do
        [ "${s}" = "-$1" ] && return 0
        [ "${s}" = "no-$1" ] && return 0
    done
    return 1
}
# ENV-aware install decision for anubis (the public PoW shield):
#   * explicit positive selection ("anubis" in the list)  => ON  (operator wins)
#   * explicit deselection ("-anubis"/"no-anubis")          => OFF (operator wins)
#   * otherwise: ENV=prod => ON  (all shields up by default in prod)
#               ENV=test => OFF (PoW interstitial off for local/test builds)
# Mirrors the gate_env_apps ENV=prod vs ENV=test split. Echoes "true"/"false".
_opt_anubis_installed() {
    if _opt_selected anubis; then echo "true"; return 0; fi
    if _opt_explicitly_deselected anubis; then echo "false"; return 0; fi
    if [ "${ENV}" = "prod" ]; then echo "true"; else echo "false"; fi
}
# Mirror a slug's install-state into its optional-services ApplicationSet element
# (apps/13a-optional-services.yaml). This COMPLETES the cut-over: the runtime
# `selector` keeps only installed=="true" elements, so rendering the flag from the
# build-time selection makes the 13a generator agree with both the pruned bootstrap
# apps/ tree AND the installed-services ConfigMap — a deselected slug is therefore
# absent from EVERY path (bootstrap seed pruned + 13a element dropped by the
# selector), so a repo-synced ArgoCD can never re-force a deselected service on.
# Idempotent: rewrites only the `installed: "..."` field of the matching `slug:` element.
_opt_render_appset_flag() {
    local slug="$1" val="$2"
    local appset="${SYSROOT}/var/lib/snapdragon/cluster/apps/13a-optional-services.yaml"
    [ -f "${appset}" ] || return 0
    # Match a list element line `- { slug: <slug>, ..., installed: "true|false" }`
    # and rewrite ONLY its installed value (the slug token is the line anchor).
    sed -i -E "s#(\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\")(true|false)(\")#\\1${val}\\3#" "${appset}"
}
_opt_render_installed_services() {
    local cm="${SYSROOT}/var/lib/snapdragon/cluster/manifests/policy/installed-services-configmap.yaml"
    [ -f "${cm}" ] || return 0
    local slug val
    # The base optional services follow plain presence in OPTIONAL_SERVICES.
    for slug in akkoma tuwunel phpbb games owncast tube character-studio headwind attestation-server workloadConsole edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        sed -i -E "s#^([[:space:]]*)${slug}:[[:space:]]*\"(true|false)\"#\\1${slug}: \"${val}\"#" "${cm}"
        # Mirror the same flag into the optional-services ApplicationSet element so the
        # runtime selector (installed=="true") agrees with the build-time selection: a
        # deselected slug is dropped from BOTH the bootstrap apps/ tree (pruned above)
        # AND the 13a generator list, so a repo-synced ArgoCD never re-forces it on.
        _opt_render_appset_flag "${slug}" "${val}"
    done
    # anubis is ENV-CONDITIONAL (NOT plain presence): the PUBLIC PoW shield is ON
    # by default in PROD ("all shields up") and OFF by default in TEST, unless the
    # operator explicitly selects/deselects it. The optional-services.yaml baseline
    # stays default:off (safe for test); PROD flips it on here.
    val="$(_opt_anubis_installed)"
    sed -i -E "s#^([[:space:]]*)anubis:[[:space:]]*\"(true|false)\"#\\1anubis: \"${val}\"#" "${cm}"
    _opt_render_appset_flag anubis "${val}"
    # Wire/unwire the PUBLIC ingress PoW reroute to match the install decision so
    # the shield is genuinely in-path when installed (idempotent + reversible).
    _opt_wire_anubis_ingress "${val}"
    info "OPTIONAL_SERVICES: rendered installed-services ConfigMap (selected: ${OPTIONAL_SERVICES:-none}; ENV=${ENV}; anubis=${val})"
}
# Flip the `enabled:` value of ONE OptionalService CR (the block whose `slug: <slug>`)
# in the baked seed file. awk anchors on the slug line then rewrites the FIRST enabled
# line after it, preserving indentation (sub only touches the matched substring). The
# end-anchored slug compare keeps edge-ai distinct from edge-ai-analysis/edge-ai-tts.
_opt_set_cr_enabled() {
    local f="$1" slug="$2" val="$3"
    [ -f "${f}" ] || return 0
    awk -v slug="${slug}" -v val="${val}" '
        /^[[:space:]]*slug:[[:space:]]/ {
            s=$0; sub(/^[[:space:]]*slug:[[:space:]]*/,"",s); sub(/[[:space:]]*$/,"",s)
            arm=(s==slug)
        }
        arm && /^[[:space:]]*enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
            sub(/enabled:[[:space:]]*(true|false)/, "enabled: " val); arm=0
        }
        { print }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Seed the per-slug OptionalService CRs (manifests/optional-services-operator/
# seed-optionalservices.yaml) from the resolved OPTIONAL_SERVICES selection, mirroring
# _opt_render_installed_services above (the CR is the runtime desired-state twin of the
# installed-services ConfigMap boolean). anubis follows the SAME ENV-conditional
# _opt_anubis_installed decision used for the ConfigMap; coturn stays at its false
# baseline (not in the selection loop, matching the ConfigMap).
_opt_render_optionalservice_cr() {
    local seed="${SYSROOT}/var/lib/snapdragon/cluster/manifests/optional-services-operator/seed-optionalservices.yaml"
    [ -f "${seed}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games owncast tube character-studio edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        _opt_set_cr_enabled "${seed}" "${slug}" "${val}"
    done
    val="$(_opt_anubis_installed)"
    _opt_set_cr_enabled "${seed}" anubis "${val}"
    info "OPTIONAL_SERVICES: seeded OptionalService CR enabled flags (selected: ${OPTIONAL_SERVICES:-none}; anubis=${val})"
}

# ============================================================================
# MANAGED BACKING SERVICES — gate_backing_services() + helpers. See
# specs/cluster/backing-services.yaml (the DECLARED contract; this is its
# executable twin — keep the case arms in sync). Applied AFTER
# gate_optional_services(). SELF-HOSTED IS THE DEFAULT: an EMPTY MANAGED_SERVICES
# selection returns immediately and the baked tree is byte-identical mainline
# (the #1 invariant). Managed mode, per selected id: prune the in-mesh workload
# app+manifests, repoint the consumer endpoint env value(s) at the operator-
# supplied endpoint, keep the ESO Secret names/Vault paths (creds ride the KEYS
# USB via gen-cluster-secrets, never argv/git). Fail-closed: unknown id / tier-3
# (docs-only) id / malformed endpoint => FATAL.
# ============================================================================
# Tier 1-2 ids (managed IS implemented). Tier 3 ids are mode-locked self-hosted.
_MGD_TIER12_IDS="velero-objectstore smtp kafka clickhouse federation-bundles postgres-admin-bff postgres-user-bff postgres-mod-bff postgres-forum-bff postgres-wiki-bff postgres-casdoor"
_MGD_TIER3_IDS="cassandra harbor vault-kv vault-pki"
_mgd_die() { echo "FATAL(managed-services): $1" >&2; exit 1; }
# The tier-3 blocker one-liner (WHY --managed-service <id> is refused in v1).
_mgd_tier3_blocker() {
    case "$1" in
        cassandra) echo "auth/TLS live only in the dark cassandra-hardening overlay; Keyspaces/Cosmos need TLS+SigV4 on 9142 with no live-path driver wiring";;
        harbor)    echo "registry host literal in ~30 kustomizations + dockerconfigjson + kaniko; robot-account Job has no ECR/ACR analog; 12h ECR tokens break static pull secrets; loses air-gap";;
        vault-kv)  echo "mechanical but broad: 1 ClusterSecretStore + ~90 remoteRef renames + writer re-point + drop vault-token seeding for IRSA — deferred wave";;
        vault-pki) echo "hardest: VaultDynamicSecret is Vault-only; needs a cert-manager re-architecture keeping <app>-mtls names; USB CA-custody has no managed analog";;
        *)         echo "tier-3 managed swap not implemented in v1";;
    esac
}
# Endpoint (RHS of id=endpoint) for a selected id; exit 1 if not selected.
_mgd_endpoint() {
    local want="$1" tok id
    for tok in ${MANAGED_SERVICES}; do
        id="${tok%%=*}"
        [ "${id}" = "${want}" ] && { printf '%s' "${tok#*=}"; return 0; }
    done
    return 1
}
_mgd_selected()  { _mgd_endpoint "$1" >/dev/null 2>&1; }
_mgd_is_tier12() { case " ${_MGD_TIER12_IDS} " in *" $1 "*) return 0;; esac; return 1; }
_mgd_is_tier3()  { case " ${_MGD_TIER3_IDS} "  in *" $1 "*) return 0;; esac; return 1; }
# Fail-closed validation of the whole MANAGED_SERVICES selection.
validate_managed_services() {
    local tok id ep
    for tok in ${MANAGED_SERVICES}; do
        case "${tok}" in *=*) : ;; *) _mgd_die "'${tok}' is malformed — expected id=endpoint";; esac
        id="${tok%%=*}"; ep="${tok#*=}"
        [ -n "${id}" ] || _mgd_die "empty id in token '${tok}'"
        # Endpoint shape: non-empty and must carry a host (not a bare `:port`). Note
        # whitespace can't reach here — word-splitting already tokenises on it.
        [ -n "${ep}" ] || _mgd_die "'${id}' has an empty endpoint (id=endpoint required)"
        case "${ep}" in :*) _mgd_die "'${id}' endpoint '${ep}' has no host (bare :port)";; esac
        if _mgd_is_tier3 "${id}"; then
            _mgd_die "'${id}' is TIER-3 (mode-locked self-hosted, docs-only in v1) — $(_mgd_tier3_blocker "${id}"). See docs/MANAGED-SERVICES.md."
        fi
        _mgd_is_tier12 "${id}" || _mgd_die "unknown backing-service id '${id}'. Known tier-1/2: ${_MGD_TIER12_IDS}. Tier-3 (docs-only): ${_MGD_TIER3_IDS}."
    done
}
# Rewrite the `value: "…"` line immediately following `- name: <ENV>` in a k8s
# container env list (exact-name anchored so SPRING_R2DBC_URL != _USERNAME; FIRST
# occurrence only; a valueFrom block is left untouched).
_mgd_rewrite_env() {
    local f="$1" env="$2" val="$3"
    [ -f "${f}" ] || return 0
    awk -v env="${env}" -v val="${val}" '
        BEGIN{done=0}
        {
            if (!done && $0 ~ ("^[[:space:]]*- name: " env "[[:space:]]*$")) {
                print
                if ((getline nl) > 0) {
                    if (nl ~ /^[[:space:]]*value:[[:space:]]*/) {
                        match(nl, /^[[:space:]]*/); ind=substr(nl,1,RLENGTH)
                        print ind "value: \"" val "\""; done=1; next
                    } else { print nl; next }
                }
                next
            }
            print
        }' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Per-service Postgres: repoint BOTH URLs (R2DBC + Liquibase), delete the DB app +
# manifests. Guarded on the consumer file existing (phpbb may have pruned it first).
_mgd_pg() {  # tree endpoint dbname consumer_manifest db_app db_manifest
    local tree="$1" ep="$2" db="$3" cons="$4" dbapp="$5" dbman="$6"
    _mgd_rewrite_env "${tree}/${cons}" SPRING_R2DBC_URL    "r2dbc:postgresql://${ep}/${db}"
    _mgd_rewrite_env "${tree}/${cons}" SPRING_LIQUIBASE_URL "jdbc:postgresql://${ep}/${db}"
    rm -f  "${tree}/${dbapp}"
    rm -rf "${tree}/${dbman}"
}
# Casdoor PG: NO app prune (05-casdoor IS the IdP). Flip host+port+sslmode inside
# the single libpq dataSourceName string (dbname=casdoor kept), drop the bundled
# pg.yaml manifest + its kustomization line. Managed PG enforces TLS -> require.
_mgd_pg_casdoor() {  # tree endpoint(host[:port])
    local tree="$1" ep="$2" h p
    h="${ep%%:*}"; p="5432"; case "${ep}" in *:*) p="${ep##*:}";; esac
    local cm="${tree}/manifests/casdoor/app-conf-configmap.yaml"
    [ -f "${cm}" ] && sed -i -E "s#host=[^ ]+ port=[0-9]+#host=${h} port=${p}#; s#sslmode=[a-z-]+#sslmode=require#" "${cm}"
    rm -f "${tree}/manifests/casdoor/pg.yaml"
    _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" pg.yaml
}
# Velero BSL: rewrite bucket/region/s3Url in the FIRST YAML doc only (the VSL doc
# after '---' has its own region). endpoint=aws => real S3 (drop s3Url); else the
# S3-compatible URL. bucket/region from MANAGED_VELERO_{BUCKET,REGION} env.
_mgd_velero() {  # tree endpoint(aws|url)
    local tree="$1" ep="$2"
    local bsl="${tree}/manifests/velero/backupstoragelocation.yaml"
    [ -f "${bsl}" ] || return 0
    local bucket="${MANAGED_VELERO_BUCKET:-snapdragon-backups}"
    local region="${MANAGED_VELERO_REGION:-us-east-1}"
    local s3url="${ep}"; [ "${ep}" = "aws" ] && s3url=""
    awk -v bucket="${bucket}" -v region="${region}" -v s3url="${s3url}" '
        BEGIN{doc=0}
        /^---/ { doc++ }
        {
            if (doc==0) {
                if ($0 ~ /^[[:space:]]*bucket:[[:space:]]/) { match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH) "bucket: " bucket; next }
                if ($0 ~ /^[[:space:]]*region:[[:space:]]/) { match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH) "region: " region; next }
                if ($0 ~ /^[[:space:]]*s3Url:[[:space:]]/)  {
                    if (s3url=="") next
                    match($0,/^[[:space:]]*/); print substr($0,1,RLENGTH) "s3Url: " s3url; next
                }
            }
            print
        }' "${bsl}" > "${bsl}.tmp" && mv "${bsl}.tmp" "${bsl}"
}
# Federation bundles: flip APP_BUNDLES_STORAGE=s3 + inject APP_BUNDLES_S3_* env
# after APP_BUNDLES_DIR (idempotent). endpoint = bucket | bucket@https://endpoint.
# Creds ride the AWS default chain (IRSA/env) — no static-key Secret.
_mgd_fed_bundles() {  # tree endpoint
    local tree="$1" ep="$2"
    local dep="${tree}/manifests/federation-api/deployment.yaml"
    [ -f "${dep}" ] || return 0
    local bucket="${ep%%@*}" endpoint=""
    case "${ep}" in *@*) endpoint="${ep#*@}";; esac
    local region="${MANAGED_FEDERATION_BUNDLES_REGION:-us-east-1}"
    _mgd_rewrite_env "${dep}" APP_BUNDLES_STORAGE "s3"
    grep -q 'APP_BUNDLES_S3_BUCKET' "${dep}" && return 0
    awk -v bkt="${bucket}" -v ep="${endpoint}" -v rgn="${region}" '
        { print }
        /^[[:space:]]*- name: APP_BUNDLES_DIR[[:space:]]*$/ { match($0,/^[[:space:]]*/); nind=substr($0,1,RLENGTH); pend=1; next }
        pend==1 && /^[[:space:]]*value:/ {
            print nind "- name: APP_BUNDLES_S3_BUCKET";   print nind "  value: \"" bkt "\""
            print nind "- name: APP_BUNDLES_S3_ENDPOINT"; print nind "  value: \"" ep "\""
            print nind "- name: APP_BUNDLES_S3_REGION";   print nind "  value: \"" rgn "\""
            pend=0
        }' "${dep}" > "${dep}.tmp" && mv "${dep}.tmp" "${dep}"
}
# Bake /etc/snapdragon/backing-services.conf (id=endpoint list; NO creds) +
# README-MANAGED.md (the standing honesty notes) into the baked tree.
_mgd_bake_readme() {  # tree
    local tree="$1"; local rd="${tree}/README-MANAGED.md"
    { echo "# Managed backing services (this image)"; echo
      echo "This image points one or more in-mesh backing services at a hosted cloud"
      echo "endpoint. Self-hosted is the platform default; only the ids listed in"
      echo "\`/etc/snapdragon/backing-services.conf\` were repointed. Full runbooks:"
      echo "docs/MANAGED-SERVICES.md."; echo
      echo "## Selected"; echo
      local id ep
      for id in ${_MGD_TIER12_IDS}; do _mgd_selected "${id}" || continue; ep="$(_mgd_endpoint "${id}")"; echo "- \`${id}\` -> \`${ep}\`"; done
      echo
      echo "## Honesty notes (READ before relying on this image)"; echo
      echo "- **TLS delta:** in-mesh Postgres/ClickHouse run plaintext. Managed RDS /"
      echo "  Azure-PG / ClickHouse-Cloud enforce TLS — add \`?ssl=true&sslMode=require\`"
      echo "  to the URLs and the managed CA to each app's truststore OUT OF BAND. The"
      echo "  build repoints the HOST only; it does not invent TLS params (except the"
      echo "  Casdoor DSN sslmode, flipped to \`require\`)."
      echo "- **Role-split SQL:** each DB's \`initdb/10-roles.sh\` (owner + least-priv app"
      echo "  role) runs via docker-entrypoint-initdb.d and NEVER runs on RDS. Run that"
      echo "  role-split SQL against the managed DB by hand."
      echo "- **Citus:** federation-db + route-access-db need Citus (initdb/90-citus.sh)"
      echo "  which vanilla RDS lacks — they are NOT managed ids in v1 (Azure Cosmos DB"
      echo "  for PostgreSQL does have Citus)."
      echo "- **Creds:** operator-supplied only, delivered via ESO/Vault on the KEYS USB"
      echo "  (gen-cluster-secrets managed block). Never minted, never in this image."
    } > "${rd}"
}
gate_backing_services() {
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    local apps="${tree}/apps"
    [ -d "${apps}" ] || return 0
    # #1 INVARIANT: empty selection => zero change. Tokens are WHITESPACE-separated
    # (all whitespace: space/tab/newline) — commas are LITERAL (a kafka endpoint is itself a comma-list of brokers).
    [ -z "${MANAGED_SERVICES//[[:space:]]/}" ] && return 0
    validate_managed_services
    local id ep churl hostport
    for id in ${_MGD_TIER12_IDS}; do
        _mgd_selected "${id}" || continue
        ep="$(_mgd_endpoint "${id}")"
        info "MANAGED_SERVICES: '${id}' -> '${ep}' — pruning in-mesh workload + repointing consumers"
        case "${id}" in
            postgres-admin-bff) _mgd_pg "${tree}" "${ep}" adminbff manifests/admin-bff-api/deployment.yaml apps/30-admin-bff-db.yaml manifests/admin-bff-db ;;
            postgres-user-bff)  _mgd_pg "${tree}" "${ep}" userbff  manifests/user-bff-api/deployment.yaml  apps/34-user-bff-db.yaml  manifests/user-bff-db ;;
            postgres-mod-bff)   _mgd_pg "${tree}" "${ep}" modbff   manifests/mod-bff-api/deployment.yaml   apps/32-mod-bff-db.yaml   manifests/mod-bff-db ;;
            postgres-forum-bff) _mgd_pg "${tree}" "${ep}" forumbff manifests/forum-bff-api/deployment.yaml apps/38-forum-bff-db.yaml manifests/forum-bff-db ;;
            postgres-wiki-bff)  _mgd_pg "${tree}" "${ep}" wikibff  manifests/wiki-bff-api/deployment.yaml  apps/34a-wiki-bff-db.yaml manifests/wiki-bff-db ;;
            postgres-casdoor)   _mgd_pg_casdoor "${tree}" "${ep}" ;;
            kafka)
                _mgd_rewrite_env "${tree}/manifests/admin-bff-api/deployment.yaml" SPRING_KAFKA_BOOTSTRAP_SERVERS "${ep}"
                rm -f "${apps}/35-analytics-kafka.yaml"; rm -rf "${tree}/manifests/analytics/kafka"
                ;;
            clickhouse)
                churl="${ep}"; case "${ep}" in *"://"*) ;; *) churl="https://${ep}";; esac
                _mgd_rewrite_env "${tree}/manifests/admin-bff-api/deployment.yaml" CLICKHOUSE_URL "${churl}"
                hostport="${ep#*://}"
                [ -f "${tree}/manifests/observability/deployment.yaml" ] && \
                    sed -i -E "s#(clickhouse://[^@]+@)[^/]+#\\1${hostport}#" "${tree}/manifests/observability/deployment.yaml"
                rm -f "${apps}/35-analytics-clickhouse.yaml"; rm -rf "${tree}/manifests/analytics/clickhouse"
                ;;
            velero-objectstore) _mgd_velero "${tree}" "${ep}" ;;
            federation-bundles) _mgd_fed_bundles "${tree}" "${ep}" ;;
            smtp) : ;;  # pure creds/host via gen-cluster-secrets MAIL_*; recorded in the conf only
        esac
    done
    mkdir -p "${SYSROOT}/etc/snapdragon"
    { echo "# Managed backing services baked into this image (see docs/MANAGED-SERVICES.md)."
      echo "# Self-hosted is the default; only the ids below were repointed at a hosted endpoint."
      echo "# Format: <id>=<endpoint>  (creds are NOT here — they ride ESO/Vault via the KEYS USB)."
      for id in ${_MGD_TIER12_IDS}; do _mgd_selected "${id}" || continue; echo "${id}=$(_mgd_endpoint "${id}")"; done
    } > "${SYSROOT}/etc/snapdragon/backing-services.conf"
    chmod 644 "${SYSROOT}/etc/snapdragon/backing-services.conf"
    _mgd_bake_readme "${tree}"
    info "MANAGED_SERVICES: baked /etc/snapdragon/backing-services.conf + README-MANAGED.md"
}

# Put the Anubis PoW gate genuinely IN FRONT of public ingress when installed.
# The fe-gateway chart renders the public Ingress (host snapdragon.systems +
# *.snapdragon.systems) with its backend Service overridable via the new
# `ingress.backendServiceName`/`ingress.backendServicePort` values. When Anubis is
# installed we point that Ingress backend at the anubis Service (:8923); Anubis
# forwards verified requests to the fe-gateway (its TARGET=fe-gateway:8080). When
# NOT installed the values stay absent and the Ingress backend defaults to the
# fe-gateway Service (unchanged direct path). IDEMPOTENT (re-derives the two lines
# from $1 every run) and REVERSIBLE (removes them when $1=false). Only the
# fe-gateway Application carries the public web ingress.
_opt_wire_anubis_ingress() {
    local installed="$1"
    local fe="${SYSROOT}/var/lib/snapdragon/cluster/apps/20-gateway-fe.yaml"
    [ -f "${fe}" ] || return 0
    # 1) Always strip any previously-wired override lines + their marker comment
    #    (idempotent reset, so re-running never accumulates duplicates).
    sed -i -E '/^[[:space:]]*# PoW shield UP: route public ingress THROUGH Anubis/d' "${fe}"
    sed -i -E '/^[[:space:]]*backendServiceName:[[:space:]]*anubis[[:space:]]*(#.*)?$/d' "${fe}"
    sed -i -E '/^[[:space:]]*backendServicePort:[[:space:]]*8923[[:space:]]*(#.*)?$/d' "${fe}"
    [ "${installed}" = "true" ] || { info "ENV=${ENV}: Anubis NOT installed — public ingress routes DIRECT to fe-gateway (no PoW reroute)"; return 0; }
    # 2) Insert the override directly under the fe-gateway `ingress:` block's
    #    `enabled: true` line so the chart points the public Ingress backend at the
    #    anubis Service (:8923) instead of the fe-gateway Service. Anubis then
    #    forwards verified traffic to the fe-gateway (TARGET). The indentation
    #    matches the sibling `className:`/`host:` keys (10 spaces under values |).
    awk '
        BEGIN { done=0 }
        {
            print
            if (!done && $0 ~ /^[[:space:]]*ingress:[[:space:]]*$/) { in_ing=1; next }
            if (in_ing && !done && $0 ~ /^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/) {
                match($0, /^[[:space:]]*/); pad=substr($0,1,RLENGTH)
                print pad "# PoW shield UP: route public ingress THROUGH Anubis (:8923) -> fe-gateway."
                print pad "backendServiceName: anubis"
                print pad "backendServicePort: 8923"
                done=1; in_ing=0
            }
        }
    ' "${fe}" > "${fe}.tmp" && mv "${fe}.tmp" "${fe}"
    info "ENV=${ENV}: Anubis installed — public ingress REROUTED through the Anubis PoW gate (:8923) -> fe-gateway (all shields up)"
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
    else
        # ENV=test
        rm -f "${apps}/12-cloudflared.yaml" && \
            info "ENV=test: pruned go-live app 12-cloudflared.yaml from the baked tree"
        case "${CLUSTER_DOMAIN}" in
            *.test) info "ENV=test: LAN wildcard DNS authoritative for ${CLUSTER_DOMAIN}" ;;
            *) rm -f "${apps}/09-lan-dns.yaml" && \
                   warn "ENV=test but domain '${CLUSTER_DOMAIN}' is not .test — pruned 09-lan-dns.yaml so it cannot hijack a real domain (use brands/local.conf / 'make local' for a .test LAN build)" ;;
        esac
    fi

    # ── RELEASE_STATE gate (K8s-manifest enforcement — Layer 2 / the PRIMARY
    # mechanism; INDEPENDENT of the ENV=prod/test split above). RELEASE_STATE
    # is threaded from brand.conf like CLUSTER_DOMAIN (default "internal";
    # validated against CLUSTER_DOMAIN in generate-brand-repos.sh). A
    # RELEASE_STATE=internal build stays LAN/tailnet-only regardless of ENV,
    # so this block runs for BOTH branches above — which is why the prod
    # branch no longer `return`s early.
    #
    # This GENERALIZES the existing tailnet-only superadmin-gateway pattern
    # (apps/22-gateway-superadmin.yaml + tier-ingress.yaml's superadmin
    # carve-out) to the WHOLE brand: when not public, the public ingress
    # controller never ships at all, both public-facing gateways serve ONLY
    # the internal ingress class, and the tier-ingress NetworkPolicy admits
    # from the internal facade instead of the (now-absent) public one.
    #
    # Layer 3 (bake_host_firewall(), the host nftables backstop) is called
    # right after gate_env_apps() in the main build flow and enforces the
    # SAME posture independently, at the netfilter layer.
    if [ "${RELEASE_STATE:-internal}" != "public" ]; then
        local cluster="${SYSROOT}/var/lib/snapdragon/cluster"
        local netpol="${cluster}/manifests/networkpolicy/tier-ingress.yaml"

        # a) The public ingress controller Application never ships — nothing
        #    for a public IngressClass to bind to.
        rm -f "${apps}/10-ingress-nginx.yaml" && \
            info "RELEASE_STATE=internal: pruned the public ingress controller 10-ingress-nginx.yaml from the baked tree"

        # b) Both public-facing gateways (be/fe) are repointed to serve ONLY
        #    the internal ingress class (11-ingress-nginx-internal.yaml,
        #    pinned to the pki node) instead of the now-absent public class.
        local gw
        for gw in "${apps}/20-gateway-be.yaml" "${apps}/20-gateway-fe.yaml"; do
            [ -f "${gw}" ] && sed -i -E 's/^([[:space:]]*className: )nginx$/\1nginx-internal/' "${gw}"
        done
        info "RELEASE_STATE=internal: be/fe gateways repointed className nginx -> nginx-internal"

        # c) tier-ingress.yaml's backend/frontend admit-lists currently let
        #    the PUBLIC ingress-nginx namespace in; with the public
        #    controller gone, admit from ingress-nginx-internal instead (the
        #    pki namespace already carries this exact carve-out — see (a)/(b)
        #    above and 22-gateway-superadmin.yaml).
        [ -f "${netpol}" ] && sed -i -E \
            -e 's/(kubernetes\.io\/metadata\.name: )ingress-nginx( \} \})/\1ingress-nginx-internal\2/' \
            -e 's/# public facade/# internal facade (RELEASE_STATE=internal)/' \
            "${netpol}" && \
            info "RELEASE_STATE=internal: tier-ingress.yaml admits ingress-nginx-internal instead of the public ingress-nginx"
    fi
}

# Layer 3 (defense-in-depth): host-level nftables backstop for RELEASE_STATE,
# INDEPENDENT of the K8s ingress-class/NetworkPolicy split in gate_env_apps()
# above and of firewalld (/etc/firewalld) — even if either is ever
# misconfigured, an internal-only device still refuses public 80/443 at the
# netfilter layer. Ships the reconcile agent (owns render + `nft -f` load,
# scoped to its OWN nftables table so firewalld's tables are untouched) + its
# OpenRC oneshot (ordered before containerd/kubelet/tailscaled — see the
# init.d depend()) + its 60s convergence cron UNCONDITIONALLY (core
# hardening, not opt-in — unlike the STAGED vpn/tor/domain reconciles). Also
# bakes /etc/snapdragon/release-state, parallel to the existing
# /etc/snapdragon/cluster-domain bake below. The FIRST-EVER ruleset load
# happens at first boot (the oneshot), rendered from this baked value + the
# (absent-by-default) go-live marker, so there is no separate build-time
# nftables.conf to keep in sync.
bake_host_firewall() {
    mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/usr/lib/snapdragon" "${SYSROOT}/etc/init.d" "${SYSROOT}/etc/cron.d" "${SYSROOT}/etc/snapdragon"
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-firewall-reconcile"   "${SYSROOT}/usr/sbin/snapdragon-firewall-reconcile"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-firewall-reconcile"
    cp "${SHARED_SPECS}/etc/init.d/snapdragon-firewall-reconcile" "${SYSROOT}/etc/init.d/snapdragon-firewall-reconcile"
    chmod +x "${SYSROOT}/etc/init.d/snapdragon-firewall-reconcile"
    cp "${SHARED_SPECS}/etc/cron.d/snapdragon-firewall-reconcile" "${SYSROOT}/etc/cron.d/snapdragon-firewall-reconcile"
    # ── Go-Live wizard: the human-facing effector of this same firewall-reconcile /
    #    release-state mechanism (driver writes /etc/snapdragon/go-live; reconcile
    #    converges <=60s). Baked unconditionally alongside reconcile — inert until the
    #    marker is written. Front-ends: -cli (thin CLI) and -menu (thin ncurses console).
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live"              "${SYSROOT}/usr/sbin/snapdragon-go-live"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live"
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live-cli"          "${SYSROOT}/usr/sbin/snapdragon-go-live-cli"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live-cli"
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live-menu"         "${SYSROOT}/usr/sbin/snapdragon-go-live-menu"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live-menu"
    cp "${SHARED_SPECS}/usr/lib/snapdragon/go-live-providers.sh"  "${SYSROOT}/usr/lib/snapdragon/go-live-providers.sh"
    # ── Cloud-deploy wizard: go-live's SIBLING driver+registry (plan/apply/status/
    #    destroy of a PACKAGED x86 image onto aws-ec2/azure-image/openshift-cnv/
    #    generic-qcow2). Baked beside the go-live set — inert until an operator runs
    #    it: plan is a pure offline render, apply/destroy are TTY-gated (no --yes).
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-cloud-deploy"         "${SYSROOT}/usr/sbin/snapdragon-cloud-deploy"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-cloud-deploy"
    cp "${SHARED_SPECS}/usr/lib/snapdragon/cloud-deploy-providers.sh" "${SYSROOT}/usr/lib/snapdragon/cloud-deploy-providers.sh"
    echo "${RELEASE_STATE:-internal}" > "${SYSROOT}/etc/snapdragon/release-state"
    # ── Go-Live web-UI effector: the 4th front-end (admin-bff's web console) can only
    #    RECORD a signed intent (it runs in a pod, can't touch this host's filesystem);
    #    this agent is what actually drives the SAME driver's commit/rollback for a
    #    web-originated intent. Baked alongside the driver it depends on (harmlessly
    #    inert without it — same fail-closed gate as every reconcile agent: missing
    #    verify lib / node.env / baked pubkey -> keep cache, exit 0, apply nothing).
    cp "${SHARED_SPECS}/usr/sbin/snapdragon-go-live-reconcile"     "${SYSROOT}/usr/sbin/snapdragon-go-live-reconcile"
    chmod +x "${SYSROOT}/usr/sbin/snapdragon-go-live-reconcile"
    cp "${SHARED_SPECS}/usr/lib/snapdragon/golive-verify.sh"       "${SYSROOT}/usr/lib/snapdragon/golive-verify.sh"
    cp "${SHARED_SPECS}/etc/init.d/snapdragon-go-live-reconcile"   "${SYSROOT}/etc/init.d/snapdragon-go-live-reconcile"
    chmod +x "${SYSROOT}/etc/init.d/snapdragon-go-live-reconcile"
    cp "${SHARED_SPECS}/etc/cron.d/snapdragon-go-live-reconcile"   "${SYSROOT}/etc/cron.d/snapdragon-go-live-reconcile"
    info "RELEASE_STATE=${RELEASE_STATE:-internal}: baked the host nftables backstop (snapdragon-firewall-reconcile renders + loads the live ruleset at boot + every 60s) + the go-live wizard (driver/registry/CLI/ncurses front-ends) + the web-UI go-live effector (snapdragon-go-live-reconcile)"
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
    # Harbor image-project segment (registry.<host>/<project>/<svc>). Defaults to the
    # brand; the HARBOR_PROJECT env is a first-class seam for a differently-named project.
    local _hproj; _hproj="$(_sed_rep_escape "${HARBOR_PROJECT:-${BRAND}}")"
    local roots=("${SYSROOT}/var/lib/snapdragon/cluster" "${SYSROOT}/etc/snapdragon")
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
            -e "s|Snapdragon Systems|${BRAND_TITLE}|g" \
            -e "s|snapdragon-systems/|${org_lc}/|g" \
            -e "s|Snapdragon-Systems|${ORG}|g" \
            -e "s|//id\.snapdragon\.games|//id.${GAMES_DOMAIN}|g" \
            -e "s|//snapdragon\.games|//${GAMES_DOMAIN}|g" \
            -e "s|snapdragon\.systems|${CLUSTER_DOMAIN}|g" \
            -e "s|\(registry\.[A-Za-z0-9.-]*\)/snapdragon/|\1/${_hproj}/|g" \
            -e "s|snapdragon-|${BRAND}-|g" \
            -e "s|@@SDSYSKEY@@/|snapdragon.systems/|g" \
            "${f}"
    done < <(find "${roots[@]}" -type f -print0 2>/dev/null)
    info "Rebrand complete (compound names like '${BRAND}-systems-web' may want review)."
}

# ── Mesh-node IdP external mode (I6.3) — the baked-tree passes ────────────────
# Byte-identical mirrors of build-x86-host-stage4.sh's four functions: all are
# self-guarding no-ops for the casdoor default (byte-identity) and for absent
# trees; the ONE call site (apply_idp_external) runs AFTER rebrand_sysroot so the
# issuer literals already read id.<CLUSTER_DOMAIN>. Extracted + fixture-tested by
# tests/scripts/test-idp-builder-functions.sh — never a real build.
bake_idp_conf() {
    [ "${IDP}" = "casdoor" ] && return 0
    mkdir -p "${SYSROOT}/etc/snapdragon"
    cat > "${SYSROOT}/etc/snapdragon/idp.conf" <<EOF
# Identity provider this image's services TRUST (--idp; docs/IDENTITY-PROVIDERS.md).
# PUBLIC identifiers only — client SECRETS ride KEYS/Vault provisioning, never here.
provider=${IDP}
issuer=${IDP_ISSUER}
client_id=${IDP_CLIENT_ID}
jwks_uri=${IDP_JWKS}
EOF
    chmod 0644 "${SYSROOT}/etc/snapdragon/idp.conf"
    info "IdP: baked /etc/snapdragon/idp.conf (provider=${IDP}, 0644, no secrets)"
}

rewrite_idp_sysroot() {
    # The idp-aware pass AFTER rebrand_sysroot: re-point every issuer literal
    # (https://id.<CLUSTER_DOMAIN>, incl. the @@CLUSTER_DOMAIN@@ first-boot
    # template form) at the external issuer, and every in-cluster/derived JWKS pin
    # at the external JWKS. JWKS rules run FIRST so the issuer rule cannot
    # half-rewrite a jwks URL into <external-issuer>/.well-known/jwks.
    [ "${IDP}" = "casdoor" ] && return 0
    local iss_e jwks_e dom_re f n=0
    iss_e="$(_sed_rep_escape "${IDP_ISSUER}")"
    jwks_e="$(_sed_rep_escape "${IDP_JWKS}")"
    dom_re="${CLUSTER_DOMAIN//./\\.}"
    while IFS= read -r -d '' f; do
        if grep -qE "https://id\.(${dom_re}|@@CLUSTER_DOMAIN@@)|/\.well-known/jwks" "${f}" 2>/dev/null; then
            sed -i -E \
                -e "s|https?://casdoor[A-Za-z0-9.:_-]*/\.well-known/jwks|${jwks_e}|g" \
                -e "s|https://id\.${dom_re}/\.well-known/jwks|${jwks_e}|g" \
                -e "s|https://id\.@@CLUSTER_DOMAIN@@/\.well-known/jwks|${jwks_e}|g" \
                -e "s|https://id\.${dom_re}|${iss_e}|g" \
                -e "s|https://id\.@@CLUSTER_DOMAIN@@|${iss_e}|g" \
                "${f}"
            n=$((n+1))
        fi
    done < <(find "${SYSROOT}/var/lib/snapdragon/cluster" "${SYSROOT}/etc/snapdragon" -type f -print0 2>/dev/null)
    info "IdP: rewrote issuer -> ${IDP_ISSUER} + JWKS pins -> ${IDP_JWKS} in ${n} file(s)"
}

gate_casdoor_apps() {
    # External provider: the built-in Casdoor deployment must NOT ride along —
    # prune its ArgoCD apps + manifest trees from the baked GitOps payload
    # (same rm-from-the-baked-copy design as gate_env_apps/gate_optional_services;
    # the repo itself is never touched).
    [ "${IDP}" = "casdoor" ] && return 0
    local tree="${SYSROOT}/var/lib/snapdragon/cluster"
    [ -d "${tree}" ] || return 0
    rm -f "${tree}/apps/05-casdoor.yaml" "${tree}/apps/06-casdoor-games.yaml"
    rm -rf "${tree}/manifests/casdoor" "${tree}/manifests/casdoor-games"
    info "IdP: external provider — gated the built-in Casdoor apps/manifests out of the baked tree"
}

write_idp_readme() {
    [ "${IDP}" = "casdoor" ] && return 0
    mkdir -p "${SYSROOT}/etc/snapdragon"
    cat > "${SYSROOT}/etc/snapdragon/README-IDP.md" <<EOF
# External identity provider (--idp ${IDP})

This image was built to TRUST an external OIDC provider:

  provider:  ${IDP}
  issuer:    ${IDP_ISSUER}
  client id: ${IDP_CLIENT_ID}
  jwks:      ${IDP_JWKS}

What that changed in this image:
  * /etc/snapdragon/idp.conf carries provider/issuer/client_id/jwks_uri (no secrets).
  * The baked cluster tree's issuer literals (https://id.<cluster-domain>) and
    in-cluster JWKS pins were rewritten to the values above, so resource servers
    VALIDATE tokens minted by your provider.
  * The built-in Casdoor applications/manifests were removed from the GitOps tree.

What does NOT work with an external provider (Casdoor-only until the service
repos grow provider support — full table: docs/IDENTITY-PROVIDERS.md in the
generator repo):
  * The native first-party /bff/login leg (user-bff drives Casdoor's proprietary
    POST /api/login; an external provider needs a browser front-channel).
  * MFA step-up stamping (mfa_satisfied is written via the Casdoor API).
  * The roles/permissions/groups token model — headscale allowed_groups, Harbor
    oidc_group_claim, sssd allowlists all read Casdoor-shaped claims.
  * signup-gate and the role-membership sync jobs (Casdoor REST API callers).
  * JWKS egress: the pki-namespace NetworkPolicy only allows in-cluster JWKS —
    HTTPS egress to your provider needs an egress-policy change on the cluster.
EOF
    chmod 0644 "${SYSROOT}/etc/snapdragon/README-IDP.md"
    info "IdP: dropped /etc/snapdragon/README-IDP.md (the honest external-mode limits note)"
}

apply_idp_external() {
    [ "${IDP}" = "casdoor" ] && return 0
    bake_idp_conf
    rewrite_idp_sysroot
    gate_casdoor_apps
    write_idp_readme
}

# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation ──────────
# Runs AFTER full arg parsing / role+env+grow validation / the optional-services
# resolution (all/exclude/opt-in folds) / allowlist checks, but BEFORE the prereq
# probes, the host package.use pre-seed, mkdir, the tee-redirect, network fetches
# or any sysroot write. No root required. One stable KEY=VALUE per line (grep
# '^PLAN_'); exit 0. Invalid role/flag combos never reach this point — the
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
# Tier-1 mandatory atoms (base + role class). Dropping one is rejected (Decision #5:
# tier-2 defaults are droppable; tier-1 essentials are hard-locked).
SNAP_MANDATORY_ATOMS="sys-block/parted app-misc/jq net-misc/networkmanager"
if ${ROLE_CLIENT}; then
    SNAP_MANDATORY_ATOMS="${SNAP_MANDATORY_ATOMS} x11-base/xorg-server x11-wm/openbox x11-misc/lightdm"
else
    SNAP_MANDATORY_ATOMS="${SNAP_MANDATORY_ATOMS} sys-cluster/kubelet sys-cluster/kubeadm app-containers/containerd"
fi
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
    _plan BUILDER            "build-rpi5-stage4.sh"
    # PLATFORM doubles as the board id (rpi5 [DEFAULT] | rpi4 | rpi3) — reusing
    # this existing key (rather than adding a new PLAN_BOARD key) keeps
    # --print-plan output for the DEFAULT board (no --board flag) BYTE-IDENTICAL
    # to before this axis existed: BOARD defaults to the literal string "rpi5",
    # so this line's value is unchanged unless --board rpi4/rpi3 is explicitly
    # passed.
    _plan PLATFORM           "${BOARD}"
    _plan ARCH               "arm64"
    _plan ROLE               "${ROLE}"
    _plan ENV                "${ENV}"
    _plan DESKTOP            "${DESKTOP}"   # 'light' for --role desktop, else headless
    _plan GPU_DRIVER         "none"   # VideoCore (V3D/VC4); no discrete-GPU driver matrix on any RPi board
    _ARTS="stage4.tar.xz"
    ${BUILD_IMG} && _ARTS="${_ARTS},img"
    ${BUILD_ISO} && _ARTS="${_ARTS},iso"
    ${BUILD_TAR} && _ARTS="${_ARTS},fs.tar.xz"
    _plan ARTIFACTS          "${_ARTS}"
    _plan ARTIFACT_PREFIX    "${BRAND}-${BOARD}-arm64-${ROLE}-${ENV}-<timestamp>"
    _plan WORK_DIR           "${WORK_DIR}"
    _plan JOBS               "${JOBS}"
    _plan BRAND              "${BRAND}"
    _plan CLUSTER_DOMAIN     "${CLUSTER_DOMAIN}"
    _plan SUPERDOMAIN        "${SUPERDOMAIN}"
    _plan HOSTNAME           "${HOSTNAME}"
    _plan K8S                "$(${ROLE_CLIENT} && echo none || { [ "${ROLE}" = "pki" ] && echo control-plane || echo worker; })"
    _plan OPTIONAL_SERVICES  "$(${ROLE_CLIENT} && echo "n/a (role=desktop; no cluster GitOps tree baked)" || echo "${OPTIONAL_SERVICES:-none}")"
    _plan MESH               "$(${SKIP_MESH} && echo skip || echo "headscale=${HEADSCALE_VERSION},tailscale=$(${SKIP_TAILSCALE} && echo skip || echo "${TAILSCALE_VERSION}")")"
    _plan IDP                "${IDP}"
    _plan IDP_ISSUER         "${IDP_ISSUER:-none}"
    _plan IDP_CLIENT_ID      "${IDP_CLIENT_ID:-none}"
    _plan IDP_JWKS           "${IDP_JWKS:-none}"
    _plan STANDALONE         "${STANDALONE}"
    _plan LOCAL_USER         "${LOCAL_USER:-$DEFAULT_USER}"
    _plan LOCAL_PASS         "$([ -n "${LOCAL_PASSHASH}" ] && echo REDACTED || echo none)"
    _plan ENCRYPT_ROOT       "${ENCRYPT_ROOT}"
    _plan LUKS_PASS          "$([ -n "${LUKS_PASS}" ] && echo REDACTED || echo none)"
    # KERNEL fragment enumeration: rp1-pi5.config's split-out from
    # hardened-k8s.config is deliberately NOT named here for --board rpi5 (the
    # DEFAULT) — this exact string must stay byte-identical to the pre-Phase-6
    # output. It IS genuinely applied at kernel-build time (see the
    # _kernel_fragments array below) and IS named in the final build summary
    # banner, which has no such constraint. bcm2711-pi4.config IS named here for
    # --board rpi4, and bcm2837-pi3.config for --board rpi3 (both non-default
    # invocations, free to look different/board-aware).
    _kernel_plan_desc="hardened-k8s.config"
    [ "${BOARD}" = "rpi4" ] && _kernel_plan_desc="${_kernel_plan_desc} + bcm2711-pi4.config"
    [ "${BOARD}" = "rpi3" ] && _kernel_plan_desc="${_kernel_plan_desc} + bcm2837-pi3.config"
    ${ROLE_CLIENT} && _kernel_plan_desc="${_kernel_plan_desc} + desktop.config"
    _plan KERNEL             "raspberrypi-arm64 (defconfig=${RPI_DEFCONFIG} + ${_kernel_plan_desc})"
    _plan FLAGS_EFFECTIVE    "env=${ENV} img=${BUILD_IMG} iso=${BUILD_ISO} tar=${BUILD_TAR} img_size=${ROOT_MiB} grow=${GROW_POLICY} sd_only=${SD_ONLY} compress=${COMPRESS_IMG} resume=${RESUME} skip_kernel=${SKIP_KERNEL} skip_mesh=${SKIP_MESH} skip_tailscale=${SKIP_TAILSCALE} pcie_gen3=${PCIE_GEN3} permit_root_login=${PERMIT_ROOT_LOGIN} enable_wifi=${ENABLE_WIFI} enable_bluetooth=${ENABLE_BLUETOOTH} enable_games=${ENABLE_GAMES} standalone=${STANDALONE} encrypt_root=${ENCRYPT_ROOT}"
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
    # Read package list from spec file, stripping comments and blanks
    mapfile -t STAGE4_PACKAGES < <(
        grep -v '^\s*#' "${SPECS_DIR}/portage/packages.list" | grep -v '^\s*$'
    )

    # k8s cluster-node roles get the containerd/kubelet/kubeadm stack; --role desktop
    # (ROLE_CLIENT) gets the lean LXDE client stack instead — never both.
    if ! ${ROLE_CLIENT}; then
        _rsp_info "K8s cluster role — appending packages-k8s.list (containerd + kubeadm node set)"
        mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
            grep -v '^\s*#' "${SPECS_DIR}/portage/packages-k8s.list" | grep -v '^\s*$')
    else
        _rsp_info "Desktop role — appending packages-desktop.list (lean LXDE client set)"
        mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
            grep -v '^\s*#' "${SPECS_DIR}/portage/packages-desktop.list" | grep -v '^\s*$')
    fi

    # Egress VPN (DEFAULT-OFF optional service): the node packages.list always lists
    # net-vpn/wireguard-tools + net-vpn/openvpn, but they are ONLY needed when the
    # egress-vpn service is selected. PRUNE them from the install set otherwise so an
    # image that does not use the VPN does not carry wg-quick/openvpn (parity with the
    # gate that prunes the cluster apps of an unselected slug).
    if ! _opt_selected egress-vpn; then
        _kept=()
        for _pkg in "${STAGE4_PACKAGES[@]}"; do
            case "${_pkg}" in
                net-vpn/wireguard-tools|net-vpn/openvpn) ;;   # drop (egress-vpn not selected)
                *) _kept+=("${_pkg}") ;;
            esac
        done
        STAGE4_PACKAGES=("${_kept[@]}")
        _rsp_info "OPTIONAL_SERVICES: egress-vpn NOT selected — pruned net-vpn/wireguard-tools + net-vpn/openvpn from the node packages"
    fi

    # BOARD-gated package: sys-apps/nvme-cli is only meaningful on --board rpi5,
    # which exposes a user-facing PCIe/NVMe path (the FFC/M.2 HAT connector); the
    # standard Pi 4 Model B has none (its one PCIe lane is fully internal, wired to
    # the VL805 USB3 bridge), and Pi 3 (BCM2837) has no PCIe controller at all —
    # see specs-rpi5/kernel/hardened-k8s.config. Prune it for --board rpi4/rpi3 so
    # the image doesn't carry NVMe tooling for hardware it cannot have.
    # sys-apps/pciutils/usbutils/i2c-tools stay unconditional — every board
    # genuinely has USB/I2C topology worth diagnosing (rpi3's USB is DWC2-based
    # rather than PCIe-attached xHCI, so usbutils/i2c-tools remain useful there;
    # pciutils is harmless dead weight on a board with no PCIe bus at all, matching
    # this codebase's existing "inert-but-harmless" tolerance elsewhere).
    if [ "${BOARD}" != "rpi5" ]; then
        _kept=()
        for _pkg in "${STAGE4_PACKAGES[@]}"; do
            case "${_pkg}" in
                sys-apps/nvme-cli) ;;   # drop (--board rpi4/rpi3: no user-facing NVMe path)
                *) _kept+=("${_pkg}") ;;
            esac
        done
        STAGE4_PACKAGES=("${_kept[@]}")
        _rsp_info "BOARD=${BOARD}: pruned sys-apps/nvme-cli (no user-facing NVMe path on this board)"
    fi

    # BOARD-gated package: dev-embedded/rpi-eeprom (the Pi 4/5 bootloader EEPROM
    # updater) has NO --board rpi3 value at all — its REQUIRED_USE is a hard
    # exactly-one-of ( pi4 pi5 ), verified against the live Gentoo ebuild (see the
    # comment on the package.use/rpi5 sed-flip above). Pi 3 has no flashable boot
    # EEPROM in the first place: it boots via bootcode.bin + start.elf read
    # directly off the FAT boot partition by the GPU's on-chip boot ROM, so there
    # is nothing for rpi-eeprom to manage even if its REQUIRED_USE could somehow be
    # satisfied. EXCLUDE it entirely for --board rpi3 (not just leave it
    # unflashed) — sys-apps/flashrom is dropped too since it is rpi-eeprom's only
    # puller in this packages.list (an UNCONDITIONAL RDEPEND; nothing else here
    # wants flashrom — see package.use/rpi5's own comment on it).
    if [ "${BOARD}" = "rpi3" ]; then
        _kept=()
        for _pkg in "${STAGE4_PACKAGES[@]}"; do
            case "${_pkg}" in
                dev-embedded/rpi-eeprom) ;;   # drop (--board rpi3: no EEPROM at all)
                *) _kept+=("${_pkg}") ;;
            esac
        done
        STAGE4_PACKAGES=("${_kept[@]}")
        _rsp_info "BOARD=rpi3: pruned dev-embedded/rpi-eeprom (no flashable boot EEPROM on this board; boots via bootcode.bin/start.elf instead)"
    fi

    # Tor v3 onion (hidden) service (DEFAULT-OFF optional service): net-vpn/tor (the v3
    # onion daemon, ships /etc/init.d/tor + /etc/tor/torrc + the tor:tor user) is NOT in
    # the base packages.list, so it is ADDED to the install set ONLY when 'tor' is selected
    # — an image without tor never carries it (parity with the egress-vpn package gate, just
    # inverted: ADD-when-selected vs prune-when-not). net-vpn/tor inherits USE=selinux from a
    # SELinux node profile, giving the upstream tor_t confinement snapdragon_tor.te references.
    if _opt_selected tor; then
        STAGE4_PACKAGES+=(net-vpn/tor)
        _rsp_info "OPTIONAL_SERVICES: tor selected — added net-vpn/tor to the node packages (v3 onion daemon; keypair off-git, minted first-boot)"
    fi

    # LUKS2 root (--encrypt-root): dracut generates the disk-boot initramfs that
    # unlocks it. cryptsetup/lvm2 are already unconditional in packages.list (used
    # today for the LUKS2 DATA partition on an attached NVMe/USB); dracut is new
    # and only needed for the root-encryption path, so it stays conditional.
    if ${ENCRYPT_ROOT}; then
        STAGE4_PACKAGES+=(sys-kernel/dracut)
    fi

    # Append user-specified extra packages
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

# Check spec directories (arch-specific + shared)
if [ ! -d "${SPECS_DIR}" ]; then
    err "RPi specs directory not found: ${SPECS_DIR}"
    err "Expected to find it next to this script, or pass --specs-dir."
    exit 1
fi
if [ ! -d "${SHARED_SPECS}" ]; then
    err "Shared specs directory not found: ${SHARED_SPECS}"
    err "Expected to find specs/ next to this script."
    exit 1
fi
info "Board:        ${BOARD_DESC}"
info "RPi specs:    ${SPECS_DIR}"
info "Shared specs: ${SHARED_SPECS}"

# Check toolchain
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    if ! command -v "${tool}" &>/dev/null; then
        err "${tool} not found in PATH."
        exit 1
    fi
done

# ── Cross-dracut (--encrypt-root) fail-FAST preflight ───────────────
# An --encrypt-root RPi5 installer (ISO) needs an arm64 disk-boot initramfs,
# generated by chrooting into the target sysroot under qemu-aarch64 (Strategy 1
# in build_disk_initramfs). That path is otherwise only DISCOVERED to be missing
# hours later, AFTER the @stage4 + kernel build (the live pki.rpi5 failure).
# Detect it NOW: attempt the (idempotent, non-fatal) qemu binfmt registration and
# require a usable qemu-aarch64; if absent, die BEFORE the multi-hour build with
# a scope-explicit, actionable message. This runs only on a real build (after the
# `--print-plan` exit above), so matrix.tsv / PLAN_* output stays byte-identical.
# The late post-build refusal (build_disk_initramfs || true -> err/exit) stays as
# the fail-SAFE backstop for cases this fail-FAST check cannot foresee.
if ${ENCRYPT_ROOT} && ${BUILD_ISO}; then
    dracut_cross_register_qemu || true
    if ! dracut_cross_preflight_ok; then
        err "--encrypt-root on ${BRAND}-${BOARD}-${ROLE} (if this build came from a multi-image mesh worklist, THIS node image is the affected one) needs the arm64 disk-boot initramfs, but no usable cross-dracut strategy is available: ${DRACUT_CROSS_BINFMT_NODE} is not registered and/or $(dracut_cross_qemu_interp) is missing/not executable."
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
    cat > /etc/portage/package.accept_keywords/snapdragon-host-build-backends <<'HOSTKW'
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
    cat > /etc/portage/package.use/snapdragon-host-build-backends <<'HOSTPYUSE'
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
# k8s-only snapdragon-cross-host-selinux seed carries, but the host policy
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
if hostguard_mutation_allowed && [ "$(id -u)" -eq 0 ]; then
    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/snapdragon-cross-host-selinux <<'HOSTSELINUX'
# Auto-written by build-rpi5-stage4.sh (RPi CROSS build, --board rpi5|rpi4). The HOST x86 selinux-python/
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
# HOST tool halves of the sysroot's SELinux 3.11 userspace (see the HOSTKW
# ~amd64 window above): the libselinux/policycoreutils pkg_postinst phases run
# these on the ROOT!=/ merge (session 20260716-160638-f8c153).
command -v sefcontext_compile &>/dev/null || HOST_POLICY_TOOLS+=(sys-libs/libselinux)
command -v semodule           &>/dev/null || HOST_POLICY_TOOLS+=(sys-apps/policycoreutils)
if [ "${#HOST_POLICY_TOOLS[@]}" -ne 0 ]; then
    readarray -t HOST_POLICY_TOOLS < <(printf '%s\n' "${HOST_POLICY_TOOLS[@]}" | sort -u)
    if hostguard_mutation_allowed && [ "$(id -u)" -eq 0 ] && command -v emerge &>/dev/null; then
        warn "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]} — emerging natively"
        # NATIVE host emerge (no ROOT/SYSROOT/PORTAGE_CONFIGROOT overrides):
        # these are x86 build tools, NOT part of the aarch64 sysroot.
        emerge --noreplace --quiet "${HOST_POLICY_TOOLS[@]}" \
            || { err "Failed to install host SELinux build tools (${HOST_POLICY_TOOLS[*]})."; \
                 err "selinux-base src_compile (emake base) needs host checkpolicy + semodule_package."; exit 1; }
    else
        err "Missing host SELinux build tools: ${HOST_POLICY_TOOLS[*]}"
        err "Install on the BUILD host (NOT the sysroot): emerge sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4 sys-libs/libselinux sys-apps/policycoreutils (accept ~amd64 for the SELinux 3.11 window: libsepol/libselinux/policycoreutils)"
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
exec > >(tee -a "${LOG_FILE}" "${IMAGE_LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE} (session-shared) + ${IMAGE_LOG_FILE} (this image)"
# Run banner: the shared log interleaves runs (append) and a RESTART appends to
# the per-image log too — keep every chunk attributable to its run.
echo "==== ${BUILD_SUBDIR#wl-} (${BUILD_SUBDIR}) start ${BUILD_TS} brand=${BRAND} role=${ROLE} env=${ENV} ===="

banner "Fetching latest arm64 stage3 seed tarball"

# The index is PGP-signed; select the stage3 tarball line, ignoring armor/comments.
STAGE3_FILE=$(curl -sL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors "${SEED_STAGE3_URL}" | awk '/stage3-.*\.tar\.xz/{print $1; exit}')
STAGE3_BASENAME=$(basename "${STAGE3_FILE}")
STAGE3_BASE_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds"
STAGE3_FULL_URL="${STAGE3_BASE_URL}/${STAGE3_FILE}"
# Per-arch: the aarch64 seed must not be reused by (or clobber) the amd64 build.
STAGE3_LOCAL="${BUILD_ROOT}/${STAGE3_BASENAME}"

if [ ! -f "${STAGE3_LOCAL}" ]; then
    info "Downloading ${STAGE3_BASENAME}..."
    curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors -o "${STAGE3_LOCAL}" "${STAGE3_FULL_URL}"
else
    info "Using cached ${STAGE3_BASENAME}"
fi

# SUPPLY-CHAIN: verify the seed's integrity+authenticity before we trust a single
# byte of it. dlv_verify_stage3 fetches the matching .DIGESTS(.asc), GPG-verifies
# it against the pinned Gentoo release-engineering key, then checks the tarball's
# SHA512/SHA256 against the signed DIGESTS — ABORTING on any signature/checksum
# mismatch. A poisoned mirror or MITM can no longer slip a backdoored seed in.
banner "Verifying stage3 seed signature + checksum"
if ! dlv_verify_stage3 "${STAGE3_LOCAL}" "${STAGE3_FULL_URL}.DIGESTS"; then
    rm -f "${STAGE3_LOCAL}"   # drop the unverified file so a re-run re-fetches
    err "stage3 seed failed verification (bad signature or checksum) — aborting."
    err "If Gentoo rotated its signing key, set DLV_GENTOO_KEY=<fingerprint>; for an"
    err "air-gapped build set DLV_OFFLINE_KEYRING=<keyfile>. Refusing unverified seed."
    exit 1
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

# Compute PCIE_LINE for templates. --pcie-gen3 only means anything on --board
# rpi5: that dtparam forces Gen 3 link speed on Pi 5's user-facing NVMe FFC/M.2
# HAT PCIe link. The standard Pi 4 Model B has NO user-facing PCIe slot at all
# (its one PCIe lane is fully consumed internally by the VL805 USB3 bridge — see
# specs-rpi5/kernel/hardened-k8s.config), and Pi 3 (BCM2837) has NO PCIe
# controller of any kind — so force the line off (commented/no-op) for
# --board rpi4/rpi3 regardless of the flag, with a loud warning instead of
# silently doing nothing.
if ${PCIE_GEN3} && [ "${BOARD}" != "rpi5" ]; then
    case "${BOARD}" in
        rpi4) warn "--pcie-gen3 has no effect on --board rpi4 (the standard Pi 4 Model B has no user-facing PCIe slot; its one PCIe lane is internal-only, wired to the VL805 USB3 bridge) — ignoring." ;;
        rpi3) warn "--pcie-gen3 has no effect on --board rpi3 (BCM2837 has no PCIe controller at all — its USB/Ethernet ride the SoC's Synopsys DWC2 controller instead, see specs-rpi5/kernel/bcm2837-pi3.config) — ignoring." ;;
    esac
    PCIE_LINE="# dtparam=pciex1_gen=3"
elif ${PCIE_GEN3}; then
    PCIE_LINE="dtparam=pciex1_gen=3"
else
    PCIE_LINE="# dtparam=pciex1_gen=3"
fi

# Compute CONSOLE_UART for cmdline.txt.tmpl: each board exposes its serial
# console on a DIFFERENT UART device node. Pi 5 has a DEDICATED debug UART on a
# 3-pin JST connector (not the GPIO header), enumerated as ttyAMA10 by the
# mainline/raspberrypi kernel — the historical hardcoded value here, unchanged
# for --board rpi5. Pi 4 has no such dedicated debug port; its serial console is
# the GPIO-header UART, ttyAMA0 (dtparam=uart0=on in config.txt, unchanged
# board-agnostic already). NOT verified against a real Pi 4 boot in this
# sandbox — cross-checked against Raspberry Pi's own forum/docs guidance only.
# Pi 3 has an onboard Bluetooth module that, by default, claims the full PL011
# UART (ttyAMA0) for itself, leaving only the clock-derived mini-UART (ttyS0)
# on the GPIO header — the mini-UART's baud rate depends on the core clock,
# which config.txt's already-unconditional enable_uart=1 stabilizes, so ttyS0
# works out of the box with NO extra dtoverlay needed. Deliberately NOT
# ttyAMA0+dtoverlay=disable-bt: that would coincidentally work with
# ENABLE_BLUETOOTH's default (false) but silently contradict --enable-bluetooth
# (BT would have no UART left) — ttyS0 is correct in EITHER radio state. NOT
# verified against a real Pi 3 boot in this sandbox — cross-checked against
# Raspberry Pi's own forum/docs guidance only, same confidence level as the
# rpi4 line above.
case "${BOARD}" in
    rpi4) CONSOLE_UART="ttyAMA0" ;;
    rpi3) CONSOLE_UART="ttyS0" ;;
    *)    CONSOLE_UART="ttyAMA10" ;;
esac

# Compute VC4_OVERLAY_LINE for config.txt.tmpl. Pi 4/5's firmware already
# defaults straight to the KMS-capable vc4/v3d device-tree binding with NO
# explicit dtoverlay needed — this line stays a harmless, always-commented
# no-op on those boards (byte-for-byte what config.txt already did before this
# token existed, just spelled out instead of omitted). Pi 3's older firmware/
# DTB does NOT default to KMS: without an explicit dtoverlay, the boot ROM
# leaves the legacy, non-KMS firmware-managed framebuffer path active, which
# this repo's modern Xorg/LXDE desktop stack cannot drive. HIGH UNCERTAINTY
# (flagged explicitly): vc4-kms-v3d (full KMS, not the older vc4-fkms-v3d
# Fake-KMS overlay) is Raspberry Pi OS's own current default for Pi 3 on a
# recent kernel — chosen here on that basis — but NOT verified against a real
# Pi 3 boot in this sandbox (no aarch64 hardware available); see
# specs-rpi5/kernel/bcm2837-pi3.config's header for the full research trail.
case "${BOARD}" in
    rpi3) VC4_OVERLAY_LINE="dtoverlay=vc4-kms-v3d" ;;
    *)    VC4_OVERLAY_LINE="# dtoverlay=vc4-kms-v3d (n/a — ${BOARD} firmware already defaults to KMS)" ;;
esac

# Compute INITRAMFS_LINE for config.txt.tmpl: the RPi firmware bootloader
# normally goes straight from kernel to root= on cmdline.txt (no initramfs at
# all). --encrypt-root needs one — a disk-boot dracut initramfs (built after
# the kernel phase, see build_disk_initramfs() below) that unlocks the LUKS2
# root before the real root= is mounted. 'followkernel' places it directly
# after the kernel in memory, the RPi firmware's documented convention.
if ${ENCRYPT_ROOT}; then
    INITRAMFS_LINE="initramfs disk-initrd.img followkernel"
else
    INITRAMFS_LINE="# initramfs disk-initrd.img followkernel"
fi

# Portage directories
mkdir -p "${SYSROOT}/etc/portage/"{package.use,package.accept_keywords,package.mask,profile,env,package.env,patches,repos.conf}

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
# dev-embedded/rpi-eeprom REQUIRED_USE is exactly-one-of ( pi4 pi5 ) — verified
# against the live Gentoo ebuild (dev-embedded/rpi-eeprom's IUSE/REQUIRED_USE;
# its DESCRIPTION is literally "Updater for Raspberry Pi 4/5 bootloader and the
# VL805 USB controller" — there is no "pi3" value and never will be, this
# package is Pi 4/5-only). The package.use/rpi5 file bakes "pi5" as its static
# default (unchanged for --board rpi5). Flip it to "pi4" for --board rpi4 so
# the installed EEPROM updater actually matches the board it is running on,
# instead of silently building a Pi 5-flavored rpi-eeprom for a Pi 4 image.
# --board rpi3 does NOT get a flip here — see the STAGE4_PACKAGES-level
# EXCLUSION below instead (there is no "pi3" USE value to flip TO, and Pi 3 has
# no flashable EEPROM at all to update in the first place).
if [ "${BOARD}" = "rpi4" ]; then
    sed -i -E 's/^(dev-embedded\/rpi-eeprom)[[:space:]]+pi5$/\1 pi4/' \
        "${SYSROOT}/etc/portage/package.use/rpi5"
    info "BOARD=rpi4: flipped dev-embedded/rpi-eeprom USE pi5 -> pi4"
fi
# Plain (non-templated) per-package env files, e.g. python-cross.conf. The .tmpl
# env files (cross-go.conf) are rendered separately just below.
cp "${SPECS_DIR}/portage/env/"*.conf                      "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
# Per-package user patches auto-applied by eapply_user (called from each ebuild's
# default src_prepare). cross_emerge runs with PORTAGE_CONFIGROOT=${SYSROOT}, so
# portage reads them from ${SYSROOT}/etc/portage/patches/<cat>/<pkg>/. Currently
# holds net-misc/networkmanager's cross jansson-SONAME fix (see that .patch).
if [ -d "${SPECS_DIR}/portage/patches" ]; then
    cp -a "${SPECS_DIR}/portage/patches/."             "${SYSROOT}/etc/portage/patches/"
fi

# Templated portage specs
render_template "${SPECS_DIR}/portage/make.conf.tmpl"     "${SYSROOT}/etc/portage/make.conf"
render_template "${SPECS_DIR}/portage/env/cross-go.conf.tmpl" "${SYSROOT}/etc/portage/env/cross-go.conf"

# The arm64 stage3's python FLOATS — the current seed ships ONLY python3.14, but
# the template historically pinned python3_12. A target with no interpreter in the
# seed leaves @system unsatisfiable (e.g. certifi/requests/pip dropped 3.12 ->
# "All ebuilds masked" -> pam/openssh/@system fail -> payload incomplete). Pin
# PYTHON_TARGETS/PYTHON_SINGLE_TARGET to whatever python the seed actually ships
# so this survives future stage3 python bumps without another hardcode edit.
_seed_py="$(ls -d "${SYSROOT}"/usr/lib/python3.* 2>/dev/null | sed 's#.*/##' | sort -V | tail -1)"   # e.g. python3.14
if [[ "${_seed_py}" =~ ^python3\.[0-9]+$ ]]; then
    _seed_pt="${_seed_py/./_}"                                                                        # python3_14
    sed -i -E "s/^PYTHON_TARGETS=.*/PYTHON_TARGETS=\"${_seed_pt}\"/; \
               s/^PYTHON_SINGLE_TARGET=.*/PYTHON_SINGLE_TARGET=\"${_seed_pt}\"/" \
        "${SYSROOT}/etc/portage/make.conf"
    info "PYTHON_TARGETS/PYTHON_SINGLE_TARGET pinned to seed python: ${_seed_pt}"
else
    warn "could not detect seed python under ${SYSROOT}/usr/lib — leaving templated PYTHON_TARGETS"
fi

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

# LUKS2 root (--encrypt-root): persist crypt-module support into any FUTURE
# dracut regeneration on the installed system (e.g. a post-install kernel
# rebuild), not just the disk-boot initramfs this build generates directly.
if ${ENCRYPT_ROOT}; then
    mkdir -p "${SYSROOT}/etc/dracut.conf.d"
    cp "${SPECS_DIR}/etc/dracut.conf.d/60-snapdragon-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/"
fi

# Everything below is arch-agnostic and shared with the x86 build -> SHARED_SPECS.
mkdir -p "${SYSROOT}/etc/sysctl.d"
cp "${SHARED_SPECS}/etc/sysctl.d/10-hardened.conf"        "${SYSROOT}/etc/sysctl.d/10-hardened.conf"

# k8s modules/sysctl + containerd/kubelet/kubeadm config + init scripts:
# cluster-node roles only — meaningless (and the binaries won't exist) on
# --role desktop (ROLE_CLIENT). Auto-loading ip_vs/vxlan/br_netfilter and
# forcing net.ipv4.ip_forward=1 etc. has no business on a personal desktop.
if ! ${ROLE_CLIENT}; then
    mkdir -p "${SYSROOT}/etc/modules-load.d"
    cp "${SHARED_SPECS}/etc/modules-load.d/kubernetes.conf"   "${SYSROOT}/etc/modules-load.d/kubernetes.conf"

    cp "${SHARED_SPECS}/etc/sysctl.d/99-kubernetes.conf"      "${SYSROOT}/etc/sysctl.d/99-kubernetes.conf"

    mkdir -p "${SYSROOT}/etc/containerd"
    cp "${SHARED_SPECS}/etc/containerd/config.toml"           "${SYSROOT}/etc/containerd/config.toml"

    mkdir -p "${SYSROOT}/var/lib/kubelet"
    cp "${SHARED_SPECS}/etc/kubernetes/kubelet-config.yaml"   "${SYSROOT}/var/lib/kubelet/config.yaml"

    mkdir -p "${SYSROOT}/etc/kubernetes"
    cp "${SHARED_SPECS}/etc/kubernetes/kubeadm-config.yaml"   "${SYSROOT}/etc/kubernetes/kubeadm-config.yaml"
fi

mkdir -p "${SYSROOT}/etc/init.d" "${SYSROOT}/etc/firewalld/zones"
for svc in growroot headscale tailscaled keys-provision; do
    cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"
    chmod +x "${SYSROOT}/etc/init.d/${svc}"
done
if ! ${ROLE_CLIENT}; then
    for svc in containerd kubelet; do
        cp "${SHARED_SPECS}/etc/init.d/${svc}" "${SYSROOT}/etc/init.d/${svc}"
        chmod +x "${SYSROOT}/etc/init.d/${svc}"
    done
fi
# firewalld installs /etc/init.d/firewalld; alias 'firewall' so the `after firewall`
# deps in tailscaled/kubelet/headscale/containerd/egress-vpn still resolve.
ln -sfn firewalld "${SYSROOT}/etc/init.d/firewall"
# Bake ENV-appropriate firewalld config: prod = hardened (DefaultZone=drop, tailscale0-only
# via trusted.xml), test = permissive (DefaultZone=trusted) so CI harnesses can connect
# without a tailnet.
if [ "${ENV}" = "prod" ]; then
    cp "${SHARED_SPECS}/etc/firewalld/firewalld-prod.conf" "${SYSROOT}/etc/firewalld/firewalld.conf"
else
    cp "${SHARED_SPECS}/etc/firewalld/firewalld-test.conf" "${SYSROOT}/etc/firewalld/firewalld.conf"
fi
cp "${SHARED_SPECS}/etc/firewalld/zones/trusted.xml" "${SYSROOT}/etc/firewalld/zones/trusted.xml"

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

# KEYS-USB provisioning engine
mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/var/lib/keys-provision"
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh"      "${SYSROOT}/usr/sbin/keys-provision"
chmod +x "${SYSROOT}/usr/sbin/keys-provision"

# Backup engine (etcd + PostgreSQL -> attached storage / network share)
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-backup"     "${SYSROOT}/usr/local/sbin/snapdragon-backup"
chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-backup"

# Opt-in host-binary auto-update poller + OpenRC boot oneshot (baked as PLUMBING).
# The poller pulls changed binpkgs (deltas) from the node's PORTAGE_BINHOST and
# kured-safe-reboots, but is DEFAULT-OFF: provision_update() bakes the /etc/cron.d
# cadence timer + the boot oneshot is linked below, yet each poll SKIPS until a
# superadmin sets enabled:true in the snapdragon-update-policy ConfigMap (fail-safe
# to off). cronie + OpenRC (not systemd).
cp "${SHARED_SPECS}/usr/local/sbin/snapdragon-update"     "${SYSROOT}/usr/local/sbin/snapdragon-update"
chmod +x "${SYSROOT}/usr/local/sbin/snapdragon-update"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-update"         "${SYSROOT}/etc/init.d/snapdragon-update"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-update"

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

# ── Egress VPN (split-tunnel, fail-closed) — node-level, DEFAULT-OFF ────────────
# Bake the OpenRC service + the split-tunnel runner into every node image. They
# are INERT until enabled: the service is NOT linked into a runlevel here (the
# optional-services gate / signed reconcile enables it), and with no
# /etc/snapdragon/vpn/active.conf the runner is a no-op. Baking unconditionally
# does NOT alter egress on a node that never selects the VPN.
cp "${SHARED_SPECS}/etc/init.d/snapdragon-egress-vpn" "${SYSROOT}/etc/init.d/snapdragon-egress-vpn"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-egress-vpn"
cp "${SHARED_SPECS}/usr/sbin/snapdragon-vpn-runner"   "${SYSROOT}/usr/sbin/snapdragon-vpn-runner"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-vpn-runner"
mkdir -p "${SYSROOT}/etc/snapdragon/vpn"; chmod 0700 "${SYSROOT}/etc/snapdragon/vpn"

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

# ── Tor v3 onion (hidden) service (signed-export-free; keypair minted first-boot) — DEFAULT-OFF ─
# Bake the onion-service reconcile agent + its OpenRC oneshot + the 24h cron into every
# node image. INERT until enabled: the optional-services gate links the DISTRO `tor`
# service + this reconcile agent ONLY when 'tor' is selected (net-vpn/tor is added then).
# The agent (ordered `before tor`) writes the managed /etc/tor/torrc + mints/persists the
# v3 onion keypair OFF-GIT under /var/lib/tor/snapdragon-onion. The cron drop-in is STAGED
# at /etc/snapdragon/registry (the gate places it into /etc/cron.d on selection).
cp "${SHARED_SPECS}/usr/sbin/snapdragon-tor-reconcile"   "${SYSROOT}/usr/sbin/snapdragon-tor-reconcile";   chmod +x "${SYSROOT}/usr/sbin/snapdragon-tor-reconcile"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-tor-reconcile" "${SYSROOT}/etc/init.d/snapdragon-tor-reconcile"; chmod +x "${SYSROOT}/etc/init.d/snapdragon-tor-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-tor-reconcile"  "${SYSROOT}/etc/snapdragon/registry/cron-tor-reconcile"

# ── Domain-registry -> brand-repo bridge (#4) — DEFAULT-OFF optional service ─────
# Bake the reconcile agent + its source-and-extend verify lib (domain-verify.sh) +
# the OpenRC service into every node image. INERT until enabled: the gate below
# links the service + cron ONLY when `domain-registry-bridge` is selected; absent a
# real key the verify fail-closes; absent transport it keeps cache + emits nothing.
# REUSES the baked registry-pub.ed25519 (Layer-B's key — never re-bake). The agent
# drives the EXISTING gen-keystores.sh + generate-brand-repos.sh, so those two
# generators are baked under /usr/share/snapdragon/generator for the agent to exec.
# The cron drop-in is STAGED at /etc/snapdragon/registry (gate places it on select),
# mirroring the device-registry-sync / vpn-reconcile staging.
cp "${SHARED_SPECS}/usr/sbin/snapdragon-domain-reconcile" "${SYSROOT}/usr/sbin/snapdragon-domain-reconcile"
chmod +x "${SYSROOT}/usr/sbin/snapdragon-domain-reconcile"
cp "${SHARED_SPECS}/usr/lib/snapdragon/domain-verify.sh" "${SYSROOT}/usr/lib/snapdragon/domain-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/snapdragon-domain-reconcile" "${SYSROOT}/etc/init.d/snapdragon-domain-reconcile"
chmod +x "${SYSROOT}/etc/init.d/snapdragon-domain-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/snapdragon-domain-reconcile" "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile"
# The two build-time generators the bridge drives at runtime (read-only payload).
mkdir -p "${SYSROOT}/usr/share/snapdragon/generator/scripts" "${SYSROOT}/usr/share/snapdragon/generator/templates"
cp "${SCRIPT_DIR}/scripts/gen-keystores.sh"     "${SYSROOT}/usr/share/snapdragon/generator/scripts/gen-keystores.sh"
cp "${SCRIPT_DIR}/generate-brand-repos.sh"      "${SYSROOT}/usr/share/snapdragon/generator/generate-brand-repos.sh"
cp -r "${SCRIPT_DIR}/templates/."               "${SYSROOT}/usr/share/snapdragon/generator/templates/"
chmod +x "${SYSROOT}/usr/share/snapdragon/generator/scripts/gen-keystores.sh" "${SYSROOT}/usr/share/snapdragon/generator/generate-brand-repos.sh"

mkdir -p "${SYSROOT}/etc/snapdragon"
echo "${ROLE}"           > "${SYSROOT}/etc/snapdragon/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/snapdragon/cluster-domain"
# Orchestration superdomain (WS-SUPER-B): record the mesh plane the image joins.
if [ -n "${SUPERDOMAIN}" ]; then
    echo "${SUPERDOMAIN}" > "${SYSROOT}/etc/snapdragon/superdomain"
    info "Baked orchestration superdomain -> /etc/snapdragon/superdomain (${SUPERDOMAIN})"
fi
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
if ${STANDALONE}; then
    # STANDALONE desktop: bake the marker so keys-provision skips all
    # mesh-seeking no-ops and a normal LOCAL USER logs in with the build-set
    # password (mirrors build-x86-host-stage4.sh). Only --role desktop can set
    # STANDALONE (guarded above).
    #
    # NOTE: a --role desktop build WITHOUT --standalone deliberately does NOT
    # write this marker (it wants headscale/tailscale mesh join). That means
    # provision.sh's non-standalone k8s block (provision_kubernetes/_calico/
    # _vault/_backup/_update/_snapdragon) still runs on a ROLE_CLIENT sysroot
    # with no containerd/kubeadm/kubelet binaries and no cluster tree — this
    # is safe ONLY because each of those functions self-guards on binary/
    # kubeconfig/manifest-key presence; keep that guard when touching them.
    echo "true" > "${SYSROOT}/etc/snapdragon/standalone"
    info "Standalone desktop: local user '${DEFAULT_USER}', no mesh."
fi
# The cluster GitOps tree (ArgoCD/Casdoor apps) is meaningless on a client
# desktop — it never runs kubeadm/joins the cluster — so skip it for
# --role desktop (ROLE_CLIENT), same as the containerd/kubelet config above.
if ! ${ROLE_CLIENT} && [ -d "${SHARED_SPECS}/cluster" ]; then
    mkdir -p "${SYSROOT}/var/lib/snapdragon"
    cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/snapdragon/cluster"
    info "Installed cluster GitOps payload (role=${ROLE})"
    # Only parameterize the games host URLs when games is actually selected; when
    # games is opt-out (default) gate_optional_services prunes it below anyway.
    case " ${OPTIONAL_SERVICES} " in
        *" games "*) parameterize_games_domain ;;  # rewrite .games -> ${GAMES_DOMAIN} (BEFORE rebrand; fixes games OIDC iss on the subdomain default)
    esac
    gate_env_apps              # prune ENV-specific ArgoCD apps from the baked copy
    bake_host_firewall         # Layer 3: host nftables backstop for RELEASE_STATE (independent of gate_env_apps' K8s-manifest layer)
    gate_optional_services     # prune OPTIONAL services (akkoma/tuwunel/phpbb/games) not in OPTIONAL_SERVICES
    gate_backing_services      # MANAGED backing services: prune in-mesh datastore + repoint consumer at hosted endpoint (empty selection = no-op)
fi

# Apply the configured brand/domain to the baked tree (no-op for defaults).
# Runs AFTER gate_env_apps so the surviving lan-dns/cloudflared manifests get
# their snapdragon.systems -> ${CLUSTER_DOMAIN} rewrite too.
rebrand_sysroot
# I6.3: AFTER rebrand — idp.conf bake + issuer/JWKS rewrite + Casdoor-app gating +
# README-IDP.md. casdoor default = guaranteed no-op (byte-identity).
apply_idp_external

mkdir -p "${SYSROOT}/etc/local.d"
[ -f "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" ] || {
    err "missing first-boot finaliser template: ${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl"; exit 1; }
render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"

# Hostname, timezone, locale
echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
mkdir -p "${SYSROOT}/etc/conf.d"
echo "hostname=\"${HOSTNAME}\"" > "${SYSROOT}/etc/conf.d/hostname"
echo "${TIMEZONE}" > "${SYSROOT}/etc/timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${SYSROOT}/etc/localtime"
echo "en_US.UTF-8 UTF-8" > "${SYSROOT}/etc/locale.gen"

# CNI / containerd directories — cluster-node roles only.
if ! ${ROLE_CLIENT}; then
    mkdir -p "${SYSROOT}/opt/cni/bin"
    mkdir -p "${SYSROOT}/etc/cni/net.d"
    mkdir -p "${SYSROOT}/etc/containerd/certs.d"
fi

# OpenRC service links
mkdir -p "${SYSROOT}/etc/runlevels/default"
# growroot expands the root fs to fill the medium on first boot; it orders itself
# before keys-provision so provisioning sees the full disk (no-op in containers).
DEFAULT_SVCS=(sshd NetworkManager cronie haveged growroot keys-provision firewall auditd local)
if ! ${ROLE_CLIENT}; then
    # snapdragon-firewall-reconcile's files are only ever baked for cluster-node
    # roles (bake_host_firewall() is called from inside the `! ROLE_CLIENT &&
    # -d cluster` block above) — enabling the service here too, never on the
    # desktop branch below, mirrors build-x86-host-stage4.sh's own SVCS split.
    DEFAULT_SVCS+=(snapdragon-firewall-reconcile snapdragon-go-live-reconcile containerd kubelet)
else
    # Desktop session bring-up: dbus + elogind (seat/login manager) + the
    # display-manager OpenRC service (provided by gui-libs/display-manager-init,
    # configured via /etc/conf.d/display-manager below). Mirrors
    # build-frite-stage4.sh/build-jetson-stage4.sh's DESKTOP=light wiring.
    DEFAULT_SVCS+=(dbus elogind display-manager)
    mkdir -p "${SYSROOT}/etc/conf.d"
    echo 'DISPLAYMANAGER="lightdm"' > "${SYSROOT}/etc/conf.d/display-manager"
    # Wire the greeter + default session explicitly: with only lightdm-gtk-greeter
    # installed the stock greeter-session (example-gtk-gnome) is absent -> blank
    # greeter. Mirrors build-frite-stage4.sh/build-jetson-stage4.sh's identical fix.
    mkdir -p "${SYSROOT}/etc/lightdm"
    cat > "${SYSROOT}/etc/lightdm/lightdm.conf" <<'LIGHTDM'
[LightDM]
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=LXDE
LIGHTDM
fi
# Opt-in host-binary auto-update: link the boot oneshot + cadence cron into the
# default runlevel as PLUMBING (every node), but the poller is DEFAULT-OFF / INERT —
# it pulls nothing until a superadmin sets enabled:true in the snapdragon-update-policy
# ConfigMap (fail-safe-to-OFF: an absent/unreachable policy => NO pull).
DEFAULT_SVCS+=(snapdragon-update)
# headscale runs on the PKI/identity node (and on a generic all-in-one image)
if [ "${ROLE}" = "pki" ] || [ "${ROLE}" = "generic" ]; then
    DEFAULT_SVCS+=(headscale)
fi
# tailscale client everywhere unless the mesh / client is skipped
if ! ${SKIP_MESH} && ! ${SKIP_TAILSCALE}; then
    DEFAULT_SVCS+=(tailscaled)
fi
# Egress VPN (DEFAULT-OFF optional service): link the signed-export RECONCILE
# agent into the default runlevel ONLY when egress-vpn is selected. The
# snapdragon-egress-vpn service itself is NOT linked here — the reconcile agent
# enables it (rc-update add) once a verified assignment lands, so a selected-but-
# unassigned node carries the agent + an inert service (no tunnel, no leak). The
# 60s reconcile cron drop-in (staged at /etc/snapdragon/registry/cron-vpn-reconcile)
# is installed alongside.
if _opt_selected egress-vpn; then
    DEFAULT_SVCS+=(snapdragon-vpn-reconcile)
    if [ -f "${SYSROOT}/etc/snapdragon/registry/cron-vpn-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/snapdragon/registry/cron-vpn-reconcile" \
              "${SYSROOT}/etc/cron.d/snapdragon-vpn-reconcile"
        info "OPTIONAL_SERVICES: egress-vpn selected — linked snapdragon-vpn-reconcile + 60s cron"
    fi
fi
# Tor v3 onion (hidden) service (DEFAULT-OFF optional service): link ONLY the snapdragon
# reconcile agent into the default runlevel when 'tor' is selected (net-vpn/tor is added
# to the package set then, see below) — mirroring egress-vpn, which links only its
# reconcile agent, not the daemon. The DISTRO `tor` service is NOT linked here: the
# reconcile agent OWNS tor's lifecycle (writes the managed torrc, mints the v3 onion
# keypair OFF-GIT under /var/lib/tor/snapdragon-onion, then `rc-service tor restart`),
# avoiding any double-start. The 24h refresh cron (staged at
# /etc/snapdragon/registry/cron-tor-reconcile) is installed alongside. Unselected =>
# reconcile not linked + net-vpn/tor absent.
if _opt_selected tor; then
    DEFAULT_SVCS+=(snapdragon-tor-reconcile)
    if [ -f "${SYSROOT}/etc/snapdragon/registry/cron-tor-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/snapdragon/registry/cron-tor-reconcile" \
              "${SYSROOT}/etc/cron.d/snapdragon-tor-reconcile"
        info "OPTIONAL_SERVICES: tor selected — linked snapdragon-tor-reconcile + 24h cron (reconcile agent owns the tor daemon)"
    fi
fi
# Domain-registry -> brand-repo bridge (#4, DEFAULT-OFF optional service): link the
# signed-export RECONCILE agent into the default runlevel ONLY when the
# `domain-registry-bridge` service is selected. When unselected the OpenRC service
# is never linked and no cron drop-in exists -> ZERO boot/cron execution (gate 1 of
# 3; the placeholder-key + no-transport gates fail-close the rest). The 60s cron
# (staged at /etc/snapdragon/registry/cron-domain-reconcile) is installed alongside.
if _opt_selected domain-registry-bridge; then
    DEFAULT_SVCS+=(snapdragon-domain-reconcile)
    if [ -f "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile" ]; then
        mkdir -p "${SYSROOT}/etc/cron.d"
        cp -f "${SYSROOT}/etc/snapdragon/registry/cron-domain-reconcile" \
              "${SYSROOT}/etc/cron.d/snapdragon-domain-reconcile"
        info "OPTIONAL_SERVICES: domain-registry-bridge selected — linked snapdragon-domain-reconcile + 60s cron"
    fi
fi
for svc in "${DEFAULT_SVCS[@]}"; do
    ln -sf "/etc/init.d/${svc}" "${SYSROOT}/etc/runlevels/default/${svc}" 2>/dev/null || true
done
# Belt-and-suspenders for shared / --resume sysroots: `ln -sf` only ADDS, so a prior
# role's run (the cross-build does pki first) can leave a headscale runlevel symlink
# behind that a worker image would then background-start. Remove it for any role that
# must NOT run the control server. (Pi audit finding, 2026-06-13.)
if [ "${ROLE}" != "pki" ] && [ "${ROLE}" != "generic" ]; then
    rm -f "${SYSROOT}/etc/runlevels/default/headscale"
fi

# ── Radio hardening: WiFi + Bluetooth DISABLED BY DEFAULT ──────────────────
# Shrink the attack surface — by default neither radio comes up (modprobe.d
# blacklist + first-boot rfkill block + NM leaves WiFi unmanaged). ETHERNET +
# the Tailscale tailnet are UNTOUCHED. ENABLE_WIFI / ENABLE_BLUETOOTH re-enable.
harden_radios "${SYSROOT}"

# Root SSH login DISABLED by default (hardened). Write an AUTHORITATIVE sshd drop-in
# (00- prefix => sshd takes the FIRST PermitRootLogin value) from PERMIT_ROOT_LOGIN
# (no | prohibit-password | yes; default no). hardened.conf 'PermitRootLogin no' stays
# a fail-safe backstop; the non-root KEYS admin user is the entry point, so this never
# bricks a node. Re-enable with --permit-root-login yes.
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
        --usepkg=y --binpkg-respect-use=y \
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

# Resolved via resolve_stage4_packages() (defined above "Verifying
# prerequisites") — the SAME single-sourced resolver the qemu preflight
# consulted at t=0, so the two can never drift.
mapfile -t STAGE4_PACKAGES < <(resolve_stage4_packages)

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
_payload_bins=(NetworkManager nmcli sshd auditd crond jq parted)
# flashrom + rpi-eeprom-update only exist on --board rpi4/rpi5 — --board rpi3
# excludes dev-embedded/rpi-eeprom entirely (see the STAGE4_PACKAGES prune
# above), so neither binary is ever emerged on that board; asserting their
# presence there would fail this gate on a perfectly correct rpi3 image.
if [ "${BOARD}" != "rpi3" ]; then
    _payload_bins+=(flashrom rpi-eeprom-update)
fi
if ! ${ROLE_CLIENT}; then
    _payload_bins+=(kubelet kubeadm kubectl containerd)
else
    _payload_bins+=(Xorg openbox lxsession pcmanfm lightdm)
fi
# LUKS2 root (--encrypt-root): cryptsetup formats/opens the root at install time,
# dracut generates the disk-boot initramfs that unlocks it at boot — both are
# only conditionally emerged (cryptsetup is unconditional today, but assert it
# here too now that it's load-bearing for a NEW use case: the root, not just an
# attached data disk), so assert them explicitly rather than discovering a
# silent emerge failure only on real hardware.
${ENCRYPT_ROOT} && _payload_bins+=(cryptsetup dracut)
for _b in "${_payload_bins[@]}"; do
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
if [ "${DESKTOP}" = "light" ] && [ ! -e "${SYSROOT}/etc/init.d/display-manager" ]; then
    err "DESKTOP=light enables the 'display-manager' service but ${SYSROOT}/etc/init.d/display-manager is missing"
    err "       (gui-libs/display-manager-init did not emerge) — the desktop would boot to a console. Aborting."
    exit 1
fi
info "Stage4 payload verified (${_payload_bins[*]})"

# ── 7a. Boot config (AFTER firmware is merged) ─────────────────────
# Written now — not in the spec-install phase — so raspberrypi-firmware's
# pkg_preinst didn't die on a pre-existing /boot/config.txt|cmdline.txt. Our
# templated versions are authoritative and overlay the firmware's defaults.
if [ -d "${SYSROOT}/boot" ]; then
    render_template "${SPECS_DIR}/boot/config.txt.tmpl"   "${SYSROOT}/boot/config.txt"
    render_template "${SPECS_DIR}/boot/cmdline.txt.tmpl"  "${SYSROOT}/boot/cmdline.txt"
    info "Boot config written (config.txt + cmdline.txt) over the firmware defaults"
fi

if ${SKIP_MESH}; then
    banner "Phase 2.5: SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Phase 2.5: Installing mesh VPN (headscale + tailscale)"

    # Pinned versions (HEADSCALE_VERSION / TAILSCALE_VERSION) + publisher checksum
    # verification: headscale releases ship checksums.txt; tailscale ships a
    # <tgz>.sha256 sidecar. We fetch the manifest, verify sha256, and ABORT on any
    # mismatch — a tampered binary can no longer reach the mesh runlevel. The
    # file(1) ELF-arch check is kept as cheap defense-in-depth.
    HS_REL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}"
    HS_URL="${HS_REL}/headscale_${HEADSCALE_VERSION}_linux_arm64"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
    info "Fetching headscale ${HEADSCALE_VERSION}..."
    if curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors -o "${HS_BIN}" "${HS_URL}"; then
        # Verify sha256 against the release checksums.txt BEFORE trusting it.
        HS_SUMS="${BUILD_ROOT}/headscale_${HEADSCALE_VERSION}_checksums.txt"
        if ! dlv_fetch "${HS_REL}/checksums.txt" "${HS_SUMS}" \
           || ! dlv_verify_from_sumsfile "${HS_BIN}" "headscale_${HEADSCALE_VERSION}_linux_arm64" "${HS_SUMS}" sha256; then
            rm -f "${HS_BIN}"
            err "headscale ${HEADSCALE_VERSION} checksum verification FAILED — refusing to ship an unverified control-plane binary."
            exit 1
        fi
        chmod +x "${HS_BIN}"
        file "${HS_BIN}" | grep -q 'ELF.*aarch64' || {
            rm -f "${HS_BIN}"
            err "headscale binary is not aarch64 — check --headscale-version"
            exit 1
        }
        info "headscale installed + sha256-verified: /usr/bin/headscale"
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
        if curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors -o "${TS_TGZ}" "${TS_URL}"; then
            # Verify sha256 against the published <tgz>.sha256 sidecar BEFORE extracting.
            TS_SHA="${TS_TGZ}.sha256"
            if ! dlv_fetch "${TS_URL}.sha256" "${TS_SHA}" \
               || ! dlv_verify_sha256_sidecar "${TS_TGZ}" "${TS_SHA}"; then
                rm -f "${TS_TGZ}"
                err "tailscale ${TAILSCALE_VERSION} checksum verification FAILED — refusing to ship an unverified mesh client."
                exit 1
            fi
            TS_TMP="$(mktemp -d)"
            tar -C "${TS_TMP}" -xzf "${TS_TGZ}"
            TS_SUB="$(find "${TS_TMP}" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
            install -Dm0755 "${TS_SUB}/tailscale"  "${SYSROOT}/usr/bin/tailscale"
            install -Dm0755 "${TS_SUB}/tailscaled" "${SYSROOT}/usr/sbin/tailscaled"
            rm -rf "${TS_TMP}"
            info "tailscale installed + sha256-verified: /usr/bin/tailscale, /usr/sbin/tailscaled"
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
        info "Board: ${BOARD_DESC}  Defconfig: ${RPI_DEFCONFIG}  CPU: ${RPI_CPU}"
        # hardened-k8s.config is the UNIVERSAL base fragment (applied to every
        # role AND board, cluster node or desktop, Pi 3/4/5 — same pattern
        # build-x86-host-stage4.sh's own identically-misnamed "hardened-k8s.config"
        # and build-jetson-stage4.sh's hardened-node.config already use). It still
        # carries the Pi 4/5-only PCIE_BRCMSTB/USB_XHCI_* lines UNCONDITIONALLY —
        # on --board rpi3 these are deliberately left as harmless dead Kconfig
        # weight (no matching hardware to bind to) rather than restructured out,
        # matching this codebase's existing tolerance for "compiles but never
        # binds" config elsewhere; see bcm2837-pi3.config's header for the
        # reasoning. The BOARD-specific hardware fragment (rp1-pi5.config's
        # RP1-exclusive NVMe/pinctrl/I2C-SPI/camera-ADC bits for --board rpi5,
        # bcm2711-pi4.config's native Broadcom I2C/SPI/pinctrl for --board rpi4,
        # or bcm2837-pi3.config's DWC2 USB/USB-Ethernet/BCM2835 GPIO-header bits
        # for --board rpi3) is applied next — additive, NEVER more than one
        # board's fragment (the boards' southbridge/USB hardware is mutually
        # exclusive). desktop.config is purely ADDITIVE (input/HID/sound),
        # applied LAST, ONLY for --role desktop, on ANY board.
        _kernel_fragments=("${SPECS_DIR}/kernel/hardened-k8s.config")
        case "${BOARD}" in
            rpi5) _kernel_fragments+=("${SPECS_DIR}/kernel/rp1-pi5.config") ;;
            rpi4) _kernel_fragments+=("${SPECS_DIR}/kernel/bcm2711-pi4.config") ;;
            rpi3) _kernel_fragments+=("${SPECS_DIR}/kernel/bcm2837-pi3.config") ;;
        esac
        ${ROLE_CLIENT} && _kernel_fragments+=("${SPECS_DIR}/kernel/desktop.config")
        info "Config fragments: ${_kernel_fragments[*]}"
        pushd "${KERNEL_SRC}" >/dev/null

        # Start from board defconfig
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" "${RPI_DEFCONFIG}"

        # Apply each config fragment from spec file, in order
        for _frag in "${_kernel_fragments[@]}"; do
            while IFS= read -r line; do
                # Skip comments and blank lines
                [[ "${line}" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${line// }" ]] && continue

                # Parse: "enable CONFIG_FOO" / "module CONFIG_FOO" / etc.
                read -r action rest <<< "${line}"
                eval "scripts/config --${action} ${rest}"
            done < "${_frag}"
        done

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
        # Mirror the x86 build's k8s node-kernel guard: refuse to ship a Pi kernel
        # that silently lost a netfilter/NAT/eBPF/container-IPC symbol to an
        # olddefconfig prune (unmet dep on a board-defconfig bump). This is the
        # FULL load-bearing set the fragment adds, NOT a subset — olddefconfig
        # prunes per-LEAF, so a surviving parent does not protect a dropped leaf.
        # Kept IDENTICAL (modulo ${must}/\${must} escaping) to the
        # build-x86-host-stage4.sh guard + tests/scripts/test-x86-kernel-net-symbols.sh.
        for must in CONFIG_NETFILTER_XTABLES \
                    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_NETFILTER_XT_MATCH_COMMENT \
                    CONFIG_NETFILTER_XT_MATCH_CONNTRACK CONFIG_NETFILTER_XT_MATCH_MARK \
                    CONFIG_NETFILTER_XT_MATCH_MULTIPORT CONFIG_NETFILTER_XT_MATCH_STATISTIC \
                    CONFIG_NETFILTER_XT_TARGET_MARK CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
                    CONFIG_NETFILTER_XT_TARGET_REDIRECT \
                    CONFIG_NETFILTER_XTABLES_LEGACY CONFIG_IP_NF_IPTABLES_LEGACY \
                    CONFIG_IP6_NF_IPTABLES_LEGACY \
                    CONFIG_IP_NF_MANGLE CONFIG_NF_NAT CONFIG_NF_NAT_MASQUERADE \
                    CONFIG_NF_TABLES CONFIG_NF_TABLES_IPV4 CONFIG_NF_TABLES_IPV6 \
                    CONFIG_NFT_NAT CONFIG_NFT_MASQ CONFIG_NFT_CT \
                    CONFIG_IP6_NF_IPTABLES CONFIG_IP6_NF_FILTER CONFIG_IP6_NF_NAT \
                    CONFIG_IP6_NF_MANGLE \
                    CONFIG_VLAN_8021Q CONFIG_NET_L3_MASTER_DEV CONFIG_NET_SCH_HTB \
                    CONFIG_NET_CLS_CGROUP \
                    CONFIG_IP_VS CONFIG_VXLAN CONFIG_VETH CONFIG_BRIDGE \
                    CONFIG_OVERLAY_FS CONFIG_OVERLAY_FS_REDIRECT_DIR CONFIG_OVERLAY_FS_INDEX \
                    CONFIG_CGROUP_NET_CLASSID CONFIG_CGROUP_NET_PRIO CONFIG_CGROUP_HUGETLB \
                    CONFIG_CGROUP_PERF CONFIG_CGROUP_WRITEBACK \
                    CONFIG_FAIR_GROUP_SCHED \
                    CONFIG_BPF_SYSCALL CONFIG_BPF_EVENTS \
                    CONFIG_POSIX_MQUEUE; do
            grep -q "^${must}=y" .config || { err "k8s node kernel option ${must} not enabled after olddefconfig (Service/kube-proxy/CNI/container-runtime would be impaired)"; exit 1; }
        done
        grep -q '^CONFIG_LSM="lockdown,yama,selinux,bpf"$' .config || { err "CONFIG_LSM malformed (expected lockdown,yama,selinux,bpf); lockdown/SELinux would not activate"; exit 1; }
        # LUKS2/dm-crypt (hardened-k8s.config enables this unconditionally, for
        # BOTH the existing attached-disk data-partition use case and the
        # --encrypt-root path): refuse to ship a kernel that silently lost it,
        # mirroring the SELinux/KSPP guards above.
        for must in CONFIG_MD CONFIG_BLK_DEV_DM CONFIG_DM_CRYPT; do
            grep -q "^${must}=y" .config || { err "LUKS2 kernel option ${must} not enabled after olddefconfig (a LUKS2 root/data-partition would not unlock)"; exit 1; }
        done

        # Build
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" -j"${JOBS}" \
            Image modules dtbs

        # Install
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" \
            INSTALL_MOD_PATH="${SYSROOT}" modules_install

        # Captured here (from `make kernelrelease`) so build_disk_initramfs() can
        # point dracut --kver at the EXACT module tree this build just installed
        # under ${SYSROOT}/lib/modules/. Empty if the kernel is skipped/unbuilt.
        RPI_KVER="$(make -s ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" kernelrelease 2>/dev/null | tail -1)"

        mkdir -p "${SYSROOT}/boot/overlays"
        cp arch/arm64/boot/Image "${SYSROOT}/boot/${RPI_KERNEL_IMG}"
        cp arch/arm64/boot/dts/broadcom/${RPI_DTB_PREFIX}*.dtb "${SYSROOT}/boot/"
        cp arch/arm64/boot/dts/overlays/*.dtb* "${SYSROOT}/boot/overlays/" 2>/dev/null || true
        cp arch/arm64/boot/dts/overlays/README "${SYSROOT}/boot/overlays/" 2>/dev/null || true

        popd >/dev/null
        info "Kernel build complete."
    fi
fi

# ── LUKS2 root disk-boot initramfs (--encrypt-root) ─────────────────────────
# The RPi firmware bootloader normally goes straight from kernel to root= on
# cmdline.txt — no initramfs at all. --encrypt-root needs one to unlock the
# LUKS2 root before that root= is mounted. Generic (--no-hostonly) with the
# dracut "crypt" module, staged at ${SYSROOT}/boot/disk-initrd.img (the exact
# filename config.txt's INITRAMFS_LINE references). Same proven 3-strategy
# cross-build fallback as build-frite-stage4.sh's build_disk_initramfs()
# (qemu-chroot / host-sh dracut / host dracut binary) — ported here since this
# is the FIRST time this board needs a dracut initramfs at all (the RPi
# firmware boots the kernel directly otherwise).
RPI_DISK_INITRD=""        # set non-empty once the disk-boot initramfs is staged
build_disk_initramfs() {
    [ -f "${SYSROOT}/boot/${RPI_KERNEL_IMG}" ] || {
        warn "no kernel in sysroot boot — cannot build the disk-boot initramfs; an --encrypt-root install would NOT boot."
        return 1; }
    local kver="${RPI_KVER}"
    if [ -z "${kver}" ] || [ ! -d "${SYSROOT}/lib/modules/${kver}" ]; then
        kver="$(find "${SYSROOT}/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
    fi
    [ -n "${kver}" ] && [ -d "${SYSROOT}/lib/modules/${kver}" ] || {
        warn "no module tree under ${SYSROOT}/lib/modules — cannot build the disk-boot initramfs; an --encrypt-root install would NOT boot."
        return 1; }

    local out="${SYSROOT}/boot/disk-initrd.img"
    info "Generating disk-boot initramfs (dracut --add crypt, kver=${kver}) ..."

    local sysroot_dracut="${SYSROOT}/usr/bin/dracut"

    # Ensure qemu-aarch64 is registered in binfmt_misc (idempotent, non-fatal).
    # binfmt_misc is kernel-global and does NOT survive `docker build` into a
    # fresh `docker run`, so the registration must happen here at run time (in a
    # --privileged container). Without this, Strategy 1's guard below is empty and
    # only the unusable host fallbacks (S2/S3) remain. See _dracut-cross-lib.sh.
    dracut_cross_register_qemu || true

    # ── Strategy 1: qemu-chroot (correct for cross-builds) ─────────────────────
    local _qemu_interp
    _qemu_interp="$(grep '^interpreter' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null | awk '{print $2}')"
    if [ -n "${_qemu_interp}" ] && [ -x "${_qemu_interp}" ] && [ -x "${sysroot_dracut}" ]; then
        local _mounts=() _qemu_staged=false
        _rpi_disk_umount() {
            local m
            for m in "${_mounts[@]}"; do umount -l "${m}" 2>/dev/null || true; done
            ${_qemu_staged} && rm -f "${SYSROOT}${_qemu_interp}" 2>/dev/null || true
        }
        trap '_rpi_disk_umount' RETURN
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
        # Capture into a var first, THEN head — piping the chroot directly into
        # `head -60` under pipefail risks SIGPIPE-killing dracut mid-generation
        # if it logs more than 60 lines (routine in a minimal cross-arch
        # sysroot), truncating a run that would otherwise have succeeded.
        _dracut_out="$(chroot "${SYSROOT}" /usr/bin/dracut --force --no-hostonly \
            --add crypt --kver "${kver}" /boot/disk-initrd.img 2>&1)"
        printf '%s\n' "${_dracut_out}" | head -60
        if [ -s "${SYSROOT}/boot/disk-initrd.img" ]; then
            RPI_DISK_INITRD="${out}"
            _rpi_disk_umount; trap - RETURN
            info "Disk-boot initramfs staged (qemu-chroot): ${out} ($(du -h "${out}" | cut -f1))"
            return 0
        fi
        warn "qemu-chroot dracut did not produce a disk-boot initramfs; falling back."
        _rpi_disk_umount; trap - RETURN
    fi

    # ── Strategy 2: run the sysroot dracut script on the host sh ───────────────
    if [ -x "${sysroot_dracut}" ] && command -v sh >/dev/null; then
        sh "${sysroot_dracut}" --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                RPI_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce a disk-boot initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                RPI_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
    fi
    warn "Could not generate the disk-boot initramfs (no usable dracut). An"
    warn "--encrypt-root install would be UNBOOTABLE without it."
    return 1
}
if ${ENCRYPT_ROOT} && ${BUILD_ISO}; then
    build_disk_initramfs || true
    if [ -z "${RPI_DISK_INITRD}" ] || [ ! -s "${RPI_DISK_INITRD}" ]; then
        err "--encrypt-root requires the disk-boot initramfs (see warnings above) — refusing to build a payload that cannot boot an encrypted root."
        exit 1
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

    # Locale data: keep en/en_US/POSIX, prune the rest (~50 MiB of LC archives).
    find "${SYSROOT}"/usr/share/locale -maxdepth 1 -mindepth 1 -type d \
         ! -name 'en' ! -name 'en_US' ! -name 'POSIX' \
         -exec rm -rf {} + 2>/dev/null || true
    find "${SYSROOT}"/usr/lib/locale -maxdepth 1 -mindepth 1 -type d \
         ! -name 'en_US.utf8' ! -name 'C.utf8' \
         -exec rm -rf {} + 2>/dev/null || true

    # Static libraries: already linked into binaries; not needed at runtime.
    find "${SYSROOT}"/usr/lib{,64} -name '*.a' -delete 2>/dev/null || true

    # Python bytecode cache: reproducible from source; not needed at runtime.
    find "${SYSROOT}" -name '*.pyc' -delete 2>/dev/null || true
    find "${SYSROOT}" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

    # Strip debug symbols from kernel modules (~30-60% size reduction per .ko).
    find "${SYSROOT}"/lib/modules -name '*.ko' \
         -exec "${CROSS_TARGET}-strip" --strip-debug {} \; 2>/dev/null || true

    # Strip ELF binaries (cross-strip for aarch64 target).
    find "${SYSROOT}"/{usr/bin,usr/sbin,usr/lib64,lib64} \
        -type f -executable 2>/dev/null | while read -r f; do
        file "$f" | grep -q 'ELF.*aarch64' && "${CROSS_TARGET}-strip" --strip-unneeded "$f" 2>/dev/null || true
    done

    info "Sysroot cleaned: locale/static-libs/pyc/ko-dbg/elf stripped."
fi

banner "Phase 4: Packaging stage4 tarball"

STAGE4_TARBALL="${WORK_DIR}/${BRAND}-${BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}.stage4.tar.xz"

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

    IMG_PATH="${WORK_DIR}/${BRAND}-${BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}.img"

    # 1MiB alignment gap + 512MiB FAT boot + ROOT_MiB ext4 root + 1MiB slack.
    img_size_mib=$(( 1 + 512 + ROOT_MiB + 1 ))

    # Pre-flight (fail in seconds, not after a long extraction): does the finished
    # payload fit the ROOT_MiB root partition? Converts the cryptic mid-tar "No space
    # left on device" into an upfront, actionable error. Mirrors the x86 builder.
    local payload_mib cap_mib
    payload_mib="$(du -sxBM "${SYSROOT}" 2>/dev/null | cut -f1 | tr -dc '0-9')"
    cap_mib=$(( ROOT_MiB * 93 / 100 ))   # ext4 metadata + 5% reserved ≈ 7% overhead
    if [ -n "${payload_mib}" ] && [ "${payload_mib}" -gt "${cap_mib}" ]; then
        err "Payload ${payload_mib} MiB exceeds the ${ROOT_MiB} MiB root partition (usable ~${cap_mib} MiB)."
        err "Re-run with a bigger root, e.g.  --img-size $(( (payload_mib * 115 / 100 / 1024 + 1) * 1024 ))"
        exit 1
    fi
    info "Pre-flight: payload ${payload_mib:-?} MiB fits the ${ROOT_MiB} MiB root (usable ~${cap_mib} MiB)"

    # Teardown helper — registered on ERR/EXIT so a failure mid-build never leaks
    # a mounted filesystem or an orphaned loop device.
    _img_cleanup() {
        local rc=$?
        set +e
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}/boot" && umount "${root_mnt}/boot"
        [ -n "${root_mnt}" ] && mountpoint -q "${root_mnt}" && umount "${root_mnt}"
        [ -n "${loop}" ] && { losetup "${loop}" &>/dev/null && losetup -d "${loop}"; rm -f "${loop}p1" "${loop}p2" 2>/dev/null; }
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

    # Pre-create a pool of loop nodes — the container ships only /dev/loop0 and has
    # no udev, so `losetup --find` for additional images fails "device node lost".
    local _ln
    for _ln in $(seq 0 31); do
        [ -e "/dev/loop${_ln}" ] || mknod "/dev/loop${_ln}" b 7 "${_ln}" 2>/dev/null || true
    done

    loop="$(losetup --show -fP "${IMG_PATH}")"
    boot_part="${loop}p1"
    root_part="${loop}p2"
    # losetup -P scans the partition table into /sys, but with no udev in the
    # container it never creates the /dev/loopNp1/p2 CHILD nodes — mkfs/mount then
    # fail on a missing node and a HOLLOW image is shipped with exit 0. Materialise
    # the child nodes from /sys using the kernel-assigned major:minor.
    local _lbn _pn _pdev _pmaj _pmin
    _lbn="$(basename "${loop}")"
    for _pn in 1 2; do
        _pdev="$(cat "/sys/block/${_lbn}/${_lbn}p${_pn}/dev" 2>/dev/null)"   # "MAJ:MIN"
        if [ -n "${_pdev}" ]; then
            _pmaj="${_pdev%%:*}"; _pmin="${_pdev##*:}"
            [ -e "${loop}p${_pn}" ] || mknod "${loop}p${_pn}" b "${_pmaj}" "${_pmin}"
        fi
    done
    udevadm settle &>/dev/null || true
    [ -b "${boot_part}" ] && [ -b "${root_part}" ] \
        || { err "loop partition nodes not created (${boot_part}/${root_part}) — refusing to image"; exit 1; }

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

    # Anti-hollow assert: the extraction must have produced a real rootfs (the
    # container-loop bug class silently shipped EMPTY images with exit 0). Require
    # kernel modules + an init. (The Pi kernel itself lives on the FAT /boot, not
    # in the rootfs, and is asserted separately by the DTB/firmware checks below.)
    { [ -d "${root_mnt}/usr/lib/modules" ] && [ -n "$(ls -A "${root_mnt}/usr/lib/modules" 2>/dev/null)" ] \
        && { [ -x "${root_mnt}/sbin/init" ] || [ -L "${root_mnt}/sbin/init" ]; }; } \
        || { err "rootfs empty/incomplete after stage4 extraction (no modules/init) — refusing to ship a HOLLOW .img"; exit 1; }

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
    # The .img's root is ALWAYS plaintext (written directly, no install step —
    # see the --encrypt-root warning above), so it must never reference the
    # disk-boot dracut initramfs even if this run also built the encrypted
    # installer ISO: that initramfs isn't staged onto this boot partition at
    # all, and referencing a missing file is needless boot-console noise.
    sed -i -E 's/^initramfs .* followkernel$/# &/' "${root_mnt}/boot/config.txt"

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
        local fs_tar="${WORK_DIR}/${BRAND}-${BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}.fs.tar.xz"
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
    rm -f "${loop}p1" "${loop}p2" 2>/dev/null; losetup -d "${loop}"; loop=""

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

    # LUKS2 root (--encrypt-root): stage the disk-boot dracut initramfs + the
    # encrypt-root marker (install.sh reads it to default --encrypt on) + an
    # optional seeded passphrase (0600; unattended installs only — omit it for
    # an interactive on-target prompt, mirrors install-frite.sh/install-x86.sh).
    if ${ENCRYPT_ROOT}; then
        [ -n "${RPI_DISK_INITRD}" ] && [ -s "${RPI_DISK_INITRD}" ] || {
            err "--encrypt-root requires the disk-boot initramfs but none was staged — refusing to ship an installer that cannot boot an encrypted root."
            exit 1
        }
        cp "${RPI_DISK_INITRD}" "${ISO_DIR}/boot/disk-initrd.img"
        touch "${ISO_DIR}/encrypt-root"
        if [ -n "${LUKS_PASS}" ]; then
            printf '%s' "${LUKS_PASS}" > "${ISO_DIR}/luks-passphrase"
            chmod 0600 "${ISO_DIR}/luks-passphrase"
            LUKS_PASS=""   # scrub the plaintext from the environment once seeded
            warn "Seeded LUKS passphrase written into the ISO — the 0600 mode is Rock-Ridge metadata only, NOT an access-control boundary: anyone who obtains this .iso can read the plaintext passphrase with tools that ignore POSIX modes (7z, isoinfo) or by extracting it as themselves. Treat this ISO as a secret artifact: restrict distribution and delete after provisioning."
        else
            info "No --luks-pass given: install.sh will prompt interactively on the target."
        fi
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
    # install.sh is a plain (non-templated) spec file with a few "RPi 5"/"Pi 5"
    # banner/comment mentions baked in for the historical single-board script;
    # rewrite them on the STAGED ISO copy only (never the source spec file) for
    # --board rpi4/rpi3 so the on-target installer banner ("Insert into RPi 5
    # and boot.") doesn't lie about the hardware it just installed onto.
    case "${BOARD}" in
        rpi4) sed -i -e 's/RPi 5/RPi 4/g' -e 's/Pi 5/Pi 4/g' "${ISO_DIR}/install.sh" ;;
        rpi3) sed -i -e 's/RPi 5/RPi 3/g' -e 's/Pi 5/Pi 3/g' "${ISO_DIR}/install.sh" ;;
    esac

    # Client-role marker (install.sh reads it, same pattern as encrypt-root
    # above, to skip the kubeadm-init hint in its final banner): a --role
    # desktop sysroot never gets kubeadm/kubelet/kubectl or kubeadm-config.yaml
    # (see packages-desktop.list / the ROLE_CLIENT guards above), so that
    # advice is actively wrong on this image.
    ${ROLE_CLIENT} && touch "${ISO_DIR}/client-role"

    ISO_PATH="${WORK_DIR}/${BRAND}-${BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}.iso"
    VOLID="$(echo "GENTOO_${BOARD}_${ROLE}_$(${ROLE_CLIENT} && echo CLIENT || echo K8S)" | tr '[:lower:]' '[:upper:]' | cut -c1-32)"

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
echo "  ${BOARD_DESC} Hardened $(${ROLE_CLIENT} && echo Desktop || echo "+ Kubernetes") Stage4 Complete"
echo "==============================================${RESET}"
echo ""
echo "  Board:            ${BOARD_DESC} (dtb=${RPI_DTB_PREFIX})"
echo "  Profile:          ${PROFILE_PATH}"
_kernel_banner_desc="specs-rpi5/kernel/hardened-k8s.config"
case "${BOARD}" in
    rpi5) _kernel_banner_desc="${_kernel_banner_desc} + rp1-pi5.config" ;;
    rpi4) _kernel_banner_desc="${_kernel_banner_desc} + bcm2711-pi4.config" ;;
    rpi3) _kernel_banner_desc="${_kernel_banner_desc} + bcm2837-pi3.config" ;;
esac
${ROLE_CLIENT} && _kernel_banner_desc="${_kernel_banner_desc} + desktop.config"
echo "  Kernel:           ${RPI_DEFCONFIG} + ${_kernel_banner_desc}"
echo "  Role:             ${ROLE}$(${ROLE_CLIENT} || echo "   (cluster domain: ${CLUSTER_DOMAIN})")"
echo "  ENV:              ${ENV}   $([ "${ENV}" = test ] && echo '(LAN-first: cluster wildcard DNS; cloudflared/ACME pruned)' || echo '(PROD: public domain; Cloudflare/ACME; creds from keys USB)')"
echo "  Brand:            ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}${CONFIG_FILE:+   (profile: ${CONFIG_FILE})}"
echo "  Hostname:         ${HOSTNAME}"
echo "  Timezone:         ${TIMEZONE}"
_console_desc="GPIO-header UART"
case "${BOARD}" in
    rpi5) _console_desc="RP1 UART, dedicated debug connector" ;;
    rpi3) _console_desc="GPIO-header mini-UART, shared core clock" ;;
esac
echo "  Serial console:   ${CONSOLE_UART} (${_console_desc})"
_pcie_na=""
case "${BOARD}" in
    rpi4) _pcie_na="   (n/a — no user-facing PCIe slot on the standard Pi 4 Model B)" ;;
    rpi3) _pcie_na="   (n/a — BCM2837 has no PCIe controller at all)" ;;
esac
echo "  PCIe Gen 3:       ${PCIE_GEN3}${_pcie_na}"
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
if ! ${ROLE_CLIENT}; then
echo "  Kubernetes:"
echo "    - containerd + runc (CRI runtime)"
echo "    - kubelet + kubeadm + kubectl"
echo "    - CNI plugins in /opt/cni/bin"
echo "    - Cgroup v2 + full netfilter/IPVS/eBPF stack"
echo "    - OverlayFS for container layers"
echo "    - Kubelet: anon-auth off, webhook auth, seccomp default"
echo ""
else
echo "  Desktop:"
echo "    - X11 + Openbox + LXpanel + PCManFM (lean LXDE session)"
echo "    - LightDM login manager"
echo ""
fi
# NOTE: this SKIPPED branch is new — --skip-mesh (a pre-existing, role-independent
# flag) previously still printed the full headscale/tailscale block below even
# when neither was actually installed. Deliberate behavior change/fix, not a
# regression: the banner now truthfully reflects --skip-mesh for every role.
if ${SKIP_MESH}; then
echo "  Mesh VPN + provisioning: SKIPPED (--skip-mesh$(${STANDALONE} && echo " / --standalone"))"
else
echo "  Mesh VPN + provisioning:"
echo "    - headscale ${HEADSCALE_VERSION} (control server) + tailscale ${TAILSCALE_VERSION}"
echo "    - First-boot provisioning from a USB FAT32 'KEYS' partition"
echo "      (users, ssh keys, passwords, certs, headscale/k8s config)"
echo "    - keys-provision engine: /usr/sbin/keys-provision"
fi
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
echo "  Credentials:"
if ${STANDALONE}; then
echo "    Local user '${LOCAL_USER:-$DEFAULT_USER}' logs in with the password set"
echo "    at build time (--local-pass). No mesh/KEYS-USB provisioning runs."
else
echo "    No default password is baked in. With a KEYS USB, users come from"
echo "    users.json (\$6\$ hashes). Without one, first boot mints a RANDOM"
echo "    one-time password for '${DEFAULT_USER}' (printed to the boot console)"
echo "    and LOCKS root — change it immediately."
fi
echo ""
echo "  Spec files used:"
echo "    ${SPECS_DIR}/   (aarch64/RPi-specific: ${BOARD_DESC})"
echo "    ${SHARED_SPECS}/   (arch-agnostic, shared with x86)"
echo ""
echo "  === Post-install ==="
echo "  1. Boot the ${BOARD_DESC}, change all default passwords"
echo "  2. Add SSH pubkeys to ${DEFAULT_USER} and root"
if ! ${ROLE_CLIENT}; then
echo "  3. kubeadm init --config /etc/kubernetes/kubeadm-config.yaml"
echo "  4. Install CNI (Flannel, Cilium, Calico, etc.)"
echo "  5. Join workers: kubeadm join <cp>:6443 --token <t> --discovery-token-ca-cert-hash <h>"
else
echo "  3. Log in at the LightDM greeter as '${LOCAL_USER:-$DEFAULT_USER}'"
fi
echo ""
