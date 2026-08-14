import { test, expect, request, APIRequestContext } from '@playwright/test';
import {
  SYSTEMS_SEED_USERS, GAMES_SEED_USERS, systemsUser, passwordFor,
  SUPERADMIN_GATEWAY, SUPERADMIN_ALLOW_ROUTES, SUPERADMIN_DENY_ROLES,
  SUPERADMIN_USERNAME, SYSTEMS_ISSUER, GAMES_ISSUER,
} from './rbac-roles';
import { gatewayDecision, effectiveRoles, Gateway } from './rbac-route-access';
import { tags } from './report-tags';

// 25 — ROLE_SUPERADMIN tier + cross-realm issuer isolation.
//
// Two NEW guarantees on top of the spec-12 contract oracle:
//
//   (i) ROLE_SUPERADMIN tier. The infra App-Store/console is served by its OWN
//       tailnet-only gateway (hugmesh-superadmin-gateway,
//       specs/cluster/apps/22-gateway-superadmin.yaml). Every route under that
//       gateway is ROLE_SUPERADMIN in gateway_route_access
//       (specs/cluster/manifests/route-access/initdb/20-schema.sql). We assert
//       ROLE_SUPERADMIN is ALLOWed every superadmin route AND — crucially — that
//       ROLE_ADMIN (and every other non-superadmin tier) is DENIED: ROLE_SUPERADMIN
//       is a DISTINCT tier, NOT a superset admin inherits, so there is no
//       down-cascade.
//
//  (ii) Cross-realm issuer isolation. The SYSTEMS Casdoor (org "hugmesh",
//       issuer id.hugmesh.net) and the GAMES Casdoor (org "threewizards",
//       issuer id.hugmesh.games) are INDEPENDENT. A token minted by one issuer
//       carries that realm's roles ONLY; the OTHER realm's gateway must treat its
//       claims as absent. We assert a games-realm identity carries NO systems
//       ROLE_* into a systems gateway decision (→ DENY on every privileged route),
//       and that a systems identity carries no games role into the games realm.
//
// We do NOT reimplement the systems→games sync PROPAGATION assertion — that lives
// in hugmesh-actions/e2e (sync-steps.ts) and owns it. Here we only add the
// issuer-isolation invariant plus a CATALOGUE-CONSISTENCY check that the games
// e2e-gamesadmin `syncedFromSystems` matches the systems ROLE_GAMES_ADMIN
// derivation (so the two catalogues cannot silently disagree about the seam).
//
// Like spec 14, the LIVE token-grant probe is SKIPPED offline (needs
// LIVE_GATEWAY=1 + a real superadmin Casdoor); the contract assertions above run
// against the oracle with no cluster, so this spec validates offline.

const LIVE = process.env.LIVE_GATEWAY === '1';
const CASDOOR_URL = process.env.SYSTEMS_CASDOOR_URL || '';
const CASDOOR_ORG = process.env.SYSTEMS_CASDOOR_ORG || 'hugmesh';
const CASDOOR_CLIENT_ID = process.env.SYSTEMS_CASDOOR_CLIENT_ID || '';
const CASDOOR_CLIENT_SECRET = process.env.SYSTEMS_CASDOOR_CLIENT_SECRET || '';
const SUPERADMIN_GW_URL =
  process.env.SUPERADMIN_GATEWAY_URL || 'https://superadmin.localhost:8443';

const eff = (username: string) => {
  const u = systemsUser(username);
  return effectiveRoles(u.roles, u.expectGamesAdmin);
};

