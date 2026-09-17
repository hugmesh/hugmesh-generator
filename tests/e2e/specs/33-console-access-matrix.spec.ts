import { test, expect, Page } from '@playwright/test';
import { onboard } from './helpers';
import { tags } from './report-tags';
import { loginPassword } from './rbac-roles';

// ────────────────────────────────────────────────────────────────────────────
// 33 — CONSOLE ACCESS MATRIX: can each identity FIND and OPEN its consoles?
//
// Why this spec exists (operator report, 2026-08-14): "this functionality
// should already exist but we can't find it nor any control UIs for any of the
// services." Every console DID exist and work; the only way in was to click
// your own username and hunt through the profile dropdown. An account holding
// all ten roles saw a menubar of exactly Home / Mastodon / Matrix / Forum.
//
// So this asserts the two halves that failure had:
//   (a) DISCOVERY — the console is LISTED for the identities that hold its role,
//       and NOT listed for the ones that do not. A console you cannot find is,
//       for the operator, a console that does not exist.
//   (b) REACH — following it actually renders the console rather than bouncing
//       to /user (the shape of the earlier NG04002 redirect bug) or rendering an
//       empty shell.
//
// Deliberately asserted per IDENTITY rather than per route: "which controls does
// THIS user get" is the question an operator actually asks, and it is the one a
// role regression breaks. The negative cases carry equal weight — a member
// seeing an admin link is as much a defect as an admin not seeing one.
//
// Personas come from the standard e2e seed. mesh-operator is the
// Studio-bootstrapped account that holds every role; it is skipped (not failed)
// when a stack was seeded without it, because a terminal-seeded mesh legitimately
// has no such account.
// ────────────────────────────────────────────────────────────────────────────

// Resolved/generated, never a literal (see rbac-roles.ts sharedPassword()).

interface ConsoleExpectation {
  /** data-testid of the menubar entry. */
  navTestId: string;
  /** Where following it must land. */
  route: string;
  /** A string that only the REAL console renders (proves it is not an empty shell). */
  proof: RegExp;
}

const ADMIN_CONSOLE: ConsoleExpectation = {
  navTestId: 'nav-admin',
  route: '/admin',
  proof: /usage|namespace|delegation|route access/i,
};

const MOD_CONSOLE: ConsoleExpectation = {
  navTestId: 'nav-mod',
  route: '/mod',
  proof: /moderat/i,
};

interface Persona {
  username: string;
  /** Consoles this identity MUST be offered. */
  expects: ConsoleExpectation[];
  /** Consoles this identity must NOT be offered. */
  denies: ConsoleExpectation[];
  /** Skip rather than fail when the account is absent from this seed. */
  optional?: boolean;
}

const PERSONAS: Persona[] = [
  { username: 'mesh-operator', expects: [ADMIN_CONSOLE, MOD_CONSOLE], denies: [], optional: true },
  { username: 'e2e-admin', expects: [ADMIN_CONSOLE, MOD_CONSOLE], denies: [] },
  { username: 'e2e-mod', expects: [MOD_CONSOLE], denies: [ADMIN_CONSOLE] },
  { username: 'e2e-user', expects: [], denies: [ADMIN_CONSOLE, MOD_CONSOLE] },
];

/**
 * Sign in and land on the shell. Returns `null` on success, else the reason it
 * failed — never a bare boolean.
 *
 * WHY IT RETURNS A REASON (hugmesh-generator#306). This was
 * `catch { return false }`, so every failure mode collapsed into one value and
 * the only thing the assertion could ever print was `Received: false`. Two of
 * the eight failures that issue calls "unexplained" are exactly that:
 * `33:87 e2e-user` and `33:110 e2e-admin` on the 2026-09-04 22:06 run. The
 * cause had to be recovered afterwards from a page snapshot buried in the HTML
 * report — `Sign-in failed: invalid_credentials`, with the password field
 * holding the same string the seed banner printed — which is a bisect's worth
 * of work to learn something the failure message could have said outright.
 *
 * It also made the `optional` escape hatch SILENT: any failure for
 * mesh-operator — a 401, a missing nav entry, a 90s timeout — read as "absent
 * from this seed" and skipped. That fired in the same run (test 246 skipped,
 * test 247 then passed on retry), so the skip was not even true. The skip is
 * kept, because a Studio-bootstrapped-only account really can be absent, but it
 * now carries the reason it is skipping on.
 */
