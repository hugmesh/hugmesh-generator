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

# Google OAuth client values are issued by Google; generate placeholders the
# operator replaces. They still populate the casdoor-google k8s Secret.
CASDOOR_GOOGLE_CLIENT_ID="REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID"
CASDOOR_GOOGLE_CLIENT_SECRET="REPLACE_WITH_GOOGLE_OAUTH_CLIENT_SECRET"

# Casdoor's own OIDC application client_id / client_secret (used by the BFF).
CASDOOR_CLIENT_ID="$(openssl rand -hex 16)"
CASDOOR_CLIENT_SECRET="$(openssl rand -hex 32)"

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
            admin_password="${CASDOOR_ADMIN_HASH}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/clickhouse" \
            password="${CLICKHOUSE_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/uptrace" \
            pg_password="${UPTRACE_PG_PASSWORD}" \
            project_token="${UPTRACE_PROJECT_TOKEN}"
        echo "    wrote ${VAULT_KV_MOUNT}/${BASE}/{casdoor,clickhouse,uptrace}"
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
BRAND="${BRAND}" \
CASDOOR_GOOGLE_CLIENT_ID="${CASDOOR_GOOGLE_CLIENT_ID}" \
CASDOOR_GOOGLE_CLIENT_SECRET="${CASDOOR_GOOGLE_CLIENT_SECRET}" \
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD}" \
UPTRACE_PG_PASSWORD="${UPTRACE_PG_PASSWORD}" \
UPTRACE_PROJECT_TOKEN="${UPTRACE_PROJECT_TOKEN}" \
python3 - "${SECRETS_JSON}" <<'PY'
import json, os, sys

brand = os.environ["BRAND"]
data = {
    f"{brand}-pki": {
        "casdoor-google": {
            "clientId": os.environ["CASDOOR_GOOGLE_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_GOOGLE_CLIENT_SECRET"],
        },
    },
    f"{brand}-backend": {
        "clickhouse-auth": {
            "password": os.environ["CLICKHOUSE_PASSWORD"],
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
