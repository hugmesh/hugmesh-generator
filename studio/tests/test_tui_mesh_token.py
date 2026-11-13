"""tui — issuing HugMesh tokens from the terminal (tui/mesh_token_step.py), the text twin
of the GUI's "Issue a HugMesh token…" dialog.

Operator ask (2026-11-04): "make sure locally created mesh can also generate tokens
through both the web ui and the gui/tui/cli on all platforms". Here: the screen is
reached from the Local Docker mesh screens with ``t``, offers the core's roles, shell
rule and longest lifetime (the same as the CLI's; the GUI dialog is compared in
test_tui_gui_parity.py), checks every field before an issuer key is made, signs with
the Studio's issuer key, never starts docker (minting is a printed CLI line, and that
line is one the CLI accepts), and never takes the pre-auth key on the screen.

Headless and Qt-free. Signing uses the real ssh-keygen (skipped when absent, like
test_mesh_token.py); docker is never run — a docker call fails the test.
"""
import os
import shlex
import subprocess
import sys
import textwrap

import pytest

from hugmesh_studio.core import mesh_token as mt
from hugmesh_studio.tui import journey, localmesh
from hugmesh_studio.tui import mesh_token_step as step

try:
    KEYGEN = mt.ssh_keygen()
except mt.TokenError:
    KEYGEN = None
needs_keygen = pytest.mark.skipif(KEYGEN is None, reason="no OpenSSH ssh-keygen")

KEY = "hskey-auth-0123456789abcdef0123456789abcdef"
STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(autouse=True)
def _no_docker(monkeypatch):
    """The TUI never starts docker: any docker argv fails the test; ssh-keygen runs."""
    real = subprocess.run

    def run(argv, *a, **kw):
        if os.path.basename(str(argv[0])).startswith("docker"):
            raise AssertionError(f"the TUI started docker: {argv}")
        return real(argv, *a, **kw)
    monkeypatch.setattr(mt.subprocess, "run", run)


def _text(j):
    return "\n".join(j.lines())


@pytest.fixture
def at_token(tmp_path):
    """The token screen, opened with ``t`` from the Local Docker mesh's first screen."""
    j = journey.Journey(str(tmp_path / "gen"))
    j.feed("")                     # welcome -> mode
    j.feed("1")                    # Local Docker mesh
    assert "t=share a mesh you created here" in _text(j)
    j.feed("t")
    assert isinstance(j.overlay, step.MeshTokenScreen)
    return j, j.overlay


def _fill(j, *, role="admin", shell=True):
    for line in ("m west", "d example.org", f"r {role}", "l https://hs.example.org",
                 "e 1h"):
        j.feed(line)
        assert not j.status, (line, j.status)
    if shell:
        j.feed("s")


@pytest.fixture
def keyfile(tmp_path):
    p = tmp_path / "authkey"
    p.write_text(KEY + "\n")
    return str(p)


# ── reaching it ───────────────────────────────────────────────────────────────────
def test_it_opens_prefilled_from_the_review_and_b_and_q_go_back(tmp_path):
    j = journey.Journey(str(tmp_path / "gen"))
    for line in ("", "1", "2", "", ""):        # -> localmesh -> generate -> review
        j.feed(line)
    lm = j.screen_for("localmesh")
    assert lm.stage == "review"
    assert "t=issue a HugMesh token for this mesh" in _text(j)
    j.feed("t")
    s = j.overlay
    assert isinstance(s, step.MeshTokenScreen) and j.title() == step.TITLE
    # the window's prefill: the brand as the mesh, the own domain as the access domain
    assert s.mesh == lm.boot(j).brand and s.domain == lm.state(j).own_name
    assert s.login_server == ""
    j.feed("q")                                # q is BACK here, never quit
    assert j.overlay is None and not j.done and lm.stage == "review"
    j.feed("t")
    j.feed("b")
    assert j.overlay is None and lm.stage == "review"


