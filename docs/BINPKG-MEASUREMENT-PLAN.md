# Measuring the compile-once speedup of the shared binpkg pools

_State key: **✅ harness shipped and tested on synthetic logs** · **⚠️ no real number
exists**. Nothing in this repository has ever compared a build that filled a binpkg pool
with a build that reused it. This page is the protocol for that comparison and the
instrument that reads its result. Running it needs privileged docker and hours of
build time on the operator's box, so the measurement itself is **operator-only**._

Companion to [`SHARED-BINPKG.md`](SHARED-BINPKG.md), whose "Honest limits" section lists
every figure below as owed.

---

## What is already proven, and what the fingerprint guard does not prove

The guard (`scripts/_binpkg-pool-lib.sh`, regression test
`tests/scripts/test-binpkg-pool-fingerprint.sh`) is a **string comparison over the
rendered `make.conf`**. It proves exactly this, hermetically:

* the pool stamp is `sha256(CHOST + COMMON_FLAGS + CFLAGS + CXXFLAGS + profile + salt)`;
* `-mcpu=cortex-a76`, `a72` and `a53` give three different stamps, so a pool stamped by
  one is **refused** (`FATAL: binpkg pool ABI MISMATCH`, build exits) by the others;
* an empty pool is stamped silently, a matching stamp passes, a non-empty unstamped
  pool is adopted with a warning, a one-time empty-profile stamp is migrated loudly.

It does **not** prove, and no test in the tree can prove:

1. **That portage hits the pool.** The tests prove the pool *paths* agree and the guard
   *permits* reuse. Whether `--usepkg` then merges `[binary]` rather than `[ebuild]` is
   decided by portage (`--binpkg-respect-use`, `--newuse`, dependency/slot matching) and
   is only observable in a real emerge log. This is the speedup question.
2. **That the binaries in the pool were built with the stamped flags.** The stamp is
   written when a pool is first *used*, not when its binaries are *produced*. An
   unstamped non-empty pool is stamped with the *current* build's key and only warned
   about (`pool_fingerprint_guard`, `_pool_has_binpkgs` branch).
3. **gcc / libc / binutils identity of the target pools.** The library header lists
   "gcc/libc ABI" among the keys, but `pool_fingerprint_string` has no such component and
   **no builder passes a `SALT` for a target pool** (`grep -n "sa_pool_guard"` over the ten
   builders shows three arguments each). Only the arm *host-bdep* leg salts on
   gcc and glibc (`sa_host_bdep_pool_salt`). Whether a seed refresh that moves the
   toolchain can leave stale target binaries reused is **unmeasured**, not shown to be
   safe or unsafe; leg D below checks it.
4. **That a reused image boots and runs.** Reuse is a build-time property; the SIGILL
   class is a run-time one.

## The instrument

`scripts/binpkg-reuse-report.py` (test: `tests/scripts/test-binpkg-reuse-report.sh`,
`make binpkg-reuse-report-check`) reads two builder logs and prints:

| figure | meaning |
|---|---|
| compiled / from the pool, per run, per emerge group and host-vs-target | counts of `>>> Emerging` and `>>> Emerging binary` lines, the markers portage itself prints |
| warm reuse rate | warm `binary / (binary + compiled)` |
| compile reduction | `(cold compiled − warm compiled) / cold compiled` |
| hit rate on cold's set | of the atoms cold compiled, how many warm merged from the pool, recompiled, or did not merge |
| pool MISS list | atoms cold compiled that warm compiled **again** despite the pool: the actionable output |
| new work list | atoms warm compiled that cold never saw (changed spec between runs) |
| wall speedup | `cold wall / warm wall`, only when you supply both walls |

```
make binpkg-reuse-report COLD=cold.log WARM=warm.log COLD_WALL=3h20m WARM_WALL=41m MIN_REUSE=90
python3 scripts/binpkg-reuse-report.py --help          # segments, --json, gates
```

