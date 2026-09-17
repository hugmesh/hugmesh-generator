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
