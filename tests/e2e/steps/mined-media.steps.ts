// mined-media.steps.ts — step definitions for the `mined-media` domain: the M4
// media + creation surfaces (owncast, tube, wiki, character-studio,
// character-forge) as they are actually implemented, not as the route table
// describes them.
//
// PROVENANCE. Every scenario these steps back was derived from a real branch,
// guard, error path or shipped config file, and every claim was RE-VERIFIED
// against the source before the step was written. Where the mining pass was
// wrong, the scenario was corrected or dropped and the reason is recorded in the
// feature file's header — a dropped false claim is a good outcome.
//
// CONTRACT (features/README.md): Given/When/Then come from './world' and NEVER
// from 'playwright-bdd' — a second createBdd() binds to a different `test`
// instance and the AfterStep evidence hook silently stops firing.
//
// REUSE. Identity, navigation, DOM assertions and the PENDING idiom all come
// from common.steps.ts / moderation-media.steps.ts and are NOT redefined here.
// In particular this file defines NO variant of 'I am signed in as …',
// 'I hold an API session as …', 'I open the path …', 'the element with test id …'
// or 'this scenario is PENDING because …'. bddgen is all-or-nothing: one
// ambiguous step generates ZERO of the suite's scenarios.
//
// ── THREE TIERS OF STEP LIVE HERE, deliberately kept apart ──────────────────
//
//   1. IN-REPO CONTRACT steps. They read artefacts committed to THIS repo
//      (specs/cluster/**, tests/stack/**). They run with every environment DOWN
//      and are the tier that has value on a box where nothing is up.
//
//   2. FLEET-SOURCE CONTRACT steps. They read the SERVICE SOURCE in the sibling
//      hugmesh-* checkouts. Those checkouts are not part of this repo, so the
//      fleet root is resolved (SNAP_FLEET_ROOT, else the parent of the main
//      generator checkout — resolved through .git so a WORKTREE resolves it too)
//      and, when it is not there, the scenario SKIPS NAMING THE VARIABLE AND THE
//      REPOS. It never passes vacuously: once the fleet root IS present, a
//      missing individual file is a hard FAILURE, because that is a repo rename
//      or a deleted mirror and is exactly what these scenarios exist to catch.
//
//   3. DRIVEN steps (HTTP against a live mesh). Every feature using one is
//      tagged `@env:docker`, so world.ts's Before hook probes the door with a
//      real request and skips with a reason naming `make stack-up ENV=test`
//      when nothing answers. No step here starts anything.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Given, When, Then } from './world';
import { service } from './dimensions';

/** Repo root — steps/ is tests/e2e/steps, so three levels up. */
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

// ═══════════════════════════════════════════════════════════════════════════
// TIER 1 — reading THIS repo
// ═══════════════════════════════════════════════════════════════════════════

/** Read a committed artefact of this repo, or fail naming the absolute path.
 *  A missing source file must never degrade into a soft skip that leaves the
 *  contract unasserted. */
