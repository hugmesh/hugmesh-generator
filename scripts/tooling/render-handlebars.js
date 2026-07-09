'use strict';
// ============================================================================
// render-handlebars.js — REAL Handlebars renderer for the mesh templating pilot.
// ============================================================================
//
//  >>> BUILD-HOST ONLY. Node MUST NOT run as root on the mesh-node <<<
//  >>> fail-closed root-cron reconcile path (Phase 6). See the         <<<
//  >>> "Node-not-root-on-the-mesh-cron-path" constraint in             <<<
//  >>> docs/MESH-TEMPLATING.md. On the mesh node the reconcile cron    <<<
//  >>> must EITHER run this as a constrained, network-less NON-ROOT     <<<
//  >>> helper OR consume pre-rendered output — never invoke node@root.  <<<
//
// Renders templates/apps/*.hbs with the ACTUAL Handlebars engine (npm
// `handlebars`, installed locally in scripts/tooling/). The existing {{TOKEN}}
// syntax is valid Handlebars; we compile with { noEscape: true } so a bare
// {{TOKEN}} is a raw substitution — byte-for-byte identical to the legacy sed
// renderer in generate-brand-repos.sh (no HTML entity escaping). sed stays the
// DEFAULT; this path is opt-in and gated by scripts/parity-gate.sh.
//
// Context is the 7 brand tokens, supplied via environment (the shell wrapper
// render-handlebars.sh sources the brand .conf and derives HARBOR_PROJECT with
// the SAME slug logic generate-brand-repos.sh uses, so values match exactly):
//   BRAND BRAND_TITLE ORG CLUSTER_DOMAIN HEADSCALE_URL HARBOR_PROJECT MESH_TAG
//
// Guardrails (fail-closed):
//   * every {{token}} referenced by a template is checked against the token
//     classifier; a denylisted (secret-bearing) token aborts the whole render.
//   * only allowlisted tokens are placed in the render context.
//
// Usage:
//   render-handlebars.js --templates DIR --out DIR
//   (tokens read from the environment; see render-handlebars.sh)

const fs = require('fs');
const path = require('path');
const Handlebars = require('handlebars');
const classifier = require('./token-classifier');

const TOKEN_KEYS = [
  'BRAND', 'BRAND_TITLE', 'ORG', 'CLUSTER_DOMAIN',
  'HEADSCALE_URL', 'HARBOR_PROJECT', 'MESH_TAG',
];

function die(msg) {
  process.stderr.write(`[render-handlebars] FATAL: ${msg}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = { templates: null, out: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--templates') out.templates = argv[++i];
    else if (a === '--out') out.out = argv[++i];
    else die(`unknown argument: ${a}`);
  }
  if (!out.templates) die('missing --templates DIR');
  if (!out.out) die('missing --out DIR');
  return out;
}

// Build the render context from the environment, allowlist-only.
function buildContext() {
  const ctx = {};
  for (const k of TOKEN_KEYS) {
    if (classifier.isDenied(k)) {
      die(`refusing to build context: token '${k}' is on the secret denylist`);
    }
    if (!classifier.isAllowed(k)) {
      die(`refusing to build context: token '${k}' is not on the git-safe allowlist`);
    }
    ctx[k] = process.env[k] !== undefined ? process.env[k] : '';
  }
  return ctx;
}

// Extract every {{token}} / {{{token}}} identifier referenced by a template so
// we can fail closed if a secret-bearing token is referenced.
const TOKEN_RE = /\{\{\{?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}?\}\}/g;
function referencedTokens(src) {
  const seen = new Set();
  let m;
  while ((m = TOKEN_RE.exec(src)) !== null) seen.add(m[1]);
  return [...seen];
}

function listHbs(dir) {
  const acc = [];
  (function walk(d) {
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, ent.name);
      if (ent.isDirectory()) walk(full);
      else if (ent.isFile() && ent.name.endsWith('.hbs')) acc.push(full);
    }
  })(dir);
  return acc.sort();
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const templatesDir = path.resolve(args.templates);
  const outDir = path.resolve(args.out);
  if (!fs.existsSync(templatesDir)) die(`templates dir not found: ${templatesDir}`);

  const ctx = buildContext();
  fs.mkdirSync(outDir, { recursive: true });

  const files = listHbs(templatesDir);
  let rendered = 0;
  for (const tmpl of files) {
    const src = fs.readFileSync(tmpl, 'utf8');

    // Fail-closed guardrail: no secret-bearing token may appear in a template.
    for (const tok of referencedTokens(src)) {
      if (classifier.isDenied(tok)) {
        die(`template ${path.relative(templatesDir, tmpl)} references denylisted secret token '{{${tok}}}' — refusing to render`);
      }
    }

    // noEscape:true => bare {{TOKEN}} is a raw substitution == sed parity.
    const tpl = Handlebars.compile(src, { noEscape: true, strict: false });
    const result = tpl(ctx);

    const rel = path.relative(templatesDir, tmpl).replace(/\.hbs$/, '');
    const dst = path.join(outDir, rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.writeFileSync(dst, result);
    rendered++;
  }
  process.stderr.write(`[render-handlebars] rendered ${rendered} template(s) -> ${outDir}\n`);
}

main();
