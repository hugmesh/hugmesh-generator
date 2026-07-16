#!/usr/bin/env bash
# gen-mastodon-env.sh — create AND self-heal tests/stack/.mastodon.env with
# EVERY key the compose.real.yaml mastodon services need to boot on a FRESH
# checkout. The file is GITIGNORED (dev secrets live only on the operator's
# disk), so both `make stack-up SOCIAL=1` (via the stack-mastodon-env target)
# and tests/stack/up-real.sh call this instead of assuming a committed file.
#
# Idempotent + self-healing: an existing file is never clobbered — only keys
# that are MISSING or EMPTY are (re)generated, so a partial/hand-edited file
# heals instead of failing at container boot.
#
# Why each non-obvious key:
#   ALTERNATE_DOMAINS=mastodon-web:3000 — Rails HostAuthorization builds
#     config.hosts from LOCAL_DOMAIN+WEB_DOMAIN+ALTERNATE_DOMAINS; Spring Cloud
#     Gateway rewrites the Host header to the proxied authority, so without
#     this every be-gateway-proxied request 403s (see the Makefile's
#     stack-mastodon-env comment for the full live-debugged story).
#   ACTIVE_RECORD_ENCRYPTION_* — Mastodon v4.3 (Rails 7.1) REFUSES to boot
#     without the three ActiveRecord encryption keys; a fresh env without them
#     crash-loops mastodon-web/sidekiq before the first request.
#   EMAIL_DOMAIN_ALLOWLIST=e2e.local — tests/stack/seed-e2e.sh provisions its
#     personas with @e2e.local emails, and the user-bff provisioning contract
#     (APP_HS_TOKEN_MASTODON_EMAIL_DOMAIN in compose.local.yaml) mints the
#     same domain; without the allowlist Mastodon rejects those signups.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${MASTODON_ENV:-${HERE}/.mastodon.env}"

created=""
if [ ! -f "${ENV_FILE}" ]; then
  echo "==> Generating dev ${ENV_FILE} (SOCIAL tier)"
  created=1
fi
touch "${ENV_FILE}"

ensure() { # KEY generator-cmd... : append/replace only when missing or empty
  local key="$1"; shift
  local cur
  cur="$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
  [ -n "${cur}" ] && return 0
  local val; val="$("$@")"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
  fi
  echo "  + ${key}"
}
lit() { printf '%s' "$1"; }

ensure LOCAL_DOMAIN      lit localhost
ensure SECRET_KEY_BASE   openssl rand -hex 64
ensure OTP_SECRET        openssl rand -hex 64
ensure DB_HOST           lit mastodon-db
ensure DB_USER           lit mastodon
ensure DB_NAME           lit mastodon
ensure DB_PASS           lit mastodon
ensure REDIS_HOST        lit mastodon-redis
ensure ALTERNATE_DOMAINS lit mastodon-web:3000
ensure ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY        openssl rand -hex 32
ensure ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY  openssl rand -hex 32
ensure ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT openssl rand -hex 32
ensure EMAIL_DOMAIN_ALLOWLIST lit e2e.local

[ -n "${created}" ] || echo "==> ${ENV_FILE} present — healed any missing/empty keys"
