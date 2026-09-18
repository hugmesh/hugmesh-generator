// mined-platform-edge.steps.ts — step definitions for the M5 PLATFORM EDGE
// domain: the fe/be/pki/superadmin gateway route-access contract, the two fe
// route tables (compose + cluster), the module-federation fragment fleet, and
// the CSP/nonce chain the committed UI archetypes ship.
//
// WHY THIS FILE EXISTS. tests/e2e/specs/rbac-route-access.ts calls itself "the
// authoritative gateway_route_access matrix". It is not: it is a HAND COPY of
// 50 of the seed's 150 rows, written before the gateways existed, and it
// disagrees with the seed in three ways that each change what "the front door
// is open" means:
//
//   1. ROLE NAME. The oracle grants the public floor to 'ROLE_ANONYMOUS'.
//      The seed emits that string ZERO times; the public role is 'PUBLIC'
//      (GatewayRouteAccessService.PUBLIC_ROLE). Measured here, not assumed:
//      exactly 5 oracle rows are absent from the seed, and all 5 are the
//      ROLE_ANONYMOUS rows whose seed counterpart is the same
//      (gateway, url_pattern) carrying role PUBLIC.
//   2. EXPLICIT DENY. The oracle's Row type has no `allow` field, so the seed's
//      four allow=false rows — the SERVICE-only ingest surfaces that are
//      permitAll app-side, i.e. the ones where the gateway is the ONLY thing in
//      front of them — cannot be expressed in it at all.
//   3. UNGOVERNED vs DENIED. The oracle collapses "no pattern matched" into
//      DENY. The real gate returns NO_RULE and falls through to the coarse
//      authenticated() floor. Those are different postures and a suite that
//      cannot tell them apart cannot describe the gate.
//
// So this file reads the SEED as the authority and evaluates it with a decision
// function that mirrors GatewayRouteAccessService.decide() — longest-url_pattern
// wins by raw pattern-string length, explicit deny wins among the winners,
// PUBLIC admits with no roles, no match at all is NO_RULE. The oracle is then
// RECONCILED against the seed rather than trusted.
//
// EVERYTHING BELOW READS A FILE COMMITTED TO THIS REPO. That constraint is the
// same one uncovered-services.steps.ts states and it is load-bearing: a step
// that reached into a sibling checkout (/home/magus/Github/hugmesh-gateway,
// .../hugmesh-host-shell) would pass on the box where those clones happen to
// exist and fail in CI, which is strictly worse than not asserting at all. It
// is also why several mined claims about the gateway's Java source and about
// the 20 per-UI nginx.conf files are NOT encoded here — see the unit report.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import { Given, When, Then } from './world';
import { ROUTE_ACCESS } from '../specs/rbac-route-access';

/** Repo root — steps/ is tests/e2e/steps, so three levels up. */
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

const ROUTE_ACCESS_SQL = 'specs/cluster/manifests/route-access/initdb/20-schema.sql';
const FE_ROUTES_COMPOSE = 'tests/stack/gateway-routes/fe/application-routes.yml';
const FE_ROUTES_CLUSTER = 'specs/cluster/apps/20-gateway-fe.yaml';
const FRAGMENT_NGINX = 'specs/cluster/manifests/remote-fragment/nginx.conf';
const FRAGMENT_DEPLOY = 'specs/cluster/manifests/remote-fragment/deployment.yaml';
const NGINX_TEMPLATES: Record<string, string> = {
  'angular-host': 'templates/archetypes/angular-host/_skeleton/nginx.conf.hbs',
  'angular-mfe': 'templates/archetypes/angular-mfe/_skeleton/nginx.conf.hbs',
};

/** Read a committed artefact, or fail naming the absolute path AND why this
 *  domain depends on it. A missing source must never degrade into a soft skip
 *  that leaves the contract unasserted. */
function readRepoFile(rel: string): string {
  const abs = path.join(REPO_ROOT, rel);
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the committed artefact ${abs}: ${(e as Error).message}. The platform-edge `
      + `contract features assert the AGREEMENT between the route-access seed, the two fe `
      + `route tables and the committed nginx artefacts; refusing to pass without reading it.`,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 1. THE ROUTE-ACCESS SEED — parsed, matched and decided the way the gateway does
// ═════════════════════════════════════════════════════════════════════════════

export interface SeedRow {
  gateway: string;
  pattern: string;
  role: string;
  allow: boolean;
}

let seedCache: SeedRow[] | undefined;

/** Parse the `('<gateway>', '<url_pattern>', '<ROLE>', <allow>)` tuples out of
 *  the committed seed. Same grammar uncovered-services.steps.ts reads, kept
 *  deliberately identical so the two domains cannot disagree about what a row is. */
function seedRows(): SeedRow[] {
  if (seedCache) return seedCache;
  const re = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)/g;
  const out: SeedRow[] = [];
  for (const m of readRepoFile(ROUTE_ACCESS_SQL).matchAll(re)) {
    out.push({ gateway: m[1], pattern: m[2], role: m[3], allow: m[4] === 'true' });
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO route-access rows out of ${ROUTE_ACCESS_SQL}. The seed's INSERT shape `
      + `changed — fix this parser; an empty table makes every assertion here vacuous.`,
    );
  }
  seedCache = out;
  return out;
}

/**
 * Translate one Spring `AntPathMatcher` url_pattern into a RegExp.
 *
 * SCOPE, STATED HONESTLY. This covers the three constructs the seed's 150
 * patterns actually use and no more: `**` (zero or more whole segments), `*`
 * (zero or more characters WITHIN one segment) and `?` (one character within one
 * segment). It is not a general AntPathMatcher — `{var}` templates and
 * `**` in a non-terminal position with a suffix are not exercised by the seed and
 * are not claimed here.
 *
 * The single-star case is the one the oracle cannot do at all: the seed grants
 * the anonymous SPA shell through `/*.js` and `/*.css`, and
 * rbac-route-access.ts's patternMatch() treats any pattern without a `/**`
 * suffix as an EXACT path, so `/*.js` there matches literally nothing a browser
 * ever requests. `/main-ABC123.js` must match; `/assets/vendor.js` must not.
 */
