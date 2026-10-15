// brand-record.steps.ts — the brand record driven through the Studio's Qt-free
// command line in a fresh process (hugmesh-generator#654: C-RECORD, C-PROFILE).
//
// Every step runs `python3 -m hugmesh_studio.core.<module> <verb> --record FILE`
// with cwd studio/, exactly as the Makefile and the text screens do; the record is
// written by the step into a scratch folder (never the Studio state folder, never
// the shared brands/ checkout). The transcript lands in world['cli.transcript'], the
// slot common.steps.ts uses, so `the command succeeded`, `the command failed` and
// `the command output contains` are REUSED as-is. Every step text below starts with
// "a scratch brand record", "I show the brand record", "I print the Docker mesh plan",
// "I ask the Docker mesh plan",
// "I write the builder profile", "the record output", "every look value", "every term",
// "for brand", "the generated profile", "no builder profile", "the builder harness" or
// "the plan says", and was grepped across steps/ before it was written.
//
// The words the assertions compare against come from docs/BRAND-MODEL.md (its
// "## The seven words" table) — read at run time, never copied here, so the
// scenario goes red the day the document and the screens drift apart.
//
// NOTHING HERE STARTS A MESH, a cluster or a builder.

import { expect } from '@playwright/test';
import { Given, When, Then } from './world';
import { runCli, REPO_ROOT, scratchDir } from './runners';
import { CliTranscript } from './evidence';
import { studioPython } from './dimensions';
import * as fs from 'node:fs';
import * as path from 'node:path';

const CLI_KEY = 'cli.transcript';     // shared with common.steps.ts, on purpose
const REC_KEY = 'brand.record';       // the record file this scenario wrote
const PROF_KEY = 'brand.profile';     // where the profile verb was told to write
const SENTINEL_KEY = 'brand.sentinel';

const STUDIO = path.join(REPO_ROOT, 'studio');
const DOC = path.join(REPO_ROOT, 'docs', 'BRAND-MODEL.md');

/** The words a brand screen never shows (docs/BRAND-MODEL.md, D1). */
const FORBIDDEN = ['tenant', 'issuer', 'slug', 'epoch', 'generation', 'residency', 'capability'];
const SOURCES = ["this brand's own", 'inherited from the superbrand'];

function fresh(): string {
  fs.mkdirSync(scratchDir(), { recursive: true });
  return fs.mkdtempSync(path.join(scratchDir(), 'brand-record-'));
}

function writeRecord(world: { set(k: string, v: unknown): void }, record: unknown): string {
  const dir = fresh();
  const file = path.join(dir, 'brand-record.json');
  fs.writeFileSync(file, JSON.stringify(record, null, 2) + '\n');
  world.set(REC_KEY, file);
  world.set(PROF_KEY, path.join(dir, 'brand.profile'));
  world.set(SENTINEL_KEY, path.join(dir, 'sentinel'));
  return file;
}

function acmeRecord(title: string, tor = true) {
  return {
    schema: 1,
    superbrand: {
      id: 'acme', title, org: 'example', public_name: 'mesh.example',
      internal_root: 'acme.internal',
      look: { primary: '#112233', font: 'System UI' },
      // the superbrand's Tor way: the record, not a command-line flag, is what turns
      // Tor on for the Docker plan below (D10)
      ways: { tor },
    },
    brands: [
      { name: 'shop.mesh.example', title: 'Shop', idp: 'own', tor: true,
        look: { primary: '#aa0000' }, images: [], optional_services: [] },
      { name: 'blog.mesh.example', title: 'Blog', idp: 'superdomain',
        images: [], optional_services: [] },
    ],
  };
}

function studio(world: { set(k: string, v: unknown): void }, module: string, args: string[]): CliTranscript {
  const t = runCli([studioPython(), '-m', `hugmesh_studio.core.${module}`, ...args],
    { cwd: STUDIO, env: { QT_QPA_PLATFORM: 'offscreen' } });
  world.set(CLI_KEY, t);
  return t;
}

/** The (term, meaning) rows of the document's "## The seven words" table. */
function documentWords(): Array<{ term: string; meaning: string }> {
  const doc = fs.readFileSync(DOC, 'utf8');
  const m = /^## The seven words\n([\s\S]*?)(?=^## )/m.exec(doc);
  expect(m, `${DOC} has no "## The seven words" section`).not.toBeNull();
  const rows: Array<{ term: string; meaning: string }> = [];
  for (const line of m![1].split('\n')) {
    if (!line.startsWith('|') || /^\|[-| ]+\|$/.test(line.trim())) continue;
    const cells = line.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
    if (cells[0] === 'Word') continue;
    rows.push({ term: cells[0], meaning: cells[1] });
  }
  expect(rows.length, 'the document lists seven words').toBe(7);
  return rows;
}

