"""#415 — the operator chooses WHICH IMAGE is flashed, not just which device.

Everything here is argv-and-UI-state only: no device is opened, no `dd` runs, no
subprocess is launched (the flasher worker is replaced wherever a flash is started).
The assertions are on the ARGV handed to scripts/flash-disk.sh and on widget state.

Split by deliverable:
  A. the ProgressPage "Flash to a device" Image dropdown (standalone path)
  B. the post-build flash-plan table (mesh / multi-entry path)
  C. the per-image write progress indicator
  D. the no-flash image validator
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                   # noqa: E402

from hugmesh_studio.core import flash_targets as ft                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.pages import progress as pg                 # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

SDB = ft.FlashTarget("/dev/sdb", 64 * (1 << 30), "Test Stick", "usb", True, "usb")
SDC = ft.FlashTarget("/dev/sdc", 64 * (1 << 30), "Other Stick", "usb", True, "usb")


@pytest.fixture
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def page(wiz):
    return wiz.page(wiz._page_ids["progress"])


class _Lines:
    """A stand-in for the log pane that records what was appended."""

    def __init__(self):
        self.lines = []

    def appendPlainText(self, s):
        self.lines.append(s)

    def toPlainText(self):
        return "\n".join(self.lines)

    def setPlainText(self, s):
        self.lines = [s] if s else []


def _artifacts(tmp_path, *names, body=b"x" * 4096):
    """Create real files so mtime/size/label reflect a real directory."""
    out = []
    for i, n in enumerate(names):
        p = tmp_path / n
        p.write_bytes(body)
        os.utime(p, (1_700_000_000 + i, 1_700_000_000 + i))   # oldest first
        out.append(str(p))
    return out


# ══ A. standalone: the Image dropdown ═══════════════════════════════════════════════
def test_image_combo_lists_every_recorded_artifact_newest_first(page, tmp_path):
    """The dropdown the standalone path never had: one row per flashable artifact the
    run produced, newest first."""
    img, live, inst = _artifacts(
        tmp_path, "b-x86-amd64-omnibus-prod-1.img.xz",
        "b-x86-amd64-omnibus-prod-1.live.iso",
        "b-x86-amd64-omnibus-prod-1.installer.iso")
    page._entry_artifact_sets = {"e1": (inst, live, img)}
    page._refresh_flash_images()
    assert page.flash_image_combo.count() == 3
    # newest first == mtime order, reversed
    assert [page.flash_image_combo.itemData(i) for i in range(3)] == [inst, live, img]
    labels = [page.flash_image_combo.itemText(i) for i in range(3)]
    assert all(os.path.basename(p) in t
               for p, t in zip([inst, live, img], labels))
    assert any("installer" in t for t in labels) and any("live" in t for t in labels)


def test_image_combo_defaults_to_todays_auto_pick(page, tmp_path):
    """Nothing changes for an operator who does not touch the control: the preselected
    row IS pick_artifact(..., "auto") — the newest .img — even though the ISOs are
    newer on disk."""
    img, live, inst = _artifacts(
        tmp_path, "b-x86-amd64-omnibus-prod-1.img.xz",
        "b-x86-amd64-omnibus-prod-1.live.iso",
        "b-x86-amd64-omnibus-prod-1.installer.iso")
    page._entry_artifact_sets = {"e1": (inst, live, img)}
    page._refresh_flash_images()
    assert page._selected_image() == img
    assert img == ft.pick_artifact((inst, live, img), ft.FLAVOR_AUTO)
    assert "default (auto-pick)" in page.flash_image_combo.currentText()


def test_selected_image_is_what_reaches_artifact_in_the_argv(page, tmp_path,
                                                             monkeypatch):
    """The whole point: choosing the .live.iso makes --artifact the .live.iso. Argv
    only — nothing is opened, nothing is written."""
    img, live, inst = _artifacts(
        tmp_path, "b-x86-amd64-omnibus-prod-1.img.xz",
        "b-x86-amd64-omnibus-prod-1.live.iso",
        "b-x86-amd64-omnibus-prod-1.installer.iso")
    page._entry_artifact_sets = {"e1": (inst, live, img)}
    page._refresh_flash_images()
    page.flash_image_combo.setCurrentIndex(
        page.flash_image_combo.findData(live))
    argv = page._flash_argv_for(SDB)
    assert "--artifact" in argv
    assert argv[argv.index("--artifact") + 1] == live
    assert argv[-1] == "/dev/sdb" and "dd" not in argv
    # and the ONE confirmation names the file, instead of "auto-picked by …"
    text = page._flash_confirm_text(SDB, argv)
    assert os.path.basename(live) in text
    assert "auto-picked by scripts/flash-disk.sh" not in text


def test_no_recorded_images_keeps_the_pre_415_auto_pick(page, monkeypatch):
    """With nothing recorded and nothing on disk, NO --artifact is emitted — the
    pre-#415 behaviour, and the combo says so rather than showing a fake default."""
    page._entry_artifact_sets = {}
    monkeypatch.setattr(ft, "find_artifacts", lambda *a, **k: ())
    page._refresh_flash_images()
    assert page.flash_image_combo.count() == 1
    assert page._selected_image() == ""
    assert not page.flash_image_combo.isEnabled()
    assert "auto-pick" in page.flash_image_combo.currentText()
    argv = page._flash_argv_for(SDB)
    assert "--artifact" not in argv


