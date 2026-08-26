// matrix.steps.ts — the Matrix (tuwunel) step vocabulary.
//
// Backs features/matrix/**. Every step here is the executable form of an
// assertion that already exists in tests/e2e/specs/05-matrix-chat,
// 07-discord, 10-matrix-call, 11-matrix-chat-and-call, 31-matrix-group-chat and
// 32-matrix-chat3d — driven through the SAME helpers those specs drive
// (specs/helpers.ts onboard/createRoom/joinRoom/matrixUserId/expectUiCallOk), so
// the two lanes cannot drift into asserting different things.
//
// KNOWN PRODUCT BLOCKER carried over verbatim, not papered over: the shipped
// hugmesh-matrix-ui percent-encodes the room id in every room-scoped CS-API path
// and the user-bff hsproxy mangles that spelling (the full live-probed story is
// in the footer of specs/31-matrix-group-chat.spec.ts). The UI-driven send/call
// steps therefore FAIL today against a live stack. They are left asserting the
// contract they exist to prove — deleting the assertion would turn a reported
// product defect into invisible green.

import { expect } from '@playwright/test';
import { Given, When, Then, requireDimension, substep } from './world';
import { persona } from './dimensions';
import {
  matrixUserId, createRoom, joinRoom, expectUiCallOk, UI_ROOM_SEND,
  platformPersonas, registerOnly, getSession,
} from '../specs/helpers';
import { peer, peersOf, signInPeers, platformAccessRole } from './social-peers';
import type { Peer } from './social-peers';

/** Mirrors helpers.ts MATRIX_HSPROXY (module-private there): the same-origin
 *  user-bff hsproxy prefix every CS-API call rides. */
const HS = '/bff/user/matrix';

/**
 * Mirrors helpers.ts `pathParam` — and specs 31/32, which each carry the same
 * mirror for the same reason (it is module-private in helpers.ts). Percent-encode
 * a path segment, then restore the characters RFC 3986 permits LITERALLY in a
 * segment (pchar — notably ':'). Both spellings are valid URIs, so this is an
 * encoding CHOICE; it is the one the whole suite sends, because the hsproxy
 * mangles the escaped spelling. THIS IS THE THIRD COPY IN THE TREE: if it ever
 * needs changing, export it from helpers.ts and delete all three.
 */
function pathParam(value: string): string {
  return encodeURIComponent(value).replace(/%(24|26|2B|2C|3A|3B|3D|40)/gi, (m) => decodeURIComponent(m));
}

/** The mxid localpart (`@alice:hs` -> `alice`) — the identifier substring that
 *  survives whichever display-name fallback a lane resolves to (spec 31). */
const localpart = (mxid: string): string => mxid.replace(/^@/, '').split(':')[0];

/** world keys this file owns. */
const ROOM = 'matrix-room-id';
const ROOM_A = 'matrix-room-a';
const ROOM_B = 'matrix-room-b';
const MY_MXID = 'matrix-my-mxid';
const SENT = 'matrix-sent-messages';   // {handle, mxid, body}[]

/** Resolve (and memoise) the signed-in page's own Matrix user id. */
async function myMxid(page: any, world: any): Promise<string> {
  if (!world.has(MY_MXID)) world.set(MY_MXID, await matrixUserId(page));
  return world.get<string>(MY_MXID);
}

async function peerMxid(p: Peer): Promise<string> {
  if (!p.matrixUserId) p.matrixUserId = await matrixUserId(p.page);
  return p.matrixUserId;
}

function roomQuery(roomId: string): string {
  return `?room=${encodeURIComponent(roomId)}`;
}

function recordSent(world: any, handle: string, mxid: string, body: string): void {
  const all = world.has(SENT) ? world.get<any[]>(SENT) : [];
  all.push({ handle, mxid, body });
  world.set(SENT, all);
}

// ── roster contracts (offline; no stack required) ────────────────────────────

