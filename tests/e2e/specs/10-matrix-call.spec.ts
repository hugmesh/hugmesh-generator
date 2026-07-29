import { test, expect } from '@playwright/test';
import { onboard, matrixUserId, createRoom, joinRoom, shot } from './helpers';

// Real WebRTC: two browser contexts (fake media) establish a peer connection,
// signalled over a shared Matrix room via the hugmesh-matrix-ui call module.
test('two users hold a Matrix video call (WebRTC, room-signalled)', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();

  await onboard(alice, 'alice@gmail.com');
  await onboard(bob, 'bob@gmail.com');
  // Shared room via each page's hsproxy (cookie-authed; no browser Matrix token).
  const bobUserId = await matrixUserId(bob);
  const roomId = await createRoom(alice, bobUserId, 'callroom');
  await joinRoom(bob, roomId);

  const q = `?room=${encodeURIComponent(roomId)}`;
  await alice.goto(`/social/matrix/call${q}`);
  await bob.goto(`/social/matrix/call${q}`);
  await expect(alice.getByTestId('call-view')).toBeVisible();
  await expect(bob.getByTestId('call-view')).toBeVisible();

  // Alice starts; Bob's UI rings; Bob joins.
  await alice.getByTestId('call-start').click();
  await expect(bob.getByTestId('call-state')).toHaveText('ringing', { timeout: 15000 });
  await bob.getByTestId('call-join').click();

  // Both peers reach a connected WebRTC state.
  await expect(alice.getByTestId('call-state')).toHaveText('connected', { timeout: 30000 });
  await expect(bob.getByTestId('call-state')).toHaveText('connected', { timeout: 30000 });

  // Remote video is actually receiving a stream on both sides.
  for (const p of [alice, bob]) {
    const live = await p.locator('[data-testid=remote-video]').evaluate(
      (v: HTMLVideoElement) => !!v.srcObject && (v.srcObject as MediaStream).getTracks().length > 0);
    expect(live).toBeTruthy();
  }

  await shot(alice, '10-call-alice');
  await shot(bob, '10-call-bob');
  await a.close();
  await b.close();
});
