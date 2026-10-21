"""A folder per domain holding a git copy of each app that domain has
(core/domain_workspaces.py, operator ask 2026-10-21).

Pinned here, with a FAKE git (a runner that records every argv and makes the folders a
clone would make) and, once, the real git:

* the domain folder and every copy's folder carry the domain's name, made safe: no
  ``/``, no ``..``, nothing hidden, nothing a link can redirect;
* only the apps the domain HAS are copied — never the apps of a service it did not
  choose — and every copy comes from the local build checkout;
* a copy is named for its domain inside git too (branch, description, config) and the
  marker that makes it "ours" is written last;
* an app the domain no longer has, and the folder of a domain that left the mesh, are
  EXTRA; a folder without the marker and anything reached through a link never is;
* removal re-checks everything and keeps a copy that holds work of its own.
"""
import json
import os
import shutil
import subprocess

import pytest

from hugmesh_studio.core import domain_workspaces as dw
from hugmesh_studio.core.config import Domain

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
  owncast-bff-db:
    image: postgres:16-alpine
  hugmesh-tor:
    profiles: ["tor"]
    build:
      context: ./tor
"""
REPOS = ("hugmesh-gateway", "hugmesh-user-ui", "hugmesh-owncast-ui",
         "hugmesh-owncast-bff-api")
MESH = "own.example"


@pytest.fixture
def gen(tmp_path):
    g = tmp_path / "gen"
    (g / "tests" / "stack").mkdir(parents=True)
    (g / "tests" / "stack" / "compose.local.yaml").write_text(COMPOSE)
    return str(g)


@pytest.fixture
def src(tmp_path):
    """The operator's build tree with every checkout present."""
    s = tmp_path / "src"
    for name in REPOS:
        (s / name / ".git").mkdir(parents=True)
    return str(s)


@pytest.fixture
def state(tmp_path):
    return str(tmp_path / "state")


class FakeGit:
    """Records every git call. ``clone`` makes the destination with a ``.git`` folder
    (what a clone leaves behind); ``status``/``rev-list``/``stash list``/``worktree
    list`` answer from ``dirty`` / ``ignored`` / ``unpushed`` / ``stashed`` /
    ``worktrees``; ``fail`` names a subcommand that exits 1.

    It answers ``rev-list`` only when asked about EVERY ref (``--all``) and reports
    ignored files only under ``status --ignored``: a narrower question (HEAD only, or
    no ``--ignored``) gets the answer the real git would give for a copy whose work is
    on another branch or in an ignored file — none — so a check that asks too narrowly
    goes red here, not only against the real git."""

    def __init__(self, dirty=None, unpushed=None, fail="", stashed=None, ignored=None,
                 worktrees=None):
        self.calls = []
        self.dirty = dirty or {}
        self.unpushed = unpushed or {}
        self.stashed = stashed or {}
        self.ignored = ignored or {}
        self.worktrees = worktrees or {}
        self.fail = fail

    def __call__(self, argv, cwd):
        self.calls.append((list(argv), cwd))
        if argv[0] == self.fail:
            return 1, f"fatal: {self.fail} broke"
        if argv[0] == "clone":
            dest = argv[-1]
            os.makedirs(os.path.join(dest, ".git"))
            return 0, ""
        if argv[0] == "status":
            lines = [" M f"] * self.dirty.get(cwd, 0)
            if "--ignored" in argv:
                lines += ["!! .env"] * self.ignored.get(cwd, 0)
            return 0, "\n".join(lines)
        if argv[0] == "rev-list":
            return 0, str(self.unpushed.get(cwd, 0) if "--all" in argv else 0)
        if argv[:2] == ["stash", "list"]:
            return 0, "\n".join(f"stash@{{{i}}}: WIP" for i in range(self.stashed.get(cwd, 0)))
        if argv[:2] == ["worktree", "list"]:
            n = 1 + self.worktrees.get(cwd, 0)
            return 0, "\n".join(f"worktree /w{i}\nHEAD abc\n" for i in range(n))
        return 0, ""


