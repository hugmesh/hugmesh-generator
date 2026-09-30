// tor-onion-domains.steps.ts — the docker stack's PER-DOMAIN Tor front doors, driven
// THROUGH TOR (hugmesh-generator#582, decision 68 = A). Bound by
// features/platform/tor-onion-domains.feature.
//
// HOW IT REACHES THE ONIONS. `make stack-up TOR=1 BRAND_B=1` starts hugmesh-tor with
// TOR_ONION_DOMAINS=brandb=brandb (tests/stack/compose.tor-domains.yaml): one more
// HiddenService, brand B's, in front of the same gateway, registered in the gateway's
// host map as `brandb` while the mesh's own onion is registered as `default`.
// `make stack-e2e-tor-domains` runs tests/e2e/run.sh --via onion-domains, which
// exports SNAP_ONION_BASE_URL (the mesh's onion), SNAP_ONION_DOMAIN_URLS
// ("brandb=https://<onion> ...") and SNAP_PROXY, and runs ONLY @via:onion-domains
// scenarios. Every context here is built by specs/helpers.ts onionContext() from one
// of those doors — never the `page`/`context`/`request` fixtures, whose context has
// no proxy — so nothing can pass by talking to localhost: the last Then audits every
// request the brand-B browser made, listener and HAR alike (the same audit as
// tor-onion.steps.ts, the mesh's own onion).
//
// OUTSIDE THAT LANE the Given SKIPS naming the command, exactly like the mesh's own
// onion scenario: an ordinary `make stack-e2e-bdd` collects this scenario too and
// must go neither red nor quietly green.
//
// THE BRAND WALL, HOW IT IS SHOWN. The default persona signs in on the MESH'S onion
// (a second proxied context), and its session cookies are carried over to brand B's
// onion host — the browser scopes cookies per host, so the same bytes are re-added
// for the other host, which is what tests/stack/tor-domains-live-check.sh row P does
// with `curl -b`. GET /bff/me there must answer 403 with X-Route-Denied: the
// gateway resolved brand B's onion Host to tenant `brandb` and refused a default-brand
// principal (GatewayRouteAccessFilter domainMatches, hugmesh-gateway#39). A 200 is the
// pre-#582 behaviour — every onion served as the default brand — and fails here.
//
// BRAND B'S PERSONA. tests/stack/seed-e2e.sh leg 1b seeds `e2e-tenant2-user` into
// brand B's Casdoor with ROLE_USER and nothing else (the SYSTEMS_ROLE_USERS line
// there), only when CASDOOR_BRAND_B_URL is set — which `make stack-seed BRAND_B=1`
// does. It is deliberately NOT in specs/rbac-roles.ts or tests/e2e-extra-personas.sh
// (the kind lane has no brand B, and tests/scripts/test-e2e-persona-catalogue.sh
// holds both lanes to one roster), so it cannot be a @role: value: the handle and
// its seeded roles are spelled here, with the seeder as their source. Its password
// is the run's e2e password (specs/helpers.ts personaPassword: the handle's own
// override, else the shared one the seeder used).
//
// The session read is /bff/session for the persona checks (the cookie-only read, as
// tor-onion.steps.ts explains) and /bff/me for the refusal: /bff/me needs the
// gateway-minted JWT and is where the gateway's route access refuses a foreign
// brand's principal, which is the claim under test. Both are fetch() INSIDE the
// page, riding the proxied browser, so they appear in the request log the last Then
// audits.

import * as fs from 'node:fs';
import { expect } from '@playwright/test';
import type { BrowserContext, Page, TestInfo } from '@playwright/test';
import { Given, When, Then, requireDimension } from './world';
import { persona } from './dimensions';
import {
  onboard, personaPassword, onionFrontDoor, domainOnionDoors, onionContext,
} from '../specs/helpers';
import type { OnionFrontDoor } from '../specs/helpers';
import { expectOnionSessionIsPersona, sessionRoleName } from './onion-session';

/** The Tor domain the compose lane mints (Makefile: BRAND_B=1 TOR=1 adds brandb=brandb). */
const DOMAIN_SLUG = 'brandb';
/** Brand B's persona and its seeded roles — tests/stack/seed-e2e.sh leg 1b. */
const DOMAIN_PERSONA = 'e2e-tenant2-user';
const DOMAIN_PERSONA_ROLES = ['user'];

