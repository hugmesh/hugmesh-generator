/**
 * fullheight.spec.ts — the OFFLINE pin for the full-height capture fix.
 *
 * Operator report, 2026-09-18: "screenshots have broken background". The host
 * shell's background layer is `position: fixed` and sized to the VIEWPORT
 * (100vh), not the document. shot() (specs/helpers.ts) captures with
 * `fullPage: true`, which grows the rendered PAGE but does not resize the
 * actual browser viewport, so a fixed 100vh layer stays pinned to the
 * ORIGINAL viewport height — any row taller than that shows the bare body
 * colour below it in the PNG. In a real browser this is invisible (the fixed
 * layer visually follows scroll); it is purely a fullPage-screenshot
 * artifact. See settle.ts's "full-height capture" section for
 * growToFullHeight()/restoreViewport().
 *
 * Runs entirely against a page.setContent() fixture; needs no door, no
 * credential and no compose stack:
 *
 *   npx playwright test -c shot-harness/fullheight.config.ts
 */
import { test, expect } from '@playwright/test';
// pngjs is already a declared dependency of this package (evidence.mjs uses
// it the same way, via createRequire — this file is transpiled CommonJS, not
// loaded as native ESM, so a plain import is enough) — no new dependency for
// this pin.
import { PNG } from 'pngjs';
import {
  growToFullHeight, restoreViewport, waitForSettle, resumeFrozenAnimations,
} from './settle';

/** Mirrors the real host shell's bare body colour named in the operator report. */
const BODY_RGB = [10, 10, 18] as const;
/** The fixture's fixed-background colour — visually unmistakable from BODY_RGB. */
const BG_RGB = [255, 105, 0] as const;

const CONTENT_HEIGHT_PX = 3000;

const FIXTURE_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><style>
  /* Background lives on <html> ONLY, not <body>. When BOTH have an explicit
     background, the canvas paint uses html's, but body's own background then
     paints as its own normal in-flow box — a stacking layer ABOVE any
     negative-z-index descendant (CSS2.1 §E: negative z-index paints in step
     2, non-positioned in-flow boxes paint in step 3). That unconditionally
     hid #bg below body's own background, in every configuration, resized or
     not — a fixture bug, found by instrumenting pixels across the whole
     capture (not just the bottom) and by a variant sweep (removing body's
     background, or giving #bg z-index:0/none, both made it visible; the
     resize/settle timing was never the cause). Un-set here so #bg's own
     negative z-index has nothing opaque above it to hide behind, matching
     what "fixed background behind everything" actually requires. */
  html { margin: 0; background: rgb(${BODY_RGB.join(',')}); }
  body { margin: 0; }
  /* Stands in for the host shell's app-background: fixed, sized to the
     viewport, behind everything. */
  #bg {
    position: fixed; inset: 0; height: 100vh; width: 100vw;
    background: rgb(${BG_RGB.join(',')});
    z-index: -1;
  }
  /* Narrow so it never itself paints over the bottom-left sample pixel;
     only #bg (or, where #bg falls short, the body) can be there. */
  #content { position: relative; height: ${CONTENT_HEIGHT_PX}px; width: 10px; }
</style></head>
<body>
  <div id="bg"></div>
  <div id="content"></div>
</body></html>`;

/** Read one RGB pixel out of a PNG buffer. */
function pixelAt(buf: Buffer, x: number, y: number): [number, number, number] {
  const png = PNG.sync.read(buf);
  const idx = (png.width * y + x) << 2;
  return [png.data[idx], png.data[idx + 1], png.data[idx + 2]];
}

test(
  'growToFullHeight makes a fixed 100vh background cover a full-page capture, and restoreViewport puts the viewport back',
  async ({ page }) => {
    await page.setViewportSize({ width: 400, height: 300 });
    await page.setContent(FIXTURE_HTML);
    const originalViewport = page.viewportSize()!;

    const returned = await growToFullHeight(page, 'fullheight-fixture');
    expect(returned).toEqual(originalViewport);

    const grown = page.viewportSize()!;
    expect(grown.width).toBe(originalViewport.width);
    expect(grown.height).toBeGreaterThanOrEqual(CONTENT_HEIGHT_PX);

    // Mirror the real pipeline (capture.spec.ts): settle before shooting, so
    // the resize has had a real chance to land — not just the two rAFs
    // growToFullHeight itself waits — before the capture is taken. This is
    // also a more faithful pin of the actual integration, since production
    // never takes a fullPage shot straight off growToFullHeight either.
    await waitForSettle(page, 'fullheight-fixture');
    let buf: Buffer;
    try {
      buf = await page.screenshot({ fullPage: true });
    } finally {
      await resumeFrozenAnimations(page);
    }
    const pngHeight = PNG.sync.read(buf).height;
    const [r, g, b] = pixelAt(buf, 5, pngHeight - 5);
    // The whole point: a pixel near the BOTTOM of the capture is the
    // background colour, not the body colour.
    expect([r, g, b]).toEqual([...BG_RGB]);
    expect([r, g, b]).not.toEqual([...BODY_RGB]);

    await restoreViewport(page, originalViewport);
    expect(page.viewportSize()).toEqual(originalViewport);
  },
);

test(
  'sanity: without growing the viewport the fixture genuinely reproduces the broken-background bug (so the test above can actually fail)',
  async ({ page }) => {
    await page.setViewportSize({ width: 400, height: 300 });
    await page.setContent(FIXTURE_HTML);
    // No growToFullHeight call at all — the harness's behaviour before this
    // fix (settle still runs, exactly like the real pre-fix pipeline did).
    await waitForSettle(page, 'fullheight-fixture-unfixed');
    let buf: Buffer;
    try {
      buf = await page.screenshot({ fullPage: true });
    } finally {
      await resumeFrozenAnimations(page);
    }
    const pngHeight = PNG.sync.read(buf).height;
    const [r, g, b] = pixelAt(buf, 5, pngHeight - 5);
    expect([r, g, b]).toEqual([...BODY_RGB]);
  },
);

test('growToFullHeight is a no-op when the document already fits the viewport', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 3200 });
  await page.setContent(FIXTURE_HTML);
  const originalViewport = page.viewportSize()!;

  const returned = await growToFullHeight(page, 'fullheight-fixture-already-tall');
  expect(returned).toEqual(originalViewport);
  expect(page.viewportSize()).toEqual(originalViewport);
});

test('growToFullHeight caps at maxHeightPx and logs when it does', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 300 });
  await page.setContent(FIXTURE_HTML); // ~3000px tall
  const originalViewport = page.viewportSize()!;

  // growToFullHeight's cap warning runs in NODE (console.warn in settle.ts),
  // not the page — it is Node code calling Node's console, not
  // page.evaluate()'d — so it is captured by spying on console.warn here,
  // not via a page 'console' event listener.
  const warnings: unknown[][] = [];
  // eslint-disable-next-line no-console
  const originalWarn = console.warn;
  // eslint-disable-next-line no-console
  console.warn = (...args: unknown[]) => { warnings.push(args); };

  const cappedHeight = 1000;
  try {
    await growToFullHeight(page, 'fullheight-fixture-capped', { maxHeightPx: cappedHeight });
  } finally {
    // eslint-disable-next-line no-console
    console.warn = originalWarn;
  }
  expect(page.viewportSize()!.height).toBe(cappedHeight);
  expect(warnings).toHaveLength(1);
  expect(String(warnings[0][0])).toMatch(/exceeds the 1000px cap/);

  await restoreViewport(page, originalViewport);
  expect(page.viewportSize()).toEqual(originalViewport);
});
