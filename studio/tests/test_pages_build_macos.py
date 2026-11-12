"""The Build page on a Mac: no "native" backend, and what IS offered can be seen.

A Mac builds only through the Linux VM of Docker Desktop, colima or OrbStack (a native
build is sudo + bash + a Gentoo chroot, which macOS cannot do), so the Backend dropdown
offers ``auto`` and ``docker`` as on Windows. The page is walked to through the real
flow, on a darwin host, and LOOKED at: at the 1200x800 and 942x552 windows the
dropdown is on screen, inside the window, wide enough for its longest entry, and the
pictures are written (``HUGMESH_STUDIO_SHOTS`` names a folder to keep them in).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import platform_info                       # noqa: E402
from hugmesh_studio.core.platform_info import SESSION_COCOA, HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.pages import build as build_mod             # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                 # noqa: E402
from test_pages_build_sections import advance_to                    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
MAC = HostInfo(os="darwin", is_gentoo=False, has_docker=True, has_bash=True, has_kvm=False,
               is_root=False, builder_image="hugmesh-builder", session=SESSION_COCOA,
               mac_arch="arm64", docker_runtime="colima", docker_vm_mem=16 * 2**30)
SIZES = ((1200, 800), (942, 552))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def mac_wizard(qapp, monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": MAC)
    monkeypatch.setattr(platform_info, "builds_in_docker_vm", lambda *a, **k: True)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _settle(app):
    for _ in range(3):
        app.processEvents()


def test_a_mac_is_offered_auto_and_docker_and_can_see_them(qapp, mac_wizard, tmp_path):
    page = advance_to(mac_wizard, build_mod.BuildPage)
    combo = page.backend
    assert [combo.itemText(i) for i in range(combo.count())] == ["auto", "docker"]
    shots = os.environ.get("HUGMESH_STUDIO_SHOTS") or str(tmp_path)
    os.makedirs(shots, exist_ok=True)
    longest = max(combo.fontMetrics().horizontalAdvance(combo.itemText(i))
                  for i in range(combo.count()))
    for width, height in SIZES:
        mac_wizard.resize(width, height)
        _settle(qapp)
        area = combo.parentWidget()
        while area is not None and not isinstance(area, QtWidgets.QScrollArea):
            area = area.parentWidget()
        assert area is not None, "the Build page is not in a scroll area"
        area.ensureWidgetVisible(combo)
        _settle(qapp)
        assert combo.isVisible()
        top_left = combo.mapTo(mac_wizard, QtCore.QPoint(0, 0))
        rect = QtCore.QRect(top_left, combo.size())
        assert mac_wizard.rect().contains(rect), (width, height, rect, mac_wizard.rect())
        viewport = area.viewport()
        vp_top_left = combo.mapTo(viewport, QtCore.QPoint(0, 0))
        assert viewport.rect().contains(QtCore.QRect(vp_top_left, combo.size())), (
            "the dropdown is scrolled out of the page's view", width, height)
        assert combo.width() >= longest, (combo.width(), longest)
        path = os.path.join(shots, f"build-page-macos-{width}x{height}.png")
        assert mac_wizard.grab().save(path), path
        assert os.path.getsize(path) > 1000
