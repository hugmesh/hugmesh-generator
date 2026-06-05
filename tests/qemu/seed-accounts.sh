#!/usr/bin/env bash
# seed-accounts.sh — seed the SAME identities the Playwright specs (tests/e2e/specs)
# assume, into a REAL booted Snapdragon node, so the unchanged specs pass against
# a QEMU-booted image instead of the rootless mock stack (tests/stack).
#
# The specs expect:
#   * an admin (Casdoor admin role):  admin@snapdragon.systems
#   * five basic Gmail users:         alice,bob,carol,dave,eve @gmail.com
#     (+ frank@gmail.com, invited-but-not-completed in spec 03)
#   * one Discord allowlist entry:    dragoneer
#   * Matrix localpart = email local-part  (alice@gmail.com -> @alice:<server>)
#   * one shared service password (SVC_PASSWORD) the BFF uses to mint
#     Synapse/Mastodon service tokens.
#
# Two delivery modes (use either or both):
#
#   --emit DIR        (rootless, no VM): render a KEYS payload under DIR that the
#                     image's keys-provision consumes on first boot —
#                       DIR/users.json          the admin/login SSH account(s)
#                       DIR/accounts.json        the seed identities (this schema)
#                       DIR/seed/seed-bff.sh     a provision.json `.run` hook that
#                                                POSTs the identities into the
#                                                node-local BFF allowlist at boot
#                       DIR/provision.json patch hint (printed) wiring the hook
#                     Pack it with tests/qemu/make-test-keys.sh and attach it as
#                     the KEYS disk (run-qemu-e2e.sh does this automatically).
#
#   --ssh HOST        (live node): SSH in and push the identities into the running
#                     BFF allowlist over its admin API (the same calls the admin UI
#                     makes), authenticating as ADMIN_EMAIL. Idempotent.
#
# Rootless + sudo-free by design: --emit needs nothing but a shell; --ssh needs
# ssh + a key. Arg parsing + payload rendering are testable without a VM.
set -euo pipefail

# ── Identity defaults (kept in lock-step with tests/e2e/specs + mock-bff.mjs) ──
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@snapdragon.systems}"
GMAIL_USERS_DEFAULT="alice@gmail.com bob@gmail.com carol@gmail.com dave@gmail.com eve@gmail.com frank@gmail.com"
DISCORD_USERS_DEFAULT="dragoneer"
GMAIL_USERS="${GMAIL_USERS:-${GMAIL_USERS_DEFAULT}}"
DISCORD_USERS="${DISCORD_USERS:-${DISCORD_USERS_DEFAULT}}"
SVC_PASSWORD="${SVC_PASSWORD:-snapdragon-svc-pw}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-snapdragon.systems}"

# ── Mode / target defaults ──
EMIT_DIR=""
SSH_HOST=""
SSH_USER="${SSH_USER:-tester}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY=""
BFF_URL="${BFF_URL:-http://127.0.0.1:8403}"   # node-local BFF (as seen inside the VM)
PUBKEY_FILE=""                                  # SSH pubkey to embed in the login users.json
PRINT_JSON=false

usage() {
cat <<EOF
Usage: $0 (--emit DIR | --ssh HOST | --print) [OPTIONS]

Seeds the identities the Playwright e2e specs assume into a real Snapdragon node.

Modes (at least one of --emit/--ssh/--print):
  --emit DIR        Render a KEYS provisioning payload into DIR (users.json +
                    accounts.json + a boot-time BFF-seed hook). Rootless.
  --ssh HOST        Push the identities into the booted node's BFF allowlist
                    over SSH (admin API). Needs --ssh-key or an agent.
  --print           Print the accounts.json to stdout and exit (dry run).

Identity options (defaults mirror tests/e2e/specs):
  --admin EMAIL     Admin (Casdoor admin role). Default: ${ADMIN_EMAIL}
  --gmail "A B .."  Space/comma-separated Gmail allowlist.
                    Default: ${GMAIL_USERS_DEFAULT}
  --discord "A B"   Space/comma-separated Discord allowlist.
                    Default: ${DISCORD_USERS_DEFAULT}
  --svc-password P  Shared service password (Synapse/Mastodon). Default: (env SVC_PASSWORD)
  --domain DOMAIN   Cluster domain (matrix server_name). Default: ${CLUSTER_DOMAIN}

KEYS (--emit) options:
  --pubkey FILE     SSH public key to embed for the login account(s) in users.json.

SSH (--ssh) options:
  --ssh-user USER   Default: ${SSH_USER}
  --ssh-port PORT   Default: ${SSH_PORT}
  --ssh-key FILE    Private key for the SSH login.
  --bff-url URL     BFF base URL as reachable inside the node. Default: ${BFF_URL}

  -h, --help        Show this help.

Examples:
  # Rootless: render KEYS payload, then pack + attach with make-test-keys.sh.
  $0 --emit ./keys-e2e --pubkey ~/.ssh/id_ed25519.pub

  # Live: push into a booted node's BFF allowlist over SSH.
  $0 --ssh 127.0.0.1 --ssh-port 2222 --ssh-key ./id_ed25519
EOF
exit "${1:-0}"
}

