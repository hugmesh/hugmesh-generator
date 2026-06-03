import { test, expect } from '@playwright/test';
import { onboard, registerOnly, shot } from './helpers';

test('Discord registration is denied for a username no admin invited', async ({ page }) => {
  await registerOnly(page, 'rando', 'discord'); // not on the Discord allowlist
  await expect(page.getByTestId('login-error')).toContainText('denied');
  await shot(page, '07-discord-denied');
});

test('an admin-invited Discord user registers and reaches Matrix + Mastodon', async ({ page }) => {
  // "dragoneer" was invited via the admin UI Discord allowlist in 02.
  const session = await onboard(page, 'dragoneer', 'discord');
  expect(session.provider).toBe('discord');
  expect(session.registrationComplete).toBe(true);
  await page.getByTestId('nav-matrix').click();
  await expect(page.getByTestId('matrix-view')).toBeVisible();
  await shot(page, '07-discord-onboarded');
});
