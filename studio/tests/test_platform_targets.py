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


# ══════════════════════════════════════════════════════════════════════════════════
# THE THREE WSL FAILURES THAT DO NOT ANNOUNCE THEMSELVES
#
# Each of the classes below covers a failure whose defining property is that the
# operator gets NO message naming its cause: a build that merely stops progressing, a
# connection error that mentions neither Docker Desktop nor WSL, and an absent /dev/kvm
# that QEMU quietly papers over by emulating everything. All three are asserted through
# a monkeypatched mount table / env / probe, because this workstation is not WSL — a
# test that only passes where the bug cannot occur would prove nothing.
# ══════════════════════════════════════════════════════════════════════════════════


def write_mounts(tmp_path, *rows: tuple[str, str]) -> str:
    """A fake /proc/mounts with (mountpoint, fstype) rows, in kernel format."""
    p = tmp_path / "mounts"
    p.write_text("".join(f"dev{i} {mp} {fs} rw,relatime 0 0\n"
                         for i, (mp, fs) in enumerate(rows)), encoding="utf-8")
    return str(p)


class TestMountTableReading:
    """The lookup the /mnt/c warning is decided on. Wrong here = warning on the wrong
    directory, which is worse than silence: it would send an operator whose repo is
    already on the fast disk off to re-clone it."""

    def test_longest_prefix_wins_over_the_root_mount(self, tmp_path):
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        assert platform_info.mount_for("/mnt/c/Users/me/repo", m) == ("/mnt/c", "9p")
        assert platform_info.mount_for("/home/me/repo", m) == ("/", "ext4")

    def test_the_prefix_is_whole_components_so_mnt_c_never_claims_mnt_cache(self, tmp_path):
        """/mnt/cache starts with the STRING '/mnt/c' while being an ordinary directory
        on the root filesystem. A naive startswith reports it as a Windows drive and
        demands a re-clone that would fix nothing — so the match is on components."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        assert platform_info.mount_for("/mnt/cache/repo", m) == ("/", "ext4")
        assert host(is_wsl=True, wsl_version=2).slow_filesystem_warning(
            "/mnt/cache/repo", m) == ""

    def test_the_mountpoint_itself_matches_not_only_paths_below_it(self, tmp_path):
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        assert platform_info.mount_for("/mnt/c", m) == ("/mnt/c", "9p")

    def test_octal_escapes_in_mountpoints_are_decoded(self, tmp_path):
        """/proc/mounts writes a space as \\040 — and 'C:\\Program Files' style paths
        under /mnt are exactly where that shows up."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/my\\040drive", "9p"))
        assert platform_info.mount_for("/mnt/my drive/repo", m) == ("/mnt/my drive", "9p")

    def test_an_unreadable_mount_table_reports_nothing_rather_than_guessing(self, tmp_path):
        assert platform_info.read_mounts(str(tmp_path / "absent")) == []
        assert platform_info.mount_for("/anywhere", str(tmp_path / "absent")) == ("", "")


