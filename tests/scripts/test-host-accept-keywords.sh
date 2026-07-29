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
#     hugmesh-host-build-backends at run time (works with ANY image state), and
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
    if grep -q 'package.accept_keywords/hugmesh-host-build-backends' "${f}" \
       && grep -q "dev-python/vcs-versioning \*\*" "${f}" \
       && grep -q "dev-python/setuptools-scm \*\*" "${f}"; then
        ok "${s}: writes the HOST-side vcs-versioning + setuptools-scm acceptance"
    else
        bad "${s}: missing the HOST-side vcs-versioning/setuptools-scm acceptance block"
    fi
done

if grep -q 'package.accept_keywords/hugmesh-host-build-backends' "${GEN}/Dockerfile.build" \
   && grep -q "dev-python/vcs-versioning \*\*" "${GEN}/Dockerfile.build" \
   && grep -q "dev-python/setuptools-scm \*\*" "${GEN}/Dockerfile.build"; then
    ok "Dockerfile.build: bakes the HOST-side acceptance (both atoms) into the FINAL stage"
else
    bad "Dockerfile.build: missing the baked HOST-side acceptance (both atoms)"
fi

# The x86 CHROOT is stable-keyworded (ACCEPT_KEYWORDS="amd64") and got NO
# acceptance from #352/#360 (ARM-only) — the 2026-07-16 five-x86-image failure.
# Its specs file must carry BOTH atoms and is copied unconditionally by the
# build-x86 accept_keywords loop (no case-filter entry for it).
f="${GEN}/specs-x86/portage/package.accept_keywords/setuptools-scm-backend"
if [ -f "${f}" ] && grep -q "dev-python/vcs-versioning \*\*" "${f}" \
   && grep -q "dev-python/setuptools-scm \*\*" "${f}"; then
    ok "specs-x86: chroot-side acceptance present (both atoms)"
else
    bad "specs-x86: chroot-side acceptance missing"
fi
if grep -qE 'setuptools-scm-backend\)' "${GEN}/build-x86-host-stage4.sh"; then
    bad "build-x86: setuptools-scm-backend must NOT be role-filtered in the copy loop"
else
    ok "build-x86: setuptools-scm-backend copied unconditionally (no case filter)"
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
