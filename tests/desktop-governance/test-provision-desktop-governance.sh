#!/usr/bin/env bash
# test-provision-desktop-governance.sh — unit test for
# provision_desktop_governance() in specs/etc/keys-provision/provision.sh
# (desktop client-image governance: Discover->BFF registry remote, SSO-claim
# sudo gate, empty-default / ships-dark).
#
# Proves, WITHOUT root (no real provisioning, no mounts, no flatpak/sssd needed):
#   * Discover Flatpak remote is rendered at api.<domain>/bff/desktop/registry/
#     with the domain SUBSTITUTED from the node's domain (NOT hardcoded).
#   * Flathub-off list drives removal of preset flathub*.flatpakrepo files.
#   * polkit desktop-sudo gate is installed verbatim (no static sudoers entry;
#     a stock %wheel line is commented out).
#   * SSSD-OIDC conf is rendered with the per-domain id.<domain> issuer + the
#     desktop-sudo claim->group mapping, mode 0600.
#   * bearer-forward.sh is rendered (mode 0755) pointed at api.<domain>.
#   * DOMAIN PRECEDENCE: /etc/snapdragon/domains first line beats
#     .snapdragon.cluster_domain; .client.primary_domain beats both.
#   * SHIPS-DARK / no-op: no baked templates dir => nothing rendered (not error);
#     templates baked but NO domain => nothing rendered, no sudo granted.
#
# Technique (mirrors tests/egress-vpn/test-provision-vpn.sh): extract the
# provision_desktop_governance() function body from the real script, sed-rewrite
# every hard-coded absolute system path to a sandbox root, and eval it with
# stubbed helpers (jqm/log/warn/have) against a sandbox filesystem.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/specs/etc/keys-provision/provision.sh"
TPL_SRC="${REPO}/specs/etc/snapdragon/desktop-governance"
[ -f "${SRC}" ] || { echo "  FAIL provision.sh missing: ${SRC}"; exit 1; }
[ -d "${TPL_SRC}" ] || { echo "  FAIL templates missing: ${TPL_SRC}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# Extract just `provision_desktop_governance() { ... }` (matched brace at col 0).
extract_fn() {
    awk '/^provision_desktop_governance\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}' "${SRC}"
}
FN="$(extract_fn)"
[ -n "${FN}" ] || { echo "  FAIL could not extract provision_desktop_governance()"; exit 1; }
export __FN__="${FN}"

SANDBOXES=()
cleanup(){ for d in "${SANDBOXES[@]:-}"; do rm -rf "${d}" 2>/dev/null; done; }
trap cleanup EXIT

# Fresh sandbox: ETCROOT stands in for / (so /etc/... -> ${ETCROOT}/etc/...).
# BASE stands in for the mounted KEYS USB.
#   $1 = with-templates | no-templates | keys-templates
#        with-templates : baked at /etc/snapdragon/desktop-governance
#        keys-templates : only on the KEYS USB (KEYS/desktop-governance/)
#        no-templates   : neither
new_sandbox() {
    WORK="$(mktemp -d)"; SANDBOXES+=("${WORK}")
    ETCROOT="${WORK}/root"; BASE="${WORK}/keys"
    mkdir -p "${ETCROOT}/etc/snapdragon" "${BASE}"
    case "${1:-with-templates}" in
        with-templates) cp -r "${TPL_SRC}" "${ETCROOT}/etc/snapdragon/desktop-governance" ;;
        keys-templates) cp -r "${TPL_SRC}" "${BASE}/desktop-governance" ;;
        no-templates)   : ;;
    esac
}

