#!/usr/bin/env bash
# Build a hardened Gentoo aarch64 image for the NVIDIA Jetson Orin family
# (Tegra234 — Orin Nano / Orin NX developer kits) using the same crossdev
# toolchain + shared mesh/provisioning plumbing as the Pi5/Frite/x86 images.
#
# ############################################################################
# ##  STATUS: EXPERIMENTAL — HARDWARE VALIDATION PENDING                    ##
# ##  The build flow mirrors the PROVEN RPi5/Frite cross path and passes    ##
# ##  every static/dry-run check (--print-plan, bash -n, arg matrix), but   ##
# ##  no physical Orin has booted an image from this builder yet. See       ##
# ##  specs-jetson/README.md before treating any artifact as shippable.    ##
# ############################################################################
#
# WHY a separate builder (not a flag on build-rpi5-stage4.sh): the Orin boots a
# fundamentally different chain — NVIDIA UEFI (edk2-nvidia) in QSPI-NOR distro-
# booting /boot/extlinux/extlinux.conf off the root filesystem. There is NO
# raspberrypi-firmware, NO config.txt, and NO u-boot to vendor (the Frite's
# problem); the QSPI firmware is updated out-of-band (recovery-mode tegraflash —
# see specs-jetson/installer/TEGRAFLASH.md). It is also a different PURPOSE mix:
# an arm64 EDGE-AI node family (plus a desktop variant), not a lean GXL desktop.
#
# ROLES (--role):
#   edge_ai  (DEFAULT, the headline) — GPU inference k8s worker: joins the mesh
#            + cluster and hosts the arch-portable `edge-ai` service (Ollama,
#            OpenAI-compatible /v1) exactly like the x86 RTX host.
#   gpu-host — GPU k8s worker WITHOUT the inference service (be+gpu analogue).
#   full     — full-stack single node (pki+backend+frontend+gpu on one Orin;
#            the omnibus analogue: headscale control plane + kubeadm init).
#   desktop  — arm64 client desktop (lean LXDE; mesh client, no k8s).
#
# KERNEL DECISION (--kernel-flavor, see specs-jetson/kernel/README.md):
#   mainline (DEFAULT, the buildable route): gentoo-sources arm64 + the Tegra234
#            DT fragments. Boots headless-node hardware; NO CUDA (the GA10B iGPU
#            needs NVIDIA's nvgpu) — the edge-ai service runs CPU-only until the
#            node moves to the L4T stack.
#   l4t      (STUBBED): NVIDIA's L4T/BSP kernel + CUDA userspace. EULA-gated
#            downloads — documented, not automated; the builder exits with a
#            hard error pointing at specs-jetson/installer/TEGRAFLASH.md.
#
# This image JOINS THE TAILSCALE MESH exactly like the other node images: same
# shared specs/ provisioning engine (keys-provision), same headscale/tailscale
# static arm64 binaries, same hardened key-only sshd, same device-license
# registry posture. Cluster roles bake the SAME shared specs/cluster GitOps
# tree the rpi5/x86 node builders bake (the edge-ai manifests are arch-portable).
#
# Run as root (sudo): the cross-emerge merges into the sysroot's vdb and writes
# the host emerge log/cache (fakeroot is NOT enough). --print-plan needs NO root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs-jetson"   # aarch64/Tegra-specific specs
SHARED_SPECS="${SCRIPT_DIR}/specs"       # arch-agnostic specs (mesh, provisioning, sshd, cluster)

# Supply-chain download verification (OWASP) — same shared helper as the other
# builders so the stage3/headscale/tailscale fetches are GPG/checksum-verified.
# shellcheck source=scripts/_download-lib.sh
source "${SCRIPT_DIR}/scripts/_download-lib.sh"
# Shared /etc/shadow password-KDF helper (ph_crypt_hash): yescrypt ($y$) where
# the build host's libcrypt provably supports it, SHA-512 crypt ($6$) fallback.
# shellcheck source=scripts/_passhash-lib.sh
source "${SCRIPT_DIR}/scripts/_passhash-lib.sh"

# Cross-dracut helper: qemu-aarch64 binfmt registration + the availability
# predicate the --encrypt-root fail-fast preflight and the qemu-chroot initramfs
# strategy rely on. Sourced for consistency with the other ARM boards; note that
# Jetson currently hard-errors on --encrypt-root earlier (single boot+root
# partition), so the preflight/register below are inert TODAY and "just work" if
# Jetson gains a separate boot partition. See scripts/_dracut-cross-lib.sh.
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
# Seed-derived PYTHON_TARGETS/PYTHON_SINGLE_TARGET (pt_apply_seed_targets).
# A frozen python3_NN literal is a BUG — see docs/PYTHON-TARGETS-SEED-DRIFT.md.
# shellcheck source=scripts/_python-targets-lib.sh
source "${SCRIPT_DIR}/scripts/_python-targets-lib.sh"
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
# sys-kernel/gentoo-sources emerge used to warn-skip Phase 3 and exit 0 with a
# kernel-less stage4 and NO .img ("stage4 is still usable via TEGRAFLASH.md
# layering" — true only when the operator CHOSE that with --skip-kernel).
# shellcheck source=scripts/_payload-gate-lib.sh
source "${SCRIPT_DIR}/scripts/_payload-gate-lib.sh"
# shellcheck source=scripts/_dracut-cross-lib.sh
source "${SCRIPT_DIR}/scripts/_dracut-cross-lib.sh"

WORK_DIR=""
BUILD_SUBDIR="${BUILD_SUBDIR:-snap-build-jetson}"  # per-arch isolation (never shares the Pi/Frite/x86 sysroot)
DISTDIR_SRC="${SNAP_DISTDIR_SRC:-}"   # --distdir DIR / SNAP_DISTDIR_SRC env: shared READ-ONLY distfiles cache (arch-independent sources → safe fleet-wide). Empty = private per-build DISTDIR only.
PACKAGES_ONLY=false   # --packages-only: prebuild the per-board binpkg pool then exit BEFORE image assembly (kernel/img/iso/tar). Host/CI build-phase flag, NOT a Studio ImageConfig field.
# --allow-missing-packages : accept a KNOWINGLY degraded image. The payload emerge
# runs --keep-going; the requested-atom completeness gate after it then FAILS the
# build when any requested atom did not actually install. Escape hatch only —
# never a Studio field. NB: it can NOT bypass the kernel tier (a kernel-less
# image is unbootable, not degraded; --skip-kernel is the only kernel opt-out).
ALLOW_MISSING_PACKAGES=false
CROSS_TARGET="aarch64-unknown-linux-gnu"
REL_VERSION="2026.0"

# ── BOARD TABLE ────────────────────────────────────────────────────
# Selected by --board. Fills the GCC CPU + the mainline board DTB. The Orin Nano
# Super Developer Kit (the target hardware) is the default; the NX modules share
# the same carrier + flow and are listed for completeness (untested).
JETSON_BOARD="orin-nano"                 # orin-nano | orin-nano-4gb | orin-nx-8gb | orin-nx-16gb
JETSON_DEFCONFIG="defconfig"             # generic arm64 mainline defconfig
JETSON_KERNEL_IMG="Image"
KERNEL_FLAVOR="mainline"                 # mainline (buildable) | l4t (stubbed; documented)
# Board-derived values. Empty here; select_board() fills any the operator did
# NOT override on the CLI (explicit --cpu/--dtb always wins regardless of order).
RPI_CPU=""                               # Orin CPUs are Cortex-A78AE
JETSON_DTB=""
JETSON_BOARD_DESC=""

JOBS="$(nproc)"
SKIP_KERNEL=false
SKIP_CLEAN=false
RESUME=false
IMAGE_ONLY=false          # skip Phase 1-3 entirely; go straight to image assembly

ROLE="edge_ai"                           # edge_ai (DEFAULT) | gpu-host | full | desktop
DESKTOP="none"                           # derived: 'light' for --role desktop, else none
BUILD_IMG=true                           # produce the flashable raw .img (SD/NVMe); stage4 always emitted
ROOT_MiB=0                               # 0 = role default (set below); --img-size overrides
IMG_SIZE_SET=false
GROW_POLICY="fill"
COMPRESS_IMG=false
EXTRA_PACKAGES=""
PACKAGES_ADD=""          # --packages-add : atoms to add on top of the derived set
PACKAGES_DROP=""         # --packages-drop: default-set atoms to remove (mandatory floor honored)
TIMEZONE="UTC"
HOSTNAME=""
CLUSTER_DOMAIN="hugmesh.systems"
# Orchestration superdomain (WS-SUPER-B): the mesh control plane's MagicDNS suffix every
# node joins. "" = builder default (legacy byte-identical). The Studio emits --superdomain
# <effective> only for MESH builds; permanently internal, never the go-live apex.
SUPERDOMAIN=""
BRAND="hugmesh"
BRAND_TITLE="HugMesh Systems"
ORG="Snapdragon-Systems"
# ENV (test|prod) selector — same semantics as the cluster builders: it shapes
# branding/creds and gates the baked cluster tree's env apps posture.
ENV="test"
CONFIG_FILE=""
DEFAULT_USER="jetson"
# NO baked default password (fleet OWASP posture): real creds come from the KEYS
# USB; a keyless first boot mints a random one-time password + locks root.
#
# ── Standalone posture (mirrors build-x86-host-stage4.sh) ──────────
# --standalone composes onto --role desktop: no mesh, a normal local user logs
# in with a password set at build time instead of the KEYS-USB-provisioned
# account, and forces --encrypt-root (LUKS2-encrypted root).
STANDALONE=false        # --standalone : local user, no mesh, LUKS2-encrypted root
LOCAL_USER=""           # --local-user NAME : the standalone local login account
LOCAL_USER_PASS=""      # --local-pass PASS : plaintext; hashed at build, never baked raw
# ── LUKS2 root encryption — BAKE-TIME, unlike x86/Frite/RPi5's install-time
# model: the Orin has no separate installer step (build_img() IS the only
# artifact, a single ext4 root written directly by the cross-build host), so
# the LUKS2 container is formatted as part of THIS build, not a later install
# run on/against the target. Independently triggerable from --standalone, same
# as the other platforms — encrypts whatever --role is being built today, not
# just --role desktop.
ENCRYPT_ROOT=false      # --encrypt-root : LUKS2-encrypt the root (bake-time)
LUKS_PASS=""            # --luks-pass PASS : plaintext; used directly by cryptsetup at
                        # bake time. Omit it and a random passphrase is generated and
                        # printed ONCE at the end of the build (first-boot-changeable
                        # via `cryptsetup luksChangeKey` — there is no first-boot mint
                        # step here the way there is for LOCAL_PASSHASH, since the
                        # passphrase must already exist before the LUKS container can
                        # be formatted at build time).

# ── Radio attack surface (DISABLED BY DEFAULT — hardened posture) ──
ENABLE_WIFI="${ENABLE_WIFI:-false}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-false}"
# Root SSH login DISABLED by default (hardened); opt back in with --permit-root-login.
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-no}"
# glibc arm64 stage3 seed ON PURPOSE (not musl): the CUDA-on-Tegra userspace —
# the whole point of the L4T flavor this platform is headed for — links glibc.
SEED_STAGE3_URL="https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt"
DLV_OFFLINE_KEYRING="${DLV_OFFLINE_KEYRING:-${SCRIPT_DIR}/scripts/gentoo-release-key.asc}"

# Mesh VPN (installed as upstream static arm64 binaries, not emerged) — IDENTICAL
# to the Pi5/Frite images so the Orin joins the same headscale/tailscale mesh.
HEADSCALE_VERSION="0.23.0"
TAILSCALE_VERSION="1.78.1"
SKIP_MESH=false
SKIP_TAILSCALE=false

