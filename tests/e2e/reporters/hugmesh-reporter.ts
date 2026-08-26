// hugmesh-reporter.ts — the custom Playwright reporter that powers the admin-ui
// test-reports console AND the Studio's e2e feature tree.
//
// Responsibilities:
//   1. SCRUB secrets from every test title/error/annotation/path it records or
//      posts (bearer tokens, access_token=…, password=… — a test title or error
//      must never carry a credential onto the durable PVC or the SSE stream).
//   2. Map each test → ROLE + LAYER via the `@role:`/`@layer:` title tags
//      (specs/report-tags.ts) so the summary pivots by role and by enforcement
//      layer, not just total pass/fail.
//   3. Pivot by SPEC FILE and emit a record PER TEST, with its attachments
//      (screenshots, traces, videos) and — for every skipped test — a skip
//      REASON. This is what a feature tree renders: result → file → test →
//      attachment, and a grey row that can say why it is grey.
//   4. Write summary.json next to the junit/json artifacts on the test-reports
//      PVC (SNAP_REPORT_DIR), which the admin-bff TestReportsController serves
//      and hugmesh_studio/core/e2e_catalogue.py parses.
//   5. Best-effort POST per-test events to the admin-bff ingest endpoint
//      (SNAP_INGEST_URL) so the console streams live. A POST failure NEVER fails
//      the run (the durable summary.json is the source of truth).
//
// ── THE SHAPE, AND WHY IT IS THIS SHAPE ──────────────────────────────────────
// summary.json is APPEND-ONLY with respect to its old shape. Every key the
// previous version wrote is still written, spelled the same, counted the same:
// {tier,runId,result,passed,failed,skipped,perRole[],perLayer[],finishedAt}.
// hugmesh_studio/core/e2e_catalogue.py:parse_summary() reads exactly those and
// ignores unknown keys, and the admin-ui console reads the same pivot — so the
// new keys below cannot break either. The contract is pinned in
// reporters/summary.schema.json and gated by
// tests/scripts/test-e2e-reporter-shape.sh.
//
// TWO DIFFERENT NUMBERS, BOTH TRUE, BOTH NAMED. `onTestEnd` fires once per
// ATTEMPT, so the legacy top-level passed/failed/skipped count RESULTS: a test
// that fails and then passes on retry adds one to each. That is what the console
// has always shown (the 2026-08-22 run: 259 results over 221 tests) and it is
// left alone. A tree cannot use it — it would render one test as two rows — so
// `testTotals`, `perSpec[]` and `tests[]` count TESTS, final attempt winning,
// which is the same rule Playwright's own JSON reporter and e2e_catalogue.py
// use (results[-1]). Anything reading a count must pick one and know which.
//
// SKIP REASONS ARE NEVER BLANK. `test.skip(cond, 'why')` / `test.fixme()` land
// as an annotation of type skip/fixme carrying the text as `description` — on
// the result, and statically on the test. An annotation with NO description is
// the bare `test.skip()` form and is NOT a reason. In the 2026-08-22 run 62 of
// 259 results were skipped and 14 of them had nothing to say; emitting "" for
// those renders as a blank cell, and a blank cell reads as "fine". They get
// UNKNOWN_SKIP_REASON plus skipReasonKnown:false, so a surface can tell "skipped
// because LIVE_GATEWAY is unset" from "skipped, nobody knows why".
//
// Pure Node (fs + global fetch); no extra deps. Referenced by playwright.config.ts.
// Kept to ERASABLE TypeScript (no enums, no parameter properties) so that
// tests/scripts/test-e2e-reporter-shape.sh can replay it under bare `node`, with
// no node_modules installed at all.

import type {
  Reporter, FullConfig, Suite, TestCase, TestResult, FullResult,
} from '@playwright/test/reporter';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { parseTags } from '../specs/report-tags';

/** Bump when the SHAPE changes in a way a consumer must notice. */
export const SUMMARY_SCHEMA_VERSION = 2;

/** What a skipped test says when nothing said why. NEVER '' — a blank cell reads
 *  as "fine". Spelled identically to hugmesh_studio/core/e2e_catalogue.py's
 *  UNKNOWN_SKIP_REASON so a surface merging both sources shows one string. */
export const UNKNOWN_SKIP_REASON =
  'unknown — this test skipped without a machine-readable reason';

