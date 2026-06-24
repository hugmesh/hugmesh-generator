#!/usr/bin/env bash
# gen-cluster-secrets.sh — generate the cluster application secrets (Casdoor,
# ClickHouse, Uptrace) and deliver them two ways:
#
#   1. ONLINE  — if VAULT_ADDR (+ VAULT_TOKEN) is set, write them to HashiCorp
#                Vault (KV v2, mount "secret/", base path "<brand>/"). The
#                External Secrets Operator then materializes the k8s Secrets.
#   2. OFFLINE — ALWAYS write a USB bundle under <out>/vault:
#                  secrets.json  — the exact namespace->secretName->key->value
#                                  shape the cluster's k8s Secrets consume, so a
#                                  device can create them with no Vault reachable.
#                  token         — the Vault token (for later online sync).
#
# Provisioning prefers Vault first, USB second. Drop the bundle onto the KEYS
# stick (it is picked up by scripts/make-keys-usb.sh).
#
# No root required. Requires: openssl, python3. Optional: vault CLI (online).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${REPO_DIR}/keys-out/vault"

# ── brand.conf (built-in defaults < brand.conf < env) ───────────────
BRAND="${BRAND:-snapdragon}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-snapdragon.systems}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
if [ -f "${REPO_DIR}/brand.conf" ]; then
    # shellcheck disable=SC1091
    . "${REPO_DIR}/brand.conf"
fi
# brands/<BRAND>.conf (the committed brand profile) may also set MAIL_*/OAuth
# presets; honor it like the other generators do. ./brand.conf (above) and the
# environment still win.
if [ -n "${BRAND:-}" ] && [ -f "${REPO_DIR}/brands/${BRAND}.conf" ]; then
    # shellcheck disable=SC1090
    . "${REPO_DIR}/brands/${BRAND}.conf"
fi

# Optional keys file with OAuth + mail creds the operator drops next to the
# generator (or points KEYS_FILE at). Lets gen-cluster-secrets.sh pick up the
# same secret/<brand>/mail + casdoor github_/discord_ props the keys USB carries,
# WITHOUT putting them in a committed brand profile. JSON shape (all optional):
#   { "github":  {"client_id":"...","client_secret":"..."},
#     "discord": {"client_id":"...","client_secret":"..."},
#     "mail":    {"provider":"gmail","host":"...","port":"587","tls":"starttls",
#                 "user":"...","password":"...","from":"...","dkim_key":"..."} }
# Missing fields fall back to env -> brand preset -> placeholder/empty.
KEYS_FILE="${KEYS_FILE:-${REPO_DIR}/keys-out/secrets/cluster-creds.json}"

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Generates Casdoor / ClickHouse / Uptrace secrets, optionally writes them to
  HashiCorp Vault (if VAULT_ADDR + VAULT_TOKEN are set), and ALWAYS writes an
  offline USB bundle for delivery without Vault.

Options:
  --out DIR     Output directory for the offline bundle. Default: ${OUT_DIR}
  -h, --help    Show this help.

Environment:
  BRAND           Brand slug = Vault base path segment. Default: snapdragon
  VAULT_ADDR      Vault server URL. Empty = offline / USB-only delivery.
  VAULT_TOKEN     Vault token (or AppRole secret-id) for online writes + bundle.
  VAULT_KV_MOUNT  KV v2 mount. Default: secret

  (BRAND / CLUSTER_DOMAIN / VAULT_* are also read from ${REPO_DIR}/brand.conf.)

Next: copy the bundle onto the KEYS stick, or let scripts/make-keys-usb.sh
pick it up.
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)     OUT_DIR="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

for t in openssl python3; do
    command -v "$t" >/dev/null || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done

BASE="${BRAND:-snapdragon}"

echo "==> Generating cluster secrets for base 'secret/${BASE}/' (brand=${BRAND})"

# ── Generate every secret value ─────────────────────────────────────
# Casdoor admin: plaintext to hand to Casdoor seed; store a -6 hash too.
CASDOOR_ADMIN_PLAIN="$(openssl rand -base64 18)"
CASDOOR_ADMIN_HASH="$(openssl passwd -6 "${CASDOOR_ADMIN_PLAIN}")"

# Platform SUPERADMIN bootstrap Casdoor login. Username is configurable
# (CASDOOR_SUPERADMIN_USERNAME env / brand.conf, default "superadmin"); the
# password is always freshly generated and stored ONLY in Vault + the USB
# offline bundle — never printed, never committed. The casdoor-init Job reads
# these from the casdoor-superadmin k8s Secret and calls POST /api/add-user,
# then assigns ROLE_SUPERADMIN. Absent => the Job skips gracefully.
CASDOOR_SUPERADMIN_USERNAME="${CASDOOR_SUPERADMIN_USERNAME:-superadmin}"
CASDOOR_SUPERADMIN_PASSWORD="$(openssl rand -base64 24)"

# Casdoor external Postgres (casdoor-pg) password. The DB user is the fixed
# "casdoor" (set in the casdoor-db ExternalSecret template); only the password
# is minted/stored.
CASDOOR_DB_PASSWORD="$(openssl rand -base64 24)"

# Google OAuth client values are issued by Google; generate placeholders the
# operator replaces. They still populate the casdoor-google k8s Secret.
CASDOOR_GOOGLE_CLIENT_ID="REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID"
CASDOOR_GOOGLE_CLIENT_SECRET="REPLACE_WITH_GOOGLE_OAUTH_CLIENT_SECRET"

# ── Optional keys file reader (no jq dependency) ────────────────────
# keyfile_get <dotted.path> -> prints the value (empty if file/key absent).
# Uses python3 (already required) so we don't add a jq dependency.
keyfile_get() {
    [ -f "${KEYS_FILE}" ] || { printf ''; return 0; }
    KF="${KEYS_FILE}" python3 - "$1" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    d = json.load(open(os.environ["KF"]))
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        sys.exit(0)
if d is None:
    sys.exit(0)
sys.stdout.write(str(d))
PY
}
if [ -f "${KEYS_FILE}" ]; then
    echo "==> Reading optional OAuth/mail creds from keys file: ${KEYS_FILE}"
fi

