"""tests/conftest.py NEVER ELEVATE — the spy itself, proved rather than trusted.

Every case that must be caught goes through the REAL subprocess module (Popen, run,
check_output, shell strings, an `env`/`nice`/`timeout` wrapper, an absolute path) and
is consumed by ``expect_elevation_attempt`` so the autouse fixture does not error the
proving test. The negative cases must still spawn normally: a guard that broke every
subprocess would be noticed, one that silently caught nothing would not — which is
the whole point of this file.

Every positive argv is one that CANNOT elevate or prompt even if the guard missed it
(`--version` / `-V` make sudo and pkexec print and exit) — the first draft of this
file used `sudo -n true`, the guard did miss `nice -n 5 sudo`, and a real sudo ran.
"""
import os
import subprocess
import sys

import pytest

import conftest
from conftest import ElevationAttempted, expect_elevation_attempt


# ── caught ───────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("argv", [
    ["sudo", "--version"],
    ["sudo", "-A", "--version"],                            # the hang's own prefix
    ["/usr/bin/sudo", "--version"],
    ["pkexec", "--version"],
    ["doas", "-V"],
    ["run0", "--version"],
    ["env", "HEADSCALE_URL=x", "sudo", "--version"],        # transparent wrappers
    ["env", "-i", "sudo", "--version"],
    ["nice", "-n", "5", "sudo", "--version"],
    ["timeout", "30", "sudo", "--version"],
    ["timeout", "5s", "pkexec", "--version"],
    ["nohup", "sudo", "--version"],
])
def test_popen_refuses_an_elevation_argv(argv):
    with expect_elevation_attempt():
        subprocess.Popen(argv)


@pytest.mark.parametrize("argv", [
    ["env", "-u", "GH_TOKEN", "sudo", "--version"],         # #360/#304: -u NAME takes an arg
    ["env", "-u", "GH_TOKEN", "-u", "GITHUB_TOKEN", "sudo", "--version"],
    ["env", "--unset", "DISPLAY", "sudo", "--version"],
    ["taskset", "0x1", "sudo", "--version"],                # hex affinity mask
    ["taskset", "0xff", "pkexec", "--version"],
    ["timeout", "-s", "KILL", "30", "sudo", "--version"],   # -s SIG takes an arg
    ["timeout", "-k", "5", "30", "sudo", "--version"],
    ["timeout", "--signal", "KILL", "30", "sudo", "--version"],
])
def test_popen_refuses_an_elevation_argv_behind_an_argument_taking_wrapper(argv):
    with expect_elevation_attempt():
        subprocess.Popen(argv)


def test_a_leading_shell_assignment_does_not_hide_the_program():
    with expect_elevation_attempt():
        subprocess.run("VAR=1 sudo --version", shell=True)
    with expect_elevation_attempt():
        subprocess.run("A=1 B=2 sudo --version", shell=True)


def test_the_executable_kwarg_is_inspected():
    with expect_elevation_attempt():
        subprocess.Popen(["harmless"], executable="/usr/bin/sudo")


def test_wrapper_argument_handling_does_not_swallow_a_real_program():
    """Consuming a flag's argument must not turn an ordinary command into a miss for the
    wrong reason: `env -u X echo` still stops at echo, never reaching a later sudo arg."""
    assert conftest._elevation_program(["env", "-u", "X", "echo", "sudo"], False) is None
    assert conftest._elevation_program(["timeout", "-s", "KILL", "30", "echo", "sudo"],
                                       False) is None


def test_run_and_check_output_go_through_the_same_spy():
    with expect_elevation_attempt():
        subprocess.run(["sudo", "--version"], capture_output=True)
    with expect_elevation_attempt():
        subprocess.check_output(["pkexec", "--version"])


def test_shell_strings_are_tokenised():
    with expect_elevation_attempt():
        subprocess.run("sudo --version", shell=True)
    with expect_elevation_attempt():
        subprocess.run("env X=1 sudo --version", shell=True)


def test_the_record_names_the_test_and_the_leading_tokens():
    before = len(conftest._ELEVATION_ATTEMPTS)
    argv = ["sudo", "-V", "bash", "./build.sh", "-w", "/w",
            "--user-password", "hunter2-never-shown"]
    with expect_elevation_attempt():
        subprocess.Popen(argv)
    # consumed by expect_elevation_attempt; re-run to inspect the record shape
    try:
        subprocess.Popen(argv)
    except ElevationAttempted as e:
        where, shown = conftest._ELEVATION_ATTEMPTS.pop()
        assert "test_the_record_names_the_test_and_the_leading_tokens" in where
        assert shown.startswith("sudo -V bash ./build.sh -w")
        assert "hunter2-never-shown" not in shown and "hunter2-never-shown" not in str(e)
    else:
        pytest.fail("second attempt was not caught")
    assert len(conftest._ELEVATION_ATTEMPTS) == before


