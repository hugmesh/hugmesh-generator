"""The IdP screens show core's provider hints, word for word (test_idp_hints.py holds
the table; this file looks at the screens that read it).

Four frames carry an issuer / client-id / JWKS line edit or an IdP picker: the node
wizard's IdP page, the provider wizard window, the local mesh's bootstrap tab and the
Cloud deploy page. Each used to spell the text itself, and the copies had drifted: the
bootstrap tab's OIDC JWKS hint lacked the clause the other two carry, and the Deploy
page's combo labelled the built-in provider "Casdoor (built-in — default)" where every
other picker says "Casdoor (built-in) — default".
"""
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_mesh_bootstrap as lmb          # noqa: E402
from hugmesh_studio.core import saved_meshes as sm                   # noqa: E402
from hugmesh_studio.core.config import (                             # noqa: E402
    IDP_CHOICES, IDP_CLIENT_HINTS, IDP_ISSUER_HINTS, IDP_JWKS_HINTS, IDP_LABELS)
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus       # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                  # noqa: E402
from hugmesh_studio.gui.pages import deploy as deploy_mod            # noqa: E402
from hugmesh_studio.gui.pages import idp_provider                    # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod      # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                          # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

EXTERNAL = [p for p in IDP_CHOICES if p != "casdoor"]


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _page(wiz, cls_name):
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        if type(page).__name__ == cls_name:
            return page
    raise AssertionError(f"page {cls_name} not registered")


@pytest.mark.parametrize("idp", EXTERNAL)
def test_the_node_wizard_idp_page_shows_core_hints(wiz, idp):
    page = _page(wiz, "IdpPage")
    page._buttons[idp].setChecked(True)          # programmatic: never navigates
    assert page.issuer.placeholderText() == IDP_ISSUER_HINTS[idp]
    assert page.client_id.placeholderText() == IDP_CLIENT_HINTS[idp]
    assert page.jwks.placeholderText() == IDP_JWKS_HINTS[idp]


@pytest.mark.parametrize("idp", EXTERNAL)
def test_the_provider_wizard_shows_core_hints(qapp, idp):
    win = idp_provider.ProviderConfigWindow(idp)
    try:
        ep = win.endpoints_page
        assert ep.issuer.placeholderText() == IDP_ISSUER_HINTS[idp]
        assert ep.client_id.placeholderText() == IDP_CLIENT_HINTS[idp]
        assert ep.jwks.placeholderText() == IDP_JWKS_HINTS[idp]
    finally:
        win.close()
        win.deleteLater()


def test_the_provider_wizard_steps_quote_the_core_shapes(qapp):
    """The walk-through prose names the issuer shape the field shows, built from the
    same table (the Entra and Cognito steps) and the same JWKS suffix (the generic one)."""
    steps = idp_provider.PROVIDER_STEPS
    assert any(IDP_ISSUER_HINTS["entra"] in s for s in steps["entra"])
    assert any(IDP_ISSUER_HINTS["aws"] in s for s in steps["aws"])
    assert any("<issuer>/.well-known/jwks," in s for s in steps["oidc"])


@pytest.fixture
def mesh_page(qapp, monkeypatch):
    monkeypatch.setattr(MeshNode, "status",
                        lambda self: MeshStatus(running=False, detail="not started"))
    monkeypatch.setattr(sm, "probe_state", lambda rec, project="": {})
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""))
    p = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace(),
                        localmesh_selected=True))
    yield p
    for name in dir(p):
        t = getattr(p, name, None)
        if isinstance(t, localmesh_mod.QtCore.QThread):
            t.wait(5000)
    qapp.processEvents()
    p.deleteLater()


@pytest.mark.parametrize("idp", EXTERNAL)
def test_the_local_mesh_bootstrap_tab_shows_core_hints(mesh_page, idp):
    mesh_page.idp.setCurrentIndex(mesh_page.idp.findData(idp))
    mesh_page._refresh_plan()
    assert mesh_page.idp_issuer.placeholderText() == IDP_ISSUER_HINTS[idp]
    # the drift this fixes: the OIDC line lost its "(override ...)" clause here
    assert mesh_page.idp_jwks.placeholderText() == IDP_JWKS_HINTS[idp]


def test_the_cloud_deploy_page_reads_the_same_labels_and_shapes(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(tmp_path / "nope"))
    dlg = deploy_mod.DeployDialog(str(tmp_path))
    try:
        items = [(dlg.idp.itemData(i), dlg.idp.itemText(i)) for i in range(dlg.idp.count())]
        assert items == [("" if p == "casdoor" else p, IDP_LABELS[p]) for p in IDP_CHOICES]
        hint = dlg.idp_issuer.placeholderText()
        assert IDP_ISSUER_HINTS["entra"] in hint and IDP_ISSUER_HINTS["aws"] in hint
    finally:
        dlg.close()
        dlg.deleteLater()
