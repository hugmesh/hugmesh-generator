"""Every agent the local assistant starts gets the project context (core/agent_context.py).

Pinned here:

* the text says what the hugmesh org and its repositories are, what the Studio is, and
  WHERE the local sources are: the checkouts folder (a setting), the generator checkout,
  the folder the mesh builds from and each domain's code folders;
* the checkouts folder is the setting, else $HUGMESH_REPOS_ROOT, else the folder that
  holds the generator checkout — never a user path written into the code;
* the agent launcher writes the file FRESH at every start, next to the brief, and the
  brief points at it and carries it inline;
* the queue worker's agents get it too (scripts/local-ai/draft.py reads the file the
  Studio names in $HUGMESH_AGENT_CONTEXT).
"""
import importlib.util
import os
import re
import subprocess
import sys

import pytest

from hugmesh_studio.core import agent_context as actx
from hugmesh_studio.core import assistant_settings
from hugmesh_studio.core import local_agent as la
from hugmesh_studio.core.config import Domain

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _git_repo(path):
    path.mkdir(parents=True)
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    for args in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "m"]):
        subprocess.run(["git", *args], cwd=path, check=True, capture_output=True, env=env)
    return str(path)


@pytest.fixture
def checkouts(tmp_path):
    root = tmp_path / "src"
    for name in ("hugmesh-user-ui", "hugmesh-user-bff-api", "hugmesh-gateway", "hugmesh-generator"):
        _git_repo(root / name)
    (root / "hugmesh-not-a-repo").mkdir()
    (root / "other-project").mkdir()
    return str(root)


def test_the_checkouts_folder_is_the_setting_else_the_env_else_beside_the_generator(
        tmp_path, monkeypatch):
    monkeypatch.delenv(actx.REPOS_ROOT_ENV, raising=False)
    gen = str(tmp_path / "anywhere" / "hugmesh-generator")
    assert actx.checkouts_dir(gen, {}, {}) == str(tmp_path / "anywhere")
    assert actx.checkouts_dir(gen, {actx.REPOS_ROOT_ENV: str(tmp_path / "env")}, {}) == \
        str(tmp_path / "env")
    assert actx.checkouts_dir(gen, {actx.REPOS_ROOT_ENV: str(tmp_path / "env")},
                              {"checkouts_dir": str(tmp_path / "set")}) == str(tmp_path / "set")
    # and through the real settings file
    assistant_settings.update(checkouts_dir=str(tmp_path / "saved"))
    assert actx.checkouts_dir(gen, {}) == str(tmp_path / "saved")


def test_only_hugmesh_git_checkouts_are_listed_with_what_each_is(checkouts):
    found = actx.list_checkouts(checkouts)
    assert [c.name for c in found] == ["hugmesh-gateway", "hugmesh-generator",
                                       "hugmesh-user-bff-api", "hugmesh-user-ui"]
    assert "web UI" in actx.role_of("hugmesh-user-ui")
    assert "backend-for-frontend" in actx.role_of("hugmesh-user-bff-api")
    assert "gateway" in actx.role_of("hugmesh-gateway")
    assert "Studio" in actx.role_of("hugmesh-generator")


def test_the_context_says_what_the_project_is_and_where_every_source_is(checkouts, tmp_path):
    rows = [Domain(name="alpha.mesh.example", optional_services=["phpbb"]),
            Domain(name="beta.mesh.example")]
    text = actx.context_for(GENERATOR_DIR, source_mode="existing", source_dir=checkouts,
                            rows=rows, mesh="alpha.mesh.example", ollama="In use: x",
                            settings={"checkouts_dir": checkouts})
    for words in ("GitHub org `hugmesh`", "## The Studio", "hugmesh_studio/gui",
                  "## Where the local sources are", f"The person's checkouts: `{checkouts}`",
                  f"The generator checkout the Studio runs from: `{os.path.abspath(GENERATOR_DIR)}`",
                  f"The folder this mesh builds from: `{checkouts}`",
                  "### Code folders per domain of the mesh alpha.mesh.example",
                  "Domain `alpha.mesh.example`", "Domain `beta.mesh.example`",
                  os.path.join(checkouts, "hugmesh-user-ui"), "In use: x",
                  "LOCAL-AI-ASSISTANT.md"):
        assert words in text, words
    # phpbb's forum folder appears under the domain that chose it, not the other
    alpha = text.split("Domain `alpha.mesh.example`")[1].split("Domain `beta")[0]
    beta = text.split("Domain `beta.mesh.example`")[1]
    assert "hugmesh-forum-api" in alpha and "hugmesh-forum-api" not in beta.split("## Rules")[0]


