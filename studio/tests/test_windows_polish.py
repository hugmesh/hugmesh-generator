"""Two native-Windows (MSI) polish items, pinned on every host.

* The Build page's "QEMU emulated-device tests" box was offered for any --env test
  build, and on Windows ProgressPage then skipped the run after the build with the
  WSL2 sentence. The runner is a bash script, so the box is greyed there with that
  sentence as its tooltip; a saved config carrying the tick still loads.
* The Go-Live export step hands over the same export as one line
  (org_export.cli_command), which on Windows is a PowerShell line (the ``&`` call
  operator, '' quoting). The GUI row and the TUI heading say "terminal" elsewhere and
  name PowerShell there, because cmd.exe would not run it.

The host-independent tests answer as one OS or the other through
platform_info.native_windows_blocker (never os.name, which pathlib and subprocess
read too); the ``skipif`` ones check the real host's answer end to end.
"""
from __future__ import annotations

import functools
import os

import pytest

# must be set BEFORE the first QApplication is created (the page tests below)
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import org_export, platform_info, qemu_tests   # noqa: E402
from hugmesh_studio.core.config import ImageConfig                       # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                   # noqa: E402
from hugmesh_studio.tui import golive as tui_golive, journey             # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
_REAL_BLOCKER = platform_info.native_windows_blocker


def _answer_as(monkeypatch, osname):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_BLOCKER, osname=osname))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def studio(qapp, monkeypatch):
    from hugmesh_studio.gui import wizard as wizard_mod
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda *_a, **_k: (True, "docker is available."))
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _build_page(wiz):
    from _helpers import advance_to
    from hugmesh_studio.gui import wizard as wizard_mod
    return advance_to(wiz, wizard_mod.BuildPage)


# ── the Build page's post-build device tests box ──────────────────────────────────────
def test_the_msi_greys_the_device_tests_box_on_test_with_the_wsl2_sentence(studio,
                                                                           monkeypatch):
    _answer_as(monkeypatch, "nt")
    build = _build_page(studio)
    box = build.qemu_device_tests
    assert build.env.currentText() == "test"            # the env the box needs elsewhere
    assert not box.isEnabled() and not box.isChecked()
    assert box.toolTip() == qemu_tests.native_blocker() and "WSL2" in box.toolTip()
    build.env.setCurrentText("prod")
    build.env.setCurrentText("test")                     # the env switch does not revive it
    assert not box.isEnabled() and box.toolTip() == qemu_tests.native_blocker()
    box.setChecked(True)                                 # a programmatic tick bypasses the grey
    build._preview()
    assert studio.cfg.qemu_device_tests is False


def test_elsewhere_the_device_tests_box_still_follows_env_alone(studio, monkeypatch):
    """The Linux/WSL behaviour, held on every host: offered on test, greyed on prod."""
    _answer_as(monkeypatch, "posix")
    build = _build_page(studio)
    box = build.qemu_device_tests
    assert box.isEnabled() and "run-qemu-docker.sh" in box.toolTip()
    build.env.setCurrentText("prod")
    assert not box.isEnabled() and "prod" in box.toolTip()
    build.env.setCurrentText("test")
    box.setChecked(True)
    build._preview()
    assert studio.cfg.qemu_device_tests is True


def test_a_saved_config_with_the_tick_still_loads_in_the_msi(studio, monkeypatch, tmp_path):
    """A config saved on Linux with the box ticked opens in the MSI without error: the
    box is greyed and unticked, and the flag is not carried on into the build."""
    cfg = ImageConfig()
    cfg.qemu_device_tests = True
    path = str(tmp_path / "ticked.json")
    cfg.save(path)
    assert ImageConfig.load(path).qemu_device_tests is True     # what the file carries
    _answer_as(monkeypatch, "nt")
    studio.load_config(path)
    build = _build_page(studio)
    assert not build.qemu_device_tests.isEnabled()
    assert not build.qemu_device_tests.isChecked()
    build._preview()
    assert studio.cfg.qemu_device_tests is False


@pytest.mark.skipif(os.name != "nt", reason="the real native-Windows answer")
def test_on_windows_the_device_tests_box_is_greyed(studio):
    build = _build_page(studio)
    assert not build.qemu_device_tests.isEnabled()
    assert "WSL2" in build.qemu_device_tests.toolTip()


# ── the Go-Live export step's hand-over line ─────────────────────────────────────────
def test_the_heading_names_powershell_only_on_windows():
    from hugmesh_studio.gui.pages import golive as gui_golive
    assert tui_golive.same_line_heading("nt") == "The same in PowerShell:"
    assert tui_golive.same_line_heading("posix") == "The same from a terminal:"
    assert gui_golive._shell_name("nt") == "PowerShell"
    assert gui_golive._shell_name("posix") == "Terminal"


def test_the_label_and_the_line_agree_on_this_host():
    """Whatever this host is, the heading names PowerShell exactly when the line is
    PowerShell's (its ``&`` call operator)."""
    from hugmesh_studio.gui.pages import golive as gui_golive
    powershell = org_export._terminal_line(["x"]).startswith("& ")
    assert powershell == (os.name == "nt")
    assert ("PowerShell" in tui_golive.same_line_heading()) == powershell
    assert (gui_golive._shell_name() == "PowerShell") == powershell


def _org_export_page(golive):
    from hugmesh_studio.gui.pages import golive as gui_golive
    page = golive.page(golive._page_ids["org-export"])
    assert isinstance(page, gui_golive.GoLiveOrgExportPage)
    return page


@pytest.fixture
def golive(qapp, monkeypatch):
    from hugmesh_studio.gui.pages import golive as gui_golive
    monkeypatch.setattr(gui_golive.GoLiveDriver, "status_text", lambda self: "pinned")
    w = gui_golive.GoLiveWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def test_the_gui_row_is_labelled_for_this_hosts_shell(golive):
    page = _org_export_page(golive)
    if os.name == "nt":
        assert page.cmd.accessibleName() == "PowerShell"
        assert page.cmd.toolTip() == "The same export in PowerShell."
    else:
        assert page.cmd.accessibleName() == "Terminal"                # unchanged
        assert page.cmd.toolTip() == "The same export from a terminal."


def _tui_export_lines(world):
    from _org_export_helpers import saved_mesh_naming_the_org
    saved_mesh_naming_the_org(world)
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    screen = j.screen()
    screen.export_runner = world["runner"]
    screen.export_remote_base = f"file://{world['gh_root']}/"
    screen.stage = "plan"
    screen.opts.provider, screen.opts.domain = "byo-domain", "mesh.example"
    j.feed("x")
    assert screen.stage == "export", j.status
    return [ln.strip() for ln in j.lines()]


def test_the_tui_heading_sits_over_the_line(tmp_path):
    from _org_export_helpers import make_world
    lines = _tui_export_lines(make_world(tmp_path))
    if os.name == "nt":
        at = lines.index("The same in PowerShell:")
        assert lines[at + 1].startswith("& ")
        assert "The same from a terminal:" not in lines
    else:
        at = lines.index("The same from a terminal:")                  # unchanged
        assert not lines[at + 1].startswith("& ")
    assert "--org-export PLAN" in lines[at + 1]
