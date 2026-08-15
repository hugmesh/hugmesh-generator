"""The cold-build preflight must measure DOCKER'S filesystem, not the checkout's.

WHY THIS TEST EXISTS. `_docker_root_free_gib` gated on `os.path.exists(root)` before
measuring. Docker's data-root is root-owned 0700, so an unprivileged Studio gets
PermissionError walking to it and `exists()` answers **False** — indistinguishable
from "the daemon is remote and the path is not visible here". The probe then fell
back to the generator checkout's filesystem.

On this machine that was two DIFFERENT disks: the checkout lives on /home (668 GiB
free) while docker's data-root is /var/lib/containerd (331 GiB free). Benign at
those numbers, and silently wrong — on a box with a roomy /home and a nearly-full
docker partition the preflight would greenlight a cold build that then fills the
docker disk and dies partway. That is not hypothetical: a filled disk killed this
operator's 56-container mesh on 2026-08-14, every service exiting 255 within a
minute.

So the property under test is not "a number comes back" but "the number describes
the filesystem the build will actually write to".
"""
from __future__ import annotations

import os
import shutil

import pytest

from hugmesh_studio.core.local_stack_node import LocalStackNode

GENERATOR_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _node(monkeypatch, reported_root: str, *, unreadable: set[str] = frozenset()):
    """A node whose `docker info` returns `reported_root`, with `unreadable` paths
    raising PermissionError from disk_usage — the real-world 0700 data-root."""
    node = LocalStackNode(GENERATOR_DIR)
    monkeypatch.setattr(node, "_probe", lambda *a, **k: (0, reported_root))

    real_usage = shutil.disk_usage

    def fake_usage(path):
        if str(path) in unreadable:
            raise PermissionError(13, "Permission denied", str(path))
        return real_usage(path)

    monkeypatch.setattr(shutil, "disk_usage", fake_usage)
    return node


def test_walks_up_to_the_docker_filesystem_when_the_data_root_is_0700(monkeypatch, tmp_path):
    """THE REGRESSION. The data-root itself is unreadable, but its PARENT is on the
    same filesystem — so that is the honest answer, NOT the checkout's disk."""
    parent = tmp_path / "containerd"
    parent.mkdir()
    root = parent / "docker"          # exists in spirit; unreadable in practice
    node = _node(monkeypatch, str(root), unreadable={str(root)})

    got = node._docker_root_free_gib()
    expected = shutil.disk_usage(str(parent)).free / (1024 ** 3)
    # Tolerance, not equality: other processes write to these filesystems while the
    # test runs, so the two reads legitimately differ by a little.
    assert got == pytest.approx(expected, rel=0.05)


def test_does_not_answer_with_the_checkouts_filesystem(monkeypatch, tmp_path):
    """The regression stated as a property, immune to free-space drift: when the
    data-root is unreadable AND sits on a different filesystem from the checkout,
    the answer must describe the DATA-ROOT's disk. Skips when this machine happens
    to have both on one filesystem (then there is nothing to distinguish)."""
    parent = tmp_path / "containerd"
    parent.mkdir()
    root = parent / "docker"
    if os.stat(str(parent)).st_dev == os.stat(GENERATOR_DIR).st_dev:
        pytest.skip("tmp and the checkout share a filesystem here")

    node = _node(monkeypatch, str(root), unreadable={str(root)})
    got = node._docker_root_free_gib()
    checkout = shutil.disk_usage(GENERATOR_DIR).free / (1024 ** 3)
    parent_free = shutil.disk_usage(str(parent)).free / (1024 ** 3)
    assert abs(got - parent_free) < abs(got - checkout), (
        f"answered {got:.1f} GiB, which is closer to the CHECKOUT's disk "
        f"({checkout:.1f}) than to the data-root's ({parent_free:.1f})")


def test_uses_the_data_root_directly_when_it_is_readable(monkeypatch, tmp_path):
    root = tmp_path / "docker"
    root.mkdir()
    node = _node(monkeypatch, str(root))
    expected = shutil.disk_usage(str(root)).free / (1024 ** 3)
    assert node._docker_root_free_gib() == pytest.approx(expected)


def test_falls_back_to_the_checkout_only_when_no_root_is_reported(monkeypatch):
    """A remote daemon reports nothing local. THEN — and only then — the checkout's
    filesystem is the best available proxy."""
    node = LocalStackNode(GENERATOR_DIR)
    monkeypatch.setattr(node, "_probe", lambda *a, **k: (0, ""))
    expected = shutil.disk_usage(GENERATOR_DIR).free / (1024 ** 3)
    assert node._docker_root_free_gib() == pytest.approx(expected)


def test_never_raises_when_nothing_is_measurable(monkeypatch):
    """The preflight must degrade to 0.0 (which REFUSES the build) rather than
    throwing — a probe that explodes would take the whole readiness check with it."""
    node = LocalStackNode(GENERATOR_DIR)
    monkeypatch.setattr(node, "_probe", lambda *a, **k: (1, ""))
    monkeypatch.setattr(shutil, "disk_usage",
                        lambda p: (_ for _ in ()).throw(OSError("nope")))
    assert node._docker_root_free_gib() == 0.0


def test_the_live_probe_names_the_real_docker_filesystem():
    """Belt-and-braces against the ACTUAL daemon on this machine: whatever it
    reports must agree with a direct measurement of that path's filesystem, not
    with the checkout's. Skips cleanly where docker is absent."""
    node = LocalStackNode(GENERATOR_DIR)
    rc, root = node._probe(["docker", "info", "--format", "{{.DockerRootDir}}"])
    if rc != 0 or not root:
        pytest.skip("no local docker daemon")

    probe = root
    while probe:
        try:
            expected = shutil.disk_usage(probe).free / (1024 ** 3)
            break
        except OSError:
            parent = os.path.dirname(probe)
            if parent == probe:
                pytest.skip("docker root not measurable at any ancestor")
            probe = parent

    assert node._docker_root_free_gib() == pytest.approx(expected, rel=0.01)
