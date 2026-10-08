// studio-code-folders.steps.ts — driving the Studio's "Code folders" block (#689).
//
// WHAT THIS PROVES, end to end and offscreen: the real StudioWizard is walked from
// its first page to the local mesh's Repo source step, the real buttons of the
// Code folders block are pressed, and the assertions read what the page SHOWED and
// what the (stand-in) file manager was actually HANDED. Nothing here reads the
// Studio's own map and compares it to itself:
//
//  * "the folder the build reads" is worked out by the driver from the compose
//    files, the STACK_SRC the stack node hands to make, and the Makefile default
//    (studio-code-folders-driver.py:_build_reads) and carried in each row as
//    `buildPath`; the step compares the button's folder with it.
//  * "handed to the file manager" is a one-line xdg-open on PATH that appends its
//    argument to a log; the step reads the log, not the Studio's own claim.
//
// STEP REUSE: 'the Studio grab is a non-empty PNG' and 'the evidence manifest holds
// a {string} artefact for this scenario' come from common.steps.ts; do not restate
// them (a byte-identical duplicate makes bddgen ambiguous and it generates ZERO
// scenarios). Every step text below starts with "the Code folders" or names the
// Repo source step, and was grepped across steps/ before it was written.
//
// NOTHING HERE STARTS AN ENVIRONMENT, builds an image, elevates or opens a window
// on the operator's desktop (PATH holds only the stand-in opener).

import { expect } from '@playwright/test';
import { When, Then } from './world';
import { runCli, REPO_ROOT, scratchDir } from './runners';
import { StudioGrab, recordStudio, runDir } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as path from 'node:path';

const DRIVER = path.resolve(__dirname, '..', 'studio-code-folders-driver.py');
const STUDIO_KEY = 'studio.grab';          // shared with common.steps.ts, on purpose
const FACTS_KEY = 'studio.codefolders';
const PARAMS_KEY = 'studio.codefolders.params';

interface Row {
  app: string; path: string; buildPath: string; enabled: boolean; label: string;
  tooltip: string; visible: boolean; width: number; labelWidth: number;
}
interface Domain {
  name: string; rows: Row[];
  openAll: { enabled: boolean; tooltip: string; visible: boolean };
}
interface Clicked {
  target: string; wasEnabled: boolean; elapsedS: number; handedToFileManager: string[];
  noteVisible: boolean; note: string; noteStyle: string; copyFieldVisible: boolean;
  copyFieldText: string; copyButtonVisible: boolean; dialogsOpen: string[];
}
interface Facts {
  ok: boolean; mode: string; sourceDir: string; root: string; pageClass: string;
  rootButton: { enabled: boolean; visible: boolean };
  generatorDir: string; domains: Domain[]; clicked?: Clicked;
}
interface Params { mode: string; tree: string; opener: string; scratch: string; also: string }

function lastJson<T>(stdout: string): T {
  const line = stdout.trim().split('\n').filter(Boolean).pop() ?? '';
  return JSON.parse(line) as T;
}

/** Run the driver, record the grab as this step's evidence, and keep the facts. */
function drive(world: { set<T>(k: string, v: T): void }, p: Params, click: string): Facts {
  const tmpDir = path.join(runDir(), '.driver-tmp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const png = path.join(tmpDir,
    `codefolders-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.png`);
  const argv = [
    studioPython(), DRIVER, '--generator-dir', REPO_ROOT, '--scratch', p.scratch,
    '--grab', png, '--source-mode', p.mode, '--tree', p.tree, '--opener', p.opener,
    ...(p.also ? ['--also-create', p.also] : []),
    ...(click ? ['--click', click] : []),
  ];
  const t = runCli(argv, { cwd: REPO_ROOT, timeoutMs: 180_000,
    env: { QT_QPA_PLATFORM: 'offscreen', HUGMESH_STUDIO_NO_ELEVATION: '1' } });
  let facts: Facts | undefined;
  try { facts = lastJson<Facts & { png?: string; width?: number; height?: number }>(t.stdout); }
  catch { facts = undefined; }
  const grab: StudioGrab = {
    pngPath: png, page: 'localmesh', binding: 'unknown',
    width: (facts as { width?: number } | undefined)?.width ?? -1,
    height: (facts as { height?: number } | undefined)?.height ?? -1,
    transcript: t,
  };
  recordStudio(grab);
  world.set(STUDIO_KEY, grab);
  expect(facts?.ok,
    `the Code folders driver did not report ok. Driver stderr:\n${t.stderr.slice(0, 2500)}`)
    .toBe(true);
  world.set(FACTS_KEY, facts as Facts);
  return facts as Facts;
}

