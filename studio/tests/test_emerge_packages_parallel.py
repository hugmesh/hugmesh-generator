"""PARALLEL emerge (``--jobs``) — the scheduler status line, ROOT-targeted counter lines,
honest settlement under concurrency, and the incremental per-package log tail that gives
several packages a LIVE step/percent/tool line at the same time.

Evidence base. Two real operator transcripts, both on this machine and both read-only here:

* ``out/sessions/20260729-065121-ce11e0/build-pki.rpi5.log`` — 22025 lines, an rpi5 arm64
  pki image cross-built 2026-07-29. PARALLEL scheduler output: 1752 ``>>> Jobs:`` lines,
  283 ``>>> Emerging`` lines (266 distinct atoms), 222 of the Emerging lines carrying a
  ``for <ROOT>/`` tail. A 304-line verbatim excerpt is COMMITTED next to this file as
  ``data/emerge_jobs_rpi5_excerpt.log`` (its own header records the provenance and the
  counted tallies) so the shape assertions below run in CI, on a machine that has never
  seen the operator's out/ tree.
* ``out/sessions/20260729-213352-5f9798/build-pki.x86.log`` — 19222 lines, the SERIAL x86
  pki build. Zero ``>>> Jobs:`` lines, 9 ``>>> Emerging``, 2 ``==> Emerge group:`` banners.
  It is the regression anchor: the serial path was already proven working and this change
  must not move it by one row.

Both full logs are asserted under skipif — they are the operator's build output, not repo
fixtures, so a CI checkout skips those two tests and still runs everything else.

The per-package log shapes fed to :meth:`poll` are taken from a real one the operator's own
build wrote: ``wl-pki.x86/sysroot/var/log/portage/build/net-libs:nghttp2-1.68.0:20260730-\
043807.log`` (613 lines) — elog header, then the full ebuild ladder, then ``>>> Done.``,
with ``checking ...`` configure probes in between. The ``>>> Done.``/``Completed (N of M)``
asymmetry is the one that matters and has its own test.
"""
import os
import subprocess

import pytest

from hugmesh_studio.core import emerge_packages as ep

_HERE = os.path.dirname(os.path.abspath(__file__))
_GENERATOR_DIR = os.path.dirname(os.path.dirname(_HERE))

# the committed excerpt (always present) …
EXCERPT = os.path.join(_HERE, "data", "emerge_jobs_rpi5_excerpt.log")

# … and the two full operator transcripts, present only where a real build ran.
SESSIONS_ENV = "HUGMESH_STUDIO_OPERATOR_SESSIONS"


def _session_dirs() -> list[str]:
    """Every directory that might hold the operator's build transcripts.

    A builder writes them to ``<repo>/out/sessions/<stamp>/`` (worklist.py's session dir),
    so the in-tree path is the normal answer. But this repo is developed in ``git
    worktree``s, and a worktree's ``out/`` is empty — the transcripts belong to the MAIN
    checkout — so the shared git dir is asked for the main worktree's root too. That is
    what lets these tests actually RUN during development instead of silently skipping in
    every worktree. An explicit env var wins over both, for replaying a copied session.
    """
    dirs = []
    env = os.environ.get(SESSIONS_ENV)
    if env:
        dirs.append(env)
    dirs.append(os.path.join(_GENERATOR_DIR, "out", "sessions"))
    try:
        res = subprocess.run(
            ["git", "-C", _GENERATOR_DIR, "rev-parse", "--path-format=absolute",
             "--git-common-dir"], capture_output=True, text=True, timeout=15, check=False)
        if res.returncode == 0 and res.stdout.strip():
            main_root = os.path.dirname(res.stdout.strip())
            dirs.append(os.path.join(main_root, "out", "sessions"))
    except (OSError, subprocess.SubprocessError):
        pass
    return dirs


def _operator_log(session: str, name: str) -> str:
    for d in _session_dirs():
        cand = os.path.join(d, session, name)
        if os.path.isfile(cand):
            return cand
    return ""


RPI5_LOG = _operator_log("20260729-065121-ce11e0", "build-pki.rpi5.log")
X86_LOG = _operator_log("20260729-213352-5f9798", "build-pki.x86.log")
# A SECOND, older real cross build of the same role/platform. Both transcripts above were
# deleted from the operator's out/ while this branch was in review (the session dirs
# survive, the .log files do not), which would have left the ROOT-tail claim resting on a
# replay that only ever skips. This one is still on the box and is pinned for exactly that
# reason — a different build of the same shape is a stronger check than one that cannot run.
RPI5_OLD_LOG = _operator_log("20260719-103006-a775c2", "build-pki.rpi5.log")

_GREEN, _RESET = "\x1b[32m", "\x1b[39;49;00m"


def _elog(text: str) -> str:
    return f"{_GREEN} * {_RESET}{text}"


