#!/usr/bin/env bash
# 90-citus.sh — OPT-IN Citus sharding for character-forge-bff-db. NO-OP by default.
# Gated on a Citus-enabled image (citusdata/citus:12-pg16) + SHARDING_CITUS=on.
# Tables are Liquibase-owned (created at APP boot, not initdb), so the actual
# create_distributed_table() is a POST-migration step; this only enables the
# extension when opted in. See docs/POSTGRES-HARDENING.md.
#
# Shard key: owner_subject — the natural per-user partition for the character-forge
# datastore (character_forge_character keys rows to their owner's Casdoor subject).
# Distribution is a DEFERRED post-migration step; co-locate by subject so per-user
# joins stay local.
set -euo pipefail

if [ "${SHARDING_CITUS:-off}" != "on" ]; then
  echo "[character-forge-bff initdb] SHARDING_CITUS!=on — single-node (no Citus). Default path."
  exit 0
fi

echo "[character-forge-bff initdb] SHARDING_CITUS=on — enabling Citus extension (distribution is a POST-migration step)"
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
SQL

cat <<'NOTE'
[character-forge-bff initdb] Citus enabled. AFTER the app's first Liquibase migration, run
ONCE (one-shot Job) to distribute by owner_subject (co-located so per-user joins
stay local). NOTE: Citus requires the distribution column in every UNIQUE/PK
constraint, so character_forge_character (PK `id`, partial-unique on
owner_subject+domain) needs its PK widened to include owner_subject first (a
DEFERRED app change).
See docs/POSTGRES-HARDENING.md for shard-key rationale + scaling to Citus workers.
NOTE