def test_a_map_that_cannot_be_read_is_said_not_guessed(monkeypatch, tmp_path):
    from hugmesh_studio.core import code_folders
    monkeypatch.setattr(code_folders, "code_folder_map",
                        lambda *a, **k: (_ for _ in ()).throw(OSError("disk on fire")))
    text = actx.context_for(GENERATOR_DIR, rows=[Domain(name="a.mesh.example")],
                            settings={"checkouts_dir": str(tmp_path)})
    assert "could not be read (OSError: disk on fire)" in text
    assert "No `hugmesh*` git checkout was found" in text


def test_no_user_path_is_written_into_the_code():
    """The checkouts path comes from a setting or the environment, never a literal."""
    here = os.path.join(STUDIO_ROOT, "hugmesh_studio")
    for rel in ("core/agent_context.py", "core/ollama_docker.py", "core/assistant_settings.py",
                "gui/_local_ai_dock.py"):
        src = open(os.path.join(here, rel), encoding="utf-8").read()
        assert not re.search(r"/home/[a-z]", src), rel


def test_the_launcher_writes_the_context_fresh_beside_the_brief_and_points_at_it(tmp_path):
    src = _git_repo(tmp_path / "src" / "hugmesh-x")
    pr = la.Probe(ollama_path="/usr/bin/ollama", server_up=True,
                  models=(la.ModelInfo("qwen3:8b", True),), agents={"claude": "/usr/bin/claude"})
    plans = []
    for n in (1, 2):
        plan = la.prepare(lane=la.LANE_DOCKER, mesh="m", domains=["m"], doors=[],
                          repo="hugmesh-x", source=src, source_root=str(tmp_path / "src"),
                          source_mode="existing", generator_dir=GENERATOR_DIR, pr=pr,
                          state_root=str(tmp_path / "state"),
                          context_text=f"# context number {n}\n- sources: here\n")
        la.write_brief(plan)
        plans.append(plan)
        assert plan.context_path == os.path.join(os.path.dirname(plan.scratch.brief_path),
                                                 la.CONTEXT_FILE)
        assert open(plan.context_path, encoding="utf-8").read() == \
            f"# context number {n}\n- sources: here\n", "not written fresh"
        brief = open(plan.scratch.brief_path, encoding="utf-8").read()
        assert f"Read {plan.context_path} first" in brief
        assert f"> # context number {n}" in brief, "the context is not inline in the brief"
        assert brief.index("Project context") < brief.index("\nRules")
    # with no context the brief is exactly as before: no pointer, no file
    bare = la.prepare(lane=la.LANE_DOCKER, mesh="m", domains=["m"], doors=[], repo="hugmesh-x",
                      source=src, source_root=str(tmp_path / "src"), source_mode="existing",
                      generator_dir=GENERATOR_DIR, pr=pr, state_root=str(tmp_path / "s2"))
    assert bare.context_path == "" and "Project context" not in bare.brief


def _draft_module():
    path = os.path.join(GENERATOR_DIR, "scripts", "local-ai", "draft.py")
    spec = importlib.util.spec_from_file_location("hugmesh_local_ai_draft", path)
    mod = importlib.util.module_from_spec(spec)
    saved = sys.dont_write_bytecode
    sys.dont_write_bytecode = True       # no __pycache__ left inside scripts/local-ai
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = saved
    return mod


def test_the_queue_workers_agents_get_the_same_context(tmp_path):
    draft = _draft_module()
    ctx = tmp_path / "HUGMESH-CONTEXT.md"
    ctx.write_text("# HugMesh: project context\n- checkouts here\n")
    text = draft.agent_context({draft.CONTEXT_ENV: str(ctx)})
    assert text.startswith("PROJECT CONTEXT") and "checkouts here" in text and str(ctx) in text
    assert draft.agent_context({}) == ""
    assert draft.agent_context({draft.CONTEXT_ENV: str(tmp_path / "missing")}) == ""
    sh = open(os.path.join(GENERATOR_DIR, "scripts", "local-ai", "draft.sh"),
              encoding="utf-8").read()
    assert 'HUGMESH_AGENT_CONTEXT="${HUGMESH_AGENT_CONTEXT:-}"' in sh, \
        "draft.sh's env -i line drops the context variable"
    src = open(os.path.join(GENERATOR_DIR, "scripts", "local-ai", "draft.py"),
               encoding="utf-8").read()
    assert src.count("agent_context() + BRIEF") == 2, "an agent mode starts without context"
