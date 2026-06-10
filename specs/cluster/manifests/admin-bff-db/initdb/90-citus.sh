#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for admin-bff-db. NO-OP by default.
# Gated on a Citus-enabled image + SHARDING_CITUS=on. Tables are Liquibase-owned
# (created at APP boot, not initdb), so distribution is a POST-migration step;
# this only enables the extension when opted in. See docs/POSTGRES-HARDENING.md.
#
# admin-bff tables are mostly low-cardinality config/admin state (account,
# allowlist, bff_session, namespace_grant, iso_artifacts, gateway_route_access).
# None is an obvious hash-shard candidate at this scale; the recommended Citus
# posture here is to keep them as REFERENCE tables (replicated) if you scale out,
# so admin reads/writes stay correct on every node.
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[admin-bff initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[admin-bff initdb] SHARDING_CITUS=on — enabling Citus extension (distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL

cat <<'NOTE'
[admin-bff initdb] Citus enabled. AFTER the app's first Liquibase migration, if you
scale out, run ONCE (one-shot Job). admin-bff state is low-cardinality, so prefer
reference tables:
  SELECT create_reference_table('account');
  SELECT create_reference_table('allowlist');
  SELECT create_reference_table('namespace_grant');
  SELECT create_reference_table('gateway_route_access');
See docs/POSTGRES-HARDENING.md.
NOTE
