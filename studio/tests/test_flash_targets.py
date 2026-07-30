"""core.flash_targets — read-only detection of installable SBC flash targets and the
argv builder that delegates the destructive write to scripts/flash-disk.sh.

No device is ever written; lsblk is stubbed. Pins the filter (removable/USB/eMMC/SD +
size sanity), the system-disk exclusion (the disk backing '/'), the sysfs fallback, and
that flash_argv produces a SAFE flash-disk.sh invocation (never a raw dd).
"""
import json
import os

from hugmesh_studio.core import flash_targets as ft
from hugmesh_studio.core.flash_targets import FlashTarget

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
    # regression pin: the boardless appliances must flash arm64 artifacts, never
    # fall through to the x86 default (orangepizero3 did exactly that once).
    assert ft.arch_for_platform("orangepizero2") == "arm64"
    assert ft.arch_for_platform("orangepizero2w") == "arm64"
    assert ft.arch_for_platform("orangepizero3") == "arm64"
    assert ft.arch_for_platform("orangepi3-lts") == "arm64"
    assert ft.arch_for_platform("x86") == "x86"
    assert ft.arch_for_platform("") == "x86"


# ── label / mountpoint decoration (the device-table columns) ──────────────────────────
def test_label_and_mountpoints_collected_from_children(monkeypatch):
    """LABEL/MOUNTPOINT ride the SAME single lsblk call: the first non-empty child
    partition LABEL and every descendant MOUNTPOINT decorate the target (read-only)."""
    data = {"blockdevices": [
        {"name": "sdb", "path": "/dev/sdb", "tran": "usb", "rm": True, "type": "disk",
         "size": 16 * GIB, "hotplug": True, "model": "Ultra USB 3.0", "vendor": "SanDisk",
         "label": None, "mountpoint": None,
         "children": [
             {"name": "sdb1", "path": "/dev/sdb1", "type": "part", "rm": True,
              "size": 15 * GIB, "hotplug": True, "label": "KEYS",
              "mountpoint": "/run/media/magus/KEYS"}]},
        {"name": "mmcblk0", "path": "/dev/mmcblk0", "tran": None, "rm": False,
         "type": "disk", "size": 16 * GIB, "hotplug": False, "model": "SD16G",
         "vendor": None, "label": None, "mountpoint": None},
    ]}
    _stub_lsblk(monkeypatch, data)
    monkeypatch.setattr(ft, "_root_source", lambda: "/dev/nvme0n1p2")
    by_path = {t.path: t for t in ft.list_targets()}
    sdb = by_path["/dev/sdb"]
    assert sdb.fs_label == "KEYS"
    assert sdb.mountpoints == ("/run/media/magus/KEYS",)
    assert sdb.mounted is True
    mmc = by_path["/dev/mmcblk0"]
    assert mmc.fs_label == "" and mmc.mountpoints == () and mmc.mounted is False


def test_flashtarget_trailing_fields_are_defaulted_positional_compat():
    """The frozen dataclass grew ONLY trailing defaulted fields: every pre-existing
    positional constructor call keeps working and yields the same detection shape."""
    t = FlashTarget("/dev/sdb", 16 * GIB, "SD", "usb", True, "usb")
    assert t.fs_label == "" and t.mountpoints == () and t.mounted is False


# ── FlashAssignment / assignment_argv (the Review-page per-device plan) ───────────────
def test_assignment_argv_is_safe_flash_disk_sh_call():
    """assignment_argv delegates whole to the existing flash_argv — the script path is
    the argv head (after the askpass launcher) and 'dd' never appears: no second write
    path exists."""
    t = FlashTarget("/dev/sdb", 16 * GIB, "SanDisk Ultra", "usb", True, "usb")
    a = ft.FlashAssignment(target=t, entry_id="pki.rpi5", role="pki", arch="arm64",
                           work_dir="/gen/out")
    argv = ft.assignment_argv(a, generator_dir="/gen")
    assert argv[:2] == ["sudo", "-A"]              # askpass launcher (no-tty case)
    assert argv[2].endswith("scripts/flash-disk.sh")
    assert argv[-1] == "/dev/sdb"                  # target device is the final positional
    assert ("--role", "pki") == (argv[3], argv[4])
    assert "--arch" in argv and "arm64" in argv
    assert "--work-dir" in argv and "/gen/out" in argv
    assert "dd" not in argv                        # never re-implemented here


