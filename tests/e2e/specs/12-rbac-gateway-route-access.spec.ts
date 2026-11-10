import { test, expect } from '@playwright/test';
import { SYSTEMS_SEED_USERS, systemsUser } from './rbac-roles';
import { gatewayDecision, decideAgainst, effectiveRoles, gatewayForwards, ROUTE_ACCESS, RouteRule, Gateway, GatewayDecision } from './rbac-route-access';

// 12 — Gateway route-access ALLOW/DENY/NO_RULE matrix.
//
// Asserts the gateway_route_access CONTRACT
// (specs/cluster/manifests/route-access/initdb/20-schema.sql)
// for the full systems role matrix: each seed user's EFFECTIVE role-set (granted
// roles + the derived ROLE_GAMES_ADMIN when they qualify) is run against the
// authoritative table via `gatewayDecision`, and the expected ALLOW/DENY is
// asserted at every contractually-interesting URL.
//
// WHY this is contract-level (not a live deny): this asserts the TABLE's verdict,
// offline. Spec 14 (`LIVE_GATEWAY=1`) drives the SAME expectations against a
// running front door.
//
// THREE VERDICTS, NOT TWO. `gatewayDecision` mirrors
// GatewayRouteAccessService.decide(): an unmatched path is NO_RULE and the gateway
// FORWARDS it (GatewayRouteAccessFilter:345 rejects only on DENY). The oracle used
// to collapse NO_RULE into DENY, which made every path the hand-copied table had
// drifted away from look walled — the whole /bff/user/** profile+password surface
// included. Cases that mean "the table does not govern this" now say NO_RULE, and
// the honest wall for those paths is named in the case comment.
//
// The authoritative cases below are derived BY HAND from the seed + the RBAC
// model, then cross-checked against the oracle (which is now GENERATED from that
// same seed by scripts/gen-route-access-oracle.py) — so a bug in the oracle OR a
// drift in the seed surfaces here.

type Case = { gw: Gateway; path: string; user: string; expect: GatewayDecision; why: string };

const eff = (username: string) => {
  const u = systemsUser(username);
  return effectiveRoles(u.roles, u.expectGamesAdmin);
};

