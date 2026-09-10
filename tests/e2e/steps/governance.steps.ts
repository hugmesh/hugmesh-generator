// governance.steps.ts — the FUNCTION tier for the governance consoles.
//
// DOMAIN: admin, mod, superadmin, fleet, games-admin, per-service admin, and the
// gateway/login surfaces — crossed against EVERY seeded identity, with the
// REFUSAL asserted exactly as hard as the admission. 967 of the 1122 decisions
// this file makes are DENY; that ratio is the point, not a side effect.
//
// EVERYTHING HERE RUNS OFFLINE. Every step below is a pure function over two
// files that ship in the repo (the route-access seed and the persona
// catalogues), so the whole tier is green with the compose stack, the kind
// cluster and every emulator DOWN. That is deliberate: this domain's value today
// is the CONTRACT, and a contract tier that needs a stack is a contract tier
// nobody runs.
//
// WHY THE ASSERTIONS ARE LEDGERS AND NOT expect(a).toBe(b). A matrix step that
// fails on the first bad cell tells you one cell. Every step below collects
// EVERY violation, then asserts the collection is empty — so one run tells you
// the whole shape of a regression (e.g. "the mod tier lost /bff/mod/** " reads
// as 3 functions x 7 identities in one message, not as one arbitrary pair).
//
// STEP VOCABULARY. Checked against all 251 pre-existing definitions before
// writing (see the unit report); nothing here redefines or re-words an existing
// step. The shared vocabulary in common.steps.ts is REUSED for evidence
// assertions rather than mirrored.

import { expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Given, Then, requireDimension } from './world';
import { persona } from './dimensions';
import { gatewayDecision } from '../specs/rbac-route-access';
import {
  GOVERNANCE_FUNCTIONS, GOVERNANCE_CONSOLES, governanceFunction, functionsForConsole,
  governancePersonas, governancePersona, governanceMatrix,
  governanceCatalogueProblems, personaCatalogueProblems, tsMirrorGaps,
  mirrorGrantsTheSeedDoesNot, swarmMembersNotCoveredByRepresentative, swarmRepresentatives,
  equivalenceCorpus, collisionCorpus, withOracleCollisionRows,
  decideWith, sqlDecision, sqlRouteRows, TS_MIRROR_ROWS,
  GovernanceConsole,
} from './governance';

// ── the ledger artefact ──────────────────────────────────────────────────────
//
// Written OUTSIDE ${SNAP_REPORT_DIR}/bdd-steps/ on purpose. That tree is the
// per-step evidence manifest's territory and its guard asserts "every file under
// the run dir has a manifest row"; dropping an un-rowed file in there would fail
// a sibling unit's guard for a reason that has nothing to do with it. The ledger
// lives beside it and is ALSO attached to the test, so it reaches the HTML report
// without needing a manifest row or a new ArtefactKind.

function ledgerDir(): string {
  const root = process.env['SNAP_REPORT_DIR'] || 'test-results';
  const runId = process.env['SNAP_RUN_ID'] || 'local';
  return path.resolve(root, 'governance-ledger', runId);
}

