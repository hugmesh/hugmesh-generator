"""The kind lane is ASKED, not assumed (#539).

THE REPORT. "can't log into kind mesh e2e users as password doesn't match what's in
the sign-in credentials." The password was not wrong — the accounts did not exist.
``bootstrap-kind.sh`` seeds identities at step 10, immediately after
``wait_job hugmesh-pki casdoor-init``; that wait failed during the #396 sign-in
lockout, so the bootstrap exited BEFORE seeding while ArgoCD carried on converging,
leaving a healthy, serving mesh with an empty identity store. Measured on the
reference cluster the same day:

    $ kubectl -n hugmesh-pki exec deploy/casdoor-pg -- psql -U casdoor -d casdoor \
        -Atc 'select owner, name from "user" order by owner, name'
    built-in|admin
    hugmesh|superadmin
    hugmesh|svc-admin-bff … svc-signup-gate

Eight accounts, not one persona. The table showed the CHECKOUT's roster with a real
password, because ``credentials_truth`` declared the kind lane "unknown BY
CONSTRUCTION" — on the premise that its ClusterIP Casdoor could not be reached. Its
DATABASE is a pod, and a pod can be read, so the premise was false.

WHAT THESE TESTS PIN.

* the three unreadable-vs-empty cases stay apart, because their fixes differ:
  "this mesh has no identities seeded" (re-run the seed) vs "this Studio cannot tell"
  (fix the probe's access) vs the HALTED lane (resume it);
* an EMPTY user list shows ``not seeded`` rows, never a usable-looking one — the
  exact state that produced the report;
* every gather failure downgrades ONE fact to unknown and never to "no";
* ``kubectl exec`` is never issued at a Deployment with no ready replica. That is not
  tidiness: measured on the halted reference cluster, ``kubectl exec deploy/casdoor-pg``
  does not fail there, it BLOCKS until its own timeout (40s, killed, no diagnostic),
  so an unguarded probe hangs the GUI's worker thread.

Pure-core: no Qt, no cluster. The cluster is a fake at ``node._probe``, which is the
same override point the compose path's tests use.
"""
from __future__ import annotations

import os

from hugmesh_studio.core import credentials_truth as ct
from hugmesh_studio.core.seeded_credentials import (Roster, SeededUser, annotate,
                                                    suggested_signin)

FIXTURE_PW = "fixture-pw-9Xq7wLm2"

# The eight rows the reference cluster really answered with, verbatim.
REAL_UNSEEDED_ROWS = "\n".join([
    "built-in|admin",
    "hugmesh|superadmin",
    "hugmesh|svc-admin-bff",
    "hugmesh|svc-api",
    "hugmesh|svc-be-gateway",
    "hugmesh|svc-fe-gateway",
    "hugmesh|svc-pki-gateway",
    "hugmesh|svc-signup-gate",
]) + "\n"


def _file(tmp_path, pw=FIXTURE_PW):
    (tmp_path / ".e2e-credentials").write_text(f"E2E_PASSWORD={pw}\n")
    return ct.credentials_file(str(tmp_path), {})


def _facts(tmp_path, **over):
    base = dict(mesh_running=False, volumes_present=None, seeded_admin=None,
                seeded_operator=None, creds=_file(tmp_path), casdoor_created=None,
                secrets_mtime=None, last_seed_ok=None, lane=ct.LANE_KIND,
                operator_user="mesh-operator", superadmin=("", ""),
                env_password=False, checked_at="now")
    base.update(over)
    return base


class _Cluster:
    """A fake kind cluster at ``node._probe``.

    ``users``/``roles`` are the raw psql stdout to hand back (None = that call
    fails). ``ready`` is ``.status.readyReplicas``; "" is what a halted Deployment
    prints. Every call is recorded so a test can assert what was NOT asked."""

    def __init__(self, *, ready="1", users=REAL_UNSEEDED_ROWS, roles="",
                 secret=None, ready_rc=0, users_rc=0, roles_rc=0, secret_rc=0):
        self.ready, self.users, self.roles, self.secret = ready, users, roles, secret
        self.ready_rc, self.users_rc = ready_rc, users_rc
        self.roles_rc, self.secret_rc = roles_rc, secret_rc
        self.calls: list[list[str]] = []

    def _probe(self, cmd, timeout=15):
        self.calls.append(list(cmd))
        joined = " ".join(cmd)
        if "get deploy" in joined or ("get" in cmd and "deploy" in cmd):
            return self.ready_rc, self.ready
        if "get" in cmd and "secret" in cmd:
            return self.secret_rc, (self.secret if self.secret is not None else "")
        if "configmap" in cmd:
            return 1, "Error from server (NotFound): configmaps not found"
        if "exec" in cmd:
            sql = cmd[-1]
            if sql == ct.KIND_USERS_SQL:
                return self.users_rc, (self.users if self.users is not None else "")
            if sql == ct.KIND_ROLES_SQL:
                return self.roles_rc, (self.roles if self.roles is not None else "")
        return 1, f"unexpected: {joined}"

    def execs(self):
        return [c for c in self.calls if "exec" in c]


