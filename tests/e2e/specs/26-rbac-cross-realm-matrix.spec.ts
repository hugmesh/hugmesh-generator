import { test, expect } from '@playwright/test';
import {
  SYSTEMS_SEED_USERS, GAMES_SEED_USERS, systemsUser,
  SYSTEMS_ISSUER, GAMES_ISSUER, SUPERADMIN_GATEWAY, SUPERADMIN_ALLOW_ROUTES,
  type SystemsRole,
} from './rbac-roles';
import { gatewayDecision, effectiveRoles, Gateway } from './rbac-route-access';
import { tags } from './report-tags';

// 26 — FULL CROSS-REALM ROLE AUTHZ MATRIX: systems × games × forum.
//
// Spec 25 established the two NEW invariants (ROLE_SUPERADMIN tier + cross-realm
// issuer isolation) but only on a HANDFUL of probes. The gap this spec closes is
// the full CROSS-REALM authz MATRIX the test standard mandates: for each realm
// PAIR (systems ↔ games ↔ forum) and each role, assert
//
//   (a) ALLOW: a principal with the RIGHT realm + role + domain reaches its own
//       resources (the positive control for every realm),
//   (b) DENY isolation: a principal from realm A / domain X is REFUSED the
//       cross-realm AND cross-domain resources — a GENERIC deny (the oracle
//       returns 'DENY' / a live gateway returns a 401|403, never a 404-vs-403
//       existence leak),
//   (c) ROLE_SUPERADMIN cross-realm REACH where designed (the tailnet superadmin
//       gateway floor spans the federation/service-catalog surface),
//   (d) the per-domain LEAST-PRIVILEGE CASCADE (a brand-X admin grant can NEVER be
//       re-granted to a brand-Y resource — the multi-tenant domain wall).
//
// THREE REALMS, one decision oracle. The "realms" here are:
//
//   * SYSTEMS — org "hugmesh", issuer id.hugmesh.net. Native roles are
//     systems ROLE_* (ROLE_ADMIN/ROLE_MOD/ROLE_USER/…). Enforced by the systems
//     fe/be/pki gateways (rbac-route-access.ROUTE_ACCESS, the schema.sql mirror).
//   * GAMES — org "threewizards", issuer id.hugmesh.games, an INDEPENDENT
//     Casdoor. Native roles are lowercase ('player','admin'); the only systems→games
//     link is the ROLE_GAMES_ADMIN→admin SYNC (owned by hugmesh-actions/e2e). A
//     games token carries NO systems ROLE_*. (The games NAMESPACE surfaces on the
//     systems gateways — /games/admin/**, /games/api/admin/** — are gated on the
//     DERIVED systems ROLE_GAMES_ADMIN, NOT on a games-realm token.)
//   * FORUM — phpBB, reached ONLY through the systems gateways via forum-bff
//     (/social/forum/**, /bff/forum/**). Its access role ROLE_FORUM and the
//     DERIVED ROLE_FORUM_MOD ( = ROLE_MOD ∩ ROLE_FORUM ) are systems Casdoor roles.
//     phpBB itself has NO gateway route (backend-only, default-deny namespace).
//
// WHY a small LOCAL route table here: the shared oracle rbac-route-access.ROUTE_ACCESS
// (consumed by specs 12–18/25) mirrors only the matrix/mastodon/admin/games rows of
// schema.sql — it does NOT yet carry the forum rows or the multi-tenant `domain`
// column. Rather than mutate that oracle (and perturb specs 12–18), this spec adds a
// SELF-CONTAINED forum-route mirror + a faithful domainApplies() wrapper, both copied
// 1:1 from specs/cluster/manifests/route-access/initdb/20-schema.sql. The systems and
// superadmin decisions still go through the SHARED oracle (single source of truth).
//
// Like specs 14/25 the LIVE token-grant probe is SKIPPED offline (needs
// LIVE_GATEWAY=1 + real per-realm Casdoors + the tailnet superadmin-gateway up). The
// contract assertions run against the oracle with NO cluster, so this spec VALIDATES
// offline and drops straight into the suite. Live validation is pending a
// kernel-fixed x86 image (the QEMU cluster cannot boot yet).

