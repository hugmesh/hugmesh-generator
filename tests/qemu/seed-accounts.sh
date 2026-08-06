#!/usr/bin/env bash
# seed-accounts.sh — seed the SAME identities the Playwright specs (tests/e2e/specs)
# assume, into a REAL booted HugMesh node, so the unchanged specs pass against
# a QEMU-booted image instead of the rootless mock stack (tests/stack).
#
# The specs expect:
#   * an admin (Casdoor admin role):  admin@hugmesh.systems
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
#
# RBAC ROLE MATRIX (--roles): the legacy modes above seed only a BINARY allowlist
# (user|admin) into the BFF. The RBAC e2e specs (tests/e2e/specs/rbac-*.spec.ts)
# need the FULL systems Casdoor role matrix — ROLE_ADMIN / ROLE_MOD / ROLE_GAMES /
# ROLE_GAMES_ADMIN(derived) / ROLE_USER / pending — plus a games-realm native
# player. `--roles DIR` renders, into DIR/roles/:
#   * casdoor-systems-roles.json   — role->member grants for the SYSTEMS Casdoor
#       (org "hugmesh"), to MERGE into manifests/casdoor init_data. NOTE it
#       grants ROLE_GAMES + ROLE_ADMIN to e2e-gamesadmin but does NOT put anyone
#       in ROLE_GAMES_ADMIN — that derived role is materialized by the
#       games-admin-sync Job ( = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD) ).
#   * casdoor-games-users.json     — one native player for the GAMES Casdoor
#       (org "threewizards"). The games admin appears via the systems->games sync,
#       not seeded here.
#   * apply-systems-roles.sh       — idempotent Casdoor add-user/update-role hook
#       (login -> add-user with the deterministic e2e password -> update-role) so
#       a REAL seeded Casdoor carries the right `roles` JWT claim. It checks the
#       Casdoor response ENVELOPE (.status == "ok"), not merely the HTTP code:
#       Casdoor reports a DENIED call as HTTP 200 + {"status":"error"}, so a
#       `curl -sf` hook cannot tell "applied" from "rejected" and an entirely
#       unauthenticated run exits 0 having seeded nothing.
# The catalogue is kept in lock-step with tests/e2e/specs/rbac-roles.ts.
set -euo pipefail

# ── Identity defaults (kept in lock-step with tests/e2e/specs + mock-bff.mjs) ──
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@hugmesh.systems}"
GMAIL_USERS_DEFAULT="alice@gmail.com bob@gmail.com carol@gmail.com dave@gmail.com eve@gmail.com frank@gmail.com"
DISCORD_USERS_DEFAULT="dragoneer"
GMAIL_USERS="${GMAIL_USERS:-${GMAIL_USERS_DEFAULT}}"
DISCORD_USERS="${DISCORD_USERS:-${DISCORD_USERS_DEFAULT}}"
SVC_PASSWORD="${SVC_PASSWORD:-hugmesh-svc-pw}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-hugmesh.systems}"

