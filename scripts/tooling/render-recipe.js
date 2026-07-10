'use strict';
// ============================================================================
// render-recipe.js — ANCHORED, PRESENCE-TOLERANT recipe engine (Phase 4).
// ============================================================================
//
//  >>> BUILD-HOST ONLY. Invokes Node + Handlebars; MUST NOT run as root on the <<<
//  >>> mesh-node fail-closed root-cron reconcile path (Phase 6). See           <<<
//  >>> docs/MESH-TEMPLATING.md, "Node-not-root-on-the-mesh-cron-path".         <<<
//
// This is the change that turns 2 whole-file EXEMPLAR overlays into N-repo
// ARCHETYPE rendering. The Phase-2/3 exemplars stored WHOLE tokenized files
// (admin app.yml 845L, login package.json/index.html). A whole-file overlay
// carries the exemplar's OWN repo identity, so laying it onto a 2nd repo of the
// same class REPLACES that repo's identity (user-bff emitted as admin;
// user-ui's `ng build user` clobbered to `ng build login` -> build FAILS).
//
// The archetype instead ships a RECIPE of ANCHORED edits applied to each repo's
// OWN base file: per (file, anchor) an upstream-literal `find` and a tokenized
// `replace`. BOTH are rendered through the SAME Handlebars context + fail-closed
// classifier gate (render-handlebars.assertTemplateSafe) — so `find` can carry
// per-repo IDENTITY tokens (e.g. `@snapdragon/{{APP_SLUG}}`) to match the base,
// and `replace` carries the brand delta. PRESENCE-TOLERANT: an anchor that does
// not occur in a given repo's base simply no-ops (user-bff has no mfa/totp/
// admin-emails/appstore keys -> those anchors match 0 and are skipped — exactly
// the wanted behavior), so ONE recipe covers the whole class UNION.
//
// Recipe schema (YAML):
//   edits:
//     - file: src/main/resources/application.yml     # repo-relative target
//       optional: true            # (default true) missing target file => skip
//       anchors:
//         - id: oidc-issuer-host  # human label for logs / drift oracle
//           find: "https://id.snapdragon.systems"          # rendered w/ ctx
//           replace: "https://id.{{CLUSTER_DOMAIN}}"       # rendered w/ ctx
//           required: false       # (default false) if true, MUST match >=1x
//
// Tokens come from the environment (the fixed brand set + --extra-tokens), the
// SAME context builder render-handlebars.js uses.
//
// Usage:
//   render-recipe.js --recipe DIR/recipe.yaml --target OUTDIR \
//       [--extra-tokens CSV] [--report JSONFILE]
//
// Exit 0 on success (prints per-anchor hit counts to stderr). Non-zero on a gate
// violation (frozen/denylisted/unknown token in find or replace), a missing
// REQUIRED anchor, or a missing REQUIRED file.

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const Handlebars = require('handlebars');
const engine = require('./render-handlebars'); // buildContext + assertTemplateSafe

function die(msg) {
  process.stderr.write(`[render-recipe] FATAL: ${msg}\n`);
  process.exit(1);
}
function log(msg) { process.stderr.write(`[render-recipe] ${msg}\n`); }

function parseArgs(argv) {
  const out = { recipe: null, target: null, extraTokens: [], report: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--recipe') out.recipe = argv[++i];
    else if (a === '--target') out.target = argv[++i];
    else if (a === '--report') out.report = argv[++i];
    else if (a === '--extra-tokens') {
      out.extraTokens = (argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean);
    } else die(`unknown argument: ${a}`);
  }
  if (!out.recipe) die('missing --recipe FILE');
  if (!out.target) die('missing --target DIR');
  return out;
}

// Render a find/replace string with the shared classifier gate. noEscape:true so
// substitution is byte-exact (parity with the sed/Handlebars default path).
function renderGated(str, ctx, label) {
  try {
    engine.assertTemplateSafe(str, label);
  } catch (e) {
    die(e.message);
  }
  return Handlebars.compile(String(str), { noEscape: true, strict: false })(ctx);
}

// Replace EVERY literal occurrence of `find` with `repl`; return [newContent, n].
function replaceAllLiteral(hay, find, repl) {
  if (find === '') return [hay, 0];
  let n = 0;
  let out = '';
  let idx = 0;
  for (;;) {
    const at = hay.indexOf(find, idx);
    if (at === -1) { out += hay.slice(idx); break; }
    out += hay.slice(idx, at) + repl;
    idx = at + find.length;
    n++;
  }
  return [out, n];
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const recipePath = path.resolve(args.recipe);
  const targetDir = path.resolve(args.target);
  if (!fs.existsSync(recipePath)) die(`recipe not found: ${recipePath}`);
  if (!fs.existsSync(targetDir)) die(`target dir not found: ${targetDir}`);

  let recipe;
  try {
    recipe = yaml.load(fs.readFileSync(recipePath, 'utf8'));
  } catch (e) {
    die(`recipe YAML parse error: ${e.message}`);
  }
  if (!recipe || !Array.isArray(recipe.edits)) die('recipe must have an edits[] list');

  const ctx = engine.buildContext(args.extraTokens); // fail-closed on token names
  const report = { recipe: recipePath, target: targetDir, files: [] };
  let totalHits = 0;

  for (const edit of recipe.edits) {
    if (!edit || typeof edit.file !== 'string') die('each edit needs a string `file`');
    // Path containment: the target file must stay inside targetDir.
    const abs = path.resolve(targetDir, edit.file);
    if (abs !== targetDir && !abs.startsWith(targetDir + path.sep)) {
      die(`edit file '${edit.file}' escapes the target dir`);
    }
    const optional = edit.optional !== false; // default: optional
    const fileRep = { file: edit.file, present: fs.existsSync(abs), anchors: [] };

    if (!fileRep.present) {
      if (!optional) die(`required target file absent: ${edit.file}`);
      log(`skip (absent, optional): ${edit.file}`);
      report.files.push(fileRep);
      continue;
    }

    let content = fs.readFileSync(abs, 'utf8');
    const anchors = Array.isArray(edit.anchors) ? edit.anchors : [];
    for (const a of anchors) {
      if (!a || typeof a.find !== 'string' || typeof a.replace !== 'string') {
        die(`anchor in '${edit.file}' needs string find + replace`);
      }
      const id = a.id || a.find.slice(0, 40);
      const label = `recipe ${path.basename(recipePath)} [${edit.file}#${id}] anchor`;
      const find = renderGated(a.find, ctx, `${label} (find)`);
      const repl = renderGated(a.replace, ctx, `${label} (replace)`);
      const [next, n] = replaceAllLiteral(content, find, repl);
      content = next;
      totalHits += n;
      if (n === 0 && a.required === true) {
        die(`required anchor '${id}' did not match in ${edit.file} (base drift? find=${JSON.stringify(find)})`);
      }
      fileRep.anchors.push({ id, hits: n, required: a.required === true });
      log(`${edit.file}#${id}: ${n} hit(s)${n === 0 ? ' (presence-tolerant no-op)' : ''}`);
    }
    fs.writeFileSync(abs, content);
    report.files.push(fileRep);
  }

  if (args.report) fs.writeFileSync(path.resolve(args.report), JSON.stringify(report, null, 2));
  log(`applied ${totalHits} anchored edit(s) across ${report.files.length} file(s) in ${targetDir}`);
}

main();
