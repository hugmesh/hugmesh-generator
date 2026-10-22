"""'Save current mesh' on the Saved meshes list (operator, 2026-10-21).

"Saved meshes screen does not give anywhere to save the mesh we just started working
on." The list now opens with a strip for the mesh being worked on (the page's form):
what it carries per domain, whether it is saved already, and Save current mesh /
Save as / Overwrite selected (armed by a first click, done by the second). None of it
needs a running mesh.

Headless (QT_QPA_PLATFORM=offscreen). The page fixture and its fakes come from
test_localmesh_saved_meshes.py, so nothing here shells out; capture() runs for real
over a faked stack node with docker and git stubbed. The Studio state dir is the
autouse tmp dir.
"""
from __future__ import annotations

import os
import threading

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_mesh_bootstrap as lmb          # noqa: E402
from hugmesh_studio.core import saved_meshes as sm                   # noqa: E402
from hugmesh_studio.core import vaults                               # noqa: E402
from hugmesh_studio.gui.pages import _saved_meshes_widget as smw     # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                  # noqa: E402

from test_localmesh_saved_meshes import (  # noqa: E402,F401 — fixtures by name
    _record, _select, _settle, page, qapp,
)


@pytest.fixture(autouse=True)
def _no_docker(monkeypatch):
    monkeypatch.setattr(vaults, "list_volumes", lambda *a, **k: [])
    monkeypatch.setattr(sm, "_repo_rows", lambda root: [])


_ROW_B = {"name": "b.example", "title": "Bee", "idp": "own",
          "optional_services": ["tuwunel"],
          "idp_settings": {"provider": "oidc", "issuer": "https://id.b.example",
                           "client_id": "bee-web"},
          "look": {"primary": "#123456", "mode": "dark"},
          "ways": {"tailnet": True,
                   "egress": {"mode": "vpn", "conf": "/etc/hugmesh/b-egress.conf"}}}


def _worked_on(page):
    """Put a two-domain mesh into the form, the way a Load or the Domains step does."""
    cfg = lmb.LocalMeshBootstrapConfig(
        cluster_domain="a.example", services=(), kind_addons=(),
        domains=({"name": "a.example", "title": "", "idp": "superdomain",
                  "optional_services": ["tuwunel"]}, dict(_ROW_B)),
        domain_services_reviewed=("a.example", "b.example"))
    page.apply_bootstrap(cfg)
    return page.collect_bootstrap()


def _entered(qapp, page):
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False                 # NOTHING is running
    page._set_verbs_enabled(True)
    return page.saved_meshes


# ── the strip ────────────────────────────────────────────────────────────────────
def test_the_current_mesh_sits_above_the_saved_list(qapp, page):
    w = _entered(qapp, page)
    lay = w.layout()
    assert lay.indexOf(w.current_box) == 0, "the current mesh is not at the top"
    assert lay.indexOf(w.current_box) < lay.indexOf(w.table)
    assert w.current_title.text() == "Current mesh — not saved yet"
    assert w.save_btn.isEnabled(), w.save_btn.toolTip()
    assert not w.overwrite_btn.isEnabled()
    assert "Select the saved record" in w.overwrite_btn.toolTip()


def test_the_strip_names_every_domain_and_what_is_saved_for_it(qapp, page):
    w = _entered(qapp, page)
    _worked_on(page)
    text = w.current_domains.text()
    assert "a.example — this mesh's own domain" in text
    assert "b.example — its own sign-in through" in text
    assert "look: mode=dark, primary=#123456" in text
    assert "VPN: on" in text and "outbound: vpn (b-egress.conf)" in text
    assert "tuwunel" in w.current_summary.text()


