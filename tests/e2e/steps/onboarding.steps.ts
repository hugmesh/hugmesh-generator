// onboarding.steps.ts — step definitions for the ONBOARDING domain features
// (tests/e2e/features/onboarding/), i.e. the executable Gherkin expression of
//
//   specs/01-frontpage.spec.ts             (already expressed by G1's frontpage.feature)
//   specs/02-admin-allowlist.spec.ts       -> features/onboarding/admin-allowlist.feature
//   specs/03-register-gating.spec.ts       -> features/onboarding/register-gating.feature
//   specs/04-five-users.spec.ts            -> features/onboarding/five-users.feature
//   specs/27-native-login.spec.ts          -> features/onboarding/native-login.feature
//   specs/30-node-host-resolution.spec.ts  -> features/onboarding/node-host-resolution.feature
//   (roster reconciliation)                -> features/onboarding/persona-roster-reconciliation.feature
//
// RULES THIS FILE FOLLOWS (features/README.md):
//   * Given/When/Then come from './world' ONLY — a second createBdd() binds to a
//     different `test` instance and the AfterStep evidence hook silently dies.
//   * Every definition REUSES specs/helpers.ts, specs/rbac-roles.ts and
//     steps/dimensions.ts. Nothing here reimplements login, seeding or navigation:
//     the Gherkin must drive the SAME code the handwritten specs drive or the two
//     lanes drift.
//   * No step writes into tests/e2e/screenshots/ (37 git-tracked PNGs the legacy
//     `shot()` helper overwrites in place). Evidence is the AfterStep hook's job.
//
// MERGE NOTE FOR THE OPERATOR: three definitions below are GENERIC UI vocabulary
// ('click the element with test id', '… is disabled', '… is attached') that
// belong in common.steps.ts. They are here because four feature-authoring units
// were editing this tree in parallel and common.steps.ts is a shared file. If two
// units both define one, `npx bddgen` fails LOUDLY on the ambiguity (missingSteps:
// 'fail-on-gen') — that is the gate working, and the fix is to promote the single
// definition into common.steps.ts, never to reword one of them.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect, type Response } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';
import { Given, When, Then, After, requireDimension, substep } from './world';
import { persona, personaSource, shellRoster, knownPersonas } from './dimensions';
import {
  registerOnly, getSession, personaPassword, apiContext,
  parseResolverRules, resolveForNode,
} from '../specs/helpers';
import { SYSTEMS_SEED_USERS } from '../specs/rbac-roles';
import { api, record } from './mined-identity.steps';

// ── generic UI vocabulary (see MERGE NOTE above) ─────────────────────────────

When('I click the element with test id {string}', async ({ page }, testId: string) => {
  await page.getByTestId(testId).click();
});

/**
 * `nav-user`'s own <span> is EMPTY BY DESIGN in the opaque-cookie model (the
 * browser never learns the display label), so it has zero rendered size and
 * toBeVisible() would never resolve. specs/helpers.ts onboard() waits for
 * 'attached' for exactly this reason; spec 04 asserts toBeAttached(). Asserting
 * visibility here would be a step that can only ever time out.
 */
Then('the element with test id {string} is attached', async ({ page }, testId: string) => {
  await expect(page.getByTestId(testId)).toBeAttached();
});

// ── 02 — admin allowlist ─────────────────────────────────────────────────────

/**
 * Admin is reached through the host's PROFILE MENU (profile-trigger -> menu-admin),
 * not a top-level nav shortcut. Spec 02 carries the scar: it used to click a
 * `nav-admin` testid that no longer exists anywhere in the UI (the same stale-nav
 * pattern specs 08/09 fixed). Encoded as one step so no feature file can
 * re-introduce the wrong route by spelling its own clicks.
 */
When('I open the admin console from the profile menu', async ({ page }) => {
  await substep('open the profile menu', async () => {
    await page.getByTestId('profile-trigger').click();
  });
  await substep('choose Admin', async () => {
    await page.getByTestId('menu-admin').click();
  });
});

When('I invite the email identity {string}', async ({ page }, email: string) => {
  await page.getByTestId('admin-email').fill(email);
  await page.getByTestId('admin-invite').click();
});

