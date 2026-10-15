"""The GUI half of the Go-Live "Export to GitHub org" feature, driven headless:

* the Domains table's 'GitHub org' column (image flow and the local-mesh widget):
  appended after Base CA, mesh-visible / cloud-hidden, a STORE cell that persists
  through validatePage into ``cfg.domains[].github_org`` and (row 0) into
  ``cfg.cluster_domain_github_org``, a bad slug refused INLINE on Next;
* the Go-Live wizard's export step: skipped when no domain names an org, present
  when a saved mesh does; Plan fills the table and the plan text (the same lines the
  TUI and CLI print); Apply is armed ONLY by typing the org name; the run goes
  through the injected runner against the offline 'GitHub' and never force-pushes;
* GEOMETRY (the operator could not SEE a control 193 green tests swore existed, #647):
  at the wizard's smallest size every control is inside the viewport, columns are
  wide enough for their text, and a PNG is grabbed for a person to look at
  ($HUGMESH_SHOTS_DIR, else the test's tmp dir);
* no modal dialog anywhere in the page's logic (a source scan).
"""
from __future__ import annotations

import inspect
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import org_export as oe                        # noqa: E402
from hugmesh_studio.core.config import Domain                           # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.pages import domains as domains_mod             # noqa: E402
from hugmesh_studio.gui.pages import golive as golive_mod               # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod         # noqa: E402
from hugmesh_studio.gui.pages.domains import (                          # noqa: E402
    _COL_CA, _COL_IDP, _COL_ORG, DomainsTableWidget, _OrgCell)
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402

from _helpers import (                                                  # noqa: E402
    added_row, advance_to, check_worklist_rows, enable_additional_domains, pick_mode)
from _org_export_helpers import (  # noqa: E402
    bare_log, make_world, parse_terminal_line, saved_mesh_naming_the_org)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SHOTS = os.environ.get("HUGMESH_SHOTS_DIR", "")

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setattr(golive_mod.GoLiveDriver, "status_text", lambda self: "pinned")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-org-export-gui-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def golive(qapp):
    w = golive_mod.GoLiveWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def world(tmp_path):
    return make_world(tmp_path)


def _shot(widget, name: str, tmp_path) -> str:
    folder = SHOTS or str(tmp_path)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    assert widget.grab().save(path), path
    return path


def _settle(qapp, n: int = 5) -> None:
    for _ in range(n):
        qapp.processEvents()


def _wait_worker(page, qapp, timeout: float = 120.0) -> None:
    t0 = time.time()
    while page.worker is not None and page.worker.isRunning():
        qapp.processEvents()
        time.sleep(0.02)
        assert time.time() - t0 < timeout, "the export worker did not finish"
    _settle(qapp, 20)                    # deliver the queued done/progress signals


