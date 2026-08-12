import { test, expect } from '@playwright/test';
import type { Browser, BrowserContext, Page } from '@playwright/test';
import {
  onboard, matrixUserId, createRoom, joinRoom, shot,
  platformPersonas, requirePlatformPersonas,
} from './helpers';
import type { PlatformPersona } from './helpers';
import { tags } from './report-tags';

// ────────────────────────────────────────────────────────────────────────────
// 31 — MATRIX GROUP CHAT: multi-invitee rooms, the invitee's accept flow, and
// the room-list unread badge across a room switch.
//
// Extends the two-party spec 05 to the GROUP surfaces the matrix-ui room list
// now renders: pending-invite rows (invite-item / invite-inviter with explicit
// Accept), per-room unread badges (room-unread-<id>, fed by /sync
// unread_notifications and cleared by selecting the room), and per-message
// sender attribution (event-sender) once three members talk in one room.
//
// WHO DRIVES THIS (changed 2026-08-12): originally alice@/bob@/carol@gmail.com.
// Those invite handles hold ROLE_USER and NOTHING ELSE, and the broad ROLE_USER
// homeserver floor was REMOVED (rbac-roles.ts on `e2e-user`, commit 0100d3b) in
// favour of the per-platform ROLE_MATRIX/ROLE_MASTODON access roles — so every
// hsproxy call they make is a 403 by DESIGN, which spec 17 asserts on purpose.
// Proven live: alice@gmail.com -> roles ["user"] -> GET .../account/whoami
// through the hsproxy = 403 with an EMPTY body, i.e. both tests below died in
// onboardMany() before touching a single group surface. Granting alice
// ROLE_MATRIX to "fix" that would directly contradict spec 17, so the personas
// come from helpers.platformPersonas('ROLE_MATRIX') — the seed catalogue's
// NON-domain-locked ROLE_MATRIX holders — instead.
//
// ROSTER SHORTFALL (why the three-user test skips today): that roster currently
// yields exactly TWO usable personas — e2e-matrix and e2e-matrix-external-client.
// e2e-matrix-domainlocked carries ROLE_MATRIX but helpers deliberately excludes
// domain-locked holders, since they are the SUBJECT of the non-federation proof
// (specs 19-23) and borrowing them for ordinary chat would entangle two proofs.
// The swarm personas (e2e-swarm-user-###, which do hold ROLE_MATRIX) are only
// created by `seed-accounts.sh --swarm` and are absent from the default seed —
// verified live: POST /bff/login as e2e-swarm-user-000 = 401. So the THREE-party
// test needs seed state nothing on this lane creates, and skips on that exact
// condition rather than passing a hollowed-out two-party assertion. It
// re-arms BY ITSELF the moment a third non-locked ROLE_MATRIX persona is seeded
// into SYSTEMS_SEED_USERS + seed-accounts.sh — no edit here required.
//
// Every Matrix CS-API call rides each page's user-bff hsproxy (auth = the
// httpOnly bff_session cookie; the browser holds no homeserver token), exactly
// as in specs 05/10/11. On the DEFAULT light stack the homeserver is the
// in-memory mock (tests/stack/mock-matrix.mjs), which tracks real
// invited-vs-joined membership, per-user read receipts and unread counts —
// so the flows below are honestly proven there AND against the real tuwunel
// (REAL_MATRIX=1) alike. Display-NAME resolution is the one soft spot: the
// mock lane may fall back to the localpart/mxid, so sender-attribution
// assertions pin the persona's mxid localpart substring, never a pretty name.
//
// FRONTEND VERSION DEPENDENCY: the unread-badge assertions need the matrix-ui
// build that folds /sync unread_notifications into the room rows (the
// hugmesh-matrix-ui group-chat-usability change, landed together with this
// spec). A stale tests/stack/.uidist predating it renders room-unread-* as
// permanently-dead markup — rebuild via tests/e2e/run-all.sh step 1 (or copy a
// fresh `ng build host`/`ng build matrix` into .uidist) before blaming this
// spec for a red badge test.
// ────────────────────────────────────────────────────────────────────────────

/** One onboarded persona: its own browser context (cookie jar = its own
 *  bff_session), the page, and the hsproxy-resolved Matrix user_id. */
