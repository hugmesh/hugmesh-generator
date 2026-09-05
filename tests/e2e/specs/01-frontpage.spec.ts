import { test, expect } from '@playwright/test';
import { SHELL_AFTER_PROVISION_MS, personaPassword, registerOnly, shot } from './helpers';

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
  // renders anywhere. The rebrand then mapped it HugMesh Systems -> HugMesh
  // Systems faithfully, preserving a string the app has never emitted. Nothing
  // caught it because spec 01 had never been run against a live cluster until
  // 2026-08-06 — the same reason the whole GitOps payload's breakage went unseen.
  // Verified against the served page: "HugMesh" is the only brand string in it,
  // and the sign-in region's own heading is an h2 ("Sign in to hugmesh.net").
  // Keep asserting the h1: it is the cheapest proof the host shell actually
  // mounted, as opposed to serving index.html and failing to bootstrap.
  await expect(page.getByRole('heading', { level: 1, name: 'HugMesh' })).toBeVisible();
  await expect(page.getByTestId('login-view')).toBeVisible();
  await expect(page.getByTestId('login-username')).toBeVisible();

  // LOGIN-PAGE CHROME GATE. While the login remote is what the outlet shows and
  // nobody is signed in, the host shell unmounts the WHOLE menubar — Home and
  // Sign-in included: 'Home' would lead straight back to the authgate that put
  // the visitor here, and 'Sign in' points at the page already on screen.
  // hugmesh-host-shell issue #19 (operator requirement, 2026-08-19: "when the
  // login page is up, hide the menu/announcements bar entirely"), landed in
  // host-shell PR #21 and pinned by menu.component.spec.ts "hides the WHOLE bar
  // (not a Home-only stub) on /login while signed out". This spec used to assert
  // `nav-login` VISIBLE here — the pre-#19 anonymous bar — and failed on every
  // live run since (PW-01 in the 2026-09-01/02/04 baselines): the assertion
  // outlived the product decision it described.
  //
  // `nav-home` is the entry the bar renders in EVERY session state, so its
  // absence is what "no bar" means; `nav-login` is the entry this test used to
  // want. Both counts come AFTER login-view is visible so they cannot pass on a
  // page that simply has not rendered yet. The POSITIVE control — the same
  // testids DO resolve once a session exists and the outlet is off the login
  // page — is the next test, in this file on purpose: an absence assertion
  // without a sibling presence assertion cannot tell "gated" from "renamed".
  await expect(page.getByTestId('nav-home')).toHaveCount(0);
  await expect(page.getByTestId('nav-login')).toHaveCount(0);

  await shot(page, '01-frontpage');
});

test('the menubar is gated on the login page only: signed in and off the home page it is back, minus Sign in', async ({ page }) => {
  // POSITIVE CONTROL for the gate assertions above. e2e-user is the plain seeded
  // member (ROLE_USER, registration complete), so the native form takes the
  // returning-user branch: POST /bff/login -> hydrate -> provision -> HARD nav to
  // '/' -> the shell cold-boots and roleHomeGuard lands a member on /user. That
  // chain is what SHELL_AFTER_PROVISION_MS is sized for (see helpers.ts).
  await registerOnly(page, 'e2e-user', personaPassword('e2e-user'));
  // /user is the signed-in HOME, and on home the shell hides the bar AGAIN and
  // renders the same entries as service CARDS instead (issue #19 comment
  // 2026-08-19, MenuComponent.homeCardsActive) — so the landing page is not
  // where the bar can be asserted either. The bar is briefly on screen at '/'
  // before the guard resolves (measured 2026-09-05: ~0.5s), which is why
  // "nav-matrix visible straight after login" passes elsewhere in this suite;
  // this test waits for the cards instead, so it asserts a settled state.
  await expect(page.getByTestId('home-services-nav')).toBeVisible({ timeout: SHELL_AFTER_PROVISION_MS });
  // Following a card is a CLIENT-SIDE navigation to a non-home, non-login route
  // — the state in which the bar renders. It has to be in-app: a page.goto()
  // deep link to /social/matrix on the compose stack does not boot the host
  // shell at all (measured 2026-09-05: no h1, no bar), so it could only ever
  // prove the absence it is here to refute.
  await page.getByTestId('home-card-nav-matrix').click();
  await expect(page, 'the Matrix service card must navigate in-app (it is a disabled button when '
    + 'the service is not installed or the session is not fully registered)').toHaveURL(/\/social\/matrix/);
  await expect(page.getByTestId('nav-home')).toBeVisible();
  // Signed in, so the Sign-in entry stays gone — this time by the entry's own
  // `@if (!session.loggedIn())`, with the bar itself visible around it.
  await expect(page.getByTestId('nav-login')).toHaveCount(0);
});
