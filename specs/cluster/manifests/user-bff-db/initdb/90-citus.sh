#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for user-bff-db. NO-OP by default.
# Gated on a Citus-enabled image (citusdata/citus:12-pg16) + SHARDING_CITUS=on.
# Tables are Liquibase-owned (created at APP boot, not initdb), so the actual
# create_distributed_table() is a POST-migration step; this only enables the
# extension when opted in. See docs/POSTGRES-HARDENING.md.
#
# Shard key: user_id — the natural per-user partition for self-service data.
#   user_profile     -> distribute by user_id   (PK IS user_id -> CLEAN distribute)
#   user_preference  -> distribute by user_id    (co-located with the profile)
#   user_block       -> distribute by user_id    (PK is `id`; see CAVEAT)
# CAVEAT: user_block PKs on `id` (not user_id). Citus requires the distribution
# column in every UNIQUE/PK constraint, so hash-distributing user_block by user_id
# needs the app PK widened to (id, user_id) — a DEFERRED app change. user_profile
# distributes cleanly today (its PK already IS user_id).
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[user-bff initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[user-bff initdb] SHARDING_CITUS=on — enabling Citus extension (distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL

cat <<'NOTE'
[user-bff initdb] Citus enabled. AFTER the app's first Liquibase migration, run ONCE
(one-shot Job) to distribute by user_id (co-located so per-user joins stay local):
  SELECT create_distributed_table('user_profile',    'user_id');   -- PK is user_id: clean
  SELECT create_distributed_table('user_preference', 'user_id', colocate_with => 'user_profile');
  -- user_block needs its PK widened to (id, user_id) first (DEFERRED app change):
  -- SELECT create_distributed_table('user_block', 'user_id', colocate_with => 'user_profile');
See docs/POSTGRES-HARDENING.md for shard-key rationale + scaling to Citus workers.
NOTE
