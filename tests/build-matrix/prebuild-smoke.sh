#!/usr/bin/env bash
# prebuild-smoke.sh — non-gating MAKE-bucket smoke for the shared-binpkg
# `prebuild-binaries` target (Lane 4c). Dry-run (`make -n`) only; NO real build.
#
# Asserts, for every platform, that `make -n prebuild-binaries ARCH=<platform>`:
#   * resolves (recipe exists),
#   * routes to that platform's builder script,
#   * threads --packages-only (the prebuild early-exit), and
#   * computes the union via the prebuild_union module.
# Plus that a BOARD= override threads --board to the pi builder (Lane-2 per-board
# pool). Run standalone or as a check.sh non-gating smoke.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== prebuild-binaries make target (Lane 4c, dry-run) =="

declare -A BUILDER=(
  [x86]=build-x86-host-stage4.sh
  [rpi5]=build-rpi5-stage4.sh
  [frite]=build-frite-stage4.sh
  [jetson]=build-jetson-stage4.sh
  [orangepi5]=build-orangepi5-stage4.sh
  [orangepizero2]=build-orangepi-zero2-stage4.sh
  [orangepizero2w]=build-orangepi-zero2w-stage4.sh
  [orangepizero3]=build-orangepi-zero3-stage4.sh
  [orangepi3-lts]=build-orangepi3-lts-stage4.sh
  [orangepi4-lts]=build-orangepi4-lts-stage4.sh
)

for arch in x86 rpi5 frite jetson orangepi5 orangepizero2 orangepizero2w orangepizero3 orangepi3-lts orangepi4-lts; do
    out="$(make -n prebuild-binaries ARCH="${arch}" 2>&1)" || { bad "${arch}: make -n exited non-zero"; continue; }
    miss=""
    grep -q -- '--packages-only' <<<"${out}"                          || miss+=" --packages-only"
    grep -q 'hugmesh_studio.core.prebuild_union' <<<"${out}"       || miss+=" prebuild_union"
    grep -q "${BUILDER[$arch]}" <<<"${out}"                           || miss+=" ${BUILDER[$arch]}"
    if [ -z "${miss}" ]; then
        ok "${arch}: -> ${BUILDER[$arch]} --packages-only (+ prebuild_union)"
    else
        bad "${arch}: missing in recipe:${miss}"
    fi
done

# BOARD= override threads --board to the pi builder (Lane-2 per-board pool)
out="$(make -n prebuild-binaries ARCH=rpi5 BOARD=rpi4 2>&1)" || out=""
grep -q -- '--board rpi4' <<<"${out}" && ok "rpi5 BOARD=rpi4 threads --board rpi4 (per-board pool)" \
                                      || bad "rpi5 BOARD=rpi4 did NOT thread --board rpi4"

echo "== prebuild-binaries smoke: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