function facts(world: { get<T>(k: string): T }): Facts { return world.get<Facts>(FACTS_KEY); }
function click(world: { get<T>(k: string): T }): Clicked {
  const c = facts(world).clicked;
  expect(c, 'no button was pressed in this scenario yet').toBeDefined();
  return c as Clicked;
}
function domain(world: { get<T>(k: string): T }, name: string): Domain {
  const d = facts(world).domains.find((x) => x.name === name);
  expect(d, `the Code folders block shows no domain ${name}. It shows: `
    + facts(world).domains.map((x) => x.name).join(', ')).toBeDefined();
  return d as Domain;
}
function row(world: { get<T>(k: string): T }, app: string, dom: string): Row {
  const r = domain(world, dom).rows.find((x) => x.app === app);
  expect(r, `${dom} has no Code folders row for ${app}`).toBeDefined();
  return r as Row;
}

// ── walking to the step ──────────────────────────────────────────────────────

/**
 * mode: "existing" (Build from a source tree I already have) | "clone" (Download
 * the source); tree: "some" (four checkouts exist) | "none"; opener: "ok" (exits 0),
 * "stay" (never exits, like a real file manager) | "none" (no file manager at all).
 */
When('I walk the Studio to the Repo source step in {string} mode with {string} checkouts and a file manager that {string}',
  async ({ world }, mode: string, tree: string, opener: string) => {
    fs.mkdirSync(scratchDir(), { recursive: true });
    const scratch = fs.mkdtempSync(path.join(scratchDir(), 'codefolders-'));
    const p: Params = { mode, tree, opener, scratch, also: '' };
    world.set(PARAMS_KEY, p);
    drive(world, p, '');
  });

/** The checkouts appear on disk after the first read, as a finished clone leaves them. */
When('the checkouts {string} appear on disk and the Studio refreshes',
  async ({ world }, names: string) => {
    const p = world.get<Params>(PARAMS_KEY);
    p.also = names;
    drive(world, p, '');
  });

When('I press {string} in the Code folders block', async ({ world }, target: string) => {
  const p = world.get<Params>(PARAMS_KEY);
  drive(world, p, target);
});

// ── what the block shows ─────────────────────────────────────────────────────

Then('the Code folders block lists the domains {string}', async ({ world }, names: string) => {
  const want = names.split(',').map((s) => s.trim());
  const got = facts(world).domains.map((d) => d.name);
  expect(got, 'the domains of the Code folders block').toEqual(want);
});

/** Open all per domain, an Open folder button per app, drawn wide enough to read (#647). */
Then('every domain has an Open all button and an Open folder button for each app it runs',
  async ({ world }) => {
    const f = facts(world);
    expect(f.rootButton.visible, 'Open source root is drawn').toBe(true);
    for (const d of f.domains) {
      expect(d.openAll.visible, `${d.name}: Open all is drawn`).toBe(true);
      expect(d.rows.length, `${d.name} lists no apps`).toBeGreaterThan(10);
      for (const r of d.rows) {
        expect(r.label, `${d.name}/${r.app}`).toBe('Open folder');
        expect(r.visible, `${d.name}/${r.app}: the button is drawn`).toBe(true);
        expect(r.width, `${d.name}/${r.app}: the button is narrower than its label`)
          .toBeGreaterThanOrEqual(r.labelWidth + 8);
      }
    }
  });

Then('the domain {string} runs more apps than the domain {string}',
  async ({ world }, more: string, fewer: string) => {
    expect(domain(world, more).rows.length).toBeGreaterThan(domain(world, fewer).rows.length);
  });

/**
 * THE LOAD-BEARING ONE for "the folder is the one the build reads": every row's
 * folder must equal the folder the build would read for that app, derived by the
 * driver from compose + the make environment, not from the Studio's own map.
 */
Then('every Code folders row is the folder the build reads', async ({ world }) => {
  const bad: string[] = [];
  let n = 0;
  for (const d of facts(world).domains) {
    for (const r of d.rows) {
      n += 1;
      if (!r.buildPath || r.buildPath !== r.path) {
        bad.push(`${d.name}/${r.app}: button folder ${JSON.stringify(r.path)}, `
          + `build reads ${JSON.stringify(r.buildPath)}`);
      }
    }
  }
  expect(n, 'no rows were checked — this would be vacuous').toBeGreaterThan(20);
  expect(bad, `rows pointing at a folder the build does not read:\n  ${bad.join('\n  ')}`)
    .toEqual([]);
});

