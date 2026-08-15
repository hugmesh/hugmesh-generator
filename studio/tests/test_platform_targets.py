"""Wayland + WSL2 support: session detection, WSL detection, and the flash gate.

OPERATOR DECISION, 2026-08-14: the Studio must run under Wayland on Linux AND on
Windows via WSL2, with everything in scope. WSL2 was chosen over a native Win32 port
precisely because it is a real Linux kernel — bash, make, docker, os.killpg and the
whole shell-out layer keep working unchanged, so there is ONE code path rather than two.

What does NOT come for free is the part these tests cover:

  * Under WAYLAND a client cannot position its own top-level windows. move() is
    accepted and silently discarded, so any code that "centres the window" or "puts the
    tooltip at the cursor" is a no-op that LOOKS correct in review and in an X11 test
    run. Detection is asserted here because it is what those call sites branch on.
  * Under WSL2 the flash-target scan still SUCCEEDS — lsblk and /proc/mounts describe
    the VM — so the failure mode is not an error, it is a plausible-looking list of the
    wrong disks. That is a destructive-write hazard, not a cosmetic one.

Everything is asserted through monkeypatched env / files rather than by running on the
target platform, because CI (and this workstation) is neither Wayland nor WSL: a test
that only passes where the bug cannot occur would prove nothing.
"""

from __future__ import annotations

import os

import pytest

from hugmesh_studio.core import platform_info
from hugmesh_studio.core.platform_info import (
    SESSION_NONE, SESSION_WAYLAND, SESSION_X11, HostInfo,
)

_SESSION_VARS = ("WAYLAND_DISPLAY", "DISPLAY", "XDG_SESSION_TYPE", "QT_QPA_PLATFORM")


@pytest.fixture
def clean_env(monkeypatch):
    """No display env at all — each test opts IN to exactly what it is asserting."""
    for var in _SESSION_VARS:
        monkeypatch.delenv(var, raising=False)
    return monkeypatch


def host(**kw) -> HostInfo:
    base = dict(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                has_kvm=False, is_root=False, builder_image="x")
    base.update(kw)
    return HostInfo(**base)


class TestSessionDetection:
    def test_wayland_socket_wins(self, clean_env):
        clean_env.setenv("WAYLAND_DISPLAY", "wayland-0")
        assert platform_info.detect_session() == SESSION_WAYLAND

    def test_bare_display_is_x11(self, clean_env):
        clean_env.setenv("DISPLAY", ":0")
        assert platform_info.detect_session() == SESSION_X11

    def test_xwayland_is_reported_as_x11_because_qt_is_an_x11_client_there(self, clean_env):
        """The case that would otherwise disable window placement for no reason.

        A Wayland compositor is running (WAYLAND_DISPLAY is set) but Qt was told to use
        xcb, so Qt IS an X11 client and move() works normally. Reporting 'wayland' here
        would make the wizard skip its centring on a session where centring is fine.
        """
        clean_env.setenv("WAYLAND_DISPLAY", "wayland-0")
        clean_env.setenv("DISPLAY", ":0")
        clean_env.setenv("QT_QPA_PLATFORM", "xcb")
        assert platform_info.detect_session() == SESSION_X11

    def test_sockets_beat_a_stale_declaration(self, clean_env):
        """XDG_SESSION_TYPE is routinely wrong (it says 'tty' under some display
        managers), so it must not override a socket that is demonstrably there."""
        clean_env.setenv("XDG_SESSION_TYPE", "tty")
        clean_env.setenv("WAYLAND_DISPLAY", "wayland-0")
        assert platform_info.detect_session() == SESSION_WAYLAND

    def test_declaration_is_the_fallback_when_no_socket_is_set(self, clean_env):
        clean_env.setenv("XDG_SESSION_TYPE", "wayland")
        assert platform_info.detect_session() == SESSION_WAYLAND

    def test_headless_is_none_not_a_guess(self, clean_env):
        assert platform_info.detect_session() == SESSION_NONE
        assert host(session=SESSION_NONE).has_gui is False

    def test_is_wayland_property_tracks_the_session(self):
        assert host(session=SESSION_WAYLAND).is_wayland is True
        assert host(session=SESSION_X11).is_wayland is False


