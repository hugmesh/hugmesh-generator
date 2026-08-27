# The Gherkin lane — conventions every feature author follows VERBATIM

This directory holds executable Gherkin. `npx bddgen` compiles it into Playwright
specs; the `bdd` project in `../playwright.config.ts` runs them. **A `.feature`
that does not generate and run does not count** — `tests/scripts/test-e2e-gherkin-harness.sh`
fails the build if one stops being picked up.

## 1. Layout — exact

```
tests/e2e/features/<domain>/<name>.feature   the Gherkin
tests/e2e/steps/world.ts                     THE single import entry point (hooks + fixtures)
tests/e2e/steps/dimensions.ts                ROLE / PLATFORM / SERVICE vocabulary
tests/e2e/steps/common.steps.ts              the SHARED step vocabulary — reuse, never redefine
tests/e2e/steps/<domain>.steps.ts            your step definitions (FLAT — no subdirectories)
tests/e2e/.features-gen/                     GENERATED. gitignored. never committed.
```

`<domain>` mirrors the handwritten spec domains: `onboarding`, `rbac`, `matrix`,
`mastodon`, `forum`, `games`, `federation`, `media`, `platform`.

Step-definition files are **flat** in `steps/` and end in `.steps.ts`, so the
import is always exactly:

```ts
import { Given, When, Then, requireDimension, substep } from './world';
```

**Never** `import { Given } from 'playwright-bdd'`. `createBdd(test)` binds hooks
and step definitions to one `test` instance; a second `createBdd()` call binds to
a different one, load ordering races, and the AfterStep screenshot hook silently
never fires. `world.ts` makes that call once for the whole suite.

## 2. The matrix: ROLE × PLATFORM × SERVICE

Three axes, one spelling. Values are validated in the `Before` hook — an unknown
value throws with the legal set before a browser action runs.

| axis | tag | legal values |
|---|---|---|
| ROLE | `@role:<persona-handle>` | any handle seeded by `specs/rbac-roles.ts` `SYSTEMS_SEED_USERS` **or** `tests/e2e-extra-personas.sh` |
| PLATFORM | `@platform:<target>` | `rpi5`, `x86` |
| SERVICE | `@service:<id>` | `tuwunel`, `akkoma`, `phpbb`, `games`, `owncast`, `tube`, `wiki`, `character-studio`, `character-forge`, `gateway`, `login`, `admin` |
| ENVIRONMENT | `@env:<id>` | `docker`, `kind`, `qemu` |
| INTERFACE | `@interface:<id>` | `browser`, `cli`, `studio` |
| (reporting) | `@layer:<layer>` | `gateway`, `bff`, `homeserver`, `egress`, `casdoor`, `ui`, `sse` (`specs/report-tags.ts`) |

`@role:` names a **persona handle** (`e2e-admin`, `alice@gmail.com`), never a
`ROLE_*` string. A role is not an identity and cannot be logged in as.

### 2a. FIXED dimension → a Gherkin tag

```gherkin
@service:akkoma @platform:x86 @layer:ui
Feature: Mastodon timeline
  @role:e2e-mastodon
  Scenario: a platform-access persona posts to their home timeline
```

### 2b. VARYING dimension → an Examples column **and** the tag suffix in the name

The Examples column must be named exactly `role` / `platform` / `service`, and the
`Scenario Outline` **name must end with the matching `@axis:<column>` suffix**:

```gherkin
Scenario Outline: <role> is denied the infra console @role:<role> @service:admin @layer:gateway
  ...
  Examples:
    | role     |
    | e2e-mod  |
    | e2e-user |
```

Why the suffix is mandatory and not cosmetic: Gherkin tags cannot carry
placeholders, so a varied axis cannot be a tag. playwright-bdd fills `<column>`
placeholders that appear in the **outline name** to build each example's test
title (`dist/generate/examplesTitleBuilder.js`), and the existing
`reporters/hugmesh-reporter.ts` pivots `summary.json`'s `perRole` / `perLayer`
off the **title**. Drop the suffix and every row of your matrix is bucketed
`role:unknown`. Measured, not assumed — see the `perRole` block in the unit
report.

Tags and title are both parsed; the title wins, because it is the per-example
value.

