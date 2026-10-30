// rbac.steps.ts — step definitions for the rbac-governance domain.
//
// Covers the executable Gherkin under features/rbac/, which is the Gherkin
// expression of the handwritten specs 12-18, 23, 25 and 33. Every definition
// here DELEGATES to the modules those specs already drive:
//
//   ../specs/rbac-route-access   the schema.sql decision oracle (gatewayDecision)
//   ../specs/rbac-roles          the systems + games seed catalogues
//   ../specs/helpers             onboard / registerOnly / getSession / personaPassword
//   ../specs/federation          the domain-lock peer observation primitives
//
// so the Gherkin lane and the TypeScript lane cannot disagree about what the
// RBAC model says. Nothing below reimplements login, seeding or a route table.
//
// ONE DELIBERATE DUPLICATION, named rather than hidden: `casdoorToken` mirrors
// the PRIVATE function of the same name in specs/14-rbac-gateway-live.spec.ts.
// It is not imported because importing a *.spec.ts file would execute its
// top-level test.describe() registrations INSIDE every generated bdd spec,
// registering the whole handwritten suite a second time in the bdd project. The
// only clean fix is to lift that helper into a non-spec module; that edit
// touches a file another agent may be holding, so it is reported instead of
// made. See the unit report.

import { expect, request as playwrightRequest } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Given, When, Then, After, requireDimension, substep } from './world';
import { persona, personaSource } from './dimensions';
import { CliTranscript } from './evidence';
import {
  SYSTEMS_SEED_USERS, GAMES_SEED_USERS, systemsUser, passwordFor,
  SUPERADMIN_GATEWAY, SUPERADMIN_ALLOW_ROUTES,
  SYSTEMS_ISSUER, GAMES_ISSUER,
} from '../specs/rbac-roles';
import {
  gatewayDecision, effectiveRoles, Gateway, GatewayDecision,
} from '../specs/rbac-route-access';
import {
  onboard, registerOnly, getSession, personaPassword, apiContext, SUPERADMIN_USERNAME,
} from '../specs/helpers';
import {
  PEER_BASE, LOCAL_MASTODON, federationSkipReason,
  postLocalStatus, peerFollow, peerSawStatus, expectPeerNeverSaw, marker,
} from '../specs/federation';

// ── shared constants, mirrored from the specs this domain expresses ──────────

/** Every admin-only BFF endpoint the mock enforces — spec 13's ADMIN_GET_ENDPOINTS. */
const ADMIN_GET_ENDPOINTS = [
  '/bff/admin/allowlist',
  '/bff/admin/usage',
  '/bff/admin/namespace-access',
  '/bff/admin/route-access',
  '/bff/admin/isos',
];

/** The consoles spec 33 asserts discovery + reach for, keyed by the name a
 *  .feature uses. `proof` is a string only the REAL console renders, so an empty
 *  shell (the NG04002 redirect shape) cannot satisfy the assertion. */
const CONSOLES: Record<string, { navTestId: string; route: string; proof: RegExp }> = {
  admin: { navTestId: 'nav-admin', route: '/admin', proof: /usage|namespace|delegation|route access/i },
  mod: { navTestId: 'nav-mod', route: '/mod', proof: /moderat/i },
};

function consoleDef(name: string) {
  const c = CONSOLES[name];
  if (!c) {
    throw new Error(
      `unknown console '${name}'. Known consoles: ${Object.keys(CONSOLES).join(', ')}. `
      + `Add a ConsoleExpectation to CONSOLES in steps/rbac.steps.ts rather than `
      + `spelling a nav test id inline in a .feature.`,
    );
  }
  return c;
}

/** The be-gateway base the mod-bff ban surface is probed through (spec 23). */
const BE = process.env['SNAP_BE_GATEWAY']
  ?? 'https://hugmesh-be-gateway.hugmesh-backend.svc.cluster.local:8443';

/** The bounded window a negative peer observation is watched for (spec 23). */
const NEGATIVE_WINDOW_MS = 30_000;

const GW_BASE: Record<Gateway, string> = {
  'hugmesh-fe-gateway': process.env.FE_GATEWAY_URL || process.env.SNAP_BASE_URL || 'https://localhost:8443',
  'hugmesh-be-gateway': process.env.BE_GATEWAY_URL || 'https://api.localhost:8443',
  'hugmesh-pki-gateway': process.env.PKI_GATEWAY_URL || 'https://id.localhost:8443',
  'hugmesh-superadmin-gateway': process.env.SUPERADMIN_GATEWAY_URL || 'https://superadmin.localhost:8443',
};

const GATEWAY_IDS: Gateway[] = [
  'hugmesh-pki-gateway', 'hugmesh-be-gateway', 'hugmesh-fe-gateway', 'hugmesh-superadmin-gateway',
];

/** Resolve a `@service:`-free gateway NAME from a .feature cell, loudly. */
function gatewayId(name: string): Gateway {
  if (!(GATEWAY_IDS as string[]).includes(name)) {
    throw new Error(
      `unknown gateway '${name}'. Legal gateway names (specs/rbac-route-access.ts Gateway): `
      + `${GATEWAY_IDS.join(', ')}.`,
    );
  }
  return name as Gateway;
}

function decisionValue(v: string): GatewayDecision {
  // THREE verdicts, not two. GatewayRouteAccessService.decide() answers NO_RULE
  // for a path no url_pattern matches and the filter FORWARDS on it, so
  // "ungoverned" and "refused" are different claims about the mesh. This guard
  // used to reject the spelling, which is why an Examples table could only say
  // DENY about a path the table does not govern at all.
  if (v !== 'ALLOW' && v !== 'DENY' && v !== 'NO_RULE') {
    throw new Error(`a route-access decision is 'ALLOW', 'DENY' or 'NO_RULE', never '${v}'.`);
  }
  return v;
}

/**
 * The EFFECTIVE Casdoor role-set of a persona handle: granted roles plus the
 * DERIVED ROLE_GAMES_ADMIN when it qualifies. Only the TypeScript catalogue
 * carries role grants, so a shell-roster-only handle fails here NAMING why —
 * rather than silently presenting an empty role-set, which would turn every
 * ALLOW expectation into a false DENY and every DENY into a vacuous pass.
 */
function effectiveRolesFor(handle: string): string[] {
  const inTs = SYSTEMS_SEED_USERS.some((u) => u.username === handle);
  if (!inTs) {
    throw new Error(
      `persona '${handle}' is seeded (${personaSource(handle) ?? 'nowhere'}) but carries NO role `
      + `grants in specs/rbac-roles.ts SYSTEMS_SEED_USERS, so its effective role-set cannot be `
      + `computed and a gateway decision about it would be meaningless. Gateway-contract `
      + `scenarios must name a persona from the TypeScript catalogue: `
      + `${SYSTEMS_SEED_USERS.map((u) => u.username).join(', ')}.`,
    );
  }
  const u = systemsUser(handle);
  return effectiveRoles(u.roles, u.expectGamesAdmin);
}

// ── API-context lifecycle ────────────────────────────────────────────────────
// Spec 13/15 need SEPARATE cookie jars (anonymous vs admin vs plain user), which
// the shared `request` fixture cannot give. Contexts are tracked on the world and
// disposed in an After hook so a scenario that fails mid-way still cleans up.

const CONTEXTS = 'rbac.apiContexts';

function trackContext(world: { has(k: string): boolean; get<T>(k: string): T; set<T>(k: string, v: T): void },
  ctx: APIRequestContext): APIRequestContext {
  const list = world.has(CONTEXTS) ? world.get<APIRequestContext[]>(CONTEXTS) : [];
  list.push(ctx);
  world.set(CONTEXTS, list);
  return ctx;
}

