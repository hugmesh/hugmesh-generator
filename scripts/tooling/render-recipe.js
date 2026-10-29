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
// per-repo IDENTITY tokens (e.g. `@hugmesh/{{APP_SLUG}}`) to match the base,
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
//           find: "https://id.hugmesh.net"          # rendered w/ ctx
//           replace: "https://id.{{CLUSTER_DOMAIN}}"       # rendered w/ ctx
//           required: false       # (default false) if true, MUST match >=1x
//   renames:                      # applied AFTER all edits[] (edits address
//     - from: docs/BRANDING.md    #   PRE-rename paths); both sides are rendered
//       to: docs/BRANDING-{{ORG_SLUG}}.md   # through the SAME classifier gate
//       required: false           # (default false) missing `from` => no-op skip
//
// renames[] is FAIL-CLOSED (each violation aborts the whole render):
//   * absolute paths on either side;
//   * any `..` segment on either side;
//   * a resolved path (realpath — symlinked parents included) escaping the
//     target tree on either side;
//   * a CONTRACT-DENYLISTED name on either side — hugmesh-deploy.yaml +
//     .hugmesh-provenance.json + .hugmesh-mesh-admitted (renaming those breaks
//     the 13d pathsExist discovery
//     filter, the provenance manifest's fixed name, and the publish
//     launder-refusal stamp checks) plus their fail-closed siblings
//     (.sig / base-origin / base-ref markers);
//   * renaming a DIRECTORY (files only — a dir rename could silently move the
//     `deploy/` discovery contract);
//   * a destination that already exists (never clobber).
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
// REQUIRED anchor, a missing REQUIRED file, or any renames[] refusal above.

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const Handlebars = require('handlebars');
const engine = require('./render-handlebars'); // buildContext + assertTemplateSafe
const classifier = require('./token-classifier'); // isRenameContractFile (tokens.json)

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

// ── renames[] guards ─────────────────────────────────────────────────────────
// CONTRACT DENYLIST: fixed-name files the platform's discovery/provenance/publish
// machinery HARDCODES. Renaming any of them in an emitted tree breaks, in order:
// the 13d brand-repo ApplicationSet pathsExist filter (hugmesh-deploy.yaml),
// provenance.sh's fixed MANIFEST/SIG names, and publish-tenant-set.sh's Phase-7
// launder-refusal stamp + durable-marker reads. The base-origin/base-ref entries
// are OUR outbound lineage markers — publish keys fail-closed behavior off their
// exact names, so a recipe may never move them either.
const RENAME_CONTRACT_DENYLIST = new Set([
  'hugmesh-deploy.yaml',
  '.hugmesh-provenance.json',
  '.hugmesh-provenance.json.sig',
  '.hugmesh-mesh-admitted',
  '.hugmesh-base-origin.json',
  '.hugmesh-base-ref',
]);

// DECLARED contracts, from any scripts/tooling/tokens.json block carrying a
// `rename_denylist` array — currently the theme delivery chain. Declared there
// rather than pinned here because its OTHER half (the SNAP_THEME_CSS /
// SNAP_THEME_OUT env keys, the web-locales key in both its live HUG_WEB_LOCALES
// and retired SNAP_WEB_LOCALES spellings, and the --hug-*/--sd-* custom
// properties)
// is enforced on the TOKEN side by render-handlebars.assertTemplateSafe(), and
// one contract split across two hardcoded lists is a contract that drifts.
//
// Kept a SEPARATE lookup from the Set literal above on purpose:
// scripts/validate-catalog-discovery.sh STATICALLY PARSES that literal (a regex
// over this file's source) to prove every catalog-ACCEPTED descriptor spelling
// is rename-protected. Spreading the declared names into the literal would feed
// that parser names no generator will ever accept, and — worse — a spread the
// regex cannot evaluate would make the gate's view of the Set silently disagree
// with the engine's. Two lookups, one refusal.
function isRenameContractName(base) {
  return RENAME_CONTRACT_DENYLIST.has(base) || classifier.isRenameContractFile(base);
}

