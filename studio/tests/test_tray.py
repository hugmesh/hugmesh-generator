"""System-tray controller (gui/tray.py) — the two GUI bugs the user reported from the
running Studio:

  1. DUAL ICONS. A default launch used to append a MeshTray AND a StackTray — two
     indistinguishable navy-'S' QSystemTrayIcons. build_tray() now yields exactly ONE
     icon whose menu carries both sections; --tray/--stack-tray still yield the one asked.

  2. NO BUILD INDICATOR. The icon never changed while an image build ran. _render_icon()
     now paints a per-state corner badge (idle/building/error/complete) and the tray polls
     a status file the ProgressPage writes — so the icon shows progress even window-closed.

Headless on Qt's offscreen platform (QSystemTrayIcon.isSystemTrayAvailable() is False
there, so these go through the build_tray factory directly, bypassing app.py's guard).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui import tray as tray_mod          # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets              # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # keep the build-status file out of the real ~/.hugmesh during tests
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _count_trays(monkeypatch):
    """Count how many QSystemTrayIcons get instantiated — every tray goes through the
    pure-Python _ControlTray.__init__, so patching it is a reliable instance counter."""
    box = {"n": 0}
    orig = tray_mod._ControlTray.__init__

    def counting(self, *a, **k):
        box["n"] += 1
        orig(self, *a, **k)

    monkeypatch.setattr(tray_mod._ControlTray, "__init__", counting)
    return box


# ── bug 1: exactly one tray icon ──────────────────────────────────────────────────────
def test_default_launch_builds_exactly_one_tray(qapp, monkeypatch):
    box = _count_trays(monkeypatch)
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=True, show_stack=True)
    assert box["n"] == 1                                   # NOT two icons
    assert isinstance(tray, QtWidgets.QSystemTrayIcon)
    assert isinstance(tray, tray_mod.CombinedTray)


def test_default_tray_menu_carries_both_sections(qapp):
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=True, show_stack=True,
                               on_open_studio=lambda: None, on_open_golive=lambda: None)
    texts = " ".join(a.text() for a in tray.contextMenu().actions())
    # both node sections are present and clearly labelled in the single menu
    assert "mesh node" in texts
    assert "local stack" in texts
    # the shared actions survive
    assert "Open Image Studio…" in texts
    assert "Go Live…" in texts
    assert "Quit" in texts


def test_tray_flag_builds_mesh_only_single_icon(qapp, monkeypatch):
    box = _count_trays(monkeypatch)
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=True, show_stack=False)
    assert box["n"] == 1
    assert isinstance(tray, tray_mod.MeshTray)
    texts = " ".join(a.text() for a in tray.contextMenu().actions())
    assert "mesh node" in texts and "local stack" not in texts


def test_stack_tray_flag_builds_stack_only_single_icon(qapp, monkeypatch):
    box = _count_trays(monkeypatch)
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=False, show_stack=True)
    assert box["n"] == 1
    assert isinstance(tray, tray_mod.StackTray)
    texts = " ".join(a.text() for a in tray.contextMenu().actions())
    assert "local stack" in texts and "mesh node" not in texts


# ── bug 2: build-state badge overlay ──────────────────────────────────────────────────
def _img_bytes(state, percent=None):
    img = tray_mod._render_icon(state, percent).pixmap(64, 64).toImage()
    return bytes(img.constBits())


def test_overlay_pixmap_differs_per_state(qapp):
    idle = _img_bytes("idle")
    building = _img_bytes("building", 50)
    error = _img_bytes("error")
    complete = _img_bytes("complete")
    variants = {"idle": idle, "building": building, "error": error, "complete": complete}
    # every state renders a visibly different icon
    seen = list(variants.values())
    for i in range(len(seen)):
        for j in range(i + 1, len(seen)):
            assert seen[i] != seen[j], "two build states rendered identical icons"


def test_building_badge_differs_by_percent(qapp):
    assert _img_bytes("building", 10) != _img_bytes("building", 90)
    # idle is the plain brand icon; building is not
    assert _img_bytes("building", 0) != _img_bytes("idle")


# ── bug 2: status file + tray poll ────────────────────────────────────────────────────
def test_build_status_roundtrip(qapp):
    assert tray_mod.read_build_status() is None            # absent -> None (idle)
    tray_mod.write_build_status("building", percent=42, running=1, total=3)
    data = tray_mod.read_build_status()
    assert data == {"state": "building", "percent": 42, "running": 1, "total": 3}


def test_tray_reflects_build_status_file(qapp):
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=True, show_stack=True)
    assert tray._build_state == "idle"                     # no file yet
    idle_icon = _img_bytes("idle")

    tray_mod.write_build_status("building", percent=73, running=1, total=1)
    tray._poll_build_status()
    assert tray._build_state == "building" and tray._build_percent == 73
    assert "73%" in tray.toolTip()
    assert bytes(tray.icon().pixmap(64, 64).toImage().constBits()) != idle_icon

    tray_mod.write_build_status("complete", percent=100, running=0, total=1)
    tray._poll_build_status()
    assert tray._build_state == "complete"
    assert "complete" in tray.toolTip()
