"""Go Live's provider list without bash (core/golive_driver.py `_registry_providers`).

On native Windows the bash driver cannot run, so the Studio reads the provider
registry itself; the wizard and the TUI then offer the real providers and preview a
plan, and only the verbs that execute the driver are refused (operator, 2026-11-04:
"fix this too" — the parity test that could not build its wizard on Windows).
The reader must say exactly what the driver's own `list` says."""
import os
import shutil

import pytest

from hugmesh_studio.core import golive_driver, platform_info
from hugmesh_studio.core.golive_driver import GoLiveDriver

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _rows(providers):
    return [(p.id, p.mechanism, p.status, p.model, p.title) for p in providers]


@pytest.mark.skipif(os.name == "nt" or not shutil.which("bash"),
                    reason="needs the bash driver to compare against")
def test_the_registry_reader_says_what_the_drivers_own_list_says():
    d = GoLiveDriver(GENERATOR_DIR, is_root=False)
    assert _rows(d._registry_providers()) == _rows(d._load_providers())
    assert d._registry_providers()                             # never vacuously equal


def test_a_host_that_cannot_run_the_driver_still_offers_every_provider(monkeypatch):
    monkeypatch.setattr(golive_driver.platform_info, "native_windows_blocker",
                        lambda action, osname=None, runs="": "needs WSL2")
    monkeypatch.setattr(golive_driver.subprocess, "run",
                        lambda *a, **k: pytest.fail("the bash driver was run"))
    d = GoLiveDriver(GENERATOR_DIR, is_root=False)
    ids = [p.id for p in d.providers()]
    assert ids[:2] == ["cloudflare-tunnel", "byo-domain"] and "tor-onion" in ids
    assert d.provider("byo-domain").model == "public-dns"
    assert "WSL2" in d.status_text()                             # still says why it cannot run


def test_no_registry_means_no_provider_not_a_crash(monkeypatch, tmp_path):
    monkeypatch.setattr(golive_driver.platform_info, "native_windows_blocker",
                        lambda action, osname=None, runs="": "needs WSL2")
    assert GoLiveDriver(str(tmp_path), is_root=False).providers() == []
