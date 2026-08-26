// world.ts — THE SINGLE ENTRY POINT for every BDD step definition in this suite.
//
// Every step file under tests/e2e/steps/ MUST import its Given/When/Then from
// HERE, never from 'playwright-bdd' directly:
//
//     import { Given, When, Then } from './world';
//
// WHY (load-bearing, learned from hugmesh-login-ui's harness). createBdd(test)
// binds hook factories and step definitions to ONE `test` instance. If some step
// files call createBdd() themselves, they bind to a DIFFERENT instance than the
// generated specs consume, load ordering races, and hooks silently never fire —
// which looks exactly like "screenshots are just not working today". Keeping the
// single createBdd() call and ALL hook registrations in this one file removes the
// race entirely.
//
// WHAT THIS FILE ADDS ON TOP OF playwright-bdd:
//   1. `dimensions` — the resolved ROLE × PLATFORM × SERVICE cell this scenario
//      runs in, validated at Before-hook time (steps/dimensions.ts).
//   2. `world` — a tiny per-scenario scratchpad so a When can hand state to a
//      Then without module-level globals leaking across scenarios.
//   3. AfterStep step evidence: an ORDINAL-PREFIXED screenshot per Gherkin step
//      into a per-run directory under the REPORT dir, plus a JSON sidecar and a
//      testInfo.attach carrying {feature, scenario, step, ordinal, role,
//      platform, service}. This is what makes per-step screenshot browsing
//      possible; before this harness, test.step() appeared ZERO times in
//      tests/e2e and every passing test produced no evidence at all
//      (playwright.config.ts sets screenshot:'only-on-failure').
//
// WHERE THE EVIDENCE GOES — and where it deliberately does NOT go. NOT into
// tests/e2e/screenshots/: that directory holds 38 GIT-TRACKED PNGs which every
// legacy run overwrites in place, so a test run dirties the working tree. Step
// evidence lands under ${SNAP_REPORT_DIR:-test-results}/bdd-steps/<runId>/…,
// which .gitignore already excludes. Overridable with SNAP_BDD_SHOTS.
//
// PER-STEP test.step(). playwright-bdd already wraps each Gherkin step in a real
// Playwright test.step() (dist/playwright/runStepWithLocation.js), so every
// Given/When/Then shows up as a step in the JSON/HTML report with no work from
// us. `substep()` below is for instrumenting SUB-actions inside one definition.

import { test as base, createBdd } from 'playwright-bdd';
import * as fs from 'node:fs';
import * as path from 'node:path';
import type { BddContext } from 'playwright-bdd/dist/runtime/bddContext';
import {
  Dimensions, resolveDimensions, requireDimension, ENVIRONMENTS,
  envOf, interfaceOf, isEnvironment, environmentBaseUrl,
  environmentAvailability, interfaceAvailability,
} from './dimensions';
import {
  slug, runDir, clearPending, drainPending, writeStepEvidence, appendManifest,
  materializeManifest, transcriptText, StepMeta, CliTranscript,
} from './evidence';

/** Per-scenario scratchpad. Cleared in Before, so nothing leaks between runs. */
export class World {
  private readonly bag = new Map<string, unknown>();

  set<T>(key: string, value: T): void { this.bag.set(key, value); }

  /** Read a value a previous step stored, or fail naming the missing producer. */
  get<T>(key: string): T {
    if (!this.bag.has(key)) {
      throw new Error(
        `world['${key}'] was never set. A Then that reads it must be preceded by the `
        + `When/Given that writes it — check the scenario's step order rather than `
        + `defaulting, which turns a broken scenario into a passing one.`,
      );
    }
    return this.bag.get(key) as T;
  }

  has(key: string): boolean { return this.bag.has(key); }
  clear(): void { this.bag.clear(); }
}

interface HugMeshBddFixtures {
  /** ROLE × PLATFORM × SERVICE cell, resolved + validated from tags and title. */
  dimensions: Dimensions;
  /** Per-scenario scratchpad. */
  world: World;
}

