#!/usr/bin/env bash
# test-desktop-sso-bake.sh — the greeter SSO path is BAKED into the desktop images
# and survives the payload emerge (scripts/_desktop-sso-lib.sh + the builders).
#
# What was true before this change (mapper, 2026-11-04): x86's --with-sso/--no-sso
# (SKIP_SSO) only changed a `_plan` line; build-frite-stage4.sh had no SSO flag at
# all; no builder baked /etc/hugmesh/desktop-governance (README: "KEYS run[] only");
# no /etc/pam.d stack existed anywhere in specs. This suite pins the fix:
#
#   A. BUILDERS   x86 (client roles, not --unaffiliated) and frite (--desktop light)
#                 source the lib, call desktop_sso_bake with ENABLED derived from
#                 SKIP_SSO and POSTURE from STANDALONE, pre-emerge (after their
#                 lightdm.conf heredoc), and desktop_sso_verify post-emerge; frite
#                 parses --with-sso/--no-sso/--skip-sso, defaults SSO on, turns it
#                 off for --standalone unless forced, and reports it in --print-plan.
#   B. RUNTIME    specs-frite/portage/packages-light-desktop.list declares
#                 dev-lang/python and sys-auth/polkit (the helper and the mapper
#                 are python3; polkit is the governed sudo gate's authority).
#   C. PROVISION  provision_desktop_governance() runs the BAKED session-install
#                 template, so the GEN-SSO session-start no longer needs a KEYS
#                 run[] hook.
#   D. LIB        desktop_sso_bake, EXECUTED against a fake sysroot: the helper,
#                 the stack, the conf (SSO_ENABLED / ISSUER / POSTURE / brand), the
#                 lightdm.conf additions (idempotent), the governance dir only when
#                 enabled, an invalid domain bakes SSO off, no lightdm.conf fails.
#   E. VERIFY     desktop_sso_verify, EXECUTED: green on the baked sysroot, parks
#                 nothing (a ._cfg0000_lightdm is removed), and RED when the stack
#                 was overwritten by the package's, or the helper / python3 /
#                 pam_exec / pam_echo is missing.
#   F. STACK      specs/etc/pam.d/lightdm: the SSO exec line precedes the local
#                 include with [success=done default=ignore] and quiet stdout
#                 expose_authtok; the hint path matches the helper's; the session
#                 hand-off line follows the session include; no numeric success=N
#                 jumps (so nothing a later splice could move).
#   A2. ARM       rpi5, jetson, orangepi4-lts, orangepi5 (the other ARM desktop
#                 builders that write lightdm.conf): the same flags
#                 (--with-sso/--no-sso/--skip-sso/--sso-issuer), standalone
#                 default off, --print-plan SSO + SSO_ISSUER, bake after the
#                 lightdm.conf heredoc and before the emerge, verify after it.
#   D2. ISSUER    --sso-issuer reaches the conf (https only; a bad URL fails the
#                 bake); a standalone image with SSO on stays UNGOVERNED (no KEYS
#                 chain runs the desktop-sudo mapper there).
#   G. CONTROLS   every static pin in A/A2/B/C is re-run against a copy with the
#                 line removed and must go red (each plant verified to change the
#                 file).
#
# Pure static + sandboxed execution. No root, no emerge, no network.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_desktop-sso-lib.sh"
X86="${REPO}/build-x86-host-stage4.sh"
FRITE="${REPO}/build-frite-stage4.sh"
ARM_DESKTOP_BUILDERS=(build-rpi5-stage4.sh build-jetson-stage4.sh build-orangepi4-lts-stage4.sh build-orangepi5-stage4.sh)
FRITE_LIST="${REPO}/specs-frite/portage/packages-light-desktop.list"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
STACK="${REPO}/specs/etc/pam.d/lightdm"
HELPER="${REPO}/specs/usr/lib/hugmesh/sso-greeter"
for f in "${LIB}" "${X86}" "${FRITE}" "${FRITE_LIST}" "${PROV}" "${STACK}" "${HELPER}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── A. builders ───────────────────────────────────────────────────────────────
# pin LABEL FILE REGEX — one line of FILE matches REGEX (fixed to the file, so
# the negative controls can re-run the same pins over a mutated copy).
pin(){ grep -Eq "$3" "$2" && ok "$1" || bad "$1 (no line matching: $3)"; }
pin_x86() {
    local f="$1"
    pin "x86: sources scripts/_desktop-sso-lib.sh" "${f}" '^source "\$\{SCRIPT_DIR\}/scripts/_desktop-sso-lib\.sh"$'
    pin "x86: desktop_sso_bake takes ENABLED from SKIP_SSO" "${f}" '"\$\(\$\{SKIP_SSO\} && echo false \|\| echo true\)" "\$\{CLUSTER_DOMAIN\}" "\$\{BRAND_TITLE\}"'
    pin "x86: desktop_sso_bake takes POSTURE from STANDALONE" "${f}" '"\$\(\$\{STANDALONE\} && echo standalone \|\| echo mesh\)"'
    pin "x86: desktop_sso_bake takes the --sso-issuer override" "${f}" '"\$\(\$\{STANDALONE\} && echo standalone \|\| echo mesh\)" "\$\{SSO_ISSUER\}"'
    pin "x86: parses --sso-issuer" "${f}" '^ *--sso-issuer\) SSO_ISSUER="\$\{2:-\}"; shift 2 ;;$'
    pin "x86: --sso-issuer implies SSO on" "${f}" '^    SSO_FORCED=on; SKIP_SSO=false$'
    pin "x86: --sso-issuer conflicts with --no-sso" "${f}" '^    \[ "\$\{SSO_FORCED\}" = off \] && \{ err "--sso-issuer conflicts with --no-sso/--skip-sso"; exit 1; \}$'
    pin "x86: --print-plan reports SSO_ISSUER" "${f}" '^    _plan SSO_ISSUER  *'
    pin "x86: the bake is skipped for --unaffiliated" "${f}" '^    if ! \$\{UNAFFILIATED\}; then$'
    pin "x86: desktop_sso_verify runs for client roles post-emerge" "${f}" '^if \$\{ROLE_CLIENT\} && ! \$\{UNAFFILIATED\}; then$'
    pin "x86: desktop_sso_verify failure aborts the build" "${f}" 'desktop_sso_verify "\$\{SYSROOT\}" \|\| \{ err .*; exit 1; \}'
    # ordering: the bake call sits after the lightdm.conf heredoc and before the
    # chroot emerge; the verify after the emerge and before the stage4 tarball.
    awk '/^LIGHTDM$/ && !h {h=NR} /desktop_sso_bake "\$\{SYSROOT\}"/ && !b {b=NR} /^banner "Emerging @system/ && !e {e=NR}
         /desktop_sso_verify "\$\{SYSROOT\}"/ && !v {v=NR} /^# ── 9\. Stage4 tarball/ && !t {t=NR}
         END { exit !(h && b && e && v && t && h < b && b < e && e < v && v < t) }' "${f}" \
        && ok "x86: bake after lightdm.conf and before the emerge; verify after the emerge and before the stage4 tarball" \
        || bad "x86: bake/verify are not in the pre-emerge / post-emerge positions"
}
pin_frite() {
    local f="$1"
    pin "frite: sources scripts/_desktop-sso-lib.sh" "${f}" '^source "\$\{SCRIPT_DIR\}/scripts/_desktop-sso-lib\.sh"$'
    pin "frite: SKIP_SSO defaults to false (SSO on for a mesh client)" "${f}" '^SKIP_SSO=false$'
    pin "frite: parses --skip-sso | --no-sso" "${f}" '^ *--skip-sso\|--no-sso\) *SKIP_SSO=true; *SSO_FORCED=off; shift ;;$'
    pin "frite: parses --with-sso" "${f}" '^ *--with-sso\) *SKIP_SSO=false; *SSO_FORCED=on; *shift ;;$'
    pin "frite: --standalone turns SSO off unless --with-sso" "${f}" '^    \[ "\$\{SSO_FORCED\}" = on \] \|\| SKIP_SSO=true$'
    pin "frite: --print-plan reports SSO" "${f}" '^    _plan SSO  *"\$\(\$\{SKIP_SSO\} && echo off \|\| echo casdoor-oidc\)"$'
    pin "frite: desktop_sso_bake takes ENABLED from SKIP_SSO" "${f}" '"\$\(\$\{SKIP_SSO\} && echo false \|\| echo true\)" "\$\{CLUSTER_DOMAIN\}" "\$\{BRAND_TITLE\}"'
    pin "frite: desktop_sso_verify failure aborts the build" "${f}" 'desktop_sso_verify "\$\{SYSROOT\}" \|\| \{ err .*; exit 1; \}'
    pin "frite: --with-sso documented in usage" "${f}" '^    --with-sso \| --no-sso \| --skip-sso '
    pin "frite: parses --sso-issuer" "${f}" '^ *--sso-issuer\) *SSO_ISSUER="\$\{2:-\}"; *shift 2 ;;$'
    pin "frite: --sso-issuer implies SSO on" "${f}" '^    SSO_FORCED=on; SKIP_SSO=false$'
    pin "frite: desktop_sso_bake takes the --sso-issuer override" "${f}" '"\$\(\$\{STANDALONE\} && echo standalone \|\| echo mesh\)" "\$\{SSO_ISSUER\}"'
    awk '/^LIGHTDM$/ && !h {h=NR} /desktop_sso_bake "\$\{SYSROOT\}"/ && !b {b=NR} /^banner "Emerging @system/ && !e {e=NR}
         /desktop_sso_verify "\$\{SYSROOT\}"/ && !v {v=NR} /^banner "Packaging stage4 tarball"/ && !t {t=NR}
         END { exit !(h && b && e && v && t && h < b && b < e && e < v && v < t) }' "${f}" \
        && ok "frite: bake after lightdm.conf and before the emerge; verify after the emerge and before the stage4 pack" \
        || bad "frite: bake/verify are not in the pre-emerge / post-emerge positions"
    # the standalone rule must sit INSIDE the STANDALONE block (it reads SSO_FORCED)
    awk '/^if \$\{STANDALONE\}; then$/ {s=1} s && /SKIP_SSO=true/ {found=1} s && /^fi$/ {exit} END {exit !found}' "${f}" \
        && ok "frite: the SSO-off rule is inside the STANDALONE posture block" || bad "frite: SKIP_SSO=true not inside the STANDALONE block"
}
# pin_arm FILE — the four other ARM desktop builders carry the same surface.
pin_arm() {
    local f="$1" n
    n="$(basename "${f}" -stage4.sh)"; n="${n#build-}"
    pin "${n}: sources scripts/_desktop-sso-lib.sh" "${f}" '^source "\$\{SCRIPT_DIR\}/scripts/_desktop-sso-lib\.sh"$'
    pin "${n}: SKIP_SSO defaults to false" "${f}" '^SKIP_SSO=false$'
    pin "${n}: parses --skip-sso | --no-sso" "${f}" '^ *--skip-sso\|--no-sso\) *SKIP_SSO=true; *SSO_FORCED=off; shift ;;$'
    pin "${n}: parses --with-sso" "${f}" '^ *--with-sso\) *SKIP_SSO=false; *SSO_FORCED=on; *shift ;;$'
    pin "${n}: parses --sso-issuer" "${f}" '^ *--sso-issuer\) *SSO_ISSUER="\$\{2:-\}"; *shift 2 ;;$'
    pin "${n}: --sso-issuer implies SSO on" "${f}" '^    SSO_FORCED=on; SKIP_SSO=false$'
    pin "${n}: --print-plan reports SSO" "${f}" '^    _plan SSO  *"\$\(\$\{SKIP_SSO\} && echo off \|\| echo casdoor-oidc\)"$'
    pin "${n}: desktop_sso_bake takes ENABLED/POSTURE/ISSUER" "${f}" '"\$\(\$\{STANDALONE\} && echo standalone \|\| echo mesh\)" "\$\{SSO_ISSUER\}"'
    pin "${n}: desktop_sso_verify failure aborts the build" "${f}" 'desktop_sso_verify "\$\{SYSROOT\}" \|\| \{ err .*; exit 1; \}'
    awk '/^LIGHTDM$/ && !h {h=NR} /desktop_sso_bake "\$\{SYSROOT\}"/ && !b {b=NR} /^banner "Emerging @system/ && !e {e=NR}
         /desktop_sso_verify "\$\{SYSROOT\}"/ && !v {v=NR} /^banner "Packaging stage4 tarball"/ && !t {t=NR}
         END { exit !(h && b && e && v && t && h < b && b < e && e < v && v < t) }' "${f}" \
        && ok "${n}: bake after lightdm.conf and before the emerge; verify after the emerge and before the stage4 pack" \
        || bad "${n}: bake/verify are not in the pre-emerge / post-emerge positions"
    awk '/^if \$\{STANDALONE\}; then$/ {s=1} s && /\[ "\$\{SSO_FORCED\}" = on \] \|\| SKIP_SSO=true/ {found=1} s && /^fi$/ {exit} END {exit !found}' "${f}" \
        && ok "${n}: the SSO-off rule is inside the STANDALONE posture block" || bad "${n}: SKIP_SSO=true not inside the STANDALONE block"
}
echo "== A. builders =="
pin_x86 "${X86}"
pin_frite "${FRITE}"
bash -n "${X86}" && bash -n "${FRITE}" && bash -n "${LIB}" && ok "builders + lib parse (bash -n)" || bad "bash -n failed"
echo "== A2. the other ARM desktop builders =="
for b in "${ARM_DESKTOP_BUILDERS[@]}"; do
    [ -f "${REPO}/${b}" ] || { bad "missing ${b}"; continue; }
    pin_arm "${REPO}/${b}"
    bash -n "${REPO}/${b}" && ok "${b}: parses (bash -n)" || bad "${b}: bash -n failed"
