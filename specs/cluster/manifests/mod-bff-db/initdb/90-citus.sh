#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for mod-bff-db. NO-OP by default.
# Gated on a Citus-enabled image + SHARDING_CITUS=on. The single table (mod_action,
# a moderation audit log) is append-heavy; if you scale out, hash-distribute it by
# the actor/subject id once the app PK includes that column (DEFERRED app change),
# or keep it single-node. This only enables the extension when opted in.
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[mod-bff initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[mod-bff initdb] SHARDING_CITUS=on — enabling Citus extension (distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL
echo "[mod-bff initdb] Citus enabled. Distribute mod_action post-migration if scaling out (see docs/POSTGRES-HARDENING.md)."