async function recordLedger($testInfo: { attach: Function; title: string }, name: string, body: unknown) {
  const dir = ledgerDir();
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${name}.json`);
  const text = JSON.stringify(body, null, 2);
  fs.writeFileSync(file, text);
  await $testInfo.attach(`governance-${name}`, { body: text, contentType: 'application/json' });
  return file;
}

function decisionWord(v: string): 'ALLOW' | 'DENY' | 'NO_RULE' {
  if (v !== 'ALLOW' && v !== 'DENY' && v !== 'NO_RULE') {
    throw new Error(
      `a governance decision is 'ALLOW', 'DENY' or 'NO_RULE', never '${v}'. (Legal values are `
      + `the same THREE the route-access oracle uses — NO_RULE is a path no url_pattern `
      + `matches, which the filter FORWARDS; do not invent 'allowed'/'denied'/'403'.)`,
    );
  }
  return v;
}

function consoleName(v: string): GovernanceConsole {
  if (!GOVERNANCE_CONSOLES.includes(v as GovernanceConsole)) {
    throw new Error(
      `unknown governance console '${v}'. Legal consoles (steps/governance.ts `
      + `GOVERNANCE_CONSOLES): ${GOVERNANCE_CONSOLES.join(', ')}.`,
    );
  }
  return v as GovernanceConsole;
}

/** Resolve the identity a scenario is about: the @role: axis when it declared
 *  one. Goes through `persona()` first so an unknown handle still fails with the
 *  harness's own legal-handle message rather than mine. */
function personaFromAxis(dimensions: { role?: string }): string {
  return persona(requireDimension(dimensions as never, 'role'));
}

// ═══════════════════════════════════════════════════════════════════════════
// A. THE CATALOGUE ITSELF — does it still describe the shipped mesh?
// ═══════════════════════════════════════════════════════════════════════════

/**
 * The catalogue declares, for every function, WHICH url_pattern governs its
 * probe path and WHICH roles that pattern is keyed on. Both claims are checked
 * against 20-schema.sql. Without this, a seed edit that re-homes a probe under a
 * weaker pattern would leave the whole matrix green while asserting a different
 * door — the failure mode that makes a big matrix worse than no matrix.
 */
Then('the governance function catalogue agrees with the shipped route-access seed',
  async ({ $testInfo }) => {
    const problems = governanceCatalogueProblems();
    await recordLedger($testInfo, 'catalogue', {
      seedPath: 'specs/cluster/manifests/route-access/initdb/20-schema.sql',
      seedRows: sqlRouteRows().length,
      functions: GOVERNANCE_FUNCTIONS.length,
      problems,
    });
    expect(problems, `the governance catalogue no longer matches 20-schema.sql:\n  `
      + `${problems.join('\n  ')}`).toEqual([]);
  });

/**
 * The decision engine in steps/governance.ts is a TRANSCRIPTION of the oracle's
 * private `patternMatch`, and a transcription that is never executed against its
 * source drifts silently — that exact bug shipped once already
 * (fix/superadmin-route-access-row MAJOR #3: a glob scored one way inverts
 * exact-vs-glob, and `/api/federation/vanity` is that live collision). So both
 * engines score every triple the mirror can generate and must agree on all of
 * them. This is what licenses deciding the FUNCTION tier against the SQL.
 */
Then('the governance decision engine agrees with the route-access oracle on every mirrored route',
  async ({ $testInfo }) => {
    const corpus = equivalenceCorpus();
    const disagreements: string[] = [];
    for (const c of corpus) {
      const mine = decideWith(TS_MIRROR_ROWS, c.gateway, c.path, c.roles);
      const theirs = gatewayDecision(c.gateway, c.path, c.roles);
      if (mine.decision !== theirs) {
        disagreements.push(
          `${c.gateway} ${c.path} roles=[${c.roles.join(',')}]: `
          + `steps/governance.ts decideWith says ${mine.decision} (${mine.why}), `
          + `specs/rbac-route-access.ts gatewayDecision says ${theirs}`,
        );
      }
    }
    // THE EXACT-VS-GLOB LEG. The corpus above cannot reach it: the mis-scoring
    // this guards against adds a constant to EVERY glob, so glob-vs-glob ordering
    // is unchanged, and the mirror's 50 rows contain no path where an exact
    // pattern and a glob both match. Measured: with patternScore deliberately
    // mis-transcribed, the corpus above stayed GREEN. So the collision is
    // manufactured inside the oracle's own table for the length of this call.
    const collisions = collisionCorpus();
    const collided = withOracleCollisionRows((rows) => {
      const bad: string[] = [];
      for (const c of collisions) {
        const mine = decideWith(rows, c.gateway, c.path, c.roles);
        const theirs = gatewayDecision(c.gateway, c.path, c.roles);
        if (mine.decision !== theirs) {
          bad.push(
            `[exact-vs-glob] ${c.gateway} ${c.path} roles=[${c.roles.join(',')}]: `
            + `decideWith says ${mine.decision} at '${mine.pattern}', `
            + `gatewayDecision says ${theirs}`,
          );
        }
      }
      return bad;
    });
    disagreements.push(...collided);

    await recordLedger($testInfo, 'engine-equivalence', {
      triples: corpus.length, collisionTriples: collisions.length,
      mirrorRows: TS_MIRROR_ROWS.length, disagreements,
    });
    expect(corpus.length, 'the equivalence corpus is empty, so this proved nothing')
      .toBeGreaterThan(1000);
    expect(collisions.length, 'no exact-vs-glob collision was probed, so the one ordering '
      + 'rule this transcription can silently invert went untested').toBeGreaterThan(0);
    expect(disagreements, `the transcribed decision engine and the route-access oracle `
      + `DISAGREE on ${disagreements.length} of ${corpus.length + collisions.length} triples:\n  `
      + `${disagreements.slice(0, 20).join('\n  ')}`).toEqual([]);
  });

/**
 * The dangerous direction of mirror drift. A mirror that grants MORE than the
 * shipped seed makes an ALLOW expectation pass on a door the mesh really keeps
 * shut — the suite would certify access nobody has. There is no ledger for this
 * one and there must never be.
 */
Then('the route-access mirror grants nothing the shipped seed withholds', async ({ $testInfo }) => {
  const over = mirrorGrantsTheSeedDoesNot();
  await recordLedger($testInfo, 'mirror-overgrants', { overGrants: over });
  expect(over, `specs/rbac-route-access.ts grants ${over.length} route(s) 20-schema.sql does `
    + `not:\n  ${over.join('\n  ')}`).toEqual([]);
});

/**
 * The mirror gap, LEDGERED. These are governance surfaces the shipped seed
 * governs and the TS mirror does not carry at all — so in the mirror they
 * default-deny for everyone and every DENY expectation about them passes without
 * testing anything. The count is pinned so that WIDENING the mirror (good) and
 * ADDING an unmirrored governance surface (needs a decision) both show up.
 */
Then('the governance surfaces missing from the route-access mirror number exactly {int}',
  async ({ $testInfo }, want: number) => {
    const gaps = tsMirrorGaps();
    await recordLedger($testInfo, 'mirror-gaps', {
      seedRows: sqlRouteRows().length, mirrorRows: TS_MIRROR_ROWS.length, gaps,
    });
    const rendered = gaps.map((g) =>
      `${g.gateway} ${g.pattern} -> [${g.roles.join(',') || 'WALL'}] (functions: ${g.functions.join(', ')})`);
    expect(gaps.length,
      `specs/rbac-route-access.ts is missing ${gaps.length} governance pattern(s) the shipped `
      + `seed carries (expected exactly ${want}). If the mirror was WIDENED, lower this number `
      + `in features/rbac/governance-drift-guard.feature. If a NEW governance surface was added `
      + `to the seed without mirroring it, mirror it or raise the number deliberately — do not `
      + `leave it undecided.\n  ${rendered.join('\n  ')}`).toBe(want);
  });

// ═══════════════════════════════════════════════════════════════════════════
// B. THE MATRIX — every identity x every function
// ═══════════════════════════════════════════════════════════════════════════

/**
 * THE GENERATIVE CORE. Every catalogued identity against every catalogued
 * function: what the catalogue's hand-declared `keyedOn` says should happen,
 * versus what the shipped seed actually decides. Two independently-written
 * encodings — an operator's statement of intent and the SQL the mesh runs — must
 * agree on all of them.
 *
 * Adding a persona or a function expands this automatically; nothing in the
 * .feature enumerates rows.
 */
Then('every governance function is decided for every seeded identity', async ({ $testInfo }) => {
  const cells = governanceMatrix();
  const mismatches = cells.filter((c) => c.expected !== c.actual);
  const byConsole: Record<string, { allow: number; deny: number }> = {};
  for (const c of cells) {
    const b = byConsole[c.console] ?? (byConsole[c.console] = { allow: 0, deny: 0 });
    if (c.actual === 'ALLOW') b.allow++; else b.deny++;
  }
  await recordLedger($testInfo, 'matrix', {
    identities: governancePersonas().length,
    functions: GOVERNANCE_FUNCTIONS.length,
    cells: cells.length,
    allow: cells.filter((c) => c.actual === 'ALLOW').length,
    deny: cells.filter((c) => c.actual === 'DENY').length,
    byConsole,
    mismatches: mismatches.map((c) => ({
      persona: c.persona, fn: c.fn, expected: c.expected, actual: c.actual, why: c.verdict.why,
    })),
    cellsDetail: cells.map((c) => ({
      persona: c.persona, fn: c.fn, console: c.console,
      decision: c.actual, pattern: c.verdict.pattern, why: c.verdict.why,
    })),
  });

  // A matrix that decided nothing is the failure this whole unit exists to
  // avoid, so refuse to be vacuous before asserting anything about it.
  expect(cells.length, 'the governance matrix produced ZERO cells').toBeGreaterThan(500);
  expect(cells.filter((c) => c.actual === 'ALLOW').length,
    'EVERY cell denied — an all-DENY matrix passes its refusal assertions for free and '
    + 'proves nothing about admission').toBeGreaterThan(0);
  expect(cells.filter((c) => c.actual === 'DENY').length,
    'EVERY cell admitted — the refusals this domain exists to assert are all vacuous')
    .toBeGreaterThan(0);

  expect(mismatches.map((c) => `${c.persona} x ${c.fn}: catalogue expects ${c.expected}, `
    + `20-schema.sql decides ${c.actual} (${c.verdict.why})`),
  `the governance catalogue and the shipped route-access seed disagree on `
  + `${mismatches.length} of ${cells.length} persona x function decisions`).toEqual([]);
});

/** One cell, named, for the rows an operator reads directly. */
Then('the identity {string} is {string} the {string} governance function',
  async ({}, handle: string, want: string, fnId: string) => {
    const p = governancePersona(handle);
    const fn = governanceFunction(fnId);
    const v = sqlDecision(fn.gateway, fn.probePath, p.roles);
    expect(v.decision, `${handle} (roles ${JSON.stringify(p.roles)}) at ${fn.gateway} `
      + `${fn.probePath} [${fn.name}] — ${v.why}`).toBe(decisionWord(want));
  });

/** The same cell, addressed through the @role: axis, for Scenario Outlines that
 *  already vary the persona on that axis. */
Then('the persona for this scenario is {string} the {string} governance function',
  async ({ dimensions }, want: string, fnId: string) => {
    const handle = personaFromAxis(dimensions);
    const p = governancePersona(handle);
    const fn = governanceFunction(fnId);
    const v = sqlDecision(fn.gateway, fn.probePath, p.roles);
    expect(v.decision, `${handle} (roles ${JSON.stringify(p.roles)}) at ${fn.gateway} `
      + `${fn.probePath} [${fn.name}] — ${v.why}`).toBe(decisionWord(want));
  });

/**
 * "What can THIS console do, and for whom" — the question an operator actually
 * asks. Asserting the EXACT admitted set means a new admission is a failure too:
 * a member appearing on the mod console is as much a defect as a moderator
 * losing it, and only an exact-set assertion catches the first kind.
 */
Then('the {string} governance console admits exactly the identities {string}',
  async ({}, consoleId: string, csv: string) => {
    const c = consoleName(consoleId);
    const fns = functionsForConsole(c);
    expect(fns.length, `console '${c}' has no catalogued functions, so this assertion is vacuous`)
      .toBeGreaterThan(0);
    const admitted = governancePersonas()
      .filter((p) => fns.some((f) => sqlDecision(f.gateway, f.probePath, p.roles).decision === 'ALLOW'))
      .map((p) => p.handle).sort();
    const want = csv.split(',').map((s) => s.trim()).filter(Boolean).sort();
    expect(admitted, `the '${c}' console (${fns.length} function(s): `
      + `${fns.map((f) => f.id).join(', ')}) admits a different identity set than declared`)
      .toEqual(want);
  });

/** A persona reaching NOTHING in a console — the strongest refusal shape, and
 *  the one a tier boundary is really made of. */
Then('the identity {string} reaches no {string} governance function at all',
  async ({}, handle: string, consoleId: string) => {
    const p = governancePersona(handle);
    const c = consoleName(consoleId);
    const fns = functionsForConsole(c);
    expect(fns.length, `console '${c}' has no catalogued functions`).toBeGreaterThan(0);
    const reached = fns
      .map((f) => ({ f, v: sqlDecision(f.gateway, f.probePath, p.roles) }))
      .filter((x) => x.v.decision === 'ALLOW')
      .map((x) => `${x.f.id} (${x.f.gateway} ${x.f.probePath}) — ${x.v.why}`);
    expect(reached, `${handle} (roles ${JSON.stringify(p.roles)}) reaches ${reached.length} of `
      + `${fns.length} '${c}' console functions and must reach none`).toEqual([]);
  });

/**
 * THE DOWN-CASCADE PROPERTY, stated over BARE role-sets rather than personas.
 * Personas cannot express "holding nothing but this role" — e2e-admin also
 * carries ROLE_USER — and the tier boundary is a claim about the ROLE.
 */
Then('no principal holding only {string} reaches any {string} governance function',
  async ({}, role: string, consoleId: string) => {
    const c = consoleName(consoleId);
    const fns = functionsForConsole(c);
    expect(fns.length, `console '${c}' has no catalogued functions`).toBeGreaterThan(0);
    const reached = fns
      .map((f) => ({ f, v: sqlDecision(f.gateway, f.probePath, [role]) }))
      .filter((x) => x.v.decision === 'ALLOW')
      .map((x) => `${x.f.id}: ${x.v.why}`);
    expect(reached, `a principal holding ONLY ${role} reaches ${reached.length} '${c}' console `
      + `function(s); the tier boundary says it must reach none`).toEqual([]);
  });

/** The reverse of the tier boundary: the tier's own role must reach the whole
 *  console, or "the tier exists" is only half true. */
Then('a principal holding only {string} reaches every {string} governance function',
  async ({}, role: string, consoleId: string) => {
    const c = consoleName(consoleId);
    const fns = functionsForConsole(c);
    expect(fns.length, `console '${c}' has no catalogued functions`).toBeGreaterThan(0);
    const refused = fns
      .map((f) => ({ f, v: sqlDecision(f.gateway, f.probePath, [role]) }))
      .filter((x) => x.v.decision === 'DENY')
      .map((x) => `${x.f.id}: ${x.v.why}`);
    expect(refused, `a principal holding ${role} is refused ${refused.length} of ${fns.length} `
      + `'${c}' console function(s)`).toEqual([]);
  });

// ═══════════════════════════════════════════════════════════════════════════
// C. THE SHAPE OF A DECISION — why, not just what
// ═══════════════════════════════════════════════════════════════════════════

/** An EXPLICIT allow=false row is a WALL: it denies even a principal that a
 *  broader row at the same pattern would admit. Asserting only "DENY" cannot
 *  tell a wall from an absent grant, and the two rot differently. */
Then('the {string} governance function is an explicit deny wall rather than an absent grant',
  async ({}, fnId: string) => {
    const fn = governanceFunction(fnId);
    const rows = sqlRouteRows().filter(
      (r) => r.gateway === fn.gateway && r.pattern === fn.governingPattern);
    expect(rows.length, `no row at ${fn.gateway} ${fn.governingPattern}`).toBeGreaterThan(0);
    expect(rows.every((r) => !r.allow),
      `${fn.governingPattern} carries allow=true row(s) for `
      + `${rows.filter((r) => r.allow).map((r) => r.role).join(',')} — it is a floor, not a wall`)
      .toBe(true);
    for (const p of governancePersonas()) {
      const v = sqlDecision(fn.gateway, fn.probePath, p.roles);
      expect(v.decision, `${p.handle} reached the walled ${fn.probePath}: ${v.why}`).toBe('DENY');
    }
  });

/** Ungoverned asserted as a property, not as a sample: the winning pattern must
 *  be NULL. A verdict produced by some over-broad glob quietly swallowing the
 *  path looks identical and is a completely different posture.
 *
 *  THE VERDICT IS NO_RULE, NOT DENY. It said DENY while the engine collapsed the
 *  two; the seed governs no /infra pattern, so the table refuses nothing here and
 *  the filter forwards to the coarse authenticated floor. Asserting DENY claimed
 *  a closed door the route-access table does not close. */
Then('the {string} governance function is governed by no route row at all',
  async ({}, fnId: string) => {
    const fn = governanceFunction(fnId);
    const v = sqlDecision(fn.gateway, fn.probePath, []);
    expect(v.pattern, `${fn.gateway} ${fn.probePath} is matched by '${v.pattern}' — the `
      + `ungoverned property this asserts is no longer what decides it`).toBeNull();
    for (const p of governancePersonas()) {
      const d = sqlDecision(fn.gateway, fn.probePath, p.roles);
      expect(d.decision, `${p.handle} was DECIDED at an ungoverned path: ${d.why}`)
        .toBe('NO_RULE');
    }
  });

/** Which url_pattern won — pinned, because most-specific-match is the part of
 *  this contract that changes shape without changing any single row. */
Then('the {string} governance function is decided by the route pattern {string}',
  async ({}, fnId: string, pattern: string) => {
    const fn = governanceFunction(fnId);
    const v = sqlDecision(fn.gateway, fn.probePath, []);
    expect(v.pattern, `${fn.gateway} ${fn.probePath}`).toBe(pattern);
  });

// ═══════════════════════════════════════════════════════════════════════════
// D. THE BROWSER DOOR FOR THE SUPERADMIN CONSOLE
// ═══════════════════════════════════════════════════════════════════════════
//
// ⚠ THIS BLOCK WAS A SKIP-GATE AND IS NOW AN ASSERTION. #244 has been answered
// ACCEPT, so the fe row exists and the POSTURE is a decided fact rather than a
// pending merge. What the old comment here said is also corrected below, because
// it was wrong in a way that made the decision look like an exposure question.
//
// WHAT WAS WRONG. The old text said "there is no browser path to any
// /bff/superadmin/** endpoint". There always was one: apps/20-gateway-fe.yaml
// routes Path=/bff/** to admin-bff, and a path with NO matching url_pattern is
// Decision.NO_RULE, which GatewayRouteAccessFilter FORWARDS (it rejects only on
// DENY). So a browser reached the superadmin BFF and was refused there, app-side,
// by pathMatchers("/bff/superadmin/**").hasRole("SUPERADMIN") — a bare 403 with
// NO X-Route-Denied header, which is the documented signature of an app-side
// refusal. The surface was ungoverned-and-forwarded, never default-denied.
//
// WHAT THE ROW CHANGED. For a non-privileged caller the refusal moved to the
// gateway: governed-but-ungranted at the longest match => DENY at the door, 403
// WITH X-Route-Denied, logged, and admin-bff never reached. For ROLE_ADMIN and
// ROLE_SUPERADMIN it changed nothing at all — both short-circuit in
// GatewayRouteAccessFilter BEFORE decide() runs, so no row on this gateway can
// alter what they reach. The real gain is that a governed row is something the
// D6/D8 privileged step-up floor can attach to; an ungoverned path returns false
// from isMfaRequiredSurface() and could not be MFA-gated at all.
//
// So:
//   * the INVARIANT — nothing but ROLE_SUPERADMIN is ever admitted at the
//     superadmin prefix, on ANY gateway — stays asserted unconditionally and
//     goes RED on the wrong fix (a ROLE_ADMIN down-cascade row);
//   * the POSTURE is no longer gated. The row's ABSENCE is now a FAILURE, not a
//     skip: a skip would let the decided row be deleted and take its own
//     coverage quietly with it.

/** The fe-gateway browser row for the superadmin console — #244 ACCEPT.
 *  ASSERTED, not skip-gated: this row is a decided posture, so losing it must
 *  turn the lane RED rather than turn this scenario off. */
Given('the fe-gateway carries a browser row for the superadmin console', async () => {
  const rows = sqlRouteRows().filter(
    (r) => r.gateway === 'hugmesh-fe-gateway' && r.pattern.startsWith('/bff/superadmin') && r.allow);
  expect(
    rows.map((r) => `${r.pattern} ${r.role}`).sort(),
    'the hugmesh-fe-gateway allow row(s) under /bff/superadmin. #244 was answered ACCEPT and '
    + 'the row lives in specs/cluster/manifests/route-access/initdb/20-schema.sql (and, '
    + 'generated from it, specs/rbac-route-access.seed.ts). With no row the prefix goes back '
    + 'to Decision.NO_RULE at this gateway — FORWARDED to admin-bff, refused app-side with no '
    + 'X-Route-Denied header, and with no surface for the privileged MFA floor to attach to.',
  ).toEqual(['/bff/superadmin/** ROLE_SUPERADMIN']);
});

/** The posture, once the row exists: superadmin in, everyone else out. */
Then('the fe-gateway browser door admits the superadmin tier and refuses every other identity',
  async ({ $testInfo }) => {
    const probe = '/bff/superadmin/service-store/catalog';
    const wrong: string[] = [];
    let admitted = 0;
    for (const p of governancePersonas()) {
      const v = decideWith(sqlRouteRows(), 'hugmesh-fe-gateway', probe, p.roles);
      const shouldAllow = p.roles.includes('ROLE_SUPERADMIN');
      if (shouldAllow) admitted++;
      if ((v.decision === 'ALLOW') !== shouldAllow) {
        wrong.push(`${p.handle} roles=[${p.roles.join(',')}] -> ${v.decision} (${v.why})`);
      }
    }
    await recordLedger($testInfo, 'superadmin-browser-door', { probe, admitted, wrong });
    expect(admitted, 'no catalogued identity holds ROLE_SUPERADMIN, so this proved nothing')
      .toBeGreaterThan(0);
    expect(wrong, `the fe-gateway browser door for ${probe} decides wrongly for `
      + `${wrong.length} identities`).toEqual([]);
  });

/** The invariant — asserted on EVERY gateway, on this tree and after the merge. */
Then('no gateway admits anything but the superadmin tier under the superadmin bff prefix',
  async ({ $testInfo }) => {
    const probes = [
      '/bff/superadmin/service-store/catalog',
      '/bff/superadmin/optional-services/state',
      '/bff/superadmin/fleet-entitlements/list',
      '/bff/superadmin/workloads/exec',
      '/bff/superadmin/games-services/catalog',
    ];
    const gateways = [...new Set(sqlRouteRows().map((r) => r.gateway))];
    const bleed: string[] = [];
    for (const g of gateways) for (const probe of probes) for (const p of governancePersonas()) {
      const v = decideWith(sqlRouteRows(), g, probe, p.roles);
      if (v.decision === 'ALLOW' && !p.roles.includes('ROLE_SUPERADMIN')) {
        bleed.push(`${g} ${probe} admits ${p.handle} (roles [${p.roles.join(',')}]) — ${v.why}`);
      }
    }
    await recordLedger($testInfo, 'superadmin-no-bleed', {
      gateways, probes, identities: governancePersonas().length, bleed,
    });
    expect(bleed, `the superadmin tier bled down to ${bleed.length} non-superadmin `
      + `identity/route pairs`).toEqual([]);
  });

// ═══════════════════════════════════════════════════════════════════════════
// E. THE DRIFT GUARD — the real deliverable
// ═══════════════════════════════════════════════════════════════════════════
//
// The scenarios above are the OUTPUT. These are the thing that keeps the output
// honest: a catalogued function, console or identity that no scenario reaches is
// a hole, and a hole that nothing reports is indistinguishable from coverage.

const FEATURE_DIR = path.resolve(__dirname, '..', 'features');

/** Every .feature line in the whole suite, COMMENTS STRIPPED. Counting a token
 *  that only ever appears in a comment is how this repo has produced five false
 *  green assertions; a `#` line is documentation, not coverage. */
function featureCorpus(): { files: string[]; text: string } {
  const files: string[] = [];
  const walk = (d: string) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) walk(f);
      else if (e.name.endsWith('.feature')) files.push(f);
    }
  };
  walk(FEATURE_DIR);
  const lines: string[] = [];
  for (const f of files) {
    for (const raw of fs.readFileSync(f, 'utf8').split('\n')) {
      const t = raw.trim();
      if (t.startsWith('#')) continue;
      lines.push(raw);
    }
  }
  return { files, text: lines.join('\n') };
}

