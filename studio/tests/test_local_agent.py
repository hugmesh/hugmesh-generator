"""The Qt-free half of "Work on this mesh with a local AI agent" (issue #695).

Pinned here, each with the production line it guards (the mutation list is in the
lane notes, and every one was broken once to watch its test fail):

* PROBE: every missing-prerequisite state reads as its own plain-words problem, in the
  order a person fixes them; only GET /api/tags and POST /api/show are ever sent; a
  server that lists capabilities needs no /api/show; cloud models are never offered;
  OLLAMA_HOST is honoured only when it points at this machine.
* PLAN: the defaults per lane, the argv, the brief (which must carry every "never run"
  item of docs/LOCAL-AI-ASSISTANT.md), and NO auto-approve flag anywhere.
* ENVIRONMENT: an allowlist. Tokens are absent from build_env, from the command line
  the terminal runs, and — run for real through bash with a token in the parent — from
  the process that `ollama launch` becomes.
* SCRATCH CLONE: real git, real directories. No remote, a fresh branch, no hardlinks
  back to the source, works from a detached HEAD, refuses a folder that is not a
  repository, reuses only a clean untouched copy and otherwise numbers a new one.
* TERMINAL: the injected host proves which terminal is chosen, that a refusal falls
  through to the next, that no desktop / Windows / macOS gets the command to paste,
  and that the paste text never carries a token.
"""
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys

import pytest

from hugmesh_studio.core import local_agent as la

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
DOC = os.path.join(GENERATOR_DIR, "docs", "LOCAL-AI-ASSISTANT.md")

TOKEN_NAMES = ("GH_TOKEN", "GITHUB_TOKEN", "GITLAB_TOKEN", "NPM_TOKEN", "DOCKER_PASSWORD",
               "REGISTRY_TOKEN", "AWS_SECRET_ACCESS_KEY", "AWS_ACCESS_KEY_ID",
               "GOOGLE_APPLICATION_CREDENTIALS", "ANTHROPIC_API_KEY", "HF_TOKEN",
               "SSH_AUTH_SOCK", "ARGOCD_AUTH_TOKEN", "ARGOCD_SERVER", "ARGOCD_OPTS",
               "KUBECONFIG", "VAULT_TOKEN", "CASDOOR_CLIENT_SECRET")
SECRET = "s3cr3t-value-that-must-never-appear"


# ── helpers ──────────────────────────────────────────────────────────────────────
def tools_entry(name, caps=("completion", "tools"), **extra):
    e = {"name": name, "model": name, "size": 5_000_000_000}
    if caps is not None:
        e["capabilities"] = list(caps)
    e.update(extra)
    return e


class FakeServer:
    """A fake Ollama: answers by (method, path). Records every request."""

    def __init__(self, entries=None, show=None, down=None, tags_status=200,
                 tags_body=None):
        self.entries = entries if entries is not None else []
        self.show = show or {}
        self.down = down
        self.tags_status = tags_status
        self.tags_body = tags_body
        self.calls = []

    def __call__(self, method, url, body=None, timeout=2.0):
        self.calls.append((method, url, body))
        if self.down is not None:
            raise self.down
        path = url.split("/", 3)[3]
        if method == "GET" and path == "api/tags":
            raw = self.tags_body if self.tags_body is not None \
                else json.dumps({"models": self.entries}).encode()
            return self.tags_status, raw
        if method == "POST" and path == "api/show":
            caps = self.show.get(body["model"])
            if caps is None:
                return 404, b"{}"
            return 200, json.dumps({"capabilities": caps}).encode()
        raise AssertionError(f"the probe sent {method} {url}")


ENV = {"PATH": "/usr/bin", "HOME": "/home/x"}


def which_all(cmds):
    return lambda c, **_k: f"/usr/bin/{c}" if c in cmds else None


def good_probe(models=("qwen3:8b",), agents=("claude",), **kw):
    return la.Probe(
        ollama_path="/usr/bin/ollama", server="127.0.0.1:11434", server_up=True,
        models=tuple(la.ModelInfo(m, True) for m in models),
        agents={a: ("/usr/bin/" + a if a in agents else "") for a in la.AGENTS}, **kw)


def run_git(*args, cwd=None):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    p = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout.strip()


@pytest.fixture
def source(tmp_path):
    """A real repository with two commits on main."""
    src = tmp_path / "src" / "hugmesh-user-bff-api"
    src.mkdir(parents=True)
    run_git("init", "-q", "-b", "main", cwd=src)
    (src / "a.txt").write_text("one\n")
    run_git("add", "a.txt", cwd=src)
    run_git("commit", "-q", "-m", "one", cwd=src)
    (src / "b.txt").write_text("two\n")
    run_git("add", "b.txt", cwd=src)
    run_git("commit", "-q", "-m", "two", cwd=src)
    return str(src)


@pytest.fixture
def state(tmp_path):
    return str(tmp_path / "state")


def plan_for(source, state, *, lane=la.LANE_DOCKER, pr=None, repo="hugmesh-user-bff-api",
             environ=None, **kw):
    return la.prepare(
        lane=lane, mesh="demo mesh", domains=["hugmesh.net", "chat.example.org"],
        doors=["http://localhost:8088"], repo=repo, source=source,
        source_root=os.path.dirname(source), source_mode="existing",
        generator_dir=GENERATOR_DIR, pr=pr or good_probe(), environ=environ or ENV,
        state_root=state, kind_cluster="hugmesh-local", **kw)


