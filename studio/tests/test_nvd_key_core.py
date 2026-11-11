"""core/nvd_key.py — the NVD API key OWASP Dependency-Check needs (FAKE keys only).

Pins: empty refused, whitespace trimmed, malformed refused before any request; the
Verify classifier maps each response class measured against NVD on 2026-11-10 to its
sentence; no redirect is followed; IPv4 is tried before IPv6; the store is 0700/0600
and the sidecar holds no key; the per-run copy; redaction of Dependency-Check's
``XXXXX-*****-XXXXX`` echo; the org-secret push puts the value on stdin only and
refuses an empty or unverified key before running anything.
"""
from __future__ import annotations

import email.message
import http.server
import io
import json
import os
import socket
import stat
import threading
import urllib.error
import urllib.request

import pytest

from hugmesh_studio.core import nvd_key
from hugmesh_studio.core.org_export import RunResult

# FAKE keys: well-formed UUIDs NVD has never issued.
KEY = "11111111-2222-4333-8444-555555555555"
KEY2 = "abcdef01-2345-4678-9abc-def012345678"
POSIX = pytest.mark.skipif(os.name == "nt", reason="POSIX file modes")


# ── a fake opener: records the request, answers with a canned outcome ───────────────
class _Resp:
    def __init__(self, status, body=b"", headers=None):
        self.status = status
        self._body = body
        self.headers = _headers(headers or {})

    def getcode(self):
        return self.status

    def read(self, n=-1):
        return self._body

    def close(self):
        pass


def _headers(d):
    m = email.message.Message()
    for k, v in d.items():
        m[k] = v
    return m


class FakeOpener:
    def __init__(self, outcome):
        self.outcome = outcome
        self.requests = []

    def open(self, req, timeout=None):
        self.requests.append(req)
        o = self.outcome
        if isinstance(o, BaseException):
            raise o
        status, body, headers = o
        if status >= 400 or 300 <= status < 400:
            raise urllib.error.HTTPError(req.full_url, status, "x", _headers(headers),
                                         io.BytesIO(body))
        return _Resp(status, body, headers)


NVD_200 = (200, json.dumps({"resultsPerPage": 1, "totalResults": 421929,
                            "format": "NVD_CVE"}).encode(), {"content-type": "application/json"})
NVD_404_KEY = (404, b"", {"message": "Invalid apiKey."})
NVD_404_HTML = (404, b"<html>not found</html>", {"content-type": "text/html"})


# ── shape ──────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("raw", ["", "   ", "\n", None, "\t \n"])
def test_empty_is_refused_with_the_shared_sentence(raw):
    with pytest.raises(nvd_key.NvdKeyError) as ei:
        nvd_key.check(raw)
    assert ei.value.verdict == nvd_key.MISSING
    assert nvd_key.EMPTY_REFUSED in str(ei.value)


@pytest.mark.parametrize("raw", [f"  {KEY}\n", f"{KEY} ", f"\t{KEY}\r\n", KEY.upper()])
def test_surrounding_whitespace_is_trimmed(raw):
    assert nvd_key.check(raw) == raw.strip()


@pytest.mark.parametrize("raw", ["not-a-uuid", KEY[:-1], KEY + "0", KEY.replace("-", ""),
                                 KEY[:8] + " " + KEY[9:], "zzzzzzzz-2222-4333-8444-555555555555"])
def test_malformed_is_refused(raw):
    with pytest.raises(nvd_key.NvdKeyError) as ei:
        nvd_key.check(raw)
    assert ei.value.verdict == nvd_key.MALFORMED


@pytest.mark.parametrize("raw, verdict", [("", nvd_key.MISSING), ("nope", nvd_key.MALFORMED)])
def test_verify_refuses_locally_and_sends_nothing(raw, verdict):
    op = FakeOpener(NVD_200)
    res = nvd_key.verify(raw, opener=op)
    assert res.verdict == verdict
    assert op.requests == []


