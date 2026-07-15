"""core.flash_targets — read-only detection of installable SBC flash targets and the
argv builder that delegates the destructive write to scripts/flash-disk.sh.

No device is ever written; lsblk is stubbed. Pins the filter (removable/USB/eMMC/SD +
size sanity), the system-disk exclusion (the disk backing '/'), the sysfs fallback, and
that flash_argv produces a SAFE flash-disk.sh invocation (never a raw dd).
"""
import json

from snapdragon_studio.core import flash_targets as ft
from snapdragon_studio.core.flash_targets import FlashTarget

GIB = 1 << 30

# Mirrors the real host probe (sda sata SSD, the 32M Wacom tablet on usb, the 2TB NVMe
# backing /) PLUS a 16G USB stick and a 16G eMMC that SHOULD be detected.
_HOST_LSBLK = {
    "blockdevices": [
        {"name": "sda", "path": "/dev/sda", "tran": "sata", "rm": False, "type": "disk",
         "size": 250059350016, "hotplug": False, "model": "Samsung SSD 860 ", "vendor": "ATA"},
        {"name": "sdc", "path": "/dev/sdc", "tran": "usb", "rm": True, "type": "disk",
         "size": 33554432, "hotplug": True, "model": "Intuos Pro M", "vendor": "Wacom"},
        {"name": "nvme0n1", "path": "/dev/nvme0n1", "tran": "nvme", "rm": False,
         "type": "disk", "size": 2000398934016, "hotplug": False, "model": "ADATA", "vendor": None,
         "children": [{"name": "nvme0n1p2", "path": "/dev/nvme0n1p2", "tran": None,
                       "rm": False, "type": "part", "size": 1_000_000_000, "hotplug": False}]},
        {"name": "sdb", "path": "/dev/sdb", "tran": "usb", "rm": True, "type": "disk",
         "size": 16 * GIB, "hotplug": True, "model": "Ultra USB 3.0", "vendor": "SanDisk"},
        {"name": "mmcblk0", "path": "/dev/mmcblk0", "tran": None, "rm": False, "type": "disk",
         "size": 16 * GIB, "hotplug": False, "model": "SD16G", "vendor": None},
    ]
}


class _FakeRun:
    def __init__(self, stdout, code=0):
        self.stdout = stdout
        self.returncode = code
        self.stderr = ""


def _stub_lsblk(monkeypatch, data):
    monkeypatch.setattr(ft.subprocess, "run",
                        lambda *a, **k: _FakeRun(json.dumps(data)))


def test_detects_usb_and_mmc_drops_tablet_and_nvme(monkeypatch):
    _stub_lsblk(monkeypatch, _HOST_LSBLK)
    monkeypatch.setattr(ft, "_root_source", lambda: "/dev/nvme0n1p2")   # / lives on the NVMe
    paths = {t.path for t in ft.list_targets()}
    assert paths == {"/dev/sdb", "/dev/mmcblk0"}       # the two real install targets
    # dropped: sda (non-removable sata), sdc (32M < 1GiB), nvme0n1 (2TB + backs /)


def test_kinds_and_size_window(monkeypatch):
    _stub_lsblk(monkeypatch, _HOST_LSBLK)
    monkeypatch.setattr(ft, "_root_source", lambda: "/dev/nvme0n1p2")
    by_path = {t.path: t for t in ft.list_targets()}
    assert by_path["/dev/mmcblk0"].kind == "mmc"
    assert by_path["/dev/sdb"].kind == "usb"
    assert all(GIB <= t.size <= 256 * GIB for t in by_path.values())