# ── RBAC role matrix (kept in lock-step with tests/e2e/specs/rbac-roles.ts) ──
# Deterministic e2e password, same convention as the games harness (E2E_PASSWORD
# default 'e2e-pass', per-user override via E2E_<UPPER>_PASSWORD).
E2E_PASSWORD="${E2E_PASSWORD:-e2e-pass}"
SYSTEMS_CASDOOR_ORG="${SYSTEMS_CASDOOR_ORG:-hugmesh}"
GAMES_CASDOOR_ORG="${GAMES_CASDOOR_ORG:-threewizards}"
SYSTEMS_CASDOOR_URL="${SYSTEMS_CASDOOR_URL:-http://127.0.0.1:8000}"
# SYSTEMS seed users: "username:ROLE_A,ROLE_B:passwordEnv". ROLE_GAMES_ADMIN is
# NEVER listed here — it is derived by the games-admin-sync Job. e2e-pending holds
# no roles (awaiting approval).
SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS:-\
e2e-admin:ROLE_ADMIN,ROLE_USER:E2E_ADMIN_PASSWORD \
e2e-mod:ROLE_MOD:E2E_MOD_PASSWORD \
e2e-gamesadmin:ROLE_GAMES,ROLE_ADMIN,ROLE_USER:E2E_GAMESADMIN_PASSWORD \
e2e-gamesonly:ROLE_GAMES,ROLE_USER:E2E_GAMESONLY_PASSWORD \
e2e-adminonly:ROLE_ADMIN,ROLE_USER:E2E_ADMINONLY_PASSWORD \
e2e-user:ROLE_USER:E2E_USER_PASSWORD \
e2e-matrix:ROLE_MATRIX,ROLE_USER:E2E_MATRIX_PASSWORD \
e2e-mastodon:ROLE_MASTODON,ROLE_USER:E2E_MASTODON_PASSWORD \
e2e-matrix-domainlocked:ROLE_MATRIX,ROLE_MATRIX_DOMAINLOCKED,ROLE_USER:E2E_MATRIX_DOMAINLOCKED_PASSWORD \
e2e-mastodon-domainlocked:ROLE_MASTODON,ROLE_MASTODON_DOMAINLOCKED,ROLE_USER:E2E_MASTODON_DOMAINLOCKED_PASSWORD \
e2e-matrix-external-client:ROLE_MATRIX,ROLE_MATRIX_EXTERNAL_CLIENT,ROLE_USER:E2E_MATRIX_EXTERNAL_CLIENT_PASSWORD \
e2e-mastodon-external-client:ROLE_MASTODON,ROLE_MASTODON_EXTERNAL_CLIENT,ROLE_USER:E2E_MASTODON_EXTERNAL_CLIENT_PASSWORD \
e2e-forum:ROLE_FORUM,ROLE_USER:E2E_FORUM_PASSWORD \
e2e-denied:ROLE_USER:E2E_DENIED_PASSWORD \
e2e-pending::E2E_PENDING_PASSWORD}"
# APPENDED, not replaced. Setting SYSTEMS_ROLE_USERS overrides the catalogue
# WHOLESALE, which is why a caller that only wanted to add e2e-fleet had to
# reconstruct the entire base list first — and why the kind lane, which did not,
# silently seeded no extras at all. EXTRA_ROLE_USERS is the additive door: callers
# hand it tests/e2e-extra-personas.sh's E2E_EXTRA_PERSONAS and keep the default
# base. Empty by default, so every existing caller is unaffected.
SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS} ${EXTRA_ROLE_USERS:-}"
# ── SWARM (the scaled-concurrent final sweep, tests/e2e/specs/24-final-e2e-sweep) ──
# A PROCEDURAL population acting simultaneously: SWARM_USERS plain users +
# SWARM_MODS mods (moderating the users below them) + SWARM_ADMINS admins. All
# share one deterministic password (E2E_SWARM_PASSWORD) so a single env var
# unlocks the population (per-user env vars for 126 identities would be unusable).
# Kept in lock-step with tests/e2e/specs/rbac-roles.ts generateSwarm().
E2E_SWARM_PASSWORD="${E2E_SWARM_PASSWORD:-e2e-swarm-pass}"
SWARM_USERS="${SWARM_USERS:-120}"
SWARM_MODS="${SWARM_MODS:-4}"
SWARM_ADMINS="${SWARM_ADMINS:-2}"
SWARM_N=""   # set by --swarm N (overrides SWARM_USERS); mods/admins keep their defaults
# GAMES seed users (native): "username:role:passwordEnv".
GAMES_ROLE_USERS="${GAMES_ROLE_USERS:-e2e-player:player:E2E_PLAYER_PASSWORD}"

# ── Mode / target defaults ──
EMIT_DIR=""
ROLES_DIR=""
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

Seeds the identities the Playwright e2e specs assume into a real HugMesh node.

