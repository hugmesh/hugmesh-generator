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
import threading
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
    # TS_EXTRA_ARGS is word-split: a path with a space would smuggle in a flag
    ({"login_server": "https://hs.example.org/ --advertise-exit-node"}, "only a host"),
    ({"login_server": "https://hs.example.org\t--ssh"}, "only a host"),
    ({"login_server": "https://hs.example.org/x?y#z"}, "only a host"),
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
    token = _issue(issuer)
    asked = []
    g, why = mt.import_token(token, lambda fp: asked.append(fp) or False)
    assert g is None and "not trusted" in why and mt.trusted_issuers() == set()
    g, why = mt.import_token(token, lambda fp: True)
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


# ── review round 1 (#862): identity, enforcement, hardening ──────────────────────
def _downs(calls):
    return [a for a, _ in calls if a[-2:] == ["down", "-v"]]


@pytest.mark.real_stack_probes
def test_a_new_grant_registers_afresh_instead_of_reusing_the_old_identity(compose, tmp_path):
    """tailscale ignores a new auth key once registered, so a changed grant must drop
    the node's saved state (compose down -v) before it starts."""
    holder = {"g": _grant(role="admin", shell=True)}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]
    assert len(_downs(compose)) == 1                           # first token run: state of
    compose.clear()                                            # unknown origin is dropped
    assert node.start()[0]
    assert not _downs(compose)                                 # same grant: keep the identity
    holder["g"] = _grant(role="user", shell=False, auth_key="another-key")
    compose.clear()
    assert node.start()[0]
    assert len(_downs(compose)) == 1                           # downgrade: fresh registration
    assert node.recorded()["summary"] == "user in example.org, no SSH in"


@pytest.mark.real_stack_probes
def test_switching_from_ts_authkey_to_a_token_drops_the_old_identity(compose, tmp_path,
                                                                     monkeypatch):
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    holder = {"g": None}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0] and node.recorded()["summary"] == "TS_AUTHKEY"
    holder["g"] = _grant()
    compose.clear()
    assert node.start()[0]
    assert len(_downs(compose)) == 1


@pytest.mark.real_stack_probes
def test_limits_never_restart_a_node_under_credentials_it_was_not_started_with(
        compose, tmp_path):
    holder = {"g": _grant()}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]
    holder["g"] = _grant(role="superadmin", auth_key="new-key")
    compose.clear()
    ok, why = node.apply_limits()
    assert not ok and "other credentials" in why
    assert not [a for a, _ in compose if "up" in a]


@pytest.mark.real_stack_probes
def test_the_tray_shows_what_the_running_node_was_started_with(compose, tmp_path):
    holder = {"g": _grant(role="admin", shell=True)}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]
    assert node.tray_note(True) == (" — admin in example.org, SSH in", "")
    holder["g"] = _grant(role="user", shell=False, auth_key="k2")
    note, tip = node.tray_note(True)
    assert note == " — admin in example.org, SSH in (restart to apply the current token)"
    assert "Stop and start" in tip
    assert node.tray_note(False)[0] == " — user in example.org, no SSH in"


@pytest.mark.real_stack_probes
def test_a_forgotten_or_expired_token_stops_its_running_node(compose, tmp_path):
    mt.trust_issuer("ssh-ed25519 AAAA")
    holder = {"g": _grant()}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]
    assert node.enforce() == ""                                # still valid: leave it
    holder["g"] = None                                         # Forget token
    compose.clear()
    assert node.enforce().startswith("Stopped the mesh node")
    assert [a for a, _ in compose if a[-1] == "down"]


@pytest.mark.real_stack_probes
def test_a_ts_authkey_node_is_never_stopped_by_enforcement(compose, tmp_path, monkeypatch):
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    node = _node(tmp_path, lambda: None)
    assert node.start()[0]
    compose.clear()
    assert node.enforce() == "" and not compose


def test_an_unexpected_error_reading_the_token_never_escapes_grant(tmp_path):
    def broken():
        raise RuntimeError("state dir exploded")
    g, why = _node(tmp_path, broken).grant()
    assert g is None and "state dir exploded" in why


