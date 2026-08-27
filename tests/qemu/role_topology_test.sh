#!/usr/bin/env bash
# role_topology_test.sh — HERMETIC tests for assertions.sh's ROLE TOPOLOGY section.
# Boots nothing, mounts nothing, needs no guest and no image: assert_role_topology()
# is sed-extracted from assertions.sh (the verdict_test.sh / devices_test.sh pattern)
# and driven against FIXTURE ROOTFS TREES built in a tmpdir.
#
#   bash tests/qemu/role_topology_test.sh
#
# WHY THIS FILE EXISTS. Measured 2026-08-26 against the three 2026-08-23 rpi5 images,
# read with debugfs at offset 1050624*512 (no mount, no loop device):
#
#   backend  /etc/runlevels/default == frontend /etc/runlevels/default, EXACTLY
#   pki      == that same set + headscale
#   the only file differing in CONTENT between backend and frontend: /etc/hugmesh/role
#
# All 42 assertions that preceded the role-topology section therefore graded properties
# ALL THREE ROLES SHARE. An image built with the wrong role payload scored 42/42 PASS.
# The tests below pin the fix, and the SWAP TEST is the one that matters: it stamps a
# pki rootfs with a worker's role marker and requires the suite to go RED.
#
# TWO DISCIPLINES THIS FILE LEARNED THE HARD WAY, BOTH FROM A REVIEW OF ITS FIRST CUT:
#
#  1. THE FIXTURES MUST HAVE THE SHAPE THE PRODUCT SHIPS. The first cut wrote RELATIVE
#     runlevel symlinks (`../../init.d/x`). Both builders write ABSOLUTE ones
#     (build-rpi5-stage4.sh:4038, build-x86-host-stage4.sh:4526), as does OpenRC's own
#     rc-update — and against that real shape the dangling-symlink assertion resolved
#     every target against the HOST's /etc/init.d and failed a PERFECTLY CORRECT image.
#     mkfixture() now defaults to absolute and covers relative as a second shape.
#  2. A COUNT ASSERTION (`>= 1 failure`) PROTECTS ALMOST NOTHING. Six mutations that
#     deleted or neutered 24 of this section's ~30 assertions all left the suite green,
#     because some OTHER assertion on the same fixture was still failing and satisfied
#     the count. Every leg below now asserts THE SPECIFIC FAIL MESSAGE EXPECTED, on a
#     line carrying the FAIL VERDICT, and every loop has its own single-defect fixture.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSERTIONS="${HERE}/assertions.sh"
[ -f "${ASSERTIONS}" ] || { echo "cannot find ${ASSERTIONS}" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── VERDICT-AWARE MATCHERS ─────────────────────────────────────────────────
# GREP THE VERDICT, NOT JUST THE MESSAGE. Every mutation of this section flips
# bad->ok while KEEPING the message text, so a bare `grep 'MUST NOT run a control
# server'` matches happily — on a PASS line. That is the prose-naming-a-token
# inversion that has broken checks in this repo repeatedly, and it survived the
# first cut of this very file in two places. Never match a message without its
# verdict. (No `| grep -q` anywhere: under pipefail a FOUND match SIGPIPEs the
# upstream grep and reports failure. Plain grep, output drained to /dev/null.)
has_fail() { grep 'FAIL' <<<"$1" | grep -F -- "$2" >/dev/null; }
has_skip() { grep 'SKIP' <<<"$1" | grep -F -- "$2" >/dev/null; }
has_pass() { grep 'PASS' <<<"$1" | grep -F -- "$2" >/dev/null; }

# want_fail OUT LABEL PATTERN — the named FAIL must be present
want_fail() {
    if has_fail "$1" "$3"; then _ok "$2"
    else _bad "$2 — no FAIL line matching: $3"; echo "$1" | sed 's/^/      | /'; fi
}
# no_fail OUT LABEL PATTERN — the named FAIL must be ABSENT
no_fail() {
    if has_fail "$1" "$3"; then _bad "$2 — unexpected FAIL matching: $3"; echo "$1" | grep FAIL | sed 's/^/      | /'
    else _ok "$2"; fi
}
want_skip() {
    if has_skip "$1" "$3"; then _ok "$2"
    else _bad "$2 — no SKIP line matching: $3"; echo "$1" | sed 's/^/      | /'; fi
}

# ── sed-extract the section under test ─────────────────────────────────────
extract() { # SRC FUNC OUT — die loudly if the function is not found (NO silent skip)
    sed -n "/^$2() {/,/^}/p" "$1" >> "$3"
    grep "^$2() {" "$3" >/dev/null || { echo "could not extract $2 from $1" >&2; exit 2; }
}
build_lib() { # SRC OUT — the three functions + the ok/bad/skip counters they call
    local src; local out
    src="$1"; out="$2"
    cat > "${out}" <<'HDR'
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP  $*"; }
HDR
    extract "${src}" _rl_has              "${out}"
    extract "${src}" _rl_dangling         "${out}"
    extract "${src}" assert_role_topology "${out}"
    printf 'assert_role_topology "${FIXTURE_ROOT}"\necho "RESULT: ${PASS} passed, ${FAIL} failed"\n' >> "${out}"
}

# run_fixture LIB ROOT HS_WANT HS_SRC -> prints the whole transcript + "RESULT: N passed, M failed"
run_fixture() {
    local lib; local root; local want; local src
    lib="$1"; root="$2"; want="$3"; src="$4"
    FIXTURE_ROOT="${root}" _hs_want="${want}" _hs_src="${src}" bash -c \
        'set -u; _hs_want="${_hs_want}"; _hs_src="${_hs_src}"; . "$1"' _ "${lib}" 2>&1
}
fails_of() { sed -n 's/^RESULT: [0-9]* passed, \([0-9]*\) failed$/\1/p' <<<"$1"; }

# ── fixture builder: a rootfs that mirrors what the real images actually ship ──
# Cluster-node default runlevel, copied from the debugfs listing of the 2026-08-23
# backend image (netmount included — it is really there, and the table must tolerate
# services it does not name).
CLUSTER_RL="sshd NetworkManager cronie haveged growroot keys-provision auditd local
            hugmesh-update hugmesh-firewall-reconcile hugmesh-coturn-firewall
            hugmesh-go-live-reconcile containerd kubelet tailscaled netmount"
CLIENT_RL="sshd NetworkManager cronie haveged growroot keys-provision auditd local
           hugmesh-update dbus elogind display-manager tailscaled netmount"
# The seven agents that ship in EVERY image and are linked in NONE of them.
AGENTS="hugmesh-device-registry-sync hugmesh-policy-sync hugmesh-node-storage-reconcile
        hugmesh-domain-reconcile hugmesh-vpn-reconcile hugmesh-tor-reconcile
        hugmesh-egress-vpn"

rl_link() { # ROOT SERVICE [abs|rel] — link a service into the default runlevel
    local d; local s; local shape
    d="$1"; s="$2"; shape="${3:-abs}"
    case "${shape}" in
        rel) ln -sf "../../init.d/${s}" "${d}/etc/runlevels/default/${s}" ;;
        # THE SHAPE BOTH BUILDERS ACTUALLY WRITE (build-rpi5-stage4.sh:4038,
        # build-x86-host-stage4.sh:4526) and the shape OpenRC's rc-update writes.
        *)   ln -sf "/etc/init.d/${s}"  "${d}/etc/runlevels/default/${s}" ;;
    esac
}

