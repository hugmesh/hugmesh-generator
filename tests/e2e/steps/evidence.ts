// evidence.ts — WHAT A STEP LEAVES BEHIND, on every interface, in every environment.
//
// THE ASK THIS SERVES. "take screenshots in docker, local devops, and qemu
// emulated e2e testing through cli and gui". A screenshot is the right artefact
// for exactly one of the three interfaces. A terminal has no screenshot: its
// honest equivalent is a TRANSCRIPT — argv, stdout, stderr, exit code,
// duration. The Studio has no browser page: its equivalent is a Qt widget grab.
// So "evidence" is an interface-shaped thing, and this module is where each
// shape is written and indexed.
//
// THE MANIFEST IS A CONTRACT. The Studio's feature tree browses the manifest, so
// downstream code depends on its shape. It is versioned (EVIDENCE_SCHEMA) and
// pinned by a fixture that is NOT read back from a run — see
// tests/e2e/evidence-manifest.schema.json and the guard that compares against
// it. Validating a run's manifest against a schema derived from that same run
// is circular and proves nothing.
//
// WHY JSONL DURING THE RUN AND JSON AT THE END. The index has to list every
// artefact, but rewriting a whole JSON array after every Gherkin step is
// quadratic — a few thousand steps would rewrite ~1MB thousands of times. So
// each step APPENDS one line to manifest.jsonl (an O_APPEND write, which is
// also the only concurrency-safe option if this suite ever runs workers > 1),
// and manifest.json is materialised once from those lines in AfterAll.
// materializeManifest() is exported so a runner can rebuild the index after a
// crashed run rather than losing it.
//
// PATHS ARE RELATIVE. Every record's `path` is relative to the manifest's own
// directory, with the absolute base in the top-level `root`. Absolute paths
// inside the records would break the moment the report dir is copied off a
// runner onto the test-reports PVC — which is exactly what this repo does.

import * as fs from 'node:fs';
import * as path from 'node:path';

/** Bump the trailing integer on any BREAKING change to a record's shape. */
export const EVIDENCE_SCHEMA = 'hugmesh.bdd.evidence-manifest/1';

/** Base dir for per-step evidence — under the REPORT dir, never the git tree. */
export const BDD_SHOTS = path.resolve(
  process.env.SNAP_BDD_SHOTS
  || path.join(process.env.SNAP_REPORT_DIR || 'test-results', 'bdd-steps'),
);

/** Per-run subdir, keyed the same way the hugmesh reporter keys summary.json. */
export const RUN_ID = process.env.SNAP_RUN_ID || 'dev';

export function slug(s: string, max = 60): string {
  return (s.replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '') || 'unnamed').slice(0, max);
}

/** The one directory this run's artefacts and manifest live in. */
export function runDir(): string {
  return path.join(BDD_SHOTS, slug(RUN_ID));
}

export function manifestJsonlPath(): string { return path.join(runDir(), 'manifest.jsonl'); }
export function manifestJsonPath(): string { return path.join(runDir(), 'manifest.json'); }

/**
 * The artefact kinds. `transcript` is the record of truth for the cli
 * interface; `transcript-text` is its human-readable rendering and
 * `transcript-render` a convenience PICTURE of it — neither is ever what an
 * assertion reads. `sidecar-only` is written when a step
 * on a non-browser interface ran no command at all — a loud "this step produced
 * no command output", rather than a silent hole in the index.
 */
export type ArtefactKind =
  | 'screenshot' | 'transcript' | 'transcript-text' | 'transcript-render'
  | 'widget-grab' | 'sidecar-only';

/**
 * ONE ROW OF THE MANIFEST — the pinned contract. Every field is always present;
 * an unknown dimension is `null`, never an omitted key, so a consumer can index
 * on it without existence checks.
 */
