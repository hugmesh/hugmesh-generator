"""Running a host command from inside the Flatpak sandbox (Qt-free, stdlib only).

The Flatpak of the Studio (packaging/flatpak/org.hugmesh.ImageStudio.yml) has no
``docker`` and no ``ollama`` inside its sandbox, and no Docker socket. It does have
``--talk-name=org.freedesktop.Flatpak``, which lets it run a command ON THE HOST with
``flatpak-spawn --host``, and ``--share=network``, so a loopback Ollama on the host
answers it over HTTP like any other client (measured 2026-11-09 inside the installed
bundle: ``/api/tags`` and a streamed ``/api/pull`` both worked from the sandbox,
``flatpak-spawn --host docker version`` answered, ``command -v ollama`` did not exist
inside).

This module is that bridge, in one place:

* :func:`in_flatpak` says whether this process is inside a Flatpak sandbox (the file
  ``/.flatpak-info`` exists in every one).
* :func:`host_argv` turns ``["docker", "ps"]`` into ``["flatpak-spawn", "--host",
  "docker", "ps"]`` there, and leaves it alone anywhere else.
* :func:`host_which` asks the HOST whether a command exists.
* :func:`host_state_dir` names the local-AI state folder the HOST's
  ``scripts/local-ai.sh`` writes: inside the sandbox ``XDG_STATE_HOME`` is the app's
  private ``~/.var/app/<id>/.local/state``, so a Studio that honoured it never saw a
  worker started on the host.

Nothing here talks to anything but this machine.
"""
from __future__ import annotations

import os
import subprocess
from typing import Callable, Optional, Sequence

__all__ = ["INFO_FILE", "SPAWN", "in_flatpak", "host_argv", "host_which", "host_state_dir",
           "host_env_defaults", "FORWARD_PREFIXES"]

#: Present in every Flatpak sandbox (flatpak(1), "Sandbox"); never outside one.
INFO_FILE = "/.flatpak-info"
SPAWN = ("flatpak-spawn", "--host")

#: The variables a host command started from the sandbox needs to see. flatpak-spawn
#: --host does NOT pass the caller's environment through: each one is named with
#: ``--env=``. Only these prefixes are forwarded, so nothing else of the sandbox's
#: environment reaches the host.
FORWARD_PREFIXES = ("OLLAMA_", "LOCAL_AI_", "HUGMESH_", "AGENT")

Exists = Callable[[str], bool]


def in_flatpak(exists: Optional[Exists] = None) -> bool:
    """True inside a Flatpak sandbox. ``exists`` is ``os.path.exists`` unless a test
    passes another."""
    return bool((exists or os.path.exists)(INFO_FILE))


def host_argv(argv: Sequence[str], env: Optional[dict] = None, *,
              exists: Optional[Exists] = None) -> "list[str]":
    """``argv`` as it must be spawned to run on the host: unchanged outside a Flatpak,
    ``flatpak-spawn --host [--env=K=V ...] argv`` inside one. ``env`` (optional) names
    the variables to forward; only those under :data:`FORWARD_PREFIXES` are."""
    argv = list(argv)
    if not in_flatpak(exists):
        return argv
    fwd = [f"--env={k}={v}" for k, v in sorted((env or {}).items())
           if k.startswith(FORWARD_PREFIXES) and "\n" not in str(v)]
    return [*SPAWN, *fwd, *argv]


def host_which(cmd: str, *, exists: Optional[Exists] = None,
               run: Optional[Callable] = None, which: Optional[Callable] = None) -> str:
    """The host's path of ``cmd``, or "". Outside a Flatpak this is ``shutil.which``;
    inside one it asks the host (``command -v``), because the sandbox's own PATH has
    neither docker nor ollama. Never raises."""
    if not in_flatpak(exists):
        import shutil
        return (which or shutil.which)(cmd) or ""
    argv = [*SPAWN, "sh", "-c", 'command -v -- "$1"', "sh", cmd]
    try:
        p = (run or subprocess.run)(argv, capture_output=True, text=True, timeout=10,
                                    stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    out = (getattr(p, "stdout", "") or "").strip().splitlines()
    return out[-1] if getattr(p, "returncode", 1) == 0 and out else ""


def host_state_dir(env: Optional[dict] = None) -> str:
    """The folder ``scripts/local-ai.sh`` uses ON THE HOST when nothing overrides it:
    ``~/.local/state/hugmesh/local-ai``. Inside the sandbox ``$HOME`` is the real home
    (and ``--filesystem=host`` makes it readable), while ``$XDG_STATE_HOME`` is the
    app's own private folder, so that variable is deliberately not read here."""
    env = os.environ if env is None else env
    home = env.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, ".local", "state", "hugmesh", "local-ai")


def host_env_defaults(env: dict, *, exists: Optional[Exists] = None) -> dict:
    """``env`` with ``HUGMESH_LOCAL_AI_DIR`` set to :func:`host_state_dir` when this is
    a Flatpak and nothing set it already, so the Studio reads the same worker, queue
    and drafts the host's script writes. Changes ``env`` in place and returns it."""
    if in_flatpak(exists) and not env.get("HUGMESH_LOCAL_AI_DIR"):
        env["HUGMESH_LOCAL_AI_DIR"] = host_state_dir(env)
    return env