mkfixture() { # ROLE DIR [abs|rel] — build a CORRECT rootfs for that role
    local role; local d; local shape; local rl; local s
    role="$1"; d="$2"; shape="${3:-abs}"
    mkdir -p "${d}/etc/hugmesh" "${d}/etc/init.d" "${d}/etc/runlevels/default" \
             "${d}/etc/cron.d" "${d}/usr/sbin"
    echo "${role}" > "${d}/etc/hugmesh/role"
    case "${role}" in
        desktop) rl="${CLIENT_RL}" ;;
        *)       rl="${CLUSTER_RL}" ;;
    esac
    case "${role}" in
        pki|generic) rl="${rl} headscale" ;;
    esac
    # /etc/init.d/tailscaled is copied UNCONDITIONALLY by the builder
    # (build-rpi5-stage4.sh:3670-3673) — it is the BINARY that tracks the mesh
    # posture, so the fixture ships both, and the negative legs remove the binary.
    for s in ${rl} ${AGENTS} headscale tailscaled; do : > "${d}/etc/init.d/${s}"; done
    : > "${d}/usr/sbin/tailscaled"; chmod +x "${d}/usr/sbin/tailscaled"
    for s in ${rl}; do rl_link "${d}" "${s}" "${shape}"; done
}

echo "══ 1. a CORRECT rootfs of each role passes with zero failures ══"
for role in pki backend frontend desktop; do
    mkfixture "${role}" "${TMP}/${role}"
done
LIB="${TMP}/lib.sh"; build_lib "${ASSERTIONS}" "${LIB}"
for role in pki backend frontend desktop; do
    case "${role}" in pki) want=true ;; *) want=false ;; esac
    out="$(run_fixture "${LIB}" "${TMP}/${role}" "${want}" "KEYS manifest")"
    n="$(fails_of "${out}")"
    if [ "${n}" = 0 ]; then _ok "role ${role}: clean rootfs (ABSOLUTE links, real shape) => 0 failures"
    else _bad "role ${role}: clean rootfs reported ${n} failure(s)"; echo "${out}" | grep FAIL | sed 's/^/      | /'; fi
done
# THE REGRESSION THAT ATE THE FIRST CUT OF THIS FILE. A prefix-blind dangling check
# resolves an ABSOLUTE runlevel target against the HOST's /etc/init.d, so a correct
# image is graded dangling — nondeterministically, on whichever service names the host
# happens to have installed. Assert the absence of that FAIL explicitly, not just the
# zero-count above, so the message is named and a future regression says why.
out="$(run_fixture "${LIB}" "${TMP}/backend" false "KEYS manifest")"
no_fail "${out}" "absolute runlevel links are NOT reported dangling (prefix-aware resolution)" \
        "dangling default-runlevel symlink"
