"""Add user on the KIND lane (#540), through Casdoor's admin API (2026-11-19).

The kind lane used to render with ``tests/qemu/seed-accounts.sh --roles`` and apply
``roles/apply-systems-roles.sh``; it now hands the apply to ``core.mesh_accounts`` (the
operator: "adding users should work without the e2e scripts"). What this file pins:

1. **Success is READ BACK.** Casdoor answers a DENIED call with HTTP 200 +
   ``{"status":"error"}``. The apply reads its own writes back, and the post-condition
   here is independent of it: the cluster's own Casdoor database (the #539 reader)
   must hold the account AND every role it was granted. An account in none of its
   roles signs in on the gateway floor and then 403s everywhere: a FAILED add.
2. **The Studio still spawns no ``kubectl port-forward``.** It ASKS for the ``casdoor``
   door ``make view LANE=kind-svc`` publishes and REFUSES with that remedy when it is
   absent — never a fallback into starting one.
3. **The admin password comes from Vault, never derived, never in argv.**
4. **No seeder script runs** and no shared e2e password is read: one account is added,
   no other account is touched.

The door is the stub Casdoor (tests/scripts/casdoor_stub.py) over loopback HTTP;
kubectl/docker are a fake at the ``runner`` override point; the read-back is a fake at
``identities``. NOTHING here touches a cluster.
"""
from __future__ import annotations

import base64
import json

import pytest

from _casdoor_stub import stub  # noqa: F401  (the fixture)
from hugmesh_studio.core import credentials_truth as ct
from hugmesh_studio.core import kind_seed
from hugmesh_studio.core import mesh_accounts as ma
from hugmesh_studio.core.seeded_credentials import Roster, SeededUser, annotate

CLUSTER_PW = "cluster-seed-pw-7Kq"
ADMIN_PW = "casdoor-admin-pw-3Zt"
VAULT_TOKEN = "hvs.rootToken"


def _b64(s):
    return base64.b64encode(s.encode()).decode()


class _Fake:
    """A fake kind lane at ``kind_seed``'s subprocess override point. Every call is
    recorded so a test can assert what was NOT run (no port-forward, no seeder)."""

    def __init__(self, *, vault_token=VAULT_TOKEN, admin_pw=ADMIN_PW, door_url=""):
        self.vault_token, self.admin_pw = vault_token, admin_pw
        self.door_url = door_url
        self.calls: list[list[str]] = []

    def runner(self, cmd, *, env=None, cwd=None, timeout=60):
        self.calls.append(list(cmd))
        j = " ".join(cmd)
        if "get" in cmd and "secret" in cmd and kind_seed.VAULT_BOOTSTRAP_SECRET in cmd:
            if self.vault_token is None:
                return 1, "Error from server (NotFound): secrets not found"
            return 0, _b64(self.vault_token)
        if "exec" in cmd and "vault" in cmd:
            if self.admin_pw is None:
                return 1, "No value found at secret/hugmesh/casdoor"
            assert f"VAULT_TOKEN={self.vault_token}" in cmd, \
                "the admin read must use the token it just read back from the cluster"
            return 0, self.admin_pw + "\n"
        return 1, f"unexpected: {j}"

    def door(self, *_a, **_k):
        return {kind_seed.DOOR_NAME: self.door_url}

    def no_door(self, *_a, **_k):
        return {}


@pytest.fixture(autouse=True)
def _kubectl(monkeypatch):
    monkeypatch.setattr(kind_seed, "_kubectl", lambda _gd: "kubectl")


@pytest.fixture
def lane(stub, tmp_path):  # noqa: F811
    """A kind lane whose casdoor door is a live stub Casdoor holding ``ADMIN_PW``."""
    def make(mode="ok", **fake_kw):
        url, journal = stub(mode=mode, admin_pw=ADMIN_PW)
        return _Fake(door_url=url, **fake_kw), url, journal
    return make


def _identities(users=("e2e-admin", "newbie"), roles=None):
    if roles is None:
        roles = (("ROLE_USER", frozenset(users)),)
    return lambda: ct.KindIdentities(users=frozenset(users), roles=tuple(roles))


def _add(tmp_path, fake, *, identities=None, doors=None, username="newbie",
         roles=("ROLE_USER",), password="newbie-pass-1", env=None):
    return kind_seed.add_user_kind(
        generator_dir=str(tmp_path), cluster="hugmesh-local", username=username,
        roles=roles, password=password, env=env if env is not None else {},
        runner=fake.runner, doors=doors or fake.door,
        identities=identities or _identities())


