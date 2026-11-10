"""Domain CA keys: the certificate authorities whose keys and certificates go onto the
KEYS sticks, so a mesh is ready to go live from its sticks.

OPERATOR ASK (verbatim, 2026-11-09): "we need another section step of the domain
config to add the private keys to the CA so everything is ready to go live in the
sticks".

What was missing before this step (measured on origin/main 7e4a5c14):

* no Studio surface took a CA private key, and the Studio's KEYS path
  (``WorklistDriver._generate_keys``) called ``gen-provision-keys.sh`` with no CA at
  all, so each pki stick minted its own throwaway self-signed cluster CA;
* even a CA supplied through brand.conf never put ``certs/cluster-ca.key`` on the pki
  stick, so ``provision_vault`` found only half a pair and Vault's ``pki_int`` made
  its own DEV root, which nothing chains to;
* no worker, frontend or host stick received the cluster CA certificate: the script
  printed "copy certs/cluster-ca.crt from the pki node" and left it to the operator.

What this step does, per domain:

* **The mesh's own domain** (``cfg.cluster_domain``): a ROOT certificate (public
  only) and a SIGNING CA (the cluster CA: certificate + private key). The signing key
  goes to the **pki stick only**, as ``certs/cluster-ca.key``, which is the file
  ``provision_vault`` imports as Vault ``pki_int``'s signing CA. Every stick, the pki
  stick included, gets the public certificates.
* **Every other domain** (``cfg.domains``): public certificates only. No node
  consumes an extra domain's CA key today (Vault signs for the mesh's own domain
  only, and gen-keystores' multi-domain layout would move the own domain's CA off the
  path Vault reads), so taking one would be a knob that does nothing.

What it deliberately does NOT take, and why (shown on both faces, :data:`NOT_TAKEN`):
a root CA private key (the root stays offline), the Secure Boot key, the device
registry signing key, a headscale key and public edge TLS.

Safety rules (each one pinned by a test):

* a key is decrypted IN MEMORY at import; the passphrase is a local variable of
  :func:`import_signing` and is never stored, written, logged or put on argv/env;
* the unencrypted key lives only in this process (:class:`DomainCAStore`) and, for
  one build run, in a 0600 file under a 0700 temp dir (:func:`materialize`);
* the store's persistable form (:meth:`DomainCA.record`) carries fingerprints only;
* the pki stick is the only stick a CA key is written to, and
  :func:`scan_keys_dir` checks every generated KEYS folder after the fact;
* validation REFUSES (it does not warn and proceed like gen-keystores.sh does): a
  key that does not match its certificate, a certificate that is not a CA, an
  expired or not-yet-valid certificate, a weak key or signature, and a signing CA
  that the given root did not issue.

python-cryptography is OPTIONAL for the Studio (not in requirements.txt; the MSI is
a PyInstaller freeze without it). Without it a CA key cannot be checked, so this step
refuses to take one and says why (:func:`crypto_problem`). Nothing falls back to an
unchecked key.

Qt-free by construction: the GUI page, the TUI screen, the CLI and the worklist
driver all call this module.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import os
import re
import shutil
import tempfile
import threading
from dataclasses import dataclass, field, replace

from .secret_files import MAX_HELD_BYTES, _write_0600

# ── face-independent text (both faces render these exact strings) ─────────────────
STEP_SLUG = "domain_ca_keys"
STEP_TITLE = "Domain CA keys"
STEP_SUBTITLE = ("Add each domain's certificate authority so every KEYS stick is "
                 "ready to go live. The signing key goes to the pki stick only; "
                 "every other stick gets the public certificates.")

#: The table both faces show, one row per domain.
TABLE_HEADERS = ("Domain", "Root CA certificate", "Signing CA certificate",
                 "Signing key", "Status")

#: What the step deliberately does not take, with the reason (both faces).
NOT_TAKEN = (
    ("Root CA private key",
     "the root stays offline; import its certificate, and an intermediate signed "
     "by it as the signing CA"),
    ("Secure Boot signing key", "held on the Build step (Secure Boot)"),
    ("Device registry signing key", "lives in the BFF and Vault, never on a stick"),
    ("headscale key", "there is no CA; each node mints its own noise key at first boot"),
    ("Public edge TLS",
     "Let's Encrypt or cloudflared, set in the device's go-live wizard"),
)

#: Thresholds (stated in the PR and on refusal).
MIN_RSA_BITS = 2048
ALLOWED_EC_CURVES = ("secp256r1", "secp384r1", "secp521r1")
EXPIRY_WARN_DAYS = 30

#: KEYS profile that carries the signing key (gen-provision-keys.sh --role pki).
KEY_PROFILE = "pki"
#: Where the signing key lands on the pki stick (provision_vault reads exactly this).
STICK_KEY_PATH = "certs/cluster-ca.key"
STICK_SIGNING_CERT_PATH = "certs/cluster-ca.crt"

_DNS_NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
                       r"(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")


class CAImportError(ValueError):
    """An import was refused. The message is a lay sentence for either face."""


def crypto_problem() -> str:
    """"" when python-cryptography is importable, else why a key cannot be taken."""
    try:
        from cryptography import x509  # noqa: F401
        from cryptography.hazmat.primitives import serialization  # noqa: F401
    except ImportError:
        return ("this Studio does not include python-cryptography, so it cannot check "
                "a CA key and will not take one unchecked. Install it (pip install "
                "cryptography) and restart the Studio, or run the Studio from a "
                "checkout that has it.")
    return ""


# ── parsing ──────────────────────────────────────────────────────────────────────
def _read(path: str) -> bytes:
    path = os.path.abspath(os.path.expanduser(path))
    try:
        size = os.path.getsize(path)
    except OSError as e:
        raise CAImportError(f"cannot read {path}: {e.strerror or e}") from None
    if size > MAX_HELD_BYTES:
        raise CAImportError(f"{os.path.basename(path)} is {size} bytes, far larger "
                            "than any certificate or key; it is not one")
    with open(path, "rb") as fh:
        return fh.read()


def _has_private_key(data: bytes) -> bool:
    return b"PRIVATE KEY-----" in data


def _load_certs(data: bytes, what: str):
    from cryptography import x509
    if b"-----BEGIN CERTIFICATE-----" in data:
        try:
            return list(x509.load_pem_x509_certificates(data))
        except ValueError:
            raise CAImportError(f"the {what} file has a CERTIFICATE block that does "
                                "not parse as X.509") from None
    try:
        return [x509.load_der_x509_certificate(data)]
    except ValueError:
        raise CAImportError(f"the {what} file is not a certificate (PEM or DER)") \
            from None


def _load_key(data: bytes, passphrase: str | None):
    from cryptography.hazmat.primitives import serialization
    pw = passphrase.encode("utf-8") if passphrase else None
    if b"-----BEGIN" in data:
        # a combined file (certificate + key): load the key block on its own
        m = _PEM_KEY.search(data)
        if m is None:
            raise CAImportError("the key file has no private key in it")
        data = m.group(0)
    loaders = ((serialization.load_pem_private_key,) if b"-----BEGIN" in data
               else (serialization.load_der_private_key,))
    for load in loaders:
        try:
            return load(data, password=pw)
        except TypeError as e:
            msg = str(e).lower()
            if "not encrypted" in msg and pw is not None:
                return load(data, password=None)
            if "encrypted" in msg:
                raise CAImportError("the key is encrypted: enter its passphrase "
                                    "and import again") from None
            raise CAImportError("the key file is not a private key") from None
        except ValueError:
            if pw is not None:
                raise CAImportError("the passphrase does not open this key "
                                    "(or the file is not a private key)") from None
            raise CAImportError("the key file is not a private key") from None
        except Exception:   # UnsupportedAlgorithm and friends
            raise CAImportError("the key file holds a key type this Studio cannot "
                                "read") from None
    raise CAImportError("the key file is not a private key")  # pragma: no cover


def _pem(cert) -> bytes:
    from cryptography.hazmat.primitives import serialization
    return cert.public_bytes(serialization.Encoding.PEM)


def _spki(public_key) -> bytes:
    from cryptography.hazmat.primitives import serialization
    return public_key.public_bytes(serialization.Encoding.DER,
                                   serialization.PublicFormat.SubjectPublicKeyInfo)


def _pkcs8(key) -> bytes:
    from cryptography.hazmat.primitives import serialization
    return key.private_bytes(serialization.Encoding.PEM,
                             serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


def _cn(cert) -> str:
    from cryptography.x509.oid import NameOID
    attrs = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    return str(attrs[0].value) if attrs else cert.subject.rfc4514_string()


def _not_after(cert) -> _dt.datetime:
    v = getattr(cert, "not_valid_after_utc", None)
    return v if v is not None else cert.not_valid_after.replace(tzinfo=_dt.timezone.utc)


def _not_before(cert) -> _dt.datetime:
    v = getattr(cert, "not_valid_before_utc", None)
    return v if v is not None else cert.not_valid_before.replace(tzinfo=_dt.timezone.utc)


def _now(now: _dt.datetime | None) -> _dt.datetime:
    return now or _dt.datetime.now(_dt.timezone.utc)


# ── validation (refusals, not warnings) ──────────────────────────────────────────
def _key_strength_problem(public_key, what: str) -> str:
    from cryptography.hazmat.primitives.asymmetric import ec, rsa
    if isinstance(public_key, rsa.RSAPublicKey):
        if public_key.key_size < MIN_RSA_BITS:
            return (f"the {what} uses a {public_key.key_size}-bit RSA key, which is "
                    f"too weak (needs {MIN_RSA_BITS} bits or more)")
        return ""
    if isinstance(public_key, ec.EllipticCurvePublicKey):
        if public_key.curve.name not in ALLOWED_EC_CURVES:
            return (f"the {what} uses the {public_key.curve.name} curve; the cluster's "
                    "keystores and Vault take P-256, P-384 or P-521 only")
        return ""
    return (f"the {what} uses a {type(public_key).__name__.replace('PublicKey', '')} "
            "key; the cluster's keystores and Vault take RSA or ECDSA only")


def _signature_problem(cert, what: str) -> str:
    # By OID, not signature_hash_algorithm: cryptography raises UnsupportedAlgorithm
    # for exactly the broken hashes, and a swallowed exception must not read as "ok".
    from cryptography.x509.oid import SignatureAlgorithmOID as S
    weak = {S.RSA_WITH_MD5: "MD5", S.RSA_WITH_SHA1: "SHA1",
            S.ECDSA_WITH_SHA1: "SHA1", S.DSA_WITH_SHA1: "SHA1"}
    if hasattr(S, "_RSA_WITH_SHA1"):            # the non-standard sha1WithRSA OID
        weak[S._RSA_WITH_SHA1] = "SHA1"
    name = weak.get(cert.signature_algorithm_oid)
    if name:
        return (f"the {what} is signed with {name}, which is broken; re-issue it "
                "with SHA-256 or stronger")
    return ""


def _is_ca_problem(cert, what: str) -> str:
    from cryptography import x509
    try:
        bc = cert.extensions.get_extension_for_class(x509.BasicConstraints).value
    except x509.ExtensionNotFound:
        return (f"the {what} is not a certificate authority (it has no "
                "basicConstraints CA:TRUE)")
    if not bc.ca:
        return f"the {what} is not a certificate authority (basicConstraints CA:FALSE)"
    try:
        ku = cert.extensions.get_extension_for_class(x509.KeyUsage).value
    except x509.ExtensionNotFound:
        return ""
    if not ku.key_cert_sign:
        return (f"the {what} may not sign certificates (its keyUsage lacks "
                "keyCertSign)")
    return ""


def _validity_problem(cert, what: str, now: _dt.datetime | None) -> str:
    n = _now(now)
    if n < _not_before(cert):
        return f"the {what} is not valid until {_not_before(cert):%Y-%m-%d}"
    if n > _not_after(cert):
        return f"the {what} expired on {_not_after(cert):%Y-%m-%d}"
    return ""


def _self_signed(cert) -> bool:
    if cert.issuer != cert.subject:
        return False
    try:
        cert.verify_directly_issued_by(cert)
    except Exception:
        return False
    return True


def ca_cert_problems(cert, what: str, now: _dt.datetime | None = None) -> list[str]:
    """Every refusal for one CA certificate on its own (no key, no chain)."""
    out = [_is_ca_problem(cert, what), _validity_problem(cert, what, now),
           _key_strength_problem(cert.public_key(), what),
           _signature_problem(cert, what)]
    return [p for p in out if p]


def chain_problem(signing, root) -> str:
    """"" when ``signing`` is ``root`` or was directly issued by it, else the refusal."""
    if signing.fingerprint(_sha256()) == root.fingerprint(_sha256()):
        return ""
    if signing.issuer != root.subject:
        return (f"the signing CA ({_cn(signing)}) was not issued by this root "
                f"({_cn(root)}): its issuer is {signing.issuer.rfc4514_string()}")
    try:
        signing.verify_directly_issued_by(root)
    except Exception:
        return (f"the signing CA ({_cn(signing)}) names {_cn(root)} as its issuer, "
                "but this root's key did not sign it (a different root with the "
                "same name)")
    from cryptography import x509
    try:
        bc = root.extensions.get_extension_for_class(x509.BasicConstraints).value
        if bc.path_length == 0:
            return (f"the root ({_cn(root)}) forbids intermediate CAs "
                    "(pathLenConstraint 0), so it cannot sign this signing CA")
    except x509.ExtensionNotFound:
        pass
    return ""


def _sha256():
    from cryptography.hazmat.primitives import hashes
    return hashes.SHA256()


# ── the held record ──────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class DomainCA:
    """One domain's CA material. Certificates are public; ``key_pem`` is the
    UNENCRYPTED signing key and lives in memory only (never in :meth:`record`,
    ``repr`` or any message)."""
    domain: str
    own: bool
    root_pem: bytes = b""
    signing_pem: bytes = b""
    key_pem: bytes = field(default=b"", repr=False)
    root_name: str = ""          # display: file name it came from
    signing_name: str = ""
    warnings: tuple[str, ...] = ()

    @staticmethod
    def _fp(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest() if data else ""

    @property
    def key_sha256(self) -> str:
        """sha256 of the signing key's PUBLIC half (SPKI DER): names the key without
        being it, and survives re-encoding."""
        if not self.signing_pem:
            return ""
        from cryptography import x509
        return hashlib.sha256(_spki(x509.load_pem_x509_certificate(
            self.signing_pem).public_key())).hexdigest() if self.key_pem else ""

    def record(self) -> dict:
        """The CONTENT-FREE persistable summary (session records): fingerprints only."""
        return {"domain": self.domain, "own": self.own,
                "key_sha256": self.key_sha256,
                "signing_sha256": self._fp(self.signing_pem),
                "root_sha256": self._fp(self.root_pem)}

    def signing_cert(self):
        from cryptography import x509
        return x509.load_pem_x509_certificate(self.signing_pem) if self.signing_pem else None

    def root_cert(self):
        from cryptography import x509
        return x509.load_pem_x509_certificate(self.root_pem) if self.root_pem else None


class DomainCAStore:
    """In-memory store, keyed by domain name ("" = the mesh's own domain until it is
    named). Thread-safe: the GUI thread imports while the worklist thread consumes."""

    def __init__(self) -> None:
        self._held: dict[str, DomainCA] = {}
        self._lock = threading.Lock()

    def get(self, domain: str) -> DomainCA | None:
        with self._lock:
            return self._held.get(domain)

    def put(self, entry: DomainCA) -> DomainCA:
        with self._lock:
            self._held[entry.domain] = entry
        return entry

    def remove(self, domain: str) -> bool:
        with self._lock:
            return self._held.pop(domain, None) is not None

    def clear(self) -> None:
        with self._lock:
            self._held.clear()

    def entries(self) -> tuple[DomainCA, ...]:
        with self._lock:
            return tuple(self._held.values())

    def own(self) -> DomainCA | None:
        with self._lock:
            for e in self._held.values():
                if e.own:
                    return e
        return None

    def records(self) -> list[dict]:
        return [e.record() for e in self.entries()]

    def __repr__(self) -> str:      # never the key, even by accident
        return f"DomainCAStore({sorted(self._held)})"


_STORE: DomainCAStore | None = None
_STORE_GUARD = threading.Lock()


def store() -> DomainCAStore:
    """The process store (one per Studio process; tests swap ``_STORE``)."""
    global _STORE
    with _STORE_GUARD:
        if _STORE is None:
            _STORE = DomainCAStore()
        return _STORE


# ── the rows a face shows ────────────────────────────────────────────────────────
def own_domain(cfg) -> str:
    return (getattr(cfg, "cluster_domain", "") or "").strip()


def domain_rows(cfg) -> list[tuple[str, bool]]:
    """(domain, is_own) per row: the mesh's own domain first, then the Domains table,
    deduped. The own row's key is ``cluster_domain`` ("" when not named yet)."""
    own = own_domain(cfg)
    rows: list[tuple[str, bool]] = [(own, True)]
    for d in (getattr(cfg, "domains", None) or []):
        name = (getattr(d, "name", "") or "").strip()
        if name and name != own and name not in [r for r, _ in rows]:
            rows.append((name, False))
    return rows