def _gather(tmp_path, cluster, pw=FIXTURE_PW):
    return ct.gather_kind_identities(cluster, str(tmp_path), "hugmesh-local",
                                     shared_password=pw)


# ── the pure parsers ──────────────────────────────────────────────────────────────

def test_parse_users_reads_the_real_answer_and_an_empty_one():
    got = ct.parse_psql_users(REAL_UNSEEDED_ROWS)
    assert got == frozenset({"admin", "superadmin", "svc-admin-bff", "svc-api",
                             "svc-be-gateway", "svc-fe-gateway", "svc-pki-gateway",
                             "svc-signup-gate"})
    assert "e2e-admin" not in got
    # NO rows is a real answer — an identity store with nothing in it.
    assert ct.parse_psql_users("") == frozenset()
    assert ct.parse_psql_users("\n \n") == frozenset()


def test_parse_users_refuses_to_turn_an_error_page_into_zero_users():
    """The false negative this module forbids. psql prints prose on failure; reading
    it as 'no rows' would report an unseeded mesh for a broken read."""
    for junk in ('ERROR:  relation "user" does not exist',
                 "psql: error: connection to server failed",
                 "Error from server (NotFound): deployments.apps not found"):
        assert ct.parse_psql_users(junk) is None
    assert ct.parse_psql_users("hugmesh|") is None      # a row with no username


def test_parse_roles_strips_the_owner_prefix_and_voids_on_one_bad_row():
    got = ct.parse_psql_roles('ROLE_ADMIN|["hugmesh/e2e-admin", "hugmesh/x"]\n'
                              'ROLE_MOD|[]\n'
                              'ROLE_USER|\n')
    assert dict(got) == {"ROLE_ADMIN": frozenset({"e2e-admin", "x"}),
                         "ROLE_MOD": frozenset(),
                         "ROLE_USER": frozenset()}
    # ONE unparseable row voids the whole answer: a partial role table would mark a
    # persona "no roles" on the strength of a row that was never read.
    assert ct.parse_psql_roles('ROLE_ADMIN|["hugmesh/a"]\nROLE_MOD|{not json\n') is None
    assert ct.parse_psql_roles('ROLE_ADMIN|["hugmesh/a"]\nbare line\n') is None
    assert ct.parse_psql_roles('ROLE_ADMIN|{"a": 1}') is None


# ── the gatherer, against a fake cluster ──────────────────────────────────────────

def test_a_halted_lane_is_never_given_an_exec_that_would_hang(tmp_path):
    """MEASURED, not theoretical: `kubectl exec deploy/<x>` on a Deployment scaled to
    0 blocks until its own timeout waiting for a pod instead of erroring. The
    gatherer reads readyReplicas first and stops there."""
    c = _Cluster(ready="")                     # what a scaled-to-0 Deployment prints
    k = _gather(tmp_path, c)
    assert k.users is None and k.roles is None
    assert "no ready replica" in k.reason
    assert c.execs() == [], "an exec was issued at a Deployment with no pod"


def test_a_halted_lane_is_unknown_and_the_banner_names_the_halt(tmp_path):
    k = ct.KindIdentities(reason="casdoor-pg has no ready replica", halted=True)
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_UNKNOWN
    assert t.marker == ct.UNKNOWN
    assert t.present_users is None
    assert "HALTED" in t.detail and "kind-resume" in t.detail
    # and it still refuses to be read as an absence
    assert "is NOT 'nobody is seeded'" in t.headline


