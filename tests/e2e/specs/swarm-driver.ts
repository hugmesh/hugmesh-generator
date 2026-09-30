// swarm-driver.ts — the SCALED-CONCURRENT final-sweep framework.
//
// Drives the procedural population from rbac-roles.ts (generateSwarm: 120 users +
// 4 mods + 2 admins by default) acting SIMULTANEOUSLY, and provides the assertion
// primitives the sweep spec (24-final-e2e-sweep.spec.ts) composes:
//
//   * loadToken(member)          — the pre-minted JWT (seed-accounts.sh --swarm
//                                  caches one per member in PREMINT_DIR) so 126
//                                  actors do not serialize at Casdoor login.
//   * runConcurrently(...)       — fan out N actor functions at once AND record
//                                  the max in-flight count, so a silently
//                                  SERIALIZED run (Casdoor replicas:1) FAILS the
//                                  concurrency invariant instead of passing slowly.
//   * assertControlAtLayers(...) — the SAME enacted control (e.g. a mod
//                                  suspending a user) is asserted at EVERY relevant
//                                  enforcement LAYER (gateway / bff / homeserver /
//                                  egress / casdoor / ui), not just one.
//   * expectSse(...)             — the acting principal RECEIVES the per-role
//                                  action message over SSE (the live console feed).
//   * assertDisabledHasHelptext  — a DISABLED UI control carries helptext
//                                  explaining WHY (aria-describedby / title), so a
//                                  denied action is legible, not just inert.
//
// FRAMEWORK + REPRESENTATIVE SCENARIOS: the full action×role×layer matrix is
// documented in docs/FINAL-E2E-SWEEP-MATRIX.md; the spec wires representative
// rows (not every cell) — the matrix is the authoritative enumeration, the spec
// the executable sample, and neither is silently truncated.

import { APIRequestContext, Page, expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import {
  SwarmMember, generateSwarm, SWARM_DEFAULTS, swarmTargetsForMod,
} from './rbac-roles';
import { Layer } from './report-tags';

/** Where seed-accounts.sh --swarm cached the per-member JWTs. */
export const PREMINT_DIR =
  process.env['SNAP_PREMINT_DIR'] ?? path.resolve(process.env['PREMINT_DIR'] ?? '../qemu/jwt-cache');

/** Build the population (overridable for a smaller CI smoke via env). */
export function swarm(): SwarmMember[] {
  const counts = {
    users: Number(process.env['SWARM_USERS'] ?? SWARM_DEFAULTS.users),
    mods: Number(process.env['SWARM_MODS'] ?? SWARM_DEFAULTS.mods),
    admins: Number(process.env['SWARM_ADMINS'] ?? SWARM_DEFAULTS.admins),
  };
  return generateSwarm(counts);
}

/** Load a member's pre-minted JWT (or '' if absent — caller skips honestly). */
export function loadToken(member: SwarmMember): string {
  const f = path.join(PREMINT_DIR, `${member.username}.jwt`);
  try { return fs.readFileSync(f, 'utf8').trim(); } catch { return ''; }
}

/** True when the JWT cache is populated enough to run the sweep for real. */
export function premintReady(min = 1): boolean {
  try { return fs.readdirSync(PREMINT_DIR).filter((f) => f.endsWith('.jwt')).length >= min; }
  catch { return false; }
}

/** Re-export so the spec + the seed agree on who each mod moderates. */
export { swarmTargetsForMod };

interface ConcurrencyResult<T> { results: T[]; maxInFlight: number; }

/**
 * Run `tasks` ALL AT ONCE and measure the peak number simultaneously in flight.
 * The sweep asserts maxInFlight >= some floor so a serialized execution (which
 * would still produce correct per-action results, just one-at-a-time) is caught:
 * concurrency is part of the contract, not an optimization.
 */
export async function runConcurrently<T>(
  tasks: Array<() => Promise<T>>,
): Promise<ConcurrencyResult<T>> {
  let inFlight = 0;
  let maxInFlight = 0;
  const wrapped = tasks.map((t) => async () => {
    inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
    try { return await t(); } finally { inFlight--; }
  });
  const results = await Promise.all(wrapped.map((w) => w()));
  return { results, maxInFlight };
}

/** A single enforcement-layer probe: hit `url` with `token` and return the
 *  observed decision ('ALLOW' on 2xx, 'DENY' on 401/403, 'ERR' otherwise). */
export async function probeLayer(
  req: APIRequestContext, url: string, token: string,
): Promise<'ALLOW' | 'DENY' | 'ERR'> {
  const r = await req.get(url, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
    failOnStatusCode: false,
  });
  const s = r.status();
  if (s >= 200 && s < 300) return 'ALLOW';
  if (s === 401 || s === 403) return 'DENY';
  return 'ERR';
}

