"""Read-only detection of USB/eMMC/SD-attached installable SBC targets, and the argv
builder that flashes a built artifact to one through ``scripts/flash-disk.sh``.

This module NEVER writes to a device and NEVER calls ``dd`` — detection is a pure
``lsblk``/sysfs read (no root, mirroring flash-disk.sh's "arg parse + --list work
without root" contract), and the actual flash is delegated whole to
``scripts/flash-disk.sh`` (typed-path confirm, child unmount, whole-disk refusal,
size-fit check, the real ``dd``). The GUI adds its OWN typed-path confirm before ever
passing ``--no-confirm`` (which only tells the script we already gated the destroy).

Detection (``list_targets``) filters ``lsblk`` output to whole disks that look like a
removable/USB/eMMC/SD installable target and are size-sane (1 GiB … ~256 GiB), and
EXCLUDES the disk backing ``/`` so the host system disk can never appear as a flash
target. A sysfs fallback covers hosts without ``lsblk -J``.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass

# size sanity: drop the tiny control-endpoint "disks" (the 32M Wacom tablet the host
# probe surfaces) and the multi-TB host NVMe. SBC install media (SD/eMMC/USB) live
# comfortably inside this window.
_MIN_SIZE = 1 << 30                    # 1 GiB
_MAX_SIZE = 256 * (1 << 30)           # ~256 GiB
_MMC_RE = re.compile(r"^mmcblk[0-9]+$")

# the exact lsblk field set verified present on the host (bytes sizes, JSON).
_LSBLK_ARGS = ["lsblk", "-J", "-b", "-o",
               "NAME,PATH,TRAN,RM,TYPE,SIZE,HOTPLUG,MODEL,VENDOR"]


@dataclass(frozen=True)
class FlashTarget:
    path: str
    size: int
    model: str
    transport: str
    removable: bool
    kind: str          # "mmc" | "usb" | "removable"

    def label(self) -> str:
        """A one-line human label for the dropdown: path, model/vendor, size, kind."""
        gib = self.size / (1 << 30)
        name = (self.model or "").strip() or "(unknown)"
        return f"{self.path} — {name} · {gib:.1f} GiB · {self.kind}"


# ── detection (read-only) ────────────────────────────────────────────────────────────
def _root_source() -> str:
    """The block device backing ``/`` (realpath-resolved), or "" if undeterminable.
    Read-only parse of /proc/mounts."""
    try:
        with open("/proc/mounts", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[1] == "/":
                    src = parts[0]
                    if src.startswith("/dev/"):
                        try:
                            return os.path.realpath(src)
                        except OSError:
                            return src
                    return src
    except OSError:
        pass
    return ""


def _node_is(dev: dict, root_src: str) -> bool:
    return dev.get("path") == root_src or f"/dev/{dev.get('name', '')}" == root_src


def _disk_contains(dev: dict, root_src: str) -> bool:
    """True if this lsblk disk node — or ANY descendant (partitions AND the mapper
    grandchildren under them: LVM/LUKS/mdraid/btrfs) — IS the root source device, i.e.
    the whole disk backing ``/`` that must be excluded. The recursion matters because on
    a mapper root ``_root_source`` realpath-resolves to ``/dev/dm-X``, which lsblk nests
    as a grandchild of the backing disk (disk → part → dm), not a direct child."""
    if not root_src:
        return False
    if _node_is(dev, root_src):
        return True
    for child in dev.get("children") or []:
        if _disk_contains(child, root_src):
            return True
    return False


def _kind(name: str, transport: str) -> str:
    if _MMC_RE.match(name or ""):
        return "mmc"
    if (transport or "").lower() == "usb":
        return "usb"
    return "removable"


def _accept(dev: dict) -> bool:
    """The installable-target filter: a whole DISK that is removable / hotplug / USB /
    an mmcblk SD-or-eMMC, and size-sane."""
    if dev.get("type") != "disk":
        return False
    name = dev.get("name") or ""
    transport = (dev.get("tran") or "")
    removable = bool(dev.get("rm"))
    hotplug = bool(dev.get("hotplug"))
    is_mmc = bool(_MMC_RE.match(name))
    if not (removable or hotplug or transport.lower() == "usb" or is_mmc):
        return False
    size = int(dev.get("size") or 0)
    return _MIN_SIZE <= size <= _MAX_SIZE


def _targets_from_lsblk_json(data: dict, root_src: str) -> list[FlashTarget]:
    out: list[FlashTarget] = []
    for dev in data.get("blockdevices") or []:
        if _disk_contains(dev, root_src):
            continue                      # never offer the system disk
        if not _accept(dev):
            continue
        name = dev.get("name") or ""
        transport = dev.get("tran") or ""
        out.append(FlashTarget(
            path=dev.get("path") or f"/dev/{name}",
            size=int(dev.get("size") or 0),
            model=(dev.get("model") or "").strip(),
            transport=transport,
            removable=bool(dev.get("rm")),
            kind=_kind(name, transport)))
    return out


def _targets_from_sysfs(root_src: str) -> list[FlashTarget]:
    """Fallback when ``lsblk -J`` is unavailable: read /sys/block/*/removable,
    /sys/block/*/size (512-byte sectors) and /sys/block/*/device/model. No writes."""
    out: list[FlashTarget] = []
    base = "/sys/block"
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out

    def _read(path: str) -> str:
        try:
            with open(path, encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    for name in names:
        removable = _read(os.path.join(base, name, "removable")) == "1"
        is_mmc = bool(_MMC_RE.match(name))
        is_usb = os.path.islink(os.path.join(base, name)) and (
            "usb" in os.path.realpath(os.path.join(base, name)))
        if not (removable or is_mmc or is_usb):
            continue
        try:
            sectors = int(_read(os.path.join(base, name, "size")) or "0")
        except ValueError:
            sectors = 0
        size = sectors * 512
        if not (_MIN_SIZE <= size <= _MAX_SIZE):
            continue
        path = f"/dev/{name}"
        if root_src and (path == root_src or os.path.realpath(path) == root_src):
            continue
        model = _read(os.path.join(base, name, "device", "model"))
        transport = "usb" if is_usb else ""
        out.append(FlashTarget(path=path, size=size, model=model, transport=transport,
                               removable=removable, kind=_kind(name, transport)))
    return out


def list_targets() -> list[FlashTarget]:
    """Read-only enumeration of installable flash targets (never the system disk).

    Shells ``lsblk -J -b`` (no root); on any failure falls back to a pure sysfs read.
    Returns [] on a host with nothing eligible attached — the safe default."""
    root_src = _root_source()
    try:
        r = subprocess.run(_LSBLK_ARGS, capture_output=True, text=True, timeout=8)
        if r.returncode == 0 and r.stdout.strip():
            return _targets_from_lsblk_json(json.loads(r.stdout), root_src)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return _targets_from_sysfs(root_src)


# ── argv builder (delegates the destructive write to flash-disk.sh) ──────────────────
_ARM64_PLATFORMS = ("rpi5", "orangepi5", "orangepizero2", "frite", "jetson")


def arch_for_platform(platform: str) -> str:
    """The flash-disk.sh ``--arch`` for a cfg.platform (arm64 for the SBC builders,
    x86 otherwise) — the arch selects the artifact naming the flasher auto-globs."""
    return "arm64" if (platform or "x86") in _ARM64_PLATFORMS else "x86"


def flash_script_path(generator_dir: str) -> str:
    return os.path.join(os.path.abspath(generator_dir), "scripts", "flash-disk.sh")


def flash_argv(target: FlashTarget, *, generator_dir: str, role: str, arch: str,
               artifact: str | None = None, work_dir: str | None = None,
               use_askpass: bool = True) -> list[str]:
    """Build the ``scripts/flash-disk.sh`` invocation that flashes ``target``.

    ``--no-confirm`` is passed ONLY because the GUI performs its own typed-path confirm
    before calling this (re-implementing dl_confirm_destroy's gate where the script has
    no tty). The script still does dl_require_root, unmount, whole-disk refusal and the
    size-fit check — we only ever invoke it, never re-implement dd. Root is obtained by
    the caller's launcher (pkexec/sudo -A/sudo); ``use_askpass`` adds ``sudo -A`` here
    for the copy-pasteable/no-tty case."""
    argv: list[str] = []
    argv += ["sudo", "-A"] if use_askpass else []
    argv += [flash_script_path(generator_dir), "--role", role, "--arch", arch]
    if artifact:
        argv += ["--artifact", artifact]
    if work_dir:
        argv += ["--work-dir", work_dir]
    argv += ["--no-confirm", target.path]
    return argv
