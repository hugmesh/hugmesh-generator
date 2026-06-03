import { test, expect } from '@playwright/test';
import { shot } from './helpers';

test('front page loads over generated certs with generated values', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByTestId('brand')).toHaveText('snapdragon.systems');
  await expect(page.getByTestId('welcome')).toBeVisible();
  await expect(page.getByTestId('nav-login')).toBeVisible();

  // The generated runtime values were injected into the page.
  const values = await page.evaluate(() => (window as any).__SNAP_VALUES__);
  expect(values.clusterDomain).toBe('snapdragon.systems');
  expect(values.casdoorIssuer).toContain('id.snapdragon.systems');
  expect(values.sessionSecret).toBeTruthy();

  await shot(page, '01-frontpage');
});