# Relative links are the other legal shape (a hand-made symlink, some rc-update ports).
mkfixture backend "${TMP}/backend-rel" rel
out="$(run_fixture "${LIB}" "${TMP}/backend-rel" false "KEYS manifest")"
[ "$(fails_of "${out}")" = 0 ] \
    && _ok "role backend: clean rootfs with RELATIVE links => 0 failures (both shapes handled)" \
    || { _bad "relative-link rootfs reported failures"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }

echo
echo "══ 2. THE SWAP TEST — a worker marker on a pki rootfs must go RED ══"
# This is the test the whole unit exists for. The rootfs is untouched: it still links
# headscale, still carries the control-server payload. Only /etc/hugmesh/role is
# rewritten, exactly as a build that shipped the wrong role payload would present.
cp -a "${TMP}/pki" "${TMP}/swap-pki-as-frontend"
echo "frontend" > "${TMP}/swap-pki-as-frontend/etc/hugmesh/role"
grep -x frontend "${TMP}/swap-pki-as-frontend/etc/hugmesh/role" >/dev/null \
    && _ok "swap fixture really was mutated (marker now reads 'frontend')" \
    || _bad "swap fixture was NOT mutated — the test below would be vacuous"
SWAP_OUT="$(run_fixture "${LIB}" "${TMP}/swap-pki-as-frontend" true "KEYS manifest")"
SWAP_FAILS="$(fails_of "${SWAP_OUT}")"
[ "${SWAP_FAILS:-0}" -ge 1 ] \
    && _ok "pki rootfs stamped 'frontend' => ${SWAP_FAILS} FAIL(s) (was a clean PASS before this unit)" \
    || { _bad "pki rootfs stamped 'frontend' still PASSES — the vacuous pass is not fixed"; echo "${SWAP_OUT}" | sed 's/^/      | /'; }
want_fail "${SWAP_OUT}" "the rogue-control-server assertion is what caught it (on a FAIL line)" \
          "MUST NOT run a control server"
want_fail "${SWAP_OUT}" "the marker-vs-manifest cross-check caught it independently" \
          "role/manifest cross-check"

echo
echo "══ 3. the other direction — a pki marker on a worker rootfs must go RED ══"
cp -a "${TMP}/backend" "${TMP}/swap-backend-as-pki"
echo "pki" > "${TMP}/swap-backend-as-pki/etc/hugmesh/role"
grep -x pki "${TMP}/swap-backend-as-pki/etc/hugmesh/role" >/dev/null \
    && _ok "swap fixture really was mutated (marker now reads 'pki')" \
    || _bad "swap fixture was NOT mutated"
out="$(run_fixture "${LIB}" "${TMP}/swap-backend-as-pki" false "KEYS manifest")"
want_fail "${out}" "backend rootfs stamped 'pki' => the MISSING control server is named" \
          "headscale MISSING from the default runlevel"
want_fail "${out}" "backend rootfs stamped 'pki' => the cross-check names the disagreement" \
          "role/manifest cross-check"

echo
echo "══ 4. a desktop payload on a cluster marker, and a cluster payload on a client ══"
cp -a "${TMP}/desktop" "${TMP}/swap-desktop-as-backend"
echo "backend" > "${TMP}/swap-desktop-as-backend/etc/hugmesh/role"
out="$(run_fixture "${LIB}" "${TMP}/swap-desktop-as-backend" false "KEYS manifest")"
want_fail "${out}" "desktop-as-backend: containerd is named MISSING" \
          "containerd MISSING from the default runlevel"
want_fail "${out}" "desktop-as-backend: kubelet is named MISSING" \
          "kubelet MISSING from the default runlevel"
want_fail "${out}" "desktop-as-backend: the display-manager on a k8s node is named" \
          "display-manager is in the default runlevel but MUST NOT be on a cluster node"
cp -a "${TMP}/backend" "${TMP}/swap-backend-as-desktop"
echo "desktop" > "${TMP}/swap-backend-as-desktop/etc/hugmesh/role"
out="$(run_fixture "${LIB}" "${TMP}/swap-backend-as-desktop" false "KEYS manifest")"
want_fail "${out}" "backend-as-desktop: containerd on a client is named forbidden" \
          "containerd is in the default runlevel but MUST NOT be on a client node"
want_fail "${out}" "backend-as-desktop: the missing seat/login stack is named" \
          "elogind MISSING from the default runlevel"

echo
echo "══ 5. the marker itself: absent, empty, and bogus are all FAIL, never skip ══"
for variant in absent empty bogus; do
    cp -a "${TMP}/backend" "${TMP}/marker-${variant}"
    case "${variant}" in
        absent) rm -f "${TMP}/marker-${variant}/etc/hugmesh/role" ;;
        empty)  : > "${TMP}/marker-${variant}/etc/hugmesh/role" ;;
        bogus)  echo "beckend" > "${TMP}/marker-${variant}/etc/hugmesh/role" ;;
    esac
    out="$(run_fixture "${LIB}" "${TMP}/marker-${variant}" false "KEYS manifest")"
    case "${variant}" in
        bogus) want_fail "${out}" "role marker ${variant} => the value is quoted back as unknown" \
                         "holds 'beckend', which is not one of the five roles" ;;
        *)     want_fail "${out}" "role marker ${variant} => FAIL (not a silent skip)" \
                         "/etc/hugmesh/role is missing or empty" ;;
    esac
