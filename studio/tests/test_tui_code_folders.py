"""tui — the per-domain code copies on the Local Docker mesh route (operator ask
2026-10-21), the text twin of the GUI block's copies part. Same core, so the same
folders; same two-step removal ("r N" lists and arms, "yes" removes, anything else
keeps). Headless and Qt-free, with a fake git."""
import json
import os

import pytest

from hugmesh_studio.tui import journey, localmesh

COMPOSE = """\
services:
  hugmesh-fe-gateway:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-gateway
  hugmesh-owncast-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-owncast-ui
"""


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


class FakeGit:
    def __init__(self):
        self.clones = []
        self.dirty = {}
        self.stashed = {}

    def __call__(self, argv, cwd):
        if argv[0] == "clone":
            self.clones.append(argv[argv.index("--") + 1])
            os.makedirs(os.path.join(argv[-1], ".git"))
        if argv[0] == "status":
            return 0, "\n".join(" M f" for _ in range(self.dirty.get(cwd, 0)))
        if argv[0] == "rev-list":
            return 0, "0"
        if argv[:2] == ["stash", "list"]:
            return 0, "\n".join("stash@{0}: WIP" for _ in range(self.stashed.get(cwd, 0)))
        return 0, ""


@pytest.fixture
def at_folders(tmp_path):
    gen = tmp_path / "gen"
    (gen / "tests" / "stack").mkdir(parents=True)
    (gen / "tests" / "stack" / "compose.local.yaml").write_text(COMPOSE)
    src = tmp_path / "src"
    for name in ("hugmesh-gateway", "hugmesh-owncast-ui"):
        (src / name / ".git").mkdir(parents=True)
    j = journey.Journey(str(gen))
    j.feed("")                     # welcome -> mode
    j.feed("1")                    # Local Docker mesh
    j.feed("2")                    # Generate a new mesh
    j.feed("a live.example")
    j.localmesh_domains.domains[1].optional_services = ["owncast"]
    j.feed("")                     # -> services
    j.feed("")                     # -> review (refused: copies do not need the gate)
    screen = j.screen_for("localmesh")
    assert screen.stage == "review"
    assert "f=code copies for each domain" in "\n".join(j.lines())
    j.feed("f")
    assert screen.stage == "folders"
    git = FakeGit()
    screen.folders.runner = git
    j.feed(f"src {src}")
    return j, screen, git, str(src)


def _text(j):
    return "\n".join(j.lines())


def test_the_screen_lists_each_domain_and_makes_only_its_apps(at_folders):
    j, screen, git, src = at_folders
    text = _text(j)
    own = j.localmesh_domains.own_name
    assert f"1. {own} — 0 of 1 copies made, 1 to make" in text
    assert "2. live.example — 0 of 2 copies made, 2 to make" in text
    j.feed("m all")
    assert sorted(git.clones) == sorted([os.path.join(src, "hugmesh-gateway"),
                                         os.path.join(src, "hugmesh-gateway"),
                                         os.path.join(src, "hugmesh-owncast-ui")])
    text = _text(j)
    assert "2. live.example — 2 of 2 copies made" in text
    root = screen.folders.plan(j).root
    assert sorted(os.listdir(os.path.join(root, "live.example"))) == [
        "hugmesh-gateway.live.example", "hugmesh-owncast-ui.live.example"]
    assert os.listdir(os.path.join(root, own)) == [f"hugmesh-gateway.{own}"]


def test_removal_takes_r_then_yes_and_anything_else_keeps(at_folders):
    j, screen, git, _src = at_folders
    j.feed("m 2")
    j.localmesh_domains.domains[1].optional_services = []
    text = _text(j)
    assert "EXTRA hugmesh-owncast-ui.live.example: this domain no longer has " \
           "hugmesh-owncast-ui" in text
    extra = os.path.join(screen.folders.plan(j).root, "live.example",
                         "hugmesh-owncast-ui.live.example")
    j.feed("r 2")
    assert "ARMED: removing 1 folder(s) of live.example" in _text(j)
    assert os.path.isdir(extra)
    j.feed("m 1")                  # any other command disarms
    assert screen.folders.armed is None
    j.feed("yes")
    assert os.path.isdir(extra) and "nothing is armed" in j.status
    j.feed("r 2")
    j.feed("yes")
    assert not os.path.exists(extra)
    assert "hugmesh-owncast-ui.live.example: removed" in _text(j)


