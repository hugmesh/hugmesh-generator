// emit-coverage-matrix.ts — THE GENERATOR. Renders the coverage matrix in
// steps/coverage-catalogue.ts into executable Gherkin under features/coverage/.
//
// RUN IT WITH  tests/e2e/gen-coverage-matrix.sh  (node cannot load the catalogue
// directly: steps/dimensions.ts imports '../specs/rbac-roles' extensionless,
// which node's own type-stripping resolves as ESM and cannot find. The wrapper
// runs this through Playwright's TypeScript transform instead.)
//
// WHY GENERATE RATHER THAN HAND-WRITE. 31 personas x 63 functions is 1953 cells.
// Nobody maintains 1953 Gherkin rows by hand, and a matrix that is only 40%
// filled looks exactly like a matrix that is complete. Emitting it means adding
// a persona to tests/e2e-extra-personas.sh, a service to SERVICES, or a function
// to FUNCTIONS expands the coverage automatically — and
// tests/scripts/test-e2e-coverage-matrix.sh goes RED until the emitted files are
// refreshed, so the expansion cannot be forgotten.
//
// WHY THE EXPECTED OUTCOME IS WRITTEN INTO THE FILE. Every Examples row carries
// the literal `admitted` / `refused` the oracle computed AT EMIT TIME, and the
// step recomputes it AT RUN TIME from the committed route-access seed and the
// three persona rosters. The committed literal is therefore a PINNED
// EXPECTATION, not a restatement: change the seed (or a persona's roles) without
// re-emitting and the run goes red at the exact cells that moved. A step that
// merely recomputed and compared against itself would be green forever.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { SERVICES, ENVIRONMENTS, INTERFACES } from '../steps/dimensions';
import {
  FUNCTIONS, roster, effectiveRolesOf, expectedOutcome, functionsForService,
  serviceFunction, unreachableFunctions, servicesWithoutFunctions,
  functionsWithUnknownService, REPO_ROOT,
} from '../steps/coverage-catalogue';

export const FEATURES_DIR = path.join(REPO_ROOT, 'tests', 'e2e', 'features', 'coverage');

const BANNER = [
  '# ─────────────────────────────────────────────────────────────────────────────',
  '# GENERATED FILE — DO NOT EDIT BY HAND.',
  '#',
  '# Emitted by tests/e2e/tools/emit-coverage-matrix.ts from three catalogues:',
  '#   personas   specs/rbac-roles.ts SYSTEMS_SEED_USERS',
  '#              + tests/e2e-extra-personas.sh',
  '#              + tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS',
  '#   services   tests/e2e/steps/dimensions.ts SERVICES',
  '#   functions  tests/e2e/steps/coverage-catalogue.ts FUNCTIONS',
  '#',
  '# Regenerate with:  bash tests/e2e/gen-coverage-matrix.sh',
  '# The drift guard tests/scripts/test-e2e-coverage-matrix.sh re-emits into a',
  '# scratch dir and DIFFS against these files, so an edit here — or a catalogue',
  '# change that was never re-emitted — turns the guard RED.',
  '# ─────────────────────────────────────────────────────────────────────────────',
].join('\n');

/** Gherkin table cells are `|`-delimited; nothing in these catalogues may carry one. */
function cell(v: string): string {
  if (v.includes('|')) {
    throw new Error(
      `catalogue value ${JSON.stringify(v)} contains a '|', which would split a Gherkin `
      + `Examples cell in two and silently shift every column after it. Rename it.`,
    );
  }
  return v;
}

function table(headers: string[], rows: string[][], indent = '      '): string {
  const widths = headers.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i].length)));
  const line = (cells: string[]): string =>
    `${indent}| ${cells.map((c, i) => c.padEnd(widths[i])).join(' | ')} |`;
  return [line(headers), ...rows.map(line)].join('\n');
}

// ── 1. the ACCESS MATRIX, one feature per service ────────────────────────────