# ── the server address ───────────────────────────────────────────────────────────
@pytest.mark.parametrize("value,expect", [
    ("", ("127.0.0.1", 11434)), ("127.0.0.1:11434", ("127.0.0.1", 11434)),
    ("localhost", ("localhost", 11434)), ("localhost:9999", ("localhost", 9999)),
    ("http://127.0.0.1:1234", ("127.0.0.1", 1234)), ("[::1]:5555", ("::1", 5555)),
    (":11434", ("127.0.0.1", 11434)), ("127.9.9.9:80", ("127.9.9.9", 80)),
])
def test_a_loopback_ollama_host_is_honoured(value, expect):
    host, port, note = la.ollama_target({"OLLAMA_HOST": value})
    assert (host, port) == expect and note == ""


@pytest.mark.parametrize("value", ["0.0.0.0:11434", "192.168.1.5:11434", "gpu.example.org",
                                   "https://ai.hugmesh.net:443", "10.0.0.1", "8.8.8.8:1"])
def test_a_host_that_is_not_this_machine_is_ignored_and_says_so(value):
    host, port, note = la.ollama_target({"OLLAMA_HOST": value})
    assert (host, port) == ("127.0.0.1", 11434)
    assert value in note and "ignored" in note
    # and the probe never sends a request to it
    fake = FakeServer([tools_entry("qwen3:8b")])
    la.probe({"OLLAMA_HOST": value, "PATH": "/usr/bin"}, which=which_all({"ollama"}),
             fetch=fake)
    assert fake.calls and all(c[1].startswith("http://127.0.0.1:11434/") for c in fake.calls)


# ── probe states ─────────────────────────────────────────────────────────────────
def test_a_ready_host_probes_clean():
    fake = FakeServer([tools_entry("qwen3:8b")])
    pr = la.probe(ENV, which=which_all({"ollama", "claude"}), fetch=fake)
    assert pr.ollama_path and pr.server_up and pr.agents["claude"]
    assert [m.name for m in pr.usable_models] == ["qwen3:8b"]
    assert la.diagnose(pr, "claude", "qwen3:8b") == []


def test_probe_sends_only_reads_never_a_generation():
    """GET /api/tags, and POST /api/show for a server that does not list capabilities.
    Nothing that would load or run a model."""
    fake = FakeServer([tools_entry("a:1", caps=None), tools_entry("b:2", caps=None)],
                      show={"a:1": ["completion", "tools"], "b:2": ["completion"]})
    pr = la.probe(ENV, which=which_all({"ollama"}), fetch=fake)
    assert {(m, u.split("/", 3)[3]) for m, u, _b in fake.calls} == {
        ("GET", "api/tags"), ("POST", "api/show")}
    assert [(m.name, m.tools) for m in pr.models] == [("a:1", True), ("b:2", False)]


def test_capabilities_listed_in_the_tag_list_need_no_show_call():
    fake = FakeServer([tools_entry("a:1"), tools_entry("b:2", caps=("completion",))])
    pr = la.probe(ENV, which=which_all({"ollama"}), fetch=fake)
    assert [c[0] for c in fake.calls] == ["GET"]
    assert [(m.name, m.tools) for m in pr.models] == [("a:1", True), ("b:2", False)]


def test_a_failed_show_call_reads_as_no_tools_not_as_a_crash():
    fake = FakeServer([tools_entry("a:1", caps=None)], show={})        # show answers 404
    pr = la.probe(ENV, which=which_all({"ollama"}), fetch=fake)
    assert pr.server_up and pr.models[0].tools is False


def test_cloud_models_are_never_offered():
    fake = FakeServer([
        tools_entry("qwen3-coder:480b-cloud"), tools_entry("x:cloud"),
        tools_entry("remote:1", remote_host="https://ollama.com"),
        tools_entry("local:1")])
    pr = la.probe(ENV, which=which_all({"ollama"}), fetch=fake)
    assert [m.name for m in pr.usable_models] == ["local:1"]
    only_cloud = la.probe(ENV, which=which_all({"ollama"}),
                          fetch=FakeServer([tools_entry("m:480b-cloud")]))
    problems = la.diagnose(only_cloud)
    assert [p.code for p in problems if p.code != "agent_missing"] == ["no_models"]
    assert "cloud" in problems[0].what


def test_the_number_of_show_calls_is_bounded():
    many = [tools_entry(f"m:{i}", caps=None) for i in range(la.MAX_SHOW_CALLS + 25)]
    fake = FakeServer(many, show={f"m:{i}": ["tools"] for i in range(200)})
    la.probe(ENV, which=which_all({"ollama"}), fetch=fake)
    assert sum(1 for c in fake.calls if c[0] == "POST") == la.MAX_SHOW_CALLS


@pytest.mark.parametrize("exc", [ConnectionRefusedError("connection refused"),
                                 TimeoutError("timed out"), OSError("no route")])
def test_a_server_that_does_not_answer_is_server_down(exc):
    pr = la.probe(ENV, which=which_all({"ollama", "claude"}), fetch=FakeServer(down=exc))
    assert not pr.server_up and pr.ollama_path
    (p,) = la.diagnose(pr, "claude")
    assert p.code == "server_down"
    assert "127.0.0.1:11434" in p.what and "not answering" in p.what
    assert str(exc) in p.what                       # the reason is shown, not hidden
    assert "ollama serve" in p.fix and "OLLAMA_HOST=127.0.0.1:11434" in p.fix


@pytest.mark.parametrize("fake", [FakeServer(tags_status=500),
                                  FakeServer(tags_body=b"<html>not ollama</html>"),
                                  FakeServer(tags_body=b'{"models": 7}')])
def test_something_else_on_the_port_is_not_an_ollama_server(fake):
    pr = la.probe(ENV, which=which_all({"ollama", "claude"}), fetch=fake)
    assert not pr.server_up
    assert [p.code for p in la.diagnose(pr)] == ["server_down"]