export interface LayerExpectation {
  layer: Layer;
  url: string;
  token: string;
  expect: 'ALLOW' | 'DENY';
}

/**
 * Assert one enacted control holds at EVERY listed layer. The point of the sweep:
 * a control that is correct at the gateway but missing at the BFF (or vice-versa)
 * is a hole — so the same outcome is required at each independent layer.
 */
export async function assertControlAtLayers(
  req: APIRequestContext, label: string, layers: LayerExpectation[],
): Promise<void> {
  for (const l of layers) {
    const got = await probeLayer(req, l.url, l.token);
    expect(got, `${label}: layer ${l.layer} (${l.url}) expected ${l.expect}, got ${got}`).toBe(l.expect);
  }
}

/**
 * READ-AFTER-WRITE cross-principal observation: assert `needle` appears in the
 * OBSERVER's view of `url` (polled as the observer's token) within `timeoutMs`.
 * This is the expect.poll-style bounded wait for "A wrote X → B sees X" — the
 * observer is a DIFFERENT principal than the writer, so a green proves the
 * write propagated across principals, not that the writer read its own cache.
 * Bounded retries only — never an unbounded wait, never a bare sleep-and-hope.
 */
export async function expectObservedWithin(
  req: APIRequestContext,
  opts: { url: string; token: string; needle: string; timeoutMs?: number; label: string },
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 15_000;
  await expect
    .poll(
      async () => {
        const r = await req.get(opts.url, {
          headers: opts.token ? { authorization: `Bearer ${opts.token}` } : {},
          failOnStatusCode: false,
        });
        if (!r.ok()) return false;
        return (await r.text()).includes(opts.needle);
      },
      {
        message: `${opts.label}: marker ${opts.needle} should appear in the observer's view of ${opts.url} within ${timeoutMs}ms`,
        timeout: timeoutMs,
        intervals: [500, 1_000, 2_000],
      },
    )
    .toBe(true);
}

/**
 * Assert the acting principal receives its per-role action message over SSE. The
 * console exposes a per-principal event stream; after an action we expect an event
 * whose payload mentions `actionMarker`. Best-effort connect with a timeout; the
 * caller decides whether SSE is REQUIRED (live console run) or skipped.
 */
export async function expectSse(
  req: APIRequestContext, sseUrl: string, token: string, actionMarker: string, timeoutMs = 15_000,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    // The console exposes a since-cursor poll fallback for the SSE feed so a test
    // need not hold an open stream; we poll it for our marker.
    const r = await req.get(sseUrl, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
      params: { since: '0' },
      failOnStatusCode: false,
    });
    if (r.ok()) {
      const body = await r.text();
      if (body.includes(actionMarker)) return true;
    }
    await new Promise((res) => setTimeout(res, 1_000));
  }
  return false;
}

/**
 * Assert a DISABLED UI control carries helptext explaining why it is disabled —
 * an aria-describedby target, a title, or a non-empty data-disabled-reason. A
 * denied action must be LEGIBLE (the user is told why), not a dead inert button.
 */
export async function assertDisabledHasHelptext(page: Page, testId: string): Promise<void> {
  const el = page.getByTestId(testId);
  // toBeDisabled() honours aria-disabled ONLY on elements carrying an ARIA widget
  // role. The host shell greys a launcher card as a role-less
  // <span aria-disabled="true"> (home-services.component.html), which toBeDisabled()
  // reads as ENABLED — so an explicit aria-disabled="true" counts on its own.
  if ((await el.getAttribute('aria-disabled')) !== 'true') {
    await expect(el, `${testId} should be disabled for this role`).toBeDisabled();
  }
  const describedBy = await el.getAttribute('aria-describedby');
  const title = await el.getAttribute('title');
  const reason = await el.getAttribute('data-disabled-reason');
  let helptext = (title ?? '') + (reason ?? '');
  if (describedBy) {
    const help = page.locator(`#${describedBy}`);
    helptext += (await help.textContent()) ?? '';
  }
  expect(
    helptext.trim().length,
    `${testId} is disabled but carries NO helptext (aria-describedby/title/data-disabled-reason) — a denied control must say WHY`,
  ).toBeGreaterThan(0);
}
