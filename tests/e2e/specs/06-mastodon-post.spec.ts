import { test, expect } from '@playwright/test';
import { onboard, mastodonAccountId, mastodonFollow, requirePlatformPersonas, shot } from './helpers';

// 06 — TWO USERS POST to Mastodon and SEE EACH OTHER on the shared timeline.
//
// PERSONAS. This drove alice@gmail.com / bob@gmail.com (ROLE_USER only). Mastodon
// is gated on the per-platform ROLE_MASTODON access role since the broad ROLE_USER
// homeserver floor was removed (commit 0100d3b) — spec 17 asserts a plain
// ROLE_USER is DENIED /api/v1/timelines/home, so those handles cannot post here by
// design (live: alice -> POST /bff/provision/mastodon = 403). It now runs on the
// two seeded ROLE_MASTODON personas (e2e-mastodon and e2e-mastodon-external-client;
// the external-client role adds native-client passthrough and does not restrict
// this UI path). Intent unchanged: two distinct users, two cookie-separated
// contexts, each post landing on the timeline both of them read.
const [ALICE, BOB] = requirePlatformPersonas('ROLE_MASTODON', 2);

test('users post to Mastodon and see each other through the UI', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();
  await onboard(alice, ALICE.username, ALICE.password);
  await onboard(bob, BOB.username, BOB.password);

  // Bodies are unique per RUN: the timeline is shared and append-only across the
  // whole suite, so a fixed string could be satisfied by a PREVIOUS run's post
  // and the assertion would stop proving that THIS post landed.
  const stamp = `${Date.now()}`;
  const ALICE_POST = `hello fediverse from Alice ${stamp}`;
  const BOB_POST = `Bob says hi to the timeline ${stamp}`;

  // Bob follows Alice BEFORE she posts. The UI's timeline is the real
  // /api/v1/timelines/home, whose contents are decided by the follow graph, so
  // "Bob sees Alice's post" is a claim about a FOLLOWER seeing it — following
  // first is what makes that claim true rather than a weaker one. Ordering
  // matters: a status fans out to its followers' home feeds at post time.
  await mastodonFollow(bob, await mastodonAccountId(alice));

  await alice.goto('/social/mastodon');
  await alice.getByTestId('mastodon-input').fill(ALICE_POST);
  await alice.getByTestId('mastodon-post').click();
  await expect(alice.getByTestId('mastodon-timeline')).toContainText(ALICE_POST);

  await bob.goto('/social/mastodon');
  await bob.getByTestId('mastodon-input').fill(BOB_POST);
  await bob.getByTestId('mastodon-post').click();
  // Both posts are visible on the shared timeline.
  await expect(bob.getByTestId('mastodon-timeline')).toContainText(ALICE_POST);
  await expect(bob.getByTestId('mastodon-timeline')).toContainText(BOB_POST);

  await shot(alice, '06-mastodon-alice');
  await shot(bob, '06-mastodon-bob');
  await a.close();
  await b.close();
});
