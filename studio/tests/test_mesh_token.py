"""Signed HugMesh tokens (core/mesh_token.py) and the tray's token-run mesh node.

Operator ask (2026-11-04): the tray must run the mesh "per access domain and role
permissions as well as shell access permissions as permitted when a hugmesh token is
shared", and obey the Resource limits set from the tray.

Signing and verifying go through OpenSSH's real ``ssh-keygen -Y`` (no fakes), so a
host without ssh-keygen skips those tests. Node tests use a fixed grant and a recorded
``docker compose`` — the shape test_limits_reach_lanes.py uses.
"""
import json
import os
import pathlib
import shutil
import subprocess
import time

import pytest

from hugmesh_studio.core import mesh_node, mesh_token as mt
from hugmesh_studio.core import resource_limits as rl

GENERATOR = pathlib.Path(__file__).resolve().parents[2]

try:
    KEYGEN = mt.ssh_keygen()
except mt.TokenError:
    KEYGEN = None
needs_keygen = pytest.mark.skipif(KEYGEN is None, reason="no OpenSSH ssh-keygen")

GOOD = dict(mesh="west", domain="example.org", role="admin", shell=True,
            login_server="https://hs.example.org", auth_key="hskey-not-real",
            lifetime_s=3600)


@pytest.fixture
def issuer(tmp_path):
    key = tmp_path / "issuer"
    subprocess.run([KEYGEN, "-q", "-t", "ed25519", "-N", "", "-C", "test-issuer",
                    "-f", str(key)], check=True)
    return str(key)


def _issue(key, **over):
    return mt.issue(key_path=key, **{**GOOD, **over})


def _sign_raw(key, payload: dict) -> str:
    """Sign arbitrary fields the way a ROGUE issuer could — bypassing issue()'s
    checks — so verify() is shown to refuse them on its own."""
    body = mt._canonical({"format": mt.FORMAT, **payload})
    data = pathlib.Path(key).with_name("raw-payload")
    data.write_bytes(body)
    subprocess.run([KEYGEN, "-Y", "sign", "-f", key, "-n", mt.NAMESPACE, str(data)],
                   check=True, capture_output=True)
    sig = pathlib.Path(str(data) + ".sig").read_bytes()
    os.remove(str(data) + ".sig")
    return f"{mt.FORMAT}.{mt._b64u(body)}.{mt._b64u(sig)}"


def _fields(token):
    return json.loads(mt._unb64u(token.split(".")[1]))


# ── issue / verify ────────────────────────────────────────────────────────────────
@needs_keygen
def test_a_token_from_an_untrusted_issuer_is_refused_until_trusted(issuer):
    token = _issue(issuer)
    with pytest.raises(mt.TokenError) as e:
        mt.verify(token)
    assert e.value.kind == "untrusted"
    fp = mt.fingerprint(e.value.issuer)
    assert fp in str(e.value)
    assert mt.trust_issuer(open(issuer + ".pub").read()) == fp
    g = mt.verify(token)
    assert (g.domain, g.role, g.shell) == ("example.org", "admin", True)


@needs_keygen
def test_fingerprint_matches_what_ssh_keygen_prints(issuer):
    out = subprocess.run([KEYGEN, "-lf", issuer + ".pub"], capture_output=True,
                         text=True, check=True).stdout
    assert mt.fingerprint(open(issuer + ".pub").read()) == out.split()[1]


@needs_keygen
@pytest.mark.parametrize("field,value", [("role", "superadmin"), ("shell", True),
                                         ("domain", "other.org"),
                                         ("auth_key", "someone-elses-key")])
def test_an_edited_token_fails_its_signature(issuer, field, value):
    mt.trust_issuer(open(issuer + ".pub").read())
    token = _issue(issuer, shell=False)
    data = _fields(token)
    data[field] = value
    data.pop("format")
    edited = (f"{mt.FORMAT}.{mt._b64u(mt._canonical({'format': mt.FORMAT, **data}))}."
              f"{token.split('.')[2]}")
    with pytest.raises(mt.TokenError) as e:
        mt.verify(edited)
    assert e.value.kind == "signature"


@needs_keygen
def test_issue_refuses_shell_for_a_role_that_cannot_hold_it(issuer):
    for role in ("user", "mod"):
        with pytest.raises(mt.TokenError, match="only admin and superadmin"):
            _issue(issuer, role=role, shell=True)


