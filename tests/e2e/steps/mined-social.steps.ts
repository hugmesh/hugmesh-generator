// mined-social.steps.ts — step definitions for the `mined-social` domain:
// the M3 social surfaces (matrix-ui, mastodon-ui, forum-ui, forum-bff-api,
// forum-api, federation-api) as they are expressed in COMMITTED artefacts.
//
// WHY THIS FILE EXISTS, and what it deliberately does NOT contain.
//
// A read-only mining pass over the six social repos proposed fourteen scenarios.
// Twelve of them assert BROWSER behaviour inside a sibling repo's Angular
// component (matrix-ui's redaction gate, mastodon-ui's optimistic rollback,
// forum-ui's refused-lock announcement …) and need BOTH a running mesh and a
// per-request stubbing lane that this suite does not have. Those were NOT
// authored here: an all-@fixme feature file does not generate at all
// (playwright-bdd filters on file.hasExecutableTests()), and a feature that
// never executes is worse than none because it reads as coverage. What survived
// is the tier that runs TODAY, with every environment down — plus one
// env-gated API probe that skips naming the command to run.
//
// THE FOUR CONTRACTS ASSERTED HERE, all from files in THIS repo:
//
//   specs/cluster/optional-services.yaml               the catalogue's declared
//                                                      federation MODULE slug
//   specs/cluster/manifests/route-access/initdb/       the per-pattern GATE, read
//     20-schema.sql                                    rather than mirrored
//   tests/stack/gateway-routes/fe/application-routes   (via the existing
//     .yml                                             uncovered-services steps)
//
// Nothing is read from a SIBLING repo. hugmesh-federation-api's changesets are
// what the module-slug claim was mined FROM, but a step that read them would
// pass on this box and fail anywhere the sibling checkout is absent — so the
// same defect is asserted through an invariant that is fully internal to the
// catalogue (see `moduleSlugMatchesMount` below).
//
// EVERY step text here was grepped against steps/ before being written; none
// shadows an existing definition. `missingSteps: 'fail-on-gen'` makes a
// duplicate a hard generation error for the whole suite, not a local problem.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Then, When, requireDimension } from './world';

/** Repo root — steps/ is tests/e2e/steps, so three levels up. */
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

const ROUTE_ACCESS_SQL = 'specs/cluster/manifests/route-access/initdb/20-schema.sql';
const OPTIONAL_SERVICES_YAML = 'specs/cluster/optional-services.yaml';

/** Read a committed artefact, or fail naming the absolute path. A missing source
 *  file must never degrade into a soft skip that leaves the contract unasserted. */
function readRepoFile(rel: string): string {
  const abs = path.join(REPO_ROOT, rel);
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the committed artefact ${abs}: ${(e as Error).message}. `
      + `The mined-social contract features assert agreement BETWEEN committed files; `
      + `refusing to pass without reading one of them.`,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 1. THE ROUTE-ACCESS SEED — the two assertions the existing vocabulary lacks
// ═══════════════════════════════════════════════════════════════════════════
//
// steps/uncovered-services.steps.ts already owns
//   'the route-access seed grants {string} at {string} on the fe gateway'   and
//   'the route-access seed has no fe gateway row for {string}'
// and those are REUSED verbatim by this domain's features. Two things they
// cannot express are added here:
//
//   * EXACTLY. The existing grant step asserts the role is PRESENT at the
//     pattern. The forum's three-tier stack (admin / moderation / floor) needs
//     the stronger claim: nothing ELSE is granted there. A stack that collapsed
//     — ROLE_ADMIN quietly added to /bff/forum/**, or ROLE_FORUM added to
//     /bff/forum/admin/** — still satisfies "contains", and longest-pattern-wins
//     means the collapse is exactly how a forum mod silently reaches the admin
//     seam. "Contains" cannot see that; "exactly" can.
//
//   * THE BE GATEWAY. The federation API's authenticated floor lives on the
//     be-gateway (/api/federation/** -> ROLE_USER); the PUBLIC capability
//     projection lives on the fe-gateway. Asserting only one door would leave
//     the claim half-made.

interface AccessRow { gateway: string; pattern: string; role: string; allow: boolean }

let accessRowsCache: AccessRow[] | undefined;

/** Parse the `('<gateway>', '<url_pattern>', '<ROLE>', <allow>)` seed tuples out
 *  of the committed route-access schema. Same shape the uncovered-services
 *  domain parses — READ, never mirrored. specs/26-rbac-cross-realm-matrix.spec.ts
 *  holds a hand-copy of the very forum rows this domain asserts ("Copied 1:1 from
 *  20-schema.sql", :59) and never opens the file, so a drift in the seed leaves
 *  that copy green and wrong. Reading is the whole point. */
function accessRows(): AccessRow[] {
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
  'the route-access seed grants exactly {string} at {string} on the fe gateway',
  async ({}, roles: string, pattern: string) => {
    const want = roles.split(',').map((r) => r.trim()).filter(Boolean).sort();
    const at = accessRows().filter(
      (r) => r.gateway === 'hugmesh-fe-gateway' && r.pattern === pattern && r.allow,
    );
    expect(
      at.map((r) => r.role).sort(),
      `${ROUTE_ACCESS_SQL} must seed EXACTLY [${want.join(', ')}] as the fe-gateway allow `
      + `set at '${pattern}'. The forum's front door is a three-tier stack and the gateway `
      + `matches LONGEST-PATTERN-WINS, so an extra role here is not additive — it is the `
      + `tier collapsing. ROLE_FORUM appearing at /bff/forum/admin/** hands the admin seam `
      + `to every forum member; ROLE_ADMIN appearing at the /bff/forum/** floor makes the `
      + `admin row it was split out of dead config that still reads as a gate.`,
    ).toEqual(want);
  },
);

