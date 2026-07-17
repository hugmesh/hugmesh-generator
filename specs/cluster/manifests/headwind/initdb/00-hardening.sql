-- 00-hardening.sql — headwind-db. Runs FIRST as the owner (POSTGRES_USER "headwind")
-- against the fresh "headwind" DB. Cloned from forum/initdb/00-hardening.sql.
-- See docs/POSTGRES-HARDENING.md.
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

ALTER DATABASE headwind SET statement_timeout = '30s';
ALTER DATABASE headwind SET idle_in_transaction_session_timeout = '60s';
ALTER DATABASE headwind SET lock_timeout = '10s';

-- Headwind's Liquibase migration OWNS its schema (runs as the owner role), so DO
-- NOT revoke CREATE from the owner. Only lock down PUBLIC.
REVOKE ALL ON DATABASE headwind FROM PUBLIC;
REVOKE ALL ON SCHEMA   public   FROM PUBLIC;
