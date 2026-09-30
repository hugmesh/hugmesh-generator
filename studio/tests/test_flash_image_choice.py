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
    back to the default under the operator's cursor.

    This pins the PATH RESTORE (`prev`), which is what survives a rebuild — a new
    artifact appearing mid-session invalidates the skip-if-unchanged guard below, and
    the pick still has to come back."""
    img, live = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img",
                           "b-x86-amd64-omnibus-prod-1.live.iso")
    page._entry_artifact_sets = {"e1": (live, img)}
    page._refresh_flash_images()
    page.flash_image_combo.setCurrentIndex(page.flash_image_combo.findData(live))
    for _ in range(5):
        page._refresh_flash_images()
    assert page._selected_image() == live
    # a genuinely NEW artifact forces the rebuild; the pick must still survive it
    later, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-2.installer.iso")
    os.utime(later, (1_800_000_000, 1_800_000_000))
    page._entry_artifact_sets = {"e1": (later, live, img)}
    page._refresh_flash_images()
    assert page.flash_image_combo.count() == 3
    assert page._selected_image() == live


def test_refresh_skips_the_rebuild_when_nothing_changed(page, tmp_path):
    """The skip-if-unchanged guard itself: with the same candidates the combo is not
    torn down and rebuilt. Observed through a sentinel the rebuild would erase — a
    rebuild 24x a minute also shuts an open dropdown under the operator's hand, which
    an offscreen test cannot see."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e1": (img,)}
    page._refresh_flash_images()
    page.flash_image_combo.setItemText(0, "SENTINEL")
    for _ in range(5):
        page._refresh_flash_images()
    assert page.flash_image_combo.itemText(0) == "SENTINEL"
    assert page.flash_image_combo.count() == 1


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
    # The refusal already HAPPENED, so retargeting cannot un-say it: the verdict on a
    # row _flash_next has consumed stands until something actually writes that device.
    assert "SKIPPED" in page.flash_plan_table.item(0, 3).text()
    page._flash_queue = list(plan)                  # re-queue the refused row
    page._flash_plan_pos = 0
    page._flash_next()
    assert len(started) == 1
    assert started[0][1][started[0][1].index("--artifact") + 1] == img
    assert any("planned for the 'installer' artifact" in c
               for c in page._flash_caveats)
    # and once it IS queued again, the status follows the real write, not the combo
    assert page.flash_plan_table.item(0, 3).text() == "writing…"


