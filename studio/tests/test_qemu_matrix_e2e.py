"""Matrix-driven QEMU e2e (OPT-IN) + its hermetic always-run half.

The gated test boots operator-supplied golden artifacts across the full device build
matrix (tests/build-matrix/matrix.tsv) under qemu-system and asserts boot-marker + image
SIZE + runtime LOAD via tests/qemu/run-matrix-e2e.sh. It NEVER builds anything.

SKIPPED by default (like test_tor_onion_e2e.py): the boot walk needs qemu, operator
artifacts, and — under TCG on an x86 host — many hours. Enable with HUGMESH_QEMU_E2E=1
(and qemu installed). Everything ELSE in this file is HERMETIC and always runs: the
matrix enumeration, the launcher resolution, the pseudo-role translation, the compact
image-size formula, the ``img_size=``-from-``--print-plan`` parser, and the shell
driver's ``--dry-run`` (which enumerates all 150 rows with no root/boot/builder).
"""
import os
import re
import shutil
import subprocess

import pytest

from hugmesh_studio.core import build_matrix as bm
from hugmesh_studio.core import device_catalog as dc

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
QEMU_DIR = os.path.join(GENERATOR_DIR, "tests", "qemu")
DRIVER = os.path.join(QEMU_DIR, "run-matrix-e2e.sh")
LAUNCH_ARM = os.path.join(QEMU_DIR, "launch-arm.sh")
ASSERTIONS = os.path.join(QEMU_DIR, "matrix-assertions.sh")

# Expected per-platform row counts — the canonical census of matrix.tsv (frite 38,
# jetson 14, orangepi5 14, orangepizero2 8, orangepizero2w 8, orangepizero3 8,
# orangepi3-lts 8, orangepi4-lts 8, rpi5 20, x86 24; 150 total).
EXPECTED_COUNTS = {"frite": 38, "jetson": 14, "orangepi5": 14,
                   "orangepizero2": 8, "orangepizero2w": 8, "orangepizero3": 8,
                   "orangepi3-lts": 8, "orangepi4-lts": 8,
                   "rpi5": 20, "x86": 24}

_qemu = shutil.which("qemu-system-x86_64")

_gated = pytest.mark.skipif(
    os.environ.get("HUGMESH_QEMU_E2E") != "1" or _qemu is None,
    reason="matrix QEMU e2e is opt-in — set HUGMESH_QEMU_E2E=1 with qemu installed")


# ── always-run: the harness exists + is executable ───────────────────────────────
def test_harness_scripts_exist_and_are_executable():
    for p in (DRIVER, LAUNCH_ARM, ASSERTIONS):
        assert os.path.exists(p), f"missing harness file: {p}"
        assert os.access(p, os.X_OK), f"not executable: {p}"


# ── always-run: hermetic matrix enumeration (no builder, no boot) ─────────────────
def test_matrix_enumerates_150_rows_by_platform():
    rows = bm.matrix_rows()
    assert len(rows) == sum(EXPECTED_COUNTS.values()) == 150
    assert bm.platform_counts() == EXPECTED_COUNTS


def test_every_row_resolves_a_launcher():
    launchers = {r.launcher for r in bm.matrix_rows()}
    assert launchers == {"launch-x86.sh", "launch-pi.sh", "launch-arm.sh"}
    for r in bm.matrix_rows():
        # each resolved launcher script must actually exist on disk
        assert os.path.exists(os.path.join(QEMU_DIR, r.launcher))


def test_pseudo_roles_translate_like_check_sh_cli_leg():
    rows = bm.matrix_rows()
    # rpi5 standalone-desktop -> --role desktop --standalone
    sd = [r for r in rows if r.role == "standalone-desktop"]
    assert sd, "expected the rpi5 standalone-desktop pseudo-role rows"
    for r in sd:
        role, flavor, standalone = r.normalized()
        assert (role, standalone) == ("desktop", True)
    # ARM flavor=standalone -> flavor=installer --standalone
    fs = [r for r in rows if r.flavor == "standalone"]
    assert fs, "expected the ARM flavor=standalone pseudo-role rows"
    for r in fs:
        role, flavor, standalone = r.normalized()
        assert (flavor, standalone) == ("installer", True)
    # a plain row is untouched
    plain = next(r for r in rows if r.platform == "x86" and r.role == "be")
    assert plain.normalized() == ("be", "", False)


# ── always-run: SIZE limit maths (read from the builder, never hardcoded) ─────────
def test_compact_image_size_formula():
    # (1 + 512 + ROOT_MiB + 1) MiB, the builders' img_size_mib layout.
    for root_mib in (2048, 3072, 6144, 8192, 9216, 16384):
        assert bm.compact_image_bytes(root_mib) == (1 + 512 + root_mib + 1) * bm.MIB