function antRegex(pattern: string): RegExp {
  const escapeLiteral = (c: string): string => (
    /[.+^${}()|[\]\\]/.test(c) ? `\\${c}` : c
  );
  let body = '';
  const src = pattern.endsWith('/**') ? pattern.slice(0, -3) : pattern;
  for (let i = 0; i < src.length; i += 1) {
    const c = src[i];
    if (c === '*') {
      if (src[i + 1] === '*') { body += '.*'; i += 1; } else { body += '[^/]*'; }
    } else if (c === '?') {
      body += '[^/]';
    } else {
      body += escapeLiteral(c);
    }
  }
  // `/foo/**` matches `/foo` itself as well as any subpath — Spring's behaviour,
  // and the reason `/bff/**` governs a bare `/bff`.
  if (pattern.endsWith('/**')) body += '(?:/.*)?';
  return new RegExp(`^${body}$`);
}

function patternMatches(pattern: string, requestPath: string): boolean {
  return antRegex(pattern).test(requestPath);
}

export type SeedDecision = 'ALLOW' | 'DENY' | 'NO_RULE';

interface SeedVerdict {
  decision: SeedDecision;
  /** The url_pattern(s) that won the longest-match, for the failure message. */
  winning: string[];
}

/**
 * The decision the SEEDED table dictates, mirroring
 * GatewayRouteAccessService.decide():
 *
 *   1. longest matching url_pattern wins, measured as the RAW PATTERN STRING
 *      LENGTH (not the literal prefix — the Java is `r.urlPattern().length()`,
 *      and copying its exact tie-break is the point of mirroring at all);
 *   2. no matching pattern at all  =>  NO_RULE — an UNGOVERNED path, which the
 *      coarse SecurityConfig floor has already authenticated. NOT a deny;
 *   3. among the winners: a PUBLIC allow row admits with no roles; an allow row
 *      whose role the caller holds admits; an allow=false row whose role the
 *      caller holds DENIES, and explicit deny beats every allow;
 *   4. governed but ungranted  =>  DENY (default-deny).
 *
 * NOT MODELLED, deliberately, because the canonical seed exercises none of it:
 * the per-row casdoor_user pin, the per-row brand `domain` scope, and the D8
 * mfa_required column (a single 4-column INSERT is the whole seed — verified by
 * the parser above, which would find zero rows if that changed).
 */
function seedDecision(gateway: string, requestPath: string, roles: string[]): SeedVerdict {
  const matching = seedRows().filter(
    (r) => r.gateway === gateway && patternMatches(r.pattern, requestPath),
  );
  if (matching.length === 0) return { decision: 'NO_RULE', winning: [] };
  const best = Math.max(...matching.map((r) => r.pattern.length));
  const winners = matching.filter((r) => r.pattern.length === best);
  let allowed = false;
  let explicitDeny = false;
  for (const r of winners) {
    if (r.allow && r.role === 'PUBLIC') { allowed = true; continue; }
    if (!roles.includes(r.role)) continue;
    if (r.allow) allowed = true; else explicitDeny = true;
  }
  const winning = [...new Set(winners.map((r) => r.pattern))];
  if (explicitDeny) return { decision: 'DENY', winning };
  return { decision: allowed ? 'ALLOW' : 'DENY', winning };
}

/** Every gateway name the seed actually carries, for a loud unknown-gateway failure. */
function seedGateways(): string[] {
  return [...new Set(seedRows().map((r) => r.gateway))].sort();
}

function requireSeedGateway(name: string): string {
  if (!seedGateways().includes(name)) {
    throw new Error(
      `'${name}' is not a gateway the route-access seed carries. Seeded gateways: `
      + `${seedGateways().join(', ')}. A scenario naming a gateway with no rows would `
      + `assert NO_RULE everywhere and pass vacuously.`,
    );
  }
  return name;
}

// ── the caller under evaluation ──────────────────────────────────────────────
//
// WORLD KEYS ARE SHARED WITH rbac.steps.ts ON PURPOSE. That file's
// `Given the persona for this scenario presents its effective role set` writes
// 'effectiveRoles' + 'principal', and the scenarios here reuse it verbatim
// rather than growing a second way to say "this persona's roles". The two Givens
// below write the SAME keys so a scenario can mix them freely.

Given('an anonymous caller presenting no roles', async ({ world }) => {
  world.set('effectiveRoles', [] as string[]);
  world.set('principal', 'anonymous');
});

Given('a caller holding the roles {string}', async ({ world }, roles: string) => {
  const list = roles.split(',').map((r) => r.trim()).filter(Boolean);
  for (const r of list) {
    if (!/^ROLE_[A-Z0-9_]+$/.test(r)) {
      throw new Error(
        `'${r}' is not a Casdoor authority. This step takes ROLE_* strings (the role column `
        + `of gateway_route_access), comma separated — not persona handles. Use `
        + `'@role:<handle>' plus the existing 'Given the persona for this scenario presents `
        + `its effective role set' when you want a real seeded identity.`,
      );
    }
  }
  world.set('effectiveRoles', list);
  world.set('principal', `a caller holding ${list.join('+') || '<nothing>'}`);
});

When(
  'the seeded route-access table is evaluated for the path {string} on the {string} gateway',
  async ({ world }, requestPath: string, gateway: string) => {
    const roles = world.get<string[]>('effectiveRoles');
    const v = seedDecision(requireSeedGateway(gateway), requestPath, roles);
    world.set('seedVerdict', v);
    world.set('seedVerdictPath', `${gateway} ${requestPath}`);
  },
);

Then('the seeded route-access decision is {string}', async ({ world }, expected: string) => {
  if (!['ALLOW', 'DENY', 'NO_RULE'].includes(expected)) {
    throw new Error(
      `a seeded route-access decision is ALLOW, DENY or NO_RULE — never '${expected}'. `
      + `NO_RULE is the one the hand-written oracle cannot express: it means the path is `
      + `UNGOVERNED by the table, not that it was refused.`,
    );
  }
  const v = world.get<SeedVerdict>('seedVerdict');
  expect(
    v.decision,
    `${world.get<string>('principal')} at ${world.get<string>('seedVerdictPath')}: the seed `
    + `decides ${v.decision} (winning url_pattern(s): ${v.winning.join(', ') || '<none — ungoverned>'}). `
    + `Read from ${ROUTE_ACCESS_SQL} with the longest-pattern + deny-wins model `
    + `GatewayRouteAccessService.decide() implements.`,
  ).toBe(expected);
});

