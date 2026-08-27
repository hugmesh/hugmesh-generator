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
from hugmesh_studio.gui.qt import QtCore, QtWidgets      # noqa: E402

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
def _png(pm) -> bytes:
    """Binding-portable raw bytes of a pixmap (PNG round-trip — PyQt6's
    constBits() and PySide6's differ, a saved buffer does not).

    `bytes(img.constBits())` is a PySide6-only spelling: there constBits() hands back
    a SIZED memoryview, while PyQt6 hands back a `sip.voidptr` of unknown length and
    bytes() raises `IndexError: ... object has an unknown size`. The three badge
    assertions below were failing for the BINDING, never for the icons — every state
    really does render a distinct pixmap. Same helper, same reason, as
    tests/test_choice_cards.py::_png; PNG is lossless, so two icons that differ by a
    single pixel still differ here.
    """
    ba = QtCore.QByteArray()
    buf = QtCore.QBuffer(ba)
    buf.open(QtCore.QIODevice.OpenModeFlag.WriteOnly)
    pm.toImage().save(buf, "PNG")
    buf.close()
    return bytes(ba.data())


def _img_bytes(state, percent=None):
    return _png(tray_mod._render_icon(state, percent).pixmap(64, 64))


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


#: The progress arc's own colour (tray._render_icon). Counting ITS pixels is the only
#: way to assert the RING moves — a whole-image comparison is satisfied by the numeral
#: alone, so a ring frozen at half-full while the number counts up reads as correct.
_ARC_RGB = (0x1a, 0x73, 0xe8)


def _arc_pixels(percent, tol=60):
    img = tray_mod._render_icon("building", percent).pixmap(64, 64).toImage()
    n = 0
    for y in range(img.height()):
        for x in range(img.width()):
            c = img.pixelColor(x, y)
            if c.alpha() > 128 and (abs(c.red() - _ARC_RGB[0]) + abs(c.green() - _ARC_RGB[1])
                                    + abs(c.blue() - _ARC_RGB[2])) <= tol:
                n += 1
    return n


def test_building_ring_fills_monotonically_with_percent(qapp):
    """The ARC itself must grow with percent, not just the numeral beside it.

    Added after a mutation battery: replacing the sweep with a constant
    (``drawArc(ring, 90*16, -180*16)``) left every icon-vs-icon assertion above GREEN,
    because the printed number still varied. A progress ring that never moves is
    exactly the "no build indicator" bug this file exists for, so it gets its own
    assertion on the arc's pixels.
    """
    counts = [_arc_pixels(p) for p in (0, 25, 50, 75, 100)]
    assert counts[0] == 0, "an unstarted build must draw no arc at all"
    assert counts == sorted(counts) and len(set(counts)) == len(counts), \
        f"the progress arc does not grow with percent: {counts}"


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
    assert _png(tray.icon().pixmap(64, 64)) != idle_icon

    tray_mod.write_build_status("complete", percent=100, running=0, total=1)
    tray._poll_build_status()
    assert tray._build_state == "complete"
    assert "complete" in tray.toolTip()