def test_ollama_not_installed_is_reported_first_even_with_a_server_up():
    pr = la.probe(ENV, which=which_all({"claude"}),
                  fetch=FakeServer([tools_entry("qwen3:8b")]))
    assert pr.server_up and not pr.ollama_path
    codes = [p.code for p in la.diagnose(pr)]
    assert codes == ["ollama_missing"]
    p = la.diagnose(pr)[0]
    assert "not installed" in p.what and "section 2" in p.fix


def test_nothing_installed_names_every_missing_piece_in_the_order_to_fix_them():
    pr = la.probe(ENV, which=which_all(set()), fetch=FakeServer(down=OSError("refused")))
    assert [p.code for p in la.diagnose(pr, "claude")] == [
        "ollama_missing", "server_down", "agent_missing"]


def test_a_server_with_no_models_and_one_with_no_tools_model_are_different_problems():
    none = la.probe(ENV, which=which_all({"ollama", "claude"}), fetch=FakeServer([]))
    (p,) = la.diagnose(none)
    assert p.code == "no_models" and "ollama pull qwen3:8b" in p.fix
    plain = la.probe(ENV, which=which_all({"ollama", "claude"}), fetch=FakeServer(
        [tools_entry("embed:1", caps=("embedding",)), tools_entry("chat:2", caps=("completion",))]))
    (q,) = la.diagnose(plain)
    assert q.code == "no_tools_model" and "tools capability" in q.what
    assert "embed:1" in q.what and "ollama pull qwen3:8b" in q.fix


def test_a_missing_agent_command_names_the_command_and_the_launcher():
    pr = good_probe(agents=())
    (p,) = la.diagnose(pr, "claude", "qwen3:8b")
    assert p.code == "agent_missing"
    assert "`claude`" in p.what and "ollama launch claude" in p.what
    pr2 = good_probe(agents=("claude",))
    (q,) = la.diagnose(pr2, "opencode", "qwen3:8b")
    assert "`opencode`" in q.what


def test_a_chosen_model_that_cannot_drive_an_agent_is_refused_by_name():
    pr = la.Probe("/usr/bin/ollama", server_up=True, agents={"claude": "/usr/bin/claude"},
                  models=(la.ModelInfo("qwen3:8b", True), la.ModelInfo("plain:1", False),
                          la.ModelInfo("far:1", True, cloud=True)))
    assert [p.code for p in la.diagnose(pr, "claude", "plain:1")] == ["model_no_tools"]
    assert [p.code for p in la.diagnose(pr, "claude", "far:1")] == ["model_cloud"]
    assert [p.code for p in la.diagnose(pr, "claude", "gone:9")] == ["model_gone"]


def test_a_source_that_cannot_be_copied_is_a_problem_too(tmp_path):
    info = la.inspect_source(str(tmp_path / "nope"))
    probs = la.diagnose(good_probe(), "claude", "qwen3:8b", source=info)
    assert [p.code for p in probs] == ["source"] and "does not exist" in probs[0].what


def test_every_problem_points_at_a_real_heading_of_the_doc():
    with open(DOC, encoding="utf-8") as fh:
        text = fh.read()
    anchors = set()
    for line in text.splitlines():
        m = re.match(r"#{2,4}\s+(.*)", line)
        if m:
            slug = re.sub(r"[^\w\s-]", "", m.group(1).lower()).strip().replace(" ", "-")
            anchors.add(slug)
    problems = []
    problems += la.diagnose(la.Probe(), "claude", "")
    problems += la.diagnose(la.Probe("/x", server_up=True), "claude", "")
    problems += la.diagnose(la.Probe("/x", server_up=True,
                                     models=(la.ModelInfo("a", False),)), "claude", "")
    problems += la.diagnose(good_probe(), "nope", "")
    problems += la.diagnose(good_probe(), "claude", "gone",
                            source=la.SourceInfo("/p", False, "x"))
    assert {p.code for p in problems} >= {"ollama_missing", "server_down", "no_models",
                                          "no_tools_model", "agent_unknown", "source",
                                          "agent_missing"}
    for p in problems:
        path, _hash, anchor = p.doc.partition("#")
        assert path == la.DOC_PATH
        assert anchor in anchors, (p.code, anchor)


# ── defaults ─────────────────────────────────────────────────────────────────────
def test_the_prepared_mesh_model_wins_over_everything():
    pr = good_probe(models=("qwen3:8b", "hugmesh-agent:latest", "zzz:1"))
    assert la.choose_defaults(pr) == ("claude", "hugmesh-agent:latest")


def test_otherwise_a_model_the_doc_names_wins_over_an_unknown_one():
    pr = good_probe(models=("aaa:1", "qwen2.5-coder:7b", "qwen3:8b"))
    assert la.choose_defaults(pr) == ("claude", "qwen3:8b")
    pr = good_probe(models=("aaa:1", "gpt-oss:20b", "qwen2.5-coder:7b"))
    assert la.choose_defaults(pr) == ("claude", "qwen2.5-coder:7b")


def test_otherwise_the_first_model_with_tools_and_otherwise_none():
    assert la.choose_defaults(good_probe(models=("aaa:1", "bbb:2")))[1] == "aaa:1"
    pr = la.Probe("/x", server_up=True, models=(la.ModelInfo("plain:1", False),
                                                 la.ModelInfo("far:1", True, cloud=True)))
    assert la.choose_defaults(pr)[1] == ""
    with pytest.raises(ValueError):
        plan_for("/nonexistent", "/nonexistent", pr=pr)