def own_label(cfg) -> str:
    own = own_domain(cfg)
    return own if own else "this mesh's own domain (no name set yet)"


def rekey_own(cfg, st: DomainCAStore | None = None) -> None:
    """Keep the own-domain entry keyed by the CURRENT cluster_domain (an operator may
    rename it after importing); extra-domain entries that left the table are dropped
    so a stale CA can never reach a stick."""
    st = st or store()
    own = own_domain(cfg)
    names = {d for d, _own in domain_rows(cfg)}
    for e in st.entries():
        if e.own and e.domain != own:
            st.remove(e.domain)
            st.put(replace(e, domain=own))
        elif not e.own and e.domain not in names:
            st.remove(e.domain)


# ── imports (every path validates fully before anything is held) ────────────────
def _need_crypto() -> None:
    prob = crypto_problem()
    if prob:
        raise CAImportError(prob)


def _check_signing(domain, own, signing, key, root, now) -> list[str]:
    """Refuse or return warnings for a signing CA (+ key when own) under ``root``."""
    probs = ca_cert_problems(signing, "signing CA certificate", now)
    if key is not None and _spki(key.public_key()) != _spki(signing.public_key()):
        probs.insert(0, "the private key does not belong to this signing CA "
                        "certificate (their public keys differ)")
    if root is not None:
        cp = chain_problem(signing, root)
        if cp:
            probs.append(cp)
    if probs:
        raise CAImportError(probs[0])
    warns = []
    days = (_not_after(signing) - _now(now)).days
    if days < EXPIRY_WARN_DAYS:
        warns.append(f"the signing CA expires in {days} day(s) "
                     f"({_not_after(signing):%Y-%m-%d})")
    return warns


