"""End-to-end tests for the passwordless local-login loopback agent.

These drive a REAL agent over a real loopback socket (bound to 127.0.0.1:0 so the
suite never needs the fixed prod port free) with hand-crafted http.client requests,
exercising the security contract: loopback bind, exact-match Origin allow-list, the
X-Snapdragon-Local preflight header, the DNS-rebinding Host check, never-'*' CORS,
and the single-use / short-TTL credential handoff. No Qt, no network off-box.
"""
import http.client
import json
import threading
from datetime import datetime, timezone

import pytest

from snapdragon_studio.core import local_login_agent as agent_mod
from snapdragon_studio.core.local_login_agent import (
    LocalLoginAgent,
    Role,
    RolesManifest,
    make_server,
)

GOOD_ORIGIN = "http://localhost:4200"
BRAND_ORIGIN = "https://login.acme.internal"


def _write_manifest(tmp_path):
    path = tmp_path / "roles.json"
    RolesManifest(
        roles=[
            Role(id="brandowner", label="Brand Owner", brand="acme",
                 username="brandowner@acme.local", secret="s3cr3t-owner"),
            Role(id="moderator", label="Moderator", brand="acme",
                 username="mod@acme.local", secret="s3cr3t-mod"),
        ],
        origins=frozenset({BRAND_ORIGIN}),
    ).write(str(path))
    return str(path)


@pytest.fixture
def server(tmp_path):
    """A running agent on an ephemeral loopback port; yields the bound port."""
    manifest = _write_manifest(tmp_path)
    agent = LocalLoginAgent(manifest)
    httpd = make_server(agent, host="127.0.0.1", port=0)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    try:
        yield httpd.server_address[1]
    finally:
        httpd.shutdown()
        httpd.server_close()


def _request(port, method, path, *, origin=GOOD_ORIGIN, local_header=True,
             body=None, host=None, extra_headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {}
    if origin is not None:
        headers["Origin"] = origin
    if local_header:
        headers["X-Snapdragon-Local"] = "1"
    if body is not None:
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)
    payload = json.dumps(body).encode() if body is not None else None
    if host is not None:
        # override the Host header (DNS-rebinding simulation)
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", host)
        for k, v in headers.items():
            conn.putheader(k, v)
        if payload is not None:
            conn.putheader("Content-Length", str(len(payload)))
        conn.endheaders(message_body=payload)
    else:
        conn.request(method, path, body=payload, headers=headers)
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    data = json.loads(raw) if raw else None
    return resp, data


# ── happy path ────────────────────────────────────────────────────────────────
def test_roles_returns_metadata_only(server):
    resp, data = _request(server, "GET", "/v1/roles")
    assert resp.status == 200
    assert data["agent"] == "snapdragon-local-login"
    assert data["version"] == 1
    ids = {r["id"] for r in data["roles"]}
    assert ids == {"brandowner", "moderator"}
    for r in data["roles"]:
        assert set(r) == {"id", "label", "brand"}   # NEVER username/secret
    # the secret must not appear anywhere in the wire bytes
    assert "s3cr3t" not in json.dumps(data)


