#!/usr/bin/env bash
# up-real.sh — bring up the REAL integration stack (compose.real.yaml): actual
# Synapse, Casdoor, Mastodon + their Postgres/Redis, plus the platform Cassandra.
# This is the heavyweight counterpart to up.sh (which runs the in-memory mocks).
#
# SCOPE: this swaps in real THIRD-PARTY backends only. It brings up no
# first-party Spring service (no gateway, no BFF). Pairing it with
# `tests/stack/up.sh` (this script's own closing message suggests
# REAL_MATRIX=1 for the Playwright harness) still serves the UI through
# mock-bff.mjs — a hand-written Node stand-in for the BFF that never calls
# Casdoor and has no "real Mastodon" mode; only the Synapse leg becomes real
# in that pairing. For the UI to talk to the REAL gateway + Spring BFFs +
# Casdoor OAuth login, use `make stack-up` instead (see docs/LOCAL-STACK.md) —
# it reuses this script's Synapse-config/Mastodon-db:prepare setup.
#
# It does the two pieces of first-run setup compose can't express, then ups:
#   1. generates the Synapse homeserver config into the `synapse` volume
#      (idempotent — synapse `generate` won't clobber an existing config), and
#      ensures a known registration_shared_secret is present so the BFF can
#      broker real Synapse tokens;
#   2. ensures tests/stack/.mastodon.env exists (generates any missing secrets),
#      then runs Mastodon's DB prepare before the web/sidekiq/streaming services.
#
# Tear down (and drop volumes) with: tests/stack/down-real.sh
#
# Env knobs:
#   SYNAPSE_SERVER_NAME   (default localhost)  Matrix server_name baked into config
#   SYNAPSE_REG_SECRET    (default snapdragon-reg-secret) registration_shared_secret
#   COMPOSE                (default "docker compose")  e.g. "podman compose"
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${HERE}/compose.real.yaml"
COMPOSE="${COMPOSE:-docker compose} -f ${COMPOSE_FILE}"
SYNAPSE_SERVER_NAME="${SYNAPSE_SERVER_NAME:-localhost}"
SYNAPSE_REG_SECRET="${SYNAPSE_REG_SECRET:-snapdragon-reg-secret}"
MASTODON_ENV="${HERE}/.mastodon.env"

echo "==> Real integration stack (compose.real.yaml)"

# ── 1. Mastodon secrets: guarantee .mastodon.env has non-empty secrets ──
# The file is committed with working dev secrets; this regenerates only the
# ones a fresh/edited checkout may have blanked, so the file is never partial.
ensure_secret() { # KEY generator-cmd...
  local key="$1"; shift
  local cur; cur="$(grep -E "^${key}=" "${MASTODON_ENV}" 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "${cur}" ]; then
    local val; val="$("$@")"
    if grep -qE "^${key}=" "${MASTODON_ENV}" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${MASTODON_ENV}"
    else
      printf '%s=%s\n' "${key}" "${val}" >> "${MASTODON_ENV}"
    fi
    echo "  generated ${key}"
  fi
}
if [ ! -f "${MASTODON_ENV}" ]; then
  echo "ERROR: ${MASTODON_ENV} missing (expected committed Mastodon env). Aborting." >&2
  exit 1
fi
ensure_secret SECRET_KEY_BASE openssl rand -hex 64
ensure_secret OTP_SECRET      openssl rand -hex 64

# ── 2. Synapse config: generate into the volume, ensure reg shared secret ──
echo "==> Generating Synapse config (server_name=${SYNAPSE_SERVER_NAME})"
${COMPOSE} run --rm --no-deps \
  -e SYNAPSE_SERVER_NAME="${SYNAPSE_SERVER_NAME}" \
  -e SYNAPSE_REPORT_STATS=no \
  synapse generate

echo "==> Ensuring Synapse registration_shared_secret + open registration"
${COMPOSE} run --rm --no-deps --entrypoint sh synapse -c '
  set -e
  cfg=/data/homeserver.yaml
  grep -q "^registration_shared_secret:" "$cfg" || \
    printf "\nregistration_shared_secret: \"%s\"\n" "'"${SYNAPSE_REG_SECRET}"'" >> "$cfg"
  grep -q "^enable_registration:" "$cfg" || \
    printf "enable_registration: true\nenable_registration_without_verification: true\n" >> "$cfg"
'

# ── 3. Datastores + identity + matrix first, wait until healthy ──
echo "==> Starting datastores + Casdoor + Synapse"
${COMPOSE} up -d casdoor-db mastodon-db mastodon-redis cassandra synapse casdoor

wait_healthy() { # service deadline-seconds
  local svc="$1" deadline="${2:-180}" cid status
  cid="$(${COMPOSE} ps -q "${svc}")"
  [ -n "${cid}" ] || { echo "  ERROR: no container for ${svc}" >&2; return 1; }
  echo "  waiting for ${svc} to be healthy (<=${deadline}s)"
  for _ in $(seq 1 "${deadline}"); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${cid}" 2>/dev/null || true)"
    case "${status}" in
      healthy|running) [ "${status}" = healthy ] && { echo "  ${svc}: healthy"; return 0; } ;;
      exited|dead) echo "  ERROR: ${svc} ${status}" >&2; return 1 ;;
    esac
    sleep 1
  done
  echo "  WARN: ${svc} not healthy after ${deadline}s (status=${status:-unknown})" >&2
  return 1
}
wait_healthy mastodon-db 120
wait_healthy synapse 180 || true   # synapse health can lag first start; not fatal

# ── 4. Mastodon DB prepare (create + migrate, idempotent), then app tier ──
echo "==> Preparing Mastodon database (rails db:prepare)"
${COMPOSE} run --rm mastodon-web bundle exec rails db:prepare

echo "==> Starting Mastodon web + sidekiq + streaming"
${COMPOSE} up -d mastodon-web mastodon-sidekiq mastodon-streaming

# ── 5. Readiness summary ──
echo "==> Waiting on HTTP endpoints"
probe() { # name url
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "$2" && { echo "  $1: up ($2)"; return 0; }
    sleep 2
  done
  echo "  WARN: $1 did not answer at $2" >&2; return 1
}
probe synapse  "http://127.0.0.1:8008/health"               || true
probe casdoor  "http://127.0.0.1:8000/"                     || true
probe mastodon "http://127.0.0.1:3000/health"               || true

cat <<EOF

Real stack up. Endpoints:
  Synapse (Matrix):  http://127.0.0.1:8008    (server_name=${SYNAPSE_SERVER_NAME}, reg secret=${SYNAPSE_REG_SECRET})
  Casdoor (OIDC):    http://127.0.0.1:8000
  Mastodon web:      http://127.0.0.1:3000
  Mastodon stream:   http://127.0.0.1:4000
  Cassandra:         127.0.0.1:9042 (gateway revocation list + URL registry)

Point the Playwright UI harness at real Synapse with:
  REAL_MATRIX=1 SYNAPSE_URL=http://127.0.0.1:8008 tests/stack/up.sh
NOTE: that harness still serves the UI through mock-bff.mjs (a hand-written
stand-in for the BFF) — Casdoor and Mastodon above stay UNUSED by it, and only
the Synapse leg becomes real. For the UI to talk to the REAL gateway + Spring
BFFs + Casdoor OAuth login, use instead:
  make stack-up SOCIAL=1 && make stack-seed SOCIAL=1   (see docs/LOCAL-STACK.md)

Tear down with: tests/stack/down-real.sh
EOF
