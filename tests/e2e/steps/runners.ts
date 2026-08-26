// runners.ts — how a Gherkin step DRIVES the cli and studio interfaces.
//
// Both runners share one rule, and it is the rule the mutation battery attacks:
// THE TRANSCRIPT REPORTS WHAT ACTUALLY HAPPENED. The exit code is the real exit
// code. A process killed by a signal reports exitCode null and the signal, not
// 0. A process that never started reports spawnError, not a clean run. Neither
// runner throws on a non-zero exit — capturing is this module's job and
// asserting is the step's — but neither one may launder a failure into a pass.
//
// NEITHER RUNNER STARTS AN ENVIRONMENT. They run a command the step named; a
// step that names `make stack-up` is a step doing something this suite forbids.

import { execFileSync, spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  CliTranscript, StudioGrab, capOutput, recordCli, recordStudio, runDir,
} from './evidence';
import { studioDriverPath, studioPython } from './dimensions';

/** Repo root, from steps/ -> e2e -> tests -> repo. */
export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

const DEFAULT_TIMEOUT_MS = Number(process.env.SNAP_CLI_TIMEOUT_MS || '120000');

export interface RunCliOptions {
  cwd?: string;
  /** Extra env for the child. Recorded in the transcript; the ambient env is not. */
  env?: Record<string, string>;
  timeoutMs?: number;
  /** stdin to feed the child. */
  input?: string;
}

/** Render argv the way a human would type it, for the transcript's first line. */
function shellish(argv: string[]): string {
  return argv.map((a) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`))
    .join(' ');
}

/**
 * Run a command, capture EVERYTHING, record it as this step's evidence, and
 * hand the transcript back for the step to assert on.
 *
 * Synchronous on purpose: a Gherkin step is already serialised, spawnSync gives
 * an unambiguous status/signal pair, and an async pipe adds a race between the
 * exit event and the last chunk of stdout that shows up as randomly-empty
 * evidence.
 */
export function runCli(argv: string[], opts: RunCliOptions = {}): CliTranscript {
  if (argv.length === 0) {
    throw new Error('runCli() needs a non-empty argv. Pass [cmd, ...args] — never a '
                  + 'single shell string, which would route through a shell this '
                  + 'runner deliberately does not use.');
  }
  const cwd = opts.cwd ?? REPO_ROOT;
  const envOverrides = { ...(opts.env ?? {}) };
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const started = Date.now();
  const r = spawnSync(argv[0], argv.slice(1), {
    cwd,
    env: { ...process.env, ...envOverrides },
    encoding: 'utf8',
    timeout: timeoutMs,
    input: opts.input,
    maxBuffer: 32 * 1024 * 1024,
  });
  const durationMs = Date.now() - started;
  const out = capOutput(r.stdout ?? '');
  const err = capOutput(r.stderr ?? '');
  const t: CliTranscript = {
    command: shellish(argv),
    argv,
    cwd,
    envOverrides,
    stdout: out.text,
    stderr: err.text,
    // r.status is the REAL code; null when signalled or never started. It is
    // never defaulted — `r.status ?? 0` here is the exact mutation the guard
    // battery plants and expects to be caught.
    exitCode: r.status,
    signal: r.signal ?? null,
    spawnError: r.error ? `${(r.error as NodeJS.ErrnoException).code ?? ''} ${r.error.message}`.trim() : null,
    durationMs,
    // spawnSync surfaces a timeout as signal SIGTERM plus an ETIMEDOUT error.
    timedOut: Boolean(r.error && (r.error as NodeJS.ErrnoException).code === 'ETIMEDOUT'),
    truncated: out.truncated || err.truncated,
    at: new Date(started).toISOString(),
  };
  recordCli(t);
  return t;
}

/** True when the command ran to completion with status 0. Nothing else counts. */
export function cliSucceeded(t: CliTranscript): boolean {
  return t.spawnError === null && t.signal === null && t.exitCode === 0;
}

/** A one-line human verdict for an assertion message. */
export function cliVerdict(t: CliTranscript): string {
  if (t.spawnError) return `never started (${t.spawnError})`;
  if (t.signal) return `killed by ${t.signal}${t.timedOut ? ' after timing out' : ''}`;
  return `exit ${t.exitCode}`;
}

// ── studio ───────────────────────────────────────────────────────────────────

export interface RunStudioOptions {
  /** Wizard page slug to advance to before grabbing. Omit for the entry page. */
  page?: string;
  /** Extra driver arguments, passed through verbatim. */
  extraArgs?: string[];
  timeoutMs?: number;
  env?: Record<string, string>;
}

/**
 * Drive the REAL PyQt Studio wizard offscreen and grab it.
 *
 * The driver is a separate python process because this harness is Node: there
 * is no in-process way to hold a QApplication. Its stdout is a single JSON
 * object; anything else — a Qt warning, a traceback — lands in stderr and is
 * kept in the transcript, so a grab that fails is explainable rather than just
 * absent.
 */
export function runStudio(opts: RunStudioOptions = {}): StudioGrab {
  const tmpDir = path.join(runDir(), '.driver-tmp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const png = path.join(tmpDir, `grab-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.png`);
  const argv = [
    studioPython(), studioDriverPath(),
    '--generator-dir', REPO_ROOT,
    '--grab', png,
    ...(opts.page ? ['--page', opts.page] : []),
    ...(opts.extraArgs ?? []),
  ];
  const t = runCli(argv, {
    cwd: REPO_ROOT,
    timeoutMs: opts.timeoutMs ?? 180_000,
    // offscreen is what makes this headless-safe; a Studio that tried to open a
    // real window on a runner with no display would abort, and the operator's
    // Wayland box would get a window flashing up mid-suite.
    env: { QT_QPA_PLATFORM: 'offscreen', ...(opts.env ?? {}) },
  });
  let parsed: { ok?: boolean; png?: string; page?: string; binding?: string;
                width?: number; height?: number; error?: string } = {};
  try {
    parsed = JSON.parse(t.stdout.trim().split('\n').filter(Boolean).pop() ?? '{}');
  } catch {
    parsed = {};
  }
  const grab: StudioGrab = {
    pngPath: parsed.png ?? png,
    page: parsed.page ?? (opts.page ?? 'unknown'),
    binding: parsed.binding ?? 'unknown',
    width: parsed.width ?? -1,
    height: parsed.height ?? -1,
    transcript: t,
  };
  recordStudio(grab);
  return grab;
}

/** True only when the driver reported a grab AND the PNG is on disk non-empty. */
export function studioGrabbed(g: StudioGrab): boolean {
  if (!cliSucceeded(g.transcript)) return false;
  try { return fs.statSync(g.pngPath).size > 0; } catch { return false; }
}

/** Ask the driver which wizard page slugs exist. Used by catalogue-driven features. */
export function studioPageSlugs(): string[] {
  const out = execFileSync(
    studioPython(), [studioDriverPath(), '--list-pages'],
    {
      encoding: 'utf8', timeout: 60_000,
      env: { ...process.env, QT_QPA_PLATFORM: 'offscreen' },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  return JSON.parse(out.trim().split('\n').filter(Boolean).pop() ?? '[]') as string[];
}

/** Where a runner may safely scribble. Never the git tree. */
export function scratchDir(): string {
  return process.env.SNAP_CLI_SCRATCH || path.join(os.tmpdir(), 'hugmesh-bdd-cli');
}
