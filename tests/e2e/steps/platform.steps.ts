// platform.steps.ts — step definitions for the PLATFORM domain's issue-tracing
// scenarios under features/platform/ (BDD coverage lane admin-platform,
// 2026-09-23). The pre-existing platform features (env-interface-evidence,
// social-function-matrix) bind to common.steps.ts / social-functions.steps.ts
// and are untouched by this file.
//
// EVERYTHING HERE READS COMMITTED FILES OF THIS REPOSITORY AND ASSERTS OVER
// THEM. No stack, no cluster, no browser, no network: the casdoor PostSync Job
// manifests, the kind bring-up script and the shot table are all in-repo, so
// none of these scenarios can skip and none can pass vacuously — every reader
// below fails LOUDLY on zero rows rather than comparing against an empty list.
//
// WHY A REGEX READER AND NOT A YAML PARSER. tests/e2e/node_modules carries no
// YAML library (checked: neither `yaml` nor `js-yaml`), the lockfile is gated by
// check-toolchain.sh, and the manifests under specs/cluster/manifests/casdoor are
// plain block YAML with one Job document per file, so the four fields a scenario
// needs (metadata.name, the two argocd hook annotations, restartPolicy and the
// podFailurePolicy exit codes) are read by anchored line patterns. The reader is
// deliberately strict — a Job document with no `  name:` at metadata indent is
// an error, not a silently skipped Job.
//
// STEP HYGIENE. Every step text below was grepped against tests/e2e/steps/ and
// every sibling lane worktree under /home/magus/.hugmesh-wt-sonnet/bdd-*/ before
// it was written; none duplicates an existing definition. bddgen fails the whole
// lane on an ambiguous step.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import { Given, Then } from './world';
import { REPO_ROOT } from '../specs/governance-sources';

/** Comma-separated Examples cell -> trimmed list. `""` is the empty list, not [""]. */
function list(csv: string): string[] {
  return csv.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
}

// ═════════════════════════════════════════════════════════════════════════════
// 1. The casdoor PostSync hook Jobs (hugmesh-generator#396, fixed by #401)
// ═════════════════════════════════════════════════════════════════════════════

const CASDOOR_DIR = path.join(REPO_ROOT, 'specs', 'cluster', 'manifests', 'casdoor');
const BOOTSTRAP_KIND = path.join(
  REPO_ROOT, 'specs', 'cluster', 'bootstrap', 'kind-local', 'bootstrap-kind.sh',
);

interface ManifestJob {
  name: string;
  file: string;
  hook: string | null;
  /** argocd.argoproj.io/sync-wave, or null when the annotation is absent. */
  wave: number | null;
  restartPolicy: string | null;
  /** Exit codes a `podFailurePolicy` rule with action FailJob names. */
  failJobExitCodes: number[];
  /** Every `secretName:` the Job's pod template mounts. */
  mountedSecrets: string[];
}

/** Drop whole-line `#` comments so a commented-out annotation cannot satisfy a
 *  pattern. Inline trailing comments are left alone: the values read below are
 *  single tokens, and the patterns stop at the token. */
function stripYamlComments(src: string): string {
  return src.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
}

/** The kustomization's `resources:` list, in order — the files ArgoCD applies. */
function kustomizeResources(dir: string): string[] {
  const kust = stripYamlComments(fs.readFileSync(path.join(dir, 'kustomization.yaml'), 'utf8'));
  const out: string[] = [];
  for (const m of kust.matchAll(/^\s*-\s*(\S+\.ya?ml)\s*$/gm)) out.push(m[1]);
  expect(out.length, `${dir}/kustomization.yaml lists no resources — the reader is broken`)
    .toBeGreaterThan(0);
  return out;
}

/** Every `kind: Job` document across the directory's kustomize resources. */
function manifestJobs(dir: string): ManifestJob[] {
  const jobs: ManifestJob[] = [];
  for (const rel of kustomizeResources(dir)) {
    const raw = fs.readFileSync(path.join(dir, rel), 'utf8');
    for (const doc of raw.split(/^---\s*$/m)) {
      const y = stripYamlComments(doc);
      if (!/^kind:\s*Job\s*$/m.test(y)) continue;
      const name = /^ {2}name:\s*(\S+)\s*$/m.exec(y);
      if (!name) throw new Error(`${rel}: a kind: Job document has no metadata.name at 2-space indent`);
      const hook = /argocd\.argoproj\.io\/hook:\s*"?([A-Za-z]+)"?/.exec(y);
      const wave = /argocd\.argoproj\.io\/sync-wave:\s*"?(-?\d+)"?/.exec(y);
      const restart = /^\s+restartPolicy:\s*(\S+)\s*$/m.exec(y);
      const failJob = /action:\s*FailJob[\s\S]*?values:\s*\[([^\]]*)\]/.exec(y);
      jobs.push({
        name: name[1],
        file: rel,
        hook: hook ? hook[1] : null,
        wave: wave ? Number(wave[1]) : null,
        restartPolicy: restart ? restart[1] : null,
        failJobExitCodes: failJob ? list(failJob[1]).map(Number) : [],
        mountedSecrets: [...y.matchAll(/secretName:\s*([A-Za-z0-9.-]+)/g)].map((m) => m[1]),
      });
    }
  }
  return jobs;
}

