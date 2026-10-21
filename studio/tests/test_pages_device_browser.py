"""ARCH-FIRST device browser (device-catalog restructure on top of the machine-first
cards): the architecture selector, the family-grouped searchable device tree, the #351
honesty gates (UNSUPPORTED visible-but-unselectable with reason, EXPERIMENTAL labelled,
rpi3 desktop-only), and — the overriding guard — EMISSION IDENTITY: for every
board/role selectable before, driving the new browser yields the SAME
cfg.platform/role/board/flavor and the SAME ``to_cli_args()`` argv the machine-card +
board-combo flow produced (goldens pinned from main c5a3d56).

Skipped whole when no Qt binding is installed (the rest of the suite stays pure-core).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import device_catalog  # noqa: E402
from hugmesh_studio.core.config import ROLE_CHOICES  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.worklist import _COL_NOTES  # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtGui, QtWidgets  # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode  # noqa: E402

# ask 13 ("cached iso, live iso, bundle, compress and resume should all be default on")
# put --compress/--resume on EVERY platform's argv: both are all-platform fields, so every
# golden here gains the same two-token tail. Named rather than inlined so the next default
# change is one edit. Mirrors tests/test_cli_args.ALL_TAIL.
ALL_TAIL = ["--compress", "--resume"]

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

CAT = device_catalog.load_catalog()


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _role_ids(page):
    return [page.roles.item(i).data(Qt.ItemDataRole.UserRole)[0]
            for i in range(page.roles.count())]


def _pickable(page, did):
    return bool(page._device_items[did].flags() & Qt.ItemFlag.ItemIsSelectable)


# ── the arch tier ─────────────────────────────────────────────────────────────────

def test_arch_selector_renders_only_populated_archs_and_defaults_to_x86(wiz):
    """Extensible enum: every arch with >=1 device gets a button (armv7/riscv64 exist —
    they carry UNSUPPORTED listings); a fresh standalone flow defaults to x86-64."""
    page = advance_to(wiz, wizard_mod.RolePage)
    assert set(page._arch_buttons) == {a.id for a in CAT.archs
                                       if CAT.devices_for_arch(a.id)}
    assert {"x86-64", "arm64"} <= set(page._arch_buttons)
    assert page._arch_buttons["x86-64"].isChecked()
    assert page._selected_device() == "x86-pc"


def test_arch_toggle_filters_families_and_hops_to_a_selectable_device(wiz):
    """Toggling ARM64 hides the x86 family and moves the selection to a pickable ARM
    device (presentation only until validatePage)."""
    page = advance_to(wiz, wizard_mod.RolePage)
    page._arch_buttons["arm64"].setChecked(True)
    assert page._family_items["x86-pcs"].isHidden()
    assert not page._family_items["raspberry-pi"].isHidden()
    did = page._selected_device()
    assert did is not None and CAT.device(did).arch == "arm64"
    assert _pickable(page, did)


# ── family-grouped searchable browser + honesty gates ───────────────────────────────

def test_search_potato_filters_to_libre_computer(wiz):
    page = advance_to(wiz, wizard_mod.RolePage)
    page._arch_buttons["arm64"].setChecked(True)
    page.device_search.setText("potato")
    assert not page._device_items["le-potato"].isHidden()
    assert not page._device_items["sweet-potato"].isHidden()
    assert page._device_items["rpi5"].isHidden()
    assert page._family_items["raspberry-pi"].isHidden()
    assert not page._family_items["libre-computer"].isHidden()
    page.device_search.setText("")
    assert not page._device_items["rpi5"].isHidden()


def test_unsupported_device_visible_unselectable_with_reason(wiz):
    """#351: bpi-m5 (and the whole unsupported tier) is LISTED, carries its honest
    reason, and can never be selected for a build."""
    page = advance_to(wiz, wizard_mod.RolePage)
    page._arch_buttons["arm64"].setChecked(True)
    for did in ("bpi-m5", "rpi6", "opi4", "rk3588-generic"):
        item = page._device_items[did]
        assert not item.isHidden() or CAT.device(did).arch != "arm64"
        assert not _pickable(page, did), did
        dev = CAT.device(did)
        assert dev.reason and dev.reason in item.text(2), did
        assert dev.reason in item.toolTip(0), did
    # selecting it programmatically must not steal the role list either
    before = page._selected_device()
    page.select_device("bpi-m5")
    assert page._selected_device() in (before, None) or \
        not device_catalog.selectable(page._selected_device())
    assert page.roles.count() > 0   # role list still belongs to a buildable device


def test_experimental_devices_are_pickable_and_labelled(wiz):
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    for did in ("orange-pi-5", "orange-pi-zero2", "rpi400"):
        assert _pickable(page, did), did
        assert "EXPERIMENTAL" in page._device_items[did].text(2), did


def test_rpi3_desktop_only_gate_cloud_and_standalone(wiz):
    """The rpi3 DEVICE derives exactly the desktop image on the client path and
    NOTHING standalone — the builder's hard-error gate, now structural."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    page.select_device("rpi3")
    assert _role_ids(page) == ["rpi5-desktop"]
    # go back and re-enter standalone: rpi3 is unpickable there, with the explanation
    wiz.back(); wiz.back()
    pick_mode(wiz, "standalone")
    page = advance_to(wiz, wizard_mod.RolePage)
    assert not _pickable(page, "rpi3")
    assert "no standalone image" in page._device_items["rpi3"].text(2)


