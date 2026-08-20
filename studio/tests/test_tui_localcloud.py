"""tui — the "create nodes for local cloud" gate (#65's TUI surface).

Headless and Qt-free; the local mesh identity is CANNED exactly the way the GUI
suite cans it (monkeypatching the module's ``local_mesh_identity``), so no test
depends on the checkout's real roster/secrets.
"""
import pytest

from hugmesh_studio.core.config import ROLE_CHOICES, image_class
from hugmesh_studio.tui import journey
from hugmesh_studio.tui import localcloud as lc

CANNED_DOMAIN = "mesh.example.org"
CANNED_USERS = [("superadmin", "superadmin"), ("alice", "admin"), ("bob", "user")]


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _canned_local_mesh(monkeypatch):
    monkeypatch.setattr(lc, "local_mesh_identity",
                        lambda _gd: (CANNED_DOMAIN, list(CANNED_USERS)))


def _at_gate() -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")            # welcome -> mode
    j.feed("2")           # the localcloud card (journey position 2)
    assert j.slug == "localcloud"
    return j


# ── the allow-set is DERIVED, never hand-kept ───────────────────────────────────────
def test_allowed_roles_are_laptop_plus_every_node_class_role():
    expected = tuple(role for role, _p, _l in ROLE_CHOICES["mesh"]
                     if role == "laptop" or image_class("mesh", role) == "node")
    assert lc.ALLOWED_ROLES == expected
    assert "laptop" in lc.ALLOWED_ROLES
    assert "chromebook" not in lc.ALLOWED_ROLES     # person-desktop: withdrawn


# ── the gate: identity shown, consent required, decline commits nothing ────────────
def test_gate_shows_the_imported_identity_before_asking_consent():
    j = _at_gate()
    text = "\n".join(j.lines())
    assert CANNED_DOMAIN in text
    assert "superadmin (superadmin)" in text and "bob (user)" in text
    assert "make kind-down" in text                 # the manual-teardown honesty
    assert "k8s will stop to proceed" in j.prompt()


def test_declining_the_gate_backs_out_with_nothing_committed():
    j = _at_gate()
    before = j.cfg.to_dict()
    j.feed("n")
    assert j.slug == "mode"
    assert j.cfg.to_dict() == before                # byte-for-byte untouched
    assert j.cfg.mode == "standalone" and j.cfg.users == []
    assert j.worklist_role_allow is None
    assert "nothing committed" in j.status


def test_confirming_commits_the_mesh_chain_and_rejoins_at_idp():
    j = _at_gate()
    j.feed("y")
    assert j.slug == "idp"                          # the abbreviated wizard rejoins
    assert j.cfg.mode == "mesh"
    assert j.cfg.role == "omnibus"                  # mesh default, reset by id
    assert j.cfg.bundle_source is False


def test_import_lands_domain_and_accounts_with_the_superadmin_rule():
    j = _at_gate()
    j.feed("y")
    cfg = j.cfg
    assert cfg.cluster_domain == CANNED_DOMAIN
    by_name = {u.username: u for u in cfg.users}
    assert set(by_name) == {"superadmin", "alice", "bob"}
    # superadmins belong to the orchestration superdomain; everyone else lands
    # on the imported apex (the GUI page's exact rule).
    assert by_name["superadmin"].domain == cfg.effective_superdomain()
    assert by_name["alice"].domain == CANNED_DOMAIN
    assert by_name["alice"].role == "admin" and by_name["bob"].role == "user"
    # the users step becomes reachable so the import is visible
    assert cfg.configure_users is True


def test_a_repeat_gate_pass_never_duplicates_the_imported_rows():
    j = _at_gate()
    j.feed("y")
    j.goto("mode")
    j.feed("2")                                     # re-enter the gate
    j.feed("y")                                     # re-confirm: re-import
    names = [u.username for u in j.cfg.users]
    assert sorted(names) == ["alice", "bob", "superadmin"]


def test_consent_is_asked_afresh_on_every_entry():
    j = _at_gate()
    j.feed("y")
    j.goto("mode")
    j.feed("2")
    # back on the gate: the prompt is the consent question again (no memory)
    assert j.slug == "localcloud"
    assert "[y/N]" in j.prompt()


# ── the abbreviation: the worklist offers ONLY the allow-set's rows ─────────────────
def test_worklist_offers_only_laptop_and_node_rows():
    j = _at_gate()
    j.feed("y")                                     # -> idp
    j.feed("")                                      # -> worklist
    assert j.slug == "worklist"
    assert j.worklist_role_allow == lc.ALLOWED_ROLES
    text = "\n".join(j.lines())
    assert "Abbreviated flow" in text
    assert "laptop.x86" in text and "omnibus.x86" in text
    assert "chromebook" not in text


def test_restriction_holds_at_collection_too():
    # the TUI's single row source IS the restriction: what is collected is what
    # was offered, so a disallowed role can never be collected.
    j = _at_gate()
    j.feed("y")
    j.feed("")
    j.feed("1")                                     # first offered row
    j.feed("")                                      # collect + continue
    assert all(e.role in lc.ALLOWED_ROLES for e in j.worklist.entries)


def test_any_other_mode_commit_lifts_the_restriction():
    j = _at_gate()
    j.feed("y")
    j.goto("mode")
    j.feed("3")                                     # a plain mesh flow
    assert j.worklist_role_allow is None
    j.feed("")                                      # idp -> worklist
    text = "\n".join(j.lines())
    assert "Abbreviated flow" not in text
    assert "chromebook" in text                     # the full catalog is back
