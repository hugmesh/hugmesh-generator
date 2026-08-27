// governance-sources.ts — the SOURCE READERS the mined-governance lane asserts over.
//
// WHY THIS MODULE EXISTS. tests/e2e/specs/rbac-route-access.ts is a HAND-COPIED
// TypeScript mirror of the route-access table. Its header says it is "copied 1:1
// from manifests/route-access/schema.sql". Nothing in this suite has ever CHECKED
// that. The real seed the cluster loads lives in this very repo at
// specs/cluster/manifests/route-access/initdb/20-schema.sql (151 INSERT rows,
// four gateways, allow AND deny) and the mirror carries 44 allow-only rows across
// four gateways — so the claim was never true and the drift was invisible.
//
// Everything here READS A FILE AND RETURNS A STRUCTURE. No process is started, no
// port is opened, no stack is required: this is the tier that runs with the whole
// mesh down, which is the only tier that has value on a box where every
// environment is off.
//
// TWO CLASSES OF SOURCE, and the difference is load-bearing:
//
//   IN-REPO      specs/cluster/manifests/route-access/initdb/20-schema.sql
//                tests/e2e/specs/rbac-route-access.ts
//                Always present in a checkout. A scenario over these can never
//                skip, so it never rots into a decorative green.
//
//   SIBLING-REPO hugmesh-gateway / -admin-ui / -mod-ui / -admin-bff-api /
//                -mod-bff-api / -superadmin-service-catalog-ui /
//                -superadmin-service-catalog-ui, checked out NEXT TO this repo.
//                Present on a developer/operator box, absent in a bare CI
//                container. `siblingRepo()` returns null rather than throwing,
//                and every step that needs one SKIPS WITH THE PATH IT LOOKED IN
//                — a silent pass here would be a lie about cross-repo drift.
//
// SIBLING RESOLUTION ORDER, most explicit first:
//   1. $SNAP_REPO_ROOT                       (operator override, always wins)
//   2. the parent of the MAIN worktree       (derived from .git, so this works
//      unchanged from a `git worktree add` under /var/tmp as well as from the
//      primary checkout — which is exactly how this lane was authored)
//   3. the parent of this repo root          (the primary-checkout case)

import * as fs from 'node:fs';
import * as path from 'node:path';

/** <repo>/tests/e2e/specs → <repo>. */
export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

/**
 * Strip `--` line comments and block comments from SQL, and `//` + block
 * comments from Java/TypeScript, WITHOUT eating a delimiter that lives inside a
 * string literal. Every count/assert in this module runs over the stripped text:
 * this repo has been burned by grep-counting a rule that was commented out.
 */
