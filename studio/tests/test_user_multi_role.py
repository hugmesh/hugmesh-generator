"""Issue #228 — Superusers & domain users: multi-role support.

One account, several roles. ``User.roles`` is the full set (precedence order:
config.USER_ROLE_CHOICES), ``User.role`` the derived primary every pre-#228 consumer
still reads. Pins the four faces the operator's rule names — the data model, the
wizard table, the headless CLI (``--config`` JSON -> ``--print-command`` /
``--print-specs``) and the TUI — plus the two channels the value must reach: the
saved config (to_dict/from_dict/save/load) and both mesh manifests.

``test_a_multi_role_config_reaches_person_role_derivation`` is the one that FAILS on
the old single-role model: there ``roles`` was an unknown key, silently dropped by
from_dict, and the account collapsed to the ``user`` default.
"""
import json
import os

import pytest

from hugmesh_studio import app
from hugmesh_studio.core.config import (
    PERSON_ROLE_CHOICES, USER_ROLE_CHOICES, Domain, ImageConfig, User,
    normalize_user_roles, person_tier,
)
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
from hugmesh_studio.core.worklist_driver import WorklistDriver
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.tui import journey
from hugmesh_studio.tui import localcloud as tui_lc

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _pairs(args):
    return list(zip(args, args[1:]))


# ── the data model ───────────────────────────────────────────────────────────────────
def test_normalize_user_roles_orders_dedups_and_floors():
    assert normalize_user_roles([]) == ["user"]
    assert normalize_user_roles(["", None, "  "]) == ["user"]
    # precedence = the vocabulary order, whatever order the operator ticked
    assert normalize_user_roles(["games", "admin", "user", "games"]) == \
        ["admin", "user", "games"]
    assert normalize_user_roles(["games-services", "superadmin"]) == \
        ["superadmin", "games-services"]
    # a role outside the vocabulary (a newer Studio's) is KEPT, after the known ones
    assert normalize_user_roles(["future-role", "mod"]) == ["mod", "future-role"]


def test_person_tier_is_the_highest_tier_and_never_a_grant():
    assert person_tier(["games", "mod", "admin"]) == "admin"
    assert person_tier(["games"]) == "user"
    assert person_tier(["games-services", "superadmin"]) == "superadmin"
    for tier in PERSON_ROLE_CHOICES:
        assert person_tier([tier]) == tier


def test_user_constructor_accepts_role_roles_or_both():
    assert User().roles == ["user"] and User().role == "user"
    one = User(username="jo", role="mod")               # every pre-#228 spelling
    assert one.roles == ["mod"] and one.role == "mod" and one.tier == "mod"
    many = User(username="ada", roles=["games", "admin"])
    assert many.roles == ["admin", "games"]
    assert many.role == "admin"                         # the primary is DERIVED
    assert many.tier == "admin"
    both = User(username="cy", role="superadmin", roles=["games-services"])
    assert both.roles == ["superadmin", "games-services"] and both.role == "superadmin"
    grants = User(username="gg", roles=["games", "games-services"])
    assert grants.role == "games" and grants.tier == "user"


def test_user_to_dict_omits_roles_when_single():
    # a one-role account keeps its pre-#228 bytes (absent == [role]) — the idp precedent
    assert User(username="jo", role="mod").to_dict() == {
        "username": "jo", "domain": "", "role": "mod", "email": "", "registration": ""}
    d = User(username="ada", roles=["games", "admin"]).to_dict()
    assert d["role"] == "admin" and d["roles"] == ["admin", "games"]


# ── round trip: saved config, both manifests ─────────────────────────────────────────
def _cfg(tmp_path=None):
    c = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal",
                    output_dir=str(tmp_path / "out") if tmp_path else "")
    c.domains = [Domain(name="acme.example", title="Acme")]
    c.users = [User(username="root-admin", domain="core.acme.internal",
                    roles=["superadmin", "games"]),
               User(username="bob", domain="acme.example", role="user")]
    return c


