"""core.flash_targets — read-only detection of installable SBC flash targets and the
argv builder that delegates the destructive write to scripts/flash-disk.sh.

No device is ever written; lsblk is stubbed. Pins the filter (removable/USB/eMMC/SD +
size sanity), the system-disk exclusion (the disk backing '/'), the sysfs fallback, and
that flash_argv produces a SAFE flash-disk.sh invocation (never a raw dd).

Also (#337) the flash path AFTER a real build: the compressed artifacts a --compress
build actually leaves, the session workdir the build actually writes into, and the ONE
OK/Cancel warning that now gates every write.
"""
import json
import os
import shutil
import subprocess

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

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
    (be.rpi5 + be.jetson are both --role backend --arch arm64) would otherwise emit
    byte-identical argvs and flash-disk.sh's newest-mtime role glob would write the
    SAME image to both devices. The resolved per-entry artifact rides --artifact."""
    t1 = FlashTarget("/dev/sdb", 16 * GIB, "SanDisk Ultra", "usb", True, "usb")
    t2 = FlashTarget("/dev/sdc", 32 * GIB, "Cruzer", "usb", True, "usb")
    a1 = ft.FlashAssignment(target=t1, entry_id="backend.rpi5", role="backend", arch="arm64",
                            work_dir="/gen/out")
    a2 = ft.FlashAssignment(target=t2, entry_id="backend.jetson", role="backend", arch="arm64",
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


# ═══════════════════════════════════════════════════════════════════════════════════
# #337 — the flash path after a real build: compressed artifacts, the session workdir,
# and the ONE OK/Cancel warning. Every assertion below is grounded in the artifact set
# the operator's 2026-09-08 standalone run actually left on disk:
#
#   out/sessions/20260907-190340-70b501/
#     gentoo-x86-amd64-standalone-thick-prod-20260908T095149Z.img.xz        <- the OS image
#     gentoo-x86-amd64-standalone-thick-prod-20260908T095149Z.installer.iso
#     gentoo-x86-amd64-standalone-thick-prod-20260908T095149Z.live.iso
#
# The .img is COMPRESSED because --compress defaults ON (core/config.py ImageConfig.
# compress = True) and the x86/rpi5/jetson builders compress IMG_PATH. Nothing here
# writes a device: the flasher worker is replaced and every target is a fake /dev path.
# ═══════════════════════════════════════════════════════════════════════════════════
_REAL = "gentoo-x86-amd64-standalone-thick-prod-20260908T095149Z"


def test_the_default_builds_compressed_image_is_a_flashable_artifact():
    """`--compress` is ON by default, so <name>.img.xz IS the image a finished build
    leaves. Scoring it "not an artifact" is what emptied the flash plan (#337)."""
    assert ft._is_flashable_artifact(f"{_REAL}.img.xz") is True
    assert ft._is_flashable_artifact(f"{_REAL}.installer.iso.xz") is True
    assert ft._is_flashable_artifact(f"{_REAL}.live.iso.xz") is True
    # and the blob filter is untouched: a compressed kernel blob is still not an image
    assert ft._is_flashable_artifact("hugmesh-rpi5-kernel.img.xz") is False
    assert ft._is_flashable_artifact("hugmesh-rpi5-initramfs.img.xz") is False


def test_compressed_artifacts_keep_their_flavour():
    """.img.xz is an "img", not an unflavoured blob — otherwise the per-device flavour
    pick skips 100% of the time on a default build."""
    assert ft.classify_artifact_flavor(f"{_REAL}.img.xz") == "img"
    assert ft.classify_artifact_flavor(f"{_REAL}.installer.iso.xz") == "installer"
    assert ft.classify_artifact_flavor(f"{_REAL}.live.iso.xz") == "live"
    assert ft.classify_artifact_flavor(f"{_REAL}.live-sb.iso.xz") == "live"
    # uncompressed classification is unchanged
    assert ft.classify_artifact_flavor(f"{_REAL}.img") == "img"
    assert ft.classify_artifact_flavor("acme-rpi5-arm64-be-x.iso") == ""


def test_is_compressed_artifact_names_only_the_xz_shapes():
    assert ft.is_compressed_artifact(f"/w/{_REAL}.img.xz") is True
    assert ft.is_compressed_artifact(f"/w/{_REAL}.live.iso.xz") is True
    assert ft.is_compressed_artifact(f"/w/{_REAL}.img") is False
    assert ft.is_compressed_artifact(f"/w/{_REAL}.installer.iso") is False
    # the stage4/fs tarballs a build also drops are NOT images
    assert ft.is_compressed_artifact(f"/w/{_REAL}.stage4.tar.xz") is False


def test_auto_pick_prefers_the_compressed_img_over_an_iso(tmp_path):
    """THE standalone shape: one .img.xz + two .iso. "auto" means "newest .img else
    newest anything", and the compressed .img IS the img — the old endswith('.img')
    test scored it as not-an-image and handed back the installer ISO instead."""
    _touch(tmp_path / f"{_REAL}.img.xz", 1000)          # oldest on purpose
    _touch(tmp_path / f"{_REAL}.installer.iso", 2000)
    _touch(tmp_path / f"{_REAL}.live.iso", 3000)        # newest overall
    arts = ft.new_artifacts(str(tmp_path), {})
    assert ft.pick_artifact(arts, ft.FLAVOR_AUTO) == str(tmp_path / f"{_REAL}.img.xz")
    assert ft.pick_artifact(arts, "img") == str(tmp_path / f"{_REAL}.img.xz")
    assert ft.pick_artifact(arts, "live") == str(tmp_path / f"{_REAL}.live.iso")


# ── the NODE image shape (never exercised by the operator — #337 predicted it) ────────
@pytest.mark.parametrize("platform,arch,role,stem", [
    # arm64 node roles: rpi5 builds pki/backend/frontend, jetson omnibus/edge-ai.
    ("rpi5", "arm64", "pki", "hugmesh-rpi5-arm64-pki-prod-20260908T101500Z"),
    ("rpi5", "arm64", "backend", "hugmesh-rpi5-arm64-backend-prod-20260908T101500Z"),
    ("jetson", "arm64", "omnibus", "hugmesh-jetson-arm64-omnibus-prod-20260908T101500Z"),
    # x86 node roles land in the same shape (an x86 node's --compress also hits IMG_PATH).
    ("x86", "x86", "pki", "hugmesh-x86-amd64-pki-prod-20260908T101500Z"),
    ("x86", "x86", "backend-gpu", "hugmesh-x86-amd64-backend-gpu-prod-20260908T101500Z"),
])
def test_node_image_only_produces_a_compressed_img_and_is_still_flashable(
        tmp_path, platform, arch, role, stem):
    """A NODE build emits exactly ONE artifact, the .img — and with --compress on
    (the default) that file is <stem>.img.xz. Before the fix the per-entry snapshot
    saw an EMPTY work dir, so `new_artifacts` returned () and the flash plan refused
    "no artifact was recorded" for every Pi/Jetson/x86 node image ever built."""
    _touch(tmp_path / f"{stem}.img.xz", 2000)
    snap = ft.snapshot_artifacts(str(tmp_path))
    assert set(snap) == {f"{stem}.img.xz"}              # the ONE artifact is seen
    arts = ft.new_artifacts(str(tmp_path), {})
    assert arts == (str(tmp_path / f"{stem}.img.xz"),)
    # both the "auto" default and an explicit img pick resolve it
    assert ft.pick_artifact(arts, ft.FLAVOR_AUTO) == str(tmp_path / f"{stem}.img.xz")
    assert ft.pick_artifact(arts, "img") == str(tmp_path / f"{stem}.img.xz")
    assert ft.arch_for_platform(platform) == arch
    # and the fallback resolver finds it by the same two anchors flash-disk.sh uses
    assert ft.find_artifacts(str(tmp_path), role=role, arch=arch) == \
        (str(tmp_path / f"{stem}.img.xz"),)


def test_node_image_flavour_menu_offers_only_what_the_builder_emits():
    """Hide-inapplicable still holds for the node platforms: rpi5/jetson build an
    .img and nothing else, so a live/installer pick is never offered for them."""
    assert ft.flavors_for_platform("rpi5") == (ft.FLAVOR_AUTO, "img")
    assert ft.flavors_for_platform("jetson") == (ft.FLAVOR_AUTO, "img")
    assert ft.flavors_for_platform("x86") == (ft.FLAVOR_AUTO, "img", "live", "installer")


# ── find_artifacts: the fallback resolver (read-only, anchored, never a silent write) ─
def test_find_artifacts_anchors_on_arch_and_role(tmp_path):
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-prod-1.img.xz", 1000)
    _touch(tmp_path / "hugmesh-x86-amd64-pki-prod-2.img", 2000)        # wrong arch
    _touch(tmp_path / "hugmesh-rpi5-arm64-backend-prod-3.img", 3000)   # wrong role
    got = ft.find_artifacts(str(tmp_path), role="pki", arch="arm64")
    assert got == (str(tmp_path / "hugmesh-rpi5-arm64-pki-prod-1.img.xz"),)
    # amd64 is the same arch token as x86, exactly as flash-disk.sh's ARCH_GLOBS has it
    assert ft.find_artifacts(str(tmp_path), role="pki", arch="x86") == \
        (str(tmp_path / "hugmesh-x86-amd64-pki-prod-2.img"),)


def test_find_artifacts_matches_an_older_role_spelling(tmp_path):
    """Images already on disk keep the spelling they were built under; the resolver
    covers every alias of the canonical role, like flash-disk.sh's ROLE_GLOBS."""
    _touch(tmp_path / "hugmesh-x86-amd64-be-test-1.img", 1000)         # 'be' = backend
    assert ft.find_artifacts(str(tmp_path), role="backend", arch="x86") == \
        (str(tmp_path / "hugmesh-x86-amd64-be-test-1.img"),)


def test_find_artifacts_is_newest_first_and_drops_blobs(tmp_path):
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-old-1.img", 1000)
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-new-2.img.xz", 5000)
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-kernel.img", 9000)       # blob, filtered
    got = ft.find_artifacts(str(tmp_path), role="pki", arch="arm64")
    assert [os.path.basename(g) for g in got] == [
        "hugmesh-rpi5-arm64-pki-new-2.img.xz", "hugmesh-rpi5-arm64-pki-old-1.img"]


def test_find_artifacts_empty_on_a_miss_and_on_a_missing_dir(tmp_path):
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-1.img", 1000)
    assert ft.find_artifacts(str(tmp_path), role="omnibus", arch="arm64") == ()
    assert ft.find_artifacts(str(tmp_path / "nope"), role="pki", arch="arm64") == ()


# ── scripts/flash-disk.sh: the same two shapes, at the script boundary ────────────────
# --list is the script's no-root dry run: it resolves the artifact and prints what it
# WOULD flash without touching a device. No /dev path is ever passed here.
_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_FLASH_SH = os.path.join(_REPO, "scripts", "flash-disk.sh")


def _flash_list(work_dir, role, arch):
    r = subprocess.run(["bash", _FLASH_SH, "--role", role, "--arch", arch,
                        "--work-dir", str(work_dir), "--list"],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return r.stdout


@pytest.mark.skipif(not os.path.exists(_FLASH_SH), reason="flash-disk.sh not present")
def test_flash_disk_sh_resolves_a_compressed_node_image(tmp_path):
    """The node prediction in #337, at the script: a Pi build with --compress on leaves
    ONLY <name>.img.xz, and the flasher used to answer "no arm64 pki .img/.iso"."""
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-prod-20260908T101500Z.img.xz", 2000)
    out = _flash_list(tmp_path, "pki", "arm64")
    assert "Would flash:" in out
    assert out.strip().endswith("hugmesh-rpi5-arm64-pki-prod-20260908T101500Z.img.xz")


@pytest.mark.skipif(not os.path.exists(_FLASH_SH), reason="flash-disk.sh not present")
def test_flash_disk_sh_prefers_the_compressed_img_over_an_iso(tmp_path):
    """The standalone shape end to end: .img.xz + .installer.iso + .live.iso in one
    session dir must resolve to the IMAGE, not to an ISO that happens to be newer."""
    _touch(tmp_path / f"{_REAL}.img.xz", 1000)
    _touch(tmp_path / f"{_REAL}.installer.iso", 2000)
    _touch(tmp_path / f"{_REAL}.live.iso", 3000)
    out = _flash_list(tmp_path, "standalone-thick", "x86")
    assert out.strip().endswith(f"{_REAL}.img.xz")


@pytest.mark.skipif(not os.path.exists(_FLASH_SH), reason="flash-disk.sh not present")
def test_flash_disk_sh_still_drops_compressed_kernel_blobs(tmp_path):
    """A compressed kernel/initramfs blob shares the .img.xz extension and must not
    become a flash candidate — the same filter the uncompressed names get."""
    _touch(tmp_path / "hugmesh-rpi5-arm64-pki-kernel.img.xz", 9000)
    out = _flash_list(tmp_path, "pki", "arm64")
    assert "no artifact found" in out


@pytest.mark.skipif(not os.path.exists(_FLASH_SH), reason="flash-disk.sh not present")
def test_flash_disk_sh_no_longer_refuses_an_explicit_compressed_artifact(tmp_path):
    """`--artifact <name>.img.xz` used to die on "artifact must be .img or .iso"
    BEFORE any device work. It must now get past the extension check — here it stops
    at the root requirement, which is the next gate and proves the refusal is gone."""
    art = tmp_path / "hugmesh-rpi5-arm64-pki-prod-1.img.xz"
    _touch(art, 1000)
    r = subprocess.run(["bash", _FLASH_SH, "--role", "pki", "--arch", "arm64",
                        "--artifact", str(art), "/dev/does-not-exist-337"],
                       capture_output=True, text=True, timeout=60)
    combined = r.stdout + r.stderr
    assert "artifact must be" not in combined
    assert "run as root" in combined            # reached the destructive-path gate


# ── the ProgressPage flash hook: session workdir + the ONE OK/Cancel warning ──────────
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                       # noqa: E402
from hugmesh_studio.gui.pages import progress as pg                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402


@pytest.fixture
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


class _Lines:
    def __init__(self):
        self.lines = []

    def appendPlainText(self, s):
        self.lines.append(s)

    def toPlainText(self):
        return "\n".join(self.lines)


FAKE = FlashTarget("/dev/sdz-test-337", 32 * GIB, "FAKE Test Stick", "usb", True, "usb")


def _page(monkeypatch, *, session_workdir="", output_dir="", sets=None, queue=(),
          answer=None, launched=None):
    """A ProgressPage minus Qt construction, driven through the REAL unbound methods.

    The flasher WORKER is replaced, so an accepted confirmation records an argv and
    launches nothing — no subprocess, no sudo, no device."""
    page = pg.ProgressPage.__new__(pg.ProgressPage)
    page.log = _Lines()
    page.flash_worker = None
    page._flash_queue = list(queue)
    page._entry_artifact_sets = dict(sets or {})
    page._entry_artifacts = {}
    page._flash_caveats = []
    page._flash_cancelled = False
    page._session = (SimpleNamespace(workdir=session_workdir)
                     if session_workdir else None)
    page.wiz = SimpleNamespace(generator_dir=_REPO,
                               cfg=SimpleNamespace(output_dir=output_dir))
    page.flash_btn = SimpleNamespace(setEnabled=lambda *_: None)
    page.flash_refresh_btn = SimpleNamespace(setEnabled=lambda *_: None)
    monkeypatch.setattr(ft, "list_targets", lambda: [FAKE])

    class _NoWorker:
        line = SimpleNamespace(connect=lambda *_: None)
        done = SimpleNamespace(connect=lambda *_: None)

        def __init__(self, argv, gen):
            if launched is not None:
                launched.append(list(argv))

        def start(self):
            pass

        def isRunning(self):
            return False
    monkeypatch.setattr(pg, "_FlashWorker", _NoWorker)
    monkeypatch.setattr(pg, "hold_thread", lambda w: w)
    if answer is not None:
        monkeypatch.setattr(pg, "confirm_flash",
                            lambda *a, **k: answer)
    return page


def test_work_dir_is_the_session_dir_the_build_actually_writes_into(monkeypatch,
                                                                    tmp_path):
    """THE #337 root cause. The page hands the driver workdir=<out>/sessions/<id>/ at
    dispatch, so that is where every artifact lands — but _work_dir() returned the
    shared <out>. The per-entry snapshot therefore diffed a directory the build never
    touched, new_artifacts() returned (), and every plan assignment refused with "no
    artifact was recorded"."""
    session = tmp_path / "out" / "sessions" / "20260907-190340-70b501"
    session.mkdir(parents=True)
    page = _page(monkeypatch, session_workdir=str(session),
                 output_dir=str(tmp_path / "out"))
    assert pg.ProgressPage._work_dir(page) == str(session)
    # no session (direct-slot tests / a record that could not be written): unchanged
    page._session = None
    assert pg.ProgressPage._work_dir(page) == str(tmp_path / "out")


def test_the_snapshot_diff_sees_the_build_output_once_work_dir_is_right(monkeypatch,
                                                                        tmp_path):
    """Non-vacuous pin of the same fix: with the session dir in play, the entry-start
    baseline and the entry-done diff both see the file the build wrote."""
    session = tmp_path / "out" / "sessions" / "s1"
    session.mkdir(parents=True)
    (tmp_path / "out" / "hugmesh-x86-amd64-pki-stale-1.img").write_text("old")
    page = _page(monkeypatch, session_workdir=str(session),
                 output_dir=str(tmp_path / "out"))
    baseline = ft.snapshot_artifacts(pg.ProgressPage._work_dir(page))
    assert baseline == {}                       # the session dir starts empty
    _touch(session / f"{_REAL}.img.xz", 5000)   # the build writes its image
    assert ft.new_artifacts(pg.ProgressPage._work_dir(page), baseline) == \
        (str(session / f"{_REAL}.img.xz"),)


def test_the_flash_warning_is_a_module_level_seam(qapp):
    """The gate must be monkeypatchable by name, or the suite can only test it by
    stubbing _start_flash — which tests nothing. It is also the ONE call site: the
    dialog lives in _start_flash and nowhere near validatePage/initializePage/
    isComplete/itemChanged, where a modal deadlocks an offscreen run."""
    assert callable(pg.confirm_flash)
    src = open(pg.__file__, encoding="utf-8").read()
    assert src.count("confirm_flash(") == 1          # exactly one call site
    body = src[src.index("def _start_flash"):]
    assert "confirm_flash(" in body[:body.index("\n    def _flash_done")]
    for hook in ("def validatePage", "def initializePage", "def isComplete"):
        if hook in src:
            seg = src[src.index(hook):]
            seg = seg[:seg.index("\n    def ", 1)] if "\n    def " in seg[1:] else seg
            assert "confirm_flash" not in seg and "QMessageBox" not in seg


def test_ok_flashes_and_the_warning_names_the_device_and_the_image(monkeypatch, qapp,
                                                                   tmp_path):
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    art = session / f"{_REAL}.img.xz"
    _touch(art, 5000)
    seen = {}

    def _confirm(parent, title, text, buttons, default):
        seen.update(title=title, text=text, buttons=buttons, default=default)
        return pg.FLASH_OK
    monkeypatch.setattr(pg, "confirm_flash", _confirm)
    launched = []
    a = ft.FlashAssignment(FAKE, "standalone.x86", "standalone-thick", "x86",
                           str(session))
    page = _page(monkeypatch, session_workdir=str(session), queue=[a],
                 sets={"standalone.x86": (str(art),)}, launched=launched)
    pg.ProgressPage._flash_next(page)
    assert len(launched) == 1                                  # the flash was launched
    assert str(art) in launched[0] and "--artifact" in launched[0]
    assert "dd" not in launched[0]                             # still delegated whole
    # the dialog says what is destroyed, what is written, and that it is compressed
    assert FAKE.path in seen["text"] and "ERASES" in seen["text"]
    assert os.path.basename(str(art)) in seen["text"]
    assert "compressed" in seen["text"]
    assert seen["default"] == pg.FLASH_CANCEL                  # Cancel is the default
    assert seen["buttons"] == pg.FLASH_OK | pg.FLASH_CANCEL    # exactly OK / Cancel


def test_cancel_writes_nothing(monkeypatch, qapp, tmp_path):
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    art = session / f"{_REAL}.img.xz"
    _touch(art, 5000)
    launched = []
    a = ft.FlashAssignment(FAKE, "standalone.x86", "standalone-thick", "x86",
                           str(session))
    page = _page(monkeypatch, session_workdir=str(session), queue=[a],
                 sets={"standalone.x86": (str(art),)}, answer=pg.FLASH_CANCEL,
                 launched=launched)
    pg.ProgressPage._flash_next(page)
    assert launched == []                                      # nothing started
    assert "Flash cancelled" in page.log.toPlainText()
    assert FAKE.path in page.log.toPlainText()


def test_cancelling_one_device_still_offers_the_next(monkeypatch, qapp, tmp_path):
    """Cancel means "not THIS device", not "abandon the plan": a two-device plan whose
    first row is declined must still reach the second."""
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    art = session / f"{_REAL}.img.xz"
    _touch(art, 5000)
    other = FlashTarget("/dev/sdy-test-337", 16 * GIB, "Second Stick", "usb", True, "usb")
    asked = []

    def _confirm(parent, title, text, buttons, default):
        asked.append(text)
        return pg.FLASH_CANCEL if len(asked) == 1 else pg.FLASH_OK
    monkeypatch.setattr(pg, "confirm_flash", _confirm)
    launched = []
    queue = [ft.FlashAssignment(FAKE, "e1", "standalone-thick", "x86", str(session)),
             ft.FlashAssignment(other, "e1", "standalone-thick", "x86", str(session))]
    page = _page(monkeypatch, session_workdir=str(session), queue=queue,
                 sets={"e1": (str(art),)}, launched=launched)
    monkeypatch.setattr(ft, "list_targets", lambda: [FAKE, other])
    pg.ProgressPage._flash_next(page)
    assert len(asked) == 2                                     # both were offered
    assert len(launched) == 1                                  # only the accepted one
    assert other.path in launched[0]


def test_nothing_recorded_falls_back_to_the_work_dir_and_says_so(monkeypatch, qapp,
                                                                 tmp_path):
    """The #337 dead end, replaced. A run that recorded no artifact for the entry used
    to refuse outright; now the image sitting in the work dir is resolved, and the
    warning states EXACTLY how it was matched so the operator can decline."""
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    art = session / f"{_REAL}.img.xz"
    _touch(art, 5000)
    seen = {}

    def _confirm(parent, title, text, buttons, default):
        seen["text"] = text
        return pg.FLASH_OK
    monkeypatch.setattr(pg, "confirm_flash", _confirm)
    launched = []
    a = ft.FlashAssignment(FAKE, "standalone.x86", "standalone-thick", "x86",
                           str(tmp_path / "out"))     # the stale BuildPage work_dir
    page = _page(monkeypatch, session_workdir=str(session), queue=[a], sets={},
                 launched=launched)
    pg.ProgressPage._flash_next(page)
    assert len(launched) == 1
    assert str(art) in launched[0]
    # the argv's --work-dir was corrected to the session dir too
    assert launched[0][launched[0].index("--work-dir") + 1] == str(session)
    assert "recorded no image" in seen["text"]
    assert "arch (x86)" in seen["text"] and "role (standalone-thick)" in seen["text"]


def test_the_fallback_never_overrides_a_recorded_set_missing_the_flavour(monkeypatch,
                                                                         qapp,
                                                                         tmp_path):
    """A run that DID record artifacts, none of them the requested flavour, still
    skips with the reason — the fallback is only for an EMPTY record, never a way to
    write an image the build is known not to have produced.

    This pins the GATE, not just the outcome: the requested flavour is 'img' and a
    MATCHING .img.xz is sitting in the work dir, so find_artifacts()+pick_artifact()
    WOULD return it. The only thing standing between that file and a whole-disk dd is
    `and not self._entry_artifact_sets.get(a.entry_id)`. Drop that clause and this
    test fails with an argv naming an image the run never recorded.

    (An earlier form of this test asked for 'installer' with no installer on disk, so
    the fallback returned "" either way and the test passed with the gate removed —
    it named the gate without pinning it.)"""
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    stray = session / f"{_REAL}.img.xz"
    _touch(stray, 5000)          # a MATCHING img is on disk, findable by arch+role
    live = session / f"{_REAL}.live.iso"
    _touch(live, 4000)           # ...but the run recorded only the live ISO
    launched = []
    a = ft.FlashAssignment(FAKE, "e1", "standalone-thick", "x86", str(session),
                           flavor="img")
    page = _page(monkeypatch, session_workdir=str(session), queue=[a],
                 sets={"e1": (str(live),)}, answer=pg.FLASH_OK, launched=launched)
    pg.ProgressPage._flash_next(page)
    assert launched == [], f"the fallback wrote an UNRECORDED image: {launched}"
    assert str(stray) not in "\n".join(" ".join(x) for x in launched)
    assert "no 'img' artifact" in page.log.toPlainText()
    assert os.path.basename(str(live)) in page.log.toPlainText()   # says what it DID build


def test_the_fallback_is_skipped_when_the_recorded_set_lacks_an_installer(monkeypatch,
                                                                          qapp,
                                                                          tmp_path):
    """The same gate for the flavour the operator actually picks on the node path —
    kept from the original test so both flavours stay covered."""
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    live = session / f"{_REAL}.live.iso"
    _touch(live, 4000)
    launched = []
    a = ft.FlashAssignment(FAKE, "e1", "standalone-thick", "x86", str(session),
                           flavor="installer")
    page = _page(monkeypatch, session_workdir=str(session), queue=[a],
                 sets={"e1": (str(live),)}, answer=pg.FLASH_OK, launched=launched)
    pg.ProgressPage._flash_next(page)
    assert launched == []
    assert "no 'installer' artifact" in page.log.toPlainText()


def test_a_truly_empty_work_dir_still_skips_with_the_reason(monkeypatch, qapp,
                                                            tmp_path):
    """Fail-safe kept: nothing recorded AND nothing findable is still a skip, never a
    guess and never an empty confirmation."""
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    launched = []
    a = ft.FlashAssignment(FAKE, "e1", "pki", "arm64", str(session))
    page = _page(monkeypatch, session_workdir=str(session), queue=[a], sets={},
                 answer=pg.FLASH_OK, launched=launched)
    pg.ProgressPage._flash_next(page)
    assert launched == []
    assert "no artifact was recorded" in page.log.toPlainText()


# ── the three gaps a skeptic's mutation battery found on this branch ──────────────────
# Each of these was written against a MUTANT first: the production change was reverted /
# broken, the test was confirmed FAILING, and only then was production restored.

def _uncompressed_size_expr():
    """The real ART_SIZE-for-a-compressed-artifact block, lifted OUT of flash-disk.sh.

    Extracted rather than retyped so the test cannot drift from the script: delete the
    block (or change the awk field index) and this returns the wrong number or raises."""
    with open(_FLASH_SH, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    start = next(i for i, l in enumerate(lines)
                 if "xz --robot --list" in l and "ART_SIZE=" in l)
    end = next(i for i, l in enumerate(lines[start:], start)
               if "ART_SIZE" in l and "|| ART_SIZE=0" in l)
    snippet = "\n".join(lines[start:end + 1])
    assert "totals" in snippet, "the uncompressed-size block lost its awk selector"
    return snippet


@pytest.mark.skipif(not os.path.exists(_FLASH_SH), reason="flash-disk.sh not present")
def test_the_fit_check_measures_the_UNCOMPRESSED_size_of_an_xz_artifact(tmp_path):
    """The size that must fit on the stick is the size that gets WRITTEN.

    The operator's real artifact is 3.0 G as a file and 51 GiB decompressed. Comparing
    the FILE size against the device passes a 32 GiB stick and dd discovers the truth
    mid-write, after the operator has already authenticated. `xz --robot --list` reports
    the true size; field 5 of the `totals` row is the fragile part and is exactly what
    this pins. Root-free: only the size arithmetic is exercised, never a device."""
    if not shutil.which("xz"):
        pytest.skip("xz not installed")
    raw = tmp_path / "img"
    payload = b"\0" * 1_000_003            # incompressible-size, highly compressible
    raw.write_bytes(payload)
    subprocess.run(["xz", "-1", str(raw)], check=True, timeout=120)
    art = tmp_path / "img.xz"
    assert art.exists()
    assert art.stat().st_size < len(payload) / 10      # the file really is much smaller

    r = subprocess.run(
        ["bash", "-euo", "pipefail", "-c",
         f'ARTIFACT="{art}"\n{_uncompressed_size_expr()}\nprintf %s "${{ART_SIZE}}"'],
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr
    assert r.stdout == str(len(payload)), (
        f"the fit check would compare {r.stdout} bytes, not the {len(payload)} that "
        f"actually get written")


@pytest.mark.skipif(not os.path.exists(_FLASH_SH), reason="flash-disk.sh not present")
def test_an_unreadable_xz_skips_the_fit_check_instead_of_dying(tmp_path):
    """Fail-OPEN is the pre-existing contract for the fit check (a stat failure has
    always yielded 0, which skips the comparison). Keep it: a truncated or non-xz file
    must not abort the run before the script's own real gates get to speak."""
    if not shutil.which("xz"):
        pytest.skip("xz not installed")
    art = tmp_path / "not-really.img.xz"
    art.write_bytes(b"this is not an xz stream")
    r = subprocess.run(
        ["bash", "-euo", "pipefail", "-c",
         f'ARTIFACT="{art}"\n{_uncompressed_size_expr()}\nprintf %s "${{ART_SIZE}}"'],
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr
    assert r.stdout == "0"


def test_the_post_build_auto_flash_is_gated_by_the_same_one_warning(monkeypatch, qapp,
                                                                    tmp_path):
    """MAJOR from the refutation: _maybe_auto_flash reaches a modal from a NON-click
    path (the BuildPage checkbox, ticked hours earlier). #337 asks for the warning "at
    the moment the flash is started", so it stays — but it must be THE seam, so a
    headless run can never block. Cancel here must write nothing."""
    session = tmp_path / "sessions" / "s1"
    session.mkdir(parents=True)
    art = session / f"{_REAL}.img.xz"
    _touch(art, 5000)
    launched = []
    page = _page(monkeypatch, session_workdir=str(session), sets={},
                 answer=pg.FLASH_CANCEL, launched=launched)
    page.wiz.cfg.role = "standalone-thick"
    page.wiz.cfg.platform = "x86"
    page.wiz.flash_plan = None
    page.wiz.flash_after = (True, FAKE)
    asked = []
    monkeypatch.setattr(pg, "confirm_flash",
                        lambda *a, **k: (asked.append(a), pg.FLASH_CANCEL)[1])
    pg.ProgressPage._maybe_auto_flash(page)
    assert asked, "the opted-in auto flash wrote without asking"
    assert launched == [], "Cancel on the auto path still launched a flasher"
    assert "cancelled" in page.log.toPlainText().lower()


def test_a_declined_flash_leaves_no_caveat_on_the_next_devices_warning(monkeypatch,
                                                                      qapp, tmp_path):
    """A caveat ("matched by arch+role only") belongs to ONE assignment. _start_flash
    early-returns while a worker is still running, and it used to do so BEFORE clearing
    the caveats — so a 3s wait timeout carried one device's warning text onto the next
    device's dialog, which is the one place in this lane where wrong text is dangerous."""
    page = _page(monkeypatch, session_workdir=str(tmp_path), sets={})
    page._flash_caveats = ["matched by arch and role only — check the name"]

    class _Busy:
        def isRunning(self):
            return True
    page.flash_worker = _Busy()
    pg.ProgressPage._start_flash(page, FAKE)
    assert page._flash_caveats == []