export function stripComments(src: string, lineToken: '--' | '//'): string {
  let out = '';
  let i = 0;
  let quote: string | null = null;
  while (i < src.length) {
    const c = src[i];
    if (quote) {
      out += c;
      if (c === '\\' && quote !== "'") { out += src[i + 1] ?? ''; i += 2; continue; }
      if (c === quote) quote = null;
      i += 1;
      continue;
    }
    if (c === "'" || c === '"' || c === '`') { quote = c; out += c; i += 1; continue; }
    if (src.startsWith(lineToken, i)) {
      while (i < src.length && src[i] !== '\n') i += 1;
      continue;                                  // drop to end of line
    }
    if (src.startsWith('/*', i)) {
      const end = src.indexOf('*/', i + 2);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

// ── sibling repositories ─────────────────────────────────────────────────────

/** The directory sibling checkouts live in, or null when it cannot be derived. */
export function siblingRoot(): string | null {
  if (process.env.SNAP_REPO_ROOT) return process.env.SNAP_REPO_ROOT;
  // Derive the MAIN worktree from .git. In a linked worktree `.git` is a FILE
  // reading `gitdir: /…/hugmesh-generator/.git/worktrees/<name>`; in the primary
  // checkout it is a directory.
  const dotGit = path.join(REPO_ROOT, '.git');
  try {
    const st = fs.statSync(dotGit);
    if (st.isFile()) {
      const m = /gitdir:\s*(.+)/.exec(fs.readFileSync(dotGit, 'utf8'));
      if (m) {
        const idx = m[1].indexOf('/.git/worktrees/');
        if (idx > 0) return path.dirname(m[1].slice(0, idx));
      }
    }
  } catch { /* fall through to the primary-checkout guess */ }
  return path.dirname(REPO_ROOT);
}

/** Absolute path to a sibling checkout, or null when it is not on this box. */
export function siblingRepo(name: string): string | null {
  const root = siblingRoot();
  if (!root) return null;
  const p = path.join(root, name);
  return fs.existsSync(p) ? p : null;
}

/** The skip reason a step MUST print when a sibling repo is missing — it names
 *  the path searched and the override, so nobody has to read this file. */
export function siblingSkipReason(name: string): string {
  return `sibling checkout '${name}' is not present at ${siblingRoot()}/${name}. `
    + `This scenario reads that repository's SOURCE (no stack, no build). Clone it `
    + `beside hugmesh-generator, or point SNAP_REPO_ROOT at the directory that holds it.`;
}

/** Read a file from a sibling checkout, or null when the repo/file is absent. */
export function siblingFile(repo: string, rel: string): string | null {
  const base = siblingRepo(repo);
  if (!base) return null;
  const p = path.join(base, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null;
}

// ── route-access rows ────────────────────────────────────────────────────────

export interface SeedRow {
  gateway: string;
  urlPattern: string;
  role: string;
  /** false = an EXPLICIT DENY row (deny-wins in GatewayRouteAccessService). */
  allow: boolean;
  /** Where the row came from, for a failure message that names a file. */
  origin: string;
}

/** `PUBLIC` in the seeds is spelled `ROLE_ANONYMOUS` in the TS mirror. One name. */
export function canonicalRole(role: string): string {
  return role === 'PUBLIC' ? 'ROLE_ANONYMOUS' : role;
}

export function rowKey(r: { gateway: string; urlPattern: string; role: string }): string {
  return `${r.gateway} ${r.urlPattern} ${canonicalRole(r.role)}`;
}

export const SQL_SEED_PATH =
  'specs/cluster/manifests/route-access/initdb/20-schema.sql';

/**
 * The cluster Postgres seed — the rows a deployed gateway actually loads.
 * Parsed from the `INSERT INTO gateway_route_access (…) VALUES` tuples, over
 * COMMENT-STRIPPED SQL so a commented-out row can never be counted.
 */
export function sqlSeedRows(): SeedRow[] {
  const raw = fs.readFileSync(path.join(REPO_ROOT, SQL_SEED_PATH), 'utf8');
  const sql = stripComments(raw, '--');
  const rows: SeedRow[] = [];
  const tuple = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)/g;
  for (const m of sql.matchAll(tuple)) {
    if (!m[1].endsWith('-gateway')) continue;      // not a route-access tuple
    rows.push({
      gateway: m[1], urlPattern: m[2], role: m[3],
      allow: m[4] === 'true', origin: SQL_SEED_PATH,
    });
  }
  return rows;
}

export const CANONICAL_SEED_REL =
  'src/main/java/net/hugmesh/gateway/cache/CanonicalSeed.java';

/**
 * The in-image fail-closed floor baked into every gateway
 * (hugmesh-gateway CanonicalSeed.java). Returns null when that sibling repo is
 * not checked out — the caller must SKIP with `siblingSkipReason`, never pass.
 */
export function canonicalSeedRows(): SeedRow[] | null {
  const raw = siblingFile('hugmesh-gateway', CANONICAL_SEED_REL);
  if (raw === null) return null;
  const java = stripComments(raw, '//');
  const consts: Record<string, string> = {};
  for (const m of java.matchAll(/static final String (\w+)\s*=\s*"([^"]+)"/g)) {
    consts[m[1]] = m[2];
  }
  const rows: SeedRow[] = [];
  // r(FE, "/admin/**", "ROLE_ADMIN")  → allow;  deny(FE, …) → explicit deny.
  for (const m of java.matchAll(/\b(r|deny)\(\s*(\w+)\s*,\s*"([^"]*)"\s*,\s*"([^"]+)"\s*\)/g)) {
    const gateway = consts[m[2]];
    if (!gateway) continue;                       // not one of the gateway constants
    rows.push({
      gateway, urlPattern: m[3], role: m[4],
      allow: m[1] === 'r', origin: `hugmesh-gateway/${CANONICAL_SEED_REL}`,
    });
  }
  return rows;
}

// ── the REAL gateway decision, over REAL rows ────────────────────────────────
//
// NOT a second copy of rbac-route-access.ts's `gatewayDecision`. That oracle
// has no allow/deny field and collapses "no rule matched" into DENY, so it
// cannot express either of the two behaviours this lane is about:
//
//   * an EXPLICIT DENY row (allow=false) that WINS over an allow row at the
//     same longest pattern — GatewayRouteAccessService:218,
//   * NO_RULE, which the filter FORWARDS on the coarse authenticated() floor
//     rather than rejecting — GatewayRouteAccessService:185 + the filter's
//     "ALLOW / NO_RULE -> forward" contract.
//
// The specificity rule here is the gateway's OWN: raw `urlPattern().length()`,
// longest wins (GatewayRouteAccessService:180-184). The mirror uses a different
// formula (prefix*2 / len*2+1); they agree on the seeded patterns, but this
// module deliberately implements the DEPLOYED one, because the point of the
// lane is to measure the mirror rather than to trust it.

export type SeedDecision = 'ALLOW' | 'DENY' | 'NO_RULE';

/** Ant-style match, the subset the seeds actually use: `**` (any subpath, at a
 *  segment boundary or the prefix itself) and `*` (within one segment). */
export function antMatch(pattern: string, p: string): boolean {
  const esc = (s: string) => s.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  if (pattern.endsWith('/**')) {
    const pre = esc(pattern.slice(0, -3)).replace(/\\?\*/g, '[^/]*');
    return new RegExp(`^${pre}(/.*)?$`).test(p);
  }
  return new RegExp(`^${esc(pattern).replace(/\\?\*/g, '[^/]*')}$`).test(p);
}

export interface SeedVerdict {
  decision: SeedDecision;
  /** True when DENY came from an allow=false row rather than from the
   *  governed-but-ungranted default. The distinction the mirror cannot make. */
  explicitDeny: boolean;
  /** The winning (longest) pattern, or null when nothing matched. */
  pattern: string | null;
}

/** Decide `path` for `roles` over `rows`, using the deployed gateway's rules. */
export function seedDecide(rows: SeedRow[], gateway: string, p: string, roles: string[]): SeedVerdict {
  const here = rows.filter((r) => r.gateway === gateway && antMatch(r.urlPattern, p));
  if (here.length === 0) return { decision: 'NO_RULE', explicitDeny: false, pattern: null };
  let bestLen = -1;
  for (const r of here) bestLen = Math.max(bestLen, r.urlPattern.length);
  const winners = here.filter((r) => r.urlPattern.length === bestLen);
  const pattern = winners[0].urlPattern;
  let allowed = false;
  let explicitDeny = false;
  for (const r of winners) {
    const role = canonicalRole(r.role);
    if (role === 'ROLE_ANONYMOUS') { allowed = true; continue; }
    if (!roles.includes(role)) continue;
    if (r.allow) allowed = true; else explicitDeny = true;
  }
  if (explicitDeny) return { decision: 'DENY', explicitDeny: true, pattern };
  return { decision: allowed ? 'ALLOW' : 'DENY', explicitDeny: false, pattern };
}

// ── admin-ui: the routed set and the menu model ──────────────────────────────

export interface AdminRoute { path: string; guards: string[] }
export interface AdminMenuItem { path: string; label: string; flags: string[] }

/** Every `{ path: … }` in admin.routes.ts with the guards on it, comment-stripped. */
export function adminRoutes(): AdminRoute[] | null {
  const src = siblingFile('hugmesh-admin-ui', 'src/app/admin.routes.ts');
  if (src === null) return null;
  const js = stripComments(src, '//');
  const out: AdminRoute[] = [];
  for (const m of js.matchAll(/\{\s*path:\s*'([^']*)'([^}]*)\}/g)) {
    const guards = [...m[2].matchAll(/canActivate:\s*\[([^\]]+)\]/g)]
      .flatMap((g) => g[1].split(',').map((s) => s.trim()).filter(Boolean));
    out.push({ path: m[1], guards });
  }
  return out;
}

/** The `allMenu` model in admin.component.ts, with its tier flags. */
export function adminMenu(): AdminMenuItem[] | null {
  const src = siblingFile('hugmesh-admin-ui', 'src/app/admin.component.ts');
  if (src === null) return null;
  const js = stripComments(src, '//');
  const out: AdminMenuItem[] = [];
  for (const m of js.matchAll(/\{\s*path:\s*'([^']*)',\s*label:\s*'([^']*)'([^}]*)\}/g)) {
    out.push({
      path: m[1], label: m[2],
      flags: [...m[3].matchAll(/(\w+):\s*true/g)].map((f) => f[1]),
    });
  }
  return out;
}