/**
 * The multi-party proofs need a roster of a given size. Spec 31 skips its
 * three-party test when the catalogue is short; this asserts the catalogue
 * instead, so a roster that shrinks is a RED contract scenario rather than a
 * silently-skipped journey nobody notices.
 */
Then('the platform roster for the service dimension seeds at least {int} non-domain-locked personas',
  async ({ dimensions }, count: number) => {
    const id = requireDimension(dimensions, 'service');
    const role = platformAccessRole(id);
    const roster = platformPersonas(role);
    expect(
      roster.length,
      `${role} roster for @service:${id} = [${roster.map((p) => p.username).join(', ') || 'none'}]. `
      + `Multi-party proofs need ${count}; seed another ${role} persona into SYSTEMS_SEED_USERS `
      + `+ seed-accounts.sh rather than granting the role to a plain ROLE_USER handle.`,
    ).toBeGreaterThanOrEqual(count);
  });

// ── sign-in / peers ──────────────────────────────────────────────────────────

// Onboarding is provisioning-heavy and every persona shares the one BFF, so each
// extra member costs a full page-load journey. The default 90s scenario timeout
// (playwright.config.ts) is a two-party budget; widen it HERE, where the cost is
// incurred, rather than making every scenario in the suite pay for it.
Given('one more seeded Matrix persona signs in as my peer', async ({ browser, world, dimensions, $testInfo }) => {
  $testInfo.setTimeout(240_000);
  const self = persona(requireDimension(dimensions, 'role'));
  await signInPeers(browser, world, 'tuwunel', self, 1);
});

Given('two more seeded Matrix personas sign in as my peers', async ({ browser, world, dimensions, $testInfo }) => {
  $testInfo.setTimeout(300_000);
  const self = persona(requireDimension(dimensions, 'role'));
  await signInPeers(browser, world, 'tuwunel', self, 2);
});

// ── rooms ────────────────────────────────────────────────────────────────────

Given('my peer and I share a Matrix room named {string}', async ({ page, world }, name: string) => {
  const p = peer(world, 0);
  const roomId = await createRoom(page, await peerMxid(p), name);
  await joinRoom(p.page, roomId);
  world.set(ROOM, roomId);
});

Given('my peers and I share a private Matrix room named {string} with the invites still pending',
  async ({ page, world }, name: string) => {
    const all = peersOf(world);
    const invitees: string[] = [];
    for (const p of all) invitees.push(await peerMxid(p));
    // Nobody joins here: the invites must surface as PENDING rows in the peers'
    // room lists, which is the group surface spec 31 exists to drive.
    world.set(ROOM, await createRoom(page, invitees, name, { preset: 'private_chat' }));
  });

Given('my peer and I share two private Matrix rooms named {string} and {string}',
  async ({ page, world }, nameA: string, nameB: string) => {
    const p = peer(world, 0);
    const mxid = await peerMxid(p);
    const a = await createRoom(page, mxid, nameA, { preset: 'private_chat' });
    const b = await createRoom(page, mxid, nameB, { preset: 'private_chat' });
    // The hsproxy join, not the UI accept path — the UI accept is proven by its
    // own scenario and re-proving it here would couple two claims.
    await joinRoom(p.page, a);
    await joinRoom(p.page, b);
    world.set(ROOM_A, a);
    world.set(ROOM_B, b);
  });

// ── chat view ────────────────────────────────────────────────────────────────

When('I open the Matrix chat view for our room', async ({ page, world }) => {
  await page.goto(`/social/matrix${roomQuery(world.get<string>(ROOM))}`);
});

When('my peer opens the Matrix chat view for our room', async ({ world }) => {
  await peer(world, 0).page.goto(`/social/matrix${roomQuery(world.get<string>(ROOM))}`);
});

When('every member opens the Matrix chat view for our room', async ({ page, world }) => {
  const q = roomQuery(world.get<string>(ROOM));
  await substep('the room creator opens the chat view', async () => {
    await page.goto(`/social/matrix${q}`);
    await expect(page.getByTestId('matrix-view')).toBeVisible();
  });
  for (const [i, p] of peersOf(world).entries()) {
    await substep(`peer ${i + 1} (${p.handle}) opens the chat view`, async () => {
      await p.page.goto(`/social/matrix${q}`);
      await expect(p.page.getByTestId('matrix-view')).toBeVisible();
    });
  }
});