# ── the classifier, against each measured response class ────────────────────────────
@pytest.mark.parametrize("outcome, verdict, words", [
    (NVD_200, nvd_key.OK, "NVD API has 421,929 records"),
    (NVD_404_KEY, nvd_key.NOT_ACCEPTED, "click the activation link in NVD's email"),
    (NVD_404_HTML, nvd_key.NVD_UNAVAILABLE, "not your key"),
    ((403, b"", {}), nvd_key.RATE_LIMITED, "retry in 30 seconds"),
    ((429, b"", {}), nvd_key.RATE_LIMITED, "retry in 30 seconds"),
    ((503, b"", {}), nvd_key.NVD_UNAVAILABLE, "HTTP 503"),
    ((200, b"<html>maintenance</html>", {}), nvd_key.NVD_UNAVAILABLE, "not with its CVE data"),
    ((302, b"", {"location": "https://elsewhere.example/"}), nvd_key.NVD_UNAVAILABLE, "HTTP 302"),
    (urllib.error.URLError(socket.gaierror(-2, "Name or service not known")),
     nvd_key.OFFLINE, "check the network/VPN"),
    (urllib.error.URLError(TimeoutError("timed out")), nvd_key.OFFLINE, "the key was not tested"),
    (socket.timeout("timed out"), nvd_key.OFFLINE, "the key was not tested"),
    (ConnectionRefusedError(111, "refused"), nvd_key.OFFLINE, "services.nvd.nist.gov"),
    (ConnectionResetError(104, "reset"), nvd_key.OFFLINE, "services.nvd.nist.gov"),
])
def test_each_response_class_maps_to_its_verdict_and_sentence(outcome, verdict, words):
    op = FakeOpener(outcome)
    res = nvd_key.verify(f" {KEY}\n", opener=op)
    assert res.verdict == verdict, res
    assert words in res.sentence
    assert res.label == nvd_key.VERDICT_LABELS[verdict]
    req = op.requests[0]
    assert req.full_url == nvd_key.VERIFY_URL
    assert req.get_method() == "GET"
    assert req.get_header("Apikey") == KEY          # stripped before it is sent
    # the result object carries no key, in any field or its repr
    assert KEY not in repr(res) and KEY not in res.line()
    assert all(KEY not in str(getattr(res, f)) for f in res.__dataclass_fields__)


def test_ok_carries_the_record_count():
    res = nvd_key.verify(KEY, opener=FakeOpener(NVD_200))
    assert res.ok and res.records == 421929 and res.http_status == 200


def test_not_accepted_says_activation_first_and_new_key_second():
    s = nvd_key.verify(KEY, opener=FakeOpener(NVD_404_KEY)).sentence
    assert s.index("activation link") < s.index("request a new key")


def test_an_empty_message_header_is_not_a_key_verdict():
    res = nvd_key.verify(KEY, opener=FakeOpener((404, b"", {"message": ""})))
    assert res.verdict == nvd_key.NVD_UNAVAILABLE


# ── no redirect, ever: a redirect would carry the apiKey header elsewhere ────────────
def test_the_default_opener_follows_no_redirect(monkeypatch):
    hits = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            hits.append((self.path, self.headers.get("apiKey")))
            if self.path.startswith("/rest"):
                self.send_response(302)
                self.send_header("Location", "/stolen")
                self.end_headers()
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"totalResults": 1}')

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        monkeypatch.setattr(nvd_key, "VERIFY_URL",
                            f"http://127.0.0.1:{srv.server_address[1]}/rest/json/cves/2.0")
        res = nvd_key.verify(KEY, timeout=5)
    finally:
        srv.shutdown()
    assert res.verdict == nvd_key.NVD_UNAVAILABLE and res.http_status == 302
    assert [p for p, _ in hits] == ["/rest/json/cves/2.0"], hits   # /stolen never asked


def test_ipv4_addresses_are_tried_before_ipv6(monkeypatch):
    """Measured 2026-11-10 on the operator's host: NVD's AAAA records black-hole while
    IPv4 answers; the default order spent 4 x the timeout before trying IPv4."""
    order = []
    v6 = (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2606:4700::1", 443, 0, 0))
    v4 = (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("172.65.90.25", 443))
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [v6, v6, v4])

    class FakeSock:
        def __init__(self, family, *a):
            self.family = family

        def settimeout(self, t):
            pass

        def connect(self, sa):
            order.append(sa[0])
            if self.family == socket.AF_INET6:
                raise TimeoutError("timed out")

        def close(self):
            pass

    monkeypatch.setattr(socket, "socket", FakeSock)
    s = nvd_key._connect_v4_first(("services.nvd.nist.gov", 443), 15)
    assert order == ["172.65.90.25"] and s.family == socket.AF_INET


# ── the store ──────────────────────────────────────────────────────────────────────
@POSIX
def test_save_is_0600_in_a_0700_dir_with_no_newline_and_a_keyless_sidecar():
    st = nvd_key.save(f"  {KEY}\n")
    p = nvd_key.key_path()
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode) == 0o700
    assert open(p, "rb").read() == KEY.encode()
    meta = open(nvd_key.meta_path()).read()
    assert KEY not in meta and KEY.replace("-", "") not in meta
    assert st.stored and not st.verified and st.fingerprint in meta
    assert nvd_key.status_line(st) == "stored (not verified)"
    assert nvd_key.load() == KEY


def test_save_refuses_empty_and_malformed_and_stores_nothing():
    for raw in ("", "  \n", "not-a-key"):
        with pytest.raises(nvd_key.NvdKeyError):
            nvd_key.save(raw)
    assert not os.path.exists(nvd_key.key_path())
    assert nvd_key.status_line() == "no key stored"


def test_the_store_lives_under_the_studio_state_dir():
    from hugmesh_studio.core.state_paths import state_dir
    assert nvd_key.key_path() == os.path.join(state_dir(), "secrets", "nvd_api_key")


