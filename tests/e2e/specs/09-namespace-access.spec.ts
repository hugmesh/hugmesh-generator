import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

// Namespace access lives inside admin-ui's own per-module menu (admin.component.ts's
// `menu()`, reached via the host's Admin profile-menu entry) — there is no
// host-level top-nav shortcut. This spec previously assumed a `nav-namespaces`
// testid that no longer exists anywhere in the current UI.
//
// Uptrace observability is server-configured (BffService.uptraceUrl(), wired to
// https://uptrace.hugmesh.systems by default) but has NO UI entry point
// anywhere in admin-ui or the host — no `nav-uptrace` equivalent was ever built.
// This spec no longer asserts it (queued as an open product gap, not a test bug).
test('admin grants a registered user access to a namespace', async ({ page }) => {
  await onboard(page, 'admin@hugmesh.systems');

  await page.getByTestId('profile-trigger').click();
  await page.getByTestId('menu-admin').click();
  await expect(page.getByTestId('admin-view')).toBeVisible();
  await page.locator('[data-menu="namespaces"]').click();
  await expect(page.getByTestId('ns-view')).toBeVisible();

  // Grant alice access to the backend namespace.
  await page.getByTestId('ns-user').fill('alice@gmail.com');
  await page.getByTestId('ns-select').selectOption('hugmesh-backend');
  await page.getByTestId('ns-grant').click();

  const row = page.getByTestId('ns-grants').locator('[data-user="alice@gmail.com"]');
  await expect(row).toContainText('hugmesh-backend');
  await shot(page, '09-namespace-grant');
});

test('non-admin is blocked from the namespace access view', async ({ page }) => {
  await onboard(page, 'bob@gmail.com');
  // The host's Admin profile-menu entry itself is role-gated (session.isAdmin()).
  await page.getByTestId('profile-trigger').click();
  await expect(page.getByTestId('menu-admin')).toHaveCount(0);
  // Direct navigation is also blocked server-side.
  await page.goto('/admin/namespaces');
  await expect(page.getByTestId('ns-view')).toHaveCount(0);
  await shot(page, '09-namespace-denied');
});
