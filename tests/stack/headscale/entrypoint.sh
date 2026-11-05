#!/usr/bin/env bash
# hugmesh-headscale entrypoint — the local docker mesh's tailnet control server
# (compose service `hugmesh-headscale`, profile `headscale`, `make stack-up HEADSCALE=1`).
#
# In order:
#   1. Render /etc/headscale/config.yaml from config.yaml.tmpl:
#      server_url https://hs.<HUGMESH_DOMAIN>:<PUBLIC_HTTPS_PORT> (the HTTPS front
#      door's hs. virtual host; that is the login server a token names).
#   2. Render /etc/headscale/policy.hujson from the DEVICE template,
#      specs/etc/headscale/policy.hujson.tmpl, mounted read-only. Its two splice
#      markers get what specs/usr/sbin/gen-headscale-policy.sh gives a node whose
#      signed export is empty: in ssh[] ONLY the always-emitted superadmin rule
#      (src tag:superadmin -> dst tag:mesh_<mesh id>), and ONE dynamic tag owner,
#      "tag:mesh_<mesh id>": [] (an empty owner list; render_policy says why it
#      is needed). So the static tagOwners are literally the device's, and a fix
#      to that template reaches this mesh on the next start.
#   3. `headscale configtest`, then `headscale serve` in the background and wait
#      for its unix socket to answer.
#   4. Create the user `hugmesh` if it is missing (the tagOwners above name it).
#   5. Keep admin-bff's API key in /run/hugmesh-headscale/admin-bff.apikey (the
#      headscale-admin-key volume; admin-bff mounts it read-only). A new key is
#      created when the file is missing, when headscale no longer lists its
#      prefix, or when it expires within HEADSCALE_APIKEY_RENEW_DAYS (30); it is
#      written 0600 to a temp file and renamed into place, and only then is the
#      old key expired. The key is NEVER printed: not here, not by `set -x`
#      (nothing in this file enables it), not in an error message.
#
# Every value that lands in the config or the policy is checked against a strict
# character set first, so no substitution below needs escaping.
#
# Paths a test can point elsewhere (tests/stack/test-headscale-local.sh renders
# with HUGMESH_HS_RENDER_ONLY=1 and no headscale binary): HUGMESH_HS_CONFIG_TMPL,
# HUGMESH_HS_POLICY_TMPL, HUGMESH_HS_CONFIG_OUT, HUGMESH_HS_POLICY_OUT. Their
# defaults are the container paths; compose sets none of them.
#
# bash 5.3: every name is declared on its own line before it is assigned (a
# `local a=$1 b=$a` list dies under set -u there), and no `| grep -q` sits
# under pipefail (SIGPIPE turns a found match into a failure).
set -euo pipefail
umask 077

HS_BIN="${HUGMESH_HS_BIN:-/usr/local/bin/headscale}"
CONFIG_TMPL="${HUGMESH_HS_CONFIG_TMPL:-/etc/hugmesh/headscale/config.yaml.tmpl}"
POLICY_TMPL="${HUGMESH_HS_POLICY_TMPL:-/etc/hugmesh/headscale/policy.hujson.tmpl}"
CONFIG_OUT="${HUGMESH_HS_CONFIG_OUT:-/etc/headscale/config.yaml}"
POLICY_OUT="${HUGMESH_HS_POLICY_OUT:-/etc/headscale/policy.hujson}"
KEY_DIR=/run/hugmesh-headscale
KEY_FILE="${KEY_DIR}/admin-bff.apikey"
SOCKET=/run/headscale/headscale.sock
HS_USER=hugmesh

