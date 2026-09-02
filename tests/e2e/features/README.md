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
| FUNCTION | *(Examples column, not a tag — see 2g)* | any id in `steps/social-functions.ts` `SOCIAL_FUNCTIONS` |
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
| `docker` | the local compose stack (**the default**) | `SNAP_BASE_URL` or `https://localhost:${PUBLIC_HTTPS_PORT:-8488}` (the compose stack's PUBLISHED door — `compose.local.yaml` maps `${PUBLIC_HTTPS_PORT:-8488}:8443`, and 8443 is the port *inside* the tls-front container; on a dev box :8443 is the kind node) | `make stack-up ENV=test` then `make stack-seed` |
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

### 2g. FUNCTION — what a user actually DOES inside a social service

The five axes above say WHO, on WHICH image, against WHICH service, in WHICH
mesh, through WHICH interface. None of them says **what the user did**. That
sixth thing is the FUNCTION, and for the three social services it is catalogued
in `steps/social-functions.ts`.

It is deliberately **not a tag**. There are 53 social functions and 31 seeded
personas, and a `@function:` tag would invite one hand-written scenario per cell
— 1,643 of them, which is decoration by volume. Instead the function is an
Examples **column** whose step iterates the other axis internally:

```gherkin
Scenario Outline: <function> is gated for the whole roster exactly as the catalogue declares @service:tuwunel @layer:gateway
  Then the route-access seed gates the "<function>" function of the service dimension for every seeded persona
  And the "<function>" function of the service dimension is a "<arity>" interaction

  Examples:
    | function     | arity |
    | send-message | pair  |
```

so the coverage is generative in **both** directions:

| file | one row per | iterates internally | adding one widens |
|---|---|---|---|
| `features/{matrix,mastodon,forum}/function-surface.feature` | FUNCTION | the whole roster | a persona |
| `features/platform/social-function-matrix.feature` | PERSONA | the whole catalogue | a function |

**`arity`** (`solo` / `pair` / `group`) is the INTERACTION axis: how many
DISTINCT cookie-separated identities the function needs before it means
anything. A `pair` downgraded to `solo` is how "my peer sees it" quietly becomes
one page asserting against itself.

**Two independent sources, never one.** The catalogue *declares* the gate by
hand; `specs/cluster/manifests/route-access/initdb/20-schema.sql` *deploys* it.
The scenarios pass only when the two agree, so neither can drift alone. NOTE
which oracle: the SQL seed, **not** `specs/rbac-route-access.ts` — measured on
this tree the TypeScript mirror is a strict SUBSET (50 rows of the seed's 150)
that never grew the forum/media/streaming/external-client planes, and
`social-function-matrix.feature` pins that relationship so a future
*contradiction* fails by name.

**A probe path asserts the GATE, not the endpoint.** Its only load-bearing
property is which `url_pattern` it matches; concrete ids in it
(`!e2e:hugmesh.net`, a status id of `1`) are representative. Behaviour is the
journey tier's job.

**The drift guard is the deliverable.** `features/platform/social-function-matrix.feature`
fails when a catalogued function has no Examples row, when a seeded persona has
no scenario, when a `pair`/`group` function names neither a journey on disk nor
a written reason, when a probe path stops resolving, or when a declared roster
gap (`expectNoPersona`, today `ROLE_FORUM_MOD`) silently closes.
`tests/scripts/test-e2e-social-function-matrix.sh` runs all of that plus a
seven-mutation battery, and is wired into `make stack-e2e-bdd-check`.

**Adding a function** — add it to `SOCIAL_FUNCTIONS` (id, arity, gate, gateway,
probe path, and either a `journey` that exists on disk or a `pending` reason),
then add one Examples row naming the id. Never spell a function id inline in a
`.feature` without a catalogue entry: the guard cannot see it.

### 2h. FUNCTION — what the user is actually DOING (owncast, tube, games, character tools)

Role, platform, service, env and interface say *who*, *where* and *how*. None of
them says *what*. "owncast is covered" was true of a suite that opened the console
and never asked whether a stream can be published, watched, granted or moderated —
four code paths, four gates, one green tick.

So the media/games domain carries a fourth thing: an enumerated FUNCTION, spelled
once in **`steps/function-catalogue.ts`**. It is deliberately **not** an axis in
`steps/dimensions.ts`: an axis is validated in the `Before` hook for all 573
scenarios, and a vocabulary only one domain uses has no business gating the whole
suite. The function id travels two ways instead:

* as a **step argument**, so the Gherkin says out loud which function it drives:
  `Then the "grant-audit" function is gated by "ROLE_OWNCAST" at "/bff/owncast/**"`
* as a **`@function:<id>` tag**, which the census step reads straight off the
  feature files. Unknown tags are inert — `parseDimensionText` only looks at the
  axes it knows.

Each catalogue entry carries the gateway + url pattern the function really
travels, the role the route-access seed grants there, and a **driveability
verdict**:

| verdict | means | a pending scenario is waiting on |
|---|---|---|
| `ui` | a seeded persona can drive it in a browser today | — |
| `no-audience` | the surface is wired; **no persona in either roster holds the role** | a **seeder line** |
| `absent` | nothing is mounted to drive at all | a **build** |

That difference is the whole point of the verdict: `owncast/publish` unblocks the
day somebody adds one line to `tests/e2e-extra-personas.sh`, and `games/launch`
does not unblock at all until a client exists. Folding both into "pending" would
hide which of the two is one line away.

**The guard is the deliverable, the scenarios are its output.**
`features/uncovered-services/media-games-function-matrix.feature` runs offline and:

1. **censuses** — every catalogued function must be named by a `@function:<id>`
   tag somewhere under `features/`. Add a function, and it goes red until a
   scenario exists. A PENDING one naming what it needs counts; a comment does
   not (comments are stripped before counting).
2. **pins the gate three ways** — the role and pattern written in the feature
   file, the catalogue's copy, and the committed route-access seed must all three
   agree. The seed leg is the one that bites: the gateway is default-deny, so a
   function whose surface has no row is a 403 for everyone however correct the UI
   guard above it looks.
3. **derives the access matrix** — the persona sets are computed by walking BOTH
   rosters (`specs/rbac-roles.ts` and `tests/e2e-extra-personas.sh`) and asking
   who holds a role the seed grants there. Seed one more persona and the computed
   set moves while the written one does not: red, naming exactly who arrived.

It deliberately does **not** model the gateway **admin-bypass**. "Reachable by
exactly `<nobody>`" means *the seed names nobody*, not *nobody gets through* — the
seed's own comments say admins reach a floor row via the bypass, which is why
`/owncast/**`, `/tube/**` and `/social/forum/**` pair no `ROLE_ADMIN`. Who
actually gets through is what the driven `@env:docker` scenarios answer. Two
honest facts beat one blended number.

Verify with `bash ../scripts/test-e2e-func-media-games.sh` (offline; seven
mutations, tree restored on exit).

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

### 4b-bis. `manifest.json` is PARTIAL while the run is in flight

Measured 2026-08-26, and it corrects what `steps/evidence.ts` used to say.
`playwright-bdd`'s `AfterAll` is Playwright's `test.afterAll`, which fires at the
end of **every generated feature spec file** — so `materializeManifest()` rewrites
`manifest.json` dozens of times per run, each time holding only the rows written
so far. On a 115-scenario lane it held 188 rows mid-run while the append log
already held 293, and 407 when the run finished.

The **final** file is complete, so nothing downstream of a finished run is
affected. But a consumer reading `manifest.json` *while the suite is running*
sees a truncated index and will report perfectly good artefacts as unindexed.
Such a consumer must read `manifest.jsonl` instead — the append log has no
window, because a step's artefacts are written and then its rows appended inside
one `AfterStep`.

* in a step: `manifestRowsForScenario()` / `readManifestRows()` already read the
  append log;
* from the Studio / a script:
  `python -m hugmesh_studio --e2e-evidence <run-dir> --e2e-evidence-live`.

### 4c. Asserting on your own evidence

```gherkin
Then the evidence manifest holds a "transcript" artefact for this scenario
And every evidence artefact recorded for this scenario exists on disk
```

These read `manifest.jsonl` (the append log), so they see rows written by
*earlier steps of the same scenario*. This is the anti-decoration assertion for
the evidence lane itself.

### 4d. The CLI entry point — ONE way to run this lane

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

### 4e. Browsing the evidence: `env × interface`

`studio/hugmesh_studio/core/e2e_evidence.py` is the Qt-free reader the Studio's
evidence browser renders. It groups rows `env -> interface -> feature -> scenario
-> step` (that nesting **is** the operator's question order) and verifies the
index against the disk in both directions. Same model in the terminal:

```sh
python -m hugmesh_studio --e2e-evidence test-results --json   # exits 1 if the index and the disk disagree
```

A row whose artefact is gone is rendered **loudly**, never filtered out.

## 5. Verify your feature before you commit

From `tests/e2e`:

```sh
npx bddgen && npx playwright test --list --project=bdd
bash ../scripts/test-e2e-gherkin-harness.sh
bash ../scripts/test-e2e-env-interface-dimensions.sh   # env/interface axes + evidence
bash ../scripts/test-e2e-func-media-games.sh           # the media/games FUNCTION census
bash ../scripts/test-e2e-cli-lane.sh                   # the CLI entry point + evidence summary
bash ../scripts/test-e2e-studio-gui-lane.sh            # the Studio GUI as a driver
```

or, from the repo root, `make stack-e2e-bdd-check` (generation + the fast
guards, no stack needed), `make stack-e2e-bdd-guards` (the axis + Studio-GUI
mutation batteries; minutes) and `make stack-e2e-coverage-check` (the coverage
matrix drift guard — measured 8m33s end-to-end on 2026-08-27: 4m22s for the
full 2105-test lane with a real chromium plus ~3m40s for its six-mutation
battery; a browser store that cannot launch is refused in ~1s with
`SKIPPED-LOUDLY` rather than burning ~29 minutes failing every cell twice; its
own guard, `tests/scripts/test-e2e-coverage-matrix-harness.sh`, proves that
refusal, the restore-under-SIGTERM and the `--retries=0` contract with a stub
playwright in ~25s, runs first inside the make target, and gates every PR from
shell-suites.yml's node job).
`make stack-e2e-bdd` runs the lane against a live mesh,
`make stack-e2e-bdd-env` runs it against whichever mesh `SNAP_ENV` names, and
`make stack-e2e-bdd-evidence` says where the artefacts went.

Both battery guards need `npx playwright` **and** a Qt6 binding; without one they
exit **2** with a `SKIPPED-LOUDLY` line naming the missing package — never 0.

If `bddgen` exits non-zero your feature uses a step nobody defined — that is the
anti-decoration gate doing its job. Define the step or fix the wording; never
delete the assertion.

## 6. `features/coverage/` is GENERATED — never edit it by hand

The operator's requirement is coverage of *every user in every function in every
service*. That is 31 personas × 63 functions = **1953 cells**, and hand-writing
1953 Gherkin rows is decoration by volume: a matrix that is 40% filled looks
exactly like one that is complete. So the coverage lane is **emitted from the
catalogues**, and a drift guard fails the build when the emitted files and the
catalogues stop agreeing.

```
tests/e2e/steps/coverage-catalogue.ts   the FUNCTION catalogue + the access ORACLE
tests/e2e/tools/emit-coverage-matrix.ts the generator
tests/e2e/gen-coverage-matrix.sh        run it   (make stack-e2e-coverage-gen)
tests/e2e/features/coverage/*.feature   GENERATED — 15 files, 2073 scenarios
tests/e2e/steps/coverage.steps.ts       the 12 step definitions they bind to
tests/scripts/test-e2e-coverage-matrix.sh   THE DRIFT GUARD (make stack-e2e-coverage-check)
```

**Adding a persona, a service or a function expands the matrix automatically.**
Add a handle to `tests/e2e-extra-personas.sh`, a `ServiceDef` to
`steps/dimensions.ts` `SERVICES`, or a `ServiceFunction` to
`steps/coverage-catalogue.ts` `FUNCTIONS`, then run
`make stack-e2e-coverage-gen` and review the diff. Skip the re-emit and the
guard goes red naming exactly what has no scenario.

### 6a. Where the expected outcome comes from — and why it is not circular

Each cell's `admitted` / `refused` is computed by replaying the function's probe
path against the **committed** gateway route-access seed
(`specs/cluster/manifests/route-access/initdb/20-schema.sql`, 150 rows, the
artefact the gateways are built from), using the most-specific-pattern-wins model
`specs/rbac-route-access.ts` documents. It is **not** read off
`ServiceDef.accessRole` — that would make the matrix assert one field of one
catalogue against another field of the same catalogue.

The computed value is then **written into the .feature as a literal** at emit
time, and the step **recomputes it at run time** and compares. The literal is the
pin: change the route-access seed, or a persona's roles, without re-emitting and
the cells that moved go red. A step that recomputed and compared with itself
would be green forever — the mutation battery's M4 (an oracle that admits
everyone) exists specifically to prove this lane is not that.

The `pattern` column is pinned for the same reason at one level deeper: a seed
edit that changes **which rule decides** while leaving the outcome alone is the
dangerous shape, because the cell still reads green.

### 6b. What the drift guard actually checks

`tests/scripts/test-e2e-coverage-matrix.sh` (offline; starts nothing):

1. re-emits into a scratch dir and **diffs** against the committed tree;
2. requires `bddgen` to generate and `--list` to collect the lane;
3. derives the expected persona / service / function / persona×service-pair /
   cell sets **from the catalogues** and compares them with the titles
   `playwright test --list --project=bdd` actually reports — measured by
   execution, never by reading the `.feature` files, and **bidirectionally** (a
   scenario naming a function the catalogue no longer carries is also red);
4. runs the whole coverage lane and requires it green with nothing started;
5. breaks production six ways and requires every break to turn it red.

### 6c. Honest limits of this lane

* The access matrix asserts the **contract** (what the committed route-access
  seed decides), not a live gateway. The gateways that enforce that table are
  README-only today — the same limitation `specs/rbac-route-access.ts` already
  documents for the handwritten RBAC specs. When a live enforcer lands, the
  expectations are unchanged; only the step's evaluation target moves.
* 15 of the 63 catalogued function probe paths are labelled `asserted`: no
  committed artefact pins them. The label is in every `function-catalogue` row so
  nobody mistakes a judgement call for a measurement.
* The 126-member procedural swarm (`specs/rbac-roles.ts` `generateSwarm()`) is
  deliberately **out** of the roster: it is generated per run from
  `SWARM_DEFAULTS`, and folding it in would multiply the matrix by five while
  adding one distinct role-set.

## 7. Driving the Studio GUI as an interface

`@interface:studio` builds the REAL `hugmesh_studio.gui.wizard.StudioWizard`
offscreen (`QT_QPA_PLATFORM=offscreen`) through `tests/e2e/studio-driver.py` and
`QWidget.grab()`s it. Each Gherkin step that drives it leaves its own
`widget-grab`, so a walk through the GUI is browsable step by step.

```gherkin
@interface:studio
Scenario: ...
  When I grab the Studio wizard page "localmesh"      # a named page
  When I drive the Studio e2e chooser to "kind"       # drive a control, then grab
  Then the Studio reports the "kind" e2e environment
  And the Studio grab is a non-empty PNG
```

The driver reports **what the page says**, not what the step asked for, and it
raises the tab / scrolls the driven widget into view before grabbing — a
plausible PNG of the wrong screen passes for evidence, which is worse than none.

### 7a. Choosing the environment: ONE channel

The Studio's environment chooser and the terminal use the same mechanism, and
that is the point — two mechanisms drift, and then a GUI run drives a mesh the
label does not name.

| | |
|---|---|
| catalogue | `studio/hugmesh_studio/core/e2e_environments.py` (`docker`, `kind`, `qemu`) |
| channel | `SNAP_ENV` on the spawned process — what `steps/world.ts` reads |
| target | `make stack-e2e-bdd-env` (the same one for all three; the recipe pins nothing) |
| CLI | `python -m hugmesh_studio --e2e-plan --e2e-env kind --json` |

```sh
make stack-e2e-bdd-env                    # docker
SNAP_ENV=kind make stack-e2e-bdd-env      # the kind cluster
SNAP_ENV=qemu make stack-e2e-bdd-env      # a device somebody already booted
```

The Python list and `ENVIRONMENTS` in `steps/dimensions.ts` are **cross-checked**
(`studio/tests/test_e2e_environments.py` parses the TS file), so adding an
environment on one side only goes red. Nothing here ever starts a mesh:
`plan(..., boot=True)` is refused, naming what to run by hand.