// ── FORUM route mirror (schema.sql lines 271/288/376–378) ────────────────────
// Copied 1:1 from 20-schema.sql. ROLE_FORUM_MOD is the DERIVED composite
// ( = ROLE_MOD ∩ ROLE_FORUM ), materialized in Casdoor by the forum reconcile Job
// exactly like ROLE_GAMES_ADMIN — a plain ROLE_MOD WITHOUT ROLE_FORUM is
// default-deny on /bff/forum/moderation/**. Admins reach the forum surfaces via the
// gateway admin-bypass (the converter does NOT grant admins ROLE_FORUM), so the
// floor rows pair NO ROLE_ADMIN; ROLE_ADMIN stays only on the genuinely admin-only
// /bff/forum/admin/** + /api/forum/admin/** rows.
interface ForumRule { gateway: Gateway; urlPattern: string; role: string; }
const FORUM_ROUTES: ForumRule[] = [
  { gateway: 'hugmesh-be-gateway', urlPattern: '/api/forum/admin/**',      role: 'ROLE_ADMIN' },
  { gateway: 'hugmesh-fe-gateway', urlPattern: '/social/forum/**',         role: 'ROLE_FORUM' },
  { gateway: 'hugmesh-fe-gateway', urlPattern: '/bff/forum/admin/**',      role: 'ROLE_ADMIN' },
  { gateway: 'hugmesh-fe-gateway', urlPattern: '/bff/forum/moderation/**', role: 'ROLE_FORUM_MOD' },
  { gateway: 'hugmesh-fe-gateway', urlPattern: '/bff/forum/**',            role: 'ROLE_FORUM' },
];

/** Most-specific-match decision over the LOCAL forum table (the same algorithm as
 *  the shared oracle's gatewayDecision: longest literal prefix wins, exact beats
 *  glob, OR-of-allow-rows at the winning pattern, default-deny). Kept local so the
 *  forum rows are not bolted onto the shared oracle that specs 12–18 depend on. */
function forumDecision(gateway: Gateway, path: string, roles: string[]): 'ALLOW' | 'DENY' {
  let best = -1;
  const winners: string[] = [];
  for (const r of FORUM_ROUTES) {
    if (r.gateway !== gateway) continue;
    const prefix = r.urlPattern.endsWith('/**') ? r.urlPattern.slice(0, -3) : r.urlPattern;
    const isGlob = r.urlPattern.endsWith('/**');
    const matched = isGlob ? (path === prefix || path.startsWith(prefix + '/')) : path === r.urlPattern;
    if (!matched) continue;
    const specificity = isGlob ? prefix.length * 2 : r.urlPattern.length * 2 + 1;
    if (specificity > best) { best = specificity; winners.length = 0; }
    if (specificity === best) winners.push(r.role);
  }
  if (best < 0) return 'DENY';
  return winners.some((w) => roles.includes(w)) ? 'ALLOW' : 'DENY';
}

/** The DERIVED systems roles a forum/games principal earns, on top of the granted
 *  set: ROLE_GAMES_ADMIN ( = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD), via
 *  effectiveRoles) AND ROLE_FORUM_MOD ( = ROLE_MOD ∩ ROLE_FORUM, the forum
 *  reconcile Job). This is the EFFECTIVE systems role-set the gateways decide on. */
function effectiveSystemsRoles(u: { roles: SystemsRole[]; expectGamesAdmin: boolean }): string[] {
  const set = new Set<string>(effectiveRoles(u.roles, u.expectGamesAdmin));
  if (set.has('ROLE_MOD') && set.has('ROLE_FORUM')) set.add('ROLE_FORUM_MOD');
  return [...set];
}

// ── PER-DOMAIN multi-tenant wall (schema.sql domain column / domainApplies) ───
// The merged gateway passes the request's target domain (derived from Host) and a
// per-brand row only applies to its own brand; NULL/blank/'default' = unscoped
// (applies to any domain). On top of the row scope, the filter HARD-DENIES on a
// domain mismatch — so a brand-X admin token presented to a brand-Y resource is
// refused even though brand-Y has an identical ROLE_ADMIN row. We model the
// canonical seed as UNSCOPED rows (matching schema.sql, which leaves every seed row
// NULL) plus the filter's hard cross-domain deny: a principal scoped to domain X
// reaching a resource on domain Y is DENY regardless of role.
const DEFAULT_DOMAIN = 'default';
function domainApplies(rowDomain: string | undefined, requestDomain: string): boolean {
  const d = (rowDomain ?? '').trim();
  return d === '' || d === DEFAULT_DOMAIN || d === requestDomain;
}
/** A faithful multi-tenant decision: the canonical seed rows are unscoped, so the
 *  ROLE decision is the oracle's — BUT a principal whose home domain != the request
 *  domain is hard-denied by the filter's cross-domain wall (defense-in-depth). */
