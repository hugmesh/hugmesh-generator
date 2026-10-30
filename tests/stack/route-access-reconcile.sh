#!/usr/bin/env bash
# route-access-reconcile.sh — re-apply the canonical route-access seed to a
# RUNNING local stack's route-access-db, on every bring-up.
#
# THE DEFECT (measured 2026-10-29 on an operator's compose stack): the local
# route-access-db (tests/stack/compose.local.yaml) seeds gateway_route_access ONLY
# through /docker-entrypoint-initdb.d, i.e. on the volume's FIRST init. A stack
# whose volume predates a route change never receives the new rows: after #824
# merged, `make stack-up GAMES=1` left the live table with 1 of the 8 fe /games
# rows and every games member got 403 until the file was re-applied by hand.
# The fe/be gateways REPLACE their baked CanonicalSeed with the DB rows on their
# 5 s refresh (CanonicalSeed.java: "Once Postgres/Cassandra answer, the loaded
# rows replace this snapshot wholesale"), so a stale table is AUTHORITATIVE —
# a row missing from the DB is a route nobody can reach.
#
# WHAT IT DOES: feed the SAME file the first init ran —
# specs/cluster/manifests/route-access/initdb/20-schema.sql — through psql in
# ONE transaction with ON_ERROR_STOP, and print COUNTS only (never a row).
# The file is designed and proven for in-place re-apply (its own header, and
# tests/scripts/test-mfa-required-rules.sh leg 1c replays it twice on the real
# engine and demands a no-op). On a populated table every statement is one of:
#   * a no-op (CREATE/ALTER … IF NOT EXISTS, SET DEFAULT/NOT NULL, the NULL
#     backfill, the de-dup DELETE, the DROP+CREATE of uq_route_access_row);
#   * ADDITIVE (INSERT … ON CONFLICT DO NOTHING): a seed row the table lacks is
#     added; an existing row — including one an admin changed (allow,
#     mfa_required, casdoor_user, domain) — is left exactly as it is;
#   * the file's declared CONVERGENCE (its "OPERATOR CAVEAT" block): the trailing
#     UPDATEs re-flip mfa_required=true on allow rows under /bff/admin,
#     /bff/superadmin and /bff/<svc>/admin|superadmin, so a CRUD LOOSENING under
#     those prefixes is undone here exactly as the file documents; a TIGHTENING
#     anywhere (mfa_required=true outside the prefixes) is preserved;
#   * the retirement of the one misspelled '/apidocs/**' fe row.
# The one semantic this ADDS to a stack: a seed row an admin DELETED comes back.
# That is the "seed is the floor" contract the file already states for an
# in-place cluster upgrade; a route is removed by editing the seed, not a row.
#
# USAGE
#   bash tests/stack/route-access-reconcile.sh          # the running compose stack
#   make stack-route-access-reconcile                   # same
# `make stack-up` runs it right after `compose up -d`, so a stack whose volume
# predates a route change converges on its next bring-up. No gateway restart is
# needed: each gateway re-reads the table on its refresh tick.
#
# TARGET SELECTION (first match wins) — the guard test uses the first two so it
# can never reach an operator's running stack:
#   ROUTE_ACCESS_CONTAINER=<name|id>  docker exec -i <c> psql (TCP to 127.0.0.1,
#                                     so the official image's socket-only initdb
#                                     server is NOT mistaken for the real one)
#   POSTGRES_HOST=<host>              psql -h <host> (a CI `services:` postgres)
#   (default)                         docker compose -f tests/stack/compose.local.yaml
#                                     exec -T route-access-db psql
# `make stack-up` and `make stack-route-access-reconcile` blank both overrides,
# so they always reach the compose service whatever the shell exports (a
# POSTGRES_HOST set for a seed replay must not redirect a bring-up).
# ROUTE_ACCESS_SQL overrides the seed file; ROUTE_ACCESS_WAIT_SECS the readiness
# wait (default 120). Exit 1 on any SQL error (the transaction is rolled back,
# the table is untouched) or if the database never becomes reachable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

SQL="${ROUTE_ACCESS_SQL:-${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql}"
COMPOSE_FILE="${STACK_COMPOSE:-${REPO}/tests/stack/compose.local.yaml}"
PG_USER="${ROUTE_ACCESS_PG_USER:-gateway}"
PG_DB="${ROUTE_ACCESS_PG_DB:-gateway}"
WAIT_SECS="${ROUTE_ACCESS_WAIT_SECS:-120}"

