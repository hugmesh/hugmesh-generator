"""Mesh control over Tor (core/mesh_control.py) on every face — OPT-IN, default lan.

Pinned here: the field's emission (x86 + rpi5 only, nothing on lan), the KEYS-channel
arguments (transport, the per-run onion dir, the mint consent), the build refusals (no
consent; an image whose builder cannot bake Tor), the secret key leaving this computer
after the run, the Network page (mesh only; consent enabled only for a Tor choice) and
the TUI's ``transport`` / ``mint`` commands. The ``test_look_*`` case runs in a fresh
interpreter started by tests/test_look.py and saves screenshots with HUGMESH_LOOK_SHOTS.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import mesh_control                       # noqa: E402
from hugmesh_studio.core.config import ImageConfig                 # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.core.worklist_driver import WorklistDriver     # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage           # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                        # noqa: E402
from hugmesh_studio.tui import network_step                        # noqa: E402

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
            or QtWidgets.QApplication(["hugmesh-studio-mesh-control-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def net_page(wiz, **cfg_kw):
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


# ── emission ────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_tor_transport_is_emitted_on_the_tor_builders(platform):
    on = ImageConfig(mode="mesh", role="pki", platform=platform,
                     mesh_control_transport="lan+onion").to_cli_args()
    i = on.index("--mesh-control-transport")
    assert on[i + 1] == "lan+onion"


@pytest.mark.parametrize("platform", ["jetson", "orangepi5", "frite"])
def test_never_emitted_where_the_builder_refuses_it(platform):
    args = ImageConfig(mode="mesh", role="pki", platform=platform,
                       mesh_control_transport="onion").to_cli_args()
    assert "--mesh-control-transport" not in args


def test_lan_emits_nothing():
    for v in ("", "lan"):
        args = ImageConfig(mode="mesh", role="pki", platform="x86",
                           mesh_control_transport=v).to_cli_args()
        assert "--mesh-control-transport" not in args


def test_a_bad_value_is_refused():
    with pytest.raises(ValueError):
        ImageConfig(mode="mesh", mesh_control_transport="tor").validate_identity()


# ── the KEYS channel and the build refusals ─────────────────────────────────────────
def _wl(platforms=("x86", "rpi5"), **kw):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                       pki_lan_ip="192.168.1.10", pki_lan_ip_fixed=True, **kw)
    roles = ("pki", "backend")
    return WorklistConfig(base=base, entries=[WorklistEntry(role=r, platform=p)
                                              for r, p in zip(roles, platforms)])


def test_genkeys_args(tmp_path):
    lan = ImageConfig(mode="mesh")
    assert mesh_control.genkeys_args(lan, str(tmp_path)) == []
    tor = ImageConfig(mode="mesh", mesh_control_transport="onion", mesh_control_onion_mint=True)
    assert mesh_control.genkeys_args(tor, str(tmp_path)) == [
        "--mesh-control-transport", "onion",
        "--mesh-control-onion-dir", os.path.join(str(tmp_path), "mesh-control-onion"),
        "--mesh-control-onion-mint"]


def test_preflight_needs_the_mint_consent(tmp_path):
    drv = WorklistDriver(GENERATOR_DIR, _wl(output_dir=str(tmp_path),
                                            mesh_control_transport="lan+onion"),
                         host=HOST, backend="native")
    assert any(mesh_control.MINT_LABEL in p for p in drv.preflight())
    drv = WorklistDriver(GENERATOR_DIR, _wl(output_dir=str(tmp_path),
                                            mesh_control_transport="lan+onion",
                                            mesh_control_onion_mint=True),
                         host=HOST, backend="native")
    assert not any("onion" in p.lower() for p in drv.preflight())


def test_preflight_refuses_a_node_whose_builder_cannot_bake_tor(tmp_path):
    drv = WorklistDriver(GENERATOR_DIR, _wl(("x86", "orangepi5"), output_dir=str(tmp_path),
                                            mesh_control_transport="onion",
                                            mesh_control_onion_mint=True),
                         host=HOST, backend="native")
    assert any("orangepi5 builder cannot bake Tor" in p for p in drv.preflight())


def test_lan_adds_no_refusal(tmp_path):
    drv = WorklistDriver(GENERATOR_DIR, _wl(("x86", "orangepi5"), output_dir=str(tmp_path)),
                         host=HOST, backend="native")
    assert not any("Tor" in p for p in drv.preflight())


def test_the_secret_key_is_removed_after_the_run(tmp_path):
    cfg = ImageConfig(mode="mesh", mesh_control_transport="onion")
    d = tmp_path / "mesh-control-onion"
    d.mkdir()
    for n in ("hostname", "hs_ed25519_secret_key", "hs_ed25519_public_key"):
        (d / n).write_text("x")
    mesh_control.forget_secret(cfg, str(tmp_path))
    assert sorted(os.listdir(d)) == ["hostname"]


# ── the Network page ────────────────────────────────────────────────────────────────
def test_mesh_only_and_default_lan(wiz):
    page = net_page(wiz)
    assert page.mesh_control_box.isVisible()
    assert page.mesh_control_transport.currentData() == "lan"
    assert not page.mesh_control_mint.isEnabled()
    page = net_page(wiz, mode="cloud", role="desktop")
    assert not page.mesh_control_box.isVisible()


def test_page_collects_transport_and_consent(wiz):
    page = net_page(wiz)
    page.mesh_control_transport.setCurrentIndex(
        page.mesh_control_transport.findData("lan+onion"))
    assert page.mesh_control_mint.isEnabled()
    page.mesh_control_mint.setChecked(True)
    assert page.validatePage()
    assert (wiz.cfg.mesh_control_transport, wiz.cfg.mesh_control_onion_mint) == ("lan+onion", True)
    page.mesh_control_transport.setCurrentIndex(page.mesh_control_transport.findData("lan"))
    assert page.validatePage()
    assert (wiz.cfg.mesh_control_transport, wiz.cfg.mesh_control_onion_mint) == ("", False)


# ── the TUI ─────────────────────────────────────────────────────────────────────────
def test_tui_transport_and_mint():
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    assert "takes lan" in network_step.pki_lan_feed(cfg, "transport tor")
    assert "Tor transport only" in network_step.pki_lan_feed(cfg, "mint on")
    network_step.pki_lan_feed(cfg, "transport onion")
    network_step.pki_lan_feed(cfg, "mint on")
    assert (cfg.mesh_control_transport, cfg.mesh_control_onion_mint) == ("onion", True)
    text = "\n".join(network_step.pki_lan_lines(cfg))
    assert mesh_control.LABELS["onion"] in text and mesh_control.MINT_LABEL in text
    network_step.pki_lan_feed(cfg, "transport lan")
    assert (cfg.mesh_control_transport, cfg.mesh_control_onion_mint) == ("", False)


# ── what a person SEES ──────────────────────────────────────────────────────────────
from _look import (LOOK_CASES, LOOK_IDS, DEFAULT_WINDOW, assert_fits,  # noqa: E402
                   assert_inside, assert_whole, child_only, looking, settle, snap)


@pytest.mark.parametrize(("style", "pt"), LOOK_CASES, ids=LOOK_IDS)
def test_look_the_transport_choice_is_drawn_whole(qapp, style, pt):
    child_only()
    with looking(qapp, style, pt):
        w = wizard_mod.StudioWizard(GENERATOR_DIR)
        w.show()
        try:
            page = net_page(w)
            settle(qapp)
            assert (w.width(), w.height()) == DEFAULT_WINDOW
            sa = getattr(page, "_content_scroll", None)
            combo = page.mesh_control_transport
            combo.setCurrentIndex(combo.findData("lan+onion"))
            settle(qapp)
            if sa is not None:
                sa.ensureWidgetVisible(page.mesh_control_mint)
            settle(qapp)
            assert_whole(page.mesh_control_q, "the question")
            assert_inside(page, combo, "the transport dropdown")
            fm = combo.fontMetrics()
            for i in range(combo.count()):          # no choice is elided
                assert fm.horizontalAdvance(combo.itemText(i)) + 24 <= combo.width(), \
                    f"{combo.itemText(i)!r} does not fit {combo.width()}px"
            assert_whole(page.mesh_control_why, "the trade-offs text")
            assert_inside(page, page.mesh_control_why, "the trade-offs text")
            assert_fits(page.mesh_control_mint, "the mint consent tick-box")
            assert_inside(page, page.mesh_control_mint, "the mint consent tick-box")
            snap(w, "mesh-control-lan-onion", style, pt)
            combo.setCurrentIndex(combo.findData("lan"))
            settle(qapp)
            assert not page.mesh_control_why.isVisible()
            assert not page.mesh_control_mint.isEnabled()
            snap(w, "mesh-control-lan", style, pt)
        finally:
            w.close()
            w.deleteLater()
            settle(qapp)
