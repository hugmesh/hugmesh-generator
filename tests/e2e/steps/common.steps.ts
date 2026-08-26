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

// Shared DOM vocabulary. This lived in BOTH onboarding.steps.ts and rbac.steps.ts as
// byte-identical definitions, which is fatal rather than merely untidy: bddgen is
// all-or-nothing, so ONE ambiguous step stopped all 453 scenarios from generating —
// the merged lane produced nothing at all. Promoted here on 2026-08-26 during
// integration, which is the fix onboarding.steps.ts already prescribed in its own
// header ("promote the single definition into common.steps.ts, never reword one of
// them"). Any step two domains both need belongs in this file, not duplicated.
Then('the element with test id {string} is disabled', async ({ page }, testId: string) => {
  await expect(page.getByTestId(testId)).toBeDisabled();
});

// ── THE ENVIRONMENT × INTERFACE VOCABULARY (shared — reuse, never redefine) ──
//
// These steps are the CLI and Studio equivalents of the browser steps above, and
// every domain author needs them. They live HERE, in the shared file, for the
// same reason 'the element with test id {string} is disabled' was promoted here
// on 2026-08-26: two authors independently defining a byte-identical step makes
// bddgen ambiguous, and bddgen is all-or-nothing — one ambiguous step generated
// ZERO of 453 scenarios and the merged lane produced nothing at all.
//
// Before adding a near-twin of any of these ("I execute the command …", "I run
// the CLI …"), grep this file. A reworded duplicate does not break generation,
// which is worse: it silently fragments the Gherkin vocabulary so two features
// describe the same act in two ways and neither reads as the other's coverage.
//
// PINNED world KEYS — downstream steps may read these:
//   world['cli.transcript']  the last transcript an EXPLICIT cli step produced
//   world['studio.grab']     the last Studio widget grab
// The Studio steps also produce a transcript internally (the driver invocation),
// but it deliberately does NOT land on 'cli.transcript': 'the command exit code
// was N' must keep meaning the command the feature actually named.

import {
  runCli, runStudio, cliSucceeded, cliVerdict, studioGrabbed, REPO_ROOT,
} from './runners';
import {
  CliTranscript, StudioGrab, manifestRowsForScenario, artefactPath, ArtefactKind,
} from './evidence';
import { environmentBaseUrl, envOf, interfaceOf, studioPython } from './dimensions';
import * as nodeFs from 'node:fs';
import * as nodePath from 'node:path';

const CLI_KEY = 'cli.transcript';
const STUDIO_KEY = 'studio.grab';

// ── cli interface ────────────────────────────────────────────────────────────

/**
 * Run a shell command and capture it whole. `bash -c`, NOT `bash -lc`: a login
 * shell sources the operator's profile, so the same feature would behave
 * differently on a developer box and in CI for reasons nothing in the Gherkin
 * mentions.
 *
 * Non-zero is NOT a failure here — capturing is this step's job and asserting is
 * the next step's. A step that both ran and judged would make it impossible to
 * write a scenario about a command that is SUPPOSED to fail.
 */
When('I run the shell command {string}', async ({ world }, command: string) => {
  world.set(CLI_KEY, runCli(['bash', '-c', command], { cwd: REPO_ROOT }));
});

/**
 * Run the Studio's Qt-FREE CLI channel (`python3 -m hugmesh_studio …`) — the
 * --print-command / --print-specs path docker/build-image.sh already drives.
 * Arguments are split on whitespace; anything needing quoting belongs in a
 * shell-command step instead.
 */
When('I run the Studio CLI with {string}', async ({ world }, args: string) => {
  const argv = [studioPython(), '-m', 'hugmesh_studio', ...args.split(/\s+/).filter(Boolean)];
  world.set(CLI_KEY, runCli(argv, { cwd: nodePath.join(REPO_ROOT, 'studio') }));
});

Then('the command exit code was {int}', async ({ world }, expected: number) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.exitCode, `\`${t.command}\` ${cliVerdict(t)}\n--- stderr ---\n${t.stderr}`)
    .toBe(expected);
});

Then('the command succeeded', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(
    cliSucceeded(t),
    `\`${t.command}\` ${cliVerdict(t)}\n--- stderr ---\n${t.stderr}`,
  ).toBe(true);
});