def _check_domain(domain: str, own: bool) -> None:
    if not own and not _DNS_NAME.match(domain or ""):
        raise CAImportError(f"{domain!r} is not a domain name")


def import_signing(st: DomainCAStore, domain: str, own: bool, *,
                   cert_path: str = "", key_path: str = "", p12_path: str = "",
                   passphrase: str | None = None,
                   now: _dt.datetime | None = None) -> DomainCA:
    """Import a domain's signing CA from a certificate file (+ key file for the own
    domain) or a PKCS#12 file, validate it against the domain's root (when one is
    set) and hold it. Raises :class:`CAImportError`; nothing is held on refusal."""
    _need_crypto()
    _check_domain(domain, own)
    prior = st.get(domain)
    key = None
    warns: list[str] = []
    bundled = None                      # a root that came IN this import, preferred
    bundled_name = ""
    if p12_path:
        from cryptography.hazmat.primitives.serialization import pkcs12
        data = _read(p12_path)
        try:
            key, cert, extra = pkcs12.load_key_and_certificates(
                data, passphrase.encode("utf-8") if passphrase else None)
        except ValueError:
            raise CAImportError("the PKCS#12 file did not open: wrong passphrase, or "
                                "not a PKCS#12 file") from None
        if cert is None:
            raise CAImportError("the PKCS#12 file holds no certificate")
        if own and key is None:
            raise CAImportError("the PKCS#12 file holds no private key")
        # a self-signed extra certificate in the bundle is the root it chains to
        for c in extra or ():
            if bundled is None and _self_signed(c) and c != cert:
                bundled, bundled_name = c, os.path.basename(p12_path)
        signing = cert
        name = os.path.basename(p12_path)
        if not own and key is not None:
            warns.append("the PKCS#12 file's private key was not taken: this domain "
                         "takes certificates only")
    else:
        if not cert_path:
            raise CAImportError("choose the signing CA certificate file")
        data = _read(cert_path)
        certs = _load_certs(data, "signing CA certificate")
        signing = certs[0]
        name = os.path.basename(cert_path)
        if own:
            if not key_path:
                raise CAImportError("choose the signing CA's private key file")
            key = _load_key(_read(key_path), passphrase)
            name = f"{name} + {os.path.basename(key_path)}"
        elif key_path:
            raise CAImportError(_EXTRA_KEY_REFUSAL)
        # a combined file's FIRST certificate is the signing CA; a self-signed
        # certificate after it is its root
        for c in certs[1:]:
            if bundled is None and _self_signed(c):
                bundled, bundled_name = c, os.path.basename(cert_path)
    if bundled is not None:
        root, root_name = bundled, bundled_name
    elif prior is not None and prior.root_pem:
        root, root_name = prior.root_cert(), prior.root_name
    else:
        root, root_name = None, ""
    if not own:
        key = None                      # an extra domain never holds a key
    warns = _check_signing(domain, own, signing, key, root, now) + warns
    if root is not None:
        rp = ca_cert_problems(root, "root CA certificate", now)
        if rp:
            raise CAImportError(rp[0])
    if root is None and not _self_signed(signing):
        warns.append("the signing CA is an intermediate: import the root certificate "
                     "it chains to so every node can trust the chain")
    entry = DomainCA(domain=domain, own=own,
                     root_pem=_pem(root) if root is not None else b"",
                     signing_pem=_pem(signing),
                     key_pem=_pkcs8(key) if key is not None else b"",
                     root_name=root_name if root is not None else "",
                     signing_name=name, warnings=tuple(warns))
    return st.put(entry)


