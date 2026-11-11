"""The Studio still SEES a running local stack whose tests/stack/.env lacks the DB keys.

hugmesh-generator#857 moved every local-stack Postgres password (and the brokers'
SVC_PASSWORD) out of the compose files: they read ``${KEY:?...}`` from the gitignored
tests/stack/.env, which tests/stack/gen-stack-db-env.sh fills. Only the ensuring
``make stack-*`` targets run that script, and ``${KEY:?}`` stops EVERY compose
command, ``ps`` and ``logs`` included. The day #857 lands, the operator's .env holds
only ROUTE_ACCESS_DB_PASSWORD while the mesh runs, so before this fix:

* ``LocalStackNode.status()`` (``compose ps -q``) got an interpolation error, an
  empty stdout, and reported the running mesh as ``running=False, 0 container(s)``;
* ``logs()`` returned "" and ``running_env()`` returned "";
* the Mesh Monitor's ``compose ps --all`` was rejected and fell back to ``docker ps``;
* the Mesh Monitor's ``up --scale`` failed on interpolation (it ensured only the
  route-access key).

The read paths now pass a fixed placeholder for a key the env does not set
(``stack_db_read_env`` / ``_read_probe``), never through ``_build_env`` (which every
creating call uses), and the scale runs the resolver first (``ensure_stack_db_env``).
No docker daemon is used: stubs answer every probe.
"""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
import textwrap

import pytest

from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core import mesh_monitor as mm
from hugmesh_studio.core.local_stack_node import LocalStackNode

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TABLE = os.path.join(REPO, "tests", "stack", "stack-db-passwords.tsv")
GEN = os.path.join(REPO, "tests", "stack", "gen-stack-db-env.sh")
PH = lsn.STACK_DB_READ_PLACEHOLDER

# status() is the probe under test: opt out of conftest's inert status() stub (the
# subprocess.run it would make is stubbed per test instead, so no docker is touched).
pytestmark = pytest.mark.real_stack_probes


def _real_keys() -> list[str]:
    return lsn.stack_db_keys(REPO)


def _gen_dir(tmp_path, dotenv: str | None = None, *, table: bool = True,
             script: bool = False) -> str:
    stack = tmp_path / "tests" / "stack"
    stack.mkdir(parents=True)
    (stack / "compose.local.yaml").write_text("name: hugmesh-local\n", encoding="utf-8")
    if table:
        shutil.copy2(TABLE, stack / "stack-db-passwords.tsv")
    if script:
        shutil.copy2(GEN, stack / "gen-stack-db-env.sh")
    if dotenv is not None:
        (stack / ".env").write_text(dotenv, encoding="utf-8")
    return str(tmp_path)


def _clear_keys(monkeypatch):
    for k in _real_keys():
        monkeypatch.delenv(k, raising=False)


class _Recorder:
    """Stands in for subprocess.run: records argv + env, answers like compose."""

    def __init__(self, stdout="cid-1\ncid-2\n"):
        self.calls: list[tuple[list[str], dict | None]] = []
        self.stdout = stdout

    def __call__(self, cmd, **kw):
        self.calls.append((list(cmd), kw.get("env")))
        return subprocess.CompletedProcess(cmd, 0, self.stdout, "")


# ── the table and the read env ────────────────────────────────────────────────────

def test_the_real_table_lists_every_key_and_an_older_checkout_has_none(tmp_path):
    keys = _real_keys()
    assert len(keys) >= 14 and "FEDERATION_DB_PASSWORD" in keys and "SVC_PASSWORD" in keys
    assert lsn.stack_db_keys(_gen_dir(tmp_path, table=False)) == []


def test_read_env_fills_every_unset_or_empty_key_and_keeps_an_exported_value(tmp_path):
    gen = _gen_dir(tmp_path)
    base = {"PATH": "/usr/bin", "FEDERATION_DB_PASSWORD": "exported1", "SVC_PASSWORD": ""}
    env = lsn.stack_db_read_env(gen, base)
    assert env["FEDERATION_DB_PASSWORD"] == "exported1"         # an export wins
    assert env["SVC_PASSWORD"] == PH                            # empty beats .env in compose
    assert all(env[k] for k in _real_keys())
    assert base == {"PATH": "/usr/bin", "FEDERATION_DB_PASSWORD": "exported1",
                    "SVC_PASSWORD": ""}                         # the input is not mutated


def test_read_env_on_an_older_checkout_adds_nothing(tmp_path):
    base = {"PATH": "/usr/bin"}
    assert lsn.stack_db_read_env(_gen_dir(tmp_path, table=False), base) == base


