"""Seeded sign-in credentials — the roster the Local-Docker-mesh page shows so an
operator knows WHO to log in as after `make stack-seed`.

The load-bearing property under test is NO DRIFT: the roster is parsed out of
tests/qemu/seed-accounts.sh (the seeder that actually creates the accounts), and the
password precedence mirrors that script's role_password(). A hardcoded copy would
rot silently the first time a persona is added, and the dialog would then hand the
operator credentials that do not work — worse than showing nothing. These tests pin
the parse against the REAL seeder in this checkout, not a fixture, so a roster-format
change in the seeder fails here instead of in front of a user.

The Qt half (_credentials_dialog.py) is covered in test_local_mesh.py beside the
other GUI assertions; this file is Qt-free and runs in the system-python CI lane.
"""
import os

from hugmesh_studio.core.seeded_credentials import (
    ROSTER_SCRIPT, Roster, SeededUser, _NOT_SEEDED, as_copyable_text, load_roster,
    parse_roster_body, resolve_password, suggested_signin,
)

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ── the parser ────────────────────────────────────────────────────────────────

def test_parse_entry_grammar_username_roles_passwordenv():
    got = parse_roster_body("alice:ROLE_A,ROLE_B:E2E_ALICE_PASSWORD bob:ROLE_B:E2E_BOB_PASSWORD")
    assert got == [("alice", ("ROLE_A", "ROLE_B"), "E2E_ALICE_PASSWORD"),
                   ("bob", ("ROLE_B",), "E2E_BOB_PASSWORD")]


def test_parse_joins_shell_line_continuations_with_whitespace():
    # The seeder writes one persona per line ending in a backslash. Collapsing the
    # continuation with '' instead of ' ' would weld two usernames into one token.
    body = "alice:ROLE_A:E2E_A_PASSWORD \\\nbob:ROLE_B:E2E_B_PASSWORD"
    assert [u for u, _, _ in parse_roster_body(body)] == ["alice", "bob"]


def test_parse_skips_malformed_entries_instead_of_raising():
    # A roster that grows an unexpected shape must degrade to the entries we DO
    # understand — never blank the whole dialog.
    got = parse_roster_body("ok:ROLE_A:E2E_OK_PASSWORD nocolons two:only")
    assert [u for u, _, _ in got] == ["ok"]


def test_parse_allows_a_roleless_persona():
    # e2e-pending holds no roles (awaiting approval) — a legitimate entry.
    got = parse_roster_body("e2e-pending::E2E_PENDING_PASSWORD")
    assert got == [("e2e-pending", (), "E2E_PENDING_PASSWORD")]


# ── password precedence (mirrors seed-accounts.sh role_password) ──────────────

def test_password_precedence_per_user_wins_then_shared_then_default():
    env = {"E2E_ADMIN_PASSWORD": "peruser", "E2E_PASSWORD": "shared"}
    assert resolve_password("E2E_ADMIN_PASSWORD", env) == "peruser"
    assert resolve_password("E2E_OTHER_PASSWORD", env) == "shared"   # falls to shared
    # no per-user/shared env AND no generator_dir to find a credentials file in ->
    # nothing resolved, so the NOT-SEEDED marker, never a literal fallback password.
    assert resolve_password("E2E_OTHER_PASSWORD", {}) == _NOT_SEEDED
    assert resolve_password("", {}) == _NOT_SEEDED


def test_password_reads_the_passed_env_not_os_environ(monkeypatch):
    # The dialog must show what the SEEDER will set. The Studio hands `make
    # stack-seed` an env it builds itself, so resolving against os.environ could
    # display a password the seeder never used.
    monkeypatch.setenv("E2E_PASSWORD", "from-os-environ")
    assert resolve_password("", {"E2E_PASSWORD": "from-studio-env"}) == "from-studio-env"


# ── the run-state credentials file (CONTRACT rule 3, the 3rd link in the chain) ──

def test_password_falls_back_to_the_credentials_file(tmp_path):
    # No per-user/shared env set, but tests/stack/e2e-password.sh already wrote a
    # value into the run-state file for this generator checkout — the table must
    # show THAT, not the not-seeded marker.
    (tmp_path / ".e2e-credentials").write_text("E2E_PASSWORD=from-the-file\n")
    assert resolve_password("", {}, str(tmp_path)) == "from-the-file"


