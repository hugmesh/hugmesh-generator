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
# SBC identity hints (see FlashTarget.hint): the usb-gadget identity strings a Pi
# compute module in rpiboot mode / an Amlogic (Libre Computer) board in burn mode
# actually present as VENDOR/MODEL.
_RPIBOOT_RE = re.compile(r"raspberry|rpi[- ]?boot|bcm27[01][0-9]", re.IGNORECASE)
_AMLOGIC_RE = re.compile(r"amlogic|gx-?chip|libre\s*computer", re.IGNORECASE)

# the exact lsblk field set verified present on the host (bytes sizes, JSON).
# LABEL/MOUNTPOINT are universal `lsblk -o` fields — same single call, no extra
# subprocess — and feed the device table's Model/Label + mounted columns.
_LSBLK_ARGS = ["lsblk", "-J", "-b", "-o",
               "NAME,PATH,TRAN,RM,TYPE,SIZE,HOTPLUG,MODEL,VENDOR,LABEL,MOUNTPOINT"]


@dataclass(frozen=True)
class FlashTarget:
    path: str
    size: int
    model: str
    transport: str
    removable: bool
    kind: str          # "mmc" | "usb" | "removable"
    # trailing DEFAULTED fields: every pre-existing positional constructor call keeps
    # working, and the golden detection behavior is unchanged when they stay default.
    fs_label: str = ""                       # first non-empty child partition LABEL
    mountpoints: tuple[str, ...] = ()        # this disk's + descendants' MOUNTPOINTs
    vendor: str = ""                         # lsblk VENDOR / sysfs device/vendor

    @property
    def mounted(self) -> bool:
        return bool(self.mountpoints)

    def label(self) -> str:
        """A one-line human label for the dropdown: path, model/vendor, size, kind."""
        gib = self.size / (1 << 30)
        name = (self.model or "").strip() or "(unknown)"
        return f"{self.path} — {name} · {gib:.1f} GiB · {self.kind}"

    def hint(self) -> str:
        """A recognisable-SBC decoration for the device table, or "".

        Matched on the USB identity strings these devices actually present, not
        guessed from bus type: a Raspberry Pi CM in rpiboot/usbboot gadget mode
        enumerates with a BCM2708/2710/2711/2712 boot MODEL, and an Amlogic SBC
        (Libre Computer La Frite/Le Potato line) in burn/gadget mode presents an
        Amlogic/GX-CHIP identity. Purely a LABEL — detection/eligibility is
        unchanged, so an unrecognised adapter loses nothing."""
        probe = f"{self.vendor} {self.model}".lower()
        if _RPIBOOT_RE.search(probe):
            return "Raspberry Pi eMMC (rpiboot gadget)"
        if _AMLOGIC_RE.search(probe):
            return "Libre Computer / Amlogic eMMC (burn mode)"
        return ""


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


def _collect_label_mounts(dev: dict) -> tuple[str, tuple[str, ...]]:
    """Walk this disk node + ALL descendants (the same recursion shape as
    _disk_contains) collecting the first non-empty partition LABEL and every non-null
    MOUNTPOINT — read-only decoration for the device table's Label/Mounted columns."""
    label = ""
    mounts: list[str] = []

    def _walk(node: dict) -> None:
        nonlocal label
        if not label and (node.get("label") or "").strip():
            label = str(node.get("label")).strip()
        mp = node.get("mountpoint")
        if mp:
            mounts.append(str(mp))
        for child in node.get("children") or []:
            _walk(child)

    _walk(dev)
    return label, tuple(mounts)


def _targets_from_lsblk_json(data: dict, root_src: str) -> list[FlashTarget]:
    out: list[FlashTarget] = []
    for dev in data.get("blockdevices") or []:
        if _disk_contains(dev, root_src):
            continue                      # never offer the system disk
        if not _accept(dev):
            continue
        name = dev.get("name") or ""
        transport = dev.get("tran") or ""
        fs_label, mountpoints = _collect_label_mounts(dev)
        out.append(FlashTarget(
            path=dev.get("path") or f"/dev/{name}",
            size=int(dev.get("size") or 0),
            model=(dev.get("model") or "").strip(),
            transport=transport,
            removable=bool(dev.get("rm")),
            kind=_kind(name, transport),
            fs_label=fs_label,
            mountpoints=mountpoints,
            vendor=(dev.get("vendor") or "").strip()))
    return out


