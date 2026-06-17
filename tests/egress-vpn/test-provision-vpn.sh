#!/usr/bin/env bash
# test-provision-vpn.sh — unit test for provision_vpn() in
# specs/etc/keys-provision/provision.sh (egress-VPN key-USB delivery, PR1).
#
# Proves, WITHOUT root (no real provisioning, no mounts):
#   * OWN-DOMAIN-ONLY: only KEYS/vpn/<own-domain>/ is read; a config staged under
#     ANOTHER tenant's domain is NEVER installed (per-domain isolation / cross-
#     tenant DENY).
#   * configs land in /etc/snapdragon/vpn/ mode 0600 root-owned.
#   * WireGuard .conf wins over .ovpn for active.conf; .ovpn becomes active only
#     when no .conf exists.
#   * FAIL-CLOSED / no-op: no own-domain dir, empty dir, or no domain at all ⇒
#     nothing installed (service default-off).
#   * .egress_vpn.domain overrides .snapdragon.cluster_domain.
#
# Technique: extract the provision_vpn() function body from the real script and
# source it with stubbed helpers (jqm/log/warn/BASE + an /etc redirect), so the
# REAL routing/scoping logic is exercised against a sandbox filesystem.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/specs/etc/keys-provision/provision.sh"
[ -f "${SRC}" ] || { echo "  FAIL provision.sh missing: ${SRC}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# Extract just `provision_vpn() { ... }` (matched brace at column 0).
extract_fn() {
    awk '/^provision_vpn\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}' "${SRC}"
}
FN="$(extract_fn)"
[ -n "${FN}" ] || { echo "  FAIL could not extract provision_vpn()"; exit 1; }

# Run provision_vpn() once in a sandbox. The function's only output side effect is
# under the hard-coded /etc/snapdragon/vpn path, so we sed-rewrite that single
# absolute path to point at the sandbox ${ETCROOT} and eval the REAL function body
# with stubbed helpers (log/warn/jqm). Args:
#   $1 = own domain returned for .snapdragon.cluster_domain
#   $2 = value returned for .egress_vpn.domain (empty => null)
export __FN__="${FN}"
run_vpn() {
    local cluster_dom="$1" egress_dom="$2"
    BASE="${BASE}" ETCROOT="${ETCROOT}" CLUSTER_DOM="${cluster_dom}" EGRESS_DOM="${egress_dom}" \
    bash -c '
        set -uo pipefail
        log()  { :; }
        warn() { :; }
        jqm() {
            case "$1" in
                *egress_vpn.domain*)         printf "%s\n" "${EGRESS_DOM:-null}" ;;
                *snapdragon.cluster_domain*) printf "%s\n" "${CLUSTER_DOM:-null}" ;;
                *) printf "\n" ;;
            esac
        }
        eval "$(printf "%s" "${__FN__}" | sed "s#/etc/snapdragon/vpn#${ETCROOT}/etc/snapdragon/vpn#g")"
        provision_vpn
    '
}

# ── Fresh sandbox per case ─────────────────────────────────────────────────────
new_sandbox() {
    WORK="$(mktemp -d)"; SANDBOXES+=("${WORK}")
    BASE="${WORK}/keys"; ETCROOT="${WORK}/root"
    mkdir -p "${BASE}" "${ETCROOT}"
}
SANDBOXES=()
cleanup(){ for d in "${SANDBOXES[@]:-}"; do rm -rf "${d}" 2>/dev/null; done; }
trap cleanup EXIT

VPN_ETC_REL="root/etc/snapdragon/vpn"

echo "== provision_vpn() unit test =="

# ── Case 1: own-domain configs installed, cross-tenant DENY ────────────────────
new_sandbox
mkdir -p "${BASE}/vpn/brandx" "${BASE}/vpn/brandy"
printf '[Interface]\nPrivateKey=SECRET_X\n[Peer]\nEndpoint=1.2.3.4:51820\n' > "${BASE}/vpn/brandx/proton-us.conf"
printf '[Interface]\nPrivateKey=SECRET_Y\n' > "${BASE}/vpn/brandy/proton-uk.conf"   # OTHER tenant
run_vpn "brandx" "" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ -f "${ED}/proton-us.conf" ] && ok "installs own-domain (brandx) config" || bad "own-domain config NOT installed"
[ ! -f "${ED}/proton-uk.conf" ] && ok "cross-tenant DENY: brandy config NOT installed on a brandx node" \
    || bad "LEAK: another tenant's config was installed"
