# FINDINGS — ARM firewalld unresolvable (introspection chain) + sendfile triage

Investigation branch: `fix/arm-firewalld-installable` (off origin/main 49f70b88).
Test bench (READ-ONLY): `out/sessions/20260730-210421-a6d331` — the operator's failed
2026-07-30 21:04 8-image mesh build. All resolution probes below are
`emerge --pretend` only, run with `PORTAGE_CONFIGROOT` pointed at scratch COPIES of the
sysroots' `etc/portage` (bench never modified).

## 1. Baseline reproduction (resolution probe on the REAL wl-pki.rpi5 sysroot)

The failing log (`build-pki.rpi5.log` ~line 1730):

```
emerge: there are no ebuilds built with USE flags to satisfy ">=dev-libs/glib-2.82.0:2[introspection]" for /out/wl-pki.rpi5/sysroot/.
!!! One of the following packages is required to complete your request:
- dev-libs/glib-2.88.2::gentoo (Change USE: +introspection)
(dependency required by "dev-libs/gobject-introspection-1.86.0::gentoo" [ebuild])
(dependency required by "dev-python/pygobject-3.56.3::gentoo" [ebuild])
(dependency required by "net-firewall/firewalld-2.4.4::gentoo[python_single_target_python3_14]" [ebuild])
(dependency required by "net-firewall/firewalld" [argument])
```

and the tail-of-log completeness-gate refusal:

```
[build-rpi5] ERROR: 1 requested package(s) are NOT installed in the target vdb:
[build-rpi5]          net-firewall/firewalld
...
    ERROR: requested-atom completeness gate failed (see the missing-atom list above).
```

The builder's real invocation (build-rpi5-stage4.sh `cross_emerge()`, line 3857ff) is
`aarch64-unknown-linux-gnu-emerge` (crossdev wrapper, which appends `--root-deps=rdeps`)
with `ROOT=SYSROOT=PORTAGE_CONFIGROOT=<sysroot>` and
`--jobs=1 --load-average=$JOBS --with-bdeps=n --usepkg=y --binpkg-respect-use=y`,
then for the image group `--update --deep --newuse --keep-going --exclude sys-devel/gcc
--exclude sys-devel/gcc-config --exclude sys-libs/glibc --exclude sys-devel/binutils
<STAGE4_PACKAGES>`.

Baseline probe (config copied UNMODIFIED from the bench sysroot to scratch):

```
LANG=C.UTF-8 LC_ALL=C.UTF-8 ROOT=$BENCH/wl-pki.rpi5/sysroot SYSROOT=$BENCH/wl-pki.rpi5/sysroot \
PORTAGE_CONFIGROOT=$SCRATCH/cfg-pki-rpi5-baseline \
aarch64-unknown-linux-gnu-emerge --pretend --verbose --jobs=1 --load-average=5 \
  --with-bdeps=n --usepkg=y --binpkg-respect-use=y --update --deep --newuse --keep-going \
  --exclude sys-devel/gcc --exclude sys-devel/gcc-config --exclude sys-libs/glibc \
  --exclude sys-devel/binutils net-firewall/firewalld
```

Output (VERBATIM — matches the log except the ROOT path, which the builder container
bind-mounts at `/out`):

```
emerge: there are no ebuilds built with USE flags to satisfy ">=dev-libs/glib-2.82.0:2[introspection]" for /home/magus/GitHub/hugmesh-generator/out/sessions/20260730-210421-a6d331/wl-pki.rpi5/sysroot/.
!!! One of the following packages is required to complete your request:
- dev-libs/glib-2.88.2::gentoo (Change USE: +introspection)
(dependency required by "dev-libs/gobject-introspection-1.86.0::gentoo" [ebuild])
(dependency required by "dev-python/pygobject-3.56.3::gentoo" [ebuild])
(dependency required by "net-firewall/firewalld-2.4.4::gentoo[python_single_target_python3_14]" [ebuild])
(dependency required by "net-firewall/firewalld" [argument])
```

