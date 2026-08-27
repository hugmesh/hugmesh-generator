// cross-realm.steps.ts — the CROSS-REALM authz step vocabulary. Backs
// features/federation/cross-realm-authz.feature and the oracle half of
// features/matrix/platform-access-wall.feature: the executable form of
// tests/e2e/specs/26-rbac-cross-realm-matrix.spec.ts.
//
// "Realm" here is an identity realm, not the Matrix homeserver:
//   SYSTEMS — org "hugmesh", issuer id.hugmesh.net, native roles ROLE_*.
//   GAMES   — org "threewizards", issuer id.hugmesh.games, an INDEPENDENT
//             Casdoor whose native roles are lowercase ('player','admin'); a
//             games token carries NO systems ROLE_*.
//
// EVERY DECISION HERE GOES THROUGH THE SHARED ORACLE (specs/rbac-route-access.ts
// ROUTE_ACCESS + gatewayDecision + effectiveRoles), which mirrors
// manifests/route-access/20-schema.sql and is the same oracle specs 12-18/25/26
// consume. Nothing is re-tabulated in this file: a second copy of the route table
// is exactly the drift the Gherkin lane exists to avoid.
//
// NOT COVERED HERE, ON PURPOSE: spec 26's FORUM route mirror and its
// multiTenantDecision/domainApplies model are module-private to that spec file.
// Expressing them in Gherkin would mean a THIRD copy of the schema.sql rows, so
// the forum-pair and per-domain-cascade halves of spec 26 are deliberately left
// to the handwritten spec until those helpers are exported. See the unit report.

import { expect } from '@playwright/test';
import { Then, requireDimension } from './world';
import { persona } from './dimensions';
import {
  SYSTEMS_SEED_USERS, GAMES_SEED_USERS, systemsUser,
  SYSTEMS_ISSUER, GAMES_ISSUER,
} from '../specs/rbac-roles';
import { gatewayDecision, effectiveRoles } from '../specs/rbac-route-access';
import type { Gateway } from '../specs/rbac-route-access';

/**
 * The EFFECTIVE systems role-set the gateways decide on: the granted roles plus
 * the DERIVED composites — ROLE_GAMES_ADMIN ( = ROLE_GAMES n (ROLE_ADMIN u
 * ROLE_MOD), via the shared oracle's effectiveRoles) and ROLE_FORUM_MOD
 * ( = ROLE_MOD n ROLE_FORUM, materialised by the forum reconcile Job exactly as
 * ROLE_GAMES_ADMIN is). Same derivation spec 26 applies.
 */
function effectiveSystemsRoles(username: string): string[] {
  const u = systemsUser(username);
  const set = new Set<string>(effectiveRoles(u.roles, u.expectGamesAdmin));
  if (set.has('ROLE_MOD') && set.has('ROLE_FORUM')) set.add('ROLE_FORUM_MOD');
  return [...set];
}

/** Fail naming the legal gateways rather than silently deciding on a typo — an
 *  unknown gateway matches no row and would DENY, which reads as a passing
 *  negative assertion. */
const GATEWAYS: Gateway[] = [
  'hugmesh-pki-gateway', 'hugmesh-be-gateway', 'hugmesh-fe-gateway', 'hugmesh-superadmin-gateway',
];
function gateway(name: string): Gateway {
  if (!(GATEWAYS as string[]).includes(name)) {
    throw new Error(
      `unknown gateway "${name}". Legal gateways (specs/rbac-route-access.ts): ${GATEWAYS.join(', ')}. `
      + `A typo would match NO route row and decide DENY, which passes a negative assertion for `
      + `the wrong reason.`,
    );
  }
  return name as Gateway;
}

function decision(value: string): 'ALLOW' | 'DENY' {
  if (value !== 'ALLOW' && value !== 'DENY') {
    throw new Error(`expected decision "ALLOW" or "DENY" in the Examples table, got "${value}".`);
  }
  return value;
}

Then('the route-access oracle decides {string} for this persona at {string} on gateway {string}',
  async ({ dimensions }, expected: string, path: string, gw: string) => {
    const handle = persona(requireDimension(dimensions, 'role'));
    const roles = effectiveSystemsRoles(handle);
    expect(
      gatewayDecision(gateway(gw), path, roles),
      `${gw} ${path} for '${handle}' with effective roles [${roles.join(', ')}]`,
    ).toBe(decision(expected));
  });

Then('persona {string} is denied {string} on gateway {string}',
  async ({}, handle: string, path: string, gw: string) => {
    const roles = effectiveSystemsRoles(persona(handle));
    expect(
      gatewayDecision(gateway(gw), path, roles),
      `'${handle}' (effective roles [${roles.join(', ')}]) must NOT reach ${gw} ${path} — `
      + `ROLE_SUPERADMIN is a DISTINCT tier, not a superset admin inherits`,
    ).toBe('DENY');
  });

Then('the effective roles of this persona are exactly {string}', async ({ dimensions }, expected: string) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  const want = expected.split(',').map((s) => s.trim()).filter(Boolean).sort();
  expect(effectiveSystemsRoles(handle).sort(), `effective roles of '${handle}'`).toEqual(want);
});

// ── issuer isolation ─────────────────────────────────────────────────────────

Then('the systems realm issuer differs from the games realm issuer', async () => {
  expect(SYSTEMS_ISSUER, 'the isolation PREMISE: two independent Casdoors').not.toBe(GAMES_ISSUER);
});

Then('no seeded games-realm identity carries a systems ROLE_ prefix', async () => {
  for (const g of GAMES_SEED_USERS) {
    for (const r of g.roles) {
      expect(
        r.startsWith('ROLE_'),
        `games role "${r}" on ${g.username} must not masquerade as a systems ROLE_*`,
      ).toBeFalsy();
    }
  }
});

Then('no seeded systems identity carries a games-native role', async () => {
  for (const u of SYSTEMS_SEED_USERS) {
    for (const r of u.roles) {
      expect(r.startsWith('ROLE_'), `systems role "${r}" on ${u.username} is a systems ROLE_*`).toBeTruthy();
      expect(
        ['player', 'admin'].includes(r),
        `systems role "${r}" on ${u.username} must not be a native games role — the synced games `
        + `admin is a games Casdoor ROW (owned by hugmesh-actions), never a systems-token claim`,
      ).toBeFalsy();
    }
  }
});

Then('every seeded games-realm identity is denied {string} on gateway {string}',
  async ({}, path: string, gw: string) => {
    for (const g of GAMES_SEED_USERS) {
      // What a systems gateway would see IF it wrongly trusted the games token.
      expect(
        gatewayDecision(gateway(gw), path, g.roles),
        `games identity ${g.username} (roles [${g.roles.join(', ')}]) must be DENIED ${gw} ${path} — `
        + `a GENERIC deny across realms, never a 404-vs-403 existence leak`,
      ).toBe('DENY');
    }
  });
