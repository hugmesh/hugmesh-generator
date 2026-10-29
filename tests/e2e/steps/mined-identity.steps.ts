// mined-identity.steps.ts — step definitions for the `mined-identity` domain:
// the M1 IDENTITY unit (login-ui, user-ui, user-mesh-ui, host-shell,
// user-bff-api, auth-core).
//
// WHY THIS FILE EXISTS. A read-only mining pass over those six repos derived a
// set of scenarios FROM REAL CODE — a guard's branch, a controller's error path,
// a seed row, a component test — and checked each against the central suite with
// comments stripped. What it found is that the whole IDENTITY tier of the
// route-access seed (`/user/**`, `/bff/user/**`, `/bff/me/**`, `/bff/mod/**`,
// the `/bff/public/*` anonymous rows and the three explicit-DENY internal-ingest
// rows) is asserted NOWHERE: features/rbac/gateway-route-access.feature covers
// admin/games/homeserver paths only, and features/uncovered-services/
// route-contract.feature covers wiki/owncast/tube/forum/character-*.
//
// TWO KINDS OF STEP LIVE HERE, deliberately kept apart — same split as
// uncovered-services.steps.ts, and for the same reason:
//
//   1. CONTRACT steps (OFFLINE; the `@harness` features). They read the
//      COMMITTED artefacts in THIS repo — the route-access seed and the
//      fe-gateway route table — and decide against them. They run with every
//      environment DOWN, which is the only tier that has value on a machine
//      where nothing is up. Nothing here reads a sibling checkout
//      (../hugmesh-login-ui, ../hugmesh-host-shell): those trees are not part of
//      this repo, so a step that depended on one would pass here and fail in CI.
//      The code they were MINED from is cited in the feature files by path:line,
//      which is documentation, not an assertion.
//
//   2. DRIVEN steps (the `@env:docker` features). Every one of them needs a live
//      mesh. They are tagged `@env:docker`, which makes world.ts's Before hook
//      probe the door and skip with a reason NAMING THE COMMAND TO START IT.
//      That is the loud skip this unit's brief demands; there is no silent one.
//
// THE SEED IS THE AUTHORITY, NOT THE TS MIRROR. specs/rbac-route-access.ts says
// it is "copied 1:1" from the seed. It is not: it carries 50 rows against the
// seed's ~150 and has NO `allow` column at all, so it cannot express the three
// explicit-DENY rows the seed relies on. Rather than assert the identity tier
// through a mirror that does not carry it, `seedDecide()` below re-implements
// the REAL gateway decision — net.hugmesh.gateway.cache.GatewayRouteAccessService
// .decide(): longest url_pattern wins by STRING LENGTH, deny-wins among the rows
// at that length, a PUBLIC row admits anyone, governed-but-ungranted is DENY and
// an ungoverned path is NO_RULE (which the gateway FORWARDS on the coarse
// authenticated() floor — a materially different answer from DENY, and the whole
// point of the `/bff/session` scenario). The drift between the mirror and the
// seed is then measured by ONE scenario instead of being silently inherited by
// all of them.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect, request as playwrightRequest } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Given, When, Then, After } from './world';
import { accessRows, feRoutes, AccessRow } from './uncovered-services.steps';
import { ROUTE_ACCESS } from '../specs/rbac-route-access';
import { personaPassword } from '../specs/helpers';

const ROUTE_ACCESS_SQL = 'specs/cluster/manifests/route-access/initdb/20-schema.sql';
const FE_ROUTES_YML = 'tests/stack/gateway-routes/fe/application-routes.yml';
const FE = 'hugmesh-fe-gateway';

// ═══════════════════════════════════════════════════════════════════════════
// 1. THE ROUTE-ACCESS SEED, DECIDED THE WAY THE GATEWAY DECIDES IT  (OFFLINE)
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Translate one Spring `AntPathMatcher` pattern into an anchored RegExp.
 *
 * `/**` is the case that matters and the one a naive `startsWith` gets wrong in
 * BOTH directions: it must match the prefix ITSELF (`/bff/user/**` governs
 * `/bff/user`) and every `/`-delimited subpath, but must NOT swallow a sibling
 * that merely shares a textual prefix (`/admin/**` must not match
 * `/administrator`). `*` is single-segment; `?` is one non-separator character.
 */