_EXTRA_KEY_REFUSAL = (
    "only the mesh's own domain takes a signing key: no node consumes another "
    "domain's CA key yet (Vault signs for the mesh's own domain only). Import this "
    "domain's certificates without the key.")


def import_root(st: DomainCAStore, domain: str, own: bool, cert_path: str, *,
                now: _dt.datetime | None = None) -> DomainCA:
    """Set a domain's ROOT certificate. A file carrying a private key is refused
    (the root key stays offline); a held signing CA must chain to the new root."""
    _need_crypto()
    _check_domain(domain, own)
    data = _read(cert_path)
    if _has_private_key(data):
        raise CAImportError("this file carries a private key: a root CA key is never "
                            "taken (the root stays offline). Import the root "
                            "certificate on its own.")
    root = _load_certs(data, "root CA certificate")[0]
    probs = ca_cert_problems(root, "root CA certificate", now)
    if not _self_signed(root):
        probs.append("this certificate is not a root (it is not self-signed): import "
                     "it as the signing CA, and the root it chains to here")
    if probs:
        raise CAImportError(probs[0])
    prior = st.get(domain)
    warns: list[str] = []
    if prior and prior.signing_pem:
        cp = chain_problem(prior.signing_cert(), root)
        if cp:
            raise CAImportError(cp + ". To rotate to a new CA, remove this domain's "
                                     "CA first, then import the new one")
        warns = [w for w in prior.warnings if "intermediate" not in w]
    entry = DomainCA(domain=domain, own=own, root_pem=_pem(root),
                     signing_pem=prior.signing_pem if prior else b"",
                     key_pem=prior.key_pem if prior else b"",
                     root_name=os.path.basename(cert_path),
                     signing_name=prior.signing_name if prior else "",
                     warnings=tuple(warns))
    return st.put(entry)


