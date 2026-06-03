import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

const GMAIL = ['alice@gmail.com', 'bob@gmail.com', 'carol@gmail.com', 'dave@gmail.com', 'eve@gmail.com', 'frank@gmail.com'];
const DISCORD = ['dragoneer'];

test('admin (Casdoor admin role) invites Gmail + Discord identities', async ({ page }) => {
  // admin@snapdragon.systems is seeded with the admin role in the BFF.
  await onboard(page, 'admin@snapdragon.systems');
  await expect(page.getByTestId('nav-admin')).toBeVisible();
  await page.getByTestId('nav-admin').click();
  await expect(page.getByTestId('admin-view')).toBeVisible();

  for (const email of GMAIL) {
    await page.getByTestId('admin-email').fill(email);
    await page.getByTestId('admin-invite').click();
    await expect(page.locator(`[data-email="${email}"]`)).toBeVisible();
  }
  for (const d of DISCORD) {
    await page.getByTestId('admin-discord').fill(d);
    await page.getByTestId('admin-invite-discord').click();
    await expect(page.locator(`[data-discord="${d}"]`)).toBeVisible();
  }
  await shot(page, '02-admin-allowlist');
});
