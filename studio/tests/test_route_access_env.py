"""The route-access-db OWNER password reaches every compose call the Studio makes.

compose.local.yaml no longer spells that password: it reads
``${ROUTE_ACCESS_DB_PASSWORD:-}``, and the value is the one key
tests/stack/gen-route-access-env.sh owns in tests/stack/.env. ``make stack-up`` runs
the generator first, but the Mesh Monitor's scale button runs
``docker compose -p hugmesh-local -f … up --scale`` DIRECTLY. Without these two
pieces a scaled gateway replica was created with an empty password and could not
load the route table that drives RBAC:

* ``LocalStackNode._build_env`` puts the file's value into the env every docker call
  runs with (compose would load .env by itself, but not under the legacy
  ``docker-compose`` fallback, and not when the inherited env carries the variable
  EMPTY, because an environment variable beats .env);
* ``mesh_monitor.scale`` runs the generator first (``ensure_route_access_env``) and
  refuses the scale when it fails.

No docker daemon is used: a stub answers the generator's volume/container probes.
"""
from __future__ import annotations

import os
import shutil
import stat
import textwrap

import pytest

from hugmesh_studio.core import mesh_monitor as mm
from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core.local_stack_node import LocalStackNode

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GEN = os.path.join(REPO, "tests", "stack", "gen-route-access-env.sh")
KEY = "ROUTE_ACCESS_DB_PASSWORD"


def _gen_dir(tmp_path, dotenv: str | None = None, with_script: bool = False) -> str:
    stack = tmp_path / "tests" / "stack"
    stack.mkdir(parents=True)
    (stack / "compose.local.yaml").write_text("name: hugmesh-local\n", encoding="utf-8")
    if dotenv is not None:
        (stack / ".env").write_text(dotenv, encoding="utf-8")
    if with_script:
        shutil.copy2(GEN, stack / "gen-route-access-env.sh")
    return str(tmp_path)


def _docker_stub(tmp_path, volume: str) -> str:
    """volume: "absent" | "exists" | "down"."""
    p = tmp_path / "docker-stub"
    p.write_text(textwrap.dedent(f"""\
        #!/usr/bin/env bash
        case "{volume}" in
          down) echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
        esac
        case "$1 $2" in
          "volume inspect")
            [ "{volume}" = exists ] && {{ echo '[{{}}]'; exit 0; }}
            echo "Error response from daemon: get $3: no such volume" >&2; exit 1 ;;
          "ps -a") exit 0 ;;
        esac
        exit 99
        """), encoding="utf-8")
    p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return str(p)


# ── reading tests/stack/.env (read only) ─────────────────────────────────────────

@pytest.mark.parametrize("text,want", [
    (f"{KEY}=abc123\n", "abc123"),
    (f"# x\nFOO=1\n{KEY}=first\n{KEY}=second\n", "second"),        # last wins, like compose
    (f'export {KEY} = "deadbeef"\r\n', "deadbeef"),               # dotenv spellings
    (f"{KEY}='q-1.2_3~'\n", "q-1.2_3~"),
    (f"{KEY}=ab+cd\n", ""),                                       # not URL-unreserved
    (f"{KEY}=\n", ""),
    ("FOO=1\n", ""),
])
def test_route_access_password_reads_the_key_like_compose(tmp_path, text, want):
    assert lsn.route_access_password(_gen_dir(tmp_path, text)) == want


def test_route_access_password_without_a_file_is_empty(tmp_path):
    assert lsn.route_access_password(_gen_dir(tmp_path)) == ""


def test_build_env_carries_the_file_value_and_beats_an_inherited_empty_one(tmp_path, monkeypatch):
    monkeypatch.setenv(KEY, "")                     # an EMPTY export would beat .env
    gen = _gen_dir(tmp_path, f"FOO=1\n{KEY}=cafe42\n")
    env = LocalStackNode(gen)._build_env(write_overlays=False)
    assert env[KEY] == "cafe42"


def test_build_env_is_byte_identical_when_the_file_holds_no_key(tmp_path, monkeypatch):
    monkeypatch.delenv(KEY, raising=False)
    bare = LocalStackNode(_gen_dir(tmp_path / "a"))._build_env(write_overlays=False)
    other = LocalStackNode(_gen_dir(tmp_path / "b", "FOO=1\n"))._build_env(write_overlays=False)
    assert KEY not in bare and KEY not in other
    bare.pop("PATH", None), other.pop("PATH", None)
    assert bare == other


def test_build_env_never_writes_the_file(tmp_path):
    gen = _gen_dir(tmp_path, with_script=True)
    LocalStackNode(gen)._build_env(write_overlays=False)
    assert not os.path.exists(os.path.join(gen, "tests", "stack", ".env"))


# ── ensure_route_access_env: the generator, run before a scale ──────────────────

def test_ensure_mints_into_tests_stack_env_and_build_env_then_carries_it(tmp_path, monkeypatch):
    monkeypatch.setenv("DOCKER", _docker_stub(tmp_path, "absent"))
    gen = _gen_dir(tmp_path, "MINE=1\n", with_script=True)
    node = LocalStackNode(gen)
    ok, note = node.ensure_route_access_env(project="hugmesh-local")
    assert ok and note == ""
    dotenv = os.path.join(gen, "tests", "stack", ".env")
    text = open(dotenv, encoding="utf-8").read()
    assert text.startswith("MINE=1\n")                         # the operator's line kept
    value = lsn.route_access_password(gen)
    assert len(value) == 48 and all(c in "0123456789abcdef" for c in value)
    assert stat.S_IMODE(os.stat(dotenv).st_mode) == 0o600
    assert node._build_env(write_overlays=False)[KEY] == value