# --print-plan: resolve + validate everything, print the machine-greppable build
# plan (one PLAN_KEY=VALUE per line) and exit 0 BEFORE any mutation (no root, no
# disk writes, no network). The CLI/make/menu/Studio channels + the build-matrix
# harness (tests/build-matrix/check.sh) verify every role/flag combo through it.
PRINT_PLAN=false

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'
BOLD='\033[1m'; RESET='\033[0m'
banner() { echo -e "\n${CYAN}${BOLD}==> $1${RESET}"; }
info()   { echo -e "${GREEN}    $1${RESET}"; }
warn()   { echo -e "${YELLOW}    WARNING: $1${RESET}"; }
err()    { echo -e "${RED}    ERROR: $1${RESET}" >&2; }

usage() {
cat <<'MANEOF'
NAME
    build-jetson-stage4.sh - Build a hardened Gentoo aarch64 image for the
    NVIDIA Jetson Orin family (Tegra234) — the arm64 edge-AI node platform —
    joined to the HugMesh Tailscale mesh. EXPERIMENTAL (hardware validation
    pending; see specs-jetson/README.md).

SYNOPSIS
    build-jetson-stage4.sh [OPTIONS]

DESCRIPTION
    Cross-compiles a hardened Gentoo image for the Jetson Orin Nano/NX devkits,
    reusing the aarch64 cross path, the SHARED mesh + KEYS-USB provisioning
    engine, and (for cluster roles) the SHARED specs/cluster GitOps tree — the
    edge-ai inference service manifests are arch-portable, so the same `edge_ai`
    role that runs on the x86 RTX host runs here.

OPTIONS
  Role
    -r, --role ROLE     edge_ai (DEFAULT, the headline: GPU inference k8s worker
                        + the edge-ai service) | gpu-host (GPU k8s worker, no
                        inference service) | full (full-stack single node:
                        headscale control plane + kubeadm init + all namespaces)
                        | desktop (arm64 client desktop; mesh, no k8s).

  Board / kernel
    --board NAME        orin-nano (DEFAULT: Orin Nano [Super] Developer Kit,
                        8GB, module p3767-0005) | orin-nano-4gb | orin-nx-8gb |
                        orin-nx-16gb (same carrier; UNTESTED).
    --kernel-flavor F   mainline (DEFAULT, the buildable route: gentoo-sources
                        arm64 + the Tegra234 fragments; NO CUDA — the edge-ai
                        service runs CPU-only) | l4t (STUB: NVIDIA's L4T/BSP
                        kernel + CUDA userspace — requires NVIDIA L4T downloads;
                        documented in specs-jetson/, not automated: hard error).
    -c, --cpu CPU       GCC -mcpu/-mtune (default cortex-a78ae — all Orins).
    -d, --defconfig N   Kernel base defconfig (default: defconfig, mainline arm64).
    --dtb PATH          Override the in-tree DTB (e.g.
                        nvidia/tegra234-p3768-0000+p3767-0003.dtb).

  Branding / env / system  (same knobs as the other builders)
    --brand / --brand-title / --org / --cluster-domain / --env test|prod
    -H hostname / -T timezone / -u user
    -C, --config FILE   drop-in brand.conf profile (sourced; CLI overrides it).

  Image
    --img / --no-img    build / skip the flashable raw .img (default: build).
    --img-size MiB      ext4 root size in the .img (default per role; growroot
                        expands it to the medium on first boot).
    --grow fill|none|<size>   first-boot grow policy (default fill).
    --compress          xz -9 the finished image(s).
    -p PKGS             extra packages appended to the stage4.

  Mesh / radios  (same as the Pi5/Frite builders)
    --headscale-version / --tailscale-version / --skip-mesh / --skip-tailscale
    --permit-root-login no|yes|prohibit-password  (default no)
    --enable-wifi / --enable-bluetooth   (off by default)

  Standalone (local user, no mesh, LUKS2-encrypted root; composes onto
              --role desktop only)
    --standalone         No mesh; a local user logs in with a build-time
                          password instead of the KEYS-USB-provisioned account.
                          Forces --encrypt-root.
    --local-user NAME    The standalone local login account (default: --user).
    --local-pass PASS    Plaintext; hashed at build (yescrypt, $6$ fallback), never
                          baked raw. Omit it and a random one-time password is
                          minted + printed once at first boot instead.

  Root disk encryption (LUKS2; bake-time — there is no separate install step
              on this platform, so encryption happens as part of THIS build)
    --encrypt-root       LUKS2-encrypt the root partition. Automatically
                          forced on by --standalone. Requires cryptsetup on
                          the BUILD HOST (not just the target sysroot).
    --luks-pass PASS     Plaintext passphrase for the encrypted root; used
                          directly by cryptsetup at build time. Omit it and a
                          random passphrase is generated and printed ONCE at
                          the end of the build — change it after first boot
                          via `cryptsetup luksChangeKey`.

  Phases
    --skip-kernel / --skip-clean / --resume / --image-only
    --allow-missing-packages
                        Ship the image even if some requested packages failed to
                        merge: the completeness gate warns instead of failing.
                        Cannot bypass the kernel check (a kernel-less image
                        cannot boot; use --skip-kernel to deliberately build
                        without one). Read the missing-atom list first.

  General
    -w, --work-dir DIR  products land here (default ./out).
    --distdir DIR       reuse a shared READ-ONLY distfiles cache (or SNAP_DISTDIR_SRC
                        env); arch-independent sources, safe fleet-wide. New fetches
                        still land in the private build tree. Empty = private only.
    -j, --jobs N        parallel jobs (default nproc).
    --print-plan        resolve + validate all flags, print the build plan
                        (PLAN_KEY=VALUE lines) and exit 0 — no root, no writes,
                        no network. Invalid combinations exit non-zero.
    -h, --help

EXAMPLES
    # The headline: Orin Nano edge-AI inference node (mainline kernel, CPU-only
    # inference until the L4T flavor lands)
    ./build-jetson-stage4.sh --role edge_ai

    # Full single-node stack on one Orin, prod domain
    ./build-jetson-stage4.sh --role full --env prod

    # Plan-only validation across the matrix (no root, no writes)
    ./build-jetson-stage4.sh --role desktop --env prod --print-plan

NOTES
    FLASHING: write the .img to microSD/NVMe and boot — a current Orin devkit
    UEFI distro-boots /boot/extlinux/extlinux.conf directly. The QSPI firmware
    itself (and the future L4T/CUDA stack) is flashed OUT-OF-BAND in recovery
    mode — see specs-jetson/installer/TEGRAFLASH.md.

    CUDA: NOT available on the default mainline kernel flavor. The GA10B iGPU
    needs NVIDIA's nvgpu driver + L4T userspace (--kernel-flavor l4t, stubbed).
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
        --packages-only)      PACKAGES_ONLY=true;         shift ;;
        # Accept an image whose requested package set did not fully merge (the
        # completeness gate warns instead of failing; kernel tier stays fatal).
        --allow-missing-packages) ALLOW_MISSING_PACKAGES=true; shift ;;
        --build-subdir)       BUILD_SUBDIR="$2";          shift 2 ;;
        -s|--specs-dir)       SPECS_DIR="$2";             shift 2 ;;
        -t|--target)          CROSS_TARGET="$2";          shift 2 ;;
        -j|--jobs)            JOBS="$2";                  shift 2 ;;
        -r|--role)            ROLE="$2";                  shift 2 ;;
        --board)              JETSON_BOARD="$2";          shift 2 ;;
        --kernel-flavor)      KERNEL_FLAVOR="$2";         shift 2 ;;
        -c|--cpu)             RPI_CPU="$2";               shift 2 ;;
        -d|--defconfig)       JETSON_DEFCONFIG="$2";      shift 2 ;;
        --dtb)                JETSON_DTB="$2";            shift 2 ;;
        -v|--version)         REL_VERSION="$2";           shift 2 ;;
        --seed-url)           SEED_STAGE3_URL="$2";       shift 2 ;;
        -H|--hostname)        HOSTNAME="$2";              shift 2 ;;
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
        # DEPRECATED no-ops (fleet posture): no password is baked into images.
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
        --img)                BUILD_IMG=true;             shift   ;;
        --no-img)             BUILD_IMG=false;            shift   ;;
        --img-size)           ROOT_MiB="$2"; IMG_SIZE_SET=true; shift 2 ;;
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

# ── select_board: map --board to its CPU / mainline DTB ────────────
# Only fills values the operator did NOT set on the CLI, so an explicit
# --cpu/--dtb always wins. All Orin modules are Cortex-A78AE; the DTB names the
# carrier (p3768) + module (p3767-000N) — see specs-jetson/boot/README.md.
select_board() {
    local cpu dtb desc
    case "${JETSON_BOARD}" in
        orin-nano)
            cpu="cortex-a78ae"; dtb="nvidia/tegra234-p3768-0000+p3767-0005.dtb"
            desc="NVIDIA Jetson Orin Nano [Super] Developer Kit (Tegra234, 8GB, p3767-0005)"
            ;;
        orin-nano-4gb)
            cpu="cortex-a78ae"; dtb="nvidia/tegra234-p3768-0000+p3767-0004.dtb"
            desc="NVIDIA Jetson Orin Nano 4GB on devkit carrier (Tegra234, p3767-0004) — UNTESTED"
            ;;
        orin-nx-8gb)
            cpu="cortex-a78ae"; dtb="nvidia/tegra234-p3768-0000+p3767-0001.dtb"
            desc="NVIDIA Jetson Orin NX 8GB on devkit carrier (Tegra234, p3767-0001) — UNTESTED"
            ;;
        orin-nx-16gb)
            cpu="cortex-a78ae"; dtb="nvidia/tegra234-p3768-0000+p3767-0000.dtb"
            desc="NVIDIA Jetson Orin NX 16GB on devkit carrier (Tegra234, p3767-0000) — UNTESTED"
            ;;
        *) err "--board must be one of: orin-nano | orin-nano-4gb | orin-nx-8gb | orin-nx-16gb (got '${JETSON_BOARD}')"; exit 1 ;;
    esac
    [ -z "${RPI_CPU}" ]    && RPI_CPU="${cpu}"
    [ -z "${JETSON_DTB}" ] && JETSON_DTB="${dtb}"
    JETSON_BOARD_DESC="${desc}"
}
select_board

# ── Validate role; derive k8s intent, desktop weight, hostname, sizing ──
ROLE_K8S="none"; ROLE_HEADSCALE=false; ROLE_CLIENT=false; EDGE_AI=false
case "${ROLE}" in
    edge-ai) ROLE="edge_ai" ;;             # slug alias (matches the x86 builder)
    gpu_host) ROLE="gpu-host" ;;           # underscore alias
esac
case "${ROLE}" in
    edge_ai)
        # The headline: GPU inference k8s worker + the edge-ai service.
        ROLE_K8S="worker"; EDGE_AI=true
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-jetson-edge-ai"
        ${IMG_SIZE_SET} || ROOT_MiB=16384 ;;
    gpu-host)
        # GPU k8s worker without the inference service (be+gpu analogue).
        ROLE_K8S="worker"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-jetson-gpu"
        ${IMG_SIZE_SET} || ROOT_MiB=14336 ;;
    full)
        # Full-stack single node (omnibus analogue): headscale control plane +
        # kubeadm init + every namespace on one Orin.
        ROLE_K8S="single-node"; ROLE_HEADSCALE=true; EDGE_AI=true
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-jetson-full"
        ${IMG_SIZE_SET} || ROOT_MiB=20480 ;;
    desktop)
        # arm64 client desktop: mesh client + lean LXDE, no k8s/cluster tree.
        ROLE_CLIENT=true; DESKTOP="light"
        [ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-jetson"
        ${IMG_SIZE_SET} || ROOT_MiB=16384 ;;
    *)
        err "--role must be one of: edge_ai (default) | gpu-host | full | desktop (got '${ROLE}')"
        exit 1 ;;
esac

# ── STANDALONE posture (composable onto --role desktop only — a k8s cluster
# role can't be a standalone appliance) ─────────────────────────────────────
if ${STANDALONE}; then
    ${ROLE_CLIENT} || { err "--standalone only composes onto --role desktop (got --role ${ROLE})"; exit 1; }
    SKIP_MESH=true
    SKIP_TAILSCALE=true
    ENCRYPT_ROOT=true
    [ -z "${LOCAL_USER}" ] && LOCAL_USER="${DEFAULT_USER}"
    info "STANDALONE desktop: no mesh; local user '${LOCAL_USER}'; LUKS2-encrypted root"