def test_build_env_never_carries_the_placeholder(tmp_path, monkeypatch):
    """The separation: every CREATING call (make, the scale) runs with _build_env, so
    a placeholder there could become a container's password."""
    _clear_keys(monkeypatch)
    gen = _gen_dir(tmp_path, "ROUTE_ACCESS_DB_PASSWORD=abc123\n")
    env = LocalStackNode(gen)._build_env(write_overlays=False)
    assert PH not in env.values()
    assert not any(k in env for k in _real_keys())


# ── status / logs / running_env: the operator's .env shape ───────────────────────

@pytest.fixture
def node_and_run(tmp_path, monkeypatch):
    _clear_keys(monkeypatch)
    gen = _gen_dir(tmp_path, "ROUTE_ACCESS_DB_PASSWORD=abc123\n")
    rec = _Recorder()
    monkeypatch.setattr(lsn, "_compose_base", lambda: ["docker", "compose"])
    monkeypatch.setattr(lsn.subprocess, "run", rec)
    return LocalStackNode(gen), rec


def _compose_env(rec, verb):
    hits = [env for cmd, env in rec.calls if cmd[:2] == ["docker", "compose"] and verb in cmd]
    assert hits, f"no compose {verb} call was made"
    return hits[0]


@pytest.mark.parametrize("call,verb", [
    (lambda n: n.status(), "ps"),
    (lambda n: n.logs(), "logs"),
    (lambda n: n.running_env(), "ps"),
])
def test_every_compose_read_passes_a_value_for_every_key(node_and_run, call, verb):
    node, rec = node_and_run
    call(node)
    env = _compose_env(rec, verb)
    assert env is not None, "the compose read ran with no env, so ${KEY:?} stops it"
    missing = [k for k in _real_keys() if not env.get(k)]
    assert missing == []
    assert env.get("ROUTE_ACCESS_DB_PASSWORD", "") in ("", "abc123")  # never replaced


def test_status_reads_a_running_mesh_as_running(node_and_run):
    node, _ = node_and_run
    st = node.status()
    assert st.running is True and st.detail == "2 container(s)"


def test_read_probe_adds_the_placeholders_and_probe_does_not(node_and_run):
    node, rec = node_and_run
    node._read_probe(["docker", "compose", "ps", "--all"], timeout=5)
    node._probe(["docker", "compose", "up", "-d", "--scale", "x=2", "x"], timeout=5)
    (_, read_env), (_, probe_env) = rec.calls[-2], rec.calls[-1]
    assert all(read_env.get(k) for k in _real_keys())
    assert not any(k in probe_env for k in _real_keys())


# ── the Mesh Monitor ─────────────────────────────────────────────────────────────

class _MonitorNode:
    compose_file = "/gen/tests/stack/compose.local.yaml"

    def __init__(self, *, has_reader=True, ensure_db=(True, "")):
        self.read_calls, self.probe_calls, self.ensured_db = [], [], []
        self.ensure_db_result = ensure_db
        if not has_reader:
            self._read_probe = None

    def _read_probe(self, cmd, timeout=None):
        self.read_calls.append(list(cmd))
        return 0, "read"

    def _probe(self, cmd, timeout=None):
        self.probe_calls.append(list(cmd))
        return 0, "probe"

    def ensure_route_access_env(self, project="", timeout=60):
        return True, ""

    def ensure_stack_db_env(self, project="", timeout=60):
        self.ensured_db.append(project)
        if isinstance(self.ensure_db_result, Exception):
            raise self.ensure_db_result
        return self.ensure_db_result


def test_monitor_compose_ps_goes_through_the_read_probe():
    node = _MonitorNode()
    rc, out = mm._read_probe(node, ["docker", "compose", "ps", "--all"], 5)
    assert (rc, out) == (0, "read") and node.probe_calls == []


def test_monitor_read_probe_falls_back_for_a_node_without_one():
    node = _MonitorNode(has_reader=False)
    rc, out = mm._read_probe(node, ["docker", "compose", "ps"], 5)
    assert (rc, out) == (0, "probe")


def test_the_compose_lane_lists_its_rows_through_the_read_probe(monkeypatch):
    """_compose_units: `compose ps --all --format json` must use the read env."""
    seen = []

    class N(_MonitorNode):
        public_https_port = 0
        public_host_port = 0

        def status(self):
            return lsn.StackStatus(running=True, detail="2 container(s)")

        def _read_probe(self, cmd, timeout=None):
            seen.append(("read", list(cmd)))
            return 0, "[]"

        def _probe(self, cmd, timeout=None):
            seen.append(("probe", list(cmd)))
            return 0, ""

    monkeypatch.setattr(mm.shutil, "which", lambda name: "/usr/bin/" + name)
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    mm._compose_units(N(), "/gen", None, {}, mm._Budget(30))
    ps = [(how, cmd) for how, cmd in seen if cmd[:2] == ["docker", "compose"] and "ps" in cmd]
    assert ps and all(how == "read" for how, _ in ps)


