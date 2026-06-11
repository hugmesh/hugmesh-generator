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
  -- ROLE_MOD moderation surfaces — MORE SPECIFIC than the ROLE_MASTODON /api/v1/**
  -- platform-access floor below, so they win the most-specific match and gate
  -- akkoma moderation to moderators/admins (NOT plain ROLE_MASTODON). ROLE_ADMIN is
  -- paired on each so admins (a superset) keep reaching these moderation surfaces.
  -- Matrix admin is enforced by admin-room membership (tuwunel-admin-sync), not an
  -- HTTP surface, so no /_synapse/admin/** row is needed (Conduit-family exposes none).
  ('snapdragon-be-gateway',  '/api/v1/pleroma/admin/**', 'ROLE_MOD',    true),  -- akkoma moderation REST
  ('snapdragon-be-gateway',  '/api/v1/pleroma/admin/**', 'ROLE_ADMIN',  true),  -- (admins superset)
  ('snapdragon-be-gateway',  '/api/pleroma/admin/**',    'ROLE_MOD',    true),  -- legacy akkoma admin
  ('snapdragon-be-gateway',  '/api/pleroma/admin/**',    'ROLE_ADMIN',  true),  -- (admins superset)
  ('snapdragon-be-gateway',  '/pleroma/admin/**',        'ROLE_MOD',    true),  -- AdminFE assets
  ('snapdragon-be-gateway',  '/pleroma/admin/**',        'ROLE_ADMIN',  true),  -- (admins superset)
  -- ── PER-PLATFORM ACCESS roles (ban/congruence foundation) ─────────────────
  -- The homeserver client surfaces are now gated by the per-PLATFORM access roles
  -- ROLE_MATRIX / ROLE_MASTODON (seeded in manifests/casdoor/init-data-configmap.yaml),
  -- NOT the broad ROLE_USER floor. Holding ROLE_USER alone no longer reaches Matrix
  -- or Mastodon — a principal must hold the matching platform role. A platform BAN
  -- is the ABSENCE of the role: removal makes every allow-predicate here false, so
  -- the path becomes governed-but-ungranted -> DENY (no allow=false / ban row).
  -- ADMIN/MOD remain a superset (paired on each row) because the
  -- casdoorAuthoritiesConverter does NOT auto-grant the platform roles to them.
  --
  -- ⚠️ The broad ROLE_USER homeserver rows ( /_matrix/**, /api/v1/**, /oauth/** )
  -- and the bare ROLE_MOD floor rows that used to live here were REMOVED at this
  -- flip. DEPLOY-TOGETHER with the Casdoor seed+BACKFILL: every current homeserver
  -- holder must be granted ROLE_MATRIX/ROLE_MASTODON BEFORE this row set reaches a
  -- live cluster, or they lock out (see init-data-configmap.yaml deploy note).
  --
  -- Matrix client surface: /_matrix/** + the spec-required /.well-known/matrix/**
  -- delegation + /_synapse/** (host-scoped catch-all on the matrix host so the
  -- broader /api/** ROLE_USER floor below can never win the most-specific match on
  -- a matrix-host request that lacks an /_matrix prefix).
  ('snapdragon-be-gateway',  '/_matrix/**',               'ROLE_MATRIX',   true),  -- Matrix C-S API
  ('snapdragon-be-gateway',  '/_matrix/**',               'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/_matrix/**',               'ROLE_ADMIN',    true),  -- (admin superset)
  ('snapdragon-be-gateway',  '/.well-known/matrix/**',    'ROLE_MATRIX',   true),  -- Matrix client/server discovery
  ('snapdragon-be-gateway',  '/.well-known/matrix/**',    'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/.well-known/matrix/**',    'ROLE_ADMIN',    true),  -- (admin superset)
  ('snapdragon-be-gateway',  '/_synapse/**',              'ROLE_MATRIX',   true),  -- Synapse-compat surface (host-scoped)
  ('snapdragon-be-gateway',  '/_synapse/**',              'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/_synapse/**',              'ROLE_ADMIN',    true),  -- (admin superset)
  -- Mastodon client surface: /api/v1/** + /api/v2/** + /oauth/** + media/streaming
  -- (the host-scoped catch-alls so the /api/** ROLE_USER floor never wins on a
  -- mastodon-host request).
  ('snapdragon-be-gateway',  '/api/v1/**',                'ROLE_MASTODON', true),  -- Mastodon REST API v1
  ('snapdragon-be-gateway',  '/api/v1/**',                'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/api/v1/**',                'ROLE_ADMIN',    true),  -- (admin superset)
  ('snapdragon-be-gateway',  '/api/v2/**',                'ROLE_MASTODON', true),  -- Mastodon REST API v2
  ('snapdragon-be-gateway',  '/api/v2/**',                'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/api/v2/**',                'ROLE_ADMIN',    true),  -- (admin superset)
  ('snapdragon-be-gateway',  '/oauth/**',                 'ROLE_MASTODON', true),  -- Mastodon OAuth
  ('snapdragon-be-gateway',  '/oauth/**',                 'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/oauth/**',                 'ROLE_ADMIN',    true),  -- (admin superset)
  ('snapdragon-be-gateway',  '/media/**',                 'ROLE_MASTODON', true),  -- Mastodon media
  ('snapdragon-be-gateway',  '/media/**',                 'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/media/**',                 'ROLE_ADMIN',    true),  -- (admin superset)
  ('snapdragon-be-gateway',  '/api/v1/streaming/**',      'ROLE_MASTODON', true),  -- Mastodon streaming
  ('snapdragon-be-gateway',  '/api/v1/streaming/**',      'ROLE_MOD',      true),  -- (mod superset)
  ('snapdragon-be-gateway',  '/api/v1/streaming/**',      'ROLE_ADMIN',    true),  -- (admin superset)
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
  -- Forum admin-console seam on the api host (admin-bff -> forum-bff, if exposed
  -- on the be-gateway). ADMIN-only, MORE SPECIFIC than the /api/** floor so it wins
  -- the most-specific match. There is NO /api/forum/** floor row for phpBB itself —
  -- phpBB is backend-only and has NO be-gateway route (it is reachable ONLY as
  -- forum-bff's in-cluster upstream inside the snapdragon-forum default-deny ns).
  ('snapdragon-be-gateway',  '/api/forum/admin/**',   'ROLE_ADMIN',     true),  -- forum admin seam (admin-only; NO phpbb floor row)
  ('snapdragon-be-gateway',  '/api/**',               'ROLE_USER',      true),  -- snapdragon APIs

  -- fe-gateway (snapdragon.systems -> Angular host + MFEs + same-origin /bff)
  ('snapdragon-fe-gateway',  '/',                     'PUBLIC', true),  -- public front page
  ('snapdragon-fe-gateway',  '/social/matrix/**',     'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/social/mastodon/**',   'ROLE_USER',      true),
  -- phpBB forum micro-frontend UI (snapdragon-forum-ui at /social/forum/**),
  -- served at the apex PATH (NOT a forum. subdomain — the *.snapdragon.systems
  -- vanity wildcard would swallow forum.<domain>). Gated by the dedicated forum
  -- ACCESS role ROLE_FORUM (the new Casdoor forum-access role) — congruent with
  -- how /social/matrix + /social/mastodon gate the social shells, and the model
  -- ban-by-role-removal uses (drop ROLE_FORUM -> this row default-denies on the
  -- next refresh). Admins reach it via the gateway admin-bypass (the converter does
  -- NOT grant admins ROLE_FORUM), so do NOT pair ROLE_ADMIN here — matching the
  -- matrix/mastodon floors which pair no ROLE_ADMIN. The phpBB pod itself has NO
  -- route row (backend-only, isolated in snapdragon-forum).
  ('snapdragon-fe-gateway',  '/social/forum/**',      'ROLE_FORUM',     true),  -- phpBB forum UI (forum-access floor)
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
  -- Moderation micro-frontend UI (snapdragon-mod-ui at /mod/**). ROLE_MOD floor;
  -- ROLE_ADMIN paired so admins (a superset that the converter does NOT
  -- auto-grant ROLE_MOD/USER to) keep reaching the moderation UI. More specific
  -- than the /** front-page catch-all, so it wins the most-specific match.
  ('snapdragon-fe-gateway',  '/mod/**',               'ROLE_MOD',       true),  -- moderation UI (mod floor)
  ('snapdragon-fe-gateway',  '/mod/**',               'ROLE_ADMIN',     true),  -- (admins superset)
  -- Self-service user micro-frontend UI (snapdragon-user-ui at /user/**). The
  -- authenticated floor — any logged-in principal reaches their own profile/prefs.
  ('snapdragon-fe-gateway',  '/user/**',              'ROLE_USER',      true),  -- user self-service UI
  -- API documentation micro-frontend UI (snapdragon-api-docs at /apidocs/**).
  -- ROLE_ADMIN only — the rendered OpenAPI/spec docs are admin-gated, matching
  -- federation's spec floor (its swagger-ui is ROLE_ADMIN).
  ('snapdragon-fe-gateway',  '/apidocs/**',           'ROLE_ADMIN',     true),  -- API docs UI (admin only)
  -- snapdragon-games namespace admin UI (games admin surface, namespaced under
  -- /games/** so it does NOT collide with the platform /admin/** row above). Same
  -- games + (admin|mod) gate: keyed on the DERIVED composite ROLE_GAMES_ADMIN
  -- ONLY (= ROLE_GAMES intersect (ROLE_ADMIN union ROLE_MOD)), so a single role
  -- is default-deny. More specific than /admin/** (different prefix) and self-
  -- contained — the one allow row encodes the AND.
  ('snapdragon-fe-gateway',  '/games/admin/**',       'ROLE_GAMES_ADMIN', true),  -- games namespace admin UI (games + (admin|mod) ONLY)
  -- PUBLIC announcements read surface for the anonymous LOGIN page banner
  -- (admin-bff GET /bff/public/announcements/login -> permitAll, see the admin-bff
  -- SecurityConfig + the shared announcements API contract). The login page is
  -- shown BEFORE a Casdoor JWT exists, so this read path must pass the gateway
  -- unauth'd — mirror the front-page '/' PUBLIC row. More SPECIFIC than the
  -- /bff/login + /bff/admin/** etc. ROLE_USER/ROLE_ADMIN rows below (distinct
  -- /bff/public/ prefix), so most-specific-match keeps it anonymous WITHOUT
  -- opening any other /bff/** subpath. Anonymous body_html is sanitized
  -- server-side at write + rendered in a sandboxed srcdoc iframe by the UI.
  ('snapdragon-fe-gateway',  '/bff/public/announcements/**', 'PUBLIC', true),  -- public login-page announcements (UNAUTHENTICATED)
  ('snapdragon-fe-gateway',  '/bff/login',            'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/register/**',      'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/provision/**',     'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/me/**',            'ROLE_USER',      true),
  ('snapdragon-fe-gateway',  '/bff/admin/**',         'ROLE_ADMIN',     true),
  -- Same-origin role BFFs (fe-gateway proxies /bff/** subpaths to the dedicated
  -- BFFs in the backend ns). The /bff/mod/** + /bff/user/** prefixes are SIBLINGS
  -- of /bff/admin/** above (non-overlapping prefixes), each gated to its own role
  -- floor. /bff/mod/** pairs ROLE_ADMIN so admins (a superset the converter does
  -- NOT auto-grant ROLE_MOD/USER to) keep reaching the moderation BFF.
  ('snapdragon-fe-gateway',  '/bff/mod/**',           'ROLE_MOD',       true),  -- moderation BFF (mod floor)
  ('snapdragon-fe-gateway',  '/bff/mod/**',           'ROLE_ADMIN',     true),  -- (admins superset)
  ('snapdragon-fe-gateway',  '/bff/user/**',          'ROLE_USER',      true),  -- user self-service BFF
  -- Forum BFF (/bff/forum/** -> snapdragon-forum-bff-api), the SINGLE
  -- browser->phpBB path. SIBLING of /bff/mod/** + /bff/user/** above. Most-specific
  -- match wins, so the subpaths are gated tighter than the floor:
  --   /bff/forum/admin/**      = ROLE_ADMIN      (the admin-console seam admin-bff
  --                              calls; admins reach it via the bypass WITHOUT
  --                              ROLE_FORUM, so it is gated ROLE_ADMIN end-to-end)
  --   /bff/forum/moderation/** = ROLE_FORUM_MOD  (the DERIVED composite role =
  --                              ROLE_MOD intersect ROLE_FORUM, materialized in
  --                              Casdoor by the forum reconcile Job — the gateway's
  --                              OR-of-allow table cannot express MOD AND FORUM, so
  --                              this single derived-role row encodes the AND, like
  --                              ROLE_GAMES_ADMIN. A plain ROLE_MOD WITHOUT the
  --                              forum role is default-deny here.)
  --   /bff/forum/**            = ROLE_FORUM      (the forum-access floor)
  -- Do NOT pair ROLE_ADMIN on the ROLE_FORUM / ROLE_FORUM_MOD floor rows: the
  -- gateway admin-bypass already lets admins through, and the matrix/mastodon seed
  -- pairs only its non-admin floors (never ROLE_ADMIN). ROLE_ADMIN stays only on
  -- the genuinely admin-only /bff/forum/admin/** row.
  ('snapdragon-fe-gateway',  '/bff/forum/admin/**',       'ROLE_ADMIN',     true),  -- forum admin-console seam (admin-only, end-to-end)
  ('snapdragon-fe-gateway',  '/bff/forum/moderation/**',  'ROLE_FORUM_MOD', true),  -- forum moderation (derived MOD ∩ FORUM)
  ('snapdragon-fe-gateway',  '/bff/forum/**',             'ROLE_FORUM',     true)   -- forum BFF (forum-access floor)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-machine-user LEAST-PRIVILEGE grants. The login roles are created in
-- 10-roles.sh (which runs first in the CLUSTER initdb); the table exists now, so
-- grant exactly the privileges each consumer needs and nothing more:
--   admin-bff   = the ONLY writer (CRUD)          -> SELECT/INSERT/UPDATE/DELETE
--   *-gateway   = read-only rule loaders          -> SELECT
-- No role gets DDL/owner rights: the table is owned by the "gateway" owner role
-- (POSTGRES_USER), which the admin-bff uses for its DDL/migration path only.
--
-- GUARDED on role existence so this same file is reusable in the LOCAL DEV stack
-- (tests/stack/compose.local.yaml), which mounts ONLY this DDL and connects as the
-- owner `gateway` — the per-user roles do not exist there, so the grants are
-- simply skipped instead of erroring out initdb.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_bff') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON gateway_route_access TO admin_bff;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pki_gateway') THEN
    GRANT SELECT ON gateway_route_access TO pki_gateway;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'be_gateway') THEN
    GRANT SELECT ON gateway_route_access TO be_gateway;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fe_gateway') THEN
    GRANT SELECT ON gateway_route_access TO fe_gateway;
  END IF;
END
$$;

-- gen_random_uuid() default needs no sequence; there is no SERIAL column here, so
-- no sequence GRANTs are required. If a future migration adds a sequence, grant
-- USAGE on it to admin_bff (writer) explicitly.