REPRODUCED. Note: a plain `emerge --pretend` (without the crossdev wrapper's exact
flags) instead prints autounmask SUGGESTIONS (`>=dev-libs/glib-2.88.2 introspection`
plus `>=sys-libs/libselinux-3.11 python` / `>=sys-process/audit-4.1.4-r4 python`) —
probes must use the builder's exact flag set to be representative.

Root cause chain: `specs-rpi5/portage/make.conf.tmpl:42` sets global USE
`-introspection` (with `-vala` appended after) →
`net-firewall/firewalld-2.4.4` RDEPENDs `dev-python/pygobject:3` →
`dev-python/pygobject-3.56.3` needs `dev-libs/gobject-introspection-1.86.0` →
g-i needs `>=dev-libs/glib-2.82.0:2[introspection]` → unsatisfiable under the
global `-introspection`, and autounmask is not active in the builder invocation.

## 2. Version puzzle — why x86 built 2.4.0 while ARM reached for 2.4.4

Tree keywords (verbatim):

```
/var/db/repos/gentoo/net-firewall/firewalld/firewalld-2.4.4.ebuild:KEYWORDS="~amd64 ~arm ~arm64 ~loong ~ppc64 ~riscv ~x86"
/var/db/repos/gentoo/net-firewall/firewalld/firewalld-2.4.0.ebuild:KEYWORDS="amd64 arm arm64 ~loong ppc64 ~riscv x86"
/var/db/repos/gentoo/net-firewall/firewalld/firewalld-2.4.2.ebuild:KEYWORDS="~amd64 ~arm ~arm64 ~loong ~ppc64 ~riscv ~x86"
```

- rpi5 make.conf sets `ACCEPT_KEYWORDS="arm64 ~arm64"` → newest visible = **2.4.4**.
- The x86 chroot build accepts stable only → **2.4.0** (stable on amd64 AND arm64).

x86 bench vdb `wl-pki.x86/sysroot/var/db/pkg/net-firewall/firewalld-2.4.0/RDEPEND`
(verbatim):

```
dev-lang/python:3.14 || ( >=sys-apps/openrc-0.11.5 sys-apps/systemd ) dev-python/dbus-python[python_targets_python3_14(-)] dev-python/pygobject:3[python_targets_python3_14(-)] >=net-firewall/nftables-0.9.4[python,json,python_targets_python3_14(-)] net-firewall/ipset net-firewall/nftables[xtables(+)]
```

