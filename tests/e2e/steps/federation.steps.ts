// federation.steps.ts — the NON-FEDERATION (domain-lock) step vocabulary. Backs
// features/federation/mastodon-domain-lock.feature, matrix-domain-lock.feature and
// admin-announcement.feature: the executable form of specs 19/20/21/22.
//
// THE PROOF THESE ENCODE. A domain-locked actor's outbound activity MUST NOT reach
// a REMOTE peer, while a NON-locked CONTROL actor's activity MUST (the positive
// control / "the clock"). The observer is the TEST-ONLY akkoma-peer — a real,
// genuinely-federating ActivityPub instance on its own origin — so "no federation"
// is OBSERVED at the remote, not merely asserted at the source.
//
// Specs 19 and 22 are the SAME journey with opposite expectations, which is why
// the Gherkin expresses the federated/non-federated split as an EXAMPLES COLUMN
// rather than as two duplicated scenarios: one outline, one set of steps, and the
// two rows differ only in the persona and the outcome word.
//
// HONEST GATING, NEVER A FAKE PASS. Domain-lock enforcement (the akkoma
// ForceLocalForUsers MRF + the egress backstop) ships DARK, and the peer only
// exists in a heavy/x86 test cluster — so these scenarios SKIP with a precise,
// named reason when the peer is absent, the gate is off, or the API tokens were
// not provisioned. Every skip names its env var and its fix.

import { expect } from '@playwright/test';
import { Given, When, Then, requireDimension } from './world';
import { persona } from './dimensions';
import { systemsUser } from '../specs/rbac-roles';
import {
  PEER_BASE, LOCAL_MASTODON, federationSkipReason,
  postLocalStatus, peerFollow, peerSawStatus, expectPeerNeverSaw, marker,
} from '../specs/federation';

/** The Mastodon domain every seeded local actor lives on (specs 19/21/22). */
const LOCAL_MASTODON_DOMAIN = 'mastodon.hugmesh.net';

const SUBJECT_TOKEN = 'nofed-subject-token';
const PEER_TOKEN = 'nofed-peer-token';
const SUBJECT_ACCT = 'nofed-subject-acct';
const NEEDLE = 'nofed-needle';
const MATRIX_ROOM = 'nofed-local-room';
const LAST_RESPONSE_OK = 'nofed-last-response-ok';

/** seed-accounts.sh --roles writes the per-persona API token into the test-seed
 *  Secret under SNAP_<PLATFORM>_TOKEN_<HANDLE FOLDED TO UPPER SNAKE>; the live
 *  runner injects them. Derived rather than listed so a new persona needs no edit
 *  here (spec 19 hard-codes SNAP_MASTODON_TOKEN_E2E_MASTODON_DOMAINLOCKED, which
 *  is exactly this derivation spelled out). */
function tokenEnvName(platform: 'MASTODON' | 'MATRIX', handle: string): string {
  return `SNAP_${platform}_TOKEN_${handle.toUpperCase().replace(/[^A-Z0-9]/g, '_')}`;
}

function tokenFor(platform: 'MASTODON' | 'MATRIX', handle: string): { name: string; value: string } {
  const name = tokenEnvName(platform, handle);
  return { name, value: process.env[name] ?? '' };
}

/** True when the seed catalogue grants this persona a *_DOMAINLOCKED role — i.e.
 *  it is the SUBJECT of the non-federation proof rather than the control. */
function isDomainLocked(handle: string): boolean {
  return systemsUser(handle).roles.some((r) => r.endsWith('_DOMAINLOCKED'));
}

// ── gates ────────────────────────────────────────────────────────────────────

/**
 * The peer must exist for EITHER row to mean anything. The domain-lock GATE is
 * required only for the LOCKED subject: the control user federates whether or not
 * the MRF is switched on, and spec 22 deliberately runs on a peer-only lane so a
 * red control can still expose a broken harness.
 */
Given('the federation observer peer is deployed, and the domain-lock gate too when this persona is domain-locked',
  async ({ dimensions, $testInfo }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    if (isDomainLocked(handle)) {
      const reason = federationSkipReason();
      $testInfo.skip(reason !== '', reason);
    } else {
      $testInfo.skip(
        PEER_BASE === '',
        'SNAP_FEDERATION_PEER unset (akkoma-peer not deployed — lean/no-x86 run). The POSITIVE '
        + 'CONTROL needs only the peer, not the domain-lock gate: without it specs 19/21 are '
        + 'inconclusive, so it is skipped honestly rather than passed vacuously.',
      );
    }
  });

Given('the federation observer peer and the domain-lock gate are both live', async ({ $testInfo }) => {
  const reason = federationSkipReason();
  $testInfo.skip(reason !== '', reason);
});