function readRepoFile(rel: string): string {
  const abs = path.join(REPO_ROOT, rel);
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the committed artefact ${abs}: ${(e as Error).message}. `
      + `The mined-media contract scenarios assert what the generator actually SHIPS; `
      + `refusing to pass without reading it.`,
    );
  }
}

/** Every file under a directory of this repo, recursively (for a manifest sweep). */
function walkRepo(rel: string): string[] {
  const abs = path.join(REPO_ROOT, rel);
  const out: string[] = [];
  const visit = (dir: string): void => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) visit(p);
      else out.push(p);
    }
  };
  if (fs.existsSync(abs)) visit(abs);
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// TIER 2 — reading the SIBLING service checkouts
// ═══════════════════════════════════════════════════════════════════════════

/**
 * The directory that holds the sibling `hugmesh-*` checkouts.
 *
 * WHY THIS IS NOT JUST `dirname(REPO_ROOT)`. The Gherkin lane is authored in
 * git WORKTREES that live outside the fleet directory entirely (this one is
 * under /var/tmp/portage), so the parent of the checkout is the wrong answer
 * there. `.git` in a worktree is a FILE holding `gitdir: <main>/.git/worktrees/<name>`,
 * so the main checkout — and therefore the fleet directory — is recoverable
 * without shelling out to git.
 *
 * A candidate is accepted only when it actually LOOKS like the fleet (three or
 * more `hugmesh-` entries). Accepting a directory that merely exists would make
 * every mirror assertion below fail for the wrong reason.
 */
function fleetRootCandidates(): string[] {
  const out: string[] = [];
  if (process.env.SNAP_FLEET_ROOT) out.push(path.resolve(process.env.SNAP_FLEET_ROOT));
  // The .git-derived candidate is tried BEFORE the checkout's own parent, and that
  // order was learned the hard way: this lane is authored in a worktree under
  // /var/tmp/portage, whose parent holds hugmesh-qemu*, hugmesh-mainline-verify …
  // — four directories starting with 'hugmesh-' and not one of them a service
  // checkout. A "looks like the fleet" test that counted prefixes accepted it, and
  // every mirror assertion then failed with "the fleet root IS present", which is
  // the worst possible message: a real failure for a fake reason.
  try {
    const dotGit = fs.readFileSync(path.join(REPO_ROOT, '.git'), 'utf8');
    const m = /gitdir:\s*(.+)/.exec(dotGit);
    if (m) {
      // <main>/.git/worktrees/<name>  ->  <main>  ->  dirname(<main>)
      const wt = m[1].trim();
      const mainGit = wt.replace(/\/worktrees\/[^/]+\/?$/, '');
      const mainRepo = path.dirname(mainGit);
      out.push(path.dirname(mainRepo));
    }
  } catch { /* a normal checkout: .git is a directory; the parent below covers it */ }
  out.push(path.dirname(REPO_ROOT));
  return [...new Set(out)];
}

/**
 * The service checkouts every scenario in this domain reads. A candidate must
 * hold ALL of them: a directory with SOME of them is a partial fleet, and
 * accepting it would turn "this repo is not here" into a mirror-drift failure.
 * Named individually so the skip reason can list exactly what to clone.
 */
const FLEET_REPOS = [
  'hugmesh-character-forge-bff-api',
  'hugmesh-user-bff-api',
  'hugmesh-wiki-bff-api',
  'hugmesh-owncast-bff-api',
  'hugmesh-matrix-ui',
  'hugmesh-games',
];

function looksLikeFleet(dir: string): boolean {
  return FLEET_REPOS.every((r) => {
    try { return fs.statSync(path.join(dir, r)).isDirectory(); } catch { return false; }
  });
}

let fleetRootCache: string | null | undefined;

function findFleetRoot(): string | null {
  if (fleetRootCache !== undefined) return fleetRootCache;
  fleetRootCache = fleetRootCandidates().find(looksLikeFleet) ?? null;
  return fleetRootCache;
}

/** The reason string a fleet-source scenario skips with. Names the variable AND
 *  where it looked, so the reader does not have to open this file to find out. */
function fleetSkipReason(): string {
  return 'the sibling service checkouts are not on this host, so the cross-repo source '
    + `contract cannot be read. Needs ALL of: ${FLEET_REPOS.join(', ')}. `
    + 'Set SNAP_FLEET_ROOT=<the directory holding them>, or run this lane from a checkout '
    + `that sits beside them. Looked in: ${fleetRootCandidates().join(', ')}.`;
}

interface HasSkip { skip(condition: boolean, description: string): void }

/** Resolve the fleet root or SKIP LOUDLY. Never returns a bogus path. */
function fleetRoot($testInfo: HasSkip): string {
  const root = findFleetRoot();
  if (!root) $testInfo.skip(true, fleetSkipReason());
  return root as string;
}

/**
 * Read a file from a sibling checkout. Called only AFTER {@link fleetRoot} has
 * established the fleet is present, so a miss here is a REAL failure — a renamed
 * repo, a moved file or a deleted mirror — and is reported as one.
 */
function readFleetFile($testInfo: HasSkip, rel: string): string {
  const abs = path.join(fleetRoot($testInfo), rel);
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch (e) {
    throw new Error(
      `${abs} is missing (${(e as Error).message}), but the fleet root IS present. `
      + `This is not an environment gap: a mirror that has moved or been deleted is `
      + `exactly the drift this scenario exists to catch. Fix the path here or restore `
      + `the file — do NOT soften this into a skip.`,
    );
  }
}

/** Drop whole-line comments so a mention inside prose can never satisfy — or
 *  defeat — an assertion about code. Handles //, #, ## and javadoc continuation
 *  lines, which is every language this file parses. */
function stripCommentLines(src: string): string {
  return src.split('\n')
    .filter((l) => !/^\s*(\/\/|\/\*|\*|#)/.test(l))
    .join('\n');
}

/** The balanced `{…}` or `(…)` region that opens after `anchor`. */
function balancedAfter(src: string, anchor: string): string {
  const at = src.indexOf(anchor);
  if (at < 0) throw new Error(`anchor ${JSON.stringify(anchor)} not found`);
  let i = at + anchor.length;
  while (i < src.length && src[i] !== '{' && src[i] !== '(') i += 1;
  if (i >= src.length) throw new Error(`no '{' or '(' follows ${JSON.stringify(anchor)}`);
  const open = src[i];
  const close = open === '{' ? '}' : ')';
  let depth = 0;
  const start = i;
  for (; i < src.length; i += 1) {
    if (src[i] === open) depth += 1;
    else if (src[i] === close) {
      depth -= 1;
      if (depth === 0) return src.slice(start + 1, i);
    }
  }
  throw new Error(`unbalanced ${open} after ${JSON.stringify(anchor)}`);
}

// ═══════════════════════════════════════════════════════════════════════════
// OWNCAST — the media endpoint is dark by default   (contract tier)
// ═══════════════════════════════════════════════════════════════════════════

const OWNCAST_APP_YML =
  'hugmesh-owncast-bff-api/src/main/resources/application.yml';
const OWNCAST_RESOLVER =
  'hugmesh-owncast-bff-api/src/main/java/net/hugmesh/owncastbff/stream/'
  + 'OwncastPlaybackUrlResolver.java';

/**
 * The shipped config must bind the property to an env placeholder with an EMPTY
 * default — `"${VAR:}"`. That single colon is the whole "dark by default"
 * posture: `"${VAR:https://…}"` would ship every mesh a live media endpoint.
 */
Then(
  'the owncast bff config declares {string} as an empty-defaulted env placeholder',
  async ({ $testInfo }, property: string) => {
    const src = readFleetFile($testInfo, OWNCAST_APP_YML);
    // The property is a dotted path; the yml nests it. Assert on the LEAF plus the
    // placeholder, which is what actually decides the value.
    const leaf = property.split('.').pop() as string;
    const re = new RegExp(`^\\s*${leaf}:\\s*"?\\$\\{([A-Z0-9_]+):(.*?)\\}"?\\s*$`, 'm');
    const m = re.exec(src);
    expect(
      m,
      `${OWNCAST_APP_YML} declares no '${leaf}:' bound to an \${ENV:default} placeholder. `
      + `The in-platform HLS player is meant to be DARK until an operator opts in; a `
      + `hard-coded template ships every mesh a live media endpoint.`,
    ).not.toBeNull();
    expect(
      m![2],
      `${leaf} defaults to '${m![2]}' rather than the empty string, so an un-opted-in mesh `
      + `resolves a real playback URL. The empty default IS the dark-by-default rule.`,
    ).toBe('');
    $testInfo.annotations.push({ type: 'owncast-playback-env', description: m![1] });
  },
);

/** Nothing this generator deploys may set the variable, or "dark by default" is
 *  a property of the BFF alone and not of the mesh the generator produces. */
Then('no generator manifest sets the environment variable {string}',
  async ({}, variable: string) => {
    const hits: string[] = [];
    for (const abs of [...walkRepo('specs/cluster'), ...walkRepo('tests/stack')]) {
      let text: string;
      try { text = fs.readFileSync(abs, 'utf8'); } catch { continue; }
      if (!text.includes(variable)) continue;
      for (const line of text.split('\n')) {
        // Comment lines are stripped: a manifest may legitimately DOCUMENT the
        // variable in prose without setting it, and counting that would make the
        // assertion fail for a reason that is not a posture change.
        if (/^\s*(#|\/\/)/.test(line)) continue;
        if (line.includes(variable)) hits.push(`${path.relative(REPO_ROOT, abs)}: ${line.trim()}`);
      }
    }
    expect(
      hits,
      `${variable} IS set by the generator:\n  ${hits.join('\n  ')}\n`
      + `That flips the in-platform player ON for every mesh this generator builds. If that `
      + `is now the intent, this scenario is the prompt to promote the owncast player-state `
      + `scenarios out of their PENDING block — do not simply delete this row.`,
    ).toEqual([]);
  });

/**
 * The resolver's own early return. Asserted from SOURCE rather than by
 * re-implementing the formatting in TypeScript: a TS re-implementation would be a
 * SIXTH copy of the rule and could agree with itself while the Java drifted.
 */
Then('the owncast playback resolver returns nothing when its template is empty',
  async ({ $testInfo }) => {
    const src = stripCommentLines(readFleetFile($testInfo, OWNCAST_RESOLVER));
    const body = balancedAfter(src, 'public String resolve(');
    expect(
      body,
      `OwncastPlaybackUrlResolver.resolve() no longer guards on an empty template. `
      + `Without that guard an un-configured mesh formats a URL out of an empty string and `
      + `hands the UI a playable-looking link into nowhere.`,
    ).toMatch(/template\s*\.\s*isEmpty\s*\(\s*\)/);
    expect(
      body,
      `resolve() reaches its return without a null path for the empty-template case.`,
    ).toMatch(/return\s+null\s*;/);
  });

// ═══════════════════════════════════════════════════════════════════════════
// TUBE — what the DEPLOYED media gate actually enforces   (in-repo, offline)
// ═══════════════════════════════════════════════════════════════════════════

const OPTIONAL_SERVICES_YAML = 'specs/cluster/optional-services.yaml';
const TUBE_DEPLOYMENT = 'specs/cluster/manifests/tube/deployment.yaml';

/**
 * The optional-services catalogue's `routeAccessRows` are what the generator
 * turns into gateway grants. Asserting the row for a CONTENT prefix (rather than
 * a BFF prefix) is the check that the media plane is a first-class reserved
 * route and not an afterthought reachable only by accident.
 */
Then(
  'the optional-service catalogue routes {string} on the {string} gateway for the {string} service',
  async ({}, pattern: string, gateway: string, slug: string) => {
    const text = readRepoFile(OPTIONAL_SERVICES_YAML);
    // Slice the catalogue entry for this slug: from `- slug: <x>` to the next
    // `- slug:` at the same list level. A file-wide grep would let ANOTHER
    // service's row satisfy this one.
    const start = text.indexOf(`- slug: ${slug}\n`);
    expect(
      start,
      `${OPTIONAL_SERVICES_YAML} has no '- slug: ${slug}' entry.`,
    ).toBeGreaterThanOrEqual(0);
    const rest = text.slice(start + 1);
    const nextAt = rest.indexOf('\n    - slug: ');
    const entry = nextAt < 0 ? rest : rest.slice(0, nextAt);
    const rows = [...entry.matchAll(
      /-\s*\{\s*gateway:\s*([A-Za-z0-9-]+)\s*,\s*urlPattern:\s*(\S+?)\s*\}/g,
    )].map((m) => `${m[1]} ${m[2]}`);
    expect(
      rows,
      `the '${slug}' catalogue entry seeds no route-access row for '${pattern}' on `
      + `'${gateway}'. The gateways are DEFAULT-DENY, so a content prefix with no row is a `
      + `403 for everyone and the media plane is unreachable however healthy the sidecar is. `
      + `Rows present: ${rows.length ? rows.join(' | ') : '<none>'}`,
    ).toContain(`${gateway} ${pattern}`);
  },
);

/** A named container in the tube Deployment, mounting the content tree. */
Then('the tube deployment declares a {string} sidecar serving {string}',
  async ({}, container: string, prefix: string) => {
    const text = readRepoFile(TUBE_DEPLOYMENT);
    expect(
      text,
      `${TUBE_DEPLOYMENT} declares no container named '${container}'. The signed-URL gate `
      + `lives in that sidecar's nginx config; with no sidecar there is no gate at all.`,
    ).toMatch(new RegExp(`^\\s*-\\s*name:\\s*${container}\\s*$`, 'm'));
    // The location may be a LITERAL prefix or a regex capture — main's enforced
    // gate matches `location ~ ^/tube/content(?<media_path>/[A-Za-z0-9._/-]+)$`
    // so it can hand the path to the verifier. Asserting the literal spelling
    // would fail on a config that serves exactly the same tree.
    const bare = prefix.replace(/\/$/, '');
    const locations = nginxConf().split('\n').filter((l) => /^\s*location\b/.test(l));
    expect(
      locations.length,
      `the '${container}' nginx config declares NO location block at all, so it serves `
      + `nothing and every assertion about the gate below would be vacuous.`,
    ).toBeGreaterThan(0);
    expect(
      locations.some((l) => l.includes(bare)),
      `the '${container}' nginx config declares no location covering '${prefix}'. Its `
      + `location lines are:\n  ${locations.map((l) => l.trim()).join('\n  ')}`,
    ).toBe(true);
  });

