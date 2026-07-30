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

# ── 7b. target-exec blocker filter (pure function) ──────────────────────────
# dracut_cross_target_exec_blockers: stdin atoms -> intersection with the
# pinned waf family (tdb/talloc/samba/cifs-utils — the packages that EXECUTE
# cross-built test binaries at configure time; session 20260716-160638-f8c153).
for fam in sys-libs/tdb sys-libs/talloc net-fs/samba net-fs/cifs-utils; do
    if [ "$(printf '%s\n' "${fam}" | dracut_cross_target_exec_blockers)" = "${fam}" ]; then
        ok "target_exec_blockers matches family atom ${fam}"
    else
        bad "target_exec_blockers should match family atom ${fam}"
    fi
done
if [ -z "$(printf '%s\n' sys-libs/glibc app-misc/foo | dracut_cross_target_exec_blockers)" ]; then
    ok "target_exec_blockers filters out non-family atoms (sys-libs/glibc)"
else
    bad "target_exec_blockers must not match non-family atoms"
fi
if [ -z "$(printf '' | dracut_cross_target_exec_blockers)" ]; then
    ok "target_exec_blockers: empty stdin -> empty output"
else
    bad "target_exec_blockers: empty stdin should produce empty output"
fi
MULTI="$(printf '%s\n' sys-libs/glibc sys-libs/tdb net-fs/cifs-utils | dracut_cross_target_exec_blockers | tr '\n' ' ')"
if [ "${MULTI}" = "sys-libs/tdb net-fs/cifs-utils " ]; then
    ok "target_exec_blockers keeps order and returns only the intersection"
else
    bad "target_exec_blockers intersection wrong: '${MULTI}'"
fi

# ── 7c. the general missing-qemu preflight block (simulated, all 3 states) ───
# Reproduce the builders' fix-C block with a stub resolve_stage4_packages so we
# assert the full state machine: (i) unusable qemu + waf-family atom in the
# resolved set -> exit 1 + the actionable make-docker-image message; (ii)
# unusable qemu + waf-free set -> WARN and continue (exit 0 — the preflight
# must NEVER block a build that would succeed); (iii) usable qemu -> silent.
run_qemu_preflight() {  # $1 = binfmt node path, $2 = newline-separated package set
    local _node="$1" _set="$2"
    (
        set -uo pipefail
        # shellcheck source=/dev/null
        source "${LIB}"
        DRACUT_CROSS_BINFMT_NODE="${_node}"
        err()  { echo "ERROR: $*" >&2; }
        warn() { echo "WARNING: $*" >&2; }
        resolve_stage4_packages() { printf '%s' "${_set}"; }
        dracut_cross_register_qemu >/dev/null 2>&1 || true
        if ! dracut_cross_preflight_ok; then
            _exec_blockers="$(resolve_stage4_packages quiet | dracut_cross_target_exec_blockers | tr '\n' ' ')"
            _exec_blockers="${_exec_blockers% }"
            if [ -n "${_exec_blockers}" ]; then
                err "${_exec_blockers} build by EXECUTING cross-compiled test binaries (waf configure) but qemu-aarch64 is unusable in THIS container."
                err "Fix: rebuild the builder image so it ships a static qemu-aarch64 (make docker-image) AND run in a --privileged container."
                exit 1
            fi
            warn "qemu-aarch64 unusable in this container — no target-exec (waf-family) packages in the resolved set; continuing."
        fi
        echo "REACHED-BUILD"
    ) 2>&1
}
SET_WITH_WAF=$'sys-apps/baselayout\nnet-fs/cifs-utils\napp-misc/ca-certificates\n'
SET_WAF_FREE=$'sys-apps/baselayout\napp-misc/ca-certificates\n'
OUT_I="$(run_qemu_preflight "${WORK}/no-such-node" "${SET_WITH_WAF}")"; RC_I=$?
if [ "${RC_I}" -ne 0 ]; then
    ok "preflight(i): unusable qemu + waf-family set exits non-zero (${RC_I})"
else
    bad "preflight(i): should exit non-zero (got 0; out: ${OUT_I})"
fi
case "${OUT_I}" in
    *"net-fs/cifs-utils"*"make docker-image"*) ok "preflight(i): message names the blocker and the make docker-image fix" ;;
    *) bad "preflight(i): message not actionable: ${OUT_I}" ;;
