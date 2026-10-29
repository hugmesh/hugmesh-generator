// coverage-catalogue.ts — the FUNCTION catalogue and the ACCESS ORACLE that turn
// "every user in every function in every service" from an aspiration into a
// countable, drift-guarded set.
//
// ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
// The operator asked for coverage of every USER x every FUNCTION x every
// SERVICE. Hand-writing that is decoration by volume: 31 personas x 62 functions
// is 1922 cells and no human keeps 1922 Gherkin rows correct. So the cells are
// DERIVED here and the .feature files under features/coverage/ are EMITTED from
// them (tools/emit-coverage-matrix.ts). Adding a persona to
// tests/e2e-extra-personas.sh, or a service to steps/dimensions.ts SERVICES, or
// a function to FUNCTIONS below, expands the emitted matrix automatically — and
// tests/scripts/test-e2e-coverage-matrix.sh goes RED until it is re-emitted.
//
// ── THE THREE INPUT CATALOGUES, NONE OF THEM RE-LISTED HERE ──────────────────
//   personas  the UNION of three DISAGREEING rosters, read (never copied):
//               1. specs/rbac-roles.ts SYSTEMS_SEED_USERS      (the TS catalogue)
//               2. tests/e2e-extra-personas.sh                 (the shell roster
//                  both the compose and kind seeders execute — parsed by
//                  steps/dimensions.ts shellRoster())
//               3. tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS default block
//                  (the shell lane's OWN base catalogue)
//             The three do not agree. The disagreement is REPRESENTED — every
//             emitted Examples row carries a `source` column naming which lanes
//             seed that handle — and deliberately NOT resolved here. Resolving
//             it is a seeding change, not a test change.
//   services  steps/dimensions.ts SERVICES (12 entries).
//   functions FUNCTIONS below — the functional surface a user can exercise per
//             service. Each entry records where it came from: `derived` means
//             the path was read off a committed artefact named in `source`;
//             `asserted` means no artefact pins it yet and a human chose it.
//             The split is visible in the emitted Gherkin, so nobody mistakes an
//             asserted probe for a derived one.
//
// ── THE ORACLE IS NOT THE ROSTER ─────────────────────────────────────────────
// The expected outcome of a cell is NOT read off ServiceDef.accessRole (that
// would make the matrix assert the catalogue against itself). It is computed by
// replaying the request against the COMMITTED gateway route-access seed —
// specs/cluster/manifests/route-access/initdb/20-schema.sql, 150 rows, the same
// artefact the gateways are built from — using the most-specific-pattern-wins
// model that specs/rbac-route-access.ts documents. Two independent artefacts
// therefore have to agree before a cell is green: the roster says what roles a
// persona holds, the seed says what those roles reach.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { SERVICES, ServiceDef, shellRoster, service } from './dimensions';
import { SYSTEMS_SEED_USERS } from '../specs/rbac-roles';

/** Repo root — steps/ is tests/e2e/steps, so three levels up. */
export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

const ROUTE_ACCESS_SQL = 'specs/cluster/manifests/route-access/initdb/20-schema.sql';
const SEED_ACCOUNTS_SH = 'tests/qemu/seed-accounts.sh';

function readRepoFile(rel: string): string {
  const abs = path.join(REPO_ROOT, rel);
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the committed artefact ${abs}: ${(e as Error).message}. The coverage `
      + `matrix DERIVES its expected outcomes from this file; refusing to fall back to a `
      + `hard-coded table, which is exactly how a mirror rots while its guard stays green.`,
    );
  }
}

// ── THE ROUTE-ACCESS ORACLE ──────────────────────────────────────────────────

export type GatewayName =
  | 'hugmesh-fe-gateway' | 'hugmesh-be-gateway'
  | 'hugmesh-pki-gateway' | 'hugmesh-superadmin-gateway';

export interface SeedRow { gateway: string; pattern: string; role: string; allow: boolean }

let seedRowsCache: SeedRow[] | undefined;

/**
 * Parse the `('<gateway>', '<url_pattern>', '<ROLE>', <allow>)` tuples out of the
 * committed route-access seed. Same shape steps/uncovered-services.steps.ts
 * parses; kept as its own reader here so this module has no dependency on a
 * step file (a step file imports `world`, which builds Playwright fixtures — the
 * emitter must be able to load this catalogue with no test runner in scope).
 */
export function seedRows(): SeedRow[] {
  if (seedRowsCache) return seedRowsCache;
  const re = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)/g;
  const out: SeedRow[] = [];
  for (const m of readRepoFile(ROUTE_ACCESS_SQL).matchAll(re)) {
    out.push({ gateway: m[1], pattern: m[2], role: m[3], allow: m[4] === 'true' });
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO rows out of ${ROUTE_ACCESS_SQL}. The seed's INSERT shape changed — fix `
      + `this parser. An empty table would make EVERY cell of the coverage matrix read `
      + `"refused" and the whole matrix would go green having asserted nothing.`,
    );
  }
  seedRowsCache = out;
  return out;
}

