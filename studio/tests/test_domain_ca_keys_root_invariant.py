"""Domain CA keys, PR #938 round 3: the root-key invariant, root rotation, the
go-live gate on KEYS generation, and collision-free trust-file names.

The invariant (core/domain_ca_keys.py, root_key_invariant_problem): no signing key
whose public half equals ANY held root's (any domain), and no key whose certificate
is self-signed BY SIGNATURE, is ever taken -- on import_signing, on import_root (any
domain), and again in materialize()/args_for before anything is written.

Every test here failed at b723d6fa (the round-2 head). Every CA is a throwaway made in
the test's temp dir (tests/_throwaway_ca.py).
"""
import os
import shutil
import tempfile
from types import SimpleNamespace

import pytest

pytest.importorskip("cryptography")

import _throwaway_ca as tca                                            # noqa: E402
from hugmesh_studio.core import domain_ca_keys as dca                  # noqa: E402
from hugmesh_studio.core import worklist_driver as wd                  # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig            # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402

OWN = "m.example"
X = "x.example"
STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
NEEDS = ("bash", "openssl", "ssh-keygen", "jq", "keytool", "python3")


@pytest.fixture(autouse=True)
def _fresh_store(monkeypatch):
    monkeypatch.setattr(dca, "_STORE", None)


def _sub(tmp_path, name: str) -> str:
    d = tmp_path / name
    d.mkdir()
    return str(d)


def _refused(fn, *needles):
    with pytest.raises(dca.CAImportError) as e:
        fn()
    for n in needles:
        assert n in str(e.value), str(e.value)
    return str(e.value)


def _materialize_refused(st, *needles):
    """materialize() must refuse; were it to return (a regression), its temp dir of
    throwaway key material is still removed before the test fails."""
    made = []

    def call():
        m = dca.materialize(st)
        made.append(m)
        return m
    try:
        return _refused(call, *needles)
    finally:
        for m in made:
            if m is not None:
                m.cleanup()


class _Cross:
    """The finding-1 shape: the mesh's root Ro, another domain's root Rx (self-signed),
    and C, a NORMAL cross-certificate: Rx's subject and Rx's public key, issued and
    signed by Ro. C passes every chain check under Ro; its key is Rx's root key."""

    def __init__(self, d):
        d = str(d)
        self.ro_key, self.rx_key = tca.key(), tca.key()
        self.ro = tca.cert(self.ro_key, "m Root CA")
        self.rx = tca.cert(self.rx_key, "x Root CA")
        self.c = tca.cert(self.rx_key, "x Root CA", issuer_key=self.ro_key,
                          issuer_cert=self.ro, path_length=0)
        self.ro_path = tca.write(d, "ro.crt", tca.pem(self.ro))
        self.rx_path = tca.write(d, "rx.crt", tca.pem(self.rx))
        self.c_path = tca.write(d, "c.crt", tca.pem(self.c))
        self.rx_key_path = tca.write(d, "rx.key", tca.key_pem(self.rx_key))
        self.rx_spki = _spki(self.rx_key)


def _spki(k) -> bytes:
    from cryptography.hazmat.primitives import serialization
    return k.public_key().public_bytes(serialization.Encoding.DER,
                                       serialization.PublicFormat.SubjectPublicKeyInfo)


def _no_rx_key_anywhere(st, x: _Cross):
    """Nothing held, materialized or put on an argv carries Rx's private key."""
    own = st.get(OWN)
    assert own is None or own.key_pem == b""
    m = dca.materialize(st)
    if m is None:
        return
    try:
        assert m.signing_key == ""
        assert "--ca-key" not in m.args_for("pki")
        assert x.rx_spki not in m.spki
    finally:
        m.cleanup()