Then(
  'the winning seeded pattern for {string} on the {string} gateway is {string}',
  async ({}, requestPath: string, gateway: string, pattern: string) => {
    const v = seedDecision(requireSeedGateway(gateway), requestPath, []);
    expect(
      v.winning,
      `the longest seeded url_pattern matching ${requestPath} on ${gateway} is `
      + `[${v.winning.join(', ') || '<none>'}], not '${pattern}'. This is the field that decides `
      + `WHICH row is consulted at all: a deny row only bites when it is the longest match, `
      + `and a shorter allow row above it is not consulted, not overridden.`,
    ).toContain(pattern);
  },
);

Then(
  'the seeded pattern {string} on the {string} gateway matches the request path {string}',
  async ({}, pattern: string, gateway: string, requestPath: string) => {
    const rows = seedRows().filter(
      (r) => r.gateway === requireSeedGateway(gateway) && r.pattern === pattern,
    );
    expect(
      rows,
      `${ROUTE_ACCESS_SQL} seeds no '${pattern}' row on ${gateway}, so this scenario is `
      + `asserting the matching semantics of a pattern that does not exist.`,
    ).not.toHaveLength(0);
    expect(
      patternMatches(pattern, requestPath),
      `the Ant pattern '${pattern}' must match '${requestPath}'. The hand-written oracle's `
      + `patternMatch() cannot do this: anything without a '/**' suffix is compared as an `
      + `EXACT path there, so '/*.js' matches literally no URL a browser requests and every `
      + `bundle the anonymous shell needs reads as denied.`,
    ).toBe(true);
  },
);

Then(
  'the seeded pattern {string} on the {string} gateway does not match the request path {string}',
  async ({}, pattern: string, gateway: string, requestPath: string) => {
    requireSeedGateway(gateway);
    expect(
      patternMatches(pattern, requestPath),
      `the Ant pattern '${pattern}' must NOT match '${requestPath}' — a single '*' stays inside `
      + `ONE path segment. A matcher that let it cross '/' would silently make the whole `
      + `/assets tree public through the webroot-bundle row.`,
    ).toBe(false);
  },
);

Then(
  'the route-access seed grants {string} at {string} on the {string} gateway',
  async ({}, role: string, pattern: string, gateway: string) => {
    const at = seedRows().filter(
      (r) => r.gateway === requireSeedGateway(gateway) && r.pattern === pattern,
    );
    expect(
      at.map((r) => `${r.role}${r.allow ? '' : ' (DENY)'}`),
      `${ROUTE_ACCESS_SQL} seeds no ${gateway} row for '${pattern}'. The gate is default-deny `
      + `for any GOVERNED path, so a surface with no row is refused to everyone who is not `
      + `admin-bypassed.`,
    ).toContain(role);
    expect(
      at.find((r) => r.role === role)!.allow,
      `the '${pattern}' -> ${role} row on ${gateway} must be an ALLOW row`,
    ).toBe(true);
  },
);

Then(
  'the route-access seed carries an explicit DENY row at {string} on the {string} gateway',
  async ({}, pattern: string, gateway: string) => {
    const denies = seedRows().filter(
      (r) => r.gateway === requireSeedGateway(gateway) && r.pattern === pattern && !r.allow,
    );
    expect(
      denies.map((r) => r.role),
      `${ROUTE_ACCESS_SQL} carries no allow=false row at '${pattern}' on ${gateway}. These `
      + `rows are not decoration: the surfaces they cover are permitAll APP-SIDE, so the `
      + `gateway is the only thing standing in front of them. Deleting the row does not `
      + `restore a default-deny — it opens the ingest.`,
    ).not.toHaveLength(0);
  },
);

Then(
  'the route-access seed has no {string} gateway row matching the request path {string}',
  async ({}, gateway: string, requestPath: string) => {
    const hits = seedRows().filter(
      (r) => r.gateway === requireSeedGateway(gateway) && patternMatches(r.pattern, requestPath),
    );
    expect(
      hits.map((r) => `${r.pattern} -> ${r.role}`),
      `${requestPath} IS governed on ${gateway} now. That changes its posture from NO_RULE `
      + `(ungoverned, admitted by the coarse authenticated() floor) to a real table decision, `
      + `so the scenarios here that assert NO_RULE are the ones to update.`,
    ).toHaveLength(0);
  },
);

Then('the route-access seed contains no row whose role is {string}', async ({}, role: string) => {
  const hits = seedRows().filter((r) => r.role === role);
  expect(
    hits.map((r) => `${r.gateway} ${r.pattern}`),
    `${ROUTE_ACCESS_SQL} DOES emit '${role}' now. The gateway admits an unauthenticated `
    + `caller only on rows whose role is exactly PUBLIC (GatewayRouteAccessService.isPublic), `
    + `so a public row spelled any other way is a row nobody anonymous can satisfy.`,
  ).toHaveLength(0);
});

// ═════════════════════════════════════════════════════════════════════════════
// 2. RECONCILING THE HAND-WRITTEN ORACLE AGAINST THE SEED
// ═════════════════════════════════════════════════════════════════════════════

Given('the route-access seed and the route-access oracle are both loaded', async ({ world }) => {
  const seed = seedRows();
  const oracle = ROUTE_ACCESS;
  expect(seed.length, 'the seed parsed to zero rows').toBeGreaterThan(0);
  expect(oracle.length, 'the oracle carries zero rows').toBeGreaterThan(0);
  world.set('seedLoaded', seed.length);
  world.set('oracleLoaded', oracle.length);
});

function oracleKey(g: string, p: string, r: string): string { return `${g}|${p}|${r}`; }