# Normalize "a@x, b@y" / "a@x b@y" -> newline list.
list_norm() { echo "$1" | tr ',' ' ' | tr -s ' ' '\n' | sed '/^$/d'; }
# email local-part = matrix localpart, lowercased + sanitised like mock-bff matrixUser().
localpart() { echo "${1%%@*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._=\/-]//g'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emit)         EMIT_DIR="$2"; shift 2 ;;
        --ssh)          SSH_HOST="$2"; shift 2 ;;
        --print)        PRINT_JSON=true; shift ;;
        --admin)        ADMIN_EMAIL="$2"; shift 2 ;;
        --gmail)        GMAIL_USERS="$2"; shift 2 ;;
        --discord)      DISCORD_USERS="$2"; shift 2 ;;
        --svc-password) SVC_PASSWORD="$2"; shift 2 ;;
        --domain)       CLUSTER_DOMAIN="$2"; shift 2 ;;
        --pubkey)       PUBKEY_FILE="$2"; shift 2 ;;
        --ssh-user)     SSH_USER="$2"; shift 2 ;;
        --ssh-port)     SSH_PORT="$2"; shift 2 ;;
        --ssh-key)      SSH_KEY="$2"; shift 2 ;;
        --bff-url)      BFF_URL="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

[ -n "${EMIT_DIR}" ] || [ -n "${SSH_HOST}" ] || ${PRINT_JSON} || {
    echo "ERROR: choose a mode: --emit DIR, --ssh HOST, or --print" >&2; usage 1; }

# ── Build the canonical accounts.json (the seed schema) ────────────────────
# Uses jq if present for safe JSON; falls back to a hand-built document. The
# matrix localpart is precomputed per identity so a backend that lacks the
# split('@') rule still maps the same way the BFF + specs do.
build_accounts_json() {
    local admin="$1"; shift
    local gmails="$1"; shift
    local discords="$1"; shift
    local svc="$1"; shift
    local domain="$1"; shift

    if command -v jq >/dev/null 2>&1; then
        local gm_json dc_json
        gm_json="$(list_norm "${gmails}" | while read -r e; do
            jq -nc --arg e "$e" --arg lp "$(localpart "$e")" \
               '{email:$e, provider:"google", matrix_localpart:$lp}'
        done | jq -sc '.')"
        dc_json="$(list_norm "${discords}" | while read -r d; do
            local dl; dl="$(echo "$d" | tr '[:upper:]' '[:lower:]')"
            jq -nc --arg d "$dl" '{username:$d, provider:"discord", matrix_localpart:$d}'
        done | jq -sc '.')"
        jq -n \
            --arg admin "${admin}" \
            --arg svc "${svc}" \
            --arg domain "${domain}" \
            --argjson gmails "${gm_json}" \
            --argjson discord "${dc_json}" \
            '{
               version: 1,
               cluster_domain: $domain,
               admin: { email: $admin, roles: ["user","admin"] },
               service_password: $svc,
               allowlist: { emails: $gmails, discord: $discord }
             }'
    else
        # jq-less fallback (best-effort; CI images carry jq, this is for bare hosts).
        local gm dc first=true
        gm=""; while read -r e; do
            ${first} || gm+=","; first=false
            gm+="{\"email\":\"${e}\",\"provider\":\"google\",\"matrix_localpart\":\"$(localpart "$e")\"}"
        done < <(list_norm "${gmails}")
        first=true; dc=""; while read -r d; do
            ${first} || dc+=","; first=false
            local dl; dl="$(echo "$d" | tr '[:upper:]' '[:lower:]')"
            dc+="{\"username\":\"${dl}\",\"provider\":\"discord\",\"matrix_localpart\":\"${dl}\"}"
        done < <(list_norm "${discords}")
        cat <<EOF
{
  "version": 1,
  "cluster_domain": "${domain}",
  "admin": { "email": "${admin}", "roles": ["user","admin"] },
  "service_password": "${svc}",
  "allowlist": { "emails": [${gm}], "discord": [${dc}] }
}
EOF
    fi
}

