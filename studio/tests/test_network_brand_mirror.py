"""The Network page's brand rows on a mesh: read-only, and the screen says where to
change them and takes the person there (2026-10-21 cleanup).

Brand ID, Brand Title, Org and Public Apex Domain became read-only on a mesh with the
superbrand step (#654, D8). A read-only QLineEdit is drawn like an editable one, and the
only explanation was a gray hint, so the rows read as broken. Why they stay read-only
rather than editable: the Branding page writes its superbrand session onto the config on
every Next, so an edit made here was silently put back on the next pass through
Branding (results-20261021/r2-cleanup/probe_two_writers.out). What is pinned here:

  * on a mesh the four rows are read-only AND look it (window background, a tooltip
    naming the superbrand step), and a framed box says where they are changed;
  * the box's button is visible, enabled and a clickable size, and one click walks the
    REAL wizard back to the Branding page with the superbrand step on screen; Next
    brings the person back to the Network page;
  * off a mesh none of that shows and the rows are editable;
  * the text interface's Network step says the same sentence on a mesh and ``s`` opens
    the superbrand step over Branding (GUI/TUI parity).

    HUGMESH_SHOTS=<dir> saves network-brand-mirror.png (the page as drawn) there.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import ImageConfig                     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402
from hugmesh_studio.tui import journey                                 # noqa: E402
from hugmesh_studio.tui import network_step                            # noqa: E402
from hugmesh_studio.tui.superbrand_step import SuperbrandScreen        # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode        # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(1040, 780)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_network(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    return advance_to(wiz, wizard_mod.NetworkPage)


def _rows(page):
    return (page.brand, page.brand_title, page.org, page.domain)


def test_on_a_mesh_the_rows_are_read_only_look_it_and_the_box_says_where(wiz, qapp):
    page = _mesh_network(wiz)
    qapp.processEvents()
    for edit in _rows(page):
        assert edit.isReadOnly()
        assert "superbrand step" in edit.toolTip()
        assert "palette(window)" in edit.styleSheet()
    assert page.brand_mirror_box.isVisibleTo(page)
    text = page.brand_mirror_note.text()
    assert text.startswith(network_step.brand_mirror_text())
    assert "Branding page" in text and "button below" in text
    shots = os.environ.get("HUGMESH_SHOTS")
    if shots:
        os.makedirs(shots, exist_ok=True)
        wiz.grab().save(os.path.join(shots, "network-brand-mirror.png"))


def test_the_button_is_visible_enabled_and_clickable_sized(wiz, qapp):
    page = _mesh_network(wiz)
    qapp.processEvents()
    btn = page.brand_mirror_go
    assert btn.isVisibleTo(page) and btn.isEnabled()
    assert "superbrand step" in btn.text()
    assert btn.sizeHint().height() >= 20 and btn.sizeHint().width() >= 120
    assert not page.brand_mirror_why.isVisibleTo(page)


def test_one_click_walks_back_to_the_superbrand_step_and_next_returns(wiz, qapp):
    page = _mesh_network(wiz)
    page.brand_mirror_go.click()
    qapp.processEvents()
    branding = wiz.currentPage()
    assert isinstance(branding, wizard_mod.BrandingPage)
    assert branding.superbrand is not None and branding.superbrand.isVisibleTo(branding)
    shots = os.environ.get("HUGMESH_SHOTS")
    if shots:
        os.makedirs(shots, exist_ok=True)
        wiz.grab().save(os.path.join(shots, "network-brand-mirror-after-click.png"))
    assert not page.brand_mirror_why.isVisibleTo(page)
    assert advance_to(wiz, wizard_mod.NetworkPage) is page


def test_without_the_branding_page_behind_it_the_button_says_why(qapp):
    """A page hosted outside a walk (no wizard, no history) refuses inline."""
    from types import SimpleNamespace
    page = wizard_mod.NetworkPage(SimpleNamespace(
        cfg=ImageConfig(mode="mesh", role="omnibus", platform="x86"),
        generator_dir=GENERATOR_DIR, worklist=None))
    page.initializePage()
    page.brand_mirror_go.click()
    assert page.brand_mirror_why.isVisibleTo(page)
    assert "Branding page" in page.brand_mirror_why.text()


def test_off_a_mesh_the_rows_are_editable_and_nothing_points_away(wiz, qapp):
    pick_mode(wiz, "standalone")
    page = advance_to(wiz, wizard_mod.NetworkPage)
    for edit in _rows(page):
        assert not edit.isReadOnly()
        assert edit.toolTip() == "" and edit.styleSheet() == ""
    assert not page.brand_mirror_box.isVisibleTo(page)


# ── the text face ────────────────────────────────────────────────────────────────────
def _tui_at_network(mode: str):
    j = journey.Journey(".")
    j.cfg.mode = mode
    j.cfg.brand, j.cfg.brand_title = "acme", "Acme Mesh"
    j.goto("network")
    return j


def test_the_text_network_step_says_the_same_sentence_on_a_mesh(tmp_path):
    j = _tui_at_network("mesh")
    text = "\n".join(j.lines())
    assert network_step.brand_mirror_text() in text
    assert "Brand ID acme" in text and "Brand Title Acme Mesh" in text
    assert "s=superbrand step" in text


def test_s_on_the_text_network_step_opens_the_superbrand_step_over_branding():
    j = _tui_at_network("mesh")
    j.feed("s")
    assert j.slug == "branding"
    assert isinstance(j.overlay, SuperbrandScreen)


def test_off_a_mesh_the_text_step_neither_says_it_nor_takes_s():
    j = _tui_at_network("standalone")
    assert network_step.brand_mirror_text() not in "\n".join(j.lines())
    j.feed("s")
    assert j.slug == "network" and j.overlay is None
    assert "superbrand" not in j.status
