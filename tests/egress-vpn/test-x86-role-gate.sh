#!/usr/bin/env bash
# test-x86-role-gate.sh — unit test for the --egress-vpn ROLE gate in
# build-x86-host-stage4.sh.
#
# THE REGRESSION IT PINS: the builder warns "--egress-vpn given for a non-desktop
# role (${ROLE}); egress VPN is a desktop/tailnet-node feature — ignoring." and
# then stages nothing — but the PACKAGE leg used to fire on EGRESS_VPN_FILE
# ALONE, so a non-desktop role still emerged net-vpn/wireguard-tools (or
# networkmanager-openvpn + openvpn) it had just been told it would not use.
# "Ignoring" was only half true.
#
# Proves, WITHOUT a build (the REAL builder blocks are extracted and eval'd
# against a sandbox — the technique test-provision-vpn.sh uses for
# provision_vpn()):
#   * PACKAGE leg: ROLE_CLIENT + .conf  -> wireguard-tools;
#                  ROLE_CLIENT + .ovpn  -> networkmanager-openvpn + openvpn;
#                  NOT ROLE_CLIENT      -> NOTHING added, either extension;
#                  ROLE_CLIENT + no file-> nothing added.
#   * KERNEL leg: the CONFIG_WIREGUARD fragment only ever lands inside the
#     ROLE_CLIENT kernel arm (it always did — this pins it so the parity the
#     package fix just established cannot silently regress on either side).
#   * Studio agrees: the egress_vpn FieldScope is desktop-class only.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"
STUDIO_CFG="${REPO}/studio/hugmesh_studio/core/config.py"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing: ${BUILDER}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== build-x86-host-stage4.sh --egress-vpn role-gate unit test =="

# ── Extract the REAL PACKAGE block (comment anchor -> matching column-0 `fi`) ──
PKG_BLOCK="$(awk '/^# Egress VPN userspace:/{p=1} p{print} p&&/^fi$/{exit}' "${BUILDER}")"
[ -n "${PKG_BLOCK}" ] || { echo "  FAIL could not extract the egress-vpn PKGS block"; exit 1; }
case "${PKG_BLOCK}" in
    *'net-vpn/wireguard-tools'*) ok "extracted the real PKGS block from the builder" ;;
    *) bad "extracted block does not carry the VPN packages — anchor drifted"; exit 1 ;;
esac

run_pkgs() {  # $1 = ROLE_CLIENT (true|false) ; $2 = EGRESS_VPN_FILE
    ROLE_CLIENT="$1" EGRESS_VPN_FILE="$2" __BLOCK__="${PKG_BLOCK}" bash -c '
        set -uo pipefail
        PKGS="sys-apps/baselayout"
        eval "${__BLOCK__}"
        printf "%s\n" "${PKGS}"
    '
}

got="$(run_pkgs true /keys/vpn/wg0.conf)"
case "${got}" in
    *net-vpn/wireguard-tools*) ok "ROLE_CLIENT + .conf: net-vpn/wireguard-tools added" ;;
    *) bad "desktop role lost its wireguard-tools: ${got}" ;;
esac
got="$(run_pkgs true /keys/vpn/prov.ovpn)"
if [[ "${got}" == *net-vpn/networkmanager-openvpn* && "${got}" == *net-vpn/openvpn* ]]; then
    ok "ROLE_CLIENT + .ovpn: NM OpenVPN plugin + openvpn added"
else
    bad "desktop role lost its OpenVPN userspace: ${got}"
fi

