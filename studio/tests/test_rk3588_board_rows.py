"""Radxa ROCK 5B and FriendlyElec NanoPC-T6 as EXPERIMENTAL rows on the Orange Pi 5
builder (hugmesh-generator#1061, lane E2 of #1045).

Both boards share the Orange Pi 5's RK3588 boot chain (rkbin DDR-init + TF-A BL31 ->
mainline U-Boot -> extlinux), so they ride build-orangepi5-stage4.sh as two more
--board values. These guards pin every surface that has to learn a board, so a row
can never be offered where a channel would refuse it:

* the device catalog row is EXPERIMENTAL on the orangepi5 builder (it was
  "unsupported, promotion path exists");
* the builder's select_board() really hands each board its mainline U-Boot defconfig
  and device tree (read from the builder's own --print-plan, not from its source);
* tests/qemu/launch-arm.sh's board table has a row for EVERY orangepi5 board and its
  DTB name is the one the builder ships (the header calls it "the drift-free key";
  until now nothing checked it);
* tests/build-matrix/matrix.tsv carries the same cells for every orangepi5 board;
* scripts/_roles-lib.sh knows each board's RAM sizes (the --ram-gb warning table).

The promotion itself is gated separately by studio/tests/test_mainline_evidence.py
(hugmesh-generator#1057). When that evidence file is present, the pair below must be
the one it recorded as found.

Pure-core: no Qt import. Runs the builder with --print-plan only (no root, no build).
"""
from __future__ import annotations

import json
import os
import re
import subprocess

import pytest

from hugmesh_studio.core import device_catalog as dc
from hugmesh_studio.core.config import ORANGEPI5_BOARDS

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
BUILDER = "build-orangepi5-stage4.sh"
LAUNCH_ARM = os.path.join(GENERATOR_DIR, "tests", "qemu", "launch-arm.sh")
MATRIX = os.path.join(GENERATOR_DIR, "tests", "build-matrix", "matrix.tsv")
ROLES_LIB = os.path.join(GENERATOR_DIR, "scripts", "_roles-lib.sh")
EVIDENCE = os.path.join(STUDIO_ROOT, "evidence", "mainline-evidence.json")

# The mainline pair each new board boots with: (kernel DTB, U-Boot defconfig).
NEW_BOARDS = {
    "rock-5b": ("rockchip/rk3588-rock-5b.dtb", "rock5b-rk3588_defconfig"),
    "nanopc-t6": ("rockchip/rk3588-nanopc-t6.dtb", "nanopc-t6-rk3588_defconfig"),
}


def _plan(board: str, *extra: str) -> dict[str, str]:
    """The builder's own --print-plan for --board <board>, as a PLAN_* dict."""
    env = dict(os.environ)
    env.pop("WAYLAND_DISPLAY", None)
    proc = subprocess.run(
        ["bash", os.path.join(GENERATOR_DIR, BUILDER), "--board", board, *extra,
         "--print-plan"],
        cwd=GENERATOR_DIR, env=env, capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, (board, proc.returncode, proc.stderr[-2000:])
    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if line.startswith("PLAN_") and "=" in line:
            k, v = line.split("=", 1)
            out[k[len("PLAN_"):]] = v
    assert out, (board, "no PLAN_ lines", proc.stdout[-2000:])
    return out


def _launch_arm_row(platform: str, board: str) -> dict[str, str]:
    """Run launch-arm.sh's OWN board_defaults() (cut out of the script, so the arg
    parser and the tool checks never run) and return DEF_DTB/DEF_CPU/DEF_SUBDIR."""
    with open(LAUNCH_ARM, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r"^board_defaults\(\) \{\n.*?^\}\n", text, re.S | re.M)
    assert m, "launch-arm.sh lost its board_defaults() table"
    script = (
        'die() { echo "DIE: $*"; exit 3; }\n' + m.group(0)
        + f'board_defaults "{platform}" "{board}"\n'
        + 'printf "DTB=%s\\nCPU=%s\\nSUBDIR=%s\\n" "$DEF_DTB" "$DEF_CPU" "$DEF_SUBDIR"\n')
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          timeout=30)
    assert proc.returncode == 0, (platform, board, proc.stdout, proc.stderr)
    return dict(line.split("=", 1) for line in proc.stdout.splitlines() if "=" in line)


