# Platform build uniformity — the measured survey

_Survey lane. This document changes **no behaviour**. It is the sourced,
re-measurable evidence base for the operator's request, made during a live
mesh build of the x86 **and** Pi5 images at the same moment:_

> "resolve differences in the ways and amount of data shown between the pi and
> x86 builds and create a uniform build structure for all platforms"

Everything below is either a **source line** (path + line number, on `main` at
`21f0ca0`) or a **count taken from a real build log**. Nothing is remembered or
estimated. Where a platform has never produced a log in `out/sessions/`, this
document says so instead of guessing.

> **Status on 2026-10-07 (`origin/main` @ `cbf5d9a6`). Read this first.** Every
> count, line number and log figure below was taken on `main` at `21f0ca0`
> (2026-07-30) from build logs that are no longer on disk (`out/sessions` holds
> one other session), so the log-derived figures are UNVERIFIED and cannot be
> re-measured, and the script in §6 points at a directory that is gone. One pass
> has landed since: #491 (`fe4d5c94`, 2026-07-30). Where each part stands:
>
> * **Stage names and ladder (§1, §5, D12, D13, D18, D21): done in
>   `studio/hugmesh_studio/core/progress-tables.json`.** `_meta.canonical_stages`
>   is one ordered list of 21 ids. Every platform's `phases` is a subsequence of
>   it, and a stage the platform lacks is named in that platform's
>   `not_applicable` map with a reason. No builder banner starts with `Phase N:`
>   any more, all ten builders announce `Rebranding baked config`, and x86 prints
>   `SKIPPED sysroot clean (--skip-clean)` (`build-x86-host-stage4.sh:6795`).
>   Phase counts today: x86 19, rpi5 15, jetson 15, and 17 for each of the other
>   seven. The shipped ladder is the §5 proposal
>   with one id and one position changed: `brand-desktop`, not `brand-image`, and
>   `rebrand-config` is stage 9 (after `stage-egress-vpn`), not stage 1. Five
>   labels differ too: `Verify seed`, `Extract stage3`, `Restore toolchain libs`,
>   `Stage bootloader` and `Package stage4`. Read the JSON, not §5, for the real
>   ids and labels. The flag grid in §1.3 is unchanged: `--image-only` is still
>   absent from x86 and rpi5 (D20 is a flag gap, not a banner gap).
> * **Emerge groups (§2.2, D8 to D11): declared, not unified.** The same five
>   names exist. x86 emits all five; the nine ARM builders emit `image`, `system`
>   and `tools`. `progress-tables.json` now states each platform's `emitted`
>   groups and gives a reason for each `not_applicable` one (`world` and
>   `dependencies` on the cross builders). The work behind a name still differs
>   (`_meta.emerge_groups.meanings`).
> * **Per-package data (§3, D1 to D7): not changed.** `Dockerfile.build:98` still
>   sets `EMERGE_DEFAULT_OPTS="--quiet-build=y ..."`, and only x86 overrides it
>   (`build-x86-host-stage4.sh:5478`); `PORTAGE_LOGDIR` is set in 2 of the 10
>   `make.conf.tmpl` files (x86 and rpi5); rpi5 still sets no `PORTAGE_TMPDIR`
>   (`cross_emerge`, `build-rpi5-stage4.sh:3922-3938`) and runs `--jobs`
>   `${CROSS_EMERGE_JOBS:-1}`, while the eight other cross builders run
>   `--jobs=${JOBS}`; x86 still sets no `EMERGE_LOG_DIR`.
> * **Platforms:** ten builders now, not eight (see the addendum).


One session, one mesh, both images, same moment:
`out/sessions/20260729-233913-719d4e/`. Snapshot taken **2026-07-30T08:41:41Z**
(the x86 leg had finished; the rpi5 leg was still running, so its counters keep
climbing — re-measure before quoting).

| marker (`grep -cF`) | `build-pki.rpi5.log` | `build-pki.x86.log` |
| --- | ---: | ---: |
| total lines | **3,848** | **105,398** |
| `>>> Emerging (` | **281** | **50** |
| `>>> Installing (` | 281 | 50 |
| `>>> Completed (` | 281 | 50 |
| `>>> Completed installing` (ebuild ladder) | **0** | **50** |
| `>>> Jobs:` (scheduler status display) | **1,739** | **0** |
| `==> Emerge group:` | **2** | **3** |
| `>>> Unpacking source` | **0** | 50 |
| `>>> Configuring source` | **0** | 50 |
| `>>> Compiling source` | **0** | 50 |
| `checking ` (autoconf) | **0** | **6,744** |
| `make[` | **0** | **1,850** |
| `USE:` (elog header) | 2 | 0 |
| `[verify-download]` | 5 | 5 |

**The Pi merges 5.6× more packages than x86 and prints 27× fewer lines.** The Pi
shows the *scheduler* and nothing else; x86 shows the *compiler* and no
scheduler. Two builds of the same mesh tell the operator two unrelated stories.

The same shape reproduces on Jetson, from the last session that has one
(`out/sessions/20260719-103006-a775c2/build-jetson-desktop.jetson.log`,
4,631 lines): 321 `>>> Emerging (`, **1,969** `>>> Jobs:`, **0** `checking `,
**0** `make[`, **0** `>>> Compiling source`. So this is **not a Pi quirk — it is
the cross-build lane**.

