"""Issuing HugMesh tokens for a mesh created locally with the Studio (core/mesh_token.py).

Operator ask (2026-11-04): "make sure locally created mesh can also generate tokens
through both the web ui and the gui/tui/cli on all platforms". This file covers the
Studio's half: the per-mesh Studio issuer key, non-interactive signing (what the GUI
and the TUI call), minting a pre-auth key in the mesh's running headscale container,
the CLI's ``issue --mint`` / ``issuer``, and ``hugmesh-studio --mesh-token``.

Signing and verifying use the real ``ssh-keygen`` (skipped when absent, like
test_mesh_token.py). Docker is never run: every docker call goes to a fake runner.
"""
import os
import subprocess
import sys
import textwrap

import pytest

from hugmesh_studio.core import mesh_token as mt

STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

try:
    KEYGEN = mt.ssh_keygen()
except mt.TokenError:
    KEYGEN = None
needs_keygen = pytest.mark.skipif(KEYGEN is None, reason="no OpenSSH ssh-keygen")

GRANT = dict(mesh="west", domain="example.org", role="admin", shell=True,
             login_server="https://hs.example.org", lifetime_s=3600)
MINTED = "hskey-auth-0123456789abcdef0123456789abcdef"


class FakeDocker:
    """Records docker argv; answers `docker ps` with ``names`` and `headscale
    preauthkeys create` with ``out``. Anything that is not docker runs for real
    (ssh-keygen), so the CLI path is exercised end to end."""

    def __init__(self, names=("hugmesh-headscale",), out=f"\n{MINTED}\n", rc=0, err=""):
        self.names, self.out, self.rc, self.err = names, out, rc, err
        self.calls: list[tuple[list[str], dict]] = []
        self._real = subprocess.run

    def __call__(self, argv, **kw):
        if argv[0] != "docker":
            return self._real(argv, **kw)
        self.calls.append((list(argv), kw))
        if argv[1] == "ps":
            return subprocess.CompletedProcess(argv, 0, "".join(f"{n}\n" for n in self.names), "")
        return subprocess.CompletedProcess(argv, self.rc, self.out, self.err)


# ── the Studio issuer key ─────────────────────────────────────────────────────────
def test_issuer_dir_is_per_mesh_under_the_state_dir_and_refuses_bad_names():
    assert mt.issuer_dir("west") == os.path.join(mt.state_dir(), "mesh-issuers", "west")
    for bad in ("", "West", "../x", "-x", "a" * 64):
        with pytest.raises(mt.TokenError) as e:
            mt.issuer_dir(bad)
        assert e.value.kind == "invalid"


@needs_keygen
def test_ensure_issuer_creates_and_trusts_once_then_reuses():
    key, line, fp = mt.ensure_issuer("west")
    assert key == os.path.join(mt.issuer_dir("west"), mt.ISSUER_KEY)
    assert os.path.isfile(key) and os.path.isfile(key + ".pub")
    assert line.startswith("ssh-ed25519 ") and line.endswith("hugmesh-issuer west")
    assert fp == mt.fingerprint(line)
    out = subprocess.run([KEYGEN, "-lf", key + ".pub"], capture_output=True, text=True)
    assert fp in out.stdout
    assert mt._issuer_key(line) in mt.trusted_issuers()
    if os.name != "nt":
        assert os.stat(key).st_mode & 0o777 == 0o600
    # Reused, not regenerated — and an operator's distrust is left alone.
    mt.distrust_issuer(line)
    again = mt.ensure_issuer("west")
    assert again == (key, line, fp)
    assert mt._issuer_key(line) not in mt.trusted_issuers()
    # Another mesh gets its own key.
    assert mt.ensure_issuer("east")[2] != fp