def _mesh_domains(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    return advance_to(wiz, wizard_mod.DomainsPage)


def _text_width(widget, text: str) -> int:
    return widget.fontMetrics().horizontalAdvance(text)


def _leave(wiz) -> None:
    """One Next off the current page — validatePage runs and must accept."""
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() != before, "validatePage rejected"


# ── the Domains table column (image flow) ────────────────────────────────────────────
def test_the_org_column_is_appended_after_base_ca_and_mesh_visible(wiz, qapp, tmp_path):
    dom = _mesh_domains(wiz)
    assert _COL_ORG == _COL_CA + 1 == _COL_IDP + 2
    assert dom.table.columnCount() == _COL_ORG + 1
    assert dom.table.horizontalHeaderItem(_COL_ORG).text() == "GitHub org"
    assert not dom.table.isColumnHidden(_COL_ORG)
    # the OWN row has the one editable cell: an org cell, empty by default
    assert dom.is_own_row(0)
    own_cell = dom.table.cellWidget(0, _COL_ORG)
    assert isinstance(own_cell, _OrgCell) and own_cell.text() == ""
    assert own_cell.placeholderText() == domains_mod._ORG_PLACEHOLDER
    # GEOMETRY: the column is wide enough for its header and a real slug, and the
    # cell widget is actually drawn (isVisible — #647's lesson), at the default size
    _settle(qapp)
    hdr = dom.table.horizontalHeader()
    width = dom.table.columnWidth(_COL_ORG)
    assert width >= _text_width(hdr, "GitHub org") + 8, width
    assert width >= _text_width(own_cell, "exampleorg") + 12, width
    assert own_cell.isVisible() and own_cell.width() >= 60, own_cell.width()
    # the whole column sits inside the viewport (not scrolled off to the right)
    x_end = hdr.sectionViewportPosition(_COL_ORG) + width
    assert x_end <= dom.table.viewport().width(), (x_end, dom.table.viewport().width())
    _shot(wiz, "domains-table-github-org-column.png", tmp_path)


def test_a_typed_org_persists_into_the_config_and_seeds_back(wiz):
    dom = _mesh_domains(wiz)
    dom._add("chat.example", "Chat")
    r = added_row(dom, 0)
    dom.table.cellWidget(r, _COL_ORG).setText("ExampleOrg")   # case is folded
    dom.table.cellWidget(0, _COL_ORG).setText("exampleorg")   # the own row
    _leave(wiz)
    assert wiz.cfg.domains[0].github_org == "exampleorg"
    assert wiz.cfg.cluster_domain_github_org == "exampleorg"
    saved = wiz.cfg.to_dict()
    assert saved["domains"][0]["github_org"] == "exampleorg"
    assert saved["cluster_domain_github_org"] == "exampleorg"
    assert wiz.cfg.mesh_manifest()["cluster_domain_github_org"] == "exampleorg"
    # back into the page: the cells still carry what the config says
    wiz.back()
    assert isinstance(wiz.currentPage(), wizard_mod.DomainsPage)
    # the cell keeps what was typed (in-progress edits survive a Back on the same
    # config object); the READ is folded, and that is what reaches the config
    assert dom.table.cellWidget(added_row(dom, 0), _COL_ORG).text() == "ExampleOrg"
    assert dom.table.cellWidget(added_row(dom, 0), _COL_ORG).selected_org() == "exampleorg"
    assert dom.own_row_github_org() == "exampleorg"


def test_an_untouched_table_writes_no_org_anywhere(wiz):
    dom = _mesh_domains(wiz)
    dom._add("chat.example", "Chat")
    _leave(wiz)
    assert wiz.cfg.domains[0].github_org == "" and wiz.cfg.cluster_domain_github_org == ""
    d = wiz.cfg.to_dict()
    assert "github_org" not in d["domains"][0] and "cluster_domain_github_org" not in d
    assert "github_org" not in wiz.cfg.mesh_manifest()["domains"][0]


def test_a_bad_slug_is_refused_inline_on_next_never_a_modal(wiz, qapp):
    dom = _mesh_domains(wiz)
    dom._add("chat.example", "Chat")
    cell = dom.table.cellWidget(added_row(dom, 0), _COL_ORG)
    cell.setText("bad-")                     # the validator lets a trailing hyphen be typed
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before          # refused
    assert dom.row_note.isVisible()
    assert "not a GitHub org slug" in dom.row_note.text() and "chat.example" in dom.row_note.text()
    assert wiz.cfg.domains == []              # nothing written
    cell.setText("exampleorg")
    cell.editingFinished.emit()               # the inline note clears as you leave the cell
    assert not dom.row_note.isVisible()
    wiz.next()
    assert wiz.currentId() != before and wiz.cfg.domains[0].github_org == "exampleorg"


def test_cloud_hides_the_column_and_collects_nothing(wiz):
    pick_mode(wiz, "cloud")
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom.table.isColumnHidden(_COL_ORG)
    _leave(wiz)
    assert wiz.cfg.cluster_domain_github_org == ""
    assert all(d.github_org == "" for d in wiz.cfg.domains)


def test_a_loaded_config_seeds_the_cells(wiz):
    wiz.cfg.domains = [Domain(name="chat.example", title="Chat", github_org="exampleorg")]
    wiz.cfg.cluster_domain_github_org = "exampleorg"
    wiz.cfg.additional_domains = True
    dom = _mesh_domains(wiz)
    assert dom.table.cellWidget(added_row(dom, 0), _COL_ORG).text() == "exampleorg"
    assert dom.own_row_github_org() == "exampleorg"


# ── the Domains table column (local-mesh widget) ────────────────────────────────────
def test_the_local_mesh_widget_shows_edits_and_writes_the_org(qapp):
    md = LocalMeshDomains(domains=[Domain(name="mesh.example", github_org="exampleorg"),
                                   Domain(name="chat.mesh.example", github_org="otherorg")],
                          own_name="mesh.example")
    w = DomainsTableWidget(cfg=lambda: md)
    w.show()
    w.fill(md.domains, md.own_name)
    _settle(qapp)
    assert w.is_own_row(0) and w.own_row_github_org() == "exampleorg"
    assert w.row_github_org(1) == "otherorg"
    rows, _ca = w.rows()
    assert [(d.name, d.github_org) for d in rows] == [("chat.mesh.example", "otherorg")]
    # editing the OWN row's cell writes through to the own Domain row of the state
    w.table.cellWidget(0, _COL_ORG).setText("neworg")
    w.table.cellWidget(0, _COL_ORG).editingFinished.emit()
    assert md.by_name("mesh.example").github_org == "neworg"
    assert not w.row_note.isVisible()
    w.table.cellWidget(0, _COL_ORG).setText("-x")
    w.table.cellWidget(0, _COL_ORG).editingFinished.emit()
    assert w.row_note.isVisible() and "not a GitHub org slug" in w.row_note.text()
    assert md.by_name("mesh.example").github_org == "neworg"      # a bad slug is not written
    w.close()
    w.deleteLater()


def test_the_local_mesh_route_records_an_added_rows_org(wiz):
    """Generate a new mesh -> Domains step: an added row's org reaches the state the
    bring-up records (``bootstrap_domain_records`` -> the saved mesh's config). The
    own row's cell is a store too (previous test) — carrying it through
    ``_commit_domains`` in pages/localmesh.py is that page's one-line follow-up."""
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshEnvPage)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage)
    ctl = wiz.page(wiz._page_ids["localmesh"])
    ctl.domains_table._add("chat.example", "Chat", github_org="exampleorg")
    assert ctl._commit_domains()
    md = ctl.mesh_domains
    assert md.by_name("chat.example").github_org == "exampleorg"
    recorded = ctl.collect_bootstrap().domains
    assert any(r["name"] == "chat.example" and r.get("github_org") == "exampleorg"
               for r in recorded), recorded


def _local_mesh_domains_step(wiz):
    """Generate a new local mesh -> the Domains step; returns the controller page."""
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshEnvPage)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshDomainsPage)
    return wiz.page(wiz._page_ids["localmesh"])


