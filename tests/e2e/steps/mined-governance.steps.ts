// mined-governance.steps.ts — step definitions for features/mined-governance/.
//
// THE UNIT: M2 governance — admin-ui, mod-ui, superadmin-service-catalog-ui,
// admin-bff-api, mod-bff-api, and the gateway route-access layer they all sit
// behind. Every scenario here was derived from a named path:line in real source
// and then RE-MEASURED before it was written; the ones whose premise did not
// survive re-measurement were dropped (see the unit report).
//
// THE TIER THIS LANE IS FOR. Every environment on this box is down and stays
// down, so a scenario that needs a stack is worth little today. Everything in
// this file READS SOURCE AND ASSERTS OVER IT — the cluster Postgres seed, the
// in-image gateway floor, the Angular route tables and guards, the Spring
// SecurityConfigs, the mod-bff controller and service. No port, no process, no
// build. That tier RUNS, which is the only reason it counts.
//
// TWO KINDS OF SOURCE AND TWO KINDS OF HONESTY:
//   * IN-REPO   (specs/cluster/manifests/route-access/initdb/20-schema.sql,
//               tests/e2e/specs/rbac-route-access.ts) — always present, so
//               those scenarios can never skip.
//   * SIBLING   (hugmesh-gateway, -admin-ui, -mod-ui, -admin-bff-api,
//               -mod-bff-api, -superadmin-service-catalog-ui) — present on an
//               operator box, absent in a bare container. `requireSibling`
//               SKIPS WITH THE PATH IT SEARCHED and the override variable. It
//               never defaults, and it never passes vacuously.
//
// KNOWN-OPEN DEFECTS use the suite's existing `Given this scenario is PENDING
// because "<reason>"` step rather than a red assertion: the scenario body is
// written against the property that SHOULD hold, the reason carries the
// MEASURED size of the gap, and the day someone closes it the scenario turns
// green by deleting one Given. A comment would not have executed.
//
// STEP HYGIENE. Every step text below was grepped against tests/e2e/steps/
// before it was written; none of them duplicates or near-twins an existing
// definition. bddgen is all-or-nothing on ambiguity, so a single collision
// would take the whole 460-scenario lane down with it.

import { expect } from '@playwright/test';
import { Given, When, Then } from './world';
import {
  SQL_SEED_PATH, SeedRow, SeedVerdict,
  sqlSeedRows, canonicalSeedRows, seedDecide, rowKey, canonicalRole, antMatch,
  siblingSkipReason, siblingFile, stripComments,
  adminRoutes, adminMenu, guardRedirects, bffSecurity,
  modEndpoints, modServiceGuardChains, modStepUpGateSource,
  MOD_STEPUP_REL, ModEndpoint, AdminRoute, AdminMenuItem, BffSecurity,
} from '../specs/governance-sources';
import { ROUTE_ACCESS } from '../specs/rbac-route-access';

/** Comma-separated Examples cell -> trimmed list. `""` is the empty list, not [""]. */
function list(csv: string): string[] {
  return csv.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
}

/** The central TS mirror, in the same shape as a seed row.
 *
 *  `allow: r.allow` — it was `allow: true` while RouteRule had no allow field and
 *  every mirror row really was a grant by construction. The generated mirror now
 *  carries the seed's four allow=false rows, and flattening them to grants made
 *  this lane report them as four permissions "production never gives" — the
 *  mirror was right and the reader was wrong. */
function mirrorRows(): SeedRow[] {
  return ROUTE_ACCESS.map((r) => ({
    gateway: r.gateway, urlPattern: r.urlPattern, role: r.role,
    allow: r.allow,
    // The generated oracle's EXPECTED_COLUMNS is (gateway, url_pattern, role,
    // allow) only — mfa_required is not modelled in this mirror at all (see
    // gen-route-access-oracle.py's own docstring). false here, always; nothing
    // in THIS file's scenarios reads mfaRequired off a mirror row.
    mfaRequired: false, origin: 'tests/e2e/specs/rbac-route-access.ts',
  }));
}

// ── the two route-access seeds ───────────────────────────────────────────────

Given('the cluster route-access seed is loaded', async ({ world }) => {
  const rows = sqlSeedRows();
  expect(rows.length, `${SQL_SEED_PATH} parsed to zero rows — the INSERT shape changed`)
    .toBeGreaterThan(0);
  world.set('seed', rows);
  world.set('seedName', `the cluster Postgres seed (${SQL_SEED_PATH})`);
});

