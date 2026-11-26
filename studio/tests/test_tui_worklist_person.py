"""tui — a checked desktop row names its person (G37, the worklist half).

The window's mesh worklist refuses to continue while a checked desktop-class row has no
user named: ``WorklistPage.isComplete`` keeps Next disabled and ``validatePage`` returns
False, because the account on the mesh's internal domain and the image's
``--person-role`` both come from the name. The text UI's worklist let a desktop row
through with no person, so a walk reached a build the window would not start.

``who N NAME [ROLE ...]`` is the who-uses-it popup as a command, and Enter refuses a
checked desktop with nobody named, in the window's rule (``worklist.person_problem``,
the one predicate both faces call).
"""
import pytest

from hugmesh_studio.core.config import (
    PERSON_ROLE_CHOICES, ROLE_CHOICES, USER_GRANT_CHOICES, image_class,
)
from hugmesh_studio.core import worklist as wl_core
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
from hugmesh_studio.tui import journey


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _row(j, entry: str) -> str:
    """The row NUMBER of an entry id (``laptop.x86``) on the screen the journey shows."""
    ids = [f"{r}.{p}" for r, p, _l in j.screen()._rows]
    return str(ids.index(entry) + 1)


def _at_worklist() -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")            # welcome -> mode
    j.feed("3")           # mesh -> idp
    j.feed("")            # idp keeps casdoor -> worklist
    assert j.slug == "worklist"
    return j


def _text(j) -> str:
    return "\n".join(j.lines())


# ── the rule is the core's one predicate ───────────────────────────────────────────
def test_the_rows_with_a_person_are_the_desktop_class_ones_derived_not_listed():
    mesh_roles = [role for role, _platforms, _label in ROLE_CHOICES["mesh"]]
    desktops = [r for r in mesh_roles if image_class("mesh", r) == "desktop"]
    nodes = [r for r in mesh_roles if image_class("mesh", r) == "node"]
    assert desktops and nodes
    for role in desktops:
        assert wl_core.takes_person(role), role
        assert wl_core.person_problem(role, "") and wl_core.person_problem(role, "  ")
        assert wl_core.person_problem(role, "alice") == ""
    for role in nodes:
        assert not wl_core.takes_person(role), role
        assert wl_core.person_problem(role, "") == ""


# ── Enter refuses a checked desktop with nobody named ──────────────────────────────
def test_a_checked_desktop_without_a_user_is_refused_inline_and_nothing_is_collected():
    j = _at_worklist()
    j.feed(_row(j, "laptop.x86"))                   # check it
    assert "[user not named: who " in _text(j)
    j.feed("")
    assert j.slug == "worklist" and j.worklist is None
    assert "laptop is a person's device: name who uses it" in j.status
    assert f"who {_row(j, 'laptop.x86')} NAME" in j.status


def test_a_node_row_needs_no_person():
    j = _at_worklist()
    j.feed(_row(j, "pki.x86"))
    assert "user not named" not in _text(j)
    j.feed("")
    assert j.slug != "worklist" and j.worklist.entries[0].desktop_user == ""


def test_the_first_refused_row_is_named_even_when_other_rows_are_fine():
    j = _at_worklist()
    laptop, chromebook = _row(j, "laptop.x86"), _row(j, "chromebook.x86")
    for r in (_row(j, "pki.x86"), laptop, chromebook):
        j.feed(r)
    j.feed(f"who {laptop} alice")
    j.feed("")
    assert j.slug == "worklist"
    assert j.status.startswith(f"row {chromebook}: chromebook is a person's device")


# ── who N NAME [ROLE ...] ──────────────────────────────────────────────────────────
def test_who_names_the_person_and_the_walk_continues_with_it_on_the_entry():
    j = _at_worklist()
    row = _row(j, "laptop.x86")
    j.feed(_row(j, "pki.x86"))
    j.feed(row)
    j.feed(f"who {row} alice admin games")
    assert j.status == f"row {row} laptop.x86: used by alice (admin, games)"
    assert "[used by alice (admin, games)]" in _text(j)
    j.feed("")
    assert j.slug != "worklist"
    lap = {e.id: e for e in j.worklist.entries}["laptop.x86"]
    assert (lap.desktop_user, lap.desktop_user_role) == ("alice", "admin")
    assert lap.desktop_user_roles == ["admin", "games"]
    pki = {e.id: e for e in j.worklist.entries}["pki.x86"]
    assert pki.desktop_user == ""
    # ...and the core turns it into the manifest account and the image's person identity,
    # exactly what the window's entry does
    [user] = j.worklist.desktop_users()
    assert (user.username, user.roles) == ("alice", ["admin", "games"])
    assert user.domain == j.cfg.effective_superdomain()
    built = {e.id: c for e, c in j.worklist.materialize()}
    assert built["laptop.x86"].person_role == "admin"
    assert built["pki.x86"].person_role == ""


def test_the_tier_defaults_to_user_and_grants_ride_on_it():
    j = _at_worklist()
    row = _row(j, "laptop.x86")
    j.feed(row)
    j.feed(f"who {row} bob")
    assert "used by bob (user)" in _text(j)
    j.feed(f"who {row} bob games-services")
    assert "used by bob (user, games-services)" in _text(j)
    j.feed(f"who {row} bob GAMES mod")                # case does not matter; order is canonical
    assert "used by bob (mod, games)" in _text(j)
    j.feed("")
    assert j.worklist.entries[0].desktop_user_role == "mod"