Then('the allowlist shows the email identity {string}', async ({ page }, email: string) => {
  await expect(page.locator(`[data-email="${email}"]`)).toBeVisible();
});

When('I invite the Discord identity {string}', async ({ page }, handle: string) => {
  await page.getByTestId('admin-discord').fill(handle);
  await page.getByTestId('admin-invite-discord').click();
});

Then('the allowlist shows the Discord identity {string}', async ({ page }, handle: string) => {
  await expect(page.locator(`[data-discord="${handle}"]`)).toBeVisible();
});

// ── 03 — registration gating ─────────────────────────────────────────────────

/**
 * Native login has NO self-registration surface: an identity no admin provisioned
 * simply fails to sign in (Casdoor 401 invalid_credentials -> "Sign-in failed").
 *
 * The handle is a STEP ARGUMENT, deliberately NOT the `@role:` dimension: the
 * whole point is that nothing seeds it, and `@role:` only accepts handles a
 * seeder creates (steps/dimensions.ts persona()). A scenario tagged
 * `@role:mallory@gmail.com` would throw in the Before hook, which is the
 * dimension vocabulary doing its job — so the un-provisioned identity travels as
 * data instead, guarded by the companion step below.
 */
When('I attempt native sign-in as the unprovisioned identity {string}',
  async ({ page }, handle: string) => {
    await registerOnly(page, handle, personaPassword(handle));
  });

Then('the sign-in is refused with the message {string}', async ({ page }, message: string) => {
  await expect(page.getByTestId('login-error')).toContainText(message);
});

/**
 * The INVERSE of common.steps.ts's 'the persona named by the role dimension is
 * seeded'. If someone ever adds this handle to a roster, the denial scenario
 * above stops testing a denial and starts testing a login — silently. This makes
 * that go red instead. Runs offline.
 */
Then('no seeder provisions the identity {string}', async ({}, handle: string) => {
  const src = personaSource(handle);
  expect(
    src,
    `'${handle}' is meant to be the UN-PROVISIONED identity the denial scenarios rely on, `
    + `but a seeder now creates it (${src}). Either drop it from the roster or pick a `
    + `different never-seeded handle — do NOT leave a "denied" scenario pointed at an `
    + `account that can log in. Known handles: ${knownPersonas().join(', ')}`,
  ).toBeUndefined();
});

// ── deliberately-gated personas (never "fixed" into onboarded ones) ──────────

/**
 * tests/stack/seed-e2e.sh pins three personas OUT of the optional
 * SEED_COMPLETE_REGISTRATION sweep, because their GATED state is the thing specs
 * 17/28/29 assert:
 *
 *   e2e-pending            registrationComplete:false is its entire contract (rbac-roles.ts)
 *   rbac-pending-gmail-com spec 17 drives the pending-registration card with it
 *   e2e-banned             spec 28 pins it 403 on both homeserver surfaces
 *
 * The skip list spells the CASDOOR-FOLDED name (rbac-pending-gmail-com), while
 * the login handle is the email (rbac-pending@gmail.com) — this step folds and
 * accepts either, so a feature can name the persona the way it logs in.
 *
 * Reading the default out of the shell script is the point: a copy of the list
 * here would be a fourth divergent roster.
 */
const SEED_E2E_SH = path.resolve(__dirname, '..', '..', 'stack', 'seed-e2e.sh');

function foldHandle(handle: string): string {
  return handle.replace(/[^A-Za-z0-9]+/g, '-');
}

function registrationSkipDefault(): string[] {
  let text: string;
  try {
    text = fs.readFileSync(SEED_E2E_SH, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read ${SEED_E2E_SH}: ${(e as Error).message}. That script owns the `
      + `SEED_REGISTRATION_SKIP default — refusing to fall back to a hard-coded copy, `
      + `which is exactly how this repo grew divergent persona lists.`,
    );
  }
  const m = text.match(/SEED_REGISTRATION_SKIP="\$\{SEED_REGISTRATION_SKIP:-([^}"]*)\}"/);
  if (!m) {
    throw new Error(
      `could not find the SEED_REGISTRATION_SKIP default in ${SEED_E2E_SH}. The grammar `
      + `changed; fix this parser rather than letting the gated-persona guard pass `
      + `against an empty list.`,
    );
  }
  return m[1].trim().split(/\s+/).filter(Boolean);
}

Then('the persona is deliberately left un-onboarded by the seeder', async ({ dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const skip = registrationSkipDefault();
  const folded = skip.map(foldHandle);
  expect(
    folded.includes(foldHandle(handle)),
    `'${handle}' must stay on tests/stack/seed-e2e.sh's SEED_REGISTRATION_SKIP default `
    + `(currently: ${skip.join(', ')}). Its GATED state is what specs 17/28/29 assert; `
    + `onboarding it launders away the state under test.`,
  ).toBe(true);
});

