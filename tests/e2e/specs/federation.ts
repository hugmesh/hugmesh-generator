// federation.ts — the non-federation (domain-lock) e2e harness helpers.
//
// The proof these specs encode: a domain-locked Mastodon/Matrix user's outbound
// activity MUST NOT reach a REMOTE peer, while a NON-locked CONTROL user's
// activity MUST (the positive control / the clock). The external observer is the
// TEST-ONLY akkoma-peer (specs/cluster/manifests/test-runner/akkoma-peer.yaml) —
// a real, genuinely-federating ActivityPub instance on its own origin (peer.test),
// reset per run. We assert on what DID and DID NOT land in ITS inbox/timeline, so
// "no federation" is OBSERVED at the remote, not merely asserted at the source.
//
// ── Runtime gating ───────────────────────────────────────────────────────────
// Domain-lock enforcement (the akkoma ForceLocalForUsers MRF + the egress
// backstop) SHIPS DARK / GATED by default (see docs/DOMAIN-LOCK.md). And the peer
// only exists in a heavy/x86 test cluster. So these specs:
//   * RUN as real assertions when SNAP_FEDERATION_PEER is set (the peer base URL)
//     AND SNAP_DOMAINLOCK_ENABLED=1 (the MRF/egress gate is flipped on),
//   * otherwise SKIP with a precise reason — they NEVER fake a pass.
// This mirrors the LIVE_GATEWAY / SNAP_EXPECT_HEAVY gating the other tiers use.

import { APIRequestContext, expect } from '@playwright/test';

/** The remote observer peer base URL (the akkoma-peer Service), or '' when the
 *  peer is not deployed (lean/no-x86 run) — the specs skip in that case. */
export const PEER_BASE = process.env['SNAP_FEDERATION_PEER'] ?? '';

/** Whether domain-lock enforcement (MRF + egress) is flipped ON in this cluster.
 *  When OFF, a domain-locked user WOULD federate, so the non-federation assertion
 *  is intentionally skipped (the feature ships dark). */
export const DOMAINLOCK_ON = process.env['SNAP_DOMAINLOCK_ENABLED'] === '1';

/** The system-under-test Mastodon (akkoma) API base — the local instance whose
 *  users we drive. Defaults to the in-cluster akkoma Service. */
export const LOCAL_MASTODON =
  process.env['SNAP_MASTODON_BASE'] ??
  'http://akkoma.snapdragon-backend.svc.cluster.local:4000';

/** Skip-guard: returns a non-empty REASON string when these specs cannot run as
 *  real assertions (so the caller test.skip(reason)s honestly), else ''. */
export function federationSkipReason(): string {
  if (!PEER_BASE) return 'SNAP_FEDERATION_PEER unset (akkoma-peer not deployed — lean/no-x86 run)';
  if (!DOMAINLOCK_ON) return 'SNAP_DOMAINLOCK_ENABLED!=1 (domain-lock MRF/egress ships dark — see docs/DOMAIN-LOCK.md)';
  return '';
}

/** Post a status as `token` on the LOCAL instance via the Mastodon REST API.
 *  visibility lets a spec prove even a RAW-API public toot stays local for a
 *  domain-locked user (not just the UI's default scoping). Returns the status id. */
export async function postLocalStatus(
  req: APIRequestContext,
  token: string,
  text: string,
  visibility: 'public' | 'unlisted' | 'private' | 'direct' = 'public',
): Promise<string> {
  const r = await req.post(`${LOCAL_MASTODON}/api/v1/statuses`, {
    headers: { authorization: `Bearer ${token}` },
    data: { status: text, visibility },
  });
  expect(r.ok(), `local post should be accepted (the user keeps full LOCAL access)`).toBeTruthy();
  return (await r.json()).id;
}

/** private-visibility variant of postLocalStatus — a followers-only toot. Used
 *  by the scoped-visibility non-federation rows: the MRF must keep even a
 *  followers-only delivery local when the actor has REMOTE followers. */
export async function postLocalPrivateStatus(
  req: APIRequestContext,
  token: string,
  text: string,
): Promise<string> {
  return postLocalStatus(req, token, text, 'private');
}

/** direct-visibility variant of postLocalStatus — a DM. `recipientAcct` is
 *  mentioned so the delivery has a concrete target (a direct toot with no
 *  mention has no recipient and would prove nothing). */
export async function postLocalDirectStatus(
  req: APIRequestContext,
  token: string,
  text: string,
  recipientAcct: string,
): Promise<string> {
  return postLocalStatus(req, token, `@${recipientAcct} ${text}`, 'direct');
}