# ── THE REGRESSION: a non-desktop role must emerge NOTHING ────────────────────
got="$(run_pkgs false /keys/vpn/wg0.conf)"
case "${got}" in
    *net-vpn/*) bad "NON-desktop role still emerged VPN userspace (.conf): ${got}" ;;
    *) ok "NOT ROLE_CLIENT + .conf: no VPN package added (matches the 'ignoring' warn)" ;;
esac
got="$(run_pkgs false /keys/vpn/prov.ovpn)"
case "${got}" in
    *net-vpn/*) bad "NON-desktop role still emerged VPN userspace (.ovpn): ${got}" ;;
    *) ok "NOT ROLE_CLIENT + .ovpn: no VPN package added (matches the 'ignoring' warn)" ;;
esac
got="$(run_pkgs true '')"
case "${got}" in
    *net-vpn/*) bad "no --egress-vpn given yet a VPN package was added: ${got}" ;;
    *) ok "ROLE_CLIENT + no --egress-vpn: no VPN package added" ;;
esac
got="$(run_pkgs false '')"
case "${got}" in
    *sys-apps/baselayout*) ok "unrelated packages are never touched by the gate" ;;
    *) bad "the gate mangled an unrelated package set: ${got}" ;;
esac

# ── Extract the REAL kernel ROLE_CLIENT arm (4-space-indented if ... fi) ──────
# The builder carries MORE THAN ONE 4-space `if ${ROLE_CLIENT}; then` block: since
# 06adabd7 (#224) bake_vault_conf() opens with one too, thousands of lines ABOVE
# the kernel arm. The old extractor took the FIRST match, silently graded
# bake_vault_conf's early-return instead, and went red with "anchor drifted" (#639).
# So: collect EVERY candidate block, keep the ones whose body appends the
# desktop kernel fragment (the kernel arm is the only place desktop.config is
# cat'd into k.config), and REFUSE unless exactly one qualifies. Never "the
# first" or "the last" match — either would silently start grading a different
# block the next time the builder grows one. (Nested ifs inside the arm close at
# 8 spaces, so a 4-space `fi` closes the arm itself.)
KERN_CANDS="${WORK}/kern-candidates"; mkdir -p "${KERN_CANDS}"
awk -v d="${KERN_CANDS}" '
    /^    if \$\{ROLE_CLIENT\}; then$/ { n++; f = sprintf("%s/%04d.blk", d, n); p = 1
                                        printf "%d\n", NR > (f ".line"); close(f ".line") }
    p { print > f }
    p && /^    fi$/ { p = 0; close(f); printf "closed\n" > (f ".closed"); close(f ".closed") }
' "${BUILDER}"
KERN_ALL=0; KERN_HITS=0; KERN_ARM=""; KERN_WHERE=""
for blk in "${KERN_CANDS}"/*.blk; do
    [ -e "${blk}" ] || continue
    KERN_ALL=$((KERN_ALL+1))
    # A candidate that never meets its 4-space `fi` ran to EOF: the builder's
    # indentation changed shape, and grading a block of unknown extent is a guess.
    [ -e "${blk}.closed" ] || { echo "  FAIL ROLE_CLIENT block at builder line $(cat "${blk}.line") never closes with a 4-space 'fi' — the arm's shape changed; re-read the builder"; exit 1; }
    if grep -F 'cat "${SPECS_DIR}/kernel/desktop.config" >> "${SYSROOT}/tmp/k.config"' "${blk}" >/dev/null; then
        KERN_HITS=$((KERN_HITS+1))
        KERN_ARM="$(cat "${blk}")"
        KERN_WHERE="${KERN_WHERE} :$(cat "${blk}.line")"
    fi
done
if [ "${KERN_HITS}" -ne 1 ]; then
    echo "  FAIL expected EXACTLY ONE 4-space 'if \${ROLE_CLIENT}; then' block that appends kernel/desktop.config;" \
         "found ${KERN_HITS} of ${KERN_ALL} candidate block(s) (at${KERN_WHERE:- none}) — refusing to guess which is the kernel arm"
    exit 1
fi
ok "kernel arm located unambiguously: 1 of ${KERN_ALL} ROLE_CLIENT block(s) appends desktop.config (builder line${KERN_WHERE})"
case "${KERN_ARM}" in
    *wireguard.config*) ok "extracted the real kernel arm (it carries the WireGuard fragment)" ;;
    *) bad "kernel arm extraction missed the WireGuard fragment — anchor drifted"; exit 1 ;;
esac

# Sandbox fragment files: each writes its own marker line into k.config.
mk_specs() {
    local d="${WORK}/specs/kernel"; rm -rf "${WORK}/specs" "${WORK}/sysroot"
    mkdir -p "${d}" "${WORK}/sysroot/tmp"
    printf 'MARK_DESKTOP\n'   > "${d}/desktop.config"
    printf 'MARK_WIREGUARD\n' > "${d}/wireguard.config"
    printf 'MARK_EINK\n'      > "${d}/eink.config"
}
run_kernel() {  # $1 = ROLE_CLIENT ; $2 = EGRESS_VPN_FILE
    mk_specs
    ROLE_CLIENT="$1" EGRESS_VPN_FILE="$2" SPECS_DIR="${WORK}/specs" \
    SYSROOT="${WORK}/sysroot" ROLE=desktop HOME_ENCRYPTED=false __ARM__="${KERN_ARM}" bash -c '
        set -uo pipefail
        info() { :; }
        eval "${__ARM__}"
    ' >/dev/null 2>&1
    cat "${WORK}/sysroot/tmp/k.config" 2>/dev/null || true
}

got="$(run_kernel true /keys/vpn/wg0.conf)"
case "${got}" in
    *MARK_WIREGUARD*) ok "ROLE_CLIENT + .conf: CONFIG_WIREGUARD fragment appended" ;;
    *) bad "desktop role lost the WireGuard kernel fragment" ;;
esac
got="$(run_kernel true /keys/vpn/prov.ovpn)"
if [[ "${got}" == *MARK_DESKTOP* && "${got}" != *MARK_WIREGUARD* ]]; then
    ok "ROLE_CLIENT + .ovpn: desktop fragment yes, WireGuard fragment no (OpenVPN is userspace)"
else
    bad "the .ovpn path got the WireGuard kernel fragment: ${got}"
fi
got="$(run_kernel false /keys/vpn/wg0.conf)"
case "${got}" in
    *MARK_WIREGUARD*) bad "NON-desktop role got the CONFIG_WIREGUARD fragment" ;;
    *) ok "NOT ROLE_CLIENT + .conf: no WireGuard kernel fragment (same gate as the packages)" ;;
esac

# ── The staging leg's warn is what the other two legs now match ───────────────
grep -Fq 'if ! ${ROLE_CLIENT} && [ -n "${EGRESS_VPN_FILE}" ]; then' "${BUILDER}" \
    && grep -Fq 'egress VPN is a desktop/tailnet-node feature — ignoring' "${BUILDER}" \
    && ok "staging leg still warns+ignores for a non-desktop role (the condition the others match)" \
    || bad "staging-leg warn drifted — the parity claim is unanchored"

# ── Studio's FieldScope must agree (desktop-class only) ───────────────────────
if [ -f "${STUDIO_CFG}" ]; then
    grep -Fq '"egress_vpn": FieldScope(platforms=_FIELD_PLATFORMS["egress_vpn"], classes=("desktop",))' "${STUDIO_CFG}" \
        && ok "Studio egress_vpn FieldScope is desktop-class only (consistent with the builder)" \
        || bad "Studio egress_vpn FieldScope no longer desktop-class only"
else
    echo "  SKIP Studio FieldScope assertion (config.py absent)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
