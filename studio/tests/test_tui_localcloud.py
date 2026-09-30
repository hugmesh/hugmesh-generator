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
CANNED_USERS = [("superadmin", ["superadmin"]),
                ("alice", ["admin", "games"]),
                ("bob", "user")]          # a bare string still loads (#228 back-compat)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


_REAL_IDENTITY = lc.local_mesh_identity     # the real reader, before it is canned


@pytest.fixture(autouse=True)
def _canned_local_mesh(monkeypatch):
    # (domain, users, with_tor) — the canned mesh ran no Tor.
    monkeypatch.setattr(lc, "local_mesh_identity",
                        lambda _gd: (CANNED_DOMAIN, list(CANNED_USERS), False))


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
    # #228: EVERY role is listed, joined — never a raw Python list repr. The
    # reader in this same module returns list-valued roles, so the renderer
    # must be exercised with that shape or the divergence goes unseen.
    assert "alice (admin, games)" in text
    accounts = [ln for ln in text.splitlines() if "accounts:" in ln][0]
    assert "[" not in accounts and "'" not in accounts
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
    # superadmins belong to the Tailscale root domain; everyone else lands
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


# ── #579: a saved mesh that ran Tor reaches the node images (TUI face) ─────────────
import os  # noqa: E402
import socket  # noqa: E402

from hugmesh_studio.core import package_catalog as pc  # noqa: E402
from hugmesh_studio.core import saved_meshes as sm  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402

_GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _save(tmp_path, services, with_tor=False):
    cfg = LocalMeshBootstrapConfig(env="prod", cluster_domain="saved.example.org",
                                   out_dir=str(tmp_path / "keys"), services=services,
                                   with_tor=with_tor)
    rec = sm.SavedMesh(id=sm.new_id(), label="tor-mesh", generator_dir=_GEN,
                       hostname=socket.gethostname(), config=cfg.to_dict())
    assert sm.save(rec)


def test_real_reader_reads_tor_and_domain_from_the_saved_record(tmp_path):
    _save(tmp_path, ("tuwunel", "tor"))
    ident = _REAL_IDENTITY(_GEN)
    assert ident.domain == "saved.example.org"
    assert ident.with_tor is True
    assert "tor-mesh" in ident.source


def test_real_reader_follows_the_services_tuple_not_the_legacy_flag(tmp_path):
    _save(tmp_path, ("tuwunel",), with_tor=True)
    assert _REAL_IDENTITY(_GEN).with_tor is False


def test_real_reader_ignores_another_checkouts_record(tmp_path):
    _save(tmp_path, ("tor",))
    other = tmp_path / "other-checkout"
    other.mkdir()
    ident = _REAL_IDENTITY(str(other))
    assert ident.with_tor is False and ident.source == ""


def test_tui_gate_bridges_a_tor_mesh_into_x86_and_rpi5_node_argv(tmp_path, monkeypatch):
    _save(tmp_path, ("tuwunel", "tor"))
    monkeypatch.setattr(lc, "local_mesh_identity", _REAL_IDENTITY)
    j = journey.Journey(_GEN)
    j.feed("")
    j.feed("2")
    assert j.slug == "localcloud"
    text = "\n".join(j.lines())
    assert "Tor onion: on" in text and "cannot carry Tor: jetson" in text
    j.feed("y")
    assert j.cfg.tor_onion_service is True
    wl = WorklistConfig(base=j.cfg, entries=[
        WorklistEntry(role="backend", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5")])
    got = {e.id: c for e, c in wl.materialize()}
    x86, rpi = got["backend.x86"], got["backend.rpi5"]
    assert "--with-tor" in x86.to_cli_args()
    argv = rpi.to_cli_args()
    svcs = argv[argv.index("--optional-services") + 1].split()
    assert "tor" in svcs and {"akkoma", "tuwunel", "phpbb"} <= set(svcs)
    assert "net-vpn/tor" in pc.adhoc_atoms(x86)
    assert "net-vpn/tor" in pc.adhoc_atoms(rpi)


def test_apply_gate_without_tor_leaves_tor_alone():
    j = journey.Journey(".")
    j.cfg.tor_onion_service = "off"
    lc.apply_gate(j, "mesh.example.org", [])
    assert j.cfg.tor_onion_service == "off"


def test_real_reader_falls_back_on_a_malformed_newest_record(tmp_path):
    # A record from_dict cannot read (services must be a sequence) must not raise out
    # of the TUI's gate: the defaults come back and no source is claimed.
    rec = sm.SavedMesh(id=sm.new_id(), label="broken", generator_dir=_GEN,
                       hostname=socket.gethostname(),
                       config={"env": "prod", "cluster_domain": "bad.example.org",
                               "services": 42})
    assert sm.save(rec)
    ident = _REAL_IDENTITY(_GEN)
    assert ident.source == "" and ident.with_tor is False
    assert ident.domain != "bad.example.org"


# ── #636: a local mesh generated with N domains imports ALL of them (TUI face) ───────
from hugmesh_studio.core.config import DOMAIN_IDP_OWN  # noqa: E402


def _save_n_domains(tmp_path):
    cfg = LocalMeshBootstrapConfig(
        env="prod", cluster_domain="saved.example.org", out_dir=str(tmp_path / "keys"),
        domains=({"name": "a.example", "title": "Alpha", "idp": "superdomain",
                  "optional_services": ["phpbb"]},
                 {"name": "b.example", "title": "Beta", "idp": DOMAIN_IDP_OWN,
                  "optional_services": []}),
        own_idp_domains=("b.example",),
        domain_services_reviewed=("a.example",))
    rec = sm.SavedMesh(id=sm.new_id(), label="three-domains", generator_dir=_GEN,
                       hostname=socket.gethostname(), config=cfg.to_dict())
    assert sm.save(rec)


def test_tui_gate_imports_every_domain_of_the_saved_mesh(tmp_path, monkeypatch):
    _save_n_domains(tmp_path)
    monkeypatch.setattr(lc, "local_mesh_identity", _REAL_IDENTITY)
    j = journey.Journey(_GEN)
    j.feed("")
    j.feed("2")
    assert j.slug == "localcloud"
    text = "\n".join(j.lines())
    assert "domains: a.example — superdomain sign-in; services: phpbb" in text
    assert "b.example — own Casdoor; services: cluster default " \
        "(services not confirmed yet)" in text
    j.feed("y")
    assert j.cfg.cluster_domain == "saved.example.org"
    assert [d.name for d in j.cfg.domains] == ["a.example", "b.example"]
    assert j.cfg.own_idp_domains() == ("b.example",)
    assert j.cfg.domains[0].optional_services == ["phpbb"]
    assert j.cfg.additional_domains is True
    assert j.cfg.domain_services_reviewed == ["a.example"]


def test_tui_apply_gate_without_domains_imports_the_apex_only():
    j = journey.Journey(".")
    lc.apply_gate(j, "mesh.example.org", [])
    assert j.cfg.domains == [] and j.cfg.additional_domains is False
