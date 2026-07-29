"""The Review & Build per-device assignment table (gui/pages/_device_table.py).

Drives the REAL wizard on Qt's offscreen platform with detection mocked at the
established boundary (``flash_targets.list_targets`` / ``ft.subprocess.run`` returning
canned lsblk JSON) — never a real device, never a real flash. Pins:

* the table lists mocked devices with the documented columns and NEVER the disk
  backing ``/`` (the #348 exclusion lives BELOW the widget, in list_targets);
* per-row role assignment: flash target (per-device image pick, multi-device,
  different images), keys USB (exclusive; writes through the EXISTING keys_usb
  field so the command preview shows --keys-usb — the pre-existing axis, no drift);
* honesty gating: the Keys role is disabled-with-a-reason off-x86 and on an
  unmounted device;
* the post-build plan executes sequentially on ProgressPage behind the TOCTOU
  identity re-check, via flash-disk.sh argv only (mocked _start_flash records);
* the scan runs off the Qt main thread (a slow mocked lsblk never blocks refresh()).
"""
import os
import threading
import time

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

import json                                                    # noqa: E402

from hugmesh_studio.core import flash_targets as ft        # noqa: E402
from hugmesh_studio.core.flash_targets import FlashTarget  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo     # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod        # noqa: E402
from hugmesh_studio.gui.pages import _device_table as dt_mod  # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtCore, QtWidgets    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
GIB = 1 << 30

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

# two canned attached devices: a mounted, labelled USB stick and a bare (unmounted) SD
SDB = FlashTarget("/dev/sdb", 16 * GIB, "SanDisk Ultra", "usb", True, "usb",
                  fs_label="KEYS", mountpoints=("/run/media/magus/KEYS",))
MMC = FlashTarget("/dev/mmcblk0", 32 * GIB, "SD32G", "", False, "mmc")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


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
    w.deleteLater()


def advance_to(wiz, page_cls):
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def pick_mode(wiz, mode):
    page = advance_to(wiz, wizard_mod.ModePage)
    idx = [m for m, _, _ in page.modes].index(mode)
    page.group.button(idx).setChecked(True)
    return page


def pick_role(wiz, role):
    page = advance_to(wiz, wizard_mod.RolePage)
    if not page.select_role(role):     # machine-first: selects the supporting card too
        raise AssertionError(f"role {role} not offered on RolePage")
    return page


def _populate(table, targets):
    """Deterministically feed a canned scan result into the table (the worker's done
    slot), cancelling the pending debounce so no background thread races the test."""
    table._debounce.stop()
    table._scan_gen += 1
    table._on_scan_done(list(targets), table._scan_gen)


def _cell(table, row, col):
    item = table.table.item(row, col)
    return item.text() if item is not None else ""


def _set_role(table, row, role_token):
    combo = table.table.cellWidget(row, 5)
    combo.setCurrentIndex(combo.findData(role_token))


def _keys_item(table, row):
    combo = table.table.cellWidget(row, 5)
    return combo.model().item(2), combo.itemData(2, QtCore.Qt.ItemDataRole.ToolTipRole)


def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


