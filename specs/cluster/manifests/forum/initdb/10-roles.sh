#!/usr/bin/env bash
# 10-roles.sh — phpbb-db. Create the dedicated NON-OWNER application login role
# `phpbb_app` (own password from env) used by phpBB at RUNTIME for DML. The OWNER
# role (POSTGRES_USER "phpbb") stays install/migrate-only (it owns the schema +
# tables phpBB creates at install). Runs after 00-hardening.sql against "phpbb".
# See docs/POSTGRES-HARDENING.md.
#
# NOTE: phpBB creates its tables during the install/migrate step (run as the OWNER
# in the phpbb pod's init), AFTER this initdb runs. So the explicit per-table
# grants below cover whatever exists at first DB boot (usually none), and the
# ALTER DEFAULT PRIVILEGES ensures EVERY table the owner later creates is
# automatically granted to phpbb_app — so phpbb_app can DML the installed schema
# without ever holding DDL.
set -euo pipefail
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

if [ -z "${PHPBB_APP_PASSWORD:-}" ]; then
  echo "FATAL: PHPBB_APP_PASSWORD is empty — refusing to create a passwordless app role" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$PHPBB_APP_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'phpbb_app') THEN
    CREATE ROLE phpbb_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 20;
  END IF;
END
$$;
ALTER ROLE phpbb_app WITH PASSWORD :'app_pw';

GRANT CONNECT ON DATABASE phpbb TO phpbb_app;
GRANT USAGE  ON SCHEMA  public  TO phpbb_app;   -- NO CREATE

-- Cover any tables/sequences that already exist at this point (usually none —
-- phpBB installs its schema after initdb).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO phpbb_app;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO phpbb_app;

-- Every table/sequence the OWNER (phpbb) creates LATER (the phpBB install) is
-- auto-granted to phpbb_app, so the runtime role can DML the installed schema.
ALTER DEFAULT PRIVILEGES FOR ROLE phpbb IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO phpbb_app;
ALTER DEFAULT PRIVILEGES FOR ROLE phpbb IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO phpbb_app;
SQL

echo "[phpbb initdb] created least-privilege app role phpbb_app (owner stays install/DDL-only)"
