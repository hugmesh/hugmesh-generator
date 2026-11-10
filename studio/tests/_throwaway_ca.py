"""Throwaway certificate authorities for the Domain CA keys tests.

Every CA here is generated fresh in the test's own temp dir and removed with it. No
key in this file, in tests/data or anywhere in the repo: the repo's ``*.pem`` ignore
rule exists to keep key material out, and these keys only ever live for one test.
"""
from __future__ import annotations

import datetime as dt
import os

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

NOW = dt.datetime.now(dt.timezone.utc)


def _name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn),
                      x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Throwaway")])


def key(kind: str = "ec", bits: int = 2048):
    if kind == "rsa":
        return rsa.generate_private_key(public_exponent=65537, key_size=bits)
    if kind == "ed25519":
        return ed25519.Ed25519PrivateKey.generate()
    if kind == "secp256k1":
        return ec.generate_private_key(ec.SECP256K1())
    return ec.generate_private_key(ec.SECP256R1())


def cert(subject_key, cn: str, *, issuer_key=None, issuer_cert=None, ca=True,
         path_length=None, key_cert_sign=True, days=(-1, 3650),
         hash_alg=hashes.SHA256(), basic_constraints=True):
    issuer_name = issuer_cert.subject if issuer_cert is not None else _name(cn)
    signer = issuer_key if issuer_key is not None else subject_key
    b = (x509.CertificateBuilder()
         .subject_name(_name(cn)).issuer_name(issuer_name)
         .public_key(subject_key.public_key())
         .serial_number(x509.random_serial_number())
         .not_valid_before(NOW + dt.timedelta(days=days[0]))
         .not_valid_after(NOW + dt.timedelta(days=days[1])))
    if basic_constraints:
        b = b.add_extension(x509.BasicConstraints(ca=ca, path_length=path_length),
                            critical=True)
    b = b.add_extension(x509.KeyUsage(
        digital_signature=True, content_commitment=False, key_encipherment=False,
        data_encipherment=False, key_agreement=False, key_cert_sign=key_cert_sign,
        crl_sign=key_cert_sign, encipher_only=False, decipher_only=False),
        critical=True)
    if isinstance(signer, ed25519.Ed25519PrivateKey):
        hash_alg = None
    return b.sign(signer, hash_alg)


def pem(c) -> bytes:
    return c.public_bytes(serialization.Encoding.PEM)


def key_pem(k, passphrase: str | None = None, fmt="pkcs8") -> bytes:
    enc = (serialization.BestAvailableEncryption(passphrase.encode())
           if passphrase else serialization.NoEncryption())
    f = (serialization.PrivateFormat.TraditionalOpenSSL if fmt == "traditional"
         else serialization.PrivateFormat.PKCS8)
    return k.private_bytes(serialization.Encoding.PEM, f, enc)


def write(dirpath, name: str, data: bytes) -> str:
    p = os.path.join(str(dirpath), name)
    with open(p, "wb") as fh:
        fh.write(data)
    return p


class Chain:
    """A root + an intermediate signing CA (+ their files) in ``dirpath``."""

    def __init__(self, dirpath, *, kind="ec", tag="t"):
        self.dir = str(dirpath)
        self.root_key = key(kind)
        self.root = cert(self.root_key, f"{tag} Root CA")
        self.signing_key = key(kind)
        self.signing = cert(self.signing_key, f"{tag} Signing CA",
                            issuer_key=self.root_key, issuer_cert=self.root,
                            path_length=0)
        self.root_path = write(dirpath, f"{tag}-root.crt", pem(self.root))
        self.signing_path = write(dirpath, f"{tag}-signing.crt", pem(self.signing))
        self.key_path = write(dirpath, f"{tag}-signing.key", key_pem(self.signing_key))

    def encrypted_key_path(self, passphrase: str) -> str:
        return write(self.dir, "enc.key", key_pem(self.signing_key, passphrase))

    def p12_path(self, passphrase: str | None, *, with_root=True) -> str:
        data = pkcs12.serialize_key_and_certificates(
            b"signing", self.signing_key, self.signing,
            [self.root] if with_root else None,
            serialization.BestAvailableEncryption(passphrase.encode())
            if passphrase else serialization.NoEncryption())
        return write(self.dir, "bundle.p12", data)

    def key_text(self) -> bytes:
        return key_pem(self.signing_key)

    def spki(self) -> bytes:
        return self.signing_key.public_key().public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo)