# The nghttp2 elog header, verbatim from the real per-package log named in the module
# docstring (its first five lines).
_NGHTTP2_HEADER = "\n".join([
    _elog("Package:    net-libs/nghttp2-1.68.0:0/1.14"),
    _elog("Repository: gentoo"),
    _elog("Maintainer: voyageur@gentoo.org"),
    _elog("USE:        abi_x86_64 amd64 elibc_glibc kernel_linux"),
    _elog("FEATURES:   nostrip preserve-libs"),
]) + "\n"


def _replay(path, parser=None):
    p = parser or ep.EmergePackageParser()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            p.feed(line)
    return p


# ── 1. the ">>> Jobs:" line: every shape the real transcript prints ────────────────────
def test_jobs_line_shapes_from_the_real_transcript():
    """The three clause shapes that make up all 1752 Jobs lines of the rpi5 build
    (903 clause-less + 566 running + 283 merge wait), byte-for-byte including portage's
    right-alignment run before ``Load avg:``."""
    p = ep.EmergePackageParser()
    s = p.scheduler()
    assert (s.seen, s.revision) == (False, 0)     # nothing claimed before portage speaks

    # L142 of the real log
    p.feed(">>> Jobs: 0 of 149 complete, 1 running                                  "
           "Load avg: 6.71, 6.83, 5.95\n")
    assert (s.seen, s.complete, s.total, s.running, s.merge_wait, s.failed) == \
        (True, 0, 149, 1, 0, 0)
    assert s.load_avg == (6.71, 6.83, 5.95)
    assert s.clauses == {"running": 1}

    # L146 — the merge-wait clause
    p.feed(">>> Jobs: 0 of 149 complete, 1 merge wait                               "
           "Load avg: 6.73, 6.83, 5.96\n")
    assert (s.running, s.merge_wait) == (0, 1)
    assert s.clauses == {"merge wait": 1}

    # L148 — clause-less
    p.feed(">>> Jobs: 1 of 149 complete                                             "
           "Load avg: 6.73, 6.83, 5.96\n")
    assert (s.complete, s.total, s.running, s.merge_wait) == (1, 149, 0, 0)
    assert s.clauses == {}


def test_jobs_zero_of_zero_is_a_real_reading_not_an_unknown():
    """``>>> Jobs: 0 of 0 complete`` (L89, and 20x in the whole file) is portage saying an
    emerge invocation had nothing to do. ``seen`` is what distinguishes it from "portage
    has not spoken", so the total is reported verbatim rather than papered over."""
    p = ep.EmergePackageParser()
    p.feed(">>> Jobs: 0 of 0 complete                                               "
           "Load avg: 7.02, 6.89, 5.96\n")
    s = p.scheduler()
    assert (s.seen, s.complete, s.total) == (True, 0, 0)


def test_jobs_load_avg_single_decimal_fields_parse():
    """L2308 of the real log: ``Load avg: 10.1, 28.1, 19.9`` — portage drops a decimal once
    the load goes double-digit, so the field is not fixed-width."""
    p = ep.EmergePackageParser()
    p.feed(">>> Jobs: 0 of 0 complete                                               "
           "Load avg: 10.1, 28.1, 19.9\n")
    assert p.scheduler().load_avg == (10.1, 28.1, 19.9)


def test_unknown_clause_is_recorded_verbatim_not_dropped_or_guessed():
    """The clause list is walked generically, so a label this transcript never printed is
    kept in ``clauses`` for the GUI/reader to see. ``failed`` is read through that SAME
    path — portage has such a counter but the real log never exercised it, so it is
    honestly derived rather than pattern-matched from memory."""
    p = ep.EmergePackageParser()
    p.feed(">>> Jobs: 5 of 20 complete, 2 running, 1 merge wait, 3 failed, 4 sideways   "
           "Load avg: 1.0, 2.0, 3.0\n")
    s = p.scheduler()
    assert (s.running, s.merge_wait, s.failed) == (2, 1, 3)
    assert s.clauses == {"running": 2, "merge wait": 1, "failed": 3, "sideways": 4}


def test_a_malformed_jobs_line_keeps_the_previous_reading():
    """A half-parsed status line is worse than a slightly stale one."""
    p = ep.EmergePackageParser()
    p.feed(">>> Jobs: 7 of 149 complete, 2 running     Load avg: 1.0, 2.0, 3.0\n")
    rev = p.scheduler().revision
    p.feed(">>> Jobs: the scheduler is feeling poetic today\n")
    s = p.scheduler()
    assert (s.complete, s.total, s.running, s.revision) == (7, 149, 2, rev)


def test_jobs_line_moves_no_package_and_bumps_the_revision_only_on_change():
    """feed() returns None for a Jobs line (it names no package), and the revision — the
    GUI's repaint gate — only moves when a figure actually changed. 1752 of the real
    build's lines are these, most of them repeats."""
    p = ep.EmergePackageParser()
    line = (">>> Jobs: 3 of 149 complete, 1 running                                  "
            "Load avg: 5.65, 6.17, 5.94\n")
    assert p.feed(line) is None
    rev = p.scheduler().revision
    assert rev > 0
    for _ in range(50):
        assert p.feed(line) is None
    assert p.scheduler().revision == rev