def test_the_roles_are_the_windows_vocabulary_one_tier_plus_grants():
    assert journey._person_roles([]) == ["user"]
    assert journey._person_roles(["superadmin"]) == ["superadmin"]
    for tier in PERSON_ROLE_CHOICES:
        for grant in USER_GRANT_CHOICES:
            assert journey._person_roles([grant, tier]) == [tier, grant]
    with pytest.raises(ValueError, match="one tier only"):
        journey._person_roles(["admin", "mod"])
    with pytest.raises(ValueError, match="unknown role 'wizard'"):
        journey._person_roles(["wizard"])
    assert journey._person_roles(["admin", "admin"]) == ["admin"]


@pytest.mark.parametrize("line, why", [
    ("who {r} Alice", "is not an account name"),            # the allowlist every surface uses
    ("who {r} a/b", "is not an account name"),
    ("who {r} alice wizard", "unknown role 'wizard'"),
    ("who {r} alice admin mod", "one tier only"),
    ("who {r}", "usage: who N NAME"),
    ("who", "usage: who N NAME"),
    ("who 999 alice", "usage: who N NAME"),
    ("who {r} - alice", "usage: who N NAME"),
])
def test_who_refusals_say_why_and_change_nothing(line, why):
    j = _at_worklist()
    row = _row(j, "laptop.x86")
    j.feed(row)
    j.feed(f"who {row} carol")                            # an existing, good answer
    j.feed(line.format(r=row))
    assert why in j.status, j.status
    assert j.screen()._people == {int(row) - 1: ("carol", ["user"])}   # untouched
    assert j.slug == "worklist"


def test_who_on_a_node_row_or_an_unchecked_row_is_refused():
    j = _at_worklist()
    pki, laptop = _row(j, "pki.x86"), _row(j, "laptop.x86")
    j.feed(pki)
    j.feed(f"who {pki} alice")
    assert "is a cluster node: it has no person" in j.status
    j.feed(f"who {laptop} alice")                         # not checked yet
    assert "is not checked" in j.status and f"type {laptop} first" in j.status
    assert j.screen()._people == {}


def test_who_dash_clears_it_and_enter_refuses_again():
    j = _at_worklist()
    row = _row(j, "laptop.x86")
    j.feed(row)
    j.feed(f"who {row} alice")
    j.feed(f"who {row} -")
    assert "no user named" in j.status and "[user not named" in _text(j)
    j.feed("")
    assert j.slug == "worklist"


def test_unchecking_a_row_forgets_its_person_like_the_window():
    j = _at_worklist()
    row = _row(j, "laptop.x86")
    j.feed(row)
    j.feed(f"who {row} alice")
    j.feed(row)                                           # off
    j.feed(row)                                           # on again
    assert "[user not named" in _text(j)
    j.feed("")
    assert j.slug == "worklist"


def test_the_help_line_names_the_command_only_where_a_desktop_row_is_offered():
    j = _at_worklist()
    assert "`who N NAME [ROLE ...]`" in _text(j)
    assert "|".join(PERSON_ROLE_CHOICES) in _text(j)
    j.worklist_role_allow = ("pki", "backend")             # a restriction with no desktop in it
    j.screen().enter(j)
    assert "who N NAME" not in _text(j)


# ── a person already on a loaded entry is kept; one that is missing is asked for ─────
def _saved(tmp_path, *entries):
    from hugmesh_studio.core.config import ImageConfig
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme")
    path = tmp_path / "mesh.json"
    WorklistConfig(base=base, entries=list(entries)).save(str(path))
    return path


def test_a_loaded_worklist_keeps_its_named_person_through_the_screen(tmp_path):
    path = _saved(tmp_path, WorklistEntry(role="laptop", platform="x86", desktop_user="dana",
                                          desktop_user_roles=["admin", "games"]))
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {path}")
    j.goto("worklist")
    assert "[used by dana (admin, games)]" in _text(j)
    j.feed("")
    assert j.slug != "worklist"
    [e] = j.worklist.entries
    assert (e.desktop_user, e.desktop_user_roles, e.desktop_user_role) == (
        "dana", ["admin", "games"], "admin")


def test_a_loaded_worklist_with_an_unnamed_desktop_is_stopped_at_the_worklist(tmp_path):
    path = _saved(tmp_path, WorklistEntry(role="laptop", platform="x86"),
                  WorklistEntry(role="pki", platform="x86"))
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {path}")
    j.goto("worklist")
    assert "[user not named" in _text(j)
    j.feed("")
    assert j.slug == "worklist" and "person's device" in j.status
    j.feed(f"who {_row(j, 'laptop.x86')} dana")
    j.feed("")
    assert j.slug != "worklist"
    assert {e.id: e.desktop_user for e in j.worklist.entries} == {
        "laptop.x86": "dana", "pki.x86": ""}


def test_the_local_cloud_flow_asks_for_the_laptops_person_too(monkeypatch):
    """Its abbreviated worklist offers the laptop row: the same screen, the same rule."""
    from hugmesh_studio.tui import localcloud as lc
    monkeypatch.setattr(lc, "local_mesh_identity", lambda _gd: ("mesh.example.org", [], False))
    monkeypatch.setattr(lc, "local_k8s_running", lambda _gd: False)
    j = journey.Journey(".")
    j.feed("")
    j.feed("2")
    j.feed("y")
    j.feed("")                                            # idp -> worklist
    assert j.slug == "worklist" and j.worklist_role_allow == lc.ALLOWED_ROLES
    row = _row(j, "laptop.x86")
    j.feed(row)
    j.feed("")
    assert j.slug == "worklist" and "person's device" in j.status
    j.feed(f"who {row} erin")
    j.feed("")
    assert j.slug != "worklist" and j.worklist.entries[0].desktop_user == "erin"
