// social-functions.steps.ts — the step vocabulary for the FUNCTION axis of the
// three social services, in two tiers.
//
//   CONTRACT tier   offline, stack down. Every (persona x function) cell is
//                   decided twice — once by the hand-declared catalogue in
//                   steps/social-functions.ts, once by the DEPLOYED route-access
//                   seed — and the two must agree. This is the tier that has
//                   value today, exactly as the 256 currently-passing scenarios
//                   do; it needs no mesh and no browser.
//
//   JOURNEY tier    @env:docker. The INTERACTIONS themselves, driven as two
//                   cookie-separated signed-in identities: A boosts B's post, B
//                   replies to A, A redacts a message B can see, B leaves the
//                   room A created. These skip loudly (with the start command)
//                   when no compose stack answers, which is the G-DIM contract.
//
// WHY THE JOURNEY STEPS USE THE hsproxy AND NOT THE UI. specs/helpers.ts already
// drives mastodonFollow / createRoom / inviteToRoom that way: the browser holds
// NO homeserver token, auth is the httpOnly bff_session cookie, and the server
// injects the real credential. So an API call issued from `page.request` is the
// SAME custody model the UI uses — not a back door around it. Where a pinned UI
// test id exists (the composer, the log) the existing UI steps are reused
// instead; a boost button nobody has pinned would have to be invented, and an
// invented test id is a scenario that can never pass.

import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

import { Given, When, Then, requireDimension } from './world';
import { persona } from './dimensions';
import { peer, signInPeers } from './social-peers';
import { matrixUserId, mastodonAccountId } from '../specs/helpers';
import { ROOM } from './matrix.steps';
import {
  SOCIAL_FUNCTIONS, SOCIAL_SERVICES, socialFunction, socialFunctions, socialServiceIds,
  socialRoster, rosterPersona, disagreements, renderDisagreements, personasWhoCan,
  featureSources, tokenIsExercised, journeyExists, seedVerdict,
} from './social-functions';
import { accessRows } from './uncovered-services.steps';
import { ROUTE_ACCESS } from '../specs/rbac-route-access';

/** The same-origin user-bff hsproxy prefixes helpers.ts drives (module-private
 *  there). Spelled once here for the API-tier interaction steps. */
const MATRIX_HS = '/bff/user/matrix';
const MASTODON_HS = '/bff/user/mastodon';

// ═══ CONTRACT TIER ═══════════════════════════════════════════════════════════

/**
 * ONE function, THE WHOLE ROSTER. This is the row that makes the coverage
 * generative on the persona axis: adding a persona to either seeder widens
 * every function row in the suite with no feature-file edit at all.
 */
Then(
  'the route-access seed gates the {string} function of the service dimension for every seeded persona',
  async ({ dimensions }, functionId: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = socialFunction(serviceId, functionId);
    const roster = socialRoster();
    expect(
      roster.length,
      'the seeded roster is empty, so this scenario would check nothing',
    ).toBeGreaterThan(0);
    const bad = disagreements([fn], roster);
    expect(
      bad,
      `the FUNCTION catalogue and the DEPLOYED route-access seed disagree about who may `
      + `'${fn.name}' (${fn.service}/${fn.id}) on ${fn.gateway} at ${fn.probePath}:\n`
      + `${renderDisagreements(bad)}\n`
      + `  Two independent sources: steps/social-functions.ts declares the gate, `
      + `specs/cluster/manifests/route-access/initdb/20-schema.sql deploys it. Fix whichever `
      + `one is wrong — never the assertion.`,
    ).toEqual([]);
  },
);

/**
 * The ARITY pin. The Examples table states, in the feature file, how many
 * DISTINCT identities the function needs to mean anything; the catalogue states
 * it too. A function silently downgraded from 'pair' to 'solo' is how an
 * interaction stops being an interaction and becomes a single page asserting
 * against itself — the exact failure two-party-chat.feature's header warns about.
 */