def test_running_greater_than_one_latches_parallel_before_any_atom_is_named():
    """portage counts a job as running BEFORE the ``Emerging`` line that names its atom, so
    its own count is the earliest parallelism proof available."""
    p = ep.EmergePackageParser()
    assert p.parallel() is False
    p.feed(">>> Jobs: 0 of 149 complete, 4 running    Load avg: 6.71, 6.83, 5.95\n")
    assert p.parallel() is True


# ── 2. ROOT-targeted counter lines (the 223 packages that used to be invisible) ─────────
@pytest.mark.parametrize("emerging,installing,completed", [
    # L137/L141/L143 of the real rpi5 log — the ROOT-targeted majority (222 of 283)
    (">>> Emerging (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo for /out/wl-pki.rpi5/sysroot/",
     ">>> Installing (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo to /out/wl-pki.rpi5/sysroot/",
     ">>> Completed (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo to /out/wl-pki.rpi5/sysroot/"),
    # L149/L152/L154 — a BDEPEND merged into "/", no tail (61 of 283)
    (">>> Emerging (2 of 149) dev-lang/python-exec-conf-2.4.6::gentoo",
     ">>> Installing (2 of 149) dev-lang/python-exec-conf-2.4.6::gentoo",
     ">>> Completed (2 of 149) dev-lang/python-exec-conf-2.4.6::gentoo"),
])
def test_root_targeted_and_plain_counter_lines_both_track(emerging, installing, completed):
    p = ep.EmergePackageParser()
    pkg = p.feed(emerging + "\n")
    assert pkg is not None, "the ROOT tail must not hide the atom"
    assert "::" not in pkg.atom and " " not in pkg.atom
    assert p.scheduler().inflight == (pkg.atom,)
    p.feed(installing + "\n")
    assert pkg.step == ep.STEP_INSTALL
    p.feed(completed + "\n")
    assert (pkg.step, pkg.percent, p.scheduler().inflight) == (ep.STEP_DONE, 100, ())


def test_root_tail_tolerates_a_space_in_the_workdir_path():
    """The keyword (``for``/``to``) is the gate, not the shape of the path — an operator's
    --workdir may contain a space."""
    p = ep.EmergePackageParser()
    pkg = p.feed(">>> Emerging (1 of 2) dev-libs/xxhash-0.8.3-r2::gentoo "
                 "for /out/my builds/wl-pki.rpi5/sysroot/\n")
    assert pkg is not None and pkg.atom == "dev-libs/xxhash-0.8.3-r2"


def test_completed_installing_is_still_not_the_terminal_marker():
    """The ROOT tail must not have loosened ``_COMPLETED_RE`` into also eating
    ">>> Completed installing <atom> into <image>", which is only the end of src_install."""
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 2) net-libs/nghttp2-1.68.0::gentoo\n")
    pkg = p.feed(">>> Completed installing net-libs/nghttp2-1.68.0 into "
                 "/var/tmp/portage/net-libs/nghttp2-1.68.0/image\n")
    assert pkg is not None
    assert (pkg.step, pkg.percent) == (ep.STEP_INSTALL, 85)
    assert p.scheduler().inflight == ("net-libs/nghttp2-1.68.0",)   # still open


# ── 3. the committed excerpt of the real parallel transcript ────────────────────────────
def test_committed_excerpt_replays_with_the_counted_tallies():
    """The excerpt's own header states its tallies; this asserts the parser agrees with
    them, so a bad edit to either the fixture or the regexes fails here."""
    with open(EXCERPT, encoding="utf-8", errors="replace") as fh:
        raw = fh.readlines()
    body = [ln for ln in raw if not ln.startswith("#")]
    assert sum(1 for ln in body if ln.startswith(">>> Jobs:")) == 169
    assert sum(1 for ln in body if ln.startswith(">>> Emerging")) == 28
    assert sum(1 for ln in body if ln.startswith(">>> Completed (")) == 28
    assert sum(1 for ln in body if ln.startswith(">>> Emerging") and " for /" in ln) == 20

    p = _replay(EXCERPT)
    pkgs = p.packages()
    assert len(pkgs) == 28
    assert all(pk.step == ep.STEP_DONE and pk.percent == 100 for pk in pkgs)
    # the excerpt ends on ">>> Jobs: 28 of 149 complete" with nothing running
    s = p.scheduler()
    assert (s.seen, s.complete, s.total, s.running, s.merge_wait) == (True, 28, 149, 0, 0)
    assert s.inflight == ()
    # this excerpt is from a --jobs=1 stretch: never two atoms at once, never running > 1,
    # so it must NOT be misreported as parallel.
    assert p.parallel() is False


