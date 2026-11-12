"""The local login agent on a host with NO peer-uid check (issue #1047, lane M4).

The agent checks which local user connected through ``SO_PEERCRED`` or
``/proc/net/tcp``. Where neither exists it used to FAIL OPEN with a warning on every
non-Linux host. Now the rule is based on what the host can check, not on its name:

* any non-Windows host without a check (FreeBSD, OpenBSD, Solaris, illumos, a Linux
  without ``/proc/net/tcp``) REFUSES: ``--login-agent`` does not start and a server
  built anyway drops every connection, so no unauthenticated handoff is served;
* macOS keeps failing open with its warning (operator decision 2026-11-12), and
  ``HUGMESH_LOCAL_LOGIN_MACOS=refuse`` switches it to a refusal; the switch does
  nothing on any other host;
* Windows is unchanged.

The GUI, the text UI and the command line show the same one-line reason.

The hosts are INJECTED (``peer_check_policy(platform=..., proc_net_tcp=...)``), so
every branch runs on Linux CI; the one ``darwin`` test runs on the macos job of
.github/workflows/studio-tests.yml, where this file is in the named-file list.
"""
from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import threading
import types

import pytest

from hugmesh_studio.core import local_login_agent as agent_mod
from hugmesh_studio.core.local_login_agent import (
    EXIT_NO_PEER_CHECK,
    MACOS_FAIL_OPEN_WARNING,
    MACOS_LOCAL_LOGIN_ENV,
    NO_PEER_CHECK_REASON,
    PEER_ENFORCED,
    PEER_FAIL_OPEN,
    PEER_REFUSED,
    LocalLoginAgent,
    Role,
    RolesManifest,
    make_server,
    peer_check_policy,
)

ORIGIN = "https://login.acme.internal"
NO_PROC = dict(osname="posix", has_getuid=True, proc_net_tcp=False, environ={})

# Real host names Python reports for the hosts this lane covers.
NO_CHECK_HOSTS = ("freebsd14", "openbsd7", "netbsd10", "dragonfly6", "sunos5", "linux")


def _manifest(tmp_path) -> str:
    path = tmp_path / "roles.json"
    RolesManifest(
        roles=[Role(id="owner", label="Owner", brand="acme",
                    username="owner@acme.local", secret="s3cr3t-owner")],
        origins=frozenset({ORIGIN}),
    ).write(str(path))
    return str(path)


