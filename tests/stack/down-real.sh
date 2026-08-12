#!/usr/bin/env bash
# down-real.sh — stop and remove the real integration stack (compose.real.yaml).
# Pass --keep-volumes to preserve the Postgres/tuwunel/Cassandra data volumes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${COMPOSE:-docker compose} -f ${HERE}/compose.real.yaml"
if [ "${1:-}" = "--keep-volumes" ]; then
  ${COMPOSE} down
else
  ${COMPOSE} down -v
fi
echo "real stack down."
