// governance.ts — the FUNCTION axis for the governance consoles.
//
// WHAT THIS IS. tests/e2e/features/rbac/ already crosses PERSONA x ROUTE. This
// module adds the third thing the operator actually asked for: the FUNCTION —
// "approve a user", "manage the allowlist", "ban/unban", "grant a namespace",
// "assign a role", "act on the fleet", "read a backing service", "drive the
// workload console", "curate the superadmin service catalog" — and crosses every
// catalogued function against every catalogued PERSONA, so a refusal is asserted
// exactly as hard as an admission.
//
// WHY IT IS GENERATIVE AND NOT A HAND-WRITTEN TABLE. 34 seeded identities x 33
// governance functions is 1122 decisions. Writing those as Gherkin Examples rows
// would be decoration by volume, and adding one persona would silently leave 29
// holes. So the catalogue below is the single source, the Gherkin scenarios
// ITERATE it, and steps/../features/rbac/governance-drift-guard.feature goes RED
// when a catalogued function or persona is not reached by a scenario. The guard
// is the deliverable; the decisions are its output.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE ORACLE PROBLEM, AND WHY THIS FILE READS THE SQL AND NOT THE TS MIRROR
// ─────────────────────────────────────────────────────────────────────────────
// specs/rbac-route-access.ts is a hand-maintained MIRROR of a SUBSET of
// specs/cluster/manifests/route-access/initdb/20-schema.sql. Measured on this
// tree: the SQL seed carries 150 rows, the TS mirror 50. Twelve GOVERNANCE
// rows exist only in the SQL — including the entire moderator console
// (`/mod/**`, `/bff/mod/**`), the fleet console (`/bff/admin/phone-fleet/**` ->
// ROLE_FLEET_ADMIN), both workload-console prefixes, and the forum/wiki/owncast
// admin surfaces. A contract assertion written against the TS mirror alone
// cannot even EXPRESS those functions: the mirror has no matching pattern, so
// every one of them default-denies and every DENY expectation passes vacuously.
// The `e2e-fleet` persona is the sharpest case — it holds ROLE_FLEET_ADMIN,
// which appears in ZERO rows of the TS mirror, so "the fleet owner reaches the
// fleet console" is un-assertable there.
//
// Therefore the FUNCTION tier decides against the AUTHORITATIVE SQL seed, and
// treats the TS-mirror divergence as a first-class, LEDGERED finding
// (TS_MIRROR_LEDGER below) rather than as something to paper over. This file
// deliberately does NOT edit specs/rbac-route-access.ts: that file is held by a
// sibling branch, and quietly widening it would change the outcome of scenarios
// this unit did not write.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE TRANSCRIPTION TRAP (already paid for once, on fix/superadmin-route-access-row)
// ─────────────────────────────────────────────────────────────────────────────
// Deciding against the SQL needs Spring's most-specific-pattern-wins, which
// lives in rbac-route-access.ts `patternMatch` — NOT exported on this branch.
// The last agent that re-implemented it scored a glob as
// `literalPrefixLen * 2` where the oracle scores `prefix.length * 2` AFTER
// stripping `/**`; identical for glob-vs-glob, INVERTED for exact-vs-glob, and
// `/api/federation/vanity` vs `/api/federation/vanity/**` is that exact
// collision, live in the seed today.
//
// So `patternScore` below is a line-by-line transcription, and it is not
// trusted: features/rbac/governance-drift-guard.feature EXECUTES
// `decideWith(TS_MIRROR_ROWS, ...)` against the real exported `gatewayDecision`
// over every (gateway, path, role-set) triple the mirror can generate, and the
// two must agree on every one. If someone edits either side, that scenario is
// what goes red.

import * as fs from 'node:fs';
import * as path from 'node:path';
import {
  ROUTE_ACCESS, Gateway, GatewayDecision, effectiveRoles,
} from '../specs/rbac-route-access';
import { SYSTEMS_SEED_USERS, generateSwarm } from '../specs/rbac-roles';
import { shellRoster } from './dimensions';

// ── 1. THE AUTHORITATIVE SEED ────────────────────────────────────────────────

export interface RouteRow {
  gateway: string;
  pattern: string;
  /** 'PUBLIC' in the SQL, 'ROLE_ANONYMOUS' in the TS mirror — see PUBLIC_ROLES. */
  role: string;
  /** false = an EXPLICIT deny row at this pattern, not merely an absent grant. */
  allow: boolean;
}

/** The SQL spellings of "no Casdoor JWT required". Both are legal; they mean the
 *  same thing and this module never prefers one. */
export const PUBLIC_ROLES = new Set(['PUBLIC', 'ROLE_ANONYMOUS']);

export const SQL_SEED_PATH = path.resolve(
  __dirname, '..', '..', '..',
  'specs', 'cluster', 'manifests', 'route-access', 'initdb', '20-schema.sql',
);

/** The one INSERT tuple grammar: ('gateway', '/pattern', 'ROLE', true|false). */
const ROW_RE = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)/g;

let sqlRowCache: RouteRow[] | undefined;

/**
 * Every gateway_route_access row the initdb seed inserts, parsed — never copied.
 * A copy is how the TS mirror drifted 19 governance rows behind in the first
 * place; this file exists to measure that gap, so it must not create a third
 * divergent list.
 */
