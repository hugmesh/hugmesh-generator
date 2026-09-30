// studio.steps.ts — the STUDIO lane's own vocabulary: driving the Studio for a
// KNOWN config, reading what a page SAYS, the Qt-free CLI channels on a fixture,
// and the TUI journey. Everything here is offline: nothing starts a mesh, a
// cluster, a device or a build, and nothing elevates.
//
// WHY A SECOND STUDIO STEPS FILE. studio-gui.steps.ts owns the e2e-chooser
// contract (the GUI and the CLI plan the same run). This file owns the
// issue-fenced coverage written on 2026-09-23 (features/studio/*.feature, each
// scenario tagged @issue:generator-<n>): the per-domain services gate (#494/#495),
// config -> argv honesty on the --print-command / --print-specs channels
// (#335, #384, #482, #521, #266), the TUI's ported / stubbed steps (#517, #518,
// #519, #524), the pre-merge test-suite hygiene (#537) and the Studio
// operator's CLI-only checks (#303). Keeping them apart keeps the chooser
// guard's mutation battery (tests/scripts/test-e2e-studio-gui-lane.sh) reading
// the file it was written against.
//
// STEP REUSE IS MANDATORY. Everything this file needs and does not define —
// 'I grab the Studio wizard page {string}', 'the Studio grab is a non-empty PNG',
// 'the Studio grab shows the wizard page {string}', 'I run the shell command',
// 'I run the Studio CLI with', 'the command succeeded/failed', 'the command exit
// code was N', 'the command output contains', 'this scenario is PENDING because'
// — is reused from common.steps.ts / moderation-media.steps.ts. A duplicate
// step text is a hard generation error, and a reworded near-twin is worse.
// Grep before adding one:  grep -rn "the exact step text" tests/e2e/steps/
//
// ONE STEP HERE IS A CANDIDATE FOR common.steps.ts: 'the command output does not
// contain {string}'. It is the negation every argv-honesty scenario needs and
// belongs beside 'the command output contains'. It is defined HERE only because
// this lane may not edit the shared file; the catalogue lane is asked to lift
// it (needs_from_catalogue). If it lands there first, delete it here.
//
// WHAT "WHAT THE PAGE SAYS" MEANS. tests/e2e/studio-driver.py reports, beside
// the PNG, every visible label / header / row (`texts`) and every button, card,
// checkbox and checkable row with its enabled state (`controls`). A PNG proves a
// page rendered; it cannot prove the refusal names the right domain or that the
// Continue card is disabled. The Studio is Qt and has no test ids, so a control
// is named by its VISIBLE TEXT — the same way the manual test plans (#303) name
// them. Steps below read that report, never the picture.

import { expect } from '@playwright/test';
import { Given, When, Then } from './world';
import { runCli, runStudio, scratchDir, REPO_ROOT } from './runners';
import { StudioGrab, CliTranscript } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as path from 'node:path';

/** The Studio's Qt-free CLI channel, rooted where `python -m hugmesh_studio` lives. */
const STUDIO_DIR = path.join(REPO_ROOT, 'studio');

/** World keys. The first two are SHARED with common.steps.ts on purpose. */
const CLI_KEY = 'cli.transcript';
const STUDIO_KEY = 'studio.grab';
const FIXTURE_KEY = 'studio.config.fixture';

/** One control on a grabbed page, as studio-driver.py reports it. */
interface PageControl {
  kind: string;
  text: string;
  enabled: boolean;
  visible: boolean;
  tristate?: boolean;
  checkState?: number;
}

/** The driver's result object, the part this file reads. */
interface PageReport {
  ok?: boolean;
  page?: string;
  texts?: string[];
  controls?: PageControl[];
  error?: string;
}

/**
 * Parse the driver's / the CLI's last stdout line as a JSON object.
 *
 * Both channels put a single JSON object on the LAST line of stdout by contract
 * (studio-driver.py's header says so; app.py's --json verbs print one line).
 * A lenient "find some JSON anywhere" parse would hide a broken contract.
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

/** The page report behind the most recent Studio grab, or a loud failure. */
function pageReport(world: { get<T>(k: string): T }): Required<Pick<PageReport, 'texts' | 'controls'>> & PageReport {
  const g = world.get<StudioGrab>(STUDIO_KEY);
  let doc: PageReport;
  try {
    doc = lastJson<PageReport>(g.transcript.stdout, 'the Studio driver');
  } catch (e) {
    throw new Error(
      `${(e as Error).message}\n--- driver stderr ---\n${g.transcript.stderr.slice(0, 2000)}`,
    );
  }
  if (!doc.ok) {
    throw new Error(
      `the Studio driver did not grab (${doc.error ?? 'no error given'})\n`
      + `--- driver stderr ---\n${g.transcript.stderr.slice(0, 2000)}`,
    );
  }
  return { ...doc, texts: doc.texts ?? [], controls: doc.controls ?? [] };
}

