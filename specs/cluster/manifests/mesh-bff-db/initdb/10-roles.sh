#!/usr/bin/env bash
# 10-roles.sh — mesh-bff-db. Create the dedicated NON-OWNER application login role
# `meshbff_app` (own password from env) with runtime DML only. The OWNER role
# (POSTGRES_USER "meshbff") stays DDL/Liquibase-only. Runs after 00-hardening.sql
# against the "meshbff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${MESHBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: MESHBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$MESHBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meshbff_app') THEN
    CREATE ROLE meshbff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE meshbff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE meshbff TO meshbff_app;
GRANT USAGE  ON SCHEMA  public   TO meshbff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO meshbff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO meshbff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE meshbff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO meshbff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE meshbff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO meshbff_app;
SQL

echo "[mesh-bff initdb] created least-privilege app role meshbff_app (owner stays DDL-only)"
