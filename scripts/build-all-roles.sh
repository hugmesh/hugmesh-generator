#!/usr/bin/env bash
# build-all-roles.sh — build the HugMesh node images + each role's KEYS folder.
#
# DEFAULT build set:
#   * RPi 5 (aarch64):  pki, backend, frontend                 (build-rpi5-stage4.sh)
#   * x86_64 (amd64):   pki, backend, frontend, backend-gpu  (every role EXCEPT omnibus)
#     ONE vocabulary across platforms now (scripts/_roles-lib.sh): the Pi and the
#     x86 set name the same logical roles with the same tokens. The old spellings
#     (be, fe, be+gpu, host, be-gpu, gpu-host, gpu_host, full, edge_ai) are still
#     accepted on every --role, forever, and are normalized at parse time.
#
# Only the x86 omnibus (all-in-one single-node) role is OPT-IN:
#   X86_OMNIBUS=1 ./scripts/build-all-roles.sh  # appends omnibus to the x86 set
#   X86_ALL=1     ./scripts/build-all-roles.sh  # pki backend frontend backend-gpu omnibus on x86
#   X86_ROLES="pki omnibus" ./scripts/build-all-roles.sh   # an explicit subset
#   SKIP_X86=1    ./scripts/build-all-roles.sh  # Pi roles only (no x86 at all)
#   SKIP_RPI=1    ./scripts/build-all-roles.sh  # x86 / frite only (no RPi5 builds)
#
# The RPi5 default set (pki backend frontend) is overridable too — e.g. to fold
# in the rpi5 client-desktop role built by the SAME builder:
#   RPI_ROLES="pki backend frontend desktop" ./scripts/build-all-roles.sh
#   RPI_ROLES="desktop" ./scripts/build-all-roles.sh   # ONLY the rpi5 desktop
# (build-rpi5-stage4.sh — roles: pki | backend | frontend | desktop.)
#
# --board rpi5|rpi4|rpi3 (SAME builder, a board table — not a separate script):
#   RPI_BOARD=rpi4 ./scripts/build-all-roles.sh   # build every selected RPI_ROLES for Pi 4 instead
# (default: rpi5, so an unset RPI_BOARD is 100% unaffected by this axis.)
# RPI_BOARD=rpi3 is DESKTOP-ONLY (1GB RAM) — the builder hard-errors on any
# RPI_ROLES entry but desktop, so pair it with RPI_ROLES=desktop:
#   RPI_ROLES=desktop RPI_BOARD=rpi3 ./scripts/build-all-roles.sh
# (the default RPI_ROLES="pki backend frontend" would hard-error on its very
# first role with RPI_BOARD=rpi3 — this is the intended safety net, not a bug.)
#
# The Libre Computer Le/La Frite LIGHT-DESKTOP client image is OPT-IN (it is a
# desktop appliance, not a cluster node, so it is NOT in the default fleet):
#   FRITE=1       ./scripts/build-all-roles.sh  # ALSO build the Frite (la-frite, both flavors)
#   FRITE_BOARD=le-potato FRITE=1 ./scripts/build-all-roles.sh   # the pricier S905X sibling
#   FRITE_ONLY=1  ./scripts/build-all-roles.sh  # ONLY the Frite (skip Pi + x86)
#   FRITE_FLAVOR=live FRITE=1 ./scripts/build-all-roles.sh       # live image only
#   FRITE_DESKTOP=none FRITE=1 ./scripts/build-all-roles.sh      # headless base (no LXDE)
# (build-frite-stage4.sh — see docs/RUNNING.md §"Frite light-desktop image".)
#
# The NVIDIA Jetson Orin (Tegra234 arm64) edge-AI platform is OPT-IN too —
# EXPERIMENTAL: hardware validation pending (specs-jetson/README.md). Knobs
# mirror the FRITE family exactly:
#   JETSON=1      ./scripts/build-all-roles.sh  # ALSO build the Jetson (edge-ai role)
#   JETSON_ROLES="edge-ai desktop" JETSON=1 ./scripts/build-all-roles.sh   # role subset
#   JETSON_ONLY=1 ./scripts/build-all-roles.sh  # ONLY the Jetson (skip Pi + x86 + Frite)
#   JETSON_BOARD=orin-nx-16gb JETSON=1 ./scripts/build-all-roles.sh        # other module
#   JETSON_KERNEL_FLAVOR=l4t JETSON=1 ./scripts/build-all-roles.sh  # (stubbed) L4T/CUDA path
# (build-jetson-stage4.sh — roles: edge-ai (default) | backend-gpu | omnibus | desktop.)
#
# The Orange Pi 5 / Orange Pi 5 Plus (Rockchip RK3588/RK3588S) light-desktop
# client image is OPT-IN too — EXPERIMENTAL: hardware validation pending
# (specs-orangepi5/README.md). Knobs mirror the FRITE family exactly (board +
# flavor, no role axis — this is a ONE-role client device, like Frite):
#   ORANGEPI5=1      ./scripts/build-all-roles.sh  # ALSO build it (orange-pi-5-plus, both flavors)
#   ORANGEPI5_BOARD=orange-pi-5 ORANGEPI5=1 ./scripts/build-all-roles.sh   # the smaller-I/O sibling
#   ORANGEPI5_ONLY=1 ./scripts/build-all-roles.sh  # ONLY it (skip Pi + x86 + Frite + Jetson)
#   ORANGEPI5_FLAVOR=live ORANGEPI5=1 ./scripts/build-all-roles.sh          # live image only
# (build-orangepi5-stage4.sh — see specs-orangepi5/README.md.)
#
# The Orange Pi Zero 2 (Allwinner H616) HEADLESS appliance image is OPT-IN too —
# EXPERIMENTAL: hardware validation pending (specs-orangepi-zero2/README.md).
# One board, one role (appliance) — no board/role axis, just flavor:
#   ORANGEPIZERO2=1      ./scripts/build-all-roles.sh  # ALSO build it (both flavors)
#   ORANGEPIZERO2_ONLY=1 ./scripts/build-all-roles.sh  # ONLY it (skip everything else)
#   ORANGEPIZERO2_FLAVOR=live ORANGEPIZERO2=1 ./scripts/build-all-roles.sh    # live image only
# (build-orangepi-zero2-stage4.sh — see specs-orangepi-zero2/README.md. No desktop
# role: the H616's display engine has no mainline driver, so this platform is
# headless-only by design, not an oversight.)
#
# The Orange Pi Zero 2W (Allwinner H618) HEADLESS appliance image is OPT-IN too —
# EXPERIMENTAL: hardware validation pending (specs-orangepi-zero2w/README.md).
# One board, one role (appliance) — no board/role axis, just flavor:
#   ORANGEPIZERO2W=1      ./scripts/build-all-roles.sh  # ALSO build it (both flavors)
#   ORANGEPIZERO2W_ONLY=1 ./scripts/build-all-roles.sh  # ONLY it (skip everything else)
#   ORANGEPIZERO2W_FLAVOR=live ORANGEPIZERO2W=1 ./scripts/build-all-roles.sh   # live image only
# (build-orangepi-zero2w-stage4.sh — see specs-orangepi-zero2w/README.md. Same
# headless-only H616-family DE33 rationale as the Zero 2; NO onboard Ethernet
# on this board — USB-Ethernet-first.)
#
# The Orange Pi Zero 3 (Allwinner H618) HEADLESS appliance image is OPT-IN too —
# EXPERIMENTAL: hardware validation pending (specs-orangepi-zero3/README.md).
# One board, one role (appliance) — no board/role axis, just flavor:
#   ORANGEPIZERO3=1      ./scripts/build-all-roles.sh  # ALSO build it (both flavors)
#   ORANGEPIZERO3_ONLY=1 ./scripts/build-all-roles.sh  # ONLY it (skip everything else)
#   ORANGEPIZERO3_FLAVOR=live ORANGEPIZERO3=1 ./scripts/build-all-roles.sh   # live image only
# (build-orangepi-zero3-stage4.sh — see specs-orangepi-zero3/README.md. Same
# headless-only H616-family DE33 rationale as the Zero 2/Zero 2W; onboard
# Gigabit Ethernet is back on this board — Ethernet-first, like the Zero 2.)
#
# The Orange Pi 3 LTS (Allwinner H6) HEADLESS appliance image is OPT-IN too —
# EXPERIMENTAL: hardware validation pending (specs-orangepi3-lts/README.md).
# One board, one role (appliance) — no board/role axis, just flavor:
#   ORANGEPI3LTS=1      ./scripts/build-all-roles.sh  # ALSO build it (both flavors)
#   ORANGEPI3LTS_ONLY=1 ./scripts/build-all-roles.sh  # ONLY it (skip everything else)
#   ORANGEPI3LTS_FLAVOR=live ORANGEPI3LTS=1 ./scripts/build-all-roles.sh   # live image only
#
# Orange Pi 4 LTS (Rockchip RK3399 arm64 LIGHT DESKTOP) is OFF by default too —
# EXPERIMENTAL: hardware validation pending (specs-orangepi4-lts/README.md).
#   ORANGEPI4LTS=1      ./scripts/build-all-roles.sh  # ALSO build it (both flavors)
#   ORANGEPI4LTS_ONLY=1 ./scripts/build-all-roles.sh  # ONLY it (skip everything else)
#   ORANGEPI4LTS_FLAVOR=live ORANGEPI4LTS=1 ./scripts/build-all-roles.sh   # live image only
# (build-orangepi3-lts-stage4.sh — see specs-orangepi3-lts/README.md. Headless
# by SCOPE decision (H6 display support exists in mainline but is partial and
# the DTB is the PLAIN OPi3's — mainline has no -lts variant); onboard GbE is
# DEAD on that DTB, so this appliance is USB-Ethernet-first like the Zero 2W.)
#
# Pen-test build OPTION (DEV / CI-pipeline only) — run the OWASP pen-test harness
# as part of the build (memory hugmesh-pentest-standard "an OPTION in the BUILD
# pipeline"). It is NOT a deployed runner; it drives tests/pentest/run-pentest.sh
# against an env-test-build using PUBLIC images (owasp/dependency-check + zaproxy):
#   PENTEST=1     ./scripts/build-all-roles.sh   # run the pen-test after the build
#   ./scripts/build-all-roles.sh --pentest       # same, as a flag
#   PENTEST=1 PENTEST_ENV=local PENTEST_SCAN=full ./scripts/build-all-roles.sh
# Knobs:  PENTEST_ENV   = compose (default) | local | cluster   (run-pentest --env)
#         PENTEST_SCAN  = baseline (default) | full             (run-pentest --scan)
#         PENTEST_PIPELINE = main (default) | games             (run-pentest --pipeline)
# PENTEST_ONLY=1 runs ONLY the pen-test (skips the image builds + keys).
#
# Any extra args are passed through to BOTH builders, e.g.:
#   ./scripts/build-all-roles.sh -j 16 --cluster-domain hugmesh.net
#
# Build ENV (baked at image creation) is just another pass-through flag:
#   ./scripts/build-all-roles.sh --env test  --config brands/local.conf  # LAN fleet
#   ./scripts/build-all-roles.sh --env prod                              # go-live fleet
# Default (no --env) is the builders' own default = test (local-first/safe).
#
# Env:
#   WORK_DIR    work/target dir (default ./out, local + gitignored). Keep in sync
#               with any -w/--work-dir you pass through. The finished PRODUCTS
#               (.img/.iso/.fs.tar.xz/stage4/keys-*) land directly in WORK_DIR;
#               each arch's HEAVY build tree (sysroot/distfiles/pkgdir) lives in a
#               PER-ARCH subdir (WORK_DIR/snap-build-pi5 vs WORK_DIR/snap-build-x86)
#               so the aarch64 (Pi) and amd64 (x86) builds never share a sysroot.
#   SKIP_KEYS=1 don't generate the per-role keys folders (Pi roles).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_RPI="${REPO_DIR}/build-rpi5-stage4.sh"
BUILD_X86="${REPO_DIR}/build-x86-host-stage4.sh"
BUILD_FRITE="${REPO_DIR}/build-frite-stage4.sh"
BUILD_JETSON="${REPO_DIR}/build-jetson-stage4.sh"
BUILD_ORANGEPI5="${REPO_DIR}/build-orangepi5-stage4.sh"
BUILD_ORANGEPIZERO2="${REPO_DIR}/build-orangepi-zero2-stage4.sh"
BUILD_ORANGEPIZERO2W="${REPO_DIR}/build-orangepi-zero2w-stage4.sh"
BUILD_ORANGEPIZERO3="${REPO_DIR}/build-orangepi-zero3-stage4.sh"
BUILD_ORANGEPI3LTS="${REPO_DIR}/build-orangepi3-lts-stage4.sh"
BUILD_ORANGEPI4LTS="${REPO_DIR}/build-orangepi4-lts-stage4.sh"
GENKEYS="${SCRIPT_DIR}/gen-provision-keys.sh"
# THE role vocabulary (scripts/_roles-lib.sh) — the role->KEYS-profile table below
# comes from here, not from a fourth hand-copy of it.
# shellcheck source=scripts/_roles-lib.sh
source "${SCRIPT_DIR}/_roles-lib.sh"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/out}"
# Honor a -w/--work-dir passed through to the builders so the keys-<role> folders
# land beside the images (recommend a dir OUTSIDE an encrypted/$HOME mount).
BUILD_ENV="test"   # mirror the builders' default for the summary line below
# --pentest is consumed HERE (not a builder flag); collect the remaining args so it
# is NOT forwarded to the per-role builders. PENTEST=1 sets the same toggle.
PENTEST="${PENTEST:-0}"
PASS_ARGS=()
_skip_next=0
for ((_i = 1; _i <= $#; _i++)); do
    # The token AFTER -w/--env is its value: capture it, then pass it through (once).
    if [ "${_skip_next}" = 1 ]; then _skip_next=0; PASS_ARGS+=("${!_i}"); continue; fi
    case "${!_i}" in
        -w|--work-dir) _j=$((_i + 1)); WORK_DIR="${!_j}"; PASS_ARGS+=("${!_i}"); _skip_next=1 ;;
        --env)         _j=$((_i + 1)); BUILD_ENV="${!_j}"; PASS_ARGS+=("${!_i}"); _skip_next=1 ;;
        --pentest)     PENTEST=1 ;;   # consumed — do NOT pass through to builders
        *)             PASS_ARGS+=("${!_i}") ;;
    esac
