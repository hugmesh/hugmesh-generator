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


def _probes(monkeypatch, *, kind_installed=True, clusters="", mount_ok=True,
            declared_bind=None):
    """Wire which()/probe() to a modelled host: `clusters` is what
    `kind get clusters` prints; `mount_ok` is whether the node can SEE the repo
    at the read-only mount; `declared_bind` is the host path the node's mount
    table DECLARES for it (None = the node declares no such bind).

    Those last two are deliberately independent, because on a real host they
    are: docker resolves a bind's source when the container starts, so a node
    can declare exactly the right Source and still be serving whatever that path
    resolved to at start time. Modelling them as one flag is what let the
    preflight answer "delete your cluster" to a stale mount."""
    monkeypatch.setattr(devops_tools, "which",
                        lambda tool, gd: "/fake/bin/kind" if kind_installed else None,
                        raising=True)

    def probe(self, cmd, timeout=15):
        if cmd[0].endswith("kind") and cmd[1:3] == ["get", "clusters"]:
            return (0, clusters)
        if cmd[0] == "docker" and cmd[1] == "exec":
            assert cmd[-1] == f"{KIND_REPO_MOUNT}/.git"
            return (0, "") if mount_ok else (1, "")
        if cmd[0] == "docker" and cmd[1] == "inspect":
            assert KIND_REPO_MOUNT in cmd[-1], "the format must select THIS mount"
            return (0, declared_bind or "")
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
    # token, and NO bind declared at all. The remedy must name the recreate
    # (a bind can only be ADDED at create time) AND the token override —
    # before the 8-minute wait, not after.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False,
            declared_bind=None)
    node = LocalStackNode(_clone(tmp_path))
    problems = node.devops_repo_access()
    assert len(problems) == 1
    assert "kind delete cluster --name hugmesh-local" in problems[0]
    assert "ARGOCD_REPO_TOKEN" in problems[0]
    assert KIND_REPO_MOUNT in problems[0]


def test_cluster_name_override_is_respected(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.setenv("KIND_CLUSTER_NAME", "other-cluster")
    _probes(monkeypatch, clusters="other-cluster", mount_ok=False,
            declared_bind=None)
    node = LocalStackNode(_clone(tmp_path))
    problems = node.devops_repo_access()
    assert problems and "kind delete cluster --name other-cluster" in problems[0]


# ── the STALE bind: declared right, serving nothing (live 2026-08-21) ────────
# /home is eCryptfs; the kind node restarted while it was not yet mounted, so
# docker re-resolved the bind against the empty directory the eCryptfs mount
# shadows. `docker inspect` still showed the correct Source, the node saw 1
# entry instead of 44, and the in-cluster git daemon answered every ArgoCD
# fetch with "no such repository". The old preflight called that a mountless
# cluster and told the operator to delete it — a 40-minute rebuild for a
# condition a 20-second `docker restart` clears.

def test_stale_bind_offers_the_restart_not_a_teardown(monkeypatch, tmp_path):
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    gd = _clone(tmp_path)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False,
            declared_bind=gd)
    problems = LocalStackNode(gd).devops_repo_access()
    assert len(problems) == 1
    assert "docker restart hugmesh-local-control-plane" in problems[0]
    # the destructive remedy must NOT be offered for a condition a restart fixes
    assert "kind delete cluster" not in problems[0]
    assert "ARGOCD_REPO_TOKEN" in problems[0]


def test_stale_bind_is_matched_through_a_non_normalised_path(monkeypatch, tmp_path):
    # `docker inspect` reports the path docker recorded, which need not be the
    # spelling the Studio was launched with. Comparing the raw strings would
    # misfile a stale bind as "a different checkout" and send the operator to
    # the teardown after all.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    gd = _clone(tmp_path)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False,
            declared_bind=gd + "/./")
    problems = LocalStackNode(gd).devops_repo_access()
    assert problems and "docker restart" in problems[0]


