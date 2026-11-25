"""G49: "Save config" is reachable from the Review/Launch screen too, not only the
prior-sessions screen (``sessions.SessionsPage``). Same button, same file dialog, same
``sessions.perform_save`` under it; only the inline note's home differs.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6)")

from hugmesh_studio.core.config import ImageConfig                  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo              # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(736, 736)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _launch(wiz, cfg):
    wiz.cfg = cfg
    wiz.worklist = WorklistConfig(base=cfg, entries=[WorklistEntry(role="pki", platform="x86")])
    page = wiz.page(wiz._page_ids["launch"])
    wiz.setStartId(wiz._page_ids["launch"])
    wiz.restart()
    assert wiz.currentPage() is page
    return page


def _standalone_cfg(tmp_path) -> ImageConfig:
    return ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                       brand="acme", output_dir=str(tmp_path / "out"),
                       local_pass="hunter2")


def test_save_config_button_is_drawn_above_the_cards(qapp, wiz, tmp_path):
    page = _launch(wiz, _standalone_cfg(tmp_path))
    qapp.processEvents()
    assert page.save_config_btn.isVisible() and page.save_config_btn.width() > 40

    def _top(w):
        return w.mapTo(page, w.rect().topLeft()).y()
    assert _top(page.save_config_btn) < _top(page.continue_card)
    shot = os.environ.get("HUGMESH_SHOT_DIR")
    if shot:
        os.makedirs(shot, exist_ok=True)
        wiz.grab().save(os.path.join(shot, "launch-save-config.png"))


def test_save_config_writes_the_file_and_says_so_inline(qapp, wiz, tmp_path, monkeypatch):
    page = _launch(wiz, _standalone_cfg(tmp_path))
    out = tmp_path / "saved.json"
    monkeypatch.setattr(QtWidgets.QFileDialog, "getSaveFileName",
                        staticmethod(lambda *a, **kw: (str(out), "JSON (*.json)")))
    # G48: never a modal from this button either.
    for kind in ("information", "warning", "critical"):
        monkeypatch.setattr(
            QtWidgets.QMessageBox, kind,
            staticmethod(lambda *a, _k=kind, **kw:
                        (_ for _ in ()).throw(AssertionError(f"modal {_k} shown"))))
    page._save_config()
    assert out.exists()
    assert page.save_config_note.isVisible()
    assert page.save_config_note.text().startswith(f"Saved {out}, but:")
    assert "local-pass was NOT saved" in page.save_config_note.text()
    import json
    with open(out) as fh:
        data = json.load(fh)
    # the on-disk shape never carries the plaintext secret (save must never write it)
    assert data.get("base", data).get("local_pass", "") == ""
    # the Continue card and the gate are untouched by Save — it is not a gate (#495
    # precedent, same as the mesh strip's own Save button)
    assert page.continue_card.isEnabled()


def test_save_config_cancelled_leaves_the_note_as_it_was(qapp, wiz, tmp_path, monkeypatch):
    page = _launch(wiz, _standalone_cfg(tmp_path))
    monkeypatch.setattr(QtWidgets.QFileDialog, "getSaveFileName",
                        staticmethod(lambda *a, **kw: ("", "")))
    page._save_config()
    assert not page.save_config_note.isVisible()
