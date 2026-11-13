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


def cmdline_windows(pid: int) -> str | None:
    """The command line of process ``pid``, asked of the Windows API; None when it
    cannot be read (no such process, not ours to inspect, no Windows API here). The
    same reader as local_ai_status._cmdline_windows, here for view_doors.

    NtQueryInformationProcess(ProcessCommandLineInformation) needs only the limited
    query right, which a person holds on every process they started themselves."""
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32")      # own instances: the prototypes set
        ntdll = ctypes.WinDLL("ntdll")            # below touch no shared windll entry
    except (ImportError, AttributeError, OSError):
        return None
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    query = ntdll.NtQueryInformationProcess
    query.restype = ctypes.c_long
    query.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.ULONG,
                      ctypes.POINTER(wintypes.ULONG))

    class _UnicodeString(ctypes.Structure):
        _fields_ = [("Length", wintypes.USHORT), ("MaximumLength", wintypes.USHORT),
                    ("Buffer", ctypes.c_void_p)]

    query_limited, command_line_information = 0x1000, 60
    handle = kernel32.OpenProcess(query_limited, False, int(pid))
    if not handle:
        return None
    try:
        size = wintypes.ULONG(0)
        query(handle, command_line_information, None, 0, ctypes.byref(size))
        if not size.value:
            return None
        buf = ctypes.create_string_buffer(size.value)
        if query(handle, command_line_information, buf, size.value, ctypes.byref(size)) != 0:
            return None
        text = _UnicodeString.from_buffer(buf)
        return ctypes.wstring_at(text.Buffer, text.Length // 2) if text.Buffer else ""
    finally:
        kernel32.CloseHandle(handle)