/**
 * e2e-pending is the SINGLE catalogue entry declaring registrationComplete:false
 * and zero roles (specs/rbac-roles.ts; spec 15 asserts the same invariant over
 * the catalogue). Offline.
 */
Then('the seed catalogue models the persona as registration-incomplete with no roles',
  async ({ dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const u = SYSTEMS_SEED_USERS.find((x) => x.username === handle);
    expect(u, `'${handle}' is not in specs/rbac-roles.ts SYSTEMS_SEED_USERS`).toBeDefined();
    expect(u!.registrationComplete, `${handle}.registrationComplete`).toBe(false);
    expect(u!.roles, `${handle}.roles`).toHaveLength(0);
  });

/**
 * Pins a persona's EXACT granted role set. Two of these are load-bearing and are
 * documented as such in tests/e2e-extra-personas.sh:
 *   e2e-fleet  granting it ROLE_ADMIN turns spec 29's gateway MFA leg vacuous
 *              (ADMIN short-circuits BEFORE decide()).
 *   e2e-banned granting it a platform role destroys spec 28 A5's "the only ban is
 *              coarse" proof — it must hold ROLE_USER and nothing else.
 * Offline; reads the shell roster and the TS catalogue, never a copy.
 */
Then('the persona holds exactly the seeded roles {string}', async ({ dimensions }, csv: string) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const want = csv.split(',').map((s) => s.trim()).filter(Boolean).sort();
  const sh = shellRoster().find((p) => p.username === handle);
  const ts = SYSTEMS_SEED_USERS.find((u) => u.username === handle);
  const got = (sh ? [...sh.roles] : ts ? [...ts.roles] : undefined);
  expect(got, `no roster grants roles to '${handle}'`).toBeDefined();
  expect(got!.slice().sort(), `granted roles for ${handle}`).toEqual(want);
});

// ── 04 — five users / session hydration ──────────────────────────────────────

/**
 * Spec 04 asserts `session.provider === 'password'`. TODAY that field is a
 * CONSTANT in specs/helpers.ts getSession() (the opaque-cookie session exposes no
 * provider to the browser), so this pins the SHAPE rather than a live value — and
 * it goes red the day someone hydrates `provider` from /bff/session and the
 * removed Google/Discord providers reappear. Stated here rather than left to look
 * like a live assertion.
 */
Then('my session provider is {string}', async ({ page, world, dimensions }, provider: string) => {
  const handle = world.has('session')
    ? (world.get<{ username: string }>('session')).username
    : requireDimension(dimensions, 'role');
  const s = await getSession(page, handle);
  expect(s.provider, `session provider for ${handle}`).toBe(provider);
});

// ── 27 — native login (/bff/login, Casdoor never browser-exposed) ────────────

Given('I am recording every main-frame navigation', async ({ page, world }) => {
  const navigated: string[] = [];
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) navigated.push(f.url()); });
  world.set('navigations', navigated);
});

/**
 * Drives the login-ui's OWN username/password form — the ONLY login surface —
 * and captures the POST /bff/login response so the scenario can assert on it.
 * The submit itself is specs/helpers.ts registerOnly(): same code the handwritten
 * specs run, including the page.goto('/login') it does first.
 */
