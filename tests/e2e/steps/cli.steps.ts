// cli.steps.ts — the vocabulary the ISSUE-COVERAGE scenarios under features/cli/
// need on top of common.steps.ts (run a command, assert its exit, assert a
// substring) and cli-lane.steps.ts (structured JSON assertions, the e2e CLI).
//
// Checked against every step already defined before each was written
// (grep -rn "<text>" tests/e2e/steps/): none of these rewords an existing step.
// The generic cli steps are REUSED as-is; nothing here is a near-twin of
// `I run the shell command`, `the command succeeded` or `the command output
// contains`.
//
// WHAT IS NEW, and why each earns a definition rather than a shell one-liner:
//
//   * `I run the shell script:` (a DocString) — a multi-line bash body. Several
//     issue scenarios stage a fixture, run a resolver over it and print a
//     verdict; squeezing that into one quoted {string} makes the Gherkin
//     unreadable and the quoting fragile. The script sees a small, NON-SECRET
//     environment (repo root, a per-scenario scratch dir, the scenario's
//     environment base URL, the Studio's python, the persona handle, the PATH
//     of the credentials file). Every one of those is recorded in the
//     transcript as an env override — which is exactly why no secret VALUE is
//     ever passed this way. A script that needs the shared e2e password reads
//     the credentials file itself and must never echo it (the secrecy step
//     below is what proves it did not).
//   * `… allowing {int} minutes` — the live kind/docker verbs (halt, resume,
//     seed) take longer than the runner's default; a scenario that needs more
//     says so in its own text instead of the operator guessing an env var.
//   * `the command output does not contain {string}` — the negative half the
//     shared vocabulary lacks. Needed by every secrecy / fail-closed assertion.
//   * `every non-empty line of the command's stdout matches {string}` — "ALL
//     Applications are Synced/Healthy" is a per-line property; a substring
//     match on the whole blob passes when one line out of 24 is right.
//   * `the command output does not contain the shared e2e persona password` —
//     reads the password through the SAME resolver the handwritten specs use
//     (specs/rbac-roles.ts sharedPassword: env, else the run-state file) and
//     asserts the transcript never carries it. NEVER executes
//     tests/stack/e2e-password.sh — executing it mints a fresh value when the
//     file is absent and silently rotates every persona's password.
//   * `this scenario mutates the {string} lane and the operator opted in with
//     {string}` — the halt/resume round trip and a re-seed MUTATE a shared
//     cluster/stack. They must never run because a lane was selected; they run
//     when a person says so, with a named env var, and skip LOUDLY otherwise.
//   * the stub kind node — bootstrap-kind.sh's fail-closed preflights (#510
//     in-node DNS, #529 halted-cluster refusal) can be proven with NO cluster:
//     kind/docker/kubectl stubs on PATH that answer "the cluster exists", break
//     exactly one thing, and RECORD every kubectl call so the scenario can
//     assert the bring-up stopped BEFORE it mutated or waited on anything.

import { expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';
// Given/When/Then come from './world' ONLY — see world.ts and features/README.md §1.
import { Given, When, Then, After } from './world';
import type { Dimensions, World } from './world';
import { runCli, REPO_ROOT, scratchDir } from './runners';
import { CliTranscript } from './evidence';
import { environmentBaseUrl, envOf, persona, studioPython } from './dimensions';
import { sharedPassword } from '../specs/rbac-roles';

// The pinned world key common.steps.ts uses; same key on purpose so
// `the command succeeded` / `the command output contains` read what these wrote.
const CLI_KEY = 'cli.transcript';
const SCRATCH_KEY = 'cli.scenarioScratch';
const STUB_KEY = 'cli.kindStub';

const DEFAULT_TIMEOUT_MS = Number(process.env.SNAP_CLI_TIMEOUT_MS || '120000');

// ── per-scenario scratch ─────────────────────────────────────────────────────

/** One private directory per scenario, under the runner's scratch root. Never the git tree. */
function scenarioScratch(world: World): string {
  if (!world.has(SCRATCH_KEY)) {
    fs.mkdirSync(scratchDir(), { recursive: true });
    world.set(SCRATCH_KEY, fs.mkdtempSync(path.join(scratchDir(), 'scenario-')));
  }
  return world.get<string>(SCRATCH_KEY);
}

After(async ({ world }) => {
  if (world.has(SCRATCH_KEY)) {
    fs.rmSync(world.get<string>(SCRATCH_KEY), { recursive: true, force: true });
  }
});

// ── a multi-line script, with a NON-SECRET environment ───────────────────────

/**
 * What a script may rely on. Every value is recorded in the transcript
 * (runners.ts records env OVERRIDES, not the ambient env), so nothing secret
 * belongs here — the credentials FILE PATH is exported, its contents are not.
 */
function scriptEnv(world: World, dimensions: Dimensions): Record<string, string> {
  const env: Record<string, string> = {
    HUGMESH_BDD_REPO_ROOT: REPO_ROOT,
    HUGMESH_BDD_SCRATCH: scenarioScratch(world),
    HUGMESH_BDD_BASE_URL: environmentBaseUrl(envOf(dimensions)),
    HUGMESH_STUDIO_PYTHON: studioPython(),
    HUGMESH_BDD_CREDENTIALS_FILE:
      process.env.E2E_CREDENTIALS_FILE ?? path.join(REPO_ROOT, '.e2e-credentials'),
  };
  // Only when the scenario declared a @role: — persona() throws on an unknown
  // handle, which is the anti-ghost-persona check doing its job.
  if (dimensions.role) env.HUGMESH_BDD_PERSONA = persona(dimensions.role);
  return env;
}

function runScript(world: World, dimensions: Dimensions, script: string, timeoutMs: number): void {
  world.set(CLI_KEY, runCli(['bash', '-c', script], {
    cwd: REPO_ROOT,
    env: scriptEnv(world, dimensions),
    timeoutMs,
  }));
}

When('I run the shell script:', async ({ world, dimensions }, script: string) => {
  runScript(world, dimensions, script, DEFAULT_TIMEOUT_MS);
});

When('I run the shell script allowing {int} minutes:',
  async ({ world, dimensions }, minutes: number, script: string) => {
    runScript(world, dimensions, script, minutes * 60_000);
  });

When('I run the shell command {string} allowing {int} minutes',
  async ({ world }, command: string, minutes: number) => {
    world.set(CLI_KEY, runCli(['bash', '-c', command], { cwd: REPO_ROOT, timeoutMs: minutes * 60_000 }));
  });

// ── negative / per-line assertions on the transcript ─────────────────────────

/**
 * A REAL non-zero exit — the process ran to completion and said no. Distinct
 * from `the command failed`, which is also true of a run the runner killed on
 * timeout (exitCode null + signal). A fail-closed preflight must be the
 * former; a bring-up that wandered into a wait loop and was shot is the latter,
 * and this suite refuses to let the second pass for the first.
 */
Then('the command exited with a non-zero code', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  expect(t.spawnError, `\`${t.command}\` never started`).toBeNull();
  expect(t.signal, `\`${t.command}\` was killed by a signal${t.timedOut ? ' (timed out)' : ''} — that is not a refusal`).toBeNull();
  expect(t.exitCode, `\`${t.command}\` exit code`).not.toBeNull();
  expect(t.exitCode, `\`${t.command}\` exited 0 — it was expected to refuse`).not.toBe(0);
});

Then('the command output does not contain {string}', async ({ world }, needle: string) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  const hay = `${t.stdout}\n${t.stderr}`;
  expect(
    hay,
    `\`${t.command}\` output was expected NOT to contain ${JSON.stringify(needle)} but did`,
  ).not.toContain(needle);
});