/**
 * Spec 21's EXTRA requirement: the admin-announcement path is only under test when
 * EVERY local actor is force-local (the instance-wide lock), which is a different
 * deployment from a single-user lock. Flagged separately so a per-user-only
 * deployment skips honestly instead of false-failing.
 */
Given('the instance-wide domain lock is in force', async ({ $testInfo }) => {
  $testInfo.skip(
    process.env['SNAP_DOMAINLOCK_INSTANCE_WIDE'] !== '1',
    'SNAP_DOMAINLOCK_INSTANCE_WIDE!=1 (instance-wide lock not in force; the admin announcement '
    + 'path is not under test on this deployment)',
  );
});

// ── the Mastodon delivery journey (specs 19 / 21 / 22) ───────────────────────

Given('the remote peer follows the persona for this scenario', async ({ request, world, dimensions, $testInfo }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const subject = tokenFor('MASTODON', handle);
  const peerTok = { name: 'SNAP_PEER_TOKEN', value: process.env['SNAP_PEER_TOKEN'] ?? '' };
  $testInfo.skip(
    !subject.value || !peerTok.value,
    `Mastodon API tokens not provisioned for this run: ${subject.name}=`
    + `${subject.value ? 'set' : 'UNSET'}, ${peerTok.name}=${peerTok.value ? 'set' : 'UNSET'}. `
    + `seed-accounts.sh --roles writes them into the test-seed Secret; the live runner injects them.`,
  );
  world.set(SUBJECT_TOKEN, subject.value);
  world.set(PEER_TOKEN, peerTok.value);
  const acct = `${handle}@${LOCAL_MASTODON_DOMAIN}`;
  world.set(SUBJECT_ACCT, acct);

  // The peer FOLLOWS the subject, so a NON-locked actor's public post WOULD be
  // delivered here. Without the follow the negative proves nothing.
  const followed = await peerFollow(request, peerTok.value, acct);
  expect(
    followed,
    `the peer must be able to FOLLOW the local subject ${acct} — a failure here is federation `
    + `REACHABILITY, not enforcement, and would make the negative assertion meaningless`,
  ).toBeTruthy();
});