def test_a_model_the_person_picked_is_kept_when_usable():
    pr = good_probe(models=("qwen3:8b", "qwen2.5-coder:7b"))
    assert la.choose_defaults(pr, "claude", "qwen2.5-coder:7b")[1] == "qwen2.5-coder:7b"
    assert la.choose_defaults(pr, "claude", "typo:1")[1] == "qwen3:8b"


def test_the_agent_defaults_to_claude_and_falls_back_to_an_installed_one():
    assert la.choose_defaults(good_probe(agents=("claude", "opencode")))[0] == "claude"
    assert la.choose_defaults(good_probe(agents=("opencode",)))[0] == "opencode"
    assert la.choose_defaults(good_probe(agents=()))[0] == "claude"


def test_every_model_the_module_prefers_is_named_in_the_doc():
    with open(DOC, encoding="utf-8") as fh:
        text = fh.read()
    for name in la.DOC_MODELS:
        assert name in text, name
    assert la.PREFERRED_MODEL in text


# ── the environment ──────────────────────────────────────────────────────────────
def noisy_environ():
    env = {name: SECRET for name in TOKEN_NAMES}
    env.update({
        "PATH": "/usr/bin:/bin", "HOME": "/home/x", "USER": "x", "LANG": "en_US.UTF-8",
        "LC_ALL": "C", "LC_CTYPE": "C.UTF-8", "TERM": "xterm", "DISPLAY": ":0",
        "WAYLAND_DISPLAY": "wayland-0", "XDG_RUNTIME_DIR": "/run/user/1", "XDG_SEAT": "seat0",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1/bus",
        "LOGNAME": "x", "SHELL": "/bin/zsh", "EDITOR": "vim", "AWS_PROFILE": "p",
        "XAUTHORITY": "/home/x/.Xauthority", "PYTHONPATH": "/x", "BASH_ENV": "/x/env",
        "ENV": "/x/env", "http_proxy": "http://proxy:3128", "MAVEN_OPTS": "-Dx",
        "OLLAMA_MODELS": "/big/disk", "OLLAMA_API_KEY": SECRET})
    return env


def test_build_env_keeps_exactly_the_allowlist():
    env = la.build_env(noisy_environ())
    assert set(env) == {"PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM",
                        "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SEAT",
                        "DBUS_SESSION_BUS_ADDRESS"}
    assert SECRET not in "".join(env.values())
    for name in TOKEN_NAMES:
        assert name not in env, name


def test_build_env_never_invents_a_value():
    assert la.build_env({}) == {}
    assert la.build_env({"HOME": "/h"}) == {"HOME": "/h"}


def test_ollama_host_passes_only_when_it_is_this_machine():
    assert la.build_env({"OLLAMA_HOST": "127.0.0.1:11500"})["OLLAMA_HOST"] == "127.0.0.1:11500"
    assert la.build_env({"OLLAMA_HOST": "localhost"})["OLLAMA_HOST"] == "localhost:11434"
    for remote in ("0.0.0.0:11434", "gpu.example.org:11434", "192.168.0.9"):
        assert "OLLAMA_HOST" not in la.build_env({"OLLAMA_HOST": remote}), remote


def test_only_the_terminals_own_environment_gets_xauthority():
    env = noisy_environ()
    assert "XAUTHORITY" not in la.build_env(env)
    term = la.build_env(env, terminal=True)
    assert term["XAUTHORITY"] == "/home/x/.Xauthority"
    assert SECRET not in "".join(term.values())


def test_the_forbidden_flag_list_names_every_way_to_approve_without_asking():
    for flag in ("-y", "--yes", "--experimental-yolo", "--yolo",
                 "--dangerously-skip-permissions", "--auto-approve"):
        assert flag in la.FORBIDDEN_FLAGS
        assert la.forbidden_in(["ollama", "launch", "claude", flag]) == [flag]
    assert la.forbidden_in(["ollama", "launch", "claude", "--model", "qwen3:8b"]) == []


# ── the plan ─────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("lane", [la.LANE_DOCKER, la.LANE_KIND])
@pytest.mark.parametrize("agent", sorted(la.AGENTS))
def test_no_command_the_card_can_build_carries_an_approval_flag_or_a_token(
        source, state, lane, agent):
    environ = dict(noisy_environ())
    pr = good_probe(agents=tuple(la.AGENTS))
    plan = plan_for(source, state, lane=lane, pr=pr, environ=environ, agent=agent)
    assert plan.argv[:3] == ("ollama", "launch", agent)
    assert plan.argv[3:] == ("--model", "qwen3:8b")
    assert la.forbidden_in(plan.argv) == []
    for text in (plan.shell_command, plan.paste_text):
        words = shlex.split(text.replace('"$(cat', "'$(cat").replace(')"', ")'"))
        assert not set(words) & la.FORBIDDEN_FLAGS, text
        for name in TOKEN_NAMES:
            assert name not in text, name
        assert SECRET not in text
    assert "env -i " in plan.shell_command and "env -i " in plan.paste_text
    assert plan.shell_command.startswith("cd ")
    # the one place a token could hide is the brief: it carries no environment at all
    assert SECRET not in plan.brief


def test_the_claude_launch_is_the_verified_form_with_the_brief_as_the_prompt(source, state):
    plan = plan_for(source, state)
    assert plan.uses_brief_argument
    assert " launch claude --model qwen3:8b -- \"$(cat " in plan.shell_command
    assert plan.scratch.brief_path in plan.shell_command
    assert plan.cwd == plan.scratch.dest


def test_other_agents_start_without_an_invented_prompt_form_and_say_where_the_brief_is(
        source, state):
    plan = plan_for(source, state, pr=good_probe(agents=("opencode",)), agent="opencode")
    assert not plan.uses_brief_argument
    assert " -- " not in plan.shell_command.split("ollama launch", 1)[1]
    assert plan.scratch.brief_path in plan.shell_command           # printed in the window


