"""Repo hygiene: lane/sandbox scaffolding must never be tracked in git.

Regression: a survey lane force-added its exit-127 PATH stubs (``.nobuild-bin/``
— fake ``sudo``, ``docker``, ``emerge``, ``qemu-*`` …) onto a feature branch,
even though ``.gitignore`` ignores the directory. gitignore does not protect
against files that are ALREADY tracked, so merging silently re-added the exact
stub executables main had already scrubbed three times (b108177, b791e01/#490,
fea6b8c). This test makes the leak a red build instead of a review-time catch:
the stubs may exist on disk (lanes rely on them) but never in the index.
"""
import os
import subprocess

import pytest

GENERATOR_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", GENERATOR_DIR, *args],
                          capture_output=True, text=True, timeout=30)


def test_no_sandbox_stub_executables_are_tracked():
    try:
        inside = _git("rev-parse", "--is-inside-work-tree")
    except FileNotFoundError:
        pytest.skip("git not available")
    if inside.returncode != 0 or inside.stdout.strip() != "true":
        pytest.skip("not running from a git checkout")
    tracked = _git("ls-files", "--", ".nobuild-bin")
    assert tracked.returncode == 0, tracked.stderr
    assert tracked.stdout.strip() == "", (
        ".nobuild-bin sandbox stubs are tracked in git (fake sudo/docker/"
        "emerge would land in the repo on merge):\n" + tracked.stdout)
