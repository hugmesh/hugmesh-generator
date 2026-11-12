"""#478: a flash row whose image left the worklist gets no x86 flavour menu.

The Review page's device table keeps each row's assignment by device path, and its
Image combo is built when the row is drawn. If the worklist then loses that image
(removed or renamed on the Worklist page), the combo still lists it. Picking it sent
the row's Artifact cell through ``_entry_platform`` -> "" -> the x86 menu, so an rpi5
image could be planned as a live or installer USB that its builder never produces.

The stale row now shows a disabled 'auto'-only Artifact combo that says why, and no
flavour picked for one image carries over when the row is pointed at another.

The Qt importorskip sits inside the ``qapp`` fixture, not at module level, so a run
without a Qt binding reports these tests as skipped rather than dropping the module.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

GIB = 1 << 30


@pytest.fixture(scope="module")
def qapp():
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def table(qapp):
    """A DeviceTable over one attached stick and a mutable worklist. No scan thread:
    the rows are drawn from ``_targets`` exactly as a finished scan draws them."""
    from hugmesh_studio.core.flash_targets import FlashTarget
    from hugmesh_studio.gui.pages import _device_table as dt

    images = [("host.x86", "host", "x86", ()), ("be.rpi5", "be", "rpi5", ())]
    tbl = dt.DeviceTable(images_provider=lambda: list(images),
                         keys_gate=lambda: (True, ""),
                         on_assignment_changed=lambda: None)
    tbl._targets = [FlashTarget("/dev/sdb", 16 * GIB, "Stick", "usb", True, "usb")]
    tbl._repopulate()
    role = tbl.table.cellWidget(0, dt._COL_ROLE)
    role.setCurrentIndex(role.findData(dt.ROLE_FLASH))
    yield dt, tbl, images
    tbl.deleteLater()


def _flavours(combo):
    return [combo.itemData(i) for i in range(combo.count())]


def test_row_whose_image_left_the_worklist_gets_a_disabled_auto_only_combo(table):
    dt, tbl, images = table
    image = tbl.table.cellWidget(0, dt._COL_EXTRA)
    assert image.currentData() == "host.x86"
    # be.rpi5 leaves the worklist; the drawn Image combo still lists it
    images[:] = [("host.x86", "host", "x86", ())]
    image.setCurrentIndex(image.findData("be.rpi5"))

    combo = tbl.table.cellWidget(0, dt._COL_FLAVOR)
    assert combo is not None
    flavours = _flavours(combo)
    assert "live" not in flavours and "installer" not in flavours
    assert flavours == ["auto"]
    assert not combo.isEnabled()
    assert "no longer in the worklist" in combo.toolTip()
    assert "be.rpi5" in combo.toolTip()
    assert tbl._assign["/dev/sdb"]["flavor"] == "auto"
    assert [a[1:] for a in tbl.flash_assignments()] == [("be.rpi5", "auto")]


def test_a_flavour_picked_before_the_image_left_does_not_linger(table):
    dt, tbl, images = table
    image = tbl.table.cellWidget(0, dt._COL_EXTRA)
    # pick an x86 flavour, then switch to an image that has since left the worklist
    flav = tbl.table.cellWidget(0, dt._COL_FLAVOR)
    flav.setCurrentIndex(flav.findData("installer"))
    assert tbl._assign["/dev/sdb"]["flavor"] == "installer"
    images[:] = [("host.x86", "host", "x86", ())]
    image.setCurrentIndex(image.findData("be.rpi5"))
    assert tbl._assign["/dev/sdb"]["flavor"] == "auto"


def test_redraw_after_the_image_left_drops_the_old_flavour(table):
    """A redraw (Refresh, or a finished scan) re-points the row at the first image
    still listed. The flavour picked for the old image must not come with it."""
    dt, tbl, images = table
    images[:] = [("host.x86", "host", "x86", ()), ("other.x86", "host", "x86", ())]
    tbl._repopulate()
    image = tbl.table.cellWidget(0, dt._COL_EXTRA)
    image.setCurrentIndex(image.findData("other.x86"))
    flav = tbl.table.cellWidget(0, dt._COL_FLAVOR)
    flav.setCurrentIndex(flav.findData("installer"))
    assert tbl._assign["/dev/sdb"] == {"role": "flash", "entry_id": "other.x86",
                                       "keys_dir": "", "flavor": "installer"}
    images[:] = [("host.x86", "host", "x86", ())]
    tbl._repopulate()
    assert tbl._assign["/dev/sdb"]["entry_id"] == "host.x86"
    assert tbl._assign["/dev/sdb"]["flavor"] == "auto"
    assert tbl.table.cellWidget(0, dt._COL_FLAVOR).currentData() == "auto"


def test_known_platform_rows_keep_their_menus(table):
    dt, tbl, images = table
    combo = tbl.table.cellWidget(0, dt._COL_FLAVOR)
    assert _flavours(combo) == ["auto", "img", "live", "installer"]
    assert combo.isEnabled()
    image = tbl.table.cellWidget(0, dt._COL_EXTRA)
    image.setCurrentIndex(image.findData("be.rpi5"))
    combo = tbl.table.cellWidget(0, dt._COL_FLAVOR)
    assert _flavours(combo) == ["auto", "img"]
    assert combo.isEnabled()


def test_listed_entry_without_a_platform_is_still_x86(table):
    """WorklistEntry.platform defaults to x86; a listed entry with an empty platform
    keeps the x86 menu. Only an entry the provider no longer lists is 'unknown'."""
    dt, tbl, images = table
    images[:] = [("host.x86", "host", "", ())]
    tbl._repopulate()
    combo = tbl.table.cellWidget(0, dt._COL_FLAVOR)
    assert _flavours(combo) == ["auto", "img", "live", "installer"]
    assert combo.isEnabled()
