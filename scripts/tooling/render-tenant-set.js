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
//        --out-dir DIR [--offline] [--only name1,name2] [--ref TAG|SHA]
//
// --ref pins every OWN-MESH base pull to that tag/sha (plumbed through
// render-repo-tree.sh --ref -> pull-repo-base.sh --ref, fail-closed there) and
// stamps each overlay tree's `.hugmesh-base-ref` marker — the versioned
// re-render half of the PR-delivery flow (publish-tenant-set.sh --pr). Foreign
// (origin{}) rows are untouched: their pin stays the immutable digest.
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
// 'generator' (Lane-E/I5): the generator repo ITSELF as a tenant-set member —
// base REQUIRED like a foreign base (no _skeleton: a skeleton generator would be
// a non-functional lie), recipe-only rebrand + the renames[] demo. The tenant's
// hosted copy 13d/GENERATOR_ORG_GROUP always presumed is now actually rendered.
const ARCHETYPES = new Set(['spring-bff', 'angular-mfe', 'gateway', 'generator']);
// RESERVED brand scalars: validated/derived tenant-brand identity that render-
// repo-tree.sh exports (behind DNS/forbidden-char guards) from the signed brand
// .conf. A repos[].identity key is PER-REPO identity, never brand — so an identity
// key that collides with one of these is refused here too (defense in depth; the
// shell script is the hard enforcement point). Mirrors _RESERVED_SCALARS there.
const RESERVED_SCALARS = new Set([
  'BRAND', 'BRAND_TITLE', 'ORG', 'CLUSTER_DOMAIN', 'NPM_SCOPE',
  'HOST_NAME', 'GENERATOR_ORG_GROUP', 'REPO_NAME', 'ORG_SLUG',
  'HEADSCALE_URL', 'MESH_TAG',
]);
// C0 control chars + DEL: a raw newline in an identity value would splice an
// attacker-shaped line into the noEscape-rendered YAML/config. Screened at both
// tiers; the shell --set parser is the backstop.
const CONTROL_RE = /[\x00-\x1f\x7f]/;
// Our token style is {{UPPER_SNAKE}} with no inner spaces — distinct from an
// Angular template's {{ expr() }} interpolation, so this residual scan never
// false-positives on a rendered MFE's own component HTML.
const RESIDUAL_RE = /\{\{[A-Z_][A-Z0-9_]*\}\}/;

function die(msg) { process.stderr.write(`[render-tenant-set] FATAL: ${msg}\n`); process.exit(1); }
function log(msg) { process.stderr.write(`[render-tenant-set] ${msg}\n`); }

function parseArgs(argv) {
  const out = { yaml: null, outDir: './out', offline: false, only: null, ref: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out-dir') out.outDir = argv[++i];
    else if (a === '--offline') out.offline = true;
    else if (a === '--only') out.only = new Set((argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean));
    else if (a === '--ref') out.ref = argv[++i];
    else rest.push(a);
  }
  if (rest.length !== 1) die('usage: render-tenant-set.js brands/<brand>.yaml --out-dir DIR [--offline] [--only a,b] [--ref TAG|SHA]');
  out.yaml = rest[0];
  // Shape-gate here too (defense in depth; render-repo-tree.sh re-validates).
  if (out.ref !== null && !(/^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$/.test(out.ref) && !out.ref.includes('..'))) {
    die(`invalid --ref '${out.ref}' (want a tag/branch/sha: [A-Za-z0-9._/-], no '..')`);
  }
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
      if (RESERVED_SCALARS.has(NAME)) die(`repos[].name '${r.name}': identity key '${k}' collides with reserved brand scalar '${NAME}' — per-repo identity may not override a brand scalar`);
      if (classifier.isDenied(NAME)) die(`repos[].name '${r.name}': identity key '${k}' is on the secret denylist`);
      if (classifier.isFrozen(NAME)) die(`repos[].name '${r.name}': identity key '${k}' targets a FROZEN protocol constant`);
      if (!classifier.isAllowed(NAME)) die(`repos[].name '${r.name}': identity key '${k}' -> token '${NAME}' is not on the git-safe allowlist (add to tokens.json or remove)`);
      const val = String(v);
      if (CONTROL_RE.test(val)) die(`repos[].name '${r.name}': identity value for '${k}' contains a newline/control character — refusing (YAML/config line-injection guard)`);
      if (classifier.isDenied(val)) die(`repos[].name '${r.name}': identity value for '${k}' looks like a denylisted secret — refusing`);
      if (classifier.isFrozen(val)) die(`repos[].name '${r.name}': identity value for '${k}' ('${val}') targets a FROZEN protocol constant — refusing`);
      setArgs.push('--set', `${NAME}=${val}`);
    }

    // Phase 7: optional per-repo FOREIGN origin. repos[].origin = { mesh, digest }
    // marks THIS repo's base as ANOTHER mesh's code, so render-repo-tree.sh resolves
    // it ONLY through the fail-closed inbound ingestion gate (digest-pinned,
    // signature-verified against a pinned pubkey, SBOM/vuln/secret/frozen screened)
    // rather than any unverified own-mesh path. Both fields are attacker-adjacent
    // data: shape-validate HARD, and forward them as A's render-repo-tree.sh flags —
    // --foreign-mesh <mesh> + --pinned-digest <digest> (the pin is MANDATORY there;
    // a foreign base is never taken from a moving ref).
    const foreignArgs = [];
    if (r.origin !== undefined && r.origin !== null) {
      if (typeof r.origin !== 'object' || Array.isArray(r.origin)) die(`repos[].name '${r.name}': origin must be a mapping { mesh, digest }`);
      const mesh = String(r.origin.mesh || '');
      if (!DNS_LABEL.test(mesh)) die(`repos[].name '${r.name}': origin.mesh '${mesh}' is not a DNS label`);
      const digest = String(r.origin.digest || '');
      if (!/^[0-9a-f]{40}$/.test(digest)) die(`repos[].name '${r.name}': origin.digest must be an IMMUTABLE 40-hex commit sha (a foreign base is never taken from a moving ref)`);
      foreignArgs.push('--foreign-mesh', mesh, '--pinned-digest', digest);
    }

    // --ref pins the OWN-MESH pull only; a foreign row's pin is its immutable
    // digest (render-repo-tree.sh refuses the combination, so don't send it).
    const refArgs = (args.ref && foreignArgs.length === 0) ? ['--ref', args.ref] : [];
    const cmd = [
      confPath, '--enable-repo-tree',
      '--repo', r.name, '--archetype', arch,
      '--out-dir', args.outDir,
      ...refArgs,
      ...foreignArgs,
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
