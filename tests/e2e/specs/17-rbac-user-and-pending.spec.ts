import { test, expect, request } from '@playwright/test';
import { registerOnly, onboard, shot } from './helpers';
import { systemsUser } from './rbac-roles';
import { gatewayDecision, effectiveRoles } from './rbac-route-access';

// 17 — Plain ROLE_USER reaches user surfaces; the pending user is denied until
// approved.
//
// Two halves, both at surfaces that EXIST TODAY:
//   * USER (contract): a plain ROLE_USER reaches the Matrix/Mastodon user floors +
//     the login/social UI, and is denied every admin/mod/games-admin route. Run
//     against the schema.sql oracle.
//   * PENDING (live UI + live BFF): the two-stage registration gate. An invited-
//     but-not-completed identity (the e2e-pending analogue) can register (stage 1)
//     but is DENIED Matrix/Mastodon until registration completes — and an email no
//     admin invited is denied registration outright. This is the real gating spec
//     03 exercises; here we frame it as the RBAC "pending awaiting approval" case.

const USER = effectiveRoles(systemsUser('e2e-user').roles, systemsUser('e2e-user').expectGamesAdmin);
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@snapdragon.systems';

test.describe('RBAC: plain user surfaces (contract)', () => {
  const USER_ALLOWED = [
    { gw: 'snapdragon-be-gateway', path: '/_matrix/client/v3/sync', what: 'Matrix C-S API' },
    { gw: 'snapdragon-be-gateway', path: '/api/v1/timelines/home', what: 'Mastodon REST' },
    { gw: 'snapdragon-fe-gateway', path: '/social/matrix/room', what: 'Matrix MFE' },
    { gw: 'snapdragon-fe-gateway', path: '/social/mastodon/feed', what: 'Mastodon MFE' },
    { gw: 'snapdragon-fe-gateway', path: '/login/callback', what: 'login UI' },
    { gw: 'snapdragon-fe-gateway', path: '/bff/me/namespaces', what: 'own profile' },
  ] as const;
  for (const c of USER_ALLOWED) {
    test(`user ALLOWED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, USER)).toBe('ALLOW');
    });
  }

  const USER_DENIED = [
    { gw: 'snapdragon-fe-gateway', path: '/admin/usage', what: 'admin UI' },
    { gw: 'snapdragon-be-gateway', path: '/api/admin/route-access', what: 'admin API' },
    { gw: 'snapdragon-fe-gateway', path: '/bff/admin/allowlist', what: 'BFF admin' },
    { gw: 'snapdragon-be-gateway', path: '/api/v1/pleroma/admin/config', what: 'akkoma moderation' },
    { gw: 'snapdragon-fe-gateway', path: '/games/admin/sessions', what: 'games admin UI' },
    { gw: 'snapdragon-be-gateway', path: '/games/api/admin/role-grants', what: 'games admin API' },
  ] as const;
  for (const c of USER_DENIED) {
    test(`user DENIED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, USER)).toBe('DENY');
    });
  }
});

test.describe('RBAC: pending principal denied until approved (live two-stage gate)', () => {
  test('an un-invited identity is DENIED registration (no role granted)', async ({ page }) => {
    await registerOnly(page, 'rbac-pending-uninvited@gmail.com'); // never allowlisted
    await expect(page.getByTestId('login-error')).toContainText('denied');
    await shot(page, '17-pending-uninvited-denied');
  });

  test('an invited-but-incomplete (pending) user is gated out of Matrix/Mastodon', async ({ page, baseURL }) => {
    // Admin invites the pending identity (stage-0 approval), but the user does NOT
    // complete registration — the awaiting-approval state.
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    const adminReg = await api.post('/bff/register/google', { data: { email: ADMIN_EMAIL } });
    const adminTok = (await adminReg.json()).token;
    await api.post('/bff/admin/allowlist', {
      headers: { authorization: `Bearer ${adminTok}` },
      data: { email: 'rbac-pending@gmail.com' },
    });
    await api.dispose();

    await registerOnly(page, 'rbac-pending@gmail.com');
    await expect(page.getByTestId('nav-user')).toHaveText('rbac-pending@gmail.com');
    // Pending: complete-step offered, Matrix/Mastodon NOT yet available.
    await expect(page.getByTestId('nav-complete')).toBeVisible();
    await expect(page.getByTestId('nav-matrix')).toHaveCount(0);
    await expect(page.getByTestId('nav-mastodon')).toHaveCount(0);
    // Direct navigation is blocked by the registration guard.
    await page.goto('/social/matrix');
    await expect(page.getByTestId('login-view')).toBeVisible();
    await expect(page.getByTestId('matrix-view')).toHaveCount(0);
    await shot(page, '17-pending-gated');
  });

  test('once registration completes, the (now plain-user) identity reaches Matrix + Mastodon', async ({ page, baseURL }) => {
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    const adminReg = await api.post('/bff/register/google', { data: { email: ADMIN_EMAIL } });
    const adminTok = (await adminReg.json()).token;
    await api.post('/bff/admin/allowlist', {
      headers: { authorization: `Bearer ${adminTok}` },
      data: { email: 'rbac-approved@gmail.com' },
    });
    await api.dispose();

    const session = await onboard(page, 'rbac-approved@gmail.com'); // stage 1 + stage 2
    expect(session.registrationComplete).toBe(true);
    expect(session.roles).toContain('user');
    await expect(page.getByTestId('nav-matrix')).toBeVisible();
    await shot(page, '17-approved-unlocked');
  });
});
