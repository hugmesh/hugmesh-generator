"""The generate-a-new-local-mesh route's DOMAINS and DOMAIN SERVICES steps (issue #494).

Reported 2026-09-23: "There's still no gui based multidomain config in the studio for
the generate new mesh path" and "it's impossible in studio still to be able to change
the services per domain, the checkbox doesn't seem to be present on each domain page".
Both were true: the route carried ONE domain field (``boot_domain``, on the prod-only
overlay step) and no per-domain services, so the #495 gate ``_bootstrap_up`` calls
could never bite on it.

What is pinned here, driving the wizard HEADLESS through the route:

* the two steps sit right after Env & brand and are visited on the generate branch;
* row 0 of the Domains step is the mesh's own domain — fixed on a test mesh, typed on
  a prod one, and the overlay's Domain field is a read-only MIRROR of it;
* the services stepper (the image flow's page, re-hosted) visits EVERY domain, the
  own one first;
* the SAME gate (``domain_services.gate_reason``, ACTION_MESH_START) refuses an
  un-reviewed domain on BOTH start doors, names it AND the step to go back to, and
  clears once the domain has been walked;
* Sign-in=Own rows feed ``LocalMeshBootstrapConfig.own_idp_domains`` and the
  per-domain selection is RECORDED (``.domains``), not what picks the compose
  profiles;
* EMISSION NEUTRALITY: an operator who only clicks Next through the new steps
  collects a LocalMeshBootstrapConfig, a stack env and a plan byte-identical to the
  ones from before the steps existed;
* no modal anywhere in the new page logic (a source scan).
"""
import copy
import inspect
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import domain_services as ds                  # noqa: E402
from hugmesh_studio.core.config import (                                # noqa: E402
    DOMAIN_IDP_OWN, OPTIONAL_SERVICES_CHOICES, ImageConfig)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LOCAL_MESH_REMEDY   # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import domain_services as dsp_mod        # noqa: E402
from hugmesh_studio.gui.pages import domains as domains_mod            # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod        # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                        # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-localmesh-domains-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _to_env(wiz):
    """Welcome -> Mode "Local Docker mesh" -> choice "Generate" -> Env & brand."""
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    choice = wiz.currentPage()
    choice._buttons["generate"].setChecked(True)
    wiz.next()
    env = wiz.currentPage()
    assert isinstance(env, localmesh_mod.LocalMeshEnvPage), type(env).__name__
    return env


def _to(wiz, cls, limit=14):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(wiz.currentPage()).__name__}"
    raise AssertionError(f"never reached {cls.__name__}: "
                         + type(wiz.currentPage()).__name__)


def _back_to(wiz, cls, limit=14):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        wiz.back()
    raise AssertionError(f"never reached {cls.__name__} going back")


def _ctl(wiz):
    return wiz.page(wiz._page_ids["localmesh"])


def _snapshot(ctl):
    """Everything a bring-up EMITS from the form: the config, the stack env the
    compose lane would run with, and the plan the operator reads."""
    cfg = ctl.collect_bootstrap()
    boot = ctl.boot.__class__(ctl.generator_dir, cfg)
    return (cfg.to_dict(), dict(boot._stack_node()._build_env()), boot.plan())


# ── 1. the steps are on the route, in the right place ──────────────────────────────
def test_the_two_steps_follow_env_and_brand(wiz):
    _to_env(wiz)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainServicesPage)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshSourcePage)


def test_the_steps_are_registered_in_the_slot_expansion():
    slugs = [s for s, _c in wizard_mod._LOCALMESH_STEPS]
    i = slugs.index("localmesh_env")
    assert slugs[i + 1:i + 4] == ["localmesh_domains", "localmesh_domain_services",
                                   "localmesh_source"]


