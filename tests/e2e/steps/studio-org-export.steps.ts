// studio-org-export.steps.ts — driving the Go-Live "Export to GitHub org" step.
//
// WHAT THIS PROVES, end to end and offscreen: the real local-mesh wizard is walked
// to its Domains step and the real Go-Live wizard to its export step
// (tests/e2e/studio-org-export-driver.py), the real buttons are pressed, and the
// assertions read what the STAND-IN GITHUB received (bare repositories, the fake
// gh's call log, the git shim's argument log) and what the pages SHOWED. Nothing
// here compares the Studio's map with itself.
//
// STEP REUSE: 'the Studio grab is a non-empty PNG' and 'the evidence manifest holds
// a {string} artefact for this scenario' come from common.steps.ts; do not restate
// them. Every step text below names the Go-Live wizard, the local-mesh Domains
// step, the export step, the plan, the stand-in GitHub or the org-export walk, and
// was grepped across steps/ before it was written.
//
// NOTHING HERE STARTS AN ENVIRONMENT, reaches the network, elevates, or reads the
// operator's saved meshes (the driver pins a scratch Studio state dir).

import { expect } from '@playwright/test';
import { When, Then } from './world';
import { runCli, REPO_ROOT, scratchDir } from './runners';
import { StudioGrab, recordStudio, runDir } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as path from 'node:path';

const DRIVER = path.resolve(__dirname, '..', 'studio-org-export-driver.py');
const STUDIO_KEY = 'studio.grab';          // shared with common.steps.ts, on purpose
const FACTS_KEY = 'studio.orgexport';

interface PlanRow {
  source: string; target: string; action: string; blocked: boolean; banned: string[];
  excluded: string[]; files: number; ref: string; commit: string;
}
interface BareRepo { commits: number; log: string[] }
interface Reopen {
  rows: { name: string; org: string; own: boolean }[]; ownCell: string; stateOwnOrg: string;
  nextAccepted: boolean; recordRowsAfterNext: { name: string; org: string | null }[];
}
interface Facts {
  ok: boolean; scenario: string;
  // no-org / export
  pagesSeen?: string[]; exportStepApplies?: boolean; pageAfterGenerate?: string;
  candidates?: string[];
  planFailed?: boolean; planStatus?: string; planRows?: PlanRow[]; planBlocked?: string[];
  tableActions?: string[]; tableTooltips?: string[];
  ghCallsDuringPlan?: string[]; gitCallsDuringPlan?: string[]; bareReposAfterPlan?: string[];
  applyEnabledBeforeTyping?: boolean; applyEnabledWrongName?: boolean; applyEnabledTyped?: boolean;
  applyEnabledUntyped?: boolean; applyStatus?: string; resultAfter?: boolean;
  resultRows?: { target: string; action: string; branch: string; commit: string; skipped: string }[] | null;
  tableResults?: string[]; applyEnabledAfter?: boolean;
  ghCalls?: string[]; gitCalls?: string[]; bareRepos?: Record<string, BareRepo>;
  renameMapField?: { text: string; visible: boolean; width: number };
  ownServices?: string[]; gitCallsAtWalkStart?: number;
  preexisting?: { target: string; branch: string; refsBefore: string[]; shaBefore: string;
    refsAfter?: string[]; shaAfter?: string };
  // domains-org
  ownDomain?: string; typed?: { ownCell: string; stateOwnOrgBeforeNext: string };
  nextAccepted?: boolean; noteVisible?: boolean; noteText?: string;
  stateOwnOrgAfterNext?: string; recordRowsAfterNext?: { name: string; org: string | null }[];
  savedRecordOrgs?: { name: string; org: string | null }[]; savedMeshCandidates?: string[][];
  reopen?: Reopen;
  dialogsOpen: string[];
}

function lastJson<T>(stdout: string): T {
  const line = stdout.trim().split('\n').filter(Boolean).pop() ?? '';
  return JSON.parse(line) as T;
}

