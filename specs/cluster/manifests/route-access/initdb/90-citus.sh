#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for route-access-db. NO-OP by default.
#
# Runs LAST in /docker-entrypoint-initdb.d. Does nothing unless BOTH:
#   * the Deployment image is a Citus-enabled Postgres (citusdata/citus:12-pg16),
#     so the `citus` extension is installable; AND
#   * SHARDING_CITUS=on is set in the pod env.
# With the default postgres:16-alpine image + SHARDING_CITUS unset, this script
# exits 0 immediately and the single-node deployment is byte-for-byte unchanged.
#
# Shard key for this DB: gateway_route_access is LOW cardinality + low write rate
# and every gateway reads the rows for its own `gateway`, so it is distributed as
# a Citus REFERENCE TABLE (full copy on every node) rather than hash-distributed —
# reads stay local on every worker and the admin-bff's writes replicate. If you
# would rather hash-distribute by `gateway`, see docs/POSTGRES-HARDENING.md
# (requires widening the PK/unique constraint to include `gateway`).
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[route-access initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

psql_db() { psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" "$@"; }

echo "[route-access initdb] SHARDING_CITUS=on — enabling Citus + distributing tables"
psql_db <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
-- Reference table: replicated to all workers; the gateways' SELECTs are local and
-- the admin-bff's CRUD fans out to every node. No PK change needed.
SELECT create_reference_table('gateway_route_access');
SQL
echo "[route-access initdb] Citus reference table ready for gateway_route_access"
