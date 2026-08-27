// studio-gui.steps.ts — driving the STUDIO GUI as an e2e interface, and proving
// its environment choice is the SAME choice the terminal makes.
//
// THE TWO THINGS THIS FILE EXISTS FOR
//
//  1. THE ENVIRONMENT IS ONE CONTRACT, NOT TWO. The operator can now pick
//     docker / kind / qemu inside the Studio. The failure mode that makes that
//     dangerous is not the picker — it is having TWO mechanisms, so the GUI's
//     idea of "kind" drifts from the harness's and a run launched from a button
//     silently drives a different mesh than the label says. Both front-ends go
//     through studio/hugmesh_studio/core/e2e_environments.plan(), which puts the
//     choice on ONE channel: SNAP_ENV on the child process — exactly what
//     `SNAP_ENV=kind make stack-e2e-bdd-env` sets and what steps/world.ts reads.
//     `the Studio GUI and the Studio CLI plan the same e2e run` compares the two
//     plans field by field, so a second mechanism cannot appear without a red test.
//
//  2. "SCREENSHOTS ... THROUGH GUI" MEANS THE STUDIO'S OWN SURFACES. A browser
//     step leaves a PNG of a web page; a Studio step leaves a Qt WIDGET GRAB of
//     the real PyQt wizard, taken offscreen (QT_QPA_PLATFORM=offscreen). Each
//     Gherkin step that drives the Studio produces its own grab, and the manifest
//     indexes every one — which is what makes a per-step GUI walk browsable
//     rather than a single end-of-run picture.
//
// STEP REUSE IS MANDATORY HERE. 250 step definitions already exist; a
// byte-identical duplicate makes bddgen AMBIGUOUS and generates ZERO scenarios
// (that cost a previous round its whole lane), and a REWORDED near-twin is worse
// because it generates fine and quietly splits the vocabulary. Everything this
// file needs and does not define — 'the Studio grab is a non-empty PNG', 'the
// command succeeded', 'the evidence manifest holds a {string} artefact for this
// scenario' — is reused from common.steps.ts. Grep before adding one:
//     grep -rn "the exact step text" tests/e2e/steps/
//
// NOTHING HERE STARTS AN ENVIRONMENT. Every step below either runs the Studio's
// Qt-free CLI channel or builds the wizard offscreen. Both are read-only with
// respect to every mesh, and `make stack-up` / `kind-up` / a QEMU launcher
// appear nowhere in any argv this file produces — that is asserted, not merely
// intended, by 'the Studio e2e plan starts no environment'.

import { expect } from '@playwright/test';
import { When, Then } from './world';
import { runCli, runStudio, REPO_ROOT } from './runners';
import { StudioGrab, manifestRowsForScenario, artefactPath, runDir } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as path from 'node:path';

/** The Studio's Qt-free CLI channel, rooted where `python -m hugmesh_studio` lives. */
const STUDIO_DIR = path.join(REPO_ROOT, 'studio');

/** PINNED world keys this file owns. Downstream steps may read them. */
const GUI_PLAN_KEY = 'studio.gui.plan';    // the plan the GUI reported
const CLI_PLAN_KEY = 'studio.cli.plan';    // the plan the CLI printed
const STUDIO_KEY = 'studio.grab';          // shared with common.steps.ts, on purpose

/** The plan shape core/e2e_environments.E2EPlan.to_dict() emits. */
interface E2EPlan {
  environment: string;
  argv: string[];
  env: Record<string, string>;
  refusals: string[];
  runnable: boolean;
  startHint: string;
  note: string;
  makeTarget: string;
  channel: string;
}

/** A grab that also carries what the page said about its environment. */
interface StudioEnvGrab extends StudioGrab {
  e2eEnvironment?: string;
  e2ePlan?: E2EPlan;
}

/**
 * Parse the driver's / the CLI's last stdout line as the plan object.
 *
 * Both channels put a single JSON object on the LAST line of stdout by contract
 * (studio-driver.py's header says so; app.py's --json verbs print one line).
 * Anything else — a Qt warning, a deprecation notice — goes to stderr, so a
 * lenient "find some JSON anywhere" parse would be hiding a broken contract
 * rather than tolerating noise.
 */
