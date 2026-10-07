"""What a person SEES on the two other surfaces PR #645 touched: the Go-Live wizard's
Inputs and Generate steps, and the cloud-mode Domains step (hugmesh-generator #647 /
#656, the post-merge review of PR #645, robustness M3).

The review found that the controls #645 added — the Go-Live ‘Baked domains’ picker and
its notes, the per-domain exposure pane, the cloud Domains step's certificate-authority
note — had no test that each is visible and wide enough, under no second Qt style and
not at 8 pt. ``test_fleet_window_layout.py`` does that for the fleet window; this file
does it for the other two surfaces. Every assertion is GEOMETRY (a box inside the
window, a label that needs no more room than it has, a picker as wide as its widest
entry), never ``isHidden()`` alone — ``isVisible`` and a measured size, because the
#647 checkbox column was "there" to every model-level test and not drawn.

The style is set on the window's own widget tree and never on the application (see
``test_fleet_window_layout.py``: ``QApplication.setStyle`` re-polishes the windows
earlier files in the #591 wrapper's single process left behind and hung it). A style
that is not installed here is not parametrized — never skipped, because the wrapper
reads a skip as red.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import CLIENT_CA_INHERITANCE_NOTE        # noqa: E402
from hugmesh_studio.core.golive_domains import NO_EXTRA_DOMAINS_NOTE     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                   # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                      # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                      # noqa: E402

from _helpers import advance_to, pick_mode                               # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

#: (style, point size): the default first; then the installed styles whose controls are
#: drawn larger relative to the text, at 8 pt (where the default font alone hides a
#: squeeze).
_INSTALLED = set(QtWidgets.QStyleFactory.keys())
COMBOS = [(s, pt) for s, pt in (("Fusion", None), ("Windows", 8.0),
                                ("Breeze", 8.0), ("Oxygen", 8.0))
          if s in _INSTALLED]


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-domain-surface-layout-tests"]))


@pytest.fixture(params=COMBOS, ids=[f"{s}-{pt or 'default'}pt" for s, pt in COMBOS])
def styled(request):
    return request.param


@pytest.fixture
def device(tmp_path, monkeypatch):
    """A device with a baked cluster domain and two more baked domains."""
    (tmp_path / "cluster-domain").write_text("mesh.example\n")
    (tmp_path / "domains").write_text(
        "mesh.example\nshop.example\nan-unusually-long-baked-domain.example.org\n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "cluster-domain"))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "domains"))
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tmp_path / "absent-tor"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    return tmp_path


@pytest.fixture
def bare_node(tmp_path, monkeypatch):
    """A node as the builders bake it: the cluster domain only."""
    (tmp_path / "cluster-domain").write_text("mesh.example\n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "cluster-domain"))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "absent"))
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tmp_path / "absent-tor"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    return tmp_path


def _events():
    QtWidgets.QApplication.processEvents()


def _restyle(win, style, pt):
    """Give every widget of ``win``'s tree the case's style (Qt does not propagate a
    widget's style) and the case's font to the window (which does propagate)."""
    for w in [win, *win.findChildren(QtWidgets.QWidget)]:
        w.setStyle(style)
    if pt:
        f = win.font()
        f.setPointSizeF(pt)
        win.setFont(f)


def _rect_in(widget, frame):
    return QtCore.QRect(widget.mapTo(frame, QtCore.QPoint(0, 0)), widget.size())


def _whole(label):
    """A (wrapped) label needs no more height than it has."""
    need = (label.heightForWidth(label.width()) if label.wordWrap()
            else label.sizeHint().height())
    return need <= label.height() + 1


def _inside(win, widget):
    return win.rect().contains(_rect_in(widget, win))


def _dispose(win):
    win.close()
    win.deleteLater()
    QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
    _events()


def _golive_at(qapp, styled, page_id, provider="cloudflare-tunnel"):
    """A Go-Live wizard in the case's style, standing on ``page_id`` at its default
    820x640. Returns ``(wizard, page, keepalive)`` — the style object must outlive the
    window (a widget does not own its style)."""
    style_name, pt = styled
    style = QtWidgets.QStyleFactory.create(style_name)
    assert style is not None, style_name
    wiz = golive_mod.GoLiveWizard(GENERATOR_DIR)
    wiz.model = wiz.driver.provider(provider).model
    wiz.opts.provider = provider
    _restyle(wiz, style, pt)
    wiz.setStartId(wiz._page_ids[page_id])
    wiz.restart()
    wiz.show()
    _events()
    page = wiz.currentPage()
    assert page is wiz.page(wiz._page_ids[page_id])
    if page_id == "inputs":
        page.initializePage()
    _restyle(wiz, style, pt)
    _events()
    return wiz, page, style


# ── Go-Live, Inputs step: the ‘Baked domains’ picker ──────────────────────────────────
def test_the_default_style_is_among_the_measured_ones():
    assert ("Fusion", None) in COMBOS


def test_the_inputs_picker_is_drawn_whole_with_every_baked_domain(qapp, styled, device):
    wiz, page, style = _golive_at(qapp, styled, "inputs")
    try:
        picker = page.domain_pick
        names = [picker.itemText(i) for i in range(picker.count())]
        assert names == ["mesh.example (cluster domain)", "shop.example",
                         "an-unusually-long-baked-domain.example.org"], names
        assert picker.isVisible() and picker.isEnabled()
        assert _inside(wiz, picker), (_rect_in(picker, wiz), wiz.size())
        # the combo is as wide as its widest entry needs (a squeezed one elides the
        # entry — the same shape as the #647 checkbox column)
        assert picker.width() >= picker.sizeHint().width(), (
            picker.width(), picker.sizeHint().width())
        widest = max(picker.fontMetrics().horizontalAdvance(n) for n in names)
        arrow = picker.style().pixelMetric(QtWidgets.QStyle.PixelMetric.PM_ScrollBarExtent)
        assert picker.width() >= widest + arrow, (picker.width(), widest, arrow)
        # the field the picker fills sits under it, whole, and shows the domain it holds
        dom = page.domain
        assert dom.isVisible() and _inside(wiz, dom)
        assert dom.text() == "mesh.example"
        assert dom.width() >= dom.fontMetrics().horizontalAdvance(dom.text()) + 20
        # the row's own label is not cut
        labels = [lb for lb in page.findChildren(QtWidgets.QLabel)
                  if lb.text() == "Baked domains"]
        assert len(labels) == 1 and labels[0].isVisible()
        assert labels[0].width() >= labels[0].fontMetrics().horizontalAdvance("Baked domains")
        # the pick's own line (shown after a pick) is whole on one line
        page.domain_pick.setCurrentIndex(1)
        _events()
        hint = page.domain_hint
        assert hint.isVisible() and hint.text(), hint.text()
        assert hint.width() >= hint.fontMetrics().horizontalAdvance(hint.text()), (
            hint.width(), hint.text())
        # Back / Next / Cancel are in the window
        for kind in (QtWidgets.QWizard.WizardButton.NextButton,
                     QtWidgets.QWizard.WizardButton.CancelButton):
            assert wiz.button(kind).isVisible() and _inside(wiz, wiz.button(kind))
    finally:
        _dispose(wiz)
        del style


def test_a_bare_nodes_picker_note_is_whole_and_in_the_window(qapp, styled, bare_node):
    wiz, page, style = _golive_at(qapp, styled, "inputs")
    try:
        note = page.domain_list_note
        assert note.text() == NO_EXTRA_DOMAINS_NOTE
        assert note.isVisible() and _inside(wiz, note)
        assert _whole(note), (note.heightForWidth(note.width()), note.height())
        assert not page.domain_pick.isEnabled()
        assert page.domain_pick.count() == 1
        assert page.domain_pick.width() >= page.domain_pick.sizeHint().width()
    finally:
        _dispose(wiz)
        del style


# ── Go-Live, Generate step: the per-domain exposure pane ──────────────────────────────
def test_the_exposure_pane_shows_every_row_without_a_scrollbar(qapp, styled, device,
                                                               monkeypatch):
    """The unreadable-export plan is the longest one (a row whose remedy runs to the
    end of a long sentence, then the per-domain row): its rows are all in view at the
    wizard's own default size, in every measured style and at 8 pt."""
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(device / "cluster-domain"))
    wiz, page, style = _golive_at(qapp, styled, "generate", provider="tor-onion")
    try:
        box = page.exposure
        rows = box.toPlainText().splitlines()
        assert any("cannot be read by this user" in r for r in rows), rows
        assert any(r.startswith("Tor: per-domain onions") for r in rows), rows
        assert box.isVisible() and _inside(wiz, box)
        assert box.width() >= 400
        assert box.horizontalScrollBar().maximum() == 0
        assert box.verticalScrollBar().maximum() == 0, (
            box.height(), box.content_height(), len(rows))
        assert box.height() >= box.content_height()
        # nothing under the pane is pushed out of the window
        for kind in (QtWidgets.QWizard.WizardButton.BackButton,
                     QtWidgets.QWizard.WizardButton.NextButton):
            assert _inside(wiz, wiz.button(kind))
    finally:
        _dispose(wiz)
        del style