interface Persona {
  ctx: BrowserContext;
  page: Page;
  userId: string;
}

/** Onboard each platform-access persona in its OWN browser context (sequentially
 *  — onboarding is provisioning-heavy and the personas share the one BFF).
 *  onboard() is idempotent, so personas already completed by earlier specs sign
 *  straight in. Each persona's password comes from the seed catalogue's resolver
 *  (rbac-roles.ts passwordFor), never a hard-coded literal. */
async function onboardMany(browser: Browser, personas: PlatformPersona[]): Promise<Persona[]> {
  const out: Persona[] = [];
  for (const { username, password } of personas) {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    await onboard(page, username, password);
    out.push({ ctx, page, userId: await matrixUserId(page) });
  }
  return out;
}

/** The NON-domain-locked ROLE_MATRIX holders in the seed catalogue — the only
 *  personas allowed to drive the homeserver backend (see the header). Resolved
 *  once at module load; the per-test guards below read its LENGTH so a roster
 *  change re-arms the tests without a spec edit. */
const MATRIX_PERSONAS = platformPersonas('ROLE_MATRIX');

/** Members the group test needs: a creator plus TWO invitees, so that "all
 *  members see all messages" and per-sender attribution are actually multi-party
 *  claims and not a two-party test wearing a group's name. */
const GROUP_MEMBERS = 3;

// Mirrors helpers.ts MATRIX_HSPROXY (module-private there): the same-origin
// user-bff hsproxy prefix every CS-API call below is addressed to.
const HS = '/bff/user/matrix';

/**
 * Mirrors helpers.ts `pathParam` (module-private there, like MATRIX_HSPROXY
 * above): percent-encode a path segment, then restore the characters RFC 3986
 * permits LITERALLY in a segment (pchar — notably ':'), which is what every other
 * room-scoped call in this suite now sends. Both spellings are valid URIs, so
 * this is an encoding CHOICE, not a trick: `:` is legal unencoded in a segment.
 *
 * It exists because the user-bff hsproxy mangles the encoded spelling (see the
 * KNOWN-RED note above the second test). Keep this identical to helpers.ts's
 * version — a spec that encodes differently from the shared helpers fails at a
 * different point in the same flow, which is exactly how this spec came to die
 * at joinRoom() one run and sendMessage() the next.
 */
function pathParam(value: string): string {
  return encodeURIComponent(value).replace(
    /%(24|26|2B|2C|3A|3B|3D|40)/gi,
    (m) => decodeURIComponent(m),
  );
}

/** Send an m.text message as the signed-in `page` user through the hsproxy —
 *  the same PUT the UI's composer issues, minus the rendering. */
async function sendMessage(page: Page, roomId: string, body: string): Promise<void> {
  const txn = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const r = await page.request.put(
    `${HS}/_matrix/client/v3/rooms/${pathParam(roomId)}/send/m.room.message/${txn}`,
    { data: { msgtype: 'm.text', body } },
  );
  expect(r.ok(), `send into ${roomId}`).toBe(true);
}

/** The rendered event-sender label of the (unique-bodied) message `body` on
 *  `page` — how THIS viewer sees that message attributed. */
async function senderOf(page: Page, body: string): Promise<string> {
  const row = page.locator('[data-testid="matrix-log"] li.event').filter({ hasText: body }).first();
  return ((await row.getByTestId('event-sender').textContent()) ?? '').trim();
}

/** The mxid localpart (`@alice:hs` → `alice`) — the identifier substring that
 *  survives whichever display-name fallback the lane resolves to. */
const localpart = (mxid: string): string => mxid.replace(/^@/, '').split(':')[0];

