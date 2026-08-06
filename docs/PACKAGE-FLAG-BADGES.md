# Package flag badges — the semantics the Studio must render

_State key: **✅ facts established, all cited to files on this machine** ·
**⛔ no feature code in this document** — this is the ground-truth lane for the
four-column per-package flag display. Everything below was re-derived from
portage 3.0.81.2's own source, its man pages, the Gentoo tree at
`/var/db/repos/gentoo`, and real captured output from the live fleet build
`out/sessions/20260729-233913-719d4e`. Where the operator's stated mapping
differs from portage's real semantics, the **real** semantics are recorded and
the difference is called out._

The operator asked, during live QA of a real mesh build, for the emerge stage to
show — per package — **four separate columns** (USE_EXPAND-style flags, plain USE
flags, KEYWORDS, LICENSE), each appearing **only when it has content**; every
flag rendered as a **hoverable badge** carrying real documentation; and **colour
semantics mirroring portage's console output, each colour also carrying a tiny
emoji** so meaning never depends on colour perception.

This document establishes what is true, what is reachable offline, and what is
simply not available — so nothing downstream has to guess.

---

## 0. Three corrections up front

Everything here is verified below. These three matter enough to state first,
because building to the stated premise instead of the real one would ship a
badge that means the wrong thing.

**(a) The operator's colour mapping is not portage's.** The ask was "newuse
(green) / from a dependency (red) / profile (yellow parens)". Portage's actual
axes are *enablement* and *change since the last merge*, not *who asked for the
flag*:

| operator's belief | portage 3.0.81.2 reality |
|---|---|
| green = newuse | **green = the flag flipped state since the last merge** (`f*` on, `-f*` off). Closest to "newuse", but it is a transition marker, not a provenance marker. |
| red = pulled in by a dependency | **red = enabled and unchanged.** Red carries *no* provenance meaning whatsoever. |
| yellow parens = profile | Two different things fused. **Parentheses = forced or masked by the profile** (correct). **Yellow = the flag is newly present in / newly removed from IUSE** (`%`) — an unrelated axis. A profile-forced flag can be red, blue *or* yellow. |

**Portage's resolver output cannot tell you why a flag is on.** There is no
"came from a dependency" state, no "came from package.use" state, no "came from
the profile default" state. `use.force`/`use.mask` membership is the only
provenance portage renders, and it renders it as parentheses. Any badge claiming
richer provenance would be fabricating it.

**(b) The Pi is not building in parallel either.** The premise "x86 should also
do builds in parallel jobs as pi" rests on the Studio showing `>>> Jobs:` lines
for rpi5 and none for x86. That line is **not** evidence of parallelism — see
§6. Both builders run `--jobs=1`, deliberately, for a recorded OOM reason. In
the live rpi5 log, of the 1 739 scheduler lines, the 562 that report a running
count **all** say `1 running` — never 2.

**(c) The resolver display in our logs is an accident, not a channel.** The 229
`[ebuild …]` lines in `build-pki.x86.log` were printed by
`depgraph._show_merge_list()` because a **slot conflict** was hit
(`/usr/lib/python3.12/site-packages/_emerge/depgraph.py:1546`). A build that
resolves cleanly emits none. Any feature that depends on the resolver emission
must **cause** that emission, not scrape for it.

---

## 1. Every USE-flag display state portage can produce

All of this is `_create_use_string()` in
`/usr/lib/python3.12/site-packages/_emerge/resolver/output_helpers.py:262-338`,
driven by `Display._display_use()` in `.../resolver/output.py:184-260`.

The table below was **not written from memory**. It was produced by calling
portage's own `_create_use_string` with one flag named `f` and every reachable
combination of `(cur_iuse, cur_use, old_iuse, old_use, is_new, iuse_forced)`,
once with `portage.output.havecolor = 1` and once with `0`. The generator and
its output are committed:

* `studio/tests/fixtures/package-flags/regenerate-flag-states.py`
* `studio/tests/fixtures/package-flags/portage-use-flag-states.json`

### 1.1 The states

`--verbose` (verbosity 3) column shows what portage prints; the *default*
(verbosity 2) column shows what it prints on an ordinary merge — which is what
our builders actually run.