@pytest.mark.parametrize("issued,expires", [(-1000, -10), (0, 3600), (100, 200)])
def test_absurd_times_are_refused_not_crashed_on(issued, expires):
    g = _grant(issued=issued, expires=expires)
    with pytest.raises(mt.TokenError) as e:
        mt.check_fields(g)
    assert e.value.kind == "invalid"
    assert mt._when(-10)                                       # Windows localtime() raises here


def test_hostname_is_a_valid_label_for_any_domain():
    long_label = "a" * 63
    for g, host in ((_grant(domain=f"{long_label}.org"), "DESKTOP-ABC"),
                    (_grant(domain="example.org", node_name="x" * 80), None),
                    (_grant(domain="example.org"), "---")):
        name = g.hostname(host)
        assert 1 <= len(name) <= 63 and name[0] != "-" and name[-1] != "-", name
        assert set(name) <= set("abcdefghijklmnopqrstuvwxyz0123456789-")


# ── review round 2 (#862) ────────────────────────────────────────────────────────
@pytest.mark.real_stack_probes
def test_a_deleted_workdir_still_drops_the_old_identity(compose, tmp_path, monkeypatch):
    """The tsstate volume belongs to the compose PROJECT, not the workdir."""
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    node = _node(tmp_path, lambda: None)
    assert node.start()[0]
    shutil.rmtree(node.workdir)
    node._load = lambda: _grant()
    compose.clear()
    assert node.start()[0]
    assert len(_downs(compose)) == 1


@pytest.mark.real_stack_probes
def test_the_token_a_node_runs_under_is_enforced_not_the_stored_one(compose, tmp_path):
    mt.trust_issuer("ssh-ed25519 AAAA")
    started = _grant()
    holder = {"g": started}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]
    holder["g"] = _grant(auth_key="token-b", expires=started.expires + 86400)
    assert node.enforce(now=started.expires - 1) == ""         # A still valid: keep running
    compose.clear()
    done = node.enforce(now=started.expires)                   # A expired, B valid: stop
    assert done.startswith("Stopped the mesh node: the HugMesh token it was started with "
                           "expired")
    assert [a for a, _ in compose if a[-1] == "down"]


@pytest.mark.real_stack_probes
def test_a_distrusted_issuer_stops_the_node_it_started(compose, tmp_path):
    mt.trust_issuer("ssh-ed25519 AAAA")
    node = _node(tmp_path, lambda: _grant())
    assert node.start()[0]
    mt.distrust_issuer("ssh-ed25519 AAAA")
    assert "no longer trusted" in node.enforce()


@pytest.mark.real_stack_probes
def test_a_passing_verification_failure_never_stops_a_node(compose, tmp_path):
    mt.trust_issuer("ssh-ed25519 AAAA")
    holder = {"g": _grant()}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]

    def keygen_gone():
        raise mt.TokenError("tool", "ssh-keygen timed out")
    node._load = keygen_gone
    compose.clear()
    assert node.enforce() == ""
    assert not [a for a, _ in compose if "down" in a]          # probed, never stopped


@pytest.mark.real_stack_probes
def test_any_other_start_drops_the_trays_record(compose, tmp_path, monkeypatch):
    """LocalMeshNode shares the workdir and project; its start must not inherit the
    tray's description of what the node runs under."""
    mt.trust_issuer("ssh-ed25519 AAAA")
    node = _node(tmp_path, lambda: _grant())
    assert node.start()[0] and node.recorded()
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    assert mesh_node.MeshNode(str(GENERATOR), node.workdir).start()[0]
    assert node.recorded() == {}
    note, tip = node.tray_note(True)
    assert note == " — started outside this tray (restart to apply)" and tip
    ok, why = node.apply_limits()
    assert not ok and "not started from this tray" in why


