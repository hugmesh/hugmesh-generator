#!/usr/bin/env bash
# test-update-poller.sh — unit test for the hugmesh-update poller
# (specs/usr/local/sbin/hugmesh-update), the OPT-IN (default-off) binpkg
# auto-update agent.
#
# Proves, WITHOUT root / real emerge / real cluster (the poller exposes test seams
# SU_EMERGE / SU_KUBECTL / SU_DATE and path overrides via env):
#   * OPT-IN PULL: a reachable ConfigMap with enabled:true => the poller pulls,
#     DELTA-ONLY: --getbinpkgonly --usepkgonly (binary only) + --update --deep @world.
#   * DEFAULT-OFF ON ABSENCE (fail-safe-to-off): no kubeconfig (worker/client) OR an
#     unreachable cluster OR an absent ConfigMap => the poller SKIPS the pull.
#   * EXPLICIT DISABLE: a reachable ConfigMap with enabled:false => the poller SKIPS
#     (and a literal `false` is honoured — not collapsed by jq `//`).
#   * WINDOW GATE (when enabled): outside .window the poller skips; inside it pulls.
#   * KURED SAFE REBOOT (when enabled): reboot:always drops the /var/run/reboot-required
#     sentinel; reboot:never never does.
#   * NO BINHOST (when enabled) => no-op (nothing to pull, exit 0, no emerge).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLLER="${REPO}/specs/usr/local/sbin/hugmesh-update"
[ -f "${POLLER}" ] || { echo "  FAIL poller missing: ${POLLER}"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  SKIP jq not installed"; exit 0; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
SANDBOXES=()
cleanup(){ for d in "${SANDBOXES[@]:-}"; do rm -rf "${d}" 2>/dev/null; done; }
trap cleanup EXIT

# Build a sandbox with: a make.conf carrying PORTAGE_BINHOST (unless $nohost),
# fake emerge (records its argv to <root>/emerge.argv and exits 0), fake kubectl
# (emits $cm_json for the policy ConfigMap, or fails if $cm_json is the literal
# UNREACHABLE), a kubeconfig iff $have_kube, and a fixed clock $now (HH:MM).
make_sandbox() {  # make_sandbox <have_kube y/n> <cm_json|UNREACHABLE|NONE> <now HH:MM> <nohost y/n>
    local have_kube="$1" cm="$2" now="$3" nohost="$4"
    local W; W="$(mktemp -d)"; SANDBOXES+=("${W}")
    local ROOT="${W}/root"; mkdir -p "${ROOT}/etc/portage" "${ROOT}/etc/kubernetes" "${ROOT}/var/run" "${ROOT}/bin"

    if [ "${nohost}" != "y" ]; then
        printf 'PORTAGE_BINHOST="http://10.0.0.30:8086/amd64"\nFEATURES="${FEATURES} getbinpkg"\n' \
            > "${ROOT}/etc/portage/make.conf"
    else
        printf 'USE="-X"\n' > "${ROOT}/etc/portage/make.conf"
    fi

    # fake emerge: record argv, exit 0.
    cat > "${ROOT}/bin/emerge" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "${ROOT}/emerge.argv"
exit 0
EOF
    chmod +x "${ROOT}/bin/emerge"

    # fake kubectl: ignore args, emit the ConfigMap policy.json (or fail => unreachable).
    if [ "${cm}" = "UNREACHABLE" ] || [ "${cm}" = "NONE" ]; then
        cat > "${ROOT}/bin/kubectl" <<EOF
#!/bin/sh
exit 1
EOF
    else
        # The poller asks for jsonpath {.data.policy\.json}; just print the JSON.
        printf '%s' "${cm}" > "${ROOT}/cm.json"
        cat > "${ROOT}/bin/kubectl" <<EOF
#!/bin/sh
cat "${ROOT}/cm.json"
EOF
    fi
    chmod +x "${ROOT}/bin/kubectl"

    [ "${have_kube}" = "y" ] && printf 'fake-kubeconfig\n' > "${ROOT}/etc/kubernetes/admin.conf"

    # fake date wrapper: -u timestamps for logs pass through; +%H:%M returns $now.
    cat > "${ROOT}/bin/date" <<EOF
#!/bin/sh
case "\$*" in
  *"+%H:%M"*) printf '%s\n' "${now}" ;;
  *) /bin/date "\$@" ;;
esac
EOF
    chmod +x "${ROOT}/bin/date"

    echo "${ROOT}"
}

run_poller() {  # run_poller <root>  -> runs the REAL poller against the sandbox
    local ROOT="$1"
    HUGMESH_UPDATE_CONF="${ROOT}/etc/hugmesh/update.json" \
    HUGMESH_MAKE_CONF="${ROOT}/etc/portage/make.conf" \
    HUGMESH_KUBECONFIG="${ROOT}/etc/kubernetes/admin.conf" \
    HUGMESH_REBOOT_SENTINEL="${ROOT}/var/run/reboot-required" \
    HUGMESH_UPDATE_STATE="${ROOT}/var/lib/hugmesh/update" \
    SU_EMERGE="${ROOT}/bin/emerge" \
    SU_KUBECTL="${ROOT}/bin/kubectl" \
    SU_DATE="${ROOT}/bin/date" \
    SU_EMERGE_LOG="${ROOT}/emerge.log" \
        bash "${POLLER}" >> "${ROOT}/run.log" 2>&1 || true
    # The poller appends its own emerge log to /var/log/...; the recorded argv is the
    # source of truth for "did it pull, and with which flags".
}
pulled() { [ -f "$1/emerge.argv" ]; }

