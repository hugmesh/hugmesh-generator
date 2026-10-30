"""The windowed Windows Studio starts its child processes with no console window.

Measured on Windows 11 with the MSI (2026-10-29): every docker/kubectl/git probe opened
a cmd window that appeared and vanished, one every few seconds while the Studio polled
Docker. core/no_console.install() is what app.main() runs first to prevent it.
"""
from __future__ import annotations

import subprocess
import sys

import pytest

from hugmesh_studio.core import no_console

FLAG = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)


@pytest.fixture
def fresh(monkeypatch):
    """Undo the hook after each test, whatever it did."""
    monkeypatch.setattr(no_console, "_INSTALLED", False)
    monkeypatch.setattr(subprocess.Popen, "__init__", subprocess.Popen.__init__)


@pytest.fixture
def recorded(monkeypatch):
    """Stand in for the real Popen.__init__ and keep the creationflags it was given."""
    seen = []

    def fake(self, *args, **kwargs):
        seen.append(kwargs.get("creationflags", 0))
        raise RuntimeError("recorded")         # never start a process

    monkeypatch.setattr(subprocess.Popen, "__init__", fake)
    return seen


def _spawn(**kwargs):
    with pytest.raises(RuntimeError, match="recorded"):
        subprocess.Popen(["docker", "version"], **kwargs)


def test_a_console_less_windows_studio_hides_every_child(fresh, recorded):
    assert no_console.install(osname="nt", has_console=lambda: False) is True
    _spawn()
    _spawn(creationflags=0)
    with pytest.raises(RuntimeError, match="recorded"):
        subprocess.run(["kubectl", "version"], capture_output=True)
    assert recorded == [FLAG, FLAG, FLAG]


def test_a_caller_that_asks_for_its_own_console_keeps_it(fresh, recorded):
    no_console.install(osname="nt", has_console=lambda: False)
    new_console = getattr(subprocess, "CREATE_NEW_CONSOLE", 0x10)
    _spawn(creationflags=new_console)
    assert recorded == [new_console]


@pytest.mark.parametrize("osname,console", [("posix", False), ("nt", True)])
def test_posix_and_a_studio_with_a_console_are_left_alone(fresh, recorded, osname, console):
    assert no_console.install(osname=osname, has_console=lambda: console) is False
    _spawn()
    assert recorded == [0]


def test_installing_twice_does_not_wrap_twice(fresh, recorded):
    no_console.install(osname="nt", has_console=lambda: False)
    no_console.install(osname="nt", has_console=lambda: False)
    _spawn()
    assert recorded == [FLAG]


@pytest.mark.skipif(sys.platform != "win32", reason="starts a real Windows process")
def test_a_real_child_still_runs_and_returns_its_output(fresh):
    no_console.install(osname="nt", has_console=lambda: False)
    out = subprocess.run(["cmd", "/c", "echo", "hidden"], capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.strip() == "hidden"