/** One proxied browser on one onion, and everything the steps hand each other. */
interface OnionBrowser {
  door: OnionFrontDoor;
  ctx: BrowserContext;
  page: Page;
  harPath: string;
  /** Every URL this proxied browser requested, in order. */
  requests: string[];
}

// The same budget as the mesh's own onion scenario (tor-onion.steps.ts): a cold
// onion's descriptor takes seconds to minutes to reach the HSDir ring, and there are
// TWO cold onions here, each contacted once.
const SCENARIO_BUDGET_MS = 12 * 60_000;
const FIRST_CONTACT_TRIES = 12;
const FIRST_CONTACT_PAUSE_MS = 10_000;

async function evidence(page: Page, testInfo: TestInfo, name: string): Promise<void> {
  const file = testInfo.outputPath(`${name}.png`);
  await page.screenshot({ path: file, fullPage: true }).catch(() => { /* page gone */ });
  await testInfo.attach(name, { path: file, contentType: 'image/png' }).catch(() => { /* no file */ });
}

async function openThroughTor(browser: Parameters<typeof onionContext>[0], door: OnionFrontDoor,
  testInfo: TestInfo, label: string): Promise<OnionBrowser> {
  const harPath = testInfo.outputPath(`${label}.har`);
  const ctx = await onionContext(browser, door, harPath);
  const requests: string[] = [];
  ctx.on('request', (r) => { requests.push(r.url()); });
  const page = await ctx.newPage();
  // First contact retries ONLY the navigation: a circuit Tor could not yet build is
  // the one failure worth waiting out. Any HTTP answer ends the loop and is judged by
  // the assertions that follow, never retried into a pass.
  let lastError = '';
  for (let i = 1; i <= FIRST_CONTACT_TRIES; i += 1) {
    try {
      await page.goto('/login', { timeout: 90_000 });
      lastError = '';
      break;
    } catch (e) {
      lastError = String(e).split('\n')[0];
      if (i < FIRST_CONTACT_TRIES) await page.waitForTimeout(FIRST_CONTACT_PAUSE_MS);
    }
  }
  if (lastError) {
    throw new Error(
      `${door.baseUrl}/login never answered through ${door.proxy} after `
      + `${FIRST_CONTACT_TRIES} tries: ${lastError}. Is hugmesh-tor healthy (make stack-ps), `
      + 'was the stack brought up with a Tor domain (TOR=1 BRAND_B=1), and is '
      + 'hugmesh-tor-client bootstrapped?',
    );
  }
  return { door, ctx, page, harPath, requests };
}

function offHost(host: string): (u: string) => boolean {
  return (u: string): boolean => {
    if (u.startsWith('data:') || u.startsWith('blob:')) return false;
    try { return new URL(u).hostname !== host; } catch { return true; }
  };
}

Given('the stack publishes a Tor onion of its own for the brand-B domain', async ({ world, $testInfo }) => {
  const mesh = onionFrontDoor();
  if (!mesh) {
    $testInfo.skip(
      true,
      '@via:onion-domains runs only in the per-domain Tor lane: SNAP_ONION_BASE_URL, '
      + 'SNAP_ONION_DOMAIN_URLS and SNAP_PROXY are unset. Run: make stack-up TOR=1 BRAND_B=1 '
      + '&& make stack-seed && make stack-e2e-tor-domains',
    );
    return;
  }
  const doors = domainOnionDoors();
  const door = doors[DOMAIN_SLUG];
  if (!door) {
    // In this lane a missing door is a FAILURE, never a skip: run.sh selected the
    // scenario because per-domain readouts exist, so a stack without brand B's is a
    // stack that was not brought up the way the lane says.
    throw new Error(
      `no onion for the Tor domain '${DOMAIN_SLUG}' in SNAP_ONION_DOMAIN_URLS `
      + `(${Object.keys(doors).join(', ') || 'none'}). Bring the stack up with brand B: `
      + 'make stack-up TOR=1 BRAND_B=1 && make stack-seed',
    );
  }
  expect(door.host, 'brand B\'s onion must be its own, not the mesh\'s').not.toBe(mesh.host);
  $testInfo.setTimeout(SCENARIO_BUDGET_MS);
  world.set('domainOnionMeshDoor', mesh);
  world.set('domainOnionDoor', door);
});

