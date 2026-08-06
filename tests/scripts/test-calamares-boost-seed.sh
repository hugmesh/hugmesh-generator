#!/usr/bin/env bash
# ── calamares boost[python] seed guard ───────────────────────────────────────
# app-admin/calamares is a PKGS atom for ANY x86 role when
# --installer-ui=calamares|all (WANT_CALAMARES), yet the boost[python] USE line
# it hard-depends on used to live in package.use/desktop, which the x86
# package.use copy loop gates on ROLE_CLIENT — so every NODE image
# (pki/be/fe/be+gpu/omnibus) hit the identical resolution wall ~16min in:
#   "no ebuilds built with USE flags to satisfy
#    '>=dev-libs/boost-1.72.0:=[python,...]'" and NOTHING in packages.list
# merged (real 5x x86 failure, session 20260716-160638-f8c153).
#
# The fix MOVED (not duplicated) the line into the role-independent
# package.use/boost. This guard bites on every way to revert it:
#   * the boost file disappearing or losing the line/rationale,
#   * the line moving (or being duplicated) back into 'desktop',
#   * the copy loop growing a 'boost)' case filter,
#   * the copy loop losing its unconditional cp fall-through.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== calamares-boost seed guard =="

BOOST="${GEN}/specs-x86/portage/package.use/boost"
DESKTOP="${GEN}/specs-x86/portage/package.use/desktop"
X86="${GEN}/build-x86-host-stage4.sh"

# 1. the role-independent boost file, with the load-bearing line + rationale.
if [ -f "${BOOST}" ] && grep -qE '^\s*dev-libs/boost\s+python\b' "${BOOST}"; then
    ok "package.use/boost present with 'dev-libs/boost python'"
else
    bad "package.use/boost missing or lost its 'dev-libs/boost python' line"
fi
if [ -f "${BOOST}" ] && grep -qi 'calamares' "${BOOST}"; then
    ok "package.use/boost carries the calamares rationale comment"
else
    bad "package.use/boost lost its calamares rationale (why role-independent)"
fi

# 2. desktop must NOT carry a dev-libs/boost line (move, not duplicate; a
#    move-BACK silently re-strands node images).
if [ -f "${DESKTOP}" ] && grep -qE '^\s*dev-libs/boost\b' "${DESKTOP}"; then
    bad "package.use/desktop regrew a dev-libs/boost line (client-only again)"
else
    ok "package.use/desktop carries no dev-libs/boost line"
fi

# 3+4. the x86 package.use copy loop: extract exactly the 'for puf in ...
#      package.use ... done' region and require (a) NO 'boost)' case entry and
#      (b) the unconditional cp fall-through still present.
LOOP="$(sed -n '/^for puf in "\${SPECS_DIR}\/portage\/package\.use\/"\*/,/^done$/p' "${X86}")"
if [ -n "${LOOP}" ]; then
    ok "x86 package.use copy loop found"
else
    bad "x86 package.use copy loop not found (anchors moved?)"
fi
if printf '%s' "${LOOP}" | grep -qE '^\s*boost\)'; then
    bad "x86 copy loop grew a 'boost)' case filter (node images lose the seed)"
else
    ok "x86 copy loop has no 'boost)' case entry (file reaches every role)"
fi
# The fall-through target was refactored from the sysroot directly to a STAGING
# dir that pcs_sync_dir then mirrors into the sysroot, so accept both shapes.
# What must hold either way is that the copy sits AFTER the case with no further
# filtering — a file that survived the case reaches the sysroot. Pinning only the
# retired literal made this leg permanently red; the suite was CI-orphaned so
# nothing noticed, and an always-red guard gets ignored exactly like an
# always-green one.
if printf '%s' "${LOOP}" | grep -qE '^\s*cp "\$\{puf\}" "\$\{SYSROOT\}/etc/portage/package\.use/"$'; then
    ok "x86 copy loop still cps package.use files unconditionally after the case"
elif printf '%s' "${LOOP}" | grep -qE '^\s*cp "\$\{puf\}" "\$\{PCS_STAGE_PU\}/"$' \
     && grep -qE '^\s*pcs_sync_dir "\$\{PCS_STAGE_PU\}" "\$\{SYSROOT\}/etc/portage/package\.use"' "${X86}"; then
    ok "x86 copy loop stages package.use files unconditionally after the case, then pcs_sync_dir mirrors the stage into the sysroot"
else
    bad "x86 copy loop lost its unconditional cp fall-through"
fi

echo "== calamares-boost-seed: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