done

echo
echo "══ 6. ONE DEFECT AT A TIME — a single-fault fixture behind every loop ══"
# A count assertion (\">= 1 failure\") cannot tell which loop caught what: on the
# multi-fault fixtures above, deleting EITHER the required-services loop or the
# must-not-run loop entirely still left a failure from the other, so the suite stayed
# green while 17 assertions vanished. Each loop therefore gets a rootfs whose ONLY
# defect is one that loop owns, and the assertion names the message.
#
# (i) required-services loop: a cluster node missing containerd and NOTHING else.
cp -a "${TMP}/backend" "${TMP}/miss-containerd"
rm -f "${TMP}/miss-containerd/etc/runlevels/default/containerd"
out="$(run_fixture "${LIB}" "${TMP}/miss-containerd" false "KEYS manifest")"
want_fail "${out}" "(i) required loop: containerd unlinked on a backend is caught" \
          "containerd MISSING from the default runlevel"
[ "$(fails_of "${out}")" = 1 ] \
    && _ok "(i) ...and it is the ONLY failure (single-fault fixture, so the loop is load-bearing alone)" \
    || { _bad "(i) single-fault fixture produced $(fails_of "${out}") failures"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }
# (ii) must-not-run loop: a cluster node carrying display-manager and NOTHING else wrong.
cp -a "${TMP}/backend" "${TMP}/rogue-dm"
: > "${TMP}/rogue-dm/etc/init.d/display-manager"
rl_link "${TMP}/rogue-dm" display-manager
out="$(run_fixture "${LIB}" "${TMP}/rogue-dm" false "KEYS manifest")"
want_fail "${out}" "(ii) must-not-run loop: a display-manager on a k8s node is caught" \
          "display-manager is in the default runlevel but MUST NOT be on a cluster node"
[ "$(fails_of "${out}")" = 1 ] \
    && _ok "(ii) ...and it is the ONLY failure" \
    || { _bad "(ii) single-fault fixture produced $(fails_of "${out}") failures"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }
# (iii) agent-presence loop: one agent's init script deleted and NOTHING else.
cp -a "${TMP}/backend" "${TMP}/no-agent"
rm -f "${TMP}/no-agent/etc/init.d/hugmesh-policy-sync"
out="$(run_fixture "${LIB}" "${TMP}/no-agent" false "KEYS manifest")"
want_fail "${out}" "(iii) agent loop: a missing agent init script is caught" \
          "hugmesh-policy-sync init script NOT baked"
[ "$(fails_of "${out}")" = 1 ] \
    && _ok "(iii) ...and it is the ONLY failure" \
    || { _bad "(iii) single-fault fixture produced $(fails_of "${out}") failures"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }
# (iv) the desktop side of the required loop: a client with no seat stack.
cp -a "${TMP}/desktop" "${TMP}/desktop-no-dbus"
rm -f "${TMP}/desktop-no-dbus/etc/runlevels/default/dbus"
out="$(run_fixture "${LIB}" "${TMP}/desktop-no-dbus" false "KEYS manifest")"
want_fail "${out}" "(iv) required loop, client class: dbus unlinked on a desktop is caught" \
          "dbus MISSING from the default runlevel"

echo
echo "══ 7. MESH POSTURE — tailscaled, and the build options the section must not misjudge ══"
# --skip-mesh / --skip-tailscale are pre-existing, ROLE-INDEPENDENT build options
# (build-rpi5-stage4.sh:1055-1056) that produce a legitimate image with no tailscaled
# and NO --standalone marker. The first cut graded that image a defect. Posture is
# resolved from the ARTIFACT: /usr/sbin/tailscaled ships iff a mesh client was asked
# for (build-rpi5-stage4.sh:4343, and :4347 aborts the build if the fetch fails),
# while /etc/init.d/tailscaled is copied unconditionally at :3670-3673.
# (a) a --skip-tailscale-shaped image: no binary, no link, no standalone marker.
cp -a "${TMP}/backend" "${TMP}/no-mesh-client"
rm -f "${TMP}/no-mesh-client/etc/runlevels/default/tailscaled" \
      "${TMP}/no-mesh-client/usr/sbin/tailscaled"
out="$(run_fixture "${LIB}" "${TMP}/no-mesh-client" false "KEYS manifest")"
want_skip "${out}" "(a) --skip-tailscale-shaped image (no binary) => SKIP, not a false FAIL" \
          "no /usr/sbin/tailscaled in this image"
[ "$(fails_of "${out}")" = 0 ] \
    && _ok "(a) ...and the image scores 0 failures overall" \
    || { _bad "(a) a legitimate mesh-less image still fails"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }
# (b) the REAL defect this assertion exists for: the client shipped but was never scheduled.
cp -a "${TMP}/backend" "${TMP}/unscheduled-tailscaled"
rm -f "${TMP}/unscheduled-tailscaled/etc/runlevels/default/tailscaled"
out="$(run_fixture "${LIB}" "${TMP}/unscheduled-tailscaled" false "KEYS manifest")"
want_fail "${out}" "(b) binary installed but tailscaled unlinked => caught" \
          "/usr/sbin/tailscaled is installed but tailscaled is MISSING"
[ "$(fails_of "${out}")" = 1 ] \
    && _ok "(b) ...and it is the ONLY failure" \
    || { _bad "(b) single-fault fixture produced $(fails_of "${out}") failures"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }
# (c) the inverse defect: scheduled with no binary behind it.
cp -a "${TMP}/backend" "${TMP}/inert-tailscaled"
rm -f "${TMP}/inert-tailscaled/usr/sbin/tailscaled"
out="$(run_fixture "${LIB}" "${TMP}/inert-tailscaled" false "KEYS manifest")"
want_fail "${out}" "(c) tailscaled scheduled with no /usr/sbin/tailscaled => caught" \
          "an inert mesh client that fails to start every boot"
# (d) --standalone still skips, and the SKIP names the marker.
cp -a "${TMP}/no-mesh-client" "${TMP}/standalone"
echo true > "${TMP}/standalone/etc/hugmesh/standalone"
out="$(run_fixture "${LIB}" "${TMP}/standalone" false "KEYS manifest")"
want_skip "${out}" "(d) a --standalone image skips on its own marker" "STANDALONE image"

echo
echo "══ 8. the always-true integrity assertions ══"
# A dangling runlevel symlink — OpenRC start failure nothing else in assertions.sh sees.
# Written ABSOLUTE, the shape the builder writes, so this grades the real case.
cp -a "${TMP}/backend" "${TMP}/dangle"
ln -sf "/etc/init.d/does-not-exist" "${TMP}/dangle/etc/runlevels/default/ghost"
out="$(run_fixture "${LIB}" "${TMP}/dangle" false "KEYS manifest")"
want_fail "${out}" "an ABSOLUTE dangling default-runlevel symlink is caught" \
          "dangling default-runlevel symlink(s) with no /etc/init.d target: ghost"
# ...and the relative shape too.
cp -a "${TMP}/backend" "${TMP}/dangle-rel"
ln -sf "../../init.d/does-not-exist" "${TMP}/dangle-rel/etc/runlevels/default/ghost"
out="$(run_fixture "${LIB}" "${TMP}/dangle-rel" false "KEYS manifest")"
want_fail "${out}" "a RELATIVE dangling default-runlevel symlink is caught" \
          "dangling default-runlevel symlink(s) with no /etc/init.d target: ghost"
# An egress tunnel with no reconcile agent owning it.
cp -a "${TMP}/backend" "${TMP}/unowned-vpn"
rl_link "${TMP}/unowned-vpn" hugmesh-egress-vpn
out="$(run_fixture "${LIB}" "${TMP}/unowned-vpn" false "KEYS manifest")"
want_fail "${out}" "hugmesh-egress-vpn scheduled without its reconcile agent is caught" \
          "NO hugmesh-vpn-reconcile owning it"
# Half-activation: scheduled agent, no convergence cron.
cp -a "${TMP}/backend" "${TMP}/half-activated"
rl_link "${TMP}/half-activated" hugmesh-policy-sync
out="$(run_fixture "${LIB}" "${TMP}/half-activated" false "KEYS manifest")"
want_fail "${out}" "a scheduled agent with no /etc/cron.d drop-in is caught (on a FAIL line)" \
          "no convergence floor"
# ...and installing the cron clears it (the assertion is not a constant FAIL).
# On a COPY: ${TMP}/half-activated must stay half-activated, because mutation leg (i)
# below re-runs it and a cron-installed tree would skip the assertion entirely — the
# leg would then "prove" the mutant was caught while grading nothing at all.
cp -a "${TMP}/half-activated" "${TMP}/half-activated-cron"
: > "${TMP}/half-activated-cron/etc/cron.d/hugmesh-policy-sync"
out="$(run_fixture "${LIB}" "${TMP}/half-activated-cron" false "KEYS manifest")"
[ "$(fails_of "${out}")" = 0 ] \
    && _ok "installing the cron clears it (assertion is two-sided, not a constant FAIL)" \
    || { _bad "cron installed but still failing"; echo "${out}" | grep FAIL | sed 's/^/      | /'; }
# An unknown manifest intent must SKIP, never invent a pass or a fail.
out="$(run_fixture "${LIB}" "${TMP}/backend" unknown "")"
want_skip "${out}" "unknown manifest intent => SKIP (not evidence in either direction)" \
          "role/manifest cross-check"