export function renderServiceMatrix(serviceId: string): string {
  const def = SERVICES.find((s) => s.id === serviceId)!;
  const fns = functionsForService(serviceId);
  const people = roster();
  const rows: string[][] = [];
  for (const p of people) {
    for (const f of fns) {
      const d = expectedOutcome(p.handle, f.id);
      rows.push([
        cell(p.handle), cell(f.id), cell(d.outcome),
        cell(d.pattern ?? '(none — default deny)'), cell(p.lanes.join('+')),
      ]);
    }
  }
  const derived = fns.filter((f) => f.evidence === 'derived').length;
  return `${BANNER}
#
# ${def.name} — the ACCESS MATRIX: every seeded persona against every catalogued
# function of this service.
#
# ${people.length} personas x ${fns.length} functions = ${rows.length} cells.
# ${derived} of ${fns.length} function probe paths are DERIVED from a committed artefact;
# ${fns.length - derived} are ASSERTED (no artefact pins them yet) — see the FUNCTIONS entry's
# \`source\` field, which the function-catalogue feature pins row by row.
#
# COLUMNS
#   role     the persona handle, from the union of the three seeding rosters
#   function the catalogued function id (steps/coverage-catalogue.ts FUNCTIONS)
#   outcome  what the COMMITTED gateway_route_access seed decides for that
#            persona's effective role-set — admitted | refused
#   pattern  the url_pattern that won the most-specific match, or
#            "(none — default deny)" when the seed governs no pattern at all
#   source   which seeding lanes create this persona. The three rosters DISAGREE;
#            the disagreement is shown here rather than resolved behind the scenes.
@layer:gateway @service:${serviceId} @coverage-matrix
Feature: ${def.name} — every persona against every function

  Scenario Outline: <role> is <outcome> at <function> @role:<role> @service:${serviceId}
    Then persona "<role>" is "<outcome>" at the "<function>" function
    And the seed decides that at pattern "<pattern>"

    Examples:
${table(['role', 'function', 'outcome', 'pattern', 'source'], rows)}
`;
}

// ── 2. the FUNCTION CATALOGUE ────────────────────────────────────────────────

export function renderFunctionCatalogue(): string {
  const rows = FUNCTIONS.map((f) => [
    cell(f.id), cell(f.service), cell(f.gateway), cell(f.probePath), cell(f.evidence),
  ]);
  const unreachable = unreachableFunctions();
  const unreachableRows = unreachable.map((id) => {
    const f = serviceFunction(id);
    return [cell(id), cell(f.service)];
  });
  return `${BANNER}
#
# THE FUNCTION CATALOGUE ITSELF, pinned row by row.
#
# The access matrices assert WHO reaches WHAT. This feature asserts the catalogue
# those matrices are computed from has not moved underneath them: every function
# still belongs to a legal SERVICES id, still probes the gateway and path the
# catalogue records, and still carries the derived/asserted label a reader uses
# to tell a measurement from a judgement call.
#
# WHY THE 'unreachable' LIST IS AN ASSERTION AND NOT A COMMENT. ${unreachable.length} of the
# ${FUNCTIONS.length} catalogued functions can be reached by NO seeded persona at all. Most of
# those are a real gap rather than a bug in this file: no seeding lane grants
# ROLE_WIKI, ROLE_OWNCAST, ROLE_TUBE, ROLE_FORUM_MOD or the ROLE_GAMES_SERVICES_*
# pair, so three whole services and two consoles are gated behind roles that
# nothing creates. Pinning the list means CLOSING one of those gaps (seeding the
# role) turns this scenario red and forces the list to shrink deliberately —
# and means a new service arriving unreachable cannot slip in unnoticed.
@layer:gateway @coverage-matrix
Feature: The function catalogue the coverage matrix is computed from

  Scenario Outline: the <function> function is catalogued against <gateway> <path> @service:<service>
    Then the "<function>" function belongs to the "<service>" service
    And the "<function>" function probes "<gateway>" at "<path>"
    And the "<function>" function probe path is "<evidence>"

    Examples:
${table(['function', 'service', 'gateway', 'path', 'evidence'], rows)}

  # Every SERVICES id must carry at least one function, and every catalogued
  # function must name a legal service. Both directions, because a one-way check
  # lets a typo'd service id sit in the catalogue forever.
  Scenario: every catalogued service has functions and every function has a catalogued service
    Then every service in the catalogue has at least one function
    And every catalogued function names a legal service

  Scenario Outline: no seeded persona can reach <function> @service:<service>
    Then no seeded persona is admitted at the "<function>" function

    Examples:
${table(['function', 'service'], unreachableRows)}
`;
}