When('the persona for this scenario posts a public toot carrying a unique marker',
  async ({ request, world, dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const needle = marker(handle);
    world.set(NEEDLE, needle);
    // A RAW-API visibility=public toot, bypassing any UI scoping: the MRF must
    // keep even THAT local for a force-local actor.
    await postLocalStatus(request, world.get<string>(SUBJECT_TOKEN), `public toot ${needle}`, 'public');
  });

Then('the toot is visible on the local instance timeline', async ({ request, world }) => {
  const r = await request.get(`${LOCAL_MASTODON}/api/v1/timelines/public`, {
    headers: { authorization: `Bearer ${world.get<string>(SUBJECT_TOKEN)}` },
    params: { local: 'true', limit: '40' },
  });
  expect(r.ok(), 'the local public timeline must answer (full LOCAL access is preserved)').toBeTruthy();
  expect(
    JSON.stringify(await r.json()),
    'the toot is visible LOCALLY — domain lock removes federation, not local access',
  ).toContain(world.get<string>(NEEDLE));
});

/**
 * The one observation both the negative proof and the positive control make, with
 * the outcome word supplied by the Examples column. `never sees` watches the FULL
 * window and fails the moment the marker appears; `sees` polls until it does.
 * The window must be >= the control's observed delivery time or the negative
 * proves nothing, which is why both rows pass the same bound.
 */
Then('the remote peer {string} that toot within {int} seconds',
  async ({ request, world }, outcome: string, seconds: number) => {
    const peerToken = world.get<string>(PEER_TOKEN);
    const acct = world.get<string>(SUBJECT_ACCT);
    const needle = world.get<string>(NEEDLE);
    const windowMs = seconds * 1_000;
    if (outcome === 'never sees') {
      await expectPeerNeverSaw(request, peerToken, acct, needle, windowMs);
      return;
    }
    if (outcome === 'sees') {
      const reached = await peerSawStatus(request, peerToken, acct, needle, windowMs);
      expect(
        reached,
        `the NON-locked control toot ${needle} MUST reach the peer ${PEER_BASE} — if this fails, `
        + `the non-federation scenarios are INCONCLUSIVE (a dead pipe looks exactly like `
        + `enforcement). Fix the harness/peer before reading any green here.`,
      ).toBe(true);
      return;
    }
    throw new Error(
      `unknown outcome "${outcome}" in the Examples table. The only legal values are `
      + `"sees" (the positive control) and "never sees" (the non-federation proof) — a typo `
      + `must not silently assert nothing.`,
    );
  });

// ── the Matrix egress backstop (spec 20) ─────────────────────────────────────
//
// For Matrix there is NO per-user federation control in tuwunel/Conduit (only
// server-wide allow/deny and per-room m.federate at create), so the AUTHORITATIVE
// non-federation control is the EGRESS backstop: the homeserver gets no direct
// internet egress and the squid allowlist excludes the target. The proof is
// therefore at the egress boundary, not in a user setting.

function matrixBase(): string {
  return process.env['SNAP_MATRIX_BASE'] ?? 'http://tuwunel.hugmesh-backend.svc.cluster.local:8008';
}
function remoteServer(): string {
  return process.env['SNAP_MATRIX_REMOTE_SERVER'] ?? 'peer.test';
}

Given('the domain-locked Matrix persona holds a provisioned homeserver token',
  async ({ world, dimensions, $testInfo }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const tok = tokenFor('MATRIX', handle);
    $testInfo.skip(!tok.value, `${tok.name} not provisioned for this run (subject Matrix token absent)`);
    world.set(SUBJECT_TOKEN, tok.value);
  });

When('the persona tries to join a room hosted on the remote server', async ({ request, world }) => {
  // #nofed-probe:peer.test — the alias form the CS-API takes.
  const alias = `%23nofed-probe:${remoteServer()}`;
  const r = await request.post(`${matrixBase()}/_matrix/client/v3/join/${alias}`, {
    headers: { authorization: `Bearer ${world.get<string>(SUBJECT_TOKEN)}` },
    data: {},
    failOnStatusCode: false,
  });
  world.set(LAST_RESPONSE_OK, r.ok());
});

Then('the remote room join is refused', async ({ world }) => {
  expect(
    world.get<boolean>(LAST_RESPONSE_OK),
    `a domain-locked user MUST NOT join a room on remote server ${remoteServer()} — the egress `
    + `backstop blocks federation, so the local server's federation attempt must FAIL`,
  ).toBe(false);
});

When('the persona creates a local Matrix room', async ({ request, world }) => {
  const r = await request.post(`${matrixBase()}/_matrix/client/v3/createRoom`, {
    headers: { authorization: `Bearer ${world.get<string>(SUBJECT_TOKEN)}` },
    data: { name: 'local-only room', preset: 'private_chat' },
    failOnStatusCode: false,
  });
  expect(r.ok(), 'creating a LOCAL room is ALLOWED — local access is preserved').toBeTruthy();
  world.set(MATRIX_ROOM, (await r.json()).room_id);
});

Then('the local room is created', async ({ world }) => {
  expect(world.get<string>(MATRIX_ROOM), 'createRoom returned a room_id').toBeTruthy();
});

When('the persona invites a user on the remote server', async ({ request, world }) => {
  const r = await request.post(
    `${matrixBase()}/_matrix/client/v3/rooms/${encodeURIComponent(world.get<string>(MATRIX_ROOM))}/invite`,
    {
      headers: { authorization: `Bearer ${world.get<string>(SUBJECT_TOKEN)}` },
      data: { user_id: `@probe:${remoteServer()}` },
      failOnStatusCode: false,
    },
  );
  world.set(LAST_RESPONSE_OK, r.ok());
});

Then('the remote invite is refused', async ({ world }) => {
  expect(
    world.get<boolean>(LAST_RESPONSE_OK),
    `a domain-locked user MUST NOT federate an invite to @probe:${remoteServer()}`,
  ).toBe(false);
});

// ── roster contracts for the federation matrix (offline) ─────────────────────

Then('the persona named by the role dimension holds a domain-locked platform role', async ({ dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const roles = systemsUser(handle).roles;
  expect(
    roles.filter((r) => r.endsWith('_DOMAINLOCKED')),
    `'${handle}' is the SUBJECT of the non-federation proof, so the seed must grant it a `
    + `*_DOMAINLOCKED role. Seeded roles: [${roles.join(', ')}]`,
  ).not.toHaveLength(0);
});

Then('the persona named by the role dimension is a federation control user', async ({ dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const u = systemsUser(handle);
  expect(
    u.federationControl,
    `'${handle}' is the CLOCK for the non-federation proof: its activity MUST reach the peer, so `
    + `the seed catalogue must mark it federationControl:true and must NOT domain-lock it. `
    + `Seeded roles: [${u.roles.join(', ')}]`,
  ).toBe(true);
  expect(u.roles.filter((r) => r.endsWith('_DOMAINLOCKED')), 'a control user is never domain-locked')
    .toHaveLength(0);
});