export interface EvidenceRecord {
  env: string;
  interface: string;
  feature: string;
  scenario: string;
  step: string;
  ordinal: number;
  role: string | null;
  service: string | null;
  platform: string | null;
  layer: string | null;
  failed: boolean;
  kind: ArtefactKind;
  /** POSIX-relative to the manifest's directory (`root`). */
  path: string;
  /** POSIX-relative path of this step's JSON sidecar. */
  sidecar: string;
  /** Bytes on disk at write time; -1 when it could not be stat'ed. */
  bytes: number;
  at: string;
  /** Populated for sidecar-only and for any degraded artefact. Else ''. */
  note: string;
}

/** The materialised index. */
export interface EvidenceManifest {
  schema: string;
  runId: string;
  root: string;
  generatedAt: string;
  counts: {
    artefacts: number;
    failed: number;
    byEnv: Record<string, number>;
    byInterface: Record<string, number>;
    byKind: Record<string, number>;
  };
  artefacts: EvidenceRecord[];
}

// ── what a step did, collected while it runs ─────────────────────────────────

/** A CLI invocation, captured whole. This is the cli interface's evidence. */
export interface CliTranscript {
  /** Shell-ish rendering for a human reading the report. Never re-executed. */
  command: string;
  argv: string[];
  cwd: string;
  /** ONLY the overrides this call set. The ambient env is never captured — it
   *  carries tokens, and evidence gets copied onto shared PVCs. */
  envOverrides: Record<string, string>;
  stdout: string;
  stderr: string;
  /** The REAL exit code. null when the process was killed by a signal — never
   *  coerced to 0, which would make a crashed command read as a clean one. */
  exitCode: number | null;
  signal: string | null;
  /**
   * Set when the process could not be STARTED at all (ENOENT, EACCES). That is
   * a different failure from "ran and exited non-zero", and collapsing the two
   * is how a missing binary reads as a failing assertion. null on a real run.
   */
  spawnError: string | null;
  durationMs: number;
  timedOut: boolean;
  /** True when stdout/stderr were cut to the cap; the cap is noted inline. */
  truncated: boolean;
  at: string;
}

/** A Studio widget grab produced by tests/e2e/studio-driver.py. */
export interface StudioGrab {
  /** Absolute path the driver wrote the PNG to. Copied into the run dir. */
  pngPath: string;
  /** Which wizard page was grabbed. */
  page: string;
  /** PySide6 | PyQt6 — which binding actually rendered it. */
  binding: string;
  width: number;
  height: number;
  /** The driver invocation itself, so a failed grab is still explainable. */
  transcript: CliTranscript;
}

// Per-step collection buffers. Module-level, which is the SAME idiom world.ts
// already uses for `stepOrdinal`: module state is per-worker, and a worker runs
// one test at a time, so there is no cross-scenario bleed.
let pendingCli: CliTranscript[] = [];
let pendingStudio: StudioGrab[] = [];

export function recordCli(t: CliTranscript): void { pendingCli.push(t); }
export function recordStudio(g: StudioGrab): void { pendingStudio.push(g); }

/** Hand the buffers to the AfterStep hook and reset them. */
export function drainPending(): { cli: CliTranscript[]; studio: StudioGrab[] } {
  const out = { cli: pendingCli, studio: pendingStudio };
  pendingCli = [];
  pendingStudio = [];
  return out;
}

/** Drop anything collected. Called in Before so a torn-down scenario cannot
 *  leak its last command into the first step of the next one. */
export function clearPending(): void { pendingCli = []; pendingStudio = []; }

// ── writing ──────────────────────────────────────────────────────────────────

function relToRun(abs: string): string {
  return path.relative(runDir(), abs).split(path.sep).join('/');
}

function bytesOf(p: string): number {
  try { return fs.statSync(p).size; } catch { return -1; }
}

