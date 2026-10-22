"""Mesh WorklistPage: the Orange Pi node rows, Raspberry Pi omnibus and the RAM column.

The Orange Pi 5 / 5 Plus builds pki/backend/frontend/omnibus and the Orange Pi 4 LTS
builds frontend (both EXPERIMENTAL); omnibus now builds on the Raspberry Pi 4/5 too.
One image serves every RAM size a board is sold with, so a Pi / Orange Pi NODE row
carries a RAM combo (--ram-gb) that offers only the board's sizes at or above the
role's floor (scripts/_roles-lib.sh), and an omnibus row without a RAM stops Next with
an INLINE message (never a dialog — feedback_no_modals_in_page_logic).

These tests LOOK at the control, not only at the data behind it: the RAM combo of a
checked row must be visible, enabled, and wide/tall enough to read.

Skipped whole when no Qt binding is installed.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.worklist import _COL_RAM  # noqa: E402
from hugmesh_studio.gui.qt import Qt  # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


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
    w.resize(1280, 860)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _worklist(wiz):
    pick_mode(wiz, "mesh")
    return advance_to(wiz, wizard_mod.WorklistPage)


def _only(page, *ids):
    """Uncheck every row, then check exactly ``ids``."""
    for item in page.rows.values():
        item.setCheckState(0, Qt.CheckState.Unchecked)
    check_worklist_rows(page, *ids)


def _items(combo):
    return [combo.itemText(i) for i in range(combo.count())]


def test_rows_offered_and_refused(wiz):
    page = _worklist(wiz)
    for rid in ("pki.orangepi5", "backend.orangepi5", "frontend.orangepi5",
                "omnibus.orangepi5", "frontend.orangepi4-lts", "omnibus.rpi5"):
        assert rid in page.rows, f"{rid} is not offered on the mesh worklist"
    # The Orange Pi 4 LTS (4 GB RAM, 16 GB eMMC) can only be a frontend node.
    for rid in ("omnibus.orangepi4-lts", "pki.orangepi4-lts", "backend.orangepi4-lts"):
        assert rid not in page.rows, f"{rid} must not be offered"


def test_ram_combo_is_visible_enabled_and_sized(wiz):
    page = _worklist(wiz)
    _only(page, "omnibus.rpi5")
    page.tree.expandAll()
    item = page.rows["omnibus.rpi5"]
    page.tree.scrollToItem(item)
    combo = page._ram_combos["omnibus.rpi5"]
    assert combo is not None
    assert page.tree.itemWidget(item, _COL_RAM) is combo
    assert combo.isVisible() and combo.isEnabled()
    assert combo.width() >= 60 and combo.height() >= 18, (combo.width(), combo.height())
    # The column itself is on screen and not collapsed.
    assert page.tree.columnWidth(_COL_RAM) >= 60
    assert page.tree.headerItem().text(_COL_RAM) == "RAM"


def test_ram_choices_follow_the_board_and_the_floor(wiz):
    page = _worklist(wiz)
    _only(page, "omnibus.rpi5", "backend.orangepi5")
    board_combo, _flavor = page._combos["omnibus.rpi5"]
    ram = page._ram_combos["omnibus.rpi5"]
    # omnibus needs 16 GB, and a Pi 4 is sold with 8 GB at most: the board picker
    # does not offer it (the builder refuses it), and the RAM picker offers only 16
    assert _items(board_combo) == ["rpi5"]
    assert _items(ram) == ["choose…", "16 GB"]
    # backend on an Orange Pi 5: "not stated" allowed, sizes >= its 8 GB floor
    assert _items(page._ram_combos["backend.orangepi5"]) == ["—", "8 GB", "16 GB", "32 GB"]


def test_orange_pi_node_rows_are_installer_only(wiz):
    page = _worklist(wiz)
    _board, flavor = page._combos["pki.orangepi5"]
    assert _items(flavor) == ["installer"]
    _board, flavor4 = page._combos["frontend.orangepi4-lts"]
    assert _items(flavor4) == ["installer"]
    # the RAM column exists on the 4 LTS row too (frontend floor 4 GB, one SKU)
    assert _items(page._ram_combos["frontend.orangepi4-lts"]) == ["—", "4 GB"]
    # x86 rows carry no RAM combo (the x86 builder takes no --ram-gb)
    assert page._ram_combos.get("omnibus.x86") is None


def test_omnibus_without_ram_is_refused_inline_then_accepted(wiz):
    page = _worklist(wiz)
    _only(page, "omnibus.rpi5")
    assert page.validatePage() is False
    assert page.ram_error.isVisible()
    assert "omnibus" in page.ram_error.text() and "16 GB" in page.ram_error.text()
    ram = page._ram_combos["omnibus.rpi5"]
    assert ram.findData("8") == -1                    # below the floor: not offered
    ram.setCurrentIndex(ram.findData("16"))
    assert page.validatePage() is True
    assert not page.ram_error.isVisible()
    entry = wiz.worklist.entries[0]
    assert (entry.role, entry.platform, entry.ram_gb) == ("omnibus", "rpi5", "16")
    (_e, cfg), = wiz.worklist.materialize()
    argv = cfg.to_cli_args()
    assert argv[argv.index("--role") + 1] == "omnibus"
    assert argv[argv.index("--ram-gb") + 1] == "16"


def test_orange_pi_omnibus_argv(wiz):
    page = _worklist(wiz)
    _only(page, "omnibus.orangepi5")
    board_combo, _flavor = page._combos["omnibus.orangepi5"]
    board_combo.setCurrentText("orange-pi-5")
    ram = page._ram_combos["omnibus.orangepi5"]
    ram.setCurrentIndex(ram.findData("16"))
    assert page.validatePage() is True
    (_e, cfg), = wiz.worklist.materialize()
    argv = cfg.to_cli_args()
    for flag, want in (("--role", "omnibus"), ("--board", "orange-pi-5"),
                       ("--flavor", "installer"), ("--ram-gb", "16")):
        assert argv[argv.index(flag) + 1] == want, (flag, argv)


def test_render_png(wiz, tmp_path):
    """Render the page offscreen (the operator LOOKS at it). The PNG lands in
    $HUGMESH_RENDER_DIR when set, else a temp dir; the grab must not be blank."""
    page = _worklist(wiz)
    _only(page, "omnibus.rpi5", "pki.orangepi5", "frontend.orangepi4-lts")
    page.tree.expandAll()
    page.tree.scrollToItem(page.rows["omnibus.rpi5"])
    out_dir = os.environ.get("HUGMESH_RENDER_DIR") or str(tmp_path)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "worklist-orangepi-nodes.png")
    pix = wiz.grab()
    assert pix.save(path)
    assert pix.width() > 600 and pix.height() > 400
    page.validatePage()              # the omnibus row has no RAM -> inline message
    path2 = os.path.join(out_dir, "worklist-orangepi-nodes-ram-refusal.png")
    assert wiz.grab().save(path2)
    assert page.ram_error.isVisible()


def test_required_trio_never_checks_experimental_orange_pi_rows(wiz):
    page = _worklist(wiz)
    for item in page.rows.values():
        item.setCheckState(0, Qt.CheckState.Unchecked)
    page.trio_btn.click()
    checked = {rid for rid, it in page.rows.items()
               if it.checkState(0) == Qt.CheckState.Checked}
    assert {"pki.x86", "backend.x86", "frontend.x86",
            "pki.rpi5", "backend.rpi5", "frontend.rpi5"} <= checked
    assert not {r for r in checked if r.endswith((".orangepi5", ".orangepi4-lts"))}, checked


# ── TUI parity: the text-mode worklist's `ram N GB` and its inline RAM refusal ─────────
def test_tui_worklist_ram_rule_matches_the_gui():
    from hugmesh_studio.core.config import ImageConfig as _Cfg
    from hugmesh_studio.tui import journey

    class _J:
        worklist_role_allow = None
        worklist = None
        status = ""
        advanced = False

        def __init__(self):
            self.cfg = _Cfg(mode="mesh")

        def advance(self):
            self.advanced = True

    scr = journey.WorklistScreen()
    j = _J()
    scr.enter(j)
    ids = [f"{r}.{p}" for r, p, _l in scr._rows]
    for want in ("omnibus.rpi5", "omnibus.orangepi5", "frontend.orangepi4-lts"):
        assert want in ids, f"the TUI worklist does not offer {want}"
    n = ids.index("omnibus.rpi5") + 1
    scr.feed(j, str(n))
    scr.feed(j, "")                                   # Enter with no RAM: refused inline
    assert not j.advanced and f"ram {n} 16" in j.status, j.status
    scr.feed(j, f"ram {n} 8")
    assert j.status.startswith("refused:") and "at least 16 GB" in j.status
    scr.feed(j, f"ram {ids.index('pki.x86') + 1} 8")
    assert "takes no board RAM" in j.status
    scr.feed(j, f"ram {n} 16")
    assert f"[RAM 16 GB]" in "\n".join(scr.lines(j))
    scr.feed(j, "")
    assert j.advanced, j.status
    (entry,) = j.worklist.entries
    assert (entry.id, entry.ram_gb) == ("omnibus.rpi5", "16")
    # the materialized command carries it, like the GUI's
    (_e, cfg), = j.worklist.materialize()
    argv = cfg.to_cli_args()
    assert argv[argv.index("--ram-gb") + 1] == "16"