esac
case "${OUT_I}" in
    *"REACHED-BUILD"*) bad "preflight(i): must stop before the build" ;;
    *) ok "preflight(i): stops before the build" ;;
esac
OUT_II="$(run_qemu_preflight "${WORK}/no-such-node" "${SET_WAF_FREE}")"; RC_II=$?
if [ "${RC_II}" -eq 0 ]; then
    ok "preflight(ii): unusable qemu + waf-free set continues (exit 0)"
else
    bad "preflight(ii): must never block a waf-free build (rc=${RC_II}; out: ${OUT_II})"
fi
case "${OUT_II}" in
    *"WARNING:"*"REACHED-BUILD"*) ok "preflight(ii): WARNs and proceeds" ;;
    *) bad "preflight(ii): expected WARN + proceed, got: ${OUT_II}" ;;
esac
OUT_III="$(run_qemu_preflight "${WORK}/node-good" "${SET_WITH_WAF}")"; RC_III=$?
if [ "${RC_III}" -eq 0 ] && [ "${OUT_III}" = "REACHED-BUILD" ]; then
    ok "preflight(iii): usable qemu + waf-family set passes silently"
else
    bad "preflight(iii): expected silent pass (rc=${RC_III}; out: ${OUT_III})"
fi

# ── 8. builder wiring: every ARM builder sources the lib + wires register + preflight ──
for b in rpi5 frite orangepi5 orangepi-zero2 orangepi-zero2w orangepi-zero3 jetson; do
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
    # Fix-C wiring: the GENERAL (non-encrypt-root) missing-qemu preflight must
    # consult the single-sourced resolver and the pinned waf family INSIDE the
    # prerequisites section, and carry the actionable message idiom.
    PREREQ_REGION="$(sed -n '/banner "Verifying prerequisites"/,/^banner /p' "${BF}")"
    printf '%s' "${PREREQ_REGION}" | grep -q 'dracut_cross_target_exec_blockers' \
        && ok "${b}: general qemu preflight consults dracut_cross_target_exec_blockers in the prerequisites section" \
        || bad "${b}: prerequisites section never calls dracut_cross_target_exec_blockers"
    printf '%s' "${PREREQ_REGION}" | grep -q 'resolve_stage4_packages quiet' \
        && ok "${b}: general qemu preflight resolves the REAL package set (resolve_stage4_packages quiet)" \
        || bad "${b}: general qemu preflight does not use resolve_stage4_packages"
    grep -q 'They would fail ~40min in and be silently dropped' "${BF}" \
        && ok "${b}: general qemu preflight carries the honest ~40min/silently-dropped message" \
        || bad "${b}: general qemu preflight message idiom missing"
    # The blockers branch must still HARD-EXIT (a softened ':'/'true' turns the
    # fail-fast into a doomed multi-hour build). Extract exactly the general
    # preflight block (from the _exec_blockers resolve to its unset) and
    # require an exit 1 inside it.
    GP_BLOCK="$(sed -n '/_exec_blockers="\$(resolve_stage4_packages quiet/,/unset _exec_blockers/p' "${BF}")"
    printf '%s' "${GP_BLOCK}" | grep -qE '^\s*exit 1$' \
        && ok "${b}: general qemu preflight blockers branch hard-exits (exit 1)" \
        || bad "${b}: general qemu preflight lost its exit 1 (fail-fast defanged)"
    # Single-source invariant: Phase 2 must consume the same resolver (no
    # second inline assembly to drift from the preflight's view).
    # (top-of-line match: the resolver's own internal packages.list mapfile is
    # indented inside the function; a COLUMN-0 grep-assembly means Phase 2
    # regrew its own inline copy.)
    if grep -qE '^mapfile -t STAGE4_PACKAGES < <\(resolve_stage4_packages\)' "${BF}" \
       && ! grep -qE '^mapfile -t STAGE4_PACKAGES < <\(grep|^mapfile -t STAGE4_PACKAGES < <\(\s*$' "${BF}"; then
        ok "${b}: Phase 2 consumes resolve_stage4_packages (single-sourced set)"
    else
        bad "${b}: Phase 2 does not use resolve_stage4_packages (drift risk)"
    fi
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
    if grep -qE '/etc/portage/(package\.)?env/hugmesh-qemu-user' "${DOCKERFILE}"; then
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