def test_an_invalid_brand_is_not_offered_as_the_mesh_name(tmp_path):
    j = journey.Journey(str(tmp_path / "gen"))
    j.feed("")
    j.feed("1")
    j.localmesh_boot = localmesh.LocalMeshBootstrapConfig(brand="Not A Mesh")
    j.feed("t")
    assert j.overlay.mesh == ""


# ── the same choices as the CLI (and, in test_tui_gui_parity, the dialog) ──────────
def _cli_role_choices(capsys):
    with pytest.raises(SystemExit):
        mt.main(["issue", "--help"])
    out = capsys.readouterr().out
    return tuple(out.split("--role {", 1)[1].split("}", 1)[0].split(","))


def test_roles_shell_rule_and_lifetime_match_the_cli(at_token, capsys, keyfile):
    j, s = at_token
    assert s.roles() == mt.ROLES == _cli_role_choices(capsys)
    for i, role in enumerate(mt.ROLES, 1):
        assert f"{i} {role}" in _text(j)
    # shell: offered exactly to SHELL_ROLES here, accepted exactly for them by the CLI
    for role in mt.ROLES:
        j.feed(f"r {role}")
        j.feed("s")
        assert s.shell is (role in mt.SHELL_ROLES)
        assert (j.status == step.SHELL_ONLY_TIP) is (role not in mt.SHELL_ROLES)
        if s.shell:
            j.feed("s")                      # back off for the next role
        rc = mt.main(["issue", "--mesh", "west", "--domain", "example.org", "--role", role,
                      "--shell", "--login-server", "https://hs.example.org",
                      "--authkey-file", keyfile, "--key", os.devnull + "-none"])
        err = capsys.readouterr().err
        assert ("only admin and superadmin can hold shell" in err) is (
            role not in mt.SHELL_ROLES)
        assert rc == 2              # the shell roles stop later, at the missing --key
    # the longest lifetime: the core's, on both faces
    days = mt.MAX_LIFETIME_S // 86400
    j.feed(f"e {days}d")
    assert not j.status and s.lifetime_s == mt.MAX_LIFETIME_S
    j.feed(f"e {days + 1}d")
    assert f"{days} days" in j.status and s.lifetime_s == mt.MAX_LIFETIME_S
    assert mt._lifetime(f"{days}d") == mt.MAX_LIFETIME_S
    rc = mt.main(["issue", "--mesh", "west", "--domain", "example.org", "--role", "user",
                  "--login-server", "https://hs.example.org", "--authkey-file", keyfile,
                  "--expires", f"{days + 1}d"])
    assert rc == 2 and f"{days} days" in capsys.readouterr().err
    assert not os.path.exists(mt.issuer_dir("west"))


def test_shell_is_dropped_when_the_role_changes_to_one_without_it(at_token):
    j, s = at_token
    _fill(j, role="superadmin")
    assert s.fields()["shell"] is True
    j.feed("r 1")
    assert s.role == mt.ROLES[0] and s.shell is False
    j.feed("r nobody")
    assert "no such role" in j.status and s.role == mt.ROLES[0]


# ── signing here ──────────────────────────────────────────────────────────────────
@needs_keygen
def test_issue_signs_with_the_studio_issuer_and_shows_token_and_fingerprint(
        at_token, keyfile, tmp_path):
    j, s = at_token
    _fill(j)
    j.feed(f"k {keyfile}")
    j.feed("i")
    assert not j.status, j.status
    g = mt.verify(s.token)                  # this computer trusts the new issuer key
    assert (g.mesh, g.domain, g.role, g.shell, g.auth_key) == \
        ("west", "example.org", "admin", True, KEY)
    assert g.expires - g.issued == 3600
    _, line, fp = mt.ensure_issuer("west")
    text = _text(j)
    assert s.token in text and f"Issuer fingerprint: {fp}" in text
    assert "created now; this computer trusts it" in text
    assert step.FINGERPRINT_NOTE in text and g.describe() in text
    assert mt.SERVER_DECIDES in text and "tags" not in text
    # the key file's content is never shown on its own line, and is not kept
    assert KEY not in text.replace(s.token, "")
    assert KEY not in repr(vars(s))
    # a second token: the same issuer, not created again
    j.feed("i")
    assert "created now" not in _text(j) and fp in _text(j)
    # w PATH saves the token; leaving drops it from the screen
    out = tmp_path / "token.txt"
    j.feed(f"w {out}")
    assert out.read_text().strip() == s.token and "keep it private" in j.status
    if os.name != "nt":
        assert (out.stat().st_mode & 0o777) == 0o600
    j.feed("b")
    assert s.token == "" and s.result == []