After(async ({ world }) => {
  if (!world.has(CONTEXTS)) return;
  for (const ctx of world.get<APIRequestContext[]>(CONTEXTS)) {
    await ctx.dispose().catch(() => { /* already torn down with the test */ });
  }
});

/** Native sign-in through OUR /bff/login into `api`'s own cookie jar — the exact
 *  mechanism specs 13/15 use (no bearer token is ever exposed to the caller). */
async function loginApiAs(api: APIRequestContext, username: string): Promise<void> {
  const r = await api.post('/bff/login', {
    data: { username, password: personaPassword(username) },
  });
  expect(r.status(), `native login ${username} -> ${r.status()}`).toBe(200);
}

// ═════════════════════════════════════════════════════════════════════════════
// 1. GATEWAY ROUTE-ACCESS CONTRACT (specs 12, 16, 17-contract, 25-contract)
//    Pure oracle over specs/rbac-route-access.ts — runs OFFLINE, no stack.
// ═════════════════════════════════════════════════════════════════════════════

Given('the persona for this scenario presents its effective role set', async ({ dimensions, world }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  world.set('effectiveRoles', effectiveRolesFor(handle));
  world.set('principal', handle);
});

Given('a principal holding only the role {string}', async ({ world }, role: string) => {
  if (!role.startsWith('ROLE_')) {
    throw new Error(
      `'${role}' is not a systems ROLE_* string. This step models a BARE ROLE-SET (used for the `
      + `no-down-cascade proof); to drive a real identity use '@role:<persona-handle>' and `
      + `'Given the persona for this scenario presents its effective role set'.`,
    );
  }
  world.set('effectiveRoles', [role]);
  world.set('principal', `a principal holding only ${role}`);
});

When('the {string} gateway evaluates the request path {string}',
  async ({ world }, gateway: string, path: string) => {
    const roles = world.get<string[]>('effectiveRoles');
    world.set('decision', gatewayDecision(gatewayId(gateway), path, roles));
    world.set('decisionAt', `${gateway} ${path}`);
  });

Then('the gateway route-access decision is {string}', async ({ world }, expected: string) => {
  const got = world.get<GatewayDecision>('decision');
  expect(
    got,
    `${world.get<string>('principal')} (effective roles `
    + `${JSON.stringify(world.get<string[]>('effectiveRoles'))}) at `
    + `${world.get<string>('decisionAt')}`,
  ).toBe(decisionValue(expected));
});

Then('the persona {string} is {string} at {string} on the {string} gateway',
  async ({}, handle: string, expected: string, path: string, gateway: string) => {
    const roles = effectiveRolesFor(persona(handle));
    expect(
      gatewayDecision(gatewayId(gateway), path, roles),
      `${handle} (effective roles ${JSON.stringify(roles)}) at ${gateway} ${path}`,
    ).toBe(decisionValue(expected));
  });

Then('no single granted role reaches the games-admin surfaces on either gateway', async ({}) => {
  // The gate property itself, asserted directly: the games-admin rows are keyed
  // on the DERIVED intersection role, so no single grant admits them.
  for (const single of ['ROLE_GAMES', 'ROLE_ADMIN', 'ROLE_MOD', 'ROLE_USER']) {
    expect(gatewayDecision('hugmesh-fe-gateway', '/games/admin/x', [single]),
      `${single} alone must NOT reach /games/admin`).toBe('DENY');
    expect(gatewayDecision('hugmesh-fe-gateway', '/games/api/admin/x', [single]),
      `${single} alone must NOT reach /games/api/admin`).toBe('DENY');
  }
});

Then('only the derived role {string} reaches both games-admin surfaces', async ({}, derived: string) => {
  expect(gatewayDecision('hugmesh-fe-gateway', '/games/admin/x', [derived])).toBe('ALLOW');
  expect(gatewayDecision('hugmesh-fe-gateway', '/games/api/admin/x', [derived])).toBe('ALLOW');
});

Then('every seeded persona derives games-admin exactly when the intersection rule says so', async ({}) => {
  for (const u of SYSTEMS_SEED_USERS) {
    const earns = u.roles.includes('ROLE_GAMES')
      && (u.roles.includes('ROLE_ADMIN') || u.roles.includes('ROLE_MOD'));
    expect(earns,
      `${u.username}: expectGamesAdmin must match ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD)`)
      .toBe(u.expectGamesAdmin);
    expect(effectiveRoles(u.roles, u.expectGamesAdmin).includes('ROLE_GAMES_ADMIN'))
      .toBe(u.expectGamesAdmin);
  }
});

// ── ROLE_SUPERADMIN tier (spec 25 part i) ────────────────────────────────────

Then('the persona for this scenario holds exactly the roles {string}',
  async ({ dimensions }, csv: string) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const want = csv.split(',').map((s) => s.trim()).filter(Boolean);
    expect(systemsUser(handle).roles, `${handle} granted roles`).toEqual(want);
  });