def test_plan_row_status_tracks_the_write(page, tmp_path, monkeypatch):
    """Each row's Status is the outcome of ITS OWN write. Driven through two real
    assignments rather than by poking _flash_plan_pos, because which row a result
    belongs to is exactly what this pins."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)}, plan=plan,
               targets=[SDB, SDC])
    page._maybe_auto_flash()
    assert page.flash_plan_table.item(0, 3).text() == "writing…"
    page._flash_done(0)                      # row 0 succeeded, and chains row 1
    assert page.flash_plan_table.item(0, 3).text() == "written"
    assert page.flash_plan_table.item(1, 3).text() == "writing…"
    page._flash_done(3)                      # row 1 failed
    assert "FAILED (rc=3)" in page.flash_plan_table.item(1, 3).text()
    assert page.flash_plan_table.item(0, 3).text() == "written"   # row 0 untouched


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


# ══ C. per-image write progress, driven by BYTES ════════════════════════════════════
# NOTHING here opens a device. The one test that runs real `dd`/`xz` writes to an
# ordinary file under tmp_path: it exercises the REPORTING contract (dd's byte count
# vs the denominator flash-disk.sh computes), which is the same wherever the bytes go.
import subprocess                                                   # noqa: E402

REPO_DIR = GENERATOR_DIR
FLASH_SH = os.path.join(REPO_DIR, "scripts", "flash-disk.sh")


def test_parsers_read_dds_real_output_and_ignore_everything_else():
    assert ft.parse_write_total("[disk] Write-bytes: 54226059264") == 54226059264
    assert ft.parse_write_total("[disk] Write-bytes: 0") == 0
    assert ft.parse_write_total("[disk] Artifact : /x.img.xz [img.xz, 50.5G "
                                "uncompressed]") == 0
    assert ft.parse_dd_progress(
        "77245448192 bytes (77 GB, 72 GiB) copied, 1 s, 77.2 GB/s") == (
            77245448192, "77.2 GB/s")
    assert ft.parse_dd_progress(
        "3145728 bytes (3.1 MB, 3.0 MiB) copied, 2 s") == (3145728, "")
    for noise in ("400000+0 records in", "", ">>> Emerging (12 of 400) dev-libs/foo",
                  "==> Writing img to /dev/sdz (this can take a while)",
                  "[disk] Target   : /dev/sdz [64GiB]"):
        assert ft.parse_dd_progress(noise) == (0, "")
        assert ft.parse_write_total(noise) == 0


def test_flash_disk_sh_emits_the_denominator_on_the_write_path():
    """The `Write-bytes:` line must sit on the WRITE path — after the confirm and the
    unmount, before the first dd — so it is never printed for a run that aborted."""
    src = open(FLASH_SH, encoding="utf-8").read().splitlines()
    idx = {"confirm": -1, "writing": -1, "bytes": -1, "dd": -1}
    for i, ln in enumerate(src):
        if idx["confirm"] < 0 and "dl_confirm_destroy" in ln and "()" not in ln:
            idx["confirm"] = i
        if idx["writing"] < 0 and 'dl_step "Writing ' in ln:
            idx["writing"] = i
        if idx["bytes"] < 0 and 'dl_info "Write-bytes:' in ln:
            idx["bytes"] = i
        if idx["dd"] < 0 and idx["writing"] >= 0 and ln.lstrip().startswith(("dd ", "| dd ")):
            idx["dd"] = i
    assert all(v >= 0 for v in idx.values()), idx
    assert idx["confirm"] < idx["writing"] < idx["bytes"] < idx["dd"], idx
    assert 'dl_info "Write-bytes: ${ART_SIZE}"' in "\n".join(src)


def test_real_dd_bytes_match_the_denominator_the_script_computes(tmp_path):
    """END TO END, no device: build a small .img.xz, compute the denominator the way
    flash-disk.sh does (xz --robot --list totals field 5), then run the script's OWN
    compressed write stanza against a REGULAR FILE in tmp_path and check dd's reported
    bytes equal it.

    of= is an ordinary file, never a block device: the point is the REPORTING contract
    (does dd's byte count land on the number the denominator promises), and that is
    identical wherever the bytes go. `conv=fsync` is kept from the real arm — measured:
    it is what rules /dev/null out as the sink, since fsync() there returns EINVAL.

    This is what makes the bar honest: numerator and denominator are the same number
    at 100%, measured, not assumed."""
    raw = tmp_path / "t.img"
    raw.write_bytes(os.urandom(1 << 20) * 8)          # 8 MiB, poorly compressible
    subprocess.run(["xz", "-0", "-T1", str(raw)], check=True)
    xz = str(raw) + ".xz"
    listing = subprocess.run(["xz", "--robot", "--list", xz], check=True,
                             capture_output=True, text=True).stdout
    total = int([l.split("\t")[4] for l in listing.splitlines()
                 if l.startswith("totals")][0])
    assert total == 8 << 20
    # the script's compressed arm, verbatim, with of= an ordinary file
    out = subprocess.run(
        ["bash", "-o", "pipefail", "-c",
         f'xz -dc "{xz}" | dd of="{tmp_path / "sink.raw"}" bs=4M iflag=fullblock '
         f'conv=fsync status=progress'],
        capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    seen = [ft.parse_dd_progress(l)[0]
            for l in (out.stdout + out.stderr).replace("\r", "\n").splitlines()]
    assert max(seen) == total, (max(seen), total)


def test_bar_advances_on_bytes_from_a_real_stream(page):
    """Feed the page the exact lines flash-disk.sh + dd produce. The bar must track
    bytes, and must be 0 before any byte count arrives."""
    page.log = _Lines()
    page._begin_flash_progress("/w/b-x86-amd64-omnibus-prod-1.img.xz")
    assert page.flash_progress_bar.maximum() == 0        # indeterminate: no total yet
    page._on_flash_line("[disk] Write-bytes: 1000")
    assert page.flash_progress_bar.maximum() == 100
    assert page.flash_progress_bar.value() == 0
    page._on_flash_line("250 bytes (250 B, 250 B) copied, 1 s, 250 B/s")
    assert page.flash_progress_bar.value() == 25
    page._on_flash_line("750 bytes (750 B, 750 B) copied, 3 s, 250 B/s")
    assert page.flash_progress_bar.value() == 75
    page._on_flash_line("1000 bytes (1.0 kB, 1000 B) copied, 4 s, 250 B/s")
    assert page.flash_progress_bar.value() == 100
    assert "250 B/s" in page.flash_progress_label.text()
    # every line still reaches the log pane
    assert any("Write-bytes" in l for l in page.log.lines)


def test_bar_never_moves_on_noise(page):
    """A line that is not a dd byte count must not move the bar — the anti-lie check."""
    page.log = _Lines()
    page._begin_flash_progress("/w/x.img")
    page._on_flash_line("[disk] Write-bytes: 1000")
    page._on_flash_line("500 bytes (500 B, 500 B) copied, 1 s")
    assert page.flash_progress_bar.value() == 50
    for noise in ("==> Writing img to /dev/sdz (this can take a while)",
                  "400000+0 records in", "[disk] Target   : /dev/sdz [64GiB]",
                  ">>> Emerging (12 of 400) dev-libs/foo-1.2", ""):
        page._on_flash_line(noise)
        assert page.flash_progress_bar.value() == 50


def test_no_denominator_shows_activity_and_says_so(page):
    """flash-disk.sh could not size the artifact (ART_SIZE=0, or DL_QUIET). The bar
    must go indeterminate and the label must refuse to call it progress."""
    page.log = _Lines()
    page._begin_flash_progress("/w/x.img")
    page._on_flash_line("[disk] Write-bytes: 0")
    page._on_flash_line("4194304 bytes (4.2 MB, 4.0 MiB) copied, 1 s, 4.2 MB/s")
    assert page.flash_progress_bar.minimum() == 0
    assert page.flash_progress_bar.maximum() == 0        # Qt's busy indicator
    label = page.flash_progress_label.text()
    assert "activity, not progress" in label
    assert "4.0 MiB written" in label


def test_image_n_of_m_counts_the_plan(page, tmp_path, monkeypatch):
    a, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    b, = _artifacts(tmp_path, "b-rpi5-arm64-backend-prod-2.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "backend.rpi5", "backend", "arm64", str(tmp_path))]
    page._entry_artifact_sets = {"omnibus.x86": (a,), "backend.rpi5": (b,)}
    page._entry_artifacts = {}
    page.wiz.flash_plan = list(plan)
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB, SDC])
    monkeypatch.setattr(pg, "confirm_flash", lambda *a, **k: pg.FLASH_OK)
    monkeypatch.setattr(pg, "hold_thread", lambda w: w)

    class _NoWorker:
        def __init__(self, argv, gen):
            pass

        line = SimpleNamespace(connect=lambda *_: None)
        done = SimpleNamespace(connect=lambda *_: None)

        def start(self):
            pass

        def isRunning(self):
            return False
    monkeypatch.setattr(pg, "_FlashWorker", _NoWorker)
    page._maybe_auto_flash()
    assert "Image 1 of 2" in page.flash_progress_label.text()
    assert os.path.basename(a) in page.flash_progress_label.text()
    page._flash_done(0)                       # chains to assignment 2
    assert "Image 2 of 2" in page.flash_progress_label.text()
    assert os.path.basename(b) in page.flash_progress_label.text()


def test_the_flash_button_is_always_image_1_of_1(page, tmp_path, monkeypatch):
    """A Flash… after a 3-device plan must not inherit 'Image 3 of 3'."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e1": (img,)}
    page.log = _Lines()
    page._flash_image_total, page._flash_image_index = 3, 3   # a previous plan run
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    page._refresh_flash_targets()
    monkeypatch.setattr(page, "_start_flash", lambda t, argv=None: None)
    page._flash_clicked()
    assert (page._flash_image_total, page._flash_image_index) == (1, 1)