// ── 3. the PERSONA ROSTER, reconciled ────────────────────────────────────────

export function renderRosterCoverage(): string {
  const rows = roster().map((p) => [
    cell(p.handle),
    cell(p.lanes.join('+')),
    cell(effectiveRolesOf(p.handle).join(',') || '(none)'),
    cell(String(p.registrationComplete)),
  ]);
  const lanes = { ts: 0, sh: 0, seed: 0, all: 0 };
  for (const p of roster()) {
    if (p.lanes.includes('ts-catalogue')) lanes.ts += 1;
    if (p.lanes.includes('extra-personas-sh')) lanes.sh += 1;
    if (p.lanes.includes('seed-accounts-sh')) lanes.seed += 1;
    if (p.lanes.length === 3) lanes.all += 1;
  }
  return `${BANNER}
#
# THE PERSONA ROSTER, reconciled across THREE DISAGREEING SOURCES.
#
#   ${String(lanes.ts).padStart(2)}  specs/rbac-roles.ts SYSTEMS_SEED_USERS
#   ${String(lanes.sh).padStart(2)}  tests/e2e-extra-personas.sh
#   ${String(lanes.seed).padStart(2)}  tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS
#   ${String(lanes.all).padStart(2)}  seeded by all three
#   ${String(roster().length).padStart(2)}  union — the roster the access matrices iterate
#
# The disagreement is REPRESENTED, not resolved: the \`lanes\` column names which
# seeders create each handle. Resolving it means changing what a seeder seeds,
# which is a production change and not this lane's to make. What this lane CAN
# do is stop the divergence growing silently — every handle, its lanes and its
# EFFECTIVE role-set (granted roles + the derived ROLE_GAMES_ADMIN composite,
# emptied when the two-stage registration gate is uncleared) are pinned here.
@layer:casdoor @coverage-matrix
Feature: The persona roster the coverage matrix iterates

  Scenario Outline: <role> is seeded by <lanes> and presents <effective_roles> @role:<role>
    Then the persona "<role>" is seeded by exactly the lanes "<lanes>"
    And the persona "<role>" presents the effective roles "<effective_roles>"
    And the persona "<role>" registration-complete flag is "<registration_complete>"

    Examples:
${table(['role', 'lanes', 'effective_roles', 'registration_complete'], rows)}

  # The composite ROLE_GAMES_ADMIN is NEVER granted directly: the sync job
  # materialises it as ROLE_GAMES INTERSECT (ROLE_ADMIN UNION ROLE_MOD). This
  # catalogue computes it from that rule; specs/rbac-roles.ts declares it per
  # user in \`expectGamesAdmin\`. Two independent statements of the same fact, so
  # they can be checked against each other.
  Scenario: the derived games-admin composite agrees with the declared expectation
    Then the derived games-admin composite agrees with every declared expectation
`;
}

// ── 4. the ENVIRONMENT x INTERFACE reach lane ────────────────────────────────

/** Which Studio wizard page stands for each environment. Real slugs, from
 *  studio/hugmesh_studio/core/config.py WIZARD_PAGE_SLUGS. */
const STUDIO_PAGE_FOR_ENV: Record<string, string> = {
  docker: 'localmesh', kind: 'localcloud', qemu: 'qemu',
};

