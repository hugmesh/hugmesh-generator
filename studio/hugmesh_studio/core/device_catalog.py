"""Device catalog — the arch → family → device taxonomy (Qt-free accessor layer).

``device-catalog.json`` (beside this module, the ``progress-tables.json`` precedent)
lists every device the Studio knows about: the currently-buildable boards, the
plausibly-buildable ones (EXPERIMENTAL — an existing builder + upstream support covers
them, labelled + fail-loud), and the named-but-unbuildable ones (UNSUPPORTED — visible
so the answer is honest, never selectable, reason shown). The #351 honesty rule is
structural here:

* the JSON stores **no role lists** — :func:`roles_for` DERIVES a device's roles at
  runtime from the same ``ROLE_CHOICES`` + ``rpi_boards_for_role()`` predicates the
  RolePage/WorklistPage/emit-image-catalog channels already consume, so a catalog role
  can only ever be one the builders really accept. A device's optional ``role_allow``
  may only NARROW that derivation (the x86 chromebook device), never add to it.
* a device IS a ``(platform, board)`` pair — :func:`config_axes` returns exactly the
  two cfg fields today's machine card + per-platform board combo produce, so selecting
  a device changes nothing about emission (byte-identity by construction).
* the drift guards in ``studio/tests/test_device_catalog.py`` pin the catalog to
  config.py's constants AND to the six builders' own role/board allowlists in three
  directions — mutating any side fails.

Qt-free by construction: imported by the GUI pages, the headless catalog emitter
(scripts/emit-image-catalog.py) and the pure-core test suite.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field

from .config import ROLE_CHOICES, rpi_boards_for_role

CATALOG_PATH = os.path.join(os.path.dirname(__file__), "device-catalog.json")
SCHEMA = "device-catalog/v1"
#: The ``--list-devices --json`` document: rows as every channel labels them, not the
#: catalog file's own shape (that is ``SCHEMA``, carried alongside as ``catalog``).
LIST_SCHEMA = "device-list/v1"

# status vocabulary (the #351 honesty buckets). SELECTABLE_STATUSES gates the GUI:
# an unsupported device is visible but never selectable for a build.
STATUSES = ("supported", "experimental", "unsupported")
SELECTABLE_STATUSES = ("supported", "experimental")

# Platforms whose builder has NO --board flag (the device's board axis is ""):
# x86 targets any UEFI machine; the zero2 builder is a single-board platform.
BOARDLESS_PLATFORMS = ("x86", "orangepizero2", "orangepizero2w", "orangepizero3",
                       "orangepi3-lts", "orangepi4-lts")

# The standing caveat every EXPERIMENTAL badge/tooltip carries (mirrors the
# PLATFORM_LABELS tag text + the fail-loud-preflight convention from #351).
EXPERIMENTAL_CAVEAT = "EXPERIMENTAL — hardware validation pending; fail-loud preflight"


@dataclass(frozen=True)
class Arch:
    id: str
    label: str


@dataclass(frozen=True)
class Family:
    id: str
    label: str
    vendor: str
    arch: str


@dataclass(frozen=True)
class Device:
    id: str
    label: str
    family: str
    arch: str
    soc: str
    builder_platform: str | None   # None iff status == "unsupported"
    builder_board: str             # "" where the platform has no --board axis
    status: str
    reason: str                    # non-empty for every non-supported entry
    role_allow: tuple[str, ...] | None   # NARROWING allowlist (may only shrink)
    notes: str
    ram_mb: int | None = None      # device RAM ceiling (MiB) for the QEMU-e2e runtime
                                   # load envelope; None where the board ships in several
                                   # RAM SKUs (no single ceiling to assert)


@dataclass(frozen=True)
class DeviceCatalog:
    archs: tuple[Arch, ...]
    families: tuple[Family, ...]
    devices: tuple[Device, ...]
    _by_id: dict = field(default_factory=dict, repr=False)

    def __post_init__(self):
        self._by_id.update({d.id: d for d in self.devices})

    # ---- lookups -------------------------------------------------------------
    def device(self, device_id: str) -> Device:
        return self._by_id[device_id]

    def family(self, family_id: str) -> Family:
        return next(f for f in self.families if f.id == family_id)

    def devices_in_family(self, family_id: str) -> tuple[Device, ...]:
        return tuple(d for d in self.devices if d.family == family_id)

    def devices_for_arch(self, arch: str) -> tuple[Device, ...]:
        return tuple(d for d in self.devices if d.arch == arch)

    def families_for_arch(self, arch: str) -> tuple[Family, ...]:
        fids = {d.family for d in self.devices_for_arch(arch)}
        return tuple(f for f in self.families if f.id in fids)

    def search(self, text: str) -> list[Device]:
        """Case-insensitive substring match over label / soc / family label / id."""
        t = (text or "").strip().lower()
        if not t:
            return list(self.devices)
        out = []
        for d in self.devices:
            fam = self.family(d.family)
            hay = f"{d.label} {d.soc} {fam.label} {fam.vendor} {d.id}".lower()
            if t in hay:
                out.append(d)
        return out


_CACHE: DeviceCatalog | None = None


def load_catalog() -> DeviceCatalog:
    """Load (once) and cache the catalog from the JSON beside this module."""
    global _CACHE
    if _CACHE is None:
        with open(CATALOG_PATH, encoding="utf-8") as fh:
            raw = json.load(fh)
        if raw.get("schema") != SCHEMA:
            raise ValueError(f"unexpected device-catalog schema: {raw.get('schema')!r}")
        archs = tuple(Arch(**a) for a in raw["archs"])
        families = tuple(Family(**f) for f in raw["families"])
        devices = tuple(
            Device(
                id=d["id"], label=d["label"], family=d["family"], arch=d["arch"],
                soc=d["soc"],
                builder_platform=(d["builder"] or {}).get("platform") if d["builder"] else None,
                builder_board=(d["builder"] or {}).get("board", "") if d["builder"] else "",
                status=d["status"], reason=d.get("reason", ""),
                role_allow=tuple(d["role_allow"]) if d.get("role_allow") is not None else None,
                notes=d.get("notes", ""),
                ram_mb=d.get("ram_mb"),
            )
            for d in raw["devices"]
        )
        _CACHE = DeviceCatalog(archs=archs, families=families, devices=devices)
    return _CACHE


# ---- the honesty predicates (module-level, catalog-cached) ------------------------

def roles_for(device_id: str, mode: str) -> tuple[tuple[str, str], ...]:
    """The (role id, label) pairs REALLY available for ``device_id`` in Studio ``mode``
    — derived from ``ROLE_CHOICES[mode]`` + ``rpi_boards_for_role()`` (the exact
    predicates emit-image-catalog.py / RolePage / WorklistPage consume), narrowed (never
    widened) by the device's ``role_allow``. An unsupported device derives ()."""
    dev = load_catalog().device(device_id)
    if dev.builder_platform is None:
        return ()
    out: list[tuple[str, str]] = []
    for role, platforms, label in ROLE_CHOICES[mode]:
        if dev.builder_platform not in platforms:
            continue
        # the rpi3 desktop-only node-gate falls out structurally: a node-class role's
        # board list (rpi_boards_for_role) never contains rpi3.
        if dev.builder_platform == "rpi5" and dev.builder_board not in rpi_boards_for_role(role):
            continue
        if dev.role_allow is not None and role not in dev.role_allow:
            continue
        out.append((role, label))
    return tuple(out)


