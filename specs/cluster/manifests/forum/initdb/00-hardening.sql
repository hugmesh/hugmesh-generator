-- 00-hardening.sql — phpbb-db. Runs FIRST as the owner (POSTGRES_USER "phpbb")
-- against the fresh "phpbb" DB. General Postgres hardening; the least-privilege
-- app login role + grants are in 10-roles.sh. See docs/POSTGRES-HARDENING.md.
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

ALTER DATABASE phpbb SET statement_timeout = '30s';
ALTER DATABASE phpbb SET idle_in_transaction_session_timeout = '60s';
ALTER DATABASE phpbb SET lock_timeout = '10s';

-- phpBB OWNS its schema (created by the install/migrate step running as the owner
-- role), so DO NOT revoke schema CREATE from the owner. Only lock down PUBLIC.
REVOKE ALL ON DATABASE phpbb FROM PUBLIC;
REVOKE ALL ON SCHEMA   public FROM PUBLIC;