done
# Replace the positional params with the pass-through set (sans --pentest) so the
# builder invocations below keep using "$@" unchanged.
set -- "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"

# PENTEST_ONLY=1 implies PENTEST=1 and skips the image builds + keys.
if [ "${PENTEST_ONLY:-0}" = "1" ]; then
    PENTEST=1
    SKIP_X86=1; SKIP_KEYS=1
fi

# RPi5 role set. Default = the 3 cluster-node roles (pki backend frontend); the
# rpi5-desktop client role is opt-in (RPI_ROLES override) since it needs
# --standalone/--local-user/--local-pass to be a self-contained appliance,
# same reasoning as x86's standalone-thin/thick staying out of the default set.
if [ "${PENTEST_ONLY:-0}" = "1" ]; then
    RPI_ROLES=()   # pentest-only: no image builds
elif [ "${SKIP_RPI:-0}" = "1" ]; then
    RPI_ROLES=()   # SKIP_RPI=1: x86-only or frite-only run
elif [ -n "${RPI_ROLES:-}" ]; then
    read -r -a RPI_BUILD_ROLES <<< "${RPI_ROLES}"
    RPI_ROLES=("${RPI_BUILD_ROLES[@]}")
else
    RPI_ROLES=(pki backend frontend)
fi
# --board rpi5 (DEFAULT) | rpi4 | rpi3 — the SAME build-rpi5-stage4.sh builder,
# a board table rather than a separate script (see its Phase 6/8 header
# notes). Threaded through EVERY selected RPI_ROLES entry below. Default rpi5
# keeps an unset RPI_BOARD 100% unaffected by this axis. rpi3 is DESKTOP-ONLY
# (see the header note above) — pair it with RPI_ROLES=desktop.
RPI_BOARD_SEL="${RPI_BOARD:-rpi5}"

