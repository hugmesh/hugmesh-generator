"""riscv64 ships labelled "no SELinux" (hugmesh-generator#1059; operator decision
2026-11-12). The catalog carries the fact per arch, and the Studio shows it where an
architecture is chosen: the arch button's label and the note under the device tree.

The repo-wide guard (tests/scripts/test-riscv64-no-selinux.sh) pins the catalog flag to
the builders' profiles, the build summary, publish-manifest.json and the docs; this file
pins the Studio side. The GUI half needs a Qt binding and is skipped without one.
"""
import os

import pytest

from hugmesh_studio.core import device_catalog

CAT = device_catalog.load_catalog()


def test_riscv64_is_the_only_arch_without_selinux():
    flags = {a.id: a.selinux for a in CAT.archs}
    assert flags["riscv64"] is False
    assert {a for a, v in flags.items() if not v} == {"riscv64"}
    assert device_catalog.arch_has_selinux("riscv64") is False
    for arch in ("x86-64", "arm64", "armv7"):
        assert device_catalog.arch_has_selinux(arch) is True


def test_arch_labels_say_no_selinux_exactly_where_the_flag_is_false():
    for a in CAT.archs:
        assert (device_catalog.NO_SELINUX in a.label) is (not a.selinux), a


def test_every_riscv64_device_is_labelled_and_no_other_device_is():
    for dev in CAT.devices:
        label = device_catalog.selinux_label(dev.id)
        if dev.arch == "riscv64":
            assert label.startswith(device_catalog.NO_SELINUX), dev.id
        else:
            assert label == "", dev.id


def test_the_web_catalog_carries_the_flag():
    from importlib import util
    here = os.path.dirname(os.path.abspath(__file__))
    emitter = os.path.join(os.path.dirname(os.path.dirname(here)), "scripts",
                           "emit-image-catalog.py")
    spec = util.spec_from_file_location("emit_image_catalog", emitter)
    mod = util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    archs = {a["id"]: a for a in mod.build_image_catalog()["archs"]}
    assert archs["riscv64"]["selinux"] is False
    assert all(a["selinux"] is True for i, a in archs.items() if i != "riscv64")


# ── the GUI: what a person actually sees ───────────────────────────────────────────

@pytest.fixture
def role_page():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.qt import QtWidgets
    from _helpers import advance_to

    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    orig = wizard_mod.detect
    wizard_mod.detect = lambda builder_image="hugmesh-builder": host
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["r2-test"])
    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    w = wizard_mod.StudioWizard(os.path.dirname(studio_root))
    w.show()
    try:
        yield advance_to(w, wizard_mod.RolePage), app
    finally:
        w.close()
        w.deleteLater()
        wizard_mod.detect = orig


def test_gui_riscv64_button_and_note_say_no_selinux(role_page):
    page, app = role_page
    btn = page._arch_buttons["riscv64"]
    assert device_catalog.NO_SELINUX in btn.text()
    btn.setChecked(True)
    app.processEvents()
    assert device_catalog.NO_SELINUX in page.note.text()
    # and the other arch buttons do not
    for arch, b in page._arch_buttons.items():
        if arch != "riscv64":
            assert device_catalog.NO_SELINUX not in b.text(), arch
    page._arch_buttons["x86-64"].setChecked(True)
    app.processEvents()
    assert device_catalog.NO_SELINUX not in page.note.text()