# ── cloud mode, Domains step: the certificate-authority note ──────────────────────────
def _cloud_domains(qapp, styled, monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    style_name, pt = styled
    style = QtWidgets.QStyleFactory.create(style_name)
    assert style is not None, style_name
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    _restyle(wiz, style, pt)
    wiz.show()
    _events()
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    _restyle(wiz, style, pt)           # the table's row widgets are made on entry
    _events()
    return wiz, dom, style


def test_the_cloud_domains_step_shows_the_ca_note_whole_beside_its_controls(
        qapp, styled, monkeypatch, tmp_path):
    wiz, dom, style = _cloud_domains(qapp, styled, monkeypatch, tmp_path)
    try:
        note = dom.client_ca_note
        assert note.text() == CLIENT_CA_INHERITANCE_NOTE
        assert note.isVisible() and _inside(wiz, note)
        assert _whole(note), (note.heightForWidth(note.width()), note.height())
        assert note.width() >= 400
        # the table and its two buttons, and the wizard's own buttons, are in the window
        assert dom.table.isVisible() and _inside(wiz, dom.table)
        assert dom.table.viewport().height() >= 3 * dom.table.verticalHeader().defaultSectionSize()
        for text in ("Add domain", "Remove selected"):
            btn = next(b for b in dom.findChildren(QtWidgets.QPushButton)
                       if b.text() == text)
            assert btn.isVisible() and _inside(wiz, btn), (text, _rect_in(btn, wiz), wiz.size())
        for kind in (QtWidgets.QWizard.WizardButton.BackButton,
                     QtWidgets.QWizard.WizardButton.NextButton):
            btn = wiz.button(kind)
            assert btn.isVisible() and _inside(wiz, btn)
        # the first row is drawn with a real cell (not an index widget in an empty one)
        first = dom.table.visualRect(dom.table.model().index(0, 0))
        assert first.width() > 40 and first.height() > 10, first
    finally:
        _dispose(wiz)
        del style
