# Shared prebuilt binary packages (binpkg pools)

_State key: **✅ shipped mechanism** · **⚠️ live speedup + correctness UNPROVEN
without a real fleet build** — this track ships the machinery and the safety
guard; the compile-once-and-reuse speedup is owed a real cross-build to prove._

> **Update — the SHARED ASSET ROOT (G1/G2/G3).** #439's pools/distfiles were keyed
> off `BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"`, and the Studio derives
> `BUILD_SUBDIR=wl-<entry-id>` per worklist entry — so **every GUI build got a brand-new
> EMPTY pool and re-downloaded the ~250 MB stage3 seed**. #439's reuse only ever
> materialised for make-driven builds. There is now ONE shared root
> (`<WORK_DIR>/shared` by default) holding the seed cache, the fleet distfiles and the
> per-BOARD pools, resolved in ONE place — `scripts/_shared-assets-lib.sh` — with
> `--shared-assets DIR` / `--no-shared-assets` / `HUGMESH_SHARED_ASSETS`. See
> **[The shared asset root](#the-shared-asset-root-seed--distfiles--pools)** below.

The fleet builders already compile every package once per build
(`FEATURES="buildpkg"` in all six `make.conf` templates) — but four of the five
cross builders never **consumed** those binpkgs, so an arm64 re-run recompiled
NetworkManager/samba/… from source every time. This track closes the
produce→consume loop, adds a **compile-once prebuild phase**, shares the
arch-independent **distfiles** read-only fleet-wide, and — most importantly —
adds the **pool fingerprint guard** that makes cross-role/cross-run binpkg reuse
*safe* against the aarch64 `-mcpu` SIGILL class portage cannot catch on its own.

---

## THE #1 SAFETY INVARIANT (violate it and images SIGILL at runtime)

Binpkg reuse (`--usepkg`) is **only** safe when **all** of
`{CHOST, exact CFLAGS/-mcpu, CXXFLAGS, profile, gcc/libc ABI}` match between the
pool's producer and the consumer.

`--binpkg-respect-use=y` checks **USE only** — it does **NOT** compare CFLAGS,
`-mcpu`, CHOST or profile. Every aarch64 board shares
`CHOST=aarch64-unknown-linux-gnu` but differs in `-mcpu`:

| board             | builder                        | `-mcpu`             | ISA baseline |
|-------------------|--------------------------------|---------------------|--------------|
| Raspberry Pi 5    | `build-rpi5-stage4.sh --board rpi5` | `cortex-a76`   | ARMv8.2-A (LSE atomics, dotprod) |
| Raspberry Pi 4    | `build-rpi5-stage4.sh --board rpi4` | `cortex-a72`   | ARMv8.0-A |
| Raspberry Pi 3    | `build-rpi5-stage4.sh --board rpi3` | `cortex-a53`   | ARMv8.0-A |
| La Frite family   | `build-frite-stage4.sh`             | `cortex-a53`   | ARMv8.0-A |
| Jetson Orin       | `build-jetson-stage4.sh`            | `cortex-a78ae` | ARMv8.2-A |
| Orange Pi 5 / 5+  | `build-orangepi5-stage4.sh`         | `cortex-a76.cortex-a55` | ARMv8.2-A |
| Orange Pi Zero 2  | `build-orangepi-zero2-stage4.sh`    | `cortex-a53`   | ARMv8.0-A |
| Orange Pi Zero 2W | `build-orangepi-zero2w-stage4.sh`   | `cortex-a53`   | ARMv8.0-A |
| Orange Pi Zero 3 | `build-orangepi-zero3-stage4.sh`   | `cortex-a53`   | ARMv8.0-A |
| Orange Pi 3 LTS  | `build-orangepi3-lts-stage4.sh`    | `cortex-a53`   | ARMv8.0-A |
| Orange Pi 4 LTS  | `build-orangepi4-lts-stage4.sh`    | `cortex-a72.cortex-a53` | ARMv8.0-A |
| x86               | `build-x86-host-stage4.sh`          | `-march=x86-64-v2`  | — |

A binpkg tuned for `cortex-a76` (LSE atomics + dotprod) executed on an
`a53`/`a72` (ARMv8.0-A) hits an **illegal instruction → SIGILL** at runtime.

**Therefore the pool key is PER-BOARD (per `BUILD_SUBDIR`), never per-arch.** A
pool may be reused across the **roles** of the SAME board, **never** across
boards. No change in this track may ever let one board's `--usepkg` read another
board's pkgdir.

---

## The pool key and where pools live

A pool is the `pkgdir` under a build's per-board `BUILD_SUBDIR`:

- **cross builders:** `PKGDIR="@@WORK_DIR@@/pkgdir"` → `${BUILD_ROOT}/pkgdir`,
  where `BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"`. Lives **outside** the
  sysroot, so it survives sysroot wipes and persists across roles of that board.
- **x86 (issue #46):** the chroot's `PKGDIR` stays `/var/cache/binpkgs`
  (make.conf), but with the shared root on, `mount_chroot` **bind-mounts the
  shared per-arch pool** `<root>/pkgdir/snap-build-x86` at that path — every
  amd64 role of every worklist entry reads/writes ONE pool that survives the
  per-entry `wl-<id>` sysroot. With `--no-shared-assets` the pool is the legacy
  chroot-internal one (reuse then needs a shared sysroot via `--resume`).

`BUILD_SUBDIR` defaults are per-board:

| builder | default `BUILD_SUBDIR` |
|---|---|
| x86 | `snap-build-x86` |
| rpi5 **`--board rpi5`** | `snap-build-pi5` |
| rpi5 **`--board rpi4`** | `snap-build-pi4` |
| rpi5 **`--board rpi3`** | `snap-build-pi3` |
| frite | `snap-build-frite` |
| jetson | `snap-build-jetson` |
| orangepi5 | `snap-build-orangepi5` |
| orangepi-zero2 | `snap-build-orangepizero2` |
| orangepi-zero2w | `snap-build-orangepizero2w` |
| orangepi-zero3 | `snap-build-orangepizero3` |
| orangepi3-lts | `snap-build-orangepi3-lts` |
| orangepi4-lts | `snap-build-orangepi4-lts` |

> **Shared-asset update.** The table above still names each board's **default**
> `BUILD_SUBDIR` — but that string is now the **pool KEY**, not the pool's parent
> directory. With the shared root on (the default), the pool is
> `<root>/pkgdir/<board-key>`, resolved from `--board` / the builder's board constant
> and **never** from `BUILD_SUBDIR`. That is the G2 fix: a Studio `wl-<entry-id>`
> subdir must own the build TREE (sysroot/staging/log — a deliberate, tested
> invariant) without fragmenting the POOL. `--no-shared-assets` restores the old
> `${BUILD_ROOT}/pkgdir` layout byte-for-byte.
>
> The SIGILL property is unchanged and is what matters: **one pool directory per
> board, never shared across boards**, plus the fingerprint guard below.

> **Lane 2 fix.** Before this track `build-rpi5` used the single literal
> `snap-build-pi5` for **all three** Pi boards (set before argv parse; `--board`
> didn't change it). Because rpi5 already consumed binpkgs (`--usepkg`),
> building rpi5 then `--board rpi4` into the same `WORK_DIR` reused
> cortex-a76 binpkgs into an a72/a53 image → **latent SIGILL**. The default is
> now resolved from `--board` **after** the parse and **before** `BUILD_ROOT` is
> derived. An explicit `--build-subdir NAME` / `BUILD_SUBDIR=NAME` env
> (e.g. a worklist `wl-<id>`) always wins.

Non-Pi ARM board tables (frite `la-frite`/`le-potato`/`sweet-potato`; orangepi5
`orange-pi-5`/`orange-pi-5-plus`) select a defconfig/DTB but **not** a different
`-mcpu`, so those boards safely share one pool per builder.

---

## The fingerprint guard — the load-bearing SIGILL safety net

Directory isolation (per-board `BUILD_SUBDIR`) is the *primary* guard, but a
stray `BUILD_SUBDIR=` env, a mis-typed `--build-subdir`, or a deliberately shared
custom pool could still point two ABI-incompatible builds at one pkgdir — and
portage would happily `--usepkg` the wrong-`-mcpu` binary. Nothing else in the
pipeline compares CFLAGS before reuse.

`scripts/_binpkg-pool-lib.sh` (sourced by all six builders) closes that hole:

- **Fingerprint** = `sha256(CHOST + COMMON_FLAGS + CFLAGS + CXXFLAGS + profile
  [+ salt])`, read from the **rendered** `make.conf`. For the cross builders the
  rendered `CFLAGS` is `-mcpu=<board-cpu> …`, so the fingerprint **does** capture
  the `-mcpu` portage ignores.
- **Preflight** (`pool_fingerprint_preflight`) runs in every build, just before
  the first `--usepkg` emerge:
  - **absent stamp, EMPTY pool** → write `${PKGDIR}/.hugmesh-pool-fingerprint`
    fresh, proceed silently (the normal fresh-pool path);
  - **absent stamp, pool already holds binpkgs** → adopt (stamp fresh) **but WARN
    loudly** naming the SIGILL risk + the flush command. An unstamped non-empty
    pool is the first-rollout case (every pre-guard pool is unstamped) and the
    manually-shared-`--build-subdir` case; hard-refusing would nuke every
    legitimate same-board cache, so the risk is made *visible* instead;
  - **matching stamp** → proceed (safe same-board/role reuse);
  - **mismatched stamp** → **die** with a clear SIGILL/ABI-mismatch message,
    refusing the reuse.

**Why this guard — not just the per-board directories — is the real net.** The
per-board `BUILD_SUBDIR` split is the primary isolation, but if a future change
regressed it (e.g. reverted rpi5/rpi4/rpi3 back to one shared `snap-build-pi5`),
the fingerprint preflight still **fails closed at build time**: the a76 build
stamps the pool, the subsequent a72 build sees the mismatch and *dies* rather
than shipping a SIGILL image. So the safety property is enforced by code that
runs on every real build — not only by the (non-gating) regression tests below.

Hermetic proof: `tests/scripts/test-binpkg-pool-fingerprint.sh` (a76/a72/a53 →
three distinct fingerprints from `-mcpu` alone; wrong stamp refuses; matching
passes; empty pool writes fresh silently; a non-empty unstamped pool adopts +
warns; a correctness **salt** flips it). These are registered as **non-gating**
smokes per the harness convention — the *live* guard above is what enforces the
invariant; the tests are regression coverage for it.

---

## Shared read-only distfiles (arch-safe fleet-wide)

Distfiles are arch-independent **source tarballs**, so ONE fleet-wide pool is
safe on every board. `--distdir DIR` (or `SNAP_DISTDIR_SRC` in the env) exposes
that cache **read-only** — via a bind-mount + `PORTAGE_RO_DISTDIRS` on x86
(chroot), or by appending `PORTAGE_RO_DISTDIRS="<dir>"` to the rendered
`make.conf` on the cross builders (host emerge). **New** fetches still land in
each build's private `DISTDIR` (`${BUILD_ROOT}/distfiles`), so the shared pool is
never written. No ABI risk. Proof: `tests/scripts/test-arm-ro-distdir.sh`.

---

## The shared asset root (seed + distfiles + pools)

`scripts/_shared-assets-lib.sh` is the ONE resolver; all ten stage4 builders source it
and nothing duplicates the path logic.

```
<root>/seed/<arch>/<stage3-basename>   stage3 seeds, keyed per ARCH   (G1)
<root>/distfiles/                      fleet-wide source tarballs     (G3)
<root>/pkgdir/<board-key>/             binpkg pools, keyed per BOARD  (G2)
```

**Where `<root>` comes from** — precedence, highest first:

| # | source | typical caller |
|---|---|---|
| 1 | `--shared-assets DIR` | the Studio (`BuildDriver._shared_assets_args`) |
| 2 | `HUGMESH_SHARED_ASSETS=DIR` | an operator putting the pool outside `WORK_DIR` |
| 3 | `<WORK_DIR>/shared` (default) | `make`, `build-all-roles.sh`, a hand-run builder |

`--no-shared-assets` (or `HUGMESH_SHARED_ASSETS=off`) opts out entirely: seed,
distfiles and pool fall back to the legacy per-`BUILD_ROOT` paths.

**Why the default is under `WORK_DIR`.** The Makefile's `DOCKER_RUN` already mounts
`-v $(WORK_DIR):/out`, so a root under `WORK_DIR` is reachable in-container with **no
new mount** — the builder just gets `/out/shared`.

**Why the Studio must be explicit.** A GUI run's work dir is the PER-SESSION
`<out>/sessions/<id>` (`build_sessions.session_workdir`), so the builder-side default
would resolve per session and share nothing. `BuildDriver` climbs back to the stable
`<out>` and passes `--shared-assets <out>/shared` on **every** dispatched build — so it
also appears in the **command preview** the operator reads before dispatch.

Under docker the Studio always gives the root its own **read-write** bind mount at the
fixed container path `/shared`. This is a deliberate deviation from "a root under
`WORK_DIR` needs no new mount", which holds for `make` (where `WORK_DIR` *is* the mount)
but **not** for the Studio, whose mount is the per-session `<out>/sessions/<id>:/out`
while the root sits at the stable `<out>/shared` above it — outside that mount. Rather
than emit two different in-container spellings depending on whether a session override
happens to be set, the path is always `/shared`, which buys:

* one spelling in the command preview and the build log on every mount layout; and
* the **golden work-dir invariant** stays true — a session work dir may still change
  only the `-v <host>:/out` value and nothing else, because the shared root is derived
  from the stable `<out>` and is byte-identical with and without the override
  (`studio/tests/test_build_driver_workdir.py`).

The mount is read-WRITE (the build creates and writes the seed cache, the pool and the
distfiles), which is why it is deliberately NOT one of `DOCKER_ASSET_FIELDS`' read-only
inputs. **Make-driven docker builds need no change at all:** `DOCKER_RUN` runs
`make … WORK_DIR=/out`, so the builder's own `<work-dir>/shared` default resolves to
`/out/shared` — the host's `$(WORK_DIR)/shared` — with zero new mounts.

The driver emits the leg *between* `-w`/`-j` and the config args, never after them:
`cfg.to_cli_args()` ends with the operator's raw `extra_flags`, and the builders parse
argv last-flag-wins, so a hand-typed `--no-shared-assets` there must still win.

> **`make clean` now also clears the cache.** `clean` is `rm -rf $(WORK_DIR)`, and the
> default root lives under `WORK_DIR` — so it discards the seed cache and every pool
> along with the build trees. That is the honest reading of "wipes WORK_DIR", but if you
> want the cache to survive a clean, put it elsewhere with
> `HUGMESH_SHARED_ASSETS=/srv/hugmesh-assets`.

### Seed cache — cached, but never trusted

`sa_seed_acquire` returns a seed path only after running the caller's verifier
(`dlv_verify_stage3`: GPG-signed DIGESTS + SHA512/SHA256) on the exact file it is about
to hand back — **cache hit or fresh download**. Caching must never turn "verified once"
into "trusted forever": a poisoned cache is caught by exactly the code that catches a
poisoned mirror. On failure the file is deleted, re-fetched **once**, re-verified, and a
second failure **fails closed** (no path is returned, so the builder cannot unpack
anything). Seeds are keyed per arch by directory **and** by basename, so an `amd64`
tarball can never be handed to an `arm64` build even if it is misfiled.

### Distfiles

The cross builders point their **writable** `DISTDIR` at `<root>/distfiles` (appended to
the rendered `make.conf`, where the last assignment wins — the same idiom the
`PORTAGE_RO_DISTDIRS` append already used). Distfiles are arch-independent SOURCE
tarballs and portage verifies each against the ebuild Manifest, so one fleet-wide cache
is safe, and portage takes its own per-file fetch lock. x86 emerges inside a chroot, so
it **reads** that same directory through the existing read-only bind +
`PORTAGE_RO_DISTDIRS` path (used when no explicit `--distdir` was given) and writes its
own private `DISTDIR`. An explicit `--distdir` naming the shared dir is dropped rather
than listed twice.

**The x86 fetch is bounded** (issue #322). Portage's default fetcher is `wget -t 3 -T 60`,
and `-T` is a *read* timeout: it fires only when no byte at all arrives, so a transfer
that stalls but still trickles is never abandoned — on 2026-09-08 a 1.02 GB GitHub
archive (`media-fonts/noto`) stopped at 10.3 %, moved 0 bytes in 22 minutes, and blocked
the whole standalone-thick payload for over an hour with no gate and no WARN. wget has no
minimum-rate option; curl does. `specs-x86/portage/make.conf.tmpl` therefore sets
`FETCHCOMMAND`/`RESUMECOMMAND` to curl with `--speed-limit 10240 --speed-time 60`
(abort under 10 KiB/s over any 60 s window) plus curl's own bounded retries, so the worst
case per URI is minutes, after which portage moves to the next mirror. `RESUMECOMMAND` is
a small `bash -c` wrapper: it resumes (`-C -`) where the server honours `Range`, and where
it does not — GitHub's archive endpoint answers a `Range` request with `200`, on which curl
exits 33 without downloading — it falls back to a fresh bounded fetch of the whole file.
`tests/scripts/test-x86-fetchcommand-bound.sh` executes both against local trickling,
silent, 404, Range-ignoring and Range-capable servers. The ARM cross specs still use the
default wget fetcher; the bound has only been applied where the stall was measured.

A rate floor bounds each URI, but a *bounded failure* of a single-source file still drops
its package under `--keep-going`, and that drop only surfaces hours later at the
requested-atom completeness gate. So the x86 build also **pre-fetches the whole payload
before the first merge** (`scripts/_emerge-prefetch-lib.sh`, called from
`build-x86-host-stage4.sh` immediately before the `system` group; hugmesh-generator#322
slice 2, decision 24). One foreground `emerge --fetchonly` resolves `@world` plus the role
payload with the same `--update --deep --newuse --keep-going` and the same exclusions as
the two real merges, so the graph fetched is the graph merged, and `--keep-going` makes one
run report **every** unfetchable file rather than stopping at the first. Three attempts,
then the build **aborts before anything has been compiled**, naming each distfile portage
could not download. `--allow-missing-packages` — the same opt-out the completeness gate
honours — downgrades that abort to a warning, and nothing else does.

The accepted cost is that fetching no longer overlaps compiling: roughly **+30-55 minutes
on a cold `DISTDIR`** at ~3 MB/s, and about **zero on a warm one**, which is what a
`PORTAGE_RO_DISTDIRS` fleet cache gives you. A *resolver* wall (keyword, mask, USE, slot
conflict) is not a fetch failure: the pass prints a loud `PRE-FETCH SKIPPED` line, says the
build continues unprotected, and returns success — the payload merge crosses those with
`--autounmask-continue=y`, and the payload-plan gate (#223) is what judges them. The pass
deliberately passes no autounmask flag itself, so it can never write `package.use` against
the pre-update portage. `tests/scripts/test-x86-prefetch-gate.sh` executes the lib against a
stub `emerge` reproducing each of those outcomes and pins every call site in the builder.

### Concurrency

Mutation of the shared root is serialised with `flock` (`sa_lock_run`), re-entrant so a
build can never deadlock against its own lock — the same sibling-lockfile discipline as
`build-x86-host-stage4.sh`'s `acquire_build_lock`. Additionally, a shared pool takes a
**long-lived exclusive writer lock** (`sa_pool_hold`) for the life of the build: the
tree has no `binpkg-multi-instance`, so two concurrent writers into one pkgdir overwrite
each other's package instances (invalidation rule #3 below — which sharing pools across
worklist entries is what makes REACHABLE). It is non-blocking, because a silent
multi-hour wait would be worse than a fast, actionable failure: the second build is told
to wait or to re-run with `--no-shared-assets`. The kernel releases flocks on process
death, so a crashed build never wedges the next one.

Hermetic proof: `tests/scripts/test-shared-build-assets.sh` (EXECUTED decisions, not
parse assertions): cache hit / cache miss / wrong-arch seed / corrupted seed / poisoned
cache recovery / fingerprint-mismatched pool refusal / two concurrent writers serialising
/ re-entrancy / the pool writer lock / the opt-out — plus a structural sweep asserting
all ten builders carry the wiring. Studio side:
`studio/tests/test_shared_build_assets.py`.

## The host-side BDEPEND pool (arm cross builds; PR #72 §4)

Cross builds merge every BDEPEND **"to /"** — the builder container's own root —
under the crossdev wrapper's `--root-deps=rdeps`, and the wave-1 measurement
(#46) found 33–49 such amd64 host tools source-compiled *per arm image* because
the container's default `PKGDIR` dies with the container. These are host tools
**executed by the builder** (checkpolicy, m4, setuptools-scm chains, the host
SELinux toolchain, …); the target board's `-mcpu` is irrelevant to them, so ONE
leg serves every arm board:

    <root>/pkgdir/host-amd64-bdep

wired by `build-rpi5-stage4.sh` / `build-jetson-stage4.sh` (the two builders the
#72 design named; the other cross builders are mechanical follow-ups):

- **Keying — HOST identity, never the target's.** The same
  `pool_fingerprint_preflight` stamp, computed from the HOST `/etc/portage/make.conf`
  ABI values + the HOST profile (`readlink -f /etc/portage/make.profile`), salted
  with the builder-toolchain identity (`sa_host_bdep_pool_salt`: host gcc + glibc
  versions — the ABI carriers an image rebuild changes when it matters;
  `HUGMESH_HOST_BDEP_SALT` is the channel for #72's exact image-digest keying, set
  it on every launch channel or on none). The #44-style empty→non-empty-profile
  stamp **migration** applies unchanged.
- **Flush, not refuse, on mismatch.** Unlike a target pool, a stale HOST tool is a
  build-time hazard on the builder itself, never a shipped-image SIGILL — and a
  mismatch means "the builder identity changed", so the old binpkgs are garbage by
  definition. `sa_host_bdep_pool_guard` therefore **empties and restamps the leg,
  loudly**, instead of bricking every arm build until an operator hand-flushes a
  shared directory.
- **HOST make.conf only.** `PKGDIR` + `FEATURES="… buildpkg binpkg-multi-instance"`
  are appended to the HOST `/etc/portage/make.conf` behind
  `hostguard_mutation_allowed` (a real machine is never rewired; unavailable ⇒ the
  build proceeds unpooled, loudly). The sysroot's rendered make.conf keeps its
  per-board `POOL_DIR`, so a target binpkg can never land in — or be taken from —
  the host leg. Consumption is the already-global `--usepkg=y
  --binpkg-respect-use=y` on `cross_emerge` plus the same flags on the native
  host-tools emerge.
- **Locking — `binpkg-multi-instance`, the design's stated alternative to
  `sa_pool_hold`.** Host bdeps merge to `/` *during* the hours-long target
  cross-emerge, so the leg's write window IS the target emerge: holding the
  single-writer lock across it would serialize all arm builds of different boards
  end-to-end (exactly what #72's design forbids), and releasing it early would
  leave the actual writes unguarded. With multi-instance on the HOST config only,
  each concurrent build packs its own build-id instance and portage serializes the
  `Packages`-index update under its own index lock. Target pools remain
  single-writer (`sa_pool_hold`) — the "no binpkg-multi-instance" rule above still
  holds for them.

Hermetic proof: `tests/scripts/test-host-bdep-pool.sh` (gated fail-closed in the
build matrix's SBP family): leg shape, host-keyed stamp, idempotent + value-aware
make.conf wiring, flush-on-identity-change (never refuse, never silent), no flush
on match, #44-consistent migration, unpooled fallback, and the structural sweep
over both builders including target/host `PKGDIR` isolation.

## Prebuild-once workflow

```sh
# 1. compile a platform's role-UNION binpkg pool ONCE (per board), no image:
make prebuild-binaries ARCH=rpi5 BOARD=rpi4        # -> out/shared/pkgdir/snap-build-pi4
make prebuild-binaries ARCH=x86                    # -> out/shared/pkgdir/snap-build-x86

# (with --no-shared-assets the ARM pool is the legacy out/snap-build-pi4/pkgdir
#  and the x86 pool falls back to chroot-internal — see the caveat below.)

# 2. later per-role image builds reuse the pool via --usepkg (already wired):
make rpi RPI_BOARD=rpi4                             # backend/frontend/… reuse pi4 pool
make x86                                            # x86: shared pool, no --resume needed
```

> **x86 caveat — `--no-shared-assets` only.** With the shared root ON (the
> default), the x86 pool lives at `<root>/pkgdir/snap-build-x86`, OUTSIDE the
> sysroot — it survives sysroot wipes and fresh `wl-<id>` subdirs exactly like the
> ARM pools, and a plain `make x86` after `make prebuild-binaries ARCH=x86` reuses
> it (issue #46). Only under `--no-shared-assets` does the x86 pool revert to
> chroot-internal `/var/cache/binpkgs`; a non-`--resume` build then wipes the
> sysroot (the wipe-on-non-resume guard) and the pool with it, so thread
> `RESUME=--resume` into the consuming build in that legacy mode.

- **Union feed:** `python3 -m hugmesh_studio.core.prebuild_union <platform>`
  prints the sorted role-union atom list — `set().union` over the EXISTING
  `package_catalog.default_set` for every `(platform, role)` cell
  `role_cells()` enumerates from `ROLE_CHOICES`. **No new resolution logic.**
- **`--packages-only`** runs the emerge that populates `PKGDIR`, then exits
  **before** image assembly, retaining the binpkgs (reuses the `--cached`
  keep-branch semantics; the cross pools live outside the sysroot and are never
  stripped). `--print-plan` reports `PLAN_PACKAGES_ONLY=1`.
- **USE note (honest):** the pool is built under the prebuild role's USE. A later
  role whose make.conf USE differs (`CLIENT_USE`/`GPU_USE`/`VIDEO_CARDS`)
  rebuilds *just those* atoms (`--binpkg-respect-use=y` + `--newuse`) — **safe,
  never a wrong reuse**, but not a 100% cache hit. The bulk (USE-invariant base
  system, k8s, …) is reused.

Channels: CLI (`--packages-only`) · make (`prebuild-binaries`) · ncurses
(**Build → Prebuild shared binpkg pool** + **Options → Shared distfiles**) ·
Studio (the headless `prebuild_union` module only — no wizard page in v1).

---

## Invalidation rules (flush the pool)

A pool must be **flushed** (`rm -rf <pkgdir>`) or keyed to a new directory on any
change that alters the produced binaries' ABI or correctness:

1. **CHOST / `-mcpu` / CFLAGS / CXXFLAGS / profile / gcc-major / glibc ABI** —
   any of these changes the ABI. The fingerprint guard catches a same-directory
   reuse across such a change (dies); a *new* board/CFLAGS should use a new
   `BUILD_SUBDIR` (the default already does this per board).
2. **`INSTALL_MASK` / `package.mask` correctness pins** — e.g. the gettext
   empty-basename `.mo` collision fix (`INSTALL_MASK=".../LC_MESSAGES/.mo"` +
   `specs-x86/portage/package.mask/gettext`): a binpkg built **before** that pin,
   served from a stale pool, re-breaks the merge (the 2026-07-08 build lost 143
   packages to it). There is no automatic eclean on a pin change — **flush on any
   such correctness pin**, or bump the fingerprint via the `salt` argument
   (`pool_fingerprint_of MAKECONF PROFILE SALT`) so the guard forces a rebuild.
3. **Single-writer per pool.** The tree overwrites a single binpkg instance
   (no `binpkg-multi-instance`), so two concurrent builds into one pool race.
   This used to be satisfied *by accident* — the worklist path isolated each entry
   under its own `BUILD_SUBDIR=wl-<id>`, which is precisely the fragmentation G2
   removed. With one pool per BOARD the rule is now **enforced**: `sa_pool_hold`
   takes a long-lived exclusive `flock` on `<pool>.writer.lock` and a second
   concurrent build of the same board is refused fast (wait, or `--no-shared-assets`).

---

## The signed-kernel artifact cache (G4)

`scripts/_kernel-cache-lib.sh` caches a **built kernel** so images of the same board
stop recompiling (and re-signing) an artifact the fleet already has. It lives inside
the shared asset root, so it inherits that root's resolution, docker reachability and
opt-out:

```
<root>/kernel/<board>/<cache-key>/manifest        the four key components + payload digests
<root>/kernel/<board>/<cache-key>/payload/boot.tar     kernel image, initramfs, unsigned UKI, DTBs
<root>/kernel/<board>/<cache-key>/payload/modules.tar  the /lib/modules/<kver> tree
<root>/kernel/<board>/<cache-key>.lock            sibling flock (share-lane discipline)
```

### The cache key — four components, all required

`kc_cache_key BOARD KVER CONFIG-DIGEST SIGNING-KEY-FP` is the **only** function that
derives a key, and it hashes a labelled, newline-framed record of all four:

| # | component | why it is in the key |
|---|---|---|
| 1 | **board** | different `-mcpu`, defconfig and DTBs (`--board`, never `BUILD_SUBDIR`) |
| 2 | **kernel version** | the source tree, read *before* the build (`kc_kver_from_srctree`) |
| 3 | **config digest** | the `.config` seed **and every fragment**, in application order — plus the non-fragment inputs that still decide the cached artifacts (see below) |
| 4 | **signing-key fingerprint** | the identity that signs the fleet's kernels |

**Why component 4 exists.** The operator's premise is that *the same keys sign every
device*, which is exactly what makes a kernel reusable across images. The corollary is
the dangerous part: when the fleet is **re-keyed**, every cached artifact belongs to a
**retired** key, and a cache keyed only on board+version+config would keep serving them
forever, silently. Re-keying is the moment you most need a miss. So the key identity is
in the key, and `tests/scripts/test-kernel-artifact-cache.sh` case **E** proves a
re-keyed build misses — including when an old entry is *renamed* onto the new key's
directory (the manifest is re-checked, the entry is refused and pruned).

**Component 3 is wider than "the .config"**, because the payload includes the initramfs
and the unsigned UKI. `kernel_cache_inputs()` folds in everything else that decides
those: `--kernel-builtin` and its keep-as-module list, the UKI name, the dracut
drop-ins, `/etc/default/grub` (the kernel cmdline baked into the UKI), and the **vdb
versions of `sys-kernel/dracut` and `sys-apps/systemd-utils`** — so a dracut upgrade
invalidates the initramfs even when the kernel config has not moved. On the cross
builders it folds in the board defconfig name, the cross target, `-mcpu`, the kernel
image filename and the DTB prefix.

**Any component unavailable ⇒ MISS.** `kc_cache_key` returns nothing unless all four are
present and well-formed; the builders treat "no key" as a permanent miss for that build
(nothing looked up, nothing stored). There is deliberately **no** degraded 3-component
key: an unavailable component can only ever cost a rebuild, never widen what an entry is
allowed to match.

### Key material never touches the cache

* `kc_key_fingerprint` emits **only** a SHA-256 over the **public half** — the DER of an
  X.509 certificate (`x509:…`) or the DER SubjectPublicKeyInfo derived from a key
  (`spki:…`). The private half is never printed, copied or stored, and the two tags keep
  a cert and a bare key from being conflated into one identity.
* The manifest records that fingerprint and nothing else about the key — no path, no
  subject, no serial.
* `kc_store` **refuses** any payload file containing a PEM private-key header, so a
  builder mis-pointed at a key directory fails loudly instead of publishing key material
  into a shared, fleet-visible tree.

> A bug found and fixed while building this: a failed `openssl … | sha256sum` pipeline
> still emits the SHA-256 of the *empty string*, so an unreadable key file was being
> reported as a perfectly good `x509:e3b0c442…` identity — which would have collapsed
> **every** keyless build onto one shared cache key. Each branch is now gated on an
> `openssl -noout` probe and the empty digest is rejected explicitly. Regression: case
> **A5**.

### A cache is never a gate bypass

Restoring a kernel replaces the **compile**, never a **check**. The x86
disk-initramfs gate, `build_img`'s seal gate, the Secure Boot signing step and the cross
builders' requested-atom payload gate all sit **outside** the cache branch and run
identically on a hit and on a miss. That is asserted by **mutation**: case **J** builds a
cache entry whose `/boot` has a kernel but *no initramfs*, restores it on the hit path,
and requires the extracted real gate to fail the build — then deletes the gate from the
same harness and requires the bad restore to sail through. If the gate ever stopped
being load-bearing, J3 would fail.

**Signing is NOT skipped on a hit.** On x86 the cache stores the *unsigned* UKI
(`*-unsigned.efi`), because the store runs before the Secure Boot step and the signing
step lives outside the kernel phase entirely. So a hit restores the compiled content and
then `sbsign` runs as usual — **every shipped artifact is signed by the key in effect at
build time**, never by a signature lifted out of the cache. The fingerprint is in the key
anyway, so cached content can never cross a trust-domain boundary; re-signing simply
means the cache can never be the thing that ships a stale signature.

The one thing a hit *does* skip is the in-tree KSPP/SELinux/k8s/LSM/LUKS `.config`
assertions. They are safe to skip because they are a pure function of (kernel source
tree, defconfig, fragments) — precisely what components 2 and 3 pin. Change any of them
and the key changes.

### Validation, pruning and locking

`kc_lookup` re-checks the manifest's four components against what *this* build derived
and re-hashes **every** payload file, on every hit — the same "cached but never trusted"
posture as the stage3 seed next door. A truncated, mangled, format-stale, payload-less
or foreign entry is **pruned with an honest log line naming the reason** and reported as
a miss; it can never be restored into a sysroot. Stores publish atomically (build into a
`.tmp` sibling, then `mv`), so an interrupted store leaves no half-entry. Mutation of an
entry is serialised with `sa_lock_run` on a **sibling** lockfile — the share lane's
discipline, reused rather than re-implemented (`kc_require_sa` refuses to operate if
that library is not sourced).

### Opting out

`--no-kernel-cache` (env `HUGMESH_KERNEL_CACHE=off|0|no|none|false`) — same class of
build-phase escape hatch as `--no-shared-assets`, and deliberately not a GUI checkbox: it
cannot change the artifact, only whether an identical kernel is rebuilt.
`--no-shared-assets` disables the kernel cache too (sharing kernels while refusing to
share anything else would be an incoherent promise). Every channel's `--print-plan`
reports `PLAN_KERNEL_CACHE=<root>|off`.

---

## Honest limits (owed proof)

- The compile-once **speedup and end-to-end correctness are UNPROVEN** in this
  change — the sandbox cannot run a real cross-build. Every change here is
  static review + `bash -n` + the build-matrix parity/flag-coverage gates +
  hermetic fixture tests. A real `make prebuild-binaries` + fleet build on the
  operator box is the true proof.
- **Shared-asset root (G1/G2/G3) — what is NOT proven here.** The seed cache, the
  fleet distfiles and the cross-entry pool reuse are proven *hermetically* (fixture
  dirs, injected fetch/verify hooks, real flock races) — **not** by a real build. In
  particular these remain owed:
  - that a second real build of the same board actually **hits** the pool and skips the
    compiles (the hermetic tests prove the PATHS agree and the guard permits reuse;
    they cannot prove portage's `--usepkg` hit rate);
  - that a real `dlv_verify_stage3` on a cached seed behaves as the fixture verifier
    does (the flow is identical, the verifier is the same function the builders already
    call today — but it has not run against distfiles.gentoo.org in this change);
  - that a shared, writable `DISTDIR` across two genuinely concurrent cross builds is
    contention-free in practice. Portage's per-file fetch lock is the mechanism; no
    real concurrent fleet build has exercised it here.
- **x86's binpkg pool IS now shared (issue #46)** — the wave-1 measurement (0% x86
  reuse, 2,042 duplicate compiles across 17 images) reversed the earlier "too
  dangerous unproven" call, and the two hazards that made it dangerous are now
  guarded rather than avoided: `mount_chroot` bind-mounts
  `<root>/pkgdir/snap-build-x86` over the chroot's `/var/cache/binpkgs`, the
  Phase-8 clean **verifies the bind is detached** (`mountpoint -q`, hard abort)
  before its `rm -rf "${SYSROOT}"/var/cache/binpkgs/*`, and `--cached` images copy
  the pool back into the sysroot after the unmount so the embedded-cache promise
  holds. The pool is fingerprint-guarded with the spec-derived PROFILE included
  (the PR #44 deferral); pre-profile stamps are migrated once, loudly, by
  `pool_fingerprint_preflight` — a real CHOST/CFLAGS change still refuses reuse.
  Like every claim in this section, the reuse RATE on a real queue is owed proof
  from the next full mesh build's plan-preview `[binary]` counts — which the plan
  wire now carries per group (`total=<M> binary=<B> ebuild=<E>` + `via=` per row,
  and a `[emerge-plan] <group> binpkg reuse: …` line in every build log; see
  `docs/EMERGE-PLAN-PREVIEW.md`). The instrument exists; the number is still owed.
- **The arm host-side bdep pool (#72 §4) is wired on rpi5 + jetson only, and its
  reuse RATE is owed proof.** The leg's decisions (host-keyed stamp, flush-on-identity
  -change, make.conf wiring, target isolation) are proven hermetically in
  `tests/scripts/test-host-bdep-pool.sh`; that a real second arm build actually
  installs its 33–49 host bdeps as `[binary]` is owed from the next fleet build's
  emerge logs (the same "to /" batch wave 1 counted). The other seven cross builders
  carry no leg yet — wiring them is the same four hunks — and portage's concurrent
  index handling under `binpkg-multi-instance` has not been exercised by a real
  concurrent fleet build here.
- **Signed-kernel cache (G4) — what is NOT done and NOT proven.**
  - **Only two builders are wired: `build-x86-host-stage4.sh` and
    `build-rpi5-stage4.sh`** (the latter covering `--board rpi5|rpi4|rpi3`). The other
    eight cross builders (frite, jetson, orangepi5, orangepi-zero2/zero2w/zero3,
    orangepi3-lts, orangepi4-lts) source nothing and carry no `--no-kernel-cache`: they
    still rebuild their kernel every image. Wiring them is mechanical (the library is
    builder-agnostic and the two wired kernel phases are the template) but it is **not
    done**, and no flag was added to them, because a no-op opt-out flag would advertise
    a cache that does not exist.
  - **The cross builders do not sign kernels at all today.** Only x86 signs (`sbsign`
    over the UKI, `--keys-usb` / `--secureboot-key|-cert`, or the generated org key at
    `<WORK_DIR>/secureboot/sb.crt`). So on ARM the "signing identity" in the cache key is
    the *fleet* cert the x86 builder persists — or `HUGMESH_KERNEL_SIGNING_CERT` — and it
    keys the cache **without** implying the ARM kernel was signed with it. Where no such
    cert exists yet, the ARM cache correctly **never engages** (missing component ⇒
    MISS). This is honest but it means the ARM cache is inert on a fleet that has never
    run an x86 build and has not set the env var.
  - **The ARM disk-initramfs is NOT cached.** It is built later by
    `build_disk_initramfs()` from the assembled sysroot, so its inputs are not all known
    at the kernel phase. Only the kernel image, DTBs/overlays and `/lib/modules/<kver>`
    are cached on ARM. x86 does cache the initramfs and the unsigned UKI.
  - **No real hit has ever happened.** Every decision is proven hermetically against
    fixture cache dirs (65 executed assertions, including the gate-bypass mutation); the
    sandbox cannot compile a kernel. A real second build of one board on the operator box
    is the owed proof that the restored tree boots.
  - **No eviction policy.** Entries accumulate under `<root>/kernel/` until something
    invalidates them; only *bad* entries are pruned. `make clean` removes the default
    root along with `WORK_DIR` (as it already does for pools and seeds).
- What ships and IS verified: the produce→consume loop on all cross builders
  (`--usepkg=y --binpkg-respect-use=y`), the per-board pool split (no cross-board
  directory), the read-only distfiles wiring, the `--packages-only` early-exit +
  `PLAN_PACKAGES_ONLY`, the `prebuild-binaries` target + union module, and the
  **fingerprint SIGILL guard** (the real defense — hermetically proven to refuse
  a cortex-a76 pool for an a72 build).
