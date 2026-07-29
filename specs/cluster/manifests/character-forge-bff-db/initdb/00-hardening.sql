-- 00-hardening.sql — character-forge-bff-db. Runs FIRST as the owner (POSTGRES_USER
-- "charforgebff") against the fresh "charforgebff" DB. General Postgres hardening; the
-- least-privilege app login role + grants are in 10-roles.sh.
-- See docs/POSTGRES-HARDENING.md.
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

ALTER DATABASE charforgebff SET statement_timeout = '30s';
ALTER DATABASE charforgebff SET idle_in_transaction_session_timeout = '60s';
ALTER DATABASE charforgebff SET lock_timeout = '10s';

REVOKE ALL ON SCHEMA   public   FROM PUBLIC;
REVOKE ALL ON DATABASE charforgebff FROM PUBLIC;
