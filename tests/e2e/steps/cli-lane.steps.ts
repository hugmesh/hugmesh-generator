// cli-lane.steps.ts — steps for driving THIS REPO'S OWN command-line surfaces.
//
// The interface axis (steps/dimensions.ts) says a mesh function driven from a
// terminal is a different code path from the same function driven from a
// browser. common.steps.ts already gives the generic terminal vocabulary — run
// a shell command, assert the exit code, assert the output. What it does not
// give is a way to assert on a STRUCTURED answer, which is what every
// machine-readable surface in this repo actually returns (`--json`,
// `--print-specs`, `--print-command`, `make ... JSON=1`). Asserting on a
// substring of a JSON blob passes for the wrong reasons: "kind" appears in
// `https://hugmesh.net:8443` only by luck, and `"env":"kind"` is what was meant.
//
// FOUR steps, all new — checked against the 250 already defined:
//   grep -rn "I run the e2e CLI with" tests/e2e/steps/            -> nothing
//   grep -rn "the command output JSON field" tests/e2e/steps/     -> nothing
// None of them reword an existing step. The generic cli steps
// (`I run the shell command`, `the command succeeded`, `the command output
// contains`) are REUSED as-is, and this file deliberately defines no near-twin
// of them.

import { expect } from '@playwright/test';
// When/Then come from './world' ONLY. A second createBdd() binds to a DIFFERENT
// playwright-bdd instance than world.ts's fixtures, and the steps defined here
// would silently never see `world` or the evidence hooks. This is written down
// in world.ts and in three other step files; it is not a style preference.
import { When, Then } from './world';
import { runCli, REPO_ROOT } from './runners';
import { CliTranscript } from './evidence';
import { environmentBaseUrl } from './dimensions';

// The pinned world key common.steps.ts uses. Same key on purpose: a scenario
// may run the e2e CLI and then assert with `the command exit code was N`, and
// two transcript slots would make "the command" ambiguous in the Gherkin.
const CLI_KEY = 'cli.transcript';

/**
 * The READ-ONLY modes of tests/e2e/run.sh. A Gherkin scenario runs INSIDE a
 * Playwright worker; letting it invoke a mode that executes the suite would
 * recurse, and letting it invoke `--gen` would run bddgen against
 * .features-gen/ — SHARED MUTABLE STATE — under an in-flight run, silently
 * invalidating the specs currently executing. Both are refused here rather than
 * documented in a comment nobody reads at 2am.
 */
const READ_ONLY_MODES = ['--print-command', '--evidence', '--help', '-h'];

/**
 * Drive this repo's e2e CLI entry point, the same `tests/e2e/run.sh` a human
 * types. Arguments are split on whitespace — anything needing quoting belongs
 * in `I run the shell command` instead, exactly as the Studio CLI step already
 * rules.
 */
When('I run the e2e CLI with {string}', async ({ world }, args: string) => {
  const argv = args.split(/\s+/).filter(Boolean);
  if (!argv.some((a) => READ_ONLY_MODES.includes(a))) {
    throw new Error(
      `refusing to run 'tests/e2e/run.sh ${args}' from inside a scenario: only the `
      + `read-only modes (${READ_ONLY_MODES.join(', ')}) are allowed here. A mode that `
      + `EXECUTES the lane would recurse, and --gen would rewrite .features-gen/ — `
      + `shared mutable state — underneath the run that is asking.`,
    );
  }
  world.set(CLI_KEY, runCli(['bash', 'tests/e2e/run.sh', ...argv], { cwd: REPO_ROOT }));
});

// -- structured assertions on a transcript -----------------------------------

/** Parse the LAST non-empty stdout line, the convention every surface here follows. */
function outputJson(t: CliTranscript): unknown {
  const last = t.stdout.trim().split('\n').filter(Boolean).pop() ?? '';
  try {
    return JSON.parse(last);
  } catch (e) {
    throw new Error(
      `\`${t.command}\` did not end with a JSON line (${(e as Error).message}).\n`
      + `--- last stdout line ---\n${last.slice(0, 400)}\n`
      + `--- stderr ---\n${t.stderr.slice(0, 400)}`,
    );
  }
}

/** Resolve a dotted path; array indices are plain integers ('argv.0'). */
function dig(root: unknown, dotted: string): { found: boolean; value: unknown } {
  let cur: unknown = root;
  for (const key of dotted.split('.')) {
    if (cur === null || typeof cur !== 'object') return { found: false, value: undefined };
    const bag = cur as Record<string, unknown>;
    if (!(key in bag)) return { found: false, value: undefined };
    cur = bag[key];
  }
  return { found: true, value: cur };
}

function field(t: CliTranscript, path: string): unknown {
  const json = outputJson(t);
  const hit = dig(json, path);
  expect(
    hit.found,
    `\`${t.command}\` output has no field '${path}'. Top-level keys: `
    + `${json && typeof json === 'object' ? Object.keys(json as object).join(', ') : typeof json}`,
  ).toBe(true);
  return hit.value;
}

/**
 * Compare as STRINGS on purpose. Gherkin has no types, `1` and `"1"` are the
 * same cell, and a step that guessed would be a coin flip a feature author
 * cannot see.
 */
Then('the command output JSON field {string} is {string}',
  async ({ world }, path: string, expected: string) => {
    const t = world.get<CliTranscript>(CLI_KEY);
    const v = field(t, path);
    expect(String(v), `\`${t.command}\` -> ${path}`).toBe(expected);
  });

Then('the command output JSON field {string} contains {string}',
  async ({ world }, path: string, needle: string) => {
    const t = world.get<CliTranscript>(CLI_KEY);
    const v = field(t, path);
    const hay = Array.isArray(v) ? v.map((x) => String(x)) : [String(v)];
    expect(hay.join(' '), `\`${t.command}\` -> ${path} = ${JSON.stringify(v)}`)
      .toContain(needle);
  });

/** Counting evidence. `at least` rather than an exact count: the number grows. */
Then('the command output JSON field {string} is at least {int}',
  async ({ world }, path: string, floor: number) => {
    const t = world.get<CliTranscript>(CLI_KEY);
    const v = field(t, path);
    const n = typeof v === 'number' ? v : Number(v);
    expect(Number.isFinite(n), `\`${t.command}\` -> ${path} = ${JSON.stringify(v)} is not a number`)
      .toBe(true);
    expect(n, `\`${t.command}\` -> ${path}`).toBeGreaterThanOrEqual(floor);
  });

/**
 * THE ANTI-DRIFT ASSERTION, and the reason this file exists at all.
 *
 * Two resolvers now answer "where is the <env> mesh": the bash table in
 * tests/e2e/run.sh (which must set SNAP_BASE_URL before Playwright starts, so
 * it cannot ask the TypeScript) and ENVIRONMENT_DEFS in steps/dimensions.ts
 * (which the running scenarios use). Two resolvers for one fact drift, and the
 * failure is silent: the CLI points chromium at one mesh while the skip reasons
 * name another. This step RESOLVES BOTH and compares, so the drift is a red
 * scenario rather than a confusing afternoon.
 */
Then('the command output JSON field {string} is the {string} environment base URL',
  async ({ world }, path: string, envId: string) => {
    const t = world.get<CliTranscript>(CLI_KEY);
    const v = String(field(t, path));
    expect(
      v,
      `tests/e2e/run.sh resolved '${envId}' to ${v}, but steps/dimensions.ts's `
      + `ENVIRONMENT_DEFS.${envId}.baseUrl() says ${environmentBaseUrl(envId)}. The CLI `
      + `would drive one mesh while the harness described another.`,
    ).toBe(environmentBaseUrl(envId));
  });