function antToRegExp(pattern: string): RegExp {
  let out = '';
  let i = 0;
  while (i < pattern.length) {
    if (pattern.startsWith('/**', i)) { out += '(?:/.*)?'; i += 3; continue; }
    if (pattern.startsWith('**', i)) { out += '.*'; i += 2; continue; }
    if (pattern[i] === '*') { out += '[^/]*'; i += 1; continue; }
    if (pattern[i] === '?') { out += '[^/]'; i += 1; continue; }
    out += pattern[i].replace(/[.+^${}()|[\]\\]/g, '\\$&');
    i += 1;
  }
  return new RegExp(`^${out}$`);
}

function antMatches(pattern: string, path: string): boolean {
  return antToRegExp(pattern).test(path);
}

/** The three answers the real gateway filter distinguishes. NO_RULE is NOT a
 *  synonym for DENY: the filter FORWARDS it on the coarse authenticated() floor
 *  (GatewayRouteAccessFilter — "ALLOW / NO_RULE -> forward"). */
export type SeedDecision = 'ALLOW' | 'DENY' | 'NO_RULE';

/** The Casdoor-free sentinel a feature uses to mean "holds no role at all". */
const ANONYMOUS = 'ROLE_ANONYMOUS';

/**
 * Decide `path` on `gateway` for a principal holding exactly `roles`, against the
 * COMMITTED seed. A faithful port of GatewayRouteAccessService.decide() minus the
 * two legs this offline lane cannot model and does not claim to: the per-row
 * `domain` scope (every canonical seed row is unscoped) and the `mfa_required`
 * floor (features/moderation-media/mfa-privileged-floor.feature owns that, live).
 */
export function seedDecide(gateway: string, path: string, roles: string[]): SeedDecision {
  const rows = accessRows().filter((r) => r.gateway === gateway);
  let bestLen = -1;
  for (const r of rows) {
    if (!antMatches(r.pattern, path)) continue;
    if (r.pattern.length > bestLen) bestLen = r.pattern.length;
  }
  if (bestLen < 0) return 'NO_RULE';               // ungoverned path
  let allowed = false;
  let explicitDeny = false;
  for (const r of rows) {
    if (r.pattern.length !== bestLen || !antMatches(r.pattern, path)) continue;
    if (r.allow && r.role.toUpperCase() === 'PUBLIC') { allowed = true; continue; }
    if (!roles.includes(r.role)) continue;
    if (r.allow) allowed = true; else explicitDeny = true;
  }
  if (explicitDeny) return 'DENY';                 // deny-wins at the longest match
  return allowed ? 'ALLOW' : 'DENY';               // governed-but-ungranted => deny
}

/** Rows at the longest matching pattern, for a failure message that shows the
 *  reader WHICH rows decided rather than only what they decided. */
function decidingRows(gateway: string, path: string): AccessRow[] {
  const rows = accessRows().filter((r) => r.gateway === gateway && antMatches(r.pattern, path));
  const bestLen = Math.max(-1, ...rows.map((r) => r.pattern.length));
  return rows.filter((r) => r.pattern.length === bestLen);
}

function describeRows(rows: AccessRow[]): string {
  return rows.length === 0
    ? '<no matching row>'
    : rows.map((r) => `${r.pattern} ${r.role} allow=${r.allow}`).join(' | ');
}

Then(
  'the route-access seed decides {string} for a principal holding only {string} at {string}',
  async ({}, expected: string, role: string, path: string) => {
    const roles = role === ANONYMOUS ? [] : [role];
    const got = seedDecide(FE, path, roles);
    expect(
      got,
      `${ROUTE_ACCESS_SQL}: a principal holding ${role === ANONYMOUS ? 'NO role' : role} at `
      + `'${path}' on ${FE}. Deciding rows (longest matching url_pattern): `
      + `${describeRows(decidingRows(FE, path))}. NO_RULE is NOT DENY — the gateway `
      + `FORWARDS an ungoverned path on the coarse authenticated() floor.`,
    ).toBe(expected);
  },
);

/**
 * The counterpart of the existing `... seed grants ... on the fe gateway`. An
 * EXPLICIT deny row (allow=false) and an ABSENT row are different contracts: the
 * absent one inherits whatever `**` floor sits above it, which for
 * `/bff/user/internal/**` is the ROLE_USER floor on `/bff/user/**` — i.e. every
 * signed-in member reaching user-bff's service-only mesh-device registry.
 */