# ── Linux-session review (#862 items 4-5) ────────────────────────────────────────
@needs_keygen
def test_a_validly_signed_but_non_canonical_payload_is_refused(issuer):
    """The verifier must check the SAME bytes it parses: a payload with the right
    fields in another serialisation (spaces, key order) is refused, even signed."""
    mt.trust_issuer(open(issuer + ".pub").read())
    fields = _fields(_issue(issuer, shell=False))
    loose = json.dumps(fields, indent=1).encode()                # valid JSON, not canonical
    data = pathlib.Path(issuer).with_name("loose-payload")
    data.write_bytes(loose)
    subprocess.run([KEYGEN, "-Y", "sign", "-f", issuer, "-n", mt.NAMESPACE, str(data)],
                   check=True, capture_output=True)
    sig = pathlib.Path(str(data) + ".sig").read_bytes()
    with pytest.raises(mt.TokenError, match="canonical") as e:
        mt.verify(f"{mt.FORMAT}.{mt._b64u(loose)}.{mt._b64u(sig)}")
    assert e.value.kind == "malformed"


@pytest.mark.parametrize("stderr,ok", [
    (b"unknown option -- Y\nusage: ssh-keygen ...", False),        # OpenSSH < 8.0
    (b"ssh-keygen: illegal option -- Y", False),
    (b"Unsupported operation for -Y: hugmesh-probe", True),          # 8.0+
])
def test_an_openssh_without_sshsig_is_named_not_mistaken_for_forgery(monkeypatch, tmp_path,
                                                                     stderr, ok):
    fake = tmp_path / "ssh-keygen"
    fake.write_text("")
    monkeypatch.setattr(mt.shutil, "which", lambda name: str(fake))
    monkeypatch.setattr(mt, "_SSHSIG_SUPPORT", {})
    monkeypatch.setattr(mt.subprocess, "run",
                        lambda *a, **k: subprocess.CompletedProcess(a[0], 255, b"", stderr))
    if ok:
        assert mt.ssh_keygen() == str(fake)
    else:
        with pytest.raises(mt.TokenError, match="older than 8.0") as e:
            mt.ssh_keygen()
        assert e.value.kind == "tool"


def test_the_grant_wording_says_ssh_in_not_a_shell_elsewhere():
    assert _grant(shell=True).short() == "admin in example.org, SSH in"
    assert "accepts SSH from the mesh" in _grant(shell=True).describe()
    assert "accepts no SSH from the mesh" in _grant(shell=False).describe()


@pytest.mark.real_stack_probes
def test_the_identity_record_holds_no_key_and_no_plain_hash_of_it(compose, tmp_path):
    import hashlib
    g = _grant(auth_key="hskey-secret-value")
    node = _node(tmp_path, lambda: g)
    assert node.start()[0]
    text = open(os.path.join(node.workdir, mesh_node.IDENTITY_FILE), encoding="utf-8").read()
    assert "hskey-secret-value" not in text
    plain = hashlib.sha256("hskey-secret-value".encode()).hexdigest()
    assert plain[:16] not in text
    assert mt.secret_digest("a") == mt.secret_digest("a") != mt.secret_digest("b")
    assert node.recorded()["salt"] == mt.salt_id()


# ── review round 3 (#862): the identity salt, a damaged token file, the cache ────
def _new_process():
    """What a tray restart does to the salt: this process's cached one is gone."""
    mt._SALTS.clear()


