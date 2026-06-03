import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

test('admin grants a registered user access to a namespace + sees Uptrace/observability', async ({ page }) => {
  await onboard(page, 'admin@snapdragon.systems');

  // Admin-only observability + namespace links are present.
  await expect(page.getByTestId('nav-uptrace')).toBeVisible();
  await expect(page.getByTestId('nav-uptrace')).toHaveAttribute('href', /uptrace\.snapdragon\.systems/);
  await expect(page.getByTestId('nav-namespaces')).toBeVisible();

  await page.getByTestId('nav-namespaces').click();
  await expect(page.getByTestId('ns-view')).toBeVisible();

  // Grant alice access to the backend namespace.
  await page.getByTestId('ns-user').fill('alice@gmail.com');
  await page.getByTestId('ns-select').selectOption('snapdragon-backend');
  await page.getByTestId('ns-grant').click();

  const row = page.getByTestId('ns-grants').locator('[data-user="alice@gmail.com"]');
  await expect(row).toContainText('snapdragon-backend');
  await shot(page, '09-namespace-grant');
});

test('non-admin sees no Uptrace/namespace links and is blocked from the views', async ({ page }) => {
  await onboard(page, 'bob@gmail.com');
  await expect(page.getByTestId('nav-uptrace')).toHaveCount(0);
  await expect(page.getByTestId('nav-namespaces')).toHaveCount(0);
  await page.goto('/admin/namespaces');
  await expect(page.getByTestId('ns-view')).toHaveCount(0);
  await shot(page, '09-namespace-denied');
});
