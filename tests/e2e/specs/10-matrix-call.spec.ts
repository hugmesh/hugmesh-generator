import { test, expect } from '@playwright/test';
import {
  onboard, matrixUserId, createRoom, joinRoom, requirePlatformPersonas,
  expectUiCallOk, UI_ROOM_SEND, shot,
} from './helpers';

// KNOWN BLOCKER: the call is signalled by m.call.* events sent through the SAME
// room-scoped `/rooms/<id>/send/<type>/<txn>` path that spec 05 documents at the
// bottom of its file — hugmesh-matrix-ui percent-encodes the room id and tuwunel
// v1.7.0 does not decode it, so call-start's m.call.invite never reaches the
// homeserver. That needs a matrix-ui source change + image rebuild; the
// assertions here are left intact and will pass once it lands.
//
// PERSONAS — see 05: the call is signalled over a real Matrix room, so the two
// callers must hold the per-platform ROLE_MATRIX access role. alice@/bob@ hold
// ROLE_USER only and are DENIED the homeserver backend by design (spec 17), so
// this drives the two seeded ROLE_MATRIX personas instead. Intent unchanged: two
// distinct users, one real WebRTC call between them.
const [ALICE, BOB] = requirePlatformPersonas('ROLE_MATRIX', 2);

// Real WebRTC: two browser contexts (fake media) establish a peer connection,
// signalled over a shared Matrix room via the hugmesh-matrix-ui call module.
test('two users hold a Matrix video call (WebRTC, room-signalled)', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();

  await onboard(alice, ALICE.username, ALICE.password);
  await onboard(bob, BOB.username, BOB.password);
  // Shared room via each page's hsproxy (cookie-authed; no browser Matrix token).
  const bobUserId = await matrixUserId(bob);
  const roomId = await createRoom(alice, bobUserId, 'callroom');
  await joinRoom(bob, roomId);

  const q = `?room=${encodeURIComponent(roomId)}`;
  await alice.goto(`/social/matrix/call${q}`);
  await bob.goto(`/social/matrix/call${q}`);
  await expect(alice.getByTestId('call-view')).toBeVisible();
  await expect(bob.getByTestId('call-view')).toBeVisible();

  // Alice starts; Bob's UI rings; Bob joins. The start is wrapped so a failing
  // m.call.invite send reports as itself (status + URL) rather than as a silent
  // 15s wait for a 'ringing' state that can never arrive.
  await expectUiCallOk(alice, UI_ROOM_SEND, "alice's call-start signalling event", async () => {
    await alice.getByTestId('call-start').click();
  });
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
