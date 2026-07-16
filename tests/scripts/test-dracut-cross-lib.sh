#!/usr/bin/env bash
# test-dracut-cross-lib.sh — unit test for scripts/_dracut-cross-lib.sh, the
# shared ARM cross-dracut helper (qemu-aarch64 binfmt registration + the
# availability predicate the --encrypt-root fail-fast preflight evaluates).
#
# Proves, WITHOUT a real cross-build and WITHOUT touching the kernel-global
# binfmt_misc, the load-bearing properties reported in the pki.rpi5 failure:
#   * dracut_cross_preflight_ok returns NON-ZERO when qemu-aarch64 is not
#     registered, or is registered but its interpreter is missing/not
#     executable — the exact conditions that made the live build refuse hours
#     in — and ZERO only when a usable qemu-aarch64 is present (mocked node +
#     an executable interpreter);
#   * dracut_cross_register_qemu is NON-FATAL (returns 0) even where it cannot
#     mount/register (unprivileged: /proc/.../register not writable);
#   * a preflight block built on the predicate DIES fast (exit 1) with the
#     actionable, scope-explicit message when qemu-aarch64 is unavailable;
#   * the pinned registration line carries the verified magic/mask/interpreter;
#   * every ARM builder sources the lib and wires the register + preflight in.
#
# Run: bash tests/scripts/test-dracut-cross-lib.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_dracut-cross-lib.sh"
[ -f "${LIB}" ] || { echo "  FAIL lib missing: ${LIB}"; exit 1; }

# shellcheck source=/dev/null
source "${LIB}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== _dracut-cross-lib.sh unit test =="

# ── Mock helpers ─────────────────────────────────────────────────────────────
# A binfmt_misc node is a text blob with 'enabled' + 'interpreter <path>' lines.
mk_node() {  # mk_node <file> <interpreter-path>
    printf 'enabled\ninterpreter %s\nflags: OC\noffset 0\n' "$2" > "$1"
}

# ── 1. ABSENT: node does not exist -> predicate FALSE ────────────────────────
DRACUT_CROSS_BINFMT_NODE="${WORK}/no-such-node"
if dracut_cross_preflight_ok; then
    bad "preflight_ok should be FALSE when the binfmt node is absent"
else
    ok "preflight_ok returns non-zero when qemu-aarch64 is not registered"
fi

# ── 2. REGISTERED but interpreter MISSING -> predicate FALSE ─────────────────
DRACUT_CROSS_BINFMT_NODE="${WORK}/node-badinterp"
mk_node "${DRACUT_CROSS_BINFMT_NODE}" "${WORK}/definitely-not-here-qemu"
if dracut_cross_preflight_ok; then
    bad "preflight_ok should be FALSE when the interpreter path is missing"
else
    ok "preflight_ok returns non-zero when the interpreter is missing/not -x"
fi

# ── 3. REGISTERED + interpreter EXECUTABLE -> predicate TRUE ─────────────────
MOCK_QEMU="${WORK}/qemu-aarch64"
printf '#!/bin/sh\n:\n' > "${MOCK_QEMU}"; chmod +x "${MOCK_QEMU}"
DRACUT_CROSS_BINFMT_NODE="${WORK}/node-good"
mk_node "${DRACUT_CROSS_BINFMT_NODE}" "${MOCK_QEMU}"
if dracut_cross_preflight_ok; then
    ok "preflight_ok returns 0 when qemu-aarch64 is registered + interpreter -x"
else
    bad "preflight_ok should be TRUE for a registered node with an -x interpreter"
fi

# ── 4. qemu_interp reads the node's ^interpreter, else the pinned default ────
if [ "$(dracut_cross_qemu_interp)" = "${MOCK_QEMU}" ]; then
    ok "qemu_interp reflects the registered ^interpreter path"
else
    bad "qemu_interp should echo the node's ^interpreter (${MOCK_QEMU})"
fi
DRACUT_CROSS_BINFMT_NODE="${WORK}/no-such-node"
if [ "$(dracut_cross_qemu_interp)" = "/usr/bin/qemu-aarch64" ]; then
    ok "qemu_interp falls back to the pinned /usr/bin/qemu-aarch64 default"
else
    bad "qemu_interp should fall back to the pinned default when unregistered"
fi

# ── 5. register_qemu is NON-FATAL (returns 0) even when it cannot register ───
# In this unprivileged test env /proc/sys/fs/binfmt_misc/register is not
# writable; the helper must still return 0 so a non-encrypt/unprivileged build
# never aborts on it.
DRACUT_CROSS_BINFMT_NODE="${WORK}/no-such-node"
if dracut_cross_register_qemu >/dev/null 2>&1; then
    ok "register_qemu returns 0 (non-fatal) when it cannot mount/register"