Then(
  'the route-access seed grants {string} at {string} on the be gateway',
  async ({}, role: string, pattern: string) => {
    const at = accessRows().filter(
      (r) => r.gateway === 'hugmesh-be-gateway' && r.pattern === pattern,
    );
    expect(
      at.map((r) => r.role),
      `${ROUTE_ACCESS_SQL} seeds no be-gateway allow row for '${pattern}'. The gateway is `
      + `DEFAULT-DENY, so an API with no row is a 403 for everyone.`,
    ).toContain(role);
    expect(
      at.find((r) => r.role === role)!.allow,
      `the be-gateway '${pattern}' -> ${role} row must be an ALLOW row`,
    ).toBe(true);
  },
);

// ═══════════════════════════════════════════════════════════════════════════
// 2. THE OPTIONAL-SERVICES CATALOGUE — the federation MODULE slug
// ═══════════════════════════════════════════════════════════════════════════
//
// `federationModule.slug` is NOT the catalogue slug. phpbb proves it: catalogue
// slug `phpbb`, module slug `forum`. It is the key of the row the host shell
// resolves a remote from, and the seeder consumes it VERBATIM —
// tests/stack/seed-e2e.sh:732 "The slugs are MODULE slugs, NOT catalogue slugs —
// phpbb's module is `forum` — so they are used VERBATIM and never re-derived
// here", and a slug with no matching row logs "leg 4 WARN: no federation_modules
// row for slug '<x>' — skipped" and moves on. A wrong module slug therefore does
// not fail anything: it silently declines to flip the row, and the service stays
// invisible in the menu while every container is up and healthy.
//
// The uncovered-services parser reads `mountAt` and discards `slug`. This one
// reads both, because the two together are the internal cross-check.

interface ModuleEntry { slug: string; moduleSlug: string | null; mountAt: string | null }

let moduleCache: Map<string, ModuleEntry> | undefined;

/** Parse `federationModule` out of the catalogue in BOTH spellings it uses: the
 *  inline-flow form (`{ slug: tube, mountAt: /tube, … }`) and the block form
 *  (character-studio / character-forge). A parser that saw only the inline form
 *  would silently report "no module" for exactly the two newest services. */
function modules(): Map<string, ModuleEntry> {
  if (moduleCache) return moduleCache;
  const out = new Map<string, ModuleEntry>();
  let cur: ModuleEntry | undefined;
  let inBlock = false;
  for (const raw of readRepoFile(OPTIONAL_SERVICES_YAML).split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*#/.test(line)) continue;
    const slug = /^\s*-\s*slug:\s*(\S+)$/.exec(line);
    if (slug) {
      cur = { slug: slug[1], moduleSlug: null, mountAt: null };
      out.set(cur.slug, cur);
      inBlock = false;
      continue;
    }
    if (!cur) continue;
    const inline = /^\s*federationModule:\s*\{(.+)\}\s*$/.exec(line);
    if (inline) {
      const s = /(?:^|[\s{,])slug:\s*([^,}\s]+)/.exec(inline[1]);
      const m = /mountAt:\s*([^,}\s]+)/.exec(inline[1]);
      cur.moduleSlug = s ? s[1] : null;
      cur.mountAt = m ? m[1] : null;
      inBlock = false;
      continue;
    }
    if (/^\s*federationModule:\s*$/.test(line)) { inBlock = true; continue; }
    if (inBlock) {
      const s = /^\s*slug:\s*(\S+)$/.exec(line);
      if (s) { cur.moduleSlug = s[1]; continue; }
      const m = /^\s*mountAt:\s*(\S+)$/.exec(line);
      if (m) { cur.mountAt = m[1]; continue; }
      if (/^\s*-\s/.test(line) || /^\s{0,6}\S/.test(line)) inBlock = false;
    }
  }
  if (out.size === 0) {
    throw new Error(`parsed ZERO service slugs out of ${OPTIONAL_SERVICES_YAML} — fix this parser.`);
  }
  moduleCache = out;
  return out;
}

