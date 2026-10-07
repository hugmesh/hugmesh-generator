# Emerge plan preview — the resolved package list, up front

During live QA of a running build the operator asked the emerge stage to "fan out
across packages and show the packages that **will be installed**": a list known and
shown up front, collapsed, before anything compiles. This page records how that
list is produced, what it costs and how it fails.

## Why a deliberate emission — the plan is not scrapable

Portage does **not** print its resolved plan during a normal merge. The plan only
appears under `--pretend`. The operator's own build log
(`out/sessions/20260729-223952-9503fa/build-standalone-thick.x86.log`, a local file,
not in the repo) has no "These are the packages that would be merged" line and no
`[ebuild` line. The per-package tree (`studio/hugmesh_studio/core/emerge_packages.py`)
can therefore create a package row only when `>>> Emerging (N of M) atom` says that
package **started**. The total M is free from the first such line. The names of the
packages still to come are not in the stream.

So every builder runs a deliberate, read-only `--pretend` pass right before each
multi-package emerge section and emits the resolved plan itself.

## The wire format (pinned, both sides)

One prefix, four line shapes, no ANSI (`--color=n`), easy to grep:

```
==> Emerge plan: <group> total=<M> binary=<B> ebuild=<E>
==> Emerge plan: <group> <idx>/<M> <atom> via=<binary|ebuild> USE="<flags>"
==> Emerge plan: <group> <idx>/<M> <atom> via=<binary|ebuild>
==> Emerge plan: <group> unavailable reason=<slug>
```

* `<group>` is the emerge-group word (`image|tools|dependencies|
  system|world`) of the merge the plan precedes. The plan comes right **before**
  that section's `==> Emerge group:` banner.
* `<atom>` is the resolved `cat/pn-ver`. Slot, subslot and `::repo` tails are
  stripped: the pass runs `--verbose`, which renders `cat/pn-ver:SLOT/SUB::repo`, and
  `cat/pn-ver` never contains `:`, so everything from the first `:` goes. Cross-merge
  `" to /sysroot/"` tails never reach it.
