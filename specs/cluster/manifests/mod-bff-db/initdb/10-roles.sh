#!/usr/bin/env bash
# 10-roles.sh — mod-bff-db. Create the dedicated NON-OWNER application login role
# `modbff_app` (own password from env) with runtime DML only. The OWNER role
# (POSTGRES_USER "modbff") stays DDL/Liquibase-only. Runs after 00-hardening.sql
# against the "modbff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${MODBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: MODBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$MODBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'modbff_app') THEN
    CREATE ROLE modbff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE modbff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE modbff TO modbff_app;
GRANT USAGE  ON SCHEMA  public   TO modbff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO modbff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO modbff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE modbff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO modbff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE modbff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO modbff_app;
SQL

echo "[mod-bff initdb] created least-privilege app role modbff_app (owner stays DDL-only)"