Then('the Code folders root is the {string} folder', async ({ world }, which: string) => {
  const root = facts(world).root;
  if (which === 'stack-src') {
    expect(root, 'download mode reads ./.stack-src of the generator checkout')
      .toBe(path.join(facts(world).generatorDir, '.stack-src'));
  } else {
    expect(root, 'the typed source tree').toBe(facts(world).sourceDir);
  }
});

Then('the Code folders row {string} under {string} is enabled',
  async ({ world }, app: string, dom: string) => {
    const r = row(world, app, dom);
    expect(r.enabled, `${dom}/${app} should be openable: ${r.tooltip}`).toBe(true);
  });

/** A missing folder is a DISABLED control that says WHY, in its tooltip. */
Then('the Code folders row {string} under {string} is disabled and says {string}',
  async ({ world }, app: string, dom: string, why: string) => {
    const r = row(world, app, dom);
    expect(r.enabled, `${dom}/${app} is enabled although its folder is missing`).toBe(false);
    expect(r.tooltip, `${dom}/${app}: the disabled button does not say why`).toContain(why);
  });

Then('no Code folders row is enabled', async ({ world }) => {
  const on = facts(world).domains.flatMap((d) => d.rows.filter((r) => r.enabled)
    .map((r) => `${d.name}/${r.app}`));
  expect(on, 'rows enabled although nothing is downloaded').toEqual([]);
  for (const d of facts(world).domains) {
    expect(d.openAll.enabled, `${d.name}: Open all`).toBe(false);
  }
});

// ── what pressing a button did ───────────────────────────────────────────────

Then('the file manager was handed exactly the folder {string}',
  async ({ world }, app: string) => {
    const c = click(world);
    const root = facts(world).root;
    expect(c.handedToFileManager, 'what the file manager was handed')
      .toEqual([path.join(root, app)]);
  });

Then('the file manager was handed nothing', async ({ world }) => {
  const c = click(world);
  expect(c.handedToFileManager).toEqual([]);
});

Then('the file manager was handed every existing folder of {string} once',
  async ({ world }, dom: string) => {
    const c = click(world);
    const want = domain(world, dom).rows.filter((r) => r.enabled).map((r) => r.path);
    expect(want.length, 'the domain has no existing folder').toBeGreaterThan(1);
    expect([...c.handedToFileManager].sort()).toEqual([...want].sort());
  });

Then('the Studio says it opened the folder, in green', async ({ world }) => {
  const c = click(world);
  expect(c.note, 'the inline result').toMatch(/^Opened /);
  expect(c.noteStyle).toContain('#2e7d32');
  expect(c.copyFieldVisible, 'a verified open needs no copy field').toBe(false);
});

/**
 * An open that nothing took, or that nothing could confirm, is said INLINE and the
 * folder is offered for copying — never a silent no-op, never a dialog.
 */
Then('the Studio says inline that no file manager took the request and offers the folder to copy',
  async ({ world }) => {
    const c = click(world);
    expect(c.noteVisible, 'no inline note appeared').toBe(true);
    // The FAILED wording, in red: an amber "asked ... not confirmed" note is a
    // different outcome (a file manager that never answered) and must not pass here.
    expect(c.note, 'the note must say nothing took it').toMatch(
      /^Could not open .*no file manager took the request/);
    expect(c.noteStyle, 'a failed open is red').toContain('#b00020');
    expect(c.noteStyle, 'never green').not.toContain('#2e7d32');
    expect(c.copyFieldVisible, 'the path to copy is offered').toBe(true);
    expect(c.copyButtonVisible, 'the Copy path button is offered').toBe(true);
  });

Then('the path offered for copying is the folder {string}', async ({ world }, app: string) => {
  expect(click(world).copyFieldText, 'the offered path')
    .toBe(path.join(facts(world).root, app));
});

Then('the Studio does not claim the open was confirmed', async ({ world }) => {
  const c = click(world);
  expect(c.noteStyle, 'a file manager that never answered is not green').not.toContain('#2e7d32');
  expect(c.note).toMatch(/nothing confirmed|not confirmed/);
  expect(c.copyFieldVisible, 'the path to copy stays on screen').toBe(true);
});

Then('no dialog is open in the Studio', async ({ world }) => {
  expect(click(world).dialogsOpen, 'dialogs opened by the Code folders block').toEqual([]);
});

/** A file manager that never exits must not freeze the window (the frozen-Open-all defect). */
Then('the Studio answered within {int} seconds', async ({ world }, secs: number) => {
  const c = click(world);
  expect(c.elapsedS, `Open all took ${c.elapsedS}s on the window's own thread`)
    .toBeLessThanOrEqual(secs);
});