/** Render a transcript as the plain text a human actually wants to read. */
export function transcriptText(t: CliTranscript): string {
  const code = t.spawnError !== null
    ? `NEVER STARTED: ${t.spawnError}`
    : t.exitCode === null
      ? `killed by ${t.signal ?? 'unknown signal'}`
      : String(t.exitCode);
  return [
    `$ ${t.command}`,
    `# cwd      : ${t.cwd}`,
    `# argv     : ${JSON.stringify(t.argv)}`,
    `# env      : ${JSON.stringify(t.envOverrides)}`,
    `# exit     : ${code}`,
    `# duration : ${t.durationMs}ms${t.timedOut ? '  (TIMED OUT)' : ''}`,
    `# at       : ${t.at}`,
    '',
    '--- stdout ---',
    t.stdout,
    '--- stderr ---',
    t.stderr,
    t.truncated ? '--- (output truncated) ---' : '',
  ].join('\n');
}

/**
 * The per-step meta every artefact of that step points back at. This is the
 * SIDECAR SCHEMA — the pre-existing fields are unchanged so anything already
 * reading them keeps working; `env` and `interface` are the two additions.
 */
export interface StepMeta {
  feature: string;
  scenario: string;
  step: string;
  ordinal: number;
  role: string | null;
  platform: string | null;
  service: string | null;
  layer: string | null;
  env: string;
  interface: string;
  failed: boolean;
  at: string;
}

/** Build one manifest row from the step meta plus this artefact's specifics. */
function record(
  meta: StepMeta, kind: ArtefactKind, abs: string, sidecarAbs: string, note = '',
): EvidenceRecord {
  return {
    env: meta.env,
    interface: meta.interface,
    feature: meta.feature,
    scenario: meta.scenario,
    step: meta.step,
    ordinal: meta.ordinal,
    role: meta.role,
    service: meta.service,
    platform: meta.platform,
    layer: meta.layer,
    failed: meta.failed,
    kind,
    path: relToRun(abs),
    sidecar: relToRun(sidecarAbs),
    bytes: bytesOf(abs),
    at: meta.at,
    note,
  };
}

/**
 * Append rows to the run's JSONL index. O_APPEND, one write per row, so a
 * concurrent worker cannot interleave a partial line into another's.
 */
export function appendManifest(records: EvidenceRecord[]): void {
  if (records.length === 0) return;
  fs.mkdirSync(runDir(), { recursive: true });
  fs.appendFileSync(
    manifestJsonlPath(),
    records.map((r) => JSON.stringify(r)).join('\n') + '\n',
  );
}

/**
 * Build manifest.json from manifest.jsonl. Idempotent, and safe to call on a
 * run that wrote nothing (it then writes an EMPTY manifest rather than none —
 * an absent manifest is indistinguishable from "the harness never ran", which
 * is the ambiguity this whole suite exists to remove).
 *
 * A malformed line is NOT silently dropped: it becomes a `sidecar-only` row
 * carrying the raw text in `note`, so corruption is visible in the index
 * instead of shrinking the count for no stated reason.
 */
export function materializeManifest(): EvidenceManifest {
  const dir = runDir();
  fs.mkdirSync(dir, { recursive: true });
  const jsonl = manifestJsonlPath();
  const artefacts: EvidenceRecord[] = [];
  if (fs.existsSync(jsonl)) {
    for (const line of fs.readFileSync(jsonl, 'utf8').split('\n')) {
      const s = line.trim();
      if (!s) continue;
      try {
        artefacts.push(JSON.parse(s) as EvidenceRecord);
      } catch (e) {
        artefacts.push({
          env: 'unknown', interface: 'unknown', feature: 'unknown', scenario: 'unknown',
          step: 'unknown', ordinal: -1, role: null, service: null, platform: null,
          layer: null, failed: true, kind: 'sidecar-only', path: '', sidecar: '',
          bytes: -1, at: new Date().toISOString(),
          note: `UNPARSEABLE manifest.jsonl line (${(e as Error).message}): ${s.slice(0, 300)}`,
        });
      }
    }
  }
  const tally = (key: (r: EvidenceRecord) => string): Record<string, number> => {
    const m: Record<string, number> = {};
    for (const r of artefacts) m[key(r)] = (m[key(r)] ?? 0) + 1;
    return m;
  };
  const manifest: EvidenceManifest = {
    schema: EVIDENCE_SCHEMA,
    runId: RUN_ID,
    root: dir,
    generatedAt: new Date().toISOString(),
    counts: {
      artefacts: artefacts.length,
      failed: artefacts.filter((r) => r.failed).length,
      byEnv: tally((r) => r.env),
      byInterface: tally((r) => r.interface),
      byKind: tally((r) => r.kind),
    },
    artefacts,
  };
  fs.writeFileSync(manifestJsonPath(), JSON.stringify(manifest, null, 2));
  return manifest;
}

