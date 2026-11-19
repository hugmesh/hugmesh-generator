"""The org-export tests' runner never calls a gh that is not their fake (Windows contract).

The fake ``gh`` is a bash script. On native Windows it cannot run, so ``gh repo create
exampleorg/...`` went to whatever gh PATH found next, the real one: the runner's host
check only looks for ``github.com``/``https://``/``git@`` in the arguments, and those
name none. Found 2026-11-18 on Windows 11, where it failed only because the isolated
home had no gh login. Nothing here runs a process: the base runner is replaced by a
recorder, and the decoy gh is an empty file.
"""
import os
import stat

import pytest

from hugmesh_studio.core import org_export as oe
from _org_export_helpers import RecordingRunner


def _decoy_gh(folder):
    """An empty file PATH lookup takes for gh: gh.exe on Windows, an executable gh
    elsewhere."""
    folder.mkdir()
    gh = folder / ("gh.exe" if os.name == "nt" else "gh")
    gh.write_bytes(b"")
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    return gh


@pytest.fixture
def reached(monkeypatch):
    calls = []

    def record(self, argv, *, cwd=None, env=None, timeout=600, input=None):
        calls.append(list(argv))
        return oe.RunResult(0, b"", b"")
    monkeypatch.setattr(oe.SubprocessRunner, "run", record)
    return calls


def test_a_gh_found_outside_the_fake_folder_is_never_run(tmp_path, monkeypatch, reached):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()                       # no runnable fake in it
    _decoy_gh(tmp_path / "real")
    monkeypatch.setenv("PATH", str(tmp_path / "real"))
    runner = RecordingRunner(str(fake_bin), str(tmp_path / "gh"), str(tmp_path / "gh.log"))
    r = runner.run(["gh", "repo", "create", "exampleorg/example-commons", "--public"])
    assert reached == [], "the real gh would have run: " + repr(reached)
    assert r.returncode != 0 and b"refused" in r.stderr, r


def test_git_still_reaches_the_runner(tmp_path, monkeypatch, reached):
    runner = RecordingRunner(str(tmp_path), str(tmp_path / "gh"), str(tmp_path / "gh.log"))
    runner.run(["git", "--version"])
    assert reached == [["git", "--version"]]


@pytest.mark.skipif(os.name == "nt", reason="the fake gh is a bash script")
def test_the_fake_gh_itself_is_run(tmp_path, monkeypatch, reached):
    fake_bin = tmp_path / "bin"
    _decoy_gh(fake_bin)
    monkeypatch.setenv("PATH", str(tmp_path / "elsewhere"))
    runner = RecordingRunner(str(fake_bin), str(tmp_path / "gh"), str(tmp_path / "gh.log"))
    runner.run(["gh", "repo", "view", "exampleorg/example-commons"])
    assert reached == [["gh", "repo", "view", "exampleorg/example-commons"]]