def test_excerpt_provenance_header_is_inert_to_the_parser():
    """The fixture carries its provenance in "#" lines; those must move nothing."""
    with open(EXCERPT, encoding="utf-8", errors="replace") as fh:
        header = [ln for ln in fh.readlines() if ln.startswith("#")]
    assert header, "the fixture must keep its provenance header"
    p = ep.EmergePackageParser()
    for ln in header:
        assert p.feed(ln) is None
    assert p.packages() == [] and p.scheduler().seen is False


# ── 4. honest settlement under concurrency ─────────────────────────────────────────────
def test_out_of_order_completion_does_not_inflate_the_group_total():
    """Under --jobs packages finish out of order, so ``Completed (10 of 149)`` can arrive
    after ``Emerging (13 of 149)``. Taking that 10 as the frontier would project
    completed + inflight + (149 - 10) and count the packages in between twice."""
    p = ep.EmergePackageParser()
    for i in range(1, 5):
        p.feed(f">>> Emerging ({i} of 149) cat/p{i}-1.0::gentoo for /out/sysroot/\n")
    # the LAST one finishes first
    p.feed(">>> Completed (4 of 149) cat/p4-1.0::gentoo to /out/sysroot/\n")
    p.feed(">>> Completed (1 of 149) cat/p1-1.0::gentoo to /out/sysroot/\n")
    done, total = p.totals()
    assert (done, total) == (2, 149)


def test_counter_restart_still_replaces_the_frontier_when_the_total_changes():
    """The high-water rule is scoped to one M: a --keep-going resume (M 805 -> 245) or a
    new emerge invocation within a group must still reset the frontier, which is what the
    documented 560 + 1 + 244 = 805 reconstruction depends on."""
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (600 of 805) cat/big-1.0::gentoo\n")
    p.feed(">>> Completed (600 of 805) cat/big-1.0::gentoo\n")
    assert p.totals() == (1, 206)          # 1 done + the (805 - 600) still queued behind it
    # a NEW invocation with a different M must be able to move the frontier back to 1 —
    # the high-water rule is scoped to one M, not to the group's whole lifetime
    p.feed(">>> Emerging (1 of 3) cat/small-1.0::gentoo\n")
    assert p._counter[""] == (1, 3)
    assert p.totals()[1] == 206            # the group's total hwm itself never drops
    assert p.scheduler().inflight == ("cat/small-1.0",)


def test_an_unresolved_in_flight_package_is_never_fabricated_to_done():
    """The core honesty rule. A package the stream opened and never closed — the build was
    killed, the log was truncated, the operator hit Stop — stays visibly unsettled. Nothing
    on any path (including a poll that read the whole ebuild log) may settle it."""
    p = ep.EmergePackageParser()
    a = p.feed(">>> Emerging (1 of 3) cat/aaa-1.0::gentoo for /out/sysroot/\n")
    b = p.feed(">>> Emerging (2 of 3) cat/bbb-1.0::gentoo for /out/sysroot/\n")
    p.feed(">>> Completed (2 of 3) cat/bbb-1.0::gentoo to /out/sysroot/\n")
    # b settled honestly; a never did
    assert (b.step, b.percent, b.failed) == (ep.STEP_DONE, 100, False)
    assert a.step != ep.STEP_DONE and a.percent < 100 and a.failed is False
    assert p.scheduler().inflight == ("cat/aaa-1.0",)
    assert p.totals()[0] == 1              # completed counts only what portage completed


def test_the_package_log_can_never_settle_a_row(tmp_path):
    """``>>> Done.`` in the package's OWN log is the end of the EBUILD; portage still has to
    merge into the ROOT, and only the scheduler's ``Completed (N of M)`` says that happened.
    So a poll that consumes the ENTIRE real ladder tops out at install/85, not done/100."""
    root = tmp_path / "build"
    root.mkdir()
    p = ep.EmergePackageParser(str(root))
    pkg = p.feed(">>> Emerging (1 of 2) net-libs/nghttp2-1.68.0::gentoo for /out/sysroot/\n")
    p.feed(">>> Emerging (2 of 2) net-libs/nghttp3-1.9.0::gentoo for /out/sysroot/\n")
    assert p.parallel() is True
    (root / "net-libs:nghttp2-1.68.0:20260730-043807.log").write_text(
        _NGHTTP2_HEADER + "\n".join([
            ">>> Unpacking source...",
            ">>> Source unpacked in /var/tmp/portage/net-libs/nghttp2-1.68.0/work",
            ">>> Preparing source in /var/tmp/portage/.../nghttp2-1.68.0 ...",
            ">>> Source prepared.",
            ">>> Configuring source in /var/tmp/portage/.../nghttp2-1.68.0 ...",
            ">>> Source configured.",
            ">>> Compiling source in /var/tmp/portage/.../nghttp2-1.68.0 ...",
            ">>> Source compiled.",
            ">>> Test phase [disabled because of RESTRICT=test]: net-libs/nghttp2-1.68.0",
            ">>> Install net-libs/nghttp2-1.68.0 into /var/tmp/portage/.../image",
            ">>> Completed installing net-libs/nghttp2-1.68.0 into /var/tmp/portage/.../image",
            ">>> Done.",
        ]) + "\n", encoding="utf-8")
    assert p.poll(now=1.0) == [pkg]
    assert (pkg.step, pkg.percent) == (ep.STEP_INSTALL, 85)
    assert pkg.step != ep.STEP_DONE and pkg.percent < 100
    # and the elog header came along for the ride
    assert pkg.header["Package"] == "net-libs/nghttp2-1.68.0:0/1.14"
    assert pkg.use_flags == ("abi_x86_64", "amd64", "elibc_glibc", "kernel_linux")


