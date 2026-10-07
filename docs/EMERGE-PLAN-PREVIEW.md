# Emerge plan preview — the resolved package list, up front

During live QA of a running build the operator asked for the emerge stage to
"fan out across packages and show the packages that **will be installed**" — a
list known and shown up front, collapsed, before anything compiles. This
document is the honest record of how that list is produced, what it costs, and
what its failure modes are.

## Why a deliberate emission — the plan is not scrapable

Portage does **not** print its resolved plan during a normal merge. The
operator's own live build log
(`out/sessions/20260729-223952-9503fa/build-standalone-thick.x86.log`) contains
zero "These are the packages that would be merged" lines and zero `[ebuild`
lines: the plan only appears under `--pretend`. The per-package tree
(`studio/hugmesh_studio/core/emerge_packages.py`) can therefore only create a
package row when `>>> Emerging (N of M) atom` says the package **started** —
the total M is free from the first such line, but the *names* of the packages
still to come are not knowable from the stream.

So every builder now runs a deliberate, read-only `--pretend` pass immediately
before each multi-package emerge section and emits the resolved plan itself.

## The wire format (pinned, both sides)

One prefix, four line shapes, ANSI-free (`--color=n`), greppable:

```
==> Emerge plan: <group> total=<M> binary=<B> ebuild=<E>
==> Emerge plan: <group> <idx>/<M> <atom> via=<binary|ebuild> USE="<flags>"
==> Emerge plan: <group> <idx>/<M> <atom> via=<binary|ebuild>
==> Emerge plan: <group> unavailable reason=<slug>
```

* `<group>` is the emerge-group taxonomy word (`image|tools|dependencies|
  system|world`) of the merge the plan precedes; the plan is emitted
  immediately **before** that section's `==> Emerge group:` banner.
* `<atom>` is the resolved `cat/pn-ver` with its slot/subslot and `::repo`
  tails stripped (the pass runs `--verbose`, which renders
  `cat/pn-ver:SLOT/SUB::repo`; `cat/pn-ver` never contains `:`, so everything
  from the first `:` goes); cross-merge `" to /sysroot/"` tails never reach it.