def _plan(gen, src, state, rows):
    return dw.plan_workspaces(gen, "existing", src, rows, MESH, state_root=state)


def _ws(plan, name):
    return next(d for d in plan.domains if d.name == name)


# ── names ──────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("raw,safe", [
    ("Chat.Example.ORG", "chat.example.org"),
    ("../../etc", "etc"),
    ("a/b\\c d", "a-b-c-d"),
    ("..", ""),
    (".", ""),
    ("...", ""),
    ("", ""),
    ("\x00", ""),
    (".hidden", "hidden"),
    ("-rf", "rf"),
    ("a..b", "a.b"),
    ("x.lock", "x-lock"),
    ("ü.example", "example"),
])
def test_a_domain_name_becomes_one_safe_folder_name(raw, safe):
    assert dw.safe_folder_name(raw) == safe


def test_a_long_name_is_capped():
    assert len(dw.safe_folder_name("a" * 300 + ".example")) <= 100


def test_a_climbing_domain_name_lands_inside_the_copies_folder(gen, src, state):
    plan = _plan(gen, src, state, [{"name": "../../../escape", "optional_services": []}])
    ws = plan.domains[0]
    assert ws.slug == "escape"
    root = os.path.realpath(plan.root)
    assert os.path.realpath(ws.folder).startswith(root + os.sep)
    for r in ws.repos:
        assert os.path.realpath(r.dest).startswith(root + os.sep)


def test_two_names_that_make_the_same_folder_are_refused_not_merged(gen, src, state):
    plan = _plan(gen, src, state, [Domain(name="a.example"), Domain(name="A.Example")])
    assert plan.domains[0].problem == ""
    second = plan.domains[1]
    assert "would share the folder" in second.problem
    assert all(not r.can_clone for r in second.repos)


def test_the_copies_live_under_the_studio_state_named_for_the_mesh(gen, src, state):
    plan = _plan(gen, src, state, [Domain(name="chat.example.org")])
    assert plan.root == os.path.join(state, "domain-code", "own.example")
    ws = plan.domains[0]
    assert ws.folder == os.path.join(plan.root, "chat.example.org")
    gw = next(r for r in ws.repos if r.app == "hugmesh-gateway")
    assert gw.folder_name == "hugmesh-gateway.chat.example.org"
    assert gw.dest == os.path.join(ws.folder, "hugmesh-gateway.chat.example.org")
    assert gw.source == os.path.join(src, "hugmesh-gateway")


# ── which apps ──────────────────────────────────────────────────────────────────
def test_only_the_apps_the_domain_has_are_planned(gen, src, state):
    plan = _plan(gen, src, state, [Domain(name="plain.example"),
                                   Domain(name="live.example", optional_services=["owncast"])])
    plain = {r.app for r in _ws(plan, "plain.example").repos}
    live = {r.app for r in _ws(plan, "live.example").repos}
    assert plain == {"hugmesh-gateway", "hugmesh-user-ui"}
    assert live == {"hugmesh-gateway", "hugmesh-user-ui", "hugmesh-owncast-ui",
                    "hugmesh-owncast-bff-api"}
    # a folder outside the source root (tor) and a stock image never get a copy
    assert not any("tor" in r.app or "db" in r.app for r in _ws(plan, "live.example").repos)


def test_making_copies_clones_only_those_apps_from_the_local_build_checkout(
        gen, src, state):
    git = FakeGit()
    plan = _plan(gen, src, state, [Domain(name="plain.example")])
    results = dw.clone_missing(plan, "plain.example", git)
    assert [r.ok for r in results] == [True, True]
    clones = [argv for argv, _cwd in git.calls if argv[0] == "clone"]
    assert len(clones) == 2
    for argv in clones:
        assert argv[:3] == ["clone", "--quiet", "--"]
        assert argv[3].startswith(src + os.sep)               # local, never a URL
        assert "owncast" not in argv[3]
    folder = _ws(plan, "plain.example").folder
    assert sorted(os.listdir(folder)) == ["hugmesh-gateway.plain.example",
                                          "hugmesh-user-ui.plain.example"]