function lastJson<T>(stdout: string, what: string): T {
  const line = stdout.trim().split('\n').filter(Boolean).pop() ?? '';
  try {
    return JSON.parse(line) as T;
  } catch (e) {
    throw new Error(
      `${what} did not end with a JSON object. Last stdout line was:\n  ${line.slice(0, 400)}\n`
      + `(${(e as Error).message})`,
    );
  }
}

// ── driving the Studio GUI ───────────────────────────────────────────────────

/**
 * Build the REAL StudioWizard offscreen, move its e2e environment chooser to
 * the named environment, and grab the page.
 *
 * The driver REPORTS WHAT THE PAGE SAYS, not what we asked for (it calls
 * `page.e2e_environment()` back and fails if the two disagree), so this step
 * cannot pass on a chooser that silently ignored the selection. It also raises
 * the tab and scrolls the chooser into view before grabbing: without that the
 * PNG is a picture of a different tab — a plausible artefact of the wrong screen,
 * which passes for evidence and is worse than none.
 */
When('I drive the Studio e2e chooser to {string}', async ({ world }, envId: string) => {
  const grab = runStudio({ extraArgs: ['--e2e-env', envId] }) as StudioEnvGrab;
  let parsed: StudioEnvGrab = grab;
  try {
    const doc = lastJson<{ e2eEnvironment?: string; e2ePlan?: E2EPlan }>(
      grab.transcript.stdout, 'the Studio driver');
    parsed = { ...grab, e2eEnvironment: doc.e2eEnvironment, e2ePlan: doc.e2ePlan };
  } catch {
    // Leave the fields undefined; the assertions below name the driver's stderr,
    // which is where the real reason is. Throwing here would replace an
    // explainable failure with a parse error.
  }
  world.set(STUDIO_KEY, parsed);
  if (parsed.e2ePlan) world.set(GUI_PLAN_KEY, parsed.e2ePlan);
});

/** What the Studio PAGE says it will drive — read back from the live widget. */
Then('the Studio reports the {string} e2e environment', async ({ world }, envId: string) => {
  const g = world.get<StudioEnvGrab>(STUDIO_KEY);
  expect(
    g.e2eEnvironment,
    'the Studio driver reported no e2eEnvironment. Driver stderr:\n'
    + g.transcript.stderr.slice(0, 2000),
  ).toBe(envId);
});

// ── the CLI half of the same contract ────────────────────────────────────────

/**
 * Ask the Studio's Qt-FREE CLI channel what it would run. Same core function the
 * GUI calls, reached without a display or a Qt binding — which is the point:
 * if the two answers can differ, one of them is lying to its user.
 */
When('I ask the Studio CLI for the e2e plan for {string}', async ({ world }, envId: string) => {
  const t = runCli(
    [studioPython(), '-m', 'hugmesh_studio', '--e2e-plan', '--e2e-env', envId, '--json'],
    { cwd: STUDIO_DIR },
  );
  world.set('cli.transcript', t);
  if (t.exitCode === 0) world.set(CLI_PLAN_KEY, lastJson<E2EPlan>(t.stdout, '--e2e-plan --json'));
});

/**
 * THE ONE-CONTRACT ASSERTION. Field by field, because "both mention kind" is
 * satisfied by two mechanisms that agree today and drift tomorrow. argv, the
 * whole env dict and the channel name all have to match.
 */
Then('the Studio GUI and the Studio CLI plan the same e2e run', async ({ world }) => {
  const gui = world.get<E2EPlan>(GUI_PLAN_KEY);
  const cli = world.get<E2EPlan>(CLI_PLAN_KEY);
  expect(gui.environment, 'environment').toBe(cli.environment);
  expect(gui.argv, 'argv').toEqual(cli.argv);
  expect(gui.env, 'the environment handed to the run').toEqual(cli.env);
  expect(gui.channel, 'the channel the choice rides on').toBe(cli.channel);
  expect(gui.runnable, 'runnable').toBe(cli.runnable);
  expect(gui.refusals, 'refusals').toEqual(cli.refusals);
});

// ── assertions on a plan, whichever channel produced it ──────────────────────