def test_img_size_parsed_from_print_plan_flags_line():
    # the exact FLAGS_EFFECTIVE grammar every builder emits under --print-plan.
    rpi_plan = ("PLAN  FLAGS_EFFECTIVE    env=test img=true iso=false tar=true "
                "img_size=9216 grow=fill sd_only=false compress=false")
    x86_plan = ("PLAN  FLAGS_EFFECTIVE    env=prod img=true live_iso=false tar=true "
                "img_size=51200 grow=fill compress=false standalone=false")
    assert bm.parse_img_size_mib(rpi_plan) == 9216
    assert bm.parse_img_size_mib(x86_plan) == 51200
    with pytest.raises(ValueError):
        bm.parse_img_size_mib("no size field here")


def test_rpi5_size_limit_matches_the_reconciled_9216_default():
    # #414 reconciliation: the Pi ROOT_MiB default is 9216 (docs/help/tests agree);
    # a Pi .img must be <= (1+512+9216+1) MiB.
    assert bm.compact_image_bytes(9216) == 10202644480


# ── always-run: runtime LOAD ceiling (device RAM envelope) ────────────────────────
def test_ram_ceiling_present_for_ram_differentiated_boards():
    # the boards whose SoC pins a single RAM SKU carry a machine-readable ceiling.
    assert dc.ram_mb_for("rpi3") == 1024
    assert dc.ram_mb_for("orin-nano-4gb") == 4096
    assert dc.ram_mb_for("orin-nx-8gb") == 8192
    assert dc.ram_mb_for("orin-nx-16gb") == 16384
    # multi-SKU boards declare none (no single ceiling to assert) — never guessed.
    assert dc.ram_mb_for("rpi5") is None


def test_row_ram_maps_via_catalog():
    rows = bm.matrix_rows()
    rpi3 = next(r for r in rows if r.board == "rpi3")
    assert bm.row_ram_mb(rpi3) == 1024
    x86 = next(r for r in rows if r.platform == "x86")
    assert bm.row_ram_mb(x86) is None   # boardless x86 declares no single ceiling


# ── always-run: declared ram_mb values are sane (drift guard) ─────────────────────
def test_declared_ram_mb_is_positive():
    for d in dc.load_catalog().devices:
        if d.ram_mb is not None:
            assert isinstance(d.ram_mb, int) and d.ram_mb > 0, f"{d.id}: bad ram_mb {d.ram_mb!r}"