def test_a_copy_is_named_for_its_domain_inside_git_too(gen, src, state):
    git = FakeGit()
    plan = _plan(gen, src, state, [Domain(name="Chat.Example.org")])
    dw.clone_missing(plan, "Chat.Example.org", git)
    dest = os.path.join(plan.root, "chat.example.org", "hugmesh-gateway.chat.example.org")
    steps = [argv for argv, cwd in git.calls if cwd == dest]
    assert steps == [["switch", "-c", "domain/chat.example.org"],
                     ["config", "hugmesh.domain", "Chat.Example.org"],
                     ["config", "hugmesh.app", "hugmesh-gateway"],
                     ["config", "hugmesh.mesh", MESH]]
    with open(os.path.join(dest, ".git", "description")) as fh:
        assert fh.read() == ("hugmesh-gateway.chat.example.org: hugmesh-gateway for the "
                             "domain Chat.Example.org (mesh own.example)\n")
    marker = dw.read_marker(dest)
    assert marker == {"domain": "Chat.Example.org", "slug": "chat.example.org",
                      "app": "hugmesh-gateway", "mesh": MESH,
                      "source": os.path.join(src, "hugmesh-gateway")}
    again = _plan(gen, src, state, [Domain(name="Chat.Example.org")])
    assert {r.app for r in again.domains[0].cloned()} == {"hugmesh-gateway",
                                                          "hugmesh-user-ui"}
    assert again.domains[0].missing() == ()


def test_a_naming_step_that_fails_leaves_the_copy_unmarked(gen, src, state):
    git = FakeGit(fail="switch")
    plan = _plan(gen, src, state, [Domain(name="plain.example")])
    results = dw.clone_missing(plan, "plain.example", git)
    assert not any(r.ok for r in results)
    assert "unmarked" in results[0].message
    again = _plan(gen, src, state, [Domain(name="plain.example")])
    ws = again.domains[0]
    # not ours (no marker): never cloned-over, never offered for removal
    assert ws.cloned() == () and ws.extras == ()
    assert all("was not made by the Studio" in r.reason for r in ws.repos)
    assert len(ws.foreign) == 2