def test_handoff_after_probe_vends_credential(server):
    _request(server, "GET", "/v1/roles")   # arm
    resp, data = _request(server, "POST", "/v1/handoff", body={"roleId": "brandowner"})
    assert resp.status == 200
    assert data["roleId"] == "brandowner"
    assert data["username"] == "brandowner@acme.local"
    assert data["secret"] == "s3cr3t-owner"
    # expiresAt = now + ~30s, Z-suffixed UTC
    exp = datetime.strptime(data["expiresAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    delta = (exp - datetime.now(timezone.utc)).total_seconds()
    assert 20 <= delta <= 31


def test_handoff_is_single_use_until_reprobe(server):
    _request(server, "GET", "/v1/roles")
    r1, _ = _request(server, "POST", "/v1/handoff", body={"roleId": "brandowner"})
    assert r1.status == 200
    r2, d2 = _request(server, "POST", "/v1/handoff", body={"roleId": "brandowner"})
    assert r2.status == 409          # consumed — no re-vend without a fresh probe
    assert "consumed" in d2["error"]
    _request(server, "GET", "/v1/roles")   # re-arm
    r3, _ = _request(server, "POST", "/v1/handoff", body={"roleId": "brandowner"})
    assert r3.status == 200


def test_handoff_unknown_role_is_404(server):
    _request(server, "GET", "/v1/roles")
    resp, _ = _request(server, "POST", "/v1/handoff", body={"roleId": "nope"})
    assert resp.status == 404


def test_handoff_missing_roleid_is_400(server):
    _request(server, "GET", "/v1/roles")
    resp, _ = _request(server, "POST", "/v1/handoff", body={})
    assert resp.status == 400


# ── Origin allow-list ─────────────────────────────────────────────────────────
def test_missing_origin_is_403_and_no_roles(server):
    resp, data = _request(server, "GET", "/v1/roles", origin=None)
    assert resp.status == 403
    assert data is None or "roles" not in data


def test_unlisted_origin_is_403(server):
    resp, _ = _request(server, "GET", "/v1/roles", origin="https://evil.example")
    assert resp.status == 403


def test_no_suffix_or_wildcard_match(server):
    # a look-alike suffix of an allowed origin must NOT be accepted
    resp, _ = _request(server, "GET", "/v1/roles", origin="http://localhost:4200.evil.example")
    assert resp.status == 403


def test_brand_origin_from_manifest_is_allowed(server):
    resp, data = _request(server, "GET", "/v1/roles", origin=BRAND_ORIGIN)
    assert resp.status == 200
    assert data["roles"]


def test_handoff_from_disallowed_origin_never_vends_secret(server):
    _request(server, "GET", "/v1/roles")   # arm from an allowed origin
    resp, data = _request(server, "POST", "/v1/handoff",
                          origin="https://evil.example", body={"roleId": "brandowner"})
    assert resp.status == 403
    assert data is None or "secret" not in data


# ── custom-header preflight requirement ───────────────────────────────────────
def test_missing_local_header_is_403(server):
    resp, _ = _request(server, "GET", "/v1/roles", local_header=False)
    assert resp.status == 403
    resp2, _ = _request(server, "POST", "/v1/handoff", local_header=False,
                        body={"roleId": "brandowner"})
    assert resp2.status == 403


def test_preflight_echoes_exact_origin_never_wildcard(server):
    resp, _ = _request(server, "OPTIONS", "/v1/roles", local_header=False)
    assert resp.status in (200, 204)
    acao = resp.getheader("Access-Control-Allow-Origin")
    assert acao == GOOD_ORIGIN
    assert acao != "*"
    assert resp.getheader("Access-Control-Allow-Methods") == "GET, POST"
    assert resp.getheader("Access-Control-Allow-Headers") == "X-Snapdragon-Local"
    assert resp.getheader("Access-Control-Max-Age")


def test_preflight_disallowed_origin_is_403_no_cors(server):
    resp, _ = _request(server, "OPTIONS", "/v1/roles", origin="https://evil.example",
                       local_header=False)
    assert resp.status == 403
    assert resp.getheader("Access-Control-Allow-Origin") is None


def test_success_response_never_emits_wildcard_acao(server):
    resp, _ = _request(server, "GET", "/v1/roles")
    assert resp.getheader("Access-Control-Allow-Origin") == GOOD_ORIGIN
    assert resp.getheader("Access-Control-Allow-Origin") != "*"


# ── DNS-rebinding Host check ──────────────────────────────────────────────────
def test_bad_host_header_is_403(server):
    resp, _ = _request(server, "GET", "/v1/roles", host="evil.example")
    assert resp.status == 403


def test_correct_host_header_ok(server):
    resp, _ = _request(server, "GET", "/v1/roles", host=f"127.0.0.1:{server}")
    assert resp.status == 200


# ── manifest loader hardening ─────────────────────────────────────────────────
def test_missing_manifest_serves_no_roles(tmp_path):
    m = agent_mod.load_manifest(str(tmp_path / "does-not-exist.json"))
    assert m.roles == []
    assert m.origins == frozenset()


def test_loader_skips_wildcard_and_bad_origins(tmp_path):
    path = tmp_path / "roles.json"
    path.write_text(json.dumps({
        "version": 1,
        "origins": ["https://*.evil.example", "not-a-url", "https://ok.internal"],
        "roles": [
            {"id": "good", "label": "G", "brand": "b", "username": "u@b", "secret": "x"},
            {"id": "bad id!", "label": "B", "brand": "b", "username": "u@b", "secret": "x"},
            {"id": "nofields"},
        ],
    }), encoding="utf-8")
    m = agent_mod.load_manifest(str(path))
    assert m.origins == frozenset({"https://ok.internal"})
    assert [r.id for r in m.roles] == ["good"]


def test_origin_allowlist_fixed_at_startup_not_widened_by_probe(tmp_path):
    """New origins written to the manifest AFTER startup are NOT honored until a
    restart — a request must never widen the allow-list."""
    path = tmp_path / "roles.json"
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")], origins=frozenset()).write(str(path))
    agent = LocalLoginAgent(str(path))
    assert not agent.is_allowed_origin("https://added.internal")
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")],
                  origins=frozenset({"https://added.internal"})).write(str(path))
    agent.probe()   # reloads roles, but must NOT reload origins
    assert not agent.is_allowed_origin("https://added.internal")


def test_write_manifest_is_0600(tmp_path):
    import os
    import stat
    path = tmp_path / "roles.json"
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")]).write(str(path))
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600