/**
 * Is `needle` NAMED in the corpus — as a whole token, not as a substring?
 *
 * Both forms count: an Examples cell carries the value bare
 * (`| e2e-admin | ALLOW | user-approval |`) while the outline's step line carries
 * it quoted, and either one means a scenario reaches it.
 *
 * THE BOUNDARY IS LOAD-BEARING, and a plain `includes()` is a false green of
 * exactly the shape this guard exists to prevent: 'admin-workload-console' is a
 * substring of 'superadmin-workload-console', and 'e2e-admin' is a substring of
 * 'e2e-adminonly' and 'e2e-matrix' of 'e2e-matrix-domainlocked'. Under
 * `includes()` a file naming only the longer sibling would certify the shorter
 * one as covered.
 */
const ID_BOUNDARY = 'A-Za-z0-9_-';
const HANDLE_BOUNDARY = 'A-Za-z0-9_@.-';

function namedIn(corpus: string, needle: string, boundary: string): boolean {
  const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, (m) => '\\' + m);
  return new RegExp(`(?<![${boundary}])${escaped}(?![${boundary}])`).test(corpus);
}

Then('every catalogued governance function is named by a scenario', async ({ $testInfo }) => {
  const { files, text } = featureCorpus();
  const missing = GOVERNANCE_FUNCTIONS
    .filter((f) => !namedIn(text, f.id, ID_BOUNDARY))
    .map((f) => `${f.id} (${f.console}: ${f.name}) — ${f.gateway} ${f.probePath}`);
  await recordLedger($testInfo, 'drift-functions', {
    featureFiles: files.length, functions: GOVERNANCE_FUNCTIONS.length, missing,
  });
  expect(files.length, 'no .feature files were read, so this guard checked nothing')
    .toBeGreaterThan(10);
  expect(missing, `${missing.length} catalogued governance function(s) are reached by NO `
    + `scenario, so adding them to steps/governance.ts bought zero coverage. Either name each `
    + `one in a scenario (quoted, e.g. "allowlist-manage") or delete it from the catalogue — a `
    + `catalogue entry nothing executes reads as coverage and is not:\n  ${missing.join('\n  ')}`)
    .toEqual([]);
});

