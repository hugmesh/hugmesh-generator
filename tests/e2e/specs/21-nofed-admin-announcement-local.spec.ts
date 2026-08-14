import { test, expect } from '@playwright/test';
import {
  PEER_BASE, federationSkipReason,
  postLocalStatus, peerFollow, peerSawStatus, marker,
} from './federation';

// 21 — NON-FEDERATION PROOF: an ADMIN announcement on a domain-locked instance
// stays local — even the privileged, instance-wide announcement path does not
// leak to the remote peer.
//
// The risk this closes: domain-lock is enforced per-ACTOR (the force-local set),
// but an admin "announcement"/broadcast or a server-pinned post could take a
// DIFFERENT delivery path than a normal user toot. If the whole instance is
// domain-locked (every local actor in the force-local set), the admin's own
// outbound announcement must ALSO be filtered to local inboxes only.
//
// Subject: the admin account (e2e-admin holds ROLE_ADMIN). When the instance-wide
// lock is on, the admin actor is force-local too; its announcement post must not
// reach the peer that follows it. Positive control remains spec 22 (a non-locked
// user/instance DOES deliver), so a green here is enforcement, not a dead pipe.
//
// Honest gating: SKIPs unless the peer is deployed AND the (instance-wide)
// domain-lock gate is on. NEVER fakes a pass.

test.describe('non-federation: admin announcement stays local', () => {
  test('an admin announcement on a domain-locked instance does NOT reach the peer', async ({ request }) => {
    const reason = federationSkipReason();
    test.skip(reason !== '', reason);
    // This variant additionally requires the INSTANCE-WIDE lock (every actor
    // force-local), distinct from a single-user lock. Flagged separately so a
    // per-user-only deployment skips honestly rather than false-failing.
    test.skip(
      process.env['SNAP_DOMAINLOCK_INSTANCE_WIDE'] !== '1',
      'SNAP_DOMAINLOCK_INSTANCE_WIDE!=1 (instance-wide lock not in force; admin announcement path not under test)',
    );

    const adminToken = process.env['SNAP_MASTODON_TOKEN_E2E_ADMIN'] ?? '';
    const peerToken = process.env['SNAP_PEER_TOKEN'] ?? '';
    test.skip(!adminToken || !peerToken, 'admin/peer Mastodon tokens not provisioned for this run');

    const adminAcct = `e2e-admin@mastodon.hugmesh.net`;

    // Peer follows the admin so a leak WOULD be observable.
    const followed = await peerFollow(request, peerToken, adminAcct);
    expect(followed, 'peer must follow the admin (so a leak would be observable)').toBeTruthy();

    // Admin posts an announcement-style public broadcast.
    const needle = marker('admin-announce');
    await postLocalStatus(request, adminToken, `📢 instance announcement ${needle}`, 'public');

    // It MUST NOT reach the peer.
    const reached = await peerSawStatus(request, peerToken, adminAcct, needle, 30_000);
    expect(reached, `admin announcement ${needle} MUST NOT reach the remote peer ${PEER_BASE}`).toBe(false);
  });
});