@pytest.mark.skipif(os.name == "nt", reason="POSIX modes; Windows uses the state dir's ACL")
def test_every_issuer_folder_it_creates_is_private():
    """os.makedirs's mode reaches only the LAST directory: mesh-issuers/ itself must be
    0700 too, not 0755 under the usual umask."""
    old = os.umask(0o022)
    try:
        mt._makedirs_private(mt.issuer_dir("west"))
    finally:
        os.umask(old)
    root = os.path.join(mt.state_dir(), mt.ISSUERS_DIR)
    for d in (mt.state_dir(), root, mt.issuer_dir("west")):
        assert os.stat(d).st_mode & 0o777 == 0o700, d
    # A folder that already existed keeps its mode.
    os.chmod(root, 0o750)
    mt._makedirs_private(mt.issuer_dir("east"))
    assert os.stat(root).st_mode & 0o777 == 0o750
    assert os.stat(mt.issuer_dir("east")).st_mode & 0o777 == 0o700


@needs_keygen
@pytest.mark.skipif(os.name == "nt", reason="POSIX modes; Windows uses the state dir's ACL")
def test_ensure_issuer_leaves_both_issuer_folders_private():
    old = os.umask(0o022)
    try:
        mt.ensure_issuer("west")
    finally:
        os.umask(old)
    for d in (os.path.join(mt.state_dir(), mt.ISSUERS_DIR), mt.issuer_dir("west")):
        assert os.stat(d).st_mode & 0o777 == 0o700, d


@needs_keygen
@pytest.mark.skipif(os.name == "nt", reason="POSIX modes; Windows uses the state dir's ACL")
def test_ensure_issuer_makes_folders_an_earlier_build_left_open_private():
    """An earlier build created mesh-issuers/ 0755 (it lists the mesh names); the key
    already exists there, so nothing is created, yet both folders end up 0700."""
    mt.ensure_issuer("west")
    root = os.path.join(mt.state_dir(), mt.ISSUERS_DIR)
    for d in (root, mt.issuer_dir("west")):
        os.chmod(d, 0o755)
    mt.ensure_issuer("west")
    for d in (root, mt.issuer_dir("west")):
        assert os.stat(d).st_mode & 0o777 == 0o700, d


@needs_keygen
def test_a_failed_first_self_check_leaves_no_key_and_no_trust(monkeypatch):
    """Creation is all or nothing: a key whose first self-check fails is not left on
    disk to be reused later unchecked and untrusted; the next call starts afresh and
    ends with a checked key that this computer trusts."""
    real = mt._self_check
    calls = []

    def flaky(key, keygen, osname, **kw):
        calls.append(key)
        if len(calls) == 1:
            raise mt.TokenError("tool", "The new issuer key cannot sign: timed out")
        return real(key, keygen, osname, **kw)

    monkeypatch.setattr(mt, "_self_check", flaky)
    with pytest.raises(mt.TokenError):
        mt.ensure_issuer("west")
    key = mt.issuer_key_path("west")
    assert not os.path.exists(key) and not os.path.exists(key + ".pub")
    assert mt.trusted_issuers() == set()
    assert os.listdir(mt.issuer_dir("west")) == []      # no scratch dir left either
    _, line, _ = mt.ensure_issuer("west")
    assert len(calls) == 2 and calls[1] != key           # checked before it was in place
    assert mt._issuer_key(line) in mt.trusted_issuers()
    assert mt.ensure_issuer("west")[1] == line and len(calls) == 2


@needs_keygen
def test_a_failed_move_into_place_drops_the_trust_it_gave(monkeypatch):
    real = os.replace

    def replace(src, dst):
        if dst == mt.issuer_key_path("west"):
            raise OSError("disk full")
        return real(src, dst)

    monkeypatch.setattr(mt.os, "replace", replace)
    with pytest.raises(OSError):
        mt.ensure_issuer("west")
    key = mt.issuer_key_path("west")
    assert not os.path.exists(key) and not os.path.exists(key + ".pub")
    assert mt.trusted_issuers() == set()


def test_ssh_keygen_missing_says_signing_or_checking(monkeypatch):
    monkeypatch.setattr(mt.shutil, "which", lambda name: None)
    with pytest.raises(mt.TokenError) as e:
        mt.ssh_keygen("posix")
    assert e.value.kind == "tool"
    assert str(e.value).startswith("Signing or checking a HugMesh token needs OpenSSH's "
                                   "ssh-keygen")


