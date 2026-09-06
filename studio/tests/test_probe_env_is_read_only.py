"""A READ must not edit the tree it is reading.

``LocalStackNode._build_env`` is the one env every stack subprocess runs with, and
it also PERSISTS three generated overlays on its way past (.theme.css, the compose
limits overlay, the own-domains overlay) — right for a bring-up, wrong for a probe.
The mesh monitor made that visible: with its section open the page probes every
10s, so every 10s the operator's generator checkout was rewritten with the FORM's
current limits, under a mesh that may have been started with others.

The dict is the contract: ``write_overlays=False`` must return the SAME env (the
Makefile picks the files up by `$(wildcard)`, nothing in the dict comes from them)
and simply not write.
"""
from __future__ import annotations

import os
import subprocess

import pytest

from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core import own_casdoor, stack_limits
from hugmesh_studio.core.local_stack_node import LocalStackNode

THEME = ":root{--brand:#123456}"


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "tests" / "stack").mkdir(parents=True)
    return str(tmp_path)


@pytest.fixture
def writes(monkeypatch):
    """Counts the limits overlay write at the function the node calls."""
    seen = []
    monkeypatch.setattr(stack_limits, "write_overlay",
                        lambda d, limits, services: seen.append(d))
    monkeypatch.setattr(stack_limits, "compose_services", lambda _p: ["a"])
    return seen


def _node(gen, **kw):
    return LocalStackNode(gen, login_theme_css=THEME,
                          own_idp_domains=("team.example",), **kw)


def test_a_bring_up_env_still_writes_all_three_overlays(gen, writes):
    """The default is unchanged: a bring-up persists what it is about to run with."""
    _node(gen)._build_env()
    assert writes == [gen]
    assert os.path.exists(os.path.join(gen, "tests", "stack", ".theme.css"))
    assert os.path.exists(own_casdoor.overlay_path(gen))


def test_a_read_env_writes_nothing_at_all(gen, writes):
    _node(gen)._build_env(write_overlays=False)
    assert writes == []
    assert not os.path.exists(os.path.join(gen, "tests", "stack", ".theme.css"))
    assert not os.path.exists(own_casdoor.overlay_path(gen))


def test_the_read_env_is_byte_identical_to_the_bring_up_env(gen, writes):
    """The flag drops a side effect, never a variable — a probe that ran in a
    different env than `make stack-up` would fabricate readiness, which is the
    whole reason _probe uses this dict in the first place."""
    node = _node(gen)
    assert node._build_env(write_overlays=False) == node._build_env()


def test_extra_env_still_applies_to_a_read_env(gen, writes):
    node = _node(gen)
    assert node._build_env({"K": "v"}, write_overlays=False)["K"] == "v"


def test_probe_uses_the_read_env_so_a_10s_monitor_poll_writes_nothing(gen, writes,
                                                                     monkeypatch):
    """The mesh monitor's every read goes through node._probe."""
    def run(cmd, **kw):
        return subprocess.CompletedProcess(cmd, 0, "ok", "")
    monkeypatch.setattr(lsn.subprocess, "run", run)
    node = _node(gen)
    for _ in range(6):                      # a minute of monitor polling
        assert node._probe(["docker", "info"]) == (0, "ok")
    assert writes == []
    assert not os.path.exists(os.path.join(gen, "tests", "stack", ".theme.css"))


def test_the_probe_env_is_the_one_the_command_actually_runs_with(gen, writes,
                                                                 monkeypatch):
    got = {}

    def run(cmd, **kw):
        got.update(kw.get("env") or {})
        return subprocess.CompletedProcess(cmd, 0, "", "")
    monkeypatch.setattr(lsn.subprocess, "run", run)
    node = _node(gen, env="prod")
    node._probe(["docker", "info"])
    assert got.get("ENV") == "prod" and got.get("OWN_CASDOOR") == "1"