**firewalld-2.4.0 ALREADY RDEPENDs dev-python/pygobject:3** — firewalld is a Python
daemon at every version in the tree. Pinning ARM to 2.4.0 (Candidate B) does NOT avoid
the pygobject → gobject-introspection → glib[introspection] chain. The x86 image
satisfies it natively: its vdb has `dev-libs/glib-2.88.2` with USE containing
`introspection`, plus `gobject-introspection-1.86.0` and `pygobject-3.56.3`
(built inside the x86 chroot where g-ir-scanner's python matches).
**Candidate B is DEAD on facts.**

## 3. Candidate A feasibility facts

### 3a. binfmt / qemu on this host and in the builder

This dev host (READ-ONLY check of /proc/sys/fs/binfmt_misc):

```
qemu-aarch64: enabled, interpreter /usr/bin/qemu-aarch64, flags: OC
aarch64:      enabled, interpreter /usr/bin/qemu-aarch64, flags: (none)
status:       enabled
```

`/usr/bin/qemu-aarch64` on this host is DYNAMICALLY linked x86-64. The builder is
stricter: `build-rpi5-stage4.sh:2947,2971` REFUSES to start unless the builder image
ships a STATIC qemu-aarch64 (Dockerfile.build FINAL stage emerges
`app-emulation/qemu[static-user] QEMU_USER_TARGETS=aarch64`) and the container is
`--privileged` so binfmt_misc can be mounted/registered. So qemu-user execution of
target binaries is a GUARANTEED PRECONDITION of every rpi5 build — the
run-target-binaries half of introspection cross-builds is provided for.

### 3b. glib ebuild / eclass cross handling (current tree)

`dev-libs/glib-2.88.2.ebuild` (`/var/db/repos/gentoo/dev-libs/glib/`):
- `_need_bootstrap_gi()` fires when USE=introspection and no usable
  `>=dev-libs/gobject-introspection-1.86.0` is installed (always true for a fresh
  sysroot) → bootstraps an internal gobject-introspection (with an internal glib) via
  meson (`-Dpython="${EPYTHON}"`, `--force-fallback-for=glib`), installs it into
  `${T}/bootstrap-gi-prefix`, prepends it to PATH/PKG_CONFIG/LD_LIBRARY_PATH/PYTHONPATH,
  then configures the real glib with `$(meson_native_use_feature introspection)`.
- The ebuild has NO cross-specific handling of the bootstrap (only a commented-out
  `tc-is-cross-compiler` block for unrelated stack-growth properties, and
  `tc-is-cross-compiler` guards for gio-cache/postinst).
- BUT the current `meson.eclass` cross file sets
  `exe_wrapper = '$(sysroot_make_run_prefixed)'` and
  `needs_exe_wrapper = true` for cross; `sysroot.eclass:107ff sysroot_make_run_prefixed`
  generates a qemu wrapper (`QEMU_LD_PREFIX="${MYROOT}" exec qemu-aarch64 "$@"`) and
  SELF-TESTS it by compiling+running a target test exe before handing it to meson —
  i.e. the CURRENT tree has a documented, self-verifying path for meson to run
  cross-built target binaries during src_configure/compile, provided qemu+binfmt work
  (guaranteed in the builder, see 3a).

### 3c. Prior cross-built introspection in OUR sysroots

```
grep -l ' introspection' out/sessions/20260730-210421-a6d331/wl-{pki,be,fe}.rpi5/sysroot/var/db/pkg/*/*/USE
→ NO MATCHES (all three ARM sysroots)
```

No package in ANY of the bench's three rpi5 sysroots was ever built with
USE=introspection (expected — the global mask). The x86 sysroots have the full
introspection chain, but built NATIVELY in a chroot. **We have ZERO prior evidence of a
successful cross-compiled USE=introspection package on our infrastructure.**

### 3d. What the frite "-introspection" comment was recorded against

`git log -S "bootstraps a native copy" -- specs-frite/portage/make.conf.tmpl` →
commit `bc87d1e` (2026-06-23, PR #163). Verbatim from the commit message:

```
3. Add USE="-introspection" to specs-frite/portage/make.conf.tmpl: glib-2.86+
   bootstraps a native gobject-introspection copy during cross-compile
   src_configure; _need_bootstrap_gi() always fires (gi not yet in sysroot) and
   the native meson/ninja bootstrap fails in the cross-emerge environment (wrong
   EPYTHON / cross-file targeting). LXDE desktop packages do not hard-require
   introspection — it is USE-conditional on harfbuzz/pango/gdk-pixbuf/gtk+.
```

The rpi5 spec's richer comment (`specs-rpi5/portage/make.conf.tmpl:34-42`, and the
rendered make.conf in the bench sysroot) records the concrete error shape:
g-ir-scanner ran under HOST python (3.14) while `_giscanner` was built for
PYTHON_SINGLE_TARGET (python3_12) → `ImportError: _giscanner.cpython-314-...so: cannot
open shared object file` → glib's bundled g-i bootstrap dies in configure. The rpi5
`-vala` companion landed 2026-07-29 (`4d26db4`, PR #464).

IMPORTANT DELTA vs. the recorded failure: the recorded failure was under a
python3_12-target / python3_14-host SKEW (glib-2.86 era). In the CURRENT bench the
arm64 stage3 seed ships python3_14 ONLY and the rendered make.conf pins
`PYTHON_TARGETS=python3_14 PYTHON_SINGLE_TARGET=python3_14`, matching host python
(3.14.6 on this dev host; the builder container's python is what matters at build
time). The VERSION half of the recorded mis-targeting is gone; the ARCH half (an
aarch64 `_giscanner` extension cannot be dlopen'd by an x86 host python — binfmt does
not help in-process) may or may not still bite depending on which machine meson builds
the bootstrap's python extension for. Resolution probes CANNOT settle this — only a
real build can.

## 4. Candidate-A closure — resolution probes on ALL THREE rpi5 sysroots

Candidate config = baseline copy + ONE scoped package.use entry
(`package.use/zz-introspection-chain`):

```
dev-libs/glib introspection
```

(the global `USE="... -introspection -vala"` in make.conf stays untouched; per-package
package.use overrides the global default for glib only. No other package in the chain
has an `introspection` USE flag to set — gobject-introspection and pygobject depend on
glib[introspection] but carry no such flag themselves.)

Same exact builder-flag probe as §1, per sysroot:

| sysroot     | baseline probe                  | candidate-A probe |
|-------------|----------------------------------|-------------------|
| wl-pki.rpi5 | rc=1, verbatim glib[introspection] error | rc=0, firewalld-2.4.4 in plan |
| wl-be.rpi5  | rc=1, same error verbatim        | rc=0, firewalld-2.4.4 in plan |
| wl-fe.rpi5  | rc=1, same error verbatim        | rc=0, firewalld-2.4.4 in plan |

No NEW walls: candidate outputs contain ZERO occurrences of
`masked` / `REQUIRED_USE` / `USE changes are necessary` / `no ebuilds` / keyword
messages (grep-verified on all three outputs).

Target-sysroot closure (identical on all three roles): **18 package actions**, of which
the introspection enablement itself accounts for only **3**:

```
[ebuild  N ] dev-libs/gobject-introspection-common-1.86.0
[ebuild  N ] dev-libs/gobject-introspection-1.86.0        PYTHON_SINGLE_TARGET=python3_14
[ebuild  R ] dev-libs/glib-2.88.2:2                        USE="... introspection* ..."  (rebuild, USE change only)
```

The other 15 are firewalld's own inherent needs, pulled REGARDLESS of the introspection
choice: net-firewall/firewalld-2.4.4, sec-policy/selinux-firewalld, net-firewall/ipset,
dev-python/dbus-python, dev-python/pygobject, dev-python/ensurepip-pip (R), plus the
pygobject default `+cairo` chain (pycairo, cairo[-X], fontconfig, freetype, libpng,
pixman, xorg-proto, liberation-fonts, virtual/ttf-fonts). NOTE for the fix phase: adding
`dev-python/pygobject -cairo` would drop those 9 font/render packages from the headless
k8s nodes (firewalld does not need pygobject[cairo]) — optional lean-image companion,
to be probed the same way if adopted.

Probe-environment noise, disclosed: the crossdev wrapper also resolves HOST-side (`/`)
deps; on THIS dev host that adds ~66 unrelated host update lines (ffmpeg, libjxl, host
glib 2.88.1→2.88.2, a host gobject-introspection PYTHON_SINGLE_TARGET rebuild, ...).
Those are my host being slightly behind the tree snapshot, NOT part of the sysroot
closure; the builder container's host-side set will differ (and `--with-bdeps=n` keeps
it minimal there).

## 5. Candidate C shape (if ever needed)

`git grep "net-firewall/firewalld" origin/main -- 'specs*'`:

```
specs-rpi5/portage/package.use/kubernetes:6:net-firewall/firewalld nftables
specs-rpi5/portage/packages.list:25:net-firewall/firewalld
specs-x86/portage/package.use/containers + package.use/desktop (USE tuning)
specs-x86/portage/packages.list:29:net-firewall/firewalld
```

Of the 9 ARM platforms (frite, jetson, orangepi-zero2/zero2w/zero3, orangepi3-lts,
orangepi4-lts, orangepi5, rpi5), **ONLY rpi5 requests firewalld at all** — the other
eight never listed it (their firewall posture is nftables-only or nothing; a separate
fleet-consistency observation, out of scope). So a Candidate-C degradation would touch
only `specs-rpi5/portage/packages.list` (+ builder comment + gate annotation), i.e.
exactly the "shipped firewalld-less rpi5 images" hole the completeness gate was built
to close — reinforcing that C is last-resort.

Gate-wiring precedent for the NEW static regression gate (fix phase): sibling tests
live in `tests/` (e.g. `tests/build-package-completeness.sh` — pure static+render
checks, no emerge/chroot/root; and `tests/build-matrix/check.sh` — dry-run
`--print-plan` validation, wired via `make matrix-check`); CI runs each as an explicit
`bash tests/<name>.sh` line in `.gitlab-ci.yml`. The new gate ("a global USE mask must
not make a requested atom unresolvable") belongs there, fail-closed, mutation-proven
per the standing rule. A FULL resolution gate needs /var/db/repos/gentoo + a sysroot
config; a render-level static gate (spec lists × known hard USE-dep chains) is the
fallback if CI lacks the tree — decision deferred to the implementation phase.

## 6. Recommendation

**A** — scoped `dev-libs/glib introspection` in `specs-rpi5/portage/package.use/`
(one new file, e.g. `package.use/firewalld-introspection`), keeping the global
`-introspection` default AND `-vala` untouched. Facts: B is dead (§2 — every firewalld
in the tree RDEPENDs pygobject); C contradicts the gate's recorded purpose and is only
justified if A is infeasible; A's depgraph PROVABLY closes on all three real failed
sysroots with zero new walls (§4) and a marginal cost of 3 package actions.

**Honest limit of proof**: probes prove RESOLUTION, not COMPILATION. Choosing A bets
against the recorded bc87d1e/PR#163 failure ("glib-2.86+ bundled g-i bootstrap fails
cross-configure — wrong EPYTHON / cross-file targeting"; rpi5 comment:
`ImportError: _giscanner.cpython-314-...so` under a python3_12-target/3.14-host skew).
What has changed since that recording: (a) the python skew is GONE — arm64 seed +
make.conf now pin python3_14 on both sides; (b) the current tree's meson.eclass +
sysroot.eclass provide a self-testing qemu exe_wrapper for cross src_configure, and the
builder hard-requires static qemu-aarch64 + binfmt before starting; (c) glib is 2.88.2
(two bumps past the recorded 2.86). What has NOT changed: no cross build with
USE=introspection has ever succeeded on our infra (§3c), and the aarch64-vs-x86
`_giscanner` extension arch question is undecidable without compiling. **The compile-
side proof requires the operator's next real rpi5 build**; if glib[introspection] still
dies in the bootstrap, fall back to C with the evidence this build will produce
(the fix-phase PR must say this in its first paragraph).

## 7. Sendfile triage (SEPARATE issue — 20260730-061622-abaf4b / 20260730-083921-a0b40c)

Verbatim repeating unit (both sessions, `build-pki.x86.log`):

```
[WARNING] _do_sendfile failed unexpectedly
Traceback (most recent call last):
  File "/usr/lib/python3.14/site-packages/portage/util/file_copy.py", line 127, in _fastcopy
    _do_sendfile(srcfd, dstfd, offset, count)
    ~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/usr/lib/python3.14/site-packages/portage/util/file_copy.py", line 89, in _do_sendfile
    written = os.sendfile(dst, src, offset, c)
OSError: [Errno 22] Invalid argument
```

Counts: 138,334 repetitions in 061622 (1,369,509-line log), 30,252 in 083921 — AND
**150,692 in the 21:04 bench session's own build-pki.x86.log** (first at line 16305).
rpi5 logs in the same sessions: **zero**.

**Fatal: NO.** Proof from the logs themselves: in 083921, after the first storm
(triggered at `>>> Installing (1 of 1) sys-devel/gettext-0.22.5-r2`, the FIRST
image→livefs merge), the log continues `>>> Completed (1 of 1) sys-devel/gettext` and
the sysroot vdb REALLY contains `sys-devel/gettext-0.22.5-r2`; the 21:04 session
stormed identically yet progressed all the way to its real (SELinux staging) failure.
Mechanism (portage-3.0.81 `file_copy.py`, same code as the traceback's line numbers):
`copyfile()` → `_fastcopy` tries FICLONE (fails, silent) → `copy_file_range` (fails,
errno in `_CFR_IGNORE`, silently latched off) → `sendfile` → EINVAL → **warn with full
traceback and re-raise** → `copyfile` catches and falls back to `shutil.copyfile`,
which SUCCEEDS. One traceback per merged file; the copy always completes.

Filesystem pair: destination is the sysroot under the operator's **eCryptfs** home
(`df -T /home/magus/GitHub` → `ecryptfs` over `/home/magus/.Private`); source is the
chroot's `/var/tmp/portage` image dir, which build-x86-host-stage4.sh:4378-4416
deliberately bind-mounts onto host **xfs** scratch (the pre-existing eCryptfs 143-char
filename-limit workaround — the builder ALREADY knows the sysroot is eCryptfs and
explicitly keeps "INSTALLED files ... land in the eCryptfs sysroot"). eCryptfs has no
splice/sendfile write support → sendfile(dst_on_ecryptfs) = EINVAL; FICLONE is
cross-device; copy_file_range is cross-fs. So EVERY x86 in-chroot merge file takes the
3-failed-syscalls + traceback path.

Why the two morning sessions ENDED mid-storm: NOT decidable from the logs as a
sendfile fatality — both logs end mid-warning-storm with no error banner and no
completion banner (061622 at `>>> Installing (170 of 212) sys-libs/libsemanage-3.10`,
083921 at `>>> Installing (113 of 212) dev-libs/libverto-0.3.2`), consistent with the
operator killing apparently-hung builds (the storm makes merges crawl and dominates
the console). The 21:04 session proves the storm itself does not stop a build.

Exposure of current main: **YES** — any x86 chroot build with the work dir under
eCryptfs (the operator's standing layout) storms; the rpi5 cross legs did not warn
(0 occurrences; their merges are done by the CONTAINER's portage, evidently a build
without this noisy python fallback — container portage version not verifiable from
the logs).

Upstream: the noisy-warning-on-every-file behaviour is portage's
`portage/util/file_copy.py` (warning added with the pure-python `_fastcopy` port);
`_do_copy_file_range` already has a silent-ignore errno list (`_CFR_IGNORE`, and the
code cites bugs.gentoo.org/828844) but `_do_sendfile` has NO equivalent — EINVAL on a
sendfile-less dst fs is "unexpected" and traceback-logged although `copyfile()`
recovers by design. No specific upstream issue number identifiable from the log alone.

**Fix small: NO — report only.** The unambiguous cause is portage-upstream noise +
eCryptfs lacking sendfile; the honest in-repo remedies are either (a) the operator
moving `out/` off eCryptfs (mirrors the existing 143-char workaround, but relocating
the merge TARGET is an operator storage decision, not a small code fix), or (b)
patching/pinning portage inside the builder image — neither is small and unambiguous,
so per the task rules this is reported, not fixed. Worth a line in the platform TODO
queue: "x86-in-chroot merges on eCryptfs: 30k-150k warning-tracebacks per build bloat
logs ~10x and slow every merge to the shutil.copyfile path."

## Probe hygiene

- Every resolution emerge in this investigation carried `--pretend`
  (transcript-greppable). One additional `emerge --version` was run — a pure
  version-string print (recorded in §Limitations: portage 3.0.81.2), no resolution,
  no build, no sysroot involved; disclosed here so the transcript grep has context.
- The bench session dir was never written: configs were copied to the session
  scratchpad and probes ran with `PORTAGE_CONFIGROOT` pointing at the copies;
  `PORTAGE_DEPCACHEDIR` + probe outputs also live in scratch.
- `.nobuild-bin/` exit-127 stubs (docker, podman, qemu-system-*, sudo, pkexec) created
  in this worktree.

## Limitations

1. Resolution probes prove the DEPGRAPH closes; they cannot prove glib/g-i/pygobject
   COMPILE cross — that proof is the operator's next real rpi5 build (see §6).
2. Probes ran on this dev host's portage 3.0.81.2 / gentoo tree at
   /var/db/repos/gentoo (same tree the builders bind-mount, but the container's
   portage/python may differ; the builder invocation flags were replicated exactly,
   including the crossdev wrapper's --root-deps=rdeps).
3. Host-side plan lines in the probes are contaminated by THIS host's installed set
   (§4); target-sysroot lines are authoritative.
4. The builder container's own python/portage versions (relevant to both the
   introspection EPYTHON story and the rpi5 sendfile silence) are not verifiable
   without running the container.
5. The two morning sessions' terminal cause (kill vs crash) is not recorded in their
   logs; classification "ended mid-storm, no banner" is the strongest supportable claim.

## 8. FIX PHASE (2026-08-05) — implemented, proven, gated

Chosen: **Candidate A**. Commits: `bfa9d61` (the fix), `b6eaa5d` (the gate).

### 8a. The fix

- `specs-rpi5/portage/package.use/firewalld-introspection` — ONE active line,
  `dev-libs/glib introspection`, under a header that states the chain, the
  incident, and the COMPILE-SIDE BET in full (what changed since bc87d1e/PR#163,
  what the runtime backstop is, what the recorded fallback is).
- `specs-rpi5/portage/make.conf.tmpl` — the `-introspection` comment block now
  cross-references the scoped exception (comment-only change; the USE line
  itself is untouched).
- Platforms fixed: **rpi5 only, because rpi5 is the only cross platform that
  requests firewalld** (`git grep net-firewall/firewalld origin/main -- 'specs*'`
  hits specs-rpi5 + specs-x86 only; x86 builds natively in a chroot with no
  -introspection wall and its bench vdb really contains firewalld-2.4.0). The
  gate below walks ALL TEN platform specs, so any future (platform, requested
  atom, wall) pairing fails at gate time.

### 8b. A/B proof on the three REAL failed sysroots (committed file, exact builder flags)

Baseline = bench `etc/portage` copied unmodified; Fixed = baseline + the
COMMITTED `package.use/firewalld-introspection`. Same invocation as §1
(crossdev wrapper, `--with-bdeps=n --usepkg=y --binpkg-respect-use=y --update
--deep --newuse --keep-going` + the four toolchain excludes, `--pretend`).

| sysroot     | baseline                         | fixed |
|-------------|----------------------------------|-------|
| wl-pki.rpi5 | rc=1, wall verbatim (below)      | rc=0, firewalld-2.4.4 in plan, wall-grep 0, 18 target-sysroot actions |
| wl-be.rpi5  | rc=1, wall verbatim              | rc=0, same closure (18 actions) |
| wl-fe.rpi5  | rc=1, wall verbatim              | rc=0, same closure (18 actions) |

Baseline wall (identical on all three, ROOT path being the only difference):

```
emerge: there are no ebuilds built with USE flags to satisfy ">=dev-libs/glib-2.82.0:2[introspection]" for /home/magus/GitHub/hugmesh-generator/out/sessions/20260730-210421-a6d331/wl-pki.rpi5/sysroot/.
!!! One of the following packages is required to complete your request:
- dev-libs/glib-2.88.2::gentoo (Change USE: +introspection)
(dependency required by "dev-libs/gobject-introspection-1.86.0::gentoo" [ebuild])
(dependency required by "dev-python/pygobject-3.56.3::gentoo" [ebuild])
(dependency required by "net-firewall/firewalld-2.4.4::gentoo[python_single_target_python3_14]" [ebuild])
(dependency required by "net-firewall/firewalld" [argument])
```

Fixed-config plan, the introspection-attributable target lines (pki shown;
be/fe identical modulo the sysroot path):

```
[ebuild  N    ] dev-libs/gobject-introspection-common-1.86.0::gentoo to <sysroot>
[ebuild   R   ] dev-libs/glib-2.88.2:2::gentoo to <sysroot> USE="elf introspection* ..."
[ebuild  N    ] dev-libs/gobject-introspection-1.86.0::gentoo to <sysroot>
[ebuild  N    ] net-firewall/firewalld-2.4.4::gentoo to <sysroot>
```

Wall-grep on every fixed output:
`grep -cE 'masked|REQUIRED_USE|USE changes are necessary|no ebuilds|The following keyword changes|One of the following'`
→ **0** on pki, be, fe. (Host-side `[ebuild U]` lines for this dev host's own
glib 2.88.1→2.88.2 etc. remain probe noise, exactly as disclosed in §4.)

### 8c. The gate — tests/requested-atoms-resolvable.sh (RAR)

Static curated-chain check (justification in the script header: CI verify jobs
run in python:3 containers with no portage and no /var/db/repos/gentoo, and a
fresh-root resolution is minutes/platform — so gate time proves the curated
table statically and THIS file holds the deep resolution proof). Sections:
(A) chain table x all 10 platform specs — global-USE final-state parse
(last token wins across accumulated USE= lines), packages*.list membership,
package.use final-state override parse (sorted files, last token wins);
(B) the live rpi5/firewalld instance pinned: atom still requested, override
line present, builder still copies package.use/* verbatim into the sysroot,
make.conf cross-reference present; (C) the runtime backstop armed
(_payload-gate-lib.sh sourced + ALLOW_MISSING_PACKAGES=false).

Wired into `tests/build-matrix/check.sh` as the RAR bucket — the SLX delegate
shape: missing script charged in full (16), short tally charged as failures,
counted into TOTAL and the exit status; runs via `make matrix-check`.

Mutation proofs (each numstat-confirmed, then restored and re-run green):

1. `sed` the override line to a comment → `git diff --numstat` = `1 1` →
   gate: **14 passed, 2 failed, rc=1**, the FAIL naming atom+wall+chain:
   `FAIL [rpi5] requested atom net-firewall/firewalld is UNRESOLVABLE: global
   USE=-introspection (make.conf.tmpl) with no scoped package.use 'dev-libs/glib
   introspection' override — chain: firewalld -> pygobject:3 ->
   gobject-introspection -> glib[introspection] ...`
2. delete the override file → numstat `0 57` → same 2 FAILs, rc=1.
3. park the gate script itself → check.sh: `FAIL [RAR] tests/requested-atoms-resolvable.sh
   — gate script missing`, `RAR 0 passed, 16 failed`, `TOTAL 1128 passed, 16
   failed`, rc=1 (the wiring cannot silently skip).

### 8d. Ruling gates (clean tree, verbatim tallies)

- `tests/build-matrix/check.sh` (make matrix-check): `TOTAL: 1144 passed, 0 failed`,
  rc=0 — incl. `RAR (requested-atoms resolvable): 16 passed, 0 failed`; all
  developer smokes PASS (incl. arm-payload-gates, package-completeness,
  spec-use-parity).
- `tests/build-arm-payload-gates.sh`: `== 146 passed, 0 failed ==`, rc=0.
- `tests/build-package-completeness.sh`: `== 24 passed, 0 failed ==`, rc=0.
- `tests/requested-atoms-resolvable.sh` standalone: `== 16 passed, 0 failed ==`, rc=0.
- Studio suite: not run — no studio/ file touched.

### 8e. Sendfile

Per §7: **report-only, no code change** — the storm is non-fatal portage noise
(eCryptfs destination lacks sendfile; `copyfile()` falls back to
`shutil.copyfile` and every merge completes). The honest remedies (move `out/`
off eCryptfs, or patch/pin portage in the builder image) are operator/storage
decisions, not small unambiguous fixes. Queued for the platform TODO list.

### 8f. What is deliberately NOT in this fix

- `dev-python/pygobject -cairo` (drops 9 font/render packages from headless
  nodes) — a separate lean-image candidate; probe it the same A/B way if adopted.
- The fleet-consistency observation that the other eight ARM platforms never
  request firewalld at all — separate track.