# ── finding 1: another domain's root key, through a cross-certificate ───────────
def test_a_cross_certificate_of_another_domains_root_is_refused(tmp_path):
    x = _Cross(tmp_path)
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, x.ro_path)
    dca.import_root(st, X, False, x.rx_path)
    assert dca.chain_problem(x.c, x.ro) == ""       # a normal cross-cert, chain-wise
    msg = _refused(lambda: dca.import_signing(st, OWN, True, cert_path=x.c_path,
                                              key_path=x.rx_key_path),
                   "root CA key is never taken", X)
    assert "x Root CA" in msg
    _no_rx_key_anywhere(st, x)


def test_a_cross_certificate_then_the_other_domains_root_is_refused(tmp_path):
    """Reverse order: the own signing CA first (Rx is held nowhere yet, so it is
    taken -- the I4 limit), then Rx on ANOTHER domain's row: refused there."""
    x = _Cross(tmp_path)
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, x.ro_path)
    dca.import_signing(st, OWN, True, cert_path=x.c_path, key_path=x.rx_key_path)
    _refused(lambda: dca.import_root(st, X, False, x.rx_path),
             "root CA key is never taken", "x Root CA")
    assert st.get(X) is None
    # ...and the same root arriving as the root a bundle of that domain carries
    sx_key = tca.key()
    sx = tca.cert(sx_key, "x Signing CA", issuer_key=x.rx_key, issuer_cert=x.rx,
                  path_length=0)
    p = tca.p12(tmp_path, "x.p12", sx_key, sx, extra=[x.rx])
    _refused(lambda: dca.import_signing(st, X, False, p12_path=p),
             "root CA key is never taken")
    assert st.get(X) is None


def test_a_cross_certificate_without_a_root_on_the_own_row_is_refused_too(tmp_path):
    """No own root held at all: Rx held on its row still refuses its key."""
    x = _Cross(tmp_path)
    st = dca.DomainCAStore()
    dca.import_root(st, X, False, x.rx_path)
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=x.c_path,
                                        key_path=x.rx_key_path),
             "root CA key is never taken")
    _no_rx_key_anywhere(st, x)


def test_materialize_and_args_for_are_the_last_gate(tmp_path):
    """A store that reached the invariant-breaking state anyway (here by a direct put,
    past every import) writes NOTHING: no temp dir, no key file, no --ca-key."""
    x = _Cross(tmp_path)
    st = dca.DomainCAStore()
    st.put(dca.DomainCA(domain=OWN, own=True, root_pem=tca.pem(x.ro),
                        signing_pem=tca.pem(x.c), key_pem=tca.key_pem(x.rx_key)))
    st.put(dca.DomainCA(domain=X, own=False, root_pem=tca.pem(x.rx)))
    before = set(os.listdir(tempfile.gettempdir()))
    _materialize_refused(st, "root CA key is never taken")
    after = set(os.listdir(tempfile.gettempdir()))
    assert not [d for d in after - before if d.startswith("hugmesh-domain-ca-")]
    # args_for refuses on its own data too (a hand-made MaterializedCA)
    m = dca.MaterializedCA(root=str(tmp_path), signing_cert="s.crt",
                           signing_key="s.key", spki=(x.rx_spki,),
                           root_spki=(x.rx_spki,))
    _refused(lambda: m.args_for("pki"), "root CA key is never taken")
    assert "--ca-key" not in m.args_for("backend")


# ── finding 2: a "signing CA" signed by its own key, no root held ───────────────
def _self_key_cert(tmp_path):
    """X: subject 'r1 Signing CA', issuer R1, R1's public key, signed by R1's key."""
    r1_key = tca.key()
    r1 = tca.cert(r1_key, "r1 Root CA")
    xc = tca.cert(r1_key, "r1 Signing CA", issuer_key=r1_key, issuer_cert=r1,
                  path_length=0)
    assert xc.issuer != xc.subject
    return (r1_key, r1, xc, tca.write(tmp_path, "x.crt", tca.pem(xc)),
            tca.write(tmp_path, "r1.key", tca.key_pem(r1_key)))


