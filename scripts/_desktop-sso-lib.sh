#!/usr/bin/env bash
# _desktop-sso-lib.sh — bake the greeter SSO login path into a desktop sysroot.
#
# Sourced by the desktop builders (build-x86-host-stage4.sh client roles,
# build-frite-stage4.sh --desktop light; the other ARM desktop builders call the
# same two functions when they adopt it). Two entry points:
#
#   desktop_sso_bake SYSROOT SHARED_SPECS ENABLED DOMAIN BRAND_TITLE POSTURE [ISSUER]
#       Run BEFORE the payload emerge (CONFIG_PROTECT then keeps our
#       /etc/pam.d/lightdm over the package's). Installs:
#         /usr/lib/hugmesh/sso-greeter        the PAM helper (specs/usr/lib/hugmesh)
#         /etc/pam.d/lightdm                  the stack with the SSO line in front
#         /etc/hugmesh/sso-greeter.conf       SSO_ENABLED / ISSUER / posture
#         /etc/lightdm/lightdm.conf           += greeter-setup-script (hint),
#                                                greeter-show-manual-login (a new
#                                                SSO user types their name)
#         /etc/hugmesh/desktop-governance/    the governance templates, baked
#                                             (ENABLED and POSTURE=mesh only:
#                                             baking the dir is what makes
#                                             provisioning treat the image as
#                                             GOVERNED — sudo via the desktop-sudo
#                                             claim, wheel stripped from KEYS users.
#                                             A standalone image has no KEYS chain
#                                             to run the mapper, so it stays
#                                             ungoverned: an SSO user gets wheel
#                                             only with the IdP admin role.)
#       ENABLED=false (--skip-sso) bakes the stack and the helper with
#       SSO_ENABLED=false: the greeter then SAYS SSO is off (and how an admin turns
#       it on: `sso-greeter configure`) and the local path is untouched; nothing
#       is ever contacted. No governance dir => ungoverned.
#       ISSUER (optional, --sso-issuer): the IdP URL, https only; default
#       https://id.<DOMAIN>. Given with ENABLED=false it is still written, so an
#       admin's later `sso-greeter configure --enable` has it.
#
#   desktop_sso_verify SYSROOT
#       Run AFTER the payload emerge. Fails (return 1) when the stack lost its
#       marker (a package overwrote it), when the helper, its interpreter
#       (python3) or the two stock PAM modules it rides on are missing. Parks
#       nothing: a ._cfg0000_lightdm the package left is removed so no
#       etc-update ever swaps the stack back.
#
# Pure sysroot file operations: no chroot, no emerge, no network. Safe under
# `set -euo pipefail`; bash 5.3-safe (no `local a=$1 b=$a`).

_dsso_say() { if declare -F info >/dev/null 2>&1; then info "$@"; else printf '[desktop-sso] %s\n' "$*"; fi; }
_dsso_err() { if declare -F err >/dev/null 2>&1; then err "$@"; else printf '[desktop-sso] ERROR: %s\n' "$*" >&2; fi; }
_dsso_warn() { if declare -F warn >/dev/null 2>&1; then warn "$@"; else printf '[desktop-sso] WARN: %s\n' "$*" >&2; fi; }

DESKTOP_SSO_MARKER="hugmesh-sso-greeter-stack"

