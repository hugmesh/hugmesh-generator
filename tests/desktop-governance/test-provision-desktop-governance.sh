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
#   * the desktop-sudo MAPPER is rendered (mode 0700) with the per-domain
#     id.<domain> issuer + the desktop-sudo claim gate, its 60s cron drop-in is
#     installed, the local desktop-sudo group is ensured, and a stale pre-mapper
#     /etc/sssd/conf.d/hugmesh-oidc.conf (fake syntax) is retired.
#   * SYNTAX PIN: the template trees + provision.sh carry NONE of the fake SSSD
#     options the old conf invented (id_provider/oidc_*/[domain/../local-groups]
#     — they exist in no released SSSD) and nothing renders into /etc/sssd.
#   * PACKAGE/WIRING PIN: the mapper's interpreter (dev-lang/python) is declared
#     in the x86 CLIENT desktop list, sys-auth/sssd is NOT shipped (it cannot
#     consume Casdoor tokens), cronie (the 60s floor) is in the base list AND
#     the client runlevel, and both template copies carry the sudo/ templates.
#   * bearer-forward.sh is rendered (mode 0755) pointed at api.<domain>.
#   * DOMAIN PRECEDENCE: /etc/hugmesh/domains first line beats
#     .hugmesh.cluster_domain; .client.primary_domain beats both.
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
TPL_SRC="${REPO}/specs/etc/hugmesh/desktop-governance"
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

# Also extract provision_users() + the shared desktop_governance_governed()
# helper, so we can prove the HIGH-severity fix: on a governed image provision_users
# writes NO static /etc/sudoers.d grant and gives the user NO sudo-conferring wheel
# membership (sudo flows only via the desktop-sudo SSO claim/polkit); a non-governed
# image keeps its existing sudoers.d behavior.
extract_named_fn() { awk -v fn="$1" 'index($0, fn"() {")==1{p=1} p{print} /^\}/{if(p){exit}}' "${SRC}"; }
USERS_FN="$(extract_named_fn provision_users)"
GOV_HELPER_FN="$(extract_named_fn desktop_governance_governed)"
[ -n "${USERS_FN}" ] || { echo "  FAIL could not extract provision_users()"; exit 1; }
[ -n "${GOV_HELPER_FN}" ] || { echo "  FAIL could not extract desktop_governance_governed()"; exit 1; }
export __USERS_FN__="${USERS_FN}" __GOV_HELPER_FN__="${GOV_HELPER_FN}"

# Run provision_users() in the sandbox with all system mutators stubbed. The
# stubbed `useradd` records the -G group list to ${ETCROOT}/useradd-groups so we
# can assert wheel was/was not conferred. A users.json with one `sudo:true` user
# is written into the KEYS BASE. Governance is decided by whether the sandbox has
# baked/KEYS desktop-governance templates (new_sandbox arg).
run_users() {
    local sudo_nopw="${1:-false}"
    cat > "${BASE}/users.json" <<JSON
{ "users": [ { "name": "alice", "sudo": true, "sudo_nopasswd": ${sudo_nopw} } ] }
JSON
    ETCROOT="${ETCROOT}" BASE="${BASE}" \
    bash -c '
        set -uo pipefail
        log(){ :; }; warn(){ :; }; have(){ return 1; }
        MANIFEST="/dev/null"; USERS_MARKER="${ETCROOT}/users.created"
        # System mutators -> harmless stubs.
        groupadd(){ :; }
        getent(){ return 1; }                 # group/passwd lookups: pretend absent
        chpasswd(){ cat >/dev/null; }
        id(){ return 1; }                      # user "does not exist yet" => useradd path
        install_authorized_keys(){ :; }
        jq(){ command jq "$@"; }
        # Record the -G groups arg useradd is called with.
        useradd(){
            local g=""; while [ $# -gt 0 ]; do [ "$1" = "-G" ] && { g="$2"; shift; }; shift; done
            printf "%s\n" "${g}" > "${ETCROOT}/useradd-groups"
            return 0
        }
        body="$(printf "%s\n%s" "${__GOV_HELPER_FN__}" "${__USERS_FN__}" \
            | sed -e "s#/etc/sudoers#${ETCROOT}/etc/sudoers#g" \
                  -e "s#/etc/hugmesh/desktop-governance#${ETCROOT}/etc/hugmesh/desktop-governance#g")"
        eval "${body}"
        provision_users
    '
}

