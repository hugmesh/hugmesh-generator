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
 * MASKED LIVE REGIONS (#563). A view can legitimately contain a region that
 * repaints forever without the Web Animations API (a <canvas> or a
 * requestAnimationFrame loop — the Character Forge's engine area). Freezing
 * cannot stop that, so condition 3 could never hold. A row may declare
 * `mask: [selector, ...]`: those elements' bounding boxes are painted over
 * (Playwright's screenshot `mask`) in the frames COMPARED for condition 3.
 * That is deliberately narrower than an opt-out:
 *   - conditions 1 and 2 (fonts, finite animations) still cover the WHOLE page;
 *   - condition 3 still compares every pixel OUTSIDE the masked boxes, so
 *     movement anywhere else still fails the row;
 *   - a selector that matches nothing masks nothing (the comparison stays
 *     whole), and an empty selector is an error rather than "mask everything";
 *   - masked boxes may cover at most MAX_MASK_FRACTION of the viewport, so a
 *     selector like `body` cannot quietly turn the check off.
 * Only the comparison is masked: the shot the caller takes afterwards still
 * contains the live region as it happens to be painted.
 *
 * FAILS LOUDLY. A page that never satisfies all three within `timeoutMs`
 * throws, naming which condition it was still waiting on. It never returns
 * silently, so a caller can never end up photographing an unsettled frame.
 */
import type { Locator, Page } from '@playwright/test';

export interface SettleOptions {
  /** Total time budget for the whole sequence (fonts + finite animations +
   *  frame-stability). Default 15s per #554's suggestion. */
  timeoutMs?: number;
  /** Spacing between the two frames compared for stability. Default 300ms. */
  frameGapMs?: number;
  /** CSS selectors of live regions (canvas / rAF loops) to paint over in the
   *  frames compared for stability. See "MASKED LIVE REGIONS" above. Empty or
   *  omitted means the whole viewport is compared. */
  mask?: string[];
}

const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_FRAME_GAP_MS = 300;
/** Masked boxes together may cover at most this share of the viewport; past it
 *  the mask is no longer "a live region" but a way to skip the comparison. */
export const MAX_MASK_FRACTION = 0.5;

// Stashed on `window` between two separate page.evaluate() calls (freeze in
// waitForSettle, resume in resumeFrozenAnimations) — a JS Animation object
// cannot cross the Node/browser boundary as a return value, but the SAME
// browser-context global is visible to both evaluate() calls.
const FREEZE_KEY = '__hugmeshSettleFrozenAnimations__';

/**
 * Resolve the row's mask selectors to Locators, refusing the shapes that would
 * turn the frame comparison into a no-op. Returns [] when there is nothing to
 * mask (no selectors, or none of them matches an element right now).
 */
async function resolveMask(page: Page, label: string, selectors: string[] | undefined): Promise<Locator[]> {
  if (!selectors || selectors.length === 0) return [];
  const locators: Locator[] = [];
  let covered = 0;
  for (const sel of selectors) {
    if (typeof sel !== 'string' || sel.trim() === '') {
      throw new Error(`${label}: settle mask selector ${JSON.stringify(sel)} is empty — name the live region to mask`);
    }
    const loc = page.locator(sel);
    locators.push(loc);
    for (const el of await loc.all()) {
      const box = await el.boundingBox();
      if (box) covered += box.width * box.height;
    }
  }
  const vp = page.viewportSize();
  if (vp && covered > MAX_MASK_FRACTION * vp.width * vp.height) {
    throw new Error(
      `${label}: settle mask ${JSON.stringify(selectors)} covers more than ${Math.round(MAX_MASK_FRACTION * 100)}% of the `
      + 'viewport — a mask names one live region, it must not hide the view being compared',
    );
  }
  return locators;
}

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

  // 4. Two consecutive viewport frames byte-identical (outside any masked
  //    live region). Resolved after the freeze so the boxes are final-ish; a
  //    bad mask throws here, after the page is put back the way it was found.
  let mask: Locator[];
  try {
    mask = await resolveMask(page, label, opts.mask);
  } catch (e) {
    await resumeFrozenAnimations(page).catch(() => { /* best effort on the way out */ });
    throw e;
  }
  const frame = () => page.screenshot(mask.length ? { mask } : {});
  let prev = await frame();
  let stable = false;
  while (Date.now() < deadline) {
    await page.waitForTimeout(frameGapMs);
    const next = await frame();
    if (Buffer.compare(prev, next) === 0) { stable = true; break; }
    prev = next;
  }
  if (!stable) {
    await resumeFrozenAnimations(page).catch(() => { /* best effort on the way out */ });
    throw new Error(
      `${label}: settle timed out after ${timeoutMs}ms — two consecutive viewport screenshots `
      + `${frameGapMs}ms apart never matched (the view never stopped changing`
      + `${mask.length ? ` outside the masked region${mask.length > 1 ? 's' : ''} ${JSON.stringify(opts.mask)}` : ''})`,
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

// ── full-height capture (operator report, 2026-09-18) ───────────────────────
//
// The host shell's background layer is `position: fixed` and sized to the
// VIEWPORT (100vh), not the document. `shot()` (specs/helpers.ts) captures
// with `fullPage: true`, which grows the rendered PAGE for the screenshot but
// does not change the fixed layer's own height — Chromium keeps it pinned to
// one viewport's worth of pixels. On any row taller than the viewport, the
// PNG below that first viewport-height shows the bare body colour instead of
// the background. In a real browser this is invisible (the fixed layer
// visually follows scroll); it is purely a `fullPage` screenshot artifact.
//
// growToFullHeight() grows the viewport's HEIGHT (width unchanged) to the
// document's full scroll height before the shot, so a `100vh` element
// recomputes against a viewport that already covers the whole page — no
// "grow the fixed layer" special-casing needed, because there is no longer a
// gap for it to fall short of. restoreViewport() puts the original size back
// afterwards so later rows in the same run are unaffected.

export interface FullHeightOptions {
  /** Hard cap on the grown viewport height, in px. Default 12,000. */
  maxHeightPx?: number;
}

const DEFAULT_MAX_HEIGHT_PX = 12_000;

/**
 * Grow `page`'s viewport height to the document's full scroll height (width
 * unchanged), capped at `maxHeightPx`, and let layout reflow so any
 * `100vh`-sized element (e.g. a fixed background) recomputes against the new
 * viewport before anything is measured or shot. Returns the viewport size in
 * effect before the call, to hand to `restoreViewport()` afterwards.
 *
 * A no-op (returns the current size, does not resize) when the document is
 * already no taller than the current viewport.
 */
export async function growToFullHeight(
  page: Page,
  label: string,
  opts: FullHeightOptions = {},
): Promise<{ width: number; height: number }> {
  const maxHeightPx = opts.maxHeightPx ?? DEFAULT_MAX_HEIGHT_PX;
  const original = page.viewportSize();
  if (!original) throw new Error(`${label}: growToFullHeight needs a page with a set viewport`);

  const scrollHeight = await page.evaluate(() => Math.max(
    document.documentElement.scrollHeight,
    document.body ? document.body.scrollHeight : 0,
  ));

  if (scrollHeight <= original.height) return original;

  let targetHeight = scrollHeight;
  if (targetHeight > maxHeightPx) {
    // eslint-disable-next-line no-console
    console.warn(
      `${label}: full-page height ${targetHeight}px exceeds the ${maxHeightPx}px cap for growToFullHeight — `
      + `capping at ${maxHeightPx}px`,
    );
    targetHeight = maxHeightPx;
  }

  await page.setViewportSize({ width: original.width, height: targetHeight });
  // Two rAFs: one for the resize's layout to land, one for anything (e.g. a
  // fixed 100vh background) that reads the new size on the frame after that.
  await page.evaluate(() => new Promise<void>((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  }));

  return original;
}

/** Undo growToFullHeight(): restore the viewport so later rows are unaffected. */
export async function restoreViewport(page: Page, size: { width: number; height: number }): Promise<void> {
  await page.setViewportSize(size);
}