/** Visible controls whose text matches `name` — exact first, then substring. */
function visibleControls(report: { controls: PageControl[] }, name: string): PageControl[] {
  const visible = report.controls.filter((c) => c.visible);
  const exact = visible.filter((c) => c.text === name);
  return exact.length ? exact : visible.filter((c) => c.text.includes(name));
}

function describeControls(report: { controls: PageControl[] }): string {
  return report.controls
    .filter((c) => c.visible && c.text)
    .map((c) => `${c.kind} '${c.text.slice(0, 60)}' enabled=${c.enabled}`)
    .join('\n  ') || '<no visible controls with text>';
}

/** Where fixtures and helper scripts may be written. Never the git tree. */
function laneScratch(sub: string): string {
  const dir = path.join(scratchDir(), 'studio-lane', sub);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function uniqueName(prefix: string, ext: string): string {
  return `${prefix}-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}${ext}`;
}

/** Run a small Python program against the Studio package, Qt-free, offline. */
function runStudioPython(script: string, args: string[], env: Record<string, string> = {}): CliTranscript {
  return runCli([studioPython(), '-c', script, ...args], {
    cwd: STUDIO_DIR,
    env: { QT_QPA_PLATFORM: 'offscreen', ...env },
  });
}

// ── a config fixture, and the two Qt-free channels that read it ──────────────

/**
 * Write the docstring as a saved Studio config. The FILE is what the channels
 * below take (`--config` needs a path, not inline JSON), and writing it from the
 * Gherkin keeps the whole contract readable in the feature: the reader sees
 * exactly which fields were set, and can reproduce the command by hand.
 */
Given('a Studio config JSON fixture:', async ({ world }, doc: string) => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(doc);
  } catch (e) {
    throw new Error(`the fixture docstring is not JSON (${(e as Error).message}):\n${doc}`);
  }
  const file = path.join(laneScratch('fixtures'), uniqueName('cfg', '.json'));
  fs.writeFileSync(file, `${JSON.stringify(parsed, null, 2)}\n`);
  world.set(FIXTURE_KEY, file);
});

/**
 * The headless single-build command channel — the argv the GUI's Review page
 * previews and docker/build-image.sh feeds back. `--backend native` pins a
 * deterministic command on any host (the in-repo test precedent,
 * studio/tests/test_vault_config.py::test_print_command_carries_the_vault_flags).
 * stdout IS the argv channel: every consumer parses it, so the transcript holds
 * the exact bytes a build would get.
 */
When('I run the Studio CLI print-command on that config fixture', async ({ world }) => {
  const file = world.get<string>(FIXTURE_KEY);
  world.set(CLI_KEY, runCli(
    [studioPython(), '-m', 'hugmesh_studio', '--print-command', '--config', file, '--backend', 'native'],
    { cwd: STUDIO_DIR },
  ));
});

/**
 * The per-image SPEC channel (JSONL, one materialised config per line, secrets
 * blanked) — what a Studio-authored domains table looks like once it has been
 * loaded, materialised and serialised again. A field the loader DROPS is absent
 * here, which is how a schema that has not landed yet shows up as red.
 */
When('I run the Studio CLI print-specs on that config fixture', async ({ world }) => {
  const file = world.get<string>(FIXTURE_KEY);
  world.set(CLI_KEY, runCli(
    [studioPython(), '-m', 'hugmesh_studio', '--print-specs', '--config', file],
    { cwd: STUDIO_DIR },
  ));
});

/**
 * THE GATE SEAM. core.domain_services.gate_reason(cfg, action) is the ONE
 * function every refusal door calls — the image build (gui/pages/launch.py),
 * both docker mesh-start doors (gui/pages/localmesh.py _bootstrap_up and
 * _start_saved) and the previous-builds restart — and the module says so is why
 * it exists: "a test can drive the refusal with a bare ImageConfig, no Qt, no
 * wizard, no build, no docker". The mesh-start doors are click handlers on a
 * page the offscreen driver cannot click, so the seam is how a scenario reaches
 * their verdict. The `action` is the literal the page passes
 * ("build these images" / "start this mesh"); stdout is the refusal sentence, or
 * empty when the action may proceed.
 */