def test_a_failed_write_does_not_snap_the_bar_to_100(page):
    page.log = _Lines()
    page._begin_flash_progress("/w/x.img")
    page._on_flash_line("[disk] Write-bytes: 1000")
    page._on_flash_line("300 bytes (300 B, 300 B) copied, 1 s")
    page._finish_flash_progress(1)
    assert page.flash_progress_bar.value() == 30
    assert "FAILED (rc=1)" in page.flash_progress_label.text()
    page._finish_flash_progress(0)
    assert page.flash_progress_bar.value() == 100
    assert page.flash_progress_label.text().endswith("written")


# ══ D. the validator: check the image(s) WITHOUT flashing ═══════════════════════════
from hugmesh_studio.core import flash_validate as fv                # noqa: E402

GIB = 1 << 30


def _img(tmp_path, name, *, size=64 << 20, gpt=True):
    """A minimally-plausible whole-disk .img: a partition-table signature plus bulk."""
    p = tmp_path / name
    head = bytearray(0x8010)
    if gpt:
        head[510:512] = b"\x55\xaa"
        head[512:520] = b"EFI PART"
    p.write_bytes(bytes(head) + b"\0" * max(0, size - len(head)))
    return str(p)


def _iso(tmp_path, name, *, size=64 << 20):
    p = tmp_path / name
    head = bytearray(0x8010)
    head[0x8001:0x8006] = b"CD001"
    p.write_bytes(bytes(head) + b"\0" * max(0, size - len(head)))
    return str(p)


def test_validator_passes_a_sane_image_and_says_what_it_did_not_check(tmp_path):
    p = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    r = fv.check_image(p, device_size=64 * GIB, device_path="/dev/sdb",
                       role="omnibus", arch="x86")
    assert r.ok
    names = {c.name: c for c in r.checks}
    assert names["exists"].state == fv.OK
    assert names["format"].state == fv.OK and "GPT" in names["format"].detail
    assert names["size"].state == fv.OK
    assert names["naming"].state == fv.OK
    # the build wrote no checksum -> NOT VERIFIED, never a silent pass
    assert names["checksum"].state == fv.SKIP
    assert "checksum" in r.unverified
    assert "not verified" in r.text()


def test_validator_catches_an_image_too_big_for_the_device(tmp_path):
    p = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img", size=64 << 20)
    r = fv.check_image(p, device_size=32 << 20, device_path="/dev/sdb",
                       role="omnibus", arch="x86")
    assert not r.ok
    bad = [c for c in r.checks if c.state == fv.BAD]
    assert len(bad) == 1 and bad[0].name == "size"
    assert "will not fit" in bad[0].detail


def test_validator_catches_a_missing_a_truncated_and_a_headless_image(tmp_path):
    missing = fv.check_image(str(tmp_path / "gone.img"), role="omnibus", arch="x86")
    assert not missing.ok and missing.checks[0].name == "exists"

    tiny = _img(tmp_path, "b-x86-amd64-omnibus-prod-2.img", size=4096)
    r = fv.check_image(tiny, device_size=64 * GIB, role="omnibus", arch="x86")
    assert not r.ok
    assert any(c.name == "size" and "too small" in c.detail for c in r.checks)

    headless = tmp_path / "b-x86-amd64-omnibus-prod-3.img"
    headless.write_bytes(b"\0" * (64 << 20))       # no MBR sig, no GPT header
    r2 = fv.check_image(str(headless), device_size=64 * GIB, role="omnibus",
                        arch="x86")
    assert not r2.ok
    assert any(c.name == "format" and "no partition table" in c.detail
               for c in r2.checks)


