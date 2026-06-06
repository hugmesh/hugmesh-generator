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
  | 'ROLE_ADMIN'
  | 'ROLE_MOD'
  | 'ROLE_GAMES'
  | 'ROLE_GAMES_ADMIN'   // DERIVED — never seeded directly; listed only as an expectation
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
  /** One-line note used in spec titles + the user matrix. */
  note: string;
}

export const SYSTEMS_SEED_USERS: SystemsSeedUser[] = [
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
    note: 'Plain member — reaches Matrix/Mastodon user surfaces; DENIED every admin/mod/games-admin route.',
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