test(`three-user group room: pending invites accepted in the UI, all members see all messages with sender attribution ${tags({ role: 'ROLE_USER', layer: 'ui' })}`,
  async ({ browser }) => {
    // HONEST SEED GATE — a missing DEPENDENCY, not a soft assertion. Three
    // distinct non-domain-locked ROLE_MATRIX personas must exist for a
    // three-party proof; the default seed provisions two. Skipping names the
    // shortfall and the exact fix; it never degrades to a two-party pass.
    test.skip(
      MATRIX_PERSONAS.length < GROUP_MEMBERS,
      `needs ${GROUP_MEMBERS} non-domain-locked ROLE_MATRIX personas, the seed catalogue provides `
      + `${MATRIX_PERSONAS.length} (${MATRIX_PERSONAS.map((p) => p.username).join(', ') || 'none'}). `
      + `The swarm personas that would supply a third are created only by `
      + `seed-accounts.sh --swarm and are absent from this lane's seed. Fix by seeding another `
      + `ROLE_MATRIX persona into SYSTEMS_SEED_USERS + seed-accounts.sh — NOT by granting `
      + `ROLE_MATRIX to a plain-ROLE_USER handle (alice@/bob@/carol@), which spec 17 asserts is `
      + `denied the homeserver backend.`,
    );
    test.setTimeout(240_000); // three full onboardings (page-load each) + three chat shells
    const [alice, bob, carol] = await onboardMany(browser,
      requirePlatformPersonas('ROLE_MATRIX', GROUP_MEMBERS));

    // Alice creates ONE private room inviting BOTH peers. Neither peer joins
    // here — the invites must surface as pending rows in their UIs first.
    const roomId = await createRoom(alice.page, [bob.userId, carol.userId], 'e2e group',
      { preset: 'private_chat' });

    // Bob and carol each SEE the pending invite (room + who invited) and
    // accept it through the UI. The room-list loads invites on init, so the
    // navigation below (after the invite exists) is what surfaces the row.
    for (const [who, member] of [['bob', bob], ['carol', carol]] as const) {
      await member.page.goto('/social/matrix');
      await expect(member.page.getByTestId(`invite-item-${roomId}`)).toBeVisible();
      // The inviter rendered is the m.room.member invite event's SENDER —
      // alice's mxid (display-name resolution may fall back to it; the mxid
      // itself is the lane-portable assertion).
      await expect(member.page.getByTestId(`invite-inviter-${roomId}`)).toContainText(alice.userId);
      await shot(member.page, `31-invite-pending-${who}`);
      await member.page.getByTestId(`btn-accept-invite-${roomId}`).click();
      // Accepting resolves the invite row and moves the room into the joined list.
      await expect(member.page.getByTestId(`invite-item-${roomId}`)).toHaveCount(0);
      await expect(member.page.getByTestId(`room-item-${roomId}`)).toBeVisible();
    }

    // All three open the SAME room and each posts one distinct message
    // (bodies deliberately avoid the persona names so the per-row locator
    // filters on message text alone, never on the rendered sender label).
    const MSG = {
      alice: 'group message one — from the room creator',
      bob: 'group message two — from the first invitee',
      carol: 'group message three — from the second invitee',
    };
    const members = [
      { persona: alice, msg: MSG.alice },
      { persona: bob, msg: MSG.bob },
      { persona: carol, msg: MSG.carol },
    ];
    const q = `?room=${encodeURIComponent(roomId)}`;
    for (const { persona } of members) {
      await persona.page.goto(`/social/matrix${q}`);
      await expect(persona.page.getByTestId('matrix-view')).toBeVisible();
    }
    for (const { persona, msg } of members) {
      await persona.page.getByTestId('matrix-input').fill(msg);
      await persona.page.getByTestId('matrix-send').click();
    }
    // EVERY page sees ALL THREE messages (each arrives via that page's own
    // sync loop — three cookie-separated sessions, one shared room).
    for (const { persona } of members) {
      const log = persona.page.getByTestId('matrix-log');
      await expect(log).toContainText(MSG.alice);
      await expect(log).toContainText(MSG.bob);
      await expect(log).toContainText(MSG.carol);
    }

    // SENDER ATTRIBUTION on bob's page: alice's and carol's messages carry
    // THEIR identifier, and alice's label differs from bob's own-message
    // label. Substring on the mxid localpart — the mock lane may resolve
    // event-sender to the raw mxid rather than a display name, and both
    // spellings contain the localpart.
    const bobSeesAlice = await senderOf(bob.page, MSG.alice);
    const bobSeesBob = await senderOf(bob.page, MSG.bob);
    const bobSeesCarol = await senderOf(bob.page, MSG.carol);
    expect(bobSeesAlice, `alice's message is attributed to alice on bob's page`).toContain(localpart(alice.userId));
    expect(bobSeesCarol, `carol's message is attributed to carol on bob's page`).toContain(localpart(carol.userId));
    expect(bobSeesAlice, `alice's messages are never attributed like bob's own`).not.toBe(bobSeesBob);

    await shot(alice.page, '31-group-alice');
    await shot(bob.page, '31-group-bob-sees-all-three');
    await shot(carol.page, '31-group-carol');
    for (const { persona } of members) await persona.ctx.close();
  });