# x86 role set. Default = every role EXCEPT omnibus (pki backend frontend backend-gpu). Only the
# omnibus all-in-one role is opt-in: X86_OMNIBUS=1 appends it; X86_ALL=1 expands
# to every role (incl. omnibus); X86_ROLES overrides explicitly; SKIP_X86=1
# disables the x86 build entirely.
if [ "${SKIP_X86:-0}" = "1" ]; then
    X86_BUILD_ROLES=()
elif [ "${X86_STANDALONE_ONLY:-0}" = "1" ]; then
    # ONLY the standalone desktops (skip the cluster node roles): the two hardened
    # NVIDIA variants + the UNAFFILIATED plain Gentoo one.
    X86_BUILD_ROLES=(standalone-thin standalone-thick standalone-unaffiliated)
    RPI_ROLES=()
elif [ -n "${X86_ROLES:-}" ]; then
    read -r -a X86_BUILD_ROLES <<< "${X86_ROLES}"
elif [ "${X86_ALL:-0}" = "1" ]; then
    X86_BUILD_ROLES=(pki backend frontend backend-gpu omnibus)
elif [ "${X86_OMNIBUS:-0}" = "1" ]; then
    X86_BUILD_ROLES=(pki backend frontend backend-gpu omnibus)
else
    X86_BUILD_ROLES=(pki backend frontend backend-gpu)