def test_image_combo_falls_back_to_the_arch_role_name_match(page, tmp_path,
                                                            monkeypatch):
    """A run that recorded nothing still offers what is really in the work dir, found
    by the SAME read-only arch+role name match flash-disk.sh uses."""
    found = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-9.img")
    page._entry_artifact_sets = {}
    monkeypatch.setattr(page, "_work_dir", lambda: str(tmp_path))
    monkeypatch.setattr(page, "_flash_role_arch", lambda: ("omnibus", "x86"))
    page._refresh_flash_images()
    assert [page.flash_image_combo.itemData(i)
            for i in range(page.flash_image_combo.count())] == found


def test_refresh_preserves_the_operators_pick(page, tmp_path):
    """The 2.5 s device timer re-enters the refresh; it must not snap the selection
    back to the default under the operator's cursor."""
    img, live = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img",
                           "b-x86-amd64-omnibus-prod-1.live.iso")
    page._entry_artifact_sets = {"e1": (live, img)}
    page._refresh_flash_images()
    page.flash_image_combo.setCurrentIndex(page.flash_image_combo.findData(live))
    for _ in range(5):
        page._refresh_flash_images()
    assert page._selected_image() == live


def test_a_second_run_drops_the_previous_runs_images(page, tmp_path, monkeypatch):
    """_reset must clear the combo: offering (and defaulting to) a file the NEW run
    never produced is how an operator flashes yesterday's image by accident."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e1": (img,)}
    page._refresh_flash_images()
    assert page._selected_image() == img
    page._reset()
    assert page.flash_image_combo.count() == 0
    assert page._selected_image() == ""


def test_flash_clicked_drops_the_auto_pick_caveat_when_an_image_is_named(
        page, tmp_path, monkeypatch):
    """The "watch the Artifact : line" caveat was true only while no image could be
    named. With a pick it would be a lie, so it must not be printed."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e1": (img,)}
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    page._refresh_flash_targets()
    seen = {}

    def _capture(target, argv=None):
        seen["caveats"] = list(page._flash_caveats)
        seen["argv"] = argv
    monkeypatch.setattr(page, "_start_flash", _capture)
    page._flash_clicked()
    assert seen["caveats"] == []
    page._entry_artifact_sets = {}
    monkeypatch.setattr(ft, "find_artifacts", lambda *a, **k: ())
    page._flash_image_cands = None
    page._refresh_flash_images()
    page._flash_clicked()
    assert seen["caveats"] and "auto-pick" in seen["caveats"][0]


def test_artifact_label_names_the_file_flavour_and_size(tmp_path):
    p, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img.xz", body=b"z" * 2048)
    label = ft.artifact_label(p)
    assert label.startswith("b-x86-amd64-omnibus-prod-1.img.xz")
    assert " img " in f" {label} " or "· img ·" in label
    assert "2.0 KiB" in label and "compressed" in label
    # an unflavoured rpi5 .iso is NAMEABLE here even though no flavour token reaches it
    q, = _artifacts(tmp_path, "b-rpi5-arm64-backend-prod-2.iso")
    assert ft.classify_artifact_flavor(q) == ""
    assert "other" in ft.artifact_label(q)


# ══ B. mesh / multi-entry: the flash-plan table ═════════════════════════════════════
def _plan_page(monkeypatch, page, *, sets, plan, targets):
    """Drive the REAL page through _maybe_auto_flash with the flasher stubbed out: an
    accepted assignment records its argv and launches nothing."""
    page._entry_artifact_sets = dict(sets)
    page._entry_artifacts = {}
    page.wiz.flash_plan = list(plan)
    monkeypatch.setattr(ft, "list_targets", lambda: list(targets))
    started = []
    monkeypatch.setattr(page, "_start_flash",
                        lambda target, argv=None: started.append((target.path, argv)))
    page.log = _Lines()
    return started