@needs_keygen
@pytest.mark.parametrize("over,needle", [
    ({"role": "user", "shell": True}, "only admin and superadmin"),
    ({"login_server": "https://hs.evil.net"}, "outside its access domain"),
    ({"login_server": "https://notexample.org"}, "outside its access domain"),
    ({"login_server": "http://hs.example.org"}, "https://"),
    ({"role": "root"}, "is not one of"),
])
def test_verify_refuses_a_signed_token_that_grants_too_much(issuer, over, needle):
    """A rogue or buggy issuer's SIGNED token is still refused by the tray."""
    mt.trust_issuer(open(issuer + ".pub").read())
    fields = _fields(_issue(issuer, shell=False))
    fields.pop("format")
    fields.update(over)
    with pytest.raises(mt.TokenError, match=needle) as e:
        mt.verify(_sign_raw(issuer, fields))
    assert e.value.kind == "invalid"


@needs_keygen
def test_an_expired_token_is_refused(issuer):
    mt.trust_issuer(open(issuer + ".pub").read())
    token = _issue(issuer)
    g = mt.verify(token)
    with pytest.raises(mt.TokenError) as e:
        mt.verify(token, now=g.expires)
    assert e.value.kind == "expired"


@needs_keygen
def test_a_token_survives_being_wrapped_when_pasted(issuer):
    mt.trust_issuer(open(issuer + ".pub").read())
    token = _issue(issuer)
    wrapped = "\n".join(token[i:i + 64] for i in range(0, len(token), 64)) + "\r\n"
    assert mt.save_token(wrapped).domain == "example.org"
    assert mt.load_grant().role == "admin"


def test_garbage_is_not_a_token():
    for text in ("", "hello", "hugmesh-token-v1.!!!.???", "hugmesh-token-v2.a.b"):
        with pytest.raises(mt.TokenError) as e:
            mt.parse(text)
        assert e.value.kind == "malformed"


@needs_keygen
def test_save_keeps_nothing_when_the_token_is_refused(issuer):
    with pytest.raises(mt.TokenError):
        mt.save_token(_issue(issuer))            # issuer not trusted
    assert mt.stored_token() == ""


@needs_keygen
def test_import_flow_asks_before_trusting(issuer):
    from hugmesh_studio.gui import mesh_token_dialog as d  # Qt-free function
    token = _issue(issuer)
    asked = []
    g, why = d.import_token(token, lambda fp: asked.append(fp) or False)
    assert g is None and "not trusted" in why and mt.trusted_issuers() == set()
    g, why = d.import_token(token, lambda fp: True)
    assert g is not None and why == "" and len(asked) == 1


# ── the tray's mesh node under a grant ────────────────────────────────────────────
def _grant(**over):
    now = int(time.time())
    base = dict(mesh="west", domain="example.org", role="admin", shell=False,
                login_server="https://hs.example.org", auth_key="hskey-from-token",
                expires=now + 3600, issued=now, issuer="ssh-ed25519 AAAA")
    return mt.MeshGrant(**{**base, **over})


@pytest.fixture
def compose(monkeypatch, tmp_path):
    """Record `docker compose` calls (argv + env); report a running node on `ps`."""
    calls = []

    def fake_run(argv, **kw):
        calls.append((list(argv), dict(kw.get("env") or {})))
        out = "abc123\n" if "ps" in argv else ""
        return subprocess.CompletedProcess(argv, 0, out, "")

    monkeypatch.setattr(mesh_node, "_compose_base", lambda: ["docker", "compose"])
    monkeypatch.setattr(mesh_node.subprocess, "run", fake_run)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    for k in (rl.CPUS_ENV, rl.MEMORY_ENV, rl.GPUS_ENV, "TS_AUTHKEY"):
        monkeypatch.delenv(k, raising=False)
    return calls


def _node(tmp_path, load):
    return mt.GrantedMeshNode(str(GENERATOR), str(tmp_path / "node"), load=load)


def _up(calls):
    ups = [(a, env) for a, env in calls if a[-2:] == ["up", "-d"]]
    assert len(ups) == 1, calls
    return ups[0]


