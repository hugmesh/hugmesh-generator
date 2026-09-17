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
