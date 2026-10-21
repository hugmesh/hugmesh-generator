"""tui — the per-domain code copies on the Local Docker mesh route (operator ask
2026-10-21), the text twin of the GUI block's copies part. Same core, so the same
folders; same two-step removal ("r N" lists and arms, "yes" removes, anything else
keeps). Headless and Qt-free, with a fake git."""
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

    def __call__(self, argv, cwd):
        if argv[0] == "clone":
            self.clones.append(argv[3])
            os.makedirs(os.path.join(argv[-1], ".git"))
        if argv[0] == "status":
            return 0, "\n".join(" M f" for _ in range(self.dirty.get(cwd, 0)))
        if argv[0] == "rev-list":
            return 0, "0"
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


def test_b_goes_back_to_the_review(at_folders):
    j, screen, _git, _src = at_folders
    j.feed("b")
    assert screen.stage == "review"
