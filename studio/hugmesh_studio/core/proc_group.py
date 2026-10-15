"""Stop a spawned child *and everything it spawned*, on every platform we ship on.

Every long-running thing the Studio launches is a process TREE, not a process: a
build is ``sudo`` → ``bash`` → ``emerge`` → compilers, and a QEMU or local-stack run
is a script that spawns ``docker`` containers. Killing only the direct child leaves
the tree running — the visible symptom is a "Cancel" that returns immediately while
the machine stays pinned at 100%.

On POSIX the answer is the process GROUP: everything here is spawned with
``start_new_session=True``, which makes the child a session and group leader, so its
pgid equals its pid and one :func:`os.killpg` reaches the whole tree.

``os.killpg`` DOES NOT EXIST on Windows. It is not that it fails — the attribute is
absent, so a call raises ``AttributeError``, which the ``except OSError`` around every
one of these call sites does not catch. That is a crash on the cancel path, on the
platform the MSI installer targets. Windows has no process groups in the POSIX sense
either, so the equivalent is ``taskkill /T``, which walks the child tree.

This module exists so that reasoning lives in ONE place rather than being re-derived
(differently, and in two cases wrongly) at five call sites.
"""
from __future__ import annotations

import os
import signal
import subprocess

__all__ = ["terminate_group", "kill_group", "supports_process_groups"]

#: True where :func:`os.killpg` exists. Probed rather than inferred from
#: ``os.name``, so a platform that grows or loses the call is handled by fact.
_HAS_KILLPG = hasattr(os, "killpg")


def supports_process_groups() -> bool:
    """Whether process-group signalling is available on this interpreter."""
    return _HAS_KILLPG


def terminate_group(proc: "subprocess.Popen[object]") -> bool:
    """Ask a child and its whole tree to stop. Returns True if a stop was issued.

    Never raises: a cancel path that can throw turns "the user pressed Cancel" into
    "the GUI reported an error", and by the time we are here the caller has already
    decided the process should die. A process that has ALREADY exited counts as
    stopped and returns True — that race is normal, not a failure.
    """
    return _signal_group(proc, signal.SIGTERM, hard=False)


def kill_group(proc: "subprocess.Popen[object]") -> bool:
    """Force a child and its whole tree to stop. Same contract as
    :func:`terminate_group`, for the escalation after a grace period."""
    return _signal_group(proc, signal.SIGKILL if _HAS_KILLPG else signal.SIGTERM, hard=True)


def _signal_group(proc: "subprocess.Popen[object]", sig: int, *, hard: bool) -> bool:
    if proc.poll() is not None:
        return True  # already gone

    if _HAS_KILLPG:
        try:
            os.killpg(proc.pid, sig)
            return True
        except ProcessLookupError:
            return True  # exited between the poll above and the signal
        except OSError:
            pass  # no session was created after all — fall through to the child
    else:
        # Windows: taskkill /T walks the child tree that POSIX would have reached
        # through the process group. /F is the SIGKILL equivalent.
        args = ["taskkill", "/PID", str(proc.pid), "/T"]
        if hard:
            args.append("/F")
        try:
            subprocess.run(
                args,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                # A cancel must not itself hang. If taskkill has not returned in
                # 10 s something is badly wrong and the direct-child fallback below
                # is a better use of the time.
                timeout=10,
            )
            return True
        except (OSError, subprocess.SubprocessError):
            pass  # taskkill missing or hung — fall through

    # Last resort: the direct child only. Leaves grandchildren behind, which is
    # worse than a group kill and better than nothing.
    try:
        if hard:
            proc.kill()
        else:
            proc.terminate()
        return True
    except (OSError, ValueError):
        return False
