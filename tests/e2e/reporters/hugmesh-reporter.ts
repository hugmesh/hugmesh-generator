// hugmesh-reporter.ts — the custom Playwright reporter that powers the admin-ui
// test-reports console.
//
// Responsibilities:
//   1. SCRUB secrets from every test title/error/annotation it records or posts
//      (bearer tokens, access_token=…, password=… — a test title or error must
//      never carry a credential onto the durable PVC or the SSE stream).
//   2. Map each test → ROLE + LAYER via the `@role:`/`@layer:` title tags
//      (specs/report-tags.ts) so the summary pivots by role and by enforcement
//      layer, not just total pass/fail.
//   3. Write summary.json {tier, passed, failed, skipped, perRole[], perLayer[]}
//      next to the junit/json artifacts on the test-reports PVC
//      (SNAP_REPORT_DIR), which the admin-bff TestReportsController serves.
//   4. Best-effort POST per-test events to the admin-bff ingest endpoint
//      (SNAP_INGEST_URL) so the console streams live. A POST failure NEVER fails
//      the run (the durable summary.json is the source of truth).
//
// Pure Node (fs + global fetch); no extra deps. Referenced by playwright.config.ts.

import type {
  Reporter, FullConfig, Suite, TestCase, TestResult, FullResult,
} from '@playwright/test/reporter';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { parseTags } from '../specs/report-tags';

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

export default class HugMeshReporter implements Reporter {
  private dir = process.env['SNAP_REPORT_DIR'] || 'test-results';
  private tier = process.env['SNAP_REPORT_TIER'] || 'LEAN';
  private runId = process.env['SNAP_RUN_ID'] || 'dev';
  private ingest = process.env['SNAP_INGEST_URL'] || '';
  private totals = emptyCounter();
  private perRole = new Map<string, Counter>();
  private perLayer = new Map<string, Counter>();
  private pending: Promise<unknown>[] = [];

  onBegin(_config: FullConfig, _suite: Suite): void {
    fs.mkdirSync(this.dir, { recursive: true });
    this.post('run-begin', { tier: this.tier, runId: this.runId });
  }

  onTestEnd(test: TestCase, result: TestResult): void {
    const status: keyof Counter =
      result.status === 'passed' ? 'passed'
      : result.status === 'skipped' ? 'skipped'
      : 'failed';
    this.totals[status]++;

    const { role, layer } = parseTags(test.titlePath().join(' '));
    bump(this.perRole, role, status);
    bump(this.perLayer, layer, status);

    this.post('test-end', {
      tier: this.tier,
      runId: this.runId,
      title: scrub(test.titlePath().join(' › ')),
      role, layer, status,
      durationMs: result.duration,
      error: status === 'failed' ? scrub(result.error?.message) : undefined,
    });
  }

  async onEnd(result: FullResult): Promise<void> {
    const summary = {
      tier: this.tier,
      runId: this.runId,
      result: result.status,
      passed: this.totals.passed,
      failed: this.totals.failed,
      skipped: this.totals.skipped,
      perRole: [...this.perRole.entries()].map(([role, c]) => ({ role, ...c })),
      perLayer: [...this.perLayer.entries()].map(([layer, c]) => ({ layer, ...c })),
      finishedAt: new Date().toISOString(),
    };
    fs.writeFileSync(
      path.join(this.dir, 'summary.json'),
      scrub(JSON.stringify(summary, null, 2)),
    );
    this.post('run-end', summary);
    await Promise.allSettled(this.pending);
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
