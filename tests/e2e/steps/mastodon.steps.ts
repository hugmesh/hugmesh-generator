// mastodon.steps.ts — the Mastodon (akkoma) step vocabulary. Backs
// features/mastodon/**, the executable form of tests/e2e/specs/06-mastodon-post.spec.ts
// and the ROLE_MASTODON half of the per-platform access wall.
//
// Everything routes through the SAME helpers spec 06 drives (onboard,
// mastodonAccountId, mastodonFollow) so the two lanes cannot disagree about what
// posting to the timeline means.

import { expect } from '@playwright/test';
import { When, Then, Given, requireDimension } from './world';
import { persona } from './dimensions';
import { mastodonAccountId, mastodonFollow } from '../specs/helpers';
import { peer, signInPeers } from './social-peers';

/** Mirrors helpers.ts MASTODON_HSPROXY (module-private there): the same-origin
 *  user-bff hsproxy prefix. */
const HS = '/bff/user/mastodon';

/** world key holding the body of the status THIS persona posted. EXPORTED so
 *  the interaction steps can find the status again without posting a second one. */
export const MY_STATUS = 'mastodon-my-status';
const PEER_STATUS = 'mastodon-peer-status';

/**
 * Status bodies are unique PER RUN. The timeline is shared and append-only across
 * the whole suite, so a fixed string could be satisfied by a PREVIOUS run's post
 * and the assertion would stop proving that THIS post landed.
 */
function stamped(text: string): string {
  return `${text} ${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

Given('one more seeded Mastodon persona signs in as my peer', async ({ browser, world, dimensions, $testInfo }) => {
  $testInfo.setTimeout(240_000); // a second full onboarding (provisioning-heavy)
  const self = persona(requireDimension(dimensions, 'role'));
  await signInPeers(browser, world, 'akkoma', self, 1);
});

/**
 * The UI's "Home" tab is the real /api/v1/timelines/home, whose contents are
 * decided by the FOLLOW GRAPH — so "my peer sees my post" is only a claim about a
 * FOLLOWER seeing it once the follow exists. Ordering matters: a status fans out
 * to its followers' home feeds at post time, so the follow must precede the post
 * (that is what makes the assertion need no backfill and no polling).
 */
Given('my peer follows me on Mastodon', async ({ page, world }) => {
  await mastodonFollow(peer(world, 0).page, await mastodonAccountId(page));
});

When('I open the Mastodon timeline', async ({ page }) => {
  await page.goto('/social/mastodon');
});

When('my peer opens the Mastodon timeline', async ({ world }) => {
  await peer(world, 0).page.goto('/social/mastodon');
});

When('I post the Mastodon status {string} with a unique run marker', async ({ page, world }, text: string) => {
  const body = stamped(text);
  world.set(MY_STATUS, body);
  await page.getByTestId('mastodon-input').fill(body);
  await page.getByTestId('mastodon-post').click();
});

When('my peer posts the Mastodon status {string} with a unique run marker', async ({ world }, text: string) => {
  const body = stamped(text);
  world.set(PEER_STATUS, body);
  const p = peer(world, 0).page;
  await p.getByTestId('mastodon-input').fill(body);
  await p.getByTestId('mastodon-post').click();
});

Then('my Mastodon timeline shows my status', async ({ page, world }) => {
  await expect(page.getByTestId('mastodon-timeline')).toContainText(world.get<string>(MY_STATUS));
});

Then('my peer\'s Mastodon timeline shows both statuses', async ({ world }) => {
  const tl = peer(world, 0).page.getByTestId('mastodon-timeline');
  await expect(tl).toContainText(world.get<string>(MY_STATUS));
  await expect(tl).toContainText(world.get<string>(PEER_STATUS));
});

// ── the per-platform ACCESS wall, live through the hsproxy ───────────────────

Then('the Mastodon hsproxy returns my account id', async ({ page, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const id = await mastodonAccountId(page);
  expect(id, `mastodon verify_credentials account id for ${handle}`).toBeTruthy();
});

Then('the Mastodon hsproxy refuses me the homeserver backend', async ({ page, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const r = await page.request.get(`${HS}/api/v1/accounts/verify_credentials`);
  expect(
    r.ok(),
    `persona '${handle}' holds no ROLE_MASTODON, so the homeserver backend must refuse it — `
    + `got HTTP ${r.status()}. A 2xx here means the per-platform access wall (commit 0100d3b) `
    + `has regressed into the old broad ROLE_USER homeserver floor.`,
  ).toBe(false);
  expect([401, 403], `refusal status for '${handle}' (got ${r.status()})`).toContain(r.status());
});