Then('the persona for this scenario does not derive the games-admin role',
  async ({ dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    expect(systemsUser(handle).expectGamesAdmin, `${handle}.expectGamesAdmin`).toBe(false);
  });

Then('the persona for this scenario is DENIED every superadmin-gateway route',
  async ({ dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const roles = effectiveRolesFor(handle);
    for (const route of SUPERADMIN_ALLOW_ROUTES) {
      expect(
        gatewayDecision(SUPERADMIN_GATEWAY as Gateway, route.probe, roles),
        `${handle} (${JSON.stringify(roles)}) must be DENIED ${route.probe} — ROLE_SUPERADMIN `
        + 'is a distinct tier, not a superset admin inherits',
      ).toBe('DENY');
    }
  });

Then('the gateway NAME scopes {string}: ROLE_USER reaches it on the be-gateway but not on the superadmin-gateway',
  async ({}, path: string) => {
    expect(gatewayDecision('hugmesh-be-gateway', path, ['ROLE_USER']),
      `ROLE_USER on the public be-gateway floor at ${path}`).toBe('ALLOW');
    expect(gatewayDecision(SUPERADMIN_GATEWAY as Gateway, path, ['ROLE_USER']),
      `ROLE_USER on the tailnet superadmin-gateway at ${path}`).toBe('DENY');
    expect(gatewayDecision(SUPERADMIN_GATEWAY as Gateway, path, ['ROLE_SUPERADMIN']),
      `ROLE_SUPERADMIN on the tailnet superadmin-gateway at ${path}`).toBe('ALLOW');
  });

// ── cross-realm issuer isolation (spec 25 part ii) ───────────────────────────

Then('the systems realm and the games realm have distinct issuers', async ({}) => {
  expect(SYSTEMS_ISSUER).not.toBe(GAMES_ISSUER);
  expect(SYSTEMS_ISSUER).toBe('id.hugmesh.net');
  expect(GAMES_ISSUER).toBe('id.hugmesh.games');
});

Then('no games-realm identity reaches any privileged systems route', async ({}) => {
  const probes: { gw: Gateway; path: string }[] = [
    { gw: 'hugmesh-fe-gateway', path: '/admin/usage' },
    { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access' },
    { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions' },
    { gw: 'hugmesh-fe-gateway', path: '/games/api/admin/role-grants' },
    { gw: SUPERADMIN_GATEWAY as Gateway, path: '/bff/superadmin/service-store/catalog' },
  ];
  for (const g of GAMES_SEED_USERS) {
    for (const r of g.roles) {
      expect(r.startsWith('ROLE_'),
        `games role "${r}" must not masquerade as a systems ROLE_*`).toBeFalsy();
    }
    for (const p of probes) {
      expect(gatewayDecision(p.gw, p.path, g.roles),
        `games identity ${g.username} must be DENIED systems ${p.gw} ${p.path}`).toBe('DENY');
    }
  }
});

Then('no systems role is a native games role', async ({}) => {
  for (const u of SYSTEMS_SEED_USERS) {
    for (const r of u.roles) {
      expect(r.startsWith('ROLE_'),
        `systems role "${r}" is a systems ROLE_*, never a native games role`).toBeTruthy();
      expect(['player', 'admin'].includes(r),
        `systems role "${r}" must not be a native games role`).toBeFalsy();
    }
  }
});

Then('the synced games admin derives from a systems persona that earns ROLE_GAMES_ADMIN', async ({}) => {
  const synced = GAMES_SEED_USERS.find((u) => u.syncedFromSystems);
  expect(synced, 'a games user synced from systems must exist').toBeTruthy();
  expect(synced!.syncedFromSystems).toBe('ROLE_GAMES_ADMIN');
  expect(synced!.roles).toContain('admin');
  const src = systemsUser(synced!.username);
  const earns = src.roles.includes('ROLE_GAMES')
    && (src.roles.includes('ROLE_ADMIN') || src.roles.includes('ROLE_MOD'));
  expect(earns,
    `${synced!.username}: systems source must satisfy ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD)`).toBe(true);
  expect(src.expectGamesAdmin,
    `${synced!.username}: expectGamesAdmin must agree with the derivation`).toBe(true);
  expect(effectiveRoles(src.roles, src.expectGamesAdmin)).toContain('ROLE_GAMES_ADMIN');
});

Then('the games catalogue carries a native player holding the {string} role', async ({}, role: string) => {
  const player = GAMES_SEED_USERS.find((u) => u.username === 'e2e-player');
  expect(player, 'native games player seeded').toBeTruthy();
  expect(player!.roles).toContain(role);
});

// ── seed-catalogue consistency (spec 15) ─────────────────────────────────────

Then('every systems seed persona has a deterministic password and never a directly-granted ROLE_GAMES_ADMIN',
  async ({}) => {
    const seen = new Set<string>();
    for (const u of SYSTEMS_SEED_USERS) {
      expect(u.username, 'username present').toBeTruthy();
      expect(seen.has(u.username), `duplicate username ${u.username}`).toBeFalsy();
      seen.add(u.username);
      expect(u.passwordEnv).toMatch(/^E2E_.*_PASSWORD$/);
      expect(passwordFor(u), `password resolves for ${u.username}`).toBeTruthy();
      expect(u.roles, `${u.username}: ROLE_GAMES_ADMIN must never be granted directly`)
        .not.toContain('ROLE_GAMES_ADMIN');
    }
  });

Then('the systems catalogue contains the personas {string}', async ({}, csv: string) => {
  const have = new Set(SYSTEMS_SEED_USERS.map((u) => u.username));
  for (const want of csv.split(',').map((s) => s.trim()).filter(Boolean)) {
    expect(have.has(want), `missing required seed user ${want}`).toBeTruthy();
  }
});

Then('the persona for this scenario holds no roles and is not registration-complete',
  async ({ dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const u = systemsUser(handle);
    expect(u.roles, `${handle} must hold NO roles until an admin approves it`).toHaveLength(0);
    expect(u.registrationComplete, `${handle}.registrationComplete`).toBe(false);
  });

// ═════════════════════════════════════════════════════════════════════════════
// 2. BFF ADMIN API GATING (spec 13) + per-realm login (spec 15) — LIVE stack
// ═════════════════════════════════════════════════════════════════════════════

Given('an anonymous API client', async ({ baseURL, world }) => {
  const api = trackContext(world,
    await playwrightRequest.newContext({ baseURL, ignoreHTTPSErrors: true }));
  world.set('api', api);
});

Given('an API client signed in as the persona for this scenario', async ({ baseURL, dimensions, world }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const api = trackContext(world,
    await playwrightRequest.newContext({ baseURL, ignoreHTTPSErrors: true }));
  await loginApiAs(api, handle);
  world.set('api', api);
});

Given('the admin principal {string} has invited {string} onto the allowlist',
  async ({ baseURL, world }, adminHandle: string, email: string) => {
    // The invite PROVISIONS a native account with roles ['user'] against the mock
    // BFF, which is what lets the plain principal sign in at all (spec 13).
    const admin = trackContext(world,
      await playwrightRequest.newContext({ baseURL, ignoreHTTPSErrors: true }));
    await loginApiAs(admin, persona(adminHandle));
    const invite = await admin.post('/bff/admin/allowlist', { data: { email } });
    expect(invite.ok(), `admin invite of ${email} -> ${invite.status()}`).toBeTruthy();
  });

When('the API client GETs every admin BFF endpoint', async ({ world }) => {
  const api = world.get<APIRequestContext>('api');
  const statuses: Record<string, number> = {};
  for (const ep of ADMIN_GET_ENDPOINTS) {
    // substep: five distinguishable probes inside one Gherkin step, so a reviewer
    // sees WHICH endpoint answered wrong rather than a single opaque failure.
    await substep(`GET ${ep}`, async () => {
      statuses[ep] = (await api.get(ep)).status();
    });
  }
  world.set('adminEndpointStatuses', statuses);
});

Then('every admin BFF endpoint answered with status {int}', async ({ world }, expected: number) => {
  const statuses = world.get<Record<string, number>>('adminEndpointStatuses');
  for (const [ep, got] of Object.entries(statuses)) {
    expect(got, `GET ${ep}`).toBe(expected);
  }
});

Then('the API client is refused a write to the admin allowlist with status {int}',
  async ({ world }, expected: number) => {
    const api = world.get<APIRequestContext>('api');
    const w = await api.post('/bff/admin/allowlist', { data: { email: 'should-not@gmail.com' } });
    expect(w.status(), 'POST /bff/admin/allowlist').toBe(expected);
  });

Then('the API client session carries the role {string}', async ({ world }, role: string) => {
  const api = world.get<APIRequestContext>('api');
  const me = await api.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(me.status(), 'GET /bff/session').toBe(200);
  expect((await me.json()).roles, 'session roles').toContain(role);
});

Then('the API client session carries exactly the roles {string}', async ({ world }, csv: string) => {
  const api = world.get<APIRequestContext>('api');
  const me = await api.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(me.status(), 'GET /bff/session').toBe(200);
  expect((await me.json()).roles, 'session roles')
    .toEqual(csv.split(',').map((s) => s.trim()).filter(Boolean));
});

// ═════════════════════════════════════════════════════════════════════════════
// 3. THE TWO-STAGE REGISTRATION GATE (spec 17, live UI)
// ═════════════════════════════════════════════════════════════════════════════

When('the unprovisioned identity {string} attempts native sign-in', async ({ page }, handle: string) => {
  // Guard the premise: this scenario is only meaningful while NOTHING seeds the
  // handle. If a roster ever grows it, the deny below would start passing for the
  // wrong reason, so fail here instead.
  expect(
    personaSource(handle),
    `'${handle}' is the UNPROVISIONED identity this scenario denies, but a seeder now `
    + 'creates it — the deny would then be vacuous. Either drop the handle from the roster '
    + 'or rewrite this scenario.',
  ).toBeUndefined();
  await registerOnly(page, handle, personaPassword(handle));
});

Then('the element with test id {string} contains the text {string}',
  async ({ page }, testId: string, text: string) => {
    await expect(page.getByTestId(testId)).toContainText(text);
  });

// ═════════════════════════════════════════════════════════════════════════════
// 4. CONSOLE ACCESS MATRIX (spec 33, live UI)
// ═════════════════════════════════════════════════════════════════════════════

Then('the {string} console is listed in the menubar', async ({ page, dimensions }, name: string) => {
  const c = consoleDef(name);
  const who = dimensions.role ?? 'this persona';
  await expect(
    page.getByTestId(c.navTestId),
    `${who} holds the role, so ${c.route} must be LISTED — a console reachable only by `
    + 'typing the URL is one the operator cannot find',
  ).toBeVisible();
});

Then('the {string} console is not listed in the menubar', async ({ page, dimensions }, name: string) => {
  const c = consoleDef(name);
  const who = dimensions.role ?? 'this persona';
  await expect(
    page.getByTestId(c.navTestId),
    `${who} lacks the role, so ${c.route} must NOT be listed`,
  ).toHaveCount(0);
});

When('I follow the {string} console entry in the menubar', async ({ page, world }, name: string) => {
  const c = consoleDef(name);
  // NOT waitForLoadState('networkidle'): this shell holds a live SSE channel open,
  // so the network is NEVER idle and that wait burns the whole test timeout.
  await page.getByTestId(c.navTestId).click();
  await page.waitForURL(new RegExp(`${c.route}(/|$)`), { timeout: 20_000 });
  world.set('console', name);
});

Then('the {string} console renders its own content', async ({ page }, name: string) => {
  const c = consoleDef(name);
  await expect(page).toHaveURL(new RegExp(`${c.route}(/|$)`));
  await expect(page.locator('body'), `${c.route} must render the real console, not an empty shell`)
    .toContainText(c.proof, { timeout: 20_000 });
});

Then('the moderation console exposes its wired controls', async ({ page }) => {
  const body = page.locator('body');
  for (const control of [/queue/i, /ban/i, /domain.?lock/i, /audit/i]) {
    await expect(body, `the moderation console must render its ${control} panel`)
      .toContainText(control, { timeout: 20_000 });
  }
});

Then('after a settling pause the page body still does not match {string}',
  async ({ page }, pattern: string) => {
    // Same reason as above — never networkidle on this shell. A fixed settle is
    // the honest way to give a WRONGLY-rendering guard time to render.
    await page.waitForTimeout(3_000);
    await expect(page.locator('body')).not.toContainText(new RegExp(pattern, 'i'));
  });

// ═════════════════════════════════════════════════════════════════════════════
// 5. LIVE GATEWAY ENFORCEMENT (spec 14) — activates under LIVE_GATEWAY=1
// ═════════════════════════════════════════════════════════════════════════════

const CASDOOR_URL = process.env.SYSTEMS_CASDOOR_URL || '';
const CASDOOR_ORG = process.env.SYSTEMS_CASDOOR_ORG || 'hugmesh';
const CASDOOR_CLIENT_ID = process.env.SYSTEMS_CASDOOR_CLIENT_ID || '';
const CASDOOR_CLIENT_SECRET = process.env.SYSTEMS_CASDOOR_CLIENT_SECRET || '';

/** Real Casdoor password-grant; returns the access token whose `roles` claim the
 *  gateway reads. Mirrors the private casdoorToken in spec 14 (see file header). */
async function casdoorToken(api: APIRequestContext, username: string): Promise<string> {
  const u = systemsUser(username);
  const mint = async (user: string) => {
    const r = await api.post(`${CASDOOR_URL}/api/login/oauth/access_token`, {
      form: {
        grant_type: 'password',
        client_id: CASDOOR_CLIENT_ID,
        client_secret: CASDOOR_CLIENT_SECRET,
        username: user,
        password: passwordFor(u),
      },
    });
    return r.json();
  };
  // Casdoor resolves the password grant inside the app's organization, so the
  // plain username is canonical; org/name is kept as a fallback.
  let body = await mint(username);
  if (!body.access_token) body = await mint(`${CASDOOR_ORG}/${username}`);
  if (!body.access_token) throw new Error(`casdoor token for ${username}: ${JSON.stringify(body)}`);
  return body.access_token as string;
}

Given('a live gateway and a real systems Casdoor are configured', async ({ $testInfo }) => {
  const missing: string[] = [];
  if (process.env.LIVE_GATEWAY !== '1') missing.push('LIVE_GATEWAY=1');
  if (!CASDOOR_URL) missing.push('SYSTEMS_CASDOOR_URL');
  $testInfo.skip(
    missing.length > 0,
    `PENDING (Phase 8/10): needs ${missing.join(' + ')}. hugmesh-fe-gateway / -be-gateway / `
    + '-pki-gateway are README-only today and the rootless mock stack has no real Casdoor, so '
    + 'the LIVE enforcement path cannot be hit. Seed one with tests/qemu/seed-accounts.sh --roles '
    + 'and set LIVE_GATEWAY=1 to activate this row. The SAME expectation is contract-locked '
    + 'offline by features/rbac/gateway-route-access.feature.',
  );
});

When('the persona for this scenario presents a real Casdoor token to the {string} gateway at {string}',
  async ({ world, dimensions }, gateway: string, path: string) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const gw = gatewayId(gateway);
    const api = trackContext(world, await playwrightRequest.newContext({ ignoreHTTPSErrors: true }));
    const token = await casdoorToken(api, handle);
    const r = await api.get(`${GW_BASE[gw]}${path}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    world.set('liveStatus', r.status());
    world.set('liveHeaders', r.headers());
    world.set('liveWhere', `${gateway} ${path}`);
    world.set('effectiveRoles', effectiveRolesFor(handle));
    world.set('principal', handle);
    world.set('decision', gatewayDecision(gw, path, effectiveRolesFor(handle)));
  });

Then('the live gateway enforcement matches the route-access contract', async ({ world }) => {
  const status = world.get<number>('liveStatus');
  const headers = world.get<Record<string, string>>('liveHeaders');
  const expected = world.get<GatewayDecision>('decision');
  // The contract under test is the GATEWAY's decision, and the gateway says which
  // 401/403s are ITS OWN: an RBAC deny carries X-Route-Denied, a token the
  // resource server rejected carries WWW-Authenticate: Bearer. A 401/403 with
  // NEITHER marker came from the proxied backend (tuwunel's M_UNKNOWN_TOKEN,
  // Mastodon refusing the relayed bearer) — which PROVES the gateway ALLOWED the
  // route. Judging bare status codes misreads every homeserver ALLOW as a deny.
  const gatewayDenied = (status === 401 || status === 403)
    && (headers['x-route-denied'] !== undefined
      || (headers['www-authenticate'] ?? '').startsWith('Bearer'));
  const where = world.get<string>('liveWhere');
  const who = world.get<string>('principal');
  if (expected === 'DENY') {
    expect(gatewayDenied,
      `${who} expected a gateway DENY at ${where} but got ${status} `
      + `(x-route-denied: ${headers['x-route-denied'] ?? 'absent'})`).toBeTruthy();
  } else {
    expect(gatewayDenied,
      `${who} expected ALLOW at ${where} but the gateway denied with ${status} `
      + `(x-route-denied: ${headers['x-route-denied'] ?? 'absent'})`).toBeFalsy();
  }
});

// ═════════════════════════════════════════════════════════════════════════════
// 6. DOMAIN-LOCK × MOD-BAN INTERACTION (spec 23) — federation lane
// ═════════════════════════════════════════════════════════════════════════════

const SUBJECT_HANDLE = 'e2e-mastodon-domainlocked';
const subjectAcct = () => `${SUBJECT_HANDLE}@mastodon.hugmesh.net`;

Given('the federation peer and the domain-lock gate are configured', async ({ $testInfo }) => {
  const reason = federationSkipReason();
  $testInfo.skip(reason !== '', `PENDING: ${reason}`);
});

Given('the domain-locked subject token and the {string} Casdoor JWT are provisioned',
  async ({ $testInfo, world }, who: string) => {
    const subjectToken = process.env['SNAP_MASTODON_TOKEN_E2E_MASTODON_DOMAINLOCKED'] ?? '';
    const envName = `SNAP_CASDOOR_JWT_${who.toUpperCase().replace(/[^A-Z0-9]/g, '_')}`;
    const jwt = process.env[envName] ?? '';
    $testInfo.skip(!subjectToken || !jwt,
      `PENDING: this run did not inject SNAP_MASTODON_TOKEN_E2E_MASTODON_DOMAINLOCKED and/or `
      + `${envName}. seed-accounts.sh --roles writes the test-seed Secret; the live runner `
      + 'injects the tokens. Never faked — a missing token would make the deny vacuous.');
    world.set('subjectToken', subjectToken);
    world.set('actorJwt', jwt);
  });

Given('the peer token is provisioned', async ({ $testInfo, world }) => {
  const peerToken = process.env['SNAP_PEER_TOKEN'] ?? '';
  $testInfo.skip(!peerToken,
    'PENDING: SNAP_PEER_TOKEN is not injected for this run, so the REMOTE observation '
    + '(the whole point of the negative proof) cannot be made.');
  world.set('peerToken', peerToken);
});

Given('the peer follows the domain-locked subject', async ({ request, world }) => {
  const followed = await peerFollow(request, world.get<string>('peerToken'), subjectAcct());
  expect(followed,
    'peer must be able to FOLLOW the local subject (federation reachability) — otherwise a '
    + 'later "the peer never saw it" proves only that nobody was listening').toBeTruthy();
});

When('a plain member calls the mod ban surface for the domain-locked subject',
  async ({ request, world }) => {
    const r = await request.post(`${BE}/bff/mod/ban`, {
      headers: { authorization: `Bearer ${world.get<string>('actorJwt')}` },
      data: { platform: 'mastodon', target: SUBJECT_HANDLE, reason: 'rbac-deny-probe' },
      failOnStatusCode: false,
    });
    world.set('banStatus', r.status());
    world.set('banOk', r.ok());
  });

Then('the mod ban surface refuses the plain member', async ({ world }) => {
  const status = world.get<number>('banStatus');
  expect([401, 403].includes(status),
    `ROLE_USER must be DENIED POST /bff/mod/ban, got ${status}`).toBe(true);
});

Then('the domain-locked subject can still post locally', async ({ request, world }) => {
  // Real absence-of-effect, not merely the status code.
  const needle = marker('deny-noop');
  await postLocalStatus(request, world.get<string>('subjectToken'), `still posting ${needle}`, 'public');
});

When('the domain-locked subject posts a public status locally', async ({ request, world }) => {
  const needle = marker('preban');
  await postLocalStatus(request, world.get<string>('subjectToken'), `pre-ban local post ${needle}`, 'public');
  world.set('marker', needle);
});

Then('that status is visible on the local public timeline', async ({ request, world }) => {
  const r = await request.get(`${LOCAL_MASTODON}/api/v1/timelines/public`, {
    headers: { authorization: `Bearer ${world.get<string>('subjectToken')}` },
    params: { local: 'true', limit: '40' },
  });
  expect(r.ok()).toBeTruthy();
  expect(JSON.stringify(await r.json()), 'the post is visible LOCALLY')
    .toContain(world.get<string>('marker'));
});

Then('the peer never sees that status within the negative window', async ({ request, world }) => {
  await expectPeerNeverSaw(
    request, world.get<string>('peerToken'), subjectAcct(),
    world.get<string>('marker'), NEGATIVE_WINDOW_MS,
  );
});

When('the moderator bans the domain-locked subject on the mastodon platform',
  async ({ request, world }) => {
    const banReason = marker('modban');
    const r = await request.post(`${BE}/bff/mod/ban`, {
      headers: { authorization: `Bearer ${world.get<string>('actorJwt')}` },
      data: { platform: 'mastodon', target: SUBJECT_HANDLE, reason: banReason },
      failOnStatusCode: false,
    });
    world.set('banReason', banReason);
    world.set('banStatus', r.status());
    world.set('banOk', r.ok());
  });

Then('the mod BFF accepts the ban', async ({ world }) => {
  expect(world.get<boolean>('banOk'),
    `mod ban must be ACCEPTED by the mod-bff (got ${world.get<number>('banStatus')})`).toBeTruthy();
});

Then('the banned subject can no longer post locally', async ({ request, world }) => {
  const needle = marker('banned');
  const token = world.get<string>('subjectToken');
  // The bff 2xx alone is NOT the oracle; the enforced effect at the homeserver
  // layer is. Bounded expect.poll — never a bare sleep.
  await expect.poll(async () => {
    const r = await request.post(`${LOCAL_MASTODON}/api/v1/statuses`, {
      headers: { authorization: `Bearer ${token}` },
      data: { status: `post while banned ${needle}`, visibility: 'public' },
      failOnStatusCode: false,
    });
    return r.ok();
  }, {
    message: "the banned subject's LOCAL post attempt must become REJECTED (deactivation applied at the homeserver)",
    timeout: 30_000,
    intervals: [1_000, 2_000, 5_000],
  }).toBe(false);
  world.set('marker', needle);
});

Then('the peer stored view of the subject carries no suspension', async ({ request, world }) => {
  const search = await request.get(`${PEER_BASE}/api/v2/search`, {
    headers: { authorization: `Bearer ${world.get<string>('peerToken')}` },
    params: { q: subjectAcct(), resolve: 'false', type: 'accounts' },
  });
  expect(search.ok()).toBeTruthy();
  const accounts = (await search.json()).accounts ?? [];
  expect(accounts.length, 'the peer already knows the subject (it follows it)').toBeGreaterThan(0);
  expect(accounts[0].suspended === true,
    "the LOCAL ban must NOT surface as a suspension on the peer's stored account").toBe(false);
});

When('the moderator lifts the ban', async ({ request, world }) => {
  const r = await request.delete(`${BE}/bff/mod/ban`, {
    headers: { authorization: `Bearer ${world.get<string>('actorJwt')}` },
    data: { platform: 'mastodon', target: SUBJECT_HANDLE, reason: world.get<string>('banReason') },
    failOnStatusCode: false,
  });
  expect(r.ok(), `ban lift must be ACCEPTED by the mod-bff (got ${r.status()})`).toBeTruthy();
});

Then('the subject can post locally again', async ({ request, world }) => {
  const needle = marker('postlift');
  const token = world.get<string>('subjectToken');
  await expect.poll(async () => {
    const r = await request.post(`${LOCAL_MASTODON}/api/v1/statuses`, {
      headers: { authorization: `Bearer ${token}` },
      data: { status: `post-lift local post ${needle}`, visibility: 'public' },
      failOnStatusCode: false,
    });
    return r.ok();
  }, {
    message: 'after the ban lift the subject must be able to post LOCALLY again',
    timeout: 30_000,
    intervals: [1_000, 2_000, 5_000],
  }).toBe(true);
  world.set('marker', needle);
});

Then('the recovered post still does not reach the peer', async ({ request, world }) => {
  const needle = world.get<string>('marker');
  const reached = await peerSawStatus(
    request, world.get<string>('peerToken'), subjectAcct(), needle, NEGATIVE_WINDOW_MS,
  );
  expect(reached,
    `post-lift toot ${needle} MUST NOT reach the peer ${PEER_BASE} — the domain-lock is `
    + 'independent of the ban lifecycle').toBe(false);
});

// ═════════════════════════════════════════════════════════════════════════════
// 7. PHASE 8/10 SURFACES THAT DO NOT EXIST YET (spec 18)
// ═════════════════════════════════════════════════════════════════════════════

Given('the Phase 8-10 surface {string} has landed', async ({ $testInfo }, surface: string) => {
  // A LOUD, NAMED pending. The scenario is fully wired: the moment the surface
  // exists and SNAP_PHASE8_SURFACES=1 is set, the assertions below RUN. Nothing
  // here fakes a pass and nothing skips silently.
  $testInfo.skip(
    process.env.SNAP_PHASE8_SURFACES !== '1',
    `PENDING (Phase 8/10): the surface '${surface}' does not exist in the host shell today `
    + '(no /games/admin mount, no ROLE_GAMES-conditional nav; SessionService derives only a '
    + 'binary isAdmin). The gateway-layer form of this same expectation IS asserted offline by '
    + 'features/rbac/gateway-route-access.feature. Set SNAP_PHASE8_SURFACES=1 once the UI lands.',
  );
});

// ═════════════════════════════════════════════════════════════════════════════
// 8. ISSUE-TRACED COVERAGE — the 2026-09-23 BDD round (features/rbac/*, @issue:)
//
// Every step below binds a scenario that names a GitHub issue. The world keys
// are the ones the SHARED API vocabulary already pins, so these steps chain
// with it instead of growing a second dialect:
//   world['api']      the APIRequestContext a Given established — reuse
//                     moderation-media's 'I hold an API session as the persona
//                     for this scenario' / 'I hold an anonymous API client'
//                     (both go through helpers.apiContext, which is the ONLY
//                     kind-safe way to build one: a raw request.newContext dies on
//                     `getaddrinfo hugmesh.net` for every @env:kind row).
//   world['response'] / ['responseLabel'] / ['responseBody']
//                     mined-identity's record() shape, so 'the response status
//                     is {int}' and 'the response header {string} is {string}'
//                     read what a POST made here wrote.
//   world['cli.transcript']
//                     common.steps.ts's pinned key for the last cli transcript.
// ═════════════════════════════════════════════════════════════════════════════

type WorldLike = { has(k: string): boolean; get<T>(k: string): T; set<T>(k: string, v: T): void };

async function recordResponse(world: WorldLike, label: string, r: APIResponse): Promise<void> {
  world.set('response', r);
  world.set('responseLabel', label);
  world.set('responseBody', await r.text().catch(() => ''));
}

function responseLabel(world: WorldLike): string {
  const r = world.get<APIResponse>('response');
  return `${world.get<string>('responseLabel')} -> ${r.status()} `
    + `${JSON.stringify(world.get<string>('responseBody')).slice(0, 300)}`;
}

// ── generic HTTP verbs the shared vocabulary lacks (candidates for common.steps) ──

/**
 * A POST with a literal JSON body. The body is parsed HERE so a .feature that
 * mistypes its JSON fails at the step, not as a 400 that reads like the BFF's
 * verdict. The status is recorded, never judged: a refusal is the NEXT step's
 * claim, which is what lets one scenario say "admitted" and its sibling "refused".
 */
When('the API client POSTs {string} with the JSON body {string}',
  async ({ world }, path: string, json: string) => {
    let data: unknown;
    try {
      data = JSON.parse(json);
    } catch (e) {
      throw new Error(`the JSON body written in the .feature is not JSON: ${json} (${(e as Error).message})`);
    }
    const api = world.get<APIRequestContext>('api');
    await recordResponse(world, `POST ${path}`, await api.post(path, { data }));
  });

Then('the response body does not contain {string}', async ({ world }, needle: string) => {
  const body = world.get<string>('responseBody');
  expect(body.includes(needle), `${responseLabel(world)} must not contain ${JSON.stringify(needle)}`)
    .toBe(false);
});

Then('the response status is a 2xx', async ({ world }) => {
  const r = world.get<APIResponse>('response');
  expect(r.status() >= 200 && r.status() < 300, responseLabel(world)).toBe(true);
});

// ── the host shell's launcher cards (hugmesh-host-shell HomeServicesComponent) ──
//
// The public `/home` page renders one card per catalog row as `data-testid="card-<id>"`
// carrying `data-state`: `enabled` (an <a> to the route), `absent` (the optional
// service is not installed), `role` (the session lacks the gating role) or
// `registration` (the two-stage gate is incomplete). A greyed card is a
// <span aria-disabled="true"> with `card-<id>-help` naming the reason. The shell
// GREYS, it never hides — which is why "only for members" is a state assertion,
// not a presence/absence one (specs/18-rbac-phase8-10-pending.spec.ts).

const CARD_STATES = ['enabled', 'absent', 'role', 'registration'] as const;

Then('the launcher card {string} is in state {string}', async ({ page }, card: string, state: string) => {
  if (!(CARD_STATES as readonly string[]).includes(state)) {
    throw new Error(
      `'${state}' is not a launcher-card state. Legal states (hugmesh-host-shell `
      + `home-services.service.ts resolve()): ${CARD_STATES.join(', ')}.`,
    );
  }
  const el = page.getByTestId(card);
  await expect(el, `launcher card '${card}' must render — the shell greys, it never hides`)
    .toBeVisible();
  await expect(el, `launcher card '${card}' data-state`).toHaveAttribute('data-state', state);
  if (state === 'enabled') {
    await expect(el, `an enabled card is a live link`).toHaveAttribute('href', /.+/);
  } else {
    await expect(el, `a greyed card is aria-disabled`).toHaveAttribute('aria-disabled', 'true');
    await expect(page.getByTestId(`${card}-help`),
      `a greyed card EXPLAINS itself (greyed-and-silent is a defect)`).not.toBeEmpty();
  }
});

/**
 * THE DECISION-NEUTRAL CONTRACT behind generator#299 / #295's "enabled card, dead
 * link": a card the shell offers as a live link must be MOUNTABLE — its remote
 * entry must be admitted at the gateway for this same session — and a card the
 * gateway refuses must be greyed. Whichever side moves (the shell grows a role
 * gate, or the seed widens the row), this stays green; only the mismatch fails.
 *
 * `page.request` shares the browser's cookie jar, so the probe is the SAME
 * identity the card was rendered for. Admission means 200 + JSON: the SPA
 * catch-all answers 200 text/html for an unrouted path (the F4 trap in every
 * persona plan), and that is not a mounted remote.
 */
Then('the launcher card {string} agrees with the gateway verdict at {string}',
  async ({ page, dimensions }, card: string, path: string) => {
    const el = page.getByTestId(card);
    await expect(el, `launcher card '${card}' must render`).toBeVisible();
    const state = await el.getAttribute('data-state');
    const r = await page.request.get(path, { headers: { accept: 'application/json' }, maxRedirects: 0 });
    const ct = r.headers()['content-type'] ?? '';
    const admitted = r.status() === 200 && /json/i.test(ct);
    const who = dimensions.role ?? 'this persona';
    const verdict = `${r.status()} ${ct || '(no content-type)'} x-route-denied=${r.headers()['x-route-denied'] ?? '<none>'}`;
    if (state === 'enabled') {
      expect(
        admitted,
        `${who}: '${card}' is offered as a LIVE LINK (data-state=enabled) but the gateway answers `
        + `${verdict} at ${path} — an enabled card into a refused remote is the "enabled card, dead `
        + `link" contract violation (generator#299 N7 / #295 step 14). Either the shell gates the `
        + `card on the same role the route-access seed keys the row on, or the row admits the caller.`,
      ).toBe(true);
    } else {
      expect(
        admitted,
        `${who}: '${card}' is greyed (data-state=${state}) yet the gateway ADMITS ${path} (${verdict}) `
        + `— the card withholds a surface the caller may use.`,
      ).toBe(false);
    }
  });

// ── optional-service gates (the games entry-point, generator#522 / #326) ─────
//
// `games` is an OPTIONAL service and DEFAULT-OFF on every lane this repo brings
// up (specs/cluster/optional-services.yaml), so a role assertion about the games
// card runs on NO default lane — which is exactly generator#522's complaint about
// spec 18. These two gates are exact COMPLEMENTS: whichever install-state a
// stack has, one of the two scenario families runs, and the other SKIPS NAMING
// what to bring up. Read anonymously off the same capability projection the
// shell derives `absent` from, so the gate and the card cannot disagree.

async function capabilityInstalled(
  baseURL: string | undefined, slug: string,
): Promise<{ installed: boolean; detail: string }> {
  const api = await apiContext(baseURL);
  try {
    const r = await api.get('/api/federation/capabilities', { headers: { accept: 'application/json' } });
    if (!r.ok()) return { installed: false, detail: `GET /api/federation/capabilities -> ${r.status()}` };
    const rows = await r.json().catch(() => null);
    const row = Array.isArray(rows) ? rows.find((c) => c && c.slug === slug) : undefined;
    if (!row) return { installed: false, detail: `'${slug}' is absent from the capability projection` };
    return { installed: row.installed === true, detail: `${slug}.installed=${row.installed}` };
  } finally {
    await api.dispose().catch(() => { /* already gone */ });
  }
}

function bringUpHint(slug: string): string {
  return slug === 'games'
    ? 'compose: `make stack-up GAMES=1` then `HUGMESH_FEDERATION_ENABLE=games make stack-seed`'
    : `bring the stack up with the '${slug}' optional service enabled (see specs/cluster/optional-services.yaml)`;
}

Given('the {string} optional service is installed on this stack',
  async ({ baseURL, $testInfo }, slug: string) => {
    const c = await capabilityInstalled(baseURL, slug);
    $testInfo.annotations.push({ type: 'capability-probe', description: c.detail });
    $testInfo.skip(
      !c.installed,
      `the '${slug}' optional service is NOT installed on this stack (${c.detail}). It is `
      + `DEFAULT-OFF, so this row never executes on a default lane — ${bringUpHint(slug)} — `
      + `and it runs as written. Its complement ("… is not installed …") covers this lane.`,
    );
  });

Given('the {string} optional service is not installed on this stack',
  async ({ baseURL, $testInfo }, slug: string) => {
    const c = await capabilityInstalled(baseURL, slug);
    $testInfo.annotations.push({ type: 'capability-probe', description: c.detail });
    $testInfo.skip(
      c.installed,
      `the '${slug}' optional service IS installed on this stack (${c.detail}); the `
      + `installed-state scenarios are the ones that apply here.`,
    );
  });

// ── sign-out lifecycle (generator#549) ──────────────────────────────────────
//
// STATEFUL, never "the endpoint was called": the 2026-08-15 host-shell round
// shipped a sign-out whose own broadcast re-hydrated a still-live cookie, and
// generator#549 shipped a /bff/sessionOut that answered {"loggedOut":true}
// having deleted nothing. Both passed a fetch-was-called test. So the
// assertions are the post-logout STATE, read through the same cookie jar the
// browser holds: the server answers 401 on /bff/session, and the jar carries no
// bff_session at all.

When('I sign out through the account menu', async ({ page }) => {
  await page.getByTestId('profile-trigger').click();
  await page.getByTestId('menu-logout').click();
  // The shell navigates to /login only AFTER the sign-out fetch resolved
  // (session.service.ts clear() awaits it — the 2026-08-15 fix), so reaching
  // /login is the moment the server-side outcome is observable.
  await page.waitForURL(/\/login(\/|$|\?)/, { timeout: 20_000 });
});

Then('my browser session answers status {int} at {string}',
  async ({ page }, status: number, path: string) => {
    await expect.poll(
      async () => (await page.request.get(path, { headers: { accept: 'application/json' } })).status(),
      {
        message: `GET ${path} through the browser's own cookie jar must answer ${status}`,
        timeout: 10_000,
        intervals: [250, 500, 1_000],
      },
    ).toBe(status);
  });

// ── the moderator's guard rails (generator#294 NC4 / NC5) ───────────────────
//
// Both known gaps are WRITES on a shared mesh if the guard is missing: a
// moderator banning an admin, or banning themselves by handle, lands a real
// access_suspension. So the attempt step LIFTS any accepted ban at once (same
// body, DELETE /bff/mod/ban — the console's own lift call) BEFORE the Then
// judges it. The scenario still FAILS when the write landed — the lift is
// hygiene, not forgiveness — and the failure message says it landed and was
// lifted, so nobody inherits a suspension from a red run.

const BAN_PROBE_REASON = 'bdd-rbac-probe';

async function attemptBan(world: WorldLike, target: string, platform: string): Promise<void> {
  const api = world.get<APIRequestContext>('api');
  const body = { platform, target, reason: BAN_PROBE_REASON };
  const r = await api.post('/bff/mod/ban', { data: body });
  await recordResponse(world, `POST /bff/mod/ban {platform:${platform}, target:${target}}`, r);
  if (r.status() >= 200 && r.status() < 300) {
    const lift = await api.delete('/bff/mod/ban', { data: body });
    world.set('banLift', `DELETE /bff/mod/ban -> ${lift.status()}`);
  }
}

When('the moderator attempts to ban {string} on the {string} platform',
  async ({ world }, target: string, platform: string) => {
    await attemptBan(world, target, platform);
  });

When('the moderator attempts to ban their own session id on the {string} platform',
  async ({ world }, platform: string) => {
    const api = world.get<APIRequestContext>('api');
    const me = await api.get('/bff/session', { headers: { accept: 'application/json' } });
    expect(me.status(), 'GET /bff/session for the moderator').toBe(200);
    const id = (await me.json()).id;
    expect(typeof id === 'string' && id.length > 0, '/bff/session carries the session id string').toBe(true);
    await attemptBan(world, id, platform);
  });

Then('the ban attempt was refused', async ({ world }) => {
  const r = world.get<APIResponse>('response');
  const landed = world.has('banLift')
    ? ` — THE WRITE LANDED on the shared mesh and was lifted immediately (${world.get<string>('banLift')})`
    : '';
  expect(r.status(), `${responseLabel(world)}${landed}`).toBe(403);
});

// ── timed access-role suspensions (admin-bff-api#56 / #45) ──────────────────
//
// A timed suspension so a red run self-heals; an explicit lift so a green one
// leaves nothing behind; and an After hook that lifts whatever a scenario failed
// to. The admin context is e2e-admin's own /bff/login session, built kind-safe.

interface PendingSuspension { role: string; user: string }

Given('an admin has suspended the {string} access role of {string} for {int} seconds',
  async ({ baseURL, world }, role: string, user: string, ttl: number) => {
    const admin = trackContext(world, await apiContext(baseURL));
    await loginApiAs(admin, persona('e2e-admin'));
    const r = await admin.post(`/bff/admin/access-roles/${role}/${encodeURIComponent(user)}`, {
      data: { ttlSeconds: ttl, reason: BAN_PROBE_REASON },
    });
    expect(
      r.status() >= 200 && r.status() < 300,
      `POST /bff/admin/access-roles/${role}/${user} (ttl ${ttl}s) -> ${r.status()} ${(await r.text()).slice(0, 200)}`,
    ).toBe(true);
    world.set('adminApi', admin);
    world.set('suspension', { role, user } as PendingSuspension);
  });

When('the admin lifts the {string} access-role suspension of {string}',
  async ({ world }, role: string, user: string) => {
    const admin = world.get<APIRequestContext>('adminApi');
    const r = await admin.delete(`/bff/admin/access-roles/${role}/${encodeURIComponent(user)}`);
    expect(
      r.status() >= 200 && r.status() < 300,
      `DELETE /bff/admin/access-roles/${role}/${user} -> ${r.status()} ${(await r.text()).slice(0, 200)}`,
    ).toBe(true);
    world.set('suspension', undefined as unknown as PendingSuspension);
  });

After(async ({ world }) => {
  // Hygiene for a scenario that suspended and then failed before its lift.
  if (!world.has('suspension') || !world.has('adminApi')) return;
  const s = world.get<PendingSuspension | undefined>('suspension');
  if (!s) return;
  const admin = world.get<APIRequestContext>('adminApi');
  await admin.delete(`/bff/admin/access-roles/${s.role}/${encodeURIComponent(s.user)}`)
    .catch(() => { /* the TTL self-heals; nothing more to do here */ });
});

// ── the gateway fast-path revocation list (admin-bff-api#45) ────────────────
//
// GET /api/gateway/revocations is the gateway's OWN controller (SUPERADMIN
// only) and answers the snapshot set of live keys. The push leg is a logged
// no-op until the service credential exists (decision 45 on generator#347), so
// the scenario is gated on a runner knob that says "this mesh really pushes":
// asserting the list on a mesh that cannot push would fail for the wrong reason
// and read like the fast path is broken rather than unbuilt.

Given('the gateway fast-path revocation broker is enabled on this run', async ({ $testInfo }) => {
  $testInfo.skip(
    process.env.SNAP_GATEWAY_REVOCATION !== '1',
    'set SNAP_GATEWAY_REVOCATION=1 ONLY against a mesh whose admin-bff runs with '
    + 'BROKER_GATEWAY_REVOCATION_ENABLED=true and a Casdoor client_credentials JWT for the '
    + 'gateway revocation API (hugmesh/hugmesh-admin-bff-api#45, blocked on decision 45 of '
    + 'hugmesh-generator#347). Until then every revokeCoarse/revokeSubject is a 401-swallowed '
    + 'no-op and this scenario would fail for the wrong reason.',
  );
});

async function revocationSnapshot(world: WorldLike, baseURL: string | undefined): Promise<string[]> {
  if (!world.has('superadminApi')) {
    const sa = trackContext(world, await apiContext(baseURL));
    await loginApiAs(sa, SUPERADMIN_USERNAME);
    world.set('superadminApi', sa);
  }
  const sa = world.get<APIRequestContext>('superadminApi');
  const r = await sa.get('/api/gateway/revocations', { headers: { accept: 'application/json' } });
  expect(r.status(), `GET /api/gateway/revocations as ${SUPERADMIN_USERNAME}`).toBe(200);
  const body = await r.json();
  expect(Array.isArray(body), 'the revocation snapshot is a JSON array of keys').toBe(true);
  return body as string[];
}

Then('the gateway revocation list holds the key {string}', async ({ baseURL, world }, key: string) => {
  // ≤15 s: a key POSTed to the PKI pod reaches the FE pod's snapshot on the
  // Cassandra poll (app.revocation.refresh-interval-ms, 5 s) — #45, 2026-09-09.
  await expect.poll(async () => (await revocationSnapshot(world, baseURL)).includes(key), {
    message: `the gateway revocation snapshot must hold '${key}'`,
    timeout: 15_000,
    intervals: [1_000, 2_000, 5_000],
  }).toBe(true);
});

Then('the gateway revocation list no longer holds the key {string}', async ({ baseURL, world }, key: string) => {
  await expect.poll(async () => (await revocationSnapshot(world, baseURL)).includes(key), {
    message: `the gateway revocation snapshot must have dropped '${key}'`,
    timeout: 15_000,
    intervals: [1_000, 2_000, 5_000],
  }).toBe(false);
});

// ── cli: a NEGATIVE substring over the whole transcript (generator#505) ─────

Then('the command output carries no line containing {string}', async ({ world }, needle: string) => {
  const t = world.get<CliTranscript>('cli.transcript');
  const hits = `${t.stdout}\n${t.stderr}`.split('\n').filter((l) => l.includes(needle));
  expect(
    hits,
    `\`${t.command}\` output must carry no line containing ${JSON.stringify(needle)}`,
  ).toEqual([]);
});

// ── the docstring twin of the POST step, for bodies that are not one token ───

When('the API client POSTs {string} with this JSON body:', async ({ world }, path: string, body: string) => {
  let data: unknown;
  try {
    data = JSON.parse(body);
  } catch (e) {
    throw new Error(`the JSON docstring under the step is not JSON (${(e as Error).message}):\n${body}`);
  }
  const api = world.get<APIRequestContext>('api');
  await recordResponse(world, `POST ${path}`, await api.post(path, { data }));
});

Then('the response status is not a 2xx', async ({ world }) => {
  const r = world.get<APIResponse>('response');
  expect(r.status() >= 200 && r.status() < 300, responseLabel(world)).toBe(false);
});

// ── replaying a REMEMBERED cookie after sign-out (generator#549) ─────────────
//
// An expiring Set-Cookie empties the jar, so a post-logout 401 through the jar
// proves only that the CLIENT dropped the cookie. The row on the server is the
// thing #549 is about ("deleted no session row"), and the only way to observe
// it is to keep the pre-logout token and present it again, bare, from a context
// that holds nothing else. 401 on that replay is the proof; 200 is the defect.

interface RememberedCookie { name: string; value: string }

Given('I remember the browser cookie {string}', async ({ context, world }, name: string) => {
  const c = (await context.cookies()).find((k) => k.name === name);
  expect(c, `the browser holds a '${name}' cookie to remember`).toBeDefined();
  world.set('rememberedCookie', { name, value: c!.value } as RememberedCookie);
});

Given('I remember the API client cookie {string}', async ({ world }, name: string) => {
  const api = world.get<APIRequestContext>('api');
  const c = (await api.storageState()).cookies.find((k) => k.name === name);
  expect(c, `the API client holds a '${name}' cookie to remember`).toBeDefined();
  world.set('rememberedCookie', { name, value: c!.value } as RememberedCookie);
});

Then('replaying the remembered cookie at {string} answers status {int}',
  async ({ baseURL, world }, path: string, status: number) => {
    const c = world.get<RememberedCookie>('rememberedCookie');
    const bare = trackContext(world, await apiContext(baseURL));
    const r = await bare.get(path, {
      headers: { accept: 'application/json', cookie: `${c.name}=${c.value}` },
    });
    expect(
      r.status(),
      `GET ${path} presenting the pre-sign-out '${c.name}' token from a context holding nothing else `
      + `-> ${r.status()}. A 200 here means the server never deleted the session row: the browser `
      + `dropped its cookie and the session lived on.`,
    ).toBe(status);
  });
