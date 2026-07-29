#!/usr/bin/env bash
# test-provision-update.sh — unit test for provision_update() in
# specs/etc/keys-provision/provision.sh (OPT-IN / default-off host-binary auto-update).
#
# Proves, WITHOUT root (no real provisioning, no emerge, no cluster):
#   * PLUMBING ALWAYS BAKED: NO .update block in the manifest => the
#     /etc/cron.d/hugmesh-update drop-in is STILL written ACTIVE (plumbing, so a
#     later opt-in fires), with the baked default cadence, and
#     /etc/hugmesh/update.json records the explicit default-OFF policy (enabled:false).
#   * ADJUST: .update.cadence rewrites the cron schedule; .update.window/reboot land
#     in update.json.
#   * STAGING: a per-role / per-board .update.staging key overrides the cadence
#     (most-specific wins: board > role > client).
#   * NO DISABLE BRANCH: .update.enabled=false STILL bakes the cron plumbing (the
#     poller is the runtime gate); update.json just records enabled:false. Withholding
#     the cron would also make runtime opt-in via the ConfigMap impossible.
#   * SELF-SUFFICIENT FALLBACK: if the poller binary is NOT baked, the plumbing is NOT
#     silently dropped — the cron is STAGED at /etc/hugmesh/cron-update.staged.
#
# Technique: extract provision_update() from the real script, sed-rewrite its
# hard-coded absolute paths to a sandbox root, and run it with stubbed helpers
# (jqm/jqe/jq driven by a real manifest file) so the REAL opt-in logic runs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/specs/etc/keys-provision/provision.sh"
[ -f "${SRC}" ] || { echo "  FAIL provision.sh missing: ${SRC}"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  SKIP jq not installed"; exit 0; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

FN="$(awk '/^provision_update\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}' "${SRC}")"
[ -n "${FN}" ] || { echo "  FAIL could not extract provision_update()"; exit 1; }
export __FN__="${FN}"

SANDBOXES=()
cleanup(){ for d in "${SANDBOXES[@]:-}"; do rm -rf "${d}" 2>/dev/null; done; }
trap cleanup EXIT

# Run provision_update() once in a sandbox ROOT. Args:
#   $1 manifest JSON ('' => no .update block at all, i.e. the bare default-off case)
#   $2 role marker   (written to <root>/etc/hugmesh/role)
#   $3 board marker  (written to <root>/etc/hugmesh/board; '' => none)
#   $4 bake_poller   ('yes' => create an executable poller stub so the [-x] check passes)
run_update() {
    local manifest="$1" role="$2" board="$3" bake="$4"
    local W; W="$(mktemp -d)"; SANDBOXES+=("${W}")
    local ROOT="${W}/root"; mkdir -p "${ROOT}/etc/hugmesh"
    [ -n "${role}"  ] && printf '%s' "${role}"  > "${ROOT}/etc/hugmesh/role"
    [ -n "${board}" ] && printf '%s' "${board}" > "${ROOT}/etc/hugmesh/board"
    if [ "${bake}" = "yes" ]; then
        mkdir -p "${ROOT}/usr/local/sbin"
        printf '#!/bin/sh\n:\n' > "${ROOT}/usr/local/sbin/hugmesh-update"
        chmod +x "${ROOT}/usr/local/sbin/hugmesh-update"
    fi
    local MAN="${W}/provision.json"
    if [ -n "${manifest}" ]; then printf '%s' "${manifest}" > "${MAN}"; else echo '{}' > "${MAN}"; fi

    # Rewrite the function's hard-coded absolute paths to the sandbox root, then run
    # it with jqm/jqe backed by the manifest file (the REAL routing/default logic).
    # __FN__ is referenced (not interpolated) inside the single-quoted script so its
    # own parens/quotes never reach the outer command line (cf. test-provision-vpn.sh).
    ROOT="${ROOT}" MAN="${MAN}" bash -c '
        set -uo pipefail
        log()  { :; }
        warn() { :; }
        MANIFEST="${MAN}"
        jqm() { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
        jqe() { jq -e "$1" "${MANIFEST}" >/dev/null 2>&1; }
        body="${__FN__}"
        body="${body//\/etc\/cron.d/${ROOT}\/etc\/cron.d}"
        body="${body//\/etc\/hugmesh/${ROOT}\/etc\/hugmesh}"
        body="${body//\/usr\/local\/sbin\/hugmesh-update/${ROOT}\/usr\/local\/sbin\/hugmesh-update}"
        eval "${body}"
        provision_update
    '
    echo "${ROOT}"   # return the sandbox root so the caller can assert files
}

echo "== provision_update() opt-in (default-off) unit test =="

# ── (1) PLUMBING: no .update block => cron written ACTIVE (plumbing) + update.json OFF ─
ROOT="$(run_update '{}' 'be' '' yes)"
CRON="${ROOT}/etc/cron.d/hugmesh-update"
if [ -f "${CRON}" ]; then ok "no .update block => cron drop-in written ACTIVE (plumbing)"; else bad "plumbing cron drop-in NOT written"; fi
grep -q '/usr/local/sbin/hugmesh-update' "${CRON}" 2>/dev/null && ok "plumbing cron invokes the poller" || bad "cron does not invoke the poller"
grep -qE '^0 4 \* \* \* root ' "${CRON}" 2>/dev/null && ok "plumbing cron uses the baked default cadence (0 4 * * *)" || bad "default cadence wrong"
UJ="${ROOT}/etc/hugmesh/update.json"
[ -f "${UJ}" ] && jq -e '.enabled == false' "${UJ}" >/dev/null 2>&1 && ok "update.json records enabled:false (self-documenting default-OFF)" || bad "update.json not default-off"

# ── (2) ADJUST: cadence + window + reboot from the manifest ───────────────────────
ROOT="$(run_update '{"update":{"cadence":"15 2 * * *","window":"01:00-05:00","reboot":"never"}}' 'fe' '' yes)"
CRON="${ROOT}/etc/cron.d/hugmesh-update"; UJ="${ROOT}/etc/hugmesh/update.json"
grep -qE '^15 2 \* \* \* root ' "${CRON}" 2>/dev/null && ok "ADJUST: cron cadence rewritten from .update.cadence" || bad "cadence not applied"
jq -e '.window == "01:00-05:00" and .reboot == "never"' "${UJ}" >/dev/null 2>&1 && ok "ADJUST: window+reboot persisted to update.json" || bad "window/reboot not persisted"

# ── (3) STAGING: per-role override; board beats role ─────────────────────────────
ROOT="$(run_update '{"update":{"cadence":"0 4 * * *","staging":{"pki":"30 3 * * *"}}}' 'pki' '' yes)"
grep -qE '^30 3 \* \* \* root ' "${ROOT}/etc/cron.d/hugmesh-update" 2>/dev/null \
    && ok "STAGING: per-role cadence overrides the base cadence" || bad "per-role staging not applied"
ROOT="$(run_update '{"update":{"cadence":"0 4 * * *","staging":{"frite:rpi5":"7 7 * * *","client":"0 5 * * 6"}}}' 'fe' 'frite:rpi5' yes)"
grep -qE '^7 7 \* \* \* root ' "${ROOT}/etc/cron.d/hugmesh-update" 2>/dev/null \
    && ok "STAGING: board tag is more specific than role/client (board wins)" || bad "board staging precedence wrong"

# ── (4) NO DISABLE BRANCH: enabled:false STILL bakes the cron plumbing; update.json OFF ─
ROOT="$(run_update '{"update":{"enabled":false}}' 'be' '' yes)"
[ -f "${ROOT}/etc/cron.d/hugmesh-update" ] && ok "enabled:false => cron plumbing STILL written (the poller gates at runtime, not provisioning)" || bad "enabled:false wrongly withheld the cron plumbing"
jq -e '.enabled == false' "${ROOT}/etc/hugmesh/update.json" >/dev/null 2>&1 && ok "enabled:false => update.json records enabled:false" || bad "update.json not enabled:false"

# enabled:true at provision time => a baked-in opt-in: cron plumbing + update.json ON.
ROOT="$(run_update '{"update":{"enabled":true}}' 'be' '' yes)"
[ -f "${ROOT}/etc/cron.d/hugmesh-update" ] && ok "enabled:true => cron plumbing written" || bad "enabled:true did not write the cron"
jq -e '.enabled == true' "${ROOT}/etc/hugmesh/update.json" >/dev/null 2>&1 && ok "enabled:true => update.json records the baked-in opt-in" || bad "update.json not enabled:true"

# ── (5) FALLBACK: poller NOT baked => plumbing STAGED, NOT silently dropped ───────
ROOT="$(run_update '{}' 'be' '' no)"
[ -f "${ROOT}/etc/cron.d/hugmesh-update" ] && bad "wrote an active cron with no poller present" || ok "FALLBACK: no active cron when poller absent (cannot run a missing binary)"
[ -f "${ROOT}/etc/hugmesh/cron-update.staged" ] && ok "FALLBACK: cron plumbing STAGED (not silently dropped)" || bad "cron plumbing NOT staged when poller absent"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
