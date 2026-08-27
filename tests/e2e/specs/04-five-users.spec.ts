import { test, expect } from '@playwright/test';
import { onboard, loginPassword, shot } from './helpers';

const USERS = ['alice@gmail.com', 'bob@gmail.com', 'carol@gmail.com', 'dave@gmail.com', 'eve@gmail.com'];

test('five basic users fully register and reach Matrix + Mastodon via the UI', async ({ browser }) => {
  test.setTimeout(240_000); // five full onboardings (page-load each) under emulation
  for (let i = 0; i < USERS.length; i++) {
    const email = USERS[i];
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    const session = await onboard(page, email); // native sign-in (stage 1) + complete (stage 2)

    expect(session.registrationComplete).toBe(true);
    expect(session.provider).toBe('password');
    // The browser holds NO Matrix/Mastodon token (the user-bff hsproxy injects the
    // server-held token); "unlocked" is proven by the UI reaching BOTH surfaces.
    await page.getByTestId('nav-matrix').click();
    await expect(page.getByTestId('matrix-view')).toBeVisible();
    await page.getByTestId('nav-mastodon').click();
    await expect(page.getByTestId('mastodon-view')).toBeVisible();

    await shot(page, `04-user-${i + 1}-${email.split('@')[0]}`);
    await ctx.close();
  }
});

test('a returning user signs in through the native login form (records a login event)', async ({ page }) => {
  // alice was fully onboarded above; sign in via OUR username/password form as a
  // returning user (POST /bff/login — the browser is never redirected to Casdoor).
  await page.goto('/login');
  await page.getByTestId('login-username').fill('alice@gmail.com');
  await page.getByTestId('login-password').fill(loginPassword());
  await page.getByTestId('login-submit').click();
  await expect(page.getByTestId('nav-user')).toBeAttached();
  await expect(page.getByTestId('nav-matrix')).toBeVisible(); // already registered → unlocked
});
