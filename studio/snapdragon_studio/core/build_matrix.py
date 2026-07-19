"""Build-matrix enumeration + image-size/RAM helpers for the QEMU e2e harness (Qt-free).

``tests/build-matrix/matrix.tsv`` is THE canonical enumeration of every buildable
image cell — one row per (platform, role, env, board, flavor, desktop). Two channels
already walk it: ``tests/build-matrix/check.sh`` (dry-run flag coverage) and now the
opt-in ``tests/qemu/run-matrix-e2e.sh`` (boot + size/load assertions). This module is
the Python view of that same file so the enumeration + the drift-free size/RAM maths
are unit-testable HERMETICALLY (no builder, no docker, no qemu — just the .tsv + pure
arithmetic), mirroring the shell driver's row-by-row decisions exactly.

Nothing here builds or boots anything: it parses the .tsv, resolves which launcher a
platform uses, translates the JOB-channel pseudo-roles the way ``check.sh``'s CLI leg
does, computes the compact-image byte size from a builder's ``ROOT_MiB`` (the
``img_size=`` field every builder emits in ``--print-plan``), and maps a row to its
device RAM ceiling via the device catalog. The harness reads the LIMITS at runtime from
the builders' own ``--print-plan`` output — this module supplies the parser + the
formula, never a hardcoded per-row size.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass

from . import device_catalog as dc

MIB = 1024 ** 2

# Beside studio/ ; matrix.tsv lives at <repo>/tests/build-matrix/matrix.tsv.
_CORE_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(_CORE_DIR)))
MATRIX_TSV = os.path.join(_REPO_DIR, "tests", "build-matrix", "matrix.tsv")

# platform -> the tests/qemu launcher that boots its artifact. x86 self-boots
# (q35+OVMF); rpi5 kernel-direct-boots via launch-pi.sh; every other aarch64
# platform kernel-direct-boots the generalized launch-arm.sh (same -M virt path).
_ARM_VIRT_PLATFORMS = ("frite", "jetson", "orangepi5", "orangepizero2")


@dataclass(frozen=True)
class MatrixRow:
    """One matrix.tsv cell. ``-`` in the .tsv (axis N/A) is normalized to ""."""
    platform: str
    role: str
    env: str
    board: str
    flavor: str
    desktop: str

    @property
    def launcher(self) -> str:
        """The tests/qemu launcher script name that boots this row's artifact."""
        if self.platform == "x86":
            return "launch-x86.sh"
        if self.platform == "rpi5":
            return "launch-pi.sh"
        if self.platform in _ARM_VIRT_PLATFORMS:
            return "launch-arm.sh"
        raise ValueError(f"unknown platform {self.platform!r} (no launcher)")

    def normalized(self) -> tuple[str, str, bool]:
        """(role, flavor, standalone) after translating the JOB-channel pseudo-roles
        the SAME way check.sh's CLI leg does (see matrix.tsv's header comments):

        * rpi5 ``standalone-desktop`` -> ``--role desktop --standalone`` ;
        * ARM ``flavor=standalone`` (frite/orangepi5/orangepizero2, which have no role
          axis) -> ``flavor=installer --standalone`` (--standalone forces the installer
          path internally anyway).

        Every other cell passes through unchanged (standalone=False)."""
        role, flavor, standalone = self.role, self.flavor, False
        if role == "standalone-desktop":
            role, standalone = "desktop", True
        if flavor == "standalone":
            flavor, standalone = "installer", True
        return role, flavor, standalone


def _is_data_line(line: str) -> bool:
    s = line.strip()
    return bool(s) and not s.startswith("#")


def iter_matrix_rows(path: str = MATRIX_TSV):
    """Yield a :class:`MatrixRow` per data line of matrix.tsv (comments/blanks skipped),
    with the exact ``IFS=$'\\t' read -r platform role env board flavor desktop`` split
    check.sh uses. ``-`` (axis not applicable) becomes ""."""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not _is_data_line(line):
                continue
            cols = line.rstrip("\n").split("\t")
            # pad short rows so every axis is addressable (mirrors read -r's behavior)
            cols += [""] * (6 - len(cols))
            platform, role, env, board, flavor, desktop = (
                "" if c == "-" else c for c in cols[:6])
            yield MatrixRow(platform, role, env, board, flavor, desktop)


def matrix_rows(path: str = MATRIX_TSV) -> list[MatrixRow]:
    return list(iter_matrix_rows(path))


def platform_counts(path: str = MATRIX_TSV) -> dict[str, int]:
    """rows-per-platform — the hermetic cross-check against
    ``grep -cvE '^\\s*#|^\\s*$' matrix.tsv`` broken out by the platform column."""
    counts: dict[str, int] = {}
    for r in iter_matrix_rows(path):
        counts[r.platform] = counts.get(r.platform, 0) + 1
    return counts


# ── image SIZE (the size LIMIT is read from the builder, never hardcoded) ──────────

def compact_image_bytes(root_mib: int) -> int:
    """The exact compact ``.img`` byte size the builders lay out for a ``ROOT_MiB`` root:
    ``(1 + 512 + ROOT_MiB + 1) MiB`` — a 1 MiB alignment gap + 512 MiB FAT boot +
    ROOT_MiB ext4 root + 1 MiB slack (build-rpi5-stage4.sh / build-x86-host-stage4.sh
    ``img_size_mib=$(( 1 + 512 + ROOT_MiB + 1 ))``). This is the ceiling a built
    artifact's ``stat -c%s`` must not exceed."""
    return (1 + 512 + int(root_mib) + 1) * MIB


_IMG_SIZE_RE = re.compile(r"\bimg_size=(\d+)\b")


def parse_img_size_mib(plan_text: str) -> int:
    """Read ``ROOT_MiB`` from a builder's ``--print-plan`` output: every one of the six
    builders emits ``img_size=<ROOT_MiB>`` in its ``FLAGS_EFFECTIVE`` plan line. This is
    the drift-free way to learn a row's size limit (no hardcoded per-role table) — the
    same string check.sh already proves every row prints. Raises if absent."""
    m = _IMG_SIZE_RE.search(plan_text)
    if not m:
        raise ValueError("no img_size= field in --print-plan output")
    return int(m.group(1))


# ── device RAM ceiling (the runtime LOAD envelope) ────────────────────────────────

def row_ram_mb(row: MatrixRow) -> int | None:
    """The device RAM ceiling (MiB) a row's artifact must boot inside, via the catalog:
    (platform, board) -> device -> ``ram_mb``. ``None`` when the catalog declares no
    machine-readable RAM for that device (many boards ship in several RAM SKUs) — the
    harness then SKIPs the runtime-load re-boot for the row rather than guessing a
    ceiling. Boardless platforms (x86, orangepizero2) map on board=""."""
    try:
        device_id = dc.device_for_axes(row.platform, row.board)
    except ValueError:
        return None
    return dc.ram_mb_for(device_id)