/** This scenario's `@service:` id as a catalogue entry, or a loud failure. */
function moduleEntry(slug: string): ModuleEntry {
  const e = modules().get(slug);
  if (!e) {
    throw new Error(
      `'${slug}' has no entry in ${OPTIONAL_SERVICES_YAML}, so it declares no federation `
      + `module and this step does not apply to it. Catalogued slugs: `
      + `${[...modules().keys()].join(', ')}.`,
    );
  }
  return e;
}

Then(
  'the optional-services catalogue registers this service under the federation module slug {string}',
  async ({ dimensions }, moduleSlug: string) => {
    const slug = requireDimension(dimensions, 'service');
    const e = moduleEntry(slug);
    expect(
      e.moduleSlug,
      `${OPTIONAL_SERVICES_YAML} records no federationModule.slug for '${slug}'.`,
    ).not.toBeNull();
    expect(
      e.moduleSlug,
      `'${slug}' declares federationModule.slug '${e.moduleSlug}', but the row the host `
      + `shell resolves its remote from is keyed '${moduleSlug}'. The seeder uses this `
      + `string VERBATIM (tests/stack/seed-e2e.sh) and WARNS-then-continues when no row `
      + `matches, so the wrong spelling is not an error anywhere — it is an operator `
      + `toggle that silently does nothing and a service that stays out of the menu with `
      + `every container healthy.`,
    ).toBe(moduleSlug);
  },
);

Then(
  'the federation module slug for this service is the last segment of its mount path',
  async ({ dimensions }) => {
    const slug = requireDimension(dimensions, 'service');
    const e = moduleEntry(slug);
    expect(e.moduleSlug, `no federationModule.slug for '${slug}'`).not.toBeNull();
    expect(e.mountAt, `no federationModule.mountAt for '${slug}'`).not.toBeNull();
    const last = e.mountAt!.replace(/\/+$/, '').split('/').pop();
    expect(
      e.moduleSlug,
      `'${slug}' declares module slug '${e.moduleSlug}' but mounts at '${e.mountAt}'. `
      + `The mount path's last segment IS the module slug for every other catalogued `
      + `service (phpbb: forum -> /social/forum; games -> /games; tube -> /tube; `
      + `owncast -> /owncast; character-studio; character-forge), and the registry `
      + `changeset each row NAMES registers exactly that string. A row that breaks the `
      + `pairing is declaring a key nothing answers to.`,
    ).toBe(last);
  },
);

// ═══════════════════════════════════════════════════════════════════════════
// 3. THE PUBLIC CAPABILITY PROJECTION (env-gated)
// ═══════════════════════════════════════════════════════════════════════════
//
// GET /api/federation/capabilities is the `permitAll` install-state list the host
// shell greys optional services from. Its contract (federation-api
// CapabilityController / CapabilityService / CapabilityDto) has three properties
// nothing in this suite reads:
//
//   * DOMAIN-SCOPED. An anonymous caller resolves to the "default" brand, never
//     PrincipalDomain.resolve(null, …) — so this permitAll endpoint cannot become
//     a cross-brand registry oracle.
//   * FRAGMENT-EXCLUDED. The `fragment` kind is cut IN THE QUERY, so a
//     profile-<username> vanity slug is never returned. Excluding it in Java
//     after the fetch would be one refactor away from a username enumerator on
//     an unauthenticated endpoint.
//   * STATE IS NOT ABSENCE. A registered-but-disabled service is LISTED with
//     installed=false (the host greys it by STATE); a service nobody registered
//     is ABSENT (greyed by ABSENCE). Collapsing the two is what turns a greyed
//     card into a dead link.
//
// These steps read `world['api']`, set by the existing
// 'I hold an anonymous API client' / 'I hold an API session as the persona for
// this scenario' Givens — the identity vocabulary is reused, not re-invented.

interface Capability { slug: string; installed: boolean; mountAt: string | null; requiresRole: string | null }

When('I read the public federation capability list', async ({ world }) => {
  const api = world.get<APIRequestContext>('api');
  const res = await api.get('/api/federation/capabilities');
  expect(
    res.status(),
    `GET /api/federation/capabilities answered ${res.status()} for `
    + `'${world.get<string>('username')}'. The route-access seed grants PUBLIC at this `
    + `exact path on the fe gateway, and the controller is permitAll — a non-200 here is `
    + `the host shell losing the only signal it has for which optional services exist, `
    + `which capabilities.service.ts reports as NOT INSTALLED for every slug.`,
  ).toBe(200);
  const body = await res.json();
  expect(
    Array.isArray(body),
    `the capability projection must be a JSON array of {slug, installed, mountAt, `
    + `requiresRole}; got ${JSON.stringify(body).slice(0, 200)}`,
  ).toBe(true);
  world.set('capabilities', body as Capability[]);
});