Modes (at least one of --emit/--roles/--ssh/--print):
  --emit DIR        Render a KEYS provisioning payload into DIR (users.json +
                    accounts.json + a boot-time BFF-seed hook). Rootless.
  --roles DIR       Render the FULL systems+games Casdoor RBAC role matrix into
                    DIR/roles/ (casdoor-systems-roles.json + casdoor-games-users.json
                    + apply-systems-roles.sh). Seeds the FULL role matrix with
                    deterministic e2e passwords (ROLE_ADMIN/ROLE_MOD/ROLE_MATRIX/
                    ROLE_MASTODON/ROLE_*_DOMAINLOCKED/ROLE_*_EXTERNAL_CLIENT/
                    ROLE_FORUM/ROLE_GAMES/ROLE_USER + control/denied/pending + a
                    games player) so the rbac-*.spec.ts + local-only specs JWT-role
                    assertions work against a REAL Casdoor. ROLE_GAMES_ADMIN is left
                    to the games-admin-sync Job. Rootless.
  --swarm N         (with --roles) ALSO emit the procedural concurrent-sweep
                    population for tests/e2e/specs/24-final-e2e-sweep: N plain users
                    (default ${SWARM_USERS}) + ${SWARM_MODS} mods + ${SWARM_ADMINS}
                    admins, all with the shared deterministic E2E_SWARM_PASSWORD.
                    Usernames are e2e-swarm-{user-000..,mod-0..,admin-0..} — kept in
                    lock-step with rbac-roles.ts generateSwarm(). The apply hook
                    PRE-MINTS + caches a JWT per swarm member so 126 logins do not
                    serialize at Casdoor token-minting at sweep start.
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
        --roles)        ROLES_DIR="$2"; shift 2 ;;
        --swarm)        SWARM_N="$2"; shift 2 ;;
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

[ -n "${EMIT_DIR}" ] || [ -n "${ROLES_DIR}" ] || [ -n "${SSH_HOST}" ] || ${PRINT_JSON} || {
    echo "ERROR: choose a mode: --emit DIR, --roles DIR, --ssh HOST, or --print" >&2; usage 1; }

# ── Procedural SWARM expansion (the scaled-concurrent final sweep) ──────────
# When --swarm N is given, fold the deterministic population into
# SYSTEMS_ROLE_USERS so the SAME emit_roles path seeds it. All swarm members share
# E2E_SWARM_PASSWORD (passwordEnv literally "E2E_SWARM_PASSWORD"). Usernames +
# role sets MUST match tests/e2e/specs/rbac-roles.ts generateSwarm().
if [ -n "${SWARM_N}" ]; then
    [ -n "${ROLES_DIR}" ] || { echo "ERROR: --swarm requires --roles DIR (it folds into the role matrix)" >&2; usage 1; }
    case "${SWARM_N}" in
        ''|*[!0-9]*) echo "ERROR: --swarm needs a non-negative integer, got '${SWARM_N}'" >&2; usage 1 ;;
    esac
    SWARM_USERS="${SWARM_N}"
    swarm_specs=""
    i=0
    while [ "${i}" -lt "${SWARM_USERS}" ]; do
        printf -v idx '%03d' "${i}"
        swarm_specs+="e2e-swarm-user-${idx}:ROLE_USER,ROLE_MATRIX,ROLE_MASTODON:E2E_SWARM_PASSWORD "
        i=$((i+1))
    done
    i=0
    while [ "${i}" -lt "${SWARM_MODS}" ]; do
        swarm_specs+="e2e-swarm-mod-${i}:ROLE_MOD,ROLE_MATRIX,ROLE_MASTODON,ROLE_USER:E2E_SWARM_PASSWORD "
        i=$((i+1))
    done
    i=0
    while [ "${i}" -lt "${SWARM_ADMINS}" ]; do
        swarm_specs+="e2e-swarm-admin-${i}:ROLE_ADMIN,ROLE_MATRIX,ROLE_MASTODON,ROLE_USER:E2E_SWARM_PASSWORD "
        i=$((i+1))
    done
    SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS} ${swarm_specs}"
    echo "==> --swarm ${SWARM_USERS}: +$((SWARM_USERS + SWARM_MODS + SWARM_ADMINS)) procedural members" \
         "(${SWARM_USERS} users + ${SWARM_MODS} mods + ${SWARM_ADMINS} admins, shared E2E_SWARM_PASSWORD)"
fi

# Resolve a seed user's deterministic e2e password: per-user env override
# (E2E_<UPPER>_PASSWORD) -> shared E2E_PASSWORD -> 'e2e-pass'. Mirrors
# tests/e2e/specs/rbac-roles.ts passwordFor() + games e2e roles.ts.
role_password() {  # <passwordEnvName>
    local env_name="$1" val=""
    [ -n "${env_name}" ] && val="$(printenv "${env_name}" 2>/dev/null || true)"
    [ -n "${val}" ] || val="${E2E_PASSWORD}"
    printf '%s' "${val}"
}

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
# seed-bff.sh — provision.json `.run` hook. Seeds the HugMesh BFF allowlist
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

