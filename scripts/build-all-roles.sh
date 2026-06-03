#!/usr/bin/env bash
# build-all-roles.sh — build all three Snapdragon RPi 5 ISO variants
# (pki, backend, frontend) into the gitignored work directory.
#
# Any extra args are passed through to build-rpi5-stage4.sh, so you can do:
#   ./scripts/build-all-roles.sh -j 16 --cluster-domain snapdragon.local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD="${REPO_DIR}/build-rpi5-stage4.sh"

ROLES=(pki backend frontend)

echo "==> Building ISOs for roles: ${ROLES[*]}"
echo "    Pass-through args: $*"
echo

for role in "${ROLES[@]}"; do
    echo "############################################################"
    echo "#  Building role: ${role}"
    echo "############################################################"
    "${BUILD}" --role "${role}" "$@"
done

echo
echo "==> All role images built. Artifacts in the work directory:"
ls -1 "${REPO_DIR}/rpi5-stage4-build/"*.iso 2>/dev/null || \
    echo "   (check your --work-dir for *.iso)"
