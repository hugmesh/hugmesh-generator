"""Domain CA keys, PR #938 follow-ups (refute round 3, two LOW findings).

1. The root-key invariant compared public halves (SPKI) only. A CRAFTED RSA key with
   a held root's modulus ``n`` and another public exponent has a different SPKI, so
   it was taken, and the signing-ca.key written for the pki stick carried the root's
   own ``p`` and ``q``. The same class: an EC root's private scalar reused on another
   curve. Both are refused now, in either import order, and by materialize().
2. Renaming the mesh's own domain onto a row that holds ANOTHER domain's CA silently
   dropped that row's root (``rekey_own`` overwrote it, outside ``_admit``). Now the
   move is refused: nothing is dropped, the checklist says why, and the KEYS step of
   every stick fails with that sentence.

Every CA is a throwaway made in the test's temp dir (tests/_throwaway_ca.py).
"""
import os
from types import SimpleNamespace

import pytest

pytest.importorskip("cryptography")

from cryptography.hazmat.primitives.asymmetric import ec, rsa          # noqa: E402

import _throwaway_ca as tca                                            # noqa: E402
from hugmesh_studio.core import domain_ca_keys as dca                  # noqa: E402
from hugmesh_studio.core import worklist_driver as wd                  # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig            # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402

OWN = "m.example"
X = "x.example"
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _fresh_store(monkeypatch):
    monkeypatch.setattr(dca, "_STORE", None)


def _refused(fn, *needles):
    with pytest.raises(dca.CAImportError) as e:
        fn()
    for n in needles:
        assert n in str(e.value), str(e.value)
    return str(e.value)


def _same_modulus_other_exponent(root_key):
    """The refuter's key: the root's p and q (so its n) under e' = 65539."""
    pn = root_key.private_numbers()
    p, q = pn.p, pn.q
    n = pn.public_numbers.n
    e = 65539
    lam = (p - 1) * (q - 1) // __import__("math").gcd(p - 1, q - 1)
    d = pow(e, -1, lam)
    k = rsa.RSAPrivateNumbers(p=p, q=q, d=d, dmp1=d % (p - 1), dmq1=d % (q - 1),
                              iqmp=pow(q, -1, p),
                              public_numbers=rsa.RSAPublicNumbers(e, n)).private_key()
    assert k.public_key().public_numbers().n == n
    return k


def _shares_one_prime(root_key):
    """A valid RSA key whose modulus shares ONE prime with the root's: knowing it
    factors the root's modulus (gcd), so it is the root's key too."""
    p = root_key.private_numbers().p
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    q = other.private_numbers().p
    e = 65537
    lam = (p - 1) * (q - 1) // __import__("math").gcd(p - 1, q - 1)
    d = pow(e, -1, lam)
    return rsa.RSAPrivateNumbers(p=p, q=q, d=d, dmp1=d % (p - 1), dmq1=d % (q - 1),
                                 iqmp=pow(q, -1, p),
                                 public_numbers=rsa.RSAPublicNumbers(e, p * q)
                                 ).private_key()


class _Crafted:
    """Ro (the mesh's own root) and Rx (another domain's root); ``key`` holds Rx's
    secret under another public half, in a normal intermediate certificate Ro
    issued for it, so every chain check under Ro passes."""

    def __init__(self, d, shape):
        d = str(d)
        if shape == "rsa-same-n":
            self.rx_key = tca.key("rsa")
            self.key = _same_modulus_other_exponent(self.rx_key)
        elif shape == "rsa-shared-prime":
            self.rx_key = tca.key("rsa")
            self.key = _shares_one_prime(self.rx_key)
        else:                                       # EC scalar reused on another curve
            self.rx_key = ec.generate_private_key(ec.SECP256R1())
            scalar = self.rx_key.private_numbers().private_value
            self.key = ec.derive_private_key(scalar, ec.SECP384R1())
        self.ro_key = tca.key("rsa") if shape.startswith("rsa") else tca.key()
        self.ro = tca.cert(self.ro_key, "m Root CA")
        self.rx = tca.cert(self.rx_key, "x Root CA")
        self.signing = tca.cert(self.key, "m Signing CA", issuer_key=self.ro_key,
                                issuer_cert=self.ro, path_length=0)
        assert dca.chain_problem(self.signing, self.ro) == ""   # chain-wise normal
        assert dca._spki(self.key.public_key()) != dca._spki(self.rx_key.public_key())
        self.ro_path = tca.write(d, "ro.crt", tca.pem(self.ro))
        self.rx_path = tca.write(d, "rx.crt", tca.pem(self.rx))
        self.signing_path = tca.write(d, "s.crt", tca.pem(self.signing))
        self.key_path = tca.write(d, "s.key", tca.key_pem(self.key))