SANDBOXES=()
cleanup(){ for d in "${SANDBOXES[@]:-}"; do rm -rf "${d}" 2>/dev/null; done; }
trap cleanup EXIT

# Fresh sandbox: ETCROOT stands in for / (so /etc/... -> ${ETCROOT}/etc/...).
# BASE stands in for the mounted KEYS USB.
#   $1 = with-templates | no-templates | keys-templates
#        with-templates : baked at /etc/hugmesh/desktop-governance
#        keys-templates : only on the KEYS USB (KEYS/desktop-governance/)
#        no-templates   : neither
new_sandbox() {
    WORK="$(mktemp -d)"; SANDBOXES+=("${WORK}")
    ETCROOT="${WORK}/root"; BASE="${WORK}/keys"
    mkdir -p "${ETCROOT}/etc/hugmesh" "${BASE}"
    case "${1:-with-templates}" in
        with-templates) cp -r "${TPL_SRC}" "${ETCROOT}/etc/hugmesh/desktop-governance" ;;
        keys-templates) cp -r "${TPL_SRC}" "${BASE}/desktop-governance" ;;
        no-templates)   : ;;
    esac
}

# Run provision_desktop_governance() in the sandbox.
#   $1 = value for .client.primary_domain (empty => null)
#   $2 = value for .hugmesh.cluster_domain (empty => null)
#   $3 = first line to write into /etc/hugmesh/domains (empty => no file)
run_gov() {
    local pdom="$1" cdom="$2" domfile="$3"
    [ -n "${domfile}" ] && printf '%s\n' "${domfile}" > "${ETCROOT}/etc/hugmesh/domains"
    ETCROOT="${ETCROOT}" BASE="${BASE}" PDOM="${pdom}" CDOM="${cdom}" \
    bash -c '
        set -uo pipefail
        log()  { :; }
        warn() { :; }
        have() { return 1; }   # pretend flatpak is NOT installed (preset path)
        # Group mutators -> recording stubs (group "absent" => groupadd path).
        getent() { return 1; }
        groupadd() { printf "%s\n" "$*" >> "${ETCROOT}/groupadd.calls"; }
        jqm() {
            case "$1" in
                *client.primary_domain*)     printf "%s\n" "${PDOM:-null}" ;;
                *hugmesh.cluster_domain*) printf "%s\n" "${CDOM:-null}" ;;
                *) printf "\n" ;;
            esac
        }
        # Redirect every absolute system path the function writes to into ETCROOT.
        body="$(printf "%s" "${__FN__}" \
            | sed -e "s#/etc/hugmesh/desktop-governance#${ETCROOT}/etc/hugmesh/desktop-governance#g" \
                  -e "s#/etc/hugmesh/domains#${ETCROOT}/etc/hugmesh/domains#g" \
                  -e "s#/etc/flatpak#${ETCROOT}/etc/flatpak#g" \
                  -e "s#/etc/polkit-1#${ETCROOT}/etc/polkit-1#g" \
                  -e "s#/etc/cron.d#${ETCROOT}/etc/cron.d#g" \
                  -e "s#/etc/sssd#${ETCROOT}/etc/sssd#g" \
                  -e "s#/etc/sudoers#${ETCROOT}/etc/sudoers#g")"
        eval "${body}"
        provision_desktop_governance
    '
}

echo "== provision_desktop_governance() unit test =="