def test_the_controls_are_visible_enabled_and_not_squashed(qapp, page):
    """Looked at, not only driven: the page shown at the wizard's size, the section
    open, and the save controls drawn with room for their text (memory:
    feedback_look_at_the_ui_you_built — geometry of a never-laid-out widget lies,
    so this asserts only after show + processEvents)."""
    w = _entered(qapp, page)
    page.resize(900, 1400)
    page.show()
    page.saved_section.set_expanded(True)
    for _ in range(5):
        qapp.processEvents()
    try:
        for ctl in (w.current_box, w.current_title, w.name_edit, w.save_btn,
                    w.overwrite_btn):
            assert ctl.isVisible(), type(ctl).__name__
        assert w.save_btn.isEnabled() and w.name_edit.isEnabled()
        for btn in (w.save_btn, w.overwrite_btn):
            need = btn.fontMetrics().horizontalAdvance(btn.text())
            assert btn.width() >= need, f"{btn.text()!r} is {btn.width()}px < {need}px"
            assert btn.height() >= btn.fontMetrics().height()
        assert w.name_edit.width() >= 120
        top = w.current_box.mapTo(w, QtCore.QPoint(0, 0)).y()
        table_top = w.table.mapTo(w, QtCore.QPoint(0, 0)).y()
        assert top < table_top, "the strip is not above the list"
    finally:
        page.hide()


# ── save with nothing running ─────────────────────────────────────────────────────
def test_save_current_mesh_works_with_no_mesh_running(qapp, page):
    w = _entered(qapp, page)
    want = _worked_on(page)
    w.name_edit.setText("lab")
    assert w.save_btn.isEnabled(), w.save_btn.toolTip()
    w.save_btn.click()
    assert page._running, "the save did not go through the worker"
    _settle(qapp, page)
    recs, _bad = sm.scan()
    assert [r.label for r in recs] == ["lab"]
    rec = recs[0]
    got = lmb.LocalMeshBootstrapConfig.from_dict(rec.config)
    # compared as LOADED on both sides: from_dict normalises the legacy social/tor
    # booleans from what runs, and the form's checkbox still says what it says
    expect = lmb.LocalMeshBootstrapConfig.from_dict(sm.config_for_record(want))
    assert got.to_dict() == expect.to_dict()
    assert rec.last_seen["compose_running"] is False
    assert w.current_title.text() == "Current mesh — saved as ‘lab’, no changes since"
    assert w.name_edit.text() == ""
    assert "Saved ‘lab’" in w.note.text()
    assert "running at save time: nothing" in page.log.toPlainText()
    # the form moves on: the strip says so, by field
    page.env_prod.setChecked(True)
    page._refresh_plan()
    assert w.current_title.text().startswith(
        "Current mesh — changed since it was saved as ‘lab’")
    assert "env" in w.current_summary.text()


def test_a_blank_name_is_derived_and_never_repeats(qapp, page):
    w = _entered(qapp, page)
    for _ in range(2):
        page.env_prod.setChecked(not page.env_prod.isChecked())   # a distinct form
        page._refresh_plan()
        w.save_btn.click()
        _settle(qapp, page)
    labels = sorted(r.label for r in sm.scan()[0])
    assert len(labels) == 2 and len(set(x.casefold() for x in labels)) == 2


def test_a_second_save_records_the_first_as_an_earlier_state_of_this_mesh(qapp, page):
    """Round 2 (2026-10-21): two saves of the same mesh are one line, so the OLDER
    record stops keeping domain code copies the newer one dropped
    (core/domain_workspaces.saved_mesh_claims). The form holds the first record after
    it is saved; the second save says it follows it."""
    w = _entered(qapp, page)
    w.name_edit.setText("first")
    w.save_btn.click()
    _settle(qapp, page)
    first = next(r for r in sm.scan()[0] if r.label == "first")
    assert first.follows == []
    assert page._loaded_record_id == first.id
    page.env_prod.setChecked(not page.env_prod.isChecked())
    page._refresh_plan()
    w.name_edit.setText("second")
    w.save_btn.click()
    _settle(qapp, page)
    second = next(r for r in sm.scan()[0] if r.label == "second")
    assert second.follows == [first.id]
    assert page._loaded_record_id == second.id


def test_the_later_version_box_names_the_record_and_is_on_screen(qapp, page):
    """The tie a save makes to the record the form holds is SHOWN (code-folders
    skeptic 2): hidden with no record, then a ticked, visible, sanely sized box
    naming the record once the form holds one."""
    w = _entered(qapp, page)
    page.resize(1000, 900)
    page.show()
    w.section.set_expanded(True)
    _settle(qapp, page)
    assert w.follows_box.isHidden()
    w.name_edit.setText("first")
    w.save_btn.click()
    _settle(qapp, page)
    box = w.follows_box
    assert box.isVisible() and box.isEnabled() and box.isChecked()
    assert box.width() >= 200 and box.height() >= 16, box.size()
    assert box.text().startswith("This is a later version of ‘first’"), box.text()


