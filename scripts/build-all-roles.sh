#!/usr/bin/env bash
# build-all-roles.sh — build all Snapdragon RPi 5 ISO variants (pki, backend,
# frontend) into the gitignored work directory, AND generate each role's
# corresponding KEYS folder next to its ISO.
#
# Any extra args are passed through to build-rpi5-stage4.sh, e.g.:
#   ./scripts/build-all-roles.sh -j 16 --cluster-domain snapdragon.systems
#
# Env:
#   WORK_DIR    work/target dir (default ./rpi5-stage4-build). Keep in sync with
#               any -w/--work-dir you pass through.
#   SKIP_KEYS=1 don't generate the per-role keys folders.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD="${REPO_DIR}/build-rpi5-stage4.sh"
GENKEYS="${SCRIPT_DIR}/gen-provision-keys.sh"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/rpi5-stage4-build}"

ROLES=(pki backend frontend)

echo "==> Building ISOs + keys folders for roles: ${ROLES[*]}"
echo "    Work/target dir: ${WORK_DIR}"
echo "    Pass-through args: $*"
echo

for role in "${ROLES[@]}"; do
    echo "############################################################"
    echo "#  Building role: ${role}"
    echo "############################################################"
    "${BUILD}" --role "${role}" "$@"

    if [ "${SKIP_KEYS:-0}" != "1" ]; then
        # Generate the role's corresponding KEYS folder in the target dir
        # (pki = full config + default users; workers = keys only). Random
        # passwords so it is non-interactive; review before writing a stick.
        echo "==> Generating keys folder: ${WORK_DIR}/keys-${role}"
        "${GENKEYS}" --role "${role}" --out "${WORK_DIR}/keys-${role}" --random || \
            echo "   (keys generation skipped/failed for ${role} — run gen-provision-keys.sh manually)"
    fi
done

echo
echo "==> Done. In ${WORK_DIR}:"
ls -1 "${WORK_DIR}/"*.iso 2>/dev/null | sed 's/^/   iso:  /' || echo "   (no *.iso — check --work-dir / --skip-iso)"
ls -1d "${WORK_DIR}/"keys-* 2>/dev/null | sed 's/^/   keys: /' || true
echo
echo "Write a stick for a role with:  sudo ./scripts/make-keys-usb.sh /dev/sdX ${WORK_DIR}/keys-<role>"