When('I ask the Studio gate seam whether that config fixture may {string}',
  async ({ world }, action: string) => {
    const file = world.get<string>(FIXTURE_KEY);
    world.set(CLI_KEY, runStudioPython(
      'import sys\n'
      + 'from hugmesh_studio.core.config import ImageConfig\n'
      + 'from hugmesh_studio.core.domain_services import gate_reason\n'
      + 'cfg = ImageConfig.load(sys.argv[1])\n'
      + 'sys.stdout.write(gate_reason(cfg, sys.argv[2]))\n',
      [file, action],
    ));
  });

// ── driving the Studio for a KNOWN config, and reading what the page says ────

/**
 * Build the REAL StudioWizard offscreen, load the fixture through the GUI's own
 * "Load config…" loader, jump to the named page and grab it. The result carries
 * the page's visible texts and controls (see the header), which the assertions
 * below read.
 */
When('I grab the Studio wizard page {string} with that config fixture',
  async ({ world }, page: string) => {
    const file = world.get<string>(FIXTURE_KEY);
    world.set(STUDIO_KEY, runStudio({ page, extraArgs: ['--config', file] }));
  });

/** A visible label / header / row on the grabbed page contains this text. */
Then('the Studio page says {string}', async ({ world }, needle: string) => {
  const r = pageReport(world);
  expect(
    r.texts.some((t) => t.includes(needle)),
    `page '${r.page}' shows no text containing ${JSON.stringify(needle)}. It says:\n  `
    + r.texts.map((t) => t.slice(0, 140)).join('\n  '),
  ).toBe(true);
});

/** No visible text on the grabbed page contains this — a hidden label does not count as shown. */
Then('the Studio page does not say {string}', async ({ world }, needle: string) => {
  const r = pageReport(world);
  const hits = r.texts.filter((t) => t.includes(needle));
  expect(hits, `page '${r.page}' shows text containing ${JSON.stringify(needle)}:\n  ${hits.join('\n  ')}`)
    .toEqual([]);
});

/**
 * A visible control named by its text is DISABLED. Both directions are asserted
 * by name so a control that vanished cannot pass as "disabled": the control has
 * to be on the page first.
 */
Then('the Studio control {string} is disabled', async ({ world }, name: string) => {
  const r = pageReport(world);
  const found = visibleControls(r, name);
  expect(found.length, `no visible control named ${JSON.stringify(name)} on page '${r.page}'. Visible controls:\n  ${describeControls(r)}`)
    .toBeGreaterThan(0);
  expect(found.every((c) => !c.enabled), `${JSON.stringify(name)} is enabled on page '${r.page}'`).toBe(true);
});

Then('the Studio control {string} is enabled', async ({ world }, name: string) => {
  const r = pageReport(world);
  const found = visibleControls(r, name);
  expect(found.length, `no visible control named ${JSON.stringify(name)} on page '${r.page}'. Visible controls:\n  ${describeControls(r)}`)
    .toBeGreaterThan(0);
  expect(found.every((c) => c.enabled), `${JSON.stringify(name)} is disabled on page '${r.page}'`).toBe(true);
});

/**
 * A services-table row (network page) carries a TRI-STATE control — the shape
 * #384 asks for on the anubis row (ENV default / force on / force off). Today's
 * rows are two-state QCheckBoxes set as item widgets; the driver reports each
 * row with its box's isTristate(), so this goes green only when the row really
 * offers a third state, not when a label says it does.
 */
Then('the Studio services row {string} offers a tri-state control', async ({ world }, slug: string) => {
  const r = pageReport(world);
  const rows = r.controls.filter((c) => c.kind === 'TreeItem'
    && (c.text === slug || c.text.startsWith(`${slug} |`)));
  expect(rows.length, `no services row for ${JSON.stringify(slug)} on page '${r.page}'. Rows:\n  `
    + r.controls.filter((c) => c.kind === 'TreeItem').map((c) => c.text.slice(0, 60)).join('\n  '))
    .toBeGreaterThan(0);
  expect(rows.every((c) => c.tristate === true),
    `the ${slug} row is a two-state tick (tristate=${JSON.stringify(rows.map((c) => c.tristate))}); `
    + '#384 asks for ENV default / force on / force off').toBe(true);
});