def test_a_missing_build_checkout_is_a_reason_not_a_clone(gen, state, tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    plan = _plan(gen, str(empty), state, [Domain(name="plain.example")])
    ws = plan.domains[0]
    assert ws.missing() == ()
    assert all(r.reason.startswith("the build checkout is not there yet") for r in ws.repos)
    git = FakeGit()
    assert dw.clone_missing(plan, "plain.example", git) == []
    assert git.calls == []


def test_a_copy_is_never_made_inside_a_stack_src(gen, tmp_path):
    src = tmp_path / "gen2" / ".stack-src"
    for name in REPOS:
        (src / name / ".git").mkdir(parents=True)
    plan = dw.plan_workspaces(gen, "existing", str(src), [Domain(name="p.example")], MESH,
                              state_root=str(src / "state"))
    git = FakeGit()
    results = dw.clone_missing(plan, "p.example", git)
    assert results and all(".stack-src" in r.message for r in results)
    assert not [a for a, _ in git.calls if a[0] == "clone"]


# ── links are never followed ────────────────────────────────────────────────────
def test_a_domain_folder_that_is_a_link_gets_no_copy(gen, src, state, tmp_path):
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    root = os.path.join(state, "domain-code", MESH)
    os.makedirs(root)
    os.symlink(elsewhere, os.path.join(root, "plain.example"))
    plan = _plan(gen, src, state, [Domain(name="plain.example")])
    ws = plan.domains[0]
    assert "is a link" in ws.problem
    git = FakeGit()
    assert dw.clone_missing(plan, "plain.example", git) == []
    assert os.listdir(elsewhere) == []


def test_a_mesh_folder_that_is_a_link_stops_everything(gen, src, state, tmp_path):
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    os.makedirs(os.path.join(state, "domain-code"))
    os.symlink(elsewhere, os.path.join(state, "domain-code", MESH))
    plan = _plan(gen, src, state, [Domain(name="plain.example")])
    assert "is a link" in plan.root_problem
    assert all(d.problem for d in plan.domains)


# ── extra folders ───────────────────────────────────────────────────────────────
def _made(gen, src, state, rows, name):
    plan = _plan(gen, src, state, rows)
    assert all(r.ok for r in dw.clone_missing(plan, name, FakeGit()))


def test_unticking_a_service_makes_its_copies_extra_and_nothing_else(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    ws = plan.domains[0]
    assert sorted(x.app for x in ws.extras) == ["hugmesh-owncast-bff-api",
                                                "hugmesh-owncast-ui"]
    assert all(x.why == f"this domain no longer has {x.app}" for x in ws.extras)
    # nothing was removed by planning
    assert len(os.listdir(ws.folder)) == 4


def test_a_folder_without_the_marker_is_never_extra(gen, src, state):
    _made(gen, src, state, [Domain(name="p.example")], "p.example")
    folder = os.path.join(state, "domain-code", MESH, "p.example")
    os.makedirs(os.path.join(folder, "my-notes", ".git"))
    plan = _plan(gen, src, state, [Domain(name="p.example")])
    ws = plan.domains[0]
    assert ws.extras == ()
    assert os.path.join(folder, "my-notes") in ws.foreign


def test_a_link_to_a_marked_copy_is_never_extra(gen, src, state, tmp_path):
    """A link inside a domain folder pointing at a REAL marked copy elsewhere must not
    be offered: removing 'it' would mean following the link."""
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    folder = os.path.join(state, "domain-code", MESH, "live.example")
    target = os.path.join(folder, "hugmesh-owncast-ui.live.example")
    outside = tmp_path / "outside-copy"
    shutil.move(target, outside)
    os.symlink(outside, target)
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    extras = {x.path for x in plan.domains[0].extras}
    assert target not in extras
    assert target in plan.domains[0].foreign


def test_a_marker_is_never_read_through_a_link(gen, src, state, tmp_path):
    _made(gen, src, state, [Domain(name="p.example")], "p.example")
    real = os.path.join(state, "domain-code", MESH, "p.example", "hugmesh-gateway.p.example")
    assert dw.read_marker(real) is not None
    link = tmp_path / "link-to-copy"
    os.symlink(real, link)
    assert dw.read_marker(str(link)) is None


def test_a_copy_whose_git_folder_is_a_link_is_not_ours(gen, src, state, tmp_path):
    """A real folder whose ``.git`` points at a marked copy's git folder elsewhere:
    removing it as 'extra' would trust a marker that lives outside it."""
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    folder = os.path.join(state, "domain-code", MESH, "live.example")
    copy = os.path.join(folder, "hugmesh-owncast-ui.live.example")
    stash = tmp_path / "stash-git"
    shutil.move(os.path.join(copy, ".git"), stash)
    os.symlink(stash, os.path.join(copy, ".git"))
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    assert copy not in {x.path for x in plan.domains[0].extras}
    assert copy in plan.domains[0].foreign


def test_the_folder_of_a_domain_that_left_the_mesh_is_listed_as_extra(gen, src, state):
    _made(gen, src, state, [Domain(name="gone.example")], "gone.example")
    plan = _plan(gen, src, state, [Domain(name="kept.example")])
    gone = [d for d in plan.domains if not d.in_mesh]
    assert len(gone) == 1 and gone[0].name == "gone.example"
    assert len(gone[0].extras) == 2
    assert all(x.why == "gone.example is not a domain of this mesh, and no saved mesh "
               "uses this copy" for x in gone[0].extras)


def test_a_departed_folder_lists_a_copy_marked_for_another_domain_as_left_alone(
        gen, src, state):
    """A copy inside gone.example's folder whose marker names ANOTHER domain is not
    gone.example's copy: it is listed as left alone, never as extra (skeptic S5)."""
    _made(gen, src, state, [Domain(name="gone.example")], "gone.example")
    _made(gen, src, state, [Domain(name="other.example")], "other.example")
    root = os.path.join(state, "domain-code", MESH)
    stray = os.path.join(root, "gone.example", "hugmesh-gateway.other.example")
    shutil.move(os.path.join(root, "other.example", "hugmesh-gateway.other.example"),
                stray)
    plan = _plan(gen, src, state, [Domain(name="kept.example"),
                                   Domain(name="other.example")])
    gone = next(d for d in plan.domains if d.name == "gone.example")
    assert stray not in {x.path for x in plan.extras()}
    assert stray in gone.foreign
    assert len(gone.extras) == 2


# ── another (saved) mesh sharing the copies folder ──────────────────────────────
def _save_record(state, rec_id, label, rows, cluster_domain=""):
    meshes = os.path.join(state, "meshes")
    os.makedirs(meshes, exist_ok=True)
    cfg = {"domains": [{"name": r.name, "optional_services": list(r.optional_services),
                        "idp": "superdomain"} for r in rows]}
    if cluster_domain:
        cfg["cluster_domain"] = cluster_domain
    # the real record shape: a LocalMeshBootstrapConfig dict inside a SavedMesh
    from hugmesh_studio.core import saved_meshes
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    full = LocalMeshBootstrapConfig.from_dict(cfg).to_dict()
    rec = saved_meshes.SavedMesh(id=rec_id, label=label, config=full)
    with open(os.path.join(meshes, rec_id + ".json"), "w") as fh:
        json.dump(rec.to_dict(), fh)


def test_a_departed_domain_that_a_saved_mesh_still_has_is_never_extra(gen, src, state):
    """The skeptic's two-mesh probe: mesh A (saved) has chat.example.org; mesh B, with
    the same own name, must not offer A's copies for removal."""
    _made(gen, src, state, [Domain(name="chat.example.org")], "chat.example.org")
    _save_record(state, "20261021-100000-aaaaaa", "Mesh A",
                 [Domain(name=MESH), Domain(name="chat.example.org")],
                 cluster_domain=MESH)
    plan = _plan(gen, src, state, [Domain(name=MESH), Domain(name="shop.example.org")])
    gone = next(d for d in plan.domains if d.name == "chat.example.org")
    assert not gone.in_mesh
    assert gone.extras == () and plan.extras() == ()
    assert sorted(x.app for x in gone.claimed) == ["hugmesh-gateway", "hugmesh-user-ui"]
    assert all(x.why == "the saved mesh ‘Mesh A’ still uses it" for x in gone.claimed)
    # and removal refuses it even when handed the folder directly
    res = dw.remove_extra(gone.claimed[0], plan, FakeGit())
    assert not res.removed and os.path.isdir(gone.claimed[0].path)


def test_an_unticked_service_that_a_saved_mesh_still_has_is_kept(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    _save_record(state, "20261021-100000-bbbbbb", "Mesh A",
                 [Domain(name="live.example", optional_services=["owncast"])])
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    ws = plan.domains[0]
    assert ws.extras == ()
    assert sorted(x.app for x in ws.claimed) == ["hugmesh-owncast-bff-api",
                                                 "hugmesh-owncast-ui"]


def test_the_record_this_mesh_was_loaded_from_claims_nothing(gen, src, state):
    """Its saved copy is stale by definition once the person un-ticks a service."""
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    rid = "20261021-100000-cccccc"
    _save_record(state, rid, "This mesh",
                 [Domain(name="live.example", optional_services=["owncast"])])
    plan = dw.plan_workspaces(gen, "existing", src, [Domain(name="live.example")], MESH,
                              state_root=state, record_id=rid)
    assert len(plan.domains[0].extras) == 2 and plan.domains[0].claimed == ()


def test_a_corrupt_or_linked_record_claims_nothing_and_breaks_nothing(
        gen, src, state, tmp_path):
    _made(gen, src, state, [Domain(name="gone.example")], "gone.example")
    meshes = os.path.join(state, "meshes")
    os.makedirs(meshes)
    with open(os.path.join(meshes, "bad.json"), "w") as fh:
        fh.write("{not json")
    outside = tmp_path / "x.json"
    outside.write_text(json.dumps({"id": "x", "label": "L",
                                   "config": {"domains": [{"name": "gone.example"}]}}))
    os.symlink(outside, os.path.join(meshes, "x.json"))
    plan = _plan(gen, src, state, [Domain(name="kept.example")])
    gone = next(d for d in plan.domains if not d.in_mesh)
    assert len(gone.extras) == 2 and gone.claimed == ()


def test_the_saved_meshes_are_not_read_when_nothing_could_be_extra(
        gen, src, state, monkeypatch):
    calls = []
    monkeypatch.setattr(dw, "saved_mesh_claims", lambda *a, **k: calls.append(1) or {})
    _made(gen, src, state, [Domain(name="live.example")], "live.example")
    _plan(gen, src, state, [Domain(name="live.example")])
    assert calls == []


# ── removal ─────────────────────────────────────────────────────────────────────
def test_remove_takes_a_clean_extra_copy(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    for x in plan.extras():
        res = dw.remove_extra(x, plan, FakeGit())
        assert res.removed, res.message
        assert not os.path.exists(x.path)
    left = os.listdir(plan.domains[0].folder)
    assert sorted(left) == ["hugmesh-gateway.live.example", "hugmesh-user-ui.live.example"]


def test_remove_keeps_a_copy_with_edits_or_commits_of_its_own(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    a, b = sorted(plan.extras(), key=lambda x: x.path)
    git = FakeGit(dirty={a.path: 2}, unpushed={b.path: 1})
    ra, rb = dw.remove_extra(a, plan, git), dw.remove_extra(b, plan, git)
    assert not ra.removed and "2 changed files" in ra.message
    assert not rb.removed and "1 commit found nowhere else" in rb.message
    assert os.path.isdir(a.path) and os.path.isdir(b.path)


@pytest.mark.parametrize("kind,words", [
    ("unpushed", "1 commit found nowhere else (on any of its branches or tags)"),
    ("stashed", "1 stashed change"),
    ("ignored", "1 ignored file or folder (such as a .env or build output)"),
    ("worktrees", "1 other working tree made from it"),
])
def test_remove_keeps_a_copy_with_any_other_kind_of_work(gen, src, state, kind, words):
    """The skeptic's case (2026-10-21): work on ANOTHER branch, in the stash or in an
    ignored ``.env`` used to read "no edits of its own" and was removed."""
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    x = plan.extras()[0]
    git = FakeGit(**{kind: {x.path: 1}})
    st = dw.extra_status(x.path, git)
    assert not st.safe_to_remove
    assert st.words() == f"holds {words} — it will be kept"
    res = dw.remove_extra(x, plan, git)
    assert not res.removed and words in res.message
    assert os.path.isdir(x.path)


def test_a_plain_copy_says_so_in_words_that_name_every_check(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    st = dw.extra_status(plan.extras()[0].path, FakeGit())
    assert st.safe_to_remove
    assert st.words() == ("a plain copy: no edits, commits, stashes or ignored files "
                          "of its own")


@pytest.mark.parametrize("sub", ["status", "rev-list", "stash", "worktree"])
def test_a_check_that_cannot_run_keeps_the_copy(gen, src, state, sub):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    x = plan.extras()[0]
    res = dw.remove_extra(x, plan, FakeGit(fail=sub))
    assert not res.removed and "cannot be checked" in res.message
    assert os.path.isdir(x.path)


def test_remove_refuses_a_folder_that_is_no_longer_extra(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    old = _plan(gen, src, state, [Domain(name="live.example")])
    x = old.extras()[0]
    fresh = _plan(gen, src, state, [Domain(name="live.example",
                                           optional_services=["owncast"])])
    res = dw.remove_extra(x, fresh, FakeGit())
    assert not res.removed and "no longer an extra" in res.message
    assert os.path.isdir(x.path)


def test_remove_refuses_when_the_marker_was_taken_away(gen, src, state):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    x = plan.extras()[0]
    os.remove(os.path.join(x.path, ".git", dw.MARKER))
    res = dw.remove_extra(x, plan, FakeGit())
    assert not res.removed and "not a copy the Studio made" in res.message
    assert os.path.isdir(x.path)


def test_remove_never_follows_a_link_put_in_place_after_planning(gen, src, state, tmp_path):
    _made(gen, src, state, [Domain(name="live.example", optional_services=["owncast"])],
          "live.example")
    plan = _plan(gen, src, state, [Domain(name="live.example")])
    x = plan.extras()[0]
    precious = tmp_path / "precious"
    shutil.copytree(x.path, precious)            # carries a valid marker too
    shutil.rmtree(x.path)
    os.symlink(precious, x.path)
    res = dw.remove_extra(x, plan, FakeGit())
    assert not res.removed
    assert os.path.isdir(precious) and os.listdir(precious)


def test_the_last_copy_of_a_departed_domain_takes_its_empty_folder_with_it(
        gen, src, state):
    _made(gen, src, state, [Domain(name="gone.example")], "gone.example")
    plan = _plan(gen, src, state, [Domain(name="kept.example")])
    gone = next(d for d in plan.domains if not d.in_mesh)
    for x in gone.extras:
        assert dw.remove_extra(x, plan, FakeGit()).removed
    assert not os.path.exists(gone.folder)


# ── the real git, once ──────────────────────────────────────────────────────────
@pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")
def test_with_the_real_git_a_copy_is_a_named_clone_and_local_commits_keep_it(
        gen, tmp_path, state):
    src = tmp_path / "real-src"
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
    for name in REPOS:
        p = src / name
        p.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(p)], check=True, env=env)
        (p / "README").write_text(name)
        subprocess.run(["git", "-C", str(p), "add", "README"], check=True, env=env)
        subprocess.run(["git", "-C", str(p), "commit", "-qm", "init"], check=True, env=env)
    rows = [Domain(name="live.example", optional_services=["owncast"])]
    plan = dw.plan_workspaces(gen, "existing", str(src), rows, MESH, state_root=state)
    results = dw.clone_missing(plan, "live.example")
    assert [r.ok for r in results] == [True] * 4, [r.message for r in results]
    dest = os.path.join(plan.root, "live.example", "hugmesh-owncast-ui.live.example")
    branch = subprocess.run(["git", "-C", dest, "branch", "--show-current"],
                            capture_output=True, text=True, check=True).stdout.strip()
    assert branch == "domain/live.example"
    cfg = subprocess.run(["git", "-C", dest, "config", "hugmesh.domain"],
                         capture_output=True, text=True, check=True).stdout.strip()
    assert cfg == "live.example"
    assert subprocess.run(["git", "-C", dest, "status", "--porcelain"],
                          capture_output=True, text=True).stdout == ""   # marker unseen
    # a local commit in one extra copy keeps it; the clean one goes
    (tmp_path / "x").write_text("")
    with open(os.path.join(dest, "NEW"), "w") as fh:
        fh.write("mine")
    subprocess.run(["git", "-C", dest, "add", "NEW"], check=True, env=env)
    subprocess.run(["git", "-C", dest, "commit", "-qm", "mine"], check=True, env=env)
    plan = dw.plan_workspaces(gen, "existing", str(src), [Domain(name="live.example")],
                              MESH, state_root=state)
    out = {os.path.basename(x.path): dw.remove_extra(x, plan) for x in plan.extras()}
    assert not out["hugmesh-owncast-ui.live.example"].removed
    assert "1 commit found nowhere else" in out["hugmesh-owncast-ui.live.example"].message
    assert out["hugmesh-owncast-bff-api.live.example"].removed
    with open(os.path.join(dest, ".git", dw.MARKER)) as fh:
        assert json.load(fh)["app"] == "hugmesh-owncast-ui"


@pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")
@pytest.mark.parametrize("scenario,words", [
    ("other-branch", "1 commit found nowhere else"),
    ("tag", "1 commit found nowhere else"),
    ("stash", "holds 1 stashed change — it will be kept"),
    ("ignored-file", "1 ignored file or folder"),
    ("linked-worktree", "1 other working tree made from it"),
    ("plain", ""),
])
def test_with_the_real_git_every_kind_of_local_work_keeps_a_copy(
        gen, tmp_path, state, scenario, words):
    """The skeptic's probe (2026-10-21, probe_loss.py) as a test, against the real git:
    each kind of work a person can leave in a copy keeps it, and the words the screen
    shows before the second click say which; only a plain clone is removed."""
    src = tmp_path / "real-src"
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")

    def git(*argv):
        subprocess.run(["git", *argv], check=True, env=env, capture_output=True)

    for name in REPOS:
        p = src / name
        p.mkdir(parents=True)
        git("init", "-q", str(p))
        (p / "README").write_text(name)
        (p / ".gitignore").write_text(".env\n")
        git("-C", str(p), "add", "README", ".gitignore")
        git("-C", str(p), "commit", "-qm", "init")
    rows = [Domain(name="live.example", optional_services=["owncast"])]
    plan = dw.plan_workspaces(gen, "existing", str(src), rows, MESH, state_root=state)
    assert all(r.ok for r in dw.clone_missing(plan, "live.example"))
    dest = os.path.join(plan.root, "live.example", "hugmesh-owncast-ui.live.example")
    if scenario == "other-branch":
        git("-C", dest, "switch", "-qc", "my-feature")
        with open(os.path.join(dest, "WORK"), "w") as fh:
            fh.write("precious")
        git("-C", dest, "add", "WORK")
        git("-C", dest, "commit", "-qm", "precious work")
        git("-C", dest, "switch", "-q", "domain/live.example")
    elif scenario == "tag":
        git("-C", dest, "switch", "-q", "--detach")
        with open(os.path.join(dest, "WORK"), "w") as fh:
            fh.write("precious")
        git("-C", dest, "add", "WORK")
        git("-C", dest, "commit", "-qm", "precious work")
        git("-C", dest, "tag", "keep-me")
        git("-C", dest, "switch", "-q", "domain/live.example")
    elif scenario == "stash":
        with open(os.path.join(dest, "README"), "a") as fh:
            fh.write("precious edit")
        git("-C", dest, "stash", "-q")
    elif scenario == "ignored-file":
        with open(os.path.join(dest, ".env"), "w") as fh:
            fh.write("SECRET=precious")
    elif scenario == "linked-worktree":
        git("-C", dest, "worktree", "add", "-q", "--detach", str(tmp_path / "linked"))
    # the checked-out branch itself is clean in every scenario
    assert subprocess.run(["git", "-C", dest, "status", "--porcelain"],
                          capture_output=True, text=True).stdout == ""
    plan = dw.plan_workspaces(gen, "existing", str(src), [Domain(name="live.example")],
                              MESH, state_root=state)
    x = next(x for x in plan.extras() if x.path == dest)
    st = dw.extra_status(dest)
    res = dw.remove_extra(x, plan)
    if scenario == "plain":
        assert st.safe_to_remove and res.removed and not os.path.exists(dest)
    else:
        assert words in st.words() and st.words().endswith("it will be kept")
        assert not res.removed and os.path.isdir(dest)
