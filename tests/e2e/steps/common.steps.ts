// common.steps.ts — the SHARED step vocabulary every feature in this suite may use.
//
// RULE FOR DOWNSTREAM AUTHORS: do NOT redefine a step that already exists here.
// playwright-bdd fails generation on an ambiguous step, so a duplicate is a hard
// error, not a silent shadow — but the fix is to reuse, not to reword.
//
// RULE 2: these definitions REUSE tests/e2e/specs/*.ts. Login, session hydration,
// persona resolution, screenshots and the Matrix/Mastodon plumbing all already
// exist and are already exercised by the 33 handwritten specs; a step that
// reimplements them would drive DIFFERENT code than the suite it is meant to
// replace, and the two would drift. Import from '../specs/…' and call the helper.

import { expect } from '@playwright/test';
import { Given, When, Then, requireDimension } from './world';
import { serviceUiPath, service, persona, personaSource } from './dimensions';
import { onboard, registerOnly, getSession, personaPassword } from '../specs/helpers';

// ── navigation ───────────────────────────────────────────────────────────────

When('I open the path {string}', async ({ page }, target: string) => {
  await page.goto(target);
});

/**
 * Navigate to the SERVICE this scenario's `@service:` dimension names. Throws
 * when that service has no pinned UI path (steps/dimensions.ts) rather than
 * guessing a URL — a 404 renders as a blank page, and a blank page satisfies
 * far too many assertions.
 */
When('I open the service surface', async ({ page, dimensions }) => {
  const id = requireDimension(dimensions, 'service');
  await page.goto(serviceUiPath(id));
});

// ── identity ─────────────────────────────────────────────────────────────────

/**
 * Sign in as the persona this scenario's `@role:` dimension names, completing
 * the two-stage registration gate. Delegates to specs/helpers.ts `onboard()` —
 * the exact function the handwritten specs use.
 */
Given('I am signed in as the persona for this scenario', async ({ page, dimensions, world }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const session = await onboard(page, handle, personaPassword(handle));
  world.set('session', session);
});

/**
 * Register WITHOUT completing the two-stage gate — the state specs 17/28/29
 * assert on for the deliberately un-onboarded personas (e2e-pending,
 * rbac-pending-gmail-com, e2e-banned). Never "fix" those into onboarded ones.
 */
Given('I have registered but not completed onboarding as the persona for this scenario',
  async ({ page, dimensions }) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    await registerOnly(page, handle, personaPassword(handle));
  });

// ── assertions ───────────────────────────────────────────────────────────────

Then('the URL matches {string}', async ({ page }, pattern: string) => {
  await expect(page).toHaveURL(new RegExp(pattern));
});

Then('the level {int} heading {string} is visible', async ({ page }, level: number, name: string) => {
  await expect(
    page.getByRole('heading', { level: level as 1 | 2 | 3 | 4 | 5 | 6, name }),
  ).toBeVisible();
});

Then('the element with test id {string} is visible', async ({ page }, testId: string) => {
  await expect(page.getByTestId(testId)).toBeVisible();
});

Then('the element with test id {string} is not visible', async ({ page }, testId: string) => {
  await expect(page.getByTestId(testId)).toHaveCount(0);
});

Then('my session holds the role {string}', async ({ page, world, dimensions }, role: string) => {
  const handle = world.has('session')
    ? (world.get<{ username: string }>('session')).username
    : requireDimension(dimensions, 'role');
  const s = await getSession(page, handle);
  expect(s.roles, `GET /bff/session roles for ${handle}`).toContain(role);
});

Then('my session registration is complete', async ({ page, world, dimensions }) => {
  const handle = world.has('session')
    ? (world.get<{ username: string }>('session')).username
    : requireDimension(dimensions, 'role');
  const s = await getSession(page, handle);
  expect(s.registrationComplete, `registrationComplete for ${handle}`).toBe(true);
});

Then('my session registration is not complete', async ({ page, world, dimensions }) => {
  const handle = world.has('session')
    ? (world.get<{ username: string }>('session')).username
    : requireDimension(dimensions, 'role');
  const s = await getSession(page, handle);
  expect(s.registrationComplete, `registrationComplete for ${handle}`).toBe(false);
});

// ── harness contract steps (offline; no stack required) ──────────────────────

/**
 * The persona named by `@role:` must be created by a seeder that actually runs.
 * This is the anti-ghost-persona check: a feature naming a handle nothing seeds
 * would otherwise fail at login with a bare 401 that reads like a broken login
 * (the exact 2026-08-06 e2e-fleet symptom in tests/scripts/test-e2e-persona-catalogue.sh).
 */
Then('the persona named by the role dimension is seeded', async ({ dimensions }) => {
  const handle = requireDimension(dimensions, 'role');
  const src = personaSource(handle);
  expect(src, `no seeder creates persona '${handle}'`).toBeDefined();
});

/** The service named by `@service:` must carry a pinned, drivable surface. */
Then('the service named by the service dimension has a pinned surface', async ({ dimensions }) => {
  const id = requireDimension(dimensions, 'service');
  const def = service(id);
  expect(def.pinned, `service '${id}' surface is not pinned: ${def.note}`).toBe(true);
});
