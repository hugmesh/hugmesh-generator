#!/usr/bin/env bash
# 10-roles.sh — forum-bff-db. Create the dedicated NON-OWNER application login role
# `forumbff_app` (own password from env) with runtime DML only. The OWNER role
# (POSTGRES_USER "forumbff") stays DDL/Liquibase-only. Runs after 00-hardening.sql
# against the "forumbff" DB. See docs/POSTGRES-HARDENING.md.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${FORUMBFF_APP_PASSWORD:-}" ]; then
  echo "FATAL: FORUMBFF_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$FORUMBFF_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'forumbff_app') THEN
    CREATE ROLE forumbff_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE forumbff_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE forumbff TO forumbff_app;
GRANT USAGE  ON SCHEMA  public     TO forumbff_app;   -- NO CREATE

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO forumbff_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO forumbff_app;

ALTER DEFAULT PRIVILEGES FOR ROLE forumbff IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO forumbff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE forumbff IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO forumbff_app;
SQL

echo "[forum-bff initdb] created least-privilege app role forumbff_app (owner stays DDL-only)"
