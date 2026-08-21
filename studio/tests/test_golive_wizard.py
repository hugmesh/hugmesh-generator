"""Go-live wizard GUI behavior — step flow, model→provider filtering, the
CLUSTER_DOMAIN autofill, secret-free previews, and the typed-domain flip arming.

The wizard is a THIN front-end onto the CANONICAL driver
specs/usr/sbin/hugmesh-go-live (subcommands status|list|plan|commit|rollback).
Runs the REAL wizard on Qt's offscreen platform (no display needed) and is skipped
whole when no Qt binding is installed — the rest of the suite stays pure-core.
No test here ever flips posture: status_text is pinned, providers() is served from
the real driver `list`, and every action button is asserted BEFORE it is clicked.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.progress_parse import ProgressParser, track_phases  # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod   # noqa: E402
from hugmesh_studio.gui.pages.golive import GOLIVE_PAGE_SLUGS  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

CANNED_STATUS = ("Go-live status\n  release-state: internal (default — no file)\n"
                 "  go-live marker: absent\n  posture: INTERNAL")


@pytest.fixture(autouse=True)
def _pinned_status(monkeypatch):
    # the preflight/verify/flip pages show driver `status` output; pin it so no
    # test ever mutates posture (and the text is deterministic). providers() still
    # shells out to the real driver `list` (read-only).
    monkeypatch.setattr(golive_mod.GoLiveDriver, "status_text",
                        lambda self: CANNED_STATUS)


@pytest.fixture(scope="session")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


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


def test_preflight_page_shows_the_driver_status(wiz):
    page = advance_to(wiz, golive_mod.GoLivePreflightPage)
    assert "posture: INTERNAL" in page.status.toPlainText()


# ---- exposure model → provider filtering ----------------------------------------

def test_exposure_models_come_from_the_registry(wiz):
    page = advance_to(wiz, golive_mod.GoLiveExposurePage)
    assert page.models == ["tunnel", "public-dns", "ddns", "funnel", "router", "onion"]
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
    assert ids == ["byo-domain"]
    # switching the model invalidated the previously picked provider
    wiz.next()
    assert wiz.opts.provider == "byo-domain"


def test_provider_page_surfaces_the_mechanism_and_emits(wiz):
    pick_model(wiz, "tunnel")
    prov = advance_to(wiz, golive_mod.GoLiveProviderPage)
    text = prov.summary.text()
    assert "Mechanism: deeplink" in text
    assert "Required inputs: token" in text
    assert "Plan emits:" in text


# ---- inputs: CLUSTER_DOMAIN autofill + provider-driven field visibility -----------

def test_inputs_autofill_domain_from_the_bake(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.domain.text() == baked_domain
    assert "autofilled" in inputs.domain_hint.text()
    # cloudflare-tunnel: token + tunnel CNAME, no DDNS fields, no ingress IP
    assert inputs.token_box.isVisible()
    assert inputs.tunnel_row.isVisible()
    assert not inputs.ingress_row.isVisible()
    assert not inputs.ddns_sub_row.isVisible()


def test_inputs_page_blocks_next_without_a_domain(wiz, monkeypatch, tmp_path):
    """Blocked, and blocked INLINE.

    validatePage used to raise a QMessageBox here. A modal inside validatePage spins a
    nested event loop that a headless run can neither see nor dismiss, so the suite hangs
    until it is killed — the standing house rule, stated in-tree at build.py:359 for the
    same override. The block must therefore be an inline label, readable as ordinary
    widget state, and NO message box may be constructed at all."""
    from hugmesh_studio.gui.qt import QtWidgets
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "missing"))
    modals = []
    for name in ("warning", "information", "critical", "question"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name,
                            staticmethod(lambda *a, _n=name, **k: modals.append(_n)))
    monkeypatch.setattr(QtWidgets.QMessageBox, "exec",
                        lambda *a, **k: modals.append("exec"))
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.domain.text() == ""
    assert not inputs.problem.isVisible(), "nothing is wrong until Next is pressed"
    before = wiz.currentId()
    wiz.next()

    assert wiz.currentId() == before, "Next must still be refused"
    assert not modals, f"validatePage must open no modal; it used {modals}"
    assert inputs.problem.isVisible()
    assert "Domain required" in inputs.problem.text()

    # …and satisfying it clears the block and lets Next through
    inputs.domain.setText("example.org")
    wiz.next()
    assert wiz.currentId() != before
    assert not inputs.problem.isVisible()


def test_ddns_provider_shows_its_fields(wiz, baked_domain):
    pick_model(wiz, "ddns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.ddns_sub_row.isVisible() and inputs.ddns_service_row.isVisible()
    assert inputs.token_box.isVisible()
    assert not inputs.ingress_row.isVisible()


def test_public_dns_provider_shows_ingress_fields(wiz, baked_domain):
    pick_model(wiz, "public-dns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    assert inputs.ingress_row.isVisible() and inputs.ipv6_row.isVisible()
    assert inputs.tunnel_row.isVisible()
    assert not inputs.token_box.isVisible()
    assert not inputs.ddns_sub_row.isVisible()


# ---- generate: preview mirrors the driver argv, secrets stay out of it -------------

def test_generate_preview_shows_the_exact_driver_command(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.token_secret.setText("super-secret-token")
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    cmd = gen.cmd.toPlainText()
    assert "specs/usr/sbin/hugmesh-go-live" in cmd
    assert " plan " in cmd
    assert "--provider cloudflare-tunnel" in cmd
    assert f"--domain {baked_domain}" in cmd
    assert "staged 0600 temp file" in cmd       # the token arrives as a file, later
    assert "super-secret-token" not in cmd      # NEVER the value
    assert "Preflight OK." in gen.log.toPlainText()


def test_generate_preflight_names_a_missing_token(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    advance_to(wiz, golive_mod.GoLiveInputsPage)   # token left empty
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    assert "needs a token" in gen.log.toPlainText()


# ---- generate: determinate progress bar (the golive-plan banner track) ------------

def test_generate_page_progress_bar_hidden_until_a_run_starts(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    advance_to(wiz, golive_mod.GoLiveInputsPage)
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    assert gen.progress_bar.isVisible() is False
    assert gen.progress_label.isVisible() is False


def test_generate_page_progress_bar_tracks_the_golive_plan_banners(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    advance_to(wiz, golive_mod.GoLiveInputsPage)
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    # drive the exact wiring _generate() would (without spawning the real driver
    # subprocess/thread): a fresh parser over the golive-plan track, then feed it
    # the SAME two banner lines specs/usr/sbin/hugmesh-go-live's cmd_plan() echoes.
    gen._parser = ProgressParser(phases=track_phases("golive-plan"))
    gen._reset_progress()
    assert gen.progress_bar.isVisible() and gen.progress_label.isVisible()
    assert gen.progress_bar.minimum() == gen.progress_bar.maximum() == 0   # indeterminate
    assert gen.progress_label.text() == "starting…"

    gen._on_line("==> Rendering provider artifacts")
    assert gen.progress_bar.maximum() == 100          # now determinate
    assert gen.progress_bar.value() == 0
    assert gen.progress_label.text() == "Render provider artifacts"

    gen._on_line("==> Plan summary ready")
    assert gen.progress_bar.value() == 50
    assert gen.progress_label.text() == "Plan summary ready"

    gen._finished(0)
    assert gen.progress_bar.value() == 100
    assert gen.progress_label.text() == "done"


def test_generate_page_progress_bar_holds_last_percent_on_failure(wiz, baked_domain):
    pick_model(wiz, "tunnel")
    advance_to(wiz, golive_mod.GoLiveInputsPage)
    gen = advance_to(wiz, golive_mod.GoLiveGeneratePage)
    gen._parser = ProgressParser(phases=track_phases("golive-plan"))
    gen._reset_progress()
    gen._on_line("==> Rendering provider artifacts")
    gen._finished(1)
    assert gen.progress_label.text() == "FAILED"
    # finalize() on a nonzero code never claims 100 — held at the last known percent
    assert gen.progress_bar.value() == 0


# ---- verify: off-device checklist + posture recheck (no driver verify subcommand) --

def test_verify_page_shows_a_checklist_and_pinned_status(wiz, baked_domain):
    pick_model(wiz, "public-dns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.7")
    verify = advance_to(wiz, golive_mod.GoLiveVerifyPage)
    assert f"dig +short {baked_domain}" in verify.checklist.toPlainText()
    assert "posture: INTERNAL" in verify.status.toPlainText()


# ---- flip: typed-domain arming (the GUI half of the double human confirm) ----------

def test_flip_button_arms_only_on_the_typed_domain(wiz, baked_domain):
    pick_model(wiz, "public-dns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.7")
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


def test_flip_page_final_button_says_exit_not_finish(wiz, baked_domain):
    """Operator report 2026-08-21: "if all the finish button does is exit then just
    label it exit."

    The flip page is the LAST page of this wizard, and its wizard button does nothing
    but close the window: the flip itself is the in-page "GO LIVE" button above (which
    opens the driver's own TTY confirmation), and there is no ``validatePage`` here, so
    the wizard button neither commits nor rolls anything back. Read off the RENDERED
    widget — the relabel is a per-page ``QWizardPage.setButtonText`` override, and one
    that never reaches the button is exactly what a call-site assertion cannot see."""
    from hugmesh_studio.gui.qt import QtWidgets

    pick_model(wiz, "public-dns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.7")
    flip = advance_to(wiz, golive_mod.GoLiveFlipPage)
    assert flip.nextId() == -1                       # it really is the end of the flow

    btn = wiz.button(QtWidgets.QWizard.WizardButton.FinishButton)
    assert btn is not None and btn.isVisible()
    assert btn.text() == "Exit", f"the flip page still renders {btn.text()!r}"
