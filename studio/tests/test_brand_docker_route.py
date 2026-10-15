"""The Docker route's brand drop-down and its 'Design your superbrand' step
(hugmesh-generator#654, decision D8; lane studio-docker-brand-mount).

On the local-mesh route the editable ``Brand`` box on 'Environment and brand' is the
superbrand drop-down (``gui/pages/brand_picker.py``): ‘Create a new superbrand’ first and
selected, then this configuration's own superbrand, the saved designs and the
``brands/*.conf`` profiles. Choosing Create opens the design under it; choosing an existing
profile shows a read-only summary and a ‘Change it’ click.

What these tests pin, in order of importance:

 1. ZERO REGRESSION. A person who walks through the page without touching the brand gets
    the SAME bootstrap configuration as before: brand ``hugmesh``, an empty superbrand
    block, no record file written.
 2. THE DEAD-FIELD CLASS (the comment on ``collect_bootstrap``): a choice or a design made
    on the page reaches the configuration the bring-up reads, and a saved mesh puts it
    back on the page.
 3. THE TWO SPELLINGS OF TOR: the design's block must not carry a Tor choice that the
    page's own Tor tick can contradict (the start refuses a record that disagrees with the
    flags).
 4. NO MODAL in anything this lane added.
"""
import inspect
import os
import types

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                    # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import (                         # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.gui.pages import localmesh as lm_mod                       # noqa: E402
from hugmesh_studio.gui.pages.brand_picker import BrandPicker                  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

CREATE = "Create a new superbrand"


