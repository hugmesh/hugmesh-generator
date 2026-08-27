import { defineConfig, devices } from '@playwright/test';
import { defineBddConfig } from 'playwright-bdd';
import * as fs from 'node:fs';

// ── BDD (Gherkin) lane ───────────────────────────────────────────────────────
// playwright-bdd compiles every tests/e2e/features/**/*.feature into a generated
// .spec.js under .features-gen/ (GITIGNORED — a generated artefact is never
// committed) and binds it to the step definitions in steps/. The `bdd` project
// below runs those; the `chromium` project keeps running the 33 handwritten
// specs/ unchanged. Both lanes therefore drive the SAME helpers.
//
// missingSteps defaults to 'fail-on-gen': a .feature using a step nobody defines
// FAILS `npx bddgen` instead of being skipped. That is the anti-decoration
// property this repo needs — a .feature that never executes is worse than no
// file, because it looks like coverage.
const bddTestDir = defineBddConfig({
  features: 'features/**/*.feature',
  steps: ['steps/**/*.ts'],
  outputDir: '.features-gen',
  // Loud on ambiguity/arity rather than quietly binding the wrong definition.
  missingSteps: 'fail-on-gen',
  arityCheck: true,
});
// Playwright errors out when a project's testDir does not exist, which would
// break the EXISTING lane on a checkout where bddgen has not run yet. Creating
// the (empty, gitignored) dir keeps `npx playwright test` working before the
// first bddgen; the guard suite is what proves the dir is actually populated.
fs.mkdirSync(bddTestDir, { recursive: true });
// NO SILENT SKIP. If .feature files exist but nothing has been generated, the
// `bdd` project would contribute ZERO tests and a plain `npx playwright test`
// would look exactly as green as a full run. Warn loudly on stderr instead of
// throwing, because throwing would break the LEGACY `make stack-e2e` lane for
// anyone who has not run bddgen. `make stack-e2e-bdd` / `-check` always run
// bddgen first (they depend on stack-e2e-bdd-gen), and
// tests/scripts/test-e2e-gherkin-harness.sh is the hard gate.
{
  const countFeatures = (dir: string): number => {
    let n = 0;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) n += countFeatures(`${dir}/${e.name}`);
      else if (e.name.endsWith('.feature')) n += 1;
    }
    return n;
  };
  const countGenerated = (dir: string): number => {
    let n = 0;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) n += countGenerated(`${dir}/${e.name}`);
      else if (e.name.endsWith('.spec.js') || e.name.endsWith('.spec.ts')) n += 1;
    }
    return n;
  };
  const features = fs.existsSync('features') ? countFeatures('features') : 0;
  const generated = countGenerated(bddTestDir);
  if (features > 0 && generated === 0) {
    process.stderr.write(
      `\n!! GHERKIN LANE NOT GENERATED: ${features} .feature file(s) exist under `
      + `tests/e2e/features but ${bddTestDir} is EMPTY, so the 'bdd' project will run `
      + `ZERO scenarios and this run will look green having tested none of them.\n`
      + `!! Run 'npx bddgen' (or 'make stack-e2e-bdd' / 'make stack-e2e-bdd-check').\n\n`,
    );
  }
}

// Drives the hugmesh.net host (served over the GENERATED TLS cert with
// the GENERATED runtime values) and the federated Matrix/Mastodon/login/admin
// micro-frontends. Run against the rootless integration stack (tests/stack).
export default defineConfig({
  testDir: './specs',
  timeout: 90_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  retries: 1,
  // Reporters. `list` stays for the console; junit + json are the DURABLE
  // artifacts the test-runner Job copies onto the test-reports PVC and the
  // admin-bff TestReportsController serves. The custom hugmesh reporter maps
  // each test -> role via the `role:<x>` annotation/tag convention (see
  // specs/report-tags.ts) and emits summary.json{passed,failed,skipped,perRole[],
  // perLayer[]} PLUS, since schemaVersion 2, the keys a feature tree needs:
  // perSpec[] (pivoted by spec FILE), tests[] (one record per test, with its
  // attachments and - for every skipped test - a skip REASON, never blank), and
  // testTotals/unexplainedSkips. The shape is pinned in
  // reporters/summary.schema.json and gated OFFLINE by
  // `make e2e-reporter-check` (tests/scripts/test-e2e-reporter-shape.sh).
  // Output dir is overridable so the runner can write per-run-id paths on the PVC.
  //   SNAP_REPORT_DIR     base dir for junit/json/summary  (default ./test-results)
  //   SNAP_REPORT_TIER    LEAN|HEAVY                       (recorded in summary.json)
  reporter: [
    ['list'],
    ['junit', { outputFile: `${process.env.SNAP_REPORT_DIR || 'test-results'}/junit.xml` }],
    ['json', { outputFile: `${process.env.SNAP_REPORT_DIR || 'test-results'}/report.json` }],
    ['./reporters/hugmesh-reporter.ts'],
  ],
  outputDir: process.env.SNAP_REPORT_DIR
    ? `${process.env.SNAP_REPORT_DIR}/test-results`
    : 'test-results',
  use: {
    baseURL: process.env.SNAP_BASE_URL || 'https://localhost:8443',
    ignoreHTTPSErrors: true,
    screenshot: 'only-on-failure',
    viewport: { width: 1280, height: 900 },
    launchOptions: {
      args: [
        '--no-sandbox', '--disable-dev-shm-usage',
        // WebRTC fake media so getUserMedia works headless (Matrix video call).
        '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
        // Kind runs address the cluster by its REAL hostname (the fe-gateway
        // Ingress matches on Host), reached via kind-local.yaml's 8443 port
        // map — SNAP_HOST_RESOLVER carries Chromium host-resolver-rules
        // (e.g. 'MAP hugmesh.net 127.0.0.1') so no /etc/hosts edit or
        // sudo is needed. Unset (compose runs) adds nothing.
        ...(process.env.SNAP_HOST_RESOLVER
          ? [`--host-resolver-rules=${process.env.SNAP_HOST_RESOLVER}`]
          : []),
      ],
    },
  },
  projects: [
    // The 33 handwritten TypeScript specs (testDir './specs', set above).
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    // The Gherkin lane. Runs the bddgen output; `npx bddgen` must have run.
    { name: 'bdd', testDir: bddTestDir, use: { ...devices['Desktop Chrome'] } },
  ],
});
