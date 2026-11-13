"""A Tor v3 onion as a HugMesh token's login server (core/mesh_token.py).

Operator report (2026-11-12): "when I try to make a local hugmesh token the uri field
doesn't seem to accept the onion uri as an example". Before the fix every face refused
an onion three ways, all from ``check_fields``: ``https://<onion>/`` was "outside its
access domain" (an onion is never under a DNS name), ``http://<onion>`` was "must be an
https:// URL", and ``https://<onion>/login`` (what the monitor's per-domain Copy hands
out) was "only a host". Now one core rule, :func:`login_server_problem`, accepts a v3
onion over http or https, refuses a malformed one with its own sentence, and keeps every
clear-web rule (https only, inside the access domain, no path or whitespace).

The onions are real, public v3 addresses, so the checksum check is pinned against Tor's
own encoding rather than a value this test computed with the code under test.
"""
import pathlib
import subprocess
import time

import pytest

from hugmesh_studio.core import mesh_node, mesh_token as mt
from hugmesh_studio.core import resource_limits as rl

GENERATOR = pathlib.Path(__file__).resolve().parents[2]

#: DuckDuckGo's and the Tor Project's published v3 onions.
ONION = "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"
ONION2 = "2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion"

try:
    KEYGEN = mt.ssh_keygen()
except mt.TokenError:
    KEYGEN = None
needs_keygen = pytest.mark.skipif(KEYGEN is None, reason="no OpenSSH ssh-keygen")


def _check(login_server, domain="example.org"):
    now = int(time.time())
    mt._new_grant(issuer="ssh-ed25519 AAAA", now=now, auth_key="hskey-not-real",
                  mesh="west", domain=domain, role="user", shell=False,
                  login_server=login_server, lifetime_s=3600, node_name="")


# ── the shared rule ──────────────────────────────────────────────────────────────
@pytest.mark.parametrize("url", [
    f"http://{ONION}", f"https://{ONION}", f"http://{ONION}/", f"https://{ONION}/",
    f"http://{ONION}:8080", f"https://{ONION2}:443/", f"http://{ONION.upper()}",
    # Tor ignores names in front of the address; the service sees them as its Host
    f"https://hs.{ONION}", f"https://a.b.{ONION}:8443",
])
def test_a_v3_onion_is_a_login_server_in_any_access_domain(url):
    assert mt.login_server_problem(url, "example.org") == ""
    _check(url)                                   # issue's own check: no TokenError
    assert mt.is_onion_login(url)


@pytest.mark.parametrize("url,needle", [
    # v2 (16 characters) — retired by Tor
    ("http://expyuzz4wqqyqhjn.onion", "v2 onion address"),
    # wrong length
    ("http://abc.onion", "has 3 characters before .onion"),
    (f"http://{ONION[:-6]}a.onion", "has 57 characters before .onion"),
    # wrong alphabet: base32 has no 0, 1, 8, 9
    (f"http://{ONION[:-7]}1.onion", "outside the onion alphabet"),
    # one character mistyped: same length, same alphabet, fails the checksum
    (f"http://e{ONION[1:]}", "checksum does not match"),
    # a name in front of the address that is not a DNS label
    (f"http://-hs.{ONION}", "name in front of the onion address"),
    # a name in front of a mistyped address
    (f"http://hs.e{ONION[1:]}", "checksum does not match"),
])
def test_a_malformed_onion_is_refused_with_its_own_reason(url, needle):
    why = mt.login_server_problem(url, "example.org")
    assert needle in why, why
    with pytest.raises(mt.TokenError, match=needle):
        _check(url)


def test_a_path_is_refused_and_the_sentence_says_what_to_drop():
    why = mt.login_server_problem(f"https://{ONION}/login", "example.org")
    assert "only a host" in why
    assert f"Drop '/login': use https://{ONION}." in why


@pytest.mark.parametrize("url,needle", [
    # the clear-web rules are unchanged by the onion exception
    ("http://hs.example.org", "https://"),
    ("https://hs.evil.net", "outside its access domain"),
    # an onion-looking label inside a DNS name is not an onion
    (f"https://{ONION[:-6]}.onion.evil.net", "outside its access domain"),
    (f"http://x.onion.example.org", "https://"),
    # a trailing dot is not the onion TLD
    (f"https://{ONION}.", "outside its access domain"),
    # TS_EXTRA_ARGS is word-split: nothing may follow the host and port
    (f"http://{ONION}/ --ssh", "only a host"),
    (f"http://{ONION}\t--advertise-exit-node", "only a host"),
    (f"ftp://{ONION}", "only a host"),
    (f"http://{ONION}:0", "not between 1 and 65535"),
    (f"http://{ONION}:70000", "not between 1 and 65535"),
])
def test_everything_else_stays_refused(url, needle):
    with pytest.raises(mt.TokenError, match=needle):
        _check(url)


