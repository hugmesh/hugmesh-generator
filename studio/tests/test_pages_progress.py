"""ProgressPage (design 3.13) — the terminal build screen driven by WorklistDriver.

Drives the REAL page on Qt's offscreen platform with BuildDriver + gen-provision-keys mocked
(no real build runs), then flushes the worker thread's queued signals and asserts the page
lifecycle: one row per image, Finish gated until every row is terminal, failure-tolerant
continue (a failed image does not abort the rest), Stop-all, and the once-per-worklist footer
(mesh manifest + per-node key-zips).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core.config import Domain, ImageConfig, User    # noqa: E402
from snapdragon_studio.core.platform_info import HostInfo              # noqa: E402
from snapdragon_studio.core import worklist_driver as wd               # noqa: E402
from snapdragon_studio.core.worklist import (                         # noqa: E402
    WorklistConfig, WorklistEntry, synthesize)
from snapdragon_studio.gui import wizard as wizard_mod                 # noqa: E402
from snapdragon_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="snapdragon-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="snapdragon-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["snapdragon-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


# ── fakes (no real build / key generation) ───────────────────────────────────────────
def _install_fake_builddriver(monkeypatch, codes=None, on_run=None):
    codes = codes or {}

    class FakeBuildDriver:
        def __init__(self, gen, host):
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            if on_line:
                on_line(f"==> building {cfg.role}")
            if on_run:
                on_run(self, cfg)
            return codes.get(cfg.role, 0)

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)


def _install_fake_genkeys(monkeypatch):
    class FakeProc:
        def __init__(self):
            self.stdout = iter(["generating keys"])

        def wait(self):
            return 0

    monkeypatch.setattr(wd.subprocess, "Popen", lambda cmd, **kw: FakeProc())


# ── helpers ───────────────────────────────────────────────────────────────────────────
def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _run_to_completion(qapp, page, timeout_ms=5000):
    """Join the worker thread, then pump the event loop so its queued signals land."""
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


def _mesh_base(tmp_path):
    b = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    b.domains = [Domain(name="acme.example", title="Acme")]
    b.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
    return b


def _mesh_worklist(tmp_path, roles=(("pki", "x86"), ("be", "rpi5"),
                                    ("rpi5-desktop", "rpi5"))):
    return WorklistConfig(base=_mesh_base(tmp_path),
                          entries=[WorklistEntry(role=r, platform=p) for r, p in roles])


def _prime(wiz, worklist, generate_keys=True):
    wiz.worklist = worklist
    wiz.build_backend = None
    wiz.generate_node_keys = generate_keys


# ── tests ──────────────────────────────────────────────────────────────────────────────
def test_finish_disabled_before_any_build_runs(wiz):
    page = _progress_page(wiz)
    assert not page.isComplete()          # nothing terminal yet -> Finish disabled


def test_no_worklist_completes_immediately(wiz):
    _prime(wiz, None)
    page = _progress_page(wiz)
    page.initializePage()
    assert page._rows == []
    assert page.isComplete()


def test_single_entry_standalone_run(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert len(page._rows) == 1
    assert page._rows[0].terminal
    assert page.isComplete()
    assert page.driver.results[0].status == "ok"
    assert page._rows[0].bar.value() == 100


def test_all_succeed_rows_terminal_and_finish_enabled(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    assert len(page._rows) == 3
    _run_to_completion(qapp, page)
    assert [page.driver.results[i].status for i in range(3)] == ["ok", "ok", "ok"]
    assert all(r.terminal for r in page._rows)
    assert page.isComplete()


def test_failure_is_tolerated_and_run_still_completes(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch, codes={"be": 3})   # middle image fails
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert [page.driver.results[i].status for i in range(3)] == ["ok", "failed", "ok"]
    assert all(r.terminal for r in page._rows)   # a failure does not abort the rest
    assert page.isComplete()                     # every row terminal -> Finish enabled


def test_stop_all_marks_rows_stopped(monkeypatch, qapp, wiz, tmp_path):
    box = {}

    def on_run(fake, cfg):
        if cfg.role == "pki":                    # stop the whole run during the first image
            box["page"]._stop_all()
    _install_fake_builddriver(monkeypatch, on_run=on_run)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    box["page"] = page
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.driver.results[0].status == "stopped"
    assert all(r.status == "stopped" for r in page.driver.results)
    assert page.isComplete()


def test_mesh_manifest_and_node_keys_footer(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    footer = page.footer.text()
    assert "manifest" in footer.lower()
    # the two node images generated key-zips; the desktop image did not.
    assert "pki.x86" in footer and "be.rpi5" in footer
    assert "rpi5-desktop.rpi5" not in footer
