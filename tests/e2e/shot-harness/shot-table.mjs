#!/usr/bin/env node
// shot-table.mjs — the OFFLINE half of the screenshot harness.
//
// Everything here runs with no stack, no browser and no credential, so a plan
// author who appends a row to shots.json can prove the row is well-formed
// before anyone brings a mesh up. capture.spec.ts (the ONLINE half) imports
// nothing from here; it re-reads the same JSON. The two agree because
// ACTIONS/AUTH below are the same closed sets the spec switches on, and
// `validate` fails on anything outside them — so a typo'd action name is a
// validation error rather than a silently skipped step in a live run.
//
//   node shot-harness/shot-table.mjs validate            # gate: exits 1 on any problem
//   node shot-harness/shot-table.mjs list                # personas + shot counts
//   node shot-harness/shot-table.mjs paths [persona]     # the shots/… lines a plan quotes (no persona: every row)
//   node shot-harness/shot-table.mjs needs-auth <persona>  # 'yes'|'no' (used by shots.sh)
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const TABLE_PATH = path.join(HERE, 'shots.json');

/** Closed set of prepare actions. capture.spec.ts switches on exactly these. */
const ACTIONS = new Set(['goto', 'click', 'fill', 'press', 'expect', 'expectAttached', 'expectHidden']);
/** Closed set of auth modes. 'anon' never signs in; 'signin-only' is stage 1
 *  (helpers.registerOnly — stops on whatever card the login-ui shows next);
 *  'onboard' is the full two-stage sign-in (helpers.onboard). */
const AUTH = new Set(['anon', 'signin-only', 'onboard']);
/** Actions that address a control and therefore REQUIRE a testid. */
const NEEDS_TESTID = new Set(['click', 'fill', 'press', 'expect', 'expectAttached', 'expectHidden']);
/** Actions that WAIT for the screen. Every row needs at least one — see below. */
const SETTLING = new Set(['expect', 'expectAttached', 'expectHidden']);
/**
 * `"first": true` on a testid action makes capture.spec.ts act on the FIRST match
 * (`locator.first()`) instead of failing Playwright's strict mode when a testid is
 * rendered once per list row — admin-ui's gs-suspend/gs-resume/gs-terminate live
 * inside `<li *ngFor="let i of instances()">`, one set per instance. Only `true`
 * is legal: the field is a declaration that the plan accepts "whichever row is
 * first" (#300 line 44), not a general index. Any other value is a validation error.
 */
const FIRST_OK = new Set([undefined, true]);

export function loadTable(file = TABLE_PATH) {
  const raw = fs.readFileSync(file, 'utf8');
  return JSON.parse(raw);
}

/** The one place the shot FILENAME is spelled. Plans quote what this returns. */
export function shotName(row) {
  return `${row.persona}-${row.step}-${row.slug}`;
}

/**
 * Validate the whole table. Returns a list of human-readable problems; empty
 * means the table is sound. Deliberately reports EVERY problem rather than
 * throwing on the first — a plan author adding five rows wants five answers.
 */