echo "== hugmesh-update poller unit test =="

# ── (1) OPT-IN: reachable ConfigMap enabled:true => pulls, delta-only flags ───────
ROOT="$(make_sandbox y '{"enabled":true}' 03:00 n)"
run_poller "${ROOT}"
if pulled "${ROOT}"; then ok "reachable enabled:true => poller pulls (opt-in)"; else bad "opt-in enabled:true did not pull"; fi
ARGV="$(cat "${ROOT}/emerge.argv" 2>/dev/null || echo '')"
case "${ARGV}" in *--getbinpkgonly*--usepkgonly*|*--usepkgonly*--getbinpkgonly*) ok "DELTA-ONLY: emerge uses --getbinpkgonly + --usepkgonly (binary only)";; *) bad "emerge missing binary-only flags: ${ARGV}";; esac
case "${ARGV}" in *--update*--deep*@world*) ok "DELTA: emerge resolves the changed set (--update --deep @world)";; *) bad "emerge missing --update --deep @world: ${ARGV}";; esac

# ── (2) DEFAULT-OFF: no kubeconfig (worker/client) => SKIPS (fail-safe-to-off) ─────
ROOT="$(make_sandbox n NONE 03:00 n)"
run_poller "${ROOT}"
pulled "${ROOT}" && bad "no kubeconfig wrongly pulled (must be default-off)" || ok "no kubeconfig => poller SKIPS (default-off, fail-safe-to-off)"

# ── (3) DEFAULT-OFF: control node, cluster UNREACHABLE => SKIPS ───────────────────
ROOT="$(make_sandbox y UNREACHABLE 03:00 n)"
run_poller "${ROOT}"
pulled "${ROOT}" && bad "unreachable cluster wrongly pulled" || ok "control node + UNREACHABLE cluster => poller SKIPS (fail-safe-to-off)"

# ── (4) DEFAULT-OFF: control node, ConfigMap absent (kubectl ok but no CM) ────────
# (kubectl prints empty => no JSON object => keep the baked default, which is OFF.)
ROOT="$(make_sandbox y '' 03:00 n)"
run_poller "${ROOT}"
pulled "${ROOT}" && bad "absent ConfigMap wrongly pulled" || ok "control node + absent ConfigMap => poller SKIPS (default-off)"

# ── (5) EXPLICIT DISABLE: reachable ConfigMap enabled:false => SKIP (false honoured) ─
ROOT="$(make_sandbox y '{"enabled":false}' 03:00 n)"
run_poller "${ROOT}"
pulled "${ROOT}" && bad "enabled:false did NOT suppress the pull (jq // false bug?)" || ok "DISABLE: reachable enabled:false => poller SKIPS the pull"
grep -q 'not enabled' "${ROOT}/run.log" 2>/dev/null && ok "OFF: poller logs the opt-in/skip reason" || bad "no skip log line"

# ── (6) WINDOW GATE (enabled): outside the window => skip; inside => pull ──────────
ROOT="$(make_sandbox y '{"enabled":true,"window":"02:00-06:00"}' 09:00 n)"   # 09:00 is outside
run_poller "${ROOT}"
pulled "${ROOT}" && bad "pulled outside the maintenance window" || ok "WINDOW: enabled + outside window => poller skips"
ROOT="$(make_sandbox y '{"enabled":true,"window":"02:00-06:00"}' 03:30 n)"   # 03:30 is inside
run_poller "${ROOT}"
pulled "${ROOT}" && ok "WINDOW: enabled + inside window => poller pulls" || bad "did not pull inside the window"

# ── (7) KURED SAFE REBOOT (enabled): reboot:always drops the sentinel; never does not ─
ROOT="$(make_sandbox y '{"enabled":true,"reboot":"always"}' 03:00 n)"
run_poller "${ROOT}"
[ -f "${ROOT}/var/run/reboot-required" ] && ok "REBOOT always => kured sentinel /var/run/reboot-required dropped" || bad "reboot:always did not drop the sentinel"
ROOT="$(make_sandbox y '{"enabled":true,"reboot":"never"}' 03:00 n)"
run_poller "${ROOT}"
[ -f "${ROOT}/var/run/reboot-required" ] && bad "reboot:never dropped the sentinel" || ok "REBOOT never => no sentinel (running kernel kept)"

# ── (8) NO BINHOST (enabled) => no-op (nothing to pull) ───────────────────────────
ROOT="$(make_sandbox y '{"enabled":true}' 03:00 y)"
run_poller "${ROOT}"
pulled "${ROOT}" && bad "pulled with no PORTAGE_BINHOST configured" || ok "NO BINHOST => no-op (nothing pulled)"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
