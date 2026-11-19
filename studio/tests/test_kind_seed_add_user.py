"""Add user on the KIND lane, through the kind lane's own seeders (#540).

WHAT THIS IS NOT. It is not a second identity-management system and it is not a
bespoke Casdoor call. The kind lane seeds with ``tests/qemu/seed-accounts.sh --roles``
+ ``roles/apply-systems-roles.sh`` (bootstrap-kind.sh step 10); this verb runs those
two, in that order, so an added account is created by exactly the machinery that
created every other persona and cannot drift from it.

THE THREE THINGS THAT MUST NOT BE GOT WRONG, each pinned below:

1. **Success is READ BACK.** Casdoor answers a DENIED call with HTTP 200 +
   ``{"status":"error"}`` — which is how an earlier seeding run "succeeded" entirely
   unauthenticated. apply-systems-roles.sh checks that envelope itself now, and that
   is still the hook reporting on its own work. The post-condition here is the
   cluster's own Casdoor database (the #539 reader): the account must be THERE, and
   it must hold the roles it was granted. An account in none of its roles signs in on
   the gateway floor and then 403s everywhere, so that is a FAILED add.
2. **The Studio still spawns no ``kubectl port-forward``.** ``core/view_doors`` states
   the rule: hugmesh-view.py owns a session-owner guard and a sweep of its own
   children. So the verb ASKS for the ``casdoor`` door ``make view LANE=kind-svc``
   publishes and REFUSES with that remedy when it is absent — never a fallback into
   starting one.
3. **It never lets the seeder mint a fresh shared password.** seed-accounts.sh mints
   one when it finds none, and apply-systems-roles.sh reconciles EVERY persona to
   whatever it is handed — so a mint would silently rotate the whole roster while
   adding one user. The value comes from the cluster's own ``test-seed-passwords``
   Secret, else the run-state file, else the verb refuses.

Everything runs against a fake at the module's three override points (``runner`` / ``doors`` /
``identities``). NOTHING here touches a cluster: the operator's kind lane may not be
seeded into, so the live add is deliberately unexercised and this file is the whole
proof that exists.
"""
from __future__ import annotations

import base64
import os

import pytest

from hugmesh_studio.core import credentials_truth as ct
from hugmesh_studio.core import kind_seed
from hugmesh_studio.core.seeded_credentials import Roster, SeededUser, annotate

CLUSTER_PW = "cluster-seed-pw-7Kq"
ADMIN_PW = "casdoor-admin-pw-3Zt"
VAULT_TOKEN = "hvs.rootToken"


def _b64(s):
    return base64.b64encode(s.encode()).decode()


class _Fake:
    """A fake kind lane at ``kind_seed``'s subprocess override point.

    Scripted per command shape, and every call is recorded so a test can assert what
    was NOT run (there is no `kubectl port-forward` in here, deliberately: if the verb
    ever grew one, no branch would answer it and the test would see it)."""

    def __init__(self, *, seed_secret=CLUSTER_PW, vault_token=VAULT_TOKEN,
                 admin_pw=ADMIN_PW, render_rc=0, apply_rc=0,
                 apply_out="ok: applied 31 role grant(s)", render_makes_script=True):
        self.seed_secret, self.vault_token, self.admin_pw = (seed_secret, vault_token,
                                                             admin_pw)
        self.render_rc, self.apply_rc, self.apply_out = render_rc, apply_rc, apply_out
        self.render_makes_script = render_makes_script
        self.calls: list[list[str]] = []
        self.envs: list[dict] = []

    def runner(self, cmd, *, env=None, cwd=None, timeout=60):
        self.calls.append(list(cmd))
        self.envs.append(dict(env or {}))
        j = " ".join(cmd)
        if "get" in cmd and "secret" in cmd and kind_seed.SEED_SECRET in cmd:
            if self.seed_secret is None:
                return 1, ("Error from server (NotFound): secrets "
                           '"test-seed-passwords" not found')
            return 0, _b64(self.seed_secret)
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
        if cmd[0] == "bash" and cmd[1].endswith("seed-accounts.sh"):
            if self.render_rc == 0 and self.render_makes_script:
                out = cmd[cmd.index("--roles") + 1]
                os.makedirs(os.path.join(out, "roles"), exist_ok=True)
                with open(os.path.join(out, kind_seed.APPLY_ROLES_REL), "w") as fh:
                    fh.write("#!/usr/bin/env bash\n")
            return self.render_rc, "rendered"
        if cmd[0] == "bash" and cmd[1].endswith("apply-systems-roles.sh"):
            return self.apply_rc, self.apply_out
        return 1, f"unexpected: {j}"

    def door(self, *_a, **_k):
        return {kind_seed.DOOR_NAME: "https://127.0.0.1:9083"}

    def no_door(self, *_a, **_k):
        return {}


