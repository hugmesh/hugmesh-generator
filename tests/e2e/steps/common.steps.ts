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
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Given, When, Then, Before, After, requireDimension } from './world';
import { serviceUiPath, service, persona, personaSource } from './dimensions';
import { onboard, registerOnly, getSession, personaPassword, apiContext } from '../specs/helpers';

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

// ── raw HTTP (shared — reuse, never redefine) ─────────────────────────────────
//
// A step-level HTTP call, for asserting a BFF's response directly rather than
// through a page. Several domains need exactly this shape (register/provision
// endpoints, internal kill-switches, gateway contract probes) and NONE of them
// needed anything domain-specific, so it lives here rather than being reworded
// per steps/<domain>.steps.ts five times over — the same duplication
// common.steps.ts's header already warns against.
//
// world['response'] / world['responseLabel'] / world['responseBody'] are the
// SAME three keys `mined-identity.steps.ts`'s `record()` and
// `Then('the response status is {int}', …)` already read — that step (and its
// neighbours: 'the response error message matches …', 'the response header …')
// is deliberately NOT redefined here. Write the request with a step from this
// section, assert the result with a step already living in mined-identity.steps.ts.
//
// world['api'] is the SAME key `moderation-media.steps.ts`'s
// 'I hold an API session as the persona for this scenario' /
// 'I hold an anonymous API client' already populate — reuse one of those Given
// steps first when the request needs to be authenticated. When nothing set
// 'api' yet (e.g. probing a permitAll pre-auth path like /bff/register/<provider>,
// where there is by definition no session to hold), these steps lazily open one
// anonymous APIRequestContext and reuse it for the rest of the scenario.
//
// VOCABULARY, so nobody rewords it (a reworded twin does not break bddgen, which
// is worse — it fragments the language two features use for one act):
//   write a request   I request {string}                      (bodiless, any verb)
//                     I submit a POST to {string} with body:   (doc-string JSON)
//                     the API client GETs {string}             (mined-identity.steps.ts)
//                     the API client POSTs {string} with body {string}   (inline JSON;
//                       mined-identity.steps.ts owns it: a second definition here
//                       makes bddgen fail with "Multiple definitions matched")
//   assert on it      the response status is {int}             (mined-identity.steps.ts)
//                     the response status is not {int}
//                     the response body contains {string}
//                     the response error message matches {string}  (mined-identity.steps.ts)
// "the API client response status was {int}" is NOT defined anywhere: it is a
// reworded twin of 'the response status is {int}'. Reuse that one.

let httpOpenContexts: APIRequestContext[] = [];

Before(async () => { httpOpenContexts = []; pendingLifts = []; });
After(async () => {
  await liftPendingSuspensions();
  for (const c of httpOpenContexts) await c.dispose().catch(() => { /* already gone */ });
  httpOpenContexts = [];
});

async function requestApi(baseURL: string | undefined, world: { has(k: string): boolean; get<T>(k: string): T; set<T>(k: string, v: T): void }): Promise<APIRequestContext> {
  if (world.has('api')) return world.get<APIRequestContext>('api');
  const ctx = await apiContext(baseURL);
  httpOpenContexts.push(ctx);
  world.set('api', ctx);
  return ctx;
}

/** Defensive CSRF header (spec 28's idiom, also moderation-media.steps.ts): the
 *  stack sets no XSRF-TOKEN cookie today, so this is empty — but a mutating
 *  call that forgot it would start 403ing for the wrong reason the day it does. */
async function defensiveCsrf(api: APIRequestContext): Promise<Record<string, string>> {
  const t = (await api.storageState()).cookies.find((c) => c.name === 'XSRF-TOKEN')?.value;
  return t ? { 'X-CSRF-TOKEN': t } : {};
}

function parseJsonArgument(stepLabel: string, body: string): unknown {
  try {
    return JSON.parse(body);
  } catch (e) {
    throw new Error(`${stepLabel} is not valid JSON: ${(e as Error).message}\n${body}`);
  }
}

async function recordHttpResponse(
  world: { set<T>(k: string, v: T): void },
  label: string,
  r: APIResponse,
): Promise<void> {
  world.set('response', r);
  world.set('responseLabel', label);
  world.set('responseBody', await r.text().catch(() => ''));
}

const HTTP_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'] as const;
type HttpMethod = (typeof HTTP_METHODS)[number];

/** Parses `"GET /bff/matrix/localpart"` — throws naming the legal verbs on a typo
 *  rather than silently defaulting to GET, which would make a mistyped verb
 *  pass against a path that answers 200 to everything. */