done
# Every builder that writes a lightdm.conf bakes the SSO stack: a NEW desktop
# builder that forgets it goes red here instead of shipping a greeter with no SSO.
for b in "${REPO}"/build-*-stage4.sh; do
    grep -q 'lightdm/lightdm.conf" <<' "${b}" || continue
    grep -q 'desktop_sso_bake "\${SYSROOT}"' "${b}" && grep -q 'desktop_sso_verify "\${SYSROOT}"' "${b}" \
        && ok "$(basename "${b}"): writes lightdm.conf AND bakes + verifies the SSO stack" \
        || bad "$(basename "${b}"): writes lightdm.conf but does not bake/verify the greeter SSO stack"
done

# ── B. frite runtime ─────────────────────────────────────────────────────────
echo "== B. frite runtime atoms =="
pin_list() {
    pin "frite light list declares dev-lang/python" "$1" '^dev-lang/python$'
    pin "frite light list declares sys-auth/polkit" "$1" '^sys-auth/polkit$'
}
pin_list "${FRITE_LIST}"

# ── C. provisioning runs the baked session-install ───────────────────────────
echo "== C. provision_desktop_governance runs the baked session-install =="
pin_prov() {
    awk '/^provision_desktop_governance\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}' "$1" > "${WORK}/fn"
    grep -Eq '^ *if KEYS_BASE="\$\{BASE\}" bash "\$\{tpl\}/autostart/session-install\.sh\.tmpl"; then$' "${WORK}/fn" \
        && ok "provision_desktop_governance runs \${tpl}/autostart/session-install.sh.tmpl with KEYS_BASE" \
        || bad "provision_desktop_governance does not run the baked session-install"
    grep -q 'bearer-forward.sh.tmpl' "${WORK}/fn" && awk '/bearer-forward\.sh\.tmpl/ && !b {b=NR} /session-install\.sh\.tmpl"; then/ && !s {s=NR} END {exit !(b && s && b < s)}' "${WORK}/fn" \
        && ok "session-install runs AFTER the named templates (bearer-forward) are rendered" || bad "session-install ordering wrong"
}
pin_prov "${PROV}"
bash -n "${PROV}" && ok "provision.sh parses" || bad "provision.sh: bash -n failed"
# The template is runnable as shipped: executable bit set when baked, and it
# resolves the domain itself (the placeholder is only in a comment).
grep -q '^set -uo pipefail' "${REPO}/specs/etc/hugmesh/desktop-governance/autostart/session-install.sh.tmpl" \
    && ok "session-install.sh.tmpl is a runnable script" || bad "session-install.sh.tmpl not runnable"