# ── GitHub + Discord OAuth federation providers (systems Casdoor) ───
# Client id/secret are issued by GitHub/Discord. Resolution order:
#   env (GITHUB_CLIENT_ID/…) -> keys file (github.client_id/…) -> placeholder.
# These populate the OPTIONAL casdoor-github / casdoor-discord k8s Secrets; the
# casdoor-init Job skips provider seeding when the secret is absent (it stays a
# placeholder => still wired through, but the operator replaces it with reals).
CASDOOR_GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-$(keyfile_get github.client_id)}"
CASDOOR_GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-$(keyfile_get github.client_secret)}"
CASDOOR_GITHUB_CLIENT_ID="${CASDOOR_GITHUB_CLIENT_ID:-REPLACE_WITH_GITHUB_OAUTH_CLIENT_ID}"
CASDOOR_GITHUB_CLIENT_SECRET="${CASDOOR_GITHUB_CLIENT_SECRET:-REPLACE_WITH_GITHUB_OAUTH_CLIENT_SECRET}"

CASDOOR_DISCORD_CLIENT_ID="${DISCORD_CLIENT_ID:-$(keyfile_get discord.client_id)}"
CASDOOR_DISCORD_CLIENT_SECRET="${DISCORD_CLIENT_SECRET:-$(keyfile_get discord.client_secret)}"
CASDOOR_DISCORD_CLIENT_ID="${CASDOOR_DISCORD_CLIENT_ID:-REPLACE_WITH_DISCORD_OAUTH_CLIENT_ID}"
CASDOOR_DISCORD_CLIENT_SECRET="${CASDOOR_DISCORD_CLIENT_SECRET:-REPLACE_WITH_DISCORD_OAUTH_CLIENT_SECRET}"

# ── Outbound mail (OPTIONAL, ABSENT-BY-DEFAULT) ─────────────────────
# secret/<brand>/mail props (host/port/tls/user/password/from/dkim_key). The knob
# MAIL_PROVIDER (brand.conf, default protonmail) only selects host/port/tls
# PRESETS; mail is only switched ON when a real MAIL_USER + MAIL_PASSWORD resolve
# (env -> keys file). With no user/pass we leave the props EMPTY: the Vault path
# carries blanks and provisioning still materializes a (blank) Secret, but the
# casdoor/akkoma manifests treat empty host/relay as "mail disabled" (Akkoma's
# enabled: is RELAY != "") so registration stays admin-approval — no mail wired.
MAIL_PROVIDER="${MAIL_PROVIDER:-$(keyfile_get mail.provider)}"
MAIL_PROVIDER="${MAIL_PROVIDER:-protonmail}"
# Provider host/port/TLS presets (overridable by explicit MAIL_HOST/PORT/TLS).
# TLS value is the Swoosh/Pleroma.Mailer :tls option the akkoma manifest passes
# verbatim as an atom: "always" (=STARTTLS) | "if_available" | "never". Casdoor
# ignores the literal and infers TLS from the port. gmail/outlook/protonmail all
# use STARTTLS on the submission port => "always".
case "${MAIL_PROVIDER}" in
    gmail)      _MAIL_HOST_DEF="smtp.gmail.com";     _MAIL_PORT_DEF="587";  _MAIL_TLS_DEF="always" ;;
    outlook)    _MAIL_HOST_DEF="smtp.office365.com"; _MAIL_PORT_DEF="587";  _MAIL_TLS_DEF="always" ;;
    protonmail) _MAIL_HOST_DEF="127.0.0.1";          _MAIL_PORT_DEF="1025"; _MAIL_TLS_DEF="always" ;;
    smtp)       _MAIL_HOST_DEF="";                    _MAIL_PORT_DEF="587";  _MAIL_TLS_DEF="always" ;;
    none|"")    _MAIL_HOST_DEF="";                    _MAIL_PORT_DEF="";     _MAIL_TLS_DEF="" ;;
    *)          echo "WARNING: unknown MAIL_PROVIDER='${MAIL_PROVIDER}', treating as 'smtp'" >&2
                _MAIL_HOST_DEF="";                    _MAIL_PORT_DEF="587";  _MAIL_TLS_DEF="always" ;;
esac
MAIL_HOST="${MAIL_HOST:-$(keyfile_get mail.host)}";         MAIL_HOST="${MAIL_HOST:-${_MAIL_HOST_DEF}}"
MAIL_PORT="${MAIL_PORT:-$(keyfile_get mail.port)}";         MAIL_PORT="${MAIL_PORT:-${_MAIL_PORT_DEF}}"
MAIL_TLS="${MAIL_TLS:-$(keyfile_get mail.tls)}";            MAIL_TLS="${MAIL_TLS:-${_MAIL_TLS_DEF}}"
# Normalize friendly TLS aliases to the Swoosh :tls atom values the manifest uses
# ("always" | "if_available" | "never"); keep "" untouched (mail disabled).
case "${MAIL_TLS}" in
    starttls|tls|STARTTLS|TLS|always) MAIL_TLS="always" ;;
    if_available|ifavailable|auto)    MAIL_TLS="if_available" ;;
    none|off|never)                   MAIL_TLS="never" ;;
    "")                               : ;;  # disabled — leave empty
esac
MAIL_USER="${MAIL_USER:-$(keyfile_get mail.user)}"
MAIL_PASSWORD="${MAIL_PASSWORD:-$(keyfile_get mail.password)}"
MAIL_FROM="${MAIL_FROM:-$(keyfile_get mail.from)}";         MAIL_FROM="${MAIL_FROM:-noreply@${CLUSTER_DOMAIN}}"
MAIL_DKIM_KEY="${MAIL_DKIM_KEY:-$(keyfile_get mail.dkim_key)}"
# DKIM private key may be a PATH (read the file) or already-inline PEM text.
MAIL_DKIM=""
if [ -n "${MAIL_DKIM_KEY}" ]; then
    if [ -f "${MAIL_DKIM_KEY}" ]; then MAIL_DKIM="$(cat "${MAIL_DKIM_KEY}")"
    else MAIL_DKIM="${MAIL_DKIM_KEY}"; fi