# ── Case 1: full render, domain from /etc/hugmesh/domains ───────────────────
new_sandbox with-templates
# Pre-seed a stale pre-mapper SSSD conf (fake syntax) — provisioning must retire it.
mkdir -p "${ETCROOT}/etc/sssd/conf.d"
printf '[domain/x]\nid_provider = oidc\n' > "${ETCROOT}/etc/sssd/conf.d/hugmesh-oidc.conf"
run_gov "" "" "acme.example" >/dev/null 2>&1
E="${ETCROOT}/etc"
REPO_F="${E}/flatpak/remotes.d/hugmesh-discover.flatpakrepo"
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
POLKIT="${E}/polkit-1/rules.d/49-hugmesh-desktop-sudo.rules"
[ -f "${POLKIT}" ] && grep -q 'unix-group:desktop-sudo' "${POLKIT}" \
    && ok "polkit desktop-sudo gate installed" || bad "polkit gate missing/wrong"
MAPPER="${E}/hugmesh/desktop-governance/desktop-sudo-mapper"
if [ -f "${MAPPER}" ]; then
    grep -q 'ISSUER = "https://id.acme.example"' "${MAPPER}" \
        && ok "mapper issuer -> id.<domain> (domain substituted)" \
        || bad "mapper issuer wrong: $(grep -m1 'ISSUER = ' "${MAPPER}")"
    ! grep -q '@@CLUSTER_DOMAIN@@' "${MAPPER}" \
        && ok "no @@CLUSTER_DOMAIN@@ placeholder left in the rendered mapper" \
        || bad "placeholder NOT substituted in the mapper"
    grep -q 'GROUP = "desktop-sudo"' "${MAPPER}" \
        && ok "mapper gates on the desktop-sudo claim->group" || bad "mapper desktop-sudo gate missing"
    mode="$(stat -c '%a' "${MAPPER}" 2>/dev/null)"
    [ "${mode}" = "700" ] && ok "mapper mode 0700 (root-run)" || bad "mapper mode ${mode} != 700"
else
    bad "desktop-sudo mapper not rendered"
fi
CRON="${E}/cron.d/hugmesh-desktop-sudo-mapper"
if [ -f "${CRON}" ]; then
    grep -q '^\* \* \* \* \* root .*/etc/hugmesh/desktop-governance/desktop-sudo-mapper' "${CRON}" \
        && ok "mapper 60s cron installed (root, targets the rendered mapper)" \
        || bad "mapper cron wrong: $(grep -m1 '^\*' "${CRON}")"
else
    bad "mapper cron drop-in not installed"
fi
grep -q '^desktop-sudo$' "${ETCROOT}/groupadd.calls" 2>/dev/null \
    && ok "local desktop-sudo group ensured (groupadd when absent)" \
    || bad "desktop-sudo group NOT ensured"
[ ! -e "${ETCROOT}/etc/sssd/conf.d/hugmesh-oidc.conf" ] \
    && ok "stale pre-mapper SSSD conf (fake syntax) retired" \
    || bad "stale /etc/sssd/conf.d/hugmesh-oidc.conf left behind"
BF="${E}/hugmesh/desktop-governance/bearer-forward.sh"
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
[ -f "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" ] \
    && ok "our hugmesh-discover remote survives Flathub-off" || bad "our remote was removed"

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
grep -q 'api.primary.example' "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" \
    && ok ".client.primary_domain wins precedence" || bad "primary_domain precedence wrong"

# ── Case 5: domains-file beats cluster_domain ──────────────────────────────────
new_sandbox with-templates
run_gov "" "cluster.example" "domainsfile.example" >/dev/null 2>&1
grep -q 'api.domainsfile.example' "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" \
    && ok "/etc/hugmesh/domains first line beats .hugmesh.cluster_domain" \
    || bad "domains-file precedence wrong"

# ── Case 6: cluster_domain fallback when no primary + no domains-file ──────────
new_sandbox with-templates
run_gov "" "cluster.example" "" >/dev/null 2>&1
grep -q 'api.cluster.example' "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" \
    && ok ".hugmesh.cluster_domain used as last-resort fallback" || bad "cluster_domain fallback wrong"

