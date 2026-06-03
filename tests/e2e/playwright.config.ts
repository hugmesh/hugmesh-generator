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
  reporter: [['list']],
  outputDir: 'test-results',
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
