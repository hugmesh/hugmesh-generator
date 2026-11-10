"""The NVD API key box in the GUI — rendered, measured, clicked (offscreen, FAKE keys).

Pins what the operator could not see on 2026-11-10: the Fleet window's Pen-test
harness group now SAYS the SCA step needs an NVD key, links the request page, has a
masked box, and keeps the activation warning visible next to it. Every state is
rendered (empty, entered-unverified, not-accepted-yet, verified) and saved as a PNG
(``$NVD_SHOTS_DIR`` when set, else the test's tmp dir), with geometry asserts: the
box, the link and both warnings are visible, non-empty, inside the group, and not
clipped. Verify runs on the worker against a fake opener and reports inline — no
QMessageBox anywhere.
"""
from __future__ import annotations

import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import nvd_key                                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                    # noqa: E402

from test_nvd_key_core import NVD_200, NVD_404_KEY, FakeOpener         # noqa: E402

KEY = "11111111-2222-4333-8444-555555555555"
GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _no_modals(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("a modal was opened")
    for name in ("exec", "information", "warning", "critical", "question"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name, boom, raising=False)


@pytest.fixture
def shots(tmp_path):
    d = os.environ.get("NVD_SHOTS_DIR") or str(tmp_path)
    os.makedirs(d, exist_ok=True)
    return d


@pytest.fixture
def page(qapp, monkeypatch):
    from hugmesh_studio.gui.pages.fleet import FleetPage
    p = FleetPage(GEN)
    p.resize(960, 1200)
    p.show()
    qapp.processEvents()
    yield p
    p.close()


def _wait(qapp, cond, s=10.0):
    end = time.monotonic() + s
    while time.monotonic() < end:
        qapp.processEvents()
        if cond():
            return True
        time.sleep(0.01)
    return False


def _in(widget, outer):
    """``widget``'s rect, mapped into ``outer``, lies inside ``outer``'s rect."""
    tl = widget.mapTo(outer, QtCore.QPoint(0, 0))
    r = QtCore.QRect(tl, widget.size())
    return outer.rect().contains(r)


def _not_clipped(label):
    """A word-wrapped label is tall enough for its text at its width."""
    need = label.heightForWidth(label.width()) if label.hasHeightForWidth() else label.sizeHint().height()
    return label.height() >= need - 1 and label.width() > 0


def _geometry(w, group):
    QtWidgets.QApplication.processEvents()          # let the layout settle first
    for name in ("need_label", "request_link", "guide_link", "key_edit", "show_btn",
                 "activation_label", "empty_label", "save_btn", "verify_btn",
                 "forget_btn", "consent_label", "status_label"):
        x = getattr(w, name)
        assert x.isVisible(), name
        assert x.width() > 0 and x.height() > 0, name
        assert _in(x, group), name
    for name in ("need_label", "request_link", "activation_label", "empty_label",
                 "consent_label", "status_label"):
        assert _not_clipped(getattr(w, name)), name
    # the warning sits right under the box
    box = w.key_edit.mapTo(group, QtCore.QPoint(0, 0))
    warn = w.activation_label.mapTo(group, QtCore.QPoint(0, 0))
    assert 0 < warn.y() - (box.y() + w.key_edit.height()) < 40


def _shot(page, shots, name):
    path = os.path.join(shots, f"nvd-key-{name}.png")
    assert page.pentest_box.grab().save(path)
    assert os.path.getsize(path) > 1000
    return path


def test_the_box_appears_only_with_a_pentest_and_lives_in_the_harness_group(qapp, page):
    w = page.nvd_key
    assert not w.isVisible()
    page.pentest.setChecked(True)
    qapp.processEvents()
    assert w.isVisible() and w.parent() is page.pentest_box
    page.pentest.setChecked(False)
    page.pentest_only.setChecked(True)
    qapp.processEvents()
    assert w.isVisible()
    page.pentest_only.setChecked(False)
    qapp.processEvents()
    assert not w.isVisible()


def test_masked_box_links_and_permanent_warnings(qapp, page):
    page.pentest.setChecked(True)
    qapp.processEvents()
    w = page.nvd_key
    assert w.key_edit.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert w.key_edit.accessibleName() == "NVD API key"
    assert w.need_label.text() == nvd_key.NEED_LINE
    assert w.activation_label.text() == nvd_key.ACTIVATION_WARNING
    assert w.empty_label.text() == nvd_key.EMPTY_REFUSED
    assert w.consent_label.text() == nvd_key.VERIFY_CONSENT
    # the link target IS the NVD request page, shown as text too, opened only on click
    assert f'href="{nvd_key.REQUEST_URL}"' in w.request_link.text()
    assert w.request_link.text().endswith(f"— {nvd_key.REQUEST_URL}")
    assert not w.request_link.openExternalLinks()
    assert f'href="{nvd_key.GUIDE_URL}"' in w.guide_link.text()
    w.show_btn.setChecked(True)
    assert w.key_edit.echoMode() == QtWidgets.QLineEdit.EchoMode.Normal
    w.show_btn.setChecked(False)
    assert w.key_edit.echoMode() == QtWidgets.QLineEdit.EchoMode.Password


def test_every_state_rendered_and_measured(qapp, page, shots):
    page.pentest.setChecked(True)
    qapp.processEvents()
    w, group = page.nvd_key, page.pentest_box
    out = {}
    # 1) empty: nothing stored
    _geometry(w, group)
    assert "no key stored" in w.status_label.text()
    out["empty"] = _shot(page, shots, "1-empty")
    # an empty Save is refused inline and stores nothing
    w.save_btn.click()
    qapp.processEvents()
    assert nvd_key.EMPTY_REFUSED in w.status_label.text() and not nvd_key.load()
    # 2) entered, saved, not verified (padded paste: trimmed)
    w.key_edit.setText(f"  {KEY}\n")
    out["typed"] = _shot(page, shots, "2-typed-masked")
    w.save_btn.click()
    qapp.processEvents()
    assert nvd_key.load() == KEY and w.key_edit.text() == ""
    assert "stored (not verified)" in w.status_label.text()
    _geometry(w, group)
    out["unverified"] = _shot(page, shots, "3-stored-unverified")
    # 3) Verify -> not accepted yet (a fresh, un-activated key)
    w._opener = FakeOpener(NVD_404_KEY)
    w.verify_btn.click()
    assert not w.verify_btn.isEnabled()                    # disabled while it runs
    assert _wait(qapp, lambda: w.verify_btn.isEnabled())
    assert w.status_label.text().startswith("not accepted yet:")
    assert "activation link" in w.status_label.text()
    _geometry(w, group)
    out["not_accepted"] = _shot(page, shots, "4-not-accepted-yet")
    # 4) Verify -> accepted
    w._opener = FakeOpener(NVD_200)
    w.verify_btn.click()
    assert _wait(qapp, lambda: w.verify_btn.isEnabled())
    assert w.status_label.text().startswith("accepted:")
    assert nvd_key.status().verified
    _geometry(w, group)
    out["verified"] = _shot(page, shots, "5-verified")
    w.refresh()
    assert w.status_label.text().startswith("NVD API key: stored, verified")
    # the org-secret row
    w.org_tick.setChecked(True)
    qapp.processEvents()
    assert w.org_box.isVisible() and _in(w.org_edit, group)
    out["org"] = _shot(page, shots, "6-org-secret-row")
    assert all(os.path.exists(p) for p in out.values())


def test_save_refuses_a_malformed_key_inline(qapp, page):
    page.pentest.setChecked(True)
    w = page.nvd_key
    w.key_edit.setText("not-a-key")
    w.save_btn.click()
    assert "Not saved" in w.status_label.text() and not nvd_key.load()


def test_org_push_refuses_unverified_inline_without_running_anything(qapp, page):
    page.pentest.setChecked(True)
    w = page.nvd_key
    calls = []

    class R:
        def run(self, argv, **kw):
            calls.append(argv)
            raise AssertionError("ran gh")
    w._runner = R()
    nvd_key.save(KEY)
    w.org_tick.setChecked(True)
    w.org_edit.setText("acme")
    w.org_btn.click()
    qapp.processEvents()
    assert calls == [] and nvd_key.ACTIVATION_WARNING in w.org_status.text()


def test_preview_note_follows_the_stored_key(qapp, page):
    from hugmesh_studio.gui.pages import fleet as fleet_mod
    page.pentest.setChecked(True)
    page._goto(fleet_mod.STEP_REVIEW)
    page.refresh_preview()
    assert nvd_key.PREFLIGHT_NO_KEY in page.problems.toPlainText()
    nvd_key.save(KEY)
    page.nvd_key.changed.emit()
    assert nvd_key.PREFLIGHT_NO_KEY not in page.problems.toPlainText()


def test_build_page_says_pentest_is_fleet_only_and_has_no_key_box(qapp):
    from hugmesh_studio.gui.pages import build as build_mod
    from hugmesh_studio.gui.pages._nvd_key_widget import NvdKeyWidget
    src = open(build_mod.__file__, encoding="utf-8").read()
    assert "runs only on a fleet build" in src and "NvdKeyWidget" not in src
    assert NvdKeyWidget  # the widget exists; the Build page just does not host it


def test_the_tui_and_the_widget_print_the_same_words(qapp, page):
    """GUI <-> TUI parity: the TUI's `nvd` block is the widget's labels, line for line."""
    from hugmesh_studio.tui.nvd_step import NvdCommands
    w = page.nvd_key
    tui = "\n".join(NvdCommands.lines())
    for gui_text in (w.need_label.text(), w.activation_label.text(), w.empty_label.text(),
                     w.consent_label.text(), nvd_key.REQUEST_URL, nvd_key.GUIDE_URL):
        assert gui_text in tui


def test_verify_then_save_keeps_the_verdict(qapp, page):
    """Typed key -> Verify (accepted) -> Save: stored AND verified, no second Verify."""
    page.pentest.setChecked(True)
    w = page.nvd_key
    w._opener = FakeOpener(NVD_200)
    w.key_edit.setText(KEY)
    w.verify_btn.click()
    assert _wait(qapp, lambda: w.verify_btn.isEnabled())
    assert "Press Save to keep it" in w.status_label.text()
    w.save_btn.click()
    assert nvd_key.status().verified
    assert "stored, verified" in w.status_label.text()
    # a DIFFERENT key saved after that Verify is not marked verified
    w.key_edit.setText("abcdef01-2345-4678-9abc-def012345678")
    w.save_btn.click()
    assert not nvd_key.status().verified
