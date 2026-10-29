"""The Studio dock's own settings file (Qt-free, stdlib only).

One small JSON file in the Studio state directory holds what the bottom panel
remembers between runs. It was ``{"expanded": bool}`` and only the dock wrote it; it
now also says which Ollama the local assistant talks to and where the person's own
checkouts are. Every key is optional, an unreadable file reads as empty, and a write
MERGES into what is there, so one setting never wipes another.

    expanded        bool   the panel was open when the Studio last closed it
    tab             str    the panel's last tab (see gui/_local_ai_dock.py)
    ollama          str    "system" (the Ollama this machine runs) or "docker"
                           (the Studio's own container, core/ollama_docker.py)
    checkouts_dir   str    the folder that holds the person's hugmesh-* checkouts;
                           "" means the default (core/agent_context.py)

Nothing secret is ever written here: the file is a convenience, and a reader that
gets garbage falls back to the defaults.
"""
from __future__ import annotations

import json
import os

from . import state_paths

__all__ = ["FILE_NAME", "settings_path", "load", "update", "get"]

#: The dock's file name since it was first written; kept so an existing choice survives.
FILE_NAME = "local-ai-dock.json"


def settings_path() -> str | None:
    """The settings file, or None when no state directory can be named (a test run
    without an isolated state dir refuses the real home on purpose)."""
    try:
        return os.path.join(state_paths.state_dir(), FILE_NAME)
    except Exception:                       # noqa: BLE001 — a convenience, never a crash
        return None


def load() -> dict:
    """Everything stored, or {} when there is no file or it cannot be read."""
    path = settings_path()
    try:
        with open(path or "", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def get(key: str, default=None):
    return load().get(key, default)


def update(**values) -> bool:
    """Merge ``values`` into the file (atomically). False when nothing could be written;
    the caller carries on, because a setting that did not stick is not worth a message."""
    path = settings_path()
    if not path:
        return False
    data = load()
    data.update(values)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, sort_keys=True)
        os.replace(tmp, path)
    except OSError:
        return False
    return True