echo
echo "══ 9. the KEYS payload generators must be ROLE-ACCURATE ══"
# The cross-check compares the manifest's headscale intent against the image's role
# marker, so a payload generator that hardcodes enabled:true for EVERY role turns a
# PERFECTLY CORRECT backend image into a FAIL that blames the image. Both generators
# must derive it per role. STRIP COMMENTS BEFORE CLASSIFYING: prose naming the old
# literal must not decide the verdict — that inversion has bitten this repo repeatedly.
payload_verdict() { # FILE -> derived | hardcoded-true | unknown
    local l
    l="$(sed 's/[[:space:]]*#.*$//' "$1" | grep '"headscale": *{ *"enabled":' | head -1)"
    case "${l}" in
        *'"enabled": ${HS_ENABLED}'*) echo derived ;;
        *'"enabled": true'*)          echo hardcoded-true ;;
        *)                            echo unknown ;;
    esac
}
role_case_present() { # FILE — a pki|generic|omnibus arm setting HS_ENABLED=true
    sed 's/[[:space:]]*#.*$//' "$1" | grep 'pki|generic|omnibus) *HS_ENABLED=true' >/dev/null
}
for g in run-qemu-test.sh docker-entrypoint.sh; do
    v="$(payload_verdict "${HERE}/${g}")"
    [ "${v}" = derived ] \
        && _ok "${g}: headscale intent is derived per role, not hardcoded (${v})" \
        || _bad "${g}: headscale payload is '${v}' — a non-pki run will false-FAIL the role/manifest cross-check"
    role_case_present "${HERE}/${g}" \
        && _ok "${g}: carries the pki|generic|omnibus => HS_ENABLED=true arm" \
        || _bad "${g}: no role case deriving HS_ENABLED"
done
# And the behaviour that made it matter: a CORRECT backend rootfs with want=true is
# graded a mismatch. The cross-check is right here; the stale payload was the bug.
out="$(run_fixture "${LIB}" "${TMP}/backend" true "KEYS manifest")"
want_fail "${out}" "a correct backend rootfs + manifest want=true IS graded a mismatch (this is why the payload was fixed)" \
          "asked headscale=true but this image's marker says 'backend'"

echo
echo "══ 10. MUTATION LEGS — break production first, prove the guard is load-bearing ══"
# Each leg mutates a COPY of the production file, VERIFIES THE COPY REALLY CHANGED,
# rebuilds the library from it, and re-runs a fixture. The guard is load-bearing iff
# the mutant NO LONGER catches the defect. MUT_SRC is set by mutate(); it is NOT
# returned on stdout, because _ok/_bad print there and a $(mutate ...) capture would
# swallow the tally lines into the path.
MUT_SRC=""
mutate() { # NAME SEDPROG [SRCFILE] — sets MUT_SRC, or returns 1 if the sed was a no-op
    local name; local prog; local src; local dst
    name="$1"; prog="$2"; src="${3:-${ASSERTIONS}}"; dst="${TMP}/mut-${name}.sh"
    MUT_SRC=""
    sed "${prog}" "${src}" > "${dst}"
    # VERIFY THE MUTATION ACTUALLY LANDED. A sed that matches nothing exits 0 and
    # writes a perfect copy, and the leg below would then "prove" the guard is
    # load-bearing while testing unmutated code. That is the vacuous pass, one level up.
    if cmp -s "${src}" "${dst}"; then
        _bad "mutation '${name}' was a NO-OP — the sed matched nothing, so its leg proves nothing"
        return 1
    fi
    _ok "mutation '${name}' really changed $(basename "${src}")"
    MUT_SRC="${dst}"
}
# mutant_out NAME SEDPROG ROOT WANT -> MUT_OUT, or empty if the mutation was a no-op
MUT_OUT=""
mutant_out() {
    MUT_OUT=""
    mutate "$1" "$2" || return 1
    build_lib "${MUT_SRC}" "${TMP}/lib-$1.sh"
    MUT_OUT="$(run_fixture "${TMP}/lib-$1.sh" "$3" "$4" "KEYS manifest")"
}

# (a) FLATTEN THE ROLE TABLE — every role gets the same headscale expectation, i.e. the
#     table now lists only what all roles share. This IS the original bug.
if mutant_out flat-table 's/^        backend|frontend)  _class=cluster; _hs_expect=forbidden ;;$/        backend|frontend)  _class=cluster; _hs_expect=required ;;/' \
        "${TMP}/swap-pki-as-frontend" true; then
    [ "$(fails_of "${MUT_OUT}")" = 0 ] \
        && _ok "(a) flattened table: the pki-as-frontend swap goes back to a CLEAN PASS => the role keying is what catches it" \
        || _ok "(a) flattened table still fails the swap, but on the residual cross-check only (n=$(fails_of "${MUT_OUT}")) — reported, not hidden"
    out="$(run_fixture "${TMP}/lib-flat-table.sh" "${TMP}/backend" false "KEYS manifest")"
    want_fail "${out}" "(a) flattened table also makes a CORRECT backend rootfs fail => mutation is caught" \
              "headscale MISSING from the default runlevel"
fi