def remove(st: DomainCAStore, domain: str) -> bool:
    return st.remove(domain)


def missing_for_restart(records, st: DomainCAStore | None = None) -> list[dict]:
    """The session record's ``held_domain_ca`` rows this process does not hold with
    the SAME fingerprints (a restart must not build with a different CA, or none)."""
    st = st or store()
    held = {(r["own"], r["key_sha256"], r["signing_sha256"], r["root_sha256"])
            for r in st.records()}
    out = []
    for rec in records or []:
        if not isinstance(rec, dict):
            continue
        k = (bool(rec.get("own")), rec.get("key_sha256", ""),
             rec.get("signing_sha256", ""), rec.get("root_sha256", ""))
        if k not in held:
            out.append(rec)
    return out


def restart_refusal(records, st: DomainCAStore | None = None) -> str:
    """"" when a restart may dispatch, else why not (both faces, one sentence)."""
    missing = missing_for_restart(records, st)
    if not missing:
        return ""
    names = ", ".join(r.get("domain") or "this mesh's own domain" for r in missing)
    return (f"Build not started: this session's sticks were made with the domain CA "
            f"for {names}, which was held only in the memory of the Studio that "
            f"dispatched it (CA keys are never saved). Import the same CA again on the "
            f"{STEP_TITLE} step, then build. Nothing was dispatched, and no throwaway "
            f"CA was used in its place.")