Then(
  'every oracle row is a seeded row once {string} is read as {string}',
  async ({}, oracleRole: string, seedRole: string) => {
    const seeded = new Set(seedRows().map((r) => oracleKey(r.gateway, r.pattern, r.role)));
    const orphans = ROUTE_ACCESS
      .filter((o) => !seeded.has(oracleKey(
        o.gateway, o.urlPattern, o.role === oracleRole ? seedRole : o.role,
      )))
      .map((o) => `${o.gateway} ${o.urlPattern} ${o.role}`);
    expect(
      orphans,
      `these tests/e2e/specs/rbac-route-access.ts rows exist in NO form in ${ROUTE_ACCESS_SQL}. `
      + `The oracle is a HAND COPY and this is the only thing keeping it from drifting into `
      + `fiction: every scenario that asserts an ALLOW through the oracle is asserting this `
      + `file's opinion, not the table the gateway loads.`,
    ).toEqual([]);
  },
);

Then(
  'the route-access oracle names no role the route-access seed never emits',
  async ({}) => {
    const seededRoles = new Set(seedRows().map((r) => r.role));
    expect(seededRoles.size, 'the seed parsed to zero distinct roles, so this comparison '
      + 'would be vacuous').toBeGreaterThan(0);
    const strangers = [...new Set(ROUTE_ACCESS.map((o) => o.role))]
      .filter((r) => !seededRoles.has(r))
      .sort();
    expect(
      strangers,
      `the oracle names role(s) the seed never emits: ${strangers.join(', ')}. The oracle is `
      + `GENERATED from the seed, so a role only it knows is a row no gateway can ever match — `
      + `i.e. a row that silently grants nobody. (Until 2026-08-26 there was ONE such name by `
      + `design: ROLE_ANONYMOUS, the hand copy's translation of the seed's PUBLIC.)`,
    ).toEqual([]);
  },
);

Then('the route-access oracle carries no more rows than the seed on any gateway', async ({}) => {
  const count = (rows: { gateway: string }[]): Record<string, number> => {
    const out: Record<string, number> = {};
    for (const r of rows) out[r.gateway] = (out[r.gateway] || 0) + 1;
    return out;
  };
  const seedBy = count(seedRows());
  const oracleBy = count(ROUTE_ACCESS.map((o) => ({ gateway: o.gateway })));
  const over = Object.entries(oracleBy)
    .filter(([g, n]) => n > (seedBy[g] || 0))
    .map(([g, n]) => `${g}: oracle ${n} > seed ${seedBy[g] || 0}`);
  expect(
    over,
    `the oracle claims more rows than the seed on a gateway, so it is no longer even a `
    + `SUBSET of the table it claims to mirror. Per-gateway today — seed `
    + `${JSON.stringify(seedBy)} vs oracle ${JSON.stringify(oracleBy)}: the oracle is a `
    + `partial copy, which is why a DENY it reports may only mean "not copied yet".`,
  ).toEqual([]);
});

Then('the route-access oracle carries every explicit-deny row the seed carries', async ({}) => {
  // Structural first: read the TYPE off the source rather than trusting a comment.
  // This step used to assert the ABSENCE of `allow` — the limitation that made
  // deny-wins unrepresentable centrally — with a message telling whoever added it
  // to turn the scenario around. This is that turn.
  const src = readRepoFile('tests/e2e/specs/rbac-route-access.ts');
  const rowType = /export interface RouteRule \{([\s\S]*?)\n\}/.exec(src);
  expect(rowType, 'the RouteRule interface is gone from rbac-route-access.ts').not.toBeNull();
  const stripped = rowType![1].split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  expect(
    /\ballow\b/.test(stripped),
    `RouteRule carries no 'allow' field, so the oracle cannot express the seed's allow=false `
    + `rows at all and every wall reads as merely ungranted.`,
  ).toBe(true);
  // Then the rows themselves, both directions.
  const key = (g: string, p: string, r: string): string => `${g} ${p} ${r}`;
  const seedDeny = seedRows().filter((r) => !r.allow)
    .map((r) => key(r.gateway, r.pattern, r.role)).sort();
  const oracleDeny = ROUTE_ACCESS.filter((o) => !o.allow)
    .map((o) => key(o.gateway, o.urlPattern, o.role)).sort();
  expect(seedDeny.length, 'the seed carries NO explicit deny row, so comparing the two lists '
    + 'would prove nothing').toBeGreaterThan(0);
  expect(
    oracleDeny,
    `the oracle models ${oracleDeny.length} of the seed's ${seedDeny.length} explicit deny `
    + `row(s). A deny row only the seed knows is a wall the offline lane reports as merely `
    + `ungranted — and an ungranted path opens the moment somebody adds an allow row beside `
    + `it, where a deny row survives (deny-wins).`,
  ).toEqual(seedDeny);
});

Then('the route-access oracle carries the fe gateway row for {string} that the seed grants PUBLIC',
  async ({}, pattern: string) => {
    // This step used to assert the row's ABSENCE, with a message saying to fold the
    // pattern into the oracle-driven scenarios once it appeared. It appeared.
    const seeded = seedRows().filter(
      (r) => r.gateway === 'hugmesh-fe-gateway' && r.pattern === pattern && r.allow
        && r.role === 'PUBLIC',
    );
    expect(
      seeded,
      `the SEED no longer grants PUBLIC at fe '${pattern}', so this scenario would be `
      + `comparing the oracle against nothing.`,
    ).not.toHaveLength(0);
    const hits = ROUTE_ACCESS.filter(
      (o) => o.gateway === 'hugmesh-fe-gateway' && o.urlPattern === pattern && o.allow,
    );
    expect(
      hits.map((o) => o.role),
      `the oracle carries no allow row at fe '${pattern}' while the seed grants it PUBLIC. `
      + `That is the shape that made the oracle report DENY for the anonymous SPA shell: an `
      + `offline ALLOW/DENY read from it would say the front door is shut when it is open.`,
    ).toContain('PUBLIC');
  });

