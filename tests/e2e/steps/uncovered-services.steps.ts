// uncovered-services.steps.ts — step definitions for the `uncovered-services`
// domain: owncast, tube, wiki, character-studio, character-forge, plus the
// forum/phpbb and games surfaces that were covered ONLY as gateway route
// contracts and never as driven UI.
//
// WHY THIS FILE EXISTS. Four services (owncast, tube, wiki, character-studio)
// had ZERO e2e coverage of any kind, and three more (forum/phpbb, games,
// character-forge) were asserted only as strings in a route table. Nothing in
// tests/e2e opened any of them in a browser, and nothing checked that the route
// a service claims in one committed artefact is the route the OTHER committed
// artefacts agree on. The failure this prevents is the one seed-e2e.sh already
// names in prose: "those services run as containers and are INVISIBLE in the
// host shell's menu — running-but-unreachable".
//
// TWO KINDS OF STEP LIVE HERE, deliberately kept apart:
//
//   1. CONTRACT steps (offline; the `@harness` features). They read the
//      COMMITTED artefacts — the fe-gateway route table, the route-access seed,
//      the optional-services catalogue, the cluster Deployments — and assert
//      that the four of them agree about where a service is mounted, what role
//      gates it, and which node architecture it can schedule on. These run with
//      the stack DOWN and are what makes this unit's coverage non-vacuous when
//      no mesh is available.
//
//   2. Driven-UI steps: THERE ARE NONE. Every browser action in this domain's
//      features comes from common.steps.ts (open the path / sign in as the
//      persona / URL matches / heading is visible / test id is visible). That is
//      the convention (features/README.md §3) and it is also the point: the
//      Gherkin drives the SAME helpers the 33 handwritten specs drive, so the
//      two lanes cannot disagree about what signing in means.
//
// EVERY assertion below is sourced from a file IN THIS REPO. Nothing is read
// from .stack-src — that tree is gitignored and `make stack-clone` resets it, so
// a step that depended on it would pass on this machine and fail in CI. (The
// SELECTORS the features assert on — `wiki-nav-access`, `cf-header`,
// `games-todo-badge` … — were read out of those checkouts by hand while writing
// the features, exactly as the handwritten specs' selectors were.)

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import { Then, requireDimension } from './world';
import { shellRoster } from './dimensions';
import { SYSTEMS_SEED_USERS } from '../specs/rbac-roles';

/** Repo root — steps/ is tests/e2e/steps, so three levels up. */
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

const FE_ROUTES_YML = 'tests/stack/gateway-routes/fe/application-routes.yml';
const ROUTE_ACCESS_SQL = 'specs/cluster/manifests/route-access/initdb/20-schema.sql';
const OPTIONAL_SERVICES_YAML = 'specs/cluster/optional-services.yaml';

/** Read a committed artefact, or fail naming the absolute path AND the reason
 *  this domain depends on it — a missing source file must never degrade into a
 *  soft skip that leaves the contract unasserted. */