Then('every catalogued governance identity is named by a scenario', async ({ $testInfo }) => {
  const { files, text } = featureCorpus();
  const missing = governancePersonas()
    .filter((p) => !namedIn(text, p.handle, HANDLE_BOUNDARY))
    .map((p) => `${p.handle} (roles [${p.roles.join(',')}], ${p.origin})`);
  await recordLedger($testInfo, 'drift-identities', {
    featureFiles: files.length, identities: governancePersonas().length, missing,
  });
  expect(files.length, 'no .feature files were read').toBeGreaterThan(10);
  expect(missing, `${missing.length} seeded identity/identities appear in NO scenario in the `
    + `whole suite. A persona the seeders create and nothing tests is an unasserted principal `
    + `on a live mesh:\n  ${missing.join('\n  ')}`).toEqual([]);
});

/** A console where every identity is admitted, or none is, asserts nothing about
 *  gating. Both halves must be non-empty or the console's rows are decoration. */
Then('every governance console has both an admitted and a refused identity', async ({ $testInfo }) => {
  const report: Record<string, { functions: number; admitted: number; refused: number }> = {};
  const problems: string[] = [];
  for (const c of GOVERNANCE_CONSOLES) {
    const fns = functionsForConsole(c);
    if (fns.length === 0) { problems.push(`console '${c}' has no catalogued functions`); continue; }
    const admitted = governancePersonas().filter(
      (p) => fns.some((f) => sqlDecision(f.gateway, f.probePath, p.roles).decision === 'ALLOW'));
    const refused = governancePersonas().filter(
      (p) => fns.every((f) => sqlDecision(f.gateway, f.probePath, p.roles).decision === 'DENY'));
    report[c] = { functions: fns.length, admitted: admitted.length, refused: refused.length };
    // TWO DELIBERATE EXCEPTIONS, each asserted as its OWN degenerate shape
    // rather than exempted. Skipping them would leave two consoles unchecked;
    // inverting the assertion checks the thing that is actually true of them.
    //
    // 'gateway' holds a WALL and an UNROUTED path, so NOBODY may be admitted.
    if (c === 'gateway') {
      if (admitted.length !== 0) {
        problems.push(`console 'gateway' holds only walls and unrouted paths, yet `
          + `${admitted.length} identity/identities are admitted`);
      }
      continue;
    }
    // 'login' is the PUBLIC front door, so EVERYBODY must be admitted — the
    // banned and the un-onboarded included, because the gate is what happens
    // after the door, not at it. A refused identity here is the defect.
    if (c === 'login') {
      if (refused.length !== 0) {
        problems.push(`console 'login' is the public door yet refuses `
          + `${refused.map((p) => p.handle).join(', ')}`);
      }
      if (admitted.length !== governancePersonas().length) {
        problems.push(`console 'login' admits ${admitted.length} of `
          + `${governancePersonas().length} identities; the public door must admit all`);
      }
      continue;
    }
    if (admitted.length === 0) problems.push(`console '${c}' admits NOBODY — its refusals are vacuous`);
    if (refused.length === 0) problems.push(`console '${c}' refuses NOBODY — it gates nothing`);
  }
  await recordLedger($testInfo, 'drift-consoles', { report, problems });
  expect(problems, `governance console coverage is degenerate:\n  ${problems.join('\n  ')}`)
    .toEqual([]);
});