function parseMethodAndPath(spec: string): { method: HttpMethod; path: string } {
  const m = /^(\S+)\s+(\S+)$/.exec(spec.trim());
  const method = m?.[1]?.toUpperCase();
  if (!m || !HTTP_METHODS.includes(method as HttpMethod)) {
    throw new Error(
      `'I request "${spec}"' must be "<METHOD> <path>" with METHOD one of `
      + `${HTTP_METHODS.join(', ')} — got ${JSON.stringify(spec)}`,
    );
  }
  return { method: method as HttpMethod, path: m[2] };
}

/**
 * `Given I hold an API session …` first when the call must be authenticated;
 * otherwise this opens (and reuses) an anonymous context — the correct default
 * for a permitAll pre-auth path, which by definition has no session to hold.
 */
When('I request {string}', async ({ baseURL, world }, spec: string) => {
  const { method, path } = parseMethodAndPath(spec);
  const api = await requestApi(baseURL, world);
  const r = await api.fetch(path, { method });
  await recordHttpResponse(world, `${method} ${path}`, r);
});

/** The POST-with-a-JSON-body twin of `I request {string}` — a Gherkin doc
 *  string, not an inline query param, so a multi-field body stays readable. */
When('I submit a POST to {string} with body:', async ({ baseURL, world }, target: string, body: string) => {
  const api = await requestApi(baseURL, world);
  const data = parseJsonArgument(`'I submit a POST to "${target}" with body:' doc string`, body);
  const r = await api.post(target, { data, headers: await defensiveCsrf(api) });
  await recordHttpResponse(world, `POST ${target}`, r);
});

/** The substring twin of mined-identity.steps.ts's exact-match response steps —
 *  for an error body where the exact JSON shape is not what the scenario is
 *  about, only that the human-readable reason appears somewhere in it. */
Then('the response body contains {string}', async ({ world }, needle: string) => {
  const body = world.get<string>('responseBody');
  expect(
    body,
    `${world.get<string>('responseLabel')} response body did not contain ${JSON.stringify(needle)}: `
    + `${body.slice(0, 300)}`,
  ).toContain(needle);
});

/**
 * The negation of 'the response status is {int}' (mined-identity.steps.ts). For
 * the row of a role matrix where the point is only that the ROLE gate passed —
 * e.g. a superadmin whose request then 404s on a domain nothing offered. Prefer
 * the exact code when the scenario knows it; this exists for the rows that do not.
 */
Then('the response status is not {int}', async ({ world }, refused: number) => {
  const r = world.get<APIResponse>('response');
  expect(
    r.status(),
    `${world.get<string>('responseLabel')} -> ${r.status()} `
    + `${JSON.stringify(world.get<string>('responseBody')).slice(0, 300)}`,
  ).not.toBe(refused);
});

// ── account suspension (shared — the PROFILE ban that CURTAILS an account) ──
//
// A "curtailed" principal (the state AccountAppealUserController, the host
// shell's session.curtailed() and the gateway's revocation fast-path all key
// off) is NOT a Casdoor-role flip: it is an admin-bff access_suspension row for
// the PROFILE role, written when a moderator or admin bans the account on the
// `profile` platform (hugmesh-mod-bff-api ModController#ban -> AdminSuspensionClient
// -> admin-bff POST /bff/admin/access-roles/PROFILE/{user}). No seeder can express
// that in the roster grammar (handle:ROLES:PASSWORD_ENV carries roles only), so
// the state is produced AT SCENARIO TIME by these steps and torn down in After.
//
// ONLY A RESERVED PERSONA MAY BE SUSPENDED. e2e-suspended exists for exactly
// this (tests/e2e-extra-personas.sh). Suspending e2e-user — the subject the
// first sketches named — would poison every scenario signing in as e2e-user in
// the same run, and the live pass runs lanes concurrently against ONE stack.
// The step therefore refuses any other handle, naming the reserved one.
//
// WHAT THE 202 MEANS. mod-bff answers 202 {state:'pending-reconcile'}: the
// desired-state row is written synchronously (that is what the appeal surface
// reads), the Casdoor/homeserver EFFECT is applied by a reconcile loop. A Then
// that observes the effect (a revocation key, a swap-cache miss) owns its own
// wait; this step asserts only that the write was accepted.
//
// SELF-HEALING: ttlSeconds is set, so a run killed between the ban and the
// After lift leaves a suspension that admin-bff auto-restores, not a persona
// that stays curtailed until somebody reseeds the operator's stack.

const SUSPENDABLE_PERSONAS = new Set(['e2e-suspended']);
const SUSPENSION_TTL_SECONDS = 900;
const SUSPENSION_ADMIN = 'e2e-admin';
const MOD_BAN_PATH = '/bff/mod/ban';