fi
# X86_STANDALONE=1 appends the standalone desktop variants (thin + thick hardened
# NVIDIA + the UNAFFILIATED plain Gentoo one) to whatever x86 set was selected.
# Each auto-enables LUKS FDE on install + emits all four artifacts (live ISO,
# stage4, .fs.tar.xz, installer ISO).
if [ "${X86_STANDALONE:-0}" = "1" ] && [ "${X86_STANDALONE_ONLY:-0}" != "1" ]; then
    X86_BUILD_ROLES+=(standalone-thin standalone-thick standalone-unaffiliated)
fi

# Frite light-desktop is OPT-IN. FRITE_ONLY=1 builds ONLY the Frite (skip Pi/x86).
BUILD_FRITE_IMG=false
if [ "${FRITE_ONLY:-0}" = "1" ]; then
    BUILD_FRITE_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=()
elif [ "${FRITE:-0}" = "1" ]; then
    BUILD_FRITE_IMG=true
fi
FRITE_BOARD_SEL="${FRITE_BOARD:-la-frite}"
FRITE_FLAVOR_SEL="${FRITE_FLAVOR:-both}"
FRITE_DESKTOP_SEL="${FRITE_DESKTOP:-light}"

# Jetson Orin edge-AI platform is OPT-IN (EXPERIMENTAL — hardware validation
# pending). Knobs mirror the FRITE family: JETSON=1 adds it, JETSON_ONLY=1
# builds ONLY it, JETSON_ROLES picks the role subset (default: the edge-ai
# headline), JETSON_BOARD / JETSON_KERNEL_FLAVOR thread to the builder.
BUILD_JETSON_IMG=false
if [ "${JETSON_ONLY:-0}" = "1" ]; then
    BUILD_JETSON_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false
elif [ "${JETSON:-0}" = "1" ]; then
    BUILD_JETSON_IMG=true
fi
read -r -a JETSON_BUILD_ROLES <<< "${JETSON_ROLES:-edge-ai}"
JETSON_BOARD_SEL="${JETSON_BOARD:-orin-nano}"
JETSON_KFLAVOR_SEL="${JETSON_KERNEL_FLAVOR:-mainline}"

# Orange Pi 5 / Orange Pi 5 Plus is OPT-IN (EXPERIMENTAL — hardware validation
# pending). ORANGEPI5_ONLY=1 builds ONLY it (skip Pi/x86/Frite/Jetson) — same
# shape as FRITE_ONLY/JETSON_ONLY above.
BUILD_ORANGEPI5_IMG=false
if [ "${ORANGEPI5_ONLY:-0}" = "1" ]; then
    BUILD_ORANGEPI5_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false; BUILD_JETSON_IMG=false
elif [ "${ORANGEPI5:-0}" = "1" ]; then
    BUILD_ORANGEPI5_IMG=true
fi
ORANGEPI5_BOARD_SEL="${ORANGEPI5_BOARD:-orange-pi-5-plus}"
ORANGEPI5_FLAVOR_SEL="${ORANGEPI5_FLAVOR:-both}"

# Orange Pi Zero 2 (Allwinner H616) headless appliance is OPT-IN (EXPERIMENTAL
# — hardware validation pending). ORANGEPIZERO2_ONLY=1 builds ONLY it (skip
# everything else) — same shape as ORANGEPI5_ONLY above. No board axis (one
# board) and no role axis (appliance only — headless, no desktop role).
BUILD_ORANGEPIZERO2_IMG=false
if [ "${ORANGEPIZERO2_ONLY:-0}" = "1" ]; then
    BUILD_ORANGEPIZERO2_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false; BUILD_JETSON_IMG=false; BUILD_ORANGEPI5_IMG=false
elif [ "${ORANGEPIZERO2:-0}" = "1" ]; then
    BUILD_ORANGEPIZERO2_IMG=true
fi
ORANGEPIZERO2_FLAVOR_SEL="${ORANGEPIZERO2_FLAVOR:-both}"

# Orange Pi Zero 2W (Allwinner H618) headless appliance is OPT-IN (EXPERIMENTAL
# — hardware validation pending). ORANGEPIZERO2W_ONLY=1 builds ONLY it (skip
# everything else) — same shape as ORANGEPIZERO2_ONLY above. No board axis (one
# board) and no role axis (appliance only — headless, no desktop role).
BUILD_ORANGEPIZERO2W_IMG=false
if [ "${ORANGEPIZERO2W_ONLY:-0}" = "1" ]; then
    BUILD_ORANGEPIZERO2W_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false; BUILD_JETSON_IMG=false; BUILD_ORANGEPI5_IMG=false; BUILD_ORANGEPIZERO2_IMG=false
elif [ "${ORANGEPIZERO2W:-0}" = "1" ]; then
    BUILD_ORANGEPIZERO2W_IMG=true
fi
ORANGEPIZERO2W_FLAVOR_SEL="${ORANGEPIZERO2W_FLAVOR:-both}"

# Orange Pi Zero 3 (Allwinner H618) headless appliance is OPT-IN (EXPERIMENTAL
# — hardware validation pending). ORANGEPIZERO3_ONLY=1 builds ONLY it (skip
# everything else) — same shape as ORANGEPIZERO2_ONLY above. No board axis (one
# board) and no role axis (appliance only — headless, no desktop role).
BUILD_ORANGEPIZERO3_IMG=false
if [ "${ORANGEPIZERO3_ONLY:-0}" = "1" ]; then
    BUILD_ORANGEPIZERO3_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false; BUILD_JETSON_IMG=false; BUILD_ORANGEPI5_IMG=false; BUILD_ORANGEPIZERO2_IMG=false; BUILD_ORANGEPIZERO2W_IMG=false
elif [ "${ORANGEPIZERO3:-0}" = "1" ]; then
    BUILD_ORANGEPIZERO3_IMG=true
fi
ORANGEPIZERO3_FLAVOR_SEL="${ORANGEPIZERO3_FLAVOR:-both}"