function readRepoFile(rel: string): string {
  const abs = path.join(REPO_ROOT, rel);
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the committed artefact ${abs}: ${(e as Error).message}. `
      + `The uncovered-services contract features assert the AGREEMENT between the `
      + `fe-gateway route table, the route-access seed and the cluster manifests; `
      + `refusing to pass without reading it.`,
    );
  }
}

// ── 1. the fe-gateway route table ────────────────────────────────────────────

export interface FeRoute {
  id: string;
  uri: string;
  paths: string[];
  headers: string[];
  stripPrefix: number | null;
  /** Zero-based DECLARATION ORDER. Spring Cloud Gateway matches first-in-declared-
   *  order, so for the several patterns served by two routes this is the field
   *  that decides which upstream actually answers. */
  order: number;
}

let feRoutesCache: FeRoute[] | undefined;

/**
 * Parse the fe-gateway Spring Cloud Gateway route list out of the committed
 * application-routes.yml. Deliberately a targeted line scanner rather than a
 * YAML dependency: this suite ships two devDeps and adding a parser to assert
 * four fields would be the larger change. Comment lines cannot match — every
 * pattern below is anchored at `- <key>:` / `- Path=` with only whitespace
 * before it, and every comment in that file starts with `#`.
 */
export function feRoutes(): FeRoute[] {
  if (feRoutesCache) return feRoutesCache;
  const out: FeRoute[] = [];
  let cur: FeRoute | undefined;
  for (const raw of readRepoFile(FE_ROUTES_YML).split('\n')) {
    const line = raw.replace(/\s+$/, '');
    const id = /^\s*-\s*id:\s*(\S+)$/.exec(line);
    if (id) {
      cur = { id: id[1], uri: '', paths: [], headers: [], stripPrefix: null, order: out.length };
      out.push(cur);
      continue;
    }
    if (!cur) continue;
    const uri = /^\s*uri:\s*(\S+)$/.exec(line);
    if (uri) { cur.uri = uri[1]; continue; }
    const p = /^\s*-\s*Path=(.+)$/.exec(line);
    if (p) { cur.paths.push(...p[1].split(',').map((s) => s.trim())); continue; }
    const h = /^\s*-\s*Header=(.+)$/.exec(line);
    if (h) { cur.headers.push(h[1].trim()); continue; }
    const sp = /^\s*-\s*StripPrefix=(\d+)$/.exec(line);
    if (sp) { cur.stripPrefix = Number(sp[1]); continue; }
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO routes out of ${FE_ROUTES_YML}. The route-list shape changed — fix `
      + `this parser rather than letting every route assertion pass vacuously against `
      + `an empty list.`,
    );
  }
  feRoutesCache = out;
  return out;
}

/**
 * The fe gateway must declare a route whose Path predicate is EXACTLY the given
 * pattern, forwarding to the given upstream. Exact-match on the pattern, not
 * substring: `/wiki/**` and `/wiki/pages/**` are different contracts and a
 * substring test would let one satisfy the other.
 */
Then(
  'the fe gateway routes {string} to the {string} upstream',
  async ({}, pattern: string, upstream: string) => {
    const routes = feRoutes();
    const matching = routes.filter((r) => r.paths.includes(pattern));
    expect(
      matching.map((r) => r.id),
      `no fe-gateway route in ${FE_ROUTES_YML} declares the Path predicate '${pattern}'. `
      + `A service with no front-door route is unreachable however healthy its container is. `
      + `Declared patterns: ${routes.flatMap((r) => r.paths).join(' ')}`,
    ).not.toHaveLength(0);
    const hit = matching.find((r) => r.uri.includes(upstream));
    expect(
      hit,
      `'${pattern}' is routed by [${matching.map((r) => `${r.id} -> ${r.uri}`).join(', ')}], `
      + `none of which forwards to '${upstream}'. A route pointed at the wrong upstream `
      + `renders SOMETHING, and something is what an assertion goes green against.`,
    ).toBeDefined();
  },
);

/**
 * StripPrefix is load-bearing and has broken this stack before: the phpbb route
 * shipped with NO StripPrefix (correct for an installer fed
 * script_path=/social/phpbb) and, against the replacement image installed at
 * script_path=/, produced a themed 404 on every URL while the index still
 * rendered. Pinning the count is what stops that swap going unnoticed.
 *
 * SCOPED BY UPSTREAM, not by pattern alone — measured the hard way while writing
 * this: /wiki/**, /owncast/**, /tube/**, /character-studio/**,
 * /character-forge/** and /social/forum/** are EACH declared by two routes, the
 * remote's own route and the `remote-deeplink-to-host-shell` route that catches
 * HTML navigations. A pattern-only lookup asserted against whichever came first
 * and reported the deep-link route's (correctly absent) StripPrefix.
 */
Then(
  'the fe gateway route for {string} to the {string} upstream strips {int} path segment(s)',
  async ({}, pattern: string, upstream: string, segments: number) => {
    const hit = feRoutes().find(
      (r) => r.paths.includes(pattern) && r.uri.includes(upstream),
    );
    expect(
      hit,
      `no fe-gateway route declares '${pattern}' forwarding to '${upstream}'`,
    ).toBeDefined();
    expect(
      hit!.stripPrefix,
      `route '${hit!.id}' (${pattern} -> ${hit!.uri}) must strip ${segments} segment(s); `
      + `a wrong StripPrefix serves the upstream's 404 page, which still returns bytes.`,
    ).toBe(segments);
  },
);

/**
 * The DEEP-LINK contract, and it is not cosmetic.
 *
 * Every shell-mounted remote path is served by TWO routes. Refreshing the page,
 * opening a bookmark or following a shared link is an HTML navigation, and it
 * must reach the HOST SHELL so Angular can resolve the deep link and load the
 * remote with the shell's chrome, session UI and nonce-CSP intact. Before the
 * `remote-deeplink-to-host-shell` route existed, that navigation went straight
 * to the remote's own nginx `try_files … /index.html` and dropped the operator
 * into the BARE remote — reported 2026-08-14: "refreshing takes us into the
 * federated remote instead of just refreshing the view".
 *
 * Two properties make it work and both are asserted: the route must be declared
 * BEFORE the remote's own route (Spring Cloud Gateway matches in declared
 * order), and it must be POSITIVE-matched on `Accept: text/html` so that
 * remoteEntry.json, chunk imports, assets, XHR and header-less requests all fail
 * the predicate and continue to the remote exactly as before.
 */
Then(
  'html navigations for {string} reach the host shell before the {string} upstream',
  async ({}, pattern: string, upstream: string) => {
    const routes = feRoutes();
    const deeplink = routes.find(
      (r) => r.paths.includes(pattern) && r.uri.includes('hugmesh-host-shell'),
    );
    expect(
      deeplink,
      `no fe-gateway route sends '${pattern}' to the host shell. Without it a refresh or a `
      + `shared link lands in the BARE remote — no menu, no shell chrome, no session UI.`,
    ).toBeDefined();
    const remote = routes.find(
      (r) => r.paths.includes(pattern) && r.uri.includes(upstream),
    );
    expect(remote, `no fe-gateway route sends '${pattern}' to '${upstream}'`).toBeDefined();
    expect(
      deeplink!.order,
      `route '${deeplink!.id}' is declared AFTER '${remote!.id}'. Spring Cloud Gateway `
      + `matches first-in-declared-order, so the remote would answer the navigation and the `
      + `deep-link route would be dead config that still reads as a fix.`,
    ).toBeLessThan(remote!.order);
    expect(
      deeplink!.headers.join(' '),
      `route '${deeplink!.id}' must be scoped to 'Accept: text/html'. Without that predicate `
      + `it swallows remoteEntry.json, chunk imports, assets and XHR too, and the remote `
      + `never loads at all.`,
    ).toMatch(/Accept.*text\/html/);
  },
);

// ── 2. the route-access seed ─────────────────────────────────────────────────

/** One parsed route-access seed tuple. EXPORTED (with {@link accessRows}) so
 *  steps/social-functions.ts can decide the social FUNCTION matrix against the
 *  same committed rows these scenarios assert against — a second parser over the
 *  same SQL is exactly the divergence this suite exists to prevent. */
export interface AccessRow { gateway: string; pattern: string; role: string; allow: boolean }

let accessRowsCache: AccessRow[] | undefined;

/** Parse the `('<gateway>', '<url_pattern>', '<ROLE>', <allow>)` seed tuples out
 *  of the committed route-access schema. Same authority the 33 handwritten specs
 *  mirror by hand in specs/rbac-route-access.ts — read here rather than copied,
 *  because a copy is how this repo grew three divergent persona lists. */
export function accessRows(): AccessRow[] {
  if (accessRowsCache) return accessRowsCache;
  const re = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)/g;
  const out: AccessRow[] = [];
  for (const m of readRepoFile(ROUTE_ACCESS_SQL).matchAll(re)) {
    out.push({ gateway: m[1], pattern: m[2], role: m[3], allow: m[4] === 'true' });
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO route-access rows out of ${ROUTE_ACCESS_SQL}. The seed's INSERT shape `
      + `changed — fix this parser; an empty table makes every grant assertion vacuous.`,
    );
  }
  accessRowsCache = out;
  return out;
}

Then(
  'the route-access seed grants {string} at {string} on the fe gateway',
  async ({}, role: string, pattern: string) => {
    const at = accessRows().filter(
      (r) => r.gateway === 'hugmesh-fe-gateway' && r.pattern === pattern,
    );
    expect(
      at.map((r) => r.role),
      `${ROUTE_ACCESS_SQL} seeds no fe-gateway allow row for '${pattern}'. The gateway is `
      + `DEFAULT-DENY, so a mounted UI with no row is a 403 for everyone — the exact gap the `
      + `wiki/owncast/tube UI mounts had before they were added.`,
    ).toContain(role);
    const row = at.find((r) => r.role === role)!;
    expect(row.allow, `the '${pattern}' -> ${role} row must be an ALLOW row`).toBe(true);
  },
);

Then(
  'the route-access seed has no fe gateway row for {string}',
  async ({}, pattern: string) => {
    const at = accessRows().filter(
      (r) => r.gateway === 'hugmesh-fe-gateway' && r.pattern === pattern,
    );
    expect(
      at,
      `${ROUTE_ACCESS_SQL} DOES seed fe-gateway rows for '${pattern}' `
      + `(${at.map((r) => r.role).join(', ')}), but this surface is contractually row-less. `
      + `Adding a row here changes the access posture of a backend-only pod.`,
    ).toHaveLength(0);
  },
);

// ── 3. the optional-services catalogue ───────────────────────────────────────

interface CatalogueEntry {
  slug: string;
  defaultOn: boolean | null;
  moduleMountAt: string | null;
}

let catalogueCache: Map<string, CatalogueEntry> | undefined;

/**
 * Parse `specs/cluster/optional-services.yaml` for the three fields this domain
 * asserts: the slug, its default on/off state, and the federation module mount
 * path. `federationModule` appears in BOTH an inline-flow form
 * (`{ slug: tube, mountAt: /tube, … }`) and a block form (character-studio /
 * character-forge), so both are handled — a parser that saw only the inline form
 * would silently report "no mount" for exactly the two newest services.
 */
function catalogue(): Map<string, CatalogueEntry> {
  if (catalogueCache) return catalogueCache;
  const lines = readRepoFile(OPTIONAL_SERVICES_YAML).split('\n');
  const out = new Map<string, CatalogueEntry>();
  let cur: CatalogueEntry | undefined;
  let inModuleBlock = false;
  for (const raw of lines) {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*#/.test(line)) continue;
    const slug = /^\s*-\s*slug:\s*(\S+)$/.exec(line);
    if (slug) {
      cur = { slug: slug[1], defaultOn: null, moduleMountAt: null };
      out.set(cur.slug, cur);
      inModuleBlock = false;
      continue;
    }
    if (!cur) continue;
    const def = /^\s*default:\s*(\S+)$/.exec(line);
    if (def) { cur.defaultOn = def[1] === 'on' || def[1] === 'true'; inModuleBlock = false; continue; }
    const inlineModule = /^\s*federationModule:\s*\{(.+)\}\s*$/.exec(line);
    if (inlineModule) {
      const mount = /mountAt:\s*([^,}\s]+)/.exec(inlineModule[1]);
      cur.moduleMountAt = mount ? mount[1] : null;
      inModuleBlock = false;
      continue;
    }
    if (/^\s*federationModule:\s*$/.test(line)) { inModuleBlock = true; continue; }
    if (inModuleBlock) {
      const mount = /^\s*mountAt:\s*(\S+)$/.exec(line);
      if (mount) { cur.moduleMountAt = mount[1]; continue; }
      if (/^\s*-\s/.test(line) || /^\s{0,6}\S/.test(line)) inModuleBlock = false;
    }
  }
  if (out.size === 0) {
    throw new Error(
      `parsed ZERO service slugs out of ${OPTIONAL_SERVICES_YAML} — fix this parser.`,
    );
  }
  catalogueCache = out;
  return out;
}