function jobNamed(world: { get<T>(k: string): T }, name: string): ManifestJob {
  const jobs = world.get<ManifestJob[]>('casdoorJobs');
  const j = jobs.find((x) => x.name === name);
  if (!j) {
    throw new Error(
      `no kind: Job named '${name}' under ${CASDOOR_DIR} (kustomize resources). `
      + `Jobs found: ${jobs.map((x) => `${x.name} (${x.file})`).join(', ') || 'NONE'}`,
    );
  }
  return j;
}

Given('the casdoor manifest Jobs are loaded', async ({ world }) => {
  const jobs = manifestJobs(CASDOOR_DIR);
  expect(jobs.length, `${CASDOOR_DIR} parsed to zero kind: Job documents — the reader is broken`)
    .toBeGreaterThan(0);
  world.set('casdoorJobs', jobs);
});

Then('the casdoor manifest job {string} is an ArgoCD PostSync hook at sync-wave {string}',
  async ({ world }, name: string, wave: string) => {
    const j = jobNamed(world, name);
    expect(j.hook, `${j.file}: ${name} argocd.argoproj.io/hook`).toBe('PostSync');
    expect(
      j.wave,
      `${j.file}: ${name} carries no argocd.argoproj.io/sync-wave (or not "${wave}"). Without a `
      + `wave every PostSync hook in the directory starts at once against the ONE built-in/admin `
      + `account — the race hugmesh-generator#396 measured (104 wrong logins, a 15-minute lockout).`,
    ).toBe(Number(wave));
  });

Then('every casdoor Job mounting the {string} Secret other than {string} sits in a later sync-wave than it',
  async ({ world }, secret: string, owner: string) => {
    const jobs = world.get<ManifestJob[]>('casdoorJobs');
    const own = jobNamed(world, owner);
    expect(own.mountedSecrets, `${owner} must itself mount ${secret}`).toContain(secret);
    expect(own.wave, `${owner} has no sync-wave`).not.toBeNull();
    const siblings = jobs.filter((j) => j.name !== owner && j.mountedSecrets.includes(secret));
    // A derived property, not a hand-written list: a FIFTH Job mounting the
    // admin Secret without a wave lands here by construction.
    expect(siblings.length, `no sibling Job mounts ${secret} — nothing to order`).toBeGreaterThan(0);
    const wrong = siblings
      .filter((j) => j.wave === null || j.wave <= (own.wave as number))
      .map((j) => `${j.name} (${j.file}) wave=${j.wave ?? 'ABSENT'}`);
    expect(
      wrong,
      `these Jobs share ${secret} with ${owner} (wave ${own.wave}) but are not strictly after it: `
      + `they would log in with the provisioned password BEFORE the takeover and spend the account's `
      + `5-attempt sign-in budget`,
    ).toEqual([]);
  });

Then('the casdoor Job {string} fails the whole Job on container exit code {int} and never restarts its pod',
  async ({ world }, name: string, code: number) => {
    const j = jobNamed(world, name);
    expect(
      j.failJobExitCodes,
      `${j.file}: ${name} has no podFailurePolicy FailJob rule naming exit code ${code} — a throttled `
      + `run would be replayed backoffLimit+1 times against the same ban`,
    ).toContain(code);
    // podFailurePolicy is only valid with restartPolicy: Never (the apiserver
    // validates the pair); OnFailure here would be a manifest ArgoCD cannot apply.
    expect(j.restartPolicy, `${j.file}: ${name} restartPolicy`).toBe('Never');
  });

Then('the kind bring-up re-applies only {string} when it restarts the {string} Job',
  async ({}, manifest: string, job: string) => {
    const src = fs.readFileSync(BOOTSTRAP_KIND, 'utf8')
      .split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
    const calls = [...src.matchAll(new RegExp(`^\\s*recreate_job\\s+\\S+\\s+${job}\\s+(\\S+)(?:\\s+(\\S+))?`, 'gm'))];
    expect(calls.length, `${BOOTSTRAP_KIND}: no 'recreate_job <ns> ${job} …' call`).toBeGreaterThan(0);
    for (const c of calls) {
      expect(
        c[2],
        `${BOOTSTRAP_KIND}: 'recreate_job … ${job} ${c[1]}' names no single manifest, so it would `
        + `'kubectl apply -k' the whole directory — kubectl honours no sync-wave, and that re-creates `
        + `every reaped wave-1 Job beside ${job}: the same four-way race, by hand (#396 item 5)`,
      ).toBe(manifest);
    }
  });