# (a2) THE TRUEST FORM OF THE ORIGINAL BUG: silently invert the headscale service
#      assertions, KEEPING their message text. Only the cross-check survives to catch
#      the swap — reported rather than hidden, because it shows both catchers are needed.
if mutant_out no-headscale-keying 's/^            bad "role ${_role}: headscale/            ok "role ${_role}: headscale/' \
        "${TMP}/swap-pki-as-frontend" true; then
    no_fail "${MUT_OUT}" "(a2) headscale dropped from the role table: no headscale assertion FAILs any more" \
            "MUST NOT run a control server"
    [ "$(fails_of "${MUT_OUT}")" -ge 1 ] \
        && _ok "(a2) ...but the marker-vs-manifest cross-check still catches the swap (n=$(fails_of "${MUT_OUT}")) — two independent catchers, by design" \
        || _bad "(a2) SURVIVING MUTANT: with headscale out of the role table the swap passes clean"
fi

# (b) DROP THE NEGATIVE HALF of the headscale assertion, replacing it with a PASS that
#     also renames the message — the honest form of "we stopped grading this".
if mutant_out no-negative 's/^            bad "role ${_role}: headscale IS in the default runlevel but this role MUST NOT run a control server.*$/            ok "role ${_role}: headscale presence not graded on this role" ;#/' \
        "${TMP}/swap-pki-as-frontend" true; then
    no_fail "${MUT_OUT}" "(b) without the negative half a rogue headscale control server is no longer reported" \
            "MUST NOT run a control server"
fi

# (c) READ THE ROLE FROM THE ENVIRONMENT instead of the image. The harness knows which
#     role it ASKED for; if the section trusts that, it grades the request rather than
#     the artifact and a wrong-payload image passes forever.
if mutate role-from-env 's|^    _role="\$(sed -n .1p. "\${_R}/etc/hugmesh/role" 2>/dev/null \| tr -d .\[:space:\].)"$|    _role="${HUGMESH_ROLE:-x}"|'; then
    build_lib "${MUT_SRC}" "${TMP}/lib-env.sh"
    out="$(FIXTURE_ROOT="${TMP}/swap-pki-as-frontend" HUGMESH_ROLE=pki _hs_want=true _hs_src="KEYS manifest" \
           bash -c 'set -u; . "$1"' _ "${TMP}/lib-env.sh" 2>&1)"
    [ "$(fails_of "${out}")" = 0 ] \
        && _ok "(c) role-from-env: the swapped image PASSES cleanly => reading the env instead of the image restores the vacuous pass" \
        || _bad "(c) role-from-env did not mask the swap (n=$(fails_of "${out}")) — check the mutation actually replaced the read"
fi

# ── The six mutants that SURVIVED the first cut of this file. Each one deleted or
#    neutered a whole loop and left the suite green, because the only thing guarding
#    them was a \">= 1 failure\" count on a multi-fault fixture. They are legs now.
# (d) required-services loop silently inverted (17 assertions).
if mutant_out req-loop-inverted 's/^            bad "role ${_role}: ${_svc} MISSING from the default runlevel/            ok "role ${_role}: ${_svc} MISSING from the default runlevel/' \
        "${TMP}/miss-containerd" false; then
    [ "$(fails_of "${MUT_OUT}")" = 0 ] \
        && _ok "(d) required-services loop inverted => the containerd-less backend passes clean; the single-fault fixture in section 6(i) is what catches it" \
        || _bad "(d) SURVIVING MUTANT: inverted required loop still fails somewhere (n=$(fails_of "${MUT_OUT}"))"
fi
# (e) must-not-run loop silently inverted (3 assertions).
if mutant_out forbid-loop-inverted 's/^            bad "role ${_role}: ${_svc} is in the default runlevel but MUST NOT be/            ok "role ${_role}: ${_svc} is in the default runlevel but MUST NOT be/' \
        "${TMP}/rogue-dm" false; then
    [ "$(fails_of "${MUT_OUT}")" = 0 ] \
        && _ok "(e) must-not-run loop inverted => the display-manager-carrying k8s node passes clean; section 6(ii) is what catches it" \
        || _bad "(e) SURVIVING MUTANT: inverted forbid loop still fails somewhere (n=$(fails_of "${MUT_OUT}"))"
fi
# (f) agent-presence loop silently inverted (7 assertions).
if mutant_out agent-loop-inverted 's/^            bad "role ${_role}: ${_svc} init script NOT baked/            ok "role ${_role}: ${_svc} init script NOT baked/' \
        "${TMP}/no-agent" false; then
    [ "$(fails_of "${MUT_OUT}")" = 0 ] \
        && _ok "(f) agent-presence loop inverted => the agent-less rootfs passes clean; section 6(iii) is what catches it" \
        || _bad "(f) SURVIVING MUTANT: inverted agent loop still fails somewhere (n=$(fails_of "${MUT_OUT}"))"
