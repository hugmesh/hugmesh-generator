// func-media-games.steps.ts — the FUNCTION-axis vocabulary for owncast, tube,
// games and the two character tools.
//
// WHAT THIS FILE IS FOR. The four services in this domain went from ZERO coverage
// to a CONTRACT tier plus one console scenario each. That proved the route
// resolves; it said nothing about whether a stream can be published, a download
// watched, an instance launched or a character saved. Those are the FUNCTIONS,
// and this file is the machinery that makes a missing function a RED RESULT
// instead of an absence nobody counts.
//
// SIX STEPS, ALL OFFLINE. Not one of them opens a browser or needs a mesh. They
// resolve three independent sources against each other:
//
//     the .feature file    what the author CLAIMS this function is
//     function-catalogue   what the domain says the function IS
//     the route-access seed + the two persona rosters (files in THIS repo)
//
// A claim that agrees with only two of the three fails. That is the whole design:
// a catalogue nobody checks rots, and a Gherkin scenario that quotes a role out of
// its author's memory rots faster.
//
// WHY NOT A `@function:` DIMENSION IN steps/dimensions.ts. It would have to be
// added to that file's AXES tuple, which five other authors are editing this week,
// and a dimension is validated at Before-hook time for EVERY scenario in the
// suite — an axis only this domain uses has no business gating all 460. The
// function id travels as a step ARGUMENT (visible in the Gherkin, validated when
// the step runs) and as a `@function:<id>` TAG that the census step reads straight
// off the feature files. Tags cost nothing: parseDimensionText only looks at the
// axes it knows, so an unknown tag is inert everywhere else.
//
// REUSE, NOT RE-PARSE. The route-access seed parser is the one already in
// uncovered-services.steps.ts, exported rather than copied. A second parser of the
// same file is how this repo grew three divergent persona lists.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from '@playwright/test';
import { Then, requireDimension } from './world';
import { accessRows } from './uncovered-services.steps';
import { knownPersonas } from './dimensions';
import {
  CATALOGUED_SERVICES, FUNCTIONS, MeshFunction, functionsOf, meshFunction,
  parsePersonas, renderPersonas, rosterPersonasHolding,
} from './function-catalogue';

/** tests/e2e/features — the tree the census step reads. */
const FEATURES_DIR = path.resolve(__dirname, '..', 'features');

