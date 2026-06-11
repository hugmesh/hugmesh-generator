import { test, expect } from '@playwright/test';
import { tags } from './report-tags';
import {
  swarm, loadToken, premintReady, runConcurrently, swarmTargetsForMod,
  assertControlAtLayers, expectSse, type LayerExpectation,
} from './swarm-driver';

// 24 — SCALED-CONCURRENT FINAL E2E SWEEP.
//
// Drives the procedural population (rbac-roles.ts generateSwarm: 120 users + 4
// mods + 2 admins by default) acting SIMULTANEOUSLY, and asserts:
//   (A) CONCURRENCY is real — the actors run at once (maxInFlight >= floor), not
//       silently serialized behind Casdoor replicas:1 (pre-minted JWTs make this
//       possible; the invariant makes a regression to serial FAIL).
//   (B) every enacted control holds at EACH enforcement LAYER (gateway+bff for a
//       mod's reach; gateway for a plain user's denials) — see assertControlAtLayers.
//   (C) a mod MODERATES the users assigned below it but is DENIED moderating an
//       admin/peer (the sibling rule holds under load).
//   (D) the per-role action MESSAGE arrives over SSE (the live console feed).
//   (E) DISABLED UI controls carry helptext (covered as a live-UI scenario; the
//       gateway/bff scenarios here are headless API probes).
//
// This is the FRAMEWORK + REPRESENTATIVE SCENARIOS. The AUTHORITATIVE full matrix
// (every action × role × layer) is docs/FINAL-E2E-SWEEP-MATRIX.md — the spec wires
// a representative, non-truncated SAMPLE of its rows; the doc enumerates them all.
//
// Honest gating: requires a LIVE gateway/bff + the pre-minted JWT cache. Without
// them it SKIPs with a precise reason (never a fake pass). LIVE_GATEWAY=1 +
// SNAP_PREMINT_DIR (populated) turn it on; the lean/heavy Jobs set both.

const LIVE = process.env['LIVE_GATEWAY'] === '1';
const BE = process.env['SNAP_BE_GATEWAY'] ?? 'https://snapdragon-be-gateway.snapdragon-backend.svc.cluster.local:8443';
const SSE = process.env['SNAP_SSE_URL'] ?? 'https://snapdragon-be-gateway.snapdragon-backend.svc.cluster.local:8443/bff/admin/test-reports/events';

test.describe('final sweep: scaled-concurrent population', () => {
  const pop = swarm();
  const users = pop.filter((m) => m.swarmTier === 'user');
  const mods = pop.filter((m) => m.swarmTier === 'mod');
  const admins = pop.filter((m) => m.swarmTier === 'admin');

  test.beforeAll(() => {
    test.skip(!LIVE, 'LIVE_GATEWAY!=1 (the sweep drives the real gateway/bff; lean/heavy Jobs set it)');
    test.skip(!premintReady(Math.min(10, pop.length)), `pre-minted JWT cache not populated (run seed-accounts.sh --roles --swarm ${users.length})`);
  });

  // (A) CONCURRENCY INVARIANT — every member hits its user-floor surface at once;
  //     the peak in-flight must reflect genuine parallelism.
  test(`(A) the population acts CONCURRENTLY (max in-flight >= floor) ${tags({ role: 'ALL', layer: 'gateway' })}`, async ({ playwright }) => {
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    const tasks = pop.map((m) => async () => {
      const token = loadToken(m);
      return req.get(`${BE}/api/v1/timelines/home`, {
        headers: token ? { authorization: `Bearer ${token}` } : {},
        failOnStatusCode: false,
      });
    });
    const { maxInFlight } = await runConcurrently(tasks);
    // Floor: at least 20 simultaneously in flight (a serialized run peaks at 1).
    const floor = Math.min(20, pop.length);
    expect(maxInFlight, `expected >= ${floor} actors in flight at once, saw ${maxInFlight} (serialized?)`).toBeGreaterThanOrEqual(floor);
    await req.dispose();
  });

  // (B)+(C) a REPRESENTATIVE mod moderates its assigned user-block AND is denied
  //     moderating an admin — asserted at the gateway AND bff layers, under the
  //     concurrent load of all mods acting at once.
  test(`(B/C) mods moderate assigned users + are DENIED admins, at gateway+bff ${tags({ role: 'ROLE_MOD', layer: 'bff' })}`, async ({ playwright }) => {
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    const modTasks = mods.map((mod) => async () => {
      const modToken = loadToken(mod);
      const targets = swarmTargetsForMod(mod.tierIndex, { users: users.length, mods: mods.length, admins: admins.length });
      const victim = targets[0]; // a representative user in this mod's block
      // (B) the mod REACHES the moderation surface (akkoma admin) for its target —
      //     at the gateway AND the bff. (C-negative) the mod is DENIED the admin API.
      const layers: LayerExpectation[] = [
        { layer: 'gateway',    url: `${BE}/api/v1/pleroma/admin/statuses?account=${victim}`, token: modToken, expect: 'ALLOW' },
        { layer: 'bff',        url: `${BE}/bff/mod/actions?subject=${victim}`,               token: modToken, expect: 'ALLOW' },
        { layer: 'gateway',    url: `${BE}/api/admin/route-access`,                          token: modToken, expect: 'DENY'  },
        { layer: 'bff',        url: `${BE}/bff/admin/allowlist`,                             token: modToken, expect: 'DENY'  },
      ];
      await assertControlAtLayers(req, `mod ${mod.username} -> ${victim}`, layers);
    });
    // All mods act simultaneously.
    const { maxInFlight } = await runConcurrently(modTasks);
    expect(maxInFlight, 'mods should act concurrently').toBeGreaterThanOrEqual(Math.min(mods.length, 2));
    await req.dispose();
  });

  // (D) the per-role action message arrives over SSE for an acting admin (a
  //     representative privileged action — a global reconcile — is announced to
  //     the principal's live console feed).
  test(`(D) an admin action is announced over SSE ${tags({ role: 'ROLE_ADMIN', layer: 'sse' })}`, async ({ playwright }) => {
    test.skip(admins.length === 0, 'no admins in this swarm sizing');
    const req = await playwright.request.newContext({ ignoreHTTPSErrors: true });
    const admin = admins[0];
    const token = loadToken(admin);
    const marker = `sweep-admin-${admin.username}-${Date.now()}`;
    // Enact a representative admin action that should surface on the feed. (The
    // exact endpoint is the admin-bff reconcile; the marker rides the request id.)
    await req.post(`${BE}/bff/admin/reconcile`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
      data: { note: marker },
      failOnStatusCode: false,
    });
    const seen = await expectSse(req, SSE, token, marker, 15_000);
    expect(seen, `admin action ${marker} should appear on the per-principal SSE feed`).toBe(true);
    await req.dispose();
  });
});

// (E) DISABLED-UI-HELPTEXT — a representative live-UI scenario. Kept a clearly
// marked PENDING stub until the role-conditional UI lands (same honesty as spec
// 18): the host shell does not yet render role-disabled controls with helptext.
// When it does, drive a ROLE_USER session to the admin entry-point and assert the
// disabled control carries helptext (assertDisabledHasHelptext in swarm-driver.ts).
test.describe('final sweep: disabled UI carries helptext (live UI)', () => {
  test.skip('a ROLE_USER sees the admin control DISABLED with an explaining helptext', async () => {
    // TODO(Phase8): when the host shell renders role-disabled controls, log in as
    // a swarm user and: await assertDisabledHasHelptext(page, 'nav-admin').
    // The framework primitive already exists; this activates when the UI does.
    expect(true).toBe(true);
  });
});
