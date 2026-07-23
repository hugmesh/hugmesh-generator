"""Local mesh-node runner (core/mesh_node.py) — the two residual CODE defects behind the
user's "when selecting start mesh node, we just get errors" (distinct from the resolved
docker-corruption/full-disk env issue, which is fixed):

  DEFECT 1 — start launched nothing: the compose invocation lacked `--profile mesh`, so the
             template's only service (tailscale, gated behind profiles:["mesh"]) was never
             selected. _compose() now includes it.

  DEFECT 2 — raw error: no TS_AUTHKEY guard, so every compose parse died on the required
             `${TS_AUTHKEY:?...}`. start() now returns a clear actionable message and never
             invokes compose without it; teardown/status inject a placeholder so they parse.

The docker-gated test validates the staged file with `docker compose --profile mesh config`
(rc=0, lists tailscale) — no `up`, no image pull, no cluster contact.
"""
import os
import shutil
import subprocess

import pytest

from hugmesh_studio.core import mesh_node
from hugmesh_studio.core.mesh_node import MeshNode

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _docker_compose_ok() -> bool:
    return bool(mesh_node._compose_base())


# ── DEFECT 1: --profile mesh on the compose argv ──────────────────────────────────────
def test_compose_argv_includes_profile_mesh_and_subcommand(monkeypatch, tmp_path):
    # pin a compose base so the assertion doesn't depend on which binary is installed
    monkeypatch.setattr(mesh_node, "_compose_base", lambda: ["docker", "compose"])
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))
    argv = node._compose("up", "-d")
    assert "--profile" in argv
    assert argv[argv.index("--profile") + 1] == "mesh"
    assert argv[-2:] == ["up", "-d"]                       # subcommand still trails
    # profile precedes the subcommand (it is a top-level flag)
    assert argv.index("--profile") < argv.index("up")


# ── DEFECT 2: TS_AUTHKEY guard ─────────────────────────────────────────────────────────
def test_start_without_authkey_is_clear_and_never_runs_compose(monkeypatch, tmp_path):
    monkeypatch.delenv("TS_AUTHKEY", raising=False)
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))

    real_run = mesh_node.subprocess.run
    calls = []

    def spy(cmd, **kw):
        calls.append(cmd)
        # the compose-version probe used by available() is allowed through
        if isinstance(cmd, list) and cmd[:3] == ["docker", "compose", "version"]:
            return real_run(cmd, **kw)
        raise AssertionError(f"compose must not run without TS_AUTHKEY: {cmd}")

    monkeypatch.setattr(mesh_node.subprocess, "run", spy)
    ok, why = node.start()
    assert ok is False
    assert "TS_AUTHKEY" in why
    # never invoked a compose 'up', and never staged the workdir
    assert not any(isinstance(c, list) and "up" in c for c in calls)
    assert not os.path.exists(node.workdir)


def test_start_missing_compose_gives_clear_message(monkeypatch, tmp_path):
    monkeypatch.setattr(mesh_node, "_compose_base", lambda: [])
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))
    ok, why = node.start()
    assert ok is False
    assert "Docker" in why                                 # actionable, not a stack trace


def test_env_injects_placeholder_authkey_for_teardown(monkeypatch, tmp_path):
    monkeypatch.delenv("TS_AUTHKEY", raising=False)
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))
    assert node._env().get("TS_AUTHKEY")                   # placeholder so `down`/`ps` parse


def test_env_preserves_real_authkey(monkeypatch, tmp_path):
    monkeypatch.setenv("TS_AUTHKEY", "real-key-123")
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))
    assert node._env()["TS_AUTHKEY"] == "real-key-123"


# ── docker-gated: prove the wiring with `compose config` (no up / pull / cluster) ─────
@pytest.mark.skipif(not _docker_compose_ok(), reason="docker compose unavailable")
def test_staged_compose_config_validates_with_profile(tmp_path):
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))
    node._stage()
    staged = os.path.join(node.workdir, "docker-compose.mesh.yml")
    assert os.path.exists(staged)
    base = mesh_node._compose_base()
    env = os.environ.copy()
    env["TS_AUTHKEY"] = "dummy-validate-only"               # config-only; no auth performed
    r = subprocess.run([*base, "--profile", "mesh", "-f", staged, "config", "--services"],
                       cwd=node.workdir, env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert "tailscale" in r.stdout                          # the profile-gated service is selected


@pytest.mark.skipif(not _docker_compose_ok(), reason="docker compose unavailable")
def test_config_without_profile_selects_nothing(tmp_path):
    # the regression the --profile mesh fix defends: without the profile, zero services.
    node = MeshNode(GENERATOR_DIR, workdir=str(tmp_path / "wd"))
    node._stage()
    staged = os.path.join(node.workdir, "docker-compose.mesh.yml")
    base = mesh_node._compose_base()
    env = os.environ.copy()
    env["TS_AUTHKEY"] = "dummy-validate-only"
    r = subprocess.run([*base, "-f", staged, "config", "--services"],
                       cwd=node.workdir, env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert "tailscale" not in r.stdout.split()