/** Read whichever plan this scenario most recently produced, GUI first. */
function currentPlan(world: { has(k: string): boolean; get<T>(k: string): T }): E2EPlan {
  if (world.has(GUI_PLAN_KEY)) return world.get<E2EPlan>(GUI_PLAN_KEY);
  return world.get<E2EPlan>(CLI_PLAN_KEY);
}

/**
 * THE LOAD-BEARING ONE. The chosen environment must actually reach the spawned
 * runner's environment — that single key is the whole contract with world.ts,
 * and a plan that dropped it would run against docker while every label said
 * otherwise. The guard battery deletes exactly this key.
 */
Then('the e2e plan pins {string} to {string}', async ({ world }, key: string, value: string) => {
  const p = currentPlan(world);
  expect(
    p.env[key],
    `the plan for '${p.environment}' does not carry ${key}=${value}. `
    + `Its environment is: ${JSON.stringify(p.env)}`,
  ).toBe(value);
});

Then('the e2e plan runs {string}', async ({ world }, cmd: string) => {
  const p = currentPlan(world);
  expect(p.argv.join(' '), 'the plan argv').toContain(cmd);
});

Then('the e2e plan is runnable', async ({ world }) => {
  const p = currentPlan(world);
  expect(p.runnable, `refused: ${p.refusals.join(' | ')}`).toBe(true);
});

/**
 * A refusal must be a SENTENCE THE OPERATOR CAN ACT ON. Asserting only that
 * `runnable` is false would pass for a refusal that says nothing, which is how
 * a disabled control comes to read as "the app is broken".
 */
Then('the e2e plan is refused, naming {string}', async ({ world }, needle: string) => {
  const p = currentPlan(world);
  expect(p.runnable, 'the plan was runnable; it was expected to be refused').toBe(false);
  expect(p.refusals.join('\n'), 'the refusal text').toContain(needle);
});

/**
 * NEITHER FRONT-END MAY START A MESH. The harness already forbids it for its own
 * runners ("a step naming `make stack-up` is a bug"); this asserts the same for
 * anything the Studio would spawn, so a future convenience that "just brings the
 * cluster up first" cannot land quietly. The list is read from the Python module,
 * not restated here, so adding a forbidden command extends this check for free.
 */
Then('the e2e plan starts no environment', async ({ world }) => {
  const p = currentPlan(world);
  const t = runCli(
    [studioPython(), '-c',
      'import json,sys;sys.path.insert(0,"studio");'
      + 'from hugmesh_studio.core import e2e_environments as e;'
      + 'print(json.dumps(list(e.BOOT_COMMANDS)))'],
    { cwd: REPO_ROOT },
  );
  expect(t.exitCode, `could not read BOOT_COMMANDS: ${t.stderr}`).toBe(0);
  const forbidden = lastJson<string[]>(t.stdout, 'BOOT_COMMANDS');
  expect(forbidden.length, 'BOOT_COMMANDS is empty — this check would be vacuous')
    .toBeGreaterThan(0);
  const line = p.argv.join(' ');
  const hits = forbidden.filter((c) => line.includes(c));
  expect(hits, `the plan for '${p.environment}' would run ${line}, which starts or `
    + 'elevates something. Plans run the suite against a mesh that is ALREADY '
    + 'serving; bringing one up is the operator\'s act, not the Studio\'s.')
    .toEqual([]);
});

// ── per-step GUI evidence ────────────────────────────────────────────────────

/**
 * THE ANTI-DECORATION CHECK FOR THE GUI LANE. Every step of this scenario that
 * drove the Studio must have left a widget grab that is a real, non-empty PNG on
 * disk — and the manifest must know about it.
 *
 * BOTH DIRECTIONS MATTER. A manifest row with no file is a lie a reviewer counts
 * and believes; a file with no row is coverage nobody can find. The mutation
 * battery plants the first one deliberately (the grab is not written but the row
 * is still emitted) and requires this to go red.
 */
