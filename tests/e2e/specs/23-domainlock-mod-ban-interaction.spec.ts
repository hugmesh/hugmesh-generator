import { test, expect } from '@playwright/test';
import { systemsUser } from './rbac-roles';
import { tags } from './report-tags';
import {
  PEER_BASE, LOCAL_MASTODON, federationSkipReason,
  postLocalStatus, peerFollow, peerSawStatus, expectPeerNeverSaw, marker,
} from './federation';

// 23 — DOMAIN-LOCK × MOD-BAN INTERACTION: the two moderation states are
// INDEPENDENT axes and must compose without leaking.
//
//   * domain-lock = PRESENCE of ROLE_MASTODON_DOMAINLOCKED (additive marker,
//     access role KEPT — full local access, no federation). docs/DOMAIN-LOCK.md.
//   * ban         = access_suspension (the ABSENCE/withdrawal of access) —
//     enacted by a MOD via the mod-bff ban surface (POST/DELETE /bff/mod/ban).
//
// The gap this closes (the matrix doc's domainlock row only proves the lock
// alone): when a domain-locked user is BANNED by a mod,
//   (1) the ban applies LOCALLY — the target's post attempt is REJECTED on the
//       local instance (a real effect, not just a 2xx envelope from the bff);
//   (2) NOTHING about the ban federates to the peer — the peer's stored view of
//       the subject never changes (no suspension state, no new activity);
//   (3) after the ban is LIFTED the user posts locally again BUT still cannot
//       federate — the domain-lock persists independently of the ban lifecycle.
//
// Subject:  e2e-mastodon-domainlocked (ROLE_MASTODON + ROLE_MASTODON_DOMAINLOCKED)
// Actor:    e2e-mod via the mod-bff ban endpoint THROUGH the be-gateway (the same
//           enforcement path spec 24 probes). NB the Mastodon/akkoma ban leg is
//           WIRED to the pleroma-admin verbs; on a mainline-Mastodon stack those
//           404 and the bff returns an honest DEGRADED envelope — which is why
//           this spec is gated to the akkoma cluster run and never asserts a
//           fake success where the leg cannot apply.
// Observer: the TEST-ONLY akkoma-peer, which FOLLOWS the subject so any leak
//           WOULD be observable. Positive control (federation pipe alive) is
//           spec 22 — without it green negatives here prove nothing.
//
// Honesty: skips with a precise reason when the peer is absent, the domain-lock
// gate is dark, or the run did not provision the subject/peer/mod tokens. It
// NEVER fakes a pass. Same skip-guard idiom as specs 19–22.

const SUBJECT = systemsUser('e2e-mastodon-domainlocked');

const BE = process.env['SNAP_BE_GATEWAY']
  ?? 'https://hugmesh-be-gateway.hugmesh-backend.svc.cluster.local:8443';

/** The bounded window a negative peer observation is watched for — the same
 *  clock the spec-22 positive control is observed under (its delivery lands
 *  well inside 30s), so "never seen in the window" is meaningful. */
const NEGATIVE_WINDOW_MS = 30_000;

