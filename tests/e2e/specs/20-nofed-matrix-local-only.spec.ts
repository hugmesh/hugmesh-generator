import { test, expect } from '@playwright/test';
import { systemsUser } from './rbac-roles';
import { federationSkipReason } from './federation';

// 20 — NON-FEDERATION PROOF (Matrix/tuwunel): a domain-locked Matrix user cannot
// federate a room/event to a remote server.
//
// Subject:  e2e-matrix-domainlocked (ROLE_MATRIX + ROLE_MATRIX_DOMAINLOCKED).
// Enforcement leg: for Matrix there is NO per-user federation control in
//   tuwunel/Conduit (only server-wide allow/deny + per-room m.federate at create).
//   So the AUTHORITATIVE non-federation control for Matrix is the EGRESS backstop
//   (manifests/networkpolicy/homeserver-egress.yaml + the squid egress-proxy
//   allowlist) — see docs/DOMAIN-LOCK.md. The proof is therefore at the egress
//   boundary: a domain-locked user's attempt to create/join a room on a REMOTE
//   server, or invite a remote user, must FAIL to leave the cluster (the homeserver
//   gets no direct internet egress and the proxy allowlist excludes the target).
//
// The remote vantage point is the same TEST-ONLY peer (a remote Matrix/well-known
// the locked user would try to reach). Because the Matrix peer + the egress gate
// are heavy/x86 + dark-by-default, this RUNS only when the gate is on and the peer
// is present; otherwise it SKIPS with a precise reason (never a fake pass). The
// positive control (a NON-locked Matrix user DOES reach the remote) is spec 22.

const SUBJECT = systemsUser('e2e-matrix-domainlocked');

test.describe('non-federation: Matrix domain-locked room/event stays local', () => {
  test('a domain-locked user cannot federate a room to a remote server', async ({ request }) => {
    const reason = federationSkipReason();
    test.skip(reason !== '', reason);

    const subjectToken = process.env['SNAP_MATRIX_TOKEN_E2E_MATRIX_DOMAINLOCKED'] ?? '';
    test.skip(!subjectToken, 'subject Matrix token not provisioned for this run');

    const matrixBase =
      process.env['SNAP_MATRIX_BASE'] ??
      'http://tuwunel.snapdragon-backend.svc.cluster.local:6167';
    const remoteServer = process.env['SNAP_MATRIX_REMOTE_SERVER'] ?? 'peer.test';

    // Attempt to JOIN a room hosted on the REMOTE server by alias. With the egress
    // backstop in force, the homeserver cannot reach peer.test, so the join must
    // FAIL (a 5xx/timeout/M_UNKNOWN from the local server's failed federation),
    // NOT a 200. We assert the request does NOT succeed.
    const remoteAlias = `%23nofed-probe:${remoteServer}`; // #nofed-probe:peer.test
    const join = await request.post(
      `${matrixBase}/_matrix/client/v3/join/${remoteAlias}`,
      { headers: { authorization: `Bearer ${subjectToken}` }, data: {}, failOnStatusCode: false },
    );
    expect(
      join.ok(),
      `domain-locked user MUST NOT join a room on remote server ${remoteServer} (egress backstop blocks federation)`,
    ).toBe(false);

    // And inviting a remote user must likewise not federate an invite out. We
    // create a LOCAL room (allowed — full local access) and assert the remote
    // invite is rejected/never delivered.
    const create = await request.post(`${matrixBase}/_matrix/client/v3/createRoom`, {
      headers: { authorization: `Bearer ${subjectToken}` },
      data: { name: 'local-only room', preset: 'private_chat' },
      failOnStatusCode: false,
    });
    expect(create.ok(), 'creating a LOCAL room is allowed (local access preserved)').toBeTruthy();
    const roomId = (await create.json()).room_id;
    const invite = await request.post(
      `${matrixBase}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/invite`,
      {
        headers: { authorization: `Bearer ${subjectToken}` },
        data: { user_id: `@probe:${remoteServer}` },
        failOnStatusCode: false,
      },
    );
    expect(
      invite.ok(),
      `domain-locked user MUST NOT federate an invite to @probe:${remoteServer}`,
    ).toBe(false);
  });
});
