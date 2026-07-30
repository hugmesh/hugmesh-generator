"""EmergePackageParser — Qt-free, per-PACKAGE emerge progress derived from portage's own output.

:mod:`.progress_parse` answers "how far through the BUILD are we" from the ``==> `` banner
table. This module answers the finer question the operator asked for: *which packages are
emerging right now, in which emerge group, with which USE flags, how far is each one, and
where is its log*. Same honesty contract as its sibling — nothing here is estimated from
wall-clock or invented; every field comes from a line portage actually printed, verified
against the real transcript of session ``20260725-140638-09692d``.

The evidence (all line numbers are in
``out/sessions/20260725-140638-09692d/build-standalone-unaffiliated.x86.log``,
3.16M lines / 353 MB, one real x86 standalone-unaffiliated build):

* ``>>> Emerging (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo``            (line 17744)
* ``>>> Emerging binary (436 of 805) sys-apps/groff-1.23.0-r2::gentoo``    (line 2526970)
* ``>>> Installing (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo``          (line 17792)
* ``>>> Completed (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo``           (line 17834)
* ``>>> Failed to emerge app-office/libreoffice-25.2.7.2-r1, Log file:``   (line 2794910)
* ``>>>  '/var/log/portage/build/app-office:libreoffice-...:20260726-024143.log'`` (2794912)

and the atom-less ebuild ladder, interleaved into the SAME stream (lines 322-16270 for
``sys-devel/gettext-0.22.5-r2``)::

    >>> Unpacking source...              >>> Source unpacked in <workdir>
    >>> Preparing source in <workdir>    >>> Source prepared.
    >>> Configuring source in <workdir>  >>> Source configured.
    >>> Compiling source in <workdir>    >>> Source compiled.
    >>> Test phase [not enabled]: sys-devel/gettext-0.22.5-r2
    >>> Install sys-devel/gettext-0.22.5-r2 into <image>
    >>> Completed installing sys-devel/gettext-0.22.5-r2 into <image>

ATTRIBUTION. Half of those ladder lines name their atom and half do not ("Unpacking
source..." carries nothing). Lines that DO name an atom are attributed to that atom
exactly, so they are safe under any emerge parallelism. Lines that do NOT are attributed
to the single in-flight package — and ONLY when exactly one package is in flight, which
the stream itself tells us (a package is in flight between its ``Emerging`` and its
``Completed``/``Failed``). x86 and rpi5 serialise package builds on purpose
(``EMERGE_JOBS=1``, build-x86-host-stage4.sh:4460, fed to portage via EMERGE_DEFAULT_OPTS
at :4497; ``--jobs="${CROSS_EMERGE_JOBS:-1}"``, build-rpi5-stage4.sh:3754) so the atom-less
lines are unambiguous there, but the SIX ARM cross builders all pass ``--jobs="${JOBS}"``
(see the PARALLEL EMERGE section below for the current call sites) — under those, several
packages ARE in flight and their atom-less lines interleave. Rather than mis-crediting them
this leg simply drops them; guessing would be the dishonest option. What recovers the lost
granularity is NOT a better guess but a different SOURCE: under parallelism each package's
own portage log carries the same ladder unambiguously, which is what
:meth:`EmergePackageParser.poll` reads. See PARALLEL EMERGE below.

USE FLAGS are NOT in the build stream. ``grep -c 'USE:'`` over the whole 3.16M-line
transcript returns ZERO — portage writes the elog header only to the per-package log
under ``<sysroot>/var/log/portage/build/<cat>:<pf>:<STAMP>.log``, ANSI-coloured::

    \x1b[32m * \x1b[39;49;00mUSE:        X abi_x86_64 adobe-cff amd64 bzip2 ... png

(verified byte-for-byte on ``media-libs:freetype-2.14.3:20260725-211000.log``). So
:func:`parse_use_flags` reads that file; there is no stream-only shortcut to fake.
:func:`parse_header` returns the WHOLE elog header block the same way (Package /
Repository / Maintainer / USE / FEATURES on the freetype log) — and its two format
surprises are both real, from ``sys-apps:groff-1.23.0-r2:20260726-015900.log``: a BINARY
merge's header does NOT start at line 0 (line 1 is ``>>> Extracting info``, the header
begins at line 2) and carries NO Maintainer row. So the reader hunts for the first
header-shaped line within a bounded window and takes the contiguous run from there,
rather than assuming byte 0 or a fixed key set.

BUILD-TOOL TELEMETRY. Between the ladder markers the stream is the underlying build
tool's own output, and the operator asked for the latest such line per package
(``tool_info``). Every recognised shape is real, cited from the same transcript:

* ninja/samu counters ``[1/197] /usr/bin/cp /var/tmp/portage/app-crypt/p11-kit-...``
  (line 60467; 74,998 ``^[N/M]`` lines in the whole build). These ALSO refine the
  percent within the compile step — see :meth:`EmergePackageParser.feed` step 8.
* make ``make -j4`` (line 2783) and ``make[1]: Entering directory '/var/tmp/portage/
  sys-devel/gettext-0.22.5-r2/...'`` (line 2785).
* cmake ``-- Configuring done (1.6s)`` / ``-- Generating done (0.0s)`` /
  ``-- Build files have been written to: ...`` (lines 69747-69749, dev-cpp/eigen).
* ./configure ``checking for a BSD-compatible install... /usr/lib/portage/...``
  (line 389, gettext) — collapsed to ``configure: checking ...`` so the GUI cell says
  which tool is talking.
* cargo ``   Compiling proc-macro2 v1.0.106`` (line 170469, 3-space indented).
* npm ``npm install`` / ``added N packages`` — the ONE shape with zero occurrences in
  this transcript (no node package in this image); implemented to the operator's list,
  flagged here as the only pattern without an in-repo proof line.

Anything else (plain compiler lines, linker noise) intentionally matches nothing:
unknown tools must degrade to "tool_info unchanged", never to a guess. And NO tool
output invents a percent — the ninja/samu N/M rule is the single sanctioned exception
because it is an honest completed/total counter, not a heuristic.

GROUP. The five emerge groups the operator asked to see separately (image / tools /
dependencies / system / world) are NOT discoverable from portage output — a builder runs
several distinct ``emerge`` invocations and portage restarts its ``(N of M)`` counter for
each (``(1 of 1)`` gettext at line 96, then ``(1 of 258)`` at 17744). The builders
therefore announce each one with a banner whose exact text is the cross-lane contract
pinned in :data:`GROUP_BANNER_PREFIX`. Before the first such banner the group is honestly
:data:`GROUP_UNKNOWN` (``""``) — NOT "image", which would silently file every pre-banner
package under the wrong heading.

PARALLEL EMERGE (``--jobs``)
----------------------------
The above was written against a SERIAL transcript. The six ARM cross builders run
``"${CROSS_TARGET}-emerge" --jobs="${JOBS}" --load-average="${JOBS}"``
(build-frite-stage4.sh:1435, build-jetson-stage4.sh:1440, build-orangepi5-stage4.sh:1462,
build-orangepi-zero2-stage4.sh:1531, build-orangepi-zero2w-stage4.sh:1542,
build-orangepi-zero3-stage4.sh:1545), and rpi5/x86 default to 1 but take an override
(``--jobs="${CROSS_EMERGE_JOBS:-1}"`` build-rpi5-stage4.sh:3754;
``EMERGE_DEFAULT_OPTS="--jobs ${EMERGE_JOBS} ..."`` build-x86-host-stage4.sh:4497). Under
``--jobs`` portage's own SCHEDULER talks, and it changes two things this module now handles.

1. It prints a status line the parser used to ignore entirely. The operator's real rpi5
   transcript (``out/sessions/20260729-065121-ce11e0/build-pki.rpi5.log``, 22025 lines)
   carries 1752 of them next to its 283 ``>>> Emerging`` lines, in exactly three clause
   shapes — 903 + 566 + 283 = 1752, counted over the whole file, not remembered::

       >>> Jobs: 27 of 149 complete                    Load avg: 5.65, 6.17, 5.94   (903x)
       >>> Jobs: 27 of 149 complete, 1 running         Load avg: 5.65, 6.17, 5.94   (566x)
       >>> Jobs: 26 of 149 complete, 1 merge wait      Load avg: 5.80, 6.21, 5.95   (283x)

   20 of those 903 clause-less lines are ``>>> Jobs: 0 of 0 complete`` — an emerge
   invocation that had nothing to do — so a zero TOTAL is a real, expected reading and
   must not be mistaken for "not started yet" (:attr:`SchedulerState.seen` is the
   has-portage-spoken flag; the total is reported verbatim).

   The gap between the clause list and ``Load avg:`` is a variable-width run of spaces
   (portage right-aligns the load field), and a clause LABEL may itself contain a space
   ("merge wait") — so :meth:`EmergePackageParser._feed_jobs` splits on the literal
   ``Load avg:`` and then walks the comma-separated clauses generically instead of
   pinning one regex per shape. Whatever labels portage prints land verbatim in
   :attr:`SchedulerState.clauses`; ``running`` and ``merge wait`` are the two attested
   here and get named attributes, and ``failed`` is read the same generic way (portage
   has such a counter but this transcript never exercised it, so it is honestly marked
   unattested rather than pattern-matched from memory).

2. Each concurrent package's build output is DIVERTED to that package's own portage log
   instead of the shared stdout, so the stream carries almost no attributable tool lines
   — which is why concurrent rows used to sit frozen at the ``emerge`` step. The fix is
   :meth:`EmergePackageParser.poll`: a separate, EXPLICIT, caller-driven pass that
   incrementally tails each in-flight package's own log (byte offset per atom, capped
   bytes per poll, tolerant of a log that does not exist yet or was replaced). It is NOT
   part of :meth:`feed`, which keeps its O(1)-per-line, filesystem-free contract. Inside
   a package's OWN log the atom-less ladder lines ("Compiling source in ...") are
   unambiguous, so the parallel leg can credit exactly what the serial leg drops — using
   the SAME :data:`STEP_PERCENT` ladder and the same tool table, so the two modes cannot
   drift. Verified against a real per-package log written by the operator's own build,
   ``wl-pki.x86/sysroot/var/log/portage/build/net-libs:nghttp2-1.68.0:20260730-043807.log``
   (613 lines), which carries the full ladder plus ``>>> Done.`` — and NOT the scheduler's
   ``>>> Completed (N of M)``. That asymmetry is load-bearing: ``>>> Done.`` is written
   before portage merges the package into the ROOT, so nothing on the poll path may
   settle a row. Only the stream's ``Completed (N of M)`` line reaches 100%.

ROOT-TARGETED MERGES. A cross build merges into a sysroot, and portage then appends the
destination to its counter lines::

    >>> Emerging (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo for /out/wl-pki.rpi5/sysroot/
    >>> Installing (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo to /out/wl-pki.rpi5/sysroot/
    >>> Completed (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo to /out/wl-pki.rpi5/sysroot/

222 of the rpi5 transcript's 283 ``Emerging`` lines carry that tail (the other 61 are
BDEPENDs merged into ``/``), and the original ``$``-anchored regexes matched NONE of them:
replaying the real log through the pre-change parser yields 60 packages out of the build's
266 distinct atoms — i.e. 206 of that build's packages never reached the GUI at all.
:data:`_ROOT_TAIL` fixes it, and the same defect was fixed independently on main as #483.

The 20260729-065121-ce11e0 transcript has since been deleted from the operator's ``out/``
(the session directory survives, the ``.log`` does not), so the replay that pins 266 now
SKIPS rather than lying. The figure was re-corroborated on the surviving cross build
``out/sessions/20260719-103006-a775c2/build-pki.rpi5.log`` (21919 lines, 279 ``Emerging``
lines of which 219 tailed, 263 distinct atoms by ``grep|awk``): the pre-change parser
tracks 60 rows there, this one tracks 263 — every one reaching 100%. Same shape, same
~60-row floor, independently measured.
"""
from __future__ import annotations