/** Run the driver once, record the grab as this step's evidence, and keep the facts. */
function drive(world: { set<T>(k: string, v: T): void }, args: string[]): Facts {
  fs.mkdirSync(scratchDir(), { recursive: true });
  const scratch = fs.mkdtempSync(path.join(scratchDir(), 'orgexport-'));
  const tmpDir = path.join(runDir(), '.driver-tmp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const png = path.join(tmpDir,
    `orgexport-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.png`);
  const argv = [studioPython(), DRIVER, '--generator-dir', REPO_ROOT, '--scratch', scratch,
    '--grab', png, ...args];
  const t = runCli(argv, { cwd: REPO_ROOT, timeoutMs: 420_000,
    env: { QT_QPA_PLATFORM: 'offscreen', HUGMESH_STUDIO_NO_ELEVATION: '1' } });
  let facts: Facts | undefined;
  try { facts = lastJson<Facts & { page?: string; width?: number; height?: number }>(t.stdout); }
  catch { facts = undefined; }
  const grab: StudioGrab = {
    pngPath: png,
    page: (facts as { page?: string } | undefined)?.page ?? 'unknown',
    binding: 'unknown',
    width: (facts as { width?: number } | undefined)?.width ?? -1,
    height: (facts as { height?: number } | undefined)?.height ?? -1,
    transcript: t,
  };
  recordStudio(grab);
  world.set(STUDIO_KEY, grab);
  expect(facts?.ok,
    `the org-export driver did not report ok. Driver stderr:\n${t.stderr.slice(0, 3000)}`)
    .toBe(true);
  world.set(FACTS_KEY, facts as Facts);
  return facts as Facts;
}

function facts(world: { get<T>(k: string): T }): Facts { return world.get<Facts>(FACTS_KEY); }

function planRows(world: { get<T>(k: string): T }): PlanRow[] {
  const f = facts(world);
  expect(f.planFailed, `Plan failed: ${f.planStatus}`).toBe(false);
  expect(f.planRows, 'no plan rows').toBeDefined();
  return f.planRows as PlanRow[];
}

const FORBIDDEN = ['--force', '-f', '--force-with-lease', '--mirror', '--delete', '--prune'];

/** The shim logs git's ARGUMENTS (the verb first, no leading "git"). */
function forbiddenGitCalls(calls: string[]): string[] {
  return calls.filter((c) => {
    const words = c.split(/\s+/);
    return words.some((w) => FORBIDDEN.includes(w))
      || (words[0] === 'push' && words.some((w) => w.startsWith('+')));
  });
}

// ── walking ──────────────────────────────────────────────────────────────────

When('I walk the Go-Live wizard from its first page with no saved mesh naming an org',
  async ({ world }) => { drive(world, ['--scenario', 'no-org']); });

When('I type the GitHub org {string} on the own row of the local-mesh Domains step and press Next',
  async ({ world }, org: string) => { drive(world, ['--scenario', 'domains-org', '--org', org]); });

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string} and press Plan',
  async ({ world }, org: string) => {
    expect(org, 'the stand-in saved mesh names exampleorg').toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'plan']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string} and press Apply without typing the name',
  async ({ world }, org: string) => {
    expect(org).toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'apply-untyped']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string} and apply it with the name typed',
  async ({ world }, org: string) => {
    expect(org).toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'apply']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh whose own domain selects {string} and press Plan',
  async ({ world }, services: string) => {
    drive(world, ['--scenario', 'export', '--action', 'plan', '--own-services', services]);
  });

When('I walk the Go-Live wizard to the export step with {string} already holding content on its {string} branch in the stand-in GitHub, and apply it with the name typed',
  async ({ world }, target: string, branch: string) => {
    drive(world, ['--scenario', 'export', '--action', 'apply', '--preexisting', `${target}:${branch}`]);
  });

When('I walk the Go-Live wizard to the export step with a fake token planted in {string} and press Plan',
  async ({ world }, repo: string) => {
    drive(world, ['--scenario', 'export', '--action', 'plan', '--plant-marker', repo]);
  });

When('I walk the Go-Live wizard to the export step with a fake token planted in {string}, exclude it through the Rename map field, and press Plan',
  async ({ world }, repo: string) => {
    drive(world, ['--scenario', 'export', '--action', 'plan', '--plant-marker', repo,
      '--rename-map', 'exclusions']);
  });

// ── opt-in ───────────────────────────────────────────────────────────────────

Then('the Go-Live wizard goes from Generate straight to Verify and the export step does not apply',
  async ({ world }) => {
    const f = facts(world);
    expect(f.pagesSeen, 'the pages walked').toEqual(
      ['preflight', 'exposure', 'provider', 'inputs', 'generate', 'verify']);
    expect(f.exportStepApplies, 'the export step applies although no domain names an org').toBe(false);
    expect(f.savedMeshCandidates).toEqual([]);
  });

Then('no dialog opened in the org-export walk', async ({ world }) => {
  expect(facts(world).dialogsOpen, 'dialogs opened').toEqual([]);
});