def test_password_env_still_wins_over_the_credentials_file(tmp_path):
    (tmp_path / ".e2e-credentials").write_text("E2E_PASSWORD=from-the-file\n")
    env = {"E2E_PASSWORD": "from-env"}
    assert resolve_password("", env, str(tmp_path)) == "from-env"


def test_credentials_file_path_is_overridable(tmp_path):
    custom = tmp_path / "elsewhere" / "creds"
    custom.parent.mkdir()
    custom.write_text("E2E_PASSWORD=from-custom-path\n")
    env = {"E2E_CREDENTIALS_FILE": str(custom)}
    # a bogus generator_dir must be ignored once E2E_CREDENTIALS_FILE names a path
    assert resolve_password("", env, str(tmp_path / "not-the-real-checkout")) \
        == "from-custom-path"


def test_missing_credentials_file_reports_not_seeded(tmp_path):
    assert resolve_password("", {}, str(tmp_path)) == _NOT_SEEDED


# ── against the REAL seeder in this checkout (the anti-drift pin) ─────────────

def test_loads_the_real_roster_from_this_checkout():
    r = load_roster(GENERATOR_DIR)
    assert r.error == "", r.error
    assert r.users, "the real seeder declared no personas"
    names = {u.username for u in r.users}
    # The personas the docs + Makefile banner promise an operator can sign in as.
    assert {"e2e-admin", "e2e-mod", "e2e-user"} <= names
    admin = next(u for u in r.users if u.username == "e2e-admin")
    assert "ROLE_ADMIN" in admin.roles
    # this checkout has neither an E2E_PASSWORD env nor a .e2e-credentials file
    # (nothing has run `make stack-seed` here), so the honest answer is the
    # not-seeded marker — never a guessed/literal password.
    assert admin.password == _NOT_SEEDED
    assert bool(r) is True


def test_roster_script_path_points_at_the_real_seeder():
    assert os.path.isfile(os.path.join(GENERATOR_DIR, ROSTER_SCRIPT))


# ── failure paths must be reportable, never raise ────────────────────────────

def test_missing_checkout_reports_an_error_instead_of_raising(tmp_path):
    r = load_roster(str(tmp_path))
    assert r.users == [] and bool(r) is False
    assert "could not read" in r.error


def test_roster_variable_gone_reports_a_named_error(tmp_path):
    script = tmp_path / ROSTER_SCRIPT
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text("# a seeder that no longer declares the roster\n")
    r = load_roster(str(tmp_path))
    assert "SYSTEMS_ROLE_USERS" in r.error


# ── presentation helpers ─────────────────────────────────────────────────────

def test_suggested_signin_prefers_admin_and_never_empties_on_a_full_roster():
    r = Roster(users=[SeededUser("e2e-user", ("ROLE_USER",), "p"),
                      SeededUser("e2e-admin", ("ROLE_ADMIN",), "p")])
    assert suggested_signin(r).username == "e2e-admin"
    # unknown roster -> still features something rather than None
    other = Roster(users=[SeededUser("someone", (), "p")])
    assert suggested_signin(other).username == "someone"
    assert suggested_signin(Roster()) is None


def test_roles_display_names_the_roleless_case():
    assert SeededUser("x", (), "p").roles_display.startswith("(none")
    assert SeededUser("x", ("A", "B"), "p").roles_display == "A, B"


def test_copyable_text_is_tab_separated_with_every_account():
    r = load_roster(GENERATOR_DIR)
    text = as_copyable_text(r)
    for u in r.users:
        assert f"{u.username}\t{u.password}\t" in text
    # one header pair + one line per user, trailing newline
    assert len(text.strip().splitlines()) == len(r.users) + 2


def test_module_imports_no_qt():
    # must run in the Qt-free CI lane (proven in a FRESH interpreter, since this
    # suite imports Qt elsewhere).
    import subprocess
    import sys
    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    probe = (
        "import hugmesh_studio.core.seeded_credentials as m, sys;"
        "assert callable(m.load_roster);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad"
    )
    env = dict(os.environ, PYTHONPATH=studio_root)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