export function sqlRouteRows(): RouteRow[] {
  if (sqlRowCache) return sqlRowCache;
  let text: string;
  try {
    text = fs.readFileSync(SQL_SEED_PATH, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the AUTHORITATIVE route-access seed at ${SQL_SEED_PATH}: `
      + `${(e as Error).message}. The governance FUNCTION tier decides against this file, `
      + `so refusing to fall back to specs/rbac-route-access.ts — that mirror is missing `
      + `the moderator, fleet, workload and forum/wiki/owncast governance rows, and a `
      + `silent fallback would turn every one of those into a vacuous DENY that passes.`,
    );
  }
  const out: RouteRow[] = [];
  for (const m of text.matchAll(ROW_RE)) {
    // The file also contains non-route 4-tuples in comments/DDL; a route row is
    // identified by its gateway name, which is the ONLY thing in this file that
    // matches /^hugmesh-.*gateway$/.
    if (!/^hugmesh-[a-z0-9-]*gateway$/.test(m[1])) continue;
    if (!m[2].startsWith('/')) continue;
    out.push({ gateway: m[1], pattern: m[2], role: m[3], allow: m[4] === 'true' });
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO route rows out of ${SQL_SEED_PATH}. The INSERT grammar changed `
      + `(expected ('gateway', '/pattern', 'ROLE', true|false)). Fix this parser rather `
      + `than letting the whole governance FUNCTION matrix decide against an empty table, `
      + `which would make every ALLOW expectation fail and every DENY pass for free.`,
    );
  }
  sqlRowCache = out;
  return out;
}

/** The TS mirror, in the same shape, so one decision engine scores both tables. */
export const TS_MIRROR_ROWS: RouteRow[] = ROUTE_ACCESS.map((r) => ({
  gateway: r.gateway, pattern: r.urlPattern, role: r.role, allow: true,
}));

// ── 2. THE DECISION ENGINE (transcribed; equivalence is EXECUTED, not claimed) ─

/**
 * Line-by-line transcription of `patternMatch` in specs/rbac-route-access.ts.
 * DO NOT "clean this up": the three formulas below (glob = prefix.length * 2
 * AFTER stripping `/**`; '/' = 1; exact = pattern.length * 2 + 1) are the
 * oracle's, and the exact-vs-glob ordering they produce is load-bearing.
 *
 * KNOWN DIVERGENCE, ledgered rather than hidden: the seed carries two
 * mid-wildcard patterns, '/*.js' and '/*.css' (fe-gateway, PUBLIC). Neither the
 * oracle nor this transcription globs them — both treat them as exact literals —
 * so a real Spring gateway admits '/main.js' where both readings deny it. No
 * governance function is probed through them (asserted by
 * governanceCatalogueProblems), so the divergence cannot reach a decision this
 * suite makes.
 */
export function patternScore(pattern: string, p: string): { matched: boolean; specificity: number } {
  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);
    const matched = p === prefix || p.startsWith(prefix + '/');
    return { matched, specificity: matched ? prefix.length * 2 : -1 };
  }
  if (pattern === '/') {
    return { matched: p === '/', specificity: p === '/' ? 1 : -1 };
  }
  const matched = p === pattern;
  return { matched, specificity: matched ? pattern.length * 2 + 1 : -1 };
}

export interface RouteVerdict {
  decision: GatewayDecision;
  /** The url_pattern that won most-specific-wins, or null when nothing matched. */
  pattern: string | null;
  /** Every role on a row at the winning pattern (allow rows only). */
  winningRoles: string[];
  /** Roles carried by an explicit allow=false row at the winning pattern. */
  deniedRoles: string[];
  why: string;
}

/**
 * Decide a request against an arbitrary row table. Mirrors `gatewayDecision`
 * (most-specific pattern wins; OR-of-allow-rows at that pattern; default-deny)
 * and adds the one thing the TS mirror cannot express: an EXPLICIT allow=false
 * row, which the SQL uses as a wall (e.g. fe '/bff/internal/**'). A false row at
 * the winning pattern denies the roles it names even if a true row at the SAME
 * pattern would have admitted them — a wall beats a floor.
 */
export function decideWith(
  rows: readonly RouteRow[], gateway: string, p: string, roles: readonly string[],
): RouteVerdict {
  let best = -1;
  let bestPattern: string | null = null;
  const allowRoles: string[] = [];
  const denyRoles: string[] = [];
  for (const r of rows) {
    if (r.gateway !== gateway) continue;
    const { matched, specificity } = patternScore(r.pattern, p);
    if (!matched) continue;
    if (specificity > best) {
      best = specificity; bestPattern = r.pattern;
      allowRoles.length = 0; denyRoles.length = 0;
    }
    if (specificity === best) (r.allow ? allowRoles : denyRoles).push(r.role);
  }
  if (best < 0) {
    return {
      decision: 'DENY', pattern: null, winningRoles: [], deniedRoles: [],
      why: `no ${gateway} row matches ${p} — default-deny`,
    };
  }
  const held = new Set(roles);
  const walled = denyRoles.filter((r) => held.has(r));
  if (walled.length > 0) {
    return {
      decision: 'DENY', pattern: bestPattern, winningRoles: allowRoles, deniedRoles: denyRoles,
      why: `${gateway} ${bestPattern} carries an EXPLICIT allow=false row for ${walled.join(',')}`,
    };
  }
  const publicRow = allowRoles.find((r) => PUBLIC_ROLES.has(r));
  if (publicRow) {
    return {
      decision: 'ALLOW', pattern: bestPattern, winningRoles: allowRoles, deniedRoles: denyRoles,
      why: `${gateway} ${bestPattern} is ${publicRow} — no JWT required`,
    };
  }
  const hit = allowRoles.filter((r) => held.has(r));
  return {
    decision: hit.length > 0 ? 'ALLOW' : 'DENY',
    pattern: bestPattern, winningRoles: allowRoles, deniedRoles: denyRoles,
    why: hit.length > 0
      ? `${gateway} ${bestPattern} admits ${hit.join(',')}`
      : `${gateway} ${bestPattern} is keyed on ${allowRoles.join('|')}; caller holds `
        + `${[...held].sort().join(',') || '(nothing)'}`,
  };
}

/** Decide against the AUTHORITATIVE SQL seed. This is what the FUNCTION tier uses. */
export function sqlDecision(gateway: string, p: string, roles: readonly string[]): RouteVerdict {
  return decideWith(sqlRouteRows(), gateway, p, roles);
}

// ── 3. THE FUNCTION CATALOGUE ────────────────────────────────────────────────

/** Which console a function belongs to. A persona's console SET is the operator's
 *  real question: "what can THIS person do here". */