**It refuses to call a run a measurement (exit 2)** when: a log has no `>>> Emerging`
line; the cold log is not cold (more than 10 % of its merges came from a pool, or the
guard warned `adopting an UNSTAMPED binpkg pool`); either log holds a guard refusal
(`binpkg pool ABI MISMATCH`); either holds `>>> Failed to emerge`. Gates
(`--min-reuse`, `--min-compile-reduction`, `--min-speedup`) exit 1 when unmet, and an
**unknown** figure (no wall supplied) never passes a gate.

**Wall time is supplied, not parsed.** Builder logs carry no per-line timestamps and
build tools inside them print their own, so an auto-detector would read the wrong
clock. Time each run from outside (`date +%s` before and after, or `time`). It is
whole-run wall (stage3 unpack, kernel, image packing included), so it **understates** the
emerge-only speedup; the compile counts are the exact figure and need no clock.

**Per-image logs hold every run, appended.** The builder writes
`<WORK_DIR>/build-snap-build-<board>.log` (and a session-shared `build.log`), and a
second build appends to it behind a `==== <name> start <stamp> ====` header.
`--list-segments` shows them; `--cold-segment 1 --warm-segment 2` selects one build each.
Default is the last. The segment splitter and the `Emerging` parser were run read-only
against the 84 MB real x86 `build.log` in the shared tree (5 build headers, 301
`Emerging` lines, none `binary`): they read it without error. That proves the line shapes
match a real log; it is not a cold/warm pair and says nothing about reuse.

**x86 caveat.** The x86 builder emerges natively in a chroot, so its `Emerging` lines
carry no ` for <root>`/` to <root>` tail and everything is counted as `target`.

---

## Protocol

### Fixed rules (a measurement that breaks one is not a measurement)

* **Fresh, dedicated `WORK_DIR` per board.** The shared asset root defaults to
  `<WORK_DIR>/shared`, which holds the seed, the distfiles and *every* pool. A reused
  `WORK_DIR` brings old pools in and the "cold" run is not cold. `make` forwards
  `WORK_DIR` into the container (`WORK_DIR=/out`), so a new directory is enough; do not
  rely on `HUGMESH_SHARED_ASSETS` through `make` (it is not forwarded to docker).
* **Same command, same flags, same `JOBS`, same git SHA, same spec files** for both runs.
  Record `git rev-parse HEAD`, `nproc`, `JOBS`, the CPU governor, and run nothing else
  heavy meanwhile (the build slot, `buildslot.sh`, is for that).
* **Pass `--no-kernel-cache`** to both (via the builder flag / `IMG_FLAGS` where the
  channel allows). The signed-kernel cache is a second reuse mechanism; leaving it on
  makes the warm run faster for a reason that has nothing to do with binpkgs.
* **Leave `--no-emerge-plan` off.** The `==> Emerge plan:` lines are how the report
  cross-checks the plan's `binary=` count against what actually merged.
* **Keep the logs.** Copy `build-snap-build-<board>.log` after each run; do not let a
  `make clean` (`rm -rf WORK_DIR`) eat them.

### Leg A: same board, same role, rerun (the core number)

```bash
M=/srv/hugmesh-measure/rpi5        # new, empty, on a disk with room for a pool
mkdir -p "$M"

t0=$(date +%s); make rpi WORK_DIR="$M" RPI_BOARD=rpi5 RPI_ROLES=backend JOBS=$(nproc) \
    IMG_FLAGS='--no-kernel-cache'; echo $(( $(date +%s) - t0 )) > "$M/cold.wall"
cp "$M/build-snap-build-pi5.log" "$M/cold.log"

t0=$(date +%s); make rpi WORK_DIR="$M" RPI_BOARD=rpi5 RPI_ROLES=backend JOBS=$(nproc) \
    IMG_FLAGS='--no-kernel-cache'; echo $(( $(date +%s) - t0 )) > "$M/warm.wall"
cp "$M/build-snap-build-pi5.log" "$M/warm.log"      # holds BOTH builds; segment 2 is the warm one

make binpkg-reuse-report COLD="$M/cold.log" WARM="$M/warm.log" \
    COLD_WALL=@"$M/cold.wall" WARM_WALL=@"$M/warm.wall"
```

