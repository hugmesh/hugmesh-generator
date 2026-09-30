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
