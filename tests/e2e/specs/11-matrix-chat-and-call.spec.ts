import { test, expect } from '@playwright/test';
import {
  onboard, matrixUserId, createRoom, joinRoom, requirePlatformPersonas,
  expectUiCallOk, UI_ROOM_SEND, shot,
} from './helpers';

// KNOWN BLOCKER: both halves of this journey (the composer send and the m.call.*
// signalling) ride the room-scoped `/rooms/<id>/send/...` path that spec 05
// documents at the bottom of its file — hugmesh-matrix-ui percent-encodes the
// room id and tuwunel v1.7.0 does not decode it. Needs a matrix-ui source change
// + image rebuild; the assertions here are left intact.
//
// PERSONAS — see 05: chat AND the room-signalled call both hit the Matrix
// backend, which is gated on the per-platform ROLE_MATRIX access role. alice@/bob@
// hold ROLE_USER only and are denied it by design (spec 17), so this journey runs
// on the two seeded ROLE_MATRIX personas. Intent unchanged: the same two users
// chat, then escalate to a voice call in that same room.
const [ALICE, BOB] = requirePlatformPersonas('ROLE_MATRIX', 2);

// End-to-end social flow: two onboarded users hold a text chat in a shared
// Matrix room, then escalate to a real-WebRTC VOICE call signalled over that
// same room (via hugmesh-matrix-ui's call module). The call module also
// carries video, but this test asserts the VOICE path specifically: a live
// remote AUDIO track on both peers. Combines the 05 (chat) + 10 (call) flows
// into the single "chat → call" journey a real user takes.
test('two users chat, then escalate to a voice call', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();

  await onboard(alice, ALICE.username, ALICE.password);
  await onboard(bob, BOB.username, BOB.password);

  // Shared room, created + joined BEFORE opening the views (the chat component
  // reads joined rooms on init, then polls; the call module signals through it).
  // Created through each page's hsproxy (cookie-authed; no browser Matrix token).
  const bobUserId = await matrixUserId(bob);
  const roomId = await createRoom(alice, bobUserId, 'chat-then-call');
  await joinRoom(bob, roomId);
  const q = `?room=${encodeURIComponent(roomId)}`;

  // ── 1. They chat ──────────────────────────────────────────────────
  await alice.goto(`/social/matrix${q}`);
  await bob.goto(`/social/matrix${q}`);
  await expect(alice.getByTestId('matrix-view')).toBeVisible();
  await expect(bob.getByTestId('matrix-view')).toBeVisible();

  // Each send is wrapped so a failing CS-API call reports as itself (status +
  // URL) instead of as an empty log 15s later.
  await expectUiCallOk(alice, UI_ROOM_SEND, "alice's composer send", async () => {
    await alice.getByTestId('matrix-input').fill('hey Bob — voice call in a sec?');
    await alice.getByTestId('matrix-send').click();
  });
  await expect(bob.getByTestId('matrix-log')).toContainText('hey Bob — voice call in a sec?');

  await expectUiCallOk(bob, UI_ROOM_SEND, "bob's composer send", async () => {
    await bob.getByTestId('matrix-input').fill('sure Alice — ring me');
    await bob.getByTestId('matrix-send').click();
  });
  await expect(alice.getByTestId('matrix-log')).toContainText('sure Alice — ring me');

  // ── 2. Alice starts a voice call in the same room; Bob answers ─────
  await alice.goto(`/social/matrix/call${q}`);
  await bob.goto(`/social/matrix/call${q}`);
  await expect(alice.getByTestId('call-view')).toBeVisible();
  await expect(bob.getByTestId('call-view')).toBeVisible();

  await expectUiCallOk(alice, UI_ROOM_SEND, "alice's call-start signalling event", async () => {
    await alice.getByTestId('call-start').click();
  });
  await expect(bob.getByTestId('call-state')).toHaveText('ringing', { timeout: 15_000 });
  await bob.getByTestId('call-join').click();

  // Both peers reach a connected WebRTC state.
  await expect(alice.getByTestId('call-state')).toHaveText('connected', { timeout: 30_000 });
  await expect(bob.getByTestId('call-state')).toHaveText('connected', { timeout: 30_000 });

  // Voice is actually flowing: each side receives a LIVE remote audio track.
  for (const p of [alice, bob]) {
    await expect
      .poll(
        () =>
          p.locator('[data-testid=remote-video]').evaluate((v: HTMLVideoElement) => {
            const ms = v.srcObject as MediaStream | null;
            const audio = ms ? ms.getAudioTracks() : [];
            return audio.length > 0 && audio.every((t) => t.readyState === 'live');
          }),
        { timeout: 15_000 },
      )
      .toBe(true);
  }

  await shot(alice, '11-chatcall-alice');
  await shot(bob, '11-chatcall-bob');
  await a.close();
  await b.close();
});