export function validate(table) {
  const problems = [];
  const slugRe = /^[a-z0-9]+(-[a-z0-9]+)*$/;

  if (!Array.isArray(table.personas)) return ['personas[] is missing or not an array'];
  if (!Array.isArray(table.shots)) return ['shots[] is missing or not an array'];

  const personas = new Set();
  for (const p of table.personas) {
    if (!slugRe.test(p.slug || '')) problems.push(`persona slug ${JSON.stringify(p.slug)} must be lower-case kebab-case`);
    if (personas.has(p.slug)) problems.push(`persona slug '${p.slug}' is declared twice`);
    personas.add(p.slug);
    if (!Number.isInteger(p.issue)) problems.push(`persona '${p.slug}' has no integer issue number`);
  }

  const seen = new Map();
  for (const [i, r] of table.shots.entries()) {
    const at = `shots[${i}] (${r.persona ?? '?'}-${r.step ?? '?'}-${r.slug ?? '?'})`;
    if (!personas.has(r.persona)) problems.push(`${at}: unknown persona '${r.persona}' — add it to personas[] first`);
    if (!/^[0-9]{2}$/.test(r.step || '')) problems.push(`${at}: step must be two digits ('04', not '4') so shots sort in plan order`);
    if (!slugRe.test(r.slug || '')) problems.push(`${at}: slug must be lower-case kebab-case`);
    if (!AUTH.has(r.auth)) problems.push(`${at}: auth must be one of ${[...AUTH].join('|')}`);
    if (r.auth !== 'anon' && !r.login) problems.push(`${at}: auth '${r.auth}' needs a 'login' handle (or '@superadmin')`);
    if (r.auth === 'anon' && r.login) problems.push(`${at}: auth 'anon' must not carry a login handle`);
    if (r.route !== undefined && !String(r.route).startsWith('/')) {
      problems.push(`${at}: route must be a door-relative path starting with '/' — the door comes from --door, never from this file`);
    }
    if (typeof r.login === 'string' && /pass|secret|pw/i.test(r.login)) {
      problems.push(`${at}: 'login' looks like a credential. Handles only; passwords are resolved at run time via @password.`);
    }

    const name = shotName(r);
    if (seen.has(name)) problems.push(`${at}: writes the same file as shots[${seen.get(name)}] — ${name}.png would be overwritten`);
    seen.set(name, i);

    // EVERY ROW MUST WAIT FOR SOMETHING before its shot is taken.
    // page.goto() resolves on load, not on render, and helpers.registerOnly()
    // returns the moment it clicks submit without waiting for the next card at
    // all. A row with no expect-family action screenshots whatever happened to
    // be painted — usually the previous screen, sometimes a spinner — and that
    // image is filed under a name that says otherwise. This is the same rule as
    // the empty-PNG check, one layer earlier.
    if (!(r.do ?? []).some((a) => SETTLING.has(a.action))) {
      problems.push(`${at}: needs at least one expect/expectAttached/expectHidden action naming a data-testid `
        + `that is on the screen being captured — otherwise the shot can land before the screen renders.`);
    }

    for (const [j, a] of (r.do ?? []).entries()) {
      const aat = `${at} do[${j}]`;
      if (!ACTIONS.has(a.action)) { problems.push(`${aat}: unknown action '${a.action}' (allowed: ${[...ACTIONS].join(', ')})`); continue; }
      if (NEEDS_TESTID.has(a.action) && !a.testid) problems.push(`${aat}: action '${a.action}' needs a data-testid`);
      if (a.action === 'fill' && typeof a.value !== 'string') problems.push(`${aat}: 'fill' needs a string 'value' (use '@password' for the seeded credential)`);
      if (a.action === 'press' && !a.key) problems.push(`${aat}: 'press' needs a 'key'`);
      if (a.action === 'goto' && !String(a.route ?? '').startsWith('/')) problems.push(`${aat}: 'goto' needs a door-relative 'route'`);
      if (!FIRST_OK.has(a.first)) {
        problems.push(`${aat}: 'first' must be exactly true when present (act on the FIRST match of a testid rendered once per list row); omit it otherwise`);
      }
      if (a.first === true && !NEEDS_TESTID.has(a.action)) problems.push(`${aat}: 'first' only applies to actions that address a data-testid`);
      // '@password' resolves to the SEEDED CREDENTIAL. Typed into anything but a
      // password field it is rendered in clear and the shot PHOTOGRAPHS it.
      if (a.action === 'fill' && a.value === '@password' && !/password/i.test(a.testid ?? '')) {
        problems.push(`${aat}: fills '@password' into '${a.testid}', which is not a password field — the shot would photograph the seeded credential.`);
      }
      // A literal password in the table would be committed to git forever.
      if (a.action === 'fill' && typeof a.value === 'string' && a.value !== '@password'
          && /password/i.test(a.testid ?? '')) {
        problems.push(`${aat}: fills a password field with a LITERAL. Use '@password' — the harness resolves the seeded credential at run time and never prints it.`);
      }
    }
  }
  return problems;
}

export function rowsFor(table, persona) {
  return persona ? table.shots.filter((r) => r.persona === persona) : table.shots;
}

// ── CLI ──────────────────────────────────────────────────────────────────────
const isMain = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isMain) {
  const [cmd, arg] = process.argv.slice(2);
  const table = loadTable();

  if (cmd === 'validate') {
    const problems = validate(table);
    if (problems.length) {
      process.stderr.write(`shots.json: ${problems.length} problem(s)\n`);
      for (const p of problems) process.stderr.write(`  - ${p}\n`);
      process.exit(1);
    }
    process.stdout.write(`shots.json OK — ${table.personas.length} personas, ${table.shots.length} shots\n`);
  } else if (cmd === 'list') {
    for (const p of table.personas) {
      const n = rowsFor(table, p.slug).length;
      process.stdout.write(`${p.slug.padEnd(24)} #${p.issue}  ${String(n).padStart(2)} shot(s)  ${p.title}\n`);
    }
  } else if (cmd === 'paths') {
    // No persona → every row, in table order. shots.sh needs that for the --all
    // epilogue, which reports WHICH cited files a run left absent.
    const rows = rowsFor(table, arg);
    if (arg && !rows.length) { process.stderr.write(`no shots for persona '${arg}'\n`); process.exit(1); }
    for (const r of rows) process.stdout.write(`shots/${shotName(r)}.png\n`);
  } else if (cmd === 'needs-auth') {
    const rows = rowsFor(table, arg);
    process.stdout.write(rows.some((r) => r.auth !== 'anon') ? 'yes\n' : 'no\n');
  } else if (cmd === 'count') {
    process.stdout.write(`${rowsFor(table, arg).length}\n`);
  } else {
    process.stderr.write('usage: shot-table.mjs validate|list|paths [persona]|needs-auth <persona>|count [persona]\n');
    process.exit(2);
  }
}