fi

# ── --encrypt-root on a headless k8s role: this platform's disk-boot
# initramfs only supports an interactive passphrase prompt (no keyfile/
# Clevis/TPM factor yet — see the crypttab comment in Phase 4), so an
# encrypted edge_ai/gpu-host/full node cannot rejoin the cluster after an
# unattended reboot/power-cycle/panic without someone at a physical console.
# STANDALONE (desktop-only, forced above) doesn't need this warning. ────────
if ${ENCRYPT_ROOT} && ! ${ROLE_CLIENT}; then
    warn "--encrypt-root on a headless --role ${ROLE} node: no unattended-unlock factor exists on this platform yet (passphrase-only prompt) — this node will hang at the LUKS prompt on any reboot/power-cycle with nobody at a physical console to unlock it. Make sure you have out-of-band console access to this fleet node, or hold off on --encrypt-root for cluster roles until a keyfile/Clevis/TPM factor ships."
fi

# ── --encrypt-root is currently a CONFIRMED-BROKEN combination on this
# platform, not just an unverified-on-hardware risk — block it outright.
# specs-jetson/boot/README.md documents the Orin's actual boot chain: the
# NVIDIA UEFI L4TLauncher distro-boots /boot/extlinux/extlinux.conf directly
# off the SAME single ext4 partition (JETSON_ROOT) that holds the whole
# rootfs — there is no separate ESP/boot partition at all, unlike every other
# platform in this repo (RPi5/Frite/Orange-Pi-5/Orange-Pi-Zero-2 all keep an
# UNENCRYPTED boot partition split from the LUKS2 root specifically so the
# firmware/bootloader can still read the kernel/initrd/extlinux.conf).
# build_img() below has only ONE partition, so --encrypt-root LUKS2-encrypts
# extlinux.conf/the kernel/the DTB/disk-initrd.img right along with the rest
# of the root filesystem — the UEFI firmware (no LUKS2 support) can no longer
# parse a filesystem there at all, so it can never even find something to
# boot, regardless of dracut's own disk-initrd.img being otherwise correct.
# This is a real, architectural boot-chain break (confirmed against this
# platform's own boot documentation), not a hypothetical hardware risk — so
# it is blocked here the same way rpi3+non-desktop is blocked on build-rpi5-
# stage4.sh, rather than silently shipping an image that cannot boot. Fixing
# this for real needs a separate unencrypted boot partition (mirroring RPi5's
# split) — a distinct, larger undertaking of its own, deliberately NOT
# attempted in this pass; see docs/STANDALONE-DESKTOP.md's Jetson section.
if ${ENCRYPT_ROOT}; then
    err "--encrypt-root is not supported on this platform yet: build_img() writes a SINGLE ext4 partition (JETSON_ROOT) that holds both /boot/extlinux/extlinux.conf AND the root filesystem, and the Orin's UEFI L4TLauncher reads that boot config directly off the raw partition before Linux/dracut ever runs — LUKS2-encrypting that single partition makes the firmware unable to find a kernel to boot at all. This needs a separate unencrypted boot partition (like RPi5/Frite/Orange-Pi-5) before it can work; see docs/STANDALONE-DESKTOP.md. (--standalone forces --encrypt-root and is blocked for the same reason.)"
    exit 1
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

# ── Validate kernel flavor / env / grow ────────────────────────────
case "${KERNEL_FLAVOR}" in
    mainline|l4t) ;;
    *) err "--kernel-flavor must be: mainline | l4t (got '${KERNEL_FLAVOR}')"; exit 1 ;;
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

# ── Charset allowlists for brand/identity/kernel/toolchain fields (fail-closed) ──
# (mirrors build-frite-stage4.sh / build-rpi5-stage4.sh — same sinks, same threat:
# these values reach render_template's sed program and root-run first-boot code.)
_require_match() {  # <human-name> <value> <regex>
    [[ "$2" =~ $3 ]] || { err "invalid $1: '$2' (must match ${3})"; exit 1; }
}
_RE_SLUG='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
_RE_ORG='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
_RE_DNS='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
_RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
_RE_TITLE='^[A-Za-z0-9 ._-]{1,64}$'
_RE_CPU='^[A-Za-z0-9._+-]+$'
_RE_TRIPLET='^[A-Za-z0-9_.-]+$'

_require_match "--brand"          "${BRAND}"          "${_RE_SLUG}"
_require_match "--org"            "${ORG}"            "${_RE_ORG}"
_require_match "--cluster-domain" "${CLUSTER_DOMAIN}" "${_RE_DNS}"
[ -n "${SUPERDOMAIN}" ] && _require_match "--superdomain" "${SUPERDOMAIN}" "${_RE_DNS}"
_require_match "--hostname"       "${HOSTNAME}"       "${_RE_DNS}"
_require_match "--user"           "${DEFAULT_USER}"   "${_RE_USER}"
_require_match "--brand-title"    "${BRAND_TITLE}"    "${_RE_TITLE}"
_require_match "--cpu"            "${RPI_CPU}"        "${_RE_CPU}"
_require_match "--target"         "${CROSS_TARGET}"   "${_RE_TRIPLET}"

BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"
SYSROOT="${BUILD_ROOT}/sysroot"
STAGE_DIR="${BUILD_ROOT}/staging"
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

# Image / artifact name prefix (board in the name so flash-disk autodetect works).
ART_PREFIX="${BRAND}-jetson-${JETSON_BOARD}-arm64-${ROLE}-${ENV}-${BUILD_TS}"

# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation ──────────
# Runs AFTER full arg parsing / board+role+env+kernel-flavor validation /
# allowlist checks / artifact resolution, but BEFORE the EXPERIMENTAL banner,
# the l4t stub gate, the prereq probes, mkdir, network fetches or any sysroot
# write. No root required. One stable KEY=VALUE per line (grep '^PLAN_'); exit
# 0. Invalid role/flag combos never reach this point — the validation above
# already exited non-zero, which is exactly what the tests/build-matrix harness
# relies on. NO secrets are echoed here. NOTE: --kernel-flavor l4t IS a valid
# plan (it validates + resolves); only the BUILD is stubbed (hard error below).

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
# Tier-1 mandatory atoms (base + role class). Dropping one is rejected (Decision #5).
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
    _plan BUILDER            "build-jetson-stage4.sh"
    _plan PLATFORM           "jetson"
    _plan ARCH               "arm64"
    _plan ROLE               "${ROLE}"
    _plan ENV                "${ENV}"
    _plan BOARD              "${JETSON_BOARD}"
    _plan BOARD_DESC         "${JETSON_BOARD_DESC}"
    _plan DTB                "${JETSON_DTB}"
    _plan KERNEL_FLAVOR      "${KERNEL_FLAVOR}"
    _plan KERNEL             "$([ "${KERNEL_FLAVOR}" = "l4t" ] && echo 'l4t-bsp (STUB: requires NVIDIA L4T downloads — build exits non-zero)' || echo "mainline-arm64 (defconfig=${JETSON_DEFCONFIG} + hardened-node.config + tegra234.config)")"
    _plan DESKTOP            "${DESKTOP}"
    _plan GPU_DRIVER         "$([ "${KERNEL_FLAVOR}" = "l4t" ] && echo nvgpu-l4t || echo tegra-mainline-nocuda)"
    _plan CUDA               "$([ "${KERNEL_FLAVOR}" = "l4t" ] && echo l4t-userspace || echo none-mainline)"
    _plan K8S                "${ROLE_K8S}"
    _plan EDGE_AI_SERVICE    "${EDGE_AI}"
    _ARTS="stage4.tar.xz"
    ${BUILD_IMG} && _ARTS="${_ARTS},img"
    _plan ARTIFACTS          "${_ARTS}"
    _plan ARTIFACT_PREFIX    "${BRAND}-jetson-${JETSON_BOARD}-arm64-${ROLE}-${ENV}-<timestamp>"
    _plan WORK_DIR           "${WORK_DIR}"
    # Per-board binpkg pool + prebuild mode (shared-binpkg). Additive PLAN_ keys.
    _plan PKGDIR             "${BUILD_ROOT}/pkgdir"
    _plan PACKAGES_ONLY      "$(${PACKAGES_ONLY} && echo 1 || echo 0)"
    _plan JOBS               "${JOBS}"
    _plan BRAND              "${BRAND}"
    _plan CLUSTER_DOMAIN     "${CLUSTER_DOMAIN}"
    _plan SUPERDOMAIN        "${SUPERDOMAIN}"
    _plan HOSTNAME           "${HOSTNAME}"
    _plan OPTIONAL_SERVICES  "$(${ROLE_CLIENT} && echo none || { ${EDGE_AI} && echo edge-ai || echo none; })"
    _plan MESH               "$(${SKIP_MESH} && echo skip || echo "headscale=${HEADSCALE_VERSION},tailscale=$(${SKIP_TAILSCALE} && echo skip || echo "${TAILSCALE_VERSION}")")"
    _plan STANDALONE         "${STANDALONE}"
    _plan LOCAL_USER         "${LOCAL_USER:-$DEFAULT_USER}"
    _plan LOCAL_PASS         "$([ -n "${LOCAL_PASSHASH}" ] && echo REDACTED || echo none)"
    _plan ENCRYPT_ROOT       "${ENCRYPT_ROOT}"
    _plan LUKS_PASS          "$([ -n "${LUKS_PASS}" ] && echo REDACTED || echo none)"
    _plan STATUS             "EXPERIMENTAL (hardware validation pending — specs-jetson/README.md)"
    _plan FLAGS_EFFECTIVE    "env=${ENV} role=${ROLE} board=${JETSON_BOARD} kernel_flavor=${KERNEL_FLAVOR} desktop=${DESKTOP} img=${BUILD_IMG} img_size=${ROOT_MiB} grow=${GROW_POLICY} compress=${COMPRESS_IMG} resume=${RESUME} skip_kernel=${SKIP_KERNEL} skip_mesh=${SKIP_MESH} skip_tailscale=${SKIP_TAILSCALE} permit_root_login=${PERMIT_ROOT_LOGIN} enable_wifi=${ENABLE_WIFI} enable_bluetooth=${ENABLE_BLUETOOTH} standalone=${STANDALONE} encrypt_root=${ENCRYPT_ROOT}"
    exit 0
fi

# ── LOUD EXPERIMENTAL banner (every real build; --print-plan exits above) ──────
echo -e "${YELLOW}${BOLD}"
echo "############################################################################"
echo "##  EXPERIMENTAL: Jetson Orin platform — HARDWARE VALIDATION PENDING     ##"
echo "##  This build mirrors the proven RPi5/Frite cross flow but has NOT been ##"
echo "##  booted on a physical Orin from this repo. Mainline kernel flavor has ##"
echo "##  NO CUDA (edge-ai runs CPU-only). See specs-jetson/README.md.         ##"
echo "############################################################################"
echo -e "${RESET}"

# ── --kernel-flavor l4t: STUB (documented, not automated) ──────────────────────
# The L4T/BSP kernel + CUDA userspace are EULA-gated NVIDIA developer downloads
# and the flash flow is recovery-mode tegraflash — neither can be fetched or run
# from this builder. Hard error HERE (after --print-plan, before any mutation).
if [ "${KERNEL_FLAVOR}" = "l4t" ]; then
    err "--kernel-flavor l4t is a documented STUB: the L4T/BSP kernel + CUDA-on-Tegra"
    err "userspace require NVIDIA L4T downloads (EULA-gated) — documented, not automated."
    err "Follow specs-jetson/kernel/README.md + specs-jetson/installer/TEGRAFLASH.md to"
    err "flash the L4T stack out-of-band, then layer this builder's stage4 over it."
    err "The buildable route today is the default: --kernel-flavor mainline (no CUDA)."
    exit 1
fi