// ── Angular route guards: WHERE a refusal lands ──────────────────────────────

/** Every `router.parseUrl('<target>')` in a guard file — the refusal target. */
export function guardRedirects(repo: string, rel: string): string[] | null {
  const src = siblingFile(repo, rel);
  if (src === null) return null;
  const js = stripComments(src, '//');
  return [...js.matchAll(/parseUrl\(\s*([A-Z_]+|'[^']*')\s*\)/g)].map((m) => {
    const v = m[1];
    if (!v.startsWith("'")) {
      // A named constant — resolve it from the same file.
      const c = new RegExp(`${v}\\s*=\\s*'([^']*)'`).exec(js);
      return c ? c[1] : v;
    }
    return v.slice(1, -1);
  });
}

// ── Spring BFF security: hierarchy, method gates, guard chains ───────────────

const BFF_CONFIG: Record<string, string> = {
  'hugmesh-admin-bff-api': 'src/main/java/net/hugmesh/adminbff/config/SecurityConfig.java',
  'hugmesh-mod-bff-api': 'src/main/java/net/hugmesh/modbff/config/SecurityConfig.java',
  'hugmesh-forum-bff-api': 'src/main/java/net/hugmesh/forumbff/config/SecurityConfig.java',
  'hugmesh-wiki-bff-api': 'src/main/java/net/hugmesh/wikibff/config/SecurityConfig.java',
  'hugmesh-user-bff-api': 'src/main/java/net/hugmesh/userbff/config/SecurityConfig.java',
};

export interface BffSecurity {
  /** `A > B` edges declared in the RoleHierarchyImpl.fromHierarchy(...) text. */
  hierarchyEdges: string[];
  /** True when a MethodSecurityExpressionHandler bean receives the hierarchy —
   *  WITHOUT which a bare RoleHierarchy bean is NOT applied to @PreAuthorize in
   *  the reactive path (four of the five configs say so in their own javadoc). */
  hierarchyWiredIntoMethodSecurity: boolean;
  /** `pathMatchers("<p>").hasRole("<r>")` pairs. */
  pathRoles: { pattern: string; role: string }[];
  methodSecurityEnabled: boolean;
}

export function bffSecurity(repo: string): BffSecurity | null {
  const rel = BFF_CONFIG[repo];
  if (!rel) throw new Error(`no SecurityConfig path known for '${repo}'. Known: ${Object.keys(BFF_CONFIG).join(', ')}`);
  const src = siblingFile(repo, rel);
  if (src === null) return null;
  const java = stripComments(src, '//');
  const hier = /fromHierarchy\(([\s\S]*?)\);/.exec(java);
  const edges: string[] = [];
  if (hier) {
    for (const m of hier[1].matchAll(/(ROLE_\w+)\s*>\s*(ROLE_\w+)/g)) edges.push(`${m[1]} > ${m[2]}`);
  }
  const handler = /MethodSecurityExpressionHandler\s+\w+\s*\(\s*RoleHierarchy[\s\S]{0,400}?setRoleHierarchy\s*\(/.test(java);
  const pathRoles = [...java.matchAll(/pathMatchers\(\s*"([^"]+)"\s*\)\s*\.hasRole\(\s*"([^"]+)"\s*\)/g)]
    .map((m) => ({ pattern: m[1], role: m[2] }));
  return {
    hierarchyEdges: edges,
    hierarchyWiredIntoMethodSecurity: handler,
    pathRoles,
    methodSecurityEnabled: /@EnableReactiveMethodSecurity|@EnableMethodSecurity/.test(java),
  };
}

export const MOD_CONTROLLER_REL = 'src/main/java/net/hugmesh/modbff/ModController.java';
export const MOD_SERVICE_REL = 'src/main/java/net/hugmesh/modbff/service/ModService.java';
export const MOD_STEPUP_REL = 'src/main/java/net/hugmesh/modbff/security/ModStepUpGate.java';

export interface ModEndpoint {
  /** The HTTP mapping's path, e.g. `/ban`. */
  path: string;
  method: string;
  preAuthorize: string;
  stepUpGated: boolean;
}

/** Every mapped ModController endpoint with its @PreAuthorize predicate. */
export function modEndpoints(): ModEndpoint[] | null {
  const src = siblingFile('hugmesh-mod-bff-api', MOD_CONTROLLER_REL);
  if (src === null) return null;
  const java = stripComments(src, '//');
  const out: ModEndpoint[] = [];
  // The mapping may be `("/ban")` or the array form `({"/a", "/b"})` — the first
  // literal in either is the canonical path. Missing the array form is how a
  // count-the-gated-endpoints assertion quietly under-reports (it did: 3 of 5).
  const re = /@PreAuthorize\(\s*"([^"]+)"\s*\)[\s\S]{0,600}?@(Get|Post|Put|Delete|Patch)Mapping\(\s*\{?\s*(?:value\s*=\s*)?"([^"]*)"/g;
  for (const m of java.matchAll(re)) {
    out.push({
      preAuthorize: m[1], method: m[2].toUpperCase(), path: m[3],
      stepUpGated: m[1].includes('@modStepUpGate.satisfied'),
    });
  }
  return out;
}

/** The guard chain each ModService write runs, in order, keyed by method name. */
export function modServiceGuardChains(): Record<string, string[]> | null {
  const src = siblingFile('hugmesh-mod-bff-api', MOD_SERVICE_REL);
  if (src === null) return null;
  const java = stripComments(src, '//');
  const chains: Record<string, string[]> = {};
  // Every 4-space-indented method, PUBLIC OR PRIVATE, sliced to the next one.
  // Slicing only to the next PUBLIC method is what swept a private helper's
  // guards into the short delegating method above it (it did: owncastRestore
  // reported a seven-call chain it does not run).
  const bodies = [...java.matchAll(/\n {4}(?:public|private)\s+(?:static\s+)?[^;(){}\n]*?(\w+)\s*\([^;{}]*\)\s*\{/g)];
  for (let i = 0; i < bodies.length; i += 1) {
    const start = bodies[i].index as number;
    const end = i + 1 < bodies.length ? (bodies[i + 1].index as number) : java.length;
    const body = java.slice(start, end);
    const guards = [...body.matchAll(/\b(guardNotSelf|guardSameTenant|guardNotPrivileged)\(/g)]
      .map((g) => g[1]);
    const name = bodies[i][1];
    // Overloads: keep the RICHEST chain seen for a name (the delegating overload
    // has none, and reporting the empty one would understate the guarding).
    if (!chains[name] || guards.length > chains[name].length) chains[name] = guards;
  }
  return chains;
}

/** `app.mfa.enforce-sensitive-writes` default, read off the gate's own source. */
export function modStepUpGateSource(): string | null {
  return siblingFile('hugmesh-mod-bff-api', MOD_STEPUP_REL);
}
