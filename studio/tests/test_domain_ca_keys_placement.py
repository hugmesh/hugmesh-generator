"""Domain CA keys: where the material lands on the KEYS sticks, end to end.

Drives the REAL ``WorklistDriver._generate_keys`` -> ``scripts/gen-provision-keys.sh``
with a throwaway CA and reads back every generated KEYS folder:

* the pki stick carries the signing key at certs/cluster-ca.key (what provision_vault
  hands to Vault pki_int) and nowhere else; kubeadm keeps its own CA;
* every other stick carries the public certificates and NO copy of the key, in any
  encoding, anywhere in the folder;
* the key's path reaches the pki call's argv only, no passphrase reaches any argv or
  environment, nothing of the key reaches the log, and the temp copy is gone after;
* an untouched step leaves every call byte-identical.

Plus the script's own guards, run directly.
"""
import os
import shutil
import subprocess

import pytest

pytest.importorskip("cryptography")

from cryptography.hazmat.primitives import serialization               # noqa: E402

import _throwaway_ca as tca                                            # noqa: E402
from hugmesh_studio.core import domain_ca_keys as dca                  # noqa: E402
from hugmesh_studio.core import worklist_driver as wd                  # noqa: E402
from hugmesh_studio.core.config import ImageConfig                     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SCRIPT = os.path.join(GENERATOR_DIR, "scripts", "gen-provision-keys.sh")
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
NEEDS = ("bash", "openssl", "ssh-keygen", "jq", "keytool", "python3")
OWN = "mesh.example"

needs_tools = pytest.mark.skipif(
    any(shutil.which(t) is None for t in NEEDS),
    reason="needs " + ", ".join(t for t in NEEDS if shutil.which(t) is None))


@pytest.fixture(autouse=True)
def _fresh_store(monkeypatch):
    monkeypatch.setattr(dca, "_STORE", None)


def _worklist(roles):
    cfg = ImageConfig(mode="mesh", cluster_domain=OWN, brand="hugmesh")
    return WorklistConfig(base=cfg, entries=[WorklistEntry(role=r, platform="x86")
                                             for r in roles])


def _spki_of_key_pem(block: bytes):
    k = serialization.load_pem_private_key(block, password=None)
    return k.public_key().public_bytes(serialization.Encoding.DER,
                                       serialization.PublicFormat.SubjectPublicKeyInfo)


def _keys_with_spki(folder: str, spki: bytes) -> list[str]:
    """Every file under ``folder`` holding a PEM private key whose public half is
    ``spki`` (the CA key in ANY PEM encoding)."""
    hits = []
    for dirpath, _d, files in os.walk(folder):
        for f in files:
            full = os.path.join(dirpath, f)
            data = open(full, "rb").read()
            for m in dca._PEM_KEY.finditer(data):
                try:
                    if _spki_of_key_pem(m.group(0)) == spki:
                        hits.append(os.path.relpath(full, folder))
                except Exception:
                    continue
    return hits


class _Recorder:
    """Wraps subprocess.Popen: records argv + env, runs the real thing."""

    def __init__(self, real):
        self.real, self.calls = real, []

    def __call__(self, cmd, *a, **kw):
        self.calls.append((list(cmd), dict(kw.get("env") or {})))
        return self.real(cmd, *a, **kw)


def test_node_key_profiles_skip_desktops():
    wl = _worklist(["pki", "backend", "frontend", "edge-ai", "laptop"])
    assert wd.node_key_profiles(wl) == ["pki", "backend", "frontend", "host"]
    assert wd.node_key_profiles(None) is None


