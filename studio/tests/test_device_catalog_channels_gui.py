"""Device catalog: GUI == text UI == CLI, row by row (hugmesh-generator#1058).

The Qt-present half of the channel parity. RolePage's device tree is the GUI channel;
the text UI's arch -> family -> device browse and ``--list-devices`` are the other
two (test_device_catalog_channels.py proves those on the Qt-free job). Here every row
of the RAW ``device-catalog.json`` is read off all three channels at once and the
three readings must be the same words and the same selection gate:

* the GUI tree's Device / SoC / Status columns and its tooltip;
* the CLI's ``--list-devices --json`` row for the same mode;
* the text UI's device screen, reached by browsing to the row.

Skipped whole when no Qt binding is installed (the rest of the suite stays pure-core).
"""
import json
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio import app  # noqa: E402
from hugmesh_studio.core import device_catalog  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.qt import Qt  # noqa: E402
from hugmesh_studio.tui import journey  # noqa: E402

from _helpers import advance_to, pick_mode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

with open(device_catalog.CATALOG_PATH, encoding="utf-8") as _fh:
    RAW = json.load(_fh)
RAW_BY_ID = {d["id"]: d for d in RAW["devices"]}


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


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


def _raw_path(device_id: str) -> tuple[int, int, int]:
    """The (arch, family, device) numbers a person types, from the raw file's order."""
    dev = RAW_BY_ID[device_id]
    devs = RAW["devices"]
    archs = [a["id"] for a in RAW["archs"] if any(d["arch"] == a["id"] for d in devs)]
    fams = [f["id"] for f in RAW["families"]
            if any(d["family"] == f["id"] and d["arch"] == dev["arch"] for d in devs)]
    rows = [d["id"] for d in devs
            if d["family"] == dev["family"] and d["arch"] == dev["arch"]]
    return (archs.index(dev["arch"]) + 1, fams.index(dev["family"]) + 1,
            rows.index(device_id) + 1)


def _tui_device_screen(mode: str, device_id: str) -> tuple[str, str]:
    """(the device screen's text, the status after picking the row) in the text UI."""
    j = journey.Journey(".")
    j.feed("")
    j.feed(str([m for m, _t, _d in journey.MODE_CHOICES].index(mode) + 1))
    while j.slug != "role":
        j.feed("")
    a, f, n = _raw_path(device_id)
    for line in ("d", str(a), str(f)):
        j.feed(line)
    screen = "\n".join(j.lines())
    j.feed(str(n))
    return screen, j.status


@pytest.mark.parametrize("mode", ("standalone", "cloud"))
def test_every_row_reads_the_same_in_gui_tui_and_cli(wiz, capsys, mode):
    pick_mode(wiz, mode)
    page = advance_to(wiz, wizard_mod.RolePage)
    assert app.main(["--list-devices", "--json", "--mode", mode]) == 0
    cli = {d["id"]: d for d in json.loads(capsys.readouterr().out)["devices"]}

    # the same set of rows in every channel, and it is the raw file's set
    assert set(page._device_items) == set(RAW_BY_ID) == set(cli)

    for did, raw in RAW_BY_ID.items():
        item = page._device_items[did]
        row = cli[did]
        # GUI columns == CLI words == raw label/SoC
        assert item.text(0) == row["label"] == raw["label"], did
        assert item.text(1) == row["soc"] == raw["soc"], did
        assert item.text(2) == row["status_text"], (did, item.text(2), row["status_text"])
        assert item.toolTip(0) == row["detail"], did
        assert item.parent().text(0) == row["family_heading"], did
        # the selection gate: GUI flag == CLI field == text UI acceptance
        gui_pickable = bool(item.flags() & Qt.ItemFlag.ItemIsSelectable)
        assert gui_pickable is row["pickable"], did
        screen, status = _tui_device_screen(mode, did)
        assert f"{raw['label']} — {raw['soc']}" in screen, did
        if row["status_text"]:
            assert f"status: {row['status_text']}" in screen, did
        if row["pickable"]:
            assert status.startswith("device: "), (did, status)
        else:
            assert status == f"refused: {row['refusal']}", (did, status)
            if raw["status"] == "unsupported":
                assert raw["reason"] in item.text(2) and raw["reason"] in status, did


@pytest.mark.parametrize("mode", ("standalone", "cloud"))
def test_a_refused_row_cannot_be_selected_in_the_gui(wiz, mode):
    """The GUI leg of "refused rows cannot be selected in any channel": the tree item
    carries no flags, so the tree will not make it current; and if it somehow were
    current, Next is disabled and validatePage refuses to commit."""
    pick_mode(wiz, mode)
    page = advance_to(wiz, wizard_mod.RolePage)
    for did in RAW_BY_ID:
        if device_catalog.device_row(did, mode).pickable:
            continue
        item = page._device_items[did]
        assert not item.flags() & Qt.ItemFlag.ItemIsSelectable, did
        page.device_tree.setCurrentItem(item)
        if page._selected_device() == did:
            assert not page.isComplete(), did
            assert page.validatePage() is False, did
        # whatever stays current is a pickable device, never the refused one
        cur = page._selected_device()
        assert cur is None or device_catalog.device_row(cur, mode).pickable, did