# Run provision_desktop_governance() in the sandbox.
#   $1 = value for .client.primary_domain (empty => null)
#   $2 = value for .snapdragon.cluster_domain (empty => null)
#   $3 = first line to write into /etc/snapdragon/domains (empty => no file)
run_gov() {
    local pdom="$1" cdom="$2" domfile="$3"
    [ -n "${domfile}" ] && printf '%s\n' "${domfile}" > "${ETCROOT}/etc/snapdragon/domains"
    ETCROOT="${ETCROOT}" BASE="${BASE}" PDOM="${pdom}" CDOM="${cdom}" \
    bash -c '
        set -uo pipefail
        log()  { :; }
        warn() { :; }
        have() { return 1; }   # pretend flatpak is NOT installed (preset path)
        jqm() {
            case "$1" in
                *client.primary_domain*)     printf "%s\n" "${PDOM:-null}" ;;
                *snapdragon.cluster_domain*) printf "%s\n" "${CDOM:-null}" ;;
                *) printf "\n" ;;
            esac
        }
        # Redirect every absolute system path the function writes to into ETCROOT.
        body="$(printf "%s" "${__FN__}" \
            | sed -e "s#/etc/snapdragon/desktop-governance#${ETCROOT}/etc/snapdragon/desktop-governance#g" \
                  -e "s#/etc/snapdragon/domains#${ETCROOT}/etc/snapdragon/domains#g" \
                  -e "s#/etc/flatpak#${ETCROOT}/etc/flatpak#g" \
                  -e "s#/etc/polkit-1#${ETCROOT}/etc/polkit-1#g" \
                  -e "s#/etc/sssd#${ETCROOT}/etc/sssd#g" \
                  -e "s#/etc/sudoers#${ETCROOT}/etc/sudoers#g")"
        eval "${body}"
        provision_desktop_governance
    '
}

echo "== provision_desktop_governance() unit test =="

# ── Case 1: full render, domain from /etc/snapdragon/domains ───────────────────
new_sandbox with-templates
run_gov "" "" "acme.example" >/dev/null 2>&1
E="${ETCROOT}/etc"
REPO_F="${E}/flatpak/remotes.d/snapdragon-discover.flatpakrepo"
if [ -f "${REPO_F}" ]; then
    grep -q 'Url=https://api.acme.example/bff/desktop/registry/' "${REPO_F}" \
        && ok "Discover remote -> api.<domain>/bff/desktop/registry/ (domain substituted)" \
        || bad "Discover remote URL wrong: $(grep -m1 '^Url=' "${REPO_F}")"
    ! grep -q '@@CLUSTER_DOMAIN@@' "${REPO_F}" \
        && ok "no @@CLUSTER_DOMAIN@@ placeholder left in rendered remote" \
        || bad "placeholder NOT substituted in remote"
else
    bad "Discover .flatpakrepo not rendered"
fi
POLKIT="${E}/polkit-1/rules.d/49-snapdragon-desktop-sudo.rules"
[ -f "${POLKIT}" ] && grep -q 'unix-group:desktop-sudo' "${POLKIT}" \
    && ok "polkit desktop-sudo gate installed" || bad "polkit gate missing/wrong"
SSSD="${E}/sssd/conf.d/snapdragon-oidc.conf"
if [ -f "${SSSD}" ]; then
    grep -q 'oidc_issuer = https://id.acme.example/' "${SSSD}" \
        && ok "SSSD-OIDC issuer -> id.<domain> (domain substituted)" \
        || bad "SSSD issuer wrong: $(grep -m1 'oidc_issuer' "${SSSD}")"
    grep -q 'desktop-sudo' "${SSSD}" \
        && ok "SSSD maps the desktop-sudo claim->group" || bad "SSSD desktop-sudo mapping missing"
    mode="$(stat -c '%a' "${SSSD}" 2>/dev/null)"
    [ "${mode}" = "600" ] && ok "SSSD conf mode 0600" || bad "SSSD conf mode ${mode} != 600"
else
    bad "SSSD-OIDC conf not rendered"
fi
BF="${E}/snapdragon/desktop-governance/bearer-forward.sh"
if [ -f "${BF}" ]; then
    grep -q 'api.acme.example' "${BF}" && ok "bearer-forward points at api.<domain>" || bad "bearer-forward host wrong"
    mode="$(stat -c '%a' "${BF}" 2>/dev/null)"
    [ "${mode}" = "755" ] && ok "bearer-forward mode 0755" || bad "bearer-forward mode ${mode} != 755"
else
    bad "bearer-forward.sh not rendered"
fi