# ── D. desktop_sso_bake executed ─────────────────────────────────────────────
echo "== D. desktop_sso_bake against a fake sysroot =="
# shellcheck source=/dev/null
source "${LIB}"
mk_sysroot() {  # $1=name -> path with the builders' lightdm.conf in place
    local s="${WORK}/$1"; mkdir -p "${s}/etc/lightdm"
    printf '[LightDM]\n[Seat:*]\ngreeter-session=lightdm-gtk-greeter\nuser-session=LXDE\n' > "${s}/etc/lightdm/lightdm.conf"
    echo "${s}"
}
S="$(mk_sysroot on)"
if desktop_sso_bake "${S}" "${REPO}/specs" true acme.example 'Acme "Desktops"' mesh >"${WORK}/bake.out" 2>&1; then
    ok "bake (SSO on) returns 0"
else
    bad "bake (SSO on) failed: $(cat "${WORK}/bake.out")"
fi
cmp -s "${S}/usr/lib/hugmesh/sso-greeter" "${HELPER}" && [ "$(stat -c %a "${S}/usr/lib/hugmesh/sso-greeter")" = 755 ] \
    && ok "helper installed byte-identical, 0755" || bad "helper not installed as expected"
cmp -s "${S}/etc/pam.d/lightdm" "${STACK}" && [ "$(stat -c %a "${S}/etc/pam.d/lightdm")" = 644 ] \
    && ok "/etc/pam.d/lightdm installed byte-identical, 0644" || bad "stack not installed as expected"
