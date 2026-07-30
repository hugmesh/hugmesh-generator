#!/usr/bin/env bash
# ── python3.12-target seed guard ─────────────────────────────────────────────
# The Gentoo tree's profile-default PYTHON_TARGETS moved past python3_12 while
# every image payload is still resolved around the stage3 seed's 3.12
# interpreter (libselinux → systemd-utils → portage chain). Without an explicit
# package.use seed the @world/payload emerge ABORTS with "The following USE
# changes are necessary to proceed: >=dev-python/… python_targets_python3_12"
# — the real jetson edge_ai fleet failure of 2026-07-16 (session
# 20260715-235432), with the identical wall queued up in the x86 logs behind
# the (since-fixed, #366) setuptools-scm compile failure.
#
# The fix is one wildcard line per config root:  */* PYTHON_TARGETS: python3_12
# This guard asserts (a revert of any half fails here):
#   * every spec dir ships portage/package.use/python-targets with that line,
#   * every ARM builder copies package.use/* into the sysroot UNCONDITIONALLY,
#   * build-x86's role-filtered package.use copy loop has NO case entry for
#     'python-targets' (so the seed reaches every role's chroot).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== python-targets seed guard =="

# The seed line, in every config root (7 ARM sysroots + the x86 chroot).
for d in specs-frite specs-rpi5 specs-orangepi5 specs-orangepi-zero2 specs-orangepi-zero2w specs-orangepi-zero3 \
         specs-jetson specs-x86; do
    f="${GEN}/${d}/portage/package.use/python-targets"
    if [ -f "${f}" ] && grep -qF '*/* PYTHON_TARGETS: python3_12' "${f}"; then
        ok "${d}: python-targets seed present with the wildcard 3.12 line"
    else
        bad "${d}: python-targets seed missing or lost its '*/* PYTHON_TARGETS: python3_12' line"
    fi
done

# PYTHON_SINGLE_TARGET must NOT be forced globally — two enabled single-targets
# violate REQUIRED_USE (^^) and would break every python_single_target package.
for d in specs-frite specs-rpi5 specs-orangepi5 specs-orangepi-zero2 specs-orangepi-zero2w specs-orangepi-zero3 \
         specs-jetson specs-x86; do
    f="${GEN}/${d}/portage/package.use/python-targets"
    if [ -f "${f}" ] && grep -qE '^\s*\*/\*\s+PYTHON_SINGLE_TARGET' "${f}"; then
        bad "${d}: seed force-enables a global PYTHON_SINGLE_TARGET (REQUIRED_USE ^^ hazard)"
    else
        ok "${d}: no global PYTHON_SINGLE_TARGET override"
    fi
done

# Every ARM builder must copy the spec's package.use/* into the sysroot with no
# filtering — the seed rides that copy.
for s in build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh build-jetson-stage4.sh; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi
    if grep -qE 'cp "\$\{SPECS_DIR\}/portage/package\.use/"\*' "${f}"; then
        ok "${s}: copies package.use/* into the sysroot unconditionally"
    else
        bad "${s}: unconditional package.use/* sysroot copy not found"
    fi
done

# build-x86 filters some package.use files by role (gpu/desktop/…). The seed is
# role-independent and must fall through the case (i.e. no filter entry).
if grep -qE '^\s*python-targets\)' "${GEN}/build-x86-host-stage4.sh"; then
    bad "build-x86: python-targets must NOT be role-filtered in the package.use copy loop"
else
    ok "build-x86: python-targets copied for every role (no case filter)"
fi

# HOST half: the cross-emerge resolves BDEPEND against the CONTAINER's own
# /etc/portage, which the sysroot seed cannot reach — every ARM builder must
# write the host-side package.use twin at run time, and Dockerfile.build must
# bake the same file (belt-and-braces, mirroring the #360/#366 keyword split).
for s in build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh build-jetson-stage4.sh; do
    f="${GEN}/${s}"
    if [ -f "${f}" ] \
       && grep -q 'package.use/hugmesh-host-build-backends' "${f}" \
       && grep -qF '*/* PYTHON_TARGETS: python3_12' "${f}"; then
        ok "${s}: writes the HOST-side python3.12-target seed"
    else
        bad "${s}: missing the HOST-side package.use python-targets pre-seed"
    fi
done
if grep -q 'package.use/hugmesh-host-build-backends' "${GEN}/Dockerfile.build" \
   && grep -qF '*/* PYTHON_TARGETS: python3_12' "${GEN}/Dockerfile.build"; then
    ok "Dockerfile.build: bakes the HOST-side python3.12-target seed"
else
    bad "Dockerfile.build: missing the baked HOST-side python-targets seed"
fi

# pam[audit]: the drift item queued directly behind the python-targets wall
# (sys-auth/passwdqc-2.1.0-r1 requires pam[audit]; the resolution only goes
# fully clean — emerge -p rc=0, zero USE-change blocks — with BOTH roots
# seeded). Sysroot/chroot half = specs file; host half rides the same
# run-time/baked package.use file as the python-targets seed.
for d in specs-frite specs-rpi5 specs-orangepi5 specs-orangepi-zero2 specs-orangepi-zero2w specs-orangepi-zero3 \
         specs-jetson specs-x86; do
    f="${GEN}/${d}/portage/package.use/pam-audit"
    if [ -f "${f}" ] && grep -qE '^\s*sys-libs/pam\s+audit' "${f}"; then
        ok "${d}: pam-audit seed present"
    else
        bad "${d}: pam-audit seed missing"
    fi
done
for s in build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh build-jetson-stage4.sh; do
    if grep -qE '^\s*sys-libs/pam\s+audit' "${GEN}/${s}"; then
        ok "${s}: HOST-side pam[audit] seed present"
    else
        bad "${s}: HOST-side pam[audit] seed missing"
    fi
done
if grep -qF "'sys-libs/pam audit'" "${GEN}/Dockerfile.build"; then
    ok "Dockerfile.build: bakes the HOST-side pam[audit] seed"
else
    bad "Dockerfile.build: missing the baked HOST-side pam[audit] seed"
fi

echo "== python-targets-seed: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