def test_validator_catches_the_wrong_arch_role_and_flavour(tmp_path):
    p = _iso(tmp_path, "b-rpi5-arm64-backend-prod-1.live.iso")
    r = fv.check_image(p, device_size=64 * GIB, device_path="/dev/sdb",
                       role="omnibus", arch="x86", flavor="installer")
    assert not r.ok
    naming = [c for c in r.checks if c.name == "naming"][0]
    assert naming.state == fv.BAD
    assert "does NOT carry" in naming.detail and "not the planned 'installer'" \
        in naming.detail


def test_validator_verifies_a_checksum_when_the_build_left_one(tmp_path):
    import hashlib
    p = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    digest = hashlib.sha256(open(p, "rb").read()).hexdigest()
    (tmp_path / "SHA256SUMS").write_text(
        f"{digest}  {os.path.basename(p)}\n", encoding="utf-8")
    r = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    assert r.ok
    ck = [c for c in r.checks if c.name == "checksum"][0]
    assert ck.state == fv.OK and "SHA256SUMS" in ck.detail
    # and a WRONG sum is caught
    (tmp_path / "SHA256SUMS").write_text(
        f"{'0' * 64}  {os.path.basename(p)}\n", encoding="utf-8")
    r2 = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    assert not r2.ok
    assert any(c.name == "checksum" and "MISMATCH" in c.detail for c in r2.checks)


def test_validator_handles_a_real_xz_artifact(tmp_path):
    """The default-build shape: a .img.xz whose WRITE size is the uncompressed size,
    not the file size. Built with real xz so the index is real."""
    raw = tmp_path / "b-x86-amd64-omnibus-prod-1.img"
    raw.write_bytes(b"\0" * (64 << 20))
    subprocess.run(["xz", "-0", "-T1", str(raw)], check=True)
    p = str(raw) + ".xz"
    assert os.path.getsize(p) < (1 << 20)          # tiny on disk…
    assert fv.uncompressed_size(p) == 64 << 20     # …64 MiB written
    r = fv.check_image(p, device_size=32 << 20, device_path="/dev/sdb",
                       role="omnibus", arch="x86", flavor="img")
    assert not r.ok, "a 64 MiB write onto a 32 MiB device must be refused"
    assert any(c.name == "size" and "will not fit" in c.detail for c in r.checks)
    r2 = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86",
                        flavor="img")
    assert r2.ok
    assert any(c.name == "format" and "valid xz" in c.detail for c in r2.checks)
    # a corrupted xz is caught by the magic, not by writing it
    bad = tmp_path / "b-x86-amd64-omnibus-prod-9.img.xz"
    bad.write_bytes(b"not an xz stream at all" + b"\0" * (32 << 20))
    r3 = fv.check_image(str(bad), device_size=64 * GIB, role="omnibus", arch="x86")
    assert not r3.ok
    assert any(c.name == "format" and "no xz magic" in c.detail for c in r3.checks)


def test_validator_refuses_a_non_flashable_file(tmp_path):
    p = tmp_path / "b-x86-amd64-omnibus-prod-1.fs.tar.xz"
    p.write_bytes(b"\0" * (64 << 20))
    r = fv.check_image(str(p), device_size=64 * GIB, role="omnibus", arch="x86")
    assert not r.ok and r.checks[0].name == "kind"


def test_check_button_reports_inline_and_writes_nothing(page, qapp, tmp_path,
                                                        monkeypatch):
    """The GUI override point: the button runs the checks off-thread, prints them into the
    inline pane, and never reaches _start_flash."""
    p = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e1": (p,)}
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    monkeypatch.setattr(page, "_flash_role_arch", lambda: ("omnibus", "x86"))
    started = []
    monkeypatch.setattr(page, "_start_flash",
                        lambda *a, **k: started.append(a))
    page._refresh_flash_targets()
    assert page.flash_check_out.isHidden()
    page._check_images_clicked()
    page.check_worker.wait(20000)
    for _ in range(200):
        qapp.processEvents()
        if "checked" in page.flash_check_out.toPlainText() or \
                "PROBLEM" in page.flash_check_out.toPlainText():
            break
    out = page.flash_check_out.toPlainText()
    assert not page.flash_check_out.isHidden()
    assert "Nothing has been written." in out
    assert os.path.basename(p) in out and "/dev/sdb" in out
    assert started == []                      # never a route into a write


def test_check_button_checks_every_plan_row(page, qapp, tmp_path, monkeypatch):
    a = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    b = _iso(tmp_path, "b-rpi5-arm64-backend-prod-2.live.iso")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "backend.rpi5", "backend", "arm64", str(tmp_path))]
    page._entry_artifact_sets = {"omnibus.x86": (a,), "backend.rpi5": (b,)}
    page._entry_artifacts = {}
    page.wiz.flash_plan = list(plan)
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB, SDC])
    monkeypatch.setattr(page, "_start_flash", lambda *a, **k: None)
    page._maybe_auto_flash()
    jobs = page._check_jobs()
    assert [j["path"] for j in jobs] == [a, b]
    assert [j["device_path"] for j in jobs] == ["/dev/sdb", "/dev/sdc"]
    assert [j["arch"] for j in jobs] == ["x86", "arm64"]
    page._check_images_clicked()
    page.check_worker.wait(20000)
    for _ in range(200):
        qapp.processEvents()
        if "image(s)" in page.flash_check_out.toPlainText() and \
                "Nothing has been written." in page.flash_check_out.toPlainText():
            break
    out = page.flash_check_out.toPlainText()
    assert os.path.basename(a) in out and os.path.basename(b) in out
    assert "/dev/sdb" in out and "/dev/sdc" in out