import glob
import os
import re
import time
from dataclasses import dataclass, field

from .progress_parse import strip_ansi

# ── the five emerge groups (operator's own taxonomy) ─────────────────────────────────
EMERGE_GROUPS: tuple[str, ...] = ("image", "tools", "dependencies", "system", "world")

# CROSS-LANE CONTRACT. The builders emit exactly ``==> Emerge group: <group>`` before each
# emerge invocation; this parser reads exactly that. Pinned as a constant (and asserted in
# the tests) so a reword on either side fails a test instead of silently un-grouping every
# package. It rides the SAME ``==> `` banner convention progress_parse.py already matches,
# so whether a builder emits it via the shared `banner` helper or a bare `echo` is the
# builder lane's choice — the wire format is this string.
GROUP_BANNER_PREFIX = "==> Emerge group: "
GROUP_UNKNOWN = ""

# ── the ebuild step ladder ───────────────────────────────────────────────────────────
STEP_QUEUED = "queued"
STEP_UNPACK = "unpack"
STEP_PREPARE = "prepare"
STEP_CONFIGURE = "configure"
STEP_COMPILE = "compile"
STEP_TEST = "test"
STEP_INSTALL = "install"
STEP_DONE = "done"
STEP_FAILED = "failed"

# Ordinal order — a package only ever moves FORWARD along this (see _advance).
STEPS: tuple[str, ...] = (STEP_QUEUED, STEP_UNPACK, STEP_PREPARE, STEP_CONFIGURE,
                          STEP_COMPILE, STEP_TEST, STEP_INSTALL, STEP_DONE)
_STEP_INDEX = {s: i for i, s in enumerate(STEPS)}

# Percent CREDITED WHEN A STEP BEGINS. This is a coarse ordinal ladder, not a time model —
# it says "this package has at least got as far as X", never "it will finish in N minutes".
# The band widths are sized off the one long build we can actually measure: sys-devel/
# gettext-0.22.5-r2 in the real transcript spans lines 322..16270, of which configure took
# 2401 lines (15%), COMPILE took 10993 lines (69%), and src_install took 2493 lines (16%),
# while unpack+prepare together took 56 lines (0.4%). Log lines are a proxy for effort, not
# a measurement of it, so the ladder below deliberately UNDER-credits the early steps
# (2/5/10 where the evidence would allow ~0.4) and gives compile the long pole it earns
# (15 -> 80 = a 65-point band vs the measured 69% of output). Under-claiming is the safe
# direction: a bar that lags reality is honest, one that runs ahead is a lie.
STEP_PERCENT: dict[str, int] = {
    STEP_QUEUED: 0,
    STEP_UNPACK: 2,
    STEP_PREPARE: 5,
    STEP_CONFIGURE: 10,
    STEP_COMPILE: 15,
    STEP_TEST: 80,
    STEP_INSTALL: 85,
    STEP_DONE: 100,
}

# ── line regexes (ALL applied after strip_ansi, per the module contract) ─────────────
_GROUP_BANNER_RE = re.compile(r"^==>\s*Emerge group:\s*(\S+)\s*$")

