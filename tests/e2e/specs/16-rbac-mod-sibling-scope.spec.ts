import { test, expect } from '@playwright/test';
import { systemsUser } from './rbac-roles';
import { gatewayDecision, effectiveRoles } from './rbac-route-access';

// 16 — ROLE_MOD is a SIBLING of ROLE_ADMIN, never a superset.
//
// The RBAC model (and the schema.sql header) is explicit: ROLE_MOD reaches Matrix
// (PL50) + akkoma/Mastodon moderation ONLY, and is DENIED infra, logs,
// server-admin, and the hugmesh admin surfaces (/api/admin/**, /admin/**,
// /bff/admin/**). Observability (uptrace/grafana/clickhouse) has NO external
// gateway route at all — see the UNGOVERNED block below for what that actually
// means, which is NOT what this comment used to claim.
//
// This asserts the full mod posture against the schema.sql contract oracle. The
// application-layer half (mod DENIED the BFF admin API) is covered live in spec
// 13 (non-admin -> 403). The Matrix UI's kick/power-level controls are gated by
// MATRIX power levels, not the Casdoor ROLE_MOD, so they intentionally do NOT
// stand in for this — see the PENDING stub in spec 18 for the app-level ROLE_MOD
// moderation UI when it lands.

const MOD = effectiveRoles(systemsUser('e2e-mod').roles, systemsUser('e2e-mod').expectGamesAdmin);
const ADMIN = effectiveRoles(systemsUser('e2e-admin').roles, systemsUser('e2e-admin').expectGamesAdmin);

test.describe('RBAC: ROLE_MOD sibling scope (reaches moderation, denied infra/admin)', () => {
  // ── ALLOW: the moderation surfaces a mod MUST reach ─────────────────────
  const MOD_ALLOWED: { gw: any; path: string; what: string }[] = [
    { gw: 'hugmesh-be-gateway', path: '/api/v1/pleroma/admin/config', what: 'akkoma moderation REST' },
    { gw: 'hugmesh-be-gateway', path: '/api/pleroma/admin/users', what: 'legacy akkoma admin' },
    { gw: 'hugmesh-be-gateway', path: '/pleroma/admin/index.html', what: 'akkoma AdminFE assets' },
    { gw: 'hugmesh-be-gateway', path: '/_matrix/client/v3/sync', what: 'Matrix C-S API (mod superset on the ROLE_MATRIX-gated floor)' },
    { gw: 'hugmesh-be-gateway', path: '/api/v1/timelines/home', what: 'Mastodon REST (mod superset on the ROLE_MASTODON-gated floor)' },
    { gw: 'hugmesh-be-gateway', path: '/oauth/token', what: 'Mastodon OAuth (mod superset on the ROLE_MASTODON-gated floor)' },
    // /_synapse/** is the host-scoped Synapse-compat catch-all added by commit
    // 0100d3b (ROLE_MATRIX/ROLE_MOD/ROLE_ADMIN) — it is the GENERAL client
    // surface, not a Matrix-admin-specific row (Matrix admin is enforced by
    // admin-room membership, not an HTTP surface — see schema.sql), so mod (a
    // paired superset) reaches it like any other homeserver floor row.
    { gw: 'hugmesh-be-gateway', path: '/_synapse/client/versions', what: 'Synapse-compat surface (mod superset)' },
  ];
  for (const c of MOD_ALLOWED) {
    test(`mod ALLOWED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, MOD)).toBe('ALLOW');
    });
  }

  // ── DENY: everything outside moderation ─────────────────────────────────
  const MOD_DENIED: { gw: any; path: string; what: string }[] = [
    { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access', what: 'hugmesh admin API' },
    { gw: 'hugmesh-fe-gateway', path: '/admin/usage', what: 'admin UI' },
    { gw: 'hugmesh-fe-gateway', path: '/bff/admin/allowlist', what: 'BFF admin allowlist' },
    // NOTE: /_synapse/admin/v1/server_version is NOT here — /_synapse/** (added by
    // commit 0100d3b) is a GENERAL host-scoped Synapse-compat catch-all, not a
    // Matrix-admin-specific row, so mod (a paired superset) reaches it; see the
    // MOD_ALLOWED /_synapse/client/versions case above. Matrix admin itself is
    // enforced by admin-room membership (tuwunel-admin-sync), not an HTTP surface
    // gated by a route row.
    { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions', what: 'games admin UI (mod alone ≠ games-admin)' },
    { gw: 'hugmesh-be-gateway', path: '/games/api/admin/role-grants', what: 'games admin API (mod alone ≠ games-admin)' },
  ];
  for (const c of MOD_DENIED) {
    test(`mod DENIED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, MOD)).toBe('DENY');
    });
  }

  // ── UNGOVERNED: no row at all is NOT a deny, and saying so was a lie ──────
  //
  // These two cases used to sit in MOD_DENIED above with the comment "default-deny
  // keeps mod off it". That was FALSE for this gateway and the falsehood was
  // load-bearing: it is exactly the belief that made the old oracle return DENY
  // for every path the mirror had drifted away from, including the entire
  // /bff/user/** profile+password surface.
  //
  // GatewayRouteAccessService.decide() returns NO_RULE for an unmatched path
  // (:185) and GatewayRouteAccessFilter rejects ONLY on Decision.DENY (:345,
  // javadoc :68-70 "ALLOW / NO_RULE -> forward"). So the route-access TABLE does
  // not wall /infra/** at all. What walls it is that NO GATEWAY ROUTES IT: neither
  // specs/cluster/apps/20-gateway-be.yaml nor tests/stack/gateway-routes/be/
  // application-routes.yml carries an /infra route, so SCG answers its own
  // no-route-matched 404 and the request never leaves the gateway.
  //
  // Asserting the truth here is what makes the assertion useful: if someone ever
  // ADDS an /infra/** route without adding a governing row, this flips to
  // NO_RULE-with-a-route — a real hole — and the mod posture below is the place
  // that has to notice.
  const MOD_UNGOVERNED: { gw: any; path: string; what: string }[] = [
    { gw: 'hugmesh-be-gateway', path: '/infra/vault/secret', what: 'infra/vault — no route, no row' },
    { gw: 'hugmesh-be-gateway', path: '/infra/logs', what: 'logs — no route, no row' },
  ];
  for (const c of MOD_UNGOVERNED) {
    test(`mod: ${c.path} is UNGOVERNED by the route table (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, MOD)).toBe('NO_RULE');
    });
  }

  test('mod is a SIBLING, not a superset: admin reaches admin-API where mod is denied', async () => {
    // Same path, opposite outcome — proves the deny is about the role, not the path.
    expect(gatewayDecision('hugmesh-be-gateway', '/api/admin/route-access', MOD)).toBe('DENY');
    expect(gatewayDecision('hugmesh-be-gateway', '/api/admin/route-access', ADMIN)).toBe('ALLOW');
    // ...and admin (a superset of moderation) ALSO reaches the moderation surface.
    expect(gatewayDecision('hugmesh-be-gateway', '/api/v1/pleroma/admin/config', ADMIN)).toBe('ALLOW');
  });
});
