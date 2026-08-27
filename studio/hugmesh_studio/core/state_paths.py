"""The ONE place the Studio state dir is resolved (Qt-free, stdlib only).

Every Studio state file — the run logs the Local Mesh page writes, the build
session records, the crash logs, the tray's build-status JSON, the first-run
stamp — hangs off a single directory: ``$HUGMESH_STUDIO_STATE_DIR``, or
``~/.hugmesh/studio`` when that is unset.

Historically FIVE modules (``instance``, ``build_sessions``, ``crashlog``,
``tray``, and ``first_run`` via ``instance``) each carried their own private copy
of that ``os.environ.get(...) or os.path.expanduser("~")`` expression. Five copies
meant isolation was per-call-site, and the fallback was silent: a test that drove
a real widget without setting the override wrote **into the operator's live
``~/.hugmesh/studio``**, indistinguishably from a real GUI run. That is not
hypothetical — ``tests/test_local_mesh_bringup.py`` clicks a real
``preflight_btn`` and its readiness failure ("cold build required but the local
maven registry is not up", a string that exists nowhere in production) landed in
the operator's real log dir, mixed in with genuine run logs.

So this module owns the resolution, and adds the piece the five copies could not
have: while pytest is running, the home fallback is **refused** rather than
silently taken. A suite that forgets to isolate its state dir now fails loudly at
the first write instead of quietly polluting the operator's home directory, and a
sixth call site cannot re-open the hole.
"""
from __future__ import annotations

import os
import sys

__all__ = [
    "ALLOW_HOME_ENV", "STATE_DIR_ENV", "home_state_dir", "state_dir",
    "under_pytest",
]

#: The override every Studio state path honours. Set it and nothing else matters.
STATE_DIR_ENV = "HUGMESH_STUDIO_STATE_DIR"

#: Deliberate opt-out for the handful of tests whose SUBJECT is the home fallback
#: itself. Set to ``"1"`` to take the ``~/.hugmesh/studio`` default under pytest.
#: Nothing that actually writes state should ever set this.
ALLOW_HOME_ENV = "HUGMESH_STUDIO_ALLOW_HOME_STATE_DIR"


def home_state_dir() -> str:
    """The unguarded default: ``~/.hugmesh/studio``. This is the operator's real,
    live state dir — the thing the pytest guard exists to keep tests out of."""
    return os.path.join(os.path.expanduser("~"), ".hugmesh", "studio")


def under_pytest() -> bool:
    """True while a pytest process is running this code.

    Both signals are needed. ``PYTEST_CURRENT_TEST`` is set only during a test's
    setup/call/teardown, so it misses module-level and collection-time writes;
    ``"pytest" in sys.modules`` catches those but is merely "pytest was imported".
    Together they cover the whole run. The Studio application itself never imports
    pytest, so neither fires in production.
    """
    return "pytest" in sys.modules or "PYTEST_CURRENT_TEST" in os.environ


def state_dir() -> str:
    """The Studio state dir.

    ``$HUGMESH_STUDIO_STATE_DIR`` wins whenever it is set. Otherwise the default is
    ``~/.hugmesh/studio`` — except under pytest, where taking that default would
    mean writing into the operator's live state dir, and so raises instead.

    :raises RuntimeError: under pytest with no override set (and no explicit
        :data:`ALLOW_HOME_ENV` opt-out).
    """
    override = os.environ.get(STATE_DIR_ENV)
    if override:
        return override
    if under_pytest() and os.environ.get(ALLOW_HOME_ENV) != "1":
        raise RuntimeError(
            f"refusing to use the operator's live state dir {home_state_dir()!r} "
            f"while pytest is running: this test would write real Studio state "
            f"(run logs, session records, crash logs) into the operator's home. "
            f"Set ${STATE_DIR_ENV} to a tmp_path — studio/tests/conftest.py does "
            f"this for the whole suite via the autouse `_isolate_studio_state_dir` "
            f"fixture, so seeing this means that fixture was removed, overridden, "
            f"or bypassed. If this test's SUBJECT really is the home fallback, set "
            f"${ALLOW_HOME_ENV}=1 for it and do not write anything."
        )
    return home_state_dir()
