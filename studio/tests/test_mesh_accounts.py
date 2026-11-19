"""core/mesh_accounts.py — people on the running mesh, created through Casdoor's admin
API with no e2e script in the path (2026-11-19).

Every scenario runs the REAL client (urllib, cookie jars, form and JSON bodies) against
tests/scripts/casdoor_stub.py over loopback HTTP: the stub keeps real state, refuses
denied calls the way Casdoor does (HTTP 200 + status error), masks passwords on read,
and refuses an identical set-password, which is the only read-back a password has. So
"created" below means the stub's store holds it, not that the client said so.
"""
from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request

import pytest

from _casdoor_stub import ROOT, stub  # noqa: F401  (the fixture)
from hugmesh_studio.core import mesh_accounts as ma
from hugmesh_studio.core import own_casdoor
from hugmesh_studio.core.config import Domain

ADMIN_PW = "checkout-admin-pw-0123456789"


@pytest.fixture
def cas(stub):  # noqa: F811
    """The stub with this checkout's admin password unless a test says otherwise."""
    def start(mode="ok", admin_pw=ADMIN_PW, seed=None, **extra):
        return stub(mode=mode, admin_pw=admin_pw, seed=seed, **extra)
    return start


def _gd(tmp_path, admin_pw=ADMIN_PW):
    d = tmp_path / "gen"
    (d / "tests" / "stack").mkdir(parents=True)
    if admin_pw is not None:
        (d / "tests" / "stack" / ".env").write_text(
            f"OTHER=1\nCASDOOR_ADMIN_PASSWORD={admin_pw}\n")
    return str(d)


def _get(url, path, admin_pw=ADMIN_PW):
    """Read the stub's store as an admin, independently of the client under test."""
    cd = ma.CasdoorAdmin(url)
    cd.login(admin_pw)
    return cd._ok("GET", path)


def _central(url, domain="acme.example"):
    return ma.Target(url, domain, True, "the test's central sign-in")


def _login_ok(url, user, pw):
    """The stub's password grant: True iff ``pw`` IS the stored credential."""
    data = urllib.parse.urlencode({"grant_type": "password", "username": f"hugmesh/{user}",
                                   "password": pw, "client_id": "x",
                                   "client_secret": "y"}).encode()
    with urllib.request.urlopen(url + "/api/login/oauth/access_token", data) as r:
        return "access_token" in json.loads(r.read())




# ── the role catalogue no longer needs seed-e2e.sh, but must not drift from it ────────
def test_grantable_roles_equal_the_seeders_operator_roles():
    text = open(os.path.join(ROOT, "tests", "stack", "seed-e2e.sh")).read()
    m = re.search(r'LOCAL_OPERATOR_ROLES="\$\{LOCAL_OPERATOR_ROLES:-([A-Z_,]+)\}"', text)
    assert m, "seed-e2e.sh LOCAL_OPERATOR_ROLES moved"
    assert set(ma.GRANTABLE_ROLES) == set(m.group(1).split(","))
    assert ma.FLOOR_ROLE in ma.GRANTABLE_ROLES


# ── creating an account ───────────────────────────────────────────────────────────────
def test_create_makes_org_roles_user_password_and_memberships(cas, tmp_path):
    url, _ = cas()
    gd = _gd(tmp_path)
    out = ma.create_account(_central(url), gd, "alice", "alice-pass-1",
                            ["ROLE_MATRIX", "ROLE_MOD"], email="alice@example.org")
    assert out.ok, out.message
    assert out.password == ""                          # given, not generated
    assert _get(url, "/api/get-organization?id=admin/hugmesh")
    user = _get(url, "/api/get-user?id=hugmesh/alice")
    assert user["email"] == "alice@example.org"
    assert user["properties"] == {ma.DOMAIN_PROPERTY: "acme.example"}
    for role in ("ROLE_USER", "ROLE_MATRIX", "ROLE_MOD"):
        assert "hugmesh/alice" in _get(url, f"/api/get-role?id=hugmesh/{role}")["users"]
    assert _login_ok(url, "alice", "alice-pass-1")
    assert "alice-pass-1" not in out.message