function out(world: { get<T>(k: string): T }): string {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.stdout.trim().length, `the command printed nothing:\n${t.stderr}`).toBeGreaterThan(0);
  return t.stdout;
}

/** The block of the printed record that belongs to one brand. */
function brandBlock(text: string, brandId: string): string {
  const start = text.indexOf(`brand ${brandId}:`);
  expect(start, `no "brand ${brandId}:" line in:\n${text}`).toBeGreaterThanOrEqual(0);
  const rest = text.slice(start + 1);
  const next = rest.search(/\nbrand [a-z0-9-]+:|\nWhat the one superbrand block drives:/);
  return next < 0 ? rest : rest.slice(0, next);
}

// ── Given ──────────────────────────────────────────────────────────────────────

Given('a scratch brand record {string} with a superbrand and the brands {string} and {string}',
  async ({ world }, superbrand: string, a: string, b: string) => {
    expect(superbrand).toBe('acme');
    expect([a, b]).toEqual(['shop', 'blog']);
    writeRecord(world, acmeRecord('Acme Mesh'));
  });

Given('a scratch brand record {string} whose superbrand has no Tor address',
  async ({ world }, superbrand: string) => {
    expect(superbrand).toBe('acme');
    writeRecord(world, acmeRecord('Acme Mesh', false));
  });

Given('a scratch brand record whose superbrand title is a command that would create a sentinel file',
  async ({ world }) => {
    const dir = fresh();
    const sentinel = path.join(dir, 'sentinel');
    const file = path.join(dir, 'brand-record.json');
    // Written directly, bypassing the Studio's save (which would refuse it): the
    // point is what the PROFILE writer does with a record that got in anyway.
    fs.writeFileSync(file, JSON.stringify(acmeRecord(`$(touch ${sentinel})`), null, 2) + '\n');
    world.set(REC_KEY, file);
    world.set(PROF_KEY, path.join(dir, 'brand.profile'));
    world.set(SENTINEL_KEY, sentinel);
  });

Given('a scratch brand record whose brands both carry the reserved id {string}',
  async ({ world }, reserved: string) => {
    expect(reserved).toBe('default');
    // Written directly, bypassing the Studio's save (which refuses a reserved id):
    // `validate` and `up` refuse this record, and the profile verb must too.
    const rec = acmeRecord('Acme Mesh');
    for (const b of rec.brands) (b as { id?: string }).id = reserved;
    writeRecord(world, rec);
  });

// ── When ───────────────────────────────────────────────────────────────────────

/** The own sign-ins the two-port scenarios name, in the order they are given. */
const OWN_SIGN_INS = ['zed.mesh.example', 'alpha.mesh.example'];
const PLAN_KEY = 'brand.plan.transcript';

When('I show the brand record and print the Docker mesh plan from two own sign-ins named in reverse alphabetical order in fresh Studio processes',
  async ({ world }) => {
    // no record file: both verbs read the same flags, and the running mesh
    // (local_stack_node) publishes each sign-in on a port by its position here
    const flags = ['--brand', 'acme', '--cluster-domain', 'mesh.example', '--generator-dir', REPO_ROOT];
    for (const name of OWN_SIGN_INS) flags.push('--own-casdoor-domain', name);
    const plan = runCli([studioPython(), '-m', 'hugmesh_studio.core.local_mesh_bootstrap', 'plan', ...flags],
      { cwd: STUDIO, env: { QT_QPA_PLATFORM: 'offscreen' } });
    world.set(PLAN_KEY, plan);
    studio(world, 'local_mesh_bootstrap', ['show-record', ...flags]);
  });

When('I print the Docker mesh plan for a production mesh from the brand record in a fresh Studio process', async ({ world }) => {
  // production, Tor on from the record: the plan must say what happens to the Tor
  // address at start — held, or not held because the Makefile has no hold yet
  studio(world, 'local_mesh_bootstrap', ['plan', '--record', world.get<string>(REC_KEY),
    '--env', 'prod', '--generator-dir', REPO_ROOT]);
});

When('I show the brand record in a fresh Studio process', async ({ world }) => {
  studio(world, 'local_mesh_bootstrap', ['show-record', '--record', world.get<string>(REC_KEY),
    '--generator-dir', REPO_ROOT]);
});

