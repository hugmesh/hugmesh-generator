"""Two native-Windows failures that left the person with no true sentence (#827):

* "Load config" on a file that does not load (malformed, the ANSI code page Windows
  PowerShell 5.1 ``Set-Content`` writes, the wrong JSON shape) raised out of the Qt
  slot: no "Loaded" box, no error box, only a crash log nobody opens;
* removing an extra code-folder copy ran a plain ``shutil.rmtree`` on a git clone,
  whose objects git writes read-only. Windows refuses to delete those, so the removal
  stopped half-way and left a copy that then looked hand-edited for good.

The rmtree tests run on every host: on Linux they pass with or without the fix (a
delete there depends on the folder, not the file), on Windows they fail without it.
"""
import os
import shutil
import stat
import subprocess

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import domain_workspaces as dw           # noqa: E402
from hugmesh_studio.core.config import Domain                     # noqa: E402

COMPOSE = """\
services:
  hugmesh-fe-gateway:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-gateway
  hugmesh-owncast-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-owncast-ui
"""
MESH = "own.example"
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")


# ── removing a copy ─────────────────────────────────────────────────────────────
def _read_only_tree(root):
    """A folder shaped like a clone's: a read-only object under .git/objects."""
    obj = root / ".git" / "objects" / "0f"
    obj.mkdir(parents=True)
    (root / ".git" / "HEAD").write_text("ref: refs/heads/main\n")
    f = obj / "abc"
    f.write_bytes(b"x")
    os.chmod(f, stat.S_IREAD)
    return f


def test_the_copy_rmtree_deletes_read_only_files(tmp_path):
    root = tmp_path / "copy"
    _read_only_tree(root)
    dw._rmtree(str(root))
    assert not root.exists()


def test_off_windows_the_copy_rmtree_is_the_plain_one(tmp_path, monkeypatch):
    seen = []
    monkeypatch.setattr(dw.shutil, "rmtree", lambda path, **kw: seen.append((path, kw)))
    dw._rmtree("x", osname="posix")
    assert seen == [("x", {})]


@pytest.mark.parametrize("func", ["scandir", "open"])
def test_only_a_refused_delete_is_retried(tmp_path, monkeypatch, func):
    """A listing that fails is raised as it was, not chmod-ed and called again."""
    target = tmp_path / "d"
    target.mkdir()
    refused = PermissionError(13, "denied", str(target))

    def fake_rmtree(path, onexc=None, onerror=None):
        handler = onexc or (lambda f, p, e: onerror(f, p, (type(e), e, None)))
        handler(getattr(os, func), path, refused)
    monkeypatch.setattr(dw.shutil, "rmtree", fake_rmtree)
    with pytest.raises(PermissionError) as got:
        dw._rmtree(str(target), osname="nt")
    assert got.value is refused


def test_a_refused_delete_of_a_read_only_file_is_retried_writable(tmp_path, monkeypatch):
    f = tmp_path / "obj"
    f.write_bytes(b"x")
    os.chmod(f, stat.S_IREAD)

    def fake_rmtree(path, onexc=None, onerror=None):
        handler = onexc or (lambda fn, p, e: onerror(fn, p, (type(e), e, None)))
        handler(os.unlink, str(f), PermissionError(13, "denied", str(f)))
    monkeypatch.setattr(dw.shutil, "rmtree", fake_rmtree)
    dw._rmtree(str(tmp_path), osname="nt")
    assert not f.exists()


@pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")
def test_with_the_real_git_an_extra_copy_is_removed_whole(tmp_path):
    gen = tmp_path / "gen"
    (gen / "tests" / "stack").mkdir(parents=True)
    (gen / "tests" / "stack" / "compose.local.yaml").write_text(COMPOSE)
    src = tmp_path / "src"
    for name in ("hugmesh-gateway", "hugmesh-owncast-ui"):
        p = src / name
        p.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(p)], check=True, env=GIT_ENV)
        (p / "README").write_text(name)
        subprocess.run(["git", "-C", str(p), "add", "README"], check=True, env=GIT_ENV)
        subprocess.run(["git", "-C", str(p), "commit", "-qm", "init"], check=True,
                       env=GIT_ENV)
    state = str(tmp_path / "state")
    rows = [Domain(name="live.example", optional_services=["owncast"])]
    plan = dw.plan_workspaces(str(gen), "existing", str(src), rows, MESH, state_root=state)
    results = dw.clone_missing(plan, "live.example")
    assert all(r.ok for r in results), [r.message for r in results]
    # owncast un-ticked: its copy is extra, a plain clone, and must go in one piece
    plan = dw.plan_workspaces(str(gen), "existing", str(src), [Domain(name="live.example")],
                              MESH, state_root=state)
    [extra] = [x for x in plan.extras()
               if os.path.basename(x.path) == "hugmesh-owncast-ui.live.example"]
    res = dw.remove_extra(extra, plan)
    assert res.removed, res.message
    assert not os.path.exists(extra.path)