@pytest.mark.real_stack_probes
def test_an_unwritable_state_dir_keeps_one_salt_for_the_whole_process(compose, tmp_path,
                                                                      monkeypatch):
    """With no salt file possible, every digest used to draw a NEW salt, so the node's
    identity changed on every call and each start wiped it (compose down -v) and
    re-registered with an already-spent single-use key."""
    blocker = tmp_path / "not-a-dir"
    blocker.write_text("")
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(blocker / "state"))
    _new_process()
    g = _grant()
    assert g.identity() == g.identity()
    assert mt.secret_digest("x") == mt.secret_digest("x") != mt.secret_digest("y")
    assert not os.path.exists(os.path.join(str(blocker), "state"))
    node = _node(tmp_path, lambda: g)
    assert node.start()[0]
    assert len(_downs(compose)) == 1                  # first token run: no record yet
    compose.clear()
    assert node.start()[0]
    assert not _downs(compose)                        # same grant: state kept
    assert node.tray_note(True) == (f" — {g.short()}", "")
    compose.clear()
    assert node.apply_limits()[0] and not _downs(compose)
    # A tray restart draws another salt (still nowhere to keep it): the record it
    # finds cannot be compared by digest, and the same token is not a change.
    _new_process()
    compose.clear()
    assert node.start()[0]
    assert not _downs(compose)
    assert node.recorded()["salt"] == mt.salt_id()    # re-recorded under this salt


@pytest.mark.real_stack_probes
@pytest.mark.parametrize("token", [True, False])
def test_a_lost_salt_never_strands_a_node_whose_credentials_did_not_change(
        compose, tmp_path, monkeypatch, token):
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    g = _grant() if token else None
    node = _node(tmp_path, lambda: g)
    assert node.start()[0]
    os.remove(os.path.join(mt.state_dir(), mt.SALT_FILE))
    _new_process()
    old = node.recorded()["salt"]
    assert old != mt.salt_id()                        # a new salt file, a new salt
    compose.clear()
    assert node.start()[0]
    assert not _downs(compose)                        # unknown is kept, never wiped
    # A token is re-recorded (its public part matched); a TS_AUTHKEY that cannot be
    # compared keeps its old record, so it never turns into "same".
    assert node.recorded()["salt"] == (mt.salt_id() if token else old)
    assert mt.salt_id() != old
    # Not restarted-behind-the-back material either: limits apply, no nag.
    os.remove(os.path.join(mt.state_dir(), mt.SALT_FILE))
    _new_process()
    compose.clear()
    assert node.apply_limits()[0] and not _downs(compose)
    assert "restart to apply" not in node.tray_note(True)[0]


@pytest.mark.real_stack_probes
def test_a_lost_salt_still_sees_a_different_token_as_a_change(compose, tmp_path):
    """The record's public part (no secret, no salt) still tells two tokens apart."""
    holder = {"g": _grant(id="aaaa")}
    node = _node(tmp_path, lambda: holder["g"])
    assert node.start()[0]
    os.remove(os.path.join(mt.state_dir(), mt.SALT_FILE))
    _new_process()
    holder["g"] = _grant(id="bbbb", role="user", auth_key="another-key")
    compose.clear()
    assert node.start()[0]
    assert len(_downs(compose)) == 1
    assert "hskey" not in json.dumps(node.recorded()) and "another-key" not in \
        json.dumps(node.recorded())


@pytest.mark.real_stack_probes
@pytest.mark.parametrize("legacy, downs", [
    ("same digest", 0),                 # the salt file it was made under is still there
    ("same expiry and issuer", 0),      # cannot tell: kept, never wiped
    ("other expiry", 1),                # another token: register afresh
    ("other issuer", 1),
    ("was TS_AUTHKEY", 1),
])
def test_a_record_from_before_the_salt_was_named_still_tells_a_change(
        compose, tmp_path, legacy, downs):
    """A record written before the salt and public part were kept: {identity, summary,
    token, expires, issuer}. It is compared by its digest under the current salt, then
    by the expiry and issuer it carries; only when neither decides is it unknown."""
    g = _grant()
    node = _node(tmp_path, lambda: g)
    rec = {"identity": "token:0123", "summary": "x", "token": True, "expires": g.expires,
           "issuer": mt._issuer_key(g.issuer)}
    if legacy == "same digest":
        rec["identity"] = g.identity()
    elif legacy == "other expiry":
        rec["expires"] = g.expires - 60
    elif legacy == "other issuer":
        rec["issuer"] = "ssh-ed25519 BBBB"
    elif legacy == "was TS_AUTHKEY":
        rec = {"identity": "ts_authkey:0123", "summary": "TS_AUTHKEY", "token": False}
    os.makedirs(node.workdir, exist_ok=True)
    with open(os.path.join(node.workdir, mesh_node.IDENTITY_FILE), "w",
              encoding="utf-8") as fh:
        json.dump(rec, fh)
    assert node.start()[0]
    assert len(_downs(compose)) == downs
    assert node.recorded()["salt"] == mt.salt_id()