if [ "${ENV}" = "prod" ]; then
    echo -e "${RED}${BOLD}"
    echo "############################################################################"
    echo "##   BUILDING PROD Jetson image for ${CLUSTER_DOMAIN}"
    echo "##   - bakes the REAL public domain; mesh/Casdoor creds from the keys USB ##"
    echo "############################################################################"
    echo -e "${RESET}"
else
    info "Build ENV: test (LAN-first; mesh + Casdoor login provisioned from the KEYS USB)"
fi
info "Board:  ${JETSON_BOARD_DESC}"
info "DTB:    ${JETSON_DTB}   kernel flavor: ${KERNEL_FLAVOR}"
info "Role:   ${ROLE}  (k8s=${ROLE_K8S} edge-ai=${EDGE_AI} desktop=${DESKTOP})"
info "Build stamp: ${BUILD_TS} (brand=${BRAND})"

# ── _sed_rep_escape + render_template (same contract as the other builders) ──
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
        -e "s|@@JETSON_KERNEL_IMG@@|$(_sed_rep_escape "${JETSON_KERNEL_IMG}")|g" \
        -e "s|@@JETSON_DTB@@|$(_sed_rep_escape "${JETSON_DTB}")|g" \
        -e "s|@@JETSON_INITRD_LINE@@|$(_sed_rep_escape "${JETSON_INITRD_LINE:-    # (initrd-less: boot-critical Tegra drivers are built in)}")|g" \
        -e "s|@@JETSON_APPEND@@|$(_sed_rep_escape "${JETSON_APPEND:-}")|g" \
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

# ── harden_radios (identical posture to the Pi5/Frite builders) ────
harden_radios() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/modprobe.d" "${sysroot}/etc/local.d" \
             "${sysroot}/etc/NetworkManager/conf.d"
    local bl="${sysroot}/etc/modprobe.d/hugmesh-radio-blacklist.conf"; : > "${bl}"
    local act="${sysroot}/etc/local.d/02-radio-hardening.start"
    {
        echo "#!/bin/sh"
        echo "# Radio hardening (build-jetson-stage4.sh). WiFi/Bluetooth OFF by default."
        echo "command -v rfkill >/dev/null 2>&1 || exit 0"
    } > "${act}"
    if [ "${ENABLE_WIFI}" != "true" ]; then
        { echo "blacklist cfg80211"; echo "blacklist mac80211"; } >> "${bl}"
        { echo "rfkill block wifi 2>/dev/null || true"
          echo "command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off 2>/dev/null || true"; } >> "${act}"
        printf '[main]\n# WiFi off by default; managed=ethernet only.\n' \
            > "${sysroot}/etc/NetworkManager/conf.d/10-no-wifi.conf"
        info "WiFi DISABLED by default. Re-enable: --enable-wifi."
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

# zram swap at first boot: sized to half of RAM, capped at 2G (an 8 GB Orin
# running a 7B model CPU-only benefits; harmless otherwise). Idempotent.
write_zram_firstboot() {
    local sysroot="$1"
    mkdir -p "${sysroot}/etc/local.d"
    cat > "${sysroot}/etc/local.d/03-zram-swap.start" <<'ZRAM_EOF'
#!/bin/sh
# zram swap — half of RAM, capped at 2G. Best-effort (no zram = skip).
[ -e /sys/class/zram-control ] || modprobe zram 2>/dev/null || exit 0
grep -q '/dev/zram0' /proc/swaps 2>/dev/null && exit 0
mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
half=$(( mem_kb / 2 )); cap=$(( 2048 * 1024 ))
[ "${half}" -gt "${cap}" ] && half="${cap}"
[ "${half}" -gt 0 ] || exit 0
echo "${half}K" > /sys/block/zram0/disksize 2>/dev/null || exit 0
mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null || true
ZRAM_EOF
    chmod +x "${sysroot}/etc/local.d/03-zram-swap.start"
}

# ── rebrand_sysroot (covers the baked cluster tree too, like rpi5/x86) ──
rebrand_sysroot() {
    [ "${BRAND}" = "hugmesh" ] && [ "${CLUSTER_DOMAIN}" = "hugmesh.systems" ] && return 0
    banner "Rebranding baked config -> brand=${BRAND} domain=${CLUSTER_DOMAIN} org=${ORG}"
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
            -e "s|Snapdragon-Systems|${_org}|g" \
            -e "s|hugmesh\.systems|${_domain}|g" \
            -e "s|\(registry\.[A-Za-z0-9.-]*\)/hugmesh/|\1/${_hproj}/|g" \
            -e "s|hugmesh-|${_brand}-|g" \
            -e "s|@@SDSYSKEY@@/|hugmesh.systems/|g" \
            "${f}"
    done < <(find "${SYSROOT}/etc/hugmesh" "${SYSROOT}/var/lib/hugmesh/cluster" -type f -print0 2>/dev/null)
}

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
    if [ "${ROLE_K8S}" != "none" ]; then
        _rsp_info "Cluster role — appending packages-k8s.list (containerd + kubeadm node set)"
        mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
            grep -v '^\s*#' "${SPECS_DIR}/portage/packages-k8s.list" | grep -v '^\s*$')
    fi
    if ${EDGE_AI}; then
        _rsp_info "Edge-AI role — appending packages-edge-ai.list (inference-node extras)"
        mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
            grep -v '^\s*#' "${SPECS_DIR}/portage/packages-edge-ai.list" | grep -v '^\s*$')
    fi
    if [ "${DESKTOP}" = "light" ]; then
        _rsp_info "Desktop role — appending packages-desktop.list (lean LXDE client set)"
        mapfile -t -O "${#STAGE4_PACKAGES[@]}" STAGE4_PACKAGES < <(
            grep -v '^\s*#' "${SPECS_DIR}/portage/packages-desktop.list" | grep -v '^\s*$')
    fi
    if ${ENCRYPT_ROOT}; then
        # sys-fs/lvm2 is NOT listed explicitly: sys-fs/cryptsetup unconditionally
        # RDEPENDs on it (libdevmapper), so it is already pulled in transitively —
        # same minimal-conditional-package convention as build-rpi5-stage4.sh /
        # build-frite-stage4.sh's --encrypt-root package blocks.
        _rsp_info "--encrypt-root — appending cryptsetup/dracut (LUKS2 root + disk-boot initramfs; lvm2 pulled in transitively via cryptsetup)"
        STAGE4_PACKAGES+=(sys-fs/cryptsetup sys-kernel/dracut)
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
[ -d "${SPECS_DIR}" ]    || { err "Jetson specs directory not found: ${SPECS_DIR}"; exit 1; }
[ -d "${SHARED_SPECS}" ] || { err "Shared specs directory not found: ${SHARED_SPECS}"; exit 1; }
info "Jetson specs: ${SPECS_DIR}"
info "Shared specs: ${SHARED_SPECS}"
for tool in "${CROSS_TARGET}-gcc" "${CROSS_TARGET}-strip" curl tar file; do
    command -v "${tool}" &>/dev/null || { err "${tool} not found in PATH."; exit 1; }
done

# ── Cross-dracut (--encrypt-root) fail-FAST preflight ───────────────
# Mirror of the other ARM boards for consistency. NOTE: Jetson hard-errors on
# --encrypt-root much earlier (a single boot+root partition the Orin UEFI reads
# raw cannot be LUKS-encrypted), so this block is UNREACHABLE today; it is here
# so that if/when Jetson gains a separate unencrypted boot partition, the same
# fail-FAST guard applies. Runs only on a real build (after --print-plan).
if ${ENCRYPT_ROOT}; then
    dracut_cross_register_qemu || true
    if ! dracut_cross_preflight_ok; then
        err "--encrypt-root on ${BRAND}-${JETSON_BOARD}-${ROLE} (if this build came from a multi-image mesh worklist, THIS node image is the affected one) needs the arm64 disk-boot initramfs, but no usable cross-dracut strategy is available: ${DRACUT_CROSS_BINFMT_NODE} is not registered and/or $(dracut_cross_qemu_interp) is missing/not executable."
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

# Host SELinux policy build tools (same rationale as the Pi5/Frite builders).
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
# containerd[selinux] host toolchain pre-seed (k8s roles; same as the rpi5 cross
# build): the HOST selinux-python/policycoreutils chain needs python bindings or
# the cross_emerge silently skips containerd and trips the payload assert.
if [ "${ROLE_K8S}" != "none" ] && hostguard_mutation_allowed && [ "$(id -u)" -eq 0 ]; then
    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/hugmesh-cross-host-selinux <<'HOSTSELINUX'
# Auto-written by build-jetson-stage4.sh (Jetson CROSS build; same rationale as
# the rpi5 builder). Safe to delete on a non-build host.
sys-libs/libselinux python
sys-process/audit    python
HOSTSELINUX
    info "Pre-seeded HOST /etc/portage/package.use: libselinux[python]+audit[python]"
fi
# .img assembly tools (best-effort: missing tools disable the .img, not the
# build) — UNLESS --encrypt-root, since build_img() is the ONLY artifact that
# can carry the LUKS2 root on this platform (no separate installer to fall
# back to, unlike x86/Frite/RPi5); silently disabling it there would silently
# ship a build with no encrypted artifact at all. cryptsetup is likewise a
# HARD requirement (not best-effort) for --encrypt-root specifically.
if ${BUILD_IMG}; then
    for t in parted losetup mkfs.ext4 blkid; do
        if ! command -v "$t" >/dev/null; then
            if ${ENCRYPT_ROOT}; then
                err "missing ${t} on the build host — required to build the --encrypt-root .img (the only artifact this platform produces)"
                exit 1
            fi
            # Non-encrypt NATIVE build: fail fast with the emerge rather than
            # silently dropping the .img the operator asked for. In the builder
            # container this returns non-zero and today's warn+disable below runs
            # verbatim (all four tools measured present in the image).
            hostguard_require_host_tools "the .img build" \
                    "sys-block/parted sys-apps/util-linux sys-fs/e2fsprogs" \
                    --hint "Or pass --no-img to build without the flashable .img." \
                    -- parted losetup mkfs.ext4 blkid || true
            warn "missing ${t}; disabling .img build"; BUILD_IMG=false; break
        fi
    done
fi
if ${ENCRYPT_ROOT}; then
    ${BUILD_IMG} || { err "--encrypt-root requires the .img (see warnings above) — refusing to run a build that cannot produce an encrypted artifact."; exit 1; }
    command -v cryptsetup >/dev/null || { err "missing cryptsetup on the BUILD HOST — required by --encrypt-root to format the LUKS2 root at build time (emerge sys-fs/cryptsetup on the host running this script, not just the target sysroot)"; exit 1; }
    # Fail fast on the UUID source too — checked again (defense in depth) right
    # before use in Phase 4, but that's hours of cross-compilation away.
    { command -v uuidgen >/dev/null 2>&1 || [ -r /proc/sys/kernel/random/uuid ]; } \
        || { err "missing uuidgen (sys-apps/util-linux) AND /proc/sys/kernel/random/uuid on the BUILD HOST — required by --encrypt-root to mint the LUKS UUID at build time"; exit 1; }
fi
info "Cross-compiler: $(${CROSS_TARGET}-gcc --version | head -1)"
info "Jobs: ${JOBS}"

banner "Preparing build directories"
mkdir -p "${WORK_DIR}" "${BUILD_ROOT}"/{distfiles,pkgdir,log} "${SYSROOT}" "${STAGE_DIR}"
# Preserve the pre-log fds so secrets that must NOT be persisted (e.g. the
# generated LUKS passphrase, printed once near the end of this script) can
# still reach the operator's terminal without also landing in build.log.
exec 3>&1 4>&2
exec > >(tee -a "${LOG_FILE}" "${IMAGE_LOG_FILE}") 2>&1
info "Logging to ${LOG_FILE} (session-shared) + ${IMAGE_LOG_FILE} (this image)"
# Run banner: the shared log interleaves runs (append) and a RESTART appends to
# the per-image log too — keep every chunk attributable to its run.
echo "==== ${BUILD_SUBDIR#wl-} (${BUILD_SUBDIR}) start ${BUILD_TS} brand=${BRAND} role=${ROLE} env=${ENV} ===="