When('I sign in through the native login form as the persona for this scenario',
  async ({ page, dimensions, world }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const loginPost = page.waitForResponse(
      (r) => r.url().includes('/bff/login') && r.request().method() === 'POST',
    );
    // If the SUBMIT itself blows up (stack down, ERR_CONNECTION_REFUSED), this
    // pending wait rejects too and Playwright prints it as a confusing SECOND
    // error beside the real one. Attaching a no-op handler marks that secondary
    // rejection as handled WITHOUT swallowing it: the `await` below still sees
    // the original promise, so a genuine "no POST /bff/login was ever made"
    // still fails the step.
    loginPost.catch(() => { /* reported by the await below, or by registerOnly */ });
    await registerOnly(page, handle, personaPassword(handle));
    world.set('loginResponse', await loginPost);
  });

Then('the POST to {string} was accepted', async ({ world }, urlFragment: string) => {
  const resp = world.get<Response>('loginResponse');
  expect(resp.url()).toContain(urlFragment);
  expect(resp.status(), `POST ${urlFragment} succeeds`).toBeLessThan(400);
});

/**
 * The session cookie is minted SERVER-SIDE by the user-bff (internal Casdoor
 * /api/login + PKCE exchange). The browser must hold an httpOnly opaque token and
 * NO JWT/access token.
 */
Then('the browser holds an httpOnly cookie named {string} whose value starts with {string}',
  async ({ context }, name: string, prefix: string) => {
    await expect
      .poll(async () => (await context.cookies()).some((c) => c.name === name && c.httpOnly))
      .toBe(true);
    const cookie = (await context.cookies()).find((c) => c.name === name);
    expect(cookie?.value.startsWith(prefix), `opaque ${prefix} session token`).toBe(true);
  });

Then('no main-frame navigation reached a Casdoor origin', async ({ world }) => {
  const navigated = world.get<string[]>('navigations');
  expect(navigated.length, 'at least one navigation was recorded').toBeGreaterThan(0);
  for (const url of navigated) {
    expect(url, `must not visit Casdoor: ${url}`).not.toMatch(/casdoor|id\.hugmesh\.net/i);
  }
});

// ── 30 — Node-side host resolution (STACK-FREE) ──────────────────────────────
//
// `--host-resolver-rules` is BROWSER-ONLY. Node-side API contexts (and
// page.request, which is easy to mistake for browser-side) die on
// `getaddrinfo ENOTFOUND hugmesh.net` on kind. resolveForNode() dials the mapped
// IP and carries the hostname in Host, which is what ingress-nginx routes on.
// The property that makes it safe to adopt suite-wide is that with
// SNAP_HOST_RESOLVER UNSET it is a NO-OP.

Given('the Node host resolver rules are unset', async ({ world }) => {
  world.set('resolverRules', parseResolverRules(undefined));
});

Given('the Node host resolver rules are {string}', async ({ world }, spec: string) => {
  world.set('resolverRules', parseResolverRules(spec));
});

When('I resolve {string} for a Node-side API request', async ({ world }, url: string) => {
  world.set('resolved', resolveForNode(url, world.get('resolverRules')));
});

Then('the resolved URL is unchanged as {string}', async ({ world }, url: string) => {
  expect(world.get<{ url: string }>('resolved').url).toBe(url);
});

Then('the resolved hostname is {string} and the port is {string}',
  async ({ world }, hostname: string, port: string) => {
    const u = new URL(world.get<{ url: string }>('resolved').url);
    expect(u.hostname).toBe(hostname);
    expect(u.port).toBe(port);
  });

/** Hostname WITHOUT the port — the exact shape proven to route on kind. */
Then('the resolved request carries the Host header {string}', async ({ world }, host: string) => {
  expect(world.get<{ headers: Record<string, string> }>('resolved').headers.Host).toBe(host);
});

Then('the resolved request adds no extra headers', async ({ world }) => {
  expect(world.get<{ headers: Record<string, string> }>('resolved').headers).toEqual({});
});

