import { test, expect, request } from '@playwright/test';
import { registerOnly, onboard, LOGIN_PASSWORD, shot } from './helpers';
import { systemsUser } from './rbac-roles';
import { gatewayDecision, effectiveRoles } from './rbac-route-access';

// 17 — Plain ROLE_USER reaches user surfaces; the pending user is denied until
// approved.
//
// Two halves, both at surfaces that EXIST TODAY:
//   * USER (contract): a plain ROLE_USER reaches the login/social-shell UI + its
//     own profile, and is denied every admin/mod/games-admin route AND (since
//     commit 0100d3b removed the broad ROLE_USER homeserver floor) the Matrix/
//     Mastodon HOMESERVER BACKEND surfaces on the be-gateway — those now require
//     the per-platform ROLE_MATRIX/ROLE_MASTODON access role. The "a plain member
//     reaches their own homeserver" intent is asserted separately below with the
//     dedicated e2e-matrix/e2e-mastodon platform-access personas (rbac-roles.ts),
//     which are the real successor to the old bare-ROLE_USER expectation.
//   * PENDING (live UI + live BFF): the two-stage registration gate. An invited-
//     but-not-completed identity (the e2e-pending analogue) can register (stage 1)
//     but is DENIED Matrix/Mastodon until registration completes — and an email no
//     admin invited is denied registration outright. This is the real gating spec
//     03 exercises; here we frame it as the RBAC "pending awaiting approval" case.

const USER = effectiveRoles(systemsUser('e2e-user').roles, systemsUser('e2e-user').expectGamesAdmin);
const MATRIX_USER = effectiveRoles(systemsUser('e2e-matrix').roles, systemsUser('e2e-matrix').expectGamesAdmin);
const MASTODON_USER = effectiveRoles(systemsUser('e2e-mastodon').roles, systemsUser('e2e-mastodon').expectGamesAdmin);
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@snapdragon.systems';

test.describe('RBAC: plain user surfaces (contract)', () => {
  const USER_ALLOWED = [
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
    // Homeserver BACKEND surfaces — REMOVED from the ROLE_USER floor by commit
    // 0100d3b; a plain member without the platform-access role is now denied.
    { gw: 'snapdragon-be-gateway', path: '/_matrix/client/v3/sync', what: 'Matrix C-S API (needs ROLE_MATRIX)' },
    { gw: 'snapdragon-be-gateway', path: '/api/v1/timelines/home', what: 'Mastodon REST (needs ROLE_MASTODON)' },
  ] as const;
  for (const c of USER_DENIED) {
    test(`user DENIED ${c.path} (${c.what})`, async () => {
      expect(gatewayDecision(c.gw, c.path, USER)).toBe('DENY');
    });
  }
});

test.describe('RBAC: platform-access member reaches their own homeserver (contract)', () => {
  // The real successor to the old "plain ROLE_USER reaches Matrix/Mastodon"
  // expectation: a member granted the per-platform access role reaches their own
  // homeserver's backend surface (commit 0100d3b). e2e-matrix/e2e-mastodon hold
  // ROLE_MATRIX/ROLE_MASTODON respectively (+ ROLE_USER), matching rbac-roles.ts.
  test('e2e-matrix (ROLE_MATRIX) ALLOWED /_matrix/client/v3/sync (Matrix C-S API)', async () => {
    expect(gatewayDecision('snapdragon-be-gateway', '/_matrix/client/v3/sync', MATRIX_USER)).toBe('ALLOW');
  });
  test('e2e-mastodon (ROLE_MASTODON) ALLOWED /api/v1/timelines/home (Mastodon REST)', async () => {
    expect(gatewayDecision('snapdragon-be-gateway', '/api/v1/timelines/home', MASTODON_USER)).toBe('ALLOW');
  });
});

test.describe('RBAC: pending principal denied until approved (live two-stage gate)', () => {
  test('an un-provisioned identity is DENIED native sign-in (no role granted)', async ({ page }) => {
    await registerOnly(page, 'rbac-pending-uninvited@gmail.com'); // never provisioned
    await expect(page.getByTestId('login-error')).toContainText('Sign-in failed');
    await shot(page, '17-pending-uninvited-denied');
  });

  test('an invited-but-incomplete (pending) user is gated out of Matrix/Mastodon', async ({ page, baseURL }) => {
    // Admin invites the pending identity (stage-0 approval), but the user does NOT
    // complete registration — the awaiting-approval state. The admin authenticates
    // natively: POST /bff/login mints the httpOnly bff_session cookie into this API
    // context (no browser token), which the allowlist POST then rides.
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await api.post('/bff/login', { data: { username: ADMIN_EMAIL, password: LOGIN_PASSWORD } });
    const xsrf = (await api.storageState()).cookies.find((c) => c.name === 'XSRF-TOKEN')?.value;
    await api.post('/bff/admin/allowlist', {
      headers: xsrf ? { 'X-CSRF-TOKEN': xsrf } : {},
      data: { email: 'rbac-pending@gmail.com' },
    });
    await api.dispose();

    await registerOnly(page, 'rbac-pending@gmail.com');
    await expect(page.getByTestId('nav-user')).toBeAttached();
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
    await api.post('/bff/login', { data: { username: ADMIN_EMAIL, password: LOGIN_PASSWORD } });
    const xsrf = (await api.storageState()).cookies.find((c) => c.name === 'XSRF-TOKEN')?.value;
    await api.post('/bff/admin/allowlist', {
      headers: xsrf ? { 'X-CSRF-TOKEN': xsrf } : {},
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
