// tor-onion.steps.ts — the docker stack's Tor front door, driven THROUGH TOR
// (hugmesh-generator#576). Bound by features/platform/tor-onion-front-door.feature.
//
// HOW IT REACHES THE ONION. `make stack-up TOR=1` starts hugmesh-tor (the onion:
// :443 -> the TLS front, :80 -> the fe-gateway) and hugmesh-tor-client (a SOCKS5
// proxy on 127.0.0.1:${TOR_SOCKS_HOST_PORT:-9050}). `make stack-e2e-tor` runs
// tests/e2e/run.sh --via onion, which exports SNAP_ONION_BASE_URL=https://<onion>
// and SNAP_PROXY=socks5://127.0.0.1:9050 and runs ONLY @via:onion scenarios.
// These steps build their OWN browser context from those two values
// (specs/helpers.ts onionContext) instead of using the `page` fixture, whose
// context has no proxy and whose baseURL the @env:docker axis points at the LOCAL
// door. So nothing here can pass by quietly talking to localhost: the last Then
// asserts every request the proxied browser made carried the onion host.
//
// OUTSIDE THAT LANE the Given SKIPS, naming the command — an ordinary
// `make stack-e2e-bdd` collects this scenario and must not go red because TOR was
// off, nor green because it silently did nothing.
//
// WHY /bff/session AND NOT /bff/me. Both return the same body (user-bff
// SsoAuthController.sessionView: id, provider, handle, registrationComplete,
// roles); /bff/me additionally needs the gateway-minted JWT, /bff/session only the
// bff_ cookie the login just set. The claim under test is "the persona signed in
// OVER THE ONION", and the cookie-only read is the one whose failure can only mean
// that. It is read with fetch() INSIDE the page, so it rides the same proxied
// browser and shows up in the request log the last Then audits.

import * as fs from 'node:fs';
import { expect } from '@playwright/test';
import type { BrowserContext, Page, TestInfo } from '@playwright/test';
import { Given, When, Then, requireDimension } from './world';
import { persona } from './dimensions';
import {
  onboard, personaPassword, onionFrontDoor, onionContext,
} from '../specs/helpers';
import type { OnionFrontDoor } from '../specs/helpers';

/** Everything the steps below hand each other, in one typed record. */
interface OnionRun {
  door: OnionFrontDoor;
  ctx: BrowserContext;
  page: Page;
  harPath: string;
  /** Every URL the proxied browser requested, in order. */
  requests: string[];
}

// Over Tor a cold onion needs its descriptor on the HSDir ring before the first
// connection succeeds: seconds to a couple of minutes after hugmesh-tor reports
// healthy (tor-onion-e2e.sh measured 118 s on this host, 2026-09-23). Then the
// sign-in chain is the same 4-5 serial round trips onboard() budgets 60 s for,
// each now a Tor circuit. One budget for the whole scenario, set in the Given.
const SCENARIO_BUDGET_MS = 10 * 60_000;
const FIRST_CONTACT_TRIES = 12;
const FIRST_CONTACT_PAUSE_MS = 10_000;

async function evidence(page: Page, testInfo: TestInfo, name: string): Promise<void> {
  // The AfterStep hook screenshots the `page` FIXTURE, which this scenario never
  // drives (it is unproxied by design). The pictures that matter are these.
  const file = testInfo.outputPath(`${name}.png`);
  await page.screenshot({ path: file, fullPage: true }).catch(() => { /* page gone */ });
  await testInfo.attach(name, { path: file, contentType: 'image/png' }).catch(() => { /* no file */ });
}

Given('the stack publishes its Tor onion front door', async ({ world, $testInfo }) => {
  const door = onionFrontDoor();
  if (!door) {
    $testInfo.skip(
      true,
      '@via:onion runs only in the Tor lane: SNAP_ONION_BASE_URL and SNAP_PROXY are unset. '
      + 'Run: make stack-up TOR=1 && make stack-seed && make stack-e2e-tor',
    );
    return;
  }
  $testInfo.setTimeout(SCENARIO_BUDGET_MS);
  world.set('onionDoor', door);
});