def test_check_names_a_plan_row_with_no_image(page, qapp, tmp_path, monkeypatch):
    """An unresolved row must appear in the report, not be quietly dropped."""
    a = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path),
                               flavor="installer")]
    page._entry_artifact_sets = {"omnibus.x86": (a,)}
    page._entry_artifacts = {}
    page.wiz.flash_plan = list(plan)
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    monkeypatch.setattr(page, "_start_flash", lambda *a, **k: None)
    page._maybe_auto_flash()
    jobs = page._check_jobs()
    # The job must be THE PLAN ROW, not the standalone fallback — dropping the row and
    # falling through to the standalone pair also yields path == "", so asserting the
    # empty path alone passes either way. Pin the fields that tell them apart.
    assert len(jobs) == 1
    assert jobs[0]["path"] == ""
    assert jobs[0]["device_path"] == "/dev/sdb"     # the ROW's device
    assert jobs[0]["flavor"] == "installer"         # the ROW's planned flavour
    assert jobs[0]["role"] == "omnibus" and jobs[0]["arch"] == "x86"
    assert jobs[0]["device_size"] == SDB.size
    r = fv.check_image("", device_path="/dev/sdb")
    assert not r.ok and "no image is selected" in r.text()


# ══ E. the land-lane closures: whose result is whose, and what nothing pinned ═══════
# Every test below was written because a skeptic found production wrong (E1-E5) or
# found production RIGHT but unpinned (E6-E15). /dev/sdz is deliberate: /dev/sdb is a
# real attached disk on the build host, and nothing in a fixture should name it.
SDZ = ft.FlashTarget("/dev/sdz", 64 * (1 << 30), "Land Stick", "usb", True, "usb")


def _no_worker(monkeypatch, accept=True):
    """Drive the REAL _start_flash (so the destroy gate, the progress arming and the
    busy guard are all exercised) while launching no subprocess at all."""
    monkeypatch.setattr(pg, "confirm_flash",
                        lambda *a, **k: pg.FLASH_OK if accept else pg.FLASH_CANCEL)
    monkeypatch.setattr(pg, "hold_thread", lambda w: w)

    class _NoWorker:
        def __init__(self, argv, gen):
            self.argv = argv

        line = SimpleNamespace(connect=lambda *_: None)
        done = SimpleNamespace(connect=lambda *_: None)

        def start(self):
            pass

        def isRunning(self):
            return False
    monkeypatch.setattr(pg, "_FlashWorker", _NoWorker)
    return _NoWorker


def test_a_later_standalone_flash_never_repaints_a_plan_row(page, tmp_path,
                                                            monkeypatch):
    """THE BLOCKER: _flash_done used to derive the row from _flash_plan_pos, so after a
    plan drained an unrelated hand flash repainted the LAST row — a device that was
    never written could read 'written'. Both directions."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    started = _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)},
                         plan=plan, targets=[SDB, SDZ])
    page._maybe_auto_flash()
    page._flash_done(1)                            # the REAL write failed
    assert page.flash_plan_table.item(0, 3).text() == "FAILED (rc=1)"
    assert page._flash_queue == []                 # the plan has drained

    # now an unrelated flash of a DIFFERENT stick, by hand, which succeeds
    page._refresh_flash_targets()
    page.flash_combo.setCurrentIndex(page.flash_combo.findData("/dev/sdz"))
    page._flash_clicked()
    assert started and started[-1][0] == "/dev/sdz"
    page._flash_done(0)
    assert page.flash_plan_table.item(0, 3).text() == "FAILED (rc=1)", \
        "a hand flash of another device rewrote a plan row's verdict"


def test_a_failing_standalone_flash_never_reddens_a_written_plan_row(page, tmp_path,
                                                                     monkeypatch):
    """The other direction: two genuinely written rows must not become FAILED."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    started = _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)},
                         plan=plan, targets=[SDB, SDC, SDZ])
    page._maybe_auto_flash()
    page._flash_done(0)
    page._flash_done(0)
    assert [page.flash_plan_table.item(r, 3).text() for r in (0, 1)] == \
        ["written", "written"]
    page._refresh_flash_targets()
    page.flash_combo.setCurrentIndex(page.flash_combo.findData("/dev/sdz"))
    page._flash_clicked()
    page._flash_done(1)                            # the hand flash failed
    assert [page.flash_plan_table.item(r, 3).text() for r in (0, 1)] == \
        ["written", "written"]


def test_retargeting_a_resolved_row_does_not_reopen_it(page, tmp_path, monkeypatch):
    """A row whose write already finished must not go back to 'queued': nothing is
    queued, and nothing will ever revisit that device."""
    img, live = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img",
                           "b-x86-amd64-omnibus-prod-1.live.iso")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    _plan_page(monkeypatch, page, sets={"omnibus.x86": (live, img)}, plan=plan,
               targets=[SDB])
    page._maybe_auto_flash()
    page._flash_done(0)
    assert page.flash_plan_table.item(0, 3).text() == "written"
    assert page._flash_queue == []
    combo = page.flash_plan_table.cellWidget(0, 1)
    assert not combo.isEnabled(), "a resolved row still invites a change it cannot make"
    combo.setCurrentIndex(combo.findData(live))
    assert page.flash_plan_table.item(0, 3).text() == "written"