// ── the Domains step ─────────────────────────────────────────────────────────

Then('the local-mesh Domains step refuses Next inline, naming the slug problem', async ({ world }) => {
  const f = facts(world);
  expect(f.typed?.ownCell, 'the cell holds what was typed').toBe('bad-');
  expect(f.nextAccepted, 'Next ACCEPTED a non-slug org').toBe(false);
  expect(f.noteVisible, 'no inline note').toBe(true);
  expect(f.noteText).toContain('not a GitHub org slug');
  expect(f.noteText).toContain('bad-');
});

Then('the local-mesh record carries no GitHub org', async ({ world }) => {
  const f = facts(world);
  expect(f.stateOwnOrgAfterNext, 'the state took the bad slug').toBe('');
  for (const r of f.recordRowsAfterNext ?? []) {
    expect(r.org ?? '', `${r.name} recorded an org`).toBe('');
  }
});

Then('the local-mesh Domains step accepts Next and the own domain\'s state carries the org {string}',
  async ({ world }, org: string) => {
    const f = facts(world);
    expect(f.typed?.ownCell).toBe(org);
    // typed, never focus-moved: the state had not seen it before Next
    expect(f.typed?.stateOwnOrgBeforeNext, 'the cell had already written the state').toBe('');
    expect(f.nextAccepted, `Next refused: ${f.noteText}`).toBe(true);
    expect(f.stateOwnOrgAfterNext, 'the org was lost on Next').toBe(org);
  });

Then('the saved mesh records the org {string} on the own domain and the Go-Live step would find it',
  async ({ world }, org: string) => {
    const f = facts(world);
    const own = (f.savedRecordOrgs ?? []).find((r) => r.name === f.ownDomain);
    expect(own, `the record has no row for the own domain ${f.ownDomain}; rows: `
      + JSON.stringify(f.savedRecordOrgs)).toBeDefined();
    expect(own?.org).toBe(org);
    expect(f.savedMeshCandidates, 'what saved_mesh_candidates finds').toEqual([[f.ownDomain, org]]);
  });

Then('re-opening that saved mesh shows the org {string} in the own row\'s cell and records it again on Next',
  async ({ world }, org: string) => {
    const f = facts(world);
    const r = f.reopen as Reopen;
    expect(r, 'no re-open happened').toBeDefined();
    expect(r.ownCell, `the own row's cell after Load into the form; rows: ${JSON.stringify(r.rows)}`).toBe(org);
    expect(r.stateOwnOrg, 'the state after the re-open').toBe(org);
    expect(r.nextAccepted, 'Next refused after the re-open').toBe(true);
    const own = r.recordRowsAfterNext.find((x) => x.name === f.ownDomain);
    expect(own?.org, 'the next record after the re-open').toBe(org);
  });

// ── the plan ─────────────────────────────────────────────────────────────────

Then('the export step appeared after Generate for the candidate {string}', async ({ world }, label: string) => {
  const f = facts(world);
  expect(f.pagesSeen?.slice(-2), 'the two pages before and at the export step')
    .toEqual(['generate', 'org-export']);
  expect(f.candidates?.length, 'candidates').toBe(1);
  expect((f.candidates ?? [])[0]).toContain(label);
});

Then('the plan lists the targets {string}', async ({ world }, want: string) => {
  const rows = planRows(world);
  expect(rows.map((r) => r.target)).toEqual(want.split(',').map((s) => s.trim()));
  for (const r of rows) {
    expect(r.blocked, `${r.source} is blocked: ${r.banned.join('; ')}`).toBe(false);
    if (r.source) {
      expect(r.commit, `${r.source}: no snapshot commit`).toMatch(/^[0-9a-f]{40}$/);
      expect(r.files, `${r.source}: no files`).toBeGreaterThan(0);
    }
  }
  expect(facts(world).tableActions).toEqual(rows.map(() => 'create'));
});

Then('the stand-in GitHub holds no repository and every gh call during the plan was a repo view',
  async ({ world }) => {
    const f = facts(world);
    expect(f.bareReposAfterPlan, 'repositories under the org after Plan').toEqual([]);
    expect(f.ghCallsDuringPlan?.length, 'gh was not asked at all').toBeGreaterThan(0);
    for (const c of f.ghCallsDuringPlan ?? []) {
      expect(c, 'a gh call that is not a repo view').toMatch(/^repo view /);
    }
  });