Then(
  'the route-access seed DENIES {string} at {string} on the fe gateway',
  async ({}, role: string, pattern: string) => {
    const at = accessRows().filter((r) => r.gateway === FE && r.pattern === pattern);
    expect(
      at.map((r) => `${r.role} allow=${r.allow}`),
      `${ROUTE_ACCESS_SQL} seeds NO fe-gateway row at all for '${pattern}'. An absent row is `
      + `not a deny: the longest '**' floor above it decides instead, which is exactly how a `
      + `service-only ingest surface becomes reachable by every authenticated member.`,
    ).not.toHaveLength(0);
    const row = at.find((r) => r.role === role);
    expect(
      row,
      `'${pattern}' carries rows [${describeRows(at)}] but none keyed on ${role}.`,
    ).toBeDefined();
    expect(
      row!.allow,
      `the '${pattern}' -> ${role} row must be an EXPLICIT DENY (allow=false). `
      + `Flipping it to allow=true re-opens the surface silently — the row keeps existing, `
      + `so a row-EXISTENCE assertion would stay green.`,
    ).toBe(false);
  },
);

/**
 * There must be no route in the fe-gateway table whose Path predicate is
 * dedicated to this prefix. Deliberately NOT "no route matches this path": the
 * table ends with a `/**` catch-all to the Angular host shell, so EVERY path
 * matches something. The contract being pinned is that the prefix has no route
 * of its OWN pointing at a remote's container.
 */
Then(
  'the fe gateway declares no dedicated route for the path prefix {string}',
  async ({}, prefix: string) => {
    const hits = feRoutes()
      .flatMap((r) => r.paths.map((p) => ({ id: r.id, uri: r.uri, path: p })))
      .filter((x) => x.path === prefix || x.path.startsWith(`${prefix}/`));
    expect(
      hits.map((x) => `${x.id} ${x.path} -> ${x.uri}`),
      `${FE_ROUTES_YML} DOES declare a dedicated route for '${prefix}'. Mounting a remote `
      + `whose components do not exist renders a blank page, and a blank page passes almost `
      + `any assertion — which is why the absence is the thing worth pinning.`,
    ).toHaveLength(0);
  },
);

/**
 * THE DRIFT MEASUREMENT, and the reason this whole file decides against the SEED
 * rather than against specs/rbac-route-access.ts.
 *
 * That mirror's own header says "copied 1:1 from manifests/route-access/
 * schema.sql. Keep in lockstep with that file." It is not in lockstep: the whole
 * identity tier is missing from it. Every @layer:gateway scenario in
 * features/rbac/gateway-route-access.feature asks the mirror, so the paths the
 * mirror never learned about simply cannot be asserted there — they answer DENY
 * by default-deny and look like a correct negative.
 *
 * This scenario is tagged @fail: it is a DEFECT DETECTOR, expected red, and
 * playwright-bdd maps @fail to test.fail() so the lane stays honest without
 * going red for everyone. When someone refreshes the mirror, test.fail() flips
 * to "expected to fail, but passed" and forces the tag off. Fixing the mirror is
 * NOT done here on purpose: several lanes assert against that file concurrently,
 * and a shared-oracle edit from a feature branch is how three divergent persona
 * lists got into this repo.
 */
Then('the route-access oracle mirrors every fe gateway allow row in the seed', async ({}) => {
  // The two artefacts spell the anonymous role differently — the seed says
  // PUBLIC (what the gateway's isPublic() reads), the mirror says
  // ROLE_ANONYMOUS. Fold them before comparing, or every public row reports as
  // drift and hides the real ones.
  const fold = (role: string) => (role.toUpperCase() === 'PUBLIC' ? ANONYMOUS : role);
  const mirrored = new Set(
    ROUTE_ACCESS.filter((r) => r.gateway === FE).map((r) => `${r.urlPattern} ${fold(r.role)}`),
  );
  const missing = accessRows()
    .filter((r) => r.gateway === FE && r.allow)
    .map((r) => `${r.pattern} ${fold(r.role)}`)
    .filter((key) => !mirrored.has(key));
  expect(
    [...new Set(missing)].sort(),
    `specs/rbac-route-access.ts claims to be the seed "copied 1:1", and the @layer:gateway `
    + `scenarios in features/rbac/ ask IT, not the seed. Every fe-gateway allow row it does `
    + `not carry is a path those scenarios answer DENY for by default-deny — a stale mirror `
    + `reads exactly like a correct negative. Rows in ${ROUTE_ACCESS_SQL} but not in the mirror:`,
  ).toEqual([]);
});

// ═══════════════════════════════════════════════════════════════════════════
// 2. DRIVEN STEPS — every one needs a live mesh (@env:docker)
// ═══════════════════════════════════════════════════════════════════════════

