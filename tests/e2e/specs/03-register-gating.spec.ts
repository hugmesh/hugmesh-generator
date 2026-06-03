import { test, expect } from '@playwright/test';
import { registerOnly, shot } from './helpers';

test('Google registration is denied for an email no admin invited', async ({ page }) => {
  await registerOnly(page, 'mallory@gmail.com'); // never added to the allowlist
  await expect(page.getByTestId('login-error')).toContainText('denied');
  await shot(page, '03-register-denied');
});

test('invited user can register but Matrix/Mastodon stay locked until registration completes', async ({ page }) => {
  // frank@gmail.com was invited in 02 but we DON'T complete registration here.
  await registerOnly(page, 'frank@gmail.com');
  await expect(page.getByTestId('nav-user')).toHaveText('frank@gmail.com');
  // Two-stage gate: complete step offered; Matrix/Mastodon NOT yet available.
  await expect(page.getByTestId('nav-complete')).toBeVisible();
  await expect(page.getByTestId('nav-matrix')).toHaveCount(0);
  await expect(page.getByTestId('nav-mastodon')).toHaveCount(0);
  // Direct navigation is blocked by the registration guard.
  await page.goto('/social/matrix');
  await expect(page.getByTestId('login-view')).toBeVisible();
  await expect(page.getByTestId('matrix-view')).toHaveCount(0);
  await shot(page, '03-pending-gated');
});
