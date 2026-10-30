"""No console window for the windowed Studio's child processes (Windows; Qt-free).

The MSI's hugmesh-studio.exe is a WINDOWED program: it owns no console. Windows gives a
console program (docker, kubectl, git, powershell, cmd) started from such a process a
NEW console window of its own, so every background probe flashed a black window on
screen and took focus. The Studio polls Docker every few seconds, so on Windows 11 (2026-10-29)
the desktop was a stream of cmd windows appearing and disappearing.

One fix at startup, not ~100 call sites: :func:`install` makes ``subprocess.Popen``
(and with it ``run``, ``check_output`` and ``call``) add ``CREATE_NO_WINDOW`` whenever the
caller passed no ``creationflags`` of its own. A caller that asks for a console on
purpose (``CREATE_NEW_CONSOLE``, to open a terminal for the user) passes flags and is left
alone. It does nothing on POSIX, and nothing when the Studio HAS a console
(hugmesh-studio-cli.exe, or ``python -m hugmesh_studio`` in a terminal), where children
share that console and no window appears.
"""
from __future__ import annotations

import os
import subprocess

#: Set once installed, so a second call does not wrap the wrapper.
_INSTALLED = False


def _has_console() -> bool:
    try:
        import ctypes
        return bool(ctypes.windll.kernel32.GetConsoleWindow())   # noqa: Windows only
    except (ImportError, AttributeError, OSError):
        return True     # cannot tell: leave the process as it is


def install(*, osname: str | None = None, has_console=None) -> bool:
    """Make child processes windowless; True when the hook is (now) in place.
    ``osname`` / ``has_console`` are for tests."""
    global _INSTALLED
    if _INSTALLED:
        return True
    if (osname or os.name) != "nt":
        return False
    if (has_console or _has_console)():
        return False
    flag = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
    original = subprocess.Popen.__init__

    def __init__(self, *args, **kwargs):
        if not kwargs.get("creationflags"):
            kwargs["creationflags"] = flag
        original(self, *args, **kwargs)

    __init__.__wrapped__ = original      # type: ignore[attr-defined]
    subprocess.Popen.__init__ = __init__  # type: ignore[method-assign]
    _INSTALLED = True
    return True
