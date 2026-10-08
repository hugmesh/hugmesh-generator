"""LocalCloudNodesPage (issue #50, items 3-5) — the "create nodes for local cloud"
gate: routing off the ModePage card, the INLINE k8s-will-stop confirmation (modeless
— no QMessageBox/exec in page logic), the TEARDOWN that confirmation arms, the
local-mesh identity import into ImageConfig, and the abbreviated worklist (ONLY
laptop + node rows on offer).

Runs the REAL wizard on Qt's offscreen platform, like test_wizard.py. Nothing here
talks to kind: both k8s override points (``local_k8s_running`` / ``local_k8s_teardown``) are
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


#: The REAL reader, kept before the autouse fixture below cans it — the #579 tests
#: put it back so at least one path reads an actual saved-mesh record off disk.
_REAL_IDENTITY = lc_mod.local_mesh_identity


@pytest.fixture(autouse=True)
def _canned_local_mesh(monkeypatch):
    # (domain, users, with_tor) — the canned mesh ran no Tor.
    monkeypatch.setattr(lc_mod, "local_mesh_identity",
                        lambda _gd: (CANNED_DOMAIN, list(CANNED_USERS), False))


@pytest.fixture
def k8s_state():
    """The modelled host's k8s truth, mutable per test: {"up": bool}. A teardown stub
    flips it the way a real `kind delete cluster` would."""
    return {"up": False}


@pytest.fixture(autouse=True)
def _canned_k8s(monkeypatch, k8s_state):
    """No cluster unless a test says otherwise. The page probes the REAL host on entry,
    so without this a dev box running `hugmesh-local` would change what every other
    test here sees — and the teardown override point is stubbed in the same breath so no test can
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
    """The wiring end to end: the press runs the real `make kind-down` override point on a WORKER
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


# ---- #579: a saved mesh that ran Tor reaches the node images ----------------------
# THE ASSERTION THE OPERATOR ASKED FOR, at the two levels that can run without a
# build (the image build itself is not run here — the builders are argv-pinned):
# a saved record whose services include `tor`, imported through this gate and built
# as an x86 row + an rpi5 row, yields builder argv that bakes the onion on BOTH, and
# the package preview (the surface an operator reads "does this image include tor"
# from) lists net-vpn/tor for both.
import socket  # noqa: E402

from hugmesh_studio.core import package_catalog as pc  # noqa: E402
from hugmesh_studio.core import saved_meshes as sm  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import (  # noqa: E402
    LocalMeshBootstrapConfig,
)


def _save_record(tmp_path, *, services, with_tor=False, domain="saved.example.org"):
    cfg = LocalMeshBootstrapConfig(
        env="prod", cluster_domain=domain, out_dir=str(tmp_path / "keys"),
        services=services, with_tor=with_tor, social="tuwunel" in (services or ()))
    rec = sm.SavedMesh(id=sm.new_id(), label="tor-mesh", generator_dir=GENERATOR_DIR,
                       hostname=socket.gethostname(), config=cfg.to_dict())
    assert sm.save(rec), "the record must land in the isolated state dir"
    return rec


def _real_reader(monkeypatch):
    monkeypatch.setattr(lc_mod, "local_mesh_identity", _REAL_IDENTITY)


def _argv_and_atoms(wiz):
    out = {}
    for entry, cfg in wiz.worklist.materialize():
        out[entry.id] = (cfg.to_cli_args(), pc.adhoc_atoms(cfg))
    return out


def _optional_services(argv):
    assert "--optional-services" in argv, argv
    return argv[argv.index("--optional-services") + 1].split()


def test_saved_tor_mesh_builds_tor_into_x86_and_rpi5_node_images(wiz, monkeypatch,
                                                                  tmp_path):
    _save_record(tmp_path, services=("tuwunel", "tor"))
    _real_reader(monkeypatch)                          # NOT canned: the record is read
    page = _confirm_and_enter_mesh_chain(wiz)
    assert page._with_tor is True
    assert "tor-mesh" in page._source                  # says which record it read
    assert wiz.cfg.cluster_domain == "saved.example.org"
    assert wiz.cfg.tor_onion_service is True           # the bridge, on the base
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "backend.x86", "backend.rpi5")
    assert wl.validatePage() is True
    got = _argv_and_atoms(wiz)
    x86_argv, x86_atoms = got["backend.x86"]
    rpi_argv, rpi_atoms = got["backend.rpi5"]
    assert "--with-tor" in x86_argv
    assert "tor" in _optional_services(rpi_argv)
    # ADDITIVE: the rpi5 node keeps the builder's default services next to tor
    assert {"akkoma", "tuwunel", "phpbb"} <= set(_optional_services(rpi_argv))
    assert "net-vpn/tor" in x86_atoms
    assert "net-vpn/tor" in rpi_atoms


def test_saved_mesh_without_tor_builds_no_tor(wiz, monkeypatch, tmp_path):
    # with_tor=True is the LEGACY flag; the services tuple is the authority and has
    # no tor row, so the saved mesh did not run Tor and the images must not carry it.
    _save_record(tmp_path, services=("tuwunel",), with_tor=True)
    _real_reader(monkeypatch)
    page = _confirm_and_enter_mesh_chain(wiz)
    assert page._with_tor is False
    assert not page.tor_note.isVisible()
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "backend.x86", "backend.rpi5")
    assert wl.validatePage() is True
    for rid, (argv, atoms) in _argv_and_atoms(wiz).items():
        assert "--with-tor" not in argv, rid
        assert "tor" not in (argv[argv.index("--optional-services") + 1].split()
                             if "--optional-services" in argv else []), rid
        assert "net-vpn/tor" not in atoms, rid


def test_tor_note_is_inline_and_names_the_platform_that_cannot_carry_it(
        wiz, monkeypatch):
    monkeypatch.setattr(lc_mod, "local_mesh_identity",
                        lambda _gd: (CANNED_DOMAIN, list(CANNED_USERS), True))
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert page.tor_note.isVisible()                   # an inline label, no modal
    text = page.tor_note.text()
    assert "cannot carry Tor" in text and "jetson" in text
    assert "x86" in text and "rpi5" in text
    assert "Tor onion: <b>on</b>" in page.summary.text()


def test_no_record_imports_the_defaults_with_tor_off(wiz, monkeypatch):
    _real_reader(monkeypatch)                          # empty isolated state dir
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert page._with_tor is False and page._source == ""
    assert "no saved mesh for this checkout" in page.summary.text()
    assert not page.tor_note.isVisible()


def test_a_mesh_without_tor_never_clears_an_operator_tor_choice(wiz):
    # the canned mesh ran no Tor; an operator who already chose Tor keeps it
    wiz.cfg.tor_onion_service = "on"
    _confirm_and_enter_mesh_chain(wiz)
    assert wiz.cfg.tor_onion_service == "on"


def _save_malformed(tmp_path):
    # The newest record for this checkout carries a config from_dict cannot read
    # (services must be a sequence) — a hand-edited or future-format file.
    rec = sm.SavedMesh(id=sm.new_id(), label="broken", generator_dir=GENERATOR_DIR,
                       hostname=socket.gethostname(),
                       config={"env": "prod", "cluster_domain": "bad.example.org",
                               "services": 42})
    assert sm.save(rec), "the record must land in the isolated state dir"
    return rec


def test_a_malformed_newest_record_falls_back_to_the_defaults(wiz, monkeypatch,
                                                              tmp_path):
    # initializePage must not raise out of the wizard on a record it cannot read;
    # it shows the defaults and says no saved mesh was used.
    _save_malformed(tmp_path)
    _real_reader(monkeypatch)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert page._with_tor is False and page._source == ""
    assert "no saved mesh for this checkout" in page.summary.text()
    assert "bad.example.org" not in page.summary.text()


def test_the_imported_record_label_and_domain_are_escaped_in_the_summary(
        wiz, monkeypatch, tmp_path):
    # The summary is RichText; a record label is operator text and must never be
    # rendered as markup.
    rec = _save_record(tmp_path, services=("tuwunel",))
    rec.label = "<b>evil</b> & co"
    assert sm.save(rec)
    _real_reader(monkeypatch)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    text = page.summary.text()
    assert "&lt;b&gt;evil&lt;/b&gt; &amp; co" in text
    assert "<b>evil</b>" not in text


# ---- #636: a local mesh generated with N domains imports ALL of them --------------
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain  # noqa: E402
from hugmesh_studio.core import domain_services as ds  # noqa: E402
from hugmesh_studio.gui.pages import domain_services as dsp_mod  # noqa: E402


def _save_n_domain_record(tmp_path):
    cfg = LocalMeshBootstrapConfig(
        env="prod", cluster_domain="saved.example.org", out_dir=str(tmp_path / "keys"),
        domains=({"name": "saved.example.org", "title": "", "idp": "superdomain",
                  "optional_services": ["games"]},
                 {"name": "a.example", "title": "Alpha", "idp": "superdomain",
                  "optional_services": ["phpbb"]},
                 {"name": "b.example", "title": "Beta", "idp": DOMAIN_IDP_OWN,
                  "optional_services": []}),
        own_idp_domains=("b.example",),
        domain_services_reviewed=("saved.example.org", "a.example"))
    rec = sm.SavedMesh(id=sm.new_id(), label="three-domains",
                       generator_dir=GENERATOR_DIR, hostname=socket.gethostname(),
                       config=cfg.to_dict())
    assert sm.save(rec)


def test_saved_n_domain_mesh_imports_every_domain(wiz, monkeypatch, tmp_path):
    _save_n_domain_record(tmp_path)
    _real_reader(monkeypatch)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    summary = page.summary.text()
    assert "a.example — superdomain sign-in; services: phpbb" in summary
    assert "b.example — own Casdoor" in summary
    page.confirm.setChecked(True)
    wiz.next()
    c = wiz.cfg
    assert c.cluster_domain == "saved.example.org"
    assert [d.name for d in c.domains] == ["a.example", "b.example"]
    assert c.own_idp_domains() == ("b.example",)
    assert c.cluster_domain_services == ["games"]
    assert c.additional_domains is True
    assert c.domain_services_reviewed == ["saved.example.org", "a.example"]


def test_the_imported_domains_survive_the_walk_to_the_build_screen(
        wiz, monkeypatch, tmp_path):
    """The rows must not be cleared by the Domains choice card on the way (it is
    preselected from additional_domains), and the per-domain services step walks
    them — the one never walked on the local mesh included."""
    _save_n_domain_record(tmp_path)
    _real_reader(monkeypatch)
    _confirm_and_enter_mesh_chain(wiz)
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "backend.x86")
    choice = advance_to(wiz, wizard_mod.DomainsChoicePage)
    assert choice._selected() == "more"
    svc = advance_to(wiz, dsp_mod.DomainServicesPage)
    # it resumes on the one domain the local mesh never walked
    assert svc.current_domain() == "b.example"
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    assert [d.name for d in wiz.cfg.domains] == ["a.example", "b.example"]
    assert wiz.cfg.own_idp_domains() == ("b.example",)
    assert launch.gate_refusal() == ""                 # the walk recorded all three
    m = wiz.cfg.mesh_manifest()
    assert [d["name"] for d in m["domains"]] == ["a.example", "b.example"]
    assert m["cluster_domain_services"] == ["games"]


def test_a_one_domain_mesh_imports_no_rows(wiz, monkeypatch, tmp_path):
    _save_record(tmp_path, services=("tuwunel",))
    _real_reader(monkeypatch)
    page = _confirm_and_enter_mesh_chain(wiz)
    assert page._mesh_domains is None
    assert wiz.cfg.domains == [] and wiz.cfg.additional_domains is False


# ---- post-merge review of PR #644: the import must win over what an earlier flow of
# the SAME Studio session left in the image-flow pages' working copies ---------------
# gui/pages/domains.py refills its table only when the config OBJECT changes, and the
# import writes the same object in place; the Domain services walk keeps a working copy
# the same way. On origin/main c882fb67 both survived into the build screen.

def _touch(page):
    if isinstance(page, wizard_mod.WorklistPage):
        check_worklist_rows(page, "backend.x86")


def _walk_to_launch(wiz):
    for _ in range(len(WIZARD_PAGE_SLUGS) + 6):
        page = wiz.currentPage()
        if isinstance(page, wizard_mod.LaunchPage):
            return page
        _touch(page)
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, f"stuck on {type(page).__name__}"
    raise AssertionError("never reached the Launch page")


def _save_named(tmp_path, label, **kw):
    cfg = LocalMeshBootstrapConfig(env="prod", cluster_domain="saved.example.org",
                                   out_dir=str(tmp_path / "keys"), **kw)
    rec = sm.SavedMesh(id=sm.new_id(), label=label, generator_dir=GENERATOR_DIR,
                       hostname=socket.gethostname(), config=cfg.to_dict())
    assert sm.save(rec)
    return rec


def _names(cfg):
    return [d.name for d in cfg.domains]


_AB_ROWS = ({"name": "a.example", "title": "Alpha", "idp": "superdomain",
             "optional_services": ["phpbb"]},
            {"name": "b.example", "title": "Beta", "idp": DOMAIN_IDP_OWN,
             "optional_services": []})


def test_a_second_import_in_the_same_session_carries_the_new_domain_and_the_record(
        wiz, monkeypatch, tmp_path):
    """Create nodes for a 2-domain mesh, Back to the main menu, the mesh is generated
    again with a THIRD domain and a changed selection, create nodes again: the build
    screen must carry the third domain, the record's selection for a.example, and
    treat b.example as unwalked again (the record says so) even though the first pass
    walked it here."""
    _save_named(tmp_path, "A", domains=_AB_ROWS, own_idp_domains=("b.example",),
                domain_services_reviewed=("a.example", "b.example"))
    _real_reader(monkeypatch)
    _confirm_and_enter_mesh_chain(wiz)
    launch = _walk_to_launch(wiz)
    assert _names(wiz.cfg) == ["a.example", "b.example"]
    launch._main_menu()                                  # restart() on the SAME object
    time.sleep(1.2)                                      # the record id is time-sortable
    _save_named(tmp_path, "B",
                domains=({"name": "a.example", "title": "Alpha", "idp": "superdomain",
                          "optional_services": ["akkoma"]},
                         _AB_ROWS[1],
                         {"name": "c.example", "title": "Gamma", "idp": "superdomain",
                          "optional_services": ["akkoma"]}),
                own_idp_domains=("b.example",),
                domain_services_reviewed=("saved.example.org", "a.example", "c.example"))
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert "c.example" in page.summary.text(), "fixture: the summary must list c.example"
    page.confirm.setChecked(True)
    wiz.next()
    assert _names(wiz.cfg) == ["a.example", "b.example", "c.example"]
    svc = advance_to(wiz, dsp_mod.DomainServicesPage)
    assert svc.current_domain() == "b.example", "the record never walked b.example"
    _walk_to_launch(wiz)
    assert _names(wiz.cfg) == ["a.example", "b.example", "c.example"], \
        "the third domain was dropped on the way to the build screen"
    by = {d.name: d for d in wiz.cfg.domains}
    assert by["a.example"].optional_services == ["akkoma"], \
        "the first import's selection was written back over the record's"
    m = wiz.cfg.mesh_manifest()
    assert [d["name"] for d in m["domains"]] == ["a.example", "b.example", "c.example"]


def test_an_import_after_an_earlier_mesh_flow_builds_only_the_imported_domains(
        wiz, monkeypatch, tmp_path):
    """A plain 'Mesh node' flow with one hand-added row up to the build screen, Back to
    the main menu, then 'Create nodes for local cloud' for a saved 3-domain mesh: the
    build screen must carry the saved mesh's rows, not the earlier flow's."""
    from _helpers import enable_additional_domains
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "backend.x86")
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("x.example", "X")
    launch = _walk_to_launch(wiz)
    assert _names(wiz.cfg) == ["x.example"]
    launch._main_menu()
    _save_named(tmp_path, "three-domain", domains=_AB_ROWS,
                own_idp_domains=("b.example",), domain_services_reviewed=("a.example",))
    _real_reader(monkeypatch)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    assert "a.example" in page.summary.text() and "b.example" in page.summary.text()
    page.confirm.setChecked(True)
    wiz.next()
    assert _names(wiz.cfg) == ["a.example", "b.example"], "fixture: the import wrote them"
    _walk_to_launch(wiz)
    assert _names(wiz.cfg) == ["a.example", "b.example"], (
        f"the build screen carries {_names(wiz.cfg)}: the earlier flow's table won")


def test_the_page_names_a_saved_row_the_import_will_not_take(wiz, monkeypatch, tmp_path):
    """A record edited by hand: a row whose name is no lowercase hostname, or whose
    sign-in the configuration does not know, is not imported. The page the operator
    reads BEFORE ticking the consent names each one (never lists it as if it would
    come), and the build screen carries only the rows the import took — in a
    configuration that still survives a save/load round trip."""
    _save_named(tmp_path, "hand-edited",
                domains=({"name": "Bad.Example", "title": "", "idp": "superdomain",
                          "optional_services": []},
                         {"name": "c.example", "title": "", "idp": "nonsense",
                          "optional_services": []},
                         _AB_ROWS[1]),
                own_idp_domains=("b.example",))
    _real_reader(monkeypatch)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    text = page.summary.text()
    assert "Bad.Example — NOT imported: not a domain name" in text
    assert "c.example — NOT imported: sign-in" in text and "nonsense" in text
    assert "b.example — own Casdoor" in text
    page.confirm.setChecked(True)
    wiz.next()
    assert _names(wiz.cfg) == ["b.example"]
    _walk_to_launch(wiz)
    assert _names(wiz.cfg) == ["b.example"]
    type(wiz.cfg).from_dict(wiz.cfg.to_dict())       # a kept bad sign-in raises here


def test_a_hand_edited_row_name_and_sign_in_are_escaped_in_the_summary(
        wiz, monkeypatch, tmp_path):
    """The summary is RichText and the "NOT imported" lines carry two strings nobody
    validated: the row's name and its sign-in, both from a record a person can edit by
    hand. Neither may ever be drawn as markup (the escape sits on the whole line, so
    this pins both fields and the em dash text around them)."""
    _save_named(tmp_path, "markup",
                domains=({"name": "<b>x</b>.example", "title": "", "idp": "superdomain",
                          "optional_services": []},
                         {"name": "c.example", "title": "", "idp": "<i>y</i>&",
                          "optional_services": []}),
                own_idp_domains=())
    _real_reader(monkeypatch)
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    text = page.summary.text()
    assert "NOT imported" in text, "fixture: the rows must reach the summary"
    assert "&lt;b&gt;x&lt;/b&gt;.example" in text
    assert "<b>x</b>" not in text
    assert "&lt;i&gt;y&lt;/i&gt;&amp;" in text
    assert "<i>" not in text


def test_a_forgotten_domains_table_writes_nothing_until_it_is_entered_again(
        wiz, monkeypatch, tmp_path):
    """collect_all() re-runs every visited page's validatePage. After the import told
    the Domains table to forget its rows, that re-run must not rebuild cfg.domains
    from the (now empty) table — the import's rows stay until the page is walked."""
    _save_named(tmp_path, "three-domain", domains=_AB_ROWS,
                own_idp_domains=("b.example",), domain_services_reviewed=("a.example",))
    _real_reader(monkeypatch)
    _confirm_and_enter_mesh_chain(wiz)
    dom = wiz.page(wiz._page_ids["domains"])
    assert dom._cfg_seen is None and dom.table.rowCount() == 0
    assert dom.validatePage() is True
    assert _names(wiz.cfg) == ["a.example", "b.example"]
    svc = wiz.page(wiz._page_ids["domain_services"])
    assert svc._cfg_seen is None
    svc.validatePage()
    assert wiz.cfg.domain_services_reviewed == ["a.example"]   # the record's markers