/** Redact obvious credentials from any string we persist or transmit. */
function scrub(s: string | undefined): string {
  if (!s) return '';
  return s
    .replace(/(Bearer)\s+[A-Za-z0-9._-]+/gi, '$1 REDACTED')
    .replace(/(access_token"?\s*[:=]\s*"?)[A-Za-z0-9._-]+/gi, '$1REDACTED')
    .replace(/(password"?\s*[:=]\s*"?)[^"\s,&}]+/gi, '$1REDACTED')
    .replace(/(token"?\s*[:=]\s*"?)[A-Za-z0-9._-]{8,}/gi, '$1REDACTED');
}

interface Counter { passed: number; failed: number; skipped: number; }
function emptyCounter(): Counter { return { passed: 0, failed: 0, skipped: 0 }; }

/** Playwright's annotation shape, narrowed. `TestResult.annotations` only exists
 *  on newer Playwright; read defensively so an older runner degrades to the
 *  test-level annotations rather than throwing. */
interface Annotation { type?: string; description?: string; }

interface AttachmentRecord {
  name: string;
  contentType: string;
  /** As Playwright reports it (absolute for a real run). '' for a body-only
   *  attachment, which has no file on disk. Join against `reportDir` yourself;
   *  this reporter does not rewrite paths it did not create. */
  path: string;
  /** Which attempt produced it. Retry 0 evidence is NOT superseded by a retry. */
  retry: number;
}

interface AttemptRecord {
  retry: number;
  status: string;
  durationMs: number;
  error: string;
  skipReason: string;
  skipReasonKnown: boolean;
}

interface TestRecord {
  specFile: string;
  title: string;
  titlePath: string[];
  id: string;
  line: number;
  column: number;
  project: string;
  role: string;
  layer: string;
  status: keyof Counter;
  expectedStatus: string;
  durationMs: number;
  retries: number;
  skipReason: string;
  skipReasonKnown: boolean;
  error: string;
  /** EVERY attempt's attachments, unioned, each tagged with its retry index. */
  attachments: AttachmentRecord[];
  attempts: AttemptRecord[];
}

/** (reason, isKnown) for a skipped test, from Playwright's annotations. Mirrors
 *  hugmesh_studio/core/e2e_catalogue.py:skip_reason_of() — result first, then the
 *  static test-level annotation; an EMPTY description is not a reason. */
function skipReasonOf(test: TestCase, result: TestResult): { reason: string; known: boolean } {
  const sources: Annotation[][] = [
    ((result as unknown as { annotations?: Annotation[] }).annotations) || [],
    (test.annotations as Annotation[] | undefined) || [],
  ];
  for (const anns of sources) {
    for (const ann of anns) {
      if (ann?.type !== 'skip' && ann?.type !== 'fixme') continue;
      const desc = scrub(ann?.description).trim();
      if (desc) return { reason: desc, known: true };
    }
  }
  return { reason: UNKNOWN_SKIP_REASON, known: false };
}

export default class HugMeshReporter implements Reporter {
  private dir = process.env['SNAP_REPORT_DIR'] || 'test-results';
  private tier = process.env['SNAP_REPORT_TIER'] || 'LEAN';
  private runId = process.env['SNAP_RUN_ID'] || 'dev';
  private ingest = process.env['SNAP_INGEST_URL'] || '';
  private rootDir = '';
  private totals = emptyCounter();
  private perRole = new Map<string, Counter>();
  private perLayer = new Map<string, Counter>();
  /** Keyed per TEST (not per attempt), so retries update one record. */
  private tests = new Map<string, TestRecord>();
  private pending: Promise<unknown>[] = [];

  onBegin(config: FullConfig, _suite: Suite): void {
    // rootDir is what Playwright's own JSON reporter makes `spec.file` relative
    // to. Matching it is what lets a consumer JOIN summary.json's specFile to
    // report.json's file instead of guessing at a prefix.
    this.rootDir = (config && config.rootDir) || '';
    fs.mkdirSync(this.dir, { recursive: true });
    this.post('run-begin', { tier: this.tier, runId: this.runId });
  }

  onTestEnd(test: TestCase, result: TestResult): void {
    const status: keyof Counter =
      result.status === 'passed' ? 'passed'
      : result.status === 'skipped' ? 'skipped'
      : 'failed';
    this.totals[status]++;

    const rawPath = test.titlePath();
    const { role, layer } = parseTags(rawPath.join(' '));
    bump(this.perRole, role, status);
    bump(this.perLayer, layer, status);

    const titlePath = rawPath.filter((p) => p !== '').map((p) => scrub(p));
    const specFile = this.relFile(test);
    const skip = status === 'skipped'
      ? skipReasonOf(test, result)
      : { reason: '', known: false };
    const error = status === 'failed' ? scrub(result.error?.message) : '';
    const retry = typeof result.retry === 'number' ? result.retry : 0;

    const key = this.keyOf(test, specFile, titlePath);
    let rec = this.tests.get(key);
    if (!rec) {
      const loc = test.location || { file: '', line: 0, column: 0 };
      rec = {
        specFile,
        title: scrub(test.title),
        titlePath,
        id: scrub((test as unknown as { id?: string }).id || ''),
        line: loc.line || 0,
        column: loc.column || 0,
        project: scrub(projectOf(test)),
        role, layer,
        status, expectedStatus: String(test.expectedStatus || ''),
        durationMs: result.duration || 0,
        retries: retry,
        skipReason: skip.reason,
        skipReasonKnown: skip.known,
        error,
        attachments: [],
        attempts: [],
      };
      this.tests.set(key, rec);
    } else if (retry >= rec.retries) {
      // LAST ATTEMPT WINS — the same rule Playwright's JSON reporter and
      // e2e_catalogue.py use. Earlier attempts survive in `attempts[]`, and
      // their attachments in `attachments[]`; nothing is dropped, but the
      // headline verdict is the one the run actually ended on.
      rec.status = status;
      rec.durationMs = result.duration || 0;
      rec.retries = retry;
      rec.skipReason = skip.reason;
      rec.skipReasonKnown = skip.known;
      rec.error = error;
      rec.role = role;
      rec.layer = layer;
    }
    rec.attempts.push({
      retry, status,
      durationMs: result.duration || 0,
      error, skipReason: skip.reason, skipReasonKnown: skip.known,
    });
    for (const att of result.attachments || []) {
      rec.attachments.push({
        name: scrub(att.name),
        contentType: scrub(att.contentType),
        path: scrub(att.path || ''),
        retry,
      });
    }

    this.post('test-end', {
      tier: this.tier,
      runId: this.runId,
      title: scrub(rawPath.join(' › ')),
      specFile,
      role, layer, status,
      durationMs: result.duration,
      retry,
      skipReason: status === 'skipped' ? skip.reason : undefined,
      skipReasonKnown: status === 'skipped' ? skip.known : undefined,
      attachments: rec.attachments.filter((a) => a.retry === retry),
      error: status === 'failed' ? error : undefined,
    });
  }

  async onEnd(result: FullResult): Promise<void> {
    const tests = [...this.tests.values()].sort(
      (a, b) => (a.specFile.localeCompare(b.specFile) || a.line - b.line
                 || a.title.localeCompare(b.title)),
    );

    const perSpecMap = new Map<string, Counter & { total: number; unexplainedSkips: number }>();
    for (const t of tests) {
      const c = perSpecMap.get(t.specFile)
        ?? { ...emptyCounter(), total: 0, unexplainedSkips: 0 };
      c[t.status]++;
      c.total++;
      if (t.status === 'skipped' && !t.skipReasonKnown) c.unexplainedSkips++;
      perSpecMap.set(t.specFile, c);
    }
    const perSpec = [...perSpecMap.entries()]
      .map(([file, c]) => ({ file, ...c }))
      .sort((a, b) => a.file.localeCompare(b.file));

    const testTotals = { ...emptyCounter(), total: tests.length };
    for (const t of tests) testTotals[t.status]++;
    const unexplainedSkips = tests.filter(
      (t) => t.status === 'skipped' && !t.skipReasonKnown).length;

    const summary = {
      // ── legacy shape, unchanged (per RESULT) ──
      tier: this.tier,
      runId: this.runId,
      result: result.status,
      passed: this.totals.passed,
      failed: this.totals.failed,
      skipped: this.totals.skipped,
      perRole: [...this.perRole.entries()].map(([role, c]) => ({ role, ...c })),
      perLayer: [...this.perLayer.entries()].map(([layer, c]) => ({ layer, ...c })),
      // ── the feature tree's shape (per TEST, final attempt) ──
      schemaVersion: SUMMARY_SCHEMA_VERSION,
      reportDir: scrub(this.dir),
      rootDir: scrub(this.rootDir),
      testTotals,
      unexplainedSkips,
      perSpec,
      tests,
      finishedAt: new Date().toISOString(),
    };
    fs.writeFileSync(
      path.join(this.dir, 'summary.json'),
      scrub(JSON.stringify(summary, null, 2)),
    );
    this.post('run-end', summary);
    await Promise.allSettled(this.pending);
  }

  /** The spec file, relative to rootDir — the spelling report.json uses. */
  private relFile(test: TestCase): string {
    const abs = (test.location && test.location.file) || '';
    if (!abs) return '';
    let rel = abs;
    if (this.rootDir) {
      const r = path.relative(this.rootDir, abs);
      // '..' means the file is OUTSIDE rootDir (an external testDir). Keep the
      // absolute path then: a '../../x' relative path joins to nothing useful.
      if (r && !r.startsWith('..')) rel = r;
    }
    return scrub(rel);
  }

  /** Stable per-test key. test.id is Playwright's own and is preferred; the
   *  fallback keys on file + title path so an older runner still folds retries
   *  into ONE record instead of emitting a row per attempt. */
  private keyOf(test: TestCase, specFile: string, titlePath: string[]): string {
    const id = (test as unknown as { id?: string }).id;
    return id ? `id:${id}` : `path:${specFile} ${titlePath.join(' ')}`;
  }

  /** Best-effort live event POST (never throws into the run). */
  private post(event: string, payload: Record<string, unknown>): void {
    if (!this.ingest || typeof fetch !== 'function') return;
    const body = scrub(JSON.stringify({ event, ...payload }));
    this.pending.push(
      fetch(this.ingest, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body,
      }).catch(() => { /* console is best-effort; summary.json is authoritative */ }),
    );
  }
}

function bump(m: Map<string, Counter>, key: string, status: keyof Counter): void {
  const c = m.get(key) ?? emptyCounter();
  c[status]++;
  m.set(key, c);
}

/** The project a test ran under, without assuming the runner exposes it. */
function projectOf(test: TestCase): string {
  const withProject = test as unknown as {
    parent?: { project?: () => { name?: string } | undefined };
  };
  try {
    const p = withProject.parent?.project?.();
    if (p && p.name) return p.name;
  } catch { /* older runner: no project() on the suite */ }
  return '';
}