def test_multi_role_round_trips_through_to_dict_from_dict_save_load(tmp_path):
    c = _cfg()
    d = c.to_dict()
    assert d["users"][0]["role"] == "superadmin"
    assert d["users"][0]["roles"] == ["superadmin", "games"]
    assert "roles" not in d["users"][1]                 # single-role: unchanged bytes
    r = ImageConfig.from_dict(d)
    assert [u.roles for u in r.users] == [["superadmin", "games"], ["user"]]
    assert [u.role for u in r.users] == ["superadmin", "user"]
    p = tmp_path / "c.json"
    c.save(str(p))
    loaded = ImageConfig.load(str(p))
    assert loaded.users[0].roles == ["superadmin", "games"]
    assert loaded.users[0].to_dict() == c.users[0].to_dict()


def test_from_dict_loads_every_spelling_and_tolerates_junk():
    def one(u):
        return ImageConfig.from_dict({"mode": "mesh", "role": "omnibus", "users": [u]}).users[0]
    assert one({"username": "a", "role": "mod"}).roles == ["mod"]            # pre-#228
    assert one({"username": "a", "roles": ["games", "mod"]}).roles == ["mod", "games"]
    assert one({"username": "a", "role": "admin", "roles": ["games"]}).roles == \
        ["admin", "games"]                                                    # unioned
    assert one({"username": "a", "roles": "admin"}).roles == ["admin"]        # bare string
    assert one({"username": "a", "roles": None, "role": "mod"}).roles == ["mod"]
    assert one({"username": "a", "roles": 7}).roles == ["user"]
    assert one({"username": "a", "role": None}).roles == ["user"]
    assert one({"username": "a"}).roles == ["user"]
    # forward-compat: an unknown FUTURE user key is still dropped
    u = one({"username": "a", "roles": ["admin"], "future_unknown_key": 1})
    assert u.roles == ["admin"] and not hasattr(u, "future_unknown_key")


def test_both_mesh_manifests_carry_role_and_the_full_roles_list(tmp_path):
    c = _cfg(tmp_path)
    v1 = c.mesh_manifest()["users"]
    assert v1[0]["role"] == "superadmin" and v1[0]["roles"] == ["superadmin", "games"]
    assert "roles" not in v1[1]
    wl = WorklistConfig(base=c, entries=[WorklistEntry(role="pki", platform="x86")])
    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    v2 = WorklistDriver(GENERATOR_DIR, wl, host).manifest_v2()["users"]
    assert v2 == v1
    # ...and the manifest is plain JSON (a list, not a tuple/set) on disk
    path = c.write_mesh_manifest(str(tmp_path / "m"))
    with open(path, encoding="utf-8") as fh:
        assert json.load(fh)["users"] == v1


def test_worklist_envelope_round_trips_multi_role_users(tmp_path):
    from hugmesh_studio.core.worklist import load_any
    c = _cfg(tmp_path)
    wl = WorklistConfig(base=c, entries=[WorklistEntry(role="pki", platform="x86"),
                                         WorklistEntry(role="laptop", platform="x86",
                                                       desktop_user="alice",
                                                       desktop_user_role="mod")])
    p = tmp_path / "wl.json"
    wl.save(str(p))
    _base, back = load_any(str(p))
    assert back.base.users[0].roles == ["superadmin", "games"]
    # a desktop person named with a tier alone is still a (one-role) manifest User
    by_id = {e.id: cfg for e, cfg in back.materialize()}
    alice = [u for u in by_id["laptop.x86"].users if u.username == "alice"][0]
    assert alice.roles == ["mod"] and alice.role == "mod"
    assert by_id["laptop.x86"].person_role == "mod"


