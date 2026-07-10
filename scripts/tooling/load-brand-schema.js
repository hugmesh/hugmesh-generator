'use strict';
// ============================================================================
// load-brand-schema.js — tiny loader for the structured brands/<name>.yaml.
// ============================================================================
//
// BUILD-HOST ONLY (Node + js-yaml). See docs/MESH-TEMPLATING.md re: never running
// node as root on the mesh-node cron path.
//
// Reads a structured brand YAML and DEGRADES it to today's 7 legacy scalars,
// printed as shell `KEY=VALUE` lines on stdout so the existing .conf-sourcing
// path can consume it unchanged:
//
//   eval "$(node scripts/tooling/load-brand-schema.js brands/example.yaml)"
//   # -> BRAND, BRAND_TITLE, ORG, CLUSTER_DOMAIN, RELEASE_STATE, HEADSCALE_URL, MESH_TAG
//
// The .conf path is NOT deleted; this is an additive, shape-compatible bridge.
// HARBOR_PROJECT is intentionally NOT emitted — it stays derived from ORG by the
// shell (single source of the slug rule), exactly as in the scalar path.
//
// Values are single-quoted with POSIX-safe escaping so they are safe to `eval`.

const fs = require('fs');
const yaml = require('js-yaml');

function die(msg) {
  process.stderr.write(`[load-brand-schema] FATAL: ${msg}\n`);
  process.exit(1);
}

// --repos-json: emit the repos[] MANIFEST as a machine-readable JSON sidecar on
// stdout (consumed by the Node driver render-tenant-set.js), instead of the 7
// shell scalars. This is the security boundary from the Phase-4 spec: repos[]
// (list data) is NEVER degraded to shell KEY=VALUE / eval'd on the signed-export
// path — only the 7 scalars are. A crafted repo entry therefore cannot inject
// into the shell-sourced .conf path.
const wantReposJson = process.argv.includes('--repos-json');
const file = process.argv[2];
if (!file) die('usage: load-brand-schema.js <brands/NAME.yaml> [--repos-json]');
if (!fs.existsSync(file)) die(`no such file: ${file}`);

let doc;
try {
  doc = yaml.load(fs.readFileSync(file, 'utf8'));
} catch (e) {
  die(`YAML parse error: ${e.message}`);
}
if (!doc || typeof doc !== 'object') die('empty or non-object YAML');

function req(v, name) {
  if (v === undefined || v === null || v === '') die(`missing required field: ${name}`);
  return v;
}

const brand = req(doc.brand, 'brand');
const title = req(doc.title, 'title');
const org = req(doc.org, 'org');

// repos[] sidecar path — structured JSON only, never shell.
if (wantReposJson) {
  const repos = Array.isArray(doc.repos) ? doc.repos : [];
  process.stdout.write(JSON.stringify(repos, null, 2) + '\n');
  process.exit(0);
}
const domains = doc.domains;
if (!Array.isArray(domains) || domains.length === 0) die('domains[] must be a non-empty list');
const clusterDomain = req(domains[0], 'domains[0]');
const releaseState = doc.release_state || 'internal';
const mesh = doc.mesh || {};
const headscaleUrl = mesh.headscale_url || '';
const meshTag = mesh.tag || '';

// POSIX single-quote escaping: close, insert an escaped quote, reopen.
function sq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

const scalars = {
  BRAND: brand,
  BRAND_TITLE: title,
  ORG: org,
  CLUSTER_DOMAIN: clusterDomain,
  RELEASE_STATE: releaseState,
  HEADSCALE_URL: headscaleUrl,
  MESH_TAG: meshTag,
};

const out = Object.entries(scalars)
  .map(([k, v]) => `${k}=${sq(v)}`)
  .join('\n');
process.stdout.write(out + '\n');