| # | State | Meaning | Text (`--verbose`) | ANSI | Text (default verbosity) | Survives capture? |
|---|---|---|---|---|---|---|
| 1 | enabled, unchanged | on now, on last time (or the package is new) | `f` | `\x1b[31;01m` **red** | *(suppressed for reinstalls; shown for new pkgs)* | ✅ unambiguous |
| 2 | disabled, unchanged | off now, off last time (or the package is new) | `-f` | `\x1b[34;01m` **blue** | *(suppressed for reinstalls; shown for new pkgs)* | ✅ unambiguous |
| 3 | turning **on** | off at last merge, on now | `f*` | `\x1b[32;01m` **green** | `f*` | ✅ unambiguous |
| 4 | turning **off** | on at last merge, off now | `-f*` | `\x1b[32;01m` **green** | `-f*` | ✅ unambiguous |
| 5 | new in IUSE, enabled | flag did not exist in the installed version's IUSE; on now | `f%*` | `\x1b[33;01m` **yellow** | `f%*` | ✅ unambiguous |
| 6 | new in IUSE, disabled | flag did not exist in the installed version's IUSE; off now | `-f%` | `\x1b[33;01m` **yellow** | `-f%` | ✅ unambiguous |
| 7 | **removed** from IUSE (was off) | flag existed last merge, gone from the new version's IUSE | `(-f%)` | yellow inside literal parens | *(suppressed)* | ✅ unambiguous |
| 8 | **removed** from IUSE (was on) | as above, and it had been enabled | `(-f%*)` | yellow inside literal parens | *(suppressed)* | ✅ unambiguous |
| 9 | forced by profile, enabled | in `use.force`; portage forced it on | `(f)` | red inside parens | `(f)` for new pkgs | ✅ |
| 10 | masked by profile, disabled | in `use.mask`; portage forced it off | `(-f)` | blue inside parens | `(-f)` for new pkgs | ⚠️ **collides — see §1.3** |
| 11 | forced/masked **and** new in IUSE, disabled | in `use.force`/`use.mask` *and* absent from the old IUSE | `(-f)` | **yellow** inside parens | `(-f)` | ⚠️ **collides — see §1.3** |
| 12 | forced **and** new in IUSE, **enabled** | in `use.force` *and* absent from the old IUSE; on now | `(f%*)` | **yellow** inside parens | `(f%*)` | ✅ unambiguous |
| 13 | forced by profile, turning **on** | in `use.force`, off at the last merge | `(f*)` | green inside parens | `(f*)` | ✅ unambiguous |
| 14 | masked by profile, turning **off** | in `use.mask`, on at the last merge | `(-f*)` | green inside parens | `(-f*)` | ✅ unambiguous |

`iuse_forced` is `pkg.use.force ∪ pkg.use.mask` (`output.py:193-195`) — one set,
so **portage itself cannot distinguish "forced on" from "masked off" in the
parentheses**; the sign inside them is the only hint (`(f)` was forced on,
`(-f)` was masked off).

### 1.1a The parens are two different mechanisms, and the sign separates them

States 12-14 are the ones a naive reading of the table misses, and getting them
wrong inverts a badge's meaning. `_create_use_string` produces parentheses on
**two unrelated paths**:

* **the removed-from-IUSE branch** (`output_helpers.py:302-309`) builds its own
  parens and then `continue`s, so it never reaches the forced wrap. It always
  emits a `-` inside them: the only shapes it can ever produce are `(-f%)` and
  `(-f%*)`.
* **the `iuse_forced` wrap** (`:324-325`, `if flag in iuse_forced: flag_str =
  "(" + flag_str + ")"`) closes around whatever the enabled/disabled branch
  already built — **suffixes included**. So `yellow(flag) + "%*"` (`:295-296`,
  newly in IUSE and on) becomes `(f%*)`, and `green(flag) + "*"` / `green("-" +
  flag) + "*"` (`:297` / `:318`) become `(f*)` / `(-f*)`.

> **Therefore: inside parentheses, `%` means "removed" only when the token also
> carries `-`. `(f%*)` is the exact opposite of a removal — the flag is newly
> present in IUSE, enabled, and profile-forced.** A classifier that keys
> "removed" off the parens plus `%` alone will render a new forced flag as
> deleted, struck through, with the 🔒 modifier lost.

Driving `_create_use_string` over the full 64-combination input space
(`(cur_iuse, cur_use, old_iuse, old_use, is_new, iuse_forced)`, at both
`all_flags` settings) yields **13 distinct plain renderings** from these 14
states — 14 minus the one two-way collision of §1.3. States 12-14 appear at
**default verbosity** as well as under `-pv`, so our builders' ordinary emission
reaches them.

Symbol legend, confirmed against `man 1 emerge`, `--verbose` (rendered from
`/usr/share/man/man1/emerge.1.bz2`):

> ```
> Symbol    Location   Meaning
> -         prefix     not enabled (either disabled or removed)
> *         suffix     transition to or from the enabled state
> %         suffix     newly added or removed
> ()        circumfix  forced, masked, or removed
> ```

### 1.2 Ordering and grouping

`_create_use_string` emits `enabled + disabled + removed` in that order, each
group sorted by `_alnum_sort_key` (`output_helpers.py:249-259` — a natural sort
that makes `python3_9` precede `python3_12`). With `--alphabetical` all three
collapse into one alphabetical run. **A GUI that re-sorts loses information**:
position alone tells the operator "everything past here is off".

### 1.3 What is lost when the log is captured to a file

`portage.output.colorize()` returns the string **unmodified** when
`havecolor == 0` (`portage/output.py:394-399`), and emerge sets
`havecolor = 0` whenever stdout is not a tty:

```python
# _emerge/actions.py:2809-2814
if "--color" in myopts:
    ...
elif settings.get("TERM") == "dumb" or not sys.stdout.isatty():
    portage.output.havecolor = 0
```

Our builders pipe emerge through `_emerge_notice_sink` and then to a file, so
**colour is absent from every log we have** — verified: the fixture
`emerge-resolver-lines.x86-pki.txt` contains zero escape sequences.

The good news: the `-` prefix, the `*` and `%` suffixes and the parentheses are
plain ASCII and **all survive**. Of the 14 states, **12 are still uniquely
recoverable from captured text** (13 distinct renderings, one of which carries
two states). The exception is a single genuine two-way collision:

> **states 10 and 11 both render as `(-f)` in plain text.** Blue `(-f)`
> ("masked, unchanged") and yellow `(-f)` ("masked, and newly appeared in
> IUSE") are only distinguishable by colour. `_create_use_string:318-321`
> deliberately suppresses the `%` marker for forced flags
> (`if flag not in iuse_forced: flag_str += "%"`), which is exactly what
> destroys the distinction.
>
> **The collision is exactly this one shape — a *bare* `(-f)`.** That `%`
> suppression sits on the branch that emits nothing else (`:317-321`), so it can
> never reach a token that carries `*`: `(-f*)` and `(f*)` come from the green
> transition branches, which require the flag to have been in the *old* IUSE and
> therefore cannot also be new. `(f)` likewise has one producer only (`red(flag)`
> at `:293`). Flagging any of those as ambiguous would be inventing doubt that
> portage's own source rules out.

**Consequence for the badge design:** either the emission runs with `--color=y`
(which forces `havecolor = 1` regardless of tty — `actions.py:2810-2811`) and we
parse the ANSI, or the `(-f)` badge must honestly render as "forced/masked by
profile" without claiming to know whether it is also new. **Recommendation: emit
with `--color=y`.** It costs nothing, it is the only way to get states 10 vs 11
apart, and the escape codes are a stable four-value alphabet (`31;01`, `32;01`,
`33;01`, `34;01`) that `strip_ansi()` already knows how to remove for the
plain-text path.

---

## 2. The exact shape of an `emerge -pv` line

**A real sample exists** and is committed at
`studio/tests/fixtures/package-flags/emerge-resolver-lines.x86-pki.txt` — 229
lines lifted verbatim from `out/sessions/20260729-233913-719d4e/build-pki.x86.log`
lines 105079-105307. Nothing in this section is from documentation alone.

### 2.1 Anatomy

```
[ebuild  N     ] dev-libs/libnl-3.12.0  USE="debug -python -test -utils -verify-sig" ABI_X86="(64) -32 (-x32)" PYTHON_TARGETS="python3_12 -python3_13 -python3_14"
└──┬──┘ └──┬──┘  └──────────┬──────────┘  └──────────────┬─────────────┘ └────────┬────────┘ └──────────────────┬───────────────────┘
 type   attrs         cpv (+:slot ::repo at -v)      plain USE           one USE_EXPAND group    another USE_EXPAND group
```

* **type** — `ebuild`, `binary`, `nomerge`, `blocks`, or a left-justified
  13-char operation for uninstalls (`output.py:_set_no_columns`).
* **attrs** — exactly 7 characters, `PkgAttrDisplay.__str__`
  (`output_helpers.py:603-649`), positional:

  | pos | char | colour | meaning |
  |---|---|---|---|
  | 1 | `I` | WARN | interactive package |
  | 2 | `N` / `r` | green / red | New / forced-reinstall |
  | 3 | `S` / `R` | green / yellow | new Slot / Replacing same version |
  | 4 | `f` / `F` / `g` | green / red / fuchsia | fetch-restricted-satisfied / fetch-restricted / remote binary |
  | 5 | `U` | turquoise | new Version (upgrade) |
  | 6 | `D` | blue | Downgrade |
  | 7 | `#` / `*` / `~` | BAD / BAD / WARN | package.mask / missing keyword / unstable keyword |

  Position 7 only exists when `verbosity > 1` (`output.py:124-125`), i.e. it is
  present by default and vanishes under `--quiet`. Real shapes present in the
  fixture: `[ebuild  N     ]` ×198, `[ebuild   R    ]` ×16, `[ebuild  N    ~]`
  ×11, `[ebuild  rR    ]`, `[ebuild  r  UD ]`, `[ebuild  NS    ]`,
  `[ebuild     UD ]`.

* **USE_EXPAND groups are rendered as their own `KEY="…"` blocks**, after plain
  `USE`, in `sorted(pkg.use.expand)` order with `"USE"` forced first
  (`output.py:244-245`). Each group's flags have the **group prefix stripped**:
  `python_targets_python3_12` is printed as `python3_12` inside
  `PYTHON_TARGETS="…"` (`map_to_use_expand`, `output.py:166-174`). Groups listed
  in `USE_EXPAND_HIDDEN` are skipped entirely unless they are the sole reason for
  a reinstall (`output.py:217-237`).

Real USE_EXPAND lines from the fixture, showing every decoration in the wild:

```
[ebuild  N     ] dev-libs/lzo-2.10  USE="-examples (-split-usr) -static-libs" ABI_X86="(64) -32 (-x32)"
[ebuild  N     ] sys-libs/talloc-2.4.4  USE="python -compat -test -valgrind" ABI_X86="(64) -32 (-x32)" PYTHON_SINGLE_TARGET="python3_12 -python3_13 -python3_14"
[ebuild   R    ] dev-python/typing-extensions-4.15.0  PYTHON_TARGETS="python3_12* -python3_13* -python3_14*"
[ebuild  N     ] dev-python/pyproject-metadata-0.11.0  USE="-test -verify-provenance" PYTHON_TARGETS="python3_12 -python3_13 -python3_14 (-python3_14t) (-python3_15) (-python3_15t)"
[ebuild  N    ~] dev-lang/go-1.26.4  CPU_FLAGS_X86="sse2"
[ebuild  N     ] dev-lang/go-bootstrap-1.24.6  USE="(-big-endian)"
```

Note `[ebuild   R    ]` rows carry **only `*`-marked flags**. That is not a
capture artefact — see §2.3.

### 2.2 KEYWORDS and LICENSE are **not** in the resolver line

`grep -in "license" .../resolver/output.py` matches exactly **one** line — the
file's own GPL copyright header at line 2. `grep -in "keyword"` matches three,
all inside `gen_mask_str`'s `pkg.get_keyword_mask()` call (lines 137-141). There
is no KEYWORDS column and no LICENSE column in `emerge -pv`, at any verbosity,
with any option. What exists instead:

* **keywords** collapse to the single mask character at attrs position 7
  (`~` = accepted-unstable, `*` = missing keyword, `#` = package.mask,
  `gen_mask_str`, `output.py:127-146`) — a *verdict*, not the keyword list. Per
  `man emerge`, `~` is suppressed when the keyword was accepted globally via
  `ACCEPT_KEYWORDS`.
* **licences** appear only in the separate "license(s) that you'll have to
  accept" block emitted when `ACCEPT_LICENSE` does not already cover them, and
  in `--autounmask` proposals. Never per-row.

**So columns 3 and 4 cannot come from the resolver at all.** They come from the
VDB — §3.

### 2.3 Verbosity changes what you get

`_DisplayConfig` (`output_helpers.py:196-199`):

```python
self.all_flags       = self.verbosity == 3 or self.quiet
self.print_use_string = self.verbosity != 1 or "--verbose" in frozen_config.myopts
```

| run | `verbosity` | `all_flags` | what a **new** package shows | what a **reinstall** shows |
|---|---|---|---|---|
| `emerge …` (our builders) | 2 | **False** | every flag (`is_new` short-circuits the `all_flags` test) | **only flags that changed** |
| `emerge -pv …` | 3 | True | every flag | every flag |
| `emerge -q …` | 1 | True | every flag | every flag |

This is verified twice over: by driving `_create_use_string` at both settings
(fixture rows tagged `default (all_flags=False)` render `''` for the four
unchanged/removed states), **and** by the real log — its 16 `[ebuild R ]` rows
list only `*`-suffixed flags while its 198 `[ebuild N ]` rows list everything.

> **The emission this feature needs is `--pretend --verbose` (`-pv`), or a real
> merge with `--verbose`. A default-verbosity run cannot fill the columns for
> any already-installed package.** For a *fresh* sysroot every package is `N`,
> so a fresh build's rows are complete even at verbosity 2 — but incremental
> rebuilds, which is when flag churn actually matters, are not.

**Corollary the operator will notice:** on a fresh image build, states 3-8 (the
green and yellow ones) **never occur**, because `is_new` is true for every
package and short-circuits every transition branch. Green/yellow badges will
only ever light up on a warm sysroot. The live log confirms it: **zero `%`
characters** across all 229 rows.

---

## 3. Where each of the four columns really comes from

The decisive discovery: **`<sysroot>/var/db/pkg/<cat>/<pf>/` — portage's VDB —
is part of the captured build output**, and it carries `KEYWORDS`, `LICENSE`,
`IUSE`, `USE`, `IUSE_EFFECTIVE`, `DESCRIPTION`, `SLOT`, `EAPI`, `FEATURES`,
`repository` as one-line plain-text files, per merged package. Verified on
`out/sessions/20260729-233913-719d4e/wl-pki.x86/sysroot`: 319 packages, 2 484
such files, **215 850 bytes total**. Sample committed as
`studio/tests/fixtures/package-flags/vdb-package-metadata.sample.json`.

| column | authoritative source | fallback | unavailable when |
|---|---|---|---|
| **USE_EXPAND groups** (`PYTHON_TARGETS`, `ABI_X86`, `CPU_FLAGS_*`, `LLVM_SLOT`, …) | resolver `-pv` line — already split into `KEY="…"` blocks with per-flag state markers | split the VDB `IUSE`/`USE` sets yourself by prefix against the 52 group names in `/var/db/repos/gentoo/profiles/desc/*.desc`; or read the group variables verbatim out of `<pkg>/environment.bz2` (`declare -x ABI_X86="64"`, `declare -x PYTHON_TARGETS=""`) | never — VDB always suffices for enabled/disabled; only the `*`/`%`/parens markers need the resolver |
| **plain USE** | resolver `-pv` line (state markers included) | VDB `IUSE` minus the USE_EXPAND prefixes, intersected with VDB `USE` → enabled; the remainder → disabled. The elog header's `USE:` row (already parsed by `emerge_packages.parse_use_flags`) gives the same enabled set | provenance/transition markers are unavailable from any non-resolver source |
| **KEYWORDS** | VDB `<pkg>/KEYWORDS` — the ebuild's full keyword list, e.g. `~alpha amd64 arm arm64 ~hppa … x86` | `environment.bz2`'s `declare -x KEYWORDS=` (identical string) | **not in the resolver line at all**; not in the elog header. Present for 319/319 packages in the measured sysroot |
| **LICENSE** | VDB `<pkg>/LICENSE` — **USE-conditionals already resolved**: `\|\| ( GPL-2+ LGPL-3+ ) GPL-3+` where the ebuild says `\|\| ( GPL-2+ LGPL-3+ ) utils? ( GPL-3+ )` | `environment.bz2`'s `declare -x LICENSE=` keeps the **raw** conditional form — use it when you want to show *why* a licence applies | **68 of 319** packages (22 `acct-group`, 6 `acct-user`, 40 `virtual`) have **no LICENSE file at all**. This is the strongest argument for the operator's "only show a column when it has content" |

### 3.1 What each channel does *not* have

* **elog header** (`<sysroot>/var/log/portage/build/<cat>:<pf>:<stamp>.log`,
  already parsed by `studio/hugmesh_studio/core/emerge_packages.py:314`) —
  carries only `Package / Repository / Maintainer / USE / FEATURES`. Verified
  byte-for-byte on
  `wl-pki.x86/sysroot/var/log/portage/build/app-admin:perl-cleaner-2.31-r2:20260730-064846.log`:

  ```
   * Package:    app-admin/perl-cleaner-2.31-r2:0
   * Repository: gentoo
   * Maintainer: perl@gentoo.org
   * USE:        abi_x86_64 amd64 elibc_glibc kernel_linux
   * FEATURES:   nostrip preserve-libs
  ```

  Its `USE` row is a **flat, enabled-only list that mixes expanded flags into
  plain ones** (`abi_x86_64`, `elibc_glibc`, `kernel_linux` sit beside real USE
  flags). No `-flag` entries, no markers, no KEYWORDS, no LICENSE. It answers
  "what was merged", never "what changed" or "what was possible".

* **`/etc/portage/package.env`** — the operator called the first column "flags
  that would go in `/etc/portage/packages.env`". That is a **different file with
  a different job**: it maps package atoms to environment *files*, e.g. the
  build's own

  ```
  llvm-core/llvm   llvm-lowmem.conf
  llvm-core/clang  llvm-lowmem.conf
  dev-qt/qtwebengine  qtwebengine-lowmem.conf
  ```

  (`wl-pki.x86/sysroot/etc/portage/package.env`). `PYTHON_TARGETS`, `ABI_X86`
  and friends are **USE_EXPAND** variables and are set in `package.use` /
  `make.conf`, not `package.env`. The column the operator wants is real and
  worth building — it is just named after the wrong file. Column name should be
  **USE_EXPAND**, not "package.env".

* **`/etc/portage/package.accept_keywords/`** and **`package.license`** — these
  are *policy the build writes*, not per-package fact. The measured build has 4
  `package.accept_keywords` files and an **empty** `package.license`. They tell
  you what the build is willing to accept, never what a given package's KEYWORDS
  or LICENSE are. Useful as a cross-reference ("this `~amd64` was accepted
  deliberately, here is the comment explaining why"), not as a column source.

### 3.2 Simply unavailable

* **Why a flag is enabled** — profile default vs `make.conf` vs `package.use`
  vs a dependency's `[flag]` requirement vs autounmask. Portage does not record
  it and does not print it. `emerge --info <atom>` and
  `equery uses` cannot recover it either.
* **Which package pulled a flag on** — only visible in slot-conflict text
  (`… required by (dev-python/sphinx-9.1.0 …)`), and only for conflicting
  packages.
* **Change markers on a fresh build** — see §2.3.

---

## 4. Offline documentation for the hover text

**Hard requirement: the Studio must never touch the network.** Every source
below is already on disk.

### 4.1 Where the sources live

| source | path | size | covers |
|---|---|---|---|
| global USE flag descriptions | `/var/db/repos/gentoo/profiles/use.desc` | 26 022 B, **401 entries** | flags meaningful tree-wide (`ssl`, `nls`, `debug`, …) |
| local USE flag descriptions | `/var/db/repos/gentoo/profiles/use.local.desc` | 766 570 B, **9 255 entries**, keyed `cat/pkg:flag` | per-package flags |
| per-package metadata | `/var/db/repos/gentoo/<cat>/<pkg>/metadata.xml` → `<use><flag name="…">…</flag></use>` | 19 397 files, 2 914 of which carry a `<use>` block | the same per-package flags — this is the **generator** of `use.local.desc` |
| USE_EXPAND descriptions | `/var/db/repos/gentoo/profiles/desc/<group>.desc` | 93 262 B across **52 files**, **1 383 entries** | `PYTHON_TARGETS`, `ABI_X86`, `CPU_FLAGS_X86`, `LLVM_SLOT`, `L10N`, … |

The 52 filenames in `profiles/desc/` are also the **authoritative offline list of
USE_EXPAND group names** — no portage import, no `emerge --info`, just
`os.listdir`.

### 4.2 The catch: the repo is NOT in the build output

`<sysroot>/var/db/repos/gentoo` exists in every captured sysroot but is
**empty** — it is a bind mount of the host tree, established at
`build-x86-host-stage4.sh:4245`:

```sh
mount --bind /var/db/repos/gentoo "${SYSROOT}/var/db/repos/gentoo"
```

and lazily unmounted at `:4314`. Confirmed: `ls -A` on
`wl-pki.x86/sysroot/var/db/repos/gentoo` returns **0 entries**.

So the descriptions are reachable **during** a build (host tree) and on any
Gentoo host running the Studio, but **not** from an archived build directory on
a non-Gentoo machine. Two honest options:

1. **Read the host tree at display time** — zero build changes, works whenever
   the Studio runs on the build host. Fails for archived/copied sessions.
2. **Capture a sidecar at build time** — measured below, and cheap enough that
   it should simply be done.

### 4.2a The group NAMES are not descriptions, and must not go missing with them

A missing description degrades gracefully: the hover simply says so. A missing
**group list** does not. `profiles/desc/` serves two unrelated purposes, and only
the first is per-package data:

* its file *contents* are the USE_EXPAND flag descriptions (hover text), and
* its 52 *filenames* are the only offline way to know that
  `python_targets_python3_13` belongs to `PYTHON_TARGETS` at all.

Lose the filenames and the VDB path cannot split anything: every USE_EXPAND flag
folds back into plain `USE` under its full prefixed name — the flat
prefix-mixing shape §3.1 records as the elog header's defect — and the
USE_EXPAND column is never revealed. That is the exact reader the sidecar exists
to serve, silently regressing to the shape the column was built to fix. The §4.4
sidecar cannot rescue it either: it maps flags to descriptions and carries no
group-name list.

So the group list has **three** sources, in order: the live tree
(authoritative), the `@GROUP:flag` keys of a session sidecar (unioned in — they
can only name groups a real build saw), and finally a **built-in snapshot of the
52 names**, which is a small, slow-moving, tree-wide constant rather than
per-package fact. The snapshot must never be silent: when it is what answered,
the hover text says so, and says what it could cost (a group added to the tree
since the snapshot stays folded into plain USE).

### 4.3 Coverage — measured, not assumed

Union of every `IUSE` entry across the real x86 pki sysroot's 319 merged
packages, resolved against the sources above:

```
iuse_flag_slots            1975
  USE_EXPAND flags          910   documented:  910  (100%, profiles/desc/*.desc)
  plain USE flags          1065   documented: 1065  (100%)
      from metadata.xml     347
      from use.desc         718
undocumented                  0
```

**Coverage is 100%.** Not one flag in a real fleet build lacks an offline
description. USE_EXPAND groups actually seen: `ABI_MIPS ABI_S390 ABI_X86
CPU_FLAGS_ARM CPU_FLAGS_PPC CPU_FLAGS_X86 CURL_SSL GUILE_SINGLE_TARGET L10N
LLVM_SLOT PERL_FEATURES PYTHON_SINGLE_TARGET PYTHON_TARGETS`.

`metadata.xml` and `use.local.desc` **agree exactly** — 347 of 347 local flags
present in both, zero in only one. Same for the other two roles measured
(be.x86: 336/336; pki.rpi5: 520/520). Either source is sufficient; prefer
`use.local.desc` (one file, one parse) unless you also want the richer
`<pkg>`/`<flag>` markup that only `metadata.xml` has.

### 4.4 Sidecar size, if we capture

A JSON map `{"cat/pkg:flag" | "*:flag" | "@GROUP:flag" → description}` covering
everything a role build touches:

| role | entries | JSON | gzip |
|---|---|---|---|
| `wl-pki.x86` | 515 | 50 027 B | **16 792 B** |
| `wl-be.x86` | 504 | 49 226 B | 16 565 B |
| `wl-pki.rpi5` | 717 | 67 232 B | 21 919 B |

**~17-22 KB gzipped per role.** Against a 730 MB build log this is free. Capture
it and the hover text works forever, on any machine, offline, for archived
sessions — which is the whole point.

### 4.5 Links may be constructed, never fetched

`https://packages.gentoo.org/packages/<cat>/<pkg>` and
`https://wiki.gentoo.org/wiki/<Topic>` are fine to **build and display** so the
operator can open them. The Studio must not request them: hover-time fetches
leak what the operator is building to a third party, break air-gapped use, and
block the UI thread.

---

## 5. Proposed badge design

Fourteen states is too many badges. They collapse to **six** distinct meanings
plus one modifier, which is what the operator actually needs to see.

**Palette constraint from this codebase, not from taste.** The Studio does not
own its background — `studio/hugmesh_studio/gui/styles.py:1-14` records that the
GUI runs on the *system* palette and that every semantic colour must therefore
be "the cross-theme compromise that stays legible on BOTH a light and a dark
background". It already exports `MUTED = "#8a8a8a"`, `WARN = "#c2410c"`,
`ERROR = "#c5221f"`. Badge colours below follow the same rule: one mid-tone
value each, no light/dark pair, and the two existing constants reused where the
meaning matches. Portage's raw bright-ANSI values (`#FF5555`, `#55FF55`,
`#FFFF55`, `#5555FF`) are *not* usable — they fail contrast on white.

Emoji are chosen to be distinguishable at 12 px, unambiguous in monochrome, and
— deliberately — to differ in **shape**, not just hue, so the badge survives
deuteranopia/protanopia/tritanopia, greyscale printing, and the operator's
system theme being either polarity.

| # | State | portage text | Emoji | Colour | Rationale |
|---|---|---|---|---|---|
| 1 | **enabled, unchanged** | `f` | 🟢 | `#0e7a63` teal | Portage's own colour here is *red*, which every operator reads as "bad". Rendering "this flag is on and always was" in red would be actively misleading in a GUI whose `ERROR` is already `#c5221f`. Teal + filled circle = steady state, on. **This is the one deliberate deviation from portage's palette, and the tooltip must say so: "portage prints this in red".** |
| 2 | **disabled, unchanged** | `-f` | ⚪ | `styles.MUTED` `#8a8a8a` | Portage uses blue; blue reads as a hyperlink in a Qt widget. Reusing the existing MUTED constant pushes the ~60% of flags that are simply off into the background where they belong, and costs no new colour. |
| 3 | **turning on** | `f*` | 🔼 | `#1a7f37` green | Portage's green, darkened to clear 4.5:1 on white. Upward triangle = gaining. This is the state the operator called "newuse". |
| 4 | **turning off** | `-f*` | 🔽 | `#1a7f37` green | Same green — portage does **not** distinguish direction by colour, and inventing a second colour would misrepresent it. The triangle carries the direction, so colour-blind readers still get it. |
| 5 | **new in IUSE** | `f%*` / `-f%` / `(f%*)` | ✨ | `styles.WARN` `#c2410c` | Portage's yellow is unusable at 12 px on white; WARN is the existing "needs attention, not broken" constant and matches the meaning exactly. Sparkle = "this flag did not exist before" — a tree change, not an operator decision. Compose with 3/4's triangle when both apply (`f%*` is new **and** turning on). |
| 6 | **removed from IUSE** | `(-f%)` / `(-f%*)` | 🗑️ | `styles.WARN` `#c2410c`, struck through | Portage renders it yellow-in-parens at the very end of the row. Strike-through + bin says "gone" without depending on the parens the GUI is otherwise consuming. |
| M | **forced / masked by profile** (modifier on any of the above) | `(…)` | 🔒 | badge outlined, not filled — no new colour | Parentheses are the only provenance portage gives. A padlock plus an outlined (rather than filled) badge says "you did not choose this, and you cannot change it here". `(f)` = forced on, `(-f)` = masked off — the sign inside is the only discriminator, so the tooltip must state which. It is a **modifier only**: the wrapped token keeps whatever its own `%`/`*` suffix meant, so `(f%*)` is badge 5 + 🔒 and `(-f*)` is badge 4 + 🔒 (§1.1a). |

Additional rules:

* **The tooltip always states the portage text verbatim** (`-python3_13*`) plus
  the plain-English meaning plus the flag description from §4. An operator who
  knows portage should be able to check our reading against theirs in one hover.
* **Every badge is also a text token.** Copy-paste of a row must yield
  `USE="debug -python -test"` exactly as portage printed it.
* **Do not re-sort.** Preserve `enabled → disabled → removed` (§1.2).
* **The `(-f)` ambiguity (§1.3) must be visible, not papered over.** If the
  emission was captured without colour, the padlock badge says "forced/masked"
  and the tooltip adds "cannot tell from this log whether this flag is also new
  — the log has no colour". Emitting with `--color=y` removes the caveat.
  **Equally: it must not be claimed anywhere else.** The caveat belongs to the
  bare `(-f)` and to nothing else (§1.3); asserting "the log was captured without
  colour" on a token that arrived *with* colour, or on a shape portage's source
  proves unambiguous, is a false statement about the operator's own data.
* **Empty column ⇒ no column.** 68/319 packages have no LICENSE; most have no
  USE_EXPAND flags. The operator asked for this explicitly and the data backs
  it.

---

## 6. Addendum: the x86 vs Pi parallelism premise

Included because the conclusion is load-bearing for a sibling lane and the
usual evidence for it is wrong.

**The `>>> Jobs:` line is not a parallelism indicator.** It is printed by
`JobStatusDisplay`, which is active only in *background mode*
(`_emerge/Scheduler.py:441-503`):

```python
parallel_jobs = self._max_jobs is True or self._max_jobs > 1
quiet = "--quiet" in self.myopts or self.myopts.get("--quiet-build") == "y"
background = (parallel_jobs or quiet) and not bool(
    self._opts_no_background.intersection(self.myopts))
```

Either branch turns it on. The fleet's asymmetry is entirely the `quiet` branch:

| | jobs flag | quiet flag | background? | `>>> Jobs:` in the live log |
|---|---|---|---|---|
| **rpi5** (runs in the build container) | `--jobs=1` on the `cross_emerge` command line (`build-rpi5-stage4.sh:3754`) | `--quiet-build=y` inherited from `Dockerfile.build:59` `EMERGE_DEFAULT_OPTS` | **yes** (via `quiet`) | 1 739 lines |
| **x86** (runs on the host) | `EMERGE_JOBS=1` → `--jobs 1` (`build-x86-host-stage4.sh:4460, 4497`) | none | **no** | 0 lines |

The container ENV sets `--jobs=4`, but the explicit `--jobs=1` on the
`cross_emerge` command line wins (emerge prepends `EMERGE_DEFAULT_OPTS` to
argv). Proof from the log itself — `build-pki.rpi5.log`'s 1 739 scheduler lines
break down as 896 bare `N of M complete`, 281 `…, 1 merge wait`, and 562
`…, 1 running`. **The running count is `1` in every line that has one; the
string `2 running` never appears.**

**So both builders are serial, on purpose.** The reason is recorded in the code
and must not be discarded:

> `build-x86-host-stage4.sh:4454-4459` — *"EMERGE_JOBS=1: SERIALIZE package
> builds. At 2 concurrent, the payload's 8 Go packages
> (kubelet/runc/cni-plugins/containerd/nerdctl/cri-tools/...) overlapped and
> their shared-runtime recompiles were OOM-KILLED (silent death, no compiler
> error — confirmed). … (Raise once known-good.)"*
>
> `build-rpi5-stage4.sh:3743-3746` — *"--jobs=1: SERIALIZE package builds — the
> payload's Go packages … were OOM-killed at high concurrency on x86; one
> cross-Go build at a time keeps RAM bounded (override with
> CROSS_EMERGE_JOBS)."*

Whoever raises x86 parallelism must therefore: keep `--load-average`; keep
`GOMAXPROCS`/`GOFLAGS -p` capped (Go ignores make's jobserver and `-l`, which is
the actual OOM mechanism); make the degree an env override exactly as rpi5
already does with `CROSS_EMERGE_JOBS`; and account for the 20 GB xfs scratch
budget cited at `:4450-4453`. A default of 2 is the *first* untested step, not a
safe one — the comment says 2 is precisely what was observed to fail.

A separate, cheaper win is available with **no** OOM risk: adding
`--quiet-build=y` to the x86 host emerge would give the Studio the same
scheduler telemetry the Pi already produces, without changing concurrency at
all. That is a decision for the progress lane, not this one.

---

## 7. Open unknowns

1. **No `%` state has ever been observed in a real fleet log.** States 5-8 are
   proven from portage's source and reproduced through portage's own formatter,
   but never captured from a fleet build (all our builds are fresh sysroots).
   They need one warm-sysroot rebuild to be confirmed end-to-end.
2. **No coloured capture exists.** Every conclusion about ANSI codes comes from
   `portage/output.py` and from driving `colorize()` directly. A real
   `--color=y` emission has never been captured by the fleet.
3. **`emerge -pv` has never been run by a builder.** The 229-line sample is a
   slot-conflict by-product at default verbosity. The verbosity-3 shape
   (per-row size, `:slot`, `::repo`, `[oldversion]`) is documented from
   `output.py` and the man page but **not** proven against a fleet emission.
4. **ARM cross builders were not measured.** frite / jetson / orangepi\* pass
   `--jobs="${JOBS}"` (per `emerge_packages.py`'s own module docstring) and were
   out of scope here; their resolver/telemetry shape is unverified.
5. **`USE_EXPAND_HIDDEN` handling is untested.** `output.py:217-237` un-hides a
   hidden group when it is the sole reinstall trigger. No sample exists.
6. **Non-`gentoo` repositories.** `guru` and `sage-on-gentoo` are enabled on this
   host; flags from an overlay resolve against that overlay's own
   `profiles/use.local.desc` and `metadata.xml`, which the coverage measurement
   did not exercise (the fleet builds pull only from `gentoo`).

## 8. Rendering: wrapping and the Configure-view dialog

Both from operator live-QA on 2026-08-06, watching a real x86 build.

### 8.1 Badges wrap; the row grows to fit them

`FlagBadgeDelegate.layout_badges()` used to place every badge on ONE line, so a
package with a wide flag set had its tail clipped at the column edge with no way
to reach it. Badges now flow onto as many lines as they need and `sizeHint()`
reserves the height they actually occupy — *"they should be allowed to expand the
row height to fit all of them"*.

The wrap is deliberately implemented **inside `layout_badges` alone**, because
that one function is the shared geometry behind `paint()`, the `helpEvent` hover
probe and `sizeHint()`. Wrapping in the painter only would have left tooltips
hit-testing the pre-wrap positions — badges would be painted on line 3 and probed
on line 1. All three now pass the same `wrap_width` (the column width), so a badge
is painted where its size was reserved and where the probe looks for it.

Two edge cases are gated by executed tests: a column narrower than a single badge
must still lay every badge out (the "wrap before placing" rule would otherwise
never place anything and loop), and a resize must re-lay the rows (heights are
width-dependent, so `sectionResized` schedules a relayout).

### 8.2 Configure view

A `Configure view` button above the tree opens a dialog with one checkbox per
hideable column. `_COL_NAME` is deliberately not offered: hiding the identity
column leaves rows that cannot be told apart, which is a broken view rather than a
view preference.

The four badge columns are *auto-revealing* (§5, "empty column ⇒ no column"), so
the dialog has to beat that in **both** directions or it looks broken:

* an operator-hidden column must STAY hidden when a package finally supplies that
  flag — otherwise the first such package silently undoes their choice mid-build;
* an operator-shown column must appear IMMEDIATELY, before any content exists —
  otherwise ticking it appears to do nothing.

So overrides are stored per column (`True`/`False`/absent = auto) and consulted by
`_sync()`, which both `reset()` and `apply()` route through. Overrides survive
`reset()` on purpose — a view preference is not run state, and revoking it at the
start of the next build would read as the dialog forgetting the setting.
"Reset to automatic" hands columns back to reveal-on-content.

### 8.3 Confirmed: a normal build emits NO resolver rows (Open unknown #3)

Measured on the operator's live session `20260806-123849-95898e`
(`build-pki.x86.log`, 32 675 lines and still growing at the time):
**zero `[ebuild …]` / `[binary …]` rows in BOTH the `system` and `world` emerge
groups.** This is the empirical confirmation of §7 unknown #3 — the committed
229-row fixture is a *slot-conflict by-product*, not what a clean build prints.

The operator's report was that flags showed "on keywords pretty" but not on the
flags column. That is exactly this: KEYWORDS/LICENSE come from the **VDB** (§3),
which is on disk for every merged package and therefore always paints, while
USE/USE_EXPAND need a resolver row (§2) that a normal merge never emits.
`EMERGE_DEFAULT_OPTS` (x86 builder) carries `--jobs/--usepkg/--binpkg-respect-use`
and no verbosity.

**So the USE columns cannot be fixed in the GUI — the data is not in the log.**
The fix is the deferred badges-Emit phase, or reusing the plan-preview
`--pretend` emission which already carries portage's `USE="…"` column verbatim
per package (`docs/EMERGE-PLAN-PREVIEW.md`). Note that on x86 the plan currently
covers `world` + `image` but declares `system` *not planned*, so covering the
operator's "make sure they're in both" requires promoting that group too.