def test_the_local_mesh_route_keeps_the_own_rows_org_through_next(wiz, qapp):
    """Generate a new mesh -> Domains step: an org typed on the OWN row (row 0)
    survives Next WITHOUT the cell ever losing focus. The Next shortcut and a
    programmatic ``next()`` do not move focus, so ``editingFinished`` never fires;
    measured before the fix ``_commit_domains`` rebuilt row 0 from the STATE that
    only that signal writes: 'exampleorg' in the cell, '' after Next, and the
    bring-up recorded no org for the mesh's own domain (correctness skeptic B3).
    The cell is the carrier; the state is read only when there is no own row."""
    ctl = _local_mesh_domains_step(wiz)
    md = ctl.mesh_domains
    own = md.own_name
    assert own and md.by_name(own) is not None and md.by_name(own).github_org == ""
    assert ctl.domains_table.is_own_row(0)
    cell = ctl.domains_table.table.cellWidget(0, _COL_ORG)
    cell.setText("exampleorg")                  # typed; NO editingFinished
    _settle(qapp)
    assert ctl.domains_table.own_row_github_org() == "exampleorg"
    assert md.by_name(own).github_org == ""     # the state has not seen it yet
    before = wiz.currentId()
    wiz.next()                                  # the real Next, as the shortcut does it
    assert wiz.currentId() != before, "Next refused"
    assert ctl.mesh_domains.own_name == own
    assert ctl.mesh_domains.by_name(own).github_org == "exampleorg", "lost on Next"
    # a second Next (Back, then Next again) must not drop it either
    wiz.back()
    assert ctl._commit_domains()
    assert ctl.mesh_domains.by_name(own).github_org == "exampleorg"
    recorded = ctl.collect_bootstrap().domains
    assert any(r["name"] == own and r.get("github_org") == "exampleorg"
               for r in recorded), recorded
    # clearing the cell (again without focus loss) clears the state on Next: the
    # cell wins over the state in BOTH directions, or a cleared org would come back
    cell = ctl.domains_table.table.cellWidget(0, _COL_ORG)
    cell.setText("")
    _settle(qapp)
    assert ctl._commit_domains()
    assert ctl.mesh_domains.by_name(own).github_org == ""
    assert all("github_org" not in r for r in ctl.collect_bootstrap().domains
               if r["name"] == own)


def test_the_local_mesh_route_refuses_a_bad_slug_on_next_never_a_modal(wiz, qapp):
    """The image flow refuses a non-slug org inline on Next (DomainsPage.validatePage);
    the local-mesh route ran only the name checks and ACCEPTED 'bad-' into the state
    and the saved record (correctness skeptic B2). Both faces now refuse with the
    same sentence, inline, and the bad value never reaches the record."""
    ctl = _local_mesh_domains_step(wiz)
    own = ctl.mesh_domains.own_name
    ctl.domains_table._add("chat.example", "Chat", github_org="bad-")
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before, "Next ACCEPTED the bad slug"
    assert ctl.domains_note.isVisible()
    assert "not a GitHub org slug" in ctl.domains_note.text()
    assert "chat.example" in ctl.domains_note.text()
    assert not [w for w in QtWidgets.QApplication.topLevelWidgets()
                if w.isVisible() and w is not wiz
                and isinstance(w, (QtWidgets.QDialog, QtWidgets.QMessageBox))]
    assert all(r.get("github_org", "") == "" for r in ctl.collect_bootstrap().domains)
    # the own row's cell too (its validator allows the in-progress trailing hyphen)
    for r in range(ctl.domains_table.table.rowCount()):
        if not ctl.domains_table.is_own_row(r):
            ctl.domains_table.table.cellWidget(r, _COL_ORG).setText("otherorg")
    cell = ctl.domains_table.table.cellWidget(0, _COL_ORG)
    cell.setText("own-")
    _settle(qapp)
    assert not ctl._commit_domains()
    assert "not a GitHub org slug" in ctl.domains_note.text()
    assert ctl.mesh_domains.by_name(own).github_org == ""   # never written to the state
    # fixing the cell lets Next through, and the note clears
    cell.setText("exampleorg")
    _settle(qapp)
    assert ctl._commit_domains()
    assert not ctl.domains_note.isVisible()
    assert ctl.mesh_domains.by_name(own).github_org == "exampleorg"
    assert ctl.mesh_domains.by_name("chat.example").github_org == "otherorg"


def test_a_reopened_saved_mesh_shows_every_org_and_records_them_again(wiz, qapp):
    """A saved mesh naming orgs is re-opened the way the Studio does it
    (``_load_saved`` -> ``from_dict`` -> ``apply_bootstrap``): every cell shows its
    org, and the next Next + record still carry them. Red on the unfixed head: the
    loader dropped the key, the cells were empty, and the re-saved record named no
    org and no own row (both skeptics, round 0)."""
    from hugmesh_studio.core import saved_meshes
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    from hugmesh_studio.core.local_mesh_domains import bootstrap_domain_records
    ctl = _local_mesh_domains_step(wiz)
    own = ctl.mesh_domains.own_name
    rec = saved_meshes.SavedMesh(id="20260101-000000-abcd", label="named orgs",
                                 generator_dir=GENERATOR_DIR)
    rec.config = LocalMeshBootstrapConfig(
        cluster_domain=own,
        domains=bootstrap_domain_records(
            [Domain(name=own, github_org="exampleorg"),
             Domain(name="chat.example", title="Chat", github_org="otherorg"),
             Domain(name="plain.example")], own)).to_dict()
    assert rec.config["domains"][0]["github_org"] == "exampleorg"     # on disk
    ctl._load_saved(rec)
    _settle(qapp)
    t = ctl.domains_table
    assert t.is_own_row(0) and t.own_row_github_org() == "exampleorg"
    assert [t.row_github_org(r) for r in range(1, t.table.rowCount())] == ["otherorg", ""]
    assert ctl.mesh_domains.by_name(own).github_org == "exampleorg"
    assert ctl._commit_domains()
    recorded = ctl.collect_bootstrap().domains
    assert [(r["name"], r.get("github_org")) for r in recorded] == [
        (own, "exampleorg"), ("chat.example", "otherorg"), ("plain.example", None)]


# ── the Go-Live export step ─────────────────────────────────────────────────────────
def _at_generate(golive):
    golive.setStartId(golive._page_ids["generate"])
    golive.restart()
    assert isinstance(golive.currentPage(), golive_mod.GoLiveGeneratePage)
    return golive.currentPage()


def test_the_export_step_is_skipped_when_no_domain_names_an_org(golive):
    _at_generate(golive)
    export_id = golive._page_ids["org-export"]
    assert golive.nextId() == golive._page_ids["verify"] != export_id
    page = golive.page(export_id)
    assert page.applies() is False
    page.initializePage()
    assert not page.status.isHidden() and "No domain" in page.status.text()