C="${S}/etc/hugmesh/sso-greeter.conf"
grep -q '^SSO_ENABLED=true$' "${C}" && grep -q '^ISSUER=https://id.acme.example$' "${C}" && grep -q '^POSTURE=mesh$' "${C}" \
    && grep -q '^CLIENT_ID=hugmesh-desktop$' "${C}" && grep -q '^OFFLINE_MAX_AGE_DAYS=14$' "${C}" \
    && ok "conf: SSO_ENABLED=true, ISSUER=https://id.<domain>, POSTURE=mesh, client id, 14-day bound" || bad "conf: $(cat "${C}")"
grep -q '^BRAND_TITLE=Acme Desktops$' "${C}" && ok "conf: brand title sanitized (quotes stripped)" || bad "conf brand: $(grep BRAND "${C}")"
grep -q '^greeter-setup-script=/usr/lib/hugmesh/sso-greeter probe$' "${S}/etc/lightdm/lightdm.conf" \
    && grep -q '^greeter-show-manual-login=true$' "${S}/etc/lightdm/lightdm.conf" \
    && ok "lightdm.conf: greeter-setup-script (hint) + manual login added" || bad "lightdm.conf: $(cat "${S}/etc/lightdm/lightdm.conf")"
[ -f "${S}/etc/hugmesh/desktop-governance/sudo/desktop-sudo-mapper.py.tmpl" ] \
    && [ "$(stat -c %a "${S}/etc/hugmesh/desktop-governance/autostart/session-install.sh.tmpl")" = 755 ] \
    && ok "governance templates baked; session-install executable" || bad "governance templates not baked as expected"