def test_every_field_is_checked_before_an_issuer_key_is_made(at_token, keyfile):
    j, s = at_token
    _fill(j)
    j.feed("d elsewhere.org")
    j.feed(f"k {keyfile}")
    j.feed("i")
    assert "outside its access domain" in j.status and s.token == ""
    assert not os.path.exists(mt.issuer_dir("west"))
    j.feed("d example.org")
    j.feed("m West!")
    j.feed("i")
    assert "not a valid mesh name" in j.status


def test_no_key_file_says_how_to_give_one(at_token, tmp_path):
    j, s = at_token
    _fill(j)
    j.feed("i")
    assert j.status == step.NO_KEY
    j.feed(f"k {tmp_path / 'missing'}")
    j.feed("i")
    assert "could not be read" in j.status
    empty = tmp_path / "empty"
    empty.write_text("\n")
    j.feed(f"k {empty}")
    j.feed("i")
    assert "is empty" in j.status
    assert not os.path.exists(mt.issuer_dir("west"))


def test_a_key_from_a_file_is_not_called_single_use(at_token, keyfile, monkeypatch):
    """A file's key may be reusable (provision.json makes some): the screen does not
    tell the admin it is single-use or that its file can be deleted."""
    j, s = at_token
    _fill(j)
    j.feed(f"k {keyfile}")
    monkeypatch.setattr(mt, "ensure_issuer",
                        lambda mesh, **k: ("/k", "ssh-ed25519 AAAA", "SHA256:x"))
    monkeypatch.setattr(mt, "issue", lambda **kw: "tok")
    monkeypatch.setattr(mt, "parse", lambda t: (mt.MeshGrant(
        mesh="west", domain="example.org", role="admin", shell=True,
        login_server="https://hs.example.org", auth_key=KEY, expires=2, issued=1,
        issuer="ssh-ed25519 AAAA"), b"", b""))
    j.feed("i")
    text = _text(j)
    assert "single-use" not in text and "can be deleted" not in text
    assert f"so {keyfile} is not needed for this token" in text
    assert "a reusable key stays valid until it expires or is expired in headscale" in text


def test_a_signing_failure_is_a_sentence_not_a_crash(at_token, keyfile, monkeypatch):
    j, s = at_token
    _fill(j)
    j.feed(f"k {keyfile}")
    monkeypatch.setattr(mt, "ensure_issuer", lambda *a, **k: (_ for _ in ()).throw(
        mt.TokenError("tool", "ssh-keygen could not create the issuer key: boom")))
    j.feed("i")
    assert j.status.endswith("boom") and s.token == ""


# ── minting: a printed line, never docker ─────────────────────────────────────────
def test_mint_prints_the_cli_line_and_runs_nothing(at_token):
    j, s = at_token
    _fill(j)
    j.feed("mint")
    text = _text(j)
    # no u USER: the line is there at once, without --headscale-user, and the screen
    # says which default the CLI mints for
    assert f"headscale user {step.DEFAULT_USER}" in text
    assert "net.hugmesh.headscale.user label, else hugmesh" in step.DEFAULT_USER
    assert "(the running one labelled or named like headscale)" in text
    assert step.MINT_NOTE in text
    assert step.mint_line(s.fields()) in text and "--headscale-" not in text
    j.feed("i")
    assert "does not start docker" in j.status and s.token == ""
    j.feed("u ops")
    j.feed("c hugmesh-headscale")
    j.feed("i")
    assert "does not start docker" in j.status and s.token == ""
    text = _text(j)
    assert step.MINT_NOTE in text
    line = step.mint_line(s.fields(), user="ops", container="hugmesh-headscale")
    assert line in text
    argv = step.mint_argv(s.fields(), user="ops", container="hugmesh-headscale")
    rest = argv[argv.index("--mesh-token") + 1:]
    assert rest == ["issue", "--mesh", "west", "--domain", "example.org", "--role",
                    "admin", "--shell", "--login-server", "https://hs.example.org",
                    "--mint", "--expires", "1h", "--headscale-container",
                    "hugmesh-headscale", "--headscale-user", "ops"]
    j.feed("c --privileged")
    assert "not a container name" in j.status and s.hs_container == "hugmesh-headscale"
    j.feed("c -")
    assert s.hs_container == "" and "--headscale-container" not in _text(j)
    assert "--headscale-user ops" in _text(j)
    j.feed("u -")
    assert s.hs_user == "" and "--headscale-user" not in _text(j)
    assert step.mint_line(s.fields()) in _text(j) and step.DEFAULT_USER in _text(j)
    assert not os.path.exists(mt.issuer_dir("west"))


