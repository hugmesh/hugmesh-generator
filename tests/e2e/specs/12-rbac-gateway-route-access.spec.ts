import { test, expect } from '@playwright/test';
import { SYSTEMS_SEED_USERS, systemsUser } from './rbac-roles';
import { gatewayDecision, effectiveRoles, Gateway } from './rbac-route-access';

// 12 — Gateway route-access ALLOW/DENY matrix.
//
// Asserts the gateway_route_access CONTRACT (manifests/route-access/schema.sql)
// for the full systems role matrix: each seed user's EFFECTIVE role-set (granted
// roles + the derived ROLE_GAMES_ADMIN when they qualify) is run against the
// authoritative table via `gatewayDecision`, and the expected ALLOW/DENY is
// asserted at every contractually-interesting URL.
//
// WHY this is contract-level (not a live deny): the fe/be/pki gateways that
// ENFORCE this table are README-only today (Phase 8/10 — see investigation). The
// decision oracle in rbac-route-access.ts encodes schema.sql so the RBAC posture
// is locked in NOW; when a real gateway (or a mock-stack route-access enforcer)
// lands, `LIVE_GATEWAY=1` flips these to hit the running endpoint and assert the
// SAME expectations (200 vs 401/403). See 12b below for that bridge.
//
// The authoritative cases below are derived BY HAND from schema.sql + the RBAC
// model, then cross-checked against the oracle — so a bug in the oracle OR a drift
// in schema.sql surfaces here.

type Case = { gw: Gateway; path: string; user: string; expect: 'ALLOW' | 'DENY'; why: string };

const eff = (username: string) => {
  const u = systemsUser(username);
  return effectiveRoles(u.roles, u.expectGamesAdmin);
};

const CASES: Case[] = [
  // ── fe-gateway /admin/** = ROLE_ADMIN ───────────────────────────────────
  { gw: 'snapdragon-fe-gateway', path: '/admin/usage', user: 'e2e-admin', expect: 'ALLOW', why: 'admin reaches the admin UI' },
  { gw: 'snapdragon-fe-gateway', path: '/admin/usage', user: 'e2e-adminonly', expect: 'ALLOW', why: 'ROLE_ADMIN alone reaches /admin' },
  { gw: 'snapdragon-fe-gateway', path: '/admin/usage', user: 'e2e-mod', expect: 'DENY', why: 'ROLE_MOD is NOT a superset of admin' },
  { gw: 'snapdragon-fe-gateway', path: '/admin/usage', user: 'e2e-gamesonly', expect: 'DENY', why: 'plain games member denied admin UI' },
  { gw: 'snapdragon-fe-gateway', path: '/admin/usage', user: 'e2e-user', expect: 'DENY', why: 'plain user denied admin UI' },

  // ── be-gateway /api/admin/** = ROLE_ADMIN (NOT ROLE_MOD) ────────────────
  { gw: 'snapdragon-be-gateway', path: '/api/admin/route-access', user: 'e2e-admin', expect: 'ALLOW', why: 'admin reaches the admin API' },
  { gw: 'snapdragon-be-gateway', path: '/api/admin/route-access', user: 'e2e-mod', expect: 'DENY', why: 'mod DENIED the snapdragon admin API' },
  { gw: 'snapdragon-be-gateway', path: '/api/admin/route-access', user: 'e2e-user', expect: 'DENY', why: 'user DENIED the admin API' },

  // ── fe-gateway /bff/admin/** = ROLE_ADMIN ───────────────────────────────
  { gw: 'snapdragon-fe-gateway', path: '/bff/admin/allowlist', user: 'e2e-admin', expect: 'ALLOW', why: 'admin reaches the BFF admin allowlist' },
  { gw: 'snapdragon-fe-gateway', path: '/bff/admin/allowlist', user: 'e2e-mod', expect: 'DENY', why: 'mod DENIED /bff/admin (stays ROLE_ADMIN)' },

  // ── be-gateway akkoma moderation = ROLE_MOD (or ROLE_ADMIN superset) ─────
  { gw: 'snapdragon-be-gateway', path: '/api/v1/pleroma/admin/config', user: 'e2e-mod', expect: 'ALLOW', why: 'mod reaches akkoma moderation REST' },
  { gw: 'snapdragon-be-gateway', path: '/api/v1/pleroma/admin/config', user: 'e2e-admin', expect: 'ALLOW', why: 'admin (superset) reaches akkoma moderation' },
  { gw: 'snapdragon-be-gateway', path: '/api/v1/pleroma/admin/config', user: 'e2e-user', expect: 'DENY', why: 'plain user DENIED akkoma moderation' },

  // ── be-gateway Matrix/Mastodon user floor — mod is self-contained ───────
  { gw: 'snapdragon-be-gateway', path: '/_matrix/client/v3/sync', user: 'e2e-mod', expect: 'ALLOW', why: 'mod has a Matrix user floor (not auto-granted ROLE_USER)' },
  { gw: 'snapdragon-be-gateway', path: '/_matrix/client/v3/sync', user: 'e2e-user', expect: 'ALLOW', why: 'user reaches Matrix C-S API' },
  { gw: 'snapdragon-be-gateway', path: '/api/v1/timelines/home', user: 'e2e-mod', expect: 'ALLOW', why: 'mod has a Mastodon user floor' },
  { gw: 'snapdragon-be-gateway', path: '/api/v1/timelines/home', user: 'e2e-user', expect: 'ALLOW', why: 'user reaches Mastodon REST API' },

  // ── GAMES-ADMIN GATE — the heart of the requirement ─────────────────────
  // /games/admin/** (fe) + /games/api/admin/** (be) = ROLE_GAMES_ADMIN ONLY.
  { gw: 'snapdragon-fe-gateway', path: '/games/admin/sessions', user: 'e2e-gamesadmin', expect: 'ALLOW', why: 'ROLE_GAMES ∩ ROLE_ADMIN earned ROLE_GAMES_ADMIN -> reaches games admin UI' },
  { gw: 'snapdragon-fe-gateway', path: '/games/admin/sessions', user: 'e2e-gamesonly', expect: 'DENY', why: 'ROLE_GAMES alone is NOT games-admin (default-deny)' },
  { gw: 'snapdragon-fe-gateway', path: '/games/admin/sessions', user: 'e2e-adminonly', expect: 'DENY', why: 'ROLE_ADMIN alone is NOT games-admin (default-deny)' },
  { gw: 'snapdragon-fe-gateway', path: '/games/admin/sessions', user: 'e2e-mod', expect: 'DENY', why: 'ROLE_MOD alone is NOT games-admin' },
  { gw: 'snapdragon-be-gateway', path: '/games/api/admin/role-grants', user: 'e2e-gamesadmin', expect: 'ALLOW', why: 'derived ROLE_GAMES_ADMIN reaches games admin API' },
  { gw: 'snapdragon-be-gateway', path: '/games/api/admin/role-grants', user: 'e2e-gamesonly', expect: 'DENY', why: 'ROLE_GAMES alone denied games admin API' },
  { gw: 'snapdragon-be-gateway', path: '/games/api/admin/role-grants', user: 'e2e-adminonly', expect: 'DENY', why: 'ROLE_ADMIN alone denied games admin API' },

  // ── default-deny: an unmapped path is DENY for everyone, even admin ──────
  { gw: 'snapdragon-be-gateway', path: '/infra/logs', user: 'e2e-admin', expect: 'DENY', why: 'no route row -> default-deny (infra/logs has no external route)' },
  { gw: 'snapdragon-be-gateway', path: '/infra/logs', user: 'e2e-mod', expect: 'DENY', why: 'mod has no infra/logs route' },
];