Then('the kind bring-up waits {int} seconds for the {string} Job, longer than the {int} second casdoor lockout',
  async ({}, seconds: number, job: string, lockout: number) => {
    const src = fs.readFileSync(BOOTSTRAP_KIND, 'utf8')
      .split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
    const m = new RegExp(`^\\s*wait_job\\s+\\S+\\s+${job}\\s+(\\d+)`, 'm').exec(src);
    expect(m, `${BOOTSTRAP_KIND}: no 'wait_job <ns> ${job} <seconds>' call`).not.toBeNull();
    const got = Number((m as RegExpExecArray)[1]);
    expect(got, `wait_job ${job} timeout`).toBe(seconds);
    // The property that makes the number load-bearing: a wait shorter than the
    // lockout expires while the cluster is merely serving out a ban it WILL
    // recover from — 600s did, by 7m37s, on 2026-09-16.
    expect(got, `the wait (${got}s) must exceed casdoor's sign-in lockout (${lockout}s)`)
      .toBeGreaterThan(lockout);
  });

// ═════════════════════════════════════════════════════════════════════════════
// 2. The shot-harness write contract (hugmesh-generator#388, fixed by #390)
// ═════════════════════════════════════════════════════════════════════════════

const SHOTS_JSON = path.join(REPO_ROOT, 'tests', 'e2e', 'shot-harness', 'shots.json');

interface ShotAction { action: string; testid?: string; value?: string; first?: true }
interface ShotRow { persona: string; step: string; slug: string; do: ShotAction[] }
interface ShotTable { personas: { slug: string }[]; shots: ShotRow[] }

function shotRow(world: { get<T>(k: string): T }, persona: string, step: string): ShotRow {
  const t = world.get<ShotTable>('shotTable');
  const r = t.shots.find((x) => x.persona === persona && x.step === step);
  if (!r) throw new Error(`shots.json has no row persona='${persona}' step='${step}'`);
  return r;
}

Given('the shot table is loaded', async ({ world }) => {
  // shots.json is strict JSON (its comments are "//"-prefixed KEYS, not line
  // comments), so JSON.parse is the same reader shot-table.mjs uses.
  const t = JSON.parse(fs.readFileSync(SHOTS_JSON, 'utf8')) as ShotTable;
  expect(Array.isArray(t.shots) && t.shots.length, `${SHOTS_JSON}: shots[] is empty`).toBeTruthy();
  expect(Array.isArray(t.personas) && t.personas.length, `${SHOTS_JSON}: personas[] is empty`).toBeTruthy();
  world.set('shotTable', t);
});

Then('every shot-table click on {string} is scoped to the FIRST matching element',
  async ({ world }, csv: string) => {
    const perRow = new Set(list(csv));
    const t = world.get<ShotTable>('shotTable');
    const clicks: string[] = [];
    const unscoped: string[] = [];
    for (const r of t.shots) {
      for (const a of r.do) {
        if (a.action !== 'click' || !a.testid || !perRow.has(a.testid)) continue;
        clicks.push(`${r.persona}-${r.step}:${a.testid}`);
        if (a.first !== true) unscoped.push(`${r.persona}-${r.step}:${a.testid}`);
      }
    }
    // Not vacuous: the table must actually click these somewhere, or the
    // property is being asserted over nothing.
    expect(clicks.length, `no shot row clicks any of ${[...perRow].join(', ')}`).toBeGreaterThan(0);
    expect(
      unscoped,
      `these clicks target a data-testid admin-ui renders ONCE PER <li *ngFor> instance and carry no `
      + `'first': true — with two instances present page.getByTestId(id).click() throws a strict-mode `
      + `violation instead of clicking (#388 item 1)`,
    ).toEqual([]);
  });

Then('the shot row for persona {string} step {string} clicks {string} on the FIRST matching element only',
  async ({ world }, persona: string, step: string, testid: string) => {
    const r = shotRow(world, persona, step);
    const clicks = r.do.filter((a) => a.action === 'click' && a.testid === testid);
    expect(clicks.length, `${persona}-${step} (${r.slug}) clicks on ${testid}`).toBe(1);
    expect(clicks[0].first, `${persona}-${step} (${r.slug}) click ${testid} 'first'`).toBe(true);
  });

Then('the shot row for persona {string} step {string} performs exactly the actions {string}',
  async ({ world }, persona: string, step: string, csv: string) => {
    const r = shotRow(world, persona, step);
    const got = r.do.map((a) => `${a.action} ${a.testid ?? ''}`.trim());
    expect(got, `${persona}-${step} (${r.slug}) action sequence`).toEqual(list(csv));
  });

Then('the shot table runs persona {string} before persona {string}',
  async ({ world }, first: string, second: string) => {
    const order = world.get<ShotTable>('shotTable').personas.map((p) => p.slug);
    const a = order.indexOf(first);
    const b = order.indexOf(second);
    expect(a, `persona '${first}' is not in personas[]`).toBeGreaterThanOrEqual(0);
    expect(b, `persona '${second}' is not in personas[]`).toBeGreaterThanOrEqual(0);
    expect(
      a,
      `personas[] runs '${second}' (index ${b}) before '${first}' (index ${a}); --all follows this `
      + `order, and '${second}' leaves state that makes a later '${first}' row fail (#388 item 3)`,
    ).toBeLessThan(b);
  });