def test_write_private_never_opens_a_file_someone_put_at_a_guessable_name(tmp_path):
    """The TUI's `w PATH` writes the token (it carries the pre-auth key) wherever the
    user says, perhaps /tmp: a file or a symlink planted at the old predictable
    temporary name is neither written through nor reused."""
    target = tmp_path / "token.txt"
    planted = tmp_path / f"token.txt.{os.getpid()}.tmp"
    aim = tmp_path / "theirs"
    aim.write_text("someone else's\n")
    if os.name == "nt":
        planted.write_text("someone else's\n")
    else:
        os.chmod(aim, 0o666)
        os.symlink(aim, planted)
    mt._write_private(str(target), "hugmesh-token-v1.secret\n")
    assert target.read_text() == "hugmesh-token-v1.secret\n"
    assert planted.read_text() == aim.read_text() == "someone else's\n"
    if os.name != "nt":
        assert planted.is_symlink()
        assert target.stat().st_mode & 0o777 == 0o600
    assert sorted(p.name for p in tmp_path.iterdir()) == sorted(
        ["token.txt", planted.name, "theirs"])        # no temporary file left over


@needs_keygen
def test_a_lost_public_half_is_recreated_from_the_private_key():
    key, line, fp = mt.ensure_issuer("west")
    os.remove(key + ".pub")
    assert mt.ensure_issuer("west")[2] == fp


@needs_keygen
def test_a_token_issued_non_interactively_with_the_studio_issuer_verifies(monkeypatch):
    key, _, fp = mt.ensure_issuer("west")
    seen = []
    real = subprocess.run

    def spy(argv, **kw):
        seen.append((list(argv), kw))
        return real(argv, **kw)

    monkeypatch.setattr(mt.subprocess, "run", spy)
    token = mt.issue(key_path=key, auth_key=MINTED, interactive=False, **GRANT)
    sign = [kw for argv, kw in seen if "-Y" in argv and "sign" in argv]
    assert sign and sign[0].get("capture_output") and sign[0].get("stdin") == subprocess.DEVNULL
    if os.name == "nt":
        assert sign[0].get("creationflags")
    g = mt.verify(token)                  # trusted on creation: the admin's own tray
    assert (g.mesh, g.role, g.shell, g.auth_key) == ("west", "admin", True, MINTED)
    assert mt.fingerprint(g.issuer) == fp


@needs_keygen
def test_a_non_interactive_signing_failure_carries_ssh_keygens_words(tmp_path):
    key, line, _ = mt.ensure_issuer("west")
    broken = tmp_path / "broken"
    broken.write_text("this is not a private key\n")
    (tmp_path / "broken.pub").write_text(line + "\n")
    with pytest.raises(mt.TokenError) as e:
        mt.issue(key_path=str(broken), auth_key=MINTED, interactive=False, **GRANT)
    assert e.value.kind == "signature"
    assert "see its message above" not in str(e.value)
    assert str(e.value).startswith("ssh-keygen could not sign the token: ")


def test_a_windows_key_with_a_too_open_acl_is_narrowed_and_rechecked(monkeypatch):
    signs, icacls = [], []

    def sign(key, body, **kw):
        signs.append(kw["namespace"])
        if len(signs) == 1:
            raise mt.TokenError("signature", "ssh-keygen could not sign the token: "
                                             "Permissions for 'k' are too open.")
        return b"sig"

    def runner(argv, **kw):
        icacls.append(argv)
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(mt, "_sign", sign)
    monkeypatch.setattr(mt.getpass, "getuser", lambda: "magus")
    mt._self_check("k", "ssh-keygen", "nt", runner=runner)
    assert icacls == [["icacls", "k", "/inheritance:r", "/grant:r", "magus:F"]]
    assert signs == [mt._SELF_CHECK_NAMESPACE] * 2 and mt.NAMESPACE not in signs


def test_a_key_that_cannot_sign_for_another_reason_is_not_touched(monkeypatch):
    def sign(key, body, **kw):
        raise mt.TokenError("signature", "ssh-keygen could not sign the token: invalid format")

    called = []
    monkeypatch.setattr(mt, "_sign", sign)
    with pytest.raises(mt.TokenError) as e:
        mt._self_check("k", "ssh-keygen", "nt", runner=lambda *a, **k: called.append(a))
    assert e.value.kind == "tool" and "invalid format" in str(e.value) and not called
    # POSIX never runs icacls, even for a permissions complaint.
    monkeypatch.setattr(mt, "_sign", lambda *a, **k: (_ for _ in ()).throw(
        mt.TokenError("signature", "UNPROTECTED PRIVATE KEY FILE!")))
    with pytest.raises(mt.TokenError):
        mt._self_check("k", "ssh-keygen", "posix", runner=lambda *a, **k: called.append(a))
    assert not called


