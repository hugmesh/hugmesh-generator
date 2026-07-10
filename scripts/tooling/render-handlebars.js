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
  const out = { templates: null, out: null, extraTokens: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--templates') out.templates = argv[++i];
    else if (a === '--out') out.out = argv[++i];
    // --extra-tokens CSV: ADDITIONAL allowlisted token names to place in the
    // render context, on top of the fixed 7. Used by the Phase-2 repo-tree
    // overlay (templates/repos/login-ui) which references brand-delta tokens
    // beyond the app-CRD set (NPM_SCOPE, HOST_NAME, GENERATOR_ORG_GROUP). When
    // this flag is ABSENT the context is byte-identical to the parity-proven
    // apps path — so scripts/parity-gate.sh is unaffected.
    else if (a === '--extra-tokens') {
      out.extraTokens = (argv[++i] || '')
        .split(',').map((s) => s.trim()).filter(Boolean);
    } else die(`unknown argument: ${a}`);
  }
  if (!out.templates) die('missing --templates DIR');
  if (!out.out) die('missing --out DIR');
  return out;
}

// Build the render context from the environment, allowlist-only.
function buildContext(extraTokens) {
  const keys = [...TOKEN_KEYS, ...(extraTokens || [])];
  const ctx = {};
  for (const k of keys) {
    if (classifier.isDenied(k)) {
      die(`refusing to build context: token '${k}' is on the secret denylist`);
    }
    if (classifier.isFrozen(k)) {
      die(`refusing to build context: token '${k}' targets a FROZEN protocol constant (k8s label-key namespace / wire header / subprotocol prefix) — it must stay literal and can never be templated (red-team gate)`);
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
      // The Phase-2 repo-overlay tree (templates/repos/**) is NOT part of the
      // app-CRD sweep — it has its own dedicated renderer (render-repo-tree.sh,
      // which stages the overlay into a temp dir before calling this). So when
      // sweeping the templates root for the cluster-manifest path, never descend
      // into a `repos` subtree. (Harmless for the overlay/skeleton renders: their
      // --templates root is already inside/below the overlay, with no `repos`
      // child.) This keeps the parity-proven apps render byte-identical.
      if (ent.isDirectory() && ent.name === 'repos') continue;
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

  const ctx = buildContext(args.extraTokens);
  fs.mkdirSync(outDir, { recursive: true });

  const files = listHbs(templatesDir);
  let rendered = 0;
  for (const tmpl of files) {
    const src = fs.readFileSync(tmpl, 'utf8');

    // Fail-closed guardrail: no secret-bearing token may appear in a template,
    // AND every referenced token must be explicitly allowlisted. Handlebars is
    // compiled with strict:false, so an UNKNOWN {{token}} (neither allow- nor
    // deny-listed) would otherwise render to an empty string — silently DROPPING
    // content, whereas the legacy sed path leaves the literal `{{token}}`. Failing
    // closed here keeps the two renderers from diverging on a future token and
    // forces every new token through the classifier.
    for (const tok of referencedTokens(src)) {
      if (classifier.isDenied(tok)) {
        die(`template ${path.relative(templatesDir, tmpl)} references denylisted secret token '{{${tok}}}' — refusing to render`);
      }
      if (classifier.isFrozen(tok)) {
        die(`template ${path.relative(templatesDir, tmpl)} references token '{{${tok}}}' that targets a FROZEN protocol constant (label-key namespace / wire header / subprotocol prefix) — refusing to render (it must stay literal)`);
      }
      if (!classifier.isAllowed(tok)) {
        die(`template ${path.relative(templatesDir, tmpl)} references token '{{${tok}}}' that is neither allowlisted nor denylisted — refusing to render (fail-closed: strict:false would silently emit empty string). Add it to scripts/tooling/tokens.json (allowlist) or remove the reference.`);
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
