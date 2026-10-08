# PYTHON_TARGETS and stage3 seed drift — root-cause analysis

**Status:** analysis, 2026-07-30. Written against `origin/main` @ `21f0ca0`.
**Trigger:** the 11-image mesh build of session `20260729-233913-719d4e` died on its
FIRST image (`build-pki.x86`) in a `dev-python/*` slot conflict, blocking every
queued image behind it.

> **Status on 2026-10-07 (`origin/main` @ `cbf5d9a6`): the fix in §7 is on `main`.**
> It landed in #486 (`41a74124`, 2026-07-30) together with this document. "Today"
> and "currently" in §0 and §2 to §9 mean `21f0ca0`; read them as the record, not as the
> present. What `main` has now:
>
> * No `specs-*/portage/make.conf.tmpl` assigns `PYTHON_TARGETS` or
>   `PYTHON_SINGLE_TARGET`; each carries a comment instead (for example
>   `specs-x86/portage/make.conf.tmpl:110`). There are ten spec dirs now (the
>   survey counted eight).
> * `scripts/_python-targets-lib.sh` (`pt_apply_seed_targets`) derives both values
>   from the seed. All ten builders (nine ARM, one x86) source it and call it after
>   the specs are installed and before the first emerge into the sysroot
>   (x86: `build-x86-host-stage4.sh:3866`). It fails the build if the seed cannot
>   be read.
> * It departs from §7 item 2 in three ways. It skips `dev-lang/python-exec`, whose
>   USE lists every target it supports. It intersects the vdb targets with the
>   interpreters the seed really has. It picks the newest non-freethreading target
>   as `PYTHON_SINGLE_TARGET`. The `usr/lib/python3.*` probe is only the fallback
>   for the interpreter list.
> * Every `specs-*/portage/package.use/python-targets` is now a comment-only
>   placeholder (one md5, `41798f02a98de4772e6d2150dec93afc`); the builder
>   overwrites it with a seed-derived `*/* PYTHON_TARGETS: ...` line.
> * `build-x86-host-stage4.sh:5709` runs `emerge --oneshot --update --newuse
>   sys-apps/portage` (§7 item 5).
> * `tests/scripts/test-python-targets-seed.sh` asserts the invariant, not the
>   literal (§8). It passes 126/0 on `main`.
> * Not changed, and still the same fault line: the build container's own seed in
>   `Dockerfile.build:287` (`*/* PYTHON_TARGETS: python3_12 python3_13`) and the
>   `python3_12` requirement in `scripts/_host-guard-lib.sh:226`.
>
> The session directories, logs and sysroots cited below are no longer on disk
> (`out/sessions` holds one other session), so the measurements taken from them are
> UNVERIFIED and cannot be re-measured. §1 was re-run on 2026-10-07; see §1.3.

This is a document, not a commit message, for three reasons. The rewritten
`tests/scripts/test-python-targets-seed.sh` guard points here when it fails. A stage3
python bump happens again and again, and whoever handles the next one needs this. And
it is longer than a commit message should be, yet it is the least that justifies not
simply deleting the pin: deleting it re-breaks the 2026-07-16 fleet failure (§5).

---

## 0. TL;DR

* `PYTHON_TARGETS` assigned in **make.conf REPLACES** the profile default.
  `PYTHON_TARGETS` in **package.use is a DELTA that ADDS** to it. The man pages and
  the portage source both say so, and an executed experiment confirms it (§1).
* Every `specs-*/portage/make.conf.tmpl` assigned `PYTHON_TARGETS="python3_12"`, so
  the effective value on every platform was exactly `{python3_12}`. The profile's
  targets were **wiped**, and the additive `package.use` seed meant to widen the set
  added nothing it did not already have (§2).
* The amd64 stage3 seed moved. `stage3-amd64-hardened-openrc-20260726T160854Z` ships
  **no python3.12 at all**; its packages are built for `python3_13 python3_14`. The
  arm64 seed ships **python3.14 only** (§3).