Then(
  'the {string} function of the service dimension is a {string} interaction',
  async ({ dimensions }, functionId: string, arity: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = socialFunction(serviceId, functionId);
    expect(
      ['solo', 'pair', 'group'],
      `'${arity}' is not a legal arity. Legal: solo, pair, group.`,
    ).toContain(arity);
    expect(
      fn.arity,
      `the feature file says ${fn.service}/${fn.id} is a '${arity}' interaction and the catalogue `
      + `says '${fn.arity}'. A 'pair' or 'group' function needs TWO OR THREE cookie-separated `
      + `identities; downgrading one to 'solo' turns "my peer sees it" into a page asserting `
      + `against itself, which looks identical in the report and proves nothing.`,
    ).toBe(arity);
  },
);

/**
 * ONE persona, THE WHOLE CATALOGUE, across every social service. The mirror
 * image of the step above: adding a FUNCTION widens every persona row with no
 * feature-file edit. Between the two, every cell of the matrix is asserted from
 * both directions.
 */
Then(
  'every catalogued social function is decided for this persona exactly as the catalogue declares',
  async ({ dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const me = rosterPersona(handle);
    expect(
      SOCIAL_FUNCTIONS.length,
      'the social function catalogue is empty, so this scenario would check nothing',
    ).toBeGreaterThan(0);
    const bad = disagreements(SOCIAL_FUNCTIONS, [me]);
    expect(
      bad,
      `persona '${handle}' (roles: ${me.roles.join(', ') || '<none>'}, seeded by ${me.source}) is `
      + `decided differently by the catalogue and by the deployed route-access seed:\n`
      + `${renderDisagreements(bad)}`,
    ).toEqual([]);
  },
);

// ═══ THE DRIFT GUARD — the real deliverable ══════════════════════════════════
//
// Everything above is OUTPUT. These are the scenarios that go red when the
// catalogue, the roster or the Gherkin tree stop describing each other, which is
// what stops this lane rotting into a directory of English prose the moment a
// service grows a feature nobody adds a row for.

Then('every catalogued social function is named by an executable scenario', async () => {
  const sources = featureSources();
  const orphans: string[] = [];
  for (const fn of SOCIAL_FUNCTIONS) {
    if (tokenIsExercised(fn.id, sources).length === 0) {
      orphans.push(`  ${fn.service}/${fn.id} — '${fn.name}'`);
    }
  }
  expect(
    orphans,
    `these catalogued functions appear in NO executable Gherkin (comment lines are stripped `
    + `before the search, so a mention in prose does not count):\n${orphans.join('\n')}\n`
    + `  Add an Examples row naming the id, or delete the catalogue entry. A function in the `
    + `catalogue with no scenario is the decorative coverage this lane exists to prevent.`,
  ).toEqual([]);
});

Then('every seeded persona is named by the social function matrix', async () => {
  const sources = featureSources();
  const missing: string[] = [];
  for (const p of socialRoster()) {
    if (tokenIsExercised(p.handle, sources).length === 0) {
      missing.push(`  ${p.handle} (seeded by ${p.source}; roles ${p.roles.join(', ') || '<none>'})`);
    }
  }
  expect(
    missing,
    `these seeded personas are named by NO executable Gherkin:\n${missing.join('\n')}\n`
    + `  A persona nothing drives is a persona whose access nobody checks. Add it to the `
    + `Examples table of features/platform/social-function-matrix.feature — one row is enough, `
    + `the step then sweeps every catalogued function for it.`,
  ).toEqual([]);
});

Then('every multi-party social function names a driven journey or a written reason', async () => {
  const bad: string[] = [];
  for (const fn of SOCIAL_FUNCTIONS) {
    if (fn.arity === 'solo') continue;
    if (fn.journey === null && (fn.pending === null || fn.pending.trim() === '')) {
      bad.push(`  ${fn.service}/${fn.id} — '${fn.name}' is a ${fn.arity} interaction with `
        + `neither a journey nor a reason`);
      continue;
    }
    if (fn.journey !== null && !journeyExists(fn.journey)) {
      bad.push(`  ${fn.service}/${fn.id} names journey '${fn.journey}', which is not on disk`);
    }
  }
  expect(
    bad,
    `the INTERACTIONS half of this catalogue has holes:\n${bad.join('\n')}\n`
    + `  Every pair/group function must either name a .feature that drives it, or say in one `
    + `sentence why it is not driven yet. A silent gap is how "all interactions" becomes a claim `
    + `nobody can check.`,
  ).toEqual([]);
});

Then('every catalogued social function is reachable by a seeded persona or declares the gap', async () => {
  const bad: string[] = [];
  for (const fn of SOCIAL_FUNCTIONS) {
    const who = personasWhoCan(fn);
    if (fn.expectNoPersona) {
      // The tripwire direction: this is a KNOWN roster gap, and the day it
      // CLOSES this scenario fails, which is the prompt to write the journey.
      if (who.length > 0) {
        bad.push(`  ${fn.service}/${fn.id} declares expectNoPersona, but ${who.length} persona(s) `
          + `now reach it (${who.map((p) => p.handle).join(', ')}). The gap CLOSED — drop `
          + `expectNoPersona and write the journey. Reason recorded when it was open: ${fn.pending}`);
      }
      continue;
    }
    if (fn.gate.kind === 'rowless') continue;   // rowless is unreachable BY DESIGN
    if (who.length === 0) {
      bad.push(`  ${fn.service}/${fn.id} — '${fn.name}' is reachable by NOBODY in either roster. `
        + `Either seed a persona that holds ${JSON.stringify(fn.gate)}, or mark the entry `
        + `expectNoPersona with the reason, so the gap is visible instead of silent.`);
    }
  }
  expect(bad, `${bad.join('\n')}`).toEqual([]);
});

Then('every social service the catalogue covers carries at least one function', async () => {
  const empty = socialServiceIds().filter((id) => socialFunctions(id).length === 0);
  expect(
    empty,
    `these social services have NO catalogued function: ${empty.join(', ')}. A service in `
    + `SOCIAL_SERVICES with an empty function list makes every sweep vacuously green for it.`,
  ).toEqual([]);
  expect(SOCIAL_SERVICES.length, 'SOCIAL_SERVICES is empty').toBeGreaterThan(0);
});

/**
 * WHY THIS CATALOGUE READS THE SQL, AND WHY THAT IS NOW THE SAME TABLE THE 33
 * HANDWRITTEN SPECS READ.
 *
 * There used to be two route-access oracles: a hand-copied TypeScript mirror
 * (50 rows) and the SQL the cluster seeds (150). This step pinned the GAP — the
 * mirror lags, and must never contradict.
 *
 * The gap CLOSED on 2026-08-26: specs/rbac-route-access.ts now re-exports
 * specs/rbac-route-access.seed.ts, GENERATED by scripts/gen-route-access-oracle.py
 * from specs/cluster/manifests/route-access/initdb/20-schema.sql. The subset
 * assertion did not become redundant, it became FALSE — and its own failure
 * message said what to do about it. MEASURED on this tree: 152 seed rows, 152
 * mirror rows, ZERO rows beyond the mirror, and 4 rows the subset test called
 * contradictions because it never modelled `allow` (they are the seed's explicit
 * DENY rows, which the generated mirror carries).
 *
 * What is asserted instead is the relationship that now holds, in BOTH
 * directions and carrying allow/deny: the two tables are the same set of
 * (gateway, pattern, role, allow) rows. tests/scripts/test-route-access-oracle.sh
 * gates the GENERATOR; this gates the CONSUMER, so a stale checked-in mirror
 * cannot make this matrix decide against a table the cluster does not seed.
 *
 * NOT VACUOUS: both sides are asserted non-empty first, so an oracle that parsed
 * to nothing fails here rather than agreeing with an empty seed.
 */
Then('the route-access mirror the handwritten specs use agrees with the deployed seed exactly', async () => {
  const seed = accessRows();
  expect(seed.length, 'the route-access seed parsed to ZERO rows — every comparison below '
    + 'would be vacuous').toBeGreaterThan(0);
  expect(ROUTE_ACCESS.length, 'the TypeScript route-access mirror carries ZERO rows — every '
    + 'comparison below would be vacuous').toBeGreaterThan(0);
  // The seed spells the public tier 'PUBLIC'; the mirror also accepts ROLE_ANONYMOUS.
  const norm = (r: string): string => (r === 'ROLE_ANONYMOUS' ? 'PUBLIC' : r);
  const key = (g: string, p: string, r: string, a: boolean): string =>
    `  ${g}  ${p}  ${r}  ${a ? 'ALLOW' : 'DENY'}`;
  const seedKeys = new Set(seed.map((s) => key(s.gateway, s.pattern, norm(s.role), s.allow)));
  const mirrorKeys = new Set(ROUTE_ACCESS.map((m) => key(m.gateway, m.urlPattern, norm(m.role), m.allow)));
  const mirrorOnly = [...mirrorKeys].filter((k) => !seedKeys.has(k)).sort();
  const seedOnly = [...seedKeys].filter((k) => !mirrorKeys.has(k)).sort();
  expect(
    mirrorOnly,
    `specs/rbac-route-access.ts carries ${mirrorOnly.length} row(s) the DEPLOYED seed does not:\n`
    + `${mirrorOnly.join('\n')}\n`
    + `  The mirror is GENERATED from the seed — a row here means the checked-in oracle is `
    + `stale. Run: python3 scripts/gen-route-access-oracle.py`,
  ).toEqual([]);
  expect(
    seedOnly,
    `the DEPLOYED seed carries ${seedOnly.length} row(s) the TypeScript mirror does not:\n`
    + `${seedOnly.join('\n')}\n`
    + `  Same cause, same fix: python3 scripts/gen-route-access-oracle.py`,
  ).toEqual([]);
});

/**
 * The per-SERVICE sweep. Every function of the service this scenario names,
 * against every seeded persona, in one assertion — so a service whose per-row
 * scenarios were deleted still cannot report green.
 */
Then('every function of the service dimension agrees with the route-access seed for every seeded persona',
  async ({ dimensions }) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fns = socialFunctions(serviceId);
    const roster = socialRoster();
    expect(
      fns.length,
      `service '${serviceId}' has NO catalogued functions, so this sweep would check nothing.`,
    ).toBeGreaterThan(0);
    const bad = disagreements(fns, roster);
    expect(
      bad,
      `${bad.length} of ${fns.length * roster.length} (persona x function) cells disagree for `
      + `service '${serviceId}':\n${renderDisagreements(bad)}`,
    ).toEqual([]);
  },
);

