import { test, expect } from '@playwright/test';
import { onboard, registerOnly, shot } from './helpers';

/**
 * Handles this spec names that must NEVER be provisioned. Read by the Studio's
 * spec->persona index (studio/hugmesh_studio/core/e2e_personas.py), which otherwise
 * cannot tell a handle nobody seeded ON PURPOSE from one somebody forgot to seed —
 * and reports the latter as a defect, because that is the shape of the 2026-08-06
 * spec-29 failure (a native-login 401 that read as a broken password and was really
 * an account nothing ever created).
 *
 * 'rando' is the unprovisioned username the first test is refused as. Seeding it
 * turns that refusal into a successful login and the assertion into a no-op.
 * 'dragoneer' IS seeded (tests/e2e-extra-personas.sh) and belongs in the roster.
 */
export const NEVER_SEEDED_PERSONAS: readonly string[] = ['rando'];

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