/** Every allow row the seed carries at one function's exact (gateway, pattern). */
function allowRowsFor(fn: MeshFunction) {
  return accessRows().filter(
    (r) => r.gateway === fn.gateway && r.pattern === fn.pattern && r.allow,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 1. the function's GATE — Gherkin, catalogue and seed must all three agree
// ═══════════════════════════════════════════════════════════════════════════

/**
 * The three-way agreement. `<role>` and `<pattern>` are written in the feature
 * file so a reader sees the gate without opening a TypeScript module; the
 * catalogue must say the same; and the committed route-access seed must actually
 * carry that ALLOW row on the catalogued gateway.
 *
 * The seed leg is the one that matters. A gateway that is DEFAULT-DENY turns a
 * missing row into a 403 for everyone — the exact gap the wiki/owncast/tube UI
 * mounts sat in before their rows were added — and no amount of agreement between
 * a feature file and a catalogue would have caught it.
 */
Then(
  'the {string} function is gated by {string} at {string}',
  async ({ dimensions }, functionId: string, role: string, pattern: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = meshFunction(serviceId, functionId);

    expect(
      fn.pattern,
      `feature file says '${serviceId}/${functionId}' travels '${pattern}', the catalogue `
      + `says '${fn.pattern}'. One of the two is stale — fix the WRONG one, and note that `
      + `the route-access seed is the tiebreak, not either of these.`,
    ).toBe(pattern);

    expect(
      fn.gateRole,
      `feature file says '${serviceId}/${functionId}' is gated by ${role}, the catalogue `
      + `says ${fn.gateRole}.`,
    ).toBe(role);

    const rows = allowRowsFor(fn);
    expect(
      rows.map((r) => r.role),
      `the committed route-access seed carries NO ${fn.gateway} allow row granting ${role} `
      + `at '${pattern}'. Rows present at that pattern: `
      + `${rows.map((r) => r.role).join(', ') || '<none at all>'}. The gateway is `
      + `DEFAULT-DENY: a function whose surface has no row is a 403 for every principal, `
      + `however correct the UI guard above it looks.`,
    ).toContain(role);
  },
);

/** The catalogue's own verdict, pinned in the Gherkin so the two cannot drift
 *  apart quietly. 'ui' = a seeded persona can drive it today; 'no-audience' = the
 *  surface is wired but nobody is seeded who can reach it; 'absent' = there is
 *  nothing mounted to drive at all. The difference decides whether a pending
 *  scenario is waiting on a SEED or on a BUILD, and stating it out loud is what
 *  stops "pending" from becoming a shrug. */
Then(
  'the {string} function is catalogued as {string}',
  async ({ dimensions }, functionId: string, verdict: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = meshFunction(serviceId, functionId);
    const legal = ['ui', 'no-audience', 'absent'];
    expect(
      legal,
      `'${verdict}' is not a driveability verdict. Legal: ${legal.join(' | ')}.`,
    ).toContain(verdict);
    expect(
      fn.driveability,
      `the catalogue rates '${serviceId}/${functionId}' as '${fn.driveability}', the feature `
      + `file claims '${verdict}'.`,
    ).toBe(verdict);
    if (fn.driveability === 'ui') {
      expect(
        fn.blockedBy,
        `'${serviceId}/${functionId}' is rated drivable but still carries a blockedBy `
        + `reason. A drivable function needs no excuse; clear it or downgrade the verdict.`,
      ).toBe('');
    } else {
      expect(
        fn.blockedBy.length,
        `'${serviceId}/${functionId}' is rated '${fn.driveability}' with an EMPTY reason. `
        + `A skip with no named reason is a silent skip wearing a coat — write what is `
        + `missing and what would unblock it.`,
      ).toBeGreaterThan(40);
    }
  },
);

// ═══════════════════════════════════════════════════════════════════════════
// 2. the ACCESS MATRIX — derived from the rosters, so a new persona moves it
// ═══════════════════════════════════════════════════════════════════════════

/**
 * THE GENERATIVE GUARD. The expected persona set is written out in the feature
 * file; the ACTUAL set is computed by walking both seeded rosters and asking who
 * holds any role the seed grants at this function's surface. Seed one more
 * persona — in specs/rbac-roles.ts or tests/e2e-extra-personas.sh — and the
 * computed set moves while the written one does not, and this goes RED naming
 * exactly who arrived. That is the point: coverage that expands when the mesh
 * does, instead of a matrix somebody has to remember to widen.
 *
 * WHAT IT DELIBERATELY DOES NOT MODEL: the gateway ADMIN-BYPASS. The seed's own
 * comments say admins reach a floor row "via the gateway admin-bypass", which is
 * why /owncast/**, /tube/** and /social/forum/** pair no ROLE_ADMIN. This step
 * answers only "who does the SEED name" — an offline, checkable question. Who
 * actually gets through is what the driven @env: scenarios answer. Blending the
 * two would produce one number that is evidence for neither.
 */
Then(
  'the {string} function is reachable by exactly the roster personas {string}',
  async ({ dimensions }, functionId: string, expected: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = meshFunction(serviceId, functionId);
    const rows = allowRowsFor(fn);
    expect(
      rows.length,
      `no ${fn.gateway} allow row at '${fn.pattern}', so the computed persona set would be `
      + `empty for a reason that has nothing to do with the roster. Fix the surface first.`,
    ).toBeGreaterThan(0);

    const roles = [...new Set(rows.map((r) => r.role))].sort();
    const actual = rosterPersonasHolding(roles);
    const want = parsePersonas(expected);

    expect(
      renderPersonas(actual),
      `the roster-derived audience for '${serviceId}/${functionId}' has MOVED.\n`
      + `  surface : ${fn.gateway} ${fn.pattern}\n`
      + `  roles the seed grants there : ${roles.join(', ')}\n`
      + `  feature file says : ${renderPersonas(want) || '<nobody>'}\n`
      + `  rosters actually seed : ${renderPersonas(actual) || '<nobody>'}\n`
      + `If a persona ARRIVED, this function now has an audience it did not have — widen `
      + `the driven scenarios for it and update this row. If one LEFT, a scenario that `
      + `used to run is now driving a persona nothing creates.`,
    ).toBe(renderPersonas(want));
  },
);

/**
 * The zero-audience tripwire, per function. Distinct from
 * access-role-roster.feature, which asks the question once per SERVICE: a service
 * can have an audience for its console and none at all for its central function,
 * which is exactly owncast's shape (admins govern it, nobody can stream on it).
 */
Then(
  'the {string} function has no seeded persona holding its own access role',
  async ({ dimensions }, functionId: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = meshFunction(serviceId, functionId);
    const holders = rosterPersonasHolding([fn.gateRole]);
    expect(
      renderPersonas(holders),
      `'${serviceId}/${functionId}' is written as an un-drivable function, but `
      + `${holders.length} roster persona(s) now hold ${fn.gateRole}: `
      + `${renderPersonas(holders)}. The gap has CLOSED — go and write the real journey `
      + `this scenario has been standing in for, and delete the pending one.`,
    ).toBe('');
    expect(
      fn.driveability,
      `'${serviceId}/${functionId}' claims no audience but the catalogue rates it '${fn.driveability}'.`,
    ).not.toBe('ui');
  },
);

// ═══════════════════════════════════════════════════════════════════════════
// 3. the CENSUS — a catalogued function with no scenario is a red result
// ═══════════════════════════════════════════════════════════════════════════

let featureTextCache: string | undefined;

/** Every .feature file in the suite, concatenated. Read once. The census asks
 *  "does ANY scenario anywhere name this function", not "does one in this
 *  directory" — a function covered from another domain still counts. */
function allFeatureText(): string {
  if (featureTextCache !== undefined) return featureTextCache;
  const parts: string[] = [];
  const walk = (dir: string): void => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.feature')) parts.push(fs.readFileSync(p, 'utf8'));
    }
  };
  walk(FEATURES_DIR);
  if (parts.length === 0) {
    throw new Error(
      `found ZERO .feature files under ${FEATURES_DIR}. The census would then pass `
      + `vacuously for every function — refusing.`,
    );
  }
  featureTextCache = parts.join('\n');
  return featureTextCache;
}