[ "$(stat -c %a "${S}/var/lib/hugmesh/sso-greeter")" = 700 ] && ok "state dir /var/lib/hugmesh/sso-greeter is 0700" || bad "state dir mode"
desktop_sso_bake "${S}" "${REPO}/specs" true acme.example Acme mesh >/dev/null 2>&1
[ "$(grep -c '^greeter-setup-script=' "${S}/etc/lightdm/lightdm.conf")" -eq 1 ] && ok "bake is idempotent (one greeter-setup-script line after two bakes)" || bad "lightdm.conf duplicated lines"
S2="$(mk_sysroot off)"
desktop_sso_bake "${S2}" "${REPO}/specs" false acme.example Acme standalone >/dev/null 2>&1
grep -q '^SSO_ENABLED=false$' "${S2}/etc/hugmesh/sso-greeter.conf" && grep -q '^ISSUER=$' "${S2}/etc/hugmesh/sso-greeter.conf" \
    && grep -q '^POSTURE=standalone$' "${S2}/etc/hugmesh/sso-greeter.conf" && [ ! -e "${S2}/etc/hugmesh/desktop-governance" ] \
    && [ -f "${S2}/etc/pam.d/lightdm" ] && [ -x "${S2}/usr/lib/hugmesh/sso-greeter" ] \
    && ok "bake (SSO off, standalone): stack + helper present, SSO_ENABLED=false, no issuer, NO governance dir (ungoverned)" \
    || bad "bake (SSO off): $(cat "${S2}/etc/hugmesh/sso-greeter.conf"); gov=$([ -e "${S2}/etc/hugmesh/desktop-governance" ] && echo present || echo absent)"