def test_the_steps_hold_no_widgets_they_claim_the_controllers_sections(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    step = _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    assert ctl.sections["domains"].parentWidget() is step._lay.parentWidget()
    assert ctl.domains_table.parentWidget() is ctl.sections["domains"]
    step2 = _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    assert ctl.sections["domain_services"].parentWidget() is step2._lay.parentWidget()
    assert isinstance(ctl.domain_services, dsp_mod.DomainServicesWidget)


# ── 2. row 0 is the mesh's own domain ──────────────────────────────────────────────
def test_row_0_is_the_brand_default_apex_on_a_test_mesh_and_is_fixed(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    assert ctl.env_test.isChecked()
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    t = ctl.domains_table
    assert t.is_own_row(0)
    own = LocalMeshBootstrapConfig().resolved_domain()
    assert t.table.item(0, 0).text() == own
    assert not (t.table.item(0, 0).flags() & Qt.ItemFlag.ItemIsEditable)
    assert ctl.mesh_domains.own_name == own
    assert [d.name for d in ctl.mesh_domains.domains] == [own]
    # the columns this route cannot fill are hidden, not offered with one answer
    assert t.table.isColumnHidden(domains_mod._COL_APPLIES)
    assert t.table.isColumnHidden(domains_mod._COL_CA)
    assert not t.table.isColumnHidden(domains_mod._COL_IDP)


def test_the_own_row_cannot_be_removed_and_says_so_inline(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    t = ctl.domains_table
    t._add("acme.example", "Acme")
    t.table.selectAll()
    t._remove()
    assert t.table.rowCount() == 1 and t.is_own_row(0)
    assert t.row_note.isVisibleTo(t) and "cannot be removed" in t.row_note.text()


def test_the_own_row_is_not_seeded_before_the_step_is_visited(wiz):
    """A host with no steps (LocalMeshDialog) and a saved-mesh Start on a flow that
    never opened the step keep passing the gate exactly as before."""
    ctl = _ctl(wiz)
    _to_env(wiz)
    assert ctl.mesh_domains.domains == []
    assert ctl._domain_services_refusal() == ""


# ── 3. emission neutrality ─────────────────────────────────────────────────────────
def test_an_untouched_walk_through_both_steps_emits_byte_identically(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    before = _snapshot(ctl)
    # the pre-#494 shape of the domain fields (the GUI has always collected
    # services/kind_addons explicitly — see collect_bootstrap — so only these three
    # are compared to a bare config)
    bare = LocalMeshBootstrapConfig().to_dict()
    for k in ("domains", "own_idp_domains", "cluster_domain"):
        assert before[0][k] == bare[k], k
    _to(wiz, localmesh_mod.LocalMeshPage)                          # Next, Next, …
    after = _snapshot(ctl)
    assert after == before
    cfg = ctl.collect_bootstrap()
    assert cfg.domains == () and cfg.own_idp_domains == () and cfg.cluster_domain == ""
    assert "domains recorded" not in ctl.boot.plan()
    # …and the gate is satisfied: the own domain was shown on its page
    assert ctl._domain_services_refusal() == ""


# ── 4. the stepper visits every domain, own first ──────────────────────────────────
def _two_added(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    ctl.domains_table._add("acme.example", "Acme")
    ctl.domains_table._add("team.example", "Team", idp=DOMAIN_IDP_OWN)
    return ctl


def test_the_services_stepper_walks_every_domain_own_domain_first(wiz):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    w = ctl.domain_services
    own = ctl.mesh_domains.own_name
    assert [d.name for d in ctl.mesh_domains.domains] == [own, "acme.example",
                                                          "team.example"]
    assert w.current_domain() == own
    assert "this mesh's own domain" in w.head.text()
    assert "1 of 3" in w.subtitle_label.text()
    assert w.unconfigured() == ["acme.example", "team.example"]
    w._step(1)
    assert w.current_domain() == "acme.example"
    w._step(1)
    assert w.current_domain() == "team.example"
    assert "3 of 3" in w.subtitle_label.text()
    assert w.unconfigured() == []
    # the same catalogue and the same honesty line as the image flow's page
    assert sorted(w._boxes) == sorted(OPTIONAL_SERVICES_CHOICES)
    assert "NOT YET ENFORCED AT THE CLUSTER" in w.enforcement.text()
    assert w.lane_note.isVisibleTo(w)
    assert "NOT what decides" in w.lane_note.text()


# ── 5. the gate, on both doors ─────────────────────────────────────────────────────
def test_the_start_refuses_an_unwalked_domain_and_names_the_step(wiz, monkeypatch):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)     # own domain shown only
    _to(wiz, localmesh_mod.LocalMeshPage)
    started = []
    monkeypatch.setattr(ctl, "_launch", lambda *a, **k: started.append(a))
    ctl._bootstrap_up()
    assert started == []
    text = ctl.status.text()
    assert "acme.example" in text and "team.example" in text
    assert ctl.mesh_domains.own_name not in text.split("—")[0].split(":", 1)[1] \
        if ":" in text else True
    assert "start this mesh" in text
    assert LOCAL_MESH_REMEDY in text                        # the step to go back to
    assert "image flow" not in text                         # not the image-flow remedy


def test_the_saved_mesh_start_is_gated_by_the_same_rows(wiz, monkeypatch):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    review = _to(wiz, localmesh_mod.LocalMeshReviewPage)
    assert isinstance(review, localmesh_mod.LocalMeshReviewPage)
    started, applied = [], []
    monkeypatch.setattr(ctl, "_launch", lambda *a, **k: started.append(a))
    monkeypatch.setattr(ctl, "apply_bootstrap", lambda *a, **k: applied.append(a) or [])
    rec = SimpleNamespace(id="r", label="r", form={},
                          config=LocalMeshBootstrapConfig().to_dict())
    ctl._start_saved(rec, "start")
    assert started == [] and applied == []
    assert "team.example" in ctl.status.text() and LOCAL_MESH_REMEDY in ctl.status.text()


def test_walking_the_domains_clears_the_gate_and_the_mesh_starts(wiz, monkeypatch):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    _to(wiz, localmesh_mod.LocalMeshPage)
    assert ctl._domain_services_refusal() != ""
    step = _back_to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    assert isinstance(step, localmesh_mod.LocalMeshDomainServicesPage)
    ctl.domain_services._step(1)
    ctl.domain_services._step(1)
    _to(wiz, localmesh_mod.LocalMeshPage)
    assert ctl._domain_services_refusal() == ""
    started = []
    monkeypatch.setattr(ctl, "_launch", lambda *a, **k: started.append(a))
    ctl._bootstrap_up()
    assert started, "a configured mesh must start: " + ctl.status.text()


def test_the_gate_reads_the_one_seam(wiz):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    _to(wiz, localmesh_mod.LocalMeshPage)
    assert ctl._domain_services_refusal() == ds.gate_reason(
        ctl.mesh_domains, ds.ACTION_MESH_START, remedy=LOCAL_MESH_REMEDY)


def test_a_domain_left_by_back_still_counts_as_walked_and_keeps_its_ticks(wiz):
    """Qt calls cleanupPage, not validatePage, on Back — the walk AND the ticks must
    be recorded either way. The gate re-records before it asks, so the discriminating
    read is ``collect_bootstrap()``, which does not: a tick made just before Back has
    to be in the record already."""
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    ctl.domain_services._step(1)                          # acme.example
    ctl.domain_services._boxes["games"].setChecked(True)
    ctl.domain_services._step(1)                          # team.example
    wiz.back()                                            # to the Domains step
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage)
    rec = {d["name"]: d for d in ctl.collect_bootstrap().domains}
    assert rec["acme.example"]["optional_services"] == ["games"]
    assert ctl.domains_table.table.cellWidget(1, 2).text() == "games"   # mirror caught up
    assert ctl._domain_services_refusal() == ""


# ── 6. what the rows turn into ─────────────────────────────────────────────────────
def test_own_sign_in_rows_feed_own_casdoor_domains_and_rows_are_recorded(wiz):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    w = ctl.domain_services
    w._step(1)                                            # acme.example
    w._boxes["games"].setChecked(True)
    w._step(1)                                            # team.example
    _to(wiz, localmesh_mod.LocalMeshReviewPage)
    cfg = ctl.collect_bootstrap()
    assert cfg.own_idp_domains == ("team.example",)
    assert cfg.domains == (
        {"name": "acme.example", "title": "Acme", "idp": "superdomain",
         "optional_services": ["games"]},
        {"name": "team.example", "title": "Team", "idp": DOMAIN_IDP_OWN,
         "optional_services": []},
    )
    # the own domain is default-shaped and therefore NOT recorded
    assert ctl.mesh_domains.own_name not in [d["name"] for d in cfg.domains]
    plan = ctl.boot.plan()
    assert "domains recorded" in plan and "acme.example" in plan and "games" in plan
    assert "RECORDED, not enforced" in plan
    assert "team.example: host port 8001" in plan


def test_the_per_domain_selection_does_not_change_the_compose_profiles(wiz):
    ctl = _two_added(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    services_before = ctl.collect_bootstrap().services
    w = ctl.domain_services
    w._step(1)
    w._boxes["games"].setChecked(True)
    w._boxes["akkoma"].setChecked(True)
    w._step(1)
    _to(wiz, localmesh_mod.LocalMeshReviewPage)
    assert ctl.collect_bootstrap().services == services_before
    assert ctl.collect_bootstrap().domains[0]["optional_services"] == ["akkoma", "games"]


def test_a_reviewed_selection_survives_a_round_trip_through_apply_bootstrap(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    rec = LocalMeshBootstrapConfig(
        cluster_domain="",
        domains=({"name": "a.example", "title": "A", "idp": DOMAIN_IDP_OWN,
                  "optional_services": ["games"]},),
        own_idp_domains=("a.example", "b.example"))
    missing = ctl.apply_bootstrap(rec)
    assert "own_idp_domains" not in missing                 # the page HAS a control now
    own = LocalMeshBootstrapConfig().resolved_domain()
    rows = {d.name: d for d in ctl.mesh_domains.domains}
    assert list(rows) == [own, "a.example", "b.example"]
    assert rows["a.example"].idp == DOMAIN_IDP_OWN and rows["a.example"].optional_services == ["games"]
    assert rows["b.example"].idp == DOMAIN_IDP_OWN           # a CLI-made record's name
    # a record only exists after a start that passed the gate: its rows are walked
    assert ctl._domain_services_refusal() == ""
    assert ctl.domains_table.table.rowCount() == 3 and ctl.domains_table.is_own_row(0)
    again = ctl.collect_bootstrap()
    assert again.own_idp_domains == ("a.example", "b.example")
    assert again.domains[0]["name"] == "a.example"


def test_a_pre_494_record_leaves_the_domain_state_alone(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    missing = ctl.apply_bootstrap(LocalMeshBootstrapConfig())
    assert "own_idp_domains" not in missing and "auth_key" in missing
    assert ctl.mesh_domains.domains == []
    assert not ctl.boot_domain.isReadOnly()


# ── 7. prod: row 0 is typed here, the overlay field mirrors it ────────────────────
def test_prod_row_0_is_typed_on_the_domains_step_and_mirrored_on_the_overlay(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    ctl.env_prod.setChecked(True)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    t = ctl.domains_table
    assert t.is_own_row(0) and t.table.item(0, 0).text() == ""
    assert t.table.item(0, 0).flags() & Qt.ItemFlag.ItemIsEditable
    t.table.item(0, 0).setText("example.com")
    wiz.next()                                            # commits row 0
    assert ctl.boot_domain.text() == "example.com"
    assert ctl.boot_domain.isReadOnly()
    assert ctl.mesh_domains.own_name == "example.com"
    overlay = _to(wiz, localmesh_mod.LocalMeshOverlayPage)
    assert isinstance(overlay, localmesh_mod.LocalMeshOverlayPage)
    assert ctl.boot_domain_note.isVisibleTo(ctl.boot_domain_note.parentWidget())
    cfg = ctl.collect_bootstrap()
    assert cfg.cluster_domain == "example.com"
    assert cfg.domains == ()                               # default-shaped: not a record
    # a record applied elsewhere (the review step's Load) lands in row 0 too — one
    # field, two views: the step re-reads the mirror on every entry
    _back_to(wiz, localmesh_mod.LocalMeshEnvPage)
    ctl.boot_domain.setText("loaded.example")
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    assert t.table.item(0, 0).text() == "loaded.example"
    assert ctl.mesh_domains.own_name == "loaded.example"
    assert [d.name for d in ctl.mesh_domains.domains] == ["loaded.example"]


def test_a_blank_prod_apex_is_an_inline_note_never_a_refusal_to_advance(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    ctl.env_prod.setChecked(True)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainServicesPage)
    assert ctl.domains_note.isVisibleTo(ctl.domains_note.parentWidget())
    assert "public apex" in ctl.domains_note.text()
    # the bring-up's own validate() is what refuses it, as it always has
    assert any("cluster domain" in p for p in ctl.boot.validate())


def test_switching_env_renames_row_0_rather_than_adding_a_second_own_row(wiz):
    ctl = _ctl(wiz)
    _to_env(wiz)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    ctl.domains_table._add("acme.example", "Acme")
    _back_to(wiz, localmesh_mod.LocalMeshEnvPage)
    ctl.env_prod.setChecked(True)
    _to(wiz, localmesh_mod.LocalMeshDomainsPage)
    names = [d.name for d in ctl.mesh_domains.domains]
    assert names == ["", "acme.example"]                   # own row now blank, typed here
    assert ctl.domains_table.table.rowCount() == 2


# ── 8. the branch stays off image modes, and no modal anywhere ────────────────────
@pytest.mark.parametrize("mode", ["mesh", "cloud", "standalone"])
def test_the_new_steps_are_skipped_on_every_image_mode(wiz, mode):
    wiz.next()
    mp = wiz.currentPage()
    mp._buttons[mode].setChecked(True)
    mp._on_mode_toggled()
    assert mp.validatePage() is True
    for slug in ("localmesh_domains", "localmesh_domain_services"):
        assert wiz.page(wiz._page_ids[slug]).applies_to(wiz.cfg) is False


def test_no_modal_in_the_new_page_logic():
    for mod, cls in ((localmesh_mod, "LocalMeshDomainsPage"),
                     (localmesh_mod, "LocalMeshDomainServicesPage"),
                     (domains_mod, "DomainsTableBody"),
                     (domains_mod, "DomainsTableWidget"),
                     (dsp_mod, "DomainServicesWidget")):
        src = inspect.getsource(getattr(mod, cls))
        assert "QMessageBox" not in src, cls
        assert ".exec(" not in src, cls
    for name in ("_seed_domains", "_commit_domains", "_apply_domains",
                 "_domain_services_refusal", "_build_domains_section",
                 "_build_domain_services_section"):
        src = inspect.getsource(getattr(localmesh_mod.LocalMeshPage, name))
        assert "QMessageBox" not in src and ".exec(" not in src, name


def test_a_standalone_host_with_no_steps_keeps_the_whole_surface_and_passes(qapp):
    page = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=ImageConfig(mode="mesh")))
    page.initializePage()
    assert page.domains_table.table.rowCount() == 0
    assert page._domain_services_refusal() == ""
    assert not page.boot_domain.isReadOnly()
