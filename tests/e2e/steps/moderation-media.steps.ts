// moderation-media.steps.ts — step definitions for the moderation + media domain:
// the executable Gherkin expression of the handwritten specs
//
//   specs/08-usage.spec.ts                       admin usage analytics (ClickHouse)
//   specs/09-namespace-access.spec.ts            admin namespace grants (KNOWN-RED)
//   specs/24-final-e2e-sweep.spec.ts             scaled-concurrent swarm sweep
//   specs/28-sticker-character-vn-moderation.spec.ts  sticker/character/VN + moderation
//   specs/29-mfa-privileged-floor.spec.ts        gateway MFA enforcement + floor
//
// CONTRACT (tests/e2e/features/README.md): Given/When/Then come from './world'
// and NEVER from 'playwright-bdd' — a second createBdd() binds to a different
// `test` instance and the AfterStep evidence hook silently stops firing.
//
// REUSE, NOT REIMPLEMENTATION. Everything that already exists is imported:
//   ../specs/helpers      apiContext, onboard, personaPassword, shot, SUPERADMIN_USERNAME
//   ../specs/totp         totpCode, totpCodeForStep   (the RFC 6238 generator itself)
//   ../specs/swarm-driver swarm, loadToken, premintReady, runConcurrently,
//                         swarmTargetsForMod, assertControlAtLayers, expectObservedWithin
//   ./dimensions          service()  — the BFF prefixes are read off the SERVICE
//                         vocabulary rather than re-spelled here
//
// THE ONE THING DUPLICATED, AND WHY. specs 28 and 29 each carry a PRIVATE
// `loginAs(api, username)` (native /bff/login + registration stage 2 over an
// APIRequestContext). Neither is exported and helpers.ts has no API-context
// login — helpers.onboard() drives a `page`. Rather than edit the SHARED
// helpers.ts (four other feature authors are working the same tree in parallel),
// `apiSignIn()` below reproduces exactly those two functions' body and cites
// them. If helpers.ts ever exports one, delete this and import it.

import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Given, When, Then, Before, After, requireDimension, substep } from './world';
import { service, persona } from './dimensions';
import { apiContext, personaPassword, SUPERADMIN_USERNAME } from '../specs/helpers';
import { totpCode, totpCodeForStep } from '../specs/totp';
import {
  swarm, loadToken, premintReady, runConcurrently, swarmTargetsForMod,
  assertControlAtLayers, expectObservedWithin, type LayerExpectation,
} from '../specs/swarm-driver';

// ── constants lifted verbatim from the specs these steps mirror ──────────────

/** spec 28: a genuinely-valid 1x1 PNG (passes the magic-byte sniff). */
const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
);
/** spec 28: PNG magic bytes + >1MB payload — passes the sniff, trips the 1MB cap. */
const PNG_OVERSIZE = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.alloc(1_200_000),
]);
/** spec 28: SVG is text/markup — trips the magic-byte sniff. */
const SVG_BYTES = Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>',
);
/** spec 28: a <script> in the payload proves the part sanitizer strips it. */
const DIRTY_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
  + '<script>alert(1)</script><rect width="8" height="8"/></svg>';

const BOGUS_ID = '00000000-0000-0000-0000-000000000000';
/** spec 29: compose's front door IS the fe gateway, so this is the X-Route-Denied prefix. */
const FE_GATEWAY = 'hugmesh-fe-gateway';
/** spec 24 / spec 29 environment gates — read once, reported by name when they skip. */
const LIVE_GATEWAY = process.env.LIVE_GATEWAY === '1';
const BE_GATEWAY = process.env.SNAP_BE_GATEWAY
  ?? 'https://hugmesh-be-gateway.hugmesh-backend.svc.cluster.local:8443';
/** spec 29: DEFAULT TRUE on purpose — an unset variable RUNS the ON-posture block. */
const MFA_ENFORCEMENT = process.env.APP_MFA_ENABLED !== 'false';
const MFA_FLOOR = process.env.MFA_FLOOR === '1';