### Log coverage actually available

`out/sessions/` holds build logs for **three** of the eight platforms only:

| platform | logs present | newest |
| --- | --- | --- |
| x86 | `build-{pki,be,fe,omnibus,be+gpu,edge_ai}.x86.log` | 20260729-233913-719d4e |
| rpi5 | `build-{pki,be,fe,rpi5-desktop}.rpi5.log` | 20260729-233913-719d4e |
| jetson | `build-{jetson-desktop,edge_ai,full,gpu-host}.jetson.log` | 20260719-103006-a775c2 |
| frite, orangepi5, orangepizero2, orangepizero2w, orangepizero3 | **none** | — |

Claims about the five log-less platforms in this document are therefore
**source-derived only**, and are labelled as such.

---

## 1. Stage taxonomy — per platform, in source order

Extracted mechanically from every `banner "..."` call site plus every bare
`echo "==> ..."` call site, in file order (the same two shapes
[`tests/build-matrix/check.sh`](../tests/build-matrix/check.sh) and
`studio/tests/test_progress_parse.py` grep). Counts match the
`banner_callsites` pins in
[`core/progress-tables.json`](../studio/hugmesh_studio/core/progress-tables.json).

### 1.1 The tables as they stand

| platform | phases in `progress-tables.json` | banner call sites | vocabulary |
| --- | ---: | ---: | --- |
| x86 | **18** | 26 | bare verbs ("Brand desktop image", "Emerge packages") |
| rpi5 | **15** | 23 | `Phase N:` prefixes |
| jetson | **14** | 23 | `Phase N:` prefixes |
| frite | **16** | 25 | `Phase N:` prefixes |
| orangepi5 | **16** | 25 | `Phase N:` prefixes |
| orangepizero2 | **16** | 25 | `Phase N:` prefixes |
| orangepizero2w | **16** | 25 | `Phase N:` prefixes |
| orangepizero3 | **16** | 25 | `Phase N:` prefixes |

The `frite`, `orangepi5`, `orangepizero2`, `orangepizero2w` and `orangepizero3`
phase lists are **byte-identical** to one another (verified by comparing the
serialised `phases` arrays) — a copy-paste family; only the builders' u-boot
defconfig variable differs, inside the banner *text*.
(As of 2026-07-30; that branch no longer exists on `origin`.) `origin/feat/orangepi-234-platforms` is **not** ahead of `main` here: it
carries the same 8-platform table (`git merge-base --is-ancestor` says it is not
an ancestor of `main`, but its `progress-tables.json` platform set is identical
to `main`'s, and its two "new" builders — Zero 2W / Zero 3 — are already on
`main`). No 3 LTS / 4 LTS platform existed on `origin` when this was measured; both landed later the same day in #489 (see the addendum).

### 1.2 The same work under different names

| the work | x86 | rpi5 | jetson | frite / orangepi\* |
| --- | --- | --- | --- | --- |
| rewrite baked brand/domain | `Rebranding baked config` (:2862) | `Rebranding baked config` (:2439) | **no banner** (calls `rebrand_sysroot` at :1358) | **no banner** (frite :1343, opi5 :1370, z2 :1432, z2w :1443, z3 :1446) |
| host preflight | `Verifying prerequisites` (:3008) | `Verifying prerequisites` (:2819) | same (:917) | same (:917 / :941 / :1001 / :1012 / :1015) |
| seed fetch | `Fetching amd64 hardened stage3 seed` | `Fetching latest arm64 stage3 seed tarball` | same (+ "glibc — CUDA needs glibc") | same |
| seed extract | `Extracting stage3` | `Extracting seed stage3 into sysroot` | same | same |
| base/system merge | `Native emerge inside chroot` (:4216) + `Emerge group: system`/`world` | `Phase 1: Cross-building @system (hardened)` (:3761) | `Phase 1: …` (:1471) | `Phase 1: …` |
| role payload merge | `Emerge group: image` (:4615) — folded into the **"Emerge packages"** phase | `Phase 2: Cross-building stage4 packages` (:3807) | `Phase 2: … (role=…)` (:1502) | `Phase 2: …` |
| mesh VPN | `Installing mesh VPN (headscale + tailscale, amd64)` (:4815) | `Phase 2.5: Installing mesh VPN (headscale + tailscale)` (:3926) | `Phase 2.5: …` | `Phase 2.5: …` |
| kernel | `Building Gentoo hardened kernel …` (:4874) | `Phase 3: Cross-compiling hardened kernel` (:3995) | `Phase 3: Cross-compiling hardened mainline kernel (Tegra234)` | `Phase 3: Cross-compiling hardened kernel` |
| sysroot clean | `Cleaning sysroot` (:5215) | `Cleaning sysroot` (:4247) | same | same |
| stage4 tarball | `Packaging stage4 tarball` (:5305) | `Phase 4: Packaging stage4 tarball` (:4286) | `Phase 4: …` | `Phase 4: …` |
| raw disk image | `Building raw .img (UEFI GPT: ESP + ext4 root, GRUB-EFI --removable)` (:5662) | `Phase 5: Building raw .img` (:4536) | `Phase 5: Building the flashable raw .img (SD/NVMe)` | **absent** |
| live media | `Building bootable LIVE ISO (grub-mkrescue + squashfs)` (:5683) | **absent** | **absent** | `Phase 5: Building LIVE image …` |
| installer media | `Building installer ISO …` (:6004) | `Phase 6: Building bootable installer ISO` (:4557) | **absent** | `Phase 6: Building INSTALLER image …` |

