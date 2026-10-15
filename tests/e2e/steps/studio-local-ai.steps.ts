// studio-local-ai.steps.ts — the Studio's Local AI dock, driven end to end offscreen.
//
// One When runs tests/e2e/studio-local-ai-driver.py, which opens a REAL Studio window
// through StudioShell.open_window (the call that mounts the dock), presses Start local
// assistant, asks the model a question and presses Clear mid-answer, grabbing the window
// after each act. The Thens read ONLY what the driver reported about the live widgets.
//
// PINNED world KEYS this file owns:
//   world['studio.localai']  the driver's JSON report
//   world['studio.grab']     the LAST grab (shared key: 'the Studio grab is a non-empty
//                            PNG' in common.steps.ts reads it)
import { expect } from '@playwright/test';
import { When, Then } from './world';
import { runCli, REPO_ROOT } from './runners';
import { StudioGrab, recordStudio, runDir } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as path from 'node:path';

const REPORT_KEY = 'studio.localai';
const STUDIO_KEY = 'studio.grab';

interface DockReport {
  ok: boolean;
  binding: string;
  png?: string;
  grabs: { name: string; png: string }[];
  errors: string[];
  modal: string | null;
  standInStartScript: string;
  model: string;
  width?: number;
  height?: number;
  dock?: {
    visible: boolean; expanded: boolean; insideWindow: boolean; bottomStrip: boolean;
    coversAWizardButton: boolean; summary: string; barHeight: number; startButton: string;
    startButtonHeight: number; workButton: string; page: string; promptHeight?: number;
    promptVisible?: boolean;
  };
  start?: {
    buttonSaidWhilePending: string; scriptRan: boolean; args: string | null;
    ollamaHostSeenByScript: string | null; ownSession: boolean; note: string;
    startLogWritten: boolean; workWindowOpened: boolean;
  };
  faces?: {
    modelSetting: string; loaded: string[]; cliExit: number; cliAnswer: string;
    cliStderr: string; cliModelAsked: string | null;
  };
  prompt?: {
    text: string; enter: string; promptClearedOnSend: boolean;
    wizardBeforeEnter: { id: number; title: string; page: string };
    wizardAfterEnter: { id: number; title: string; page: string };
    sendButtonWhileBusy: string;
    busy: boolean; streamedBeforeClear: boolean; answerBeforeClear: string;
    requestsToModel: string[]; modelAsked: string | null;
  };
  clear?: {
    pressedWhileBusy: boolean; answerRightAfter: string; answerAfterTheModelFinished: string;
    historyAfter: number; sendButtonAfter: string; promptEnabled: boolean;
  };
  escape?: {
    how: string; promptAfter: string; windowRejected: boolean; windowVisible: boolean;
    promptHasFocus: boolean; page: string;
  };
  answerArea?: {
    how: string; answerHadFocus: boolean; answerAfter: string;
    keys: Record<string, {
      wizardBefore: { id: number; title: string; page: string };
      wizardAfter: { id: number; title: string; page: string } | null;
      windowRejected: boolean; windowVisible: boolean;
    }>;
  };
}

function driverPath(): string {
  return path.resolve(__dirname, '..', 'studio-local-ai-driver.py');
}

function report(world: { get<T>(k: string): T }): DockReport {
  return world.get<DockReport>(REPORT_KEY);
}