async function signInFailure(page: Page, username: string): Promise<string | null> {
  try {
    await onboard(page, username, loginPassword());
    return null;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // First line only: onboard() failures carry a full Playwright call log, and
    // the whole thing in a skip annotation makes the run summary unreadable.
    return msg.split('\n')[0].trim() || String(e);
  }
}

test.describe('33 — console access matrix (discovery + reach, per identity)', () => {
  for (const persona of PERSONAS) {
    test(`${persona.username}: sees exactly its own consoles in the menubar `
      + tags({ layer: 'ui' }), async ({ page }) => {
      const why = await signInFailure(page, persona.username);
      test.skip(!!why && !!persona.optional,
        `${persona.username} could not sign in and is optional `
        + `(Studio-bootstrapped only) — ${why}`);
      expect(why, `${persona.username} must be able to sign in`).toBeNull();

      for (const c of persona.expects) {
        await expect(
          page.getByTestId(c.navTestId),
          `${persona.username} holds the role, so ${c.route} must be LISTED — `
          + 'a console reachable only by typing the URL is one the operator cannot find',
        ).toBeVisible();
      }
      for (const c of persona.denies) {
        await expect(
          page.getByTestId(c.navTestId),
          `${persona.username} lacks the role, so ${c.route} must NOT be listed`,
        ).toHaveCount(0);
      }
    });

    for (const c of persona.expects) {
      test(`${persona.username}: opening ${c.route} renders the real console `
        + tags({ layer: 'ui' }), async ({ page }) => {
        const why = await signInFailure(page, persona.username);
        test.skip(!!why && !!persona.optional,
          `${persona.username} could not sign in and is optional — ${why}`);
        expect(why, `${persona.username} must be able to sign in`).toBeNull();

        // NOT waitForLoadState('networkidle'): this shell holds a live SSE channel
        // open, so the network is NEVER idle and that wait simply burns the whole
        // test timeout (observed: 45s timeouts with an empty page URL). waitForURL
        // is the assertion that actually models "the navigation happened".
        await page.getByTestId(c.navTestId).click();
        await page.waitForURL(new RegExp(`${c.route}(/|$)`), { timeout: 20_000 });

        // Reach: we are ON the console, not bounced to /user (the shape of the
        // in-app-navigation bug that sent Mastodon's reply button to the shell root).
        await expect(page).toHaveURL(new RegExp(`${c.route}(/|$)`));
        // …and the console actually rendered its own content, not an empty shell.
        await expect(page.locator('body')).toContainText(c.proof, { timeout: 20_000 });
      });
    }
  }

  test('the moderation console exposes its wired controls to a moderator '
    + tags({ role: 'ROLE_MOD', layer: 'ui' }), async ({ page }) => {
    // The console's panels are the actual moderation CONTROLS: queue, ban/lift,
    // domain-lock, recommend, audit. Asserting they render for a mod is what
    // makes "the controls exist for this user" a checked claim rather than a
    // screenshot someone remembers.
    expect(await signInFailure(page, 'e2e-mod'), 'e2e-mod must be able to sign in').toBeNull();
    await page.goto('/mod/console');
    const body = page.locator('body');
    for (const control of [/queue/i, /ban/i, /domain.?lock/i, /audit/i]) {
      await expect(body, `the moderation console must render its ${control} panel`)
        .toContainText(control, { timeout: 20_000 });
    }
  });

  test('a plain member is DENIED the moderation console even by direct URL '
    + tags({ role: 'ROLE_USER', layer: 'ui' }), async ({ page }) => {
    // Discovery-gating is presentation; this is the one that matters for safety.
    // The guard must hold when the URL is typed, not merely when the link is hidden.
    expect(await signInFailure(page, 'e2e-user'), 'e2e-user must be able to sign in').toBeNull();
    await page.goto('/mod/console');
    // Same reason as above — never networkidle on this shell.
    await page.waitForTimeout(3_000);
    await expect(page.locator('body')).not.toContainText(/moderation queue/i);
  });
});