SHAPES = ["rsa-same-n", "rsa-shared-prime", "ec-scalar-other-curve"]
NEEDLE = {"rsa-same-n": "same RSA modulus", "rsa-shared-prime": "RSA prime factor",
          "ec-scalar-other-curve": "EC private scalar"}


@pytest.mark.parametrize("shape", SHAPES)
def test_a_key_carrying_another_roots_secret_is_refused_roots_first(tmp_path, shape):
    c = _Crafted(tmp_path, shape)
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, c.ro_path)
    dca.import_root(st, X, False, c.rx_path)
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=c.signing_path,
                                        key_path=c.key_path),
             NEEDLE[shape], "x Root CA", "never taken")
    assert st.get(OWN).key_pem == b"" and st.get(OWN).signing_pem == b""


@pytest.mark.parametrize("shape", SHAPES)
def test_a_key_carrying_another_roots_secret_is_refused_key_first(tmp_path, shape):
    c = _Crafted(tmp_path, shape)
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, c.ro_path)
    dca.import_signing(st, OWN, True, cert_path=c.signing_path, key_path=c.key_path)
    # the reverse order: the other domain's root arrives later
    _refused(lambda: dca.import_root(st, X, False, c.rx_path), NEEDLE[shape])
    assert st.get(X) is None


@pytest.mark.parametrize("shape", SHAPES)
def test_materialize_refuses_a_store_holding_such_a_key(tmp_path, shape):
    """A store poisoned behind the importers' back (put()) never gets a key file."""
    c = _Crafted(tmp_path, shape)
    st = dca.DomainCAStore()
    dca.import_root(st, OWN, True, c.ro_path)
    dca.import_signing(st, OWN, True, cert_path=c.signing_path, key_path=c.key_path)
    st.put(dca.DomainCA(domain=X, own=False, root_pem=tca.pem(c.rx), root_name="rx"))
    made = []
    try:
        _refused(lambda: made.append(dca.materialize(st)), NEEDLE[shape])
    finally:
        for m in made:
            if m is not None:
                m.cleanup()
    assert made == []


@pytest.mark.parametrize("kind", ["rsa", "ec"])
def test_an_unrelated_key_of_the_same_kind_is_still_taken(tmp_path, kind):
    """The new check does not refuse a normal intermediate beside another root."""
    chain = tca.Chain(tmp_path, kind=kind)
    other = tca.key(kind)
    rx_path = tca.write(str(tmp_path), "rx.crt", tca.pem(tca.cert(other, "x Root CA")))
    st = dca.DomainCAStore()
    dca.import_root(st, X, False, rx_path)
    dca.import_root(st, OWN, True, chain.root_path)
    e = dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                           key_path=chain.key_path)
    assert e.key_pem
    m = dca.materialize(st)
    try:
        assert m.signing_key and "--ca-key" in m.args_for("pki")
    finally:
        m.cleanup()


def test_shared_secret_names_each_shape(tmp_path):
    for shape in SHAPES:
        (tmp_path / shape).mkdir()
        c = _Crafted(tmp_path / shape, shape)
        assert NEEDLE[shape] in dca._shared_root_secret(c.key, c.rx_key.public_key())
        assert dca._shared_root_secret(c.key, c.ro_key.public_key()) == ""


# ── finding 2: a rename of the mesh's domain onto a held extra-domain row ────────
def _cfg(own, *extra):
    return SimpleNamespace(mode="mesh", cluster_domain=own,
                           domains=[Domain(name=n) for n in extra])


def _two_roots(tmp_path):
    """Ro + an intermediate it issued for the own domain, and Rx on x.example."""
    chain = tca.Chain(tmp_path, tag="m")
    rx_key = tca.key()
    rx_path = tca.write(str(tmp_path), "rx.crt", tca.pem(tca.cert(rx_key, "x Root CA")))
    st = dca.store()
    dca.import_root(st, OWN, True, chain.root_path)
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    dca.import_root(st, X, False, rx_path)
    return chain, rx_key, st