def test_granting_adds_a_member_and_keeps_the_others(cas, tmp_path):
    seed = {"organization:admin/hugmesh": {"owner": "admin", "name": "hugmesh"},
            "role:hugmesh/ROLE_USER": {"owner": "hugmesh", "name": "ROLE_USER",
                                       "users": ["hugmesh/e2e-user", "hugmesh/bob"]},
            "role:hugmesh/ROLE_ADMIN": {"owner": "hugmesh", "name": "ROLE_ADMIN",
                                        "users": ["hugmesh/e2e-admin"]}}
    url, _ = cas(seed=seed)
    out = ma.create_account(_central(url), _gd(tmp_path), "carol", "carol-pass-1",
                            ["ROLE_ADMIN"])
    assert out.ok, out.message
    assert set(_get(url, "/api/get-role?id=hugmesh/ROLE_USER")["users"]) == {
        "hugmesh/e2e-user", "hugmesh/bob", "hugmesh/carol"}
    assert set(_get(url, "/api/get-role?id=hugmesh/ROLE_ADMIN")["users"]) == {
        "hugmesh/e2e-admin", "hugmesh/carol"}


def test_an_existing_name_is_refused_and_never_repassworded(cas, tmp_path):
    url, _ = cas()
    gd = _gd(tmp_path)
    assert ma.create_account(_central(url), gd, "dave", "first-pass-1", []).ok
    out = ma.create_account(_central(url), gd, "dave", "second-pass-2", ["ROLE_ADMIN"])
    assert not out.ok and "already exists" in out.message
    assert _login_ok(url, "dave", "first-pass-1")
    assert "hugmesh/dave" not in (_get(url, "/api/get-role?id=hugmesh/ROLE_ADMIN") or {}
                                  ).get("users", [])


def test_an_empty_password_is_generated_returned_once_and_stored(cas, tmp_path):
    url, _ = cas()
    out = ma.create_account(_central(url), _gd(tmp_path), "erin", "", [])
    assert out.ok and len(out.password) >= ma.MIN_PASSWORD
    assert out.password not in out.message
    assert _login_ok(url, "erin", out.password)


def test_a_dropped_password_on_create_is_repaired_and_proven(cas, tmp_path):
    url, _ = cas(mode="adduser-droppw")
    out = ma.create_account(_central(url), _gd(tmp_path), "fay", "fay-pass-12", [])
    assert out.ok, out.message
    assert _login_ok(url, "fay", "fay-pass-12")


def test_a_create_whose_password_landed_is_proven_by_the_already_current_refusal(
        cas, tmp_path):
    url, _ = cas(mode="setpw-noop")
    # the admin is already on this checkout's value, so no admin move is needed
    out = ma.create_account(_central(url), _gd(tmp_path), "gus", "gus-pass-12", [])
    # setpw-noop: add-user stores the password, so the FIRST write is refused as
    # already current and the second too — that is a proven credential
    assert out.ok, out.message
    assert _login_ok(url, "gus", "gus-pass-12")


def test_denied_writes_are_failures_never_success(cas, tmp_path):
    url, _ = cas(mode="deny-writes")
    out = ma.create_account(_central(url), _gd(tmp_path), "hal", "hal-pass-123", [])
    assert not out.ok and "refused" in out.message.lower()


def test_writes_that_vanish_are_caught_by_the_read_back(cas, tmp_path):
    url, _ = cas(mode="writes-vanish")
    out = ma.create_account(_central(url), _gd(tmp_path), "ivy", "ivy-pass-123", [])
    assert not out.ok


@pytest.mark.parametrize("name", ["", "a--b", "-x", "x_", "me@example.org", "a b"])
def test_illegal_names_are_refused_before_any_call(cas, tmp_path, name):
    url, journal = cas()
    out = ma.create_account(_central(url), _gd(tmp_path), name, "pass-pass-1", [])
    assert not out.ok
    assert not journal.exists() or journal.read_text() == ""


def test_an_unknown_role_is_refused(cas, tmp_path):
    url, _ = cas()
    out = ma.create_account(_central(url), _gd(tmp_path), "jo", "pass-pass-1",
                            ["ROLE_GAMES_ADMIN"])
    assert not out.ok and "ROLE_GAMES_ADMIN" in out.message


# ── the admin session ─────────────────────────────────────────────────────────────────
def test_a_factory_admin_is_moved_onto_the_checkouts_value_and_proven(cas, tmp_path):
    url, _ = cas(admin_pw=ma.FACTORY_ADMIN_PASSWORD)
    lines = []
    out = ma.create_account(_central(url), _gd(tmp_path), "kai", "kai-pass-123", [],
                            on_line=lines.append)
    assert out.ok, out.message
    assert any("factory password" in ln for ln in lines)
    assert not ma.CasdoorAdmin(url)._try_login(ma.FACTORY_ADMIN_PASSWORD)[0]
    assert ma.CasdoorAdmin(url)._try_login(ADMIN_PW)[0]


