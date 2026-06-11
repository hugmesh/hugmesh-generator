import { defineConfig, devices } from '@playwright/test';

// Drives the snapdragon.systems host (served over the GENERATED TLS cert with
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
  // admin-bff TestReportsController serves. The custom snapdragon reporter maps
  // each test -> role via the `role:<x>` annotation/tag convention (see
  // specs/report-tags.ts) and emits summary.json{passed,failed,skipped,perRole[]}.
  // Output dir is overridable so the runner can write per-run-id paths on the PVC.
  //   SNAP_REPORT_DIR     base dir for junit/json/summary  (default ./test-results)
  //   SNAP_REPORT_TIER    LEAN|HEAVY                       (recorded in summary.json)
  reporter: [
    ['list'],
    ['junit', { outputFile: `${process.env.SNAP_REPORT_DIR || 'test-results'}/junit.xml` }],
    ['json', { outputFile: `${process.env.SNAP_REPORT_DIR || 'test-results'}/report.json` }],
    ['./reporters/snapdragon-reporter.ts'],
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
      ],
    },
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
