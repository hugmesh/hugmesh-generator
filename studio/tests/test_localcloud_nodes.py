"""LocalCloudNodesPage (issue #50, items 3-5) — the "create nodes for local cloud"
gate: routing off the ModePage card, the INLINE k8s-will-stop confirmation (modeless
— no QMessageBox/exec in page logic), the TEARDOWN that confirmation arms, the
local-mesh identity import into ImageConfig, and the abbreviated worklist (ONLY
laptop + node rows on offer).

Runs the REAL wizard on Qt's offscreen platform, like test_wizard.py. Nothing here
talks to kind: both k8s seams (``local_k8s_running`` / ``local_k8s_teardown``) are
stubbed, so the suite is deterministic on a host with or without a live cluster and
no test can delete one.
"""
import os
import threading
import time

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
CANNED_USERS = [("superadmin", ["superadmin"]),
                ("alice", ["admin", "games"]),
                ("bob", "user")]          # a bare string still loads (#228 back-compat)


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _canned_local_mesh(monkeypatch):
    monkeypatch.setattr(lc_mod, "local_mesh_identity",
                        lambda _gd: (CANNED_DOMAIN, list(CANNED_USERS)))


@pytest.fixture
def k8s_state():
    """The modelled host's k8s truth, mutable per test: {"up": bool}. A teardown stub
    flips it the way a real `kind delete cluster` would."""
    return {"up": False}


@pytest.fixture(autouse=True)
def _canned_k8s(monkeypatch, k8s_state):
    """No cluster unless a test says otherwise. The page probes the REAL host on entry,
    so without this a dev box running `hugmesh-local` would change what every other
    test here sees — and the teardown seam is stubbed in the same breath so no test can
    ever delete the operator's cluster."""
    def _never(_gd, on_line=None, cancel=None):
        raise AssertionError("local_k8s_teardown called without a test stubbing it")

    monkeypatch.setattr(lc_mod, "local_k8s_running", lambda _gd: k8s_state["up"])
    monkeypatch.setattr(lc_mod, "local_k8s_teardown", _never)


def _wait_until(qapp, pred, timeout_s: float = 5.0) -> bool:
    """Pump the event loop until ``pred()`` or the ceiling. The page's k8s answers and
    verb results arrive as QUEUED signals off worker threads, so a headless test has to
    let the loop breathe rather than assert on the instant after the call."""
    deadline = time.monotonic() + timeout_s
    while not pred() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return bool(pred())


def _settled(wiz, qapp):
    """Route to the gate page and wait for its entry probe to answer."""
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert _wait_until(qapp, lambda: page._k8s_up is not None), "k8s probe never answered"
    return page


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


#: The page's background threads — its k8s entry probe and the teardown worker.
_THREAD_ATTRS = ("_k8s_probe", "worker")


def _drain(page, qapp, timeout_ms: int = 5000):
    """Join every background thread the page owns and deliver what they posted.

    "Never let a live QThread outlive its page: destroying one aborts under Qt" — the
    same teardown rule test_localmesh_page_entry_offthread.py states. Skipping this
    SEGFAULTED this file: the first test to pump the event loop delivered the earlier
    wizards' queued probe answers into pages that had already been collected."""
    for name in _THREAD_ATTRS:
        try:
            t = getattr(page, name, None)
            if t is not None:
                t.wait(timeout_ms)
        except RuntimeError:            # C++ side already gone — nothing to join
            pass
    qapp.processEvents()


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    _drain(w.page(w._page_ids["localcloud"]), qapp)
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
    assert wiz.e2e_selected is False
    assert wiz.qemu_selected is False
    # nothing is committed until the gate is confirmed: cfg.mode untouched, and the
    # sibling side-flow pages were skipped, not visited.
    assert wiz.cfg.mode == before
    for slug in ("localmesh", "phone", "quest", "deploy", "e2e", "qemu"):
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


# ---- the k8s teardown the confirmation arms (issue #50 item 4) ----------------------

def test_no_cluster_means_nothing_to_stop(wiz, qapp):
    """The common case: no DevOps lane running. The destructive button stays dark and
    the gate is the consent alone — exactly the behaviour before the teardown landed."""
    page = _settled(wiz, qapp)
    assert page._k8s_up is False
    page.confirm.setChecked(True)
    assert page.down_btn.isEnabled() is False
    assert page.isComplete() is True
    assert "nothing to stop" in page.gate_note.text()


def test_a_running_cluster_holds_next_until_it_is_stopped(wiz, qapp, k8s_state):
    """THE issue-4 requirement: with k8s up, ticking the box is no longer enough to
    proceed — it ARMS the teardown, and Next stays shut until the cluster is gone."""
    k8s_state["up"] = True
    page = _settled(wiz, qapp)
    page.confirm.setChecked(True)
    assert page.down_btn.isEnabled() is True       # consent ARMS the destructive verb
    assert page.isComplete() is False              # ... and does not substitute for it
    here = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == here                 # stayed: validatePage refused too
    assert wiz.cfg.mode != "mesh"                  # nothing committed on a live cluster