def test_an_admin_on_a_value_this_checkout_lacks_is_refused_untouched(cas, tmp_path):
    url, _ = cas(admin_pw="somebody-elses-value-99")
    out = ma.create_account(_central(url), _gd(tmp_path), "lee", "lee-pass-123", [])
    assert not out.ok and "Nothing was changed" in out.message
    assert ADMIN_PW not in out.message


def test_the_sign_in_throttle_is_named_as_such(cas, tmp_path):
    url, _ = cas(mode="lockout", STUB_LOCKOUT_AFTER="0")
    out = ma.create_account(_central(url), _gd(tmp_path), "max", "max-pass-123", [])
    assert not out.ok and "throttl" in out.message


def test_no_admin_password_says_how_to_get_one(cas, tmp_path):
    url, journal = cas()
    out = ma.create_account(_central(url), _gd(tmp_path, admin_pw=None), "ned",
                            "ned-pass-123", [], env={})
    assert not out.ok and "CASDOOR_ADMIN_PASSWORD" in out.message


def test_admin_password_prefers_the_export_and_never_writes(tmp_path):
    gd = _gd(tmp_path)
    env_file = os.path.join(gd, ma.ENV_FILE_REL)
    before = open(env_file).read()
    assert ma.admin_password(gd, env={}) == ADMIN_PW
    assert ma.admin_password(gd, env={"CASDOOR_ADMIN_PASS": "exported"}) == "exported"
    assert open(env_file).read() == before
    assert ma.admin_password(str(tmp_path / "nowhere"), env={}) == ""


# ── listing ───────────────────────────────────────────────────────────────────────────
def test_list_reads_accounts_with_their_roles_and_domain(cas, tmp_path):
    url, _ = cas()
    gd = _gd(tmp_path)
    assert ma.create_account(_central(url, "a.example"), gd, "olga", "olga-pass-1",
                             ["ROLE_WIKI"]).ok
    assert ma.create_account(_central(url, "b.example"), gd, "pete", "pete-pass-1",
                             []).ok
    got = ma.list_accounts(_central(url), gd)
    assert got.ok, got.message
    by = {a.name: a for a in got.accounts}
    assert by["olga"].domain == "a.example" and by["pete"].domain == "b.example"
    assert by["olga"].roles == ("ROLE_USER", "ROLE_WIKI")


# ── which Casdoor ─────────────────────────────────────────────────────────────────────
def test_targets_follow_the_domains_sign_in(tmp_path):
    gd = _gd(tmp_path)
    open(os.path.join(gd, ma.OVERLAY_REL), "w").write(
        own_casdoor.compose_overlay(["own.example", "two.example"],
                                    ports={"two.example": 8007}))
    env = {}
    t, why = ma.target_for("mesh.example", None, gd, own=True, env=env)
    assert t.central and t.url == ma.CENTRAL_URL and not why
    t, _ = ma.target_for("inherit.example", Domain(name="inherit.example"), gd, env=env)
    assert t.central and t.domain == "inherit.example"
    t, _ = ma.target_for("own.example", Domain(name="own.example", idp="own"), gd, env=env)
    assert not t.central and t.url == "http://127.0.0.1:8001"
    t, _ = ma.target_for("two.example", Domain(name="two.example", idp="own"), gd, env=env)
    assert t.url == "http://127.0.0.1:8007"
    t, why = ma.target_for("gone.example", Domain(name="gone.example", idp="own"), gd,
                           env=env)
    assert t is None and "not started a Casdoor" in why
    ext = Domain(name="ext.example", idp="own",
                 idp_settings={"provider": "entra", "issuer": "https://x", "client_id": "c"})
    t, why = ma.target_for("ext.example", ext, gd, env=env)
    assert t is None and "entra" in why
    t, _ = ma.target_for("m", None, gd, own=True, env={"CASDOOR_URL": "http://h:9"})
    assert t.url == "http://h:9"


def test_an_own_casdoor_account_carries_no_domain_marker(cas, tmp_path):
    url, _ = cas()
    target = ma.Target(url, "own.example", False, "own.example's own Casdoor")
    assert ma.create_account(target, _gd(tmp_path), "quin", "quin-pass-1", []).ok
    assert not _get(url, "/api/get-user?id=hugmesh/quin").get("properties")


def test_the_module_is_qt_free():
    src = open(ma.__file__).read()
    assert "PySide6" not in src and "PyQt6" not in src and "from ..gui" not in src
