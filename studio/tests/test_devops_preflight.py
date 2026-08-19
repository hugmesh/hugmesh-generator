"""Both-ways coverage for the DevOps lane's repo-access preflight
(LocalStackNode.devops_repo_access + its devops_up wiring) — issue #48.

Motivating failure (live, 2026-08-19): `make kind-up` was run without
ARGOCD_REPO_TOKEN against a cluster with no local-sync mount; every git-path
Application sat in `ComparisonError: authentication required`, vault-0 was
never created, and the operator watched the bootstrap's 8-minute vault-0 wait
end in a warning that exited 0 — the Studio reported success on a broken
cluster. The preflight turns that into a one-line remedy in the GUI log
BEFORE the long verb starts.

Every probe is mocked BOTH ways — no test talks to kind or docker, and
nothing asserts readiness the host doesn't have.
"""
import os

from hugmesh_studio.core import devops_tools
from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core.local_stack_node import KIND_REPO_MOUNT, LocalStackNode


def _clone(tmp_path):
    """A generator dir that looks like a full clone (.git DIRECTORY)."""
    (tmp_path / ".git").mkdir()
    return str(tmp_path)


def _worktree(tmp_path):
    """A generator dir that looks like a linked worktree (.git FILE)."""
    (tmp_path / ".git").write_text("gitdir: /somewhere/else/.git/worktrees/x\n")
    return str(tmp_path)


def _probes(monkeypatch, *, kind_installed=True, clusters="", mount_ok=True):
    """Wire which()/probe() to a modelled host: `clusters` is what
    `kind get clusters` prints; `mount_ok` is whether the node carries the
    read-only repo mount."""
    monkeypatch.setattr(devops_tools, "which",
                        lambda tool, gd: "/fake/bin/kind" if kind_installed else None,
                        raising=True)

    def probe(self, cmd, timeout=15):
        if cmd[0].endswith("kind") and cmd[1:3] == ["get", "clusters"]:
            return (0, clusters)
        if cmd[0] == "docker" and cmd[1] == "exec":
            assert cmd[-1] == f"{KIND_REPO_MOUNT}/.git"
            return (0, "") if mount_ok else (1, "")
        raise AssertionError(f"unexpected probe: {cmd}")
    monkeypatch.setattr(LocalStackNode, "_probe", probe, raising=True)


# ── the preflight itself, both ways ──────────────────────────────────────────

def test_token_set_needs_nothing_else(monkeypatch, tmp_path):
    # With the override credential, none of the local-sync conditions apply —
    # not even a worktree checkout or a mountless cluster can block the lane.
    monkeypatch.setenv("ARGOCD_REPO_TOKEN", "tok")
    node = LocalStackNode(_worktree(tmp_path))
    assert node.devops_repo_access() == []


def test_fresh_host_full_clone_is_ready(monkeypatch, tmp_path):
    # No existing cluster: bootstrap-kind.sh mounts + serves the checkout on
    # create, so there is nothing to preflight beyond the clone shape.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    _probes(monkeypatch, clusters="")
    node = LocalStackNode(_clone(tmp_path))
    assert node.devops_repo_access() == []


def test_existing_cluster_with_mount_is_ready(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=True)
    node = LocalStackNode(_clone(tmp_path))
    assert node.devops_repo_access() == []


def test_worktree_checkout_names_both_remedies(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    node = LocalStackNode(_worktree(tmp_path))
    problems = node.devops_repo_access()
    assert len(problems) == 1
    assert "ARGOCD_REPO_TOKEN" in problems[0]
    assert "full clone" in problems[0]


def test_mountless_cluster_names_both_remedies(monkeypatch, tmp_path):
    # THE #48 SHAPE: an existing cluster from before the local-sync path, no
    # token. The remedy must name the recreate (mounts are create-time-only)
    # AND the token override — before the 8-minute wait, not after.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False)
    node = LocalStackNode(_clone(tmp_path))
    problems = node.devops_repo_access()
    assert len(problems) == 1
    assert "kind delete cluster --name hugmesh-local" in problems[0]
    assert "ARGOCD_REPO_TOKEN" in problems[0]
    assert KIND_REPO_MOUNT in problems[0]


def test_cluster_name_override_is_respected(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.setenv("KIND_CLUSTER_NAME", "other-cluster")
    _probes(monkeypatch, clusters="other-cluster", mount_ok=False)
    node = LocalStackNode(_clone(tmp_path))
    problems = node.devops_repo_access()
    assert problems and "kind delete cluster --name other-cluster" in problems[0]


def test_missing_kind_tool_defers_to_devops_available(monkeypatch, tmp_path):
    # The tool gap is devops_available()'s report; this preflight must not
    # double-report it (and must not crash probing with no binary).
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    _probes(monkeypatch, kind_installed=False)
    node = LocalStackNode(_clone(tmp_path))
    assert node.devops_repo_access() == []


# ── devops_up wiring: the remedy lands in the GUI log BEFORE the long verb ──

def test_devops_up_blocks_and_logs_before_make(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False)
    node = LocalStackNode(_clone(tmp_path))
    monkeypatch.setattr(LocalStackNode, "devops_available",
                        lambda self: [], raising=True)

    def _no_make(self, *a, **kw):  # pragma: no cover - the assertion IS the test
        raise AssertionError("make kind-up must not run when repo access is missing")
    monkeypatch.setattr(LocalStackNode, "_make", _no_make, raising=True)

    lines: list[str] = []
    ok, why = node.devops_up(on_line=lines.append)
    assert ok is False
    assert "ARGOCD_REPO_TOKEN" in why
    # the one-line remedy reached the streamed GUI log, not just the summary
    assert any("kind delete cluster" in ln for ln in lines)


def test_devops_up_proceeds_and_names_the_mode(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    _probes(monkeypatch, clusters="")
    node = LocalStackNode(_clone(tmp_path))
    monkeypatch.setattr(LocalStackNode, "devops_available",
                        lambda self: [], raising=True)
    ran: dict = {}

    def _fake_make(self, target, timeout, on_line=None, cancel=None):
        ran["target"] = target
        return True, "done"
    monkeypatch.setattr(LocalStackNode, "_make", _fake_make, raising=True)

    lines: list[str] = []
    ok, _ = node.devops_up(on_line=lines.append)
    assert ok is True and ran["target"] == "kind-up"
    assert any("tokenless local sync" in ln for ln in lines)


def test_devops_up_token_mode_is_named(monkeypatch, tmp_path):
    monkeypatch.setenv("ARGOCD_REPO_TOKEN", "tok")
    node = LocalStackNode(_clone(tmp_path))
    monkeypatch.setattr(LocalStackNode, "devops_available",
                        lambda self: [], raising=True)
    monkeypatch.setattr(LocalStackNode, "_make",
                        lambda self, target, timeout, on_line=None, cancel=None:
                        (True, "done"), raising=True)
    lines: list[str] = []
    ok, _ = node.devops_up(on_line=lines.append)
    assert ok is True
    assert any("GitHub" in ln for ln in lines)
    # the token VALUE must never reach the log
    assert not any("ARGOCD_REPO_TOKEN=tok" in ln for ln in lines)
