"""The suite must never write Studio state into the operator's real home.

This is a regression test for a defect that was live in production: 131 of the
suite's 171 test files did not set ``$HUGMESH_STUDIO_STATE_DIR``, and every Studio
state path fell back to ``~/.hugmesh/studio``. Tests that drive real widgets —
``test_local_mesh_bringup.py`` clicks a real ``preflight_btn`` — wrote real run
logs into the operator's live log directory. The operator's ``~/.hugmesh/studio``
accumulated hundreds of them, including 59 in a single minute, interleaved with
genuine GUI runs and indistinguishable from them.

Three layers are asserted here:

1. the autouse conftest fixture actually redirects the state dir (and every path
   derived from it) away from ``$HOME``;
2. EVERY state-path resolver in the tree is covered, not just the one that leaked
   — enumerated with a floor assertion so the test cannot pass over an empty or
   silently-shrunken list;
3. the ``state_paths.state_dir()`` guard refuses the home fallback under pytest,
   so removing the fixture fails loudly instead of resuming the pollution.
"""
from __future__ import annotations

import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import build_sessions, crashlog, instance, state_paths
import importlib.util
import json
import pwd
import textwrap


# Every resolver whose result must live under the isolated state dir. Adding a new
# Studio state path means adding it here; the floor assertion below makes a
# silently-shrunken list fail rather than pass vacuously.
def _state_path_resolvers():
    from hugmesh_studio.gui import tray
    return [
        ("state_paths.state_dir", state_paths.state_dir),
        ("instance.state_dir", instance.state_dir),
        ("build_sessions.sessions_dir", build_sessions.sessions_dir),
        ("crashlog.crashes_dir", crashlog.crashes_dir),
        ("tray.build_status_path", tray.build_status_path),
    ]


# The child-process probe (see the end-to-end test). Kept at module level and
# zero-indented so it is written out verbatim -- no dedent step to get wrong.
_PROBE_SOURCE = """\
import os


def test_touch_every_state_path():
    from hugmesh_studio.core import build_sessions, crashlog, instance
    from hugmesh_studio.gui import tray

    # Resolve every state path, then actually CREATE what each one names.
    # Writing is what leaked, so the probe must really write.
    for fn in (instance.state_dir, build_sessions.sessions_dir,
               crashlog.crashes_dir):
        os.makedirs(fn(), exist_ok=True)

    status = tray.build_status_path()
    os.makedirs(os.path.dirname(status), exist_ok=True)
    with open(status, "w", encoding="utf-8") as fh:
        fh.write("{}")

    # the exact path that polluted the operator's home: <state>/logs/<stamp>.log
    logs = os.path.join(instance.state_dir(), "logs")
    os.makedirs(logs, exist_ok=True)
    with open(os.path.join(logs, "probe.log"), "w", encoding="utf-8") as fh:
        fh.write("probe\\n")
"""


_MIN_RESOLVERS = 5          # the five that each carried a private copy of the fallback


def test_every_state_path_resolver_is_redirected_away_from_home():
    """No resolver may return a path under the operator's real home directory."""
    resolvers = _state_path_resolvers()
    # floor: the subject is a derived list, so prove it was actually populated
    assert len(resolvers) >= _MIN_RESOLVERS, (
        f"only {len(resolvers)} state-path resolvers enumerated; expected at least "
        f"{_MIN_RESOLVERS}. A shrunken list would make this test pass vacuously."
    )

    real_home = os.path.realpath(os.path.expanduser("~"))
    hugmesh_home = os.path.join(real_home, ".hugmesh")

    checked = 0
    for name, fn in resolvers:
        resolved = os.path.realpath(fn())
        assert not (resolved == hugmesh_home
                    or resolved.startswith(hugmesh_home + os.sep)), (
            f"{name}() resolved to {resolved!r}, which is inside the operator's real "
            f"~/.hugmesh — the test suite would write live Studio state there."
        )
        checked += 1

    assert checked == len(resolvers), (
        f"only {checked} of {len(resolvers)} resolvers were actually examined"
    )


def test_the_isolated_state_dir_is_the_one_the_conftest_fixture_set():
    """The redirect is the conftest fixture's doing, not an ambient env var."""
    override = os.environ.get(state_paths.STATE_DIR_ENV)
    assert override, (
        f"${state_paths.STATE_DIR_ENV} is unset during a test — the autouse "
        f"`_isolate_studio_state_dir` fixture in tests/conftest.py is not running."
    )
    assert os.path.realpath(state_paths.state_dir()) == os.path.realpath(override)


def test_writing_a_run_log_lands_in_the_isolated_dir_not_the_real_home():
    """The exact operation that leaked: create <state>/logs and write a log there."""
    logs = os.path.join(state_paths.state_dir(), "logs")
    os.makedirs(logs, exist_ok=True)
    path = os.path.join(logs, "20260827-000000-Checking-host-readiness-FAILED.log")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# Checking host readiness — FAILED\n")

    real_home = os.path.realpath(os.path.expanduser("~"))
    assert not os.path.realpath(path).startswith(real_home + os.sep), (
        f"a run log was written to {path!r}, inside the operator's real home"
    )
    assert os.path.exists(path)          # and it really was written somewhere


