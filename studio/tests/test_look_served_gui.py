"""The Look tab says, truthfully, where an added domain's own look shows (theme survey
item B): served by Host on the Docker mesh when the checkout's front door serves it,
"recorded only" when it does not, and "not applied on this route yet" on the image and
Fleet routes. Looked at, not only asserted: with HUGMESH_LOOK_SHOTS set, each case is
grabbed to a PNG.
"""
from __future__ import annotations

import os
from types import SimpleNamespace

import pytest

pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_look                                     # noqa: E402
from hugmesh_studio.core.config import Domain                                  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains            # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                 # noqa: E402
from hugmesh_studio.gui.pages._lookeditor import LookEditor                    # noqa: E402
from hugmesh_studio.gui.pages.brand_screen import TAB_LOOK                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                    # noqa: E402
from hugmesh_studio.tui.superbrand_step import session_for                     # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-look-served-tests"])


def _shot(widget, name: str) -> None:
    out = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if out:
        os.makedirs(out, exist_ok=True)
        widget.grab().save(os.path.join(out, f"{name}.png"))


def _settle(qapp):
    for _ in range(3):
        qapp.processEvents()


def _docker_tab(qapp, generator_dir):
    state = LocalMeshDomains(domains=[Domain(name="mesh.example"), Domain(name="shop.example")],
                             own_name="mesh.example")
    session = session_for(SimpleNamespace(), "docker",
                          (LocalMeshBootstrapConfig(), state), generator_dir)
    widget = ds_mod.DomainServicesWidget(brand_session=lambda: session, route="docker")
    widget.load(state)
    widget._step(1)                                   # the added domain
    widget.resize(1000, 900)
    widget.show()
    widget.brand_tabs.setCurrentIndex(TAB_LOOK)
    _settle(qapp)
    return state, widget, widget.brand_tabs.look_editor


def _sane(label, what):
    assert label.isVisible(), f"{what} is not shown"
    assert label.isEnabled(), f"{what} is greyed out"
    g = label.geometry()
    assert g.width() >= 200 and g.height() >= 14, f"{what} is {g.width()}x{g.height()}"


def test_docker_route_says_the_added_domains_look_is_served(qapp):
    state, widget, ed = _docker_tab(qapp, REPO)
    assert ed is not None and ed.model.mode == "override"
    assert ed.served_note.text() == brand_look.DOCKER_SERVED_SENTENCE
    _sane(ed.served_note, "the served sentence")
    assert ed.path_note.isHidden() and ed.primary.isEnabled()
    _shot(widget, "docker-added-domain-look-served")
    widget.close()


def test_docker_route_on_a_checkout_without_the_door_says_recorded_only(qapp, tmp_path):
    state, widget, ed = _docker_tab(qapp, str(tmp_path))
    assert ed.served_note.text() == brand_look.DOCKER_NOT_SERVED_SENTENCE
    _sane(ed.served_note, "the recorded-only sentence")
    _shot(widget, "docker-added-domain-look-recorded-only")
    widget.close()


@pytest.mark.parametrize("path", ["image", "fleet"])
def test_image_and_fleet_say_plainly_it_is_not_applied(qapp, path):
    base = brand_look.Look({"primary": "#3355aa"})
    ed = LookEditor(brand_look.Look({}, base=base.effective()), path=path,
                    generator_dir=REPO)
    ed.resize(900, 700)
    ed.show()
    _settle(qapp)
    assert ed.path_note.text() == brand_look.DOCKER_ONLY_SENTENCE
    assert ed.path_note.text().startswith("Not applied on this route yet")
    _sane(ed.path_note, "the not-applied sentence")
    assert ed.served_note.isHidden()
    assert not ed.primary.isEnabled()
    _shot(ed, f"{path}-added-domain-look-not-applied")
    ed.close()


def test_the_mesh_own_look_row_has_no_where_sentence(qapp):
    ed = LookEditor(brand_look.Look({"primary": "#3355aa"}), path="docker", generator_dir=REPO)
    ed.show()
    _settle(qapp)
    assert ed.served_note.isHidden() and ed.path_note.isHidden()
    ed.close()