def test_ensure_adopting_an_existing_volume_passes_the_warning_through(tmp_path, monkeypatch):
    monkeypatch.setenv("DOCKER", _docker_stub(tmp_path, "exists"))
    gen = _gen_dir(tmp_path, with_script=True)
    ok, note = LocalStackNode(gen).ensure_route_access_env(project="hugmesh-local")
    assert ok and "WARNING" in note
    assert lsn.route_access_password(gen) not in ("", None)
    assert lsn.route_access_password(gen) not in note           # the value never in text


def test_ensure_refuses_when_docker_cannot_answer(tmp_path, monkeypatch):
    monkeypatch.setenv("DOCKER", _docker_stub(tmp_path, "down"))
    gen = _gen_dir(tmp_path, with_script=True)
    ok, note = LocalStackNode(gen).ensure_route_access_env(project="hugmesh-local")
    assert ok is False and "docker could not say" in note
    assert not os.path.exists(os.path.join(gen, "tests", "stack", ".env"))


def test_ensure_with_a_key_already_present_spawns_nothing(tmp_path, monkeypatch):
    gen = _gen_dir(tmp_path, f"{KEY}=abc123\n", with_script=True)

    def _no_spawn(*a, **k):
        raise AssertionError("ensure spawned a process although the key is present")
    monkeypatch.setattr(lsn.subprocess, "run", _no_spawn)
    assert LocalStackNode(gen).ensure_route_access_env(project="hugmesh-local") == (True, "")


def test_ensure_with_an_unsafe_key_still_runs_the_generator_and_refuses(tmp_path, monkeypatch):
    monkeypatch.setenv("DOCKER", _docker_stub(tmp_path, "absent"))
    gen = _gen_dir(tmp_path, f"{KEY}=ab+cd\n", with_script=True)
    ok, note = LocalStackNode(gen).ensure_route_access_env(project="hugmesh-local")
    assert ok is False and "URL-unreserved" in note


def test_ensure_on_an_older_checkout_without_the_script_is_a_no_op(tmp_path):
    ok, note = LocalStackNode(_gen_dir(tmp_path)).ensure_route_access_env()
    assert (ok, note) == (True, "")


# ── mesh_monitor.scale runs the ensure step on the compose lane ─────────────────

def _unit(lane, ns, kind, ctrl):
    return mm.MeshUnit(
        lane=lane, namespace=ns, name="c-1", owner="o", phase="Running 1/1",
        ready=True, reason="", state="ok", cluster_path="", external="",
        door=mm.Door(blocked="no door"), detail="d",
        scale=mm.ScaleTarget(kind, ctrl, ns, refused=""))


def _compose_unit(ctrl="pki-gateway"):
    return _unit("compose", "hugmesh-local", "compose-service", ctrl)


class _Node:
    compose_file = "/gen/tests/stack/compose.local.yaml"

    def __init__(self, ensure=(True, "")):
        self.ensure_result, self.ensured, self.probed = ensure, [], []

    def ensure_route_access_env(self, project="", timeout=60):
        self.ensured.append(project)
        if isinstance(self.ensure_result, Exception):
            raise self.ensure_result
        return self.ensure_result

    def _probe(self, cmd, timeout=None):
        self.probed.append(list(cmd))
        return 0, "ok"


def test_a_compose_scale_runs_the_generator_first_with_the_pinned_project():
    node = _Node()
    ok, text = mm.scale("/gen", node, _compose_unit(), 2)
    assert ok, text
    assert node.ensured == ["hugmesh-local"] and len(node.probed) == 1
    assert "--scale" in node.probed[0]


def test_a_generator_failure_refuses_the_scale_before_compose_runs():
    node = _Node(ensure=(False, "docker could not say whether volume x exists"))
    ok, text = mm.scale("/gen", node, _compose_unit(), 2)
    assert ok is False and node.probed == []
    assert "refused" in text and "docker could not say" in text


def test_a_raising_ensure_is_folded_into_a_refusal():
    node = _Node(ensure=OSError("bash: not found"))
    ok, text = mm.scale("/gen", node, _compose_unit(), 2)
    assert ok is False and node.probed == [] and "bash: not found" in text


def test_an_adoption_warning_is_surfaced_on_success():
    node = _Node(ensure=(True, "WARNING: ROUTE_ACCESS_DB_PASSWORD was missing\nmore"))
    ok, text = mm.scale("/gen", node, _compose_unit(), 2)
    assert ok and "WARNING: ROUTE_ACCESS_DB_PASSWORD was missing" in text and "more" not in text


def test_the_kind_lane_does_not_run_the_compose_generator(monkeypatch):
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, d: "/usr/bin/" + tool)
    node = _Node()
    unit = _unit("kind", "hugmesh", "deployment", "gw")
    mm.scale("/gen", node, unit, 2)
    assert node.ensured == []