/**
 * The belt-and-braces sweep: EVERY function x EVERY persona in one scenario, so
 * a run that somehow lost the per-row scenarios still cannot report green with a
 * broken matrix. The per-row scenarios exist for the REPORT (perRole/perService
 * pivot); this one exists for the PROOF.
 */
Then('the social function catalogue and the route-access seed agree on every cell', async () => {
  const roster = socialRoster();
  const cells = SOCIAL_FUNCTIONS.length * roster.length;
  expect(cells, 'the matrix has no cells').toBeGreaterThan(0);
  const bad = disagreements(SOCIAL_FUNCTIONS, roster);
  expect(
    bad,
    `${bad.length} of ${cells} (persona x function) cells disagree:\n${renderDisagreements(bad)}`,
  ).toEqual([]);
});

/** Report the size of what was swept, so a shrinking matrix is visible in the
 *  run output rather than only in a diff. */
Then('the social function matrix sweeps at least {int} personas and {int} functions', async (
  {}, minPersonas: number, minFunctions: number,
) => {
  const roster = socialRoster();
  expect(
    roster.length,
    `the seeded roster shrank to ${roster.length} personas (floor ${minPersonas}). A roster that `
    + `shrinks turns multi-party proofs into skips nobody reads — see `
    + `features/matrix/social-access-contract.feature.`,
  ).toBeGreaterThanOrEqual(minPersonas);
  expect(
    SOCIAL_FUNCTIONS.length,
    `the function catalogue shrank to ${SOCIAL_FUNCTIONS.length} entries (floor ${minFunctions}).`,
  ).toBeGreaterThanOrEqual(minFunctions);
});

