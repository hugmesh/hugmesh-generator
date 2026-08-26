// e2e-reporter-replay.mjs — replay a RECORDED run through the REAL reporter.
//
// Usage: node e2e-reporter-replay.mjs <fixture.json> <out-dir> [reporter.ts]
//
// WHY A REPLAY AND NOT A RUN. Asserting on summary.json after running the suite
// proves only that the writer agrees with itself, and it needs a live stack, a
// browser and ~40 minutes. This drives tests/e2e/reporters/hugmesh-reporter.ts
// directly: it hands the reporter the same onBegin/onTestEnd/onEnd calls
// Playwright made during a real run (the fixture is that run's report.json
// flattened back into the calls that produced it) and lets it write summary.json
// wherever it is told. The SHAPE of what comes out is then checked against
// reporters/summary.schema.json, which no part of the reporter can edit.
//
// NO node_modules. The reporter imports only node builtins, specs/report-tags.ts
// and TYPES from @playwright/test (erased at load). So this runs under bare node
// on a checkout that has never had `npm ci` — which is most checkouts.
//
// The TestCase/TestResult stand-ins below carry exactly the fields the reporter
// reads. Anything the reporter starts reading that Playwright supplies but this
// does not will surface as undefined here, loudly, rather than as a field that
// quietly stops being emitted in production.

import { registerHooks } from 'node:module';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { pathToFileURL } from 'node:url';

// The reporter says `from '../specs/report-tags'` — extensionless, which is what
// Playwright's own loader accepts and node's ESM resolver does not. Resolve it
// here instead of editing production to suit the harness.
registerHooks({
  resolve(spec, ctx, next) {
    if (spec.startsWith('.') && !/\.[cm]?[jt]sx?$/.test(spec)) {
      try {
        return next(spec + '.ts', ctx);
      } catch {
        /* not a .ts sibling; fall through to the normal resolution */
      }
    }
    return next(spec, ctx);
  },
});

const [fixturePath, outDir, reporterArg] = process.argv.slice(2);
if (!fixturePath || !outDir) {
  console.error('usage: node e2e-reporter-replay.mjs <fixture.json> <out-dir> [reporter.ts]');
  process.exit(2);
}
const here = path.dirname(new URL(import.meta.url).pathname);
const reporterPath = path.resolve(
  reporterArg || path.join(here, '..', 'e2e', 'reporters', 'hugmesh-reporter.ts'),
);
if (!fs.existsSync(reporterPath)) {
  console.error(`replay: reporter not found: ${reporterPath}`);
  process.exit(2);
}

const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const events = fixture.events || [];
if (!events.length) {
  console.error(`replay: ${fixturePath} has no events — a replay of nothing would pass everything`);
  process.exit(2);
}

// SNAP_REPORT_DIR is read by the reporter's field initialisers, i.e. at
// construction. Set it before importing/constructing, not after.
fs.mkdirSync(outDir, { recursive: true });
process.env.SNAP_REPORT_DIR = outDir;
process.env.SNAP_REPORT_TIER = process.env.SNAP_REPORT_TIER || fixture.tier || 'LEAN';
process.env.SNAP_RUN_ID = process.env.SNAP_RUN_ID || fixture.runId || 'replay';
// No live console during a replay: an ingest POST would be a network call from a
// guard that promises to make none.
delete process.env.SNAP_INGEST_URL;

const mod = await import(pathToFileURL(reporterPath).href);
const Reporter = mod.default;
if (typeof Reporter !== 'function') {
  console.error(`replay: ${reporterPath} has no default-exported reporter class`);
  process.exit(2);
}
const reporter = new Reporter();

/** A TestCase stand-in: only what a reporter is allowed to read. */
function testCase(spec) {
  const projectName = spec.projectName || '';
  return {
    id: spec.id || '',
    title: spec.title || '',
    titlePath: () => (spec.titlePath || []).slice(),
    location: spec.location || { file: '', line: 0, column: 0 },
    annotations: spec.annotations || [],
    expectedStatus: spec.expectedStatus || 'passed',
    // Playwright hangs the project off the suite chain; the reporter reads it
    // through parent.project(), so the stand-in must too.
    parent: { project: () => ({ name: projectName }) },
  };
}

function testResult(res) {
  return {
    status: res.status,
    duration: res.duration || 0,
    retry: res.retry || 0,
    error: res.error || undefined,
    errors: res.error ? [res.error] : [],
    annotations: res.annotations || [],
    attachments: res.attachments || [],
    stdout: [],
    stderr: [],
    steps: [],
  };
}

const config = { rootDir: (fixture.config && fixture.config.rootDir) || '' };
reporter.onBegin?.(config, { allTests: () => [] });
for (const ev of events) {
  reporter.onTestEnd(testCase(ev.test), testResult(ev.result));
}
await reporter.onEnd({ status: fixture.runStatus || 'failed' });

const written = path.join(outDir, 'summary.json');
if (!fs.existsSync(written)) {
  console.error(`replay: the reporter wrote no ${written}`);
  process.exit(1);
}
console.log(`replay: ${events.length} event(s) from ${path.basename(fixturePath)} -> ${written}`);