/** Look up this scenario's `@service:` id in the catalogue, or fail naming the
 *  legal slugs. A service absent from the catalogue is NOT an optional service
 *  (wiki, for instance, is always-on) and must not be asserted about here. */
function catalogueEntry(slug: string): CatalogueEntry {
  const e = catalogue().get(slug);
  if (!e) {
    throw new Error(
      `'${slug}' has no entry in ${OPTIONAL_SERVICES_YAML}, so it is not an operator-`
      + `selectable optional service and this step does not apply to it. Catalogued slugs: `
      + `${[...catalogue().keys()].join(', ')}.`,
    );
  }
  return e;
}

Then(
  'the optional-services catalogue mounts this service at {string}',
  async ({ dimensions }, mountAt: string) => {
    const slug = requireDimension(dimensions, 'service');
    const e = catalogueEntry(slug);
    expect(
      e.moduleMountAt,
      `optional-services.yaml records no federationModule.mountAt for '${slug}'. Without a `
      + `registered module the host shell has nothing to mount, and the service runs as a `
      + `container that is invisible in the menu — running-but-unreachable.`,
    ).toBe(mountAt);
  },
);

Then(
  'this service is default-off in the optional-services catalogue',
  async ({ dimensions }) => {
    const slug = requireDimension(dimensions, 'service');
    const e = catalogueEntry(slug);
    expect(
      e.defaultOn,
      `'${slug}' records no default: on/off in optional-services.yaml`,
    ).not.toBeNull();
    expect(
      e.defaultOn,
      `'${slug}' is default-ON in the catalogue. This domain's driven-UI scenarios are `
      + `written against a mesh that opted in explicitly; if the default flipped, the `
      + `pending reasons in features/uncovered-services/*.feature are stale.`,
    ).toBe(false);
  },
);