const openContexts: APIRequestContext[] = [];

After(async () => {
  while (openContexts.length) await openContexts.pop()!.dispose().catch(() => { /* torn down */ });
});

/** A signed-in API client for `handle`, over the scenario's own baseURL. Mirrors
 *  rbac.steps.ts's loginApiAs — same native `/bff/login` the browser lane uses,
 *  so the two cannot disagree about what signing in means. */
async function apiAs(baseURL: string | undefined, handle: string): Promise<APIRequestContext> {
  const client = await playwrightRequest.newContext({ baseURL, ignoreHTTPSErrors: true });
  openContexts.push(client);
  const r = await client.post('/bff/login', {
    data: { username: handle, password: personaPassword(handle) },
  });
  expect(r.status(), `native login ${handle} -> ${r.status()}`).toBe(200);
  return client;
}

export function api(world: { get<T>(k: string): T }): APIRequestContext {
  return world.get<APIRequestContext>('api');
}

/** Record a response plus the call that produced it, so a failing status
 *  assertion names the verb and path instead of a bare number. */
export async function record(world: any, label: string, r: APIResponse): Promise<void> {
  world.set('response', r);
  world.set('responseLabel', label);
  world.set('responseBody', await r.text().catch(() => ''));
}

// ── profile reads/writes (the owner==subject wall) ───────────────────────────

const PROFILE = '/bff/user/profile';

Given('an API client signed in as the seeded persona {string}',
  async ({ baseURL, world }, handle: string) => {
    world.set('api', await apiAs(baseURL, handle));
    world.set('username', handle);
  });

When('the API client GETs {string}', async ({ world }, path: string) => {
  await record(world, `GET ${path}`, await api(world).get(path));
});

Then('the response status is {int}', async ({ world }, expected: number) => {
  const r = world.get<APIResponse>('response');
  expect(
    r.status(),
    `${world.get<string>('responseLabel')} -> ${r.status()} `
    + `${JSON.stringify(world.get<string>('responseBody')).slice(0, 300)}`,
  ).toBe(expected);
});

Then('the response error message matches {string}', async ({ world }, needle: string) => {
  const body = world.get<string>('responseBody');
  expect(
    body,
    `${world.get<string>('responseLabel')} must explain WHY it refused — the profile editor `
    + `shows the server's message, so an empty or generic body becomes "Please try again" in `
    + `front of a user whose input can never succeed.`,
  ).toMatch(new RegExp(needle, 'i'));
});

Then('the response header {string} contains {string}',
  async ({ world }, header: string, needle: string) => {
    const r = world.get<APIResponse>('response');
    expect(
      r.headers()[header.toLowerCase()] ?? '<absent>',
      `${world.get<string>('responseLabel')} response header ${header}`,
    ).toContain(needle);
  });

Then('the response header {string} is {string}',
  async ({ world }, header: string, expected: string) => {
    const r = world.get<APIResponse>('response');
    expect(
      r.headers()[header.toLowerCase()] ?? '<absent>',
      `${world.get<string>('responseLabel')} response header ${header}`,
    ).toBe(expected);
  });

/** The IDOR probe. The body's userId is the attacker-controlled field
 *  ProfileController deliberately ignores (owner = jwt.getSubject()), so a write
 *  naming the victim must land on the ATTACKER's own row. */
When('the API client PUTs a profile whose body userId names {string} and displayName {string}',
  async ({ world }, victim: string, displayName: string) => {
    const r = await api(world).put(PROFILE, { data: { userId: victim, displayName } });
    await record(world, `PUT ${PROFILE} {userId:'${victim}', displayName:'${displayName}'}`, r);
  });

When('the API client PUTs a profile with displayName {string} and screenReaderName {string}',
  async ({ world }, displayName: string, screenReaderName: string) => {
    const r = await api(world).put(PROFILE, { data: { displayName, screenReaderName } });
    await record(world, `PUT ${PROFILE} {displayName:'${displayName}', `
      + `screenReaderName:'${screenReaderName}'}`, r);
  });

When('the API client PUTs a profile with displayName {string} and no screenReaderName',
  async ({ world }, displayName: string) => {
    const r = await api(world).put(PROFILE, { data: { displayName } });
    await record(world, `PUT ${PROFILE} {displayName:'${displayName}'} (no screenReaderName)`, r);
  });

/** U+200D ZERO WIDTH JOINER, spelled as an escape rather than pasted: an
 *  invisible character in a source file is unreviewable, and this one is the
 *  whole point of the assertion. */
