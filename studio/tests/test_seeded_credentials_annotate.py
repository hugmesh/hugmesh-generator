"""seeded_credentials.annotate — joining the live-mesh assessment INTO the parsed roster.

The parser says who a seed WOULD create; credentials_truth says what the running mesh
holds. ``annotate`` is where the two meet, and these pin its four promises: the
superadmin row becomes the MINTED one in place (never a duplicate), mesh-operator is
marked absent on a lane that does not seed it, an absent everything still shows the
not-seeded marker the dialog test at test_local_mesh.py pins, and the new SeededUser
fields are keyword additions that break no existing construction.
"""
from __future__ import annotations

import os

from hugmesh_studio.core import credentials_truth as ct
from hugmesh_studio.core.seeded_credentials import (
    _NOT_SEEDED, Roster, SeededUser, annotate, as_copyable_text, load_roster,
    suggested_signin)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

FIXTURE_PW = "fixture-pw-annotate-3Fq"


def _creds(tmp_path, exists=True):
    if exists:
        p = tmp_path / ".e2e-credentials"
        p.write_text("E2E_PASSWORD=" + FIXTURE_PW + "\n")
        os.utime(p, (2.5, 2.5))       # written BEFORE the seed _truth() records (3.0)
    return ct.credentials_file(str(tmp_path), {})


def _truth(tmp_path, **over):
    base = dict(mesh_running=True, volumes_present=True, seeded_admin=True,
                seeded_operator=True, creds=_creds(tmp_path), casdoor_created=1.0,
                secrets_mtime=2.0, last_seed_ok=3.0, lane=ct.LANE_COMPOSE,
                operator_user="mesh-operator",
                superadmin=("minted-admin", FIXTURE_PW + "-sa"))
    base.update(over)
    return ct.assess(**base)


def _roster(tmp_path):
    return load_roster(GENERATOR_DIR, {"E2E_CREDENTIALS_FILE": str(tmp_path / ".e2e-credentials")})


def test_superadmin_row_uses_the_minted_secrets_json_values_without_duplicating(tmp_path):
    roster = _roster(tmp_path)
    before = [u.username for u in roster.users]
    assert "e2e-superadmin" in before                 # the script's default row
    idx = before.index("e2e-superadmin")

    out = annotate(roster, _truth(tmp_path))
    names = [u.username for u in out.users]
    assert len(names) == len(before)                  # in place: no extra row
    assert "e2e-superadmin" not in names
    assert names[idx] == "minted-admin"
    row = out.users[idx]
    assert row.password == FIXTURE_PW + "-sa"
    assert "ROLE_SUPERADMIN" in row.roles
    assert row.live == ct.LIVE
    assert "secrets.json" in row.note
    assert out.truth is not None and out.truth.state == ct.STATE_SEEDED
    # the input roster is untouched
    assert [u.username for u in roster.users] == before


def test_superadmin_row_falls_back_to_the_script_row_when_no_bundle_is_readable(tmp_path):
    out = annotate(_roster(tmp_path), _truth(tmp_path, superadmin=("", "")))
    row = next(u for u in out.users if u.username == "e2e-superadmin")
    assert "no minted bundle" in row.note.lower()
    assert sum(1 for u in out.users if "ROLE_SUPERADMIN" in u.roles
               and u.password_env == "E2E_SUPERADMIN_PASSWORD") == 1


def test_minted_but_unseeded_superadmin_is_marked_not_seeded(tmp_path):
    out = annotate(_roster(tmp_path),
                   _truth(tmp_path, mesh_running=False, volumes_present=False,
                          seeded_admin=None, seeded_operator=None,
                          secrets_mtime=5.0, last_seed_ok=3.0))
    assert out.truth.state == ct.STATE_MINTED_NOT_SEEDED
    row = next(u for u in out.users if u.username == "minted-admin")
    assert row.live == ct.NOT_SEEDED
    assert "not proven seeded" in row.note.lower()


