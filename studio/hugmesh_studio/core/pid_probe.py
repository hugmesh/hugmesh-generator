"""Is a pid a running process? Asked of the Windows API on Windows (Qt-free, a leaf).

``os.kill(pid, 0)`` is the POSIX probe and is NOT one on Windows: signal 0 there is
``CTRL_C_EVENT``, so CPython calls ``GenerateConsoleCtrlEvent`` instead of looking the
process up. From the windowed MSI exe that fails with a plain ``OSError`` for every pid,
dead or alive, and a caller that reads ``OSError`` as "exists, not ours" calls every
pid alive. The same probe as local_ai_status._pid_alive_windows, moved to a leaf
module so build_sessions can use it without importing local_ai_status (which imports
build_sessions). local_ai_status can delegate here too; that file is being reworked on
another branch, so it keeps its own copy until then.
"""
from __future__ import annotations


def alive_windows(pid: int) -> bool:
    """Is ``pid`` a running process, asked of the Windows API (never a signal)."""
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32                      # noqa: attribute only exists on Windows
    except (ImportError, AttributeError, OSError):
        return False
    query_limited, still_active, access_denied = 0x1000, 259, 5
    handle = kernel32.OpenProcess(query_limited, False, int(pid))
    if not handle:
        return kernel32.GetLastError() == access_denied      # exists, just not ours to inspect
    try:
        code = ctypes.c_ulong()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return True
        return code.value == still_active
    finally:
        kernel32.CloseHandle(handle)
