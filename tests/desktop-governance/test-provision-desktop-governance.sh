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
                  -e "s#/etc/sssd#${ETCROOT}/etc/sssd#g" \
                  -e "s#/etc/sudoers#${ETCROOT}/etc/sudoers#g")"
        eval "${body}"
        provision_desktop_governance
    '
}

echo "== provision_desktop_governance() unit test =="

# ── Case 1: full render, domain from /etc/hugmesh/domains ───────────────────
new_sandbox with-templates
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
SSSD="${E}/sssd/conf.d/hugmesh-oidc.conf"
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

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
