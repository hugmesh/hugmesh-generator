"""The PKI LAN Address row (core/pki_lan.py) on every face, as the operator meets it.

Operator rule (2026-11-11): the Studio REQUIRES a static IP or a DHCP reservation for
the pki node when configuring a mesh, validates it, says why, and uses no mDNS. A
worker's first boot dials that address before go-live (keys-provision
resolve_control_endpoint), so a mesh whose sticks lack it cannot join its workers.

What is pinned here:
  * the core rule (mesh only, a private IPv4, the "fixed" confirmation) and its words;
  * the Network page: the row shows on a mesh and nowhere else, refuses a malformed
    address INLINE (no dialog), collects the canonical address, and says what the build
    will refuse while it is missing or unconfirmed;
  * the build refuses (WorklistDriver.preflight) and the keys step passes ``--pki-ip``;
  * the Fleet route: the same rule on FleetDriver.preflight and PKI_LAN_IP in its env;
  * the TUI: the Network step's ``ip`` / ``fixed`` commands and the Build screen's line;
  * what a person SEES: the ``test_look_*`` case runs in a fresh interpreter started by
    tests/test_look.py, measures the row at the wizard's default window under two
    styles and two font sizes, and saves screenshots when HUGMESH_LOOK_SHOTS is set.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import pki_lan                           # noqa: E402
from hugmesh_studio.core.config import ImageConfig                # noqa: E402
from hugmesh_studio.core.fleet import FleetConfig, FleetDriver    # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.core.worklist_driver import WorklistDriver    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage          # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                       # noqa: E402
from hugmesh_studio.tui import network_step                       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-pki-lan-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def net_page(wiz, **cfg_kw):
    """The NetworkPage as the CURRENT page, initialised for ``cfg_kw`` (an x86 mesh pki
    unless told otherwise)."""
    kw = dict(mode="mesh", role="pki", platform="x86")
    kw.update(cfg_kw)
    pid = [i for i in wiz.pageIds() if isinstance(wiz.page(i), NetworkPage)][0]
    wiz.cfg = ImageConfig(**kw)
    wiz.setStartId(pid)
    wiz.restart()
    wiz.setStartId(-1)
    QtWidgets.QApplication.processEvents()
    page = wiz.page(pid)
    assert wiz.currentPage() is page
    return page


# ── the core rule ───────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("value", ["10.0.0.5", "172.16.0.1", "172.31.255.254",
                                   "192.168.1.10", " 192.168.1.10 ", "010.000.000.005"])
def test_private_ipv4_is_accepted(value):
    assert pki_lan.ip_error(value) == ""


@pytest.mark.parametrize("value", ["100.64.0.1", "8.8.8.8", "127.0.0.1", "169.254.0.9",
                                   "172.32.0.1", "10.0.0.256", "10.0.0", "pki.local",
                                   "pki", "10.0.0.1:8080", "fd00::1"])
def test_anything_else_is_refused_with_a_reason(value):
    assert pki_lan.ip_error(value)


def test_a_dot_local_name_is_refused_as_mdns():
    assert "mDNS" in pki_lan.ip_error("pki.local")


def test_the_rule_is_mesh_only_and_needs_the_fixed_confirmation():
    assert pki_lan.problem(ImageConfig(mode="standalone")) == ""
    assert pki_lan.problem(ImageConfig(mode="cloud")) == ""
    cfg = ImageConfig(mode="mesh")
    assert pki_lan.problem(cfg).startswith(pki_lan.LABEL_IP + " is required")
    assert pki_lan.WHY in pki_lan.problem(cfg)
    cfg.pki_lan_ip = "192.168.1.10"
    assert "confirm it is fixed" in pki_lan.problem(cfg)
    cfg.pki_lan_ip_fixed = True
    assert pki_lan.problem(cfg) == ""
    assert pki_lan.genkeys_args(cfg) == ["--pki-ip", "192.168.1.10"]


def test_why_says_static_or_reservation_and_no_mdns():
    for words in ("static IP", "DHCP", "mDNS", "KEYS stick"):
        assert words in pki_lan.WHY


def test_never_a_builder_flag_and_survives_a_save(tmp_path):
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86",
                      pki_lan_ip="192.168.1.10", pki_lan_ip_fixed=True)
    assert "--pki-ip" not in cfg.to_cli_args()
    path = tmp_path / "c.json"
    cfg.save(str(path))
    back = ImageConfig.load(str(path))
    assert (back.pki_lan_ip, back.pki_lan_ip_fixed) == ("192.168.1.10", True)


def test_a_malformed_saved_address_is_refused_at_validation():
    with pytest.raises(ValueError):
        ImageConfig(mode="mesh", pki_lan_ip="pki.local").validate_identity()


# ── the image route: preflight refuses, the keys step passes --pki-ip ────────────────
def _worklist(**base_kw):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", **base_kw)
    return WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86"),
                                              WorklistEntry(role="backend", platform="x86")])


def test_mesh_preflight_refuses_without_it(tmp_path):
    drv = WorklistDriver(GENERATOR_DIR, _worklist(output_dir=str(tmp_path)), host=HOST,
                         backend="native")
    assert any(p.startswith(pki_lan.LABEL_IP) for p in drv.preflight())
    drv = WorklistDriver(GENERATOR_DIR, _worklist(output_dir=str(tmp_path),
                                                  pki_lan_ip="192.168.1.10"),
                         host=HOST, backend="native")
    assert any("confirm it is fixed" in p for p in drv.preflight())
    drv = WorklistDriver(GENERATOR_DIR, _worklist(output_dir=str(tmp_path),
                                                  pki_lan_ip="192.168.1.10",
                                                  pki_lan_ip_fixed=True),
                         host=HOST, backend="native")
    assert not any(pki_lan.LABEL_IP in p for p in drv.preflight())


def test_a_run_that_makes_no_sticks_is_not_refused(tmp_path):
    drv = WorklistDriver(GENERATOR_DIR, _worklist(output_dir=str(tmp_path)), host=HOST,
                         backend="native", generate_keys=False)
    assert not any(pki_lan.LABEL_IP in p for p in drv.preflight())


def test_the_keys_step_passes_pki_ip(tmp_path, monkeypatch):
    seen = []

    class FakeProc:
        stdout = iter(())
        returncode = 0

        def wait(self):
            return 0

    def fake_popen(cmd, **kw):
        seen.append(list(cmd))
        return FakeProc()

    import hugmesh_studio.core.worklist_driver as wd
    monkeypatch.setattr(wd.subprocess, "Popen", fake_popen)
    wl = _worklist(output_dir=str(tmp_path), pki_lan_ip="192.168.001.010",
                   pki_lan_ip_fixed=True)
    drv = WorklistDriver(GENERATOR_DIR, wl, host=HOST, backend="native")
    try:
        drv._generate_keys(0, wl.entries[0], None, None)
    except Exception:          # the fake proc is minimal; the argv is what we pin
        pass
    assert seen, "gen-provision-keys.sh was never started"
    argv = seen[0]
    i = argv.index("--pki-ip")
    assert argv[i + 1] == "192.168.1.10"


# ── the Fleet route ─────────────────────────────────────────────────────────────────
def test_fleet_preflight_and_env():
    drv = FleetDriver(GENERATOR_DIR, HOST)
    assert any(p.startswith(pki_lan.LABEL_IP) for p in drv.preflight(FleetConfig(), "native"))
    assert not any(pki_lan.LABEL_IP in p
                   for p in drv.preflight(FleetConfig(skip_keys=True), "native"))
    ok = FleetConfig(pki_lan_ip="192.168.1.10", pki_lan_ip_fixed=True)
    assert not any(pki_lan.LABEL_IP in p for p in drv.preflight(ok, "native"))
    assert ok.to_env()["PKI_LAN_IP"] == "192.168.1.10"
    assert "PKI_LAN_IP" not in FleetConfig().to_env()


# ── the Network page ────────────────────────────────────────────────────────────────
def test_the_row_shows_on_a_mesh_only(wiz):
    page = net_page(wiz)
    assert page.pki_lan_box.isVisible()
    page = net_page(wiz, mode="cloud", role="desktop")
    assert not page.pki_lan_box.isVisible()
    page = net_page(wiz, mode="standalone", role="standalone-thick")
    assert not page.pki_lan_box.isVisible()


def test_missing_and_unconfirmed_say_so_but_do_not_stop_the_walk(wiz):
    page = net_page(wiz)
    assert page.pki_lan_note.isVisible()
    assert "required" in page.pki_lan_note.text()
    assert page.validatePage()
    page.pki_lan_ip.setText("192.168.1.10")
    assert "Tick the box" in page.pki_lan_note.text()
    page.pki_lan_fixed.setChecked(True)
    assert not page.pki_lan_note.isVisible()


def test_a_malformed_address_is_refused_inline(wiz, monkeypatch):
    # a dialog here would hang a headless run: fail loudly if one is attempted
    for name in ("warning", "critical", "information", "question"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name,
                            lambda *a, **k: pytest.fail("a modal dialog was opened"))
    page = net_page(wiz)
    page.pki_lan_ip.setText("pki.local")
    assert page.validatePage() is False
    assert page.pki_lan_note.isVisible() and "mDNS" in page.pki_lan_note.text()
    assert wiz.cfg.pki_lan_ip == ""


def test_the_page_collects_the_canonical_address(wiz):
    page = net_page(wiz)
    page.pki_lan_ip.setText(" 192.168.001.010 ")
    page.pki_lan_fixed.setChecked(True)
    assert page.validatePage()
    assert (wiz.cfg.pki_lan_ip, wiz.cfg.pki_lan_ip_fixed) == ("192.168.1.10", True)
    assert pki_lan.problem(wiz.cfg) == ""


def test_a_loaded_config_shows_its_values(wiz):
    page = net_page(wiz, pki_lan_ip="10.1.2.3", pki_lan_ip_fixed=True)
    assert page.pki_lan_ip.text() == "10.1.2.3"
    assert page.pki_lan_fixed.isChecked()
    assert not page.pki_lan_note.isVisible()


# ── the TUI ─────────────────────────────────────────────────────────────────────────
class _J:
    def __init__(self, cfg):
        self.cfg = cfg
        self.status = ""


def test_tui_network_step_sets_and_refuses_like_the_page():
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    lines = "\n".join(network_step.pki_lan_lines(cfg))
    assert pki_lan.LABEL_IP in lines and pki_lan.WHY in lines
    assert "build will refuse" in lines
    assert "not changed" in network_step.pki_lan_feed(cfg, "ip pki.local")
    assert cfg.pki_lan_ip == ""
    network_step.pki_lan_feed(cfg, "ip 192.168.001.010")
    network_step.pki_lan_feed(cfg, "fixed on")
    assert (cfg.pki_lan_ip, cfg.pki_lan_ip_fixed) == ("192.168.1.10", True)
    assert "build will refuse" not in "\n".join(network_step.pki_lan_lines(cfg))
    # not a mesh: no rows, no commands
    other = ImageConfig(mode="cloud")
    assert network_step.pki_lan_lines(other) == []
    assert network_step.pki_lan_feed(other, "ip 192.168.1.10") is None


def test_tui_screen_wires_the_commands():
    screen = network_step.NetworkScreen()
    j = _J(ImageConfig(mode="mesh", role="pki", platform="x86"))
    j.advance = lambda: None
    screen.feed(j, "ip 10.9.8.7")
    screen.feed(j, "fixed on")
    assert (j.cfg.pki_lan_ip, j.cfg.pki_lan_ip_fixed) == ("10.9.8.7", True)
    assert any("ip ADDR" in ln for ln in screen.lines(j))


# ── what a person SEES ──────────────────────────────────────────────────────────────
from _look import (LOOK_CASES, LOOK_IDS, DEFAULT_WINDOW, assert_fits,  # noqa: E402
                   assert_inside, assert_whole, child_only, looking, settle, snap)


def _box(widget, page):
    """``widget``'s rectangle in the page viewport's coordinates (top, bottom, left, right)."""
    sa = getattr(page, "_content_scroll", None)
    vp = sa.viewport() if sa is not None else page
    tl = widget.mapTo(vp, widget.rect().topLeft()) if vp.isAncestorOf(widget) else None
    if tl is None:
        g = widget.mapToGlobal(widget.rect().topLeft())
        tl = vp.mapFromGlobal(g)
    return tl.y(), tl.y() + widget.height(), tl.x(), tl.x() + widget.width()


@pytest.mark.parametrize(("style", "pt"), LOOK_CASES, ids=LOOK_IDS)
def test_look_the_pki_lan_row_is_drawn_whole(qapp, style, pt):
    child_only()
    with looking(qapp, style, pt):
        w = wizard_mod.StudioWizard(GENERATOR_DIR)
        w.show()
        try:
            page = net_page(w)
            settle(qapp)
            assert (w.width(), w.height()) == DEFAULT_WINDOW
            sa = getattr(page, "_content_scroll", None)
            # the "missing" state: hint, field, tick-box and the red line under them
            if sa is not None:
                sa.ensureWidgetVisible(page.pki_lan_note)
            settle(qapp)
            assert_whole(page.pki_lan_why, "the why-hint")
            assert_inside(page, page.pki_lan_ip, "the address field")
            assert page.pki_lan_ip.width() >= 120, page.pki_lan_ip.width()
            assert_fits(page.pki_lan_fixed, "the 'fixed' tick-box")
            assert_inside(page, page.pki_lan_fixed, "the 'fixed' tick-box")
            assert_whole(page.pki_lan_note, "the refusal line")
            assert_inside(page, page.pki_lan_note, "the refusal line")
            # stacked top to bottom without overlap: hint, field, tick-box, note
            hint, field, tick, note = (_box(x, page) for x in (
                page.pki_lan_why, page.pki_lan_ip, page.pki_lan_fixed, page.pki_lan_note))
            assert hint[1] <= field[0] + 1 and field[1] <= tick[0] + 1 \
                and tick[1] <= note[0] + 1, (hint, field, tick, note)
            snap(w, "pki-lan-missing", style, pt)
            # a malformed address: the same line says why, the page stays put
            page.pki_lan_ip.setText("pki.local")
            assert page.validatePage() is False
            settle(qapp)
            if sa is not None:
                sa.ensureWidgetVisible(page.pki_lan_note)
            settle(qapp)
            assert_whole(page.pki_lan_note, "the mDNS refusal")
            assert_inside(page, page.pki_lan_note, "the mDNS refusal")
            snap(w, "pki-lan-mdns-refused", style, pt)
            # set and confirmed: the line goes away, the field keeps its place
            before = _box(page.pki_lan_ip, page)
            page.pki_lan_ip.setText("192.168.1.10")
            page.pki_lan_fixed.setChecked(True)
            settle(qapp)
            assert not page.pki_lan_note.isVisible()
            assert _box(page.pki_lan_ip, page)[2:] == before[2:], "the field moved sideways"
            snap(w, "pki-lan-confirmed", style, pt)
        finally:
            w.close()
            w.deleteLater()
            settle(qapp)


def test_a_malformed_address_refuses_without_dropping_the_rest_of_the_collect(wiz):
    # GUI-20 (_refuse_malformed): a refusal on Next never returns early, so every field
    # below the pki row is still collected (collect_all() ignores the answer), and a
    # malformed superdomain refused in the same Next is put back, not written through.
    page = net_page(wiz)
    wiz.cfg.superdomain = "good.internal"
    page.superdomain.setText("bad..domain")
    page.pki_lan_ip.setText("pki.local")
    page.root_login.setCurrentIndex(page.root_login.count() - 1)
    want_root_login = page.root_login.currentText()
    assert page.validatePage() is False
    assert wiz.cfg.pki_lan_ip == ""
    assert page.pki_lan_note.isVisible() and "mDNS" in page.pki_lan_note.text()
    assert wiz.cfg.superdomain == "good.internal"
    assert page.superdomain_error.isVisible()
    assert wiz.cfg.root_login == want_root_login