// ── persona roster reconciliation (STACK-FREE) ───────────────────────────────
//
// THE DISCREPANCY, NAMED. There are THREE static rosters, not two:
//
//   A  tests/e2e/specs/rbac-roles.ts SYSTEMS_SEED_USERS       17 handles (TS)
//   B  tests/qemu/seed-accounts.sh   SYSTEMS_ROLE_USERS       16 handles (shell, the
//                                                             base matrix — A minus
//                                                             the superadmin)
//   C  tests/e2e-extra-personas.sh   E2E_EXTRA_PERSONAS       15 handles (shell, the
//                                                             extras, incl. superadmin)
//
// Union = 31 distinct handles. steps/dimensions.ts personaSource() reads only A
// and C, so it labels the 16 base handles 'ts-catalogue' — which reads as "the
// shell lane does not seed this", and that is FALSE: tests/stack/seed-e2e.sh
// reconstructs B via `seed-accounts.sh --roles` into BASE_SPECS and seeds
// BASE_SPECS + C together. Exactly ONE handle (e2e-superadmin) is in both A and C
// and therefore reports 'both'.
//
// Rather than silently pick a side, the reconciliation feature declares each
// handle's expected source AND asserts the shell lane really does seed it —
// which is what turns "the lists disagree" into something that fails when the
// disagreement changes shape.

const SEED_ACCOUNTS_SH = path.resolve(__dirname, '..', '..', 'qemu', 'seed-accounts.sh');

let baseRosterCache: string[] | undefined;

/** The base matrix seed-accounts.sh seeds when nobody overrides SYSTEMS_ROLE_USERS. */
function seedAccountsBaseRoster(): string[] {
  if (baseRosterCache) return baseRosterCache;
  let text: string;
  try {
    text = fs.readFileSync(SEED_ACCOUNTS_SH, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read ${SEED_ACCOUNTS_SH}: ${(e as Error).message}. It owns the BASE persona `
      + `matrix that tests/stack/seed-e2e.sh reconstructs into BASE_SPECS; without it this `
      + `guard cannot tell a TS-only persona from one the shell lane really seeds.`,
    );
  }
  const block = text.match(/SYSTEMS_ROLE_USERS="\$\{SYSTEMS_ROLE_USERS:-([\s\S]*?)\}"/);
  if (!block) {
    throw new Error(
      `could not find the default SYSTEMS_ROLE_USERS block in ${SEED_ACCOUNTS_SH}. The `
      + `grammar changed — fix this parser rather than letting every row pass against an `
      + `empty base roster.`,
    );
  }
  const names = [...block[1].matchAll(/^\s*([A-Za-z0-9@._-]+):/gm)].map((m) => m[1]);
  if (names.length === 0) {
    throw new Error(`parsed ZERO base personas out of ${SEED_ACCOUNTS_SH}; fix the parser.`);
  }
  baseRosterCache = names;
  return names;
}

Then('the persona is catalogued as coming from the {string} roster',
  async ({ dimensions }, expected: string) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    expect(
      personaSource(handle),
      `steps/dimensions.ts personaSource('${handle}') — the feature's Examples table `
      + `declares this handle's origin; if the two rosters were reconciled, update the `
      + `table rather than deleting the row.`,
    ).toBe(expected);
  });