/** The ConfigMap's `default.conf` block, verbatim. */
let nginxConfCache: string | undefined;

function nginxConf(): string {
  if (nginxConfCache !== undefined) return nginxConfCache;
  const lines = readRepoFile(TUBE_DEPLOYMENT).split('\n');
  const at = lines.findIndex((l) => /^\s*default\.conf:\s*\|/.test(l));
  if (at < 0) {
    throw new Error(
      `${TUBE_DEPLOYMENT} carries no 'default.conf: |' block, so the tube-media gate `
      + `cannot be read. The ConfigMap shape changed — fix this reader rather than letting `
      + `every gate assertion pass against an empty string.`,
    );
  }
  const indent = (lines[at].match(/^\s*/) as RegExpMatchArray)[0].length;
  const out: string[] = [];
  for (let i = at + 1; i < lines.length; i += 1) {
    const l = lines[i];
    if (l.trim() === '') { out.push(''); continue; }
    if ((l.match(/^\s*/) as RegExpMatchArray)[0].length <= indent) break;
    out.push(l);
  }
  nginxConfCache = out.join('\n');
  return nginxConfCache;
}

/** The gate that IS shipped: a presence check on one query parameter. */
/**
 * WAS THE TRIPWIRE — "this asserts an ABSENCE, and it is meant to FAIL one day".
 * It did. The sidecar is wired to the BFF, so what is worth asserting now is the
 * SHAPE that makes the wiring a gate: an `internal` authoriser (unreachable from
 * outside nginx) and the subrequest ahead of the alias, so there is no second,
 * weaker path to the bytes.
 */
