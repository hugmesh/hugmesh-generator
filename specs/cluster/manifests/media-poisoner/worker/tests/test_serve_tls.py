# SPDX-License-Identifier: Apache-2.0
"""Tests for app/serve.py — the media-poisoner (m)TLS entrypoint config.

Two layers:

  * TlsKwargsFromEnv / TransportMode — pure config-resolution tests (stdlib
    only, no fastapi/uvicorn needed): the backward-compatible plaintext
    default, the mTLS kwargs mapping, and the FAIL-CLOSED contract on every
    partial/broken configuration.
  * LiveMutualTls — a real end-to-end handshake proof (skipped unless uvicorn
    + fastapi + the openssl CLI are available, e.g. in the worker's CI image):
    self-signs a throwaway CA + server + client cert, boots `python -m
    app.serve` with the mTLS env, and asserts a certless client is REJECTED
    at the handshake while a cert-bearing client gets a 200 /health that
    discloses transport:"mtls".

Run:  python3 -m unittest discover -s <worker dir>/tests -v
      (pytest also collects these unittest classes.)
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

WORKER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WORKER_DIR))

from app.serve import (  # noqa: E402  (path bootstrap above)
    TlsConfigError,
    tls_kwargs_from_env,
    transport_mode,
)


class TlsKwargsFromEnv(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cert = Path(self.tmp.name, "tls.crt")
        self.key = Path(self.tmp.name, "tls.key")
        self.ca = Path(self.tmp.name, "client-ca.crt")
        for f in (self.cert, self.key, self.ca):
            f.write_text("dummy pem\n")

    # ── backward-compatible default ─────────────────────────────────────────
    def test_no_env_means_plaintext(self) -> None:
        self.assertEqual(tls_kwargs_from_env({}), {})

    def test_blank_env_values_treated_as_unset(self) -> None:
        env = {"POISON_TLS_CERT": "  ", "POISON_TLS_KEY": "", "POISON_TLS_CLIENT_CA": "\t"}
        self.assertEqual(tls_kwargs_from_env(env), {})

    # ── server-auth TLS and full mTLS mappings ──────────────────────────────
    def test_cert_and_key_yield_server_tls_without_client_verify(self) -> None:
        kw = tls_kwargs_from_env(
            {"POISON_TLS_CERT": str(self.cert), "POISON_TLS_KEY": str(self.key)}
        )
        self.assertEqual(
            kw, {"ssl_certfile": str(self.cert), "ssl_keyfile": str(self.key)}
        )
        self.assertNotIn("ssl_cert_reqs", kw)  # no client CA => no client verify

    def test_client_ca_enforces_cert_required(self) -> None:
        kw = tls_kwargs_from_env(
            {
                "POISON_TLS_CERT": str(self.cert),
                "POISON_TLS_KEY": str(self.key),
                "POISON_TLS_CLIENT_CA": str(self.ca),
            }
        )
        self.assertEqual(kw["ssl_ca_certs"], str(self.ca))
        self.assertEqual(kw["ssl_cert_reqs"], ssl.CERT_REQUIRED)

    # ── FAIL-CLOSED: every partial/broken config must raise ─────────────────
    def test_cert_without_key_fails_closed(self) -> None:
        with self.assertRaises(TlsConfigError):
            tls_kwargs_from_env({"POISON_TLS_CERT": str(self.cert)})

    def test_key_without_cert_fails_closed(self) -> None:
        with self.assertRaises(TlsConfigError):
            tls_kwargs_from_env({"POISON_TLS_KEY": str(self.key)})

    def test_client_ca_alone_fails_closed(self) -> None:
        # A client-CA with no server cert/key cannot be honoured — must abort,
        # never silently serve plaintext while the operator believes mTLS is on.
        with self.assertRaises(TlsConfigError):
            tls_kwargs_from_env({"POISON_TLS_CLIENT_CA": str(self.ca)})

    def test_missing_cert_file_fails_closed(self) -> None:
        with self.assertRaises(TlsConfigError):
            tls_kwargs_from_env(
                {
                    "POISON_TLS_CERT": str(Path(self.tmp.name, "nope.crt")),
                    "POISON_TLS_KEY": str(self.key),
                }
            )

    def test_missing_client_ca_file_fails_closed(self) -> None:
        with self.assertRaises(TlsConfigError):
            tls_kwargs_from_env(
                {
                    "POISON_TLS_CERT": str(self.cert),
                    "POISON_TLS_KEY": str(self.key),
                    "POISON_TLS_CLIENT_CA": str(Path(self.tmp.name, "nope-ca.crt")),
                }
            )


class TransportMode(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cert = Path(self.tmp.name, "tls.crt")
        self.key = Path(self.tmp.name, "tls.key")
        self.ca = Path(self.tmp.name, "client-ca.crt")
        for f in (self.cert, self.key, self.ca):
            f.write_text("dummy pem\n")

    def test_modes(self) -> None:
        self.assertEqual(transport_mode({}), "plaintext")
        self.assertEqual(
            transport_mode(
                {"POISON_TLS_CERT": str(self.cert), "POISON_TLS_KEY": str(self.key)}
            ),
            "tls",
        )
        self.assertEqual(
            transport_mode(
                {
                    "POISON_TLS_CERT": str(self.cert),
                    "POISON_TLS_KEY": str(self.key),
                    "POISON_TLS_CLIENT_CA": str(self.ca),
                }
            ),
            "mtls",
        )
        self.assertEqual(
            transport_mode({"POISON_TLS_CERT": str(self.cert)}), "invalid"
        )


def _deps_available() -> bool:
    try:
        import fastapi  # noqa: F401
        import uvicorn  # noqa: F401
    except Exception:
        return False
    return shutil.which("openssl") is not None


def _openssl(*args: str) -> None:
    subprocess.run(["openssl", *args], check=True, capture_output=True)


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(
    _deps_available(), "live mTLS test needs fastapi+uvicorn+openssl (worker CI image)"
)
class LiveMutualTls(unittest.TestCase):
    """Boot the real entrypoint with mTLS env and prove the handshake gate."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        subj = "/CN=media-poisoner-test"
        # Throwaway CA + server leaf (CN=localhost, SAN for 127.0.0.1) + client leaf.
        _openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                 "-keyout", str(d / "ca.key"), "-out", str(d / "ca.crt"),
                 "-subj", "/CN=poisoner-test-ca",
                 # Modern OpenSSL/Python require a REAL CA profile on the trust
                 # anchor (basicConstraints CA:TRUE + keyCertSign) — a bare
                 # self-signed req is rejected with "CA cert does not include
                 # key usage extension".
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        for name, cn, ext in (("server", "localhost", "subjectAltName=IP:127.0.0.1,DNS:localhost"),
                              ("client", "user-bff", "")):
            _openssl("req", "-newkey", "rsa:2048", "-nodes",
                     "-keyout", str(d / f"{name}.key"), "-out", str(d / f"{name}.csr"),
                     "-subj", subj.replace("media-poisoner-test", cn))
            args = ["x509", "-req", "-days", "1", "-in", str(d / f"{name}.csr"),
                    "-CA", str(d / "ca.crt"), "-CAkey", str(d / "ca.key"),
                    "-CAcreateserial", "-out", str(d / f"{name}.crt")]
            if ext:
                extf = d / f"{name}.ext"
                extf.write_text(ext + "\n")
                args += ["-extfile", str(extf)]
            _openssl(*args)

        cls.port = _free_port()
        env = dict(os.environ)
        env.update(
            POISON_BIND_HOST="127.0.0.1",
            POISON_BIND_PORT=str(cls.port),
            POISON_TLS_CERT=str(d / "server.crt"),
            POISON_TLS_KEY=str(d / "server.key"),
            POISON_TLS_CLIENT_CA=str(d / "ca.crt"),
            POISON_BACKEND="cpu",
        )
        cls.proc = subprocess.Popen(
            [sys.executable, "-m", "app.serve"],
            cwd=str(WORKER_DIR), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        # Wait for the TLS listener (mTLS context: connect with the client cert).
        deadline = time.monotonic() + 30
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            if cls.proc.poll() is not None:
                out = cls.proc.stdout.read().decode(errors="replace") if cls.proc.stdout else ""
                raise AssertionError(f"server exited early:\n{out}")
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=2) as raw:
                    ctx = cls._client_ctx(d)
                    with ctx.wrap_socket(raw, server_hostname="localhost"):
                        return  # handshake completed — server is up
            except Exception as exc:  # noqa: BLE001 — retry until deadline
                last_err = exc
                time.sleep(0.3)
        raise AssertionError(f"server did not come up: {last_err}")

    @staticmethod
    def _client_ctx(d: Path, with_client_cert: bool = True) -> ssl.SSLContext:
        ctx = ssl.create_default_context(cafile=str(d / "ca.crt"))
        if with_client_cert:
            ctx.load_cert_chain(str(d / "client.crt"), str(d / "client.key"))
        return ctx

    @classmethod
    def tearDownClass(cls) -> None:
        cls.proc.terminate()
        try:
            cls.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
        cls.tmp.cleanup()

    def test_certless_client_is_rejected(self) -> None:
        # THE mTLS property: a client without a certificate must NOT be able to
        # complete a /health round-trip. Depending on the TLS version the
        # rejection surfaces as a handshake failure, a certificate_required
        # alert on first read (TLS 1.3 defers the client-cert check), or a
        # reset/EOF — any of those is a rejection. A 200 response = FAIL.
        d = Path(self.tmp.name)
        ctx = self._client_ctx(d, with_client_cert=False)
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as raw:
                with ctx.wrap_socket(raw, server_hostname="localhost") as tls:
                    tls.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    first = tls.recv(1024)
        except (ssl.SSLError, ConnectionError, TimeoutError):
            return  # rejected — the expected mTLS outcome
        self.assertEqual(
            first, b"",
            f"certless client obtained a response over mTLS: {first[:120]!r}",
        )

    def test_cert_bearing_client_gets_health_with_mtls_disclosure(self) -> None:
        d = Path(self.tmp.name)
        # Connect to 127.0.0.1 (the bind address; 'localhost' may resolve to ::1)
        # — the server cert carries an IP:127.0.0.1 SAN so verification still holds.
        conn = http.client.HTTPSConnection(
            "127.0.0.1", self.port, context=self._client_ctx(d), timeout=10
        )
        try:
            conn.request("GET", "/health")
            resp = conn.getresponse()
            body = json.loads(resp.read())
        finally:
            conn.close()
        self.assertEqual(resp.status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["transport"], "mtls")  # honest transport disclosure


if __name__ == "__main__":
    unittest.main(verbosity=2)
