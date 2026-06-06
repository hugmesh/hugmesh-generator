import { test, expect } from '@playwright/test';
import { systemsUser } from './rbac-roles';
import { gatewayDecision, effectiveRoles } from './rbac-route-access';

// 16 — ROLE_MOD is a SIBLING of ROLE_ADMIN, never a superset.
//
// The RBAC model (and the schema.sql header) is explicit: ROLE_MOD reaches Matrix
// (PL50) + akkoma/Mastodon moderation ONLY, and is DENIED infra, logs,
// server-admin, and the snapdragon admin surfaces (/api/admin/**, /admin/**,
// /bff/admin/**). Observability (uptrace/grafana/clickhouse) has NO external
// gateway route at all, so default-deny keeps mod off it.
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
    { gw: 'snapdragon-be-gateway', path: '/api/v1/pleroma/admin/config', what: 'akkoma moderation REST' },
    { gw: 'snapdragon-be-gateway', path: '/api/pleroma/admin/users', what: 'legacy akkoma admin' },
    { gw: 'snapdragon-be-gateway', path: '/pleroma/admin/index.html', what: 'akkoma AdminFE assets' },
    { gw: 'snapdragon-be-gateway', path: '/_matrix/client/v3/sync', what: 'Matrix C-S API (mod user floor)' },
    { gw: 'snapdragon-be-gateway', path: '/api/v1/timelines/home', what: 'Mastodon REST (mod user floor)' },
    { gw: 'snapdragon-be-gateway', path: '/oauth/token', what: 'Mastodon OAuth (mod user floor)' },
  ];
  for (const c of MOD_ALLOWED) {
    test(`mod ALLOWED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, MOD)).toBe('ALLOW');
    });
  }

  // ── DENY: everything outside moderation ─────────────────────────────────
  const MOD_DENIED: { gw: any; path: string; what: string }[] = [
    { gw: 'snapdragon-be-gateway', path: '/api/admin/route-access', what: 'snapdragon admin API' },
    { gw: 'snapdragon-fe-gateway', path: '/admin/usage', what: 'admin UI' },
    { gw: 'snapdragon-fe-gateway', path: '/bff/admin/allowlist', what: 'BFF admin allowlist' },
    { gw: 'snapdragon-be-gateway', path: '/infra/vault/secret', what: 'infra/vault (no route)' },
    { gw: 'snapdragon-be-gateway', path: '/infra/logs', what: 'logs (no route)' },
    { gw: 'snapdragon-be-gateway', path: '/_synapse/admin/v1/server_version', what: 'Matrix server-admin (no route)' },
    { gw: 'snapdragon-fe-gateway', path: '/games/admin/sessions', what: 'games admin UI (mod alone ≠ games-admin)' },
    { gw: 'snapdragon-be-gateway', path: '/games/api/admin/role-grants', what: 'games admin API (mod alone ≠ games-admin)' },
  ];
  for (const c of MOD_DENIED) {
    test(`mod DENIED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, MOD)).toBe('DENY');
    });
  }

  test('mod is a SIBLING, not a superset: admin reaches admin-API where mod is denied', async () => {
    // Same path, opposite outcome — proves the deny is about the role, not the path.
    expect(gatewayDecision('snapdragon-be-gateway', '/api/admin/route-access', MOD)).toBe('DENY');
    expect(gatewayDecision('snapdragon-be-gateway', '/api/admin/route-access', ADMIN)).toBe('ALLOW');
    // ...and admin (a superset of moderation) ALSO reaches the moderation surface.
    expect(gatewayDecision('snapdragon-be-gateway', '/api/v1/pleroma/admin/config', ADMIN)).toBe('ALLOW');
  });
});