def test_the_export_step_appears_when_a_saved_mesh_names_an_org(golive, world):
    saved_mesh_naming_the_org(world)
    _at_generate(golive)
    export_id = golive._page_ids["org-export"]
    assert golive.nextId() == export_id
    golive.next()
    page = golive.currentPage()
    assert isinstance(page, golive_mod.GoLiveOrgExportPage)
    assert page.source.count() == 1
    assert page.source.currentText().startswith("mesh.example -> exampleorg")
    assert page.source_dir.text() == world["src"]           # the record's checkouts
    assert page.cmd.text().startswith("python3 -m hugmesh_studio --org-export PLAN")
    assert not page.apply_btn.isEnabled()
    # Next from here is the verify step, as before the step existed
    assert golive.nextId() == golive._page_ids["verify"]


def test_plan_then_typed_org_arms_apply_and_the_run_goes_through_the_runner(
        golive, world, qapp, tmp_path):
    saved_mesh_naming_the_org(world)
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    assert isinstance(page, golive_mod.GoLiveOrgExportPage)
    page.out_dir.setText(str(tmp_path / "out"))
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None, page.status.text()
    assert not page.plan.blocked, [(r.source, r.action, r.notes) for r in page.plan.blocked]
    # the saved mesh's default set: the platform app, the chain, the generator, the site
    targets = [page.table.item(r, 1).text() for r in range(page.table.rowCount())]
    assert targets == ["exampleorg/example-actions", "exampleorg/example-build-config",
                       "exampleorg/example-parent", "exampleorg/example-commons",
                       "exampleorg/example-auth-core", "exampleorg/example-generator",
                       "exampleorg/mesh.example.github.io"]
    assert [page.table.horizontalHeaderItem(c).text() for c in range(page.table.columnCount())] \
        == list(golive_mod.EXPORT_COLUMNS)
    assert page.plan_text.toPlainText().splitlines() == oe.plan_lines(page.plan)
    assert page.cmd.text().endswith("--apply")
    # arming: only the exact org name (case folded), never before a plan
    assert not page.apply_btn.isEnabled()
    page.confirm.setText("nope")
    assert not page.apply_btn.isEnabled()
    page.confirm.setText("ExampleOrg")
    assert page.apply_btn.isEnabled()
    _shot(golive, "golive-org-export-planned.png", tmp_path)
    # GEOMETRY at the wizard's own (smallest supported) size: every control inside
    # the scroll viewport, the verbs on the first screen, nothing squeezed
    golive.resize(820, 640)
    _settle(qapp, 10)
    viewport = page._content_scroll.viewport()
    content = page._content_scroll.widget()
    assert content.minimumSizeHint().width() <= viewport.width(), \
        (content.minimumSizeHint().width(), viewport.width())
    for name in ("source", "rename_map", "plan_btn", "confirm", "apply_btn", "status", "table"):
        ctl = getattr(page, name)
        if name == "status" and not ctl.isVisible():
            continue
        assert ctl.isVisible(), name
        top = ctl.mapTo(viewport, ctl.rect().topLeft())
        bottom = ctl.mapTo(viewport, ctl.rect().bottomRight())
        assert top.x() >= 0 and bottom.x() <= viewport.width(), (name, top, bottom)
        if name in ("source", "plan_btn", "confirm", "apply_btn"):
            assert 0 <= top.y() and bottom.y() <= viewport.height(), (name, top, bottom)
    for btn in (page.plan_btn, page.apply_btn):
        assert btn.width() >= btn.sizeHint().width() - 2, (btn.text(), btn.width())
    hdr = page.table.horizontalHeader()
    longest = max(targets, key=len)
    assert page.table.columnWidth(1) >= _text_width(page.table, longest) + 8
    for c in range(3):                      # Source, Target, Action: never elided
        texts = [page.table.item(r, c).text() for r in range(page.table.rowCount())]
        assert page.table.columnWidth(c) >= _text_width(page.table, max(texts, key=len)) + 8
    assert hdr.sectionViewportPosition(2) + page.table.columnWidth(2) \
        <= page.table.viewport().width(), "Source/Target/Action must fit without scrolling"
    # APPLY: the worker runs the engine against the offline GitHub
    page.apply_btn.click()
    _wait_worker(page, qapp)
    assert page.result is not None, page.status.text()
    assert page.result.failures == [], [(r.target, r.skipped) for r in page.result.failures]
    assert [page.table.item(r, 7).text().split()[0] for r in range(page.table.rowCount())] \
        == ["create"] * 7
    for target in ("example-actions", "example-generator", "mesh.example.github.io"):
        assert len(bare_log(world, target)) == 1
    assert not page.apply_btn.isEnabled()            # one apply per plan
    assert "Result file:" in page.plan_text.toPlainText()
    joined = [" ".join(c) for c in world["runner"].calls]
    # (the one local `git add --force` stages the snapshot folder past ignore rules)
    assert not any(("--force" in c and " add " not in f" {c} ") or "--mirror" in c
                   or "--delete" in c for c in joined)
    _shot(golive, "golive-org-export-applied.png", tmp_path)


def test_the_own_domains_selected_services_reach_the_steps_plan(golive, world, qapp, tmp_path):
    """The saved mesh's own domain selects phpbb: the step's plan must list the
    repository that profile adds (hugmesh-forum-api). Measured before the fix: the
    candidate door dropped the own row's services, so the table showed the default
    set only (skeptic, round 1, blocker 1 / mutation M16)."""
    saved_mesh_naming_the_org(world, services=["phpbb"])
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    assert isinstance(page, golive_mod.GoLiveOrgExportPage)
    assert page.export_config().optional_services == ["phpbb"]
    page.out_dir.setText(str(tmp_path / "out"))
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None, page.status.text()
    targets = [page.table.item(r, 1).text() for r in range(page.table.rowCount())]
    assert "exampleorg/example-forum-api" in targets, targets
    # the test world holds no checkout for it: planned, reported, and Apply stays off
    forum = next(r for r in page.plan.repos if r.source == "hugmesh-forum-api")
    assert forum.action == "missing source"
    page.confirm.setText("exampleorg")
    assert not page.apply_btn.isEnabled()


