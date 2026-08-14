"""WorklistPage desktop people (operator ask 2026-08-14): checking a desktop-class
row collects its person (user + role). The check itself only adds a PLACEHOLDER —
the modal dialog opens exclusively from a real mouse click (itemClicked), so a
programmatic check (these tests, the initializePage re-seed, _helpers) can never
hang on a dialog. Next stays disabled until every checked desktop is named."""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                   # noqa: E402
from hugmesh_studio.gui.pages.worklist import WorklistPage, _COL_CHECK  # noqa: E402

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
    assert page._desktop_people["laptop.x86"] == ("", "user")
    assert not page.isComplete()
    assert page.people_table.isVisibleTo(page)       # the table shows the gap
    page._desktop_people["laptop.x86"] = ("alice", "admin")
    assert page.isComplete()
    _check(page, "laptop.x86", on=False)             # unchecking forgets the pair
    assert "laptop.x86" not in page._desktop_people
    assert page.isComplete()


def test_validate_stamps_the_person_onto_the_entry(page):
    _check(page, "pki.x86")
    _check(page, "laptop.x86")
    page._desktop_people["laptop.x86"] = ("alice", "admin")
    page._refresh_people_table()
    assert page.validatePage()
    wl = page.wiz.worklist
    lap = {e.id: e for e in wl.entries}["laptop.x86"]
    assert (lap.desktop_user, lap.desktop_user_role) == ("alice", "admin")
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
    page._desktop_people["desktop.x86"] = ("bob", "user")
    assert page.validatePage()
    page._desktop_people.clear()                     # simulate a fresh visit
    page.initializePage()
    assert page._desktop_people.get("desktop.x86") == ("bob", "user")
