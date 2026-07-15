import { test, expect, request } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';

// 13 — ROLE_ADMIN vs non-admin gating at the BFF admin API (EXISTS TODAY).
//
// The mock-bff (tests/stack/mock-bff.mjs) is the live stand-in for the snapdragon
// admin BFF behind the gateway. It already enforces the ROLE_ADMIN surface
// (/bff/admin/**) at the application layer: admin -> 200, everyone else -> 403.
// This spec asserts that gate end-to-end through the served origin, for the FULL
// set of admin-protected BFF endpoints — the systems realm's ROLE_ADMIN contract
// at a surface that runs in the rootless mock stack right now.
//
// NOTE on identity (NATIVE login): the browser's only auth is the opaque httpOnly
// `bff_session` cookie minted by POST /bff/login — no bearer token is ever exposed
// to the caller. The mock grants the admin role IFF the login username is in
// ADMIN_EMAILS (default admin@snapdragon.systems); a real Casdoor would carry the
// ROLE_ADMIN claim on the session instead — the assertion (admin 200 / non-admin
// 403) is identical. Each Playwright request context keeps its OWN cookie jar, so
// "logged-in as admin" vs "logged-in as a plain user" vs "anonymous" are just
// three separate contexts. The non-admin principal here is a plain user — the SAME
// posture a ROLE_MOD / ROLE_GAMES / ROLE_USER principal must have against the admin
// API (mod/games are siblings of admin, never supersets).

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@snapdragon.systems';
// The deterministic native password every seeded/invited persona signs in with —
// mirrors the mock-bff LOGIN_PASSWORD and the e2e helper (E2E_PASSWORD ?? 'e2e-pass').
const LOGIN_PASSWORD = process.env.E2E_PASSWORD || 'e2e-pass';

// Every admin-only BFF endpoint the mock enforces (mirrors mock-bff routeAccess
// + the /bff/admin/** route-access row). GET is non-mutating, safe to probe.
const ADMIN_GET_ENDPOINTS = [
  '/bff/admin/allowlist',
  '/bff/admin/usage',
  '/bff/admin/namespace-access',
  '/bff/admin/route-access',
  '/bff/admin/isos',
];

// Native sign-in through OUR /bff/login: the opaque httpOnly bff_session cookie is
// stored in THIS request context's cookie jar and rides every subsequent /bff/**
// call automatically (credentials are implicit to the context; no bearer token is
// ever handed to the caller). An un-provisioned username 401s.
async function loginAs(api: APIRequestContext, username: string, password = LOGIN_PASSWORD): Promise<void> {
  const r = await api.post('/bff/login', { data: { username, password } });
  expect(r.status(), `native login ${username} -> ${r.status()}`).toBe(200);
}

test.describe('RBAC: BFF admin API gating (ROLE_ADMIN surface, exists today)', () => {
  test('admin principal reaches every /bff/admin/** endpoint (200)', async ({ baseURL }) => {
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await loginAs(api, ADMIN_EMAIL);
    for (const ep of ADMIN_GET_ENDPOINTS) {
      const r = await api.get(ep);
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
    // Admin (its own context/cookie) invites a plain gmail user — the invite
    // PROVISIONS a native account with roles ['user'] so it can sign in.
    const adminApi = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await loginAs(adminApi, ADMIN_EMAIL);
    const invite = await adminApi.post('/bff/admin/allowlist', { data: { email: 'rbac-plain@gmail.com' } });
    expect(invite.ok()).toBeTruthy();

    // The invited user signs in natively in its OWN context (separate cookie jar).
    const userApi = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await loginAs(userApi, 'rbac-plain@gmail.com');

    for (const ep of ADMIN_GET_ENDPOINTS) {
      const r = await userApi.get(ep);
      expect(r.status(), `plain-user GET ${ep}`).toBe(403);
    }
    // And the mutating admin write is denied too.
    const w = await userApi.post('/bff/admin/allowlist', { data: { email: 'should-not@gmail.com' } });
    expect(w.status(), 'plain-user POST /bff/admin/allowlist').toBe(403);
    await userApi.dispose();
    await adminApi.dispose();
  });
});