def test_the_hint_is_the_reason_else_the_onion_note_else_nothing():
    assert mt.login_server_hint("", "example.org") == ""
    assert mt.login_server_hint("https://hs.example.org", "example.org") == ""
    assert mt.login_server_hint(f"http://{ONION}", "example.org") == mt.ONION_NOTE
    assert "v2 onion" in mt.login_server_hint("http://expyuzz4wqqyqhjn.onion", "")
    # with the access domain still empty, only the URL itself is judged
    assert mt.login_server_hint("https://hs.example.org", "") == ""
    assert "outside" in mt.login_server_hint("https://hs.example.org", "other.org")


def test_the_example_onion_is_one_the_rule_accepts_and_names_no_real_service():
    assert mt.is_onion_login(mt.ONION_EXAMPLE)
    assert ONION not in mt.ONION_EXAMPLE and ONION2 not in mt.ONION_EXAMPLE


# ── the issued token carries the onion, and the tray acts on it ───────────────────
@pytest.fixture
def issuer(tmp_path):
    key = tmp_path / "issuer"
    subprocess.run([KEYGEN, "-q", "-t", "ed25519", "-N", "", "-C", "test-issuer",
                    "-f", str(key)], check=True)
    return str(key)


@needs_keygen
@pytest.mark.parametrize("url", [f"http://{ONION}", f"https://{ONION}:443/"])
def test_an_onion_token_is_signed_carried_and_verified(issuer, url):
    token = mt.issue(key_path=issuer, mesh="west", domain="example.org", role="admin",
                     shell=True, login_server=url, auth_key="hskey-not-real",
                     lifetime_s=3600)
    mt.trust_issuer(open(issuer + ".pub").read())
    g = mt.verify(token)                          # the tray's own check
    assert g.login_server == url.rstrip("/")         # issue() drops a trailing /
    assert f"--login-server={url.rstrip('/')}" in g.extra_args().split()


@pytest.fixture
def compose(monkeypatch, tmp_path):
    calls = []

    def fake_run(argv, **kw):
        calls.append((list(argv), dict(kw.get("env") or {})))
        out = "abc123\n" if "ps" in argv else ""
        return subprocess.CompletedProcess(argv, 0, out, "")

    monkeypatch.setattr(mesh_node, "_compose_base", lambda: ["docker", "compose"])
    monkeypatch.setattr(mesh_node.subprocess, "run", fake_run)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    for k in (rl.CPUS_ENV, rl.MEMORY_ENV, rl.GPUS_ENV, "TS_AUTHKEY", "TS_EXTRA_ARGS"):
        monkeypatch.delenv(k, raising=False)
    return calls


def test_the_tray_node_starts_with_the_onion_login_server(compose, tmp_path):
    now = int(time.time())
    g = mt.MeshGrant(mesh="west", domain="example.org", role="user", shell=False,
                     login_server=f"http://{ONION}", auth_key="hskey-from-token",
                     expires=now + 3600, issued=now, issuer="ssh-ed25519 AAAA")
    node = mt.GrantedMeshNode(str(GENERATOR), str(tmp_path / "node"), load=lambda: g)
    ok, why = node.start()
    assert ok, why
    ups = [env for a, env in compose if a[-2:] == ["up", "-d"]]
    assert len(ups) == 1, compose
    assert ups[0]["TS_EXTRA_ARGS"].split() == [
        f"--login-server=http://{ONION}", "--accept-routes", "--ssh=false"]


# ── the command line ─────────────────────────────────────────────────────────────
def test_the_cli_help_names_the_onion_form(capsys):
    with pytest.raises(SystemExit):
        mt.main(["issue", "--help"])
    out = " ".join(capsys.readouterr().out.split())
    assert ".onion" in out


@needs_keygen
def test_the_cli_issues_an_onion_token_and_says_what_it_needs(issuer, tmp_path, capsys):
    keyfile = tmp_path / "key.txt"
    keyfile.write_text("hskey-not-real\n")
    assert mt.main(["issue", "--key", str(issuer), "--mesh", "west", "--domain",
                    "example.org", "--role", "user", "--login-server", f"http://{ONION}",
                    "--authkey-file", str(keyfile), "--expires", "1h"]) == 0
    out, err = capsys.readouterr()
    g, _, _ = mt.parse(out.split()[0])
    assert g.login_server == f"http://{ONION}"
    assert mt.ONION_NOTE in err


def test_the_cli_refuses_a_v2_onion_before_anything_is_created(tmp_path, monkeypatch,
                                                               capsys):
    created = []
    monkeypatch.setattr(mt, "ensure_issuer", lambda *a, **k: created.append(a))
    keyfile = tmp_path / "key.txt"
    keyfile.write_text("hskey-not-real\n")
    rc = mt.main(["issue", "--mesh", "west", "--domain", "example.org", "--role", "user",
                  "--login-server", "http://expyuzz4wqqyqhjn.onion",
                  "--authkey-file", str(keyfile), "--expires", "1h"])
    out, err = capsys.readouterr()
    assert rc != 0 and created == [] and out == ""
    assert "v2 onion address" in err and "Traceback" not in err
