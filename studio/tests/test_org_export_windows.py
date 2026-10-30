"""Org export from a native Windows Studio (issue #827 group 3). Qt-free, no network.

From Windows the export published a different repository than the source: CRLF line
endings (git archive under Git for Windows' core.autocrlf=true, and text-mode
rewrites), every x bit dropped, links turned into copies and Windows-illegal names
dropped. A second plan for the same domain also crashed, because rmtree could not
delete git's read-only objects.

Each Windows rule is reached through ``osname="nt"``, so it is checked on Linux CI
too; the few tests that need the host's own file system say so.
"""
from __future__ import annotations

import errno
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile

import pytest

from hugmesh_studio.core import org_export as oe


def _tar(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, kind, payload, mode in members:
            ti = tarfile.TarInfo(name)
            ti.mode = mode
            if kind == "sym":
                ti.type, ti.linkname = tarfile.SYMTYPE, payload
                tf.addfile(ti)
            elif kind == "dir":
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(payload)
                tf.addfile(ti, io.BytesIO(payload))
    return buf.getvalue()


class _Runner(oe.Runner):
    """git as _prepare_repo asks it: no origin/HEAD, HEAD names a commit, and the
    archive is the tar given."""

    def __init__(self, tar_bytes):
        self.tar, self.argv = tar_bytes, []

    def run(self, argv, *, cwd=None, env=None, timeout=600):
        self.argv.append(list(argv))
        if "archive" in argv:
            return oe.RunResult(0, self.tar, b"")
        if "rev-parse" in argv:
            return oe.RunResult(0, b"a" * 40 + b"\n", b"")
        return oe.RunResult(1, b"", b"")


MEMBERS = [("mvnw", "file", b"#!/bin/sh\n", 0o755),
           ("README.md", "file", b"hi\n", 0o644),
           ("link", "sym", "README.md", 0o777),
           ("aux.txt", "file", b"x\n", 0o644),
           ("docs/what?.md", "file", b"x\n", 0o644),
           # ntpath reads the first as a drive and the second as climbing out: both
           # were dropped by the inside check before the Windows checks saw them
           ("a:b", "file", b"x\n", 0o644),
           ("x\\..\\..\\y", "file", b"x\n", 0o644),
           # a name Windows can hold that still leaves the folder, here and on Linux
           ("/abs.txt", "file", b"x\n", 0o644)]


def _snap(tmp_path, members, osname="nt"):
    meta: dict = {}
    files = oe._snapshot(_Runner(_tar(members)), str(tmp_path), "HEAD",
                         str(tmp_path / "w"), meta, osname=osname)
    return files, meta


def test_git_archive_hands_over_the_committed_bytes(tmp_path):
    r = _Runner(_tar([MEMBERS[1]]))
    oe._snapshot(r, str(tmp_path), "HEAD", str(tmp_path / "w"))
    archive = next(a for a in r.argv if "archive" in a)
    assert archive[:5] == ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf"]


def test_on_windows_nothing_is_quietly_changed(tmp_path):
    files, meta = _snap(tmp_path, MEMBERS)
    assert files == ["README.md", "mvnw"]
    assert meta["executables"] == ["mvnw"]
    lost = dict(meta["lost"])
    assert set(lost) == {"link", "aux.txt", "docs/what?.md", "a:b", "x\\..\\..\\y",
                         "/abs.txt"}, lost
    assert lost["/abs.txt"] == "a path that leaves the work folder here"
    assert not os.path.lexists(tmp_path / "w" / "link")   # never written as a copy


def test_elsewhere_the_snapshot_is_unchanged(tmp_path):
    _files, meta = _snap(tmp_path, MEMBERS[:2], osname="posix")
    assert meta == {"executables": [], "lost": []}


def test_names_that_differ_only_in_case_are_lost_not_merged(tmp_path):
    # NTFS holds one of README/readme (the second overwrote the first) and cannot hold
    # a file Docs beside a folder docs/: the folder count matched the commit, so the
    # repository was published with the wrong bytes and a file missing
    files, meta = _snap(tmp_path, [("Docs", "file", b"d\n", 0o644),
                                   ("docs", "dir", b"", 0o755),
                                   ("docs/a.txt", "file", b"a\n", 0o644),
                                   ("README", "file", b"upper\n", 0o644),
                                   ("readme", "file", b"lower\n", 0o644),
                                   ("straße", "file", b"s\n", 0o644),
                                   ("STRASSE", "file", b"S\n", 0o644)])
    assert files == ["Docs", "README", "STRASSE", "straße"]
    lost = dict(meta["lost"])
    assert set(lost) == {"docs/a.txt", "readme"}, lost
    assert "differs from README only in case" in lost["readme"]
    assert (tmp_path / "w" / "README").read_bytes() == b"upper\n"
    files, meta = _snap(tmp_path, [("README", "file", b"u\n", 0o644),
                                   ("readme", "file", b"l\n", 0o644)], osname="posix")
    assert meta["lost"] == []


def test_only_ascii_letters_are_folded_without_asking_the_volume():
    # Python's upper() folded µ into Μ and ı into I (two names on NTFS), and refused
    # the repository with a sentence that was not true
    held: dict[str, str] = {}
    for name in ("µ", "ı", "ſ", "ǅ", "Docs/a"):
        assert oe._case_clash(held, name) == "", name
    for name in ("Μ", "I", "S", "Ǆ"):
        assert oe._case_clash(held, name) == "", name
    assert oe._case_clash(held, "docs/b") == "Docs"


@pytest.mark.skipif(os.name != "nt", reason="needs the NTFS upcase table")
def test_the_volume_decides_beyond_ascii(tmp_path):
    # NTFS holds xᾳ and xᾼ as one name (the second overwrote the first), which no
    # Python case mapping predicts; µ and Μ, ı and I it holds as two
    files, meta = _snap(tmp_path, [("xᾳ", "file", b"1\n", 0o644),
                                   ("xᾼ", "file", b"2\n", 0o644),
                                   ("dᾀ", "dir", b"", 0o755),
                                   ("dᾀ/a", "file", b"a\n", 0o644),
                                   ("dᾈ", "dir", b"", 0o755),
                                   ("dᾈ/b", "file", b"b\n", 0o644),
                                   ("µ", "file", b"m\n", 0o644),
                                   ("Μ", "file", b"M\n", 0o644),
                                   ("ı", "file", b"i\n", 0o644),
                                   ("I", "file", b"I\n", 0o644)])
    lost = dict(meta["lost"])
    assert set(lost) == {"xᾼ", "dᾈ/b"}, lost
    assert "only in case" in lost["xᾼ"] and "dᾈ/" in lost["dᾈ/b"]
    assert files == sorted(["xᾳ", "dᾀ/a", "µ", "Μ", "ı", "I"])
    assert (tmp_path / "w" / "xᾳ").read_bytes() == b"1\n"


def test_a_member_windows_could_not_write_is_lost_not_dropped(tmp_path, monkeypatch):
    # a path past MAX_PATH (long paths are off by default), a file held open: the
    # extraction raised and the member was left out of both lists
    real = tarfile.TarFile.extract

    def extract(self, member, path="", *a, **kw):
        if member.name == "deep/run.sh":
            raise OSError(errno.ENAMETOOLONG, "File name too long")
        return real(self, member, path, *a, **kw)
    monkeypatch.setattr(tarfile.TarFile, "extract", extract)
    members = [("deep/run.sh", "file", b"#!/bin/sh\n", 0o755), MEMBERS[1]]
    files, meta = _snap(tmp_path, members)
    assert files == ["README.md"]
    assert [n for n, _ in meta["lost"]] == ["deep/run.sh"]
    assert "could not be written here" in meta["lost"][0][1]
    assert meta["executables"] == []
    _files, meta = _snap(tmp_path, members, osname="posix")
    assert meta["lost"] == []                         # Linux is as it was


@pytest.mark.parametrize("name,bad", [
    ("a/b.txt", False), ("CONTRIBUTING.md", False), ("console.log", False),
    ("con", True), ("x/NUL.txt", True), ("com1", True), ("a:b", True),
    ("trailing.", True), ("space /x", True), ("tab\there", True)])
def test_names_windows_cannot_hold(name, bad):
    assert oe._windows_cannot_hold(name) is bad


# ── the plan of one repository ───────────────────────────────────────────────────────
def _prepare(tmp_path, members, rules=(), osname="nt", rename_map=None):
    src = tmp_path / "src"
    (src / ".git").mkdir(parents=True, exist_ok=True)
    cfg = oe.ExportConfig(domain="mesh.example", org="acmeorg", generator_dir=str(src),
                          rename_map=rename_map or {})
    return oe._prepare_repo(_Runner(_tar(members)), oe.GENERATOR_REPO, cfg, list(rules),
                            str(tmp_path / "out"), [], osname=osname)


def test_a_link_windows_cannot_hold_refuses_the_repository(tmp_path):
    rp = _prepare(tmp_path, [MEMBERS[1], ("link", "sym", "README.md", 0o777)])
    assert rp.action == oe.REFUSED_ON_WINDOWS and rp.blocked
    assert "link: a symbolic link" in rp.notes[0] and "WSL2" in rp.notes[0]
    assert rp.files == 1
    # Linux extracts the link and publishes it: nothing to refuse
    assert _prepare(tmp_path, [MEMBERS[1], ("link", "sym", "README.md", 0o777)],
                    osname="posix").action == ""


def test_a_link_the_export_drops_anyway_is_no_loss(tmp_path):
    # CLAUDE.md -> AGENTS.md and node_modules/.bin/* are left out on Linux too, so
    # leaving them out on Windows publishes the same tree: no refusal
    members = [("AGENTS.md", "file", b"a\n", 0o644),
               ("CLAUDE.md", "sym", "AGENTS.md", 0o777),
               ("node_modules", "dir", b"", 0o755),
               ("node_modules/.bin", "dir", b"", 0o755),
               ("node_modules/.bin/x", "sym", "../x/cli.js", 0o777)]
    rp = _prepare(tmp_path, members)
    assert rp.action == "" and rp.windows_lost == [], rp.notes
    assert rp.files == 1
    # ... and the plan lists them as left out, as the Linux plan does
    assert rp.excluded == ["CLAUDE.md: excluded file name",
                           "node_modules/.bin/x: directory node_modules/"]
    # a link whose fate hangs on its bytes (.npmrc, *.asc) cannot be judged unread
    rp = _prepare(tmp_path, members + [(".npmrc", "sym", "AGENTS.md", 0o777)])
    assert rp.action == oe.REFUSED_ON_WINDOWS
    # ... and the rename map's exclude list still counts
    rp = _prepare(tmp_path, members + [("link", "sym", "AGENTS.md", 0o777)],
                  rename_map={"exclude": ["link"]})
    assert rp.action == ""


def test_a_rewrite_keeps_each_line_ending(tmp_path):
    # a text-mode write on Windows turned every LF into CRLF, and a CRLF into CR CR LF
    rules = [(re.compile("oldtok"), "newtok", "test")]
    rp = _prepare(tmp_path, [("a.txt", "file", b"x oldtok\r\nb\nc\r\n", 0o644)], rules)
    assert rp.rewrites == {"a.txt": 1}
    assert (tmp_path / "out" / "work" / rp.target / "a.txt").read_bytes() \
        == b"x newtok\r\nb\nc\r\n"


def test_the_site_is_written_with_lf(tmp_path):
    cfg = oe.ExportConfig(domain="mesh.example", org="acmeorg")
    site = oe._prepare_site(cfg, [], str(tmp_path), "20261029T000000Z")
    for dirpath, _dirs, names in os.walk(site.workdir):
        for n in names:
            with open(os.path.join(dirpath, n), "rb") as fh:
                assert b"\r\n" not in fh.read(), n


# ── apply: the x bits ────────────────────────────────────────────────────────────────
@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_the_x_bits_reach_the_commit_whatever_the_name(tmp_path):
    # "+build.sh" or "-f" went into the argv bare and the never-force check refused
    # the repository at apply, after the plan had shown it as exportable
    wd = tmp_path / "work" / "acme-x"
    wd.mkdir(parents=True)
    for name in ("mvnw", "+build.sh", "-f", "README.md"):
        (wd / name).write_bytes(b"#!/bin/sh\n")
        os.chmod(wd / name, 0o644)                    # what a Windows folder holds
    rp = oe.RepoPlan(source="hugmesh-x", target="acme-x", org="acmeorg",
                     visibility="private", action="create", workdir=str(wd), files=4,
                     executables=["+build.sh", "-f", "mvnw"])
    cfg = oe.ExportConfig(domain="mesh.example", org="acmeorg", author_name="Test",
                          author_email="test@example.invalid")
    push = tmp_path / "push"
    push.mkdir()
    calls: list[list[str]] = []
    commit, _tree = oe._commit_snapshot(oe.SubprocessRunner(), calls, rp, cfg,
                                        "20261029T000000Z", "snapshot", str(push))
    verbs = [c[1] if c[1] != "-c" else c[3] for c in calls if c[0] == "git"]
    assert verbs.index("update-index") < verbs.index("commit")
    out = subprocess.run(["git", "ls-tree", "-r", commit], cwd=wd, capture_output=True,
                         check=True).stdout.decode()
    modes = {line.split("\t")[1]: line.split()[0] for line in out.splitlines()}
    assert modes == {"+build.sh": "100755", "-f": "100755", "mvnw": "100755",
                     "README.md": "100644"}


# ── removing a work folder ───────────────────────────────────────────────────────────
def test_rmtree_removes_read_only_files(tmp_path):
    # only a Windows host shows the failure (a read-only file in a writable folder
    # unlinks fine on POSIX): this runs in the Windows CI job
    d = tmp_path / "work" / ".git" / "objects" / "ab"
    d.mkdir(parents=True)
    f = d / "cdef"
    f.write_bytes(b"x")
    os.chmod(f, stat.S_IREAD)                         # how git writes its objects
    oe._rmtree(str(tmp_path / "work"))
    assert not (tmp_path / "work").exists()


@pytest.mark.parametrize("osname", ["nt", "posix"])
def test_rmtree_never_chmods_through_a_link(tmp_path, osname):
    # the retry chmodded whatever a failing path named, on every OS: a work folder
    # that was a link to a directory had that directory set to 0700, and the rmtree
    # then returned quietly with nothing deleted
    target = tmp_path / "elsewhere"
    target.mkdir()
    os.chmod(target, 0o755)
    before = stat.S_IMODE(os.stat(target).st_mode)
    link = tmp_path / "work"
    try:
        os.symlink(target, link, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("this host cannot make a symbolic link")
    with pytest.raises(OSError):
        oe._rmtree(str(link), osname=osname)
    assert target.is_dir() and stat.S_IMODE(os.stat(target).st_mode) == before


@pytest.mark.parametrize("osname", ["nt", "posix"])
def test_rmtree_ignore_errors(tmp_path, osname):
    oe._rmtree(str(tmp_path / "gone"), ignore_errors=True, osname=osname)
    with pytest.raises(OSError):
        oe._rmtree(str(tmp_path / "gone"), osname=osname)


def test_off_windows_rmtree_is_the_plain_one(monkeypatch):
    # elsewhere a read-only file in a writable folder deletes fine, and a retry's chmod
    # could only follow a link: nothing but shutil.rmtree runs there
    seen = []
    monkeypatch.setattr(oe.shutil, "rmtree", lambda path, **kw: seen.append((path, kw)))
    oe._rmtree("x", osname="posix")
    oe._rmtree("y", ignore_errors=True, osname="posix")
    assert seen == [("x", {"ignore_errors": False}), ("y", {"ignore_errors": True})]


def _handler_of(monkeypatch):
    """The onexc handler oe._rmtree installs on native Windows, captured unrun."""
    got = {}

    def fake_rmtree(path, onexc=None, onerror=None):
        got["h"] = onexc or (lambda f, p, e: onerror(f, p, (type(e), e, None)))
    monkeypatch.setattr(oe.shutil, "rmtree", fake_rmtree)
    oe._rmtree("ignored", osname="nt")
    return got["h"]


def test_a_refused_delete_of_a_link_inside_the_tree_is_not_chmodded_through(
        tmp_path, monkeypatch):
    # a link INSIDE the folder fails in os.unlink, not in os.path.islink (that is only
    # the folder itself), so only the os.path.islink(p) half of the guard stops the
    # chmod from following it to whatever it names
    target = tmp_path / "elsewhere"
    target.mkdir()
    os.chmod(target, 0o755)
    before = stat.S_IMODE(os.stat(target).st_mode)
    (tmp_path / "work").mkdir()
    link = tmp_path / "work" / "inner"
    try:
        os.symlink(target, link, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("this host cannot make a symbolic link")
    handler = _handler_of(monkeypatch)
    refused = PermissionError(13, "denied", str(link))
    try:
        with pytest.raises(PermissionError) as got:
            handler(os.unlink, str(link), refused)
        assert got.value is refused
        assert stat.S_IMODE(os.stat(target).st_mode) == before
        assert os.path.islink(link)                     # not deleted on a retry either
    finally:
        os.chmod(target, 0o755)


# ── the Terminal line ────────────────────────────────────────────────────────────────
MSI_EXE = r"C:\Users\pat\AppData\Local\HugMesh\Image Studio\hugmesh-studio.exe"


def test_the_terminal_line_names_what_runs_the_cli_here(monkeypatch):
    assert oe._studio_cli("posix") == ["python3", "-m", "hugmesh_studio"]
    # python3 on Windows is usually the Microsoft Store alias
    assert oe._studio_cli("nt") == [sys.executable, "-m", "hugmesh_studio"]
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", MSI_EXE)
    assert oe._studio_cli("nt") == [MSI_EXE.replace("hugmesh-studio.exe",
                                                    "hugmesh-studio-cli.exe")]
    # the Linux tarball has no -cli twin: its one executable takes --org-export
    monkeypatch.setattr(sys, "executable", "/opt/hugmesh-studio/hugmesh-studio")
    assert oe._studio_cli("posix") == ["/opt/hugmesh-studio/hugmesh-studio"]


def test_the_windows_terminal_line_runs_in_powershell(monkeypatch):
    # POSIX quoting single-quoted every backslash path, and a quoted first word is a
    # string expression in PowerShell ("Unexpected token 'org-export'")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", MSI_EXE)
    cfg = oe.ExportConfig(domain="shop.example", org="acme")
    line = oe.cli_command(cfg, "APPLY", config_path=r"C:\Users\pat\it's mine.json",
                          osname="nt")
    cli = MSI_EXE.replace("hugmesh-studio.exe", "hugmesh-studio-cli.exe")
    assert line == (f"& '{cli}' --org-export APPLY --config 'C:\\Users\\pat\\it''s mine.json' "
                    "--domain shop.example --apply")
    assert oe._terminal_line(["x", r"C:\a\b.json", "a b"], "posix") \
        == "x 'C:\\a\\b.json' 'a b'"


def test_a_folder_on_the_windows_line_loses_its_trailing_separators(monkeypatch):
    # Windows PowerShell 5.1 double-quotes a word with a space for the program, so
    # 'C:\My Exports\' arrived as "C:\My Exports\": the backslash escaped the closing
    # quote and --apply became part of an illegal folder name
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", MSI_EXE)
    cfg = oe.ExportConfig(domain="shop.example", org="acme", out_dir="C:\\My Exports\\",
                          source_mode="existing", source_dir="D:\\code\\my src/\\")
    line = oe.cli_command(cfg, "APPLY", osname="nt")
    assert ("--source-dir 'D:\\code\\my src' --source-mode existing" in line
            and line.endswith("--out 'C:\\My Exports' --apply")), line
    # POSIX shells take a trailing separator as typed: that line is unchanged
    posix = oe.cli_command(cfg, "APPLY", osname="posix")
    assert "--out 'C:\\My Exports\\' --apply" in posix, posix


@pytest.mark.parametrize("typed, handed", [
    ("C:\\My Exports\\", "C:\\My Exports"),
    ("C:\\My Exports\\\\/", "C:\\My Exports"),
    ("C:\\", "C:\\"),                       # the drive's root, which C: is not
    ("C:/", "C:/"),
    ("\\", "\\"),
    ("\\\\srv\\my share\\", "\\\\srv\\my share"),   # a share is named without one
    ("\\\\srv\\my share\\sub dir\\", "\\\\srv\\my share\\sub dir"),
    ("C:", "C:"),
    ("rel dir/", "rel dir"),
])
def test_a_windows_folder_keeps_only_a_roots_separator(typed, handed):
    assert oe._line_dir(typed, "nt") == handed
    assert oe._line_dir(typed, "posix") == typed


@pytest.mark.skipif(os.name != "nt" or not shutil.which("powershell"),
                    reason="needs Windows PowerShell")
def test_a_folder_ending_in_a_backslash_does_not_swallow_the_next_word(tmp_path):
    """Windows PowerShell 5.1, the one every Windows has: the folder and the word after
    it reach the program as two words."""
    words = ["-c", "import sys, json; print(json.dumps(sys.argv[1:]))",
             "--out", oe._line_dir("C:\\My Exports\\", "nt"), "--apply"]
    line = oe._terminal_line([sys.executable, *words], osname="nt")
    script = tmp_path / "line.ps1"
    script.write_text(line + "\n", encoding="utf-8-sig")
    out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                          "-File", str(script)], capture_output=True, timeout=60)
    text = out.stdout.decode("utf-8", "replace")
    assert json.loads(text.strip().splitlines()[-1]) == \
        ["--out", "C:\\My Exports", "--apply"], text


@pytest.mark.skipif(os.name != "nt", reason="needs Windows PowerShell")
def test_powershell_hands_the_words_over_unchanged(tmp_path):
    # an interpreter in a folder with a space, standing in for the MSI's console exe
    exe = tmp_path / "Image Studio" / "python.exe"
    exe.parent.mkdir()
    shutil.copy(sys.executable, exe)
    cfg = os.path.join(sys.prefix, "pyvenv.cfg")       # a venv's launcher needs it
    if os.path.isfile(cfg):
        shutil.copy(cfg, exe.parent)
    words = [str(exe), "-c", "import sys, json; print(json.dumps(sys.argv[1:]))",
             r"C:\a b\it's.json", "--domain", "shop.example", "x;y", "$HOME"]
    r = subprocess.run(["powershell", "-NoProfile", "-Command",
                        oe._terminal_line(words, "nt")], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout.strip().splitlines()[-1]) == words[3:]


# ── hand-edited JSON ─────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("encoding", ["utf-8", "utf-8-sig", "utf-16"])
def test_the_export_reads_json_whatever_windows_saved_it_as(tmp_path, encoding):
    # Notepad saves UTF-8 with a BOM and PowerShell's Out-File writes UTF-16: Load
    # config read them, Go Live's Add config and --org-export --config did not
    cfg_path = tmp_path / "export.json"
    cfg_path.write_bytes(json.dumps({"domain": "shop.example", "org": "acme"})
                         .encode(encoding))
    assert oe.load_config(str(cfg_path)).org == "acme"
    assert [c.org for c in oe.candidates_from_file(str(cfg_path))] == ["acme"]
    rm = tmp_path / "rename-map.json"
    rm.write_bytes(json.dumps({"repos": {"hugmesh-a": "acme-a"}}).encode(encoding))
    assert oe.load_rename_map(str(rm))["repos"] == {"hugmesh-a": "acme-a"}


def test_every_powershell_quote_is_doubled_inside_a_quoted_word():
    word = "brand\u2019; Write-Host INJECTED; \u2018x\u201a\u201b'"
    line = oe._terminal_line(["C:\\x\\cli.exe", word], osname="nt")
    inner = line.split(" ", 2)[2]
    assert inner.startswith("'") and inner.endswith("'")
    body = inner[1:-1]
    for q in "'\u2018\u2019\u201a\u201b":
        assert body.count(q) == 2 * word.count(q), (q, line)


@pytest.mark.skipif(os.name != "nt" or not shutil.which("powershell"),
                    reason="needs Windows PowerShell")
def test_the_powershell_line_hands_over_exactly_its_words(tmp_path):
    """Run the line in real PowerShell against python, and read back what it got."""
    import subprocess
    words = ["-c", "import sys, json; print(json.dumps(sys.argv[1:]))",
             "brand\u2019; Write-Host INJECTED; \u2019x", "Magus\u2019 projects", "a'b"]
    line = oe._terminal_line([sys.executable, *words], osname="nt")
    script = tmp_path / "line.ps1"
    script.write_text("[Console]::OutputEncoding = [Text.Encoding]::UTF8\n" + line + "\n",
                      encoding="utf-8-sig")
    out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                          "-File", str(script)], capture_output=True, timeout=60)
    text = out.stdout.decode("utf-8", "replace")
    # an injected Write-Host would print INJECTED on a line of its own
    assert "INJECTED" not in [ln.strip() for ln in text.splitlines()], text
    import json
    # PowerShell 5.1 re-quotes native arguments itself; the words that reach the
    # program are what counts
    assert json.loads(text.strip().splitlines()[-1]) == words[2:], text


@pytest.mark.parametrize("osname", ["posix", "nt"])
def test_a_member_that_fails_part_way_leaves_no_partial_file(tmp_path, monkeypatch, osname):
    real = tarfile.copyfileobj

    def half_then_full_disk(src, dst, length=None, *a, **k):
        dst.write(src.read(4))
        raise OSError(28, "No space left on device")
    tar = _tar([("README.md", "file", b"hi\n", 0o644),
                (".env", "file", b"DB_PASSWORD=hunter2\n", 0o644)])
    calls = {"n": 0}

    def copy(src, dst, length=None, *a, **k):
        calls["n"] += 1
        if calls["n"] == 2:                               # the second member: .env
            return half_then_full_disk(src, dst, length)
        return real(src, dst, length, *a, **k)
    monkeypatch.setattr(tarfile, "copyfileobj", copy)
    wd = tmp_path / "w"
    meta: dict = {}
    files = oe._snapshot(_Runner(tar), str(tmp_path), "HEAD", str(wd), meta, osname=osname)
    assert files == ["README.md"]
    assert not os.path.lexists(wd / ".env"), "a half-written .env would be published"
    if osname == "nt":
        assert [n for n, _why in meta["lost"]] == [".env"]