# ── Case 2: Flathub-off removes a preset flathub.flatpakrepo ───────────────────
new_sandbox with-templates
mkdir -p "${ETCROOT}/etc/flatpak/remotes.d"
printf '[Flatpak Repo]\nTitle=Flathub\n' > "${ETCROOT}/etc/flatpak/remotes.d/flathub.flatpakrepo"
run_gov "" "" "acme.example" >/dev/null 2>&1
[ ! -f "${ETCROOT}/etc/flatpak/remotes.d/flathub.flatpakrepo" ] \
    && ok "Flathub-off removes the preset flathub.flatpakrepo" \
    || bad "preset flathub.flatpakrepo NOT removed"
[ -f "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" ] \
    && ok "our snapdragon-discover remote survives Flathub-off" || bad "our remote was removed"

# ── Case 3: no static sudoers — stock %wheel line commented out ────────────────
new_sandbox with-templates
mkdir -p "${ETCROOT}/etc"
printf 'root ALL=(ALL) ALL\n%%wheel ALL=(ALL) ALL\n' > "${ETCROOT}/etc/sudoers"
run_gov "" "" "acme.example" >/dev/null 2>&1
if grep -Eq '^%wheel[[:space:]]+ALL=\(ALL\)[[:space:]]+ALL' "${ETCROOT}/etc/sudoers"; then
    bad "stock %wheel sudoers line still active (standing sudo)"
else
    ok "stock %wheel sudoers line commented out (no static sudo)"
fi

# ── Case 4: .client.primary_domain beats domains-file and cluster_domain ───────
new_sandbox with-templates
run_gov "primary.example" "cluster.example" "domainsfile.example" >/dev/null 2>&1
grep -q 'api.primary.example' "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" \
    && ok ".client.primary_domain wins precedence" || bad "primary_domain precedence wrong"

# ── Case 5: domains-file beats cluster_domain ──────────────────────────────────
new_sandbox with-templates
run_gov "" "cluster.example" "domainsfile.example" >/dev/null 2>&1
grep -q 'api.domainsfile.example' "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" \
    && ok "/etc/snapdragon/domains first line beats .snapdragon.cluster_domain" \
    || bad "domains-file precedence wrong"

# ── Case 6: cluster_domain fallback when no primary + no domains-file ──────────
new_sandbox with-templates
run_gov "" "cluster.example" "" >/dev/null 2>&1
grep -q 'api.cluster.example' "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" \
    && ok ".snapdragon.cluster_domain used as last-resort fallback" || bad "cluster_domain fallback wrong"

# ── Case 7: SHIPS-DARK — no baked templates dir => no-op (not error) ───────────
new_sandbox no-templates
run_gov "" "" "acme.example" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && ok "no baked templates => clean no-op (return 0)" || bad "non-zero rc with no templates"
[ ! -e "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" ] \
    && ok "no baked templates => nothing rendered (ships-dark)" || bad "rendered config without templates"

# ── Case 8: templates but NO domain => nothing rendered, no sudo granted ───────
new_sandbox with-templates
run_gov "" "" "" >/dev/null 2>&1
[ ! -e "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" ] \
    && ok "no domain => Discover remote NOT rendered (empty store)" || bad "remote rendered with no domain"
[ ! -e "${ETCROOT}/etc/polkit-1/rules.d/49-snapdragon-desktop-sudo.rules" ] \
    && ok "no domain => no polkit gate written (no sudo granted)" || bad "polkit gate written with no domain"

# ── Case 9: KEYS-USB fallback — templates only on KEYS, not baked ──────────────
# Proves the feature works WITHOUT touching the protected image builder: an admin
# ships KEYS/desktop-governance/ and provisioning renders from there.
new_sandbox keys-templates
run_gov "" "" "acme.example" >/dev/null 2>&1
[ -f "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" ] \
    && grep -q 'api.acme.example' "${ETCROOT}/etc/flatpak/remotes.d/snapdragon-discover.flatpakrepo" \
    && ok "KEYS-USB fallback: renders from KEYS/desktop-governance/ when not baked" \
    || bad "KEYS-USB fallback did not render the Discover remote"
[ -f "${ETCROOT}/etc/polkit-1/rules.d/49-snapdragon-desktop-sudo.rules" ] \
    && ok "KEYS-USB fallback: polkit sudo gate rendered" || bad "KEYS-USB fallback: no polkit gate"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