When('I open the Studio and drive its Local AI dock through Start, a prompt and Clear',
  async ({ world }) => {
    const grabDir = path.join(runDir(), '.driver-tmp', `local-ai-${process.pid}-${Date.now()}`);
    fs.mkdirSync(grabDir, { recursive: true });
    const t = runCli(
      [studioPython(), driverPath(), '--generator-dir', REPO_ROOT, '--grab-dir', grabDir],
      { cwd: REPO_ROOT, timeoutMs: 240_000, env: { QT_QPA_PLATFORM: 'offscreen' } },
    );
    let parsed: DockReport;
    const last = t.stdout.trim().split('\n').filter(Boolean).pop() ?? '';
    try {
      parsed = JSON.parse(last) as DockReport;
    } catch {
      throw new Error(
        `the Local AI dock driver did not end with a JSON report. Last stdout line:\n  ${last.slice(0, 400)}\n`
        + `--- driver stderr ---\n${t.stderr.slice(0, 3000)}`,
      );
    }
    world.set(REPORT_KEY, parsed);
    let lastGrab: StudioGrab | undefined;
    for (const g of parsed.grabs ?? []) {
      const grab: StudioGrab = {
        pngPath: g.png, page: `local-ai-dock/${g.name}`, binding: parsed.binding ?? 'unknown',
        width: parsed.width ?? -1, height: parsed.height ?? -1, transcript: t,
      };
      recordStudio(grab);
      lastGrab = grab;
    }
    if (lastGrab) world.set(STUDIO_KEY, lastGrab);
    expect(parsed.errors ?? [], `the driver reported errors. stderr:\n${t.stderr.slice(0, 3000)}`)
      .toEqual([]);
  });

Then('the Local AI dock is on the page, inside the window, clear of the wizard buttons',
  async ({ world }) => {
    const d = report(world).dock;
    expect(d, 'the driver reported no dock').toBeTruthy();
    expect(d!.visible).toBe(true);
    expect(d!.insideWindow).toBe(true);
    expect(d!.bottomStrip, 'the dock is not the window\'s bottom strip').toBe(true);
    expect(d!.coversAWizardButton, 'the dock covers Back/Next/Cancel').toBe(false);
    expect(d!.startButton).toBe('Start local assistant');
    expect(d!.workButton).toBe('Current work');
    expect(d!.startButtonHeight).toBeGreaterThanOrEqual(26);
    expect(d!.promptVisible).toBe(true);
    expect(d!.promptHeight ?? 0).toBeGreaterThanOrEqual(26);
  });

Then('the dock\'s status line counts the queued work read from the local-AI state folder',
  async ({ world }) => {
    const d = report(world).dock!;
    expect(d.summary).toMatch(/^Local AI: ready, qwen3:8b loaded/);
    expect(d.summary).toContain('1 queued');
  });

Then('pressing Start local assistant ran the local-ai start command detached and said so inline',
  async ({ world }) => {
    const s = report(world).start;
    expect(s, 'the driver reported no start act').toBeTruthy();
    expect(s!.buttonSaidWhilePending).toBe('Starting…');
    expect(s!.scriptRan, 'the start command never ran').toBe(true);
    expect(s!.args).toBe('start');
    expect(s!.ownSession, 'the start command shares the Studio\'s session (not detached)').toBe(true);
    expect(s!.startLogWritten).toBe(true);
    expect(s!.note).toContain('Starting the local assistant');
    expect(s!.workWindowOpened, 'a successful start opened the work window uninvited').toBe(false);
  });

Then('the question went to the loopback model only and its answer streamed into the dock',
  async ({ world }) => {
    const r = report(world);
    const p = r.prompt!;
    expect(p.promptClearedOnSend).toBe(true);
    expect(p.sendButtonWhileBusy).toBe('Stop');
    expect(p.streamedBeforeClear, 'no piece of the answer arrived').toBe(true);
    expect(p.answerBeforeClear).toContain(`You: ${p.text}`);
    expect(p.answerBeforeClear).toContain('The dock talks');
    expect(p.requestsToModel).toEqual(['/api/chat']);
    expect(r.model).toMatch(/^127\.0\.0\.1:\d+$/);
  });

Then('pressing Enter in the prompt did not move the wizard off its page', async ({ world }) => {
  const p = report(world).prompt!;
  // the driver pressed a real key (a QKeyEvent), not the signal: only a key can travel
  // on to the wizard, so only a key can show the defect this step is about
  expect(p.enter, 'Enter was not delivered as a key event').toMatch(/^QKeyEvent/);
  expect(p.wizardBeforeEnter, 'the driver did not read the page before Enter').toBeTruthy();
  expect(p.wizardAfterEnter,
    `Enter in the prompt moved the wizard from "${p.wizardBeforeEnter.title}" to "${p.wizardAfterEnter?.title}"`)
    .toEqual(p.wizardBeforeEnter);
});