def test_the_reference_cluster_reads_as_not_seeded_with_its_real_roster(tmp_path):
    c = _Cluster(users=REAL_UNSEEDED_ROWS)
    k = _gather(tmp_path, c)
    assert k.users is not None and len(k.users) == 8
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_UP_UNSEEDED
    assert t.marker == ct.NOT_SEEDED
    assert "NO identities seeded" in t.headline
    assert "8 account(s)" in t.headline
    # the fix named is the seed, not a password reset — that was the operator's
    # wrong turn, and it came from this surface
    assert "re-run the identity seed" in t.detail.lower()
    assert "password reset" in t.detail


def test_an_empty_user_list_shows_not_seeded_rows_not_usable_looking_ones(tmp_path):
    """THE ISSUE'S OWN TEST: a fake cluster returning an EMPTY user list must put
    `not seeded` in the table, never a row an operator would try."""
    c = _Cluster(users="")
    k = _gather(tmp_path, c)
    assert k.users == frozenset()
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_UP_UNSEEDED
    assert t.present_users == frozenset()

    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN",), FIXTURE_PW),
                           SeededUser("e2e-user", ("ROLE_USER",), FIXTURE_PW),
                           SeededUser("mesh-operator", ("ROLE_ADMIN",), FIXTURE_PW)],
                    operator="mesh-operator")
    out = annotate(roster, t)
    assert [u.live for u in out.users] == [ct.NOT_SEEDED, ct.NOT_SEEDED,
                                           ct.NOT_ON_LANE]
    assert all(u.live != ct.LIVE for u in out.users)
    # The marker has to come from THIS ROW's absence from the store, not from the
    # lane-wide default happening to agree with it: only the per-row join writes
    # this note, so it is what distinguishes the two.
    assert all("does not exist in the identity store" in u.note
               for u in out.users if u.live == ct.NOT_SEEDED)
    # and nothing is offered as the lead
    assert suggested_signin(out) is None
    assert t.verified is False


def test_a_read_that_failed_marks_unknown_and_keeps_every_password(tmp_path):
    """One failed fact downgrades to unknown, NEVER to "no". A cluster whose API did
    not answer is not an unseeded cluster, and the rows must keep their values."""
    c = _Cluster(ready_rc=1, ready="Unable to connect to the server: EOF")
    k = _gather(tmp_path, c)
    assert k.users is None
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_UNKNOWN and t.marker == ct.UNKNOWN
    assert t.present_users is None
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN",), FIXTURE_PW)],
                    operator="mesh-operator")
    out = annotate(roster, t)
    assert out.users[0].live == ct.UNKNOWN
    assert out.users[0].password == FIXTURE_PW        # not blanked, not "(not seeded)"
    assert "not seeded" not in out.users[0].live


def test_psql_prose_is_unknown_not_an_empty_store(tmp_path):
    c = _Cluster(users='ERROR:  relation "user" does not exist')
    k = _gather(tmp_path, c)
    assert k.users is None
    assert "not a row set" in k.reason
    assert ct.assess(**_facts(tmp_path, kind=k)).state == ct.STATE_UNKNOWN


def test_a_missing_casdoor_pg_says_so_rather_than_blaming_the_seed(tmp_path):
    c = _Cluster(ready_rc=1,
                 ready="Error from server (NotFound): deployments.apps "
                       '"casdoor-pg" not found')
    k = _gather(tmp_path, c)
    assert k.users is None
    assert "no casdoor-pg Deployment" in k.reason


# ── seeded clusters, and the password corroboration ───────────────────────────────

def _seeded(users=("e2e-admin", "e2e-user"), roles=None, **kw):
    rows = "".join(f"hugmesh|{u}\n" for u in users)
    if roles is None:
        roles = "".join(
            'ROLE_%s|["%s"]\n' % (u.split("-")[-1].upper(), f"hugmesh/{u}")
            for u in users)
    return _Cluster(users=rows, roles=roles, **kw)


def _b64(s):
    import base64
    return base64.b64encode(s.encode()).decode()


def test_a_matching_seed_secret_is_the_only_route_to_seeded(tmp_path):
    c = _seeded(secret=_b64(FIXTURE_PW))
    k = _gather(tmp_path, c)
    assert k.password_matches is True
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_SEEDED and t.marker == ct.LIVE and t.verified


def test_a_different_seed_secret_is_seeded_suspect_not_seeded(tmp_path):
    c = _seeded(secret=_b64("something-else"))
    k = _gather(tmp_path, c)
    assert k.password_matches is False
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_SEEDED_SUSPECT and t.marker == ct.STALE
    assert t.verified is False


