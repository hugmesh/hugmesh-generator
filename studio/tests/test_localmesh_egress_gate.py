"""The egress-vpn conf channel (operator ask 2026-08-14), all three layers:
node env exports + fail-closed ctor, bootstrap preflight, and the page's
never-left-checked-without-a-conf gate. The conf dialog itself opens only from
a real mouse click (`clicked`) — these tests exercise every other path, which
is exactly why none of them can hang on a modal."""
import os

import pytest

from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_stack_node import LocalStackNode

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_WG = ("[Interface]\nPrivateKey = x=\nAddress = 10.2.0.2/32\n"
       "[Peer]\nPublicKey = y=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n")


@pytest.fixture
def wg_conf(tmp_path):
    p = tmp_path / "wg0.conf"
    p.write_text(_WG)
    return str(p)


# ── node: env + fail-closed ctor ────────────────────────────────────────────────
def test_node_exports_egress_and_tts_env(wg_conf):
    node = LocalStackNode(GENERATOR_DIR, with_tts=True,
                          with_egress_vpn=True, egress_vpn_conf=wg_conf)
    env = node._build_env()
    assert env["TTS"] == "1"
    assert env["EGRESS_VPN"] == "1"
    assert env["EGRESS_VPN_CONF"] == os.path.abspath(wg_conf)


def test_node_off_exports_empty_knobs():
    env = LocalStackNode(GENERATOR_DIR)._build_env()
    assert env["TTS"] == "" and env["EGRESS_VPN"] == ""
    assert "EGRESS_VPN_CONF" not in env


def test_node_confless_egress_exports_no_conf_path():
    # NOT a ctor raise (the plan preview builds a node mid-selection; a raise
    # would escape a Qt slot and qFatal the Studio). Conf-less means no
    # EGRESS_VPN_CONF export: compose then mounts /dev/null and the container
    # refuses to start — the terminal fail-closed layer.
    env = LocalStackNode(GENERATOR_DIR, with_egress_vpn=True)._build_env()
    assert env["EGRESS_VPN"] == "1"
    assert "EGRESS_VPN_CONF" not in env


# ── bootstrap: picker-driven effectives + preflight ─────────────────────────────
def test_effective_tts_and_egress_follow_the_picker():
    cfg = LocalMeshBootstrapConfig(services=("tuwunel", "edge-ai-tts", "egress-vpn"))
    assert cfg.effective_tts() and cfg.effective_egress_vpn()
    assert not LocalMeshBootstrapConfig(services=("tuwunel",)).effective_tts()
    assert not LocalMeshBootstrapConfig().effective_egress_vpn()   # no picker => off


def test_validate_blocks_selected_egress_without_usable_conf(wg_conf):
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        services=("egress-vpn",)))
    assert any("Egress VPN" in p for p in boot.validate())
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        services=("egress-vpn",), egress_vpn_conf=wg_conf))
    assert not any("Egress VPN" in p for p in boot.validate())


# ── page: the exit gate ─────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def qapp():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    from hugmesh_studio.gui.pages.localmesh import LocalMeshPage
    from types import SimpleNamespace
    return LocalMeshPage(SimpleNamespace(generator_dir=GENERATOR_DIR,
                                         cfg=SimpleNamespace()))


def test_conf_less_check_is_unchecked_at_exit(page):
    """collect_services deliberately does NOT enforce (the plan preview runs it on
    every toggle — unchecking there would revert a user's click before its
    `clicked` handler could open the dialog). The EXIT hook is what may never
    leave the box checked without a conf."""
    box = page.service_boxes["egress-vpn"]
    box.setChecked(True)                     # programmatic: no dialog (by design)
    assert "egress-vpn" in page.collect_services()   # pending state is visible...
    boot = LocalMeshBootstrap(GENERATOR_DIR, page.collect_bootstrap())
    assert any("Egress VPN" in p for p in boot.validate())   # ...but blocks an up
    page._enforce_egress_conf()              # what hideEvent runs on any exit
    assert not box.isChecked()
    assert "egress-vpn" not in page.collect_services()
    assert not page.egress_note.isHidden()


def test_valid_conf_survives_the_gate_and_reaches_the_config(page, wg_conf):
    box = page.service_boxes["egress-vpn"]
    box.setChecked(True)
    page._egress_vpn_conf = wg_conf          # what the click-dialog would have set
    page._enforce_egress_conf()
    assert box.isChecked()
    assert "egress-vpn" in page.collect_services()
    assert page.collect_bootstrap().egress_vpn_conf == wg_conf


def test_vanished_conf_is_caught_on_exit(page, tmp_path):
    p = tmp_path / "gone.conf"
    p.write_text(_WG)
    box = page.service_boxes["egress-vpn"]
    box.setChecked(True)
    page._egress_vpn_conf = str(p)
    p.unlink()                               # picked, then deleted out from under us
    page._enforce_egress_conf()
    assert not box.isChecked()
    assert "egress-vpn" not in page.collect_services()