When('the API client PUTs a profile whose displayName carries a zero-width joiner',
  async ({ world }) => {
    const displayName = 'Rin\u200Dbot';
    const r = await api(world).put(PROFILE, { data: { displayName } });
    await record(world, `PUT ${PROFILE} {displayName:'Rin<U+200D>bot'}`, r);
  });

Then('my own profile displayName is {string}', async ({ world }, expected: string) => {
  const r = await api(world).get(PROFILE);
  expect(r.status(), `GET ${PROFILE} (own, re-read)`).toBe(200);
  expect((await r.json()).displayName, 'my own profile row after the write').toBe(expected);
});

Given('the seeded persona {string} holds a profile with displayName {string}',
  async ({ baseURL, world }, handle: string, displayName: string) => {
    const victim = await apiAs(baseURL, handle);
    const r = await victim.put(PROFILE, { data: { displayName } });
    expect(r.status(), `seeding ${handle}'s profile -> ${r.status()}`).toBe(200);
    world.set(`victimApi:${handle}`, victim);
  });

/** The half of an IDOR test that is usually left out: RE-READ the victim's own
 *  row through the VICTIM's session. A 404 or a 200 on the attacker's call
 *  proves nothing about whether the write landed somewhere. */
Then('the seeded persona {string} still holds displayName {string}',
  async ({ world }, handle: string, expected: string) => {
    const victim = world.get<APIRequestContext>(`victimApi:${handle}`);
    const r = await victim.get(PROFILE);
    expect(r.status(), `GET ${PROFILE} as ${handle} (victim re-read)`).toBe(200);
    expect(
      (await r.json()).displayName,
      `${handle}'s OWN row must be untouched by another principal's write. A write that `
      + `"failed" for the attacker but mutated the victim is the failure mode an `
      + `attacker-side status assertion cannot see.`,
    ).toBe(expected);
  });

// ── the two avatar bodies, across a sign-out ─────────────────────────────────

When('the API client remembers this response body as {string}', async ({ world }, key: string) => {
  const r = world.get<APIResponse>('response');
  world.set(`bytes:${key}`, await r.body());
});

Then('the remembered response bodies {string} and {string} differ',
  async ({ world }, a: string, b: string) => {
    const left = world.get<Buffer>(`bytes:${a}`);
    const right = world.get<Buffer>(`bytes:${b}`);
    expect(
      Buffer.compare(left, right) === 0,
      `the avatar body served to '${a}' and to '${b}' is byte-identical (${left.length} bytes). `
      + `The URL is the same for every user — the owner comes from the JWT subject, never the `
      + `path — so identical bytes across two identities means a cache, not a coincidence.`,
    ).toBe(false);
  });

// ── the complete-registration a11y gate (login-ui) ───────────────────────────

When('I type the display name {string}', async ({ page }, value: string) => {
  await page.getByTestId('register-display-name').fill(value);
});

When('I type the screen-reader name {string}', async ({ page }, value: string) => {
  await page.getByTestId('register-screen-reader-name').fill(value);
});

Then('the element with test id {string} is not disabled', async ({ page }, testId: string) => {
  await expect(page.getByTestId(testId)).toBeEnabled();
});

Then('the element with test id {string} is described by {string}',
  async ({ page }, testId: string, id: string) => {
    const tokens = (await page.getByTestId(testId).getAttribute('aria-describedby')) ?? '';
    expect(
      tokens.split(/\s+/).filter(Boolean),
      `[data-testid=${testId}] aria-describedby='${tokens}'. A disabled submit that does not `
      + `point at the reason is, to a screen-reader user, a control that simply stopped working.`,
    ).toContain(id);
  });

Then('the element with test id {string} does not contain the text {string}',
  async ({ page }, testId: string, text: string) => {
    await expect(page.getByTestId(testId)).not.toContainText(text);
  });

Then('the element with test id {string} is an assertive live region',
  async ({ page }, testId: string) => {
    const el = page.getByTestId(testId);
    await expect(el).toBeVisible();
    expect(
      await el.getAttribute('aria-live'),
      `[data-testid=${testId}] must be aria-live="assertive". A sign-in error that is only `
      + `VISIBLE is, to a screen-reader user, an error that never happened — they re-tab the `
      + `form looking for what changed.`,
    ).toBe('assertive');
  });

// ── the denied landing (host-shell) ──────────────────────────────────────────

