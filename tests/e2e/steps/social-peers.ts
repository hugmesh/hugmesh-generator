// social-peers.ts — the MULTI-USER machinery the social-federation Gherkin needs,
// and nothing else.
//
// WHY IT EXISTS. Specs 05/06/10/11/31 are not single-page journeys: their whole
// point is that TWO OR THREE DISTINCT signed-in identities, in cookie-separated
// browser contexts, see each other's traffic. A Gherkin lane that quietly drove
// one page and asserted against itself would look identical in the report and
// prove nothing, so the peer contexts are modelled explicitly here and shared by
// steps/matrix.steps.ts and steps/mastodon.steps.ts.
//
// NOT A STEP FILE. It defines no Given/When/Then; it is picked up by the
// generator's `steps: ['steps/**/*.ts']` glob the same way world.ts and
// dimensions.ts are, which is what lets it register the ONE After hook that
// closes the contexts a scenario opened. The hook comes from './world' — the
// single createBdd() instance — never from 'playwright-bdd' directly.

import type { Browser, BrowserContext, Page } from '@playwright/test';
import { After } from './world';
import type { World } from './world';
import { onboard, platformPersonas, requirePlatformPersonas } from '../specs/helpers';
import { service } from './dimensions';

/** One onboarded peer: its own cookie jar, its page, and the handle it signed in
 *  as. `matrixUserId` is filled lazily by the Matrix steps that need it. */
export interface Peer {
  handle: string;
  ctx: BrowserContext;
  page: Page;
  matrixUserId?: string;
  mastodonAccountId?: string;
}

/** world key holding the ordered peer list a scenario opened. */
export const PEERS = 'social-peers';

/** The platform ACCESS role that gates a service's homeserver backend, read off
 *  the ServiceDef rather than re-spelled here (steps/dimensions.ts SERVICES).
 *  Throws for a service that has none — a feature naming, say, @service:wiki in a
 *  platform-roster step is asking a question the roster cannot answer. */
export function platformAccessRole(serviceId: string): 'ROLE_MATRIX' | 'ROLE_MASTODON' {
  const def = service(serviceId);
  if (def.accessRole !== 'ROLE_MATRIX' && def.accessRole !== 'ROLE_MASTODON') {
    throw new Error(
      `service '${serviceId}' (${def.name}) is not gated by a per-platform ACCESS role — its `
      + `accessRole is ${JSON.stringify(def.accessRole)}. Only tuwunel (ROLE_MATRIX) and akkoma `
      + `(ROLE_MASTODON) carry the platform roster this step asks about.`,
    );
  }
  return def.accessRole;
}

/** The peers this scenario opened, or an empty list. */
export function peersOf(world: World): Peer[] {
  return world.has(PEERS) ? world.get<Peer[]>(PEERS) : [];
}

/** The Nth peer (0-based), or a failure naming the missing Given. */
export function peer(world: World, index: number): Peer {
  const all = peersOf(world);
  if (!all[index]) {
    throw new Error(
      `this step needs peer #${index + 1} but the scenario opened ${all.length}. Add the Given `
      + `that signs the peers in ("one more seeded ... persona signs in as my peer" / "two more `
      + `seeded ... personas sign in as my peers") before the step that drives them.`,
    );
  }
  return all[index];
}

/**
 * Sign `count` MORE platform-access personas in, each in its own context,
 * SKIPPING the handle the scenario itself is signed in as.
 *
 * The roster comes from helpers.platformPersonas — the seed catalogue's
 * NON-domain-locked holders of the access role — exactly as specs 05/06/10/11/31
 * resolve it, so a roster change re-arms the Gherkin with no feature edit and a
 * SHORT roster fails by name (requirePlatformPersonas) instead of dying on
 * `undefined.username`. Domain-locked holders stay excluded: they are the SUBJECT
 * of the non-federation proof (features/federation/**) and borrowing them for
 * ordinary chat would entangle two proofs.
 */
export async function signInPeers(
  browser: Browser,
  world: World,
  serviceId: string,
  selfHandle: string,
  count: number,
): Promise<Peer[]> {
  const role = platformAccessRole(serviceId);
  // require count+1 so the failure message names the real shortfall: this
  // scenario needs its OWN persona plus `count` distinct peers.
  requirePlatformPersonas(role, count + 1);
  const candidates = platformPersonas(role).filter((p) => p.username !== selfHandle);
  if (candidates.length < count) {
    throw new Error(
      `need ${count} ${role} peer(s) distinct from the scenario persona '${selfHandle}', the seed `
      + `catalogue leaves ${candidates.length} (${candidates.map((p) => p.username).join(', ') || 'none'}). `
      + `Seed another ${role} persona into SYSTEMS_SEED_USERS + seed-accounts.sh — never grant the `
      + `platform role to a plain ROLE_USER handle, which spec 17 asserts is denied the backend.`,
    );
  }
  const opened = peersOf(world);
  for (const { username, password } of candidates.slice(0, count)) {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    // onboard() is the SAME two-stage helper the handwritten specs use, and is
    // idempotent, so a persona an earlier scenario completed signs straight in.
    await onboard(page, username, password);
    opened.push({ handle: username, ctx, page });
  }
  world.set(PEERS, opened);
  return opened;
}

// Close every context a scenario opened. Without this the contexts live until the
// worker's browser closes — with workers:1 and a whole social suite that is a
// steadily growing pile of Chromium contexts, which is how a suite starts dying
// of memory in the middle rather than at a scenario you can name.
After(async ({ world }) => {
  for (const p of peersOf(world)) {
    await p.ctx.close().catch(() => { /* already torn down by the scenario */ });
  }
});