/** The probe integrity check: a probePath that matches NO seed pattern would be
 *  decided DENY for everyone by default-deny, and its whole row would pass for
 *  the wrong reason. Only a `rowless` gate may legally match nothing. */
Then('every catalogued probe path resolves to a real route-access pattern', async () => {
  const bad: string[] = [];
  for (const fn of SOCIAL_FUNCTIONS) {
    const v = seedVerdict(fn.gateway, fn.probePath, []);
    if (fn.gate.kind === 'rowless') {
      if (v.pattern !== null) {
        bad.push(`  ${fn.service}/${fn.id} is declared ROWLESS but ${fn.probePath} now matches `
          + `'${v.pattern}' (granting ${v.grantedRoles.join(', ')}). A backend-only surface just `
          + `became governed — that is a posture change, not a typo.`);
      }
      continue;
    }
    if (v.pattern === null) {
      bad.push(`  ${fn.service}/${fn.id} probe ${fn.probePath} matches NO ${fn.gateway} pattern, `
        + `so it is default-denied for everyone and its row proves nothing.`);
    }
  }
  expect(bad, `${bad.join('\n')}`).toEqual([]);
});

// ═══ JOURNEY TIER — the interactions, driven ═════════════════════════════════
//
// All of these are @env:docker in the feature files: they need a live compose
// stack with SOCIAL=1 and a seeded roster, and they SKIP with the start command
// when nothing answers. None of them starts anything.