# ── 5. the synthetic parallel fixture: SEVERAL rows moving at once ──────────────────────
def _para_parser(tmp_path, n=3):
    """3 concurrent packages, ROOT-targeted exactly as a cross builder prints them, with an
    empty log_root ready for their per-package logs."""
    root = tmp_path / "build"
    root.mkdir()
    p = ep.EmergePackageParser(str(root))
    p.feed("==> Emerge group: system\n")
    p.feed(f">>> Jobs: 0 of {n} complete, {n} running     Load avg: 7.9, 7.4, 6.1\n")
    atoms = []
    for i in range(1, n + 1):
        line = (f">>> Emerging ({i} of {n}) dev-libs/pkg{i}-{i}.0::gentoo "
                f"for /out/wl-pki.rpi5/sysroot/\n")
        atoms.append(p.feed(line).atom)
    return p, root, atoms


def _write(root, atom, body, stamp="20260730-043807"):
    cat, pf = atom.split("/", 1)
    (root / f"{cat}:{pf}:{stamp}.log").write_text(body, encoding="utf-8")


def _append(root, atom, body, stamp="20260730-043807"):
    cat, pf = atom.split("/", 1)
    with open(root / f"{cat}:{pf}:{stamp}.log", "a", encoding="utf-8") as fh:
        fh.write(body)


def test_three_concurrent_packages_show_live_moving_percent_across_polls(tmp_path):
    """The feature the operator asked for: several rows live at once, each with real status
    read from its OWN portage log, all advancing across successive poll() calls."""
    p, root, atoms = _para_parser(tmp_path)
    assert p.parallel() is True
    assert p.scheduler().inflight == tuple(atoms)
    assert [pk.step for pk in p.inflight()] == [ep.STEP_QUEUED] * 3
    assert [pk.percent for pk in p.inflight()] == [0, 0, 0]

    # tick 1: portage has created all three logs and unpacked
    for a in atoms:
        _write(root, a, _NGHTTP2_HEADER + ">>> Unpacking source...\n")
    assert {pk.atom for pk in p.poll(now=1.0)} == set(atoms)
    assert [pk.step for pk in p.inflight()] == [ep.STEP_UNPACK] * 3
    assert [pk.percent for pk in p.inflight()] == [2, 2, 2]

    # tick 2: all three advance AGAIN, and to DIFFERENT places — the point of the feature
    _append(root, atoms[0], ">>> Configuring source in /var/tmp/portage/w ...\n"
                            "checking for a BSD-compatible install... /usr/bin/install\n")
    _append(root, atoms[1], ">>> Source prepared.\n")
    _append(root, atoms[2], ">>> Compiling source in /var/tmp/portage/w ...\n"
                            "[120/240] cc -o foo.o foo.c\n")
    assert {pk.atom for pk in p.poll(now=2.0)} == set(atoms)
    rows = {pk.atom: pk for pk in p.inflight()}
    assert rows[atoms[0]].step == ep.STEP_CONFIGURE
    assert rows[atoms[1]].step == ep.STEP_PREPARE
    assert rows[atoms[2]].step == ep.STEP_COMPILE
    # three distinct live percents at the same instant
    live = [rows[a].percent for a in atoms]
    assert live == [10, 5, 47], live
    assert len(set(live)) == 3
    # and each row carries ITS OWN tool line — the attribution feed() has to drop
    assert rows[atoms[0]].tool_info.startswith("configure: checking for a BSD-compatible")
    assert rows[atoms[2]].tool_info == "[120/240] cc -o foo.o foo.c"
    assert rows[atoms[1]].tool_info == ""

    # tick 3: only ONE log grew -> only that row is reported moved
    _append(root, atoms[2], "[240/240] cc -o bar.o bar.c\n")
    assert [pk.atom for pk in p.poll(now=3.0)] == [atoms[2]]
    assert rows[atoms[2]].percent == 79           # one point short of the test floor (80)
    assert rows[atoms[0]].percent == 10           # untouched

    # and settlement is still the STREAM's job, one atom at a time
    p.feed(f">>> Completed (2 of 3) {atoms[1]}::gentoo to /out/wl-pki.rpi5/sysroot/\n")
    assert (rows[atoms[1]].step, rows[atoms[1]].percent) == (ep.STEP_DONE, 100)
    assert p.scheduler().inflight == (atoms[0], atoms[2])
    assert rows[atoms[0]].percent < 100 and rows[atoms[2]].percent < 100


