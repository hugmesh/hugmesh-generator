"""Domain CA keys (core): imports, refusals, the held record, readiness, placement.

Operator ask (2026-11-09): "we need another section step of the domain config to add
the private keys to the CA so everything is ready to go live in the sticks".

Every CA is a throwaway generated in the test's temp dir (tests/_throwaway_ca.py).
"""
import datetime as dt
import hashlib
import json
import os
import stat
from types import SimpleNamespace

import pytest

pytest.importorskip("cryptography")

import _throwaway_ca as tca                                            # noqa: E402
from hugmesh_studio.core import build_sessions                        # noqa: E402
from hugmesh_studio.core import domain_ca_keys as dca                  # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig            # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402

OWN = "mesh.example"


@pytest.fixture(autouse=True)
def _fresh_store(monkeypatch):
    monkeypatch.setattr(dca, "_STORE", None)


@pytest.fixture
def chain(tmp_path):
    return tca.Chain(tmp_path)


def _cfg(*extra):
    return SimpleNamespace(mode="mesh", cluster_domain=OWN,
                           domains=[Domain(name=n) for n in extra])


def _st():
    return dca.DomainCAStore()


def _import_ok(st, chain, **kw):
    dca.import_root(st, OWN, True, chain.root_path)
    return dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                              key_path=chain.key_path, **kw)


def _refused(fn, *needles):
    with pytest.raises(dca.CAImportError) as e:
        fn()
    for n in needles:
        assert n in str(e.value), str(e.value)
    return str(e.value)


# ── accepted ─────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("kind", ["ec", "rsa"])
def test_a_valid_root_and_signing_pair_is_accepted_and_ready(tmp_path, kind):
    c = tca.Chain(tmp_path, kind=kind)
    st = _st()
    e = _import_ok(st, c)
    assert e.key_pem and e.signing_pem and e.root_pem
    lines = dca.readiness_lines(_cfg(), st, ["pki", "backend"])
    assert lines[0].startswith("READY to go live"), lines
    assert dca.ready_to_go_live(dca.readiness(_cfg(), st, ["pki", "backend"]))


def test_signing_first_then_root_also_chains(chain):
    st = _st()
    e = dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                           key_path=chain.key_path)
    assert any("intermediate" in w for w in e.warnings)
    assert not dca.ready_to_go_live(dca.readiness(_cfg(), st))
    dca.import_root(st, OWN, True, chain.root_path)
    assert dca.ready_to_go_live(dca.readiness(_cfg(), st)), dca.readiness_lines(_cfg(), st)


def test_an_encrypted_key_opens_with_its_passphrase(chain):
    st = _st()
    dca.import_root(st, OWN, True, chain.root_path)
    e = dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                           key_path=chain.encrypted_key_path("correct horse"),
                           passphrase="correct horse")
    assert e.key_pem.startswith(b"-----BEGIN PRIVATE KEY-----")   # decrypted, PKCS#8
    _refused(lambda: dca.import_signing(
        st, OWN, True, cert_path=chain.signing_path,
        key_path=chain.encrypted_key_path("correct horse")), "encrypted", "passphrase")
    _refused(lambda: dca.import_signing(
        st, OWN, True, cert_path=chain.signing_path,
        key_path=chain.encrypted_key_path("correct horse"), passphrase="wrong"),
        "passphrase does not open")


def test_a_traditional_and_a_der_key_and_a_combined_file_are_read(chain, tmp_path):
    from cryptography.hazmat.primitives import serialization
    st = _st()
    trad = tca.write(tmp_path, "trad.key", tca.key_pem(chain.signing_key, fmt="traditional"))
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path, key_path=trad)
    der = tca.write(tmp_path, "k.der", chain.signing_key.private_bytes(
        serialization.Encoding.DER, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()))
    dca.import_signing(st, OWN, True, cert_path=chain.signing_path, key_path=der)
    both = tca.write(tmp_path, "both.pem", tca.pem(chain.signing) + chain.key_text()
                     + tca.pem(chain.root))
    e = dca.import_signing(st, OWN, True, cert_path=both, key_path=both)
    assert e.root_pem == tca.pem(chain.root)          # the self-signed one after it