def selectable(device_id: str) -> bool:
    """Whether the device may be picked for a build at all (supported/experimental).
    Unsupported devices are visible in every menu but never selectable (#351)."""
    return load_catalog().device(device_id).status in SELECTABLE_STATUSES


def buildable(device_id: str, mode: str, role_id: str) -> bool:
    """THE honesty predicate the drift guards pin: catalog says (device, mode, role)
    is buildable IFF the device is selectable AND the role derives for it."""
    return selectable(device_id) and any(r == role_id for r, _l in roles_for(device_id, mode))


def mesh_capable(device_id: str) -> bool:
    """ASK 18, verbatim: "image/roles that cant be a mesh should be excluded from mesh
    generation options". This is the predicate that says which those are.

    True iff the device can carry AT LEAST ONE mesh role — i.e. iff it is selectable at
    all AND ``roles_for(device_id, "mesh")`` is non-empty. Two disjoint populations answer
    False and both were on the mesh screen:

      * the 11 SINGLE-IMAGE devices — chromebook, the three La Frite boards, the seven
        Orange Pi boards. They are supported and buildable, just never as a cluster node:
        ROLE_CHOICES["mesh"] names no role on their builder platform, because their
        builders bake no cluster GitOps tree at all;
      * the 27 UNSUPPORTED devices (rpi2, opi6, bpi-f3, rock-5b, the legacy Jetsons, …),
        which derive no roles in ANY mode (``builder_platform is None``).

    Deliberately derived, never a hand-kept list: the authority stays ROLE_CHOICES +
    role_allow + rpi_boards_for_role, so a device that GAINS a mesh role becomes
    mesh-capable in the same commit that gives it one. A literal tuple here would be the
    exact drift ``roles_for`` was written to prevent.

    Qt-free and module-level on purpose — the gate belongs to the catalog, not to a
    wizard page, so ``scripts/emit-image-catalog.py`` and any headless consumer get the
    same answer WorklistPage does."""
    return selectable(device_id) and bool(roles_for(device_id, "mesh"))


