"""view_doors.pid_alive never signals on Windows (part of the Windows contract).

Found 2026-11-13 on Windows 11: with no /proc it fell back to ``os.kill(pid, 0)``,
which on Windows is GenerateConsoleCtrlEvent(CTRL_C_EVENT): a Ctrl+C sent to the
recorded pid's console group, and "alive" for any live pid, reused or not.
"""
from __future__ import annotations

import os

import pytest

from hugmesh_studio.core import view_doors


@pytest.fixture
def no_signals(monkeypatch):
    monkeypatch.setattr(view_doors.os, "kill",
                        lambda *a: pytest.fail(f"os.kill{a} on Windows is a console event"))


def _alive(pid, *, live, line):
    return view_doors.pid_alive(pid, "hugmesh-view", os_name="nt",
                                alive_windows=lambda p: live,
                                cmdline_windows=lambda p: line)


def test_windows_asks_the_process_api_and_the_marker_decides(no_signals):
    assert _alive(4242, live=True, line="python hugmesh-view.py serve") is True
    assert _alive(4242, live=True, line="C:\\Windows\\notepad.exe") is False   # reused pid
    assert _alive(4242, live=True, line=None) is False          # unreadable: not ours
    assert _alive(4242, live=False, line="python hugmesh-view.py") is False
    assert view_doors.pid_alive(0, os_name="nt") is False


def test_posix_keeps_its_proc_marker_check(monkeypatch):
    monkeypatch.setattr(view_doors, "_cmdline", lambda pid: "python3 hugmesh-view.py serve")
    never = lambda p: pytest.fail("POSIX never asks the Windows API")        # noqa: E731
    assert view_doors.pid_alive(4242, "hugmesh-view", os_name="posix",
                                alive_windows=never, cmdline_windows=never) is True
    monkeypatch.setattr(view_doors, "_cmdline", lambda pid: "/usr/bin/vim")
    assert view_doors.pid_alive(4242, "hugmesh-view", os_name="posix") is False


@pytest.mark.skipif(os.name != "nt", reason="the real Windows process API")
def test_on_windows_this_process_is_read_not_signalled(no_signals):
    assert view_doors.pid_alive(os.getpid(), marker="hugmesh-view") is False
    assert view_doors.pid_alive(os.getpid(), marker="pytest") is True