def _mounts_for_dev(name: str) -> tuple[str, ...]:
    """Mountpoints of /dev/<name> and its partitions from a read-only /proc/mounts
    prefix match (the sysfs-fallback twin of the lsblk MOUNTPOINT column)."""
    prefix = f"/dev/{name}"
    mounts: list[str] = []
    try:
        with open("/proc/mounts", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[0].startswith(prefix):
                    mounts.append(parts[1])
    except OSError:
        pass
    return tuple(mounts)


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
        vendor = _read(os.path.join(base, name, "device", "vendor"))
        transport = "usb" if is_usb else ""
        out.append(FlashTarget(path=path, size=size, model=model, transport=transport,
                               removable=removable, kind=_kind(name, transport),
                               mountpoints=_mounts_for_dev(name), vendor=vendor))
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

# flash-disk.sh accepts only these --role tokens; any client/desktop role maps to the
# generic 'host' artifact glob (same set as ProgressPage._FLASH_ROLES).
FLASH_ROLE_TOKENS = frozenset({"pki", "backend", "frontend", "host", "be", "fe", "omnibus"})


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


# ── artifact FLAVOURS (the install / live / img axis) ────────────────────────────────
# Classified by the EXACT suffixes the builders emit (evidence: each builder's _ARTS
# summary + artifact-path assignments):
#   x86:            <brand>-x86-amd64-<role>-<env>-<ts>.img / .live.iso / .installer.iso
#   frite/opi5/opz2:                       <prefix>.live.iso / .installer.iso  (no .img)
#   rpi5:           <prefix>.img (+ a plain .iso that carries NO flavour suffix)
#   jetson:         <prefix>.img
# x86 secure-boot re-signs emit "<name>.live-sb.iso" / "<name>.installer-sb.iso" — the
# (-sb)? alternation keeps them in their flavour class. A plain ".iso" classifies as ""
# (unflavoured): it is only reachable through the "auto" pick, never mis-sold as
# live/installer.
FLAVOR_AUTO = "auto"
_FLAVOR_RES: tuple[tuple[str, re.Pattern], ...] = (
    ("installer", re.compile(r"\.installer(-sb)?\.iso$", re.IGNORECASE)),
    ("live", re.compile(r"\.live(-sb)?\.iso$", re.IGNORECASE)),
    ("img", re.compile(r"\.img$", re.IGNORECASE)),
)
# what each platform's BUILDER can emit (same evidence) — the GUI offers only these,
# per the hide-inapplicable rule: a flavour the builder cannot produce would make the
# flash plan skip 100% of the time.
_PLATFORM_FLAVORS = {
    "x86": ("img", "live", "installer"),
    "rpi5": ("img",),
    "jetson": ("img",),
    "frite": ("live", "installer"),
    "orangepi5": ("live", "installer"),
    "orangepizero2": ("live", "installer"),
}
FLAVOR_LABELS = {
    FLAVOR_AUTO: "auto — newest built (.img preferred)",
    "img": "OS image (.img — boots as the installed system)",
    "live": "live USB (.live.iso)",
    "installer": "install USB (.installer.iso)",
}


def classify_artifact_flavor(name: str) -> str:
    """"installer" | "live" | "img" | "" for an artifact FILENAME (see table above)."""
    base = os.path.basename(name)
    for flavor, rx in _FLAVOR_RES:
        if rx.search(base):
            return flavor
    return ""


def flavors_for_platform(platform: str) -> tuple[str, ...]:
    """The flavour choices offered for a worklist entry's platform: always "auto",
    plus exactly what that platform's builder can emit."""
    return (FLAVOR_AUTO,) + _PLATFORM_FLAVORS.get(platform or "x86", ("img",))


@dataclass(frozen=True)
class FlashAssignment:
    """One row of the Review-page post-build flash plan: WHICH worklist image
    (entry_id) goes to WHICH attached device, plus the flash-disk.sh parameters
    (role token / arch / artifact work dir) resolved at commit time. Purely
    declarative — building the argv still delegates to flash_argv()/flash-disk.sh,
    and execution stays post-build on the ProgressPage behind its TOCTOU re-check.
    ``flavor`` (trailing default: pre-existing positional constructions unchanged)
    picks WHICH of the entry's artifacts is written — install/live/img — resolved
    against the entry's recorded artifact set at flash time (pick_artifact)."""
    target: FlashTarget
    entry_id: str
    role: str
    arch: str
    work_dir: str
    flavor: str = FLAVOR_AUTO


def assignment_argv(a: FlashAssignment, *, generator_dir: str,
                    artifact: str | None = None) -> list[str]:
    """The scripts/flash-disk.sh invocation for one plan assignment — a thin wrapper
    over the existing flash_argv() so no second (unaudited) write path can exist.

    ``artifact`` is the CONCRETE built image resolved for this assignment's entry
    (see :func:`new_artifact`). Passing it emits ``--artifact`` so the per-row image
    pick is honored EXACTLY: flash-disk.sh's newest-mtime ``*-<role>-*`` auto-glob
    cannot discriminate two worklist entries sharing a role token (be.rpi5 vs
    be.jetson are both ``--role be --arch arm64``; every client/desktop role folds
    to ``host``), so relying on the glob would flash the same newest artifact to
    differently-assigned devices."""
    return flash_argv(a.target, generator_dir=generator_dir, role=a.role, arch=a.arch,
                      artifact=artifact, work_dir=a.work_dir)


# ── per-entry artifact tracking (the flash plan's entry_id → built-image map) ─────────
# flashable extensions flash-disk.sh accepts, and the same kernel/initramfs/initrd/
# squashfs blob filter its list_candidates() applies (they share the .img extension).
_ARTIFACT_EXTS = (".img", ".iso")
_ARTIFACT_BLOB_RE = re.compile(r"(^|-)(kernel|initramfs|initrd|squashfs)", re.IGNORECASE)


def _is_flashable_artifact(name: str) -> bool:
    return (name.lower().endswith(_ARTIFACT_EXTS)
            and not _ARTIFACT_BLOB_RE.search(name))


def snapshot_artifacts(work_dir: str) -> dict[str, float]:
    """{filename: mtime} of the flashable artifacts (*.img/*.iso minus kernel/
    initramfs/squashfs blobs) currently in ``work_dir`` — the read-only baseline the
    ProgressPage takes when a worklist entry STARTS building, so the artifact that
    entry PRODUCED can be identified by diff when it finishes (the worklist runs
    entries sequentially, so the diff is unambiguous)."""
    out: dict[str, float] = {}
    try:
        names = os.listdir(work_dir)
    except OSError:
        return out
    for name in names:
        if not _is_flashable_artifact(name):
            continue
        try:
            out[name] = os.stat(os.path.join(work_dir, name)).st_mtime
        except OSError:
            continue
    return out


def new_artifacts(work_dir: str, baseline: dict[str, float]) -> tuple[str, ...]:
    """EVERY flashable artifact a just-finished entry build produced (NEW or
    REWRITTEN vs the entry-start ``baseline``), absolute paths, newest first.

    Plural on purpose: one x86 entry can legitimately produce .img + .live.iso +
    .installer.iso in a single run, and the per-device FLAVOUR pick needs the whole
    set — recording only the newest would make every non-default flavour
    unreachable."""
    fresh = snapshot_artifacts(work_dir)
    changed = sorted(
        ((name, mtime) for name, mtime in fresh.items()
         if baseline.get(name) != mtime),
        key=lambda c: c[1], reverse=True)
    return tuple(os.path.join(os.path.abspath(work_dir), name)
                 for name, _ in changed)


def pick_artifact(artifacts: tuple[str, ...] | list[str], flavor: str) -> str:
    """The artifact matching ``flavor`` out of an entry's recorded set, or "".

    "auto" keeps the established preference (newest .img, else newest anything) —
    byte-identical to the pre-flavour behaviour. A specific flavour returns ONLY a
    matching artifact: when the entry didn't produce one (e.g. the build ran
    ``--flavor live`` but the device asked for installer) the flash plan SKIPS with
    the reason instead of writing the wrong image."""
    arts = list(artifacts)
    if not arts:
        return ""
    if flavor in (FLAVOR_AUTO, "", None):
        imgs = [a for a in arts if a.lower().endswith(".img")]
        return (imgs or arts)[0]
    for a in arts:
        if classify_artifact_flavor(a) == flavor:
            return a
    return ""


def new_artifact(work_dir: str, baseline: dict[str, float]) -> str:
    """The single auto-picked artifact (newest .img else newest) — the pre-flavour
    contract, kept for existing callers/tests; == pick_artifact(new_artifacts(...),
    "auto")."""
    return pick_artifact(new_artifacts(work_dir, baseline), FLAVOR_AUTO)