banner "Fetching stage3 seed (arm64 glibc — CUDA needs glibc)"
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

banner "Verifying stage3 seed signature + checksum"
if ! dlv_verify_stage3 "${STAGE3_LOCAL}" "${STAGE3_FULL_URL}.DIGESTS"; then
    rm -f "${STAGE3_LOCAL}"
    err "stage3 seed failed verification (bad signature or checksum) — aborting."
    err "If Gentoo rotated its signing key, set DLV_GENTOO_KEY=<fingerprint>; for an"
    err "air-gapped build set DLV_OFFLINE_KEYRING=<keyfile>. Refusing unverified seed."
    exit 1
fi

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
[ -f "${SPECS_DIR}/portage/profile/package.provided" ] && \
    cp "${SPECS_DIR}/portage/profile/package.provided" "${SYSROOT}/etc/portage/profile/package.provided"
cp "${SPECS_DIR}/portage/package.accept_keywords/"* "${SYSROOT}/etc/portage/package.accept_keywords/"
cp "${SPECS_DIR}/portage/package.use/"*             "${SYSROOT}/etc/portage/package.use/"
cp "${SPECS_DIR}/portage/package.env/"*             "${SYSROOT}/etc/portage/package.env/"
cp "${SPECS_DIR}/portage/env/"*.conf                "${SYSROOT}/etc/portage/env/" 2>/dev/null || true
render_template "${SPECS_DIR}/portage/make.conf.tmpl" "${SYSROOT}/etc/portage/make.conf"
# ── PYTHON_TARGETS: derived from the STAGE3 SEED, never a literal ─────────────
# make.conf.tmpl deliberately ships no PYTHON_TARGETS/PYTHON_SINGLE_TARGET
# assignment: a USE_EXPAND variable ASSIGNED in make.conf REPLACES the profile
# default (portage's config.regenerate() wipes every accumulated
# python_targets_* flag for a non-incremental USE_EXPAND that a config layer
# sets), so a frozen python3_NN there silently narrows every image to one
# interpreter — whichever one happened to be right for the seed of the day. The
# seed floats: amd64 20260726 ships 3.13+3.14 with NO 3.12, arm64 ships 3.14
# only, the 2026-07 jetson seed shipped 3.12+3.14. Getting it wrong is fatal in
# both directions (2026-07-29 dev-python slot conflict / 2026-07-16 "USE changes
# are necessary: python_targets_python3_12" wall). Derive it from the seed
# instead, HERE — after the specs land and BEFORE the first emerge touches the
# sysroot, because an emerge run under a wrong pin installs the wrong
# interpreter and the probe would then read its own effect back in. Fails the
# build rather than guessing. Analysis: docs/PYTHON-TARGETS-SEED-DRIFT.md.
pt_apply_seed_targets "${SYSROOT}" "build-jetson" \
    || { err "could not derive PYTHON_TARGETS from the stage3 seed (see above)"; exit 1; }
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
if [ -n "${DISTDIR_SRC}" ] && [ ! -d "${DISTDIR_SRC}" ]; then
    warn "--distdir: not a directory: ${DISTDIR_SRC} — IGNORING it (sources re-download into ${BUILD_ROOT}/distfiles)."
elif [ -n "${DISTDIR_SRC}" ]; then
    grep -q 'PORTAGE_RO_DISTDIRS' "${SYSROOT}/etc/portage/make.conf" 2>/dev/null \
        || printf 'PORTAGE_RO_DISTDIRS="%s"\n' "${DISTDIR_SRC}" >> "${SYSROOT}/etc/portage/make.conf"
    info "Distfiles: reusing shared cache ${DISTDIR_SRC} via PORTAGE_RO_DISTDIRS (read-only; new fetches -> ${BUILD_ROOT}/distfiles)"
fi
# SB-RO-DISTFILES-END

cp "${SPECS_DIR}/etc/fstab" "${SYSROOT}/etc/fstab"
mkdir -p "${SYSROOT}/etc/modules-load.d"
cp "${SPECS_DIR}/etc/modules-load.d/jetson.conf" "${SYSROOT}/etc/modules-load.d/jetson.conf"

# LUKS2 root (--encrypt-root): persist crypt-module support into any FUTURE
# dracut regeneration on the installed system (e.g. a post-install kernel
# rebuild), not just the disk-boot initramfs this build generates directly.
if ${ENCRYPT_ROOT}; then
    mkdir -p "${SYSROOT}/etc/dracut.conf.d"
    cp "${SPECS_DIR}/etc/dracut.conf.d/60-hugmesh-crypt.conf" "${SYSROOT}/etc/dracut.conf.d/"
else
    # Belt-and-suspenders for --resume sysroots: remove a stale dracut crypt
    # fragment left behind by a prior --encrypt-root build of this same sysroot.
    rm -f "${SYSROOT}/etc/dracut.conf.d/60-hugmesh-crypt.conf"
fi

# ── Shared (arch-agnostic) mesh + provisioning + sshd — the SAME plumbing every
# other node/client image bakes, so the Orin joins the SAME mesh with the SAME
# key-only SSH + device-license posture. ────────────────────────────
mkdir -p "${SYSROOT}/etc/init.d"
JETSON_SVCS=(growroot headscale tailscaled keys-provision)
if [ "${ROLE_K8S}" != "none" ]; then
    JETSON_SVCS+=(containerd kubelet)
fi
for svc in "${JETSON_SVCS[@]}"; do
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
# Layer-A: bake the BOOTSTRAP policy AS the initial policy.hujson (same as
# rpi5/x86/frite; the first verified Layer-A sync re-renders it).
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson" "${SYSROOT}/etc/headscale/policy.hujson"

mkdir -p "${SYSROOT}/usr/sbin" "${SYSROOT}/var/lib/keys-provision"
cp "${SHARED_SPECS}/etc/keys-provision/provision.sh" "${SYSROOT}/usr/sbin/keys-provision"
chmod +x "${SYSROOT}/usr/sbin/keys-provision"

# Hardened, key-only sshd (NO broad SSH access baked in).
mkdir -p "${SYSROOT}/etc/ssh/sshd_config.d"
cp "${SHARED_SPECS}/etc/ssh/sshd_config.d/hardened.conf" "${SYSROOT}/etc/ssh/sshd_config.d/hardened.conf"

# ── Layer-B device-license-registry sshd enforcement (INERT-on-core) ──
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

# ── Layer-A device-license-registry headscale policy (control node only) ──
cp "${SHARED_SPECS}/usr/sbin/gen-headscale-policy.sh"          "${SYSROOT}/usr/sbin/gen-headscale-policy.sh"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-headscale-forcetags"   "${SYSROOT}/usr/sbin/hugmesh-headscale-forcetags"
chmod +x "${SYSROOT}/usr/sbin/gen-headscale-policy.sh" "${SYSROOT}/usr/sbin/hugmesh-headscale-forcetags"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-policy-sync"         "${SYSROOT}/etc/init.d/hugmesh-policy-sync"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-policy-sync"
cp "${SHARED_SPECS}/etc/headscale/policy.bootstrap.hujson"     "${SYSROOT}/etc/headscale/policy.bootstrap.hujson"
cp "${SHARED_SPECS}/etc/headscale/policy.hujson.tmpl"          "${SYSROOT}/etc/headscale/policy.hujson.tmpl"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-policy-sync"         "${SYSROOT}/etc/hugmesh/registry/cron-policy-sync"

# ── Egress VPN (split-tunnel, fail-closed) — baked-but-INERT (default-off) ──
cp "${SHARED_SPECS}/etc/init.d/hugmesh-egress-vpn" "${SYSROOT}/etc/init.d/hugmesh-egress-vpn"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-egress-vpn"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-vpn-runner"   "${SYSROOT}/usr/sbin/hugmesh-vpn-runner"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-vpn-runner"
mkdir -p "${SYSROOT}/etc/hugmesh/vpn"; chmod 0700 "${SYSROOT}/etc/hugmesh/vpn"
cp "${SHARED_SPECS}/usr/sbin/hugmesh-vpn-reconcile" "${SYSROOT}/usr/sbin/hugmesh-vpn-reconcile"
chmod +x "${SYSROOT}/usr/sbin/hugmesh-vpn-reconcile"
cp "${SHARED_SPECS}/usr/lib/hugmesh/vpn-verify.sh" "${SYSROOT}/usr/lib/hugmesh/vpn-verify.sh"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-vpn-reconcile" "${SYSROOT}/etc/init.d/hugmesh-vpn-reconcile"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-vpn-reconcile"
cp "${SHARED_SPECS}/etc/cron.d/hugmesh-vpn-reconcile" "${SYSROOT}/etc/hugmesh/registry/cron-vpn-reconcile"

# ── Opt-in host-binary auto-update (baked plumbing; poller DEFAULT-OFF) ──
mkdir -p "${SYSROOT}/usr/local/sbin"
cp "${SHARED_SPECS}/usr/local/sbin/hugmesh-update"     "${SYSROOT}/usr/local/sbin/hugmesh-update"
chmod +x "${SYSROOT}/usr/local/sbin/hugmesh-update"
cp "${SHARED_SPECS}/etc/init.d/hugmesh-update"         "${SYSROOT}/etc/init.d/hugmesh-update"
chmod +x "${SYSROOT}/etc/init.d/hugmesh-update"

# ── Domain-registry -> brand-repo bridge — baked-but-INERT (default-off) ──
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

# ── Cluster GitOps tree (k8s roles only) — the SAME shared specs/cluster tree
# the rpi5/x86 node builders bake; the edge-ai manifests are arch-portable
# (Ollama ships arm64 + Jetson images; nvidia-device-plugin/RuntimeClass apply
# on arm64 GPU nodes). EXPERIMENTAL note: this bakes the WHOLE tree — the
# per-slug optional-services pruning gate (gate_optional_services) is NOT
# replicated here yet; ArgoCD's installed-services ConfigMap still gates
# activation at runtime. Revisit with hardware validation. ──────────
if [ "${ROLE_K8S}" != "none" ]; then
    if [ -d "${SHARED_SPECS}/cluster" ]; then
        mkdir -p "${SYSROOT}/var/lib/hugmesh"
        rm -rf "${SYSROOT}/var/lib/hugmesh/cluster"
        cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/hugmesh/cluster"
        info "Baked shared cluster GitOps tree -> /var/lib/hugmesh/cluster (role=${ROLE})"
    else
        warn "shared specs/cluster tree not found — k8s role '${ROLE}' will have no baked GitOps tree"
    fi
fi

# Node role + domain + env + board + kernel-flavor markers (read by
# keys-provision / first-boot / the fleet inventory).
mkdir -p "${SYSROOT}/etc/hugmesh"
echo "${ROLE}"           > "${SYSROOT}/etc/hugmesh/role"
echo "${CLUSTER_DOMAIN}" > "${SYSROOT}/etc/hugmesh/cluster-domain"
# Orchestration superdomain (WS-SUPER-B): record the mesh plane the image joins.
if [ -n "${SUPERDOMAIN}" ]; then
    echo "${SUPERDOMAIN}" > "${SYSROOT}/etc/hugmesh/superdomain"
    info "Baked orchestration superdomain -> /etc/hugmesh/superdomain (${SUPERDOMAIN})"
fi
echo "${ENV}"            > "${SYSROOT}/etc/hugmesh/env"
echo "jetson:${JETSON_BOARD}" > "${SYSROOT}/etc/hugmesh/board"
echo "${KERNEL_FLAVOR}"  > "${SYSROOT}/etc/hugmesh/kernel-flavor"
if [ -n "${HEADSCALE_URL:-}" ]; then
    echo "${HEADSCALE_URL}" > "${SYSROOT}/etc/hugmesh/headscale-url"
    info "Baked HEADSCALE_URL=${HEADSCALE_URL} -> /etc/hugmesh/headscale-url"