def test_superadmin_minted_before_a_recreated_store_is_unverified_not_seeded(tmp_path):
    """Mint 2.0, recorded seed 3.0, but the store that exists was created at 4.0 by a
    run the Studio never recorded: the minted row is unverified, never live, and its
    note says the current store is not proven to hold it."""
    out = annotate(_roster(tmp_path), _truth(tmp_path, casdoor_created=4.0))
    assert out.truth.state == ct.STATE_UNKNOWN
    assert out.truth.superadmin_seeded is None
    row = next(u for u in out.users if u.username == "minted-admin")
    assert row.live == ct.UNVERIFIED
    assert "not proven seeded" in row.note.lower()
    assert "current identity store" in row.note
    assert suggested_signin(out) is not None          # unverified is not "no"


def test_mesh_operator_marked_not_on_this_lane_for_kind(tmp_path):
    out = annotate(_roster(tmp_path), _truth(tmp_path, lane=ct.LANE_KIND))
    op = next(u for u in out.users if u.username == "mesh-operator")
    assert op.live == ct.NOT_ON_LANE
    assert "kind" in op.note.lower()
    # every other persona is UNKNOWN there — never asserted either way
    others = [u for u in out.users if u.username not in ("mesh-operator", "minted-admin")]
    assert others and all(u.live == ct.UNKNOWN for u in others)
    # and the lead never lands on the operator the lane cannot have
    lead = suggested_signin(out)
    assert lead is not None and lead.username != "mesh-operator"


def test_mesh_operator_marked_not_on_this_lane_when_stage2_did_not_run(tmp_path):
    out = annotate(_roster(tmp_path), _truth(tmp_path, seeded_operator=False))
    op = next(u for u in out.users if u.username == "mesh-operator")
    assert op.live == ct.NOT_ON_LANE
    assert "SEED_COMPLETE_REGISTRATION" in op.note
    assert next(u for u in out.users if u.username == "e2e-admin").live == ct.LIVE
    assert suggested_signin(out).username == "e2e-admin"


def test_absent_everything_still_shows_the_not_seeded_marker(tmp_path):
    """Keeps the contract test_local_mesh.py pins: with no env, no file and no mesh,
    the password cell is the not-seeded marker, never a plausible value."""
    roster = load_roster(GENERATOR_DIR, {"E2E_CREDENTIALS_FILE": str(tmp_path / "absent")})
    out = annotate(roster, _truth(tmp_path, mesh_running=False, volumes_present=False,
                                  seeded_admin=None, seeded_operator=None,
                                  creds=_creds(tmp_path, exists=False),
                                  secrets_mtime=None, superadmin=("", "")))
    assert out.truth.state == ct.STATE_NO_MESH
    admin = next(u for u in out.users if u.username == "e2e-admin")
    assert admin.password == _NOT_SEEDED
    assert admin.live == ct.NOT_SEEDED
    # an unannotated roster keeps the marker too (the legacy path)
    assert next(u for u in roster.users if u.username == "e2e-admin").password == _NOT_SEEDED


def _unreadable(tmp_path):
    return ct.CredentialsFile(path=str(tmp_path / ".e2e-credentials"), exists=True,
                              readable=False, mtime=1.0,
                              error="PermissionError: Permission denied", keys=())


def test_unreadable_file_replaces_the_password_cell_not_the_not_seeded_marker(tmp_path):
    out = annotate(_roster(tmp_path), _truth(tmp_path, creds=_unreadable(tmp_path)))
    assert out.truth.state == ct.STATE_UNREADABLE
    admin = next(u for u in out.users if u.username == "e2e-admin")
    assert admin.password == ct.UNREADABLE_MARKER
    assert admin.password != _NOT_SEEDED