Then('the Matrix chat view is rendered for both of us', async ({ page, world }) => {
  await expect(page.getByTestId('matrix-view')).toBeVisible();
  await expect(peer(world, 0).page.getByTestId('matrix-view')).toBeVisible();
});

// ── sending + reading messages ───────────────────────────────────────────────
//
// Each send is wrapped in expectUiCallOk so a FAILING CS-API call is reported as
// itself (status + URL) instead of surfacing 15s later as a `toContainText`
// against an empty log — the diagnostic that exposed the encoded-room-id defect.

async function sendAs(who: { page: any; handle: string }, body: string): Promise<void> {
  await expectUiCallOk(who.page, UI_ROOM_SEND, `${who.handle}'s composer send`, async () => {
    await who.page.getByTestId('matrix-input').fill(body);
    await who.page.getByTestId('matrix-send').click();
  });
}

When('I send the Matrix chat message {string}', async ({ page, world, dimensions }, body: string) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  await expectUiCallOk(page, UI_ROOM_SEND, `${handle}'s composer send`, async () => {
    await page.getByTestId('matrix-input').fill(body);
    await page.getByTestId('matrix-send').click();
  });
  recordSent(world, handle, await myMxid(page, world), body);
});

When('my peer sends the Matrix chat message {string}', async ({ world }, body: string) => {
  const p = peer(world, 0);
  await sendAs(p, body);
  recordSent(world, p.handle, await peerMxid(p), body);
});

When('my second peer sends the Matrix chat message {string}', async ({ world }, body: string) => {
  const p = peer(world, 1);
  await sendAs(p, body);
  recordSent(world, p.handle, await peerMxid(p), body);
});

Then('my Matrix log contains {string}', async ({ page }, body: string) => {
  await expect(page.getByTestId('matrix-log')).toContainText(body);
});

Then('my peer\'s Matrix log contains {string}', async ({ world }, body: string) => {
  await expect(peer(world, 0).page.getByTestId('matrix-log')).toContainText(body);
});

Then('every member\'s Matrix log shows every message sent in this room', async ({ page, world }) => {
  const sent = world.get<{ body: string }[]>(SENT);
  expect(sent.length, 'no message was recorded — the sending When must run first').toBeGreaterThan(0);
  const logs = [page, ...peersOf(world).map((p) => p.page)];
  for (const l of logs) {
    for (const m of sent) await expect(l.getByTestId('matrix-log')).toContainText(m.body);
  }
});

/**
 * Sender attribution on ONE viewer's page (spec 31): every message carries ITS
 * OWN sender's identifier, and another member's label is never the same as that
 * viewer's own-message label. Substring on the mxid LOCALPART, because a lane
 * whose display-name resolution falls back to the raw mxid still contains it.
 */
Then('on my peer\'s page every message is attributed to its own sender', async ({ world }) => {
  const viewer = peer(world, 0);
  const sent = world.get<{ handle: string; mxid: string; body: string }[]>(SENT);
  const labelOf = async (body: string): Promise<string> => {
    const row = viewer.page.locator('[data-testid="matrix-log"] li.event').filter({ hasText: body }).first();
    return ((await row.getByTestId('event-sender').textContent()) ?? '').trim();
  };
  const own = sent.find((m) => m.handle === viewer.handle);
  expect(own, `${viewer.handle} sent nothing in this room, so there is no own-message label to compare against`).toBeTruthy();
  const ownLabel = await labelOf(own!.body);
  for (const m of sent) {
    const label = await labelOf(m.body);
    expect(label, `"${m.body}" is attributed to ${m.handle} on ${viewer.handle}'s page`)
      .toContain(localpart(m.mxid));
    if (m.handle !== viewer.handle) {
      expect(label, `another member's message is never labelled like ${viewer.handle}'s own`).not.toBe(ownLabel);
    }
  }
});