echo "== D2. --sso-issuer and the standalone posture =="
S5="$(mk_sysroot sa-on)"
desktop_sso_bake "${S5}" "${REPO}/specs" true acme.example Acme standalone https://login.tail1234.ts.net/ >"${WORK}/bake5.out" 2>&1
grep -q '^SSO_ENABLED=true$' "${S5}/etc/hugmesh/sso-greeter.conf" && grep -q '^ISSUER=https://login.tail1234.ts.net$' "${S5}/etc/hugmesh/sso-greeter.conf" \
    && grep -q '^POSTURE=standalone$' "${S5}/etc/hugmesh/sso-greeter.conf" \
    && ok "bake (standalone, --sso-issuer): SSO on, the given issuer (trailing / dropped), POSTURE=standalone" \
    || bad "bake (standalone, issuer): $(cat "${S5}/etc/hugmesh/sso-greeter.conf"; cat "${WORK}/bake5.out")"
[ ! -e "${S5}/etc/hugmesh/desktop-governance" ] \
    && ok "bake (standalone, SSO on): NO governance dir — ungoverned, wheel only with the IdP admin role" \
    || bad "bake (standalone, SSO on): governance dir baked (KEYS users would lose wheel with no mapper chain to replace it)"
S6="$(mk_sysroot sa-off-issuer)"
desktop_sso_bake "${S6}" "${REPO}/specs" false acme.example Acme standalone https://id.acme.example >/dev/null 2>&1
grep -q '^SSO_ENABLED=false$' "${S6}/etc/hugmesh/sso-greeter.conf" && grep -q '^ISSUER=https://id.acme.example$' "${S6}/etc/hugmesh/sso-greeter.conf" \
    && ok "bake (SSO off + issuer): the issuer is kept for a later 'sso-greeter configure --enable'" || bad "bake (off+issuer): $(cat "${S6}/etc/hugmesh/sso-greeter.conf")"
for badurl in 'http://id.acme.example' 'https://id.acme.example/?x=1' 'https://user@id.acme.example' "https://id.acme.example
SSO_ENABLED=true"; do
    S7="$(mk_sysroot "bad-issuer-$RANDOM")"
    if desktop_sso_bake "${S7}" "${REPO}/specs" true acme.example Acme mesh "${badurl}" >/dev/null 2>&1; then
        bad "bake accepted --sso-issuer '$(printf '%s' "${badurl}" | tr '\n' ' ')'"
    else
        ok "bake refuses --sso-issuer '$(printf '%s' "${badurl}" | tr '\n' ' ')'"
    fi
done
S3="$(mk_sysroot baddom)"
desktop_sso_bake "${S3}" "${REPO}/specs" true 'acme.example;rm -rf /' Acme mesh >"${WORK}/bake3.out" 2>&1
grep -q '^SSO_ENABLED=false$' "${S3}/etc/hugmesh/sso-greeter.conf" && grep -q 'not a valid hostname' "${WORK}/bake3.out" \
    && ! grep -q 'rm -rf' "${S3}/etc/hugmesh/sso-greeter.conf" && ok "bake: an invalid domain bakes SSO OFF loudly and never interpolates it" \
    || bad "bake: invalid domain: $(cat "${S3}/etc/hugmesh/sso-greeter.conf")"
S4="${WORK}/nolightdm"; mkdir -p "${S4}"
desktop_sso_bake "${S4}" "${REPO}/specs" true acme.example Acme mesh >/dev/null 2>&1 && bad "bake without lightdm.conf succeeded" || ok "bake refuses a sysroot with no lightdm.conf yet (ordering guard)"
desktop_sso_bake "${S}" "${REPO}/specs" maybe acme.example Acme mesh >/dev/null 2>&1 && bad "bake accepted ENABLED=maybe" || ok "bake rejects an ENABLED value that is not true|false"