Then('the current URL carries a denied query naming {string}',
  async ({ page }, attempted: string) => {
    const url = new URL(page.url());
    expect(
      url.searchParams.get('denied'),
      `landed on ${page.url()}. roleGuard sends a SIGNED-IN caller who lacks the role to `
      + `/home?denied=<attempted path> (role-guard.factory.ts DENIED_PATH); /login is the `
      + `ANONYMOUS destination, and answering an authorization failure with it tells a user `
      + `who just signed in that they are not signed in.`,
    ).toBe(attempted);
  });

// ── avatar uploads (the bytes the no-store contract protects) ────────────────
//
// The three payloads are synthesised here rather than committed as fixture
// files: each is a handful of magic bytes, and a binary fixture in git is a
// thing nobody can review. PNG_1x1 is the same base64 spec 28 and
// moderation-media.steps.ts already use; the GIF is a DIFFERENT format on
// purpose, so the two-identity scenario compares bytes that cannot coincide.

/** A genuinely-valid 1x1 PNG — passes ImageSniffer's magic-byte gate. */
const AVATAR_PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
);
/** A valid 1x1 GIF87a — a DIFFERENT sniffed type, so the bytes cannot collide
 *  with the PNG above even if both were re-encoded. */
const AVATAR_GIF_1x1 = Buffer.from(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  'base64',
);
/** SVG: an XML/script vector. ImageSniffer.detect() reports null for it
 *  deliberately, so it must never reach storage. */
const AVATAR_SVG = Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
  'utf8',
);

const AVATAR_UPLOAD = '/bff/user/profile/avatar';

async function uploadAvatar(
  world: any, name: string, mimeType: string, buffer: Buffer,
): Promise<APIResponse> {
  const r = await api(world).post(AVATAR_UPLOAD, {
    multipart: { file: { name, mimeType, buffer } },
  });
  await record(world, `POST ${AVATAR_UPLOAD} (${mimeType}, ${buffer.length} bytes)`, r);
  return r;
}

Given('I have uploaded a 1x1 PNG avatar through the API client', async ({ world }) => {
  const r = await uploadAvatar(world, 'avatar.png', 'image/png', AVATAR_PNG_1x1);
  expect(
    r.status(),
    `seeding an avatar so the no-store contract has bytes to protect: `
    + `POST ${AVATAR_UPLOAD} -> ${r.status()} ${world.get<string>('responseBody').slice(0, 200)}`,
  ).toBe(200);
});

Given('I have uploaded a distinct 1x1 GIF avatar through the API client', async ({ world }) => {
  const r = await uploadAvatar(world, 'avatar.gif', 'image/gif', AVATAR_GIF_1x1);
  expect(
    r.status(),
    `POST ${AVATAR_UPLOAD} (GIF) -> ${r.status()} `
    + `${world.get<string>('responseBody').slice(0, 200)}. ImageSniffer.java:26 accepts GIF; `
    + `a refusal here means the SERVER narrowed, and the two-identity comparison below would `
    + `then be comparing one identity's bytes with a 404.`,
  ).toBe(200);
});

When('I upload an SVG as my avatar through the API client', async ({ world }) => {
  await uploadAvatar(world, 'payload.svg', 'image/svg+xml', AVATAR_SVG);
});

// ── the user remote's profile editor ─────────────────────────────────────────
//
// A SEPARATE step from `I type the display name` on purpose: the login remote's
// complete-registration card and the user remote's profile editor are different
// components with different test ids (register-display-name vs
// profile-displayName), and folding them into one step would make a failure
// report the wrong screen.
When('I type the profile display name {string}', async ({ page }, value: string) => {
  await page.getByTestId('profile-displayName').fill(value);
});

// ═══════════════════════════════════════════════════════════════════════════
// 3. THE API CLIENT'S WRITE VERBS + RESPONSE-SHAPE VOCABULARY  (identity lane,
//    2026-09-23 — sign-out (#549/#569), the appeal surface (#480), /bff/me's
//    status field (#311) and the register/provision legs (onboarding.steps.ts
//    builds on these).
// ═══════════════════════════════════════════════════════════════════════════
//
// These sit beside `the API client GETs {string}` / `the response status is
// {int}` above and read/write the SAME world keys ('api', 'response',
// 'responseLabel', 'responseBody'), so a scenario can open its client with any
// of the existing Givens (`I hold an API session as the persona for this
// scenario`, `I hold an anonymous API client`, `an API client signed in as …`)
// and assert with the steps already here. Every JSON assertion parses
// world['responseBody'] — the text `record()` captured — rather than calling
// r.json() a second time, so a body that was already read cannot surprise it.