export type GovernanceConsole =
  | 'admin' | 'mod' | 'superadmin' | 'fleet' | 'games-admin'
  | 'service-admin' | 'gateway' | 'login';

export const GOVERNANCE_CONSOLES: GovernanceConsole[] = [
  'admin', 'mod', 'superadmin', 'fleet', 'games-admin', 'service-admin', 'gateway', 'login',
];

export interface GovernanceFunction {
  /** Stable id — the exact spelling an Examples cell / a drift-guard row uses. */
  id: string;
  /** What an operator would call the action. */
  name: string;
  console: GovernanceConsole;
  /** The door this function is reached through. */
  gateway: Gateway;
  /** A CONCRETE governed path — the thing a request actually asks for. */
  probePath: string;
  /**
   * The url_pattern in 20-schema.sql that MUST win most-specific-match for
   * probePath. Declared, not derived, so a seed edit that re-homes the probe
   * under a different (possibly weaker) pattern is caught by
   * governanceCatalogueProblems instead of silently changing what is asserted.
   */
  governingPattern: string;
  /**
   * The role-set that the door is keyed on, INDEPENDENTLY hand-declared from the
   * operator's intent. `expectedDecision` uses only this; the SQL decides
   * separately; the matrix asserts the two agree. Two independent encodings
   * disagreeing is the whole signal — do not derive this from the SQL.
   * ['PUBLIC'] means no JWT.
   */
  keyedOn: string[];
  /** true when the function has NO row anywhere and must default-deny for all. */
  defaultDeny?: boolean;
  note: string;
}