export const test = base.extend<HugMeshBddFixtures>({
  dimensions: async ({ $tags, $testInfo }, use) => {
    // Throws here on an unknown persona/service/platform/env/interface — before
    // a single browser action or subprocess runs, with the legal values in the
    // message.
    await use(resolveDimensions($tags, $testInfo.titlePath.join(' ')));
  },
  // THE ENVIRONMENT AXIS, MADE REAL FOR page.goto(). A scenario tagged
  // `@env:kind` must drive the kind ingress, not whatever playwright.config.ts
  // was started with. Overriding the baseURL OPTION here is what makes every
  // existing relative `page.goto('/login')` in every step definition follow the
  // scenario's environment with no change to the step.
  //
  // BACKWARD COMPATIBILITY IS THE WHOLE POINT OF THE TERNARY: a scenario that
  // declared no `@env:` falls through to the config's own baseURL untouched, so
  // the 453 pre-existing scenarios resolve exactly the URL they resolved before.
  baseURL: async ({ $tags, $testInfo, baseURL }, use) => {
    const d = resolveDimensions($tags, $testInfo.titlePath.join(' '));
    await use(d.env ? environmentBaseUrl(d.env) : baseURL);
  },
  world: async ({}, use) => {
    const w = new World();
    await use(w);
    w.clear();
  },
});

export const {
  Given, When, Then, Step,
  Before, After, BeforeStep, AfterStep, BeforeAll, AfterAll,
} = createBdd(test);

export { requireDimension };
export type { Dimensions };

/**
 * Instrument a SUB-action inside one step definition as its own Playwright step.
 * The Gherkin step itself is already a test.step(); use this when a definition
 * does several distinguishable things and a reviewer needs to see which one blew up.
 */
export async function substep<T>(title: string, body: () => Promise<T>): Promise<T> {
  return test.step(title, body);
}

// ── step evidence ────────────────────────────────────────────────────────────
//
// Re-exported so the historical import site keeps working. The machinery itself
// now lives in steps/evidence.ts, because evidence is no longer one shape: a
// browser step leaves a PNG, a cli step leaves a TRANSCRIPT, a studio step
// leaves a Qt widget grab, and all three have to land in one manifest.
export { BDD_SHOTS } from './evidence';

/** Per-scenario ordinal. Reset in Before; incremented in AfterStep. */
let stepOrdinal = 0;

/**
 * Escape a transcript for the throwaway HTML page the PNG rendering uses.
 * Backticks and `${` matter here: this string is interpolated into a template
 * literal in setContent, and this repo has been bitten by executable backticks
 * inside quotes before.
 */
function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string
  ));
}

/**
 * Render a CLI transcript to a PNG.
 *
 * THE HONEST FRAMING, because the operator asked for "screenshots" everywhere:
 * a terminal has no screen to shoot, so the transcript (.cli.json / .cli.txt)
 * is the artefact of RECORD and this picture is a convenience. It is produced
 * with NO new dependency — the Chromium instance Playwright already launched
 * renders it.
 *
 * IT USES A THROWAWAY PAGE, never the scenario's own. Calling setContent on the
 * driven page would destroy whatever the browser steps had built up, which is a
 * silent, spooky corruption in any scenario that mixes interfaces. A second page
 * in the same context costs a few milliseconds and cannot touch the first.
 *
 * Set SNAP_CLI_PNG=0 to skip the rendering entirely; the transcript is unaffected.
 */
async function renderTranscriptPng(
  page: import('@playwright/test').Page, t: CliTranscript, dest: string,
): Promise<boolean> {
  if (process.env.SNAP_CLI_PNG === '0') return false;
  const ctx = page.context();
  const scratch = await ctx.newPage();
  try {
    await scratch.setViewportSize({ width: 1280, height: 900 });
    await scratch.setContent(
      '<html><body style="margin:0;background:#0b0e14;color:#d6deeb;'
      + 'font:13px/1.45 ui-monospace,Menlo,Consolas,monospace">'
      + '<pre style="margin:0;padding:16px;white-space:pre-wrap;word-break:break-word">'
      + escapeHtml(transcriptText(t))
      + '</pre></body></html>',
    );
    await scratch.screenshot({ path: dest, fullPage: true });
    return true;
  } finally {
    await scratch.close().catch(() => { /* context already torn down */ });
  }
}