/** Parse a JSON step argument, naming the step on a typo instead of letting
 *  Playwright serialise the raw string as the request body (which the BFF would
 *  answer 400 to, and which would read like a server defect). */
function parseJsonArg(label: string, raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`${label}: the body argument is not valid JSON — ${(e as Error).message}\n${raw}`);
  }
}

When('the API client POSTs {string}', async ({ world }, path: string) => {
  await record(world, `POST ${path}`, await api(world).post(path, { data: {} }));
});

When('the API client POSTs {string} with body {string}',
  async ({ world }, path: string, body: string) => {
    const data = parseJsonArg(`POST ${path}`, body);
    await record(world, `POST ${path} ${body}`, await api(world).post(path, { data }));
  });

When('the API client DELETEs {string}', async ({ world }, path: string) => {
  await record(world, `DELETE ${path}`, await api(world).delete(path));
});

/** The recorded body as JSON, or a failure that shows the first 300 bytes of
 *  what actually came back — a 502 HTML page is the usual reason this throws. */
function responseJson(world: any): unknown {
  const body = world.get('responseBody') as string;
  try {
    return JSON.parse(body);
  } catch {
    throw new Error(
      `${world.get('responseLabel')} did not answer JSON: ${JSON.stringify(body).slice(0, 300)}`,
    );
  }
}

/** Walk a dotted path (`counts.byInterface.cli`) through a parsed body. */
function fieldAt(root: unknown, dotted: string): { present: boolean; value: unknown } {
  let cur: unknown = root;
  for (const key of dotted.split('.')) {
    if (cur === null || typeof cur !== 'object' || !(key in (cur as Record<string, unknown>))) {
      return { present: false, value: undefined };
    }
    cur = (cur as Record<string, unknown>)[key];
  }
  return { present: true, value: cur };
}

Then('the response JSON field {string} is present', async ({ world }, field: string) => {
  const json = responseJson(world);
  expect(
    fieldAt(json, field).present,
    `${world.get<string>('responseLabel')} body has no '${field}' field. Body keys: `
    + `${JSON.stringify(json && typeof json === 'object' ? Object.keys(json as object) : json)}`,
  ).toBe(true);
});

// `Then the response JSON field {string} is {string}` is NOT defined here: main's
// admin.steps.ts (domain-registry lane) defines the identical text over the same
// world keys ('responseBody' / 'responseLabel'), and a second definition makes
// bddgen fail with "Multiple definitions matched scenario step" for EVERY
// feature that uses it. The features in this lane use that one.

Then('the response body is a JSON array', async ({ world }) => {
  const json = responseJson(world);
  expect(
    Array.isArray(json),
    `${world.get<string>('responseLabel')} must answer a JSON array; got `
    + `${JSON.stringify(json).slice(0, 200)}`,
  ).toBe(true);
});

// ── the API client's cookie jar ──────────────────────────────────────────────
//
// Playwright's APIRequestContext keeps its own jar and honours Set-Cookie the way
// a browser does, INCLUDING an expiry (Max-Age=0 drops the cookie). So "the
// session cookie is gone after sign-out" is observable on the client, not only
// inferred from the header — which is the half a header assertion cannot see:
// a Set-Cookie whose attributes do not match the mint (name, Path, host-only)
// is a no-op for the browser and would still "contain Max-Age=0".

/** What the jar is being read AFTER. A cookie assertion is legal straight after
 *  'I hold an API session as the persona for this scenario' — before any request
 *  step has set world['responseLabel'] — and world.get() throws on an unset key
 *  (by design), so reading the label unguarded turned that perfectly ordered
 *  step into "world['responseLabel'] was never set" on every live run. */
function jarMoment(world: any): string {
  return world.has('responseLabel') ? world.get<string>('responseLabel') : 'the API session sign-in';
}

async function cookieNames(world: any): Promise<string[]> {
  const state = await api(world).storageState();
  return state.cookies.map((c) => c.name);
}

Then('the API client holds a cookie named {string}', async ({ world }, name: string) => {
  expect(await cookieNames(world), `cookie jar after ${jarMoment(world)}`)
    .toContain(name);
});

Then('the API client holds no cookie named {string}', async ({ world }, name: string) => {
  expect(
    await cookieNames(world),
    `'${name}' is still in the jar after ${jarMoment(world)}. A sign-out `
    + `that answers 204 but leaves the cookie alive is the exact no-op hugmesh-generator#549 `
    + `fixed — the next GET /bff/session re-hydrates the session as if nothing happened.`,
  ).not.toContain(name);
});