def config_axes(device_id: str) -> dict[str, str]:
    """The exact cfg fields selecting this device writes: ``{"platform", "board"}``.
    ``board`` is "" for platforms with no --board flag (x86, orangepizero2,
    orangepizero2w, orangepizero3, orangepi3-lts) and the
    exact builder ``--board`` value otherwise — emission identity by construction.
    Raises for an unsupported device (it has no builder axes to write)."""
    dev = load_catalog().device(device_id)
    if dev.builder_platform is None:
        raise ValueError(f"device {device_id!r} is unsupported — no builder axes")
    return {"platform": dev.builder_platform, "board": dev.builder_board}


def ram_mb_for(device_id: str) -> int | None:
    """The device RAM ceiling (MiB) for the QEMU-e2e runtime-load envelope, or ``None``
    when the catalog declares none (the board ships in several RAM SKUs, so there is no
    single ceiling to assert — the harness then skips the memory-capped re-boot for that
    row rather than guessing). Declared only where the SoC free text pins one RAM size
    (e.g. rpi3's 1 GB, the orin-nano-4gb / orin-nx-8gb / orin-nx-16gb SKU labels)."""
    return load_catalog().device(device_id).ram_mb


def status_reason(device_id: str) -> str:
    """The badge/tooltip reason text: the entry's reason, with the fail-loud-preflight
    caveat prefixed for experimental devices (supported devices return "")."""
    dev = load_catalog().device(device_id)
    if dev.status == "supported":
        return ""
    if dev.status == "experimental":
        return (dev.reason if dev.reason.lower().startswith("experimental")
                else f"{EXPERIMENTAL_CAVEAT}: {dev.reason}")
    return dev.reason


# ---- the ONE row presenter every channel renders (GUI, TUI, CLI) ------------------
#
# The GUI device tree, the TUI's arch -> family -> device browse and the CLI's
# --list-devices all label a row with these functions and nothing else, so a device can
# never read one way in a window and another way in a terminal. Colours stay in the
# GUI (gui/pages/_widgets.py); only the WORDS live here.

#: The status badge text per catalog status. SUPPORTED carries no badge: buildable is
#: the default claim, and the two non-default statuses must say so explicitly (#351).
STATUS_BADGE_TEXT = {
    "supported": "",
    "experimental": EXPERIMENTAL_CAVEAT,
    "unsupported": "NOT BUILDABLE",
}


@dataclass(frozen=True)
class DeviceRow:
    """One device as every channel shows it in ``mode``.

    ``status_text`` is the GUI tree's Status column, verbatim. ``pickable`` is the
    selection gate: False for an UNSUPPORTED device, and for a selectable device that
    derives no image type in this mode. ``refusal`` is the sentence a channel prints
    when someone tries to pick a row that is not pickable ("" when it is pickable).
    ``detail`` is the GUI tooltip: the reason or caveat, else the device notes."""
    id: str
    label: str
    soc: str
    arch: str
    family: str
    status: str
    status_text: str
    pickable: bool
    refusal: str
    detail: str
    board_axis: str


def family_heading(family_id: str) -> str:
    """A family group's heading: ``"<label> — <vendor>"`` (the GUI tree's bold row)."""
    fam = load_catalog().family(family_id)
    return f"{fam.label} — {fam.vendor}"


def board_axis(device_id: str) -> str:
    """The builder axes a device selects, as the flags they become: ``--platform rpi5
    --board rpi4``, ``--platform x86 (no --board axis)``, or ``no builder`` for an
    UNSUPPORTED device (it has no axes to write)."""
    dev = load_catalog().device(device_id)
    if dev.builder_platform is None:
        return "no builder"
    if dev.builder_board:
        return f"--platform {dev.builder_platform} --board {dev.builder_board}"
    return f"--platform {dev.builder_platform} (no --board axis)"


def device_row(device_id: str, mode: str) -> DeviceRow:
    """The row for ``device_id`` in Studio ``mode`` — the rule RolePage's device tree
    has always applied, lifted here so the TUI and the CLI apply the same one:

    * UNSUPPORTED: ``NOT BUILDABLE — <reason>``, never pickable;
    * selectable but no image type in this mode: ``no <mode> image — <notes, or the
      modes that do offer it>``, not pickable here;
    * otherwise the status badge ("" for supported, the EXPERIMENTAL caveat)."""
    dev = load_catalog().device(device_id)
    roles = roles_for(device_id, mode)
    if dev.status == "unsupported":
        text = f"{STATUS_BADGE_TEXT['unsupported']} — {dev.reason}"
        pickable = False
        refusal = f"{dev.label} cannot be built: {dev.reason}"
    elif not roles:
        others = [m for m in ROLE_CHOICES if roles_for(device_id, m)]
        text = (f"no {mode} image — " + (dev.notes or
                f"offered on the {'/'.join(others) or 'other'} path"))
        pickable = False
        refusal = f"{dev.label}: {text}"
    else:
        text = STATUS_BADGE_TEXT[dev.status]
        pickable = True
        refusal = ""
    return DeviceRow(
        id=dev.id, label=dev.label, soc=dev.soc, arch=dev.arch, family=dev.family,
        status=dev.status, status_text=text, pickable=pickable, refusal=refusal,
        detail=status_reason(device_id) or dev.notes, board_axis=board_axis(device_id))


