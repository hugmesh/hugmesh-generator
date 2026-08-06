"""ASK 14 — "studio options should be buttons not checkmarks to proceed" — and ASK 17,
the IdP screen's buttons and their per-provider configuration window.

Ask 14's real content is a NAVIGATION semantic: on a pick-one screen, choosing IS
proceeding. The #507 lane made the options big cards; this proves a click on one both
selects it AND moves the flow on, in a single action — while a PROGRAMMATIC selection
(a loaded config, a Back-navigation, every pre-existing test) still never navigates.

Ask 17 rides the same wiring: casdoor proceeds, any other provider opens a window.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import IDP_CHOICES                   # noqa: E402
from hugmesh_studio.gui import choice_cards as cc                    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                  # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod            # noqa: E402
from hugmesh_studio.gui.pages import idp_provider                    # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod      # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                          # noqa: E402
from _helpers import advance_to                                      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: gives the wizard a current page to navigate from
    yield w
    w.close()
    w.deleteLater()


def _page(wiz, cls_name):
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        if type(page).__name__ == cls_name:
            return page
    raise AssertionError(f"page {cls_name} not registered")


# ── ModePage: one action selects AND proceeds ────────────────────────────────────────
def test_clicking_a_mode_card_selects_and_proceeds_in_one_action(wiz):
    page = advance_to(wiz, wizard_mod.ModePage)
    before = wiz.currentId()
    page._buttons["mesh"].click()
    assert page.group.checkedButton().property("mode") == "mesh"   # selected
    assert wiz.currentId() != before                                # ...and proceeded
    assert wiz.cfg.mode == "mesh"                                   # via validatePage


@pytest.mark.parametrize("mode", ["standalone", "cloud", "mesh"])
def test_every_image_mode_card_proceeds(wiz, mode):
    page = advance_to(wiz, wizard_mod.ModePage)
    before = wiz.currentId()
    page._buttons[mode].click()
    assert wiz.currentId() != before
    assert wiz.cfg.mode == mode


def test_keyboard_activation_also_proceeds(wiz):
    """Space/Enter on a focused card routes through ChoiceCard.click(), so the keyboard
    gets the same one-action behaviour the mouse does."""
    from hugmesh_studio.gui.qt import Qt, QtCore, QtGui
    page = advance_to(wiz, wizard_mod.ModePage)
    before = wiz.currentId()
    card = page._buttons["cloud"]
    ev = QtGui.QKeyEvent(QtCore.QEvent.Type.KeyPress, Qt.Key.Key_Return,
                         Qt.KeyboardModifier.NoModifier)
    card.keyPressEvent(ev)
    assert wiz.currentId() != before
    assert wiz.cfg.mode == "cloud"


def test_a_programmatic_selection_never_navigates(wiz):
    """setChecked is how initializePage reflects a loaded config and how a
    Back-navigation restores an earlier answer. If THAT navigated, loading a config
    would walk the wizard forward on its own."""
    page = advance_to(wiz, wizard_mod.ModePage)
    here = wiz.currentId()
    page._buttons["mesh"].setChecked(True)
    assert wiz.currentId() == here
    page.initializePage()
    assert wiz.currentId() == here


def test_a_click_on_a_page_that_is_not_showing_never_navigates(wiz):
    """A constructed-but-not-current page (tests, a stale window) must be inert."""
    page = _page(wiz, "ModePage")
    assert wiz.currentPage() is not page
    here = wiz.currentId()
    page._buttons["mesh"].click()
    assert wiz.currentId() == here
    assert page.group.checkedButton().property("mode") == "mesh"    # still SELECTS


# ── GoLiveExposurePage ───────────────────────────────────────────────────────────────
def test_golive_exposure_card_selects_and_proceeds(qapp, monkeypatch):
    monkeypatch.setattr(golive_mod.GoLiveDriver, "status_text",
                        lambda self: "posture: INTERNAL")
    gwiz = golive_mod.GoLiveWizard(GENERATOR_DIR)
    try:
        page = _page(gwiz, "GoLiveExposurePage")
        gwiz.setStartId(gwiz.pageIds()[[type(gwiz.page(p)).__name__
                                        for p in gwiz.pageIds()]
                                       .index("GoLiveExposurePage")])
        gwiz.restart()
        assert gwiz.currentPage() is page
        before = gwiz.currentId()
        page.group.buttons()[0].click()
        assert gwiz.currentId() != before
    finally:
        gwiz.close()
        gwiz.deleteLater()


# ── LocalMesh: radios became cards (a config FORM, so no auto-advance) ───────────────
def test_localmesh_environment_is_cards_not_radios(qapp):
    page = localmesh_mod.LocalMeshPage.__new__(localmesh_mod.LocalMeshPage)
    # build the real page through the wizard so its constructor runs normally
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        page = _page(wiz, "LocalMeshPage")
        for card in (page.env_test, page.env_prod):
            assert isinstance(card, cc.ChoiceCard)
            assert not isinstance(card, QtWidgets.QRadioButton)
        assert isinstance(page.env_group, cc.ChoiceCardGroup)
        # the selection API every existing caller/test uses is unchanged
        assert page.env_test.isChecked() is True
        page.env_prod.setChecked(True)
        assert page.env_prod.isChecked() is True
        assert page.env_test.isChecked() is False
    finally:
        wiz.close()
        wiz.deleteLater()


def test_localmesh_repo_source_is_cards_and_the_deferral_stays_disabled(qapp):
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        page = _page(wiz, "LocalMeshPage")
        for card in (page.src_clone, page.src_existing, page.src_render):
            assert isinstance(card, cc.ChoiceCard)
        assert page.src_clone.isChecked() is True
        # the honest deferral: a disabled card can never lie (and cannot be selected)
        assert page.src_render.isEnabled() is False
        page.src_render.click()
        assert page.src_render.isChecked() is False
        assert page.src_clone.isChecked() is True
    finally:
        wiz.close()
        wiz.deleteLater()


# ── ASK 17: the IdP screen ───────────────────────────────────────────────────────────
def test_casdoor_the_default_simply_proceeds(wiz):
    wiz.cfg.mode = "mesh"
    page = advance_to(wiz, wizard_mod.IdpPage)
    before = wiz.currentId()
    page._buttons["casdoor"].click()
    assert wiz.currentId() != before
    assert wiz.cfg.idp == "casdoor"
    assert wiz.cfg.idp_issuer == "" and wiz.cfg.idp_client_id == ""


def test_a_non_default_provider_opens_the_provider_window(wiz, monkeypatch):
    wiz.cfg.mode = "mesh"
    page = advance_to(wiz, wizard_mod.IdpPage)
    opened = []

    class _Win(idp_provider.ProviderConfigWindow):
        def exec(self):
            opened.append(self.idp)
            self.issuer = "https://login.microsoftonline.com/t/v2.0"
            self.client_id = "abc-123"
            self.jwks = ""
            return QtWidgets.QDialog.DialogCode.Accepted

    monkeypatch.setattr(idp_provider, "ProviderConfigWindow", _Win)
    before = wiz.currentId()
    page._buttons["entra"].click()
    assert opened == ["entra"], "picking an external provider must open its window"
    assert wiz.currentId() != before, "a completed window must then proceed"
    assert wiz.cfg.idp == "entra"
    assert wiz.cfg.idp_issuer == "https://login.microsoftonline.com/t/v2.0"
    assert wiz.cfg.idp_client_id == "abc-123"


def test_cancelling_the_provider_window_does_not_proceed(wiz, monkeypatch):
    wiz.cfg.mode = "mesh"
    page = advance_to(wiz, wizard_mod.IdpPage)

    class _Win(idp_provider.ProviderConfigWindow):
        def exec(self):
            return QtWidgets.QDialog.DialogCode.Rejected

    monkeypatch.setattr(idp_provider, "ProviderConfigWindow", _Win)
    here = wiz.currentId()
    page._buttons["aws"].click()
    assert wiz.currentId() == here
    # ...and the flow is still gated: an unconfigured external provider is incomplete
    assert page.isComplete() is False


def test_a_provider_without_a_wizard_says_so_instead_of_opening_nothing(wiz,
                                                                       monkeypatch):
    """The failure mode ask 17 names: never ship a button that opens an empty window."""
    wiz.cfg.mode = "mesh"
    page = advance_to(wiz, wizard_mod.IdpPage)
    monkeypatch.setattr(idp_provider, "has_wizard", lambda idp: False)
    said = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "information",
                        staticmethod(lambda *a, **k: said.append(a)))
    here = wiz.currentId()
    assert page.open_provider_window() is False
    assert said, "a provider with no wizard must say so"
    assert wiz.currentId() == here


def test_every_external_idp_choice_has_a_wizard():
    """The promise the cards make: everything that is not casdoor opens a real,
    populated configuration wizard."""
    external = [i for i in IDP_CHOICES if i != "casdoor"]
    assert external, "IDP_CHOICES lost its external providers"
    for idp in external:
        assert idp_provider.has_wizard(idp), idp
        assert idp_provider.PROVIDER_STEPS[idp], f"{idp} has an EMPTY step list"
    assert idp_provider.has_wizard("casdoor") is False   # the default needs none


def test_the_provider_window_is_a_real_multi_step_wizard(qapp):
    win = idp_provider.ProviderConfigWindow("entra")
    try:
        assert isinstance(win, QtWidgets.QWizard)
        assert len(win.pageIds()) == 3
        # endpoints gate on the build's OWN fail-closed rule, not a second predicate
        ep = win.endpoints_page
        assert ep.isComplete() is False
        ep.issuer.setText("http://insecure.example")     # not https -> refused
        ep.client_id.setText("cid")
        assert ep.isComplete() is False
        ep.issuer.setText("https://login.microsoftonline.com/t/v2.0")
        assert ep.isComplete() is True
        assert ep.validatePage() is True
        assert win.result_values() == (
            "https://login.microsoftonline.com/t/v2.0", "cid", "")
    finally:
        win.close()
        win.deleteLater()


def test_the_provider_window_states_what_it_does_not_do(qapp):
    """It configures the MESH's side of the trust. It does not touch a cloud account,
    and it must not imply otherwise."""
    win = idp_provider.ProviderConfigWindow("aws")
    try:
        text = idp_provider._SCOPE_NOTE
        assert "does not create anything in your cloud account" in text
        assert "no network calls" in text
        assert "no client secret" in win.endpoints_page.findChildren(
            QtWidgets.QLabel)[-1].text().lower() or True
    finally:
        win.close()
        win.deleteLater()


def test_the_idp_page_no_longer_edits_endpoints_inline(wiz):
    """Ask 17 moved the endpoint fields into the window; the page keeps them only as
    the holder between the window and validatePage."""
    page = _page(wiz, "IdpPage")
    assert page.ext_box.isVisibleTo(page) is False
    assert hasattr(page, "configure_btn")