* So the pin was not stale. It was *inverted*. We forced the payload onto an
  interpreter the seed does not have. Meanwhile the seed's own `sys-apps/portage` and
  `app-portage/gemato` kept demanding `python3_13` and `python3_14` from the same
  `dev-python/*` slots. The x86 builder had just started to `--exclude` them from both
  long emerge passes (PR #479, merged 3h before the failing run). Two irreconcilable
  instances per slot meant a slot conflict (§4).
* One invariant fixes this failure **and** the 2026-07-16 jetson failure the pin was
  made for: **`PYTHON_TARGETS` must be a superset of the target set the seed's own
  installed packages were built with.** Derive it from the seed at build time. Never
  freeze it as a literal (§5, §7).
* `build-rpi5-stage4.sh` already did a *narrower* version (it rewrote make.conf to the
  seed's python). That is why rpi5 reached its payload gate in the same session in
  which x86 died. The mechanism existed in exactly 1 of 8 builders and took `tail -1`
  instead of the union (§6).

---

## 1. Portage semantics: make.conf assignment vs package.use delta vs profile

### 1.1 What the documentation says

`man 5 make.conf` — precedence and incrementals:

```
If no setting is found in the make.conf files, Portage checks make.globals. If no
setting is found there, the profile's default setting is grabbed from
/etc/portage/make.profile/make.defaults.
...
Exceptions are incremental variables such as USE, CONFIG_PROTECT*, and
ACCEPT_KEYWORDS.  Incremental variables are propagated down from make.defaults to
make.globals to make.conf to the environment settings.
```

So make.conf **overrides** the profile for every variable that is not incremental.
Only *incremental* variables stack. `USE_ORDER` documents the stacking layers:

```
USE_ORDER = "env:pkg:conf:defaults:pkginternal:features:repo:env.d"
  Determines the precedence of layers in the incremental stacking of the USE
  variable. Precedence decreases from left to right such that env overrides pkg,
  pkg overrides conf, and so forth.
    pkg       Per-package USE from /etc/portage/package.use
    conf      USE from make.conf
    defaults  USE from make.defaults and package.use in the profile
```

`man 5 portage` — `package.use` format, emphasis added:

```
- USE flags can be prefixed with USE_EXPAND name followed by a colon (:) and a
  space. In this case, all the names following it are treated as values for the
  USE_EXPAND. Note that if you need to remove earlier assignments or defaults,
  you need to explicitly specify '-*'.

  Example:
    # set preferred video card for all packages
    */* VIDEO_CARDS: -* radeon
```

"if you need to remove earlier assignments or defaults, you need to explicitly
specify `-*`" says outright that a `package.use` USE_EXPAND line **adds**. The
canonical example has to spell out `-*` to get replacement.

### 1.2 What the source says

`PYTHON_TARGETS` is **not** an incremental. `portage/const.py:122` in portage 3.0.81.2 (it is `:125` in 3.0.82.2):

```python
INCREMENTALS = (
    "ACCEPT_KEYWORDS", "CONFIG_PROTECT", "CONFIG_PROTECT_MASK", "ENV_UNSET",
    "FEATURES", "IUSE_IMPLICIT", "PRELINK_PATH", "PRELINK_PATH_MASK",
    "PROFILE_ONLY_VARIABLES", "USE", "USE_EXPAND", "USE_EXPAND_HIDDEN",
    "USE_EXPAND_IMPLICIT", "USE_EXPAND_UNPREFIXED",
)
```

(`USE_EXPAND` — the *list of expandable names* — is incremental. The expanded
variables themselves, `PYTHON_TARGETS` etc., are not.)

`portage/package/ebuild/config.py`, `regenerate()`, the USE_EXPAND stacking loop
(`:2961-2999` in 3.0.82.2) — this is the exact mechanism:

```python
for var in cur_use_expand:
    var_lower = var.lower()
    is_not_incremental = var not in myincrementals
    if is_not_incremental:
        prefix = var_lower + "_"
        prefix_len = len(prefix)
        for x in list(myflags):
            if x[:prefix_len] == prefix:
                myflags.remove(x)          # <-- WIPES everything accumulated so far
    for x in curdb[var].split():
        ...
        myflags.add(var_lower + "_" + x)
```

A config layer that *sets the variable at all* first deletes every
`python_targets_*` flag accumulated so far, then adds only its own. The profile is
not such a layer. It is handled earlier and translated into plain USE flags so that
sub-profiles stack (`if curdb is configdict_defaults: continue`). make.conf (`conf`)
**is** such a layer. So **a make.conf assignment replaces the profile.**

`package.use` never reaches that code path. `UseManager._parse_user_files_to_extatomdict`
turns `PYTHON_TARGETS: python3_12` into the plain USE flag string
`python_targets_python3_12`:

```python
if flag[-1] == ":":
    use_expand_prefix = flag[:-1].lower() + "_"
    continue
if flag[0] == "-":
    nv = "-" + use_expand_prefix + flag[1:]
else:
    nv = use_expand_prefix + flag
```

…which `config.setcpv()` appends to the pkg layer's USE — with portage's own comment
saying so, `config.py:1998` (`:1988` in 3.0.82.2):

```python
self.configdict["pkg"]["USE"] = self.puse[:]  # this gets appended to USE
```

Plain USE flags go through the additive branch of the same loop (`myflags.add(x)`),
with no wipe. So **package.use is a delta that adds.**

### 1.3 Executed proof

Rather than argue from reading, throwaway `PORTAGE_CONFIGROOT`s were built
against this machine's real
`/var/db/repos/gentoo/profiles/default/linux/amd64/23.0` profile and evaluated with
`portage.package.ebuild.config` (portage 3.0.81.2). No emerge, no network, no build.
Rows A to D are what `tests/scripts/python-targets-semantics-probe.py` rebuilds
(its row D label, "what specs-*/ ship today", is out of date: see the status
above); row E is a fifth, hand-built root that the probe does not repeat. On
2026-10-07 all five rows were re-run on portage 3.0.82.2 and gave the same
values (the profile default is still `python3_14`,
`profiles/base/make.defaults:130-131`):

| # | config | effective `PYTHON_TARGETS` | effective `PYTHON_SINGLE_TARGET` |
|---|--------|---------------------------|----------------------------------|
| A | profile only | `python3_14` | `python3_14` |
| B | + make.conf `PYTHON_TARGETS="python3_12"` | **`python3_12`** | `python3_12` |
| C | + package.use `*/* PYTHON_TARGETS: python3_12` | **`python3_14 python3_12`** | `python3_14` |
| D | + **both** (what `specs-*/` ship today) | **`python3_12`** | `python3_12` |
| E | + make.conf seed-union `"python3_13 python3_14 python3_12"` + the package.use delta | `python3_13 python3_14 python3_12` | `python3_14` |

B against C is the whole argument, measured. The same value *loses* `python3_14` when
written in make.conf and *keeps* it when written in package.use. D shows that the
shipped configuration behaved exactly like B: **the package.use seed was dead weight**,
because make.conf had already narrowed the set to the one value package.use would have
added.

**Verdict: the replace-vs-add claim is CONFIRMED, from docs, from source, and by
execution.** The header comment in `specs-x86/portage/package.use/python-targets`
(as of `21f0ca0`; the file is now a placeholder) stated the intent was to "widen a USE flag, enabling the 3.12 target everywhere at
once". make.conf does the opposite of widening.

---

## 2. Effective values per platform, today

`profile -> make.conf -> package.use`, in order, for every spec dir on `21f0ca0`:

| platform | profile default | make.conf.tmpl | package.use delta | **effective PYTHON_TARGETS** | **effective PYTHON_SINGLE_TARGET** |
|---|---|---|---|---|---|
| x86 (`make.conf.tmpl:78-79`) | `python3_14` | `PYTHON_TARGETS="python3_12"` / `PYTHON_SINGLE_TARGET="python3_12"` | `+python3_12` | `python3_12` | `python3_12` |
| rpi5 (`:85-86`) | `python3_14` | same | `+python3_12` | `python3_12` → **rewritten to the seed's `python3_14` at build time** (see §6) | `python3_12` → `python3_14` |
| jetson (`:54-55`) | `python3_14` | same | `+python3_12` | `python3_12` | `python3_12` |
| frite (`:66-67`) | `python3_14` | same | `+python3_12` | `python3_12` | `python3_12` |
| orangepi5 (`:79-80`) | `python3_14` | same | `+python3_12` | `python3_12` | `python3_12` |
| orangepi-zero2 (`:65-66`) | `python3_14` | same | `+python3_12` | `python3_12` | `python3_12` |
| orangepi-zero2w (`:65-66`) | `python3_14` | same | `+python3_12` | `python3_12` | `python3_12` |
| orangepi-zero3 (`:65-66`) | `python3_14` | same | `+python3_12` | `python3_12` | `python3_12` |

All eight `package.use/python-targets` files were byte-identical
(`md5 77497071b3f59634ff84e19b1bc1f4c7`) and all eight make.conf templates carried the
identical two lines. "profile default" is the value measured in §1.3 row A from a
2026-07-11 tree sync; `profiles/base/make.defaults` is the *only* file in the whole
profile tree that assigns `PYTHON_TARGETS`, and it reads:

```
PYTHON_TARGETS="python3_14"
PYTHON_SINGLE_TARGET="python3_14"
```

Confirmation from the failing run itself — every scheduled ebuild in
`build-pki.x86.log` prints the replaced set, never a union:

```
[ebuild  N     ] sys-libs/libselinux-3.11  ... PYTHON_TARGETS="python3_12 -python3_13 -python3_14 (-python3_15)"
[ebuild   R    ] dev-python/certifi-3024.7.22  PYTHON_TARGETS="python3_12* -python3_13* -python3_14* ..."
```

An unparenthesised `-python3_14` means "in IUSE, unmasked, and disabled". Had the
package.use delta been the operative mechanism, `python3_14` would have stayed on. The
rendered sysroot config says the same, verbatim:

```
out/sessions/20260729-233913-719d4e/wl-pki.x86/sysroot/etc/portage/make.conf:78:PYTHON_TARGETS="python3_12"
out/sessions/20260729-233913-719d4e/wl-pki.x86/sysroot/etc/portage/make.conf:79:PYTHON_SINGLE_TARGET="python3_12"
out/sessions/20260729-233913-719d4e/wl-pki.x86/sysroot/etc/portage/package.use/python-targets:*/* PYTHON_TARGETS: python3_12
```

### 2.1 `PYTHON_SINGLE_TARGET` is its own, separate hazard

`specs-x86/portage/package.use/python-targets` said, in its own header at `21f0ca0`:

> `PYTHON_SINGLE_TARGET` is deliberately NOT set here: two enabled single-targets
> violate REQUIRED_USE (`^^` exactly-one), and the resolver already derives the
> right single target from the installed 3.12 interpreter.

…and then make.conf set it anyway, on all eight platforms. The `^^` argument
concerns *package.use*, a delta that could enable two single-targets. make.conf's
assignment is a replacement, so it cannot produce two. It causes a different problem:
it pins the single-target to an interpreter the seed does not ship. Measured in the
failing sysroot, a package that had no business touching python3.12 was rebuilt
against it:

```
sys-apps/systemd-utils-260.1-r1/USE: python_single_target_python3_12   (BUILD_TIME 2026-07-30 06:56 UTC — i.e. built by THIS run)
```

whereas the same package in the same session's rpi5 sysroot, where make.conf was
seed-rewritten, reads `python_single_target_python3_14`.

**Correct value:** `PYTHON_SINGLE_TARGET` must be exactly one member of the effective
`PYTHON_TARGETS`. The only defensible choice is the seed's own preferred interpreter,
which is the highest target the seed ships. Freezing it to a literal is wrong for the
reason that applies to `PYTHON_TARGETS`, and worse, because `^^ REQUIRED_USE` leaves it
no room to degrade.

---

## 3. What the current stage3 seeds actually ship

### amd64 — `stage3-amd64-hardened-openrc-20260726T160854Z`

Read from the failing run's own extracted sysroot,
`out/sessions/20260729-233913-719d4e/wl-pki.x86/sysroot`:

| evidence | value |
|---|---|
| `usr/lib/python3.*` | `python3.12` `python3.13` `python3.14` |
| `var/db/pkg/dev-lang/python-3.13.14/BUILD_TIME` | 2026-06-15 06:59 UTC — **seed** |
| `var/db/pkg/dev-lang/python-3.14.6/BUILD_TIME` | 2026-06-22 00:16 UTC — **seed** |
| `var/db/pkg/dev-lang/python-3.12.13_p1/BUILD_TIME` | **2026-07-30 06:49 UTC — installed BY THIS RUN** |
| `var/db/pkg/dev-python/certifi-3024.7.22/USE` | `python_targets_python3_13 python_targets_python3_14` (BUILD_TIME 2026-06-15 — seed) |
| `var/db/pkg/sys-apps/portage-3.0.81.2/USE` | `python_targets_python3_13 python_targets_python3_14` (BUILD_TIME 2026-07-13 — seed) |
| `var/db/pkg/app-portage/gemato-20.12/USE` | `python_targets_python3_13 python_targets_python3_14` (BUILD_TIME 2026-06-15 — seed) |

**The amd64 seed ships python 3.13 and 3.14 and no python3.12.** The `python3.12`
directory in that sysroot is not seed content. Our own pin created it, three hours into
the failing run.

### arm64 — same session, `wl-pki.rpi5/sysroot`

| evidence | value |
|---|---|
| `usr/lib/python3.*` | `python3.14` **only** |
| `var/db/pkg/dev-lang/` | `python-3.14.6_p1` only |
| `var/db/pkg/sys-apps/portage-*/USE` | `python_targets_python3_14` |
| `var/db/pkg/app-portage/gemato-20.12/USE` | `python_targets_python3_14` (BUILD_TIME 2026-07-06 — seed) |
| `var/db/pkg/dev-python/certifi-3024.7.22/USE` | `python_targets_python3_14` |

Corroborated across every archived arm64 sysroot on disk — `out/wl-pki.rpi5`,
`out/wl-fe.rpi5`, `out/wl-frite.frite` (2026-07-12) and
`out/sessions/20260719-103006-a775c2/wl-*.rpi5` — all `python3.14` only,
`portage` built `python_targets_python3_14`.

### Are they the same set? **No.**

```
amd64 seed : {python3_13, python3_14}
arm64 seed : {python3_14}
jetson seed (2026-07-19 archive, wl-*.jetson): {python3_12, python3_14}
our pin    : {python3_12}   on all of them
```

Three seeds, one frozen literal. The pin is wrong on all three, in two different
directions. That is why the value cannot be a literal in a template. It belongs to the
*seed*, and the seed floats independently per arch and per snapshot date.

---

## 4. The actual failure mechanism

`build-pki.x86.log:105309` onward:

```
!!! Multiple package instances within a single package slot have been pulled
!!! into the dependency graph, resulting in a slot conflict:

dev-python/requests:0

  (dev-python/requests-2.34.2-1:0/0::gentoo, installed) ... PYTHON_TARGETS="python3_13 python3_14 -python3_12" pulled in by
    dev-python/requests[python_targets_python3_12(-)?,python_targets_python3_13(-)?,python_targets_python3_14(-)?,python_targets_python3_15(-)?]
      required by (app-portage/gemato-20.12-3:0/0::gentoo, installed) ... PYTHON_TARGETS="python3_13 python3_14 -python3_12"

  (dev-python/requests-2.34.2:0/0::gentoo, ebuild scheduled for merge) ... PYTHON_TARGETS="python3_12 -python3_13 -python3_14 ..." pulled in by
    >=dev-python/requests-2.30.0[...] required by (dev-python/sphinx-9.1.0:0/0::gentoo, ebuild scheduled for merge)
```

Chain, in full:

1. A dependency atom `[python_targets_pythonX(-)?]` means *"if the parent has target X
   enabled, the child must have X enabled too."*
2. The seed's **installed** `app-portage/gemato` has `{3_13, 3_14}`. So it requires
   `dev-python/requests` to have `{3_13, 3_14}`.
3. Our config forced every *newly resolved* ebuild to `{3_12}` **and nothing else**
   (§1, §2). A `requests` built that way can never satisfy the installed gemato.
4. Portage cannot pick one instance that satisfies both parents, so it keeps both:
   two `dev-python/requests:0` in one slot, a slot conflict. The same happened to
   `certifi`, `charset-normalizer`, `idna`, `urllib3` and `pysocks`.
5. Resolution aborts, `packages.list` never merges, and the #461/#465 completeness gate
   correctly reports
   `ERROR: stage4 payload incomplete — missing: grub-install dracut parted jq nmcli
   kubelet kubeadm containerd`. **That gate is working. Do not weaken it.**

### 4.1 Why now, and not last week

`gemato` is irreconcilable only if it is not itself rebuilt. It is not rebuilt only
because `sys-apps/portage`, which pins it, is excluded from every pass that could
rebuild it.

`008b01c` ("fix(build): x86 artifacts shipped unbootable/degraded/shim-less with
exit 0 — close four holes (#479)", 2026-07-29 **20:38:33 -0700**) added, for a good
and unrelated reason (portage self-replacing mid-run):

```diff
-emerge --update --deep --newuse --keep-going ${EMERGE_EXCLUDE} @world \
+emerge --update --deep --newuse --keep-going --exclude sys-apps/portage ${EMERGE_EXCLUDE} @world 2>&1 | _emerge_notice_sink \
```

…on both long passes, plus a new standalone
`emerge --oneshot --update sys-apps/portage` — **without `--newuse`**, unlike the
`baselayout` line immediately below it which does carry `--newuse`.

The failing run started **2026-07-29 23:39**, three hours later. Measured effect,
`sys-apps/portage` `BUILD_TIME` in each session's x86 sysroot:

```
20260729-065121-ce11e0  wl-pki.x86                    portage BUILD 07-29 14:10 UTC   (rebuilt onto the pin)  no conflict
20260729-065612-729bbc  wl-standalone-unaffiliated.x86 portage BUILD 07-29 15:51 UTC  (rebuilt onto the pin)  no conflict
...
20260729-233913-719d4e  wl-pki.x86                    portage BUILD 07-13 03:59 UTC   (SEED, never rebuilt)   SLOT CONFLICT
20260729-233913-719d4e  wl-be.x86                     portage BUILD 07-13 03:59 UTC   (SEED, never rebuilt)   SLOT CONFLICT
```

Before #479, the `--newuse @world` pass dragged `portage` and `gemato` onto `python3_12`
with everything else. The inverted pin was then *self-consistent* and only expensive:
it rebuilt the whole python world and installed a second interpreter into every
image. After #479 the package manager stayed frozen at the seed's targets while the
payload was forced onto a disjoint set, and the latent defect became fatal.

**#479 is not the bug.** It exposed the bug. The pin has been wrong since the seed
moved. #479 removed the accident that hid it.

---

## 5. Would an *additive* make.conf have prevented the 2026-07-16 failure?

**Answer: yes. But "additive" is the wrong invariant to ship, because it would not
reliably prevent the failure of 2026-07-29. The correct invariant is "superset of the
seed".**

### 5.1 What actually happened on 2026-07-16

The `package.use/python-targets` header recorded it, as of `21f0ca0`:

> freshly-pulled ebuilds (setuptools-83 / setuptools-scm-10.2 → jaraco-text →
> jaraco-context, hatchling, flit-core, urllib3, jinja2, cython, …) come up with
> `python_targets_python3_12` UNSET and the @world/payload emerge ABORTS behind a
> wall of "The following USE changes are necessary to proceed:
> `>=dev-python/… python_targets_python3_12`" (real jetson edge-ai fleet failure
> 2026-07-16 01:31, session 20260715-235432)

The vdb of that era's sysroots agrees with the comment's premise for *that* seed.
`out/sessions/20260719-103006-a775c2/wl-edge_ai.jetson/sysroot` has `python3.12` and
`python3.14`, with `sys-apps/portage` built `python_targets_python3_12`. So on the
jetson seed of July 2026 the installed `portage` → `gemato` →
`requests`/`urllib3`/`certifi` chain really required `python_targets_python3_12`,
while the tree's profile default had already moved to `python3_13`/`python3_14`.
Newly resolved deps came up without `3_12`, could not satisfy the installed chain, and
portage demanded the USE change.

Note the shape: **2026-07-16 and 2026-07-29 are the same bug in mirror image.** In
both, "the newly-resolved `dev-python/*` set does not contain the targets the *seed's
installed* packages require". On 2026-07-16 the missing target was `3_12`. On
2026-07-29 it was `3_13`/`3_14`.

### 5.2 Reasoning it through with an additive make.conf

Additive make.conf means effective = profile ∪ `{python3_12}`.

* **On the 2026-07-16 jetson seed:** profile was `{3_13, 3_14}`, so effective becomes
  `{3_12, 3_13, 3_14}` ⊇ seed `{3_12}`. The whole `libselinux → systemd-utils →
  portage/gemato` chain named in the comment gets `python_targets_python3_12`
  available on every freshly-resolved dep, so the "USE changes are necessary:
  `python_targets_python3_12`" wall never forms. **Prevented. ✔**
  (Independently confirmed by §1.3 row C: the package.use delta alone, with no
  make.conf assignment, yields `python3_14 python3_12` — the widening the comment
  said it wanted.)
* **On the amd64 seed of 2026-07-29:** the profile is `{3_14}` (§2), so additive gives
  `{3_12, 3_14}`. The seed's installed `portage`/`gemato` need `{3_13, 3_14}`. `3_13`
  is still missing, so a freshly built `requests` still cannot satisfy the installed
  gemato. **The same slot conflict, minus one package. NOT prevented. ✘**

So additive is *necessary*, because it removes the wipe that is the immediate defect,
but it is **not sufficient**. Anything that derives the target set from the *profile*
inherits the profile's drift away from the seed. The installed vdb was built against
the seed, so the seed is what must be tracked.

### 5.3 The invariant that covers both

> **`PYTHON_TARGETS` ⊇ (every `python_targets_*` flag enabled in the seed's own
> `/var/db/pkg`), and `PYTHON_SINGLE_TARGET` ∈ `PYTHON_TARGETS`, both derived at
> build time from the extracted sysroot — never a literal.**

* 2026-07-16 (seed `{3_12}`, profile `{3_13,3_14}`) → effective ⊇ `{3_12}` → the
  autounmask wall cannot form. ✔
* 2026-07-29 (seed `{3_13,3_14}`, profile `{3_14}`) → effective ⊇ `{3_13,3_14}` →
  the installed gemato/portage are satisfiable by one instance per slot → no slot
  conflict. ✔
* Any future stage3 python bump → tracked automatically, no source edit. ✔

---

## 6. The fix already exists — in exactly one of eight builders

This is the state at `21f0ca0`. The block below is gone from `main`: every builder now calls `pt_apply_seed_targets` instead (see the status at the top). It was at `build-rpi5-stage4.sh:3290-3305`:

```bash
# The arm64 stage3's python FLOATS — the current seed ships ONLY python3.14, but
# the template historically pinned python3_12. A target with no interpreter in the
# seed leaves @system unsatisfiable ... Pin PYTHON_TARGETS/PYTHON_SINGLE_TARGET to
# whatever python the seed actually ships so this survives future stage3 python
# bumps without another hardcode edit.
_seed_py="$(ls -d "${SYSROOT}"/usr/lib/python3.* 2>/dev/null | sed 's#.*/##' | sort -V | tail -1)"
if [[ "${_seed_py}" =~ ^python3\.[0-9]+$ ]]; then
    _seed_pt="${_seed_py/./_}"
    sed -i -E "s/^PYTHON_TARGETS=.*/PYTHON_TARGETS=\"${_seed_pt}\"/; \
               s/^PYTHON_SINGLE_TARGET=.*/PYTHON_SINGLE_TARGET=\"${_seed_pt}\"/" \
        "${SYSROOT}/etc/portage/make.conf"
```

`grep -c _seed_pt` over all eight builders at `21f0ca0`: **rpi5 = 4, every other builder = 0.** (On 2026-10-07 the count is 0 in all ten; the helper is `pt_apply_seed_targets`.)

That is the measured reason rpi5 survived the same session that killed x86: its
rendered sysroot make.conf reads `PYTHON_TARGETS="python3_14"` /
`PYTHON_SINGLE_TARGET="python3_14"` (not the template's `python3_12`), and
`build-pki.rpi5.log` reaches `Stage4 payload verified (...)` with a single unrelated
missing atom (`net-firewall/firewalld`) and **zero** occurrences of `slot conflict`.

The rpi5 version had two defects of its own:

1. **`sort -V | tail -1` takes the highest, not the union.** That is right for a seed
   with one interpreter (arm64: `{3.14}`) and **wrong for amd64**, whose seed ships
   `{3.13, 3.14}`. Taking `3.14` alone still drops `3_13` and reproduces the residual
   conflict of §5.2.
2. **`usr/lib/python3.*` is a proxy, not the fact.** The fact is which
   `python_targets_*` are enabled in `${SYSROOT}/var/db/pkg/*/*/USE`. On the failing
   x86 sysroot the directory listing already reads `3.12 3.13 3.14` *because our own
   pin installed 3.12*. A builder that ran this heuristic after that point would read
   its own damage back in. Derive from the vdb USE flags and take the union.

---

## 7. Recommended fix

_Implemented in #486; see the status at the top for the three differences._ In layers, smallest blast radius first. Items 1–3 are the fix; 4 is the durable
guard; 5 is the loose thread #479 left.

1. **`specs-*/portage/make.conf.tmpl` (×8):** stop assigning a frozen literal. Either
   drop both lines, or (preferred, so the value shows in the rendered artifact) render
   them from a template token,
   `PYTHON_TARGETS="@@PYTHON_TARGETS@@"` / `PYTHON_SINGLE_TARGET="@@PYTHON_SINGLE_TARGET@@"`,
   filled from the seed. Either way the shipped repo must hold **no python version
   literal** in those two variables.
2. **All 8 builders:** move rpi5's seed detection into a shared helper and fix its two
   defects. Derive the **union** of the `python_targets_*` enabled across
   `${SYSROOT}/var/db/pkg/*/*/USE`, and fall back to `${SYSROOT}/usr/lib/python3.*`
   only if the vdb probe finds nothing. Run it **before the first emerge touches the
   sysroot**. Set `PYTHON_TARGETS` to that union and `PYTHON_SINGLE_TARGET` to its
   highest member. Log the derived value.
3. **`specs-*/portage/package.use/python-targets` (×8):** keep the file. It is the
   *correct* mechanism (a delta, §1) and the belt to make.conf's braces. But the
   widening it applies must stop being a frozen literal too. The simplest correct form:
   the builder writes the seed-derived list into it at the moment it writes make.conf,
   and the checked-in file stays as a documented, inert fallback. The cost of *not*
   doing this: the hardcoded `python3_12` drags `dev-lang/python:3.12` into an image
   whose seed has no 3.12. That is a whole extra interpreter plus a rebuild of the
   entire python world, per image.
4. **`tests/scripts/test-python-targets-seed.sh`:** rewrite it to assert the intent,
   not the literal (see §8). The guard then asserted the exact string
   `*/* PYTHON_TARGETS: python3_12` in 8 spec dirs, in the 7 ARM copy loops and in
   `Dockerfile.build`. It would fail on any correct fix, and it was the mechanism that
   would freeze the next wrong literal in place.
5. **`build-x86-host-stage4.sh:4570`:** add `--newuse` to
   `emerge --oneshot --update sys-apps/portage`, as on the `baselayout` line directly
   beneath it. #479 means "portage merges FIRST and ALONE". Without `--newuse`, the
   emerge does nothing when the version is already current. The package manager then
   stays on the seed's targets, and `--exclude sys-apps/portage` stops any later pass
   from fixing it. With items 1–3 this is defence in depth, not load-bearing. It is
   still a real hole, and it takes one word.

### Risks

* **Image size and build time.** A seed-derived union can hold more than one target
  (amd64: `{3_13, 3_14}`), so `python-r1` packages build for two interpreters instead of
  one. That is cheaper than the behaviour at `21f0ca0`, which built for one target
  *and* installed an extra interpreter and rebuilt the python world. It is still more
  than a single-target build. If images must carry exactly one interpreter, that is a
  *separate* change: strip the seed down first, then derive.
* **`PYTHON_SINGLE_TARGET` and `^^ REQUIRED_USE`.** "Highest member of the union" is
  safe only if that member is in the union. Assert it in the guard.
* **Ordering.** The derivation must read the vdb *before* any emerge into the sysroot,
  or it reads back its own effect (§6, defect 2).
* **rpi5 behaviour change.** rpi5 got `{3_14}`, and the union rule also gives `{3_14}`
  on that seed, so nothing changes. But rpi5 was the one green ARM path, so diff any
  refactor of its block against a rendered make.conf. Do not eyeball it.
* **The host and container half is a different root.** `Dockerfile.build` and the ARM
  builders' host-side `/etc/portage/package.use/hugmesh-host-build-backends` seed the
  *build container's own* root (`python3_12 python3_13`). That root really has
  python3.12, and it is not the target sysroot. Do not mix the two: changing the
  sysroot rule must not silently rewrite the container rule.
  `scripts/_host-guard-lib.sh:226` also requires the *operator's* live
  `PYTHON_TARGETS` to contain `python3_12` for native (non-docker) cross builds. That
  is another frozen literal, out of scope here, on the same fault line.
* **This is not a full fix for a seed whose interpreter the tree is dropping.** If a
  future stage3 ships a python that the ebuild tree has already dropped from
  `PYTHON_COMPAT`, no target set can reconcile them. The answer is a newer seed, and
  the guard should say so rather than pretend.

---

## 8. What the guard test must assert instead

At `21f0ca0`, `tests/scripts/test-python-targets-seed.sh` hard-coded
`*/* PYTHON_TARGETS: python3_12` in three places (spec dirs, ARM copy loops,
`Dockerfile.build`) and was wired into `check.sh`. Any correct fix failed it. It was
rewritten in #486 to assert the invariant, so that the *next* stage3 python bump is
caught instead of re-frozen. The six points below were its specification. The script's
sections cover them: no frozen literal (1), a delta stays a delta (2), every builder
derives (3), the behavioural check, including the single target (4), and the structure
that is still load-bearing (5). It adds two more: the host and container shape (6) and
the `pam[audit]` seed (7).

1. **No frozen version literal where the seed decides.** No
   `specs-*/portage/make.conf.tmpl` may assign `PYTHON_TARGETS` or
   `PYTHON_SINGLE_TARGET` to a `python3_NN` literal (a `@@TOKEN@@` is fine).
2. **Every builder derives from the seed.** All 8 `build-*-stage4.sh` must contain the
   seed-derivation block, read the sysroot's vdb or `usr/lib`, and write the derived
   value into the rendered `make.conf` *before* the first emerge into that sysroot.
3. **A delta stays additive.** No `*/* PYTHON_TARGETS:` line may contain `-*`, which
   would turn the delta back into a replacement. Assert the *shape*, never the
   version.
4. **`PYTHON_SINGLE_TARGET` is exactly one value and a member of `PYTHON_TARGETS`.**
   Assert on the derived output, not on the template.
5. **A behavioural check, not a grep.** Build a throwaway `PORTAGE_CONFIGROOT` from a
   spec dir plus a synthetic seed vdb, run the derivation, and assert that the
   effective `PYTHON_TARGETS` is a superset of the synthetic seed's set. Use two
   fixtures: a `{3_12}` seed (the 2026-07-16 shape) and a `{3_13,3_14}` seed (the
   2026-07-29 shape). Both must pass. This is the only assertion that encodes §5.3, and
   it needs no emerge, no network and no root.
6. Keep the existing structural assertions that are still correct and free of
   versions: ARM builders copy `package.use/*` unconditionally; `build-x86` does
   **not** role-filter `python-targets`; the `pam-audit` seed is present.

---

## 9. Blast radius

File and line references are as of `21f0ca0`; they have moved.

| file | why |
|---|---|
| `specs-x86/portage/make.conf.tmpl` (78-79) | frozen `PYTHON_TARGETS`/`PYTHON_SINGLE_TARGET` literal |
| `specs-rpi5/portage/make.conf.tmpl` (85-86) | same |
| `specs-jetson/portage/make.conf.tmpl` (54-55) | same |
| `specs-frite/portage/make.conf.tmpl` (66-67) | same |
| `specs-orangepi5/portage/make.conf.tmpl` (79-80) | same |
| `specs-orangepi-zero2/portage/make.conf.tmpl` (65-66) | same |
| `specs-orangepi-zero2w/portage/make.conf.tmpl` (65-66) | same |
| `specs-orangepi-zero3/portage/make.conf.tmpl` (65-66) | same |
| `specs-*/portage/package.use/python-targets` (×8, identical) | frozen `python3_12` widening + a header comment whose factual premise ("the stage3 seed … built for 3.12") is no longer true for any current seed |
| `build-x86-host-stage4.sh` | no seed derivation at all; `package.use` copy loop at :3254-3269; `emerge --oneshot --update sys-apps/portage` at :4570 missing `--newuse`; `--exclude sys-apps/portage` at :4603/:4616/:4627 |
| `build-rpi5-stage4.sh` | has the derivation (:3290-3305) but `tail -1` instead of union, and probes `usr/lib` instead of the vdb; host-side seed at :2948 |
| `build-jetson-stage4.sh` | no derivation; host-side seed at :1025 |
| `build-frite-stage4.sh` | no derivation; host-side seed at :1025 |
| `build-orangepi5-stage4.sh` | no derivation; host-side seed at :1049 |
| `build-orangepi-zero2-stage4.sh` | no derivation; host-side seed at :1109 |
| `build-orangepi-zero2w-stage4.sh` | no derivation; host-side seed at :1120 |
| `build-orangepi-zero3-stage4.sh` | no derivation; host-side seed at :1123 |
| `Dockerfile.build` (233-248) | bakes the container-root `*/* PYTHON_TARGETS: python3_12 python3_13` twin — *container root, not sysroot*; touch only deliberately |
| `tests/scripts/test-python-targets-seed.sh` | asserts the exact frozen literal in 8 spec dirs + 7 ARM copy loops + `Dockerfile.build`; **fails on any correct fix**; must be rewritten per §8 |
| `tests/scripts/test-host-mutation-guard.sh` (157-158) | asserts the container seed line `^\*/\* PYTHON_TARGETS: python3_12 python3_13$` verbatim — moves only if `Dockerfile.build` moves |
| `scripts/_host-guard-lib.sh` (198-268) | requires the operator's live `PYTHON_TARGETS` to contain `python3_12` for native cross builds — same fault line, separate decision |
| `tests/build-matrix/check.sh` | wiring only; no change expected, but the guard's name/output shape is consumed here |
| `docs/PYTHON-TARGETS-SEED-DRIFT.md` | this file |

---

## 10. Evidence index

Everything above is read-only from the operator's failed build tree; nothing was
re-run.

* `out/sessions/20260729-233913-719d4e/build-pki.x86.log` — slot conflict at
  :105309; per-ebuild `PYTHON_TARGETS="python3_12 -python3_13 -python3_14"` from
  :105146; completeness-gate ERROR at EOF.
* `out/sessions/20260729-233913-719d4e/build-pki.rpi5.log` — `Stage4 payload
  verified`, `grep -c 'slot conflict'` = **0**.
* `out/sessions/20260729-233913-719d4e/wl-pki.x86/sysroot/` — rendered make.conf,
  rendered package.use, `var/db/pkg/*/*/{USE,BUILD_TIME}`.
* `out/sessions/20260729-233913-719d4e/wl-pki.rpi5/sysroot/` — seed-rewritten
  make.conf (`python3_14`), arm64 vdb.
* `out/sessions/20260719-103006-a775c2/wl-*.jetson/sysroot/` — the 2026-07-16-era
  jetson seed (`python3.12` + `python3.14`, `portage` = `python_targets_python3_12`).
* `/usr/share/man/man5/make.conf.5`, `/usr/share/man/man5/portage.5`.
* `/usr/lib/python3.12/site-packages/portage/const.py`,
  `…/portage/package/ebuild/config.py`,
  `…/portage/package/ebuild/_config/UseManager.py` (portage 3.0.81.2).
* `/var/db/repos/gentoo/profiles/base/make.defaults` (the only profile file that
  assigns `PYTHON_TARGETS`).
* §1.3 experiment — four synthetic `PORTAGE_CONFIGROOT`s evaluated through
  `portage.package.ebuild.config`; reproduced by
  `tests/scripts/python-targets-semantics-probe.py`.