# Orange Pi 3 LTS (Allwinner H6) headless appliance is OPT-IN (EXPERIMENTAL
# — hardware validation pending). ORANGEPI3LTS_ONLY=1 builds ONLY it (skip
# everything else) — same shape as ORANGEPIZERO2_ONLY above. No board axis (one
# board) and no role axis (appliance only — headless, no desktop role).
BUILD_ORANGEPI3LTS_IMG=false
if [ "${ORANGEPI3LTS_ONLY:-0}" = "1" ]; then
    BUILD_ORANGEPI3LTS_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false; BUILD_JETSON_IMG=false; BUILD_ORANGEPI5_IMG=false; BUILD_ORANGEPIZERO2_IMG=false; BUILD_ORANGEPIZERO2W_IMG=false; BUILD_ORANGEPIZERO3_IMG=false
elif [ "${ORANGEPI3LTS:-0}" = "1" ]; then
    BUILD_ORANGEPI3LTS_IMG=true
fi
ORANGEPI3LTS_FLAVOR_SEL="${ORANGEPI3LTS_FLAVOR:-both}"

# Orange Pi 4 LTS (Rockchip RK3399) LIGHT DESKTOP is OPT-IN (EXPERIMENTAL —
# hardware validation pending). ORANGEPI4LTS_ONLY=1 builds ONLY it (skip
# everything else) — same shape as ORANGEPI3LTS_ONLY above. No board axis (one
# mainline DTB/defconfig for the whole RK3399 Orange Pi family). UNLIKE every
# other Orange Pi platform here this one IS a desktop client, but it still has
# no role axis: one role, and no headless variant to gate.
BUILD_ORANGEPI4LTS_IMG=false
if [ "${ORANGEPI4LTS_ONLY:-0}" = "1" ]; then
    BUILD_ORANGEPI4LTS_IMG=true
    RPI_ROLES=(); X86_BUILD_ROLES=(); BUILD_FRITE_IMG=false; BUILD_JETSON_IMG=false; BUILD_ORANGEPI5_IMG=false; BUILD_ORANGEPIZERO2_IMG=false; BUILD_ORANGEPIZERO2W_IMG=false; BUILD_ORANGEPIZERO3_IMG=false; BUILD_ORANGEPI3LTS_IMG=false
elif [ "${ORANGEPI4LTS:-0}" = "1" ]; then
    BUILD_ORANGEPI4LTS_IMG=true
fi
ORANGEPI4LTS_FLAVOR_SEL="${ORANGEPI4LTS_FLAVOR:-both}"

echo "==> RPi5 roles:  ${RPI_ROLES[*]:-(none)}  (board=${RPI_BOARD_SEL})"
echo "==> x86 roles:   ${X86_BUILD_ROLES[*]:-(none)}"
echo "==> Frite:       $([ "${BUILD_FRITE_IMG}" = true ] && echo "${FRITE_BOARD_SEL} (flavor=${FRITE_FLAVOR_SEL}, desktop=${FRITE_DESKTOP_SEL})" || echo '(off — set FRITE=1)')"
echo "==> Jetson:      $([ "${BUILD_JETSON_IMG}" = true ] && echo "${JETSON_BOARD_SEL} roles: ${JETSON_BUILD_ROLES[*]} (kernel=${JETSON_KFLAVOR_SEL}; EXPERIMENTAL)" || echo '(off — set JETSON=1)')"
echo "==> Orange Pi 5: $([ "${BUILD_ORANGEPI5_IMG}" = true ] && echo "${ORANGEPI5_BOARD_SEL} (flavor=${ORANGEPI5_FLAVOR_SEL}; EXPERIMENTAL)" || echo '(off — set ORANGEPI5=1)')"
echo "==> OPi Zero 2:  $([ "${BUILD_ORANGEPIZERO2_IMG}" = true ] && echo "(flavor=${ORANGEPIZERO2_FLAVOR_SEL}; EXPERIMENTAL, headless)" || echo '(off — set ORANGEPIZERO2=1)')"
echo "==> OPi Zero 2W: $([ "${BUILD_ORANGEPIZERO2W_IMG}" = true ] && echo "(flavor=${ORANGEPIZERO2W_FLAVOR_SEL}; EXPERIMENTAL, headless)" || echo '(off — set ORANGEPIZERO2W=1)')"
echo "==> OPi Zero 3: $([ "${BUILD_ORANGEPIZERO3_IMG}" = true ] && echo "(flavor=${ORANGEPIZERO3_FLAVOR_SEL}; EXPERIMENTAL, headless)" || echo '(off — set ORANGEPIZERO3=1)')"
echo "==> OPi 3 LTS:  $([ "${BUILD_ORANGEPI3LTS_IMG}" = true ] && echo "(flavor=${ORANGEPI3LTS_FLAVOR_SEL}; EXPERIMENTAL, headless)" || echo '(off — set ORANGEPI3LTS=1)')"
echo "==> OPi 4 LTS:  $([ "${BUILD_ORANGEPI4LTS_IMG}" = true ] && echo "(flavor=${ORANGEPI4LTS_FLAVOR_SEL}; EXPERIMENTAL, light desktop)" || echo '(off — set ORANGEPI4LTS=1)')"
echo "==> Build ENV:   ${BUILD_ENV}  $([ "${BUILD_ENV}" = test ] && echo '(LAN-first; cluster wildcard DNS; cloudflared/ACME pruned)' || echo '(PROD: public domain; Cloudflare/ACME; creds from keys USB)')"
echo "==> Pen-test:    $([ "${PENTEST}" = 1 ] && echo "ON (env=${PENTEST_ENV:-compose} scan=${PENTEST_SCAN:-baseline} pipeline=${PENTEST_PIPELINE:-main})$([ "${PENTEST_ONLY:-0}" = 1 ] && echo ' [PENTEST_ONLY]')" || echo '(off — set PENTEST=1 / --pentest)')"
echo "    Work/target dir: ${WORK_DIR}"
echo "    Pass-through args: $*"
echo