def browse(mode: str) -> list[tuple["Arch", list[tuple["Family", list[DeviceRow]]]]]:
    """The whole catalog as arch -> family -> device rows, in catalog order. EVERY arch
    with at least one device appears (an all-refused arch such as ARMv7 included, so
    its reasons are reachable); a family appears under each arch it has devices on."""
    cat = load_catalog()
    out = []
    for arch in cat.archs:
        fams = []
        for fam in cat.families_for_arch(arch.id):
            rows = [device_row(d.id, mode) for d in cat.devices_in_family(fam.id)
                    if d.arch == arch.id]
            if rows:
                fams.append((fam, rows))
        if fams:
            out.append((arch, fams))
    return out


def row_text_lines(row: DeviceRow, number: int | None = None,
                   current: bool = False) -> list[str]:
    """A device row as terminal text — what the TUI browse and ``--list-devices``
    both print: ``label — SoC``, then the status (the GUI Status column's words, when
    there are any), the builder axes, and the reason or caveat (the GUI tooltip)."""
    marker = "*" if current else " "
    head = f" {marker}{number:2d}. " if number is not None else "   "
    out = [f"{head}{row.label} — {row.soc}"]
    pad = " " * len(head)
    if row.status_text:
        out.append(f"{pad}status: {row.status_text}")
    out.append(f"{pad}builds as: {row.board_axis}")
    if row.detail and row.detail not in row.status_text:
        out.append(f"{pad}about: {row.detail}")
    return out


def list_devices_lines(mode: str) -> list[str]:
    """``--list-devices`` as text: every catalog row, arch -> family -> device, each
    with its id (what ``--json`` keys on) and :func:`row_text_lines`."""
    out = [f"Device catalog — labelled for {mode} images "
           f"(--mode {'|'.join(ROLE_CHOICES)} for another path). Rows marked NOT "
           f"BUILDABLE, or with no image on this path, cannot be picked."]
    for arch, fams in browse(mode):
        out.append("")
        out.append(arch.label)
        for fam, rows in fams:
            out.append(f"  {family_heading(fam.id)}")
            for row in rows:
                lines = row_text_lines(row)
                out.append(f"    [{row.id}]")
                out += ["    " + ln for ln in lines]
    return out


def list_devices_json(mode: str) -> dict:
    """``--list-devices --json``: the same rows as data. ``pickable`` is the selection
    gate and ``refusal`` its sentence; ``roles`` lists the image types the device
    derives on this path (empty for a refused row)."""
    devices = []
    for arch, fams in browse(mode):
        for fam, rows in fams:
            for row in rows:
                dev = load_catalog().device(row.id)
                devices.append({
                    "id": row.id, "label": row.label, "soc": row.soc,
                    "arch": arch.id, "arch_label": arch.label,
                    "family": fam.id, "family_heading": family_heading(fam.id),
                    "status": row.status, "status_text": row.status_text,
                    "pickable": row.pickable, "refusal": row.refusal,
                    "detail": row.detail, "board_axis": row.board_axis,
                    "platform": dev.builder_platform, "board": dev.builder_board,
                    "roles": [r for r, _l in roles_for(row.id, mode)],
                })
    return {"schema": LIST_SCHEMA, "catalog": SCHEMA, "mode": mode, "devices": devices}


def default_device_for_platform(platform: str) -> str:
    """The device a bare platform id maps to (the GUI compat shim for
    ``select_machine(plat)``): the first SELECTABLE device whose axes equal the
    platform's own defaults (board == the builder-default first board, or "" on
    boardless platforms) — i.e. exactly what today's card + default combo produced."""
    return device_for_axes(platform, "")


def device_for_axes(platform: str, board: str) -> str:
    """Map cfg axes back to a device id (initializePage round-trip). board "" matches
    the platform's first selectable device (its default board). Prefers supported over
    experimental, then catalog order — so (rpi5, rpi4) resolves to the rpi4 device,
    not the experimental rpi400 alias."""
    cat = load_catalog()
    best: Device | None = None
    for d in cat.devices:
        if d.builder_platform != platform:
            continue
        if board and d.builder_board != board:
            continue
        if best is None or (best.status != "supported" and d.status == "supported"):
            best = d
        if best.status == "supported" and not board:
            break   # first supported device is the platform default
        if best.status == "supported" and board and best.builder_board == board:
            break
    if best is None:
        raise ValueError(f"no catalog device for platform={platform!r} board={board!r}")
    return best.id