def test_telling_the_pages_is_not_a_crash_when_the_wizard_lacks_one():
    """_forget_domain_pages asks the wizard's page registry by slug. A wizard without
    the registry, or without one of the two pages, or with a page that has no such
    method, must not turn an import into an AttributeError."""
    from types import SimpleNamespace
    forget = lc_mod.LocalCloudNodesPage._forget_domain_pages
    forget(SimpleNamespace(wiz=SimpleNamespace()))                  # no registry at all
    told = []
    pages = {1: SimpleNamespace(forget_rows=lambda: told.append("rows")),
             2: object()}                                           # no forget_answers
    forget(SimpleNamespace(wiz=SimpleNamespace(
        _page_ids={"domains": 1, "domain_services": 2}, page=pages.get)))
    forget(SimpleNamespace(wiz=SimpleNamespace(
        _page_ids={"domains": 1}, page=pages.get)))                 # no services page
    assert told == ["rows", "rows"], "the page that has the method was not told"


def test_forgetting_cuts_off_a_table_and_a_walk_that_were_already_filled(
        wiz, monkeypatch, tmp_path):
    """The case above is a page that was never entered, where "forgotten" and "never
    filled" look alike. This one walks the image flow first, so both pages hold a
    working copy of THIS configuration, and then the gate tells them the rows were
    replaced (what a second import does): each must drop its copy — the table its
    rows, both their claim on the configuration — and until they are entered again a
    validatePage() must leave what the import wrote exactly as it was."""
    _save_named(tmp_path, "three-domain", domains=_AB_ROWS,
                own_idp_domains=("b.example",), domain_services_reviewed=("a.example",))
    _real_reader(monkeypatch)
    gate = _confirm_and_enter_mesh_chain(wiz)
    _walk_to_launch(wiz)
    dom = wiz.page(wiz._page_ids["domains"])
    svc = wiz.page(wiz._page_ids["domain_services"])
    assert dom._cfg_seen is wiz.cfg and dom.table.rowCount() > 0, "fixture: filled"
    assert svc._cfg_seen is wiz.cfg, "fixture: entered"
    rows_before = _names(wiz.cfg)
    marks_before = list(wiz.cfg.domain_services_reviewed)
    assert rows_before == ["a.example", "b.example"] and marks_before

    gate._forget_domain_pages()

    assert dom.table.rowCount() == 0, "the Domains table kept its rows"
    assert dom._cfg_seen is None, "the Domains table kept its claim on the config"
    assert svc._cfg_seen is None, "the Domain services walk kept its claim"
    assert dom.validatePage() is True
    assert svc.validatePage() is True
    assert _names(wiz.cfg) == rows_before, "a forgotten table rewrote the rows"
    assert list(wiz.cfg.domain_services_reviewed) == marks_before, \
        "a forgotten walk rewrote the markers"