def test_a_pkcs12_file_with_a_passphrase_brings_key_cert_and_root(chain):
    st = _st()
    e = dca.import_signing(st, OWN, True, p12_path=chain.p12_path("p12 pass"),
                           passphrase="p12 pass")
    assert e.key_pem and e.root_pem == tca.pem(chain.root)
    assert dca.ready_to_go_live(dca.readiness(_cfg(), st))
    _refused(lambda: dca.import_signing(st, OWN, True,
                                        p12_path=chain.p12_path("p12 pass"),
                                        passphrase="nope"), "did not open")


# ── refused, each with a clear message ───────────────────────────────────────────
def test_a_key_that_does_not_match_the_certificate_is_refused(chain, tmp_path):
    other = tca.write(tmp_path, "other.key", tca.key_pem(tca.key()))
    st = _st()
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                                        key_path=other),
             "does not belong to this signing CA certificate")
    assert st.get(OWN) is None                       # nothing held on refusal


def test_a_signing_ca_from_another_root_is_refused(chain, tmp_path):
    other = tca.Chain(tmp_path, tag="other")
    st = _st()
    dca.import_root(st, OWN, True, other.root_path)
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                                        key_path=chain.key_path),
             "was not issued by this root")
    # and the other way round: a held signing CA refuses a root that did not issue it
    st2 = _st()
    dca.import_signing(st2, OWN, True, cert_path=chain.signing_path,
                       key_path=chain.key_path)
    _refused(lambda: dca.import_root(st2, OWN, True, other.root_path),
             "was not issued by this root")
    assert st2.get(OWN).root_pem == b""


def test_a_root_with_the_same_name_but_another_key_is_refused(chain, tmp_path):
    impostor_key = tca.key()
    impostor = tca.cert(impostor_key, "t Root CA")               # same subject
    path = tca.write(tmp_path, "impostor.crt", tca.pem(impostor))
    st = _st()
    dca.import_root(st, OWN, True, path)
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                                        key_path=chain.key_path),
             "did not sign it")


@pytest.mark.parametrize("days, needle", [((-400, -1), "expired on"),
                                          ((2, 400), "not valid until")])
def test_expired_or_not_yet_valid_is_refused(tmp_path, days, needle):
    k = tca.key()
    c = tca.cert(k, "dated", days=days)
    st = _st()
    _refused(lambda: dca.import_signing(
        st, OWN, True, cert_path=tca.write(tmp_path, "c.crt", tca.pem(c)),
        key_path=tca.write(tmp_path, "c.key", tca.key_pem(k))), needle)


@pytest.mark.parametrize("kind, needle", [("rsa1024", "1024-bit RSA key"),
                                          ("secp256k1", "secp256k1 curve"),
                                          ("ed25519", "RSA or ECDSA only")])
def test_a_weak_or_unsupported_key_is_refused(tmp_path, kind, needle):
    k = tca.key("rsa", 1024) if kind == "rsa1024" else tca.key(kind)
    c = tca.cert(k, "weak")
    st = _st()
    _refused(lambda: dca.import_signing(
        st, OWN, True, cert_path=tca.write(tmp_path, "w.crt", tca.pem(c)),
        key_path=tca.write(tmp_path, "w.key", tca.key_pem(k))), needle)


def test_a_sha1_signature_is_refused(tmp_path):
    """cryptography will not SIGN with SHA-1 any more, so openssl makes this one —
    and the refusal must not depend on cryptography being able to name the hash."""
    import shutil
    import subprocess
    if not shutil.which("openssl"):
        pytest.skip("needs openssl to mint a SHA-1 certificate")
    k = tca.key("rsa", 2048)
    kp = tca.write(tmp_path, "s.key", tca.key_pem(k))
    cp = os.path.join(str(tmp_path), "s.crt")
    subprocess.run(["openssl", "req", "-x509", "-new", "-key", kp, "-sha1", "-days",
                    "30", "-subj", "/CN=sha1 ca", "-addext",
                    "basicConstraints=critical,CA:TRUE", "-out", cp],
                   check=True, capture_output=True)
    st = _st()
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=cp, key_path=kp),
             "SHA1", "broken")