When('I print the Docker mesh plan from the brand record in a fresh Studio process', async ({ world }) => {
  // no --with-tor here on purpose: the record's superbrand way is what the plan reads
  studio(world, 'local_mesh_bootstrap', ['plan', '--record', world.get<string>(REC_KEY),
    '--generator-dir', REPO_ROOT]);
});

When('I ask the Docker mesh plan for Tor on the command line against the brand record', async ({ world }) => {
  studio(world, 'local_mesh_bootstrap', ['plan', '--record', world.get<string>(REC_KEY),
    '--with-tor', '--generator-dir', REPO_ROOT]);
});

When('I ask the Docker mesh plan for the brand {string} on the command line against the brand record',
  async ({ world }, brand: string) => {
    studio(world, 'local_mesh_bootstrap', ['plan', '--record', world.get<string>(REC_KEY),
      '--brand', brand, '--generator-dir', REPO_ROOT]);
  });

When('I ask the Docker mesh plan for the own sign-in {string} on the command line against the brand record',
  async ({ world }, name: string) => {
    studio(world, 'local_mesh_bootstrap', ['plan', '--record', world.get<string>(REC_KEY),
      '--own-casdoor-domain', name, '--generator-dir', REPO_ROOT]);
  });

When('I write the builder profile from the brand record in a fresh Studio process', async ({ world }) => {
  studio(world, 'brand_model', ['profile', '--record', world.get<string>(REC_KEY),
    '--out', world.get<string>(PROF_KEY)]);
});

// ── Then: the printed record ───────────────────────────────────────────────────

Then('the record output lists the superbrand {string} and the brands {string} and {string}',
  async ({ world }, sb: string, a: string, b: string) => {
    const text = out(world);
    expect(text).toContain(`superbrand: ${sb}`);
    expect(text).toContain(`brand ${a}:`);
    expect(text).toContain(`brand ${b}:`);
  });

Then('the record output says the look value {string} of brand {string} is {string} and {string}',
  async ({ world }, key: string, brandId: string, value: string, source: string) => {
    const block = brandBlock(out(world), brandId);
    const line = block.split('\n').find((l) => l.trim().startsWith(`${key} `));
    expect(line, `no look line for ${key} in:\n${block}`).toBeDefined();
    expect(line!).toContain(value);
    expect(line!.split('—').pop()!.trim()).toBe(source);
  });

Then('every look value printed for a brand carries one of the model\'s two sources', async ({ world }) => {
  const text = out(world);
  const blocks = text.split(/\nbrand [a-z0-9-]+:/).slice(1);
  expect(blocks.length).toBeGreaterThan(0);
  for (const block of blocks) {
    const lookPart = block.split('ways to reach it:')[0];
    const lines = lookPart.split('\n').filter((l) => /^ {4}\S/.test(l) && l.includes('—'));
    expect(lines.length, `no look lines in:\n${block}`).toBeGreaterThanOrEqual(8);
    for (const l of lines) {
      expect(SOURCES, `source of "${l.trim()}"`).toContain(l.split('—').pop()!.trim());
    }
  }
});

Then('for brand {string} the record output gives the {string} an effect on the {string}, the {string} and the {string}',
  async ({ world }, brandId: string, way: string, p1: string, p2: string, p3: string) => {
    const block = brandBlock(out(world), brandId);
    const start = block.indexOf(`    ${way}:`);
    expect(start, `no way "${way}" in:\n${block}`).toBeGreaterThanOrEqual(0);
    const rest = block.slice(start + 1);
    const next = rest.search(/\n {4}\S/);
    const wayBlock = next < 0 ? rest : rest.slice(0, next);
    for (const p of [p1, p2, p3]) {
      const line = wayBlock.split('\n').find((l) => l.trim().startsWith(p));
      expect(line, `no effect for "${way}" on the ${p} in:\n${wayBlock}`).toBeDefined();
      expect(line!.trim().slice(p.length).trim().length,
        `the ${p} effect of "${way}" is empty`).toBeGreaterThan(10);
    }
  });

Then('every term the record output uses is a word of the model document', async ({ world }) => {
  const text = out(world);
  const words = documentWords();
  const terms = new Set(words.map((w) => w.term));
  // the printed record names these terms as labels; each must be a word of the table
  for (const label of ['superbrand', 'brand', 'sign-in', 'internal root name']) {
    expect(terms, `"${label}" is not in the document's table`).toContain(label);
    expect(text, `the record never says "${label}"`).toContain(label);
  }
  // and the ways it lists are the ones the table's "ways to reach a brand" row means
  const ways = words.find((w) => w.term === 'ways to reach a brand')!.meaning;
  for (const w of ['internal name', 'Tor address', 'public name through a provider']) {
    expect(ways).toContain(w.replace('Tor address', 'a Tor address').replace('internal name', 'an internal name')
      .replace('public name through a provider', 'a public name through a provider'));
    expect(text).toContain(`${w}:`);
  }
});