def test_a_copy_with_edits_is_never_armed(at_folders):
    j, screen, git, _src = at_folders
    j.feed("m 2")
    j.localmesh_domains.domains[1].optional_services = []
    extra = os.path.join(screen.folders.plan(j).root, "live.example",
                         "hugmesh-owncast-ui.live.example")
    git.dirty[extra] = 1
    j.feed("r 2")
    assert screen.folders.armed is None
    assert "holds 1 changed file — it will be kept" in _text(j)
    j.feed("yes")
    assert os.path.isdir(extra)


def test_the_last_outcome_and_an_arm_go_when_the_services_change(at_folders):
    """Round 2 (2026-10-21): the same rule as the window's note — what the last
    command did is about the mesh as it was; once a domain's services change it is
    dropped, and so is an armed removal (a ``yes`` then removes nothing)."""
    j, screen, git, _src = at_folders
    j.feed("m 2")
    assert "live.example: made 2 of 2 copies" in _text(j)
    assert "live.example: made 2 of 2 copies" in _text(j)        # a re-read keeps it
    j.localmesh_domains.domains[1].optional_services = []
    assert "made 2 of 2 copies" not in _text(j)
    j.feed("r 2")
    assert "ARMED" in _text(j)
    j.localmesh_domains.domains[1].optional_services = ["owncast"]
    assert "ARMED" not in _text(j) and screen.folders.armed is None
    j.feed("yes")
    assert "nothing is armed" in j.status


def test_the_screen_says_each_copys_remote_is_named_for_its_domain(at_folders):
    j, _screen, _git, _src = at_folders
    assert "Each copy's git remote is named for its domain" in _text(j)


def test_b_goes_back_to_the_review(at_folders):
    j, screen, _git, _src = at_folders
    j.feed("b")
    assert screen.stage == "review"


def test_a_stashed_change_keeps_a_copy_in_the_same_words_as_the_window(at_folders):
    """The skeptic's blocker: a stash used to read "no edits of its own"."""
    j, screen, git, _src = at_folders
    j.feed("m 2")
    j.localmesh_domains.domains[1].optional_services = []
    extra = os.path.join(screen.folders.plan(j).root, "live.example",
                         "hugmesh-owncast-ui.live.example")
    git.stashed[extra] = 1
    j.feed("r 2")
    assert screen.folders.armed is None
    assert ("hugmesh-owncast-ui.live.example: holds 1 stashed change — it will be kept"
            in _text(j))
    j.feed("yes")
    assert os.path.isdir(extra)


def test_another_saved_meshs_domain_is_listed_kept_and_cannot_be_armed(at_folders):
    from hugmesh_studio.core import saved_meshes
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    j, screen, git, _src = at_folders
    j.feed("m 2")
    rec = saved_meshes.SavedMesh(
        id="20261021-120000-aaaaaa", label="Mesh A",
        config=LocalMeshBootstrapConfig.from_dict({"domains": [
            {"name": "live.example", "optional_services": ["owncast"],
             "idp": "superdomain"}]}).to_dict())
    os.makedirs(saved_meshes.meshes_dir(), exist_ok=True)
    with open(rec.path(), "w") as fh:
        json.dump(rec.to_dict(), fh)
    del j.localmesh_domains.domains[1]          # this mesh drops live.example
    text = _text(j)
    assert "live.example — not a domain of this mesh" in text
    assert ("kept hugmesh-owncast-ui.live.example: the saved mesh ‘Mesh A’ still uses "
            "it") in text
    assert "EXTRA" not in text
    assert "a mesh that was never saved cannot be checked" in text
    n = next(i for i, ws in enumerate(screen.folders.plan(j).domains, 1)
             if ws.name == "live.example")
    j.feed(f"r {n}")
    assert screen.folders.armed is None and "no extra copies" in j.status