else
    bad "register_qemu must be non-fatal (return 0) even on failure"
fi

# ── 5b. pre-existing registration + interpreter missing in-container ─────────
# The kernel-global case the pki.rpi5 triage hit: the HOST's qemu-aarch64
# registration is visible but its interpreter path does not exist in the
# container. register_qemu must return 0, warn ONCE actionably (rebuild the
# builder image), and NEVER print the old contradictory "registration failed"
# WARN + "registered" INFO pair for the same entry.
DRACUT_CROSS_BINFMT_NODE="${WORK}/node-hostglobal"
mk_node "${DRACUT_CROSS_BINFMT_NODE}" "${WORK}/definitely-not-here-qemu"
OUT5B="$(dracut_cross_register_qemu 2>&1)"; RC5B=$?
if [ "${RC5B}" -eq 0 ]; then
    ok "register_qemu returns 0 on a pre-existing (host-global) registration"
else
    bad "register_qemu must return 0 when the node pre-exists (got rc=${RC5B})"
fi
case "${OUT5B}" in
    *"rebuild the builder image"*) ok "existing-registration + missing interp warns actionably (rebuild hint)" ;;
    *) bad "expected an actionable rebuild-the-builder-image WARN, got: ${OUT5B}" ;;
esac
case "${OUT5B}" in
    *"registration failed"*) bad "must not print the contradictory 'registration failed' for an existing entry" ;;
    *) ok "no contradictory 'registration failed' WARN for an existing entry" ;;
esac

# ── 5c. pre-existing registration + interpreter USABLE -> quiet no-op ────────
DRACUT_CROSS_BINFMT_NODE="${WORK}/node-hostglobal-good"
mk_node "${DRACUT_CROSS_BINFMT_NODE}" "${MOCK_QEMU}"
OUT5C="$(dracut_cross_register_qemu 2>&1)"; RC5C=$?
if [ "${RC5C}" -eq 0 ] && [ -z "${OUT5C}" ]; then
    ok "register_qemu is a quiet no-op when the existing registration is usable"
else
    bad "usable pre-existing registration should be silent rc=0 (rc=${RC5C}, out: ${OUT5C})"
fi

# ── 6. the pinned registration line carries the verified magic/mask/interp ──
# magic/mask verified byte-for-byte from a host with qemu-aarch64 registered.
EXPECT=':qemu-aarch64:M::\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64:OC'
if [ "${DRACUT_CROSS_BINFMT_LINE}" = "${EXPECT}" ]; then
    ok "pinned binfmt registration line matches the verified aarch64 magic/mask/interp"
else
    bad "DRACUT_CROSS_BINFMT_LINE drifted from the verified aarch64 registration"
fi

# ── 7. a preflight block built on the predicate DIES FAST with the message ──
# Reproduce the builder's fail-fast block in a subshell so we assert BOTH the
# non-zero exit AND the actionable, scope-explicit message — the behaviour that
# replaces discovering the missing qemu hours into the build.
PREOUT="$( {
    set -uo pipefail
    # shellcheck source=/dev/null
    source "${LIB}"
    DRACUT_CROSS_BINFMT_NODE="${WORK}/no-such-node"   # simulate: not registered
    err() { echo "ERROR: $*" >&2; }
    info() { echo "$*"; }
    BRAND="acme"; BOARD="rpi5"; ROLE="pki"
    if ! dracut_cross_preflight_ok; then
        err "--encrypt-root on ${BRAND}-${BOARD}-${ROLE} (if this build came from a multi-image mesh worklist, THIS node image is the affected one) needs the arm64 disk-boot initramfs, but no usable cross-dracut strategy is available: ${DRACUT_CROSS_BINFMT_NODE} is not registered and/or $(dracut_cross_qemu_interp) is missing/not executable."
        err "Fix: rebuild the builder image so it ships a static qemu-aarch64 ..."
        exit 1
    fi
    echo "SHOULD-NOT-REACH"
} 2>&1 )"
PRERC=$?
if [ "${PRERC}" -ne 0 ]; then
    ok "preflight block exits non-zero (${PRERC}) when qemu-aarch64 is unavailable"
else
    bad "preflight block should exit non-zero when qemu-aarch64 is unavailable"
fi
case "${PREOUT}" in
    *"--encrypt-root on acme-rpi5-pki"*"static qemu-aarch64"*)
        ok "preflight message names board+role+--encrypt-root and the qemu fix" ;;
    *) bad "preflight message not actionable/scope-explicit: ${PREOUT}" ;;