def test_an_absent_seed_secret_leaves_the_password_unverified_not_wrong(tmp_path):
    """The Secret is absent on the reference cluster. Absence says nothing about the
    value — it is unverified, never "stale", which would be a claim."""
    c = _seeded(secret_rc=1, secret="Error from server (NotFound): secrets "
                                    '"test-seed-passwords" not found')
    k = _gather(tmp_path, c)
    assert k.password_matches is None
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.state == ct.STATE_UNKNOWN and t.marker == ct.UNVERIFIED
    assert t.present_users and "e2e-admin" in t.present_users
    assert "401" not in t.headline and "wrong" not in t.headline.lower()


def test_the_seed_secrets_value_never_reaches_the_answer(tmp_path):
    """Only the boolean leaves the gatherer. The Secret is compared and dropped."""
    secret_value = "kind-secret-value-do-not-leak"
    c = _seeded(secret=_b64(secret_value))
    k = _gather(tmp_path, c)
    t = ct.assess(**_facts(tmp_path, kind=k))
    blob = repr(k) + t.headline + t.detail + repr(t)
    assert secret_value not in blob
    assert FIXTURE_PW not in t.headline + t.detail


# ── the empty-role case ───────────────────────────────────────────────────────────

def test_a_user_that_exists_in_no_role_is_not_a_working_sign_in(tmp_path):
    """The reference cluster's 28 roles all had `users` == []. An account in none of
    its own roles authenticates on the gateway floor and then 403s on every page,
    which an operator reads as a wrong password."""
    c = _seeded(users=("e2e-admin",),
                roles='ROLE_ADMIN|[]\nROLE_USER|[]\n',
                secret=_b64(FIXTURE_PW))
    k = _gather(tmp_path, c)
    assert dict(k.roles) == {"ROLE_ADMIN": frozenset(), "ROLE_USER": frozenset()}
    t = ct.assess(**_facts(tmp_path, kind=k))
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN",), FIXTURE_PW)],
                    operator="mesh-operator")
    out = annotate(roster, t)
    assert out.users[0].live == ct.NO_ROLES
    assert suggested_signin(out) is None


def test_no_roles_is_never_claimed_from_a_role_table_that_was_not_read(tmp_path):
    """If the role query failed, ``roles`` is None and NO row may be marked "no
    roles" — the absence of a read is not the absence of a membership."""
    c = _seeded(users=("e2e-admin",), roles_rc=1, roles="connection refused",
                secret=_b64(FIXTURE_PW))
    k = _gather(tmp_path, c)
    assert k.users == frozenset({"e2e-admin"}) and k.roles is None
    t = ct.assess(**_facts(tmp_path, kind=k))
    assert t.holds_any_role("e2e-admin", ("ROLE_ADMIN",)) is None
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN",), FIXTURE_PW)],
                    operator="mesh-operator")
    out = annotate(roster, t)
    assert out.users[0].live == ct.LIVE
    assert "role table could not be read" in t.detail


def test_a_present_user_in_one_of_its_roles_is_live(tmp_path):
    c = _seeded(users=("e2e-admin",),
                roles='ROLE_ADMIN|["hugmesh/e2e-admin"]\nROLE_MATRIX|[]\n',
                secret=_b64(FIXTURE_PW))
    k = _gather(tmp_path, c)
    t = ct.assess(**_facts(tmp_path, kind=k))
    # holds ROLE_ADMIN but not ROLE_MATRIX: ANY of its own roles is enough to be a
    # working sign-in — which app it opens is the Opens column's job, not this one.
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN", "ROLE_MATRIX"),
                                      FIXTURE_PW)], operator="mesh-operator")
    out = annotate(roster, t)
    assert out.users[0].live == ct.LIVE


# ── the roster shown is the MESH's, not the checkout's ────────────────────────────

def test_a_persona_the_cluster_lacks_is_marked_not_seeded_row_by_row(tmp_path):
    """The heart of #539: the roster is the checkout's list, the MARKERS are the
    cluster's. A half-seeded cluster must show exactly which half."""
    c = _seeded(users=("e2e-admin",),
                roles='ROLE_ADMIN|["hugmesh/e2e-admin"]\n',
                secret=_b64(FIXTURE_PW))
    t = ct.assess(**_facts(tmp_path, kind=_gather(tmp_path, c)))
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN",), FIXTURE_PW),
                           SeededUser("e2e-fleet", ("ROLE_FLEET_ADMIN",), FIXTURE_PW)],
                    operator="mesh-operator")
    out = annotate(roster, t)
    marks = {u.username: u.live for u in out.users}
    assert marks == {"e2e-admin": ct.LIVE, "e2e-fleet": ct.NOT_SEEDED}
    gone = next(u for u in out.users if u.username == "e2e-fleet")
    assert "does not exist in the identity store" in gone.note
    assert suggested_signin(out).username == "e2e-admin"