/**
 * A regular expression every non-empty STDOUT line must match. Stdout only:
 * stderr is where kubectl and friends put warnings that are not rows. A
 * command that printed NOTHING fails — "every line of nothing matches" is the
 * vacuous green this suite refuses everywhere else.
 */
Then("every non-empty line of the command's stdout matches {string}",
  async ({ world }, pattern: string) => {
    const t = world.get<CliTranscript>(CLI_KEY);
    const re = new RegExp(pattern);
    const lines = t.stdout.split('\n').filter((l) => l.trim() !== '');
    expect(lines.length, `\`${t.command}\` printed no stdout lines to match against`).toBeGreaterThan(0);
    const bad = lines.filter((l) => !re.test(l));
    expect(bad, `\`${t.command}\`: ${bad.length} of ${lines.length} stdout line(s) do not match /${pattern}/`)
      .toEqual([]);
  });

/**
 * THE SECRECY ASSERTION (#362). Resolves the shared e2e password exactly as the
 * handwritten specs do — E2E_PASSWORD, else the run-state credentials file —
 * and requires the transcript to be free of it. If no password can be
 * resolved the step FAILS rather than passing: secrecy of an unknown value is
 * not something this step can vouch for. It never runs e2e-password.sh.
 */
Then('the command output does not contain the shared e2e persona password', async ({ world }) => {
  const t = world.get<CliTranscript>(CLI_KEY);
  const pw = sharedPassword(); // throws, naming the remedy, when nothing resolves
  expect(pw.length, 'the resolved shared e2e password is too short to assert secrecy of').toBeGreaterThanOrEqual(8);
  const hay = `${t.stdout}\n${t.stderr}`;
  expect(
    hay.includes(pw),
    `\`${t.command}\` printed the shared e2e persona password to its own stdout/stderr `
    + '(value withheld from this message). The seed banner must name WHERE the password is, never what it is.',
  ).toBe(false);
});

// ── explicit opt-in for scenarios that MUTATE a shared lane ──────────────────

/**
 * `SNAP_KIND_MUTATE=1`-style opt-in. The lane is named so the skip reason says
 * which shared thing the scenario would have changed; the spec is VAR=value so
 * the operator sets exactly what the scenario text shows. Skips are reported
 * by name, never silent.
 */
Given('this scenario mutates the {string} lane and the operator opted in with {string}',
  async ({ $testInfo }, lane: string, spec: string) => {
    const eq = spec.indexOf('=');
    if (eq <= 0) throw new Error(`opt-in spec must be VAR=value, got ${JSON.stringify(spec)}`);
    const name = spec.slice(0, eq);
    const want = spec.slice(eq + 1);
    const got = process.env[name];
    $testInfo.skip(
      got !== want,
      `this scenario MUTATES the shared ${lane} lane (halt/resume/re-seed). It runs only when a person `
      + `opts in with ${spec} on the command line; ${name} is ${got === undefined ? 'unset' : JSON.stringify(got)}.`,
    );
  });

// ── a stub kind node, for bootstrap-kind.sh's fail-closed preflights ─────────

interface KindStub { dir: string; bin: string; cluster: string }

const STUB_CLUSTER = 'bdd-stub';

/**
 * kind / docker / kubectl stubs that make bootstrap-kind.sh take its
 * "already exists — reusing it" branch against a cluster that does not exist,
 * then break ONE thing. Every kubectl call is appended to kubectl.log so the
 * scenario can assert the bring-up stopped before it applied or waited.
 *
 * The docker stub answers the EXISTING egress preflight (a raw TCP connect
 * inside the node) with success, so the scenario proves a DNS preflight that is
 * distinct from it. An in-node NAME LOOKUP (getent/nslookup/dig/host/resolvectl)
 * behaves like a real broken resolver: NO output, exit 2. The stub deliberately
 * prints neither the word "resolver" nor an address, so the bring-up's own
 * message is the only place those can come from. The node's resolver is
 * readable the way a real node's is — `cat /etc/resolv.conf` inside it names
 * 172.18.0.1, docker's embedded DNS on the kind network.
 */