# CROSS-BUILD TAIL (``_ROOT_TAIL``). When ROOT is not ``/`` portage appends the target
# root to its counter lines — " for /out/wl-pki.rpi5/sysroot/" on Emerging, " to <same>"
# on Installing and Completed. See the ROOT-TARGETED MERGES note in the module docstring.
# Every ARM builder emerges into ``${BUILD_ROOT}/sysroot``, so the tail is present on
# precisely the packages that land in the IMAGE, while host BDEPEND tools (merged to /)
# have no tail. An earlier ``\s*$`` anchor right after the optional ``::repo`` therefore
# dropped the target half of every cross build: 222 of the real rpi5 transcript's 283
# ``Emerging`` lines carry the tail, so the Studio tree listed only the 61 host tools and
# silently omitted all 222 image packages — replaying that log through the pre-change
# parser yields 60 rows, not 266. ``Completed`` carries the same tail, so those rows could
# never reach STEP_DONE either.
#
# The tail is matched but deliberately NOT captured: the row is keyed by atom, so leaking
# a sysroot path into it would fork one package into two rows (native vs cross) and break
# every dict keyed by it — and a build already knows its own sysroot.
#
# The keyword (``for``/``to``) is what gates this, NOT the shape of the path: the path is
# allowed to contain spaces (``\S.*?``) because nothing stops an operator from pointing
# --workdir at one. Anything else trailing the atom still matches nothing, because
# inventing a row out of a line shape we do not recognise would be a guess.
#
# RECONCILED: the identical defect was fixed independently on main (#483, 6a1f20c) with
# the same constant name and the same two call sites; the only difference was ``\S+`` vs
# this ``\S.*?``. This branch keeps the superset pattern (the space-tolerant one) and
# main's call sites, comment and tests — see studio/tests/test_emerge_packages.py.
_ROOT_TAIL = r"(?:\s+(?:for|to)\s+\S.*?)?"

# ">>> Emerging (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo" and its binpkg twin
# ">>> Emerging binary (436 of 805) sys-apps/groff-1.23.0-r2::gentoo" (line 2526970), plus
# ">>> Installing (1 of 258) ...". The ``::repo`` suffix is optional — portage omits it for
# some sources and we never need it.
_COUNTER_RE = re.compile(
    r"^>>>\s+(Emerging|Installing)(?:\s+binary)?\s+\((\d+) of (\d+)\)\s+(\S+?)(?:::\S+)?"
    + _ROOT_TAIL + r"\s*$")

# ">>> Completed (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo" — the true per-package
# terminal marker (line 17834). The ``\(`` is what keeps this from also eating
# ">>> Completed installing <atom> into <image>", which is merely the end of src_install.
# Carries the same cross-build tail (">>> Completed (1 of 1) …::gentoo to <sysroot>"), so
# without it a cross build's rows never reached STEP_DONE.
_COMPLETED_RE = re.compile(
    r"^>>>\s+Completed\s+\((\d+) of (\d+)\)\s+(\S+?)(?:::\S+)?" + _ROOT_TAIL + r"\s*$")

# ── portage's parallel SCHEDULER status line (see the PARALLEL EMERGE note above) ────
# Deliberately NOT one regex per observed shape: the clause list is open-ended, a label may
# contain a space ("merge wait"), and the gap before "Load avg:" is a variable-width
# right-alignment run. So the prefix is a cheap literal, the fixed head is one small regex,
# and the clauses are walked generically — an unknown clause portage adds tomorrow lands in
# SchedulerState.clauses verbatim instead of silently disappearing.
JOBS_PREFIX = ">>> Jobs:"
_JOBS_HEAD_RE = re.compile(r"^(\d+)\s+of\s+(\d+)\s+complete\b")
_JOBS_CLAUSE_RE = re.compile(r"^(\d+)\s+(\S.*)$")
_LOAD_AVG_MARK = "Load avg:"
# The two clause labels the real transcript actually prints, pinned so a reword fails a
# test rather than silently zeroing the aggregate the operator reads.
JOBS_CLAUSE_RUNNING = "running"
JOBS_CLAUSE_MERGE_WAIT = "merge wait"
# portage has a failed-jobs counter too, but this transcript never printed one — so it is
# read through the SAME generic clause walk (no invented regex) and stays 0 until seen.
JOBS_CLAUSE_FAILED = "failed"

# ── poll() bounds: this is the ONE filesystem path in the module, so cap it ───────────
# One pass per this many seconds. The GUI drives poll() from its existing 1 Hz tick, so
# this only ever bites if some other caller polls in a tight loop.
POLL_MIN_INTERVAL = 0.5
# Bytes read per in-flight atom per pass. A compile log grows by megabytes; the follow is
# for the LATEST state, so a bounded chunk that skips no lines (the offset only ever
# advances by what was read) is the right trade — it just catches up over a few ticks.
POLL_CHUNK_BYTES = 64 * 1024
# In-flight atoms touched per pass. --jobs is bounded by the host's core count in every
# builder, so this is slack, not a policy.
POLL_MAX_ATOMS = 32

# ">>> Failed to emerge app-office/libreoffice-25.2.7.2-r1, Log file:" (line 2794910), and
# the log path portage prints on a LATER line, chroot-absolute and single-quoted
# (line 2794912, with a blank line between them).
_FAILED_RE = re.compile(r"^>>>\s+Failed to emerge\s+([^,\s]+)")
_FAILED_LOG_RE = re.compile(r"^>>>\s+'(\S+\.log)'\s*$")
_FAILED_LOG_WINDOW = 5      # lines to keep looking after the "Failed to emerge" line

# Atom-NAMED ladder lines — safe under any parallelism.
_TEST_RE = re.compile(r"^>>>\s+Test phase\b[^:]*:\s*(\S+/\S+)\s*$")
_SRC_INSTALL_RE = re.compile(r"^>>>\s+Install\s+(\S+/\S+)\s+into\s")
_SRC_INSTALLED_RE = re.compile(r"^>>>\s+Completed installing\s+(\S+/\S+)\s+into\s")

# Atom-LESS ladder lines — only credited when exactly one package is in flight.
_ANON_LADDER: tuple[tuple[str, str], ...] = (
    (">>> Unpacking source", STEP_UNPACK),
    (">>> Source unpacked", STEP_UNPACK),
    (">>> Preparing source in", STEP_PREPARE),
    (">>> Source prepared.", STEP_PREPARE),
    (">>> Configuring source in", STEP_CONFIGURE),
    (">>> Source configured.", STEP_CONFIGURE),
    (">>> Compiling source in", STEP_COMPILE),
    (">>> Source compiled.", STEP_COMPILE),
)

# Gentoo's PF split: the version starts at the first ``-`` that is followed by a digit, and
# the only hyphen a version may itself contain is the ``-rN`` revision. Non-greedy + the
# ``\d`` anchor makes "gtk-doc-1.34.0" -> (gtk-doc, 1.34.0) and "acct-group/polkitd-0-r3"
# -> (polkitd, 0-r3) fall out correctly; both shapes are in the real transcript.
_PF_RE = re.compile(r"^(?P<pn>.+?)-(?P<ver>\d[^-]*(?:-r\d+)?)$")

# One elog header row, post-strip_ansi: " * USE:        X abi_x86_64 adobe-cff ...".
# The key is a single bare word glued to its colon — which is exactly what keeps portage's
# OTHER asterisk lines out: " * Unsetting ebtables symlinks before removal" (the iptables
# trailer) and " * QA Notice: ..." both have whitespace where the colon would have to be.
_HEADER_ROW_RE = re.compile(r"^\s*\*\s+([A-Za-z][A-Za-z0-9_-]*):\s*(.*?)\s*$")
_USE_HEADER_SCAN_LINES = 64   # header sits in the first ~6 lines; bound the read anyway