Nine rows are **the same work with three different names**. The `Phase N:`
prefix is the loudest of them: it is a *cross-builder family convention*, not a
statement about the build, and it makes the x86 and ARM ladders unreadable
side by side.

### 1.3 Stages one platform has and another lacks

| stage | x86 | rpi5 | jetson | frite | opi5 | opiz2 | opiz2w | opiz3 |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Rebrand baked config (banner) | ✅ | ✅ | ❌\* | ❌\* | ❌\* | ❌\* | ❌\* | ❌\* |
| Brand desktop image | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Stage egress VPN | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Restore toolchain static libs | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `Phase 1/2 SKIPPED (--image-only)` | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `Phase 3.5: u-boot` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `Phase 4: extlinux boot config` | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `Phase 4: Boot tree` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Raw `.img` | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Live ISO / image | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Installer ISO / image | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `Cleaning: SKIPPED` alternative | ❌† | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

\* **the work happens, the banner does not.** All six of those builders call
`rebrand_sysroot` unconditionally at the position where x86/rpi5 announce it.
The stage is real, invisible, and un-tracked by the progress table.

† x86 **does** accept `--skip-clean` (`SKIP_CLEAN` at :174/:582/:874) but its
guard at :5214 has no `else`, so the stage vanishes from the ladder instead of
reporting itself skipped.

Flag support behind those rows (`grep -c` per builder):

| builder | `--image-only` | `--packages-only` | `--skip-uboot` | `--iso` |
| --- | ---: | ---: | ---: | ---: |
| build-x86-host-stage4.sh | 0 | 5 | 0 | 0 |
| build-rpi5-stage4.sh | **0** | 5 | 0 | **9** |
| build-jetson-stage4.sh | 8 | 5 | 0 | 0 |
| build-frite-stage4.sh | 3 | 5 | 3 | 0 |
| build-orangepi5-stage4.sh | 3 | 5 | 3 | 0 |
| build-orangepi-zero2\*/zero3 | 3 | 5 | 3 | 0 |

`--packages-only` is the one axis already uniform across all eight.

---

## 2. Emerge invocation — per platform

### 2.1 The three shapes

**x86 — native, in-chroot, `ROOT=/`.**
[`build-x86-host-stage4.sh:4497`](../build-x86-host-stage4.sh):

```
export EMERGE_DEFAULT_OPTS="--jobs ${EMERGE_JOBS} --load-average ${JOBS} --usepkg=y --binpkg-respect-use=y"
```

with `EMERGE_JOBS=1` pinned at :4460. Every merge is a bare `emerge` run inside
`chroot "${SYSROOT}" /bin/bash` (:4491). Because the export **replaces** the
inherited value, nothing from the builder container survives into it.

**rpi5 — cross, `ROOT=${SYSROOT}`.**
[`build-rpi5-stage4.sh:3737`](../build-rpi5-stage4.sh):

```
ROOT/SYSROOT/PORTAGE_CONFIGROOT="${SYSROOT}"
EMERGE_LOG_DIR="${BUILD_ROOT}/log"  PORTAGE_DEPCACHEDIR="${BUILD_ROOT}/edb"
"${CROSS_TARGET}-emerge" --jobs="${CROSS_EMERGE_JOBS:-1}" --load-average="${JOBS}" \
    --with-bdeps=n --usepkg=y --binpkg-respect-use=y "$@"
```

**The other six ARM builders — cross, `ROOT=${SYSROOT}`, but `--jobs=${JOBS}`.**
jetson :1435, frite :1430, orangepi5 :1457, opiz2 :1526, opiz2w :1537,
opiz3 :1540 — all identical:

```
ROOT/SYSROOT/PORTAGE_CONFIGROOT="${SYSROOT}"
EMERGE_LOG_DIR="${BUILD_ROOT}/log"  PORTAGE_DEPCACHEDIR="${BUILD_ROOT}/edb"
PORTAGE_TMPDIR="${BUILD_ROOT}/tmp"
"${CROSS_TARGET}-emerge" --jobs="${JOBS}" --load-average="${JOBS}" --with-bdeps=n \
    --usepkg=y --binpkg-respect-use=y "$@"
```

Two differences from rpi5, both undocumented: **`--jobs=${JOBS}`** (host core
count, measured at **13** on the jetson session) instead of 1, and
**`PORTAGE_TMPDIR` is set** — rpi5 does not set it, so its build dirs land in
the container's default `/var/tmp/portage` and vanish with the container.
rpi5's own comment claims it "Mirrors the x86 builder" (:3746), which is true of
`--jobs` and false of `PORTAGE_TMPDIR`.