def test_the_mesh_wide_services_step_reaches_the_steps_plan(golive, world, qapp, tmp_path):
    """The own row names only the org; phpbb was picked on the mesh-wide Services
    step (what the mesh actually runs). Measured before the fix: the step planned the
    own domain without hugmesh-forum-api (integration skeptic, blocker B1)."""
    saved_mesh_naming_the_org(world, mesh_services=["phpbb"])
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    assert isinstance(page, golive_mod.GoLiveOrgExportPage)
    assert page.export_config().optional_services == ["phpbb"]
    page.out_dir.setText(str(tmp_path / "out"))
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None, page.status.text()
    targets = [page.table.item(r, 1).text() for r in range(page.table.rowCount())]
    assert "exampleorg/example-forum-api" in targets, targets


def test_the_terminal_line_plans_the_same_repositories_as_the_steps_table(
        golive, world, qapp, tmp_path, monkeypatch, capsys):
    """The Terminal field's claim — 'The same export from a terminal' — run back
    through the REAL CLI (app.main: the Studio parser, run_cli, the real runner over
    the fake gh) and compared with the table. Measured before the fix: the field
    spelled ``--domain --org`` for a saved mesh, so the line planned 6 repositories
    where the table showed 7 (correctness skeptic, round 0, blocker 1)."""
    import re
    import shlex
    from hugmesh_studio import app as app_mod
    monkeypatch.setenv("PATH", world["runner"].fake_bin + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("FAKE_GH_ROOT", world["gh_root"])
    monkeypatch.setenv("FAKE_GH_LOG", world["runner"].gh_log)
    saved_mesh_naming_the_org(world, services=["phpbb"])
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    page.out_dir.setText(str(tmp_path / "out"))     # no editingFinished: the line is live
    before = page.cmd.text()
    assert before.startswith("python3 -m hugmesh_studio --org-export PLAN --config "), before
    assert f"--out {tmp_path / 'out'}" in before
    assert parse_terminal_line(before, GENERATOR_DIR) == page.export_config()
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None, page.status.text()
    table = [page.table.item(r, 1).text() for r in range(page.table.rowCount())]
    assert "exampleorg/example-forum-api" in table
    # the apply form: the same words with the verb swapped and the flag appended
    assert page.cmd.text() == before.replace("--org-export PLAN", "--org-export APPLY", 1) + " --apply"
    # the PLAN line, run as a person would paste it (the parser is app.main's own)
    words = shlex.split(before)
    assert words[:3] == ["python3", "-m", "hugmesh_studio"]
    rc = app_mod.main(words[3:])
    out = capsys.readouterr().out
    assert rc == (1 if page.plan.blocked else 0), out
    cli_targets = re.findall(r"^\S+\s+(exampleorg/\S+)\s", out, re.M)
    assert cli_targets == table, (cli_targets, table)
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))   # a plan: nothing created
    # the field itself is drawn where a person can copy it (#647): scrolled into
    # view at the wizard's smallest size, inside the viewport, wide enough for a path
    golive.resize(820, 640)
    page._content_scroll.ensureWidgetVisible(page.cmd)
    _settle(qapp, 10)
    viewport = page._content_scroll.viewport()
    assert page.cmd.isVisible()
    top = page.cmd.mapTo(viewport, page.cmd.rect().topLeft())
    bottom = page.cmd.mapTo(viewport, page.cmd.rect().bottomRight())
    assert 0 <= top.y() and bottom.y() <= viewport.height(), (top, bottom, viewport.height())
    assert 0 <= top.x() and bottom.x() <= viewport.width(), (top, bottom, viewport.width())
    assert page.cmd.width() >= 300, page.cmd.width()
    assert page.cmd.text().startswith("python3 -m hugmesh_studio --org-export APPLY --config ")
    _shot(golive, "golive-org-export-terminal-line.png", tmp_path)


def test_a_typed_source_folder_and_every_picker_reach_the_terminal_line_at_once(
        golive, world, tmp_path):
    """Only the rename-map field used to re-spell the Terminal line: a Source folder
    typed over a saved mesh's, or a flipped picker, showed up in it only after Plan
    (and never, under --config, before this round). The two folders refresh on
    every text change — no editingFinished is emitted here, as none is when a value
    is set without a focus move (the e2e driver's setText found the line stale)."""
    saved_mesh_naming_the_org(world)
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    assert "--source-dir" not in page.cmd.text()          # the record's own folder: nothing to add
    other = tmp_path / "elsewhere"
    other.mkdir()
    page.source_dir.setText(str(other))
    assert f"--source-dir {other} --source-mode existing" in page.cmd.text()
    page.source_dir.setText("")
    # an empty folder is the clone root, as the field's placeholder says
    assert "--source-mode clone" in page.cmd.text() and "--source-dir" not in page.cmd.text()
    assert page.export_config().source_mode == "clone"
    page.visibility.setCurrentText("public")
    assert "--visibility public" in page.cmd.text()
    page.update_mode.setCurrentIndex(page.update_mode.findData(oe.UPDATE_BRANCH))
    assert "--update branch" in page.cmd.text()
    page.out_dir.setText(str(tmp_path / "o"))
    assert f"--out {tmp_path / 'o'}" in page.cmd.text()
    assert parse_terminal_line(page.cmd.text(), GENERATOR_DIR) == page.export_config()


def test_apply_without_the_typed_name_is_refused_inline(golive, world, qapp, tmp_path):
    saved_mesh_naming_the_org(world)
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    page.out_dir.setText(str(tmp_path / "out"))
    page.plan_btn.click()
    _wait_worker(page, qapp)
    page.confirm.setText("")
    page._apply()                                     # the slot, bypassing the disabled button
    assert page.status.isVisible() and "Type the org name" in page.status.text()
    assert page.result is None
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))


