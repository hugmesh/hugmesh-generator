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
    _NOT_SEEDED, Roster, SeededUser, annotate, load_roster, suggested_signin)

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


def test_unreadable_file_replaces_the_password_cell_not_the_not_seeded_marker(tmp_path):
    creds = ct.CredentialsFile(path=str(tmp_path / ".e2e-credentials"), exists=True,
                               readable=False, mtime=1.0,
                               error="PermissionError: Permission denied", keys=())
    out = annotate(_roster(tmp_path), _truth(tmp_path, creds=creds))
    assert out.truth.state == ct.STATE_UNREADABLE
    admin = next(u for u in out.users if u.username == "e2e-admin")
    assert admin.password == ct.UNREADABLE_MARKER
    assert admin.password != _NOT_SEEDED


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
