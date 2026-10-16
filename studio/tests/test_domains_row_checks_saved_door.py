"""#631 sections 2 and 3, and the display-only item.

Section 2: the mesh image route's DomainsPage refuses on Next the three rows the
local-mesh Domains step and the TUI already refuse (a non-hostname, a duplicate, an
added row named after row 0), inline, never a modal. The rows are recorded either way.
A cloud table has no own row: its row 0 is the primary ``--domains`` element, so the
cluster domain's name is legitimate there and only junk and duplicates are refused.

Section 3: the saved-mesh door gates the RECORD, not the image flow's ``wiz.cfg`` table.

Display-only: the saved-meshes "Saved" cell shows the record's ``created`` stamp.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import saved_meshes                           # noqa: E402
from hugmesh_studio.core.config import Domain                          # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod        # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402
from hugmesh_studio.tui import domains_step, journey                   # noqa: E402

from _helpers import (  # noqa: E402
    advance_to, check_worklist_rows, enable_additional_domains, pick_mode)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-domain-row-checks"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(1000, 760)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_domains(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    return advance_to(wiz, wizard_mod.DomainsPage)


def _cloud_domains(wiz):
    pick_mode(wiz, "cloud")
    return advance_to(wiz, wizard_mod.DomainsPage)


def _last_row_name(dom, name):
    dom.table.item(dom.table.rowCount() - 1, 0).setText(name)


# ── section 2, GUI ──────────────────────────────────────────────────────────────
@pytest.mark.parametrize("typed, needle", [
    ("Not_A_Domain", "not a domain name"),
    ("junk", "not a domain name"),
])
def test_mesh_refuses_a_non_hostname_row_on_next(wiz, typed, needle):
    dom = _mesh_domains(wiz)
    dom._add("")
    _last_row_name(dom, typed)
    assert dom.validatePage() is False
    assert dom.row_note.isVisible()
    assert needle in dom.row_note.text() and typed in dom.row_note.text()
    wiz.next()                                       # the real Next is blocked too
    assert wiz.currentPage() is dom
    assert [d.name for d in wiz.cfg.domains] == [typed]   # recorded either way


def test_mesh_refuses_a_duplicate_row(wiz):
    dom = _mesh_domains(wiz)
    dom._add("acme.example")
    dom._add("acme.example")
    assert dom.validatePage() is False
    assert "already listed: acme.example" in dom.row_note.text()
    wiz.next()
    assert wiz.currentPage() is dom


def test_mesh_refuses_an_added_row_named_after_row_0(wiz):
    dom = _mesh_domains(wiz)
    own = wiz.cfg.cluster_domain
    assert own and dom.is_own_row(0)
    dom._add(own)
    assert dom.validatePage() is False
    assert "this mesh's own domain (row 0)" in dom.row_note.text()
    wiz.next()
    assert wiz.currentPage() is dom


def test_fixing_the_row_clears_the_note_and_lets_Next_through(wiz):
    dom = _mesh_domains(wiz)
    dom._add("junk")
    assert dom.validatePage() is False and dom.row_note.isVisible()
    _last_row_name(dom, "acme.example")
    assert dom.validatePage() is True
    assert not dom.row_note.isVisible() and dom.row_note.text() == ""
    wiz.next()
    assert wiz.currentPage() is not dom


def test_an_untouched_mesh_table_and_a_blank_row_pass_next(wiz):
    dom = _mesh_domains(wiz)
    assert dom.validatePage() is True and not dom.row_note.isVisible()
    dom._add("")                                     # a blank row was always ignored
    assert dom.validatePage() is True
    wiz.next()
    assert wiz.currentPage() is not dom


def test_default_cloud_table_passes_next_with_the_cluster_domain_row(wiz):
    """Cloud row 0 IS the prefilled cluster domain (the primary ``--domains``): a
    by-name own-domain refusal would refuse every default cloud flow."""
    dom = _cloud_domains(wiz)
    assert not any(dom.is_own_row(r) for r in range(dom.table.rowCount()))
    assert dom.table.item(0, 0).text() == wiz.cfg.cluster_domain
    assert dom.validatePage() is True and not dom.row_note.isVisible()
    wiz.next()
    assert wiz.currentPage() is not dom


def test_cloud_refuses_junk_and_a_duplicate_of_the_prefill(wiz):
    dom = _cloud_domains(wiz)
    first = wiz.cfg.cluster_domain
    dom._add(first)
    assert dom.validatePage() is False
    assert f"already listed: {first}" in dom.row_note.text()
    _last_row_name(dom, "junk")
    assert dom.validatePage() is False
    assert "not a domain name" in dom.row_note.text()


def test_the_note_is_inline_inside_the_page_and_clear_of_the_table(wiz, tmp_path):
    """Rendered, with geometry: the refusal is a visible label, inside the page, below
    the table, not overlapping it or the notes under it."""
    dom = _mesh_domains(wiz)
    dom._add("junk")
    dom._add("junk")
    wiz.next()
    QtWidgets.QApplication.processEvents()
    assert wiz.currentPage() is dom and dom.row_note.isVisible()
    page = dom.rect()
    note = dom.row_note.geometry()
    table = dom.table.geometry()
    assert note.width() > 0 and note.height() > 0
    assert page.contains(note), (page, note)
    assert note.top() >= table.bottom(), (note, table)         # below, not over, the table
    assert dom.row_note.styleSheet().find("#c62828") >= 0      # the refusal colour
    assert dom.admin_note.geometry().top() >= note.bottom()    # the next note is not covered
    shot = os.environ.get("HUGMESH_SHOT_DIR")
    if shot:
        os.makedirs(shot, exist_ok=True)
        wiz.grab().save(os.path.join(shot, "domains-row-refusal-mesh.png"))


# ── section 2, TUI ──────────────────────────────────────────────────────────────
def test_tui_mesh_refuses_an_added_row_named_after_the_own_domain():
    j = journey.Journey(".")
    j.cfg.mode = "mesh"
    j.cfg.additional_domains = True
    own = j.cfg.cluster_domain
    assert own
    j.goto("domains")
    j.feed(f"a {own}")
    assert "this mesh's own domain (row 0)" in j.status
    assert [d.name for d in j.cfg.domains] == []
    j.feed("a acme.example")
    assert [d.name for d in j.cfg.domains] == ["acme.example"]


def test_tui_cloud_still_accepts_the_cluster_domain_as_row_0():
    j = journey.Journey(".")
    j.cfg.mode = "cloud"
    own = j.cfg.cluster_domain
    j.goto("domains")
    j.feed(f"a {own}")
    assert [d.name for d in j.cfg.domains] == [own], j.status
    assert domains_step is not None


# ── section 3 ───────────────────────────────────────────────────────────────────
def _to(wiz, cls, limit=14):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        wiz.next()
    raise AssertionError(f"never reached {cls.__name__}")


def _ctl(wiz):
    return wiz.page(wiz._page_ids["localmesh"])


def _to_env(wiz):
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    assert isinstance(wiz.currentPage(), localmesh_mod.LocalMeshEnvPage)


def _saved_record(**over):
    rec = saved_meshes.SavedMesh(id=saved_meshes.new_id(), label="rec",
                                 config=LocalMeshBootstrapConfig(**over).to_dict())
    assert saved_meshes.save(rec)
    return rec


@pytest.mark.parametrize("mode", ["start", "restore"])
def test_an_image_flow_table_with_unwalked_rows_does_not_refuse_a_saved_mesh(
        wiz, monkeypatch, mode):
    ctl = _ctl(wiz)
    _to_env(wiz)
    wiz.cfg.mode = "mesh"
    wiz.cfg.domains = [Domain(name="unwalked.example")]     # the image flow's table
    wiz.cfg.domain_services_reviewed = []
    assert ctl._domain_services_refusal() != ""             # the FORM's start is refused
    started = []
    monkeypatch.setattr(ctl, "_launch", lambda *a, **k: started.append(a))
    ctl._start_saved(_saved_record(), mode)                  # a record with no domains
    assert "unwalked.example" not in ctl.status.text()
    assert started, "the record must start: " + ctl.status.text()


# ── display-only ────────────────────────────────────────────────────────────────
def test_the_saved_cell_is_the_created_stamp_and_a_healed_start_does_not_move_it(
        wiz, monkeypatch):
    """A Start that writes the walk into the record bumps ``updated`` (``save``) and
    leaves ``created`` alone, and the cell renders ``created``: nothing to refresh."""
    ctl = _ctl(wiz)
    _to_env(wiz)
    monkeypatch.setattr(ctl, "_launch", lambda *a, **k: None)
    rec = _saved_record(own_idp_domains=("never.example",))
    ctl.saved_meshes.refresh()
    cell = lambda: ctl.saved_meshes.table.item(0, 1).text()      # noqa: E731
    shown = cell()
    assert shown == rec.created[:16].replace("T", " ")
    ctl._load_saved(rec)
    _to(wiz, localmesh_mod.LocalMeshDomainServicesPage)
    w = ctl.domain_services
    for _ in range(8):
        if w.current_domain() == "never.example":
            break
        w._step(1)
    w._boxes["games"].setChecked(True)
    _to(wiz, localmesh_mod.LocalMeshReviewPage)
    updated_before = saved_meshes.load(rec.path()).updated
    ctl._start_saved(rec, "start")                           # heals the record
    healed = saved_meshes.load(rec.path())
    assert healed.domain_services_reviewed if hasattr(healed, "domain_services_reviewed") \
        else healed.config.get("domain_services_reviewed")
    assert healed.created == rec.created
    assert healed.updated >= updated_before
    assert cell() == shown
