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
  'HEADSCALE_URL', 'HARBOR_PROJECT', 'MESH_TAG', 'NS_PREFIX',
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

// Extract the RAW body of every mustache — i.e. whatever sits between {{ and }},
// NOT just valid {{identifier}} names. This is the reachability fix for the
// Phase-3 red-team gate: the frozen protocol constants (hugmesh.net/…,
// X-HugMesh-Local, snapdragon.device-terminal.stepup.) and some denylisted
// keys are NOT valid Handlebars identifiers (they carry ./ / -), so TOKEN_RE
// above never captures them. A template that literally wrote
// `{{hugmesh.net/domain}}` would therefore slip past the identifier-only
// check and render to an EMPTY string (exit 0) instead of being refused. Scanning
// the raw body lets isFrozen()/isDenied() actually fire on the constants they
// name, so the reference-side gate is reachable — not theater. We do NOT run the
// isAllowed() check here (raw bodies legitimately include {{!}} comments, dotted
// helper paths, etc.); the identifier loop above owns the allowlist gate.
const RAW_MUSTACHE_RE = /\{\{\{?\s*([^{}]*?)\s*\}?\}\}/g;
function referencedRawBodies(src) {
  const seen = new Set();
  let m;
  while ((m = RAW_MUSTACHE_RE.exec(src)) !== null) {
    const body = m[1].trim();
    if (body) seen.add(body);
  }
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
      if (ent.isDirectory() && (ent.name === 'repos' || ent.name === 'archetypes')) continue;
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

    // Fail-closed guardrail (shared with the Phase-4 recipe engine via
    // assertTemplateSafe): no secret-bearing / frozen token may appear in a
    // template, AND every referenced {{identifier}} must be allowlisted.
    // Handlebars is compiled with strict:false, so an UNKNOWN {{token}} would
    // otherwise render to an empty string (silently dropping content) while the
    // legacy sed path leaves the literal `{{token}}`. The raw-body scan inside
    // assertTemplateSafe also catches a frozen constant / secret written as a
    // non-identifier mustache body (e.g. {{hugmesh.net/domain}}).
    try {
      assertTemplateSafe(src, `template ${path.relative(templatesDir, tmpl)}`);
    } catch (e) {
      die(e.message);
    }

    // ArgoCD ApplicationSet Go-template expressions ({{ .repository }}, {{ .url }},
    // {{ .branch }} — any mustache whose body starts with '.') must survive INTO the
    // rendered YAML verbatim for ArgoCD's ApplicationSet controller to evaluate at
    // apply-time. They collide with Handlebars' own {{ }} delimiters: Handlebars would
    // parse/evaluate '.repository' as a context path and (strict:false) drop it to an
    // empty string, DIVERGING from the sed renderer (generate-brand-repos.sh), which
    // leaves them literal because they are not brand {{TOKEN}}s. Protect them behind a
    // sentinel across the Handlebars pass, then restore the EXACT original text so the
    // output is byte-identical to sed (this is what keeps the parity gate green).
    // SAFETY: assertTemplateSafe()'s fail-closed frozen/denied RAW-BODY scan has
    // ALREADY run over these bodies above, so a dot-body naming a frozen constant
    // (e.g. {{ .hugmesh.net/x }}) was refused before we reach here — this
    // passthrough only ever carries inert ArgoCD context refs, never a brand token or
    // a secret value.
    const goTmpl = [];
    const protectedSrc = src.replace(/\{\{\s*\.[^{}]*?\s*\}\}/g, (match) => {
      const sentinel = `@@ARGOCD_GOTMPL_${goTmpl.length}@@`;
      goTmpl.push(match);
      return sentinel;
    });

    // noEscape:true => bare {{TOKEN}} is a raw substitution == sed parity.
    const tpl = Handlebars.compile(protectedSrc, { noEscape: true, strict: false });
    let result = tpl(ctx);
    // Restore the protected ArgoCD Go-template expressions verbatim.
    result = result.replace(/@@ARGOCD_GOTMPL_(\d+)@@/g, (_, i) => goTmpl[Number(i)]);

    const rel = path.relative(templatesDir, tmpl).replace(/\.hbs$/, '');
    const dst = path.join(outDir, rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.writeFileSync(dst, result);
    rendered++;
  }
  process.stderr.write(`[render-handlebars] rendered ${rendered} template(s) -> ${outDir}\n`);
}

// ── Shared, fail-closed template-safety gate ────────────────────────────────
// Exported so the Phase-4 recipe engine (render-recipe.js) runs the EXACT same
// classifier gate over its anchor find/replace strings — single source of truth,
// no forked gate. `label` is a human name for the error (a template path or a
// recipe anchor id). Throws (not process.exit) so callers can decide; the CLI
// wrapper below converts a throw into die()/exit 1.
function assertTemplateSafe(src, label) {
  for (const tok of referencedTokens(src)) {
    if (classifier.isDenied(tok)) {
      throw new Error(`${label} references denylisted secret token '{{${tok}}}' — refusing to render`);
    }
    if (classifier.isFrozen(tok)) {
      throw new Error(`${label} references token '{{${tok}}}' that targets a FROZEN protocol constant (label-key namespace / wire header / subprotocol prefix) — refusing to render (it must stay literal)`);
    }
    if (!classifier.isAllowed(tok)) {
      throw new Error(`${label} references token '{{${tok}}}' that is neither allowlisted nor denylisted — refusing to render (fail-closed). Add it to scripts/tooling/tokens.json (allowlist) or remove the reference.`);
    }
  }
  for (const body of referencedRawBodies(src)) {
    if (classifier.isFrozen(body)) {
      throw new Error(`${label} references '{{${body}}}' that targets a FROZEN protocol constant (label-key namespace / wire header / subprotocol prefix) — refusing to render (it must stay literal)`);
    }
    if (classifier.isDenied(body)) {
      throw new Error(`${label} references denylisted secret token '{{${body}}}' — refusing to render`);
    }
  }
}

module.exports = {
  TOKEN_KEYS,
  buildContext,
  assertTemplateSafe,
  referencedTokens,
  referencedRawBodies,
};

if (require.main === module) main();