Then(
  'the route-access oracle decides {string} for a caller holding {string} at {string} on the {string} gateway',
  async ({}, expected: string, roles: string, requestPath: string, gateway: string) => {
    // RE-IMPLEMENTED ON PURPOSE, AND IT HAD TO CHANGE WITH THE ORACLE. The point
    // of the second reading is that this step used to STATE a divergence, so
    // calling gatewayDecision() would have made the assertion circular. The model
    // below is therefore transcribed from the oracle rather than imported — and
    // when the oracle's model moved (single-segment globs, raw pattern length,
    // NO_RULE, deny-wins), the transcription had to move with it or it would have
    // gone on describing a function nobody runs. Kept because features/rbac/
    // governance-function-matrix.feature proves the two agree by EXECUTION.
    const rows = ROUTE_ACCESS.filter((o) => o.gateway === gateway);
    const held = roles.split(',').map((r) => r.trim()).filter(Boolean);
    const PUBLIC_ROLES = new Set(['PUBLIC', 'ROLE_ANONYMOUS']);
    // antMatch's four shapes.
    const matches = (pattern: string): boolean => {
      if (pattern === '/**') return true;
      if (pattern.endsWith('/**')) {
        const prefix = pattern.slice(0, -3);
        return requestPath === prefix || requestPath.startsWith(`${prefix}/`);
      }
      if (pattern.includes('*')) {
        const rx = new RegExp('^' + pattern.split('*')
          .map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
          .join('[^/]*') + '$');
        return rx.test(requestPath);
      }
      return requestPath === pattern;
    };
    // Longest matching url_pattern wins — by LENGTH, as the gateway measures it.
    let bestLen = -1;
    for (const r of rows) {
      if (!matches(r.urlPattern)) continue;
      if (r.urlPattern.length > bestLen) bestLen = r.urlPattern.length;
    }
    let decision: string;
    const winning: string[] = [];
    if (bestLen < 0) {
      // NO matching pattern is NO_RULE, and the filter FORWARDS on it.
      decision = 'NO_RULE';
    } else {
      let allowed = false;
      let explicitDeny = false;
      for (const r of rows) {
        if (r.urlPattern.length !== bestLen || !matches(r.urlPattern)) continue;
        winning.push(`${r.role}${r.allow ? '' : '(DENY)'}`);
        if (r.allow && PUBLIC_ROLES.has(r.role)) { allowed = true; continue; }
        if (!held.includes(r.role)) continue;
        if (r.allow) allowed = true; else explicitDeny = true;
      }
      decision = explicitDeny || !allowed ? 'DENY' : 'ALLOW';
    }
    expect(
      decision,
      `the oracle decides '${decision}' at ${gateway} ${requestPath} for `
      + `[${held.join(', ') || 'no roles'}] (rows at the winning pattern: `
      + `${winning.join(', ') || '<none: NO pattern matches, which is NO_RULE, not DENY>'}). `
      + `This reading is transcribed from specs/rbac-route-access.ts rather than imported, so `
      + `the scenario cannot be circular; features/rbac/governance-function-matrix.feature `
      + `proves the transcription and the oracle agree by executing both over every triple.`,
    ).toBe(expected);
  },
);

// ═════════════════════════════════════════════════════════════════════════════
// 3. THE TWO fe ROUTE TABLES
// ═════════════════════════════════════════════════════════════════════════════
//
// The compose table (tests/stack/gateway-routes/fe/application-routes.yml) and
// the cluster table (specs/cluster/apps/20-gateway-fe.yaml) are the SAME front
// door expressed twice, in two different YAML shapes: compose uses Spring Cloud
// Gateway's `predicates: - Path=a,b`, the cluster chart uses a flat `path: a,b`.
// uncovered-services.steps.ts already parses the compose one; the cluster one
// has never been read by any test, which is exactly why routes present in one
// and absent in the other went unnoticed.

interface EdgeRoute {
  id: string;
  uri: string;
  paths: string[];
  headers: string[];
  /** Zero-based DECLARATION ORDER — Spring Cloud Gateway matches first-in-order. */
  order: number;
  /** Every filter line declared on the route, verbatim. */
  filters: string[];
}

const routeCache = new Map<string, EdgeRoute[]>();

/** Parse either fe route table. Comment lines cannot match: every pattern is
 *  anchored at `- <key>:` / `path:` / `- Path=` with only whitespace before it,
 *  and every comment in both files starts with `#`. */