# ── build-tool telemetry (all matched post-strip_ansi, post-lstrip) ──────────────────
# ninja/samu "[123/1186] <command or description>" — the one tool counter honest enough
# to refine a percent from (a real completed/total, not a heuristic).
_NINJA_RE = re.compile(r"^\[(\d+)/(\d+)\]\s+\S")
# make's two loud shapes: the top-level "make -j4 ..." invocation echo and the recursive
# "make[2]: Entering directory '...'" markers.
_MAKE_RE = re.compile(r"^make(?:\[\d+\]: Entering directory\s|\s+-j\d+\b)")
# cmake's three configure-stage milestones (lines 69747-69749 of the real transcript).
_CMAKE_RE = re.compile(r"^-- (?:Configuring done|Generating done|Build files have been written)")
# autoconf probes; collapsed to "configure: checking ..." when surfaced.
_CONFIGURE_RE = re.compile(r"^checking .+")
# npm's invocation echo and its "added 1300 packages in 25s" summary.
_NPM_RE = re.compile(r"^(?:npm install\b|added \d+ packages?\b)")
# cargo "Compiling proc-macro2 v1.0.106" (the 3-space indent is gone post-lstrip).
_CARGO_RE = re.compile(r"^Compiling \S+ v\d\S*$")
# First characters a tool line can start with, post-lstrip — the cheap gate that keeps
# feed() from running six regexes against every one of a build's millions of lines.
_TOOL_FIRST_CHARS = frozenset("[m-cnaC")


@dataclass
class PackageProgress:
    """One package's live row. Mutable and shared: :meth:`EmergePackageParser.packages`
    hands back the SAME objects on every call so a GUI can hold a row and watch it move
    (the alternative — copying ~800 dataclasses per fed line — is what the O(1)-per-line
    discipline in stage_tracker.py exists to avoid). Treat them as read-only."""
    atom: str                             # "xfce-base/xfwm4-4.20.0"
    category: str                         # "xfce-base"
    name: str                             # "xfwm4"
    version: str                          # "4.20.0"
    group: str                            # one of EMERGE_GROUPS, or GROUP_UNKNOWN
    index: int = 0                        # N from "(N of M)", 0 while unknown
    total: int = 0                        # M from "(N of M)", 0 while unknown
    step: str = STEP_QUEUED
    percent: int = 0                      # 0..100, monotonic; 100 only when step == done
    use_flags: tuple[str, ...] = ()
    log_path: str = ""
    failed: bool = False
    header: dict[str, str] = field(default_factory=dict)   # full elog header, {} until known
    tool_info: str = ""                   # latest build-tool telemetry line, "" when none


@dataclass
class SchedulerState:
    """What portage's ``>>> Jobs:`` line last said, plus who WE know is in flight.

    Mutable and shared, exactly like :class:`PackageProgress`:
    :meth:`EmergePackageParser.scheduler` hands back the same object every time so a GUI
    can hold it and watch it move. Treat it as read-only.

    The two halves are deliberately separate and are NOT reconciled into one number:

    * ``complete`` / ``total`` / ``running`` / ``merge_wait`` / ``failed`` / ``load_avg``
      are portage's own figures, verbatim from the last status line. ``running`` counts
      jobs the SCHEDULER has started, which legitimately exceeds ``len(inflight)`` — the
      real transcript prints ``>>> Jobs: 0 of 149 complete, 1 running`` on the line BEFORE
      the ``>>> Emerging (1 of 149)`` that first names the atom.
    * ``inflight`` is the set of atoms this parser has seen opened by ``Emerging`` and not
      yet closed by ``Completed``/``Failed``, oldest first. That is the honest answer to
      "which packages can I show a live row for", because it is the only one keyed to an
      atom.

    ``seen`` is False until a ``>>> Jobs:`` line has actually been parsed, so a serial
    build (``--jobs 1`` still prints them; a build whose emerge is not reached at all does
    not) is distinguishable from ``0 of 0``. ``revision`` increments on every change to
    any field — it is the fingerprint a GUI compares to skip a no-op repaint, the same
    discipline the per-package rows use.
    """
    complete: int = 0
    total: int = 0
    running: int = 0
    merge_wait: int = 0
    failed: int = 0
    load_avg: tuple[float, ...] = ()
    clauses: dict[str, int] = field(default_factory=dict)
    inflight: tuple[str, ...] = ()
    seen: bool = False
    revision: int = 0


@dataclass
class _Tail:
    """Per-atom incremental-read cursor for :meth:`EmergePackageParser.poll`.

    ``ident`` is ``(st_dev, st_ino)``: comparing it is what distinguishes "the file grew"
    from "a DIFFERENT file now lives at this path", which really happens — portage writes
    a fresh ``<cat>:<pf>:<STAMP>.log`` per merge attempt, and a sysroot can be re-created
    under the same name between runs. ``residue`` holds the trailing BYTES of a line that
    the byte cap or the writer's own buffering cut in half, so no line is ever parsed
    twice or dropped — bytes rather than text so that a chunk boundary inside a multi-byte
    UTF-8 character rejoins instead of decoding into two replacement chars."""
    path: str = ""
    offset: int = 0
    ident: tuple[int, int] | None = None
    residue: bytes = b""


def split_atom(atom: str) -> tuple[str, str, str]:
    """``"xfce-base/xfwm4-4.20.0"`` -> ``("xfce-base", "xfwm4", "4.20.0")``.

    Anything that does not split cleanly degrades instead of raising: a missing version
    yields ``("", <whole>, "")`` rather than a fabricated one, because a row labelled with
    the raw text portage printed is honest and a row labelled with a guessed version is
    not."""
    cat, sep, pf = atom.partition("/")
    if not sep:
        return "", atom, ""
    m = _PF_RE.match(pf)
    if not m:
        return cat, pf, ""
    return cat, m.group("pn"), m.group("ver")


def _log_stamp(path: str) -> str:
    """The ``YYYYMMDD-HHMMSS`` field of ``<cat>:<pf>:<STAMP>.log``, or "" if malformed.
    Fixed-width, so plain string ordering IS chronological ordering."""
    base = os.path.basename(path)
    stem = base[:-4] if base.endswith(".log") else base
    return stem.rpartition(":")[2]


def find_package_logs(log_root: str, atom: str) -> list[str]:
    """Every ``<log_root>/<cat>:<pf>:<STAMP>.log`` for ``atom``, NEWEST FIRST.

    Ranking on the embedded stamp rather than mtime is deliberate: it survives a sysroot
    that was copied/rsynced out of the chroot, and the two orders genuinely disagree —
    ``net-firewall:iptables-1.8.13:20260725-211759.log`` has the later stamp but the
    EARLIER mtime (14:17 vs 14:18) than ``...-211746.log``, because the stamp is when the
    ebuild phase started and the mtime is when it last wrote."""
    if not log_root or "/" not in atom:
        return []
    cat, pf = atom.split("/", 1)
    hits = glob.glob(os.path.join(log_root, f"{glob.escape(cat)}:{glob.escape(pf)}:*.log"))
    return sorted(hits, key=lambda p: (_log_stamp(p), p), reverse=True)


def find_package_log(log_root: str, atom: str) -> str:
    """Newest log for ``atom``, or "" if there is none.

    NEWEST matters and is not hypothetical: the real session has TWO logs for the very
    same atom — ``sys-devel:gettext-0.22.5-r2:20260725-210758.log`` and
    ``...-210759.log`` — because the x86 builder's quarantine downgrade
    (build-x86-host-stage4.sh:4420) merges gettext twice."""
    hits = find_package_logs(log_root, atom)
    return hits[0] if hits else ""


def parse_header(log_path: str) -> dict[str, str]:
    """The whole elog header block of a per-package portage log, ANSI-stripped —
    ``{"Package": "media-libs/freetype-2.14.3:2", "Repository": "gentoo", ...}``.

    Returns ``{}`` for a missing / unreadable / header-less file rather than raising —
    the GUI polls this while the build is still running, so "the log is not there yet"
    is a NORMAL state, not an error. Two real-format facts shape the scan (both from the
    session's own logs, see the module docstring):

    * the header is usually the very top of the file (bytes 0..321 of the freetype log)
      but a BINARY merge writes ``>>> Extracting info`` FIRST (groff log, line 1), so the
      reader hunts for the first header-shaped row within the first
      :data:`_USE_HEADER_SCAN_LINES` lines instead of demanding line 0;
    * the block is CONTIGUOUS, so reading stops at the first non-header line after it
      starts — that is what keeps a ``* QA Notice``-style asterisk line deeper in the
      file from being glued on as a fake header key, and what keeps this from ever
      walking a multi-hundred-MB compile log.

    The key set is NOT pinned to Package/Repository/Maintainer/USE/FEATURES on purpose:
    the groff binary log genuinely lacks Maintainer, and a future portage may add rows —
    the GUI shows whatever portage actually wrote."""
    if not log_path:
        return {}
    header: dict[str, str] = {}
    try:
        with open(log_path, encoding="utf-8", errors="replace") as fh:
            for i, raw in enumerate(fh):
                if i >= _USE_HEADER_SCAN_LINES:
                    break
                m = _HEADER_ROW_RE.match(strip_ansi(raw).rstrip("\r\n"))
                if m:
                    header[m.group(1)] = m.group(2)
                elif header:
                    break            # the contiguous block is over — stop reading
    except OSError:
        return {}
    return header