def test_wrapper_scan_stops_at_the_first_real_program():
    """Looking through wrappers must not turn into scanning the whole argv: `bash -c
    'sudo …'` is bash's business (and `echo sudo` is just text)."""
    assert conftest._elevation_program(["bash", "-c", "sudo --version"], False) is None
    assert conftest._elevation_program(["echo", "sudo"], False) is None
    assert conftest._elevation_program(["nice", "-n", "5", "bash", "sudo"], False) is None
    assert conftest._elevation_program(["nice", "-n", "5", "sudo", "x"], False) == "sudo"
    assert conftest._elevation_program("sudo -n true", True) == "sudo"
    assert conftest._elevation_program("/usr/bin/sudo", False) == "sudo"
    assert conftest._elevation_program(b"sudo", False) == "sudo"
    assert conftest._elevation_program([], False) is None


# ── not caught: ordinary subprocesses still work exactly as before ───────────────────
def test_ordinary_commands_still_spawn():
    r = subprocess.run([sys.executable, "-c", "print('ok')"], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip() == "ok"
    assert subprocess.check_output(["echo", "sudo"], text=True).strip() == "sudo"


def test_the_installed_popen_is_still_a_popen():
    """isinstance checks and the run/call helpers rely on Popen being the class."""
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    assert isinstance(p, subprocess.Popen)
    assert getattr(subprocess.Popen, "_hugmesh_never_elevate", False)


def test_a_faked_popen_is_invisible_to_the_spy_by_design(monkeypatch):
    """The documented way to assert a sudo argv: fake the process layer. Nothing is
    spawned, so nothing is recorded — and monkeypatch restores the spy afterwards."""
    seen = []
    monkeypatch.setattr(subprocess, "Popen", lambda cmd, **kw: seen.append(cmd))
    subprocess.Popen(["sudo", "kill", "-TERM", "-1234"])
    assert seen == [["sudo", "kill", "-TERM", "-1234"]]


# ── #375 (1): an attempt inside an unguarded QThread.run must not qFatal pytest ───────
def test_an_attempt_from_a_qthread_is_recorded_not_raised():
    """PyQt6 treats a Python exception escaping a reimplemented QThread.run (the shape of
    progress._FlashWorker) as fatal: `Fatal Python error: Aborted`, rc 134, no report, and
    every later test in the file lost. Off the main thread the spy therefore RECORDS the
    attempt (the autouse fixture still fails the test at teardown) and neutralises the
    spawn instead of raising. The thread's own result proves no sudo ran: a real
    `sudo --version` prints a banner; the neutralised child prints nothing.

    This is the ONE Qt-touching case in an otherwise Qt-free file, so the skip lives
    INSIDE the test: a module-level ``importorskip`` would drop the other 36 cases, which
    are pure subprocess-spy checks and must keep running in the pre-merge job that
    installs no Qt binding (.github/workflows/studio-tests.yml).

    It gates on PyQt6 BY NAME, not on the ``hugmesh_studio.gui.qt`` shim the GUI files
    use, and that is deliberate. The behaviour pinned here is PyQt6's, and the shim
    would also let the case run under PySide6 (GitLab's ``test:studio-suite`` installs
    only that) — where it is unsafe: the QCoreApplication created below outlives the
    test, so the NEXT GUI file's ``QApplication.instance() or QApplication(...)`` is
    handed a QCoreApplication and Qt aborts the whole process (rc 134, every later test
    lost). Measured with PySide6 6.11.2: this case, then tests/test_choice_cards.py.
    Under PySide6 alone this case therefore skips, as it does with no binding at all."""
    QtCore = pytest.importorskip(
        "PyQt6.QtCore", reason="no PyQt6 binding installed (this case pins PyQt6's qFatal)")

    _app = QtCore.QCoreApplication.instance() or QtCore.QCoreApplication([])
    seen = {}

    class T(QtCore.QThread):
        def run(self):
            seen["cp"] = subprocess.run(["sudo", "--version"], capture_output=True)

    before = len(conftest._ELEVATION_ATTEMPTS)
    t = T()
    t.start()
    assert t.wait(15000), "the thread never finished (it raised into Qt?)"
    assert len(conftest._ELEVATION_ATTEMPTS) == before + 1, "the attempt was not recorded"
    assert seen["cp"].returncode == 0 and seen["cp"].stdout == b"", seen["cp"]
    del conftest._ELEVATION_ATTEMPTS[before:]      # consumed: the proving test must pass


def test_a_plain_thread_attempt_is_recorded_too():
    import threading

    seen = {}
    before = len(conftest._ELEVATION_ATTEMPTS)

    def body():
        seen["cp"] = subprocess.run(["sudo", "--version"], capture_output=True)

    th = threading.Thread(target=body)
    th.start()
    th.join(15)
    assert len(conftest._ELEVATION_ATTEMPTS) == before + 1
    assert seen["cp"].stdout == b""
    del conftest._ELEVATION_ATTEMPTS[before:]


def test_the_main_thread_still_raises():
    """The neutralise-don't-raise branch must not leak onto the main thread, where the
    raise is what names the offending line."""
    with expect_elevation_attempt():
        subprocess.run(["sudo", "--version"], capture_output=True)


# ── #375 (2): an iterator argv must reach the real Popen intact ───────────────────────
def test_an_iterator_argv_is_not_consumed_by_the_spy():
    out = subprocess.run(iter([sys.executable, "-c", "print('hi-iter')"]),
                         capture_output=True, text=True)
    assert out.stdout.strip() == "hi-iter"


def test_an_iterator_argv_is_still_scanned_for_elevation():
    with expect_elevation_attempt():
        subprocess.Popen(iter(["sudo", "--version"]))


# ── #360 (1): the REPORTING layers, proved by running the spy in an INNER session ─────
# Every case above goes through expect_elevation_attempt, which consumes the record so
# the autouse fixture (layer b) and pytest_sessionfinish (layer c) never fire. A
# refactor that turned the spy into a logger, or dropped the fixture, was invisible.
# These two run the REAL conftest in a child pytest and assert on its verdict.
def _inner_session(tmp_path, test_body: str, conftest_tail: str = ""):
    import textwrap
    outer = os.path.join(os.path.dirname(os.path.abspath(__file__)), "conftest.py")
    (tmp_path / "conftest.py").write_text(
        "import importlib.util, sys\n"
        f"_spec = importlib.util.spec_from_file_location('_outer_conftest', {outer!r})\n"
        "_m = importlib.util.module_from_spec(_spec)\n"
        "sys.modules['_outer_conftest'] = _m\n"
        "_spec.loader.exec_module(_m)\n"
        "globals().update({k: v for k, v in vars(_m).items() if not k.startswith('__')})\n"
        + textwrap.dedent(conftest_tail))
    (tmp_path / "test_inner.py").write_text(textwrap.dedent(test_body))
    env = {k: v for k, v in os.environ.items()
           if k not in ("PYTEST_CURRENT_TEST", "HUGMESH_STUDIO_NO_ELEVATION")}
    env["QT_QPA_PLATFORM"] = "offscreen"
    return subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
         "--rootdir", str(tmp_path), str(tmp_path / "test_inner.py")],
        cwd=str(tmp_path), env=env, capture_output=True, text=True, timeout=120)


