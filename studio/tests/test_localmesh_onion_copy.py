"""#623: the "Copy .onion address" button's copy must describe what the page does.

The button is never disabled, so its tooltip may not claim it is "enabled only
after" an onion exists; and the "No .onion yet" dialog must name the control that
really exists (the "On" box of the `tor` row on the Services step), not a label
that appears nowhere in the UI. The dialog is captured by patching
QMessageBox.information - a real modal would hang a headless run."""
import os
from types import SimpleNamespace

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    from hugmesh_studio.gui.pages.localmesh import LocalMeshPage
    return LocalMeshPage(SimpleNamespace(generator_dir=GENERATOR_DIR,
                                         cfg=SimpleNamespace()))


def test_tooltip_does_not_claim_the_button_is_gated(page):
    assert page.copy_onion_btn.isEnabled()           # the premise: never disabled
    tip = page.copy_onion_btn.toolTip()
    assert "Enabled only" not in tip
    assert "TOR=1" not in tip


def test_no_onion_dialog_names_the_real_control(page, monkeypatch):
    from hugmesh_studio.gui.pages import localmesh
    shown = []
    monkeypatch.setattr(
        localmesh.QtWidgets.QMessageBox, "information",
        staticmethod(lambda parent, title, text, *a, **k: shown.append((title, text))))
    page.boot._stack_node = lambda: SimpleNamespace(onion_url=lambda: "")
    page._copy_onion()
    assert len(shown) == 1
    title, text = shown[0]
    assert title == "No .onion yet"
    assert "Expose the mesh as a Tor" not in text
    assert "Services step" in text and '"On"' in text and '"tor"' in text
    # ...and that control really exists: a `tor` row with an On checkbox.
    assert "tor" in page.service_boxes
    assert page.with_tor is page.service_boxes["tor"]
