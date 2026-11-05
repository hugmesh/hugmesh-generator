"""Native-Windows sweep, cluster c1 (2026-10-30): four places where the MSI gave a
false or empty sentence, or a step that could only fail.

* a KEYS USB picked at a drive root (``E:\\``) was held with the name "", so the held
  row and the restart prompt named nothing (core/secret_files.py);
* a domain copy failed with "Filename too long" once the domain name was 40-odd
  characters (the domain is in every path of a copy two or three times), and the
  message was git's last 300 characters, cut mid-word (core/domain_workspaces.py);
* the docker keys step on Windows logged the container's ``/keys/...`` paths and the
  Linux ``sudo ./scripts/make-keys-usb.sh /dev/sdX ...`` advice
  (core/worklist_driver.py);
* the builder image had no keytool, so the pki node's keys always failed there
  (Dockerfile.build).

Most tests pass ``osname`` and so mean the same on either CI job: the "nt" answer is
the fix, the "posix" answer is the Linux control that must not change. The tests with
the real git and a real drive root run on Windows only.
"""
import ntpath
import os
import shutil
import subprocess

import pytest

from hugmesh_studio.core import domain_workspaces as dw
from hugmesh_studio.core import secret_files
from hugmesh_studio.core import worklist_driver as wd
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
windows_only = pytest.mark.skipif(os.name != "nt", reason="native Windows only")


# ── a KEYS USB at a drive root ──────────────────────────────────────────────────
@pytest.fixture
def _fresh_vault(monkeypatch):
    monkeypatch.setattr(secret_files, "_VAULT", secret_files.SecretFileVault())


@pytest.mark.parametrize("picked,name", [
    ("E:\\", "E:\\"),                       # the drive root: named by the root itself
    ("\\\\nas\\keys\\", "\\\\nas\\keys\\"),  # a share's root, likewise
    ("E:\\KEYS", "KEYS"),                   # a folder keeps its basename
    ("C:\\Users\\Jöhn Doe\\KEYS\\", "KEYS"),
])
def test_a_keys_usb_name_on_windows_is_never_empty(picked, name):
    assert secret_files._dir_display_name(picked, osname="nt") == name


def test_a_keys_usb_name_off_windows_is_the_basename():
    assert secret_files._dir_display_name("/media/u/KEYS", osname="posix") == "KEYS"


@windows_only
@pytest.mark.parametrize("spelling", ["/", "\\"])
def test_a_keys_usb_held_at_a_drive_root_names_the_drive(tmp_path, monkeypatch,
                                                         _fresh_vault, spelling):
    """The real hold() at a real drive root (this PC's own, as Qt's directory picker
    returns it: ``C:/``). The key file is faked there: nothing is written to a root."""
    root = os.path.splitdrive(str(tmp_path))[0]
    real_isfile = os.path.isfile

    def isfile(p):
        rel = os.path.normcase(p.replace("/", "\\"))
        return (rel == os.path.normcase(root + "\\Keys\\kernel_key.pem")
                or real_isfile(p))
    monkeypatch.setattr(secret_files.os.path, "isfile", isfile)
    monkeypatch.setattr(secret_files, "_read_capped", lambda p: b"key")
    held = secret_files.vault().hold("keys_usb", root + spelling)
    assert held.name == root + "\\"
    assert held.summary().startswith(root + "\\ · sha256 ")
    assert held.record()["name"] == root + "\\"


# ── domain copies past 260 characters ───────────────────────────────────────────
COMPOSE = """\
services:
  hugmesh-fe-gateway:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-gateway
"""
MESH = "own.example"
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")


def _gen_and_src(tmp_path, with_git=False):
    gen = tmp_path / "gen"
    (gen / "tests" / "stack").mkdir(parents=True)
    (gen / "tests" / "stack" / "compose.local.yaml").write_text(COMPOSE)
    src = tmp_path / "src" / "hugmesh-gateway"
    if with_git:
        src.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(src)], check=True, env=GIT_ENV)
        (src / "README").write_text("gateway")
        subprocess.run(["git", "-C", str(src), "add", "README"], check=True, env=GIT_ENV)
        subprocess.run(["git", "-C", str(src), "commit", "-qm", "init"], check=True,
                       env=GIT_ENV)
    else:
        (src / ".git").mkdir(parents=True)
    return str(gen), str(tmp_path / "src")


