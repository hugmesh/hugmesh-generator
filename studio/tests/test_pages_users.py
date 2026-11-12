"""UsersPage: the per-row Domain dropdown offers every domain the flow serves.

GUI-12 (GUI retest 2026-11-11). On the mesh route the dropdown was built from the
superdomain and ``cfg.domains`` only, so it never offered the mesh's OWN domain
(``cfg.cluster_domain``) — the implicit row that is always served and that the
Domains page cannot add as a row. The "Create nodes for local cloud" import places
every non-superadmin account on exactly that domain (``localcloud_nodes`` ->
``dom = superdomain if "superadmin" in roles else cfg.cluster_domain``), so every
imported row read '<own domain> (not defined)', cut to "hugmesh.ne" by the 100px
column, under an orange warning that listed the own domain once per row (thirty-one
times for a 32-account mesh) and said to "define them there".

What these pin:
* mesh: the own domain is offered and a row on it is defined (no flag, no warning);
* local cloud: the import yields no '(not defined)' row and no warning;
* cloud: nothing implicit is added (a cloud client's own domain is a real row 0);
* the warning names each undefined domain once;
* geometry: the Domain column shows its rows' text uncut, also after Back-navigation
  adds a longer domain; the '(not defined)' flag is in the cell's tooltip too.
"""
from __future__ import annotations

import os
import time

import pytest

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="Qt binding (PySide6/PyQt6) not installed")

from hugmesh_studio.core.config import Domain, User  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as lc_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