Then('the tube-media nginx config keeps its auth_request target internal and ahead of the alias',
  async ({}) => {
    const conf = nginxConf();
    const target = /auth_request\s+(\/[A-Za-z0-9_./-]+)\s*;/.exec(conf);
    expect(target, 'no auth_request directive in the tube-media nginx config').not.toBeNull();
    const name = target![1];
    const block = new RegExp(`location\\s*=\\s*${name}\\s*\\{([^}]*)\\}`);
    const body = block.exec(conf);
    expect(
      body,
      `the auth_request target '${name}' has no 'location = ${name} { ... }' block, so the `
      + `subrequest 404s and nginx fails the request for the wrong reason.`,
    ).not.toBeNull();
    expect(
      body![1],
      `the auth_request target '${name}' is not 'internal', so a caller can reach the `
      + `authoriser directly instead of the content it authorises.`,
    ).toMatch(/\binternal\s*;/);
    const at = conf.indexOf('auth_request ');
    const alias = conf.indexOf('alias ');
    expect(alias, 'the tube-media nginx config aliases nothing, so it serves no content')
      .toBeGreaterThan(-1);
    expect(
      at < alias,
      `the alias at offset ${alias} is reached before the auth_request at ${at}: the bytes `
      + `are served without waiting for the verifier.`,
    ).toBe(true);
  });

