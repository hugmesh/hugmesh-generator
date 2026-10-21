"""The "copies for this domain" part of the Code folders block, driven headless with a
fake git (operator ask 2026-10-21: per-domain folders, named for the domain, holding
only the apps that domain has; extra folders removed only on an explicit second click).

Pinned here:

* *Make N copies* is visible, enabled, a clickable size, and clones exactly the
  domain's missing apps on a worker thread; afterwards each row shows and opens the
  domain's COPY;
* a domain that did not choose owncast has no owncast row and no owncast copy;
* un-ticking a service lists its copies as extra; the first click on *Remove* removes
  nothing and says what would go and what is kept; only the second click removes;
  *Keep them* disarms; a folder holding work of its own is kept;
* the folder of a domain that left the mesh gets its own frame with the same two-click
  removal;
* the rendered block is a real picture (PNG paths written for a person to look at).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import domain_workspaces as dw                  # noqa: E402
from hugmesh_studio.core.config import Domain                           # noqa: E402
from hugmesh_studio.core.open_path import OpenResult                    # noqa: E402
from hugmesh_studio.gui.pages import _code_folders_widget as cfw        # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402

COMPOSE = """\
services:
  hugmesh-fe-gateway:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-gateway
  hugmesh-user-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-user-ui
  hugmesh-owncast-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-owncast-ui
  hugmesh-owncast-bff-api:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-owncast-bff-api