Then('a shell seeder really does create the persona', async ({ dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const inBase = seedAccountsBaseRoster().includes(handle);
  const inExtras = shellRoster().some((p) => p.username === handle);
  expect(
    inBase || inExtras,
    `'${handle}' is seeded by NEITHER tests/qemu/seed-accounts.sh's base matrix nor `
    + `tests/e2e-extra-personas.sh, so the compose/kind seeders never create it and a `
    + `feature naming it would 401 at login with a bare "invalid credentials".`,
  ).toBe(true);
});

// ═══════════════════════════════════════════════════════════════════════════
// The provider registration legs + sign-out  (identity lane, 2026-09-23)
//
//   features/onboarding/register-provider-paths.feature   #366 / user-bff #16 #19 #14
//   features/onboarding/email-register.feature            gateway #29 / user-bff #13
//   features/onboarding/native-login.feature (#306 row)
//   features/mined-identity/sign-out-ends-session.feature (#549 / #569)
//
// Everything below drives the SAME front door the browser lane drives, through
// the resolver-aware apiContext() (so a @env:kind row resolves hugmesh.net the
// way tests/e2e/run.sh --env kind expects) and records into the SAME world keys
// mined-identity.steps.ts's `record()` / `the response status is {int}` read.
// ═══════════════════════════════════════════════════════════════════════════

/** An identity this scenario invited itself; provider decides the body shape. */
interface InvitedIdentity { provider: 'google' | 'discord'; handle: string }

const ONBOARDING_CONTEXTS = 'onboarding:contexts';
const ONBOARDING_INVITES = 'onboarding:invites';
const ONBOARDING_ADMIN_API = 'onboarding:adminApi';
/** The admin the suite already uses to invite identities (spec 02). */
const INVITING_ADMIN = 'admin@hugmesh.net';

function trackOnboardingContext(
  world: { has(k: string): boolean; get<T>(k: string): T; set<T>(k: string, v: T): void },
  ctx: APIRequestContext,
): APIRequestContext {
  const list = world.has(ONBOARDING_CONTEXTS) ? world.get<APIRequestContext[]>(ONBOARDING_CONTEXTS) : [];
  list.push(ctx);
  world.set(ONBOARDING_CONTEXTS, list);
  return ctx;
}

/** LEAVE NO TRACE. Every identity a scenario invited is un-invited again, even
 *  when a step in between failed — the running stack is the operator's, and
 *  the admin allowlist console is a surface they read by hand. The ACCOUNT row
 *  a successful registration created cannot be removed through any front-door
 *  API (there is none), which is why the handle carries a `bdd-` prefix and a
 *  per-run stamp: recognisable, and never colliding with a seeded persona. */
After(async ({ world }) => {
  if (world.has(ONBOARDING_INVITES) && world.has(ONBOARDING_ADMIN_API)) {
    const admin = world.get<APIRequestContext>(ONBOARDING_ADMIN_API);
    for (const inv of world.get<InvitedIdentity[]>(ONBOARDING_INVITES)) {
      const data = inv.provider === 'google' ? { email: inv.handle } : { discord: inv.handle };
      await admin.delete('/bff/admin/allowlist', { data }).catch(() => { /* best effort */ });
    }
  }
  if (world.has(ONBOARDING_CONTEXTS)) {
    for (const ctx of world.get<APIRequestContext[]>(ONBOARDING_CONTEXTS)) {
      await ctx.dispose().catch(() => { /* already torn down with the test */ });
    }
  }
});

async function signedInApi(
  baseURL: string | undefined,
  world: { has(k: string): boolean; get<T>(k: string): T; set<T>(k: string, v: T): void },
  handle: string,
): Promise<APIRequestContext> {
  const ctx = trackOnboardingContext(world, await apiContext(baseURL));
  const r = await ctx.post('/bff/login', {
    data: { username: handle, password: personaPassword(handle) },
  });
  expect(r.status(), `native login ${handle} -> ${r.status()}`).toBe(200);
  return ctx;
}

/** A per-run stamp: a registration that succeeded is durable (the account row
 *  survives an un-invite), so a FIXED handle would be "already complete" from
 *  the second run on and the fresh-registration legs would read as a regression. */
function freshStamp(): string {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/** Invite `identity` as the suite's admin through the real
 *  POST /bff/admin/allowlist (AdminController#invite: durable allowlist row +
 *  best-effort Casdoor record), and remember it for the After hook. */
async function inviteAsAdmin(
  baseURL: string | undefined,
  world: { has(k: string): boolean; get<T>(k: string): T; set<T>(k: string, v: T): void },
  identity: InvitedIdentity,
): Promise<void> {
  const admin = world.has(ONBOARDING_ADMIN_API)
    ? world.get<APIRequestContext>(ONBOARDING_ADMIN_API)
    : await signedInApi(baseURL, world, INVITING_ADMIN);
  world.set(ONBOARDING_ADMIN_API, admin);
  const data = identity.provider === 'google' ? { email: identity.handle } : { discord: identity.handle };
  const r = await admin.post('/bff/admin/allowlist', { data });
  const invites = world.has(ONBOARDING_INVITES) ? world.get<InvitedIdentity[]>(ONBOARDING_INVITES) : [];
  invites.push(identity);
  world.set(ONBOARDING_INVITES, invites);
  expect(
    r.status(),
    `${INVITING_ADMIN} inviting ${identity.provider}:${identity.handle} -> ${r.status()} `
    + `${(await r.text().catch(() => '')).slice(0, 300)}. A 422 here is the reserved/confusable `
    + `username gate refusing the DERIVED username, not a registration defect.`,
  ).toBe(200);
}

Given('a freshly invited Gmail identity for this scenario', async ({ baseURL, world }) => {
  const identity: InvitedIdentity = { provider: 'google', handle: `bdd-invite-${freshStamp()}@gmail.com` };
  await inviteAsAdmin(baseURL, world, identity);
  world.set('invitedIdentity', identity);
});

Given('a freshly invited Discord identity for this scenario', async ({ baseURL, world }) => {
  const identity: InvitedIdentity = { provider: 'discord', handle: `bdd-invite-${freshStamp()}` };
  await inviteAsAdmin(baseURL, world, identity);
  world.set('invitedIdentity', identity);
});

function registerBody(identity: InvitedIdentity): Record<string, string> {
  return identity.provider === 'google' ? { email: identity.handle } : { username: identity.handle };
}

/**
 * POST the invited identity to its provider's registration path THROUGH THE
 * CALLER'S CURRENT SESSION. That is not an accident of the step: the front door
 * seeds `/bff/register/**` as ROLE_USER (route-access row :627) and lists no
 * `/bff/register/*` in the gateway's PUBLIC_PATHS, so an anonymous registration
 * POST is 401'd before any BFF sees it (hugmesh-gateway#29 records the same for
 * `/bff/register`). A signed-in member is therefore the only front-door caller
 * these legs have today. On success user-bff's emitAndSession mints the NEW
 * account's bff_ cookie onto this same jar — from here on `the API client` IS
 * the freshly registered identity, which is exactly what the follow-up steps
 * assert on.
 */
When('the API client registers the invited identity through {string}',
  async ({ world }, path: string) => {
    const identity = world.get<InvitedIdentity>('invitedIdentity');
    const data = registerBody(identity);
    await record(world, `POST ${path} ${JSON.stringify(data)}`, await api(world).post(path, { data }));
  });

/**
 * The precondition of the decision-57 leg: an invited identity whose account is
 * ALREADY registrationComplete. Built through the same front-door legs a user
 * takes, and idempotent on a persistent stack:
 *   * 200  -> a fresh account; complete its registration now
 *   * 409  -> already complete (decision 57's answer, once it lands)
 *   * 503  -> already complete, on a user-bff that still answers the pre-decision
 *             refusal (hugmesh-user-bff-api#19's declared 503)
 * so the SECOND registration, the one the scenario asserts on, always meets a
 * completed account. Anything else is a real failure and says which leg.
 */
Given('the invited {string} identity {string} already holds a completed registration',
  async ({ baseURL, world }, provider: string, handle: string) => {
    if (provider !== 'google' && provider !== 'discord') {
      throw new Error(`provider must be google or discord, got '${provider}'`);
    }
    const identity: InvitedIdentity = { provider, handle };
    await inviteAsAdmin(baseURL, world, identity);
    world.set('invitedIdentity', identity);
    const path = `/bff/register/${provider}`;
    const r = await api(world).post(path, { data: registerBody(identity) });
    const body = (await r.text().catch(() => '')).slice(0, 300);
    if (r.status() === 200) {
      const done = await api(world).post('/bff/register/complete', { data: { displayName: handle } });
      expect(done.status(), `POST /bff/register/complete for the fresh ${identity.provider}: account`)
        .toBe(200);
      return;
    }
    expect(
      [409, 503],
      `${path} for an identity that should either be fresh (200) or already complete `
      + `(409, or the pre-decision-57 503) answered ${r.status()} ${body}`,
    ).toContain(r.status());
  });

When('the API client completes registration with the display name {string}',
  async ({ world }, displayName: string) => {
    await record(world, `POST /bff/register/complete {displayName:'${displayName}'}`,
      await api(world).post('/bff/register/complete', { data: { displayName } }));
  });

/** GET /bff/session through the client's CURRENT jar and pin who it now is. */
async function apiSession(world: any): Promise<Record<string, unknown>> {
  const r = await api(world).get('/bff/session', { headers: { accept: 'application/json' } });
  expect(r.status(), `GET /bff/session -> ${r.status()} ${(await r.text().catch(() => '')).slice(0, 200)}`)
    .toBe(200);
  return r.json();
}

Then('the API client session is a {string} account for the invited identity',
  async ({ world }, provider: string) => {
    const identity = world.get<InvitedIdentity>('invitedIdentity');
    const s = await apiSession(world);
    expect(s.provider, `session provider after registering ${identity.handle}`).toBe(provider);
    expect(
      String(s.handle).toLowerCase(),
      `the session must now be the REGISTERED identity's — a jar still carrying the `
      + `caller's previous session means emitAndSession minted no cookie`,
    ).toBe(identity.handle.toLowerCase());
  });

Then('the API client session registration is complete', async ({ world }) => {
  expect((await apiSession(world)).registrationComplete, 'session.registrationComplete').toBe(true);
});

Then('the API client session registration is not complete', async ({ world }) => {
  expect((await apiSession(world)).registrationComplete, 'session.registrationComplete').toBe(false);
});

// ── #306 Family A: repeated native sign-ins in a short window ────────────────

When('the API client signs in natively {int} times in a row as the persona for this scenario',
  async ({ baseURL, dimensions, world }, times: number) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const statuses: number[] = [];
    let last: APIRequestContext | undefined;
    for (let i = 1; i <= times; i += 1) {
      // substep: N distinguishable sign-ins, so a reviewer sees WHICH one 401'd
      // rather than a single opaque failure.
      await substep(`native sign-in ${i}/${times} as ${handle}`, async () => {
        const ctx = trackOnboardingContext(world, await apiContext(baseURL));
        const r = await ctx.post('/bff/login', {
          data: { username: handle, password: personaPassword(handle) },
        });
        statuses.push(r.status());
        last = ctx;
      });
    }
    world.set('signInStatuses', statuses);
    world.set('api', last);
    world.set('username', handle);
  });

Then('every native sign-in in that run was accepted', async ({ world }) => {
  const statuses = world.get<number[]>('signInStatuses');
  expect(
    statuses,
    `POST /bff/login statuses in order: ${statuses.join(', ')}. A 401 that appears only `
    + `after earlier 200s with the SAME correct password is hugmesh-generator#306's Family A `
    + `shape — not a wrong password.`,
  ).toEqual(statuses.map(() => 200));
});

// ── sign-out through the shell (hugmesh-generator#549) ──────────────────────

/** The host shell's account menu: profile-trigger opens it, menu-logout is the
 *  'Sign out' entry (hugmesh-host-shell header-controls.component.ts:161). Its
 *  handler AWAITS POST /bff/sessionOut before clearing local state and returning
 *  to the authgate — the 2026-08-15 fix — which is why the assertions that
 *  follow may read the post-logout state straight away. */
When('I sign out through the profile menu', async ({ page }) => {
  await page.getByTestId('profile-trigger').click();
  await page.getByTestId('menu-logout').click();
});

/** page.request shares the BROWSER's cookie jar, so this is the same question
 *  the shell asks on its next hydrate — served from the same cookies. */
Then('a browser GET to {string} answers {int}', async ({ page }, path: string, status: number) => {
  const r = await page.request.get(path, { headers: { accept: 'application/json' } });
  expect(
    r.status(),
    `GET ${path} from the browser's own jar -> ${r.status()}. After a sign-out this must be `
    + `401: a 200 means the server session is still alive and the shell's next hydrate `
    + `signs the user straight back in.`,
  ).toBe(status);
});

Then('the browser holds no cookie named {string}', async ({ context }, name: string) => {
  await expect
    .poll(async () => (await context.cookies()).some((c) => c.name === name), {
      message: `'${name}' must be gone from the browser jar after sign-out`,
    })
    .toBe(false);
});

/** Register an arbitrary handle (invited or not) through a provider path. The
 *  body shape follows the path's provider — RegisterEmailRequest {email} for
 *  google, RegisterDiscordRequest {username} for discord — so an Examples row
 *  names the handle and never spells JSON into a table cell. */
When('the API client registers the handle {string} through {string}',
  async ({ world }, handle: string, path: string) => {
    const provider = path.endsWith('/google') ? 'google' : path.endsWith('/discord') ? 'discord' : null;
    if (!provider) {
      throw new Error(`'${path}' is not a provider registration path (…/google or …/discord)`);
    }
    const data = registerBody({ provider, handle });
    await record(world, `POST ${path} ${JSON.stringify(data)}`, await api(world).post(path, { data }));
  });
