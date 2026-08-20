"""LocalCloudNodesPage (issue #50, items 3-5) — the "create nodes for local cloud"
gate: routing off the ModePage card, the INLINE k8s-will-stop confirmation (modeless
— no QMessageBox/exec in page logic), the local-mesh identity import into
ImageConfig, and the abbreviated worklist (ONLY laptop + node rows on offer).

Runs the REAL wizard on Qt's offscreen platform, like test_wizard.py.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import ROLE_CHOICES, image_class  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as lc_mod  # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets  # noqa: E402

from _helpers import advance_to, back_to, check_worklist_rows, pick_mode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

# the canned local mesh every test imports from — pinned so no test depends on the
# checkout's real roster/secrets (deterministic on any host, keys-out/ or not).
CANNED_DOMAIN = "mesh.example.org"
CANNED_USERS = [("superadmin", "superadmin"), ("alice", "admin"), ("bob", "user")]


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _canned_local_mesh(monkeypatch):
    monkeypatch.setattr(lc_mod, "local_mesh_identity",
                        lambda _gd: (CANNED_DOMAIN, list(CANNED_USERS)))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()


def _confirm_and_enter_mesh_chain(wiz):
    """Route Mode -> LocalCloudNodesPage, tick the k8s gate, and step into the
    abbreviated mesh chain. Returns the gate page."""
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    page.confirm.setChecked(True)
    wiz.next()
    return page


# ---- routing: the card reaches the page for the new slug -------------------------

def test_mode_card_routes_to_the_gate_page_for_the_new_slug(wiz):
    pick_mode(wiz, "localcloud")
    before = wiz.cfg.mode
    advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert wiz.currentId() == wiz._page_ids["localcloud"]   # the page IS the new slug
    assert wiz.localcloud_selected is True
    assert wiz.localmesh_selected is False
    assert wiz.phone_selected is False
    assert wiz.quest_selected is False
    assert wiz.deploy_selected is False
    assert wiz.qemu_selected is False
    # nothing is committed until the gate is confirmed: cfg.mode untouched, and the
    # sibling side-flow pages were skipped, not visited.
    assert wiz.cfg.mode == before
    for slug in ("localmesh", "phone", "quest", "deploy", "qemu"):
        assert not wiz.hasVisitedPage(wiz._page_ids[slug])


def test_other_flows_skip_the_gate_page(wiz):
    """A plain image flow never routes through the localcloud gate (applies_to)."""
    pick_mode(wiz, "mesh")
    advance_to(wiz, wizard_mod.WorklistPage)
    assert not wiz.hasVisitedPage(wiz._page_ids["localcloud"])


# ---- the k8s gate ------------------------------------------------------------------

def test_confirmation_gates_progression(wiz):
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    # the gate is INLINE and modeless: unticked -> Next disabled AND validate refuses
    assert page.isComplete() is False
    here = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == here                     # stayed: validatePage refused
    assert wiz.cfg.mode != "mesh"                      # nothing committed either
    page.confirm.setChecked(True)
    assert page.isComplete() is True
    wiz.next()
    assert wiz.currentId() != here
    # confirming commits the mesh chain and lands on its first page (idp)
    assert wiz.cfg.mode == "mesh"
    assert isinstance(wiz.currentPage(), wizard_mod.IdpPage)


def test_gate_names_the_k8s_stop_and_is_reasked_on_reentry(wiz):
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert "k8s will stop to proceed" in page.confirm.text()
    page.confirm.setChecked(True)
    wiz.next()
    # walking Back out and forward in again re-asks the confirmation: initializePage
    # clears the box (consent is the page's point, never remembered).
    back_to(wiz, wizard_mod.ModePage)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert page.confirm.isChecked() is False
    assert page.isComplete() is False


# ---- the identity import -----------------------------------------------------------

def test_imported_domain_and_users_land_in_the_config(wiz):
    _confirm_and_enter_mesh_chain(wiz)
    cfg = wiz.cfg
    assert cfg.cluster_domain == CANNED_DOMAIN         # the imported apex
    by_name = {u.username: u for u in cfg.users}
    assert set(by_name) == {"superadmin", "alice", "bob"}
    # superadmins belong to the orchestration superdomain (UsersPage locks them
    # there); everyone else lands on the imported apex.
    assert by_name["superadmin"].role == "superadmin"
    assert by_name["superadmin"].domain == cfg.effective_superdomain()
    assert by_name["alice"].role == "admin" and by_name["alice"].domain == CANNED_DOMAIN
    assert by_name["bob"].role == "user" and by_name["bob"].domain == CANNED_DOMAIN
    # the users TABLE becomes reachable so the import is visible + editable
    assert cfg.configure_users is True


def test_import_is_one_shot_across_collect_all_reruns(wiz):
    """collect_all() re-runs validatePage on every visited page — the import must be
    latched so a later operator edit (e.g. the cluster domain on the Network step)
    is not clobbered, and the users are never duplicated."""
    page = _confirm_and_enter_mesh_chain(wiz)
    cfg = wiz.cfg
    cfg.cluster_domain = "edited.example.org"
    assert page.validatePage() is True                 # the collect_all() re-run
    assert cfg.cluster_domain == "edited.example.org"  # edit survived
    assert len(cfg.users) == len(CANNED_USERS)         # no duplicates


# ---- the abbreviated worklist -------------------------------------------------------

def test_allowed_roles_are_exactly_laptop_plus_the_node_class(wiz):
    allowed = set(lc_mod.LOCALCLOUD_ALLOWED_ROLES)
    mesh_roles = {r for r, _p, _l in ROLE_CHOICES["mesh"]}
    assert allowed <= mesh_roles
    assert "laptop" in allowed
    assert all(image_class("mesh", r) == "node" for r in allowed - {"laptop"})
    # every OTHER desktop variant is out (that is the abbreviation)
    assert {r for r in mesh_roles - allowed} == {
        r for r in mesh_roles if image_class("mesh", r) == "desktop" and r != "laptop"}


def test_worklist_offers_only_laptop_and_node_rows(wiz):
    _confirm_and_enter_mesh_chain(wiz)
    assert tuple(wiz.worklist_role_allow) == lc_mod.LOCALCLOUD_ALLOWED_ROLES
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    allowed = set(lc_mod.LOCALCLOUD_ALLOWED_ROLES)
    for rid, item in wl.rows.items():
        role = wl._id_axes[rid][0]
        assert item.isHidden() == (role not in allowed), rid
    # the no-mesh-role info rows stay hidden and their disclosure is withdrawn
    assert all(item.isHidden() for item in wl._info_items)
    assert not wl.show_non_mesh.isVisible()


def test_worklist_restriction_holds_in_validate_too(wiz):
    """The arch/search filter is presentation-only ('a hidden checked row still
    builds'), so the restriction must also hold at collection: a disallowed row can
    never ride a programmatic/stale check into the built worklist."""
    _confirm_and_enter_mesh_chain(wiz)
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86", "laptop.x86", "desktop.x86")
    # name the laptop's person so the laptop entry itself is valid
    wl._desktop_people["laptop.x86"] = ("magus", "user")
    wl._refresh_people_table()
    assert wl.validatePage() is True
    ids = [e.id for e in wiz.worklist.entries]
    assert "omnibus.x86" in ids and "laptop.x86" in ids
    assert "desktop.x86" not in ids                    # disallowed: never collected


def test_restriction_lifts_when_another_mode_is_picked(wiz):
    _confirm_and_enter_mesh_chain(wiz)
    assert wiz.worklist_role_allow is not None
    back_to(wiz, wizard_mod.ModePage)
    pick_mode(wiz, "mesh")                             # a plain mesh flow instead
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    assert wiz.worklist_role_allow is None
    # the full catalog is back on offer: a desktop variant row is visible again
    assert not wl.rows["desktop.x86"].isHidden()
    assert wl.show_non_mesh.isVisible()