def test_the_standalone_default_never_crosses_architecture(page, tmp_path):
    """A multi-entry run unions every entry's images into one combo. Preselecting the
    newest of them emitted '--arch x86' beside an arm64 --artifact, and flash-disk.sh
    takes an explicit artifact VERBATIM, so nothing downstream would have caught it."""
    x86, arm = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img",
                          "b-rpi5-arm64-backend-prod-2.img")     # arm64 is NEWER
    page._entry_artifact_sets = {"e1": (x86,), "e2": (arm,)}
    page._refresh_flash_images()
    assert page._selected_image() == x86
    argv = page._flash_argv_for(SDB)
    assert argv[argv.index("--arch") + 1] == "x86"
    assert argv[argv.index("--artifact") + 1] == x86
    # the other architecture is still OFFERED — choosing it stays possible, but only
    # as a deliberate act
    assert arm in [page.flash_image_combo.itemData(i)
                   for i in range(page.flash_image_combo.count())]


def test_no_image_of_this_arch_means_no_artifact_at_all(page, tmp_path):
    """When the union holds nothing of this build's architecture the honest default is
    NONE — the pre-#415 auto-pick path — never the other architecture's newest file."""
    arm, = _artifacts(tmp_path, "b-rpi5-arm64-backend-prod-2.img")
    page._entry_artifact_sets = {"e2": (arm,)}
    page._refresh_flash_images()
    assert page._selected_image() == ""
    assert "architecture" in page.flash_image_combo.currentText()
    assert "--artifact" not in page._flash_argv_for(SDB)


def test_stopping_the_flash_says_so_on_every_unwritten_row(page, tmp_path,
                                                           monkeypatch):
    """_detach_from_window clears the queue so a queued destructive write cannot fire
    at a closed window. The rows it dropped must stop claiming they are 'queued'."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDZ, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    _plan_page(monkeypatch, page, sets={"omnibus.x86": (img,)}, plan=plan,
               targets=[SDB, SDC, SDZ])
    page._maybe_auto_flash()
    assert page.flash_plan_table.item(0, 3).text() == "writing…"
    page._detach_from_window()
    assert page._flash_queue == []
    for r in (1, 2):
        assert "not written" in page.flash_plan_table.item(r, 3).text()
        assert not page.flash_plan_table.cellWidget(r, 1).isEnabled()
    # row 0's worker is joined just below the clear and delivers its own outcome, so
    # it is deliberately left alone
    assert page.flash_plan_table.item(0, 3).text() == "writing…"


def test_a_busy_flasher_marks_the_row_not_started(page, tmp_path, monkeypatch):
    """_start_flash returns early when the previous worker is still running. The row
    had already been painted 'writing…', so the drop read as a write in progress on a
    device nothing had touched."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDC, "omnibus.x86", "omnibus", "x86", str(tmp_path))]
    page._entry_artifact_sets = {"omnibus.x86": (img,)}
    page._entry_artifacts = {}
    page.wiz.flash_plan = list(plan)
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB, SDC])

    confirms = []
    monkeypatch.setattr(pg, "confirm_flash",
                        lambda *a, **k: confirms.append(a) or pg.FLASH_OK)

    class _Busy:
        def isRunning(self):
            return True

        def wait(self, _ms=0):
            return False
    page.flash_worker = _Busy()

    page._maybe_auto_flash()
    assert confirms == [], "a busy flasher must not even raise the destroy dialog"
    assert page._flash_queue == []
    for r in (0, 1):
        assert page.flash_plan_table.item(r, 3).text() == "NOT started — flasher busy"
    assert any("was NOT started" in ln for ln in page.log.lines)


def test_a_declined_row_and_a_gone_device_and_a_swapped_stick_each_say_so(
        page, tmp_path, monkeypatch):
    """Three of the four plan-row refusal statuses had no test at all: only 'no image
    resolved' was pinned, so a stale 'writing…' could ship green."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e": (img,)}
    page._entry_artifacts = {}
    page.log = _Lines()
    _no_worker(monkeypatch, accept=False)          # every confirmation is DECLINED

    plan = [ft.FlashAssignment(SDB, "e", "omnibus", "x86", str(tmp_path))]
    page.wiz.flash_plan = list(plan)
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    page._maybe_auto_flash()
    assert page.flash_plan_table.item(0, 3).text() == "cancelled — not written"

    # device unplugged between the plan and the write
    page._reset()
    page._entry_artifact_sets = {"e": (img,)}
    page.log = _Lines()
    page.wiz.flash_plan = list(plan)
    monkeypatch.setattr(ft, "list_targets", lambda: [SDC])
    page._maybe_auto_flash()
    assert page.flash_plan_table.item(0, 3).text() == "SKIPPED — device gone"

    # same /dev node, DIFFERENT stick (the TOCTOU the identity check exists for)
    page._reset()
    page._entry_artifact_sets = {"e": (img,)}
    page.log = _Lines()
    page.wiz.flash_plan = list(plan)
    swapped = ft.FlashTarget("/dev/sdb", 8 * (1 << 30), "Someone Else's", "usb",
                             True, "usb")
    monkeypatch.setattr(ft, "list_targets", lambda: [swapped])
    page._maybe_auto_flash()
    assert page.flash_plan_table.item(0, 3).text() == "SKIPPED — device identity changed"


def test_three_rows_with_a_skip_number_and_attribute_correctly(page, tmp_path,
                                                               monkeypatch):
    """Sequencing was only ever driven at two resolvable rows. A SKIPPED row in the
    middle is where an off-by-one in the row attribution would actually show."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "e", "omnibus", "x86", str(tmp_path),
                               flavor="installer"),          # nothing built: SKIP
            ft.FlashAssignment(SDC, "e", "omnibus", "x86", str(tmp_path)),
            ft.FlashAssignment(SDZ, "e", "omnibus", "x86", str(tmp_path))]
    page._entry_artifact_sets = {"e": (img,)}
    page._entry_artifacts = {}
    page.wiz.flash_plan = list(plan)
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB, SDC, SDZ])
    _no_worker(monkeypatch)

    page._maybe_auto_flash()
    # row 0 refused, row 1 is the one actually being written — and it is image 2 of 3
    assert page.flash_plan_table.item(0, 3).text() == "SKIPPED — no image resolved"
    assert page.flash_plan_table.item(1, 3).text() == "writing…"
    assert "Image 2 of 3" in page.flash_progress_label.text()
    page._flash_done(0)
    assert page.flash_plan_table.item(1, 3).text() == "written"
    assert page.flash_plan_table.item(2, 3).text() == "writing…"
    assert "Image 3 of 3" in page.flash_progress_label.text()
    page._flash_done(2)
    assert [page.flash_plan_table.item(r, 3).text() for r in range(3)] == \
        ["SKIPPED — no image resolved", "written", "FAILED (rc=2)"]


