// studio-local-agent.steps.ts — the Studio's "Work on this mesh with a local AI agent"
// card (issue #695), driven through the REAL wizard offscreen by
// tests/e2e/studio-local-agent-driver.py.
//
// WHAT THESE STEPS PROVE AND WHAT THEY DO NOT.
//   Proven: the card is on the Bring-up page (where the Docker mesh and the kind
//   DevOps lane both end), names each missing prerequisite in plain words, keeps
//   Start disabled until none is missing, starts nothing without a press, shows lines
//   a person can paste (which are RUN here, in bash, against the copy the Start just
//   made), carries no auto-approve flag, and leaves a copy with no remote.
//   NOT proven (the driver says so too): the probe is a stand-in machine and the
//   terminal is "none installed", so no real Ollama is contacted and no window opens.
//   Those two need a live run on a desktop with Ollama and are listed as such in the
//   pull request.
//
// STEP REUSE: 'the Studio grab is a non-empty PNG' and 'the evidence manifest holds a
// {string} artefact for this scenario' come from common.steps.ts; grep before adding.

import { expect } from '@playwright/test';
import { When, Then } from './world';
import { runCli, REPO_ROOT, scratchDir } from './runners';
import { StudioGrab, recordStudio } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const STUDIO_KEY = 'studio.grab';          // shared with common.steps.ts, on purpose
const CARD_KEY = 'studio.agentcard';
const WORK_KEY = 'studio.agentcard.work';

const DRIVER = path.resolve(__dirname, '..', 'studio-local-agent-driver.py');

interface Box { visible: boolean; width: number; height: number; inside: boolean; labelWidth?: number }
interface Card {
  title: string; onBringUpPage: boolean; status: string; more: string;
  startText: string; startEnabled: boolean; startTooltip: string;
  start: Box; copy: Box; recheck: Box; note: string; commandShown: string;
  laneChoices: string[]; lane: string; app: string; folder: string;
  launchesRequested: number; cardWidth: number; forbiddenFlags: string[];
  plan?: { argv: string[]; cwd: string; brief: string; title: string };
  copyHasRemote?: boolean | null;
}

function lastJson(stdout: string): { ok: boolean; png?: string; binding?: string; card?: Card; error?: string } {
  const line = stdout.trim().split('\n').filter(Boolean).pop() ?? '{}';
  try { return JSON.parse(line); } catch { return { ok: false, error: `no JSON: ${line.slice(0, 300)}` }; }
}

/** A stand-in `ollama` that records where it ran and what it was given. */
function makeWorkDir(): { dir: string; bin: string; ran: string } {
  fs.mkdirSync(scratchDir(), { recursive: true });
  const dir = fs.mkdtempSync(path.join(scratchDir(), 'studio-agent-card-'));
  const bin = path.join(dir, 'bin');
  const ran = path.join(dir, 'agent-ran.txt');
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, 'ollama'), `#!/bin/sh\necho "$PWD $*" > ${ran}\n`, { mode: 0o755 });
  return { dir, bin, ran };
}

function drive(world: { set(k: string, v: unknown): void }, machine: string, press: string, lane = 'docker'): void {
  const work = makeWorkDir();
  const png = path.join(work.dir, 'card.png');
  const t = runCli(
    [studioPython(), DRIVER, '--generator-dir', REPO_ROOT, '--grab', png,
      '--work-dir', path.join(work.dir, 'w'), '--machine', machine, '--press', press, '--lane', lane],
    {
      cwd: REPO_ROOT, timeoutMs: 180_000,
      // PATH first holds the stand-in ollama, so the lines the card shows (which carry
      // this PATH inside `env -i`) start the stand-in when they are run below.
      env: { QT_QPA_PLATFORM: 'offscreen', PATH: `${work.bin}:${process.env.PATH ?? '/usr/bin:/bin'}` },
    },
  );
  const doc = lastJson(t.stdout);
  const grab: StudioGrab = {
    pngPath: doc.png ?? png, page: 'localmesh', binding: doc.binding ?? 'unknown',
    width: -1, height: -1, transcript: t,
  };
  recordStudio(grab);
  world.set(STUDIO_KEY, grab);
  world.set(WORK_KEY, work);
  if (doc.card) world.set(CARD_KEY, doc.card);
  else expect(doc.ok, `the driver failed: ${doc.error}\n${t.stderr.slice(0, 1500)}`).toBe(true);
}

function card(world: { get<T>(k: string): T }): Card { return world.get<Card>(CARD_KEY); }

// ── driving ──────────────────────────────────────────────────────────────────
When('I open the Studio Bring-up page on a machine that is {string}', async ({ world }, machine: string) => {
  drive(world, machine, 'none');
});

When('I open the Studio Bring-up page on a {string} machine and press Start local agent chat with no terminal installed',
  async ({ world }, machine: string) => {
    drive(world, machine, 'start');
  });

When('I open the Studio Bring-up page on the kind lane and press Start local agent chat with no terminal installed',
  async ({ world }) => {
    drive(world, 'ready', 'start', 'kind');
  });

