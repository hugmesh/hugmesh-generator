"""A Studio crash must leave evidence on disk.

The 2026-07-29 GUI crash had to be reconstructed from build artifacts and file
mtimes because nothing was written anywhere: under PyQt6 an unhandled exception in a
slot calls qFatal() and aborts the process, and a Studio started from a desktop entry
has nowhere to print. These tests pin the parts that make the NEXT one diagnosable.

Qt-free on purpose — core/crashlog.py must be importable and installable before any
binding is loaded, since a crash during wizard construction is exactly the kind that
used to vanish.
"""
import os
import sys
import threading

import pytest

from hugmesh_studio.core import crashlog


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _restore_hooks():
    """install() mutates process-global hooks; put them back or every later test in
    the session inherits them."""
    sys_hook, thread_hook = sys.excepthook, threading.excepthook
    yield
    sys.excepthook, threading.excepthook = sys_hook, thread_hook


def _boom():
    try:
        raise ValueError("the-canary-error")
    except ValueError:
        return sys.exc_info()


def test_state_dir_env_override_is_honoured(tmp_path):
    """Never write to the operator's real ~/.hugmesh during a test or a hygiene run."""
    assert crashlog.crashes_dir().startswith(str(tmp_path))


def test_write_persists_the_traceback_and_returns_its_path():
    path = crashlog.write(*_boom())
    assert path and os.path.isfile(path)
    body = open(path, encoding="utf-8").read()
    assert "the-canary-error" in body, "the exception message is missing"
    assert "ValueError" in body
    assert "Traceback" in body, "the traceback itself was not written"


def test_the_log_records_the_qt_binding_and_interpreter():
    """The single most useful fact for a crash that only reproduces on one binding —
    the Studio supports both PyQt6 and PySide6 via gui/qt.py."""
    body = open(crashlog.write(*_boom()), encoding="utf-8").read()
    assert "qt binding:" in body
    assert "python:" in body
    assert sys.version.split()[0] in body


def test_install_captures_an_unhandled_exception_and_still_chains():
    """The hook must not REPLACE the previous behaviour (stderr printing) — a crash
    log is additive evidence, not a swallow."""
    called = []
    sys.excepthook = lambda *a: called.append(a)
    crashlog.install()
    sys.excepthook(*_boom())                      # simulate the interpreter's call
    files = os.listdir(crashlog.crashes_dir())
    assert len(files) == 1, f"expected exactly one crash log, got {files}"
    assert called, "the previous excepthook was not chained — stderr output would be lost"


def test_install_is_idempotent():
    """Installing twice must not chain the handler to itself and write two files."""
    crashlog.install()
    crashlog.install()
    sys.excepthook(*_boom())
    assert len(os.listdir(crashlog.crashes_dir())) == 1


def test_thread_exceptions_are_captured_too():
    """The build worker runs off the main thread, and threading exceptions do NOT go
    through sys.excepthook — precisely the path whose failures used to vanish."""
    crashlog.install()

    def _target():
        raise RuntimeError("worker-thread-canary")

    t = threading.Thread(target=_target, name="hugmesh-test-worker")
    t.start()
    t.join()
    logs = os.listdir(crashlog.crashes_dir())
    assert logs, "a worker-thread crash left no evidence"
    body = open(os.path.join(crashlog.crashes_dir(), logs[0]), encoding="utf-8").read()
    assert "worker-thread-canary" in body
    assert "hugmesh-test-worker" in body, "the failing thread is not identified"


def test_write_never_raises_even_when_the_directory_is_unusable(monkeypatch):
    """This runs while the process is already dying: an exception from the crash
    handler would replace the real crash with a confusing one."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", "/proc/version/not-a-dir")
    assert crashlog.write(*_boom()) == ""


def test_old_crash_logs_are_pruned():
    """Bounded so a crash loop cannot fill the operator's home directory."""
    for _ in range(crashlog._MAX_KEPT + 5):
        crashlog.write(*_boom())
    assert len(os.listdir(crashlog.crashes_dir())) <= crashlog._MAX_KEPT