# ── always-run: the shell driver's --dry-run enumerates all 150 rows ──────────────
def test_driver_dry_run_enumerates_all_rows():
    r = subprocess.run(["bash", DRIVER, "--dry-run"], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, f"dry-run failed:\n{r.stdout}\n{r.stderr}"
    rows = [ln for ln in r.stdout.splitlines() if ln.startswith("ROW ")]
    assert len(rows) == 150
    assert "DRY-RUN enumerated 150 matrix rows" in r.stdout


def test_driver_subset_filter():
    r = subprocess.run(["bash", DRIVER, "--dry-run", "--only", "x86/be+gpu"],
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0
    rows = [ln for ln in r.stdout.splitlines() if ln.startswith("ROW ")]
    assert len(rows) == 2 and all("launch-x86.sh" in ln for ln in rows)


def test_driver_boot_path_skips_clean_without_opt_in(monkeypatch):
    # no HUGMESH_QEMU_E2E → SKIP clean (exit 0), never a FAIL (windows-studio-e2e shape).
    env = {k: v for k, v in os.environ.items() if k != "HUGMESH_QEMU_E2E"}
    r = subprocess.run(["bash", DRIVER, "--only", "x86/be+gpu"], env=env,
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0
    assert "SKIP" in (r.stdout + r.stderr)


def test_driver_boot_path_skips_when_no_artifact_even_opted_in(tmp_path):
    # Opted in + qemu bypassed by the launcher stub, but the WORK_DIR is EMPTY: the row
    # must SKIP because the ARTIFACT is absent — NOT because the boot path is a stub.
    # (This is exactly why the no-build sandbox skips: no golden images, not "always skip".)
    stub = tmp_path / "launch-stub.sh"
    stub.write_text("#!/usr/bin/env bash\nexit 0\n"); stub.chmod(0o755)
    env = {**os.environ, "HUGMESH_QEMU_E2E": "1",
           "SNAP_QEMU_LAUNCH_CMD": f"bash {stub}"}
    r = subprocess.run(["bash", DRIVER, "--only", "x86/be+gpu", "-w", str(tmp_path)],
                       env=env, capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stdout + r.stderr
    out = r.stdout + r.stderr
    assert "no golden artifact" in out           # the SKIP names the real reason
    assert re.search(r"skip=[1-9]", out)


def test_driver_really_boots_and_asserts_with_a_present_artifact(tmp_path):
    """HERMETIC wiring proof (no real qemu / no build): with a resolvable artifact and
    stub launcher/plan, the driver must ACTUALLY resolve → assert_size → boot →
    assert_runtime_load → tally a PASS (ran increments, fail=0). Guards against a
    regression to an unconditional-skip boot path."""
    plan = tmp_path / "plan.sh"
    plan.write_text('#!/usr/bin/env bash\necho "FLAGS_EFFECTIVE: role=$2 img_size=9216"\n'); plan.chmod(0o755)
    launch = tmp_path / "launch.sh"
    launch.write_text(
        "#!/usr/bin/env bash\nrundir=''\n"
        "while [ $# -gt 0 ]; do case \"$1\" in --run-dir) rundir=\"$2\"; shift 2;; *) shift;; esac; done\n"
        "[ -n \"$rundir\" ] && printf 'boot\\n[  OK  ] reached target Graphical Interface\\nlogin:\\n' > \"$rundir/console.log\"\n"
        "exit 0\n")
    launch.chmod(0o755)
    wd = tmp_path / "wd"; wd.mkdir()
    (wd / "hugmesh-x86-be+gpu-prod-ts.img").write_bytes(b"\0" * (1 << 20))  # 1 MiB << ceiling
    env = {**os.environ, "HUGMESH_QEMU_E2E": "1",
           "SNAP_QEMU_PLAN_CMD": f"bash {plan}", "SNAP_QEMU_LAUNCH_CMD": f"bash {launch}"}
    r = subprocess.run(["bash", DRIVER, "--only", "x86/be+gpu", "-w", str(wd)],
                       env=env, capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stdout + r.stderr
    out = r.stdout + r.stderr
    assert "size OK" in out                          # assert_size actually ran
    assert re.search(r"x86/be\+gpu[^:]*: PASS", out)  # the row passed (label carries /env)
    m = re.search(r"ran=(\d+) pass=(\d+) skip=\d+ inconclusive=\d+ fail=(\d+)", out)
    assert m, f"no RESULT census:\n{out}"
    assert int(m.group(1)) >= 2 and int(m.group(2)) >= 2 and int(m.group(3)) == 0


def test_driver_fails_the_row_when_the_image_is_oversize(tmp_path):
    # The SIZE assertion must actually FAIL a too-big image (not silently pass).
    plan = tmp_path / "plan.sh"
    plan.write_text('#!/usr/bin/env bash\necho "img_size=1"\n'); plan.chmod(0o755)   # ceiling 515 MiB
    launch = tmp_path / "launch.sh"
    launch.write_text("#!/usr/bin/env bash\nexit 0\n"); launch.chmod(0o755)
    wd = tmp_path / "wd"; wd.mkdir()
    with open(wd / "hugmesh-x86-be+gpu-prod-ts.img", "wb") as fh:
        fh.truncate(600 * (1 << 20))             # 600 MiB sparse > 515 MiB ceiling
    env = {**os.environ, "HUGMESH_QEMU_E2E": "1",
           "SNAP_QEMU_PLAN_CMD": f"bash {plan}", "SNAP_QEMU_LAUNCH_CMD": f"bash {launch}"}
    r = subprocess.run(["bash", DRIVER, "--only", "x86/be+gpu", "-w", str(wd)],
                       env=env, capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    assert re.search(r"fail=[1-9]", out), f"oversize image should fail the row:\n{out}"


# ── OPT-IN: the real matrix boot walk (needs qemu + operator artifacts) ───────────
@_gated
def test_matrix_boot_walk(tmp_path):
    """Boot the subset's golden artifacts and assert boot-marker + size + load.

    Operator-only: supply MATRIX_FILTER + a WORK_DIR of golden images. A missing
    artifact is a per-row SKIP (exit 0), so this asserts only that the driver runs
    green — the per-row PASS/SKIP census is in its stdout."""
    env = {**os.environ, "WORK_DIR": str(tmp_path)}
    subset = os.environ.get("MATRIX_FILTER", "x86/be+gpu")
    r = subprocess.run(["bash", DRIVER, "--only", subset], env=env,
                       capture_output=True, text=True, timeout=int(os.environ.get("QEMU_MATRIX_TIMEOUT", "36000")))
    assert r.returncode == 0, f"matrix boot walk failed:\n{r.stdout}\n{r.stderr}"
    assert "RESULT:" in r.stdout
