// go-live-refuse.steps.ts — the REAL device driver against a scratch device
// configuration (hugmesh-generator#654, D12: a Tor address needs no public flip).
//
// Every step here runs specs/usr/sbin/hugmesh-go-live exactly as a device would,
// with its GL_ETC_HUGMESH seam pointed at a throwaway folder so nothing can touch
// /etc. The assertions read the FOLDER (is the marker there?) and the driver's
// own `status` readout — never the step's opinion of what the driver should have
// done. The transcript lands in world['cli.transcript'], the same slot
// common.steps.ts uses, so `the command failed` / `the command output contains`
// are REUSED as-is (grepped before writing: no step below restates one).
//
// NOTHING HERE STARTS A MESH, needs tor, or elevates.

import { expect } from '@playwright/test';
// When/Then come from './world' ONLY (a second createBdd() binds to a different
// playwright-bdd instance and the steps never see `world` or the evidence hooks).
import { Given, When, Then } from './world';
import { runCli, REPO_ROOT, scratchDir } from './runners';
import { CliTranscript } from './evidence';
import * as fs from 'node:fs';
import * as path from 'node:path';

const CLI_KEY = 'cli.transcript';     // shared with common.steps.ts, on purpose
const ETC_KEY = 'golive.etc';

const DRIVER = path.join(REPO_ROOT, 'specs', 'usr', 'sbin', 'hugmesh-go-live');
const PROVIDERS = path.join(REPO_ROOT, 'specs', 'usr', 'lib', 'hugmesh', 'go-live-providers.sh');

/** Run the driver against the scratch folder, stdin closed (a non-TTY, as on a device job). */
function drive(etc: string, args: string[]): CliTranscript {
  return runCli(['bash', DRIVER, ...args], {
    cwd: REPO_ROOT,
    env: { GL_ETC_HUGMESH: etc, GL_PROVIDERS_LIB: PROVIDERS },
    input: '',
  });
}

Given('a scratch device configuration folder for the go-live driver with the domain {string}',
  async ({ world }, domain: string) => {
    expect(fs.existsSync(DRIVER), `driver missing: ${DRIVER}`).toBe(true);
    fs.mkdirSync(scratchDir(), { recursive: true });
    const etc = fs.mkdtempSync(path.join(scratchDir(), 'go-live-refuse-'));
    // The baked context a device ships with: its apex, internal, no marker.
    fs.writeFileSync(path.join(etc, 'cluster-domain'), `${domain}\n`);
    fs.writeFileSync(path.join(etc, 'release-state'), 'internal\n');
    world.set(ETC_KEY, etc);
  });

When('I run the go-live driver against it with {string}', async ({ world }, args: string) => {
  const etc = world.get<string>(ETC_KEY);
  world.set(CLI_KEY, drive(etc, args.split(/\s+/).filter(Boolean)));
});

Then('the scratch device configuration holds no go-live marker', async ({ world }) => {
  const etc = world.get<string>(ETC_KEY);
  const marker = path.join(etc, 'go-live');
  expect(fs.existsSync(marker),
    `${marker} exists — the device would open public 80/443 within 60 s:\n`
    + (fs.existsSync(marker) ? fs.readFileSync(marker, 'utf8') : '')).toBe(false);
});

Then('the scratch device configuration holds a go-live marker', async ({ world }) => {
  const etc = world.get<string>(ETC_KEY);
  expect(fs.existsSync(path.join(etc, 'go-live')), `no marker under ${etc}`).toBe(true);
});

Then('the go-live driver reports the posture {string} for it', async ({ world }, want: string) => {
  const etc = world.get<string>(ETC_KEY);
  const t = drive(etc, ['status']);
  const m = /^effective posture:\s+(\S+)/m.exec(t.stdout);
  expect(m, `no 'effective posture:' line in:\n${t.stdout}\n${t.stderr}`).not.toBeNull();
  expect((m as RegExpExecArray)[1], `hugmesh-go-live status for ${etc}`).toBe(want);
});
