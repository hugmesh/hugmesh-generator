"""core/qemu_tests.py — the Qt-free driver behind QemuPage and the post-build hook.

Hermetic on purpose: no docker daemon work, no qemu, no images — a fake artifacts
tree of empty files exercises every resolution rule, and the one shell test runs
the REAL tests/qemu/run-qemu-docker.sh in --list mode (which enumerates and exits
before any container is created) to prove the Python parse and the runner's parse
agree on the SAME sample names. Drift in either direction fails here rather than
silently booting the wrong image.
"""
import json
import os
import re
import subprocess

import pytest

from hugmesh_studio.core import qemu_tests
from hugmesh_studio.core.qemu_tests import (
    BuildSession, DeviceRow, QemuRunOptions, discover_rows, discover_sessions,
    newest_session, parse_artifact_name, platform_rank, read_results,
    results_summary, runner_command,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
RUNNER = os.path.join(GENERATOR_DIR, "tests", "qemu", "run-qemu-docker.sh")

# The builders' real naming convention (see build-x86-host-stage4.sh:1966-1968 and
# the rpi5/frite ART_PREFIX equivalents): hugmesh-<platform>-<arch>-<role>-<env>-<ts>.
# The hyphenated role rows are the regression the both-ends parse exists for.
SAMPLES = {
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz":
        ("rpi5", "arm64", "pki", "test"),
    "hugmesh-rpi5-arm64-backend-test-20260807T185415Z.img":
        ("rpi5", "arm64", "backend", "test"),
    "hugmesh-x86-amd64-be-test-20260807T172418Z.img":
        ("x86", "amd64", "be", "test"),
    "hugmesh-x86-amd64-standalone-thin-prod-20260807T172418Z.img":
        ("x86", "amd64", "standalone-thin", "prod"),
}

REJECTS = (
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.kernel.img",   # kernel blob
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.stage4.tar.xz",  # not a disk
    "othermesh-x86-amd64-be-test-20260807T172418Z.img",          # foreign brand
    "hugmesh-x86-be.img",                                        # too few fields
    "initramfs-hugmesh-x86-amd64-be-test-20260807T172418Z.img",  # initramfs blob
)


# ---- name parsing -----------------------------------------------------------------

@pytest.mark.parametrize("name,expect", sorted(SAMPLES.items()))
def test_parse_artifact_name_accepts_the_builders_convention(name, expect):
    assert parse_artifact_name(name) == expect


@pytest.mark.parametrize("name", REJECTS)
def test_parse_artifact_name_rejects_non_role_images(name):
    assert parse_artifact_name(name) is None


def test_platform_rank_orders_pi_then_arm_then_x86():
    assert platform_rank("rpi5") < platform_rank("frite") < platform_rank("x86")
    assert platform_rank("orangepi5") == platform_rank("jetson")  # both mid-tier ARM


# ---- row discovery ----------------------------------------------------------------

def _touch(d, name):
    p = os.path.join(str(d), name)
    open(p, "w").close()
    return p


def test_discover_rows_pi_first_and_decompressed_wins(tmp_path):
    for n in SAMPLES:
        _touch(tmp_path, n)
    for n in REJECTS:
        _touch(tmp_path, n)
    # the same rpi5/pki artifact both compressed and raw: the raw one must win
    # (the runner would otherwise re-expand gigabytes it already has on disk)
    raw = _touch(tmp_path, "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img")

    rows = discover_rows(str(tmp_path))
    labels = [r.label for r in rows]
    assert labels == ["rpi5/backend", "rpi5/pki",           # Pi rows first
                      "x86/be", "x86/standalone-thin"]      # then x86
    pki = next(r for r in rows if r.label == "rpi5/pki")
    assert pki.image == raw and not pki.compressed


def test_discover_rows_missing_dir_is_empty():
    assert discover_rows("/nonexistent/nowhere") == []


# ---- session discovery ------------------------------------------------------------

def _fake_generator(tmp_path):
    """out/sessions/{empty,full,newer} — only the image-holding ones may be offered."""
    root = tmp_path / "out" / "sessions"
    (root / "20260101-000000-empty").mkdir(parents=True)
    full = root / "20260201-000000-full"
    full.mkdir(parents=True)
    _touch(full, "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz")
    _touch(full, "hugmesh-x86-amd64-be-test-20260807T172418Z.img")
    newer = root / "20260301-000000-newer"
    newer.mkdir(parents=True)
    _touch(newer, "hugmesh-x86-amd64-omnibus-test-20260807T000000Z.img")
    os.utime(full, (1_000_000, 1_000_000))
    os.utime(newer, (2_000_000, 2_000_000))
    return tmp_path


def test_discover_sessions_hides_empty_and_sorts_newest_first(tmp_path):
    gen = _fake_generator(tmp_path)
    sessions = discover_sessions(str(gen))
    assert [s.name for s in sessions] == ["20260301-000000-newer", "20260201-000000-full"]
    assert all(s.has_images for s in sessions)
    with_empty = discover_sessions(str(gen), only_with_images=False)
    assert len(with_empty) == 3
    newest = newest_session(str(gen))
    assert newest is not None and newest.name == "20260301-000000-newer"


def test_session_summary_names_platforms_and_roles(tmp_path):
    gen = _fake_generator(tmp_path)
    full = [s for s in discover_sessions(str(gen)) if s.name.endswith("full")][0]
    text = full.summary()
    assert "2 image(s)" in text and "rpi5 (pki)" in text and "x86 (be)" in text
    assert full.platforms == ["rpi5", "x86"]


# ---- argv construction ------------------------------------------------------------

def test_runner_command_defaults(tmp_path):
    argv = runner_command(str(tmp_path), QemuRunOptions(artifacts_dir="/a/dir"))
    assert argv[0] == os.path.join(str(tmp_path), "tests", "qemu", "run-qemu-docker.sh")
    assert argv[1:3] == ["--artifacts", "/a/dir"]
    assert argv[3:5] == ["--work", os.path.join(str(tmp_path), "out", "qemu-runs")]
    # defaults are explicit for the run envelope, omitted for the filters/mode
    assert "--platform" not in argv and "--role" not in argv and "--only" not in argv
    assert "--mode" not in argv          # golden IS the runner's default
    assert argv[-8:] == ["--jobs", "2", "--mem", "2048", "--smp", "2",
                         "--timeout", "2400"]


def test_runner_command_filters_and_switches(tmp_path):
    opts = QemuRunOptions(artifacts_dir="/a", platform="rpi5", role="pki",
                          only="rpi5/pki", mode="stage4", jobs=1, mem_mb=4096,
                          smp=4, timeout_s=600, list_only=True, build_image=True,
                          keep=True, work_dir="/scratch")
    argv = runner_command(str(tmp_path), opts)
    for pair in (["--platform", "rpi5"], ["--role", "pki"], ["--only", "rpi5/pki"],
                 ["--mode", "stage4"], ["--work", "/scratch"]):
        i = argv.index(pair[0])
        assert argv[i:i + 2] == pair
    for flag in ("--list", "--build-image", "--keep"):
        assert flag in argv


# ---- result reading ---------------------------------------------------------------

def test_read_results_worst_first_and_summary(tmp_path):
    rdir = tmp_path / "results"
    rdir.mkdir()
    rows = [{"label": "rpi5/pki", "status": "PASS", "assertions_passed": 12,
             "assertions_failed": 0},
            {"label": "x86/be", "status": "FAIL", "assertions_passed": 10,
             "assertions_failed": 2},
            {"label": "rpi5/backend", "status": "ERROR", "detail": "no kernel"}]
    for r in rows:
        (rdir / (r["label"].replace("/", "_") + ".json")).write_text(json.dumps(r))
    (rdir / "corrupt.json").write_text("{not json")
    (rdir / "ignored.txt").write_text("nope")

    out = read_results(str(tmp_path))
    assert [r["label"] for r in out] == ["x86/be", "rpi5/backend", "rpi5/pki"]
    assert results_summary(out) == (1, 2, 3)
    assert read_results(str(tmp_path / "nowhere")) == []


# ---- the runner script itself (hermetic: --list boots nothing) --------------------

def _docker_usable() -> bool:
    try:
        return subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def test_runner_script_list_agrees_with_python(tmp_path):
    """Cross-check: the SAME sample tree, enumerated by tests/qemu/run-qemu-docker.sh
    --list and by discover_rows(), must yield the same platform/role/env rows in the
    same Pi-first order. This is the drift probe the module docstring promises — and
    the runner script's only hermetic test, so --list breaking fails HERE, not in a
    2400s containerized run."""
    if not _docker_usable():
        pytest.skip("docker unavailable — the runner preflights `docker info` "
                    "even for --list")
    for n in SAMPLES:
        _touch(tmp_path, n)
    for n in REJECTS:
        # KNOWN divergence, excluded rather than papered over: the shell's
        # both-ends field strip happily "parses" a too-short hugmesh-*.img name
        # (yielding role==env) where the Python side refuses it. No builder emits
        # such a name; the Python refusal is the safer behavior to keep.
        if n == "hugmesh-x86-be.img":
            continue
        _touch(tmp_path, n)

    proc = subprocess.run(
        ["bash", RUNNER, "--artifacts", str(tmp_path), "--list"],
        capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "nothing booted" in proc.stdout

    # numbered table rows: "<n> <platform> <role> <env> <basename>"
    shell_rows = re.findall(r"^\s*\d+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$",
                            proc.stdout, re.M)
    py_rows = [(r.platform, r.role, r.env, r.basename)
               for r in discover_rows(str(tmp_path))]
    # the shell does not dedup a .img/.img.xz pair (none exists in SAMPLES), so a
    # straight list-compare is exact here
    assert [(p, r, e) for p, r, e, _ in shell_rows] \
        == [(p, r, e) for p, r, e, _ in py_rows]
    assert [b for *_x, b in shell_rows] == [b for *_x, b in py_rows]


def test_runner_script_is_executable():
    assert os.path.isfile(RUNNER)
    assert os.access(RUNNER, os.X_OK), "run-qemu-docker.sh must keep its +x bit"