/** Cap on captured stdout/stderr. Evidence, not a log sink. */
const OUTPUT_CAP = Number(process.env.SNAP_CLI_OUTPUT_CAP || '262144');

export function capOutput(s: string): { text: string; truncated: boolean } {
  if (s.length <= OUTPUT_CAP) return { text: s, truncated: false };
  return {
    text: `${s.slice(0, OUTPUT_CAP)}\n…[truncated at ${OUTPUT_CAP} bytes; `
        + `raise SNAP_CLI_OUTPUT_CAP to capture more]`,
    truncated: true,
  };
}

/**
 * Write every artefact this step earned, and return the manifest rows.
 *
 * ORDER OF OPERATIONS is deliberate. The sidecar is written FIRST and always,
 * so every row can point at a file that exists even if the artefact itself
 * fails to write. Then, independent of the declared interface:
 *   * any CLI transcripts collected during the step,
 *   * any Studio grabs collected during the step,
 * are written — a scenario that declares one interface but calls another's
 * runner still gets its evidence, rather than dropping it because a tag said
 * otherwise. Then the declared interface's PRIMARY artefact is written.
 */
export interface WriteStepArgs {
  dir: string;
  stem: string;
  meta: StepMeta;
  cli: CliTranscript[];
  studio: StudioGrab[];
  /** Writes the browser PNG. Absent for a step with no page to shoot. */
  screenshot?: (dest: string) => Promise<void>;
  /** Optional cheap PNG rendering of a transcript. Returns false if it declined. */
  renderTranscript?: (t: CliTranscript, dest: string) => Promise<boolean>;
}

