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


@pytest.fixture(autouse=True)
def _hermetic_targets(monkeypatch, tmp_path):
    """No test here reads this machine's real device registry (a running emulated mesh
    on the developer's box would otherwise appear in the picker), and this host
    answers as a node unless a test says otherwise (B1 has its own tests)."""
    from hugmesh_studio.core import golive_target
    monkeypatch.setattr(golive_mod.qemu_devices, "default_work_dir",
                        lambda _gen: str(tmp_path / "no-devices"))
    monkeypatch.setattr(golive_target, "local_node_refusal", lambda *a, **k: "")


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
              # the optional export step (skipped unless a domain names a GitHub org)
              "org-export": golive_mod.GoLiveOrgExportPage,
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


# ---- go live from an EMULATED device (core.golive_target) ------------------------------
# The device is a fake `ssh` first on PATH that plays the guest (tests/_golive_fake_guest):
# every go-live verb against an emulated target is an ssh, so the argv the wizard makes
# this host run is what is asserted — and nothing else runs.


import _golive_fake_guest as fake                          # noqa: E402
from hugmesh_studio.core import golive_target              # noqa: E402

SECRET = "tok-NEVER-ON-ARGV-0123456789"


@pytest.fixture
def guest(tmp_path, monkeypatch):
    g = fake.install(tmp_path, monkeypatch)
    monkeypatch.setattr(golive_mod.qemu_devices, "default_work_dir",
                        lambda _gen: g.work_dir)
    return g


@pytest.fixture
def emu_wiz(qapp, guest):
    """The wizard opened the way the Mesh emulation page opens it: on the front door."""
    fake.register(guest, label="rpi5/pki")
    fake.register(guest, label="x86/laptop", platform="x86", role="laptop", port=22402)
    fake.register(guest, label="rpi5/be", role="backend", port=22403, state="stopped")
    w = golive_mod.GoLiveWizard(GENERATOR_DIR, target="rpi5/pki")
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _no_secret_on_any_argv(guest):
    for argv in guest.calls():
        assert not any(SECRET in a for a in argv), argv


def test_the_picker_offers_this_host_and_every_device_greying_the_refused(emu_wiz, guest):
    from hugmesh_studio.gui.qt import QtCore
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    pick = pre.target_pick
    texts = [pick.itemText(i) for i in range(pick.count())]
    assert texts[0] == golive_mod.THIS_HOST
    assert any(t.startswith("rpi5/pki") for t in texts)
    # the front door is preselected, and the wizard really targets it
    assert pick.currentText().startswith("rpi5/pki")
    assert emu_wiz.target.label == "rpi5/pki" and emu_wiz.target.is_remote
    assert emu_wiz.driver.target.label == "rpi5/pki"
    model = pick.model()
    for i, text in enumerate(texts):
        enabled = bool(model.item(i).flags() & QtCore.Qt.ItemFlag.ItemIsEnabled)
        tip = pick.itemData(i, QtCore.Qt.ItemDataRole.ToolTipRole) or ""
        if text.startswith(("x86/laptop", "rpi5/be")):
            assert not enabled, text
            assert tip, f"{text}: greyed with no reason"
            assert tip in pre.target_refusals.text()      # said INLINE, too
        else:
            assert enabled, text
    assert "client" in pre.target_refusals.text()           # the laptop: no driver baked
    assert "not running" in pre.target_refusals.text()      # the stopped backend
    assert pre.target_refusals.isVisible()
    assert not pre.target_problem.isVisible()
    assert "over ssh" in pre.target_info.text()
    assert pre.isComplete()
    # the probe ran — one read-only ssh round trip, BatchMode, no tty
    probes = [c for c in guest.calls() if "::driver" in c[-1]]
    assert probes and "BatchMode=yes" in probes[0] and "-t" not in probes[0]


def test_a_device_whose_image_bakes_no_driver_stops_preflight_inline(qapp, guest,
                                                                     monkeypatch):
    monkeypatch.setenv("FAKE_GUEST_DRIVER", "")             # B8: no hugmesh-go-live
    fake.register(guest, label="rpi5/pki")
    w = golive_mod.GoLiveWizard(GENERATOR_DIR, target="rpi5/pki")
    w.show()
    try:
        pre = advance_to(w, golive_mod.GoLivePreflightPage)
        assert not pre.isComplete()
        assert pre.target_problem.isVisible()
        assert "no go-live driver" in pre.target_problem.text()
        # back to this host: the flow opens again
        pre.target_pick.setCurrentIndex(0)
        assert w.target.is_local and pre.isComplete()
        assert not pre.target_problem.isVisible()
    finally:
        w.close()
        w.deleteLater()


