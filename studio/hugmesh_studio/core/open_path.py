"""Open a folder in the operator's file manager — Qt-free, and VERIFIED where the
platform lets it be (issue #689; the running-mesh monitor of #651 reuses this).

THE API, kept small on purpose:

    open_folder(path, last_resort=None, host=None) -> OpenResult

``OpenResult`` says whether anything took the request (``opened``), whether that
was confirmed by the opener's own exit status (``verified``), which mechanism was
used (``how``), the path, and a plain-words ``reason`` the GUI shows inline when
the open is unverified or failed. ``last_resort`` is the ONE hook for a GUI: a
callable ``path -> bool`` tried after every command-line opener has failed (the
Studio passes ``QDesktopServices.openUrl``). Its True is reported as UNVERIFIED,
never as success. ``host`` is a :class:`Host` — detected from the machine by
default, handed in by tests so a WSL or Windows path can be driven on a Linux
test box with no subprocess at all.

WHAT ``core/login_preview.open_in_browser`` ALREADY LEARNED, reused here rather
than re-learned (the "preview button does nothing" post-mortem, and the amber
note in ``gui/pages/_logintheme._open_preview``):

  * every launch mechanism reports DISPATCH, not DISPLAY. ``xdg-open`` exits 0 only
    after a successful handoff and exits non-zero (2, 3, 4) when no handler exists
    or the handler fails — but only if somebody WAITS for it. So each command-line
    opener is waited on for ``OPENER_WAIT_S`` (the same grace ``open_in_browser``
    uses): exit 0 is a verified handoff, non-zero means THAT opener failed and the
    next one is tried, still-running is reported as ASKED BUT UNCONFIRMED (it is
    usually the file manager itself, but a stuck prompt looks identical);
  * the Qt fallback comes LAST and is labelled unverified, so the note can say
    "dispatched, not confirmed" instead of lying green;
  * ``open_folders`` (Open all) shares ONE waiting budget across every folder, so
    25 folders can never mean 25 waits;
  * a total miss returns the reason and the GUI offers the path to copy — never a
    silent no-op.

PLATFORMS (``core/platform_info`` decides which one this is):

  * Linux (X11 or Wayland alike): ``xdg-open`` then ``gio open``, verified.
  * WSL2: the Linux openers first (WSLg or wslu may answer, verified); then
    ``explorer.exe`` on the Windows spelling of the path (``wslpath -w``, else
    ``\\\\wsl$\\<distro>\\...``). explorer.exe exits 1 even when it opened the
    folder, so that leg is reported as dispatched-but-unverified, honestly.
  * Windows (a native Python): ``os.startfile`` — it raises when no association
    exists, so not raising is a real (if weak) confirmation.
  * macOS: ``open``, verified by its exit status.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable

from . import platform_info
# ONE grace period for every verified opener in the Studio — the number
# open_in_browser measured for xdg-open/gio, not a second guess at it.
from .login_preview import _OPENER_WAIT_S as OPENER_WAIT_S

__all__ = ["OpenResult", "Host", "open_folder", "open_folders", "OPENER_WAIT_S",
           "HOST_LINUX", "HOST_WSL", "HOST_WINDOWS", "HOST_DARWIN"]

HOST_LINUX = "linux"
HOST_WSL = "wsl"
HOST_WINDOWS = "windows"
HOST_DARWIN = "darwin"

#: A command runner: ``run(argv, capture, wait_s) -> (exit_code | None, stdout)``.
#: None for the exit code means the command was still running after ``wait_s``
#: seconds (0 = do not wait at all). The default launches a real process; tests
#: inject a table.
Runner = Callable[[list[str], bool, float], "tuple[int | None, str]"]

#: The clock the shared "Open all" wait budget is spent against; a test replaces it.
_now = time.monotonic


@dataclass(frozen=True)
class OpenResult:
    """What happened to one open request. ``opened`` and ``verified`` are two
    different facts: xdg-open exiting 0 is both, QDesktopServices.openUrl returning
    True is only the first. ``reason`` is empty on a verified success and otherwise
    says, in plain words, what the operator should make of it."""
    opened: bool
    verified: bool
    how: str
    path: str
    reason: str = ""

    def summary(self) -> str:
        """One line for a log or a status label."""
        if self.opened and self.verified:
            return f"opened {self.path} ({self.how})"
        if self.opened:
            return f"asked to open {self.path} ({self.how}, unconfirmed)"
        return f"could not open {self.path} ({self.reason})"


def _run_and_wait(argv: list[str], capture: bool,
                  wait_s: float = OPENER_WAIT_S) -> "tuple[int | None, str]":
    """Launch ``argv`` and wait up to ``wait_s`` for its exit status. A launch
    failure (missing binary, EACCES) reads as exit 127 so the caller moves on to
    the next opener instead of raising out of a click handler."""
    try:
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
    except Exception:                  # noqa: BLE001 — any launch failure = "not this one"
        return 127, ""
    try:
        out, _ = proc.communicate(timeout=max(0.0, wait_s))
    except subprocess.TimeoutExpired:
        # Deliberately NOT killed: a still-running opener is the file manager
        # itself, and killing it would close the window we just opened.
        return None, ""
    return proc.returncode, (out or b"").decode("utf-8", "replace")


@dataclass(frozen=True)
class Host:
    """The facts :func:`open_folder` needs about the machine, plus the two
    side-effecting calls it makes, so a test can replace all of them."""
    kind: str
    which: Callable[[str], "str | None"] = shutil.which
    run: Runner = _run_and_wait
    #: ``os.startfile`` where it exists (Windows); None elsewhere.
    startfile: "Callable[[str], object] | None" = None
    #: WSL_DISTRO_NAME, for the ``\\wsl$\<distro>`` spelling when wslpath is absent.
    wsl_distro: str = ""
    environ: dict = field(default_factory=lambda: os.environ, repr=False)

    @classmethod
    def detect(cls) -> "Host":
        if os.name == "nt":
            return cls(kind=HOST_WINDOWS,
                       startfile=getattr(os, "startfile", None))
        if sys.platform == "darwin":
            return cls(kind=HOST_DARWIN)
        is_wsl, _version = platform_info.detect_wsl()
        return cls(kind=HOST_WSL if is_wsl else HOST_LINUX,
                   wsl_distro=os.environ.get("WSL_DISTRO_NAME", "") if is_wsl else "")


def _windows_spelling(path: str, host: Host) -> str:
    """The path as explorer.exe wants it. ``wslpath -w`` is authoritative (it knows
    the distro's mount table); without it, the documented ``\\\\wsl$\\<distro>``
    UNC form, which every WSL2 kernel serves. "" when neither is available."""
    wslpath = host.which("wslpath")
    if wslpath:
        code, out = host.run([wslpath, "-w", path], True, OPENER_WAIT_S)
        if code == 0 and out.strip():
            return out.strip()
    if host.wsl_distro:
        return "\\\\wsl$\\" + host.wsl_distro + path.replace("/", "\\")
    return ""


def open_folder(path: str, last_resort: "Callable[[str], bool] | None" = None,
                host: "Host | None" = None,
                wait_s: float = OPENER_WAIT_S) -> OpenResult:
    """Open ``path`` (a directory) in the desktop's file manager. Never raises.

    ``wait_s`` is how long to wait on each command-line opener for its exit status;
    0 hands the request over and does not wait (the answer is then unconfirmed).

    A path that is not a directory is refused up front — every opener below would
    otherwise hand it to a browser or an editor, which "works" and is wrong."""
    host = host or Host.detect()
    if not os.path.isdir(path):
        return OpenResult(False, False, "none", path,
                          "the folder does not exist" if not os.path.exists(path)
                          else "the path is not a folder")
    tried: list[str] = []

    if host.kind == HOST_WINDOWS and host.startfile is not None:
        try:
            host.startfile(path)
            return OpenResult(True, True, "os.startfile", path)
        except Exception as exc:       # noqa: BLE001 — "no association" is the common one
            tried.append(f"os.startfile failed ({exc})")

    if host.kind == HOST_DARWIN:
        candidates = [["open", path]]
    elif host.kind in (HOST_LINUX, HOST_WSL):
        candidates = [["xdg-open", path], ["gio", "open", path]]
    else:
        candidates = []

    for argv in candidates:
        exe = host.which(argv[0])
        if not exe:
            tried.append(f"{argv[0]} is not installed")
            continue
        code, _out = host.run([exe, *argv[1:]], False, wait_s)
        if code == 0:
            return OpenResult(True, True, f"{argv[0]} exited 0", path)
        if code is None:
            # Not "verified": a file manager that stays up and an opener stuck on a
            # prompt look the same from here. The folder was asked for; nobody
            # confirmed a window, so the GUI keeps the path to copy on screen.
            if wait_s > 0:
                how = f"{argv[0]} still running after {wait_s:g}s"
                why = ("That is normal when it is the file manager itself, but "
                       "nothing confirmed a window opened")
            else:
                how = f"{argv[0]} started, not waited for"
                why = ("It was started without waiting for its answer, so "
                       "nothing confirmed a window opened")
            return OpenResult(True, False, how, path,
                              why + "; if none appeared, copy the path.")
        # non-zero: THIS opener says nothing took the folder (xdg-open: 2/3/4 — no
        # handler, missing tool, action failed). On to the next one.
        tried.append(f"{argv[0]} exited {code}")

    if host.kind == HOST_WSL:
        exe = host.which("explorer.exe")
        win = _windows_spelling(path, host) if exe else ""
        if exe and win:
            host.run([exe, win], False, wait_s)
            # explorer.exe returns 1 whether or not it opened anything, so its exit
            # status proves nothing either way: dispatched, not confirmed.
            return OpenResult(True, False, "explorer.exe", path,
                              "explorer.exe was asked to open "
                              f"{win} — it does not report success, so look for "
                              "the Explorer window; if none appeared, copy the path.")
        tried.append("explorer.exe is not reachable (no Windows interop)" if not exe
                     else "the path has no Windows spelling (no wslpath, no "
                          "WSL_DISTRO_NAME)")

    if last_resort is not None:
        try:
            dispatched = bool(last_resort(path))
        except Exception as exc:       # noqa: BLE001 — a hook must not break the click
            dispatched = False
            tried.append(f"the desktop fallback raised ({exc})")
        if dispatched:
            return OpenResult(True, False, "desktop fallback (QDesktopServices.openUrl)",
                              path,
                              "the desktop reports the request was dispatched, not "
                              "that a file manager appeared; if nothing opened, "
                              "copy the path.")
        if not tried or not tried[-1].startswith("the desktop fallback"):
            tried.append("the desktop fallback declined it")

    return OpenResult(False, False, "none", path,
                      "no file manager took the request (" + "; ".join(tried) + ")"
                      if tried else "no opener is available on this platform")


def open_folders(paths: "list[str]",
                 last_resort: "Callable[[str], bool] | None" = None,
                 host: "Host | None" = None,
                 budget_s: float = OPENER_WAIT_S) -> "list[OpenResult]":
    """Open several folders, spending ONE shared waiting budget across all of them.

    ``open_folder`` waits up to OPENER_WAIT_S on each command-line opener, and an
    opener that is the file manager never exits — so a loop over 25 folders on the
    window's thread froze the Studio for about 75 seconds. Here the budget is spent
    in order: a quick opener that exits 0 costs almost nothing and each folder after
    it keeps the rest of the budget (so they are still verified); once a slow opener
    has used it up, the later folders are handed over without waiting and come back
    as asked-but-unconfirmed. The total wait is therefore at most ``budget_s``.

    If the FIRST folder that really is a folder cannot be opened at all (no opener,
    no handler), the rest would fail the same way: the walk stops there. A path that
    vanished between the page being drawn and the click is reported on its own and
    does not count as that first attempt, so it cannot skip the folders after it."""
    host = host or Host.detect()
    left = max(0.0, budget_s)
    results: list[OpenResult] = []
    attempted = 0
    for path in paths:
        if not os.path.isdir(path):
            results.append(open_folder(path, last_resort=last_resort, host=host,
                                       wait_s=0))
            continue
        attempted += 1
        started = _now()
        res = open_folder(path, last_resort=last_resort, host=host, wait_s=left)
        results.append(res)
        left = max(0.0, left - (_now() - started))
        if not res.opened and attempted == 1:
            break
    return results