def test_unticking_the_box_saves_a_different_mesh_that_follows_nothing(qapp, page):
    """Load or save mesh A, edit the form into a DIFFERENT mesh, untick the box and
    save: the new record does not list A, so A keeps claiming its code copies."""
    w = _entered(qapp, page)
    w.name_edit.setText("mesh a")
    w.save_btn.click()
    _settle(qapp, page)
    a = next(r for r in sm.scan()[0] if r.label == "mesh a")
    page.env_prod.setChecked(not page.env_prod.isChecked())
    page._refresh_plan()
    w.follows_box.setChecked(False)
    w.name_edit.setText("mesh b")
    w.save_btn.click()
    _settle(qapp, page)
    b = next(r for r in sm.scan()[0] if r.label == "mesh b")
    assert b.follows == [], b.follows
    from hugmesh_studio.core import domain_workspaces as dw
    assert a.id not in dw.superseded_ids(sm.scan()[0])
    # the form now holds b: the box offers b, ticked again
    assert w.follows_box.isChecked() and "‘mesh b’" in w.follows_box.text()


def test_a_start_ties_the_form_to_the_started_record(qapp, page, monkeypatch):
    """Start applies a saved record to the form, so a later save follows THAT record
    — not whichever one was loaded or saved before (it used to keep the old id)."""
    w = _entered(qapp, page)
    w.name_edit.setText("loaded first")
    w.save_btn.click()
    _settle(qapp, page)
    started = _record(label="started")
    w.refresh()
    page._mesh_up = False
    monkeypatch.setattr(page, "_launch", lambda *a, **k: None)
    page._start_saved(started, sm.MODE_START)
    assert page._loaded_record_id == started.id
    assert w.follows_wanted(started.id) and "‘started’" in w.follows_box.text()


def test_a_taken_name_refuses_save_and_points_at_overwrite(qapp, page):
    _record(label="kept")
    w = _entered(qapp, page)
    w.name_edit.setText("KEPT ")
    assert not w.save_btn.isEnabled()
    assert "already called ‘kept’" in w.save_btn.toolTip()
    assert "Overwrite selected" in w.save_btn.toolTip()
    w.name_edit.setText("fresh")
    assert w.save_btn.isEnabled()


def test_save_is_off_while_a_verb_runs(qapp, page):
    w = _entered(qapp, page)
    page._running = True
    page._sync_saved_gate()
    assert not w.save_btn.isEnabled() and "verb is running" in w.save_btn.toolTip()
    page._running = False
    page._sync_saved_gate()
    assert w.save_btn.isEnabled()


# ── overwrite: two clicks ─────────────────────────────────────────────────────────
def test_overwrite_needs_a_second_click_and_keeps_the_record(qapp, page):
    old = _record(label="mine")
    w = _entered(qapp, page)
    page.env_prod.setChecked(True)
    page._refresh_plan()
    _select(page)
    assert w.overwrite_btn.isEnabled(), w.overwrite_btn.toolTip()
    w.overwrite_btn.click()                                   # FIRST click: arms only
    _settle(qapp, page)
    assert sm.load(old.path()).config["env"] == "test", "one click overwrote"
    assert w.overwrite_btn.text() == "Click again to overwrite ‘mine’"
    assert not w.overwrite_note.isHidden()
    assert "second click replaces the saved record ‘mine’" in w.overwrite_note.text()
    w.overwrite_btn.click()                                   # SECOND click: saves
    _settle(qapp, page)
    recs = sm.scan()[0]
    assert [r.id for r in recs] == [old.id], "the overwrite made a second record"
    assert recs[0].config["env"] == "prod" and recs[0].label == "mine"
    assert w.overwrite_btn.text() == "Overwrite selected"
    assert w.current_title.text() == "Current mesh — saved as ‘mine’, no changes since"


