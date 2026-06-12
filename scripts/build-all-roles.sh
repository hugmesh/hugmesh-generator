#!/usr/bin/env bash
# build-all-roles.sh — build the Snapdragon node images + each role's KEYS folder.
#
# DEFAULT build set:
#   * RPi 5 (aarch64):  pki, backend, frontend                 (build-rpi5-stage4.sh)
#   * x86_64 (amd64):   pki, be, fe, be+gpu  (every role EXCEPT omnibus)
#
# Only the x86 omnibus (all-in-one single-node) role is OPT-IN:
#   X86_OMNIBUS=1 ./scripts/build-all-roles.sh  # appends omnibus to the x86 set
#   X86_ALL=1     ./scripts/build-all-roles.sh  # pki be fe be+gpu omnibus on x86
#   X86_ROLES="pki omnibus" ./scripts/build-all-roles.sh   # an explicit subset
#   SKIP_X86=1    ./scripts/build-all-roles.sh  # Pi roles only (no x86 at all)
#
# The Libre Computer Le/La Frite LIGHT-DESKTOP client image is OPT-IN (it is a
# desktop appliance, not a cluster node, so it is NOT in the default fleet):
#   FRITE=1       ./scripts/build-all-roles.sh  # ALSO build the Frite (la-frite, both flavors)
#   FRITE_BOARD=le-potato FRITE=1 ./scripts/build-all-roles.sh   # the pricier S905X sibling
#   FRITE_ONLY=1  ./scripts/build-all-roles.sh  # ONLY the Frite (skip Pi + x86)
#   FRITE_FLAVOR=live FRITE=1 ./scripts/build-all-roles.sh       # live image only
# (build-frite-stage4.sh — see docs/RUNNING.md §"Frite light-desktop image".)
#
# Any extra args are passed through to BOTH builders, e.g.:
#   ./scripts/build-all-roles.sh -j 16 --cluster-domain snapdragon.systems
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
GENKEYS="${SCRIPT_DIR}/gen-provision-keys.sh"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/out}"
# Honor a -w/--work-dir passed through to the builders so the keys-<role> folders
# land beside the images (recommend a dir OUTSIDE an encrypted/$HOME mount).
BUILD_ENV="test"   # mirror the builders' default for the summary line below
for ((_i = 1; _i <= $#; _i++)); do
    case "${!_i}" in
        -w|--work-dir) _j=$((_i + 1)); WORK_DIR="${!_j}" ;;
        --env)         _j=$((_i + 1)); BUILD_ENV="${!_j}" ;;
    esac
done

RPI_ROLES=(pki backend frontend)

# x86 role set. Default = every role EXCEPT omnibus (pki be fe be+gpu). Only the
# omnibus all-in-one role is opt-in: X86_OMNIBUS=1 appends it; X86_ALL=1 expands
# to every role (incl. omnibus); X86_ROLES overrides explicitly; SKIP_X86=1
# disables the x86 build entirely.
if [ "${SKIP_X86:-0}" = "1" ]; then
    X86_BUILD_ROLES=()
elif [ -n "${X86_ROLES:-}" ]; then
    read -r -a X86_BUILD_ROLES <<< "${X86_ROLES}"
elif [ "${X86_ALL:-0}" = "1" ]; then
    X86_BUILD_ROLES=(pki be fe be+gpu omnibus)
elif [ "${X86_OMNIBUS:-0}" = "1" ]; then
    X86_BUILD_ROLES=(pki be fe be+gpu omnibus)
else
    X86_BUILD_ROLES=(pki be fe be+gpu)
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

echo "==> RPi5 roles:  ${RPI_ROLES[*]:-(none)}"
echo "==> x86 roles:   ${X86_BUILD_ROLES[*]:-(none)}"
echo "==> Frite:       $([ "${BUILD_FRITE_IMG}" = true ] && echo "${FRITE_BOARD_SEL} (flavor=${FRITE_FLAVOR_SEL})" || echo '(off — set FRITE=1)')"
echo "==> Build ENV:   ${BUILD_ENV}  $([ "${BUILD_ENV}" = test ] && echo '(LAN-first; cluster wildcard DNS; cloudflared/ACME pruned)' || echo '(PROD: public domain; Cloudflare/ACME; creds from keys USB)')"
echo "    Work/target dir: ${WORK_DIR}"
echo "    Pass-through args: $*"
echo

for role in "${RPI_ROLES[@]}"; do
    echo "############################################################"
    echo "#  Building RPi5 role: ${role}"
    echo "############################################################"
    "${BUILD_RPI}" --role "${role}" "$@"
done

for role in "${X86_BUILD_ROLES[@]}"; do
    echo "############################################################"
    echo "#  Building x86 role: ${role}"
    echo "############################################################"
    "${BUILD_X86}" --role "${role}" "$@"
done

if [ "${BUILD_FRITE_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Frite light desktop: ${FRITE_BOARD_SEL} (flavor=${FRITE_FLAVOR_SEL})"
    echo "############################################################"
    "${BUILD_FRITE}" --board "${FRITE_BOARD_SEL}" --flavor "${FRITE_FLAVOR_SEL}" "$@"
fi

# ── Generate provisioning keys ───────────────────────────────────────
# All images are built first; keys are created LAST, in one pass over every
# built role. gen-provision-keys.sh only knows the RPi/host role names, so we
# key off the RPi roles here (the per-role KEYS folder the make-keys-usb.sh
# stick consumes). Set SKIP_KEYS=1 to skip this entirely.
if [ "${SKIP_KEYS:-0}" != "1" ]; then
    echo "############################################################"
    echo "#  Generate provisioning keys (all built roles)"
    echo "############################################################"
    for role in "${RPI_ROLES[@]}"; do
        echo "==> Generating keys folder: ${WORK_DIR}/keys-${role}"
        "${GENKEYS}" --role "${role}" --out "${WORK_DIR}/keys-${role}" --random || \
            echo "   (keys generation skipped/failed for ${role} — run gen-provision-keys.sh manually)"
    done
    # The Frite light-desktop client provisions from the SAME KEYS USB mechanism.
    # It is a client appliance (no users.json / no cluster join), so it uses the
    # 'host' worker-key profile: break-glass root key + mesh join material only.
    if [ "${BUILD_FRITE_IMG}" = true ]; then
        echo "==> Generating keys folder: ${WORK_DIR}/keys-frite (host profile)"
        "${GENKEYS}" --role host --out "${WORK_DIR}/keys-frite" --random || \
            echo "   (keys generation skipped/failed for frite — run gen-provision-keys.sh manually)"
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
