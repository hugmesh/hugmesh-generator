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
(``EMERGE_JOBS=1``, build-x86-host-stage4.sh:4357, fed to portage via EMERGE_DEFAULT_OPTS
at :4383; ``--jobs="${CROSS_EMERGE_JOBS:-1}"``, build-rpi5-stage4.sh:3719) so the atom-less
lines are unambiguous there, but the four ARM cross builders all pass ``--jobs="${JOBS}"``
(build-frite-stage4.sh:1404, build-jetson-stage4.sh:1408, build-orangepi5-stage4.sh:1431,
build-orangepi-zero2-stage4.sh:1500) — under those, several packages ARE in flight and
their atom-less lines interleave. Rather than mis-crediting them we simply drop them: those
builds still advance every bar through the atom-named markers (test / install /
completed / failed), just at coarser granularity. Guessing would be the dishonest option.

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
"""
from __future__ import annotations

import glob
import os
import re
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

# ">>> Emerging (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo" and its binpkg twin
# ">>> Emerging binary (436 of 805) sys-apps/groff-1.23.0-r2::gentoo" (line 2526970), plus
# ">>> Installing (1 of 258) ...". The ``::repo`` suffix is optional — portage omits it for
# some sources and we never need it.
#
# CROSS-BUILD TAIL (``_ROOT_TAIL``). When ROOT is not ``/`` portage appends the target
# root to these lines — ``Emerging … for /out/wl-pki.rpi5/sysroot/`` and
# ``Installing … to /out/wl-pki.rpi5/sysroot/``. Every ARM builder emerges into
# ``${BUILD_ROOT}/sysroot``, so the tail is present on precisely the packages that land
# in the IMAGE, while host BDEPEND tools (merged to /) have no tail. An earlier ``\s*$``
# anchor therefore dropped the target half of every cross build: in the operator's real
# build-pki.rpi5.log 222 of 283 ``Emerging`` lines carried the tail, so the Studio tree
# listed only the 61 host tools and silently omitted all 222 image packages. The tail is
# matched but deliberately NOT captured — the row is keyed by atom, and a build already
# knows its own sysroot.
_ROOT_TAIL = r"(?:\s+(?:for|to)\s+\S+)?"
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

    # ── public API ───────────────────────────────────────────────────────────────────
    def group(self) -> str:
        """Current emerge group, or :data:`GROUP_UNKNOWN` before the first group banner."""
        return self._group

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
        exactly the pre-failure total."""
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
            self._counter[self._group] = (n, tot)
            if verb == "Emerging":
                self._inflight.pop(atom, None)   # re-insert so order == recency
                self._inflight[atom] = pkg
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
            self._counter[self._group] = (pkg.index, pkg.total)
            self._inflight.pop(pkg.atom, None)
            self._advance(pkg, STEP_DONE)
            return pkg

        # 5. ">>> Failed to emerge <atom>, Log file:"
        m = _FAILED_RE.match(stripped)
        if m:
            pkg = self._row(m.group(1))
            self._inflight.pop(pkg.atom, None)
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
        #    discipline the whole feed loop lives by.
        if len(self._inflight) == 1:
            first = stripped[:1]
            if first in _TOOL_FIRST_CHARS:
                pkg = next(iter(self._inflight.values()))
                info = stripped.rstrip()    # the real "make -j4 " (L2783) trails a space
                m = _NINJA_RE.match(stripped) if first == "[" else None
                if m:
                    pkg.tool_info = info
                    # The ONE sanctioned tool-derived percent: ninja's N/M is a real
                    # completed/total counter, so while the ladder says we are in compile
                    # it interpolates across the compile band — and ONLY up to one point
                    # short of the test step's floor, because "ninja printed [M/M]" is
                    # not the same fact as ">>> Source compiled." (post-build script
                    # steps still run). max() keeps it monotonic across the counter
                    # RESTARTS that really happen: multibuild ebuilds (gettext builds
                    # once per ABI) and the install phase re-invoke ninja from [1/...].
                    n, mtot = int(m.group(1)), int(m.group(2))
                    if pkg.step == STEP_COMPILE and 0 < n <= mtot:
                        lo = STEP_PERCENT[STEP_COMPILE]
                        hi = STEP_PERCENT[STEP_TEST] - 1
                        pkg.percent = max(pkg.percent, lo + ((hi - lo) * n) // mtot)
                    return pkg
                if ((first == "m" and _MAKE_RE.match(stripped))
                        or (first == "-" and _CMAKE_RE.match(stripped))
                        or (first in "na" and _NPM_RE.match(stripped))
                        or (first == "C" and _CARGO_RE.match(stripped))):
                    pkg.tool_info = info
                    return pkg
                if first == "c" and _CONFIGURE_RE.match(stripped):
                    # collapsed so the GUI cell says which tool is talking — bare
                    # "checking for a race-free mkdir -p..." reads like our own status.
                    pkg.tool_info = "configure: " + info
                    return pkg
        return None

    # ── internals ────────────────────────────────────────────────────────────────────
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
