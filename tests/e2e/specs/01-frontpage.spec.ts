import { test, expect } from '@playwright/test';
import { shot } from './helpers';

test('front page loads over generated certs and gates anonymous visitors to native sign-in', async ({ page }) => {
  await page.goto('/');
  // '' has no component of its own — roleHomeGuard is a pure authgate that
  // always returns a UrlTree (app.routes.ts): anonymous -> /login, otherwise ->
  // the signed-in user's role-home remote. There is no static marketing splash
  // page any more, so the front door IS the native sign-in form.
  await expect(page).toHaveURL(/\/login/);
  // The h1 is the shell's brand mark, and it reads exactly "HugMesh" — one word.
  // This assertion used to name a two-word brand, which was a straggler from the
  // marketing splash page #273 deleted: that commit retired the OTHER splash
  // assertions and left this one behind, pointing at a heading that no longer
  // renders anywhere. The rebrand then mapped it Snapdragon Systems -> HugMesh
  // Systems faithfully, preserving a string the app has never emitted. Nothing
  // caught it because spec 01 had never been run against a live cluster until
  // 2026-08-06 — the same reason the whole GitOps payload's breakage went unseen.
  // Verified against the served page: "HugMesh" is the only brand string in it,
  // and the sign-in region's own heading is an h2 ("Sign in to hugmesh.systems").
  // Keep asserting the h1: it is the cheapest proof the host shell actually
  // mounted, as opposed to serving index.html and failing to bootstrap.
  await expect(page.getByRole('heading', { level: 1, name: 'HugMesh' })).toBeVisible();
  await expect(page.getByTestId('nav-login')).toBeVisible();
  await expect(page.getByTestId('login-view')).toBeVisible();
  await expect(page.getByTestId('login-username')).toBeVisible();

  await shot(page, '01-frontpage');
});