# ---- #661 / #647 / #656 rule: the page is LOOKED AT, two styles, 8 pt as well -------
from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS  # noqa: E402

from _look import (LOOK_CASES, LOOK_IDS, DEFAULT_WINDOW, assert_fits,  # noqa: E402
                   assert_inside, assert_page_fits_its_window,
                   assert_seen_without_scrolling, assert_whole, child_only, looking,
                   settle, snap)


@pytest.mark.parametrize(("style", "pt"), LOOK_CASES, ids=LOOK_IDS)
def test_look_the_page_fits_its_window_and_every_line_is_drawn_whole(
        qapp, monkeypatch, tmp_path, style, pt):
    """#661: on main the consent sentence sat on a QCheckBox, which never wraps, so
    the page was 804 px wide in a 736 px window and every line was cut at the right
    edge with no sideways scroll. Now: nothing reaches past the viewport, the consent
    box and its wrapped sentence are whole, and so are the imported-domain lines."""
    child_only()
    _save_n_domain_record(tmp_path)
    _real_reader(monkeypatch)
    with looking(qapp, style, pt):
        w = wizard_mod.StudioWizard(GENERATOR_DIR)
        w.show()
        try:
            pick_mode(w, "localcloud")
            page = advance_to(w, wizard_mod.LocalCloudNodesPage)
            assert _wait_until(qapp, lambda: page._k8s_up is not None)
            settle(qapp)
            assert (w.width(), w.height()) == DEFAULT_WINDOW
            assert_page_fits_its_window(page)
            assert_fits(page.confirm, "the consent tick-box")
            assert_inside(page, page.confirm_text, "the consent sentence")
            assert_whole(page.confirm_text, "the consent sentence")
            assert page.confirm_text.width() >= 300, "the sentence is squeezed"
            assert_whole(page.summary, "the imported-mesh summary")
            assert "b.example — own Casdoor" in page.summary.text()
            assert_whole(page.gate_note, "the k8s gate note")
            # the consent line and the gate note are what the page is for: seen
            # whole, without scrolling, as the page opens
            assert_seen_without_scrolling(page, page.confirm, "the consent tick-box")
            assert_seen_without_scrolling(page, page.confirm_text,
                                          "the consent sentence")
            assert_seen_without_scrolling(page, page.gate_note, "the k8s gate note")
            snap(w, "localcloud-nodes", style, pt)
        finally:
            _drain(page, qapp)
            w.close()
            w.deleteLater()
            settle(qapp)


def test_the_consent_sentence_is_one_control_with_its_box(wiz, qapp):
    """Clicking the wrapped sentence ticks the box (#661 moved the words off the box;
    the line must still behave as the one control it was)."""
    from hugmesh_studio.gui.qt import QtCore, QtGui
    page = _settled(wiz, qapp)
    assert "k8s will stop to proceed" in page.confirm.text()
    assert page.confirm_text.text().startswith("—")
    assert not page.confirm.isChecked()

    def click(widget):
        pos = QtCore.QPointF(3.0, 3.0)
        for kind in (QtCore.QEvent.Type.MouseButtonPress,
                     QtCore.QEvent.Type.MouseButtonRelease):
            ev = QtGui.QMouseEvent(kind, pos, Qt.MouseButton.LeftButton,
                                   Qt.MouseButton.LeftButton,
                                   Qt.KeyboardModifier.NoModifier)
            qapp.sendEvent(widget, ev)
        qapp.processEvents()

    click(page.confirm_text)
    assert page.confirm.isChecked()
    click(page.confirm_text)
    assert not page.confirm.isChecked()
