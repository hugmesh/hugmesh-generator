// rbac-roles.ts — the SYSTEMS-side role/user catalogue the RBAC specs iterate.
//
// This is the systems analogue of snapdragon.games/e2e/tests/helpers/roles.ts
// SEED_USERS: a single authoritative list of seed identities + the Casdoor roles
// each one holds, in the SYSTEMS realm (org "snapdragon", issuer
// id.snapdragon.systems). The specs drive a per-role test matrix off this list
// instead of hard-coding strings in each `test.describe` body, so adding a role
// is a one-line change here and the assertions follow.
//
// The role names mirror manifests/casdoor/init-data-configmap.yaml + the
// gateway_route_access seed (manifests/route-access/schema.sql). Crucially:
//
//   * ROLE_GAMES_ADMIN is NEVER granted directly. It is a DERIVED/composite role
//     materialized by manifests/casdoor/games-admin-sync-job.yaml as
//         ROLE_GAMES_ADMIN = ROLE_GAMES INTERSECT (ROLE_ADMIN UNION ROLE_MOD).
//     So `e2e-gamesadmin` holds ROLE_GAMES + ROLE_ADMIN and EARNS the derived
//     role via the sync job; `e2e-gamesonly` (ROLE_GAMES only) and
//     `e2e-adminonly` (ROLE_ADMIN only) must NOT earn it (default-deny). The
//     `expectGamesAdmin` flag is what the gate specs assert against.
//
//   * ROLE_MOD is a SIBLING of ROLE_ADMIN, not a superset: it reaches Matrix /
//     Mastodon (akkoma) moderation but is DENIED /admin, /api/admin, /bff/admin,
//     infra, logs, server-admin (default-deny everywhere else).
//
//   * `e2e-pending` holds NO roles and is NOT registration-complete — the
//     two-stage registration gate must keep it out of every user surface until
//     an admin approves it.
//
// Password resolution mirrors the games harness: per-user env override
// (E2E_<UPPER>_PASSWORD) -> shared E2E_PASSWORD -> 'e2e-pass'. seed-accounts.sh
// --roles renders the matching systems Casdoor init payload with the same
// deterministic passwords so a real-Casdoor login carries the right `roles`
// claim; the mock stack (mock-bff) reads the same catalogue for its role grants.

export type SystemsRole =
  | 'ROLE_SUPERADMIN'  // infra control-plane tier; ABOVE admin. Reaches the tailnet-only
                       // superadmin-gateway (snapdragon-superadmin-gateway) Service Catalog/console
                       // surface. NOT a superset that auto-grants admin: it is its OWN ROLE_*.
  | 'ROLE_ADMIN'
  | 'ROLE_MOD'
  | 'ROLE_GAMES'
  | 'ROLE_GAMES_ADMIN'   // DERIVED — never seeded directly; listed only as an expectation
  | 'ROLE_MATRIX'                    // per-platform ACCESS role (use Matrix via OUR UI)
  | 'ROLE_MASTODON'                  // per-platform ACCESS role (use Mastodon via OUR UI)
  | 'ROLE_MATRIX_EXTERNAL_CLIENT'    // may register/use own native Matrix client (gateway passthrough)
  | 'ROLE_MASTODON_EXTERNAL_CLIENT'  // may register/use own native Mastodon client
  | 'ROLE_MATRIX_DOMAINLOCKED'       // forced local-only: Matrix federation blocked for this user
  | 'ROLE_MASTODON_DOMAINLOCKED'     // forced local-only: Mastodon (akkoma) federation blocked
  | 'ROLE_FORUM'                     // forum (phpBB) ACCESS role
  | 'ROLE_USER';