def test_moving_the_selection_disarms_the_overwrite(qapp, page):
    _record(label="one")
    _record(label="two")
    w = _entered(qapp, page)
    _select(page, 0)
    w.overwrite_btn.click()
    assert w.overwrite_btn.text().startswith("Click again")
    _select(page, 1)
    assert w.overwrite_btn.text() == "Overwrite selected"
    assert w.overwrite_note.isHidden()
    w.overwrite_btn.click()                       # a first click again, not a save
    _settle(qapp, page)
    assert not page._running
    assert {r.label for r in sm.scan()[0]} == {"one", "two"}


def test_typing_a_name_disarms_and_renames_on_overwrite(qapp, page):
    old = _record(label="old name")
    w = _entered(qapp, page)
    _select(page)
    w.overwrite_btn.click()
    w.name_edit.setText("new name")
    assert w.overwrite_btn.text() == "Overwrite selected", "a typed name kept it armed"
    w.overwrite_btn.click()
    assert "renamed to ‘new name’" in w.overwrite_note.text()
    w.overwrite_btn.click()
    _settle(qapp, page)
    assert sm.load(old.path()).label == "new name"


def test_overwrite_is_refused_for_a_record_from_another_checkout(qapp, page):
    _record(label="elsewhere", generator_dir="/somewhere/else")
    w = _entered(qapp, page)
    _select(page)
    assert not w.overwrite_btn.isEnabled()
    assert "another checkout" in w.overwrite_btn.toolTip()


# ── the full round trip through the screens ───────────────────────────────────────
def test_save_then_load_brings_every_domain_setting_back_into_the_form(qapp, page):
    w = _entered(qapp, page)
    want = _worked_on(page)
    w.name_edit.setText("two domains")
    w.save_btn.click()
    _settle(qapp, page)
    # scramble the form: a different, one-domain mesh
    page.apply_bootstrap(lmb.LocalMeshBootstrapConfig(cluster_domain="z.example"))
    assert page.collect_bootstrap().domains != want.domains
    w.refresh()
    w.mark_current("")            # a later session: nothing ties the form to it yet
    _select(page)
    w.load_btn.click()
    got = page.collect_bootstrap()
    rows = {r["name"]: r for r in got.domains}
    assert rows["b.example"]["look"] == _ROW_B["look"]
    assert rows["b.example"]["ways"] == _ROW_B["ways"]
    assert rows["b.example"]["idp_settings"] == _ROW_B["idp_settings"]
    assert got.domains == want.domains
    assert got.domain_services_reviewed == want.domain_services_reviewed
    assert w.current_title.text() == \
        "Current mesh — saved as ‘two domains’, no changes since"
    # the form is now TIED to that record: an edit reads as a change to it, not as
    # a new unsaved mesh
    page.env_prod.setChecked(True)
    page._refresh_plan()
    assert w.current_title.text().startswith(
        "Current mesh — changed since it was saved as ‘two domains’")


def test_the_list_shows_each_records_domains(qapp, page):
    w = _entered(qapp, page)
    _worked_on(page)
    w.name_edit.setText("dom")
    w.save_btn.click()
    _settle(qapp, page)
    cell = w.table.item(0, smw._SM_COL_DOMAINS)
    assert cell.text() == "2: a.example, b.example"
    assert "look: mode=dark" in cell.toolTip()


def test_the_capture_runs_off_the_gui_thread(qapp, page, monkeypatch):
    seen = {}
    real = sm.capture

    def spy(*a, **kw):
        seen["thread"] = threading.get_ident()
        seen["kw"] = kw
        return real(*a, **kw)
    monkeypatch.setattr(sm, "capture", spy)
    w = _entered(qapp, page)
    w.save_btn.click()
    _settle(qapp, page)
    assert seen["thread"] != threading.get_ident()
    assert seen["kw"]["copy_credentials"] is False, "the list's save copied credentials"
    assert seen["kw"]["overwrite"] is None


def test_no_modal_is_opened_by_the_save_controls():
    src = open(smw.__file__, encoding="utf-8").read()
    assert "QMessageBox." not in src and "QMessageBox(" not in src
    assert ".exec(" not in src and "QInputDialog" not in src
    assert QtWidgets is not None