class TestWslDetection:
    def _proc_version(self, monkeypatch, text: str):
        import builtins
        real_open = builtins.open

        def fake_open(path, *a, **kw):
            if str(path) == "/proc/version":
                from io import StringIO
                return StringIO(text)
            return real_open(path, *a, **kw)

        monkeypatch.setattr(builtins, "open", fake_open)

    def test_wsl2_kernel_is_detected_as_version_2(self, monkeypatch):
        monkeypatch.setattr(os, "name", "posix")
        self._proc_version(monkeypatch,
                           "Linux version 5.15.90.1-microsoft-standard-WSL2 (oe-user@oe-host)")
        assert platform_info.detect_wsl() == (True, 2)

    def test_wsl1_is_distinguished_from_wsl2(self, monkeypatch):
        """Not trivia: WSL1 cannot run the docker daemon or KVM, so a build that would
        work on WSL2 fails there for reasons no error message explains."""
        monkeypatch.setattr(os, "name", "posix")
        self._proc_version(monkeypatch, "Linux version 4.4.0-19041-Microsoft")
        assert platform_info.detect_wsl() == (True, 1)

    def test_a_normal_linux_kernel_is_not_wsl(self, monkeypatch):
        monkeypatch.setattr(os, "name", "posix")
        self._proc_version(monkeypatch, "Linux version 6.6.8-gentoo")
        assert platform_info.detect_wsl() == (False, 0)

    def test_missing_proc_version_is_not_wsl_rather_than_an_exception(self, monkeypatch):
        import builtins
        monkeypatch.setattr(os, "name", "posix")
        monkeypatch.setattr(builtins, "open",
                            lambda *a, **kw: (_ for _ in ()).throw(OSError("nope")))
        assert platform_info.detect_wsl() == (False, 0)


class TestFlashGate:
    """The destructive-write hazard. Under WSL2 lsblk SUCCEEDS and describes the VM."""

    def test_plain_linux_can_flash(self):
        assert host(os="linux").can_flash_devices is True
        assert host(os="linux").flash_blocker() == ""

    def test_wsl_without_usb_passthrough_cannot_flash(self, monkeypatch):
        monkeypatch.setattr(platform_info.HostInfo, "has_usb_passthrough",
                            property(lambda self: False))
        h = host(os="linux", is_wsl=True, wsl_version=2)
        assert h.can_flash_devices is False

    def test_wsl_blocker_names_usbipd_and_the_actual_commands(self, monkeypatch):
        """A bare 'unsupported' would send the operator round an unplug/replug loop that
        cannot succeed, so the message must carry the fix."""
        monkeypatch.setattr(platform_info.HostInfo, "has_usb_passthrough",
                            property(lambda self: False))
        msg = host(os="linux", is_wsl=True, wsl_version=2).flash_blocker()
        assert "usbipd" in msg
        assert "attach --wsl" in msg
        assert "bind --busid" in msg

    def test_wsl_WITH_an_attached_usb_device_can_flash(self, monkeypatch):
        monkeypatch.setattr(platform_info.HostInfo, "has_usb_passthrough",
                            property(lambda self: True))
        assert host(os="linux", is_wsl=True, wsl_version=2).can_flash_devices is True

    def test_non_linux_cannot_flash_and_is_told_to_use_wsl(self):
        h = host(os="windows")
        assert h.can_flash_devices is False
        assert "WSL2" in h.flash_blocker()

    def test_usb_backed_detection_reads_the_sysfs_link(self, monkeypatch):
        monkeypatch.setattr(os.path, "realpath",
                            lambda p: "/sys/devices/pci0000:00/usb1/1-2/block/sda")
        assert platform_info._is_usb_backed("sda") is True
        monkeypatch.setattr(os.path, "realpath",
                            lambda p: "/sys/devices/pci0000:00/nvme/block/nvme0n1")
        assert platform_info._is_usb_backed("nvme0n1") is False


class TestSummaryDisclosesTheEnvironment:
    def test_summary_names_wsl_and_session(self):
        s = host(os="linux", is_wsl=True, wsl_version=2, session=SESSION_WAYLAND).summary()
        assert "WSL2" in s and "wayland" in s

    def test_summary_omits_wsl_when_not_wsl(self):
        assert "WSL" not in host(os="linux", session=SESSION_X11).summary()