def test_the_operator_row_is_not_on_this_lane_but_never_contradicts_the_cluster(tmp_path):
    """bootstrap-kind.sh never runs seed-e2e.sh, so mesh-operator is not created on
    this lane — stated as a fact only while the running store does not contradict it."""
    absent = ct.assess(**_facts(tmp_path, kind=_gather(
        tmp_path, _seeded(users=("e2e-admin",), secret=_b64(FIXTURE_PW)))))
    roster = Roster(users=[SeededUser("mesh-operator", ("ROLE_ADMIN",), FIXTURE_PW)],
                    operator="mesh-operator")
    assert annotate(roster, absent).users[0].live == ct.NOT_ON_LANE

    present = ct.assess(**_facts(tmp_path, kind=_gather(
        tmp_path, _seeded(users=("e2e-admin", "mesh-operator"),
                          roles='ROLE_ADMIN|["hugmesh/mesh-operator"]\n',
                          secret=_b64(FIXTURE_PW)))))
    out = annotate(roster, present)
    assert out.users[0].live != ct.NOT_ON_LANE, \
        "the cluster holds the account; 'not on this lane' would be a lie"


# ── the banner distinguishes the two diagnoses ────────────────────────────────────

def test_cannot_tell_and_nothing_seeded_are_different_sentences(tmp_path):
    """They have different fixes — fix the probe's access, versus re-run the seed —
    so they may never render as the same banner."""
    cant = ct.assess(**_facts(tmp_path, kind=ct.KindIdentities(
        reason="kubectl is not installed")))
    none = ct.assess(**_facts(tmp_path, kind=_gather(tmp_path, _Cluster(users=""))))
    assert cant.state == ct.STATE_UNKNOWN and none.state == ct.STATE_UP_UNSEEDED
    assert cant.headline != none.headline
    assert "could not read" in cant.headline
    assert "kubectl is not installed" in cant.detail
    assert "NO identities seeded" in none.headline


def test_no_password_ever_reaches_a_kind_headline_or_detail(tmp_path):
    for k in (ct.KindIdentities(reason="x"),
              _gather(tmp_path, _Cluster(users="")),
              _gather(tmp_path, _seeded(secret=_b64(FIXTURE_PW))),
              _gather(tmp_path, _seeded(secret=_b64("other")))):
        t = ct.assess(**_facts(tmp_path, kind=k))
        assert FIXTURE_PW not in t.headline + t.detail


# ── the wiring ────────────────────────────────────────────────────────────────────

def test_probe_credentials_reads_the_kind_store_when_that_is_the_lane(tmp_path):
    """The end-to-end override point: compose down + a kind control-plane container means the
    kind lane, and the kind lane now gets ASKED."""
    (tmp_path / ".e2e-credentials").write_text(f"E2E_PASSWORD={FIXTURE_PW}\n")

    class _Node(_Cluster):
        def status(self):
            from types import SimpleNamespace
            return SimpleNamespace(running=False, detail="0")

        def _probe(self, cmd, timeout=15):
            if cmd[:2] == ["docker", "ps"]:
                self.calls.append(list(cmd))
                return 0, "hugmesh-local-control-plane\n"
            if cmd[:3] == ["docker", "volume", "ls"]:
                return 0, ""
            return super()._probe(cmd, timeout)

    class _Boot:
        secrets_json = "/nonexistent/secrets.json"

        def superadmin_login(self):
            return ("", "")

    node = _Node(users=REAL_UNSEEDED_ROWS)
    t = ct.probe_credentials(str(tmp_path), {}, node, _Boot(),
                             operator_user="mesh-operator",
                             logs_dir=str(tmp_path / "no-logs"))
    assert t.lane == ct.LANE_KIND
    assert t.state == ct.STATE_UP_UNSEEDED
    assert t.present_users is not None and "e2e-admin" not in t.present_users
    # the users query it ran is the ISSUE'S OWN statement, verbatim
    assert any(c[-1] == ct.KIND_USERS_SQL for c in node.calls if "exec" in c)