export interface SystemsSeedUser {
  /** Casdoor username in org "snapdragon" (also the login handle). */
  username: string;
  /** Per-user password env var; falls back to E2E_PASSWORD then 'e2e-pass'. */
  passwordEnv: string;
  /** Roles GRANTED directly in the systems Casdoor seed (NOT the derived role). */
  roles: SystemsRole[];
  /** Whether the games-admin-sync job should compute this user INTO
   *  ROLE_GAMES_ADMIN ( = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD) ). The games-admin
   *  gate specs assert reach to /games/admin/** iff this is true. */
  expectGamesAdmin: boolean;
  /** Registration-complete? `false` models the awaiting-approval pending user. */
  registrationComplete: boolean;
  /** When this user is a domain-locked CONTROL or SUBJECT for the local-only
   *  non-federation e2e (specs 19-23): which platform the lock is asserted on.
   *  `undefined` for non-federation-test users. The matching DOMAINLOCKED role is
   *  in `roles`; the federation-liveness CONTROL users (e2e-matrix / e2e-mastodon)
   *  set this WITHOUT the domainlocked role (they MUST federate). */
  federationProbe?: 'matrix' | 'mastodon';
  /** True for the federating CONTROL user in the non-federation proof: it holds
   *  the base ROLE_MATRIX/ROLE_MASTODON but NOT the domainlocked role, so its post
   *  MUST reach the peer (the positive control / the clock). */
  federationControl?: boolean;
  /** A pinned (role, route, expect) DENY triple for the single-role-DENIED user,
   *  so the deny is reproducible rather than "something 403s somewhere". */
  pinnedDeny?: { route: string; expectStatus: number; reason: string };
  /** One-line note used in spec titles + the user matrix. */
  note: string;
}