def test_a_probe_answer_for_a_record_since_overwritten_is_not_applied(qapp, page):
    """An overwrite keeps the id. Facts a probe gathered about the OLD record (its
    volumes, its copies) must not land on the record that replaced it."""
    rec = _record(label="v1")
    w = _entered(qapp, page)
    w.refresh()
    row = next(r for r in w._rows if r.rec is not None and r.rec.id == rec.id)
    row.probe = None
    stale = {"volumes_present": True, "images_present": True, "creds_match": True,
             "mesh_running": False, "source_ok": True, "copies_missing": (),
             "source_drift": (), "volumes_missing": (), "volumes_seen": 3,
             "_updated": "2000-01-01T00:00:00+00:00"}
    w.apply_probe({rec.id: stale})
    assert row.probe is None, "an answer about an older version was applied"
    w.apply_probe({rec.id: dict(stale, _updated=rec.updated)})
    assert row.probe is not None


# ── fix round: what the armed overwrite says, old records, the Actions-row name ──
def test_the_armed_overwrite_says_the_credential_copies_go(qapp, page):
    rec = _record(label="with copies")
    rec.credentials["e2e_file"] = {"copied": True, "copy": "e2e-credentials"}
    assert sm.save(rec) and sm.load(rec.path()).has_credential_copies()
    w = _entered(qapp, page)
    _select(page)
    w.overwrite_btn.click()                                   # FIRST click: arms
    note = w.overwrite_note.text()
    assert "Its saved credential copies are removed: this save keeps pointers only." \
        in note, note
    # nothing running: the second click files a configuration that has not run, and
    # says so — but this record's mesh RAN (a record with no last_seen facts predates
    # the field and could only have been saved from a running mesh), so it is never
    # called one that never ran (saved-meshes skeptic 2, probe_core.py case A)
    assert "marked not run as saved" in note, note
    assert "never ran" not in note, note
    # the words are where the person looks: the note is shown under an enabled,
    # armed button, and is not squeezed to nothing
    assert not w.overwrite_note.isHidden() and w.overwrite_note.isVisibleTo(w)
    assert w.overwrite_btn.isEnabled() and "Click again" in w.overwrite_btn.text()
    assert w.overwrite_note.wordWrap() and w.overwrite_note.sizeHint().height() > 0


def test_a_record_without_copies_does_not_claim_any_go(qapp, page):
    _record(label="pointers only")
    w = _entered(qapp, page)
    _select(page)
    w.overwrite_btn.click()
    assert "credential copies" not in w.overwrite_note.text()


def test_loading_an_old_record_does_not_read_as_changed(qapp, page):
    """A record saved before the add-on picker existed leaves kind_addons at None;
    Load keeps the boxes as they are, so the strip must not call that a change —
    and the armed Overwrite says the form's add-on ticks are written in."""
    old = _record(label="old shape")
    old.config = lmb.LocalMeshBootstrapConfig(services=("tuwunel",),
                                              kind_addons=None).to_dict()
    assert sm.save(old)
    w = _entered(qapp, page)
    page._load_saved(sm.load(old.path()))
    page._refresh_plan()
    assert w.current_title.text() == \
        "Current mesh — saved as ‘old shape’, no changes since", \
        w.current_summary.text()
    assert "kind_addons" not in w.current_summary.text()
    _select(page)
    w.overwrite_btn.click()
    assert "never recorded a choice of DevOps add-ons" in w.overwrite_note.text()


def test_the_actions_row_save_says_where_the_name_came_from(qapp, page):
    w = _entered(qapp, page)
    w.name_edit.setText("named on review")
    page.save_mesh_btn.click()
    _settle(qapp, page)
    log = page.log.toPlainText()
    assert "the record is named ‘named on review’ — typed in the 'Save as' box" in log
    assert [r.label for r in sm.scan()[0]] == ["named on review"]
    assert "'Save as' box" in page.save_mesh_btn.toolTip()
    page.save_mesh_btn.click()                                # blank box: derived
    _settle(qapp, page)
    assert "derived, because the 'Save as' box" in page.log.toPlainText()