Then('git was not asked to push anything during the plan', async ({ world }) => {
  const pushes = (facts(world).gitCallsDuringPlan ?? []).filter((c) => /^push\b/.test(c));
  expect(pushes, 'git push during a plan').toEqual([]);
});

// GitHub slugs are case-insensitive, so the arming compares case-insensitively too
// (the GUI and the TUI alike; docs/GOLIVE-ORG-EXPORT.md says so): a wrong NAME never
// arms, a different letter CASE of the right name does.
Then('Apply is disarmed until the org name is typed, in any letter case', async ({ world }) => {
  const f = facts(world);
  expect(f.applyEnabledBeforeTyping, 'Apply armed before typing').toBe(false);
  expect(f.applyEnabledWrongName, 'Apply armed by a wrong name').toBe(false);
  expect(f.applyEnabledTyped, 'Apply did not arm with the name as configured').toBe(true);
  expect(f.applyEnabledOtherCase, 'Apply did not arm with the name in another letter case')
    .toBe(true);
});

// ── apply ────────────────────────────────────────────────────────────────────

Then('the export step refuses the apply inline and the stand-in GitHub still holds no repository',
  async ({ world }) => {
    const f = facts(world);
    expect(f.applyEnabledUntyped, 'Apply was armed with nothing typed').toBe(false);
    expect(f.applyStatus).toContain('Type the org name');
    expect(f.resultAfter, 'a result exists: something ran').toBe(false);
    expect(Object.keys(f.bareRepos ?? {})).toEqual([]);
    const creates = (f.ghCalls ?? []).filter((c) => /^repo create /.test(c));
    expect(creates).toEqual([]);
  });

Then('every planned repository and the site hold exactly one commit on main in the stand-in GitHub',
  async ({ world }) => {
    const f = facts(world);
    const rows = planRows(world);
    expect(f.resultRows, `apply reported nothing: ${f.applyStatus}`).not.toBeNull();
    for (const r of f.resultRows ?? []) {
      expect(r.skipped, `${r.target} skipped`).toBe('');
      expect(r.branch).toBe('main');
    }
    const want = rows.map((r) => r.target.split('/')[1]).sort();
    expect(Object.keys(f.bareRepos ?? {}).sort(), 'the repositories under the org').toEqual(want);
    for (const [name, repo] of Object.entries(f.bareRepos ?? {})) {
      expect(repo.commits, `${name}: commits on main`).toBe(1);
    }
  });

Then('every snapshot commit is authored as the person running the export', async ({ world }) => {
  const f = facts(world);
  for (const [name, repo] of Object.entries(f.bareRepos ?? {})) {
    expect(repo.log[0], `${name}: author`).toMatch(/ Test Exporter <exporter@example\.invalid>$/);
  }
});

Then('the result column reports create for every row and Apply is disarmed again', async ({ world }) => {
  const f = facts(world);
  for (const cell of f.tableResults ?? []) expect(cell.split(/\s+/)[0]).toBe('create');
  expect((f.tableResults ?? []).length).toBe((f.planRows ?? []).length);
  expect(f.applyEnabledAfter, 'Apply re-armed after a run').toBe(false);
});

Then('git was never asked to force, mirror, delete or prune', async ({ world }) => {
  const calls = facts(world).gitCalls ?? [];
  expect(calls.length, 'the git shim logged nothing — was the real git used?').toBeGreaterThan(0);
  expect(calls.some((c) => /^push\b/.test(c)), 'no push was logged').toBe(true);
  expect(forbiddenGitCalls(calls), 'git calls with a forbidden flag').toEqual([]);
});

// ── the own domain's services reach the plan ─────────────────────────────────

Then('the plan lists {string} for the own domain\'s selected service and marks it {string}',
  async ({ world }, target: string, action: string) => {
    const f = facts(world);
    const rows = planRows(world);
    expect(f.ownServices, 'the saved mesh selects a service on its own domain').not.toEqual([]);
    const row = rows.find((r) => r.target === target);
    expect(row, `${target} is not on the plan; targets: ${rows.map((r) => r.target).join(', ')}`)
      .toBeDefined();
    expect((row as PlanRow).action).toBe(action);
    expect((f.tableActions ?? [])[rows.indexOf(row as PlanRow)], 'the table shows it').toBe(action);
    if ((row as PlanRow).blocked) {
      expect(f.applyEnabledTyped, 'Apply armed on a blocked plan').toBe(false);
    }
  });

// ── an existing repository is refused, whatever branch its content is on ─────

