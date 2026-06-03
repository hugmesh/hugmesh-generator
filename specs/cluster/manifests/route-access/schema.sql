-- gateway_route_access — which Casdoor roles may reach which URL patterns from
-- OUTSIDE a given gateway (external = from the VPN/cloud, before the gateway).
-- Managed by the admin-api (CRUD); each snapdragon-*-gateway loads the rows for
-- its own gateway name, caches them in Cassandra (periodic refresh like the
-- existing revocation/url-registry caches), and denies a request unless the
-- caller's Casdoor roles match an `allow` rule for the matched URL pattern.
--
-- This is the snapdragon-id-gateway Postgres-backed pattern WITHOUT the random
-- per-app URL generation — just role-based external access control to the
-- already-known services. Roles are owned by Casdoor; rows reference a Casdoor
-- role (and optionally a specific Casdoor user) by name.
CREATE TABLE IF NOT EXISTS gateway_route_access (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway      text        NOT NULL,   -- snapdragon-pki-gateway | -be-gateway | -fe-gateway
    url_pattern  text        NOT NULL,   -- Spring path pattern, e.g. /api/admin/**, /social/**
    role         text        NOT NULL,   -- Casdoor role, e.g. ROLE_ADMIN, ROLE_USER
    casdoor_user text,                   -- optional: pin to a specific Casdoor user
    allow        boolean     NOT NULL DEFAULT true,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_route_access_gw ON gateway_route_access (gateway, url_pattern);

-- Seed: public auth/login/registration on every gateway; admin paths admin-only.
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ('snapdragon-pki-gateway', '/api/auth/**',         'ROLE_USER',  true),
  ('snapdragon-pki-gateway', '/login/**',            'ROLE_USER',  true),
  ('snapdragon-fe-gateway',  '/login/**',            'ROLE_USER',  true),
  ('snapdragon-fe-gateway',  '/social/**',           'ROLE_USER',  true),
  ('snapdragon-fe-gateway',  '/admin/**',            'ROLE_ADMIN', true),
  ('snapdragon-be-gateway',  '/api/admin/**',        'ROLE_ADMIN', true),
  ('snapdragon-be-gateway',  '/api/**',              'ROLE_USER',  true)
ON CONFLICT DO NOTHING;