def test_a_swallowed_attempt_still_errors_the_test_at_teardown(tmp_path):
    """Layer (b): the code under test swallows the raise (the ProgressPage worker catches
    BaseException by design) — the autouse `_never_elevate` fixture must still fail the
    test. Mutation: `if fresh:` -> `if False and fresh:` makes this inner run `1 passed`."""
    r = _inner_session(tmp_path, """
        import subprocess

        def test_swallowed():
            try:
                subprocess.Popen(["sudo", "--version"])
            except Exception:
                pass
    """)
    out = r.stdout + r.stderr
    assert r.returncode == 1, out
    assert "this test started (or tried to start) an elevation program" in out, out
    assert "1 passed, 1 error" in out, out


def test_an_attempt_outside_any_test_window_fails_the_run(tmp_path):
    """Layer (c): an attempt from a thread that outlives its test lands after the
    fixture's window; pytest_sessionfinish must flip the exit status and print the
    ELEVATION ATTEMPTED report even though every test passed. The late attempt is
    appended deterministically after the last test's teardown (runtest_logfinish).
    Mutation: `if not _ELEVATION_ATTEMPTS:` -> `if True or ...` makes this exit 0."""
    r = _inner_session(tmp_path, """
        def test_fine():
            assert True
    """, conftest_tail="""
        import pytest

        @pytest.hookimpl(trylast=True)
        def pytest_runtest_logfinish(nodeid, location):
            _m._ELEVATION_ATTEMPTS.append(("late-thread", "sudo --version ..."))
    """)
    out = r.stdout + r.stderr
    assert "1 passed" in out, out                    # the test itself was fine
    assert r.returncode == 1, out
    assert "ELEVATION ATTEMPTED" in r.stderr, out
    assert "late-thread: sudo --version" in r.stderr, out