def test_assignment_argv_passes_the_concrete_artifact():
    """The per-row image pick must be REAL: two assignments sharing a role token
    (be.rpi5 + be.jetson are both --role be --arch arm64) would otherwise emit
    byte-identical argvs and flash-disk.sh's newest-mtime role glob would write the
    SAME image to both devices. The resolved per-entry artifact rides --artifact."""
    t1 = FlashTarget("/dev/sdb", 16 * GIB, "SanDisk Ultra", "usb", True, "usb")
    t2 = FlashTarget("/dev/sdc", 32 * GIB, "Cruzer", "usb", True, "usb")
    a1 = ft.FlashAssignment(target=t1, entry_id="be.rpi5", role="be", arch="arm64",
                            work_dir="/gen/out")
    a2 = ft.FlashAssignment(target=t2, entry_id="be.jetson", role="be", arch="arm64",
                            work_dir="/gen/out")
    v1 = ft.assignment_argv(a1, generator_dir="/gen",
                            artifact="/gen/out/hugmesh-rpi5-arm64-backend-x.img")
    v2 = ft.assignment_argv(a2, generator_dir="/gen",
                            artifact="/gen/out/hugmesh-jetson-arm64-backend-y.img")
    assert v1 != v2                                # non-vacuous: the pick changes the argv
    assert ("--artifact", "/gen/out/hugmesh-rpi5-arm64-backend-x.img") in \
        zip(v1, v1[1:])
    assert ("--artifact", "/gen/out/hugmesh-jetson-arm64-backend-y.img") in \
        zip(v2, v2[1:])
    assert "dd" not in v1 and "dd" not in v2


# ── per-entry artifact tracking (snapshot diff around each sequential build) ──────────
def _touch(path, mtime=None):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("x")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def test_snapshot_and_new_artifact_pick_the_entrys_own_image(tmp_path):
    """new_artifact returns exactly the image the entry's build ADDED (or rewrote)
    since its start baseline — never a pre-existing same-role image, never a
    kernel/initramfs/squashfs blob that shares the .img extension."""
    old = tmp_path / "hugmesh-rpi5-arm64-backend-old.img"
    _touch(old, 1000)
    base = ft.snapshot_artifacts(str(tmp_path))
    assert set(base) == {"hugmesh-rpi5-arm64-backend-old.img"}
    # the entry's build produces a NEW same-role image + a kernel blob
    _touch(tmp_path / "hugmesh-jetson-arm64-backend-new.img", 2000)
    _touch(tmp_path / "hugmesh-jetson-kernel.img", 3000)   # filtered blob
    got = ft.new_artifact(str(tmp_path), base)
    assert got == str(tmp_path / "hugmesh-jetson-arm64-backend-new.img")


def test_new_artifact_detects_a_rewritten_image_and_prefers_img_over_iso(tmp_path):
    img = tmp_path / "hugmesh-rpi5-arm64-be-x.img"
    _touch(img, 1000)
    base = ft.snapshot_artifacts(str(tmp_path))
    _touch(img, 5000)                                          # rebuilt in place
    _touch(tmp_path / "gentoo-rpi5-arm64-be-k8s-x.iso", 6000)  # newer iso also produced
    assert ft.new_artifact(str(tmp_path), base) == str(img)    # .img preferred


def test_new_artifact_empty_when_nothing_new_is_the_fail_safe(tmp_path):
    _touch(tmp_path / "hugmesh-rpi5-arm64-be-x.img", 1000)
    base = ft.snapshot_artifacts(str(tmp_path))
    assert ft.new_artifact(str(tmp_path), base) == ""          # skip, never glob-guess
    assert ft.new_artifact(str(tmp_path / "missing"), {}) == ""
