"""PackagesDialog (spec 9 / design 3.14) — the per-image tri-tier package picker.

Drives the REAL dialog on Qt's offscreen platform against the REAL generator package lists
(so the tiers are the honest builder-derived model). Covers: essentials checked + LOCKED,
default-removable → packages_drop, available → packages_add, the free-atom entry (validated),
legacy extra_packages shown but not migrated, the live counter, and the filter.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import package_catalog as pc          # noqa: E402
from hugmesh_studio.core.config import ImageConfig             # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                # noqa: E402
from hugmesh_studio.gui.pages.packages_dialog import PackagesDialog  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def _thin_cfg():
    # standalone-thin x86: a desktop image whose tiers all have real atoms.
    return ImageConfig(mode="standalone", role="standalone-thin", platform="x86")


def _tiers(cfg):
    return pc.tiers(GENERATOR_DIR, cfg)


def _checked(item):
    return item.checkState(0) == Qt.CheckState.Checked


def test_essentials_checked_and_locked(qapp):
    cfg = _thin_cfg()
    dlg = PackagesDialog(GENERATOR_DIR, cfg)
    ess = _tiers(cfg)["essential"]
    assert ess, "expected a non-empty essential tier for a thin x86 desktop"
    for atom in ess[:5]:
        item = dlg.row_for_atom(atom)
        assert _checked(item)                                  # essential is always installed
        assert not (item.flags() & Qt.ItemFlag.ItemIsEnabled)  # …and locked (greyed)
    # an essential atom never contributes to a delta
    assert dlg.packages_add == "" and dlg.packages_drop == ""


def test_unchecking_a_default_compiles_to_packages_drop(qapp):
    cfg = _thin_cfg()
    dlg = PackagesDialog(GENERATOR_DIR, cfg)
    rem = _tiers(cfg)["removable"]
    assert rem, "expected a non-empty removable tier"
    atom = rem[0]
    item = dlg.row_for_atom(atom)
    assert _checked(item)                                      # default-on
    assert item.flags() & Qt.ItemFlag.ItemIsUserCheckable     # user-editable
    item.setCheckState(0, Qt.CheckState.Unchecked)
    assert atom in dlg.packages_drop.split()
    assert atom not in dlg.packages_add.split()


def test_checking_an_available_extra_compiles_to_packages_add(qapp):
    cfg = _thin_cfg()
    dlg = PackagesDialog(GENERATOR_DIR, cfg)
    avail = _tiers(cfg)["available"]
    assert avail, "expected a non-empty available tier"
    atom = avail[0]
    item = dlg.row_for_atom(atom)
    assert not _checked(item)                                  # off by default
    item.setCheckState(0, Qt.CheckState.Checked)
    assert atom in dlg.packages_add.split()
    assert atom not in dlg.packages_drop.split()


def test_reopen_reapplies_prior_deltas(qapp):
    cfg = _thin_cfg()
    t = _tiers(cfg)
    drop_atom, add_atom = t["removable"][0], t["available"][0]
    dlg = PackagesDialog(GENERATOR_DIR, cfg,
                         packages_add=add_atom, packages_drop=drop_atom)
    assert not _checked(dlg.row_for_atom(drop_atom))           # prior drop reapplied
    assert _checked(dlg.row_for_atom(add_atom))                # prior add reapplied
    assert drop_atom in dlg.packages_drop.split()
    assert add_atom in dlg.packages_add.split()


def test_free_atom_add_is_validated(qapp):
    cfg = _thin_cfg()
    dlg = PackagesDialog(GENERATOR_DIR, cfg)
    # a valid atom not already in the catalog becomes a checked custom extra -> add.
    custom = "dev-util/hugmesh-fake-atom"
    assert custom not in dlg.items
    dlg.free_atom_edit.setText(custom)
    dlg._add_free()
    assert dlg.error_label.isHidden()          # no error (the dialog itself is not shown)
    assert custom in dlg.packages_add.split()
    assert _checked(dlg.row_for_atom(custom))
    # a shell-unsafe atom is rejected (fail-closed) and never added.
    dlg.free_atom_edit.setText("evil/pkg; rm -rf /")
    dlg._add_free()
    assert not dlg.error_label.isHidden()       # error surfaced
    assert "evil/pkg" not in dlg.items


def test_legacy_extra_packages_shown_but_not_migrated(qapp):
    """A retired-field atom is displayed (locked, informational) but is NOT folded into
    packages_add — migrating it would change the emitted argv (I1)."""
    cfg = _thin_cfg()
    dlg = PackagesDialog(GENERATOR_DIR, cfg, extra_packages="app-misc/legacy-widget")
    item = dlg.row_for_atom("app-misc/legacy-widget")
    assert _checked(item)
    assert not (item.flags() & Qt.ItemFlag.ItemIsEnabled)     # locked / frozen
    assert "app-misc/legacy-widget" not in dlg.packages_add.split()


def test_counter_and_filter(qapp):
    cfg = _thin_cfg()
    dlg = PackagesDialog(GENERATOR_DIR, cfg)
    t = _tiers(cfg)
    dlg.row_for_atom(t["available"][0]).setCheckState(0, Qt.CheckState.Checked)
    dlg.row_for_atom(t["removable"][0]).setCheckState(0, Qt.CheckState.Unchecked)
    assert "+1 added" in dlg.counter_label.text()
    assert "1 dropped" in dlg.counter_label.text()
    # filtering hides non-matching atoms.
    target = t["available"][0]
    dlg._apply_filter(target)
    assert not dlg.row_for_atom(target).isHidden()
    other = next((a for a in t["available"] if target not in a), None)
    if other is not None:
        assert dlg.row_for_atom(other).isHidden()


def test_node_image_locks_cluster_payload(qapp):
    """A mesh node image (omnibus x86): the k8s / mandatory payload is essential + locked."""
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86")
    dlg = PackagesDialog(GENERATOR_DIR, cfg)
    assert "sys-cluster/kubelet" in dlg.items
    item = dlg.row_for_atom("sys-cluster/kubelet")
    assert _checked(item) and not (item.flags() & Qt.ItemFlag.ItemIsEnabled)
    assert dlg.items["sys-cluster/kubelet"][1] == "essential"
