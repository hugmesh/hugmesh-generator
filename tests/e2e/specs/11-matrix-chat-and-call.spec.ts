import { test, expect } from '@playwright/test';
import { onboard, createRoom, joinRoom, shot } from './helpers';

// End-to-end social flow: two onboarded users hold a text chat in a shared
// Matrix room, then escalate to a real-WebRTC VOICE call signalled over that
// same room (via snapdragon-matrix-ui's call module). The call module also
// carries video, but this test asserts the VOICE path specifically: a live
// remote AUDIO track on both peers. Combines the 05 (chat) + 10 (call) flows
// into the single "chat → call" journey a real user takes.
test('two users chat, then escalate to a voice call', async ({ browser, request }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();

  const sa = await onboard(alice, 'alice@gmail.com');
  const sb = await onboard(bob, 'bob@gmail.com');

  // Shared room, created + joined BEFORE opening the views (the chat component
  // reads joined rooms on init, then polls; the call module signals through it).
  const roomId = await createRoom(request, sa, sb.matrix!.userId, 'chat-then-call');
  await joinRoom(request, sb, roomId);
  const q = `?room=${encodeURIComponent(roomId)}`;

  // ── 1. They chat ──────────────────────────────────────────────────
  await alice.goto(`/social/matrix${q}`);
  await bob.goto(`/social/matrix${q}`);
  await expect(alice.getByTestId('matrix-view')).toBeVisible();
  await expect(bob.getByTestId('matrix-view')).toBeVisible();

  await alice.getByTestId('matrix-input').fill('hey Bob — voice call in a sec?');
  await alice.getByTestId('matrix-send').click();
  await expect(bob.getByTestId('matrix-log')).toContainText('hey Bob — voice call in a sec?');

  await bob.getByTestId('matrix-input').fill('sure Alice — ring me');
  await bob.getByTestId('matrix-send').click();
  await expect(alice.getByTestId('matrix-log')).toContainText('sure Alice — ring me');

  // ── 2. Alice starts a voice call in the same room; Bob answers ─────
  await alice.goto(`/social/matrix/call${q}`);
  await bob.goto(`/social/matrix/call${q}`);
  await expect(alice.getByTestId('call-view')).toBeVisible();
  await expect(bob.getByTestId('call-view')).toBeVisible();

  await alice.getByTestId('call-start').click();
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
