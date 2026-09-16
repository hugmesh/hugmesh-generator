/**
 * capture.spec.ts — the ONLINE half of the screenshot harness.
 *
 * Drives one screenshot per row of shots.json against an ALREADY-RUNNING stack
 * and writes `<SNAP_SHOTS>/<persona>-<NN>-<slug>.png`. The 17 manual test plans
 * reference those files by path; nobody pastes an image into an issue body.
 *
 * Run it through `npm run shots -- --persona <p> --door <url>` (shots.sh), which
 * does the stack preflight and resolves the credential READ-ONLY. Running this
 * file directly still works, but the beforeAll below re-does the preflight so a
 * down stack can never produce a directory full of browser error pages.
 *
 * DESIGN NOTES, in the order they matter:
 *
 *  1. NO CODE EDIT TO ADD A SHOT. The table is shots.json. This file contains no
 *     persona names, no routes and no testids — read it and you will find none.
 *     A plan author appends a row and runs `shot-table.mjs validate`.
 *
 *  2. IT REUSES THE REPO'S AUTH. onboard()/registerOnly() from specs/helpers.ts,
 *     the same two-stage sign-in the 33 specs use, with the same
 *     SHELL_AFTER_PROVISION_MS budget. Login is not reimplemented here — a
 *     second implementation would drift and then lie about what a tester sees.
 *
 *  3. IT NEVER MINTS A CREDENTIAL. The password arrives as $E2E_PASSWORD, which
 *     shots.sh resolves by READING .e2e-credentials. tests/stack/e2e-password.sh
 *     GENERATES when executed directly; nothing in this harness executes it.
 *     '@password' in a table row resolves through loginPassword() at run time so
 *     no credential is ever written into a committed file.
 *
 *  4. AN EMPTY PNG IS WORSE THAN NO PNG. evidence.mjs checks the PNG header,
 *     the IHDR dimensions, the byte length and (via pngjs) that the frame is
 *     not one flat colour — and DELETES the file before failing. A blank
 *     image sitting in shots/ under the right filename reads as evidence to
 *     everyone who did not run the harness. It is a separate .mjs so it can
 *     be mutation-tested offline, with no mesh.
 *
 *  5. ONE RED ROW COSTS ONE PNG. Rows are independent tests (each signs in
 *     afresh), so they run in 'default' mode, not 'serial'. Under serial mode
 *     (the shape until 2026-09-16) the first failing row SKIPPED every later
 *     row of the persona: a single plan-designed 403 document that the
 *     evidence check deletes (#310 step 12) silently withheld five more cited
 *     PNGs. The one thing serial mode bought — stopping early when the DOOR is
 *     gone — is kept by `doorLost` below: a row that finds the browser on its
 *     own error page marks the door lost, and every later row skips with that
 *     reason instead of burning its 120 s timeout.
 */
import { test, expect, type Page, type Locator } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { pathToFileURL } from 'node:url';
import { onboard, registerOnly, shot, SHOTS, apiContext, SUPERADMIN_USERNAME } from '../specs/helpers';
import { loginPassword } from '../specs/rbac-roles';

interface DoAction {
  action: 'goto' | 'click' | 'fill' | 'press' | 'expect' | 'expectAttached' | 'expectHidden';
  testid?: string;
  value?: string;
  key?: string;
  route?: string;
  /** Act on the FIRST match when the testid is rendered once per list row (see shot-table.mjs). */
  first?: true;
}
interface ShotRow {
  persona: string;
  step: string;
  slug: string;
  auth: 'anon' | 'signin-only' | 'onboard';
  login?: string;
  route?: string;
  do?: DoAction[];
  note?: string;
}

const TABLE = JSON.parse(fs.readFileSync(path.join(__dirname, 'shots.json'), 'utf8')) as
  { personas: { slug: string; issue: number; title: string }[]; shots: ShotRow[] };

const PERSONA = process.env.SHOTS_PERSONA || '';
const ROWS = PERSONA ? TABLE.shots.filter((r) => r.persona === PERSONA) : TABLE.shots;

/** The door. shots.sh always sets it; shots.config.ts refuses to load without it. */
const DOOR = process.env.SNAP_BASE_URL || '';

/**
 * Resolve a table login handle. '@superadmin' follows SUPERADMIN_USERNAME
 * (env-driven on a Studio-bootstrapped mesh) rather than pinning a literal that
 * would be wrong on exactly the meshes an operator builds themselves.
 */
function resolveLogin(handle: string): string {
  return handle === '@superadmin' ? SUPERADMIN_USERNAME : handle;
}

/** Resolve a table fill value. '@password' is the seeded shared credential. */
function resolveValue(value: string): string {
  return value === '@password' ? loginPassword() : value;
}

/** A chrome error page is not a screenshot of the product. */
async function assertNotAnErrorPage(page: Page): Promise<void> {
  const url = page.url();
  if (url.startsWith('chrome-error://')) {
    throw new Error(`the browser could not reach ${DOOR} — it is showing its own error page, not the product`);
  }
  const body = await page.locator('body').innerText().catch(() => '');
  const netErr = body.match(/ERR_(CONNECTION_REFUSED|CONNECTION_RESET|EMPTY_RESPONSE|NAME_NOT_RESOLVED|SSL_PROTOCOL_ERROR|CERT_[A-Z_]+)/);
  if (netErr) throw new Error(`the browser reported ${netErr[0]} against ${DOOR} — the stack is not serving this route`);
}