def _identities(users=("e2e-admin", "newbie"), roles=None):
    if roles is None:
        roles = (("ROLE_USER", frozenset(users)),)
    return lambda: ct.KindIdentities(users=frozenset(users), roles=tuple(roles))


def _add(tmp_path, fake, *, identities=None, doors=None, username="newbie",
         roles=("ROLE_USER",), password="", password_env="", env=None):
    return kind_seed.add_user_kind(
        generator_dir=str(tmp_path), cluster="hugmesh-local",
        specs=[f"{username}:{','.join(roles)}:E2E_PASSWORD"],
        username=username, roles=roles, password=password,
        password_env=password_env, env=env if env is not None else {},
        runner=fake.runner, doors=doors or fake.door,
        identities=identities or _identities())


# ── the door: asked, never started ────────────────────────────────────────────────

def test_without_the_casdoor_door_it_refuses_and_names_the_remedy(tmp_path):
    f = _Fake()
    out = _add(tmp_path, f, doors=f.no_door)
    assert out.ok is False and out.stage == kind_seed.STAGE_DOOR
    assert "make view LANE=kind-svc" in out.message
    assert "does not start a kubectl port-forward" in out.message
    # and it stopped THERE: nothing was rendered, nothing was applied
    assert f.calls == []


def test_it_never_spawns_a_port_forward_of_its_own(tmp_path):
    """core/view_doors states the rule plainly (hugmesh-view.py owns the session
    guard and sweeps its own children). Every subprocess the happy path runs is
    inspected — none of them is a forwarder."""
    f = _Fake()
    out = _add(tmp_path, f)
    assert out.ok, out.message
    assert not any("port-forward" in " ".join(c) for c in f.calls)


# ── the shared password: the CLUSTER's, never a fresh mint ────────────────────────

def test_the_render_uses_the_password_the_cluster_was_seeded_with(tmp_path):
    f = _Fake(seed_secret=CLUSTER_PW)
    assert _add(tmp_path, f).ok
    render = next(e for c, e in zip(f.calls, f.envs)
                  if c[0] == "bash" and c[1].endswith("seed-accounts.sh"))
    assert render["E2E_PASSWORD"] == CLUSTER_PW


def test_with_no_recorded_password_anywhere_it_refuses_rather_than_rotating_everyone(tmp_path):
    """seed-accounts.sh MINTS when it finds none, and apply-systems-roles.sh
    reconciles EVERY persona to what it is handed — so a mint here would rotate the
    whole roster as a side effect of adding one user."""
    f = _Fake(seed_secret=None)
    out = _add(tmp_path, f, env={})
    assert out.ok is False and out.stage == kind_seed.STAGE_PASSWORD
    assert "MINT" in out.message and "reconcile" in out.message
    assert not any(c[0] == "bash" for c in f.calls), "nothing may be rendered or applied"