# ── "Load config" ───────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def qapp():
    """One QApplication, HELD for every page test. A discarded one is freed at once
    under PyQt6, and the QWizardPage built next aborts the whole process (SIGABRT),
    so none of the page tests ran there; PySide6 happened to keep it alive."""
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp, tmp_path, monkeypatch):
    from hugmesh_studio.gui.pages import sessions
    from hugmesh_studio.gui.qt import QtWidgets

    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    said = []
    for kind in ("information", "warning", "critical"):
        monkeypatch.setattr(QtWidgets.QMessageBox, kind,
                            staticmethod(lambda _parent, title, text, *a, _k=kind, **kw:
                                         said.append((_k, title, text))))

    class Wiz:
        """The real load_config's body (wizard.py) without the rest of the wizard."""
        restarted = 0

        def load_config(self, path):
            from hugmesh_studio.core import worklist
            self.cfg, self.worklist = worklist.load_any(path)
            self.restarted += 1

    pg = sessions.SessionsPage(Wiz())

    def choose(path):
        monkeypatch.setattr(QtWidgets.QFileDialog, "getOpenFileName",
                            staticmethod(lambda *a, **kw: (str(path), "JSON (*.json)")))
        pg._load()
        return said
    pg.choose = choose
    return pg


@pytest.mark.parametrize("raw", [
    b"{not json",
    '{"hostname": "café"}'.encode("cp1252"),      # Windows PowerShell 5.1 Set-Content
    b"[1, 2]",
])
def test_a_config_that_does_not_load_says_so(page, tmp_path, raw):
    bad = tmp_path / "bad.json"
    bad.write_bytes(raw)
    said = page.choose(bad)
    assert [(k, t) for k, t, _ in said] == [("warning", "Could not load")]
    assert said[0][2].startswith(f"{bad} could not be loaded: ")
    assert page.wiz.restarted == 0


def test_a_config_in_the_ansi_code_page_is_told_how_to_fix_it(page, tmp_path):
    bad = tmp_path / "ansi.json"
    bad.write_bytes('{"hostname": "café"}'.encode("cp1252"))
    [(_, _, text)] = page.choose(bad)
    assert "Save it again as UTF-8" in text


def test_a_utf16_config_without_a_bom_is_not_called_not_utf16(page, tmp_path):
    # json_files.decode trusts UTF-16 only with a BOM, so this file is read as UTF-8 and
    # its é (E9 00) breaks the decode. The dialog must not claim it is not UTF-16.
    bad = tmp_path / "utf16-no-bom.json"
    bad.write_bytes('{"hostname": "café"}'.encode("utf-16-le"))
    [(kind, _, text)] = page.choose(bad)
    assert kind == "warning"
    assert "not UTF-8 text, nor UTF-16 with a byte order mark" in text
    assert "Save it again as UTF-8" in text


def test_a_config_that_loads_still_says_loaded(page, tmp_path):
    good = tmp_path / "good.json"
    good.write_text("{}", encoding="utf-8")
    said = page.choose(good)
    assert said == [("information", "Loaded", f"Loaded {good}")]
    assert page.wiz.restarted == 1


def _handler_of(monkeypatch):
    """The onexc handler dw._rmtree installs on native Windows, captured unrun."""
    got = {}

    def fake_rmtree(path, onexc=None, onerror=None):
        got["h"] = onexc or (lambda f, p, e: onerror(f, p, (type(e), e, None)))
    monkeypatch.setattr(dw.shutil, "rmtree", fake_rmtree)
    dw._rmtree("ignored", osname="nt")
    return got["h"]


def test_a_refused_delete_of_a_link_is_not_chmodded_through(tmp_path, monkeypatch):
    target = tmp_path / "target"
    target.mkdir()
    os.chmod(target, stat.S_IREAD | stat.S_IEXEC)
    link = tmp_path / "link"
    try:
        os.symlink(target, link, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("this host cannot make a symlink")
    before = os.stat(target).st_mode
    handler = _handler_of(monkeypatch)
    refused = PermissionError(13, "denied", str(link))
    with pytest.raises(PermissionError):
        handler(os.unlink, str(link), refused)
    assert os.stat(target).st_mode == before
    os.chmod(target, stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)


def test_an_error_that_is_not_a_refusal_is_raised_as_it_is(tmp_path, monkeypatch):
    f = tmp_path / "f"
    f.write_bytes(b"x")
    os.chmod(f, stat.S_IREAD)
    handler = _handler_of(monkeypatch)
    gone = FileNotFoundError(2, "gone", str(f))
    with pytest.raises(FileNotFoundError):
        handler(os.unlink, str(f), gone)
    assert f.exists() and not os.access(f, os.W_OK)       # no chmod, no retry
    os.chmod(f, stat.S_IWRITE | stat.S_IREAD)