def test_the_brief_carries_every_never_run_item_of_the_doc(source, state):
    with open(DOC, encoding="utf-8") as fh:
        doc = " ".join(fh.read().split())
    never = re.search(r"Never run: .*?directory\.", doc).group(0)
    end = re.search(r"End every task with: .*?verify\.|End every task with: .*?did NOT verify\.",
                    doc).group(0)
    brief = " ".join(plan_for(source, state).brief.split())
    # the doc's own sentences, word for word: edit the doc and not the brief (or the
    # reverse) and this fails
    assert never in brief, never
    assert end in brief, end
    for item in ("git push", "sudo", "docker compose up/down", "make stack-*", "make kind-*"):
        assert item in never and item in brief, item
    assert "Do not claim a test passed unless you ran it and saw it pass." in brief
    assert "scratch clone" in brief and "no remote" in brief


def test_the_docker_brief_names_the_lane_the_mesh_and_a_rebuild_that_exists(source, state):
    brief = plan_for(source, state, lane=la.LANE_DOCKER).brief
    assert "Lane: Docker" in brief
    assert "demo mesh" in brief and "hugmesh.net, chat.example.org" in brief
    assert "http://localhost:8088" in brief
    # the targets named exist on this commit's Makefile; stack-rebuild does not
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        make = fh.read()
    for target in re.findall(r"`make ([a-z0-9-]+)`", brief):
        assert re.search(rf"^{re.escape(target)}:", make, re.M), target
    assert "stack-rebuild" not in brief and "kind-rebuild" not in brief
    assert "not you" in brief


def test_the_kind_brief_names_the_one_service_rebuild_and_that_it_does_not_restart_pods(
        source, state):
    repos = la.kind_image_repos(GENERATOR_DIR)
    assert "hugmesh-user-bff-api" in repos, "scripts/kind-load-images.sh changed shape"
    brief = plan_for(source, state, lane=la.LANE_KIND).brief
    assert "Lane: kind (a local Kubernetes cluster named hugmesh-local)" in brief
    assert "make kind-images ONLY=hugmesh-user-bff-api" in brief
    assert "does NOT restart" in brief
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        assert re.search(r"^kind-images:", fh.read(), re.M)


def test_in_the_own_tree_mode_the_named_command_carries_the_source_variables(source, state):
    """A hand-typed `make kind-images` has neither STACK_SRC nor STACK_NO_CLONE (the
    Studio sets them), so it would build ./.stack-src after resetting it. The brief
    must name the form that builds the person's tree, and the variables must be ones
    the Makefile and the script really honour."""
    root = os.path.dirname(source)
    kind = plan_for(source, state, lane=la.LANE_KIND).brief
    assert f"STACK_SRC={root} STACK_NO_CLONE=1 make kind-images ONLY=hugmesh-user-bff-api" in kind
    docker = plan_for(source, state, lane=la.LANE_DOCKER).brief
    assert f"`STACK_SRC={root} STACK_NO_CLONE=1 make stack-build`" in docker
    assert "that is what STACK_NO_CLONE=1 does" in docker
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        make = fh.read()
    assert re.search(r"^STACK_SRC\s*\?=", make, re.M)
    assert re.search(r"if \[ -n \"\$\(STACK_NO_CLONE\)\" \]", make)
    with open(os.path.join(GENERATOR_DIR, "scripts", "kind-load-images.sh"),
              encoding="utf-8") as fh:
        assert 'STACK_SRC="${STACK_SRC:-' in fh.read()


def test_in_the_download_mode_the_command_is_bare_and_the_reset_is_named(source, state):
    brief = la.prepare(
        lane=la.LANE_KIND, mesh="m", domains=[], doors=[], repo="hugmesh-user-bff-api",
        source=source, source_root="/gen/.stack-src", source_mode="clone",
        generator_dir=GENERATOR_DIR, pr=good_probe(), environ=ENV, state_root=state).brief
    assert "with: make kind-images ONLY=hugmesh-user-bff-api" in brief
    assert "STACK_SRC=" not in brief and "STACK_NO_CLONE=1 make" not in brief
    assert "resets .stack-src checkouts that have no local commits" in brief


def test_a_repo_that_is_not_a_kind_image_is_not_given_a_command_that_would_be_refused(
        source, state):
    brief = plan_for(source, state, lane=la.LANE_KIND, repo="hugmesh-games").brief
    assert "ONLY=hugmesh-games" not in brief
    assert "would refuse it" in brief


def test_the_brief_says_what_the_copy_does_not_contain(source, state):
    (open(os.path.join(source, "a.txt"), "w")).write("edited\n")        # uncommitted
    brief = plan_for(source, state).brief
    assert "1 uncommitted change(s)" in brief and "NOT in your copy" in brief
    assert "downloaded" not in brief                    # existing mode
    clone_mode = la.prepare(
        lane=la.LANE_DOCKER, mesh="m", domains=[], doors=[], repo="hugmesh-user-bff-api",
        source=source, source_root="/gen/.stack-src", source_mode="clone",
        generator_dir=GENERATOR_DIR, pr=good_probe(), environ=ENV, state_root=state).brief
    assert "make stack-clone" in clone_mode and "/gen/.stack-src" in clone_mode


def test_the_brief_is_written_beside_the_copy_not_inside_it(source, state):
    plan = plan_for(source, state)
    path = la.write_brief(plan)
    assert open(path, encoding="utf-8").read() == plan.brief
    assert not path.startswith(plan.scratch.dest + os.sep)
    clone = la.create_scratch(plan.scratch)
    assert run_git("status", "--porcelain", cwd=clone.path) == ""