/** Unique CS-API transaction id (spec 28's `txn()`). */
function txn(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

// ── per-scenario API contexts ────────────────────────────────────────────────
// Tracked at module scope and disposed in After, so a scenario that fails
// mid-way never leaks a context into the next one. (Scenarios run serially
// within a worker, so a module-level list is per-scenario in practice; the
// Before reset makes that explicit rather than assumed.)

let openContexts: APIRequestContext[] = [];

Before(async () => { openContexts = []; });

After(async () => {
  for (const c of openContexts) await c.dispose().catch(() => { /* already gone */ });
  openContexts = [];
});

/**
 * Native sign-in over an APIRequestContext + registration STAGE 2.
 *
 * Reproduces specs 28 and 29's private `loginAs` verbatim. Stage 2 is NOT
 * optional: the seed deliberately leaves registration_complete=false (other
 * specs need still-gated personas), and while it is false the gateway grants
 * only the bare ROLE_USER floor (BffSessionAuthFilter.buildAuthorities) — so
 * every role assertion downstream would be vacuous. POST /bff/register/complete
 * is admin-bff's public AuthController endpoint, the exact call the login-ui's
 * "Complete registration" button makes; it is not a back door.
 */
async function apiSignIn(api: APIRequestContext, username: string): Promise<void> {
  const r = await api.post('/bff/login', {
    data: { username, password: personaPassword(username) },
  });
  expect(
    r.status(),
    `native login ${username} -> ${r.status()} — the persona must be seeded `
    + '(tests/e2e-extra-personas.sh / seed-e2e.sh) with its deterministic e2e password',
  ).toBe(200);
  const s = await api.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(s.status(), `${username}: GET /bff/session after login`).toBe(200);
  if (!(await s.json()).registrationComplete) {
    const done = await api.post('/bff/register/complete', { data: { displayName: username } });
    expect(done.status(), `${username}: POST /bff/register/complete`).toBe(200);
  }
}

/** Defensive CSRF header (spec 28's `csrf`) — the stack does not set XSRF-TOKEN
 *  today, but mirroring the idiom keeps the mutating calls correct if it ever does. */
async function csrfHeaders(api: APIRequestContext): Promise<Record<string, string>> {
  const t = (await api.storageState()).cookies.find((c) => c.name === 'XSRF-TOKEN')?.value;
  return t ? { 'X-CSRF-TOKEN': t } : {};
}

/** spec 28's `createRoom` over an API context (creator is auto-joined). */
async function createRoomApi(api: APIRequestContext, hs: string, name: string): Promise<string> {
  const r = await api.post(`${hs}/_matrix/client/v3/createRoom`, { data: { name } });
  expect(r.status(), 'createRoom').toBe(200);
  return (await r.json()).room_id as string;
}

/** spec 29's black-box gateway verdict. Only the GATEWAY sets X-Route-Denied
 *  (admin-bff's own entitlement wall 403s WITHOUT it), and only the privileged
 *  floor's cold-start hold answers 503 + Retry-After. */
type Verdict = 'DENIED' | 'HOLDING' | 'PASSED' | 'UNAUTHENTICATED';

function verdictOf(r: APIResponse): Verdict {
  if (r.status() === 403 && r.headers()['x-route-denied']) return 'DENIED';
  if (r.status() === 503 && r.headers()['retry-after']) return 'HOLDING';
  if (r.status() === 401) return 'UNAUTHENTICATED';
  return 'PASSED';
}

function whyOf(r: APIResponse): string {
  return `${r.status()} x-route-denied=${r.headers()['x-route-denied'] ?? '<none>'}`;
}

/** spec 29's `primedGet`: ride out the floor's cold-start 503 + Retry-After hold,
 *  but return any other 503 as-is so the caller's assertion fails on it rather
 *  than looping forever. */
async function primedGet(api: APIRequestContext, path: string): Promise<APIResponse> {
  let last = await api.get(path);
  const deadline = Date.now() + 60_000;
  while (verdictOf(last) === 'HOLDING' && Date.now() < deadline) {
    await new Promise((f) => setTimeout(f, 2_000));
    last = await api.get(path);
  }
  return last;
}

/** The API context a previous Given established for this scenario. */
function api(world: { get<T>(k: string): T }): APIRequestContext {
  return world.get<APIRequestContext>('api');
}

// ═══════════════════════════════════════════════════════════════════════════
// PENDING + POSTURE GATES — every one of these SKIPS LOUDLY, by name.
// A scenario that cannot run must say so in the report; it must never quietly
// pass, and it must never quietly vanish from the listing.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * The scenario describes a capability, an evidence artefact or a backend that
 * DOES NOT EXIST YET. It stays in the feature file (so the contract is
 * executable the day it lands) and is reported as SKIPPED with the reason
 * printed — the Gherkin equivalent of the handwritten specs' `test.fixme`.
 */
Given('this scenario is PENDING because {string}', async ({ $testInfo }, reason: string) => {
  $testInfo.annotations.push({ type: 'pending', description: reason });
  $testInfo.skip(true, `PENDING — ${reason}`);
});

Given('the gateway MFA leg is OFF on this stack', async ({ $testInfo }) => {
  $testInfo.skip(
    MFA_ENFORCEMENT,
    'APP_MFA_ENABLED is not false on this stack — the gateway MFA leg is ON, so the '
    + 'ON-posture scenarios are the ones that apply. These two blocks are exact '
    + 'COMPLEMENTS (spec 29): whichever posture a stack holds, one of them runs.',
  );
});

Given('the gateway MFA leg is ON on this stack', async ({ $testInfo }) => {
  $testInfo.skip(
    !MFA_ENFORCEMENT,
    'APP_MFA_ENABLED=false on this stack — the gateway never consults the mfa_required '
    + 'rows, so a 403 here would come from admin-bff\'s entitlement wall instead: the '
    + 'right status from the wrong layer. The OFF-posture scenarios cover this stack.',
  );
});

Given('the privileged MFA floor is enabled on this stack', async ({ $testInfo }) => {
  $testInfo.skip(
    !MFA_FLOOR,
    'the privileged-floor scenarios need a floor-enabled stack: `make stack-up MFA_FLOOR=1` '
    + '(APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true on the compose gateways), then run with '
    + 'MFA_FLOOR=1 in the environment.',
  );
});

Given('the live-gateway swarm preconditions hold', async ({ $testInfo }) => {
  const pop = swarm();
  $testInfo.skip(
    !LIVE_GATEWAY,
    'LIVE_GATEWAY!=1 — the sweep drives the REAL be-gateway/bff with pre-minted JWTs; '
    + 'the lean/heavy Jobs set it.',
  );
  $testInfo.skip(
    !premintReady(Math.min(10, pop.length)),
    `pre-minted JWT cache not populated (run seed-accounts.sh --roles --swarm ${pop.length}); `
    + 'without it 126 actors would serialize at Casdoor login and the concurrency '
    + 'invariant would measure the seeder, not the mesh.',
  );
});

/**
 * spec 08's dependency probe, asked of admin-bff itself rather than guessed at.
 * The COMPOSE lane has neither Kafka nor ClickHouse (compose.local.yaml says so
 * outright), so admin-bff degrades to its clearly-marked in-memory fallback,
 * which self-reports `source` and records a NARROWER action vocabulary (no
 * 'login' row at all). The warehouse-backed aggregates cannot be proven there,
 * so this skips on the dependency rather than being loosened to whatever the
 * fallback happens to emit.
 */
Given('the analytics warehouse is serving the admin usage aggregates', async ({ page, $testInfo }) => {
  const probe = await page.request.get('/bff/admin/usage', { headers: { accept: 'application/json' } });
  const source = probe.ok() ? String((await probe.json().catch(() => ({} as any)))?.source ?? '') : '';
  $testInfo.annotations.push({ type: 'analytics-source', description: source || '<unavailable>' });
  $testInfo.skip(
    source !== 'clickhouse',
    `ClickHouse is not deployed on this stack — GET /bff/admin/usage reports source=`
    + `"${source || '<unavailable>'}" (admin-bff's documented in-memory fallback). `
    + `tests/stack/compose.local.yaml omits the Kafka/ClickHouse analytics wiring entirely; `
    + `ClickHouse ships only in specs/cluster/manifests/analytics/clickhouse/. Run this on a `
    + `lane with ClickHouse wired.`,
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// ADMIN CONSOLE — specs 08 + 09
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Usage and Namespace access live inside admin-ui's OWN per-module menu
 * (admin.component.ts `menu()`), reached through the host's Admin profile-menu
 * entry. There is no host-level top-nav shortcut — the `nav-usage` /
 * `nav-namespaces` testids specs 08/09 once assumed exist nowhere in the UI.
 */
When('I open the admin module {string}', async ({ page }, module: string) => {
  await substep('open the host Admin profile-menu entry', async () => {
    await page.getByTestId('profile-trigger').click();
    await page.getByTestId('menu-admin').click();
    await expect(page.getByTestId('admin-view')).toBeVisible();
  });
  await substep(`select the admin-ui module "${module}"`, async () => {
    await page.locator(`[data-menu="${module}"]`).click();
  });
});

/** The host's Admin profile-menu entry is itself role-gated (session.isAdmin()). */
Then('the Admin entry is absent from my profile menu', async ({ page }) => {
  await page.getByTestId('profile-trigger').click();
  await expect(page.getByTestId('menu-admin')).toHaveCount(0);
});

Then('the usage aggregate {string} is not zero', async ({ page }, testId: string) => {
  await expect(page.getByTestId(testId)).not.toHaveText('0');
});

/** `kind` is 'module' or 'action': testid `usage-by-<kind>`, attribute `data-<kind>`. */
Then('the usage {string} breakdown lists {string}', async ({ page }, kind: string, value: string) => {
  await expect(
    page.getByTestId(`usage-by-${kind}`).locator(`[data-${kind}="${value}"]`),
  ).toBeVisible();
});

When('I grant the namespace {string} to {string}', async ({ page }, ns: string, user: string) => {
  await page.getByTestId('ns-user').fill(user);
  await page.getByTestId('ns-select').selectOption(ns);
  await page.getByTestId('ns-grant').click();
});

Then('the namespace grants list shows {string} holding {string}',
  async ({ page }, user: string, ns: string) => {
    await expect(page.getByTestId('ns-grants').locator(`[data-user="${user}"]`)).toContainText(ns);
  });

// ═══════════════════════════════════════════════════════════════════════════
// API SESSIONS — the identity half of specs 28/29
// ═══════════════════════════════════════════════════════════════════════════

Given('I hold an API session as the persona for this scenario',
  async ({ baseURL, dimensions, world }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const ctx = await apiContext(baseURL);
    openContexts.push(ctx);
    await apiSignIn(ctx, handle);
    world.set('api', ctx);
    world.set('username', handle);
  });

Given('I hold an API session as the seeded superadmin', async ({ baseURL, world }) => {
  const ctx = await apiContext(baseURL);
  openContexts.push(ctx);
  await apiSignIn(ctx, SUPERADMIN_USERNAME);
  world.set('api', ctx);
  world.set('username', SUPERADMIN_USERNAME);
});

Given('I hold an anonymous API client', async ({ baseURL, world }) => {
  const ctx = await apiContext(baseURL);
  openContexts.push(ctx);
  world.set('api', ctx);
  world.set('username', '<anonymous>');
});

// ═══════════════════════════════════════════════════════════════════════════
// STICKER / CHARACTER / VN — spec 28 GROUP A
// ═══════════════════════════════════════════════════════════════════════════

const STICKER_KINDS: Record<string, { name: string; mimeType: string; buffer: Buffer }> = {
  'valid-png': { name: 'neutral.png', mimeType: 'image/png', buffer: PNG_1x1 },
  svg: { name: 'x.svg', mimeType: 'image/svg+xml', buffer: SVG_BYTES },
  'oversize-png': { name: 'big.png', mimeType: 'image/png', buffer: PNG_OVERSIZE },
};

When('I save a sticker of kind {string} at expression {string}',
  async ({ world }, kind: string, expression: string) => {
    const file = STICKER_KINDS[kind];
    if (!file) {
      throw new Error(
        `unknown sticker kind '${kind}'. Legal kinds: ${Object.keys(STICKER_KINDS).join(', ')} `
        + `— these mirror spec 28's three payloads exactly (a valid 1x1 PNG, SVG markup that `
        + `must trip the magic-byte sniff, and a >1MB PNG that must trip the 1MB cap).`,
      );
    }
    const ctx = api(world);
    const r = await ctx.post('/bff/user/character/stickers', {
      headers: await csrfHeaders(ctx),
      multipart: { file, expression },
      failOnStatusCode: false,
    });
    world.set('stickerSave', r);
  });

Then('the sticker save was accepted as PENDING with a stub mxc url', async ({ world }) => {
  const r = world.get<APIResponse>('stickerSave');
  expect(r.status(), 'save PNG sticker').toBe(200);
  const body = await r.json();
  expect(body.status, 'a freshly-saved sticker is PENDING (binary global lifecycle)').toBe('PENDING');
  expect(String(body.mxcUrl).startsWith('mxc://'), 'stub mxc assigned').toBe(true);
  world.set('stickerId', body.id as string);
});

Then('the sticker save was rejected with HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('stickerSave');
  expect(r.status(), 'rejected sticker save').toBe(status);
});

Then('my sticker library lists that sticker as PENDING', async ({ world }) => {
  const id = world.get<string>('stickerId');
  const list = await api(world).get('/bff/user/character/stickers');
  expect(list.status()).toBe(200);
  const rows = await list.json();
  expect(
    Array.isArray(rows) && rows.some((row: any) => row.id === id && row.status === 'PENDING'),
    'the saved sticker is listed for its owner (owner + domain scoped)',
  ).toBe(true);
});

/**
 * spec 28's live correction to its own facts draft: EVERY authenticated role
 * reaches this surface. Not the Spring RoleHierarchy bean (which only defines
 * SUPERADMIN>{ADMIN,MOD,USER}) — CasdoorAuthorities unconditionally grants
 * ROLE_USER to every authenticated principal, so hasRole('USER') is really an
 * "any authenticated user" floor. The ONLY DENY on this surface is anonymous.
 */
Then('the sticker library answers HTTP {int} for this session', async ({ world }, status: number) => {
  const who = world.get<string>('username');
  const r = await api(world).get('/bff/user/character/stickers');
  expect(r.status(), `${who} on GET /bff/user/character/stickers`).toBe(status);
});

Then('an anonymous sticker save is denied with HTTP {int}', async ({ world }, status: number) => {
  const r = await api(world).post('/bff/user/character/stickers', {
    multipart: { file: STICKER_KINDS['valid-png'], expression: 'neutral' },
    failOnStatusCode: false,
  });
  expect(r.status(), 'anonymous save denied').toBe(status);
});

When('I save a character part whose SVG carries a script tag', async ({ world }) => {
  const ctx = api(world);
  const r = await ctx.post('/bff/user/character/parts', {
    headers: await csrfHeaders(ctx),
    data: { name: 'e2e-part', headArchetype: 'round', svg: DIRTY_SVG },
    failOnStatusCode: false,
  });
  world.set('partSave', r);
});

Then('the character part was stored PENDING with the script stripped', async ({ world }) => {
  const r = world.get<APIResponse>('partSave');
  expect(r.status(), 'save character part').toBe(200);
  const body = await r.json();
  expect(body.status, 'a freshly-saved part is PENDING').toBe('PENDING');
  expect(String(body.svg).includes('<script'), 'stored svg is sanitized (no <script>)').toBe(false);
  world.set('partId', body.id as string);
});

Then('the served part SVG is sanitized and typed as SVG', async ({ world }) => {
  const id = world.get<string>('partId');
  const r = await api(world).get(`/bff/user/character/parts/${id}/svg`);
  expect(r.status(), 'serve part svg').toBe(200);
  expect((r.headers()['content-type'] || '').includes('image/svg+xml')).toBe(true);
  const text = await r.text();
  expect(text.includes('<svg'), 'served body is svg').toBe(true);
  expect(text.includes('<script'), 'served svg is sanitized').toBe(false);
});

// ── Matrix / Mastodon sends (spec 28 A2 + A6) ────────────────────────────────

/** The homeserver reverse-proxy prefix for this scenario's @service:, read off
 *  the SERVICE vocabulary rather than re-spelled ('/bff/user/matrix'). */
function servicePrefix(id: string): string {
  const def = service(id);
  if (!def.bffPrefix) {
    throw new Error(
      `service '${id}' (${def.name}) has no pinned BFF prefix, so a send step cannot `
      + `drive it. ${def.note}`,
    );
  }
  return def.bffPrefix;
}

Given('I have created a Matrix room named {string}', async ({ world, dimensions }, name: string) => {
  const hs = servicePrefix(requireDimension(dimensions, 'service'));
  world.set('roomId', await createRoomApi(api(world), hs, name));
});

When('I send an m.sticker event carrying the VN expression {string}',
  async ({ world, dimensions }, expression: string) => {
    const hs = servicePrefix(requireDimension(dimensions, 'service'));
    const roomId = world.get<string>('roomId');
    const content = {
      body: `${expression} sticker`,
      url: 'mxc://stub.invalid/e2e-bdd',
      info: { w: 256, h: 256, mimetype: 'image/png' },
      'net.hugmesh.vn': { expression },
    };
    // RAW room_id in the path — the portable spelling. Synapse rejected the
    // percent-encoded form (403); tuwunel accepts both. Raw works everywhere.
    const r = await api(world).put(
      `${hs}/_matrix/client/v3/rooms/${roomId}/send/m.sticker/${txn()}`,
      { data: content, failOnStatusCode: false },
    );
    world.set('send', r);
    world.set('sentExpression', expression);
  });

/**
 * The TEXT baseline the missing feature ban would have to preserve. Two
 * services, one step: on tuwunel a raw m.room.message PUT, on akkoma a
 * POST /api/v1/statuses — exactly what spec 28 A6 drives for each.
 */
When('I send plain text on the service for this scenario', async ({ world, dimensions }) => {
  const id = requireDimension(dimensions, 'service');
  const prefix = servicePrefix(id);
  const ctx = api(world);
  const marker = `bdd-a6-text-${txn()}`;
  world.set('marker', marker);
  if (id === 'tuwunel') {
    const roomId = await createRoomApi(ctx, prefix, 'A6 text baseline');
    world.set('roomId', roomId);
    const r = await ctx.put(
      `${prefix}/_matrix/client/v3/rooms/${roomId}/send/m.room.message/${txn()}`,
      { data: { msgtype: 'm.text', body: marker }, failOnStatusCode: false },
    );
    world.set('send', r);
  } else if (id === 'akkoma') {
    const r = await ctx.post(`${prefix}/api/v1/statuses`, {
      headers: await csrfHeaders(ctx),
      data: { status: marker, visibility: 'public' },
      failOnStatusCode: false,
    });
    world.set('send', r);
  } else {
    throw new Error(
      `the plain-text baseline step only knows the two services spec 28 A6 drives `
      + `(tuwunel via m.room.message, akkoma via POST /api/v1/statuses); it was asked `
      + `for '${id}'. Add the real send shape here before adding an Examples row — a `
      + `step that guessed would assert nothing.`,
    );
  }
});

Then('the send was accepted by the service', async ({ world, dimensions }) => {
  const id = requireDimension(dimensions, 'service');
  const r = world.get<APIResponse>('send');
  expect(r.status(), `send on ${id}`).toBe(200);
  const body = await r.json();
  // Matrix answers {event_id}; Mastodon answers a status object with {id}.
  const handle = body.event_id ?? body.id;
  expect(handle, `${id} returned an identifier for the accepted send`).toBeTruthy();
  world.set('eventId', String(handle));
});

Then('reading the event back shows an m.sticker with an mxc url and the same VN expression',
  async ({ world, dimensions }) => {
    const hs = servicePrefix(requireDimension(dimensions, 'service'));
    const roomId = world.get<string>('roomId');
    const eventId = world.get<string>('eventId');
    const r = await api(world).get(`${hs}/_matrix/client/v3/rooms/${roomId}/event/${eventId}`);
    expect(r.status()).toBe(200);
    const stored = await r.json();
    expect(stored.type).toBe('m.sticker');
    expect(String(stored.content.url).startsWith('mxc://')).toBe(true);
    expect(stored.content['net.hugmesh.vn'].expression).toBe(world.get<string>('sentExpression'));
    expect(stored.content.body).toBe(`${world.get<string>('sentExpression')} sticker`);
  });

/**
 * The "banned from the platform" state the product actually models: a user
 * holding only ROLE_USER (no ROLE_MATRIX/ROLE_MASTODON). It is 403 on BOTH
 * homeserver surfaces — i.e. it cannot send TEXT either. That is the crux of
 * spec 28: the only real block is coarse and takes text with it.
 */
Then('I am denied the identity surface of the service for this scenario', async ({ world, dimensions }) => {
  const id = requireDimension(dimensions, 'service');
  const prefix = servicePrefix(id);
  const probe = id === 'tuwunel'
    ? `${prefix}/_matrix/client/v3/account/whoami`
    : `${prefix}/api/v1/accounts/verify_credentials`;
  const r = await api(world).get(probe, { failOnStatusCode: false });
  expect(r.status(), `no-platform-access persona on ${id} (${probe})`).toBe(403);
});

// ── moderation surfaces (spec 28 A4/A5/A7) ───────────────────────────────────

/**
 * The mod findings queue is the ONLY fine-grained moderation channel that
 * exists. On the stock compose stack its EFFECT round-trip is not observable
 * (test-seed 503, FindingActivationReconciler dark, and GET /bff/mod/findings
 * itself 500s because the federation findings backend is down) — so only the
 * RBAC gate is asserted as real. 'authorized' means "not 401/403"; a 500 proves
 * authorization succeeded and is not an auth denial.
 */
Then('the mod findings queue is {string} for this session', async ({ world, $testInfo }, outcome: string) => {
  const who = world.get<string>('username');
  const r = await api(world).get('/bff/mod/findings?status=held', { failOnStatusCode: false });
  $testInfo.annotations.push({ type: 'observed', description: `${who} GET /bff/mod/findings -> ${r.status()}` });
  if (outcome === 'denied') {
    expect(r.status(), `${who} must be DENIED the mod findings queue`).toBe(403);
  } else if (outcome === 'authorized') {
    expect([401, 403], `${who} must be AUTHORIZED for the findings queue (got ${r.status()})`)
      .not.toContain(r.status());
  } else {
    throw new Error(`unknown findings outcome '${outcome}' — use "authorized" or "denied".`);
  }
});

Then('resolving a finding is {string} for this session', async ({ world, $testInfo }, outcome: string) => {
  const who = world.get<string>('username');
  const r = await api(world).post(`/bff/mod/findings/${BOGUS_ID}/resolve?actioned=false`, {
    failOnStatusCode: false,
  });
  $testInfo.annotations.push({ type: 'observed', description: `${who} resolve(bogus) -> ${r.status()}` });
  if (outcome === 'denied') {
    expect(r.status(), `${who} must be DENIED finding resolution`).toBe(403);
  } else if (outcome === 'authorized') {
    expect([401, 403], `${who} must be AUTHORIZED to resolve (got ${r.status()})`)
      .not.toContain(r.status());
  } else {
    throw new Error(`unknown resolve outcome '${outcome}' — use "authorized" or "denied".`);
  }
});

/**
 * The ban surface accepts ONLY platform matrix|mastodon|profile. A feature-
 * scoped target is rejected at VALIDATION, before any effect — so this probe is
 * non-destructive and never enacts a real ban on a shared persona.
 */
When('I attempt a moderation ban on platform {string}', async ({ world }, platform: string) => {
  const ctx = api(world);
  const r = await ctx.post('/bff/mod/ban', {
    headers: await csrfHeaders(ctx),
    data: { platform, target: 'e2e-user', reason: 'bdd contract lock' },
    failOnStatusCode: false,
  });
  world.set('ban', r);
});

Then('the ban is rejected as an unknown platform target', async ({ world }) => {
  const r = world.get<APIResponse>('ban');
  expect(r.status(), 'no feature-scoped ban target exists').toBe(400);
  const err = await r.json().catch(() => ({} as any));
  expect(
    JSON.stringify(err),
    'the validation error must still enumerate the only three legal platforms',
  ).toMatch(/matrix.*mastodon.*profile/i);
});

Then('the ban is rejected with HTTP {int}', async ({ world }, status: number) => {
  expect(world.get<APIResponse>('ban').status(), 'ban validation').toBe(status);
});

/**
 * The negative-space contract LOCK. If a role-scoped feature ban is ever built
 * (spec 28 B3), a ROLE_STICKER/ROLE_CHARACTER/ROLE_VN (or a role->feature
 * deny-map) appears here and this assertion flips — which is the signal to move
 * the pending contract scenarios to live ones.
 */
Then('my session carries no sticker, character or VN feature role', async ({ world }) => {
  const who = world.get<string>('username');
  const r = await api(world).get('/bff/session');
  expect(r.status()).toBe(200);
  const roles: string[] = (await r.json()).roles ?? [];
  expect(roles.length, `${who} session hydrated with roles`).toBeGreaterThan(0);
  for (const role of roles) {
    expect(role, `${who} carries no sticker/character/VN feature-role (${role})`)
      .not.toMatch(/sticker|character|\bvn\b/i);
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// MFA — spec 29
// ═══════════════════════════════════════════════════════════════════════════

/**
 * RFC 6238 Appendix B. Fully offline, no stack: runs first so a failing
 * challenge downstream can never be blamed on our own code generation. The
 * published vectors are 8-digit; the platform is DIGITS=6 (auth-core
 * TotpService), so the expectation is the low 6 digits of each.
 */
Then('the RFC 6238 SHA-1 vector at T={int} yields the six digits {string}',
  async ({}, t: number, expected: string) => {
    const SECRET = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    const step = Math.floor(t / 30);
    expect(totpCodeForStep(SECRET, step), `RFC 6238 T=${t} (step ${step})`).toBe(expected);
  });

Then('a non-base32 TOTP secret throws instead of hashing garbage', async ({}) => {
  // A garbled `mfa-secret` read off the page must fail HERE, not produce a
  // plausible-looking 6 digits the server then rejects for the wrong reason.
  expect(() => totpCode('not base32!')).toThrow(/base32/i);
});

/**
 * The anti-fake-green preconditions. `GET /bff/session` roles are LOWERCASED and
 * ROLE_-stripped ('admin', 'fleet_admin'), and registrationComplete gates
 * whether the gateway maps them to authorities at all — both are asserted so a
 * 403 downstream can never be a role deny masquerading as an MFA deny.
 */
async function sessionRoles(ctx: APIRequestContext, who: string): Promise<string[]> {
  const r = await ctx.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(r.status(), `${who}: GET /bff/session after login`).toBe(200);
  const body = await r.json();
  expect(Array.isArray(body.roles), `${who}: /bff/session returned a roles array`).toBe(true);
  expect(
    !!body.registrationComplete,
    `${who}: registrationComplete is false, so the gateway grants only the ROLE_USER floor `
    + 'and every role assertion below would be vacuous',
  ).toBe(true);
  return body.roles as string[];
}

Then('my session carries a fleet role and not admin', async ({ world }) => {
  const who = world.get<string>('username');
  const roles = await sessionRoles(api(world), who);
  expect(
    roles.some((r) => /fleet/i.test(r)),
    `${who} session roles ${JSON.stringify(roles)} carry no fleet role — re-seed `
    + '(tests/e2e-extra-personas.sh grants e2e-fleet ROLE_FLEET_ADMIN). Without the '
    + 'granting row a 403 here would prove nothing about MFA.',
  ).toBe(true);
  expect(
    roles.some((r) => /^(role_)?admin$/i.test(r)),
    `${who} must NOT hold ROLE_ADMIN (got ${JSON.stringify(roles)}) — an admin `
    + 'short-circuits before decide() and would reach the row for the wrong reason',
  ).toBe(false);
});

Then('my session carries the admin role', async ({ world }) => {
  const who = world.get<string>('username');
  const roles = await sessionRoles(api(world), who);
  expect(
    roles.some((r) => /^(role_)?admin$/i.test(r)),
    `${who} session roles ${JSON.stringify(roles)} lack admin — nothing here is about MFA`,
  ).toBe(true);
});

Then('my session is non-privileged', async ({ world }) => {
  const who = world.get<string>('username');
  const roles = await sessionRoles(api(world), who);
  expect(
    roles.some((r) => /^(role_)?(admin|superadmin|game.master)$/i.test(r)),
    `${who} must be non-privileged (got ${JSON.stringify(roles)})`,
  ).toBe(false);
});

When('I request the governed path {string}', async ({ world }, path: string) => {
  const r = await primedGet(api(world), path);
  world.set('governed', r);
  world.set('governedPath', path);
});

Then('the gateway verdict is {string}', async ({ world }, expected: string) => {
  const r = world.get<APIResponse>('governed');
  const path = world.get<string>('governedPath');
  expect(verdictOf(r), `${world.get<string>('username')} GET ${path} -> ${whyOf(r)}`).toBe(expected);
});

Then('the gateway verdict is not {string}', async ({ world }, unexpected: string) => {
  const r = world.get<APIResponse>('governed');
  const path = world.get<string>('governedPath');
  expect(verdictOf(r), `${world.get<string>('username')} GET ${path} -> ${whyOf(r)}`)
    .not.toBe(unexpected);
});

Then('the gateway route-access reject names the path {string}', async ({ world }, path: string) => {
  const r = world.get<APIResponse>('governed');
  expect(
    r.headers()['x-route-denied'],
    "the deny must be the gateway route-access reject, not an upstream entitlement wall",
  ).toBe(`${FE_GATEWAY}:${path}`);
});

Then('the gateway did not reject the request', async ({ world }) => {
  const r = world.get<APIResponse>('governed');
  const path = world.get<string>('governedPath');
  expect(
    r.headers()['x-route-denied'],
    `GET ${path} -> ${whyOf(r)}. An X-Route-Denied here means the gateway DID consult `
    + 'mfa_required — the declared posture and the live posture disagree (check the '
    + 'gateway pod env, not the chart values).',
  ).toBeUndefined();
});

Then('the gateway reject carries no body', async ({ world }) => {
  const r = world.get<APIResponse>('governed');
  expect((await r.text()).length, 'the gateway reject carries no body').toBe(0);
});

Then('no layer redirected me to the MFA challenge', async ({ world }) => {
  const r = world.get<APIResponse>('governed');
  expect(
    r.headers()['location'] ?? '',
    'no layer redirected an un-enrolled admin to the MFA challenge',
  ).not.toMatch(/\/login\/mfa/);
});

// ═══════════════════════════════════════════════════════════════════════════
// FINAL SWEEP — spec 24. The population is 126 procedural identities; it is
// driven as a POPULATION (concurrently, through swarm-driver) and deliberately
// NOT unrolled into 126 Examples rows: an Examples table is the matrix
// vocabulary, not a load generator, and unrolling would destroy the very
// concurrency invariant (A) exists to prove.
// ═══════════════════════════════════════════════════════════════════════════

Then('the swarm population acts concurrently with at least {int} actors in flight',
  async ({ playwright }, floorHint: number) => {
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    try {
      const pop = swarm();
      const tasks = pop.map((m) => async () => {
        const token = loadToken(m);
        return req.get(`${BE_GATEWAY}/api/v1/timelines/home`, {
          headers: token ? { authorization: `Bearer ${token}` } : {},
          failOnStatusCode: false,
        });
      });
      const { maxInFlight } = await runConcurrently(tasks);
      const floor = Math.min(floorHint, pop.length);
      expect(
        maxInFlight,
        `expected >= ${floor} actors in flight at once, saw ${maxInFlight} (serialized?)`,
      ).toBeGreaterThanOrEqual(floor);
    } finally {
      await req.dispose();
    }
  });

Then('every swarm mod is allowed its assigned targets and denied the admin plane at the gateway and bff layers',
  async ({ playwright }) => {
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    try {
      const pop = swarm();
      const users = pop.filter((m) => m.swarmTier === 'user');
      const mods = pop.filter((m) => m.swarmTier === 'mod');
      const admins = pop.filter((m) => m.swarmTier === 'admin');
      const counts = { users: users.length, mods: mods.length, admins: admins.length };
      const modTasks = mods.map((mod) => async () => {
        const modToken = loadToken(mod);
        const victim = swarmTargetsForMod(mod.tierIndex, counts)[0];
        // The real ModController audit read has NO subject filter — the only param
        // is the boolean `mine`, so `mine=true` stands in for the fabricated
        // `?subject=` query that endpoint never supported.
        const layers: LayerExpectation[] = [
          { layer: 'gateway', url: `${BE_GATEWAY}/api/v1/pleroma/admin/statuses?account=${victim}`, token: modToken, expect: 'ALLOW' },
          { layer: 'bff', url: `${BE_GATEWAY}/bff/mod/audit?mine=true`, token: modToken, expect: 'ALLOW' },
          { layer: 'gateway', url: `${BE_GATEWAY}/api/admin/route-access`, token: modToken, expect: 'DENY' },
          { layer: 'bff', url: `${BE_GATEWAY}/bff/admin/allowlist`, token: modToken, expect: 'DENY' },
        ];
        await assertControlAtLayers(req, `mod ${mod.username} -> ${victim}`, layers);
      });
      const { maxInFlight } = await runConcurrently(modTasks);
      expect(maxInFlight, 'mods should act concurrently')
        .toBeGreaterThanOrEqual(Math.min(mods.length, 2));
    } finally {
      await req.dispose();
    }
  });

Then("an admin observes a swarm mod's ban through the mod audit read within {int} seconds",
  async ({ playwright, $testInfo }, seconds: number) => {
    const pop = swarm();
    const users = pop.filter((m) => m.swarmTier === 'user');
    const mods = pop.filter((m) => m.swarmTier === 'mod');
    const admins = pop.filter((m) => m.swarmTier === 'admin');
    $testInfo.skip(
      mods.length === 0 || admins.length === 0,
      'needs at least one mod + one admin in this swarm sizing (SWARM_MODS/SWARM_ADMINS)',
    );
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    try {
      const mod = mods[0];
      const admin = admins[0];
      const modToken = loadToken(mod);
      const adminToken = loadToken(admin);
      const victim = swarmTargetsForMod(mod.tierIndex, {
        users: users.length, mods: mods.length, admins: admins.length,
      })[0];
      const auditMarker = `bdd-sweep-modban-${mod.username}-${Date.now()}`;

      // WRITE as the MOD. The mod-bff BanRequest DTO's user field is `target`.
      const ban = await req.post(`${BE_GATEWAY}/bff/mod/ban`, {
        headers: modToken ? { authorization: `Bearer ${modToken}` } : {},
        data: { platform: 'mastodon', target: victim, reason: auditMarker, ttlSeconds: 300 },
        failOnStatusCode: false,
      });
      expect(ban.ok(), `mod ban of ${victim} must be accepted (got ${ban.status()})`).toBeTruthy();

      // READ-AFTER-WRITE as the ADMIN — a DIFFERENT principal. `mine` stays at its
      // default false: a domain-scoped ADMIN sees every row in its own domain.
      await expectObservedWithin(req, {
        url: `${BE_GATEWAY}/bff/mod/audit`,
        token: adminToken,
        needle: auditMarker,
        timeoutMs: seconds * 1_000,
        label: `admin ${admin.username} observes ${mod.username}'s ban of ${victim}`,
      });

      // LIFT (cleanup) — the sweep must leave no residual ban.
      const lift = await req.delete(`${BE_GATEWAY}/bff/mod/ban`, {
        headers: modToken ? { authorization: `Bearer ${modToken}` } : {},
        data: { platform: 'mastodon', target: victim, reason: auditMarker },
        failOnStatusCode: false,
      });
      expect(lift.ok(), `ban lift for ${victim} must be accepted (got ${lift.status()})`).toBeTruthy();
    } finally {
      await req.dispose();
    }
  });

Then('concurrent author-observer pairs each achieve read-after-write within {int} seconds',
  async ({ playwright, $testInfo }, seconds: number) => {
    const users = swarm().filter((m) => m.swarmTier === 'user');
    const pairCount = Math.min(
      Number(process.env.SWARM_RAW_PAIRS ?? 8),
      Math.floor(users.length / 2),
    );
    $testInfo.skip(pairCount < 2, 'needs at least 4 swarm users (2 author->observer pairs)');
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    try {
      // Disjoint pairs: author = users[2i], observer = users[2i+1].
      const pairs = Array.from({ length: pairCount }, (_, i) => ({
        author: users[2 * i],
        observer: users[2 * i + 1],
        needle: `bdd-sweep-raw-${users[2 * i].username}-${Date.now()}`,
      }));
      const tasks = pairs.map((p) => async () => {
        const authorToken = loadToken(p.author);
        const observerToken = loadToken(p.observer);
        const post = await req.post(`${BE_GATEWAY}/api/v1/statuses`, {
          headers: authorToken ? { authorization: `Bearer ${authorToken}` } : {},
          data: { status: `raw pair post ${p.needle}`, visibility: 'public' },
          failOnStatusCode: false,
        });
        expect(post.ok(), `${p.author.username}'s post must be accepted (got ${post.status()})`)
          .toBeTruthy();
        await expectObservedWithin(req, {
          url: `${BE_GATEWAY}/api/v1/timelines/public?local=true&limit=40`,
          token: observerToken,
          needle: p.needle,
          timeoutMs: seconds * 1_000,
          label: `${p.observer.username} observes ${p.author.username}'s post`,
        });
      });
      const { maxInFlight } = await runConcurrently(tasks);
      const floor = Math.min(pairs.length, 4);
      expect(
        maxInFlight,
        `expected >= ${floor} pairs in flight at once, saw ${maxInFlight} (serialized?)`,
      ).toBeGreaterThanOrEqual(floor);
    } finally {
      await req.dispose();
    }
  });


// ═══════════════════════════════════════════════════════════════════════════
// BDD coverage round 2026-09-23 (services lane) — admin-bff-api#93. The step
// below reuses the helpers this file already carries (api / csrfHeaders).
// ═══════════════════════════════════════════════════════════════════════════

// ── the mod-bff notify_channels directive (admin-bff-api#93, the wire half) ──
//
// mod-bff's BanRequest carries `notifyChannels` and AdminSuspensionClient puts it
// in the body it POSTs to admin-bff. A TTL'd ban on the standing banned persona is
// the least-destructive real write that exercises that path: the effect expires
// on its own and touches a persona no other scenario expects to be unbanned.

When('I ban {string} on platform {string} for {int} seconds with the notify channels {string}',
  async ({ world }, target: string, platform: string, ttlSeconds: number, channelsCsv: string) => {
    const ctx = api(world);
    const notifyChannels = channelsCsv.split(',').map((s) => s.trim()).filter(Boolean);
    const r = await ctx.post('/bff/mod/ban', {
      headers: await csrfHeaders(ctx),
      data: { platform, target, reason: 'bdd: notify_channels directive (admin-bff-api#93)', ttlSeconds, notifyChannels },
      failOnStatusCode: false,
    });
    world.set('ban', r);
  });

Then('the ban was accepted as pending-reconcile with HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('ban');
  expect(r.status(), `POST /bff/mod/ban -> ${r.status()} ${(await r.text()).slice(0, 300)}`).toBe(status);
});

// ── the upstream's OWN refusal on a governed path (admin-bff-api#62) ─────────
//
// 'the gateway verdict is {string}' reads DENIED only when the 403 carries
// X-Route-Denied, so a refusal made by the BFF behind the door (403, no header)
// reads PASSED there. A scenario that means "the gateway let it through and the
// BFF said no" pairs 'the gateway did not reject the request' with this step.
Then('the governed path answered HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('governed');
  expect(r.status(), `GET ${world.get<string>('governedPath')} -> ${whyOf(r)}`).toBe(status);
});
