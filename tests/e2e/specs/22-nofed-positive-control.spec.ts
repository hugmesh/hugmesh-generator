import { test, expect } from '@playwright/test';
import { systemsUser } from './rbac-roles';
import {
  PEER_BASE, federationSkipReason,
  postLocalStatus, peerFollow, peerSawStatus, marker,
} from './federation';

// 22 — POSITIVE CONTROL (the clock): a NON-locked user DOES federate to the peer.
//
// Without this, specs 19/21 prove nothing — a post failing to reach the peer
// could just mean federation is broken, the peer is down, or the follow never
// took. This spec drives the SAME path (post on the local instance, observe the
// peer) with the NON-locked CONTROL user e2e-mastodon (ROLE_MASTODON, NO
// domainlocked role, federationControl:true in rbac-roles.ts) and asserts its
// public toot DOES appear on the peer. So:
//   spec 22 GREEN  + spec 19/21 GREEN  ⇒ federation works AND the lock enforces.
//   spec 22 RED                        ⇒ the harness/peer is broken; 19/21 are
//                                        inconclusive (fail-loud, never a silent
//                                        false-confidence pass).
//
// Same honest gating: the peer must be deployed. It does NOT require the
// domain-lock gate to be on (the control user federates regardless), but we keep
// the same skip-reason helper so a lean/no-peer run skips with a clear message.

const CONTROL = systemsUser('e2e-mastodon');

test.describe('non-federation positive control: a non-locked user DOES federate', () => {
  test('a non-locked public toot REACHES the remote peer (the clock)', async ({ request }) => {
    // Only the peer is strictly required for the control; if the whole
    // non-federation gate is off we still want the control to run when a peer
    // exists, so we skip ONLY on the missing-peer condition.
    test.skip(PEER_BASE === '', 'SNAP_FEDERATION_PEER unset (akkoma-peer not deployed — lean/no-x86 run)');
    void federationSkipReason; // referenced for symmetry with 19/21

    const controlToken = process.env['SNAP_MASTODON_TOKEN_E2E_MASTODON'] ?? '';
    const peerToken = process.env['SNAP_PEER_TOKEN'] ?? '';
    test.skip(!controlToken || !peerToken, 'control/peer Mastodon tokens not provisioned for this run');

    const controlAcct = `${CONTROL.username}@mastodon.hugmesh.systems`;

    const followed = await peerFollow(request, peerToken, controlAcct);
    expect(followed, 'peer must FOLLOW the control user (delivery target)').toBeTruthy();

    const needle = marker('control');
    await postLocalStatus(request, controlToken, `federating hello ${needle}`, 'public');

    const reached = await peerSawStatus(request, peerToken, controlAcct, needle, 45_000);
    expect(
      reached,
      `the NON-locked control toot ${needle} MUST reach the peer ${PEER_BASE} — if this fails, specs 19/21 are inconclusive`,
    ).toBe(true);
  });
});
