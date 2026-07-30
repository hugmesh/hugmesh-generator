#!/usr/bin/env bash
# ── HOST SELinux 3.11 tool-parity guard ──────────────────────────────────────
# libselinux-3.11's and policycoreutils-3.11's pkg_postinst run HOST
# sefcontext_compile / semodule against the ROOT!=/ cross merge:
#   "sefcontext_compile: command not found" -> die "Failed to recompile contexts"
#   "semodule: command not found"           -> die "Failed to rebuild policy store mcs"
# (real jetson edge_ai cross-build failure, session 20260716-160638-f8c153;
# the build container shipped NEITHER tool — only libsepol-3.10). The 3.11
# SELinux userspace is also still ~amd64, so the host needs a keyword window
# (libsepol/libselinux/libsemanage/policycoreutils) plus two USE seeds
# (libselinux[python], audit[python] — pretend-resolve proven) before the
# tools can be emerged at all. Empirically proven end-to-end in a throwaway
# builder container: both EXACT postinst snippets exit 0 against a copy of
# the failed sysroot once the trio is merged.
#
# Mirrors test-host-accept-keywords.sh: BOTH halves must hold or this bites —
#   * runtime half: all 6 ARM builders probe the two tools into
#     HOST_POLICY_TOOLS and carry the ~amd64 window in their HOSTKW heredoc;
#   * baked half: Dockerfile.build carries the same keyword lines AND emerges
#     the two packages in the FINAL stage (fresh images: zero runtime cost).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== host SELinux 3.11 tool-parity guard =="

BUILDERS=(build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh
          build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh
          build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh build-jetson-stage4.sh)
KW_ATOMS=(sys-libs/libsepol sys-libs/libselinux sys-libs/libsemanage sys-apps/policycoreutils)

# ── runtime half: the probe + the keyword window in all 6 ARM builders ──
for s in "${BUILDERS[@]}"; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi
    grep -qE 'command -v sefcontext_compile.*HOST_POLICY_TOOLS\+=\(sys-libs/libselinux\)' "${f}" \
        && ok "${s}: probes sefcontext_compile -> sys-libs/libselinux" \
        || bad "${s}: missing sefcontext_compile -> libselinux probe"
    grep -qE 'command -v semodule\s.*HOST_POLICY_TOOLS\+=\(sys-apps/policycoreutils\)' "${f}" \
        && ok "${s}: probes semodule -> sys-apps/policycoreutils" \
        || bad "${s}: missing semodule -> policycoreutils probe"
    for a in "${KW_ATOMS[@]}"; do
        grep -qE "^${a} ~amd64$" "${f}" \
            && ok "${s}: HOSTKW heredoc accepts ${a} ~amd64" \
            || bad "${s}: HOSTKW heredoc lost '${a} ~amd64'"
    done
    # USE halves the tools emerge needs (pretend-resolve proven): the host
    # package.use heredoc must seed libselinux[python] + audit[python].
    grep -qE '^sys-libs/libselinux python$' "${f}" \
        && ok "${s}: HOST package.use seeds sys-libs/libselinux python" \
        || bad "${s}: HOST package.use lost 'sys-libs/libselinux python'"
    grep -qE '^sys-process/audit python$' "${f}" \
        && ok "${s}: HOST package.use seeds sys-process/audit python" \
        || bad "${s}: HOST package.use lost 'sys-process/audit python'"
done

# ── baked half: Dockerfile.build keywords + FINAL-stage emerge ──
DOCKERFILE="${GEN}/Dockerfile.build"
if [ -f "${DOCKERFILE}" ]; then
    for a in "${KW_ATOMS[@]}"; do
        grep -qF "'${a} ~amd64'" "${DOCKERFILE}" \
            && ok "Dockerfile.build: bakes '${a} ~amd64'" \
            || bad "Dockerfile.build: missing baked '${a} ~amd64'"
    done
    grep -qF "'sys-libs/libselinux python'" "${DOCKERFILE}" \
        && ok "Dockerfile.build: bakes 'sys-libs/libselinux python'" \
        || bad "Dockerfile.build: missing baked 'sys-libs/libselinux python'"
    grep -qF "'sys-process/audit python'" "${DOCKERFILE}" \
        && ok "Dockerfile.build: bakes 'sys-process/audit python'" \
        || bad "Dockerfile.build: missing baked 'sys-process/audit python'"
    # FINAL-stage emerge: extract the last 'RUN emerge --verbose --noreplace'
    # block (backslash-continued) and require both packages in it.
    EMERGE_BLOCK="$(awk '/^RUN emerge --verbose --noreplace/{grab=1} grab{print; if ($0 !~ /\\$/) grab=0}' "${DOCKERFILE}")"
    printf '%s' "${EMERGE_BLOCK}" | grep -q 'sys-libs/libselinux' \
        && ok "Dockerfile.build: FINAL-stage emerge installs sys-libs/libselinux" \
        || bad "Dockerfile.build: FINAL-stage emerge lost sys-libs/libselinux"
    printf '%s' "${EMERGE_BLOCK}" | grep -q 'sys-apps/policycoreutils' \
        && ok "Dockerfile.build: FINAL-stage emerge installs sys-apps/policycoreutils" \
        || bad "Dockerfile.build: FINAL-stage emerge lost sys-apps/policycoreutils"
else
    bad "Dockerfile.build missing"
fi

echo "== host-selinux-tools: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