/**
 * Spring path-pattern match + specificity, mirroring specs/rbac-route-access.ts
 * `patternMatch` (most-specific literal prefix wins; an exact path beats a glob
 * of the same length). Extended for the two shapes the SQL seed uses that the TS
 * mirror does not carry: a bare `/**` catch-all and a `/*.ext` suffix glob.
 */
export function patternMatch(pattern: string, target: string): { matched: boolean; specificity: number } {
  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);
    const matched = target === prefix || target.startsWith(`${prefix}/`)
      || (prefix === '' && target.startsWith('/'));
    return { matched, specificity: matched ? prefix.length * 2 : -1 };
  }
  if (pattern.startsWith('/*.')) {
    const suffix = pattern.slice(2);                       // '.css'
    const matched = target.endsWith(suffix) && !target.slice(1).includes('/');
    return { matched, specificity: matched ? suffix.length : -1 };
  }
  if (pattern === '/') return { matched: target === '/', specificity: target === '/' ? 1 : -1 };
  const matched = target === pattern;
  return { matched, specificity: matched ? pattern.length * 2 + 1 : -1 };
}

export type Outcome = 'admitted' | 'refused';

export interface Decision {
  outcome: Outcome;
  /** The url_pattern that won the most-specific match, or null when none matched. */
  pattern: string | null;
  /** Every role granted at the winning pattern (the reason, spelled out). */
  grantedRoles: string[];
  /** Why — a one-line human sentence quoted into the failure message. */
  why: string;
}

/**
 * Replay one request against the committed seed. DEFAULT-DENY: a path no
 * pattern matches is refused, and a pattern whose only rows are `allow=false`
 * (the governed-but-ungranted `/bff/internal/**` shape) is refused too.
 * 'PUBLIC' is the seed's spelling of the anonymous floor.
 */
export function seedDecision(gateway: GatewayName, target: string, roles: readonly string[]): Decision {
  const rows = seedRows().filter((r) => r.gateway === gateway);
  let best = -1;
  let winners: SeedRow[] = [];
  for (const r of rows) {
    const { matched, specificity } = patternMatch(r.pattern, target);
    if (!matched) continue;
    if (specificity > best) { best = specificity; winners = []; }
    if (specificity === best) winners.push(r);
  }
  if (best < 0) {
    return {
      outcome: 'refused', pattern: null, grantedRoles: [],
      why: `no ${gateway} url_pattern in ${ROUTE_ACCESS_SQL} matches ${target}; the gateway is default-deny`,
    };
  }
  const pattern = winners[0].pattern;
  const allowRoles = winners.filter((r) => r.allow).map((r) => r.role);
  if (allowRoles.includes('PUBLIC')) {
    return {
      outcome: 'admitted', pattern, grantedRoles: allowRoles,
      why: `${pattern} is a PUBLIC row — admitted with no Casdoor JWT at all`,
    };
  }
  const held = allowRoles.filter((r) => roles.includes(r));
  if (held.length) {
    return {
      outcome: 'admitted', pattern, grantedRoles: allowRoles,
      why: `${pattern} grants ${allowRoles.join('/')} and the principal holds ${held.join('/')}`,
    };
  }
  return {
    outcome: 'refused', pattern, grantedRoles: allowRoles,
    why: allowRoles.length
      ? `${pattern} grants only ${allowRoles.join('/')}; the principal holds none of them`
      : `${pattern} carries no allow row (governed but ungranted) — deny`,
  };
}

// ── THE PERSONA ROSTER, RECONCILED ACROSS THREE DISAGREEING SOURCES ──────────

export type RosterLane = 'ts-catalogue' | 'extra-personas-sh' | 'seed-accounts-sh';

export interface RosterEntry {
  handle: string;
  /** Roles GRANTED by any lane that seeds this handle (union; never the derived role). */
  granted: string[];
  /** Which lanes seed it. Sorted. The DISAGREEMENT, made visible in every row. */
  lanes: RosterLane[];
  /**
   * Two-stage registration gate. `false` models the awaiting-approval persona
   * (specs/rbac-roles.ts: "the two-stage registration gate must keep it out of
   * every user surface until an admin approves it"), whose effective role-set at
   * the gateway is EMPTY however many roles Casdoor holds for it.
   */
  registrationComplete: boolean;
  /** ROLE_GAMES INTERSECT (ROLE_ADMIN UNION ROLE_MOD) — the sync-job composite. */
  derivedGamesAdmin: boolean;
  /** SYSTEMS_SEED_USERS.expectGamesAdmin, or null when only a shell lane seeds it. */
  declaredGamesAdmin: boolean | null;
}