def test_a_config_file_can_be_added_as_a_source(golive, world, tmp_path):
    cfg_path = tmp_path / "export.json"
    import json
    cfg_path.write_text(json.dumps(world["cfg"].to_dict()))
    _at_generate(golive)
    page = golive.page(golive._page_ids["org-export"])
    assert not page.applies()
    page.config_path.setText(str(cfg_path))
    page._add_config()
    assert page.applies() and page.source.count() == 1
    assert "config file export.json" in page.source.currentText()
    assert golive.nextId() == golive._page_ids["org-export"]
    page.config_path.setText(str(tmp_path / "missing.json"))
    page._add_config()
    # the page is not the current one here, so isVisible() is False for every child;
    # isHidden() is the widget's own flag
    assert not page.status.isHidden() and "missing.json" in page.status.text()


def test_a_config_files_rules_reach_the_plan_and_the_rename_map_field_works(
        golive, world, qapp, tmp_path):
    """The config-file door kept only domain/org/source: a file saying
    include_generator:false, skip_repos, an exclude rule, public, update:branch was
    planned with the DEFAULTS (correctness skeptic B4). Now: the pickers are seeded
    from the file, the plan honours every rule, the Terminal line hands the file
    over as --config, and a 'Rename map' field (the CLI's --rename-map) merges extra
    rules — the way to drop a file a 'refused: banned marker' row points at."""
    import json
    cfg = world["cfg"]
    cfg.visibility = "public"
    cfg.update = oe.UPDATE_BRANCH
    cfg.rename_map = oe.merge_rename_maps({}, {"exclude": ["hugmesh-actions:Dockerfile"]})
    cfg_path = tmp_path / "export.json"
    cfg_path.write_text(json.dumps(cfg.to_dict()))
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    page = golive.page(golive._page_ids["org-export"])
    page.config_path.setText(str(cfg_path))
    page._add_config()
    golive.next()
    assert golive.currentPage() is page
    # the file's own choices seeded the pickers and the Terminal line carries the file
    assert page.visibility.currentText() == "public"
    assert page.update_mode.currentData() == oe.UPDATE_BRANCH
    assert page.out_dir.text() == cfg.out_dir
    assert f"--config {cfg_path}" in page.cmd.text() and "--domain mesh.example" in page.cmd.text()
    assert "--org " not in page.cmd.text()
    planned = page.export_config()
    assert planned.include_generator is False and planned.skip_repos == cfg.skip_repos
    assert planned.visibility == "public" and planned.update == oe.UPDATE_BRANCH
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None, page.status.text()
    targets = [page.table.item(r, 1).text() for r in range(page.table.rowCount())]
    assert targets == ["exampleorg/example-actions", "exampleorg/example-parent",
                       "exampleorg/example-commons", "exampleorg/mesh.example.github.io"]
    actions = next(r for r in page.plan.repos if r.source == "hugmesh-actions")
    assert "Dockerfile: excluded by the rename map" in actions.excluded
    # the Rename map field: an extra file merged over the config's own map
    rm = tmp_path / "extra.json"
    rm.write_text(json.dumps({"repos": {"hugmesh-commons": "example-core"},
                              "exclude": ["hugmesh-parent:LICENSE"]}))
    page.rename_map.setText(str(rm))
    page.rename_map.editingFinished.emit()
    assert f"--rename-map {rm}" in page.cmd.text()
    page.plan_btn.click()
    _wait_worker(page, qapp)
    targets = [page.table.item(r, 1).text() for r in range(page.table.rowCount())]
    assert "exampleorg/example-core" in targets and "exampleorg/example-commons" not in targets
    parent = next(r for r in page.plan.repos if r.source == "hugmesh-parent")
    assert "LICENSE: excluded by the rename map" in parent.excluded
    actions = next(r for r in page.plan.repos if r.source == "hugmesh-actions")
    assert "Dockerfile: excluded by the rename map" in actions.excluded   # both maps apply
    assert f"--rename-map {rm}" in page.cmd.text() and page.cmd.text().endswith("--apply")
    # a rename map that cannot be read is said inline, and nothing is planned
    page.rename_map.setText(str(tmp_path / "nope.json"))
    page.plan = None
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is None
    assert page.status.isVisible() and "nope.json" in page.status.text()
    # the field is drawn where a person can use it (#647): visible, inside the
    # viewport, wide enough for a path, on the first screen at the smallest size
    page.rename_map.setText(str(rm))
    page.rename_map.editingFinished.emit()
    # ... and fixing the field clears the stale red line a failed Plan left (it used
    # to stay until the next Plan: correctness skeptic, round 1, concern 1)
    assert "nope.json" not in page.status.text(), page.status.text()
    golive.resize(820, 640)
    _settle(qapp, 10)
    viewport = page._content_scroll.viewport()
    assert page.rename_map.isVisible()
    top = page.rename_map.mapTo(viewport, page.rename_map.rect().topLeft())
    bottom = page.rename_map.mapTo(viewport, page.rename_map.rect().bottomRight())
    assert 0 <= top.x() and bottom.x() <= viewport.width(), (top, bottom)
    assert 0 <= top.y() and bottom.y() <= viewport.height(), (top, bottom)
    assert page.rename_map.width() >= 300, page.rename_map.width()
    _shot(golive, "golive-org-export-rename-map-field.png", tmp_path)