fi
# Mail is "live" only with BOTH a user and a password (and provider != none).
# Otherwise blank EVERYTHING so the manifests see empty host/relay = disabled.
if [ "${MAIL_PROVIDER}" = "none" ] || [ -z "${MAIL_USER}" ] || [ -z "${MAIL_PASSWORD}" ]; then
    MAIL_HOST=""; MAIL_PORT=""; MAIL_TLS=""; MAIL_USER=""; MAIL_PASSWORD=""; MAIL_DKIM=""
    MAIL_ENABLED=0
    echo "==> Mail: DISABLED (provider=${MAIL_PROVIDER}; no MAIL_USER/MAIL_PASSWORD) — no SMTP wired"
else
    MAIL_ENABLED=1
    echo "==> Mail: ENABLED via provider '${MAIL_PROVIDER}' (${MAIL_HOST}:${MAIL_PORT}, tls=${MAIL_TLS}, from=${MAIL_FROM})"
fi

# GitLab registry pull credentials — a GROUP DEPLOY TOKEN (scope: read_registry)
# created by an admin in GitLab. Placeholders the operator replaces; ESO builds
# the gitlab-registry dockerconfigjson imagePullSecret from these in each app
# namespace. (In-cluster registry, so no offline-bundle entry.)
GITLAB_REGISTRY_USER="${GITLAB_REGISTRY_USER:-snapdragon-deploy}"
GITLAB_REGISTRY_TOKEN="${GITLAB_REGISTRY_TOKEN:-REPLACE_WITH_GITLAB_DEPLOY_TOKEN}"

# In-cluster image-builder PUSH credentials — a GROUP DEPLOY TOKEN with scope
# WRITE_REGISTRY (distinct from the read_registry pull token above). The opt-in
# Kaniko build pipeline (manifests/image-builder) mounts the image-builder-registry
# dockerconfigjson built from these to PUSH the images it builds. Placeholders the
# operator replaces post-bootstrap; ESO only materializes once the opt-in namespace
# exists. (In-cluster registry, so no offline-bundle entry.)
IMAGE_BUILDER_REGISTRY_USER="${IMAGE_BUILDER_REGISTRY_USER:-snapdragon-image-builder}"
IMAGE_BUILDER_REGISTRY_TOKEN="${IMAGE_BUILDER_REGISTRY_TOKEN:-REPLACE_WITH_GITLAB_WRITE_REGISTRY_DEPLOY_TOKEN}"

# Casdoor's own OIDC application client_id / client_secret (used by the BFF).
CASDOOR_CLIENT_ID="$(openssl rand -hex 16)"
CASDOOR_CLIENT_SECRET="$(openssl rand -hex 32)"

# ── GAMES-realm Casdoor (casdoor-games, org "threewizards") ─────────
# A SEPARATE, INDEPENDENT Casdoor from the systems one above, mirroring the
# canonical snapdragon.games realm. Its secrets live under a distinct Vault path
# (secret/<brand>/casdoor-games). The threewizards-app clientId is the fixed
# "twclient001" (set in the casdoor-games-app ExternalSecret template); only the
# client-secret, admin password, DB password, and GitHub provider creds are minted.
CASDOOR_GAMES_ADMIN_PLAIN="$(openssl rand -base64 18)"
CASDOOR_GAMES_DB_PASSWORD="$(openssl rand -base64 24)"
CASDOOR_GAMES_CLIENT_SECRET="$(openssl rand -hex 32)"
# GitHub OAuth client (issued by GitHub) — placeholders the operator replaces.
CASDOOR_GAMES_GITHUB_CLIENT_ID="REPLACE_WITH_GITHUB_OAUTH_CLIENT_ID"
CASDOOR_GAMES_GITHUB_CLIENT_SECRET="REPLACE_WITH_GITHUB_OAUTH_CLIENT_SECRET"

# Per-application Casdoor SERVICE identities. Each app/UI/API gets its own
# OAuth2 application client-secret (and, where it logs in as a machine user, a
# service-user password). Names mirror docs/SECURITY.md's identity matrix and
# the Casdoor applications declared in manifests/casdoor/init-data (which seeds
# the apps/users/roles structure; these secrets are injected by casdoor-init).
# The init Job needs the admin PLAINTEXT to call the Casdoor API, so we keep it
# alongside the -6 hash. Secrets live only in Vault / the USB bundle, never git.
CASDOOR_APPS="pki-gateway be-gateway fe-gateway api admin-bff user-bff matrix mastodon fragment-sync signup-gate"
CASDOOR_APP_KV_ARGS=()
CASDOOR_APP_JSON_ENV=()
for _app in ${CASDOOR_APPS}; do
    _sec="$(openssl rand -hex 32)"
    _var="APPSEC_$(echo "${_app}" | tr 'a-z-' 'A-Z_')"
    printf -v "${_var}" '%s' "${_sec}"
    CASDOOR_APP_KV_ARGS+=("${_app}=${_sec}")
    CASDOOR_APP_JSON_ENV+=("${_var}")
done
# Shared-secret for the signup-gate POST-signup reconcile webhook (Casdoor ->
# signup-gate /casdoor/webhook header X-Signup-Gate-Secret). NOT a Casdoor app
# secret — co-located in the casdoor-apps path (property signup-gate-webhook) so
# the proxy + casdoor-init read it from one place. Optional in the manifests; we
# seed it here so the ExternalSecret property resolves.
SIGNUP_GATE_WEBHOOK_SECRET="$(openssl rand -hex 32)"
CASDOOR_APP_KV_ARGS+=("signup-gate-webhook=${SIGNUP_GATE_WEBHOOK_SECRET}")
CASDOOR_APP_JSON_ENV+=("SIGNUP_GATE_WEBHOOK_SECRET")

CLICKHOUSE_PASSWORD="$(openssl rand -base64 24)"

# Dedicated per-app Postgres passwords (federation-db / admin-bff-db / mod-bff-db /
# user-bff-db). The OWNER password (DDL/Liquibase) stays the existing `password`
# key; a SEPARATE app_password is the non-owner least-privilege runtime role
# (federation_app / adminbff_app / modbff_app / userbff_app). DB pod + consumer
# reference the SAME Vault key so role + cred stay in sync.
FEDERATION_DB_PASSWORD="$(openssl rand -base64 24)"
ADMIN_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
MOD_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
USER_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
FORUM_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
# Non-owner least-privilege RUNTIME role passwords (one per single-consumer DB).
FEDERATION_DB_APP_PASSWORD="$(openssl rand -base64 24)"
ADMIN_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
MOD_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
USER_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
FORUM_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"