def test_the_check_button_re_enables_after_the_check(page, tmp_path, monkeypatch):
    """A button that never comes back is a dead control; nothing pinned it."""
    p = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e1": (p,)}
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    page._refresh_flash_targets()
    started = {}

    class _Sync:
        def __init__(self, jobs):
            self.jobs = jobs
            self.done = SimpleNamespace(connect=lambda f: started.setdefault("f", f))

        def isRunning(self):
            return False

        def start(self):
            started["f"]([fv.check_image(**j) for j in self.jobs])
    monkeypatch.setattr(pg, "hold_thread", lambda w: w)
    monkeypatch.setattr(pg, "_ImageCheckWorker", _Sync)
    page._check_images_clicked()
    assert page.flash_check_btn.isEnabled(), \
        "the Check button never came back — one click kills the control"
    assert not page.flash_check_out.isHidden()
    assert "Nothing has been written." in page.flash_check_out.toPlainText()


def test_a_check_that_raises_is_reported_not_swallowed(tmp_path):
    """The worker's 'a check must never take the window with it' guard: a check that
    blows up must come back as a BAD report, not vanish and not kill the thread."""
    w = pg._ImageCheckWorker([{"path": str(tmp_path / "x.img"), "bogus_kwarg": 1}])
    out = []
    w.done = SimpleNamespace(emit=out.append)
    w.run()
    assert len(out) == 1 and len(out[0]) == 1
    rep = out[0][0]
    assert not rep.ok
    assert any(c.name == "check" and "the check itself failed" in c.detail
               for c in rep.checks)


def test_report_text_with_nothing_to_check_is_not_a_pass(tmp_path):
    """report_text([]) must never render as a clean bill of health."""
    txt = fv.report_text([])
    assert "Nothing to check" in txt
    assert "no problems found" not in txt
    # and the real summary still distinguishes pass from fail
    good = fv.check_image(_img(tmp_path, "b-x86-amd64-omnibus-prod-1.img"),
                          device_size=64 * GIB, role="omnibus", arch="x86")
    assert "no problems found" in fv.report_text([good])