### 2c. Reading a dimension inside a step

```ts
Given('I am signed in as the persona for this scenario', async ({ page, dimensions }) => {
  const handle = persona(requireDimension(dimensions, 'role'));
  ...
});
```

`requireDimension` fails loudly when the scenario never declared the axis.

### 2d. What PLATFORM actually does at run time

A mesh under test is one image target at a time. `SNAP_PLATFORM=rpi5|x86` makes
the `Before` hook skip scenarios pinned to the *other* platform **with a named
reason** — they still appear in `--list`, and the skip is reported, never silent.
With `SNAP_PLATFORM` unset (the default) every platform row runs.

### 2e. ENVIRONMENT — which mesh, and what to start when it is down

| id | what it is | base URL | start it with |
|---|---|---|---|
| `docker` | the local compose stack (**the default**) | `SNAP_BASE_URL` or `https://localhost:8443` | `make stack-up ENV=test` then `make stack-seed` |
| `kind` | the local devops cluster, context `kind-hugmesh-local` | `https://hugmesh.net:8443` (from the Makefile's `kind-e2e`) | `make kind-images && make kind-up` |
| `qemu` | an emulated device, over its forwarded host port | `https://localhost:${UI_PORT}` (`tests/qemu/run-qemu-e2e.sh`, default 8443) | `bash tests/qemu/run-qemu-e2e.sh --target x86 --img <image>` |

Tagging `@env:` does three things:

1. it **re-points `baseURL`**, so every existing relative `page.goto('/login')`
   follows the scenario's environment with no change to the step;
2. it **availability-gates** the scenario — the `Before` hook probes the door with
   a real HTTP request and, when nothing answers, skips with a reason **naming
   the exact command to run**. It never passes against a dead mesh;
3. it makes the scenario respect `SNAP_ENV=docker|kind|qemu`, the environment
   equivalent of `SNAP_PLATFORM`.

**An untagged scenario is NOT availability-gated.** That is deliberate: the
pre-existing scenarios declare no `@env:`, and gating them would turn every
honest "nothing at :8443" failure into a green-looking skip. Opt in by tagging.

A probe issues a real HTTP request, because a TCP-connect probe lies here:
docker's port proxy binds `:8443` whether or not anything serves it, and the kind
node container holds that same port as soon as the cluster exists. Only a status
line proves the door answers. `@env:docker` and `@env:kind` can therefore never
both be available on one host, and the skip reason names which container actually
holds the port.

`@env:kind` + `@interface:browser` additionally needs
`SNAP_HOST_RESOLVER='MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1'`
(what `make kind-e2e` sets) — `hugmesh.net` does not resolve on a developer box.
Without it the scenario skips naming the variable, rather than dying on DNS and
reading like a broken cluster.

**No probe starts anything.** Bringing an environment up is the operator's action.

### 2f. INTERFACE — how it is driven, and what evidence that leaves

| id | driven by | evidence of record |
|---|---|---|
| `browser` (**default**) | Playwright page driving | the per-step `.png` |
| `cli` | `runCli()` in `steps/runners.ts` | a **transcript** — argv, cwd, stdout, stderr, real exit code, duration |
| `studio` | the real PyQt wizard offscreen, via `tests/e2e/studio-driver.py` | a **Qt widget grab** `.png` |

A terminal has no screenshot, so the cli interface's artefact of record is the
transcript. A `.cli.txt` rendering and a `.cli.png` picture are written alongside
it for readability, but **an assertion always reads the transcript**, never the
picture.

The exit code in a transcript is the **real** one. A process killed by a signal
records `exitCode: null` plus the signal; one that never started records
`spawnError`. Neither is ever coerced to `0`.

Use the shared steps — do not write your own runner:

```gherkin
@interface:cli
Scenario: the mesh CLI reports its version
  When I run the shell command "make --version"
  Then the command succeeded
  And the command output contains "GNU Make"

@interface:studio
Scenario: the QEMU page renders
  When I grab the Studio wizard page "qemu"
  Then the Studio grab is a non-empty PNG
  And the Studio grab shows the wizard page "qemu"
```

`cli` and `studio` are availability-probed too: a host with no Qt6 binding skips
the studio scenarios naming the package to install, rather than dying inside a
python traceback four layers down.

## 3. Steps

* Reuse `common.steps.ts` first. A duplicate step text is a hard generation error
  (`missingSteps: 'fail-on-gen'`), so you cannot shadow one by accident — but the
  fix is to reuse, not to reword.
* Step definitions **call the existing helpers** (`../specs/helpers`,
  `../specs/federation`, `../specs/rbac-roles`, `../specs/totp`, …). Do not
  reimplement login, seeding or navigation: the Gherkin must drive the same code
  the 33 handwritten specs drive, or the two lanes drift.
* Every Gherkin step is already a real Playwright `test.step()` (playwright-bdd
  wraps it). Use `substep('…', async () => {…})` from `world.ts` only to split a
  definition that does several distinguishable things.

## 4. Evidence — one artefact per step, one manifest per run

`AfterStep` writes, per Gherkin step, under
`${SNAP_REPORT_DIR:-test-results}/bdd-steps/<runId>/<feature>/<scenario>/`:

```
NNN-<step>.json         the SIDECAR — always written, for every step
NNN-<step>.png          browser: the screenshot
NNN-<step>.cli.json     cli: the TRANSCRIPT (record of truth)
NNN-<step>.cli.txt      cli: human-readable rendering of it
NNN-<step>.cli.png      cli: convenience picture of it   (SNAP_CLI_PNG=0 to skip)
NNN-<step>.studio.png   studio: the Qt widget grab
NNN-<step>.studio.json  studio: the driver invocation behind the grab
manifest.jsonl          appended during the run, one line per artefact
manifest.json           the browsable index, materialised in AfterAll
```

Override the base with `SNAP_BDD_SHOTS`. Evidence never goes to
`tests/e2e/screenshots/` — that holds 38 git-tracked PNGs which every legacy run
overwrites in place, dirtying the working tree. Do not add to that pattern.

### 4a. The sidecar

```jsonc
{ "feature", "scenario", "step", "ordinal", "role", "platform", "service",
  "layer", "env", "interface", "failed", "at" }
```

The first eight keys predate the env/interface axes and **keep their names** —
other readers already parse them. `env` and `interface` carry the **effective**
value (default applied), because a reader asking "which mesh produced this PNG"
needs an answer, not a null.

### 4b. The manifest is a CONTRACT

The Studio's feature tree browses `manifest.json`, so its shape is pinned by the
hand-written fixture `tests/e2e/evidence-manifest.schema.json` and checked by
`tests/scripts/test-e2e-env-interface-dimensions.sh`.

```jsonc
{
  "schema": "hugmesh.bdd.evidence-manifest/1",
  "runId": "...", "root": "<abs dir>", "generatedAt": "...",
  "counts": { "artefacts", "failed", "byEnv", "byInterface", "byKind" },
  "artefacts": [
    { "env", "interface", "feature", "scenario", "step", "ordinal",
      "role", "service", "platform", "layer", "failed",
      "kind", "path", "sidecar", "bytes", "at", "note" }
  ]
}
```

* `kind` ∈ `screenshot` | `transcript` | `transcript-text` | `transcript-render`
  | `widget-grab` | `sidecar-only`.
* **Every key is always present on every row.** An unknown dimension is `null`,
  never an absent key, so a consumer can index without existence checks.
* `path` and `sidecar` are **relative to `root`**, so a report directory copied
  onto the test-reports PVC still resolves.
* **Every file written gets a row, and every row points at a file that exists.**
  Both directions are gated — a manifest listing artefacts nobody can open is
  worse than no manifest, because a reviewer counts the rows and believes them.

The fixture is hand-written and **must never be regenerated from a run**.
Validating a run's output against a schema derived from that same output proves
only that the run agreed with itself: the moment the writer drops a field, a
derived schema drops it too and the guard stays green while the contract rots.

Breaking the shape (removing/renaming a field, changing a type) means bumping the
trailing integer of `EVIDENCE_SCHEMA` in `steps/evidence.ts` **and** `schema` in
the fixture, together. Adding an optional field is compatible.

### 4c. Asserting on your own evidence

```gherkin
Then the evidence manifest holds a "transcript" artefact for this scenario
And every evidence artefact recorded for this scenario exists on disk
```

These read `manifest.jsonl` (the append log), so they see rows written by
*earlier steps of the same scenario*. This is the anti-decoration assertion for
the evidence lane itself.

## 4d. The CLI entry point — ONE way to run this lane

`tests/e2e/run.sh` is the only invocation path. Every `stack-e2e-bdd*` Makefile
target delegates to it, so `make stack-e2e-bdd BDD_ENV=qemu` and
`bash tests/e2e/run.sh --bdd --env qemu` are the same run. When these were two
recipes they drifted; do not add a third.

```sh
tests/e2e/run.sh --bdd --env docker|kind|qemu   # which mesh (NOTHING is started)
tests/e2e/run.sh --bdd --tags '@interface:cli'  # -> bddgen --tags (filters GENERATION)
tests/e2e/run.sh --bdd --features cli/          # -> playwright (filters COLLECTION)
tests/e2e/run.sh --bdd --list                   # collect, run nothing
tests/e2e/run.sh --bdd --gen                    # generate, run nothing
tests/e2e/run.sh --print-command --env kind     # the whole plan as JSON, executes nothing
tests/e2e/run.sh --evidence [--json]            # where this run's artefacts are, per env/interface
```

With **no** new flag it behaves exactly as it always did (legacy specs, both
projects, arguments forwarded verbatim, SNAP_BASE_URL untouched) — that is what
`tests/e2e/run-all.sh` and `tests/qemu/run-qemu-e2e.sh` rely on, and it is
asserted, not assumed.

Three properties are gated by `tests/scripts/test-e2e-cli-lane.sh`, which drives
the script with a **stub `npx` on PATH** and reads the argv that really came
out — grepping the source for `SNAP_ENV` would prove a token exists, not that it
is forwarded:

* `--env` reaches the runner as `SNAP_ENV` + `SNAP_BASE_URL` (+ the chromium
  resolver map for kind), and the bash table agrees with
  `ENVIRONMENT_DEFS` in `steps/dimensions.ts` for **every** mesh;
* `--tags` reaches the generator and `--features` reaches the runner, translated
  from the source path you type to the `.features-gen/` mirror;
* the runner's exit code is the script's exit code, and a failed `bddgen` aborts
  instead of running a smaller suite.

An unknown `--env` **fails naming the legal set**; it never falls through to the
default mesh. `--evidence` counts the manifest's rows itself (never
`manifest.counts`) and exits non-zero when there is nothing to report — an empty
summary printed as success is how a lane that ran nothing passes for one that
ran everything.