def test_a_banned_marker_is_cleared_from_the_gui_with_the_rename_map_field(
        golive, world, qapp, tmp_path):
    """The whole remedy a person gets in the GUI: a planted marker blocks one
    repository (its row red, the file named), Apply cannot be armed; an exclude
    rule typed into the Rename map field unblocks it and Apply arms."""
    import json
    from _org_export_helpers import git as _git
    token = "github_pat_" + "11FAKE" + "A" * 30
    src = os.path.join(world["src"], "hugmesh-commons")
    os.makedirs(os.path.join(src, "tests"), exist_ok=True)
    with open(os.path.join(src, "tests", "fake-token.sh"), "w", encoding="utf-8") as fh:
        fh.write(f"TOKEN={token}\n")
    _git(src, "add", "-A")
    _git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant")
    cfg_path = tmp_path / "export.json"
    cfg_path.write_text(json.dumps(world["cfg"].to_dict()))
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    page = golive.page(golive._page_ids["org-export"])
    page.config_path.setText(str(cfg_path))
    page._add_config()
    golive.next()
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None and page.plan.blocked, page.status.text()
    row = next(r for r in range(page.table.rowCount())
               if page.table.item(r, 0).text() == "hugmesh-commons")
    assert page.table.item(row, 2).text() == "refused: banned marker"
    assert "tests/fake-token.sh: GitHub fine-grained token" in page.table.item(row, 2).toolTip()
    assert "blocked" in page.status.text()
    page.confirm.setText("exampleorg")
    assert not page.apply_btn.isEnabled()
    rm = tmp_path / "unblock.json"
    rm.write_text(json.dumps({"exclude": ["hugmesh-commons:tests/fake-token.sh"]}))
    page.rename_map.setText(str(rm))
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None and not page.plan.blocked
    assert not page.apply_btn.isEnabled()           # the name typed for the BLOCKED plan is gone
    page.confirm.setText("exampleorg")
    assert page.apply_btn.isEnabled()
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))    # still a plan


def _planned_page(golive, world, qapp, tmp_path, visibility="public"):
    """The step with a clean plan made under ``visibility`` and Apply armed."""
    saved_mesh_naming_the_org(world)
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    assert isinstance(page, golive_mod.GoLiveOrgExportPage)
    page.out_dir.setText(str(tmp_path / "out"))
    page.visibility.setCurrentText(visibility)
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None and not page.plan.blocked, page.status.text()
    page.confirm.setText("exampleorg")
    assert page.apply_btn.isEnabled()
    return page


def _created(world) -> list[str]:
    return [c for c in world["runner"].gh_calls() if c.startswith("repo create")]


def test_flipping_the_visibility_picker_after_plan_disarms_apply_and_creates_nothing(
        golive, world, qapp, tmp_path):
    """The defect the correctness skeptic reproduced: Plan as public, flip the picker
    back to private, type the org, click Apply -> `gh repo create --public` ran under a
    screen that read private. The plan on screen is dropped by the change, so there is
    nothing to apply until a fresh Plan."""
    page = _planned_page(golive, world, qapp, tmp_path, visibility="public")
    assert "--public" in page.plan_text.toPlainText() or page.plan.config.visibility == "public"
    page.visibility.setCurrentText("private")
    assert page.plan is None and page.result is None
    assert not page.apply_btn.isEnabled()
    assert page.table.rowCount() == 0 and page.plan_text.toPlainText() == ""
    assert "--org-export PLAN" in page.cmd.text() and "--visibility" not in page.cmd.text()
    page.confirm.setText("exampleorg")
    assert not page.apply_btn.isEnabled()
    _settle(qapp, 10)
    _shot(golive, "golive-org-export-plan-dropped.png", tmp_path)
    page.apply_btn.click()                       # a disabled button: nothing runs
    page._apply()                                # and the slot itself refuses with no plan
    _wait_worker(page, qapp)
    assert _created(world) == [], world["runner"].gh_calls()
    assert not os.path.isdir(os.path.join(world["gh_root"], "exampleorg"))
    # a fresh Plan under what the screen shows is what arms Apply again, and it creates
    # PRIVATE repositories, as the picker says
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None and page.plan.config.visibility == "private"
    assert not page.apply_btn.isEnabled()           # the name is retyped for each plan
    page.confirm.setText("exampleorg")
    assert page.apply_btn.isEnabled()
    page.apply_btn.click()
    _wait_worker(page, qapp)
    created = _created(world)
    assert created and all("--private" in c and "--public" not in c for c in created), created


@pytest.mark.parametrize("change", ["update_mode", "source_dir", "out_dir", "rename_map",
                                    "config_added"])
def test_every_other_input_change_after_plan_also_drops_the_plan(
        golive, world, qapp, tmp_path, change):
    import json
    page = _planned_page(golive, world, qapp, tmp_path)
    if change == "update_mode":
        page.update_mode.setCurrentIndex(page.update_mode.findData(oe.UPDATE_BRANCH))
    elif change == "source_dir":
        other = tmp_path / "elsewhere"
        other.mkdir()
        page.source_dir.setText(str(other))
    elif change == "out_dir":
        page.out_dir.setText(str(tmp_path / "another-out"))
    elif change == "rename_map":
        rm = tmp_path / "rm.json"
        rm.write_text(json.dumps({"exclude": ["hugmesh-commons:README.md"]}))
        page.rename_map.setText(str(rm))
    else:                                         # a second source: the domain combo changes
        page.config_path.setText(os.path.join(os.path.dirname(os.path.abspath(oe.__file__)),
                                              "..", "..", "tests", "fixtures", "org_export",
                                              "mesh-config.json"))
        page._add_config()
        assert page.source.count() == 2
    assert page.plan is None and not page.apply_btn.isEnabled(), change
    assert page.table.rowCount() == 0 and page.plan_text.toPlainText() == "", change
    page.apply_btn.click()
    _wait_worker(page, qapp)
    assert _created(world) == [], (change, world["runner"].gh_calls())


