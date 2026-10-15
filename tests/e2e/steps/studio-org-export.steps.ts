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
  notes: string[]; source: string; target: string; action: string; blocked: boolean; banned: string[];
  excluded: string[]; files: number; ref: string; commit: string;
}
interface BareRepo { commits: number; log: string[]; files: string[] }
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
  tableResults?: string[]; applyEnabledAfter?: boolean; applyEnabledAfterRetype?: boolean[];
  cliNoProbe?: { rc: number; stdout: string; stderrTail: string; ghCalls: string[] };
  ghCalls?: string[]; gitCalls?: string[]; bareRepos?: Record<string, BareRepo>;
  renameMapField?: { text: string; visible: boolean; width: number };
  ownServices?: string[]; meshServices?: string[]; gitCallsAtWalkStart?: number;
  terminalLineBeforePlan?: string; terminalLineAfterPlan?: string;
  terminalPlan?: { interpreter: string; argv: string[]; rc: number; seconds: number;
    targets: string[]; stdoutTail: string; stderrTail: string; ghCalls: string[] };
  bareFiles?: Record<string, string | null>;
  flip?: { planVisibility: string; applyEnabledBeforeFlip: boolean; pickerReads: string;
    planKept: boolean; applyEnabledAfterFlip: boolean; tableRowsAfterFlip: number;
    terminalLineAfterFlip: string; applyEnabledTypedAfterFlip: boolean;
    createCallsAfterStaleApply: string[]; bareReposAfterStaleApply: string[];
    freshPlanVisibility: string | null; applyEnabledAfterFreshPlan: boolean;
    createCallsAfterFreshApply: string[] };
  retype?: { planVisibility: string; applyEnabledBeforeFlip: boolean; confirmTextAfterFlip: string;
    applyEnabledAfterFlip: boolean; replanVisibility: string | null; confirmTextAfterReplan: string;
    applyEnabledAfterReplan: boolean; createCallsAfterUnretypedApply: string[];
    applyEnabledAfterRetype: boolean };
  badConfig?: { key: string; candidatesBefore: number; candidatesAfter: number; statusShown: boolean;
    statusText: string; cliRc: number; cliStderr: string; cliTraceback: boolean;
    reposAfterCli: string[] };
  workFolders?: string[]; sentinel?: string | null; escapeFolder?: string[] | null;
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
    // the one local --force is `git add`'s: it stages the snapshot folder past ignore
    // rules (a global excludes file must not drop a published file) and reaches no remote
    const stagingOnly = words.includes('add') && !words.includes('push');
    return words.some((w) => FORBIDDEN.includes(w) && !(stagingOnly && w === '--force'))
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
    drive(world, ['--scenario', 'export', '--action', 'plan', '--terminal-line']);
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
    drive(world, ['--scenario', 'export', '--action', 'plan', '--own-services', services,
      '--terminal-line']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh whose Services step picked {string} and press Plan',
  async ({ world }, services: string) => {
    drive(world, ['--scenario', 'export', '--action', 'plan', '--mesh-services', services,
      '--terminal-line']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh whose own domain selects {string} with {string} an Angular application, apply it with the name typed, and read the published site list',
  async ({ world }, services: string, repo: string) => {
    drive(world, ['--scenario', 'export', '--action', 'apply', '--own-services', services,
      '--angular-repo', repo,
      '--read-file', 'mesh.example.github.io:repos.json',
      '--read-file', 'mesh.example.github.io:.github/workflows/build-all.yml']);
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

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string}, apply it with the name typed, and read the published site list',
  async ({ world }, org: string) => {
    expect(org).toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'apply',
      '--read-file', 'mesh.example.github.io:repos.json',
      '--read-file', 'mesh.example.github.io:.github/workflows/build-all.yml']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string}, plan it as public, flip the visibility picker to private and press Apply with the name typed',
  async ({ world }, org: string) => {
    expect(org).toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'flip-visibility']);
  });