# ── readiness: the go-live checklist both faces render ──────────────────────────
@dataclass(frozen=True)
class Check:
    domain: str
    ok: bool
    text: str


def _expiry_text(cert, now) -> str:
    days = (_not_after(cert) - _now(now)).days
    return f"valid until {_not_after(cert):%Y-%m-%d} ({days} days)"


def readiness(cfg, st: DomainCAStore | None = None, profiles=None,
              now: _dt.datetime | None = None) -> list[Check]:
    """The per-domain go-live checklist. ``profiles`` is the KEYS profile of every
    node image in the worklist (None when the worklist is not known yet)."""
    st = st or store()
    out: list[Check] = []
    for domain, own in domain_rows(cfg):
        label = own_label(cfg) if own else domain
        e = st.get(domain)
        if own:
            if e is None or not e.signing_pem:
                out.append(Check(label, False,
                                 "no signing CA imported: each pki stick would mint a "
                                 "throwaway self-signed CA and Vault a DEV root"))
                continue
            sc = e.signing_cert()
            out.append(Check(label, True, f"signing CA {_cn(sc)}, "
                             + _expiry_text(sc, now)))
            out.append(Check(label, bool(e.key_pem),
                             "signing key held in memory for this session; it goes "
                             f"to the pki stick only ({STICK_KEY_PATH}, which Vault "
                             "pki_int imports)" if e.key_pem else
                             "signing key not held: import it again (keys are never "
                             "saved, so a Studio restart forgets them)"))
        else:
            if e is None or not e.signing_pem:
                out.append(Check(label, True,
                                 "no CA imported (optional): this domain adds no "
                                 "certificate to the sticks"))
                continue
            sc = e.signing_cert()
            out.append(Check(label, True, f"signing CA {_cn(sc)} (certificate only), "
                             + _expiry_text(sc, now)))
        rc = e.root_cert()
        if rc is not None:
            out.append(Check(label, True, f"chains to root {_cn(rc)}"))
        elif _self_signed(e.signing_cert()):
            out.append(Check(label, True, "the signing CA is itself the root "
                             "(self-signed); an offline root with an intermediate is "
                             "the recommended model"))
        else:
            out.append(Check(label, False, "intermediate without its root: import the "
                             "root certificate so every node can trust the chain"))
        for w in e.warnings:
            if "intermediate" in w:
                continue
            out.append(Check(label, "expires in" not in w, w))
        if own and profiles is not None:
            n_pki = sum(1 for p in profiles if p == KEY_PROFILE)
            others = len(profiles) - n_pki
            if n_pki == 0:
                out.append(Check(label, False, "no image in the worklist takes the pki "
                                 "keys profile, so no stick would carry the key to "
                                 "Vault"))
            else:
                out.append(Check(label, True,
                                 f"{n_pki} pki stick(s) get the key; {others} other "
                                 "stick(s) get public certificates only"))
    return out


def ready_to_go_live(checks) -> bool:
    return all(c.ok for c in checks)