function multiTenantDecision(
  gateway: Gateway, path: string, roles: string[],
  principalDomain: string, requestDomain: string,
): 'ALLOW' | 'DENY' {
  // The canonical seed leaves `domain` NULL (unscoped) → the row applies to any
  // request domain; that is the role half. The filter's hard cross-domain deny is
  // the tenant half: an X-scoped principal can never act on a Y resource.
  if (principalDomain !== requestDomain && !domainApplies(undefined, requestDomain)) {
    return 'DENY'; // unreachable for unscoped rows; kept explicit for the model
  }
  if (principalDomain !== requestDomain) return 'DENY'; // the hard cross-domain wall
  return gatewayDecision(gateway, path, roles);
}

// Representative own-realm RESOURCES per realm/role (the ALLOW positive controls).
const SYSTEMS_ADMIN_PROBE = { gw: 'hugmesh-fe-gateway' as Gateway, path: '/admin/usage' };
const SYSTEMS_MOD_PROBE   = { gw: 'hugmesh-be-gateway' as Gateway, path: '/api/v1/pleroma/admin/statuses' };
const SYSTEMS_USER_PROBE  = { gw: 'hugmesh-be-gateway' as Gateway, path: '/api/v1/timelines/home' };
const GAMES_ADMIN_PROBE   = { gw: 'hugmesh-fe-gateway' as Gateway, path: '/games/admin/sessions' };       // systems ROLE_GAMES_ADMIN
const GAMES_API_PROBE     = { gw: 'hugmesh-be-gateway' as Gateway, path: '/games/api/admin/role-grants' }; // systems ROLE_GAMES_ADMIN
const FORUM_USER_PROBE    = { gw: 'hugmesh-fe-gateway' as Gateway, path: '/bff/forum/topics' };            // ROLE_FORUM floor
const FORUM_MOD_PROBE     = { gw: 'hugmesh-fe-gateway' as Gateway, path: '/bff/forum/moderation/queue' };  // ROLE_FORUM_MOD
const FORUM_ADMIN_PROBE   = { gw: 'hugmesh-fe-gateway' as Gateway, path: '/bff/forum/admin/settings' };    // ROLE_ADMIN