def test_a_copy_folder_past_the_windows_limit_is_refused_with_the_remedy():
    dest = "C:\\" + "d" * 230
    said = dw._windows_path_problem(dest, osname="nt")
    assert "233 characters" in said and "260" in said
    assert "shorter domain name" in said and "HUGMESH_STUDIO_STATE_DIR" in said
    assert dw._windows_path_problem("C:\\" + "d" * 200, osname="nt") == ""
    assert dw._windows_path_problem(dest, osname="posix") == ""


def test_the_plan_does_not_offer_a_copy_windows_cannot_hold(tmp_path):
    gen, src = _gen_and_src(tmp_path)
    rows = [Domain(name="a" * 90 + ".example.org")]
    state = str(tmp_path / "state")
    [repo] = dw.plan_workspaces(gen, "existing", src, rows, MESH, state_root=state,
                                osname="nt").domains[0].repos
    assert not repo.can_clone and "260 characters" in repo.reason
    [linux] = dw.plan_workspaces(gen, "existing", src, rows, MESH, state_root=state,
                                 osname="posix").domains[0].repos
    assert linux.can_clone and linux.reason == ""


def test_on_windows_the_real_git_is_told_core_longpaths(monkeypatch):
    seen = []
    monkeypatch.setattr(dw, "_run_git", lambda args, cwd: (seen.append(list(args)), (0, ""))[1])
    run = dw._git_for("nt")
    run(["clone", "--quiet", "--", "a", "b"], None)
    run(["status", "--porcelain"], "b")
    assert seen == [["-c", "core.longpaths=true", "clone", "-c", "core.longpaths=true",
                     "--quiet", "--", "a", "b"],
                    ["-c", "core.longpaths=true", "status", "--porcelain"]]
    assert dw._git_for("posix") is dw._run_git


def test_making_a_copy_on_windows_clones_with_core_longpaths(tmp_path, monkeypatch):
    gen, src = _gen_and_src(tmp_path)
    plan = dw.plan_workspaces(gen, "existing", src, [Domain(name="chat.example.org")],
                              MESH, state_root=str(tmp_path / "state"), osname="nt")
    seen = []

    def fake_git(args, cwd):
        seen.append(list(args))
        if "clone" in args:
            os.makedirs(os.path.join(args[-1], ".git"))
        return 0, ""
    monkeypatch.setattr(dw, "_run_git", fake_git)
    [res] = dw.clone_missing(plan, "chat.example.org", osname="nt")
    assert res.ok, res.message
    assert seen and all(a[:2] == ["-c", "core.longpaths=true"] for a in seen)
    assert seen[0][2:5] == ["clone", "-c", "core.longpaths=true"]


_WIN_GIT_OUT = (
    "Cloning into 'C:/Users/Jöhn Doe/.hugmesh/domain-code/own-mesh/" + "b" * 60
    + ".example.org/hugmesh-gateway." + "b" * 60 + ".example.org'...\n"
    "error: unable to create file C:/Users/Jöhn Doe/.hugmesh/domain-code/own-mesh/"
    + "b" * 60 + ".example.org/hugmesh-gateway." + "b" * 60
    + ".example.org/.git/logs/refs/remotes/x/HEAD: Filename too long\n"
    "fatal: unable to update refs/remotes/x/HEAD")