# 0600 + active symlink
if [ -f "${ED}/proton-us.conf" ]; then
    mode="$(stat -c '%a' "${ED}/proton-us.conf" 2>/dev/null)"
    [ "${mode}" = "600" ] && ok "config installed mode 0600" || bad "config mode ${mode} != 600"
    [ -L "${ED}/active.conf" ] && [ "$(readlink "${ED}/active.conf")" = "${ED}/proton-us.conf" ] \
        && ok "active.conf -> the WireGuard config" || bad "active.conf not pointed at the config"
    # Secret content preserved.
    grep -q 'SECRET_X' "${ED}/proton-us.conf" && ok "config content preserved verbatim" || bad "config content corrupted"
fi

# ── Case 2: .egress_vpn.domain OVERRIDES cluster_domain ────────────────────────
new_sandbox
mkdir -p "${BASE}/vpn/override-dom" "${BASE}/vpn/brandx"
printf '[Interface]\nPrivateKey=OVR\n' > "${BASE}/vpn/override-dom/o.conf"
printf '[Interface]\nPrivateKey=NO\n'  > "${BASE}/vpn/brandx/x.conf"
run_vpn "brandx" "override-dom" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ -f "${ED}/o.conf" ] && [ ! -f "${ED}/x.conf" ] \
    && ok ".egress_vpn.domain overrides .snapdragon.cluster_domain" \
    || bad "override domain not honoured"

# ── Case 3: WireGuard .conf wins over .ovpn for active.conf ────────────────────
new_sandbox
mkdir -p "${BASE}/vpn/brandx"
printf 'remote 9.9.9.9 1194\n' > "${BASE}/vpn/brandx/legacy.ovpn"
printf '[Interface]\nPrivateKey=WG\n' > "${BASE}/vpn/brandx/wg.conf"
run_vpn "brandx" "" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ -f "${ED}/wg.conf" ] && [ -f "${ED}/legacy.ovpn" ] && ok "both .conf and .ovpn installed" || bad "missing config(s)"
[ -L "${ED}/active.conf" ] && [ "$(readlink "${ED}/active.conf")" = "${ED}/wg.conf" ] \
    && ok "WireGuard .conf wins active.conf over .ovpn" || bad "active.conf not the WireGuard config"
mode="$(stat -c '%a' "${ED}/legacy.ovpn" 2>/dev/null)"
[ "${mode}" = "600" ] && ok ".ovpn installed mode 0600" || bad ".ovpn mode ${mode} != 600"

# ── Case 4: .ovpn-only becomes active when no .conf ────────────────────────────
new_sandbox
mkdir -p "${BASE}/vpn/brandx"
printf 'remote 9.9.9.9 1194\n' > "${BASE}/vpn/brandx/only.ovpn"
run_vpn "brandx" "" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ -L "${ED}/active.conf" ] && [ "$(readlink "${ED}/active.conf")" = "${ED}/only.ovpn" ] \
    && ok "active.conf falls back to the .ovpn when no .conf" || bad "ovpn-only active.conf wrong"

# ── Case 5: no own-domain dir ⇒ NOTHING installed (fail-closed no-op) ──────────
new_sandbox
mkdir -p "${BASE}/vpn/someoneelse"
printf '[Interface]\n' > "${BASE}/vpn/someoneelse/x.conf"
run_vpn "brandx" "" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ ! -d "${ED}" ] || [ -z "$(ls -A "${ED}" 2>/dev/null)" ] \
    && ok "no own-domain dir ⇒ nothing installed (service stays off)" \
    || bad "installed configs despite no own-domain dir"

# ── Case 6: empty own-domain dir ⇒ NOTHING installed ───────────────────────────
new_sandbox
mkdir -p "${BASE}/vpn/brandx"
run_vpn "brandx" "" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ ! -e "${ED}/active.conf" ] && ok "empty own-domain dir ⇒ no active.conf (service stays off)" \
    || bad "active.conf created from an empty dir"

# ── Case 7: no domain at all ⇒ no-op ───────────────────────────────────────────
new_sandbox
mkdir -p "${BASE}/vpn/brandx"
printf '[Interface]\n' > "${BASE}/vpn/brandx/x.conf"
run_vpn "" "" >/dev/null 2>&1
ED="${WORK}/${VPN_ETC_REL}"
[ ! -d "${ED}" ] || [ -z "$(ls -A "${ED}" 2>/dev/null)" ] \
    && ok "no node domain ⇒ no-op (nothing installed)" || bad "installed configs with no domain"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