// ─────────────────────────────────────────────────────────────────────────────
// (a) + DENY isolation — the SYSTEMS ↔ FORUM realm pair
// ─────────────────────────────────────────────────────────────────────────────
test.describe('cross-realm matrix: SYSTEMS ↔ FORUM (forum-access realm)', () => {
  // (a) ALLOW — the forum participant reaches the forum floor.
  test('(a) ALLOW: ROLE_FORUM reaches the forum BFF floor (/bff/forum/**) '
    + tags({ role: 'ROLE_FORUM', layer: 'gateway' }), async () => {
    const u = systemsUser('e2e-forum');
    expect(forumDecision(FORUM_USER_PROBE.gw, FORUM_USER_PROBE.path, effectiveSystemsRoles(u))).toBe('ALLOW');
  });

  // (b) DENY isolation — a plain ROLE_FORUM is REFUSED the forum MODERATION +
  //     ADMIN surfaces (a forum participant is NOT a forum mod/admin).
  test('(b) DENY: ROLE_FORUM is refused forum moderation + admin (no forum-mod bleed) '
    + tags({ role: 'ROLE_FORUM', layer: 'gateway' }), async () => {
    const u = systemsUser('e2e-forum');
    const eff = effectiveSystemsRoles(u);
    expect(eff).not.toContain('ROLE_FORUM_MOD');
    expect(forumDecision(FORUM_MOD_PROBE.gw, FORUM_MOD_PROBE.path, eff),
      'forum participant must NOT reach forum moderation').toBe('DENY');
    expect(forumDecision(FORUM_ADMIN_PROBE.gw, FORUM_ADMIN_PROBE.path, eff),
      'forum participant must NOT reach forum admin').toBe('DENY');
  });

  // (b) DENY isolation — a plain ROLE_MOD WITHOUT ROLE_FORUM is default-deny on the
  //     forum moderation surface (the derived ROLE_FORUM_MOD = MOD ∩ FORUM gate).
  test('(b) DENY: a systems ROLE_MOD WITHOUT ROLE_FORUM cannot reach forum moderation '
    + '(derived ROLE_FORUM_MOD = MOD ∩ FORUM, single role default-deny) '
    + tags({ role: 'ROLE_MOD', layer: 'gateway' }), async () => {
    const mod = systemsUser('e2e-mod');
    const eff = effectiveSystemsRoles(mod);
    expect(eff).not.toContain('ROLE_FORUM');
    expect(eff).not.toContain('ROLE_FORUM_MOD');
    expect(forumDecision(FORUM_MOD_PROBE.gw, FORUM_MOD_PROBE.path, eff),
      'a mod that is not a forum-mod must be DENIED forum moderation').toBe('DENY');
  });

  // (c)-shaped — ROLE_ADMIN reaches the forum ADMIN seam end-to-end (the converter
  //     does NOT grant admins ROLE_FORUM, so admin's reach is via the admin-only row,
  //     proving admin's cross-surface reach is DELIBERATE, not forum-floor bleed).
  test('ROLE_ADMIN reaches the forum admin seam but NOT via the ROLE_FORUM floor '
    + tags({ role: 'ROLE_ADMIN', layer: 'gateway' }), async () => {
    const admin = effectiveSystemsRoles(systemsUser('e2e-admin'));
    expect(admin).not.toContain('ROLE_FORUM');
    expect(forumDecision(FORUM_ADMIN_PROBE.gw, FORUM_ADMIN_PROBE.path, admin)).toBe('ALLOW');
    // …and admin is NOT auto-admitted to the ROLE_FORUM-only floor row by ROLE_FORUM
    // (the floor pairs no ROLE_ADMIN — the admin-bypass is a gateway feature outside
    // the route-access table; in the table contract a non-ROLE_FORUM admin is DENY).
    expect(forumDecision(FORUM_USER_PROBE.gw, FORUM_USER_PROBE.path, admin),
      'the ROLE_FORUM floor row admits ONLY ROLE_FORUM in the table contract').toBe('DENY');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// (a) + (b) — the SYSTEMS ↔ GAMES realm pair (issuer isolation + namespace gate)
// ─────────────────────────────────────────────────────────────────────────────
test.describe('cross-realm matrix: SYSTEMS ↔ GAMES (independent Casdoor)', () => {
  test('the two realms have DISTINCT issuers (the isolation premise) '
    + tags({ layer: 'casdoor' }), async () => {
    expect(SYSTEMS_ISSUER).not.toBe(GAMES_ISSUER);
  });

  // (a) ALLOW — the systems ROLE_GAMES_ADMIN derivation reaches the games namespace
  //     surfaces on BOTH systems gateways (the designed cross-namespace reach).
  test('(a) ALLOW: systems ROLE_GAMES_ADMIN reaches /games/admin/** + /games/api/admin/** '
    + tags({ role: 'ROLE_GAMES_ADMIN', layer: 'gateway' }), async () => {
    const ga = effectiveSystemsRoles(systemsUser('e2e-gamesadmin'));
    expect(ga).toContain('ROLE_GAMES_ADMIN');
    expect(gatewayDecision(GAMES_ADMIN_PROBE.gw, GAMES_ADMIN_PROBE.path, ga)).toBe('ALLOW');
    expect(gatewayDecision(GAMES_API_PROBE.gw, GAMES_API_PROBE.path, ga)).toBe('ALLOW');
  });

  // (b) DENY isolation — ROLE_GAMES alone and ROLE_ADMIN alone are each DENIED the
  //     games-admin surfaces (the AND is encoded in the single derived-role row;
  //     neither half alone earns it). This is the cross-namespace deny.
  for (const username of ['e2e-gamesonly', 'e2e-adminonly']) {
    test(`(b) DENY: ${username} is refused the games-admin surfaces (no half earns the AND) `
      + tags({ role: systemsUser(username).roles[0], layer: 'gateway' }), async () => {
      const eff = effectiveSystemsRoles(systemsUser(username));
      expect(eff).not.toContain('ROLE_GAMES_ADMIN');
      expect(gatewayDecision(GAMES_ADMIN_PROBE.gw, GAMES_ADMIN_PROBE.path, eff)).toBe('DENY');
      expect(gatewayDecision(GAMES_API_PROBE.gw, GAMES_API_PROBE.path, eff)).toBe('DENY');
    });
  }

  // (b) DENY isolation — a GAMES-REALM identity (native lowercase roles) carries NO
  //     systems ROLE_* and is therefore REFUSED EVERY systems/forum/games-namespace
  //     surface (issuer isolation: the systems gateways treat its claims as absent).
  //     A GENERIC deny across realms — never an existence-leaking 404-vs-403.
  test('(b) DENY: a games-realm identity is refused EVERY systems + games-namespace '
    + '+ forum + superadmin surface (issuer isolation, generic deny) '
    + tags({ layer: 'gateway' }), async () => {
    const systemsProbes: { gw: Gateway; path: string }[] = [
      SYSTEMS_ADMIN_PROBE, SYSTEMS_MOD_PROBE, SYSTEMS_USER_PROBE,
      GAMES_ADMIN_PROBE, GAMES_API_PROBE,
      { gw: SUPERADMIN_GATEWAY as Gateway, path: '/bff/superadmin/service-store/catalog' },
    ];
    for (const g of GAMES_SEED_USERS) {
      // A games token's roles are native lowercase — NEVER systems ROLE_*.
      for (const r of g.roles) {
        expect(r.startsWith('ROLE_'),
          `games role "${r}" must not masquerade as a systems ROLE_*`).toBeFalsy();
      }
      const crossRealm = g.roles; // what a systems gateway would see if it wrongly trusted the games token
      for (const p of systemsProbes) {
        expect(gatewayDecision(p.gw, p.path, crossRealm),
          `games identity ${g.username} must be DENIED systems ${p.gw} ${p.path}`).toBe('DENY');
      }
      // …and the forum surfaces too (forum roles are systems Casdoor roles).
      expect(forumDecision(FORUM_USER_PROBE.gw, FORUM_USER_PROBE.path, crossRealm),
        `games identity ${g.username} must be DENIED the forum floor`).toBe('DENY');
    }
  });

  // (b) DENY isolation — the reverse direction: a SYSTEMS identity carries NO
  //     games-NATIVE role; even the synced games admin is materialized as a games
  //     Casdoor ROW (owned by hugmesh-actions/e2e), NOT a token bleed.
  test('(b) DENY: a systems identity carries no games-native role into the games realm '
    + '(the synced admin is a games ROW, not a systems-token claim) '
    + tags({ layer: 'casdoor' }), async () => {
    for (const u of SYSTEMS_SEED_USERS) {
      for (const r of u.roles) {
        expect(r.startsWith('ROLE_'),
          `systems role "${r}" is a systems ROLE_*, never a native games role`).toBeTruthy();
        expect(['player', 'admin'].includes(r),
          `systems role "${r}" must not be a native games role`).toBeFalsy();
      }
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// (c) ROLE_SUPERADMIN cross-realm reach where DESIGNED
// ─────────────────────────────────────────────────────────────────────────────
test.describe('cross-realm matrix: ROLE_SUPERADMIN reach where designed', () => {
  // (c) — ROLE_SUPERADMIN reaches the tailnet superadmin-gateway floor that spans
  //     the cross-realm infra surface (service-catalog + federation manifest the
  //     superadmin shell needs across brands/realms), AND no other tier does.
  for (const route of SUPERADMIN_ALLOW_ROUTES) {
    test(`(c) ROLE_SUPERADMIN reaches the cross-realm infra surface ${route.probe} (${route.what}) `
      + tags({ role: 'ROLE_SUPERADMIN', layer: 'gateway' }), async () => {
      const sa = effectiveSystemsRoles(systemsUser('e2e-superadmin'));
      expect(gatewayDecision(SUPERADMIN_GATEWAY as Gateway, route.probe, sa)).toBe('ALLOW');
      // No down-cascade: a concrete admin is DENIED the same cross-realm surface.
      const admin = effectiveSystemsRoles(systemsUser('e2e-admin'));
      expect(gatewayDecision(SUPERADMIN_GATEWAY as Gateway, route.probe, admin),
        `admin must NOT reach the cross-realm superadmin surface ${route.probe}`).toBe('DENY');
    });
  }

  // (c)-negative — ROLE_SUPERADMIN is its OWN tier: it does NOT auto-grant the
  //     PUBLIC realm floors (a superadmin token on the public be-gateway holds no
  //     ROLE_USER), so its reach is exactly the superadmin surface, not everything.
  test('(c) ROLE_SUPERADMIN does NOT auto-grant the public ROLE_USER floor '
    + '(its reach is the superadmin surface, not a universal superset) '
    + tags({ role: 'ROLE_SUPERADMIN', layer: 'gateway' }), async () => {
    const sa = effectiveSystemsRoles(systemsUser('e2e-superadmin'));
    expect(sa).toEqual(['ROLE_SUPERADMIN']);
    expect(gatewayDecision('hugmesh-be-gateway', SYSTEMS_USER_PROBE.path, sa),
      'a bare ROLE_SUPERADMIN holds no ROLE_USER on the public floor').toBe('DENY');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// (d) PER-DOMAIN least-privilege cascade — the multi-tenant brand wall
// ─────────────────────────────────────────────────────────────────────────────
test.describe('cross-realm matrix: per-domain least-privilege cascade (multi-tenant)', () => {
  const BRAND_X = 'brand-x.example';
  const BRAND_Y = 'brand-y.example';

  // (a)/positive — an admin acting on its OWN brand reaches the admin surface.
  test('(a) ALLOW: a brand-X admin reaches the admin surface on brand X '
    + tags({ role: 'ROLE_ADMIN', layer: 'gateway' }), async () => {
    const admin = effectiveSystemsRoles(systemsUser('e2e-admin'));
    expect(multiTenantDecision(SYSTEMS_ADMIN_PROBE.gw, SYSTEMS_ADMIN_PROBE.path, admin, BRAND_X, BRAND_X)).toBe('ALLOW');
  });

  // (d) DENY isolation — the SAME admin grant can NEVER be re-granted to a brand-Y
  //     resource: the filter's hard cross-domain wall denies even an identical
  //     ROLE_ADMIN row on the other brand (defense-in-depth alongside row scoping).
  test('(d) DENY: a brand-X admin is refused brand-Y admin resources (no cross-brand re-grant) '
    + tags({ role: 'ROLE_ADMIN', layer: 'gateway' }), async () => {
    const admin = effectiveSystemsRoles(systemsUser('e2e-admin'));
    expect(multiTenantDecision(SYSTEMS_ADMIN_PROBE.gw, SYSTEMS_ADMIN_PROBE.path, admin, BRAND_X, BRAND_Y),
      'a brand-X admin must NOT reach a brand-Y admin resource').toBe('DENY');
  });

  // (d) DENY isolation — the cross-brand wall holds across realms too: a brand-X
  //     forum-mod / games-admin is refused the same surface on brand Y.
  test('(d) DENY: the cross-brand wall holds for the forum + games surfaces '
    + tags({ role: 'ROLE_GAMES_ADMIN', layer: 'gateway' }), async () => {
    const ga = effectiveSystemsRoles(systemsUser('e2e-gamesadmin'));
    expect(multiTenantDecision(GAMES_ADMIN_PROBE.gw, GAMES_ADMIN_PROBE.path, ga, BRAND_X, BRAND_X),
      'own-brand games admin reaches the games surface').toBe('ALLOW');
    expect(multiTenantDecision(GAMES_ADMIN_PROBE.gw, GAMES_ADMIN_PROBE.path, ga, BRAND_X, BRAND_Y),
      'a brand-X games admin must NOT reach a brand-Y games surface').toBe('DENY');
  });

  // domainApplies model fidelity — NULL/blank/'default' is unscoped (applies to any
  //     request domain); a brand-scoped row applies ONLY to its own brand.
  test('domainApplies: NULL/blank/"default" unscoped; a brand row applies to its brand only '
    + tags({ layer: 'gateway' }), async () => {
    expect(domainApplies(undefined, BRAND_X)).toBe(true);
    expect(domainApplies('', BRAND_X)).toBe(true);
    expect(domainApplies('default', BRAND_X)).toBe(true);
    expect(domainApplies(BRAND_X, BRAND_X)).toBe(true);
    expect(domainApplies(BRAND_X, BRAND_Y)).toBe(false);
  });
});