// ── transcript assertions the shared vocabulary lacks ────────────────────────

/**
 * The negation of common.steps.ts 'the command output contains {string}'. Same
 * haystack (stdout + stderr), so "does not contain" cannot be satisfied by a
 * needle that merely moved streams.
 */
Then('the command output does not contain {string}', async ({ world }, needle: string) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  const hay = `${t.stdout}\n${t.stderr}`;
  expect(
    hay.includes(needle),
    `\`${t.command}\` output contains ${JSON.stringify(needle)}, which it must not:\n${hay.slice(0, 1500)}`,
  ).toBe(false);
});

/**
 * stdout is EXACTLY one line — byte-for-byte, trailing newline included. This
 * is for channels whose stdout is consumed verbatim by another program (the
 * askpass password channel, the argv channel): a banner, a prompt or a second
 * line is a contract break, not noise.
 */
Then('the command stdout is exactly the line {string}', async ({ world }, line: string) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.stdout, `\`${t.command}\` stdout (${JSON.stringify(t.stdout.slice(0, 200))})`).toBe(`${line}\n`);
});

Then('the command stdout is empty', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.stdout, `\`${t.command}\` wrote ${t.stdout.length} bytes to stdout`).toBe('');
});

Then('the command stderr is exactly the line {string}', async ({ world }, line: string) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.stderr, `\`${t.command}\` stderr (${JSON.stringify(t.stderr.slice(0, 200))})`).toBe(`${line}\n`);
});

Then('the command stderr is empty', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.stderr, `\`${t.command}\` wrote to stderr:\n${t.stderr.slice(0, 500)}`).toBe('');
});

/**
 * The last stdout line is a JSON OBJECT whose key set is EXACTLY the given
 * comma-separated list. Set equality, not "contains": a scan that grew a key
 * nobody documented and one that lost a key both fail by name.
 */
Then('the command output JSON object has exactly the keys {string}', async ({ world }, keys: string) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  const doc = lastJson<Record<string, unknown>>(t.stdout, `\`${t.command}\``);
  const want = keys.split(',').map((k) => k.trim()).filter(Boolean).sort();
  expect(Object.keys(doc).sort(), 'the JSON object\'s keys').toEqual(want);
});

// ── the TUI journey, driven without a terminal ───────────────────────────────

/**
 * Render ONE journey step through the face-independent state machine
 * (hugmesh_studio.tui.journey.Journey — the same object both the urwid and the
 * plain face drive), landing on it by slug exactly as the GUI's --page jump
 * does. stdout is the screen's lines. A step the TUI has not ported renders the
 * honesty stub (journey.PENDING_NOTE / PendingSideFlow), which is the text the
 * #517/#518/#519 scenarios assert AGAINST.
 */
When('I open the Studio TUI journey step {string}', async ({ world }, slug: string) => {
  world.set(CLI_KEY, runStudioPython(
    'import sys\n'
    + 'from hugmesh_studio.tui.journey import Journey\n'
    + 'j = Journey(sys.argv[1])\n'
    + 'j.goto(sys.argv[2])\n'
    + 'print("\\n".join(j.lines()))\n',
    [REPO_ROOT, slug],
  ));
});

/**
 * Drive the PLAIN TUI face (`python -m hugmesh_studio.tui --plain`) with typed
 * lines — `;`-separated, each followed by Enter — over a pipe, exactly as a
 * scripted terminal would. The plain face is the one that runs when no TTY or
 * no urwid is present, so this needs neither. Read-only: the journey reads the
 * sessions directory to list previous builds and writes nothing; never type a
 * `d` (delete) line here.
 */
When('I drive the plain Studio TUI typing {string}', async ({ world }, typed: string) => {
  const input = `${typed.split(';').map((s) => s.trim()).join('\n')}\n`;
  world.set(CLI_KEY, runCli(
    [studioPython(), '-m', 'hugmesh_studio.tui', '--plain'],
    { cwd: STUDIO_DIR, input, env: { NO_TUI: '1', TERM: 'dumb' } },
  ));
});