[ -r "${SQL}" ] || { echo "route-access reconcile: FAIL seed file not readable: ${SQL}" >&2; exit 1; }

# pg <psql args…>: one psql invocation against the selected target. -X skips
# any ~/.psqlrc; every caller adds its own -v ON_ERROR_STOP / -1 / -tA.
if [ -n "${ROUTE_ACCESS_CONTAINER:-}" ]; then
  TARGET="container ${ROUTE_ACCESS_CONTAINER}"
  # The password never leaves the container: the image's own POSTGRES_PASSWORD
  # becomes PGPASSWORD inside it (TCP auth is scram; a socket connection would
  # also reach the init-phase temp server, which is exactly the race to avoid).
  pg() { docker exec -i "${ROUTE_ACCESS_CONTAINER}" sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" exec psql -X -h 127.0.0.1 "$@"' psql -U "${PG_USER}" -d "${PG_DB}" "$@"; }
elif [ -n "${POSTGRES_HOST:-}" ]; then
  TARGET="host ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}"
  command -v psql >/dev/null 2>&1 || { echo "route-access reconcile: FAIL POSTGRES_HOST=${POSTGRES_HOST} is set but psql is not installed" >&2; exit 1; }
  pg() { psql -X -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${PG_USER}" -d "${PG_DB}" "$@"; }
else
  TARGET="compose service route-access-db (${COMPOSE_FILE})"
  [ -r "${COMPOSE_FILE}" ] || { echo "route-access reconcile: FAIL compose file not readable: ${COMPOSE_FILE}" >&2; exit 1; }
  # shellcheck disable=SC2086  # COMPOSE_CMD is a command WITH its subcommand ("docker compose")
  pg() { ${COMPOSE_CMD:-docker compose} -f "${COMPOSE_FILE}" exec -T route-access-db sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" exec psql -X -h 127.0.0.1 "$@"' psql -U "${PG_USER}" -d "${PG_DB}" "$@"; }
fi

# Readiness: a real SELECT over the same path the apply will use (not pg_isready,
# which answers for the init-phase temp server too). Bounded; fail loud.
deadline=$(( $(date +%s) + WAIT_SECS ))
until pg -q -tA -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "route-access reconcile: FAIL ${TARGET} not reachable as ${PG_USER}/${PG_DB} within ${WAIT_SECS}s" >&2
    exit 1
  fi
  sleep 2
done

count_rows() {
  # 0 when the table does not exist yet (a reconcile over an EMPTY database is a
  # first seed, which the file also supports).
  pg -q -tA -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM gateway_route_access' 2>/dev/null || echo 0
}

before="$(count_rows)"
LOG="$(mktemp "${TMPDIR:-/tmp}/route-access-reconcile.XXXXXX")"
trap 'rm -f "${LOG}"' EXIT

# THE APPLY. -1 = one transaction (a failure anywhere rolls back everything, so
# the table is never left half-reconciled); ON_ERROR_STOP = the first error ends
# the run with a non-zero status instead of psql pressing on. No -q: the command
# tags (INSERT 0 n / UPDATE n / DELETE n) are what the count line is built from.
if ! pg -v ON_ERROR_STOP=1 -1 <"${SQL}" >"${LOG}" 2>&1; then
  echo "route-access reconcile: FAIL applying $(basename "${SQL}") to ${TARGET} — transaction rolled back, table unchanged (${before} rows)" >&2
  grep -E 'ERROR|FATAL|psql:|could not' "${LOG}" | tail -n 5 >&2 || true
  exit 1
fi

after="$(count_rows)"
# Sum the command tags. Only the seed INSERT inserts; the two DELETEs are the
# de-dup and the '/apidocs/**' retirement; the UPDATEs are the NULL backfill and
# the two mfa_required flips (all three write mfa_required and nothing else).
inserted="$(awk '$1=="INSERT"{n+=$3} END{print n+0}' "${LOG}")"
deleted="$(awk '$1=="DELETE"{n+=$2} END{print n+0}' "${LOG}")"
updated="$(awk '$1=="UPDATE"{n+=$2} END{print n+0}' "${LOG}")"
mfa_true="$(pg -q -tA -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM gateway_route_access WHERE mfa_required' 2>/dev/null || echo '?')"

echo "route-access reconcile: ${before} -> ${after} rows (inserted ${inserted}, deleted ${deleted}, mfa_required rewritten ${updated}; ${mfa_true} rows carry mfa_required=true) on ${TARGET}"