# ── (a) listing: columns + the root disk NEVER becomes a row ─────────────────────────
def test_table_lists_devices_with_columns(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    t = build.device_table
    assert t.table.rowCount() == 2
    assert _cell(t, 0, 0) == "/dev/sdb"
    assert _cell(t, 0, 1) == "SanDisk Ultra · KEYS"      # model + fs label, both shown
    assert _cell(t, 0, 2) == "16.0 GiB"
    assert _cell(t, 0, 3) == "usb"
    assert _cell(t, 0, 4) == "mounted: /run/media/magus/KEYS"
    assert _cell(t, 1, 0) == "/dev/mmcblk0"
    assert _cell(t, 1, 3) == "mmc"
    assert _cell(t, 1, 4) == "—"                          # unmounted indicator
    # default: every Role combo is "(none)" and the plan is empty (default-off)
    for row in range(2):
        assert t.table.cellWidget(row, 5).currentData() == dt_mod.ROLE_NONE
    assert t.flash_assignments() == [] and t.keys_assignment() is None
    assert "no post-build flashing (default)" in t.plan_label.text()


def test_root_backing_disk_never_becomes_a_row(monkeypatch, wiz):
    """Page-level pin of the #348 exclusion: a stubbed lsblk tree CONTAINING the disk
    backing '/' yields no row for it — the table's only data source is list_targets."""
    data = {"blockdevices": [
        {"name": "nvme0n1", "path": "/dev/nvme0n1", "tran": "nvme", "rm": False,
         "type": "disk", "size": 100 * GIB, "hotplug": True, "model": "HostSSD",
         "vendor": None, "label": None, "mountpoint": None,
         "children": [{"name": "nvme0n1p2", "path": "/dev/nvme0n1p2", "type": "part",
                       "rm": False, "size": 99 * GIB, "hotplug": False, "label": None,
                       "mountpoint": "/"}]},
        {"name": "sdb", "path": "/dev/sdb", "tran": "usb", "rm": True, "type": "disk",
         "size": 16 * GIB, "hotplug": True, "model": "Ultra", "vendor": None,
         "label": None, "mountpoint": None},
    ]}

    class _FakeRun:
        stdout = json.dumps(data)
        returncode = 0
        stderr = ""
    monkeypatch.setattr(ft.subprocess, "run", lambda *a, **k: _FakeRun())
    monkeypatch.setattr(ft, "_root_source", lambda: "/dev/nvme0n1p2")
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, ft.list_targets())
    t = build.device_table
    paths = {_cell(t, r, 0) for r in range(t.table.rowCount())}
    assert paths == {"/dev/sdb"}
    assert "/dev/nvme0n1" not in paths


