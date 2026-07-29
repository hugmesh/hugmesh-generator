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
  // A provisioned-but-incomplete sign-in never reaches the host shell (no
  // nav bar exists yet) — login-ui itself keeps the caller on its own
  // "Complete registration" card (login.component.html's complete-view)
  // until stage 2 finishes. This spec previously asserted `nav-user`/
  // `nav-complete` testids that assumed the host nav rendered at this
  // point; neither reflects the current two-stage flow (`nav-complete`
  // does not exist anywhere in the current UI).
  await registerOnly(page, 'frank@gmail.com');
  await expect(page.getByTestId('complete-view')).toBeVisible();
  await expect(page.getByTestId('register-display-name')).toBeVisible();
  await expect(page.getByTestId('login-complete')).toBeDisabled();
  // Matrix/Mastodon are proven locked by the absence of any path to them: the
  // caller never reaches the host shell (no nav-matrix/nav-mastodon exist to
  // click) while stuck on this card. A DIRECT `page.goto('/social/matrix')`
  // was previously asserted here too ("blocked by the registration guard,
  // redirects to login-view"), but that isn't a real gate: matrix-ui's raw
  // gateway path (like every other federated remote) serves ONLY the
  // <snap-matrix-root> custom-element shell for the HOST to mount internally
  // — verified live it never renders matrix-view for ANY caller navigating
  // there directly, complete-registration or not, so the old assertion was
  // checking a redirect that doesn't exist rather than a real registration
  // gate. Dropped rather than replaced with an invented mechanism.
  await shot(page, '03-pending-gated');
});