esac
case "${PREOUT}" in
    *"SHOULD-NOT-REACH"*) bad "preflight did not stop before the build" ;;
    *) ok "preflight stops before proceeding to the build" ;;
esac

# ── 8. builder wiring: every ARM builder sources the lib + wires register + preflight ──
for b in rpi5 frite orangepi5 orangepi-zero2 jetson; do
    BF="${REPO}/build-${b}-stage4.sh"
    [ -f "${BF}" ] || { bad "build-${b}-stage4.sh missing"; continue; }
    grep -qE 'source .*_dracut-cross-lib\.sh' "${BF}" \
        && ok "${b}: sources scripts/_dracut-cross-lib.sh" \
        || bad "${b}: does not source _dracut-cross-lib.sh"
    grep -q 'dracut_cross_register_qemu' "${BF}" \
        && ok "${b}: calls dracut_cross_register_qemu" \
        || bad "${b}: never calls dracut_cross_register_qemu"
    grep -q 'dracut_cross_preflight_ok' "${BF}" \
        && ok "${b}: gates a fail-fast preflight on dracut_cross_preflight_ok" \
        || bad "${b}: has no dracut_cross_preflight_ok preflight"
done

# ── 9. Dockerfile.build ships a RESOLVABLE static qemu-aarch64 config ────────
# Pinned against an empirical pretend-emerge inside the real builder image:
#   * qemu's static-user DEPEND is `static-user? ( ALL_DEPEND )` with ALL_DEPEND =
#     dev-libs/glib:2[static-libs(+)] + virtual/zlib:=[static-libs(+)] +
#     xattr? ( sys-apps/attr[static-libs(+)] ) — every one of those HAS a real,
#     default-OFF static-libs flag (so the (+) fallback never applies) and glib
#     forwards static-libs to dev-libs/libpcre2. Without package.use entries for
#     that whole closure, `emerge app-emulation/qemu` halts with 'USE changes
#     necessary' and the builder image DOES NOT BUILD (reproduced: old config
#     RC=1 demanding glib/attr/libpcre2 static-libs; fixed config RC=0).
#   * USE_EXPAND variables (QEMU_SOFTMMU_TARGETS) canNOT be set per-package via
#     package.env, and qemu has no plain `softmmu` USE flag — the only working
#     way to cancel the amd64 profile's QEMU_SOFTMMU_TARGETS="x86_64" is the
#     expanded flag -qemu_softmmu_targets_x86_64 in package.use.
DOCKERFILE="${REPO}/Dockerfile.build"
if [ -f "${DOCKERFILE}" ]; then
    grep -qE 'app-emulation/qemu[^'"'"']*static-user[^'"'"']*qemu_user_targets_aarch64' "${DOCKERFILE}" \
        && ok "Dockerfile.build: qemu gets static-user + qemu_user_targets_aarch64 via package.use" \
        || bad "Dockerfile.build: qemu package.use line lost static-user/qemu_user_targets_aarch64"
    grep -q -- '-qemu_softmmu_targets_x86_64' "${DOCKERFILE}" \
        && ok "Dockerfile.build: profile QEMU_SOFTMMU_TARGETS=x86_64 cancelled via -qemu_softmmu_targets_x86_64" \
        || bad "Dockerfile.build: missing -qemu_softmmu_targets_x86_64 (image would build the x86_64 system emulator + firmware blobs)"
    for pkg in 'dev-libs/glib' 'dev-libs/libpcre2' 'sys-apps/attr' 'virtual/zlib' 'sys-libs/zlib'; do
        grep -qE "'${pkg} static-libs'" "${DOCKERFILE}" \
            && ok "Dockerfile.build: ${pkg} static-libs enabled (qemu[static-user] DEPEND closure)" \
            || bad "Dockerfile.build: ${pkg} static-libs MISSING — qemu[static-user] emerge halts with 'USE changes necessary'"
    done
    if grep -qE '/etc/portage/(package\.)?env/snapdragon-qemu-user' "${DOCKERFILE}"; then
        bad "Dockerfile.build: no-op per-package USE_EXPAND via package.env/env is back (portage ignores it)"
    else
        ok "Dockerfile.build: no per-package USE_EXPAND-via-package.env no-op"
    fi
    if grep -qE "'[^']*qemu[^']*-softmmu[^']*'" "${DOCKERFILE}"; then
        bad "Dockerfile.build: bogus '-softmmu' USE flag is back (qemu has no such flag; silently ignored)"
    else
        ok "Dockerfile.build: no bogus '-softmmu' pseudo-flag"
    fi
else
    bad "Dockerfile.build missing"
fi

echo "== dracut-cross-lib: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
