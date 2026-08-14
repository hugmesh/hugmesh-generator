import { test, expect, request, APIRequestContext } from '@playwright/test';
import { SYSTEMS_SEED_USERS, passwordFor, systemsUser } from './rbac-roles';
import { gatewayDecision, effectiveRoles, Gateway } from './rbac-route-access';

// 14 — LIVE gateway route-access enforcement (ACTIVATES when the gateways land).
//
// Phase 8/10: hugmesh-fe-gateway / -be-gateway / -pki-gateway are README-only
// today and there is no real Casdoor in the rootless mock stack, so this whole
// file is SKIPPED unless BOTH:
//   * LIVE_GATEWAY=1            — a gateway that enforces gateway_route_access is up
//   * SYSTEMS_CASDOOR_URL=...   — a real systems Casdoor seeded with the role
//                                 matrix (tests/qemu/seed-accounts.sh --roles)
// is set. When activated it does the REAL thing the oracle in 12 models:
//   1. obtain a real Casdoor JWT per seed user (password grant, deterministic
//      e2e password — same mechanism the games harness uses).
//   2. hit each gateway URL THROUGH the gateway and assert the HTTP status
//      matches the schema.sql contract: ALLOW => not 401/403, DENY => 401/403.
//
// The expected decision is computed from rbac-route-access.ts (the schema.sql
// mirror) using the user's EFFECTIVE roles (granted + derived ROLE_GAMES_ADMIN),
// so 12 (contract) and 14 (live) can never silently diverge.
//
// We deliberately do NOT fake a pass: with no gateway up, test.skip() marks these
// pending so they light up the moment the enforcement layer exists.

const LIVE = process.env.LIVE_GATEWAY === '1';
const CASDOOR_URL = process.env.SYSTEMS_CASDOOR_URL || '';
const CASDOOR_ORG = process.env.SYSTEMS_CASDOOR_ORG || 'hugmesh';
const CASDOOR_CLIENT_ID = process.env.SYSTEMS_CASDOOR_CLIENT_ID || '';
const CASDOOR_CLIENT_SECRET = process.env.SYSTEMS_CASDOOR_CLIENT_SECRET || '';
// Gateway base URLs (default to SNAP_BASE_URL for the fe-gateway; override per gw).
const GW_BASE: Record<Gateway, string> = {
  'hugmesh-fe-gateway': process.env.FE_GATEWAY_URL || process.env.SNAP_BASE_URL || 'https://localhost:8443',
  'hugmesh-be-gateway': process.env.BE_GATEWAY_URL || 'https://api.localhost:8443',
  'hugmesh-pki-gateway': process.env.PKI_GATEWAY_URL || 'https://id.localhost:8443',
  // Tailnet-only; probed by spec 25 (its own LIVE describe), listed here only so
  // the Gateway record is total — spec 14's LIVE_PROBES never target it.
  'hugmesh-superadmin-gateway': process.env.SUPERADMIN_GATEWAY_URL || 'https://superadmin.localhost:8443',
};

/** Real Casdoor password-grant for a seed user; returns the access token whose
 *  `roles` claim the gateway reads. Mirrors hugmesh.games e2e login() but at
 *  the OIDC token endpoint (no UI). */
async function casdoorToken(api: APIRequestContext, username: string): Promise<string> {
  const u = systemsUser(username);
  const mint = async (user: string) => {
    const r = await api.post(`${CASDOOR_URL}/api/login/oauth/access_token`, {
      form: {
        grant_type: 'password',
        client_id: CASDOOR_CLIENT_ID,
        client_secret: CASDOOR_CLIENT_SECRET,
        username: user,
        password: passwordFor(u),
      },
    });
    return r.json();
  };
  // Casdoor resolves the password grant inside the app's organization, so the
  // plain username is canonical ("org/name" answers "the user does not exist"
  // there); org/name is kept as a fallback for deployments that accepted it.
  let body = await mint(username);
  if (!body.access_token) body = await mint(`${CASDOOR_ORG}/${username}`);
  if (!body.access_token) throw new Error(`casdoor token for ${username}: ${JSON.stringify(body)}`);
  return body.access_token as string;
}

