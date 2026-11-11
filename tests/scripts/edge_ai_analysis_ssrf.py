#!/usr/bin/env python3
"""edge-ai-analysis image_url SSRF regression (CodeQL py/full-ssrf, alert #9).

Drives the real specs/cluster/manifests/edge-ai-analysis/image/app.py through
FastAPI's TestClient on POST /v1/analyze/image/hash, the cheapest endpoint that
takes image_url (it hashes the fetched bytes and makes no model call).

NOTHING LEAVES THIS PROCESS. socket.getaddrinfo is replaced by a fixed answer
table (an unknown name fails, an IP literal answers itself), and
socket.create_connection is replaced by a shim that records every connect. The
shim forwards connects to the "public" test addresses to a listener this file
runs on 127.0.0.1; every other connect is refused with an error text that carries
LEAK_MARKER, so the API response can be checked for a leaked transport error.
The public test addresses are globally routable on paper only: no packet is ever
sent to them.

EDGE_AI_ANALYSIS_APP overrides the path of app.py. The wrapper suite
(tests/scripts/test-edge-ai-analysis-ssrf.sh) points it at mutated copies to
prove each test can fail.

Needs the image's pinned requirements (httpx, fastapi, Pillow, imagehash) and the
openssl CLI for the throwaway test CA.
"""
from __future__ import annotations

import importlib.util
import io
import ipaddress
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
APP_PATH = os.environ.get(
    "EDGE_AI_ANALYSIS_APP",
    os.path.join(REPO, "specs", "cluster", "manifests", "edge-ai-analysis", "image", "app.py"),
)

import imagehash  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from PIL import Image  # noqa: E402


