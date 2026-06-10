#!/usr/bin/env bash
# 10-roles.sh — user-bff-db. Create the dedicated NON-OWNER application login role
# `userbff_app` (own password from env) with runtime DML only. The OWNER role
# (POSTGRES_USER "userbff") stays DDL/Liquibase-only. Runs after 00-hardening.sql
# against the "userbff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${USERBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: USERBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$USERBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'userbff_app') THEN
    CREATE ROLE userbff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE userbff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE userbff TO userbff_app;
GRANT USAGE  ON SCHEMA  public    TO userbff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO userbff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO userbff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE userbff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO userbff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE userbff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO userbff_app;
SQL

echo "[user-bff initdb] created least-privilege app role userbff_app (owner stays DDL-only)"