@pytest.mark.real_stack_probes
def test_a_failed_restart_keeps_the_record_so_the_next_start_keeps_the_state(
        compose, tmp_path, monkeypatch):
    """MeshNode.start drops the record before `up`. A failed `up` (a pull timeout)
    used to leave no record, so the next Start wiped the unchanged node (down -v) and
    re-registered it with its already-spent single-use key."""
    g = _grant()
    node = _node(tmp_path, lambda: g)
    assert node.start()[0]
    rec = node.recorded()
    fake = mesh_node.subprocess.run
    fail = {"up": True}

    def up_fails(argv, **kw):
        if argv[-2:] == ["up", "-d"] and fail["up"]:
            fake(argv, **kw)
            return subprocess.CompletedProcess(argv, 1, "", "pull timed out")
        return fake(argv, **kw)

    monkeypatch.setattr(mesh_node.subprocess, "run", up_fails)
    compose.clear()
    ok, out = node.start()                            # e.g. apply_limits' restart
    assert not ok and "pull timed out" in out
    assert node.recorded() == rec
    fail["up"] = False
    compose.clear()
    assert node.start()[0]
    assert not _downs(compose)
    # A first token run whose `up` fails after its reset: the state is empty or the
    # grant's, so it is recorded as the grant's and the next Start keeps it.
    other = mt.GrantedMeshNode(str(GENERATOR), str(tmp_path / "other"), load=lambda: g)
    fail["up"] = True
    compose.clear()
    assert not other.start()[0] and len(_downs(compose)) == 1
    fail["up"] = False
    compose.clear()
    assert other.start()[0] and not _downs(compose)


@pytest.mark.real_stack_probes
def test_a_ts_authkey_that_cannot_be_compared_is_never_recorded_as_the_current_one(
        compose, tmp_path, monkeypatch):
    """After a lost salt, a changed TS_AUTHKEY cannot be told from the old one. Its
    digest used to be recorded as what the node runs under, so every later comparison
    said "same" although the node kept the old registration."""
    monkeypatch.setenv("TS_AUTHKEY", "key-for-tailnet-a")
    node = _node(tmp_path, lambda: None)
    assert node.start()[0]
    rec = node.recorded()
    os.remove(os.path.join(mt.state_dir(), mt.SALT_FILE))
    _new_process()
    monkeypatch.setenv("TS_AUTHKEY", "key-for-tailnet-b")
    compose.clear()
    assert node.start()[0] and not _downs(compose)    # cannot tell: state kept
    assert node.recorded() == rec                     # and not recorded as key b's
    assert node._compare(node.recorded(), None) is None


