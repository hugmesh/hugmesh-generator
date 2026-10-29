// admin.steps.ts — step definitions for features/admin/ (BDD coverage lane
// admin-platform, 2026-09-23): the admin-bff plane behind the admin-ui remote —
// route-access write validation, the phone-fleet lock plane, the MFA role
// policy and the domain registry.
//
// TWO TIERS, TWO KINDS OF HONESTY:
//   * OFFLINE — reads committed files of THIS repository (the cluster
//     route-access seed, the kind admin-bff Deployment, the compose stack file)
//     and, where a sibling checkout is present, its SOURCE (hugmesh-admin-ui's
//     route table, hugmesh-admin-bff-api's PhoneLockConfig). A missing sibling
//     SKIPS with the path searched (governance-sources.siblingSkipReason); it
//     never defaults and never passes vacuously.
//   * LIVE (@env:docker / @env:kind) — drives the real admin-bff through the
//     mesh's front door with the SAME API-client vocabulary the identity lane
//     uses: `Given an API client signed in as the persona for this scenario`
//     (rbac.steps.ts, world['api']) and `Then the response status is {int}`
//     (mined-identity.steps.ts, world['response'|'responseLabel'|'responseBody']).
//     The steps below WRITE those same world keys so the shared Then reads them.
//
// WRITES. Every live step here that mutates is either a REFUSED write (the
// bare-wildcard route rule the API rejects at validation, before any row) or
// tagged @env:kind in its feature so it never lands a row in the operator's
// compose registry. A domain a scenario registers is namespaced
// `e2e-bdd-<slug>-<runId>.example.test`; there is no delete on the resource
// (soft-disable only, by design), which the feature header says out loud.
//
// STEP HYGIENE. Every step text below was grepped against tests/e2e/steps/ and
// every sibling lane worktree under /home/magus/.hugmesh-wt-sonnet/bdd-*/ before
// it was written; none duplicates an existing definition.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { Given, When, Then } from './world';
import {
  REPO_ROOT, SeedRow, canonicalRole, adminRoutes, siblingFile, siblingSkipReason, stripComments,
} from '../specs/governance-sources';

/** Comma-separated Examples cell -> trimmed list. `""` is the empty list, not [""]. */
function list(csv: string): string[] {
  return csv.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
}

function api(world: { get<T>(k: string): T }): APIRequestContext {
  return world.get<APIRequestContext>('api');
}

/** Same shape as mined-identity.steps.ts's recorder, so the shared
 *  `Then the response status is {int}` / `the response error message matches`
 *  read it. Deliberately a private twin, not an import: importing another
 *  domain's *.steps.ts would register its definitions a second time. */
async function record(world: { set<T>(k: string, v: T): void }, label: string, r: APIResponse): Promise<void> {
  world.set('response', r);
  world.set('responseLabel', label);
  world.set('responseBody', await r.text().catch(() => ''));
}

function responseJson(world: { get<T>(k: string): T }): Record<string, unknown> {
  const body = world.get<string>('responseBody');
  try {
    return JSON.parse(body) as Record<string, unknown>;
  } catch {
    throw new Error(`${world.get<string>('responseLabel')} answered a non-JSON body: ${body.slice(0, 300)}`);
  }
}

/** Walk a dotted path ('body.entries.0.idp') through parsed JSON. */
function dig(obj: unknown, dotted: string): unknown {
  let cur: unknown = obj;
  for (const k of dotted.split('.')) {
    if (cur === null || typeof cur !== 'object') return undefined;
    cur = (cur as Record<string, unknown>)[k];
  }
  return cur;
}

// ═════════════════════════════════════════════════════════════════════════════
// 1. Route-access write validation (hugmesh-admin-bff-api#57, decision 61)
// ═════════════════════════════════════════════════════════════════════════════