def test_the_teardown_never_runs_without_the_consent(wiz, qapp, k8s_state, monkeypatch):
    """Nothing on this page may delete a cluster unasked — not from the button (it is
    unarmed) and not from a programmatic call."""
    ran = []

    def fake_teardown(gd, on_line=None, cancel=None):
        ran.append(gd)
        return True, ""

    monkeypatch.setattr(lc_mod, "local_k8s_teardown", fake_teardown)
    k8s_state["up"] = True
    page = _settled(wiz, qapp)
    assert page.down_btn.isEnabled() is False
    page.down_btn.click()
    page._stop_k8s()                               # even called directly it refuses
    assert ran == []
    assert page._running is False


def test_stopping_kubernetes_runs_the_verb_off_thread_and_opens_the_gate(
        wiz, qapp, k8s_state, monkeypatch):
    """The wiring end to end: the press runs the real `make kind-down` seam on a WORKER
    (the click returns with the verb still in flight — a synchronous call here would
    freeze the wizard for the minutes a teardown takes), streams its output into the
    page's console, and the gate opens only once the RE-PROBE says the cluster is gone."""
    calls = []

    def fake_teardown(gd, on_line=None, cancel=None):
        calls.append(gd)
        on_line("deleting cluster \"hugmesh-local\" ...")
        k8s_state["up"] = False                    # what a real kind-down leaves behind
        return True, ""

    monkeypatch.setattr(lc_mod, "local_k8s_teardown", fake_teardown)
    k8s_state["up"] = True
    page = _settled(wiz, qapp)
    page.confirm.setChecked(True)
    page.down_btn.click()
    assert page._running is True                   # off-thread: the click already returned
    assert page.isComplete() is False              # ... and Next is held while it streams
    assert _wait_until(qapp, lambda: not page._running), "teardown never finished"
    assert calls == [wiz.generator_dir]
    assert "deleting cluster" in page.log.toPlainText()
    assert _wait_until(qapp, lambda: page._k8s_up is False), "gate never re-probed"
    assert page.isComplete() is True
    wiz.next()
    assert wiz.cfg.mode == "mesh"                  # and the abbreviated wizard continues
    assert isinstance(wiz.currentPage(), wizard_mod.IdpPage)


def test_a_failed_teardown_keeps_the_gate_shut(wiz, qapp, k8s_state, monkeypatch):
    """`make kind-down` failing must NOT be reported as a stopped cluster: the gate
    stays shut, the button re-arms for a retry, and the log says so."""
    monkeypatch.setattr(lc_mod, "local_k8s_teardown",
                        lambda gd, on_line=None, cancel=None: (False, "boom"))
    k8s_state["up"] = True                         # ... and it stays up
    page = _settled(wiz, qapp)
    page.confirm.setChecked(True)
    page.down_btn.click()
    assert _wait_until(qapp, lambda: not page._running), "teardown never finished"
    assert "FAILED" in page.log.toPlainText()
    assert page.isComplete() is False
    assert _wait_until(qapp, lambda: page.down_btn.isEnabled()), "retry never re-armed"


def test_entering_the_page_does_not_block_on_the_probe(wiz, qapp, monkeypatch):
    """`kind get clusters` shells out (15 s ceiling). initializePage must not wait on
    it: the page renders with the answer still unknown, and unknown is rendered as
    unknown — never as a claim about the operator's cluster."""
    released = threading.Event()
    monkeypatch.setattr(lc_mod, "local_k8s_running",
                        lambda _gd: (released.wait(5.0), False)[1])
    pick_mode(wiz, "localcloud")
    t0 = time.monotonic()
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    entry_s = time.monotonic() - t0
    try:
        assert entry_s < 1.0, f"initializePage blocked on the probe for {entry_s:.1f}s"
        assert page._k8s_up is None
        assert "Checking" in page.gate_note.text()
    finally:
        released.set()
        _wait_until(qapp, lambda: page._k8s_up is not None)


# ---- the identity import -----------------------------------------------------------

def test_imported_domain_and_users_land_in_the_config(wiz):
    _confirm_and_enter_mesh_chain(wiz)
    cfg = wiz.cfg
    assert cfg.cluster_domain == CANNED_DOMAIN         # the imported apex
    by_name = {u.username: u for u in cfg.users}
    assert set(by_name) == {"superadmin", "alice", "bob"}
    # superadmins belong to the Tailscale root domain (UsersPage locks them
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