When('I walk the Go-Live wizard to the export step with a token-free {string} and a placeholder-login {string} planted in {string}, apply it with the name typed, and read the published {string}',
  async ({ world }, plain: string, tokened: string, repo: string, read: string) => {
    expect(plain).toBe('.npmrc');
    expect(read).toBe('.npmrc');
    drive(world, ['--scenario', 'export', '--action', 'apply',
      '--plant-file', repo + ':' + plain + '=legacy-peer-deps=true\\n',
      '--plant-file', repo + ':' + tokened + '=//registry.example/:_authToken=${NPM_TOKEN}\\n',
      '--read-file', 'example-parent:.npmrc']);
  });

When('I walk the Go-Live wizard to the export step with a token-free {string} and a URL-login {string} planted in {string}, apply it with the name typed, and read the published {string}',
  async ({ world }, plain: string, tokened: string, repo: string, read: string) => {
    expect(plain).toBe('.npmrc');
    expect(read).toBe('.npmrc');
    drive(world, ['--scenario', 'export', '--action', 'apply',
      '--plant-file', repo + ':' + plain + '=legacy-peer-deps=true\\n',
      // a login written INTO the registry address, not as an _authToken line
      '--plant-file', repo + ':' + tokened + '=registry=https://bob:s3cret@npm.example.com/\\n',
      '--read-file', 'example-parent:.npmrc']);
  });

// a token spelled from parts, the shape and never a real one
const FAKE_TOKEN = 'ghp_' + 'A'.repeat(36);

When('I walk the Go-Live wizard to the export step with a fake token hidden in a latin-1 file and in a binary file of {string} and press Plan',
  async ({ world }, repo: string) => {
    const latin1 = Buffer.concat([Buffer.from([0x63, 0x61, 0x66, 0xe9, 0x20]),
      Buffer.from(FAKE_TOKEN + '\n')]).toString('hex');
    const binary = Buffer.concat([Buffer.from([0, 0, 0, 1, 2, 3, 0]),
      Buffer.from('header ' + FAKE_TOKEN + '\n')]).toString('hex');
    drive(world, ['--scenario', 'export', '--action', 'plan',
      '--plant-bytes', repo + ':latin.txt=' + latin1,
      '--plant-bytes', repo + ':nul.bin=' + binary]);
  });

When('I walk the Go-Live wizard to the export step with {string} tracked in {string} next to a {string} that ignores it, under a global git ignore of {string}, and apply it with the name typed',
  async ({ world }, file: string, repo: string, ignoreFile: string, pattern: string) => {
    drive(world, ['--scenario', 'export', '--action', 'apply',
      '--plant-file', repo + ':' + ignoreFile + '=' + pattern + '\\n',
      '--plant-file', repo + ':' + file + '=tracked\\n',
      '--global-excludes', pattern]);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string}, plan it as private with the name typed, flip the picker to public and press Plan again',
  async ({ world }, org: string) => {
    expect(org).toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'retype-after-flip']);
  });

When('I walk the Go-Live wizard to the export step and add a config file whose {string} is {string}',
  async ({ world }, key: string, value: string) => {
    // a plain value is JSON (123 is a number); 'text:no' is the string "no"
    const json = value.startsWith('text:') ? JSON.stringify(value.slice(5)) : value;
    drive(world, ['--scenario', 'export', '--action', 'plan', '--bad-config', `${key}=${json}`]);
  });

When('I walk the Go-Live wizard to the export step and point the Rename map field at a file renaming {string} to {string} and press Plan',
  async ({ world }, repo: string, to: string) => {
    expect(repo).toBe('hugmesh-commons');
    expect(to).toBe('../../escape');
    drive(world, ['--scenario', 'export', '--action', 'plan', '--rename-map', 'bad-target']);
  });

When('I walk the Go-Live wizard to the export step and point the Rename map field at a file sending {string} and {string} to the one name {string} and press Plan',
  async ({ world }, a: string, b: string, to: string) => {
    expect([a, b, to]).toEqual(['hugmesh-actions', 'hugmesh-commons', 'dup']);
    drive(world, ['--scenario', 'export', '--action', 'plan', '--rename-map', 'shared-target']);
  });