# ── Case 7: SHIPS-DARK — no baked templates dir => no-op (not error) ───────────
new_sandbox no-templates
run_gov "" "" "acme.example" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && ok "no baked templates => clean no-op (return 0)" || bad "non-zero rc with no templates"
[ ! -e "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" ] \
    && ok "no baked templates => nothing rendered (ships-dark)" || bad "rendered config without templates"

# ── Case 8: templates but NO domain => nothing rendered, no sudo granted ───────
new_sandbox with-templates
run_gov "" "" "" >/dev/null 2>&1
[ ! -e "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" ] \
    && ok "no domain => Discover remote NOT rendered (empty store)" || bad "remote rendered with no domain"
[ ! -e "${ETCROOT}/etc/polkit-1/rules.d/49-hugmesh-desktop-sudo.rules" ] \
    && ok "no domain => no polkit gate written (no sudo granted)" || bad "polkit gate written with no domain"
[ ! -e "${ETCROOT}/etc/hugmesh/desktop-governance/desktop-sudo-mapper" ] \
    && [ ! -e "${ETCROOT}/etc/cron.d/hugmesh-desktop-sudo-mapper" ] \
    && ok "no domain => no mapper + no cron rendered (sudo leg stays dark)" \
    || bad "mapper/cron rendered with no domain"

# ── Case 9: KEYS-USB fallback — templates only on KEYS, not baked ──────────────
# Proves the feature works WITHOUT touching the protected image builder: an admin
# ships KEYS/desktop-governance/ and provisioning renders from there.
new_sandbox keys-templates
run_gov "" "" "acme.example" >/dev/null 2>&1
[ -f "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" ] \
    && grep -q 'api.acme.example' "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" \
    && ok "KEYS-USB fallback: renders from KEYS/desktop-governance/ when not baked" \
    || bad "KEYS-USB fallback did not render the Discover remote"
[ -f "${ETCROOT}/etc/polkit-1/rules.d/49-hugmesh-desktop-sudo.rules" ] \
    && ok "KEYS-USB fallback: polkit sudo gate rendered" || bad "KEYS-USB fallback: no polkit gate"

# ── Case 10: HIGH FIX — GOVERNED image suppresses static sudoers.d + wheel-sudo ─
# A `sudo:true` KEYS user on a governed image must get NO /etc/sudoers.d/10-<name>
# grant and must NOT be placed in the sudo-conferring `wheel` group. Sudo flows
# only via the desktop-sudo SSO claim / polkit gate.
new_sandbox with-templates
mkdir -p "${ETCROOT}/etc/sudoers.d"
run_users false >/dev/null 2>&1
[ ! -e "${ETCROOT}/etc/sudoers.d/10-alice" ] \
    && ok "governed: NO static /etc/sudoers.d/10-alice grant for a sudo:true user" \
    || bad "governed: static sudoers.d grant written (standing root bypass)"
if [ -f "${ETCROOT}/useradd-groups" ] && ! grep -qw 'wheel' "${ETCROOT}/useradd-groups"; then
    ok "governed: user NOT placed in sudo-conferring wheel group"
else
    bad "governed: user given wheel-group sudo ($(cat "${ETCROOT}/useradd-groups" 2>/dev/null))"
fi
# Non-wheel supplementary groups are preserved.
grep -q 'audio' "${ETCROOT}/useradd-groups" 2>/dev/null \
    && ok "governed: non-sudo groups (audio/video/usb) preserved" \
    || bad "governed: dropped non-sudo supplementary groups too"

# ── Case 11: GOVERNED image — provision_desktop_governance STRIPS a pre-existing
# standing /etc/sudoers.d/10-* grant (defense-in-depth, after provision_users).
new_sandbox with-templates
mkdir -p "${ETCROOT}/etc/sudoers.d"
printf 'bob ALL=(ALL) ALL\n' > "${ETCROOT}/etc/sudoers.d/10-bob"
printf 'carol ALL=(ALL:ALL) NOPASSWD: ALL\n' > "${ETCROOT}/etc/sudoers.d/90-carol"
run_gov "" "" "acme.example" >/dev/null 2>&1
[ ! -e "${ETCROOT}/etc/sudoers.d/10-bob" ] \
    && ok "governed: pre-existing 10-<name> standing sudoers.d grant stripped" \
    || bad "governed: standing 10-bob grant survived"
