"""HugMesh Image Studio — package metadata + Studio-local runtime prefs.

Deliberately dependency-free (stdlib only): this module is imported on every
``import hugmesh_studio.*`` and the headless (Qt-free) build channels rely on it
staying importable with no GUI toolkit present.
"""
from __future__ import annotations

import os

__version__ = "0.3.0-beta.3"

# Opt-in expert mode. Gates power-user affordances that would only confuse someone
# building a single personal image (the whole-release Fleet build, the Qt-binding
# console line, …) behind an explicit flag — mirrors app.py's --dev env-flag pattern.
ADVANCED_ENV = "HUGMESH_STUDIO_ADVANCED"


def _env_flag(name: str) -> bool:
    """Truthy env-var check ("1"/"true"/"yes"/"on", case-insensitive)."""
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


def advanced_mode() -> bool:
    """True when Studio should surface power-user / expert affordances. Off by default;
    opt in with ``$HUGMESH_STUDIO_ADVANCED=1``. The ``--fleet`` CLI entry stays
    available regardless, so nothing is lost when it is off."""
    return _env_flag(ADVANCED_ENV)