function edgeRoutes(rel: string): EdgeRoute[] {
  const cached = routeCache.get(rel);
  if (cached) return cached;
  const out: EdgeRoute[] = [];
  let cur: EdgeRoute | undefined;
  let inFilters = false;
  for (const raw of readRepoFile(rel).split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*#/.test(line)) continue;
    const id = /^\s*-\s*id:\s*(\S+)$/.exec(line);
    if (id) {
      cur = { id: id[1], uri: '', paths: [], headers: [], order: out.length, filters: [] };
      out.push(cur);
      inFilters = false;
      continue;
    }
    if (!cur) continue;
    const uri = /^\s*uri:\s*(\S+)$/.exec(line);
    if (uri) { cur.uri = uri[1]; inFilters = false; continue; }
    const predicatePath = /^\s*-\s*Path=(.+)$/.exec(line);
    if (predicatePath) {
      cur.paths.push(...predicatePath[1].split(',').map((s) => s.trim()));
      inFilters = false;
      continue;
    }
    const flatPath = /^\s*path:\s*(.+)$/.exec(line);
    if (flatPath) {
      cur.paths.push(...flatPath[1].split(',').map((s) => s.trim()));
      inFilters = false;
      continue;
    }
    const header = /^\s*-\s*Header=(.+)$/.exec(line);
    if (header) { cur.headers.push(header[1].trim()); inFilters = false; continue; }
    if (/^\s*filters:\s*$/.test(line)) { inFilters = true; continue; }
    if (inFilters) {
      const f = /^\s*-\s*(\S.*)$/.exec(line);
      if (f) { cur.filters.push(f[1].trim()); continue; }
      inFilters = false;
    }
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO routes out of ${rel}. The route-list shape changed — fix this parser `
      + `rather than letting every ordering assertion pass against an empty list.`,
    );
  }
  routeCache.set(rel, out);
  return out;
}

function tableOf(which: string): { rel: string; routes: EdgeRoute[] } {
  if (which === 'compose') return { rel: FE_ROUTES_COMPOSE, routes: edgeRoutes(FE_ROUTES_COMPOSE) };
  if (which === 'cluster') return { rel: FE_ROUTES_CLUSTER, routes: edgeRoutes(FE_ROUTES_CLUSTER) };
  throw new Error(`unknown fe route table '${which}' — legal values: compose, cluster.`);
}

/** The first route whose Path predicate would claim this request path, using the
 *  same Ant semantics the gateway applies. Declaration order, NOT specificity:
 *  Spring Cloud Gateway takes the first route whose predicates all match. */
function claimingRoute(routes: EdgeRoute[], requestPath: string): EdgeRoute | undefined {
  return routes.find((r) => r.paths.some((p) => patternMatches(p, requestPath)));
}

Then('the fe gateway route {string} declares no path-rewriting filter', async ({}, id: string) => {
  const route = edgeRoutes(FE_ROUTES_COMPOSE).find((r) => r.id === id);
  expect(route, `no route with id '${id}' in ${FE_ROUTES_COMPOSE}`).toBeDefined();
  const rewriting = route!.filters.filter(
    (f) => /^(StripPrefix|SetPath|RewritePath|PrefixPath)\b/.test(f),
  );
  expect(
    rewriting,
    `route '${id}' rewrites the path (${rewriting.join(', ')}). It must forward VERBATIM: the `
    + `host shell injects its CSP nonce with a sub_filter inside its own 'location /' block, `
    + `so a rewritten path is served from a different block, the shell still answers 200, the `
    + `policy still demands a nonce, and no script tag carries one. Blank page, no error, `
    + `no status an assertion can see.`,
  ).toEqual([]);
});

Then('the fe gateway deep-link route does not claim {string}', async ({}, pattern: string) => {
  const route = edgeRoutes(FE_ROUTES_COMPOSE).find((r) => r.id === 'remote-deeplink-to-host-shell');
  expect(route, `no remote-deeplink-to-host-shell route in ${FE_ROUTES_COMPOSE}`).toBeDefined();
  expect(
    route!.paths,
    `'${pattern}' has been added to the deep-link route. Its ABSENCE is a decision, not an `
    + `omission: /social/phpbb is a server-rendered app that must keep serving its own HTML, `
    + `/api-docs is mounted in the shell at the DIFFERENT path /admin/docs so it never `
    + `collides, and /admin has no gateway route at all and already falls through to the host.`,
  ).not.toContain(pattern);
});

Then(
  'the fe gateway deep-link route is scoped to html navigations only for {string}',
  async ({}, pattern: string) => {
    const route = edgeRoutes(FE_ROUTES_COMPOSE).find((r) => r.id === 'remote-deeplink-to-host-shell');
    expect(route, `no remote-deeplink-to-host-shell route in ${FE_ROUTES_COMPOSE}`).toBeDefined();
    expect(
      route!.paths,
      `the deep-link route does not claim '${pattern}', so a refresh on it lands in the bare remote.`,
    ).toContain(pattern);
    expect(
      route!.headers.join(' '),
      `the deep-link route must be POSITIVE-matched on 'Accept: text/html'. Without that `
      + `predicate it also swallows remoteEntry.json, the chunk imports, the assets and every `
      + `XHR for '${pattern}' — the remote then never loads at all, which is a strictly worse `
      + `failure than the refresh bug this route exists to fix.`,
    ).toMatch(/Accept.*text\/html/);
  },
);

Then(
  'the cluster fe gateway routes {string} to the {string} upstream',
  async ({}, pattern: string, upstream: string) => {
    const { rel, routes } = tableOf('cluster');
    const matching = routes.filter((r) => r.paths.includes(pattern));
    expect(
      matching.map((r) => r.id),
      `no route in ${rel} declares the path '${pattern}'. The cluster table is what kind and `
      + `production serve; a service routed only in the compose table is unreachable there `
      + `however green the compose lane is.`,
    ).not.toHaveLength(0);
    expect(
      matching.find((r) => r.uri.includes(upstream)),
      `'${pattern}' is routed by [${matching.map((r) => `${r.id} -> ${r.uri}`).join(', ')}], `
      + `none of which forwards to '${upstream}'.`,
    ).toBeDefined();
  },
);

Then(
  'the cluster fe gateway declares {string} before {string}',
  async ({}, earlier: string, later: string) => {
    const { rel, routes } = tableOf('cluster');
    const a = routes.find((r) => r.paths.includes(earlier));
    const b = routes.find((r) => r.paths.includes(later));
    expect(a, `${rel} declares no route for '${earlier}'`).toBeDefined();
    expect(b, `${rel} declares no route for '${later}'`).toBeDefined();
    expect(
      a!.order,
      `route '${a!.id}' ('${earlier}') is declared AFTER '${b!.id}' ('${later}'). Spring Cloud `
      + `Gateway matches FIRST-IN-DECLARED-ORDER, not most-specific, so '${later}' would `
      + `swallow '${earlier}' and the request would reach the wrong service — which answers `
      + `403 for an identity it has never heard of. A routing bug wearing a permission bug's face.`,
    ).toBeLessThan(b!.order);
  },
);

// Generalised twins of the two steps above — take WHICH table ('compose' or
// 'cluster') as an explicit quoted argument instead of hard-coding 'cluster',
// so a single scenario outline can pin the SAME carve-out on both lanes at
// once (hugmesh-generator#480). Kept alongside the cluster-only steps rather
// than replacing them: the unquoted literal "the cluster fe gateway routes …"
// / "…declares …" elsewhere in this feature still matches those steps, not
// these.
Then(
  'the {string} fe gateway routes {string} to the {string} upstream',
  async ({}, which: string, pattern: string, upstream: string) => {
    const { rel, routes } = tableOf(which);
    const matching = routes.filter((r) => r.paths.includes(pattern));
    expect(
      matching.map((r) => r.id),
      `no route in ${rel} declares the path '${pattern}'.`,
    ).not.toHaveLength(0);
    expect(
      matching.find((r) => r.uri.includes(upstream)),
      `'${pattern}' is routed by [${matching.map((r) => `${r.id} -> ${r.uri}`).join(', ')}] in `
      + `${rel}, none of which forwards to '${upstream}'.`,
    ).toBeDefined();
  },
);

