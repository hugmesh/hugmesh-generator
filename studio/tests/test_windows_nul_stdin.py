"""NUL is not a terminal on Windows (part of the Windows contract).

Found 2026-11-13 on Windows 11: ``python -m hugmesh_studio.core.nvd_key set`` with
stdin from NUL (``stdin=DEVNULL``, ``< NUL``, a job with no input) hung instead of
refusing, because NUL is a character device, ``isatty()`` says True, and ``getpass``
then waits on the console keyboard. ``platform_info.is_terminal`` asks the console.
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import types

import pytest

from hugmesh_studio.core import nvd_key, platform_info

STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class _Stream:
    def __init__(self, tty=True, fd=7):
        self._tty, self._fd = tty, fd

    def isatty(self):
        return self._tty

    def fileno(self):
        if self._fd is None:
            raise io.UnsupportedOperation("fileno")
        return self._fd


@pytest.fixture
def fake_msvcrt(monkeypatch):
    mod = types.SimpleNamespace(get_osfhandle=lambda fd: 1000 + fd)
    monkeypatch.setitem(sys.modules, "msvcrt", mod)
    return mod


def test_on_windows_a_tty_the_console_disowns_is_not_a_terminal(fake_msvcrt):
    asked = []
    no_console = lambda h: asked.append(h) or False                    # noqa: E731
    assert not platform_info.is_terminal(_Stream(), osname="nt", console_mode=no_console)
    assert asked == [1007]


def test_on_windows_a_real_console_is_a_terminal(fake_msvcrt):
    assert platform_info.is_terminal(_Stream(), osname="nt", console_mode=lambda h: True)


def test_on_windows_a_stream_without_a_descriptor_keeps_its_own_word(fake_msvcrt):
    never = lambda h: pytest.fail("no handle to ask about")             # noqa: E731
    assert platform_info.is_terminal(_Stream(fd=None), osname="nt", console_mode=never)
    assert not platform_info.is_terminal(_Stream(tty=False, fd=None), osname="nt",
                                         console_mode=never)


def test_posix_hosts_take_isatty_as_it_is():
    never = lambda h: pytest.fail("POSIX never asks a console")         # noqa: E731
    assert platform_info.is_terminal(_Stream(), osname="posix", console_mode=never)
    assert not platform_info.is_terminal(_Stream(tty=False), osname="posix",
                                         console_mode=never)
    assert not platform_info.is_terminal(None, osname="posix")


def test_nvd_key_refuses_a_nul_stdin_instead_of_prompting(monkeypatch):
    monkeypatch.setattr(nvd_key, "is_terminal", lambda s: False)
    prompted = []
    with pytest.raises(nvd_key.NvdKeyError) as exc:
        nvd_key._read_key_source("", _Stream(), prompt=lambda p: prompted.append(p) or "x")
    assert "refusing: no key source" in str(exc.value) and prompted == []


@pytest.mark.skipif(os.name != "nt", reason="the real NUL device")
def test_the_real_nul_device_is_not_a_terminal_on_windows():
    with open(os.devnull, encoding="utf-8") as nul:
        assert nul.isatty()                       # what fooled the old check
        assert not platform_info.is_terminal(nul)


@pytest.mark.skipif(os.name != "nt", reason="the real NUL device")
def test_nvd_key_set_with_stdin_from_nul_refuses_and_returns_on_windows():
    env = dict(os.environ, PYTHONPATH=STUDIO)
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.nvd_key", "set"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env,
                       cwd=STUDIO, timeout=60)
    assert r.returncode == 2 and "refusing: no key source" in r.stderr