def test_a_signing_ca_signed_by_its_own_key_is_refused_with_no_root_held(tmp_path):
    r1_key, r1, xc, xp, kp = _self_key_cert(tmp_path)
    st = dca.DomainCAStore()
    msg = _refused(lambda: dca.import_signing(st, OWN, True, cert_path=xp,
                                              key_path=kp),
                   "self-signed", "root CA key is never taken")
    assert "names" in msg and "r1 Root CA" in msg       # says why the names lie
    p = tca.p12(tmp_path, "x.p12", r1_key, xc)
    _refused(lambda: dca.import_signing(st, OWN, True, p12_path=p), "self-signed")
    _refused(lambda: dca.import_signing(st, X, False, cert_path=xp), "self-signed")
    assert st.entries() == ()
    assert dca.materialize(st) is None
    # a direct put past the import: materialize still writes nothing
    st.put(dca.DomainCA(domain=OWN, own=True, signing_pem=tca.pem(xc),
                        key_pem=tca.key_pem(r1_key)))
    _materialize_refused(st, "self-signed")


def test_a_real_intermediate_is_not_mistaken_for_self_signed(tmp_path):
    chain = tca.Chain(tmp_path, kind="rsa")
    assert not dca._signed_by_own_key(chain.signing)
    assert dca._signed_by_own_key(chain.root)
    st = dca.DomainCAStore()
    e = dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                           key_path=chain.key_path)
    assert e.key_pem


# ── finding 3: a held root is fixed in every state ──────────────────────────────
@pytest.mark.parametrize("own", [True, False])
def test_a_held_root_without_a_signing_ca_is_not_silently_replaced(tmp_path, own):
    domain = OWN if own else X
    r1 = tca.Chain(_sub(tmp_path, "1"), tag="r1")
    r2 = tca.Chain(_sub(tmp_path, "2"), tag="r2")
    st = dca.DomainCAStore()
    dca.import_root(st, domain, own, r1.root_path)
    held = st.get(domain)
    _refused(lambda: dca.import_root(st, domain, own, r2.root_path),
             "already holds a root", "remove this domain's CA first")
    assert st.get(domain) == held
    assert dca.import_root(st, domain, own, r1.root_path).root_pem == tca.pem(r1.root)
    assert dca.remove(st, domain)
    assert dca.import_root(st, domain, own, r2.root_path).root_pem == tca.pem(r2.root)


# ── finding 4: per-domain trust-file names never collide ────────────────────────
def test_trust_file_names_cannot_collide_or_take_a_reserved_name(tmp_path):
    chain = tca.Chain(tmp_path)
    other = tca.Chain(_sub(tmp_path, "o"), tag="o")
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    dca.import_root(st, "x", False, other.root_path)               # root only
    dca.import_signing(st, "x-root", False, cert_path=other.signing_path)  # signing
    dca.import_root(st, "signing", False, other.root_path)
    dca.import_signing(st, "signing", False, cert_path=other.signing_path)
    dca.import_root(st, "cluster", False, other.root_path)
    dca.import_signing(st, "cluster", False, cert_path=other.signing_path)
    m = dca.materialize(st)
    try:
        names = [n for n, _p in m.trust]
        assert len(set(names)) == len(names), names
        assert len({os.path.basename(p) for _n, p in m.trust}) == len(names)
        for n in names:
            assert n not in ("cluster-ca", "signing-ca"), n
            assert dca._SCRIPT_TRUST_NAME.match(n), n
        assert os.path.basename(m.signing_cert) == "signing-ca.crt"
        assert set(names) == {"cluster-root-ca", "root-ca.x", "ca.x-root",
                              "ca.signing", "root-ca.signing", "ca.cluster",
                              "root-ca.cluster"}
        args = m.args_for("backend")
        assert args.count("--trust-cert") == len(names)
    finally:
        m.cleanup()