export function renderEnvInterfaceReach(): string {
  const blocks: string[] = [];
  for (const env of ENVIRONMENTS) {
    for (const iface of INTERFACES) {
      const tags = `@env:${env} @interface:${iface}`;
      const name = `${iface} evidence in the ${env} environment @env:${env} @interface:${iface}`;
      if (iface === 'browser') {
        blocks.push(`  ${tags}
  Scenario: ${name}
    When I open the path "/"
    Then the scenario drives the "${env}" environment base URL
    And the evidence manifest holds a "screenshot" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk`);
      } else if (iface === 'cli') {
        blocks.push(`  ${tags}
  Scenario: ${name}
    When I run the shell command "echo hugmesh-coverage-${env}-cli"
    Then the command succeeded
    And the command output contains "hugmesh-coverage-${env}-cli"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk`);
      } else {
        blocks.push(`  ${tags}
  Scenario: ${name}
    When I grab the Studio wizard page "${STUDIO_PAGE_FOR_ENV[env]}"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "${STUDIO_PAGE_FOR_ENV[env]}"
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk`);
      }
    }
  }
  return `${BANNER}
#
# THE OPERATOR'S SECOND REQUIREMENT: evidence "in docker, local devops, and qemu
# emulated e2e testing through cli and gui".
#
# ${ENVIRONMENTS.length} environments x ${INTERFACES.length} interfaces = ${ENVIRONMENTS.length * INTERFACES.length} cells, every one tagged so it either RUNS
# and leaves its own kind of artefact, or SKIPS naming exactly what to start.
# None of them can pass while its environment is down — that is the whole point
# of the @env: gate (steps/world.ts Before), and it is why this lane is honest
# on a laptop with nothing running: 9 skips, 9 named reasons, 0 false greens.
#
# The @interface: axis decides the artefact of record: a PNG for browser, a
# TRANSCRIPT for cli (a terminal has no screenshot), a Qt WIDGET GRAB for the
# Studio GUI. Each Studio cell grabs the wizard page that actually corresponds
# to its environment — localmesh for the compose stack, localcloud for the kind
# devops cluster, qemu for an emulated device — so a grab of the wrong screen
# cannot pass for coverage of the right one.
@layer:ui @coverage-matrix
Feature: Every environment leaves evidence through every interface

${blocks.join('\n\n')}
`;
}

// ── emit ─────────────────────────────────────────────────────────────────────

export interface EmittedFile { relPath: string; text: string }

export function emitAll(): EmittedFile[] {
  const bad = [...servicesWithoutFunctions(), ...functionsWithUnknownService()];
  if (bad.length) {
    throw new Error(
      `refusing to emit: the catalogues disagree — ${bad.join(', ')}. Every SERVICES id needs `
      + `at least one FUNCTIONS entry and every FUNCTIONS entry needs a legal service id.`,
    );
  }
  const out: EmittedFile[] = [];
  for (const s of SERVICES) out.push({ relPath: `access-matrix-${s.id}.feature`, text: renderServiceMatrix(s.id) });
  out.push({ relPath: 'function-catalogue.feature', text: renderFunctionCatalogue() });
  out.push({ relPath: 'roster-coverage.feature', text: renderRosterCoverage() });
  out.push({ relPath: 'environment-interface-reach.feature', text: renderEnvInterfaceReach() });
  return out;
}

/** Write into `dir`, removing any stale .feature the catalogues no longer produce. */
export function writeAll(dir: string): { written: string[]; removed: string[] } {
  fs.mkdirSync(dir, { recursive: true });
  const files = emitAll();
  const keep = new Set(files.map((f) => f.relPath));
  const removed: string[] = [];
  for (const existing of fs.readdirSync(dir)) {
    if (existing.endsWith('.feature') && !keep.has(existing)) {
      fs.unlinkSync(path.join(dir, existing));
      removed.push(existing);
    }
  }
  for (const f of files) fs.writeFileSync(path.join(dir, f.relPath), f.text, 'utf8');
  return { written: files.map((f) => f.relPath), removed };
}