def test_record_verdict_marks_only_the_stored_key_verified():
    nvd_key.save(KEY)
    other = nvd_key.verify(KEY2, opener=FakeOpener(NVD_200))
    nvd_key.record_verdict(other)                       # a different key: ignored
    assert not nvd_key.status().verified
    nvd_key.record_verdict(nvd_key.verify(KEY, opener=FakeOpener(NVD_200)))
    st = nvd_key.status()
    assert st.verified and nvd_key.status_line(st).startswith("stored, verified 20")
    nvd_key.record_verdict(nvd_key.verify(KEY, opener=FakeOpener(NVD_404_KEY)))
    assert "not accepted yet" in nvd_key.status_line()


def test_saving_a_new_key_resets_the_verdict():
    nvd_key.save(KEY)
    nvd_key.record_verdict(nvd_key.verify(KEY, opener=FakeOpener(NVD_200)))
    nvd_key.save(KEY2)
    assert not nvd_key.status().verified


def test_forget_removes_key_and_sidecar():
    nvd_key.save(KEY)
    assert nvd_key.forget() is True
    assert not os.path.exists(nvd_key.key_path()) and not os.path.exists(nvd_key.meta_path())
    assert nvd_key.forget() is False


# ── the per-run copy ───────────────────────────────────────────────────────────────
@POSIX
def test_materialize_for_run_is_a_private_copy_removed_by_cleanup():
    assert nvd_key.materialize_for_run()[0] is None          # nothing stored
    nvd_key.save(KEY)
    path, cleanup = nvd_key.materialize_for_run()
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode) == 0o700
    assert open(path).read() == KEY
    assert not path.startswith(os.path.dirname(nvd_key.key_path()))
    cleanup()
    assert not os.path.exists(os.path.dirname(path))


# ── redaction ──────────────────────────────────────────────────────────────────────
def test_redact_blanks_the_dc_echo_and_the_key_in_any_case():
    line = f"NvdApiException: Invalid API Key: 11111-*****-55555 (key {KEY.upper()})"
    out = nvd_key.redact(line, KEY)
    assert "11111-" not in out and KEY.upper() not in out and "Invalid API Key:" in out
    assert nvd_key.redact("plain line", KEY) == "plain line"


# ── the org secret ─────────────────────────────────────────────────────────────────
class FakeRunner:
    def __init__(self, set_rc=0, set_err=b"", readback=b"2026-11-10T10:00:00Z\nall\n"):
        self.calls = []
        self.set_rc, self.set_err, self.readback = set_rc, set_err, readback

    def run(self, argv, *, cwd=None, env=None, timeout=600, input=None):
        self.calls.append((list(argv), input))
        if argv[:3] == ["gh", "secret", "set"]:
            return RunResult(self.set_rc, b"", self.set_err)
        return RunResult(0, self.readback, b"")


@pytest.mark.parametrize("raw", ["", "   ", "not-a-key"])
def test_push_refuses_empty_or_malformed_before_spawning_anything(raw):
    r = FakeRunner()
    res = nvd_key.push_org_secret("acme", raw=raw, runner=r, set_anyway=True)
    assert not res.ok and r.calls == []


def test_push_refuses_an_unverified_key_unless_set_anyway():
    nvd_key.save(KEY)
    r = FakeRunner()
    res = nvd_key.push_org_secret("acme", runner=r)
    assert not res.ok and r.calls == [] and nvd_key.ACTIVATION_WARNING in res.sentence
    assert nvd_key.push_refusal("acme") == res.sentence


def test_push_refuses_a_bad_org_name():
    r = FakeRunner()
    res = nvd_key.push_org_secret("no such/org", raw=KEY, runner=r, set_anyway=True)
    assert not res.ok and r.calls == []


def test_push_sends_the_value_on_stdin_only_and_reads_back():
    nvd_key.save(f"{KEY}\n")
    nvd_key.record_verdict(nvd_key.verify(KEY, opener=FakeOpener(NVD_200)))
    r = FakeRunner()
    res = nvd_key.push_org_secret("acme", runner=r)
    assert res.ok and res.updated_at == "2026-11-10T10:00:00Z" and res.visibility == "all"
    (set_argv, set_in), (rb_argv, rb_in) = r.calls
    assert set_argv == ["gh", "secret", "set", "NVD_API_KEY", "--org", "acme",
                        "--visibility", "all"]
    assert set_in == KEY.encode()                              # exact bytes, no newline
    assert all(KEY not in a for a in set_argv + rb_argv) and rb_in is None
    assert "--body" not in set_argv


def test_push_names_admin_org_on_403_and_never_echoes_the_key():
    r = FakeRunner(set_rc=1, set_err=f"HTTP 403: Must have admin rights ({KEY})".encode())
    res = nvd_key.push_org_secret("acme", raw=KEY, runner=r, set_anyway=True)
    assert not res.ok and "gh auth refresh -s admin:org" in res.sentence
    assert KEY not in res.sentence


def test_subprocess_runner_hands_input_to_the_child_stdin(tmp_path):
    import sys
    from hugmesh_studio.core.org_export import SubprocessRunner
    r = SubprocessRunner().run([sys.executable, "-c",
                                "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read()[::-1])"],
                               input=b"abc")
    assert r.returncode == 0 and r.stdout == b"cba"
