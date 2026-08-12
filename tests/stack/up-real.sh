#!/usr/bin/env bash
# up-real.sh — bring up the REAL integration stack (compose.real.yaml): actual
# tuwunel, Casdoor, Mastodon + their Postgres/Redis, plus the platform Cassandra.
# This is the heavyweight counterpart to up.sh (which runs the in-memory mocks).
#
# SCOPE: this swaps in real THIRD-PARTY backends only. It brings up no
# first-party Spring service (no gateway, no BFF). Pairing it with
# `tests/stack/up.sh` (this script's own closing message suggests
# REAL_MATRIX=1 for the Playwright harness) still serves the UI through
# mock-bff.mjs — a hand-written Node stand-in for the BFF that never calls
# Casdoor and has no "real Mastodon" mode; only the Matrix leg becomes real
# in that pairing. For the UI to talk to the REAL gateway + Spring BFFs +
# Casdoor OAuth login, use `make stack-up SOCIAL=1` instead (see
# docs/LOCAL-STACK.md) — it gets the same declaratively-configured tuwunel
# (both invocations start the same `tuwunel` service in compose.real.yaml)
# but does NOT run Mastodon's `db:prepare`; for that, either run this script
# or `docker compose ... run --rm mastodon-web bundle exec rails db:prepare`
# by hand.
#
# It does the Mastodon first-run setup compose can't express, then ups:
#   1. ensures tests/stack/.mastodon.env exists (generates any missing secrets),
#      then runs Mastodon's DB prepare before the web/sidekiq/streaming services.
#
# NOTE: the homeserver needs NO first-run step at all. Synapse used to need a
# self-healing entrypoint (generate homeserver.yaml + idempotently append
# enable_registration); tuwunel is configured entirely declaratively via the
# TUWUNEL_* env on its service (tests/stack/compose.real.yaml), so a fresh
# volume comes up registration-enabled on every bring-up path (this script,
# `make stack-up SOCIAL=1`, or a bare `docker compose --profile social up`).
# MATRIX_SERVER_NAME/MATRIX_REG_SECRET below are `export`ed so `${COMPOSE} up`
# (further down) still passes them through to that service via compose's own
# `${VAR}` interpolation.
#
# Tear down (and drop volumes) with: tests/stack/down-real.sh
#
# Env knobs:
#   MATRIX_SERVER_NAME    (default localhost)  Matrix server_name baked into the
#                         homeserver config. PINNED into tuwunel's RocksDB at
#                         first boot — changing it later needs a volume wipe
#                         (down-real.sh).
#   MATRIX_REG_SECRET     (default hugmesh-reg-secret) tuwunel
#                         registration_shared_secret — powers the
#                         Synapse-compatible /_synapse/admin/v1/register HMAC
#                         admin mint (ops tooling parity; the seed itself uses
#                         the public registration flow).
#   COMPOSE                (default "docker compose")  e.g. "podman compose"
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${HERE}/compose.real.yaml"
COMPOSE="${COMPOSE:-docker compose} -f ${COMPOSE_FILE}"
export MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-localhost}"
export MATRIX_REG_SECRET="${MATRIX_REG_SECRET:-hugmesh-reg-secret}"
MASTODON_ENV="${HERE}/.mastodon.env"

echo "==> Real integration stack (compose.real.yaml)"

# ── 1. Mastodon secrets: guarantee .mastodon.env exists and is COMPLETE ──
# .mastodon.env is GITIGNORED (dev secrets never land in git), so a fresh
# checkout has NO file at all — generate it instead of aborting. The shared
# gen-mastodon-env.sh writes/heals EVERY key the compose.real.yaml mastodon
# services need (LOCAL_DOMAIN/DB/REDIS, SECRET_KEY_BASE/OTP_SECRET, the
# ACTIVE_RECORD_ENCRYPTION_* trio Mastodon v4.3 refuses to boot without, and
# seed-e2e.sh's EMAIL_DOMAIN_ALLOWLIST), touching only missing/empty keys.
MASTODON_ENV="${MASTODON_ENV}" bash "${HERE}/gen-mastodon-env.sh"

# (The homeserver has no first-run step: tuwunel's whole config is TUWUNEL_*
# env on the service itself — see compose.real.yaml.)

# ── 2. Datastores + identity + matrix first, wait until healthy ──
echo "==> Starting datastores + Casdoor + tuwunel"
${COMPOSE} up -d casdoor-db mastodon-db mastodon-redis cassandra tuwunel casdoor

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
# tuwunel's image is distroless (no shell/curl), so it can't carry a compose
# healthcheck — wait on its HTTP surface from the host instead. Non-fatal like
# the old Synapse wait; the readiness probe below + seed-e2e.sh gate on it again.
echo "  waiting for tuwunel to answer /_matrix/client/versions (<=60s)"
for _ in $(seq 1 30); do
  curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:8008/_matrix/client/versions" && break
  sleep 2
done

# ── 3. Mastodon DB prepare (create + migrate, idempotent), then app tier ──
echo "==> Preparing Mastodon database (rails db:prepare)"
${COMPOSE} run --rm mastodon-web bundle exec rails db:prepare

echo "==> Starting Mastodon web + sidekiq + streaming"
${COMPOSE} up -d mastodon-web mastodon-sidekiq mastodon-streaming

# ── 4. Readiness summary ──
echo "==> Waiting on HTTP endpoints"
probe() { # name url
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "$2" && { echo "  $1: up ($2)"; return 0; }
    sleep 2
  done
  echo "  WARN: $1 did not answer at $2" >&2; return 1
}
probe tuwunel  "http://127.0.0.1:8008/_matrix/client/versions" || true
probe casdoor  "http://127.0.0.1:8000/"                        || true
probe mastodon "http://127.0.0.1:3000/health"                  || true

cat <<EOF

Real stack up. Endpoints:
  tuwunel (Matrix):  http://127.0.0.1:8008    (server_name=${MATRIX_SERVER_NAME}, reg secret=${MATRIX_REG_SECRET})
  Casdoor (OIDC):    http://127.0.0.1:8000
  Mastodon web:      http://127.0.0.1:3000
  Mastodon stream:   http://127.0.0.1:4000
  Cassandra:         127.0.0.1:9042 (gateway revocation list + URL registry)

Point the Playwright UI harness at real tuwunel with:
  REAL_MATRIX=1 SYNAPSE_URL=http://127.0.0.1:8008 tests/stack/up.sh
(SYNAPSE_URL is the frozen Spring-BFF env-name contract — the server behind
it is tuwunel.) NOTE: that harness still serves the UI through mock-bff.mjs
(a hand-written stand-in for the BFF) — Casdoor and Mastodon above stay
UNUSED by it, and only the Matrix leg becomes real. For the UI to talk to
the REAL gateway + Spring BFFs + Casdoor OAuth login, use instead:
  make stack-up SOCIAL=1 && make stack-seed SOCIAL=1   (see docs/LOCAL-STACK.md)

Tear down with: tests/stack/down-real.sh
EOF
