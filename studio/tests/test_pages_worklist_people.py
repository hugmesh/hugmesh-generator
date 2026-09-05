"""WorklistPage desktop people (operator ask 2026-08-14): checking a desktop-class
row collects its person (user + roles). The check itself only adds a PLACEHOLDER —
the modal dialog opens exclusively from a real mouse click (itemClicked), so a
programmatic check (these tests, the initializePage re-seed, _helpers) can never
hang on a dialog. Next stays disabled until every checked desktop is named.

Multi-role (issue #228): the person's roles are a tier plus any grants; the page
keeps the FULL set, the entry derives the tier (``desktop_user_role``) from it."""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (                          # noqa: E402
    PERSON_ROLE_CHOICES, USER_GRANT_CHOICES, USER_ROLE_CHOICES)
from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                   # noqa: E402
from hugmesh_studio.gui.pages import worklist as worklist_mod     # noqa: E402
from hugmesh_studio.gui.pages.worklist import WorklistPage, _COL_CHECK  # noqa: E402
from hugmesh_studio.gui.pages._desktop_user_dialog import DesktopUserDialog  # noqa: E402

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
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.cfg.mode = "mesh"
    pid = [i for i in w.pageIds() if isinstance(w.page(i), WorklistPage)][0]
    p = w.page(pid)
    p.initializePage()
    yield p
    w.deleteLater()


def _check(page, rid, on=True):
    page.rows[rid].setCheckState(
        _COL_CHECK, Qt.CheckState.Checked if on else Qt.CheckState.Unchecked)


def test_desktop_rows_exist_in_the_mesh_worklist(page):
    for rid in ("laptop.x86", "chromebook.x86", "desktop.x86"):
        assert rid in page.rows, f"{rid} missing from the mesh worklist"


def test_checked_desktop_blocks_next_until_named(page):
    _check(page, "pki.x86")
    assert page.isComplete()
    _check(page, "laptop.x86")                       # placeholder, unnamed
    assert page._desktop_people["laptop.x86"] == ("", ["user"])
    assert not page.isComplete()
    assert page.people_table.isVisibleTo(page)       # the table shows the gap
    page._desktop_people["laptop.x86"] = ("alice", ["admin"])
    assert page.isComplete()
    _check(page, "laptop.x86", on=False)             # unchecking forgets the pair
    assert "laptop.x86" not in page._desktop_people
    assert page.isComplete()


def test_validate_stamps_the_person_onto_the_entry(page):
    _check(page, "pki.x86")
    _check(page, "laptop.x86")
    page._desktop_people["laptop.x86"] = ("alice", ["admin"])
    page._refresh_people_table()
    assert page.validatePage()
    wl = page.wiz.worklist
    lap = {e.id: e for e in wl.entries}["laptop.x86"]
    assert (lap.desktop_user, lap.desktop_user_role) == ("alice", "admin")
    assert lap.desktop_user_roles == ["admin"]
    pki = {e.id: e for e in wl.entries}["pki.x86"]
    assert pki.desktop_user == ""
    # and the manifest derivation picks it up on the internal superdomain
    users = wl.desktop_users()
    assert [(u.username, u.role) for u in users] == [("alice", "admin")]


def test_validate_refuses_an_unnamed_desktop(page):
    _check(page, "pki.x86")
    _check(page, "laptop.x86")                       # placeholder never named
    assert not page.validatePage()


def test_revisit_reseeds_people_from_saved_entries(page):
    _check(page, "pki.x86")
    _check(page, "desktop.x86")
    page._desktop_people["desktop.x86"] = ("bob", ["user"])
    assert page.validatePage()
    page._desktop_people.clear()                     # simulate a fresh visit
    page.initializePage()
    assert page._desktop_people.get("desktop.x86") == ("bob", ["user"])


# ---- multi-role (issue #228) ----------------------------------------------------

