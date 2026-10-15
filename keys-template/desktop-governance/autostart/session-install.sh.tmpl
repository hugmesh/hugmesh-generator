#!/usr/bin/env bash
# session-install.sh (TEMPLATE) -> KEYS/desktop-governance/session-install.sh
#
# GEN-SSO deployment glue (the NO-provision.sh-edit vector). provision.sh's
# provision_desktop_governance() render_gov's only its 4 NAMED templates and has
# no generic loop, no /etc/xdg/autostart handling, and editing it is out of scope.
# So this self-contained hook renders the GEN-SSO templates (incl. the token producer) and
# publishes the XDG autostart entry, run AS ROOT at end of first boot by
# keys-provision's provision_run_hooks() (KEYS_BASE exported) AFTER
# provision_desktop_governance() has run. Wire via KEYS provision.json:
#     "run": [ "desktop-governance/session-install.sh" ]
#
# @@CLUSTER_DOMAIN@@ in this header is a harmless comment (the running copy at the
# KEYS root keeps the placeholder only here). Domain is resolved at runtime below
# with the SAME precedence + fail-closed validation + sed-escape as provision.sh.
#
# IDEMPOTENT + GOVERNED-GATED + FAIL-CLOSED:
#   * ungoverned image (no baked /etc/hugmesh/desktop-governance and no
#     KEYS/desktop-governance/) => render NOTHING, publish nothing, exit 0.
#   * no resolvable domain OR a domain that is not a valid hostname => refuse to
#     render (exit 0, ships-dark) — never emit a corrupted/injected config.
#   * safe to re-run: overwrites its own outputs deterministically.
set -uo pipefail

log()  { printf 'session-install: %s\n' "$*"; }
warn() { printf 'session-install: WARN %s\n' "$*" >&2; }

# Where the GEN-SSO templates live. Prefer the baked sysroot copy; fall back to
# the KEYS USB dir (KEYS_BASE exported by provision_run_hooks; this script's own
# dir as a last resort when run by hand).
GOV_DST="/etc/hugmesh/desktop-governance"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=""
for cand in \
    "/etc/hugmesh/desktop-governance" \
    "${KEYS_BASE:-}/desktop-governance" \
    "${SELF_DIR}" ; do
    [ -n "${cand}" ] || continue
    if [ -f "${cand}/discover/oidc-token-deposit.sh.tmpl" ] \
       || [ -f "${cand}/autostart/hugmesh-desktop-sso.desktop.tmpl" ]; then
        SRC="${cand}"; break
    fi
done

# is_governed(): mirrors provision.sh desktop_governance_governed() — the image is
# governed iff it carries the desktop-governance config dir (baked or on KEYS).
is_governed() {
    [ -d /etc/hugmesh/desktop-governance ] && return 0
    [ -n "${KEYS_BASE:-}" ] && [ -d "${KEYS_BASE}/desktop-governance" ] && return 0
    return 1
}

if ! is_governed; then
    log "ungoverned image (no desktop-governance dir baked or on KEYS) — nothing to install (ships-dark)"
    exit 0
fi
if [ -z "${SRC}" ]; then
    warn "GEN-SSO templates not found (baked / KEYS / self) — nothing to render (ships-dark)"
    exit 0
fi

# ── Resolve this node's OWN domain — SAME precedence as provision.sh:
#    manifest .client.primary_domain (via provision-resolved /etc/hugmesh/domains
#    here, since we run post-provision) -> first non-blank line of
#    /etc/hugmesh/domains -> none. We read the domains marker provision wrote.
dom=""
if [ -r /etc/hugmesh/domains ]; then
    dom="$(grep -m1 -v '^[[:space:]]*$' /etc/hugmesh/domains 2>/dev/null | tr -d '[:space:]')"
fi
# Fallback: derive from the rendered Discover remote (api.<domain>/...) so we
# track exactly the domain provision_desktop_governance() used.
if [ -z "${dom}" ] && [ -r /etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo ]; then
    dom="$(sed -n 's#^Url=https://api\.\([a-z0-9.-]*\)/bff/desktop/registry/.*#\1#p' \
            /etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo 2>/dev/null | head -n1)"
fi

if [ -z "${dom}" ]; then
    warn "no resolvable node domain (/etc/hugmesh/domains / rendered remote) — refusing to render (ships-dark, no autostart)"
    exit 0
fi

# FAIL-CLOSED hostname validation — IDENTICAL to provision.sh: anchored whole
# string [a-z0-9.-] only. Rejects sed metachars (/ & \) and embedded newlines so a
# malformed/injected domain renders nothing rather than a corrupted config.
if [[ ! "${dom}" =~ ^[a-z0-9.-]+$ ]]; then
    warn "node domain is not a valid hostname ([a-z0-9.-]) — refusing to render (ships-dark, no autostart)"
    exit 0
fi
log "installing GEN-SSO session-start for domain ${dom} (src ${SRC})"

# Same sed-metacharacter escape as provision.sh render_gov (defense-in-depth; with
# the strict validator above this only ever escapes the harmless . / -).
dom_esc="$(printf '%s' "${dom}" | sed 's/[&/\]/\\&/g')"

render() {  # $1=src-tmpl  $2=dst  $3=mode
    local src="$1" dst="$2" mode="$3"
    [ -f "${src}" ] || { warn "template missing: ${src}"; return 1; }
    mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
    sed "s/@@CLUSTER_DOMAIN@@/${dom_esc}/g" "${src}" > "${dst}" || { warn "render failed: ${dst}"; return 1; }
    chmod "${mode}" "${dst}" 2>/dev/null || true
    chown root:root "${dst}" 2>/dev/null || true
    log "rendered ${dst} (mode ${mode})"
}

# Render the two helper scripts into the writable governance dir.
render "${SRC}/discover/oidc-token-deposit.sh.tmpl" \
       "${GOV_DST}/oidc-token-deposit.sh" 0755 || exit 0
render "${SRC}/autostart/hugmesh-desktop-sso-start.sh.tmpl" \
       "${GOV_DST}/hugmesh-desktop-sso-start.sh" 0755 || exit 0

# The token PRODUCER (RFC 8628 device flow). Run by the session wrapper; optional
# so a KEYS dir from before the producer existed still installs the rest.
if [ -f "${SRC}/sso/hugmesh-sso-token.py.tmpl" ]; then
    render "${SRC}/sso/hugmesh-sso-token.py.tmpl" \
           "${GOV_DST}/hugmesh-sso-token" 0755 || exit 0
else
    warn "sso/hugmesh-sso-token.py.tmpl not found in ${SRC} — no token producer installed (deposit stays inert)"
fi

# Publish the XDG autostart entry honored by LXDE + XFCE (no OnlyShowIn).
render "${SRC}/autostart/hugmesh-desktop-sso.desktop.tmpl" \
       "/etc/xdg/autostart/hugmesh-desktop-sso.desktop" 0644 || exit 0

log "done — autostart published; bearer-forward now has a token depositor + a session-start invoker"
exit 0