def _paths(journal):
    if not journal.exists():
        return []
    return [json.loads(ln)["path"] for ln in journal.read_text().splitlines() if ln]


# ── the door: asked, never started ────────────────────────────────────────────────

def test_without_the_casdoor_door_it_refuses_and_names_the_remedy(tmp_path):
    f = _Fake()
    out = _add(tmp_path, f, doors=f.no_door)
    assert out.ok is False and out.stage == kind_seed.STAGE_DOOR
    assert "make view LANE=kind-svc" in out.message
    assert "does not start a kubectl port-forward" in out.message
    assert f.calls == []                         # it stopped THERE


def test_it_runs_no_port_forward_and_no_seeder(lane, tmp_path):
    f, _url, _j = lane()
    out = _add(tmp_path, f)
    assert out.ok, out.message
    joined = [" ".join(c) for c in f.calls]
    assert not any("port-forward" in c for c in joined)
    assert not any(c.startswith("bash") or "seed-accounts" in c
                   or "apply-systems-roles" in c for c in joined)
    # and never the cluster's shared e2e password
    assert not any(kind_seed.SEED_SECRET in c for c in joined)


# ── the Casdoor admin password: read back from Vault, never derived ───────────────

def test_the_admin_password_comes_from_vault_and_signs_in_at_the_door(lane, tmp_path):
    f, url, journal = lane()
    assert _add(tmp_path, f).ok
    logins = [json.loads(ln) for ln in journal.read_text().splitlines()
              if '"/api/login"' in ln]
    assert logins and logins[0]["result"] == "ok"
    for c in f.calls:                            # never argv (the token read aside)
        assert ADMIN_PW not in " ".join(a for a in c if not a.startswith("VAULT_TOKEN="))


def test_without_the_admin_password_it_refuses_instead_of_applying_blind(lane, tmp_path):
    f, _url, journal = lane(admin_pw=None)
    out = _add(tmp_path, f)
    assert out.ok is False and out.stage == kind_seed.STAGE_ADMIN
    assert "HTTP 200" in out.message
    assert _paths(journal) == []                 # Casdoor was never called


def test_a_vault_password_casdoor_refuses_is_an_apply_failure(stub, tmp_path):  # noqa: F811
    url, _ = stub(mode="ok", admin_pw="something-else-entirely")
    f = _Fake(door_url=url)
    out = _add(tmp_path, f)
    assert out.ok is False and out.stage == kind_seed.STAGE_APPLY
    assert ADMIN_PW not in out.message


# ── the apply: one account, its roles ADDED, the rest untouched ────────────────────

def test_the_account_and_its_roles_land_in_casdoor(lane, tmp_path):
    f, url, _ = lane()
    out = _add(tmp_path, f, roles=("ROLE_MOD",),
               identities=_identities(roles=(("ROLE_USER", frozenset({"newbie"})),
                                             ("ROLE_MOD", frozenset({"newbie"})))))
    assert out.ok, out.message
    cd = ma.CasdoorAdmin(url)
    cd.login(ADMIN_PW)
    assert "hugmesh/newbie" in cd._ok("GET", "/api/get-role?id=hugmesh/ROLE_MOD")["users"]
    assert out.granted == ("ROLE_USER", "ROLE_MOD")


def test_an_empty_password_is_generated_and_returned_never_in_the_message(lane,
                                                                           tmp_path):
    f, _url, _ = lane()
    out = _add(tmp_path, f, password="")
    assert out.ok and out.password and out.password not in out.message


def test_a_denied_apply_is_a_failure_not_a_success(lane, tmp_path):
    f, _url, _ = lane(mode="deny-writes")
    out = _add(tmp_path, f)
    assert out.ok is False and out.stage == kind_seed.STAGE_APPLY


# ── success is read back from the cluster, never reported ─────────────────────────

def test_an_account_the_store_does_not_hold_is_a_failure(lane, tmp_path):
    f, _url, _ = lane()
    out = _add(tmp_path, f, identities=_identities(users=("e2e-admin",)))
    assert out.ok is False and out.stage == kind_seed.STAGE_READBACK
    assert "NOT in the cluster's identity store" in out.message


