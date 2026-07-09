"""Go-live wizard GUI behavior — step flow, model→provider filtering, the
CLUSTER_DOMAIN autofill, secret-free previews, and the typed-domain flip arming.

Runs the REAL wizard on Qt's offscreen platform (no display needed) and is skipped
whole when no Qt binding is installed — the rest of the suite stays pure-core.
No test here ever executes the engine: status_text is pinned and every action
button is asserted BEFORE it is clicked.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.gui.pages import golive as golive_mod   # noqa: E402
from snapdragon_studio.gui.pages.golive import GOLIVE_PAGE_SLUGS  # noqa: E402
from snapdragon_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

CANNED_STATUS = ("Go-live status\n  release-state: internal (default — no file)\n"
                 "  go-live marker: absent\n  posture: INTERNAL")


@pytest.fixture(autouse=True)
def _pinned_status(monkeypatch):
    # the preflight/flip pages show engine --status output; pin it so no test
    # ever shells out to bash (and the text is deterministic)
    monkeypatch.setattr(golive_mod.GoLiveDriver, "status_text",
                        lambda self: CANNED_STATUS)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["snapdragon-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = golive_mod.GoLiveWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def baked_domain(monkeypatch, tmp_path):
    bake = tmp_path / "cluster-domain"
    bake.write_text("example.org\n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(bake))
    return "example.org"


def advance_to(wiz, page_cls):
    """Click Next until page_cls is current — failing loudly if the flow stalls."""
    for _ in range(len(GOLIVE_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def back_to(wiz, page_cls):
    for _ in range(len(GOLIVE_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        wiz.back()
    raise AssertionError(f"never reached {page_cls.__name__} going back")


def pick_model(wiz, model):
    page = advance_to(wiz, golive_mod.GoLiveExposurePage)
    idx = page.models.index(model)
    page.group.button(idx).setChecked(True)
    return page


# ---- page catalog / slug map --------------------------------------------------

def test_page_slugs_map_to_the_right_pages(wiz):
    expect = {"preflight": golive_mod.GoLivePreflightPage,
              "exposure": golive_mod.GoLiveExposurePage,
              "provider": golive_mod.GoLiveProviderPage,
              "inputs": golive_mod.GoLiveInputsPage,
              "generate": golive_mod.GoLiveGeneratePage,
              "verify": golive_mod.GoLiveVerifyPage,
              "flip": golive_mod.GoLiveFlipPage}
    assert set(expect) == set(GOLIVE_PAGE_SLUGS)
    for slug, cls in expect.items():
        assert type(wiz.page(wiz._page_ids[slug])) is cls


def test_preflight_page_shows_the_engine_status(wiz):
    page = advance_to(wiz, golive_mod.GoLivePreflightPage)
    assert "posture: INTERNAL" in page.status.toPlainText()


# ---- exposure model → provider filtering ----------------------------------------

def test_exposure_models_come_from_the_catalog(wiz):
    page = advance_to(wiz, golive_mod.GoLiveExposurePage)
    assert page.models == ["tunnel", "public-dns", "ddns", "funnel", "router"]
    assert page.group.checkedButton() is not None


def test_provider_list_is_filtered_by_the_chosen_model(wiz):
    pick_model(wiz, "tunnel")
    prov = advance_to(wiz, golive_mod.GoLiveProviderPage)
    ids = [prov.list.item(i).text().split(" — ")[0] for i in range(prov.list.count())]
    assert ids == ["cloudflare-tunnel"]
    back_to(wiz, golive_mod.GoLiveExposurePage)
    pick_model(wiz, "public-dns")
    prov = advance_to(wiz, golive_mod.GoLiveProviderPage)
    ids = [prov.list.item(i).text().split(" — ")[0] for i in range(prov.list.count())]
    assert ids == ["registrar-manual"]
    # switching the model invalidated the previously picked provider
    wiz.next()
    assert wiz.opts.provider == "registrar-manual"


def test_provider_page_surfaces_deep_links_and_notes(wiz):
    pick_model(wiz, "tunnel")
    prov = advance_to(wiz, golive_mod.GoLiveProviderPage)
    assert prov.links_lay.count() == 3          # cloudflare-tunnel's catalog link rows
    texts = []
    for i in range(prov.links_lay.count()):
        row = prov.links_lay.itemAt(i).widget()
        texts.extend(lab.text() for lab in row.findChildren(QtWidgets.QLabel))
    assert any("one.dash.cloudflare.com" in t for t in texts)
    assert "ENV=prod" in prov.notes.text()


# ---- inputs: CLUSTER_DOMAIN autofill + provider-driven field visibility -----------

def test_inputs_autofill_domain_from_the_bake(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.domain.text() == baked_domain
    assert "autofilled" in inputs.domain_hint.text()
    # cloudflare-tunnel: token + tunnel-id + optional CF driver, no DDNS fields
    assert inputs.token_box.isVisible()
    assert inputs.tunnel_row.isVisible()
    assert inputs.cf_box.isVisible()
    assert not inputs.ddns_sub_row.isVisible()


def test_inputs_page_blocks_next_without_a_domain(wiz, monkeypatch, tmp_path):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "missing"))
    warned = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "warning",
                        staticmethod(lambda *a, **k: warned.append(a)))
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.domain.text() == ""
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before and warned


def test_ddns_provider_shows_its_fields(wiz, baked_domain):
    pick_model(wiz, "ddns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.ddns_sub_row.isVisible() and inputs.ddns_service_row.isVisible()
    assert inputs.token_box.isVisible()
    assert not inputs.cf_box.isVisible()


# ---- generate: preview mirrors the engine argv, secrets stay out of it -------------

def test_generate_preview_shows_the_exact_engine_command(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.token_secret.setText("super-secret-token")
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    cmd = gen.cmd.toPlainText()
    assert "./scripts/go-live.sh" in cmd
    assert "--provider cloudflare-tunnel" in cmd
    assert f"--domain {baked_domain}" in cmd
    assert "--emit" in cmd
    assert "staged 0600 temp file" in cmd       # the token arrives as a file, later
    assert "super-secret-token" not in cmd      # NEVER the value
    assert "Preflight OK." in gen.log.toPlainText()


def test_generate_preflight_names_a_missing_token(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    advance_to(wiz, golive_mod.GoLiveInputsPage)   # token left empty
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    assert "needs a token" in gen.log.toPlainText()


# ---- flip: typed-domain arming (the GUI half of the double human confirm) ----------

def test_flip_button_arms_only_on_the_typed_domain(wiz, baked_domain):
    pick_model(wiz, "public-dns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.record_ip.setText("203.0.113.7")
    flip = advance_to(wiz, golive_mod.GoLiveFlipPage)
    assert not flip.flip_btn.isEnabled()
    flip.confirm.setText("wrong.example")
    assert not flip.flip_btn.isEnabled()
    flip.confirm.setText(baked_domain)
    assert flip.flip_btn.isEnabled()
    flip.confirm.setText("")
    assert not flip.flip_btn.isEnabled()
    assert baked_domain in flip.warning.text()
    assert "posture: INTERNAL" in flip.status.toPlainText()