test.describe('domain-lock × mod-ban: independent axes, no federation leak', () => {
  test(`a plain ROLE_USER is DENIED the mod ban surface (and the subject is unaffected) ${tags({ role: 'ROLE_USER', layer: 'bff' })}`, async ({ request }) => {
    const reason = federationSkipReason();
    test.skip(reason !== '', reason);
    const subjectToken = process.env['SNAP_MASTODON_TOKEN_E2E_MASTODON_DOMAINLOCKED'] ?? '';
    const userJwt = process.env['SNAP_CASDOOR_JWT_E2E_USER'] ?? '';
    test.skip(!subjectToken || !userJwt, 'subject Mastodon token / e2e-user Casdoor JWT not provisioned for this run');

    // DENY half of the ban pair: a plain user's ban attempt is refused outright…
    const denied = await request.post(`${BE}/bff/mod/ban`, {
      headers: { authorization: `Bearer ${userJwt}` },
      data: { platform: 'mastodon', target: SUBJECT.username, reason: 'rbac-deny-probe' },
      failOnStatusCode: false,
    });
    expect(
      [401, 403].includes(denied.status()),
      `ROLE_USER must be DENIED POST /bff/mod/ban, got ${denied.status()}`,
    ).toBe(true);

    // …and it had NO effect: the subject still posts locally (real absence-of-
    // effect, not just the status code).
    const needle = marker('deny-noop');
    await postLocalStatus(request, subjectToken, `still posting ${needle}`, 'public');
  });

  test(`domain-locked user banned by mod: local ban, no federated state, lock survives the lift ${tags({ role: 'ROLE_MOD', layer: 'homeserver' })}`, async ({ request }) => {
    const reason = federationSkipReason();
    test.skip(reason !== '', reason);

    // Tokens come from the seed (seed-accounts.sh --roles writes the test-seed
    // Secret; the live runner injects SNAP_MASTODON_TOKEN_<user> + SNAP_PEER_TOKEN
    // + the mod's Casdoor JWT for the mod-bff leg).
    const subjectToken = process.env['SNAP_MASTODON_TOKEN_E2E_MASTODON_DOMAINLOCKED'] ?? '';
    const peerToken = process.env['SNAP_PEER_TOKEN'] ?? '';
    const modJwt = process.env['SNAP_CASDOOR_JWT_E2E_MOD'] ?? '';
    test.skip(!subjectToken || !peerToken || !modJwt,
      'subject/peer Mastodon tokens or e2e-mod Casdoor JWT not provisioned for this run');

    const subjectAcct = `${SUBJECT.username}@mastodon.hugmesh.net`;

    // ── Phase 0: the peer follows the subject, so any leak WOULD deliver here. ──
    const followed = await peerFollow(request, peerToken, subjectAcct);
    expect(followed, 'peer must be able to FOLLOW the local subject (federation reachability)').toBeTruthy();

    // ── Phase 1 (pre-ban baseline): full LOCAL access, zero federation. ──
    const markA = marker('preban');
    await postLocalStatus(request, subjectToken, `pre-ban local post ${markA}`, 'public');
    const localTl = await request.get(`${LOCAL_MASTODON}/api/v1/timelines/public`, {
      headers: { authorization: `Bearer ${subjectToken}` },
      params: { local: 'true', limit: '40' },
    });
    expect(localTl.ok()).toBeTruthy();
    expect(JSON.stringify(await localTl.json()), 'the pre-ban post is visible LOCALLY').toContain(markA);
    await expectPeerNeverSaw(request, peerToken, subjectAcct, markA, NEGATIVE_WINDOW_MS);

    // ── Phase 2: the mod BANS the subject (mastodon platform) via the mod-bff. ──
    const banReason = marker('modban');
    const ban = await request.post(`${BE}/bff/mod/ban`, {
      headers: { authorization: `Bearer ${modJwt}` },
      data: { platform: 'mastodon', target: SUBJECT.username, reason: banReason },
      failOnStatusCode: false,
    });
    expect(ban.ok(), `mod ban must be ACCEPTED by the mod-bff (got ${ban.status()})`).toBeTruthy();

    // ── Phase 3: the ban is applied LOCALLY — the target's post attempt is
    //     REJECTED on the local instance. The bff 2xx alone is NOT the oracle;
    //     the enforced effect at the homeserver layer is. Bounded expect.poll —
    //     never a bare sleep. ──
    const markB = marker('banned');
    await expect
      .poll(async () => {
        const r = await request.post(`${LOCAL_MASTODON}/api/v1/statuses`, {
          headers: { authorization: `Bearer ${subjectToken}` },
          data: { status: `post while banned ${markB}`, visibility: 'public' },
          failOnStatusCode: false,
        });
        return r.ok();
      }, {
        message: 'the banned subject\'s LOCAL post attempt must become REJECTED (deactivation applied at the homeserver)',
        timeout: 30_000,
        intervals: [1_000, 2_000, 5_000],
      })
      .toBe(false);

    // ── Phase 4: NOTHING about the ban federates to the peer. ──
    // (a) the peer's stored view of the subject account carries no suspension.
    const search = await request.get(`${PEER_BASE}/api/v2/search`, {
      headers: { authorization: `Bearer ${peerToken}` },
      params: { q: subjectAcct, resolve: 'false', type: 'accounts' },
    });
    expect(search.ok()).toBeTruthy();
    const peerAccounts = (await search.json()).accounts ?? [];
    expect(peerAccounts.length, 'the peer already knows the subject (it follows it)').toBeGreaterThan(0);
    expect(
      peerAccounts[0].suspended === true,
      'the LOCAL ban must NOT surface as a suspension on the peer\'s stored account',
    ).toBe(false);
    // (b) no ban-window activity reaches the peer either (full-window watch).
    await expectPeerNeverSaw(request, peerToken, subjectAcct, markB, NEGATIVE_WINDOW_MS);

    // ── Phase 5: the mod LIFTS the ban; local posting recovers. ──
    const lift = await request.delete(`${BE}/bff/mod/ban`, {
      headers: { authorization: `Bearer ${modJwt}` },
      data: { platform: 'mastodon', target: SUBJECT.username, reason: banReason },
      failOnStatusCode: false,
    });
    expect(lift.ok(), `ban lift must be ACCEPTED by the mod-bff (got ${lift.status()})`).toBeTruthy();

    const markC = marker('postlift');
    await expect
      .poll(async () => {
        const r = await request.post(`${LOCAL_MASTODON}/api/v1/statuses`, {
          headers: { authorization: `Bearer ${subjectToken}` },
          data: { status: `post-lift local post ${markC}`, visibility: 'public' },
          failOnStatusCode: false,
        });
        return r.ok();
      }, {
        message: 'after the ban lift the subject must be able to post LOCALLY again',
        timeout: 30_000,
        intervals: [1_000, 2_000, 5_000],
      })
      .toBe(true);

    // ── Phase 6: the DOMAIN-LOCK persisted through the ban lifecycle — the
    //     recovered local post still MUST NOT federate. Positive control that
    //     the pipe is alive at all remains spec 22 (the clock). ──
    const reached = await peerSawStatus(request, peerToken, subjectAcct, markC, NEGATIVE_WINDOW_MS);
    expect(
      reached,
      `post-lift toot ${markC} MUST NOT reach the peer ${PEER_BASE} — the domain-lock is independent of the ban`,
    ).toBe(false);
  });
});
