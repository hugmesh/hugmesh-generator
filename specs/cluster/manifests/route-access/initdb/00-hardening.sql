-- 00-hardening.sql — runs FIRST in /docker-entrypoint-initdb.d (alphabetical),
-- against the freshly-created POSTGRES_DB ("gateway") as the owner/superuser.
-- General Postgres hardening that is independent of which login roles exist;
-- the per-machine-user login roles + grants are created in 10-roles.sh (it needs
-- the per-user passwords from env, so it is a shell script, not static SQL).
--
-- What this does:
--   * REVOKE the implicit PUBLIC privileges so a brand-new login role can NOT
--     read/create in the database or the public schema by accident. Every grant
--     is then EXPLICIT (least privilege) — see 10-roles.sh.
--   * Set server-side per-database safety timeouts (statement / idle-in-tx) so a
--     stuck client can never pin a connection or hold locks forever.
-- scram-sha-256 password hashing is enforced via POSTGRES_INITDB_ARGS
-- (--auth-host=scram-sha-256) on the Deployment and password_encryption below.

-- Force scram-sha-256 for any password SET from now on (defence in depth on top
-- of the initdb --auth-host flag, which only governs pg_hba method selection).
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

-- Per-database safety valves. A runaway query is cancelled after 30s; a session
-- that opens a transaction and goes idle is killed after 60s so it cannot hold
-- locks / bloat. Applied at the DB level so EVERY role inherits them (a role may
-- tighten further, never loosen silently).
ALTER DATABASE gateway SET statement_timeout = '30s';
ALTER DATABASE gateway SET idle_in_transaction_session_timeout = '60s';
ALTER DATABASE gateway SET lock_timeout = '10s';

-- Drop the dangerous default where ANY role may create objects in / use the
-- public schema. We re-grant USAGE explicitly to the app roles in 10-roles.sh.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
-- Revoke the implicit CONNECT-for-everyone on the database; explicit GRANT
-- CONNECT per login role follows in 10-roles.sh.
REVOKE ALL ON DATABASE gateway FROM PUBLIC;
