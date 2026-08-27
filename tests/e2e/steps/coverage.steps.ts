// coverage.steps.ts — the twelve step definitions the GENERATED coverage matrix
// under features/coverage/ binds to.
//
// THE ANTI-CIRCULARITY RULE THAT MAKES THIS LANE WORTH RUNNING. Every assertion
// below compares a value RECOMPUTED at run time from the committed artefacts
// (specs/cluster/manifests/route-access/initdb/20-schema.sql, the three persona
// rosters, steps/dimensions.ts SERVICES) against a LITERAL that was written into
// the .feature file when the matrix was emitted. The literal is the pin. Change
// the route-access seed, or a persona's roles, or a function's probe path, and
// the cells that moved go RED until somebody re-emits and reviews the diff.
//
// A step that merely recomputed the expectation and compared it with itself
// would be green forever and would prove exactly nothing — that is the vacuity
// this file exists to avoid, and the mutation battery in
// tests/scripts/test-e2e-coverage-matrix.sh attacks it directly (M4 rewrites the
// oracle to answer 'admitted' for everyone; a self-comparing step would survive).
//
// NO STACK, NO NETWORK, NO SUBPROCESS. Every one of these reads committed files.
// The matrix is therefore fully runnable on a laptop with nothing started, which
// is the only way a 2000-cell lane ever actually gets run.

import { expect } from '@playwright/test';
import { Then, requireDimension } from './world';
import { SERVICES, personaSource } from './dimensions';
import {
  expectedOutcome, serviceFunction, rosterEntry, effectiveRolesOf, roster,
  servicesWithoutFunctions, functionsWithUnknownService, gamesAdminDisagreements,
  coverageCells, FUNCTIONS, Decision,
} from './coverage-catalogue';

/** Pinned world key: the decision the previous step computed, so the pattern
 *  assertion reads the SAME evaluation rather than re-deriving a second one. */
const DECISION_KEY = 'coverage.decision';

// ── the access matrix ────────────────────────────────────────────────────────

Then('persona {string} is {string} at the {string} function',
  async ({ world, dimensions }, handle: string, outcome: string, functionId: string) => {
    // The emitted table may only carry the two legal outcomes. A typo'd cell
    // must die here rather than being compared as a string nobody produces.
    expect(['admitted', 'refused'], `'${outcome}' is not a legal outcome`).toContain(outcome);

    // Anti-ghost-persona: the handle has to be created by a seeder that runs, or
    // the whole row is describing somebody who does not exist. This is the exact
    // 2026-08-06 e2e-fleet symptom (a 401 that reads like a broken login).
    expect(personaSource(handle), `no seeder creates persona '${handle}'`).toBeDefined();

    const fn = serviceFunction(functionId);
    // The row's function must belong to the service the FEATURE is tagged with —
    // otherwise an emitter bug could file a row under the wrong service and the
    // per-service coverage claim would be false while every row still passed.
    expect(fn.service, `function '${functionId}' is not a ${requireDimension(dimensions, 'service')} function`)
      .toBe(requireDimension(dimensions, 'service'));

    const decision = expectedOutcome(handle, functionId);
    world.set(DECISION_KEY, decision);
    expect(
      decision.outcome,
      `${handle} at ${functionId} (${fn.gateway} ${fn.probePath})\n`
      + `  effective roles : ${effectiveRolesOf(handle).join(', ') || '(none)'}\n`
      + `  seed says       : ${decision.why}\n`
      + `  the committed matrix row expects '${outcome}'. If the route-access seed or the\n`
      + `  persona roster changed on purpose, re-emit with\n`
      + `    bash tests/e2e/gen-coverage-matrix.sh\n`
      + `  and review the diff — do not edit the .feature by hand.`,
    ).toBe(outcome);
  });

Then('the seed decides that at pattern {string}', async ({ world }, pattern: string) => {
  const d = world.get<Decision>(DECISION_KEY);
  const actual = d.pattern ?? '(none — default deny)';
  expect(
    actual,
    `the winning url_pattern moved. ${d.why}\n`
    + `  A pattern change with the SAME outcome is the dangerous kind: the cell still\n`
    + `  reads green while a different rule is now doing the deciding.`,
  ).toBe(pattern);
});

// ── the function catalogue ───────────────────────────────────────────────────

Then('the {string} function belongs to the {string} service',
  async ({}, functionId: string, serviceId: string) => {
    expect(serviceFunction(functionId).service, `function '${functionId}' service`).toBe(serviceId);
  });

Then('the {string} function probes {string} at {string}',
  async ({}, functionId: string, gateway: string, probePath: string) => {
    const f = serviceFunction(functionId);
    expect(f.gateway, `function '${functionId}' gateway`).toBe(gateway);
    expect(f.probePath, `function '${functionId}' probe path`).toBe(probePath);
  });

