"""NetworkPage's Egress VPN row on a mesh/node image (finding 6, the GUI half).

The row was gated by PLATFORM only, and that gate could never catch this: egress_vpn is
x86-supported, and the mesh worklist base FORCES platform="x86" (the option superset,
worklist.py:471) before deepcopying itself onto every entry. So the only gate that existed
passed, and the row stayed live on every cluster node in the mesh flow.

The builder does warn — "--egress-vpn given for a non-desktop role (${ROLE}); egress VPN is
a desktop/tailnet-node feature — ignoring" (build-x86-host-stage4.sh:3061) — but "ignoring"
covers ONLY the staging leg :3064. The package leg :3572 and the CONFIG_WIREGUARD kernel
fragment :3849 are not role-gated, so the node emerged the VPN userspace anyway. Warn-and-
ignore that still costs you the packages is exactly the silence this track exists to close.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace  # noqa: E402

from hugmesh_studio.core.config import ImageConfig  # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="module")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def _page(cfg):
    return NetworkPage(SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR))


def test_egress_row_hidden_and_dropped_on_a_mesh_node(qapp):
    """THE defect: live on every mesh node because the platform gate passes via the
    worklist base's forced x86. HIDE it, and drop a stale value on collect."""
    cfg = ImageConfig(mode="mesh", role="backend", platform="x86")
    page = _page(cfg)
    page.initializePage()
    assert not page.egress_row.isVisibleTo(page), "egress VPN still offered on a mesh node"
    assert not page.egress_locked.isVisibleTo(page)
    assert "cluster" in page.egress_row.toolTip()
    # a stale conf picked while the role was a desktop must not ride the switch
    page.egress.setText("/tmp/wg0.conf")
    page.egress_locked.setChecked(True)
    assert page.validatePage()
    assert cfg.egress_vpn == "", "a hidden egress conf still reached the config"
    assert cfg.egress_vpn_locked is False
    assert "--egress-vpn" not in cfg.to_cli_args()


def test_egress_row_live_on_a_cloud_desktop(qapp):
    """The other direction. The builder gates egress on ROLE_CLIENT alone, so a desktop
    keeps it in EVERY mode — emission must stay byte-identical on an in-scope image."""
    cfg = ImageConfig(mode="cloud", role="desktop", platform="x86")
    page = _page(cfg)
    page.initializePage()
    assert page.egress_row.isVisibleTo(page)
    page.egress.setText("/tmp/wg0.conf")
    assert page.validatePage()
    assert cfg.egress_vpn == "/tmp/wg0.conf"
    assert "--egress-vpn" in cfg.to_cli_args()


def test_egress_row_re_gates_per_visit(qapp):
    """Every-visit contract: a node visit must not permanently strand the row."""
    cfg = ImageConfig(mode="mesh", role="backend", platform="x86")
    page = _page(cfg)
    page.initializePage()
    assert not page.egress_row.isVisibleTo(page)
    cfg.mode, cfg.role = "cloud", "desktop"
    page.initializePage()
    assert page.egress_row.isVisibleTo(page), "egress row stranded after a mesh visit"
