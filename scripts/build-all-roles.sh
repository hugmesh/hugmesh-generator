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
# Pen-test build OPTION (DEV / CI-pipeline only) — run the OWASP pen-test harness
# as part of the build (memory snapdragon-pentest-standard "an OPTION in the BUILD
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

if [ "${PENTEST_ONLY:-0}" = "1" ]; then
    RPI_ROLES=()   # pentest-only: no image builds
else
    RPI_ROLES=(pki backend frontend)
fi

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
    echo "#  Building RPi5 role: ${role}"
    echo "############################################################"
    "${BUILD_RPI}" --role "${role}" "$@" \
        || { echo "!! RPi5 role '${role}' build FAILED — continuing with the remaining roles" >&2; BUILDS_FAILED+=("rpi5:${role}"); }
done

for role in "${X86_BUILD_ROLES[@]}"; do
    echo "############################################################"
    echo "#  Building x86 role: ${role}"
    echo "############################################################"
    "${BUILD_X86}" --role "${role}" "$@" \
        || { echo "!! x86 role '${role}' build FAILED — continuing with the remaining roles" >&2; BUILDS_FAILED+=("x86:${role}"); }
done

if [ "${BUILD_FRITE_IMG}" = true ]; then
    echo "############################################################"
    echo "#  Building Frite light desktop: ${FRITE_BOARD_SEL} (flavor=${FRITE_FLAVOR_SEL})"
    echo "############################################################"
    "${BUILD_FRITE}" --board "${FRITE_BOARD_SEL}" --flavor "${FRITE_FLAVOR_SEL}" "$@" \
        || { echo "!! Frite build FAILED — continuing" >&2; BUILDS_FAILED+=("frite:${FRITE_BOARD_SEL}"); }
fi

# ── Generate provisioning keys ───────────────────────────────────────
# All images are built first; keys are created LAST, in one pass over every
# built role. gen-provision-keys.sh only knows the RPi/host role names, so we
# key off the RPi roles here (the per-role KEYS folder the make-keys-usb.sh
# stick consumes). Set SKIP_KEYS=1 to skip this entirely.
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
        echo "==> Generating keys folder: ${WORK_DIR}/keys-${role}"
        if ! "${GENKEYS}" --role "${role}" --out "${WORK_DIR}/keys-${role}" --random; then
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
    echo "!!   ./build-rpi5-stage4.sh --role <r>  |  ./build-x86-host-stage4.sh --role <r>  |  ./build-frite-stage4.sh --board <b>" >&2
fi
# A run whose keys folders failed has NO usable provisioning deliverable for those roles.
if [ "${#KEYS_FAILED[@]}" -gt 0 ]; then
    echo >&2
    echo "!! KEYS generation FAILED for: ${KEYS_FAILED[*]}" >&2
    echo "!! The partial keys folders were removed. Re-run gen-provision-keys.sh per role:" >&2
    for _r in "${KEYS_FAILED[@]}"; do
        echo "!!   ${GENKEYS} --role ${_r/frite/host} --out ${WORK_DIR}/keys-${_r} --random" >&2
    done
fi
if [ "${#BUILDS_FAILED[@]}" -gt 0 ] || [ "${#KEYS_FAILED[@]}" -gt 0 ]; then
    exit 1
fi