def test_an_unknown_label_stays_on_this_host_and_says_why(qapp, guest):
    w = golive_mod.GoLiveWizard(GENERATOR_DIR, target="x86/nope")
    try:
        assert w.target.is_local
        pre = w.page(w._page_ids["preflight"])
        assert "no running device 'x86/nope'" in pre.target_problem.text()
        # still said once the window is up and the step has filled its picker
        w.show()
        assert "no running device 'x86/nope'" in pre.target_problem.text()
        assert pre.target_problem.isVisible()
        pre.target_pick.setCurrentIndex(0)           # a person picks: answered
        pre.target_pick.currentIndexChanged.emit(0)
        assert not pre.target_problem.isVisible()
    finally:
        w.close()
        w.deleteLater()


def test_exposure_and_provider_say_what_each_mechanism_can_do_from_the_device(emu_wiz):
    exp = advance_to(emu_wiz, golive_mod.GoLiveExposurePage)
    assert exp.reach["tunnel"].isVisible()
    assert "can be really reachable (outbound only)" in exp.reach["tunnel"].text()
    assert "can be really reachable" in exp.reach["onion"].text()
    for model in ("public-dns", "ddns", "router"):
        assert exp.reach[model].text().startswith("From rpi5/pki: REHEARSAL"), model
    assert "not on headscale" in exp.reach["funnel"].text()
    pick_model(emu_wiz, "tunnel")
    prov = advance_to(emu_wiz, golive_mod.GoLiveProviderPage)
    assert prov.reach.isVisible()
    assert "PROD ExternalSecret" in prov.reach.text()       # cloudflare-tunnel's caveat


def test_this_host_shows_no_reachability_labels(wiz):
    exp = advance_to(wiz, golive_mod.GoLiveExposurePage)
    assert not any(lb.isVisible() for lb in exp.reach.values())
    prov = advance_to(wiz, golive_mod.GoLiveProviderPage)
    assert not prov.reach.isVisible()


def test_inputs_autofill_from_the_devices_probe_not_this_host(emu_wiz, monkeypatch,
                                                               tmp_path, guest):
    monkeypatch.setenv("FAKE_GUEST_DOMAINS", "mesh.example\nshop.example")
    host = tmp_path / "host-cluster-domain"
    host.write_text("workstation.example\n")             # must NOT be what is offered
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(host))
    emu_wiz.forget_probes()                              # read the device again
    pick_model(emu_wiz, "public-dns")
    inputs = advance_to(emu_wiz, golive_mod.GoLiveInputsPage)
    assert inputs.domain.text() == "mesh.example"
    assert "rpi5/pki" in inputs.domain_hint.text()
    assert [inputs.domain_pick.itemData(i) for i in range(inputs.domain_pick.count())] \
        == ["mesh.example", "shop.example"]
    # the host-side folders mean nothing on a device; where the plan goes is said
    assert not inputs.out_row.isVisible() and not inputs.keys_row.isVisible()
    assert inputs.remote_note.isVisible()
    assert golive_target.GUEST_OUT_ROOT in inputs.remote_note.text()
    # the emulator's own addresses are refused inline, before any plan runs
    inputs.ingress_ip.setText("10.0.2.15")
    before = emu_wiz.currentId()
    emu_wiz.next()
    assert emu_wiz.currentId() == before
    assert inputs.problem.isVisible() and "10.0.2.0/24" in inputs.problem.text()
    inputs.ingress_ip.setText("203.0.113.10")
    emu_wiz.next()
    assert emu_wiz.currentId() != before