// ── pending invites (group) ──────────────────────────────────────────────────

Then('each of my peers sees a pending Matrix invite from me and accepts it in the UI',
  async ({ page, world }) => {
    const roomId = world.get<string>(ROOM);
    const inviter = await myMxid(page, world);
    for (const p of peersOf(world)) {
      await substep(`${p.handle} accepts the invite`, async () => {
        await p.page.goto('/social/matrix');
        await expect(p.page.getByTestId(`invite-item-${roomId}`)).toBeVisible();
        // The rendered inviter is the m.room.member invite event's SENDER — my
        // mxid. Display-name resolution may fall back to it; the mxid is the
        // lane-portable assertion.
        await expect(p.page.getByTestId(`invite-inviter-${roomId}`)).toContainText(inviter);
        await p.page.getByTestId(`btn-accept-invite-${roomId}`).click();
        await expect(p.page.getByTestId(`invite-item-${roomId}`)).toHaveCount(0);
        await expect(p.page.getByTestId(`room-item-${roomId}`)).toBeVisible();
      });
    }
  });

// ── room switching + unread badge ────────────────────────────────────────────

When('my peer parks in the first room', async ({ world }) => {
  const p = peer(world, 0);
  await p.page.goto(`/social/matrix${roomQuery(world.get<string>(ROOM_A))}`);
  await expect(p.page.getByTestId(`room-item-${world.get<string>(ROOM_A)}`)).toBeVisible();
  await expect(p.page.getByTestId(`room-item-${world.get<string>(ROOM_B)}`)).toBeVisible();
});

Then('neither room row carries an unread badge', async ({ world }) => {
  const p = peer(world, 0);
  await expect(p.page.getByTestId(`room-unread-${world.get<string>(ROOM_A)}`)).toHaveCount(0);
  await expect(p.page.getByTestId(`room-unread-${world.get<string>(ROOM_B)}`)).toHaveCount(0);
});

When('I send {string} into the second room while my peer reads the first', async ({ page, world }, body: string) => {
  const roomId = world.get<string>(ROOM_B);
  const txn = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const r = await page.request.put(
    `${HS}/_matrix/client/v3/rooms/${pathParam(roomId)}/send/m.room.message/${txn}`,
    { data: { msgtype: 'm.text', body } },
  );
  expect(r.ok(), `background send into ${roomId} (HTTP ${r.status()})`).toBe(true);
  world.set('matrix-background-message', body);
});

Then('the second room row grows a positive unread badge', async ({ world }) => {
  const badge = peer(world, 0).page.getByTestId(`room-unread-${world.get<string>(ROOM_B)}`);
  await expect(badge).toBeVisible();
  await expect(badge).toHaveText(/^[1-9]\d*$/);
});

When('my peer opens the second room from the room list', async ({ world }) => {
  const p = peer(world, 0);
  await p.page.getByTestId(`room-item-${world.get<string>(ROOM_B)}`).click();
  // The room row is an <a> whose ABSOLUTE ['/rooms', id] routerLink the HOST
  // cannot route: today the navigation errors in place and only the row's
  // (click) selection fires. Pin that assumption here, so a host that later
  // grows a /rooms route fails with a precise reason instead of a mysterious
  // matrix-log timeout after the page navigated away.
  await expect(
    p.page,
    'the room-item click must stay on /social/matrix — the host must not route the row\'s absolute /rooms link',
  ).toHaveURL(/\/social\/matrix/);
});

Then('my peer sees the backgrounded message and the unread badge is cleared', async ({ world }) => {
  const p = peer(world, 0);
  await expect(p.page.getByTestId('matrix-log')).toContainText(world.get<string>('matrix-background-message'));
  await expect(p.page.getByTestId(`room-unread-${world.get<string>(ROOM_B)}`)).toHaveCount(0);
});

// ── the WebRTC call surfaces ─────────────────────────────────────────────────