Then('the {string} function probe path is {string}',
  async ({}, functionId: string, evidence: string) => {
    expect(['derived', 'asserted'], `'${evidence}' is not a legal evidence label`).toContain(evidence);
    const f = serviceFunction(functionId);
    expect(
      f.evidence,
      `function '${functionId}' probe path is labelled '${f.evidence}' but the matrix was `
      + `emitted with '${evidence}'. The label is how a reader tells a path READ OFF a `
      + `committed artefact from one a human chose; silently promoting an asserted path to `
      + `derived would launder a guess into a measurement. Source on file: ${f.source}`,
    ).toBe(evidence);
    if (f.evidence === 'derived') {
      expect(
        f.source.trim(),
        `function '${functionId}' claims a DERIVED probe path but records no source artefact`,
      ).not.toBe('');
    }
  });

Then('every service in the catalogue has at least one function', async ({}) => {
  expect(
    servicesWithoutFunctions(),
    `these SERVICES ids have NO catalogued function, so the coverage matrix emits zero `
    + `cells for them and "every service is covered" is false. Add functions to `
    + `steps/coverage-catalogue.ts FUNCTIONS and re-emit.`,
  ).toEqual([]);
  expect(SERVICES.length, 'SERVICES is empty').toBeGreaterThan(0);
});

Then('every catalogued function names a legal service', async ({}) => {
  expect(
    functionsWithUnknownService(),
    `these FUNCTIONS entries name a service id that is not in steps/dimensions.ts SERVICES. `
    + `A typo'd service id produces cells nobody can attribute.`,
  ).toEqual([]);
  expect(FUNCTIONS.length, 'FUNCTIONS is empty').toBeGreaterThan(0);
});

Then('no seeded persona is admitted at the {string} function',
  async ({}, functionId: string) => {
    serviceFunction(functionId);
    const admitted = coverageCells()
      .filter((c) => c.functionId === functionId && c.outcome === 'admitted')
      .map((c) => c.handle);
    expect(
      admitted,
      `'${functionId}' was pinned as reachable by NOBODY, but ${admitted.length} persona(s) now `
      + `reach it: ${admitted.join(', ')}. That is usually GOOD NEWS — a role that nothing `
      + `seeded is now seeded. Re-emit with 'bash tests/e2e/gen-coverage-matrix.sh' so the `
      + `unreachable list shrinks deliberately and the diff records who closed the gap.`,
    ).toEqual([]);
  });

// ── the persona roster ───────────────────────────────────────────────────────

Then('the persona {string} is seeded by exactly the lanes {string}',
  async ({}, handle: string, lanes: string) => {
    const e = rosterEntry(handle);
    expect(
      e.lanes.join('+'),
      `the seeding lanes for '${handle}' changed. The three rosters `
      + `(specs/rbac-roles.ts, tests/e2e-extra-personas.sh, tests/qemu/seed-accounts.sh) `
      + `deliberately DISAGREE and the disagreement is pinned here rather than resolved — a `
      + `handle quietly gaining or losing a lane is how the kind cluster ended up without `
      + `e2e-fleet in the first place.`,
    ).toBe(lanes);
  });

Then('the persona {string} presents the effective roles {string}',
  async ({}, handle: string, expected: string) => {
    const actual = effectiveRolesOf(handle).join(',') || '(none)';
    expect(
      actual,
      `the EFFECTIVE role-set of '${handle}' changed (granted roles + the derived `
      + `ROLE_GAMES_ADMIN composite, emptied when the two-stage registration gate is `
      + `uncleared). Every access-matrix cell for this persona is computed from it.`,
    ).toBe(expected);
  });

Then('the persona {string} registration-complete flag is {string}',
  async ({}, handle: string, expected: string) => {
    expect(['true', 'false'], `'${expected}' is not a boolean cell`).toContain(expected);
    expect(
      String(rosterEntry(handle).registrationComplete),
      `'${handle}' registrationComplete. A persona flipped to complete presents its full `
      + `role-set at the gateway instead of nothing at all, which moves every one of its `
      + `${FUNCTIONS.length} cells.`,
    ).toBe(expected);
  });

Then('the derived games-admin composite agrees with every declared expectation', async ({}) => {
  expect(
    gamesAdminDisagreements(),
    `these personas' DERIVED ROLE_GAMES_ADMIN (computed as ROLE_GAMES INTERSECT (ROLE_ADMIN `
    + `UNION ROLE_MOD), the rule the games-admin-sync Job implements) disagrees with the `
    + `expectGamesAdmin flag declared beside them in specs/rbac-roles.ts. One of the two is `
    + `wrong, and the access matrix believes the derivation.`,
  ).toEqual([]);
  // Non-vacuity: the check means nothing if nobody qualifies at all.
  expect(
    roster().filter((p) => p.derivedGamesAdmin).map((p) => p.handle).length,
    'NO persona qualifies for the derived ROLE_GAMES_ADMIN composite, so the agreement above '
    + 'is vacuously true. The roster must seed at least one ROLE_GAMES + ROLE_ADMIN/ROLE_MOD '
    + 'persona (e2e-gamesadmin) or the games-admin gate is untested.',
  ).toBeGreaterThan(0);
});
