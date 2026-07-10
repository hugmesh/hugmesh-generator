import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

// By the time this runs, earlier specs have generated real login/complete/
// invite events that the BFF wrote to ClickHouse. The admin Usage view reads
// the aggregates back. (Native login records a 'login' event — there is no
// 'register' action; the removed google/discord self-registration is gone.)
//
// Usage analytics lives inside admin-ui's own per-module menu (admin.component.ts's
// `menu()`, reached via the host's Admin profile-menu entry) — there is no
// host-level top-nav shortcut. This spec previously assumed a `nav-usage`
// testid that no longer exists anywhere in the current UI.
test('admin views live infra usage analytics (ClickHouse-backed)', async ({ page }) => {
  await onboard(page, 'admin@snapdragon.systems'); // admin role; also generates events

  await page.getByTestId('profile-trigger').click();
  await page.getByTestId('menu-admin').click();
  await expect(page.getByTestId('admin-view')).toBeVisible();
  await page.locator('[data-menu="usage"]').click();
  await expect(page.getByTestId('usage-view')).toBeVisible();

  // Active users + total events are real, non-zero aggregates.
  await expect(page.getByTestId('usage-total')).not.toHaveText('0');
  await expect(page.getByTestId('usage-active')).not.toHaveText('0');

  // Module + action breakdowns are populated (native login flow at least).
  await expect(page.getByTestId('usage-by-module').locator('[data-module="login-ui"]')).toBeVisible();
  await expect(page.getByTestId('usage-by-action').locator('[data-action="login"]')).toBeVisible();

  await shot(page, '08-usage');
});

test('non-admin cannot reach the usage view', async ({ page }) => {
  await onboard(page, 'alice@gmail.com');
  // The host's Admin profile-menu entry itself is role-gated (session.isAdmin()).
  await page.getByTestId('profile-trigger').click();
  await expect(page.getByTestId('menu-admin')).toHaveCount(0);
  // Direct navigation is also blocked server-side.
  await page.goto('/admin/usage');
  await expect(page.getByTestId('usage-view')).toHaveCount(0);
  await shot(page, '08-usage-denied');
});