Then('the record output uses no word the brand screens forbid', async ({ world }) => {
  const text = out(world).toLowerCase();
  for (const w of FORBIDDEN) {
    expect(text, `the record says "${w}"`).not.toMatch(new RegExp(`\\b${w}\\b`));
  }
});

Then('the record output and the plan give the same sign-in port to each own sign-in, {int} then {int}',
  async ({ world }, first: number, second: number) => {
    const plan = world.get<CliTranscript>(PLAN_KEY);
    expect(plan.exitCode, `plan: ${plan.stderr}`).toBe(0);
    const record = out(world);
    const want = [first, second];
    OWN_SIGN_INS.forEach((name, i) => {
      const planLine = plan.stdout.split('\n').find((l) => l.includes(`* ${name}: host port `));
      expect(planLine, `no port line for ${name} in the plan:\n${plan.stdout}`).toBeDefined();
      expect(planLine!).toContain(`* ${name}: host port ${want[i]},`);
      const block = brandBlock(record, name.replace(/\./g, '-'));
      expect(block, `the record's port for ${name}`).toContain(`sign-in port ${want[i]} on the Docker mesh`);
    });
  });

// ── Then: the production hold, measured against the Makefile ───────────────────

Then('the plan says the Tor address is held until Go live exactly when the Makefile reads TOR_HOLD', async ({ world }) => {
  // the Makefile is the authority: a word-match on the knob (the Studio's own
  // makefile_holds_tor does the same), so this scenario flips the day the hold lands
  const makefile = fs.readFileSync(path.join(REPO_ROOT, 'Makefile'), 'utf8');
  const readsKnob = /\bTOR_HOLD\b/.test(makefile);
  const text = out(world);
  if (readsKnob) {
    expect(text).toContain('HELD: a production mesh starts no Tor address until Go live (TOR_HOLD=1');
    expect(text).toContain('It is HELD until Go live (a production mesh).');
    expect(text).not.toContain('NOT HELD YET');
  } else {
    expect(text).toContain('NOT HELD YET: this production mesh publishes its Tor address at start');
    expect(text).toContain('does not read TOR_HOLD');
    expect(text).toContain('It starts with this mesh (a production mesh; the hold is not built yet).');
    expect(text).not.toContain('HELD:');
  }
});

// ── Then: the generated profile and the builder harness ────────────────────────

Then('the generated profile sets {string} to {string}', async ({ world }, key: string, value: string) => {
  const prof = world.get<string>(PROF_KEY);
  expect(fs.existsSync(prof), `no profile at ${prof}`).toBe(true);
  const lines = fs.readFileSync(prof, 'utf8').split('\n');
  expect(lines, `${key} in:\n${lines.join('\n')}`).toContain(`${key}='${value}'`);
});

Then('no builder profile was written for the brand record', async ({ world }) => {
  const prof = world.get<string>(PROF_KEY);
  expect(fs.existsSync(prof), `${prof} exists:\n${fs.existsSync(prof) ? fs.readFileSync(prof, 'utf8') : ''}`)
    .toBe(false);
});

/** The consumer shape: `set -eu; . PROFILE` — a builder sourcing brands/<brand>.conf. */
function harness(args: string[]): CliTranscript {
  return runCli(['bash', '-c',
    'set -eu; prof="$1"; key="$2"; if [ -e "$prof" ]; then . "$prof"; fi; '
    + 'if [ -n "$key" ]; then eval "printf %s \\"\\${$key}\\""; fi',
    'harness', ...args], { cwd: REPO_ROOT });
}

Then('the builder harness sources whatever profile exists and the sentinel file does not exist', async ({ world }) => {
  const prof = world.get<string>(PROF_KEY);
  const sentinel = world.get<string>(SENTINEL_KEY);
  const t = harness([prof, '']);
  expect(t.exitCode, `harness: ${t.stderr}`).toBe(0);
  expect(fs.existsSync(sentinel), `${sentinel} was created — the profile ran code`).toBe(false);
});

Then('the builder harness sources the generated profile and reads {string} as {string}',
  async ({ world }, key: string, value: string) => {
    const prof = world.get<string>(PROF_KEY);
    expect(fs.existsSync(prof), `no profile at ${prof}`).toBe(true);
    const t = harness([prof, key]);
    expect(t.exitCode, `harness: ${t.stderr}`).toBe(0);
    expect(t.stdout).toBe(value);
  });