/**
 * Which function ids the Gherkin tags FOR THIS SERVICE.
 *
 * SERVICE-SCOPED ON PURPOSE. Two services in this domain catalogue a function
 * called 'open' and two catalogue one called 'console'; a bare id set would let
 * one scenario tagged '@function:open @service:character-studio' silently satisfy
 * the census for character-forge as well, which is coverage claimed for a service
 * nobody drove. So a tag counts only where '@function:<id>' and
 * '@service:<serviceId>' appear on the SAME line — which is how every scenario in
 * this domain is written: the tag line carries both, and so does the Scenario
 * (Outline) name, per the tag-suffix convention in features/README.md 2b.
 *
 * COMMENTS ARE STRIPPED FIRST. A '@function:' written inside a '#' comment — and
 * this domain's feature files are more comment than Gherkin — would otherwise
 * count as coverage. Comment-token inversion has bitten this repo five times; it
 * does not get to bite the guard whose entire job is counting.
 *
 * A Scenario Outline that VARIES the function writes '@function:<function>' — a
 * literal placeholder, not an id — so it does not match and cannot satisfy the
 * census for the rows it happens to enumerate. That is deliberate: the census is
 * meant to measure per-function scenarios, not the table that lists them.
 */
function taggedFunctionIds(serviceId: string): Set<string> {
  const ids = new Set<string>();
  for (const line of allFeatureText().split('\n')) {
    if (/^\s*#/.test(line)) continue;
    if (!line.includes(`@service:${serviceId}`)) continue;
    for (const m of line.matchAll(/@function:([a-z0-9-]+)/g)) ids.add(m[1]);
  }
  return ids;
}

Then(
  'every catalogued function of this service is named by a scenario',
  async ({ dimensions }) => {
    const serviceId = requireDimension(dimensions, 'service');
    const catalogued = functionsOf(serviceId);
    expect(
      catalogued.length,
      `the catalogue lists NO functions for service '${serviceId}', so this census would `
      + `pass by having nothing to check.`,
    ).toBeGreaterThan(0);

    const tagged = taggedFunctionIds(serviceId);
    const missing = catalogued.filter((f) => !tagged.has(f.id)).map((f) => `${f.service}/${f.id}`);
    expect(
      missing,
      `these catalogued functions have NO scenario tagged '@function:<id>' anywhere under `
      + `${FEATURES_DIR}:\n  ${missing.join('\n  ')}\n`
      + `A catalogued function with no scenario is the hole this guard exists to report. `
      + `Write the scenario — a PENDING one naming what it needs counts, a comment does not.`,
    ).toEqual([]);
  },
);

/** Pins the SCOPE of the catalogue, so a service added to FUNCTIONS without a row
 *  in the census Examples table cannot slip through un-censused. Without this the
 *  census is only ever as complete as the table somebody remembered to extend. */
Then(
  'the function catalogue covers exactly the services {string}',
  async ({}, expected: string) => {
    const declared = [...new Set(FUNCTIONS.map((f) => f.service))].sort();
    const pinned = [...CATALOGUED_SERVICES].sort();
    const want = expected.split(',').map((s) => s.trim()).filter(Boolean).sort();

    expect(
      declared.join(', '),
      `steps/function-catalogue.ts FUNCTIONS carries entries for services `
      + `[${declared.join(', ')}] but CATALOGUED_SERVICES pins [${pinned.join(', ')}]. `
      + `The two are one list spelled twice — reconcile them.`,
    ).toBe(pinned.join(', '));

    expect(
      declared.join(', '),
      `the census Examples table covers [${want.join(', ')}] but the catalogue covers `
      + `[${declared.join(', ')}]. A service in the catalogue and not in the table is `
      + `never censused, which is a coverage claim nobody measured.`,
    ).toBe(want.join(', '));
  },
);

/**
 * The COMPLEMENT of the step above, and the one that is legible for a floor row.
 * `/character-studio/**` is granted to ROLE_USER, which 28 of the 31 seeded
 * handles hold — writing all 28 into a Gherkin cell would be a wall nobody reads
 * and everybody rubber-stamps. The three the seed does NOT name are the
 * interesting fact, and they are a surprising three: e2e-superadmin (ROLE_SUPERADMIN
 * alone), e2e-mod (ROLE_MOD alone) and e2e-pending (no roles at all) hold no
 * ROLE_USER, so no allow row at the character tools' floor names them.
 *
 * Same non-modelling caveat as above: an admin — and, by the admin-bypass, plausibly
 * a superadmin — gets through without being named. A BARE MOD is named by nothing
 * and is not an admin, which is the row of this matrix most worth a live check.
 */
Then(
  'the {string} function is refused by exactly the roster personas {string}',
  async ({ dimensions }, functionId: string, expected: string) => {
    const serviceId = requireDimension(dimensions, 'service');
    const fn = meshFunction(serviceId, functionId);
    const rows = allowRowsFor(fn);
    expect(
      rows.length,
      `no ${fn.gateway} allow row at '${fn.pattern}' — every persona would be "refused" `
      + `for a reason that has nothing to do with the roster.`,
    ).toBeGreaterThan(0);

    const roles = [...new Set(rows.map((r) => r.role))].sort();
    const admitted = new Set(rosterPersonasHolding(roles));
    const actual = knownPersonas().filter((h) => !admitted.has(h)).sort();
    const want = parsePersonas(expected);

    expect(
      renderPersonas(actual),
      `the set of roster personas NO allow row names at '${fn.pattern}' has MOVED.\n`
      + `  roles the seed grants there : ${roles.join(', ')}\n`
      + `  feature file says refused : ${renderPersonas(want) || '<nobody>'}\n`
      + `  rosters actually leave out : ${renderPersonas(actual) || '<nobody>'}\n`
      + `A persona that JOINED this set lost its seeded access to '${serviceId}/${functionId}'; `
      + `one that LEFT it gained access nobody wrote a scenario for.`,
    ).toBe(renderPersonas(want));
  },
);
