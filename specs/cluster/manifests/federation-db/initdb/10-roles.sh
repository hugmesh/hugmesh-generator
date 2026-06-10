#!/usr/bin/env bash
# 10-roles.sh — federation-db. Create the dedicated NON-OWNER application login
# role `federation_app` with its OWN password (from env, never committed) and
# grant it ONLY runtime DML. Runs after 00-hardening.sql, as the owner
# (POSTGRES_USER "federation") against the "federation" DB.
#
# WHY a separate role: the OWNER role (POSTGRES_USER) is kept for DDL/Liquibase
# ONLY (the app runs its changelog at boot with the owner cred). The app's RUNTIME
# R2DBC handle logs in as `federation_app`, which can read/write rows but can NOT
# run DDL, create roles, or touch other schemas — so a compromised runtime cred
# cannot drop/alter tables.
#
# Tables are created LATER by Liquibase (not at initdb time), so we use
# ALTER DEFAULT PRIVILEGES: every table/sequence the OWNER creates from now on
# automatically grants DML/USAGE to federation_app. We also grant on anything that
# already exists (none yet, but idempotent + future-proof).
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${FEDERATION_APP_PASSWORD:-}" ]; then
  echo "FATAL: FEDERATION_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$FEDERATION_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'federation_app') THEN
    CREATE ROLE federation_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE federation_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE federation TO federation_app;
GRANT USAGE  ON SCHEMA  public       TO federation_app;   -- NO CREATE

-- Existing objects (none yet at initdb, but idempotent + covers re-runs).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO federation_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO federation_app;

-- Future objects the OWNER (Liquibase) creates: auto-grant runtime DML. This is
-- what makes the non-owner runtime role work without per-migration grant edits.
ALTER DEFAULT PRIVILEGES FOR ROLE federation IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO federation_app;
ALTER DEFAULT PRIVILEGES FOR ROLE federation IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO federation_app;
SQL

echo "[federation initdb] created least-privilege app role federation_app (owner stays DDL-only)"