@pytest.mark.parametrize("kw, needle", [({"ca": False}, "CA:FALSE"),
                                        ({"basic_constraints": False}, "no basicConstraints"),
                                        ({"key_cert_sign": False}, "keyCertSign")])
def test_a_certificate_that_is_not_a_ca_is_refused(tmp_path, kw, needle):
    k = tca.key()
    c = tca.cert(k, "leaf", **kw)
    st = _st()
    _refused(lambda: dca.import_signing(
        st, OWN, True, cert_path=tca.write(tmp_path, "l.crt", tca.pem(c)),
        key_path=tca.write(tmp_path, "l.key", tca.key_pem(k))), needle)


def test_a_root_that_forbids_intermediates_is_refused(tmp_path):
    rk = tca.key()
    root = tca.cert(rk, "pathlen0 root", path_length=0)
    sk = tca.key()
    signing = tca.cert(sk, "sub", issuer_key=rk, issuer_cert=root)
    st = _st()
    dca.import_root(st, OWN, True, tca.write(tmp_path, "r.crt", tca.pem(root)))
    _refused(lambda: dca.import_signing(
        st, OWN, True, cert_path=tca.write(tmp_path, "s.crt", tca.pem(signing)),
        key_path=tca.write(tmp_path, "s.key", tca.key_pem(sk))), "pathLenConstraint 0")


def test_a_root_key_is_never_taken(chain, tmp_path):
    with_key = tca.write(tmp_path, "root-with-key.pem",
                         tca.pem(chain.root) + tca.key_pem(chain.root_key))
    _refused(lambda: dca.import_root(_st(), OWN, True, with_key),
             "root CA key is never taken")
    _refused(lambda: dca.import_root(_st(), OWN, True, chain.signing_path),
             "not a root")


def test_another_domain_takes_certificates_only(chain):
    st = _st()
    _refused(lambda: dca.import_signing(st, "chat.example", False,
                                        cert_path=chain.signing_path,
                                        key_path=chain.key_path),
             "only the mesh's own domain takes a signing key")
    e = dca.import_signing(st, "chat.example", False, p12_path=chain.p12_path(None))
    assert e.key_pem == b"" and any("was not taken" in w for w in e.warnings)
    e = dca.import_signing(st, "chat.example", False, cert_path=chain.signing_path)
    assert e.key_pem == b"" and e.root_pem == tca.pem(chain.root)


def test_without_python_cryptography_no_key_is_taken(chain, monkeypatch):
    monkeypatch.setattr(dca, "crypto_problem", lambda: "no cryptography here")
    _refused(lambda: dca.import_signing(_st(), OWN, True, cert_path=chain.signing_path,
                                        key_path=chain.key_path), "no cryptography here")


# ── the key never leaks ──────────────────────────────────────────────────────────
def test_the_key_and_passphrase_are_in_no_record_repr_or_message(chain):
    st = _st()
    pw = "pass-phrase-that-must-not-leak"
    dca.import_root(st, OWN, True, chain.root_path)
    e = dca.import_signing(st, OWN, True, cert_path=chain.signing_path,
                           key_path=chain.encrypted_key_path(pw), passphrase=pw)
    key_body = e.key_pem.decode().splitlines()[1]
    blob = json.dumps(st.records()) + repr(st) + repr(e) + "\n".join(
        dca.readiness_lines(_cfg(), st)) + json.dumps(dca.row_cells(_cfg(), st))
    for secret in (pw, key_body, "PRIVATE KEY"):
        assert secret not in blob
    rec = st.records()[0]
    assert set(rec) == {"domain", "own", "key_sha256", "signing_sha256", "root_sha256"}
    assert rec["key_sha256"] == hashlib.sha256(chain.spki()).hexdigest()
    # nothing on the held entry carries the passphrase in any form
    assert all(pw.encode() not in v for v in (e.key_pem, e.signing_pem, e.root_pem))