# ── Mode C: emit the FULL Casdoor RBAC role matrix (systems + games) ────────
# Renders DIR/roles/ with:
#   casdoor-systems-roles.json   role->member grants to MERGE into the systems
#                                Casdoor init_data (org "hugmesh"). Every seed
#                                user + the deterministic password it logs in with.
#                                ROLE_GAMES_ADMIN is intentionally EMPTY (derived
#                                by the games-admin-sync Job).
#   casdoor-games-users.json     native player(s) for the games Casdoor (org
#                                "threewizards"). The synced games admin is NOT
#                                seeded here (it appears via systems->games sync).
#   apply-systems-roles.sh       idempotent Casdoor admin-API hook (add-user with
#                                the e2e password, then update-role) so a REAL
#                                Casdoor carries the right JWT `roles` claim.
#                                Envelope-checked + read-back-verified: it fails
#                                loudly rather than reporting a seed it did not
#                                perform (see its own header for the HTTP-200
#                                denial shape that made that possible).

# Casdoor's add-user rejects any name that isn't alphanumeric/hyphen/underline
# (no leading/trailing/consecutive -_ ), so an email-shaped SYSTEMS_ROLE_USERS
# spec (admin@hugmesh.systems, alice@gmail.com, …) can never be the Casdoor
# `name` verbatim. Pass the ORIGINAL handle through unchanged when it's already
# legal (every existing e2e-* spec); otherwise fold every disallowed run of
# characters to a single hyphen and trim the ends. The sanitized string is used
# ONLY for Casdoor's internal name/role-membership id — displayName/email keep
# the original handle, and Casdoor's native /api/login matches by email too, so
# the specs' hardcoded login-username values keep working unchanged.
casdoor_legal_name() {
    local raw="$1"
    if [[ "${raw}" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$ && ! "${raw}" =~ (--|__|-_|_-) ]]; then
        echo "${raw}"
        return
    fi
    local s="${raw//[^A-Za-z0-9]/-}"
    s="$(echo "${s}" | sed -E 's/-+/-/g')"
    s="${s#-}"; s="${s%-}"
    # Defensive: a raw handle with NO alphanumeric characters at all sanitizes to
    # empty (no current SYSTEMS_ROLE_USERS/EXTRA_SPECS entry is like this, but an
    # empty Casdoor `name` would be a confusing failure mode for whoever adds one).
    [ -n "${s}" ] || s="e2e-persona"
    echo "${s}"
}