Then(
  'this service is default-on in the optional-services catalogue',
  async ({ dimensions }) => {
    const slug = requireDimension(dimensions, 'service');
    const e = catalogueEntry(slug);
    expect(
      e.defaultOn,
      `'${slug}' records no default: on/off in optional-services.yaml`,
    ).not.toBeNull();
    expect(
      e.defaultOn,
      `'${slug}' is default-OFF in the catalogue, so the driven-UI scenarios written `
      + `against it as an always-present service no longer hold.`,
    ).toBe(true);
  },
);

// ── 4. cluster Deployment placement (the PLATFORM axis, with teeth) ──────────

/** The `kubernetes.io/arch` nodeSelector of a service's cluster Deployment, or
 *  null when it pins none (i.e. it schedules on rpi5 arm64 AND x86 amd64). */
function deploymentArch(manifestDir: string): string | null {
  const rel = path.join('specs/cluster/manifests', manifestDir, 'deployment.yaml');
  const m = /kubernetes\.io\/arch:\s*(\S+)/.exec(readRepoFile(rel));
  return m ? m[1] : null;
}

Then(
  'the {string} deployment pins the node architecture {string}',
  async ({}, manifestDir: string, arch: string) => {
    expect(
      deploymentArch(manifestDir),
      `specs/cluster/manifests/${manifestDir}/deployment.yaml must pin `
      + `kubernetes.io/arch: ${arch} — this service needs a GPU-bearing amd64 worker, and a `
      + `mesh of Pi 5s has nowhere to schedule it. Dropping the pin does not make it run; `
      + `it makes the Pod Pending with no explanation at the UI.`,
    ).toBe(arch);
  },
);