# admin-bff MFA TOTP-secret encryption key (app.mfa.factor-key / env
# APP_MFA_FACTOR_KEY). The admin-bff's MfaSecretCipher AES-256-GCM-encrypts each
# enrolled TOTP secret at rest with this 256-bit data key (the same key also seeds
# the recovery-code keyed hash). The cipher PREFERS a base64-decoded 32-byte key —
# `openssl rand -base64 32` mints exactly that (32 random bytes => 44 base64 chars),
# matching the existing high-entropy-secret idiom. SHIPS DARK: the whole MFA surface
# stays off behind app.casdoor.mfa.enabled (default false) and the cipher is INERT
# with an empty key, so this only PROVISIONS the key — it does not enable MFA. The
# value lives ONLY in Vault + the offline USB bundle, never committed to git.
ADMIN_BFF_MFA_FACTOR_KEY="$(openssl rand -base64 32)"

# user-bff OIDC session-custody AES-256-GCM key (APP_BFF_CUSTODY_KEY).
# Encrypts the held Casdoor access + refresh tokens at rest, keyed to each
# opaque bff_ session. The BffCustodyCipher is INERT when this key is blank,
# and OidcCustodyBootGuard refuses to start if OIDC is enabled but key is empty.
# Mirrors admin-bff MfaSecretCipher: prefers a base64-decoded 32-byte key.
USER_BFF_CUSTODY_KEY="$(openssl rand -base64 32)"

# user-bff HS token key (APP_HS_TOKEN_KEY) — the homeserver-native token
# custody encryption key. The ESO ExternalSecret + deployment wiring already
# existed (user-bff-hs-token); this closes the bootstrap gap by seeding Vault.
USER_BFF_HS_TOKEN_KEY="$(openssl rand -base64 32)"

# Shared back-channel token between user-bff and the fe-gateway / admin-bff
# (INTERNAL_TOKEN / X-Internal-Token header). Authenticates the gateway→admin-bff
# BffSessionAuthFilter introspection call and the user-bff→admin-bff call.
# Blank = no-op in dev; set = fail-closed 401 on mismatch (both sides match).
BFF_INTERNAL_TOKEN="$(openssl rand -hex 32)"

# phpBB forum (backend-only). phpbb-db OWNER (install/migrate) + phpbb_app runtime
# role + the phpBB first-install admin. Kept on their OWN Vault paths (forum,
# forum-db) so the isolated snapdragon-forum namespace's phpbb-secrets /
# phpbb-db-app-auth ExternalSecrets resolve them.
PHPBB_DB_PASSWORD="$(openssl rand -base64 24)"
PHPBB_DB_APP_PASSWORD="$(openssl rand -base64 24)"
PHPBB_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# route-access-db per-machine-user least-privilege passwords. The owner (DDL) plus
# one password per consuming machine-user: admin-bff (the ONLY writer) and the
# three gateways (read-only). Each gateway/admin-bff Deployment mounts ONLY its own
# password; the route-access-db pod seeds all four roles from route-access-db-roles.
ROUTE_ACCESS_OWNER_PASSWORD="$(openssl rand -base64 24)"
ROUTE_ACCESS_ADMIN_BFF_PASSWORD="$(openssl rand -base64 24)"
ROUTE_ACCESS_PKI_GATEWAY_PASSWORD="$(openssl rand -base64 24)"
ROUTE_ACCESS_BE_GATEWAY_PASSWORD="$(openssl rand -base64 24)"
ROUTE_ACCESS_FE_GATEWAY_PASSWORD="$(openssl rand -base64 24)"

UPTRACE_PG_PASSWORD="$(openssl rand -base64 24)"
UPTRACE_PROJECT_TOKEN="$(openssl rand -hex 32)"

# ── Vault token (real, or a generated placeholder for the bundle) ───
if [ -n "${VAULT_TOKEN:-}" ]; then
    BUNDLE_TOKEN="${VAULT_TOKEN}"
    TOKEN_KIND="from VAULT_TOKEN"
else
    BUNDLE_TOKEN="PLACEHOLDER-$(openssl rand -hex 24)"
    TOKEN_KIND="generated placeholder (no VAULT_TOKEN set)"
fi

