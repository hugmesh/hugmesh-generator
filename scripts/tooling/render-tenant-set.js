'use strict';
// ============================================================================
// render-tenant-set.js — FULL TENANT-SET instantiation from the repos[] manifest.
// ============================================================================
//
//  >>> BUILD-HOST ONLY. Drives node (Handlebars/recipe engines); MUST NOT run as <<<
//  >>> root on the mesh-node fail-closed root-cron path (Phase 6). See           <<<
//  >>> docs/MESH-TEMPLATING.md, "Node-not-root-on-the-mesh-cron-path".           <<<
//
// ONE command that renders the whole N-repo tenant set for a brand, driven by the
// repos[] manifest in the STRUCTURED brand YAML (brands/<name>.yaml). For each
// `installed:true` repo it resolves the repo -> archetype -> archetype overlay
// (templates/archetypes/<archetype>) and calls render-repo-tree.sh with the
// repo's OWN identity row as --set tokens. A repo whose base is unpullable falls
// to that archetype's _skeleton (two-tier fallback — never refuses).
//
// SECURITY BOUNDARY (Phase-4 spec): repos[] is read here as STRUCTURED data via
// js-yaml and NEVER degraded to shell / eval'd. The 7 scalar brand tokens still
// go through the shell-source path (a temp .conf built by load-brand-schema.js).
// So list data cannot inject on the signed-export shell path. Every identity
// token NAME is fail-closed through the classifier (allow/deny/frozen) and every
// VALUE is screened for a secret/frozen constant before it can reach a render.
//
// Usage:
//   node scripts/tooling/render-tenant-set.js brands/<brand>.yaml \
//        --out-dir DIR [--offline] [--only name1,name2]
//
// Env: <NAME>_BASE_DIR overrides (read-only base clones) + OFFLINE are passed
// through to pull-repo-base.sh per repo. Exit 0 iff every installed repo emitted
// a scanned-clean tree with ZERO residual {{TOKEN}}s.

const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const yaml = require('js-yaml');
const classifier = require('./token-classifier');

const TOOLING = __dirname;
const REPO_ROOT = path.resolve(TOOLING, '..', '..');
const SCRIPTS = path.join(REPO_ROOT, 'scripts');
const ARCHETYPES = new Set(['spring-bff', 'angular-mfe', 'gateway']);
// Our token style is {{UPPER_SNAKE}} with no inner spaces — distinct from an
// Angular template's {{ expr() }} interpolation, so this residual scan never
// false-positives on a rendered MFE's own component HTML.
const RESIDUAL_RE = /\{\{[A-Z_][A-Z0-9_]*\}\}/;

function die(msg) { process.stderr.write(`[render-tenant-set] FATAL: ${msg}\n`); process.exit(1); }
function log(msg) { process.stderr.write(`[render-tenant-set] ${msg}\n`); }

function parseArgs(argv) {
  const out = { yaml: null, outDir: './out', offline: false, only: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out-dir') out.outDir = argv[++i];
    else if (a === '--offline') out.offline = true;
    else if (a === '--only') out.only = new Set((argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean));
    else rest.push(a);
  }
  if (rest.length !== 1) die('usage: render-tenant-set.js brands/<brand>.yaml --out-dir DIR [--offline] [--only a,b]');
  out.yaml = rest[0];
  return out;
}

