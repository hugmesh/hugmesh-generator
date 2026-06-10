#!/usr/bin/env bash
# 10-roles.sh — admin-bff-db. Create the dedicated NON-OWNER application login
# role `adminbff_app` (own password from env) with runtime DML only. The OWNER
# role (POSTGRES_USER "adminbff") stays DDL/Liquibase-only. Runs after
# 00-hardening.sql against the "adminbff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${ADMINBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: ADMINBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$ADMINBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'adminbff_app') THEN
    CREATE ROLE adminbff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE adminbff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE adminbff TO adminbff_app;
GRANT USAGE  ON SCHEMA  public     TO adminbff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO adminbff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO adminbff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE adminbff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO adminbff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE adminbff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO adminbff_app;
SQL

echo "[admin-bff initdb] created least-privilege app role adminbff_app (owner stays DDL-only)"
