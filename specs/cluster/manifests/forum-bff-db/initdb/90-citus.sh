#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for forum-bff-db. NO-OP by default.
# Gated on a Citus-enabled image (citusdata/citus:12-pg16) + SHARDING_CITUS=on.
# Tables are Liquibase-owned (created at APP boot, not initdb), so the actual
# create_distributed_table() is a POST-migration step; this only enables the
# extension when opted in. See docs/POSTGRES-HARDENING.md.
#
# Shard key: casdoor_subject — the natural per-user partition for the forum config
# datastore (forum_user_role keys on casdoor_subject; forum_action keys actions to
# actor_subject). Distribution is a DEFERRED post-migration step; co-locate by
# subject so per-user joins stay local.
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[forum-bff initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[forum-bff initdb] SHARDING_CITUS=on — enabling Citus extension (distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL

cat <<'NOTE'
[forum-bff initdb] Citus enabled. AFTER the app's first Liquibase migration, run
ONCE (one-shot Job) to distribute by casdoor_subject (co-located so per-user joins
stay local). NOTE: Citus requires the distribution column in every UNIQUE/PK
constraint, so any table whose PK is NOT casdoor_subject (e.g. forum_action keyed
on `id`) needs its PK widened to include casdoor_subject first (a DEFERRED app
change). forum_user_role distributes cleanly (its UNIQUE key IS casdoor_subject).
See docs/POSTGRES-HARDENING.md for shard-key rationale + scaling to Citus workers.
NOTE