def test_state_dir_refuses_the_home_fallback_under_pytest(monkeypatch):
    """With no override, state_dir() raises rather than returning ~/.hugmesh/studio.

    This is the guard that makes a future conftest regression loud. Without it,
    deleting the autouse fixture silently restores the original defect.
    """
    monkeypatch.delenv(state_paths.STATE_DIR_ENV, raising=False)
    monkeypatch.delenv(state_paths.ALLOW_HOME_ENV, raising=False)

    assert state_paths.under_pytest()

    with pytest.raises(RuntimeError) as excinfo:
        state_paths.state_dir()
    assert ".hugmesh" in str(excinfo.value)

    # every resolver inherits the guard, not just the entry point
    from hugmesh_studio.gui import tray
    for name, fn in [("instance.state_dir", instance.state_dir),
                     ("build_sessions.sessions_dir", build_sessions.sessions_dir),
                     ("tray.build_status_path", tray.build_status_path)]:
        with pytest.raises(RuntimeError):
            fn()


def test_the_opt_out_still_exposes_the_real_default(monkeypatch):
    """The home fallback itself is still reachable, deliberately, for its own tests."""
    monkeypatch.delenv(state_paths.STATE_DIR_ENV, raising=False)
    monkeypatch.setenv(state_paths.ALLOW_HOME_ENV, "1")
    expected = os.path.join(os.path.expanduser("~"), ".hugmesh", "studio")
    assert state_paths.state_dir() == expected == state_paths.home_state_dir()


def test_crash_logger_never_raises_when_the_guard_fires(monkeypatch):
    """crashlog.write() must swallow the guard like any other failure."""
    monkeypatch.delenv(state_paths.STATE_DIR_ENV, raising=False)
    monkeypatch.delenv(state_paths.ALLOW_HOME_ENV, raising=False)
    try:
        raise ValueError("boom")
    except ValueError:
        exc_type, exc, tb = sys.exc_info()
        assert crashlog.write(exc_type, exc, tb) == ""     # returned "", did not raise


def test_a_real_suite_run_writes_nothing_into_a_sandboxed_home(tmp_path):
    """End-to-end proof, in a child pytest with $HOME redirected to a sandbox.

    This is the original defect's exact reproduction. The probe is written INTO
    ``studio/tests/`` on purpose: pytest only applies ``tests/conftest.py`` to files
    beneath it, so a probe anywhere else would never exercise the very fixture this
    test exists to verify. It touches every state-path resolver, and the sandboxed
    ``$HOME`` must come back untouched.

    Before the fix this produced
    ``<sandbox>/.hugmesh/studio/logs/*-Checking-host-readiness-FAILED.log``.
    """
    sandbox = tmp_path / "home"
    sandbox.mkdir()

    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tests_dir = os.path.join(studio_root, "tests")
    probe = os.path.join(tests_dir, "test_zz_state_leak_probe_tmp.py")

    with open(probe, "w", encoding="utf-8") as fh:
        fh.write(_PROBE_SOURCE)

    env = dict(os.environ)
    env.pop(state_paths.STATE_DIR_ENV, None)
    env.pop(state_paths.ALLOW_HOME_ENV, None)
    env["HOME"] = str(sandbox)
    env["QT_QPA_PLATFORM"] = "offscreen"

    try:
        proc = subprocess.run(
            [sys.executable, "-m", "pytest", probe, "-q", "-p", "no:cacheprovider"],
            cwd=studio_root, env=env, capture_output=True, text=True, timeout=300)
    finally:
        os.unlink(probe)

    leaked = []
    hugmesh = sandbox / ".hugmesh"
    if hugmesh.exists():
        leaked = sorted(str(f) for f in hugmesh.rglob("*") if f.is_file())

    assert not leaked, (
        f"the child pytest run wrote {len(leaked)} file(s) into the sandboxed HOME "
        f"-- the suite is polluting the operator's real state dir: {leaked}"
    )
    # floor: "nothing leaked" is only meaningful if the probe actually ran and
    # passed. A collection error would also leave the sandbox clean.
    assert "1 passed" in proc.stdout, (
        f"the child pytest did not run the probe to completion (rc={proc.returncode}); "
        f"'nothing leaked' would be vacuous.\nstdout:\n{proc.stdout}\n"
        f"stderr:\n{proc.stderr}"
    )


# ─────────────────────────────────────────────────────────────────────────────
# PREVENTION above, DETECTION below. The two halves came from separate branches
# and were nearly landed as rival copies of this file; they are not rivals.
#
#   above  — the seam (core/state_paths), the autouse fixture that redirects every
#            test, and state_dir()'s refusal of the home fallback under pytest.
#            These stop the write from happening.
#   below  — an inventory of the REAL ~/.hugmesh taken before and after, keyed on
#            (mtime_ns, ctime_ns, size). ctime is the load-bearing part: userspace
#            cannot forge it with os.utime, so an in-place rewrite of
#            build-status.json is caught even when name and size are unchanged.
#
# Keeping both is the point. Prevention that is bypassed leaves no trace, and a
# detector alone lets the pollution happen and only then complains. The detector
# is what catches the day someone adds a state accessor that does not go through
# the seam.
# ─────────────────────────────────────────────────────────────────────────────

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
    if not isolated:
        # THE POSITIVE CONTROL HAS TO BE ABLE TO LEAK. state_paths.state_dir()
        # refuses the ~/.hugmesh fallback outright while pytest is running, which is
        # the PREVENTION half of this file — and it is strong enough that stripping
        # the conftest isolation is no longer sufficient to make the canary write.
        # Without this the control writes nothing, correctly declares itself inert,
        # and the detection half below can never be shown to bite.
        #
        # ALLOW_HOME_ENV is state_paths' own documented escape hatch for exactly this
        # case. It is set ONLY on the control run (isolated=False), never on the
        # isolated run the real assertion is about, and HOME already points at a
        # synthetic tree — so the "home" this permits writing to is tmp_path, not the
        # operator's.
        env[state_paths.ALLOW_HOME_ENV] = "1"
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