Before(async ({ dimensions, $testInfo }) => {
  stepOrdinal = 0;
  // Nothing a previous scenario collected may bleed into this one's first step.
  clearPending();

  // PLATFORM GATE. A mesh under test is ONE image target at a time. When the
  // runner says which (SNAP_PLATFORM=rpi5|x86), a scenario pinned to the other
  // platform is skipped WITH A NAMED REASON — it still appears in --list, so the
  // matrix stays visible and the skip is reported, never silent. With
  // SNAP_PLATFORM unset (the default) NOTHING is skipped and every platform row
  // runs, so an un-configured lane over-tests rather than under-tests.
  const underTest = process.env.SNAP_PLATFORM;
  if (dimensions.platform && underTest && dimensions.platform !== underTest) {
    $testInfo.skip(
      true,
      `scenario is pinned @platform:${dimensions.platform}; the stack under test is `
      + `SNAP_PLATFORM=${underTest}. Unset SNAP_PLATFORM to run every platform row.`,
    );
  }

  // ── ENVIRONMENT GATE ──────────────────────────────────────────────────────
  // Applies ONLY to scenarios that explicitly declared `@env:`. That line is
  // load-bearing for backward compatibility: the 453 pre-existing scenarios
  // declare no environment, and gating them on availability would convert the
  // 130 that currently FAIL against a dead stack into 130 skips — turning a
  // loud, true "nothing at :8443" into a quiet green-looking run. Opting in is
  // how a feature author asks for the skip.
  const declaredEnv = dimensions.env;
  if (declaredEnv) {
    // Runner-level pin, mirroring SNAP_PLATFORM.
    const envUnderTest = process.env.SNAP_ENV;
    if (envUnderTest && !isEnvironment(envUnderTest)) {
      throw new Error(
        `SNAP_ENV=${envUnderTest} is not a legal environment. Legal values: `
        + `${ENVIRONMENTS.join(', ')}. Unset SNAP_ENV to run every environment row.`,
      );
    }
    if (envUnderTest && envUnderTest !== declaredEnv) {
      $testInfo.skip(
        true,
        `scenario is pinned @env:${declaredEnv}; the environment under test is `
        + `SNAP_ENV=${envUnderTest}. Unset SNAP_ENV to run every environment row.`,
      );
    }
    // Availability. The reason ALWAYS names what to start — a skip that just
    // says "unavailable" sends the reader to the source to find out which of
    // three meshes was meant.
    const availability = await environmentAvailability(declaredEnv);
    if (!availability.available) {
      $testInfo.annotations.push({ type: 'env-probe', description: availability.detail });
      $testInfo.skip(true, `@env:${declaredEnv} ${availability.reason}`);
    }
    // KIND + BROWSER needs the chromium resolver rules, because hugmesh.net does
    // not resolve on a developer box (verified: getent hosts hugmesh.net is
    // empty — that is exactly why `make kind-e2e` passes host-resolver-rules
    // rather than editing /etc/hosts). Without them the navigation dies on DNS,
    // which reads like "kind is broken" rather than "the runner is missing a
    // variable". Name the variable instead.
    if (declaredEnv === 'kind' && interfaceOf(dimensions) === 'browser'
        && !process.env.SNAP_HOST_RESOLVER) {
      $testInfo.skip(
        true,
        '@env:kind with @interface:browser needs chromium host-resolver rules: '
        + "hugmesh.net does not resolve on this host. Set SNAP_HOST_RESOLVER="
        + "'MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1' "
        + '(this is what `make kind-e2e` sets).',
      );
    }
  }

  // ── INTERFACE GATE ────────────────────────────────────────────────────────
  // browser is always available — Playwright resolved it before this hook ran.
  // cli and studio can genuinely be missing (no shell, no Qt binding), and a
  // studio scenario on a Qt-less host must say WHICH package is missing rather
  // than dying inside a python traceback four layers down.
  const iface = interfaceOf(dimensions);
  if (iface !== 'browser') {
    const ia = await interfaceAvailability(iface);
    if (!ia.available) {
      $testInfo.annotations.push({ type: 'interface-probe', description: ia.detail });
      $testInfo.skip(true, `@interface:${iface} ${ia.reason}`);
    }
  }

  // Record the resolved cell as annotations so a reporter/reader can pivot on it
  // without re-parsing the title. (The existing hugmesh reporter pivots off the
  // TITLE — which is why the convention puts @role:/@layer: in the scenario name
  // as well as in tags. See features/README.md.)
  //
  // Only DECLARED axes are annotated. The effective env/interface (which apply a
  // default) go into the evidence sidecar instead — annotating a default would
  // claim the author varied an axis they never touched.
  for (const [axis, value] of Object.entries(dimensions)) {
    if (value) $testInfo.annotations.push({ type: axis, description: String(value) });
  }
});