def readiness_lines(cfg, st: DomainCAStore | None = None, profiles=None,
                    now: _dt.datetime | None = None) -> list[str]:
    """The checklist as text lines: the GUI, the TUI and the CLI print these."""
    checks = readiness(cfg, st, profiles, now)
    head = ("READY to go live: every stick gets its CA material"
            if ready_to_go_live(checks) else
            "NOT ready to go live: fix the items marked [ ]")
    out = [head]
    last = None
    for c in checks:
        if c.domain != last:
            out.append(c.domain)
            last = c.domain
        out.append(f"  [{'x' if c.ok else ' '}] {c.text}")
    return out


def row_cells(cfg, st: DomainCAStore | None = None) -> list[list[str]]:
    """The table body both faces render (TABLE_HEADERS columns)."""
    st = st or store()
    rows = []
    for domain, own in domain_rows(cfg):
        e = st.get(domain)
        label = own_label(cfg) if own else domain
        root = e.root_name if e and e.root_pem else "-"
        signing = e.signing_name if e and e.signing_pem else "-"
        if own:
            key = ("held (pki stick only)" if e and e.key_pem
                   else "needed" if e and e.signing_pem else "-")
        else:
            key = "not taken (certificates only)"
        checks = [c for c in readiness(cfg, st) if c.domain == label]
        status = "ready" if ready_to_go_live(checks) else "not ready"
        if not own and not (e and e.signing_pem):
            status = "optional"
        rows.append([label, root, signing, key, status])
    return rows


# ── placement on the sticks ──────────────────────────────────────────────────────
def _trust_name(domain: str, kind: str) -> str:
    base = domain or "mesh"
    return f"{base}-{kind}"


@dataclass
class MaterializedCA:
    """The held CA material written for ONE build run under a private temp dir."""
    root: str
    signing_cert: str = ""
    signing_key: str = ""
    trust: list[tuple[str, str]] = field(default_factory=list)   # (name, path)
    spki: tuple[bytes, ...] = ()

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def args_for(self, profile: str) -> list[str]:
        """gen-provision-keys.sh arguments for one KEYS profile. The key path is
        passed to the pki profile ONLY; every profile gets the public certificates."""
        args: list[str] = []
        if self.signing_cert:
            args += ["--ca-cert", self.signing_cert]
            if profile == KEY_PROFILE and self.signing_key:
                args += ["--ca-key", self.signing_key, "--ca-key-to-stick",
                         "--no-kubeadm-ca"]
        for name, path in self.trust:
            args += ["--trust-cert", f"{name}={path}"]
        return args

    def paths(self) -> list[str]:
        out = [p for p in (self.signing_cert, self.signing_key) if p]
        return out + [p for _n, p in self.trust]


def has_material(st: DomainCAStore | None = None) -> bool:
    st = st or store()
    return any(e.signing_pem or e.root_pem for e in st.entries())


def materialize(st: DomainCAStore | None = None) -> MaterializedCA | None:
    """Write the held material for one run (None when nothing is held, so an untouched
    step changes no argv). Files are 0600 under a 0700 ``mkdtemp`` dir, never under the
    build workdir; callers ``cleanup()`` in a ``finally``."""
    st = st or store()
    if not has_material(st):
        return None
    root = tempfile.mkdtemp(prefix="hugmesh-domain-ca-")
    os.chmod(root, 0o700)
    m = MaterializedCA(root=root)
    try:
        spki = []
        for e in sorted(st.entries(), key=lambda x: (not x.own, x.domain)):
            if e.own and e.signing_pem:
                m.signing_cert = os.path.join(root, "signing-ca.crt")
                _write_0600(m.signing_cert, e.signing_pem)
                if e.key_pem:
                    m.signing_key = os.path.join(root, "signing-ca.key")
                    _write_0600(m.signing_key, e.key_pem)
                    spki.append(_spki(e.signing_cert().public_key()))
            elif e.signing_pem:
                name = _trust_name(e.domain, "ca")
                p = os.path.join(root, f"{name}.crt")
                _write_0600(p, e.signing_pem)
                m.trust.append((name, p))
            if e.root_pem and e.root_pem != e.signing_pem:
                name = _trust_name(e.domain, "root-ca")
                p = os.path.join(root, f"{name}.crt")
                _write_0600(p, e.root_pem)
                m.trust.append((name, p))
        m.spki = tuple(spki)
    except BaseException:
        shutil.rmtree(root, ignore_errors=True)
        raise
    return m


_PEM_KEY = re.compile(rb"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----.*?"
                      rb"-----END \1PRIVATE KEY-----", re.S)