/** Fail with the persona named, rather than on `undefined.id` three lines later. */
async function hsJson(page: Page, url: string, what: string): Promise<any> {
  const r = await page.request.get(url);
  const text = await r.text();
  expect(r.ok(), `${what}: HTTP ${r.status()} from ${url}\n  body: ${text.slice(0, 400)}`).toBe(true);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${what} returned non-JSON from ${url}: ${text.slice(0, 400)}`);
  }
}

async function hsPost(page: Page, url: string, data: unknown, what: string): Promise<any> {
  const r = await page.request.post(url, data === undefined ? {} : { data });
  const text = await r.text();
  expect(r.ok(), `${what}: HTTP ${r.status()} from ${url}\n  body: ${text.slice(0, 400)}`).toBe(true);
  return text.length ? JSON.parse(text) : {};
}

// ── Mastodon interactions ────────────────────────────────────────────────────

const MY_STATUS_ID = 'social-fn-my-status-id';
const PEER_ACCOUNT = 'social-fn-peer-account-id';

/** My newest status, resolved server-side. Deliberately NOT "the status whose
 *  body I remember": the id is what every interaction below needs, and asking
 *  the server for it is the only way to get one after a UI composer post. */
async function myLatestStatusId(page: Page): Promise<string> {
  const me = await mastodonAccountId(page);
  const list = await hsJson(
    page, `${MASTODON_HS}/api/v1/accounts/${encodeURIComponent(me)}/statuses?limit=1`,
    'read my own statuses',
  );
  expect(
    Array.isArray(list) && list.length > 0,
    'the account has posted NO statuses, so there is nothing for a peer to interact with. The '
    + 'scenario must post before it boosts.',
  ).toBe(true);
  return String(list[0].id);
}

Given('my peer and I both hold Mastodon accounts', async ({ page, browser, world, dimensions, $testInfo }) => {
  $testInfo.setTimeout(240_000);
  const self = persona(requireDimension(dimensions, 'role'));
  await signInPeers(browser, world, 'akkoma', self, 1);
  await mastodonAccountId(page);
  world.set(PEER_ACCOUNT, await mastodonAccountId(peer(world, 0).page));
});

When('my peer boosts my latest Mastodon status', async ({ page, world }) => {
  const id = await myLatestStatusId(page);
  world.set(MY_STATUS_ID, id);
  await hsPost(peer(world, 0).page, `${MASTODON_HS}/api/v1/statuses/${encodeURIComponent(id)}/reblog`,
    undefined, `peer boosts status ${id}`);
});

When('my peer favourites my latest Mastodon status', async ({ page, world }) => {
  const id = world.has(MY_STATUS_ID) ? world.get<string>(MY_STATUS_ID) : await myLatestStatusId(page);
  world.set(MY_STATUS_ID, id);
  await hsPost(peer(world, 0).page, `${MASTODON_HS}/api/v1/statuses/${encodeURIComponent(id)}/favourite`,
    undefined, `peer favourites status ${id}`);
});

When('my peer replies {string} to my latest Mastodon status', async ({ page, world }, body: string) => {
  const id = world.has(MY_STATUS_ID) ? world.get<string>(MY_STATUS_ID) : await myLatestStatusId(page);
  world.set(MY_STATUS_ID, id);
  const stamped = `${body} ${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  world.set('social-fn-peer-reply', stamped);
  await hsPost(peer(world, 0).page, `${MASTODON_HS}/api/v1/statuses`,
    { status: stamped, in_reply_to_id: id }, `peer replies to status ${id}`);
});

