// kind-onion.steps.ts — the kind lane's .onion front door, driven THROUGH TOR
// (hugmesh-generator#577, operator decision 67 = B).
// Bound by features/platform/tor-onion-kind.feature.
//
// HOW IT REACHES THE ONION. `make kind-tor` (scripts/kind-tor.sh) runs a HOST tor
// as the operator — no sudo — publishing `HiddenServicePort 443 127.0.0.1:8443`
// (the kind node's TLS door) and `80 127.0.0.1:8080`, with a SOCKS5 port on
// 127.0.0.1 (default 9052), and admits the minted onion on the fe-gateway Ingress.
// `make kind-e2e-tor` runs tests/e2e/run.sh --bdd --env kind --via onion, which
// exports SNAP_ONION_BASE_URL=https://<onion> and SNAP_PROXY=socks5://127.0.0.1:<port>
// read from that LIVE tor and runs ONLY @via:onion @env:kind scenarios.
//
// THE SEAM IS THE COMPOSE LANE'S (hugmesh-generator#576, PR #598): these steps build
// their OWN browser context from those two values (specs/helpers.ts onionFrontDoor /
// onionContext) and never touch the `page`, `context` or `request` fixtures, whose
// baseURL the @env:kind axis points at the LOCAL kind door and which carry no
// proxy. tests/scripts/test-kind-tor.sh refuses, statically, any of those fixtures
// or an unproxied request route in this file. So nothing here can pass by quietly
// talking to 127.0.0.1:8443: the last Then asserts that every request the proxied
// browser made — page listener AND HAR, which also records page.request calls —
// carried the onion host.
//
// OUTSIDE THAT LANE the Given SKIPS, naming the command — an ordinary kind run
// collects this scenario and must not go red because the onion was off, nor green
// because it silently did nothing (run.sh --via onion fails any skip).
//
// WHAT IS KIND-SPECIFIC. (1) The plain :80 door: the kind fe-gateway Ingress
// force-ssl-redirects it (ingress-nginx, 308), so http://<onion>/ must land on
// https://<onion>/ — the compose lane has no such redirect to prove. (2) The
// certificate: ingress-nginx's default cert, never one for the onion, hence the
// context's ignoreHTTPSErrors (onionContext sets it for the compose lane's
// per-machine cert for the same reason).

import * as fs from 'node:fs';
import { expect } from '@playwright/test';
import type { BrowserContext, Page, TestInfo } from '@playwright/test';
import { Given, When, Then, requireDimension } from './world';
import { persona } from './dimensions';
import {
  onboard, personaPassword, onionFrontDoor, onionContext,
} from '../specs/helpers';
import type { OnionFrontDoor } from '../specs/helpers';
import { expectOnionSessionIsPersona } from './onion-session';

interface KindOnionRun {
  door: OnionFrontDoor;
  ctx: BrowserContext;
  page: Page;
  harPath: string;
  /** Every URL the proxied browser requested, in order. */
  requests: string[];
}

// A cold onion needs its descriptor on the HSDir ring before the first connection
// succeeds (tests/stack/tor-onion-e2e.sh measured 118 s on this host, 2026-09-23;
// `make kind-tor` already waits for one answer, but a second client's circuit is
// its own). Then the sign-in chain is onboard()'s 4-5 serial round trips, each a
// Tor circuit. One budget for the whole scenario, set in the Given — the same
// numbers as the compose lane's tor-onion.steps.ts.
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

Given('the kind lane publishes its Tor onion front door', async ({ world, $testInfo }) => {
  const door = onionFrontDoor();
  if (!door) {
    $testInfo.skip(
      true,
      '@via:onion @env:kind runs only in the kind Tor lane: SNAP_ONION_BASE_URL and '
      + 'SNAP_PROXY are unset. Run: make kind-up && make kind-images && make kind-tor '
      + '&& make kind-e2e-tor',
    );
    return;
  }
  $testInfo.setTimeout(SCENARIO_BUDGET_MS);
  world.set('kindOnionDoor', door);
});

When('I open the kind onion\'s plain http door through Tor',
  async ({ browser, world, $testInfo }) => {
    const door = world.get<OnionFrontDoor>('kindOnionDoor');
    const harPath = $testInfo.outputPath('kind-onion.har');
    const ctx = await onionContext(browser, door, harPath);
    const requests: string[] = [];
    ctx.on('request', (r) => { requests.push(r.url()); });
    const page = await ctx.newPage();
    world.set<KindOnionRun>('kindOnion', { door, ctx, page, harPath, requests });

    // First contact retries ONLY the navigation: a circuit Tor could not build yet
    // is the one failure worth waiting out. Anything that answers — any HTTP
    // status — ends the loop and is judged by the next step, never retried into a pass.
    let lastError = '';
    for (let i = 1; i <= FIRST_CONTACT_TRIES; i += 1) {
      try {
        await page.goto(`http://${door.host}/`, { timeout: 90_000 });
        lastError = '';
        break;
      } catch (e) {
        lastError = String(e).split('\n')[0];
        if (i < FIRST_CONTACT_TRIES) await page.waitForTimeout(FIRST_CONTACT_PAUSE_MS);
      }
    }
    if (lastError) {
      throw new Error(
        `http://${door.host}/ never answered through ${door.proxy} after `
        + `${FIRST_CONTACT_TRIES} tries: ${lastError}. Is the kind tor alive `
        + '(make kind-tor-status) and does the Ingress admit the onion?',
      );
    }
  });