if grep -Eq '^carol[[:space:]]+ALL=' "${ETCROOT}/etc/sudoers.d/90-carol" 2>/dev/null; then
    bad "governed: other standing sudoers.d ALL=(ALL) grant left active"
else
    ok "governed: other standing sudoers.d ALL=(ALL) grant neutralized"
fi

# ── Case 12: NON-governed image keeps existing sudoers.d behavior (regression) ──
new_sandbox no-templates
mkdir -p "${ETCROOT}/etc/sudoers.d"
run_users false >/dev/null 2>&1
[ -f "${ETCROOT}/etc/sudoers.d/10-alice" ] \
    && grep -q 'alice ALL=(ALL) ALL' "${ETCROOT}/etc/sudoers.d/10-alice" \
    && ok "non-governed: existing static /etc/sudoers.d/10-alice grant preserved" \
    || bad "non-governed: sudoers.d grant missing/wrong (broke un-governed behavior)"
grep -qw 'wheel' "${ETCROOT}/useradd-groups" 2>/dev/null \
    && ok "non-governed: default wheel group membership preserved" \
    || bad "non-governed: wheel group dropped (broke un-governed behavior)"
# NOPASSWD variant still honored on a non-governed image.
new_sandbox no-templates
mkdir -p "${ETCROOT}/etc/sudoers.d"
run_users true >/dev/null 2>&1
grep -q 'alice ALL=(ALL) NOPASSWD: ALL' "${ETCROOT}/etc/sudoers.d/10-alice" 2>/dev/null \
    && ok "non-governed: sudo_nopasswd:true still writes NOPASSWD grant" \
    || bad "non-governed: NOPASSWD grant not written"

# ── Case 13: MED FIX — bearer-forward uses PER-USER scope + clears on logout ────
# Render bearer-forward.sh and assert it never touches the shared/system flatpak
# config, uses `flatpak --user`, installs a logout clear hook, and does NOT export
# the token into the environment.
new_sandbox with-templates
run_gov "" "" "acme.example" >/dev/null 2>&1
BF="${ETCROOT}/etc/hugmesh/desktop-governance/bearer-forward.sh"
if [ -f "${BF}" ]; then
    grep -q 'flatpak --user config --set http.extra-headers' "${BF}" \
        && ok "bearer-forward: writes header via flatpak --user (per-user scope)" \
        || bad "bearer-forward: not using --user scope"
    ! grep -Eq 'flatpak[[:space:]]+config[[:space:]]+--set' "${BF}" \
        && ! grep -q -- '--system config' "${BF}" \
        && ok "bearer-forward: never writes the shared/system flatpak config" \
        || bad "bearer-forward: still writes system/shared flatpak config"
    grep -q 'plasma-workspace/shutdown' "${BF}" && grep -q 'install_logout_clear' "${BF}" \
        && ok "bearer-forward: installs a logout hook that clears the header on session end" \
        || bad "bearer-forward: no logout clear hook"
    grep -q -- '--clear' "${BF}" \
        && ok "bearer-forward: supports --clear mode (invoked by the logout hook)" \
        || bad "bearer-forward: no --clear mode"
    ! grep -q 'export HUGMESH_REGISTRY_BEARER' "${BF}" \
        && ok "bearer-forward: does NOT export the bearer token into the environment" \
        || bad "bearer-forward: still exports HUGMESH_REGISTRY_BEARER (token leak)"
else
    bad "bearer-forward.sh not rendered"
fi