def test_on_windows_a_failed_git_says_whole_words_and_the_remedy():
    said = dw._git_tail(_WIN_GIT_OUT, osname="nt")
    assert said.startswith("…") and said.endswith(
        "makes every path in it shorter)")
    # no word cut in half: what follows the "…" starts after a space in git's output
    first = said[1:].split()[0]
    assert (" " + first) in _WIN_GIT_OUT
    assert "fatal: unable to update refs/remotes/x/HEAD" in said
    assert "Filename too long\nfatal:" in said      # the line that says why is kept
    assert len(said.split(" (a path in the copy")[0]) <= 300
    assert dw._git_tail("fatal: one\nfatal: two", osname="nt") == "fatal: one\nfatal: two"
    # Linux keeps the slice it always had
    assert dw._git_tail(_WIN_GIT_OUT, osname="posix") == _WIN_GIT_OUT[-300:]


def test_on_windows_a_copy_is_removed_through_its_long_path(monkeypatch):
    seen = []

    def fake_rmtree(path, onexc=None, onerror=None):
        seen.append(path)
        raise PermissionError(13, "denied", path + "\\.git\\objects\\0f\\abc")
    monkeypatch.setattr(dw.shutil, "rmtree", fake_rmtree)
    with pytest.raises(PermissionError) as got:
        dw._rmtree("C:\\Users\\Jöhn Doe\\copy", osname="nt")
    assert seen == ["\\\\?\\C:\\Users\\Jöhn Doe\\copy"]
    # the message still names the plain path the person knows
    assert got.value.filename == "C:\\Users\\Jöhn Doe\\copy\\.git\\objects\\0f\\abc"
    seen.clear()
    with pytest.raises(PermissionError) as got:
        dw._rmtree("\\\\nas\\share\\copy", osname="nt")
    assert seen == ["\\\\?\\UNC\\nas\\share\\copy"]
    assert got.value.filename == "\\\\nas\\share\\copy\\.git\\objects\\0f\\abc"


@windows_only
@pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")
def test_with_the_real_git_a_long_domain_is_copied_and_removed(tmp_path):
    """A 40-character domain under pytest's own (long) temp folder: the copy's
    ``.git/logs/refs/remotes/<domain>/HEAD`` is past 260 characters. Without
    core.longpaths git stopped with "Filename too long"; without the long-path
    removal the copy was left half-deleted."""
    gen, src = _gen_and_src(tmp_path, with_git=True)
    state = str(tmp_path / "s")
    domain = "b" * 28 + ".example.org"
    plan = dw.plan_workspaces(gen, "existing", src, [Domain(name=domain)], MESH,
                              state_root=state)
    [repo] = plan.domains[0].repos
    longest = len(repo.dest) + len("\\.git\\logs\\refs\\remotes\\\\HEAD") + len(domain)
    if not repo.can_clone or longest <= 260:
        pytest.skip(f"this temp folder does not make a long-enough copy ({longest})")
    [res] = dw.clone_missing(plan, domain)
    assert res.ok, res.message
    # the domain left the mesh: its copy is extra, a plain clone, and goes in one piece
    plan = dw.plan_workspaces(gen, "existing", src, [Domain(name="other.example")],
                              MESH, state_root=state)
    [extra] = [x for x in plan.extras() if x.path == repo.dest]
    removed = dw.remove_extra(extra, plan)
    assert removed.removed, removed.message
    assert not os.path.exists(repo.dest)