const CASES: Case[] = [
  // ── fe-gateway /admin/** = ROLE_ADMIN ───────────────────────────────────
  { gw: 'hugmesh-fe-gateway', path: '/admin/usage', user: 'e2e-admin', expect: 'ALLOW', why: 'admin reaches the admin UI' },
  { gw: 'hugmesh-fe-gateway', path: '/admin/usage', user: 'e2e-adminonly', expect: 'ALLOW', why: 'ROLE_ADMIN alone reaches /admin' },
  { gw: 'hugmesh-fe-gateway', path: '/admin/usage', user: 'e2e-mod', expect: 'DENY', why: 'ROLE_MOD is NOT a superset of admin' },
  { gw: 'hugmesh-fe-gateway', path: '/admin/usage', user: 'e2e-gamesonly', expect: 'DENY', why: 'plain games member denied admin UI' },
  { gw: 'hugmesh-fe-gateway', path: '/admin/usage', user: 'e2e-user', expect: 'DENY', why: 'plain user denied admin UI' },

  // ── be-gateway /api/admin/** = ROLE_ADMIN (NOT ROLE_MOD) ────────────────
  { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access', user: 'e2e-admin', expect: 'ALLOW', why: 'admin reaches the admin API' },
  { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access', user: 'e2e-mod', expect: 'DENY', why: 'mod DENIED the hugmesh admin API' },
  { gw: 'hugmesh-be-gateway', path: '/api/admin/route-access', user: 'e2e-user', expect: 'DENY', why: 'user DENIED the admin API' },

  // ── fe-gateway /bff/admin/** = ROLE_ADMIN ───────────────────────────────
  { gw: 'hugmesh-fe-gateway', path: '/bff/admin/allowlist', user: 'e2e-admin', expect: 'ALLOW', why: 'admin reaches the BFF admin allowlist' },
  { gw: 'hugmesh-fe-gateway', path: '/bff/admin/allowlist', user: 'e2e-mod', expect: 'DENY', why: 'mod DENIED /bff/admin (stays ROLE_ADMIN)' },

  // ── be-gateway akkoma moderation = ROLE_MOD (or ROLE_ADMIN superset) ─────
  { gw: 'hugmesh-be-gateway', path: '/api/v1/pleroma/admin/config', user: 'e2e-mod', expect: 'ALLOW', why: 'mod reaches akkoma moderation REST' },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/pleroma/admin/config', user: 'e2e-admin', expect: 'ALLOW', why: 'admin (superset) reaches akkoma moderation' },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/pleroma/admin/config', user: 'e2e-user', expect: 'DENY', why: 'plain user DENIED akkoma moderation' },

  // ── be-gateway Matrix/Mastodon PLATFORM-ACCESS floor (commit 0100d3b) ────
  // The broad ROLE_USER homeserver floor was REMOVED and replaced by the
  // per-platform ROLE_MATRIX/ROLE_MASTODON access roles (ROLE_MOD/ROLE_ADMIN
  // paired as supersets). Plain ROLE_USER (e2e-user) no longer reaches the
  // homeserver client surfaces — only a principal holding the matching platform
  // role (or MOD/ADMIN) does. e2e-matrix/e2e-mastodon are the dedicated
  // platform-access personas (rbac-roles.ts) that model "a plain member who has
  // been granted their own homeserver" — the real successor to the old bare-
  // ROLE_USER expectation.
  { gw: 'hugmesh-be-gateway', path: '/_matrix/client/v3/sync', user: 'e2e-mod', expect: 'ALLOW', why: 'mod is a paired superset on the ROLE_MATRIX-gated row (not auto-granted ROLE_USER)' },
  { gw: 'hugmesh-be-gateway', path: '/_matrix/client/v3/sync', user: 'e2e-matrix', expect: 'ALLOW', why: 'ROLE_MATRIX holder reaches Matrix C-S API' },
  { gw: 'hugmesh-be-gateway', path: '/_matrix/client/v3/sync', user: 'e2e-user', expect: 'DENY', why: 'plain ROLE_USER (no ROLE_MATRIX) no longer reaches the Matrix homeserver floor' },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/timelines/home', user: 'e2e-mod', expect: 'ALLOW', why: 'mod is a paired superset on the ROLE_MASTODON-gated row' },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/timelines/home', user: 'e2e-mastodon', expect: 'ALLOW', why: 'ROLE_MASTODON holder reaches Mastodon REST API' },
  { gw: 'hugmesh-be-gateway', path: '/api/v1/timelines/home', user: 'e2e-user', expect: 'DENY', why: 'plain ROLE_USER (no ROLE_MASTODON) no longer reaches the Mastodon homeserver floor' },

  // ── GAMES-ADMIN GATE — the heart of the requirement ─────────────────────
  // /games/admin/** (fe) + /games/api/admin/** (be) = ROLE_GAMES_ADMIN ONLY.
  { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions', user: 'e2e-gamesadmin', expect: 'ALLOW', why: 'ROLE_GAMES ∩ ROLE_ADMIN earned ROLE_GAMES_ADMIN -> reaches games admin UI' },
  { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions', user: 'e2e-gamesonly', expect: 'DENY', why: 'ROLE_GAMES alone is NOT games-admin (default-deny)' },
  { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions', user: 'e2e-adminonly', expect: 'DENY', why: 'ROLE_ADMIN alone is NOT games-admin (default-deny)' },
  { gw: 'hugmesh-fe-gateway', path: '/games/admin/sessions', user: 'e2e-mod', expect: 'DENY', why: 'ROLE_MOD alone is NOT games-admin' },
  { gw: 'hugmesh-fe-gateway', path: '/games/api/admin/role-grants', user: 'e2e-gamesadmin', expect: 'ALLOW', why: 'derived ROLE_GAMES_ADMIN reaches games admin API' },
  { gw: 'hugmesh-fe-gateway', path: '/games/api/admin/role-grants', user: 'e2e-gamesonly', expect: 'DENY', why: 'ROLE_GAMES alone denied games admin API' },
  { gw: 'hugmesh-fe-gateway', path: '/games/api/admin/role-grants', user: 'e2e-adminonly', expect: 'DENY', why: 'ROLE_ADMIN alone denied games admin API' },

  // ── UNGOVERNED: an unmapped path is NO_RULE — the table does not wall it ──
  // The gateway forwards NO_RULE and the coarse SecurityConfig gate decides. What
  // actually keeps /infra/** unreachable is that NO gateway routes it at all
  // (no /infra route in specs/cluster/apps/20-gateway-be.yaml nor in
  // tests/stack/gateway-routes/be/application-routes.yml), so SCG answers its own
  // no-route-matched 404. Calling this "default-deny" was the error that let the
  // hand-copied table drift for months without a single red test.
  { gw: 'hugmesh-be-gateway', path: '/infra/logs', user: 'e2e-admin', expect: 'NO_RULE', why: 'no matching row -> NO_RULE; the wall is the ABSENT ROUTE, not the table' },
  { gw: 'hugmesh-be-gateway', path: '/infra/logs', user: 'e2e-mod', expect: 'NO_RULE', why: 'same for mod — the table has nothing to say about /infra/**' },

  // ── SELF-SERVICE PROFILE + PASSWORD (the operator-reported surface) ───────
  // These are the rows the old 11-row mirror was missing entirely, so the oracle
  // answered DENY for every one of them while the real gateway ALLOWs. Both the
  // API (/bff/user/**) and the browser mount (/user/**) are ROLE_USER floors.
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/profile', user: 'e2e-user', expect: 'ALLOW', why: 'ROLE_USER reaches its own profile API' },
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/profile/password', user: 'e2e-user', expect: 'ALLOW', why: 'password CHANGE is on the ROLE_USER floor' },
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/profile/email', user: 'e2e-user', expect: 'ALLOW', why: 'email change is on the ROLE_USER floor' },
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/profile/avatar', user: 'e2e-user', expect: 'ALLOW', why: 'avatar upload is on the ROLE_USER floor' },
  { gw: 'hugmesh-fe-gateway', path: '/user/profile', user: 'e2e-user', expect: 'ALLOW', why: 'the user-ui browser mount is on the ROLE_USER floor' },
  { gw: 'hugmesh-fe-gateway', path: '/user/preferences', user: 'e2e-user', expect: 'ALLOW', why: 'preferences ride the same /user/** row' },
  // REFUSAL, same surface: a moderator is not a user. The converter does NOT
  // auto-grant ROLE_USER to ROLE_MOD/ROLE_ADMIN (schema.sql says so on the
  // /bff/mod/** rows), so e2e-modonly is genuinely without the floor role here.
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/profile/password', user: 'e2e-mod', expect: 'DENY', why: 'ROLE_MOD alone does not hold the ROLE_USER floor' },
  // REFUSAL: the SERVICE-only ingest surface under the same prefix is an EXPLICIT
  // DENY row (20-schema.sql: '/bff/user/internal/**' ROLE_USER allow=false). The
  // old oracle could not even REPRESENT allow=false — it got this right only by
  // having no row at all, and would have flipped to ALLOW the moment one landed.
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/internal/mesh-devices', user: 'e2e-user', expect: 'DENY', why: 'explicit allow=false row beats the /bff/user/** floor (deny-wins at the longer pattern)' },
  { gw: 'hugmesh-fe-gateway', path: '/bff/user/internal/mesh-devices', user: 'e2e-admin', expect: 'DENY', why: 'the internal ingest DENY is not role-escapable via admin' },
];

test.describe('RBAC: gateway route-access ALLOW/DENY (schema.sql contract)', () => {
  for (const c of CASES) {
    test(`${c.gw} ${c.path} — ${c.user} => ${c.expect} (${c.why})`, async () => {
      const decision = gatewayDecision(c.gw, c.path, eff(c.user));
      expect(decision, `${c.user} effective roles=${JSON.stringify(eff(c.user))}: ${c.why}`).toBe(c.expect);
    });
  }

  test('ROLE_GAMES_ADMIN is the ONLY key on both games-admin rows (single role default-deny)', async () => {
    // Cross-check the gate property directly: no single granted role admits the
    // games-admin surface; only the derived intersection role does.
    for (const single of ['ROLE_GAMES', 'ROLE_ADMIN', 'ROLE_MOD', 'ROLE_USER']) {
      expect(gatewayDecision('hugmesh-fe-gateway', '/games/admin/x', [single]),
        `${single} alone must NOT reach /games/admin`).toBe('DENY');
      expect(gatewayDecision('hugmesh-fe-gateway', '/games/api/admin/x', [single]),
        `${single} alone must NOT reach /games/api/admin`).toBe('DENY');
    }
    expect(gatewayDecision('hugmesh-fe-gateway', '/games/admin/x', ['ROLE_GAMES_ADMIN'])).toBe('ALLOW');
    expect(gatewayDecision('hugmesh-fe-gateway', '/games/api/admin/x', ['ROLE_GAMES_ADMIN'])).toBe('ALLOW');
  });

  // ── THE ORACLE ITSELF, under test ─────────────────────────────────────────
  //
  // Everything above is only as good as the table it consults. The table used to
  // be hand-copied and had drifted to 11 of the seed's 77 hugmesh-fe-gateway rows
  // without a single red test. These four assertions make that class of rot
  // impossible to reach this suite silently. The row COUNTS are cross-checked
  // against the SQL seed by tests/scripts/test-route-access-oracle.sh (which
  // regenerates and diffs); the floors here are the cheap in-suite backstop.

  test('the oracle is not vacuous: the generated table carries the whole seed', async () => {
    const fe = ROUTE_ACCESS.filter((r) => r.gateway === 'hugmesh-fe-gateway');
    // Floors, not equalities: the seed grows. A COLLAPSE is the failure mode.
    expect(ROUTE_ACCESS.length, 'total seed rows').toBeGreaterThanOrEqual(140);
    expect(fe.length, 'hugmesh-fe-gateway rows (was 11 when the mirror was hand-copied)')
      .toBeGreaterThanOrEqual(70);
    // allow=false must be REPRESENTABLE and actually present — the previous
    // RouteRule interface had no `allow` field at all.
    expect(ROUTE_ACCESS.some((r) => r.allow === false),
      'the seed carries explicit-DENY rows; a table that cannot express them is wrong')
      .toBe(true);
  });

  test('NO_RULE is not DENY: the filter forwards an ungoverned path', async () => {
    // GatewayRouteAccessFilter:345 rejects ONLY on Decision.DENY.
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/session', ['ROLE_USER'])).toBe('NO_RULE');
    expect(gatewayForwards('hugmesh-fe-gateway', '/bff/session', ['ROLE_USER'])).toBe(true);
    // ...while a genuine deny does NOT forward.
    expect(gatewayForwards('hugmesh-fe-gateway', '/bff/user/internal/x', ['ROLE_USER'])).toBe(false);
    expect(gatewayForwards('hugmesh-fe-gateway', '/bff/admin/allowlist', ['ROLE_USER'])).toBe(false);
  });

  test('REFUSAL: an unauthenticated caller reaches no profile or password surface', async () => {
    for (const path of ['/bff/user/profile', '/bff/user/profile/password',
                        '/bff/user/profile/email', '/bff/user/profile/avatar',
                        '/user', '/user/profile', '/user/preferences']) {
      expect(gatewayDecision('hugmesh-fe-gateway', path, []),
        `anonymous must not reach ${path}`).toBe('DENY');
    }
    // ...and the anonymous rows that DO exist still admit, so the [] role-set is
    // not just denying everything (which would make the loop above vacuous).
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/login', [])).toBe('ALLOW');
    expect(gatewayDecision('hugmesh-fe-gateway', '/login/callback', [])).toBe('ALLOW');
  });

  test('deny-wins: the longest pattern decides, and an allow=false row there beats every allow row', async () => {
    // /bff/user/internal/** (21 chars) beats /bff/user/** (12) — the real gateway
    // compares url_pattern LENGTH (GatewayRouteAccessService:187-192).
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/user/profile', ['ROLE_USER'])).toBe('ALLOW');
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/user/internal/mesh-devices', ['ROLE_USER'])).toBe('DENY');
    // A textual sibling must NOT be swallowed by the glob: /bff/user/** does not
    // match /bff/userland (no segment boundary), so the deny does not leak sideways.
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/userland', ['ROLE_USER'])).not.toBe('DENY');
  });

  // DENY-WINS, tested where the seed cannot test it.
  //
  // The committed seed's four allow=false rows are each the ONLY row at their
  // url_pattern, so `governed-but-ungranted -> DENY` produces the right answer
  // even with the deny-wins branch deleted. That was MEASURED, not assumed: a
  // mutation run on 2026-08-26 removed `else explicitDeny = true` and all 99 RBAC
  // assertions stayed green. A branch nothing can distinguish is a branch that
  // will be silently wrong the first time the seed pairs an allow row with a deny
  // row at one pattern (a per-user ban row is exactly that shape). So this case
  // drives a SYNTHETIC table through the same decision function.
  test('deny-wins: a satisfied allow=false row beats a satisfied allow row at the SAME pattern', async () => {
    const table: RouteRule[] = [
      { gateway: 'hugmesh-fe-gateway', urlPattern: '/bff/user/**', role: 'ROLE_USER', allow: true },
      { gateway: 'hugmesh-fe-gateway', urlPattern: '/bff/user/**', role: 'ROLE_BANNED', allow: false },
    ];
    // Plain user: the allow row grants.
    expect(decideAgainst(table, 'hugmesh-fe-gateway', '/bff/user/profile', ['ROLE_USER'])).toBe('ALLOW');
    // Same user, now also carrying the deny-keyed role: DENY, not ALLOW.
    expect(decideAgainst(table, 'hugmesh-fe-gateway', '/bff/user/profile', ['ROLE_USER', 'ROLE_BANNED']))
      .toBe('DENY');
    // Order of the rows must not matter.
    expect(decideAgainst([table[1], table[0]], 'hugmesh-fe-gateway', '/bff/user/profile',
      ['ROLE_USER', 'ROLE_BANNED'])).toBe('DENY');
    // A deny row whose role the caller does NOT hold must not deny anyone else.
    expect(decideAgainst(table, 'hugmesh-fe-gateway', '/bff/user/profile', ['ROLE_USER'])).toBe('ALLOW');
    // A PUBLIC allow row does not override a satisfied deny row either.
    const withPublic: RouteRule[] = [
      ...table,
      { gateway: 'hugmesh-fe-gateway', urlPattern: '/bff/user/**', role: 'PUBLIC', allow: true },
    ];
    expect(decideAgainst(withPublic, 'hugmesh-fe-gateway', '/bff/user/profile', ['ROLE_BANNED'])).toBe('DENY');
  });

  // ── AN HONEST GAP, ASSERTED AS IT IS (not as we wish it were) ─────────────
  //
  // There is NO `/bff/**` row on hugmesh-fe-gateway. The seed governs each BFF
  // prefix by name (/bff/user/**, /bff/mod/**, /bff/admin/**, /bff/forum/** …),
  // and apps/20-gateway-fe.yaml carries a `/bff/**` ROUTE to admin-bff as the
  // catch-all. So a /bff path that matches no named prefix is NO_RULE: the
  // route-access filter forwards it and admin-bff's own SecurityConfig is the only
  // authority left. That is the state of the tree on 2026-08-26, and the previous
  // oracle could not have told anyone — it answered DENY for every unmodelled
  // path, so this hole looked closed.
  //
  // This test is NOT an endorsement. It pins the CURRENT truth so that adding a
  // `/bff/**` floor row (a production RBAC decision that belongs to the seed's
  // owner, not to a test) turns it red and forces the change to be noticed.
  test('GAP: an unnamed /bff subpath is UNGOVERNED on the fe-gateway (no /bff/** floor row)', async () => {
    expect(ROUTE_ACCESS.some((r) => r.gateway === 'hugmesh-fe-gateway' && r.urlPattern === '/bff/**'),
      'if a /bff/** floor row has been added, update this test and the comment above').toBe(false);
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/userland', ['ROLE_USER'])).toBe('NO_RULE');
    expect(gatewayDecision('hugmesh-fe-gateway', '/bff/userland', [])).toBe('NO_RULE');
  });

  test('every seed user has a consistent effective role-set vs its expectGamesAdmin flag', async () => {
    for (const u of SYSTEMS_SEED_USERS) {
      const e = effectiveRoles(u.roles, u.expectGamesAdmin);
      const earns = u.roles.includes('ROLE_GAMES') &&
        (u.roles.includes('ROLE_ADMIN') || u.roles.includes('ROLE_MOD'));
      // The seed catalogue's expectGamesAdmin MUST equal what the intersection
      // rule ( ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD) ) computes from its grants.
      expect(earns, `${u.username}: expectGamesAdmin must match the intersection of its granted roles`)
        .toBe(u.expectGamesAdmin);
      expect(e.includes('ROLE_GAMES_ADMIN')).toBe(u.expectGamesAdmin);
    }
  });
});