Then('Escape in the prompt cleared a half-typed question and did not close the Studio window',
  async ({ world }) => {
    const e = report(world).escape;
    expect(e, 'the driver did not press Escape in the prompt').toBeTruthy();
    // a real key, not a call to clear(): only a key can travel on to the wizard, and the
    // wizard is a QDialog, which closes itself on an Escape nobody claimed
    expect(e!.how, 'Escape was not delivered as a key event').toMatch(/^QKeyEvent/);
    expect(e!.promptAfter, 'Escape left the half-typed question in the prompt').toBe('');
    expect(e!.windowRejected, 'Escape in the prompt closed the Studio window').toBe(false);
    expect(e!.windowVisible).toBe(true);
    expect(e!.promptHasFocus, 'the prompt lost the focus on Escape').toBe(true);
  });

Then('Enter and Escape with the focus in the answer area moved no page and closed no window',
  async ({ world }) => {
    const a = report(world).answerArea;
    expect(a, 'the driver did not press keys in the answer area').toBeTruthy();
    // the answer area is where a person clicks to copy the model's words; a key it does
    // not keep travels on to the wizard, a QDialog: Enter presses Next, Escape closes it
    expect(a!.how).toMatch(/^QKeyEvent/);
    expect(a!.answerHadFocus, 'the answer area never took the focus: nothing was tested').toBe(true);
    for (const name of ['Return', 'Escape']) {
      const k = a!.keys[name];
      expect(k, `the driver did not press ${name} in the answer area`).toBeTruthy();
      expect(k.wizardAfter,
        `${name} in the answer area moved the wizard from "${k.wizardBefore.title}" to "${k.wizardAfter?.title}"`)
        .toEqual(k.wizardBefore);
      expect(k.windowRejected, `${name} in the answer area closed the Studio window`).toBe(false);
      expect(k.windowVisible).toBe(true);
    }
    expect(a!.answerAfter).toContain('an answer the person wants to copy');
  });

Then('the dock asked the model named by LOCAL_AI_MODEL, the same one the command line asks',
  async ({ world }) => {
    const r = report(world);
    const f = r.faces;
    expect(f, 'the driver did not ask the command line first').toBeTruthy();
    expect(f!.cliExit, `--local-ai-prompt failed: ${f!.cliStderr}`).toBe(0);
    expect(f!.cliAnswer).toBe('Hello there');
    // the setting names a pulled model that is NOT the loaded one, so a face that
    // preferred the loaded model would show up here as a different name
    expect(f!.loaded).not.toContain(f!.modelSetting);
    expect(f!.cliModelAsked).toBe(f!.modelSetting);
    expect(r.prompt!.modelAsked, 'the dock asked a different model than the command line')
      .toBe(f!.cliModelAsked);
  });

Then('Clear pressed mid-answer left the answer area empty and the conversation forgotten',
  async ({ world }) => {
    const c = report(world).clear!;
    expect(c.pressedWhileBusy, 'Clear was not pressed while the answer was arriving').toBe(true);
    expect(c.answerRightAfter).toBe('');
    expect(c.answerAfterTheModelFinished, 'late pieces of the cleared answer came back').toBe('');
    expect(c.historyAfter).toBe(0);
    expect(c.sendButtonAfter).toBe('Send');
    expect(c.promptEnabled).toBe(true);
  });

Then('the Local AI dock opened no modal dialog', async ({ world }) => {
  expect(report(world).modal).toBeNull();
});

Then('a grab exists for each act of the Local AI dock scenario', async ({ world }) => {
  const r = report(world);
  const names = r.grabs.map((g) => g.name);
  expect(names).toEqual(['1-opened-collapsed', '2-expanded', '3-started', '3a-escape-cleared-the-prompt',
    '3b-keys-in-the-answer-area', '4-answer-streaming', '5-after-clear']);
  for (const g of r.grabs) {
    expect(fs.statSync(g.png).size, `${g.png} is empty`).toBeGreaterThan(0);
  }
});