fi
# (g) tailscaled bad() -> ok(), message kept.
if mutant_out tailscaled-inverted 's/^        bad "role ${_role}: \/usr\/sbin\/tailscaled is installed but tailscaled is MISSING/        ok "role ${_role}: \/usr\/sbin\/tailscaled is installed but tailscaled is MISSING/' \
        "${TMP}/unscheduled-tailscaled" false; then
    [ "$(fails_of "${MUT_OUT}")" = 0 ] \
        && _ok "(g) tailscaled assertion inverted => the unscheduled mesh client passes clean; section 7(b) is what catches it" \
        || _bad "(g) SURVIVING MUTANT: inverted tailscaled assertion still fails (n=$(fails_of "${MUT_OUT}"))"
fi
# (h) the standalone branch always taken => tailscaled always SKIPs.
if mutant_out standalone-always 's|^    if \[ -f "${_R}/etc/hugmesh/standalone" \]; then|    if true; then|' \
        "${TMP}/unscheduled-tailscaled" false; then
    has_skip "${MUT_OUT}" "STANDALONE image" \
        && _ok "(h) standalone branch forced true => tailscaled always SKIPs; section 7(b)'s named FAIL is what catches it" \
        || _bad "(h) mutation did not force the standalone skip"
    [ "$(fails_of "${MUT_OUT}")" = 0 ] \
        && _ok "(h) ...and the unscheduled mesh client then passes clean" \
        || _bad "(h) SURVIVING MUTANT: forced-standalone still fails (n=$(fails_of "${MUT_OUT}"))"
fi
# (i) half-activation bad() -> ok(), message kept — the mutant that fooled the first
#     cut's verdict-less `grep 'no convergence floor'`.
if mutant_out half-activation-inverted 's/^            bad "role ${_role}: ${_svc} is scheduled but \/etc\/cron.d/            ok "role ${_role}: ${_svc} is scheduled but \/etc\/cron.d/' \
        "${TMP}/half-activated" false; then
    has_pass "${MUT_OUT}" "no convergence floor" \
        && _ok "(i) half-activation inverted: the message still appears — on a PASS line (this is what fooled the first cut)" \
        || _bad "(i) mutation did not keep the message text"
    no_fail "${MUT_OUT}" "(i) ...and no FAIL carries it, which section 8's verdict-aware matcher now requires" \
            "no convergence floor"
fi
# (j) THE PREFIX-BLIND DANGLING CHECK — the reviewer's blocker. Restore the naive form
#     that resolves an ABSOLUTE target against the HOST's /etc/init.d.
if mutant_out dangling-prefix-blind 's|^        /\*)  \[ ! -e "\$1\${_t}" \] ;;.*$|        /*)  [ ! -e "${_l}" ] ;;|' \
        "${TMP}/backend" false; then
    has_fail "${MUT_OUT}" "dangling default-runlevel symlink" \
        && _ok "(j) prefix-blind dangling check => a CORRECT backend rootfs is graded dangling; section 1's no_fail leg is what catches it" \
        || _bad "(j) SURVIVING MUTANT: prefix-blind dangling check did not false-FAIL the correct rootfs"
fi
# (k) THE MESH-POSTURE SKIP REMOVED — the reviewer's --skip-tailscale false FAIL.
if mutant_out mesh-posture-blind 's|^    elif \[ ! -e "${_R}/usr/sbin/tailscaled" \]; then|    elif false; then|' \
        "${TMP}/no-mesh-client" false; then
    has_fail "${MUT_OUT}" "tailscaled is MISSING" \
        && _ok "(k) posture-blind: a legitimate --skip-tailscale image is graded a defect again; section 7(a) is what catches it" \
        || _bad "(k) SURVIVING MUTANT: removing the posture skip did not false-FAIL the mesh-less image"
fi
# (l) THE STALE KEYS PAYLOAD — restore run-qemu-test.sh's hardcoded enabled:true.
if mutate payload-hardcoded 's/"enabled": ${HS_ENABLED}/"enabled": true/' "${HERE}/run-qemu-test.sh"; then
    [ "$(payload_verdict "${MUT_SRC}")" = hardcoded-true ] \
        && _ok "(l) run-qemu-test.sh with a hardcoded enabled:true is classified 'hardcoded-true' => section 9 goes RED on it" \
        || _bad "(l) SURVIVING MUTANT: a hardcoded enabled:true payload is not classified as such"
fi
# (l2) ...and the comment-vs-code inversion the classifier must not fall for: a COMMENT
#      naming the derived spelling must not rescue a hardcoded payload line.
if mutate payload-comment-decoy \
        's|^  "headscale": { "enabled": ${HS_ENABLED}, "config_file": "headscale/config.yaml" },|  "headscale": { "enabled": true, "config_file": "headscale/config.yaml" },   # was: "enabled": ${HS_ENABLED}|' \
        "${HERE}/run-qemu-test.sh"; then
    [ "$(payload_verdict "${MUT_SRC}")" = hardcoded-true ] \
        && _ok "(l2) a comment naming \${HS_ENABLED} does NOT rescue a hardcoded payload (comments stripped before classifying)" \
        || _bad "(l2) SURVIVING MUTANT: the classifier was fooled by a comment"
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
