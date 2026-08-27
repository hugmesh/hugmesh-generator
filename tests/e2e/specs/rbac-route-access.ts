// rbac-route-access.ts — the gateway_route_access decision ORACLE the RBAC specs
// assert against. The TABLE is generated (rbac-route-access.seed.ts); this file
// is only the DECISION FUNCTION, and it mirrors the real gateway.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT WAS WRONG WITH THE PREVIOUS VERSION, AND WHY IT MATTERED
//
// 1. THE TABLE WAS COPIED BY HAND. The header said "copied 1:1 from
//    manifests/route-access/schema.sql. Keep in lockstep with that file" — a path
//    that has not existed since the seed moved to
//    specs/cluster/manifests/route-access/initdb/20-schema.sql. Measured
//    2026-08-26: the mirror held 11 hugmesh-fe-gateway rows against the seed's 77
//    (50 rows against 150 overall). Everything the operator's profile/password
//    report touches — /bff/user/**, /user/**, /bff/session, /_fragments/** — was
//    simply absent, so this oracle answered DENY for all of it while the real
//    gateway ALLOWs it. The specs were green the whole time, because they assert
//    the oracle. The table now comes from the seed, generated, with a CI gate
//    (tests/scripts/test-route-access-oracle.sh).
//
// 2. THE POLARITY WAS INVERTED FOR UNGOVERNED PATHS. The old line read
//    `if (best < 0) return 'DENY'; // no matching pattern -> default-deny`.
//    The gateway does the OPPOSITE:
//      GatewayRouteAccessService.decide()  :185  `if (bestLen < 0) return Decision.NO_RULE;`
//      GatewayRouteAccessFilter            :345  rejects ONLY on `== Decision.DENY`
//      GatewayRouteAccessFilter javadoc  :68-70  "ALLOW / NO_RULE -> forward.
//                                                 NO_RULE means the path isn't governed"
//    "No row" and "denied" are DIFFERENT verdicts: an ungoverned path is forwarded
//    and the coarse SecurityConfig gate is the authority. Encoding them as one
//    verdict made every unmodelled path look walled, which is precisely how a
//    missing row goes unnoticed. `GatewayDecision` now has three values and
//    `gatewayForwards()` reproduces the filter's actual reject predicate.
//
// 3. `allow` WAS INEXPRESSIBLE. `interface RouteRule` had no `allow` field, so the
//    seed's explicit-DENY rows (/bff/user/internal/**, /bff/mesh/internal/**,
//    /bff/internal/**, /attest/api/create-account) could not be represented. The
//    oracle got them right only by ACCIDENT — it had no row at all — and would
//    have silently ALLOWed them the moment someone added one. `allow` is now a
//    required field and deny-wins is implemented at the winning pattern.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE MODEL, mirroring GatewayRouteAccessService.decide() line for line:
//   1. find the LONGEST url_pattern (by string length, exactly as the gateway
//      does — `int len = r.urlPattern().length()`) that Ant-matches the path;
//   2. no match at all              -> NO_RULE (the gateway FORWARDS);
//   3. among the rows at that pattern: a role='PUBLIC' allow row admits without
//      any Casdoor check; any satisfied allow=false row denies (deny-wins);
//   4. governed but nothing granted -> DENY;
//   5. otherwise                    -> ALLOW.
//
// NOT MODELLED, deliberately, and stated out loud rather than implied:
//   * per-row `domain` scoping and the `casdoor_user` pin — the canonical seed
//     sets neither (the generator ASSERTS the INSERT's column list is exactly
//     (gateway, url_pattern, role, allow), so a row that starts scoping cannot
//     arrive unnoticed);
//   * the D8 `mfa_required` floor — that lives in the seed's separate UPDATE and
//     is covered by tests/e2e/specs/29-mfa-privileged-floor.spec.ts against the
//     LIVE posture, which is a stronger check than a mirror of it here;
//   * the gateway's ROLE-typed authority match (a bare Casdoor PERMISSION must not
//     satisfy a ROLE_ rule). Callers here pass Spring authority strings directly,
//     and every caller in this suite passes ROLE_-prefixed values.
//   * the admin bypass in GatewayRouteAccessFilter (ROLE_ADMIN on the internal
//     Casdoor JWT forwards before decide() is consulted) — this is the TABLE's
//     verdict, not the filter's end-to-end one.

import { ROUTE_ACCESS_SEED } from './rbac-route-access.seed';

export type Gateway =
  | 'hugmesh-pki-gateway'
  | 'hugmesh-be-gateway'
  | 'hugmesh-fe-gateway'
  | 'hugmesh-superadmin-gateway';   // tailnet-only infra control plane (ROLE_SUPERADMIN)

export interface RouteRule {
  gateway: Gateway | string;
  urlPattern: string;   // Spring path pattern, e.g. /api/admin/**
  role: string;         // ROLE_* | PUBLIC (Casdoor check skipped)
  allow: boolean;       // false = EXPLICIT DENY row; deny-wins at the winning pattern
}

/** The canonical seed, GENERATED from
 *  specs/cluster/manifests/route-access/initdb/20-schema.sql. Never edit by hand;
 *  run `python3 scripts/gen-route-access-oracle.py`. */
export const ROUTE_ACCESS: readonly RouteRule[] = ROUTE_ACCESS_SEED;