# ── ONLINE: write to Vault if configured ────────────────────────────
if [ -n "${VAULT_ADDR:-}" ] && [ -n "${VAULT_TOKEN:-}" ]; then
    if command -v vault >/dev/null; then
        echo "==> VAULT_ADDR set; writing to Vault (${VAULT_ADDR}, mount ${VAULT_KV_MOUNT})"
        export VAULT_ADDR VAULT_TOKEN
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/casdoor" \
            google_client_id="${CASDOOR_GOOGLE_CLIENT_ID}" \
            google_client_secret="${CASDOOR_GOOGLE_CLIENT_SECRET}" \
            github_client_id="${CASDOOR_GITHUB_CLIENT_ID}" \
            github_client_secret="${CASDOOR_GITHUB_CLIENT_SECRET}" \
            discord_client_id="${CASDOOR_DISCORD_CLIENT_ID}" \
            discord_client_secret="${CASDOOR_DISCORD_CLIENT_SECRET}" \
            client_id="${CASDOOR_CLIENT_ID}" \
            client_secret="${CASDOOR_CLIENT_SECRET}" \
            admin_password="${CASDOOR_ADMIN_HASH}" \
            admin_password_plain="${CASDOOR_ADMIN_PLAIN}" \
            db_password_plain="${CASDOOR_DB_PASSWORD}"
        # Per-app service OAuth2 client-secrets (one KV key per app).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/casdoor-apps" "${CASDOOR_APP_KV_ARGS[@]}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/casdoor-superadmin" \
            username="${CASDOOR_SUPERADMIN_USERNAME}" \
            password="${CASDOOR_SUPERADMIN_PASSWORD}"
        # GAMES-realm Casdoor (casdoor-games) — separate path, separate instance.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/casdoor-games" \
            client_secret="${CASDOOR_GAMES_CLIENT_SECRET}" \
            admin_password_plain="${CASDOOR_GAMES_ADMIN_PLAIN}" \
            db_password_plain="${CASDOOR_GAMES_DB_PASSWORD}" \
            github_client_id="${CASDOOR_GAMES_GITHUB_CLIENT_ID}" \
            github_client_secret="${CASDOOR_GAMES_GITHUB_CLIENT_SECRET}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/clickhouse" \
            password="${CLICKHOUSE_PASSWORD}"
        # Dedicated per-app Postgres passwords (federation-db / admin-bff-db /
        # mod-bff-db / user-bff-db): owner `password` (DDL) + `app_password`
        # (non-owner least-privilege runtime role).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/federation-db" \
            password="${FEDERATION_DB_PASSWORD}" \
            app_password="${FEDERATION_DB_APP_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/admin-bff-db" \
            password="${ADMIN_BFF_DB_PASSWORD}" \
            app_password="${ADMIN_BFF_DB_APP_PASSWORD}"
        # admin-bff MFA TOTP-secret encryption key (app.mfa.factor-key). Own path so
        # it is independent of the admin-bff DB creds. SHIPS DARK (MFA off by default).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/admin-bff-mfa" \
            factor_key="${ADMIN_BFF_MFA_FACTOR_KEY}"
        # SSO back-channel secrets. Seeded alongside the DB creds so the ESO
        # ExternalSecrets in sso-externalsecrets.yaml resolve on first ArgoCD sync.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/user-bff-custody-key" \
            key="${USER_BFF_CUSTODY_KEY}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/user-bff-hs-token" \
            key="${USER_BFF_HS_TOKEN_KEY}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/bff-internal-token" \
            token="${BFF_INTERNAL_TOKEN}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/mod-bff-db" \
            password="${MOD_BFF_DB_PASSWORD}" \
            app_password="${MOD_BFF_DB_APP_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/user-bff-db" \
            password="${USER_BFF_DB_PASSWORD}" \
            app_password="${USER_BFF_DB_APP_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/forum-bff-db" \
            password="${FORUM_BFF_DB_PASSWORD}" \
            app_password="${FORUM_BFF_DB_APP_PASSWORD}"
        # phpBB forum (backend-only, isolated snapdragon-forum ns). phpbb-secrets
        # multi-key (DB_PASSWORD owner + ADMIN_PASSWORD first-install admin) at
        # /forum; the phpbb_app runtime role password at /forum-db (app_password).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/forum" \
            DB_PASSWORD="${PHPBB_DB_PASSWORD}" \
            ADMIN_PASSWORD="${PHPBB_ADMIN_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/forum-db" \
            app_password="${PHPBB_DB_APP_PASSWORD}"
        # route-access-db per-machine-user least-privilege passwords (owner + the
        # four consumers). admin-bff = writer; pki/be/fe-gateway = read-only.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/route-access-db" \
            owner_password="${ROUTE_ACCESS_OWNER_PASSWORD}" \
            admin_bff_password="${ROUTE_ACCESS_ADMIN_BFF_PASSWORD}" \
            pki_gateway_password="${ROUTE_ACCESS_PKI_GATEWAY_PASSWORD}" \
            be_gateway_password="${ROUTE_ACCESS_BE_GATEWAY_PASSWORD}" \
            fe_gateway_password="${ROUTE_ACCESS_FE_GATEWAY_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/uptrace" \
            pg_password="${UPTRACE_PG_PASSWORD}" \
            project_token="${UPTRACE_PROJECT_TOKEN}"
        # Outbound mail (OPTIONAL). Empty props when disabled => ESO renders blank
        # casdoor-smtp/akkoma-smtp Secrets that the manifests treat as "no SMTP".
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/mail" \
            provider="${MAIL_PROVIDER}" \
            host="${MAIL_HOST}" \
            port="${MAIL_PORT}" \
            tls="${MAIL_TLS}" \
            user="${MAIL_USER}" \
            password="${MAIL_PASSWORD}" \
            from="${MAIL_FROM}" \
            dkim_key="${MAIL_DKIM}"
        # GitLab registry pull token (imagePullSecret source). Replace the
        # placeholder with a real read_registry deploy token post-bootstrap.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/gitlab-registry" \
            username="${GITLAB_REGISTRY_USER}" \
            token="${GITLAB_REGISTRY_TOKEN}"
        # In-cluster image-builder PUSH token (the Kaniko build pipeline's push
        # credential). Replace the placeholder with a real WRITE_REGISTRY deploy
        # token post-bootstrap. Materialized by ESO into the opt-in build namespace.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/image-builder-registry" \
            username="${IMAGE_BUILDER_REGISTRY_USER}" \
            token="${IMAGE_BUILDER_REGISTRY_TOKEN}"
        echo "    wrote ${VAULT_KV_MOUNT}/${BASE}/{casdoor,casdoor-apps,casdoor-superadmin,casdoor-games,clickhouse,federation-db,admin-bff-db,admin-bff-mfa,user-bff-custody-key,user-bff-hs-token,bff-internal-token,mod-bff-db,user-bff-db,forum-bff-db,forum,forum-db,route-access-db,uptrace,mail,gitlab-registry,image-builder-registry}"
    else
        echo "WARNING: VAULT_ADDR is set but the 'vault' CLI is not installed;" >&2
        echo "         skipping the online write. Writing the offline bundle only." >&2
    fi
else
    echo "==> VAULT_ADDR/VAULT_TOKEN not both set; offline (USB-only) delivery"
fi

# ── OFFLINE: always write the bundle (secrets.json + token) ─────────
mkdir -p "${OUT_DIR}"
SECRETS_JSON="${OUT_DIR}/secrets.json"
TOKEN_FILE="${OUT_DIR}/token"