When('I open the brand-B onion login page through Tor', async ({ browser, world, $testInfo }) => {
  const door = world.get<OnionFrontDoor>('domainOnionDoor');
  world.set<OnionBrowser>('domainOnion', await openThroughTor(browser, door, $testInfo, 'brandb-onion'));
});

Then('the brand-B onion login page renders', async ({ world, $testInfo }) => {
  const { page } = world.get<OnionBrowser>('domainOnion');
  // The SPA booted over brand B's onion: rendered by login-ui's JavaScript, so a door
  // that serves the document but not its scripts and fetches fails here, not later.
  await expect(page.getByTestId('login-username')).toBeVisible({ timeout: 90_000 });
  await expect(page.getByTestId('login-password')).toBeVisible();
  await expect(page.getByTestId('login-submit')).toBeVisible();
  await evidence(page, $testInfo, 'brandb-onion-login-page');
});

When('the persona for this scenario signs in through the mesh onion', async ({ browser, world, dimensions, $testInfo }) => {
  const mesh = world.get<OnionFrontDoor>('domainOnionMeshDoor');
  const run = await openThroughTor(browser, mesh, $testInfo, 'mesh-onion');
  const handle = persona(requireDimension(dimensions, 'role'));
  await onboard(run.page, handle, personaPassword(handle));
  // The session really is this persona's on the MESH'S onion before it is carried
  // anywhere: a refusal later must be the brand wall, not a login that never happened.
  const me = await run.page.evaluate(async () => {
    const r = await fetch('/bff/session', {
      headers: { accept: 'application/json' }, credentials: 'same-origin',
    });
    return { status: r.status, body: await r.text() };
  });
  expectOnionSessionIsPersona(me.status, me.body, handle, 'the mesh\'s own onion');
  await evidence(run.page, $testInfo, 'mesh-onion-signed-in');
  world.set<OnionBrowser>('meshOnion', run);
  world.set('meshOnionHandle', handle);
});

Then('that session is refused on the brand-B onion with X-Route-Denied', async ({ world, $testInfo }) => {
  const mesh = world.get<OnionBrowser>('meshOnion');
  const dom = world.get<OnionBrowser>('domainOnion');
  const handle = world.get<string>('meshOnionHandle');
  // The same session bytes, presented to brand B's onion: cookies are per host, so
  // the mesh onion's are re-added for brand B's host (row P of the live check).
  const cookies = await mesh.ctx.cookies(mesh.door.baseUrl);
  expect(cookies.length, `${handle} signed in on the mesh's onion but holds no cookie there`)
    .toBeGreaterThan(0);
  await dom.ctx.addCookies(cookies.map((c) => ({
    name: c.name, value: c.value, domain: dom.door.host, path: c.path,
    httpOnly: c.httpOnly, secure: c.secure, sameSite: c.sameSite,
  })));
  const answer = await dom.page.evaluate(async () => {
    const r = await fetch('/bff/me', {
      headers: { accept: 'application/json' }, credentials: 'same-origin',
    });
    return { status: r.status, denied: r.headers.get('x-route-denied'), body: (await r.text()).slice(0, 300) };
  });
  const why = `${handle}'s default-brand session on brand B's onion -> ${answer.status}`
    + `${answer.denied ? ` X-Route-Denied: ${answer.denied}` : ' (no X-Route-Denied)'}: ${answer.body}. `
    + 'Want 403 X-Route-Denied — the gateway must map brand B\'s onion Host to brand B and refuse '
    + 'a default-brand principal there. 200 means the onion is served as the default brand '
    + '(the pre-#582 behaviour: no host map, hugmesh-gateway#38).';
  expect(answer.status, why).toBe(403);
  expect(answer.denied, why).not.toBeNull();
  // Cleared before brand B's own persona signs in: its session must be its own.
  await dom.ctx.clearCookies();
  await mesh.ctx.close().catch(() => { /* already closed */ });
  await $testInfo.attach('mesh-onion.har', { path: mesh.harPath, contentType: 'application/json' })
    .catch(() => { /* HAR not written */ });
  // The mesh onion browser never left the mesh onion either.
  expect(mesh.requests.filter(offHost(mesh.door.host)),
    `requests the mesh-onion browser made off ${mesh.door.host}`).toEqual([]);
});

