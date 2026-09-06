import { test, expect } from '@playwright/test';
import {
  onboard, matrixUserId, createRoom, joinRoom, requirePlatformPersonas,
  expectUiCallOk, UI_ROOM_SEND, shot,
} from './helpers';

// 05 — TWO USERS CHAT through the Matrix UI.
//
// PERSONAS. This drove alice@gmail.com / bob@gmail.com, which hold ROLE_USER and
// nothing else. The broad ROLE_USER homeserver floor was removed (commit 0100d3b)
// in favour of the per-platform ROLE_MATRIX access role, so those handles are now
// DENIED the Matrix backend BY DESIGN — spec 17 asserts that deny explicitly, and
// granting them ROLE_MATRIX to revive this spec would contradict it. The live
// stack agrees: alice -> POST /bff/provision/matrix = 403, and createRoom through
// the hsproxy = 403 with an EMPTY body.
//
// So the flow now runs on the two seeded ROLE_MATRIX platform-access personas
// (helpers.requirePlatformPersonas -> e2e-matrix and e2e-matrix-external-client;
// both hold ROLE_MATRIX + ROLE_USER, the second additionally holding the
// external-client passthrough role, which does not restrict this UI path).
// The INTENT is unchanged: two DISTINCT signed-in users, two cookie-separated
// browser contexts, a real shared room, and each one seeing the other's message.
const [ALICE, BOB] = requirePlatformPersonas('ROLE_MATRIX', 2);

test('two users chat with each other through the Matrix UI', async ({ browser }) => {
  const a = await browser.newContext({ ignoreHTTPSErrors: true });
  const b = await browser.newContext({ ignoreHTTPSErrors: true });
  const alice = await a.newPage();
  const bob = await b.newPage();

  await onboard(alice, ALICE.username, ALICE.password);
  await onboard(bob, BOB.username, BOB.password);

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

  // Alice sends; Bob must see it (polled). The send is wrapped so a FAILING
  // CS-API call is reported as itself (status + URL) instead of surfacing 15s
  // later as an empty log — see the FORMER BLOCKER note at the bottom of this file.
  await expectUiCallOk(alice, UI_ROOM_SEND, "alice's composer send", async () => {
    await alice.getByTestId('matrix-input').fill('hi Bob — alice here');
    await alice.getByTestId('matrix-send').click();
  });
  await expect(bob.getByTestId('matrix-log')).toContainText('hi Bob — alice here');

  // Bob replies; Alice must see it.
  await expectUiCallOk(bob, UI_ROOM_SEND, "bob's composer send", async () => {
    await bob.getByTestId('matrix-input').fill('hey Alice — bob here');
    await bob.getByTestId('matrix-send').click();
  });
  await expect(alice.getByTestId('matrix-log')).toContainText('hey Alice — bob here');

  await shot(alice, '05-matrix-alice');
  await shot(bob, '05-matrix-bob');
  await a.close();
  await b.close();
});

// ────────────────────────────────────────────────────────────────────────────
// FORMER BLOCKER — RESOLVED in the deployed hugmesh-matrix-ui.
//
// This file used to end with a "KNOWN BLOCKER (product defect)" note: the UI's
// matrix.service.ts built room-scoped CS-API paths with a bare
// `encodeURIComponent(roomId)`, tuwunel v1.7.0 does not percent-decode the path
// parameter, so `!id%3Alocalhost` reached the room-id deserializer literally and
// the UI's own send/messages calls came back 500/403 while helpers.ts's calls
// (moved to pathParam for exactly that reason) succeeded. The UI now restores
// the sub-delims tuwunel expects — the deployed bundle reads
// `enc(e){return encodeURIComponent(e).replace(/%(24|26|2B|2C|3A|3B|3D|40)/gi,
// t=>decodeURIComponent(t))}` — and this spec passed end to end against the
// live compose stack + tuwunel on 2026-09-05 (both composer sends 200, both
// logs showing the peer's line). expectUiCallOk stays: it is what turns a
// regression of that encoding back into a status+URL instead of an empty log.
//
// What this spec DOES need from the stack: the `social` compose profile
// (`make stack-up SOCIAL=1`). On a core-only stack user-bff's hsproxy has no
// tuwunel to reach and the very first room-setup call (matrixUserId -> whoami)
// fails as `HTTP 502 Bad Gateway` — an environment gap, not a product defect.
// ────────────────────────────────────────────────────────────────────────────