# ── E. desktop_sso_verify executed ───────────────────────────────────────────
echo "== E. desktop_sso_verify =="
finish_sysroot() {  # what the payload emerge would add
    mkdir -p "$1/usr/bin" "$1/lib64/security"; : > "$1/usr/bin/python3"
    : > "$1/lib64/security/pam_exec.so"; : > "$1/lib64/security/pam_echo.so"
}
finish_sysroot "${S}"
desktop_sso_verify "${S}" >"${WORK}/v.out" 2>&1 && ok "verify: green on the baked + emerged sysroot" || bad "verify red on a good sysroot: $(cat "${WORK}/v.out")"
printf 'auth include system-local-login\n' > "${S}/etc/pam.d/._cfg0000_lightdm"
desktop_sso_verify "${S}" >"${WORK}/v.out" 2>&1 && [ ! -e "${S}/etc/pam.d/._cfg0000_lightdm" ] && grep -q 'removed ._cfg0000_lightdm' "${WORK}/v.out" \
    && ok "verify: removes the package's ._cfg0000_lightdm so etc-update can never swap the stack back" || bad "verify: ._cfg0000_lightdm handling: $(cat "${WORK}/v.out")"
vmut() {  # $1=label $2=command that damages a copy -> verify must go red
    local d="${WORK}/vm-$1"; rm -rf "${d}"; cp -r "${S}" "${d}"
    eval "$2"
    if desktop_sso_verify "${d}" >"${WORK}/vm.out" 2>&1; then bad "verify: $1 => still green"; else ok "verify: $1 => red ($(grep -o 'desktop-sso: [^(—]*' "${WORK}/vm.out" | head -1))"; fi
}
vmut "stock stack swapped in" 'printf "auth include system-local-login\naccount include system-local-login\npassword include system-local-login\nsession include system-local-login\n" > "${d}/etc/pam.d/lightdm"'
vmut "exec line dropped" 'sed -i "/pam_exec.so quiet stdout expose_authtok/d" "${d}/etc/pam.d/lightdm"'
vmut "helper missing" 'rm -f "${d}/usr/lib/hugmesh/sso-greeter"'
vmut "python3 missing" 'rm -f "${d}/usr/bin/python3"'
vmut "pam_echo.so missing" 'rm -f "${d}/lib64/security/pam_echo.so"'
vmut "conf missing" 'rm -f "${d}/etc/hugmesh/sso-greeter.conf"'

# ── F. the stack itself ──────────────────────────────────────────────────────
echo "== F. specs/etc/pam.d/lightdm structure =="
grep -v '^#' "${STACK}" | grep -v '^$' > "${WORK}/stack"
ex="$(grep -n 'pam_exec.so quiet stdout expose_authtok /usr/lib/hugmesh/sso-greeter pam-auth' "${WORK}/stack" | cut -d: -f1)"
inc="$(grep -n '^auth[[:space:]]*include[[:space:]]*system-local-login' "${WORK}/stack" | cut -d: -f1)"
echo_l="$(grep -n '^auth[[:space:]]*optional[[:space:]]*pam_echo.so file=/run/hugmesh/sso-greeter/hint' "${WORK}/stack" | cut -d: -f1)"
[ -n "${ex}" ] && [ -n "${inc}" ] && [ -n "${echo_l}" ] && [ "${echo_l}" -lt "${ex}" ] && [ "${ex}" -lt "${inc}" ] \
    && ok "auth order: pam_echo hint, then the SSO exec line, then include system-local-login" || bad "auth order wrong (echo=${echo_l} exec=${ex} include=${inc})"
grep -q '^auth[[:space:]]*\[success=done default=ignore\][[:space:]]*pam_exec.so' "${WORK}/stack" \
    && ok "exec control is [success=done default=ignore] (SSO success ends auth; anything else is ignored)" || bad "exec control wrong"
