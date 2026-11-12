#!/usr/bin/env python3
"""Write a Tor v3 onion-service keypair from an Ed25519 key made by openssl.

    onion-v3-key.py <private.der> <public.der> <outdir>

<private.der> is `openssl genpkey -algorithm ed25519 -outform DER` (PKCS#8: the
32-byte seed is its last 32 bytes) and <public.der> is `openssl pkey -pubout
-outform DER` of it (SubjectPublicKeyInfo: the 32-byte key is its last 32 bytes).
Writes, mode 0600, exactly the three files tor keeps in a HiddenServiceDir:

    hs_ed25519_secret_key   "== ed25519v1-secret: type0 ==\\0\\0\\0" + the 64-byte
                            expanded key (SHA-512 of the seed, clamped)
    hs_ed25519_public_key   "== ed25519v1-public: type0 ==\\0\\0\\0" + the key
    hostname                base32(key | checksum | 0x03) + ".onion"

and prints the hostname. Used by scripts/gen-provision-keys.sh
--mesh-control-onion-mint (docs/MESH-CONTROL-OVER-TOR.md) so the build host needs
only openssl and python3, never a tor binary. Checked against tor 0.4.9.11 with no
network (`DisableNetwork 1`, docker --network none): tor loaded the secret key
unchanged and wrote the same public key and hostname; the fixed-seed vector in
tests/scripts/test-mesh-control-onion.sh came from that run.
"""
import base64
import hashlib
import os
import sys

PKCS8_ED25519_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
SPKI_ED25519_PREFIX = bytes.fromhex("302a300506032b6570032100")


def onion_hostname(pub: bytes) -> str:
    version = b"\x03"
    checksum = hashlib.sha3_256(b".onion checksum" + pub + version).digest()[:2]
    return base64.b32encode(pub + checksum + version).decode("ascii").lower() + ".onion"


def expanded_secret(seed: bytes) -> bytes:
    h = bytearray(hashlib.sha512(seed).digest())
    h[0] &= 248
    h[31] &= 127
    h[31] |= 64
    return bytes(h)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(argv[1], "rb") as fh:
        priv = fh.read()
    with open(argv[2], "rb") as fh:
        spki = fh.read()
    if len(priv) != 48 or not priv.startswith(PKCS8_ED25519_PREFIX):
        print("onion-v3-key: private key is not a PKCS#8 Ed25519 key", file=sys.stderr)
        return 1
    if len(spki) != 44 or not spki.startswith(SPKI_ED25519_PREFIX):
        print("onion-v3-key: public key is not an Ed25519 SubjectPublicKeyInfo", file=sys.stderr)
        return 1
    seed, pub = priv[-32:], spki[-32:]
    outdir = argv[3]
    os.makedirs(outdir, mode=0o700, exist_ok=True)
    os.chmod(outdir, 0o700)
    host = onion_hostname(pub)
    files = {
        "hs_ed25519_secret_key": b"== ed25519v1-secret: type0 ==\x00\x00\x00" + expanded_secret(seed),
        "hs_ed25519_public_key": b"== ed25519v1-public: type0 ==\x00\x00\x00" + pub,
        "hostname": (host + "\n").encode("ascii"),
    }
    for name, data in files.items():
        path = os.path.join(outdir, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        os.chmod(path, 0o600)
    print(host)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