def test_a_foreign_checkout_bind_names_the_other_path(monkeypatch, tmp_path):
    # Several sessions share checkouts on this machine. A cluster created against
    # a DIFFERENT tree would sync that tree; a restart cannot change which path a
    # container binds, so this one really is a recreate — and the message has to
    # name the other path or the operator recreates into the same mismatch.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    gd = _clone(tmp_path)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False,
            declared_bind="/home/someone/other-generator")
    problems = LocalStackNode(gd).devops_repo_access()
    assert len(problems) == 1
    assert "/home/someone/other-generator" in problems[0]
    assert gd in problems[0]
    assert "kind delete cluster --name hugmesh-local" in problems[0]
    assert "docker restart" not in problems[0]


def test_a_serving_mount_never_asks_docker_inspect(monkeypatch, tmp_path):
    # The inspect is a DIAGNOSIS step, not part of the happy path: a node that
    # can see .git is ready, and spending a docker inspect to confirm it would
    # be pure cost on every single lane start.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=True)
    node = LocalStackNode(_clone(tmp_path))
    monkeypatch.setattr(LocalStackNode, "_kind_repo_bind_source",
                        lambda self, n: (_ for _ in ()).throw(
                            AssertionError("inspect must not run when the mount serves")),
                        raising=True)
    assert node.devops_repo_access() == []


def test_uninspectable_node_falls_back_to_the_recreate(monkeypatch, tmp_path):
    # `docker inspect` failing (daemon gone, node removed under us) must not be
    # read as "the bind is declared" — an unestablished answer stays the
    # conservative one, the same tri-state rule devops_running() follows.
    monkeypatch.delenv("ARGOCD_REPO_TOKEN", raising=False)
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    monkeypatch.setattr(devops_tools, "which", lambda tool, gd: "/fake/bin/kind",
                        raising=True)

    def probe(self, cmd, timeout=15):
        if cmd[0].endswith("kind"):
            return (0, "hugmesh-local")
        if cmd[1] == "exec":
            return (1, "")
        return (1, "Error: No such object: hugmesh-local-control-plane")
    monkeypatch.setattr(LocalStackNode, "_probe", probe, raising=True)
    problems = LocalStackNode(_clone(tmp_path)).devops_repo_access()
    assert len(problems) == 1
    assert "lacks the read-only repo mount" in problems[0]
    assert "kind delete cluster --name hugmesh-local" in problems[0]
    # and the inspect's STDERR must never be paraded as the bind's host path
    assert "No such object" not in problems[0]


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
    _probes(monkeypatch, clusters="hugmesh-local", mount_ok=False,
            declared_bind=None)
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


# ── devops_running: the read-only "is the lane up?" probe (issue #50 item 4) ─
# The "create nodes for local cloud" gate holds Next on this answer before it
# will configure node images against a live cluster, so it is pinned BOTH ways
# here, next to the probes it shares.

def test_devops_running_sees_this_repo_s_cluster(monkeypatch, tmp_path):
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="kind\nhugmesh-local\n")
    assert LocalStackNode(_clone(tmp_path)).devops_running() is True


def test_devops_running_ignores_a_foreign_cluster(monkeypatch, tmp_path):
    # Someone else's kind cluster is not this lane and must never be reported as
    # one — the gate would then demand a teardown that deletes nothing.
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, clusters="some-other-cluster\n")
    assert LocalStackNode(_clone(tmp_path)).devops_running() is False


def test_devops_running_respects_the_cluster_name_override(monkeypatch, tmp_path):
    monkeypatch.setenv("KIND_CLUSTER_NAME", "other-cluster")
    _probes(monkeypatch, clusters="other-cluster\n")
    assert LocalStackNode(_clone(tmp_path)).devops_running() is True


def test_devops_running_is_false_without_kind(monkeypatch, tmp_path):
    # No binary that could have created a cluster -> no cluster. Must not crash
    # probing with nothing to probe with, and must not report "up" from an answer
    # nothing established: that would strand the gate on a page whose Next can
    # never enable.
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    _probes(monkeypatch, kind_installed=False)
    assert LocalStackNode(_clone(tmp_path)).devops_running() is False