def test_racing_creators_of_the_salt_file_all_take_the_winners_salt(tmp_path, monkeypatch):
    path = str(tmp_path / "state" / mt.SALT_FILE)
    # Deterministic: the file appears between this process's look and its create.
    os.makedirs(os.path.dirname(path))
    winner = bytes(range(32))
    with open(path, "w", encoding="ascii") as fh:
        fh.write(winner.hex() + "\n")
    real = mt._read_salt
    looks = []

    def first_look_misses(p):
        looks.append(p)
        return b"" if len(looks) == 1 else real(p)

    monkeypatch.setattr(mt, "_read_salt", first_look_misses)
    assert mt._load_or_create_salt(path) == winner
    monkeypatch.setattr(mt, "_read_salt", real)
    # Real threads racing on a fresh file: one salt for all, and it is the file's.
    path2 = str(tmp_path / "race" / mt.SALT_FILE)
    gate = threading.Barrier(8)
    got = []

    def racer():
        gate.wait()
        got.append(mt._load_or_create_salt(path2))

    threads = [threading.Thread(target=racer) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(got) == 8 and len(set(got)) == 1
    assert got[0] == mt._read_salt(path2)
    # A damaged file (not a race) is left alone: the salt goes in the file beside it,
    # and that is what every later process takes.
    with open(path2, "w", encoding="ascii") as fh:
        fh.write("not hex\n")
    salt = mt._load_or_create_salt(path2, retries=1)
    assert len(salt) == 32 and salt == mt._read_salt(path2 + mt.SALT_REPAIRED)
    assert mt._load_or_create_salt(path2, retries=1) == salt


def test_racers_that_find_a_damaged_salt_file_still_take_one_salt(tmp_path):
    """A creator that died between its create and its write left an empty file. Two
    processes that both gave up waiting on it used to each replace it, and could each
    keep their own salt."""
    path = str(tmp_path / "state" / mt.SALT_FILE)
    os.makedirs(os.path.dirname(path))
    open(path, "w").close()
    gate = threading.Barrier(6)
    got = []

    def racer():
        gate.wait()
        got.append(mt._load_or_create_salt(path, retries=2))

    threads = [threading.Thread(target=racer) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(got) == 6 and len(set(got)) == 1
    assert got[0] == mt._read_salt(path + mt.SALT_REPAIRED)
    assert sorted(os.listdir(os.path.dirname(path))) == [
        mt.SALT_FILE, mt.SALT_FILE + mt.SALT_REPAIRED]  # no temporary file left behind


def test_a_token_file_that_is_not_text_is_unusable_not_absent(compose, tmp_path,
                                                              monkeypatch):
    """A non-UTF-8 token file used to raise out of summary(), so the token dialog
    (where Forget is) never opened."""
    path = os.path.join(mt.state_dir(), mt.TOKEN_FILE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"hugmesh-token-v1.\xff\xfe\x80broken\n")
    assert mt.token_stored()
    text = mt.summary()
    assert text.startswith("The imported token cannot be used:") and "damaged" in text
    with pytest.raises(mt.TokenError) as e:
        mt.load_grant()
    assert e.value.kind == "malformed"
    # It is not "no token": the tray refuses rather than fall back to TS_AUTHKEY.
    monkeypatch.setenv("TS_AUTHKEY", "operator-key")
    node = mt.GrantedMeshNode(str(GENERATOR), str(tmp_path / "node"))
    ok, why = node.start()
    assert not ok and "damaged" in why
    assert not [a for a, _ in compose if a[-2:] == ["up", "-d"]]
    mt.forget_token()
    assert not mt.token_stored() and mt.summary().startswith("No HugMesh token imported")


@needs_keygen
def test_the_signature_cache_is_keyed_on_the_payload_and_the_signature(issuer, tmp_path):
    """A valid token verified first must not let the same payload through with another
    (corrupted) signature: the cache remembers (payload, signature), not the payload."""
    mt.trust_issuer(open(issuer + ".pub").read())
    token = _issue(issuer)
    g = mt.verify(token)                              # the good pair is cached now
    head, body, sig = token.split(".")
    armored = mt._unb64u(sig).decode("ascii").splitlines()
    i = len(armored) - 2                              # the last base64 line of the blob
    line = armored[i]
    k = len(line) // 2
    armored[i] = line[:k] + ("A" if line[k] != "A" else "B") + line[k + 1:]
    corrupted = ("\n".join(armored) + "\n").encode("ascii")
    bad = f"{head}.{body}.{mt._b64u(corrupted)}"
    assert mt.parse(bad)[1] == mt.parse(token)[1]     # the very same payload bytes
    with pytest.raises(mt.TokenError) as e:
        mt.verify(bad)
    assert e.value.kind == "signature"
    missing = str(tmp_path / "no-such-ssh-keygen")
    assert mt.verify(token, keygen=missing) == g      # the good one is still cached
    with pytest.raises((mt.TokenError, OSError)):
        mt.verify(bad, keygen=missing)                # never cached as good