def test_unreadable_file_reaches_the_operator_row_the_dialog_bolds(tmp_path):
    """The operator resolves through the SAME shared E2E_PASSWORD chain, so a file
    that cannot be read cannot supply its password either. It escaped the marker
    once (its branch `continue`d past the substitution), leaving the one row the
    dialog BOLDS carrying "(not seeded — run `make stack-seed`)" on a mesh that is
    seeded — false, and the wrong remedy: e2e-password.sh's e2e_password_ensure
    reuses the file's value whenever the file exists, so stack-seed dies on the same
    permission problem. The banner's `sudo chown` is the fix, and the banner says so.
    """
    out = annotate(_roster(tmp_path), _truth(tmp_path, creds=_unreadable(tmp_path)))
    op = next(u for u in out.users if u.username == out.operator)
    assert op.password == ct.UNREADABLE_MARKER
    # …and the seeder's script-default superadmin, when no bundle was minted.
    out2 = annotate(_roster(tmp_path),
                    _truth(tmp_path, creds=_unreadable(tmp_path), superadmin=("", "")))
    sa = next(u for u in out2.users if "ROLE_SUPERADMIN" in u.roles)
    assert sa.password == ct.UNREADABLE_MARKER
    # The mutation-proof form: NO row anywhere may still carry the false marker,
    # whichever personas the seeder grows next.
    for r in (out, out2):
        assert [u.username for u in r.users if u.password == _NOT_SEEDED] == []


def test_the_minted_superadmin_keeps_its_value_when_the_file_is_unreadable(tmp_path):
    """The one exemption: the minted value comes from keys-out/vault/secrets.json,
    about which the run-state file's permissions say nothing."""
    out = annotate(_roster(tmp_path), _truth(tmp_path, creds=_unreadable(tmp_path)))
    row = next(u for u in out.users if u.username == "minted-admin")
    assert row.password == FIXTURE_PW + "-sa"


def test_added_users_render_without_a_password(tmp_path):
    out = annotate(_roster(tmp_path), _truth(tmp_path),
                   added=(("alice", ("ROLE_USER", "ROLE_FORUM")),))
    row = next(u for u in out.users if u.username == "alice")
    assert row.password == ct.ADDED_MARKER
    assert row.live == ct.ADDED and row.roles == ("ROLE_USER", "ROLE_FORUM")
    # a truth-less annotate (probe failed) still lists them
    out2 = annotate(_roster(tmp_path), None, added=(("bob", ("ROLE_USER",)),))
    assert next(u for u in out2.users if u.username == "bob").live == ct.ADDED
    assert out2.truth is None


def test_seeded_user_new_fields_are_keyword_only_additions():
    # the three-positional construction the existing tests use still works …
    u = SeededUser("e2e-admin", ("ROLE_ADMIN",), "hunter2")
    assert (u.live, u.note) == ("", "")
    # … and the new fields are the LAST two, so no positional caller shifts
    names = list(SeededUser.__dataclass_fields__)
    assert names[-2:] == ["live", "note"]
    assert Roster().truth is None


def test_the_lead_is_never_a_row_the_assessment_says_is_not_there(tmp_path):
    """suggested_signin filters out NOT_ON_LANE / NOT_SEEDED rows so the dialog never
    features an account that is guaranteed to 401 — but its last-resort fallback used
    to return roster.users[0], i.e. reach back OUTSIDE that filter. Reachable whenever
    none of (operator, e2e-admin, e2e-superadmin, e2e-user) survives it."""
    r = Roster(users=[SeededUser("e2e-gone", ("ROLE_USER",), "p", live=ct.NOT_SEEDED),
                      SeededUser("e2e-off-lane", ("ROLE_USER",), "p",
                                 live=ct.NOT_ON_LANE),
                      SeededUser("e2e-forum", ("ROLE_FORUM",), "p", live=ct.LIVE)],
               operator="mesh-operator")
    lead = suggested_signin(r)
    assert lead is not None
    assert lead.username == "e2e-forum"
    assert lead.live not in (ct.NOT_SEEDED, ct.NOT_ON_LANE)
    # …and when EVERY row is absent there is NO lead (#539). This used to fall back
    # to roster.users[0] — reaching back outside the filter it had just applied — on
    # the reasoning that the dialog needs something to feature. It does not: on a kind
    # mesh whose identity seed never ran, every row is absent, and "Start with
    # <persona> / <password>" for an account that does not exist is the exact untruth
    # this module was written to delete. The dialog's no-lead branch already says
    # "none of them can sign in anywhere right now" instead.
    allgone = Roster(users=[SeededUser("a", (), "p", live=ct.NOT_SEEDED)])
    assert suggested_signin(allgone) is None
    # A row that EXISTS but holds none of its roles is not a lead either (#539): it
    # signs in on the gateway floor and then 403s on every page.
    noroles = Roster(users=[SeededUser("a", ("ROLE_ADMIN",), "p", live=ct.NO_ROLES)])
    assert suggested_signin(noroles) is None
    # An UNASSESSED roster still leads with its first entry: nothing has claimed
    # anything about those rows, and that lead vouches for nothing (the dialog only
    # renders it when truth.verified anyway).
    unassessed = Roster(users=[SeededUser("a", (), "p")])
    assert suggested_signin(unassessed).username == "a"


