"""The fleet flow on native Windows (the MSI) says the true reason a native fleet cannot run.

#827 group 1 dropped "native" from BuildPage's backend combo on Windows and gave
BuildDriver.preflight a WSL2/docker refusal. The fleet missed both: FleetPage still
offered "native", and FleetDriver.preflight overrides BuildDriver's without calling it,
so a native fleet on Windows was refused with "Native build needs root (the Studio will
prepend sudo)." That is false there: is_root is always False on Windows (no geteuid),
running as Administrator cannot clear it, and sudo is not what is missing.

Host-independent: Windows is answered through ``native_windows_blocker(osname="nt")``,
never by changing os.name for the process (pathlib and subprocess read it too).
"""
from __future__ import annotations

import functools
import os

import pytest

from hugmesh_studio.core import platform_info
from hugmesh_studio.core.fleet import FleetConfig, FleetDriver
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# What detect() reports on the MSI: no Gentoo, never root.
WINDOWS_HOST = HostInfo(os="windows", is_gentoo=False, has_docker=True, has_bash=True,
                        has_kvm=False, is_root=False, builder_image="hugmesh-builder")
LINUX_HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                      has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture
def as_native_windows(monkeypatch):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(platform_info.native_windows_blocker,
                                          osname="nt"))


@pytest.fixture
def as_posix(monkeypatch):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(platform_info.native_windows_blocker,
                                          osname="posix"))


def test_native_fleet_on_windows_names_docker_and_wsl2_not_root(as_native_windows):
    problems = FleetDriver(GENERATOR_DIR, WINDOWS_HOST).preflight(FleetConfig(), "native")
    said = [p for p in problems if "native fleet build" in p]
    assert len(said) == 1, problems
    assert "docker backend" in said[0] and "WSL2" in said[0], said
    assert not any("needs root" in p for p in problems), problems


def test_native_fleet_off_windows_keeps_the_root_sentence(as_posix):
    # Linux/WSL is unchanged: a non-root native fleet still gets the root refusal.
    problems = FleetDriver(GENERATOR_DIR, LINUX_HOST).preflight(FleetConfig(), "native")
    assert "Native build needs root (the Studio will prepend sudo)." in problems, problems
    assert not any("WSL2" in p for p in problems), problems


def test_docker_fleet_on_windows_is_not_refused_for_being_on_windows(as_native_windows,
                                                                     monkeypatch):
    monkeypatch.setattr(FleetDriver, "_image_present", lambda self: True)
    problems = FleetDriver(GENERATOR_DIR, WINDOWS_HOST).preflight(FleetConfig(), "docker")
    assert not any("WSL2" in p or "needs root" in p for p in problems), problems


def test_backend_choices_drop_native_on_windows_only():
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    from hugmesh_studio.gui.pages import fleet as fleet_mod
    assert fleet_mod._backend_choices("nt") == ["auto", "docker"]
    assert fleet_mod._backend_choices("posix") == ["auto", "native", "docker"]


def test_fleet_page_combo_offers_this_hosts_choices(tmp_path, monkeypatch):
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    from hugmesh_studio.gui.pages import fleet as fleet_mod
    from hugmesh_studio.gui.qt import QtWidgets
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    app = (QtWidgets.QApplication.instance()
           or QtWidgets.QApplication(["hugmesh-studio-tests"]))
    page = fleet_mod.FleetPage(GENERATOR_DIR)
    try:
        items = [page.backend.itemText(i) for i in range(page.backend.count())]
        assert items == fleet_mod._backend_choices(), items
        if os.name == "nt":
            assert "native" not in items, items
    finally:
        page.deleteLater()
        app.processEvents()
