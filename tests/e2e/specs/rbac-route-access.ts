// rbac-route-access.ts — the authoritative gateway_route_access matrix, encoded
// from manifests/route-access/schema.sql, plus the gateway decision function the
// RBAC gateway specs assert against.
//
// WHY a TS mirror of schema.sql: the gateways that ENFORCE this table
// (snapdragon-fe-gateway / -be-gateway / -pki-gateway) are README-only today
// (Phase 8/10), so the live deny/allow path cannot be hit yet. This file lets the
// specs assert the CONTRACT the gateways must implement: given a role-set and a
// URL, does the most-specific matching allow row admit the request? When a real
// gateway lands (or the mock stack grows a route-access enforcer), the same specs
// point `evaluateAt` at the live endpoint and the expectations are unchanged.
//
// Decision model (mirrors the schema.sql header + the games SecurityConfig
// casdoorAuthoritiesConverter):
//   * ROLE_ANONYMOUS rows are public — admitted with NO Casdoor JWT.
//   * ROLE_USER is the authenticated floor.
//   * A request is ALLOWED iff the caller holds the role of a matching allow row
//     for THIS gateway at the MOST-SPECIFIC matching url_pattern. The table is an
//     OR-of-allow-rows, so the games-admin AND ( ROLE_GAMES ∩ (ROLE_ADMIN ∪
//     ROLE_MOD) ) is expressed as a SINGLE row keyed on the derived
//     ROLE_GAMES_ADMIN — a single input role is default-deny.
//   * Everything not matched by an allow row is DENY (default-deny).

export type Gateway =
  | 'snapdragon-pki-gateway'
  | 'snapdragon-be-gateway'
  | 'snapdragon-fe-gateway'
  | 'snapdragon-superadmin-gateway';   // tailnet-only infra control plane (ROLE_SUPERADMIN)

export interface RouteRule {
  gateway: Gateway;
  urlPattern: string;   // Spring path pattern, e.g. /api/admin/**
  role: string;         // ROLE_ANONYMOUS | ROLE_USER | ROLE_ADMIN | ROLE_MOD | ROLE_MATRIX |
                         // ROLE_MASTODON | ROLE_GAMES_ADMIN
}

