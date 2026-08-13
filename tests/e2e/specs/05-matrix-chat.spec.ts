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
  // later as an empty log — see the KNOWN BLOCKER note at the bottom of this file.
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
// KNOWN BLOCKER (product defect, NOT a spec defect) — hugmesh-matrix-ui encodes
// the room id, tuwunel does not decode it.
//
// With the personas fixed above, every hsproxy call this spec makes itself now
// succeeds and the room really is shared. What still fails is the UI's OWN
// room-scoped CS-API calls. matrix.service.ts builds them as
// `rooms/${this.enc(roomId)}/…` with `enc(s) { return encodeURIComponent(s); }`
// (verified in the DEPLOYED bundle, not just in source:
// `docker exec hugmesh-local-hugmesh-matrix-ui-1 grep enc(  routes-*.js`), and
// tuwunel v1.7.0 does not percent-decode the path parameter, so `!id%3Alocalhost`
// reaches the room-id deserializer literally. Observed live from the running UI:
//
//   PUT  …/rooms/!m4iwDAcfCDEQ1ZM75w%3Alocalhost/send/m.room.message/…  -> 500
//   GET  …/rooms/!m4iwDAcfCDEQ1ZM75w%3Alocalhost/messages?dir=b&limit=50 -> 403
//   PUT  …/rooms/!LmrBEFNwdPsY0FfToB%3Alocalhost/send/…  (curl)  -> 400 M_BAD_JSON
//        "deserialization failed: leading sigil is incorrect or missing"
//   PUT  …/rooms/!LmrBEFNwdPsY0FfToB:localhost/send/…    (curl)  -> 200
//
// helpers.ts's own calls were moved off encodeURIComponent for exactly this
// reason (see pathParam there). The UI needs the same change — a source edit in
// hugmesh-matrix-ui plus an image rebuild — so it is NOT fixable from the test
// tree. The assertions above are deliberately left intact: they describe the
// contract this spec exists to prove, and they will pass once the UI is fixed.
// ────────────────────────────────────────────────────────────────────────────
