import { test, expect } from '@playwright/test';
import { parseRouteRowsFromSql } from '../steps/governance';

// 34 — sqlRouteRows() must not read a phantom row out of a SQL comment.
//
// hugmesh-generator#379: tests/e2e/steps/governance.ts:sqlRouteRows() used to run
// its tuple regex over the RAW 20-schema.sql text, never stripping `-- …` line
// comments first. A `--` comment that merely NAMES a route-access tuple — for
// example documenting a row that was deliberately left out, or a row a previous
// commit paired with another one — is textually indistinguishable from a real
// INSERT tuple to a regex that only looks for `('a', 'b', 'c', true|false)`. A
// comment that happens to wrap onto one line (or is authored that way to begin
// with) becomes a seeded row nobody wrote into the VALUES list.
//
// scripts/gen-route-access-oracle.py hit the identical shape as
// hugmesh-generator#404 and fixed it with a character-wise, quote-aware
// comment stripper; tests/e2e/specs/governance-sources.ts's sqlSeedRows() (a
// SEPARATE reader of this same file, used by the mined-governance lane) already
// carries an equivalent stripComments() and was never affected. This spec pins
// that governance.ts's sqlRouteRows() now uses that same stripComments() too.
//
// OFFLINE, in-memory fixture only — this never touches the real 20-schema.sql,
// so it cannot be satisfied by that file happening not to trip the bug today.

const REAL_ROW_1 =
  "('hugmesh-fe-gateway', '/admin/usage', 'ROLE_ADMIN', true)";
const REAL_ROW_2 =
  "('hugmesh-be-gateway', '/api/admin/route-access', 'ROLE_ADMIN', true)";
// Route-shaped text sitting inside a `--` line comment: a real gateway name, a
// real pattern, a real role, and a boolean — the exact grammar ROW_RE matches —
// but authored as PROSE documenting a row that was deliberately NOT seeded.
const COMMENT_TUPLE =
  "-- documented but deliberately not seeded here: "
  + "('hugmesh-superadmin-gateway', '/attest/api/decoy', 'ROLE_SUPERADMIN', false)";

const FIXTURE_SQL = `
-- 20-schema.sql fixture (hugmesh-generator#379)
${COMMENT_TUPLE}
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow) VALUES
  ${REAL_ROW_1},
  ${REAL_ROW_2}
ON CONFLICT DO NOTHING;
`;

test('the fixture actually traps the bug: the raw (unstripped) tuple regex would '
  + 'have picked up the commented-out row', () => {
  // Same grammar as governance.ts's ROW_RE, applied with NO comment stripping —
  // this is what sqlRouteRows() did before hugmesh-generator#379. If this stops
  // matching 3 rows, the fixture no longer proves anything and must be revisited.
  const RAW_ROW_RE = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)/g;
  const raw = [...FIXTURE_SQL.matchAll(RAW_ROW_RE)]
    .filter((m) => /^hugmesh-[a-z0-9-]*gateway$/.test(m[1]));
  expect(raw).toHaveLength(3);
  expect(raw.map((m) => m[1])).toContain('hugmesh-superadmin-gateway');
});

test('parseRouteRowsFromSql strips the comment: the decoy row never appears', () => {
  const rows = parseRouteRowsFromSql(FIXTURE_SQL, 'fixture-379');
  expect(rows).toHaveLength(2);
  expect(rows.map((r) => r.gateway)).not.toContain('hugmesh-superadmin-gateway');
  expect(rows).toEqual([
    { gateway: 'hugmesh-fe-gateway', pattern: '/admin/usage', role: 'ROLE_ADMIN', allow: true },
    {
      gateway: 'hugmesh-be-gateway', pattern: '/api/admin/route-access',
      role: 'ROLE_ADMIN', allow: true,
    },
  ]);
});

test('a comment containing ONLY route-like text and no real INSERT still throws the '
  + 'zero-rows guard rather than silently returning an empty table', () => {
  const onlyComment = `-- ${COMMENT_TUPLE.replace(/^-- /, '')}\n`;
  expect(() => parseRouteRowsFromSql(onlyComment, 'fixture-379-empty'))
    .toThrow(/parsed ZERO route rows/);
});