// ── decision 60 / hugmesh-generator#569: the BFFs' positive-swap cache is pinned OFF ──
//
// The gateway's own bff-exchange cache TTL was pinned to 0 by #398; admin-bff
// and mod-bff carry a MIRROR of that cache (APP_BFF_EXCHANGE_CACHE_TTL_MS) which
// used to default to 5 s — a five-second window in which a revoked or banned
// session keeps swapping successfully. #569 pins it to "0" on BOTH lanes.
// tests/scripts/test-fe-bff-route-lane-parity.sh guards the same value with a
// mutation battery; this row makes the contract visible in the BDD lane under
// its issue tag, reading the SAME committed artefacts (never a running pod).
// The LIVE half — a revoked session loses its swap immediately — is
// features/mined-identity/sign-out-ends-session.feature.

const COMPOSE_YAML = 'tests/stack/compose.local.yaml';

function repoFile(rel: string): string {
  const abs = path.resolve(__dirname, '..', '..', '..', rel);
  if (!fs.existsSync(abs)) throw new Error(`${rel} does not exist at ${abs}`);
  return fs.readFileSync(abs, 'utf8');
}

/** The value of `name` under compose service `service` (top-level `services:`
 *  key at two-space indent), or null when the block or the key is absent. */
function composeEnvValue(service: string, name: string): string | null {
  const text = repoFile(COMPOSE_YAML);
  const lines = text.split('\n');
  const start = lines.findIndex((l) => l === `  ${service}:`);
  if (start < 0) throw new Error(`${COMPOSE_YAML} has no service block '  ${service}:'`);
  for (let i = start + 1; i < lines.length; i += 1) {
    const l = lines[i];
    if (/^  [A-Za-z0-9_.-]+:\s*$/.test(l)) break;               // next service block
    const m = l.match(new RegExp(`^\\s+${name}:\\s*"?([^"\\s]*)"?\\s*(#.*)?$`));
    if (m) return m[1];
  }
  return null;
}

/** The value of env `name` in a cluster Deployment manifest, accepting both the
 *  inline `- { name: X, value: "0" }` and the two-line `- name: X` / `value: "0"`
 *  spellings — the two files use the former today, but a reformat must not read
 *  as a dropped pin. */
function clusterEnvValue(manifest: string, name: string): string | null {
  const text = repoFile(manifest);
  const inline = text.match(new RegExp(`\\{\\s*name:\\s*${name}\\s*,\\s*value:\\s*"?([^"}\\s]*)"?\\s*\\}`));
  if (inline) return inline[1];
  const twoLine = text.match(new RegExp(`-\\s*name:\\s*${name}\\s*\\n\\s*value:\\s*"?([^"\\s]*)"?`));
  return twoLine ? twoLine[1] : null;
}

Then('the {string} lane pins the environment variable {string} to {string} for {string}',
  async ({}, lane: string, name: string, expected: string, service: string) => {
    let got: string | null;
    let where: string;
    if (lane === 'compose') {
      where = `${COMPOSE_YAML} service '${service}'`;
      got = composeEnvValue(service, name);
    } else if (lane === 'cluster') {
      const manifest = `specs/cluster/manifests/${service.replace(/^hugmesh-/, '')}/deployment.yaml`;
      where = manifest;
      got = clusterEnvValue(manifest, name);
    } else {
      throw new Error(`unknown lane '${lane}' — legal lanes: compose, cluster`);
    }
    expect(
      got,
      `${where} must pin ${name}="${expected}" explicitly. An ABSENT pin is not "0": the `
      + `application default is what the pin exists to override, and a lane that drops the `
      + `line silently reopens the positive-swap window decision 60 closed.`,
    ).toBe(expected);
  });

/** The ABSENCE of a header, as its own step: `the response header X is "<absent>"`
 *  reads as an Examples placeholder inside a Scenario Outline, and a gateway
 *  refusal vs. an app-side refusal is told apart by exactly this header. */
Then('the response carries no header {string}', async ({ world }, header: string) => {
  const r = world.get<APIResponse>('response');
  expect(
    r.headers()[header.toLowerCase()],
    `${world.get<string>('responseLabel')} carries ${header}=${r.headers()[header.toLowerCase()]}. `
    + `For X-Route-Denied that means the GATEWAY refused the request and the BFF never saw `
    + `it — a different refusal from the app-side one this scenario asserts.`,
  ).toBeUndefined();
});