def test_refresh_preserves_assignments_by_path(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    _set_role(build.device_table, 0, dt_mod.ROLE_FLASH)
    before = build.device_table.flash_assignments()
    assert len(before) == 1
    _populate(build.device_table, [SDB, MMC])            # rescan (same devices)
    t = build.device_table
    assert t.table.cellWidget(0, 5).currentData() == dt_mod.ROLE_FLASH
    assert t.flash_assignments() == before
    # an unplugged device's assignment is pruned, not left dangling
    _populate(build.device_table, [MMC])
    assert t.flash_assignments() == []


# ── (b)+(c) flash assignment → post-build plan → sequential mocked execution ─────────
def test_flash_assignment_yields_post_build_plan_not_argv(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    entry_id = build._flash_image_choices()[0][0]        # the 1-entry standalone shape
    assert len(build._flash_image_choices()) == 1        # degrades gracefully
    cmd_before = build.cmd.toPlainText()
    _set_role(build.device_table, 0, dt_mod.ROLE_FLASH)
    img_combo = build.device_table.table.cellWidget(0, 6)
    assert img_combo.currentData() == entry_id
    # flash assignments are POST-BUILD: the build command preview is unchanged;
    # the plan shows in the read-only summary label instead.
    build._preview()
    assert build.cmd.toPlainText() == cmd_before
    assert f"{entry_id} → /dev/sdb" in build.device_table.plan_label.text()
    assert "flash-disk.sh" in build.device_table.plan_label.text()
    assert build.validatePage() is True
    plan = wiz.flash_plan
    assert len(plan) == 1
    a = plan[0]
    assert a.target == SDB and a.entry_id == entry_id
    assert a.role == "host"           # a desktop role maps to the generic host glob
    assert a.arch == "x86"
    assert wiz.flash_after == (False, None)              # legacy stash stays inert


def test_two_devices_take_two_different_images_and_flash_sequentially(monkeypatch, wiz):
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    for rid in ("omnibus.x86", "be.rpi5"):
        wl_page.row_for_id(rid).setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    ids = [c[0] for c in build._flash_image_choices()]
    assert {"omnibus.x86", "be.rpi5"} <= set(ids)
    _set_role(build.device_table, 0, dt_mod.ROLE_FLASH)   # sdb -> be.rpi5
    c0 = build.device_table.table.cellWidget(0, 6)
    c0.setCurrentIndex(c0.findData("be.rpi5"))
    _set_role(build.device_table, 1, dt_mod.ROLE_FLASH)   # mmc -> omnibus.x86
    c1 = build.device_table.table.cellWidget(1, 6)
    c1.setCurrentIndex(c1.findData("omnibus.x86"))
    assert build.validatePage() is True
    plan = wiz.flash_plan
    assert [(a.target.path, a.entry_id, a.role, a.arch) for a in plan] == [
        ("/dev/sdb", "be.rpi5", "be", "arm64"),
        ("/dev/mmcblk0", "omnibus.x86", "omnibus", "x86")]
    # execution: sequential on ProgressPage, each argv a flash-disk.sh call — never dd.
    # Each entry's CONCRETE built image (recorded per entry during the run) rides
    # --artifact, so the per-row pick is honored even when role globs would collide.
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: [SDB, MMC])
    page = _progress_page(wiz)
    page._entry_artifacts = {
        "be.rpi5": "/out/hugmesh-rpi5-arm64-backend-1.img",
        "omnibus.x86": "/out/hugmesh-host-amd64-2.img"}
    recorded = []

    def fake_start(target, argv=None):
        recorded.append((target.path, list(argv or [])))
        page._flash_done(0)                     # chain: _flash_done runs the next one
    page._start_flash = fake_start              # type: ignore[assignment]
    page._maybe_auto_flash()
    assert [r[0] for r in recorded] == ["/dev/sdb", "/dev/mmcblk0"]
    for _path, argv in recorded:
        assert any(a.endswith("scripts/flash-disk.sh") for a in argv)
        assert "dd" not in argv
    assert ("--role", "be") in zip(recorded[0][1], recorded[0][1][1:])
    assert ("--role", "omnibus") in zip(recorded[1][1], recorded[1][1][1:])
    assert ("--artifact", "/out/hugmesh-rpi5-arm64-backend-1.img") in \
        zip(recorded[0][1], recorded[0][1][1:])
    assert ("--artifact", "/out/hugmesh-host-amd64-2.img") in \
        zip(recorded[1][1], recorded[1][1][1:])


def test_plan_toctou_identity_change_skips_that_device(monkeypatch, wiz):
    """An unplug/replug swap (same /dev path, different size/model) is skipped with a
    log line, not written — the SAME identity check as the legacy auto-flash path."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB])
    _set_role(build.device_table, 0, dt_mod.ROLE_FLASH)
    assert build.validatePage() is True and len(wiz.flash_plan) == 1
    swapped = FlashTarget("/dev/sdb", 64 * GIB, "Some Other Stick", "usb", True, "usb")
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: [swapped])
    page = _progress_page(wiz)
    page._entry_artifacts = {wiz.flash_plan[0].entry_id: "/out/x.img"}
    started = []
    page._start_flash = lambda t, argv=None: started.append(t)  # type: ignore[assignment]
    page._maybe_auto_flash()
    assert started == []
    assert "identity changed" in page.log.toPlainText()


def test_plan_identity_recheck_is_fresh_per_assignment(monkeypatch, wiz):
    """The identity check must run immediately before EACH flash, not once for the
    whole queue: a dd takes minutes, so a stick swapped at /dev/mmcblk0 WHILE
    /dev/sdb was being flashed must still be caught when its own turn comes."""
    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    for rid in ("omnibus.x86", "be.rpi5"):
        wl_page.row_for_id(rid).setCheckState(0, Qt.CheckState.Checked)
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    _set_role(build.device_table, 0, dt_mod.ROLE_FLASH)
    c0 = build.device_table.table.cellWidget(0, 6)
    c0.setCurrentIndex(c0.findData("be.rpi5"))
    _set_role(build.device_table, 1, dt_mod.ROLE_FLASH)
    c1 = build.device_table.table.cellWidget(1, 6)
    c1.setCurrentIndex(c1.findData("omnibus.x86"))
    assert build.validatePage() is True and len(wiz.flash_plan) == 2
    attached = [[SDB, MMC]]                     # mutated mid-run below
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: list(attached[0]))
    page = _progress_page(wiz)
    page._entry_artifacts = {"be.rpi5": "/out/a.img", "omnibus.x86": "/out/b.img"}
    started = []

    def fake_start(target, argv=None):
        started.append(target.path)
        # WHILE the first flash "runs": mmcblk0 is unplugged and a DIFFERENT card
        # enumerates at the same node — the classic same-node swap.
        attached[0] = [SDB, FlashTarget("/dev/mmcblk0", 8 * GIB, "Evil Twin",
                                        "", False, "mmc")]
        page._flash_done(0)                     # chain to the next assignment
    page._start_flash = fake_start              # type: ignore[assignment]
    page._maybe_auto_flash()
    assert started == ["/dev/sdb"]              # the swapped device was NOT written
    assert "identity changed" in page.log.toPlainText()


def test_plan_without_a_recorded_artifact_fails_safe(monkeypatch, wiz):
    """No recorded per-entry artifact ⇒ SKIP, never a role-glob guess: flash-disk.sh's
    newest-mtime '*-<role>-*' glob cannot tell two same-role entries apart, so a
    guess could write the WRONG image to a correctly-identified device."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB])
    _set_role(build.device_table, 0, dt_mod.ROLE_FLASH)
    assert build.validatePage() is True and len(wiz.flash_plan) == 1
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: [SDB])
    page = _progress_page(wiz)
    page._entry_artifacts = {}                  # nothing recorded for this run
    started = []
    page._start_flash = lambda t, argv=None: started.append(t)  # type: ignore[assignment]
    page._maybe_auto_flash()
    assert started == []
    assert "no artifact was recorded" in page.log.toPlainText()