# Image builds are failure-TOLERANT: under `set -e` a bare builder call aborts the WHOLE
# run on the first role failure — skipping every later image AND the keys block below
# (whose FATAL gate then never runs). Accumulate failures and report them loudly at the
# end instead, so one role's transient failure (fetch/OOM/ENOSPC) never voids the rest.
BUILDS_FAILED=()
for role in "${RPI_ROLES[@]}"; do
    echo "############################################################"
    echo "#  Building RPi role: ${role} (board=${RPI_BOARD_SEL})"
    echo "############################################################"
    "${BUILD_RPI}" --role "${role}" --board "${RPI_BOARD_SEL}" "$@" \
        || { echo "!! RPi role '${role}' (board=${RPI_BOARD_SEL}) build FAILED — continuing with the remaining roles" >&2; BUILDS_FAILED+=("rpi-${RPI_BOARD_SEL}:${role}"); }
done

for role in "${X86_BUILD_ROLES[@]}"; do
    # The UNAFFILIATED plain desktop is brandless BY DEFINITION — a fleet-wide
    # brand profile (--config/--brand/--brand-title/--org) hard-conflicts with
    # it in the builder. Skip it LOUDLY on branded fleet runs rather than
    # producing a guaranteed-failed build (build it separately, unbranded:
    # make x86-standalone-unaffiliated).
    if [ "${role}" = "standalone-unaffiliated" ]; then
        _branded=false
        for _a in "$@"; do case "${_a}" in --config|--brand|--brand-title|--org) _branded=true ;; esac; done
        if ${_branded}; then
            echo "## SKIPPING x86 role 'standalone-unaffiliated': this fleet run carries a brand profile," >&2
            echo "##   and the unaffiliated desktop is brandless by definition (the builder would hard-error)." >&2
            echo "##   Build it separately: make x86-standalone-unaffiliated" >&2
            continue
        fi
    fi
    echo "############################################################"
    echo "#  Building x86 role: ${role}"
    echo "############################################################"
    "${BUILD_X86}" --role "${role}" "$@" \
        || { echo "!! x86 role '${role}' build FAILED — continuing with the remaining roles" >&2; BUILDS_FAILED+=("x86:${role}"); }
done