* `USE="..."` is portage's own flag column copied **verbatim** when the pretend
  row carries one (including portage's `%`/`*` markers) — the flags data the
  GUI's badge columns want, free from the same output. Absent when portage
  printed none.
* `unavailable` slugs: `opt-out`, `pretend-failed`, `pretend-timeout`,
  `parse-mismatch`. Each means *no plan is coming for that group* — the GUI
  falls back to start-time rows, it never waits.
* `total=0` is a real reading (a merge with nothing to do), not "plan missing".
  It is only reachable because the pass runs `--verbose`: portage prints its
  `Total: N packages` line under `-v` alone, and without it an empty group and
  a drifted row shape are byte-identical — which is how every `--resume` with
  `@world` already satisfied used to be reported as `parse-mismatch`
  (issue #319). Real captures of both verbose shapes are the test fixtures
  `tests/build-matrix/fixtures/emerge-pretend-plan.verbose*.txt`.
* `via=<binary|ebuild>` is portage's own row kind (`[binary …]` merged from the
  binpkg pool, `[ebuild …]` compiled) and `binary=<B> ebuild=<E>` on the header
  are the two counts (B + E == M) — the per-group **binpkg reuse** reading
  issue #46 asked for. Until this field existed the parser stripped the bracket
  block and the distinction never left the builder. The lib also prints one
  human line per planned group next to the wire —
  `[emerge-plan] <group> binpkg reuse: B of M package(s) from the pool (P%), E to compile`
  — so a build log answers "how much did the pool save this image?" on its own.
  Parser-side both fields are optional (`PlanLine.via/binary/ebuild` are `None`
  on a pre-#46 line), so old logs still replay; `PlanLine.reuse_percent()` is the
  whole-percent rate for a header, `None` when unknown or when nothing is planned.

The prefix is pinned **once on each side** — builder-side
`EMERGE_PLAN_PREFIX` in `scripts/_emerge-plan-lib.sh`, parser-side
`PLAN_BANNER_PREFIX` in `studio/hugmesh_studio/core/emerge_packages.py` — the
same both-sides pattern as the `==> Emerge group: ` banner, and byte-equality
is gated fail-closed by `tests/build-matrix/check.sh`'s **EPL** bucket.

## Where it runs — and where it deliberately does not

| builder | planned sections | not planned (why) |
|---|---|---|
| x86 | `world`, `image` | `tools`/`system`/`dependencies`: fixed named-atom one-shots (eselect-repository; portage/baselayout/gettext; gentoo-sources) — the list is visible in the script itself, a full resolution buys nothing |
| all nine ARM cross builders | `system`, `image` | `tools`: the host SELinux toolchain, a fixed named list merged only when missing from the build host |

The declaration lives per-platform in
`studio/hugmesh_studio/core/progress-tables.json` (`emerge_plan`:
`planned`/`not_planned`-with-reason, partitioning that platform's emitted
groups), cross-checked against the builders' own call sites from both the shell
side (check.sh EPL) and the Python side (`test_progress_uniformity.py`).

## Read-only by construction

The pass runs the **same argument vector** as the merge it precedes — the EPL
bucket mechanically asserts that an identical merge invocation follows each
`emerge_plan_emit` call — with `--pretend --verbose --color=n --nospinner
--autounmask-write=n` appended (`--verbose` is what makes portage print the
`Total:` line the honesty guards key on — see `total=0` above). Nothing merges, nothing is written to portage
config, and the plan therefore describes exactly the merge that follows,
including `[binary]` vs `[ebuild]` rows under `--usepkg`. The executed test
(`tests/build-matrix/emerge-plan-emit.sh`) proves the stub emerge is never
invoked without `--pretend`.

## Cost — honest, unmeasured, bounded

**A pretend pass is a second full dependency resolution per planned section.
It is not free, and no wall-time figure is quoted here because none was
measured**: this feature was built and gated in a sandbox where running real
portage resolutions is prohibited, and inventing a number would be worse than
admitting the gap. What is known without measurement:

* The cost is one dependency *calculation* (the `Calculating dependencies`
  phase) per planned section — two per build on every platform. No sources are
  fetched, nothing compiles.
* It scales with the size of the package set being resolved, exactly like the
  calculation phase of the real merge that follows it — on a warm tree the
  real merge's own calculation is typically a small fraction of a build that
  compiles hundreds of packages, and the preview doubles only that fraction,
  not the build.
* Sections where a resolution cannot pay for itself (fixed named-atom
  one-shots) get **no** pass at all — see the table above.

To measure it on a real build: the emission logs
`[emerge-plan] resolving the <group> plan ...` before the pass and the plan
lines land after it; the timestamp delta in the session log is the true cost
on that hardware, that tree, that day.

Bounds and escape hatches:

* `--no-emerge-plan` (every builder) skips the pass entirely. Build-phase
  escape hatch in the `--allow-missing-packages`/`--no-kernel-cache` class —
  deliberately not a Studio field; the artifact is identical either way.
* `EMERGE_PLAN_TIMEOUT` (seconds, default 1800) caps a wedged resolution at a
  WARN. The watchdog is hand-rolled because the command may be a shell
  function (`cross_emerge`), which coreutils `timeout` cannot supervise.
  The nine ARM builders source the lib in the host shell, so this reaches it
  from the environment directly; x86 runs it inside the chroot, so the builder
  renders it into the payload alongside the opt-out. Both are asserted by the
  EPL plumbing check — carrying only the opt-out made this knob a silent no-op
  on x86 alone.

## Never breaks a build

Every failure path — opt-out, mktemp failure, nonzero resolution, timeout,
row/Total parse drift — emits the honest `unavailable reason=<slug>` line,
WARNs on stderr, and **returns 0** (the payload-gate tooling-failure
discipline). The x86 call sites run inside a `bash -eo pipefail` chroot, so
the return-0 contract is load-bearing and is executed-tested under exactly
that shell. On x86 the lib is staged into the sysroot; a failed staging
degrades to a defined no-op fallback, never an aborted payload. A cosmetic
preview must not cost an image.

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

A separate **badges-Emit** phase is queued to emit richer per-package flag data
(`emerge -pv --color=y` + a description sidecar **file**) from the same
builders — see `docs/PACKAGE-FLAG-BADGES.md` for its ground truth. The two
emissions are designed to coexist and must stay separate:

* this feature owns the `==> Emerge plan: ` stdout wire and the
  `emerge-plan preview` sentinel blocks in the builders;
* badges-Emit must use its **own** sentinel blocks and its **own** output
  file, never extend the plan wire — the plan's `USE="..."` clause is
  portage's `--pretend` column verbatim, deliberately unparsed, and stays
  that way.

GUI consumption of the plan is partly built. `gui/pages/progress.py` feeds each plan
line to the flag-badge index (`gui/flag_badges.py`, through `parse_plan_line()`), so a
package's USE badges can appear before it compiles. The collapsed up-front package list
(running-jobs-only during the build; partial/full collapse) has no code yet.
