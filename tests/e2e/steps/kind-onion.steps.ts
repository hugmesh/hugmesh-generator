// kind-onion.steps.ts — the kind lane's .onion front door (hugmesh-generator#577,
// operator decision 67 = B). Feature: features/platform/tor-onion-kind.feature.
//
// WHAT RUNS WHERE. `make kind-tor` (scripts/kind-tor.sh) runs a HOST tor as the
// operator — no sudo — publishing `HiddenServicePort 443 127.0.0.1:8443` (the kind
// node's TLS door) and `80 127.0.0.1:8080`, and admits the minted onion on the
// fe-gateway Ingress. `make kind-e2e-tor` then runs this feature with:
//
//   SNAP_KIND_ONION         the onion, read from `kind-tor.sh onion` (which refuses
//                           a leftover hostname when that tor is not alive)
//   SNAP_ENV_KIND_BASE_URL  https://<onion>  — the @env:kind baseURL seam
//                           (steps/dimensions.ts), so every relative page.goto and
//                           every page.request in the shared steps drives the onion
//   SNAP_PROXY              socks5://127.0.0.1:<port> of that same tor
//
// THE PROXY IS NOT PLUMBED HERE, and that is deliberate. Routing the browser (and
// every request context) through SNAP_PROXY belongs to playwright.config.ts, which
// the compose-lane Tor work (hugmesh-generator#576) owns. A step cannot re-proxy a
// page the fixture already created, and a private browser launched here would leave
// the AfterStep evidence screenshots of a blank fixture page — evidence of nothing.
// So the first step CHECKS that the project's `use` carries SNAP_PROXY and fails,
// naming the missing plumbing, when it does not. It never passes without Tor: a
// .onion name resolves nowhere else, and the last step fails on any request that
// left for a host other than the onion.
//
// `@via:onion` is not a dimension axis (steps/dimensions.ts AXES) and not an
// @issue: tag, so the dimension parser and gherkin-harness check 5 both ignore it;
// it exists so `--tags '@env:kind and @via:onion'` selects exactly this door.

import { expect } from '@playwright/test';
import { Given, When, Then } from './world';

const ONION_RE = /^[a-z2-7]{56}\.onion$/;

interface OnionRun {
  onion: string;
  requests: string[];
}

function proxyServerOf(use: Record<string, unknown>): string | undefined {
  const direct = (use.proxy as { server?: string } | undefined)?.server;
  if (direct) return direct;
  const launch = use.launchOptions as { proxy?: { server?: string } } | undefined;
  return launch?.proxy?.server;
}

Given('the front door under test is the kind lane\'s live onion',
  async ({ page, baseURL, world, $testInfo }) => {
    const onion = process.env.SNAP_KIND_ONION || '';
    if (!onion) {
      $testInfo.skip(true,
        'SNAP_KIND_ONION is unset: no kind onion door is up. Run `make kind-tor` '
        + '(after `make kind-up`), then `make kind-e2e-tor`, which sets it from the '
        + 'LIVE tor rather than from a leftover hostname file.');
      return;
    }
    expect(onion, 'SNAP_KIND_ONION must be a v3 onion hostname').toMatch(ONION_RE);

    const base = new URL(baseURL || 'about:blank');
    expect(base.hostname,
      'the @env:kind baseURL must BE the onion (SNAP_ENV_KIND_BASE_URL=https://<onion>) — '
      + 'otherwise this scenario would sign in through the plain kind door and prove nothing')
      .toBe(onion);
    expect(base.protocol, 'the kind onion door is the TLS one (HiddenServicePort 443)').toBe('https:');

    const want = process.env.SNAP_PROXY || '';
    expect(want, 'SNAP_PROXY must name the kind tor SOCKS port (`scripts/kind-tor.sh socks`)')
      .toMatch(/^socks5h?:\/\/127\.0\.0\.1:\d+$/);
    const got = proxyServerOf($testInfo.project.use as Record<string, unknown>);
    expect(got,
      'playwright.config.ts does not route the browser through SNAP_PROXY. That plumbing '
      + 'is the compose-lane Tor work (hugmesh-generator#576); until it lands this '
      + 'scenario cannot reach an onion and must not pretend to.').toBe(want);

    const run: OnionRun = { onion, requests: [] };
    page.on('request', (r) => { run.requests.push(r.url()); });
    world.set('kind-onion', run);
  });

When('I open the onion\'s plain http door', async ({ page, world }) => {
  const run = world.get<OnionRun>('kind-onion');
  await page.goto(`http://${run.onion}/`);
});

Then('I am redirected to the onion\'s https door', async ({ page, world }) => {
  const run = world.get<OnionRun>('kind-onion');
  const now = new URL(page.url());
  expect(now.hostname, 'the redirect must stay on the onion').toBe(run.onion);
  expect(now.protocol,
    'kind\'s fe-gateway Ingress force-ssl-redirects :80, so http://<onion>/ must land on https')
    .toBe('https:');
});

Then('the session endpoint answers for the signed-in persona through the onion',
  async ({ page, world }) => {
    const run = world.get<OnionRun>('kind-onion');
    expect(new URL(page.url()).hostname, 'the signed-in page is still on the onion').toBe(run.onion);
    // In-page and same-origin: the httpOnly bff_session cookie minted over the onion
    // rides along, and the request leaves through the same proxied browser.
    const r = await page.evaluate(async () => {
      const res = await fetch('/bff/session', {
        credentials: 'include', headers: { accept: 'application/json' },
      });
      return { status: res.status, body: await res.text() };
    });
    expect(r.status, `GET /bff/session over the onion: ${r.body.slice(0, 200)}`).toBe(200);
    const session = JSON.parse(r.body) as { roles?: unknown };
    expect(Array.isArray(session.roles) && session.roles.length > 0,
      `the onion session carries the persona's roles: ${r.body.slice(0, 200)}`).toBe(true);
  });

Then('every request this scenario made went to the onion host', async ({ world }) => {
  const run = world.get<OnionRun>('kind-onion');
  const network = run.requests.filter((u) => /^(https?|wss?):/i.test(u));
  expect(network.length, 'the scenario made no network request at all').toBeGreaterThan(0);
  const offenders = network.filter((u) => new URL(u).hostname !== run.onion);
  expect(offenders,
    `requests that left the onion (an absolute URL to hugmesh.net or localhost leaks `
    + `the user off Tor): ${offenders.slice(0, 10).join(' , ')}`).toEqual([]);
});