When('I open the Matrix call view for our room', async ({ page, world }) => {
  await page.goto(`/social/matrix/call${roomQuery(world.get<string>(ROOM))}`);
});

When('my peer opens the Matrix call view for our room', async ({ world }) => {
  await peer(world, 0).page.goto(`/social/matrix/call${roomQuery(world.get<string>(ROOM))}`);
});

Then('the Matrix call view is rendered for both of us', async ({ page, world }) => {
  await expect(page.getByTestId('call-view')).toBeVisible();
  await expect(peer(world, 0).page.getByTestId('call-view')).toBeVisible();
});

When('I start the Matrix call', async ({ page, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  await expectUiCallOk(page, UI_ROOM_SEND, `${handle}'s call-start signalling event`, async () => {
    await page.getByTestId('call-start').click();
  });
});

Then('my peer\'s call state becomes {string}', async ({ world }, state: string) => {
  await expect(peer(world, 0).page.getByTestId('call-state')).toHaveText(state, { timeout: 15_000 });
});

When('my peer answers the Matrix call', async ({ world }) => {
  await peer(world, 0).page.getByTestId('call-join').click();
});

Then('both call states become {string}', async ({ page, world }, state: string) => {
  await expect(page.getByTestId('call-state')).toHaveText(state, { timeout: 30_000 });
  await expect(peer(world, 0).page.getByTestId('call-state')).toHaveText(state, { timeout: 30_000 });
});

Then('both of us receive a live remote video track', async ({ page, world }) => {
  for (const p of [page, peer(world, 0).page]) {
    const live = await p.locator('[data-testid=remote-video]').evaluate(
      (v: HTMLVideoElement) => !!v.srcObject && (v.srcObject as MediaStream).getTracks().length > 0,
    );
    expect(live, 'a remote MediaStream with at least one track').toBeTruthy();
  }
});

Then('both of us receive a live remote audio track', async ({ page, world }) => {
  for (const p of [page, peer(world, 0).page]) {
    await expect
      .poll(
        () => p.locator('[data-testid=remote-video]').evaluate((v: HTMLVideoElement) => {
          const ms = v.srcObject as MediaStream | null;
          const audio = ms ? ms.getAudioTracks() : [];
          return audio.length > 0 && audio.every((t) => t.readyState === 'live');
        }),
        { timeout: 15_000 },
      )
      .toBe(true);
  }
});

// ── native sign-in into the social shell (spec 07) ───────────────────────────

When('an unprovisioned username {string} attempts native sign-in', async ({ page }, username: string) => {
  // Deliberately NOT a @role: persona: the whole claim is that no seeder ever
  // created this handle, so resolving it through the roster would be wrong.
  await registerOnly(page, username);
});

Then('the native sign-in error reports a failed sign-in', async ({ page }) => {
  await expect(page.getByTestId('login-error')).toContainText('Sign-in failed');
});

Then('my session was minted by the native password provider', async ({ page, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const s = await getSession(page, handle);
  expect(s.provider, 'the only login surface is our native username/password form').toBe('password');
});

When('I open Matrix from the social nav', async ({ page }) => {
  await page.getByTestId('nav-matrix').click();
});

// ── the per-platform ACCESS wall, live through the hsproxy ───────────────────

Then('the Matrix hsproxy returns my Matrix user id', async ({ page, world, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const mxid = await myMxid(page, world);
  expect(mxid, `matrix whoami user_id for ${handle}`).toMatch(/^@[^:]+:.+$/);
});

Then('the Matrix hsproxy refuses me the homeserver backend', async ({ page, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const r = await page.request.get(`${HS}/_matrix/client/v3/account/whoami`);
  expect(
    r.ok(),
    `persona '${handle}' holds no ROLE_MATRIX, so the homeserver backend must refuse it — `
    + `got HTTP ${r.status()}. A 2xx here means the per-platform access wall (commit 0100d3b) `
    + `has regressed into the old broad ROLE_USER homeserver floor.`,
  ).toBe(false);
  expect([401, 403], `refusal status for '${handle}' (got ${r.status()})`).toContain(r.status());
});
