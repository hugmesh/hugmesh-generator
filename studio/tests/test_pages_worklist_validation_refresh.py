"""WorklistPage validation refresh (issue #50 bug item): naming a checked desktop's
person must re-emit completeChanged, or the wizard never re-reads isComplete() and
Next stays disabled with a fully valid selection.

The reported symptom: "selecting all necessary images leaves Next disabled until you
toggle any node image type disabled->enabled to refresh validation". Root cause: the
who-uses-it dialog's ACCEPT path (`_ask_person`, reached from a real mouse click via
_on_item_clicked, or from double-clicking the people table via _edit_person) mutates
_desktop_people — flipping isComplete() False -> True — without emitting
completeChanged. Only the CANCEL path and the row-toggle handler emitted, which is
exactly why toggling an unrelated node row "fixed" the button.

Headless-safe per repo convention: the modal DesktopUserDialog is replaced with an
exec-free stand-in; the mouse-only handlers are invoked directly (itemClicked never
fires for programmatic checks, so nothing here can hang on a dialog).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                    # noqa: E402
from hugmesh_studio.gui.pages import worklist as worklist_mod      # noqa: E402
from hugmesh_studio.gui.pages.worklist import (                    # noqa: E402
    WorklistPage, _COL_CHECK,
)

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


class _AcceptedDialog:
    """Exec-free stand-in for DesktopUserDialog: 'accepts' immediately with a fixed
    person, so the mouse-path handlers can run headless (no modal event loop)."""

    def __init__(self, device_label, username="", roles="user", parent=None):
        self._user = "alice"
        self._role = "user"

    def exec(self):
        return QtWidgets.QDialog.DialogCode.Accepted

    def user(self):
        return self._user

    def person_role(self):
        return self._role

    def person_roles(self):
        # multi-role (issue #228): the page reads the full set — tier + grants
        return [self._role]


def _check(page, rid, on=True):
    page.rows[rid].setCheckState(
        _COL_CHECK, Qt.CheckState.Checked if on else Qt.CheckState.Unchecked)


def _spy_complete(page):
    """Record isComplete() at every completeChanged emission — QWizard re-reads it
    exactly (and only) then, so `True in seen` == "Next would have been enabled"."""
    seen = []
    page.completeChanged.connect(lambda: seen.append(page.isComplete()))
    return seen


def test_accepting_the_person_dialog_reenables_next(page, monkeypatch):
    """The issue #50 repro: all necessary images checked (node trio + a desktop for
    one of the mesh's people); the who-uses-it dialog is answered; Next must enable
    WITHOUT toggling an unrelated node row to refresh the validation."""
    for rid in ("pki.x86", "backend.x86", "frontend.x86"):
        _check(page, rid)
    assert page.isComplete()

    # the desktop check: itemChanged adds the unnamed placeholder -> Next disabled
    _check(page, "laptop.x86")
    assert page._desktop_people["laptop.x86"] == ("", ["user"])
    assert not page.isComplete()

    # a real mouse click then reaches _on_item_clicked, which prompts; accept it
    monkeypatch.setattr(worklist_mod, "DesktopUserDialog", _AcceptedDialog)
    seen = _spy_complete(page)
    page._on_item_clicked(page.rows["laptop.x86"], _COL_CHECK)

    assert page._desktop_people["laptop.x86"] == ("alice", ["user"])
    assert page.isComplete()
    assert True in seen, (
        "naming the desktop person must emit completeChanged: isComplete() flipped "
        "True but the wizard was never told, so Next stays disabled until an "
        "unrelated row toggle refreshes the validation (issue #50)")


def test_naming_the_person_via_table_edit_reenables_next(page, monkeypatch):
    """Same hole on the other entry point: the placeholder row says 'double-click to
    set the user' — doing exactly that (_edit_person -> _ask_person) must also
    re-emit completeChanged once the person is named."""
    _check(page, "pki.x86")
    _check(page, "laptop.x86")                        # placeholder, unnamed
    assert not page.isComplete()
    assert page.people_table.rowCount() == 1

    monkeypatch.setattr(worklist_mod, "DesktopUserDialog", _AcceptedDialog)
    seen = _spy_complete(page)
    page._edit_person(0, 0)                           # the advertised double-click

    assert page.isComplete()
    assert True in seen, (
        "editing the person via the people table must emit completeChanged, or "
        "Next stays disabled on a fully valid selection (issue #50)")