def test_the_domain_combo_alone_drops_the_plan(golive, world, qapp, tmp_path):
    """Two sources, the same pickers: choosing the other domain/org is an input too."""
    import json
    page = _planned_page(golive, world, qapp, tmp_path)
    other = oe.ExportConfig(domain="other.example", org="otherorg", generator_dir=world["gen"],
                            source_mode="existing", source_dir=world["src"],
                            skip_repos=["hugmesh-build-config", "hugmesh-auth-core"],
                            include_generator=False, out_dir=str(tmp_path / "other-out"))
    path = tmp_path / "other.json"
    path.write_text(json.dumps(other.to_dict()))
    page.config_path.setText(str(path))
    page._add_config()
    assert page.source.count() == 2
    page.visibility.setCurrentText("public")
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None
    page.confirm.setText(page.plan.config.org)
    assert page.apply_btn.isEnabled()
    page.source.setCurrentIndex(0)                # same pickers, a different domain
    assert page.plan is None and not page.apply_btn.isEnabled()


def test_a_picker_changed_while_a_plan_runs_discards_that_plan(golive, world, qapp, tmp_path):
    saved_mesh_naming_the_org(world)
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    page.out_dir.setText(str(tmp_path / "out"))
    page.visibility.setCurrentText("public")
    page.plan_btn.click()
    page.visibility.setCurrentText("private")      # before the worker's result is delivered
    _wait_worker(page, qapp)
    assert page.plan is None and not page.apply_btn.isEnabled()
    assert "plan again" in page.status.text()
    page.confirm.setText("exampleorg")
    assert not page.apply_btn.isEnabled()
    assert page.plan_btn.isEnabled()


def test_the_pickers_are_locked_while_apply_runs_and_free_afterwards(
        golive, world, qapp, tmp_path):
    page = _planned_page(golive, world, qapp, tmp_path, visibility="private")
    page.apply_btn.click()
    assert not any(w.isEnabled() for w in page._pickers) and not page.add_btn.isEnabled()
    _wait_worker(page, qapp)
    assert page.result is not None and all(w.isEnabled() for w in page._pickers)
    assert page.plan_text.toPlainText().splitlines()[-1] != ""     # the result is shown
    assert not page.apply_btn.isEnabled()


def test_no_modal_dialogs_in_the_new_page_logic():
    src = inspect.getsource(golive_mod.GoLiveOrgExportPage)
    assert "QMessageBox" not in src and ".exec(" not in src and "exec_()" not in src
    src = inspect.getsource(domains_mod._OrgCell) + inspect.getsource(domains_mod.DomainsTableBody)
    assert "QMessageBox" not in src and ".exec(" not in src


# ── the round-1 skeptic findings ─────────────────────────────────────────────────────
def test_a_name_typed_for_a_private_plan_does_not_arm_a_later_public_plan(
        golive, world, qapp, tmp_path):
    """The typed org name armed ANY later plan: plan private, type the name, flip to
    public (the plan drops, Apply disarms, the text stayed), Plan again -> Apply was
    armed on a public export nobody had confirmed. The name belongs to one plan."""
    page = _planned_page(golive, world, qapp, tmp_path, visibility="private")
    page.visibility.setCurrentText("public")
    assert page.plan is None and not page.apply_btn.isEnabled()
    assert page.confirm.text() == "", "the name typed for the private plan is still there"
    page.plan_btn.click()
    _wait_worker(page, qapp)
    assert page.plan is not None and page.plan.config.visibility == "public"
    assert not page.apply_btn.isEnabled(), "armed without retyping the name"
    page.confirm.setText("exampleorg")
    assert page.apply_btn.isEnabled()
    assert _created(world) == []


def test_a_name_typed_while_a_plan_runs_does_not_arm_the_plan_that_arrives(
        golive, world, qapp, tmp_path):
    saved_mesh_naming_the_org(world)
    golive.export_runner = world["runner"]
    golive.export_remote_base = f"file://{world['gh_root']}/"
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    page.out_dir.setText(str(tmp_path / "out"))
    page.plan_btn.click()
    page.confirm.setText("exampleorg")            # typed before any plan can be read
    _wait_worker(page, qapp)
    assert page.plan is not None and not page.plan.blocked
    assert not page.apply_btn.isEnabled()


def test_a_config_file_with_a_wrongly_typed_value_is_refused_inline_and_nothing_aborts(
        golive, world, qapp, tmp_path):
    """`"brand": 123` used to be added as a candidate; Plan then raised inside the
    slot, which aborts the whole Studio process under PyQt6 (rc 134)."""
    import json
    saved_mesh_naming_the_org(world)
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()
    for key, value in (("brand", 123), ("org", 7), ("include_generator", "no"),
                       ("skip_repos", "hugmesh-parent"), ("domain", ["x"])):
        data = world["cfg"].to_dict()
        data[key] = value
        path = tmp_path / f"bad-{key}.json"
        path.write_text(json.dumps(data))
        before = page.source.count()
        page.config_path.setText(str(path))
        page._add_config()
        assert page.source.count() == before, key
        assert not page.status.isHidden() and key in page.status.text(), (key, page.status.text())
    _settle(qapp, 10)
    # the path is said ONCE (the engine's message already starts with it), and the
    # red line is tall enough for its wrapped text, not clipped
    assert page.status.text().count(str(path)) == 1, page.status.text()
    assert page.status.height() >= page.status.heightForWidth(page.status.width()) - 2, \
        (page.status.height(), page.status.heightForWidth(page.status.width()))
    _shot(golive, "golive-org-export-bad-config-refused.png", tmp_path)
    page.plan_btn.click()                         # the saved mesh's own plan still works
    _wait_worker(page, qapp)
    assert page.plan is not None


def test_a_settings_error_inside_plan_is_said_inline_never_raised_out_of_the_slot(
        golive, world, qapp, tmp_path, monkeypatch):
    """Whatever the settings hold, the Plan slot must not let an exception out."""
    saved_mesh_naming_the_org(world)
    _at_generate(golive)
    golive.next()
    page = golive.currentPage()

    def boom(self):
        raise AttributeError("'int' object has no attribute 'strip'")
    monkeypatch.setattr(oe.ExportConfig, "problems", boom)
    page.plan_btn.click()                         # must return
    assert not page.status.isHidden() and "could not be read" in page.status.text()
    assert page.plan is None and not page.apply_btn.isEnabled()