def test_cli_worklist_envelope_expresses_a_multi_role_desktop_person(tmp_path, capsys):
    """The CLI face of the desktop-person leg: a worklist envelope's
    ``desktop_user_roles`` (the who-uses-it dialog's tier + grants) reaches
    --print-specs as the manifest User's full set and --print-commands as the
    tier alone. FAILS on the single-role entry (unknown field)."""
    c = _cfg(tmp_path)
    wl = WorklistConfig(base=c, entries=[
        WorklistEntry(role="laptop", platform="x86", desktop_user="alice",
                      desktop_user_roles=["games", "admin"])])
    p = tmp_path / "wl.json"
    wl.save(str(p))
    with open(p, encoding="utf-8") as fh:
        entry = json.load(fh)["entries"][0]
    assert entry["desktop_user_role"] == "admin"
    assert entry["desktop_user_roles"] == ["admin", "games"]
    assert app.main(["--config", str(p), "--print-specs"]) == 0
    spec = json.loads(capsys.readouterr().out.strip().splitlines()[0])
    alice = [u for u in spec["users"] if u["username"] == "alice"][0]
    assert alice["role"] == "admin" and alice["roles"] == ["admin", "games"]
    assert alice["domain"] == c.effective_superdomain()
    assert spec["person_role"] == "admin"
    assert app.main(["--config", str(p), "--print-commands"]) == 0
    cmd = capsys.readouterr().out
    assert "--person-role admin" in cmd
    assert "--person-role games" not in cmd


# ── the sharpest single-role assumption: --person-role from users[0] ────────────────
def test_a_multi_role_config_reaches_person_role_derivation():
    """FAILS on the pre-#228 model: `roles` was an unknown key, dropped by from_dict,
    and the account collapsed to role="user" -> `--person-role user`."""
    cfg = ImageConfig.from_dict({
        "mode": "cloud", "role": "desktop", "platform": "x86",
        "tailscale": True, "sso": True,
        "users": [{"username": "ada", "roles": ["games", "mod"]}]})
    assert cfg.users[0].roles == ["mod", "games"]
    assert ("--person-role", "mod") in _pairs(cfg.to_cli_args())


def test_person_role_derivation_uses_the_highest_tier_of_users0():
    def args(roles):
        return ImageConfig(mode="cloud", role="desktop", platform="x86", tailscale=True,
                           sso=True, users=[User(username="jo", roles=roles)]).to_cli_args()
    assert ("--person-role", "admin") in _pairs(args(["games", "admin", "user"]))
    assert ("--person-role", "superadmin") in _pairs(args(["mod", "superadmin"]))
    # a grants-only account is a plain user on the image: the builder accepts exactly
    # the four tiers, so `--person-role games` is never emitted.
    assert ("--person-role", "user") in _pairs(args(["games"]))
    assert "games" not in args(["games", "games-services"])
    # an explicit tier still wins over the derivation
    exp = ImageConfig(mode="cloud", role="desktop", platform="x86", tailscale=True,
                      sso=True, person_role="mod",
                      users=[User(username="jo", roles=["superadmin"])]).to_cli_args()
    assert ("--person-role", "mod") in _pairs(exp)


# ── the CLI face: --config JSON -> --print-command / --print-specs ───────────────────
def test_cli_print_command_and_print_specs_express_multi_role(tmp_path, capsys):
    cfg = ImageConfig(mode="cloud", role="desktop", platform="x86", tailscale=True,
                      sso=True, output_dir=str(tmp_path / "out"),
                      users=[User(username="ada", domain="acme.example",
                                  roles=["games", "admin"])])
    p = tmp_path / "cfg.json"
    p.write_text(json.dumps(cfg.to_dict()), encoding="utf-8")
    assert app.main(["--config", str(p), "--print-command"]) == 0
    cmd = capsys.readouterr().out
    assert "--person-role admin" in cmd
    assert "--person-role games" not in cmd
    assert app.main(["--config", str(p), "--print-specs"]) == 0
    spec = json.loads(capsys.readouterr().out.strip().splitlines()[0])
    assert spec["users"][0]["role"] == "admin"
    assert spec["users"][0]["roles"] == ["admin", "games"]


# ── the TUI face ─────────────────────────────────────────────────────────────────────
def test_tui_users_screen_lists_every_role():
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.users = [User(username="ada", domain="acme.example", roles=["games", "admin"]),
                   User(username="bob", domain="acme.example", role="user")]
    lines = j.screen_for("users").lines(j)
    text = "\n".join(lines)
    assert "admin, games" in text
    assert "roles" in lines[0]
    bob = [ln for ln in lines if "bob" in ln][0]
    assert "user" in bob and "games" not in bob     # one role renders as one word