/** Spring's PUBLIC sentinel: an allow row whose role is PUBLIC admits with no
 *  Casdoor JWT at all (GatewayRouteAccessService.isPublic). The seed also uses
 *  ROLE_ANONYMOUS for the same intent on the browser-facing rows. */
const PUBLIC_ROLES = new Set(['PUBLIC', 'ROLE_ANONYMOUS']);

/**
 * Ant-match a seed url_pattern against a path.
 *
 * The seed uses exactly four pattern shapes and the generator REFUSES to emit a
 * fifth (scripts/gen-route-access-oracle.py:pattern_shape), so this stays a
 * faithful stand-in for Spring's AntPathMatcher without reimplementing it:
 *   `/**`            — matches every path
 *   `<prefix>/**`    — the prefix itself, `<prefix>/`, or any `/`-delimited subpath.
 *                      Must NOT swallow a textual sibling: `/admin/**` rejects
 *                      `/administrator`.
 *   `/<seg>` literal — exact match
 *   `/*.css`-style   — single-segment glob; `*` never spans a `/`
 */
export function antMatch(pattern: string, path: string): boolean {
  if (pattern === '/**') return true;
  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);
    return path === prefix || path.startsWith(prefix + '/');
  }
  if (pattern.includes('*')) {
    // Single-segment glob: `*` matches anything but `/`.
    const rx = new RegExp('^' + pattern.split('*')
      .map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
      .join('[^/]*') + '$');
    return rx.test(path);
  }
  return path === pattern;
}

/** The three verdicts GatewayRouteAccessService.Decision carries. NO_RULE is NOT
 *  a denial: the filter forwards on it (GatewayRouteAccessFilter:345). */
export type GatewayDecision = 'ALLOW' | 'DENY' | 'NO_RULE';

/**
 * The route-access TABLE's verdict for a caller holding `roles` requesting `path`
 * from outside `gateway` — a mirror of GatewayRouteAccessService.decide().
 *
 * `roles` should be the EFFECTIVE Casdoor role-set, i.e. include the DERIVED
 * ROLE_GAMES_ADMIN when (and only when) the user qualifies for it (games-admin
 * sync). Pass roles:[] for an unauthenticated caller (only PUBLIC/ROLE_ANONYMOUS
 * rows admit).
 *
 * Returns NO_RULE — never DENY — when no pattern matches. Use `gatewayForwards`
 * if what you mean is "does the request get through this filter".
 */
export function gatewayDecision(gateway: Gateway, path: string, roles: string[]): GatewayDecision {
  return decideAgainst(ROUTE_ACCESS, gateway, path, roles);
}

/**
 * The same decision against an ARBITRARY rule table.
 *
 * Exists so the deny-wins branch can be tested. It cannot be reached through the
 * committed seed: the seed's four allow=false rows are the ONLY rows at their
 * url_pattern, so removing deny-wins entirely still yields DENY through the
 * governed-but-ungranted path. A mutation battery run on 2026-08-26 proved that —
 * deleting `else explicitDeny = true` left all 99 RBAC assertions green. A branch
 * no test can distinguish is a branch that will be wrong the first day the seed
 * pairs an allow row with a deny row at one pattern, which is exactly the shape
 * docs/ROUTE-ACCESS.md describes for a future per-user ban row.
 */
export function decideAgainst(
  table: readonly RouteRule[], gateway: Gateway | string,
  path: string, roles: string[],
): GatewayDecision {
  if (path == null) return 'NO_RULE';
  const rows = table.filter((r) => r.gateway === gateway);

  // 1) longest matching url_pattern wins — by LENGTH, as the gateway measures it.
  let bestLen = -1;
  for (const r of rows) {
    if (!antMatch(r.urlPattern, path)) continue;
    if (r.urlPattern.length > bestLen) bestLen = r.urlPattern.length;
  }
  if (bestLen < 0) return 'NO_RULE';                    // ungoverned path — the gateway FORWARDS

  // 2) deny-wins among the rows AT that pattern.
  let allowed = false;
  let explicitDeny = false;
  for (const r of rows) {
    if (r.urlPattern.length !== bestLen || !antMatch(r.urlPattern, path)) continue;
    if (r.allow && PUBLIC_ROLES.has(r.role)) { allowed = true; continue; }
    if (!roles.includes(r.role)) continue;              // rule's role not held
    if (r.allow) allowed = true; else explicitDeny = true;
  }
  if (explicitDeny) return 'DENY';
  if (!allowed) return 'DENY';                          // governed-but-ungranted
  return 'ALLOW';
}

/** What GatewayRouteAccessFilter actually does with the verdict: reject ONLY on
 *  DENY; ALLOW and NO_RULE both forward (filter javadoc :68-70, code :345). */
export function gatewayForwards(gateway: Gateway, path: string, roles: string[]): boolean {
  return gatewayDecision(gateway, path, roles) !== 'DENY';
}

/** The effective role-set a systems seed user presents to a gateway: the granted
 *  roles PLUS the derived ROLE_GAMES_ADMIN iff they qualify (the games-admin sync
 *  result). This is what `gatewayDecision` consumes. */
export function effectiveRoles(granted: string[], expectGamesAdmin: boolean): string[] {
  const set = new Set(granted);
  if (expectGamesAdmin) set.add('ROLE_GAMES_ADMIN');
  return [...set];
}