/** Have a follower account ON THE PEER follow `localAcct` (e.g. user@mastodon.
 *  snapdragon.systems) so the local user's public posts have a remote delivery
 *  target. Uses the peer's Mastodon-compatible search+follow API. Returns true if
 *  the remote actor resolved on the peer at all (federation reachability). */
export async function peerFollow(
  req: APIRequestContext,
  peerToken: string,
  localAcct: string,
): Promise<boolean> {
  const s = await req.get(`${PEER_BASE}/api/v2/search`, {
    headers: { authorization: `Bearer ${peerToken}` },
    params: { q: localAcct, resolve: 'true', type: 'accounts' },
  });
  if (!s.ok()) return false;
  const accounts = (await s.json()).accounts ?? [];
  if (accounts.length === 0) return false;
  const id = accounts[0].id;
  const f = await req.post(`${PEER_BASE}/api/v1/accounts/${id}/follow`, {
    headers: { authorization: `Bearer ${peerToken}` },
  });
  return f.ok();
}

/** Poll the PEER for whether `needle` text appeared in any status the peer
 *  received from `fromAcct` (its federated/public timeline + the actor's
 *  statuses). Returns true once seen, false after the timeout — the core
 *  observation primitive for both the negative proof and the positive control. */
export async function peerSawStatus(
  req: APIRequestContext,
  peerToken: string,
  fromAcct: string,
  needle: string,
  timeoutMs = 30_000,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    // (a) the actor's statuses as the peer stored them (post-federation), and
    // (b) the peer's public/federated timeline.
    const search = await req.get(`${PEER_BASE}/api/v2/search`, {
      headers: { authorization: `Bearer ${peerToken}` },
      params: { q: fromAcct, resolve: 'true', type: 'accounts' },
    });
    if (search.ok()) {
      const accounts = (await search.json()).accounts ?? [];
      if (accounts.length) {
        const statuses = await req.get(
          `${PEER_BASE}/api/v1/accounts/${accounts[0].id}/statuses`,
          { headers: { authorization: `Bearer ${peerToken}` } },
        );
        if (statuses.ok()) {
          const body = JSON.stringify(await statuses.json());
          if (body.includes(needle)) return true;
        }
      }
    }
    const fed = await req.get(`${PEER_BASE}/api/v1/timelines/public`, {
      headers: { authorization: `Bearer ${peerToken}` },
      params: { remote: 'true', limit: '40' },
    });
    if (fed.ok()) {
      const body = JSON.stringify(await fed.json());
      if (body.includes(needle)) return true;
    }
    await new Promise((res) => setTimeout(res, 2_000));
  }
  return false;
}

/** Assert an observer does NOT see `needle` — a BOUNDED negative probe. It
 *  watches `url` (as `token`) for the FULL `windowMs` window and FAILS the
 *  moment the marker appears; only after the whole window elapses without a
 *  sighting does it pass. windowMs must be >= the positive-control delivery
 *  time (spec 22's clock) or the negative proves nothing — pass the SAME bound
 *  the positive control was observed under. */
export async function assertObserverNeverSees(
  req: APIRequestContext,
  opts: { url: string; token: string; needle: string; windowMs: number; label: string },
): Promise<void> {
  const deadline = Date.now() + opts.windowMs;
  while (Date.now() < deadline) {
    const r = await req.get(opts.url, {
      headers: opts.token ? { authorization: `Bearer ${opts.token}` } : {},
      failOnStatusCode: false,
    });
    if (r.ok()) {
      const body = await r.text();
      expect(
        body.includes(opts.needle),
        `${opts.label}: marker ${opts.needle} MUST NOT appear at ${opts.url} — but it did`,
      ).toBe(false);
    }
    await new Promise((res) => setTimeout(res, 2_000));
  }
}

/** Assert the PEER never received `needle` from `fromAcct` — the peer-side
 *  negative observation (same probes as peerSawStatus, full-window watch).
 *  Only meaningful next to the spec-22 positive control: a green here plus a
 *  green control means "federation works AND this delivery was withheld". */
export async function expectPeerNeverSaw(
  req: APIRequestContext,
  peerToken: string,
  fromAcct: string,
  needle: string,
  windowMs = 30_000,
): Promise<void> {
  const reached = await peerSawStatus(req, peerToken, fromAcct, needle, windowMs);
  expect(
    reached,
    `marker ${needle} from ${fromAcct} MUST NOT reach the peer ${PEER_BASE} `
    + `(watched the full ${windowMs}ms window; positive control = spec 22)`,
  ).toBe(false);
}

/** A unique per-run marker so a post is unmistakably THIS run's (no false match
 *  on a stale peer record — though the peer DB resets per run too). */
export function marker(label: string): string {
  return `nofed-${label}-${process.env['SNAP_RUN_ID'] ?? 'dev'}-${Date.now()}`;
}