@pytest.fixture
def ctl(tmp_path, monkeypatch):
    """A local-mesh controller page with its Environment-and-brand section mounted, as
    the wizard's step mounts it, and a state folder of its own (the record and the
    saved designs are written there, never in the operator's)."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    page = lm_mod.LocalMeshPage(shim)
    page.show()
    page.mount_brand()
    yield page
    page.close()
    del page, app


def _type(step, field, value):
    box = step.fields[field]
    box.setText(value)
    box.editingFinished.emit()


# ── 1. the drop-down replaces the editable box ──────────────────────────────────────
def test_the_brand_box_is_the_superbrand_drop_down(ctl):
    assert isinstance(ctl.brand_picker, BrandPicker)
    # the page keeps the name `brand` as text (collect_bootstrap and the saved-mesh
    # round trip read it that way) but it is no longer a box a person types a slug into
    assert not isinstance(ctl.brand, QtWidgets.QWidget)


def test_create_is_first_and_selected_and_the_design_is_open(ctl):
    p = ctl.brand_picker
    labels = p.item_labels()
    assert labels[0] == CREATE
    assert p.current_key() == "create"
    assert ctl.superbrand_design.design.isVisibleTo(ctl.superbrand_design)
    # the shipped profiles follow it (brands/example.conf is in this checkout)
    assert any("example" in x for x in labels[1:])


def test_an_untouched_walk_is_the_configuration_main_gives(ctl, tmp_path):
    cfg = ctl.collect_bootstrap()
    assert cfg.brand == "hugmesh"
    assert cfg.superbrand == {}
    ctl.leave_brand()                   # Next on the step, nothing touched
    assert ctl.collect_bootstrap().to_dict() == cfg.to_dict()
    assert not os.path.exists(brand_model.record_path()), "an untouched step wrote a record"


def test_the_standalone_dialog_has_a_working_drop_down_too(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    dlg = lm_mod.LocalMeshDialog(GENERATOR_DIR)
    try:
        page = dlg.page
        assert page.brand_picker.item_labels()[0] == CREATE
        assert page.brand_picker.current_key() == "create"
        assert page.superbrand_design.session is page.brand_picker.session
    finally:
        dlg.close()
        del dlg, app


# ── 2. choosing an existing profile skips the design ────────────────────────────────
def test_an_existing_profile_shows_a_summary_and_a_change_it_click(ctl):
    p = ctl.brand_picker
    p.select("profile:example")
    assert not ctl.superbrand_design.design.isVisibleTo(ctl.superbrand_design)
    assert p.summary.isVisibleTo(p) and p.change_btn.isVisibleTo(p)
    assert ctl.brand.currentText() == "example"
    assert ctl.collect_bootstrap().brand == "example"
    p.change_btn.click()
    assert ctl.superbrand_design.design.isVisibleTo(ctl.superbrand_design)


def test_choosing_create_again_reopens_the_design(ctl):
    ctl.brand_picker.select("profile:example")
    ctl.brand_picker.select("create")
    assert ctl.superbrand_design.design.isVisibleTo(ctl.superbrand_design)


def test_a_refusal_is_said_once_not_beside_the_drop_down_too(ctl):
    _type(ctl.superbrand_design, "id", "Not A Slug")
    assert ctl.superbrand_design.note.text()
    assert ctl.brand_picker.note.isHidden(), ctl.brand_picker.note.text()


def test_the_sentence_about_what_a_design_saves_shows_under_an_open_design_only(ctl):
    note = ctl.brand_effect_note
    assert note.isVisibleTo(ctl)
    ctl.brand_picker.select("profile:example")
    assert not note.isVisibleTo(ctl)
    ctl.brand_picker.change_btn.click()
    assert note.isVisibleTo(ctl)


# ── 3. a design reaches the configuration, the plan and the record ──────────────────
def test_a_designed_superbrand_reaches_the_bootstrap_configuration(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    _type(step, "title", "Acme Mesh")
    _type(step, "org", "example")
    cfg = ctl.collect_bootstrap()
    assert cfg.brand == "acme"
    assert cfg.superbrand["title"] == "Acme Mesh"
    assert "Acme Mesh" in ctl.plan_view.toPlainText()
    assert "acme" not in cfg.cluster_domain          # the public name is not invented


def test_a_design_survives_the_look_being_edited(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    ed = step.look_editor
    ed.primary.setText("#336699")
    ed.primary.editingFinished.emit()
    assert ctl.collect_bootstrap().superbrand["look"]["primary"] == "#336699"


def test_a_refused_id_is_said_inline_and_changes_nothing(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "Not A Slug")
    assert step.note.isVisibleTo(step) and step.note.text()
    assert ctl.collect_bootstrap().brand == "hugmesh"


def test_leaving_the_step_writes_the_record_through_the_record_module(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    _type(step, "title", "Acme Mesh")
    ctl.leave_brand()
    rec = brand_model.load_record()
    assert rec.superbrand.id == "acme" and rec.superbrand.title == "Acme Mesh"


def test_the_public_name_has_one_editing_home_and_the_design_says_where(ctl):
    box = ctl.superbrand_design.fields["public_name"]
    assert not box.isEnabled()
    assert "Domains" in box.toolTip()


def test_the_records_public_name_follows_the_domain_the_page_holds(ctl):
    _type(ctl.superbrand_design, "id", "acme")
    ctl.env_prod.setChecked(True)
    ctl.boot_domain.setText("mesh.example")
    ctl.leave_brand()
    assert brand_model.load_record().superbrand.public_name == "mesh.example"
    # the block the bring-up gets never holds a name that could go stale
    assert "public_name" not in ctl.collect_bootstrap().superbrand
    assert ctl.collect_bootstrap().cluster_domain == "mesh.example"


def test_the_records_sign_in_address_follows_a_switch_to_prod_after_the_first_commit(ctl):
    """The first commit writes the DERIVED sign-in address (http://localhost:8000 on a
    test mesh) back onto the carrier; a key that is merely present must not freeze it."""
    _type(ctl.superbrand_design, "id", "acme")           # committed on a test mesh
    ctl.env_prod.setChecked(True)
    ctl.boot_domain.setText("mesh.example")
    ctl.leave_brand()
    rec = brand_model.load_record()
    assert rec.superbrand.public_name == "mesh.example"
    assert rec.superbrand.central_signin == "https://id.mesh.example"


def test_a_sign_in_address_a_saved_mesh_chose_itself_is_kept(ctl):
    saved = LocalMeshBootstrapConfig(
        brand="acme", superbrand={"title": "Acme Mesh",
                                  "central_signin": "https://sso.example/realms/acme"})
    ctl.apply_bootstrap(saved)
    ctl.brand_picker.change_btn.click()
    _type(ctl.superbrand_design, "org", "example")
    ctl.env_prod.setChecked(True)
    ctl.boot_domain.setText("mesh.example")
    ctl.leave_brand()
    assert brand_model.load_record().superbrand.central_signin == \
        "https://sso.example/realms/acme"


def test_the_block_the_bring_up_gets_drops_a_derived_sign_in_address_on_a_switch_to_prod(ctl):
    """The record file is re-derived at the save (the test above); the block that
    ``collect_bootstrap`` hands the bring-up must be too. The first commit writes the
    test mesh's localhost sign-in onto the carrier, so a block passed on as it stands
    would send the localhost address into a production bring-up."""
    _type(ctl.superbrand_design, "id", "acme")           # committed on a test mesh
    assert "central_signin" not in ctl.collect_bootstrap().superbrand
    ctl.env_prod.setChecked(True)
    ctl.boot_domain.setText("mesh.example")
    ctl.leave_brand()
    block = ctl.collect_bootstrap().superbrand
    assert "central_signin" not in block, block
    assert "localhost" not in str(block)


def test_the_block_the_bring_up_gets_keeps_a_sign_in_address_a_saved_mesh_chose(ctl):
    chosen = "https://sso.example/realms/acme"
    ctl.apply_bootstrap(LocalMeshBootstrapConfig(
        brand="acme", superbrand={"title": "Acme Mesh", "central_signin": chosen}))
    ctl.env_prod.setChecked(True)
    ctl.boot_domain.setText("mesh.example")
    ctl.leave_brand()
    assert ctl.collect_bootstrap().superbrand.get("central_signin") == chosen


# ── 4. Tor: one place says it ──────────────────────────────────────────────────────
def test_the_block_the_page_passes_on_never_carries_a_tor_choice(ctl):
    _type(ctl.superbrand_design, "id", "acme")
    ctl.with_tor.setChecked(True)
    cfg = ctl.collect_bootstrap()
    assert "tor" not in (cfg.superbrand.get("ways") or {})
    ctl.with_tor.setChecked(False)
    cfg = ctl.collect_bootstrap()
    assert "tor" not in (cfg.superbrand.get("ways") or {})
    # and the start's own check finds no contradiction either way
    boot = LocalMeshBootstrap(GENERATOR_DIR, cfg)
    assert not [p for p in boot.validate() if "brand record" in p], boot.validate()


def test_ticking_tor_after_the_session_was_made_does_not_refuse_the_design(ctl):
    """The session caches the Tor way it read when it was made; the start refuses a
    record whose Tor way disagrees with the selection. The design must still be taken."""
    ctl.with_tor.setChecked(True)
    _type(ctl.superbrand_design, "id", "acme")
    assert ctl.superbrand_design.note.isHidden(), ctl.superbrand_design.note.text()
    assert ctl.collect_bootstrap().brand == "acme"
    ctl.leave_brand()
    assert brand_model.load_record().superbrand.ways.get("tor") is True


# ── 5. the saved mesh puts the choice back ──────────────────────────────────────────
def test_a_saved_mesh_round_trips_the_designed_superbrand(ctl):
    _type(ctl.superbrand_design, "id", "acme")
    _type(ctl.superbrand_design, "title", "Acme Mesh")
    saved = LocalMeshBootstrapConfig.from_dict(ctl.collect_bootstrap().to_dict())
    ctl.brand_picker.select("create")
    ctl.apply_bootstrap(saved)
    assert ctl.brand.currentText() == "acme"
    assert ctl.brand_picker.current_key() == "current:acme"
    assert not ctl.superbrand_design.design.isVisibleTo(ctl.superbrand_design)
    assert ctl.collect_bootstrap().to_dict() == saved.to_dict()


def test_a_saved_mesh_with_a_plain_profile_selects_it(ctl):
    ctl.apply_bootstrap(LocalMeshBootstrapConfig(brand="example"))
    assert ctl.brand.currentText() == "example"
    assert ctl.collect_bootstrap().brand == "example"


def test_the_old_text_spelling_still_sets_the_brand(ctl):
    # tests/test_local_mesh_source_axis.py sets the brand this way
    ctl.brand.setCurrentText("example")
    assert ctl.collect_bootstrap().brand == "example"
    assert "brands/example.conf" not in ctl.brand_note.text()


def test_the_brand_note_still_says_a_missing_profile(ctl):
    ctl.brand.setCurrentText("nosuchprofile")
    ctl._refresh_plan()
    assert "No brands/nosuchprofile.conf" in ctl.brand_note.text()


def test_no_missing_profile_note_is_drawn_under_the_default_create(ctl):
    """brands/hugmesh.conf does not exist in this checkout, and the note about it is
    about a profile the person PICKED. Under ‘Create a new superbrand’ (selected on first
    sight) it read as a warning about something they did not choose. Looked at too: the
    label is hidden, not an empty line."""
    assert ctl.brand_picker.current_key() == "create"
    assert not os.path.exists(os.path.join(GENERATOR_DIR, "brands", "hugmesh.conf"))
    ctl._refresh_plan()
    assert ctl.brand_note.text() == "" and not ctl.brand_note.isVisibleTo(ctl)
    _type(ctl.superbrand_design, "id", "acme")           # a design being typed: still none
    ctl._refresh_plan()
    assert ctl.brand_note.text() == ""
    # a picked profile with no file still says it (the sentence is kept for that case)
    ctl.brand.setCurrentText("nosuchprofile")
    ctl._refresh_plan()
    assert ctl.brand_note.text().startswith("No brands/nosuchprofile.conf")


def test_a_failure_in_the_brand_step_is_one_plain_sentence_on_the_page(ctl, monkeypatch, capsys):
    """mount_brand, _brand_changed and leave_brand used to print a traceback to the
    terminal and leave a half-drawn page with no word; each now says one sentence where
    the person is looking and a good run clears it. (Mutation: make _brand_swallow only
    print.)"""
    def boom(*_a, **_k):
        raise RuntimeError("deliberate")
    for where, call in (("mount_brand", ctl.mount_brand), ("_brand_changed", ctl._brand_changed),
                        ("leave_brand", ctl.leave_brand)):
        with monkeypatch.context() as m:
            m.setattr(ctl, "_brand_sync_in", boom)
            ctl._brand_mounted = True
            call()
        assert ctl.brand_error.isVisibleTo(ctl), where
        assert "nothing was changed" in ctl.brand_error.text(), where
        assert "deliberate" in capsys.readouterr().err, where     # the debugger still gets it
        ctl.mount_brand()                                          # a good run clears it
        assert not ctl.brand_error.isVisibleTo(ctl) and ctl.brand_error.text() == "", where
    # the drop-down says it too when a pick cannot be applied
    p = ctl.brand_picker
    monkeypatch.setattr(p.session, "choose", boom)
    p.select("profile:example")
    assert p.note.isVisibleTo(p) and "nothing was changed" in p.note.text()


# ── 6. no modal in what this lane added ─────────────────────────────────────────────
def test_nothing_this_lane_added_opens_a_dialog():
    for name in ("mount_brand", "leave_brand", "_brand_changed", "_brand_sync_in",
                 "_fix_design_widgets", "_set_brand_id", "_adopt_brand",
                 "_superbrand_block"):
        src = inspect.getsource(getattr(lm_mod.LocalMeshPage, name))
        for bad in ("QMessageBox", ".exec(", "QInputDialog", "QFileDialog"):
            assert bad not in src, f"LocalMeshPage.{name} uses {bad}"


# ── round 2: the pick and the record say the same thing, in both directions ─────────
def _design_acme(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    _type(step, "title", "Acme Mesh")
    _type(step, "org", "example")
    ctl.leave_brand()
    cfg = ctl.collect_bootstrap()
    assert cfg.brand == "acme" and cfg.superbrand.get("title") == "Acme Mesh"


def test_picking_a_profile_after_a_design_drops_the_designs_title_and_organisation(ctl):
    """Designed 'acme' (title Acme Mesh), then picked the profile 'example': the mesh
    is the profile 'example' with nothing of the abandoned design (it used to be brand
    'example' with the block {title: Acme Mesh})."""
    _design_acme(ctl)
    ctl.brand_picker.select("profile:example")
    cfg = ctl.collect_bootstrap()
    assert cfg.brand == "example"
    assert cfg.superbrand == {}, cfg.superbrand
    rec = brand_model.record_from_bootstrap(cfg)
    assert (rec.superbrand.id, rec.superbrand.title, rec.superbrand.org) == ("example", "", "")
    ctl.leave_brand()
    saved = brand_model.load_record()
    assert (saved.superbrand.id, saved.superbrand.title) == ("example", "")


def test_picking_create_after_a_pick_gives_the_blank_design_not_the_old_pick(ctl):
    """Create selected means the record is the blank design (the shipped id), not the
    profile or the design picked before it."""
    _design_acme(ctl)
    ctl.brand_picker.select("profile:example")
    ctl.brand_picker.select("create")
    assert ctl.brand_picker.current_key() == "create"
    cfg = ctl.collect_bootstrap()
    assert cfg.brand == "hugmesh" and cfg.superbrand == {}, (cfg.brand, cfg.superbrand)
    assert ctl.superbrand_design.fields["id"].text() == ""
    # and a design typed after it replaces the shipped id as before
    _type(ctl.superbrand_design, "id", "second")
    assert ctl.collect_bootstrap().brand == "second"
