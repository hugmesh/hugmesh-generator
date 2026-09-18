import { defineConfig, devices } from '@playwright/test';

/**
 * Config for settle.spec.ts ONLY — the offline pin for #554's settle logic.
 * Deliberately separate from both other configs in this repo:
 *   - ../playwright.config.ts:  testDir is ./specs, so it never sees this file.
 *   - ./shots.config.ts:        throws at IMPORT time when SNAP_BASE_URL is
 *                                unset, which this lane has no reason to set —
 *                                page.setContent() builds the page entirely
 *                                in-browser, no door, no stack, no credential.
 */
export default defineConfig({
  testDir: '.',
  testMatch: 'settle.spec.ts',
  timeout: 20_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    viewport: { width: 400, height: 300 },
    launchOptions: { args: ['--no-sandbox', '--disable-dev-shm-usage'] },
  },
  projects: [{ name: 'settle-unit', use: { ...devices['Desktop Chrome'] } }],
});