// The same contractual URLs as spec 12, re-expressed for a live probe. Each one's
// expected decision is derived from the oracle so the two stay in lockstep.
//
// Matrix/Mastodon homeserver floors (commit 0100d3b): e2e-user (plain ROLE_USER)
// now derives DENY here — the broad ROLE_USER homeserver floor was removed in
// favor of the per-platform ROLE_MATRIX/ROLE_MASTODON access roles. e2e-matrix /
// e2e-mastodon are included so the "a granted member reaches their own
// homeserver" ALLOW case is still live-probed with a real persona.
const LIVE_PROBES: { gw: Gateway; path: string; users: string[] }[] = [
  { gw: 'hugmesh-fe-gateway', path: '/admin/usage', users: ['e2e-admin', 'e2e-adminonly', 'e2e-mod', 'e2e-user'] },
  { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access', users: ['e2e-admin', 'e2e-mod', 'e2e-user'] },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/pleroma/admin/config', users: ['e2e-mod', 'e2e-admin', 'e2e-user'] },
  { gw: 'hugmesh-be-gateway', path: '/_matrix/client/v3/sync', users: ['e2e-mod', 'e2e-matrix', 'e2e-user'] },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/timelines/home', users: ['e2e-mod', 'e2e-mastodon', 'e2e-user'] },
  { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions', users: ['e2e-gamesadmin', 'e2e-gamesonly', 'e2e-adminonly', 'e2e-mod'] },
  { gw: 'hugmesh-be-gateway', path: '/games/api/admin/role-grants', users: ['e2e-gamesadmin', 'e2e-gamesonly', 'e2e-adminonly'] },
  { gw: 'hugmesh-be-gateway', path: '/infra/logs', users: ['e2e-admin', 'e2e-mod'] }, // default-deny for all
];

test.describe('RBAC: LIVE gateway route-access enforcement', () => {
  test.skip(!LIVE || !CASDOOR_URL,
    'pending: needs LIVE_GATEWAY=1 + a real SYSTEMS_CASDOOR_URL seeded via seed-accounts.sh --roles ' +
    '(fe/be/pki gateways are README-only today — Phase 8/10).');

  for (const probe of LIVE_PROBES) {
    for (const username of probe.users) {
      const expected = gatewayDecision(
        probe.gw, probe.path,
        effectiveRoles(systemsUser(username).roles, systemsUser(username).expectGamesAdmin),
      );
      test(`${probe.gw} ${probe.path} — ${username} should be ${expected} (live)`, async () => {
        const api = await request.newContext({ ignoreHTTPSErrors: true });
        const token = await casdoorToken(api, username);
        const r = await api.get(`${GW_BASE[probe.gw]}${probe.path}`, {
          headers: { authorization: `Bearer ${token}` },
        });
        // The contract under test is the GATEWAY's route-access decision, and
        // the gateway says which 401/403s are ITS OWN: an RBAC deny carries
        // X-Route-Denied (RouteAccessWebFilter), a token the resource server
        // rejected carries WWW-Authenticate: Bearer. A 401/403 with NEITHER
        // marker came from the proxied backend — e.g. tuwunel's M_UNKNOWN_TOKEN
        // or Mastodon refusing the relayed Casdoor bearer (both gateways relay
        // the caller's bearer verbatim; no homeserver token exchange has
        // landed) — which PROVES the gateway allowed the route. Judging bare
        // status codes here misread every homeserver ALLOW as a deny.
        const gatewayDenied =
          (r.status() === 401 || r.status() === 403)
          && (r.headers()['x-route-denied'] !== undefined
              || (r.headers()['www-authenticate'] ?? '').startsWith('Bearer'));
        if (expected === 'DENY') {
          expect(gatewayDenied,
            `${username} expected a gateway DENY but got ${r.status()} `
            + `(x-route-denied: ${r.headers()['x-route-denied'] ?? 'absent'})`).toBeTruthy();
        } else {
          expect(gatewayDenied,
            `${username} expected ALLOW but the gateway denied with ${r.status()} `
            + `(x-route-denied: ${r.headers()['x-route-denied'] ?? 'absent'})`).toBeFalsy();
        }
        await api.dispose();
      });
    }
  }
});