fi
if ${STANDALONE}; then
    # STANDALONE desktop: bake the marker so keys-provision skips all
    # mesh-seeking no-ops and a normal LOCAL USER logs in with the build-set
    # password (mirrors build-x86-host-stage4.sh).
    echo "true" > "${SYSROOT}/etc/hugmesh/standalone"
    info "Standalone desktop: local user '${DEFAULT_USER}', no mesh."
fi
rebrand_sysroot

# First-boot finaliser (shared template) + radio hardening + zram swap.
mkdir -p "${SYSROOT}/etc/local.d"
[ -f "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" ] || {
    err "missing first-boot finaliser template: ${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl"; exit 1; }
render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl" "${SYSROOT}/etc/local.d/01-firstboot.start"
chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"
harden_radios "${SYSROOT}"

# Root SSH login DISABLED by default (authoritative 00- drop-in; same contract
# as the other builders).
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

# ── OpenRC service links ───────────────────────────────────────────
mkdir -p "${SYSROOT}/etc/runlevels/default"
DEFAULT_SVCS=(sshd NetworkManager cronie haveged growroot keys-provision local)
# Auto-update boot oneshot: baked plumbing, poller DEFAULT-OFF (see the shared note).
DEFAULT_SVCS+=(hugmesh-update)
if [ "${ROLE_K8S}" != "none" ]; then
    DEFAULT_SVCS+=(containerd kubelet)
fi
# headscale control plane runs ONLY on the 'full' single-node role; every other
# role is a mesh CLIENT (tailscaled only).
if ${ROLE_HEADSCALE}; then
    DEFAULT_SVCS+=(headscale)
fi
if ! ${SKIP_MESH} && ! ${SKIP_TAILSCALE}; then
    DEFAULT_SVCS+=(tailscaled)
fi
if [ "${DESKTOP}" = "light" ]; then
    DEFAULT_SVCS+=(dbus elogind display-manager)
    mkdir -p "${SYSROOT}/etc/conf.d"
    echo 'DISPLAYMANAGER="lightdm"' > "${SYSROOT}/etc/conf.d/display-manager"
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
# Belt-and-suspenders for --resume sysroots (rpi5 audit finding): remove a
# stale headscale runlevel link on non-control roles.
if ! ${ROLE_HEADSCALE}; then
    rm -f "${SYSROOT}/etc/runlevels/default/headscale"
fi

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
    # (mirrors the Pi5 builder). SAFE: PKGDIR is ${BUILD_ROOT}/pkgdir under this
    # board's OWN BUILD_SUBDIR (snap-build-jetson) — reuse is same-board only,
    # never across boards (different -mcpu ⇒ SIGILL). --binpkg-respect-use=y
    # rejects a binpkg whose recorded USE ≠ the current config (rebuilds it).
}

# Don't cross-rebuild the toolchain (fails under crossdev). Same as Pi5/Frite.
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
# Before the FIRST --usepkg cross_emerge consumes ${BUILD_ROOT}/pkgdir, verify the
# pool's fingerprint (CHOST + exact CFLAGS/-mcpu + CXXFLAGS + profile, read from the
# rendered make.conf) matches THIS build. portage's --binpkg-respect-use checks USE
# only, never CFLAGS — so this is the ONLY check that catches a cross-board (different
# -mcpu) pool being reused, which would SIGILL at runtime. Fresh pool ⇒ stamped;
# mismatch ⇒ abort. Belt-and-suspenders over the per-board BUILD_SUBDIR isolation.
pool_fingerprint_preflight "${BUILD_ROOT}/pkgdir" "${SYSROOT}/etc/portage/make.conf" "${PROFILE_PATH:-}" \
    || { err "binpkg pool ABI mismatch (see above) — refusing --usepkg reuse."; exit 1; }

# ── EMERGE-GROUP BANNER (system) ──────────────────────────────────────────────
# Tells the Studio which of image|tools|dependencies|system|world the FOLLOWING
# ">>> Emerging (N of M) cat/pn-ver" stream belongs to, so the GUI sub-lists
# packages under the right group. This builder serves the mesh/node roles AND the
# client desktop role with the SAME emerges — the role only changes which atoms
# resolve_stage4_packages() returns, never WHICH emerges run — so one banner set
# covers every image this builder can produce. (--standalone parses here but is
# currently hard-blocked on this platform: it forces --encrypt-root, which the
# Orin's single-partition extlinux layout can't support — see the --encrypt-root
# err above. If that lands, it inherits these banners unchanged, exactly BECAUSE
# the grouping is role-independent.)
# ONE banner per contiguous run of the same group (a group is a SECTION of the
# stream; the parser holds it until the next transition), so baselayout and
# @system share this one rather than emitting a meaningless second step.
# baselayout + @system are the base layer/profile set — 'system', not payload.
banner "Emerge group: system"
cross_emerge --oneshot --update sys-apps/baselayout
cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" @system \
    || warn "@system had package failures (--keep-going); continuing"

banner "Emerging role payload (stage4, cross-compiled, role=${ROLE})"
# Resolved via resolve_stage4_packages() (defined above "Verifying
# prerequisites") — the SAME single-sourced resolver the qemu preflight
# consulted at t=0, so the two can never drift.
mapfile -t STAGE4_PACKAGES < <(resolve_stage4_packages)
[ -s "${SPECS_DIR}/portage/packages.list" ] || { err "packages.list is empty/missing: ${SPECS_DIR}/portage/packages.list"; exit 1; }
[ "${#STAGE4_PACKAGES[@]}" -gt 0 ] || { err "no stage4 packages resolved from the package lists — refusing to build a payload-less image."; exit 1; }
info "Package count: ${#STAGE4_PACKAGES[@]}"
# EMERGE-GROUP BANNER (image): STAGE4_PACKAGES IS the role package set — the image
# payload. The per-package retry loop below is the SAME group (it re-runs the very
# atoms this batch just failed on), so it deliberately does NOT re-announce.
banner "Emerge group: image"
if ! cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${STAGE4_PACKAGES[@]}"; then
    warn "Batch emerge failed (unsatisfiable atom?); retrying per-package so the rest still install"
    for _pkg in "${STAGE4_PACKAGES[@]}"; do
        cross_emerge --update --deep --newuse --keep-going "${CROSS_EXCLUDE[@]}" "${_pkg}" \
            || warn "  skipped ${_pkg}"
    done
fi

# ── Post-emerge payload assert (mirrors the x86/Frite "hollow stage4" guard) ──
have_in_sysroot() {
    local b="$1" d
    for d in usr/bin usr/sbin bin sbin usr/local/bin usr/local/sbin opt/bin; do
        [ -e "${SYSROOT}/${d}/${b}" ] && return 0
    done
    return 1
}
REQUIRED_BINS=(NetworkManager nmcli sshd nano)
if [ "${ROLE_K8S}" != "none" ]; then
    REQUIRED_BINS+=(containerd runc crictl kubelet kubeadm kubectl)
fi
if [ "${DESKTOP}" = "light" ]; then
    REQUIRED_BINS+=(Xorg openbox lxsession pcmanfm lightdm)
fi
if ${ENCRYPT_ROOT}; then
    REQUIRED_BINS+=(cryptsetup dracut)
fi
payload_missing=""
for _b in "${REQUIRED_BINS[@]}"; do
    have_in_sysroot "${_b}" || payload_missing="${payload_missing} ${_b}"
done
if [ -n "${payload_missing}" ]; then
    err "stage4 payload incomplete — missing role-defining binaries in ${SYSROOT}:${payload_missing}"
    err "       the package-list emerge did not complete; review the emerge output above."
    exit 1
fi
if [ "${DESKTOP}" = "light" ] && [ ! -e "${SYSROOT}/etc/init.d/display-manager" ]; then
    err "DESKTOP=light enables the 'display-manager' service but ${SYSROOT}/etc/init.d/display-manager is missing"
    err "       (gui-libs/display-manager-init did not emerge) — the desktop would boot to a console. Aborting."
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
# --allow-missing-packages: without it Phase 3 warn-skipped and the run ended
# exit 0 with a kernel-less stage4 and no .img. Fail HERE, before the mesh
# fetch and the multi-minute kernel phase, while the emerge output is still on
# screen. --skip-kernel is the only sanctioned kernel opt-out.
_kernel_gate_atom="sys-kernel/gentoo-sources"
${SKIP_KERNEL} && _kernel_gate_atom=""
requested_atom_gate "${SYSROOT}" "${BUILD_ROOT}" "build-jetson" \
    "${ALLOW_MISSING_PACKAGES}" "${_kernel_gate_atom}" "${STAGE4_PACKAGES[@]}" \
    || { err "requested-atom completeness gate failed (see the missing-atom list above)."; exit 1; }

# ── --packages-only: prebuild the binpkg pool, then STOP before image assembly ──
# The cross_emerge above populated PKGDIR (${BUILD_ROOT}/pkgdir) under
# FEATURES=buildpkg, and the payload assert just confirmed the pool built the role
# set. In --packages-only mode we exit NOW — before mesh, the kernel, the boot tree
# and the stage4 tarball — so the ONLY output is the per-board binpkg pool a later
# per-role image build reuses via --usepkg (guarded by the fingerprint preflight).
# The pool lives in ${BUILD_ROOT}/pkgdir (outside the sysroot), so it is never
# stripped. We emit NOTHING image-shaped.
if ${PACKAGES_ONLY}; then
    info "--packages-only: per-board binpkg pool prebuilt at ${BUILD_ROOT}/pkgdir — skipping image assembly (PLAN_PACKAGES_ONLY=1)"
    exit 0
fi

# ── Phase 2.5: mesh VPN (headscale + tailscale) — same as Pi5/Frite ─
if ${SKIP_MESH}; then
    banner "SKIPPED mesh VPN (--skip-mesh)"
