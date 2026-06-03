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

-- Canonical seed — one allow row per (gateway, url_pattern, role) in the routing
-- contract. Role semantics (mirroring the snapdragon.games SecurityConfig
-- casdoorAuthoritiesConverter):
--   ROLE_ANONYMOUS  public: no Casdoor JWT required (login, OIDC discovery, the
--                   front page). The gateway lets the request through unauth'd.
--   ROLE_USER       the authenticated floor: any valid Casdoor principal holds
--                   it (this is the "public-floor" of /api/auth/** etc.).
--   ROLE_ADMIN      JWT "roles" claim contains admin, or the legacy isAdmin flag.
-- A request is allowed iff the caller holds the role of a matching allow row for
-- THIS gateway; the most specific matching url_pattern wins (admin paths first).
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  -- pki-gateway (id.snapdragon.systems -> Casdoor)
  ('snapdragon-pki-gateway', '/api/auth/**',          'ROLE_USER',      true),  -- public-floor
  ('snapdragon-pki-gateway', '/login/**',             'ROLE_ANONYMOUS', true),  -- public
  ('snapdragon-pki-gateway', '/.well-known/**',       'ROLE_ANONYMOUS', true),  -- public (OIDC/jwks)

  -- be-gateway (api./matrix./mastodon.snapdragon.systems -> APIs/Matrix/Mastodon)
  ('snapdragon-be-gateway',  '/_matrix/**',           'ROLE_USER',      true),  -- Matrix C-S API
  ('snapdragon-be-gateway',  '/api/v1/**',            'ROLE_USER',      true),  -- Mastodon REST API
  ('snapdragon-be-gateway',  '/oauth/**',             'ROLE_USER',      true),  -- Mastodon OAuth
  ('snapdragon-be-gateway',  '/api/admin/**',         'ROLE_ADMIN',     true),  -- snapdragon admin API
  ('snapdragon-be-gateway',  '/api/**',               'ROLE_USER',      true),  -- snapdragon APIs

  -- fe-gateway (snapdragon.systems -> Angular host + MFEs + same-origin /bff)
  ('snapdragon-fe-gateway',  '/',                     'ROLE_ANONYMOUS', true),  -- public front page
  ('snapdragon-fe-gateway',  '/social/matrix/**',     'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/social/mastodon/**',   'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/login/**',             'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/admin/**',             'ROLE_ADMIN',     true),
  ('snapdragon-fe-gateway',  '/bff/login',            'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/register/**',      'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/provision/**',     'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/me/**',            'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/admin/**',         'ROLE_ADMIN',     true)
ON CONFLICT DO NOTHING;