def test_a_colliding_or_reserved_name_is_refused_at_import(tmp_path, monkeypatch):
    """The guard behind the scheme: were names ever to collide again (here the
    round-2 scheme, put back), the import refuses with a sentence -- not a
    FileExistsError at build time, and not one domain's CA over another's."""
    monkeypatch.setattr(dca, "trust_name",
                        lambda domain, own, kind: f"{domain or 'mesh'}-{kind}")
    chain = tca.Chain(tmp_path)
    st = dca.DomainCAStore()
    dca.import_root(st, "x", False, chain.root_path)
    _refused(lambda: dca.import_signing(st, "x-root", False,
                                        cert_path=chain.signing_path),
             "'x' and 'x-root'", "certs/x-root-ca.crt", "rename one")
    _refused(lambda: dca.import_signing(st, "signing", False,
                                        cert_path=chain.signing_path),
             "certs/signing-ca.crt", "reserved")
    _refused(lambda: dca.import_signing(st, "cluster", False,
                                        cert_path=chain.signing_path),
             "certs/cluster-ca.crt", "reserved")
    assert [e.domain for e in st.entries()] == ["x"]


def test_a_domain_too_long_for_a_stick_file_name_is_refused(tmp_path):
    chain = tca.Chain(tmp_path)
    long_ = "a" * 63 + "." + "b" * 55                 # a valid DNS name, 119 chars
    _refused(lambda: dca.import_root(dca.DomainCAStore(), long_, False,
                                     chain.root_path),
             "too long", "122 characters")


# ── the go-live checklist gates the KEY on dispatch ─────────────────────────────
def _worklist(roles):
    cfg = ImageConfig(mode="mesh", cluster_domain=OWN, brand="hugmesh")
    return WorklistConfig(base=cfg, entries=[WorklistEntry(role=r, platform="x86")
                                             for r in roles])


class _FakeGen:
    """Stands in for gen-provision-keys.sh: records argv and which CA files EXISTED
    when it ran (the temp dir is gone after)."""

    def __init__(self):
        self.calls = []

    def __call__(self, cmd, *a, **kw):
        files = []
        for arg in cmd:
            path = arg.partition("=")[2] or arg
            if "hugmesh-domain-ca-" in path and os.path.isdir(os.path.dirname(path)):
                files = sorted(f for f in os.listdir(os.path.dirname(path))
                               if not f.startswith("."))
        self.calls.append((list(cmd), files))
        out = cmd[cmd.index("--out") + 1]
        os.makedirs(out, exist_ok=True)
        return SimpleNamespace(stdout=iter(()), wait=lambda: 0)