else
    banner "Installing mesh VPN (headscale + tailscale, arm64)"
    HS_REL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}"
    HS_URL="${HS_REL}/headscale_${HEADSCALE_VERSION}_linux_arm64"
    HS_BIN="${SYSROOT}/usr/bin/headscale"
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
        file "${SYSROOT}/usr/bin/tailscale"   | grep -q 'ELF.*aarch64' || { err "tailscale binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
        file "${SYSROOT}/usr/sbin/tailscaled" | grep -q 'ELF.*aarch64' || { err "tailscaled binary is NOT aarch64 (wrong/corrupt download) — refusing to ship it."; exit 1; }
        info "tailscale installed + sha256-verified: /usr/bin/tailscale, /usr/sbin/tailscaled"
    fi
fi

fi  # IMAGE_ONLY skip of Phase 1+2

# ── Phase 3: Cross-compile the kernel (MAINLINE arm64 + Tegra234 DT) ──
# The l4t flavor exited above; this is the mainline route only. JETSON_KVER is
# captured for potential future initramfs use (the boot is initrd-less today —
# the boot-critical Tegra drivers are =y in the fragments).
JETSON_KVER=""
if ${SKIP_KERNEL}; then
    banner "SKIPPED kernel (--skip-kernel)"
else
    banner "Building hardened kernel (cross-compiled: mainline Tegra234)"
    KERNEL_SRC=$(find "${SYSROOT}/usr/src/" -maxdepth 1 -name 'linux-*' -type d 2>/dev/null | sort -V | tail -1)
    if [ -z "${KERNEL_SRC}" ]; then
        # No source tree despite the completeness gate proving gentoo-sources is
        # in the vdb (or the gate being bypassed). ONE legitimate shape: a
        # --resume onto a sysroot whose clean phase already removed /usr/src/*
        # but whose /boot still carries the previously-built kernel — reuse it.
        # Anything else used to warn-skip here and exit 0 with a kernel-less
        # stage4 and no .img.
        if [ -f "${SYSROOT}/boot/${JETSON_KERNEL_IMG}" ]; then
            warn "No kernel source tree under ${SYSROOT}/usr/src — but a previously-built kernel"
            warn "exists at /boot/${JETSON_KERNEL_IMG} (cleaned --resume sysroot); reusing it."
        else
            err "No kernel source tree under ${SYSROOT}/usr/src AND no previously-built kernel at"
            err "${SYSROOT}/boot/${JETSON_KERNEL_IMG} — nothing to boot; refusing to continue toward"
            err "a kernel-less artifact. (sys-kernel/gentoo-sources must merge, or pass"
            err "--skip-kernel to a sysroot that already carries a kernel.)"
            exit 1
        fi
    else
        info "Building kernel from ${KERNEL_SRC} (defconfig: ${JETSON_DEFCONFIG}, CPU: ${RPI_CPU})"
        pushd "${KERNEL_SRC}" >/dev/null
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" "${JETSON_DEFCONFIG}"
        # merge_config.sh handles Kconfig dependency resolution (same mechanism
        # as the Frite builder). Two fragments always; a third (LUKS2 crypt)
        # ONLY for --encrypt-root, so a plain build never carries the extra
        # kernel-config surface.
        _kernel_fragments=("${SPECS_DIR}/kernel/hardened-node.config" "${SPECS_DIR}/kernel/tegra234.config")
        ${ENCRYPT_ROOT} && _kernel_fragments+=("${SPECS_DIR}/kernel/luks-crypt.config")
        ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" \
            bash scripts/kconfig/merge_config.sh -m .config "${_kernel_fragments[@]}"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" olddefconfig
        # Refuse to ship a kernel that silently lost SELinux (fleet posture guard).
        for must in CONFIG_SECURITY_SELINUX CONFIG_SECURITY_SELINUX_BOOTPARAM; do
            grep -q "^${must}=y" .config || { err "SELinux kernel option ${must} not enabled after olddefconfig"; exit 1; }
        done
        grep -q '^CONFIG_LSM="yama,selinux,bpf"$' .config || { err "CONFIG_LSM malformed (expected yama,selinux,bpf)"; exit 1; }
        # Refuse to ship a kernel that silently lost LUKS2/dm-crypt support for
        # --encrypt-root builds (CONFIG_MD/BLK_DEV_DM/DM_CRYPT depend on each
        # other transitively — a --defconfig override lacking CONFIG_MD would
        # otherwise drop them with no build-time signal).
        if ${ENCRYPT_ROOT}; then
            for must in CONFIG_MD CONFIG_BLK_DEV_DM CONFIG_DM_CRYPT; do
                grep -q "^${must}=y" .config || { err "--encrypt-root requires ${must}=y but it did not survive olddefconfig (check --defconfig)"; exit 1; }
            done
        fi
        JETSON_KVER="$(make -s ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" kernelrelease 2>/dev/null | tail -1)"
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" -j"${JOBS}" Image modules dtbs
        make ARCH=arm64 CROSS_COMPILE="${CROSS_TARGET}-" INSTALL_MOD_PATH="${SYSROOT}" modules_install
        mkdir -p "${SYSROOT}/boot/dtb/nvidia"
        cp arch/arm64/boot/Image "${SYSROOT}/boot/${JETSON_KERNEL_IMG}"
        # Ship the FULL nvidia DTB dir (the board DTB is selected by extlinux's
        # FDT line) — kernel-owns-the-DTB, same policy as the Frite.
        cp -r arch/arm64/boot/dts/nvidia "${SYSROOT}/boot/dtb/" 2>/dev/null || \
            cp arch/arm64/boot/dts/nvidia/*.dtb "${SYSROOT}/boot/dtb/nvidia/" 2>/dev/null || true
        if [ ! -f "${SYSROOT}/boot/dtb/${JETSON_DTB}" ]; then
            err "Selected DTB ${JETSON_DTB} not found under ${SYSROOT}/boot/dtb after the kernel build — the board would not boot. Verify the in-tree DTB name for this kernel."
            exit 1
        fi
        popd >/dev/null
        info "Kernel build complete (Image + nvidia/tegra234 DTBs staged under /boot)."
    fi
fi

# ── LUKS2 root disk-boot initramfs (--encrypt-root) ─────────────────────────
# The Orin boots initrd-less today (boot-critical Tegra drivers are =y in the
# fragments) — --encrypt-root needs one to unlock the LUKS2 root before that
# root= is mounted. Generic (--no-hostonly) with the dracut "crypt" module,
# staged at ${SYSROOT}/boot/disk-initrd.img. Same proven 3-strategy cross-build
# fallback as build-frite-stage4.sh/build-rpi5-stage4.sh's
# build_disk_initramfs() (qemu-chroot / host-sh dracut / host dracut binary) —
# ported here since this is the FIRST time this board needs an initramfs at all.
JETSON_DISK_INITRD=""        # set non-empty once the disk-boot initramfs is staged
build_disk_initramfs() {
    [ -f "${SYSROOT}/boot/${JETSON_KERNEL_IMG}" ] || {
        warn "no kernel in sysroot boot — cannot build the disk-boot initramfs; an --encrypt-root build would NOT boot."
        return 1; }
    local kver="${JETSON_KVER}"
    if [ -z "${kver}" ] || [ ! -d "${SYSROOT}/lib/modules/${kver}" ]; then
        kver="$(find "${SYSROOT}/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
    fi
    [ -n "${kver}" ] && [ -d "${SYSROOT}/lib/modules/${kver}" ] || {
        warn "no module tree under ${SYSROOT}/lib/modules — cannot build the disk-boot initramfs; an --encrypt-root build would NOT boot."
        return 1; }

    local out="${SYSROOT}/boot/disk-initrd.img"
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
        _jetson_disk_umount() {
            local m
            for m in "${_mounts[@]}"; do umount -l "${m}" 2>/dev/null || true; done
            ${_qemu_staged} && rm -f "${SYSROOT}${_qemu_interp}" 2>/dev/null || true
        }
        trap '_jetson_disk_umount' RETURN
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
            JETSON_DISK_INITRD="${out}"
            _jetson_disk_umount; trap - RETURN
            info "Disk-boot initramfs staged (qemu-chroot): ${out} ($(du -h "${out}" | cut -f1))"
            return 0
        fi
        warn "qemu-chroot dracut did not produce a disk-boot initramfs; falling back."
        _jetson_disk_umount; trap - RETURN
    fi

    # ── Strategy 2: run the sysroot dracut script on the host sh ───────────────
    if [ -x "${sysroot_dracut}" ] && command -v sh >/dev/null; then
        sh "${sysroot_dracut}" --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                JETSON_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host-sh dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
        warn "sysroot dracut (host-sh) did not produce a disk-boot initramfs; trying host dracut."
    fi
    if command -v dracut >/dev/null; then
        dracut --force --no-hostonly \
            --add crypt --kver "${kver}" --kmoddir "${SYSROOT}/lib/modules/${kver}" \
            "${out}" 2>/dev/null && [ -s "${out}" ] && {
                JETSON_DISK_INITRD="${out}"
                info "Disk-boot initramfs staged (host dracut): ${out} ($(du -h "${out}" | cut -f1))"
                return 0; }
    fi
    warn "Could not generate the disk-boot initramfs (no usable dracut). An"
    warn "--encrypt-root build would be UNBOOTABLE without it."
    return 1
}
if ${ENCRYPT_ROOT}; then
    if ${SKIP_KERNEL}; then
        # --skip-kernel/--image-only doesn't regenerate the initramfs, but an
        # existing disk-initrd.img from a prior run of this same sysroot still
        # counts — the HARD REQUIREMENT below must still be enforced either way
        # (previously this whole block, including the fail-closed assert, was
        # skipped under --skip-kernel — silently shipping an unbootable image).
        [ -s "${SYSROOT}/boot/disk-initrd.img" ] && JETSON_DISK_INITRD="${SYSROOT}/boot/disk-initrd.img"
    else
        build_disk_initramfs || true
    fi
    if [ -z "${JETSON_DISK_INITRD}" ] || [ ! -s "${JETSON_DISK_INITRD}" ]; then
        err "--encrypt-root requires the disk-boot initramfs at ${SYSROOT}/boot/disk-initrd.img (see warnings above) — refusing to build a payload that cannot boot an encrypted root. (--skip-kernel/--image-only do not regenerate it; run once without --skip-kernel first, or --resume onto a sysroot that already has it.)"
        exit 1
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

banner "Staging the boot tree (extlinux boot config)"
# The Orin's UEFI distro-boots /boot/extlinux/extlinux.conf FROM THE ROOT
# FILESYSTEM (no separate boot partition, no u-boot) — see specs-jetson/boot/.
APPEND_BASE="$(cat "${SPECS_DIR}/boot/cmdline.base")"
mkdir -p "${SYSROOT}/boot/extlinux"
JETSON_INITRD_LINE="    # (initrd-less: boot-critical Tegra drivers are built in)"
JETSON_APPEND="${APPEND_BASE} root=LABEL=JETSON_ROOT"

# ── LUKS2 root (--encrypt-root): unlike x86/Frite/RPi5's install-time model,
# the LUKS UUID is CHOSEN HERE (not discovered from a formatted partition
# afterward) — build_img() below formats the container with --uuid="${LUKS_UUID}"
# later, so the extlinux cmdline and /etc/crypttab are correct on first render;
# no post-hoc sed rewrite of a baked file is needed at all. ────────────────
LUKS_UUID=""
LUKS_PASS_GENERATED=false
if ${ENCRYPT_ROOT}; then
    if command -v uuidgen >/dev/null 2>&1; then
        LUKS_UUID="$(uuidgen)"
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        LUKS_UUID="$(cat /proc/sys/kernel/random/uuid)"
    else
        err "--encrypt-root needs uuidgen (sys-apps/util-linux) or /proc/sys/kernel/random/uuid on the build host"
        exit 1
    fi
    # Guard against a broken/shimmed uuidgen (or truncated /proc read) that
    # exits 0 but yields an empty or malformed string — this UUID gets baked
    # into the cmdline, /etc/crypttab, AND cryptsetup's --uuid= with no other
    # checkpoint before it's used.
    if [[ ! "${LUKS_UUID}" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
        err "generated LUKS UUID is empty or malformed: '${LUKS_UUID}'"
        exit 1
    fi
    if [ -z "${LUKS_PASS}" ]; then
        # Bake-time passphrase generation (unlike LOCAL_PASSHASH's first-boot
        # mint): the LUKS container must be formatted with a real passphrase
        # NOW, so there is no later boot-time point to defer this to. Printed
        # ONCE at the end of the build; change it on the target via
        # `cryptsetup luksChangeKey` at first real login.
        if command -v openssl >/dev/null 2>&1; then
            LUKS_PASS="$(openssl rand -base64 18)"
        else
            LUKS_PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
        fi
        LUKS_PASS_GENERATED=true
    fi
    # rd.luks.name=<uuid>=cryptroot is REQUIRED alongside rd.luks.uuid=: with
    # no /etc/crypttab baked into the disk-boot initramfs itself (dracut is
    # run --no-hostonly, before this SYSROOT's own /etc/crypttab write below is
    # even relevant to it), dracut's crypt module would otherwise default the
    # mapper name to 'luks-<uuid>', not 'cryptroot' — root= would never resolve.
    JETSON_APPEND="${APPEND_BASE} root=/dev/mapper/cryptroot rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot"
    # Belt-and-suspenders: the ONLY place that generates/validates this file is
    # the SKIP_KERNEL-gated block above — re-check its existence right here so
    # a reused/--image-only sysroot that never actually built one still fails
    # loudly instead of rendering a boot config that points at nothing.
    [ -s "${SYSROOT}/boot/disk-initrd.img" ] || {
        err "--encrypt-root: ${SYSROOT}/boot/disk-initrd.img is missing — the sysroot was never built/validated with the disk-boot initramfs (e.g. --image-only reusing a pre-encrypt-root sysroot). Rebuild without --image-only/--skip-kernel first."
        exit 1
    }
    JETSON_INITRD_LINE="    INITRD /boot/disk-initrd.img"
    # crypttab: unlock 'cryptroot' from the LUKS partition at boot (passphrase
    # prompt via the disk-boot initramfs — no keyfile factor on this platform
    # yet). Written here (not after mkfs/extraction in build_img()) since the
    # UUID is already known — it flows into the image via build_img()'s own
    # tar-pipe of this SYSROOT, same as every other file under /etc.
    printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > "${SYSROOT}/etc/crypttab"
    chmod 0600 "${SYSROOT}/etc/crypttab"
else
    # Belt-and-suspenders for --resume sysroots: remove a stale /etc/crypttab
    # left behind by a prior --encrypt-root build of this same sysroot.
    rm -f "${SYSROOT}/etc/crypttab"
fi
render_template "${SPECS_DIR}/boot/extlinux.conf.tmpl" "${SYSROOT}/boot/extlinux/extlinux.conf"
if [ ! -f "${SYSROOT}/boot/${JETSON_KERNEL_IMG}" ]; then
    # Kernel-less here with the kernel phase ENABLED means Phase 3 was supposed
    # to stage /boot/${JETSON_KERNEL_IMG} this run and did not. Only
    # --skip-kernel makes a kernel-less stage4 a deliberate operator choice
    # (the documented TEGRAFLASH.md layering flow, where NVIDIA's L4T kernel is
    # layered on afterwards).
    if ${SKIP_KERNEL}; then
        warn "Kernel ${JETSON_KERNEL_IMG} not in sysroot /boot (--skip-kernel) — the image will not boot until one is added (TEGRAFLASH.md layering)."
    else
        err "Kernel ${JETSON_KERNEL_IMG} not in sysroot /boot after the kernel phase — the"
        err "artifact cannot boot. Review Phase 3 above."
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

IMG_PATH="(not built)"

build_img() {
    # Raw flashable image: GPT with a single ext4 root labeled JETSON_ROOT
    # containing /boot/extlinux/extlinux.conf — the Orin UEFI's L4TLauncher
    # scans exactly this layout on microSD/NVMe/USB. growroot expands the root
    # to the medium on first boot.
    [ -f "${SYSROOT}/boot/${JETSON_KERNEL_IMG}" ] || {
        ${ENCRYPT_ROOT} && { err "no kernel in sysroot /boot — cannot build the .img required by --encrypt-root (the only artifact this platform produces)"; exit 1; }
        # The .img is this platform's only directly bootable artifact. Skipping
        # it with exit 0 is the silent-degradation class the completeness gate
        # exists to end; only --skip-kernel makes the kernel-less stage4 (the
        # documented TEGRAFLASH.md layering flow) a deliberate operator choice.
        if ! ${SKIP_KERNEL}; then
            err "no kernel in sysroot /boot — cannot build the .img. The kernel phase was"
            err "enabled and produced nothing; review Phase 3 above. (Pass --skip-kernel +"
            err "--no-img for a deliberate TEGRAFLASH-layering stage4-only build.)"
            exit 1
        fi
        warn "no kernel in sysroot /boot (--skip-kernel) — skipping the .img (stage4 is still usable via TEGRAFLASH.md layering)."
        IMG_PATH="(not built — kernel missing)"; return 0; }

    IMG_PATH="${WORK_DIR}/${ART_PREFIX}.img"
    local total_mib=$(( ROOT_MiB + 16 ))   # GPT headroom
    info "Creating ${IMG_PATH} (${total_mib} MiB: ext4 root ${ROOT_MiB} MiB, label JETSON_ROOT)"
    rm -f "${IMG_PATH}"
    truncate -s "${total_mib}M" "${IMG_PATH}"
    parted -s "${IMG_PATH}" mklabel gpt \
        mkpart JETSON_ROOT ext4 4MiB "$(( ROOT_MiB + 4 ))MiB" \
        set 1 boot off

    local loopdev
    loopdev="$(losetup -Pf --show "${IMG_PATH}")" || {
        ${ENCRYPT_ROOT} && { err "losetup failed — cannot build the .img required by --encrypt-root"; exit 1; }
        warn "losetup failed — leaving the .img unpopulated"; IMG_PATH="(not built — losetup failed)"; return 0; }
    # Ensure the loop device (and, for --encrypt-root, the LUKS mapping) are
    # torn down on every exit path from here on. RETURN alone is NOT enough:
    # bash's RETURN trap only fires on an explicit `return`/normal fallthrough,
    # NOT when a later unguarded command in this function (mkfs.ext4, mount,
    # the tar-pipe, ...) trips `set -e` — ERR is required to actually catch
    # that case and close the LUKS mapping / detach the loop device instead of
    # leaking both on the build host.
    _jetson_img_cleanup() {
        # Disarm first so this can only ever run once, whether we get here via
        # a normal return, an early `return 0`, or an errexit-triggered abort —
        # traps are not function-scoped in bash, so leaving it armed would let
        # an unrelated later failure re-invoke this with out-of-scope locals.
        trap - RETURN ERR
        mountpoint -q "${STAGE_DIR}/imgroot" 2>/dev/null && umount "${STAGE_DIR}/imgroot" 2>/dev/null || true
        ${ENCRYPT_ROOT} && { cryptsetup close cryptroot 2>/dev/null || true; }
        [ -n "${loopdev}" ] && losetup -d "${loopdev}" 2>/dev/null || true
    }
    trap '_jetson_img_cleanup' RETURN ERR

    local part="${loopdev}p1"
    [ -b "${part}" ] || { sleep 1; partprobe "${loopdev}" 2>/dev/null || true; }
    [ -b "${part}" ] || {
        ${ENCRYPT_ROOT} && { err "partition ${part} did not appear — cannot build the .img required by --encrypt-root"; exit 1; }
        warn "partition ${part} did not appear — leaving the .img unpopulated"; IMG_PATH="(not built — no loop partition)"; return 0; }

    local root_dev="${part}"
    if ${ENCRYPT_ROOT}; then
        info "Creating LUKS2 container on ${part} (uuid=${LUKS_UUID})"
        # cryptsetup's argon2id PBKDF auto-benchmark calibrates cost to whatever
        # host runs THIS builder — but that is never the machine that unlocks
        # the root (the Orin itself, at every future boot). Pin explicit,
        # bounded cost parameters instead of inheriting a cost tuned to a fast
        # cross-build host and paid at every boot by the weaker target.
        printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 --uuid="${LUKS_UUID}" \
            --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
            --pbkdf-memory 262144 --iter-time 2000 --pbkdf-parallel 4 \
            --batch-mode "${part}" -
        # Clear a stale 'cryptroot' mapping left by a prior interrupted run —
        # otherwise this open fails with cryptsetup's native "Device cryptroot
        # already exists."
        cryptsetup close cryptroot 2>/dev/null || true
        printf '%s' "${LUKS_PASS}" | cryptsetup open "${part}" cryptroot -
        root_dev="/dev/mapper/cryptroot"
    fi
    mkfs.ext4 -q -L JETSON_ROOT "${root_dev}"
    mkdir -p "${STAGE_DIR}/imgroot"
    mount "${root_dev}" "${STAGE_DIR}/imgroot"
    info "Populating the root filesystem from the sysroot ..."
    tar -C "${SYSROOT}" --xattrs-include='*.*' --numeric-owner -cpf - \
        --exclude='./usr/src' --exclude='./var/cache/distfiles' --exclude='./tmp/*' . \
        | tar -C "${STAGE_DIR}/imgroot" --xattrs-include='*.*' --numeric-owner -xpf - 2>/dev/null || \
    tar -C "${SYSROOT}" --numeric-owner -cpf - \
        --exclude='./usr/src' --exclude='./var/cache/distfiles' --exclude='./tmp/*' . \
        | tar -C "${STAGE_DIR}/imgroot" --numeric-owner -xpf -
    sync
    umount "${STAGE_DIR}/imgroot"
    # Close the LUKS mapping only AFTER unmounting — cryptsetup close fails (and
    # would leave the mapper device dangling) if the filesystem on top is still
    # mounted. Suppressed/non-fatal: a transient 'device busy' right after
    # umount (dm-crypt holders/udev not yet released) shouldn't abort a
    # successful build.
    ${ENCRYPT_ROOT} && { cryptsetup close cryptroot 2>/dev/null || true; }
    losetup -d "${loopdev}"; loopdev=""
    trap - RETURN ERR
    info "Raw image: ${IMG_PATH} ($(du -sh "${IMG_PATH}" | cut -f1))"
    if ${COMPRESS_IMG}; then
        xz -T0 -9 -f "${IMG_PATH}"; IMG_PATH="${IMG_PATH}.xz"
    fi
    return 0
}

if ${BUILD_IMG}; then
    banner "Building raw .img (flashable SD/NVMe)"
    build_img
    # Belt-and-suspenders: catches ANY degrade-to-warn path inside build_img()
    # (present and future) that lets IMG_PATH end up as a "(not built — ...)"
    # placeholder instead of a real artifact — without this, a build could
    # exit 0 and print a full success banner (including the LUKS passphrase
    # disclosure below) while producing no image at all.
    if ${ENCRYPT_ROOT} && [[ "${IMG_PATH}" != *.img && "${IMG_PATH}" != *.img.xz ]]; then
        err "--encrypt-root requires a built .img but none was produced (IMG_PATH=${IMG_PATH}) — refusing to report success."
        exit 1
    fi
else
    banner "SKIPPED raw .img (--no-img)"
fi

echo ""
echo -e "${CYAN}${BOLD}=============================================="
echo "  Jetson Orin (Tegra234) build complete — EXPERIMENTAL"
echo "==============================================${RESET}"
echo ""
echo "  Board:          ${JETSON_BOARD_DESC}"
echo "  DTB:            ${JETSON_DTB}"
echo "  Kernel flavor:  ${KERNEL_FLAVOR} (mainline = NO CUDA; see specs-jetson/kernel/README.md)"
echo "  Role:           ${ROLE}   (k8s=${ROLE_K8S}, edge-ai service=${EDGE_AI}, desktop=${DESKTOP})"
echo "  ENV:            ${ENV}"
echo "  Brand:          ${BRAND} / \"${BRAND_TITLE}\" / ${ORG}"
echo "  Hostname:       ${HOSTNAME}"
echo ""
echo "  Mesh + provisioning (SAME as the other node images):"
echo "    - headscale ${HEADSCALE_VERSION} + tailscale ${TAILSCALE_VERSION} (joins the fleet tailnet)"
echo "    - First-boot KEYS-USB provisioning (users, ssh keys, Casdoor login, certs)"
echo "    - Hardened sshd: key-only, prohibit-password"
echo ""
echo "  Artifacts:"
echo "    Work directory:  ${WORK_DIR}"
echo "    Stage4 tarball:  ${STAGE4_TARBALL}"
echo "    Raw image:       ${IMG_PATH}"
echo ""
echo "  === Post-build ==="
echo "  FLASH: write the .img to microSD/NVMe (dd / scripts/flash-disk.sh) and boot —"
echo "         a current Orin devkit UEFI distro-boots /boot/extlinux/extlinux.conf."
echo "  QSPI / L4T+CUDA: out-of-band recovery-mode tegraflash — see"
echo "         specs-jetson/installer/TEGRAFLASH.md."
echo ""
if ${ENCRYPT_ROOT}; then
    echo -e "  ${YELLOW}${BOLD}Root is LUKS2-encrypted — boot will prompt for the passphrase.${RESET}"
    if ${LUKS_PASS_GENERATED}; then
        # Written to fd 3 (the pre-tee terminal fd saved before "exec >
        # >(tee -a "${LOG_FILE}")" was installed), NOT the tee'd stdout every
        # other echo/info in this script goes through — a plain echo here
        # would also land in build.log, directly contradicting "does not
        # persist it anywhere".
        echo -e "  ${RED}${BOLD}Generated LUKS passphrase (shown ONCE — this build does not persist it" >&3
        echo -e "  anywhere): ${LUKS_PASS}${RESET}" >&3
        echo "  Record it now. Change it after first boot: cryptsetup luksChangeKey <root-partition>." >&3
        echo -e "  ${RED}${BOLD}(passphrase redacted from build.log; see terminal scrollback only)${RESET}"
    fi
    echo ""
fi
unset LUKS_PASS
echo -e "  ${YELLOW}${BOLD}REMINDER: EXPERIMENTAL — no physical Orin has booted this image yet."
echo -e "  Validate on hardware before shipping (specs-jetson/README.md).${RESET}"
echo ""