def test_mint_line_is_withheld_until_the_fields_check_out(at_token):
    j, s = at_token
    j.feed("mint")
    assert "Not ready:" in _text(j) and "--mesh-token" not in _text(j)


def test_the_printed_mint_line_is_one_the_cli_accepts(at_token, monkeypatch, capsys):
    """Fed to the CLI (docker and signing stubbed), the line mints for the user it
    names with the token's lifetime and signs exactly the fields on the screen."""
    j, s = at_token
    _fill(j)
    j.feed("e 2d")
    j.feed("mint")
    j.feed("u joiners")
    argv = step.mint_argv(s.fields(), user=s.hs_user)
    assert step.mint_line(s.fields(), user=s.hs_user) in _text(j)
    seen = {}
    monkeypatch.setattr(mt, "find_headscale_container", lambda runner=None: "hs")
    monkeypatch.setattr(mt, "headscale_labels", lambda name, runner=None: {})
    monkeypatch.setattr(mt, "check_signing", lambda *a, **k: None)
    monkeypatch.setattr(mt, "ensure_issuer",
                        lambda mesh, **k: ("/k", "ssh-ed25519 AAAA", "SHA256:x"))

    def mint(**kw):
        seen["mint"] = kw
        return KEY
    monkeypatch.setattr(mt, "mint_preauth_key", mint)
    monkeypatch.setattr(mt, "issue", lambda **kw: seen.setdefault("issue", kw) and "tok")
    monkeypatch.setattr(mt, "parse", lambda t: (mt.MeshGrant(
        mesh="west", domain="example.org", role="admin", shell=True,
        login_server="https://hs.example.org", auth_key=KEY, expires=2, issued=1,
        issuer="ssh-ed25519 AAAA"), b"", b""))
    assert mt.main(argv[argv.index("--mesh-token") + 1:]) == 0
    assert seen["mint"]["user"] == "joiners" and seen["mint"]["lifetime_s"] == 2 * 86400
    signed = {k: seen["issue"][k] for k in s.fields()}
    assert signed == s.fields()


@pytest.mark.parametrize("osname, first", [("posix", "python3"), ("nt", "& ")])
def test_the_mint_line_is_spelled_for_the_platforms_terminal(osname, first):
    fields = dict(mesh="west", domain="example.org", role="user", shell=False,
                  login_server="https://hs.example.org", lifetime_s=7 * 86400,
                  node_name="")
    line = step.mint_line(fields, osname=osname)
    assert line.startswith(first)
    assert "--mesh-token issue" in line and "--expires 7d" in line
    assert "--shell" not in line and KEY not in line
    if osname == "posix":
        assert shlex.split(line)[1:4] == ["-m", "hugmesh_studio", "--mesh-token"]


def test_lifetime_text_round_trips_through_the_cli_parser():
    for seconds in (60, 3600, 5400, 86400, mt.MAX_LIFETIME_S):
        assert mt._lifetime(step.lifetime_text(seconds)) == seconds