/**
 * The RECEIVING end. Every interaction above is asserted on MY notifications,
 * never on the peer's own response — a 200 from the actor's own call says the
 * request was accepted, not that anything reached the other identity.
 */
Then('my Mastodon notifications include a {string} from my peer', async ({ page, world }, type: string) => {
  const legal = ['reblog', 'favourite', 'follow', 'mention'];
  expect(legal, `'${type}' is not a Mastodon notification type. Legal: ${legal.join(', ')}.`)
    .toContain(type);
  const peerAccount = world.get<string>(PEER_ACCOUNT);
  const notes = await hsJson(page, `${MASTODON_HS}/api/v1/notifications`, 'read my notifications');
  const mine = (notes as any[]).filter(
    (n) => n?.type === type && String(n?.account?.id) === String(peerAccount),
  );
  expect(
    mine.length,
    `no '${type}' notification from peer account ${peerAccount} reached me. `
    + `Notification types seen: ${[...new Set((notes as any[]).map((n) => `${n?.type}:${n?.account?.id}`))].join(', ') || '<none>'}. `
    + `A 200 on the peer's own call proves the request was accepted, not that it landed here.`,
  ).toBeGreaterThan(0);
});

Then('the local public Mastodon timeline carries my latest status', async ({ page, world }) => {
  const id = world.has(MY_STATUS_ID) ? world.get<string>(MY_STATUS_ID) : await myLatestStatusId(page);
  const tl = await hsJson(page, `${MASTODON_HS}/api/v1/timelines/public?local=true&limit=40`,
    'read the local public timeline');
  expect(
    (tl as any[]).map((s) => String(s.id)),
    `status ${id} is not on the LOCAL public timeline. The public timeline is follow-independent, `
    + `so an absence here is a posting problem, not a follow-graph problem — which is exactly why `
    + `this control sits beside the home-timeline assertion.`,
  ).toContain(String(id));
});

When('my peer unfollows me on Mastodon', async ({ page, world }) => {
  const me = await mastodonAccountId(page);
  await hsPost(peer(world, 0).page, `${MASTODON_HS}/api/v1/accounts/${encodeURIComponent(me)}/unfollow`,
    undefined, 'peer unfollows me');
});

Then('my peer no longer follows me on Mastodon', async ({ page, world }) => {
  const me = await mastodonAccountId(page);
  const rel = await hsJson(
    peer(world, 0).page,
    `${MASTODON_HS}/api/v1/accounts/relationships?id[]=${encodeURIComponent(me)}`,
    'read the peer -> me relationship',
  );
  expect(Array.isArray(rel) && rel.length === 1,
    `relationships returned ${JSON.stringify(rel).slice(0, 200)} instead of one row`).toBe(true);
  expect(
    rel[0].following,
    `the peer still follows me after unfollowing. The negative half of the follow graph is what `
    + `proves a follow is a real edge and not a no-op the timeline happened to satisfy.`,
  ).toBe(false);
});

// ── Matrix interactions ──────────────────────────────────────────────────────
//
// KNOWN PRODUCT BLOCKER, same as two-party-chat.feature: the room-scoped CS-API
// paths (/rooms/<id>/send, /redact, /state) go through the user-bff HsReverseProxy,
// which re-escapes the already-encoded '%' in the room id. Every step below that
// touches a room-scoped path fails today for that reason and NOT for a reason of
// its own. The assertions describe the contract they exist to prove.

const MY_EVENT = 'social-fn-my-event-id';

function roomOf(world: { get: <T>(k: string) => T }): string {
  return world.get<string>(ROOM);
}

function txn(): string {
  return `e2e-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

When('I send the Matrix message {string} through the client API', async ({ page, world }, body: string) => {
  const room = roomOf(world);
  const stamped = `${body} ${txn()}`;
  world.set('social-fn-my-body', stamped);
  const sent = await hsPost(
    page,
    `${MATRIX_HS}/_matrix/client/v3/rooms/${encodeURIComponent(room)}/send/m.room.message/${txn()}`,
    { msgtype: 'm.text', body: stamped },
    `send m.room.message into ${room}`,
  );
  expect(sent.event_id, `the send returned no event_id: ${JSON.stringify(sent).slice(0, 300)}`)
    .toBeTruthy();
  world.set(MY_EVENT, String(sent.event_id));
});

Then('my peer sees that Matrix message in the room timeline', async ({ world }) => {
  const room = roomOf(world);
  const body = world.get<string>('social-fn-my-body');
  const msgs = await hsJson(
    peer(world, 0).page,
    `${MATRIX_HS}/_matrix/client/v3/rooms/${encodeURIComponent(room)}/messages?dir=b&limit=50`,
    `read ${room} as my peer`,
  );
  const bodies = ((msgs?.chunk ?? []) as any[]).map((e) => e?.content?.body).filter(Boolean);
  expect(
    bodies,
    `my peer's copy of room ${room} does not carry the message I sent. Bodies seen: `
    + `${bodies.join(' | ') || '<none>'}`,
  ).toContain(body);
});