def test_poll_uses_the_same_ladder_as_the_serial_stream(tmp_path):
    """The two modes read the SAME step table, so a package whose ladder arrives on the
    shared stream and one whose identical ladder arrives via its own log land on the same
    step and the same percent. Drift between them is the failure this pins."""
    ladder = [">>> Unpacking source...", ">>> Source unpacked in /w",
              ">>> Preparing source in /w ...", ">>> Source prepared.",
              ">>> Configuring source in /w ...", ">>> Source configured.",
              ">>> Compiling source in /w ..."]
    serial = ep.EmergePackageParser()
    sp = serial.feed(">>> Emerging (1 of 1) dev-libs/pkg1-1.0::gentoo\n")
    for ln in ladder:
        serial.feed(ln + "\n")

    p, root, atoms = _para_parser(tmp_path)
    _write(root, atoms[0], "\n".join(ladder) + "\n")
    p.poll(now=1.0)
    par = {pk.atom: pk for pk in p.inflight()}[atoms[0]]
    assert (par.step, par.percent) == (sp.step, sp.percent) == (ep.STEP_COMPILE, 15)


# ── 6. poll() preconditions and bounds ─────────────────────────────────────────────────
def test_poll_is_a_no_op_without_a_log_root(tmp_path):
    """No log_root keeps the parser the pure stream parser its class docstring promises —
    poll() must not go looking for files it was never pointed at."""
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 2) cat/a-1.0::gentoo\n")
    p.feed(">>> Emerging (2 of 2) cat/b-1.0::gentoo\n")
    assert p.parallel() is True
    assert p.poll(now=1.0) == []


def test_poll_is_a_no_op_on_a_serial_stream(tmp_path):
    """A serial build's ladder and tool lines are already in the stream and already
    credited; polling it would duplicate work on a path proven to work. This is what makes
    the change a no-op for x86/rpi5 at their default --jobs 1."""
    root = tmp_path / "build"
    root.mkdir()
    p = ep.EmergePackageParser(str(root))
    pkg = p.feed(">>> Emerging (1 of 9) net-libs/nghttp2-1.68.0::gentoo\n")
    _write(root, pkg.atom, _NGHTTP2_HEADER + ">>> Compiling source in /w ...\n")
    assert p.parallel() is False
    assert p.poll(now=1.0) == []
    assert pkg.step == ep.STEP_QUEUED       # the log on disk was deliberately not read


def test_poll_rate_limits_to_one_filesystem_pass_per_interval(tmp_path):
    p, root, atoms = _para_parser(tmp_path)
    for a in atoms:
        _write(root, a, ">>> Unpacking source...\n")
    assert len(p.poll(now=10.0)) == 3
    _append(root, atoms[0], ">>> Source configured.\n")
    # inside the interval: not even a stat
    assert p.poll(now=10.0 + ep.POLL_MIN_INTERVAL / 2) == []
    assert p.poll(now=10.0 + ep.POLL_MIN_INTERVAL) != []


def test_poll_handles_a_log_that_does_not_exist_yet_then_appears(tmp_path):
    """portage writes the log when the ebuild STARTS, which is after the Emerging line put
    the atom in flight — so "not there yet" is the normal first state, not an error."""
    p, root, atoms = _para_parser(tmp_path)
    assert p.poll(now=1.0) == []
    _write(root, atoms[1], ">>> Unpacking source...\n")
    assert [pk.atom for pk in p.poll(now=2.0)] == [atoms[1]]


def test_poll_survives_a_log_replaced_by_a_different_file(tmp_path):
    """A new inode at the same path (a re-created sysroot, a re-run merge) must restart the
    read at 0 instead of seeking into the middle of a different file."""
    p, root, atoms = _para_parser(tmp_path)
    _write(root, atoms[0], ">>> Unpacking source...\n>>> Source unpacked in /w\n")
    p.poll(now=1.0)
    cat, pf = atoms[0].split("/", 1)
    target = root / f"{cat}:{pf}:20260730-043807.log"
    replacement = root / "replacement.tmp"
    replacement.write_text(">>> Compiling source in /w ...\n", encoding="utf-8")
    replacement.replace(target)             # same path, new inode
    moved = p.poll(now=2.0)
    assert [pk.atom for pk in moved] == [atoms[0]]
    assert {pk.atom: pk for pk in p.inflight()}[atoms[0]].step == ep.STEP_COMPILE


def test_poll_survives_a_truncated_log(tmp_path):
    p, root, atoms = _para_parser(tmp_path)
    _write(root, atoms[0], ">>> Unpacking source...\n" * 20)
    p.poll(now=1.0)
    _write(root, atoms[0], ">>> Configuring source in /w ...\n")   # now SHORTER
    assert [pk.atom for pk in p.poll(now=2.0)] == [atoms[0]]
    assert {pk.atom: pk for pk in p.inflight()}[atoms[0]].step == ep.STEP_CONFIGURE