emit_roles() {
    local dir="$1/roles"
    mkdir -p "${dir}"
    command -v jq >/dev/null 2>&1 || { echo "ERROR: --roles needs jq" >&2; return 1; }

    # Build the per-user objects + invert into role->members. We emit BOTH a
    # users[] array (with deterministic password) and a roles[] array (members),
    # which is the shape Casdoor's init_data / update-role consume.
    local users_json="[]" role_members_json="{}"
    # HARD PREREQUISITE: every role any seed user is granted MUST be declared here
    # (present-but-empty first) so the round-trip update-role finds a real Casdoor
    # role object. Mirrors manifests/casdoor/init-data-configmap.yaml `roles[]`.
    local declared_roles="ROLE_ADMIN ROLE_MOD ROLE_MATRIX ROLE_MASTODON \
ROLE_MATRIX_DOMAINLOCKED ROLE_MASTODON_DOMAINLOCKED \
ROLE_MATRIX_EXTERNAL_CLIENT ROLE_MASTODON_EXTERNAL_CLIENT \
ROLE_FORUM ROLE_FORUM_MOD ROLE_WIKI ROLE_GAMES ROLE_GAMES_ADMIN ROLE_USER"
    # Seed every declared role as an empty member set first (so the DERIVED
    # ROLE_GAMES_ADMIN / ROLE_FORUM_MOD are present-but-empty — the
    # games-admin-sync / forum reconcile Jobs fill them).
    for r in ${declared_roles}; do
        role_members_json="$(echo "${role_members_json}" | jq --arg r "${r}" '. + {($r): []}')"
    done

    for spec in ${SYSTEMS_ROLE_USERS}; do
        local uname roles_csv penv pass cname email_field
        uname="${spec%%:*}"; spec="${spec#*:}"
        roles_csv="${spec%%:*}"; penv="${spec##*:}"
        pass="$(role_password "${penv}")"
        cname="$(casdoor_legal_name "${uname}")"
        email_field=""
        [[ "${uname}" == *"@"* ]] && email_field="${uname}"
        users_json="$(echo "${users_json}" | jq \
            --arg u "${cname}" --arg disp "${uname}" --arg p "${pass}" --arg org "${SYSTEMS_CASDOOR_ORG}" \
            --arg penv "${penv}" --arg email "${email_field}" \
            '. + [{owner:$org, name:$u, displayName:$disp,
                   email: (if $email == "" then null else $email end),
                   password:$p, passwordEnv:$penv,
                   type:"normal-user", isAdmin:false, isForbidden:false, isDeleted:false}]')"
        # Add this user as a member of each of its (directly-granted) roles. The
        # member id MUST be the Casdoor (sanitized) name — Casdoor resolves role
        # membership against real user ids, not the display handle.
        local IFS=','
        for r in ${roles_csv}; do
            [ -n "${r}" ] || continue
            role_members_json="$(echo "${role_members_json}" | jq \
                --arg r "${r}" --arg m "${SYSTEMS_CASDOOR_ORG}/${cname}" \
                '.[$r] = ((.[$r] // []) + [$m] | unique)')"
        done
        unset IFS
    done

    # Render the systems roles file: organization + roles[] (with members) + users[].
    jq -n \
        --arg org "${SYSTEMS_CASDOOR_ORG}" \
        --argjson members "${role_members_json}" \
        --argjson users "${users_json}" \
        '{
           realm: "systems",
           organization: $org,
           note: "ROLE_GAMES_ADMIN stays EMPTY here — materialized by games-admin-sync = ROLE_GAMES INTERSECT (ROLE_ADMIN UNION ROLE_MOD).",
           roles: ($members | to_entries | map({owner:$org, name:.key, users:.value, isEnabled:true})),
           users: $users
         }' > "${dir}/casdoor-systems-roles.json"

    # Render the games native players file.
    local gusers_json="[]"
    for spec in ${GAMES_ROLE_USERS}; do
        local uname role penv pass
        uname="${spec%%:*}"; spec="${spec#*:}"
        role="${spec%%:*}"; penv="${spec##*:}"
        pass="$(role_password "${penv}")"
        gusers_json="$(echo "${gusers_json}" | jq \
            --arg u "${uname}" --arg p "${pass}" --arg role "${role}" \
            --arg org "${GAMES_CASDOOR_ORG}" --arg penv "${penv}" \
            '. + [{owner:$org, name:$u, displayName:$u, password:$p, passwordEnv:$penv,
                   role:$role, type:"normal-user", isAdmin:false}]')"
    done
    jq -n \
        --arg org "${GAMES_CASDOOR_ORG}" \
        --argjson users "${gusers_json}" \
        '{
           realm: "games",
           organization: $org,
           note: "Native players only. The games admin appears via the systems->games sync (ROLE_GAMES_ADMIN -> admin), asserted by hugmesh-actions/e2e — NOT seeded here.",
           users: $users
         }' > "${dir}/casdoor-games-users.json"

    # The apply hook: login as the Casdoor admin, ensure each user (with its
    # deterministic e2e password) exists, then set each role's members. Idempotent.
    cat > "${dir}/apply-systems-roles.sh" <<'APPLY'