Then(
  'the {string} deployment pins no node architecture',
  async ({}, manifestDir: string) => {
    expect(
      deploymentArch(manifestDir),
      `specs/cluster/manifests/${manifestDir}/deployment.yaml pins a node architecture, so `
      + `this surface is NOT platform-neutral and the rpi5 row of this scenario's Examples `
      + `table is a row that cannot run.`,
    ).toBeNull();
  },
);

// ── 5. the persona roster vs the per-service access roles ────────────────────

/** Every persona either seeder creates that holds `role`, from BOTH rosters —
 *  the TypeScript catalogue (specs/rbac-roles.ts) and the shell roster the
 *  compose + kind seeders execute (tests/e2e-extra-personas.sh). */
function roleHolders(role: string): string[] {
  const out: string[] = [];
  for (const u of SYSTEMS_SEED_USERS) {
    if ((u.roles as readonly string[]).includes(role)) out.push(u.username);
  }
  for (const p of shellRoster()) {
    if (p.roles.includes(role)) out.push(p.username);
  }
  return [...new Set(out)].sort();
}

/**
 * A TRIPWIRE, not a lament. Three services (wiki, owncast, tube) are gated on a
 * per-service access role that NO persona in either e2e roster holds, so no e2e
 * scenario can drive them as their intended audience — only as an admin, whose
 * path through the console is a different one. Asserting the gap keeps it
 * visible AND makes the day it closes loud: seed a ROLE_WIKI persona and this
 * scenario fails, which is the prompt to drop the `@fixme` from the matching
 * console feature.
 */
Then(
  'no persona in the e2e roster holds the access role {string}',
  async ({}, role: string) => {
    const holders = roleHolders(role);
    expect(
      holders,
      `${role} IS now held by [${holders.join(', ')}]. That is good news and this `
      + `assertion is the prompt: the matching scenarios in `
      + `features/uncovered-services/ are pinned pending on "nothing seeds ${role}" and `
      + `can now drive the service as its real audience. Update them, then update this row.`,
    ).toHaveLength(0);
  },
);

Then(
  'some persona in the e2e roster holds the access role {string}',
  async ({}, role: string) => {
    const holders = roleHolders(role);
    expect(
      holders,
      `NO persona in specs/rbac-roles.ts SYSTEMS_SEED_USERS or tests/e2e-extra-personas.sh `
      + `holds ${role}, so every scenario that signs in expecting to reach this service `
      + `would fail at the gate — which reads like a broken console and is really an `
      + `identity nobody granted (the 2026-08-06 e2e-fleet symptom).`,
    ).not.toHaveLength(0);
  },
);