// ─────────────────────────────────────────────────────────────────────────────
// ENCODING NOTE — an OPEN product bug this spec routes around (2026-08-12).
//
// Every room-scoped CS-API path carries a room id containing a colon
// (`!abc:localhost`). Percent-encoding that segment is the obvious spelling, and
// it is what the SHIPPED matrix-ui does — its worker builds every room URL with
// `enc(t){return encodeURIComponent(t)}` (join, send, messages, state, invite,
// kick, redact; verified in tests/stack/.uidist/_remotes/matrix/worker-*.js).
// Through the user-bff hsproxy that spelling is BROKEN. Measured on this stack:
//
//   VIA the hsproxy, `%3A`  -> HTTP 500 {"errcode":"M_UNKNOWN","error":
//        "non-create event for room of unknown version in !Tq…%3Alocalhost"}
//                                              ^ the escape survived, undecoded
//   VIA the hsproxy, raw `:`                    -> HTTP 200
//   DIRECT to tuwunel :8008, `%21…%3A…`         -> HTTP 200
//   DIRECT to tuwunel :8008, `!…%3A…`           -> HTTP 200
//   DIRECT to tuwunel :8008, raw `!…:…`         -> HTTP 200
//
// The three DIRECT probes settle attribution: tuwunel v1.7.0 percent-decodes
// path segments correctly in every spelling, so the homeserver is NOT at fault
// and the hsproxy is the sole offender. (helpers.ts's pathParam comment blames
// "tuwunel does not percent-decode the segment" — that is contradicted by the
// probes above; the workaround it applies is still the right one, only the
// attribution is wrong.)
//
// CAUSE: HsReverseProxy#exchangeAndRelay hands the already-encoded path to
// `WebClient.uri(String)` under a comment asserting it "keeps the already-encoded
// path + query verbatim" — it does not. Nothing in hugmesh-user-bff-api sets a
// DefaultUriBuilderFactory encoding mode, so Spring's default
// (TEMPLATE_AND_VALUES) treats the string as a URI TEMPLATE and escapes its `%`,
// sending `%253A` upstream; tuwunel dutifully decodes that to a literal `%3A`.
// FIX (needs a rebuilt hugmesh-user-bff-api image, hence not done here): set the
// WebClient's uriBuilderFactory encoding mode to NONE, or pass a pre-built
// java.net.URI, then re-run the probes above.
//
// WHAT THIS SPEC DOES MEANWHILE: sends the raw-`:` spelling via pathParam(),
// matching helpers.ts and every other room-scoped call in the suite. That is an
// equally VALID URI (RFC 3986 permits ':' literally in a path segment), so it is
// a spelling choice rather than a bypass — but it only fixes the calls the TEST
// makes. The UI UNDER TEST still ships encodeURIComponent, so it stays crippled,
// and that is why the unread-badge assertion below is still RED.
//
// HOW CRIPPLED, measured in a real browser signed in as a ROLE_MATRIX persona:
// the room list renders (only /sync, which has no path variable, works), but the
// page fires a continuous stream of failures, ALL of them this one bug —
//
//   GET /rooms/!…%3Alocalhost/state                -> 403 M_FORBIDDEN
//        ("You don't have permission to view the room state" — because tuwunel
//         resolved a DIFFERENT room whose id literally contains "%3A", one this
//         user is of course not a member of; the raw-`:` spelling returns 200)
//   GET /user/@…%3Alocalhost/account_data/m.direct -> 400 M_BAD_JSON
//        ("deserialization failed: required colon is missing" — the smoking gun:
//         the colon arrived as an escape, so the user-id parser never saw one;
//         the raw-`:` spelling returns 404, i.e. simply no data)
//
// Because /state is dead, the UI cannot resolve room NAMES either: every row in
// the list renders its raw `!id:localhost` instead of "e2e switch room a".
//
// So the unread-badge behaviour CANNOT be honestly evaluated on this stack. The
// homeserver and the proxy do deliver the counts — verified end-to-end with a
// 30s long-poll through the hsproxy, which returned in ~1s carrying
// `unread_notifications: {"notification_count": 1}` for the backgrounded room —
// and the shipped bundle does contain both the mapping
// (`unreadCount: …unread_notifications?.notification_count`) and the badge
// markup (`data-testid="room-unread-"+roomId`). The badge still never appears,
// on a room list that is simultaneously failing to read any room state. Whether
// a SECOND, independent UI defect is hiding behind that cannot be settled until
// the proxy is fixed, so this test is left RED rather than skipped: it is
// reporting a real, user-visible breakage, not a stale assumption.
// ─────────────────────────────────────────────────────────────────────────────
test(`room switching: the backgrounded room grows an unread badge and opening it clears the badge ${tags({ role: 'ROLE_USER', layer: 'ui' })}`,
  async ({ browser }) => {
    test.setTimeout(240_000); // two full onboardings + a two-room chat shell
    // Two-party, so the current roster covers it. requirePlatformPersonas throws
    // a named roster error rather than dying on `undefined.username` if it ever
    // shrinks below two.
    const [alice, bob] = await onboardMany(browser, requirePlatformPersonas('ROLE_MATRIX', 2));

    // Two private rooms, both alice's, both inviting bob; bob accepts each
    // (the hsproxy join — the UI accept path is already proven above).
    const roomA = await createRoom(alice.page, bob.userId, 'e2e switch room a', { preset: 'private_chat' });
    const roomB = await createRoom(alice.page, bob.userId, 'e2e switch room b', { preset: 'private_chat' });
    await joinRoom(bob.page, roomA);
    await joinRoom(bob.page, roomB);

    // Bob parks in room A. Both rooms list; NEITHER carries a badge yet (the
    // baseline that makes the later badge meaningful).
    await bob.page.goto(`/social/matrix?room=${encodeURIComponent(roomA)}`);
    await expect(bob.page.getByTestId(`room-item-${roomA}`)).toBeVisible();
    await expect(bob.page.getByTestId(`room-item-${roomB}`)).toBeVisible();
    await expect(bob.page.getByTestId(`room-unread-${roomB}`)).toHaveCount(0);

    // Alice posts into room B while bob is still viewing room A…
    await sendMessage(alice.page, roomB, 'ping into room b while bob reads room a');

    // …and B's row grows an unread badge with a positive count (bob's sync
    // loop folds the homeserver's unread_notifications into the room rows).
    const badge = bob.page.getByTestId(`room-unread-${roomB}`);
    await expect(badge).toBeVisible();
    await expect(badge).toHaveText(/^[1-9]\d*$/);
    await shot(bob.page, '31-unread-badge-on-room-b');

    // Clicking through to room B shows the message AND clears the badge
    // (selection zeroes it in the UI; bob's read receipt keeps it zero
    // server-side on every later sync).
    await bob.page.getByTestId(`room-item-${roomB}`).click();
    // The room row is an <a> whose absolute ['/rooms', id] routerLink the HOST
    // cannot route — today that navigation errors in place and only the row's
    // (click) selection fires. Pin that assumption: if the host ever grows a
    // /rooms (or wildcard) route, fail HERE with a precise reason instead of a
    // mysterious matrix-log timeout after the page navigated away.
    await expect(bob.page, 'room-item click must stay on /social/matrix (host must not route the row’s absolute /rooms link)').toHaveURL(/\/social\/matrix/);
    await expect(bob.page.getByTestId('matrix-log')).toContainText('ping into room b while bob reads room a');
    await expect(badge).toHaveCount(0);
    await shot(bob.page, '31-unread-badge-cleared');

    await alice.ctx.close();
    await bob.ctx.close();
  });