# ── minting a pre-auth key ─────────────────────────────────────────────────────────
def test_mint_runs_headscale_in_the_one_running_container_and_returns_the_key():
    fake = FakeDocker(out=f"2026-11-04T10:00:00Z WRN something\n\n{MINTED}\n\n")
    assert mt.mint_preauth_key(user="admin", lifetime_s=3600, runner=fake) == MINTED
    (ps, ps_kw), (create, kw) = fake.calls
    assert ps == ["docker", "ps", "--filter", "name=headscale", "--format", "{{.Names}}"]
    assert create == ["docker", "exec", "hugmesh-headscale", "headscale", "preauthkeys",
                      "create", "--user", "admin", "--expiration", "3600s"]
    assert "--reusable" not in create
    assert kw["capture_output"] and kw["stdin"] == subprocess.DEVNULL
    if os.name == "nt":
        assert kw.get("creationflags")


def test_mint_requests_no_tags_by_default_and_exactly_the_tags_asked_for():
    assert mt.DEFAULT_MINT_TAGS == ()
    fake = FakeDocker()
    mt.mint_preauth_key(user="joiners", tags=["tag:hugmesh", "tag:pki"], lifetime_s=60,
                        container="hs", runner=fake)
    (create, _), = fake.calls           # a named container is not looked up
    assert create[2] == "hs" and create[-2:] == ["--tags", "tag:hugmesh,tag:pki"]


@pytest.mark.parametrize("tag", ["tag:superadmin", "tag:mesh_east-01", "tag:dev_084628ddb3aa",
                                 "tag:dom_example-org"])
def test_mint_refuses_a_tag_that_grants_access_and_mints_nothing(tag):
    # headscale 0.23 forces a pre-auth key's tags on the node that joins with it, and
    # forced tags bypass tagOwners: a key carrying one of these would hand its holder
    # the access the control node alone is meant to assign.
    fake = FakeDocker()
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="hugmesh", tags=["tag:hugmesh", tag], lifetime_s=60,
                            container="hs", runner=fake)
    assert e.value.kind == "invalid" and tag in str(e.value)
    assert fake.calls == []             # nothing minted


@pytest.mark.parametrize("tag", ["tag:superadmins", "tag:meshy", "tag:devices", "tag:domain"])
def test_mint_security_tag_match_is_exact_not_a_loose_prefix(tag):
    fake = FakeDocker()
    mt.mint_preauth_key(user="hugmesh", tags=[tag], lifetime_s=60, container="hs", runner=fake)
    (create, _), = fake.calls
    assert create[-2:] == ["--tags", tag]


@pytest.mark.parametrize("tag", ["tag:a,tag:b", "tag:a,b", "tag:a\n", "tag:a tag:b",
                                 ",tag:a"])
def test_a_tag_cannot_smuggle_another_into_the_comma_joined_list(tag):
    """--tags takes ONE comma-joined argument, so a comma inside a single --tag would
    ask for a second tag nobody named."""
    assert not mt._TAG_RE.match(tag)
    fake = FakeDocker()
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="joiners", tags=[tag], lifetime_s=60, container="hs",
                            runner=fake)
    assert e.value.kind == "invalid" and not fake.calls


def test_minting_needs_a_named_headscale_user(capsys):
    """There is no default headscale user: the core, mint_and_issue and the CLI all
    refuse before anything runs."""
    assert not hasattr(mt, "DEFAULT_MINT_USER")
    fake = FakeDocker()
    for user in ("", None):
        with pytest.raises(mt.TokenError) as e:
            mt.mint_preauth_key(user=user, lifetime_s=60, container="hs", runner=fake)
        assert e.value.kind == "invalid" and mt.NAME_MINT_USER in str(e.value)
    with pytest.raises(mt.TokenError) as e:
        mt.mint_and_issue(key_path="k", user="", container="hs", runner=fake,
                          node_name="", **GRANT)
    assert mt.NAME_MINT_USER in str(e.value)
    with pytest.raises(TypeError):
        mt.mint_and_issue(key_path="k", container="hs", runner=fake, node_name="", **GRANT)
    assert not fake.calls
    with pytest.raises(SystemExit):
        mt.main(CLI + ["--mint"])
    assert mt.NAME_MINT_USER in capsys.readouterr().err
    assert not os.path.exists(mt.issuer_dir("west"))