def test_the_saved_config_and_session_record_never_carry_the_key(chain, tmp_path,
                                                                 monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    cfg = ImageConfig(mode="mesh", cluster_domain=OWN)
    wl = WorklistConfig(base=cfg, entries=[WorklistEntry(role="pki", platform="x86")])
    before = (json.dumps(cfg.to_dict(), sort_keys=True), cfg.to_cli_args(),
              json.dumps(build_sessions.new_session(wl, str(tmp_path)).to_dict(),
                         sort_keys=True))
    assert "held_domain_ca" not in before[2]          # untouched: record unchanged
    e = _import_ok(dca.store(), chain)
    after_cfg = json.dumps(cfg.to_dict(), sort_keys=True)
    assert after_cfg == before[0] and cfg.to_cli_args() == before[1]
    s = build_sessions.new_session(wl, str(tmp_path))
    text = json.dumps(s.to_dict())
    assert e.key_pem.decode().splitlines()[1] not in text
    assert "PRIVATE KEY" not in text and "BEGIN CERTIFICATE" not in text
    assert s.to_dict()["held_domain_ca"] == dca.store().records()
    assert build_sessions.new_session(wl, str(tmp_path), generate_keys=False
                                      ).to_dict().get("held_domain_ca") is None


# ── removal, rotation, restart ───────────────────────────────────────────────────
def test_removal_and_rotation(chain, tmp_path):
    st = _st()
    _import_ok(st, chain)
    old = st.records()
    assert dca.restart_refusal(old, st) == ""
    rotated = tca.Chain(tmp_path, tag="rotated")
    # the held root refuses a signing CA from another chain, and the held signing CA
    # refuses another root: rotation is remove, then import
    _refused(lambda: dca.import_signing(st, OWN, True, cert_path=rotated.signing_path,
                                        key_path=rotated.key_path), "not issued by")
    _refused(lambda: dca.import_root(st, OWN, True, rotated.root_path),
             "remove this domain's CA first")
    # ...unless the new root comes IN the import (a PKCS#12 or a combined file)
    e = dca.import_signing(st, OWN, True, p12_path=rotated.p12_path(None))
    assert e.root_pem == tca.pem(rotated.root)
    assert dca.remove(st, OWN)
    _import_ok(st, rotated)
    assert len(st.entries()) == 1 and st.records() != old
    assert "Import the same CA again" in dca.restart_refusal(old, st)
    assert dca.remove(st, OWN) and st.get(OWN) is None
    assert not dca.remove(st, OWN)
    assert "Build not started" in dca.restart_refusal(old, _st())
    assert dca.restart_refusal([], _st()) == ""


def test_renaming_the_mesh_domain_keeps_its_ca_and_dropping_a_domain_drops_its(chain):
    st = _st()
    cfg = _cfg("chat.example")
    _import_ok(st, chain)
    dca.import_signing(st, "chat.example", False, cert_path=chain.signing_path)
    cfg.cluster_domain = "renamed.example"
    cfg.domains = []
    dca.rekey_own(cfg, st)
    assert [e.domain for e in st.entries()] == ["renamed.example"]


# ── readiness ────────────────────────────────────────────────────────────────────
def test_an_untouched_step_is_not_ready_and_says_why():
    lines = dca.readiness_lines(_cfg("chat.example"), _st())
    assert lines[0].startswith("NOT ready to go live")
    assert any("throwaway self-signed CA" in ln for ln in lines)
    assert any("optional" in ln for ln in lines)


def test_no_pki_stick_in_the_worklist_is_not_ready(chain):
    st = _st()
    _import_ok(st, chain)
    checks = dca.readiness(_cfg(), st, ["backend", "host"])
    assert not dca.ready_to_go_live(checks)
    # the table's Status agrees with the checklist
    assert dca.row_cells(_cfg(), st, ["backend", "host"])[0][4] == "not ready"
    assert dca.row_cells(_cfg(), st, ["pki", "host"])[0][4] == "ready"
    assert any("no stick would carry the key" in c.text for c in checks)


def test_expiring_soon_is_flagged_not_ready(tmp_path):
    k = tca.key()
    c = tca.cert(k, "soon", days=(-1, 10))
    st = _st()
    dca.import_signing(st, OWN, True, cert_path=tca.write(tmp_path, "c.crt", tca.pem(c)),
                       key_path=tca.write(tmp_path, "c.key", tca.key_pem(k)))
    checks = dca.readiness(_cfg(), st)
    assert any("expires in" in c.text and not c.ok for c in checks)


# ── placement ────────────────────────────────────────────────────────────────────
def test_an_empty_store_materializes_nothing():
    assert dca.materialize(_st()) is None


def test_materialized_files_are_private_and_only_pki_gets_the_key(chain):
    st = _st()
    _import_ok(st, chain)
    dca.import_root(st, "chat.example", False, chain.root_path)
    dca.import_signing(st, "chat.example", False, cert_path=chain.signing_path)
    m = dca.materialize(st)
    try:
        assert stat.S_IMODE(os.stat(m.root).st_mode) == 0o700
        for p in m.paths():
            assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
        pki = m.args_for("pki")
        assert pki[:2] == ["--ca-cert", m.signing_cert]
        assert ["--ca-key", m.signing_key] == pki[2:4]
        assert "--ca-key-to-stick" in pki and "--no-kubeadm-ca" in pki
        for profile in ("backend", "frontend", "host", "control-plane-additional",
                        "mesh-extension"):
            a = m.args_for(profile)
            assert m.signing_key not in " ".join(a)
            assert "--ca-key" not in a and "--ca-key-to-stick" not in a
            assert a[:2] == ["--ca-cert", m.signing_cert]
        names = [n for n, _p in m.trust]
        assert names == ["mesh.example-root-ca", "chat.example-ca",
                         "chat.example-root-ca"]
    finally:
        m.cleanup()
    assert not os.path.exists(m.root)


def test_the_scan_catches_a_misplaced_key_in_any_encoding(chain, tmp_path):
    spki = (chain.spki(),)
    pki = tmp_path / "keys-pki"
    (pki / "certs").mkdir(parents=True)
    (pki / "certs" / "cluster-ca.key").write_bytes(chain.key_text())
    assert dca.scan_keys_dir(str(pki), "pki", spki) == []
    (pki / "kubernetes" / "pki").mkdir(parents=True)
    (pki / "kubernetes" / "pki" / "ca.key").write_bytes(
        tca.key_pem(chain.signing_key, fmt="traditional"))
    probs = dca.scan_keys_dir(str(pki), "pki", spki)
    assert probs and "kubernetes/pki/ca.key" in probs[0]
    worker = tmp_path / "keys-backend"
    (worker / "ssh").mkdir(parents=True)
    (worker / "ssh" / "stray").write_bytes(chain.key_text())       # anywhere at all
    assert "ssh/stray" in dca.scan_keys_dir(str(worker), "backend", spki)[0]
    (worker / "ssh" / "stray").unlink()
    (worker / "certs").mkdir()
    (worker / "certs" / "other.key").write_bytes(tca.key_pem(tca.key()))  # any key
    assert "certs/other.key" in dca.scan_keys_dir(str(worker), "backend", spki)[0]
    (worker / "certs" / "other.key").unlink()
    (worker / "certs" / "cluster-ca.crt").write_bytes(tca.pem(chain.signing))
    assert dca.scan_keys_dir(str(worker), "backend", spki) == []


def test_now_is_respected_for_validity(chain):
    later = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=4000)
    _refused(lambda: dca.import_root(_st(), OWN, True, chain.root_path, now=later),
             "expired")