Given('the in-image gateway fail-closed floor is loaded', async ({ world, $testInfo }) => {
  const rows = canonicalSeedRows();
  if (rows === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-gateway')); return; }
  world.set('floor', rows);
  world.set('floorName', 'the in-image CanonicalSeed floor (hugmesh-gateway)');
});

Given('the central route-access mirror is loaded', async ({ world }) => {
  world.set('mirror', mirrorRows());
});

// ── decisions over REAL rows ─────────────────────────────────────────────────
//
// Deliberately NOT `the "<gw>" gateway evaluates the request path "<p>"` (that
// existing step drives the TS mirror's ALLOW/DENY-only oracle). These name the
// SOURCE they decide from, because the whole point of the lane is that the two
// sources disagree and the mirror cannot express the third outcome.

function decideFrom(world: { get<T>(k: string): T; set<T>(k: string, v: T): void },
                    key: 'seed' | 'floor', gateway: string, path: string): void {
  const rows = world.get<SeedRow[]>(key);
  const roles = world.get<string[]>('effectiveRoles');
  world.set('verdict', seedDecide(rows, gateway, path, roles));
  world.set('verdictAt', `${gateway} ${path} as ${JSON.stringify(roles)}`);
}

When('the {string} gateway decides {string} from the cluster seed',
  async ({ world }, gateway: string, path: string) => decideFrom(world, 'seed', gateway, path));

When('the {string} gateway decides {string} from the in-image floor',
  async ({ world }, gateway: string, path: string) => decideFrom(world, 'floor', gateway, path));

Then('the seed decision is {string}', async ({ world }, expected: string) => {
  const v = world.get<SeedVerdict>('verdict');
  expect(v.decision, `at ${world.get<string>('verdictAt')} (winning pattern ${v.pattern})`)
    .toBe(expected);
});

Then('the deny came from an explicit deny row', async ({ world }) => {
  const v = world.get<SeedVerdict>('verdict');
  expect(v.decision, `at ${world.get<string>('verdictAt')}`).toBe('DENY');
  expect(
    v.explicitDeny,
    `at ${world.get<string>('verdictAt')} the winning pattern ${v.pattern} denied by `
    + `governed-but-ungranted DEFAULT, not by an allow=false row. The distinction is the `
    + `point: a default-deny disappears the moment somebody adds an allow row at that `
    + `pattern, an explicit deny survives it (deny-wins, GatewayRouteAccessService:218).`,
  ).toBe(true);
});

Then('the deciding url pattern is {string}', async ({ world }, pattern: string) => {
  const v = world.get<SeedVerdict>('verdict');
  expect(v.pattern, `at ${world.get<string>('verdictAt')}`).toBe(pattern);
});

// ── decision 56 — the declared MFA-required set (hugmesh-generator#347,
// 2026-09-18) ─────────────────────────────────────────────────────────────

Then('the deciding rule requires MFA', async ({ world }) => {
  const v = world.get<SeedVerdict>('verdict');
  expect(v.mfaRequired, `at ${world.get<string>('verdictAt')} (winning pattern ${v.pattern})`)
    .toBe(true);
});

Then('the deciding rule does not require MFA', async ({ world }) => {
  const v = world.get<SeedVerdict>('verdict');
  expect(v.mfaRequired, `at ${world.get<string>('verdictAt')} (winning pattern ${v.pattern})`)
    .toBe(false);
});

// ── seed shape ───────────────────────────────────────────────────────────────

Then('the cluster seed carries {int} route-access rows across {int} gateways',
  async ({ world }, rows: number, gateways: number) => {
    const seed = world.get<SeedRow[]>('seed');
    const names = [...new Set(seed.map((r) => r.gateway))].sort();
    expect(seed.length, `${SQL_SEED_PATH} row count`).toBe(rows);
    expect(names.length, `gateways seeded: ${names.join(', ')}`).toBe(gateways);
  });

Then('the cluster seed carries exactly {int} explicit deny rows', async ({ world }, n: number) => {
  const deny = world.get<SeedRow[]>('seed').filter((r) => !r.allow);
  expect(deny.length, `explicit deny rows:\n  ${deny.map(rowKey).join('\n  ')}`).toBe(n);
});

Then('the cluster seed carries an explicit deny row on {string} at gateway {string}',
  async ({ world }, pattern: string, gateway: string) => {
    const hit = world.get<SeedRow[]>('seed')
      .filter((r) => !r.allow && r.gateway === gateway && r.urlPattern === pattern);
    expect(
      hit.length,
      `no allow=false row at ${gateway} ${pattern}. Leaving the subtree OUT of the seed `
      + `instead is NOT equivalent: an unmatched path is NO_RULE, and NO_RULE FORWARDS on `
      + `the coarse authenticated() floor.`,
    ).toBeGreaterThan(0);
  });

// ── mirror vs seed ───────────────────────────────────────────────────────────

Then('every central mirror row exists in the cluster seed as an allow row', async ({ world }) => {
  // GRANTS, so ALLOW rows on BOTH sides. The mirror carries the seed's four
  // allow=false rows now; a wall is not a claim of access, and comparing one
  // against the seed's grant list reported the mirror over-granting exactly where
  // it was faithfully mirroring a refusal.
  const seed = new Set(world.get<SeedRow[]>('seed').filter((r) => r.allow).map(rowKey));
  expect(seed.size, 'the cluster seed parsed to zero ALLOW rows, so this comparison would be '
    + 'vacuous').toBeGreaterThan(0);
  const grants = world.get<SeedRow[]>('mirror').filter((r) => r.allow);
  expect(grants.length, 'the mirror carries zero ALLOW rows, so this comparison would be '
    + 'vacuous').toBeGreaterThan(0);
  const invented = grants.map(rowKey).filter((k) => !seed.has(k));
  expect(
    invented,
    `the TS mirror GRANTS ${invented.length} row(s) the cluster seed does not. A mirror row `
    + `with no seed behind it is a test asserting a permission production never gives.`,
  ).toEqual([]);
});

Then('every gateway the central mirror names is seeded by the cluster', async ({ world }) => {
  const seeded = new Set(world.get<SeedRow[]>('seed').map((r) => r.gateway));
  const named = [...new Set(world.get<SeedRow[]>('mirror').map((r) => r.gateway))];
  const orphans = named.filter((g) => !seeded.has(g));
  expect(
    orphans,
    `the mirror asserts on gateway(s) nothing seeds: ${orphans.join(', ')}. `
    + `Every DENY it proves there would be vacuous.`,
  ).toEqual([]);
});

Then('the central mirror carries every allow row the cluster seed carries', async ({ world }) => {
  const mirror = new Set(world.get<SeedRow[]>('mirror').map(rowKey));
  const missing = world.get<SeedRow[]>('seed').filter((r) => r.allow)
    .map(rowKey).filter((k) => !mirror.has(k));
  expect(
    missing,
    `${missing.length} allow row(s) the deployed gateway loads are absent from the mirror, `
    + `so the oracle answers DENY where production answers ALLOW:\n  ${missing.join('\n  ')}`,
  ).toEqual([]);
});

Then('the central mirror models every explicit deny row the cluster seed carries',
  async ({ world }) => {
    // Structural first, then the sample. The mirror's row TYPE used to have no
    // allow/deny field at all, which made deny-wins unrepresentable centrally;
    // this step asserted that limitation so that lifting it would fail here and
    // name the follow-up. It was lifted — RouteRule carries `allow` — so the
    // assertion becomes the positive one it was holding the place for.
    const declared = Object.keys(ROUTE_ACCESS[0]);
    expect(
      declared,
      `RouteRule fields: ${declared.join(', ')}. Without an allow boolean the central `
      + `oracle cannot model deny-wins at all and every /bff/*/internal/** deny row is `
      + `unrepresentable.`,
    ).toEqual(['gateway', 'urlPattern', 'role', 'allow']);
    const seedDeny = world.get<SeedRow[]>('seed').filter((r) => !r.allow).map(rowKey).sort();
    const mirrorDeny = world.get<SeedRow[]>('mirror').filter((r) => !r.allow).map(rowKey).sort();
    expect(seedDeny.length, 'the cluster seed carries NO explicit deny row, so this scenario '
      + 'would compare two empty lists and prove nothing').toBeGreaterThan(0);
    expect(
      mirrorDeny,
      `the mirror models ${mirrorDeny.length} of the seed's ${seedDeny.length} explicit deny `
      + `row(s). A deny row the central oracle cannot see is a wall it reports as merely `
      + `ungranted — which disappears the moment somebody adds an allow row at that pattern.`,
    ).toEqual(seedDeny);
  });

// ── floor vs seed (the fail-closed parity property) ──────────────────────────

Then('the in-image floor seeds exactly the gateways {string}', async ({ world }, csv: string) => {
  const got = [...new Set(world.get<SeedRow[]>('floor').map((r) => r.gateway))].sort();
  expect(got, 'gateway names in CanonicalSeed').toEqual(list(csv).sort());
});

Then('every url pattern the cluster seed governs at gateway {string} is also governed by the in-image floor',
  async ({ world }, gateway: string) => {
    const floorPatterns = [...new Set(world.get<SeedRow[]>('floor')
      .filter((r) => r.gateway === gateway).map((r) => r.urlPattern))];
    const seedPatterns = [...new Set(world.get<SeedRow[]>('seed')
      .filter((r) => r.gateway === gateway).map((r) => r.urlPattern))];
    // A pattern is "governed by the floor" when a representative path under it
    // matches SOME floor pattern — matching pattern strings would miss a broader
    // floor pattern that legitimately covers a narrower seed one.
    const representative = (p: string) => p.replace(/\/\*\*$/, '/probe').replace(/\*/g, 'x');
    const ungoverned = seedPatterns
      .filter((p) => !floorPatterns.some((f) => antMatch(f, representative(p))));
    expect(
      ungoverned,
      `${ungoverned.length} of ${seedPatterns.length} patterns the cluster seed governs at `
      + `${gateway} have NO matching row in the in-image floor, so on the `
      + `datastore-unreachable fallback they resolve NO_RULE and the gateway FORWARDS them `
      + `on the coarse authenticated() floor — the fallback is WEAKER than the Postgres `
      + `rules, which is the exact hole CanonicalSeed's own javadoc says the three deny `
      + `rows exist to close:\n  ${ungoverned.join('\n  ')}`,
    ).toEqual([]);
  });

// ── row-level properties of a seed ───────────────────────────────────────────

Then('no cluster seed row grants {string} on the exact pattern {string} at gateway {string}',
  async ({ world }, role: string, pattern: string, gateway: string) => {
    const hits = world.get<SeedRow[]>('seed').filter(
      (r) => r.gateway === gateway && r.urlPattern === pattern
        && canonicalRole(r.role) === role && r.allow,
    );
    expect(
      hits.map(rowKey),
      `${role} IS granted at ${gateway} ${pattern} by a row. If that is intended, the `
      + `filter-level cross-domain bypass is no longer the only thing admitting it, and the `
      + `two layers now say different things about why.`,
    ).toEqual([]);
  });

Then('the only patterns at gateway {string} naming {string} are {string}',
  async ({ world }, gateway: string, role: string, csv: string) => {
    const got = [...new Set(world.get<SeedRow[]>('seed')
      .filter((r) => r.gateway === gateway && canonicalRole(r.role) === role)
      .map((r) => r.urlPattern))].sort();
    expect(got, `${role} patterns at ${gateway}`).toEqual(list(csv).sort());
  });

// ── admin console: routes vs menu ────────────────────────────────────────────

Given('the admin console route table and menu model are loaded', async ({ world, $testInfo }) => {
  const routes = adminRoutes();
  const menu = adminMenu();
  if (routes === null || menu === null) {
    $testInfo.skip(true, siblingSkipReason('hugmesh-admin-ui'));
    return;
  }
  world.set('adminRoutes', routes);
  world.set('adminMenu', menu);
});

Then('the admin console routes {int} paths and lists {int} menu items',
  async ({ world }, routes: number, items: number) => {
    expect(world.get<AdminRoute[]>('adminRoutes').length, 'admin.routes.ts route entries')
      .toBe(routes);
    expect(world.get<AdminMenuItem[]>('adminMenu').length, 'admin.component.ts allMenu entries')
      .toBe(items);
  });

Then('every menu item names a real route', async ({ world }) => {
  const routed = new Set(world.get<AdminRoute[]>('adminRoutes').map((r) => r.path));
  const dangling = world.get<AdminMenuItem[]>('adminMenu')
    .map((m) => m.path).filter((p) => !routed.has(p));
  expect(dangling, 'menu entries whose path has no route — a link straight to NG04002')
    .toEqual([]);
});

Then('the admin routes reachable only by typing a URL are exactly {string}',
  async ({ world }, csv: string) => {
    const menued = new Set(world.get<AdminMenuItem[]>('adminMenu').map((m) => m.path));
    const orphans = world.get<AdminRoute[]>('adminRoutes')
      .map((r) => r.path).filter((p) => p !== '' && !menued.has(p)).sort();
    expect(
      orphans,
      `a routed admin console in NO menu for ANY role is reachable only by typing its URL. `
      + `This list is PINNED deliberately: a new orphan fails here, and closing an existing `
      + `one fails here too, so neither can happen silently.`,
    ).toEqual(list(csv).sort());
  });

Then('the {string} menu tier holds exactly the modules {string}',
  async ({ world }, tier: string, csv: string) => {
    const got = world.get<AdminMenuItem[]>('adminMenu')
      .filter((m) => m.flags.includes(tier)).map((m) => m.path).sort();
    expect(got, `menu items flagged ${tier}:true`).toEqual(list(csv).sort());
  });

Then('every route guarded by {string} is either flagged {string} in the menu or absent from it',
  async ({ world }, guard: string, tier: string) => {
    const menu = world.get<AdminMenuItem[]>('adminMenu');
    const byPath = new Map(menu.map((m) => [m.path, m] as const));
    const wrong = world.get<AdminRoute[]>('adminRoutes')
      .filter((r) => r.guards.includes(guard))
      .filter((r) => {
        const item = byPath.get(r.path);
        return item !== undefined && !item.flags.includes(tier);
      })
      .map((r) => r.path);
    expect(
      wrong,
      `these routes are ${guard}-protected but appear in the menu WITHOUT ${tier}:true, so a `
      + `plain admin is shown a door that bounces them.`,
    ).toEqual([]);
  });

Then('the routes guarded by {string} that no menu lists are exactly {string}',
  async ({ world }, guard: string, csv: string) => {
    const menued = new Set(world.get<AdminMenuItem[]>('adminMenu').map((m) => m.path));
    const got = world.get<AdminRoute[]>('adminRoutes')
      .filter((r) => r.guards.includes(guard) && !menued.has(r.path))
      .map((r) => r.path).sort();
    expect(
      got,
      `${guard}-protected consoles that even a fully entitled principal can only reach by `
      + `typing the URL.`,
    ).toEqual(list(csv).sort());
  });

// ── governance remotes: where a refusal lands ────────────────────────────────

Then('the guard {string} in {string} refuses to {string}',
  async ({ $testInfo }, rel: string, repo: string, target: string) => {
    const targets = guardRedirects(repo, rel);
    if (targets === null) { $testInfo.skip(true, siblingSkipReason(repo)); return; }
    expect(
      targets,
      `${repo}/${rel} redirect targets. A federated remote that bounces to a HOST path it `
      + `does not own is the wiki-ui bug this contract exists to prevent.`,
    ).toContain(target);
  });

Then('the guard {string} in {string} never refuses to {string}',
  async ({ $testInfo }, rel: string, repo: string, target: string) => {
    const targets = guardRedirects(repo, rel);
    if (targets === null) { $testInfo.skip(true, siblingSkipReason(repo)); return; }
    expect(targets, `${repo}/${rel} redirect targets`).not.toContain(target);
  });

// ── BFF security configuration ───────────────────────────────────────────────

Given('the security configuration of {string} is loaded', async ({ world, $testInfo }, repo: string) => {
  const sec = bffSecurity(repo);
  if (sec === null) { $testInfo.skip(true, siblingSkipReason(repo)); return; }
  world.set('bff', sec);
  world.set('bffName', repo);
});

Then('it declares the role hierarchy edges {string}', async ({ world }, csv: string) => {
  const sec = world.get<BffSecurity>('bff');
  expect(sec.hierarchyEdges.sort(), `${world.get<string>('bffName')} RoleHierarchyImpl edges`)
    .toEqual(list(csv).sort());
});

Then('it declares no {string} edge', async ({ world }, edge: string) => {
  const sec = world.get<BffSecurity>('bff');
  expect(
    sec.hierarchyEdges,
    `${world.get<string>('bffName')} would let a plain ADMIN satisfy a MOD-only @PreAuthorize. `
    + `ADMIN and MOD are documented SIBLINGS across this estate.`,
  ).not.toContain(edge);
});

Then('reactive method security is enabled and the hierarchy is wired into it: {string}',
  async ({ world }, wired: string) => {
    const sec = world.get<BffSecurity>('bff');
    const repo = world.get<string>('bffName');
    expect(sec.methodSecurityEnabled, `${repo} @EnableReactiveMethodSecurity`).toBe(true);
    expect(
      sec.hierarchyWiredIntoMethodSecurity,
      `${repo}: a bare RoleHierarchy bean is NOT auto-applied to @PreAuthorize in the `
      + `reactive method-security path — four of these five configs say exactly that in `
      + `their own javadoc and set a MethodSecurityExpressionHandler explicitly. Where this `
      + `column says "no" the hierarchy bean exists and is INERT for @PreAuthorize, so a `
      + `pure ROLE_SUPERADMIN does NOT satisfy hasRole('USER') there.`,
    ).toBe(wired === 'yes');
  });

Then('the path {string} requires exactly the role {string}', async ({ world }, path: string, role: string) => {
  const sec = world.get<BffSecurity>('bff');
  const hits = sec.pathRoles.filter((p) => p.pattern === path);
  expect(hits.map((h) => h.role), `${world.get<string>('bffName')} pathMatchers("${path}")`)
    .toEqual([role]);
});

Then('no declared hierarchy edge grants {string}', async ({ world }, role: string) => {
  const sec = world.get<BffSecurity>('bff');
  const granting = sec.hierarchyEdges.filter((e) => e.endsWith(`> ${role}`));
  expect(
    granting,
    `${world.get<string>('bffName')} has a hierarchy edge INTO ${role}, so a human role `
    + `inherits the in-cluster service identity. ROLE_SERVICE is deliberately reachable by `
    + `no human role — not even SUPERADMIN.`,
  ).toEqual([]);
});

// ── mod-bff: the write surface ───────────────────────────────────────────────

Given('the mod-bff moderation surface is loaded', async ({ world, $testInfo }) => {
  const eps = modEndpoints();
  const chains = modServiceGuardChains();
  const gate = modStepUpGateSource();
  if (eps === null || chains === null || gate === null) {
    $testInfo.skip(true, siblingSkipReason('hugmesh-mod-bff-api'));
    return;
  }
  world.set('modEndpoints', eps);
  world.set('modChains', chains);
  world.set('modGate', gate);
});

Then('the mod-bff endpoints carrying the step-up gate are exactly {string}',
  async ({ world }, csv: string) => {
    const got = world.get<ModEndpoint[]>('modEndpoints')
      .filter((e) => e.stepUpGated).map((e) => `${e.method} ${e.path}`).sort();
    expect(
      got,
      `the sensitive-write set the step-up gate covers. Arming the flag changes the posture `
      + `of exactly these and nothing else.`,
    ).toEqual(list(csv).sort());
  });

Then('every other mod-bff endpoint carries no step-up gate', async ({ world }) => {
  const eps = world.get<ModEndpoint[]>('modEndpoints');
  const reads = eps.filter((e) => e.method === 'GET');
  expect(reads.length, 'no GET endpoints parsed — the controller shape changed')
    .toBeGreaterThan(0);
  expect(
    reads.filter((e) => e.stepUpGated).map((e) => e.path),
    `arming app.mfa.enforce-sensitive-writes must not close the READ surface a moderator `
    + `needs in order to decide whether a write is warranted.`,
  ).toEqual([]);
});

Then('every mod-bff endpoint requires at least the moderator role', async ({ world }) => {
  const open = world.get<ModEndpoint[]>('modEndpoints')
    .filter((e) => !e.preAuthorize.includes("hasAnyRole('MOD','ADMIN'"))
    .map((e) => `${e.method} ${e.path} :: ${e.preAuthorize}`);
  expect(open, 'a mod-bff endpoint whose @PreAuthorize does not start at MOD/ADMIN').toEqual([]);
});

Then('the mod step-up gate ships DARK on its own flag and is fail-closed when armed',
  async ({ world }) => {
    const gate = world.get<string>('modGate');
    expect(
      gate,
      `${MOD_STEPUP_REL} no longer names its own sub-flag. Sharing app.mfa.enabled would make `
      + `turning on MFA DERIVATION silently start denying moderators.`,
    ).toContain('app.mfa.enforce-sensitive-writes');
    // Fail-closed: the ONLY unconditional true is the not-armed leg.
    expect(gate, 'the dark default leg').toMatch(/if\s*\(!enforced\)\s*\{[\s\S]{0,120}return true;/);
    expect(gate, 'the armed leg must consult the MFA marker, never default-allow')
      .toMatch(/return\s+Roles\.isMfaSatisfied\(auth\);/);
  });

Then('the mod-bff service write {string} runs the guard chain {string}',
  async ({ world }, method: string, csv: string) => {
    const chains = world.get<Record<string, string[]>>('modChains');
    expect(
      chains[method],
      `ModService.${method} guard chain. PUNITIVE writes run self -> tenant -> privileged; `
      + `REMEDIAL ones run the cross-tenant guard ALONE, deliberately — a moderator MAY lift `
      + `their own ban and MAY lift a privileged target's. Pinning both halves is what stops `
      + `a well-meaning refactor from quietly closing the asymmetry (or opening it).`,
    ).toEqual(list(csv));
  });

Then('the mod-bff refusal envelope is exactly the {string} key', async ({ $testInfo }, key: string) => {
  const src = siblingFile('hugmesh-mod-bff-api',
    'src/main/java/net/hugmesh/modbff/web/ApiExceptionHandler.java');
  if (src === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-mod-bff-api')); return; }
  expect(
    src,
    `mod-ui reads (await r.json()).error || 'HTTP <status>' — widening this body to a `
    + `problem+detail shape turns every moderator-visible refusal into a bare status code.`,
  ).toContain(`Map.of("${key}", ex.getMessage())`);
});

Then('a mod-bff validation failure adds a {string} map beside it', async ({ $testInfo }, key: string) => {
  const src = siblingFile('hugmesh-mod-bff-api',
    'src/main/java/net/hugmesh/modbff/web/ValidationExceptionHandler.java');
  if (src === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-mod-bff-api')); return; }
  expect(src, 'the validation envelope keeps the {error} convention').toContain('"validation failed"');
  expect(src, `the per-field detail under "${key}"`).toContain(`body.put("${key}", fields)`);
});

// ── admin-bff: the appeal decide CAS ─────────────────────────────────────────

Then('deciding an account appeal answers {string} on a no-op rather than a conflict',
  async ({ $testInfo }, shape: string) => {
    const src = siblingFile('hugmesh-admin-bff-api',
      'src/main/java/net/hugmesh/adminbff/appeal/AccountAppealAdminController.java');
    if (src === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-admin-bff-api')); return; }
    expect(
      src,
      `the decide surface renders the CAS ROW COUNT as 200 ${shape}. A losing racer is `
      + `therefore indistinguishable from a winner BY STATUS — the body is the only signal, `
      + `and it is the opposite convention from the concurrent-edit surfaces, which REFUSE.`,
    ).toContain('ResponseEntity.ok(Map.of("decided", n, "status", s))');
    expect(src, 'an unknown status is rejected BEFORE service.decide is called')
      .toMatch(/if\s*\(!DECIDABLE\.contains\(s\)\)[\s\S]{0,120}badRequest/);
  });

Then('deciding an account appeal is gated to exactly the roles {string}',
  async ({ $testInfo }, csv: string) => {
    const src = siblingFile('hugmesh-admin-bff-api',
      'src/main/java/net/hugmesh/adminbff/appeal/AccountAppealAdminController.java');
    if (src === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-admin-bff-api')); return; }
    // Anchor on the DECIDE MAPPING and walk BACK to the nearest @PreAuthorize.
    // A forward `@PreAuthorize … decide(` window matched the LIST handler above
    // it during the mutation battery and read the wrong annotation — the
    // mutation went uncaught, which is exactly what a battery is for.
    const java = stripComments(src, '//');
    const at = java.indexOf('@PostMapping("/{id}/decide")');
    expect(at, 'the decide mapping moved — this step is anchored on it').toBeGreaterThan(-1);
    const before = java.slice(0, at);
    const gate = before.lastIndexOf('@PreAuthorize(');
    expect(gate, 'no @PreAuthorize precedes the decide mapping').toBeGreaterThan(-1);
    const m = /@PreAuthorize\("hasAnyRole\(([^)]*)\)"\)/.exec(before.slice(gate));
    expect(m, 'the decide gate is not a hasAnyRole expression').not.toBeNull();
    const roles = (m as RegExpExecArray)[1].split(',').map((s) => s.trim().replace(/'/g, ''));
    expect(roles.sort(), 'roles that may decide an appeal').toEqual(list(csv).sort());
  });
