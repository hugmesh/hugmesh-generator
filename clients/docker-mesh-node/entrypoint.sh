#!/usr/bin/env bash
# HugMesh docker mesh-node entrypoint (FD-09): join the HugMesh tailnet using
# LOCAL FILE KEYS, perform a one-line Casdoor login, and run as a background mesh
# node. No OS flash — this is the THIRD onboarding form (alongside appliance images
# and client desktops). Honors the register-and-approve node-admission flow: a
# freshly-registered node stays PENDING until a superadmin approves it.
#
# Keys (mounted read-only at /keys, mirrors the KEYS-USB layout the appliance images
# consume — see specs/etc/keys-provision):
#   /keys/tailscale/authkey   one-time pre-auth key (or /keys/authkey)
#   /keys/login-server        headscale control URL (optional; else $SNAP_LOGIN_SERVER)
#   /keys/casdoor.json        { "issuer": "...", "client_id": "...", "domain": "..." }  (optional)
#   /keys/role                user|mod|admin|superadmin  (or $SNAP_ROLE; default user)
set -euo pipefail
log() { printf '[mesh-node %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

KEYS="${SNAP_KEYS_DIR:-/keys}"
STATE_DIR="${SNAP_STATE_DIR:-/var/lib/tailscale}"
ROLE="${SNAP_ROLE:-}"; [ -z "${ROLE}" ] && [ -f "${KEYS}/role" ] && ROLE="$(tr -d ' \n' < "${KEYS}/role")"
ROLE="${ROLE:-user}"
HOSTNAME_TS="${SNAP_HOSTNAME:-hugmesh-meshnode-$(hostname | tr -cd 'a-z0-9-' | cut -c1-20)}"

# ── Resolve the pre-auth key (local file keys) ──────────────────────
AUTHKEY="${SNAP_AUTHKEY:-}"
for f in "${KEYS}/tailscale/authkey" "${KEYS}/authkey"; do
    [ -z "${AUTHKEY}" ] && [ -f "${f}" ] && AUTHKEY="$(tr -d ' \n' < "${f}")"
done
[ -n "${AUTHKEY}" ] || { log "FATAL: no pre-auth key (mount it at ${KEYS}/tailscale/authkey or set SNAP_AUTHKEY)"; exit 1; }

# ── Resolve the headscale control server ────────────────────────────
LOGIN_SERVER="${SNAP_LOGIN_SERVER:-}"
[ -z "${LOGIN_SERVER}" ] && [ -f "${KEYS}/login-server" ] && LOGIN_SERVER="$(tr -d ' \n' < "${KEYS}/login-server")"

# ── TUN vs userspace networking ─────────────────────────────────────
# Kernel TUN gives full mesh routing; without /dev/net/tun (common on Docker
# Desktop / locked-down hosts) fall back to userspace-networking, which still
# joins the tailnet (SOCKS/HTTP proxy + Tailscale SSH) for the onboarding use case.
TS_TUN_ARGS=()
if [ -c /dev/net/tun ]; then
    log "kernel TUN present — full tailnet routing"
else
    log "no /dev/net/tun — using userspace networking (tailnet reachable; no kernel routes)"
    TS_TUN_ARGS=(--tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055)
fi

mkdir -p "${STATE_DIR}"
log "starting tailscaled (state=${STATE_DIR}, role=${ROLE}, hostname=${HOSTNAME_TS})"
tailscaled --state="${STATE_DIR}/tailscaled.state" --socket=/var/run/tailscale/tailscaled.sock "${TS_TUN_ARGS[@]}" &
TSD_PID=$!
# Wait for the daemon socket.
for _ in $(seq 1 30); do [ -S /var/run/tailscale/tailscaled.sock ] && break; sleep 0.5; done

# ── Join the mesh (register; one-time authkey per SEC-08) ───────────
UP=(tailscale up --authkey "${AUTHKEY}" --hostname "${HOSTNAME_TS}" --ssh --accept-dns=true)
[ -n "${LOGIN_SERVER}" ] && UP+=(--login-server "${LOGIN_SERVER}")
log "joining mesh: tailscale up${LOGIN_SERVER:+ --login-server ${LOGIN_SERVER}} --hostname ${HOSTNAME_TS} --ssh"
if "${UP[@]}"; then
    log "mesh JOINED + approved."
else
    # register-and-approve: the node registered but is not yet admitted. Stay up;
    # tailscaled keeps retrying and the node becomes reachable once the superadmin
    # approves it (ADR-14 mesh-join latch + admission).
    log "registered but NOT yet approved — AWAITING superadmin node-admission. tailscaled will keep retrying."
fi
tailscale status --self --peers=false 2>/dev/null || true

# ── One-line Casdoor login (OIDC device-code) ───────────────────────
casdoor_login() {
    local cj="${KEYS}/casdoor.json"
    [ -f "${cj}" ] || { log "no casdoor.json — skipping Casdoor login (mesh join only)"; return 0; }
    local issuer client_id domain
    issuer="$(jq -r '.issuer // empty' "${cj}")"
    client_id="$(jq -r '.client_id // empty' "${cj}")"
    domain="$(jq -r '.domain // empty' "${cj}")"
    [ -n "${issuer}" ] && [ -n "${client_id}" ] || { log "casdoor.json missing issuer/client_id — skipping"; return 0; }
    local disc dae te
    disc="$(curl -fsS "${issuer%/}/.well-known/openid-configuration" 2>/dev/null || true)"
    dae="$(printf '%s' "${disc}" | jq -r '.device_authorization_endpoint // empty' 2>/dev/null)"
    te="$(printf '%s' "${disc}" | jq -r '.token_endpoint // empty' 2>/dev/null)"
    if [ -z "${dae}" ]; then
        # No device flow advertised — print the browser auth URL (open over the tailnet).
        log "Casdoor: open this URL over the tailnet to sign in:"
        log "   ${issuer%/}/login/oauth/authorize?client_id=${client_id}&response_type=code&scope=openid+profile&redirect_uri=urn:ietf:wg:oauth:2.0:oob"
        return 0
    fi
    local resp dc uc vu interval
    resp="$(curl -fsS -X POST "${dae}" -d "client_id=${client_id}" -d "scope=openid profile" 2>/dev/null || true)"
    dc="$(printf '%s' "${resp}" | jq -r '.device_code // empty')"
    uc="$(printf '%s' "${resp}" | jq -r '.user_code // empty')"
    vu="$(printf '%s' "${resp}" | jq -r '.verification_uri_complete // .verification_uri // empty')"
    interval="$(printf '%s' "${resp}" | jq -r '.interval // 5')"
    [ -n "${dc}" ] || { log "Casdoor device-code request failed; skipping login"; return 0; }
    log "════════════ ONE-LINE CASDOOR LOGIN ════════════"
    log "  Open: ${vu}"
    log "  Code: ${uc}"
    log "═════════════════════════════════════════════════"
    # Poll for the token (best-effort; the mesh node keeps running regardless).
    for _ in $(seq 1 60); do
        sleep "${interval}"
        local tr err
        tr="$(curl -fsS -X POST "${te}" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" -d "device_code=${dc}" -d "client_id=${client_id}" 2>/dev/null || true)"
        err="$(printf '%s' "${tr}" | jq -r '.error // empty')"
        if printf '%s' "${tr}" | jq -e '.access_token' >/dev/null 2>&1; then
            log "Casdoor login OK (role=${ROLE})."
            return 0
        fi
        [ "${err}" = "authorization_pending" ] || [ "${err}" = "slow_down" ] || { [ -n "${err}" ] && { log "Casdoor: ${err}"; return 0; }; }
    done
    log "Casdoor login still pending (timed out waiting) — re-open the URL above."
}
casdoor_login || true

# ── superadmin: point at the tailnet-only superadmin UI (ADR-17) ────
if [ "${ROLE}" = "superadmin" ]; then
    dom="$(jq -r '.domain // empty' "${KEYS}/casdoor.json" 2>/dev/null || true)"
    if [ -n "${dom}" ]; then
        log "SUPERADMIN: open the tailnet-only superadmin UI:  https://superadmin.${dom}/"
        log "            (reachable only over this mesh; no public forward — ADR-17)"
    else
        log "SUPERADMIN: superadmin UI is at https://superadmin.<your-domain>/ over the tailnet."
    fi
fi

log "mesh-node up — running in background. Ctrl-C / 'docker stop' to leave the mesh."
# Keep PID 1 alive on tailscaled; exit (and let the container restart) if it dies.
wait "${TSD_PID}"