# Emit valid JSON via python3 (jq may be absent on the host). The shape is the
# materialized k8s Secrets: namespace -> secretName -> k8sKey -> value.
# Per-app service secrets as a JSON object {app: secret} for the bundle.
CASDOOR_APP_SECRETS_JSON="{"
_first=1
for _var in "${CASDOOR_APP_JSON_ENV[@]}"; do
    _app="$(echo "${_var#APPSEC_}" | tr 'A-Z_' 'a-z-')"
    [ "${_first}" = 1 ] || CASDOOR_APP_SECRETS_JSON+=","
    CASDOOR_APP_SECRETS_JSON+="\"${_app}\":\"${!_var}\""; _first=0
done
CASDOOR_APP_SECRETS_JSON+="}"

BRAND="${BRAND}" \
CASDOOR_GOOGLE_CLIENT_ID="${CASDOOR_GOOGLE_CLIENT_ID}" \
CASDOOR_GOOGLE_CLIENT_SECRET="${CASDOOR_GOOGLE_CLIENT_SECRET}" \
CASDOOR_GITHUB_CLIENT_ID="${CASDOOR_GITHUB_CLIENT_ID}" \
CASDOOR_GITHUB_CLIENT_SECRET="${CASDOOR_GITHUB_CLIENT_SECRET}" \
CASDOOR_DISCORD_CLIENT_ID="${CASDOOR_DISCORD_CLIENT_ID}" \
CASDOOR_DISCORD_CLIENT_SECRET="${CASDOOR_DISCORD_CLIENT_SECRET}" \
MAIL_ENABLED="${MAIL_ENABLED}" \
MAIL_HOST="${MAIL_HOST}" \
MAIL_PORT="${MAIL_PORT}" \
MAIL_TLS="${MAIL_TLS}" \
MAIL_USER="${MAIL_USER}" \
MAIL_PASSWORD="${MAIL_PASSWORD}" \
MAIL_FROM="${MAIL_FROM}" \
CASDOOR_ADMIN_PLAIN="${CASDOOR_ADMIN_PLAIN}" \
CASDOOR_SUPERADMIN_USERNAME="${CASDOOR_SUPERADMIN_USERNAME}" \
CASDOOR_SUPERADMIN_PASSWORD="${CASDOOR_SUPERADMIN_PASSWORD}" \
CASDOOR_DB_PASSWORD="${CASDOOR_DB_PASSWORD}" \
CASDOOR_CLIENT_ID="${CASDOOR_CLIENT_ID}" \
CASDOOR_CLIENT_SECRET="${CASDOOR_CLIENT_SECRET}" \
CASDOOR_GAMES_ADMIN_PLAIN="${CASDOOR_GAMES_ADMIN_PLAIN}" \
CASDOOR_GAMES_DB_PASSWORD="${CASDOOR_GAMES_DB_PASSWORD}" \
CASDOOR_GAMES_CLIENT_SECRET="${CASDOOR_GAMES_CLIENT_SECRET}" \
CASDOOR_GAMES_GITHUB_CLIENT_ID="${CASDOOR_GAMES_GITHUB_CLIENT_ID}" \
CASDOOR_GAMES_GITHUB_CLIENT_SECRET="${CASDOOR_GAMES_GITHUB_CLIENT_SECRET}" \
CASDOOR_APP_SECRETS_JSON="${CASDOOR_APP_SECRETS_JSON}" \
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD}" \
FEDERATION_DB_PASSWORD="${FEDERATION_DB_PASSWORD}" \
ADMIN_BFF_DB_PASSWORD="${ADMIN_BFF_DB_PASSWORD}" \
MOD_BFF_DB_PASSWORD="${MOD_BFF_DB_PASSWORD}" \
USER_BFF_DB_PASSWORD="${USER_BFF_DB_PASSWORD}" \
FORUM_BFF_DB_PASSWORD="${FORUM_BFF_DB_PASSWORD}" \
FEDERATION_DB_APP_PASSWORD="${FEDERATION_DB_APP_PASSWORD}" \
ADMIN_BFF_DB_APP_PASSWORD="${ADMIN_BFF_DB_APP_PASSWORD}" \
ADMIN_BFF_MFA_FACTOR_KEY="${ADMIN_BFF_MFA_FACTOR_KEY}" \
USER_BFF_CUSTODY_KEY="${USER_BFF_CUSTODY_KEY}" \
USER_BFF_HS_TOKEN_KEY="${USER_BFF_HS_TOKEN_KEY}" \
BFF_INTERNAL_TOKEN="${BFF_INTERNAL_TOKEN}" \
MOD_BFF_DB_APP_PASSWORD="${MOD_BFF_DB_APP_PASSWORD}" \
USER_BFF_DB_APP_PASSWORD="${USER_BFF_DB_APP_PASSWORD}" \
FORUM_BFF_DB_APP_PASSWORD="${FORUM_BFF_DB_APP_PASSWORD}" \
PHPBB_DB_PASSWORD="${PHPBB_DB_PASSWORD}" \
PHPBB_DB_APP_PASSWORD="${PHPBB_DB_APP_PASSWORD}" \
PHPBB_ADMIN_PASSWORD="${PHPBB_ADMIN_PASSWORD}" \
ROUTE_ACCESS_OWNER_PASSWORD="${ROUTE_ACCESS_OWNER_PASSWORD}" \
ROUTE_ACCESS_ADMIN_BFF_PASSWORD="${ROUTE_ACCESS_ADMIN_BFF_PASSWORD}" \
ROUTE_ACCESS_PKI_GATEWAY_PASSWORD="${ROUTE_ACCESS_PKI_GATEWAY_PASSWORD}" \
ROUTE_ACCESS_BE_GATEWAY_PASSWORD="${ROUTE_ACCESS_BE_GATEWAY_PASSWORD}" \
ROUTE_ACCESS_FE_GATEWAY_PASSWORD="${ROUTE_ACCESS_FE_GATEWAY_PASSWORD}" \
UPTRACE_PG_PASSWORD="${UPTRACE_PG_PASSWORD}" \
UPTRACE_PROJECT_TOKEN="${UPTRACE_PROJECT_TOKEN}" \
python3 - "${SECRETS_JSON}" <<'PY'
import json, os, sys