const DNS_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.yaml)) die(`no such brand YAML: ${args.yaml}`);

  // 1) Degrade the 7 scalars to a temp shell .conf via load-brand-schema.js
  //    (single source of the scalar rule). repos[] is NOT on this path.
  let confBody;
  try {
    confBody = cp.execFileSync('node', [path.join(TOOLING, 'load-brand-schema.js'), args.yaml], { encoding: 'utf8' });
  } catch (e) {
    die(`load-brand-schema.js failed: ${e.stderr || e.message}`);
  }
  const tmpDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'tenant-set-'));
  const confPath = path.join(tmpDir, 'brand.conf');
  fs.writeFileSync(confPath, confBody);
  process.on('exit', () => { try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) {} });

  // 2) Read repos[] as STRUCTURED data (never shell).
  const doc = yaml.load(fs.readFileSync(args.yaml, 'utf8')) || {};
  const repos = Array.isArray(doc.repos) ? doc.repos : [];
  if (repos.length === 0) die('brand YAML has no repos[] manifest');

  const results = [];
  let installed = 0, skipped = 0;

  for (const r of repos) {
    if (!r || typeof r.name !== 'string') die('each repos[] entry needs a string name');
    if (!DNS_LABEL.test(r.name)) die(`repos[].name '${r.name}' is not a DNS label`);
    if (args.only && !args.only.has(r.name)) continue;
    if (r.installed === false) {         // optional-service toggle
      log(`skip (installed:false): ${r.name}`);
      skipped++;
      continue;
    }
    const arch = r.archetype;
    if (!ARCHETYPES.has(arch)) die(`repos[].name '${r.name}': archetype '${arch}' not in {${[...ARCHETYPES].join(', ')}}`);

    // Identity row -> --set NAME=VALUE, fail-closed on NAME (classifier) + VALUE
    // (no secret/frozen constant may ride in as identity data).
    const setArgs = [];
    const identity = r.identity || {};
    for (const [k, v] of Object.entries(identity)) {
      const NAME = String(k).toUpperCase();
      if (!/^[A-Z][A-Z0-9_]*$/.test(NAME)) die(`repos[].name '${r.name}': identity key '${k}' is not a valid token name`);
      if (classifier.isDenied(NAME)) die(`repos[].name '${r.name}': identity key '${k}' is on the secret denylist`);
      if (classifier.isFrozen(NAME)) die(`repos[].name '${r.name}': identity key '${k}' targets a FROZEN protocol constant`);
      if (!classifier.isAllowed(NAME)) die(`repos[].name '${r.name}': identity key '${k}' -> token '${NAME}' is not on the git-safe allowlist (add to tokens.json or remove)`);
      const val = String(v);
      if (classifier.isDenied(val)) die(`repos[].name '${r.name}': identity value for '${k}' looks like a denylisted secret — refusing`);
      if (classifier.isFrozen(val)) die(`repos[].name '${r.name}': identity value for '${k}' ('${val}') targets a FROZEN protocol constant — refusing`);
      setArgs.push('--set', `${NAME}=${val}`);
    }

    const cmd = [
      confPath, '--enable-repo-tree',
      '--repo', r.name, '--archetype', arch,
      '--out-dir', args.outDir,
      ...setArgs,
    ];
    log(`render ${r.name} (archetype=${arch}${setArgs.length ? ', identity ' + setArgs.filter((_, i) => i % 2 === 1).join(' ') : ''})`);
    let stdout;
    try {
      stdout = cp.execFileSync(path.join(SCRIPTS, 'render-repo-tree.sh'), cmd, {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'inherit'],
        env: { ...process.env, OFFLINE: args.offline ? '1' : (process.env.OFFLINE || '0') },
      });
    } catch (e) {
      die(`render-repo-tree.sh failed for '${r.name}' (see log above)`);
    }
    // Last stdout line is MODE\tOUT.
    const last = stdout.trim().split('\n').pop() || '';
    const [mode, outTree] = last.split('\t');
    if (!outTree) die(`render-repo-tree.sh produced no result line for '${r.name}'`);
    results.push({ name: r.name, archetype: arch, mode, out: outTree });
    installed++;
  }

  // 3) Residual {{TOKEN}} sweep across every emitted tree (our token style only).
  let residual = 0;
  const residualHits = [];
  for (const res of results) {
    const files = [];
    (function walk(d) {
      for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
        if (ent.isDirectory()) { if (ent.name === '.git' || ent.name === 'node_modules') continue; walk(path.join(d, ent.name)); }
        else if (ent.isFile()) files.push(path.join(d, ent.name));
      }
    })(res.out);
    for (const f of files) {
      let txt;
      try { txt = fs.readFileSync(f, 'utf8'); } catch (_) { continue; } // skip binaries
      if (RESIDUAL_RE.test(txt)) { residual++; residualHits.push(`${f}`); }
    }
  }

  // 4) Report.
  process.stdout.write('\n== tenant-set render summary ==\n');
  process.stdout.write(`brand YAML   : ${args.yaml}\n`);
  process.stdout.write(`out dir      : ${args.outDir}\n`);
  process.stdout.write(`installed    : ${installed} rendered, ${skipped} toggled-off (installed:false)\n`);
  const byMode = results.reduce((m, r) => ((m[r.mode] = (m[r.mode] || 0) + 1), m), {});
  process.stdout.write(`modes        : ${Object.entries(byMode).map(([k, v]) => `${k}=${v}`).join(', ') || '(none)'}\n`);
  process.stdout.write(`residual {{}}: ${residual}${residual ? ' — ' + residualHits.slice(0, 10).join(', ') : ' (zero)'}\n\n`);
  for (const r of results) process.stdout.write(`  [${r.mode.padEnd(8)}] ${r.name.padEnd(30)} <- ${r.archetype}\n`);
  process.stdout.write('\n');

  if (residual > 0) die(`${residual} residual {{TOKEN}}(s) across the tenant set — refusing`);
  log(`OK: ${installed} repo(s) rendered, 0 residual tokens.`);
}

main();
