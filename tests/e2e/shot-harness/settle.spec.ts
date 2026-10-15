/**
 * settle.spec.ts — the OFFLINE pin for #554's settle logic.
 *
 * Runs entirely against `page.setContent()` fixtures built in this file; it
 * needs no door, no credential and no compose stack. Run it with:
 *
 *   npx playwright test -c shot-harness/settle.config.ts
 *   (or: npm run shots:settle-unit)
 *
 * WHY THIS PINS #554. Each fixture below reproduces, in miniature, one of the
 * two failures the issue measured against the live stack: a finite entry
 * transition caught mid-fade, and a decorative infinite loop that must not
 * block settling forever. If waitForSettle() is gutted back to a no-op (the
 * settle step "removed"), the FIRST test goes red: the assertion checks a
 * property (opacity reaching 1) that provably is NOT yet true the instant
 * setContent() resolves (proven by the sanity test right above it), so a
 * function that does not actually wait leaves it caught mid-transition.
 *
 * #563 adds the `mask` option (a live region excluded from the frame
 * comparison) and its cases at the bottom of this file. Their fixtures put a
 * <canvas> that is repainted every animation frame next to a settled region,
 * which is the Character Forge's shape: no Web Animations API, so freezing
 * cannot stop it and two identical frames can never happen on their own.
 */
import { test, expect } from '@playwright/test';
import { waitForSettle, resumeFrozenAnimations } from './settle';

/**
 * A minimal page with two independent animations:
 *  - #box fades in over 900ms via a CSS transition (FINITE) started a couple
 *    of frames after load, standing in for the shell's real entry fade.
 *  - #bg runs forever via a CSS @keyframes animation (INFINITE), standing in
 *    for the shell's decorative background loop #554 says to ignore.
 */
const FIXTURE_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><style>
  html, body { margin: 0; }
  #bg {
    position: fixed; inset: 0;
    background: linear-gradient(90deg, #111, #eee, #111);
    background-size: 400% 100%;
    animation: slide 1.4s linear infinite;
  }
  @keyframes slide { from { background-position: 0% 0; } to { background-position: 100% 0; } }
  #box {
    position: relative; width: 120px; height: 80px; margin: 20px;
    background: #2a6; opacity: 0;
    transition: opacity 900ms linear;
  }
  #box.go { opacity: 1; }
</style></head>
<body>
  <div id="bg"></div>
  <div id="box"></div>
  <script>
    // Two rAFs, like a framework applying a class post-render rather than
    // inline in the initial markup — mirrors a real "entry transition".
    requestAnimationFrame(() => requestAnimationFrame(() => {
      document.getElementById('box').classList.add('go');
    }));
  </script>
</body></html>`;

async function boxOpacity(page: import('@playwright/test').Page): Promise<string> {
  return page.evaluate(() => getComputedStyle(document.getElementById('box')!).opacity);
}

test('sanity: the fixture is genuinely mid-transition right after load (so the next test can actually fail)', async ({ page }) => {
  await page.setContent(FIXTURE_HTML);
  // No wait at all — this is the harness's OLD behaviour (shoot the instant
  // the DOM exists). #554's whole premise is that this is not settled yet.
  const opacity = await boxOpacity(page);
  expect(opacity).not.toBe('1');
});

test('waitForSettle blocks until the finite transition has actually finished', async ({ page }) => {
  await page.setContent(FIXTURE_HTML);
  await waitForSettle(page, 'fixture-transition');
  expect(await boxOpacity(page)).toBe('1');
  await resumeFrozenAnimations(page);
});

test('waitForSettle freezes the infinite animation rather than waiting on it forever, and resumeFrozenAnimations restores it', async ({ page }) => {
  await page.setContent(FIXTURE_HTML);
  await waitForSettle(page, 'fixture-infinite-bg', { timeoutMs: 5_000 });
  // Settled: the infinite #bg loop must be paused, not still running.
  const pausedState = await page.evaluate(
    () => document.getAnimations().find((a) => a.effect?.getTiming?.().iterations === Infinity)?.playState,
  );
  expect(pausedState).toBe('paused');

  await resumeFrozenAnimations(page);
  const resumedState = await page.evaluate(
    () => document.getAnimations().find((a) => a.effect?.getTiming?.().iterations === Infinity)?.playState,
  );
  expect(resumedState).toBe('running');
});

test('waitForSettle fails loudly, inside its budget, on a view that never stops changing', async ({ page }) => {
  // No CSS animation at all — a setInterval mutates layout forever, so
  // document.getAnimations() is empty (steps 1-2 pass instantly) but the
  // frame-identity check (step 4) can never converge. This is the "half
  // rendered forever" / non-animation-API case #554's Done-when also covers
  // ("A row that never settles must FAIL with a clear message").
  await page.setContent(`<!doctype html><html><body><div id="t">0</div>
    <script>setInterval(() => { document.getElementById('t').textContent = String(Math.random()); }, 60); </script>
    </body></html>`);
  const budgetMs = 800;
  const started = Date.now();
  await expect(waitForSettle(page, 'fixture-never-settles', { timeoutMs: budgetMs, frameGapMs: 100 }))
    .rejects.toThrow(/fixture-never-settles.*timed out.*never matched/s);
  const elapsed = Date.now() - started;
  // Bounded: it must not hang past roughly its own budget.
  expect(elapsed).toBeLessThan(budgetMs + 3_000);
});

// ── #563: a live canvas next to a settled region ─────────────────────────────

/** A canvas repainted with random colour on every animation frame (no Web
 *  Animations API, so nothing can freeze it), a static text box, and a moving
 *  region that is NOT a canvas (#other, text rewritten on a timer). */
const LIVE_CANVAS_HTML = (opts: { otherMoves?: boolean; fade?: boolean } = {}) => `<!doctype html>
<html><head><meta charset="utf-8"><style>
  html, body { margin: 0; font: 16px sans-serif; }
  body { min-height: 100vh; }   /* the children are absolute: without this body/html have no box to mask */
  #live { position: absolute; left: 10px; top: 10px; width: 120px; height: 80px; }
  #settled { position: absolute; left: 10px; top: 120px; width: 200px; height: 40px; background: #36c; color: #fff; }
  #other { position: absolute; left: 10px; top: 180px; width: 200px; height: 30px; background: #eee; }
  #box { position: absolute; left: 220px; top: 120px; width: 60px; height: 40px; background: #2a6; opacity: 0;
         transition: opacity 600ms linear; }
  #box.go { opacity: 1; }