def test_chromebook_device_offers_exactly_its_narrowed_role(wiz):
    """role_allow only NARROWS: the chromebook device derives exactly the chromebook
    role (ADR-16) in both single-image modes."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    page.select_device("chromebook")
    assert _role_ids(page) == ["chromebook"]


def test_device_pins_the_board_combo_readonly(wiz):
    """One machine picker per flow: selecting a board-bearing device pins the old
    per-platform board combo to that device's board, read-only."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    page.select_device("rpi4")
    assert page.rpi5_board.currentText() == "rpi4"
    assert not page.rpi5_board.isEnabled()


# ── keyboard nav / no-device states must NEVER emit (#351 at the Next button) ──────

def _press(widget, qt_key):
    QtWidgets.QApplication.sendEvent(
        widget, QtGui.QKeyEvent(QtGui.QKeyEvent.Type.KeyPress, qt_key,
                                Qt.KeyboardModifier.NoModifier))
    QtWidgets.QApplication.processEvents()


def test_keyboard_up_onto_family_header_disarms_next(wiz):
    """REGRESSION (review mustFix): QTreeView keyboard nav stops on the enabled family
    HEADER rows. Landing there must disarm the image-type list and gate Next — the old
    code kept the previous device's role armed while validatePage fell back to
    platform='x86', emitting '--role rpi5-desktop' at the x86 builder (guaranteed
    hard-error)."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    page.select_device("rpi5")
    role_before, plat_before = wiz.cfg.role, wiz.cfg.platform
    tree = page.device_tree
    tree.setFocus()
    _press(tree, Qt.Key.Key_Up)          # first child -> its family header
    assert page._selected_device() is None      # a header carries no device id
    assert page.roles.count() == 0              # stale role list disarmed
    assert not page.isComplete()                # Next disabled
    assert not page.validatePage()              # and refused outright (no x86 fallback)
    before = wiz.currentId()
    wiz.next()                                  # the REAL Next path
    assert wiz.currentId() == before
    assert (wiz.cfg.role, wiz.cfg.platform) == (role_before, plat_before)  # cfg intact


def test_keyboard_down_past_last_family_device_disarms_then_recovers(wiz):
    """The Down-arrow variant (Sweet Potato -> next family's header), plus recovery:
    the next keypress onto a real device re-arms the list and Next."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    page.select_device("sweet-potato")
    tree = page.device_tree
    tree.setFocus()
    _press(tree, Qt.Key.Key_Down)
    assert page._selected_device() is None
    assert not page.isComplete() and not page.validatePage()
    _press(tree, Qt.Key.Key_Down)               # keyboard nav is NOT trapped
    did = page._selected_device()
    assert did is not None and device_catalog.selectable(did)
    assert page.roles.count() > 0 and page.isComplete()
    assert _role_ids(page) == [r for r, _l in device_catalog.roles_for(did, "cloud")]


def test_all_unsupported_arch_disarms_next_and_reenables_on_toggle_back(wiz):
    """An arch whose devices are ALL unsupported (ARMv7 / RISC-V) must not keep the
    hidden prior device armed: selection clears, Next gates, and an honest note says
    why; toggling back to a buildable arch re-arms."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    for arch in ("armv7", "riscv64"):
        assert arch in page._arch_buttons   # rendered — the listings stay visible
        page._arch_buttons[arch].setChecked(True)
        assert page._selected_device() is None, arch
        assert page.roles.count() == 0 and not page.isComplete(), arch
        assert not page.validatePage(), arch
        assert "No buildable device" in page.note.text(), arch
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() == before, arch
    page._arch_buttons["arm64"].setChecked(True)
    did = page._selected_device()
    assert did is not None and device_catalog.selectable(did)
    assert page.isComplete()


def test_experimental_alias_survives_back_navigation(wiz):
    """A committed EXPERIMENTAL alias (Pi 400 shares the Pi 4's (rpi5, rpi4) axes)
    is restored AS ITSELF on Back — not folded to the supported sibling — so the
    EXPERIMENTAL label and fail-loud note survive the round-trip."""
    _drive_single_image(wiz, "cloud", "rpi400", "rpi5-desktop")
    advance_to(wiz, wizard_mod.HardwarePage)
    assert (wiz.cfg.platform, wiz.cfg.board) == ("rpi5", "rpi4")
    wiz.back()
    page = wiz.currentPage()
    assert isinstance(page, wizard_mod.RolePage)
    assert page._selected_device() == "rpi400"
    assert "EXPERIMENTAL" in page.note.text()


# ── EMISSION BYTE-IDENTITY (goldens pinned from main c5a3d56) ──────────────────────

def _drive_single_image(wiz, mode, device_id, role):
    pick_mode(wiz, mode)
    page = advance_to(wiz, wizard_mod.RolePage)
    page.select_device(device_id)
    assert page.select_role(role) or role in _role_ids(page)
    return page


def test_emission_x86_pc_standalone_thick(wiz):
    _drive_single_image(wiz, "standalone", "x86-pc", "standalone-thick")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == ("standalone-thick", "x86", "", "")
    assert c.to_cli_args()[:2] == ["--role", "standalone-thick"]


def test_emission_rpi3_cloud_desktop_golden_argv(wiz):
    _drive_single_image(wiz, "cloud", "rpi3", "rpi5-desktop")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == ("rpi5-desktop", "rpi5", "rpi3", "")
    assert c.to_cli_args() == ["--role", "desktop", "--board", "rpi3", "--env", "test",
                               *ALL_TAIL]


def test_emission_le_potato_cloud_flavor_both_golden_argv(wiz):
    page = _drive_single_image(wiz, "cloud", "le-potato", "frite")
    page.flavor.setCurrentText("both")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == ("frite", "frite", "le-potato", "both")
    # --desktop light is the frite desktop knob's default — untouched by the browser
    assert c.to_cli_args() == ["--board", "le-potato", "--flavor", "both",
                               "--desktop", "light", "--env", "test", *ALL_TAIL]


def test_emission_orange_pi_5_installer_golden_argv(wiz):
    page = _drive_single_image(wiz, "cloud", "orange-pi-5", "orangepi5")
    page.orangepi5_flavor.setCurrentText("installer")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == \
        ("orangepi5", "orangepi5", "orange-pi-5", "installer")
    assert c.to_cli_args() == \
        ["--board", "orange-pi-5", "--flavor", "installer", "--env", "test", *ALL_TAIL]


def test_emission_orange_pi_zero2_live_golden_argv(wiz):
    page = _drive_single_image(wiz, "cloud", "orange-pi-zero2", "orangepizero2")
    page.orangepizero2_flavor.setCurrentText("live")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == \
        ("orangepizero2", "orangepizero2", "", "live")
    assert c.to_cli_args() == ["--flavor", "live", "--env", "test", *ALL_TAIL]


def test_emission_orange_pi_zero2w_live_golden_argv(wiz):
    """Same flavor-only emission shape as its Zero 2 template sibling above."""
    page = _drive_single_image(wiz, "cloud", "orange-pi-zero2w", "orangepizero2w")
    page.orangepizero2w_flavor.setCurrentText("live")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == \
        ("orangepizero2w", "orangepizero2w", "", "live")
    assert c.to_cli_args() == ["--flavor", "live", "--env", "test", *ALL_TAIL]


def test_emission_orange_pi_zero3_live_golden_argv(wiz):
    """Same flavor-only emission shape as its Zero 2 template sibling above."""
    page = _drive_single_image(wiz, "cloud", "orange-pi-zero3", "orangepizero3")
    page.orangepizero3_flavor.setCurrentText("live")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == \
        ("orangepizero3", "orangepizero3", "", "live")
    assert c.to_cli_args() == ["--flavor", "live", "--env", "test", *ALL_TAIL]


def test_emission_orange_pi_3_lts_live_golden_argv(wiz):
    """Same flavor-only emission shape as its Zero 2 template sibling above."""
    page = _drive_single_image(wiz, "cloud", "orange-pi-3-lts", "orangepi3-lts")
    page.orangepi3lts_flavor.setCurrentText("live")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board, c.flavor) == \
        ("orangepi3-lts", "orangepi3-lts", "", "live")
    assert c.to_cli_args() == ["--flavor", "live", "--env", "test", *ALL_TAIL]


def test_emission_experimental_rpi400_builds_as_rpi4(wiz):
    """An EXPERIMENTAL alias device maps to the accepted builder row — no builder
    change, no invented axes."""
    _drive_single_image(wiz, "cloud", "rpi400", "rpi5-desktop")
    advance_to(wiz, wizard_mod.HardwarePage)
    c = wiz.cfg
    assert (c.role, c.platform, c.board) == ("rpi5-desktop", "rpi5", "rpi4")


# ── mesh worklist: family grouping + honesty rows, entry identity untouched ────────

def test_worklist_family_groups_and_badges(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    assert {"x86-pcs", "raspberry-pi", "nvidia-jetson"} <= set(page._family_items)
    # jetson: no supported device in the family -> the header carries the badge
    # (in the Notes column)
    assert "EXPERIMENTAL" in page._family_items["nvidia-jetson"].text(_COL_NOTES)
    # role rows nest under their family header and keep their stable ids
    assert page.rows["pki.x86"].parent() is page._family_items["x86-pcs"]
    assert page.rows["pki.rpi5"].parent() is page._family_items["raspberry-pi"]
    assert page.rows["edge-ai.jetson"].parent() is page._family_items["nvidia-jetson"]


def test_worklist_unsupported_info_rows_visible_never_checkable(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    bpi = page._family_items["banana-pi"]
    labels = {bpi.child(i).text(1) for i in range(bpi.childCount())}
    assert any("BPI-M5" in t for t in labels)
    for i in range(bpi.childCount()):
        child = bpi.child(i)
        assert not (child.flags() & Qt.ItemFlag.ItemIsUserCheckable)
        assert child.text(_COL_NOTES)   # the reason rides in the Notes column
    # info rows never mint entry ids
    assert not any(rid.endswith(".banana-pi") for rid in page.rows)


def test_worklist_rpi3_never_offered_on_node_rows(wiz):
    """The rpi3 node-gate is intact: no node-role board combo offers rpi3; the desktop
    row still does (real-cases check)."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    for rid in ("pki.rpi5", "backend.rpi5", "frontend.rpi5"):
        combo, _f = page._combos[rid]
        assert "rpi3" not in [combo.itemText(i) for i in range(combo.count())], rid
    combo, _f = page._combos["rpi5-desktop.rpi5"]
    assert "rpi3" in [combo.itemText(i) for i in range(combo.count())]


def test_worklist_emission_identity_rpi4_pki_and_jetson_edge_ai(wiz):
    """Checking 'pki on Raspberry Pi (board rpi4)' + 'edge_ai on Jetson (orin-nx-16gb)'
    yields the identical WorklistEntry axes the flat rows produced."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(page, "pki.rpi5", "edge-ai.jetson")
    board, _ = page._combos["pki.rpi5"]
    board.setCurrentText("rpi4")
    jboard, _ = page._combos["edge-ai.jetson"]
    jboard.setCurrentText("orin-nx-16gb")
    assert page.validatePage()
    by_id = {e.id: (e.role, e.platform, e.board) for e in wiz.worklist.entries}
    assert by_id == {"pki.rpi5": ("pki", "rpi5", "rpi4"),
                     "edge-ai.jetson": ("edge-ai", "jetson", "orin-nx-16gb")}


def test_worklist_services_column_sets_per_node_tor(wiz):
    """The per-node Services combo carries a Tor-onion selection into the
    WorklistEntry and, through materialize, into that ONE node's --with-tor argv —
    while a sibling node with no selection stays clean (proves per-node, GUI end)."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(page, "backend.x86", "pki.x86")
    svc = page._services_combos["backend.x86"]
    assert svc is not None                       # x86 expresses the Tor onion
    i = next(j for j in range(svc.count()) if tuple(svc.itemData(j) or ()) == ("tor",))
    svc.setCurrentIndex(i)
    assert page.validatePage()
    by_id = {e.id: e for e in wiz.worklist.entries}
    assert by_id["backend.x86"].infra_services == ("tor",)
    assert by_id["pki.x86"].infra_services == ()
    # and it reaches argv for that node only
    mats = {e.id: cfg for e, cfg in wiz.worklist.materialize()}
    assert "--with-tor" in mats["backend.x86"].to_cli_args()
    assert "--with-tor" not in mats["pki.x86"].to_cli_args()


def test_worklist_arch_filter_is_presentation_only(wiz):
    """A checked row hidden by the arch filter still builds — filtering never mutates
    the worklist."""
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(page, "omnibus.x86")
    idx = page.arch_filter.findData("arm64")
    page.arch_filter.setCurrentIndex(idx)
    assert page.rows["omnibus.x86"].isHidden()
    assert page.validatePage()
    assert [e.id for e in wiz.worklist.entries] == ["omnibus.x86"]
    page.arch_filter.setCurrentIndex(0)
    assert not page.rows["omnibus.x86"].isHidden()


def test_worklist_search_filters_rows(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    page.device_search.setText("edge")
    assert not page.rows["edge-ai.jetson"].isHidden()
    assert page.rows["pki.rpi5"].isHidden()
    page.device_search.setText("")
    assert not page.rows["pki.rpi5"].isHidden()


# ── the compat shims keep the machine-first entry points alive ──────────────────────

def test_select_machine_shim_selects_platform_default_device(wiz):
    page = advance_to(wiz, wizard_mod.RolePage)
    for plat, want in (("x86", "x86-pc"), ("rpi5", "rpi5"), ("frite", "la-frite"),
                       ("orangepi5", "orange-pi-5-plus"), ("orangepizero2", "orange-pi-zero2"),
                       ("orangepizero2w", "orange-pi-zero2w")):
        page.select_machine(plat)
        assert page._selected_device() == want, plat
        assert page._selected_machine() == plat


def test_roles_repopulate_from_catalog_derivation(wiz):
    """The image-type list equals roles_for(device, mode) for every pickable device —
    the derivation is THE role source (never an invented role)."""
    pick_mode(wiz, "cloud")
    page = advance_to(wiz, wizard_mod.RolePage)
    for did in ("x86-pc", "rpi5", "rpi4", "rpi3", "la-frite", "orange-pi-5"):
        page.select_device(did)
        assert _role_ids(page) == [r for r, _l in device_catalog.roles_for(did, "cloud")], did


# ── the required-trio button honours the arch filter ────────────────────────────────
# Until 2026-07-17 _select_trio() hardcoded entry_id(role, "x86"), so the button ignored
# the dropdown next to it: with "All architectures" showing, one click produced an
# x86-ONLY mesh from a control that claims to select "the required trio". pki/be/fe are
# buildable on x86 AND rpi5 (ROLE_CHOICES gives each ("x86", "rpi5")), so an unnarrowed
# filter must check both. Real report: "the button ... with the 'All architectures'
# dropdown selected should check fe/be/pki on x86 and arm".
def _checked_ids(page):
    from hugmesh_studio.gui.qt import Qt
    return {rid for rid, it in page.rows.items()
            if it.checkState(0) == Qt.CheckState.Checked}


def test_trio_button_with_all_architectures_checks_x86_AND_arm(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    assert page.arch_filter.currentData() in ("", None)   # "All architectures" default
    page.trio_btn.click()
    got = _checked_ids(page)
    assert {"pki.x86", "backend.x86", "frontend.x86"} <= got, got
    assert {"pki.rpi5", "backend.rpi5", "frontend.rpi5"} <= got, f"arm trio not selected: {got}"


def _trio_delta(page, arch_id):
    """Rows the trio button NEWLY checks under an arch filter. A delta (not an absolute
    set) because the wiz fixture is shared down the file — an unrelated row another test
    left checked is not this button's doing, and the button is additive by contract."""
    idx = page.arch_filter.findData(arch_id)
    assert idx >= 0, f"arch id {arch_id!r} not in the filter: " + repr(
        [page.arch_filter.itemData(i) for i in range(page.arch_filter.count())])
    page.arch_filter.setCurrentIndex(idx)
    before = _checked_ids(page)
    page.trio_btn.click()
    return _checked_ids(page) - before


def test_trio_button_narrowed_to_arm64_checks_only_arm(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    added = _trio_delta(page, "arm64")
    assert added == {"pki.rpi5", "backend.rpi5", "frontend.rpi5"}, added


def test_trio_button_narrowed_to_x86_checks_only_x86(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    added = _trio_delta(page, "x86-64")
    assert added == {"pki.x86", "backend.x86", "frontend.x86"}, added


def test_trio_button_stays_additive_and_does_not_touch_gpu_rows(wiz):
    pick_mode(wiz, "mesh")
    page = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(page, "backend-gpu.x86")
    page.trio_btn.click()
    got = _checked_ids(page)
    assert "backend-gpu.x86" in got, "the trio button must never unpick an existing row"
    assert {"pki.x86", "backend.x86", "frontend.x86", "pki.rpi5"} <= got