@pytest.mark.parametrize("board", sorted(NEW_BOARDS))
def test_catalog_row_is_experimental_on_the_orangepi5_builder(board):
    d = dc.load_catalog().device(board)
    assert d.status == "experimental", (board, d.status)
    assert d.builder_platform == "orangepi5", (board, d.builder_platform)
    assert d.builder_board == board, (board, d.builder_board)
    assert board in ORANGEPI5_BOARDS, (board, ORANGEPI5_BOARDS)
    # An experimental row says it is unvalidated on silicon (the catalog's own rule).
    assert "hardware validation pending" in d.reason, d.reason


@pytest.mark.parametrize("board", sorted(NEW_BOARDS))
def test_builder_selects_the_mainline_pair(board):
    dtb, uboot = NEW_BOARDS[board]
    plan = _plan(board, "--flavor", "installer")
    assert plan["BOARD"] == board
    assert plan["DTB"] == dtb, plan["DTB"]
    assert plan["UBOOT_DEFCONFIG"] == uboot, plan["UBOOT_DEFCONFIG"]
    assert f"-orangepi5-{board}-arm64-" in plan["ARTIFACT_PREFIX"], plan["ARTIFACT_PREFIX"]


@pytest.mark.parametrize("board", sorted(NEW_BOARDS))
def test_builder_builds_the_node_roles_for_the_new_board(board):
    plan = _plan(board, "--role", "pki")
    assert plan["ROLE"] == "pki" and plan["BOARD"] == board, plan
    assert plan["EXPERIMENTAL"].startswith("yes"), plan.get("EXPERIMENTAL")


def test_pair_matches_the_mainline_evidence_when_present():
    """Once hugmesh-generator#1057's evidence table is on this tree, the pair this
    builder ships must be the one recorded there as found (the promotion guard reads
    the verdict; this reads the names)."""
    if not os.path.exists(EVIDENCE):
        pytest.skip("mainline evidence table not on this tree yet (hugmesh-generator#1057)")
    with open(EVIDENCE, encoding="utf-8") as fh:
        ev = {b["id"]: b for b in json.load(fh)["boards"]}
    for board, (dtb, uboot) in NEW_BOARDS.items():
        row = ev[board]
        assert row["verdict"] == "found", (board, row["verdict"])
        assert row["dt"] + ".dtb" == dtb, (board, row["dt"])
        assert row["u-boot"]["defconfig"] == uboot, (board, row["u-boot"])


@pytest.mark.parametrize("board", ORANGEPI5_BOARDS)
def test_launch_arm_has_a_row_whose_dtb_is_the_builders(board):
    row = _launch_arm_row("orangepi5", board)
    plan = _plan(board, "--flavor", "installer")
    assert row["DTB"] == plan["DTB"], (board, row["DTB"], plan["DTB"])
    assert row["SUBDIR"] == plan["POOL_KEY"] == "snap-build-orangepi5", (row, plan["POOL_KEY"])
    # QEMU -M virt has no A76/A55 big.LITTLE: the RK3588 boards boot on the A76 model.
    assert row["CPU"] == "cortex-a76", row


def _matrix_cells(board: str) -> set[tuple[str, str, str]]:
    cells = set()
    with open(MATRIX, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            plat, role, env, b, flavor, _desk = line.rstrip("\n").split("\t")
            if plat == "orangepi5" and b == board:
                cells.add((role, env, flavor))
    return cells


@pytest.mark.parametrize("board", sorted(NEW_BOARDS))
def test_matrix_carries_the_orange_pi_5_cells_for_the_board(board):
    """Same desktop flavors and node roles as the Orange Pi 5 (the RK3588S sibling,
    which also has no standalone probe row)."""
    want = {("desktop", env, fl) for env in ("test", "prod")
            for fl in ("live", "installer", "both")}
    want |= {(role, env, "installer") for env in ("test", "prod")
             for role in ("pki", "backend", "frontend", "omnibus")}
    assert _matrix_cells("orange-pi-5") == want  # the template this mirrors
    assert _matrix_cells(board) == want, sorted(want ^ _matrix_cells(board))


@pytest.mark.parametrize("board", ORANGEPI5_BOARDS)
def test_roles_lib_knows_the_boards_ram_sizes(board):
    with open(ROLES_LIB, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r'^HUGMESH_BOARD_RAM_GB="\n(.*?)^"', text, re.S | re.M)
    assert m, "_roles-lib.sh lost HUGMESH_BOARD_RAM_GB"
    sizes = dict(l.split("=", 1) for l in m.group(1).split() if "=" in l)
    assert board in sizes, (board, sorted(sizes))
    # omnibus needs 16 GB: every orangepi5 board is sold with at least that much.
    assert max(int(g) for g in sizes[board].split(",")) >= 16, sizes[board]
