"""Device imaging: the per-device (domain, node, install/live/img) assignment axis.

The operator ask, verbatim shape: a listing of each attached storage device via USB
(including Pi / Libre-Computer eMMC), with per-device selection of WHICH domain
image, for WHICH node, and WHETHER the device becomes an install / live / img USB.

Grounded pins (nothing invented):
  * flavour classification matches the EXACT artifact suffixes the six builders
    emit (`.img` / `.live.iso` / `.installer.iso`, plus x86's `-sb` re-signs) —
    a plain `.iso` (rpi5) classifies UNFLAVOURED and is only reachable via "auto";
  * per-platform flavour menus mirror each builder's real `_ARTS` list — a flavour
    a platform cannot build is never offered (hide-inapplicable), and a flavour
    the finished run didn't produce SKIPS at flash time with the reason, never a
    wrong-image guess;
  * one x86 entry can produce all three artifacts in one run → the progress page
    records the WHOLE changed set per entry (plural), else non-default flavours
    would be unreachable;
  * Pi-rpiboot / Amlogic-burn-mode identities decorate the listing (label ONLY —
    detection and eligibility are unchanged);
  * domains decorate the image pick (Domain.images refs; empty = attaches to all).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import flash_targets as ft        # noqa: E402
from hugmesh_studio.core.flash_targets import FlashTarget  # noqa: E402
from hugmesh_studio.gui.pages import _device_table as dt_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                # noqa: E402

GIB = 1 << 30
SDB = FlashTarget("/dev/sdb", 16 * GIB, "SanDisk Ultra", "usb", True, "usb")


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


# ── flavour classification: the real builder suffixes ───────────────────────────────
@pytest.mark.parametrize("name,flavor", [
    ("acme-x86-amd64-host-test-20260718T000000Z.img", "img"),
    ("acme-x86-amd64-host-test-20260718T000000Z.live.iso", "live"),
    ("acme-x86-amd64-host-test-20260718T000000Z.installer.iso", "installer"),
    # x86 secure-boot re-sign: ISO_PATH%.iso + "-sb.iso" -> .live-sb.iso
    ("acme-x86-amd64-host-test-20260718T000000Z.live-sb.iso", "live"),
    ("acme-x86-amd64-host-test-20260718T000000Z.installer-sb.iso", "installer"),
    ("acme-rpi5-arm64-be-test-20260718T000000Z.img", "img"),
    ("acme-rpi5-arm64-be-test-20260718T000000Z.iso", ""),      # rpi5's PLAIN iso
    ("stage4.tar.xz", ""),
])
def test_classify_matches_the_shipped_suffixes(name, flavor):
    assert ft.classify_artifact_flavor(name) == flavor


def test_platform_flavour_menus_mirror_the_builders_artifact_lists():
    # evidence: each builder's _ARTS summary (x86:1545-47, rpi5:2066-67 img+plain
    # iso, frite:788-89, opi5:810-11, opz2:872-73, jetson:623).
    assert ft.flavors_for_platform("x86") == ("auto", "img", "live", "installer")
    assert ft.flavors_for_platform("rpi5") == ("auto", "img")
    assert ft.flavors_for_platform("jetson") == ("auto", "img")
    for p in ("frite", "orangepi5", "orangepizero2", "orangepizero2w", "orangepizero3",
              "orangepi3-lts"):
        assert ft.flavors_for_platform(p) == ("auto", "live", "installer")
    assert ft.flavors_for_platform("") == ft.flavors_for_platform("x86")
    for p, flavors in ft._PLATFORM_FLAVORS.items():
        assert set(flavors) <= set(ft.FLAVOR_LABELS), p


def test_pick_artifact_auto_keeps_img_preference_and_flavours_never_guess():
    arts = ("/w/a.installer.iso", "/w/a.live.iso", "/w/a.img")
    assert ft.pick_artifact(arts, "auto") == "/w/a.img"
    assert ft.pick_artifact(arts, "live") == "/w/a.live.iso"
    assert ft.pick_artifact(arts, "installer") == "/w/a.installer.iso"
    # the fail-safe: a flavour the run didn't produce returns "" (skip), NEVER a
    # different flavour.
    assert ft.pick_artifact(("/w/a.live.iso",), "installer") == ""
    assert ft.pick_artifact((), "img") == ""


def test_new_artifacts_records_the_whole_changed_set(tmp_path):
    for name in ("x.img", "x.live.iso", "x.installer.iso", "stale.img",
                 "x-initramfs.img"):
        (tmp_path / name).write_bytes(b"a")
    os.utime(tmp_path / "stale.img", (100, 100))
    baseline = {"stale.img": 100.0}
    arts = ft.new_artifacts(str(tmp_path), baseline)
    names = {os.path.basename(a) for a in arts}
    # all three changed flashables; the stale one and the initramfs blob excluded
    assert names == {"x.img", "x.live.iso", "x.installer.iso"}
    # and the legacy single pick still resolves to the .img out of that set
    assert ft.new_artifact(str(tmp_path), baseline).endswith("x.img")


def test_flash_assignment_flavor_is_a_trailing_default():
    a = ft.FlashAssignment(SDB, "backend.rpi5", "backend", "arm64", "/w")   # positional, pre-flavour
    assert a.flavor == ft.FLAVOR_AUTO
    assert ft.FlashAssignment(SDB, "backend.rpi5", "backend", "arm64", "/w",
                              flavor="installer").flavor == "installer"


# ── SBC identity hints (label-only) ─────────────────────────────────────────────────
def test_pi_and_amlogic_gadget_identities_are_recognised():
    pi = FlashTarget("/dev/sda", 8 * GIB, "BCM2711 Boot", "usb", True, "usb")
    aml = FlashTarget("/dev/sdb", 8 * GIB, "GX-CHIP", "usb", True, "usb",
                      vendor="Amlogic")
    plain = FlashTarget("/dev/sdc", 8 * GIB, "SanDisk Ultra", "usb", True, "usb")
    assert "rpiboot" in pi.hint()
    assert "Amlogic" in aml.hint()
    assert plain.hint() == ""


def test_hint_decorates_the_table_model_column(qapp):
    table = dt_mod.DeviceTable(images_provider=lambda: [], keys_gate=lambda: (False, "x"),
                               on_assignment_changed=lambda: None)
    pi = FlashTarget("/dev/sda", 8 * GIB, "BCM2711 Boot", "usb", True, "usb")
    table._debounce.stop()
    table._scan_gen += 1
    table._on_scan_done([pi], table._scan_gen)
    assert "rpiboot" in table.table.item(0, 1).text()


# ── the table: domain-decorated image pick + platform-bounded flavour pick ──────────
def _table(qapp, choices):
    t = dt_mod.DeviceTable(images_provider=lambda: choices,
                           keys_gate=lambda: (False, "off-x86"),
                           on_assignment_changed=lambda: None)
    t._debounce.stop()
    t._scan_gen += 1
    t._on_scan_done([SDB], t._scan_gen)
    return t


def _set_role_flash(table, row=0):
    combo = table.table.cellWidget(row, dt_mod._COL_ROLE)
    combo.setCurrentIndex(combo.findData(dt_mod.ROLE_FLASH))


def test_image_labels_carry_the_entry_domains(qapp):
    table = _table(qapp, [("backend.rpi5", "backend", "rpi5", ("beta.example",)),
                          ("omnibus.x86", "omnibus", "x86",
                           ("alpha.games", "beta.example"))])
    _set_role_flash(table)
    img = table.table.cellWidget(0, dt_mod._COL_EXTRA)
    labels = [img.itemText(i) for i in range(img.count())]
    assert any("backend.rpi5" in l and "beta.example" in l for l in labels)
    assert any("alpha.games, beta.example" in l for l in labels)
    # legacy 3-tuple providers stay accepted (empty domains tail)
    t3 = _table(qapp, [("backend.rpi5", "backend", "rpi5")])
    _set_role_flash(t3)
    assert t3.table.cellWidget(0, dt_mod._COL_EXTRA).itemText(0) == "backend.rpi5"


def test_flavour_menu_is_bounded_by_the_assigned_images_platform(qapp):
    table = _table(qapp, [("fe.frite", "frontend", "frite", ()),
                          ("omnibus.x86", "omnibus", "x86", ())])
    _set_role_flash(table)
    img = table.table.cellWidget(0, dt_mod._COL_EXTRA)
    img.setCurrentIndex(img.findData("fe.frite"))
    flav = table.table.cellWidget(0, dt_mod._COL_FLAVOR)
    tokens = [flav.itemData(i) for i in range(flav.count())]
    assert tokens == ["auto", "live", "installer"]      # frite builds no .img
    # switching the image to x86 REBUILDS the menu with x86's full triple
    img.setCurrentIndex(img.findData("omnibus.x86"))
    flav = table.table.cellWidget(0, dt_mod._COL_FLAVOR)
    assert [flav.itemData(i) for i in range(flav.count())] == [
        "auto", "img", "live", "installer"]


def test_assignments_carry_the_flavour_and_the_plan_shows_it(qapp):
    table = _table(qapp, [("omnibus.x86", "omnibus", "x86", ())])
    _set_role_flash(table)
    img = table.table.cellWidget(0, dt_mod._COL_EXTRA)
    img.setCurrentIndex(img.findData("omnibus.x86"))
    flav = table.table.cellWidget(0, dt_mod._COL_FLAVOR)
    flav.setCurrentIndex(flav.findData("installer"))
    assert table.flash_assignments() == [(SDB, "omnibus.x86", "installer")]
    assert "[installer]" in table.plan_label.text()
    # default (auto) stays undecorated in the plan line
    flav.setCurrentIndex(flav.findData("auto"))
    assert "[" not in table.plan_label.text()


# ── progress-page resolution: flavour pick + honest skip (stubbed page state) ───────
class _Lines:
    def __init__(self):
        self.lines = []

    def appendPlainText(self, s):
        self.lines.append(s)


def _progress_stub(monkeypatch, *, sets=None, singles=None, queue):
    """A ProgressPage minus Qt construction: exactly the state _flash_next reads,
    driven through the REAL unbound method so the resolution/skip logic under test
    is the shipped code, not a re-implementation."""
    from types import SimpleNamespace

    from hugmesh_studio.gui.pages.progress import ProgressPage
    page = ProgressPage.__new__(ProgressPage)
    page.log = _Lines()
    page.flash_worker = None
    page._flash_queue = list(queue)
    page._entry_artifact_sets = dict(sets or {})
    page._entry_artifacts = dict(singles or {})
    page.wiz = SimpleNamespace(generator_dir="/g")
    started = []
    page._start_flash = lambda target, argv=None: started.append((target.path, argv))
    monkeypatch.setattr(ft, "list_targets", lambda: [SDB])
    return page, started


def test_flash_next_picks_the_assigned_flavour_from_the_recorded_set(qapp, monkeypatch):
    a = ft.FlashAssignment(SDB, "omnibus.x86", "omnibus", "x86", "/w",
                           flavor="installer")
    page, started = _progress_stub(
        monkeypatch, queue=[a],
        sets={"omnibus.x86": ("/w/x.img", "/w/x.live.iso", "/w/x.installer.iso")})
    page._flash_next()
    assert len(started) == 1
    assert "--artifact" in started[0][1]
    assert started[0][1][started[0][1].index("--artifact") + 1] == "/w/x.installer.iso"
    assert any("[installer]" in l for l in page.log.lines)


def test_flash_next_skips_with_the_reason_when_the_flavour_was_not_built(qapp,
                                                                         monkeypatch):
    a = ft.FlashAssignment(SDB, "fe.frite", "frontend", "arm64", "/w", flavor="installer")
    page, started = _progress_stub(
        monkeypatch, queue=[a], sets={"fe.frite": ("/w/y.live.iso",)})
    page._flash_next()
    assert started == []                       # NEVER writes the wrong flavour
    assert any("no 'installer' artifact" in l and "y.live.iso" in l
               for l in page.log.lines)


def test_flash_next_legacy_single_record_still_flashes_on_auto(qapp, monkeypatch):
    a = ft.FlashAssignment(SDB, "backend.rpi5", "backend", "arm64", "/w")   # pre-flavour shape
    page, started = _progress_stub(monkeypatch, queue=[a],
                                   singles={"backend.rpi5": "/w/z.img"})
    page._flash_next()
    assert len(started) == 1
    assert started[0][1][started[0][1].index("--artifact") + 1] == "/w/z.img"