Then(
  'the {string} fe gateway declares {string} before {string}',
  async ({}, which: string, earlier: string, later: string) => {
    const { rel, routes } = tableOf(which);
    const a = routes.find((r) => r.paths.includes(earlier));
    const b = routes.find((r) => r.paths.includes(later));
    expect(a, `${rel} declares no route for '${earlier}'`).toBeDefined();
    expect(b, `${rel} declares no route for '${later}'`).toBeDefined();
    expect(
      a!.order,
      `route '${a!.id}' ('${earlier}') is declared AFTER '${b!.id}' ('${later}') in ${rel}. `
      + `Spring Cloud Gateway / the chart matches FIRST-IN-DECLARED-ORDER, not most-specific, `
      + `so '${later}' would swallow '${earlier}' and the request would reach the wrong service.`,
    ).toBeLessThan(b!.order);
  },
);

Then(
  'the {string} fe gateway claims {string} before the {string} catch-all',
  async ({}, which: string, requestPath: string, catchAllId: string) => {
    const { rel, routes } = tableOf(which);
    const catchAll = routes.find((r) => r.id === catchAllId);
    expect(catchAll, `${rel} has no route with id '${catchAllId}'`).toBeDefined();
    const claimed = claimingRoute(routes, requestPath);
    expect(
      claimed?.id,
      `nothing in ${rel} claims '${requestPath}' before '${catchAllId}'. This is the repo's own `
      + `recorded incident, verbatim from 20-gateway-fe.yaml: with no route on the front door `
      + `the path fell through to the Angular shell's /** catch-all and the shell answered its `
      + `OWN index.html — GET /_matrix/client/versions -> 200 text/html. The client parsed HTML `
      + `as JSON, reported the homeserver unavailable, and every layer looked healthy. A 200 `
      + `with the wrong content-type raises no error anywhere.`,
    ).not.toBe(catchAllId);
    expect(
      claimed!.order,
      `'${requestPath}' is claimed by '${claimed!.id}' at position ${claimed!.order}, which is `
      + `after the catch-all '${catchAllId}' at ${catchAll!.order} — so the catch-all answers first.`,
    ).toBeLessThan(catchAll!.order);
  },
);

Then(
  '{string} is the final route in the {string} fe gateway table',
  async ({}, id: string, which: string) => {
    const { rel, routes } = tableOf(which);
    const last = routes[routes.length - 1];
    expect(
      last.id,
      `the last route declared in ${rel} is '${last.id}', not '${id}'. The SPA catch-all must `
      + `be last: every route declared after it is dead config that still reads as a fix, and `
      + `the surface it was meant to claim keeps being answered with index.html at 200.`,
    ).toBe(id);
  },
);

// ── the fragment fleet ───────────────────────────────────────────────────────

/** Every port the committed remote-fragment nginx.conf listens on. */
function fragmentNginxPorts(): number[] {
  const out = new Set<number>();
  for (const m of readRepoFile(FRAGMENT_NGINX).matchAll(/^\s*listen\s+\S*?:?(\d+)\s*;/gm)) {
    out.add(Number(m[1]));
  }
  if (out.size === 0) {
    throw new Error(
      `parsed no listen directive out of ${FRAGMENT_NGINX} — fix this parser rather than `
      + `letting the port assertion pass against an empty set.`,
    );
  }
  return [...out].sort((a, b) => a - b);
}

Then(
  'the {string} fe gateway route for {string} targets a port the remote-fragment web listener serves',
  async ({}, which: string, pattern: string) => {
    const { rel, routes } = tableOf(which);
    const route = routes.find((r) => r.paths.includes(pattern));
    expect(route, `${rel} declares no route for '${pattern}'`).toBeDefined();
    const web = fragmentNginxPorts();
    const svc = /ports:\s*\[\{\s*name:\s*http,\s*port:\s*(\d+)/.exec(readRepoFile(FRAGMENT_DEPLOY));
    const legal = new Set<number>(web);
    if (svc) legal.add(Number(svc[1]));   // the ClusterIP Service port -> targetPort http
    const port = /:(\d+)(?:\/|$)/.exec(route!.uri);
    expect(
      port,
      `route '${route!.id}' -> ${route!.uri} names no explicit port, so this assertion cannot `
      + `tell which listener it reaches.`,
    ).not.toBeNull();
    expect(
      legal.has(Number(port![1])),
      `route '${route!.id}' sends ${pattern} to ${route!.uri}, i.e. port ${port![1]}. The `
      + `remote-fragment WEB listener is nginx on ${web.join('/')} (${FRAGMENT_NGINX}), exposed `
      + `by the Service on ${svc ? svc[1] : '<unparsed>'}; 8081 is the SPRING SYNC SIDECAR's `
      + `SERVER_PORT (${FRAGMENT_DEPLOY}) and has no /_fragments handler at all. A route to a `
      + `live host on the wrong port is not a 404: the gateway 5xxes or hangs, the shell's `
      + `loadRemoteModule rejects, and the fragment region renders EMPTY inside an otherwise `
      + `healthy page. Legal ports: ${[...legal].sort((a, b) => a - b).join(', ')}.`,
    ).toBe(true);
  },
);

// ═════════════════════════════════════════════════════════════════════════════
// 4. THE CSP NONCE CHAIN IN THE COMMITTED UI ARCHETYPES
// ═════════════════════════════════════════════════════════════════════════════
//
// SCOPE, STATED HONESTLY. The mined claim was about ~20 per-UI nginx.conf files.
// Exactly TWO nginx configs for an Angular surface are committed to THIS repo —
// the angular-host and angular-mfe archetype skeletons every generated UI starts
// from — plus the remote-fragment static fleet's, which serves no HTML. The
// per-repo configs live in sibling checkouts and are deliberately NOT read here
// (a step that reached into them would pass on a developer box and fail in CI).
// The archetypes are the higher-leverage half anyway: they are the MULTIPLIER.

function nginxTemplate(name: string): string {
  const rel = NGINX_TEMPLATES[name];
  if (!rel) {
    throw new Error(
      `'${name}' is not a committed nginx archetype in this repo. Legal names: `
      + `${Object.keys(NGINX_TEMPLATES).join(', ')} (templates/archetypes/<name>/_skeleton/`
      + `nginx.conf.hbs). Per-UI nginx.conf files live in their own repos and are not `
      + `readable from this suite.`,
    );
  }
  // Comments stripped BEFORE any assertion: a directive named only in a comment
  // must never satisfy a check that the directive is configured.
  return readRepoFile(rel).split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
}

Then(
  'the {string} nginx archetype emits its own Content-Security-Policy header',
  async ({}, name: string) => {
    expect(
      /add_header\s+Content-Security-Policy\s/.test(nginxTemplate(name)),
      `${NGINX_TEMPLATES[name]} sends no CSP of its own, so everything generated from it `
      + `inherits the gateway's fallback (hugmesh-gateway SecurityConfig: script-src 'self' `
      + `with NO nonce and NO blob:, style-src 'self' with no 'unsafe-inline'). That is a `
      + `correct policy for an API and a fatal one for an Angular SPA: the styles and the `
      + `federation bootstrap are both blocked, the app never mounts, and the response is `
      + `still 200. A blank page is not a 404 and no status assertion will ever see it.`,
    ).toBe(true);
  },
);

Then(
  'the {string} nginx archetype Content-Security-Policy allows {string} in {string}',
  async ({}, name: string, token: string, directive: string) => {
    const csp = /add_header\s+Content-Security-Policy\s+"([^"]*)"/.exec(nginxTemplate(name));
    expect(csp, `${NGINX_TEMPLATES[name]} emits no double-quoted CSP to inspect`).not.toBeNull();
    const found = csp![1].split(';').map((d) => d.trim()).find((d) => d.startsWith(`${directive} `));
    expect(
      found,
      `the CSP in ${NGINX_TEMPLATES[name]} declares no '${directive}' at all: "${csp![1]}"`,
    ).toBeDefined();
    expect(
      found!.split(/\s+/).slice(1),
      `'${directive}' must allow ${token}. For script-src/worker-src, blob: is REQUIRED and not `
      + `optional: native federation and the wasm/worker bootstraps load from blob URLs, and `
      + `without it the remote silently never mounts.`,
    ).toContain(token);
  },
);