sinc="$(grep -n '^session[[:space:]]*include[[:space:]]*system-local-login' "${WORK}/stack" | cut -d: -f1)"
sex="$(grep -n '^session[[:space:]]*optional[[:space:]]*pam_exec.so quiet /usr/lib/hugmesh/sso-greeter pam-session' "${WORK}/stack" | cut -d: -f1)"
[ -n "${sinc}" ] && [ -n "${sex}" ] && [ "${sinc}" -lt "${sex}" ] && ok "session hand-off line follows the session include (after pam_elogind)" || bad "session hand-off ordering wrong"
grep -Eq 'success=[0-9]' "${WORK}/stack" && bad "stack carries a numeric success=N jump" || ok "no numeric success=N jumps in the stack"
for t in account password; do grep -q "^${t}[[:space:]]*include[[:space:]]*system-local-login" "${WORK}/stack" && ok "${t} stack still includes system-local-login" || bad "${t} include missing"; done
grep -q 'hugmesh-sso-greeter-stack' "${STACK}" && ok "stack carries the survival marker the builders assert" || bad "marker missing"
# the helper's hint path and the stack's pam_echo path agree
grep -q 'RUN_DIR = seam("HSG_RUN_DIR", "/run/hugmesh/sso-greeter")' "${HELPER}" && grep -q 'HINT_FILE = os.path.join(RUN_DIR, "hint")' "${HELPER}" \
    && ok "helper hint path == pam_echo file path (/run/hugmesh/sso-greeter/hint)" || bad "hint path drift between helper and stack"

# ── G. negative controls over the static pins ────────────────────────────────
echo "== G. negative controls (each plant must change the file and go red) =="
control() {  # $1=label $2=src $3=sed-expr $4=pin-function  -> at least one FAIL from the pin function
    local m="${WORK}/ctl-$1"
    sed -e "$3" "$2" > "${m}"
    if cmp -s "$2" "${m}"; then bad "control $1: plant changed nothing"; return; fi
    local out; out="$("$4" "${m}" 2>&1)"
    grep -q 'FAIL' <<< "${out}" && ok "control $1: the pins go red" || bad "control $1: pins stayed green over the mutated copy"
}
# run the pin functions silently inside control(): they print PASS/FAIL lines we only grep
pin_x86_q(){ P=0; F=0; pin_x86 "$1"; }
pin_frite_q(){ P=0; F=0; pin_frite "$1"; }
pin_list_q(){ P=0; F=0; pin_list "$1"; }
pin_prov_q(){ P=0; F=0; pin_prov "$1"; }
control x86-no-bake "${X86}" '/desktop_sso_bake "\${SYSROOT}"/,/|| { err "greeter SSO bake failed/d' pin_x86_q
control x86-no-verify "${X86}" '/desktop_sso_verify "\${SYSROOT}"/d' pin_x86_q
control frite-no-flag "${FRITE}" '/--skip-sso|--no-sso)/d' pin_frite_q
control frite-standalone-rule "${FRITE}" '/\[ "\${SSO_FORCED}" = on \] || SKIP_SSO=true/d' pin_frite_q
control frite-no-verify "${FRITE}" '/desktop_sso_verify "\${SYSROOT}"/d' pin_frite_q
control frite-no-issuer-flag "${FRITE}" '/--sso-issuer)/d' pin_frite_q
control x86-no-issuer-arg "${X86}" 's/echo mesh)" "\${SSO_ISSUER}"/echo mesh)"/' pin_x86_q
pin_arm_q(){ P=0; F=0; pin_arm "$1"; }
for b in "${ARM_DESKTOP_BUILDERS[@]}"; do
    n="${b#build-}"; n="${n%-stage4.sh}"
    control "${n}-no-bake" "${REPO}/${b}" '/desktop_sso_bake "\${SYSROOT}"/,/|| { err "greeter SSO bake failed/d' pin_arm_q
    control "${n}-no-verify" "${REPO}/${b}" '/desktop_sso_verify "\${SYSROOT}"/d' pin_arm_q
    control "${n}-standalone-rule" "${REPO}/${b}" '/\[ "\${SSO_FORCED}" = on \] || SKIP_SSO=true/d' pin_arm_q
done
control list-no-polkit "${FRITE_LIST}" '/^sys-auth\/polkit$/d' pin_list_q
control prov-no-install "${PROV}" '/session-install\.sh\.tmpl"; then/d' pin_prov_q

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
