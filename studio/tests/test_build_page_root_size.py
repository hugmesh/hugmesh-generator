"""The Build page refuses a root image size below the builder's floor, through the same
function the headless ``--check`` reads (``root_size_floor.entry_errors``, G50).

The refusal itself is old; what is pinned here is that moving it behind that one function
changed nothing the operator sees: the page still stays put, the red label is shown, and
it carries the words ``--check`` prints. Real wizard on Qt's offscreen platform, skipped
whole when no Qt binding is installed (the harness of test_pages_build.py).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import root_size_floor                     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo              # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from _helpers import type_login_password                            # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


def _build_page(wiz):
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, wizard_mod.BuildPage):
            return page
        before = wiz.currentId()
        type_login_password(page)
        wiz.next()
        assert wiz.currentId() != before, f"flow stuck on {type(page).__name__}"
    raise AssertionError("never reached the Build page")


def test_the_build_page_refuses_a_size_below_the_floor_in_the_shared_words(wiz):
    build = _build_page(wiz)
    build.img_size.setValue(1000)
    assert build.validatePage() is False
    assert not build.img_size_err.isHidden()
    cfg = wiz.cfg
    [(_eid, words)] = root_size_floor.entry_errors(wiz.worklist.entries, cfg)
    assert build.img_size_err.text() == words
    assert "1000 MiB is below" in words
    # drawn, not just "visible": at the default window size the whole refusal sits inside
    # the window's width and is as tall as its words need (a model-only test once passed
    # over controls nobody could see)
    wiz.show()
    QtWidgets.QApplication.processEvents()
    lab = build.img_size_err
    where = lab.mapTo(wiz, lab.rect().topLeft())
    assert where.x() >= 0 and where.x() + lab.width() <= wiz.width()
    assert lab.height() >= lab.fontMetrics().height()


def test_the_build_page_accepts_the_role_default_and_a_size_at_the_floor(wiz):
    build = _build_page(wiz)
    build.img_size.setValue(0)
    assert build.validatePage() is True
    assert build.img_size_err.isHidden()
    floor = root_size_floor.min_root_mib(wiz.cfg.platform, wiz.cfg.mode, wiz.cfg.role,
                                         desktop=wiz.cfg.desktop,
                                         capable=bool(wiz.cfg.capable))
    build.img_size.setValue(floor)
    assert build.validatePage() is True and build.img_size_err.isHidden()