"""
REPOS = ("hugmesh-gateway", "hugmesh-user-ui", "hugmesh-owncast-ui",
         "hugmesh-owncast-bff-api")
OWN = "own.example"
SHOTS = os.environ.get("CODE_FOLDERS_SHOTS_DIR", "")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-copies-tests"]))


@pytest.fixture
def gen(tmp_path):
    g = tmp_path / "gen"
    (g / "tests" / "stack").mkdir(parents=True)
    (g / "tests" / "stack" / "compose.local.yaml").write_text(COMPOSE)
    return str(g)


@pytest.fixture
def src(tmp_path):
    s = tmp_path / "src"
    for name in REPOS:
        (s / name / ".git").mkdir(parents=True)
    return str(s)


class FakeGit:
    def __init__(self):
        self.calls = []
        self.dirty = {}

    def __call__(self, argv, cwd):
        self.calls.append((list(argv), cwd))
        if argv[0] == "clone":
            os.makedirs(os.path.join(argv[-1], ".git"))
        if argv[0] == "status":
            return 0, "\n".join(" M f" for _ in range(self.dirty.get(cwd, 0)))
        if argv[0] == "rev-list":
            return 0, "0"
        return 0, ""


class FakeOpener:
    def __init__(self):
        self.paths = []

    def __call__(self, path):
        self.paths.append(path)
        return OpenResult(True, True, "fake exited 0", path)


@pytest.fixture
def block(qapp, gen, tmp_path):
    git = FakeGit()
    w = cfw.CodeFoldersWidget(gen, opener=FakeOpener(), git_runner=git,
                              state_root=str(tmp_path / "state"))
    w.git = git
    w.resize(736, 900)
    w.show()
    yield w
    w.wait_idle()
    w.close()
    w.deleteLater()


def _rows(live_services=("owncast",)):
    return [Domain(name=OWN), Domain(name="live.example",
                                     optional_services=list(live_services))]


def _settle(n=3):
    for _ in range(n):
        QtWidgets.QApplication.processEvents()


def _sane(btn):
    assert btn.isVisible(), btn.text()
    assert btn.width() >= 60 and btn.height() >= 20, (btn.text(), btn.size())


def _shot(widget, name):
    if not SHOTS:
        return ""
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name)
    assert widget.grab().save(path)
    return path


def test_make_copies_clones_exactly_the_domains_missing_apps(block, src):
    block.refresh("existing", src, _rows(), own_name=OWN)
    _settle()
    btn = block.clone_buttons["live.example"]
    _sane(btn)
    assert btn.isEnabled() and btn.text() == "Make 4 copies"
    assert block.clone_buttons[OWN].text() == "Make 2 copies"
    assert "0 of 4 made" in block.copy_labels["live.example"].text()
    _shot(block, "copies-1-before.png")
    btn.click()
    assert block.wait_idle()
    cloned = sorted(os.path.basename(a[-1]) for a, _c in block.git.calls if a[0] == "clone")
    assert cloned == ["hugmesh-gateway.live.example", "hugmesh-owncast-bff-api.live.example",
                      "hugmesh-owncast-ui.live.example", "hugmesh-user-ui.live.example"]
    assert "Made 4 copies for live.example." == block.result_note.text()
    assert "4 of 4 made" in block.copy_labels["live.example"].text()
    done = block.clone_buttons["live.example"]
    assert done.text() == "All copies made" and not done.isEnabled()
    # the row now stands for the copy, and opens it
    key = ("live.example", "hugmesh-owncast-ui")
    copy = os.path.join(block.plan.root, "live.example", "hugmesh-owncast-ui.live.example")
    assert block.row_paths[key] == copy
    block.open_buttons[key].click()
    assert block._opener.paths[-1] == copy
    # the own domain chose no owncast: no row, no copy planned
    assert (OWN, "hugmesh-owncast-ui") not in block.open_buttons
    own_ws = next(d for d in block.plan.domains if d.name == OWN)
    assert {r.app for r in own_ws.repos} == {"hugmesh-gateway", "hugmesh-user-ui"}
    _shot(block, "copies-2-made.png")


def test_removing_extra_copies_takes_two_clicks(block, src):
    block.refresh("existing", src, _rows(), own_name=OWN)
    block.clone_buttons["live.example"].click()
    assert block.wait_idle()
    # owncast is un-ticked on the Domain services step
    block.refresh("existing", src, _rows(live_services=()), own_name=OWN)
    _settle()
    label = block.extra_labels["live.example"]
    assert label.isVisible()
    assert "2 extra folders" in label.text() and "hugmesh-owncast-ui" in label.text()
    rm = block.remove_buttons["live.example"]
    _sane(rm)
    assert rm.isEnabled() and rm.text() == "Remove 2 extra folders…"
    assert not block.cancel_buttons["live.example"].isVisible()
    ws = next(d for d in block.plan.domains if d.name == "live.example")
    paths = [x.path for x in ws.extras]
    # FIRST click: nothing goes
    rm.click()
    _settle()
    assert block.wait_idle()
    assert all(os.path.isdir(p) for p in paths)
    rm = block.remove_buttons["live.example"]
    assert rm.text() == "Click again to remove 2 folders"
    _sane(rm)
    _sane(block.cancel_buttons["live.example"])
    assert "no edits of its own" in block.extra_labels["live.example"].text()
    shot = _shot(block, "copies-3-armed.png")
    # SECOND click: they go
    rm.click()
    assert block.wait_idle()
    assert not any(os.path.exists(p) for p in paths)
    assert block.result_note.text() == "Removed 2 extra folders for live.example."
    assert "live.example" not in block.remove_buttons
    assert sorted(os.listdir(ws.folder)) == ["hugmesh-gateway.live.example",
                                             "hugmesh-user-ui.live.example"]
    _shot(block, "copies-4-removed.png")
    del shot


def test_keep_them_disarms_and_removes_nothing(block, src):
    block.refresh("existing", src, _rows(), own_name=OWN)
    block.clone_buttons["live.example"].click()
    assert block.wait_idle()
    block.refresh("existing", src, _rows(live_services=()), own_name=OWN)
    block.remove_buttons["live.example"].click()
    _settle()
    block.cancel_buttons["live.example"].click()
    _settle()
    assert "live.example" not in block.armed
    assert block.remove_buttons["live.example"].text() == "Remove 2 extra folders…"
    # a click now is a FIRST click again
    block.remove_buttons["live.example"].click()
    assert block.wait_idle()
    ws = next(d for d in block.plan.domains if d.name == "live.example")
    assert len(ws.extras) == 2 and all(os.path.isdir(x.path) for x in ws.extras)


def test_a_copy_with_edits_is_named_on_the_first_click_and_kept(block, src):
    block.refresh("existing", src, _rows(), own_name=OWN)
    block.clone_buttons["live.example"].click()
    assert block.wait_idle()
    block.refresh("existing", src, _rows(live_services=()), own_name=OWN)
    ws = next(d for d in block.plan.domains if d.name == "live.example")
    dirty = next(x.path for x in ws.extras if x.app == "hugmesh-owncast-ui")
    block.git.dirty[dirty] = 3
    block.remove_buttons["live.example"].click()
    _settle()
    text = block.extra_labels["live.example"].text()
    assert "holds 3 changed files — it will be kept" in text
    assert block.remove_buttons["live.example"].text() == "Click again to remove 1 folder"
    block.remove_buttons["live.example"].click()
    assert block.wait_idle()
    assert os.path.isdir(dirty)
    assert not os.path.exists(next(x.path for x in ws.extras if x.path != dirty))


def test_a_domain_that_left_the_mesh_gets_its_own_frame(block, src):
    block.refresh("existing", src, _rows(), own_name=OWN)
    block.clone_buttons["live.example"].click()
    assert block.wait_idle()
    block.refresh("existing", src, [Domain(name=OWN)], own_name=OWN)
    _settle()
    frames = block.findChildren(QtWidgets.QFrame, "code_folders_gone_domain")
    assert len(frames) == 1 and frames[0].isVisible()
    assert block.remove_buttons["live.example"].text() == "Remove 4 extra folders…"
    _shot(block, "copies-5-gone-domain.png")
    block.remove_buttons["live.example"].click()
    _settle()
    block.remove_buttons["live.example"].click()
    assert block.wait_idle()
    assert not os.path.exists(os.path.join(block.plan.root, "live.example"))
    assert not block.findChildren(QtWidgets.QFrame, "code_folders_gone_domain")


def test_a_missing_build_checkout_disables_make_copies_with_the_reason(block, tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    block.refresh("existing", str(empty), _rows(), own_name=OWN)
    _settle()
    btn = block.clone_buttons["live.example"]
    assert btn.isVisible() and not btn.isEnabled()
    assert "cannot be made yet: the build checkout is not there yet" in \
        block.copy_labels["live.example"].text()


def test_the_copies_root_and_the_edits_sentence_are_on_screen(block, src):
    block.refresh("existing", src, _rows(), own_name=OWN)
    _settle()
    assert block.copies_root.full_text() == os.path.join(
        block.state_root, "domain-code", OWN)
    assert block.copies_note.isVisible() and block.copies_note.text() == dw.EDITS_NOTE