@pytest.mark.parametrize("found", ["--privileged", "-hs", "hs x"])
def test_a_container_name_docker_ps_found_is_checked_like_a_given_one(found):
    """find_headscale_container's answer gets the same name check as a container the
    operator named: nothing is exec'd in a "container" that reads as an option."""
    fake = FakeDocker(names=(found,))
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="joiners", lifetime_s=60, runner=fake)
    assert e.value.kind == "invalid" and "not a container name" in str(e.value)
    assert [a[1] for a, _ in fake.calls] == ["ps"]          # nothing exec'd


@pytest.mark.parametrize("names, needle", [((), "No running headscale container"),
                                           (("hs-a", "hs-b"), "hs-a, hs-b"),
                                           (("a-headscale", "b-headscale"),
                                            "a-headscale, b-headscale")])
def test_mint_needs_exactly_one_headscale_container(names, needle):
    fake = FakeDocker(names=names)
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="admin", lifetime_s=60, runner=fake)
    assert e.value.kind == "tool" and needle in str(e.value)
    assert e.value.choices == tuple(sorted(names))    # what the dialog offers to pick
    assert len(fake.calls) == 1          # nothing minted


@pytest.mark.parametrize("names, want", [
    (("headscale", "headscale-ui"), "headscale"),
    (("headscale-admin", "hugmesh-headscale"), "hugmesh-headscale"),
    (("hugmesh-headscale-1", "hugmesh-headscale-ui-1"), "hugmesh-headscale-1"),
    (("mesh_headscale_1", "headscale-webui"), "mesh_headscale_1")])
def test_headscale_itself_wins_over_the_containers_beside_it(names, want):
    """docker's name filter matches substrings: a headscale-ui next to headscale must
    not make the common setup ambiguous."""
    assert mt.find_headscale_container(runner=FakeDocker(names=names)) == want


def test_mint_says_when_docker_is_missing():
    def runner(argv, **kw):
        raise FileNotFoundError(argv[0])
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="admin", lifetime_s=60, runner=runner)
    assert e.value.kind == "tool" and "docker, which was not found" in str(e.value)


def test_mint_quotes_headscales_complaint():
    fake = FakeDocker(rc=1, err="line one\nError: user not found\n")
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="mod", lifetime_s=60, container="hs", runner=fake)
    assert e.value.kind == "tool"
    assert "user not found" in str(e.value) and "hs" in str(e.value) and "mod" in str(e.value)


def test_mint_never_echoes_output_it_cannot_read_as_a_key():
    fake = FakeDocker(out="Key created: secret-looking value here\n")
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(user="admin", lifetime_s=60, container="hs", runner=fake)
    assert "secret-looking" not in str(e.value)


@pytest.mark.parametrize("over", [dict(user="-x"), dict(user="a b"), dict(tags=["tag:A"]),
                                  dict(tags=["hugmesh"]), dict(container="--privileged"),
                                  dict(lifetime_s=0), dict(lifetime_s=mt.MAX_LIFETIME_S + 1)])
def test_mint_refuses_arguments_before_running_anything(over):
    fake = FakeDocker()
    with pytest.raises(mt.TokenError) as e:
        mt.mint_preauth_key(**{"user": "admin", "lifetime_s": 60, "runner": fake, **over})
    assert e.value.kind == "invalid" and not fake.calls


# ── CLI ───────────────────────────────────────────────────────────────────────────
CLI = ["issue", "--mesh", "west", "--domain", "example.org", "--role", "admin", "--shell",
       "--login-server", "https://hs.example.org", "--expires", "1h"]