export async function writeStepEvidence(a: WriteStepArgs): Promise<EvidenceRecord[]> {
  const { dir, stem, meta } = a;
  fs.mkdirSync(dir, { recursive: true });
  const sidecar = path.join(dir, `${stem}.json`);
  fs.writeFileSync(sidecar, JSON.stringify(meta, null, 2));

  const rows: EvidenceRecord[] = [];

  // ── cli transcripts ───────────────────────────────────────────────────────
  for (const [i, t] of a.cli.entries()) {
    const sfx = a.cli.length > 1 ? `.${i + 1}` : '';
    const jsonAbs = path.join(dir, `${stem}${sfx}.cli.json`);
    const txtAbs = path.join(dir, `${stem}${sfx}.cli.txt`);
    fs.writeFileSync(jsonAbs, JSON.stringify(t, null, 2));
    fs.writeFileSync(txtAbs, transcriptText(t));
    const exitNote = t.spawnError !== null
      ? `spawn-failed:${t.spawnError}`
      : t.exitCode === null ? `signal:${t.signal}` : String(t.exitCode);
    rows.push(record(meta, 'transcript', jsonAbs, sidecar,
      `exit=${exitNote} text=${relToRun(txtAbs)}`));
    // The .txt is a SEPARATE artefact on disk, so it gets its own row. Mentioning
    // it only in the note above left a real file with no index entry — an orphan
    // of exactly the kind the M4 mutation plants deliberately.
    rows.push(record(meta, 'transcript-text', txtAbs, sidecar,
      'human-readable rendering of the transcript; the .cli.json is the record of truth'));
    if (a.renderTranscript) {
      const pngAbs = path.join(dir, `${stem}${sfx}.cli.png`);
      try {
        if (await a.renderTranscript(t, pngAbs)) {
          rows.push(record(meta, 'transcript-render', pngAbs, sidecar,
            'convenience rendering of the transcript; the .cli.json is the record of truth'));
        }
      } catch (e) {
        // A failed picture never costs us the transcript.
        rows.push(record(meta, 'transcript', jsonAbs, sidecar,
          `transcript PNG rendering failed (${(e as Error).message}); `
          + 'the transcript itself is intact'));
      }
    }
  }

  // ── studio widget grabs ───────────────────────────────────────────────────
  for (const [i, g] of a.studio.entries()) {
    const sfx = a.studio.length > 1 ? `.${i + 1}` : '';
    const jsonAbs = path.join(dir, `${stem}${sfx}.studio.json`);
    fs.writeFileSync(jsonAbs, JSON.stringify(g, null, 2));
    const pngAbs = path.join(dir, `${stem}${sfx}.studio.png`);
    let note = `page=${g.page} binding=${g.binding} ${g.width}x${g.height}`;
    try {
      fs.copyFileSync(g.pngPath, pngAbs);
      rows.push(record(meta, 'widget-grab', pngAbs, sidecar, note));
    } catch (e) {
      note = `widget grab MISSING at ${g.pngPath}: ${(e as Error).message}`;
      rows.push(record(meta, 'sidecar-only', sidecar, sidecar, note));
    }
    rows.push(record(meta, 'transcript', jsonAbs, sidecar,
      'the studio-driver.py invocation behind the grab'));
  }

  // ── the declared interface's primary artefact ─────────────────────────────
  if (meta.interface === 'browser' && a.screenshot) {
    const pngAbs = path.join(dir, `${stem}.png`);
    try {
      await a.screenshot(pngAbs);
      rows.push(record(meta, 'screenshot', pngAbs, sidecar));
    } catch (e) {
      rows.push(record(meta, 'sidecar-only', sidecar, sidecar,
        `browser screenshot failed: ${(e as Error).message}`));
    }
  } else if (meta.interface !== 'browser' && rows.length === 0) {
    // A cli/studio step that drove nothing. Say so IN the index rather than
    // leaving a gap a reader would have to notice by counting.
    rows.push(record(meta, 'sidecar-only', sidecar, sidecar,
      `step ran on the '${meta.interface}' interface but invoked no command, so there `
      + 'is no transcript or grab to record; the sidecar is the whole evidence'));
  }

  return rows;
}

/**
 * Read back the rows appended so far this run.
 *
 * Steps use this to assert on their OWN scenario's evidence — by the time step
 * N+1 runs, step N's rows are already on disk. It reads manifest.jsonl (the
 * append log), not manifest.json (which only exists after AfterAll), so it works
 * mid-run.
 *
 * A guard must NOT use this as its schema oracle: validating a run's manifest
 * against a shape read out of that same run proves only that the run agreed
 * with itself. The pinned fixture at tests/e2e/evidence-manifest.schema.json is
 * the oracle.
 */
export function readManifestRows(): EvidenceRecord[] {
  const p = manifestJsonlPath();
  if (!fs.existsSync(p)) return [];
  const out: EvidenceRecord[] = [];
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try { out.push(JSON.parse(s) as EvidenceRecord); } catch { /* reported by materializeManifest */ }
  }
  return out;
}

/** Rows belonging to one scenario title. */
export function manifestRowsForScenario(scenario: string): EvidenceRecord[] {
  return readManifestRows().filter((r) => r.scenario === scenario);
}

/** Absolute path of a record's artefact. */
export function artefactPath(r: EvidenceRecord): string {
  return path.join(runDir(), r.path);
}