| | x86 | rpi5 | jetson / frite / orangepi\* |
| --- | --- | --- | --- |
| wrapper | bare `emerge` inside `chroot` | `${CROSS_TARGET}-emerge` (crossdev `/usr/bin/<chost>-emerge`) | `${CROSS_TARGET}-emerge` |
| `ROOT` | `/` (chroot) | `${SYSROOT}` | `${SYSROOT}` |
| jobs | `--jobs 1` (`EMERGE_JOBS=1`) | `--jobs=1` (`CROSS_EMERGE_JOBS:-1`) | `--jobs=${JOBS}` (nproc) |
| load-average | `${JOBS}` | `${JOBS}` | `${JOBS}` |
| `--usepkg` | `=y` | `=y` | `=y` |
| `--binpkg-respect-use` | `=y` | `=y` | `=y` |
| `--with-bdeps` | *(unset)* | `=n` | `=n` |
| `--root-deps` | *(unset)* | `rdeps` (injected by the crossdev wrapper's `CROSS_CMD`) | `rdeps` (same) |
| `EMERGE_DEFAULT_OPTS` | **exported, overrides the container** | **inherited from the container** | **inherited from the container** |

The wrapper's injection is real and verifiable:
`/usr/bin/aarch64-unknown-linux-gnu-emerge` ends with
`: ${CROSS_CMD:=emerge --root-deps=rdeps}` / `exec ${CROSS_CMD} "$@"`.

### 2.2 Which emerge groups each platform actually emits

Call sites (`banner "Emerge group: …"` / `echo "==> Emerge group: …"`), pinned by
the `EGB` bucket in [`tests/build-matrix/check.sh:1466`](../tests/build-matrix/check.sh):

| platform | groups emitted | call sites |
| --- | --- | --- |
| x86 | `dependencies image system tools world` (**5**) | :4485 tools · :4548 system · :4602 world · :4615 image · :4945 dependencies |
| rpi5 | `image system tools` (**3**) | :3030 tools · :3802 system · :3822 image |
| jetson | `image system tools` (3) | :1067 · :1497 · :1513 |
| frite | `image system tools` (3) | :1068 · :1491 · :1510 |
| orangepi5 | `image system tools` (3) | :1093 · :1518 · :1536 |
| orangepizero2 | `image system tools` (3) | :1153 · :1587 · :1605 |
| orangepizero2w | `image system tools` (3) | :1164 · :1598 · :1616 |
| orangepizero3 | `image system tools` (3) | :1167 · :1601 · :1619 |

`EMERGE_GROUPS` in
[`core/emerge_packages.py:106`](../studio/hugmesh_studio/core/emerge_packages.py)
is the fixed 5-name taxonomy `("image", "tools", "dependencies", "system", "world")`.
Only x86 uses all five; **`world` and `dependencies` are emitted by exactly one
platform**.

Worse than the count: **the same group name denotes different work.**

| group | x86 means | every ARM builder means |
| --- | --- | --- |
| `tools` | `app-eselect/eselect-repository`, **inside the chroot**, only under `--steam` (:4485-4486) | host SELinux policy tools (`checkpolicy`, `semodule-utils`, `m4`, `libselinux`, `policycoreutils`) merged **natively onto the build host**, only when one is missing and `hostguard_mutation_allowed` (rpi5 :3030-3032) |
| `system` | three bootstrap one-shots: `sys-apps/portage`, `sys-apps/baselayout`, `<sys-devel/gettext-0.23` (:4570-4579) | `sys-apps/baselayout` **plus the whole `@system` set** (rpi5 :3803-3804) |
| `world` | `emerge --update --deep --newuse --keep-going @world` — the bulk of the build (:4603) | **never emitted**; the equivalent work is inside `system` |
| `image` | `${PKGS}`, the role payload (:4616) | `${STAGE4_PACKAGES[@]}`, the role payload (rpi5 :3823) — the one row that agrees |
| `dependencies` | `sys-kernel/gentoo-sources`, pulled during the kernel phase (:4946) | **never emitted**; kernel sources ride inside `image` (rpi5's `STAGE4_PACKAGES` contains `sys-kernel/raspberrypi-sources` — visible in `wl-pki.rpi5/log/emerge.log`) |

Also positional: on x86 the `tools` banner fires **late**, inside the chroot
payload; on every ARM builder it fires **first**, before `Preparing build
directories`. `progress-tables.json` papers over this by attaching `tools` to
`Verify prerequisites` on ARM and to `Emerge packages` on x86 — two different
phases for one group name.

---

## 3. What per-package data reaches the stream, and what only the log

### 3.1 Root cause: portage background mode

Portage suppresses per-package build output on stdout when
`_background_mode()` is true. From the portage the builds actually run
(3.0.81.2, `/usr/lib/python3.14/site-packages/_emerge/Scheduler.py:441-452`):

```python
parallel_jobs = self._max_jobs is True or self._max_jobs > 1
quiet = "--quiet" in self.myopts or self.myopts.get("--quiet-build") == "y"
background = (parallel_jobs or quiet) and not bool(
    self._opts_no_background.intersection(self.myopts))
```

and at :495 `self._status_display.quiet = not background or …` — so `>>> Jobs:`
lines appear **iff** background mode is on. That is the single switch that
produces the whole 3,848-vs-105,398 divergence.

### 3.2 Which side of the switch each platform is on — measured

The **normalised** option set portage records in its own `emerge.log` is the
authority (it prints the resolved `myopts`, not the argv):

`wl-pki.rpi5/log/emerge.log`:

```
*** emerge --newuse --update --deep --exclude=… --jobs=1 --keep-going --load-average=4.0
    --with-bdeps=n --binpkg-respect-use=y --quiet-build=y --regex-search-auto=y
    --root-deps=rdeps --usepkg @system
```

`wl-pki.x86/sysroot/var/log/emerge.log`:

```
*** emerge --newuse --update --deep --exclude=… --jobs=1 --keep-going --load-average=4.0
    --binpkg-respect-use=y --regex-search-auto=y --usepkg @world
```

`20260719-103006-a775c2/wl-jetson-desktop.jetson/log/emerge.log`:

```
*** emerge --newuse --update --deep --exclude=… --jobs=13 --keep-going --load-average=13.0
    --with-bdeps=n --quiet-build=y --regex-search-auto=y --root-deps=rdeps …
```

**`--quiet-build=y` is on the ARM lines and absent from the x86 line — and no
builder passes it.** Its origin is
[`Dockerfile.build:59`](../Dockerfile.build):

```
ENV FEATURES="-news binpkg-multi-instance" \
    EMERGE_DEFAULT_OPTS="--quiet-build=y --jobs=4 --load-average=8" \
    MAKEOPTS="-j4"
```

x86 neutralises it by **exporting** `EMERGE_DEFAULT_OPTS` inside the chroot
(:4497). `cross_emerge()` never exports it, so the container default leaks
straight through: its `--jobs`/`--load-average` are overridden by the explicit
flags, and `--quiet-build=y` — which no explicit flag contradicts — survives.

So the ARM lane is in background mode for **two** independent reasons:

1. the leaked `--quiet-build=y` (all seven cross builders), and
2. `--jobs=${JOBS}` > 1 (the six non-rpi5 cross builders).

Fixing only one of them would leave jetson/frite/orangepi\* dark.

### 3.3 Where the per-package output goes instead

`PORTAGE_LOGDIR` is set in **two** of the eight make.conf templates:

| template | `PORTAGE_LOGDIR` |
| --- | --- |
| [`specs-x86/portage/make.conf.tmpl:45`](../specs-x86/portage/make.conf.tmpl) | `/var/log/portage/build` |
| [`specs-rpi5/portage/make.conf.tmpl:24`](../specs-rpi5/portage/make.conf.tmpl) | `/var/log/portage/build` |
| specs-jetson, specs-frite, specs-orangepi5, specs-orangepi-zero2, specs-orangepi-zero2w, specs-orangepi-zero3 | **unset** |

And even where it is set, it only *lands in the sysroot* when portage runs
**inside** that sysroot:

| | resolves to | per-package logs on disk (measured) |
| --- | --- | --- |
| x86 (chroot, `ROOT=/`) | `<session>/wl-pki.x86/sysroot/var/log/portage/build` | **57 files** (`sys-devel:gettext-0.22.5-r2:20260730-064035.log`, …) |
| rpi5 (cross, portage on the host/container) | container's `/var/log/portage/build`, **not** the sysroot | `wl-pki.rpi5/sysroot/var/log/portage/` contains **only `elog/`** — no `build/` directory at all |
| jetson (same) | container's `/var/log/portage/build` | `wl-jetson-desktop.jetson/sysroot/var/log/portage/` — **only `elog/`** |

`wl-pki.rpi5/` has no `tmp/` either (rpi5 sets no `PORTAGE_TMPDIR`), so even the
throwaway `…/temp/build.log` fallback is outside the artifact tree. On the six
siblings `PORTAGE_TMPDIR="${BUILD_ROOT}/tmp"` at least keeps build dirs under
`/out`, but portage deletes them on success (`wl-jetson-desktop.jetson/tmp/portage`
retained exactly **1** entry after a full build).

**Net effect: on every ARM platform the per-package compile output reaches
neither the stream nor any durable log. It is destroyed.**

### 3.4 What the Studio consequently cannot show on ARM

[`core/emerge_packages.py:367`](../studio/hugmesh_studio/core/emerge_packages.py)
takes `log_root` = `<session>/wl-<role>.<arch>/sysroot/var/log/portage/build`
and reads the elog header from it — that is the **only** source of USE flags
(`grep -c 'USE:'` over a 3.16M-line x86 transcript returns 0; measured again
here: 0 on x86's stream, 2 on rpi5's). That directory exists on x86 and does not
exist on any ARM platform, so on ARM the per-package tree has:

* no USE flags,
* no elog header (Package / Repository / Maintainer / FEATURES),
* no working log click-through (`>>> Failed to emerge … Log file:` paths rebase
  onto a `log_root` that is not there),
* no `Unpacking/Configuring/Compiling/Install` ebuild ladder — those lines are
  0/0/0 in the rpi5 and jetson streams, so every ARM row jumps
  `queued → emerging → completed`.

Conversely x86 gets **no** `>>> Jobs:` scheduler data at all (0 lines), so
concurrency/queue depth is invisible there.

Per-package data availability, measured:

| datum | x86 | rpi5 | jetson | frite / opi\* (source-derived) |
| --- | --- | --- | --- | --- |
| `Emerging/Installing/Completed (N of M)` | stream | stream | stream | stream |
| cross-build `for/to <sysroot>` tail | n/a (`ROOT=/`) | stream | stream | stream |
| ebuild ladder (`Unpacking…Compiling…`) | **stream** | none | none | none |
| autoconf/make tool output | **stream** (6,744 + 1,850) | none | none | none |
| `>>> Jobs:` scheduler state | none | **stream** | **stream** | **stream** |
| USE flags / elog header | per-package log (57 files) | **nowhere** | **nowhere** | **nowhere** |
| emerge summary log | `sysroot/var/log/emerge.log` (452 lines) | `<BUILD_ROOT>/log/emerge.log` (2,534 lines) | `<BUILD_ROOT>/log/emerge.log` | `<BUILD_ROOT>/log/emerge.log` |

Note the last row is itself a divergence: x86's `emerge.log` is inside the
**image** (`EMERGE_LOG_DIR` unset → chroot default), ARM's is beside it in the
build root (`EMERGE_LOG_DIR="${BUILD_ROOT}/log"`).

### 3.5 A second-order artefact worth knowing

x86's `>>> Completed` count (100) is **50 counter lines + 50 ebuild-ladder
`>>> Completed installing <atom> into <image>` lines**. Any parser or check that
counts a bare `>>> Completed` double-counts on x86 and not on ARM. Use
`>>> Completed (` — measured 50 (x86) / 281 (rpi5) — as the counter marker.

---

## 4. Divergence register

Classification:

* **MUST-UNIFY** — the difference has no defensible cause; it is drift,
  copy-paste, or a leak. Remove it.
* **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** — the underlying work legitimately
  differs, but the operator must see the same word for the same concept, and an
  absent stage must be *stated*, never silent.
* **GENUINELY-PLATFORM-SPECIFIC** — the hardware or the build model forces it.

| # | what | platforms | root cause | classification | evidence |
| --- | --- | --- | --- | --- | --- |
| D1 | `--quiet-build=y` leaks from the builder container into every cross build; x86 alone overrides it, so ARM prints **zero** compile output | 7 cross builders vs x86 | **leak** — `Dockerfile.build:59` sets `EMERGE_DEFAULT_OPTS`; `build-x86-host-stage4.sh:4497` exports over it, `cross_emerge()` does not | **MUST-UNIFY** | `emerge.log` argv on rpi5/jetson carries `--quiet-build=y`, x86's does not; Scheduler.py:441-452 |
| D2 | `PORTAGE_LOGDIR` set in only 2 of 8 make.conf templates | jetson, frite, orangepi5, opiz2, opiz2w, opiz3 lack it | **drift** — added for x86/rpi5, never propagated to the copy-paste family | **MUST-UNIFY** | `specs-*/portage/make.conf.tmpl` grep |
| D3 | Even where set, `PORTAGE_LOGDIR` resolves on the build host for cross builds, so no per-package log ever lands in the sysroot | all 7 cross builders | **model mismatch** — portage runs outside the ROOT it merges into | **MUST-UNIFY** (must be made explicit + redirected into the build root) | `wl-pki.rpi5/sysroot/var/log/portage/` has only `elog/`; x86 has 57 build logs |
| D4 | Studio's USE-flag / elog reader is keyed to a directory that exists on x86 only | all 7 cross builders | consequence of D2+D3 | **MUST-UNIFY** | `core/emerge_packages.py:367`; measured directory absence |
| D5 | `--jobs`: 1 on x86 and rpi5, `${JOBS}` (13 measured) on the other six | jetson, frite, orangepi5, opiz2, opiz2w, opiz3 | **drift** — the sibling family copied an earlier rpi5 that had not yet been serialised; the rpi5 comment at :3746 still claims parity | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** (parallelism is a legitimate choice, but it *silently* degrades per-package attribution — `emerge_packages.py:38-46` drops atom-less ladder lines under it) | jetson `emerge.log`: `--jobs=13` |
| D6 | `PORTAGE_TMPDIR` set by 6 cross builders, **not** by rpi5 | rpi5 | **drift** | **MUST-UNIFY** | rpi5 :3737-3758 vs jetson :1435-1441; `wl-pki.rpi5/` has no `tmp/` |
| D7 | `EMERGE_LOG_DIR` inside the image (x86) vs beside it (ARM) | x86 vs all cross | **accident** — x86 simply never sets it | **MUST-UNIFY** (the summary log should not ship inside the image) | `wl-pki.x86/sysroot/var/log/emerge.log` vs `wl-pki.rpi5/log/emerge.log` |
| D8 | Emerge-group taxonomy: 5 names, x86 emits all 5, ARM emits 3 | all | **taxonomy never reconciled** across the native/cross split | **MUST-UNIFY** | `check.sh:1466-1477`; `EMERGE_GROUPS` at `emerge_packages.py:106` |
| D9 | `system` means "3 bootstrap one-shots" on x86 and "the whole `@system` set" on ARM; `world` exists only on x86 | all | **same word, different scope** | **MUST-UNIFY** | x86 :4548-4579 vs rpi5 :3802-3804 |
| D10 | `tools` = in-chroot `--steam` helper (x86) vs host-mutating SELinux tools (ARM), and fires last vs first | all | **same word, different host and trigger** | **MUST-UNIFY** | x86 :4485 vs rpi5 :3030 |
| D11 | `dependencies` emitted only by x86 (kernel sources); ARM folds kernel sources into `image` | x86 vs all cross | deliberate on x86 (:4938-4942 comment), unconsidered on ARM | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** | x86 :4945; rpi5 `STAGE4_PACKAGES` contains `sys-kernel/raspberrypi-sources` |
| D12 | Stage vocabulary: `Phase N:` prefixes on all 7 ARM builders, bare verbs on x86 | all | **family convention**, never reconciled | **MUST-UNIFY** | `progress-tables.json` labels |
| D13 | "Rebrand baked config" banner exists on x86+rpi5 only, though **all 8** call `rebrand_sysroot` | jetson, frite, orangepi5, opiz2, opiz2w, opiz3 | **drift** — a real stage that is invisible on 6 platforms | **MUST-UNIFY** | call sites: jetson :1358, frite :1343, opi5 :1370, z2 :1432, z2w :1443, z3 :1446 |
| D14 | "Brand desktop image" / "Stage egress VPN" stages exist only on x86 | x86 | x86 is the only desktop-branding + egress-VPN platform today (`BRANDING_THEME` 11 hits, `EGRESS_VPN` 15 hits, 0 elsewhere) | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** (declare as N/A per platform, do not omit) | grep counts per builder |
| D15 | "Restore toolchain static libs from seed" only on x86 | x86 | **genuine** — native chroot GPU source-compile needs the seed's static libs; a cross build never runs target binaries | **GENUINELY-PLATFORM-SPECIFIC** | x86 :4161 |
| D16 | `ROOT=/` + chroot (x86) vs `ROOT=${SYSROOT}` (ARM), producing the ` for/to <sysroot>` counter tail | all | **genuine** — cross vs native | **GENUINELY-PLATFORM-SPECIFIC** (already handled by PR #483) | `emerge_packages.py:165-180` |
| D17 | `--with-bdeps=n` + `--root-deps=rdeps` on ARM only | all cross | **genuine** — build-time deps belong to the host, not the target sysroot; `--root-deps` is injected by the crossdev wrapper | **GENUINELY-PLATFORM-SPECIFIC** | `/usr/bin/aarch64-unknown-linux-gnu-emerge` tail |
| D18 | u-boot (`Phase 3.5`) on frite+orangepi\*, extlinux on jetson, GRUB-EFI folded into the `.img` stage on x86, none on rpi5 (firmware blobs) | all | **genuine** — different boot chains | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** (one canonical "Bootloader / firmware" stage, platform-specific detail in the sub-label) | banner tables §1.3 |
| D19 | Output media: raw `.img` (x86/rpi5/jetson), LIVE+INSTALLER images (frite/opi\*), LIVE ISO (x86 only), installer ISO (x86/rpi5, opt-in on rpi5 via `--iso`) | all | mixed — genuine for ISO-vs-SD, drift for the LIVE gap on rpi5/jetson | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** | §1.3 table; `--iso` grep |
| D20 | `--image-only` skip banners on 6 ARM builders, absent on rpi5 and x86 | rpi5, x86 | **drift** | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** | flag grep table §1.3 |
| D21 | `Cleaning: SKIPPED` alternative banner on all 7 ARM builders, absent on x86 — yet x86 **does** support `--skip-clean`, so under that flag the "Clean sysroot" rung silently never appears | x86 | **drift** — the flag was added without the SKIPPED banner the ARM family emits | **MUST-UNIFY** | x86 `SKIP_CLEAN` at :174/:582/:874, guard at :5214 wraps `banner "Cleaning sysroot"` (:5215) with no `else`; `progress-tables.json` x86 phase has no SKIPPED alternative |
| D22 | x86 emits its group banners as bare `echo` inside unquoted chroot heredocs; ARM uses `banner()` | x86 | **genuine** — `banner()` does not exist inside the chroot | **GENUINELY-PLATFORM-SPECIFIC** (already documented and gated; wire format is the `==> ` text) | `progress-tables.json` `_meta.source`; `check.sh` heredoc-safety probe |
| D23 | `>>> Completed` appears twice per package on x86 (counter + ebuild ladder), once on ARM | x86 | consequence of D1 | **MUST-UNIFY** (follows from D1) | 50 + 50 = 100 vs 281 |
| D24 | 5 of 8 platforms had never produced a log under `out/sessions/` (the §0 coverage table lists five without logs and three with) | frite, orangepi5, opiz2, opiz2w, opiz3 (+ x86/rpi5/jetson do) | coverage gap, not a code divergence | **MAY-DIFFER-BUT-MUST-BE-NAMED-CONSISTENTLY** (uniformity claims for those five are source-only until a build exists) | `out/sessions` inventory §0 |

---

## 5. Recommended canonical taxonomy

One ordered stage list for **every** platform. Each platform declares each stage
as **present**, **skipped-by-flag** (with the flag), or **not-applicable** (with
the reason) — and the not-applicable ones are still *rendered*, greyed, so an
operator sees the same ladder on a Pi and on x86 and can tell at a glance which
rungs this board does not have. No stage may be silently absent, and no stage
may be named differently on two platforms.

| # | canonical id | canonical label | platform-specific detail belongs in the sub-label |
| ---: | --- | --- | --- |
| 1 | `rebrand-config` | Rebrand baked config | — |
| 2 | `verify-prereqs` | Verify prerequisites | host toolchain, crossdev, `xorrisofs` |
| 3 | `prepare-dirs` | Prepare build dirs | — |
| 4 | `fetch-seed` | Fetch stage3 seed | `amd64 hardened` / `arm64` / `arm64 glibc (CUDA)` |
| 5 | `verify-seed` | Verify seed signature + checksum | — |
| 6 | `extract-seed` | Extract stage3 into sysroot | — |
| 7 | `install-specs` | Install spec files | — |
| 8 | `brand-image` | Brand desktop image | N/A on non-desktop boards — say so |
| 9 | `stage-egress-vpn` | Stage egress VPN | N/A where unsupported — say so |
| 10 | `restore-toolchain` | Restore toolchain static libs | N/A on cross builds (no native GPU compile) |
| 11 | `emerge-system` | Emerge `@system` | native `@world` on x86; cross `@system` on ARM |
| 12 | `emerge-payload` | Emerge role payload | — |
| 13 | `mesh-vpn` | Install mesh VPN | — |
| 14 | `kernel` | Build kernel | `gentoo-sources` / `raspberrypi-sources` / Tegra234 mainline |
| 15 | `bootloader` | Bootloader / firmware | u-boot · extlinux · GRUB-EFI · RPi firmware blobs |
| 16 | `clean-sysroot` | Clean sysroot | — |
| 17 | `boot-tree` | Stage boot tree | N/A where the image stage does it |
| 18 | `package-stage4` | Package stage4 tarball | — |
| 19 | `image-raw` | Build raw `.img` | — |
| 20 | `image-live` | Build LIVE image | ISO on x86, SD/USB image on ARM |
| 21 | `image-installer` | Build INSTALLER image | ISO on x86/rpi5, SD/eMMC image on ARM |

Drop the `Phase N:` prefixes entirely: the ladder position already carries the
ordering, and the numbers currently disagree between platforms anyway
(jetson has two different `Phase 4:` stages).

**Canonical emerge-group taxonomy.** Keep the five names, but give each exactly
one meaning and require every platform to emit every group it performs:

| group | canonical meaning | today |
| --- | --- | --- |
| `tools` | build-host / build-chroot helpers that never ship in the image | x86: chroot `--steam` helper · ARM: host SELinux tools — reconcile |
| `system` | the profile base layer (`@system` + `baselayout` + the package manager) | x86 emits only the 3 bootstrap one-shots — must include its `@world` base half |
| `world` | a full `@world` reconciliation pass | x86 only — ARM must emit it or declare it N/A |
| `dependencies` | packages merged solely to satisfy another build step | x86 only (kernel sources) — ARM must emit it around its kernel-source merge |
| `image` | the role payload | already uniform — the model for the rest |

**Canonical per-package data contract.** Every platform must supply, from a
source that survives the build:

1. the counter stream (`Emerging/Installing/Completed (N of M)`) — already uniform;
2. the ebuild ladder and tool output — today x86-only, recoverable on ARM by
   removing the `--quiet-build=y` leak (D1) and/or by tailing the per-package
   log (the `feat/emerge-multijob-progress` tailer approach, which was **not
   on `origin`** when measured — `git ls-remote` found no such head — so this survey assumed
   it must compose rather than that it exists. The branch is still absent on 2026-10-07. #488 (`70fcea37`, 2026-07-30) added Studio parsing of the `>>> Jobs:` lines (`emerge_packages.py:113-115`); whether it is the work meant here is UNVERIFIED);
3. the elog header + USE flags — today x86-only, requires a `PORTAGE_LOGDIR`
   that actually lands under the build root on cross builds (D2/D3);
4. `>>> Jobs:` scheduler state — today ARM-only; x86 must either emit it or the
   GUI must state that a serialised native build has no queue to show.

Where a platform genuinely cannot supply one of the four, the GUI must say so in
that platform's own words. A blank panel is the one outcome this document
exists to prevent.

---

## 6. Re-measuring this document

```bash
S=out/sessions/20260729-233913-719d4e
for f in "$S"/build-pki.rpi5.log "$S"/build-pki.x86.log; do
  echo "== $f  $(wc -l < "$f") lines"
  for p in '>>> Emerging (' '>>> Jobs:' '>>> Completed (' '==> Emerge group:' \
           'checking ' 'make[' '>>> Compiling source'; do
    printf '%-24s %s\n' "$p" "$(grep -cF -- "$p" "$f")"
  done
done
# group banners per builder (the EGB probe's own extraction)
for b in build-*-stage4.sh; do
  printf '%-32s %s\n' "$b" "$( { sed -nE 's/^[[:space:]]*banner "Emerge group: ([a-z]+)".*/\1/p' "$b"
                                 sed -nE 's/^[[:space:]]*echo "==> Emerge group: ([a-z]+)".*/\1/p' "$b"
                               } | sort | tr '\n' ' ')"
done
# stage ladder per builder, in source order
grep -nE '^[[:space:]]*(banner "|echo "==> )' build-rpi5-stage4.sh
```

`out/sessions/**` is **read-only input**. Never write there, and never `cat` the
multi-hundred-megabyte transcripts — `grep -c` / `awk` only.

---

## Addendum (2026-07-30): two boards landed after the survey

Every count above was measured on `main` at `21f0ca0`, when the fleet had
**eight** builders. PR #489 then added **Orange Pi 3 LTS + 4 LTS**
(`build-orangepi3-lts-stage4.sh` / `build-orangepi4-lts-stage4.sh`, both cloned
from the Zero 2/Zero 3 template) — in the PRE-uniformity "Phase N" vocabulary.
The taxonomy pass folded both into the canonical stage ladder and emerge-group
declaration in the same change that canonicalized the original eight, so the
canonical ladder now spans **ten builders**; a new platform that is not uniform
would have defeated the point of the pass. The survey's per-platform
measurements were NOT re-run for the two LTS boards (no archived log of either
exists yet — they have never completed a real build); their rows inherit the
Zero 2/Zero 3 template's shape, which is what their builders are.
