"""tests/conftest.py must isolate the SUITE from the operator's real ~/.hugmesh.

The defect this pins: the Studio's state accessors (core.instance.state_dir,
core.build_sessions.sessions_dir, core.crashlog.crashes_dir, gui.tray.
build_status_path) all fall back to ``~/.hugmesh/studio`` when
``$HUGMESH_STUDIO_STATE_DIR`` is unset, and only 38 of 169 test files pinned it. Running
the rest wrote real GUI run-logs into the operator's live state dir — logs whose body
is the TEST constant ``test_local_stack_preflight._M2_PROBLEM``, a string that exists
nowhere in production code.

Three properties, each with its own teeth:

  * the autouse default redirects every state accessor          (test_* below)
  * HOME itself moves, in pytest_configure, EARLY ENOUGH for a module that binds a
    home-derived path at import time (tests/test_pages_identity.py's ``STAGING``)
  * the leak guard actually fires — on a created, a DELETED and a MODIFIED file

The last group runs pytest-in-pytest against a COPY of the real conftest.py, with a
synthetic HOME, so it never touches the operator's state. Each such case carries a
positive control (the same inner run with the isolation stripped out) so a test that
silently stopped exercising anything cannot pass.
"""
import importlib.util
import json
import os
import pwd
import subprocess
import sys
import textwrap

import pytest

from hugmesh_studio.core import build_sessions, crashlog, instance

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_STUDIO_ROOT = os.path.dirname(_TESTS_DIR)
_CONFTEST = os.path.join(_TESTS_DIR, "conftest.py")

#: Every production accessor that falls back to ``~/.hugmesh/studio``. Named as
#: (label, callable) so the floor assertion below can prove the list was not empty.
#: gui.tray needs a Qt binding; this file must still run in the Qt-less CI the module
#: docstring of conftest.py promises, so it is appended only when Qt imports — and
#: ``test_the_tray_accessor_is_covered_when_qt_is_present`` makes sure a Qt-capable box
#: never silently drops it.
_QT_AVAILABLE = importlib.util.find_spec("PySide6") is not None or \
    importlib.util.find_spec("PyQt6") is not None

_STATE_ACCESSORS = [
    ("core.instance.state_dir", instance.state_dir),
    ("core.build_sessions.sessions_dir", build_sessions.sessions_dir),
    ("core.crashlog.crashes_dir", crashlog.crashes_dir),
]
if _QT_AVAILABLE:
    from hugmesh_studio.gui import tray
    _STATE_ACCESSORS.append(("gui.tray.build_status_path", tray.build_status_path))


def _login_home() -> str:
    """The real home of the invoking user, read from the passwd database — the one
    answer $HOME cannot move, so the assertions below cannot be satisfied merely by
    the redirect pointing at itself."""
    return pwd.getpwuid(os.getuid()).pw_dir


# ── (b) the autouse default state dir ────────────────────────────────────────────

def test_every_state_accessor_is_redirected_off_the_real_hugmesh():
    state = os.environ.get("HUGMESH_STUDIO_STATE_DIR")
    assert state, ("conftest.py must set HUGMESH_STUDIO_STATE_DIR for EVERY test — "
                   "only 38 of 169 files pinned it themselves")
    real = os.path.join(_login_home(), ".hugmesh")
    checked = 0
    for label, fn in _STATE_ACCESSORS:
        path = os.path.abspath(fn())
        assert not path.startswith(real + os.sep), f"{label}() -> {path} is inside {real}"
        assert path.startswith(os.path.abspath(state)), \
            f"{label}() -> {path} does not honour HUGMESH_STUDIO_STATE_DIR={state}"
        checked += 1
    assert checked == len(_STATE_ACCESSORS) >= 3, \
        f"floor: expected >=3 state accessors examined, examined {checked}"


def test_the_tray_accessor_is_covered_when_qt_is_present():
    """The Qt-optional list above must not quietly shrink on a box that HAS Qt —
    gui.tray.build_status_path is the accessor that produced build-status.json."""
    if not _QT_AVAILABLE:
        pytest.skip("no Qt binding installed — the core accessors above still ran")
    assert "gui.tray.build_status_path" in dict(_STATE_ACCESSORS)
    assert len(_STATE_ACCESSORS) == 4