Then(
  'the {string} nginx archetype Content-Security-Policy carries no {string} in {string}',
  async ({}, name: string, token: string, directive: string) => {
    const csp = /add_header\s+Content-Security-Policy\s+"([^"]*)"/.exec(nginxTemplate(name));
    expect(csp, `${NGINX_TEMPLATES[name]} emits no double-quoted CSP to inspect`).not.toBeNull();
    const found = csp![1].split(';').map((d) => d.trim()).find((d) => d.startsWith(`${directive} `));
    expect(found, `the CSP declares no '${directive}'`).toBeDefined();
    expect(
      found!.split(/\s+/).slice(1),
      `'${directive}' must NOT allow ${token} — a nonce plus 'unsafe-inline' in script-src is `
      + `strictly weaker than no CSP at all, because browsers that honour the nonce IGNORE `
      + `'unsafe-inline' and browsers that do not, honour it.`,
    ).not.toContain(token);
  },
);

Then('the {string} nginx archetype defines the nonce source from $request_id', async ({}, name: string) => {
  expect(
    /map\s+\$request_id\s+\$cspnonce/.test(nginxTemplate(name)),
    `${NGINX_TEMPLATES[name]} names a per-request nonce in its CSP but never defines one. The `
    + `chain is THREE parts — the map, the sub_filter injection, and the header — and two of `
    + `three is strictly worse than none: the policy demands a nonce no script tag carries, so `
    + `every bootstrap script is blocked and the page is blank at HTTP 200.`,
  ).toBe(true);
});

Then('the {string} nginx archetype injects the nonce into every script tag', async ({}, name: string) => {
  const src = nginxTemplate(name);
  expect(
    /sub_filter\s+'<script'\s+'<script nonce="\$cspnonce"'/.test(src),
    `${NGINX_TEMPLATES[name]} has no sub_filter injecting nonce="$cspnonce" into <script tags.`,
  ).toBe(true);
  expect(
    /sub_filter_once\s+off/.test(src),
    `the injection must run with 'sub_filter_once off'. With it on, only the FIRST <script in `
    + `index.html is given a nonce and every later one is blocked — which is the same blank `
    + `page, reached one directive later.`,
  ).toBe(true);
});

Then('the {string} nginx archetype does not serve html precompressed', async ({}, name: string) => {
  const src = nginxTemplate(name);
  const gz = /gzip_static\s+(on|always)/.exec(src);
  expect(
    gz,
    `${NGINX_TEMPLATES[name]} enables gzip_static (${gz?.[0]}). sub_filter CANNOT rewrite an `
    + `already-compressed response, so the nonce is never injected while the CSP that demands `
    + `it is still sent — the silent defeat of the whole chain, recorded in host-shell's own `
    + `nginx.conf as a trap. Serve index.html uncompressed past the sub_filter.`,
  ).toBeNull();
});

/**
 * THE TRIPWIRE for the scaffold, and it is a tripwire rather than a failing
 * assertion for a stated reason: angular-mfe's skeleton records the omission as a
 * DECISION ("STRICTER policies (Content-Security-Policy, COEP/CORP,
 * Permissions-Policy) are deliberately deferred — they need per-UI tuning"),
 * while its angular-host sibling ships the full chain. Pinning the decision keeps
 * the divergence visible and makes CLOSING it loud, in the same shape as
 * uncovered-services' "no persona holds ROLE_WIKI" tripwire.
 */
Then('the {string} nginx archetype still emits no Content-Security-Policy of its own', async ({}, name: string) => {
  expect(
    /add_header\s+Content-Security-Policy\s/.test(nginxTemplate(name)),
    `GOOD NEWS AND A PROMPT: ${NGINX_TEMPLATES[name]} now emits a CSP. Every micro-frontend `
    + `generated from this archetype used to inherit the gateway's fallback instead — `
    + `script-src 'self' with no nonce and no blob:, which blocks the federation bootstrap and `
    + `leaves a blank page at HTTP 200. Verify the new policy carries the whole nonce chain `
    + `(map $request_id, sub_filter with sub_filter_once off, and the header), then move this `
    + `archetype into the complete-chain Scenario Outline above and delete this scenario.`,
  ).toBe(false);
});
