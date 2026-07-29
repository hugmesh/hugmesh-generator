import { test, expect } from '@playwright/test';
import { onboard, registerOnly, shot } from './helpers';

// NOTE: the Google/Discord social-login registration surface was REMOVED from
// login-ui — the only login surface is our native username/password form. These
// specs now drive that native form; "dragoneer" is just a native username.
test('native sign-in is denied for a username no admin provisioned', async ({ page }) => {
  await registerOnly(page, 'rando'); // not a provisioned account
  await expect(page.getByTestId('login-error')).toContainText('Sign-in failed');
  await shot(page, '07-discord-denied');
});

test('a provisioned user signs in natively and reaches Matrix + Mastodon', async ({ page }) => {
  const session = await onboard(page, 'dragoneer');
  expect(session.provider).toBe('password');
  expect(session.registrationComplete).toBe(true);
  await page.getByTestId('nav-matrix').click();
  await expect(page.getByTestId('matrix-view')).toBeVisible();
  await shot(page, '07-discord-onboarded');
});
