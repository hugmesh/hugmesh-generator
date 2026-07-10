'use strict';
// ============================================================================
// validate-archetype.js — ANCHORED-REGION drift oracle for an archetype overlay.
// ============================================================================
//
// BUILD-HOST ONLY. The Phase-4 generalization of the Phase-2/3 whole-file
// byte-compare: a 2nd class member's file legitimately DIFFERS from the exemplar,
// so we no longer byte-compare whole files. Instead, rendering each token with the
// archetype's UPSTREAM-IDENTITY oracle (_identity.env), we assert:
//
//   RECIPE anchors (class-B):
//     (1) find@upstream still occurs in the freshly-pulled base file (>=1x if the
//         anchor is `required`; a present-but-0 optional anchor is fine) — proves
//         the anchor still bites the intended region;
//     (2) replace@upstream === find@upstream — the round-trip no-op that proves the
//         recipe is a faithful, brand-only rewrite of that region.
//   CLASS-A whole-file .hbs (e.g. angular-mfe/federation-base.js):
//     (3) render@upstream is byte-identical to the base file. Additive class-A
//         files with NO corresponding base file (gateway deploy/*) have no base
//         drift oracle and are reported as ADDITIVE (not failed).
//
// GREEN on a fresh, in-sync base; RED on any injected drift.
//
// Usage:
//   validate-archetype.js --archetype-dir DIR --base DIR --extra-tokens CSV

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const Handlebars = require('handlebars');
const engine = require('./render-handlebars');

function die(m) { process.stderr.write(`[validate-archetype] FATAL: ${m}\n`); process.exit(2); }

function parseArgs(argv) {
  const o = { archetypeDir: null, base: null, extraTokens: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--archetype-dir') o.archetypeDir = argv[++i];
    else if (a === '--base') o.base = argv[++i];
    else if (a === '--extra-tokens') o.extraTokens = (argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean);
    else die(`unknown arg: ${a}`);
  }
  if (!o.archetypeDir) die('missing --archetype-dir');
  if (!o.base) die('missing --base');
  return o;
}

function render(str, ctx, label) {
  engine.assertTemplateSafe(str, label);
  return Handlebars.compile(String(str), { noEscape: true, strict: false })(ctx);
}

function listHbs(dir) {
  const acc = [];
  (function walk(d) {
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      if (ent.isDirectory()) { if (ent.name === '_skeleton') continue; walk(path.join(d, ent.name)); }
      else if (ent.isFile() && ent.name.endsWith('.hbs')) acc.push(path.join(d, ent.name));
    }
  })(dir);
  return acc.sort();
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const archDir = path.resolve(args.archetypeDir);
  const base = path.resolve(args.base);
  const ctx = engine.buildContext(args.extraTokens);

  let failed = 0, checks = 0;
  const out = [];
  out.push(`== archetype drift check ==`);
  out.push(`archetype dir : ${archDir}`);
  out.push(`base          : ${base}`);
  out.push('');

  // ── (A) recipe anchors ──────────────────────────────────────────────────
  const recipePath = path.join(archDir, 'recipe.yaml');
  if (fs.existsSync(recipePath)) {
    const recipe = yaml.load(fs.readFileSync(recipePath, 'utf8')) || {};
    for (const edit of (recipe.edits || [])) {
      const baseFile = path.join(base, edit.file);
      const optional = edit.optional !== false;
      if (!fs.existsSync(baseFile)) {
        if (optional) { out.push(`  [ADDITIVE] ${edit.file} — absent in base (optional file, skipped)`); continue; }
        failed++; out.push(`  [DRIFT]    ${edit.file} — REQUIRED file absent from base`); continue;
      }
      const content = fs.readFileSync(baseFile, 'utf8');
      for (const a of (edit.anchors || [])) {
        checks++;
        const id = a.id || a.find.slice(0, 30);
        const find = render(a.find, ctx, `${edit.file}#${id} find`);
        const repl = render(a.replace, ctx, `${edit.file}#${id} replace`);
        const hits = content.split(find).length - 1;
        const roundTrip = repl === find;
        if (a.required === true && hits === 0) {
          failed++; out.push(`  [DRIFT]    ${edit.file}#${id} — required anchor NOT FOUND in base (find=${JSON.stringify(find)})`);
        } else if (!roundTrip) {
          failed++; out.push(`  [DRIFT]    ${edit.file}#${id} — replace@upstream != find@upstream (oracle mismatch)\n               find=${JSON.stringify(find)}\n               repl=${JSON.stringify(repl)}`);
        } else {
          out.push(`  [OK]       ${edit.file}#${id} — ${hits} hit(s), round-trip no-op${hits === 0 ? ' (optional, absent in this base)' : ''}`);
        }
      }
    }
  }

  // ── (B) class-A whole-file .hbs ─────────────────────────────────────────
  for (const hbs of listHbs(archDir)) {
    const rel = path.relative(archDir, hbs).replace(/\.hbs$/, '');
    const baseFile = path.join(base, rel);
    const src = fs.readFileSync(hbs, 'utf8');
    const rendered = render(src, ctx, `class-A ${rel}`);
    if (!fs.existsSync(baseFile)) { out.push(`  [ADDITIVE] ${rel} — class-A file has no base counterpart (no drift oracle)`); continue; }
    checks++;
    if (fs.readFileSync(baseFile, 'utf8') === rendered) out.push(`  [OK]       ${rel} — class-A byte-identical to base`);
    else { failed++; out.push(`  [DRIFT]    ${rel} — class-A render differs from base (whole-file drift)`); }
  }

  out.push('');
  out.push(failed === 0
    ? `RESULT: PASS — archetype overlay in sync with the base (${checks} checks, 0 drift).`
    : `RESULT: FAIL — ${failed} drifted region(s) of ${checks} checks (see above).`);
  process.stdout.write(out.join('\n') + '\n');
  process.exit(failed === 0 ? 0 : 1);
}

main();