def test_poll_survives_a_log_that_vanishes(tmp_path):
    """The log lives inside a chroot the build owns; it can go away under us. One
    unreadable file must not stop the other rows from moving, and nothing may raise into
    the caller's timer."""
    p, root, atoms = _para_parser(tmp_path)
    for a in atoms:
        _write(root, a, ">>> Unpacking source...\n")
    p.poll(now=1.0)
    cat, pf = atoms[0].split("/", 1)
    (root / f"{cat}:{pf}:20260730-043807.log").unlink()
    _append(root, atoms[2], ">>> Source configured.\n")
    assert [pk.atom for pk in p.poll(now=2.0)] == [atoms[2]]


def test_poll_never_re_reads_and_never_splits_a_line(tmp_path):
    """A half-written trailing line (the writer's buffer, or our own byte cap) is held as
    residue and completed on the next pass — parsed exactly once, never twice."""
    p, root, atoms = _para_parser(tmp_path)
    cat, pf = atoms[0].split("/", 1)
    path = root / f"{cat}:{pf}:20260730-043807.log"
    path.write_text(">>> Unpacking source...\n>>> Configuring so", encoding="utf-8")
    p.poll(now=1.0)
    row = {pk.atom: pk for pk in p.inflight()}[atoms[0]]
    assert row.step == ep.STEP_UNPACK           # the partial line credited nothing
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("urce in /w ...\n")
    assert [pk.atom for pk in p.poll(now=2.0)] == [atoms[0]]
    assert row.step == ep.STEP_CONFIGURE


