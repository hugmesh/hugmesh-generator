import { defineConfig, devices } from '@playwright/test';

/**
 * The screenshot-capture lane. SEPARATE from ../playwright.config.ts on purpose:
 * that config's testDir is ./specs and it wires the BDD project, the junit/json
 * reporters and the hugmesh summary reporter. Capturing screenshots for a manual
 * test plan is not a test result and must not land in a run's summary.json, nor
 * add a project to `npm test`.
 *
 * NO FOURTH COPY OF THE DOOR DEFAULT. playwright.config.ts, steps/dimensions.ts
 * and the Studio's e2e_environments.py already each carry the
 * `https://localhost:8488` fallback, and that duplication has bitten this repo.
 * This config REQUIRES SNAP_BASE_URL and refuses without it; shots.sh is the one
 * place the shots lane resolves a door, and it is what a tester runs.
 */
const baseURL = process.env.SNAP_BASE_URL;
if (!baseURL) {
  throw new Error(
    'SNAP_BASE_URL is unset, so this lane has no door to point at and will not guess one.\n'
    + 'Run the harness the documented way:\n'
    + '  npm run shots -- --persona <persona> --door https://localhost:8488',
  );
}

export default defineConfig({
  testDir: '.',
  testMatch: 'capture.spec.ts',
  timeout: 120_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  // NO RETRIES. A retry would re-take a shot that failed its evidence check and
  // could leave the second attempt's file behind; and a flaky screenshot is a
  // fact a plan author needs to see, not smooth over.
  retries: 0,
  reporter: [['list']],
  outputDir: process.env.SNAP_SHOTS ? `${process.env.SNAP_SHOTS}/.playwright` : 'shots/.playwright',
  use: {
    baseURL,
    ignoreHTTPSErrors: true,          // the local stack serves generated certs
    screenshot: 'off',                // this lane takes its own, deliberately named
    video: 'off',
    trace: 'off',
    viewport: { width: 1280, height: 900 },
    launchOptions: {
      args: [
        '--no-sandbox', '--disable-dev-shm-usage',
        // Kind runs address the cluster by its real hostname; SNAP_HOST_RESOLVER
        // carries the Chromium mapping so no /etc/hosts edit or sudo is needed.
        // Unset (every compose run) adds nothing. Same contract as
        // ../playwright.config.ts.
        ...(process.env.SNAP_HOST_RESOLVER ? [`--host-resolver-rules=${process.env.SNAP_HOST_RESOLVER}`] : []),
      ],
    },
  },
  projects: [{ name: 'shots', use: { ...devices['Desktop Chrome'] } }],
});