When('I redact that Matrix message', async ({ page, world }) => {
  const room = roomOf(world);
  const evt = world.get<string>(MY_EVENT);
  await hsPost(
    page,
    `${MATRIX_HS}/_matrix/client/v3/rooms/${encodeURIComponent(room)}`
    + `/redact/${encodeURIComponent(evt)}/${txn()}`,
    { reason: 'e2e redaction' },
    `redact ${evt} in ${room}`,
  );
});

Then('my peer no longer sees that Matrix message in the room timeline', async ({ world }) => {
  const room = roomOf(world);
  const body = world.get<string>('social-fn-my-body');
  const msgs = await hsJson(
    peer(world, 0).page,
    `${MATRIX_HS}/_matrix/client/v3/rooms/${encodeURIComponent(room)}/messages?dir=b&limit=50`,
    `re-read ${room} as my peer after the redaction`,
  );
  const bodies = ((msgs?.chunk ?? []) as any[]).map((e) => e?.content?.body).filter(Boolean);
  expect(
    bodies,
    `my peer still sees the redacted message. A redaction the AUTHOR sees applied but the peer `
    + `does not is the only version of this bug that matters.`,
  ).not.toContain(body);
});

When('I set my Matrix display name to {string}', async ({ page, world }, name: string) => {
  const mxid = await matrixUserId(page);
  const stamped = `${name} ${txn()}`;
  world.set('social-fn-my-displayname', stamped);
  const r = await page.request.put(
    `${MATRIX_HS}/_matrix/client/v3/profile/${encodeURIComponent(mxid)}/displayname`,
    { data: { displayname: stamped } },
  );
  expect(r.ok(), `set displayname: HTTP ${r.status()} — ${(await r.text()).slice(0, 300)}`).toBe(true);
});

Then('my peer sees my new Matrix display name', async ({ page, world }) => {
  const mxid = await matrixUserId(page);
  const want = world.get<string>('social-fn-my-displayname');
  const prof = await hsJson(
    peer(world, 0).page,
    `${MATRIX_HS}/_matrix/client/v3/profile/${encodeURIComponent(mxid)}`,
    `read ${mxid}'s profile as my peer`,
  );
  expect(
    prof.displayname,
    `my peer reads my display name as '${prof.displayname}'. A display name only I can see is a `
    + `local cache, not a profile.`,
  ).toBe(want);
});

When('my peer leaves our Matrix room', async ({ world }) => {
  const room = roomOf(world);
  await hsPost(peer(world, 0).page, `${MATRIX_HS}/_matrix/client/v3/rooms/${encodeURIComponent(room)}/leave`,
    undefined, `peer leaves ${room}`);
});

Then('the room shows my peer as {string}', async ({ page, world }, membership: string) => {
  const legal = ['join', 'leave', 'invite', 'ban'];
  expect(legal, `'${membership}' is not a Matrix membership. Legal: ${legal.join(', ')}.`)
    .toContain(membership);
  const room = roomOf(world);
  const peerMxid = await matrixUserId(peer(world, 0).page);
  const state = await hsJson(
    page,
    `${MATRIX_HS}/_matrix/client/v3/rooms/${encodeURIComponent(room)}`
    + `/state/m.room.member/${encodeURIComponent(peerMxid)}`,
    `read ${peerMxid}'s membership in ${room}`,
  );
  expect(
    state.membership,
    `the room records my peer as '${state.membership}', not '${membership}'. Membership is the `
    + `only observable a leave has — the leaver's own 200 says nothing about the room.`,
  ).toBe(membership);
});