Then('the tube-media nginx config issues an auth_request subrequest to the tube bff verify route',
  async ({}) => {
    expect(
      nginxConf(),
      `no auth_request directive in the tube-media nginx config.`,
    ).toMatch(/auth_request\s+\//);
    expect(
      nginxConf(),
      `the auth_request target does not proxy to the tube BFF's verify route.`,
    ).toMatch(/proxy_pass[^;]*\/bff\/tube\/media\/verify/);
  });

// ═══════════════════════════════════════════════════════════════════════════
// CHARACTER PALETTE — one canonical table, five mirrors   (fleet source)
// ═══════════════════════════════════════════════════════════════════════════

const FORGE = 'hugmesh-character-forge-bff-api';
const VALIDATOR =
  `${FORGE}/src/main/java/net/hugmesh/characterforgebff/character/Char3DConfigValidator.java`;
const CONTRACT_FIXTURE =
  `${FORGE}/frontend/src/app/character-forge/contract/server-contract.fixtures.json`;

/**
 * Pull a `region -> #hex` table out of ANY of the four languages this palette is
 * spelled in (Java `Map.of("k","#v")`, TS/JSON `k: '#v'`, GDScript `"k": "#v"`).
 * Comment lines are stripped FIRST, because every one of these files documents
 * the constant above its declaration and the word DEFAULT_MATERIALS appears in
 * that prose before it appears in code.
 */
function paletteIn(src: string, anchors: string[]): Record<string, string> {
  const clean = stripCommentLines(src);
  const anchor = anchors.find((a) => clean.includes(a));
  if (!anchor) {
    throw new Error(
      `none of [${anchors.join(', ')}] appears in this file OUTSIDE its comments, so it `
      + `declares no palette. A mirror that has been renamed is drift, not a parser bug — `
      + `but if the spelling legitimately changed, update the anchor list here.`,
    );
  }
  const body = balancedAfter(clean, anchor);
  const out: Record<string, string> = {};
  const re = /(?:"([A-Za-z_][A-Za-z0-9_]*)"|'([A-Za-z_][A-Za-z0-9_]*)'|\b([A-Za-z_][A-Za-z0-9_]*)\b)\s*[:,]\s*['"](#[0-9a-fA-F]{3,8})['"]/g;
  for (const m of body.matchAll(re)) {
    out[(m[1] ?? m[2] ?? m[3]) as string] = (m[4] as string).toLowerCase();
  }
  if (Object.keys(out).length === 0) {
    throw new Error(
      `parsed ZERO region->colour pairs out of the '${anchor}' table. An empty table would `
      + `make this comparison vacuously true, so this throws instead.`,
    );
  }
  return out;
}

/** The authority: Char3DConfigValidator.DEFAULT_MATERIALS. */
function authorityPalette($testInfo: HasSkip): Record<string, string> {
  return paletteIn(readFleetFile($testInfo, VALIDATOR), ['DEFAULT_MATERIALS']);
}

Then('the character palette declared in {string} matches the Char3DConfigValidator authority',
  async ({ $testInfo }, rel: string) => {
    const authority = authorityPalette($testInfo);
    const mirror = paletteIn(
      readFleetFile($testInfo, rel), ['DEFAULT_MATERIALS', '"defaultMaterials"'],
    );
    expect(
      mirror,
      `${rel} disagrees with Char3DConfigValidator.DEFAULT_MATERIALS. The five copies MUST `
      + `be byte-identical: a stored definition may carry null for a region it never set, and `
      + `each surface resolves that against its OWN copy — so a divergence renders ONE `
      + `character in two different colour schemes depending on which surface drew it. This `
      + `mirror was once "a neutral grey ramp of its own invention" and that is the bug. Change `
      + `the validator, then all five.`,
    ).toEqual(authority);
  });

/**
 * The anti-drift half. Counts DECLARATIONS across the whole fleet, so a SIXTH
 * surface inventing its own ramp fails here instead of quietly shipping.
 * Declaration = a NON-comment line binding the name, which is why a mention in
 * prose (there are several) and a mere USE (`DEFAULT_MATERIALS[region]`) do not
 * count.
 */
Then('the fleet declares exactly {int} mirrors of the character palette',
  async ({ $testInfo }, expected: number) => {
    const root = fleetRoot($testInfo);
    const exts = new Set(['.ts', '.js', '.mjs', '.json', '.java', '.gd', '.py', '.cs']);
    // WHAT IS EXCLUDED AND WHY IT IS NOT A LOOPHOLE. Every entry here is either a
    // package manager's tree, a compiler's output, or a build sysroot. MEASURED,
    // not guessed: with only the obvious excludes this walk touched 438,121 files
    // and 6.7 GB (hugmesh-generator/out/ holds whole device SYSROOTS, including a
    // 12 MB vulkan validusage.json) and the scenario blew its 90s timeout; with
    // these it touches 10,868 files and 100 MB in 0.2s. A palette declaration
    // cannot live in a build artefact — if it did, deleting the artefact would
    // delete the mirror.
    const skipDirs = new Set([
      'node_modules', '.git', 'dist', 'build', 'target', '.angular', '.uidist',
      'coverage', 'out', 'out-tsc', '.nx', '.cache', '.stack-src', 'sysroot',
      'test-results', 'playwright-report', '.godot', '.import', 'vendor',
      '.venv', 'venv', '__pycache__',
    ]);
    // A source file this large is a generated blob. Counted and REPORTED rather
    // than silently passed over, because an unreported skip in a census is how a
    // census starts lying.
    const MAX_SCAN_BYTES = 512 * 1024;
    let oversize = 0;
    const decl = /^[^\n]*?(\bDEFAULT_MATERIALS\b\s*(?::=|=|:)|"defaultMaterials"\s*:)/;
    const found: string[] = [];
    const visit = (dir: string): void => {
      let entries: fs.Dirent[];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (e.isDirectory()) {
          if (!skipDirs.has(e.name)) visit(path.join(dir, e.name));
          continue;
        }
        if (!exts.has(path.extname(e.name))) continue;
        const abs = path.join(dir, e.name);
        try {
          if (fs.statSync(abs).size > MAX_SCAN_BYTES) { oversize += 1; continue; }
        } catch { continue; }
        let text: string;
        try { text = fs.readFileSync(abs, 'utf8'); } catch { continue; }
        if (!text.includes('EFAULT_MATERIALS') && !text.includes('defaultMaterials')) continue;
        for (const line of stripCommentLines(text).split('\n')) {
          if (decl.test(line)) { found.push(path.relative(root, abs)); break; }
        }
      }
    };
    for (const e of fs.readdirSync(root, { withFileTypes: true })) {
      if (e.isDirectory() && e.name.startsWith('hugmesh-')) visit(path.join(root, e.name));
    }
    const mirrors = found.filter((f) => !f.endsWith(path.basename(VALIDATOR))).sort();
    expect(
      mirrors,
      `the fleet declares ${mirrors.length} palette mirror(s), not ${expected}:\n  `
      + `${mirrors.join('\n  ')}\nA NEW copy must be added to this scenario's Examples table `
      + `(so it is compared to the authority) in the same change that creates it; a copy `
      + `nobody compares is how the grey-ramp divergence happened the first time.`,
    ).toHaveLength(expected);
    $testInfo.annotations.push({ type: 'palette-mirrors', description: mirrors.join(', ') });
    $testInfo.annotations.push({
      type: 'palette-census-skipped-oversize',
      description: `${oversize} candidate file(s) over ${MAX_SCAN_BYTES} bytes were not read`,
    });
  });

/**
 * The other locked vocabularies travel with the palette. The shared fixture is
 * the ONLY place all of them are stated once, and three consumers read it — so a
 * fixture that has drifted from the validator silently blesses the drift in all
 * three.
 */
const VOCABULARY_CONSTANT: Record<string, string> = {
  families: 'FAMILIES',
  styles: 'STYLES',
  expressions: 'EXPRESSIONS',
  packIds: 'PACK_IDS',
  partKeys: 'PART_KEYS',
  materialKeys: 'MATERIAL_KEYS',
  maxDefinitionBytes: 'MAX_DEFINITION_BYTES',
  maxNameLength: 'MAX_NAME_LENGTH',
  maxSourceSlots: 'MAX_SOURCE_SLOTS',
  maxSourcePalette: 'MAX_SOURCE_PALETTE',
};

/** `List.of("a","b")` -> the strings; `= 16 * 1024;` -> 16384. */
function validatorConstant(src: string, name: string): string[] | number {
  const clean = stripCommentLines(src);
  const at = clean.indexOf(` ${name} `);
  if (at < 0) throw new Error(`Char3DConfigValidator declares no constant '${name}'`);
  const line = clean.slice(at, clean.indexOf(';', at));
  if (line.includes('List.of')) {
    const body = balancedAfter(line, 'List.of');
    const items = [...body.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
    if (items.length === 0) throw new Error(`parsed ZERO items out of ${name}`);
    return items;
  }
  const rhs = line.slice(line.indexOf('=') + 1).trim();
  const factors = rhs.split('*').map((s) => Number(s.trim()));
  if (factors.some((n) => !Number.isFinite(n))) {
    throw new Error(`cannot evaluate ${name} = ${rhs} — extend this reader, do not guess`);
  }
  return factors.reduce((a, b) => a * b, 1);
}

Then('the shared character contract fixture pins the validator vocabulary {string}',
  async ({ $testInfo }, key: string) => {
    const constant = VOCABULARY_CONSTANT[key];
    expect(
      constant,
      `'${key}' is not a vocabulary this step knows. Legal keys: `
      + `${Object.keys(VOCABULARY_CONSTANT).join(', ')}.`,
    ).toBeDefined();
    const fixture = JSON.parse(readFleetFile($testInfo, CONTRACT_FIXTURE));
    const contract = fixture.serverContract ?? fixture;
    expect(
      Object.prototype.hasOwnProperty.call(contract, key),
      `${CONTRACT_FIXTURE} serverContract carries no '${key}'. Three consumers read this `
      + `fixture; a key that vanished stops being asserted anywhere at all.`,
    ).toBe(true);
    expect(
      contract[key],
      `serverContract.${key} disagrees with Char3DConfigValidator.${constant}. The fixture is `
      + `a MIRROR of the validator, and it is the mirror the Angular karma spec, the Java `
      + `ClientContractFixturesTest and the Godot run_tests.gd all compare THEMSELVES to — so a `
      + `drifted fixture blesses the drift in three places at once.`,
    ).toEqual(validatorConstant(readFleetFile($testInfo, VALIDATOR), constant));
  });

// ═══════════════════════════════════════════════════════════════════════════
// UPLOAD-SERVE POSTURE — three upload paths, compared   (fleet source)
// ═══════════════════════════════════════════════════════════════════════════

interface UploadSurface { file: string; note: string }

const UPLOAD_SURFACES: Record<string, UploadSurface> = {
  'profile-avatar': {
    file: 'hugmesh-user-bff-api/src/main/java/net/hugmesh/userbff/profile/ProfileController.java',
    note: 'the mesh avatar: magic-byte sniffed, the SNIFFED type is what is stored and served',
  },
  'character-part': {
    file: 'hugmesh-user-bff-api/src/main/java/net/hugmesh/userbff/character/'
        + 'CharacterPartController.java',
    note: 'the drawn SVG part: sanitized, stored PENDING, served under a fixed image/svg+xml',
  },
  'wiki-attachment': {
    file: 'hugmesh-wiki-bff-api/src/main/java/net/hugmesh/wikibff/wiki/'
        + 'WikiAttachmentController.java',
    note: 'the wiki attachment: the CLIENT-declared Content-Type is stored and echoed back',
  },
};

function uploadSurface(id: string): UploadSurface {
  const s = UPLOAD_SURFACES[id];
  if (!s) {
    throw new Error(
      `unknown upload surface '${id}'. Legal surfaces: ${Object.keys(UPLOAD_SURFACES).join(', ')}.`,
    );
  }
  return s;
}

/**
 * Where the served Content-Type comes from, DERIVED from the controller source
 * rather than tabulated here — so a surface that grows a sniff, or loses one,
 * flips this answer instead of quietly keeping the label the table used to carry.
 *
 * THE RESOLUTION IS ORDERED, and the order is the AUTHORITY order, not a
 * convenience. Measured while writing this: ProfileController matches BOTH the
 * sniff signature and the raw getContentType() one, because it reads the client
 * header for a cheap "does this even CLAIM to be an image" pre-gate and then
 * throws that value away — the SNIFFED type is what it stores and serves. An
 * "exactly one signature may match" rule therefore failed on the correctly
 * hardened controller. A server-side sniff exists only to override the header, so
 * where one is present it IS the answer; a server-FIXED literal type outranks a
 * client-declared one for the same reason.
 *
 * Every signature that matched is reported in the failure message, so a reader
 * sees what the file actually contains rather than just the verdict.
 */
function typeSourceOf($testInfo: HasSkip, id: string): string {
  const src = stripCommentLines(readFleetFile($testInfo, uploadSurface(id).file));
  const signatures: Array<[string, boolean]> = [
    ['server-sniffed', /ImageSniffer\s*\.\s*detect\s*\(/.test(src)],
    ['server-fixed', /MediaType\s*\.\s*valueOf\s*\(\s*"[a-z]+\/[a-z0-9+.-]+"\s*\)/.test(src)],
    ['client-declared',
      /headers\s*\(\s*\)\s*\.\s*getContentType\s*\(\s*\)/.test(src)
      && /parseMediaType\s*\(/.test(src)],
  ];
  const present = signatures.filter(([, hit]) => hit).map(([name]) => name);
  if (present.length === 0) {
    throw new Error(
      `${uploadSurface(id).file} carries NONE of the three content-type signatures this step `
      + `knows. The controller's shape changed; update this reader rather than letting the `
      + `comparison decide on a guess.`,
    );
  }
  typeSourceDetail.set(id, present.join(' + '));
  return present[0];
}

/** Every signature the last resolution saw, for the failure message. */
const typeSourceDetail = new Map<string, string>();

Then('the {string} upload path takes its served Content-Type from {string}',
  async ({ $testInfo }, id: string, expected: string) => {
    expect(
      typeSourceOf($testInfo, id),
      `${uploadSurface(id).file} (${uploadSurface(id).note}) no longer derives its served `
      + `Content-Type from '${expected}' — signatures present: `
      + `${typeSourceDetail.get(id)}. The three upload paths in this estate deliberately `
      + `differ, and the differences are the contract — an unnoticed convergence on `
      + `'client-declared' is a stored-XSS gap, and an unnoticed convergence on `
      + `'server-sniffed' silently breaks the sanitized-SVG part path.`,
    ).toBe(expected);
  });

/**
 * A response header set on the SERVE side, read out of the controller source.
 * `absent` is a first-class expected value: the whole point of the comparison is
 * that one of these three surfaces sets fewer headers than the other two.
 */
Then('the {string} upload path serves stored bytes with the {string} header {string}',
  async ({ $testInfo }, id: string, header: string, expected: string) => {
    const raw = readFleetFile($testInfo, uploadSurface(id).file);
    const src = stripCommentLines(raw);
    const m = new RegExp(`\\.header\\(\\s*"${header}"\\s*,\\s*([A-Za-z_0-9]+|"[^"]*")\\s*\\)`)
      .exec(src);
    if (!m) {
      expect(
        'absent',
        `${uploadSurface(id).file} sets NO '${header}' on the serve path, but this row expects `
        + `${JSON.stringify(expected)}.`,
      ).toBe(expected);
      return;
    }
    // A constant reference (SVG_CSP) is resolved from its own declaration in the
    // same file, so the assertion reads the VALUE and not the identifier.
    let value = m[1];
    if (!value.startsWith('"')) {
      const c = new RegExp(`\\b${value}\\s*=\\s*"([^"]*)"`).exec(src);
      expect(c, `${uploadSurface(id).file} references ${value} but declares no literal for it`)
        .not.toBeNull();
      value = `"${c![1]}"`;
    }
    const literal = value.slice(1, -1);
    expect(
      literal,
      `${uploadSurface(id).file} serves '${header}: ${literal}', which does not contain `
      + `${JSON.stringify(expected)}. ${uploadSurface(id).note}`,
    ).toContain(expected);
  });

// ═══════════════════════════════════════════════════════════════════════════
// DRIVEN TIER — HTTP against a live mesh (every user is @env:docker tagged)
// ═══════════════════════════════════════════════════════════════════════════

/** The API context an earlier `I hold an API session …` step put in the world. */
function api(world: { get: <T>(k: string) => T }): APIRequestContext {
  return world.get<APIRequestContext>('api');
}

/** A genuinely-valid 1x1 PNG (passes ImageSniffer). Same bytes spec 28 uses. */
const PNG_VALID = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
);
/** PNG magic bytes + a payload past the 5 MB avatar cap. */
const PNG_OVER_5MB = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.alloc(5 * 1024 * 1024 + 1),
]);
/** SVG markup — declared image/svg+xml, sniffs to null. */
const SVG_MARKUP = Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
  + '<script>alert(1)</script><rect width="8" height="8"/></svg>',
);
/** HTML claiming to be a PNG — the polyglot leg of the stored-XSS gap. */
const HTML_POLYGLOT = Buffer.from(
  '<html><body><img src=x onerror="alert(1)"></body></html>'.padEnd(64, ' '),
);