`cold.log` already holds only build 1 (default segment `last` = 1) and `warm.log` holds
two, so `last` = the warm one; both defaults are right here. Use `--cold-segment` /
`--warm-segment` against one combined file otherwise. `IMG_FLAGS` is spliced into the
builder command line (`Makefile:282-291`, every platform), and `make rpi`/`make x86`
forward it into the container.

**Confounder: distfiles and the seed.** Run 1 downloads distfiles and the stage3 seed,
run 2 gets them from `<root>/distfiles` and `<root>/seed`, so run 1's wall includes
fetch time that is not compile time. To separate them, add **A2**: delete only the
pool (`rm -rf "$M/shared/pkgdir/snap-build-pi5"`, which is a fresh pool for the guard)
and run once more as a "cold with warm distfiles"; compare A2 against the warm run.
The compile counts are unaffected either way.

**Proposed acceptance (my proposal, not a measured result, set by the operator):**
warm reuse rate ≥ 90 %, hit rate on cold's set ≥ 95 %, MISS list empty or explained
(an atom whose USE differs between roles is a legitimate rebuild under
`--binpkg-respect-use=y`), `MEASUREMENT VALID`. A wall speedup threshold should wait
for the first real figure rather than be guessed.

### Leg B: cross-role reuse through `prebuild-binaries`

The point of `make prebuild-binaries ARCH=rpi5` is that role 2..N reuse a pool compiled
once. Baseline = a role image built with an **empty** pool; treatment = the same role
after a prebuild.

1. Fresh `WORK_DIR` `M1`: build `--role pki` cold. This is the **baseline** log.
2. Fresh `WORK_DIR` `M2`: `make prebuild-binaries ARCH=rpi5 WORK_DIR=M2`, then build
   `--role pki`. This is the **treatment** log.
3. `binpkg-reuse-report --cold <M1 pki log> --warm <M2 pki log>`.