</style></head>
<body>
  <canvas id="live" width="120" height="80"></canvas>
  <div id="settled">settled</div>
  <div id="other">still</div>
  <div id="box"></div>
  <script>
    window.__draws = 0;
    const ctx = document.getElementById('live').getContext('2d');
    (function paint() {
      ctx.fillStyle = 'rgb(' + [0, 0, 0].map(() => Math.floor(Math.random() * 256)).join(',') + ')';
      ctx.fillRect(0, 0, 120, 80);
      window.__draws++;
      requestAnimationFrame(paint);
    })();
    ${opts.otherMoves ? "setInterval(() => { document.getElementById('other').textContent = String(Math.random()); }, 40);" : ''}
    ${opts.fade ? "requestAnimationFrame(() => requestAnimationFrame(() => document.getElementById('box').classList.add('go')));" : ''}
  </script>
</body></html>`;

const LIVE = '#live';
const BUDGET = { timeoutMs: 1_500, frameGapMs: 100 };
const NEVER = /timed out.*never matched/s;

test('without a mask, a constantly redrawing canvas can never settle (the #563 defect)', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await expect(waitForSettle(page, 'canvas-unmasked', BUDGET)).rejects.toThrow(NEVER);
});

test('masking the canvas settles the row, and the comparison is still real outside it', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await waitForSettle(page, 'canvas-masked', { ...BUDGET, mask: [LIVE] });
  await resumeFrozenAnimations(page);
});

test('the mask only hides the comparison: the canvas is still live and still in the real shot', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await waitForSettle(page, 'canvas-still-live', { ...BUDGET, mask: [LIVE] });
  const before = await page.evaluate(() => (window as unknown as { __draws: number }).__draws);
  await page.waitForTimeout(250);
  const after = await page.evaluate(() => (window as unknown as { __draws: number }).__draws);
  expect(after).toBeGreaterThan(before);
  await resumeFrozenAnimations(page);
});

test('a mask over the canvas does not hide movement in another (non-canvas) region', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML({ otherMoves: true }));
  await expect(waitForSettle(page, 'canvas-masked-other-moves', { ...BUDGET, mask: [LIVE] }))
    .rejects.toThrow(/canvas-masked-other-moves.*never matched.*outside the masked region/s);
});

test('masking the moving non-canvas region does not excuse the canvas that is not masked', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML({ otherMoves: true }));
  await expect(waitForSettle(page, 'other-masked-canvas-live', { ...BUDGET, mask: ['#other'] }))
    .rejects.toThrow(NEVER);
});

test('masking both live regions settles (the mask is per selector, not per kind of element)', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML({ otherMoves: true }));
  await waitForSettle(page, 'both-masked', { ...BUDGET, mask: [LIVE, '#other'] });
  await resumeFrozenAnimations(page);
});

test('a mask selector that matches nothing masks nothing: the live canvas still fails the row', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await expect(waitForSettle(page, 'mask-matches-nothing', { ...BUDGET, mask: ['#no-such-element'] }))
    .rejects.toThrow(NEVER);
});

test('an empty mask list is the whole-view comparison, not an opt-out', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await expect(waitForSettle(page, 'empty-mask-list', { ...BUDGET, mask: [] })).rejects.toThrow(NEVER);
});

test('an empty mask selector is an error, not "mask everything"', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await expect(waitForSettle(page, 'blank-selector', { ...BUDGET, mask: ['  '] })).rejects.toThrow(/blank-selector.*empty/s);
});

test('a mask that covers most of the viewport is refused (body must not become an opt-out)', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML());
  await expect(waitForSettle(page, 'mask-body', { ...BUDGET, mask: ['body', 'html'] }))
    .rejects.toThrow(/mask-body.*more than 50% of the viewport/s);
});

test('fonts and finite animations are still waited for everywhere while the canvas is masked', async ({ page }) => {
  await page.setContent(LIVE_CANVAS_HTML({ fade: true }));
  expect(await page.evaluate(() => getComputedStyle(document.getElementById('box')!).opacity)).not.toBe('1');
  await waitForSettle(page, 'canvas-masked-finite-anim', { ...BUDGET, timeoutMs: 5_000, mask: [LIVE] });
  expect(await page.evaluate(() => getComputedStyle(document.getElementById('box')!).opacity)).toBe('1');
  await resumeFrozenAnimations(page);
});
