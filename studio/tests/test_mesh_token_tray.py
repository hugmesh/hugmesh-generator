"""The tray's mesh section under a shared HugMesh token (gui/tray.py +
gui/mesh_token_dialog.py): the menu offers the token entry, the status line says
what the token grants (or why it cannot be used), and saving Resource limits
restarts a RUNNING mesh node under them instead of waiting for a later start."""
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import mesh_node, mesh_token as mt   # noqa: E402
from hugmesh_studio.gui import tray as tray_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                    # noqa: E402

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def _grant(**over):
    now = int(time.time())
    base = dict(mesh="west", domain="example.org", role="admin", shell=True,
                login_server="https://hs.example.org", auth_key="k",
                expires=now + 3600, issued=now, issuer="ssh-ed25519 AAAA")
    return mt.MeshGrant(**{**base, **over})


def _mesh_tray(monkeypatch, load):
    monkeypatch.setattr(mt, "load_grant", load)
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=True, show_stack=False,
                               builds_provider=lambda: [])
    return tray, tray.sections[0]


def _texts(tray):
    return [a.text() for a in tray.contextMenu().actions()]


def test_the_mesh_section_offers_the_token_entry(qapp, monkeypatch):
    tray, sec = _mesh_tray(monkeypatch, lambda: None)
    assert isinstance(sec.node, mt.GrantedMeshNode)
    assert tray_mod.TOKEN_LABEL in _texts(tray)


def test_the_status_line_says_what_the_token_grants(qapp, monkeypatch):
    tray, sec = _mesh_tray(monkeypatch, lambda: _grant(role="superadmin", shell=False))
    tray._refresh()
    assert sec.status_act.text().endswith("— superadmin in example.org, no shell")


def test_an_unusable_token_is_flagged_with_the_whole_reason(qapp, monkeypatch):
    def expired():
        raise mt.TokenError("expired", "The HugMesh token expired at 2026-11-01 10:00. "
                                       "Ask its issuer for a new one.")
    tray, sec = _mesh_tray(monkeypatch, expired)
    tray._refresh()
    assert "token unusable" in sec.status_act.text()
    assert "Ask its issuer" in sec.status_act.toolTip()


def test_saved_limits_restart_a_running_mesh_node(qapp, monkeypatch):
    tray, sec = _mesh_tray(monkeypatch, lambda: _grant())
    calls = []
    monkeypatch.setattr(mesh_node.MeshNode, "status",
                        lambda self: mesh_node.MeshStatus(True, "1 container(s)"))
    monkeypatch.setattr(type(sec.node), "apply_limits",
                        lambda self: calls.append("apply") or (True, ""))
    assert tray.apply_limits_now() == tray_mod.LIMITS_APPLIED_NOTE
    assert calls == ["apply"]


def test_saved_limits_leave_a_stopped_node_alone(qapp, monkeypatch):
    tray, sec = _mesh_tray(monkeypatch, lambda: _grant())
    monkeypatch.setattr(mesh_node.MeshNode, "status",
                        lambda self: mesh_node.MeshStatus(False, "not started"))
    monkeypatch.setattr(type(sec.node), "apply_limits",
                        lambda self: pytest.fail("a stopped node was restarted"))
    assert tray.apply_limits_now() == ""


def test_a_failed_restart_is_reported_not_hidden(qapp, monkeypatch):
    tray, sec = _mesh_tray(monkeypatch, lambda: _grant())
    monkeypatch.setattr(mesh_node.MeshNode, "status",
                        lambda self: mesh_node.MeshStatus(True, "1 container(s)"))
    monkeypatch.setattr(type(sec.node), "apply_limits",
                        lambda self: (False, "docker said no"))
    assert "not restarted under them: docker said no" in tray.apply_limits_now()
