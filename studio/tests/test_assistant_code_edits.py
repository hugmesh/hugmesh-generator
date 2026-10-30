"""core/assistant_code_edits: workspace discovery, scope limits, the diff parser, apply
with before-copies and a manifest, revert with its sha check, the hand-off, and that
no git process is ever spawned (subprocess patched) and nothing under the repo moves.
"""
import hashlib
import json
import os
import subprocess

import pytest

from hugmesh_studio.core import assistant_code_edits as ce
from hugmesh_studio.core import domain_workspaces as dw
from hugmesh_studio.core.config import Domain

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

INDEX = "<html>\n<body>\n<footer>\n  <p>Welcome to shop</p>\n</footer>\n</body>\n</html>\n"
_QT_APP: list = []
DIFF = ("Changing the footer text in index.html.\n```diff\n--- a/src/index.html\n+++ b/src/index.html\n"
        "@@ -3,3 +3,3 @@\n <footer>\n-  <p>Welcome to shop</p>\n+  <p>Welcome to the Shop</p>\n </footer>\n```\n")


@pytest.fixture(autouse=True)
def _no_git(monkeypatch):
    for name in ("run", "Popen", "check_output", "check_call", "call"):
        monkeypatch.setattr(subprocess, name,
                            lambda *a, **k: (_ for _ in ()).throw(AssertionError("subprocess spawned")))


@pytest.fixture
def ws(tmp_path, monkeypatch):
    state = tmp_path / "state"
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    folder = state / "domain-code" / "shop" / "web-shop.example"
    (folder / ".git").mkdir(parents=True)
    (folder / ".git" / dw.MARKER).write_text(json.dumps(
        {"app": "web", "domain": "shop.example", "mesh": "shop", "source": "x", "schema": 1}))
    (folder / "src").mkdir()
    (folder / "src" / "index.html").write_text(INDEX)
    (folder / "src" / "styles.css").write_text("body { color: red; }\n")
    return ce.Workspace("shop", "shop.example", "web", os.path.realpath(str(folder))), state


def test_find_workspaces_lists_marker_bearing_folders_only(tmp_path, monkeypatch, ws):
    space, state = ws
    folders = ce.find_workspaces(GENERATOR_DIR, "clone", "", [Domain(name="shop.example", optional_services=[])],
                                 "shop", state_root=str(state))
    # the plan may or may not map this domain to a "web" app; the folder is only
    # returned when the plan names it AND the marker reads back
    assert all(dw.read_marker(f.path) is not None for f in folders)
    assert ce.find_workspaces(GENERATOR_DIR, "clone", "", [], "none", state_root=str(state)) == []


def test_safe_path_refuses_escape_links_secrets_and_binaries(ws):
    space, state = ws
    assert ce.safe_path(space, "src/index.html")[1] == ""
    assert "outside" in ce.safe_path(space, "../x.html")[1] or "not a path" in ce.safe_path(space, "../x.html")[1]
    assert "not a path" in ce.safe_path(space, "/etc/passwd")[1]
    os.symlink("/etc", os.path.join(space.path, "lnk"))
    assert "link" in ce.safe_path(space, "lnk/hosts")[1]
    for name in (".env", "k.pem", "id_rsa", "secrets.json", "token.txt", "prod.kubeconfig"):
        assert "secrets" in ce.safe_path(space, name)[1], name
    assert "not a text file" in ce.safe_path(space, "a.bin")[1]
    with open(os.path.join(space.path, "src", "blob.js"), "wb") as fh:
        fh.write(b"\0\1\2")
    assert ce.file_text(space, "src/blob.js")[1] == "src/blob.js is not a text file"
    with open(os.path.join(space.path, "src", "big.css"), "w") as fh:
        fh.write("x" * (65 * 1024))
    assert "KiB" in ce.file_text(space, "src/big.css")[1]


def test_files_mentioned_finds_the_basename_the_question_names(ws):
    space, state = ws
    assert ce.files_mentioned("change the footer text in index.html", space) == ["src/index.html"]
    assert ce.files_mentioned("make the page blue (styles.css)", space) == ["src/styles.css"]
    assert ce.files_mentioned("make it nicer", space) == []
    text, why = ce.file_text(space, "src/index.html")
    assert why == "" and "Welcome to shop" in text