// ── (i) ROLE_SUPERADMIN tier — ALLOW for superadmin, DENY-down-cascade for admin ──
test.describe('RBAC: ROLE_SUPERADMIN tier (superadmin-gateway contract)', () => {
  test('e2e-superadmin holds ONLY ROLE_SUPERADMIN (its own tier, not admin) '
    + tags({ role: 'ROLE_SUPERADMIN', layer: 'casdoor' }), async () => {
    const sa = systemsUser('e2e-superadmin');
    expect(sa.roles).toEqual(['ROLE_SUPERADMIN']);
    // It deliberately does NOT carry ROLE_ADMIN, so an ALLOW on a superadmin
    // route can only come from the superadmin tier, never from admin bleed.
    expect(sa.roles).not.toContain('ROLE_ADMIN');
    expect(sa.expectGamesAdmin).toBe(false);
  });

  for (const route of SUPERADMIN_ALLOW_ROUTES) {
    test(`ROLE_SUPERADMIN ALLOWED ${route.probe} (${route.what}) `
      + tags({ role: 'ROLE_SUPERADMIN', layer: 'gateway' }), async () => {
      const decision = gatewayDecision(
        SUPERADMIN_GATEWAY as Gateway, route.probe, eff('e2e-superadmin'),
      );
      expect(decision, `superadmin must reach ${route.probe}`).toBe('ALLOW');
    });

    // DENY-down-cascade: ADMIN (and every other non-superadmin tier) is denied
    // every superadmin route — ROLE_SUPERADMIN is not a superset admin inherits.
    for (const role of SUPERADMIN_DENY_ROLES) {
      test(`${role} DENIED ${route.probe} (no down-cascade to superadmin) `
        + tags({ role, layer: 'gateway' }), async () => {
        const decision = gatewayDecision(
          SUPERADMIN_GATEWAY as Gateway, route.probe, [role],
        );
        expect(decision, `${role} must NOT reach the superadmin route ${route.probe}`).toBe('DENY');
      });
    }
  }

  test('a concrete ADMIN principal cannot reach ANY superadmin-gateway route '
    + tags({ role: 'ROLE_ADMIN', layer: 'gateway' }), async () => {
    // The strongest form of the down-cascade: the real e2e-admin's EFFECTIVE
    // role-set is denied every superadmin route.
    for (const route of SUPERADMIN_ALLOW_ROUTES) {
      expect(
        gatewayDecision(SUPERADMIN_GATEWAY as Gateway, route.probe, eff('e2e-admin')),
        `e2e-admin must be DENIED ${route.probe}`,
      ).toBe('DENY');
    }
  });

  test('superadmin-gateway /api/federation/** is ROLE_SUPERADMIN even though the '
    + 'be-gateway floor is ROLE_USER (gateway NAME scopes the decision) '
    + tags({ role: 'ROLE_SUPERADMIN', layer: 'gateway' }), async () => {
    const path = '/api/federation/manifest';
    // ROLE_USER reaches it on the public be-gateway floor …
    expect(gatewayDecision('hugmesh-be-gateway', path, ['ROLE_USER'])).toBe('ALLOW');
    // … but is DENIED the SAME path on the tailnet superadmin-gateway.
    expect(gatewayDecision(SUPERADMIN_GATEWAY as Gateway, path, ['ROLE_USER'])).toBe('DENY');
    expect(gatewayDecision(SUPERADMIN_GATEWAY as Gateway, path, ['ROLE_SUPERADMIN'])).toBe('ALLOW');
  });
});