def test_system_disk_never_appears_even_if_removable(monkeypatch):
    """A removable USB disk that happens to back '/' must be excluded (defence for a
    USB-booted host)."""
    data = {"blockdevices": [
        {"name": "sdb", "path": "/dev/sdb", "tran": "usb", "rm": True, "type": "disk",
         "size": 16 * GIB, "hotplug": True, "model": "boot", "vendor": None,
         "children": [{"name": "sdb2", "path": "/dev/sdb2", "type": "part",
                       "rm": True, "size": 15 * GIB, "hotplug": True}]}]}
    _stub_lsblk(monkeypatch, data)
    monkeypatch.setattr(ft, "_root_source", lambda: "/dev/sdb2")
    assert ft.list_targets() == []


def test_system_disk_excluded_when_root_is_a_mapper_grandchild(monkeypatch):
    """LVM/LUKS/mdraid/btrfs root: _root_source realpath-resolves '/' to /dev/dm-X, which
    lsblk nests as a GRANDCHILD (disk -> part -> dm), not a direct child. The whole disk
    backing it must still be excluded — defence for a USB/eMMC-booted encrypted SBC."""
    data = {"blockdevices": [
        {"name": "mmcblk0", "path": "/dev/mmcblk0", "tran": None, "rm": False,
         "type": "disk", "size": 16 * GIB, "hotplug": False, "model": "boot", "vendor": None,
         "children": [{"name": "mmcblk0p2", "path": "/dev/mmcblk0p2", "type": "part",
                       "rm": False, "size": 15 * GIB, "hotplug": False,
                       "children": [{"name": "root", "path": "/dev/mapper/root",
                                     "type": "crypt", "rm": False, "size": 15 * GIB,
                                     "hotplug": False}]}]}]}
    _stub_lsblk(monkeypatch, data)
    monkeypatch.setattr(ft, "_root_source", lambda: "/dev/mapper/root")   # LUKS mapper root
    assert ft.list_targets() == []


def test_lsblk_failure_falls_back_to_sysfs(monkeypatch):
    def _boom(*a, **k):
        raise OSError("no lsblk")
    monkeypatch.setattr(ft.subprocess, "run", _boom)
    monkeypatch.setattr(ft, "_root_source", lambda: "")
    called = {}

    def _fake_sysfs(root_src):
        called["hit"] = root_src
        return [FlashTarget("/dev/sdb", 16 * GIB, "x", "usb", True, "usb")]
    monkeypatch.setattr(ft, "_targets_from_sysfs", _fake_sysfs)
    out = ft.list_targets()
    assert "hit" in called and [t.path for t in out] == ["/dev/sdb"]


# ── argv builder (delegates to flash-disk.sh; never a raw dd) ─────────────────────────
def test_flash_argv_is_safe_flash_disk_sh_call():
    t = FlashTarget("/dev/sdb", 16 * GIB, "SD", "usb", True, "usb")
    argv = ft.flash_argv(t, generator_dir="/gen", role="pki", arch="arm64",
                         work_dir="/gen/out", use_askpass=False)
    assert argv[0].endswith("scripts/flash-disk.sh")
    assert argv[-1] == "/dev/sdb"                  # target device is the final positional
    assert "--no-confirm" in argv                  # GUI already did its own typed-path gate
    assert ("--role", "pki") == (argv[1], argv[2])
    assert "--arch" in argv and "arm64" in argv
    assert "--work-dir" in argv and "/gen/out" in argv
    assert "dd" not in argv                         # never re-implemented here


def test_flash_argv_askpass_and_artifact():
    t = FlashTarget("/dev/mmcblk0", 16 * GIB, "SD", "", False, "mmc")
    argv = ft.flash_argv(t, generator_dir="/gen", role="host", arch="x86",
                         artifact="/gen/out/img.img")
    assert argv[:2] == ["sudo", "-A"]              # askpass launcher for the no-tty case
    assert "--artifact" in argv and "/gen/out/img.img" in argv


def test_arch_for_platform():
    assert ft.arch_for_platform("rpi5") == "arm64"
    assert ft.arch_for_platform("orangepi5") == "arm64"
    assert ft.arch_for_platform("x86") == "x86"
    assert ft.arch_for_platform("") == "x86"