def test_it_falls_back_to_the_run_state_file_when_the_secret_is_gone(tmp_path):
    (tmp_path / ".e2e-credentials").write_text(f"E2E_PASSWORD={CLUSTER_PW}\n")
    f = _Fake(seed_secret=None)
    out = _add(tmp_path, f, env={})
    assert out.ok, out.message
    render = next(e for c, e in zip(f.calls, f.envs)
                  if c[0] == "bash" and c[1].endswith("seed-accounts.sh"))
    assert render["E2E_PASSWORD"] == CLUSTER_PW


# ── the Casdoor admin password: read back from Vault, never derived ───────────────

def test_the_admin_password_comes_from_vault_and_reaches_only_the_env(tmp_path):
    f = _Fake()
    assert _add(tmp_path, f).ok
    apply_env = next(e for c, e in zip(f.calls, f.envs)
                     if c[0] == "bash" and c[1].endswith("apply-systems-roles.sh"))
    assert apply_env["CASDOOR_ADMIN_PASS"] == ADMIN_PW
    assert apply_env["CASDOOR_URL"] == "https://127.0.0.1:9083"
    # never argv: no call anywhere carries either secret as an argument
    for c in f.calls:
        assert ADMIN_PW not in " ".join(a for a in c if not a.startswith("VAULT_TOKEN="))
        assert CLUSTER_PW not in " ".join(c)


def test_without_the_admin_password_it_refuses_instead_of_applying_blind(tmp_path):
    f = _Fake(admin_pw=None)
    out = _add(tmp_path, f)
    assert out.ok is False and out.stage == kind_seed.STAGE_ADMIN
    assert "HTTP 200" in out.message          # names WHY applying without checking is dangerous
    assert not any(c[1].endswith("apply-systems-roles.sh")
                   for c in f.calls if c[0] == "bash")


# ── success is read back, never reported ──────────────────────────────────────────

def test_a_denied_seed_that_exits_0_is_reported_as_a_failure(tmp_path):
    """THE ISSUE'S OWN TEST. A fake Casdoor answering `{"status":"error"}` with HTTP
    200 — the shape that let a whole seed run unauthenticated and exit 0 — must not
    become a success. The read-back is what settles it: the account is not there."""
    f = _Fake(apply_rc=0, apply_out='{"status":"error","msg":"the user is not '
                                    'authenticated"}')
    out = _add(tmp_path, f, identities=_identities(users=("e2e-admin",)))
    assert out.ok is False and out.stage == kind_seed.STAGE_READBACK
    assert "NOT in the cluster's identity store" in out.message


def test_the_denied_envelope_check_only_changes_wording_never_the_verdict(tmp_path):
    """Pins the ``applied_ok`` computation itself (#539/#540 follow-up, found during
    landing-time mutation testing): the verdict was already, and remains, decided
    entirely by the read-back — a denied HTTP-200 envelope and a plain exit-0
    success both land on ``ok=False`` here because the read-back does not see the
    account either way. What the envelope check controls is ONLY whether the
    message claims the seeder "exited 0" on a call this Studio knows was denied.
    Without this test nothing pinned that distinction; a mutation that deletes the
    ``'"status":"error"' not in out`` check passed every other test in this file
    unchanged."""
    denied = _Fake(apply_rc=0, apply_out='{"status":"error","msg":"the user is not '
                                         'authenticated"}')
    out_denied = _add(tmp_path, denied, identities=_identities(users=("e2e-admin",)))
    assert out_denied.ok is False
    assert "although apply-systems-roles.sh exited 0" not in out_denied.message

    # A TRUE exit-0 success whose read-back has not caught up yet (eventual
    # consistency, or a spec that renders a different username): still a failed
    # add — the read-back is still the verdict — but now the message may honestly
    # say the seeder itself reported success.
    slow_readback = _Fake(apply_rc=0, apply_out="ok: applied 31 role grant(s)")
    out_slow = _add(tmp_path, slow_readback, identities=_identities(users=("e2e-admin",)))
    assert out_slow.ok is False
    assert "although apply-systems-roles.sh exited 0" in out_slow.message