/**
 * Parse the DEFAULT `SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS:- … }"` block out of
 * tests/qemu/seed-accounts.sh — the third roster, and the one the qemu/kind lanes
 * actually execute. Read, not copied: a copy is how this repo grew three
 * divergent lists in the first place (tests/scripts/test-e2e-persona-catalogue.sh).
 */
export function seedAccountsRoster(): { username: string; roles: string[] }[] {
  const text = readRepoFile(SEED_ACCOUNTS_SH);
  const start = text.indexOf('SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS:-');
  if (start < 0) {
    throw new Error(
      `could not find the default SYSTEMS_ROLE_USERS block in ${SEED_ACCOUNTS_SH}. Its shape `
      + `moved; re-point this parser. Silently returning an empty roster would drop a whole `
      + `seeding lane out of the reconciliation and the matrix would still look complete.`,
    );
  }
  const end = text.indexOf('}"', start);
  const block = text.slice(start, end < 0 ? text.length : end);
  const out: { username: string; roles: string[] }[] = [];
  // handle:ROLE_A,ROLE_B:ENV  — and the role-less `e2e-pending::E2E_PENDING_PASSWORD`.
  const re = /(^|\s)([A-Za-z0-9@._-]+):((?:ROLE_[A-Z0-9_]+)(?:,ROLE_[A-Z0-9_]+)*)?:([A-Z0-9_]+)/g;
  for (const m of block.matchAll(re)) {
    out.push({ username: m[2], roles: m[3] ? m[3].split(',') : [] });
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO personas out of the ${SEED_ACCOUNTS_SH} SYSTEMS_ROLE_USERS block. The `
      + `grammar changed (expected handle:ROLE_A,ROLE_B:PASSWORD_ENV) — fix this parser.`,
    );
  }
  return out;
}

let rosterCache: RosterEntry[] | undefined;

/** Every persona ANY lane seeds, with the union of its roles and the lanes that seed it. */
export function roster(): RosterEntry[] {
  if (rosterCache) return rosterCache;
  const byHandle = new Map<string, RosterEntry>();
  const touch = (handle: string, lane: RosterLane, roles: string[]): RosterEntry => {
    let e = byHandle.get(handle);
    if (!e) {
      e = {
        handle, granted: [], lanes: [], registrationComplete: true,
        derivedGamesAdmin: false, declaredGamesAdmin: null,
      };
      byHandle.set(handle, e);
    }
    if (!e.lanes.includes(lane)) e.lanes.push(lane);
    for (const r of roles) if (!e.granted.includes(r)) e.granted.push(r);
    return e;
  };

  for (const u of SYSTEMS_SEED_USERS) {
    const e = touch(u.username, 'ts-catalogue', u.roles as string[]);
    e.registrationComplete = u.registrationComplete;
    e.declaredGamesAdmin = u.expectGamesAdmin;
  }
  for (const p of shellRoster()) touch(p.username, 'extra-personas-sh', p.roles);
  for (const p of seedAccountsRoster()) touch(p.username, 'seed-accounts-sh', p.roles);

  const out = [...byHandle.values()];
  for (const e of out) {
    e.granted.sort();
    e.lanes.sort();
    // The composite the games-admin-sync Job materialises. Computed from the RULE
    // (specs/rbac-roles.ts header) rather than copied from expectGamesAdmin, so the
    // two can be cross-checked — see `gamesAdminDisagreements()`.
    e.derivedGamesAdmin = e.granted.includes('ROLE_GAMES')
      && (e.granted.includes('ROLE_ADMIN') || e.granted.includes('ROLE_MOD'));
  }
  out.sort((a, b) => a.handle.localeCompare(b.handle));
  rosterCache = out;
  return out;
}

export function rosterEntry(handle: string): RosterEntry {
  const e = roster().find((r) => r.handle === handle);
  if (!e) {
    throw new Error(
      `no seeding lane creates persona '${handle}'. Known handles (${roster().length}): `
      + `${roster().map((r) => r.handle).join(', ')}`,
    );
  }
  return e;
}

/** Handles where the DERIVED composite disagrees with SYSTEMS_SEED_USERS.expectGamesAdmin. */
export function gamesAdminDisagreements(): string[] {
  return roster()
    .filter((e) => e.declaredGamesAdmin !== null && e.declaredGamesAdmin !== e.derivedGamesAdmin)
    .map((e) => e.handle);
}

/**
 * The role-set this persona actually presents to a gateway: granted roles plus the
 * derived composite — EXCEPT when the two-stage registration gate has not been
 * cleared, in which case it presents nothing at all and only PUBLIC rows admit it.
 */
export function effectiveRolesOf(handle: string): string[] {
  const e = rosterEntry(handle);
  if (!e.registrationComplete) return [];
  const set = new Set(e.granted);
  if (e.derivedGamesAdmin) set.add('ROLE_GAMES_ADMIN');
  return [...set].sort();
}

// ── THE FUNCTION CATALOGUE ───────────────────────────────────────────────────

/** Where a function's probe path came from. `asserted` is never silently mixed in. */
export type FunctionEvidence = 'derived' | 'asserted';

export interface ServiceFunction {
  /** Globally unique id, `<service>.<verb>`. The Examples `function` column. */
  id: string;
  /** SERVICES id it belongs to. */
  service: string;
  /** Human sentence used in the scenario name. */
  name: string;
  /** Which gateway decides this function's access. */
  gateway: GatewayName;
  /** A CONCRETE path (never a pattern) the oracle replays. */
  probePath: string;
  evidence: FunctionEvidence;
  /** The committed artefact (or the reasoning) the probe path came from. */
  source: string;
}

const FE: GatewayName = 'hugmesh-fe-gateway';
const BE: GatewayName = 'hugmesh-be-gateway';

/**
 * The functional surface per service.
 *
 * DERIVED entries take their path from a url_pattern that really exists in
 * specs/cluster/manifests/route-access/initdb/20-schema.sql (the gate) and/or
 * tests/stack/gateway-routes/fe/application-routes.yml (the route) — the probe
 * is a concrete instance of that pattern. ASSERTED entries are functions the
 * product plainly has but no committed artefact pins a path for; they are
 * labelled so a reader never mistakes one for a measurement.
 */
export const FUNCTIONS: ServiceFunction[] = [
  // ── tuwunel (Matrix homeserver) ────────────────────────────────────────────
  { id: 'tuwunel.open-ui', service: 'tuwunel', name: 'open the Matrix surface in the host shell',
    gateway: FE, probePath: '/social/matrix/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/social/matrix/**','ROLE_USER')" },
  { id: 'tuwunel.sign-in', service: 'tuwunel', name: 'log in to the homeserver with a native client',
    gateway: FE, probePath: '/_matrix/client/v3/login', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/_matrix/client/v3/login','ROLE_MATRIX_EXTERNAL_CLIENT') — a MORE SPECIFIC row than /_matrix/**, so native-client login is external-client-only by contract" },
  { id: 'tuwunel.join-room', service: 'tuwunel', name: 'join a room',
    gateway: FE, probePath: '/_matrix/client/v3/join/!e2e:hugmesh.net', evidence: 'derived',
    source: "instance of the '/_matrix/**' seed row; the join endpoint is the one specs/05-matrix-chat.spec.ts drives through the matrix remote" },
  { id: 'tuwunel.send-message', service: 'tuwunel', name: 'send a message',
    gateway: FE, probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.room.message/1', evidence: 'derived',
    source: "instance of the '/_matrix/**' seed row (spec 05/31 send path)" },
  { id: 'tuwunel.receive-message', service: 'tuwunel', name: 'receive messages',
    gateway: FE, probePath: '/_matrix/client/v3/sync', evidence: 'derived',
    source: "instance of the '/_matrix/**' seed row (the sync loop specs 05/11/31 wait on)" },
  { id: 'tuwunel.start-call', service: 'tuwunel', name: 'start a call',
    gateway: FE, probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.call.invite/1', evidence: 'derived',
    source: "instance of the '/_matrix/**' seed row (spec 10/11 m.call.invite)" },
  { id: 'tuwunel.leave-room', service: 'tuwunel', name: 'leave a room',
    gateway: FE, probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/leave', evidence: 'derived',
    source: "instance of the '/_matrix/**' seed row" },
  { id: 'tuwunel.well-known', service: 'tuwunel', name: 'resolve the server delegation',
    gateway: FE, probePath: '/.well-known/matrix/client', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/.well-known/matrix/**',ROLE_MATRIX/MOD/ADMIN)" },

  // ── akkoma (Mastodon-compatible) ───────────────────────────────────────────
  { id: 'akkoma.open-ui', service: 'akkoma', name: 'open the Mastodon surface in the host shell',
    gateway: FE, probePath: '/social/mastodon/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/social/mastodon/**','ROLE_USER')" },
  { id: 'akkoma.sign-in', service: 'akkoma', name: 'obtain an OAuth token',
    gateway: FE, probePath: '/oauth/token', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/oauth/**',ROLE_MASTODON/MOD/ADMIN/MASTODON_EXTERNAL_CLIENT)" },
  { id: 'akkoma.post', service: 'akkoma', name: 'post a status',
    gateway: FE, probePath: '/api/v1/statuses', evidence: 'derived',
    source: "instance of the '/api/v1/**' seed row; the endpoint specs/06-mastodon-post.spec.ts drives" },
  { id: 'akkoma.boost', service: 'akkoma', name: 'boost a status',
    gateway: FE, probePath: '/api/v1/statuses/1/reblog', evidence: 'derived',
    source: "instance of the '/api/v1/**' seed row (Mastodon API reblog)" },
  { id: 'akkoma.follow', service: 'akkoma', name: 'follow an account',
    gateway: FE, probePath: '/api/v1/accounts/1/follow', evidence: 'derived',
    source: "instance of the '/api/v1/**' seed row" },
  { id: 'akkoma.timeline', service: 'akkoma', name: 'read the home timeline',
    gateway: FE, probePath: '/api/v1/timelines/home', evidence: 'derived',
    source: "instance of the '/api/v1/**' seed row (spec 06/19/22 read the timeline back)" },
  { id: 'akkoma.delete-post', service: 'akkoma', name: 'delete a status',
    gateway: FE, probePath: '/api/v1/statuses/1', evidence: 'derived',
    source: "instance of the '/api/v1/**' seed row" },
  { id: 'akkoma.moderate', service: 'akkoma', name: 'use the akkoma moderation API',
    gateway: BE, probePath: '/api/v1/pleroma/admin/users', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-be-gateway','/api/v1/pleroma/admin/**',ROLE_MOD/ROLE_ADMIN)" },

  // ── phpbb (forum) ──────────────────────────────────────────────────────────
  { id: 'phpbb.open-ui', service: 'phpbb', name: 'open the forum micro-frontend',
    gateway: FE, probePath: '/social/forum/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/social/forum/**','ROLE_FORUM')" },
  { id: 'phpbb.read-topic', service: 'phpbb', name: 'read a topic',
    gateway: FE, probePath: '/bff/forum/topics/1', evidence: 'derived',
    source: "instance of the ('hugmesh-fe-gateway','/bff/forum/**','ROLE_FORUM') seed row" },
  { id: 'phpbb.post-topic', service: 'phpbb', name: 'start a topic',
    gateway: FE, probePath: '/bff/forum/topics', evidence: 'derived',
    source: "instance of the '/bff/forum/**' seed row" },
  { id: 'phpbb.reply', service: 'phpbb', name: 'reply to a topic',
    gateway: FE, probePath: '/bff/forum/topics/1/posts', evidence: 'derived',
    source: "instance of the '/bff/forum/**' seed row" },
  { id: 'phpbb.moderate', service: 'phpbb', name: 'work the forum moderation queue',
    gateway: FE, probePath: '/bff/forum/moderation/reports', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/forum/moderation/**','ROLE_FORUM_MOD')" },
  { id: 'phpbb.administer', service: 'phpbb', name: 'administer the forum',
    gateway: FE, probePath: '/bff/forum/admin/forums', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/forum/admin/**','ROLE_ADMIN')" },

  // ── games ──────────────────────────────────────────────────────────────────
  { id: 'games.list', service: 'games', name: 'list the games catalogue',
    gateway: FE, probePath: '/games/', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/games/**',ROLE_GAMES/ROLE_ADMIN/ROLE_MOD) — the `games` federation remote's bytes + member HTML behind the fe route games-ui (2026-10-28; until then the fe side had NO /games/** row and the absence was pinned by features/uncovered-services/route-contract.feature, which now pins the grant)" },
  { id: 'games.launch', service: 'games', name: 'launch a game',
    gateway: FE, probePath: '/games/play/chess', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/games/**',ROLE_GAMES/ROLE_ADMIN/ROLE_MOD) — the member Play screen (/games/play/<slug>, remote `games` './routes' GAMES_ROUTES) rides the same /games/** row as the catalog; the launch itself is games.member-api below" },
  { id: 'games.member-api', service: 'games', name: 'call the games member API (catalog, launch, launches)',
    gateway: FE, probePath: '/games/api/games/chess/launch', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/games/api/**',ROLE_GAMES/ROLE_ADMIN/ROLE_MOD) — the games BFF behind the fe route games-bff (Path=/games/api/**, StripPrefix=1); the BFF's own SecurityConfig then requires authenticated() on these paths" },
  { id: 'games.admin-api', service: 'games', name: 'call the games admin API (sessions, stats, access, debug-mode)',
    gateway: FE, probePath: '/games/api/admin/stats', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/games/api/admin/**','ROLE_GAMES_ADMIN') — the derived composite alone, the same AND as games.admin-console; longer than /games/api/** so the member floor never reaches it" },
  { id: 'games.instance-lifecycle', service: 'games', name: 'drive an instance lifecycle',
    gateway: BE, probePath: '/games/api/instances', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-be-gateway','/games/**',ROLE_GAMES/ROLE_ADMIN/ROLE_MOD) — the non-admin games API floor on the BACK-END gateway (the standalone portal's door). The browser front door now carries its own /games/** and /games/api/** trios (games.list / games.member-api), identical role sets" },
  { id: 'games.server-fleet', service: 'games', name: 'drive the game-server fleet',
    gateway: BE, probePath: '/games/servers/lobby', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-be-gateway','/games/servers/**',ROLE_GAMES_SERVICES/ROLE_ADMIN/ROLE_MOD) — a MORE SPECIFIC row than '/games/**', so the games floor alone does not reach it" },
  { id: 'games.admin-console', service: 'games', name: 'open the games admin console',
    gateway: FE, probePath: '/games/admin/queue', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/games/admin/**','ROLE_GAMES_ADMIN') — the derived composite alone" },
  { id: 'games.services-runner', service: 'games', name: 'drive the games-services runner console',
    gateway: FE, probePath: '/admin/games-services/runners', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/admin/games-services/**',ROLE_GAMES_SERVICES_ADMIN/ROLE_GAMES_SERVICES_RUNNER)" },

  // ── owncast ────────────────────────────────────────────────────────────────
  { id: 'owncast.watch', service: 'owncast', name: 'watch the live stream',
    gateway: FE, probePath: '/owncast/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/owncast/**','ROLE_OWNCAST')" },
  { id: 'owncast.publish', service: 'owncast', name: 'publish a stream',
    gateway: FE, probePath: '/bff/owncast/stream', evidence: 'asserted',
    source: "ASSERTED path under the derived ('hugmesh-fe-gateway','/bff/owncast/**','ROLE_OWNCAST') row" },
  { id: 'owncast.chat', service: 'owncast', name: 'use the stream chat',
    gateway: FE, probePath: '/bff/owncast/chat', evidence: 'asserted',
    source: "ASSERTED path under the derived '/bff/owncast/**' row" },
  { id: 'owncast.administer', service: 'owncast', name: 'administer the stream',
    gateway: FE, probePath: '/bff/owncast/admin/config', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/owncast/admin/**','ROLE_ADMIN')" },

  // ── tube ───────────────────────────────────────────────────────────────────
  { id: 'tube.watch', service: 'tube', name: 'watch a video',
    gateway: FE, probePath: '/tube/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/tube/**','ROLE_TUBE')" },
  { id: 'tube.list', service: 'tube', name: 'browse channels',
    gateway: FE, probePath: '/bff/tube/channels', evidence: 'asserted',
    source: "ASSERTED path under the derived ('hugmesh-fe-gateway','/bff/tube/**','ROLE_TUBE') row" },
  { id: 'tube.publish', service: 'tube', name: 'publish a video',
    gateway: FE, probePath: '/bff/tube/videos', evidence: 'asserted',
    source: "ASSERTED path under the derived '/bff/tube/**' row" },
  { id: 'tube.delete', service: 'tube', name: 'delete a video',
    gateway: FE, probePath: '/bff/tube/videos/1', evidence: 'asserted',
    source: "ASSERTED path under the derived '/bff/tube/**' row" },

  // ── wiki ───────────────────────────────────────────────────────────────────
  { id: 'wiki.read', service: 'wiki', name: 'read the wiki',
    gateway: FE, probePath: '/wiki/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/wiki/**','ROLE_WIKI')" },
  { id: 'wiki.edit', service: 'wiki', name: 'edit a page',
    gateway: FE, probePath: '/bff/wiki/pages/home', evidence: 'asserted',
    source: "ASSERTED path under the derived ('hugmesh-fe-gateway','/bff/wiki/**','ROLE_WIKI') row" },
  { id: 'wiki.history', service: 'wiki', name: 'read a page history',
    gateway: FE, probePath: '/bff/wiki/pages/home/history', evidence: 'asserted',
    source: "ASSERTED path under the derived '/bff/wiki/**' row" },
  { id: 'wiki.administer', service: 'wiki', name: 'administer the wiki',
    gateway: FE, probePath: '/bff/wiki/admin/pages', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/wiki/admin/**','ROLE_ADMIN')" },

  // ── character-studio (2D) ──────────────────────────────────────────────────
  { id: 'character-studio.open', service: 'character-studio', name: 'open the 2D character studio',
    gateway: FE, probePath: '/character-studio/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/character-studio/**','ROLE_USER')" },
  { id: 'character-studio.create', service: 'character-studio', name: 'create a character',
    gateway: FE, probePath: '/bff/user/character-studio/characters', evidence: 'derived',
    source: "the studio has NO BFF prefix of its own (pinned as an absence by features/uncovered-services/route-contract.feature), so it talks to the always-present ('hugmesh-fe-gateway','/bff/user/**','ROLE_USER') row" },
  { id: 'character-studio.save', service: 'character-studio', name: 'save a character',
    gateway: FE, probePath: '/bff/user/character-studio/characters/1', evidence: 'derived',
    source: "instance of the '/bff/user/**' seed row (see character-studio.create)" },
  { id: 'character-studio.export', service: 'character-studio', name: 'export a character',
    gateway: FE, probePath: '/bff/user/character-studio/characters/1/export', evidence: 'asserted',
    source: "ASSERTED path under the derived '/bff/user/**' row" },

  // ── character-forge (3D) ───────────────────────────────────────────────────
  { id: 'character-forge.open', service: 'character-forge', name: 'open the 3D character forge',
    gateway: FE, probePath: '/character-forge/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/character-forge/**','ROLE_USER')" },
  { id: 'character-forge.create', service: 'character-forge', name: 'create a 3D character',
    gateway: FE, probePath: '/bff/character-forge/characters', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/character-forge/**','ROLE_USER'); specs/32-matrix-chat3d.spec.ts POSTs this exact path" },
  { id: 'character-forge.save', service: 'character-forge', name: 'save a 3D character',
    gateway: FE, probePath: '/bff/character-forge/characters/1', evidence: 'derived',
    source: "instance of the '/bff/character-forge/**' seed row" },
  { id: 'character-forge.export', service: 'character-forge', name: 'export a 3D character',
    gateway: FE, probePath: '/bff/character-forge/characters/1/export', evidence: 'asserted',
    source: "ASSERTED path under the derived '/bff/character-forge/**' row" },

  // ── gateway (the decision surface itself) ──────────────────────────────────
  { id: 'gateway.front-door', service: 'gateway', name: 'reach the public front door',
    gateway: FE, probePath: '/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/','PUBLIC')" },
  { id: 'gateway.host-shell-importmap', service: 'gateway', name: 'fetch the host shell import map',
    gateway: FE, probePath: '/importmap.json', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/importmap.json','PUBLIC')" },
  { id: 'gateway.session', service: 'gateway', name: 'read my own session',
    gateway: FE, probePath: '/bff/me/session', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/me/**','ROLE_USER'); specs/helpers.ts getSession() drives /bff/session behind it" },
  { id: 'gateway.federation-manifest', service: 'gateway', name: 'read the federation manifest',
    gateway: FE, probePath: '/api/federation/manifest', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/api/federation/manifest','ROLE_USER')" },
  { id: 'gateway.federation-capabilities', service: 'gateway', name: 'read the public federation capabilities',
    gateway: FE, probePath: '/api/federation/capabilities', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/api/federation/capabilities','PUBLIC')" },
  { id: 'gateway.internal-refused', service: 'gateway', name: 'reach an internal-only BFF path',
    gateway: FE, probePath: '/bff/internal/health', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/internal/**','ROLE_USER',allow=FALSE) — governed but ungranted, so NOBODY may reach it" },

  // ── login ──────────────────────────────────────────────────────────────────
  { id: 'login.form', service: 'login', name: 'open the sign-in form',
    gateway: FE, probePath: '/login/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/login/**','PUBLIC')" },
  { id: 'login.native-sign-in', service: 'login', name: 'sign in natively',
    gateway: FE, probePath: '/bff/login', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/login','PUBLIC'); specs/27-native-login.spec.ts POSTs it" },
  { id: 'login.register', service: 'login', name: 'complete the two-stage registration',
    gateway: FE, probePath: '/bff/register/complete', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/register/**','ROLE_USER'); specs/helpers.ts onboard() drives it" },
  { id: 'login.provision', service: 'login', name: 'provision device keys',
    gateway: FE, probePath: '/bff/provision/keys', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/provision/**','ROLE_USER')" },

  // ── admin ──────────────────────────────────────────────────────────────────
  { id: 'admin.console', service: 'admin', name: 'open the admin console',
    gateway: FE, probePath: '/admin/', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/admin/**','ROLE_ADMIN')" },
  { id: 'admin.allowlist', service: 'admin', name: 'edit the registration allowlist',
    gateway: FE, probePath: '/bff/admin/allowlist', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/bff/admin/**','ROLE_ADMIN'); specs/02-admin-allowlist.spec.ts drives it" },
  { id: 'admin.phone-fleet', service: 'admin', name: 'administer the phone fleet',
    gateway: FE, probePath: '/bff/admin/phone-fleet/devices', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/bff/admin/phone-fleet/**',ROLE_ADMIN/ROLE_FLEET_ADMIN/ROLE_SUPERADMIN) — the one surface a pure fleet owner reaches" },
  { id: 'admin.api-docs', service: 'admin', name: 'read the API docs',
    gateway: FE, probePath: '/api-docs/index.html', evidence: 'derived',
    source: "route-access seed row ('hugmesh-fe-gateway','/api-docs/**','ROLE_ADMIN')" },
  { id: 'admin.moderation-console', service: 'admin', name: 'open the moderation console',
    gateway: FE, probePath: '/mod/', evidence: 'derived',
    source: "route-access seed rows ('hugmesh-fe-gateway','/mod/**',ROLE_MOD/ROLE_ADMIN)" },
  { id: 'admin.superadmin-catalog', service: 'admin', name: 'open the superadmin service catalog',
    gateway: 'hugmesh-superadmin-gateway', probePath: '/superadmin/service-catalog/index', evidence: 'derived',
    source: "route-access seed row ('hugmesh-superadmin-gateway','/superadmin/service-catalog/**','ROLE_SUPERADMIN') — no ROLE_ADMIN down-cascade row exists" },
];

const FUNCTION_BY_ID = new Map(FUNCTIONS.map((f) => [f.id, f]));

export function serviceFunction(id: string): ServiceFunction {
  const f = FUNCTION_BY_ID.get(id);
  if (!f) {
    throw new Error(
      `unknown function id '${id}'. Legal ids (steps/coverage-catalogue.ts FUNCTIONS, `
      + `${FUNCTIONS.length}): ${FUNCTIONS.map((x) => x.id).join(', ')}. Add the function to `
      + `the catalogue and re-emit the matrix — never spell one inline in a .feature file.`,
    );
  }
  return f;
}

export function functionsForService(serviceId: string): ServiceFunction[] {
  service(serviceId);                       // validate through the SERVICES vocabulary
  return FUNCTIONS.filter((f) => f.service === serviceId);
}

/** Every SERVICES id that has no function catalogued. The drift guard's ammunition. */
export function servicesWithoutFunctions(): string[] {
  return SERVICES.filter((s) => !FUNCTIONS.some((f) => f.service === s.id)).map((s) => s.id);
}

/** Every catalogued function whose `service` is not a legal SERVICES id. */
export function functionsWithUnknownService(): string[] {
  const ids = new Set(SERVICES.map((s: ServiceDef) => s.id));
  return FUNCTIONS.filter((f) => !ids.has(f.service)).map((f) => f.id);
}

// ── THE COVERAGE CELLS ───────────────────────────────────────────────────────

export interface CoverageCell {
  handle: string;
  lanes: RosterLane[];
  service: string;
  functionId: string;
  outcome: Outcome;
  decision: Decision;
}

/**
 * The full persona x function product with its expected outcome — the set the
 * emitted Gherkin must cover exactly. `roster().length` x `FUNCTIONS.length`
 * rows, no sampling, no hand-picked subset.
 */
export function coverageCells(): CoverageCell[] {
  const out: CoverageCell[] = [];
  for (const p of roster()) {
    const roles = effectiveRolesOf(p.handle);
    for (const f of FUNCTIONS) {
      const decision = seedDecision(f.gateway, f.probePath, roles);
      out.push({
        handle: p.handle, lanes: p.lanes, service: f.service,
        functionId: f.id, outcome: decision.outcome, decision,
      });
    }
  }
  return out;
}

/** The outcome one cell must have. Used by BOTH the emitter and the step. */
export function expectedOutcome(handle: string, functionId: string): Decision {
  const f = serviceFunction(functionId);
  return seedDecision(f.gateway, f.probePath, effectiveRolesOf(handle));
}

/** Functions no seeded persona can reach at all — a real, reportable gap. */
export function unreachableFunctions(): string[] {
  const cells = coverageCells();
  return FUNCTIONS
    .filter((f) => !cells.some((c) => c.functionId === f.id && c.outcome === 'admitted'))
    .map((f) => f.id);
}