ACCOUNTS_JSON="$(build_accounts_json "${ADMIN_EMAIL}" "${GMAIL_USERS}" "${DISCORD_USERS}" "${SVC_PASSWORD}" "${CLUSTER_DOMAIN}")"

if ${PRINT_JSON}; then
    printf '%s\n' "${ACCOUNTS_JSON}"
fi

# ── Mode A: emit a KEYS provisioning payload ───────────────────────────────
# Renders, under EMIT_DIR:
#   accounts.json        the seed schema above (read by the boot hook)
#   users.json           the OS login account (so run-qemu-e2e can SSH in) —
#                        only written if --pubkey was given AND no users.json
#                        already exists (so a caller-provided one is preserved)
#   seed/seed-bff.sh     a provision.json `.run` hook: at first boot it waits for
#                        the node-local BFF, logs in as the admin, and POSTs every
#                        allowlist entry to /bff/admin/allowlist (idempotent).
emit_keys() {
    local dir="$1"
    mkdir -p "${dir}/seed"
    printf '%s\n' "${ACCOUNTS_JSON}" > "${dir}/accounts.json"

    # OS login account for SSH-based readiness/teardown (mirrors run-qemu-test.sh).
    if [ -n "${PUBKEY_FILE}" ]; then
        [ -f "${PUBKEY_FILE}" ] || { echo "ERROR: --pubkey file not found: ${PUBKEY_FILE}" >&2; return 1; }
        if [ -f "${dir}/users.json" ]; then
            echo "  keep existing ${dir}/users.json (not overwriting)"
        else
            local pub; pub="$(tr -d '\n' < "${PUBKEY_FILE}")"
            cat > "${dir}/users.json" <<EOF
{
  "users": [
    {
      "name": "${SSH_USER}",
      "comment": "QEMU e2e login user",
      "groups": ["wheel", "audio", "video", "usb"],
      "shell": "/bin/bash",
      "uid": 1000,
      "sudo": true,
      "sudo_nopasswd": true,
      "ssh_authorized_keys": ["${pub}"]
    }
  ],
  "root": { "ssh_authorized_keys": ["${pub}"] }
}
EOF
            echo "  wrote ${dir}/users.json (login user '${SSH_USER}')"
        fi
    fi

    # The boot-time hook. keys-provision copies it out of the read-only mount and
    # runs it with KEYS_BASE set to the KEYS root, so it can read accounts.json.
    cat > "${dir}/seed/seed-bff.sh" <<'HOOK'
#!/bin/bash
# seed-bff.sh — provision.json `.run` hook. Seeds the Snapdragon BFF allowlist
# (admin-managed) with the e2e identities from KEYS/accounts.json so the
# Playwright specs pass against this node. Idempotent; failures are non-fatal
# (the node still boots). Run with KEYS_BASE pointing at the KEYS root.
set -uo pipefail
log() { echo "[seed-bff] $*"; }
ACC="${KEYS_BASE:-/run/keys}/accounts.json"
BFF="${SEED_BFF_URL:-http://127.0.0.1:8403}"
[ -f "${ACC}" ] || { log "no accounts.json at ${ACC} — nothing to seed"; exit 0; }
command -v jq   >/dev/null 2>&1 || { log "jq missing — cannot parse accounts.json"; exit 0; }
command -v curl >/dev/null 2>&1 || { log "curl missing — cannot reach BFF"; exit 0; }

ADMIN="$(jq -r '.admin.email' "${ACC}")"
# Wait for the node-local BFF (it comes up with the platform pods).
for _ in $(seq 1 60); do
  curl -sf -o /dev/null "${BFF}/bff/me" -X GET && break || true
  # /bff/me returns 401 (not 000) once the server is listening — treat any
  # HTTP answer as "up".
  code="$(curl -s -o /dev/null -w '%{http_code}' "${BFF}/bff/me" || echo 000)"
  [ "${code}" != "000" ] && break
  sleep 2
done

# Authenticate as the admin (admin@... is granted the admin role by the BFF).
TOK="$(curl -s "${BFF}/bff/login" -H 'content-type: application/json' \
        -d "{\"provider\":\"google\",\"email\":\"${ADMIN}\"}" | jq -r '.token // empty')"
if [ -z "${TOK}" ]; then
  # No account yet: register the admin first (admin email is self-allowed).
  TOK="$(curl -s "${BFF}/bff/register/google" -H 'content-type: application/json' \
          -d "{\"email\":\"${ADMIN}\"}" | jq -r '.token // empty')"
fi
[ -n "${TOK}" ] || { log "could not obtain an admin token from ${BFF}"; exit 0; }

post() { # json-body
  curl -s -o /dev/null -w '%{http_code}' "${BFF}/bff/admin/allowlist" \
    -H "authorization: Bearer ${TOK}" -H 'content-type: application/json' -d "$1"
}
n=0
while read -r e; do [ -n "${e}" ] || continue
  c="$(post "{\"email\":\"${e}\"}")"; log "invite email ${e} -> ${c}"; n=$((n+1))
done < <(jq -r '.allowlist.emails[].email' "${ACC}")
while read -r d; do [ -n "${d}" ] || continue
  c="$(post "{\"discord\":\"${d}\"}")"; log "invite discord ${d} -> ${c}"; n=$((n+1))
done < <(jq -r '.allowlist.discord[].username' "${ACC}")
log "seeded ${n} allowlist entr(y/ies) into ${BFF}"
exit 0
HOOK
    chmod +x "${dir}/seed/seed-bff.sh"

    echo "==> KEYS seed payload rendered in ${dir}"
    echo "    accounts.json   : $(list_norm "${GMAIL_USERS}" | wc -l) gmail + $(list_norm "${DISCORD_USERS}" | wc -l) discord (+ admin ${ADMIN_EMAIL})"
    echo "    seed/seed-bff.sh: boot hook (POSTs allowlist to the node-local BFF)"
    cat <<EOF
    Wire the hook into the KEYS provision.json by adding:
        "run": ["seed/seed-bff.sh"]
    (run-qemu-e2e.sh merges this automatically when it builds the KEYS disk.)
EOF
}