When('I open the Studio Bring-up page on a ready machine and press Copy command', async ({ world }) => {
  drive(world, 'ready', 'copy');
});

// ── the card as drawn ────────────────────────────────────────────────────────
Then('the Studio shows the local agent card on the Bring-up page', async ({ world }) => {
  const c = card(world);
  expect(c.title).toBe('Work on this mesh with a local AI agent');
  expect(c.onBringUpPage, 'the card is not inside the Bring-up page').toBe(true);
});

Then('the card offers both the Docker mesh and the kind cluster lanes', async ({ world }) => {
  const c = card(world);
  expect(c.laneChoices.join(' | ')).toContain('Docker mesh');
  expect(c.laneChoices.join(' | ')).toContain('Kind cluster');
});

Then('the card status says {string}', async ({ world }, needle: string) => {
  expect(card(world).status).toContain(needle);
});

Then('Start local agent chat is disabled and its tooltip says {string}', async ({ world }, needle: string) => {
  const c = card(world);
  expect(c.startEnabled, 'Start was enabled while a prerequisite is missing').toBe(false);
  expect(c.startTooltip).toContain(needle);
});

Then('Start local agent chat is enabled', async ({ world }) => {
  const c = card(world);
  expect(c.startEnabled, `Start is disabled; the card says: ${c.status}`).toBe(true);
  expect(c.status).toContain('Ready');
});

Then('Start local agent chat is drawn inside the card and wide enough for its label', async ({ world }) => {
  const c = card(world);
  expect(c.start.visible, 'the Start button is not drawn').toBe(true);
  expect(c.start.inside, 'the Start button sticks out of the card').toBe(true);
  expect(c.start.height).toBeGreaterThanOrEqual(20);
  expect(c.start.width, `the label is ${c.start.labelWidth}px wide`).toBeGreaterThanOrEqual((c.start.labelWidth ?? 0) + 8);
  expect(c.startText).toBe('Start local agent chat');
});

Then('nothing was started', async ({ world }) => {
  const c = card(world);
  expect(c.launchesRequested, 'a launch was requested without a press').toBe(0);
  expect(c.note, 'the card reported a launch').toBe('');
});

// ── after a press ────────────────────────────────────────────────────────────
Then('the card says no window was opened and shows the lines to run', async ({ world }) => {
  const c = card(world);
  expect(c.launchesRequested).toBe(1);
  expect(c.note).toContain('No window was opened');
  expect(c.commandShown.length, 'no lines were shown').toBeGreaterThan(0);
});

Then('the lines shown carry no auto-approve flag', async ({ world }) => {
  const c = card(world);
  expect(c.forbiddenFlags.length, 'the forbidden-flag list is empty: this check would be vacuous').toBeGreaterThan(0);
  const words = c.commandShown.split(/\s+/);
  const hits = c.forbiddenFlags.filter((f) => words.includes(f));
  expect(hits, `the shown lines carry ${hits.join(', ')}`).toEqual([]);
  expect(c.commandShown).toContain('ollama launch claude --model qwen3:8b');
  const argv = (c.plan?.argv ?? []).filter((a) => c.forbiddenFlags.includes(a));
  expect(argv).toEqual([]);
});

Then('the lines shown run in bash against the copy and start the agent there without a git error',
  async ({ world }) => {
    const c = card(world);
    const w = world.get<{ dir: string; bin: string; ran: string }>(WORK_KEY);
    const r = runCli(['bash', '--noprofile', '--norc', '-c', c.commandShown],
      { cwd: os.tmpdir(), env: { PATH: `${w.bin}:${process.env.PATH ?? '/usr/bin:/bin'}` } });
    expect(r.exitCode, `the shown lines failed:\n${r.stderr}`).toBe(0);
    expect(r.stderr, 'the shown lines printed an error').toBe('');
    expect(c.commandShown, 'the shown lines clone again').not.toContain('git clone');
    const seen = fs.readFileSync(w.ran, 'utf8').trim().split(/\s+/);
    expect(fs.realpathSync(seen[0])).toBe(fs.realpathSync(c.plan!.cwd));
    expect(seen.slice(1, 5)).toEqual(['launch', 'claude', '--model', 'qwen3:8b']);
  });

Then('the copy of the repository has no remote', async ({ world }) => {
  const c = card(world);
  expect(c.plan, 'no plan was made').toBeTruthy();
  expect(fs.existsSync(c.plan!.cwd), 'the copy was not made').toBe(true);
  expect(c.copyHasRemote, 'the copy still has a remote it could push to').toBe(false);
});

Then('the agent brief names {string}', async ({ world }, needle: string) => {
  expect(card(world).plan!.brief).toContain(needle);
});

Then('the lines the Copy command button shows make the copy first', async ({ world }) => {
  const c = card(world);
  expect(c.commandShown).toMatch(/^git clone --no-hardlinks -- /);
  expect(c.commandShown).toContain('git remote remove origin');
  expect(c.commandShown).toContain('ollama launch claude --model qwen3:8b');
  expect(c.launchesRequested, 'Copy command must not start anything').toBe(0);
});