When('I walk the Go-Live wizard to the export step with a login file, a private PGP key file and a public PGP key file planted in {string}, apply it with the name typed, and read what was published',
  async ({ world }, repo: string) => {
    expect(repo).toBe('hugmesh-parent');
    drive(world, ['--scenario', 'export', '--action', 'apply',
      '--plant-file', repo + ':.pypirc=[pypi]\\nusername = u\\n',
      '--plant-file', repo + ':deploy/.docker/config.json={}\\n',
      '--plant-file', repo + ':keys/private.asc=-----BEGIN PGP ' + 'PRIVATE KEY BLOCK-----\\n',
      '--plant-file', repo + ':keys/public.asc=-----BEGIN PGP PUBLIC KEY BLOCK-----\\n\\nabc\\n',
      '--plant-file', repo + ':deploy/config.json={}\\n']);
  });

When('I walk the Go-Live wizard to the export step for a saved mesh naming the org {string}, plan it from a terminal with --no-probe and read what it printed',
  async ({ world }, org: string) => {
    expect(org).toBe('exampleorg');
    drive(world, ['--scenario', 'export', '--action', 'plan', '--cli-no-probe']);
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

Then('the result column reports create for every row and Apply stays disarmed when the name is typed again',
  async ({ world }) => {
    const f = facts(world);
    for (const cell of f.tableResults ?? []) expect(cell.split(/\s+/)[0]).toBe('create');
    expect((f.tableResults ?? []).length).toBe((f.planRows ?? []).length);
    expect(f.applyEnabledAfter, 'Apply re-armed after a run').toBe(false);
    // one apply per plan: cleared, typed, and typed in another letter case
    expect(f.applyEnabledAfterRetype, 'Apply armed again for the plan just applied').toEqual([false, false, false]);
  });

Then('git was never asked to force, mirror, delete or prune', async ({ world }) => {
  // only the wizard's own calls: the fixture's set-up (planting a tracked file with
  // `git add -f`) is logged by the same shim before the walk starts
  const f = facts(world);
  const calls = (f.gitCalls ?? []).slice(f.gitCallsAtWalkStart ?? 0);
  expect(calls.length, 'the git shim logged nothing — was the real git used?').toBeGreaterThan(0);
  expect(calls.some((c) => /^push\b/.test(c)), 'no push was logged').toBe(true);
  expect(forbiddenGitCalls(calls), 'git calls with a forbidden flag').toEqual([]);
});

// ── the own domain's services reach the plan ─────────────────────────────────

Then('the plan lists {string} for the own domain\'s selected service and marks it {string}',
  async ({ world }, target: string, action: string) => {
    const f = facts(world);
    const rows = planRows(world);
    // on the own ROW, or on the mesh-wide Services step: both are the own domain's
    expect([...(f.ownServices ?? []), ...(f.meshServices ?? [])],
      'the saved mesh selects a service for its own domain').not.toEqual([]);
    const row = rows.find((r) => r.target === target);
    expect(row, `${target} is not on the plan; targets: ${rows.map((r) => r.target).join(', ')}`)
      .toBeDefined();
    expect((row as PlanRow).action).toBe(action);
    expect((f.tableActions ?? [])[rows.indexOf(row as PlanRow)], 'the table shows it').toBe(action);
    if ((row as PlanRow).blocked) {
      expect(f.applyEnabledTyped, 'Apply armed on a blocked plan').toBe(false);
    }
  });

// ── the Terminal line IS the same export ─────────────────────────────────────
// The step's 'Terminal' field claims to be the same export from a terminal. The
// driver ran the PLAN form of that line (its words, the driver's interpreter for the
// bare python3) over the same stand-in GitHub; what the CLI printed is compared with
// the page's table. For a saved mesh the line must plan the selected service's
// repository too, as the table does (--domain/--org alone would plan one fewer).
Then('the terminal line the export step shows plans the same repositories as its table',
  async ({ world }) => {
    const f = facts(world);
    const rows = planRows(world);
    expect(f.terminalLineBeforePlan, 'the Terminal line before Plan')
      .toMatch(/^python3 -m hugmesh_studio --org-export PLAN --config \S+ --domain \S+/);
    expect(f.terminalLineAfterPlan, 'after Plan the line is the apply form: the verb swapped, --apply appended')
      .toBe(`${(f.terminalLineBeforePlan ?? '').replace('--org-export PLAN', '--org-export APPLY')} --apply`);
    const t = f.terminalPlan;
    expect(t, 'the driver did not run the Terminal line').toBeDefined();
    const blocked = (f.planBlocked ?? []).length > 0;
    expect(t?.rc, `the Terminal line exited ${t?.rc}; stderr: ${t?.stderrTail}`).toBe(blocked ? 1 : 0);
    expect(t?.targets, `the repositories the Terminal line plans; stdout: ${t?.stdoutTail}`)
      .toEqual(rows.map((r) => r.target));
    for (const c of t?.ghCalls ?? []) {
      expect(c, 'the Terminal line in PLAN mode asked gh for more than a view').toMatch(/^repo view /);
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

Then('the plan is blocked for {string} naming {string} and {string} and Apply cannot be armed',
  async ({ world }, repo: string, a: string, b: string) => {
    const f = facts(world);
    const rows = planRows(world);
    expect(f.planBlocked, 'the blocked repositories').toEqual([repo]);
    const row = rows.find((r) => r.source === repo) as PlanRow;
    expect(row.action).toBe('refused: banned marker');
    expect([...row.banned].sort()).toEqual([a, b].sort());
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

// ── the Maven settings choice ────────────────────────────────────────────────

Then('the published site list records {string} for {string} and no settings file for {string}',
  async ({ world }, settings: string, withFile: string, without: string) => {
    const f = facts(world);
    const raw = (f.bareFiles ?? {})['mesh.example.github.io:repos.json'];
    expect(raw, 'repos.json is not on main of the stand-in site repository').toBeTruthy();
    const rows = (JSON.parse(raw as string).repos ?? []) as { name: string; settings: string; build: string }[];
    const by = Object.fromEntries(rows.map((r) => [r.name, r]));
    expect(by[withFile]?.build, `${withFile} is a Java repository`).toBe('java');
    expect(by[withFile]?.settings).toBe(settings);
    expect(by[without]?.build, `${without} is a Java repository`).toBe('java');
    expect(by[without]?.settings, `${without} must carry no settings file`).toBe('');
  });

// ── the Angular build: the other half of the org's repositories ──────────────

Then('the published site list records the {string} build for {string} and the {string} build for {string}, and the build workflow switches the npm steps on for it',
  async ({ world }, ngBuild: string, ngRepo: string, javaBuild: string, javaRepo: string) => {
    const f = facts(world);
    const raw = (f.bareFiles ?? {})['mesh.example.github.io:repos.json'];
    expect(raw, 'repos.json is not on main of the stand-in site repository').toBeTruthy();
    const rows = (JSON.parse(raw as string).repos ?? []) as { name: string; settings: string; mvnw: boolean; build: string }[];
    const by = Object.fromEntries(rows.map((r) => [r.name, r]));
    expect(by[ngRepo]?.build, `${ngRepo} is an Angular application`).toBe(ngBuild);
    expect(by[ngRepo]?.settings, 'an Angular build has no Maven settings file').toBe('');
    expect(by[javaRepo]?.build, `${javaRepo} is a Java repository`).toBe(javaBuild);
    // what the exported Angular repository holds is what the npm steps run on
    expect(f.bareRepos?.[ngRepo]?.files, `${ngRepo} on the stand-in GitHub`).toEqual(
      expect.arrayContaining(['angular.json', 'package.json']));
    expect(f.bareRepos?.[ngRepo]?.files).not.toContain('pom.xml');
    const wf = (f.bareFiles ?? {})['mesh.example.github.io:.github/workflows/build-all.yml'] as string;
    expect(wf, 'build-all.yml is not on main of the stand-in site repository').toBeTruthy();
    expect(wf).toContain("matrix.build == 'angular'");
    expect(wf).toContain('npm ci');
    expect(wf).toContain('npm run build');
  });

// ── the Maven wrapper: not every Java repository ships ./mvnw ────────────────

Then('the published site list records no Maven wrapper for {string} and one for {string}, and the build workflow falls back to plain mvn',
  async ({ world }, without: string, withWrapper: string) => {
    const f = facts(world);
    const raw = (f.bareFiles ?? {})['mesh.example.github.io:repos.json'];
    expect(raw, 'repos.json is not on main of the stand-in site repository').toBeTruthy();
    const rows = (JSON.parse(raw as string).repos ?? []) as { name: string; mvnw: boolean; build: string }[];
    const by = Object.fromEntries(rows.map((r) => [r.name, r]));
    expect(by[without]?.build, `${without} is a Java repository`).toBe('java');
    expect(by[without]?.mvnw, `${without} ships no mvnw`).toBe(false);
    expect(by[withWrapper]?.mvnw, `${withWrapper} ships a mvnw`).toBe(true);
    expect(f.bareRepos?.[without]?.files, `${without} on the stand-in GitHub`).not.toContain('mvnw');
    expect(f.bareRepos?.[withWrapper]?.files).toContain('mvnw');
    const wf = (f.bareFiles ?? {})['mesh.example.github.io:.github/workflows/build-all.yml'] as string;
    expect(wf, 'build-all.yml is not on main of the stand-in site repository').toBeTruthy();
    expect(wf).toContain('mvnw: .mvnw');
    expect(wf).toContain('HAS_MVNW: ${{ matrix.mvnw }}');
    expect(wf).toContain('MVN=mvn');
    expect(wf, 'an unconditional ./mvnw call is back').not.toMatch(/^\s*\.\/mvnw -B/m);
  });

// ── a picker changed after Plan drops the plan ───────────────────────────────

Then('the flipped picker dropped the plan, Apply stayed disarmed and the stand-in GitHub still holds no repository',
  async ({ world }) => {
    const fl = facts(world).flip;
    expect(fl, 'the driver reported no flip').toBeDefined();
    const x = fl as NonNullable<Facts['flip']>;
    expect(x.planVisibility, 'the first Plan was made as public').toBe('public');
    expect(x.applyEnabledBeforeFlip, 'Apply was armed by the public plan').toBe(true);
    expect(x.pickerReads).toBe('private');
    expect(x.planKept, 'the public plan is still on screen under a private picker').toBe(false);
    expect(x.applyEnabledAfterFlip).toBe(false);
    expect(x.applyEnabledTypedAfterFlip, 'typing the org name re-armed a dropped plan').toBe(false);
    expect(x.tableRowsAfterFlip).toBe(0);
    expect(x.terminalLineAfterFlip).toContain('--org-export PLAN');
    expect(x.createCallsAfterStaleApply, 'gh repo create ran from a dropped plan').toEqual([]);
    expect(x.bareReposAfterStaleApply).toEqual([]);
  });

Then('a fresh Plan after the flip creates only private repositories when applied',
  async ({ world }) => {
    const x = facts(world).flip as NonNullable<Facts['flip']>;
    expect(x.freshPlanVisibility).toBe('private');
    expect(x.applyEnabledAfterFreshPlan).toBe(true);
    expect(x.createCallsAfterFreshApply.length, 'the fresh apply created nothing').toBeGreaterThan(0);
    for (const c of x.createCallsAfterFreshApply) {
      expect(c, 'a repository was created public').not.toContain('--public');
      expect(c).toContain('--private');
    }
  });

Then('the plan notes that {string} has only the GitLab registry file', async ({ world }, target: string) => {
  const rows = planRows(world);
  const row = rows.find((r) => r.target === `exampleorg/${target}`) as PlanRow;
  expect(row, `${target} is not on the plan`).toBeDefined();
  expect(row.notes.join(' | ')).toContain('GitLab registry file');
});

Then('the exported {string} holds {string} and the exported {string} holds no CI settings file',
  async ({ world }, withName: string, file: string, withoutName: string) => {
    const f = facts(world);
    expect(f.bareRepos?.[withName]?.files, `${withName} on the stand-in GitHub`).toContain(file);
    const other = f.bareRepos?.[withoutName]?.files ?? [];
    expect(other.length, `${withoutName} has no files on the stand-in GitHub`).toBeGreaterThan(0);
    expect(other).not.toContain(file);
  });

// ── the .npmrc rule ──────────────────────────────────────────────────────────

Then('the plan lists {string} as excluded for {string} because of an npm login and does not list {string}',
  async ({ world }, rel: string, repo: string, kept: string) => {
    const row = planRows(world).find((r) => r.source === repo) as PlanRow;
    expect(row, `${repo} is not on the plan`).toBeDefined();
    expect(row.excluded).toContain(`${rel}: npm login in .npmrc`);
    expect(row.excluded.filter((e) => e.startsWith(`${kept}:`)), `${kept} must not be excluded`).toEqual([]);
  });

Then('the exported {string} holds {string} with the text {string} and no {string}',
  async ({ world }, name: string, file: string, text: string, gone: string) => {
    const f = facts(world);
    const files = f.bareRepos?.[name]?.files ?? [];
    expect(files).toContain(file);
    expect(files, `${gone} was published`).not.toContain(gone);
    expect((f.bareFiles ?? {})[`${name}:${file}`]).toBe(text);
  });

// ── what the commit holds is what the plan counted ───────────────────────────

Then('the exported {string} holds {string} and {string}',
  async ({ world }, name: string, a: string, b: string) => {
    const files = facts(world).bareRepos?.[name]?.files ?? [];
    expect(files, `${name} on the stand-in GitHub`).toContain(a);
    expect(files, `${name} on the stand-in GitHub`).toContain(b);
  });

Then('every exported repository holds exactly as many files as its plan counted', async ({ world }) => {
  const f = facts(world);
  for (const row of planRows(world)) {
    const name = row.target.split('/')[1];
    const held = f.bareRepos?.[name]?.files ?? [];
    expect(held.length, `${name}: files on the stand-in GitHub against ${row.files} in the plan`)
      .toBe(row.files);
  }
});

// ── a name typed for one plan arms no other ──────────────────────────────────

Then('the name typed for the private plan was cleared, the public plan is not armed and nothing is created until the name is typed again',
  async ({ world }) => {
    const x = facts(world).retype as NonNullable<Facts['retype']>;
    expect(x, 'the driver reported no retype walk').toBeDefined();
    expect(x.planVisibility).toBe('private');
    expect(x.applyEnabledBeforeFlip, 'the private plan was armed by the typed name').toBe(true);
    expect(x.confirmTextAfterFlip, 'the typed name survived the flip').toBe('');
    expect(x.applyEnabledAfterFlip).toBe(false);
    expect(x.replanVisibility).toBe('public');
    expect(x.confirmTextAfterReplan, 'the typed name came back with the new plan').toBe('');
    expect(x.applyEnabledAfterReplan, 'the public plan was armed without retyping').toBe(false);
    expect(x.createCallsAfterUnretypedApply, 'gh repo create ran from an unconfirmed plan').toEqual([]);
    expect(x.applyEnabledAfterRetype, 'typing the name again does not arm the new plan').toBe(true);
  });

// ── a wrongly typed value in a config file ───────────────────────────────────

Then('the export step refuses that config file inline naming {string}, the CLI exits 2 with no traceback and nothing is exported',
  async ({ world }, key: string) => {
    const f = facts(world);
    const b = f.badConfig as NonNullable<Facts['badConfig']>;
    expect(b, 'the driver reported no bad-config walk').toBeDefined();
    expect(b.candidatesAfter, 'the bad file was added as a source').toBe(b.candidatesBefore);
    expect(b.statusShown, 'no inline message').toBe(true);
    expect(b.statusText).toContain(key);
    expect(b.cliRc, `the CLI said ${b.cliStderr}`).toBe(2);
    expect(b.cliStderr).toContain(key);
    expect(b.cliTraceback, 'the CLI crashed with a traceback').toBe(false);
    expect(b.reposAfterCli, 'the CLI exported something from a bad file').toEqual([]);
  });

Then('the step still plans the saved mesh afterwards', async ({ world }) => {
  const f = facts(world);
  expect(f.planFailed, `Plan failed: ${f.planStatus}`).toBe(false);
  expect(planRows(world).length).toBeGreaterThan(0);
});

// ── a rename that leaves the work folder ─────────────────────────────────────

Then('the export step refuses the plan inline naming the bad repository rename', async ({ world }) => {
  const f = facts(world);
  expect(f.planFailed, 'the plan ran with a rename that leaves the work folder').toBe(true);
  expect(f.planStatus).toContain('bad repository rename');
  expect(f.planStatus).toContain('../../escape');
});

Then('nothing was created in the stand-in GitHub, no gh call was made and no repository folder was written',
  async ({ world }) => {
    const f = facts(world);
    expect(f.bareReposAfterPlan, 'repositories under the org').toEqual([]);
    expect(f.ghCalls, 'gh was called although the plan was refused').toEqual([]);
    expect(f.workFolders, 'repository folders written under the work directory').toEqual([]);
  });

Then('the folder the rename pointed at still holds only its untouched file', async ({ world }) => {
  const f = facts(world);
  expect(f.sentinel, 'the file in the folder the rename pointed at').toBe('keep\n');
  expect(f.escapeFolder).toEqual(['precious.txt']);
});

// ── two repositories sent to one target ──────────────────────────────────────

Then('the export step refuses the plan inline saying two repositories share the target {string}',
  async ({ world }, target: string) => {
    const f = facts(world);
    expect(f.planFailed, 'the plan ran although two repositories share one target').toBe(true);
    expect(f.planStatus).toContain('same target');
    expect(f.planStatus).toContain(`'${target}'`);
  });

// ── secret-shaped names ──────────────────────────────────────────────────────

Then('the plan lists the login file, the docker login file and the private PGP key file as excluded for {string} and lists neither the public PGP key file nor the other config.json',
  async ({ world }, repo: string) => {
    const row = planRows(world).find((r) => r.source === repo) as PlanRow;
    expect(row, `${repo} is not on the plan`).toBeDefined();
    const names = row.excluded.map((e) => e.split(': ')[0]);
    for (const gone of ['.pypirc', 'deploy/.docker/config.json', 'keys/private.asc']) {
      expect(names, `${gone} must be excluded`).toContain(gone);
    }
    for (const kept of ['keys/public.asc', 'deploy/config.json']) {
      expect(names, `${kept} must not be excluded`).not.toContain(kept);
    }
  });

Then('the exported {string} holds the public PGP key file and the other config.json and none of the dropped files',
  async ({ world }, name: string) => {
    const files = facts(world).bareRepos?.[name]?.files ?? [];
    for (const kept of ['keys/public.asc', 'deploy/config.json']) expect(files).toContain(kept);
    for (const gone of ['.pypirc', 'deploy/.docker/config.json', 'keys/private.asc']) {
      expect(files, `${gone} was published`).not.toContain(gone);
    }
  });

// ── a plan that never asked GitHub ───────────────────────────────────────────

Then('the terminal plan exited 0 with {string} on every repository row and the site row and made no gh call',
  async ({ world }, words: string) => {
    const c = facts(world).cliNoProbe;
    expect(c, 'the driver did not run the terminal plan').toBeDefined();
    expect(c?.rc, c?.stderrTail).toBe(0);
    const rows = (c?.stdout ?? '').split('\n').filter((l) => /^\S+\s+exampleorg\/\S+\s/.test(l));
    expect(rows.length, 'plan rows in the terminal output').toBe(4);
    for (const row of rows) expect(row, 'a row that claims to know').toContain(words);
    expect(c?.stdout).not.toContain('exists (compared at apply)');
    expect(c?.ghCalls, 'gh was called by a --no-probe plan').toEqual([]);
  });