@needs_keygen
def test_cli_issue_mint_signs_with_the_studio_issuer(monkeypatch, capsys):
    fake = FakeDocker()
    monkeypatch.setattr(mt.subprocess, "run", fake)
    assert mt.main(CLI + ["--mint", "--headscale-user", "joiners"]) == 0
    out, err = capsys.readouterr()
    token = out.strip()
    g = mt.verify(token)
    assert g.auth_key == MINTED and (g.role, g.shell) == ("admin", True)
    create = fake.calls[-1][0]
    assert create[create.index("--user") + 1] == "joiners"   # the user named; no default
    assert create[create.index("--expiration") + 1] == "3600s"     # the token's lifetime
    _, _, fp = mt.ensure_issuer("west")
    assert fp in err and "created now; this computer trusts it" in err
    assert "hugmesh-headscale" in err and "no tags of its own" in err
    assert mt.SERVER_DECIDES in err and "tags for" not in err
    assert MINTED not in err
    # Second run: the same issuer, not created again.
    assert mt.main(CLI + ["--mint", "--headscale-user", "ops",
                          "--headscale-container", "hs"]) == 0
    err = capsys.readouterr().err
    assert "created now" not in err and fp in err
    assert fake.calls[-1][0][2] == "hs" and "ops" in fake.calls[-1][0]
    assert "for the headscale user ops" in err


def test_mint_and_issue_checks_the_key_signs_before_minting(monkeypatch):
    """A key that cannot sign fails BEFORE anything exists on the server."""
    signed = []

    def sign(key, body, **kw):
        signed.append(kw["namespace"])
        raise mt.TokenError("signature", "ssh-keygen could not sign the token: "
                                         "incorrect passphrase supplied")

    monkeypatch.setattr(mt, "_read_pub", lambda key: "ssh-ed25519 AAAA")
    monkeypatch.setattr(mt, "_sign", sign)
    fake = FakeDocker()
    with pytest.raises(mt.TokenError) as e:
        mt.mint_and_issue(key_path="k", user="joiners", container="hs", runner=fake,
                          keygen="ssh-keygen", node_name="", **GRANT)
    assert "incorrect passphrase" in str(e.value)
    assert signed == [mt._SELF_CHECK_NAMESPACE] and not fake.calls      # nothing minted


@pytest.mark.parametrize("expired", [True, False])
def test_a_key_minted_for_a_token_that_fails_to_sign_is_expired(monkeypatch, expired):
    monkeypatch.setattr(mt, "check_signing", lambda *a, **k: None)

    def issue(**kw):
        raise mt.TokenError("signature", "ssh-keygen could not sign the token: timed out")

    monkeypatch.setattr(mt, "issue", issue)
    fake = FakeDocker()
    real_call = fake.__call__

    def runner(argv, **kw):
        r = real_call(argv, **kw)
        if "expire" in " ".join(argv) and not expired:
            return subprocess.CompletedProcess(argv, 1, "", "sh: not found")
        return r

    with pytest.raises(mt.TokenError) as e:
        mt.mint_and_issue(key_path="k", user="joiners", container="hs", runner=runner,
                          node_name="", **GRANT)
    (create, _), (expire, kw) = fake.calls
    assert create[:6] == ["docker", "exec", "hs", "headscale", "preauthkeys", "create"]
    assert expire[:4] == ["docker", "exec", "-i", "hs"] and expire[-1] == "joiners"
    assert MINTED not in " ".join(expire) and kw["input"] == MINTED + "\n"
    msg = str(e.value)
    assert msg.startswith("ssh-keygen could not sign the token: timed out")
    assert MINTED not in msg
    if expired:
        assert "has been expired" in msg
    else:
        assert "could not be expired and stays usable" in msg and "--user joiners" in msg


def test_cli_checks_every_field_before_minting(monkeypatch, capsys):
    fake = FakeDocker()
    monkeypatch.setattr(mt.subprocess, "run", fake)
    bad = [a if a != "example.org" else "elsewhere.org" for a in CLI]
    assert mt.main(bad + ["--mint", "--headscale-user", "joiners"]) == 2
    assert "outside its access domain" in capsys.readouterr().err
    assert not fake.calls and not os.path.exists(mt.issuer_dir("west"))


