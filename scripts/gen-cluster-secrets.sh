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

# ── credentials that get EMBEDDED IN A URL ───────────────────────────────────
# `openssl rand -base64` draws from the base64 alphabet, which includes + / and =.
# A password carrying any of those cannot survive being interpolated into a URL:
#
#     r2dbc:postgresql://fe_gateway:$(ROUTE_ACCESS_DB_PASSWORD)@route-access-db...
#
# R2DBC parses that with ConnectionFactoryOptions.parse(), which URL-DECODES the
# userinfo — so a literal `+` arrives at Postgres as a SPACE and authentication
# fails. `/` ends the authority early; `=` is harmless here but is dropped for the
# same reason: this alphabet has no business in a URL.
#
# THE FAILURE IS SILENT AND IT FAILS OPEN. When a gateway cannot reach
# route-access-db it has no route_access rows, so it enforces NOTHING: a plain
# ROLE_USER gets HTTP 200 with the admin UI shell. Nothing logs "RBAC is off".
#
# NOT HYPOTHETICAL, AND NOT RARE. A 24-byte base64 string is 32 characters, each
# with a 2-in-64 chance of being + or /, so ~63% of bootstraps mint at least one
# unusable route-access credential. Measured on the live kind cluster on
# 2026-08-27: THREE of the six route-access passwords contained `+`, two of them
# (fe_gateway, pki_gateway) on gateways whose URL embeds it.
#
# base64url keeps every bit of entropy (same byte count) and its alphabet
# [A-Za-z0-9-_] is entirely URI-unreserved, so it needs no escaping anywhere.
rand_urlsafe() { # <bytes> -> unpadded base64url
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '='
}


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${REPO_DIR}/keys-out/vault"

# ── brand.conf (built-in defaults < brand.conf < env) ───────────────
BRAND="${BRAND:-hugmesh}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-hugmesh.net}"
# VAULT_ADDR NEVER REACHES THE ClusterSecretStore, ON PURPOSE (issue #531, decision
# 88 = B): VAULT_ADDR only steers the WRITE side (this script). The reader's
# spec.provider.vault.server in secretstore.yaml is pinned to the in-cluster
# https://vault.vault.svc.cluster.local:8200 and an external Vault is not a supported
# topology, so pointing VAULT_ADDR elsewhere writes secrets the cluster will not read.
# tests/scripts/test-eso-provider-refs.sh pins that literal and this paragraph.
# THE MOUNT IS STILL WRITER-SIDE ONLY; THE BASE PATH IS NOT ANY MORE.
# (issue #285; decision 22 on #347, operator 2026-09-16 "A: drop both controls";
#  decision 38 = B on #347, operator 2026-09-17 "the reader follows the writer"):
#   * the MOUNT is pinned in specs/cluster/manifests/external-secrets/secretstore.yaml
#     (`path: "secret"`, server vault.vault.svc), which apps/04-external-secrets-config
#     .yaml serves with automated { prune: true, selfHeal: true } — ArgoCD re-applies
#     it from git on every reconcile, so nothing image-side or kubectl-side re-points it;
#   * the BASE PATH now FOLLOWS THIS WRITER. The 143 `key: hugmesh/…` literals under
#     specs/cluster are the DEFAULT RENDER and must stay byte-identical in git, because
#     ArgoCD fetches those manifests FROM GIT and every mesh gets the same bytes. What
#     moves is the render: the ClusterSecretStore carries the annotation
#     platform.hugmesh.net/vault-base, a `replacements` block in that directory's
#     kustomization.yaml copies it into the first segment of all 121 served remoteRef
#     keys, apps/04-external-secrets-config.yaml carries a one-line kustomize op that
#     SETS the annotation, and rebrand_sysroot() in every build-*-stage4.sh rewrites
#     that one value to <BRAND> — the Application object is applied from the image's
#     BAKED tree, so it is the only brand-aware thing on ArgoCD's serving path.
#     apps/12-cloudflared.yaml does the same for its one key, and
#     apps/03b-harbor-provision.yaml moves the SECOND writer (the in-cluster
#     harbor-provision Job's VAULT_KV_BASE) with it. Pinned end to end by
#     tests/scripts/test-eso-remoteref-brand.sh, which renders the baked Application
#     against the git manifests through real kustomize.
#     WHAT THIS REPLACED — and the trap to avoid if you re-derive it: a sed over the
#     baked manifests copy at ${SYSROOT}/var/lib/hugmesh/cluster/manifests is INERT.
#     bootstrap.sh applies from the baked tree only namespaces/, manifests/local-path
#     and apps/*.yaml; the manifests those Applications point at come from the git
#     repoURL. Measured against the live cluster on the build host, 2026-09-17:
#     external-secrets-config -> repoURL github.com/hugmesh/hugmesh-generator.git @ main,
#     path specs/cluster/manifests/external-secrets.
# So a NON-DEFAULT VAULT_KV_MOUNT still makes this script write where the cluster does
# not read: the MOUNT half is unchanged and remains pinned at "secret" by
# secretstore.yaml under a prune+selfHeal Application. Decision 38 moved the BASE PATH
# half only. The matching image-builder flags --vault-kv-mount / --vault-base-path were
# removed by decision 22.
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
  BRAND           Brand slug = Vault base path segment. Default: hugmesh
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

BASE="${BRAND:-hugmesh}"

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
# LocalTube (DEFAULT-OFF optional slug). The path is seeded UNCONDITIONALLY —
# same contract as every other secret here: materializing only SOURCES values,
# it does not enable the slug. media_key/token_dek are minted; the Google
# OAuth2 client is issued by Google, so placeholders the operator replaces
# (the tube slug's YouTube sync simply fails auth until they are real).
# NOTHING seeded this path before, so even the DECLARED tube ExternalSecrets
# (tube-media-key / tube-token-dek) could never materialize on slug enable.
TUBE_MEDIA_KEY="$(openssl rand -base64 32)"
TUBE_TOKEN_DEK="$(openssl rand -base64 32)"
TUBE_GOOGLE_CLIENT_ID="${TUBE_GOOGLE_CLIENT_ID:-$(keyfile_get tube.google_client_id)}"
TUBE_GOOGLE_CLIENT_ID="${TUBE_GOOGLE_CLIENT_ID:-REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID}"
TUBE_GOOGLE_CLIENT_SECRET="${TUBE_GOOGLE_CLIENT_SECRET:-$(keyfile_get tube.google_client_secret)}"
TUBE_GOOGLE_CLIENT_SECRET="${TUBE_GOOGLE_CLIENT_SECRET:-REPLACE_WITH_GOOGLE_OAUTH_CLIENT_SECRET}"
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