/**
 * The FOUR avatar payloads, each named for the branch it must trip. The
 * declared content type is part of the fixture because the first gate reads the
 * header and the second reads the bytes — a kind that got both from one field
 * could not distinguish them.
 */
const AVATAR_KINDS: Record<string, { name: string; mimeType: string; buffer: Buffer }> = {
  'valid-png': { name: 'ok.png', mimeType: 'image/png', buffer: PNG_VALID },
  'text-plain': { name: 'note.txt', mimeType: 'text/plain', buffer: Buffer.from('not an image') },
  svg: { name: 'x.svg', mimeType: 'image/svg+xml', buffer: SVG_MARKUP },
  'html-polyglot': { name: 'x.png', mimeType: 'image/png', buffer: HTML_POLYGLOT },
  'oversize-png': { name: 'big.png', mimeType: 'image/png', buffer: PNG_OVER_5MB },
};

function avatarKind(kind: string): { name: string; mimeType: string; buffer: Buffer } {
  const f = AVATAR_KINDS[kind];
  if (!f) {
    throw new Error(
      `unknown avatar kind '${kind}'. Legal kinds: ${Object.keys(AVATAR_KINDS).join(', ')} — `
      + `each one is named for the ProfileController.uploadAvatar branch it must trip.`,
    );
  }
  return f;
}

const AVATAR = '/bff/user/profile/avatar';