def _drive(tmp_path, monkeypatch, roles):
    fake = _FakeGen()
    monkeypatch.setattr(wd.subprocess, "Popen", fake)
    wl = _worklist(roles)
    drv = wd.WorklistDriver(str(tmp_path), wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    lines = []
    for i, e in enumerate(wl.entries):
        drv._generate_keys(i, e, lambda _i, ln: lines.append(ln), None)
    return drv, fake, lines


def test_a_not_ready_checklist_places_no_ca_key(tmp_path, monkeypatch):
    chain = tca.Chain(tmp_path)
    st = dca.store()
    # signing CA + key, NO root: the checklist says NOT ready (intermediate without
    # its root), and the step's text says so -- the build must agree
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    cfg = SimpleNamespace(mode="mesh", cluster_domain=OWN, domains=[])
    assert not dca.ready_to_go_live(dca.readiness(cfg, st, ["pki", "backend"]))
    drv, fake, lines = _drive(tmp_path, monkeypatch, ["pki", "backend"])
    pki_calls = [c for c, _f in fake.calls if c[c.index("--role") + 1] == "pki"]
    assert pki_calls == []                           # no generation, so no key placed
    assert drv.results[0].keys_ok is False
    assert any("NOT ready to go live" in ln and "intermediate without its root" in ln
               for ln in lines), lines
    assert not os.path.exists(drv.results[0].keys_path)
    # the backend stick still gets its public certificates, and the key FILE was
    # never even written for it
    (cmd, files), = fake.calls
    assert "--ca-key" not in cmd and "--ca-cert" in cmd
    assert "signing-ca.key" not in files and "signing-ca.crt" in files
    assert drv.results[1].keys_ok is True


def test_a_ready_checklist_places_the_key_on_the_pki_stick(tmp_path, monkeypatch):
    chain = tca.Chain(tmp_path)
    st = dca.store()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    drv, fake, lines = _drive(tmp_path, monkeypatch, ["pki", "backend"])
    (pki, pki_files), (backend, backend_files) = fake.calls
    assert "--ca-key" in pki and "signing-ca.key" in pki_files
    assert "--ca-key" not in backend and "signing-ca.key" not in backend_files
    assert all(r.keys_ok for r in drv.results), lines


def test_an_expiring_signing_ca_places_no_key(tmp_path, monkeypatch):
    chain = tca.Chain(tmp_path)
    k = tca.key()
    soon = tca.cert(k, "soon", days=(-1, 10), issuer_key=chain.root_key,
                    issuer_cert=chain.root, path_length=0)
    st = dca.store()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True,
                       cert_path=tca.write(tmp_path, "soon.crt", tca.pem(soon)),
                       key_path=tca.write(tmp_path, "soon.key", tca.key_pem(k)))
    drv, fake, lines = _drive(tmp_path, monkeypatch, ["pki"])
    assert fake.calls == [] and drv.results[0].keys_ok is False
    assert any("expires in" in ln for ln in lines), lines


def test_certificates_only_or_an_untouched_step_is_not_gated(tmp_path, monkeypatch):
    chain = tca.Chain(tmp_path)
    dca.import_root(dca.store(), X, False, chain.root_path)
    wl = _worklist(["pki"])
    wl.base.domains = [Domain(name=X)]
    fake = _FakeGen()
    monkeypatch.setattr(wd.subprocess, "Popen", fake)
    drv = wd.WorklistDriver(str(tmp_path), wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    drv._generate_keys(0, wl.entries[0], None, None)
    (cmd, files), = fake.calls
    assert "--ca-key" not in cmd and files == ["root-ca.x.example.crt"]
    assert "root-ca.x.example=" in " ".join(cmd)
    assert drv.results[0].keys_ok is True


@pytest.mark.skipif(any(shutil.which(t) is None for t in NEEDS),
                    reason="needs " + ", ".join(NEEDS))
def test_the_script_takes_every_new_trust_name(tmp_path, monkeypatch):
    """gen-provision-keys.sh itself accepts the round-3 names and writes one file per
    domain certificate (the old names made 'x' and 'x-root' share one)."""
    chain = tca.Chain(tmp_path)
    other = tca.Chain(_sub(tmp_path, "o"), tag="o")
    st = dca.store()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_root(st, "x", False, other.root_path)
    dca.import_signing(st, "x-root", False, cert_path=other.signing_path)
    dca.import_root(st, "signing", False, other.root_path)
    dca.import_root(st, "cluster", False, other.root_path)
    wl = _worklist(["backend"])
    wl.base.domains = [Domain(name=n) for n in ("x", "x-root", "signing", "cluster")]
    (tmp_path / "out").mkdir()
    drv = wd.WorklistDriver(GENERATOR_DIR, wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    monkeypatch.setenv("NONINTERACTIVE", "1")
    lines = []
    drv._generate_keys(0, wl.entries[0], lambda _i, ln: lines.append(ln), None)
    assert drv.results[0].keys_ok, "\n".join(lines)[-3000:]
    certs = set(os.listdir(os.path.join(drv.results[0].keys_path, "certs")))
    assert {"cluster-root-ca.crt", "root-ca.x.crt", "ca.x-root.crt",
            "root-ca.signing.crt", "root-ca.cluster.crt"} <= certs, certs
    assert not any(c.endswith(".key") for c in certs), certs