Then('the only bare {string} rows in the cluster seed are {string}',
  async ({ world }, pattern: string, csv: string) => {
    const rows = world.get<SeedRow[]>('seed').filter((r) => r.urlPattern === pattern);
    const got = rows.map((r) => `${r.gateway}:${canonicalRole(r.role)}`).sort();
    expect(
      got,
      `rows whose url_pattern is exactly '${pattern}'. Decision 61 = refuse (hugmesh-generator#347, `
      + `2026-09-18): AdminController.addRouteRule 400s a pattern whose first segment is a bare `
      + `wildcard, so any row here beyond the documented exception is one the admin API can never `
      + `recreate. tests/scripts/cluster_manifest_integrity.py BARE_DOUBLE_STAR_EXCEPTIONS is the `
      + `other copy of this list.`,
    ).toEqual(list(csv).sort());
    for (const r of rows) {
      expect(r.allow, `${r.gateway} '${pattern}' ${r.role} must be an allow row (a catch-all DENY is not the documented shape)`).toBe(true);
    }
  });

When('the API client POSTs a route rule with url_pattern {string} for role {string} at gateway {string}',
  async ({ world }, urlPattern: string, role: string, gateway: string) => {
    // RouteRuleRequest's JSON names are its record components (no @JsonProperty):
    // gateway / urlPattern / role / casdoorUser / allow / mfaRequired.
    const r = await api(world).post('/bff/admin/route-access', {
      data: { gateway, urlPattern, role, allow: true },
    });
    await record(world, `POST /bff/admin/route-access {gateway:'${gateway}', urlPattern:'${urlPattern}', role:'${role}'}`, r);
  });

/** spec 29's black-box rule, restated here rather than imported from
 *  moderation-media.steps.ts (a *.steps.ts import would re-register its steps):
 *  only the GATEWAY sets X-Route-Denied; a BFF-side wall (entitlement, method
 *  security) 403s WITHOUT it. */
Then('the refusal came from the gateway', async ({ world }) => {
  const r = world.get<APIResponse>('response');
  expect(r.status(), `${world.get<string>('responseLabel')} status`).toBe(403);
  expect(
    r.headers()['x-route-denied'],
    `${world.get<string>('responseLabel')} answered 403 with NO X-Route-Denied header — an app-side `
    + `refusal, so the gateway forwarded a caller the route-access rows should have stopped`,
  ).toBeTruthy();
});

Then('the refusal came from the BFF, not the gateway', async ({ world }) => {
  const r = world.get<APIResponse>('response');
  expect(r.status(), `${world.get<string>('responseLabel')} status`).toBe(403);
  expect(
    r.headers()['x-route-denied'],
    `${world.get<string>('responseLabel')} answered 403 WITH X-Route-Denied — the gateway refused a `
    + `caller the rows admit, so the wall being asserted (method security / entitlement) never ran`,
  ).toBeUndefined();
});

// ═════════════════════════════════════════════════════════════════════════════
// 2. The phone-fleet lock plane (hugmesh-admin-bff-api#8)
// ═════════════════════════════════════════════════════════════════════════════

const KIND_ADMIN_BFF_DIR = path.join(REPO_ROOT, 'specs', 'cluster', 'manifests', 'admin-bff-api');
const COMPOSE_STACK = path.join(REPO_ROOT, 'tests', 'stack', 'compose.local.yaml');
/** Spring relaxed binding of `app.phone-lock.<leg>.enabled` as an env var, plus
 *  the property spelling itself (a ConfigMap/application.yml override). */
const PHONE_LOCK_FLAG = /APP_PHONE[_-]?LOCK_|app\.phone-lock\./i;