def parse_use_flags(log_path: str) -> tuple[str, ...]:
    """USE flags from a per-package portage log's elog header — the ``USE`` row of
    :func:`parse_header`, split on whitespace. ``()`` when the file is missing,
    unreadable, or its header has no USE row, rather than raising (same normal-state
    reasoning as :func:`parse_header`)."""
    return tuple(parse_header(log_path).get("USE", "").split())


class EmergePackageParser:
    """Stateful, line-fed per-package emerge tracker for ONE image build.

    Feed every stdout line (raw, with ANSI) through :meth:`feed`; it returns the
    :class:`PackageProgress` the line moved, or ``None`` when the line said nothing about
    a package. Pass ``log_root`` (the build's
    ``<session>/wl-<role>.<arch>/sysroot/var/log/portage/build``) to have the elog header
    (USE flags included) and log paths resolved as they become available; leave it empty
    and the parser stays a pure
    stream parser with no filesystem access at all (which is how the tests and the
    admin-bff pod-log follower can run it)."""

    def __init__(self, log_root: str = "") -> None:
        self.log_root = log_root
        self._group = GROUP_UNKNOWN
        self._pkgs: dict[str, PackageProgress] = {}       # atom -> row, insertion-ordered
        self._inflight: dict[str, PackageProgress] = {}   # Emerging..Completed/Failed
        self._counter: dict[str, tuple[int, int]] = {}    # group -> last (N, M) seen
        self._total_hwm: dict[str, int] = {}              # group -> high-water total
        self._resolved: set[str] = set()                  # atoms whose log+USE are settled
        self._explicit_log: set[str] = set()              # atoms portage named a log for
        self._await_fail_log: PackageProgress | None = None
        self._await_fail_budget = 0
        # ── parallel-emerge state (all inert on a serial build) ──────────────────────
        self._sched = SchedulerState()
        self._parallel = False                            # sticky; see _note_parallel
        self._tails: dict[str, _Tail] = {}                # atom -> incremental read cursor
        self._last_poll: float | None = None

    # ── public API ───────────────────────────────────────────────────────────────────
    def group(self) -> str:
        """Current emerge group, or :data:`GROUP_UNKNOWN` before the first group banner."""
        return self._group

    def scheduler(self) -> SchedulerState:
        """Portage's live ``>>> Jobs:`` figures + the in-flight atom set (live shared
        object — see :class:`SchedulerState`)."""
        return self._sched

    def inflight(self) -> list[PackageProgress]:
        """Every package opened by ``Emerging`` and not yet closed by
        ``Completed``/``Failed``, OLDEST FIRST (live objects). Under ``--jobs`` this is
        the set of rows that should be showing live status at the same time; serially it
        holds at most one."""
        return list(self._inflight.values())

    def parallel(self) -> bool:
        """True once this stream has PROVEN it is a parallel emerge — either two atoms
        were in flight simultaneously, or portage's own status line reported more than one
        running job. Sticky: ``--jobs`` is fixed for the whole invocation, so a momentary
        dip to one in-flight package (the tail of a batch, or its very first package) does
        not mean the build went serial, and letting it flip back would freeze exactly the
        rows the operator is watching. Serial builds never set it, which is what keeps
        :meth:`poll` a no-op — and therefore the proven serial path byte-identical."""
        return self._parallel

    def packages(self) -> list[PackageProgress]:
        """Every package seen, in first-seen order (live objects — see PackageProgress)."""
        return list(self._pkgs.values())

    def current(self) -> PackageProgress | None:
        """The most recently started package that is still in flight, or ``None`` when
        nothing is (between packages, and after the last one completes). Deliberately NOT
        "the last row we touched": once a build is over there IS no current package, and
        saying otherwise would leave a bar spinning forever."""
        if not self._inflight:
            return None
        return next(reversed(list(self._inflight.values())))

    def totals(self) -> tuple[int, int]:
        """``(completed, total)`` for the CURRENT group.

        ``completed`` counts only rows that reached ``done`` — a failed package is never
        counted as progress. ``total`` cannot just be the current ``(N of M)``: portage
        restarts that counter both for each new emerge invocation within a group (``(1 of
        1)`` at line 96 then ``(1 of 258)`` at 17744) AND on every ``--keep-going`` resume
        (``*** Resuming merge...`` at line 2794913 is followed by ``(1 of 245)`` at
        2794952, after 560 packages had already merged). So it is derived from what we can
        actually stand behind — packages already finished, packages in flight right now,
        and packages the current counter still has queued behind the in-flight one — and
        floored both by the number of distinct rows seen and by a per-group high-water
        mark, because we never legitimately learn that a group has FEWER packages than we
        already know about. On the real resume that reconstructs 560 + 1 + 244 = 805,
        exactly the pre-failure total.

        Under ``--jobs`` the stored ``N`` has to be a HIGH-WATER mark rather than "the last
        one seen" (see :meth:`_note_counter`): packages finish out of order, so a
        ``Completed (10 of 149)`` can legitimately arrive after an ``Emerging (13 of 149)``,
        and taking that 10 as the frontier would count the three packages between them
        twice and inflate the total past the 149 portage actually announced."""
        g = self._group
        rows = [p for p in self._pkgs.values() if p.group == g]
        completed = sum(1 for p in rows if p.step == STEP_DONE)
        inflight = sum(1 for p in self._inflight.values() if p.group == g)
        n, m = self._counter.get(g, (0, 0))
        projected = completed + inflight + max(m - n, 0) if m > 0 else 0
        total = max(len(rows), projected, self._total_hwm.get(g, 0))
        self._total_hwm[g] = total
        return completed, total

    def feed(self, raw_line: str) -> PackageProgress | None:
        line = strip_ansi(raw_line).rstrip("\r\n")

        # 1. group banner — changes the bucket new rows land in, moves no package.
        m = _GROUP_BANNER_RE.match(line.lstrip())
        if m:
            g = m.group(1)
            # An unrecognised name is IGNORED rather than accepted: a typo in a builder
            # must not be able to invent a sixth group the GUI has no column for.
            if g in EMERGE_GROUPS:
                self._group = g
            return None

        stripped = line.lstrip()

        # 1b. portage's parallel scheduler status line. It names no package (so the return
        #     value stays None per this method's contract) but it is the only source of the
        #     aggregate the operator asked for — "12 of 283 · 4 running". Gated on a literal
        #     startswith before any regex: 1752 of the real rpi5 transcript's 22,025 lines
        #     are these, and the O(1)-per-line discipline applies to them too.
        if stripped.startswith(JOBS_PREFIX):
            self._feed_jobs(stripped)
            return None

        # 2. the log path portage prints a line or two AFTER "Failed to emerge".
        if self._await_fail_log is not None:
            self._await_fail_budget -= 1
            fm = _FAILED_LOG_RE.match(stripped)
            if fm:
                pkg = self._await_fail_log
                self._await_fail_log = None
                # The path portage prints is CHROOT-absolute ("/var/log/portage/build/..."),
                # which does not exist on the host — rebase its basename onto log_root.
                pkg.log_path = (os.path.join(self.log_root, os.path.basename(fm.group(1)))
                                if self.log_root else fm.group(1))
                self._explicit_log.add(pkg.atom)
                # Re-open the resolution. By now the row has almost certainly ALREADY been
                # resolved against a glob guess (``_row`` resolves at creation, i.e. back on
                # the ``Emerging`` line), and that guess can be a DIFFERENT file: the real
                # session holds two logs for this very atom —
                # app-office:libreoffice-25.2.7.2-r1:20260725-230047.log (764 B, the earlier
                # attempt) and :20260726-024143.log (37 KB, the one portage names here.
                # Leaving the row resolved would show flags read from one file next to a
                # click-through that opens the other; they happen to agree on THIS build but
                # nothing makes them, and the x86 builder's ``emerge --update --deep
                # --newuse --keep-going @world`` (build-x86-host-stage4.sh:4424) is the case
                # that re-merges a package with different USE. The named file is the
                # evidence of THIS failure, so it wins for both fields.
                self._resolved.discard(pkg.atom)
                self._resolve_log(pkg)
                return pkg
            if self._await_fail_budget <= 0:
                self._await_fail_log = None

        # 3. ">>> (Emerging|Installing) (N of M) <atom>[::repo]"
        m = _COUNTER_RE.match(stripped)
        if m:
            verb, n, tot, atom = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
            pkg = self._row(atom)
            pkg.index, pkg.total = n, tot
            self._note_counter(n, tot)
            if verb == "Emerging":
                self._inflight.pop(atom, None)   # re-insert so order == recency
                self._inflight[atom] = pkg
                self._note_inflight()
            else:
                # For a BINARY merge this is the only install signal there is — line
                # 2526970's groff goes Emerging binary -> Extracting -> Installing with no
                # ebuild ladder at all, so the ladder steps must not be a precondition.
                self._advance(pkg, STEP_INSTALL)
            return pkg

        # 4. ">>> Completed (N of M) <atom>[::repo]" — the honest per-package terminal.
        m = _COMPLETED_RE.match(stripped)
        if m:
            pkg = self._row(m.group(3))
            pkg.index, pkg.total = int(m.group(1)), int(m.group(2))
            self._note_counter(pkg.index, pkg.total)
            self._inflight.pop(pkg.atom, None)
            self._note_inflight()
            self._advance(pkg, STEP_DONE)
            return pkg

        # 5. ">>> Failed to emerge <atom>, Log file:"
        m = _FAILED_RE.match(stripped)
        if m:
            pkg = self._row(m.group(1))
            self._inflight.pop(pkg.atom, None)
            self._note_inflight()
            self._fail(pkg)
            self._await_fail_log = pkg
            self._await_fail_budget = _FAILED_LOG_WINDOW
            return pkg

        # 6. atom-NAMED ladder lines — attribution is exact, parallelism-proof.
        for rx, step in ((_TEST_RE, STEP_TEST), (_SRC_INSTALL_RE, STEP_INSTALL),
                         (_SRC_INSTALLED_RE, STEP_INSTALL)):
            m = rx.match(stripped)
            if m:
                pkg = self._row(m.group(1))
                self._advance(pkg, step)
                return pkg

        # 7. atom-LESS ladder lines — credited only when the stream itself proves there is
        #    exactly one candidate (see the ATTRIBUTION note in the module docstring).
        for prefix, step in _ANON_LADDER:
            if stripped.startswith(prefix):
                if len(self._inflight) != 1:
                    return None
                pkg = next(iter(self._inflight.values()))
                self._advance(pkg, step)
                return pkg

        # 8. build-tool telemetry (ninja/make/cmake/configure/npm/cargo). Atom-less like
        #    step 7, so the same attribution rule applies: credited only when exactly one
        #    package is in flight, dropped under parallel emerge rather than mis-credited.
        #    74,998 of the real transcript's 3.16M lines are ninja counters alone, so this
        #    path is gated on the first character before any regex runs — the O(1)-per-line
        #    discipline the whole feed loop lives by. (The parallel leg recovers exactly
        #    these lines from each package's OWN log, where they need no guessing at all:
        #    _feed_pkg_line -> the same _apply_tool below.)
        if len(self._inflight) == 1:
            pkg = next(iter(self._inflight.values()))
            if self._apply_tool(pkg, stripped):
                return pkg
        return None

    def poll(self, now: float | None = None) -> list[PackageProgress]:
        """PARALLEL-mode live status. Returns the rows that MOVED, ``[]`` when none did.

        This is the module's one filesystem-touching, caller-driven pass, and it exists
        because :meth:`feed` cannot answer the operator's question under ``--jobs``: with
        several packages compiling at once portage sends each one's output to that
        package's own log instead of the shared stdout, so the stream literally does not
        contain the lines that would move those bars. Here we go and read them: for each
        in-flight atom, tail its own portage build log from a remembered byte offset and
        apply the new lines to that atom's row via :meth:`_feed_pkg_line`.

        Deliberately NOT called from :meth:`feed`. feed() is documented as O(1) per line
        and filesystem-free (a caller may hand it three million lines as fast as it can
        read them); a stat+read per line would destroy both properties. The GUI drives
        this from the 1 Hz tick it already runs for elapsed time.

        Preconditions, all of them cheap and all of them fail-quiet:

        * a ``log_root`` — without one the parser stays the pure stream parser its class
          docstring promises;
        * :meth:`parallel` — a serial build's ladder and tool lines are ALREADY in the
          stream and already credited, so polling it would be duplicate work on a path
          that is proven correct. This is what makes the change a no-op for x86/rpi5 at
          their default ``--jobs 1``;
        * ``now`` no sooner than :data:`POLL_MIN_INTERVAL` after the previous pass
          (``now=None`` reads the monotonic clock; tests pass explicit increasing values).

        Bounded by construction: at most :data:`POLL_MAX_ATOMS` atoms per pass, at most
        :data:`POLL_CHUNK_BYTES` per atom, and never a re-read — the offset only advances
        by bytes actually consumed, so a package whose log grew by 4 MB catches up over
        the next few ticks instead of stalling the caller for a second.

        OSError per atom is swallowed (the log lives inside a chroot the build is actively
        writing; "not there yet", "just replaced", "vanished with the sysroot" are all
        normal), because one unreadable file must not stop the other rows from moving."""
        moved: list[PackageProgress] = []
        if not self.log_root or not self._parallel:
            return moved
        t = time.monotonic() if now is None else now
        if self._last_poll is not None and (t - self._last_poll) < POLL_MIN_INTERVAL:
            return moved
        self._last_poll = t
        for pkg in list(self._inflight.values())[:POLL_MAX_ATOMS]:
            try:
                if self._tail_package(pkg):
                    moved.append(pkg)
            except OSError:
                continue
        # Bounded memory: a cursor is only useful while its atom is in flight. Swept in
        # bulk rather than per-completion so the common path stays allocation-free.
        if len(self._tails) > POLL_MAX_ATOMS * 4:
            for atom in [a for a in self._tails if a not in self._inflight]:
                del self._tails[atom]
        return moved

    # ── internals ────────────────────────────────────────────────────────────────────
    def _feed_jobs(self, stripped: str) -> None:
        """Parse one ``>>> Jobs: ...`` line into :attr:`_sched`.

        Shape-agnostic on purpose (see the PARALLEL EMERGE note in the module docstring):
        split on the literal ``Load avg:``, match the fixed ``N of M complete`` head, then
        walk the remaining comma-separated ``<count> <label>`` clauses. That is what copes
        with a label containing a space ("merge wait"), with the variable-width alignment
        run before ``Load avg:``, and with a clause portage adds in a future release — an
        unrecognised label is recorded in :attr:`SchedulerState.clauses` rather than
        dropped or guessed at.

        A line that does not match the head is left alone entirely: the previous reading
        stays, because a half-parsed status line is worse than a slightly stale one."""
        body = stripped[len(JOBS_PREFIX):]
        head, _, tail = body.partition(_LOAD_AVG_MARK)
        m = _JOBS_HEAD_RE.match(head.strip())
        if not m:
            return
        clauses: dict[str, int] = {}
        for part in head.strip()[m.end():].split(","):
            part = part.strip()
            if not part:
                continue
            cm = _JOBS_CLAUSE_RE.match(part)
            if cm:
                clauses[cm.group(2).strip().lower()] = int(cm.group(1))
        load: tuple[float, ...] = ()
        if tail:
            vals = []
            for fld in tail.split(","):
                try:
                    vals.append(float(fld.strip()))
                except ValueError:
                    break        # stop at the first non-number; report what parsed
            load = tuple(vals)
        s = self._sched
        before = (s.complete, s.total, s.running, s.merge_wait, s.failed, s.load_avg,
                  s.clauses, s.seen)
        s.complete, s.total = int(m.group(1)), int(m.group(2))
        s.clauses = clauses
        s.running = clauses.get(JOBS_CLAUSE_RUNNING, 0)
        s.merge_wait = clauses.get(JOBS_CLAUSE_MERGE_WAIT, 0)
        s.failed = clauses.get(JOBS_CLAUSE_FAILED, 0)
        s.load_avg = load
        s.seen = True
        if (s.complete, s.total, s.running, s.merge_wait, s.failed, s.load_avg,
                s.clauses, s.seen) != before:
            s.revision += 1
        # portage's own count is the earliest proof of parallelism there is — it reports a
        # job as running before the ">>> Emerging" line that names its atom.
        if s.running > 1:
            self._parallel = True

    def _note_inflight(self) -> None:
        """Republish the in-flight atom set onto :attr:`_sched` (and latch parallelism).

        Called on exactly the three lines that can change the set — Emerging / Completed /
        Failed — so it is O(concurrency) a few hundred times per build, not per line."""
        s = self._sched
        atoms = tuple(self._inflight)
        if atoms != s.inflight:
            s.inflight = atoms
            s.revision += 1
        if len(atoms) > 1:
            self._parallel = True

    def _note_counter(self, n: int, total: int) -> None:
        """Record the ``(N of M)`` frontier for the current group, keeping ``N`` as a
        HIGH-WATER mark within one ``M``.

        Serially "the last N seen" and "the highest N seen" are the same number. Under
        ``--jobs`` they are not: packages complete out of order, so ``Completed (10 of
        149)`` can arrive after ``Emerging (13 of 149)``, and :meth:`totals` would then
        project ``completed + inflight + (149 - 10)`` and count the packages in between
        twice. A CHANGE of ``M`` still replaces the pair outright, which is what keeps the
        documented ``--keep-going`` resume reconstruction (M goes 805 -> 245) working."""
        prev = self._counter.get(self._group)
        if prev is not None and prev[1] == total:
            n = max(n, prev[0])
        self._counter[self._group] = (n, total)

    def _apply_tool(self, pkg: PackageProgress, stripped: str) -> bool:
        """Apply one build-tool telemetry line to ``pkg``; True if it moved the row.

        Extracted verbatim from feed()'s step 8 so the parallel leg (:meth:`_feed_pkg_line`,
        reading the package's own log) and the serial leg (the shared stdout) run the SAME
        table — a tool shape can never be recognised in one mode and not the other."""
        first = stripped[:1]
        if first not in _TOOL_FIRST_CHARS:
            return False
        info = stripped.rstrip()        # the real "make -j4 " (L2783) trails a space
        if first == "[":
            m = _NINJA_RE.match(stripped)
            if not m:
                return False
            pkg.tool_info = info
            # The ONE sanctioned tool-derived percent: ninja's N/M is a real
            # completed/total counter, so while the ladder says we are in compile it
            # interpolates across the compile band — and ONLY up to one point short of
            # the test step's floor, because "ninja printed [M/M]" is not the same fact
            # as ">>> Source compiled." (post-build script steps still run). max() keeps
            # it monotonic across the counter RESTARTS that really happen: multibuild
            # ebuilds (gettext builds once per ABI) and the install phase re-invoke ninja
            # from [1/...].
            n, mtot = int(m.group(1)), int(m.group(2))
            if pkg.step == STEP_COMPILE and 0 < n <= mtot:
                lo = STEP_PERCENT[STEP_COMPILE]
                hi = STEP_PERCENT[STEP_TEST] - 1
                pkg.percent = max(pkg.percent, lo + ((hi - lo) * n) // mtot)
            return True
        if ((first == "m" and _MAKE_RE.match(stripped))
                or (first == "-" and _CMAKE_RE.match(stripped))
                or (first in "na" and _NPM_RE.match(stripped))
                or (first == "C" and _CARGO_RE.match(stripped))):
            pkg.tool_info = info
            return True
        if first == "c" and _CONFIGURE_RE.match(stripped):
            # collapsed so the GUI cell says which tool is talking — bare
            # "checking for a race-free mkdir -p..." reads like our own status.
            pkg.tool_info = "configure: " + info
            return True
        return False

    def _feed_pkg_line(self, pkg: PackageProgress, raw: str) -> None:
        """Apply ONE line of a package's OWN portage build log to that package's row.

        The parallel twin of feed()'s steps 6-8, and the reason the parallel mode can show
        what the serial mode shows: the ATTRIBUTION problem that forces feed() to DROP
        atom-less lines under ``--jobs`` does not exist here, because the line came out of
        THIS atom's file. ">>> Compiling source in ..." is unambiguous, so it is credited.
        Same :data:`_ANON_LADDER`, same :meth:`_advance`, same :meth:`_apply_tool` — one
        ladder, so the two modes cannot drift.

        Confirmed against a real per-package log from the operator's own build
        (``net-libs:nghttp2-1.68.0:20260730-043807.log``, 613 lines): elog header, then
        Unpacking / Source unpacked / Preparing / Source prepared / Configuring / Source
        configured / Compiling / Source compiled / Test phase / Install <atom> into /
        Completed installing <atom> into / ``>>> Done.``, with 'checking ...' configure
        probes in between.

        What this must NOT do is settle the row. ``>>> Done.`` is the end of the EBUILD;
        portage still has to merge the package into the ROOT, and only the scheduler's
        ``>>> Completed (N of M)`` on the shared stream states that that happened. So the
        highest step reachable from here is ``install`` (85%) — a package whose fate the
        stream never states stays visibly unsettled, which is the honest outcome."""
        stripped = strip_ansi(raw).rstrip("\r\n").lstrip()
        for rx, step in ((_TEST_RE, STEP_TEST), (_SRC_INSTALL_RE, STEP_INSTALL),
                         (_SRC_INSTALLED_RE, STEP_INSTALL)):
            m = rx.match(stripped)
            if m:
                # A foreign atom inside this atom's log would be nonsense; ignoring it is
                # cheaper than reasoning about it and cannot mis-credit anything.
                if m.group(1) == pkg.atom:
                    self._advance(pkg, step)
                return
        for prefix, step in _ANON_LADDER:
            if stripped.startswith(prefix):
                self._advance(pkg, step)
                return
        self._apply_tool(pkg, stripped)

    def _tail_package(self, pkg: PackageProgress) -> bool:
        """Read the NEW bytes of ``pkg``'s own portage build log and apply them; True if
        the row moved. Never re-reads and never reads unboundedly — see :meth:`poll`.

        The four states a live log can be in, all real and all handled without an
        exception escaping to the caller's timer:

        * not created yet — portage writes it when the ebuild starts, which is AFTER the
          ``Emerging`` line that put the atom in flight. Returns False; retried next poll.
        * grown — the normal case: seek to the remembered offset, read a capped chunk.
        * REPLACED — a different inode at the same path, or a newer ``:<STAMP>.log``
          alongside it (portage writes one file per merge attempt). Start over at 0 rather
          than seeking into the middle of a different file.
        * truncated — size below our offset. Same reset.
        """
        t = self._tails.get(pkg.atom)
        if t is None:
            t = _Tail()
            self._tails[pkg.atom] = t
        if not t.path:
            t.path = find_package_log(self.log_root, pkg.atom)
            if not t.path:
                return False                      # not written yet — normal, retry later
        try:
            st = os.stat(t.path)
        except OSError:
            # rotated away / sysroot unmounted mid-build: forget it and re-resolve.
            t.path, t.offset, t.ident, t.residue = "", 0, None, b""
            return False
        ident = (st.st_dev, st.st_ino)
        if t.ident is None:
            t.ident = ident
        elif ident != t.ident:
            t.ident, t.offset, t.residue = ident, 0, b""
        if st.st_size < t.offset:
            t.offset, t.residue = 0, b""
        if st.st_size == t.offset:
            # Nothing new. While we have never read a byte, the path is still only a GUESS
            # (the newest log matching the atom at the moment the row appeared), so keep
            # re-resolving it — a merge that started a second later writes a later STAMP,
            # i.e. a different filename that no inode check would catch. Once bytes have
            # been read the path is settled and this glob stops happening, which is what
            # keeps the steady state a single stat per atom per tick.
            if t.offset == 0:
                newest = find_package_log(self.log_root, pkg.atom)
                if newest and newest != t.path:
                    t.path, t.ident, t.residue = newest, None, b""
            return False
        with open(t.path, "rb") as fh:
            fh.seek(t.offset)
            chunk = fh.read(min(st.st_size - t.offset, POLL_CHUNK_BYTES))
        if not chunk:
            return False
        t.offset += len(chunk)
        # The split is done on BYTES, and the residue is bytes, so a chunk boundary that
        # lands in the middle of a multi-byte UTF-8 character rejoins it on the next pass
        # instead of decoding two halves into two replacement chars. (A boundary can never
        # split a character across a LINE, because b"\n" is never part of one.) Decoding is
        # per complete line, errors="replace" — a genuinely mis-encoded byte in a build
        # tool's output must degrade one cell, never raise into the caller's timer.
        data = t.residue + chunk
        t.residue = b""
        if data.endswith(b"\n"):
            raw_lines = data.split(b"\n")[:-1]
        else:
            parts = data.split(b"\n")
            t.residue = parts.pop()
            raw_lines = parts
            if len(t.residue) > POLL_CHUNK_BYTES:
                # a single line longer than the whole per-poll budget would otherwise grow
                # the residue without bound and never be parsed anyway. Drop it; the row
                # keeps its last honest reading.
                t.residue = b""
        # The change probe covers every field the GUI paints (its own per-atom fingerprint
        # is (step, percent, failed, len(use_flags), len(header), tool_info)) — resolving
        # the elog header is a visible move even when no ladder step fired.
        before = (pkg.step, pkg.percent, pkg.tool_info, len(pkg.use_flags), len(pkg.header))
        for rb in raw_lines:
            self._feed_pkg_line(pkg, rb.decode("utf-8", "replace"))
        # The header/USE lookup is normally driven by _advance's step transitions; a poll
        # that produced no transition is also the moment a just-created log first has its
        # elog header flushed, so give it one more chance here.
        self._resolve_log(pkg)
        return (pkg.step, pkg.percent, pkg.tool_info,
                len(pkg.use_flags), len(pkg.header)) != before

    def _row(self, atom: str) -> PackageProgress:
        """Get-or-create the row for ``atom``. Keyed on the atom ALONE, so the twice-merged
        gettext (lines 96 and 17744-ish in the real log, two portage logs on disk) is ONE
        row rather than a duplicate — and its ``group`` stays whatever it was first seen
        under, so rows never jump columns mid-build."""
        pkg = self._pkgs.get(atom)
        if pkg is None:
            cat, name, ver = split_atom(atom)
            pkg = PackageProgress(atom=atom, category=cat, name=name, version=ver,
                                  group=self._group)
            self._pkgs[atom] = pkg
            self._resolve_log(pkg)
        return pkg

    def _advance(self, pkg: PackageProgress, step: str) -> None:
        """Move a row FORWARD along the ladder only. A failed row is terminal: portage's
        ``--keep-going`` resume drops the failed atom from the remaining list rather than
        retrying it (line 2794913 resumes at ``(1 of 245)`` with libreoffice gone), so a
        later line must never be able to turn a red row green."""
        if pkg.failed:
            return
        was = _STEP_INDEX[pkg.step]
        now = _STEP_INDEX[step]
        if now > was:
            pkg.step = step
            self._resolve_log(pkg)
        # percent is monotonic independently of the step guard, so an out-of-order line
        # can never claw a bar back.
        pct = max(pkg.percent, STEP_PERCENT[step])
        # Invariant: 100 means DONE and nothing else. Cheap belt-and-braces on top of the
        # ladder table, so a future table edit can't quietly make a running bar full.
        pkg.percent = pct if pkg.step == STEP_DONE else min(pct, 99)

    def _fail(self, pkg: PackageProgress) -> None:
        """Red, terminal, and NOT done — percent freezes wherever the ladder had got to,
        because that is genuinely how far the package got before it died."""
        pkg.failed = True
        pkg.step = STEP_FAILED
        pkg.percent = min(pkg.percent, 99)

    def _resolve_log(self, pkg: PackageProgress) -> None:
        """Best-effort log + USE lookup. Only ever runs with a ``log_root`` configured, and
        settles permanently once a row has both — portage writes the elog header (and hence
        the USE line) at the top of the file the moment the ebuild starts, so a row that
        has advanced past ``queued`` will normally resolve on its first attempt; retrying
        on each subsequent step transition covers the binary-merge case, where the log
        appears only around the Installing line.

        It walks the candidates NEWEST-FIRST rather than just taking the newest, because on
        real data the newest is sometimes not the BUILD log at all: replaying the whole
        session-20260725 transcript, ``net-firewall/iptables-1.8.13``,
        ``dev-build/cmake-4.3.4`` and ``app-crypt/pinentry-1.3.2-r1`` each ended up
        pointing at a 45-657 byte pkg_prerm/postrm trailer (``* Unsetting ebtables symlinks
        before removal``, no elog header at all) written AFTER their real 236 KB / 1.2 MB
        build log. Replaying all 3,162,640 lines proves the difference exactly: taking the
        plain newest resolves USE for 849/852 packages and misses precisely those three,
        leaving three GUI rows whose "open the log" would have shown the operator a stub;
        walking newest-first for a candidate that actually carries the header resolves
        852/852 and points every row at its real build log. It still falls back to the
        plain newest when NO candidate has a header (a package that genuinely only ever got
        unmerged) rather than reporting no log at all."""
        if not self.log_root or pkg.atom in self._resolved:
            return
        if pkg.atom in self._explicit_log:
            # portage named the file itself (the "Failed to emerge" path) — that beats any
            # guess of ours, so only the header facts are still open.
            pkg.header = parse_header(pkg.log_path)
            pkg.use_flags = tuple(pkg.header.get("USE", "").split())
            if pkg.header:
                self._resolved.add(pkg.atom)
            return
        for cand in find_package_logs(self.log_root, pkg.atom):
            header = parse_header(cand)
            if header:
                pkg.log_path, pkg.header = cand, header
                # a header without a USE row settles with () — the file IS the build log
                # and portage simply printed no flags, which is not a retryable state.
                pkg.use_flags = tuple(header.get("USE", "").split())
                self._resolved.add(pkg.atom)
                return
            if not pkg.log_path:
                pkg.log_path = cand        # newest, per find_package_log's contract
        # NOT added to _resolved: a log that exists but has not been flushed past its elog
        # header yet must stay retryable on the row's next step transition.
