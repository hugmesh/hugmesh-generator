import { test, expect } from '@playwright/test';
import { registerOnly, shot } from './helpers';

test('native sign-in is denied for an identity no admin provisioned', async ({ page }) => {
  // Native login has no self-registration surface: an unprovisioned identity
  // simply fails to sign in (401 invalid_credentials → "Sign-in failed").
  await registerOnly(page, 'mallory@gmail.com'); // never provisioned
  await expect(page.getByTestId('login-error')).toContainText('Sign-in failed');
  await shot(page, '03-register-denied');
});

test('a provisioned user can sign in but Matrix/Mastodon stay locked until registration completes', async ({ page }) => {
  // frank@gmail.com is provisioned but we DON'T complete registration here.
  await registerOnly(page, 'frank@gmail.com');
  await expect(page.getByTestId('nav-user')).toBeAttached();
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
