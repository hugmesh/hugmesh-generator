import { test, expect } from '@playwright/test';
import { shot } from './helpers';

test('front page loads over generated certs and gates anonymous visitors to native sign-in', async ({ page }) => {
  await page.goto('/');
  // '' has no component of its own — roleHomeGuard is a pure authgate that
  // always returns a UrlTree (app.routes.ts): anonymous -> /login, otherwise ->
  // the signed-in user's role-home remote. There is no static marketing splash
  // page any more, so the front door IS the native sign-in form.
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByRole('heading', { level: 1, name: 'Snapdragon Systems' })).toBeVisible();
  await expect(page.getByTestId('nav-login')).toBeVisible();
  await expect(page.getByTestId('login-view')).toBeVisible();
  await expect(page.getByTestId('login-username')).toBeVisible();

  await shot(page, '01-frontpage');
});
