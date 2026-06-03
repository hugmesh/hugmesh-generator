import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

test('users post to Mastodon and see each other through the UI', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();
  await onboard(alice, 'alice@gmail.com');
  await onboard(bob, 'bob@gmail.com');

  await alice.goto('/social/mastodon');
  await alice.getByTestId('mastodon-input').fill('hello fediverse from Alice');
  await alice.getByTestId('mastodon-post').click();
  await expect(alice.getByTestId('mastodon-timeline')).toContainText('hello fediverse from Alice');

  await bob.goto('/social/mastodon');
  await bob.getByTestId('mastodon-input').fill('Bob says hi to the timeline');
  await bob.getByTestId('mastodon-post').click();
  // Both posts are visible on the shared timeline.
  await expect(bob.getByTestId('mastodon-timeline')).toContainText('hello fediverse from Alice');
  await expect(bob.getByTestId('mastodon-timeline')).toContainText('Bob says hi to the timeline');

  await shot(alice, '06-mastodon-alice');
  await shot(bob, '06-mastodon-bob');
  await a.close();
  await b.close();
});