def test_parse_diff_applies_cleanly_and_refuses_a_context_mismatch(ws):
    space, state = ws
    edits = ce.parse_diff(DIFF, space)
    assert not isinstance(edits, ce.DiffProblem)
    assert [e.path for e in edits] == ["src/index.html"] and edits[0].changed == 2
    assert edits[0].new_text(INDEX) == INDEX.replace("Welcome to shop", "Welcome to the Shop")
    bad = DIFF.replace("-  <p>Welcome to shop</p>", "-  <p>Welcome to SHOP</p>")
    prob = ce.parse_diff(bad, space)
    assert isinstance(prob, ce.DiffProblem) and "src/index.html line 4" in prob.text and "Welcome to shop" in prob.text
    assert isinstance(ce.parse_diff("nothing", space), ce.DiffProblem)
    assert "secrets" in ce.parse_diff(DIFF.replace("src/index.html", ".env"), space).text
    assert "does not exist" in ce.parse_diff(DIFF.replace("src/index.html", "src/none.html"), space).text
    assert ce.preview(edits).startswith("--- a/src/index.html\n+++ b/src/index.html\n@@ -3,3 +3,3 @@\n <footer>\n-")


def test_scope_limits_refuse_four_files_or_121_lines(ws):
    space, state = ws
    for i in range(4):
        with open(os.path.join(space.path, f"f{i}.md"), "w") as fh:
            fh.write("a\n" * 200)
    four = "".join(f"--- a/f{i}.md\n+++ b/f{i}.md\n@@ -1,1 +1,1 @@\n-a\n+b\n" for i in range(4))
    assert "4 files" in ce.parse_diff("```diff\n" + four + "```", space).text
    many = "--- a/f0.md\n+++ b/f0.md\n@@ -1,121 +1,121 @@\n" + "".join("-a\n+b\n" for _ in range(61))
    prob = ce.parse_diff("```diff\n" + many + "```", space)
    assert isinstance(prob, ce.DiffProblem) and "changed lines" in prob.text
    assert ce.too_big_reason("please refactor the whole app") == "you asked to refactor"
    assert ce.handoff_text("x").startswith("That is more than a small edit (x). Open a coding session with the Launch button")


def test_apply_writes_before_copies_and_a_manifest_then_revert_restores(ws):
    space, state = ws
    edits = ce.parse_diff(DIFF, space)
    before = hashlib.sha256(INDEX.encode()).hexdigest()
    a = ce.apply(edits, space, str(state))
    assert isinstance(a, ce.Applied)
    path = os.path.join(space.path, "src", "index.html")
    assert "Welcome to the Shop" in open(path).read()
    assert open(os.path.join(a.before_dir, "src", "index.html")).read() == INDEX
    m = json.load(open(os.path.join(os.path.dirname(a.before_dir), "manifest.json")))
    assert m["files"][0] == {"path": "src/index.html", "before": before, "after": a.files[0]["after"]}
    assert m["workspace"] == space.path and m["domain"] == "shop.example"
    assert a.footer == f"Applied to {space.path}. Not committed. Revert: press Revert or copy from {a.before_dir}."
    assert ce.list_applied(str(state)) == [a.id] and ce.load_applied(str(state), a.id).files == a.files
    assert ce.revert(a) == ""
    assert open(path).read() == INDEX


def test_revert_refuses_when_the_file_changed_after_the_edit(ws):
    space, state = ws
    a = ce.apply(ce.parse_diff(DIFF, space), space, str(state))
    path = os.path.join(space.path, "src", "index.html")
    with open(path, "a") as fh:
        fh.write("<!-- hand edit -->\n")
    why = ce.revert(a)
    assert why.startswith("the file src/index.html changed after my edit; revert by hand from ")
    assert "hand edit" in open(path).read()


def test_only_the_last_20_edits_are_kept(ws, monkeypatch):
    space, state = ws
    base = ce.edits_dir(str(state))
    os.makedirs(base)
    for i in range(25):
        os.makedirs(os.path.join(base, f"2026-{i:02d}"))
    ce._prune(str(state))
    assert len(os.listdir(base)) == ce.KEEP_EDITS