// Canonical seed — one allow row per (gateway, url_pattern, role), copied 1:1 from
// manifests/route-access/schema.sql. Keep in lockstep with that file.
//
// PLATFORM ACCESS roles (ROLE_MATRIX / ROLE_MASTODON) gate the Matrix/Mastodon
// homeserver CLIENT surfaces on the be-gateway (commit 0100d3b, 2026-06-10) — the
// broad ROLE_USER homeserver floor was REMOVED and replaced with these per-platform
// rows (ROLE_MOD/ROLE_ADMIN paired on each as supersets). Holding plain ROLE_USER
// no longer reaches Matrix or Mastodon; a platform ban is the ABSENCE of the role.
export const ROUTE_ACCESS: RouteRule[] = [
  // pki-gateway
  { gateway: 'snapdragon-pki-gateway', urlPattern: '/api/auth/**',    role: 'ROLE_USER' },
  { gateway: 'snapdragon-pki-gateway', urlPattern: '/login/**',       role: 'ROLE_ANONYMOUS' },
  { gateway: 'snapdragon-pki-gateway', urlPattern: '/.well-known/**', role: 'ROLE_ANONYMOUS' },

  // be-gateway — akkoma moderation (ROLE_MOD + ROLE_ADMIN superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/pleroma/admin/**', role: 'ROLE_MOD' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/pleroma/admin/**', role: 'ROLE_ADMIN' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/pleroma/admin/**',    role: 'ROLE_MOD' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/pleroma/admin/**',    role: 'ROLE_ADMIN' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/pleroma/admin/**',        role: 'ROLE_MOD' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/pleroma/admin/**',        role: 'ROLE_ADMIN' },
  // ── PER-PLATFORM ACCESS roles (ban/congruence foundation, commit 0100d3b) ──
  // Matrix client surface: /_matrix/** + the spec-required /.well-known/matrix/**
  // delegation + /_synapse/** (host-scoped Synapse-compat catch-all).
  { gateway: 'snapdragon-be-gateway', urlPattern: '/_matrix/**',               role: 'ROLE_MATRIX' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/_matrix/**',               role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/_matrix/**',               role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/.well-known/matrix/**',    role: 'ROLE_MATRIX' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/.well-known/matrix/**',    role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/.well-known/matrix/**',    role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/_synapse/**',              role: 'ROLE_MATRIX' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/_synapse/**',              role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/_synapse/**',              role: 'ROLE_ADMIN' },   // (admin superset)
  // Mastodon client surface: /api/v1/** + /api/v2/** + /oauth/** + media/streaming.
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/**',                role: 'ROLE_MASTODON' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/**',                role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/**',                role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v2/**',                role: 'ROLE_MASTODON' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v2/**',                role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v2/**',                role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/oauth/**',                 role: 'ROLE_MASTODON' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/oauth/**',                 role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/oauth/**',                 role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/media/**',                 role: 'ROLE_MASTODON' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/media/**',                 role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/media/**',                 role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/streaming/**',      role: 'ROLE_MASTODON' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/streaming/**',      role: 'ROLE_MOD' },     // (mod superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/v1/streaming/**',      role: 'ROLE_ADMIN' },   // (admin superset)
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/admin/**',       role: 'ROLE_ADMIN' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/games/api/admin/**', role: 'ROLE_GAMES_ADMIN' },
  { gateway: 'snapdragon-be-gateway', urlPattern: '/api/**',             role: 'ROLE_USER' },

  // fe-gateway
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/',                   role: 'ROLE_ANONYMOUS' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/social/matrix/**',   role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/social/mastodon/**', role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/login/**',           role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/admin/**',           role: 'ROLE_ADMIN' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/games/admin/**',     role: 'ROLE_GAMES_ADMIN' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/bff/login',          role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/bff/register/**',    role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/bff/provision/**',   role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/bff/me/**',          role: 'ROLE_USER' },
  { gateway: 'snapdragon-fe-gateway', urlPattern: '/bff/admin/**',       role: 'ROLE_ADMIN' },

  // superadmin-gateway — TAILNET-ONLY infra control plane (apps/22-gateway-superadmin.yaml).
  // Every row here is ROLE_SUPERADMIN; there is NO down-cascade row for ROLE_ADMIN,
  // so admin is default-denied. NB /api/federation/** is ROLE_USER on the be-gateway
  // but ROLE_SUPERADMIN on THIS gateway — the gateway NAME scopes the decision.
  { gateway: 'snapdragon-superadmin-gateway', urlPattern: '/bff/superadmin/**',      role: 'ROLE_SUPERADMIN' },
  { gateway: 'snapdragon-superadmin-gateway', urlPattern: '/superadmin/service-catalog/**', role: 'ROLE_SUPERADMIN' },
  { gateway: 'snapdragon-superadmin-gateway', urlPattern: '/api/federation/**',      role: 'ROLE_SUPERADMIN' },
];

/** Translate a Spring path pattern (`/a/**`, `/a/b`) into a matcher + a
 *  specificity score (longer literal prefix = more specific, an exact path beats
 *  a `/**` glob). Mirrors Spring's most-specific-pattern-wins. */
function patternMatch(pattern: string, path: string): { matched: boolean; specificity: number } {
  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);           // strip /**
    // Spring `/**` matches the prefix itself or any `/`-delimited subpath — it
    // must NOT swallow a sibling that merely shares a textual prefix (e.g.
    // `/admin/**` must reject `/administrator`). A bare startsWith(prefix) would
    // over-match, so require a segment boundary.
    const matched = path === prefix || path.startsWith(prefix + '/');
    // specificity = literal prefix length; a glob is less specific than an exact
    // path of the same length, so subtract a hair.
    return { matched, specificity: matched ? prefix.length * 2 : -1 };
  }
  if (pattern === '/') {
    return { matched: path === '/', specificity: path === '/' ? 1 : -1 };
  }
  const matched = path === pattern;
  return { matched, specificity: matched ? pattern.length * 2 + 1 : -1 };
}

export type GatewayDecision = 'ALLOW' | 'DENY';

/**
 * The gateway decision the route-access table dictates for a caller holding
 * `roles` requesting `path` from OUTSIDE `gateway`. This is the oracle the specs
 * assert against — it encodes the schema.sql contract, NOT a live gateway.
 *
 * `roles` should be the EFFECTIVE Casdoor role-set, i.e. include the DERIVED
 * ROLE_GAMES_ADMIN when (and only when) the user qualifies for it (games-admin
 * sync). Pass roles:[] for an unauthenticated caller (only ROLE_ANONYMOUS rows
 * admit).
 */
export function gatewayDecision(gateway: Gateway, path: string, roles: string[]): GatewayDecision {
  const rows = ROUTE_ACCESS.filter((r) => r.gateway === gateway);
  // Find the most-specific matching url_pattern (across ALL roles), then check
  // whether ANY allow row at that winning pattern is satisfied by the caller.
  let best = -1;
  const winningRoles: string[] = [];
  for (const r of rows) {
    const { matched, specificity } = patternMatch(r.urlPattern, path);
    if (!matched) continue;
    if (specificity > best) { best = specificity; winningRoles.length = 0; }
    if (specificity === best) winningRoles.push(r.role);
  }
  if (best < 0) return 'DENY';                          // no matching pattern → default-deny
  if (winningRoles.includes('ROLE_ANONYMOUS')) return 'ALLOW';
  return winningRoles.some((wr) => roles.includes(wr)) ? 'ALLOW' : 'DENY';
}

/** The effective role-set a systems seed user presents to a gateway: the granted
 *  roles PLUS the derived ROLE_GAMES_ADMIN iff they qualify (the games-admin sync
 *  result). This is what `gatewayDecision` consumes. */
export function effectiveRoles(granted: string[], expectGamesAdmin: boolean): string[] {
  const set = new Set(granted);
  if (expectGamesAdmin) set.add('ROLE_GAMES_ADMIN');
  return [...set];
}
