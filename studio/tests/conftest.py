"""Make the hugmesh_studio package importable for the studio test suite.

These tests target the pure-Python core (config / keyzip / validate) and do NOT
need PySide6, so they run in plain CI without the GUI toolkit installed.
"""
import os
import shutil
import sys
import tempfile

import pytest

# studio/ is the package root (contains hugmesh_studio/).
_STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _STUDIO_ROOT not in sys.path:
    sys.path.insert(0, _STUDIO_ROOT)


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
    """Redirect HOME (and the XDG dirs derived from it) to a throwaway tree, and take
    the before-picture the leak guard compares against."""
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


@pytest.fixture(autouse=True)
def _isolated_state_dir_default(tmp_path, monkeypatch):
    """The DEFAULT state dir for every test that does not pin its own — see (b)."""
    monkeypatch.setenv(STATE_DIR_ENV, str(tmp_path / "state"))


def pytest_sessionfinish(session, exitstatus):
    """Fail the RUN (not a test) if anything under the operator's real ~/.hugmesh was
    created, deleted or modified while the suite ran."""
    home = getattr(session.config, "_hugmesh_fake_home", "")
    try:
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
