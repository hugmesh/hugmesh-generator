"""Windows sweep, cluster c8: the Docker probe, org export's Git for Windows refusals and
long paths, and the mesh node's logs before a start. Qt-free, no network.

Each Windows rule is reached through ``osname="nt"`` (or a host built as
``os="windows"``), so it is checked on Linux CI too; the tests that need Git for
Windows or NTFS say so.
"""
from __future__ import annotations

import io
import os
import shutil
import subprocess
import tarfile

import pytest

from hugmesh_studio.core import mesh_node, org_export as oe, platform_info
from hugmesh_studio.core.platform_info import HostInfo


# ── the Docker probe ─────────────────────────────────────────────────────────────────
def _probe(osname, outcome):
    """docker_probe with docker on PATH and ``outcome`` as what `docker info` does."""
    seen: dict = {}

    def run(argv, **kw):
        seen.update(kw, argv=argv)
        if isinstance(outcome, BaseException):
            raise outcome
        return subprocess.CompletedProcess(argv, outcome)
    state = platform_info.docker_probe(osname, which=lambda _n: "docker", run=run)
    return state, seen


def test_a_slow_docker_is_not_reported_as_no_docker():
    # TimeoutExpired was caught as "no docker", and the MSI told a user whose Docker
    # Desktop was running to install it
    slow = subprocess.TimeoutExpired(["docker", "info"], 8)
    assert _probe("nt", slow)[0] == platform_info.DOCKER_TIMEOUT
    assert _probe("nt", 1)[0] == platform_info.DOCKER_DOWN
    assert _probe("nt", 0)[0] == platform_info.DOCKER_OK
    assert platform_info.docker_probe("nt", which=lambda _n: None) \
        == platform_info.DOCKER_MISSING


def test_the_windows_probe_has_no_console_no_pipes_and_time_to_answer():
    # a console per docker.exe from the windowed MSI made `docker info` slow, and
    # com.docker.cli.exe held a captured pipe open past the timeout (8 s became 20-30 s)
    _state, kw = _probe("nt", 0)
    assert "capture_output" not in kw
    assert kw["stdout"] == kw["stderr"] == subprocess.DEVNULL
    assert kw["creationflags"] & 0x08000000                  # CREATE_NO_WINDOW
    assert kw["timeout"] == platform_info.WINDOWS_DOCKER_PROBE_TIMEOUT_S > 8


def test_the_linux_probe_is_unchanged():
    _state, kw = _probe("posix", 0)
    assert kw == {"argv": ["docker", "info"], "capture_output": True, "timeout": 8}
    slow = subprocess.TimeoutExpired(["docker", "info"], 8)
    host = HostInfo(os="linux", is_gentoo=False, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="b",
                    docker_state=_probe("posix", slow)[0])
    assert host.docker_remedy().startswith("Start the daemon (`sudo systemctl start docker`)")
    assert host.summary().endswith("no-docker")


def _windows_host(state):
    return HostInfo(os="windows", is_gentoo=False, has_docker=False, has_bash=False,
                    has_kvm=False, is_root=False, builder_image="b", docker_state=state)


def test_each_windows_docker_state_has_its_own_true_sentence():
    slow = _windows_host(platform_info.DOCKER_TIMEOUT)
    for text in (slow.docker_remedy(), slow.docker_blocker()):
        assert "Install" not in text and "not reachable" not in text, text
        assert "did not answer" in text and "restart the Studio" in text, text
    assert "no-docker" not in slow.summary()
    down = _windows_host(platform_info.DOCKER_DOWN).docker_remedy()
    assert "Install" not in down and "start Docker Desktop" in down
    # only an absent docker.exe (or an unknown state) is told to install it
    assert _windows_host(platform_info.DOCKER_MISSING).docker_remedy() \
        == "Install Docker Desktop and start it."
    assert _windows_host("").docker_remedy() == "Install Docker Desktop and start it."


# ── the mesh node's logs before any start ────────────────────────────────────────────
def test_logs_before_a_start_say_so(tmp_path, monkeypatch):
    # subprocess.run(cwd=<a folder not made yet>) raised WinError 267 ("The directory
    # name is invalid"), shown as the log; the "(no logs ...)" fallbacks never fired
    ran = []
    monkeypatch.setattr(mesh_node.subprocess, "run",
                        lambda *a, **kw: ran.append(a) or subprocess.CompletedProcess(a, 0, "", ""))
    monkeypatch.setattr(mesh_node, "_compose_base", lambda: ["docker", "compose"])
    node = mesh_node.MeshNode(str(tmp_path), workdir=str(tmp_path / "not made yet"))
    text = node.logs(osname="nt")
    assert text == "The mesh node has not been started yet, so it has no logs."
    assert ran == [] and not (tmp_path / "not made yet").exists()
    node.logs(osname="posix")                    # Linux asks compose, as it did
    assert len(ran) == 1


@pytest.mark.skipif(os.name != "nt", reason="WinError 267 is the Windows CreateProcess error")
def test_logs_before_a_start_on_this_windows(tmp_path):
    node = mesh_node.MeshNode(str(tmp_path), workdir=str(tmp_path / "mesh node"))
    assert "WinError" not in node.logs()


