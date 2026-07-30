# Shared prebuilt binary packages (binpkg pools)

_State key: **✅ shipped mechanism** · **⚠️ live speedup + correctness UNPROVEN
without a real fleet build** — this track ships the machinery and the safety
guard; the compile-once-and-reuse speedup is owed a real cross-build to prove._

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
- **x86:** `PKGDIR="/var/cache/binpkgs"` (chroot-internal, inside the shared
  sysroot); the 4 x86 roles reuse one pool via a shared sysroot (`--resume`).

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

## Prebuild-once workflow

```sh
# 1. compile a platform's role-UNION binpkg pool ONCE (per board), no image:
make prebuild-binaries ARCH=rpi5 BOARD=rpi4        # -> snap-build-pi4/pkgdir
make prebuild-binaries ARCH=x86                    # -> snap-build-x86 sysroot pool

# 2. later per-role image builds reuse the pool via --usepkg (already wired):
make rpi RPI_BOARD=rpi4                             # backend/frontend/… reuse pi4 pool
make x86 RESUME=--resume                            # x86: MUST pass --resume (see below)
```

> **x86 caveat — pass `RESUME=--resume` to consume an x86 prebuild.** The x86 pool
> lives *inside* the sysroot (`/var/cache/binpkgs`), unlike the ARM pools which sit
> in `${BUILD_ROOT}/pkgdir` outside the sysroot. A non-`--resume` x86 build wipes
> the sysroot (the wipe-on-non-resume guard) and therefore the prebuilt pool with
> it — so `make prebuild-binaries ARCH=x86` then a plain `make x86` recompiles from
> scratch. Always thread `RESUME=--resume` into the consuming x86 build. The ARM
> boards have no such caveat (their pool survives a sysroot wipe).

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
   Keep one writer per pool (the worklist path already isolates each entry under
   its own `BUILD_SUBDIR=wl-<id>`).

---

## Honest limits (owed proof)

- The compile-once **speedup and end-to-end correctness are UNPROVEN** in this
  change — the sandbox cannot run a real cross-build. Every change here is
  static review + `bash -n` + the build-matrix parity/flag-coverage gates +
  hermetic fixture tests. A real `make prebuild-binaries` + fleet build on the
  operator box is the true proof.
- What ships and IS verified: the produce→consume loop on all cross builders
  (`--usepkg=y --binpkg-respect-use=y`), the per-board pool split (no cross-board
  directory), the read-only distfiles wiring, the `--packages-only` early-exit +
  `PLAN_PACKAGES_ONLY`, the `prebuild-binaries` target + union module, and the
  **fingerprint SIGILL guard** (the real defense — hermetically proven to refuse
  a cortex-a76 pool for an a72 build).
