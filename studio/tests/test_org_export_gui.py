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
from _org_export_helpers import bare_log, make_world, saved_mesh_naming_the_org  # noqa: E402

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
    for name in ("source", "plan_btn", "confirm", "apply_btn", "status", "table"):
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
    assert not any("--force" in c or "--mirror" in c or "--delete" in c for c in joined)
    _shot(golive, "golive-org-export-applied.png", tmp_path)


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


def test_no_modal_dialogs_in_the_new_page_logic():
    src = inspect.getsource(golive_mod.GoLiveOrgExportPage)
    assert "QMessageBox" not in src and ".exec(" not in src and "exec_()" not in src
    src = inspect.getsource(domains_mod._OrgCell) + inspect.getsource(domains_mod.DomainsTableBody)
    assert "QMessageBox" not in src and ".exec(" not in src