# ── org export: a tree Git for Windows refuses ───────────────────────────────────────
def _tar(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, payload in members:
            ti = tarfile.TarInfo(name)
            ti.mode, ti.size = 0o644, len(payload)
            tf.addfile(ti, io.BytesIO(payload))
    return buf.getvalue()


class _Runner(oe.Runner):
    """git as _prepare_repo asks it; ``archive`` answers with ``archive``."""

    def __init__(self, archive, ls_tree=b""):
        self.archive, self.ls_tree, self.argv = archive, ls_tree, []

    def run(self, argv, *, cwd=None, env=None, timeout=600):
        self.argv.append(list(argv))
        if "archive" in argv:
            return self.archive
        if "ls-tree" in argv:
            if self.ls_tree is None:
                return oe.RunResult(128, b"", b"fatal: not a tree object")
            return oe.RunResult(0, self.ls_tree, b"")
        if "rev-parse" in argv:
            return oe.RunResult(0, b"a" * 40 + b"\n", b"")
        return oe.RunResult(1, b"", b"")


def _prepare(tmp_path, runner, osname="nt", rename_map=None):
    src = tmp_path / "src"
    (src / ".git").mkdir(parents=True, exist_ok=True)
    cfg = oe.ExportConfig(domain="mesh.example", org="acmeorg", generator_dir=str(src),
                          rename_map=rename_map or {})
    return oe._prepare_repo(runner, oe.GENERATOR_REPO, cfg, [], str(tmp_path / "out"),
                            [], osname=osname)


def test_git_archive_on_windows_leaves_the_names_to_the_export(tmp_path):
    # core.protectNTFS refused the whole tree over aux.txt, before _windows_cannot_hold
    # could refuse just that repository with the sentence that says why
    ok = oe.RunResult(0, _tar([("README.md", b"hi\n")]), b"")
    for osname, expect in (("nt", True), ("posix", False)):
        r = _Runner(ok)
        oe._snapshot(r, str(tmp_path), "HEAD", str(tmp_path / osname), {}, osname=osname)
        archive = next(a for a in r.argv if "archive" in a)
        assert archive[:5] == ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf"]
        assert ("core.protectNTFS=false" in archive) is expect


REFUSED = oe.RunResult(128, b"", b"error: invalid path 'a:b.txt'\n"
                                 b"fatal: failed to unpack tree object 51f8be55\n")


def test_a_tree_git_for_windows_will_not_read_refuses_that_repository_only(tmp_path):
    # a ':' Git for Windows refuses whatever protectNTFS says: the plan of EVERY
    # repository died with "RuntimeError: git archive main failed ..."
    rp = _prepare(tmp_path, _Runner(REFUSED, b"ok.txt\0a:b.txt\0CON\0x/c:d\0"))
    assert rp.action == oe.REFUSED_ON_WINDOWS and rp.blocked
    # only a ':' stops git reading the tree: CON beside it is not said to
    assert rp.windows_lost == ["a:b.txt: a name Git for Windows refuses to read",
                               "CON: a name Windows cannot hold",
                               "x/c:d: a name Git for Windows refuses to read"]
    assert "WSL2" in rp.notes[0] and "(it refuses the name a:b.txt)" in rp.notes[0]
    assert "rename these files" in rp.notes[0], rp.notes
    assert rp.files == 0
    # the exclude list cannot help (git reads no path of it), so it is not offered
    assert "exclude" not in rp.notes[0]
    # ls-tree failing still names the path git gave
    rp = _prepare(tmp_path, _Runner(REFUSED, None))
    assert rp.windows_lost == ["a:b.txt: a name Git for Windows refuses to read"]
    assert "rename this file" in rp.notes[0], rp.notes
    # elsewhere a failed archive is the error it was
    with pytest.raises(RuntimeError, match="git archive"):
        _prepare(tmp_path, _Runner(REFUSED), osname="posix")


def test_a_name_ntfs_reads_as_dot_git_is_refused(tmp_path):
    # with protectNTFS off for git archive, git~1/ (the .git folder's 8.3 name) would
    # be written to the work folder, and `git add` would refuse it at apply
    meta: dict = {}
    files = oe._snapshot(_Runner(oe.RunResult(0, _tar([("GIT~1/config", b"x\n"),
                                                       ("README.md", b"hi\n")]), b"")),
                         str(tmp_path), "HEAD", str(tmp_path / "w"), meta, osname="nt")
    assert files == ["README.md"]
    assert [n for n, _why in meta["lost"]] == ["GIT~1/config"]


@pytest.mark.parametrize("name", ["CONIN$", "conout$.txt", "x/CONIN$", "LPT0", "lpt0.txt",
                                  "COM0", "COM¹", "lpt³.log"])
def test_the_console_and_reserved_port_names_are_names_windows_cannot_hold(tmp_path, name):
    # with protectNTFS off, git archive handed CONIN$ over: the plan was clean, Python
    # wrote the file, and apply died on "git add ... unable to index file 'CONIN$'"
    meta: dict = {}
    files = oe._snapshot(_Runner(oe.RunResult(0, _tar([(name, b"x\n"),
                                                       ("README.md", b"hi\n")]), b"")),
                         str(tmp_path), "HEAD", str(tmp_path / "w"), meta, osname="nt")
    assert files == ["README.md"]
    assert meta["lost"] == [(name, "a name Windows cannot hold")]


@pytest.mark.parametrize("name", ["CONIN", "conin.txt", "conout$x", "COM10", "lpt1x.txt",
                                  "COM⁴", "x/CONINx"])
def test_names_only_like_a_device_are_still_held(name):
    assert not oe._windows_cannot_hold(name)


def _git(cwd, *args, data=None):
    env = {**os.environ, "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid",
           "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
    return subprocess.run(["git", *args], cwd=cwd, input=data, env=env,
                          capture_output=True, check=True).stdout.decode().strip()


def _commit_of(src, names):
    """A commit of ``names`` made with plumbing: Git for Windows writes trees it will
    not read back."""
    _git(src, "init", "-q")
    blob = _git(src, "hash-object", "-w", "--stdin", data=b"x\n")
    tree = _git(src, "mktree", data="".join(f"100644 blob {blob}\t{n}\n"
                                            for n in names).encode())
    commit = _git(src, "commit-tree", tree, "-m", "m")
    _git(src, "update-ref", "HEAD", commit)


@pytest.mark.skipif(os.name != "nt" or shutil.which("git") is None,
                    reason="needs Git for Windows")
@pytest.mark.parametrize("bad", ["aux.txt", "what?.txt", "trailing.", "a:b.txt", "CONIN$",
                                 "LPT0"])
def test_git_for_windows_refusals_reach_the_windows_sentence(tmp_path, bad):
    src = tmp_path / "src"
    src.mkdir()
    _commit_of(str(src), ["ok.txt", bad])
    rp = _prepare(tmp_path, oe.SubprocessRunner(), osname=None)
    assert rp.action == oe.REFUSED_ON_WINDOWS, rp.notes
    assert bad in rp.notes[0] and "WSL2" in rp.notes[0]
    if bad != "a:b.txt":
        # git read the tree, so the exclude list leaves the name out as on Linux
        rp = _prepare(tmp_path, oe.SubprocessRunner(), osname=None,
                      rename_map={"exclude": [bad]})
        assert rp.action == "" and rp.files == 1, rp.notes


# ── org export: a path past 260 characters ───────────────────────────────────────────
class _AddFails(oe.Runner):
    def __init__(self):
        self.argv = []

    def run(self, argv, *, cwd=None, env=None, timeout=600):
        self.argv.append(list(argv))
        return oe.RunResult(1 if "add" in argv else 0, b"", b"stop here")


def _rp(wd, files):
    return oe.RepoPlan(source="hugmesh-x", target="acme-x", org="acmeorg",
                       visibility="private", action="create", workdir=str(wd), files=files)


CFG = oe.ExportConfig(domain="mesh.example", org="acmeorg", author_name="Test",
                      author_email="test@example.invalid")


@pytest.mark.parametrize("osname, expect", [("nt", True), ("posix", False)])
def test_the_windows_work_repository_takes_long_paths(tmp_path, osname, expect):
    wd = tmp_path / "w"
    wd.mkdir()
    r = _AddFails()
    with pytest.raises(RuntimeError, match="stop here"):
        oe._commit_snapshot(r, [], _rp(wd, 1), CFG, "20261029T000000Z", "m",
                            str(tmp_path), osname=osname)
    longpaths = ["git", "config", "core.longpaths", "true"]
    assert (longpaths in r.argv) is expect
    if expect:                                   # before anything reads the folder
        assert r.argv.index(longpaths) < next(i for i, a in enumerate(r.argv) if "add" in a)


@pytest.mark.skipif(os.name != "nt" or shutil.which("git") is None,
                    reason="needs Git for Windows and NTFS")
def test_a_path_past_260_characters_reaches_the_commit(tmp_path, monkeypatch):
    # Python wrote it (Windows long paths on), `git add` skipped it with exit 0, and
    # apply refused with "holds 4 files but the plan counted 5" and no cause
    empty = tmp_path / "gitconfig"
    empty.write_bytes(b"")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(empty))   # no core.longpaths of the user's
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    wd = tmp_path / "work" / "acme-x"
    deep = wd.joinpath(*["long-directory-name-for-path-length"] * 8)
    try:
        deep.mkdir(parents=True)
        (deep / "file.txt").write_bytes(b"x\n")
    except OSError:
        pytest.skip("Windows long paths are off here: the plan refuses such a path")
    assert len(str(deep / "file.txt")) > 260
    (wd / "README.md").write_bytes(b"hi\n")
    push = tmp_path / "push"
    push.mkdir()
    commit, _tree = oe._commit_snapshot(oe.SubprocessRunner(), [], _rp(wd, 2), CFG,
                                        "20261029T000000Z", "m", str(push))
    listed = subprocess.run(["git", "ls-tree", "-r", "--name-only", commit], cwd=wd,
                            capture_output=True, check=True).stdout.decode().split("\n")
    assert any(n.endswith("/file.txt") for n in listed), listed