@needs_tools
def test_the_ca_key_reaches_the_pki_stick_only(tmp_path, monkeypatch):
    (tmp_path / "ca").mkdir()
    chain = tca.Chain(tmp_path / "ca")
    pw = "only-in-memory-pass"
    st = dca.store()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.encrypted_key_path(pw), passphrase=pw)
    wl = _worklist(["pki", "backend", "frontend", "edge-ai"])
    (tmp_path / "out").mkdir()
    drv = wd.WorklistDriver(GENERATOR_DIR, wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    rec = _Recorder(subprocess.Popen)
    monkeypatch.setattr(wd.subprocess, "Popen", rec)
    monkeypatch.setenv("NONINTERACTIVE", "1")
    lines, keys = [], []
    for i, entry in enumerate(wl.entries):
        drv._generate_keys(i, entry, lambda _i, ln: lines.append(ln),
                           lambda _i, p, ok: keys.append((p, ok)))
    log = "\n".join(lines)
    assert all(ok for _p, ok in keys), log[-3000:]

    signing_der = chain.signing.public_bytes(serialization.Encoding.DER)
    spki = chain.spki()
    for (folder, _ok), entry in zip(keys, wl.entries):
        profile = wd.key_profile(entry.role, entry.platform)
        cert = open(os.path.join(folder, "certs", "cluster-ca.crt"), "rb").read()
        from cryptography import x509
        assert x509.load_pem_x509_certificate(cert).public_bytes(
            serialization.Encoding.DER) == signing_der, folder
        assert os.path.isfile(os.path.join(folder, "certs", "mesh.example-root-ca.crt"))
        assert not os.path.exists(os.path.join(folder, "kubernetes", "pki", "ca.key"))
        found = _keys_with_spki(folder, spki)
        if profile == "pki":
            assert found == [os.path.join("certs", "cluster-ca.key")], found
            assert oct(os.stat(os.path.join(folder, found[0])).st_mode & 0o777) == "0o600"
        else:
            assert found == [], (profile, found)

    # argv / env / log: the key path on the pki call only, no passphrase, no key text
    key_body = chain.key_text().decode().splitlines()[1]
    ca_roots = set()
    for (cmd, env), entry in zip(rec.calls, wl.entries):
        profile = wd.key_profile(entry.role, entry.platform)
        joined = " ".join(cmd)
        assert pw not in joined and pw not in " ".join(env.values())
        assert "CA_KEY_PASS" not in env and "--ca-key-pass" not in cmd
        assert ("--ca-key" in cmd) == (profile == "pki"), (profile, cmd)
        assert ("--ca-key-to-stick" in cmd) == (profile == "pki")
        ca_roots.add(os.path.dirname(cmd[cmd.index("--ca-cert") + 1]))
    assert pw not in log and key_body not in log and "PRIVATE KEY-----" not in log
    for root in ca_roots:
        assert not os.path.exists(root), f"the temp CA copy {root} was left behind"


def test_an_untouched_step_leaves_every_call_byte_identical(tmp_path, monkeypatch):
    calls = []

    class FakeProc:
        stdout = iter(())

        def wait(self):
            return 0

    def fake(cmd, *a, **kw):
        calls.append(list(cmd))
        return FakeProc()

    monkeypatch.setattr(wd.subprocess, "Popen", fake)
    wl = _worklist(["pki", "backend"])
    drv = wd.WorklistDriver(str(tmp_path), wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    for i, e in enumerate(wl.entries):
        drv._generate_keys(i, e, None, None)
    for cmd, e in zip(calls, wl.entries):
        assert cmd == [os.path.join(str(tmp_path), wd.GENKEYS_SCRIPT), "--role",
                       wd.key_profile(e.role, e.platform), "--out",
                       wd.keys_dir(str(tmp_path / "out"), e.id), "--random",
                       "--superdomain", wl.base.effective_superdomain()]


def test_a_misplaced_key_fails_the_keys_step(tmp_path, monkeypatch):
    """The after-the-fact scan: a generator that put the CA key on a worker stick
    fails that stick and removes the folder."""
    chain = tca.Chain(tmp_path)
    st = dca.store()
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)

    class FakeProc:
        stdout = iter(())

        def __init__(self, out):
            os.makedirs(os.path.join(out, "certs"), exist_ok=True)
            with open(os.path.join(out, "certs", "leaked.key"), "wb") as fh:
                fh.write(chain.key_text())

        def wait(self):
            return 0

    def fake(cmd, *a, **kw):
        return FakeProc(cmd[cmd.index("--out") + 1])

    monkeypatch.setattr(wd.subprocess, "Popen", fake)
    wl = _worklist(["backend"])
    drv = wd.WorklistDriver(str(tmp_path), wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    lines = []
    drv._generate_keys(0, wl.entries[0], lambda _i, ln: lines.append(ln), None)
    assert drv.results[0].keys_ok is False
    assert any("domain CA placement" in ln and "certs/leaked.key" in ln for ln in lines)
    assert not os.path.exists(drv.results[0].keys_path)


def test_windows_docker_mounts_the_ca_dir_read_only_and_maps_its_paths(tmp_path):
    chain = tca.Chain(tmp_path)
    st = dca.store()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    m = dca.materialize(st)
    try:
        wl = _worklist(["pki"])
        drv = wd.WorklistDriver(str(tmp_path), wl, host=HOST, backend="docker")
        cmd = drv._genkeys_command("s.sh", "hugmesh",
                                   ["--role", "pki", "--out", r"C:\out\keys-pki",
                                    *m.args_for("pki")], osname="nt", ca_dir=m.root)
        assert f"{m.root}:/ca:ro" in cmd
        tail = cmd[cmd.index("hugmesh-builder") + 1:]
        assert m.root not in " ".join(tail)
        assert "/ca/signing-ca.key" in tail and "/ca/signing-ca.crt" in tail
        assert "mesh.example-root-ca=/ca/mesh.example-root-ca.crt" in tail
    finally:
        m.cleanup()


# ── the script's own guards ──────────────────────────────────────────────────────
def _run(tmp_path, *args, template=None):
    env = dict(os.environ, NONINTERACTIVE="1", BRAND="hugmesh")
    cmd = ["bash", SCRIPT, "--out", str(tmp_path / "keys"), "--random", *args]
    if template:
        cmd += ["--template", template]
    return subprocess.run(cmd, cwd=GENERATOR_DIR, env=env, capture_output=True,
                          text=True, timeout=600)


@needs_tools
def test_script_refuses_the_ca_key_on_a_worker_stick(tmp_path):
    chain = tca.Chain(tmp_path)
    r = _run(tmp_path, "--role", "backend", "--ca-cert", chain.signing_path,
             "--ca-key", chain.key_path, "--ca-key-to-stick")
    assert r.returncode == 1 and "for --role pki only" in r.stderr


@needs_tools
@pytest.mark.parametrize("value, needle", [
    ("x={key}", "holds a PRIVATE KEY"),
    ("cluster-ca={cert}", "reserved"),
    ("../evil={cert}", "lower-case letters"),
    ("nofile", "NAME=FILE"),
])
def test_script_refuses_a_bad_trust_cert(tmp_path, value, needle):
    chain = tca.Chain(tmp_path)
    both = tca.write(tmp_path, "both.pem", tca.pem(chain.root) + chain.key_text())
    r = _run(tmp_path, "--role", "host",
             "--trust-cert", value.format(key=both, cert=chain.root_path))
    assert r.returncode == 1 and needle in r.stderr, r.stderr
    assert not (tmp_path / "keys").exists()          # refused before building


@needs_tools
def test_script_refuses_a_worker_stick_with_any_private_key_in_certs(tmp_path):
    template = tmp_path / "template"
    shutil.copytree(os.path.join(GENERATOR_DIR, "keys-template"), template)
    (template / "certs" / "stray.key").write_bytes(tca.key_pem(tca.key()))
    r = _run(tmp_path, "--role", "host", template=str(template))
    assert r.returncode == 1 and "only the pki stick may carry a CA key" in r.stderr


@needs_tools
def test_script_worker_stick_gets_only_the_certificate_from_a_combined_file(tmp_path):
    chain = tca.Chain(tmp_path)
    combined = tca.write(tmp_path, "combined.pem", tca.pem(chain.signing)
                         + chain.key_text())
    r = _run(tmp_path, "--role", "host", "--ca-cert", combined, "--ca-key",
             chain.key_path)
    assert r.returncode == 0, r.stderr[-2000:]
    out = (tmp_path / "keys" / "certs" / "cluster-ca.crt").read_bytes()
    assert b"PRIVATE KEY" not in out and b"BEGIN CERTIFICATE" in out
    assert "NOT written to a host stick" in r.stderr
    assert _keys_with_spki(str(tmp_path / "keys"), chain.spki()) == []


# ── a killed Studio leaves no key in TMPDIR for good (PR #938 review, finding 4) ──
# materialize() writes the plaintext signing key for one keys call and removes it in
# a finally; a SIGKILL skips the finally. Every private materialize dir now holds an
# owner lock for its whole life (the OS drops it when the process dies, however it
# dies), and the Studio's startup sweep removes the dirs whose owner is gone.
import subprocess as _sp       # noqa: E402
import sys as _sys             # noqa: E402
import time as _time           # noqa: E402

from hugmesh_studio.core import secret_files as sf                    # noqa: E402

_CHILD = r"""
import sys
sys.path[:0] = [sys.argv[1], sys.argv[2]]
from hugmesh_studio.core import domain_ca_keys as dca
from hugmesh_studio.core import secret_files as sf
st = dca.DomainCAStore()
dca.import_root(st, "mesh.example", True, sys.argv[3])
dca.import_signing(st, "mesh.example", True, cert_path=sys.argv[4], key_path=sys.argv[5])
m = dca.materialize(st)
held = sf.materialize([sf.HeldSecretFile("sb_key", "db.key", "/x/db.key",
                                         (("db.key", b"k"),), "0" * 64)])
login, _cleanup = sf.stage_local_pass("pw")
print(m.root, held._root, login.rsplit("/", 1)[0] if "/" in login else login,
      sep="\n", flush=True)
sys.stdin.readline()          # hold until the test kills us
"""


def _child_dirs(tmp_path, chain):
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()
    env = dict(os.environ, TMPDIR=str(tmpdir), TEMP=str(tmpdir), TMP=str(tmpdir))
    proc = _sp.Popen([_sys.executable, "-c", _CHILD, STUDIO_ROOT,
                      os.path.join(STUDIO_ROOT, "tests"), chain.root_path,
                      chain.signing_path, chain.key_path],
                     stdin=_sp.PIPE, stdout=_sp.PIPE, text=True, env=env)
    dirs = [proc.stdout.readline().strip() for _ in range(3)]
    assert all(os.path.isdir(d) for d in dirs), dirs
    return proc, str(tmpdir), dirs


def test_a_killed_studios_key_dirs_are_swept_and_a_live_ones_are_not(tmp_path):
    chain = tca.Chain(tmp_path)
    proc, tmpdir, dirs = _child_dirs(tmp_path, chain)
    try:
        prefixes = sorted(os.path.basename(d).rsplit("-", 1)[0] for d in dirs)
        assert any(p.startswith("hugmesh-domain-ca") for p in prefixes)
        assert any(p.startswith("hugmesh-held-keys") for p in prefixes)
        assert os.path.exists(os.path.join(dirs[0], "signing-ca.key"))
        # the owner is alive: nothing is swept, even with no grace at all
        assert sf.sweep_stale_private_dirs(tmpdir, grace=0) == []
        assert all(os.path.isdir(d) for d in dirs)
    finally:
        proc.kill()                   # SIGKILL: no finally, no atexit in the child
        proc.wait()
    assert all(os.path.isdir(d) for d in dirs)      # the kill left them behind
    assert sorted(sf.sweep_stale_private_dirs(tmpdir, grace=0, dry_run=True)) \
        == sorted(dirs)
    assert all(os.path.isdir(d) for d in dirs)      # a dry run removes nothing
    assert sorted(sf.sweep_stale_private_dirs(tmpdir, grace=0)) == sorted(dirs)
    assert not any(os.path.exists(d) for d in dirs)


def test_the_sweep_leaves_this_processs_live_dirs_and_strangers_alone(tmp_path,
                                                                        monkeypatch):
    chain = tca.Chain(tmp_path)
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()
    monkeypatch.setattr(sf.tempfile, "tempdir", str(tmpdir))
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    m = dca.materialize(st)
    held = sf.materialize([sf.HeldSecretFile("sb_key", "db.key", "/x/db.key",
                                             (("db.key", b"k"),), "0" * 64)])
    try:
        assert os.path.dirname(m.root) == str(tmpdir)
        old = _time.time() - 3600
        # a dir from a Studio that predates the owner lock, an hour old
        legacy = tmpdir / "hugmesh-held-keys-legacy"
        legacy.mkdir(mode=0o700)
        (legacy / "db.key").write_bytes(b"k")
        os.utime(legacy, (old, old))
        # the same, but seconds old: possibly a dir being created right now
        young = tmpdir / "hugmesh-domain-ca-young"
        young.mkdir(mode=0o700)
        # not ours to touch: other names, a plain file, a symlink to a dir
        other = tmpdir / "unrelated-dir"
        other.mkdir()
        os.utime(other, (old, old))
        plain = tmpdir / "hugmesh-domain-ca-plainfile"
        plain.write_bytes(b"x")
        os.utime(plain, (old, old))
        target = tmp_path / "elsewhere"
        target.mkdir()
        os.utime(target, (old, old))      # old and lock-free: only lstat saves it
        link = tmpdir / "hugmesh-domain-ca-link"
        try:
            os.symlink(str(target), str(link))
        except (OSError, NotImplementedError):
            link = None
        for d in (m.root, held._root):
            os.utime(d, (old, old))
        swept = sf.sweep_stale_private_dirs(str(tmpdir))
        assert swept == [str(legacy)]
        assert not legacy.exists()
        for keep in (m.root, held._root, str(young), str(other), str(plain), str(target)):
            assert os.path.exists(keep), keep
        if link is not None:
            assert os.path.islink(str(link))
    finally:
        m.cleanup()
        held.cleanup()
    assert not os.path.exists(m.root) and not os.path.exists(held._root)


def test_the_gui_and_tui_entry_points_sweep_at_startup(monkeypatch):
    calls = []

    class Swept(Exception):
        pass

    def fake_sweep():
        calls.append("sweep")
        raise Swept

    monkeypatch.setattr(sf, "startup_sweep", fake_sweep)
    try:                                 # without the sweep, fail fast, not a GUI
        from hugmesh_studio.gui.qt import QtWidgets

        def no_gui(*_a, **_k):
            raise AssertionError("the GUI started before the startup sweep")
        monkeypatch.setattr(QtWidgets, "QApplication", no_gui)
    except ImportError:
        pass
    from hugmesh_studio import app as app_mod
    with pytest.raises(Swept):           # before any window, any build
        app_mod.main([])
    from hugmesh_studio.tui import app as tui_app
    import io
    monkeypatch.setattr(_sys, "stdin", io.StringIO(""))
    monkeypatch.setattr(_sys, "stdout", io.StringIO())
    with pytest.raises(Swept):
        tui_app.main(["--plain"])
    assert calls == ["sweep", "sweep"]