# ── Case 14: MED FIX — malicious domain with sed metachars / newline is REJECTED
# (fail-closed) so it cannot inject into / break the rendered config. Crafted
# domains: a `/`-injection that would rewrite the sed replacement, a `&`/`\`
# payload, and an embedded newline. None must render any config or grant sudo.
for craft in 'evil.example/g; s/Title/HACKED' 'a&b\c.example' $'good.example\ninjected line'; do
    new_sandbox with-templates
    run_gov "${craft}" "" "" >/dev/null 2>&1; rc=$?
    if [ "${rc}" -eq 0 ] \
       && [ ! -e "${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" ] \
       && [ ! -e "${ETCROOT}/etc/polkit-1/rules.d/49-hugmesh-desktop-sudo.rules" ]; then
        ok "malicious domain rejected fail-closed (no render, no sudo): $(printf '%q' "${craft}")"
    else
        bad "malicious domain NOT rejected (render or sudo happened): $(printf '%q' "${craft}") rc=${rc}"
    fi
done
# And a benign domain still escapes harmlessly + renders correctly (no injection
# of a stray sed command, exactly one Url line).
new_sandbox with-templates
run_gov "good.example" "" "" >/dev/null 2>&1
REPO_F="${ETCROOT}/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo"
if [ -f "${REPO_F}" ] \
   && grep -q 'Url=https://api.good.example/bff/desktop/registry/' "${REPO_F}" \
   && ! grep -qi 'HACKED' "${REPO_F}"; then
    ok "benign domain renders correctly with escaping (no injected content)"
else
    bad "benign domain render wrong/injected"
fi

# ── Case 15: the two template copies are BYTE-IDENTICAL for the config templates
# rendered onto the system (KEYS-USB fallback must render the same bytes as the
# baked path). README docs may differ in framing and are excluded.
KEYS_TPL="${REPO}/keys-template/desktop-governance"
if [ -d "${KEYS_TPL}" ]; then
    parity_ok=1
    while IFS= read -r rel; do
        case "${rel}" in */README.md|README.md) continue ;; esac
        if ! cmp -s "${TPL_SRC}/${rel}" "${KEYS_TPL}/${rel}"; then
            parity_ok=0; echo "    (differs: ${rel})"
        fi
    done < <(cd "${TPL_SRC}" && find . -type f | sed 's#^\./##')
    [ "${parity_ok}" -eq 1 ] \
        && ok "config templates byte-identical between specs/etc/... and keys-template/..." \
        || bad "config templates DIFFER between the two template copies"
else
    bad "keys-template/desktop-governance not found"
fi

# ── Case 16: SYNTAX PIN — the fake SSSD options must never come back ───────────
# The pre-fix conf used `id_provider = oidc` + `oidc_groups_allowlist` + a
# `[domain/../local-groups]` section: syntax that exists in NO released SSSD
# (2.11's real OAuth2 provider is `id_provider = idp`, Keycloak/Entra-only, no
# claim->group mapping). Pin: no ACTIVE (non-comment) option assignment of that
# family anywhere in either template tree or provision.sh, no such section
# header, and provision.sh renders NOTHING into /etc/sssd. Prose mentions in
# comments (lines starting with #) stay allowed.
KEYS_TPL="${REPO}/keys-template/desktop-governance"
if grep -rEn '^[[:space:]]*(id_provider|auth_provider|oidc_[a-z_]+)[[:space:]]*=' \
        "${TPL_SRC}" "${KEYS_TPL}" "${SRC}" 2>/dev/null; then
    bad "fake SSSD option syntax reintroduced (id_provider/oidc_* assignment above)"
else
    ok "syntax pin: no id_provider/auth_provider/oidc_* option assignment anywhere"
fi
if grep -rEn '^\[domain/.*/local-groups\]' "${TPL_SRC}" "${KEYS_TPL}" "${SRC}" 2>/dev/null; then
    bad "fake [domain/../local-groups] section reintroduced"
else
    ok "syntax pin: no [domain/../local-groups] section anywhere"
fi
if grep -En 'render_gov[^#]*/etc/sssd' "${SRC}" 2>/dev/null; then
    bad "provision.sh renders into /etc/sssd again (sssd cannot consume Casdoor tokens)"
