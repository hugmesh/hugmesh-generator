"""End-to-end tests for the passwordless local-login loopback agent.

These drive a REAL agent over a real loopback socket (bound to 127.0.0.1:0 so the
suite never needs the fixed prod port free) with hand-crafted http.client requests,
exercising the security contract: loopback bind, exact-match Origin allow-list, the
X-Snapdragon-Local preflight header, the DNS-rebinding Host check, never-'*' CORS,
and the single-use / short-TTL credential handoff. No Qt, no network off-box.
"""
import http.client
import json
import os
import socket
import threading
from datetime import datetime, timezone

import pytest

from hugmesh_studio.core import local_login_agent as agent_mod
from hugmesh_studio.core.local_login_agent import (
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
    """A running agent on an ephemeral loopback port; yields the bound port.

    Dev origins are opted in (allow_dev_origins=True) because the HTTP contract tests
    drive the localhost dev origin (GOOD_ORIGIN); production gating is covered separately
    by the prod_server fixture below."""
    manifest = _write_manifest(tmp_path)
    agent = LocalLoginAgent(manifest, allow_dev_origins=True)
    httpd = make_server(agent, host="127.0.0.1", port=0)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    try:
        yield httpd.server_address[1]
    finally:
        httpd.shutdown()
        httpd.server_close()


@pytest.fixture
def prod_server(tmp_path, monkeypatch):
    """A running agent with the PRODUCTION posture: no dev opt-in, so the localhost dev
    origins are NOT trusted — only the brand origin from the manifest is."""
    monkeypatch.delenv(agent_mod.DEV_ORIGINS_ENV, raising=False)
    manifest = _write_manifest(tmp_path)
    agent = LocalLoginAgent(manifest)          # no allow_dev_origins
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
    assert data["agent"] == "hugmesh-local-login"
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
    import stat
    path = tmp_path / "roles.json"
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")]).write(str(path))
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600


# ── FINDING 1: OS-level peer-uid authentication (multi-user defense-in-depth) ──
def test_peer_uid_mismatch_drops_connection(server, monkeypatch):
    """A connection whose peer uid differs from the agent's uid (a DIFFERENT local user
    on a multi-user host) must be dropped at the socket layer — before any route runs,
    so the client gets NO HTTP response at all (not even a 403 body it could read)."""
    monkeypatch.setattr(agent_mod, "_peer_uid", lambda conn: os.getuid() + 1)
    with pytest.raises((http.client.RemoteDisconnected, http.client.BadStatusLine,
                        ConnectionResetError, ConnectionError, OSError)):
        _request(server, "GET", "/v1/roles")


def test_peer_uid_match_is_allowed(server):
    """The real loopback peer IS us (same uid), so the happy path still works with the
    peer-uid check ACTIVE (this fixture is NOT monkeypatched)."""
    resp, data = _request(server, "GET", "/v1/roles")
    assert resp.status == 200
    assert {r["id"] for r in data["roles"]} == {"brandowner", "moderator"}


def test_peer_uid_unavailable_fails_open(server, monkeypatch):
    """Where the platform exposes no reliable peer-uid (mechanism returns None) we FAIL
    OPEN with a documented reduced guarantee — never drop every connection."""
    monkeypatch.setattr(agent_mod, "_peer_uid", lambda conn: None)
    resp, data = _request(server, "GET", "/v1/roles")
    assert resp.status == 200
    assert data["roles"]


@pytest.mark.skipif(not agent_mod.PEER_UID_ENFORCED,
                    reason="no reliable OS peer-uid for a TCP socket on this platform")
def test_real_peer_uid_resolves_our_uid_for_a_live_loopback_pair():
    """Prove the ENFORCED mechanism (SO_PEERCRED -> /proc/net/tcp) returns THIS user's
    uid for a genuine loopback connection — guards against a regression that would
    silently reject every request. SO_PEERCRED alone returns -1 for a TCP socket; the
    /proc/net/tcp fallback is what makes the check real."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    result = {}

    def _accept():
        conn, _ = srv.accept()
        result["uid"] = agent_mod._peer_uid(conn)
        conn.close()

    t = threading.Thread(target=_accept)
    t.start()
    client = socket.create_connection(("127.0.0.1", port))
    t.join(timeout=5)
    client.close()
    srv.close()
    assert result["uid"] == os.getuid()


def test_peer_uid_enforced_on_linux():
    """On this Linux host the peer-uid check must be ENFORCED (not silently degraded)."""
    if os.name == "posix" and os.path.exists("/proc/net/tcp"):
        assert agent_mod.PEER_UID_ENFORCED is True


# ── FINDING 2: localhost dev origins gated behind an explicit opt-in ──────────
def test_dev_origins_gated_off_by_default(tmp_path, monkeypatch):
    """A shipped production agent (no opt-in) must NOT trust the localhost dev origins,
    while the real brand origin from the manifest stays trusted."""
    monkeypatch.delenv(agent_mod.DEV_ORIGINS_ENV, raising=False)
    agent = LocalLoginAgent(_write_manifest(tmp_path))     # no allow_dev_origins
    assert not agent.dev_origins_enabled
    assert not agent.is_allowed_origin("http://localhost:4200")
    assert not agent.is_allowed_origin("http://127.0.0.1:4200")
    assert agent.is_allowed_origin(BRAND_ORIGIN)           # brand origin still trusted


def test_dev_origins_enabled_by_flag(tmp_path, monkeypatch):
    monkeypatch.delenv(agent_mod.DEV_ORIGINS_ENV, raising=False)
    agent = LocalLoginAgent(_write_manifest(tmp_path), allow_dev_origins=True)
    assert agent.dev_origins_enabled
    assert agent.is_allowed_origin("http://localhost:4200")
    assert agent.is_allowed_origin("http://127.0.0.1:4200")
    assert agent.is_allowed_origin(BRAND_ORIGIN)


def test_dev_origins_enabled_by_env(tmp_path, monkeypatch):
    monkeypatch.setenv(agent_mod.DEV_ORIGINS_ENV, "1")
    agent = LocalLoginAgent(_write_manifest(tmp_path))     # env is the opt-in
    assert agent.dev_origins_enabled
    assert agent.is_allowed_origin("http://localhost:4200")


def test_dev_origins_enabled_by_manifest_field(tmp_path, monkeypatch):
    monkeypatch.delenv(agent_mod.DEV_ORIGINS_ENV, raising=False)
    path = tmp_path / "roles.json"
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")],
                  origins=frozenset({BRAND_ORIGIN}), dev_origins=True).write(str(path))
    agent = LocalLoginAgent(str(path))                     # manifest devOrigins is the opt-in
    assert agent.dev_origins_enabled
    assert agent.is_allowed_origin("http://localhost:4200")


def test_manifest_dev_origins_round_trips(tmp_path):
    """devOrigins survives write -> load, and only a JSON boolean true enables it."""
    path = tmp_path / "roles.json"
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")], dev_origins=True).write(str(path))
    assert agent_mod.load_manifest(str(path)).dev_origins is True
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")], dev_origins=False).write(str(path))
    assert agent_mod.load_manifest(str(path)).dev_origins is False
    # a truthy-but-not-true value must NOT enable it (no accidental widening)
    path.write_text(json.dumps({"version": 1, "devOrigins": "yes",
                                "roles": []}), encoding="utf-8")
    assert agent_mod.load_manifest(str(path)).dev_origins is False


def test_prod_agent_rejects_localhost_dev_origin_end_to_end(prod_server):
    """End-to-end over a real socket: the production agent 403s a localhost dev origin
    while serving the brand origin from the manifest."""
    resp, data = _request(prod_server, "GET", "/v1/roles", origin="http://localhost:4200")
    assert resp.status == 403
    assert data is None or "roles" not in data
    resp2, data2 = _request(prod_server, "GET", "/v1/roles", origin=BRAND_ORIGIN)
    assert resp2.status == 200
    assert data2["roles"]


def test_dev_origin_fixed_at_startup_not_widened_by_probe(tmp_path, monkeypatch):
    """Like the origins allow-list, the dev-origin decision is made ONCE at startup: a
    manifest that turns devOrigins on AFTER startup must not widen a running agent."""
    monkeypatch.delenv(agent_mod.DEV_ORIGINS_ENV, raising=False)
    path = tmp_path / "roles.json"
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")], dev_origins=False).write(str(path))
    agent = LocalLoginAgent(str(path))
    assert not agent.is_allowed_origin("http://localhost:4200")
    RolesManifest(roles=[Role("r", "R", "b", "u@b", "s")], dev_origins=True).write(str(path))
    agent.probe()   # reloads roles, but must NOT reload the dev-origin decision
    assert not agent.is_allowed_origin("http://localhost:4200")