def _compose_unit(ctrl="pki-gateway"):
    return mm.MeshUnit(
        lane="compose", namespace="hugmesh-local", name="c-1", owner="o",
        phase="Running 1/1", ready=True, reason="", state="ok", cluster_path="",
        external="", door=mm.Door(blocked="no door"), detail="d",
        scale=mm.ScaleTarget("compose-service", ctrl, "hugmesh-local", refused=""))


def test_a_compose_scale_ensures_the_db_keys_with_the_pinned_project():
    node = _MonitorNode()
    ok, text = mm.scale("/gen", node, _compose_unit(), 2)
    assert ok, text
    assert node.ensured_db == ["hugmesh-local"]
    assert len(node.probe_calls) == 1 and "--scale" in node.probe_calls[0]


@pytest.mark.parametrize("result", [(False, "docker could not say whether volume x exists"),
                                    OSError("bash: not found")])
def test_a_db_resolver_failure_refuses_the_scale_before_compose_runs(result):
    node = _MonitorNode(ensure_db=result)
    ok, text = mm.scale("/gen", node, _compose_unit(), 2)
    assert ok is False and node.probe_calls == []
    assert "refused" in text and "gen-stack-db-env.sh" in text


# ── ensure_stack_db_env: the resolver, run before a scale ────────────────────────

def _docker_stub(tmp_path, volumes: str) -> str:
    p = tmp_path / "docker-stub"
    p.write_text(textwrap.dedent(f"""\
        #!/usr/bin/env bash
        [ "{volumes}" = down ] && {{ echo "Cannot connect to the Docker daemon" >&2; exit 1; }}
        case "$1 $2" in
          "volume inspect")
            echo "Error response from daemon: get $3: no such volume" >&2; exit 1 ;;
          "ps -a") exit 0 ;;
        esac
        exit 99
        """), encoding="utf-8")
    p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return str(p)


def test_ensure_mints_every_key_into_tests_stack_env_keeping_other_lines(tmp_path, monkeypatch):
    monkeypatch.setenv("DOCKER", _docker_stub(tmp_path, "none"))
    gen = _gen_dir(tmp_path, "ROUTE_ACCESS_DB_PASSWORD=abc123\n", script=True)
    ok, note = LocalStackNode(gen).ensure_stack_db_env(project="hugmesh-local")
    assert ok, note
    held = lsn._stack_dotenv(gen)
    assert held["ROUTE_ACCESS_DB_PASSWORD"] == "abc123"
    assert all(len(held.get(k, "")) == 48 for k in _real_keys())
    assert not any(held[k] in note for k in _real_keys())       # no value in the text


def test_ensure_refuses_when_docker_cannot_answer(tmp_path, monkeypatch):
    monkeypatch.setenv("DOCKER", _docker_stub(tmp_path, "down"))
    gen = _gen_dir(tmp_path, "ROUTE_ACCESS_DB_PASSWORD=abc123\n", script=True)
    ok, note = LocalStackNode(gen).ensure_stack_db_env(project="hugmesh-local")
    assert ok is False and "docker could not say" in note


def test_ensure_with_every_key_present_spawns_nothing(tmp_path, monkeypatch):
    lines = "".join(f"{k}=abc{i}def\n" for i, k in enumerate(_real_keys()))
    gen = _gen_dir(tmp_path, lines, script=True)

    def _no_spawn(*a, **k):
        raise AssertionError("ensure spawned a process although every key is present")
    monkeypatch.setattr(lsn.subprocess, "run", _no_spawn)
    assert LocalStackNode(gen).ensure_stack_db_env(project="hugmesh-local") == (True, "")


def test_ensure_on_an_older_checkout_is_a_no_op(tmp_path):
    assert LocalStackNode(_gen_dir(tmp_path, table=False)).ensure_stack_db_env() == (True, "")
    assert LocalStackNode(_gen_dir(tmp_path / "b")).ensure_stack_db_env() == (True, "")


def test_ensure_probes_the_pinned_project(tmp_path, monkeypatch):
    """A node-image mesh (hugmesh-img-<id>) must adopt from ITS volumes, not
    hugmesh-local's: the project rides STACK_DB_PROJECT into the resolver."""
    gen = _gen_dir(tmp_path, "ROUTE_ACCESS_DB_PASSWORD=abc123\n", script=True)
    rec = _Recorder(stdout="")
    monkeypatch.setattr(lsn.subprocess, "run", rec)
    LocalStackNode(gen).ensure_stack_db_env(project="hugmesh-img-abc")
    spawned = [(cmd, env) for cmd, env in rec.calls if cmd[:1] == ["bash"]]
    assert len(spawned) == 1 and spawned[0][0][1].endswith("gen-stack-db-env.sh")
    assert spawned[0][1]["STACK_DB_PROJECT"] == "hugmesh-img-abc"