export const SYSTEMS_SEED_USERS: SystemsSeedUser[] = [
  {
    username: 'e2e-superadmin',
    passwordEnv: 'E2E_SUPERADMIN_PASSWORD',
    // ROLE_SUPERADMIN is its OWN tier — it does NOT carry ROLE_ADMIN. The
    // superadmin-gateway routes are keyed on ROLE_SUPERADMIN alone (schema.sql
    // 20-schema.sql), so the tier is asserted purely on that role. We do NOT
    // grant ROLE_ADMIN here so the DENY-down-cascade (admin cannot reach
    // superadmin) is provable without role bleed.
    roles: ['ROLE_SUPERADMIN'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'Infra superadmin — reaches the tailnet-only snapdragon-superadmin-gateway Service Catalog/console (/bff/superadmin/**, /superadmin/service-catalog/**, /api/federation/**); ADMIN must NOT reach these.',
  },
  {
    username: 'e2e-admin',
    passwordEnv: 'E2E_ADMIN_PASSWORD',
    roles: ['ROLE_ADMIN', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'Platform admin — reaches /admin, /api/admin, /bff/admin + infra/observability views.',
  },
  {
    username: 'e2e-mod',
    passwordEnv: 'E2E_MOD_PASSWORD',
    roles: ['ROLE_MOD'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'Network moderator — Matrix PL50 + akkoma/Mastodon moderation ONLY; DENIED infra/logs/server-admin/admin-API.',
  },
  {
    username: 'e2e-gamesadmin',
    passwordEnv: 'E2E_GAMESADMIN_PASSWORD',
    // ROLE_GAMES + ROLE_ADMIN -> the intersection job materializes ROLE_GAMES_ADMIN.
    roles: ['ROLE_GAMES', 'ROLE_ADMIN', 'ROLE_USER'],
    expectGamesAdmin: true,
    registrationComplete: true,
    note: 'Games namespace admin — ROLE_GAMES ∩ ROLE_ADMIN earns derived ROLE_GAMES_ADMIN; reaches /games/admin/**.',
  },
  {
    username: 'e2e-gamesonly',
    passwordEnv: 'E2E_GAMESONLY_PASSWORD',
    roles: ['ROLE_GAMES', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'ROLE_GAMES only — must be DENIED /games/admin/** (games without admin|mod ≠ games-admin).',
  },
  {
    username: 'e2e-adminonly',
    passwordEnv: 'E2E_ADMINONLY_PASSWORD',
    roles: ['ROLE_ADMIN', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'ROLE_ADMIN only (no ROLE_GAMES) — must be DENIED /games/admin/** (admin without games ≠ games-admin).',
  },
  {
    username: 'e2e-user',
    passwordEnv: 'E2E_USER_PASSWORD',
    roles: ['ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    // NOTE (commit 0100d3b, 2026-06-10): the broad ROLE_USER homeserver floor for
    // /_matrix/**, /api/v1/**, /oauth/** (+ /.well-known/matrix/**, /_synapse/**,
    // /api/v2/**, /media/**, /api/v1/streaming/**) was REMOVED from schema.sql and
    // replaced by the per-platform ROLE_MATRIX/ROLE_MASTODON access roles. A plain
    // ROLE_USER no longer reaches the Matrix/Mastodon homeserver BACKEND — see
    // e2e-matrix / e2e-mastodon below for that.
    note: 'Plain member — reaches the login/social-shell UI + its own profile; DENIED the Matrix/Mastodon homeserver backend (needs ROLE_MATRIX/ROLE_MASTODON) and every admin/mod/games-admin route.',
  },

  // ── per-platform ACCESS roles (use Matrix/Mastodon via OUR UI) ──────────
  {
    username: 'e2e-matrix',
    passwordEnv: 'E2E_MATRIX_PASSWORD',
    roles: ['ROLE_MATRIX', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    federationProbe: 'matrix',
    federationControl: true,
    note: 'Matrix access (NOT domain-locked) — the federating CONTROL user: its events MUST reach the peer (positive control for spec 20).',
  },
  {
    username: 'e2e-mastodon',
    passwordEnv: 'E2E_MASTODON_PASSWORD',
    roles: ['ROLE_MASTODON', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    federationProbe: 'mastodon',
    federationControl: true,
    note: 'Mastodon access (NOT domain-locked) — the federating CONTROL user: its toot MUST reach the peer (positive control for specs 19/22).',
  },

  // ── DOMAIN-LOCKED roles (forced local-only; subject of the non-federation proof) ─
  {
    username: 'e2e-matrix-domainlocked',
    passwordEnv: 'E2E_MATRIX_DOMAINLOCKED_PASSWORD',
    roles: ['ROLE_MATRIX', 'ROLE_MATRIX_DOMAINLOCKED', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    federationProbe: 'matrix',
    note: 'Matrix domain-locked — cross-server create/join/invite blocked at gateway+egress; a remote room/event must NOT reach the peer (spec 20).',
  },
  {
    username: 'e2e-mastodon-domainlocked',
    passwordEnv: 'E2E_MASTODON_DOMAINLOCKED_PASSWORD',
    roles: ['ROLE_MASTODON', 'ROLE_MASTODON_DOMAINLOCKED', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    federationProbe: 'mastodon',
    note: 'Mastodon domain-locked — MRF forces every delivery local; even a RAW-API visibility=public toot must NOT reach the peer (spec 19).',
  },

  // ── EXTERNAL-CLIENT roles (native client passthrough via the gateway) ──────
  {
    username: 'e2e-matrix-external-client',
    passwordEnv: 'E2E_MATRIX_EXTERNAL_CLIENT_PASSWORD',
    roles: ['ROLE_MATRIX', 'ROLE_MATRIX_EXTERNAL_CLIENT', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'Matrix external-client — may register/use a native client (Element) through the gateway passthrough; revoked on role removal.',
  },
  {
    username: 'e2e-mastodon-external-client',
    passwordEnv: 'E2E_MASTODON_EXTERNAL_CLIENT_PASSWORD',
    roles: ['ROLE_MASTODON', 'ROLE_MASTODON_EXTERNAL_CLIENT', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'Mastodon external-client — may register/use a native client (Tusky) through the gateway OAuth passthrough; revoked on role removal.',
  },

  // ── forum (phpBB) access ──────────────────────────────────────────────────
  {
    username: 'e2e-forum',
    passwordEnv: 'E2E_FORUM_PASSWORD',
    roles: ['ROLE_FORUM', 'ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    note: 'Forum participant — reaches forum-ui/forum-bff; DENIED admin/mod/forum-mod surfaces.',
  },

  // ── single-role-DENIED — a PINNED (role, route, expect=403) triple ─────────
  {
    username: 'e2e-denied',
    passwordEnv: 'E2E_DENIED_PASSWORD',
    roles: ['ROLE_USER'],
    expectGamesAdmin: false,
    registrationComplete: true,
    pinnedDeny: {
      route: '/bff/admin/domain-lock',
      expectStatus: 403,
      reason: 'ROLE_USER only — must be DENIED the admin domain-lock surface (a concrete, reproducible deny).',
    },
    note: 'Single-role DENIED — holds ONLY ROLE_USER; pinned 403 on GET /bff/admin/domain-lock (admin-only).',
  },

  {
    username: 'e2e-pending',
    passwordEnv: 'E2E_PENDING_PASSWORD',
    roles: [],
    expectGamesAdmin: false,
    registrationComplete: false,
    note: 'Awaiting approval — no roles, registration incomplete; DENIED until an admin approves.',
  },
];

// ── Procedural SWARM generator (the scaled-concurrent final sweep, spec 24) ──
// The final e2e sweep drives a POPULATION acting simultaneously: 120 plain users,
// 4 mods (who moderate the users below them), and 2 admins. The swarm is
// PROCEDURAL + DETERMINISTIC so the seed (seed-accounts.sh --swarm N) and the
// spec agree on every identity WITHOUT a 126-line table. Passwords derive from a
// single E2E_SWARM_PASSWORD (default below) so a real Casdoor login carries the
// right `roles` claim. The numbers are overridable for a smaller CI smoke.
export const SWARM_DEFAULTS = { users: 120, mods: 4, admins: 2 } as const;

/** Deterministic password for a swarm member — `E2E_SWARM_PASSWORD` (shared) so
 *  a single env var unlocks the whole population. NOT per-user (126 distinct env
 *  vars would be unusable); the seed uses the identical derivation. */
export function swarmPassword(): string {
  return process.env['E2E_SWARM_PASSWORD'] ?? process.env['E2E_PASSWORD'] ?? 'e2e-swarm-pass';
}

export interface SwarmMember extends SystemsSeedUser {
  /** Swarm tier — drives what the actor DOES in spec 24. */
  swarmTier: 'user' | 'mod' | 'admin';
  /** Zero-based index within the tier (for deterministic moderation targeting:
   *  mod m moderates the users in [m * usersPerMod, (m+1) * usersPerMod)). */
  tierIndex: number;
}

/** Generate the swarm population deterministically. Usernames are
 *  e2e-swarm-user-000 … -119, e2e-swarm-mod-0 … -3, e2e-swarm-admin-0 … -1.
 *  Kept in lock-step with seed-accounts.sh --swarm. */
export function generateSwarm(
  counts: { users: number; mods: number; admins: number } = SWARM_DEFAULTS,
): SwarmMember[] {
  const out: SwarmMember[] = [];
  const pad = (n: number, w: number) => String(n).padStart(w, '0');
  for (let i = 0; i < counts.users; i++) {
    out.push({
      username: `e2e-swarm-user-${pad(i, 3)}`,
      passwordEnv: 'E2E_SWARM_PASSWORD',
      roles: ['ROLE_USER', 'ROLE_MATRIX', 'ROLE_MASTODON'],
      expectGamesAdmin: false,
      registrationComplete: true,
      swarmTier: 'user',
      tierIndex: i,
      note: `Swarm plain user #${i} — a moderation TARGET; asserts its own per-principal SSE + disabled-helptext.`,
    });
  }
  for (let i = 0; i < counts.mods; i++) {
    out.push({
      username: `e2e-swarm-mod-${i}`,
      passwordEnv: 'E2E_SWARM_PASSWORD',
      roles: ['ROLE_MOD', 'ROLE_MATRIX', 'ROLE_MASTODON', 'ROLE_USER'],
      expectGamesAdmin: false,
      registrationComplete: true,
      swarmTier: 'mod',
      tierIndex: i,
      note: `Swarm mod #${i} — moderates the user-block assigned to it; asserted to FAIL on admins/peers.`,
    });
  }
  for (let i = 0; i < counts.admins; i++) {
    out.push({
      username: `e2e-swarm-admin-${i}`,
      passwordEnv: 'E2E_SWARM_PASSWORD',
      roles: ['ROLE_ADMIN', 'ROLE_MATRIX', 'ROLE_MASTODON', 'ROLE_USER'],
      expectGamesAdmin: false,
      registrationComplete: true,
      swarmTier: 'admin',
      tierIndex: i,
      note: `Swarm admin #${i} — global suspension/role-assignment/allowlist/reconcile.`,
    });
  }
  return out;
}

/** Which users a given mod moderates (deterministic, non-overlapping blocks) —
 *  shared by the seed + the sweep so "mod m moderates users below it" is exact. */
export function swarmTargetsForMod(
  modIndex: number,
  counts: { users: number; mods: number; admins: number } = SWARM_DEFAULTS,
): string[] {
  const perMod = Math.ceil(counts.users / counts.mods);
  const start = modIndex * perMod;
  const end = Math.min(start + perMod, counts.users);
  const pad = (n: number) => String(n).padStart(3, '0');
  const out: string[] = [];
  for (let i = start; i < end; i++) out.push(`e2e-swarm-user-${pad(i)}`);
  return out;
}

// ── ROLE_SUPERADMIN tier — the tailnet-only infra control plane ──────────────
// The superadmin Service Catalog/console is served by its OWN gateway
// (snapdragon-superadmin-gateway, specs/cluster/apps/22-gateway-superadmin.yaml),
// NOT by the public fe/be/pki gateways. Every route under that gateway name is
// gated ROLE_SUPERADMIN in gateway_route_access
// (specs/cluster/manifests/route-access/initdb/20-schema.sql). These are the
// ALLOW routes (copied 1:1 from the manifest's superadmin-gateway rows) the
// spec asserts ROLE_SUPERADMIN reaches and ROLE_ADMIN is DENIED (no down-cascade).
export const SUPERADMIN_GATEWAY = 'snapdragon-superadmin-gateway' as const;

/** The ROLE_SUPERADMIN ALLOW routes on the superadmin-gateway — the three rows
 *  seeded in 20-schema.sql under gateway = snapdragon-superadmin-gateway, plus a
 *  representative concrete path to probe each glob with. */
export const SUPERADMIN_ALLOW_ROUTES: { urlPattern: string; probe: string; what: string }[] = [
  { urlPattern: '/bff/superadmin/**',      probe: '/bff/superadmin/service-store/catalog', what: 'Service Catalog BFF control plane (tailnet)' },
  { urlPattern: '/superadmin/service-catalog/**', probe: '/superadmin/service-catalog/remoteEntry.js', what: 'service-catalog-ui federated remote (tailnet)' },
  { urlPattern: '/api/federation/**',      probe: '/api/federation/manifest', what: 'federation manifest/bundles for the superadmin shell (tailnet)' },
];

/** The DENY-down-cascade expectation: ROLE_ADMIN (and any non-superadmin tier)
 *  must NOT reach the superadmin-gateway routes — ROLE_SUPERADMIN is a distinct
 *  tier, not a subset that admin inherits, so there is NO down-cascade. The spec
 *  asserts every non-superadmin role in this list is DENIED every route above. */
export const SUPERADMIN_DENY_ROLES: SystemsRole[] = [
  'ROLE_ADMIN', 'ROLE_MOD', 'ROLE_GAMES_ADMIN', 'ROLE_USER',
];

// ── Cross-realm issuer isolation invariant ──────────────────────────────────
// The two realms are INDEPENDENT Casdoors with distinct issuers. A token minted
// by one issuer carries that realm's roles ONLY; the other realm's gateways must
// treat its ROLE_*/role claims as absent (issuer isolation). The spec uses these
// to assert a games-realm identity carries NO systems ROLE_* into a systems
// gateway decision (and vice-versa).
export const SYSTEMS_ISSUER = 'id.snapdragon.systems' as const;  // org "snapdragon"
export const GAMES_ISSUER = 'id.snapdragon.games' as const;      // org "threewizards"

/** The GAMES realm (org "threewizards", issuer id.snapdragon.games) is an
 *  INDEPENDENT Casdoor. The only systems->games automatic sync is
 *  ROLE_GAMES_ADMIN(systems) -> admin(games) (snapdragon-actions
 *  GameMasterAdminSyncAction). We seed exactly one native player here, and the
 *  synced games admin is EXPECTED to appear from e2e-gamesadmin — but that
 *  cross-realm assertion is owned by snapdragon-actions/e2e (sync-steps.ts), so
 *  here we only record the expectation. */
export interface GamesSeedUser {
  username: string;
  passwordEnv: string;
  /** Native games role(s). */
  roles: string[];
  /** True when the row exists ONLY because of the systems->games sync (not seeded
   *  natively) — asserted by snapdragon-actions/e2e, recorded here for the matrix. */
  syncedFromSystems?: string;
  note: string;
}

export const GAMES_SEED_USERS: GamesSeedUser[] = [
  {
    username: 'e2e-player',
    passwordEnv: 'E2E_PLAYER_PASSWORD',
    roles: ['player'],
    note: 'Native games player — plays games; no admin/mod/publisher surfaces (games realm).',
  },
  {
    username: 'e2e-gamesadmin',     // SAME login handle as the systems user it mirrors
    passwordEnv: 'E2E_GAMESADMIN_PASSWORD',
    roles: ['admin'],
    syncedFromSystems: 'ROLE_GAMES_ADMIN',
    note: 'games admin appears via systems->games sync from e2e-gamesadmin (ROLE_GAMES_ADMIN). Asserted by snapdragon-actions/e2e.',
  },
];

/** Resolve a seed user's password — per-user env override or E2E_PASSWORD
 *  fallback — without throwing on a missing env. Mirrors games roles.ts
 *  passwordFor(). */
export function passwordFor(user: { passwordEnv: string }): string {
  return process.env[user.passwordEnv]
      ?? process.env['E2E_PASSWORD']
      ?? 'e2e-pass';
}

export function systemsUser(username: string): SystemsSeedUser {
  const u = SYSTEMS_SEED_USERS.find((x) => x.username === username);
  if (!u) throw new Error(`unknown systems seed user: ${username}`);
  return u;
}
