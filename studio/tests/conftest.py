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


@pytest.fixture(autouse=True)
def _host_independent_build_defaults(monkeypatch):
    """Make the suite's host-aware build defaults (core/host_resources) deterministic
    on ANY test host: pin the jobs default to the historical 8 via its env override,
    clear any ambient memory-cap override, and pin BOTH meminfo seams — the
    per-process snapshot (_meminfo_cached: jobs default + cap) AND the per-call
    dispatch-time read (_meminfo_fresh: low-memory warnings) — to a canonical
    healthy 32 GiB reading (cap auto-derives, warnings stay quiet). Tests that
    exercise the formulas pass explicit env/meminfo (which win) or re-monkeypatch
    the relevant seam themselves."""
    from hugmesh_studio.core import host_resources
    monkeypatch.setenv(host_resources.JOBS_ENV, "8")
    monkeypatch.delenv(host_resources.MEMORY_ENV, raising=False)
    healthy = {"MemTotal": 32 * host_resources.GIB,
               "MemAvailable": 24 * host_resources.GIB,
               "SwapTotal": 4 * host_resources.GIB,
               "SwapFree": 4 * host_resources.GIB}
    monkeypatch.setattr(host_resources, "_meminfo_cached", lambda: dict(healthy))
    monkeypatch.setattr(host_resources, "_meminfo_fresh", lambda: dict(healthy))


@pytest.fixture(autouse=True)
def _inert_mesh_monitor(request, monkeypatch):
    """Make the local-mesh page's running-mesh monitor INERT by default.

    ``LocalMeshPage`` re-reads BOTH mesh lanes off-thread (``core.mesh_monitor.
    snapshot``: ``kind get clusters``, one ``kubectl get … -A -o json``, ``docker
    inspect``, ``docker compose ps``) whenever its mesh-state probe answers or its
    monitor section is open. Ten test files build that page for unrelated reasons
    (verb attribution, the egress gate, log coalescing, the e2e tree, theming) and
    stub only the seams THEY know about; without this fixture each of them would
    shell the operator's real kind cluster and docker daemon through the monitor,
    and a QThread still in that read when the page is torn down aborts the process
    (``QThread: Destroyed while thread is still running``) — measured on two suites
    before this fixture existed.

    The stub answers instantly with BOTH lanes unestablished (never "no mesh": the
    page's tri-state rule) and records nothing. A module that wants the real
    function — the monitor's own core and GUI suites — opts out with
    ``pytestmark = pytest.mark.real_mesh_monitor``; the GUI suite then seams
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


# ─────────────────────────────────────────────────────────────────────────────
# NEVER ELEVATE: a spy on the real subprocess.Popen that fails any test which starts
# sudo / pkexec / doas / su — the anti-vacuity control for the 2026-09-04 wedge.
#
# What happened: tests/test_pages_fields_asks.py walked the REAL wizard onto the
# ProgressPage, which dispatches the committed worklist ON ARRIVAL — through the real
# WorklistDriver -> BuildDriver -> `sudo -A bash ./build-x86-host-stage4.sh` with the
# Qt askpass helper as SUDO_ASKPASS. Under QT_QPA_PLATFORM=offscreen on a desktop
# (DISPLAY set) the helper popped an INVISIBLE dialog and blocked forever; the test
# itself PASSED (it only checked the page type), its worker thread died with the
# interpreter, and the root-owned sudo was orphaned. 60 of them were found wedged, some
# two days old, each pinning a 15-58 MB Qt process. No assertion anywhere could see it,
# which is why the control sits at the one boundary every spawn crosses.
#
# Three pieces, each load-bearing:
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
# second, and it is the one that would have caught every wedged launcher.
# ─────────────────────────────────────────────────────────────────────────────

#: argv[0] basenames that mean "become another user".
ELEVATION_PROGRAMS = frozenset({"sudo", "pkexec", "doas", "su", "run0"})
#: Wrappers looked THROUGH when locating the program (`env K=V sudo …`, `nice -n 5
#: sudo …`, `timeout 30 sudo …`). While inside one, tokens carrying `=`, starting with
#: `-`, or purely numeric (an optional s/m/h/d suffix) are the wrapper's own arguments.
_TRANSPARENT_WRAPPERS = frozenset({"env", "nice", "ionice", "stdbuf", "setsid", "nohup",
                                   "timeout", "chrt", "taskset"})
_WRAPPER_NUMERIC = re.compile(r"[0-9]+[smhd]?")

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
    inside_wrapper = False
    for tok in tokens:
        name = os.path.basename(tok)
        if name in ELEVATION_PROGRAMS:
            return name
        if name in _TRANSPARENT_WRAPPERS:
            inside_wrapper = True
            continue
        if inside_wrapper and ("=" in tok or tok.startswith("-")
                               or _WRAPPER_NUMERIC.fullmatch(tok)):
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
            prog = _elevation_program(args, bool(kw.get("shell", False)))
            if prog is not None:
                where = os.environ.get("PYTEST_CURRENT_TEST", "<outside any test>")
                shown = _leading_tokens(args)
                _ELEVATION_ATTEMPTS.append((where, shown))
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
# Three pieces, and each one is load-bearing:
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


# NOTE. A second autouse fixture (_isolated_state_dir_default) arrived here from the
# sibling branch and did exactly what _isolate_studio_state_dir above already does:
# point HUGMESH_STUDIO_STATE_DIR at a tmp_path. Git merged the two without a
# conflict, because each side only ADDED — leaving two autouse fixtures racing to
# set one variable, with the winner decided by definition order rather than by
# anyone's intent. Collapsed to the one above, which is the one paired with
# state_paths.state_dir()'s refusal of the home fallback under pytest.
#
# The DETECTION half of that branch is kept in full below: it is not a duplicate of
# anything, and it is what catches a state accessor that never goes through the seam.

def pytest_sessionfinish(session, exitstatus):
    """Fail the RUN (not a test) if anything under the operator's real ~/.hugmesh was
    created, deleted or modified while the suite ran."""
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
