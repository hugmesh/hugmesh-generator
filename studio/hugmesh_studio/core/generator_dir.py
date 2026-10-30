"""Which hugmesh-generator checkout the Studio drives (Qt-free, stdlib only).

The Studio is a front end over scripts in a checkout (``build-*.sh``, ``scripts/``,
``specs/``), and the MSI bundles none of them. A source run finds the checkout it lives
in, but the frozen Windows exe cannot: the old fallback was ``os.getcwd()``, which for the
Start Menu shortcut is the install folder, and nothing in the GUI could choose another.
So every build, cluster and go-live action there failed with "not found in
C:\\...\\HugMesh\\Image Studio".

Resolution order, first hit wins:
  1. ``--generator-dir`` (the caller passes it; argparse default is :func:`resolve`)
  2. ``$HUGMESH_GENERATOR_DIR``
  3. the checkout this source tree lives in (a source run)
  4. the folder the operator last picked in the GUI, saved under the Studio state dir
  5. the working directory
Steps 3 and 4 only count when the folder really is a checkout (:func:`is_checkout`).
"""
from __future__ import annotations

import os

from . import state_paths

ENV = "HUGMESH_GENERATOR_DIR"

#: The file that marks a hugmesh-generator checkout (every build starts from it).
MARKER = "build-x86-host-stage4.sh"

_SAVED_NAME = "generator-dir.txt"


def is_checkout(path: str) -> bool:
    return bool(path) and os.path.isfile(os.path.join(path, MARKER))


def saved_path() -> str:
    return os.path.join(state_paths.state_dir(), _SAVED_NAME)


def saved() -> str:
    """The folder last picked in the GUI, "" when none was (or it is unreadable)."""
    try:
        with open(saved_path(), encoding="utf-8-sig") as fh:
            return fh.read().strip()
    except (OSError, RuntimeError, UnicodeDecodeError):
        return ""


def save(path: str) -> None:
    target = saved_path()
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(os.path.abspath(path) + "\n")


def resolve(source_repo: str = "") -> str:
    """The default ``--generator-dir``. ``source_repo`` is the repo root the caller
    derives from its own ``__file__`` (the GUI and TUI entry points sit at different
    depths)."""
    env = os.environ.get(ENV, "").strip()
    if env:
        return os.path.abspath(env)
    if is_checkout(source_repo):
        return source_repo
    picked = saved()
    if is_checkout(picked):
        return picked
    return os.getcwd()


def not_a_checkout_message(path: str) -> str:
    return (f"{path} is not a hugmesh-generator checkout (it has no {MARKER}). The Studio "
            f"runs that checkout's scripts, and the Windows installer does not include "
            f"them. Choose the folder you cloned hugmesh-generator into.")