brand = os.environ["BRAND"]
app_secrets = json.loads(os.environ["CASDOOR_APP_SECRETS_JSON"])
data = {
    f"{brand}-pki": {
        "casdoor-google": {
            "clientId": os.environ["CASDOOR_GOOGLE_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_GOOGLE_CLIENT_SECRET"],
        },
        # GitHub / Discord OAuth federation clients (optional providers). Always
        # emitted (placeholder until the operator supplies reals), mirroring the
        # casdoor-github / casdoor-discord ExternalSecrets. The casdoor-init Job
        # seeds the provider only when the value is non-placeholder/non-empty.
        "casdoor-github": {
            "clientId": os.environ["CASDOOR_GITHUB_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_GITHUB_CLIENT_SECRET"],
        },
        "casdoor-discord": {
            "clientId": os.environ["CASDOOR_DISCORD_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_DISCORD_CLIENT_SECRET"],
        },
        # admin plaintext for the casdoor-init Job's API login.
        "casdoor-admin": {
            "username": "admin",
            "password": os.environ["CASDOOR_ADMIN_PLAIN"],
        },
        # platform SUPERADMIN bootstrap user (casdoor-init creates + assigns ROLE_SUPERADMIN).
        "casdoor-superadmin": {
            "username": os.environ["CASDOOR_SUPERADMIN_USERNAME"],
            "password": os.environ["CASDOOR_SUPERADMIN_PASSWORD"],
        },
        # external Postgres (casdoor-pg) credentials for Casdoor + the DB pod.
        "casdoor-db": {
            "username": "casdoor",
            "password": os.environ["CASDOOR_DB_PASSWORD"],
        },
        # one key per app: the OAuth2 application client-secret.
        "casdoor-app-secrets": app_secrets,
        # route-access-db pod role passwords (owner + the four machine-users). The
        # DB pod seeds every login role from this Secret; the consumers each mount
        # only their own matching per-namespace Secret with the SAME value.
        "route-access-db-roles": {
            "owner_password":        os.environ["ROUTE_ACCESS_OWNER_PASSWORD"],
            "admin_bff_password":    os.environ["ROUTE_ACCESS_ADMIN_BFF_PASSWORD"],
            "pki_gateway_password":  os.environ["ROUTE_ACCESS_PKI_GATEWAY_PASSWORD"],
            "be_gateway_password":   os.environ["ROUTE_ACCESS_BE_GATEWAY_PASSWORD"],
            "fe_gateway_password":   os.environ["ROUTE_ACCESS_FE_GATEWAY_PASSWORD"],
        },
        # pki-gateway's OWN read-only route-access password (user pki_gateway).
        "route-access-pki-gateway": {
            "password": os.environ["ROUTE_ACCESS_PKI_GATEWAY_PASSWORD"],
        },
    },
    f"{brand}-backend": {
        "clickhouse-auth": {
            "password": os.environ["CLICKHOUSE_PASSWORD"],
        },
        # Dedicated per-app Postgres OWNER passwords (DDL/Liquibase). The DB pod and
        # its consumer both reference the same Secret. Mirrors clickhouse-auth.
        "federation-db-auth": {
            "password": os.environ["FEDERATION_DB_PASSWORD"],
        },
        "admin-bff-db-auth": {
            "password": os.environ["ADMIN_BFF_DB_PASSWORD"],
        },
        "mod-bff-db-auth": {
            "password": os.environ["MOD_BFF_DB_PASSWORD"],
        },
        "user-bff-db-auth": {
            "password": os.environ["USER_BFF_DB_PASSWORD"],
        },
        "forum-bff-db-auth": {
            "password": os.environ["FORUM_BFF_DB_PASSWORD"],
        },
        # Non-owner least-privilege RUNTIME role passwords (federation_app etc.).
        "federation-db-app-auth": {
            "password": os.environ["FEDERATION_DB_APP_PASSWORD"],
        },
        "admin-bff-db-app-auth": {
            "password": os.environ["ADMIN_BFF_DB_APP_PASSWORD"],
        },
        # admin-bff MFA TOTP-secret encryption key (app.mfa.factor-key /
        # APP_MFA_FACTOR_KEY). The k8s key is `factor-key`; the admin-bff
        # Deployment mounts it via secretKeyRef. SHIPS DARK (MFA off by default).
        "admin-bff-mfa": {
            "factor-key": os.environ["ADMIN_BFF_MFA_FACTOR_KEY"],
        },
        # SSO back-channel secrets. Three independent Vault paths so each
        # ExternalSecret materializes a focused single-key k8s Secret.
        # user-bff-custody-key: AES-256-GCM key for BffCustodyCipher (APP_BFF_CUSTODY_KEY).
        "user-bff-custody-key": {
            "key": os.environ["USER_BFF_CUSTODY_KEY"],
        },
        # user-bff-hs-token: homeserver-native token custody key (APP_HS_TOKEN_KEY).
        # Pre-existing ESO + deployment wiring; this closes the bootstrap gap.
        "user-bff-hs-token": {
            "key": os.environ["USER_BFF_HS_TOKEN_KEY"],
        },
        # bff-internal-token: shared back-channel auth token (INTERNAL_TOKEN).
        # Mounted in BOTH snapdragon-backend (user-bff) and snapdragon-frontend
        # (fe-gateway); the frontend entry is added below.
        "bff-internal-token": {
            "token": os.environ["BFF_INTERNAL_TOKEN"],
        },
        "mod-bff-db-app-auth": {
            "password": os.environ["MOD_BFF_DB_APP_PASSWORD"],
        },
        "user-bff-db-app-auth": {
            "password": os.environ["USER_BFF_DB_APP_PASSWORD"],
        },
        "forum-bff-db-app-auth": {
            "password": os.environ["FORUM_BFF_DB_APP_PASSWORD"],
        },
        # route-access machine-user passwords reachable from the backend ns:
        # be-gateway (read-only) + admin-bff (writer). Each Deployment mounts ONLY
        # its own Secret; the value matches the route-access-db-roles key (pki ns).
        "route-access-be-gateway": {
            "password": os.environ["ROUTE_ACCESS_BE_GATEWAY_PASSWORD"],
        },
        "route-access-admin-bff": {
            "password": os.environ["ROUTE_ACCESS_ADMIN_BFF_PASSWORD"],
        },
        # snapdragon-actions two-Casdoor sync: admin client per side. SYSTEMS side
        # reuses the systems Casdoor OIDC client; GAMES side reuses threewizards-app.
        "casdoor-sync-systems": {
            "clientId": os.environ["CASDOOR_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_CLIENT_SECRET"],
        },
        "casdoor-sync-games": {
            "clientId": "twclient001",
            "clientSecret": os.environ["CASDOOR_GAMES_CLIENT_SECRET"],
        },
    },
    # GAMES-realm Casdoor (casdoor-games) — SEPARATE instance in the games namespace.
    f"{brand}-games": {
        "casdoor-games-db": {
            "username": "threewizards",
            "password": os.environ["CASDOOR_GAMES_DB_PASSWORD"],
        },
        "casdoor-games-admin": {
            "username": "admin",
            "password": os.environ["CASDOOR_GAMES_ADMIN_PLAIN"],
        },
        "casdoor-games-app": {
            "clientId": "twclient001",
            "clientSecret": os.environ["CASDOOR_GAMES_CLIENT_SECRET"],
        },
        "casdoor-games-github": {
            "clientId": os.environ["CASDOOR_GAMES_GITHUB_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_GAMES_GITHUB_CLIENT_SECRET"],
        },
    },
    # fe-gateway runs in the frontend ns and needs its OWN read-only route-access
    # password (user fe_gateway); value matches the route-access-db-roles key.
    # bff-internal-token is also mounted here — same value as the backend ns entry,
    # same Vault path; the ESO fetches it independently per namespace.
    f"{brand}-frontend": {
        "route-access-fe-gateway": {
            "password": os.environ["ROUTE_ACCESS_FE_GATEWAY_PASSWORD"],
        },
        "bff-internal-token": {
            "token": os.environ["BFF_INTERNAL_TOKEN"],
        },
    },
    # phpBB forum — the ISOLATED backend-only namespace (phpBB + phpbb-db). phpbb-db
    # OWNER + first-install admin in phpbb-secrets (multi-key); the phpbb_app runtime
    # role in phpbb-db-app-auth; the forum-admin-sync Job reuses casdoor-app-secrets.
    f"{brand}-forum": {
        "phpbb-secrets": {
            "DB_PASSWORD": os.environ["PHPBB_DB_PASSWORD"],
            "ADMIN_PASSWORD": os.environ["PHPBB_ADMIN_PASSWORD"],
        },
        "phpbb-db-app-auth": {
            "password": os.environ["PHPBB_DB_APP_PASSWORD"],
        },
        "casdoor-app-secrets": app_secrets,
    },
    "observability": {
        "clickhouse-auth": {
            "password": os.environ["CLICKHOUSE_PASSWORD"],
        },
        "uptrace-auth": {
            "pg-password": os.environ["UPTRACE_PG_PASSWORD"],
            "project-token": os.environ["UPTRACE_PROJECT_TOKEN"],
        },
    },
}