def test_dialog_offers_a_tier_plus_the_grants(qapp):
    """The who-uses-it dialog: ONE tier (the --person-role value) plus a checkbox per
    grant. FAILS on the single-role dialog: no `grants`, no `person_roles()`."""
    dlg = DesktopUserDialog("laptop (x86)", "alice", ["games", "admin"])
    try:
        assert [dlg.role.itemData(i) for i in range(dlg.role.count())] == \
            list(PERSON_ROLE_CHOICES)
        assert [g for g, _box in dlg.grants] == list(USER_GRANT_CHOICES) == \
            ["games", "games-services"]
        # the tier picker + the grants cover exactly the Users table's vocabulary
        assert set(PERSON_ROLE_CHOICES) | set(USER_GRANT_CHOICES) == set(USER_ROLE_CHOICES)
        assert dlg.person_role() == "admin"
        assert dlg.person_roles() == ["admin", "games"]
        dict(dlg.grants)["games-services"].setChecked(True)
        dlg.role.setCurrentIndex(dlg.role.findData("mod"))
        assert dlg.person_roles() == ["mod", "games", "games-services"]
        for _g, box in dlg.grants:
            box.setChecked(False)
        assert dlg.person_roles() == ["mod"]          # never empty: the tier is in it
    finally:
        dlg.deleteLater()
    # the pre-#228 spelling (one role string) still seeds the dialog
    one = DesktopUserDialog("laptop (x86)", "bob", "superadmin")
    try:
        assert one.person_role() == "superadmin" and one.person_roles() == ["superadmin"]
        assert not any(box.isChecked() for _g, box in one.grants)
    finally:
        one.deleteLater()


def test_ask_person_hands_the_dialog_the_full_set_and_keeps_what_it_returns(page, monkeypatch):
    """_ask_person must round-trip the FULL set through the dialog (prefill from the
    page's map, collect via person_roles()) — a page still reading person_role()
    would silently drop every grant. The dialog is faked so nothing exec()s."""
    seen = {}

    class Fake:
        def __init__(self, label, user, roles, parent=None):
            seen["in"] = (user, list(roles))

        def exec(self):
            return QtWidgets.QDialog.DialogCode.Accepted

        def user(self):
            return "alice"

        def person_role(self):
            raise AssertionError("the page must read person_roles(), not the tier alone")

        def person_roles(self):
            return ["admin", "games"]

    monkeypatch.setattr(worklist_mod, "DesktopUserDialog", Fake)
    _check(page, "laptop.x86")
    page._desktop_people["laptop.x86"] = ("alice", ["mod", "games-services"])
    assert page._ask_person("laptop.x86")
    assert seen["in"] == ("alice", ["mod", "games-services"])
    assert page._desktop_people["laptop.x86"] == ("alice", ["admin", "games"])
    assert page.people_table.item(0, 2).text() == "admin, games"


def test_validate_stamps_a_multi_role_person_onto_the_entry_and_manifest(page):
    _check(page, "pki.x86")
    _check(page, "laptop.x86")
    page._desktop_people["laptop.x86"] = ("alice", ["games", "admin"])
    page._refresh_people_table()
    assert page.people_table.horizontalHeaderItem(2).text() == "Roles"
    assert page.people_table.item(0, 2).text() == "admin, games"
    assert page.validatePage()
    wl = page.wiz.worklist
    lap = {e.id: e for e in wl.entries}["laptop.x86"]
    assert lap.desktop_user_roles == ["admin", "games"]
    assert lap.desktop_user_role == "admin"                 # the derived tier
    users = wl.desktop_users()
    assert [(u.username, u.roles, u.role) for u in users] == \
        [("alice", ["admin", "games"], "admin")]
    by_id = {e.id: cfg for e, cfg in wl.materialize()}
    assert by_id["laptop.x86"].person_role == "admin"
    # revisit re-seeds the full set, not just the tier
    page._desktop_people.clear()
    page.initializePage()
    assert page._desktop_people["laptop.x86"] == ("alice", ["admin", "games"])
