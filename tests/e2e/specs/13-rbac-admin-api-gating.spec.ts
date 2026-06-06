import { test, expect, request } from '@playwright/test';

// 13 — ROLE_ADMIN vs non-admin gating at the BFF admin API (EXISTS TODAY).
//
// The mock-bff (tests/stack/mock-bff.mjs) is the live stand-in for the snapdragon
// admin BFF behind the gateway. It already enforces the ROLE_ADMIN surface
// (/bff/admin/**) at the application layer: admin -> 200, everyone else -> 403.
// This spec asserts that gate end-to-end through the served origin, for the FULL
// set of admin-protected BFF endpoints — the systems realm's ROLE_ADMIN contract
// at a surface that runs in the rootless mock stack right now.
//
// NOTE on identity: the mock-bff grants the admin role IFF the login email is in
// ADMIN_EMAILS (default admin@snapdragon.systems). A real Casdoor would carry the
// ROLE_ADMIN claim in the JWT instead; the assertion (admin 200 / non-admin 403)
// is identical. The non-admin principal here is a plain user — the SAME posture a
// ROLE_MOD / ROLE_GAMES / ROLE_USER principal must have against the admin API
// (mod/games are siblings of admin, never supersets).

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@snapdragon.systems';

// Every admin-only BFF endpoint the mock enforces (mirrors mock-bff routeAccess
// + the /bff/admin/** route-access row). GET is non-mutating, safe to probe.
const ADMIN_GET_ENDPOINTS = [
  '/bff/admin/allowlist',
  '/bff/admin/usage',
  '/bff/admin/namespace-access',
  '/bff/admin/route-access',
  '/bff/admin/isos',
];

async function tokenFor(api: import('@playwright/test').APIRequestContext, email: string): Promise<string> {
  // register/google self-allows the admin email; for a non-allowlisted user we
  // register via the admin first. Here we only need an admin token + a plain
  // user token, both of which the mock issues from register/google when invited.
  const r = await api.post('/bff/register/google', { data: { email } });
  expect(r.ok(), `register ${email} -> ${r.status()}`).toBeTruthy();
  return (await r.json()).token as string;
}

test.describe('RBAC: BFF admin API gating (ROLE_ADMIN surface, exists today)', () => {
  test('admin principal reaches every /bff/admin/** endpoint (200)', async ({ baseURL }) => {
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    const token = await tokenFor(api, ADMIN_EMAIL);
    for (const ep of ADMIN_GET_ENDPOINTS) {
      const r = await api.get(ep, { headers: { authorization: `Bearer ${token}` } });
      expect(r.status(), `admin GET ${ep}`).toBe(200);
    }
    await api.dispose();
  });

  test('unauthenticated caller is DENIED every /bff/admin/** endpoint (403)', async ({ baseURL }) => {
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    for (const ep of ADMIN_GET_ENDPOINTS) {
      const r = await api.get(ep);
      expect(r.status(), `anon GET ${ep}`).toBe(403);
    }
    await api.dispose();
  });

  test('a non-admin (plain ROLE_USER) is DENIED every /bff/admin/** endpoint (403)', async ({ baseURL }) => {
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    // Admin invites a plain gmail user, who then registers and gets ['user'].
    const adminTok = await tokenFor(api, ADMIN_EMAIL);
    const invite = await api.post('/bff/admin/allowlist', {
      headers: { authorization: `Bearer ${adminTok}` },
      data: { email: 'rbac-plain@gmail.com' },
    });
    expect(invite.ok()).toBeTruthy();
    const userTok = await tokenFor(api, 'rbac-plain@gmail.com');

    for (const ep of ADMIN_GET_ENDPOINTS) {
      const r = await api.get(ep, { headers: { authorization: `Bearer ${userTok}` } });
      expect(r.status(), `plain-user GET ${ep}`).toBe(403);
    }
    // And the mutating admin write is denied too.
    const w = await api.post('/bff/admin/allowlist', {
      headers: { authorization: `Bearer ${userTok}` },
      data: { email: 'should-not@gmail.com' },
    });
    expect(w.status(), 'plain-user POST /bff/admin/allowlist').toBe(403);
    await api.dispose();
  });
});