def test_a_seeder_that_exits_0_without_creating_the_account_is_a_failure(tmp_path):
    f = _Fake(apply_rc=0, apply_out="ok")
    out = _add(tmp_path, f, identities=_identities(users=("e2e-admin",)))
    assert out.ok is False
    assert "although apply-systems-roles.sh exited 0" in out.message


def test_an_account_the_cluster_grants_none_of_its_roles_is_a_failed_add(tmp_path):
    """"A user created with ROLE_MOD on a cluster whose ROLE_MOD has no members
    afterwards is a failed add, not a success." """
    f = _Fake()
    out = _add(tmp_path, f, roles=("ROLE_MOD",),
               identities=_identities(users=("e2e-admin", "newbie"),
                                      roles=(("ROLE_MOD", frozenset()),
                                             ("ROLE_USER", frozenset({"newbie"})))))
    assert out.ok is False and out.stage == kind_seed.STAGE_READBACK
    assert out.missing == ("ROLE_MOD",)
    assert "403s on every page" in out.message


def test_an_unreadable_store_is_never_called_a_success(tmp_path):
    f = _Fake()
    out = _add(tmp_path, f,
               identities=lambda: ct.KindIdentities(reason="the cluster's API did "
                                                           "not answer"))
    assert out.ok is False and out.stage == kind_seed.STAGE_READBACK
    assert "unproven" in out.message
    assert "on the seeder's own word" in out.message


def test_an_unreadable_ROLE_table_lands_but_says_the_roles_are_unverified(tmp_path):
    """The account IS there — that much was read — so this is a success. Its roles
    were not read, so they are said to be unverified rather than asserted."""
    f = _Fake()
    out = _add(tmp_path, f,
               identities=lambda: ct.KindIdentities(
                   users=frozenset({"newbie"}), roles=None, reason="role query failed"))
    assert out.ok is True
    assert "unverified" in out.message


def test_the_happy_path_says_what_the_cluster_grants_not_what_was_asked(tmp_path):
    f = _Fake()
    out = _add(tmp_path, f, roles=("ROLE_USER",))
    assert out.ok and out.stage == kind_seed.STAGE_OK
    assert out.granted == ("ROLE_USER",) and out.missing == ()
    assert "read back from Casdoor's own database" in out.message


# ── the FULL spec list is re-rendered ─────────────────────────────────────────────

def test_every_accumulated_spec_is_rendered_not_just_the_new_one(tmp_path):
    """apply-systems-roles.sh sets each role's members to EXACTLY the rendered list,
    so rendering one user would wipe every other persona's memberships."""
    f = _Fake()
    kind_seed.add_user_kind(
        generator_dir=str(tmp_path), cluster="hugmesh-local",
        specs=["alpha:ROLE_USER:E2E_PASSWORD", "beta:ROLE_MOD:E2E_PASSWORD"],
        username="beta", roles=("ROLE_MOD",), env={},
        runner=f.runner, doors=f.door,
        identities=_identities(users=("beta",),
                               roles=(("ROLE_MOD", frozenset({"beta"})),)))
    render = next(e for c, e in zip(f.calls, f.envs)
                  if c[0] == "bash" and c[1].endswith("seed-accounts.sh"))
    assert render["EXTRA_ROLE_USERS"] == ("alpha:ROLE_USER:E2E_PASSWORD "
                                          "beta:ROLE_MOD:E2E_PASSWORD")


def test_an_explicit_password_travels_in_its_own_env_var_only(tmp_path):
    f = _Fake()
    out = _add(tmp_path, f, password="chosen-pw-1", password_env="STUDIO_USER_NEWBIE_PASSWORD")
    assert out.ok, out.message
    for which in ("seed-accounts.sh", "apply-systems-roles.sh"):
        e = next(env for c, env in zip(f.calls, f.envs)
                 if c[0] == "bash" and c[1].endswith(which))
        assert e["STUDIO_USER_NEWBIE_PASSWORD"] == "chosen-pw-1"
    for c in f.calls:
        assert "chosen-pw-1" not in " ".join(c)


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