function makeKindStub(world: World, opts: { unresolvable?: boolean; halted?: boolean }): KindStub {
  const dir = fs.mkdtempSync(path.join(scenarioScratch(world), 'kind-stub-'));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin, { recursive: true });
  const write = (name: string, body: string) => {
    const p = path.join(bin, name);
    fs.writeFileSync(p, body, { mode: 0o755 });
  };

  write('kind', `#!/usr/bin/env bash
printf '%s\\n' "kind $*" >> "\${STUB_DIR}/kind.log"
case "\${1:-} \${2:-}" in
  "get clusters")      echo "${STUB_CLUSTER}"; exit 0 ;;
  "export kubeconfig") exit 0 ;;
esac
echo "kind v0.0.0-bdd-stub"
exit 0
`);

  write('docker', `#!/usr/bin/env bash
printf '%s\\n' "docker $*" >> "\${STUB_DIR}/docker.log"
case "\${1:-}" in
  inspect) echo running; exit 0 ;;
  network)
    # docker network inspect kind -> the gateway that doubles as the node's resolver
    echo '[{"Name":"kind","IPAM":{"Config":[{"Subnet":"172.18.0.0/16","Gateway":"172.18.0.1"}]}}]'; exit 0 ;;
  exec)
    args=" $* "
    case "\${args}" in
      *"/etc/resolv.conf"*) echo "nameserver 172.18.0.1"; echo "search ."; exit 0 ;;
      *" getent "*|*" nslookup "*|*" dig "*|*" host "*|*" resolvectl "*|*" drill "*)
        if [ "\${STUB_UNRESOLVABLE:-0}" = "1" ]; then exit 2; fi
        echo "203.0.113.10    stub-answer"; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
`);

  write('kubectl', `#!/usr/bin/env bash
printf '%s\\n' "kubectl $*" >> "\${STUB_DIR}/kubectl.log"
args=" $* "
is_halt_record=0
case "\${args}" in *" configmap "*|*" configmap/"*|*" cm "*|*" configmaps "*)
  case "\${args}" in *"hugmesh-kind-halt"*) is_halt_record=1 ;; esac ;;
esac
if [ "\${is_halt_record}" = "1" ]; then
  if [ -f "\${STUB_DIR}/halt.json" ]; then
    case "\${args}" in
      *jsonpath*) cat "\${STUB_DIR}/halt.json" ;;
      *" -o json"*|*" -ojson"*|*"-o=json"*)
        python3 - "\${STUB_DIR}/halt.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap",
                  "metadata": {"name": "hugmesh-kind-halt", "namespace": "devops"},
                  "data": {"halt.json": raw}}))
PY
        ;;
      *) echo "NAME               DATA   AGE"; echo "hugmesh-kind-halt  1      1h" ;;
    esac
    exit 0
  fi
  echo 'Error from server (NotFound): configmaps "hugmesh-kind-halt" not found' >&2
  exit 1
fi
case "\${args}" in
  *" get nodes "*|*" get node "*)
    case "\${args}" in
      *jsonpath*) echo "${STUB_CLUSTER}-control-plane" ;;
      *) echo "NAME                      STATUS   ROLES           AGE   VERSION"
         echo "${STUB_CLUSTER}-control-plane   Ready    control-plane   1h    v1.30.0" ;;
    esac
    exit 0 ;;
  *" version"*) echo "Client Version: v1.30.0"; echo "Server Version: v1.30.0"; exit 0 ;;
esac
# Everything else is ACCEPTED silently (exit 0, no output). That is what makes
# "no mutating kubectl call was recorded" a meaningful assertion: a preflight
# that fails closed exits before this stub ever has to invent a cluster.
exit 0
`);

  if (opts.halted) {
    fs.writeFileSync(path.join(dir, 'halt.json'), JSON.stringify({
      version: 2,
      completed: true,
      cluster: STUB_CLUSTER,
      context: `kind-${STUB_CLUSTER}`,
      argocd_ns: 'devops',
      halted_at: '2026-09-23T00:00:00Z',
      skipped_namespaces: ['kube-system', 'kyverno', 'local-path-storage', 'devops'],
      admission_floor: {},
      counts: { workloads_censused: 39, workloads_scaled: 24, workloads_left_running: 15,
                workloads_on_unbacked_floor: 0, applications_censused: 24, applications_suspended: 24 },
      applications: [{ name: 'hugmesh-user-bff-api', namespace: 'devops', was_automated: true,
                       sync: 'Synced', health: 'Healthy', owned_by: [] }],
      workloads: [{ namespace: 'hugmesh-backend', kind: 'Deployment', name: 'hugmesh-user-bff-api',
                    replicas: 6, skipped: null, floor_unbacked: false }],
      hpas: [], hpas_censused: true,
    }, null, 2));
  }
  fs.writeFileSync(path.join(dir, 'unresolvable'), opts.unresolvable ? '1' : '0');
  const stub = { dir, bin, cluster: STUB_CLUSTER };
  world.set(STUB_KEY, stub);
  return stub;
}