def test_poll_caps_the_bytes_read_per_atom_per_pass(tmp_path):
    """A compile log grows by megabytes; the follow catches up over ticks instead of
    stalling the GUI's timer for a second. Nothing is skipped — the offset only advances by
    what was consumed."""
    p, root, atoms = _para_parser(tmp_path)
    filler = "checking for something irrelevant... yes\n"
    body = (">>> Unpacking source...\n"
            + filler * (3 * ep.POLL_CHUNK_BYTES // len(filler))
            + ">>> Compiling source in /w ...\n")
    assert len(body) > 2 * ep.POLL_CHUNK_BYTES
    _write(root, atoms[0], body)
    row = {pk.atom: pk for pk in p.inflight()}[atoms[0]]
    p.poll(now=1.0)
    assert row.step == ep.STEP_UNPACK           # the compile marker is beyond the cap
    for i in range(2, 12):
        p.poll(now=float(i))
    assert row.step == ep.STEP_COMPILE          # caught up over the following ticks


def test_poll_rejoins_a_multibyte_character_split_by_the_byte_cap(tmp_path):
    """The residue is BYTES, not text. A chunk boundary landing inside a multi-byte UTF-8
    character (portage's own output is full of them — quotes, arrows, maintainer names)
    would otherwise decode into two replacement chars and garble the operator's tool cell.
    The file below is built so the cap falls exactly between the two bytes of 'é'."""
    p, root, atoms = _para_parser(tmp_path)
    marker = "checking for café support... yes\n"
    # "checking for caf" is 16 bytes, so the 17th byte of the marker is é's first byte:
    # put the marker's start at CAP-17 and the cap splits é.
    head = ">>> Compiling source in /w ...\n"
    pad = ep.POLL_CHUNK_BYTES - 17 - len(head)
    assert pad > 1
    body = head + "z" * (pad - 1) + "\n" + marker
    assert len(body.encode("utf-8")) > ep.POLL_CHUNK_BYTES
    assert body.encode("utf-8")[ep.POLL_CHUNK_BYTES - 1:ep.POLL_CHUNK_BYTES + 1] == \
        "é".encode()
    _write(root, atoms[0], body)
    row = {pk.atom: pk for pk in p.inflight()}[atoms[0]]
    p.poll(now=1.0)
    assert row.step == ep.STEP_COMPILE
    p.poll(now=2.0)
    assert row.tool_info == "configure: checking for café support... yes"
    assert "�" not in row.tool_info


def test_poll_only_touches_in_flight_atoms(tmp_path):
    """A settled row is not re-read: its log may still be growing (portage's own postrm
    trailers) but its fate is already stated."""
    p, root, atoms = _para_parser(tmp_path)
    for a in atoms:
        _write(root, a, ">>> Unpacking source...\n")
    p.poll(now=1.0)
    p.feed(f">>> Completed (1 of 3) {atoms[0]}::gentoo to /out/wl-pki.rpi5/sysroot/\n")
    _append(root, atoms[0], ">>> Compiling source in /w ...\n")
    _append(root, atoms[1], ">>> Compiling source in /w ...\n")
    assert [pk.atom for pk in p.poll(now=2.0)] == [atoms[1]]


def test_poll_without_an_explicit_now_uses_the_clock(tmp_path):
    """The GUI passes its tick's monotonic value; a bare poll() must still work."""
    p, root, atoms = _para_parser(tmp_path)
    _write(root, atoms[0], ">>> Unpacking source...\n")
    assert [pk.atom for pk in p.poll()] == [atoms[0]]


# ── 7. full-log replay of BOTH real operator transcripts ───────────────────────────────
@pytest.mark.skipif(not RPI5_LOG,
                    reason=f"operator rpi5 transcript not on this machine (looked in "
                           f"{_session_dirs()}; override with ${SESSIONS_ENV})")
def test_real_parallel_rpi5_transcript_replays_every_package():
    """The gap this change closes, measured on the real thing. 222 of the transcript's 283
    ``Emerging`` lines carry a ``for <ROOT>/`` tail that the ``$``-anchored regexes rejected
    outright, so the pre-change parser produced 60 package rows out of the build's 266
    distinct atoms — 206 rows the operator's GUI simply never had.

    Ground truth for the 266 was computed independently of the parser:
    ``grep -o '>>> Emerging ([0-9]* of [0-9]*) [^ ]*' … | awk '{print $NF}' | sort -u``.

    This is also the single home of that replay: #483 landed the same assertion on main in
    test_emerge_packages.py, and the two were reconciled here (see the note at that site).
    Its ``percent == 100`` assertion is carried below."""
    p = _replay(RPI5_LOG)
    pkgs = p.packages()
    assert len(pkgs) == 266, f"tracked {len(pkgs)} of 266 real packages"
    assert sum(1 for pk in pkgs if pk.step == ep.STEP_DONE) == 266
    assert all(pk.percent == 100 for pk in pkgs), "every Completed row must reach 100%"
    assert not [pk for pk in pkgs if pk.failed]
    s = p.scheduler()
    assert s.seen is True
    assert s.inflight == ()               # every package the stream opened, it also closed
    assert len(s.load_avg) == 3
    # this build ran --jobs=1 (build-rpi5-stage4.sh:3754 default), so despite 1752 Jobs
    # lines it must NOT be reported as parallel — and poll() must keep doing nothing on it.
    assert p.parallel() is False
    assert p.poll(now=1.0) == []


@pytest.mark.skipif(not RPI5_OLD_LOG,
                    reason=f"the older operator rpi5 transcript is not on this machine "
                           f"(looked in {_session_dirs()}; override with ${SESSIONS_ENV})")
def test_a_second_real_cross_build_transcript_tracks_every_package():
    """The same claim on a DIFFERENT real cross build, so it does not rest on one file.

    Independent ground truth over out/sessions/20260719-103006-a775c2/build-pki.rpi5.log
    (21919 lines), computed with grep/awk and not with this parser::

        grep -c '^>>> Emerging'                                    -> 279
        grep -cE '^>>> Emerging .* for /'                          -> 219   (the tailed ones)
        grep -oE '^>>> Emerging (binary )?\\([0-9]+ of [0-9]+\\) [^ ]+' \\
            | awk '{print $NF}' | sed 's/::.*$//' | sort -u | wc -l -> 263   (distinct atoms)

    The merge-base parser (80d9a49, ``$``-anchored) tracks 60 of those 263. This one tracks
    all 263, every row at 100%. This build predates the ``==> Emerge group:`` banner, so
    every row is correctly ungrouped rather than guessed into a group — which is also why
    it is a useful second sample.
    """
    p = _replay(RPI5_OLD_LOG)
    pkgs = p.packages()
    assert len(pkgs) == 263, f"tracked {len(pkgs)} of 263 real packages"
    assert sum(1 for pk in pkgs if pk.step == ep.STEP_DONE) == 263
    assert all(pk.percent == 100 for pk in pkgs)
    assert not [pk for pk in pkgs if pk.failed]
    assert {pk.group for pk in pkgs} == {ep.GROUP_UNKNOWN}
    s = p.scheduler()
    assert s.seen is True and s.inflight == ()
    # 1727 ">>> Jobs:" lines, but this build also ran --jobs=1: never two atoms at once.
    assert p.parallel() is False


@pytest.mark.skipif(not X86_LOG,
                    reason=f"operator x86 transcript not on this machine (looked in "
                           f"{_session_dirs()}; override with ${SESSIONS_ENV})")
def test_real_serial_x86_transcript_is_unchanged_to_the_row():
    """The regression anchor. The serial per-package path was already proven working
    end-to-end; these are its exact pre-change figures, asserted so this feature cannot
    have moved it."""
    p = _replay(X86_LOG)
    pkgs = p.packages()
    assert len(pkgs) == 9
    assert sum(1 for pk in pkgs if pk.step == ep.STEP_DONE) == 8
    assert sorted({pk.group for pk in pkgs}) == ["system", "world"]
    assert p.group() == "world"
    assert p.totals() == (7, 49)
    # zero ">>> Jobs:" lines in this transcript at all
    assert p.scheduler().seen is False
    assert p.parallel() is False