async function postAvatar(
  ctx: APIRequestContext, kind: string, declaredType?: string,
): Promise<APIResponse> {
  const f = avatarKind(kind);
  return ctx.post(AVATAR, {
    multipart: { file: declaredType ? { ...f, mimeType: declaredType } : f },
    failOnStatusCode: false,
  });
}

When('I upload an avatar of kind {string}', async ({ world }, kind: string) => {
  world.set('avatarUpload', await postAvatar(api(world), kind));
});

When('I upload an avatar of kind {string} declaring the content type {string}',
  async ({ world }, kind: string, declared: string) => {
    world.set('avatarUpload', await postAvatar(api(world), kind, declared));
  });

Then('the avatar upload was rejected with HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('avatarUpload');
  expect(r.status(), `POST ${AVATAR} -> ${r.status()}: ${(await r.text()).slice(0, 300)}`)
    .toBe(status);
});

Then('the avatar upload reject reports {string}', async ({ world }, fragment: string) => {
  const r = world.get<APIResponse>('avatarUpload');
  const body = await r.text();
  expect(
    body,
    `the reject body does not mention ${JSON.stringify(fragment)}. Each branch of `
    + `uploadAvatar carries a DISTINCT message; asserting the fragment is what makes a branch `
    + `collapsing into its neighbour visible instead of silently still-400.`,
  ).toContain(fragment);
});

Then('the avatar upload was accepted', async ({ world }) => {
  const r = world.get<APIResponse>('avatarUpload');
  expect(r.status(), `POST ${AVATAR} -> ${r.status()}: ${(await r.text()).slice(0, 300)}`)
    .toBe(200);
});

Then('my profile still carries no avatar url', async ({ world }) => {
  const r = await api(world).get('/bff/user/profile');
  expect(r.status(), 'GET /bff/user/profile').toBe(200);
  const body = await r.json();
  const url = body.avatarUrl ?? body.avatarMxcUrl ?? null;
  expect(
    url,
    `a REJECTED upload left an avatar url on the profile (${url}). The gates are meant to `
    + `refuse before anything is stored — a 400 that still wrote is the worst of both.`,
  ).toBeFalsy();
});

Then('my stored avatar body is served as {string}', async ({ world }, type: string) => {
  const r = await api(world).get(`${AVATAR}/body`);
  expect(r.status(), `GET ${AVATAR}/body`).toBe(200);
  expect(
    r.headers()['content-type'] ?? '',
    `the avatar body is served as '${r.headers()['content-type']}' rather than the SNIFFED `
    + `type. The client header is never trusted: uploading real PNG bytes under a lying `
    + `image/gif header must still be served image/png.`,
  ).toContain(type);
});

Then('the avatar body response carries the header {string} containing {string}',
  async ({ world }, header: string, needle: string) => {
    const r = await api(world).get(`${AVATAR}/body`);
    expect(r.status(), `GET ${AVATAR}/body`).toBe(200);
    expect(
      r.headers()[header.toLowerCase()] ?? '<absent>',
      `${AVATAR}/body must send '${header}: …${needle}…'. The URL is IDENTICAL for every user `
      + `(the owner comes from the JWT, never the path) and the browser cache is keyed by URL `
      + `alone — it neither varies on the session cookie nor is emptied by sign-out. Anything `
      + `cacheable here serves the PREVIOUS account's face after a switch, with no request `
      + `leaving the browser (operator report 2026-08-19).`,
    ).toContain(needle);
  });

Then('the avatar body response carries the header {string} equal to {string}',
  async ({ world }, header: string, value: string) => {
    const r = await api(world).get(`${AVATAR}/body`);
    expect(r.status(), `GET ${AVATAR}/body`).toBe(200);
    expect(r.headers()[header.toLowerCase()] ?? '<absent>', `${AVATAR}/body ${header}`)
      .toBe(value);
  });

// The character-part serve is hardened THREE ways; only the MIME type is
// asserted by the existing sticker feature. These two read the SAME stored part
// the reused 'I save a character part …' step created.
Then('the served part SVG carries the header {string} containing {string}',
  async ({ world }, header: string, needle: string) => {
    const id = world.get<string>('partId');
    const r = await api(world).get(`/bff/user/character/parts/${id}/svg`);
    expect(r.status(), 'serve part svg').toBe(200);
    expect(
      r.headers()[header.toLowerCase()] ?? '<absent>',
      `the part SVG serve must send '${header}: …${needle}…' — defence in depth ON TOP of the `
      + `sanitizer, because the bytes are served from the platform origin.`,
    ).toContain(needle);
  });

Then('the served part SVG carries the header {string} equal to {string}',
  async ({ world }, header: string, value: string) => {
    const id = world.get<string>('partId');
    const r = await api(world).get(`/bff/user/character/parts/${id}/svg`);
    expect(r.status(), 'serve part svg').toBe(200);
    expect(r.headers()[header.toLowerCase()] ?? '<absent>', `part svg ${header}`).toBe(value);
  });

// ── tube media verify (PUBLIC — permitAll; the HMAC IS the credential) ───────

const VERIFY = '/bff/tube/media/verify';

/**
 * The eight malformed-input cases, each a DISTINCT early return in
 * TubeMediaController.verify. They must be INDISTINGUISHABLE from one another
 * and from a forged signature: one uniform empty 403, because nginx auth_request
 * only separates 2xx from everything else and any variation turns the wall into
 * an oracle.
 */
const VERIFY_CASES: Record<string, Record<string, string>> = {
  'no-parameters': {},
  'blank-sig': { path: '/acme/alice/videos/x.mp4', sig: '', exp: '9999999999999', sub: 'alice', domain: 'acme' },
  'blank-sub': { path: '/acme/alice/videos/x.mp4', sig: 'AAAA', exp: '9999999999999', sub: '', domain: 'acme' },
  'blank-domain': { path: '/acme/alice/videos/x.mp4', sig: 'AAAA', exp: '9999999999999', sub: 'alice', domain: '' },
  'missing-path': { sig: 'AAAA', exp: '9999999999999', sub: 'alice', domain: 'acme' },
  'non-numeric-exp': { path: '/acme/alice/videos/x.mp4', sig: 'AAAA', exp: 'soon', sub: 'alice', domain: 'acme' },
  'expired-exp': { path: '/acme/alice/videos/x.mp4', sig: 'AAAA', exp: '1', sub: 'alice', domain: 'acme' },
  'forged-sig': { path: '/acme/alice/videos/x.mp4', sig: 'Zm9yZ2Vk', exp: '9999999999999', sub: 'alice', domain: 'acme' },
};

