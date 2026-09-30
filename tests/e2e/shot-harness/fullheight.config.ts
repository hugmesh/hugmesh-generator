import { defineConfig, devices } from '@playwright/test';

/**
 * Config for fullheight.spec.ts ONLY — the offline pin for the full-height
 * capture fix (operator report, 2026-09-18: "screenshots have broken
 * background"). Mirrors settle.config.ts's reasoning and is deliberately its
 * own file rather than widening settle.config.ts's testMatch, so this lane's
 * changes never touch a file another concurrent lane could also be editing.
 *
 *   - ../playwright.config.ts:  testDir is ./specs, so it never sees this file.
 *   - ./shots.config.ts:        throws at IMPORT time when SNAP_BASE_URL is
 *                                unset, which this lane has no reason to set —
 *                                page.setContent() builds the fixture entirely
 *                                in-browser, no door, no stack, no credential.
 *   - ./settle.config.ts:       testMatch is 'settle.spec.ts' only.
 */
export default defineConfig({
  testDir: '.',
  testMatch: 'fullheight.spec.ts',
  timeout: 20_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    // The fixture sets its own viewport per-test (it must know the exact
    // pre-grow size to assert restoreViewport() puts it back), so this is
    // just a sane default.
    viewport: { width: 400, height: 300 },
    launchOptions: { args: ['--no-sandbox', '--disable-dev-shm-usage'] },
  },
  projects: [{ name: 'fullheight-unit', use: { ...devices['Desktop Chrome'] } }],
});
