"""The Jetson l4t kernel flavour is shown greyed with its reason, never offered
(hugmesh-generator #1060, lane E1).

build-jetson-stage4.sh exits 1 on ``--kernel-flavor l4t`` by design: NVIDIA's L4T
kernel and CUDA userspace are EULA-gated downloads it does not fetch. Both Studio combos
that carry the axis (RolePage's Jetson box and the fleet page's Jetson group) used to
offer it as an ordinary item. Now every ENABLED item is an offered flavour (or the
builder-default sentinel), the l4t item is listed but disabled with the reason as its
tooltip, and a saved config naming l4t restores as the builder default instead of
re-selecting the greyed row.

The catalog/config half (KERNEL_FLAVOR_REFUSED equals what the builder refuses) is
pinned by test_catalog_doc_truth.py; this file pins what a person sees.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (                           # noqa: E402
    KERNEL_FLAVOR_CHOICES, KERNEL_FLAVOR_REFUSED,
)
from hugmesh_studio.core.fleet import FleetConfig                    # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo               # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                  # noqa: E402
from hugmesh_studio.gui.pages import fleet as fleet_mod              # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                      # noqa: E402

from _helpers import advance_to                                      # noqa: E402

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
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _items(combo):
    """(data, enabled, tooltip) for every item of a combo."""
    out = []
    for i in range(combo.count()):
        item = combo.model().item(i)
        out.append((combo.itemData(i), item.isEnabled(),
                    combo.itemData(i, Qt.ItemDataRole.ToolTipRole) or ""))
    return out


def _assert_offer(combo):
    items = _items(combo)
    enabled = [d for d, on, _ in items if on]
    greyed = {d: tip for d, on, tip in items if not on}
    # every enabled item builds: the default sentinel or an offered flavour
    assert set(enabled) <= {""} | set(KERNEL_FLAVOR_CHOICES), enabled
    assert set(KERNEL_FLAVOR_CHOICES) <= set(enabled)
    # every refused flavour is LISTED, greyed, with its reason as the tooltip
    assert set(greyed) == set(KERNEL_FLAVOR_REFUSED), greyed
    for flavour, reason in KERNEL_FLAVOR_REFUSED.items():
        assert greyed[flavour] == reason, flavour
    # and the combo's own tooltip says why too
    assert KERNEL_FLAVOR_REFUSED["l4t"] in combo.toolTip()


def _role_page(wiz):
    for pid in wiz.pageIds():
        page = wiz.page(pid)
        if isinstance(page, wizard_mod.RolePage):
            return page
    raise AssertionError("no RolePage in the wizard")


def test_role_page_lists_l4t_greyed_with_its_reason(wiz):
    _assert_offer(_role_page(wiz).kernel_flavor)


def test_role_page_restores_a_saved_l4t_as_the_builder_default(wiz):
    """A config saved while l4t was offered must not reopen with the greyed row
    selected: that row would be emitted on the next commit."""
    wiz.cfg.kernel_flavor = "l4t"
    page = advance_to(wiz, wizard_mod.RolePage)
    assert page.kernel_flavor.currentData() == ""
    wiz.cfg.kernel_flavor = "mainline"       # a still-offered value restores as itself
    page.initializePage()
    assert page.kernel_flavor.currentData() == "mainline"


def test_fleet_page_lists_l4t_greyed_with_its_reason(qapp):
    page = fleet_mod.FleetPage(GENERATOR_DIR)
    try:
        _assert_offer(page.jetson_kernel_flavor)
    finally:
        page.deleteLater()


def test_fleet_page_restores_a_saved_l4t_as_the_builder_default(qapp):
    page = fleet_mod.FleetPage(GENERATOR_DIR)
    try:
        page.apply(FleetConfig(jetson=True, jetson_kernel_flavor="l4t"))
        assert page.jetson_kernel_flavor.currentData() == ""
        assert page.collect().jetson_kernel_flavor == ""
        page.apply(FleetConfig(jetson=True, jetson_kernel_flavor="mainline"))
        assert page.collect().jetson_kernel_flavor == "mainline"
    finally:
        page.deleteLater()
