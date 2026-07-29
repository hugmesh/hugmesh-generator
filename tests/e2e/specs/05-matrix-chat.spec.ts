import { test, expect } from '@playwright/test';
import { onboard, matrixUserId, createRoom, joinRoom, shot } from './helpers';

test('two users chat with each other through the Matrix UI', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();

  await onboard(alice, 'alice@gmail.com');
  await onboard(bob, 'bob@gmail.com');

  // Establish a shared room BEFORE opening the chat view (the component reads
  // joined rooms on init, then polls messages). Created through each page's
  // user-bff hsproxy (auth = the httpOnly bff_session cookie); the browser holds
  // no Matrix token, so the peer id comes from the hsproxy whoami.
  const bobUserId = await matrixUserId(bob);
  const roomId = await createRoom(alice, bobUserId, 'general');
  await joinRoom(bob, roomId);

  const q = `?room=${encodeURIComponent(roomId)}`;
  await alice.goto(`/social/matrix${q}`);
  await bob.goto(`/social/matrix${q}`);
  await expect(alice.getByTestId('matrix-view')).toBeVisible();
  await expect(bob.getByTestId('matrix-view')).toBeVisible();

  // Alice sends; Bob must see it (polled).
  await alice.getByTestId('matrix-input').fill('hi Bob — alice here');
  await alice.getByTestId('matrix-send').click();
  await expect(bob.getByTestId('matrix-log')).toContainText('hi Bob — alice here');

  // Bob replies; Alice must see it.
  await bob.getByTestId('matrix-input').fill('hey Alice — bob here');
  await bob.getByTestId('matrix-send').click();
  await expect(alice.getByTestId('matrix-log')).toContainText('hey Alice — bob here');

  await shot(alice, '05-matrix-alice');
  await shot(bob, '05-matrix-bob');
  await a.close();
  await b.close();
});