function caps(world: { get<T>(k: string): T }): Capability[] {
  return world.get<Capability[]>('capabilities');
}

Then('the capability list contains the slug {string}', async ({ world }, slug: string) => {
  expect(
    caps(world).map((c) => c.slug),
    `'${slug}' is ABSENT from the public capability projection. Absence is how the host `
    + `shell decides a service was never registered at all, so it will grey the entry `
    + `with "not available on this deployment" no matter how healthy the container is.`,
  ).toContain(slug);
});

Then('the capability list contains no slug starting with {string}', async ({ world }, prefix: string) => {
  const leaked = caps(world).map((c) => c.slug).filter((s) => s.startsWith(prefix));
  expect(
    leaked,
    `the public capability projection returned ${leaked.length} slug(s) starting with `
    + `'${prefix}': ${leaked.join(', ')}. Vanity profile rows are the 'fragment' kind and `
    + `are cut IN THE QUERY (findByDomainAndKindNot) precisely so this permitAll endpoint `
    + `cannot enumerate them. A leak here is an unauthenticated username oracle.`,
  ).toEqual([]);
});

Then('the capability slug {string} reports installed {string}', async ({ world }, slug: string, installed: string) => {
  const row = caps(world).find((c) => c.slug === slug);
  expect(
    row,
    `'${slug}' is absent from the capability projection, so it has no installed STATE at `
    + `all. Absent and installed=false are different facts: absent means nobody `
    + `registered the module, false means a registered module is disabled or its circuit `
    + `is open. The host greys them with different copy and only one of them is fixable `
    + `by an operator toggle.`,
  ).toBeDefined();
  expect(
    String(row!.installed),
    `'${slug}' reports installed=${row!.installed}. installed is derived per row as `
    + `enabled AND circuit-closed (CapabilityDto.from) — a registered, enabled, `
    + `circuit-closed module is the only thing the host shell will mount.`,
  ).toBe(installed);
});


// ═══════════════════════════════════════════════════════════════════════════
// BDD coverage round 2026-09-23 (services lane) — forum-bff-api#1: the phpBB
// suspend leg. forum-bff's ForumAdminController answers a ban with
// `{state: applied|pending-reconcile, op, subject, external: <outcome>, note?}`:
// 200 + state=applied when the phpBB extension really acknowledged it, 202 +
// external="stubbed" while external.forum.enabled=false short-circuits the HTTP
// call. The Then below asserts the REAL outcome the issue asks for, never the
// stub, and the lift step leaves the shared persona as it found it.
// ═══════════════════════════════════════════════════════════════════════════

function forumApi(world: { get<T>(k: string): T }): APIRequestContext {
  const ctx = world.get<APIRequestContext>('api');
  if (!ctx) {
    throw new Error('no API client — run `Given an API client signed in as the persona for this scenario` first');
  }
  return ctx;
}

When('the admin bans the forum subject {string} with the reason {string}',
  async ({ world }, subject: string, reason: string) => {
    const r = await forumApi(world).post(`/bff/forum/admin/users/${encodeURIComponent(subject)}/ban`, {
      data: { reason },
      failOnStatusCode: false,
    });
    world.set('forumBan', r);
    world.set('forumBanBody', await r.text().catch(() => ''));
  });

Then('the forum ban reached phpBB as a real applied outcome', async ({ world }) => {
  const r = world.get<APIResponse>('forumBan');
  const text = world.get<string>('forumBanBody');
  let body: Record<string, unknown> = {};
  try { body = JSON.parse(text) as Record<string, unknown>; } catch { /* asserted below */ }
  expect(r.status(), `POST /bff/forum/admin/users/{subject}/ban -> ${r.status()} ${text.slice(0, 300)}`).toBe(200);
  expect(body.state, `the ban must be APPLIED in phpBB, not pending-reconcile: ${text.slice(0, 300)}`).toBe('applied');
  expect(
    body.external,
    `the external outcome must be a real phpBB acknowledgement, never the "stubbed" short-circuit `
    + `(external.forum.enabled=false): ${text.slice(0, 300)}`,
  ).not.toBe('stubbed');
});

When('the admin lifts the forum ban on {string}', async ({ world }, subject: string) => {
  const r = await forumApi(world).delete(`/bff/forum/admin/users/${encodeURIComponent(subject)}/ban`, {
    failOnStatusCode: false,
  });
  expect([200, 202], `DELETE /bff/forum/admin/users/${subject}/ban -> ${r.status()}`).toContain(r.status());
});