Then('the command failed', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(
    cliSucceeded(t),
    `\`${t.command}\` was expected to fail but ${cliVerdict(t)}\n`
    + `--- stdout ---\n${t.stdout}`,
  ).toBe(false);
});

Then('the command output contains {string}', async ({ world }, needle: string) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(
    `${t.stdout}\n${t.stderr}`,
    `\`${t.command}\` (${cliVerdict(t)}) output did not contain ${JSON.stringify(needle)}`,
  ).toContain(needle);
});

Then('the command output is valid JSON', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  const last = t.stdout.trim().split('\n').filter(Boolean).pop() ?? '';
  expect(
    () => JSON.parse(last),
    `last stdout line of \`${t.command}\` is not JSON: ${last.slice(0, 300)}`,
  ).not.toThrow();
});

// ── studio interface ─────────────────────────────────────────────────────────

/**
 * Build the REAL StudioWizard offscreen, jump to a named page and grab it.
 * The slug must be one of hugmesh_studio.core.config.WIZARD_PAGE_SLUGS; the
 * driver fails loudly listing them all rather than grabbing whatever page it
 * happened to be on, which would produce a plausible PNG of the wrong screen.
 */
When('I grab the Studio wizard page {string}', async ({ world }, page: string) => {
  world.set(STUDIO_KEY, runStudio({ page }));
});

When('I grab the Studio wizard', async ({ world }) => {
  world.set(STUDIO_KEY, runStudio());
});

Then('the Studio grab is a non-empty PNG', async ({ world }) => {
  const g = world.get<StudioGrab>(STUDIO_KEY);
  expect(
    studioGrabbed(g),
    `Studio grab failed (${cliVerdict(g.transcript)})\n`
    + `--- driver stderr ---\n${g.transcript.stderr}`,
  ).toBe(true);
  expect(nodeFs.statSync(g.pngPath).size, `${g.pngPath} is empty`).toBeGreaterThan(0);
});

Then('the Studio grab shows the wizard page {string}', async ({ world }, page: string) => {
  const g = world.get<StudioGrab>(STUDIO_KEY);
  expect(g.page, `driver reported page '${g.page}'`).toBe(page);
});

// ── evidence + manifest (interface-agnostic) ─────────────────────────────────

/**
 * The anti-decoration assertion for the evidence lane itself: this scenario has
 * actually produced an artefact of the named kind, and the manifest knows about
 * it. Reads manifest.jsonl (the append log), so it sees the rows PREVIOUS steps
 * of this same scenario wrote.
 */
Then('the evidence manifest holds a {string} artefact for this scenario',
  async ({ $testInfo }, kind: string) => {
    const rows = manifestRowsForScenario($testInfo.title);
    const kinds = [...new Set(rows.map((r) => r.kind))];
    expect(
      kinds,
      `no '${kind}' artefact recorded for this scenario. Kinds present: `
      + `${kinds.length ? kinds.join(', ') : '<none — the AfterStep hook recorded NOTHING>'}`,
    ).toContain(kind as ArtefactKind);
  });

/**
 * Every row the manifest claims must be a file that is really there. This is the
 * check that stops the index from drifting into fiction — a manifest listing
 * artefacts nobody can open is worse than no manifest, because a reviewer counts
 * the rows and believes them.
 */
Then('every evidence artefact recorded for this scenario exists on disk',
  async ({ $testInfo }) => {
    const rows = manifestRowsForScenario($testInfo.title);
    expect(rows.length, 'this scenario recorded ZERO evidence rows').toBeGreaterThan(0);
    const missing = rows
      .filter((r) => !nodeFs.existsSync(artefactPath(r)))
      .map((r) => `${r.kind} -> ${r.path}`);
    expect(missing, `manifest rows with no file on disk:\n  ${missing.join('\n  ')}`).toEqual([]);
  });

/** The env axis actually re-points the browser's base URL. */
Then('the scenario drives the {string} environment base URL',
  async ({ dimensions }, envId: string) => {
    expect(envOf(dimensions), 'effective environment').toBe(envId);
    expect(environmentBaseUrl(envId), `${envId} base URL`).toMatch(/^https?:\/\//);
  });

/** The interface axis resolved to what the feature declared. */
Then('the scenario runs on the {string} interface', async ({ dimensions }, ifaceId: string) => {
  expect(interfaceOf(dimensions), 'effective interface').toBe(ifaceId);
});