desktop_sso_bake() {
    local sysroot="$1" shared="$2" enabled="$3" domain="$4" brand_title="$5" posture="$6"
    local issuer_override="${7:-}"
    local helper_src pam_src conf issuer
    helper_src="${shared}/usr/lib/hugmesh/sso-greeter"
    pam_src="${shared}/etc/pam.d/lightdm"
    [ -f "${helper_src}" ] || { _dsso_err "desktop-sso: helper missing: ${helper_src}"; return 1; }
    [ -f "${pam_src}" ] || { _dsso_err "desktop-sso: PAM stack missing: ${pam_src}"; return 1; }
    [ -f "${sysroot}/etc/lightdm/lightdm.conf" ] || { _dsso_err "desktop-sso: ${sysroot}/etc/lightdm/lightdm.conf not written yet (bake after the lightdm.conf heredoc)"; return 1; }
    case "${enabled}" in true|false) ;; *) _dsso_err "desktop-sso: ENABLED must be true|false (got '${enabled}')"; return 1 ;; esac
    case "${posture}" in mesh|standalone) ;; *) _dsso_err "desktop-sso: POSTURE must be mesh|standalone (got '${posture}')"; return 1 ;; esac

    # The issuer is the per-domain IdP. A domain that is not a plain hostname
    # cannot be an https host and must not be interpolated: bake SSO off, loudly.
    issuer=""
    if [ -n "${issuer_override}" ]; then
        # https://HOST[:PORT][/PATH], nothing a KEY=VALUE line or a URL could be
        # bent by (no quotes, spaces, '?', '#', '@').
        if [[ "${issuer_override}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
            issuer="${issuer_override%/}"
        else
            _dsso_err "desktop-sso: --sso-issuer must be https://HOST[:PORT][/PATH] (got '${issuer_override}')"
            return 1
        fi
    elif [ "${enabled}" = true ]; then
        if [[ "${domain}" =~ ^[a-z0-9.-]+$ ]]; then
            issuer="https://id.${domain}"
        else
            _dsso_warn "desktop-sso: cluster domain '${domain}' is not a valid hostname — baking SSO_ENABLED=false"
            enabled=false
        fi
    fi
    # The brand title is shown on the greeter hint; one printable line, no quotes.
    brand_title="$(printf '%s' "${brand_title}" | tr -d '\n\r"'"'" | tr -c '[:print:]' ' ')"
    [ -n "${brand_title}" ] || brand_title="HugMesh"

    mkdir -p "${sysroot}/usr/lib/hugmesh" "${sysroot}/etc/pam.d" "${sysroot}/etc/hugmesh" \
             "${sysroot}/var/lib/hugmesh/sso-greeter"
    chmod 0700 "${sysroot}/var/lib/hugmesh/sso-greeter"
    cp "${helper_src}" "${sysroot}/usr/lib/hugmesh/sso-greeter"
    chmod 0755 "${sysroot}/usr/lib/hugmesh/sso-greeter"
    cp "${pam_src}" "${sysroot}/etc/pam.d/lightdm"
    chmod 0644 "${sysroot}/etc/pam.d/lightdm"

    conf="${sysroot}/etc/hugmesh/sso-greeter.conf"
    {
        printf '# Written by the image builder (scripts/_desktop-sso-lib.sh). Read by\n'
        printf '# /usr/lib/hugmesh/sso-greeter at every greeter sign-in. Strict KEY=VALUE.\n'
        printf 'SSO_ENABLED=%s\n' "${enabled}"
        printf 'ISSUER=%s\n' "${issuer}"
        printf 'CLIENT_ID=hugmesh-desktop\n'
        printf 'BRAND_TITLE=%s\n' "${brand_title}"
        printf 'OFFLINE_MAX_AGE_DAYS=14\n'
        printf 'ADMIN_ROLE=desktop-admin\n'
        printf 'LOGIN_TIMEOUT=180\n'
        printf 'CONNECT_TIMEOUT=5\n'
        printf 'POSTURE=%s\n' "${posture}"
    } > "${conf}"
    chmod 0644 "${conf}"

    # lightdm.conf: the hint writer runs as root each time a greeter starts, and
    # a user the image has never seen (first SSO sign-in) needs a name box.
    if ! grep -q '^greeter-setup-script=' "${sysroot}/etc/lightdm/lightdm.conf"; then
        {
            printf 'greeter-setup-script=/usr/lib/hugmesh/sso-greeter probe\n'
            printf 'greeter-show-manual-login=true\n'
        } >> "${sysroot}/etc/lightdm/lightdm.conf"
    fi

    if [ "${enabled}" = true ] && [ "${posture}" = mesh ]; then
        [ -d "${shared}/etc/hugmesh/desktop-governance" ] \
            || { _dsso_err "desktop-sso: governance templates missing: ${shared}/etc/hugmesh/desktop-governance"; return 1; }
        rm -rf "${sysroot}/etc/hugmesh/desktop-governance"
        cp -r "${shared}/etc/hugmesh/desktop-governance" "${sysroot}/etc/hugmesh/desktop-governance"
        find "${sysroot}/etc/hugmesh/desktop-governance" -type d -exec chmod 0755 {} +
        find "${sysroot}/etc/hugmesh/desktop-governance" -type f -exec chmod 0644 {} +
        chmod 0755 "${sysroot}/etc/hugmesh/desktop-governance/autostart/session-install.sh.tmpl"
        _dsso_say "desktop-sso: greeter SSO ON (issuer ${issuer}, posture ${posture}); governance templates baked (image is GOVERNED: sudo via the desktop-sudo claim)"
    elif [ "${enabled}" = true ]; then
        rm -rf "${sysroot}/etc/hugmesh/desktop-governance"
        _dsso_say "desktop-sso: greeter SSO ON (issuer ${issuer}, posture standalone); no governance dir (ungoverned: wheel only for the IdP's desktop-admin role)"
    else
        rm -rf "${sysroot}/etc/hugmesh/desktop-governance"
        _dsso_say "desktop-sso: greeter SSO OFF (--skip-sso); stack baked so the greeter says so (sso-greeter configure turns it on later); no governance dir (ungoverned: wheel sudo stays)"
    fi
    return 0
}

desktop_sso_verify() {
    local sysroot="$1" pamf rc=0 cfg
    pamf="${sysroot}/etc/pam.d/lightdm"
    if ! grep -q "${DESKTOP_SSO_MARKER}" "${pamf}" 2>/dev/null; then
        _dsso_err "desktop-sso: ${pamf} lost the HugMesh stack (marker ${DESKTOP_SSO_MARKER} absent) — a package overwrote it; the greeter would have no SSO path"
        rc=1
    elif ! grep -q 'pam_exec\.so quiet stdout expose_authtok /usr/lib/hugmesh/sso-greeter pam-auth' "${pamf}"; then
        _dsso_err "desktop-sso: ${pamf} carries the marker but not the exec line"
        rc=1
    fi
    for cfg in "${sysroot}"/etc/pam.d/._cfg????_lightdm; do
        [ -e "${cfg}" ] || continue
        rm -f "${cfg}"
        _dsso_say "desktop-sso: removed ${cfg##*/} (the package's stack parked by CONFIG_PROTECT; ours stays)"
    done
    [ -x "${sysroot}/usr/lib/hugmesh/sso-greeter" ] || { _dsso_err "desktop-sso: helper missing or not executable in the sysroot"; rc=1; }
    [ -f "${sysroot}/etc/hugmesh/sso-greeter.conf" ] || { _dsso_err "desktop-sso: /etc/hugmesh/sso-greeter.conf missing in the sysroot"; rc=1; }
    [ -e "${sysroot}/usr/bin/python3" ] || { _dsso_err "desktop-sso: /usr/bin/python3 missing in the sysroot (the helper is python3; declare dev-lang/python in the desktop package list)"; rc=1; }
    local mod found
    for mod in pam_exec.so pam_echo.so; do
        found=""
        for cfg in "${sysroot}/lib/security/${mod}" "${sysroot}/lib64/security/${mod}" \
                   "${sysroot}/usr/lib/security/${mod}" "${sysroot}/usr/lib64/security/${mod}"; do
            [ -e "${cfg}" ] && { found=1; break; }
        done
        [ -n "${found}" ] || { _dsso_err "desktop-sso: ${mod} missing in the sysroot (sys-libs/pam ships it; the greeter stack needs it)"; rc=1; }
    done
    [ "${rc}" -eq 0 ] && _dsso_say "desktop-sso: verified — /etc/pam.d/lightdm carries the SSO stack, helper + python3 + pam_exec/pam_echo present"
    return "${rc}"
}