// ── the persona catalogue's own integrity ───────────────────────────────────

Then('both seeders agree about every identity they both create', async ({ $testInfo }) => {
  const problems = personaCatalogueProblems();
  await recordLedger($testInfo, 'persona-agreement', {
    identities: governancePersonas().length,
    shared: governancePersonas().filter((p) => p.origin === 'both').map((p) => p.handle),
    problems,
  });
  expect(problems, `the TypeScript catalogue and the shell roster disagree:\n  `
    + `${problems.join('\n  ')}`).toEqual([]);
});

/** The swarm is 126 identities represented by 3. That shortcut is only honest if
 *  each of the 123 excluded members really does hold its representative's roles. */
Then('every swarm identity is represented in the governance matrix', async ({ $testInfo }) => {
  const uncovered = swarmMembersNotCoveredByRepresentative();
  const reps = swarmRepresentatives();
  await recordLedger($testInfo, 'swarm-representation', { representatives: reps, uncovered });
  expect(reps.length, 'the swarm generator produced no tiers, so this checked nothing')
    .toBeGreaterThan(0);
  expect(uncovered, `${uncovered.length} swarm identity/identities are NOT represented by their `
    + `tier representative, so excluding them from the matrix drops real coverage:\n  `
    + `${uncovered.slice(0, 10).join('\n  ')}`).toEqual([]);
});