// ── (ii) Cross-realm issuer isolation ───────────────────────────────────────
test.describe('RBAC: cross-realm issuer isolation (systems ⟂ games)', () => {
  test('the two realms have DISTINCT issuers '
    + tags({ layer: 'casdoor' }), async () => {
    expect(SYSTEMS_ISSUER).not.toBe(GAMES_ISSUER);
    expect(SYSTEMS_ISSUER).toBe('id.hugmesh.net');
    expect(GAMES_ISSUER).toBe('id.hugmesh.games');
  });

  test('INVARIANT: a games-realm identity carries NO systems ROLE_* into systems '
    + 'gateway routes (issuer isolation) '
    + tags({ layer: 'gateway' }), async () => {
    // A games-realm token's roles are native games roles ('player', 'admin') —
    // NEVER systems ROLE_*. Model that: present the games identity's role-set to
    // the SYSTEMS gateways. Because none of its roles are systems ROLE_*, every
    // authenticated/privileged systems route is DENY (only ROLE_ANONYMOUS rows
    // would admit, and those are public anyway).
    for (const g of GAMES_SEED_USERS) {
      // games roles are lowercase native roles; assert they are not systems roles.
      for (const r of g.roles) {
        expect(r.startsWith('ROLE_'),
          `games role "${r}" must not masquerade as a systems ROLE_*`).toBeFalsy();
      }
      const crossRealmRoles = g.roles; // what the systems gateway would "see" if it (wrongly) trusted the games token
      // Privileged systems routes across all systems gateways → DENY for a games identity.
      const probes: { gw: Gateway; path: string }[] = [
        { gw: 'hugmesh-fe-gateway', path: '/admin/usage' },
        { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access' },
        { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions' },
        { gw: 'hugmesh-be-gateway', path: '/games/api/admin/role-grants' },
        { gw: SUPERADMIN_GATEWAY as Gateway, path: '/bff/superadmin/service-store/catalog' },
      ];
      for (const p of probes) {
        expect(gatewayDecision(p.gw, p.path, crossRealmRoles),
          `games identity ${g.username} must be DENIED systems ${p.gw} ${p.path}`).toBe('DENY');
      }
    }
  });

  test('INVARIANT: a systems identity carries NO games-native role into the games '
    + 'realm — even the synced games admin is materialized natively, not by token '
    + 'bleed ' + tags({ layer: 'casdoor' }), async () => {
    // The ONLY systems→games link is the ROLE_GAMES_ADMIN→admin SYNC (a row
    // materialized in the games Casdoor by hugmesh-actions), NOT a claim the
    // systems token carries into the games gateway. So no systems ROLE_* is a
    // native games role, and the games realm grants 'admin' via the synced ROW.
    for (const u of SYSTEMS_SEED_USERS) {
      for (const r of u.roles) {
        expect(r.startsWith('ROLE_'),
          `systems role "${r}" is a systems ROLE_*, never a native games role`).toBeTruthy();
        expect(['player', 'admin'].includes(r),
          `systems role "${r}" must not be a native games role`).toBeFalsy();
      }
    }
  });

  test('catalogue-consistency: the games e2e-gamesadmin syncedFromSystems matches '
    + 'the systems ROLE_GAMES_ADMIN derivation '
    + tags({ layer: 'casdoor' }), async () => {
    // The games-side row that exists ONLY because of the sync must point at
    // ROLE_GAMES_ADMIN, and the systems user it mirrors must actually DERIVE
    // ROLE_GAMES_ADMIN ( = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD) ). This is the
    // catalogue half of the seam; the PROPAGATION proof is owned by
    // hugmesh-actions/e2e (sync-steps.ts) and is NOT duplicated here.
    const synced = GAMES_SEED_USERS.find((u) => u.syncedFromSystems);
    expect(synced, 'a games user synced from systems must exist').toBeTruthy();
    expect(synced!.syncedFromSystems).toBe('ROLE_GAMES_ADMIN');
    expect(synced!.roles).toContain('admin');

    // Same login handle on both realms, and the systems source must qualify.
    const src = systemsUser(synced!.username);
    const earnsDerived = src.roles.includes('ROLE_GAMES') &&
      (src.roles.includes('ROLE_ADMIN') || src.roles.includes('ROLE_MOD'));
    expect(earnsDerived,
      `${synced!.username}: systems source must satisfy ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD)`).toBe(true);
    expect(src.expectGamesAdmin,
      `${synced!.username}: expectGamesAdmin must agree with the derivation`).toBe(true);
    // And the EFFECTIVE systems role-set that drives the sync includes the
    // derived role (so the systems→games sync source is exactly ROLE_GAMES_ADMIN).
    expect(effectiveRoles(src.roles, src.expectGamesAdmin)).toContain('ROLE_GAMES_ADMIN');
  });
});

// ── LIVE superadmin-gateway probe — pending, like spec 14 ────────────────────
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
  // Same plain-first/org-name-fallback as spec 14's casdoorToken: Casdoor
  // resolves the password grant inside the app's organization, so "org/name"
  // answers "the user does not exist" there.
  let body = await mint(username);
  if (!body.access_token) body = await mint(`${CASDOOR_ORG}/${username}`);
  if (!body.access_token) throw new Error(`casdoor token for ${username}: ${JSON.stringify(body)}`);
  return body.access_token as string;
}

test.describe('RBAC: LIVE superadmin-gateway enforcement', () => {
  test.skip(!LIVE || !CASDOOR_URL,
    'pending: needs LIVE_GATEWAY=1 + a real SYSTEMS_CASDOOR_URL seeded with the '
    + 'superadmin role (seed-accounts.sh --roles) + the tailnet superadmin-gateway '
    + 'up (hugmesh-superadmin-gateway is README/manifest-only offline).');
  // The superadmin-gateway is TAILNET-ONLY — the compose stack never runs one,
  // so LIVE_GATEWAY=1 alone must not activate these probes against the
  // unreachable https://superadmin.localhost fallback. Probe only when the
  // operator explicitly points SUPERADMIN_GATEWAY_URL at a live instance.
  test.skip(!process.env.SUPERADMIN_GATEWAY_URL,
    'superadmin-gateway is tailnet-only (absent in the compose lane) — set '
    + 'SUPERADMIN_GATEWAY_URL to a live instance to activate these probes.');

  for (const route of SUPERADMIN_ALLOW_ROUTES) {
    for (const username of [SUPERADMIN_USERNAME, 'e2e-admin']) {
      const expected = gatewayDecision(
        SUPERADMIN_GATEWAY as Gateway, route.probe, eff(username),
      );
      test(`superadmin-gateway ${route.probe} — ${username} should be ${expected} (live) `
        + tags({ role: systemsUser(username).roles[0], layer: 'gateway' }), async () => {
        const api = await request.newContext({ ignoreHTTPSErrors: true });
        const token = await casdoorToken(api, username);
        const r = await api.get(`${SUPERADMIN_GW_URL}${route.probe}`, {
          headers: { authorization: `Bearer ${token}` },
        });
        const denied = r.status() === 401 || r.status() === 403;
        if (expected === 'DENY') {
          expect(denied, `${username} expected DENY but got ${r.status()}`).toBeTruthy();
        } else {
          expect(denied, `${username} expected ALLOW but gateway returned ${r.status()}`).toBeFalsy();
        }
        await api.dispose();
      });
    }
  }
});
