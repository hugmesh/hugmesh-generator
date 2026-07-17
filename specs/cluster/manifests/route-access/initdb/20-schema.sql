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
    -- Per-row BRAND scope (multi-brand architecture tier). NULL/'default' = applies
    -- to ANY target domain (back-compat: every canonical seed row below leaves it
    -- NULL/unscoped, so single-tenant + the in-image CanonicalSeed floor are
    -- unchanged). The merged gateway (GatewayRouteAccessService.loadFromPostgres +
    -- the Cassandra mirror) now SELECTs this column, and its domainApplies()/
    -- appliesTo() treat NULL/blank/'default' as unscoped; without the column the
    -- deployed gateway's row load fails outright. A per-brand row carries its own
    -- domain so a brand-Y `/api/admin/** -> ROLE_ADMIN` grant can NEVER be
    -- re-granted to a brand-X admin — the gateway filter passes the request's
    -- target domain (derived from Host) and a scoped row only applies to its own
    -- brand. Defense-in-depth alongside the filter's hard-deny on domain mismatch.
    domain       text,
    -- Per-row MFA REQUIREMENT (Casdoor MFA tier — D6/D8). DEFAULT false = INERT:
    -- every canonical seed row below omits this column from its INSERT list, so the
    -- default applies and the deployed posture is BYTE-IDENTICAL until an operator
    -- flips a row to true. This column is the DUAL-WRITE PARTNER of the gateway G4
    -- CanonicalSeed mfa_required field (snapdragon-gateway) + the admin-bff
    -- 001-copy RouteRule/RouteAccessRepository mirror — the merged gateway's
    -- GatewayRouteAccessService.loadFromPostgres SELECTs this column, and
    -- GatewayRouteAccessFilter.decide() (when app.mfa.enabled) requires the
    -- principal to hold MFA_SATISFIED on a matched true row, else 403 fail-closed.
    -- A row with mfa_required=false never gates on MFA, so legacy/single-issuer
    -- tokens with no MFA claim are unaffected = additive. ⚠ MUST merge in LOCKSTEP
    -- with the gateway G4 + admin-bff 001-copy so all three sides SELECT/write the
    -- same column (mirrors the domain-column dual-write idiom directly above).
    mfa_required boolean     NOT NULL DEFAULT false,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- Idempotent add for a table created by an EARLIER (pre-domain) initdb run so an
