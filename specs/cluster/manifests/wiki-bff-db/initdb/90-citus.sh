#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for wiki-bff-db. NO-OP by default.
# Gated on a Citus-enabled image (citusdata/citus:12-pg16) + SHARDING_CITUS=on.
# Tables are Liquibase-owned (created at APP boot, not initdb), so the actual
# create_distributed_table() is a POST-migration step; this only enables the
# extension when opted in. See docs/POSTGRES-HARDENING.md.
#
# Shard key: casdoor_subject — the natural per-user partition for the wiki content
# datastore (wiki_page and wiki_audit_log key actions to subject). Distribution is
# a DEFERRED post-migration step; co-locate by subject so per-user joins stay local.
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[wiki-bff initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[wiki-bff initdb] SHARDING_CITUS=on — enabling Citus extension (distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL

cat <<'NOTE'
[wiki-bff initdb] Citus enabled. AFTER the app's first Liquibase migration, run
ONCE (one-shot Job) to distribute by casdoor_subject (co-located so per-user joins
stay local). See docs/POSTGRES-HARDENING.md for shard-key rationale + scaling to
Citus workers.
NOTE