#!/usr/bin/env bash
# apply-systems-roles.sh — push the systems RBAC role matrix into a REAL Casdoor
# (org "hugmesh") so the rbac-*.spec.ts JWT-role assertions work. Reads the
# sibling casdoor-systems-roles.json. Idempotent: add-user is skipped when the
# user already exists, update-role overwrites the member set. Requires curl + jq
# + Casdoor admin creds.
#
#   CASDOOR_URL          (default http://127.0.0.1:8000)
#   CASDOOR_ADMIN_USER   (default admin)
#   CASDOOR_ADMIN_PASS   (required)
#   CASDOOR_ORG          (default hugmesh)
#
# ── WHY EVERY CALL GOES THROUGH casdoor_call() AND NOT `curl -sf` ─────────────
# Casdoor answers a DENIED call with HTTP **200** carrying {"status":"error",…}.
# Upstream controllers/util.go:
#     func (c *ApiController) ResponseError(error string, data ...interface{}) {
#         resp := &Response{Status: "error", Msg: error}
#         c.ResponseJsonData(resp, data...)
#     }
# — it never sets an HTTP status, so the response stays 200; and BOTH
# RequireSignedIn() and RequireAdmin() report their denials through exactly that
# function. `curl -sf` fails only on HTTP >= 400, so it cannot see a denial AT
# ALL.
#
# The failure that caused: on a fresh cluster Casdoor still carries its BUILT-IN
# default admin password (nothing applies the Vault-minted one), so /api/login
# with the Vault password is DENIED -> HTTP 200 -> `curl -sf` is happy -> the
# cookie jar stays empty -> every get-user reads "" (indistinguishable from "not
# created yet") -> every add-user is an anonymous, denied call whose own "error"
# status is printed as informational text -> every get-role reads empty ->
# "role missing — skip" -> exit 0, and the bootstrap prints "SSO slice seeded."
# having seeded NOTHING. Envelope checking is the only thing that separates
# "applied" from "rejected".
#
# Casdoor does distinguish ABSENT from DENIED, and so do we: GetUser()/GetRole()
# on a non-existent id return ResponseOk(nil) = {"status":"ok","data":null},
# whereas a denial returns {"status":"error"}. A missing ROLE is now a hard
# FAILURE (the matrix cannot be applied without it), never a "skip".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_JSON="${HERE}/casdoor-systems-roles.json"
BASE="${CASDOOR_URL:-http://127.0.0.1:8000}"
ORG="${CASDOOR_ORG:-hugmesh}"
AU="${CASDOOR_ADMIN_USER:-admin}"
AP="${CASDOOR_ADMIN_PASS:?CASDOOR_ADMIN_PASS required}"
WORK="$(mktemp -d)"; CJ="${WORK}/cookies"; : > "${CJ}"
trap 'rm -rf "${WORK}"' EXIT
log() { echo "[apply-roles] $*"; }
die() { echo "[apply-roles] FATAL: $*" >&2; exit 1; }

for _t in curl jq; do
  command -v "${_t}" >/dev/null 2>&1 || die "missing required tool: ${_t}"
done
[ -f "${ROLES_JSON}" ] || die "role matrix not found: ${ROLES_JSON}"

# casdoor_call <GET|POST> <path> [json-body]  -> response body on stdout.
# Fails on a transport error, on HTTP >= 400, on a non-JSON body, and on an
# {"status":"error"} envelope delivered with HTTP 200 (the denial shape above).
casdoor_call() {
  local method="$1" path="$2" body="${3:-}" code status msg
  local -a args=(-s -o "${WORK}/body" -w '%{http_code}' -b "${CJ}" -c "${CJ}"
                 -X "${method}" -H 'content-type: application/json')
  [ -n "${body}" ] && args+=(-d "${body}")
  : > "${WORK}/body"
  code="$(curl "${args[@]}" "${BASE}${path}" 2>/dev/null)" \
    || die "${method} ${path}: curl transport failure (is ${BASE} reachable?)"
  case "${code}" in
    2*) : ;;
    *)  die "${method} ${path}: HTTP ${code} — $(head -c 200 "${WORK}/body" 2>/dev/null)" ;;
  esac
  jq -e 'type == "object"' "${WORK}/body" >/dev/null 2>&1 \
    || die "${method} ${path}: HTTP ${code} but the body is not a JSON object — $(head -c 200 "${WORK}/body")"
  status="$(jq -r '.status // empty' "${WORK}/body")"
  if [ "${status}" != "ok" ]; then
    msg="$(jq -r '.msg // "(no msg)"' "${WORK}/body")"
    die "${method} ${path}: Casdoor answered HTTP ${code} with status='${status:-<absent>}' msg='${msg}'. The call was REJECTED, not applied — a wrong CASDOOR_ADMIN_PASS (or an expired session) looks EXACTLY like this."
  fi
  cat "${WORK}/body"
}