@pytest.mark.parametrize("suffix", [".sha256", ".sha256sum"])
def test_validator_reads_the_per_image_checksum_sidecars(tmp_path, suffix):
    """Only the SHA256SUMS form was exercised; the two per-image sidecars were not, and
    a broken reader degrades to the BENIGN 'not verified' state rather than a failure."""
    import hashlib
    p = _img(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    digest = hashlib.sha256(open(p, "rb").read()).hexdigest()
    (tmp_path / (os.path.basename(p) + suffix)).write_text(
        f"{digest}  {os.path.basename(p)}\n", encoding="utf-8")
    r = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    ck = [c for c in r.checks if c.name == "checksum"][0]
    assert ck.state == fv.OK and suffix in ck.detail
    # a BARE digest (no filename column) is the other spelling builds emit
    (tmp_path / (os.path.basename(p) + suffix)).write_text(digest + "\n",
                                                           encoding="utf-8")
    r2 = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    assert [c for c in r2.checks if c.name == "checksum"][0].state == fv.OK
    # and a WRONG one in a sidecar is caught, not skipped
    (tmp_path / (os.path.basename(p) + suffix)).write_text("0" * 64 + "\n",
                                                           encoding="utf-8")
    r3 = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    assert not r3.ok
    assert any(c.name == "checksum" and "MISMATCH" in c.detail for c in r3.checks)


def test_artifact_matches_still_needs_the_arch_anchor(tmp_path):
    """The extracted artifact_matches' ARCH half, pinned in THIS file: the flasher's
    glob and the validator's naming verdict share it, and the #415 default now leans on
    it too, so it must not be reachable by role alone."""
    assert ft.artifact_matches("b-x86-amd64-omnibus-prod-1.img",
                               role="omnibus", arch="x86")
    assert not ft.artifact_matches("b-rpi5-arm64-omnibus-prod-1.img",
                                   role="omnibus", arch="x86")
    assert not ft.artifact_matches("b-omnibus-prod-1.img", role="omnibus", arch="x86")
    assert ft.artifact_arch_matches("b-x86-amd64-omnibus-prod-1.img", "x86")
    assert ft.artifact_arch_matches("b-rpi5-aarch64-backend-prod-1.img", "arm64")
    assert not ft.artifact_arch_matches("b-rpi5-arm64-backend-prod-1.img", "x86")
    # the validator's naming verdict rides on the same anchor
    p = _img(tmp_path, "b-rpi5-arm64-omnibus-prod-1.img")
    r = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    assert not r.ok
    assert any(c.name == "naming" and c.state == fv.BAD for c in r.checks)


def test_a_hybrid_iso_is_reported_as_usb_bootable(tmp_path):
    """The ISO verdict's hybrid MBR/GPT detail is what tells an operator the .iso can
    go on a stick at all."""
    plain = _iso(tmp_path, "b-x86-amd64-omnibus-prod-1.installer.iso")
    r0 = fv.check_image(plain, device_size=64 * GIB, role="omnibus", arch="x86")
    fmt0 = [c for c in r0.checks if c.name == "format"][0]
    assert fmt0.state == fv.OK and fmt0.detail == "ISO9660"      # NOT hybrid

    p = _iso(tmp_path, "b-x86-amd64-omnibus-prod-1.live.iso")
    with open(p, "r+b") as fh:
        fh.seek(510)
        fh.write(b"\x55\xaa" + b"EFI PART")                     # 55aa@510, GPT@512
    r = fv.check_image(p, device_size=64 * GIB, role="omnibus", arch="x86")
    fmt = [c for c in r.checks if c.name == "format"][0]
    assert fmt.state == fv.OK and "ISO9660" in fmt.detail
    assert "hybrid" in fmt.detail and "USB-bootable" in fmt.detail


def test_the_image_combo_and_the_argv_search_the_same_work_dir(page, tmp_path):
    """Two spellings of "where this run's artifacts are" had drifted: the combo
    searched _work_dir() and the argv named a second expression."""
    assert page._flash_work_dir() == page._work_dir()
    page._entry_artifact_sets = {}
    page._session = SimpleNamespace(workdir="")            # falsy session workdir
    assert page._flash_work_dir() == page._work_dir() != ""


def test_the_check_uses_the_device_size_the_stick_reports_now(page, tmp_path,
                                                              monkeypatch):
    """The fit verdict was computed against the size recorded when the plan was made,
    so a stick swapped for a smaller one still read as 'it fits'."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    plan = [ft.FlashAssignment(SDB, "e", "omnibus", "x86", str(tmp_path))]
    page._entry_artifact_sets = {"e": (img,)}
    page.wiz.flash_plan = list(plan)
    page.log = _Lines()
    smaller = ft.FlashTarget("/dev/sdb", 2 * (1 << 30), "Test Stick", "usb", True,
                             "usb")
    monkeypatch.setattr(ft, "list_targets", lambda: [smaller])
    monkeypatch.setattr(page, "_start_flash", lambda *a, **k: None)
    page._maybe_auto_flash()
    page._refresh_flash_targets()
    jobs = page._check_jobs()
    assert len(jobs) == 1 and jobs[0]["device_size"] == smaller.size


def test_a_flash_that_never_started_owns_no_plan_row(page, tmp_path, monkeypatch):
    """The invariant the blocker fix rests on: only an IN-FLIGHT plan row may own the
    next done signal. These exits are mutually redundant — with all of them in place a
    behavioural battery can only ever catch the last one standing — so each is pinned
    on its own postcondition here.

    (a) a DECLINED confirmation and (b) a busy flasher both start no worker at all."""
    page.log = _Lines()
    page._entry_artifact_sets = {}
    _no_worker(monkeypatch, accept=False)
    page._flash_active_row = 0                    # a row from an earlier plan
    page._start_flash(SDB)
    assert page._flash_active_row == -1, "a declined flash still owns a plan row"
    assert page._flash_cancelled is True

    class _Busy:
        def isRunning(self):
            return True

        def wait(self, _ms=0):
            return False
    page.flash_worker = _Busy()
    page._flash_active_row = 0
    page._start_flash(SDB)
    assert page._flash_active_row == -1, "a refused (busy) flash still owns a plan row"
    assert page._flash_busy_skipped is True


def test_a_finished_or_hand_started_flash_owns_no_plan_row(page, tmp_path,
                                                           monkeypatch):
    """(c) _flash_done consumes the row it just painted, and (d) the Flash… button
    disowns whatever row was last in flight before it starts. Same invariant, the two
    exits that fire AFTER a real write."""
    img, = _artifacts(tmp_path, "b-x86-amd64-omnibus-prod-1.img")
    page._entry_artifact_sets = {"e": (img,)}
    page.log = _Lines()
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    page._refresh_flash_targets()
    monkeypatch.setattr(page, "_start_flash", lambda t, argv=None: None)

    page._flash_active_row = 0
    page._flash_done(0)
    assert page._flash_active_row == -1, "a finished flash still owns its plan row"

    page._flash_active_row = 0
    page._flash_clicked()
    assert page._flash_active_row == -1, "the Flash… button inherited a plan row"