def test_abort_clears_the_flash_queue_so_no_chain_start_after_cancel(monkeypatch, wiz):
    """Closing/cancelling the wizard mid-plan drops the queued assignments: when the
    still-running flash worker finally emits done (a dd outlives the 3s join),
    _flash_done must NOT chain-start the next destructive flash."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: [SDB, MMC])
    page = _progress_page(wiz)
    page._entry_artifacts = {"e1": "/out/a.img", "e2": "/out/b.img"}
    page._flash_queue = [
        ft.FlashAssignment(target=SDB, entry_id="e1", role="host", arch="x86",
                           work_dir="/out"),
        ft.FlashAssignment(target=MMC, entry_id="e2", role="host", arch="x86",
                           work_dir="/out")]
    started = []
    page._start_flash = lambda t, argv=None: started.append(t)  # type: ignore[assignment]
    page._abort_run()                           # user closed the wizard mid-flash
    assert page._flash_queue == []
    page._flash_done(0)                         # the orphaned worker finally finishes
    assert started == []                        # nothing chain-started after the abort


# ── (d) keys USB: the EXISTING cfg.keys_usb axis + honesty gating ────────────────────
def test_keys_assignment_sets_cfg_keys_usb_and_preview_shows_flag(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB, MMC])
    _set_role(build.device_table, 0, dt_mod.ROLE_KEYS)
    # written THROUGH the existing widget -> cfg -> the pre-existing --keys-usb emission
    assert build.keys_usb.text() == "/run/media/magus/KEYS"
    assert wiz.cfg.keys_usb == "/run/media/magus/KEYS"
    assert "--keys-usb /run/media/magus/KEYS" in build.cmd.toPlainText()
    ka = build.device_table.keys_assignment()
    assert ka is not None and ka[0].path == "/dev/sdb"
    # un-assigning clears the field (it still equals the assigned dir)
    _set_role(build.device_table, 0, dt_mod.ROLE_NONE)
    assert build.keys_usb.text() == ""
    assert "--keys-usb" not in build.cmd.toPlainText()


def test_keys_unassign_never_clobbers_a_hand_typed_path(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB])
    _set_role(build.device_table, 0, dt_mod.ROLE_KEYS)
    build.keys_usb.setText("/hand/typed/keys")           # user edits after assigning
    _set_role(build.device_table, 0, dt_mod.ROLE_NONE)
    assert build.keys_usb.text() == "/hand/typed/keys"   # untouched


def test_keys_role_is_exclusive_across_rows(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    sdb2 = FlashTarget("/dev/sdc", 8 * GIB, "Cruzer", "usb", True, "usb",
                       mountpoints=("/run/media/magus/OTHER",))
    _populate(build.device_table, [SDB, sdb2])
    _set_role(build.device_table, 0, dt_mod.ROLE_KEYS)
    assert build.keys_usb.text() == "/run/media/magus/KEYS"
    _set_role(build.device_table, 1, dt_mod.ROLE_KEYS)   # reassign on the other row
    t = build.device_table
    assert t.table.cellWidget(0, 5).currentData() == dt_mod.ROLE_NONE  # row A cleared
    ka = t.keys_assignment()
    assert ka is not None and ka[0].path == "/dev/sdc"
    assert build.keys_usb.text() == "/run/media/magus/OTHER"


def test_keys_role_disabled_when_device_not_mounted(wiz):
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [MMC])                 # no mountpoints
    item, tip = _keys_item(build.device_table, 0)
    assert not item.isEnabled()
    assert "not mounted" in tip


def test_keys_role_disabled_with_reason_off_x86(wiz):
    """keys_usb is x86-gated (PLATFORM_FIELD_SUPPORT) — on an ARM platform the Keys
    role is disabled with the standard unsupported note, never a silent no-op."""
    pick_role(wiz, "generic")                            # standalone rpi5
    build = advance_to(wiz, wizard_mod.BuildPage)
    _populate(build.device_table, [SDB])                 # mounted — platform is the gate
    item, tip = _keys_item(build.device_table, 0)
    assert not item.isEnabled()
    assert "no flag" in tip
    # flash target assignment is still offered (post-build, platform-independent)
    combo = build.device_table.table.cellWidget(0, 5)
    assert combo.model().item(1).isEnabled()


# ── (e) responsiveness: the scan never runs on the Qt main loop ──────────────────────
def test_slow_scan_never_blocks_the_main_thread(monkeypatch, qapp, wiz):
    release = threading.Event()

    def slow_list_targets():
        release.wait(5.0)                                # a wedged lsblk
        return [SDB]
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        slow_list_targets)
    build = advance_to(wiz, wizard_mod.BuildPage)
    t0 = time.monotonic()
    build.device_table.refresh()
    assert time.monotonic() - t0 < 0.5                   # returned instantly (debounced)
    # let the debounce fire and the worker launch — the GUI thread keeps pumping
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline and \
            build.device_table.refresh_btn.text() != "Scanning…":
        qapp.processEvents()
        time.sleep(0.01)
    assert build.device_table.refresh_btn.text() == "Scanning…"
    release.set()                                        # scan completes off-thread
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and \
            build.device_table.refresh_btn.text() != "Refresh":
        qapp.processEvents()
        time.sleep(0.01)
    assert build.device_table.refresh_btn.text() == "Refresh"
    assert build.device_table.table.rowCount() == 1
    build.device_table.join()


def test_run_records_each_entrys_artifact_by_snapshot_diff(wiz, tmp_path):
    """Two entries sharing the SAME flash-disk.sh role token (both 'be'/arm64) each
    get THEIR OWN artifact recorded — the snapshot diff around each sequential entry
    build is what makes the per-row image pick real (flash-disk.sh's newest-mtime
    role glob would flash the same image to both devices)."""
    import types

    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, "be.rpi5", "rpi5")
    page._build_row(1, "be.jetson", "jetson")

    def _res(eid):
        return types.SimpleNamespace(entry=types.SimpleNamespace(id=eid), status="ok")
    page.driver = types.SimpleNamespace(results=[_res("be.rpi5"), _res("be.jetson")])
    wiz.cfg.output_dir = str(tmp_path)

    def _write(name):
        with open(os.path.join(str(tmp_path), name), "w", encoding="utf-8") as fh:
            fh.write("x")
    page._on_entry_start(0)
    _write("hugmesh-rpi5-arm64-backend-1.img")
    page._on_entry_done(0, 0)
    page._on_entry_start(1)
    _write("hugmesh-jetson-arm64-backend-2.img")
    page._on_entry_done(1, 0)
    assert page._entry_artifacts == {
        "be.rpi5": os.path.join(str(tmp_path), "hugmesh-rpi5-arm64-backend-1.img"),
        "be.jetson": os.path.join(str(tmp_path), "hugmesh-jetson-arm64-backend-2.img")}
    page.driver = None                          # keep the wiz teardown inert


def test_keys_role_fails_closed_when_the_gate_errors(wiz):
    """An erroring keys gate must disable the Keys role WITH a reason (fail closed):
    'allowed' by default would offer an assignment nobody can prove emits."""
    build = advance_to(wiz, wizard_mod.BuildPage)

    def boom():
        raise RuntimeError("gate broke")
    build.device_table._keys_gate = boom        # type: ignore[assignment]
    _populate(build.device_table, [SDB])
    item, tip = _keys_item(build.device_table, 0)
    assert not item.isEnabled()
    assert "keys gating unavailable" in tip