test.describe('RBAC: gateway route-access ALLOW/DENY (schema.sql contract)', () => {
  for (const c of CASES) {
    test(`${c.gw} ${c.path} — ${c.user} => ${c.expect} (${c.why})`, async () => {
      const decision = gatewayDecision(c.gw, c.path, eff(c.user));
      expect(decision, `${c.user} effective roles=${JSON.stringify(eff(c.user))}: ${c.why}`).toBe(c.expect);
    });
  }

  test('ROLE_GAMES_ADMIN is the ONLY key on both games-admin rows (single role default-deny)', async () => {
    // Cross-check the gate property directly: no single granted role admits the
    // games-admin surface; only the derived intersection role does.
    for (const single of ['ROLE_GAMES', 'ROLE_ADMIN', 'ROLE_MOD', 'ROLE_USER']) {
      expect(gatewayDecision('snapdragon-fe-gateway', '/games/admin/x', [single]),
        `${single} alone must NOT reach /games/admin`).toBe('DENY');
      expect(gatewayDecision('snapdragon-be-gateway', '/games/api/admin/x', [single]),
        `${single} alone must NOT reach /games/api/admin`).toBe('DENY');
    }
    expect(gatewayDecision('snapdragon-fe-gateway', '/games/admin/x', ['ROLE_GAMES_ADMIN'])).toBe('ALLOW');
    expect(gatewayDecision('snapdragon-be-gateway', '/games/api/admin/x', ['ROLE_GAMES_ADMIN'])).toBe('ALLOW');
  });

  test('every seed user has a consistent effective role-set vs its expectGamesAdmin flag', async () => {
    for (const u of SYSTEMS_SEED_USERS) {
      const e = effectiveRoles(u.roles, u.expectGamesAdmin);
      const earns = u.roles.includes('ROLE_GAMES') &&
        (u.roles.includes('ROLE_ADMIN') || u.roles.includes('ROLE_MOD'));
      // The seed catalogue's expectGamesAdmin MUST equal what the intersection
      // rule ( ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD) ) computes from its grants.
      expect(earns, `${u.username}: expectGamesAdmin must match the intersection of its granted roles`)
        .toBe(u.expectGamesAdmin);
      expect(e.includes('ROLE_GAMES_ADMIN')).toBe(u.expectGamesAdmin);
    }
  });
});