def test_an_account_the_cluster_grants_none_of_its_roles_is_a_failed_add(lane, tmp_path):
    f, _url, _ = lane()
    out = _add(tmp_path, f, roles=("ROLE_MOD",),
               identities=_identities(users=("e2e-admin", "newbie"),
                                      roles=(("ROLE_MOD", frozenset()),
                                             ("ROLE_USER", frozenset({"newbie"})))))
    assert out.ok is False and out.stage == kind_seed.STAGE_READBACK
    assert out.missing == ("ROLE_MOD",)
    assert "403s on every page" in out.message


def test_an_unreadable_store_is_never_called_a_success(lane, tmp_path):
    f, _url, _ = lane()
    out = _add(tmp_path, f, identities=lambda: ct.KindIdentities(
        reason="the cluster's API did not answer"))
    assert out.ok is False and out.stage == kind_seed.STAGE_READBACK
    assert "unproven" in out.message and "own word" in out.message


def test_an_unreadable_ROLE_table_lands_but_says_the_roles_are_unverified(lane, tmp_path):
    f, _url, _ = lane()
    out = _add(tmp_path, f, identities=lambda: ct.KindIdentities(
        users=frozenset({"newbie"}), roles=None, reason="role query failed"))
    assert out.ok is True and "unverified" in out.message


def test_the_happy_path_says_what_the_cluster_grants_not_what_was_asked(lane, tmp_path):
    f, _url, _ = lane()
    out = _add(tmp_path, f, roles=("ROLE_USER",))
    assert out.ok and out.stage == kind_seed.STAGE_OK
    assert out.granted == ("ROLE_USER",) and out.missing == ()
    assert "read back from Casdoor's own database" in out.message


# ── the table afterwards shows the row because it EXISTS ──────────────────────────

def test_an_added_row_is_marked_from_the_running_mesh_not_from_the_request(tmp_path):
    """#540's last Done-when. "added this session" is a claim like any other: on a
    lane whose store was read, an add that did not land must read as not seeded."""
    (tmp_path / ".e2e-credentials").write_text(f"E2E_PASSWORD={CLUSTER_PW}\n")
    creds = ct.credentials_file(str(tmp_path), {})
    base = dict(mesh_running=False, volumes_present=None, seeded_admin=None,
                seeded_operator=None, creds=creds, casdoor_created=None,
                secrets_mtime=None, last_seed_ok=None, lane=ct.LANE_KIND,
                operator_user="mesh-operator", superadmin=("", ""),
                env_password=False, checked_at="now")

    landed = ct.assess(**base, kind=ct.KindIdentities(
        users=frozenset({"e2e-admin", "newbie"}),
        roles=(("ROLE_USER", frozenset({"e2e-admin", "newbie"})),),
        password_matches=True))
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_USER",), CLUSTER_PW)],
                    operator="mesh-operator")
    out = annotate(roster, landed, added=[("newbie", ("ROLE_USER",))])
    assert {u.username: u.live for u in out.users}["newbie"] == ct.ADDED

    gone = ct.assess(**base, kind=ct.KindIdentities(
        users=frozenset({"e2e-admin"}),
        roles=(("ROLE_USER", frozenset({"e2e-admin"})),), password_matches=True))
    out = annotate(roster, gone, added=[("newbie", ("ROLE_USER",))])
    row = {u.username: u for u in out.users}["newbie"]
    assert row.live == ct.NOT_SEEDED
    assert "does not exist in the identity store" in row.note


# ── the lane probe ────────────────────────────────────────────────────────────────

def test_kind_lane_up_is_tri_state_and_asks_by_exact_name():
    seen = []

    def ok(cmd, **kw):
        seen.append(cmd)
        return 0, "hugmesh-local-control-plane\n"

    assert kind_seed.kind_lane_up(runner=ok, cluster="hugmesh-local") is True
    assert "name=^hugmesh-local-control-plane$" in seen[0]
    assert kind_seed.kind_lane_up(runner=lambda c, **k: (0, ""),
                                  cluster="x") is False
    # docker did not answer: NOT "there is no cluster"
    assert kind_seed.kind_lane_up(runner=lambda c, **k: (1, "daemon down"),
                                  cluster="x") is None


def test_the_module_is_qt_free():
    import sys
    import importlib
    importlib.reload(kind_seed)
    assert not any(m.startswith(("PySide6", "PyQt6")) for m in sys.modules
                   if m == "hugmesh_studio.core.kind_seed")
    src = open(kind_seed.__file__, encoding="utf-8").read()
    assert "QtWidgets" not in src and "from ..gui" not in src