Then('a Qt widget grab exists on disk for every Studio step so far', async ({ $testInfo }) => {
  const rows = manifestRowsForScenario($testInfo.title);
  const grabs = rows.filter((r) => r.kind === 'widget-grab');
  expect(
    grabs.length,
    'this scenario recorded ZERO widget-grab rows. Kinds present: '
    + `${[...new Set(rows.map((r) => r.kind))].join(', ') || '<none>'}`,
  ).toBeGreaterThan(0);
  const bad: string[] = [];
  for (const r of grabs) {
    const abs = artefactPath(r);
    let size = -1;
    try { size = fs.statSync(abs).size; } catch { size = -1; }
    if (size <= 0) bad.push(`${r.path} (${size < 0 ? 'absent' : 'empty'})`);
    else {
      // A PNG, not merely a file with a .png name. The 8-byte signature is the
      // cheapest way to catch a writer that created the path and wrote nothing
      // useful into it.
      const head = fs.readFileSync(abs).subarray(0, 8);
      if (head.toString('hex') !== '89504e470d0a1a0a') bad.push(`${r.path} (not a PNG)`);
    }
  }
  expect(
    bad,
    'the manifest claims widget grabs that are not real PNGs on disk:\n  '
    + `${bad.join('\n  ')}\nA manifest that lies is worse than no manifest.`,
  ).toEqual([]);
});

/**
 * The manifest's own dimensions are populated for this scenario's rows — so the
 * evidence browser can group by environment and interface rather than showing a
 * flat pile of files. A row with an empty env or interface would silently bucket
 * under '<unset>' in the Studio's tree.
 */
Then('every evidence row for this scenario names an environment and an interface',
  async ({ $testInfo }) => {
    const rows = manifestRowsForScenario($testInfo.title);
    expect(rows.length, 'this scenario recorded ZERO evidence rows').toBeGreaterThan(0);
    const bad = rows
      .filter((r) => !r.env || !r.interface)
      .map((r) => `${r.kind} ${r.path}: env=${JSON.stringify(r.env)} `
                + `interface=${JSON.stringify(r.interface)}`);
    expect(bad, `rows missing a dimension:\n  ${bad.join('\n  ')}`).toEqual([]);
  });

/**
 * The Studio's evidence READER agrees with the run that produced the evidence.
 * This is the consumer contract exercised end to end: the same manifest the
 * AfterStep hook wrote is loaded by core/e2e_evidence (the module the Studio's
 * browser renders) and its verification must come back clean.
 *
 * It runs the reader over the CURRENT run's directory, so it is checking this
 * scenario's own artefacts rather than a fixture that agrees with itself.
 */
Then('the Studio evidence reader verifies this run', async ({ world }) => {
  // runDir() is the SAME directory the AfterStep hook is writing into, so this
  // reads this run's own artefacts rather than a fixture that agrees with itself.
  //
  // --e2e-evidence-live IS LOAD-BEARING, and finding out why cost a measured
  // detour. manifest.json is NOT written once at the end: playwright-bdd's
  // AfterAll is Playwright's test.afterAll, which fires at the end of every
  // generated feature spec FILE, so the index is rewritten dozens of times per
  // run and is TRUNCATED while the suite is in flight. Measured on a
  // 115-scenario lane: this step read a 188-row manifest.json and reported 170
  // perfectly good artefacts as unindexed, while the append log already held
  // 293 rows and the finished run held 407. Reading the APPEND LOG has no such
  // window — a step's artefacts are written and then its rows appended,
  // synchronously, inside one AfterStep.
  const runDirPath = runDir();
  const t = runCli(
    [studioPython(), '-m', 'hugmesh_studio', '--e2e-evidence', runDirPath,
      '--e2e-evidence-live', '--json'],
    { cwd: STUDIO_DIR },
  );
  world.set('cli.transcript', t);
  const doc = lastJson<{ verification: { ok: boolean; summary: string;
                                         missing: string[]; orphans: string[] };
                         problems: string[]; counts: { rows: number } }>(
    t.stdout, '--e2e-evidence --json');
  expect(doc.counts.rows, 'the reader found ZERO artefacts in this run').toBeGreaterThan(0);
  expect(
    doc.verification.ok,
    `the Studio's evidence reader rejects this run (${doc.counts.rows} rows): `
    + `${doc.verification.summary}\n`
    + `missing: ${doc.verification.missing.slice(0, 20).join(', ')}\n`
    + `orphans: ${doc.verification.orphans.slice(0, 20).join(', ')}\n`
    + `problems: ${doc.problems.join('; ')}`,
  ).toBe(true);
});