# ── MANAGED BACKING SERVICES creds (OPTIONAL, OPERATOR-SUPPLIED) ─────
# When a mesh points a backing service at a HOSTED cloud equivalent
# (--managed-service / MANAGED_SERVICES at build time), the hosted service's
# credentials are OPERATOR-SUPPLIED — NEVER generator-minted. This block resolves
# them env -> keys-file -> blank, exactly like mail: a Vault path is written ONLY
# when real creds resolve, and the offline bundle mirrors the MATERIALIZED Secret.
#
# velero / object-store S3 IAM creds -> secret/<brand>/velero (ESO
# velero-cloud-credentials, INI key `cloud`). This fills the gap the recon flagged:
# the mesh never had a keys-file/env hook for this path (it was a fully-MANUAL
# `vault kv put` per docs/CLOUD-BACKUPS.md). blank/absent = DISABLED (velero already
# ships dark; provisioning then materializes NOTHING — no empty Secret). Managed DB
# passwords stay on their existing per-DB paths (secret/<brand>/<x>-db) — the
# operator seeds the RDS/Azure-PG password there via the SAME env/keys-file the
# minted value used; documented in docs/MANAGED-SERVICES.md.
MANAGED_VELERO_ACCESS_KEY_ID="${MANAGED_VELERO_ACCESS_KEY_ID:-$(keyfile_get managed.velero.access_key_id)}"
MANAGED_VELERO_SECRET_ACCESS_KEY="${MANAGED_VELERO_SECRET_ACCESS_KEY:-$(keyfile_get managed.velero.secret_access_key)}"
# Kopia repository ENCRYPTION password (Velero: Secret velero-repo-credentials,
# key repository-password — ESO velero-externalsecrets.yaml, property
# repo_password on the SAME Vault path). Unlike the object-store IAM pair this
# is OUR secret, so when the operator supplies none it is MINTED — otherwise
# every kopia repo is keyed by upstream's well-known static default. Env/keys-
# file override exists to PIN it across re-provisions: a re-run that mints a
# fresh password is a rotation, and rotating does NOT re-encrypt existing repos
# (Velero can no longer connect to them — docs/CLOUD-BACKUPS.md).
MANAGED_VELERO_REPO_PASSWORD="${MANAGED_VELERO_REPO_PASSWORD:-$(keyfile_get managed.velero.repo_password)}"
if [ -n "${MANAGED_VELERO_ACCESS_KEY_ID}" ] && [ -n "${MANAGED_VELERO_SECRET_ACCESS_KEY}" ]; then
    MANAGED_VELERO_ENABLED=1
    if [ -z "${MANAGED_VELERO_REPO_PASSWORD}" ]; then
        MANAGED_VELERO_REPO_PASSWORD="$(openssl rand -base64 24)"
        echo "==> Managed velero object-store creds: ENABLED (secret/${BASE}/velero); repo password MINTED"
    else
        echo "==> Managed velero object-store creds: ENABLED (secret/${BASE}/velero); repo password PINNED (env/keys-file)"
    fi
else
    MANAGED_VELERO_ENABLED=0
    MANAGED_VELERO_ACCESS_KEY_ID=""; MANAGED_VELERO_SECRET_ACCESS_KEY=""; MANAGED_VELERO_REPO_PASSWORD=""
    echo "==> Managed velero object-store creds: disabled (no MANAGED_VELERO_ACCESS_KEY_ID/SECRET) — velero stays dark"
fi

# Registry pull/push credentials.
#
# THIS SCRIPT DOES NOT OWN secret/<brand>/harbor-robots. The in-cluster
# harbor-provision PostSync Job does (specs/cluster/manifests/harbor/
# harbor-provision-job.yaml): it creates the Harbor project and the two scoped
# robot accounts (pull-only, push-only) through Harbor's own REST API and
# read-merge-writes their secrets to that path (project + pull_name/pull_secret
# + push_name/push_secret). It has to: Harbor reveals a robot's secret EXACTLY
# ONCE, at creation, and can never re-reveal it (that Job's header, "UNLIKE every
# other secret in this platform"), so the only process that can ever hold the
# real value is the one standing there when Harbor mints it. This generator
# cannot mint that value and must therefore never destroy it.
#
# THE BUG THAT MADE THIS RULE EXPLICIT. Until 2026-08-06 this script did an
# UNCONDITIONAL `vault kv put .../harbor-robots` of the two placeholder defaults
# below. KV v2 `put` REPLACES the whole document, and the Job's idempotency is
# keyed on HARBOR ("if a robot with the expected name already exists, SKIP
# creating it" — harbor-provision-job.yaml's ensure_robot()), NOT on what is in
# Vault. So the second and every later run of this seeder overwrote four real
# robot credentials with literal placeholder strings, deleted the `project` key
# it does not even know about, and the Job could never repair any of it: the
# robots still existed in Harbor, so it skipped. Every imagePullSecret in all
# five namespaces then rendered a dockerconfigjson holding
# `REPLACE_WITH_GITLAB_DEPLOY_TOKEN` — ESO reports SYNCED, the Secret exists, and
# every pull 401s with no error anywhere upstream of the kubelet.
#
# THE RULE, and it is the same one the velero block below already follows
# ("WRITTEN ONLY when enabled so a blank never CLOBBERS a manually-seeded
# secret/<brand>/velero"): a path this generator does not own is either left
# alone or MERGED into — never replaced.
#
# THE ESCAPE HATCH SURVIVES, DECLAWED. GITLAB_REGISTRY_TOKEN /
# IMAGE_BUILDER_REGISTRY_TOKEN still exist for local/offline testing without a
# live Harbor to call. They now default to EMPTY — empty means "write nothing",
# so the placeholder literal can no longer reach Vault by construction — and when
# an operator does set one, the write below is a `vault kv patch` (merge) carrying
# ONLY the half that was supplied, so overriding the pull credential cannot
# destroy the push robot, or `project`, or vice versa.
GITLAB_REGISTRY_USER="${GITLAB_REGISTRY_USER:-hugmesh-deploy}"
GITLAB_REGISTRY_TOKEN="${GITLAB_REGISTRY_TOKEN:-}"

IMAGE_BUILDER_REGISTRY_USER="${IMAGE_BUILDER_REGISTRY_USER:-hugmesh-image-builder}"
IMAGE_BUILDER_REGISTRY_TOKEN="${IMAGE_BUILDER_REGISTRY_TOKEN:-}"

