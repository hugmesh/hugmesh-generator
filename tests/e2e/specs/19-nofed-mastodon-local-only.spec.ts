import { test, expect } from '@playwright/test';
import { systemsUser, passwordFor } from './rbac-roles';
import {
  PEER_BASE, LOCAL_MASTODON, federationSkipReason,
  postLocalStatus, peerFollow, peerSawStatus, marker,
} from './federation';

// 19 — NON-FEDERATION PROOF (Mastodon/akkoma): a domain-locked user's RAW-API
// public toot must NOT reach the remote peer.
//
// Subject:  e2e-mastodon-domainlocked (ROLE_MASTODON + ROLE_MASTODON_DOMAINLOCKED)
// Observer: the TEST-ONLY akkoma-peer (peer.test), which FOLLOWS the subject so a
//           non-locked user's public post WOULD be delivered to it. The custom
//           akkoma ForceLocalForUsers MRF filters every outbound delivery for a
//           force-local actor to LOCAL inboxes only — so even a visibility=public
//           toot posted via the RAW Mastodon API (bypassing any UI scoping) must
//           never appear on the peer. The positive control (a NON-locked user DOES
//           land on the peer) is spec 22 — without it this proves nothing.
//
// Honesty: skips with a precise reason when the peer is absent (lean run) or the
// domain-lock gate is dark (SNAP_DOMAINLOCK_ENABLED!=1). It NEVER fakes a pass.

const SUBJECT = systemsUser('e2e-mastodon-domainlocked');

test.describe('non-federation: Mastodon domain-locked toot stays local', () => {
  test('a domain-locked public toot does NOT reach the remote peer', async ({ request }) => {
    const reason = federationSkipReason();
    test.skip(reason !== '', reason);

    // Tokens come from the seed (seed-accounts.sh --roles writes the test-seed
    // Secret; the live runner injects SNAP_MASTODON_TOKEN_<user> + SNAP_PEER_TOKEN).
    const subjectToken = process.env['SNAP_MASTODON_TOKEN_E2E_MASTODON_DOMAINLOCKED'] ?? '';
    const peerToken = process.env['SNAP_PEER_TOKEN'] ?? '';
    test.skip(!subjectToken || !peerToken, 'subject/peer Mastodon tokens not provisioned for this run');

    const subjectAcct = `${SUBJECT.username}@mastodon.snapdragon.systems`;

    // The peer follows the subject, so a NON-locked user would federate here.
    const followed = await peerFollow(request, peerToken, subjectAcct);
    expect(followed, 'peer must be able to FOLLOW the local subject (federation reachability)').toBeTruthy();

    // Post a RAW-API public toot as the domain-locked subject.
    const needle = marker('mastodon-locked');
    await postLocalStatus(request, subjectToken, `public toot ${needle}`, 'public');

    // It MUST appear on the LOCAL instance (full local access is preserved)…
    const localTl = await request.get(`${LOCAL_MASTODON}/api/v1/timelines/public`, {
      headers: { authorization: `Bearer ${subjectToken}` },
      params: { local: 'true', limit: '40' },
    });
    expect(localTl.ok()).toBeTruthy();
    expect(JSON.stringify(await localTl.json()), 'the toot is visible LOCALLY').toContain(needle);

    // …and MUST NOT appear on the remote peer (the whole point).
    const reached = await peerSawStatus(request, peerToken, subjectAcct, needle, 30_000);
    expect(reached, `domain-locked toot ${needle} MUST NOT reach the remote peer ${PEER_BASE}`).toBe(false);
  });
});