if [ "${BUILD_FRITE_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Frite light desktop: ${FRITE_BOARD_SEL} (flavor=${FRITE_FLAVOR_SEL}, desktop=${FRITE_DESKTOP_SEL})"
    echo "############################################################"
    "${BUILD_FRITE}" --board "${FRITE_BOARD_SEL}" --flavor "${FRITE_FLAVOR_SEL}" \
            --desktop "${FRITE_DESKTOP_SEL}" "$@" \
        || { echo "!! Frite build FAILED — continuing" >&2; BUILDS_FAILED+=("frite:${FRITE_BOARD_SEL}"); }
fi

if [ "${BUILD_JETSON_IMG}" = true ]; then
    for role in "${JETSON_BUILD_ROLES[@]}"; do
        echo "############################################################"
        echo "#  Building Jetson role: ${role} (${JETSON_BOARD_SEL}, kernel=${JETSON_KFLAVOR_SEL}) — EXPERIMENTAL"
        echo "############################################################"
        "${BUILD_JETSON}" --role "${role}" --board "${JETSON_BOARD_SEL}" \
                --kernel-flavor "${JETSON_KFLAVOR_SEL}" "$@" \
            || { echo "!! Jetson role '${role}' build FAILED — continuing with the remaining roles" >&2; BUILDS_FAILED+=("jetson:${role}"); }
    done
fi

if [ "${BUILD_ORANGEPI5_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Orange Pi 5 light desktop: ${ORANGEPI5_BOARD_SEL} (flavor=${ORANGEPI5_FLAVOR_SEL}) — EXPERIMENTAL"
    echo "############################################################"
    "${BUILD_ORANGEPI5}" --board "${ORANGEPI5_BOARD_SEL}" --flavor "${ORANGEPI5_FLAVOR_SEL}" "$@" \
        || { echo "!! Orange Pi 5 build FAILED — continuing" >&2; BUILDS_FAILED+=("orangepi5:${ORANGEPI5_BOARD_SEL}"); }
fi

if [ "${BUILD_ORANGEPIZERO2_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Orange Pi Zero 2 headless appliance (flavor=${ORANGEPIZERO2_FLAVOR_SEL}) — EXPERIMENTAL"
    echo "############################################################"
    "${BUILD_ORANGEPIZERO2}" --flavor "${ORANGEPIZERO2_FLAVOR_SEL}" "$@" \
        || { echo "!! Orange Pi Zero 2 build FAILED — continuing" >&2; BUILDS_FAILED+=("orangepizero2"); }
fi

if [ "${BUILD_ORANGEPIZERO2W_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Orange Pi Zero 2W headless appliance (flavor=${ORANGEPIZERO2W_FLAVOR_SEL}) — EXPERIMENTAL"
    echo "############################################################"
    "${BUILD_ORANGEPIZERO2W}" --flavor "${ORANGEPIZERO2W_FLAVOR_SEL}" "$@" \
        || { echo "!! Orange Pi Zero 2W build FAILED — continuing" >&2; BUILDS_FAILED+=("orangepizero2w"); }
fi

if [ "${BUILD_ORANGEPIZERO3_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Orange Pi Zero 3 headless appliance (flavor=${ORANGEPIZERO3_FLAVOR_SEL}) — EXPERIMENTAL"
    echo "############################################################"
    "${BUILD_ORANGEPIZERO3}" --flavor "${ORANGEPIZERO3_FLAVOR_SEL}" "$@" \
        || { echo "!! Orange Pi Zero 3 build FAILED — continuing" >&2; BUILDS_FAILED+=("orangepizero3"); }
fi

if [ "${BUILD_ORANGEPI3LTS_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Orange Pi 3 LTS headless appliance (flavor=${ORANGEPI3LTS_FLAVOR_SEL}) — EXPERIMENTAL"
    echo "############################################################"
    "${BUILD_ORANGEPI3LTS}" --flavor "${ORANGEPI3LTS_FLAVOR_SEL}" "$@" \
        || { echo "!! Orange Pi 3 LTS build FAILED — continuing" >&2; BUILDS_FAILED+=("orangepi3-lts"); }
fi

if [ "${BUILD_ORANGEPI4LTS_IMG}" = true ]; then
    echo
    echo "#  Building Orange Pi 4 LTS light desktop (flavor=${ORANGEPI4LTS_FLAVOR_SEL}) — EXPERIMENTAL"
    "${BUILD_ORANGEPI4LTS}" --flavor "${ORANGEPI4LTS_FLAVOR_SEL}" "$@" \
        || { echo "!! Orange Pi 4 LTS build FAILED — continuing" >&2; BUILDS_FAILED+=("orangepi4-lts"); }
fi

# ── Generate provisioning keys ───────────────────────────────────────
# All images are built first; keys are created LAST, in one pass over every
# built role. gen-provision-keys.sh takes a KEYS PROFILE, not a role — the two
# happen to coincide for pki/backend/frontend and diverge for every other role, so
# the profile is looked up in the ONE HUGMESH_ROLE_KEYPROFILE table
# (scripts/_roles-lib.sh) rather than assumed. The FOLDER keeps the role name (that
# is what an operator navigates to). Set SKIP_KEYS=1 to skip this entirely.
# A keys-generation failure is FATAL for the run (the keys folder IS the
# deliverable a node provisions from): every role is still attempted, the
# partial output dir is removed (a half-written keys-<role> must never be
# mistaken for a deliverable), and the orchestrator exits nonzero at the end
# listing every role whose keys failed.
KEYS_FAILED=()
if [ "${SKIP_KEYS:-0}" != "1" ]; then
    echo "############################################################"
    echo "#  Generate provisioning keys (all built roles)"
    echo "############################################################"
    for role in "${RPI_ROLES[@]}"; do
        _kprof="$(hugmesh_role_keyprofile "$(hugmesh_role_canonicalize "${role}" || echo "${role}")" || echo host)"
        echo "==> Generating keys folder: ${WORK_DIR}/keys-${role} (profile ${_kprof})"
        if ! "${GENKEYS}" --role "${_kprof}" --out "${WORK_DIR}/keys-${role}" --random; then
            echo "!! keys generation FAILED for ${role} — removing partial ${WORK_DIR}/keys-${role}" >&2
            rm -rf "${WORK_DIR}/keys-${role}"
            KEYS_FAILED+=("${role}")
        fi
    done
    # The Frite light-desktop client provisions from the SAME KEYS USB mechanism.
    # It is a client appliance (no users.json / no cluster join), so it uses the
    # 'host' worker-key profile: break-glass root key + mesh join material only.
    if [ "${BUILD_FRITE_IMG}" = true ]; then
        echo "==> Generating keys folder: ${WORK_DIR}/keys-frite (host profile)"
        if ! "${GENKEYS}" --role host --out "${WORK_DIR}/keys-frite" --random; then
            echo "!! keys generation FAILED for frite — removing partial ${WORK_DIR}/keys-frite" >&2
            rm -rf "${WORK_DIR}/keys-frite"
            KEYS_FAILED+=(frite)
        fi
    fi
    # Jetson roles provision from the SAME KEYS USB mechanism, through the SAME
    # HUGMESH_ROLE_KEYPROFILE table as every other platform: omnibus (the
    # single-node control plane, spelled `full` here until this change) -> pki;
    # backend-gpu / edge-ai -> the 'host' worker-key profile; the desktop client
    # has no node profile and falls back to 'host' like the Frite client.
    if [ "${BUILD_JETSON_IMG}" = true ]; then
        for role in "${JETSON_BUILD_ROLES[@]}"; do
            _jk_profile="$(hugmesh_role_keyprofile "$(hugmesh_role_canonicalize "${role}" || echo "${role}")" || echo host)"
            echo "==> Generating keys folder: ${WORK_DIR}/keys-jetson-${role} (${_jk_profile} profile)"
            if ! "${GENKEYS}" --role "${_jk_profile}" --out "${WORK_DIR}/keys-jetson-${role}" --random; then
                echo "!! keys generation FAILED for jetson-${role} — removing partial ${WORK_DIR}/keys-jetson-${role}" >&2
                rm -rf "${WORK_DIR}/keys-jetson-${role}"
                KEYS_FAILED+=("jetson-${role}")
            fi
        done
    fi
    # Orange Pi 5 provisions from the SAME KEYS USB mechanism, as a client
    # appliance (no users.json / no cluster join) — the 'host' worker-key
    # profile, exactly like the Frite client.
    if [ "${BUILD_ORANGEPI5_IMG}" = true ]; then
        echo "==> Generating keys folder: ${WORK_DIR}/keys-orangepi5 (host profile)"
        if ! "${GENKEYS}" --role host --out "${WORK_DIR}/keys-orangepi5" --random; then
            echo "!! keys generation FAILED for orangepi5 — removing partial ${WORK_DIR}/keys-orangepi5" >&2
            rm -rf "${WORK_DIR}/keys-orangepi5"
            KEYS_FAILED+=(orangepi5)
        fi
    fi
    # Orange Pi Zero 2 provisions from the SAME KEYS USB mechanism, as a headless
    # appliance (no users.json / no cluster join) — the 'host' worker-key
    # profile, exactly like the Frite/Orange Pi 5 clients.
    if [ "${BUILD_ORANGEPIZERO2_IMG}" = true ]; then
        echo "==> Generating keys folder: ${WORK_DIR}/keys-orangepizero2 (host profile)"
        if ! "${GENKEYS}" --role host --out "${WORK_DIR}/keys-orangepizero2" --random; then
            echo "!! keys generation FAILED for orangepizero2 — removing partial ${WORK_DIR}/keys-orangepizero2" >&2
            rm -rf "${WORK_DIR}/keys-orangepizero2"
            KEYS_FAILED+=(orangepizero2)
        fi
    fi
    # Orange Pi Zero 2W: same headless-appliance 'host' worker-key profile as
    # the Zero 2 above.
    if [ "${BUILD_ORANGEPIZERO2W_IMG}" = true ]; then
        echo "==> Generating keys folder: ${WORK_DIR}/keys-orangepizero2w (host profile)"
        if ! "${GENKEYS}" --role host --out "${WORK_DIR}/keys-orangepizero2w" --random; then
            echo "!! keys generation FAILED for orangepizero2w — removing partial ${WORK_DIR}/keys-orangepizero2w" >&2
            rm -rf "${WORK_DIR}/keys-orangepizero2w"
            KEYS_FAILED+=(orangepizero2w)
        fi
    fi
    # Orange Pi Zero 3: same headless-appliance 'host' worker-key profile as
    # the Zero 2 above.
    if [ "${BUILD_ORANGEPIZERO3_IMG}" = true ]; then
        echo "==> Generating keys folder: ${WORK_DIR}/keys-orangepizero3 (host profile)"
        if ! "${GENKEYS}" --role host --out "${WORK_DIR}/keys-orangepizero3" --random; then
            echo "!! keys generation FAILED for orangepizero3 — removing partial ${WORK_DIR}/keys-orangepizero3" >&2
            rm -rf "${WORK_DIR}/keys-orangepizero3"
            KEYS_FAILED+=(orangepizero3)
        fi
    fi
fi

echo
echo "==> Done. Products in ${WORK_DIR}:"
echo "    (per-arch build trees: ${WORK_DIR}/snap-build-pi5, ${WORK_DIR}/snap-build-x86)"
ls -1 "${WORK_DIR}/"*.img 2>/dev/null | sed 's/^/   img:  /' || echo "   (no *.img)"
ls -1 "${WORK_DIR}/"*.iso 2>/dev/null | sed 's/^/   iso:  /' || true
ls -1d "${WORK_DIR}/"keys-* 2>/dev/null | sed 's/^/   keys: /' || true
echo
echo "Write a stick for a role with:  sudo ./scripts/make-keys-usb.sh /dev/sdX ${WORK_DIR}/keys-<role>"

# ── Pen-test build OPTION (DEV / CI-pipeline only) ───────────────────────────
# When PENTEST=1 / --pentest, run the OWASP pen-test harness as part of the build.
# This drives tests/pentest/run-pentest.sh (public images: owasp/dependency-check
# + zaproxy) against an env-test-build — it is NOT a deployed runner. A non-zero
# scan result fails the build so the pen-test gates the pipeline like any test.
if [ "${PENTEST}" = "1" ]; then
    PENTEST_SH="${REPO_DIR}/tests/pentest/run-pentest.sh"
    echo
    echo "############################################################"
    echo "#  Pen-test (build option): env=${PENTEST_ENV:-compose} scan=${PENTEST_SCAN:-baseline} pipeline=${PENTEST_PIPELINE:-main}"
    echo "############################################################"
    if [ ! -x "${PENTEST_SH}" ]; then
        echo "!! pen-test harness not found/executable: ${PENTEST_SH}" >&2
        exit 1
    fi
    "${PENTEST_SH}" \
        --env "${PENTEST_ENV:-compose}" \
        --scan "${PENTEST_SCAN:-baseline}" \
        --pipeline "${PENTEST_PIPELINE:-main}"
fi

# ── Failure gates (LAST so every role/build above was still attempted) ────────
# Image builds + keys are failure-tolerant above; report any failures loudly here and
# exit nonzero so a partial run is never mistaken for a complete success.
if [ "${#BUILDS_FAILED[@]}" -gt 0 ]; then
    echo >&2
    echo "!! IMAGE BUILD FAILED for: ${BUILDS_FAILED[*]}  (the other roles + keys were still produced)" >&2
    echo "!! Re-run a failed role with its per-arch builder:" >&2
    echo "!!   ./build-rpi5-stage4.sh --role <r>  |  ./build-x86-host-stage4.sh --role <r>  |  ./build-frite-stage4.sh --board <b>  |  ./build-jetson-stage4.sh --role <r>  |  ./build-orangepi5-stage4.sh --board <b>  |  ./build-orangepi-zero2-stage4.sh --flavor <f>  |  ./build-orangepi-zero2w-stage4.sh --flavor <f>  |  ./build-orangepi-zero3-stage4.sh --flavor <f>" >&2
fi
# A run whose keys folders failed has NO usable provisioning deliverable for those roles.
if [ "${#KEYS_FAILED[@]}" -gt 0 ]; then
    echo >&2
    echo "!! KEYS generation FAILED for: ${KEYS_FAILED[*]}" >&2
    echo "!! The partial keys folders were removed. Re-run gen-provision-keys.sh per role:" >&2
    for _r in "${KEYS_FAILED[@]}"; do
        # Map the appliance names back to the key profile gen-provision-keys knows:
        # frite + jetson workers/desktop + orangepi5 + orangepizero2 +
        # orangepizero2w + orangepizero3 -> host; jetson 'full' (single-node CP) -> pki.
        case "${_r}" in
            frite)          _kp=host ;;
            orangepi5)      _kp=host ;;
            orangepizero2)  _kp=host ;;
            orangepizero2w) _kp=host ;;
            orangepizero3) _kp=host ;;
            jetson-full)    _kp=pki ;;
            jetson-*)       _kp=host ;;
            *)              _kp="${_r}" ;;
        esac
        echo "!!   ${GENKEYS} --role ${_kp} --out ${WORK_DIR}/keys-${_r} --random" >&2
    done
fi
if [ "${#BUILDS_FAILED[@]}" -gt 0 ] || [ "${#KEYS_FAILED[@]}" -gt 0 ]; then
    exit 1
fi