def scan_keys_dir(path: str, profile: str, spki: tuple[bytes, ...]) -> list[str]:
    """After generation: every place a CA private key landed that it must not.

    * on a non-pki stick: ANY private key under ``certs/`` or ``kubernetes/pki/``,
      and the held CA key anywhere at all;
    * on the pki stick: the held CA key anywhere other than ``certs/cluster-ca.key``.

    Returns the problems ([] = clean). A file is matched on the key's PUBLIC half, so
    a re-encoded copy is caught too."""
    from cryptography.hazmat.primitives import serialization
    problems: list[str] = []
    for dirpath, _dirs, files in os.walk(path):
        for f in files:
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            try:
                if os.path.getsize(full) > MAX_HELD_BYTES:
                    continue
                with open(full, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"PRIVATE KEY-----" not in data:
                continue
            guarded_dir = rel.startswith(("certs/", "kubernetes/pki/"))
            if profile != KEY_PROFILE and guarded_dir:
                problems.append(f"{rel}: a private key on a {profile} stick (only the "
                                "pki stick may carry a CA key)")
                continue
            for m in _PEM_KEY.finditer(data):
                try:
                    k = serialization.load_pem_private_key(m.group(0), password=None)
                    pub = _spki(k.public_key())
                except Exception:
                    continue
                if pub in spki and not (profile == KEY_PROFILE
                                        and rel == STICK_KEY_PATH):
                    problems.append(f"{rel}: the domain CA private key, outside "
                                    f"{STICK_KEY_PATH} on the pki stick")
    return problems


# ── the CLI face (hugmesh-studio --domain-ca check ...) ─────────────────────────
CLI_PLACEMENT_NOTE = (
    "To put a CA on the sticks from a terminal, give the same files to "
    "scripts/gen-provision-keys.sh: --ca-cert/--ca-key/--ca-key-to-stick/"
    "--no-kubeadm-ca on the pki profile, --ca-cert and --trust-cert NAME=FILE on "
    "every other profile.")


def cli_main(argv) -> int:
    """Check one domain's CA files and print the go-live checklist (the step's text).

    Exit 0 = imported and ready, 1 = imported but not ready, 2 = refused. A
    passphrase comes from ``--pass-file`` (first line), never from the command line."""
    import argparse
    import json as _json
    import sys

    ap = argparse.ArgumentParser(
        prog="hugmesh-studio --domain-ca",
        description=f"{STEP_TITLE}: check a domain's CA files against the rules the "
                    "Studio step enforces, and print its go-live checklist. "
                    + CLI_PLACEMENT_NOTE)
    ap.add_argument("action", choices=["check"])
    ap.add_argument("--config", help="a saved Studio config or worklist (its domains "
                                     "are the rows); default: a mesh with --domain only")
    ap.add_argument("--domain", default="", help="the row to import into (default: "
                                                 "the mesh's own domain)")
    ap.add_argument("--cert", default="", help="signing CA certificate (PEM or DER)")
    ap.add_argument("--key", default="", help="signing CA private key (own domain)")
    ap.add_argument("--p12", default="", help="PKCS#12 file instead of --cert/--key")
    ap.add_argument("--root", default="", help="root CA certificate")
    ap.add_argument("--pass-file", default="", help="file whose first line is the "
                                                    "key/PKCS#12 passphrase")
    ap.add_argument("--profile", action="append", default=None,
                    help="a KEYS profile in the worklist (repeat), for the "
                         "placement line; default: taken from --config")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    a = ap.parse_args(argv)

    from types import SimpleNamespace
    profiles = a.profile
    if a.config:
        from .worklist import load_any
        from .worklist_driver import node_key_profiles
        try:
            cfg, wl = load_any(a.config)
        except (OSError, ValueError) as e:
            print(f"cannot read {a.config}: {e}", file=sys.stderr)
            return 2
        if profiles is None:
            profiles = node_key_profiles(wl)
    else:
        cfg = SimpleNamespace(mode="mesh", cluster_domain=a.domain, domains=[])
    domain = a.domain or own_domain(cfg)
    rows = dict(domain_rows(cfg))
    if domain not in rows:
        print(f"{domain} is not a domain of this config", file=sys.stderr)
        return 2
    own = rows[domain]
    pw = None
    if a.pass_file:
        try:
            with open(a.pass_file, encoding="utf-8") as fh:
                pw = fh.readline().rstrip("\r\n")
        except OSError as e:
            print(f"cannot read the passphrase file: {e.strerror or e}", file=sys.stderr)
            return 2
    st = DomainCAStore()
    try:
        if a.root:
            import_root(st, domain, own, a.root)
        if a.cert or a.p12:
            import_signing(st, domain, own, cert_path=a.cert, key_path=a.key,
                           p12_path=a.p12, passphrase=pw)
    except CAImportError as err:
        if a.json:
            print(_json.dumps({"refused": str(err)}))
        else:
            print(f"refused: {err}")
        return 2
    checks = readiness(cfg, st, profiles)
    ok = ready_to_go_live(checks)
    if a.json:
        print(_json.dumps({"ready": ok, "records": st.records(),
                           "checks": [c.__dict__ for c in checks]}, indent=2))
    else:
        print("\n".join(readiness_lines(cfg, st, profiles)))
    return 0 if ok else 1
