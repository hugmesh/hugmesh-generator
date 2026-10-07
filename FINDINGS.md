# FINDINGS — ARM firewalld unresolvable (introspection chain) + sendfile triage

> **Status on 2026-10-07 (`origin/main` @ `cbf5d9a6`). Read this before the rest.**
> This is the 2026-07-30 to 2026-08-05 record. Two of its conclusions no longer hold.
>
> 1. **The firewalld fix (§6, §8) was applied, then reverted.** The compile-side
>    bet in §6 lost. The real rpi5 resume build of 2026-08-05 built 45 of the 52
>    chain packages, then `glib-2.88.2` died twice in `src_configure`, inside its
>    bundled gobject-introspection bootstrap. #513 (`b06b9036`) therefore deleted
>    `specs-rpi5/portage/package.use/firewalld-introspection`, removed
>    `net-firewall/firewalld` from `specs-rpi5/portage/packages.list` behind a
>    comment block, and rewrote section B of `tests/requested-atoms-resolvable.sh`
>    to pin the exclusion. That is Candidate C (§5), the fallback §6 named. Today no
>    ARM platform requests firewalld; host firewalling on rpi5 is nftables, iptables
>    and the `hugmesh-firewall-reconcile` OpenRC service. The gate now passes 25/0
>    (it passed 16/0 when §8 was written).
> 2. **The sendfile noise (§7, §8e) is no longer report-only.** A pinned patch to
>    portage's `file_copy.py` (`scripts/patch-portage-file-copy.py`, `cdcf6e1b`,
>    2026-08-19) silences the traceback for the expected errnos. It is applied to
>    the builder image and to every sysroot, and re-applied in the x86 chroot after
>    portage updates itself (`f6b6dd20`, 2026-08-27). The patch does not fix the
>    cause: eCryptfs still has no splice write.
>
> The commits `bfa9d61` and `b6eaa5d` named in §8 are not in `main`'s history; the
> work was squashed into `a7b2842d` (#512). The build logs and the bench session
> `out/sessions/20260730-210421-a6d331` are gone (`out/sessions` now holds one
> other session), so every count taken from them is UNVERIFIED and cannot be
> re-measured. File and line numbers are as of that date.

Investigation branch: `fix/arm-firewalld-installable` (off origin/main 49f70b88; merged as #512, then partly reverted by #513, see the status above).
Test bench (read-only): `out/sessions/20260730-210421-a6d331`, the operator's failed
2026-07-30 21:04 8-image mesh build. Every resolution probe below is
`emerge --pretend`, run with `PORTAGE_CONFIGROOT` pointed at scratch copies of the
sysroots' `etc/portage`. The bench was never modified.

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

and the completeness gate's refusal at the end of the log:

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

Output, verbatim. It matches the log except the ROOT path, which the builder container
bind-mounts at `/out`:

```
emerge: there are no ebuilds built with USE flags to satisfy ">=dev-libs/glib-2.82.0:2[introspection]" for /home/magus/GitHub/hugmesh-generator/out/sessions/20260730-210421-a6d331/wl-pki.rpi5/sysroot/.
!!! One of the following packages is required to complete your request:
- dev-libs/glib-2.88.2::gentoo (Change USE: +introspection)
(dependency required by "dev-libs/gobject-introspection-1.86.0::gentoo" [ebuild])
(dependency required by "dev-python/pygobject-3.56.3::gentoo" [ebuild])
(dependency required by "net-firewall/firewalld-2.4.4::gentoo[python_single_target_python3_14]" [ebuild])
(dependency required by "net-firewall/firewalld" [argument])
```

REPRODUCED. A plain `emerge --pretend`, without the crossdev wrapper's exact flags,
prints autounmask suggestions instead (`>=dev-libs/glib-2.88.2 introspection` plus
`>=sys-libs/libselinux-3.11 python` / `>=sys-process/audit-4.1.4-r4 python`). Probes
must use the builder's exact flags.

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

**firewalld-2.4.0 already RDEPENDs `dev-python/pygobject:3`.** firewalld is a Python
daemon at every version in the tree. Pinning ARM to 2.4.0 (Candidate B) does not avoid
the pygobject → gobject-introspection → glib[introspection] chain. The x86 image meets
it natively: its vdb has `dev-libs/glib-2.88.2` with `introspection` in USE, plus
`gobject-introspection-1.86.0` and `pygobject-3.56.3`, built inside the x86 chroot where
g-ir-scanner's python matches. **Candidate B is dead.**

## 3. Candidate A feasibility facts

### 3a. binfmt / qemu on this host and in the builder

This dev host (read-only check of /proc/sys/fs/binfmt_misc):

```
qemu-aarch64: enabled, interpreter /usr/bin/qemu-aarch64, flags: OC
aarch64:      enabled, interpreter /usr/bin/qemu-aarch64, flags: (none)
status:       enabled
```

`/usr/bin/qemu-aarch64` on this host is dynamically linked x86-64. The builder is
stricter. `build-rpi5-stage4.sh:2947,2971` refuses to start unless the builder image
ships a static qemu-aarch64 (the final stage of `Dockerfile.build` emerges
`app-emulation/qemu[static-user] QEMU_USER_TARGETS=aarch64`) and the container is
`--privileged`, so binfmt_misc can be mounted and registered. So running target
binaries under qemu-user is a guaranteed precondition of every rpi5 build. The
run-target-binaries half of an introspection cross-build is covered.

### 3b. glib ebuild / eclass cross handling (current tree)

`dev-libs/glib-2.88.2.ebuild` (`/var/db/repos/gentoo/dev-libs/glib/`):
- `_need_bootstrap_gi()` fires when USE=introspection and no usable
  `>=dev-libs/gobject-introspection-1.86.0` is installed (always true for a fresh
  sysroot) → bootstraps an internal gobject-introspection (with an internal glib) via
  meson (`-Dpython="${EPYTHON}"`, `--force-fallback-for=glib`), installs it into
  `${T}/bootstrap-gi-prefix`, prepends it to PATH/PKG_CONFIG/LD_LIBRARY_PATH/PYTHONPATH,
  then configures the real glib with `$(meson_native_use_feature introspection)`.
- The ebuild has no cross-specific handling of the bootstrap. It has a commented-out
  `tc-is-cross-compiler` block for unrelated stack-growth properties, and
  `tc-is-cross-compiler` guards for gio-cache and postinst.
- But the current `meson.eclass` cross file sets
  `exe_wrapper = '$(sysroot_make_run_prefixed)'` and
  `needs_exe_wrapper = true` for cross builds. `sysroot.eclass:107ff sysroot_make_run_prefixed`
  generates a qemu wrapper (`QEMU_LD_PREFIX="${MYROOT}" exec qemu-aarch64 "$@"`) and
  self-tests it by compiling and running a target test exe before handing it to meson.
  So the tree has a documented, self-verifying path for meson to run cross-built target
  binaries during src_configure and compile, provided qemu and binfmt work (the builder
  guarantees both, see 3a). The real build of 2026-08-05 showed this path does not make
  the bootstrap compile (see the status at the top).

### 3c. Prior cross-built introspection in OUR sysroots

```
grep -l ' introspection' out/sessions/20260730-210421-a6d331/wl-{pki,be,fe}.rpi5/sysroot/var/db/pkg/*/*/USE
→ NO MATCHES (all three ARM sysroots)
```

No package in any of the bench's three rpi5 sysroots was ever built with
USE=introspection. That is expected, given the global mask. The x86 sysroots have the
full chain, built natively in a chroot. **We have no prior evidence of a successful
cross-compiled USE=introspection package on our infrastructure.**

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

The rpi5 spec's fuller comment (`specs-rpi5/portage/make.conf.tmpl:34-42`, and the
rendered make.conf in the bench sysroot) records the error: g-ir-scanner ran under the
host python (3.14) while `_giscanner` was built for PYTHON_SINGLE_TARGET (python3_12)
→ `ImportError: _giscanner.cpython-314-...so: cannot open shared object file` →
glib's bundled g-i bootstrap dies in configure. The rpi5 `-vala` companion landed
2026-07-29 (`4d26db4`, PR #464).

One difference from the recorded failure matters. That failure was a
python3_12-target / python3_14-host skew (glib-2.86 era). In the bench, the arm64
stage3 seed ships python3_14 only, and the rendered make.conf pins
`PYTHON_TARGETS=python3_14 PYTHON_SINGLE_TARGET=python3_14`, which matches the host
python (3.14.6 on this dev host; at build time the builder container's python is what
counts). The version half of the mis-targeting is gone. The architecture half may
still bite: an aarch64 `_giscanner` extension cannot be dlopen'd by an x86 host
python, and binfmt does not help in-process. Whether it bites depends on which machine
meson builds the bootstrap's python extension for. Resolution probes cannot settle
this. Only a real build can. (The real build of 2026-08-05 did: the bootstrap still
failed.)

## 4. Candidate-A closure — resolution probes on ALL THREE rpi5 sysroots

Candidate config = baseline copy + ONE scoped package.use entry
(`package.use/zz-introspection-chain`):

```
dev-libs/glib introspection
```

(The global `USE="... -introspection -vala"` in make.conf stays untouched; the
per-package entry overrides the default for glib only. No other package in the chain
has an `introspection` USE flag to set: gobject-introspection and pygobject depend on
glib[introspection] but carry no such flag themselves.)

Same exact builder-flag probe as §1, per sysroot:

| sysroot     | baseline probe                  | candidate-A probe |
|-------------|----------------------------------|-------------------|
| wl-pki.rpi5 | rc=1, verbatim glib[introspection] error | rc=0, firewalld-2.4.4 in plan |
| wl-be.rpi5  | rc=1, same error verbatim        | rc=0, firewalld-2.4.4 in plan |
| wl-fe.rpi5  | rc=1, same error verbatim        | rc=0, firewalld-2.4.4 in plan |

No new walls: the candidate outputs contain no `masked`, `REQUIRED_USE`,
`USE changes are necessary`, `no ebuilds` or keyword messages (grep-verified on all
three outputs).

Target-sysroot closure (identical on all three roles): **18 package actions**, of which
the introspection enablement itself accounts for only **3**:

```
[ebuild  N ] dev-libs/gobject-introspection-common-1.86.0
[ebuild  N ] dev-libs/gobject-introspection-1.86.0        PYTHON_SINGLE_TARGET=python3_14
[ebuild  R ] dev-libs/glib-2.88.2:2                        USE="... introspection* ..."  (rebuild, USE change only)
```

The other 15 are firewalld's own needs, pulled whatever the introspection choice: net-firewall/firewalld-2.4.4, sec-policy/selinux-firewalld, net-firewall/ipset,
dev-python/dbus-python, dev-python/pygobject, dev-python/ensurepip-pip (R), plus the
pygobject default `+cairo` chain (pycairo, cairo[-X], fontconfig, freetype, libpng,
pixman, xorg-proto, liberation-fonts, virtual/ttf-fonts). Note for the fix phase: adding
`dev-python/pygobject -cairo` would drop those 9 font and render packages from the
headless k8s nodes, because firewalld does not need pygobject[cairo]. It is an optional
lean-image companion, to be probed the same way if adopted.

Probe noise: the crossdev wrapper also resolves host-side (`/`) deps. On this dev host
that adds about 66 unrelated host update lines (ffmpeg, libjxl, host glib 2.88.1→2.88.2,
a host gobject-introspection PYTHON_SINGLE_TARGET rebuild, ...). They come from this
host being slightly behind the tree snapshot. They are not part of the sysroot
closure. The builder container's host-side set will differ, and `--with-bdeps=n` keeps
it minimal there.

## 5. Candidate C shape (if ever needed)

`git grep "net-firewall/firewalld" origin/main -- 'specs*'`:

```
specs-rpi5/portage/package.use/kubernetes:6:net-firewall/firewalld nftables
specs-rpi5/portage/packages.list:25:net-firewall/firewalld
specs-x86/portage/package.use/containers + package.use/desktop (USE tuning)
specs-x86/portage/packages.list:29:net-firewall/firewalld
```

Of the 9 ARM platforms (frite, jetson, orangepi-zero2/zero2w/zero3, orangepi3-lts,
orangepi4-lts, orangepi5, rpi5), **ONLY rpi5 requested firewalld at all** (as of 2026-08-05; since #513 none does) — the other
eight never listed it (their firewall is nftables only, or nothing; a separate
fleet-consistency question, out of scope). So Candidate C would touch only
`specs-rpi5/portage/packages.list` (plus a builder comment and a gate annotation). That
is exactly the "shipped firewalld-less rpi5 images" hole the completeness gate was built
to close, which is why C is the last resort.

Where the new static gate would go (fix phase): its sibling tests live in `tests/`.
`tests/build-package-completeness.sh` does static and render checks only, with no
emerge, chroot or root. `tests/build-matrix/check.sh` validates `--print-plan` dry
runs and is wired via `make matrix-check`. CI runs each as an explicit
`bash tests/<name>.sh` line in `.gitlab-ci.yml`. The new gate ("a global USE mask must
not make a requested atom unresolvable") belongs there, fail-closed and
mutation-proven per the standing rule. A full resolution gate needs
/var/db/repos/gentoo and a sysroot config. If CI lacks the tree, the fallback is a
render-level static gate (spec lists × known hard USE-dep chains). That decision was
left to the implementation phase.

## 6. Recommendation

**A**: a scoped `dev-libs/glib introspection` in `specs-rpi5/portage/package.use/`
(one new file, for example `package.use/firewalld-introspection`), keeping the global
`-introspection` default and `-vala` untouched. The facts: B is dead (§2: every
firewalld in the tree RDEPENDs pygobject). C contradicts the gate's recorded purpose
and is justified only if A is infeasible. A's depgraph closes on all three failed
sysroots with no new walls (§4), at a marginal cost of 3 package actions.

**Limit of the proof.** Probes prove resolution, not compilation. Choosing A bets
against the failure recorded in bc87d1e / PR #163 ("glib-2.86+ bundled g-i bootstrap
fails cross-configure — wrong EPYTHON / cross-file targeting"; rpi5 comment:
`ImportError: _giscanner.cpython-314-...so` under a python3_12-target / 3.14-host skew).
Three things have changed since: (a) the python skew is gone, because the arm64 seed
and make.conf now pin python3_14 on both sides; (b) the current tree's meson.eclass and
sysroot.eclass provide a self-testing qemu exe_wrapper for cross src_configure, and the
builder requires static qemu-aarch64 and binfmt before it starts; (c) glib is 2.88.2,
two bumps past the recorded 2.86. Two things have not changed: no cross build with
USE=introspection has ever succeeded on our infrastructure (§3c), and the question of
the aarch64 versus x86 `_giscanner` extension cannot be decided without compiling.
**The compile-side proof needs the operator's next real rpi5 build.** If
glib[introspection] still dies in the bootstrap, fall back to C with the evidence that
build produces. The fix-phase PR must say this in its first paragraph.

(Outcome: the bet lost on 2026-08-05; see the status at the top.)

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

**Fatal: no.** The logs show it. In 083921, the first storm starts at
`>>> Installing (1 of 1) sys-devel/gettext-0.22.5-r2`, the first image→livefs merge.
The log then continues `>>> Completed (1 of 1) sys-devel/gettext`, and the sysroot vdb
really contains `sys-devel/gettext-0.22.5-r2`. The 21:04 session stormed the same way
and still ran to its real failure (SELinux staging).
Mechanism (portage-3.0.81 `file_copy.py`, the code behind the traceback's line numbers):
`copyfile()` → `_fastcopy` tries FICLONE (fails, silent) → `copy_file_range` (fails,
errno in `_CFR_IGNORE`, silently latched off) → `sendfile` → EINVAL → **warn with full
traceback and re-raise** → `copyfile` catches it and falls back to `shutil.copyfile`,
which succeeds. One traceback per merged file. The copy always completes.

The filesystem pair: the destination is the sysroot under the operator's **eCryptfs**
home (`df -T /home/magus/GitHub` → `ecryptfs` over `/home/magus/.Private`). The source
is the chroot's `/var/tmp/portage` image dir, which build-x86-host-stage4.sh:4378-4416
deliberately bind-mounts onto host **xfs** scratch. That is the older workaround for
eCryptfs's 143-character filename limit, so the builder already knows the sysroot is
eCryptfs and says so: "INSTALLED files ... land in the eCryptfs sysroot". eCryptfs
has no splice or sendfile write support, so sendfile to an eCryptfs destination gives
EINVAL. FICLONE fails across devices and copy_file_range across filesystems. So every
file of every x86 in-chroot merge takes the path of three failed syscalls plus a
traceback.

Why the two morning sessions ended mid-storm cannot be decided from the logs as a
sendfile fatality. Both end mid-storm with no error banner and no completion banner
(061622 at `>>> Installing (170 of 212) sys-libs/libsemanage-3.10`, 083921 at
`>>> Installing (113 of 212) dev-libs/libverto-0.3.2`). That fits the operator killing
builds that looked hung: the storm makes merges crawl and fills the console. The 21:04
session shows the storm itself does not stop a build.

Exposure of `main` at the time: **yes.** Any x86 chroot build with the work dir under
eCryptfs (the operator's standing layout) storms. The rpi5 cross legs did not warn
(0 occurrences). Their merges run in the container's portage, evidently a build
without this noisy python fallback; the container's portage version cannot be read
from the logs.

Upstream: the per-file warning comes from portage's `portage/util/file_copy.py` (added
with the pure-python `_fastcopy` port). `_do_copy_file_range` already has a
silent-ignore errno list (`_CFR_IGNORE`; the code cites bugs.gentoo.org/828844).
`_do_sendfile` has no equivalent, so EINVAL on a destination filesystem without
sendfile is "unexpected" and gets a traceback, although `copyfile()` recovers by
design. The logs alone give no upstream issue number.

**Fix small: NO — report only** (as of 2026-08-05; patched on 2026-08-19, see the status at the top). The cause is clear: portage's upstream noise plus eCryptfs
lacking sendfile. The in-repo remedies are (a) the operator moving `out/` off
eCryptfs, which mirrors the 143-character workaround but moves the merge target and
is a storage decision, not a small code fix, or (b) patching or pinning portage inside
the builder image. Neither is small and unambiguous, so by the task rules it is
reported, not fixed. It is worth a line in the platform TODO queue: "x86-in-chroot
merges on eCryptfs: 30k-150k warning-tracebacks per build bloat logs ~10x and slow
every merge to the shutil.copyfile path."

## Probe hygiene

- Every resolution emerge in this investigation carried `--pretend`, so a transcript
  grep finds them. One extra `emerge --version` was run. It only prints the version
  (recorded in §Limitations: portage 3.0.81.2); it resolves nothing, builds nothing and
  touches no sysroot. It is disclosed so the transcript grep has context.
- The bench session dir was never written. Configs were copied to the session
  scratchpad, and probes ran with `PORTAGE_CONFIGROOT` pointing at the copies.
  `PORTAGE_DEPCACHEDIR` and the probe outputs also live in scratch.
- `.nobuild-bin/` holds exit-127 stubs (docker, podman, qemu-system-*, sudo, pkexec),
  created in this worktree.

## Limitations

1. Resolution probes prove that the depgraph closes. They cannot prove that
   glib, g-i and pygobject compile in a cross build. That proof is the operator's
   next real rpi5 build (see §6).
2. Probes ran on this dev host's portage 3.0.81.2 and gentoo tree at
   /var/db/repos/gentoo. The builders bind-mount the same tree, but the container's
   portage and python may differ. The builder's flags were replicated exactly,
   including the crossdev wrapper's --root-deps=rdeps.
3. Host-side plan lines in the probes reflect this host's installed set (§4).
   Target-sysroot lines are the authoritative ones.
4. The builder container's own python and portage versions matter to both the
   introspection EPYTHON story and the rpi5 sendfile silence. They cannot be read
   without running the container.
5. The logs do not record why the two morning sessions ended (kill or crash). "Ended
   mid-storm, no banner" is the strongest claim they support.

## 8. FIX PHASE (2026-08-05) — implemented, proven, gated

Chosen: **Candidate A** (reverted by #513, see the status at the top). Commits: `bfa9d61` (the fix), `b6eaa5d` (the gate); both were squashed into `a7b2842d` (#512).

### 8a. The fix

- `specs-rpi5/portage/package.use/firewalld-introspection` (removed by #513): one
  active line, `dev-libs/glib introspection`, under a header that states the chain,
  the incident and the compile-side bet in full (what changed since bc87d1e / PR #163,
  the runtime backstop, the recorded fallback).
- `specs-rpi5/portage/make.conf.tmpl`: the `-introspection` comment block
  cross-referenced the scoped exception. Comment-only change; the USE line itself
  was untouched.
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

A static check of a curated chain. The script header gives the reason: CI verify jobs
run in python:3 containers with no portage and no /var/db/repos/gentoo, and a
fresh-root resolution takes minutes per platform. So the gate proves the curated
table statically, and this file holds the deep resolution proof. Sections:
(A) chain table x all 10 platform specs — global-USE final-state parse
(last token wins across accumulated USE= lines), packages*.list membership,
package.use final-state override parse (sorted files, last token wins);
(B) the live rpi5/firewalld instance pinned: atom still requested, override
line present, builder still copies package.use/* verbatim into the sysroot,
make.conf cross-reference present; (C) the runtime backstop armed
(_payload-gate-lib.sh sourced + ALLOW_MISSING_PACKAGES=false).

Wired into `tests/build-matrix/check.sh` as the RAR bucket, in the SLX delegate
shape: a missing script is charged in full (16), a short tally is charged as
failures, and both count into TOTAL and the exit status. It runs via
`make matrix-check`. After #513, section B pins the opposite state (firewalld
absent, override absent, paper trail present), and the standalone gate passes 25/0.

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

Per §7 (as of 2026-08-05): **report-only, no code change** (a pinned patch followed on 2026-08-19, see the status at the top) — the storm is non-fatal portage noise
(the eCryptfs destination lacks sendfile; `copyfile()` falls back to
`shutil.copyfile`, and every merge completes). The remedies (move `out/` off
eCryptfs, or patch or pin portage in the builder image) are operator and storage
decisions, not small, clear fixes. Queued for the platform TODO list.

### 8f. What is deliberately NOT in this fix

- `dev-python/pygobject -cairo` (drops 9 font and render packages from headless
  nodes): a separate lean-image candidate. Probe it the same A/B way if adopted.
- The fleet-consistency question: the other eight ARM platforms never request
  firewalld at all. A separate track.