else
    ok "syntax pin: provision.sh renders nothing into /etc/sssd"
fi

# ── Case 17: PACKAGE/WIRING PIN — the mapper's runtime is actually shipped ─────
# The sudo leg is real only if EVERY runtime it depends on is a DECLARED x86
# CLIENT package (not an accident of portage's transitive graph): the polkit
# authority that reads the gate rule, the mapper's interpreter, and the cron
# engine behind the 60s floor (base list + enabled in the client runlevel). The
# templates must exist in BOTH delivery copies, and sys-auth/sssd — which cannot
# consume the Casdoor token — must stay off the image. The client lists are the
# ONLY place these may appear: the sudo leg is desktop-only, so a leak into the
# base (headless node) list is also a failure.
PKG_DESKTOP="${REPO}/specs-x86/portage/packages-desktop.list"
PKG_BASE="${REPO}/specs-x86/portage/packages.list"
BUILDER="${REPO}/build-x86-host-stage4.sh"
[ -f "${TPL_SRC}/sudo/desktop-sudo-mapper.py.tmpl" ] && [ -f "${KEYS_TPL}/sudo/desktop-sudo-mapper.py.tmpl" ] \
    && [ -f "${TPL_SRC}/sudo/cron-desktop-sudo-mapper" ] && [ -f "${KEYS_TPL}/sudo/cron-desktop-sudo-mapper" ] \
    && ok "sudo/ mapper + cron templates present in both delivery copies" \
    || bad "sudo/ templates missing from a delivery copy"
# polkit is THE sole escalation route on a governed image (sudoers is stripped):
# without sys-auth/polkit the rendered rules.d gate is an inert text file and no
# user can escalate at all. It arrives today only via lxde-base/lxsession — a
# transitive dep is not a contract, so it must be declared.
grep -qx 'sys-auth/polkit' "${PKG_DESKTOP}" \
    && ok "polkit gate engine (sys-auth/polkit) declared in the x86 CLIENT desktop list" \
    || bad "sys-auth/polkit not declared in packages-desktop.list (sole sudo path is transitive-only)"
! grep -qx 'sys-auth/polkit' "${PKG_BASE}" \
    && ok "polkit stays CLIENT-scoped (not pulled onto headless nodes)" \
    || bad "sys-auth/polkit leaked into the base (headless) package list"
grep -qx 'dev-lang/python' "${PKG_DESKTOP}" \
    && ok "mapper interpreter (dev-lang/python) declared in the x86 CLIENT desktop list" \
    || bad "dev-lang/python not declared in packages-desktop.list"
! grep -Eq '^sys-auth/sssd' "${PKG_DESKTOP}" "${PKG_BASE}" \
    && ok "sys-auth/sssd NOT shipped (it cannot consume Casdoor tokens — mapper instead)" \
    || bad "sys-auth/sssd shipped despite having no working config"
grep -qx 'sys-process/cronie' "${PKG_BASE}" \
    && ok "cron floor engine (sys-process/cronie) in the base package list" \
    || bad "sys-process/cronie missing from the base list"
grep -Eq 'SVCS=\([^)]*cronie[^)]*display-manager' "${BUILDER}" \
    && ok "client runlevel enables cronie (the mapper's 60s floor actually runs)" \
    || bad "client SVCS set does not enable cronie"
# No PAM/NSS wiring is part of this design: `desktop-sudo` is a LOCAL group, so
# polkit resolves it through the stock nsswitch `files` source. Pin that the
# provisioning path never starts editing nsswitch.conf or /etc/pam.d — an edit
# there would mean someone reached for an identity-provider integration again.
if grep -En 'nsswitch\.conf|/etc/pam\.d' "${SRC}" 2>/dev/null; then
    bad "provisioning touches nsswitch/PAM (the mapper needs neither — local group)"
else
    ok "wiring pin: no nsswitch/PAM edits (membership is a local group via nss files)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