Note `prebuild-binaries` has no docker branch: its recipe calls `$(RPI)`/`$(X86)`
directly, i.e. a **host** build through `sudo`. The arm builders only wire the shared
host-bdep pool when the host-mutation guard says the root is disposable, which means
inside the builder container (`build-rpi5-stage4.sh:3023-3035`: "container-only
feature"), so a plain host `make prebuild-binaries` would leave the 33-49 host tools
unpooled and is not the measurement. Run it in the container, with the same mounts
`DOCKER_RUN` uses (`Makefile:239-243`):

```bash
make ensure-image
docker run --rm --privileged -v "$PWD":/src -v "$M2":/out -w /src \
    -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) hugmesh-builder \
    make prebuild-binaries ARCH=rpi5 WORK_DIR=/out
```

Both this and the later `make rpi WORK_DIR="$M2"` resolve the same
`<WORK_DIR>/shared` root (`/out/shared` inside, `$M2/shared` outside), so the treatment
build finds the prebuilt pool. I have not run this command; confirm it on the day.

The prebuild is built under one role's USE (`PREBUILD_ROLE_RPI`, default `backend`), so
a role whose USE differs rebuilds those atoms; the report's MISS list names them.
Account for the prebuild's own wall (it is part of the cost of reuse) when quoting a
speedup: `baseline wall` against `prebuild wall + treatment wall`.

### Leg C: isolation (must show NO cross-board reuse)

After Leg A on rpi5, in the **same** `WORK_DIR`, build `RPI_BOARD=rpi4` (a72). Expect:

* **target** merges all `compiled` (a new pool `snap-build-pi4`): the report's
  `by root → target` line is the check, and run this as `--cold <leg A cold> --warm <rpi4>`
  only for the numbers, never as a speedup;
* **host** merges (`to /`, the shared `host-amd64-bdep` leg, keyed on the builder's gcc and
  glibc and not on the board) mostly `binary`: this is the #72 section 4 reuse rate, the
  figure `SHARED-BINPKG.md` owes.

Then the guard's real-build proof. The first rpi4 build already created
`shared/pkgdir/snap-build-pi4`, so a plain `cp -a` of the pi5 pool would nest it inside
and prove nothing. Copy **only the stamp** over the pi4 pool's:

```bash
cp "$M/shared/pkgdir/snap-build-pi5/.hugmesh-pool-fingerprint" \
   "$M/shared/pkgdir/snap-build-pi4/.hugmesh-pool-fingerprint"
```

then build rpi4 again. It must die with `binpkg pool ABI MISMATCH` (a76 stamp against an
a72 build). Feed that log to the report as the warm side: it must exit **2**.
Restore the real stamp afterwards (or `rm -rf` the pi4 pool) before reusing that
`WORK_DIR`.

### Leg D: correctness of the reused image

A fast image that SIGILLs is the failure the guard exists for.

1. Boot the leg A **warm** image on the existing QEMU device harness
   (`tests/qemu`, see `docs/RUNNING.md`) and run the same checks as for the cold image.
2. For an a53 target (`--board rpi3`) run a handful of reused binaries under
   `qemu-aarch64 -cpu cortex-a53` (the lowest ISA in the fleet). A cortex-a76-tuned
   binary should fault there; I have not tried it, and whether QEMU's a53 model traps
   LSE atomics and dotprod is the thing to confirm first with a deliberately a76-built
   test program.
3. Toolchain identity (gap 3 above): record `gcc -dumpfullversion` and the glibc version
   of the builder image for runs 1 and 2. They should be equal. To test the gap
   deliberately, rebuild the builder image on a newer stage3, rerun, and read the report's
   MISS list: if portage reuses target binaries across the toolchain change the guard did
   not stop it, and that is a finding to file, not a pass.

### Leg E: x86

The same Leg A with `make x86 X86_ROLE_LIST=pki`, then compare with the **0 % reuse /
2,042 duplicate compiles across 17 images** figure that issue #46 measured, and read the
per-group `binary=` counts the plan lines already carry. Needs root for the chroot
(`mount`, `chroot`), so it is the operator's.

---

## What to record

Fill this in from the report, do not estimate. Every cell is currently empty because no
run has happened.

| board / role | leg | cold compiled | warm compiled | warm reuse % | hit rate % | MISS atoms | cold wall | warm wall | speedup | valid |
|---|---|---|---|---|---|---|---|---|---|---|
| rpi5 / backend | A | | | | | | | | | |
| rpi5 / pki | B | | | | | | | | | |
| rpi4 / backend | C | | | | | | | | | |
| x86 / pki | E | | | | | | | | | |

Then update `SHARED-BINPKG.md` "Honest limits": replace "UNPROVEN" with the measured
figure and the git SHA, hardware and date, or leave the bullet and name what failed.

## What this harness cannot do

* It cannot produce the numbers. It was tested on **synthetic** fixture logs
  (`tests/scripts/fixtures/binpkg-reuse/`, hand-written, labelled as such), so it proves
  the arithmetic and the refusal rules, not any property of a real build.
* It counts lines portage prints. A log lost to truncation, `--quiet` output, or a
  differently formatted portage version would undercount; the `Failed to emerge` and
  no-`Emerging` refusals catch the gross cases, not a subtle format change.
* `Emerging binary` means portage chose the pool, not that the package is correct.
  Leg D is the correctness check; this is not.
* Concurrent builders against one pool (`binpkg-multi-instance` is not enabled; the
  single-writer lock refuses a second writer) are out of scope here and listed as an
  open item in `SHARED-BINPKG.md`.