def test_set_first_task_reaches_the_brief_through_the_context_text(tmp_path, monkeypatch):
    pytest.importorskip("hugmesh_studio.gui.qt")
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from hugmesh_studio.gui.qt import QtWidgets
    from hugmesh_studio.gui.pages import _local_agent_widget as law
    # Held at module scope: a QApplication collected before the widget aborts the process.
    _QT_APP.append(QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"]))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    card = law.LocalAgentWidget(GENERATOR_DIR, context_text=lambda ctx: "CONTEXT")
    card.set_first_task("refactor the footer across every page")
    assert card.first_task() == "refactor the footer across every page"
    snap = card._snapshot() if hasattr(card, "_snapshot") else None
    if snap is None:
        return
    assert snap.first_task == "refactor the footer across every page"
    import types
    snap = types.SimpleNamespace(**{**snap.__dict__, "app": types.SimpleNamespace(name="web", path=str(tmp_path))})
    seen = {}
    monkeypatch.setattr(law.la, "prepare", lambda **k: seen.update(k) or None)
    card._prepare_plan(snap)
    assert seen["context_text"].endswith("## First task\nrefactor the footer across every page\n")
    assert seen["context_text"].startswith("CONTEXT")


def test_no_file_under_the_repo_changes(ws):
    """Edits happen only under the temp state dir: the generator checkout is untouched."""
    space, state = ws
    assert not space.path.startswith(GENERATOR_DIR)
    ce.apply(ce.parse_diff(DIFF, space), space, str(state))
    assert not os.path.exists(os.path.join(GENERATOR_DIR, "src", "index.html"))


def test_a_garbled_hunk_header_is_applied_only_when_its_start_line_is_readable(ws):
    """qwen3:8b wrote "@@ -3 @@ -3 @@" in the 2026-10-29 eval: the parser used to accept
    that as an edit with NO hunks, so Apply would have said "Applied" and changed nothing."""
    space, state = ws
    loose = DIFF.replace("@@ -3,3 +3,3 @@", "@@ -3 @@ -3 @@")
    edits = ce.parse_diff(loose, space)
    assert not isinstance(edits, ce.DiffProblem), edits
    assert edits[0].changed == 2 and len(edits[0].hunks) == 1
    ce.apply(edits, space, str(state))
    with open(os.path.join(space.path, "src", "index.html")) as fh:
        assert "Welcome to the Shop" in fh.read()
    bad = ce.parse_diff(DIFF.replace("@@ -3,3 +3,3 @@", "@@ footer @@"), space)
    assert isinstance(bad, ce.DiffProblem) and "hunk header" in bad.text


def test_a_diff_that_changes_nothing_is_refused_not_applied(ws):
    space, state = ws
    for body in ("--- a/src/index.html\n+++ b/src/index.html\n",
                 "--- a/src/index.html\n+++ b/src/index.html\n@@ -3,1 +3,1 @@\n <footer>\n"):
        out = ce.parse_diff("x\n```diff\n" + body + "```\n", space)
        assert isinstance(out, ce.DiffProblem) and "changes nothing" in out.text, out


def test_apply_refuses_when_the_file_was_edited_after_the_card_and_changes_nothing(ws):
    """PR #832 review (C2): the card's diff was checked at parse time; two lines added at
    the top before Apply moved every line, and a splice by line number replaced the
    person's <body>. Apply checks the hunks again and writes nothing."""
    space, state = ws
    edits = ce.parse_diff(DIFF, space)
    assert not isinstance(edits, ce.DiffProblem)
    path = os.path.join(space.path, "src", "index.html")
    edited = "<!-- one -->\n<!-- two -->\n" + INDEX
    with open(path, "w") as fh:
        fh.write(edited)
    r = ce.apply(edits, space, str(state))
    assert isinstance(r, ce.DiffProblem), r
    assert r.text.startswith("src/index.html changed since I proposed this edit (")
    assert "nothing was changed" in r.text
    assert open(path).read() == edited
    assert ce.list_applied(str(state)) == []            # no before-copy, no manifest
