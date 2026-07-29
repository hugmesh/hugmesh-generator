#!/usr/bin/env bash
# 10-roles.sh — wiki-bff-db. Create the dedicated NON-OWNER application login role
# `wikibff_app` (own password from env) with runtime DML only. The OWNER role
# (POSTGRES_USER "wikibff") stays DDL/Liquibase-only. Runs after 00-hardening.sql
# against the "wikibff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${WIKIBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: WIKIBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$WIKIBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wikibff_app') THEN
    CREATE ROLE wikibff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE wikibff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE wikibff TO wikibff_app;
GRANT USAGE  ON SCHEMA  public    TO wikibff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO wikibff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO wikibff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE wikibff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO wikibff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE wikibff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO wikibff_app;
SQL

echo "[wiki-bff initdb] created least-privilege app role wikibff_app (owner stays DDL-only)"