from _helpers import (  # noqa: E402
    advance_to, back_to, check_worklist_rows, enable_additional_domains,
    enable_configure_users, pick_mode,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

_COL_DOMAIN = 1
_FLAG = " (not defined)"

# a saved local mesh the import reads: one superadmin and the rest on the apex — the
# shape the lane probe saw (32 accounts, 31 of them flagged).
LC_DOMAIN = "mesh.example.org"
LC_USERS = ([("superadmin", ["superadmin"]), ("alice", ["admin", "games"])]
            + [(f"user{i:02d}", ["user"]) for i in range(6)])


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _canned_local_mesh(monkeypatch):
    """The Local-cloud gate reads a saved mesh and probes k8s on entry: both canned,
    and the teardown is a tripwire so no test can reach the operator's cluster."""
    monkeypatch.setattr(lc_mod, "local_mesh_identity",
                        lambda _gd: (LC_DOMAIN, list(LC_USERS), False))
    monkeypatch.setattr(lc_mod, "local_k8s_running", lambda _gd: False)

    def _never(*_a, **_k):
        raise AssertionError("local_k8s_teardown called from a Users-page test")
    monkeypatch.setattr(lc_mod, "local_k8s_teardown", _never)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-users-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(1200, 800)
    w.show()          # offscreen: real geometry, and per-widget isVisible() is meaningful
    yield w
    # never let the Local-cloud page's k8s probe thread outlive its page
    lc = w.page(w._page_ids["localcloud"])
    for name in ("_k8s_probe", "worker"):
        t = getattr(lc, name, None)
        if t is not None:
            try:
                t.wait(5000)
            except RuntimeError:
                pass
    qapp.processEvents()
    w.close()
    w.deleteLater()


# ---- helpers ------------------------------------------------------------------------

def _combo(users, row):
    combo = users.table.cellWidget(row, _COL_DOMAIN)
    assert isinstance(combo, QtWidgets.QComboBox), "the Domain cell is a dropdown"
    return combo


def _items(combo):
    return [combo.itemText(i) for i in range(combo.count())]


def _texts(users):
    return [_combo(users, r).currentText() for r in range(users.table.rowCount())]


def _settle(qapp):
    for _ in range(5):
        qapp.processEvents()


def _uncut(combo) -> bool:
    """Whether the combo's text area (frame, padding and arrow excluded) is as wide
    as its current text — i.e. nothing is elided."""
    opt = QtWidgets.QStyleOptionComboBox()
    opt.initFrom(combo)
    opt.editable = combo.isEditable()
    opt.frame = combo.hasFrame()
    field = combo.style().subControlRect(
        QtWidgets.QStyle.ComplexControl.CC_ComboBox, opt,
        QtWidgets.QStyle.SubControl.SC_ComboBoxEditField, combo)
    return field.width() >= combo.fontMetrics().horizontalAdvance(combo.currentText())


def _mesh_to_users(wiz, users=()):
    """Mesh flow, the default "just this mesh's own domain" card (no Domains table
    rows), the users TABLE card, then the Users step — seeded with ``users``."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "backend.x86")
    wiz.cfg.users = list(users)
    enable_configure_users(wiz)
    return advance_to(wiz, wizard_mod.UsersPage)


def _localcloud_import_to_users(wiz, qapp):
    pick_mode(wiz, "localcloud")
    gate = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    deadline = time.monotonic() + 5
    while gate._k8s_up is None and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    assert gate._k8s_up is False, "fixture: the canned k8s probe answered 'down'"
    gate.confirm.setChecked(True)
    wiz.next()
    return advance_to(wiz, wizard_mod.UsersPage)


# ---- mesh: the own domain is a domain ----------------------------------------------

def test_mesh_dropdown_offers_the_mesh_own_domain(wiz):
    users = _mesh_to_users(wiz)
    c = wiz.cfg
    assert c.mode == "mesh" and c.cluster_domain, "fixture: a mesh with its own domain"
    assert c.domains == [], "fixture: no Domains-table rows (the default card)"
    users._add("bob", role="user")
    assert _items(_combo(users, 0)) == [c.effective_superdomain(), c.cluster_domain]


def test_mesh_row_on_the_own_domain_is_defined_and_kept(wiz):
    own = "own.example"
    pick_mode(wiz, "mesh")
    wiz.cfg.cluster_domain = own
    users = _mesh_to_users(wiz, [User(username="bob", domain=own, role="user"),
                                 User(username="carol", domain=own, role="mod")])
    assert _texts(users) == [own, own], "the own domain is selected, not flagged"
    assert not users.warn.isVisible()
    assert users.warn.text() == "" or own not in users.warn.text()
    advance_to(wiz, wizard_mod.SystemPage)          # Next past Users collects the table
    assert [(u.username, u.domain) for u in wiz.cfg.users] == [("bob", own),
                                                               ("carol", own)]


# ---- local cloud: the import's accounts resolve ------------------------------------

def test_localcloud_import_yields_no_undefined_domain(wiz, qapp):
    users = _localcloud_import_to_users(wiz, qapp)
    c = wiz.cfg
    assert c.cluster_domain == LC_DOMAIN
    assert users.table.rowCount() == len(LC_USERS)
    texts = _texts(users)
    assert not [t for t in texts if t.endswith(_FLAG)], texts
    assert texts == [c.effective_superdomain()] + [LC_DOMAIN] * (len(LC_USERS) - 1)
    assert not users.warn.isVisible()
    assert LC_DOMAIN not in users.warn.text()
    # every non-superadmin row can still be moved off and back onto the own domain
    for r in range(1, users.table.rowCount()):
        assert LC_DOMAIN in _items(_combo(users, r))
    advance_to(wiz, wizard_mod.SystemPage)
    assert {u.domain for u in c.users if "superadmin" not in u.roles} == {LC_DOMAIN}


# ---- cloud: nothing implicit --------------------------------------------------------

def test_cloud_dropdown_adds_no_implicit_own_domain(wiz):
    """A cloud client's own domain is a REAL Domains row 0 (prefilled), never an
    implicit one: a table without it does not get it back through this dropdown."""
    c = wiz.cfg
    c.mode = "cloud"
    c.cluster_domain = "own.example"
    c.domains = [Domain(name="acme.example", title="Acme")]
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    assert [d.name for d in c.domains] == ["acme.example"], "fixture: no own row"
    users._add("bob", role="user")
    assert _items(_combo(users, 0)) == [c.effective_superdomain(), "acme.example"]


# ---- the warning: each undefined domain once ----------------------------------------

def test_warning_names_each_undefined_domain_once(wiz):
    c = wiz.cfg
    c.mode = "cloud"
    c.domains = [Domain(name="acme.example", title="Acme")]
    c.users = [User(username=f"u{i}", domain="ghost.example", role="user")
               for i in range(5)]
    c.users.append(User(username="v", domain="other.example", role="user"))
    c.users.append(User(username="w", domain="acme.example", role="user"))
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    assert users.warn.isVisible()
    text = users.warn.text()
    assert text.count("ghost.example") == 1, text
    assert text.count("other.example") == 1, text
    assert "acme.example" not in text, text
    assert text.index("ghost.example") < text.index("other.example"), "row order"


# ---- geometry + tooltip -------------------------------------------------------------

def test_domain_column_shows_every_row_uncut(wiz, qapp):
    """The 100px default cut the superdomain to "hugmesh.inte" and an imported row to
    "hugmesh.ne"; the flag never showed at all. Measured off the rendered widgets."""
    c = wiz.cfg
    c.mode = "cloud"
    c.domains = [Domain(name="acme.example", title="Acme")]
    c.users = [User(username="root", domain="", role="superadmin"),
               User(username="bob", domain="a-rather-long-ghost-domain.example",
                    role="user"),
               User(username="carol", domain="acme.example", role="user")]
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    _settle(qapp)
    texts = _texts(users)
    assert texts[0] == c.effective_superdomain()
    assert texts[1] == "a-rather-long-ghost-domain.example" + _FLAG
    for r in range(users.table.rowCount()):
        combo = _combo(users, r)
        assert combo.width() <= users.table.columnWidth(_COL_DOMAIN)
        assert _uncut(combo), (r, combo.currentText(), combo.width())


def test_domain_column_refits_after_back_navigation_adds_a_longer_domain(wiz, qapp):
    users = _mesh_to_users(wiz, [User(username="bob", domain="", role="user")])
    _settle(qapp)
    narrow = users.table.columnWidth(_COL_DOMAIN)
    longer = "a-considerably-longer-tenant-domain.example"
    back_to(wiz, wizard_mod.DomainsChoicePage)
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add(longer, "Longer")
    users = advance_to(wiz, wizard_mod.UsersPage)
    combo = _combo(users, 0)
    assert longer in _items(combo), "a newly-defined domain reaches the dropdown"
    combo.setCurrentText(longer)
    _settle(qapp)
    assert users.table.columnWidth(_COL_DOMAIN) > narrow
    assert _uncut(combo), (combo.currentText(), combo.width())


def test_undefined_flag_is_in_the_cell_tooltip(wiz):
    c = wiz.cfg
    c.mode = "cloud"
    c.domains = [Domain(name="acme.example", title="Acme")]
    c.users = [User(username="bob", domain="ghost.example", role="user"),
               User(username="carol", domain="acme.example", role="user")]
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    flagged, fine = _combo(users, 0), _combo(users, 1)
    assert "ghost.example" in flagged.toolTip()
    assert "not defined" in flagged.toolTip()
    assert fine.toolTip() == "acme.example"
    # picking a defined domain clears the flag from the tooltip as well
    flagged.setCurrentText("acme.example")
    assert "not defined" not in flagged.toolTip()
    assert not users.warn.isVisible()