def _load_app():
    spec = importlib.util.spec_from_file_location("edge_ai_analysis_app_under_test", APP_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


APP = _load_app()
ENDPOINT = "/v1/analyze/image/hash"
REAL_CREATE_CONNECTION = socket.create_connection
LEAK_MARKER = "fakenet-leak-7c1d"

# Globally routable addresses the fake network pretends serve images. Never contacted.
PUBLIC_A = "93.184.216.34"
PUBLIC_B = "93.184.216.35"
PUBLIC_C = "93.184.216.36"
PUBLIC_V6 = "2606:2800:220:1:248:1893:25c8:1946"


def _png() -> bytes:
    buf = io.BytesIO()
    im = Image.new("RGB", (16, 16))
    for x in range(16):
        for y in range(16):
            im.putpixel((x, y), ((x * 16) % 256, (y * 16) % 256, ((x + y) * 8) % 256))
    im.save(buf, format="PNG")
    return buf.getvalue()


PNG = _png()
with Image.open(io.BytesIO(PNG)) as _im:
    PNG_PHASH = str(imagehash.phash(_im.convert("RGB")))


def http_response(status: str, body: bytes = b"", headers: tuple[str, ...] = ()) -> bytes:
    head = [f"HTTP/1.1 {status}", f"Content-Length: {len(body)}", "Connection: close", *headers]
    return ("\r\n".join(head) + "\r\n\r\n").encode("ascii") + body


OK_PNG = http_response("200 OK", PNG, ("Content-Type: image/png",))


class Listener:
    """A one-response-per-connection HTTP(S) server on 127.0.0.1."""

    def __init__(self, response: bytes, tls: ssl.SSLContext | None = None):
        self.response = response
        self.requests: list[bytes] = []
        self.server_names: list[str | None] = []
        self.tls_errors: list[str] = []
        self._tls = tls
        if tls is not None:
            tls.sni_callback = self._sni
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self._sock.settimeout(0.2)
        self.port = self._sock.getsockname()[1]
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _sni(self, sslobj, server_name, ctx):
        self.server_names.append(server_name)

    def _run(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except (socket.timeout, OSError):
                continue
            conn.settimeout(5)
            try:
                if self._tls is not None:
                    try:
                        conn = self._tls.wrap_socket(conn, server_side=True)
                    except (ssl.SSLError, OSError) as e:
                        self.tls_errors.append(type(e).__name__)
                        continue
                data = b""
                while b"\r\n\r\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                self.requests.append(data)
                conn.sendall(self.response)
            except OSError:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self._sock.close()


class FakeNet:
    """Replaces name resolution and TCP connect for the duration of a test."""

    def __init__(self):
        self.dns: dict[str, list[list[str]]] = {}
        self.lookups: dict[str, int] = {}
        self.connects: list[tuple[str, int, str]] = []
        self.routes: dict[tuple[str, int], int] = {}

    def answer(self, name: str, *answers: list[str]) -> None:
        """Successive lookups of `name` get successive answers; the last one repeats."""
        self.dns[name] = [list(a) for a in answers]

    def serve(self, address: str, port: int, listener: Listener) -> None:
        self.routes[(address, port)] = listener.port

    def _resolve(self, host: str) -> list[str]:
        try:
            ipaddress.ip_address(host)
            return [host]
        except ValueError:
            pass
        if host not in self.dns:
            raise socket.gaierror(socket.EAI_NONAME, "Name or service not known")
        n = self.lookups.get(host, 0)
        self.lookups[host] = n + 1
        seq = self.dns[host]
        return seq[min(n, len(seq) - 1)]

    def getaddrinfo(self, host, port, family=0, type=0, proto=0, flags=0):
        if isinstance(host, bytes):
            host = host.decode("ascii")
        port = int(port or 0)
        out = []
        for a in self._resolve(host):
            if ipaddress.ip_address(a).version == 4:
                out.append((socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (a, port)))
            else:
                out.append((socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (a, port, 0, 0)))
        return out

    def create_connection(self, address, timeout=None, source_address=None, **_kw):
        host, port = address[0], int(address[1])
        resolved = self._resolve(host)[0]
        self.connects.append((host, port, resolved))
        target = self.routes.get((resolved, port))
        if target is None:
            raise ConnectionRefusedError(111, f"Connection refused by {resolved}:{port} [{LEAK_MARKER}]")
        return REAL_CREATE_CONNECTION(("127.0.0.1", target), timeout)


def install_fake_net(test: unittest.TestCase) -> FakeNet:
    """Patch resolution and connect for one test, and drop the runner's proxy
    variables (only the proxy test sets them, on purpose). Undone by cleanups."""
    net = FakeNet()
    for attr in ("getaddrinfo", "create_connection"):
        patcher = mock.patch.object(socket, attr, getattr(net, attr))
        patcher.start()
        test.addCleanup(patcher.stop)
    env = mock.patch.dict(os.environ, {}, clear=False)
    env.start()
    test.addCleanup(env.stop)
    for k in [k for k in os.environ if k.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")]:
        del os.environ[k]
    return net


def _make_test_pki(workdir: str) -> dict[str, str]:
    """A throwaway CA and one leaf certificate for tls.example (openssl CLI)."""
    p = {k: os.path.join(workdir, k) for k in ("ca.key", "ca.pem", "leaf.key", "leaf.csr", "leaf.pem", "ext.cnf")}
    with open(p["ext.cnf"], "w") as f:
        f.write("subjectAltName=DNS:tls.example\nbasicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
                "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")

    def run(*args):
        subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)

    run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", p["ca.key"], "-out", p["ca.pem"],
        "-days", "2", "-subj", "/CN=edge-ai-ssrf-test-ca",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        "-addext", "subjectKeyIdentifier=hash")
    run("req", "-newkey", "rsa:2048", "-nodes", "-keyout", p["leaf.key"], "-out", p["leaf.csr"],
        "-subj", "/CN=tls.example")
    run("x509", "-req", "-in", p["leaf.csr"], "-CA", p["ca.pem"], "-CAkey", p["ca.key"],
        "-CAcreateserial", "-out", p["leaf.pem"], "-days", "2", "-extfile", p["ext.cnf"])
    return p


class ImageUrlSsrf(unittest.TestCase):
    REFUSED = "image_url must be a public http(s) URL"
    FETCH_FAILED = "could not fetch image_url"

    @classmethod
    def setUpClass(cls):
        cls.client = TestClient(APP.app, raise_server_exceptions=False)

    def setUp(self):
        self.net = install_fake_net(self)
        self.listeners: list[Listener] = []

    def tearDown(self):
        for listener in self.listeners:
            listener.close()

    def listen(self, response: bytes, tls: ssl.SSLContext | None = None) -> Listener:
        listener = Listener(response, tls)
        self.listeners.append(listener)
        return listener

    def fetch(self, url: str):
        return self.client.post(ENDPOINT, json={"image_url": url})

    def assert_no_connect(self, url: str, resp) -> None:
        self.assertEqual(resp.status_code, 400, f"{url}: expected a 400, got {resp.status_code} {resp.text}")
        self.assertEqual(self.net.connects, [], f"{url}: the service opened a connection: {self.net.connects}")

    # ── the CGNAT / tailnet hole and its neighbours ─────────────────────────
    def test_internal_literal_addresses_are_refused_without_connecting(self):
        cases = [
            "http://100.64.0.1/x.png",                 # CGNAT = the headscale tailnet
            "http://100.100.100.100/x.png",            # tailnet MagicDNS
            "http://100.127.255.254:8080/x.png",       # top of 100.64.0.0/10
            "http://169.254.169.254/latest/meta-data/",  # cloud metadata
            "http://[fd00::1]/x.png",                  # IPv6 ULA
            "http://[fd7a:115c:a1e0::1]/x.png",        # tailnet IPv6 (ULA)
            "http://[::ffff:127.0.0.1]/x.png",         # IPv4-mapped loopback
            "http://[::ffff:100.64.0.1]/x.png",        # IPv4-mapped tailnet
            "http://[64:ff9b::a9fe:a9fe]/x.png",       # NAT64 of 169.254.169.254
            "http://[64:ff9b::6440:1]/x.png",          # NAT64 of 100.64.0.1
            "http://[2002:a9fe:a9fe::1]/x.png",        # 6to4 of 169.254.169.254
            "http://0.1.2.3/x.png",                    # 0.0.0.0/8
            "http://198.18.0.1/x.png",                 # benchmarking
            "http://224.0.0.1/x.png",                  # multicast (is_global alone admits it)
            "http://[ff0e::1]/x.png",                  # IPv6 multicast (likewise)
            "http://127.0.0.1/x.png",
            "http://10.0.0.1/x.png",
            "http://[::1]/x.png",
        ]
        for url in cases:
            with self.subTest(url=url):
                self.net.connects.clear()
                self.assert_no_connect(url, self.fetch(url))

    def test_names_resolving_to_internal_addresses_are_refused_without_connecting(self):
        cases = {
            "tailnet-node.example": "100.64.0.7",
            "magicdns.example": "100.100.100.100",
            "metadata.example": "169.254.169.254",
            "ula.example": "fd12:3456:789a::1",
            "mapped.example": "::ffff:127.0.0.1",
            "nat64.example": "64:ff9b::a00:1",
        }
        for name, addr in cases.items():
            self.net.answer(name, [addr])
            url = f"http://{name}/x.png"
            with self.subTest(url=url, resolves_to=addr):
                self.net.connects.clear()
                self.assert_no_connect(url, self.fetch(url))

    def test_one_internal_answer_among_public_ones_refuses_the_url(self):
        self.net.answer("mixed.example", [PUBLIC_A, "100.64.0.9"])
        self.assert_no_connect("http://mixed.example/x.png", self.fetch("http://mixed.example/x.png"))

    def test_non_http_schemes_are_refused(self):
        # The names resolve to a public address, so only the scheme check refuses them.
        for name in ("ftp.example", "gopher.example"):
            self.net.answer(name, [PUBLIC_A])
        for url in ("file:///etc/passwd", "ftp://ftp.example/x.png", "gopher://gopher.example/",
                    "http:///x.png", "not a url"):
            with self.subTest(url=url):
                self.net.connects.clear()
                resp = self.fetch(url)
                self.assert_no_connect(url, resp)
                self.assertEqual(resp.json().get("detail"), self.REFUSED)

    # ── DNS rebinding: the fetch must not resolve the name again ─────────────
    def test_fetch_connects_to_the_vetted_address_not_a_second_lookup(self):
        lsn = self.listen(OK_PNG)
        self.net.serve(PUBLIC_A, 80, lsn)
        # First answer public (what the guard sees), every later answer loopback.
        self.net.answer("rebind.example", [PUBLIC_A], ["127.0.0.1"])
        resp = self.fetch("http://rebind.example/cat.png")
        bad = [c for c in self.net.connects if c[2] != PUBLIC_A]
        self.assertEqual(bad, [], f"connected to an address the guard never vetted: {bad}")
        self.assertEqual(self.net.lookups.get("rebind.example"), 1,
                         "the name was resolved again after the guard vetted it")
        self.assertEqual(resp.status_code, 200, resp.text)

    def test_fetch_dials_the_ip_literal_and_keeps_the_host_header(self):
        lsn = self.listen(OK_PNG)
        self.net.serve(PUBLIC_B, 8080, lsn)
        self.net.answer("img.example", [PUBLIC_B])
        resp = self.fetch("http://img.example:8080/cat.png?size=16")
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()["result"]["perceptual_hash"], PNG_PHASH)
        self.assertEqual(self.net.connects, [(PUBLIC_B, 8080, PUBLIC_B)],
                         "the connect must name the vetted IP literal, not the hostname")
        self.assertEqual(self.net.lookups.get("img.example"), 1)
        self.assertEqual(len(lsn.requests), 1)
        head = lsn.requests[0].decode("latin-1").split("\r\n")
        self.assertEqual(head[0], "GET /cat.png?size=16 HTTP/1.1")
        hosts = [h.split(":", 1)[1].strip() for h in head[1:] if h.lower().startswith("host:")]
        self.assertEqual(hosts, ["img.example:8080"])

    def test_public_ipv6_literal_is_fetched(self):
        lsn = self.listen(OK_PNG)
        self.net.serve(PUBLIC_V6, 80, lsn)
        resp = self.fetch(f"http://[{PUBLIC_V6}]/cat.png")
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(self.net.connects, [(PUBLIC_V6, 80, PUBLIC_V6)])

    def test_idn_host_is_resolved_and_sent_in_its_ascii_form(self):
        lsn = self.listen(OK_PNG)
        self.net.serve(PUBLIC_C, 80, lsn)
        self.net.answer("xn--bcher-kva.example", [PUBLIC_C])
        resp = self.fetch("http://bücher.example/cat.png")
        self.assertEqual(resp.status_code, 200, resp.text)
        head = lsn.requests[0].decode("latin-1").split("\r\n")
        hosts = [h.split(":", 1)[1].strip() for h in head[1:] if h.lower().startswith("host:")]
        self.assertEqual(hosts, ["xn--bcher-kva.example"])

    # ── no route around the pin ───────────────────────────────────────────────
    def test_redirect_is_not_followed(self):
        lsn = self.listen(http_response("302 Found", b"", ("Location: http://169.254.169.254/latest/meta-data/",)))
        self.net.serve(PUBLIC_A, 80, lsn)
        self.net.answer("redirect.example", [PUBLIC_A])
        resp = self.fetch("http://redirect.example/cat.png")
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertEqual(self.net.connects, [(PUBLIC_A, 80, PUBLIC_A)],
                         f"the redirect was followed: {self.net.connects}")
        self.assertEqual(resp.json().get("detail"), self.FETCH_FAILED)

    def test_proxy_environment_cannot_reroute_the_fetch(self):
        lsn = self.listen(OK_PNG)
        self.net.serve(PUBLIC_A, 80, lsn)
        self.net.answer("img.example", [PUBLIC_A])
        self.net.answer("proxy.internal.example", ["10.20.30.40"])
        proxy = "http://proxy.internal.example:3128"
        with mock.patch.dict(os.environ, {"HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "ALL_PROXY": proxy,
                                          "http_proxy": proxy, "https_proxy": proxy, "all_proxy": proxy}):
            resp = self.fetch("http://img.example/cat.png")
        self.assertEqual(self.net.connects, [(PUBLIC_A, 80, PUBLIC_A)],
                         f"a proxy variable rerouted the fetch: {self.net.connects}")
        self.assertEqual(resp.status_code, 200, resp.text)

    # ── no probing oracle in the error detail ─────────────────────────────────
    def test_fetch_failure_detail_is_generic(self):
        self.net.answer("down.example", [PUBLIC_B])            # nothing listens there
        resp = self.fetch("http://down.example:22/x.png")
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertNotIn(LEAK_MARKER, resp.text, "the transport error text reached the caller")
        self.assertEqual(resp.json().get("detail"), self.FETCH_FAILED)

        lsn = self.listen(http_response("404 Not Found", b"nope"))
        self.net.serve(PUBLIC_C, 80, lsn)
        self.net.answer("missing.example", [PUBLIC_C])
        resp = self.fetch("http://missing.example/x.png")
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertEqual(resp.json().get("detail"), self.FETCH_FAILED)

    def test_unresolvable_and_internal_names_get_the_same_detail(self):
        self.net.answer("internal-svc.example", ["10.43.0.10"])
        a = self.fetch("http://internal-svc.example/x.png")
        b = self.fetch("http://no-such-name.example/x.png")
        self.assertEqual((a.status_code, b.status_code), (400, 400))
        self.assertEqual(a.json().get("detail"), b.json().get("detail"),
                         "the detail tells an existing internal name from a missing one")
        self.assertEqual(a.json().get("detail"), self.REFUSED)