# ── Mode B: push over SSH into a running node's BFF allowlist ───────────────
push_ssh() {
    local host="$1"
    command -v ssh >/dev/null || { echo "ERROR: ssh not found" >&2; return 1; }
    local opts=(-p "${SSH_PORT}" -o StrictHostKeyChecking=no
                -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
    [ -n "${SSH_KEY}" ] && opts+=(-i "${SSH_KEY}")

    echo "==> Pushing allowlist to ${SSH_USER}@${host}:${SSH_PORT} (BFF ${BFF_URL})"
    # Carry accounts.json as a base64 env var (not stdin) so the remote heredoc
    # script is the SSH stdin, and decode it on the node. This runs the same
    # allowlist logic the boot hook uses.
    local acc_b64; acc_b64="$(printf '%s' "${ACCOUNTS_JSON}" | base64 | tr -d '\n')"
    # shellcheck disable=SC2029  # BFF_URL + acc_b64 MUST expand client-side into the remote env
    ssh "${opts[@]}" "${SSH_USER}@${host}" \
        "SEED_BFF_URL='${BFF_URL}' SEED_ACC_B64='${acc_b64}' bash -s" <<'REMOTE'
set -uo pipefail
mkdir -p /tmp/snap-seed
printf '%s' "${SEED_ACC_B64}" | base64 -d > /tmp/snap-seed/accounts.json
ACC=/tmp/snap-seed/accounts.json
BFF="${SEED_BFF_URL:-http://127.0.0.1:8403}"
command -v jq >/dev/null && command -v curl >/dev/null || { echo "[seed-ssh] need jq+curl on node"; exit 1; }
ADMIN="$(jq -r '.admin.email' "${ACC}")"
TOK="$(curl -s "${BFF}/bff/login" -H 'content-type: application/json' \
        -d "{\"provider\":\"google\",\"email\":\"${ADMIN}\"}" | jq -r '.token // empty')"
[ -n "${TOK}" ] || TOK="$(curl -s "${BFF}/bff/register/google" -H 'content-type: application/json' \
        -d "{\"email\":\"${ADMIN}\"}" | jq -r '.token // empty')"
[ -n "${TOK}" ] || { echo "[seed-ssh] no admin token from ${BFF}"; exit 1; }
post() { curl -s -o /dev/null -w '%{http_code}' "${BFF}/bff/admin/allowlist" \
          -H "authorization: Bearer ${TOK}" -H 'content-type: application/json' -d "$1"; }
while read -r e; do [ -n "$e" ] && echo "[seed-ssh] email $e -> $(post "{\"email\":\"$e\"}")"; done \
    < <(jq -r '.allowlist.emails[].email' "${ACC}")
while read -r d; do [ -n "$d" ] && echo "[seed-ssh] discord $d -> $(post "{\"discord\":\"$d\"}")"; done \
    < <(jq -r '.allowlist.discord[].username' "${ACC}")
REMOTE
    echo "==> SSH seed complete"
}

[ -n "${EMIT_DIR}" ] && emit_keys "${EMIT_DIR}"
[ -n "${SSH_HOST}" ] && push_ssh "${SSH_HOST}"
exit 0