# ── the command, run for real ────────────────────────────────────────────────────
def test_the_window_command_hands_the_agent_no_token_even_from_a_profile_and_a_server(
        source, state, tmp_path):
    """Run the exact string a terminal would run, through bash --noprofile --norc, with
    a token in the parent's environment AND one injected by BASH_ENV (the way a profile
    or a terminal server would). The stand-in `ollama` records what it was given."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    out = tmp_path / "seen.json"
    recorder = tmp_path / "record.py"
    recorder.write_text(
        "import json, os, sys\n"
        f"json.dump({{'argv': sys.argv[1:], 'env': dict(os.environ), 'cwd': os.getcwd()}}, "
        f"open({str(out)!r}, 'w'))\n")
    (bindir / "ollama").write_text(
        f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(recorder))} \"$@\"\n")
    (bindir / "ollama").chmod(0o755)
    profile = tmp_path / "profile.sh"
    profile.write_text(f"export GH_TOKEN={SECRET}\nexport GITHUB_TOKEN={SECRET}\n")
    environ = dict(noisy_environ(), PATH=f"{bindir}:/usr/bin:/bin", BASH_ENV=str(profile),
                   HOME=str(tmp_path))
    plan = plan_for(source, state, environ=environ)
    la.write_brief(plan)
    la.create_scratch(plan.scratch)
    proc = subprocess.run(["bash", "--noprofile", "--norc", "-c", plan.shell_command],
                          env=environ, input="\n", capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    seen = json.load(open(out))
    assert os.path.realpath(seen["cwd"]) == os.path.realpath(plan.cwd)
    assert seen["argv"][:4] == ["launch", "claude", "--model", "qwen3:8b"]
    assert seen["argv"][4] == "--" and seen["argv"][5] == plan.brief.rstrip("\n")
    assert not [f for f in seen["argv"] if f in la.FORBIDDEN_FLAGS]
    names = set(seen["env"])
    assert not (names & set(TOKEN_NAMES)), names & set(TOKEN_NAMES)
    assert SECRET not in json.dumps(seen["env"])
    assert not {"BASH_ENV", "ENV", "LOGNAME", "SHELL", "EDITOR", "AWS_PROFILE",
                "PYTHONPATH", "http_proxy", "MAVEN_OPTS", "XAUTHORITY"} & names
    assert {"PATH", "HOME", "TERM", "DISPLAY"} <= names
    assert "[agent exited with status 0" in proc.stdout


def test_the_pasted_text_clones_without_a_remote_and_launches(source, state):
    plan = plan_for(source, state)
    lines = plan.paste_text.splitlines()
    assert lines[0].startswith("git clone --no-hardlinks -- ")
    assert lines[2] == "git remote remove origin"
    assert lines[3].startswith("git switch -c lm/")
    assert lines[4].startswith("env -i ")
    assert lines.index("git remote remove origin") < len(lines) - 1


# ── the scratch clone ────────────────────────────────────────────────────────────
def test_a_scratch_clone_has_no_remote_a_new_branch_and_no_hardlinks(source, state):
    c = la.make_scratch_clone(source, "demo mesh", "hugmesh-user-bff-api", state_root=state)
    assert run_git("remote", cwd=c.path) == ""
    assert run_git("branch", "--show-current", cwd=c.path) == c.branch
    assert re.fullmatch(r"lm/\d{8}-\d{6}", c.branch)
    assert run_git("rev-parse", "HEAD", cwd=c.path) == run_git("rev-parse", "HEAD", cwd=source)
    assert c.base_sha == run_git("rev-parse", "HEAD", cwd=source)
    assert open(os.path.join(c.path, "b.txt")).read() == "two\n"
    # the object database is a copy: a file in it is not a second name for the source's
    objs = [os.path.join(dp, f) for dp, _d, fs in os.walk(os.path.join(c.path, ".git", "objects"))
            for f in fs if len(f) in (38, 62)]
    assert objs and all(os.stat(o).st_nlink == 1 for o in objs)
    # and the push has nowhere to go
    p = subprocess.run(["git", "push"], cwd=c.path, capture_output=True, text=True)
    assert p.returncode != 0


def test_it_lives_under_the_state_dir_and_the_mesh_name_never_escapes(source, state):
    c = la.make_scratch_clone(source, "../../etc/odd mesh", "hugmesh-user-bff-api",
                              state_root=state)
    assert os.path.realpath(c.path).startswith(os.path.realpath(state) + os.sep)
    assert os.path.relpath(c.path, state).split(os.sep)[:2] == ["agent-work", "etc-odd-mesh"]
    assert ".stack-src" not in c.path


def test_a_detached_head_source_still_clones_and_branches(source, state):
    run_git("checkout", "-q", "--detach", "HEAD~1", cwd=source)
    c = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    assert run_git("remote", cwd=c.path) == ""
    assert run_git("branch", "--show-current", cwd=c.path) == c.branch
    assert run_git("rev-parse", "HEAD", cwd=c.path) == run_git("rev-parse", "HEAD", cwd=source)
    assert not os.path.exists(os.path.join(c.path, "b.txt"))      # HEAD~1 had no b.txt
    assert la.inspect_source(source).branch == "(detached)"


def test_a_source_that_is_not_a_repository_is_refused_with_the_reason(tmp_path, state):
    plain = tmp_path / "plain"
    plain.mkdir()
    (plain / "f").write_text("x")
    with pytest.raises(la.ScratchError, match="not a git repository"):
        la.make_scratch_clone(str(plain), "m", "hugmesh-x", state_root=state)
    assert not os.path.exists(os.path.join(state, "agent-work"))      # nothing was made
    with pytest.raises(la.ScratchError, match="does not exist"):
        la.make_scratch_clone(str(tmp_path / "gone"), "m", "hugmesh-x", state_root=state)
    with pytest.raises(la.ScratchError, match="No folder is known"):
        la.make_scratch_clone("", "m", "hugmesh-x", state_root=state)


def test_a_repository_with_no_commit_and_a_subfolder_of_one_are_refused(tmp_path, state, source):
    empty = tmp_path / "empty"
    empty.mkdir()
    run_git("init", "-q", cwd=empty)
    with pytest.raises(la.ScratchError, match="no commits"):
        la.make_scratch_clone(str(empty), "m", "hugmesh-x", state_root=state)
    sub = os.path.join(source, "deep")
    os.makedirs(sub)
    with pytest.raises(la.ScratchError, match="not its top folder"):
        la.make_scratch_clone(sub, "m", "hugmesh-x", state_root=state)


def test_a_clean_copy_from_the_same_commit_is_reused(source, state):
    first = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    again = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    assert again.reused and again.path == first.path and again.branch == first.branch


def test_a_copy_with_uncommitted_work_is_never_reused_or_touched(source, state):
    first = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    mine = os.path.join(first.path, "work.txt")
    open(mine, "w").write("the agent's unsaved work\n")                  # untracked
    open(os.path.join(first.path, "a.txt"), "w").write("changed\n")      # tracked
    second = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    assert not second.reused and second.path == first.path + "-2"
    assert open(mine).read() == "the agent's unsaved work\n"             # nothing deleted
    assert os.path.isdir(first.path)
    third = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    assert third.reused and third.path == second.path       # -2 is clean and current


def test_a_copy_of_an_older_commit_is_not_reused(source, state):
    first = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    open(os.path.join(source, "c.txt"), "w").write("three\n")
    run_git("add", "c.txt", cwd=source)
    run_git("commit", "-q", "-m", "three", cwd=source)
    second = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    assert not second.reused and second.path == first.path + "-2"
    assert os.path.exists(os.path.join(second.path, "c.txt"))
    assert os.path.isdir(first.path)


def test_a_copy_whose_remote_came_back_is_not_reused(source, state):
    first = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    run_git("remote", "add", "origin", "https://example.invalid/x.git", cwd=first.path)
    second = la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state)
    assert not second.reused and second.path != first.path
    assert run_git("remote", cwd=second.path) == ""


def test_the_clone_never_runs_with_a_token_or_a_prompt(source, state):
    seen = []

    def spy(args, cwd=None):
        seen.append(args)
        return la._run_git(args, cwd)
    env = la._git_env()
    assert env.get("GIT_TERMINAL_PROMPT") == "0"
    os.environ["GH_TOKEN"] = SECRET
    try:
        assert "GH_TOKEN" not in la._git_env()
        la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state,
                              runner=spy)
    finally:
        del os.environ["GH_TOKEN"]
    assert ["remote", "remove", "origin"] in seen


def test_a_failing_step_leaves_a_plain_reason_and_never_a_half_usable_copy(source, state):
    def failing(step_prefix):
        def runner(args, cwd=None):
            if list(args[:len(step_prefix)]) == step_prefix:
                return 1, "boom"
            return la._run_git(args, cwd)
        return runner
    with pytest.raises(la.ScratchError, match="git clone failed: boom"):
        la.make_scratch_clone(source, "m", "hugmesh-user-bff-api", state_root=state,
                              runner=failing(["clone"]))
    with pytest.raises(la.ScratchError, match="must not be used"):
        la.make_scratch_clone(source, "m", "hugmesh-a", state_root=state,
                              runner=failing(["remote", "remove"]))
    # the half-made copy is not offered as reusable: it still has its remote
    spec = la.prepare_scratch(source, "m", "hugmesh-a", state_root=state)
    assert not spec.reuse


def test_a_state_dir_inside_the_source_is_refused(source):
    with pytest.raises(la.ScratchError, match="inside the source"):
        la.make_scratch_clone(source, "m", "hugmesh-user-bff-api",
                              state_root=os.path.join(source, "state"))


# ── the terminal ─────────────────────────────────────────────────────────────────
class FakeHost:
    def __init__(self, kind="linux", have=(), exits=None, environ=None):
        self.kind = kind
        self.have = list(have)
        self.exits = exits or {}
        self.environ = environ if environ is not None else {
            "DISPLAY": ":0", "GH_TOKEN": SECRET, "HOME": "/h", "PATH": "/usr/bin",
            "XAUTHORITY": "/h/.Xauthority"}
        self.runs = []

    def which(self, cmd):
        return f"/usr/bin/{cmd}" if cmd in self.have else None

    def run(self, argv, cwd, env):
        self.runs.append((list(argv), cwd, dict(env)))
        return self.exits.get(os.path.basename(argv[0]), 0)


def make_host(fake):
    return la.Host(fake.kind, which=fake.which, run=fake.run, environ=fake.environ)


@pytest.fixture
def plan(source, state):
    p = plan_for(source, state)
    la.write_brief(p)
    la.create_scratch(p.scratch)
    return p


def test_the_first_installed_terminal_is_used_with_the_clone_as_its_folder(plan):
    fake = FakeHost(have=["xterm", "konsole"])
    res = la.launch(plan, make_host(fake))
    assert res.opened and res.verified and res.terminal == "konsole"
    (argv, cwd, env), = fake.runs
    assert argv[0] == "/usr/bin/konsole" and "--separate" in argv
    assert cwd == plan.cwd and plan.cwd in argv
    assert argv[-4:-1] == ["bash", "--noprofile", "--norc"] or "-c" in argv
    assert argv[-1] == plan.shell_command
    assert res.command == plan.paste_text


@pytest.mark.parametrize("name,flag", [
    ("xfce4-terminal", "--disable-server"), ("konsole", "--separate"), ("kitty", "--directory"),
    ("gnome-terminal", "--"), ("alacritty", "--working-directory"), ("foot", "--working-directory"),
    ("xterm", "-e"), ("x-terminal-emulator", "-e")])
def test_every_known_terminal_runs_bash_without_a_profile(plan, name, flag):
    fake = FakeHost(have=[name])
    res = la.launch(plan, make_host(fake))
    assert res.opened and res.terminal == name
    (argv, _cwd, _env), = fake.runs
    assert flag in argv
    i = argv.index("bash")
    assert argv[i:i + 4] == ["bash", "--noprofile", "--norc", "-c"]
    assert argv[i + 4] == plan.shell_command and "-l" not in argv[i:i + 3]


def test_the_terminal_process_gets_the_allowlist_not_the_session(plan):
    fake = FakeHost(have=["xterm"])
    la.launch(plan, make_host(fake))
    env = fake.runs[0][2]
    assert "GH_TOKEN" not in env and SECRET not in "".join(env.values())
    assert env["DISPLAY"] == ":0" and env["XAUTHORITY"] == "/h/.Xauthority"


def test_a_terminal_that_refuses_falls_through_to_the_next(plan):
    fake = FakeHost(have=["konsole", "xterm"], exits={"konsole": 1})
    res = la.launch(plan, make_host(fake))
    assert res.opened and res.terminal == "xterm"
    assert res.tried == ("konsole exited 1",)
    assert [os.path.basename(r[0][0]) for r in fake.runs] == ["konsole", "xterm"]


def test_a_terminal_still_running_after_the_grace_is_the_window(plan):
    fake = FakeHost(have=["xterm"], exits={"xterm": None})
    res = la.launch(plan, make_host(fake))
    assert res.opened and res.verified and "still running" in res.reason


def test_when_every_terminal_refuses_the_person_gets_the_command(plan):
    fake = FakeHost(have=["konsole", "xterm"], exits={"konsole": 2, "xterm": 3})
    res = la.launch(plan, make_host(fake))
    assert not res.opened and not res.verified
    assert "konsole exited 2" in res.reason and "xterm exited 3" in res.reason
    assert res.command == plan.paste_text and "env -i" in res.command


def test_with_no_terminal_installed_it_says_what_it_looked_for(plan):
    res = la.launch(plan, make_host(FakeHost(have=[])))
    assert not res.opened and "no terminal emulator was found" in res.reason
    assert "xterm" in res.reason and res.command == plan.paste_text


def test_no_desktop_session_opens_nothing_and_does_not_try(plan):
    fake = FakeHost(have=["xterm"], environ={"HOME": "/h"})
    res = la.launch(plan, make_host(fake))
    assert not res.opened and fake.runs == []
    assert "no desktop session" in res.reason and res.command == plan.paste_text
    wsl = FakeHost(kind="wsl", have=["xterm"], environ={"HOME": "/h"})
    assert "WSL2 without a Linux desktop" in la.launch(plan, make_host(wsl)).reason


def test_wsl2_with_a_desktop_uses_the_linux_terminals(plan):
    fake = FakeHost(kind="wsl", have=["xterm"], environ={"WAYLAND_DISPLAY": "wayland-0"})
    res = la.launch(plan, make_host(fake))
    assert res.opened and res.terminal == "xterm"


def test_windows_and_macos_say_plainly_that_the_window_is_not_offered(plan):
    for kind, word in (("windows", "Windows"), ("darwin", "macOS")):
        fake = FakeHost(kind=kind, have=["xterm"])
        res = la.launch(plan, make_host(fake))
        assert not res.opened and word in res.reason and fake.runs == []
        assert res.command == plan.paste_text


def test_the_default_spawner_reports_a_real_exit_and_a_real_still_running(tmp_path, monkeypatch):
    fast = tmp_path / "refuse"
    fast.write_text("#!/bin/sh\nexit 3\n")
    slow = tmp_path / "linger"
    slow.write_text("#!/bin/sh\nsleep 5\n")
    for f in (fast, slow):
        f.chmod(f.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setattr(la, "TERMINAL_WAIT_S", 0.5)
    assert la._spawn_and_wait([str(fast)], str(tmp_path), {"PATH": "/usr/bin:/bin"}) == 3
    assert la._spawn_and_wait([str(slow)], str(tmp_path), {"PATH": "/usr/bin:/bin"}) is None
    assert la._spawn_and_wait([str(tmp_path / "nothere")], str(tmp_path), {}) == 127


# ── the real server on this machine (read-only) ──────────────────────────────────
def test_probe_against_the_real_loopback_ollama_reads_without_generating():
    """GET /api/tags and POST /api/show only. Skipped, loudly, when no server answers:
    that is a statement about this host, not about the code."""
    seen = []

    def spy(method, url, body=None, timeout=2.0):
        seen.append((method, url.split("/", 3)[3]))
        return la._http(method, url, body, timeout)
    pr = la.probe(os.environ, fetch=spy)
    if not pr.server_up:
        pytest.skip(f"NOT EXERCISED: no Ollama server answers on {pr.server} "
                    f"({pr.server_error}); the live probe check needs one")
    assert set(seen) <= {("GET", "api/tags"), ("POST", "api/show")}, seen
    assert ("GET", "api/tags") in seen
    for m in pr.models:
        assert isinstance(m.tools, bool)
    if pr.usable_models:
        agent, model = la.choose_defaults(pr)
        assert model in {m.name for m in pr.usable_models}