class ImageUrlTls(unittest.TestCase):
    """Pinning must not break HTTPS: SNI and the certificate check use the name."""

    @classmethod
    def setUpClass(cls):
        if shutil.which("openssl") is None:
            raise RuntimeError("openssl CLI not found; the TLS tests need it for a throwaway CA")
        cls._dir = tempfile.mkdtemp(prefix="edge-ai-ssrf-pki-")
        cls.pki = _make_test_pki(cls._dir)
        cls.client = TestClient(APP.app, raise_server_exceptions=False)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._dir, ignore_errors=True)

    def setUp(self):
        self.net = install_fake_net(self)
        trust =ssl.create_default_context(cafile=self.pki["ca.pem"])
        patcher = mock.patch.object(APP, "_TLS_CONTEXT", trust)
        patcher.start()
        self.addCleanup(patcher.stop)
        server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.minimum_version = ssl.TLSVersion.TLSv1_2
        server.load_cert_chain(self.pki["leaf.pem"], self.pki["leaf.key"])
        self.lsn = Listener(OK_PNG, tls=server)
        self.addCleanup(self.lsn.close)
        self.net.serve(PUBLIC_A, 443, self.lsn)

    def test_https_verifies_against_the_original_name(self):
        self.net.answer("tls.example", [PUBLIC_A])
        resp = self.client.post(ENDPOINT, json={"image_url": "https://tls.example/cat.png"})
        self.assertEqual(self.lsn.server_names, ["tls.example"], "SNI must carry the original name")
        self.assertEqual(self.net.connects, [(PUBLIC_A, 443, PUBLIC_A)])
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()["result"]["perceptual_hash"], PNG_PHASH)

    def test_https_with_a_certificate_for_another_name_fails(self):
        self.net.answer("other.example", [PUBLIC_A])
        resp = self.client.post(ENDPOINT, json={"image_url": "https://other.example/cat.png"})
        self.assertEqual(self.lsn.server_names, ["other.example"])
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertEqual(resp.json().get("detail"), "could not fetch image_url")
        self.assertEqual(self.lsn.requests, [], "a request was sent over an unverified connection")


if __name__ == "__main__":
    unittest.main(verbosity=2)