# Harbor's own built-in superuser ("admin") password. Consumed by BOTH the
# Harbor Helm chart itself (existingSecretAdminPassword, so the chart never
# falls back to its insecure default) and the harbor-provision Job (to call
# Harbor's REST API for project/robot-account provisioning) — see
# manifests/external-secrets/secretstore.yaml's harbor-admin block.
HARBOR_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# Casdoor's own OIDC application client_id / client_secret (used by the BFF).
CASDOOR_CLIENT_ID="$(openssl rand -hex 16)"
CASDOOR_CLIENT_SECRET="$(openssl rand -hex 32)"

# ── GAMES-realm Casdoor (casdoor-games, org "threewizards") ─────────
# A SEPARATE, INDEPENDENT Casdoor from the systems one above, mirroring the
# canonical hugmesh.games realm. Its secrets live under a distinct Vault path
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
CASDOOR_APPS="pki-gateway be-gateway fe-gateway api admin-bff user-bff matrix mastodon fragment-sync signup-gate harbor headscale"
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
# Must go into CASDOOR_APP_JSON_ENV under the SAME APPSEC_<APP> naming the loop
# above uses: the offline-bundle builder derives the JSON property name with
# `${_var#APPSEC_} | tr 'A-Z_' 'a-z-'`. A bare SIGNUP_GATE_WEBHOOK_SECRET has no
# APPSEC_ prefix to strip, so it used to land in the bundle as the property
# `signup-gate-webhook-secret` while Vault got `signup-gate-webhook` — the
# signup-gate-webhook ExternalSecret's property then resolved online and NOT
# offline.
printf -v APPSEC_SIGNUP_GATE_WEBHOOK '%s' "${SIGNUP_GATE_WEBHOOK_SECRET}"
CASDOOR_APP_JSON_ENV+=("APPSEC_SIGNUP_GATE_WEBHOOK")

CLICKHOUSE_PASSWORD="$(rand_urlsafe 24)"    # embedded in uptrace.yml's clickhouse:// DSN

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
WIKI_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
# mesh-bff-db / character-forge-bff-db — same owner+app shape as the six above
# (mesh-bff-db-auth / mesh-bff-db-app-auth / character-forge-bff-db-auth /
# character-forge-bff-db-app-auth ExternalSecrets). Their slugs ship dark, but the
# ExternalSecrets are UNCONDITIONALLY rendered by the external-secrets
# kustomization, so an unseeded path leaves those Secrets permanently unresolved.
MESH_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
CHARACTER_FORGE_BFF_DB_PASSWORD="$(openssl rand -base64 24)"
# Non-owner least-privilege RUNTIME role passwords (one per single-consumer DB).
FEDERATION_DB_APP_PASSWORD="$(openssl rand -base64 24)"
ADMIN_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
MOD_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
USER_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
FORUM_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
WIKI_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
MESH_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"
CHARACTER_FORGE_BFF_DB_APP_PASSWORD="$(openssl rand -base64 24)"

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
# ...and the homeserver SERVICE-ACCOUNT password the ServiceTokenBroker mints
# with (APP_HS_TOKEN_SVC_PASSWORD). SAME Vault doc, property `svc-password` —
# the user-bff-hs-token ExternalSecret lists BOTH properties, and ESO fails an
# ExternalSecret ALL-OR-NOTHING, so leaving this one unseeded also cost the
# `key` above (the whole Secret never materialized).
USER_BFF_HS_TOKEN_SVC_PASSWORD="$(openssl rand -base64 24)"

# Shared back-channel token between user-bff and the fe-gateway / admin-bff
# (INTERNAL_TOKEN / X-Internal-Token header). Authenticates the gateway→admin-bff
# BffSessionAuthFilter introspection call and the user-bff→admin-bff call.
# Blank = no-op in dev; set = fail-closed 401 on mismatch (both sides match).
BFF_INTERNAL_TOKEN="$(openssl rand -hex 32)"

# phpBB forum (backend-only). phpbb-db OWNER (install/migrate) + phpbb_app runtime
# role + the phpBB first-install admin. Kept on their OWN Vault paths (forum,
# forum-db) so the isolated hugmesh-forum namespace's phpbb-secrets /
# phpbb-db-app-auth ExternalSecrets resolve them.
PHPBB_DB_PASSWORD="$(openssl rand -base64 24)"
PHPBB_DB_APP_PASSWORD="$(openssl rand -base64 24)"
PHPBB_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# Headwind MDM (self-hosted Android device-management server, DEFAULT-OFF
# optional-service, ns hugmesh-pki). headwind-db OWNER role `headwind` —
# used for BOTH install/Liquibase-migrate AND runtime (VERIFIED not
# separable: hmdm-server shares one datasource across migrate+runtime, so
# there is no non-owner runtime role) — + the Headwind local first-install
# admin (LocalAuth.java — CE has no OIDC/SAML). Kept on ONE Vault path
# (headwind) so the two ExternalSecrets (headwind-db-auth / headwind-admin)
# resolve it.
HEADWIND_DB_PASSWORD="$(openssl rand -base64 24)"
HEADWIND_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# Akkoma/Pleroma RUNTIME app secrets (was a raw kind:Secret with REPLACE_*
# placeholders in manifests/akkoma/akkoma.yaml — now ESO-sourced from Vault).
# SECRET_KEY_BASE + SIGNING_SALT = Phoenix endpoint signing; AKKOMA_DB_PASSWORD =
# the akkoma-db Postgres owner. Materialized by the akkoma-secrets ExternalSecret
# (manifests/external-secrets/akkoma-externalsecrets.yaml) at secret/<brand>/akkoma.
# SECRET_KEY_BASE is a long Phoenix key (64 random bytes); the salt + DB pw shorter.
AKKOMA_SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
AKKOMA_SIGNING_SALT="$(openssl rand -base64 24)"
AKKOMA_DB_PASSWORD="$(openssl rand -base64 24)"

# route-access-db per-machine-user least-privilege passwords. The owner (DDL) plus
# one password per consuming machine-user: admin-bff (the ONLY writer) and the
# FOUR gateways (read-only) — pki / be / fe plus the TAILNET superadmin gateway
# (specs/cluster/apps/22-gateway-superadmin.yaml, role superadmin_gateway). Each
# gateway/admin-bff Deployment mounts ONLY its own password; the route-access-db pod
# seeds all five roles from route-access-db-roles, and its initdb/10-roles.sh
# `require`s every one of them.
ROUTE_ACCESS_OWNER_PASSWORD="$(rand_urlsafe 24)"
ROUTE_ACCESS_ADMIN_BFF_PASSWORD="$(rand_urlsafe 24)"
ROUTE_ACCESS_PKI_GATEWAY_PASSWORD="$(rand_urlsafe 24)"
ROUTE_ACCESS_BE_GATEWAY_PASSWORD="$(rand_urlsafe 24)"
ROUTE_ACCESS_FE_GATEWAY_PASSWORD="$(rand_urlsafe 24)"
ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD="$(rand_urlsafe 24)"