def test_copy_all_carries_the_liveness_it_is_copying(tmp_path):
    """The paste OUTLIVES the banner that qualified it. In seeded-suspect the banner
    says sign-in will 401 for every account until it is re-seeded; a payload that
    listed those passwords bare would re-assert as fact exactly what the dialog above
    it denies — the untruth this whole lane exists to delete."""
    suspect = _truth(tmp_path, creds=_creds(tmp_path), last_seed_ok=2.0)
    assert suspect.state == ct.STATE_SEEDED_SUSPECT
    text = as_copyable_text(annotate(_roster(tmp_path), suspect))
    assert suspect.headline in text
    header = next(ln for ln in text.splitlines() if ln.startswith("# username"))
    assert header == "# username\tpassword\tlive\troles"
    admin = next(ln for ln in text.splitlines() if ln.startswith("e2e-admin\t"))
    assert f"\t{ct.STALE}\t" in admin
    # header lines still carry no value (the headline is asserted password-free)
    for ln in text.splitlines():
        if ln.startswith("#"):
            assert FIXTURE_PW not in ln
    # an UNannotated roster is unchanged — no live column invented out of nothing
    plain = as_copyable_text(_roster(tmp_path))
    assert plain.splitlines()[1] == "# username\tpassword\troles"


def test_with_no_mesh_the_operator_row_is_not_seeded_like_every_other_row(tmp_path):
    """No mesh, no lane: "not on this lane" claimed a lane existed and its seeder
    left mesh-operator out, beside thirty rows saying "not seeded". The same
    holds for a stack that is up but unseeded."""
    roster = load_roster(GENERATOR_DIR, {"E2E_CREDENTIALS_FILE": str(tmp_path / "absent")})
    no_mesh = _truth(tmp_path, mesh_running=False, volumes_present=False,
                     seeded_admin=None, seeded_operator=None,
                     creds=_creds(tmp_path, exists=False),
                     secrets_mtime=None, superadmin=("", ""))
    assert no_mesh.state == ct.STATE_NO_MESH and no_mesh.marker == ct.NOT_SEEDED
    op = next(u for u in annotate(roster, no_mesh).users if u.username == "mesh-operator")
    assert op.live == ct.NOT_SEEDED
    assert "SEED_COMPLETE_REGISTRATION" in op.note
    unseeded = _truth(tmp_path, seeded_admin=False, seeded_operator=False)
    assert unseeded.state == ct.STATE_UP_UNSEEDED
    op = next(u for u in annotate(roster, unseeded).users if u.username == "mesh-operator")
    assert op.live == ct.NOT_SEEDED
    # the kind lane keeps its own answer: never created there at all
    kind = _truth(tmp_path, lane=ct.LANE_KIND)
    op = next(u for u in annotate(roster, kind).users if u.username == "mesh-operator")
    assert op.live == ct.NOT_ON_LANE