# ── 1. Admin session ────────────────────────────────────────────────────────
log "admin login as '${AU}' at ${BASE}"
casdoor_call POST /api/login \
  "{\"application\":\"app-built-in\",\"organization\":\"built-in\",\"username\":\"${AU}\",\"password\":\"${AP}\",\"type\":\"login\",\"autoSignin\":true}" \
  >/dev/null
# status=ok is necessary but not sufficient: everything after this is authorized
# by the SESSION COOKIE, so if the jar is empty we are about to run the whole
# seed anonymously. Count real cookie records (curl writes HttpOnly cookies with
# a leading "#HttpOnly_", so a plain "skip comment lines" test would miss them).
cookies="$(awk -F'\t' 'NF>=7 {n++} END {print n+0}' "${CJ}" 2>/dev/null || echo 0)"
[ "${cookies}" -gt 0 ] \
  || die "/api/login returned status=ok but set NO session cookie — every call after this would be anonymous (and denied with HTTP 200)."

# ── 2. Ensure every seed user exists with its deterministic e2e password ────
users_total="$(jq '.users | length' "${ROLES_JSON}")"
[ "${users_total}" -gt 0 ] || die "role matrix declares zero users — nothing to seed"
added=0; already=0
while IFS= read -r u; do
  [ -n "${u}" ] || continue
  name="$(printf '%s' "$u" | jq -r '.name')"
  resp="$(casdoor_call GET "/api/get-user?id=${ORG}/${name}")"
  exists="$(printf '%s' "${resp}" | jq -r '.data.name // empty')"
  if [ -n "${exists}" ]; then
    log "user ${name} exists"; already=$((already+1)); continue
  fi
  payload="$(printf '%s' "$u" | jq -c '{owner, name, displayName, email, password, type, isAdmin, isForbidden, isDeleted, signupApplication:"app-built-in"}')"
  add="$(casdoor_call POST /api/add-user "${payload}")"
  # Casdoor wraps writes with wrapActionResponse(): status=ok carries
  # data="Affected" when a row really changed and data="Unaffected" when the
  # write was a no-op. We only get here when get-user said the user is ABSENT,
  # so "Unaffected" means the insert silently did nothing.
  affected="$(printf '%s' "${add}" | jq -r '.data // empty')"
  [ "${affected}" != "Unaffected" ] \
    || die "add-user ${name}: Casdoor returned status=ok data=Unaffected — the user was NOT created"
  log "add-user ${name} -> ok (${affected:-ok})"
  added=$((added+1))
done < <(jq -c '.users[]' "${ROLES_JSON}")
log "users: ${added} added, ${already} already present (${users_total} declared)"

# ── 3. Set each role's member set to EXACTLY the seeded list ────────────────
# Round-trip the existing role object so other fields survive. ROLE_GAMES_ADMIN
# is sent EMPTY on purpose (the games-admin-sync Job derives it).
roles_done=0
while IFS= read -r r; do
  [ -n "${r}" ] || continue
  rname="$(printf '%s' "$r" | jq -r '.name')"
  want="$(printf '%s' "$r" | jq -c '.users')"
  cur_resp="$(casdoor_call GET "/api/get-role?id=${ORG}/${rname}")"
  cur="$(printf '%s' "${cur_resp}" | jq -c '.data // empty')"
  # status=ok + data:null is Casdoor for "this role does not exist". The matrix
  # cannot be applied without it, and pretending otherwise is precisely how a
  # fully-unseeded run used to report success.
  [ -n "${cur}" ] && [ "${cur}" != "null" ] \
    || die "role ${ORG}/${rname} does not exist in Casdoor — declare it in manifests/casdoor init_data.json (roles[]) and re-run casdoor-init. Refusing to report success with an unapplied role matrix."
  upd="$(printf '%s' "${cur}" | jq -c --argjson members "${want}" '.users = $members')"
  casdoor_call POST "/api/update-role?id=${ORG}/${rname}" "${upd}" >/dev/null
  # READ BACK rather than trust the write's own status. Casdoor has a
  # LIVE-VERIFIED history of answering {"status":"ok","data":"Affected"} to a
  # membership write it did not persist (see manifests/casdoor/init-job.yaml's
  # update-group note), so the write's status alone is not evidence.
  back_resp="$(casdoor_call GET "/api/get-role?id=${ORG}/${rname}")"
  got="$(printf '%s' "${back_resp}" | jq -c '.data.users // []')"
  missing="$(jq -nr --argjson want "${want}" --argjson got "${got}" '($want - $got) | join(", ")')"
  [ -z "${missing}" ] \
    || die "update-role ${rname} reported success but the role still does not contain: ${missing} (read back ${got})"
  log "update-role ${rname} -> ok ($(printf '%s' "${want}" | jq -r 'length') member(s), verified)"
  roles_done=$((roles_done+1))