export const GOVERNANCE_FUNCTIONS: GovernanceFunction[] = [
  // ── ADMIN CONSOLE — the platform-admin functions (fe '/bff/admin/**') ──────
  {
    id: 'user-approval', name: 'approve a pending registration (allowlist invite)',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/allowlist', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'spec 02/03: an identity registers only after an admin invites it onto the allowlist. '
        + 'e2e-pending and rbac-pending@gmail.com are UNDER TEST in their gated state.',
  },
  {
    id: 'allowlist-manage', name: 'list and revoke allowlist entries',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/allowlist/entries', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'The management half of the same surface (spec 02).',
  },
  {
    id: 'role-assign', name: 'assign or revoke a role on a user',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/roles/ROLE_STICKER_BANNED/assign', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'Driven by spec 28 (sticker moderation grants ROLE_STICKER_BANNED).',
  },
  {
    id: 'feature-ban', name: 'ban a user from one feature',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/users/e2e-matrix/feature-ban', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'The per-feature ban the admin console issues; the MOD equivalent is mod-ban below, '
        + 'and the two are DIFFERENT tiers, not one surface with two names.',
  },
  {
    id: 'namespace-grant', name: 'grant a namespace to a principal',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/namespace-access', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'spec 09 drives this surface through the admin console.',
  },
  {
    id: 'route-access-view', name: 'read the gateway route-access table',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/route-access', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'The console view of the very table this file decides against.',
  },
  {
    id: 'usage-analytics', name: 'read the usage aggregates',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/usage', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'spec 08.',
  },
  {
    id: 'domain-lock', name: 'set the instance-wide domain lock',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/domain-lock', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'The gate spec 23 and features/rbac/domainlock-mod-ban.feature exercise.',
  },
  {
    id: 'image-builds', name: 'list built device images',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/isos', governingPattern: '/bff/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'One of spec 13 ADMIN_GET_ENDPOINTS.',
  },
  {
    id: 'admin-workload-console', name: 'drive the ADMIN half of the workload console',
    console: 'admin', gateway: 'hugmesh-be-gateway',
    probePath: '/bff/admin/workloads/list', governingPattern: '/bff/admin/workloads/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'The be-gateway carries a LONGER pattern for the workload half than the plain '
        + 'admin floor, so it is a distinct row and must be probed as one. Absent from the '
        + 'TS mirror entirely — see TS_MIRROR_LEDGER.',
  },
  {
    id: 'admin-console-ui', name: 'open the admin console UI',
    console: 'admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/admin/usage', governingPattern: '/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'The browser half of discovery+reach (features/rbac/console-access-matrix.feature).',
  },

  // ── MODERATOR CONSOLE — a SIBLING tier, never a subset of admin ───────────
  {
    id: 'mod-console-ui', name: 'open the moderation console UI',
    console: 'mod', gateway: 'hugmesh-fe-gateway',
    probePath: '/mod/console', governingPattern: '/mod/**',
    keyedOn: ['ROLE_MOD', 'ROLE_ADMIN'],
    note: 'ABSENT from the TS mirror, so the pre-existing contract tier cannot decide the '
        + 'moderation console at all — console-access-matrix.feature asserts it in the '
        + 'BROWSER only, which needs a running stack. This row makes it decidable offline.',
  },
  {
    id: 'mod-ban', name: 'ban or unban an identity on a platform',
    console: 'mod', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/mod/ban', governingPattern: '/bff/mod/**',
    keyedOn: ['ROLE_MOD', 'ROLE_ADMIN'],
    note: 'The surface features/rbac/domainlock-mod-ban.feature drives live. ABSENT from the '
        + 'TS mirror.',
  },
  {
    id: 'mod-findings', name: 'read and resolve the moderation findings queue',
    console: 'mod', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/mod/findings', governingPattern: '/bff/mod/**',
    keyedOn: ['ROLE_MOD', 'ROLE_ADMIN'],
    note: 'features/moderation-media/ drives this live; ABSENT from the TS mirror.',
  },
  {
    id: 'mod-audit', name: 'read the moderation audit log',
    console: 'mod', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/mod/audit', governingPattern: '/bff/mod/**',
    keyedOn: ['ROLE_MOD', 'ROLE_ADMIN'],
    note: 'ABSENT from the TS mirror.',
  },
  {
    id: 'akkoma-moderation', name: 'drive akkoma/Mastodon moderation REST',
    console: 'mod', gateway: 'hugmesh-be-gateway',
    probePath: '/api/v1/pleroma/admin/config', governingPattern: '/api/v1/pleroma/admin/**',
    keyedOn: ['ROLE_MOD', 'ROLE_ADMIN'],
    note: 'The one moderator surface the TS mirror DOES carry (gateway-route-access.feature).',
  },

  // ── FLEET — ROLE_FLEET_ADMIN, a tier the TS mirror cannot express at all ──
  {
    id: 'fleet-phone-console', name: 'act on the phone fleet (fleet owner console)',
    console: 'fleet', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/admin/phone-fleet/devices', governingPattern: '/bff/admin/phone-fleet/**',
    keyedOn: ['ROLE_FLEET_ADMIN', 'ROLE_ADMIN', 'ROLE_SUPERADMIN'],
    note: 'The ONLY row in the whole seed keyed on ROLE_FLEET_ADMIN, and the reason the '
        + 'e2e-fleet persona exists (docs/MFA-ROLLOUT.md §3.1). ROLE_FLEET_ADMIN appears in '
        + 'ZERO rows of the TS mirror, so this function is un-assertable there: e2e-fleet '
        + 'would default-deny and the DENY would pass for the wrong reason.',
  },

  // ── SUPERADMIN — a DISTINCT tier; admin must NOT inherit it ───────────────
  {
    id: 'superadmin-service-catalog', name: 'curate the superadmin service catalog',
    console: 'superadmin', gateway: 'hugmesh-superadmin-gateway',
    probePath: '/bff/superadmin/service-store/catalog', governingPattern: '/bff/superadmin/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'The App-Store control plane on the tailnet-only gateway.',
  },
  {
    id: 'superadmin-catalog-remote', name: 'load the service-catalog federated remote',
    console: 'superadmin', gateway: 'hugmesh-superadmin-gateway',
    probePath: '/superadmin/service-catalog/remoteEntry.js',
    governingPattern: '/superadmin/service-catalog/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'The UI half of the same console.',
  },
  {
    id: 'superadmin-backing-services', name: 'read the backing-service views',
    console: 'superadmin', gateway: 'hugmesh-be-gateway',
    probePath: '/bff/superadmin/optional-services/state', governingPattern: '/bff/superadmin/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'The optional/backing service state the superadmin console renders. ABSENT from '
        + 'the TS mirror on this gateway.',
  },
  {
    id: 'superadmin-fleet-entitlements', name: 'grant a fleet entitlement',
    console: 'superadmin', gateway: 'hugmesh-be-gateway',
    probePath: '/bff/superadmin/fleet-entitlements/list', governingPattern: '/bff/superadmin/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'The superadmin half of the fleet story: a FLEET owner drives its own devices, only '
        + 'a SUPERADMIN grants the entitlement. Two tiers, one story.',
  },
  {
    id: 'superadmin-phone-devices', name: 'reassign a phone device owner',
    console: 'superadmin', gateway: 'hugmesh-be-gateway',
    probePath: '/bff/superadmin/phone-devices', governingPattern: '/bff/superadmin/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'ABSENT from the TS mirror on this gateway.',
  },
  {
    id: 'superadmin-workload-console', name: 'drive the SUPERADMIN half of the workload console',
    console: 'superadmin', gateway: 'hugmesh-be-gateway',
    probePath: '/bff/superadmin/workloads/exec', governingPattern: '/bff/superadmin/workloads/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'Cross-cluster read + RUNTIME_MUTATE/exec/port-forward. A LONGER pattern than the '
        + 'superadmin floor, so a distinct row. ABSENT from the TS mirror.',
  },
  {
    id: 'superadmin-games-services', name: 'curate the games app-store catalog',
    console: 'superadmin', gateway: 'hugmesh-be-gateway',
    probePath: '/bff/superadmin/games-services/catalog',
    governingPattern: '/bff/superadmin/games-services/**',
    keyedOn: ['ROLE_SUPERADMIN'],
    note: 'Global catalog + per-domain offers. ABSENT from the TS mirror.',
  },

  // ── GAMES-ADMIN — the DERIVED intersection tier ──────────────────────────
  {
    id: 'games-admin-console', name: 'open the games-namespace admin console',
    console: 'games-admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/games/admin/sessions', governingPattern: '/games/admin/**',
    keyedOn: ['ROLE_GAMES_ADMIN'],
    note: 'Keyed on the DERIVED role alone: neither ROLE_GAMES nor ROLE_ADMIN admits it.',
  },
  {
    id: 'games-admin-api', name: 'call the games-namespace admin API',
    console: 'games-admin', gateway: 'hugmesh-be-gateway',
    probePath: '/games/api/admin/role-grants', governingPattern: '/games/api/admin/**',
    keyedOn: ['ROLE_GAMES_ADMIN'],
    note: 'The API half of the same gate.',
  },

  // ── PER-SERVICE ADMIN/MOD — the surfaces only the SQL knows about ────────
  {
    id: 'forum-admin', name: 'administer the forum',
    console: 'service-admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/forum/admin/settings', governingPattern: '/bff/forum/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'ABSENT from the TS mirror.',
  },
  {
    id: 'forum-moderation', name: 'moderate the forum',
    console: 'service-admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/forum/moderation/queue', governingPattern: '/bff/forum/moderation/**',
    keyedOn: ['ROLE_FORUM_MOD'],
    note: 'A per-service moderator tier: the NETWORK moderator (ROLE_MOD) does NOT hold it, '
        + 'and no seeded persona does either — so this row is currently unreachable by every '
        + 'catalogued identity, which is itself the assertion.',
  },
  {
    id: 'wiki-admin', name: 'administer the wiki',
    console: 'service-admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/wiki/admin/settings', governingPattern: '/bff/wiki/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'ABSENT from the TS mirror.',
  },
  {
    id: 'owncast-admin', name: 'administer the live stream',
    console: 'service-admin', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/owncast/admin/config', governingPattern: '/bff/owncast/admin/**',
    keyedOn: ['ROLE_ADMIN'],
    note: 'ABSENT from the TS mirror.',
  },

  // ── GATEWAY / LOGIN SURFACES ─────────────────────────────────────────────
  {
    id: 'login-front-door', name: 'post credentials at the login front door',
    console: 'login', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/login', governingPattern: '/bff/login',
    keyedOn: ['PUBLIC'],
    note: 'The one governance-adjacent surface that must admit EVERY persona, banned and '
        + 'un-onboarded included — the gate is what happens after, not at the door.',
  },
  {
    id: 'internal-bff-wall', name: 'reach an INTERNAL bff path from outside',
    console: 'gateway', gateway: 'hugmesh-fe-gateway',
    probePath: '/bff/internal/reconcile', governingPattern: '/bff/internal/**',
    keyedOn: [],
    note: 'An EXPLICIT allow=false row — a WALL, not an absent grant. Nobody reaches it, '
        + 'admin and superadmin included, and the reason must be the deny row rather than '
        + 'default-deny. The TS mirror cannot express an allow=false row at all.',
  },
  {
    id: 'unrouted-infra', name: 'reach a path with no route row at all',
    console: 'gateway', gateway: 'hugmesh-be-gateway',
    probePath: '/infra/logs', governingPattern: '(none)',
    keyedOn: [], defaultDeny: true,
    note: 'Default-deny, asserted as a property: no persona reaches it, and the winning '
        + 'pattern must be null rather than some over-broad glob quietly swallowing it.',
  },
];

const FN_BY_ID = new Map(GOVERNANCE_FUNCTIONS.map((f) => [f.id, f]));

export function governanceFunctionIds(): string[] {
  return GOVERNANCE_FUNCTIONS.map((f) => f.id);
}

export function governanceFunction(id: string): GovernanceFunction {
  const f = FN_BY_ID.get(id);
  if (!f) {
    throw new Error(
      `unknown governance function '${id}'. Legal ids (steps/governance.ts `
      + `GOVERNANCE_FUNCTIONS): ${governanceFunctionIds().join(', ')}. Add the function to `
      + `the catalogue — never spell a governed path inline in a .feature, because a typo `
      + `there resolves to default-deny and every DENY row passes for free.`,
    );
  }
  return f;
}

export function functionsForConsole(c: string): GovernanceFunction[] {
  if (!GOVERNANCE_CONSOLES.includes(c as GovernanceConsole)) {
    throw new Error(
      `unknown governance console '${c}'. Legal consoles: ${GOVERNANCE_CONSOLES.join(', ')}.`,
    );
  }
  return GOVERNANCE_FUNCTIONS.filter((f) => f.console === c);
}

// ── 4. THE PERSONA SIDE ──────────────────────────────────────────────────────

export type PersonaOrigin = 'ts-catalogue' | 'shell-roster' | 'both';

export interface GovernancePersona {
  handle: string;
  /** EFFECTIVE roles: granted + the derived ROLE_GAMES_ADMIN when it qualifies. */
  roles: string[];
  origin: PersonaOrigin;
  /** true for the three deliberately un-onboarded/gated identities. */
  gated: boolean;
  note: string;
}

/** The intersection rule games-admin-sync materialises (schema.sql header):
 *  ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD). Applied to shell-roster personas, which
 *  carry no expectGamesAdmin flag of their own. */
export function derivesGamesAdmin(roles: readonly string[]): boolean {
  return roles.includes('ROLE_GAMES')
      && (roles.includes('ROLE_ADMIN') || roles.includes('ROLE_MOD'));
}

/** The three identities that are UNDER TEST in their gated state. Never "fixed". */
export const GATED_PERSONAS = ['e2e-pending', 'rbac-pending@gmail.com', 'e2e-banned'];

let personaCache: GovernancePersona[] | undefined;

/**
 * Every persona EITHER seeder creates, with its effective role-set — the union,
 * not the TypeScript catalogue alone. This is the coverage expansion: the
 * pre-existing contract tier can only decide about the 17 handles in
 * SYSTEMS_SEED_USERS, and refuses (correctly, loudly) for the 14 shell-roster-only
 * ones — including e2e-fleet, the ONLY ROLE_FLEET_ADMIN holder in the mesh.
 */
export function governancePersonas(): GovernancePersona[] {
  if (personaCache) return personaCache;
  const byHandle = new Map<string, GovernancePersona>();
  for (const u of SYSTEMS_SEED_USERS) {
    byHandle.set(u.username, {
      handle: u.username,
      roles: [...effectiveRoles(u.roles, u.expectGamesAdmin)].sort(),
      origin: 'ts-catalogue',
      gated: GATED_PERSONAS.includes(u.username),
      note: u.note ?? '',
    });
  }
  for (const p of shellRoster()) {
    const roles = [...new Set(
      derivesGamesAdmin(p.roles) ? [...p.roles, 'ROLE_GAMES_ADMIN'] : p.roles,
    )].sort();
    const existing = byHandle.get(p.username);
    if (existing) {
      existing.origin = 'both';
      // Divergence between the two seeders is NOT reconciled here — it is
      // reported by personaCatalogueProblems(). Silently preferring one source
      // is how three divergent persona lists happened in the first place.
      continue;
    }
    byHandle.set(p.username, {
      handle: p.username, roles, origin: 'shell-roster',
      gated: GATED_PERSONAS.includes(p.username),
      note: 'shell-roster only (tests/e2e-extra-personas.sh)',
    });
  }
  // ONE representative per swarm tier — see swarmMembersNotCoveredByRepresentative
  // for why the other 123 are excluded and what proves that exclusion is safe.
  for (const r of swarmRepresentatives()) {
    if (byHandle.has(r.handle)) continue;
    byHandle.set(r.handle, {
      handle: r.handle, roles: r.roles, origin: 'ts-catalogue', gated: false,
      note: `swarm ${r.tier} tier representative — stands for `
          + `${swarmTierSizes()[r.tier]} identically-roled identities`,
    });
  }
  personaCache = [...byHandle.values()].sort((a, b) => a.handle.localeCompare(b.handle));
  return personaCache;
}

export function governancePersona(handle: string): GovernancePersona {
  const p = governancePersonas().find((x) => x.handle === handle);
  if (!p) {
    throw new Error(
      `unknown governance persona '${handle}'. Legal handles (${governancePersonas().length}): `
      + `${governancePersonas().map((x) => x.handle).join(', ')}.`,
    );
  }
  return p;
}

/** Where the two seeders disagree about a shared handle's roles. Empty is healthy. */
export function personaCatalogueProblems(): string[] {
  const problems: string[] = [];
  for (const p of shellRoster()) {
    const ts = SYSTEMS_SEED_USERS.find((u) => u.username === p.username);
    if (!ts) continue;
    const a = [...new Set(ts.roles)].sort().join(',');
    const b = [...new Set(p.roles)].sort().join(',');
    if (a !== b) {
      problems.push(
        `persona '${p.username}' is seeded by BOTH lanes with DIFFERENT roles: `
        + `specs/rbac-roles.ts says [${a}], tests/e2e-extra-personas.sh says [${b}]. `
        + `Whichever seeder ran last wins at run time, so every governance decision about `
        + `this identity depends on the lane.`,
      );
    }
  }
  return problems;
}

/**
 * The swarm population (seed-accounts.sh --swarm) is 120 plain users + 4 mods +
 * 2 admins. Expanding all 126 into the matrix would be 126 identical role-sets —
 * 4158 fabricated decisions that restate three facts. So exactly ONE
 * REPRESENTATIVE per swarm TIER joins the persona set (see governancePersonas),
 * and the exclusion of the other 123 is only legitimate if each of them has the
 * same effective role-set as its representative. This returns the members for
 * which that is NOT true — i.e. the coverage the shortcut would actually lose.
 *
 * The shortcut is NOT free and was not assumed: measured on this tree, all three
 * swarm tiers carry role-sets NO other seeded persona has (the swarm user holds
 * ROLE_MATRIX *and* ROLE_MASTODON together, which no e2e-* persona does), so
 * dropping the swarm entirely — the obvious move — would have silently lost
 * three whole role-classes from the matrix.
 */
export function swarmMembersNotCoveredByRepresentative(): string[] {
  const reps = new Map<string, string>();
  for (const r of swarmRepresentatives()) reps.set(r.tier, r.roles.join(','));
  const out: string[] = [];
  for (const m of generateSwarm()) {
    const key = [...new Set(effectiveRoles(m.roles, m.expectGamesAdmin))].sort().join(',');
    const rep = reps.get(m.swarmTier);
    if (rep === undefined) { out.push(`${m.username}: swarm tier '${m.swarmTier}' has no representative`); continue; }
    if (rep !== key) {
      out.push(
        `${m.username} (tier ${m.swarmTier}) holds [${key}] but the tier representative holds `
        + `[${rep}] — the representative no longer stands for it, so excluding this member `
        + `from the matrix drops real coverage`,
      );
    }
  }
  return out;
}

export interface SwarmRepresentative { tier: string; handle: string; roles: string[]; }

/** The first member of each swarm tier, deterministically. */
export function swarmRepresentatives(): SwarmRepresentative[] {
  const byTier = new Map<string, SwarmRepresentative>();
  for (const m of generateSwarm()) {
    if (byTier.has(m.swarmTier)) continue;
    byTier.set(m.swarmTier, {
      tier: m.swarmTier, handle: m.username,
      roles: [...new Set(effectiveRoles(m.roles, m.expectGamesAdmin))].sort(),
    });
  }
  return [...byTier.values()];
}

/** How many identities each representative stands for. Reported, never assumed. */
export function swarmTierSizes(): Record<string, number> {
  const out: Record<string, number> = {};
  for (const m of generateSwarm()) out[m.swarmTier] = (out[m.swarmTier] ?? 0) + 1;
  return out;
}

// ── 5. THE EXPECTATION, INDEPENDENTLY DECLARED ───────────────────────────────

/**
 * What the catalogue SAYS should happen, computed only from `keyedOn` — never
 * from the route table. The matrix asserts this against `sqlDecision`, so the
 * two encodings (an operator's statement of intent, and the shipped seed) must
 * agree for every persona x function pair. That is the non-tautological core:
 * a seed edit that widens or narrows a governance door disagrees with the
 * catalogue and the matrix goes red naming the pair.
 */
export function expectedDecision(fn: GovernanceFunction, roles: readonly string[]): GatewayDecision {
  if (fn.keyedOn.some((r) => PUBLIC_ROLES.has(r))) return 'ALLOW';
  if (fn.keyedOn.length === 0) return 'DENY';   // wall, or no row at all
  return fn.keyedOn.some((r) => roles.includes(r)) ? 'ALLOW' : 'DENY';
}

export interface MatrixCell {
  persona: string;
  fn: string;
  console: GovernanceConsole;
  expected: GatewayDecision;
  actual: GatewayDecision;
  verdict: RouteVerdict;
}

/** The whole persona x function matrix, decided. This is the generative output. */
export function governanceMatrix(): MatrixCell[] {
  const out: MatrixCell[] = [];
  for (const p of governancePersonas()) {
    for (const fn of GOVERNANCE_FUNCTIONS) {
      const verdict = sqlDecision(fn.gateway, fn.probePath, p.roles);
      out.push({
        persona: p.handle, fn: fn.id, console: fn.console,
        expected: expectedDecision(fn, p.roles), actual: verdict.decision, verdict,
      });
    }
  }
  return out;
}

// ── 6. CATALOGUE SELF-CHECKS ─────────────────────────────────────────────────

/**
 * Everything that would make the catalogue LIE, checked against the seed. A
 * catalogue that names a pattern the seed no longer carries would keep deciding —
 * against whatever weaker pattern happens to win — and the matrix would stay
 * green while asserting something else entirely.
 */
export function governanceCatalogueProblems(): string[] {
  const problems: string[] = [];
  const rows = sqlRouteRows();
  const seenIds = new Set<string>();
  const seenProbes = new Set<string>();

  for (const fn of GOVERNANCE_FUNCTIONS) {
    if (seenIds.has(fn.id)) problems.push(`duplicate governance function id '${fn.id}'`);
    seenIds.add(fn.id);

    const probeKey = `${fn.gateway} ${fn.probePath}`;
    if (seenProbes.has(probeKey)) {
      problems.push(
        `two governance functions probe the SAME door (${probeKey}) — one of them is not `
        + `testing what its name claims`,
      );
    }
    seenProbes.add(probeKey);

    // The probe must actually be governed by the pattern the catalogue declares.
    const v = decideWith(rows, fn.gateway, fn.probePath, []);
    if (fn.defaultDeny) {
      if (v.pattern !== null) {
        problems.push(
          `'${fn.id}' claims NO route row governs ${fn.gateway} ${fn.probePath}, but the seed `
          + `matches '${v.pattern}' — the default-deny property it asserts is no longer true`,
        );
      }
    } else if (v.pattern !== fn.governingPattern) {
      problems.push(
        `'${fn.id}' declares governingPattern '${fn.governingPattern}' for ${fn.gateway} `
        + `${fn.probePath}, but most-specific-match in 20-schema.sql wins with `
        + `'${v.pattern ?? '(no row)'}'`,
      );
    }

    // Mid-wildcard patterns are a KNOWN divergence from a real Spring gateway;
    // no governance decision may depend on one.
    if (v.pattern && /\*/.test(v.pattern) && !v.pattern.endsWith('/**')) {
      problems.push(
        `'${fn.id}' is decided by the mid-wildcard pattern '${v.pattern}', which this suite `
        + `(and specs/rbac-route-access.ts) treats as an exact literal — a real Spring `
        + `gateway would glob it, so the decision is not trustworthy`,
      );
    }

    // The declared keying must match the seed's rows at the winning pattern.
    if (!fn.defaultDeny) {
      const at = rows.filter((r) => r.gateway === fn.gateway && r.pattern === fn.governingPattern);
      if (at.length === 0) {
        problems.push(`'${fn.id}': 20-schema.sql carries NO row at ${fn.gateway} ${fn.governingPattern}`);
      }
      const seedAllow = [...new Set(at.filter((r) => r.allow).map((r) => r.role))].sort();
      const declared = [...new Set(fn.keyedOn)].sort();
      const isWall = at.length > 0 && at.every((r) => !r.allow);
      if (isWall) {
        if (declared.length !== 0) {
          problems.push(
            `'${fn.id}' declares keyedOn [${declared.join(',')}] but ${fn.governingPattern} is `
            + `an EXPLICIT allow=false WALL in the seed — nobody is admitted`,
          );
        }
      } else if (seedAllow.join(',') !== declared.join(',')) {
        problems.push(
          `'${fn.id}' declares keyedOn [${declared.join(',')}] but 20-schema.sql keys `
          + `${fn.gateway} ${fn.governingPattern} on [${seedAllow.join(',')}]`,
        );
      }
    }
  }
  return problems;
}

// ── 7. THE TS-MIRROR LEDGER — a named finding, not a silent pass ─────────────

export interface MirrorGap {
  gateway: string;
  pattern: string;
  roles: string[];
  /** Which catalogued function ids become un-assertable in the TS mirror. */
  functions: string[];
}

/**
 * Every (gateway, pattern) the AUTHORITATIVE seed governs that a catalogued
 * function depends on and specs/rbac-route-access.ts does NOT carry. Computed,
 * never hand-listed — a hand list rots the moment the mirror is widened, and a
 * rotted ledger is worse than none because it reads as a checked claim.
 *
 * These are why the FUNCTION tier decides against the SQL: in the mirror each of
 * these patterns is simply absent, so every persona default-denies and every
 * DENY expectation passes without testing anything.
 */
export function tsMirrorGaps(): MirrorGap[] {
  const rows = sqlRouteRows();
  const gaps = new Map<string, MirrorGap>();
  for (const fn of GOVERNANCE_FUNCTIONS) {
    if (fn.defaultDeny) continue;
    const key = `${fn.gateway} ${fn.governingPattern}`;
    const inMirror = TS_MIRROR_ROWS.some(
      (r) => r.gateway === fn.gateway && r.pattern === fn.governingPattern,
    );
    if (inMirror) continue;
    const roles = [...new Set(
      rows.filter((r) => r.gateway === fn.gateway && r.pattern === fn.governingPattern && r.allow)
          .map((r) => r.role),
    )].sort();
    const g = gaps.get(key) ?? { gateway: fn.gateway, pattern: fn.governingPattern, roles, functions: [] };
    g.functions.push(fn.id);
    gaps.set(key, g);
  }
  return [...gaps.values()].sort((a, b) => (a.gateway + a.pattern).localeCompare(b.gateway + b.pattern));
}

/**
 * The reverse direction: a (gateway, pattern, role) the TS mirror grants that the
 * SQL seed does NOT. This is the DANGEROUS direction — a mirror that grants more
 * than the shipped table makes an ALLOW expectation pass on a door that is really
 * shut, so the suite would certify access the mesh refuses. Empty is the only
 * acceptable answer, and there is no ledger for it.
 */
export function mirrorGrantsTheSeedDoesNot(): string[] {
  const rows = sqlRouteRows();
  const out: string[] = [];
  for (const m of TS_MIRROR_ROWS) {
    const sqlRole = PUBLIC_ROLES.has(m.role) ? null : m.role;
    const match = rows.some((r) =>
      r.gateway === m.gateway && r.pattern === m.pattern && r.allow
      && (sqlRole === null ? PUBLIC_ROLES.has(r.role) : r.role === sqlRole));
    if (!match) {
      out.push(
        `specs/rbac-route-access.ts grants ${m.gateway} ${m.pattern} -> ${m.role}, which `
        + `20-schema.sql does NOT — an ALLOW asserted through the mirror would certify a `
        + `door the shipped seed keeps shut`,
      );
    }
  }
  return out;
}

// ── 8. THE ENGINE-EQUIVALENCE CORPUS ─────────────────────────────────────────

/**
 * Every (gateway, path, role-set) triple worth scoring to prove `decideWith` and
 * the exported `gatewayDecision` are the same function over the mirror's own row
 * set. Paths are derived from the mirror's patterns — the literal prefix, a child
 * of it, a SIBLING that merely shares a textual prefix (the `/admin` vs
 * `/administrator` trap) and the pattern text itself — so the corpus grows with
 * the table instead of being a fixed sample.
 */
/**
 * THE ONE ORDERING CASE THE MIRROR CANNOT PRODUCE BY ITSELF.
 *
 * MEASURED, not theorised: the corpus below was run against a DELIBERATELY
 * mis-transcribed patternScore (glob scored from the UNSTRIPPED pattern, which
 * is exactly the bug fix/superadmin-route-access-row found) and it stayed GREEN.
 * The reason is that the mis-scoring adds a constant +6 to EVERY glob, so the
 * ordering among globs is unchanged; it only inverts EXACT-vs-GLOB — and
 * specs/rbac-route-access.ts's 50 rows happen to contain no path where an exact
 * pattern and a glob both match. The seed does (`/api/federation/vanity` beside
 * `/api/federation/vanity/**`); the mirror does not.
 *
 * So the collision is MANUFACTURED, inside the oracle's own table, for the
 * duration of one assertion. Each pair is an exact row and a glob that both
 * match one path and carry DIFFERENT roles, so the two readings cannot agree by
 * accident: the correct one lets the exact row win, the mis-scored one lets the
 * glob win, and the caller's role-set decides differently under each.
 */
export const COLLISION_PROBE_ROWS: RouteRow[] = [
  // fe: the mirror already has EXACT '/bff/login' -> ROLE_ANONYMOUS. A glob at
  // '/bff/login/**' also matches '/bff/login' (Spring's `/**` matches the prefix
  // itself), so the two collide on that one path.
  { gateway: 'hugmesh-fe-gateway', pattern: '/bff/login/**', role: 'ROLE_SUPERADMIN', allow: true },
  // be: the live seed collision, reproduced in the mirror.
  { gateway: 'hugmesh-be-gateway', pattern: '/api/federation/vanity', role: 'ROLE_USER', allow: true },
  { gateway: 'hugmesh-be-gateway', pattern: '/api/federation/vanity/**', role: 'ROLE_SUPERADMIN', allow: true },
];

/** The triples that exercise those collisions, and only those. */
export function collisionCorpus(): { gateway: Gateway; path: string; roles: string[] }[] {
  const out: { gateway: Gateway; path: string; roles: string[] }[] = [];
  for (const roles of [[], ['ROLE_USER'], ['ROLE_SUPERADMIN'], ['ROLE_ADMIN', 'ROLE_USER']]) {
    out.push({ gateway: 'hugmesh-fe-gateway', path: '/bff/login', roles });
    out.push({ gateway: 'hugmesh-fe-gateway', path: '/bff/login/callback', roles });
    out.push({ gateway: 'hugmesh-be-gateway', path: '/api/federation/vanity', roles });
    out.push({ gateway: 'hugmesh-be-gateway', path: '/api/federation/vanity/x', roles });
  }
  return out;
}

/**
 * Run `body` with COLLISION_PROBE_ROWS temporarily appended to the oracle's own
 * ROUTE_ACCESS table, so `gatewayDecision` and `decideWith` are scoring the SAME
 * colliding rows. Restored in a `finally`, and the restore is by RECORDED LENGTH
 * rather than by popping a count, so a throw mid-body cannot leave the shared
 * table polluted for the next scenario in the worker.
 *
 * TS_MIRROR_ROWS is a load-time SNAPSHOT and is deliberately NOT rebuilt from
 * this: the gap/over-grant ledgers must always describe the real mirror, never a
 * mirror this probe widened.
 */
export function withOracleCollisionRows<T>(body: (rows: RouteRow[]) => T): T {
  const originalLength = ROUTE_ACCESS.length;
  for (const r of COLLISION_PROBE_ROWS) {
    ROUTE_ACCESS.push({ gateway: r.gateway as Gateway, urlPattern: r.pattern, role: r.role });
  }
  try {
    return body(ROUTE_ACCESS.map((r) => ({
      gateway: r.gateway, pattern: r.urlPattern, role: r.role, allow: true,
    })));
  } finally {
    ROUTE_ACCESS.length = originalLength;
  }
}

export function equivalenceCorpus(): { gateway: Gateway; path: string; roles: string[] }[] {
  const gateways = [...new Set(TS_MIRROR_ROWS.map((r) => r.gateway))] as Gateway[];
  const paths = new Set<string>(['/', '/infra/logs', '/administrator', '/admin']);
  for (const r of TS_MIRROR_ROWS) {
    const base = r.pattern.endsWith('/**') ? r.pattern.slice(0, -3) : r.pattern;
    paths.add(base || '/');
    paths.add(`${base}/child`);
    paths.add(`${base}x`);
    paths.add(r.pattern);
  }
  const roleSets: string[][] = [
    [],
    ['ROLE_USER'],
    ['ROLE_ADMIN', 'ROLE_USER'],
    ['ROLE_MOD'],
    ['ROLE_SUPERADMIN'],
    ['ROLE_GAMES', 'ROLE_USER'],
    ['ROLE_GAMES', 'ROLE_ADMIN', 'ROLE_USER', 'ROLE_GAMES_ADMIN'],
    ['ROLE_MATRIX', 'ROLE_USER'],
    ['ROLE_MASTODON', 'ROLE_USER'],
    ['ROLE_FLEET_ADMIN', 'ROLE_USER'],
  ];
  const out: { gateway: Gateway; path: string; roles: string[] }[] = [];
  for (const g of gateways) for (const p of paths) for (const roles of roleSets) {
    out.push({ gateway: g, path: p, roles });
  }
  return out;
}
