#!/usr/bin/env bash
# 10-roles.sh — create the per-machine-user LEAST-PRIVILEGE login roles for
# route-access-db. Runs in /docker-entrypoint-initdb.d AFTER 00-hardening.sql and
# BEFORE 20-schema.sql (alphabetical order), as the Postgres superuser, against
# the freshly-initialised "gateway" database.
#
# It is a SHELL script (not plain .sql) because each role gets its OWN password,
# injected from per-user k8s Secrets via the env vars below — never committed.
# A missing/empty password is a hard error: we must NOT create a passwordless or
# shared-password login role. The "gateway" OWNER role (POSTGRES_USER/PASSWORD)
# is the admin-bff's DDL handle is NOT touched here; it stays the owner that the
# admin-bff Liquibase/DDL path uses. The roles below are the runtime, non-owner,
# least-privilege identities.
#
# Role/grant matrix (see docs/POSTGRES-HARDENING.md for the full table):
#   admin-bff     -> SELECT/INSERT/UPDATE/DELETE on gateway_route_access  (writer)
#   pki-gateway   -> SELECT on gateway_route_access                       (reader)
#   be-gateway    -> SELECT on gateway_route_access                       (reader)
#   fe-gateway    -> SELECT on gateway_route_access                       (reader)
# (No url_registry table lives in this DB — the gateway URL registry is in
#  Cassandra — so route-access grants cover gateway_route_access only.)
set -euo pipefail

: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}"

require() { # require VAR_NAME human-name
  local v="${!1:-}"
  if [ -z "$v" ]; then
    echo "FATAL: $2 password ($1) is empty — refusing to create a passwordless/shared login role" >&2
    exit 1
  fi
}
require ROUTE_ACCESS_ADMIN_BFF_PASSWORD  "admin-bff"
require ROUTE_ACCESS_PKI_GATEWAY_PASSWORD "pki-gateway"
require ROUTE_ACCESS_BE_GATEWAY_PASSWORD  "be-gateway"
require ROUTE_ACCESS_FE_GATEWAY_PASSWORD  "fe-gateway"

# psql connected to the target DB as the bootstrap superuser. ON_ERROR_STOP so any
# failure aborts initdb (the pod restarts and retries on an empty volume).
psql_db() { psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"; }

# Create the four login roles. Passwords are passed as psql variables (:'var') so
# they are correctly quoted/escaped and never interpolated into the shell-visible
# SQL text. NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT — pure login identities
# with only the privileges we GRANT below. CONNECTION LIMIT caps each machine
# user's concurrent connections (gateways pool small; admin-bff a touch more).
psql_db \
  -v ab_pw="$ROUTE_ACCESS_ADMIN_BFF_PASSWORD" \
  -v pki_pw="$ROUTE_ACCESS_PKI_GATEWAY_PASSWORD" \
  -v be_pw="$ROUTE_ACCESS_BE_GATEWAY_PASSWORD" \
  -v fe_pw="$ROUTE_ACCESS_FE_GATEWAY_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_bff') THEN
    CREATE ROLE admin_bff   LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 10;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pki_gateway') THEN
    CREATE ROLE pki_gateway LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 5;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'be_gateway') THEN
    CREATE ROLE be_gateway  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 5;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fe_gateway') THEN
    CREATE ROLE fe_gateway  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 5;
  END IF;
END
$$;

-- Set/rotate each password (scram-sha-256 per 00-hardening.sql). Idempotent.
ALTER ROLE admin_bff   WITH PASSWORD :'ab_pw';
ALTER ROLE pki_gateway WITH PASSWORD :'pki_pw';
ALTER ROLE be_gateway  WITH PASSWORD :'be_pw';
ALTER ROLE fe_gateway  WITH PASSWORD :'fe_pw';

-- Explicit CONNECT (PUBLIC connect was revoked in 00-hardening.sql) + USAGE on
-- the schema. NO CREATE on the schema for any of them.
GRANT CONNECT ON DATABASE gateway TO admin_bff, pki_gateway, be_gateway, fe_gateway;
GRANT USAGE   ON SCHEMA  public   TO admin_bff, pki_gateway, be_gateway, fe_gateway;
SQL

echo "[route-access initdb] created least-privilege login roles: admin_bff, pki_gateway, be_gateway, fe_gateway"