def test_plan_table_states_entry_image_and_device_for_every_row(page, tmp_path,
                                                                monkeypatch):
    """The mesh gap #415 names: entry->device existed, image->device did not. Every
    row now carries the exact FILE alongside the device."""
    a_img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    b_img, = _artifacts(tmp_path, "b-rpi5-arm64-backend-prod-2.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "backend.rpi5", "backend", "arm64", str(tmp_path))]
    started = _plan_page(monkeypatch, page,
                         sets={"omnibus.x86": (a_img,), "backend.rpi5": (b_img,)},
                         plan=plan, targets=[SDB, SDC])
    page._maybe_auto_flash()
    t = page.flash_plan_table
    assert not page.flash_plan_box.isHidden() and t.rowCount() == 2
    assert t.item(0, 0).text().startswith("omnibus.x86")
    assert os.path.basename(a_img) in t.cellWidget(0, 1).currentText()
    assert "/dev/sdb" in t.item(0, 2).text()
    assert t.item(1, 0).text().startswith("backend.rpi5")
    assert os.path.basename(b_img) in t.cellWidget(1, 1).currentText()
    assert "/dev/sdc" in t.item(1, 2).text()
    # and the first assignment actually resolved to that file
    assert started and started[0][1][started[0][1].index("--artifact") + 1] == a_img


def test_plan_row_defaults_to_exactly_what_flash_next_resolved_before(page, tmp_path,
                                                                      monkeypatch):
    """Rendering the table must not change what is written: the preselected image is
    pick_artifact(recorded set, planned flavour)."""
    img, live, inst = _artifacts(
        tmp_path, "b-x86-amd64-omnibus-prod-1.img",
        "b-x86-amd64-omnibus-prod-1.live.iso",
        "b-x86-amd64-omnibus-prod-1.installer.iso")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path),
                               flavor="live")]
    started = _plan_page(monkeypatch, page, sets={"omnibus.x86": (inst, live, img)},
                         plan=plan, targets=[SDB])
    page._maybe_auto_flash()
    assert page._plan_image_for(0) == live == ft.pick_artifact((inst, live, img),
                                                               "live")
    assert started[0][1][started[0][1].index("--artifact") + 1] == live


def test_changing_a_plan_row_image_changes_what_that_device_gets(page, tmp_path,
                                                                 monkeypatch):
    """The override is read at the moment THAT row resolves, so retargeting device 2
    while device 1 writes is honoured."""
    img, live = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img",
                           "b-x86-amd64-omnibus-prod-1.live.iso")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    started = _plan_page(monkeypatch, page, sets={"omnibus.x86": (live, img)},
                         plan=plan, targets=[SDB, SDC])
    page._maybe_auto_flash()                       # resolves + "starts" row 0 only
    assert started[0][1][started[0][1].index("--artifact") + 1] == img
    combo = page.flash_plan_table.cellWidget(1, 1)
    combo.setCurrentIndex(combo.findData(live))    # retarget row 1 mid-flight
    page._flash_next()
    assert len(started) == 2
    assert started[1][1][started[1][1].index("--artifact") + 1] == live


def test_unresolvable_plan_row_still_refuses_loudly(page, tmp_path, monkeypatch):
    """THE guard: a row whose planned flavour was never built must keep skipping with
    the reason. Its combo must default to an explicit '(none …)', never to some other
    file that happens to be in the set."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path),
                               flavor="installer")]
    started = _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)},
                         plan=plan, targets=[SDB])
    page._maybe_auto_flash()
    assert started == []                            # nothing was written
    assert page._plan_image_for(0) == ""            # NOT silently defaulted to the .img
    assert "built no 'installer' artifact" in page.log.toPlainText()
    assert "SKIPPED" in page.flash_plan_table.item(0, 3).text()
    # the other file is still OFFERED — overriding is possible, but deliberate
    combo = page.flash_plan_table.cellWidget(0, 1)
    assert combo.findData(img) > 0


def test_overriding_an_unresolvable_row_writes_and_warns(page, tmp_path, monkeypatch):
    """Having refused, the table lets the operator say 'yes, that one' — and the
    mismatch is carried into the ONE confirmation as a caveat."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path),
                               flavor="installer")]
    started = _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)},
                         plan=plan, targets=[SDB])
    page._maybe_auto_flash()
    assert started == []
    combo = page.flash_plan_table.cellWidget(0, 1)
    combo.setCurrentIndex(combo.findData(img))
    assert "SKIPPED" not in page.flash_plan_table.item(0, 3).text()
    page._flash_queue = list(plan)                  # re-queue the refused row
    page._flash_plan_pos = 0
    page._flash_next()
    assert len(started) == 1
    assert started[0][1][started[0][1].index("--artifact") + 1] == img
    assert any("planned for the 'installer' artifact" in c
               for c in page._flash_caveats)


def test_plan_row_status_tracks_the_write(page, tmp_path, monkeypatch):
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)}, plan=plan,
               targets=[SDB])
    page._maybe_auto_flash()
    assert page.flash_plan_table.item(0, 3).text() == "writing…"
    page._flash_done(0)
    assert page.flash_plan_table.item(0, 3).text() == "written"
    page._flash_plan_pos = 1
    page._flash_done(3)
    assert "FAILED (rc=3)" in page.flash_plan_table.item(0, 3).text()


def test_plan_table_is_cleared_by_a_second_run(page, tmp_path, monkeypatch):
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)}, plan=plan,
               targets=[SDB])
    page._maybe_auto_flash()
    assert page.flash_plan_table.rowCount() == 1
    page._reset()
    assert page.flash_plan_table.rowCount() == 0
    assert page.flash_plan_box.isHidden()