// Shape-validate ONE side of a rename (already Handlebars-rendered). Returns the
// resolved absolute path; die()s on any fail-closed violation. `side` labels the
// error ("from"/"to"); `id` is the rename's human label.
function resolveRenameSide(targetDir, rel, side, id) {
  if (typeof rel !== 'string' || rel.length === 0) {
    die(`rename '${id}': ${side} must be a non-empty string`);
  }
  if (/[\x00-\x1f\x7f]/.test(rel)) {
    die(`rename '${id}': ${side} '${rel}' contains a control character — refusing`);
  }
  if (path.isAbsolute(rel)) {
    die(`rename '${id}': ${side} '${rel}' is an ABSOLUTE path — renames are repo-relative only (fail-closed)`);
  }
  // Any '..' segment is refused outright (belt) — the realpath containment below
  // is the suspenders for symlinked parents.
  if (rel.split(/[\\/]/).includes('..')) {
    die(`rename '${id}': ${side} '${rel}' contains a '..' segment — refusing (tree-escape guard)`);
  }
  if (isRenameContractName(path.basename(rel))) {
    die(`rename '${id}': ${side} '${rel}' names a CONTRACT file (${path.basename(rel)}) — the 13d discovery filter / provenance manifest / publish admission stamps / theme delivery chain hardcode it; refusing (fail-closed)`);
  }
  const abs = path.resolve(targetDir, rel);
  if (abs === targetDir || !abs.startsWith(targetDir + path.sep)) {
    die(`rename '${id}': ${side} '${rel}' escapes the target dir — refusing`);
  }
  return abs;
}

// Realpath containment for an EXISTING path (follows symlinked parents): the
// lexical checks above cannot see a symlinked dir inside the tree pointing out.
function assertRealUnder(targetDir, existingPath, side, id) {
  const realRoot = fs.realpathSync(targetDir);
  const real = fs.realpathSync(existingPath);
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
    die(`rename '${id}': ${side} '${existingPath}' resolves (through a symlink) to '${real}' OUTSIDE the target tree — refusing`);
  }
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
  if (recipe.renames !== undefined && !Array.isArray(recipe.renames)) {
    die('recipe renames must be a list when present');
  }

  const ctx = engine.buildContext(args.extraTokens); // fail-closed on token names
  const report = { recipe: recipePath, target: targetDir, files: [], renames: [] };
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

  // ── renames[] — applied AFTER all edits (edits address PRE-rename paths) ────
  // Both sides ride through the SAME renderGated() classifier gate as anchor
  // find/replace (a denylisted/frozen/unknown token in a path aborts), then the
  // fail-closed shape/containment/contract guards above.
  let totalRenames = 0;
  for (const r of (recipe.renames || [])) {
    if (!r || typeof r.from !== 'string' || typeof r.to !== 'string') {
      die('each rename needs string `from` + `to`');
    }
    const id = r.id || `${r.from} -> ${r.to}`;
    const label = `recipe ${path.basename(recipePath)} [rename ${id}]`;
    const from = renderGated(r.from, ctx, `${label} (from)`);
    const to = renderGated(r.to, ctx, `${label} (to)`);
    const absFrom = resolveRenameSide(targetDir, from, 'from', id);
    const absTo = resolveRenameSide(targetDir, to, 'to', id);

    if (!fs.existsSync(absFrom)) {
      if (r.required === true) {
        die(`rename '${id}': REQUIRED source '${from}' absent in the target tree (base drift?)`);
      }
      log(`rename skip (absent, optional): ${from}`);
      report.renames.push({ id, from, to, applied: false, required: false });
      continue;
    }
    assertRealUnder(targetDir, absFrom, 'from', id);
    // Files only: a directory rename could silently relocate the deploy/
    // discovery contract or an entire marker-bearing subtree.
    if (!fs.lstatSync(absFrom).isFile()) {
      die(`rename '${id}': source '${from}' is not a regular file — renames[] operates on files only (fail-closed)`);
    }
    if (fs.existsSync(absTo)) {
      die(`rename '${id}': destination '${to}' already exists — refusing to clobber`);
    }
    // Create the destination's parent (inside the tree — containment proven
    // above), then realpath-check IT too (a symlinked parent could escape).
    fs.mkdirSync(path.dirname(absTo), { recursive: true });
    assertRealUnder(targetDir, path.dirname(absTo), 'to (parent)', id);
    fs.renameSync(absFrom, absTo);
    totalRenames++;
    report.renames.push({ id, from, to, applied: true, required: r.required === true });
    log(`rename: ${from} -> ${to}`);
  }

  if (args.report) fs.writeFileSync(path.resolve(args.report), JSON.stringify(report, null, 2));
  log(`applied ${totalHits} anchored edit(s) across ${report.files.length} file(s) + ${totalRenames} rename(s) in ${targetDir}`);
}

main();
