#!/usr/bin/env bash
# ── HOST-side build-backend keyword-acceptance guard ─────────────────────────────
# The cross-emerge resolves BDEPEND against the CONTAINER's own /etc/portage (an
# amd64 root), so the sysroot's specs-*/portage/package.accept_keywords files can
# NOT cover the host-side "to /" installs. dev-python/vcs-versioning is keyworded
# amd64-first upstream; without a HOST-side acceptance the SELinux-toolchain chain
# dies mid-@stage4 with "masked by: ~amd64 keyword" (the post-#352 frite failure —
# #352 fixed only the sysroot side). Empirically verified in the real builder
# container: `emerge -p =dev-python/vcs-versioning-2*` is masked without the file
# and resolves with it.
#
# This guard asserts the acceptance exists in BOTH places (a revert fails here):
#   * every ARM cross-builder writes /etc/portage/package.accept_keywords/
#     snapdragon-host-build-backends at run time (works with ANY image state), and
#   * Dockerfile.build bakes the same file into the FINAL stage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== host-side accept_keywords guard =="

for s in build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-jetson-stage4.sh; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi
    if grep -q 'package.accept_keywords/snapdragon-host-build-backends' "${f}" \
       && grep -q "dev-python/vcs-versioning \*\*" "${f}"; then
        ok "${s}: writes the HOST-side vcs-versioning acceptance"
    else
        bad "${s}: missing the HOST-side vcs-versioning acceptance block"
    fi
done

if grep -q 'package.accept_keywords/snapdragon-host-build-backends' "${GEN}/Dockerfile.build" \
   && grep -q "dev-python/vcs-versioning \*\*" "${GEN}/Dockerfile.build"; then
    ok "Dockerfile.build: bakes the HOST-side acceptance into the FINAL stage"
else
    bad "Dockerfile.build: missing the baked HOST-side acceptance"
fi

# The sysroot-side file (#352) must ALSO survive — the two are twins, not
# alternatives (host emerges vs cross-emerges read different config roots).
for d in specs-frite specs-rpi5 specs-orangepi5 specs-jetson specs-orangepi-zero2; do
    f="${GEN}/${d}/portage/package.accept_keywords/setuptools-scm-backend"
    if [ -f "${f}" ] && grep -q "dev-python/vcs-versioning \*\*" "${f}"; then
        ok "${d}: sysroot-side acceptance (#352) intact"
    else
        bad "${d}: sysroot-side acceptance (#352) missing"
    fi
done

echo "== host-accept-keywords: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