When('I open the onion login page through Tor', async ({ browser, world, $testInfo }) => {
  const door = world.get<OnionFrontDoor>('onionDoor');
  const harPath = $testInfo.outputPath('onion.har');
  const ctx = await onionContext(browser, door, harPath);
  const requests: string[] = [];
  ctx.on('request', (r) => { requests.push(r.url()); });
  const page = await ctx.newPage();
  world.set<OnionRun>('onion', { door, ctx, page, harPath, requests });

  // First contact retries ONLY the navigation itself: a connection that Tor could
  // not yet build (descriptor not propagated) is the one failure worth waiting
  // out. Anything that answers — any HTTP status — ends the loop and is judged
  // by the assertions below, never retried into a pass.
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
      + `${FIRST_CONTACT_TRIES} tries: ${lastError}. Is hugmesh-tor healthy `
      + '(make stack-ps) and hugmesh-tor-client bootstrapped?',
    );
  }
});

Then('the onion login page renders', async ({ world, $testInfo }) => {
  const { page } = world.get<OnionRun>('onion');
  // The SPA booted: these are rendered by login-ui's JavaScript, which is exactly
  // what an http entry (or an upgraded subresource with no :443 behind it) kills.
  await expect(page.getByTestId('login-username')).toBeVisible({ timeout: 90_000 });
  await expect(page.getByTestId('login-password')).toBeVisible();
  await expect(page.getByTestId('login-submit')).toBeVisible();
  await evidence(page, $testInfo, 'onion-login-page');
});

When('the persona for this scenario signs in through the onion', async ({ world, dimensions, $testInfo }) => {
  const run = world.get<OnionRun>('onion');
  const handle = persona(requireDimension(dimensions, 'role'));
  // The SAME onboard() every browser scenario uses; its relative goto('/login')
  // resolves against this context's baseURL, i.e. the onion.
  await onboard(run.page, handle, personaPassword(handle));
  world.set('onionHandle', handle);
  await evidence(run.page, $testInfo, 'onion-signed-in');
});

Then('the onion session belongs to that persona', async ({ world }) => {
  const { page, door } = world.get<OnionRun>('onion');
  const handle = world.get<string>('onionHandle');
  expect(new URL(page.url()).hostname, 'the signed-in page is still on the onion').toBe(door.host);
  const me = await page.evaluate(async () => {
    const r = await fetch('/bff/session', {
      headers: { accept: 'application/json' }, credentials: 'same-origin',
    });
    return { status: r.status, body: await r.text() };
  });
  expect(me.status, `GET /bff/session over the onion -> ${me.status}: ${me.body.slice(0, 300)}`).toBe(200);
  const body = JSON.parse(me.body) as { handle?: unknown; registrationComplete?: unknown };
  expect(body.handle, 'the session the onion minted is the persona that signed in').toBe(handle);
  expect(body.registrationComplete).toBe(true);
});

Then('every request the browser made went to the onion', async ({ world, $testInfo }) => {
  const run = world.get<OnionRun>('onion');
  // Closing the context is what flushes the HAR; the listener is the authority,
  // the HAR is the artefact a person opens.
  await run.ctx.close();
  await $testInfo.attach('onion.har', { path: run.harPath, contentType: 'application/json' })
    .catch(() => { /* HAR not written */ });
  expect(run.requests.length, 'the proxied browser made no requests at all').toBeGreaterThan(0);
  const offOnion = (u: string): boolean => {
    if (u.startsWith('data:') || u.startsWith('blob:')) return false;
    try { return new URL(u).hostname !== run.door.host; } catch { return true; }
  };
  const why = `requests that did NOT carry the onion host ${run.door.host} — a UI that links `
    + 'an absolute localhost/hugmesh.net URL works on the local door and breaks for every Tor user';
  expect(run.requests.filter(offOnion), why).toEqual([]);
  // The HAR is audited too: it also records the context's Node-side calls
  // (page.request — onboard()'s session hydrate), which the page listener cannot
  // see. Measured 2026-09-23 over a live onion: a page.request GET appeared in the
  // HAR and not in the listener; failed loopback requests appeared in both.
  const har = JSON.parse(fs.readFileSync(run.harPath, 'utf8')) as
    { log?: { entries?: Array<{ request?: { url?: string } }> } };
  const harUrls = (har.log?.entries ?? []).map((e) => e.request?.url ?? '');
  expect(harUrls.length, `the HAR at ${run.harPath} recorded nothing`).toBeGreaterThan(0);
  expect(harUrls.filter(offOnion), `${why} (HAR)`).toEqual([]);
});
