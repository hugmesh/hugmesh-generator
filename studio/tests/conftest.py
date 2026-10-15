"""Make the hugmesh_studio package importable for the studio test suite.

These tests target the pure-Python core (config / keyzip / validate) and do NOT
need PySide6, so they run in plain CI without the GUI toolkit installed.
"""
import contextlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

import pytest

# studio/ is the package root (contains hugmesh_studio/).
_STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _STUDIO_ROOT not in sys.path:
    sys.path.insert(0, _STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _isolate_studio_state_dir(monkeypatch, tmp_path):
    """Point EVERY test at a throwaway Studio state dir.

    Without this, any test that reaches a Studio state path with no override set
    resolves the default — the operator's live ``~/.hugmesh/studio`` — and writes
    there for real. That is not theoretical: ``test_local_mesh_bringup.py`` drives a
    real ``LocalMeshDialog`` and clicks its real ``preflight_btn``, and the resulting
    "Checking host readiness — FAILED" run log landed in the operator's actual log
    directory, interleaved with genuine GUI runs and indistinguishable from them.

    Only 40 of the suite's 171 files set the override themselves; this one autouse
    fixture covers the other 131 and, unlike a per-file setenv, cannot be forgotten
    by the next test that is added. Tests that need a specific state dir still set
    ``$HUGMESH_STUDIO_STATE_DIR`` in their own body — theirs runs later and wins.

    Paired with the guard in ``core/state_paths.state_dir()``, which refuses the
    home fallback outright while pytest is running: if this fixture is ever removed
    or bypassed, the suite fails loudly instead of quietly polluting a real home.
    """
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio-state"))
    # (monkeypatch restores the session-wide default pytest_configure sets, not an
    # unset variable — see the note there for why that difference is relied on.)


@pytest.fixture(autouse=True)
def _host_independent_build_defaults(monkeypatch):
    """Make the suite's host-aware build defaults (core/host_resources) deterministic
    on ANY test host: pin the jobs default to the historical 8 via its env override,
    clear any ambient memory-cap override, and pin BOTH meminfo override points — the
    per-process snapshot (_meminfo_cached: jobs default + cap) AND the per-call
    dispatch-time read (_meminfo_fresh: low-memory warnings) — to a canonical
    healthy 32 GiB reading (cap auto-derives, warnings stay quiet). Tests that
    exercise the formulas pass explicit env/meminfo (which win) or re-monkeypatch
    the relevant override point themselves."""
    from hugmesh_studio.core import host_resources
    monkeypatch.setenv(host_resources.JOBS_ENV, "8")
    monkeypatch.delenv(host_resources.MEMORY_ENV, raising=False)
    healthy = {"MemTotal": 32 * host_resources.GIB,
               "MemAvailable": 24 * host_resources.GIB,
               "SwapTotal": 4 * host_resources.GIB,
               "SwapFree": 4 * host_resources.GIB}
    monkeypatch.setattr(host_resources, "_meminfo_cached", lambda: dict(healthy))
    monkeypatch.setattr(host_resources, "_meminfo_fresh", lambda: dict(healthy))


def _live_qapplication():
    """The process's QApplication, or None — without ever raising, and without
    importing Qt into a run that has not already imported it.

    Deliberately paranoid about ``QtWidgets.QApplication`` not being the class: tests
    legitimately ``monkeypatch.setattr(QtWidgets, "QApplication", lambda *a: qapp)``
    to stop a page building a second one (``tests/test_pages_build.py`` does), and a
    ``tryfirst`` teardown hook runs BEFORE monkeypatch's undo. A bare
    ``QApplication.instance()`` there raised ``AttributeError: 'function' object has
    no attribute 'instance'``, which aborted teardown before the undo, leaving the
    patch in place for the REST OF THE SESSION — the whole file then failed at
    ``pytest_sessionfinish``. Measured 2026-09-04 on tests/test_pages_build.py, which
    is green on origin/main.
    """
    qtw = sys.modules.get("PyQt6.QtWidgets")
    if qtw is None:                              # no toolkit in this run
        return None
    try:
        return qtw.QApplication.instance()
    except Exception:                            # not the class right now
        return None


def _drain_probe_threads(deadline_s: float = 60.0) -> None:
    """Wait out every probe QThread the Studio still has in flight, ONCE, at session end.

    ``gui/pages/_widgets.own_probe`` un-parents every probe and holds it in a module
    registry, so a page dropped mid-probe no longer takes the process down (see that
    docstring). What no registry can cover is the very LAST owner: the QApplication is
    destroyed at interpreter exit — taking ``BuildSupervisor`` and any worker it has
    adopted with it — and a thread still running THEN hits the same ``QThread:
    Destroyed while thread is still running`` qFatal. Measured on 2026-09-04 with the
    un-parent in place and this drain removed, ``test_local_mesh.py`` ran all 34 tests
    green and then aborted the process at exit.

    So it drains BOTH registries: ``own_probe``'s in-flight probes and the supervisor's
    adopted build workers (``_running_supervised_workers``).

    It deliberately does NOT go hunting for threads OUTSIDE those two. A version that
    also enumerated live QThreads — by ``gc.get_objects()``, by walking the Qt object
    tree from the QApplication, and by both at once, run per-iteration and run once
    after the loop with no ``processEvents()`` at all — was written and thrown away.
    Every variant broke ``tests/test_shell.py``, 3 of 3 runs each: merely enumerating
    objects at that moment changes when a queued ``BuildActionsWindow.destroyed``
    reaches its lambda, and the ``TypeError`` that lambda then raises inside a Qt slot
    aborts PyQt6. It bought one suite (``test_pages_fields_asks.py``, 4 of 4 instead of
    2 of 3) at the cost of another, deterministically, so it is not here. That suite's
    residual abort — after all 87 of its tests PASS, and against aborting at test 15 of
    87 on origin/main — is left standing and written up in the PR.

    So this runs ONCE, from ``pytest_sessionfinish``, and never per test. Per-test it
    also worked, and cost ~25 s a test on any suite whose probes genuinely shell out
    (``test_pages_e2e_run.py`` went from 12 s to over 500 s) — for no benefit, because
    between tests a live probe is now harmless.

    It asserts nothing: it waits on every running probe thread and pumps the event
    loop until things are QUIESCENT, since a delivered ``result`` can start the next
    probe (``tests/test_localmesh_page_entry_offthread.py::_settle`` documents the same
    re-entrancy) and ``isRunning()`` is still False in the instant between ``start()``
    and the OS thread running. Bounded: past the deadline it returns anyway and the
    process is no worse off than before.

    Qt is touched ONLY if the run already imported it — the core-only CI lane must
    stay free of a PyQt import.
    """
    qtw = sys.modules.get("PyQt6.QtWidgets")
    qtc = sys.modules.get("PyQt6.QtCore")
    if qtw is None or qtc is None:
        return
    app = _live_qapplication()
    if app is None:
        return
    end = time.monotonic() + deadline_s
    idle = 0
    # QUIESCENCE, not one clear pass. Two things make a single check lie, and
    # tests/test_localmesh_page_entry_offthread.py::_settle documents both:
    # a delivered `result` can START the next probe (_on_mesh_state re-gates), and
    # isRunning() is still False in the instant between start() and the OS thread
    # actually running. So idle has to hold across several consecutive passes.
    while time.monotonic() < end and idle < 20:
        running = _running_probe_threads(qtw, qtc) + _running_supervised_workers()
        for t in running:
            try:
                t.wait(200)
            except RuntimeError:                # wrapper outlived its C++ object
                continue
        # processEvents ONLY. An earlier version also flushed DeferredDelete here, to
        # collect the finished threads' C++ objects — and that turned this drain into a
        # destroyer: `tests/test_pages_progress.py` deleteLater()s a page whose
        # _WorklistWorker (a QThread that does NOT go through own_probe) was still
        # running, and forcing that delete aborted a run that had passed all 50 tests.
        # The registry entry is cleared by the `finished` signal, which a plain
        # processEvents delivers, so nothing here needs to delete anything.
        app.processEvents()
        idle = 0 if (running or _running_probe_threads(qtw, qtc)
                     or _running_supervised_workers()) else idle + 1


def _running_probe_threads(qtw, qtc) -> list:
    """Every probe own_probe is still holding that has not finished.

    Asks ``own_probe``'s registry rather than walking the object tree: the threads are
    parented to nothing at all (that is the whole point of the re-parent), so there is
    no widget and no application whose ``children()`` would list them.
    """
    try:
        from hugmesh_studio.gui.pages import _widgets
    except Exception:                           # no toolkit in this run
        return []
    out = []
    for t in _widgets.in_flight_probes():
        try:
            if t.isRunning():
                out.append(t)
        except RuntimeError:                    # wrapper outlived its C++ object
            continue
    return out


def _running_supervised_workers() -> list:
    """Every build worker ``gui/build_supervisor`` has adopted and that is still running.

    A second registry, because the supervisor is a second OWNER: ``adopt()`` reparents
    the worker QThread onto the process-wide ``BuildSupervisor`` deliberately, so that
    no window's destruction can take a running build with it. Draining
    ``own_probe``'s registry alone would therefore miss any worker that reached the
    supervisor by a route other than ``hold_thread``.
    """
    try:
        from hugmesh_studio.gui import build_supervisor
    except Exception:                           # no toolkit in this run
        return []
    if build_supervisor._SUPERVISOR is None:    # never a build in this run
        return []
    out = []
    try:
        builds = list(build_supervisor._SUPERVISOR.running())
    except Exception:
        return []
    for b in builds:
        w = getattr(b, "worker", None)
        try:
            if w is not None and w.isRunning():
                out.append(w)
        except RuntimeError:                    # wrapper outlived its C++ object
            continue
    return out


#: The QApplication, held for the whole session once some test has made one. A LIST
#: rather than a single slot so a suite that deliberately builds a second application
#: cannot silently drop the first (see pytest_runtest_teardown below).
_PINNED_APPS: list = []


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_teardown(item, nextitem):
    """Two things a GUI test must not leave behind, done BEFORE any fixture unwinds.

    Both are about the same object graph, which ``gui/build_supervisor`` builds on
    purpose::

        QApplication  ->  BuildSupervisor  ->  _WorklistWorker (a running QThread)

    ``adopt()`` reparents a build worker off its page and onto the process-wide
    supervisor precisely so that "no window's destruction can take it". In the real
    Studio that graph is torn down exactly once, at exit, and ``aboutToQuit`` has run
    ``cancel_all()`` first. Under pytest neither half holds, and each failing half
    aborts the interpreter — which loses every test after it while REPORTING nothing,
    because the process never gets far enough to write a failure.

    (1) PIN THE APPLICATION. Almost every GUI suite here gets its application from a
        FUNCTION-scoped fixture that returns ``QApplication.instance() or
        QApplication([...])`` and keeps no reference of its own, so between tests its
        refcount reaches zero. Qt destroys a QObject's children from inside
        ``~QObject``, so that collection walks straight down the graph above and meets
        a running QThread: ``QThread: Destroyed while thread
        'progress._WorklistWorker' is still running``, a qFatal. Pinning is also the
        HONEST lifetime — a process has one QApplication, and it lives until the
        process ends. Qt is touched only through ``sys.modules``, so a session that
        never builds an application (the core-only CI lane) pins nothing and imports
        nothing.

    (2) STOP THE BUILDS. With the application pinned the worker is no longer destroyed
        — it just keeps RUNNING, into the next test and past the fixtures its slots
        depend on. Measured: ``tests/test_pages_progress.py`` then reached the end and
        aborted anyway, this time on ``RuntimeError: refusing to use the operator's
        live state dir`` raised inside a Qt slot, because ``_isolate_studio_state_dir``
        had already been undone under the still-running build. So a build must not
        outlive the test that started it, which is the same rule ``aboutToQuit ->
        cancel_all()`` enforces at a real exit. This hook is ``tryfirst`` for that
        reason: it runs before ``teardown_exact``, so the state dir, the fake HOME and
        every monkeypatch are still in place while ``on_cancelled`` writes its record.

    Cost is only what it stops: a session with no supervisor has nothing to do here,
    and the builds that exist in this suite are driven by a faked ``Popen``.

    Measured 2026-09-04 on ``tests/test_pages_progress.py``: ``origin/main`` aborted
    3 of 3 runs (at test 20 of 50); with (1) alone, 2 of 3; with both, 5 of 5 green.
    """
    try:
        app = _live_qapplication()
        if app is not None and not any(a is app for a in _PINNED_APPS):
            _PINNED_APPS.append(app)
        _stop_supervised_builds()
    except Exception:
        # NEVER raise from here. This hook is `tryfirst`, so it runs before
        # `teardown_exact` — an exception escaping it skips every fixture finalizer
        # for this test, monkeypatch's undo included, and the patches then leak into
        # the rest of the session. Whatever this hook could not do is not worth that.
        pass


def _stop_supervised_builds() -> None:
    """Cancel and join every build the supervisor still has live, then DELIVER what
    they already queued. Never raises: this runs during teardown, where an escaping
    exception would mask the test's own verdict, and the supervisor's own slots are
    written the same way.

    The pump is not tidiness. A worker emits ``entry_done`` from its own thread, so the
    signal sits in the main thread's queue until something runs the event loop — and
    the page's slot for it writes a session record through ``core.build_sessions``.
    Joining the thread does not deliver that queued call; the next ``processEvents()``
    does, wherever that happens to be. Measured: with only the cancel, the queued
    ``entry_done`` was delivered by ``_drain_probe_threads`` at SESSION finish, long
    after ``_isolate_studio_state_dir`` had been undone, and ``state_paths.state_dir()``
    then refused the un-redirected path — a ``RuntimeError`` raised inside a Qt slot,
    which under PyQt6 aborts the interpreter. Pumping here delivers it while the state
    dir, the fake HOME and every monkeypatch are still in place.
    """
    try:
        from hugmesh_studio.gui import build_supervisor
    except Exception:                            # no toolkit in this run
        return
    sup = build_supervisor._SUPERVISOR
    if sup is None:                              # no build ever started
        return
    try:
        cancelled = sup.cancel_all(wait_ms=10000)
    except Exception:
        return
    # Pump ONLY when a live build was actually stopped. Running the event loop is not
    # free of consequences: it delivers every OTHER queued call too, and a suite that
    # started no build can be holding one that is only safe to never deliver —
    # ``tests/test_shell.py`` queues ``BuildActionsWindow.destroyed`` onto a lambda
    # whose keyword-only capture is gone by then, and a ``TypeError`` raised inside a
    # Qt slot aborts PyQt6 (measured 3 of 3 runs; that file is green when this pump is
    # skipped). Nothing here needs those: the queued call this exists for is the
    # ``entry_done`` of a build we just cancelled.
    if not cancelled:
        return
    app = _live_qapplication()
    if app is None:
        return
    for _ in range(50):
        try:
            app.processEvents()
        except Exception:
            return


@pytest.fixture(autouse=True)
def _inert_mesh_monitor(request, monkeypatch):
    """Make the local-mesh page's running-mesh monitor DO NOTHING by default.

    ``LocalMeshPage`` re-reads BOTH mesh lanes off-thread (``core.mesh_monitor.
    snapshot``: ``kind get clusters``, one ``kubectl get … -A -o json``, ``docker
    inspect``, ``docker compose ps``) whenever its mesh-state probe answers or its
    monitor section is open. Ten test files build that page for unrelated reasons
    (verb attribution, the egress gate, log coalescing, the e2e tree, theming) and
    stub only the override points THEY know about; without this fixture each of them would
    shell the operator's real kind cluster and docker daemon through the monitor,
    and a QThread still in that read when the page is torn down aborts the process
    (``QThread: Destroyed while thread is still running``) — measured on two suites
    before this fixture existed.

    The stub answers instantly with BOTH lanes unestablished (never "no mesh": the
    page's tri-state rule) and records nothing. A module that wants the real
    function — the monitor's own core and GUI suites — opts out with
    ``pytestmark = pytest.mark.real_mesh_monitor``; the GUI suite then stubs
    ``snapshot`` itself and the core suite calls it with scripted nodes.
    """
    if request.node.get_closest_marker("real_mesh_monitor"):
        return
    from hugmesh_studio.core import mesh_monitor
    why = "not read under pytest (tests/conftest.py: _inert_mesh_monitor)"

    def _inert(generator_dir, node, **kw):
        return mesh_monitor.MonitorSnapshot(
            taken_at="00:00:00",
            compose=mesh_monitor.LaneState(None, detail=why),
            kind=mesh_monitor.LaneState(None, detail=why))
    monkeypatch.setattr(mesh_monitor, "snapshot", _inert)


@pytest.fixture(autouse=True)
def _inert_entry_probes(request, monkeypatch):
    """Make the local-mesh page's PAGE-ENTRY probes non-shelling by default.

    The sibling of ``_inert_mesh_monitor`` above, for the two blocking calls that
    run on entering the page rather than on opening a section:

    * ``_StatusProbe`` -> ``LocalStackNode.status()`` / ``MeshNode.status()`` — a
      ``docker compose ps`` (``subprocess.run(..., timeout=30)``).
    * ``_E2EGateProbe`` -> ``LocalStackNode.e2e_ready()`` — up to three of those
      plus a 5 s urlopen of Casdoor (its own docstring puts the ceiling at ~95 s).

    Two things go wrong without this, and both were measured on 2026-09-04 (and
    identically on the pre-lane baseline 98bc3ad4, so neither is new work's fault):

    (a) A test that builds the page and drops it goes on to build the NEXT one, and
        the first page is collected mid-``subprocess.run`` — ``QThread: Destroyed
        while thread is still running``, a Qt qFatal, which aborts the whole file.
        ``test_local_mesh.py``, ``test_local_mesh_bringup.py`` and
        ``test_local_mesh_stages.py`` each died that way, losing every test after
        the fifth, eleventh and nineteenth respectively.
    (b) Until then those probes were shelling the OPERATOR'S REAL docker daemon on
        every page construction in the suite — the same non-hermeticity
        ``_inert_mesh_monitor`` and ``_isolate_studio_state_dir`` exist to close.

    The stubs answer INSTANTLY and honestly: not running, with a detail that names
    this fixture, and an e2e gate whose single blocker says the same. A test that
    wants the real functions opts out with
    ``pytestmark = pytest.mark.real_stack_probes``; a test that wants a SPECIFIC
    answer keeps monkeypatching the node itself — a per-instance attribute, and a
    ``monkeypatch.setattr`` in the test body, both run after this and both win.
    """
    if request.node.get_closest_marker("real_stack_probes"):
        return
    from hugmesh_studio.core import mesh_node
    from hugmesh_studio.core.local_stack_node import LocalStackNode, StackStatus
    why = "not probed under pytest (tests/conftest.py: _inert_entry_probes)"
    monkeypatch.setattr(LocalStackNode, "status",
                        lambda self: StackStatus(False, why), raising=True)
    monkeypatch.setattr(LocalStackNode, "e2e_ready",
                        lambda self, environment="docker": [why], raising=True)
    monkeypatch.setattr(mesh_node.MeshNode, "status",
                        lambda self: mesh_node.MeshStatus(False, why), raising=True)


# ─────────────────────────────────────────────────────────────────────────────
# NEVER ELEVATE: a spy on the real subprocess.Popen that fails any test which starts
# sudo / pkexec / doas / su — the control that proves this guard sees real cases, for the 2026-09-04 hang.
#
# What happened: tests/test_pages_fields_asks.py walked the REAL wizard onto the
# ProgressPage, which dispatches the committed worklist ON ARRIVAL — through the real
# WorklistDriver -> BuildDriver -> `sudo -A bash ./build-x86-host-stage4.sh` with the
# Qt askpass helper as SUDO_ASKPASS. Under QT_QPA_PLATFORM=offscreen on a desktop
# (DISPLAY set) the helper popped an INVISIBLE dialog and blocked forever; the test
# itself PASSED (it only checked the page type), its worker thread died with the
# interpreter, and the root-owned sudo was orphaned. 60 of them were found hung, some
# two days old, each pinning a 15-58 MB Qt process. No assertion anywhere could see it,
# which is why the control sits at the one boundary every spawn crosses.
#
# Three pieces, each relied on:
#   (a) pytest_configure replaces subprocess.Popen with a SUBCLASS — isinstance checks
#       and run/call/check_output keep working (they all construct the module-global
#       `Popen`) — that raises ElevationAttempted BEFORE anything is spawned;
#   (b) an autouse fixture ERRORS the test in whose window the attempt fell, at
#       teardown, so a raise the code under test swallowed (the ProgressPage worker
#       catches BaseException by design) still fails the test;
#   (c) pytest_sessionfinish fails the RUN with the list, in case (b) was bypassed
#       (an attempt from a thread that outlived its test lands here).
#
# There is deliberately NO opt-out. A test whose subject is a sudo argv fakes the
# process layer (monkeypatch.setattr(bd.subprocess, "Popen", ...)) — a fake spawns
# nothing, so this spy never sees it. The driver's own refusal
# (core/build_driver.guard_elevation: ElevationRefused under pytest or
# HUGMESH_STUDIO_NO_ELEVATION) is the first line of defence; this is the independent
# second, and it is the one that would have caught every hung launcher.
# ─────────────────────────────────────────────────────────────────────────────

#: argv[0] basenames that mean "become another user".
ELEVATION_PROGRAMS = frozenset({"sudo", "pkexec", "doas", "su", "run0"})
#: Wrappers looked THROUGH when locating the program (`env K=V sudo …`, `nice -n 5
#: sudo …`, `timeout 30 sudo …`). While inside one, tokens carrying `=`, starting with
#: `-`, or purely numeric (an optional s/m/h/d suffix) are the wrapper's own arguments.
_TRANSPARENT_WRAPPERS = frozenset({"env", "nice", "ionice", "stdbuf", "setsid", "nohup",
                                   "timeout", "chrt", "taskset"})
_WRAPPER_NUMERIC = re.compile(r"(?:[0-9]+[smhd]?|0[xX][0-9a-fA-F]+)")
#: Wrapper flags whose NEXT token is their argument (`env -u NAME`, `timeout -s SIG`,
#: `timeout -k DUR`, `taskset -c LIST`, `ionice -c CLASS`, `env -C DIR`). Without this
#: the bare argument ended the scan and `env -u GH_TOKEN sudo …` read as "not elevating"
#: (#360/#304). The `--flag=value` spelling already passes via the `=` rule.
_WRAPPER_ARG_FLAGS = frozenset({"-u", "--unset", "-C", "--chdir", "-s", "--signal",
                                "-k", "--kill-after", "-c", "--cpu-list", "-n",
                                "--adjustment", "-P", "--pid"})
#: A leading shell assignment (`VAR=1 sudo …`) when the string runs through a shell.
_SHELL_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# Known blind spots, by design (no in-tree caller spawns them; the driver's own
# guard_elevation still covers every in-tree argv): `cd /x && sudo …`, `bash -c '…sudo…'`
# / `sh -c`, and terminal-emulator wrappers (`konsole -e bash -c 'sudo …'`). A test that
# needs one of these must fake the process layer instead.

#: Every attempt, as (PYTEST_CURRENT_TEST or a placeholder, the leading argv tokens).
_ELEVATION_ATTEMPTS: list[tuple[str, str]] = []


class ElevationAttempted(RuntimeError):
    """A test tried to start an elevation program. Raised INSTEAD of spawning it."""


def _elevation_program(args, shell: bool) -> str | None:
    """The elevation program ``args`` would execute, or ``None``."""
    if isinstance(args, (str, bytes, os.PathLike)):
        text = os.fsdecode(args)
        if shell:
            try:
                tokens = shlex.split(text)
            except ValueError:
                tokens = text.split()
        else:
            tokens = [text]
    else:
        try:
            tokens = [os.fsdecode(t) for t in args]
        except TypeError:
            return None
    return _scan_tokens(tokens, shell)


def _scan_tokens(tokens: list[str], shell: bool = False) -> str | None:
    inside_wrapper = False
    skip_next = False
    for tok in tokens:
        if skip_next:                        # the argument of a wrapper flag
            skip_next = False
            continue
        name = os.path.basename(tok)
        if name in ELEVATION_PROGRAMS:
            return name
        if name in _TRANSPARENT_WRAPPERS:
            inside_wrapper = True
            continue
        if shell and not inside_wrapper and _SHELL_ASSIGNMENT.match(tok):
            continue                         # `VAR=1 sudo …` through a shell
        if inside_wrapper and ("=" in tok or tok.startswith("-")
                               or _WRAPPER_NUMERIC.fullmatch(tok)):
            skip_next = tok in _WRAPPER_ARG_FLAGS
            continue
        return None
    return None


def _leading_tokens(args) -> str:
    """The first few argv tokens for the report — never the whole line: a builder argv
    can carry --user-password."""
    try:
        if isinstance(args, (str, bytes, os.PathLike)):
            return os.fsdecode(args)[:120]
        return shlex.join(os.fsdecode(t) for t in list(args)[:5]) + " ..."
    except Exception:                                    # noqa: BLE001 - report only
        return repr(args)[:120]


def _install_never_elevate_popen() -> None:
    real = subprocess.Popen
    if getattr(real, "_hugmesh_never_elevate", False):   # already installed (re-entry)
        return

    class Popen(real):                                   # noqa: N801 - keeps the name
        _hugmesh_never_elevate = True

        def __init__(self, args, *a, **kw):
            # An iterator/generator argv is legal for the real Popen (_execute_child does
            # list(args)); scanning it here would exhaust it and the real Popen would get
            # an empty list (#375). Materialise ONCE, scan the list, hand the list on.
            if not isinstance(args, (str, bytes, os.PathLike)):
                try:
                    args = list(args)
                except TypeError:
                    pass
            prog = _elevation_program(args, bool(kw.get("shell", False)))
            if prog is None and kw.get("executable"):
                # `Popen(["harmless"], executable="/usr/bin/sudo")` runs sudo.
                prog = _scan_tokens([os.fsdecode(kw["executable"])])
            if prog is not None:
                where = os.environ.get("PYTEST_CURRENT_TEST", "<outside any test>")
                shown = _leading_tokens(args)
                _ELEVATION_ATTEMPTS.append((where, shown))
                if threading.current_thread() is not threading.main_thread():
                    # Off the main thread a raise is worse than useless: escaping a
                    # reimplemented QThread.run (progress._FlashWorker's shape) PyQt6
                    # qFatals the interpreter — rc 134, no pass/fail line, the autouse
                    # fixture and pytest_sessionfinish never run, every later test lost
                    # (#375). The attempt is already RECORDED, so _never_elevate fails the
                    # test at teardown; here the spawn is neutralised, not performed:
                    # a harmless interpreter no-op replaces the argv (shell/executable
                    # dropped so nothing of the original can run).
                    kw.pop("executable", None)
                    kw["shell"] = False
                    super().__init__([sys.executable, "-c", "pass"], *a, **kw)
                    return
                raise ElevationAttempted(
                    f"the test suite must never start {prog} (it would block on a "
                    f"password prompt nobody can answer and wedge a root-owned launcher "
                    f"forever): {shown} — stub the driver instead "
                    f"(tests/test_pages_progress.py FakeBuildDriver) or fake "
                    f"subprocess.Popen; tests/conftest.py NEVER ELEVATE")
            super().__init__(args, *a, **kw)

    Popen.__module__ = real.__module__
    Popen.__qualname__ = real.__qualname__
    subprocess.Popen = Popen


@pytest.fixture(autouse=True)
def _ambient_no_elevation_does_not_leak_in(monkeypatch):
    """Clear an AMBIENT ``HUGMESH_STUDIO_NO_ELEVATION`` for the duration of each test.

    Automation rightly exports it for a whole sweep so a stray launcher can never
    prompt for a password. But ``core/build_driver.elevation_refusal`` lets that
    variable beat the per-test opt-out, so every test whose subject is the sudo argv
    (it fakes subprocess and sets ``HUGMESH_STUDIO_ALLOW_ELEVATION_UNDER_TEST``) or
    the askpass env plumbing failed under such a sweep, yet passed when run alone
    (13 tests measured, among them test_build_driver_cancel's
    ``test_cancel_native_nonroot_wraps_kill_in_sudo``) — a flake that looks like test-order
    pollution and is really an inherited variable. This does NOT weaken the guards:
    the driver still refuses under pytest without the opt-out, the ``_never_elevate``
    spy below still errors any real sudo/pkexec spawn, and the tests that exercise
    the variable set it themselves with ``monkeypatch.setenv`` (theirs runs later
    and wins)."""
    monkeypatch.delenv("HUGMESH_STUDIO_NO_ELEVATION", raising=False)


@pytest.fixture(autouse=True)
def _never_elevate():
    """ERROR the test in whose window an elevation program was started (see NEVER
    ELEVATE above). Checked at teardown, so a raise the code under test swallowed
    still fails the test that caused it."""
    before = len(_ELEVATION_ATTEMPTS)
    yield
    fresh = _ELEVATION_ATTEMPTS[before:]
    if fresh:
        pytest.fail(
            "this test started (or tried to start) an elevation program — a real "
            "sudo/pkexec would have blocked on a password prompt forever:\n  "
            + "\n  ".join(shown for _where, shown in fresh)
            + "\nStub the build driver (tests/test_pages_progress.py FakeBuildDriver) "
            "or fake subprocess.Popen; there is no opt-out (tests/conftest.py NEVER "
            "ELEVATE).", pytrace=False)


@contextlib.contextmanager
def expect_elevation_attempt():
    """For the guard's OWN tests only (tests/test_never_elevate_guard.py): assert the
    body attempts exactly one elevation, and consume the record so the autouse
    fixture does not error the test that proved the guard works."""
    before = len(_ELEVATION_ATTEMPTS)
    with pytest.raises(ElevationAttempted):
        yield
    assert len(_ELEVATION_ATTEMPTS) == before + 1, "no attempt was recorded"
    del _ELEVATION_ATTEMPTS[before:]


def _report_elevation_attempts(session) -> None:
    if not _ELEVATION_ATTEMPTS:
        return
    session.exitstatus = 1
    print(f"\nELEVATION ATTEMPTED: the suite tried to start an elevation program "
          f"{len(_ELEVATION_ATTEMPTS)} time(s) (tests/conftest.py NEVER ELEVATE)",
          file=sys.stderr)
    for where, shown in _ELEVATION_ATTEMPTS:
        print(f"  {where}: {shown}", file=sys.stderr)


# ─────────────────────────────────────────────────────────────────────────────
# Suite-wide isolation from the operator's REAL state — and a guard that proves it
#
# The Studio's state accessors (core.instance.state_dir, core.build_sessions.
# sessions_dir, core.crashlog.crashes_dir, gui.tray.build_status_path) all fall back
# to ``~/.hugmesh/studio`` when ``$HUGMESH_STUDIO_STATE_DIR`` is unset. Of the 169 test
# files, 38 carried their OWN copy of the two-line isolation fixture (40 mention the
# variable at all); the other 131 did not, so running the suite wrote real GUI
# run-logs, session records and build-status.json into the operator's live
# ~/.hugmesh. (Signature: hundreds of
# ``<stamp>-Checking-host-readiness-FAILED.log`` files whose body is the TEST constant
# ``_M2_PROBLEM``, a string that exists nowhere in production code.)
#
# Three pieces, and each one is relied on:
#
#   (a) HOME moves in ``pytest_configure``, NOT in a fixture. Some test modules bind a
#       home-derived path at IMPORT time (tests/test_pages_identity.py's module-level
#       ``STAGING = ~/.hugmesh/keyzip``), and module import happens after
#       pytest_configure but before any fixture runs — a fixture is simply too late.
#       This also covers the state that has no env override at all: ~/.hugmesh/keyzip,
#       ~/.hugmesh/mesh-node, ~/.local/bin, ~/.local/share, ~/.config, ~/.cache.
#
#   (b) The autouse fixture is the DEFAULT, not an override. A module's own autouse
#       ``_isolated_state_dir`` is instantiated after this one (conftest autouse
#       fixtures run closest-to-root first), so the 38 existing copies still win and
#       keep working unchanged.
#
#   (c) The guard keys on stat identity, not on filenames, and reports REMOVED as well
#       as added — a leak that rewrites build-status.json in place, or that rmtree's
#       the keyzip staging dir, changes no filename set at all. It sets
#       ``session.exitstatus`` rather than failing a test, because the leaks we
#       actually saw came from GREEN tests and from Qt threads that outlived the test
#       that spawned them.
#
# Set HUGMESH_STUDIO_TEST_LEAK_GUARD=0 to disable the guard (e.g. on a shared box where
# a concurrent GUI session is legitimately writing to the same ~/.hugmesh).
# ─────────────────────────────────────────────────────────────────────────────

#: The operator's real home, captured at conftest IMPORT — before the redirect below.
_REAL_HOME = os.path.expanduser("~")
_REAL_HUGMESH = os.path.join(_REAL_HOME, ".hugmesh")

#: Published so a test can name the pre-redirect home without re-deriving it.
REAL_HOME_ENV = "HUGMESH_STUDIO_TEST_REAL_HOME"
LEAK_GUARD_ENV = "HUGMESH_STUDIO_TEST_LEAK_GUARD"
STATE_DIR_ENV = "HUGMESH_STUDIO_STATE_DIR"

_BASELINE: dict[str, tuple] = {}


def _inventory(root: str) -> dict[str, tuple]:
    """Every regular file under ``root``, keyed by a stat identity that changes on ANY
    write: mtime, ctime (which userspace cannot forge with os.utime) and size. Keying
    on the filename SET alone would miss an in-place rewrite of build-status.json."""
    out: dict[str, tuple] = {}
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                st = os.stat(path)
            except OSError:                      # raced away mid-walk — not our write
                continue
            out[path] = (st.st_mtime_ns, st.st_ctime_ns, st.st_size)
    return out


def _guard_enabled() -> bool:
    return os.environ.get(LEAK_GUARD_ENV, "1").strip().lower() not in ("0", "off", "false", "no")


def pytest_configure(config):
    """Install the never-elevate spy, redirect HOME (and the XDG dirs derived from it)
    to a throwaway tree, and take the before-picture the leak guard compares against."""
    _install_never_elevate_popen()
    if _guard_enabled():
        _BASELINE.update(_inventory(_REAL_HUGMESH))
    home = tempfile.mkdtemp(prefix="hugmesh-studio-tests-home-")
    os.makedirs(os.path.join(home, ".hugmesh"), exist_ok=True)
    config._hugmesh_fake_home = home
    os.environ[REAL_HOME_ENV] = _REAL_HOME
    os.environ["HOME"] = home
    os.environ["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
    os.environ["XDG_CACHE_HOME"] = os.path.join(home, ".cache")
    os.environ["XDG_DATA_HOME"] = os.path.join(home, ".local", "share")
    # A SESSION-WIDE state dir under the same throwaway home, so the variable is never
    # unset while pytest runs. `_isolate_studio_state_dir` gives each test its own and
    # monkeypatch restores THIS value afterwards — which matters, because Qt work can
    # outlive the test that queued it: a page's `entry_done` slot writes a session
    # record through core.build_sessions, and delivered from the session-end drain it
    # found no override, hit `state_paths.state_dir()`'s refusal of the home fallback,
    # and raised inside a Qt slot — a PyQt6 abort AFTER "87 passed" was printed
    # (tests/test_pages_fields_asks.py, 2026-09-04). It is NOT the home fallback path,
    # so the refusal still fires for anything that bypasses the override point entirely.
    os.makedirs(os.path.join(home, "studio-state-session"), exist_ok=True)
    os.environ[STATE_DIR_ENV] = os.path.join(home, "studio-state-session")


# NOTE. A second autouse fixture (_isolated_state_dir_default) arrived here from the
# sibling branch and did exactly what _isolate_studio_state_dir above already does:
# point HUGMESH_STUDIO_STATE_DIR at a tmp_path. Git merged the two without a
# conflict, because each side only ADDED — leaving two autouse fixtures racing to
# set one variable, with the winner decided by definition order rather than by
# anyone's intent. Collapsed to the one above, which is the one paired with
# state_paths.state_dir()'s refusal of the home fallback under pytest.
#
# The DETECTION half of that branch is kept in full below: it is not a duplicate of
# anything, and it is what catches a state accessor that never goes through the override point.

def pytest_sessionfinish(session, exitstatus):
    """Drain the Studio's in-flight probe threads, then fail the RUN (not a test) if
    anything under the operator's real ~/.hugmesh was created, deleted or modified
    while the suite ran.

    The drain comes FIRST and is not optional: a probe still running when the
    QApplication is destroyed aborts the interpreter, which would take this hook's
    own verdict down with it."""
    _drain_probe_threads()
    home = getattr(session.config, "_hugmesh_fake_home", "")
    try:
        _report_elevation_attempts(session)
        if not _guard_enabled():
            return
        now = _inventory(_REAL_HUGMESH)
        added = sorted(set(now) - set(_BASELINE))
        removed = sorted(set(_BASELINE) - set(now))
        changed = sorted(p for p in set(now) & set(_BASELINE) if now[p] != _BASELINE[p])
        if not (added or removed or changed):
            return
        session.exitstatus = 1
        print(f"\nSTATE LEAK: the suite wrote to the operator's real {_REAL_HUGMESH} "
              f"({len(_BASELINE)} file(s) watched)", file=sys.stderr)
        for tag, paths in (("created", added), ("DELETED", removed), ("modified", changed)):
            for path in paths:
                print(f"  {tag}: {path}", file=sys.stderr)
    finally:
        if home and os.path.isdir(home):
            shutil.rmtree(home, ignore_errors=True)
