#!/usr/bin/env bash
# down-real.sh — stop and remove the real integration stack (compose.real.yaml).
# Pass --keep-volumes to preserve the Postgres/tuwunel/Cassandra data volumes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${COMPOSE:-docker compose} -f ${HERE}/compose.real.yaml"
# compose.real.yaml reads its DB passwords as ${KEY:?...} from tests/stack/.env
# (hugmesh-generator#857); compose needs them even to tear down. Ensure, never
# rotate: an existing volume's value is adopted. The keys are NOT removed here:
# tests/stack/.env is shared with the hugmesh-local project (make stack-down owns that).
STACK_DB_PROJECT=hugmesh-real bash "${HERE}/gen-stack-db-env.sh" || exit 1
if [ "${1:-}" = "--keep-volumes" ]; then
  ${COMPOSE} down
else
  ${COMPOSE} down -v
fi
echo "real stack down."