log() { printf 'hugmesh-headscale: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ── inputs ───────────────────────────────────────────────────────────────────
DOMAIN="${HUGMESH_DOMAIN:-hugmesh.net}"
PORT="${PUBLIC_HTTPS_PORT:-8488}"
MESH_ID="${HEADSCALE_MESH_ID:-hugmesh-local}"
SSH_USER="${HEADSCALE_SSH_USER:-admin}"
RENEW_DAYS="${HEADSCALE_APIKEY_RENEW_DAYS:-30}"

[[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] \
    || die "HUGMESH_DOMAIN '${DOMAIN}' is not a lower-case DNS name with at least two labels"
[[ "${PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "${PORT}" -le 65535 ] \
    || die "PUBLIC_HTTPS_PORT '${PORT}' is not a port number"
[[ "${MESH_ID}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] \
    || die "HEADSCALE_MESH_ID '${MESH_ID}' must match ^[a-z0-9][a-z0-9-]{0,62}\$"
[[ "${SSH_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "HEADSCALE_SSH_USER '${SSH_USER}' is not a plain user name"
# 90 (the key's whole lifetime) means "replace the key at every start".
[[ "${RENEW_DAYS}" =~ ^[0-9]{1,2}$ ]] && [ "${RENEW_DAYS}" -le 90 ] \
    || die "HEADSCALE_APIKEY_RENEW_DAYS '${RENEW_DAYS}' must be 0..90 (the key lives 90 days)"

SERVER_URL="https://hs.${DOMAIN}:${PORT}"
MESH_TAG="tag:mesh_${MESH_ID}"

# ── 1. config ────────────────────────────────────────────────────────────────
render_config() {
    local out_tmp
    [ -r "${CONFIG_TMPL}" ] || die "config template ${CONFIG_TMPL} is missing"
    mkdir -p "$(dirname "${CONFIG_OUT}")"
    out_tmp="${CONFIG_OUT}.tmp.$$"
    HS_SERVER_URL="${SERVER_URL}" awk '
        { line = $0; gsub(/@@HS_SERVER_URL@@/, ENVIRON["HS_SERVER_URL"], line); print line }
    ' "${CONFIG_TMPL}" > "${out_tmp}"
    if grep -n '@@' "${out_tmp}" >/dev/null; then
        rm -f "${out_tmp}"; die "rendered config still holds an @@ marker"
    fi
    chmod 0644 "${out_tmp}"
    mv -f "${out_tmp}" "${CONFIG_OUT}"
}

# ── 2. policy ────────────────────────────────────────────────────────────────
# The splice is the node renderer's (gen-headscale-policy.sh render_policy) for
# an export with no operators: the tagOwners suffix is empty and the ssh body is
# the superadmin edge alone, encoded with `jq -cn` exactly as the node does it.
render_policy() {
    local out_tmp
    local sup_edge
    local ssh_splice
    local to_suffix
    [ -r "${POLICY_TMPL}" ] || die "policy template ${POLICY_TMPL} is missing (compose mounts specs/etc/headscale/policy.hujson.tmpl)"
    mkdir -p "$(dirname "${POLICY_OUT}")"
    sup_edge="$(jq -cn --arg sshuser "${SSH_USER}" --arg meshtag "${MESH_TAG}" \
        '{action:"accept",src:["tag:superadmin"],dst:[$meshtag],users:[$sshuser]}')"
    [ -n "${sup_edge}" ] || die "could not encode the superadmin ssh edge"
    ssh_splice="$(printf '\n    %s' "${sup_edge}")"
    # ONE dynamic owner entry, and it owns nothing: "tag:mesh_<id>": []. headscale
    # 0.23 builds no map at all for ANY node while a policy names a tag that is
    # neither in tagOwners nor forced on some node (measured on this image:
    #   "invalid tag. tag:mesh_hugmesh-local isn't owned by a TagOwner and no
    #    forced tags are defined", every map request, every node stuck short of
    #    Running). On a device the force-tag companion puts tag:mesh_<id> on the
    #    core nodes, so the superadmin rule's dst resolves; the local mesh has no
    #    such companion. An EMPTY owner list resolves the name without letting
    #    anyone self-advertise it, so the tag stays server-forced only.
    to_suffix="$(printf ',\n    "%s": []' "${MESH_TAG}")"
    out_tmp="${POLICY_OUT}.tmp.$$"
    SNAP_TO_SUFFIX="${to_suffix}" SNAP_SSH_SPLICE="${ssh_splice}" awk '
        {
            line = $0
            gsub(/@@HUGMESH_TAGOWNERS_DYNAMIC@@/, ENVIRON["SNAP_TO_SUFFIX"], line)
            gsub(/@@HUGMESH_SSH_EDGES@@/, ENVIRON["SNAP_SSH_SPLICE"], line)
            print line
        }
    ' "${POLICY_TMPL}" > "${out_tmp}"
    if grep -n '@@' "${out_tmp}" >/dev/null; then
        rm -f "${out_tmp}"; die "rendered policy still holds an @@ marker"
    fi
    chmod 0644 "${out_tmp}"
    mv -f "${out_tmp}" "${POLICY_OUT}"
}

render_config
render_policy
log "rendered ${CONFIG_OUT} (server_url ${SERVER_URL}) and ${POLICY_OUT} (ssh: superadmin -> ${MESH_TAG})"

if [ "${HUGMESH_HS_RENDER_ONLY:-}" = 1 ]; then
    exit 0
fi

# ── 3. serve ─────────────────────────────────────────────────────────────────
"${HS_BIN}" configtest >/dev/null 2>&1 || { "${HS_BIN}" configtest || true; die "headscale configtest refused the rendered config/policy"; }

mkdir -p "$(dirname "${SOCKET}")" /var/lib/headscale "${KEY_DIR}"
chmod 0700 "${KEY_DIR}"
rm -f "${SOCKET}"

"${HS_BIN}" serve &
HS_PID=$!
trap 'kill -TERM "${HS_PID}" 2>/dev/null || true' TERM INT

hs() { "${HS_BIN}" "$@"; }

ready=0
for _ in $(seq 1 120); do
    if [ -S "${SOCKET}" ] && hs users list -o json >/dev/null 2>&1; then ready=1; break; fi
    kill -0 "${HS_PID}" 2>/dev/null || die "headscale serve exited during start-up"
    sleep 0.5
done
[ "${ready}" = 1 ] || die "headscale did not answer on ${SOCKET} within 60s"

# ── 4. user ──────────────────────────────────────────────────────────────────
users_json="$(hs users list -o json)"
if jq -e --arg u "${HS_USER}" 'any(.[]?; .name == $u)' >/dev/null <<<"${users_json:-[]}"; then
    log "user ${HS_USER} present"
else
    hs users create "${HS_USER}" >/dev/null || die "could not create user ${HS_USER}"
    log "user ${HS_USER} created"
fi

# ── 5. admin-bff API key ─────────────────────────────────────────────────────
# A key is `<prefix>.<secret>`; headscale lists only prefixes and expiries.
ensure_api_key() {
    local list_json
    local now
    local cur=""
    local cur_prefix=""
    local cur_exp=""
    local new_key
    local new_prefix
    local tmp
    local action=created
    now="$(date +%s)"
    list_json="$(hs apikeys list -o json)" || die "could not list API keys"
    if [ -s "${KEY_FILE}" ]; then
        action=rotated
        cur="$(cat "${KEY_FILE}")"
        cur_prefix="${cur%%.*}"
        cur_exp="$(jq -r --arg p "${cur_prefix}" \
            '[.[]? | select(.prefix == $p) | .expiration.seconds // empty] | first // empty' \
            <<<"${list_json:-[]}")"
    fi
    if [ -n "${cur_exp}" ] && [[ "${cur_exp}" =~ ^[0-9]+$ ]] \
        && [ "${cur_exp}" -gt $(( now + RENEW_DAYS * 86400 )) ]; then
        log "admin-bff API key kept (expires $(date -u -d "@${cur_exp}" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo "${cur_exp}"))"
        return 0
    fi
    new_key="$(hs apikeys create --expiration 90d 2>/dev/null)" || die "could not create an API key"
    new_key="${new_key//[[:space:]]/}"
    [[ "${new_key}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || die "headscale returned an API key of an unexpected shape (not shown)"
    new_prefix="${new_key%%.*}"
    tmp="$(mktemp "${KEY_DIR}/.admin-bff.apikey.XXXXXX")"
    printf '%s' "${new_key}" > "${tmp}"
    chmod 0600 "${tmp}"
    mv -f "${tmp}" "${KEY_FILE}"
    new_key=""
    cur=""
    if [ -n "${cur_prefix}" ] && [ "${cur_prefix}" != "${new_prefix}" ] && [ -n "${cur_exp}" ]; then
        hs apikeys expire --prefix "${cur_prefix}" >/dev/null 2>&1 \
            || log "could not expire the previous admin-bff API key (it expires on its own)"
    fi
    log "admin-bff API key ${action} (90 days) in ${KEY_FILE}"
}
ensure_api_key

log "ready: login server ${SERVER_URL}, user ${HS_USER}"
set +e
wait "${HS_PID}"
rc=$?
# A TERM trapped above returns from the first wait early; wait for the real exit.
if kill -0 "${HS_PID}" 2>/dev/null; then wait "${HS_PID}"; rc=$?; fi
exit "${rc}"