* `USE="..."` is portage's own flag column, copied **verbatim** when the pretend row
  has one (including portage's `%`/`*` markers). It feeds the GUI's badge columns at
  no extra cost. It is absent when portage printed none.
* `unavailable` slugs: `opt-out`, `pretend-failed`, `pretend-timeout`,
  `parse-mismatch`. Each means *no plan is coming for that group*. The GUI falls back
  to start-time rows and never waits.
* `total=0` is a real reading (a merge with nothing to do), not "plan missing". It is
  only reachable because the pass runs `--verbose`: portage prints its
  `Total: N packages` line under `-v` alone, and without it an empty group and a
  drifted row shape look the same. That is how every `--resume` with `@world` already
  satisfied used to be reported as `parse-mismatch` (issue #319). Real captures of
  both verbose shapes are the test fixtures
  `tests/build-matrix/fixtures/emerge-pretend-plan.verbose*.txt`.
* `via=<binary|ebuild>` is portage's own row kind (`[binary …]` merged from the
  binpkg pool, `[ebuild …]` compiled). `binary=<B> ebuild=<E>` on the header are the
  two counts (B + E == M). Together they give the per-group **binpkg reuse** reading
  issue #46 asked for. The lib also prints one human line per planned group next to
  the wire —
  `[emerge-plan] <group> binpkg reuse: B of M package(s) from the pool (P%), E to compile`
  — so a build log shows how much the pool saved. On the parser side both fields are
  optional (`PlanLine.via/binary/ebuild` are `None` on a pre-#46 line), so old logs
  still replay. `PlanLine.reuse_percent()` is the whole-percent rate for a header, and
  `None` when unknown or when nothing is planned.

The prefix is pinned **once on each side**: `EMERGE_PLAN_PREFIX` in
`scripts/_emerge-plan-lib.sh` (builder) and `PLAN_BANNER_PREFIX` in
`studio/hugmesh_studio/core/emerge_packages.py` (parser). It is the same pattern as
the `==> Emerge group: ` banner. The `tests/build-matrix/check.sh` **EPL** bucket
fails closed if the two differ by a byte.

## Where it runs — and where it deliberately does not

| builder | planned sections | not planned (why) |
|---|---|---|
| x86 | `world`, `image` | `tools`/`system`/`dependencies`: fixed named-atom one-shots (eselect-repository; portage/baselayout/gettext; gentoo-sources) — the list is visible in the script itself, a full resolution buys nothing |
| all nine ARM cross builders | `system`, `image` | `tools`: the host SELinux toolchain, a fixed named list merged only when missing from the build host |

Each platform declares this in `studio/hugmesh_studio/core/progress-tables.json`
(`emerge_plan`: `planned`, and `not_planned` with a reason, together covering that
platform's emitted groups). The shell side (check.sh EPL) and the Python side
(`test_progress_uniformity.py`) both check the declaration against the builders' own
call sites.

## Read-only by construction

The pass runs the **same argument vector** as the merge it precedes, with
`--pretend --verbose --color=n --nospinner --autounmask-write=n` appended. The EPL
bucket asserts that an identical merge invocation follows each `emerge_plan_emit`
call. `--verbose` is what makes portage print the `Total:` line the honesty guards
key on (see `total=0` above). Nothing merges and nothing is written to portage
config. So the plan describes exactly the merge that follows, including `[binary]`
vs `[ebuild]` rows under `--usepkg`. The executed test
(`tests/build-matrix/emerge-plan-emit.sh`) proves the stub emerge is never invoked
without `--pretend`.

## Cost — honest, unmeasured, bounded

**A pretend pass is a second full dependency resolution per planned section. It is
not free. No wall-time figure is quoted here because none was measured.** The feature
was built and gated in a sandbox where real portage resolutions are prohibited, and
an invented number would be worse than an admitted gap. What is known without
measuring:

* The cost is one dependency *calculation* (the `Calculating dependencies` phase) per
  planned section: two per build on every platform. No sources are fetched and
  nothing compiles.
* It scales with the size of the package set, like the calculation phase of the real
  merge that follows. On a warm tree that phase is typically a small fraction of a
  build that compiles hundreds of packages, so the preview doubles only that
  fraction, not the build.
* Sections where a resolution cannot pay for itself (fixed named-atom one-shots) get
  **no** pass. See the table above.

To measure it on a real build: the emission logs
`[emerge-plan] resolving the <group> plan ...` before the pass, and the plan lines
land after it. The timestamp delta in the session log is the true cost on that
hardware, that tree, that day.

Bounds and escape hatches:

* `--no-emerge-plan` (every builder) skips the pass. It is a build-phase escape hatch
  in the `--allow-missing-packages`/`--no-kernel-cache` class, deliberately not a
  Studio field. The artifact is identical either way.
* `EMERGE_PLAN_TIMEOUT` (seconds, default 1800) caps a wedged resolution at a WARN.
  The watchdog is hand-rolled because the command may be a shell function
  (`cross_emerge`), which coreutils `timeout` cannot supervise. The nine ARM builders
  source the lib in the host shell, so the variable reaches it from the environment.
  x86 runs it inside the chroot, so the builder renders it into the payload next to
  the opt-out. The EPL plumbing check asserts both. Carrying only the opt-out once
  made this knob a silent no-op on x86 alone.

## Never breaks a build

Every failure path emits the honest `unavailable reason=<slug>` line, WARNs on
stderr and **returns 0**. The paths are: opt-out, mktemp failure, nonzero
resolution, timeout, and row/Total parse drift. The x86 call sites run inside a
`bash -eo pipefail` chroot, so the return-0 contract is load-bearing, and the test
runs it under exactly that shell. On x86 the lib is staged into the sysroot. If
staging fails, a defined no-op fallback takes over and the payload never aborts. A
cosmetic preview must not cost an image.

## Gating (fail-closed)

* `tests/build-matrix/check.sh` **EPL** bucket, `EPL_EXPECTED=24`: per-builder
  plan-section coverage (10), plan-vs-merge argument parity (10), both-sides
  prefix + reason-slug pin (1), plumbing — default-on var, opt-out arm, lib
  reachability incl. the x86 no-op fallback, and x86 chroot env parity for
  every `EMERGE_PLAN_*` knob (1), the executed behaviour test
  (1), and the progress-tables declaration cross-check (1). A builder that
  loses its plan emission fails CI instead of silently degrading.
* `tests/build-matrix/emerge-plan-emit.sh`: runs the real emission function
  against stub emerges — byte-exact wire golden over 30 rows captured verbatim
  from the operator's own build, edge shapes (`::repo`, cross tails,
  `[binary]`, ANSI, `%`/`*` markers, uninstall/blocks), read-only proof, argv
  pinning, CMD-as-shell-function, opt-out, and all failure paths under
  `bash -eo pipefail`.
* `studio/tests/test_emerge_packages.py`: wire-shape parsing, pin byte-parity,
  reason-slug parity, and no-op proofs (plan lines move no package row, switch
  no group, advance no phase ladder).
* `studio/tests/test_progress_uniformity.py`: the `emerge_plan` declaration
  partitions each platform's emitted groups and matches the builder source.

## Coexistence with the flag-badges emission (queued follow-up)

A separate **badges-Emit** phase is queued. It will emit richer per-package flag data
(`emerge -pv --color=y` plus a description sidecar **file**) from the same builders.
`docs/PACKAGE-FLAG-BADGES.md` holds its ground truth. The two emissions must coexist
and stay separate:

* this feature owns the `==> Emerge plan: ` stdout wire and the
  `emerge-plan preview` sentinel blocks in the builders;
* badges-Emit must use its **own** sentinel blocks and its **own** output file, and
  never extend the plan wire. The plan's `USE="..."` clause is portage's `--pretend`
  column verbatim, left unparsed on the builder side, and stays that way.

GUI use of the plan is partly built. `gui/pages/progress.py` feeds each plan line to
the flag-badge index (`gui/flag_badges.py`, through `parse_plan_line()`), so a
package's USE badges can appear before it compiles. The collapsed up-front package
list (running-jobs-only during the build; partial/full collapse) has no code yet.