AfterStep(async ({ page, $bddContext, $step, $testInfo, dimensions }) => {
  stepOrdinal += 1;
  const ctx = $bddContext as BddContext;
  const featureUri = ctx?.featureUri || 'unknown.feature';
  const feature = path.basename(featureUri);
  const scenario = $testInfo.title;
  const stepTitle = $step?.title || `step-${stepOrdinal}`;
  const ordinal = String(stepOrdinal).padStart(3, '0');

  const dir = path.join(
    runDir(), slug(feature.replace(/\.feature$/, '')), slug(scenario, 80),
  );
  const stem = `${ordinal}-${slug(stepTitle, 70)}`;

  // THE SIDECAR SCHEMA. The pre-existing fields keep their exact names and
  // order; `env` and `interface` are the additions, and they carry the
  // EFFECTIVE value (default applied) rather than the declared one — a reader
  // asking "which mesh produced this PNG" needs the answer, not a null.
  const meta: StepMeta = {
    feature: featureUri,
    scenario,
    step: stepTitle,
    ordinal: stepOrdinal,
    role: dimensions.role ?? null,
    platform: dimensions.platform ?? null,
    service: dimensions.service ?? null,
    layer: dimensions.layer ?? null,
    env: envOf(dimensions),
    interface: interfaceOf(dimensions),
    failed: $step?.error !== undefined,
    at: new Date().toISOString(),
  };

  // Whatever this step actually did, regardless of what it was TAGGED as. A
  // browser-tagged scenario that shells out still gets its transcript.
  const pending = drainPending();

  try {
    const rows = await writeStepEvidence({
      dir,
      stem,
      meta,
      cli: pending.cli,
      studio: pending.studio,
      // Path-based attach: Playwright's HTML reporter only persists path-based
      // attachments into html/data — a body-based one attaches fine and then is
      // not there when you open the report.
      screenshot: async (dest) => { await page.screenshot({ path: dest, fullPage: false }); },
      renderTranscript: (t, dest) => renderTranscriptPng(page, t, dest),
    });
    appendManifest(rows);

    for (const r of rows) {
      const abs = path.join(runDir(), r.path);
      const png = r.path.endsWith('.png');
      await $testInfo.attach(`step ${stem} [${r.kind}]`, {
        path: abs,
        contentType: png ? 'image/png' : 'application/json',
      }).catch(() => { /* the artefact vanished; the manifest row still records it */ });
    }
    await $testInfo.attach(`step ${stem} meta`, {
      body: JSON.stringify(meta), contentType: 'application/json',
    });
  } catch (e) {
    // The page can be closed mid-step (context torn down by the scenario itself).
    // Do NOT swallow this silently — an evidence gap that leaves no trace is how
    // "the screenshots stopped working" goes unnoticed for weeks. Attach the
    // reason; never fail the step over it.
    await $testInfo.attach(`step ${stem} EVIDENCE-MISSING`, {
      body: `${stem}: ${(e as Error).message}`, contentType: 'text/plain',
    }).catch(() => { /* testInfo itself is gone; nothing left to record onto */ });
  }
});

// THE INDEX. manifest.jsonl is appended to during the run (O_APPEND, one line
// per artefact, so it survives a crash and so a workers>1 run cannot interleave
// a partial record); manifest.json is the browsable index built from it here.
//
// AfterAll runs per worker, and materializeManifest() rebuilds the WHOLE index
// from the JSONL every time, so N workers converge on the same complete file
// rather than each writing a partial one. It is also exported for a runner that
// needs to rebuild the index after a crashed run.
AfterAll(async () => {
  try {
    materializeManifest();
  } catch (e) {
    // Never fail a suite over its own bookkeeping — but never lose the fact
    // either. This lands on stderr where the runner captures it.
    process.stderr.write(
      `\n!! EVIDENCE MANIFEST NOT WRITTEN: ${(e as Error).message}\n`
      + `!! Rebuild it with: node -e "require('./steps/evidence').materializeManifest()"\n`,
    );
  }
});