# ── Outbound mail (OPTIONAL, ABSENT-BY-DEFAULT) ─────────────────────
# Only emit the casdoor-smtp / akkoma-smtp Secrets into the offline bundle when
# mail is ENABLED (real user+password resolved). When disabled we emit NOTHING,
# so provisioning never creates an (empty) SMTP Secret and the casdoor/akkoma
# manifests stay on native login + admin-approval — no mail wired. The k8s keys
# below mirror the casdoor-smtp / akkoma-smtp ExternalSecret template.data shapes.
if os.environ.get("MAIL_ENABLED") == "1":
    data[f"{brand}-pki"]["casdoor-smtp"] = {
        "CASDOOR_SMTP_HOST": os.environ["MAIL_HOST"],
        "CASDOOR_SMTP_PORT": os.environ["MAIL_PORT"],
        "CASDOOR_SMTP_USER": os.environ["MAIL_USER"],
        "CASDOOR_SMTP_PASSWORD": os.environ["MAIL_PASSWORD"],
        "CASDOOR_SMTP_FROM": os.environ["MAIL_FROM"],
    }
    data[f"{brand}-backend"]["akkoma-smtp"] = {
        "AKKOMA_SMTP_RELAY": os.environ["MAIL_HOST"],
        "AKKOMA_SMTP_PORT": os.environ["MAIL_PORT"],
        "AKKOMA_SMTP_USER": os.environ["MAIL_USER"],
        "AKKOMA_SMTP_PASSWORD": os.environ["MAIL_PASSWORD"],
        "AKKOMA_SMTP_TLS": os.environ["MAIL_TLS"],
        "AKKOMA_SMTP_FROM": os.environ["MAIL_FROM"],
    }

with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY

printf '%s\n' "${BUNDLE_TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}" "${SECRETS_JSON}" 2>/dev/null || true

# ── Summary ─────────────────────────────────────────────────────────
echo
echo "Done. Offline bundle written to ${OUT_DIR}:"
echo "  ${SECRETS_JSON}   (namespace -> secretName -> key -> value)"
echo "  ${TOKEN_FILE}         (Vault token: ${TOKEN_KIND})"
echo
echo "Casdoor admin password (PLAINTEXT, shown once — seed Casdoor with this):"
echo "  ${CASDOOR_ADMIN_PLAIN}"
echo "  (a -6 hash is what was stored under secret/${BASE}/casdoor.admin_password)"
echo
echo "Note: casdoor google/github/discord client_id/secret are placeholders unless"
echo "      supplied via env (GITHUB_CLIENT_ID/…, DISCORD_CLIENT_ID/…) or the keys"
echo "      file (${KEYS_FILE}). The casdoor-init Job skips seeding a provider whose"
echo "      secret is still a placeholder. Replace them with your real OAuth creds."
if [ "${MAIL_ENABLED}" = "1" ]; then
    echo
    echo "Mail: ENABLED (provider=${MAIL_PROVIDER}, ${MAIL_HOST}:${MAIL_PORT}, from=${MAIL_FROM})."
    echo "      casdoor-smtp + akkoma-smtp Secrets are in Vault and the offline bundle."
else
    echo
    echo "Mail: DISABLED (no MAIL_USER/MAIL_PASSWORD or MAIL_PROVIDER=none). No SMTP is"
    echo "      wired; casdoor/akkoma stay on native login + admin-approval registration."
fi
echo
echo "Next:"
echo "  - Copy ${OUT_DIR} onto the KEYS stick under vault/, or"
echo "  - Run scripts/make-keys-usb.sh, which picks up keys-out/vault automatically."