class TestWindowsDriveTrap:
    """The /mnt/c performance trap — the highest-cost WSL2 mistake, and silent."""

    def test_a_repo_on_a_9p_windows_drive_is_flagged(self, tmp_path):
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        w = host(is_wsl=True, wsl_version=2).slow_filesystem_warning("/mnt/c/Users/me/gen", m)
        assert w != ""

    def test_the_warning_names_the_symptom_and_the_actual_fix(self, tmp_path):
        """It must say HANG, because that is the word the operator would otherwise use
        to describe it, and it must say where to put the repo instead. A warning that
        only says '9p is slow' leaves them with nothing to do."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        w = host(is_wsl=True, wsl_version=2).slow_filesystem_warning("/mnt/c/Users/me/gen", m)
        assert "HANG" in w
        assert "git clone" in w and "~/Github" in w
        assert "10-20x" in w

    @pytest.mark.parametrize("fstype", ["9p", "drvfs", "virtiofs"])
    def test_every_name_wsl_has_used_for_a_windows_drive_is_the_same_trap(self, tmp_path, fstype):
        """WSL has reported Windows drives as drvfs, 9p and virtiofs across versions.
        Covering only the one this month's build uses would let the trap back in."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", fstype))
        assert host(is_wsl=True, wsl_version=2).slow_filesystem_warning("/mnt/c/gen", m) != ""

    def test_a_repo_on_the_wsl_disk_says_nothing(self, tmp_path):
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        assert host(is_wsl=True, wsl_version=2).slow_filesystem_warning("/home/me/gen", m) == ""

    def test_the_PATH_alone_does_not_decide_it(self, tmp_path):
        """THE rule this feature is built on. A real Linux disk mounted at /mnt/c is
        fast, and warning about it would be a lie that costs the operator a re-clone.
        The filesystem TYPE is the evidence; the path is not."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "ext4"))
        assert host(is_wsl=True, wsl_version=2).slow_filesystem_warning("/mnt/c/gen", m) == ""

    def test_a_symlink_into_a_windows_drive_is_still_caught(self, tmp_path):
        """The other half of the same rule, in the other direction: ~/Github/gen can be
        a symlink onto /mnt/c and is then exactly as slow, while LOOKING like the fast
        path the operator was told to use."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/mnt/c", "9p"))
        link = tmp_path / "looks-native"
        os.symlink("/mnt/c/Users/me/gen", link)
        assert host(is_wsl=True, wsl_version=2).slow_filesystem_warning(str(link), m) != ""

    def test_no_mount_table_falls_back_to_the_path_shape_under_wsl(self, tmp_path):
        """Secondary evidence only, and only when the primary evidence is unavailable:
        staying silent because /proc could not be read would drop the warning in exactly
        the degraded environment most likely to need it."""
        gone = str(tmp_path / "absent")
        h = host(is_wsl=True, wsl_version=2)
        assert h.slow_filesystem_warning("/mnt/c/Users/me/gen", gone) != ""
        assert h.slow_filesystem_warning("/home/me/gen", gone) == ""

    def test_a_virtiofs_repo_outside_wsl_is_not_called_a_windows_drive(self, tmp_path):
        """virtiofs is an ordinary, fast, LOCAL passthrough on a normal Linux VM. The
        Windows-drive reading of it is WSL-specific and must stay that way."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/srv", "virtiofs"))
        assert host(is_wsl=False).slow_filesystem_warning("/srv/gen", m) == ""

    def test_a_network_filesystem_is_warned_about_on_any_host(self, tmp_path):
        """Same failure (per-file round trips), same symptom, different remedy — and it
        is not a WSL problem, so it is not gated on WSL."""
        m = write_mounts(tmp_path, ("/", "ext4"), ("/net", "nfs4"))
        w = host(is_wsl=False).slow_filesystem_warning("/net/gen", m)
        assert "HANG" in w and "network filesystem" in w
        assert "git clone" not in w          # the /mnt/c remedy would be wrong here


class TestDockerRemedyUnderWsl:
    """Docker Desktop keeps the daemon on the WINDOWS side and shares it per distro.
    With the share off, `docker info` fails with a socket error that names neither."""

    def test_wsl2_remedy_names_the_integration_setting_and_this_distro(self):
        r = platform_info.wsl_docker_remedy(True, 2, "Ubuntu-24.04")
        assert "WSL Integration" in r and "Resources" in r
        assert "Ubuntu-24.04" in r           # the exact checkbox, not "your distro"

    def test_wsl1_is_told_to_convert_rather_than_to_flip_a_checkbox(self):
        """WSL1 cannot run the daemon at all, so the integration advice would send the
        operator to a setting that cannot help them."""
        r = platform_info.wsl_docker_remedy(True, 1, "legacy")
        assert "set-version" in r and "WSL1" in r

    def test_not_wsl_returns_nothing_so_the_generic_advice_stands(self):
        assert platform_info.wsl_docker_remedy(False, 0, "") == ""

    def test_it_probes_the_environment_when_called_with_no_arguments(self, monkeypatch):
        """Callers with no HostInfo to hand (qemu_tests.docker_available) rely on this."""
        monkeypatch.setattr(platform_info, "detect_wsl", lambda: (True, 2))
        monkeypatch.setenv("WSL_DISTRO_NAME", "Debian")
        assert "Debian" in platform_info.wsl_docker_remedy()
        monkeypatch.setattr(platform_info, "detect_wsl", lambda: (False, 0))
        assert platform_info.wsl_docker_remedy() == ""

    def test_host_remedy_on_plain_linux_is_the_service_and_group_advice(self):
        r = host(has_docker=False, is_wsl=False).docker_remedy()
        assert "docker" in r and "group" in r
        assert "WSL Integration" not in r

    def test_a_reachable_daemon_has_no_remedy_at_all(self):
        assert host(has_docker=True).docker_remedy() == ""
        assert host(has_docker=True).docker_blocker() == ""

    def test_the_blocker_is_self_contained_for_surfaces_that_show_it_alone(self):
        b = host(has_docker=False, is_wsl=True, wsl_version=2, wsl_distro="Ubuntu").docker_blocker()
        assert "not reachable" in b and "WSL Integration" in b


class TestKvmGate:
    """Nested virtualisation. QEMU does not fail without it — it emulates, and an x86
    row goes from minutes to hours, which is indistinguishable from a hang."""

    def test_wsl2_blocker_carries_the_wslconfig_stanza_and_the_shutdown(self):
        b = host(has_kvm=False, is_wsl=True, wsl_version=2).kvm_blocker()
        assert "nestedVirtualization=true" in b
        assert ".wslconfig" in b
        assert "wsl --shutdown" in b         # without this the setting is not read

    def test_wsl1_is_told_to_convert_instead(self):
        b = host(has_kvm=False, is_wsl=True, wsl_version=1, wsl_distro="legacy").kvm_blocker()
        assert "set-version" in b and "nestedVirtualization" not in b

    def test_a_present_but_unreadable_kvm_node_is_a_group_problem_not_a_wsl_one(self):
        """Different cause, different fix. Telling someone whose /dev/kvm exists to edit
        .wslconfig sends them to change a setting that is already correct."""
        b = host(has_kvm=False, is_wsl=True, wsl_version=2,
                 kvm_present_but_denied=True).kvm_blocker()
        assert "usermod -aG kvm" in b
        assert "nestedVirtualization" not in b

    def test_plain_linux_gets_modprobe_and_firmware_advice(self):
        b = host(has_kvm=False, is_wsl=False).kvm_blocker()
        assert "modprobe" in b and "irmware" in b
        assert "wslconfig" not in b

    def test_working_kvm_says_nothing(self):
        assert host(has_kvm=True, is_wsl=True, wsl_version=2).kvm_blocker() == ""

    def test_the_wording_is_slow_not_impossible_because_tcg_still_works(self):
        """The runner degrades to TCG on its own, so this is a WARNING. Wording it as a
        blocker would be a second lie in the other direction."""
        b = host(has_kvm=False, is_wsl=True, wsl_version=2).kvm_blocker()
        assert "emulation" in b.lower()
        assert "aarch64" in b.lower()        # Pi rows are unaffected — say so

    def test_kvm_needs_read_AND_write_not_mere_existence(self, monkeypatch):
        """What the harness itself tests (`[ -r /dev/kvm ] && [ -w /dev/kvm ]`). A node
        the operator cannot open is not acceleration, however present it is."""
        monkeypatch.setattr(os.path, "exists", lambda p: p == "/dev/kvm")
        monkeypatch.setattr(os, "access", lambda p, mode: False)
        assert platform_info._kvm_state() == (False, True)
        monkeypatch.setattr(os, "access", lambda p, mode: True)
        assert platform_info._kvm_state() == (True, False)
        monkeypatch.setattr(os.path, "exists", lambda p: False)
        assert platform_info._kvm_state() == (False, False)


class TestTheWarningsActuallyReachTheOperator:
    """Detection that nothing renders is worth nothing. These pin the WIRING: the three
    remedies above have to arrive on a surface the operator is already looking at."""

    def _driver(self, tmp_path, h):
        from hugmesh_studio.core.build_driver import BuildDriver
        return BuildDriver(str(tmp_path), h)

    def _cfg(self, tmp_path):
        from hugmesh_studio.core.config import ImageConfig
        return ImageConfig(mode="mesh", role="omnibus", platform="x86",
                           output_dir=str(tmp_path / "out"))

    def _pin_mounts(self, monkeypatch, tmp_path, fstype):
        """Report the generator dir itself as a mount of ``fstype``, whatever path the
        driver passes — read_mounts is the seam both mount_for callers go through."""
        here = os.path.realpath(str(tmp_path))
        monkeypatch.setattr(platform_info, "read_mounts",
                            lambda _p=None: [("/", "ext4"), (here, fstype)])

    def test_build_preflight_warnings_carry_the_slow_filesystem_warning(
            self, tmp_path, monkeypatch):
        """The Review page and the Progress log both render preflight_warnings(), so
        this is where 'the build hung' gets explained BEFORE it happens."""
        self._pin_mounts(monkeypatch, tmp_path, "9p")
        d = self._driver(tmp_path, host(is_wsl=True, wsl_version=2))
        warns = d.preflight_warnings(self._cfg(tmp_path), "docker")
        assert any("SLOW FILESYSTEM" in w for w in warns)
        assert any("git clone" in w for w in warns)

    def test_a_repo_on_the_linux_disk_adds_no_warning(self, tmp_path, monkeypatch):
        self._pin_mounts(monkeypatch, tmp_path, "ext4")
        d = self._driver(tmp_path, host(is_wsl=True, wsl_version=2))
        warns = d.preflight_warnings(self._cfg(tmp_path), "docker")
        assert not [w for w in warns if "SLOW FILESYSTEM" in w]

    def test_the_docker_preflight_PROBLEM_carries_the_wsl_remedy(self, tmp_path, monkeypatch):
        """Blocking channel. The bare 'daemon is not reachable' is true and useless on
        WSL: there is no daemon in the distro to start and no group to join."""
        self._pin_mounts(monkeypatch, tmp_path, "ext4")
        h = host(has_docker=False, is_wsl=True, wsl_version=2, wsl_distro="Ubuntu-24.04")
        problems = self._driver(tmp_path, h).preflight(self._cfg(tmp_path), "docker")
        joined = "\n".join(problems)
        assert "daemon is not reachable" in joined      # the diagnosis is kept
        assert "WSL Integration" in joined              # …and now carries the cure
        assert "Ubuntu-24.04" in joined

    def test_qemu_docker_probe_replaces_the_group_advice_with_the_wsl_one(self, monkeypatch):
        """'is your user in the docker group?' is not merely unhelpful under WSL, it is
        wrong — it describes a daemon that is not supposed to be running in the distro."""
        import subprocess as sp

        from hugmesh_studio.core import qemu_tests
        monkeypatch.setattr(platform_info, "detect_wsl", lambda: (True, 2))
        monkeypatch.setenv("WSL_DISTRO_NAME", "Ubuntu-24.04")
        monkeypatch.setattr(qemu_tests.subprocess, "run",
                            lambda *a, **k: sp.CompletedProcess(a[0], 1, None, "conn refused"))
        ok, why = qemu_tests.docker_available()
        assert ok is False
        assert "WSL Integration" in why
        # the generic sentence is REPLACED, not merely appended to: "is it running, and
        # is your user in the 'docker' group?" describes a distro-local daemon that does
        # not exist here. (The remedy's own parenthetical does mention the group — for
        # the operator who deliberately installed docker INSIDE the distro.)
        assert "is it running, and is" not in why

    def test_qemu_docker_probe_keeps_the_generic_advice_off_wsl(self, monkeypatch):
        import subprocess as sp

        from hugmesh_studio.core import qemu_tests
        monkeypatch.setattr(platform_info, "detect_wsl", lambda: (False, 0))
        monkeypatch.setattr(qemu_tests.subprocess, "run",
                            lambda *a, **k: sp.CompletedProcess(a[0], 1, None, "conn refused"))
        ok, why = qemu_tests.docker_available()
        assert ok is False and "'docker' group" in why and "WSL Integration" not in why
