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

# Casdoor external Postgres (casdoor-pg) password. The DB user is the fixed
# "casdoor" (set in the casdoor-db ExternalSecret template); only the password
# is minted/stored.
CASDOOR_DB_PASSWORD="$(openssl rand -base64 24)"

# Google OAuth client values are issued by Google; generate placeholders the
# operator replaces. They still populate the casdoor-google k8s Secret.
CASDOOR_GOOGLE_CLIENT_ID="REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID"
CASDOOR_GOOGLE_CLIENT_SECRET="REPLACE_WITH_GOOGLE_OAUTH_CLIENT_SECRET"

# GitLab registry pull credentials — a GROUP DEPLOY TOKEN (scope: read_registry)
# created by an admin in GitLab. Placeholders the operator replaces; ESO builds
# the gitlab-registry dockerconfigjson imagePullSecret from these in each app
# namespace. (In-cluster registry, so no offline-bundle entry.)
GITLAB_REGISTRY_USER="${GITLAB_REGISTRY_USER:-snapdragon-deploy}"
GITLAB_REGISTRY_TOKEN="${GITLAB_REGISTRY_TOKEN:-REPLACE_WITH_GITLAB_DEPLOY_TOKEN}"

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
CASDOOR_APPS="pki-gateway be-gateway fe-gateway auth api admin-bff matrix mastodon"
CASDOOR_APP_KV_ARGS=()
CASDOOR_APP_JSON_ENV=()
for _app in ${CASDOOR_APPS}; do
    _sec="$(openssl rand -hex 32)"
    _var="APPSEC_$(echo "${_app}" | tr 'a-z-' 'A-Z_')"
    printf -v "${_var}" '%s' "${_sec}"
    CASDOOR_APP_KV_ARGS+=("${_app}=${_sec}")
    CASDOOR_APP_JSON_ENV+=("${_var}")
done

CLICKHOUSE_PASSWORD="$(openssl rand -base64 24)"

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
            client_id="${CASDOOR_CLIENT_ID}" \
            client_secret="${CASDOOR_CLIENT_SECRET}" \
            admin_password="${CASDOOR_ADMIN_HASH}" \
            admin_password_plain="${CASDOOR_ADMIN_PLAIN}" \
            db_password_plain="${CASDOOR_DB_PASSWORD}"
        # Per-app service OAuth2 client-secrets (one KV key per app).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/casdoor-apps" "${CASDOOR_APP_KV_ARGS[@]}"
        # GAMES-realm Casdoor (casdoor-games) — separate path, separate instance.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/casdoor-games" \
            client_secret="${CASDOOR_GAMES_CLIENT_SECRET}" \
            admin_password_plain="${CASDOOR_GAMES_ADMIN_PLAIN}" \
            db_password_plain="${CASDOOR_GAMES_DB_PASSWORD}" \
            github_client_id="${CASDOOR_GAMES_GITHUB_CLIENT_ID}" \
            github_client_secret="${CASDOOR_GAMES_GITHUB_CLIENT_SECRET}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/clickhouse" \
            password="${CLICKHOUSE_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/uptrace" \
            pg_password="${UPTRACE_PG_PASSWORD}" \
            project_token="${UPTRACE_PROJECT_TOKEN}"
        # GitLab registry pull token (imagePullSecret source). Replace the
        # placeholder with a real read_registry deploy token post-bootstrap.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/gitlab-registry" \
            username="${GITLAB_REGISTRY_USER}" \
            token="${GITLAB_REGISTRY_TOKEN}"
        echo "    wrote ${VAULT_KV_MOUNT}/${BASE}/{casdoor,casdoor-apps,casdoor-games,clickhouse,uptrace,gitlab-registry}"
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
CASDOOR_ADMIN_PLAIN="${CASDOOR_ADMIN_PLAIN}" \
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
        # admin plaintext for the casdoor-init Job's API login.
        "casdoor-admin": {
            "username": "admin",
            "password": os.environ["CASDOOR_ADMIN_PLAIN"],
        },
        # external Postgres (casdoor-pg) credentials for Casdoor + the DB pod.
        "casdoor-db": {
            "username": "casdoor",
            "password": os.environ["CASDOOR_DB_PASSWORD"],
        },
        # one key per app: the OAuth2 application client-secret.
        "casdoor-app-secrets": app_secrets,
    },
    f"{brand}-backend": {
        "clickhouse-auth": {
            "password": os.environ["CLICKHOUSE_PASSWORD"],
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
echo "Note: casdoor google_client_id/secret are placeholders — replace them with"
echo "      your real Google OAuth credentials (in Vault and/or the bundle)."
echo
echo "Next:"
echo "  - Copy ${OUT_DIR} onto the KEYS stick under vault/, or"
echo "  - Run scripts/make-keys-usb.sh, which picks up keys-out/vault automatically."