**Writing a cli-interface scenario.** Drive a real command line and assert on
what came back. Reuse the shared vocabulary — `I run the shell command`,
`I run the Studio CLI with`, `the command succeeded/failed`,
`the command exit code was N`, `the command output contains`. For a structured
answer use the JSON steps in `steps/cli-lane.steps.ts`
(`the command output JSON field "counts.byInterface.cli" is at least 1`) rather
than a substring match on a JSON blob, which passes for the wrong reasons.
`I run the e2e CLI with` accepts only run.sh's read-only modes: a scenario that
executed the lane would recurse, and `--gen` would rewrite `.features-gen/` —
shared mutable state — underneath the run that asked.

Do **not** tag a cli scenario `@env:` unless it genuinely needs that mesh
running. `make help`, `make qemu-matrix-enumerate`, `make kind-honesty` and the
Studio's Qt-free channels all answer with everything down; gating them would
turn honest coverage into permanent skips.

## 5. Verify your feature before you commit

From `tests/e2e`:

```sh
npx bddgen && npx playwright test --list --project=bdd
bash ../scripts/test-e2e-gherkin-harness.sh
bash ../scripts/test-e2e-env-interface-dimensions.sh   # env/interface axes + evidence
bash ../scripts/test-e2e-cli-lane.sh                   # the CLI entry point + evidence summary
```

or, from the repo root, `make stack-e2e-bdd-check` (generation + all three
guards, no stack needed). `make stack-e2e-bdd` runs the lane against a live
mesh; `make stack-e2e-bdd-evidence` says where the artefacts went.

If `bddgen` exits non-zero your feature uses a step nobody defined — that is the
anti-decoration gate doing its job. Define the step or fix the wording; never
delete the assertion.
