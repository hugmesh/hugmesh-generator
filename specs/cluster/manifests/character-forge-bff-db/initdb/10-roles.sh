#!/usr/bin/env bash
# 10-roles.sh — character-forge-bff-db. Create the dedicated NON-OWNER application login role
# `charforgebff_app` (own password from env) with runtime DML only. The OWNER role
# (POSTGRES_USER "charforgebff") stays DDL/Liquibase-only. Runs after 00-hardening.sql
# against the "charforgebff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${CHARFORGEBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: CHARFORGEBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$CHARFORGEBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'charforgebff_app') THEN
    CREATE ROLE charforgebff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE charforgebff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE charforgebff TO charforgebff_app;
GRANT USAGE  ON SCHEMA  public     TO charforgebff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO charforgebff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO charforgebff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE charforgebff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO charforgebff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE charforgebff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO charforgebff_app;
SQL

echo "[character-forge-bff initdb] created least-privilege app role charforgebff_app (owner stays DDL-only)"