When('the brand-B persona signs in through the brand-B onion', async ({ world, $testInfo }) => {
  const dom = world.get<OnionBrowser>('domainOnion');
  await dom.page.goto('/login', { timeout: 90_000 });
  // The SAME onboard() every browser scenario uses; its relative goto('/login')
  // resolves against this context's baseURL, i.e. brand B's onion.
  await onboard(dom.page, DOMAIN_PERSONA, personaPassword(DOMAIN_PERSONA));
  await evidence(dom.page, $testInfo, 'brandb-onion-signed-in');
});

Then('the brand-B onion session belongs to the brand-B persona', async ({ world }) => {
  const dom = world.get<OnionBrowser>('domainOnion');
  expect(new URL(dom.page.url()).hostname, 'the signed-in page is still on brand B\'s onion')
    .toBe(dom.door.host);
  const me = await dom.page.evaluate(async () => {
    const r = await fetch('/bff/session', {
      headers: { accept: 'application/json' }, credentials: 'same-origin',
    });
    return { status: r.status, body: await r.text() };
  });
  const where = 'brand B\'s onion';
  expect(me.status, `GET /bff/session over ${where} -> ${me.status}: ${me.body.slice(0, 300)}`).toBe(200);
  let body: { id?: unknown; roles?: unknown; registrationComplete?: unknown };
  try {
    body = JSON.parse(me.body) as typeof body;
  } catch {
    throw new Error(`GET /bff/session over ${where} returned 200 but not JSON: ${me.body.slice(0, 300)}`);
  }
  expect(typeof body.id === 'string' && body.id !== '',
    `the session over ${where} names no account id: ${me.body.slice(0, 300)}`).toBe(true);
  expect(body.registrationComplete,
    `${DOMAIN_PERSONA} signed in over ${where} but registration is not complete`).toBe(true);
  expect(Array.isArray(body.roles),
    `the session over ${where} carries no roles array: ${me.body.slice(0, 300)}`).toBe(true);
  // Identity by roles, as onion-session.ts explains (the handle is the Casdoor sub):
  // EQUAL to what seed-e2e.sh leg 1b seeded, so a more privileged persona fails.
  const got = [...new Set((body.roles as unknown[]).map((r) => sessionRoleName(String(r))))].sort();
  expect(got, `the session over ${where} must be ${DOMAIN_PERSONA}'s: roles equal to its seeded `
    + 'roles (tests/stack/seed-e2e.sh leg 1b: ROLE_USER only)').toEqual([...DOMAIN_PERSONA_ROLES].sort());
});

Then('every request the brand-B onion browser made stayed on that onion', async ({ world, $testInfo }) => {
  const dom = world.get<OnionBrowser>('domainOnion');
  // Closing the context flushes the HAR; the listener is the authority, the HAR the
  // artefact a person opens.
  await dom.ctx.close();
  await $testInfo.attach('brandb-onion.har', { path: dom.harPath, contentType: 'application/json' })
    .catch(() => { /* HAR not written */ });
  expect(dom.requests.length, 'the proxied brand-B browser made no requests at all').toBeGreaterThan(0);
  const off = offHost(dom.door.host);
  const why = `requests that did NOT carry brand B's onion host ${dom.door.host} — a UI that links `
    + 'an absolute localhost/hugmesh.net URL, or the mesh\'s own onion, works on the local door and '
    + 'breaks for every Tor user of this domain';
  expect(dom.requests.filter(off), why).toEqual([]);
  const har = JSON.parse(fs.readFileSync(dom.harPath, 'utf8')) as
    { log?: { entries?: Array<{ request?: { url?: string } }> } };
  const harUrls = (har.log?.entries ?? []).map((e) => e.request?.url ?? '');
  expect(harUrls.length, `the HAR at ${dom.harPath} recorded nothing`).toBeGreaterThan(0);
  expect(harUrls.filter(off), `${why} (HAR)`).toEqual([]);
});
