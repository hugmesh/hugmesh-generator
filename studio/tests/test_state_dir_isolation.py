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