function nonCommentLines(file: string): string[] {
  return fs.readFileSync(file, 'utf8').split('\n').filter((l) => !/^\s*#/.test(l));
}

Then('neither the kind admin-bff Deployment nor the compose stack sets a phone-lock leg flag',
  async ({}) => {
    const files = fs.readdirSync(KIND_ADMIN_BFF_DIR)
      .filter((f) => /\.ya?ml$/.test(f))
      .map((f) => path.join(KIND_ADMIN_BFF_DIR, f));
    expect(files.length, `${KIND_ADMIN_BFF_DIR} holds no manifests — the reader is broken`).toBeGreaterThan(0);
    expect(fs.existsSync(COMPOSE_STACK), `${COMPOSE_STACK} is missing`).toBe(true);
    files.push(COMPOSE_STACK);
    const hits: string[] = [];
    for (const f of files) {
      nonCommentLines(f).forEach((l, i) => {
        if (PHONE_LOCK_FLAG.test(l)) hits.push(`${path.relative(REPO_ROOT, f)}:${i + 1}: ${l.trim()}`);
      });
    }
    // The property #8 rests on: every enforcement leg ships DARK in both e2e
    // meshes, so a lock records authoritative DB state and reports DEGRADED.
    // The day a leg is switched on here, this names the line and the live
    // smoke of that leg becomes the scenario to write.
    expect(hits, 'phone-lock leg flags set by the generator').toEqual([]);
  });

Then('the admin-bff phone-lock legs are exactly {string}, each wired only when its flag is explicitly true',
  async ({ $testInfo }, csv: string) => {
    const src = siblingFile('hugmesh-admin-bff-api', 'src/main/java/net/hugmesh/adminbff/phone/PhoneLockConfig.java');
    if (src === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-admin-bff-api')); return; }
    const js = stripComments(src, '//');
    const legs = new Map<string, Set<string>>();
    for (const m of js.matchAll(/@ConditionalOnProperty\(\s*name\s*=\s*"app\.phone-lock\.([a-z-]+)\.enabled"\s*,\s*havingValue\s*=\s*"(true|false)"/g)) {
      if (!legs.has(m[1])) legs.set(m[1], new Set());
      (legs.get(m[1]) as Set<string>).add(m[2]);
    }
    expect([...legs.keys()].sort(), 'legs PhoneLockConfig switches on app.phone-lock.<leg>.enabled')
      .toEqual(list(csv).sort());
    for (const [leg, values] of legs) {
      // Both arms must exist: a `true` arm (the real client) AND a `false` arm
      // (the no-op that reports the leg disabled) — one without the other is a
      // leg that either can never be enabled or boots with no bean at all.
      expect([...values].sort(), `app.phone-lock.${leg}.enabled arms`).toEqual(['false', 'true']);
    }
  });

// ═════════════════════════════════════════════════════════════════════════════
// 3. The domain registry (hugmesh-admin-bff-api#83, hugmesh-admin-ui#9, #10)
// ═════════════════════════════════════════════════════════════════════════════

const DOMAINS = '/bff/admin/domains';

/** A per-run, per-scenario cluster_domain so a re-run never collides with the
 *  row the previous run left behind (there is no delete on this resource). */
function freshDomain(slug: string): { clusterDomain: string; nsPrefix: string } {
  const stamp = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  // nsPrefix IS the namespace slug and is REQUIRED (decision 29a — DomainSlug:
  // DNS-1123 label, at most 59 chars); DomainRegistryService.create refuses the
  // slug BEFORE it looks at idp, so a probe of the idp vocabulary must carry a
  // valid one or it 400s for the wrong reason.
  const nsPrefix = `e2e-bdd-${slug}-${stamp}`.toLowerCase().replace(/[^a-z0-9-]/g, '-').slice(0, 59);
  return { clusterDomain: `${nsPrefix}.example.test`, nsPrefix };
}

When('the API client registers the domain {string} with idp {string}',
  async ({ world }, slug: string, idp: string) => {
    const { clusterDomain, nsPrefix } = freshDomain(slug);
    world.set('clusterDomain', clusterDomain);
    const r = await api(world).post(DOMAINS, { data: { clusterDomain, nsPrefix, brand: 'e2e-bdd', idp } });
    await record(world, `POST ${DOMAINS} {clusterDomain:'${clusterDomain}', idp:'${idp}'}`, r);
  });

When('the API client registers the domain {string} without choosing an IdP',
  async ({ world }, slug: string) => {
    const { clusterDomain, nsPrefix } = freshDomain(slug);
    world.set('clusterDomain', clusterDomain);
    const r = await api(world).post(DOMAINS, { data: { clusterDomain, nsPrefix, brand: 'e2e-bdd' } });
    await record(world, `POST ${DOMAINS} {clusterDomain:'${clusterDomain}'} (no idp)`, r);
  });

When('the API client reads back the registered domain', async ({ world }) => {
  const clusterDomain = world.get<string>('clusterDomain');
  const r = await api(world).get(`${DOMAINS}/${encodeURIComponent(clusterDomain)}`);
  await record(world, `GET ${DOMAINS}/${clusterDomain}`, r);
});

When('the API client soft-disables the registered domain', async ({ world }) => {
  const clusterDomain = world.get<string>('clusterDomain');
  const r = await api(world).put(`${DOMAINS}/${encodeURIComponent(clusterDomain)}`, { data: { enabled: false } });
  await record(world, `PUT ${DOMAINS}/${clusterDomain} {enabled:false}`, r);
});

Then('the response JSON field {string} is {string}', async ({ world }, field: string, expected: string) => {
  const got = dig(responseJson(world), field);
  expect(
    got === undefined ? undefined : String(got),
    `${world.get<string>('responseLabel')} -> JSON field '${field}'`,
  ).toBe(expected);
});

Then('the response JSON carries the fields {string}', async ({ world }, csv: string) => {
  const json = responseJson(world);
  const missing = list(csv).filter((f) => dig(json, f) === undefined);
  expect(
    missing,
    `${world.get<string>('responseLabel')} -> fields absent from the JSON (present: `
    + `${Object.keys(json).join(', ')})`,
  ).toEqual([]);
});

Then('the admin console route {string} is guarded by {string}',
  async ({ $testInfo }, routePath: string, guard: string) => {
    const routes = adminRoutes();
    if (routes === null) { $testInfo.skip(true, siblingSkipReason('hugmesh-admin-ui')); return; }
    const r = routes.find((x) => x.path === routePath);
    expect(r, `hugmesh-admin-ui admin.routes.ts has no route '${routePath}'. Routes: ${routes.map((x) => x.path).join(', ')}`)
      .toBeDefined();
    expect((r as { guards: string[] }).guards, `guards on '${routePath}'`).toContain(guard);
  });

// ── the console (browser, @env:kind, ahead of admin-ui#9 / #10) ───────────────

/** The <li> in the sd-domains list for one cluster_domain — scoped by the
 *  data-cluster-domain attribute the console already renders, so a control
 *  rendered once per row is addressed on THAT row and never strict-mode-clashes
 *  with its twin on another (the exact trap hugmesh-generator#388 recorded). */
function domainRow(page: import('@playwright/test').Page, clusterDomain: string) {
  return page.getByTestId('sd-domains').locator(`li[data-cluster-domain="${clusterDomain}"]`);
}

Then('the domains list shows the registered domain', async ({ page, world }) => {
  const clusterDomain = world.get<string>('clusterDomain');
  await expect(domainRow(page, clusterDomain), `row for ${clusterDomain}`).toBeVisible();
});

When('I activate the {string} control on the registered domain\'s row',
  async ({ page, world }, testid: string) => {
    const clusterDomain = world.get<string>('clusterDomain');
    await domainRow(page, clusterDomain).getByTestId(testid).click();
  });

Then('the domains list renders the registered domain as {string}', async ({ page, world }, state: string) => {
  const clusterDomain = world.get<string>('clusterDomain');
  const row = domainRow(page, clusterDomain);
  // The row must STILL be listed (soft-disable never hides), and its status
  // chip — `.sd-status`, `.is-disabled` when enabled=false, already in the
  // console today — must read the state.
  await expect(row, `row for ${clusterDomain} must remain listed`).toBeVisible();
  await expect(row.locator('.sd-status')).toHaveText(state);
  if (state === 'disabled') await expect(row.locator('.sd-status')).toHaveClass(/is-disabled/);
});

Then('the {string} control offers exactly the choices {string}', async ({ page }, testid: string, csv: string) => {
  const control = page.getByTestId(testid);
  await expect(control).toBeVisible();
  // A <select> (options) or a radio group (inputs) — either is an explicit
  // choice; a free-text field is exactly what admin-ui#10 says is NOT one.
  const options = control.locator('option, input[type=radio]');
  const values = await options.evaluateAll((els) => els.map((e) => (e as HTMLInputElement).value));
  expect(values.sort(), `${testid} choices`).toEqual(list(csv).sort());
});

Then('the {string} control defaults to {string}', async ({ page }, testid: string, value: string) => {
  const control = page.getByTestId(testid);
  const got = await control.evaluate((el) => {
    if (el instanceof HTMLSelectElement) return el.value;
    const checked = el.querySelector('input[type=radio]:checked') as HTMLInputElement | null;
    return checked ? checked.value : (el as HTMLInputElement).value;
  });
  expect(got, `${testid} default`).toBe(value);
});
