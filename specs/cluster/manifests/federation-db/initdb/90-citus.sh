#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for federation-db. NO-OP by default.
#
# IMPORTANT ordering caveat: federation owns its tables via LIQUIBASE, which runs
# when the APP boots — AFTER Postgres initdb. So at initdb time the tables do NOT
# exist yet and create_distributed_table() cannot run here. This script therefore
# only ENABLES the extension at initdb (cheap, idempotent) when opted in; the
# actual create_distributed_table() calls are emitted as a documented MANUAL/Job
# step you run ONCE after the app's first migration (see the heredoc below and
# docs/POSTGRES-HARDENING.md "Distributing federation tables").
#
# Gated on BOTH a Citus-enabled image (citusdata/citus:12-pg16) AND
# SHARDING_CITUS=on. Default postgres:16-alpine + unset flag => exits 0, unchanged.
#
# Shard keys (high-cardinality, owner-scoped):
#   federation_modules  -> distribute by owner_user_id   (per-owner module registry)
#   user_modules        -> distribute by owner_user_id   (per-owner uploaded modules)
# CAVEAT: both tables PK on `id` (bigint identity), and Citus requires the
# distribution column to be part of every UNIQUE/PK constraint. Hash-distributing
# by owner_user_id thus needs the app's PK/unique widened to (id, owner_user_id)
# first — an app-side change tracked as DEFERRED (keeps the H2/PG-compat test
# slices untouched). Until then, run them as Citus REFERENCE tables (replicated)
# if you need multi-node now; the post-migration template below shows both.
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[federation initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[federation initdb] SHARDING_CITUS=on — enabling Citus extension (table distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL

cat <<'NOTE'
[federation initdb] Citus enabled. AFTER the app's first Liquibase migration, run
ONCE (e.g. a one-shot Job) to distribute the high-cardinality tables:

  -- Preferred once the PK is widened to include owner_user_id (DEFERRED app change):
  SELECT create_distributed_table('federation_modules', 'owner_user_id');
  SELECT create_distributed_table('user_modules',       'owner_user_id');

  -- Interim multi-node option WITHOUT an app schema change (replicated copies):
  -- SELECT create_reference_table('federation_modules');
  -- SELECT create_reference_table('user_modules');

See docs/POSTGRES-HARDENING.md for shard-key rationale + scaling to Citus workers.
NOTE
