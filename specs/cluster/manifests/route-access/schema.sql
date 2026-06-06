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
--   PUBLIC          public: no Casdoor JWT required (login, OIDC discovery, the
--                   front page). The gateway lets the request through unauth'd.
--   ROLE_USER       the authenticated floor: any valid Casdoor principal holds
--                   it (this is the "public-floor" of /api/auth/** etc.).
--   ROLE_ADMIN      JWT "roles" claim contains admin, or the legacy isAdmin flag.
--   ROLE_MOD        Casdoor 'moderator' group: network-wide Matrix + Mastodon
--                   moderation ONLY. A SIBLING of ROLE_ADMIN, NOT a superset of
--                   it — ROLE_MOD never matches the infra/admin rows
--                   (/api/admin/**, /admin/**, /bff/admin/** stay ROLE_ADMIN),
--                   and there is no route to vault/k8s or observability
--                   (uptrace/grafana/clickhouse have no external gateway route at
--                   all), so default-deny keeps ROLE_MOD off everything else.
--   ROLE_GAMES      Casdoor network-wide sibling, "Games Member". Grants nothing
--                   on its own (no route row keys on it) — it is one INPUT to the
--                   games-namespace-admin gate, never the gate itself.
--   ROLE_GAMES_ADMIN  DERIVED/composite role (membership = ROLE_GAMES intersect
--                   (ROLE_ADMIN union ROLE_MOD), materialized by games-admin-sync;
--                   see manifests/casdoor/init-data-configmap.yaml). It is the
--                   ONLY role on the games-namespace admin rows (/games/api/admin/**
--                   on be-gateway, /games/admin/** on fe-gateway). Because the gate
--                   is a SINGLE allow row keyed on this intersection role, the
--                   OR-of-allow-rows table expresses the required AND of
--                   "games + (admin|mod)": ROLE_GAMES alone or ROLE_ADMIN alone is
--                   default-deny — only the combination reaches the surface.
-- A request is allowed iff the caller holds the role of a matching allow row for
-- THIS gateway; the most specific matching url_pattern wins (admin paths first).
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  -- pki-gateway (id.snapdragon.systems -> Casdoor)
  ('snapdragon-pki-gateway', '/api/auth/**',          'ROLE_USER',      true),  -- public-floor
  ('snapdragon-pki-gateway', '/login/**',             'PUBLIC', true),  -- public
  ('snapdragon-pki-gateway', '/.well-known/**',       'PUBLIC', true),  -- public (OIDC/jwks)

  -- be-gateway (api./matrix./mastodon.snapdragon.systems -> APIs/Matrix/Mastodon)
  -- ROLE_MOD moderation surfaces — MORE SPECIFIC than the ROLE_USER /api/v1/**
  -- floor below, so they win the most-specific match and gate akkoma moderation
  -- to moderators/admins (NOT plain ROLE_USER). ROLE_ADMIN is paired on each so
  -- admins (a superset) keep reaching these moderation surfaces. Matrix admin is
  -- enforced by admin-room membership (tuwunel-admin-sync), not an HTTP surface,
  -- so no /_synapse/admin/** row is needed (Conduit-family exposes none).
  ('snapdragon-be-gateway',  '/api/v1/pleroma/admin/**', 'ROLE_MOD',    true),  -- akkoma moderation REST
  ('snapdragon-be-gateway',  '/api/v1/pleroma/admin/**', 'ROLE_ADMIN',  true),  -- (admins superset)
  ('snapdragon-be-gateway',  '/api/pleroma/admin/**',    'ROLE_MOD',    true),  -- legacy akkoma admin
  ('snapdragon-be-gateway',  '/api/pleroma/admin/**',    'ROLE_ADMIN',  true),  -- (admins superset)
  ('snapdragon-be-gateway',  '/pleroma/admin/**',        'ROLE_MOD',    true),  -- AdminFE assets
  ('snapdragon-be-gateway',  '/pleroma/admin/**',        'ROLE_ADMIN',  true),  -- (admins superset)
  -- ROLE_MOD user-floor mirror — the casdoorAuthoritiesConverter does NOT
  -- auto-grant ROLE_USER to ROLE_MOD principals, so mirror the ROLE_USER rows on
  -- the Matrix/Mastodon surfaces to keep ROLE_MOD self-contained (a moderator can
  -- use Matrix/Mastodon normally without also holding ROLE_USER in Casdoor).
  ('snapdragon-be-gateway',  '/_matrix/**',           'ROLE_MOD',       true),  -- Matrix C-S API (mod floor)
  ('snapdragon-be-gateway',  '/api/v1/**',            'ROLE_MOD',       true),  -- Mastodon REST API (mod floor)
  ('snapdragon-be-gateway',  '/oauth/**',             'ROLE_MOD',       true),  -- Mastodon OAuth (mod floor)
  ('snapdragon-be-gateway',  '/_matrix/**',           'ROLE_USER',      true),  -- Matrix C-S API
  ('snapdragon-be-gateway',  '/api/v1/**',            'ROLE_USER',      true),  -- Mastodon REST API
  ('snapdragon-be-gateway',  '/oauth/**',             'ROLE_USER',      true),  -- Mastodon OAuth
  ('snapdragon-be-gateway',  '/api/admin/**',         'ROLE_ADMIN',     true),  -- snapdragon admin API (NOT ROLE_MOD)
  -- snapdragon-games NAMESPACE admin (games BFF /api/admin/** surface, namespaced
  -- under /games/** so it does NOT collide with the platform /api/admin/** row
  -- above). The requirement is games + (admin|mod): nobody reaches this surface
  -- unless they hold ROLE_GAMES AND (ROLE_ADMIN OR ROLE_MOD). That AND is
  -- materialized in Casdoor as the DERIVED role ROLE_GAMES_ADMIN (membership =
  -- ROLE_GAMES intersect (ROLE_ADMIN union ROLE_MOD), reconciled by games-admin-sync
  -- — see manifests/casdoor/init-data-configmap.yaml). This is the SINGLE allow
  -- row for the surface and keys on ROLE_GAMES_ADMIN ONLY — NOT ROLE_GAMES,
  -- ROLE_ADMIN, or ROLE_MOD individually — so the gateway's OR-of-allow-rows table
  -- still yields the AND, and any single role is default-deny. More specific than
  -- the /api/** ROLE_USER floor, so it wins the most-specific match.
  ('snapdragon-be-gateway',  '/games/api/admin/**',   'ROLE_GAMES_ADMIN', true),  -- games namespace admin API (games + (admin|mod) ONLY)
  -- snapdragon-federation-api module-federation registry/manifest/bundles API. MORE
  -- SPECIFIC than the /api/** floor below, so it wins the most-specific match.
  -- Single ROLE_USER row = the coarse authenticated floor (lets a logged-in
  -- caller reach the manifest + bundles); fine-grained authz (modules/overrides=
  -- ROLE_ADMIN, moderation=ROLE_MOD/ADMIN) is enforced INSIDE federation's
  -- SecurityConfig, NOT mirrored here (the converter does not auto-grant ROLE_USER
  -- to admins/mods, so per-subpath ROLE_ADMIN/ROLE_MOD rows would have to be
  -- duplicated — the single floor row keeps it self-contained, matching /api/**).
  ('snapdragon-be-gateway',  '/api/federation/**',    'ROLE_USER',      true),  -- federation registry/manifest/bundles (authenticated floor; ADMIN/MOD enforced in federation)
  ('snapdragon-be-gateway',  '/api/**',               'ROLE_USER',      true),  -- snapdragon APIs

  -- fe-gateway (snapdragon.systems -> Angular host + MFEs + same-origin /bff)
  ('snapdragon-fe-gateway',  '/',                     'PUBLIC', true),  -- public front page
  ('snapdragon-fe-gateway',  '/social/matrix/**',     'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/social/mastodon/**',   'ROLE_USER',      true),
  -- DB-hosted module-federation FRAGMENT bundles served by the remote-fragment
  -- static fleet (user-profile/card + admin contained-pages). The authenticated
  -- host's loadRemoteModule fetches them; they are content-addressed (non-secret)
  -- bytes and visibility is enforced upstream (federation emits only enabled/
  -- visible modules into its manifest), so the gateway gate is the ROLE_USER floor
  -- (the host itself loads them only after login). If anonymous profile cards are
  -- ever needed, add a sibling PUBLIC row for the public sub-path.
  ('snapdragon-fe-gateway',  '/_fragments/**',        'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/login/**',             'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/admin/**',             'ROLE_ADMIN',     true),
  -- snapdragon-games namespace admin UI (games admin surface, namespaced under
  -- /games/** so it does NOT collide with the platform /admin/** row above). Same
  -- games + (admin|mod) gate: keyed on the DERIVED composite ROLE_GAMES_ADMIN
  -- ONLY (= ROLE_GAMES intersect (ROLE_ADMIN union ROLE_MOD)), so a single role
  -- is default-deny. More specific than /admin/** (different prefix) and self-
  -- contained — the one allow row encodes the AND.
  ('snapdragon-fe-gateway',  '/games/admin/**',       'ROLE_GAMES_ADMIN', true),  -- games namespace admin UI (games + (admin|mod) ONLY)
  ('snapdragon-fe-gateway',  '/bff/login',            'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/register/**',      'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/provision/**',     'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/me/**',            'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/admin/**',         'ROLE_ADMIN',     true)
ON CONFLICT DO NOTHING;