def test_generate_runs_the_plan_inside_the_device_and_shows_what_came_back(
        emu_wiz, guest, qapp):
    pick_model(emu_wiz, "public-dns")
    inputs = advance_to(emu_wiz, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.10")
    gen = advance_to(emu_wiz, golive_mod.GoLiveGeneratePage)
    preview = gen.cmd.toPlainText()
    assert preview.startswith("ssh ") and "sudo -n hugmesh-go-live plan" in preview
    assert "--domain mesh.example" in preview and "bash" not in preview.split()
    gen._generate()
    assert gen.worker.wait(30000)
    qapp.processEvents()
    log = gen.log.toPlainText()
    assert "==> Plan summary ready" in log and "=== plan exited 0 ===" in log
    assert gen.progress_label.text() == "done" and gen.progress_bar.value() == 100
    out = golive_target.artifacts_dir(guest.work_dir, "rpi5/pki")
    assert gen.artifacts_folder() == out
    assert sorted(os.listdir(out)) == ["records.txt", "zone.db"]
    for name in ("records.txt", "zone.db"):
        assert f"  {name}" in log                           # listed on the page by name
    plans = [c for c in guest.calls() if "hugmesh-go-live plan" in c[-1]]
    assert len(plans) == 1
    assert not any(a in ("-y", "--yes") for a in plans[0])
    assert golive_target.GUEST_OUT_ROOT + "/studio-" in plans[0][-1]


def test_a_masked_token_reaches_the_device_over_stdin_never_argv(emu_wiz, guest, qapp):
    pick_model(emu_wiz, "tunnel")
    inputs = advance_to(emu_wiz, golive_mod.GoLiveInputsPage)
    inputs.token_secret.setText(SECRET)
    gen = advance_to(emu_wiz, golive_mod.GoLiveGeneratePage)
    assert SECRET not in gen.cmd.toPlainText()
    gen._generate()
    assert gen.worker.wait(30000)
    qapp.processEvents()
    assert guest.token_seen().strip() == SECRET               # the plan read it there
    assert guest.removed() == ["/run/hugmesh-golive-tok.AbC123"]   # and it was deleted
    assert gen._staged == []                                   # the host temp file too
    _no_secret_on_any_argv(guest)
    assert SECRET not in gen.log.toPlainText()


def test_verify_and_flip_show_the_ephemeral_banner_for_a_device(emu_wiz):
    pick_model(emu_wiz, "public-dns")
    inputs = advance_to(emu_wiz, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.10")
    ver = advance_to(emu_wiz, golive_mod.GoLiveVerifyPage)
    assert ver.ephemeral.isVisible()
    assert golive_target.EPHEMERAL_NOTE in ver.ephemeral.text()
    assert "REHEARSAL" in ver.checklist.toPlainText()
    flip = advance_to(emu_wiz, golive_mod.GoLiveFlipPage)
    assert flip.ephemeral.isVisible()
    assert "a restart boots the golden image INTERNAL again" in flip.ephemeral.text()
    assert "rpi5/pki" in flip.flip_btn.text()
    # the warning does not promise the internet: from a device this is a rehearsal
    assert "ABOUT TO GO PUBLIC on rpi5/pki" in flip.warning.text()
    assert "REHEARSAL" in flip.warning.text()


def test_this_host_shows_no_ephemeral_banner(wiz, baked_domain):
    pick_model(wiz, "public-dns")
    inputs = advance_to(wiz, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.7")
    ver = advance_to(wiz, golive_mod.GoLiveVerifyPage)
    assert not ver.ephemeral.isVisible()
    flip = advance_to(wiz, golive_mod.GoLiveFlipPage)
    assert not flip.ephemeral.isVisible() and flip.ephemeral.text() == ""


class _Launched(list):
    pass


@pytest.fixture
def launched(monkeypatch):
    """Capture the terminal the flip opens (a real Popen would open a window)."""
    import subprocess
    real = subprocess.Popen
    got = _Launched()

    def popen(argv, *a, **kw):
        # a DETACHED launch (its own session / console) is the terminal; everything
        # else (the fake guest's ssh) runs for real
        if kw.get("start_new_session") or kw.get("creationflags"):
            got.append((list(argv), kw))
            return None
        return real(argv, *a, **kw)
    monkeypatch.setattr(subprocess, "Popen", popen)
    return got


def _at_flip(w):
    pick_model(w, "public-dns")
    inputs = advance_to(w, golive_mod.GoLiveInputsPage)
    inputs.ingress_ip.setText("203.0.113.10")
    return advance_to(w, golive_mod.GoLiveFlipPage)


def test_flip_opens_the_ssh_commit_on_a_tty_with_no_bypass(emu_wiz, guest, launched,
                                                           monkeypatch):
    monkeypatch.setattr(golive_target, "terminal_spec",
                        lambda argv, **k: golive_target.TerminalSpec(
                            ["xterm", "-e", "bash", "-c", " ".join(argv)], 0, "linux"))
    flip = _at_flip(emu_wiz)
    flip.confirm.setText("mesh.example")
    assert flip.flip_btn.isEnabled()
    flip.flip_btn.click()
    assert len(launched) == 1
    script = launched[0][0][-1]
    assert "ssh" in script and "-t" in script.split()
    assert "sudo hugmesh-go-live commit --provider byo-domain --domain mesh.example" in script
    assert " -y" not in script and "--yes" not in script and "GL_ASSUME_YES" not in script
    assert "Launched in xterm" in flip.out.text()
    # the journal: what was ASKED of which boot of the device, no secret
    j = golive_target.read_journal(guest.work_dir, "rpi5/pki")
    assert j["action"] == "commit" and j["domain"] == "mesh.example"
    assert j["started_at"] == "2026-11-09T20:00:00Z"
    # the GUI only LAUNCHED the commit in a detached terminal: the device's TTY confirm
    # is what decides, so the journal never reads it as a commit that went through
    # (golive_target.journal_status, FG1 #927 final wording)
    assert j["confirmed"] is None
    shown = flip.status.toPlainText()
    assert "commit launched from this host" in shown
    assert "the confirmation happened on the device's TTY" in shown
    assert "last commit from this host" not in shown


def test_flip_without_a_terminal_shows_the_exact_ssh_command(emu_wiz, launched,
                                                            monkeypatch):
    monkeypatch.setattr(golive_target, "terminal_spec", lambda argv, **k: None)
    flip = _at_flip(emu_wiz)
    flip.confirm.setText("mesh.example")
    flip.flip_btn.click()
    assert not launched
    assert flip.manual.isVisible()
    cmd = flip.manual.text()
    assert cmd.startswith("ssh ") and " -t " in cmd
    assert "hugmesh-go-live commit --provider byo-domain --domain mesh.example" in cmd


def test_a_restart_since_the_commit_is_said(emu_wiz, guest, monkeypatch):
    golive_target.write_journal(
        golive_target.GoLiveTarget(kind=golive_target.KIND_DOCKER, label="rpi5/pki",
                                   started_at="2026-11-01T00:00:00Z",
                                   work_dir=guest.work_dir),
        "commit", "byo-domain", "mesh.example")
    flip = _at_flip(emu_wiz)
    assert "reset by a restart" in flip.status.toPlainText()


def test_this_host_off_node_cannot_flip_whatever_is_typed(wiz, baked_domain, monkeypatch,
                                                          launched):
    monkeypatch.setattr(golive_target, "local_node_refusal",
                        lambda *a, **k: "this host is not a HugMesh node — pick a device")
    pre = advance_to(wiz, golive_mod.GoLivePreflightPage)
    pre.rescan_btn.click()                           # the wizard was shown before the patch
    assert "commit is refused" in pre.target_info.text()
    assert pre.isComplete()                          # plan and status still preview
    flip = _at_flip(wiz)
    assert flip.refused.isVisible()
    assert "not a HugMesh node" in flip.refused.text()
    flip.confirm.setText(baked_domain)
    assert not flip.flip_btn.isEnabled()
    flip._flip()                                     # even if it were clicked
    assert not launched
    assert "not a HugMesh node" in flip.out.text()


def test_rollback_opens_no_message_box_and_takes_the_revert_tick(emu_wiz, launched,
                                                                monkeypatch):
    from hugmesh_studio.gui.qt import QtWidgets
    modals = []
    for name in ("warning", "information", "critical", "question"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name,
                            staticmethod(lambda *a, _n=name, **k: modals.append(_n)))
    monkeypatch.setattr(golive_target, "terminal_spec",
                        lambda argv, **k: golive_target.TerminalSpec(list(argv), 0, "x"))
    flip = _at_flip(emu_wiz)
    flip.persist.setChecked(True)
    assert flip.revert.isChecked()                  # a persisted flip needs the revert
    flip.rollback_btn.click()
    assert not modals
    argv = launched[-1][0]
    assert argv[0] == "ssh" and "-t" in argv
    assert argv[-1] == "sudo hugmesh-go-live rollback --revert-release-state"
    flip.revert.setChecked(False)
    flip.rollback_btn.click()
    assert launched[-1][0][-1] == "sudo hugmesh-go-live rollback"


def test_open_go_live_opens_a_new_wizard_for_another_device(qapp, guest):
    fake.register(guest, label="rpi5/pki")
    fake.register(guest, label="x86/be", platform="x86", role="backend", port=22404)
    first = golive_mod.open_go_live(GENERATOR_DIR, target="rpi5/pki")
    try:
        assert first.target.label == "rpi5/pki"
        assert golive_mod.open_go_live(GENERATOR_DIR, target="rpi5/pki",
                                       current=first) is first
        other = golive_mod.open_go_live(GENERATOR_DIR, target="x86/be", current=first)
        assert other is not first and other.target.label == "x86/be"
        other.close()
        other.deleteLater()
    finally:
        first.close()
        first.deleteLater()


# ---- the picked device is RE-BOUND to its fresh record (round 2 of #931) ------------
# A keep-alive device restarted by the harness comes back on the first FREE ssh port of
# a range (tests/qemu/run-qemu-docker.sh claim_port), with a new started_at; a stopped
# device's port can be handed to ANOTHER device. The wizard must never go on driving
# the record it read when the device was first picked.

def _restart(guest, label="rpi5/pki", port=22999, started_at="2026-11-10T09:00:00Z",
             **kw):
    return fake.register(guest, label=label, port=port, started_at=started_at, **kw)


def _flip_port(w):
    argv = golive_target.commit_argv(w.driver.target, "byo-domain", "mesh.example")
    return argv[argv.index("-p") + 1]


def test_rescan_after_a_restart_rebinds_to_the_new_port_and_boot(emu_wiz, guest):
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    assert emu_wiz.target.ssh_port == 22401
    emu_wiz.opts.provider = "byo-domain"
    golive_target.write_journal(emu_wiz.target, "commit", "byo-domain", "mesh.example",
                                confirmed=True)
    assert "reset by a restart" not in emu_wiz.journal_line()
    _restart(guest)                                  # new port, new boot
    pre.rescan_btn.click()
    assert emu_wiz.target.ssh_port == 22999
    assert emu_wiz.target.started_at == "2026-11-10T09:00:00Z"
    assert emu_wiz.driver.target.ssh_port == 22999, "the driver still sshes the OLD port"
    assert _flip_port(emu_wiz) == "22999"
    assert "reset by a restart" in emu_wiz.journal_line()
    assert "reset by a restart" in pre.status.toPlainText()
    assert "127.0.0.1:22999" in pre.target_info.text()
    # the same device: the provider picked for it is kept
    assert emu_wiz.opts.provider == "byo-domain"
    assert pre.isComplete()
    # the probe after the re-scan went to the NEW port
    probes = [c for c in guest.calls() if "::driver" in c[-1]]
    assert probes[-1][probes[-1].index("-p") + 1] == "22999"


def test_rescan_after_a_stop_and_port_reuse_refuses_the_stale_pick(emu_wiz, guest):
    from hugmesh_studio.gui.qt import QtCore
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    # rpi5/pki stops; the backend starts and the first-free port lock hands it 22401
    _restart(guest, port=22401, started_at="2026-11-09T20:00:00Z", state="stopped")
    _restart(guest, label="rpi5/be", role="backend", port=22401)
    pre.rescan_btn.click()
    i = pre.target_pick.currentIndex()
    assert pre._rows[i].label == "rpi5/pki" and not pre._rows[i].running
    assert not (pre.target_pick.model().item(i).flags() & QtCore.Qt.ItemFlag.ItemIsEnabled)
    assert pre.target_problem.isVisible()
    assert "rpi5/pki is not running" in pre.target_problem.text()
    assert "not running" in emu_wiz.target_refusal()
    assert "not running" in emu_wiz.commit_refusal()
    assert not pre.isComplete()
    # and the button a person presses follows: Next is greyed, Next does not move
    from hugmesh_studio.gui.qt import QtWidgets
    assert not _next_enabled(emu_wiz)


def test_picking_a_row_again_takes_the_record_as_it_is_now(emu_wiz, guest):
    """Target change: the picker's rows were read before the restart; picking the
    device re-reads its record instead of trusting the row."""
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    at = pre.target_pick.currentIndex()
    _restart(guest)
    pre.target_pick.setCurrentIndex(0)               # this host
    assert emu_wiz.target.is_local
    pre.target_pick.setCurrentIndex(at)              # back to rpi5/pki
    assert emu_wiz.target.label == "rpi5/pki"
    assert emu_wiz.target.ssh_port == 22999 and emu_wiz.driver.target.ssh_port == 22999


def test_filling_the_picker_rebinds_without_a_rescan(emu_wiz, guest):
    """Every fill of the picker (the step's initializePage, a re-scan) re-reads the
    work dir AND re-binds the picked device — not only the rows around it."""
    advance_to(emu_wiz, golive_mod.GoLiveExposurePage)
    _restart(guest)
    pre = back_to(emu_wiz, golive_mod.GoLivePreflightPage)
    pre.initializePage()
    assert emu_wiz.driver.target.ssh_port == 22999
    assert pre._rows[pre.target_pick.currentIndex()].ssh_port == 22999


def _next_enabled(w) -> bool:
    from hugmesh_studio.gui.qt import QtWidgets
    return w.button(QtWidgets.QWizard.WizardButton.NextButton).isEnabled()


def test_back_to_preflight_rebinds_a_restarted_device(emu_wiz, guest):
    """QWizard's Back never calls initializePage on the step it returns to. Coming
    Back to Preflight after the device restarted must still re-bind it — nobody has
    to know to click Re-scan — and Next then leads on with the NEW boot."""
    advance_to(emu_wiz, golive_mod.GoLiveExposurePage)
    assert emu_wiz.target.ssh_port == 22401
    _restart(guest)
    pre = back_to(emu_wiz, golive_mod.GoLivePreflightPage)      # real Back, nothing else
    assert emu_wiz.target.ssh_port == 22999
    assert emu_wiz.driver.target.ssh_port == 22999
    assert emu_wiz.target.started_at == "2026-11-10T09:00:00Z"
    assert pre._rows[pre.target_pick.currentIndex()].ssh_port == 22999
    assert emu_wiz.stale_binding() == ""
    assert "restarted" not in pre.status.toPlainText()
    assert pre.isComplete()
    assert _next_enabled(emu_wiz)


def test_back_to_preflight_after_a_stop_shuts_next(emu_wiz, guest):
    """Back after the picked device stopped (and its port went to another device):
    the step says so and Next stays shut — never the old 'still running' binding."""
    advance_to(emu_wiz, golive_mod.GoLiveExposurePage)
    _restart(guest, port=22401, started_at="2026-11-09T20:00:00Z", state="stopped")
    _restart(guest, label="rpi5/be", role="backend", port=22401)
    pre = back_to(emu_wiz, golive_mod.GoLivePreflightPage)
    assert not pre.isComplete()
    assert not _next_enabled(emu_wiz)
    assert pre.target_problem.isVisible() and "rpi5/pki" in pre.target_problem.text()


def test_preflight_next_is_shut_while_the_pick_is_stale(emu_wiz, guest):
    """The backstop: whatever path left the picked binding stale (no re-fill ran),
    Preflight's Next is shut until it is re-bound."""
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    assert pre.isComplete()
    _restart(guest)
    assert emu_wiz.stale_binding()
    assert not pre.isComplete()


def test_the_flip_refuses_a_device_that_restarted_since_it_was_picked(emu_wiz, guest,
                                                                      launched,
                                                                      monkeypatch):
    monkeypatch.setattr(golive_target, "terminal_spec",
                        lambda argv, **k: golive_target.TerminalSpec(list(argv), 0, "x"))
    flip = _at_flip(emu_wiz)
    flip.confirm.setText("mesh.example")
    assert flip.flip_btn.isEnabled()
    _restart(guest, port=22401, started_at="2026-11-09T20:00:00Z", state="stopped")
    _restart(guest, label="rpi5/be", role="backend", port=22401)
    flip.confirm.setText("")
    flip.confirm.setText("mesh.example")
    assert not flip.flip_btn.isEnabled()
    flip._flip()                                     # even if it were clicked
    flip._rollback()
    assert not launched, launched
    assert "rpi5/pki" in flip.out.text() and "Re-scan" in flip.out.text()


def test_the_flip_refuses_a_restart_on_a_new_port_and_says_so(emu_wiz, guest, launched,
                                                              monkeypatch):
    monkeypatch.setattr(golive_target, "terminal_spec",
                        lambda argv, **k: golive_target.TerminalSpec(list(argv), 0, "x"))
    flip = _at_flip(emu_wiz)
    _restart(guest)
    n = len(guest.calls())
    flip.initializePage()
    # nothing is asked of the old port: not even `status` (it could be another device)
    assert all(c[c.index("-p") + 1] != "22401" for c in guest.calls()[n:]), \
        guest.calls()[n:]
    assert "restarted" in flip.status.toPlainText()
    assert flip.refused.isVisible()
    assert "restarted" in flip.refused.text() and "22999" in flip.refused.text()
    flip.confirm.setText("mesh.example")
    assert not flip.flip_btn.isEnabled()
    flip._flip()
    assert not launched


def test_open_go_live_does_not_reuse_a_wizard_bound_to_an_old_boot(qapp, guest):
    fake.register(guest, label="rpi5/pki", port=22401)
    t1 = golive_target.find_target(golive_target.targets(guest.work_dir), "rpi5/pki")
    w = golive_mod.open_go_live(GENERATOR_DIR, target=t1, work_dir=guest.work_dir)
    w2 = w3 = None
    try:
        _restart(guest, port=22305)
        t2 = golive_target.find_target(golive_target.targets(guest.work_dir), "rpi5/pki")
        w2 = golive_mod.open_go_live(GENERATOR_DIR, target=t2, current=w,
                                     work_dir=guest.work_dir)
        assert w2.target.ssh_port == 22305 and w2.driver.target.ssh_port == 22305
        assert w2.target.started_at == "2026-11-10T09:00:00Z"
        # by LABEL (--go-live-target, the TUI's g): the label resolves to the fresh
        # record before reuse is decided
        _restart(guest, port=22306, started_at="2026-11-10T10:00:00Z")
        w3 = golive_mod.open_go_live(GENERATOR_DIR, target="rpi5/pki", current=w2,
                                     work_dir=guest.work_dir)
        assert w3.driver.target.ssh_port == 22306
        # unchanged record: the open wizard IS reused
        assert golive_mod.open_go_live(GENERATOR_DIR, target="rpi5/pki", current=w3,
                                       work_dir=guest.work_dir) is w3
    finally:
        for x in {id(v): v for v in (w, w2, w3) if v is not None}.values():
            x.close()
            x.deleteLater()


def test_open_go_live_by_label_does_not_reuse_a_wizard_whose_device_is_gone(qapp, guest):
    """The label is looked up in the work dir as it is NOW — not among the wizard's
    own rows, which always include the device it was opened on."""
    fake.register(guest, label="rpi5/pki", port=22401)
    w = golive_mod.open_go_live(GENERATOR_DIR, target="rpi5/pki", work_dir=guest.work_dir)
    w2 = None
    try:
        os.remove(os.path.join(guest.work_dir, "devices", "rpi5_pki.json"))
        w2 = golive_mod.open_go_live(GENERATOR_DIR, target="rpi5/pki", current=w,
                                     work_dir=guest.work_dir)
        assert w2 is not w
        pre = w2.page(w2._page_ids["preflight"])
        assert "no running device 'rpi5/pki'" in pre.target_problem.text()
    finally:
        for x in {id(v): v for v in (w, w2) if v is not None}.values():
            x.close()
            x.deleteLater()


# ---- Tailscale Funnel on an emulated mesh: refused on the face, not just in core -------

def test_funnel_is_refused_inline_on_the_provider_step_for_a_device(emu_wiz):
    pick_model(emu_wiz, "funnel")
    prov = advance_to(emu_wiz, golive_mod.GoLiveProviderPage)
    assert prov._current().id == "tailscale-funnel"
    assert prov.refused.isVisible()
    assert "headscale" in prov.refused.text() and "refused" in prov.refused.text()
    assert not prov.isComplete()
    before = emu_wiz.currentId()
    emu_wiz.next()
    assert emu_wiz.currentId() == before, "Next went past a refused provider"
    # and the flip would refuse it as well (belt and braces)
    emu_wiz.opts.provider = "tailscale-funnel"
    assert "headscale" in emu_wiz.commit_refusal()


def test_funnel_is_not_refused_on_this_host(wiz):
    pick_model(wiz, "funnel")
    prov = advance_to(wiz, golive_mod.GoLiveProviderPage)
    assert prov._current().id == "tailscale-funnel"
    assert not prov.refused.isVisible() and prov.isComplete()


# ---- what a person SEES: the picker and the banner, measured (not just "visible") ------

def _rect_in(widget, frame):
    from hugmesh_studio.gui.qt import QtCore
    return QtCore.QRect(widget.mapTo(frame, QtCore.QPoint(0, 0)), widget.size())


def _whole(label):
    return label.heightForWidth(label.width()) <= label.height() + 1


def _shoot(w, name, tmp_path):
    """Render the window to a PNG (GOLIVE_SHOTS_DIR keeps it for a human to look at)
    and hand back the image, so a test can assert it is not blank."""
    from hugmesh_studio.gui.qt import QtWidgets
    QtWidgets.QApplication.processEvents()
    img = w.grab().toImage()
    out = os.environ.get("GOLIVE_SHOTS_DIR") or str(tmp_path)
    os.makedirs(out, exist_ok=True)
    assert img.save(os.path.join(out, f"{name}.png"))
    return img


def test_the_target_picker_and_its_refusals_are_drawn_whole(emu_wiz, tmp_path):
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    img = _shoot(emu_wiz, "golive-preflight-target-picker", tmp_path)
    assert not img.isNull() and img.width() >= 800
    pick = pre.target_pick
    assert pick.isVisible() and emu_wiz.rect().contains(_rect_in(pick, emu_wiz))
    # as wide as its widest entry needs (a squeezed combo elides the device names)
    widest = max(pick.fontMetrics().horizontalAdvance(pick.itemText(i))
                 for i in range(pick.count()))
    assert pick.width() >= widest, (pick.width(), widest)
    for lb in (pre.target_info, pre.target_refusals):
        assert lb.isVisible() and lb.text()
        assert emu_wiz.rect().contains(_rect_in(lb, emu_wiz)), lb.text()
        assert _whole(lb), (lb.text(), lb.heightForWidth(lb.width()), lb.height())
    # the refusals sit UNDER the picker, not over it
    assert _rect_in(pre.target_refusals, emu_wiz).top() >= _rect_in(pick, emu_wiz).bottom()


def test_the_ephemeral_banner_is_drawn_whole_above_the_flip(emu_wiz, tmp_path):
    flip = _at_flip(emu_wiz)
    _shoot(emu_wiz, "golive-flip-ephemeral-banner", tmp_path)
    b = flip.ephemeral
    assert b.isVisible() and emu_wiz.rect().contains(_rect_in(b, emu_wiz))
    assert _whole(b), (b.heightForWidth(b.width()), b.height())
    assert b.width() >= 400                           # a banner, not a squeezed sliver
    # it is read before the button that acts: above GO LIVE, and the button is whole
    assert _rect_in(b, emu_wiz).bottom() <= _rect_in(flip.flip_btn, emu_wiz).top()
    btn = flip.flip_btn
    assert btn.isVisible() and emu_wiz.rect().contains(_rect_in(btn, emu_wiz))
    assert btn.width() >= btn.fontMetrics().horizontalAdvance(btn.text())
    _shoot(emu_wiz, "golive-flip-ephemeral-banner", tmp_path)


def test_the_funnel_refusal_is_drawn_whole_under_the_provider_list(emu_wiz, tmp_path):
    pick_model(emu_wiz, "funnel")
    prov = advance_to(emu_wiz, golive_mod.GoLiveProviderPage)
    _shoot(emu_wiz, "golive-provider-funnel-refused", tmp_path)
    r = prov.refused
    assert r.isVisible() and emu_wiz.rect().contains(_rect_in(r, emu_wiz))
    assert _whole(r), (r.heightForWidth(r.width()), r.height())
    assert r.width() >= 400
    assert _rect_in(r, emu_wiz).top() >= _rect_in(prov.list, emu_wiz).bottom()


def test_a_stale_pick_after_rescan_is_drawn_whole_under_the_picker(emu_wiz, guest,
                                                                   tmp_path):
    pre = advance_to(emu_wiz, golive_mod.GoLivePreflightPage)
    _restart(guest, port=22401, started_at="2026-11-09T20:00:00Z", state="stopped")
    pre.rescan_btn.click()
    _shoot(emu_wiz, "golive-preflight-rescan-stopped", tmp_path)
    lb = pre.target_problem
    assert lb.isVisible() and emu_wiz.rect().contains(_rect_in(lb, emu_wiz))
    assert _whole(lb), (lb.heightForWidth(lb.width()), lb.height())
    assert _rect_in(lb, emu_wiz).top() >= _rect_in(pre.target_pick, emu_wiz).bottom()