@pytest.mark.parametrize("shell,flag", [(True, "--ssh"), (False, "--ssh=false")])
def test_the_node_runs_exactly_as_the_token_grants(compose, tmp_path, monkeypatch,
                                                   shell, flag):
    # an ambient env that would WIDEN the grant: shell on, another control plane
    monkeypatch.setenv("TS_EXTRA_ARGS", "--ssh --login-server=https://evil.net")
    monkeypatch.setenv("HUGMESH_NODE_NAME", "spoofed")
    g = _grant(shell=shell, role="admin" if shell else "user")
    ok, why = _node(tmp_path, lambda: g).start()
    assert ok, why
    _, env = _up(compose)
    assert env["TS_AUTHKEY"] == "hskey-from-token"
    assert env["TS_EXTRA_ARGS"].split() == [
        "--login-server=https://hs.example.org", "--accept-routes", flag]
    assert env["HUGMESH_NODE_NAME"].endswith("-example")
    assert "evil" not in env["TS_EXTRA_ARGS"]


def test_an_unusable_token_stops_the_node_even_with_ts_authkey_set(compose, tmp_path,
                                                                   monkeypatch):
    monkeypatch.setenv("TS_AUTHKEY", "ambient-key")

    def expired():
        raise mt.TokenError("expired", "The HugMesh token expired at 2026-11-01 10:00.")
    ok, why = _node(tmp_path, expired).start()
    assert not ok and "expired" in why
    assert not [a for a, _ in compose if "up" in a]


def test_no_token_and_no_key_says_how_to_get_one(compose, tmp_path):
    ok, why = _node(tmp_path, lambda: None).start()
    assert not ok and "Import a HugMesh token" in why


def test_without_a_token_the_node_still_runs_on_ts_authkey(compose, tmp_path, monkeypatch):
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    ok, why = _node(tmp_path, lambda: None).start()
    assert ok, why
    assert _up(compose)[1]["TS_AUTHKEY"] == "operator-key"


def test_a_token_run_node_obeys_the_tray_resource_limits(compose, tmp_path):
    rl.save(rl.ResourceLimits(cpus=2.0, memory="4g"))
    ok, why = _node(tmp_path, lambda: _grant()).start()
    assert ok, why
    argv, _ = _up(compose)
    overlays = [argv[i + 1] for i, a in enumerate(argv) if a == "-f"]
    assert overlays[-1].endswith(mesh_node.LIMITS_OVERLAY)
    text = open(overlays[-1], encoding="utf-8").read()
    assert "cpus: '2'" in text and "memory: '4g'" in text


@pytest.mark.real_stack_probes          # the real MeshNode.status(), on the recorded compose
def test_apply_limits_restarts_only_a_running_node(compose, tmp_path, monkeypatch):
    node = _node(tmp_path, lambda: _grant())
    assert node.apply_limits() == (True, "not running")     # not staged -> not running
    assert node.start()[0]
    compose.clear()
    rl.save(rl.ResourceLimits(cpus=1.0, memory="2g"))
    ok, why = node.apply_limits()
    assert ok, why
    argv, env = _up(compose)
    overlay = [argv[i + 1] for i, a in enumerate(argv) if a == "-f"][-1]
    assert "cpus: '1'" in open(overlay, encoding="utf-8").read()
    assert env["TS_EXTRA_ARGS"].endswith("--ssh=false")       # still under the token


@pytest.mark.skipif(shutil.which("ssh-keygen") is None and os.name != "nt",
                    reason="the System32 fallback is Windows-only")
def test_windows_finds_the_inbox_openssh(monkeypatch):
    if os.name != "nt":
        pytest.skip("Windows only")
    monkeypatch.setenv("PATH", "")
    assert mt.ssh_keygen(osname="nt").lower().endswith(r"openssh\ssh-keygen.exe")


@needs_keygen
def test_a_checked_signature_is_not_rechecked_but_trust_and_expiry_are(issuer, tmp_path):
    mt.trust_issuer(open(issuer + ".pub").read())
    token = _issue(issuer)
    g = mt.verify(token)
    missing = str(tmp_path / "no-such-ssh-keygen")
    assert mt.verify(token, keygen=missing) == g              # no second ssh-keygen run
    with pytest.raises(mt.TokenError) as e:
        mt.verify(token, keygen=missing, now=g.expires)
    assert e.value.kind == "expired"
    mt.distrust_issuer(g.issuer)
    with pytest.raises(mt.TokenError) as e:
        mt.verify(token, keygen=missing)
    assert e.value.kind == "untrusted"