def test_a_record_that_never_chose_does_not_claim_an_unsaved_form(qapp, page):
    """A CLI-made record with no services / add-on choice is not the form's twin:
    the strip must not say the form is saved as it (only the record the form was
    loaded from gets that leniency)."""
    cli = _record(label="cli made")
    cli.config = lmb.LocalMeshBootstrapConfig(services=None, kind_addons=None).to_dict()
    assert sm.save(cli)
    w = _entered(qapp, page)
    assert w.current_title.text() == "Current mesh — not saved yet"


@pytest.mark.parametrize("kind", [True, False, None])
def test_the_save_records_what_the_monitor_last_read_of_the_kind_lane(qapp, page, kind,
                                                                      monkeypatch):
    """Saved-meshes skeptic 2 (R5): the GUI save hands the monitor's reading of the
    DevOps (kind) lane to the record — True, False, or None while not read yet — and
    never a constant, so a save made while the kind lane runs is not filed as a draft."""
    w = _entered(qapp, page)
    monkeypatch.setattr(page, "_kind_lane_running", lambda: kind)
    w.name_edit.setText(f"kind-{kind}")
    w.save_btn.click()
    _settle(qapp, page)
    rec = next(r for r in sm.scan()[0] if r.label == f"kind-{kind}")
    assert rec.last_seen["kind_running"] is kind
    assert rec.ran_when_saved() is bool(kind)


def test_the_armed_overwrite_of_a_draft_says_it_stays_one(qapp, page):
    """A record saved with nothing up (it never ran) overwritten with nothing up is
    still a draft that never ran — and only that record is called one."""
    _record(label="never up", last_seen={"compose_running": False,
                                         "kind_running": False, "at": "x"})
    w = _entered(qapp, page)
    _select(page)
    w.overwrite_btn.click()
    note = w.overwrite_note.text()
    assert "stays a draft (never ran)" in note, note
    assert "marked not run as saved" not in note


def test_an_overwrite_with_nothing_running_keeps_that_the_mesh_ran(qapp, page):
    """The second click with nothing up: the record keeps WHEN its mesh last ran, and
    the node-image import line does not call it a mesh that never ran."""
    old = _record(label="ran last week",
                  last_seen={"compose_running": True, "kind_running": None,
                             "at": "2026-10-14T09:30:00+00:00"})
    w = _entered(qapp, page)
    _select(page)
    w.overwrite_btn.click()                                   # arms
    w.overwrite_btn.click()                                   # saves
    _settle(qapp, page)
    got = sm.find(old.id)
    assert got.ran_when_saved() is False
    assert got.ran_before_at() == "2026-10-14T09:30:00+00:00"
    src = lmb.saved_mesh_source(got)
    assert "NEVER RAN" not in src and "NOT RUN AS SAVED" in src, src


# ── the GUI kind-lane path, from the monitor's own snapshot (no stubbed reader) ──
@pytest.mark.parametrize("kind", [True, False, None])
def test_the_save_records_the_kind_lane_from_the_monitor_snapshot(qapp, page, kind,
                                                                  monkeypatch):
    """Saved-meshes skeptic 2 (R5), end to end on the page: a monitor snapshot that
    arrives through _on_monitor (the slot the off-thread probe feeds) decides the
    record's kind_running — True, False, or None while the census could not be
    taken. The reader itself is not stubbed, so dropping what it reads goes red."""
    from hugmesh_studio.core import mesh_monitor as mm
    w = _entered(qapp, page)
    # no REAL census may land over the test's snapshot: let one in flight finish,
    # then start no more (the reader under test is untouched)
    t = getattr(page, "_monitor_probe", None)
    if t is not None:
        t.wait(10000)
        qapp.processEvents()
    monkeypatch.setattr(page, "_refresh_monitor", lambda reason="": False)
    page._on_monitor(mm.MonitorSnapshot(
        taken_at="10:00:00", compose=mm.LaneState(False, "not started"),
        kind=mm.LaneState(kind, "cluster hugmesh-local" if kind else "",
                          error="" if kind is not None else "kubectl is not installed")))
    w.name_edit.setText(f"monitor-{kind}")
    w.save_btn.click()
    _settle(qapp, page)
    rec = next(r for r in sm.scan()[0] if r.label == f"monitor-{kind}")
    assert rec.last_seen["kind_running"] is kind
    assert rec.ran_when_saved() is bool(kind)