Then('the plan marks {string} as {string} and Apply refuses it as an existing non-empty repository',
  async ({ world }, target: string, planAction: string) => {
    const f = facts(world);
    const rows = planRows(world);
    const row = rows.find((r) => r.target === target) as PlanRow;
    expect(row, `${target} is not on the plan`).toBeDefined();
    expect(row.action).toBe(planAction);
    expect(f.resultRows, `apply reported nothing: ${f.applyStatus}`).not.toBeNull();
    const res = (f.resultRows ?? []).find((r) => r.target === target);
    expect(res, `${target} has no result row`).toBeDefined();
    expect(res?.action).toBe('refused: existing non-empty repository');
    expect(res?.skipped, 'the refusal names the branch the content is on')
      .toContain(f.preexisting?.branch ?? '<no branch>');
    expect(res?.branch, 'a branch was chosen for a refused repository').toBe('');
    const cell = (f.tableResults ?? [])[rows.indexOf(row)] ?? '';
    expect(cell.split(/\s+/)[0], 'the Result column').toBe('refused:');
  });

Then('that repository still holds only its {string} branch at the same commit and git never pushed to it',
  async ({ world }, branch: string) => {
    const f = facts(world);
    const p = f.preexisting;
    expect(p, 'no pre-existing repository was planted').toBeDefined();
    expect(p?.branch).toBe(branch);
    expect(p?.refsBefore).toEqual([`refs/heads/${branch}`]);
    expect(p?.refsAfter, 'the refs after apply').toEqual([`refs/heads/${branch}`]);
    expect(p?.shaAfter, 'the branch moved').toBe(p?.shaBefore);
    const name = (p?.target ?? '').split('/')[1];
    const walkCalls = (f.gitCalls ?? []).slice(f.gitCallsAtWalkStart ?? 0);
    const pushes = walkCalls.filter((c) => /^push\b/.test(c) && c.includes(`/${name}.git`));
    expect(pushes, 'git push to the refused repository').toEqual([]);
  });

Then('every other planned repository and the site hold exactly one commit on main in the stand-in GitHub',
  async ({ world }) => {
    const f = facts(world);
    const rows = planRows(world);
    const refused = f.preexisting?.target ?? '';
    const others = rows.filter((r) => r.target !== refused);
    expect(others.length, 'other repositories on the plan').toBeGreaterThan(0);
    for (const r of f.resultRows ?? []) {
      if (r.target === refused) continue;
      expect(r.skipped, `${r.target} skipped`).toBe('');
      expect(r.branch).toBe('main');
    }
    for (const r of others) {
      const name = r.target.split('/')[1];
      expect(f.bareRepos?.[name]?.commits, `${name}: commits on main`).toBe(1);
    }
    expect(forbiddenGitCalls(f.gitCalls ?? []), 'git calls with a forbidden flag').toEqual([]);
  });

// ── a banned marker ──────────────────────────────────────────────────────────

Then('the plan is blocked for {string} naming {string} and Apply cannot be armed',
  async ({ world }, repo: string, marker: string) => {
    const f = facts(world);
    const rows = planRows(world);
    expect(f.planBlocked, 'the blocked repositories').toEqual([repo]);
    const row = rows.find((r) => r.source === repo) as PlanRow;
    expect(row.action).toBe('refused: banned marker');
    expect(row.banned).toEqual([marker]);
    const i = rows.indexOf(row);
    expect((f.tableActions ?? [])[i]).toBe('refused: banned marker');
    expect((f.tableTooltips ?? [])[i], 'the table names the file').toContain(marker);
    expect(f.planStatus).toContain('blocked');
    expect(f.applyEnabledTyped, 'Apply armed on a blocked plan').toBe(false);
  });

Then('the plan is clean, {string} is listed as excluded for {string}, and Apply arms with the name typed',
  async ({ world }, rel: string, repo: string) => {
    const f = facts(world);
    const rows = planRows(world);
    expect(f.renameMapField?.visible, 'the Rename map field is drawn').toBe(true);
    expect(f.renameMapField?.width ?? 0, 'the Rename map field is wide enough for a path')
      .toBeGreaterThanOrEqual(300);
    expect(f.planBlocked).toEqual([]);
    const row = rows.find((r) => r.source === repo) as PlanRow;
    expect(row.banned).toEqual([]);
    expect(row.excluded).toContain(`${rel}: excluded by the rename map`);
    expect(f.applyEnabledTyped, 'Apply did not arm on the clean plan').toBe(true);
    expect(f.bareReposAfterPlan).toEqual([]);
  });