async function runAction(page: Page, a: DoAction): Promise<void> {
  if (a.action === 'goto') { await page.goto(a.route!); return; }
  // getByTestId is STRICT: two matches throw instead of acting on one. A row
  // whose plan accepts "the first row" (e.g. #300 line 44) says so with
  // `"first": true`, validated by shot-table.mjs; everything else stays strict,
  // because a silently-picked element is a screenshot of the wrong control.
  const all: Locator = page.getByTestId(a.testid!);
  const target: Locator = a.first === true ? all.first() : all;
  switch (a.action) {
    case 'click': await target.click(); return;
    case 'fill': await target.fill(resolveValue(a.value!)); return;
    case 'press': await target.press(a.key!); return;
    case 'expect': await expect(target).toBeVisible(); return;
    case 'expectAttached': await expect(target).toBeAttached(); return;
    case 'expectHidden': await expect(target).toBeHidden(); return;
    default:
      // Unreachable while shot-table.mjs validate gates the table, and loud if
      // that gate is ever skipped: a silently ignored action is a screenshot of
      // the wrong screen.
      throw new Error(`unknown action '${(a as DoAction).action}' — run: node shot-harness/shot-table.mjs validate`);
  }
}

test.describe.configure({ mode: 'default' });   // see design note 5 — one red row costs one PNG

/**
 * Set by the first row that finds the browser on its own error page (door gone
 * mid-run). Every later row then skips, naming this reason, rather than each
 * paying a full timeout to rediscover it. A row failing for its OWN reason (a
 * missing testid, a 403 document, a login no seeder creates) does not set it.
 */
let doorLost: string | null = null;

test.beforeAll(async () => {
  if (!DOOR) throw new Error('SNAP_BASE_URL is unset. Run this through: npm run shots -- --persona <p> --door <url>');
  // The same preflight shots.sh runs, repeated here so a direct `npx playwright
  // test -c shot-harness/shots.config.ts` cannot fill shots/ with error pages.
  // /bff/session answers 401 when signed out, so ANY of 200/401/403 proves the
  // gateway routed to the BFF; a 404 proves only that SOMETHING is listening
  // (measured 2026-08-27: the kind node's nginx 404s on the wrong port).
  const ctx = await apiContext(DOOR);
  let status: number;
  try {
    status = (await ctx.get('/bff/session', { headers: { accept: 'application/json' }, timeout: 15_000 })).status();
  } catch (e) {
    throw new Error(`the stack at ${DOOR} did not answer GET /bff/session (${(e as Error).message}). Bring it up: make stack-up && make stack-seed`);
  } finally {
    await ctx.dispose();
  }
  if (![200, 401, 403].includes(status)) {
    throw new Error(
      `GET ${DOOR}/bff/session returned ${status}. Something is listening on that port but it is not this platform's `
      + 'front door (a 404 is what a bare nginx default backend answers). Check --door.',
    );
  }
});

if (ROWS.length === 0) {
  // NO SILENT GREEN. A persona nobody has written rows for must not look like a
  // clean capture run; it is the plan author's cue to add rows to shots.json.
  test(`shot table has rows for persona '${PERSONA || '(all)'}'`, () => {
    throw new Error(
      `no rows in shots.json for persona '${PERSONA}'. Known personas:\n  `
      + TABLE.personas.map((p) => `${p.slug} (#${p.issue})`).join('\n  ')
      + '\nAdd a row to tests/e2e/shot-harness/shots.json, then: node shot-harness/shot-table.mjs validate',
    );
  });
}

for (const row of ROWS) {
  const name = `${row.persona}-${row.step}-${row.slug}`;
  test(name, async ({ page }) => {
    test.skip(doorLost !== null, `door unreachable since an earlier row: ${doorLost}`);
    try {
      if (row.auth === 'onboard') await onboard(page, resolveLogin(row.login!));
      else if (row.auth === 'signin-only') await registerOnly(page, resolveLogin(row.login!));

      if (row.route) await page.goto(row.route);
      await assertNotAnErrorPage(page);

      for (const a of row.do ?? []) await runAction(page, a);

      await shot(page, name);                       // specs/helpers.ts shot(): fullPage, into SNAP_SHOTS

      // The evidence guard lives in evidence.mjs so it can be exercised OFFLINE
      // (`node shot-harness/evidence.mjs <file.png>`) — a guard nobody can run
      // without a mesh is a guard nobody re-checks. It DELETES a failing image.
      const { assertRealEvidence } = await import(pathToFileURL(path.join(__dirname, 'evidence.mjs')).href);
      assertRealEvidence(path.join(SHOTS, `${name}.png`));
    } catch (e) {
      // Was it the DOOR, not the row? onboard() on a dead stack fails as a
      // locator timeout, so ask the page itself; a live page passes this and
      // the row's own error is what gets reported.
      await assertNotAnErrorPage(page).catch((doorErr: Error) => { doorLost = doorErr.message; });
      throw e;
    }
  });
}