# ── the docker keys step's log on Windows ───────────────────────────────────────
def _drv(tmp_path, backend="docker"):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal",
                       output_dir=str(tmp_path / "out keys"))
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86")])
    host = HostInfo(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    return wd.WorklistDriver(str(tmp_path), wl, host=host, backend=backend)


def _container_lines(name):
    return [
        "==> Building /keys/" + name + " from keys-template (role=pki)\n",
        "    pki:/keys/" + name + "/certs/cluster-ca.crt        -> certs/cluster-ca.crt\n",
        "Next:\n",
        "  1. Review /keys/" + name + "/provision.json\n",
        "  2. sudo ./scripts/make-keys-usb.sh /dev/sdX /keys/" + name + "\n",
        "  3. ssh -i /keys/" + name + "/ssh/admin_ed25519 <user>@<node-address>\n",
    ]


def _fake_popen(monkeypatch, lines, code=0):
    calls = []

    class Proc:
        def __init__(self, cmd):
            self.stdout = iter(lines)

        def wait(self):
            return code

    def popen(cmd, **kw):
        calls.append(list(cmd))
        return Proc(cmd)
    monkeypatch.setattr(wd.subprocess, "Popen", popen)
    return calls


def test_on_windows_the_keys_log_names_the_real_folder_and_no_sudo(tmp_path, monkeypatch):
    drv = _drv(tmp_path)
    out = wd.keys_dir(drv._output_dir(), drv.worklist.entries[0].id)
    name = ntpath.basename(ntpath.abspath(out))
    _fake_popen(monkeypatch, _container_lines(name))
    got = []
    drv._generate_keys(0, drv.worklist.entries[0], lambda i, s: got.append(s), None,
                       osname="nt")
    host = ntpath.abspath(out)
    log = "\n".join(got)
    assert "/keys/" not in log and "sudo" not in log and "/dev/sd" not in log, log
    assert f"  1. Review {host}\\provision.json" in got
    assert f"    pki:{host}\\certs\\cluster-ca.crt        -> certs/cluster-ca.crt" in got
    assert f"  3. ssh -i {host}\\ssh\\admin_ed25519 <user>@<node-address>" in got
    [step2] = [s for s in got if s.startswith("  2. ")]
    assert "volume label KEYS" in step2 and host in step2 and "vault-seed" in step2
    assert "cannot run on Windows" in step2
    # FAT32 is what make-keys-usb.sh makes and every node kernel mounts; exFAT only
    # x86/rpi5 do, so it must never be offered as an option.
    assert "as FAT32" in step2 and "32 GB or less" in step2
    assert "FAT32 or exFAT" not in step2 and "not exFAT" in step2


def test_off_windows_the_keys_log_is_the_scripts_own(tmp_path, monkeypatch):
    for osname, backend in (("posix", "docker"), ("nt", "native")):
        drv = _drv(tmp_path, backend)
        lines = _container_lines("keys-pki.x86")
        _fake_popen(monkeypatch, lines)
        got = []
        drv._generate_keys(0, drv.worklist.entries[0], lambda i, s: got.append(s), None,
                           osname=osname)
        assert got == [ln.rstrip("\n") for ln in lines]


def test_a_builder_image_without_keytool_is_named_with_the_rebuild(tmp_path, monkeypatch):
    drv = _drv(tmp_path)
    _fake_popen(monkeypatch, ["==> Generating per-API JKS keystores\n",
                              "ERROR: need keytool\n"], code=1)
    got = []
    drv._generate_keys(0, drv.worklist.entries[0], lambda i, s: got.append(s), None,
                       osname="nt")
    [said] = [s for s in got if "has no keytool" in s]
    assert "hugmesh-builder" in said
    assert "docker build -f Dockerfile.build -t hugmesh-builder ." in said
    assert drv.results[0].keys_ok is False


# ── keytool in the builder image ────────────────────────────────────────────────
@pytest.mark.skipif(not os.path.isfile(os.path.join(_REPO, "Dockerfile.build")),
                    reason="not a hugmesh-generator checkout")
def test_the_builder_image_installs_keytool_for_the_pki_keystores():
    with open(os.path.join(_REPO, "Dockerfile.build"), encoding="utf-8") as fh:
        text = fh.read()
    final = text.split("AS final", 1)[1]
    runs = [r for r in final.split("\nRUN ")[1:] if "emerge" in r]
    assert any("dev-java/openjdk-bin" in r and "command -v keytool" in r for r in runs)
    # what needs it: gen-keystores.sh still refuses without keytool
    with open(os.path.join(_REPO, "scripts", "gen-keystores.sh"), encoding="utf-8") as fh:
        assert "for t in openssl keytool" in fh.read()


def test_the_genkeys_docstring_names_keytool():
    assert "keytool" in wd.WorklistDriver._genkeys_command.__doc__