def test_the_default_does_not_override_a_files_own_isolation(monkeypatch, tmp_path):
    """The 37 files that already carry their own ``_isolated_state_dir`` must keep
    winning: a module-level autouse fixture is instantiated AFTER a conftest one."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "mine"))
    assert instance.state_dir() == str(tmp_path / "mine")


# ── (a) HOME itself, moved early enough for an import-time binding ───────────────

def test_home_is_redirected_before_test_modules_are_imported():
    home = os.path.expanduser("~")
    assert home != _login_home(), (
        "HOME still points at the real home — a module that binds ~/.hugmesh/keyzip at "
        "IMPORT time (tests/test_pages_identity.py STAGING) would write to the operator")
    assert os.environ.get("HUGMESH_STUDIO_TEST_REAL_HOME") == _login_home()
    for var in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
        val = os.environ.get(var, "")
        assert val.startswith(home + os.sep), f"{var}={val!r} is not under the fake HOME"


def test_the_import_time_keyzip_staging_binding_is_isolated():
    """The exact expression tests/test_pages_identity.py evaluates at import."""
    staging = os.path.join(os.path.expanduser("~"), ".hugmesh", "keyzip")
    assert not staging.startswith(os.path.join(_login_home(), ".hugmesh")), staging


# ── (c) the leak guard, mutation-tested in three directions ──────────────────────

_CANARY = {
    "created": "open(os.path.join(REAL, 'studio', 'logs', 'ZZ-CANARY.log'), 'w').write('x')",
    "deleted": "os.remove(os.path.join(REAL, 'studio', 'logs', 'ZZ-DELETE-ME.log'))",
    "modified": ("p = os.path.join(REAL, 'studio', 'build-status.json'); "
                 "open(p, 'w').write('{\"state\": \"mutated\"}')"),
}


def _seed_home(root):
    """A synthetic ~/.hugmesh that looks like the operator's: a log to delete, a
    build-status.json to rewrite in place, and a keyzip dir."""
    logs = root / ".hugmesh" / "studio" / "logs"
    logs.mkdir(parents=True)
    (root / ".hugmesh" / "keyzip").mkdir(parents=True)
    (logs / "ZZ-DELETE-ME.log").write_text("pre-existing\n")
    (root / ".hugmesh" / "studio" / "build-status.json").write_text(json.dumps({"state": "idle"}))
    return root / ".hugmesh"


def _inner_run(tmp_path, body, *, isolated=True, name="canary"):
    """Run pytest-in-pytest over one generated test, against a COPY of the real
    conftest.py, with HOME pointed at a synthetic tree.

    ``isolated=False`` strips the isolation out of the copy — the positive control that
    proves the generated test really does write, so a green ``isolated=True`` run is a
    fact about the fix and not about an inert canary.
    """
    home = tmp_path / name / "home"
    home.mkdir(parents=True)
    hugmesh = _seed_home(home)

    workdir = tmp_path / name / "tests"
    workdir.mkdir(parents=True)
    conftest = open(_CONFTEST).read()
    if not isolated:
        conftest = "import os, sys\nimport pytest\n" + \
            f"sys.path.insert(0, {_STUDIO_ROOT!r})\n"
    (workdir / "conftest.py").write_text(conftest)
    (workdir / "test_canary.py").write_text(textwrap.dedent(f"""\
        import os
        REAL = os.path.join(os.environ["HUGMESH_STUDIO_TEST_REAL_HOME_FOR_CANARY"], ".hugmesh")

        def test_canary():
            {body}
            assert True
        """))

    env = dict(os.environ)
    env.update(HOME=str(home), PYTHONPATH=_STUDIO_ROOT,
               HUGMESH_STUDIO_TEST_REAL_HOME_FOR_CANARY=str(home),
               QT_QPA_PLATFORM="offscreen")
    for var in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
                "HUGMESH_STUDIO_STATE_DIR", "HUGMESH_STUDIO_TEST_REAL_HOME"):
        env.pop(var, None)
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", str(workdir), "-q", "-p", "no:cacheprovider",
         "--rootdir", str(workdir)],
        capture_output=True, text=True, env=env, cwd=str(workdir), timeout=300)
    return proc, hugmesh


@pytest.mark.parametrize("kind", sorted(_CANARY))
def test_the_guard_catches_a_leak_in_every_direction(tmp_path, kind):
    proc, hugmesh = _inner_run(tmp_path, _CANARY[kind], name=f"guard-{kind}")
    out = proc.stdout + proc.stderr
    assert "1 passed" in out, f"the canary test itself must PASS — a leak from a green test:\n{out}"
    assert "STATE LEAK" in out, f"the guard did not report the {kind} leak:\n{out}"
    tag = {"created": "created:", "deleted": "DELETED:", "modified": "modified:"}[kind]
    assert tag in out, f"the guard reported a leak but not as {tag!r}:\n{out}"
    assert proc.returncode != 0, \
        f"the guard must fail the RUN, not just print ({kind}); rc={proc.returncode}\n{out}"


def test_a_leaking_test_writes_nothing_under_the_real_home(tmp_path):
    """End to end: the exact production write that produced the real leaked logs, run
    from a test that does NOT isolate itself."""
    body = ("from hugmesh_studio.core import build_sessions as bs; "
            "d = bs.sessions_dir(); os.makedirs(d, exist_ok=True); "
            "open(os.path.join(d, 'leaked.json'), 'w').write('{}')")

    # positive control FIRST: with the isolation removed this must land in the home.
    proc, hugmesh = _inner_run(tmp_path, body, isolated=False, name="control")
    leaked = [p for p in hugmesh.rglob("leaked.json")]
    assert leaked, ("the control run wrote nothing — the canary is inert, so the "
                    f"isolated run below would pass vacuously:\n{proc.stdout}{proc.stderr}")

    proc, hugmesh = _inner_run(tmp_path, body, isolated=True, name="isolated")
    assert "1 passed" in (proc.stdout + proc.stderr), proc.stdout + proc.stderr
    strays = sorted(str(p.relative_to(hugmesh)) for p in hugmesh.rglob("*") if p.is_file())
    assert strays == ["studio/build-status.json", "studio/logs/ZZ-DELETE-ME.log"], \
        f"the suite leaked into the real ~/.hugmesh: {strays}"
    assert proc.returncode == 0, proc.stdout + proc.stderr
