import { test, expect } from '@playwright/test';
import { systemsUser, passwordFor } from './rbac-roles';
import { shot, describeLoginFailure } from './helpers';

// 27 — NATIVE LOGIN coverage (the direct successor to the deleted social-login).
//
// The login-ui's OWN username/password form is the ONLY login surface: it POSTs
// { username, password } to `POST /bff/login` (credentials: include); the user-bff
// runs Casdoor's INTERNAL /api/login + PKCE code-exchange SERVER-SIDE and mints the
// opaque httpOnly `bff_session` cookie (token prefixed `bff_`). The browser is
// NEVER redirected to Casdoor and never receives a JWT/access token.
//
// The rest of the suite drove the REMOVED Google/Discord social-login testids
// (login-email/login-google-register/login-discord/-register/login-signin) and had
// ZERO coverage of this native /bff/login contract — this spec is that coverage.
test.describe('native login: our own form drives /bff/login (Casdoor never browser-exposed)', () => {
  test('POST /bff/login mints an httpOnly bff_session cookie; no navigation to a Casdoor origin', async ({ page, context }) => {
    // A real seeded native account (deterministic e2e password) so the sign-in
    // actually mints a session on the live run.
    const user = systemsUser('e2e-user');

    // Record every main-frame navigation so we can prove none hit Casdoor.
    const navigated: string[] = [];
    page.on('framenavigated', (f) => { if (f === page.mainFrame()) navigated.push(f.url()); });

    await page.goto('/login');

    // The ONLY login surface is our native username/password form. The deleted
    // social-login / OIDC-redirect testids must be ABSENT (login-ui pins them so).
    await expect(page.getByTestId('login-view')).toBeVisible();
    await expect(page.getByTestId('login-username')).toBeVisible();
    await expect(page.getByTestId('login-password')).toBeVisible();
    await expect(page.getByTestId('login-submit')).toBeVisible();
    for (const gone of [
      'login-email', 'login-google-register', 'login-discord', 'login-discord-register', 'login-signin',
    ]) {
      await expect(page.getByTestId(gone)).toHaveCount(0);
    }

    // The form POSTs /bff/login; capture the response to assert it succeeded.
    const loginPost = page.waitForResponse(
      (r) => r.url().includes('/bff/login') && r.request().method() === 'POST',
    );
    await page.getByTestId('login-username').fill(user.username);
    await page.getByTestId('login-password').fill(passwordFor(user));
    await page.getByTestId('login-submit').click();

    const resp = await loginPost;
    // On a refusal, name WHY (a Casdoor lockout reads differently from a wrong
    // password — hugmesh-generator#473); this test's own failure on 2026-09-04
    // said only "Received: 401".
    const why = resp.status() < 400 ? '' : ` — ${describeLoginFailure(resp.status(), await resp.text().catch(() => ''))}`;
    expect(resp.status(), `POST /bff/login succeeds${why}`).toBeLessThan(400);

    // The opaque session cookie was minted SERVER-SIDE: httpOnly `bff_session`,
    // whose value is the raw `bff_` token. The browser holds no JWT/access token.
    await expect
      .poll(async () => (await context.cookies()).some((c) => c.name === 'bff_session' && c.httpOnly))
      .toBe(true);
    const bff = (await context.cookies()).find((c) => c.name === 'bff_session');
    expect(bff?.value.startsWith('bff_'), 'opaque bff_ session token').toBe(true);

    // The browser NEVER navigated to a Casdoor origin — native PKCE is server-side.
    for (const url of navigated) {
      expect(url, `must not visit Casdoor: ${url}`).not.toMatch(/casdoor|id\.hugmesh\.net/i);
    }

    await shot(page, '27-native-login');
  });
});
