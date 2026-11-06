"""The local-mesh page on native Windows: the `make` teardown verbs are greyed with the
WSL2 sentence, and a press says it BEFORE any confirmation, note or dialog.

The Windows sweep made every core verb behind these buttons refuse (stack-halt,
stack-clean, stack-m2-bootstrap, kind-down/-halt/-resume, the seeders), but the page
still armed Stop mesh / Stop && clean Docker / Build maven prereqs (m2) / Delete
DevOps lane, asked "Delete the DevOps lane?" for a deletion that could never run,
opened the Add-user dialog for an account that could never be created, and ended
the readiness report with "'Build maven prereqs (m2)' covers the maven-registry one",
a button that refuses there too.

The host is pinned the test_windows_sweep_c6 way (``native_windows_blocker`` with
``osname`` bound), never by changing os.name, so this runs on Linux CI and Windows
alike, and the Linux half proves Linux is unchanged.
"""
from __future__ import annotations

import functools
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest  # noqa: E402

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed in this job")

from hugmesh_studio.core import platform_info  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import (  # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.gui.pages import localmesh  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
_REAL_BLOCKER = platform_info.native_windows_blocker
STACK = _REAL_BLOCKER("The local stack", osname="nt")
LANE = _REAL_BLOCKER("The DevOps (Kubernetes) lane", osname="nt")


def _answer_as(monkeypatch, osname):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_BLOCKER, osname=osname))


@pytest.fixture
def as_native_windows(monkeypatch):
    _answer_as(monkeypatch, "nt")


@pytest.fixture
def as_linux(monkeypatch):
    _answer_as(monkeypatch, "posix")


@pytest.fixture
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


@pytest.fixture
def page(qapp):
    """The real page, in the standalone dialog (held, so Qt does not delete it)."""
    dlg = localmesh.LocalMeshDialog(GENERATOR_DIR)
    yield dlg.page
    dlg.close()


def _buttons(page):
    return {"Stop mesh": page.boot_down_btn, "Stop && clean Docker": page.boot_clean_btn,
            "m2": page.m2_btn, "Delete DevOps lane": page.devops_down_btn}


# ── the real page: greyed with the sentence, from first paint and after every verb ─
def test_on_native_windows_the_teardown_verbs_are_greyed_with_the_wsl2_sentence(
        as_native_windows, page):
    for _round in range(2):             # construction, then the end-of-verb re-gate
        for name, btn in _buttons(page).items():
            assert not btn.isEnabled(), name
            want = LANE if btn is page.devops_down_btn else STACK
            assert btn.toolTip() == f"Disabled: {want}", name
            assert "WSL2" in btn.toolTip()
        page._set_verbs_enabled(True)


def test_on_linux_the_teardown_verbs_keep_their_own_gates(as_linux, page):
    page._mesh_up = None                # unknown: the existing gate leaves them armed
    page._set_verbs_enabled(True)
    for name, btn in _buttons(page).items():
        assert btn.isEnabled(), name
        assert "WSL2" not in btn.toolTip(), name
    assert "KEPT" in page.boot_down_btn.toolTip()


def test_a_running_mesh_on_native_windows_is_not_told_to_stop_it_here(as_native_windows, page):
    page._on_mesh_state(True, "3 container(s)")
    text = page._mesh_state_label.text()
    assert "cannot stop it" in text and "WSL2" in text
    assert "stop it first" not in text


def test_a_running_mesh_on_linux_keeps_its_sentence(as_linux, page):
    page._on_mesh_state(True, "3 container(s)")
    assert "stop it first if you want a clean bring-up" in page._mesh_state_label.text()


# ── the handlers: the refusal comes first, nothing else happens ────────────────────
class _Page:
    """Only what the handlers touch; anything else raises AttributeError."""
    generator_dir = GENERATOR_DIR

    def __init__(self):
        self.refused, self.launched, self.notes = [], [], []

    def _refuse(self, text):
        self.refused.append(text)

    def _note(self, text, queue=True):
        self.notes.append(text)

    def _launch(self, title, fn, **kw):
        self.launched.append((title, fn))

    def collect_bootstrap(self):
        return LocalMeshBootstrapConfig()


@pytest.mark.parametrize("verb, sentence", [("_bootstrap_down", STACK),
                                             ("_bootstrap_clean", STACK),
                                             ("_m2_bootstrap", STACK),
                                             ("_devops_down", LANE),
                                             ("_devops_halt", LANE),
                                             ("_devops_resume", LANE)])
def test_on_native_windows_each_press_is_refused_before_anything(
        monkeypatch, as_native_windows, verb, sentence):
    def _boom(*a, **k):
        raise AssertionError("no confirmation for a verb that cannot run")
    monkeypatch.setattr(localmesh, "confirm_devops_down", _boom)
    monkeypatch.setattr(QtWidgets.QMessageBox, "question", _boom)
    page = _Page()
    getattr(localmesh.LocalMeshPage, verb)(page)
    assert page.refused == [sentence]
    assert page.launched == [] and page.notes == []


def test_on_native_windows_add_user_refuses_before_its_dialog(monkeypatch, as_native_windows):
    def _boom(*a, **k):
        raise AssertionError("the dialog must not ask for a username and password")
    monkeypatch.setattr(localmesh, "AddUserDialog", _boom)
    page = _Page()
    localmesh.LocalMeshPage._add_user(page)
    assert page.refused == [_REAL_BLOCKER("Adding a user", osname="nt")]
    assert "WSL2" in page.refused[0] and page.launched == []


def _readiness(monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "preflight", lambda self: ["a problem"])
    page = _Page()
    localmesh.LocalMeshPage._check_readiness(page)
    (_title, probe), = page.launched
    return probe()


def test_on_native_windows_readiness_names_no_m2_remedy(monkeypatch, as_native_windows):
    ok, lines = _readiness(monkeypatch)
    assert not ok and lines == ["[readiness] NOT ready:", "  - a problem"]


def test_on_linux_readiness_still_names_the_m2_button(monkeypatch, as_linux):
    ok, lines = _readiness(monkeypatch)
    assert not ok and "'Build maven prereqs (m2)'" in lines[-1]