/** The `_SIDE_FLOW_STUB = {...}` block of journey.py: its keys and the comment block above it. */
function sideFlowStub(): { keys: string[]; comment: string; file: string } {
  const file = path.join(STUDIO_DIR, 'hugmesh_studio', 'tui', 'journey.py');
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const start = lines.findIndex((l) => /^_SIDE_FLOW_STUB\s*=\s*\{/.test(l));
  expect(start, `${file} has no '_SIDE_FLOW_STUB = {' line`).toBeGreaterThanOrEqual(0);
  const keys: string[] = [];
  for (let i = start; i < lines.length; i += 1) {
    const m = /^\s*"([a-z0-9_-]+)"\s*:/.exec(lines[i]);
    if (m) keys.push(m[1]);
    if (/^\}/.test(lines[i])) break;
  }
  const comment: string[] = [];
  for (let i = start - 1; i >= 0 && /^\s*#/.test(lines[i]); i -= 1) comment.unshift(lines[i]);
  return { keys, comment: comment.join('\n'), file };
}

/**
 * #519's "Done when", both arms: the side flow is either REMOVED from the stub
 * set (a real screen exists) or FORMALLY DECLINED with the reason recorded in
 * the dict's own comment block — the way DECISION 2(d) is recorded for the
 * welcome card. A stubbed flow with no recorded decline is the "unfinished port
 * indistinguishable from a deliberate omission" the issue exists to end.
 */
Then('the Studio TUI side flow {string} is ported or formally declined', async ({}, slug: string) => {
  const { keys, comment, file } = sideFlowStub();
  const ported = !keys.includes(slug);
  const declined = comment.includes(slug) && /declin/i.test(comment);
  expect(
    ported || declined,
    `${slug} is still in _SIDE_FLOW_STUB (${keys.join(', ')}) and the comment block above it in `
    + `${path.relative(REPO_ROOT, file)} records no decline naming it. Either port it or `
    + 'record the decision there.',
  ).toBe(true);
});

/**
 * #524's "Done when": the named test picks a welcome entry BY ID, not by a
 * typed ordinal. Reads the test's body (from its `def` to the next top-level
 * `def`/`class`) and requires (a) no `_typed(<app>, "<digit>")` literal and
 * (b) the entry id spelled in the body. Reading the source is the only way to
 * assert this without urwid + pytest on the host; the plain-face scenarios in
 * the same feature prove the PRODUCT behaviour independently.
 */
Then('the Studio test {string} in {string} picks the welcome entry {string} by id, not by ordinal',
  async ({}, testName: string, rel: string, entryId: string) => {
    const file = path.join(REPO_ROOT, rel);
    const src = fs.readFileSync(file, 'utf8');
    const lines = src.split('\n');
    const start = lines.findIndex((l) => new RegExp(`^(async )?def ${testName}\\b`).test(l));
    expect(start, `${rel} has no test named ${testName}`).toBeGreaterThanOrEqual(0);
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i += 1) {
      if (/^(async )?def |^class /.test(lines[i])) { end = i; break; }
    }
    const body = lines.slice(start, end).join('\n');
    const ordinal = /_typed\(\s*\w+\s*,\s*["']\d+["']\s*\)/.exec(body);
    expect(ordinal?.[0] ?? null,
      `${testName} still types a bare ordinal at the welcome menu — a menu cut silently `
      + 'selects the wrong entry (or none). Pick by id.').toBeNull();
    expect(body.includes(`"${entryId}"`) || body.includes(`'${entryId}'`),
      `${testName} never names the entry id ${JSON.stringify(entryId)}`).toBe(true);
  });

/**
 * #537's guard, executable: no studio/tests/test_*.py may call
 * `pytest.importorskip(...)` at MODULE LEVEL (column 0) with a `def test_`
 * ABOVE it — that skips the whole module in the no-Qt pre-merge job, Qt-free
 * tests included, and reports it as one tidy SKIPPED. importorskip inside a
 * fixture (the in-repo idiom) is fine and is not matched.
 */
Then('no Studio test file puts a module-level importorskip above a test function', async () => {
  const dir = path.join(STUDIO_DIR, 'tests');
  const offenders: string[] = [];
  for (const name of fs.readdirSync(dir).filter((n) => /^test_.*\.py$/.test(n)).sort()) {
    const lines = fs.readFileSync(path.join(dir, name), 'utf8').split('\n');
    let seenTest = false;
    lines.forEach((l, i) => {
      if (/^(async )?def test_/.test(l)) seenTest = true;
      if (seenTest && /^pytest\.importorskip\(/.test(l)) offenders.push(`studio/tests/${name}:${i + 1}`);
    });
  }
  expect(offenders, 'module-level importorskip BELOW test functions (they never run in the no-Qt job):\n  '
    + offenders.join('\n  ')).toEqual([]);
});

/**
 * #537's proof-by-execution: run ONE Studio test file with NO Qt binding
 * importable — a sitecustomize meta-path blocker on PYTHONPATH makes PyQt6 and
 * PySide6 MISSING (ModuleNotFoundError), which is the pre-merge job's condition
 * and what the issue reproduced with. The transcript's pytest summary line is
 * what the scenario asserts on. Skips loudly when pytest is not importable in
 * the Studio interpreter, naming what to install, rather than failing for an
 * absent tool. Elevation is refused by env on top of pytest's own guard, so a
 * test that reaches the real launcher cannot wedge a sudo.
 */
When('I run the Studio test file {string} with no Qt binding on the path',
  async ({ world, $testInfo }, rel: string) => {
    const probe = runCli([studioPython(), '-c', 'import pytest'], { cwd: STUDIO_DIR });
    if (probe.exitCode !== 0) {
      $testInfo.skip(true, `pytest is not importable in ${studioPython()} — install it there `
        + '(pip install pytest) or point SNAP_STUDIO_PYTHON at an interpreter that has it. '
        + `(${probe.stderr.trim().split('\n').pop()})`);
      return;
    }
    const blocker = laneScratch('no-qt-blocker');
    fs.writeFileSync(path.join(blocker, 'sitecustomize.py'),
      '# Written by tests/e2e/steps/studio.steps.ts: make every Qt binding MISSING.\n'
      + 'import sys\n'
      + 'class _NoQt:\n'
      + '    NAMES = ("PyQt6", "PySide6", "PyQt5", "PySide2")\n'
      + '    def find_spec(self, name, path=None, target=None):\n'
      + '        if name.split(".")[0] in self.NAMES:\n'
      + '            raise ModuleNotFoundError("No module named %r (blocked: no-Qt e2e run)" % name)\n'
      + '        return None\n'
      + 'sys.meta_path.insert(0, _NoQt())\n');
    const file = path.isAbsolute(rel) ? rel : path.join(REPO_ROOT, rel);
    world.set(CLI_KEY, runCli(
      [studioPython(), '-m', 'pytest', file, '-q', '-rs', '-p', 'no:cacheprovider'],
      {
        cwd: STUDIO_DIR,
        timeoutMs: 600_000,
        env: { PYTHONPATH: blocker, QT_QPA_PLATFORM: 'offscreen', HUGMESH_STUDIO_NO_ELEVATION: '1' },
      },
    ));
  });

/**
 * #303 NC9, headless twin: the flash-target scan must never list the device
 * backing `/` — nor its whole parent disk. Asks the real core (flash_targets)
 * for the root source and every listed target, then asserts the exclusion
 * against what THIS host reports. With no removable media attached the list is
 * empty and the exclusion holds vacuously — but the scan still has to answer
 * without root, which is the other half of the contract.
 */
Then('the Studio flash-target scan lists no disk backing the root filesystem', async ({ world }) => {
  const t = runStudioPython(
    'import json, sys\n'
    + 'from hugmesh_studio.core import flash_targets as f\n'
    + 'print(json.dumps({"root": f._root_source(), '
    + '"targets": [getattr(x, "path", str(x)) for x in f.list_targets()]}))\n',
    [],
  );
  world.set(CLI_KEY, t);
  expect(t.exitCode, `the flash-target scan failed:\n${t.stderr}`).toBe(0);
  const doc = lastJson<{ root: string; targets: string[] }>(t.stdout, 'the flash-target scan');
  expect(doc.root, 'the scan could not name the device backing /').toMatch(/^\/dev\//);
  const parent = doc.root.replace(/p\d+$/, '').replace(/(\/dev\/(?:sd|vd|hd)[a-z]+)\d+$/, '$1');
  const bad = doc.targets.filter((p) => p === doc.root || p === parent || doc.root.startsWith(`${p}p`) || doc.root.startsWith(p));
  expect(bad, `the flash list offers the disk backing / (${doc.root}): ${bad.join(', ')}`).toEqual([]);
});