@pytest.mark.parametrize("extra", [
    ["--headscale-user", "bad user"],
    ["--headscale-user", " "],
    ["--headscale-user", "joiners", "--headscale-container", "hs;rm"],
    ["--headscale-user", "joiners", "--tag", "Not A Tag"],
])
def test_cli_checks_the_mint_options_before_an_issuer_key_is_created(monkeypatch, capsys,
                                                                     extra):
    fake = FakeDocker()
    monkeypatch.setattr(mt.subprocess, "run", fake)
    with pytest.raises(SystemExit):
        mt.main(CLI + ["--mint"] + extra)
    assert "created now" not in capsys.readouterr().err
    assert not fake.calls and not os.path.exists(os.path.join(mt.state_dir(), mt.ISSUERS_DIR))


def test_cli_mint_options_need_mint_and_one_key_source(capsys):
    with pytest.raises(SystemExit):
        mt.main(CLI + ["--authkey-file", "k", "--headscale-user", "x"])
    with pytest.raises(SystemExit):
        mt.main(CLI + ["--authkey-file", "k", "--mint"])
    with pytest.raises(SystemExit):
        mt.main(CLI)
    with pytest.raises(SystemExit):
        mt.main(CLI + ["--mint"])                   # --headscale-user is required


@needs_keygen
def test_cli_authkey_file_with_an_own_key_still_works(tmp_path, capsys):
    key = tmp_path / "own"
    subprocess.run([KEYGEN, "-q", "-t", "ed25519", "-N", "", "-C", "own", "-f", str(key)],
                   check=True)
    authkey = tmp_path / "authkey"
    authkey.write_text(MINTED + "\n")
    assert mt.main(CLI + ["--key", str(key), "--authkey-file", str(authkey)]) == 0
    out, err = capsys.readouterr()
    g, _, _ = mt.parse(out.strip())
    assert g.auth_key == MINTED and mt.SERVER_DECIDES in err and "tags" not in err
    assert not os.path.exists(mt.issuer_dir("west"))     # no Studio key made


@needs_keygen
def test_cli_issuer_prints_the_public_key_and_fingerprint(capsys):
    assert mt.main(["issuer", "--mesh", "west"]) == 0
    out, err = capsys.readouterr()
    line, fp = out.strip().splitlines()
    assert line.startswith("ssh-ed25519 ") and fp == mt.fingerprint(line)
    assert "Created the Studio issuer key for mesh west" in err
    assert mt.main(["issuer", "--mesh", "west"]) == 0
    out2, err2 = capsys.readouterr()
    assert out2 == out and not err2


# ── hugmesh-studio --mesh-token ───────────────────────────────────────────────────
def test_app_forwards_everything_after_mesh_token(monkeypatch):
    from hugmesh_studio import app
    seen = []
    monkeypatch.setattr(mt, "main", lambda argv: seen.append(argv) or 7)
    rest = ["issue", "--mesh", "west", "--json", "--help"]
    assert app.main(["--mesh-token", *rest]) == 7
    assert seen == [rest]


def test_app_mesh_token_never_imports_qt(tmp_path):
    """In a fresh interpreter whose Qt imports would fail loudly, --mesh-token runs
    the token CLI (a missing token file: exit 2 with mesh_token's own sentence)."""
    script = textwrap.dedent("""
        import sys
        BLOCK = ("PyQt6", "PyQt5", "PySide6", "PySide2")
        class NoQt:
            def find_spec(self, name, path=None, target=None):
                if name.split(".")[0] in BLOCK:
                    raise ImportError("Qt imported on the --mesh-token path: " + name)
        sys.meta_path.insert(0, NoQt())
        from hugmesh_studio import app
        rc = app.main(["--mesh-token", "show", sys.argv[1]])
        assert not [m for m in sys.modules if m.split(".")[0] in BLOCK]
        sys.exit(rc)
    """)
    env = {**os.environ, "PYTHONPATH": STUDIO}
    r = subprocess.run([sys.executable, "-c", script, str(tmp_path / "missing")],
                       capture_output=True, text=True, cwd=STUDIO, env=env, timeout=120)
    assert r.returncode == 2, r.stderr
    assert "mesh-token:" in r.stderr and "Qt imported" not in r.stderr
