// evidence-report.mjs — make the evidence manifest REACHABLE FROM THE CLI.
//
// The Gherkin lane writes a screenshot / transcript / widget-grab per step plus
// a manifest indexing all of it (steps/evidence.ts, schema
// hugmesh.bdd.evidence-manifest/1). Until now the only way to find that was to
// know the layout. `tests/e2e/run.sh --evidence` prints WHERE this run's
// artefacts are and what is in them, broken down per environment and per
// interface — the two axes the operator asked to see covered.
//
// TWO SOURCES, ON PURPOSE:
//   manifest.json   the index, materialised in AfterAll — the normal case
//   manifest.jsonl  the append log, written as the run goes — read when the
//                   run is still in flight (or died before AfterAll), so a
//                   crashed run still yields its evidence instead of nothing
// The summary says WHICH it read. A summary that silently fell back would make
// a half-finished run look complete.
//
// IT NEVER REPORTS AN EMPTY SUCCESS. No run dir, no manifest, or zero artefacts
// all exit non-zero with the path it looked at. A lane that prints
// "0 artefacts" and exits 0 is the silent-skip failure this repo keeps paying
// for.
import * as fs from 'node:fs';
import * as path from 'node:path';

const argv = process.argv.slice(2);
const opt = (name, dflt = null) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes(`--${name}`);

const cwd = opt('cwd', process.cwd());
const reportDir = opt('report-dir', process.env.SNAP_REPORT_DIR || 'test-results');
const runId = opt('run-id', process.env.SNAP_RUN_ID || 'dev');
const asJson = flag('json');

// Same slug steps/evidence.ts uses for the per-run subdirectory. Kept in step
// with it by tests/scripts/test-e2e-cli-lane.sh, which writes a manifest at the
// path THIS file computes and then asserts the reader finds it.
const slug = (s) => (String(s).replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '') || 'unnamed').slice(0, 60);

const shots = process.env.SNAP_BDD_SHOTS
  ? path.resolve(cwd, process.env.SNAP_BDD_SHOTS)
  : path.resolve(cwd, reportDir, 'bdd-steps');
const runDir = path.join(shots, slug(runId));

const fail = (msg) => {
  process.stderr.write(`evidence: ${msg}\n`);
  process.exit(3);
};

if (!fs.existsSync(runDir)) {
  fail(`no evidence directory at ${runDir}\n`
     + `  Nothing has written evidence for run id '${runId}' under report dir '${reportDir}'.\n`
     + `  Run the lane first:  tests/e2e/run.sh --bdd --run-id ${runId} --report-dir ${reportDir}`);
}

const jsonPath = path.join(runDir, 'manifest.json');
const jsonlPath = path.join(runDir, 'manifest.jsonl');

let manifest = null;
let source = null;
if (fs.existsSync(jsonPath)) {
  try {
    manifest = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    source = 'manifest.json';
  } catch (e) {
    fail(`${jsonPath} is not readable JSON (${e.message}). The index is corrupt; `
       + `the append log ${jsonlPath} may still be intact.`);
  }
} else if (fs.existsSync(jsonlPath)) {
  const rows = [];
  let unparseable = 0;
  for (const line of fs.readFileSync(jsonlPath, 'utf8').split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try { rows.push(JSON.parse(s)); } catch { unparseable += 1; }
  }
  manifest = { schema: null, runId, root: runDir, generatedAt: null, artefacts: rows, unparseable };
  source = 'manifest.jsonl (run in flight — manifest.json not written yet)';
} else {
  fail(`no manifest in ${runDir}\n`
     + `  Neither manifest.json nor manifest.jsonl is there, so this run recorded NOTHING.\n`
     + `  If the lane really ran, SNAP_BDD_SHOTS / SNAP_REPORT_DIR did not match.`);
}

const rows = Array.isArray(manifest.artefacts) ? manifest.artefacts : [];
if (rows.length === 0) {
  fail(`the manifest in ${runDir} lists ZERO artefacts.\n`
     + `  An empty index is not a clean run; it means the AfterStep evidence hook `
     + `recorded nothing.`);
}

const tally = (pick) => {
  const m = {};
  for (const r of rows) {
    const k = pick(r) ?? 'unknown';
    m[k] = (m[k] ?? 0) + 1;
  }
  return Object.fromEntries(Object.entries(m).sort(([a], [b]) => a.localeCompare(b)));
};

// Counted from the ROWS, never copied out of manifest.counts: the point of this
// summary is to be a second opinion on the index, and echoing the index's own
// tally back would make a miscounted manifest agree with itself.
const summary = {
  schema: manifest.schema ?? null,
  runId: manifest.runId ?? runId,
  root: runDir,
  source,
  generatedAt: manifest.generatedAt ?? null,
  counts: {
    artefacts: rows.length,
    failed: rows.filter((r) => r.failed === true).length,
    missingOnDisk: rows.filter((r) => r.path && !fs.existsSync(path.join(runDir, r.path))).length,
    byEnv: tally((r) => r.env),
    byInterface: tally((r) => r.interface),
    byKind: tally((r) => r.kind),
    byService: tally((r) => r.service),
  },
  scenarios: [...new Set(rows.map((r) => r.scenario))].length,
  features: [...new Set(rows.map((r) => r.feature))].length,
};

if (asJson) {
  // One line — see print-plan.mjs; the harness parses the last stdout line.
  process.stdout.write(`${JSON.stringify(summary)}\n`);
} else {
  const pad = (o) => Object.entries(o).map(([k, v]) => `${k}=${v}`).join('  ') || '<none>';
  const out = [
    `==> evidence for run '${summary.runId}'`,
    `    dir        : ${summary.root}`,
    `    read from  : ${summary.source}`,
    `    schema     : ${summary.schema ?? '(not yet materialised)'}`,
    `    artefacts  : ${summary.counts.artefacts} across ${summary.scenarios} scenario(s) in ${summary.features} feature(s)`,
    `    failed step: ${summary.counts.failed}`,
    `    per env    : ${pad(summary.counts.byEnv)}`,
    `    per iface  : ${pad(summary.counts.byInterface)}`,
    `    per kind   : ${pad(summary.counts.byKind)}`,
  ];
  if (summary.counts.missingOnDisk > 0) {
    out.push(`    !! ${summary.counts.missingOnDisk} manifest row(s) point at a file that is NOT on disk`);
  }
  process.stdout.write(`${out.join('\n')}\n`);
}

// A manifest that indexes files nobody can open is worse than no manifest: a
// reviewer counts the rows and believes them. Exiting non-zero here is what
// stops that from being a footnote.
process.exit(summary.counts.missingOnDisk > 0 ? 4 : 0);
