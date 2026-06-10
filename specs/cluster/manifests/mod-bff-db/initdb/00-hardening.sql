-- 00-hardening.sql — mod-bff-db. Runs FIRST as the owner (POSTGRES_USER "modbff")
-- against the fresh "modbff" DB. General Postgres hardening; the least-privilege
-- app login role + grants are in 10-roles.sh. See docs/POSTGRES-HARDENING.md.
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

ALTER DATABASE modbff SET statement_timeout = '30s';
ALTER DATABASE modbff SET idle_in_transaction_session_timeout = '60s';
ALTER DATABASE modbff SET lock_timeout = '10s';

REVOKE ALL ON SCHEMA   public FROM PUBLIC;
REVOKE ALL ON DATABASE modbff FROM PUBLIC;
