import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

// By the time this runs, earlier specs have generated real register/login/
// complete/invite events that the BFF wrote to ClickHouse. The admin Usage
// view reads the aggregates back.
test('admin views live infra usage analytics (ClickHouse-backed)', async ({ page }) => {
  await onboard(page, 'admin@snapdragon.systems'); // admin role; also generates events
  await expect(page.getByTestId('nav-usage')).toBeVisible();
  await page.getByTestId('nav-usage').click();
  await expect(page.getByTestId('usage-view')).toBeVisible();

  // Active users + total events are real, non-zero aggregates.
  await expect(page.getByTestId('usage-total')).not.toHaveText('0');
  await expect(page.getByTestId('usage-active')).not.toHaveText('0');

  // Module + action breakdowns are populated (registration flow at least).
  await expect(page.getByTestId('usage-by-module').locator('[data-module="login-ui"]')).toBeVisible();
  await expect(page.getByTestId('usage-by-action').locator('[data-action="register"]')).toBeVisible();

  await shot(page, '08-usage');
});

test('non-admin cannot reach the usage view', async ({ page }) => {
  await onboard(page, 'alice@gmail.com');
  await expect(page.getByTestId('nav-usage')).toHaveCount(0);
  await page.goto('/admin/usage');
  await expect(page.getByTestId('usage-view')).toHaveCount(0);
  await shot(page, '08-usage-denied');
});