Then('the kind onion redirects me to its https door', async ({ world }) => {
  const { page, door } = world.get<KindOnionRun>('kindOnion');
  const now = new URL(page.url());
  expect(now.hostname, 'the redirect must stay on the onion').toBe(door.host);
  expect(now.protocol,
    'kind\'s fe-gateway Ingress force-ssl-redirects :80, so http://<onion>/ must land on https')
    .toBe('https:');
});

When('I open the kind onion login page through Tor', async ({ world }) => {
  const { page } = world.get<KindOnionRun>('kindOnion');
  // Relative: resolves against the context's baseURL, i.e. https://<onion>.
  await page.goto('/login', { timeout: 90_000 });
});

Then('the kind onion login page renders', async ({ world, $testInfo }) => {
  const { page } = world.get<KindOnionRun>('kindOnion');
  await expect(page.getByTestId('login-username')).toBeVisible({ timeout: 90_000 });
  await expect(page.getByTestId('login-password')).toBeVisible();
  await expect(page.getByTestId('login-submit')).toBeVisible();
  await evidence(page, $testInfo, 'kind-onion-login-page');
});

When('the persona for this scenario signs in through the kind onion',
  async ({ world, dimensions, $testInfo }) => {
    const run = world.get<KindOnionRun>('kindOnion');
    const handle = persona(requireDimension(dimensions, 'role'));
    // The SAME onboard() every browser scenario uses; its relative goto('/login')
    // resolves against this context's baseURL, i.e. the onion.
    await onboard(run.page, handle, personaPassword(handle));
    world.set('kindOnionHandle', handle);
    await evidence(run.page, $testInfo, 'kind-onion-signed-in');
  });

Then('the kind onion session belongs to that persona', async ({ world }) => {
  const { page, door } = world.get<KindOnionRun>('kindOnion');
  const handle = world.get<string>('kindOnionHandle');
  expect(new URL(page.url()).hostname, 'the signed-in page is still on the onion').toBe(door.host);
  // In-page and same-origin: the httpOnly bff_ cookie minted over the onion rides
  // along, and the fetch leaves through the same proxied browser.
  const me = await page.evaluate(async () => {
    const r = await fetch('/bff/session', {
      headers: { accept: 'application/json' }, credentials: 'same-origin',
    });
    return { status: r.status, body: await r.text() };
  });
  // Identity by roles, not by `handle`: the handle is the Casdoor sub, never the
  // username (#624). The same judgement as the compose lane, in onion-session.ts.
  expectOnionSessionIsPersona(me.status, me.body, handle, 'the kind onion');
});

Then('every request the kind onion browser made stayed on the onion',
  async ({ world, $testInfo }) => {
    const run = world.get<KindOnionRun>('kindOnion');
    // Closing the context flushes the HAR; the listener is the authority, the HAR
    // is the artefact a person opens AND the only record of page.request calls.
    await run.ctx.close();
    await $testInfo.attach('kind-onion.har', { path: run.harPath, contentType: 'application/json' })
      .catch(() => { /* HAR not written */ });
    expect(run.requests.length, 'the proxied browser made no requests at all').toBeGreaterThan(0);
    const offOnion = (u: string): boolean => {
      if (u.startsWith('data:') || u.startsWith('blob:')) return false;
      try { return new URL(u).hostname !== run.door.host; } catch { return true; }
    };
    const why = `requests that did NOT carry the onion host ${run.door.host} — an absolute `
      + 'hugmesh.net or localhost URL works on the kind door and leaks every Tor user off it';
    expect(run.requests.filter(offOnion), why).toEqual([]);
    const har = JSON.parse(fs.readFileSync(run.harPath, 'utf8')) as
      { log?: { entries?: Array<{ request?: { url?: string } }> } };
    const harUrls = (har.log?.entries ?? []).map((e) => e.request?.url ?? '');
    expect(harUrls.length, `the HAR at ${run.harPath} recorded nothing`).toBeGreaterThan(0);
    expect(harUrls.filter(offOnion), `${why} (HAR)`).toEqual([]);
  });