def _serve(tmp_path, policy):
    httpd = make_server(LocalLoginAgent(_manifest(tmp_path)), host="127.0.0.1",
                        port=0, policy=policy)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def _call(port, method, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {"Origin": ORIGIN, "X-HugMesh-Local": "1"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.read()
    finally:
        conn.close()


_DROPPED = (http.client.RemoteDisconnected, http.client.BadStatusLine,
            ConnectionResetError, ConnectionError, OSError)


# ── the policy: capability first, name only for the macOS switch ──────────────
@pytest.mark.parametrize("platform", NO_CHECK_HOSTS)
def test_a_host_without_proc_net_tcp_refuses(platform):
    policy = peer_check_policy(platform=platform, **NO_PROC)
    assert policy.mode == PEER_REFUSED
    assert policy.reason == NO_PEER_CHECK_REASON


@pytest.mark.parametrize("platform", ("freebsd14", "sunos5", "linux"))
def test_the_macos_switch_never_makes_another_host_fail_open(platform):
    for value in ("", "fail-open", "FAIL-OPEN", "refuse"):
        host = dict(NO_PROC, environ={MACOS_LOCAL_LOGIN_ENV: value})
        assert peer_check_policy(platform=platform, **host).mode == PEER_REFUSED


def test_a_host_without_getuid_but_not_windows_refuses():
    assert peer_check_policy(osname="posix", platform="sunos5", has_getuid=False,
                             proc_net_tcp=True, environ={}).mode == PEER_REFUSED


def test_macos_keeps_failing_open_with_the_warning_by_default():
    for value in (None, "", "fail-open", " Fail-Open "):
        env = {} if value is None else {MACOS_LOCAL_LOGIN_ENV: value}
        policy = peer_check_policy(platform="darwin", **dict(NO_PROC, environ=env))
        assert policy.mode == PEER_FAIL_OPEN
        assert policy.reason == MACOS_FAIL_OPEN_WARNING


@pytest.mark.parametrize("value", ("refuse", "REFUSE", "off", "typo"))
def test_macos_switched_to_refuse_refuses(value):
    host = dict(NO_PROC, environ={MACOS_LOCAL_LOGIN_ENV: value})
    policy = peer_check_policy(platform="darwin", **host)
    assert policy.mode == PEER_REFUSED
    assert policy.reason == NO_PEER_CHECK_REASON


def test_linux_with_proc_net_tcp_is_enforced_and_windows_is_unchanged():
    assert peer_check_policy(osname="posix", platform="linux", has_getuid=True,
                             proc_net_tcp=True, environ={}).mode == PEER_ENFORCED
    win = peer_check_policy(osname="nt", platform="win32", has_getuid=False,
                            proc_net_tcp=False, environ={})
    assert (win.mode, win.reason) == (PEER_FAIL_OPEN, "")


# ── the agent: no handoff is served without a peer check ─────────────────────
def test_run_refuses_before_reading_the_manifest_or_binding(tmp_path, monkeypatch,
                                                            capsys):
    def no_bind(*a, **k):
        raise AssertionError("a refusing host must not bind the handoff port")

    def no_manifest(*a, **k):
        raise AssertionError("a refusing host must not read the roles manifest")

    monkeypatch.setattr(agent_mod, "make_server", no_bind)
    monkeypatch.setattr(agent_mod, "LocalLoginAgent", no_manifest)
    policy = peer_check_policy(platform="freebsd14", **NO_PROC)
    rc = agent_mod.run(manifest_path=str(tmp_path / "roles.json"), port=0, policy=policy)
    assert rc == EXIT_NO_PEER_CHECK
    assert NO_PEER_CHECK_REASON in capsys.readouterr().err


@pytest.mark.parametrize("platform", ("freebsd14", "sunos5", "linux"))
def test_a_server_built_anyway_serves_no_roles_and_no_handoff(tmp_path, platform):
    httpd = _serve(tmp_path, peer_check_policy(platform=platform, **NO_PROC))
    port = httpd.server_address[1]
    try:
        with pytest.raises(_DROPPED):
            _call(port, "GET", "/v1/roles")
        with pytest.raises(_DROPPED):
            _call(port, "POST", "/v1/handoff", {"roleId": "owner"})
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_macos_by_default_still_serves_the_handoff(tmp_path, monkeypatch):
    """Fail-open by decision: the same server on an injected Mac answers. The real
    peer lookup is stubbed to "unknown", which is what a Mac's TCP socket gives."""
    monkeypatch.setattr(agent_mod, "_peer_uid", lambda conn: None)
    httpd = _serve(tmp_path, peer_check_policy(platform="darwin", **NO_PROC))
    port = httpd.server_address[1]
    try:
        status, body = _call(port, "GET", "/v1/roles")
        assert status == 200 and json.loads(body)["roles"]
        status, body = _call(port, "POST", "/v1/handoff", {"roleId": "owner"})
        assert status == 200 and json.loads(body)["secret"] == "s3cr3t-owner"
    finally:
        httpd.shutdown()
        httpd.server_close()


# ── AF_UNIX: LOCAL_PEERCRED (what getpeereid reads) ───────────────────────────
class _FakeUnixConn:
    family = socket.AF_UNIX

    def __init__(self, raw):
        self.raw = raw
        self.asked = None

    def getsockopt(self, level, opt, buflen=None):
        self.asked = (level, opt)
        if isinstance(self.raw, Exception):
            raise self.raw
        return self.raw


def _xucred(version, uid):
    # struct xucred: u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t[16] ...
    import struct
    return struct.pack("=IIh2x16I", version, uid, 1, *([20] + [0] * 15))


def test_local_peercred_reads_the_xucred_uid():
    conn = _FakeUnixConn(_xucred(0, 501))
    assert agent_mod._local_peercred_uid(conn, opt=1) == 501
    assert conn.asked == (0, 1)                          # SOL_LOCAL, LOCAL_PEERCRED


def test_local_peercred_rejects_an_unknown_version_and_errors():
    assert agent_mod._local_peercred_uid(_FakeUnixConn(_xucred(7, 501)), opt=1) is None
    assert agent_mod._local_peercred_uid(_FakeUnixConn(OSError("no")), opt=1) is None
    assert agent_mod._local_peercred_uid(_FakeUnixConn(b"\0"), opt=1) is None


def test_an_af_unix_check_does_not_make_the_tcp_check_available():
    """LOCAL_PEERCRED exists on a Mac and a FreeBSD, but only for AF_UNIX; the agent's
    transport is TCP, so the policy must not count it as a peer check."""
    assert peer_check_policy(platform="freebsd14", **NO_PROC).refused


@pytest.mark.skipif(not hasattr(socket, "AF_UNIX"), reason="no AF_UNIX sockets")
def test_a_real_af_unix_pair_resolves_our_own_uid():
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        assert agent_mod._peer_uid(a) == os.getuid()
    finally:
        a.close()
        b.close()


# ── one reason, three channels ────────────────────────────────────────────────
@pytest.fixture
def refusing_host(monkeypatch):
    real = agent_mod.peer_check_policy

    def injected(**host):
        return real(**{**dict(platform="freebsd14", **NO_PROC), **host})

    monkeypatch.setattr(agent_mod, "peer_check_policy", injected)


def test_cli_login_agent_prints_the_reason_and_exits(refusing_host, monkeypatch, capsys):
    from hugmesh_studio import app
    monkeypatch.setattr(agent_mod, "make_server", lambda *a, **k: pytest.fail("bound"))
    assert app.main(["--login-agent"]) == EXIT_NO_PEER_CHECK
    assert NO_PEER_CHECK_REASON in capsys.readouterr().err


def test_cli_remember_roles_is_dropped_with_the_reason(refusing_host, monkeypatch, capsys):
    from hugmesh_studio import app
    seen = {}
    monkeypatch.setattr(agent_mod, "run",
                        lambda **k: seen.setdefault("rc", 0))
    # --login-agent is the cheapest Qt-free exit after argument handling.
    app.main(["--remember-roles-for-passwordless-login", "--login-agent"])
    err = capsys.readouterr().err
    assert f"--remember-roles-for-passwordless-login ignored: {NO_PEER_CHECK_REASON}" in err


def test_tui_keyzip_step_shows_the_reason(refusing_host):
    from hugmesh_studio.tui import journey
    j = journey.Journey()
    lines = j.screen_for("keyzip").lines(j)
    assert NO_PEER_CHECK_REASON in lines


def test_tui_keyzip_step_is_quiet_where_local_login_is_enforced(monkeypatch):
    from hugmesh_studio.tui import journey
    real = agent_mod.peer_check_policy
    monkeypatch.setattr(agent_mod, "peer_check_policy", lambda **h: real(
        **{**dict(osname="posix", platform="linux", has_getuid=True,
                  proc_net_tcp=True, environ={}), **h}))
    j = journey.Journey()
    assert j.screen_for("keyzip").lines(j) == [journey.PENDING_NOTE]


def test_gui_keyzip_page_greys_local_login_with_the_reason(refusing_host):
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    from hugmesh_studio.gui.pages.keyzip import KeyZipPage
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    # Seeded ON (the flag or the env var): a refusing host must still not write roles.
    wiz = types.SimpleNamespace(remember_roles_for_passwordless_login=True,
                                login_manifest_path=None,
                                cfg=types.SimpleNamespace(mode="mesh"))
    page = KeyZipPage(wiz)
    try:
        page.show()
        app.processEvents()
        assert page.remember_roles.isChecked() is False
        assert page.remember_roles.isEnabled() is False
        assert page.local_login_reason.text() == NO_PEER_CHECK_REASON
        assert page.local_login_reason.isVisible()
        assert page.local_login_reason.geometry().height() > 0
    finally:
        page.close()
        page.deleteLater()


# ── the real Mac (the macos job) ──────────────────────────────────────────────
@pytest.mark.skipif(sys.platform != "darwin", reason="needs a real Mac")
def test_real_mac_fails_open_by_default_refuses_when_switched_and_reads_xucred(
        tmp_path, monkeypatch):
    monkeypatch.delenv(MACOS_LOCAL_LOGIN_ENV, raising=False)
    assert not os.path.exists("/proc/net/tcp")
    assert peer_check_policy().mode == PEER_FAIL_OPEN
    monkeypatch.setenv(MACOS_LOCAL_LOGIN_ENV, "refuse")
    assert peer_check_policy().refused
    assert agent_mod.run(manifest_path=str(tmp_path / "roles.json"),
                         port=0) == EXIT_NO_PEER_CHECK
    # LOCAL_PEERCRED on a real AF_UNIX pair is our own uid; a TCP loopback pair has
    # no peer uid at all, which is exactly why the policy is not "enforced" here.
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        assert agent_mod._local_peercred_uid(a) == os.getuid()
    finally:
        a.close()
        b.close()
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    cli = socket.create_connection(srv.getsockname())
    conn, _ = srv.accept()
    try:
        assert agent_mod._peer_uid(conn) is None
    finally:
        for s in (conn, cli, srv):
            s.close()


def test_this_file_is_in_the_macos_jobs_named_list():
    import re
    wf = os.path.join(os.path.dirname(__file__), "..", "..", ".github", "workflows",
                      "studio-tests.yml")
    with open(wf, encoding="utf-8") as fh:
        text = fh.read()
    step = text.split("- name: Run the macOS contract", 1)[1].split("- name:", 1)[0]
    assert "tests/test_local_login_no_peer_check.py" in re.findall(
        r"tests/[\w./-]+\.py", step)