def test_renaming_the_mesh_domain_onto_a_held_row_keeps_both_cas(tmp_path):
    chain, rx_key, st = _two_roots(tmp_path)
    before = sorted((e.domain, e.own, e.root_pem) for e in st.entries())
    cfg = _cfg(X, X)                     # the operator renames the mesh to x.example
    msg = dca.rekey_own(cfg, st)
    assert "renamed to x.example" in msg and "x Root CA" in msg, msg
    assert "was not moved" in msg and "Remove x.example's CA" in msg, msg
    # nothing moved, nothing lost: Rx is still held, on its own row, as a root
    assert sorted((e.domain, e.own, e.root_pem) for e in st.entries()) == before
    assert st.get(X).root_cert().subject == tca.cert(rx_key, "x Root CA").subject
    # the checklist says so, and is NOT ready (so no key is placed)
    lines = dca.readiness_lines(cfg, st, ["pki"])
    assert lines[0].startswith("NOT ready"), lines
    assert any("[ ]" in ln and "renamed to x.example" in ln for ln in lines), lines
    assert "renamed to x.example" in dca.placement_refusal(cfg, st, ["pki"])
    # and a cross-certificate of Rx is STILL refused (Rx was not dropped)
    cross = tca.cert(rx_key, "x Root CA", issuer_key=chain.root_key,
                     issuer_cert=chain.root, path_length=0)
    cp = tca.write(str(tmp_path), "cross.crt", tca.pem(cross))
    kp = tca.write(str(tmp_path), "rx.key", tca.key_pem(rx_key))
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=cp, key_path=kp),
             "x Root CA")


def test_after_the_other_ca_is_removed_the_rename_goes_through(tmp_path):
    chain, _rx_key, st = _two_roots(tmp_path)
    cfg = _cfg(X, X)
    assert dca.rekey_own(cfg, st)
    assert dca.remove(st, X)
    assert dca.rekey_own(cfg, st) == ""
    (e,) = st.entries()
    assert (e.domain, e.own) == (X, True) and e.key_pem
    assert dca.readiness_lines(cfg, st, ["pki"])[0].startswith("READY")


def test_a_plain_rename_still_follows_the_config(tmp_path):
    chain, _rx_key, st = _two_roots(tmp_path)
    cfg = _cfg("renamed.example", X)
    assert dca.rekey_own(cfg, st) == ""
    assert sorted((e.domain, e.own) for e in st.entries()) == [
        ("renamed.example", True), (X, False)]


def test_the_rename_goes_through_admit(tmp_path, monkeypatch):
    """The move is an import like any other: what _admit refuses is not moved."""
    _chain, _rx_key, st = _two_roots(tmp_path)
    monkeypatch.setattr(dca, "trust_name_problem",
                        lambda entries: "refused by the gate" if any(
                            e.own and e.domain == "renamed.example" for e in entries)
                        else "")
    assert dca.rekey_own(_cfg("renamed.example", X), st) == "refused by the gate"
    assert sorted((e.domain, e.own) for e in st.entries()) == [(OWN, True), (X, False)]


def test_the_keys_step_fails_every_stick_while_the_rename_is_refused(tmp_path,
                                                                     monkeypatch):
    _chain, _rx_key, st = _two_roots(tmp_path)
    calls = []

    def fake(cmd, *a, **kw):
        calls.append(list(cmd))
        os.makedirs(cmd[cmd.index("--out") + 1], exist_ok=True)
        return SimpleNamespace(stdout=iter(()), wait=lambda: 0)
    monkeypatch.setattr(wd.subprocess, "Popen", fake)
    base = ImageConfig(mode="mesh", cluster_domain=X, brand="hugmesh",
                       domains=[Domain(name=X)])
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role=r, platform="x86")
                                            for r in ("pki", "backend")])
    drv = wd.WorklistDriver(str(tmp_path), wl, host=HOST, backend="native",
                            workdir=str(tmp_path / "out"))
    lines = []
    for i, e in enumerate(wl.entries):
        drv._generate_keys(i, e, lambda _i, ln: lines.append(ln), None)
    assert calls == [], calls
    assert [r.keys_ok for r in drv.results] == [False, False]
    assert sum("renamed to x.example" in ln for ln in lines) >= 2, lines
    assert st.get(X) is not None and not st.get(X).own