Given('a stub kind node on PATH whose resolver cannot resolve any name', async ({ world }) => {
  makeKindStub(world, { unresolvable: true });
});

Given('a stub kind node on PATH carrying a halt record', async ({ world }) => {
  makeKindStub(world, { halted: true });
});

/**
 * Drive the REAL specs/cluster/bootstrap/kind-local/bootstrap-kind.sh with the
 * stubs at the front of PATH. KIND_PROFILE=core and KIND_ADDONS=none keep the
 * run to the bring-up's own preflights; the cluster name is the stub's, so a
 * real hugmesh-local is never even named. A pre-fix bring-up walks past the
 * missing preflight into its wait loops and is killed by the timeout, which
 * the transcript records as a signal, never as success.
 */
When('I run the kind bootstrap against the stub node', async ({ world }) => {
  const stub = world.get<KindStub>(STUB_KEY);
  world.set(CLI_KEY, runCli(['bash', 'specs/cluster/bootstrap/kind-local/bootstrap-kind.sh'], {
    cwd: REPO_ROOT,
    env: {
      PATH: `${stub.bin}:${process.env.PATH ?? '/usr/bin:/bin'}`,
      STUB_DIR: stub.dir,
      STUB_UNRESOLVABLE: fs.readFileSync(path.join(stub.dir, 'unresolvable'), 'utf8').trim(),
      KIND_CLUSTER_NAME: stub.cluster,
      KIND_PROFILE: 'core',
      KIND_ADDONS: 'none',
      KUBECONFIG: path.join(stub.dir, 'kubeconfig'),
      TMPDIR: stub.dir,
    },
    timeoutMs: 90_000,
  }));
});

/**
 * "Before it waits on anything" / "refuse with the remedy", made checkable: the
 * stub's kubectl.log must hold no apply/create/patch/label/delete/wait/scale/
 * rollout call. Reads (get/version/config) are fine — asking the cluster a
 * question is how a preflight works.
 */
Then('the stub node recorded no mutating or waiting kubectl call', async ({ world }) => {
  const stub = world.get<KindStub>(STUB_KEY);
  const logPath = path.join(stub.dir, 'kubectl.log');
  const lines = fs.existsSync(logPath)
    ? fs.readFileSync(logPath, 'utf8').split('\n').filter((l) => l.trim() !== '')
    : [];
  const mutating = /^kubectl(?:\s+--context\s+\S+)?(?:\s+-n\s+\S+)?\s+(apply|create|patch|label|delete|wait|scale|rollout|annotate|replace|exec)\b/;
  const bad = lines.filter((l) => mutating.test(l));
  expect(
    bad,
    `bootstrap-kind.sh reached ${bad.length} mutating/waiting kubectl call(s) before failing closed:\n  ${bad.join('\n  ')}`,
  ).toEqual([]);
});