done < <(jq -c '.roles[]' "${ROLES_JSON}")
log "roles: ${roles_done} applied and read-back-verified"
log "done — REMEMBER to run the games-admin-sync Job so ROLE_GAMES_ADMIN materializes."

# ── Pre-mint + cache a JWT per seed user (CRITICAL for the swarm) ───────────
# Casdoor is replicas:1; the concurrent sweep (spec 24) would serialize 126
# logins at token-minting time if every actor logged in at sweep start. Pre-mint
# each user's access token NOW (right after seeding) into PREMINT_DIR so the
# harness loads cached tokens instead of racing the login endpoint. The harness
# then asserts a real concurrency invariant (max in-flight >= N) so a silently
# serialized run still FAILS rather than passing slowly.
#
# DELIBERATELY BEST-EFFORT (the one call in this file that is): the OAuth2
# password grant is a Casdoor CONFIG option, so its absence is a legitimate
# deployment state, not a seeding failure — and spec 24 carries its own
# max-in-flight concurrency invariant, which FAILS a silently-serialized run. So
# a zero-token outcome degrades to interactive login instead of aborting the
# seed. It still must not LIE about it: the count below is the real one (the old
# loop incremented `minted` inside a pipeline subshell, so the parent always saw
# 0 and printed the same cheerful line whether it minted 126 tokens or none).
PREMINT_DIR="${PREMINT_DIR:-${HERE}/jwt-cache}"
APP="${PREMINT_APP:-app-built-in}"
mkdir -p "${PREMINT_DIR}"
minted=0; premint_total=0
while IFS= read -r u; do
  [ -n "${u}" ] || continue
  premint_total=$((premint_total+1))
  name="$(printf '%s' "$u" | jq -r '.name')"
  pass="$(printf '%s' "$u" | jq -r '.password')"
  tok="$(curl -s "${BASE}/api/login/oauth/access_token" \
          -H 'content-type: application/x-www-form-urlencoded' \
          --data-urlencode "grant_type=password" \
          --data-urlencode "username=${ORG}/${name}" \
          --data-urlencode "password=${pass}" \
          --data-urlencode "client_id=${APP}" 2>/dev/null \
        | jq -r '.access_token // empty' 2>/dev/null || true)"
  if [ -n "${tok}" ]; then
    printf '%s' "${tok}" > "${PREMINT_DIR}/${name}.jwt"
    minted=$((minted+1))
  fi
done < <(jq -c '.users[]' "${ROLES_JSON}")
if [ "${minted}" -eq 0 ]; then
  log "pre-mint: 0 of ${premint_total} JWTs (password grant unavailable) — the swarm harness will fall back to interactive login; spec 24's concurrency invariant still gates serialization"
else
  log "pre-mint: ${minted} of ${premint_total} JWTs cached in ${PREMINT_DIR} (load them in the swarm harness to avoid serializing Casdoor logins)"
fi
APPLY
    chmod +x "${dir}/apply-systems-roles.sh"

    echo "==> RBAC role matrix rendered in ${dir}"
    echo "    casdoor-systems-roles.json : $(jq '.users|length' "${dir}/casdoor-systems-roles.json") systems users across $(jq '.roles|length' "${dir}/casdoor-systems-roles.json") roles (ROLE_GAMES_ADMIN derived/empty)"
    echo "    casdoor-games-users.json   : $(jq '.users|length' "${dir}/casdoor-games-users.json") native games player(s)"
    echo "    apply-systems-roles.sh     : Casdoor admin-API hook (CASDOOR_ADMIN_PASS=... ./apply-systems-roles.sh)"
}

[ -n "${EMIT_DIR}" ]  && emit_keys  "${EMIT_DIR}"
[ -n "${ROLES_DIR}" ] && emit_roles "${ROLES_DIR}"
[ -n "${SSH_HOST}" ]  && push_ssh   "${SSH_HOST}"
exit 0