When('I call the tube media verify route with the {string} parameters',
  async ({ world }, name: string) => {
    const params = VERIFY_CASES[name];
    if (!params) {
      throw new Error(
        `unknown verify case '${name}'. Legal cases: ${Object.keys(VERIFY_CASES).join(', ')} — `
        + `each names one early return in TubeMediaController.verify.`,
      );
    }
    world.set('verify', await api(world).get(VERIFY, { params, failOnStatusCode: false }));
  });

Then('the tube media verify verdict is {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('verify');
  expect(
    r.status(),
    `${VERIFY} answered ${r.status()}. Every failure mode must be the SAME 403: a 400 for a `
    + `malformed parameter and a 403 for a forged signature would tell an attacker which of `
    + `the two they got wrong, and nginx auth_request cannot use the distinction anyway.`,
  ).toBe(status);
});

Then('the tube media verify response body is empty', async ({ world }) => {
  const r = world.get<APIResponse>('verify');
  const body = await r.text();
  expect(
    body.trim(),
    `${VERIFY} returned a body (${body.slice(0, 200)}). The deny is deliberately empty — a `
    + `message here is the oracle the empty body exists to prevent.`,
  ).toBe('');
});

// ── character forge bounds (browser-session; page.request, like spec 32) ─────

/** The forge BFF prefix, read off the SERVICE catalogue and never re-spelled. */
function forgePrefix(): string {
  const p = service('character-forge').bffPrefix;
  if (!p) throw new Error('character-forge carries no pinned BFF prefix in steps/dimensions.ts');
  return p;
}

/** A minimal definition the server validator accepts (spec 32's shape). */
function forgeDefinition(name: string): Record<string, unknown> {
  return {
    v: 1,
    family: 'canid',
    style: 'toon',
    name,
    body: { height: 1.0, build: 0.5 },
    head: { muzzle: 0.5, ears: 0.5 },
    materials: {},
  };
}

Given('I hold {int} stored forge characters', async ({ page, world }, n: number) => {
  const prefix = forgePrefix();
  const existing = await page.request.get(`${prefix}/characters`);
  expect(existing.status(), `GET ${prefix}/characters`).toBe(200);
  const rows = await existing.json();
  const have = Array.isArray(rows) ? rows.length : 0;
  expect(
    have,
    `this persona already holds ${have} forge characters, more than the ${n} this scenario `
    + `needs. The cap scenario must start below the cap or it proves nothing; run it against a `
    + `freshly-seeded mesh.`,
  ).toBeLessThanOrEqual(n);
  for (let i = have; i < n; i += 1) {
    const created = await page.request.post(`${prefix}/characters`, {
      data: { name: `e2e-cap-${i}`, definition: forgeDefinition(`e2e-cap-${i}`) },
    });
    expect(created.status(), `POST ${prefix}/characters #${i}`).toBe(201);
  }
  world.set('forgeCount', n);
});

When('I create one more forge character', async ({ page, world }) => {
  world.set('forgeCreate', await page.request.post(`${forgePrefix()}/characters`, {
    data: { name: 'e2e-one-too-many', definition: forgeDefinition('e2e-one-too-many') },
    failOnStatusCode: false,
  }));
});

Then('the forge create was rejected with HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('forgeCreate');
  expect(
    r.status(),
    `POST characters -> ${r.status()}: ${(await r.text()).slice(0, 300)}. The cap is a `
    + `409 CONFLICT, not a 400 — it is a state limit, not a malformed request.`,
  ).toBe(status);
});

Then('I still hold {int} stored forge characters', async ({ page }, n: number) => {
  const r = await page.request.get(`${forgePrefix()}/characters`);
  expect(r.status(), 'GET characters').toBe(200);
  const rows = await r.json();
  expect(
    Array.isArray(rows) ? rows.length : -1,
    `the refused create changed the stored count. A rejected create that still wrote a row `
    + `would make the cap advisory.`,
  ).toBe(n);
});

/** The three id shapes that must ALL answer 404 — a foreign owner, a foreign
 *  brand and a malformed uuid — so the error shape leaks nothing about which. */
const FOREIGN_IDS: Record<string, string> = {
  'another-owners': '00000000-0000-0000-0000-0000000000aa',
  'another-brands': '00000000-0000-0000-0000-0000000000bb',
  'not-a-uuid': 'definitely-not-a-uuid',
};

When('I read the forge character id {string}', async ({ page, world }, kind: string) => {
  const id = FOREIGN_IDS[kind];
  if (!id) {
    throw new Error(
      `unknown id kind '${kind}'. Legal kinds: ${Object.keys(FOREIGN_IDS).join(', ')}.`,
    );
  }
  world.set('forgeRead', await page.request.get(`${forgePrefix()}/characters/${id}`,
    { failOnStatusCode: false }));
});

Then('the forge read was rejected with HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('forgeRead');
  expect(
    r.status(),
    `an id-addressed read answered ${r.status()}. It must be 404 and never 403: a 403 would `
    + `confirm the row EXISTS under another owner, which is a cross-owner existence leak.`,
  ).toBe(status);
});

When('I look up the active characters of {int} subjects', async ({ page, world }, n: number) => {
  const subjects = Array.from({ length: n }, (_, i) => `e2e-lookup-subject-${i}`);
  world.set('forgeLookup', await page.request.post(`${forgePrefix()}/characters/lookup`, {
    data: { subjects }, failOnStatusCode: false,
  }));
});

Then('the lookup was rejected with HTTP {int}', async ({ world }, status: number) => {
  const r = world.get<APIResponse>('forgeLookup');
  expect(
    r.status(),
    `POST characters/lookup -> ${r.status()}. The 1..50 bound is bean validation on the `
    + `request record: an unbounded list would let one call scan the whole brand.`,
  ).toBe(status);
});

Then('my active forge character is named {string}', async ({ page }, name: string) => {
  const r = await page.request.get(`${forgePrefix()}/characters/active`);
  expect(r.status(), 'GET characters/active').toBe(200);
  expect((await r.json()).name, 'the active character').toBe(name);
});

Then('exactly one of my forge characters is marked active', async ({ page }) => {
  const r = await page.request.get(`${forgePrefix()}/characters`);
  expect(r.status(), 'GET characters').toBe(200);
  const rows = await r.json();
  const active = (Array.isArray(rows) ? rows : []).filter((c: { active?: boolean }) => c.active);
  expect(
    active.length,
    `${active.length} characters are marked active. Single-active is backstopped by a PARTIAL `
    + `UNIQUE INDEX, so two actives means the swap stopped clearing its sibling and the index `
    + `is not covering the case that reached the DB.`,
  ).toBe(1);
});
