-- 00-hardening.sql — federation-db. Runs FIRST in /docker-entrypoint-initdb.d as
-- the owner (POSTGRES_USER "federation") against the fresh "federation" DB.
-- General Postgres hardening; the least-privilege app login role + grants are in
-- 10-roles.sh (needs the app password from env). See docs/POSTGRES-HARDENING.md.
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

ALTER DATABASE federation SET statement_timeout = '30s';
ALTER DATABASE federation SET idle_in_transaction_session_timeout = '60s';
ALTER DATABASE federation SET lock_timeout = '10s';

-- Strip the implicit PUBLIC privileges; every grant becomes explicit. The owner
-- (Liquibase/DDL) keeps full rights as the schema owner; the app role gets only
-- DML, granted in 10-roles.sh.
REVOKE ALL ON SCHEMA   public     FROM PUBLIC;
REVOKE ALL ON DATABASE federation FROM PUBLIC;