# Cassandra auth. These were seeded believing they fed a DARK, operator-staged
# flip; they do not. The bitnami image runs PasswordAuthenticator by DEFAULT, so
# the cluster has always demanded credentials and no gateway could start without
# them (docs/KIND-SSO-E2E-FINDINGS.md #5). Both documents are now consumed by the
# LIVE payload: cassandra-admin by apps/00-cassandra.yaml (dbUser.existingSecret)
# and the cassandra-init bootstrap Job, cassandra-app-creds by every gateway and
# BFF. Leaving either unseeded is not a stalled flip — it is a cluster whose
# front doors cannot boot.
# The superuser NAME stays the chart default `cassandra` (dbUser.user); only its
# password is rotated off cassandra/cassandra, and NO application uses it.
CASSANDRA_ADMIN_USER="cassandra"
CASSANDRA_ADMIN_PASSWORD="$(openssl rand -base64 24)"
# One password per least-privilege app role created by bootstrap-roles-configmap.yaml.
# Property names are the k8s keys the bootstrap Job + consumers read verbatim.
CASSANDRA_APP_ADMIN_BFF_PASSWORD="$(openssl rand -base64 24)"
CASSANDRA_APP_PKI_GATEWAY_PASSWORD="$(openssl rand -base64 24)"
CASSANDRA_APP_BE_GATEWAY_PASSWORD="$(openssl rand -base64 24)"
CASSANDRA_APP_FE_GATEWAY_PASSWORD="$(openssl rand -base64 24)"
CASSANDRA_APP_SUPERADMIN_GATEWAY_PASSWORD="$(openssl rand -base64 24)"
CASSANDRA_APP_FEDERATION_PASSWORD="$(openssl rand -base64 24)"