def test_tui_localcloud_import_carries_every_mapped_grant():
    assert tui_lc._person_roles(("ROLE_USER", "ROLE_GAMES", "ROLE_ADMIN")) == \
        ["admin", "user", "games"]
    assert tui_lc._person_roles(("ROLE_MATRIX",)) == ["user"]          # nothing mapped
    assert tui_lc._person_roles(("ROLE_SUPERADMIN", "ROLE_GAMES_SERVICES")) == \
        ["superadmin", "games-services"]
    j = journey.Journey(GENERATOR_DIR)
    tui_lc.apply_gate(j, "mesh.example.org",
                      [("root", ["superadmin", "games"]), ("ada", ["admin", "games"]),
                       ("bob", "user")])                       # a bare string still works
    by_name = {u.username: u for u in j.cfg.users}
    assert by_name["root"].roles == ["superadmin", "games"]
    assert by_name["root"].domain == j.cfg.effective_superdomain()   # superadmin rule holds
    assert by_name["ada"].roles == ["admin", "games"]
    assert by_name["ada"].domain == "mesh.example.org"
    assert by_name["bob"].roles == ["user"]


# ── the GUI face ─────────────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def qapp():
    # session-scoped and RETURNED so the QApplication outlives every wizard (a
    # discarded instance is collected before QWizard() and Qt aborts the process).
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp, monkeypatch):
    from hugmesh_studio.gui import wizard as wizard_mod
    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": host)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def test_gui_users_table_collects_and_reloads_multi_role_rows(wiz):
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages.users import RoleCell
    from _helpers import advance_to, back_to, enable_configure_users, pick_mode
    pick_mode(wiz, "mesh")
    enable_configure_users(wiz)
    users = advance_to(wiz, wizard_mod.UsersPage)
    users._add("ada", "acme.example", "user")
    cell = users.table.cellWidget(0, 2)
    assert isinstance(cell, RoleCell)
    assert cell.choices() == list(USER_ROLE_CHOICES)
    boxes = dict(cell.boxes)
    boxes["admin"].setChecked(True)
    boxes["games"].setChecked(True)
    assert cell.roles() == ["admin", "user", "games"]
    # nothing ticked -> the user floor (the help label under the table says so)
    users._add("nobody", "acme.example", [])
    empty = users.table.cellWidget(1, 2)
    assert empty.roles() == ["user"]
    assert "nothing ticked" in users.roles_help.text()
    advance_to(wiz, wizard_mod.HomePage)
    c = wiz.cfg
    assert [(u.username, u.roles) for u in c.users] == \
        [("ada", ["admin", "user", "games"]), ("nobody", ["user"])]
    assert c.users[0].role == "admin"
    m = c.mesh_manifest()["users"]
    assert m[0]["role"] == "admin" and m[0]["roles"] == ["admin", "user", "games"]
    assert "roles" not in m[1]
    # back-nav: the row reloads with the same boxes ticked (initializePage path)
    back_to(wiz, wizard_mod.UsersPage)
    assert users.table.cellWidget(0, 2).roles() == ["admin", "user", "games"]


def test_gui_users_table_seeds_from_a_loaded_multi_role_config(wiz):
    from hugmesh_studio.gui import wizard as wizard_mod
    from _helpers import advance_to
    c = wiz.cfg
    c.mode = "mesh"
    c.configure_users = True
    c.users = [User(username="root", domain=c.effective_superdomain(),
                    roles=["games-services", "superadmin"])]
    wiz.restart()
    users = advance_to(wiz, wizard_mod.UsersPage)
    cell = users.table.cellWidget(0, 2)
    assert cell.roles() == ["superadmin", "games-services"]
    # superadmin among several roles still locks the row to the superdomain (spec 5)
    dom = users.table.cellWidget(0, 1)
    assert not dom.isEnabled() and dom.currentText() == c.effective_superdomain()
    advance_to(wiz, wizard_mod.HomePage)
    assert c.users[0].roles == ["superadmin", "games-services"]