def test_the_token_screen_and_its_mint_line_never_import_qt(tmp_path):
    """In a fresh interpreter whose Qt imports would fail loudly, the screen is built
    from the local-mesh screen and prints its mint line."""
    script = textwrap.dedent("""
        import sys
        BLOCK = ("PyQt6", "PyQt5", "PySide6", "PySide2")
        class NoQt:
            def find_spec(self, name, path=None, target=None):
                if name.split(".")[0] in BLOCK:
                    raise ImportError("Qt imported by the TUI token screen: " + name)
        sys.meta_path.insert(0, NoQt())
        from hugmesh_studio.tui import localmesh, mesh_token_step as step
        s = step.MeshTokenScreen()
        s.mesh, s.domain, s.login_server = "west", "example.org", "https://hs.example.org"
        assert "--mesh-token" in step.mint_line(s.fields())
        assert not [m for m in sys.modules if m.split(".")[0] in BLOCK]
    """)
    env = {**os.environ, "PYTHONPATH": STUDIO,
           "HUGMESH_STUDIO_STATE_DIR": str(tmp_path / "state")}
    r = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True,
                       cwd=STUDIO, env=env, timeout=120)
    assert r.returncode == 0, r.stderr


@pytest.mark.parametrize("labels, user, tags", [
    ({"user": "members", "key_tags": ("tag:hugmesh",)}, "members", ("tag:hugmesh",)),
    ({}, "hugmesh", ())])
def test_the_mint_line_without_a_user_mints_for_the_default(at_token, monkeypatch, capsys,
                                                            labels, user, tags):
    """Without u USER the printed line names no user: the CLI it runs mints for the
    headscale container's label, else hugmesh, as the screen says."""
    j, s = at_token
    _fill(j)
    j.feed("mint")
    argv = step.mint_argv(s.fields())
    assert "--headscale-user" not in argv and step.mint_line(s.fields()) in _text(j)
    seen = {}
    monkeypatch.setattr(mt, "find_headscale_container", lambda runner=None: "hs")
    monkeypatch.setattr(mt, "headscale_labels", lambda name, runner=None: dict(labels))
    monkeypatch.setattr(mt, "check_signing", lambda *a, **k: None)
    monkeypatch.setattr(mt, "ensure_issuer",
                        lambda mesh, **k: ("/k", "ssh-ed25519 AAAA", "SHA256:x"))

    def mint(**kw):
        seen["mint"] = kw
        return KEY
    monkeypatch.setattr(mt, "mint_preauth_key", mint)
    monkeypatch.setattr(mt, "issue", lambda **kw: "tok")
    monkeypatch.setattr(mt, "parse", lambda t: (mt.MeshGrant(
        mesh="west", domain="example.org", role="admin", shell=True,
        login_server="https://hs.example.org", auth_key=KEY, expires=2, issued=1,
        issuer="ssh-ed25519 AAAA"), b"", b""))
    assert mt.main(argv[argv.index("--mesh-token") + 1:]) == 0
    assert (seen["mint"]["user"], tuple(seen["mint"]["tags"])) == (user, tags)
    assert f"for the headscale user {user}" in capsys.readouterr().err


# ── an onion login server (operator report 2026-11-12) ────────────────────────────
ONION = "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"


def test_the_empty_login_server_row_shows_the_onion_form(at_token):
    j, _s = at_token
    assert ".onion" in _text(j)


@needs_keygen
def test_an_onion_login_server_is_accepted_and_issued(at_token, keyfile):
    j, s = at_token
    _fill(j, role="user", shell=False)
    j.feed(f"l http://{ONION}")
    assert not j.status, j.status
    assert mt.ONION_NOTE in _text(j)                   # the dialog's inline line
    j.feed(f"k {keyfile}")
    j.feed("i")
    assert s.token, j.status
    assert mt.parse(s.token)[0].login_server == f"http://{ONION}"


def test_a_v2_onion_is_refused_with_its_reason(at_token, keyfile):
    j, s = at_token
    _fill(j, role="user", shell=False)
    j.feed("l http://expyuzz4wqqyqhjn.onion")
    assert "v2 onion address" in _text(j)
    j.feed(f"k {keyfile}")
    j.feed("i")
    assert not s.token
    assert "v2 onion address" in j.status