UPTRACE_PG_PASSWORD="$(rand_urlsafe 24)"
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
            key="${USER_BFF_HS_TOKEN_KEY}" \
            svc-password="${USER_BFF_HS_TOKEN_SVC_PASSWORD}"
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
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/wiki-bff-db" \
            password="${WIKI_BFF_DB_PASSWORD}" \
            app_password="${WIKI_BFF_DB_APP_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/mesh-bff-db" \
            password="${MESH_BFF_DB_PASSWORD}" \
            app_password="${MESH_BFF_DB_APP_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/character-forge-bff-db" \
            password="${CHARACTER_FORGE_BFF_DB_PASSWORD}" \
            app_password="${CHARACTER_FORGE_BFF_DB_APP_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/tube" \
            media_key="${TUBE_MEDIA_KEY}" \
            token_dek="${TUBE_TOKEN_DEK}" \
            google_client_id="${TUBE_GOOGLE_CLIENT_ID}" \
            google_client_secret="${TUBE_GOOGLE_CLIENT_SECRET}"
        # phpBB forum (backend-only, isolated hugmesh-forum ns). phpbb-secrets
        # multi-key (DB_PASSWORD owner + ADMIN_PASSWORD first-install admin) at
        # /forum; the phpbb_app runtime role password at /forum-db (app_password).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/forum" \
            DB_PASSWORD="${PHPBB_DB_PASSWORD}" \
            ADMIN_PASSWORD="${PHPBB_ADMIN_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/forum-db" \
            app_password="${PHPBB_DB_APP_PASSWORD}"
        # Headwind MDM (backend-only, ns hugmesh-pki, DEFAULT-OFF). ONE Vault
        # path holds both properties.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/headwind" \
            DB_PASSWORD="${HEADWIND_DB_PASSWORD}" \
            ADMIN_PASSWORD="${HEADWIND_ADMIN_PASSWORD}"
        # Akkoma/Pleroma runtime app secrets (akkoma-secrets ESO <- secret/<brand>/
        # akkoma). Replaces the former plaintext REPLACE_* kind:Secret. SECRET_KEY_BASE
        # + SIGNING_SALT = Phoenix signing; DB_PASSWORD = akkoma-db owner pw.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/akkoma" \
            SECRET_KEY_BASE="${AKKOMA_SECRET_KEY_BASE}" \
            SIGNING_SALT="${AKKOMA_SIGNING_SALT}" \
            DB_PASSWORD="${AKKOMA_DB_PASSWORD}"
        # route-access-db per-machine-user least-privilege passwords (owner + the
        # five consumers). admin-bff = writer; pki/be/fe/superadmin-gateway = read-only.
        # EVERY property here is listed by the route-access-db-roles ExternalSecret,
        # and ESO fails an ExternalSecret ALL-OR-NOTHING — one missing property means
        # the Secret is never created and route-access-db never boots.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/route-access-db" \
            owner_password="${ROUTE_ACCESS_OWNER_PASSWORD}" \
            admin_bff_password="${ROUTE_ACCESS_ADMIN_BFF_PASSWORD}" \
            pki_gateway_password="${ROUTE_ACCESS_PKI_GATEWAY_PASSWORD}" \
            be_gateway_password="${ROUTE_ACCESS_BE_GATEWAY_PASSWORD}" \
            fe_gateway_password="${ROUTE_ACCESS_FE_GATEWAY_PASSWORD}" \
            superadmin_gateway_password="${ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD}"
        # Cassandra auth. Two docs, exactly the properties
        # manifests/external-secrets/cassandra-externalsecrets.yaml lists — `user`
        # is the chart's dbUser.user, `password` the rotated superuser password,
        # and one property per least-privilege app role.
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/cassandra-admin" \
            user="${CASSANDRA_ADMIN_USER}" \
            password="${CASSANDRA_ADMIN_PASSWORD}"
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/cassandra-app-creds" \
            admin-bff="${CASSANDRA_APP_ADMIN_BFF_PASSWORD}" \
            pki-gateway="${CASSANDRA_APP_PKI_GATEWAY_PASSWORD}" \
            be-gateway="${CASSANDRA_APP_BE_GATEWAY_PASSWORD}" \
            fe-gateway="${CASSANDRA_APP_FE_GATEWAY_PASSWORD}" \
            superadmin-gateway="${CASSANDRA_APP_SUPERADMIN_GATEWAY_PASSWORD}" \
            federation="${CASSANDRA_APP_FEDERATION_PASSWORD}"
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
        # ── secret/<brand>/harbor-robots — OWNED BY harbor-provision, NOT HERE ──
        # See the GITLAB_REGISTRY_* header above for the full argument. Short
        # form: only the in-cluster Job can ever hold a Harbor robot secret
        # (revealed once, never re-readable), and that Job skips on HARBOR state,
        # so it can never repair a Vault doc somebody else overwrote. A writer
        # that cannot repair must be the only writer; everyone else merges or
        # stays out. `vault kv put` REPLACES the whole KV-v2 document — it is the
        # wrong verb for a path this script does not own, at any time, with any
        # value.
        #
        # DEFAULT: write NOTHING. Until harbor-provision has run, the six
        # ExternalSecrets that read this path (four harbor-registry, one
        # hugmesh-registry-pull, one image-builder-registry) report
        # SecretSyncedError and no pull Secret exists — which is loud, correct
        # and self-resolving. The alternative this replaces (a placeholder that
        # renders a syntactically perfect dockerconfigjson holding a dead token)
        # is silent, and there is nothing to pull from Harbor before Harbor is up
        # anyway.
        HARBOR_ROBOT_OVERRIDE=()
        if [ -n "${GITLAB_REGISTRY_TOKEN}" ]; then
            HARBOR_ROBOT_OVERRIDE+=(pull_name="${GITLAB_REGISTRY_USER}"
                                    pull_secret="${GITLAB_REGISTRY_TOKEN}")
        fi
        if [ -n "${IMAGE_BUILDER_REGISTRY_TOKEN}" ]; then
            HARBOR_ROBOT_OVERRIDE+=(push_name="${IMAGE_BUILDER_REGISTRY_USER}"
                                    push_secret="${IMAGE_BUILDER_REGISTRY_TOKEN}")
        fi
        if [ "${#HARBOR_ROBOT_OVERRIDE[@]}" -gt 0 ]; then
            # The verb is chosen by whether a document EXISTS, never by whether a
            # write failed. `kv patch || kv put` looks equivalent and is not: a
            # patch can be refused for reasons that have nothing to do with the
            # document being absent — most obviously a token without the `patch`
            # capability on this path — and the fallback would then REPLACE the
            # very document this block exists to protect, silently, which is the
            # original bug wearing a fallback.
            #
            # And the probe itself is only allowed to authorize a `put` when it
            # positively reports ABSENCE. "The read failed" is not "there is
            # nothing there" — a token with update but no read on this path is an
            # ordinary Vault policy — so anything other than a clean read or an
            # explicit not-found ABORTS. Fail-closed: the worst case is a
            # provisioning run that stops and says why, instead of one that
            # destroys a credential nothing can re-mint.
            #
            # Only stderr is captured (`2>&1 >/dev/null` — stderr to the capture,
            # stdout to /dev/null): a successful read prints the document, and
            # the robot secrets have no business in a shell variable.
            if _hr_probe="$(vault kv get -format=json \
                    "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" 2>&1 >/dev/null)"; then
                vault kv patch "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \
                    "${HARBOR_ROBOT_OVERRIDE[@]}"
            elif printf '%s' "${_hr_probe}" | grep -i 'no value found' >/dev/null; then
                # Virgin path: `kv patch` cannot create a document, and there is
                # nothing to clobber. Only the supplied keys are written — never
                # a fabricated value for the robot we were not given.
                vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \
                    "${HARBOR_ROBOT_OVERRIDE[@]}"
            else
                echo "ERROR: could not determine whether ${VAULT_KV_MOUNT}/${BASE}/harbor-robots" >&2
                echo "       exists; the read failed for a reason other than 'no value found':" >&2
                printf '%s\n' "${_hr_probe}" | sed 's/^/         /' >&2
                echo "       REFUSING to write it. That path holds Harbor robot secrets the" >&2
                echo "       harbor-provision Job captured at mint time and can NEVER re-reveal;" >&2
                echo "       writing blind would replace them permanently. Grant this token read" >&2
                echo "       on the path, or unset GITLAB_REGISTRY_TOKEN /" >&2
                echo "       IMAGE_BUILDER_REGISTRY_TOKEN to skip the manual override entirely." >&2
                exit 1
            fi
            echo "    MERGED manual override into ${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \
                 "(keys: ${HARBOR_ROBOT_OVERRIDE[*]%%=*}) — harbor-provision still owns the rest"
        else
            echo "    skipped ${VAULT_KV_MOUNT}/${BASE}/harbor-robots — owned by the in-cluster" \
                 "harbor-provision Job (set GITLAB_REGISTRY_TOKEN / IMAGE_BUILDER_REGISTRY_TOKEN" \
                 "to merge a manual override for offline testing)"
        fi
        # Harbor admin password — consumed by the Helm chart (existingSecretAdminPassword)
        # AND the harbor-provision Job (project/robot-account REST calls).
        vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor" \
            admin_password_plain="${HARBOR_ADMIN_PASSWORD}"
        # Managed velero object-store creds (operator-supplied) + the kopia repo
        # encryption password (minted/pinned above) — WRITTEN ONLY when enabled so
        # a blank never CLOBBERS a manually-seeded secret/<brand>/velero. `kv put`
        # replaces the whole doc, so repo_password rides the SAME write: a partial
        # write here would silently drop whichever property it omitted.
        if [ "${MANAGED_VELERO_ENABLED}" = "1" ]; then
            vault kv put "${VAULT_KV_MOUNT}/${BASE}/velero" \
                access_key_id="${MANAGED_VELERO_ACCESS_KEY_ID}" \
                secret_access_key="${MANAGED_VELERO_SECRET_ACCESS_KEY}" \
                repo_password="${MANAGED_VELERO_REPO_PASSWORD}"
            echo "    wrote ${VAULT_KV_MOUNT}/${BASE}/velero (managed object-store creds + kopia repo password)"
        fi
        # NB: harbor-robots is deliberately NOT in this list — see the block
        # above; it belongs to the harbor-provision Job.
        echo "    wrote ${VAULT_KV_MOUNT}/${BASE}/{casdoor,casdoor-apps,casdoor-superadmin,casdoor-games,clickhouse,federation-db,admin-bff-db,admin-bff-mfa,user-bff-custody-key,user-bff-hs-token,bff-internal-token,mod-bff-db,user-bff-db,forum-bff-db,wiki-bff-db,mesh-bff-db,character-forge-bff-db,forum,forum-db,akkoma,tube,route-access-db,cassandra-admin,cassandra-app-creds,uptrace,mail,harbor,headwind}"
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
MANAGED_VELERO_ENABLED="${MANAGED_VELERO_ENABLED}" \
MANAGED_VELERO_ACCESS_KEY_ID="${MANAGED_VELERO_ACCESS_KEY_ID}" \
MANAGED_VELERO_SECRET_ACCESS_KEY="${MANAGED_VELERO_SECRET_ACCESS_KEY}" \
MANAGED_VELERO_REPO_PASSWORD="${MANAGED_VELERO_REPO_PASSWORD}" \
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
WIKI_BFF_DB_PASSWORD="${WIKI_BFF_DB_PASSWORD}" \
MESH_BFF_DB_PASSWORD="${MESH_BFF_DB_PASSWORD}" \
MESH_BFF_DB_APP_PASSWORD="${MESH_BFF_DB_APP_PASSWORD}" \
CHARACTER_FORGE_BFF_DB_PASSWORD="${CHARACTER_FORGE_BFF_DB_PASSWORD}" \
CHARACTER_FORGE_BFF_DB_APP_PASSWORD="${CHARACTER_FORGE_BFF_DB_APP_PASSWORD}" \
TUBE_MEDIA_KEY="${TUBE_MEDIA_KEY}" \
TUBE_TOKEN_DEK="${TUBE_TOKEN_DEK}" \
TUBE_GOOGLE_CLIENT_ID="${TUBE_GOOGLE_CLIENT_ID}" \
TUBE_GOOGLE_CLIENT_SECRET="${TUBE_GOOGLE_CLIENT_SECRET}" \
FEDERATION_DB_APP_PASSWORD="${FEDERATION_DB_APP_PASSWORD}" \
ADMIN_BFF_DB_APP_PASSWORD="${ADMIN_BFF_DB_APP_PASSWORD}" \
ADMIN_BFF_MFA_FACTOR_KEY="${ADMIN_BFF_MFA_FACTOR_KEY}" \
USER_BFF_CUSTODY_KEY="${USER_BFF_CUSTODY_KEY}" \
USER_BFF_HS_TOKEN_KEY="${USER_BFF_HS_TOKEN_KEY}" \
USER_BFF_HS_TOKEN_SVC_PASSWORD="${USER_BFF_HS_TOKEN_SVC_PASSWORD}" \
BFF_INTERNAL_TOKEN="${BFF_INTERNAL_TOKEN}" \
MOD_BFF_DB_APP_PASSWORD="${MOD_BFF_DB_APP_PASSWORD}" \
USER_BFF_DB_APP_PASSWORD="${USER_BFF_DB_APP_PASSWORD}" \
FORUM_BFF_DB_APP_PASSWORD="${FORUM_BFF_DB_APP_PASSWORD}" \
WIKI_BFF_DB_APP_PASSWORD="${WIKI_BFF_DB_APP_PASSWORD}" \
PHPBB_DB_PASSWORD="${PHPBB_DB_PASSWORD}" \
PHPBB_DB_APP_PASSWORD="${PHPBB_DB_APP_PASSWORD}" \
PHPBB_ADMIN_PASSWORD="${PHPBB_ADMIN_PASSWORD}" \
HEADWIND_DB_PASSWORD="${HEADWIND_DB_PASSWORD}" \
HEADWIND_ADMIN_PASSWORD="${HEADWIND_ADMIN_PASSWORD}" \
AKKOMA_SECRET_KEY_BASE="${AKKOMA_SECRET_KEY_BASE}" \
AKKOMA_SIGNING_SALT="${AKKOMA_SIGNING_SALT}" \
AKKOMA_DB_PASSWORD="${AKKOMA_DB_PASSWORD}" \
ROUTE_ACCESS_OWNER_PASSWORD="${ROUTE_ACCESS_OWNER_PASSWORD}" \
ROUTE_ACCESS_ADMIN_BFF_PASSWORD="${ROUTE_ACCESS_ADMIN_BFF_PASSWORD}" \
ROUTE_ACCESS_PKI_GATEWAY_PASSWORD="${ROUTE_ACCESS_PKI_GATEWAY_PASSWORD}" \
ROUTE_ACCESS_BE_GATEWAY_PASSWORD="${ROUTE_ACCESS_BE_GATEWAY_PASSWORD}" \
ROUTE_ACCESS_FE_GATEWAY_PASSWORD="${ROUTE_ACCESS_FE_GATEWAY_PASSWORD}" \
ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD="${ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD}" \
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD}" \
CLUSTER_DOMAIN="${CLUSTER_DOMAIN}" \
CASSANDRA_ADMIN_USER="${CASSANDRA_ADMIN_USER}" \
CASSANDRA_ADMIN_PASSWORD="${CASSANDRA_ADMIN_PASSWORD}" \
CASSANDRA_APP_ADMIN_BFF_PASSWORD="${CASSANDRA_APP_ADMIN_BFF_PASSWORD}" \
CASSANDRA_APP_PKI_GATEWAY_PASSWORD="${CASSANDRA_APP_PKI_GATEWAY_PASSWORD}" \
CASSANDRA_APP_BE_GATEWAY_PASSWORD="${CASSANDRA_APP_BE_GATEWAY_PASSWORD}" \
CASSANDRA_APP_FE_GATEWAY_PASSWORD="${CASSANDRA_APP_FE_GATEWAY_PASSWORD}" \
CASSANDRA_APP_SUPERADMIN_GATEWAY_PASSWORD="${CASSANDRA_APP_SUPERADMIN_GATEWAY_PASSWORD}" \
CASSANDRA_APP_FEDERATION_PASSWORD="${CASSANDRA_APP_FEDERATION_PASSWORD}" \
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
        # route-access-db pod role passwords (owner + the five machine-users). The
        # DB pod seeds every login role from this Secret; the consumers each mount
        # only their own matching per-namespace Secret with the SAME value. EVERY
        # key here is `require`d by manifests/route-access/initdb/10-roles.sh and
        # listed by the route-access-db-roles ExternalSecret.
        "route-access-db-roles": {
            "owner_password":        os.environ["ROUTE_ACCESS_OWNER_PASSWORD"],
            "admin_bff_password":    os.environ["ROUTE_ACCESS_ADMIN_BFF_PASSWORD"],
            "pki_gateway_password":  os.environ["ROUTE_ACCESS_PKI_GATEWAY_PASSWORD"],
            "be_gateway_password":   os.environ["ROUTE_ACCESS_BE_GATEWAY_PASSWORD"],
            "fe_gateway_password":   os.environ["ROUTE_ACCESS_FE_GATEWAY_PASSWORD"],
            "superadmin_gateway_password": os.environ["ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD"],
        },
        # pki-gateway's OWN read-only route-access password (user pki_gateway).
        "route-access-pki-gateway": {
            "password": os.environ["ROUTE_ACCESS_PKI_GATEWAY_PASSWORD"],
        },
        # The TAILNET superadmin-gateway's OWN read-only route-access password
        # (user superadmin_gateway). Same ns as pki-gateway's; apps/22-gateway-
        # superadmin.yaml mounts secret route-access-superadmin-gateway key
        # `password` into ROUTE_ACCESS_DB_PASSWORD.
        "route-access-superadmin-gateway": {
            "password": os.environ["ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD"],
        },
        # Harbor built-in superuser login. THREE keys, mirroring the harbor-admin
        # ExternalSecret template exactly: the Helm chart reads
        # HARBOR_ADMIN_PASSWORD (existingSecretAdminPasswordKey) and the
        # harbor-provision Job reads password; username is the fixed "admin".
        "harbor-admin": {
            "username": "admin",
            "password": os.environ["HARBOR_ADMIN_PASSWORD"],
            "HARBOR_ADMIN_PASSWORD": os.environ["HARBOR_ADMIN_PASSWORD"],
        },
        # SCOPED per-app Casdoor machine-client Secrets carved out of the
        # casdoor-apps doc (the ESO side templates a FIXED clientId + the one
        # per-app secret). Mirrors harbor-casdoor / signup-gate-casdoor in
        # secretstore.yaml; the consumers mount these, NOT the whole bag.
        "harbor-casdoor": {
            "clientId": "app-harbor",
            "clientSecret": app_secrets["harbor"],
        },
        "signup-gate-casdoor": {
            "clientId": "app-signup-gate",
            "clientSecret": app_secrets["signup-gate"],
        },
        # signup-gate POST-signup reconcile webhook shared secret (header
        # X-Signup-Gate-Secret). Same casdoor-apps property, own Secret.
        "signup-gate-webhook": {
            "secret": app_secrets["signup-gate-webhook"],
        },
        # Headwind MDM (DEFAULT-OFF optional-service). OWNER role only — VERIFIED
        # not separable from runtime (see gen-cluster-secrets.sh's HEADWIND_DB_PASSWORD
        # comment) — so this materializes only the two ExternalSecrets headwind
        # actually uses (headwind-db-auth, headwind-admin), unlike phpbb-secrets'
        # owner/app split.
        "headwind-db-auth": {
            "password": os.environ["HEADWIND_DB_PASSWORD"],
        },
        "headwind-admin": {
            "username": "admin",
            "password": os.environ["HEADWIND_ADMIN_PASSWORD"],
            # Non-secret, and DOMAIN-COUPLED — not a fixed string.
            # headwind-externalsecrets.yaml's template.data.email reads
            # "admin@hugmesh.net" IN THE REPO, and ESO writes that value
            # verbatim online — but the manifest the cluster actually runs is the
            # BAKED copy: build-*-stage4.sh does
            #   cp -r specs/cluster -> ${SYSROOT}/var/lib/hugmesh/cluster
            # and then rebrand_sysroot() seds `hugmesh.net` ->
            # `${CLUSTER_DOMAIN}` across that whole tree. So on every non-default
            # brand the ONLINE value is admin@${CLUSTER_DOMAIN}, and this offline
            # value has to track it. Hardcoding "admin@hugmesh.net" here
            # would match only the default brand and hand a rebranded cluster's
            # SAME pod two different ADMIN_EMAILs depending on which delivery
            # path provisioned it.
            # headwind.yaml mounts this as a NON-optional secretKeyRef
            # (ADMIN_EMAIL), so an offline bundle without it leaves the pod in
            # CreateContainerConfigError. Both directions are gated:
            # [literal-value] in tests/scripts/eso_seed_contract.py pins the
            # default-brand string byte-for-byte, and [domain-coupled] re-runs
            # this script under a NON-default CLUSTER_DOMAIN and fails if the
            # value stops tracking it.
            "email": "admin@" + os.environ["CLUSTER_DOMAIN"],
        },
        # Cassandra auth. cassandra-admin's third key `cassandra-password` is the
        # bitnami chart's dbUser.existingSecret alias for the SAME superuser
        # password the bootstrap Job reads as `password` (the ExternalSecret
        # aliases both to the one Vault property). THIS pki copy carries all six
        # role passwords because the bootstrap Job here creates all six roles; the
        # backend/frontend copies below carry only their own namespace's keys,
        # which is the least-privilege boundary the per-role GRANTs exist to draw.
        "cassandra-admin": {
            "user": os.environ["CASSANDRA_ADMIN_USER"],
            "password": os.environ["CASSANDRA_ADMIN_PASSWORD"],
            "cassandra-password": os.environ["CASSANDRA_ADMIN_PASSWORD"],
        },
        "cassandra-app-creds": {
            "admin-bff": os.environ["CASSANDRA_APP_ADMIN_BFF_PASSWORD"],
            "pki-gateway": os.environ["CASSANDRA_APP_PKI_GATEWAY_PASSWORD"],
            "be-gateway": os.environ["CASSANDRA_APP_BE_GATEWAY_PASSWORD"],
            "fe-gateway": os.environ["CASSANDRA_APP_FE_GATEWAY_PASSWORD"],
            "superadmin-gateway": os.environ["CASSANDRA_APP_SUPERADMIN_GATEWAY_PASSWORD"],
            "federation": os.environ["CASSANDRA_APP_FEDERATION_PASSWORD"],
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
        "wiki-bff-db-auth": {
            "password": os.environ["WIKI_BFF_DB_PASSWORD"],
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
        # user-bff-hs-token: homeserver-native token custody key (APP_HS_TOKEN_KEY)
        # + the ServiceTokenBroker's homeserver service-account password
        # (APP_HS_TOKEN_SVC_PASSWORD). BOTH keys are listed by the ExternalSecret.
        "user-bff-hs-token": {
            "key": os.environ["USER_BFF_HS_TOKEN_KEY"],
            "svc-password": os.environ["USER_BFF_HS_TOKEN_SVC_PASSWORD"],
        },
        # user-bff's OWN Casdoor OIDC client secret, carved out of the casdoor-apps
        # doc (APP_BFF_OIDC_CLIENT_SECRET). Mirrors the user-bff-oidc ExternalSecret
        # in sso-externalsecrets.yaml — k8s key `client-secret`.
        "user-bff-oidc": {
            "client-secret": app_secrets["user-bff"],
        },
        # admin-bff's OWN Casdoor client-credentials pair (app-admin-bff), carved out
        # of the casdoor-apps doc exactly like harbor-casdoor above. Mirrors the
        # admin-bff-casdoor-client ExternalSecret in secretstore.yaml (APP_CASDOOR_
        # PLATFORM_CLIENT_ID / _CLIENT_SECRET on the admin-bff Deployment).
        "admin-bff-casdoor-client": {
            "clientId": "app-admin-bff",
            "clientSecret": app_secrets["admin-bff"],
        },
        # bff-internal-token: shared back-channel auth token (INTERNAL_TOKEN).
        # Mounted in BOTH hugmesh-backend (user-bff) and hugmesh-frontend
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
        "wiki-bff-db-app-auth": {
            "password": os.environ["WIKI_BFF_DB_APP_PASSWORD"],
        },
        # mesh-bff / character-forge-bff owner + runtime DB roles. Same owner/app
        # split as the six above; their ExternalSecrets are rendered
        # unconditionally by the external-secrets kustomization.
        "mesh-bff-db-auth": {
            "password": os.environ["MESH_BFF_DB_PASSWORD"],
        },
        "mesh-bff-db-app-auth": {
            "password": os.environ["MESH_BFF_DB_APP_PASSWORD"],
        },
        "character-forge-bff-db-auth": {
            "password": os.environ["CHARACTER_FORGE_BFF_DB_PASSWORD"],
        },
        "character-forge-bff-db-app-auth": {
            "password": os.environ["CHARACTER_FORGE_BFF_DB_APP_PASSWORD"],
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
        # Cassandra roles reachable from the backend ns: be-gateway (schema owner
        # for hugmesh_gateway), admin-bff (DML writer) and federation (its own
        # keyspace). No other key is delivered here.
        "cassandra-app-creds": {
            "be-gateway": os.environ["CASSANDRA_APP_BE_GATEWAY_PASSWORD"],
            "admin-bff":  os.environ["CASSANDRA_APP_ADMIN_BFF_PASSWORD"],
            "federation": os.environ["CASSANDRA_APP_FEDERATION_PASSWORD"],
        },
        # hugmesh-actions two-Casdoor sync: admin client per side. SYSTEMS side
        # reuses the systems Casdoor OIDC client; GAMES side reuses threewizards-app.
        "casdoor-sync-systems": {
            "clientId": os.environ["CASDOOR_CLIENT_ID"],
            "clientSecret": os.environ["CASDOOR_CLIENT_SECRET"],
        },
        "casdoor-sync-games": {
            "clientId": "twclient001",
            "clientSecret": os.environ["CASDOOR_GAMES_CLIENT_SECRET"],
        },
        # Akkoma/Pleroma runtime app secrets (was a raw REPLACE_* kind:Secret in
        # manifests/akkoma/akkoma.yaml; now ESO-sourced). akkoma envFrom secretRef +
        # akkoma-db secretKeyRef DB_PASSWORD. Matches the akkoma-secrets ExternalSecret.
        "akkoma-secrets": {
            "SECRET_KEY_BASE": os.environ["AKKOMA_SECRET_KEY_BASE"],
            "SIGNING_SALT": os.environ["AKKOMA_SIGNING_SALT"],
            "DB_PASSWORD": os.environ["AKKOMA_DB_PASSWORD"],
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
        # fe-gateway's OWN Cassandra role password — and ONLY that one.
        "cassandra-app-creds": {
            "fe-gateway": os.environ["CASSANDRA_APP_FE_GATEWAY_PASSWORD"],
        },
        "bff-internal-token": {
            "token": os.environ["BFF_INTERNAL_TOKEN"],
        },
        # remote-fragment sync sidecar's Casdoor client-credentials machine account.
        # Carved out of casdoor-apps exactly like harbor-casdoor above.
        "fragment-sync-casdoor": {
            "clientId": "app-fragment-sync",
            "clientSecret": app_secrets["fragment-sync"],
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
    # LocalTube (DEFAULT-OFF optional slug, ns <brand>-tube). Mirrors the three
    # tube ExternalSecret shapes (tube-externalsecrets.yaml): mediaKey / dek /
    # clientId+clientSecret. Emitted unconditionally like every other secret —
    # the bundle sources values, slug enablement is a separate operator act.
    f"{brand}-tube": {
        "tube-media-key": {
            "mediaKey": os.environ["TUBE_MEDIA_KEY"],
        },
        "tube-token-dek": {
            "dek": os.environ["TUBE_TOKEN_DEK"],
        },
        "google-oauth": {
            "clientId": os.environ["TUBE_GOOGLE_CLIENT_ID"],
            "clientSecret": os.environ["TUBE_GOOGLE_CLIENT_SECRET"],
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
    # AttestationServer (DEFAULT-OFF optional-service) reuses this SAME shared
    # mail doc — no new Vault path. Consumed by the smtp-config-seeder sidecar
    # (NOT read as process env vars by the app itself; it only reads SMTP
    # settings from its own SQLite Configuration table — see
    # attestation-server-externalsecrets.yaml). k8s keys mirror the
    # attestation-server-smtp ExternalSecret template.data shape.
    data[f"{brand}-pki"]["attestation-server-smtp"] = {
        "ATTESTATION_SMTP_HOST": os.environ["MAIL_HOST"],
        "ATTESTATION_SMTP_PORT": os.environ["MAIL_PORT"],
        "ATTESTATION_SMTP_USER": os.environ["MAIL_USER"],
        "ATTESTATION_SMTP_PASSWORD": os.environ["MAIL_PASSWORD"],
        "ATTESTATION_SMTP_FROM": os.environ["MAIL_FROM"],
    }

# ── MANAGED backing services (OPTIONAL) — velero object-store creds ──
# Mirror secret/<brand>/velero as the MATERIALIZED velero-cloud-credentials Secret
# (ns `velero` — the Helm chart namespace, NOT brand-prefixed; key `cloud` = the AWS
# INI the ESO template renders) so an offline/USB provision seeds it too. Only when
# ENABLED (real operator creds); disabled => omit ENTIRELY so velero stays dark and
# no empty Secret is materialized. This fills the gap the recon flagged (the mesh
# only ever wrote this path by hand).
if os.environ.get("MANAGED_VELERO_ENABLED") == "1":
    data["velero"] = {
        "velero-cloud-credentials": {
            "cloud": "[default]\naws_access_key_id={}\naws_secret_access_key={}\n".format(
                os.environ["MANAGED_VELERO_ACCESS_KEY_ID"],
                os.environ["MANAGED_VELERO_SECRET_ACCESS_KEY"],
            ),
        },
        # Kopia repo encryption password — mirrors the velero-repo-credentials
        # ExternalSecret shape (key name is Velero's fixed contract). Must exist
        # BEFORE the first backup or the repo is keyed by upstream's well-known
        # static default; rotating later does NOT re-encrypt existing repos.
        "velero-repo-credentials": {
            "repository-password": os.environ["MANAGED_VELERO_REPO_PASSWORD"],
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
echo "Note: casdoor google/github/discord AND tube google client_id/secret are placeholders unless"
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
