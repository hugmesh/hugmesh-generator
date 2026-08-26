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
import { Dimensions, resolveDimensions, requireDimension } from './dimensions';

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
    // Throws here on an unknown persona/service/platform — before a single
    // browser action runs, with the legal values in the message.
    await use(resolveDimensions($tags, $testInfo.titlePath.join(' ')));
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

/** Base dir for per-step evidence — under the REPORT dir, never the git tree. */
export const BDD_SHOTS = path.resolve(
  process.env.SNAP_BDD_SHOTS
  || path.join(process.env.SNAP_REPORT_DIR || 'test-results', 'bdd-steps'),
);

/** Per-run subdir, keyed the same way the hugmesh reporter keys summary.json. */
const RUN_ID = process.env.SNAP_RUN_ID || 'dev';

function slug(s: string, max = 60): string {
  return (s.replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '') || 'unnamed').slice(0, max);
}

/** Per-scenario ordinal. Reset in Before; incremented in AfterStep. */
let stepOrdinal = 0;

Before(async ({ dimensions, $testInfo }) => {
  stepOrdinal = 0;
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
  // Record the resolved cell as annotations so a reporter/reader can pivot on it
  // without re-parsing the title. (The existing hugmesh reporter pivots off the
  // TITLE — which is why the convention puts @role:/@layer: in the scenario name
  // as well as in tags. See features/README.md.)
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
    BDD_SHOTS, slug(RUN_ID), slug(feature.replace(/\.feature$/, '')), slug(scenario, 80),
  );
  const stem = `${ordinal}-${slug(stepTitle, 70)}`;
  const meta = {
    feature: featureUri,
    scenario,
    step: stepTitle,
    ordinal: stepOrdinal,
    role: dimensions.role ?? null,
    platform: dimensions.platform ?? null,
    service: dimensions.service ?? null,
    layer: dimensions.layer ?? null,
    failed: $step?.error !== undefined,
    at: new Date().toISOString(),
  };

  try {
    fs.mkdirSync(dir, { recursive: true });
    const png = path.join(dir, `${stem}.png`);
    const json = path.join(dir, `${stem}.json`);
    // Path-based attach: Playwright's HTML reporter only persists path-based
    // attachments into html/data — a body-based one attaches fine and then is
    // not there when you open the report.
    await page.screenshot({ path: png, fullPage: false });
    fs.writeFileSync(json, JSON.stringify(meta, null, 2));
    await $testInfo.attach(`step ${stem}`, { path: png, contentType: 'image/png' });
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
