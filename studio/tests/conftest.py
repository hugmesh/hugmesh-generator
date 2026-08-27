"""Make the hugmesh_studio package importable for the studio test suite.

These tests target the pure-Python core (config / keyzip / validate) and do NOT
need PySide6, so they run in plain CI without the GUI toolkit installed.
"""
import os
import sys

import pytest

# studio/ is the package root (contains hugmesh_studio/).
_STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _STUDIO_ROOT not in sys.path:
    sys.path.insert(0, _STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _isolate_studio_state_dir(monkeypatch, tmp_path):
    """Point EVERY test at a throwaway Studio state dir.

    Without this, any test that reaches a Studio state path with no override set
    resolves the default — the operator's live ``~/.hugmesh/studio`` — and writes
    there for real. That is not theoretical: ``test_local_mesh_bringup.py`` drives a
    real ``LocalMeshDialog`` and clicks its real ``preflight_btn``, and the resulting
    "Checking host readiness — FAILED" run log landed in the operator's actual log
    directory, interleaved with genuine GUI runs and indistinguishable from them.

    Only 40 of the suite's 171 files set the override themselves; this one autouse
    fixture covers the other 131 and, unlike a per-file setenv, cannot be forgotten
    by the next test that is added. Tests that need a specific state dir still set
    ``$HUGMESH_STUDIO_STATE_DIR`` in their own body — theirs runs later and wins.

    Paired with the guard in ``core/state_paths.state_dir()``, which refuses the
    home fallback outright while pytest is running: if this fixture is ever removed
    or bypassed, the suite fails loudly instead of quietly polluting a real home.
    """
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio-state"))


@pytest.fixture(autouse=True)
def _host_independent_build_defaults(monkeypatch):
    """Make the suite's host-aware build defaults (core/host_resources) deterministic
    on ANY test host: pin the jobs default to the historical 8 via its env override,
    clear any ambient memory-cap override, and pin BOTH meminfo seams — the
    per-process snapshot (_meminfo_cached: jobs default + cap) AND the per-call
    dispatch-time read (_meminfo_fresh: low-memory warnings) — to a canonical
    healthy 32 GiB reading (cap auto-derives, warnings stay quiet). Tests that
    exercise the formulas pass explicit env/meminfo (which win) or re-monkeypatch
    the relevant seam themselves."""
    from hugmesh_studio.core import host_resources
    monkeypatch.setenv(host_resources.JOBS_ENV, "8")
    monkeypatch.delenv(host_resources.MEMORY_ENV, raising=False)
    healthy = {"MemTotal": 32 * host_resources.GIB,
               "MemAvailable": 24 * host_resources.GIB,
               "SwapTotal": 4 * host_resources.GIB,
               "SwapFree": 4 * host_resources.GIB}
    monkeypatch.setattr(host_resources, "_meminfo_cached", lambda: dict(healthy))
    monkeypatch.setattr(host_resources, "_meminfo_fresh", lambda: dict(healthy))
