/**
 * settle.ts — wait for a page to actually stop changing before it is
 * photographed. Pure logic, no `test()` calls, so it can be imported both by
 * capture.spec.ts (the live harness) and by settle.spec.ts (an OFFLINE pin
 * that needs no stack, no door, no credential — see that file).
 *
 * #554: the harness used to call shot() the instant a row's awaited testid
 * became visible, which is not the same moment as "the view stopped
 * changing". Two concrete failures that produced:
 *   - a ghosted double frame (entry transition caught mid-fade)
 *   - a half-rendered page (fonts/content not painted yet)
 *
 * waitForSettle() closes both, plus a font swap after paint, by requiring
 * THREE things to all be true before it returns:
 *   1. document.fonts.ready has resolved.
 *   2. Every FINITE animation in document.getAnimations() has reached its
 *      'finished' play state. "Finite" excludes anything whose iteration
 *      count or duration is Infinity.
 *   3. Two viewport screenshots taken `frameGapMs` apart are byte-identical.
 *
 * INFINITE ANIMATIONS. The host shell runs a decorative background animation
 * with no end (iterations: Infinity) — #554 says explicitly to ignore it.
 * Condition 3 cannot just "ignore" it by name (this module never sees the
 * shell's CSS), so instead: once conditions 1-2 hold, every currently
 * RUNNING infinite animation is PAUSED before the frame comparison. That
 * makes condition 3 an honest test of "has everything that is ever going to
 * stop, stopped" rather than a comparison quietly rigged to exclude whatever
 * loops forever. The caller is expected to take its real screenshot while
 * still paused (this is what #554 means by "pausing ... for the shot"), then
 * call resumeFrozenAnimations() to put the page back the way it found it —
 * a decorative loop losing the few hundred ms it spent paused is imperceptible;
 * a row's actual, finite content is never touched by this, only loops that
 * were never going to finish on their own.
 *
 * FAILS LOUDLY. A page that never satisfies all three within `timeoutMs`
 * throws, naming which condition it was still waiting on. It never returns
 * silently, so a caller can never end up photographing an unsettled frame.
 */
import type { Page } from '@playwright/test';

export interface SettleOptions {
  /** Total time budget for the whole sequence (fonts + finite animations +
   *  frame-stability). Default 15s per #554's suggestion. */
  timeoutMs?: number;
  /** Spacing between the two frames compared for stability. Default 300ms. */
  frameGapMs?: number;
}

const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_FRAME_GAP_MS = 300;

// Stashed on `window` between two separate page.evaluate() calls (freeze in
// waitForSettle, resume in resumeFrozenAnimations) — a JS Animation object
// cannot cross the Node/browser boundary as a return value, but the SAME
// browser-context global is visible to both evaluate() calls.
const FREEZE_KEY = '__hugmeshSettleFrozenAnimations__';

async function raceTimeout<T>(p: Promise<T>, ms: number): Promise<T | 'timeout'> {
  return Promise.race([
    p,
    new Promise<'timeout'>((resolve) => { setTimeout(() => resolve('timeout'), ms); }),
  ]);
}

/**
 * Wait until `page` has settled (see module doc), then freeze any running
 * infinite animation so the caller's next screenshot is deterministic.
 * `label` names the row/case in any thrown error. The caller MUST call
 * `resumeFrozenAnimations(page)` afterwards (normally right after its own
 * screenshot) to undo the freeze.
 */
export async function waitForSettle(page: Page, label: string, opts: SettleOptions = {}): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const frameGapMs = opts.frameGapMs ?? DEFAULT_FRAME_GAP_MS;
  const deadline = Date.now() + timeoutMs;
  const remaining = () => Math.max(0, deadline - Date.now());

  // 1. Fonts.
  const fontsReady = await raceTimeout(
    page.evaluate(() => document.fonts.ready.then(() => true as const)),
    remaining(),
  );
  if (fontsReady !== true) {
    throw new Error(`${label}: settle timed out after ${timeoutMs}ms waiting for document.fonts.ready`);
  }

  // 2. Every finite animation finished (infinite ones ignored by definition).
  const finiteDone = await raceTimeout(
    page.evaluate(() => Promise.all(
      document.getAnimations()
        .filter((a) => {
          const t = a.effect?.getTiming?.();
          return !(t?.iterations === Infinity || t?.duration === Infinity);
        })
        .map((a) => a.finished.catch(() => undefined)),
    ).then(() => true as const)),
    remaining(),
  );
  if (finiteDone !== true) {
    throw new Error(
      `${label}: settle timed out after ${timeoutMs}ms waiting for finite animations `
      + '(document.getAnimations(), excluding any with iterations/duration Infinity) to finish',
    );
  }

  // 3. Freeze whatever infinite animation is still running so it cannot make
  //    step 4 — or the real shot the caller is about to take — unstable
  //    purely by looping forever.
  await page.evaluate((key) => {
    const infinite = document.getAnimations().filter((a) => {
      const t = a.effect?.getTiming?.();
      return t?.iterations === Infinity || t?.duration === Infinity;
    }).filter((a) => a.playState === 'running');
    (window as unknown as Record<string, Animation[]>)[key] = infinite;
    for (const a of infinite) a.pause();
  }, FREEZE_KEY);

  // 4. Two consecutive viewport frames byte-identical.
  let prev = await page.screenshot();
  let stable = false;
  while (Date.now() < deadline) {
    await page.waitForTimeout(frameGapMs);
    const next = await page.screenshot();
    if (Buffer.compare(prev, next) === 0) { stable = true; break; }
    prev = next;
  }
  if (!stable) {
    await resumeFrozenAnimations(page).catch(() => { /* best effort on the way out */ });
    throw new Error(
      `${label}: settle timed out after ${timeoutMs}ms — two consecutive viewport screenshots `
      + `${frameGapMs}ms apart never matched (the view never stopped changing)`,
    );
  }
}

/** Undo the freeze waitForSettle() applied. Safe to call even if nothing was frozen. */
export async function resumeFrozenAnimations(page: Page): Promise<void> {
  await page.evaluate((key) => {
    const store = window as unknown as Record<string, Animation[] | undefined>;
    const frozen = store[key];
    if (frozen) {
      for (const a of frozen) {
        try { a.play(); } catch { /* page may have navigated away; nothing to resume */ }
      }
    }
    delete store[key];
  }, FREEZE_KEY);
}