-- in-place cluster upgrade gains the column the merged gateway now SELECTs.
ALTER TABLE gateway_route_access ADD COLUMN IF NOT EXISTS domain text;
-- Idempotent add (mirrors the domain-column idiom) so an in-place upgrade of a
-- pre-MFA cluster gains the mfa_required column the merged gateway now SELECTs.
-- DEFAULT false keeps every existing row inert (no MFA gate) until an operator
-- flips it — byte-identical to today. Dual-write partner of gateway G4 +
-- admin-bff 001-copy (see the CREATE-TABLE note above).
ALTER TABLE gateway_route_access ADD COLUMN IF NOT EXISTS mfa_required boolean DEFAULT false;
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
  ('snapdragon-pki-gateway', '/**',                   'ROLE_SUPERADMIN', true),  -- headscale control-plane (scale.) catch-all -> SUPERADMIN-only; the 3 specific rows above win by most-specific match (bug #15)

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
  -- ── EXTERNAL-CLIENT (personal-client / native-app) ISSUANCE rows ───────────
  -- Personal native clients (Element/Tusky/Ivory) reach the homeservers ONLY
  -- through the gateway (sole ingress; raw homeserver unreachable per the
  -- NetworkPolicy+mTLS isolation). The token-ISSUANCE sub-paths are gated by the
  -- DEDICATED external-client roles ROLE_MATRIX_EXTERNAL_CLIENT /
  -- ROLE_MASTODON_EXTERNAL_CLIENT (seeded in manifests/casdoor/init-data-configmap.yaml),
  -- which are SEPARATE from the base ROLE_MATRIX/ROLE_MASTODON. Base role =
  -- use-via-OUR-UI (brokered token); external-client role = may register/use a
  -- NATIVE client through the passthrough. Mods/admins grant/revoke the external-
  -- client role; removing it revokes the user's personal-client tokens at the
  -- gateway (HomeserverTokenRevocationFilter, external-client:<localpart>:<platform>,
  -- kind=personal only) WITHOUT touching our-UI access. PARITY with the gateway
  -- CanonicalSeed (snapdragon-gateway). Token-USAGE (/_matrix/**, /api/v1/**,
  -- /api/v2/**) stays gated by the base roles above + the revocation filter.
  --
  -- The brokered mint our BFFs run does NOT traverse these issuance paths: it runs
  -- as an INTERNAL service identity that the GatewayRouteAccessFilter short-circuits
  -- (or via an internal route bypassing this gate), so these external-client rows
  -- govern only genuine native-client issuance traffic and never lock out
  -- ROLE_USER/MOD/ADMIN using OUR UI. Versioned Matrix login variants (v3, r0) are
  -- enumerated explicitly rather than assuming one '*' covers them.
  --   Mastodon issuance: OAuth flow + dynamic app registration.
  ('snapdragon-be-gateway',  '/oauth/**',                 'ROLE_MASTODON_EXTERNAL_CLIENT',  true),  -- Mastodon OAuth (token/authorize) — external client
  ('snapdragon-be-gateway',  '/api/v1/apps',              'ROLE_MASTODON_EXTERNAL_CLIENT',  true),  -- Mastodon app registration — external client
  --   Matrix issuance: client login + device registration (versioned).
  ('snapdragon-be-gateway',  '/_matrix/client/v3/login',  'ROLE_MATRIX_EXTERNAL_CLIENT',    true),  -- Matrix login (v3) — external client
  ('snapdragon-be-gateway',  '/_matrix/client/r0/login',  'ROLE_MATRIX_EXTERNAL_CLIENT',    true),  -- Matrix login (r0) — external client
  ('snapdragon-be-gateway',  '/_matrix/client/v3/register', 'ROLE_MATRIX_EXTERNAL_CLIENT',  true),  -- Matrix register/device (v3) — external client
  ('snapdragon-be-gateway',  '/_matrix/client/r0/register', 'ROLE_MATRIX_EXTERNAL_CLIENT',  true),  -- Matrix register/device (r0) — external client
  -- ── Image-builder console seam (build-distribution) + superadmin infra console ─
  -- PARITY with the merged gateway CanonicalSeed.java (snapdragon-gateway repo).
  -- The mesh-WORKLOAD image-build surface is gated on the GRANTED capability
  -- ROLE_IMAGE_BUILDER (NOT an admin default): an admin reaches it ONLY if
  -- separately granted that role. Do NOT pair ROLE_ADMIN on /bff/image-builds/** —
  -- that would let every per-domain admin build images, breaking the build≠run /
  -- workload-vs-arch boundary. The arch/core build sub-surface + the superadmin
  -- infra console stay SUPERADMIN-only by longest-pattern-match: /bff/image-builds/
  -- arch/** is LONGER than /bff/image-builds/**, so it wins. SUPERADMIN reaches
  -- ordinary admin paths via the gateway cross-domain bypass, so it needs no
  -- per-surface row there.
  ('snapdragon-be-gateway',  '/bff/image-builds/arch/**', 'ROLE_SUPERADMIN',    true),  -- arch/core builds: superadmin only (wins, longer)
  ('snapdragon-be-gateway',  '/bff/image-builds/**',      'ROLE_IMAGE_BUILDER', true),  -- mesh-workload builds: image_builder (admins granted it)
  ('snapdragon-be-gateway',  '/bff/superadmin/**',        'ROLE_SUPERADMIN',    true),  -- superadmin infra console (tailnet)
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
  -- ── OPTIONAL slug `games` — games portal floor on the games.<GAMES_DOMAIN> host ──
  -- The games BFF/portal surface under /games/** (games members reach the portal;
  -- the more-specific /games/api/admin/** row above wins for the admin API). Keyed
  -- on the network-wide ROLE_GAMES access role; a games BAN is role removal ->
  -- governed-but-ungranted -> DENY. ADMIN/MOD paired so they keep reaching it.
  -- ⚠ gate_optional_services REMOVES these rows + the games host route when the
  -- games slug is deselected (see optional-services.yaml games.routeAccessRows).
  ('snapdragon-be-gateway',  '/games/**',             'ROLE_GAMES',     true),  -- games portal floor (games-access)
  ('snapdragon-be-gateway',  '/games/**',             'ROLE_ADMIN',     true),  -- (admins superset)
  ('snapdragon-be-gateway',  '/games/**',             'ROLE_MOD',       true),  -- (mods superset)
  -- ── GAMES APP-STORE (games-services control plane) — admin-bff surfaces ──────────
  -- The per-domain FOSS game-server app-store control plane (catalog + offers +
  -- instances) lives in the admin-bff under /bff/superadmin/games-services/** (global
  -- catalog curation, SUPERADMIN ONLY) and /bff/games-services/** (per-domain
  -- admin/runner instance ops). The admin-bff itself ALSO enforces these via
  -- @PreAuthorize + DomainScope; these gateway rows are the coarse defence-in-depth
  -- (most-specific match wins, ahead of the /bff/admin/** floor). The DERIVED roles
  -- ROLE_GAMES_SERVICES_ADMIN (= ROLE_GAMES_SERVICES ∩ (ROLE_ADMIN ∪ ROLE_MOD)) and
  -- ROLE_GAMES_SERVICES_RUNNER (= ROLE_GAMES_SERVICES ∩ ROLE_MOD) are materialized by
  -- games-services-{admin,runner}-sync (manifests/casdoor); keying a surface on a
  -- single derived role yields the required AND (any single input role is default-deny).
  -- ⚠ gate_optional_services REMOVES these rows when the games slug is deselected
  -- (see optional-services.yaml games.routeAccessRows).
  ('snapdragon-be-gateway',  '/bff/superadmin/games-services/**', 'ROLE_SUPERADMIN', true),  -- global catalog + per-domain offers (SUPERADMIN ONLY)
  ('snapdragon-be-gateway',  '/bff/games-services/instances/**',  'ROLE_GAMES_SERVICES_ADMIN',  true),  -- create/run/stop instances (games-services ∩ (admin|mod))
  ('snapdragon-be-gateway',  '/bff/games-services/instances/**',  'ROLE_GAMES_SERVICES_RUNNER', true),  -- mod-delegated run/stop (games-services ∩ mod)
  ('snapdragon-be-gateway',  '/bff/games-services/catalog/**',    'ROLE_GAMES_SERVICES',        true),  -- read offered catalog (games-services-access floor)
  -- HTTP game consoles, path-routed by be-gateway to per-instance Services (PR7). A
  -- games-services member reaches a running console; admins/mods are supersets.
  ('snapdragon-be-gateway',  '/games/servers/**',     'ROLE_GAMES_SERVICES', true),  -- per-instance HTTP console floor
  ('snapdragon-be-gateway',  '/games/servers/**',     'ROLE_ADMIN',          true),  -- (admins superset)
  ('snapdragon-be-gateway',  '/games/servers/**',     'ROLE_MOD',            true),  -- (mods superset)
  -- ── WORKLOAD CONSOLE (podman/OpenShift-equivalent pod-mgmt + live-log + exec) ──────
  -- The admin-bff surfaces /bff/admin/workloads/** (ADMIN read-only own-domain, grant-gated)
  -- and /bff/superadmin/workloads/** (SUPERADMIN cross-cluster read + RUNTIME_MUTATE/exec/
  -- port-forward/lifecycle). The admin-bff itself is the TOTAL authz predicate (the central
  -- WebFilter: dangerous-tier kill + namespace allowlist + grant + step-up + Lease + device/
  -- SSH-license); these gateway rows are the coarse defence-in-depth, MORE SPECIFIC than the
  -- /bff/admin/** and /bff/superadmin/** floors so they win the most-specific match. The
  -- DANGEROUS surfaces (logs-stream / exec / exec-tty WS / port-forward) are reachable ONLY
  -- over the TAILNET (the superadmin surface is tailnet-only by deployment — same posture as
  -- /bff/superadmin/** infra console). SHIPS DARK: the admin-bff gate
  -- (app.workload-console.enabled) + the DB master flag + an active grant all default off.
  -- ⚠ gate_optional_services REMOVES these rows when the workloadConsole slug is deselected
  -- (see optional-services.yaml workloadConsole.routeAccessRows). DEFAULT: deselected.
  ('snapdragon-be-gateway',  '/bff/superadmin/workloads/**', 'ROLE_SUPERADMIN', true),  -- workload console superadmin (cross-cluster read + mutate/exec/port-forward; tailnet-only)
  ('snapdragon-be-gateway',  '/bff/admin/workloads/**',      'ROLE_ADMIN',      true),  -- workload console admin (read-only own-domain, grant-gated by the BFF)
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
  -- edge-ai inference API (ai.<domain> host route -> Ollama /v1 on the GPU/edge_ai
  -- node). Authenticated floor: any mesh user may call the model API; finer
  -- per-domain gating can add a ROLE_EDGE_AI row (cf. ROLE_OWNCAST). Distinct /v1
  -- path space, so no overlap with /api/**. ⚠ OPTIONAL slug `edge-ai`:
  -- gate_optional_services drops this row when edge-ai is deselected.
  -- edge-ai-analysis task API (/v1/analyze/** -> the analysis wrapper). MORE SPECIFIC
  -- than /v1/** below; same ROLE_USER floor. ⚠ OPTIONAL slug `edge-ai-analysis`:
  -- gate_optional_services drops this row when edge-ai-analysis is deselected.
  ('snapdragon-be-gateway',  '/v1/analyze/**',        'ROLE_USER',      true),  -- edge-ai-analysis verdict API
  -- edge-ai-tts voice synthesis API (/v1/synthesize/** -> the Piper TTS wrapper;
  -- VN voice feature, B3). MORE SPECIFIC than /v1/** below; same ROLE_USER floor.
  -- ⚠ OPTIONAL slug `edge-ai-tts`: gate_optional_services drops this row when
  -- edge-ai-tts is deselected.
  ('snapdragon-be-gateway',  '/v1/synthesize/**',     'ROLE_USER',      true),  -- edge-ai-tts voice synthesis API
  ('snapdragon-be-gateway',  '/v1/**',                'ROLE_USER',      true),  -- edge-ai OpenAI-compatible inference API

  -- fe-gateway (snapdragon.systems -> Angular host + MFEs + same-origin /bff)
  ('snapdragon-fe-gateway',  '/',                     'PUBLIC', true),  -- public front page
  -- The rest of the anonymous SPA shell the '/' row already implies: the
  -- document, the root-level hashed bundles the Angular browser build serves
  -- from the systems-web webroot (Ant '*' does not cross '/', so only webroot
  -- files match), the module-federation manifests, favicon and static assets.
  -- Mirrors the SecurityConfig FE_SHELL_PUBLIC_GET_PATHS floor (GET-only, fe
  -- tier only) so the coarse layer and the route-access layer agree the
  -- anonymous front page is servable. PARITY with the gateway CanonicalSeed
  -- fe() (snapdragon-gateway PR #72) — these rows were added there and were
  -- missing here (dual-write seed drift), this closes that gap.
  ('snapdragon-fe-gateway',  '/index.html',           'PUBLIC', true),  -- public (anon SPA shell doc)
  ('snapdragon-fe-gateway',  '/favicon.ico',          'PUBLIC', true),  -- public (anon SPA shell)
  ('snapdragon-fe-gateway',  '/importmap.json',       'PUBLIC', true),  -- public (module-federation import map)
  ('snapdragon-fe-gateway',  '/remoteEntry.json',     'PUBLIC', true),  -- public (module-federation remote entry)
  ('snapdragon-fe-gateway',  '/*.js',                 'PUBLIC', true),  -- public (webroot hashed JS bundles)
  ('snapdragon-fe-gateway',  '/*.css',                'PUBLIC', true),  -- public (webroot hashed CSS bundles)
  ('snapdragon-fe-gateway',  '/assets/**',            'PUBLIC', true),  -- public (static assets)
  -- Public federation reads (federation-api permitAll's both at the app layer;
  -- the cluster fe spec's vanity-subdomain route documents the gateway-side
  -- allowance as the deferred missing piece): the vanity profile resolve
  -- (path + Host-derived collection resolve) and the install-state
  -- capabilities projection a LOGGED-OUT host shell reads to grey-out
  -- optional services. Scoped to the exact public reads (NOT
  -- /api/federation/**) — the manifest / module-registry / username surfaces
  -- stay gated by the ROLE_USER floor row below. PARITY with the gateway
  -- CanonicalSeed fe() (snapdragon-gateway PR #72).
  ('snapdragon-fe-gateway',  '/api/federation/vanity',       'PUBLIC', true),  -- public (vanity profile/collection resolve)
  ('snapdragon-fe-gateway',  '/api/federation/vanity/**',    'PUBLIC', true),  -- public (vanity profile/collection resolve)
  ('snapdragon-fe-gateway',  '/api/federation/capabilities', 'PUBLIC', true),  -- public (install-state capabilities projection)
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
  -- NATIVE-LOGIN: the login-ui SPA shell is ANONYMOUS (the only login surface now
  -- that Casdoor's hosted page is never browser-exposed; a logged-out visitor holds
  -- no role yet, so ROLE_USER was a chicken-and-egg lock-out). PUBLIC matches the
  -- gateway SecurityConfig FE_SHELL_PUBLIC_GET_PATHS `/login/**`. Pairs with the
  -- `/bff/login` PUBLIC row below.
  ('snapdragon-fe-gateway',  '/login/**',             'PUBLIC',         true),
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
  -- Character Studio (VN) micro-frontend UI (snapdragon-character-studio-ui at
  -- /character-studio/**). Authenticated floor — any logged-in principal reaches it.
  -- ⚠ gate_optional_services REMOVES this row when the character-studio slug is
  -- deselected (so a matched route to a pruned upstream cannot stale-grant / 502).
  ('snapdragon-fe-gateway',  '/character-studio/**',  'ROLE_USER',      true),  -- character-studio VN UI
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
  -- GAMES APP-STORE operator UI (the admin-ui federated remote at /admin/games-services,
  -- PR8). Keyed on the DERIVED ROLE_GAMES_SERVICES_ADMIN ONLY (= ROLE_GAMES_SERVICES ∩
  -- (ROLE_ADMIN ∪ ROLE_MOD)), so a single role is default-deny — the one allow row
  -- encodes the AND. The RUNNER (mod) reaches the same operator UI for run/stop; the UI
  -- greys-out create/enable for a runner (the BFF authz is the real gate). More specific
  -- than the /admin/** floor (longer prefix). ⚠ gate_optional_services REMOVES this row
  -- when the games slug is deselected.
  ('snapdragon-fe-gateway',  '/admin/games-services/**', 'ROLE_GAMES_SERVICES_ADMIN',  true),  -- games app-store operator UI (games-services ∩ (admin|mod))
  ('snapdragon-fe-gateway',  '/admin/games-services/**', 'ROLE_GAMES_SERVICES_RUNNER', true),  -- runner reaches the operator UI for run/stop (BFF greys-out create)
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
  -- PUBLIC appeal-contact resolver for the login-ui appeal page shown to a
  -- banned/suspended (or logged-out) user (admin-bff GET /bff/public/appeal-contact
  -- -> permitAll, returns {"email":"..."}, no PII). Reached BEFORE a Casdoor JWT
  -- exists, so it must pass the gateway unauth'd. Mirrors the gateway CanonicalSeed
  -- fe() row + SecurityConfig PUBLIC_PATHS (snapdragon-gateway PR #22). EXACT path
  -- (not /bff/public/**) so most-specific-match keeps ONLY this resolver anonymous.
  ('snapdragon-fe-gateway',  '/bff/public/appeal-contact', 'PUBLIC', true),  -- public appeal-contact resolver (UNAUTHENTICATED)
  -- NATIVE-LOGIN credential submit (UNAUTHENTICATED): the anonymous browser POSTs
  -- {username,password} from OUR login-ui form to /bff/login BEFORE it holds any
  -- session/role; user-bff drives Casdoor /api/login server-side and mints the opaque
  -- bff_ session (no token reaches the browser). PUBLIC matches the gateway
  -- SecurityConfig PUBLIC_PATHS `/bff/login`; ROLE_USER was a chicken-and-egg lock-out.
  ('snapdragon-fe-gateway',  '/bff/login',            'PUBLIC',         true),
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
  ('snapdragon-fe-gateway',  '/bff/forum/**',             'ROLE_FORUM',     true),  -- forum BFF (forum-access floor)
  -- Wiki BFF (/bff/wiki/** -> snapdragon-wiki-bff-api), the SINGLE browser->wiki
  -- path. SIBLING of /bff/forum/** + /bff/mod/** above. Most-specific match wins:
  --   /bff/wiki/admin/**  = ROLE_ADMIN  (admin-only seam: wiki-config, content-admin
  --                         ops; gated ROLE_ADMIN end-to-end — admins reach this
  --                         WITHOUT ROLE_WIKI, so DO NOT pair ROLE_WIKI here)
  --   /bff/wiki/**        = ROLE_WIKI   (wiki-access floor; granted by admin)
  -- Do NOT pair ROLE_ADMIN on the ROLE_WIKI floor row: the gateway admin-bypass
  -- already passes admins through; pairing ROLE_ADMIN would incorrectly expose
  -- every wiki-floor endpoint to admins who have not been granted wiki access.
  ('snapdragon-fe-gateway',  '/bff/wiki/admin/**',  'ROLE_ADMIN', true),  -- wiki admin-console seam (admin-only, end-to-end)
  ('snapdragon-fe-gateway',  '/bff/wiki/**',        'ROLE_WIKI',  true),  -- wiki BFF (wiki-access floor)
  -- Owncast BFF (/bff/owncast/** -> snapdragon-owncast-bff-api). Admins reach
  -- /bff/owncast/admin/** for per-user broadcast grants; ROLE_OWNCAST holders
  -- (granted by admin) reach the user-facing console.
  ('snapdragon-fe-gateway',  '/bff/owncast/admin/**',  'ROLE_ADMIN',   true),  -- owncast admin grant surface
  ('snapdragon-fe-gateway',  '/bff/owncast/**',        'ROLE_OWNCAST', true),  -- owncast user console
  -- Tube BFF (/bff/tube/** -> snapdragon-tube-bff-api) + media serving
  -- (/tube/content/** -> tube-media Nginx, signed-URL-gated).
  -- ROLE_TUBE = "may use LocalTube" (granted by admin). The media row sits on
  -- be-gateway (same role) so the HMAC-signed URL check + owner two-wall in
  -- tube-bff are the domain enforcement; the gateway only checks role.
  ('snapdragon-fe-gateway',  '/bff/tube/**',          'ROLE_TUBE',    true),  -- tube BFF (tube-access floor)
  ('snapdragon-be-gateway',  '/tube/content/**',       'ROLE_TUBE',    true),  -- tube media serving (signed URL)
  -- ── Wiki / Owncast / Tube UI MOUNT rows (pre-existing gap, filled here) ─────
  -- The wiki-ui/owncast-ui/tube-ui repos' own Dockerfiles document the intended
  -- gateway gate ("Serves on :8080 to MATCH the federation-api <slug> module
  -- registration... reachable only behind the gateway's /<slug>=ROLE_<SLUG>
  -- route-access gate") but no row for the UI's OWN mount path (as opposed to its
  -- BFF's /bff/<slug>/** path above) was ever added to this canonical seed — only
  -- the BFF rows existed. Congruent with the /admin/**, /mod/**, /user/**,
  -- /character-studio/** UI-mount rows above: same non-ROLE_ADMIN-paired floor
  -- convention as /social/forum/** (admins reach it via the gateway admin-bypass,
  -- so do NOT pair ROLE_ADMIN here either). Reuses the SAME roles already granted
  -- to the sibling /bff/wiki/**, /bff/owncast/**, /bff/tube/** rows above — no new
  -- role invented. Harmless additively in the cluster too: no SCG route currently
  -- points at /wiki/**, /owncast/**, /tube/** in apps/20-gateway-fe.yaml, so the
  -- row simply goes unmatched there until/unless such a route is added; it takes
  -- effect where the local compose gateway-routes/fe/application-routes.yml DOES
  -- add the matching direct-path route (mirroring the mod-ui/user-ui local
  -- convenience routes).
  ('snapdragon-fe-gateway',  '/wiki/**',              'ROLE_WIKI',    true),  -- wiki UI (wiki-access floor)
  ('snapdragon-fe-gateway',  '/owncast/**',           'ROLE_OWNCAST', true),  -- owncast UI (owncast-access floor)
  ('snapdragon-fe-gateway',  '/tube/**',              'ROLE_TUBE',    true),  -- tube UI (tube-access floor)
  -- ── SUPERADMIN APP-STORE — TAILNET-ONLY superadmin-gateway (snapdragon-superadmin-
  -- appstore design, V6) ──────────────────────────────────────────────────────────
  -- The superadmin infra control plane is served by its OWN gateway
  -- (snapdragon-superadmin-gateway, apps/22-gateway-superadmin.yaml) on the
  -- nginx-internal class on the pki node — TAILNET-ONLY, off every public-ingress
  -- gateway, with NO be-gateway forward of the superadmin host. These are the
  -- gateway-NAME-scoped ROLE_SUPERADMIN floor rows (lock #2 of the three tailnet
  -- locks: network NetworkPolicy + these rows + the Angular superadminGuard).
  --
  -- NOTE the existing be-gateway '/bff/superadmin/**' -> ROLE_SUPERADMIN row above
  -- is RETAINED (it also fronts the merged games-services superadmin surface
  -- /bff/superadmin/games-services/** and is itself ROLE_SUPERADMIN-gated); adding
  -- the superadmin-gateway is ADDITIVE — it does not remove that row. The NEW
  -- App-Store CONSOLE path is reachable ONLY via the tailnet superadmin-gateway.
  ('snapdragon-superadmin-gateway', '/bff/superadmin/**',        'ROLE_SUPERADMIN', true),  -- App-Store BFF control plane (tailnet)
  ('snapdragon-superadmin-gateway', '/superadmin/service-catalog/**', 'ROLE_SUPERADMIN', true),  -- service-catalog-ui federated remote (tailnet)
  ('snapdragon-superadmin-gateway', '/api/federation/**',        'ROLE_SUPERADMIN', true),  -- federation manifest/bundles for the superadmin shell (tailnet)
  -- ── Headwind MDM (Enterprise Phones) — DEFAULT-OFF optional-service `headwind`,
  -- rides the EXISTING tailnet superadmin-gateway (no gatewayHost of its own).
  -- Console = human JSP UI, gated ROLE_SUPERADMIN like every other row on this
  -- gateway. Check-in = device MQTT-push/REST surface: network-locked (this
  -- gateway is tailnet-only end-to-end) but role='PUBLIC' so the Casdoor JWT
  -- check is SKIPPED — Headwind's own per-device enrollment token is the real
  -- authenticator for this path. A route with ZERO matching allow rows is
  -- default-deny, so this row is REQUIRED (not "omit to make it public").
  -- ⚠ gate_optional_services REMOVES both rows when the headwind slug is
  -- deselected (see optional-services.yaml headwind.routeAccessRows).
  ('snapdragon-superadmin-gateway', '/hmdm/manage/**',           'ROLE_SUPERADMIN', true),  -- Headwind MDM human console (tailnet, JSP — no Angular guard)
  ('snapdragon-superadmin-gateway', '/hmdm/rest/**',              'PUBLIC',           true)   -- Headwind device check-in/push (network-locked; Headwind's own device token, not Casdoor)
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
  -- The TAILNET superadmin-gateway's own read-only rule loader.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superadmin_gateway') THEN
    GRANT SELECT ON gateway_route_access TO superadmin_gateway;
  END IF;
END
$$;

-- gen_random_uuid() default needs no sequence; there is no SERIAL column here, so
-- no sequence GRANTs are required. If a future migration adds a sequence, grant
-- USAGE on it to admin_bff (writer) explicitly.