interface PendingLift { admin: APIRequestContext; target: string }
let pendingLifts: PendingLift[] = [];

/** A signed-in API client for the admin who performs the ban. Mirrors
 *  moderation-media.steps.ts apiSignIn (login, session read, complete the
 *  two-stage gate if needed): an incomplete registration presents ZERO roles at
 *  the gateway and /bff/mod/** would refuse it for a reason unrelated to the ban. */
async function adminApi(baseURL: string | undefined): Promise<APIRequestContext> {
  const api = await apiContext(baseURL);
  httpOpenContexts.push(api);
  const r = await api.post('/bff/login', {
    data: { username: SUSPENSION_ADMIN, password: personaPassword(SUSPENSION_ADMIN) },
  });
  expect(r.status(), `native login ${SUSPENSION_ADMIN} -> ${r.status()} — the admin persona must be seeded`).toBe(200);
  const s = await api.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(s.status(), `${SUSPENSION_ADMIN}: GET /bff/session after login`).toBe(200);
  if (!(await s.json()).registrationComplete) {
    const done = await api.post('/bff/register/complete', { data: { displayName: SUSPENSION_ADMIN } });
    expect(done.status(), `${SUSPENSION_ADMIN}: POST /bff/register/complete`).toBe(200);
  }
  return api;
}

function suspensionSubject(dimensions: Parameters<typeof requireDimension>[0]): string {
  const handle = persona(requireDimension(dimensions, 'role'));
  if (!SUSPENDABLE_PERSONAS.has(handle)) {
    throw new Error(
      `refusing to suspend '${handle}': only a persona RESERVED for suspension scenarios may be `
      + `curtailed at scenario time (${[...SUSPENDABLE_PERSONAS].join(', ')} — tests/e2e-extra-personas.sh). `
      + `Suspending '${handle}' would poison every concurrently running scenario that signs in as `
      + `it. Tag the scenario @role:e2e-suspended.`,
    );
  }
  return handle;
}

async function liftSuspension(admin: APIRequestContext, target: string): Promise<APIResponse> {
  return admin.delete(MOD_BAN_PATH, {
    data: { platform: 'profile', target, idempotencyKey: `e2e-lift-${target}-${Date.now()}` },
    headers: await defensiveCsrf(admin),
  });
}

async function liftPendingSuspensions(): Promise<void> {
  const lifts = pendingLifts;
  pendingLifts = [];
  for (const l of lifts) {
    await liftSuspension(l.admin, l.target).catch(() => { /* best effort; the TTL is the backstop */ });
  }
}

/**
 * Curtail the scenario's persona with a PROFILE ban through the real moderation
 * surface, as e2e-admin. Records the lift for After. Leaves world['suspension']
 * = the target handle for a downstream step that needs to name it.
 */
When('an admin suspends the persona for this scenario', async ({ baseURL, dimensions, world, $testInfo }) => {
  const target = suspensionSubject(dimensions);
  const admin = await adminApi(baseURL);
  const r = await admin.post(MOD_BAN_PATH, {
    data: {
      platform: 'profile',
      target,
      ttlSeconds: SUSPENSION_TTL_SECONDS,
      reason: `e2e: ${$testInfo.title}`.slice(0, 2048),
      idempotencyKey: `e2e-ban-${target}-${Date.now()}`,
    },
    headers: await defensiveCsrf(admin),
  });
  const body = await r.text().catch(() => '');
  expect(
    r.status(),
    `POST ${MOD_BAN_PATH} {platform:profile, target:${target}} as ${SUSPENSION_ADMIN} -> ${r.status()} `
    + `${body.slice(0, 300)} (202 pending-reconcile is the contract; a 403 with a step-up header means `
    + `the stack armed app.mfa.enforce-sensitive-writes and this admin has no fresh MFA stamp)`,
  ).toBe(202);
  pendingLifts.push({ admin, target });
  world.set('suspension', target);
});

/** Lift the ban this scenario wrote. Idempotent with the After lift. */
When('the suspension on the persona for this scenario is cleared', async ({ dimensions, world }) => {
  const target = suspensionSubject(dimensions);
  const pending = pendingLifts.find((l) => l.target === target);
  expect(pending, `no suspension was written for '${target}' in this scenario — 'an admin suspends the persona for this scenario' must come first`).toBeDefined();
  pendingLifts = pendingLifts.filter((l) => l !== pending);
  const r = await liftSuspension(pending!.admin, target);
  const body = await r.text().catch(() => '');
  expect(r.status(), `DELETE ${MOD_BAN_PATH} {platform:profile, target:${target}} -> ${r.status()} ${body.slice(0, 300)}`).toBe(202);
  world.set('suspension', target);
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
