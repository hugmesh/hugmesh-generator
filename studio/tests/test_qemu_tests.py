"""Hermetic tests for core/qemu_tests.py — the containerized emulated-device driver.

Everything here runs WITHOUT docker, qemu, or a single real image: the module's job is
resolution (which artifacts imply which device rows) and argv construction, both of
which are pure. The one thing that cannot be faked — that the shell runner parses
artifact names the same way this module does — is pinned by
``test_shell_and_python_agree_on_row_discovery``, which runs the real script's
``--list`` over a fabricated artifacts dir.
"""
import json
import os
import shutil
import subprocess

import pytest

from hugmesh_studio.core import qemu_tests as qt

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
RUNNER = os.path.join(GENERATOR_DIR, qt.RUNNER_SCRIPT)

#: Real artifact names from the 2026-08-07 build session, plus the hyphenated-role and
#: decoy cases the parser has to survive.
_REAL_NAMES = [
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
    "hugmesh-rpi5-arm64-backend-test-20260807T185415Z.img.xz",
    "hugmesh-rpi5-arm64-frontend-test-20260807T205908Z.img.xz",
    "hugmesh-x86-amd64-be-test-20260807T172418Z.img.xz",
    "hugmesh-x86-amd64-omnibus-test-20260807T213853Z.img.xz",
]


def test_parse_artifact_name_real_names():
    assert qt.parse_artifact_name(
        "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz") == ("rpi5", "arm64", "pki", "test")
    assert qt.parse_artifact_name(
        "hugmesh-x86-amd64-omnibus-test-20260807T213853Z.img") == ("x86", "amd64", "omnibus", "test")


def test_parse_artifact_name_keeps_hyphenated_roles():
    """standalone-thin must not truncate to 'standalone'.

    The role sits between the arch and the trailing <env>-<stamp>, so it is parsed
    from both ends; a naive split('-')[3] loses everything after the first hyphen.
    """
    assert qt.parse_artifact_name(
        "hugmesh-x86-amd64-standalone-thin-prod-20260807T213853Z.img") == (
            "x86", "amd64", "standalone-thin", "prod")
    assert qt.parse_artifact_name(
        "hugmesh-x86-amd64-standalone-unaffiliated-test-20260101T000000Z.img.xz") == (
            "x86", "amd64", "standalone-unaffiliated", "test")


@pytest.mark.parametrize("name", [
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.stage4.tar.xz",  # not a disk
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.iso",            # not a disk
    "kernel_2712.img",                                             # kernel blob
    "hugmesh-rpi5-arm64-pki-test-initramfs.img",                   # initramfs blob
    "some-third-party.img",                                        # not ours
    "hugmesh-too-short.img",                                       # missing fields
])
def test_parse_artifact_name_rejects_non_rows(name):
    assert qt.parse_artifact_name(name) is None


def test_platform_rank_orders_pi_first_then_arm_then_x86():
    assert qt.platform_rank("rpi5") < qt.platform_rank("orangepi5")
    assert qt.platform_rank("orangepi5") < qt.platform_rank("x86")


def _write(dirpath, *names):
    for n in names:
        with open(os.path.join(dirpath, n), "w", encoding="utf-8") as fh:
            fh.write("x")


def test_discover_rows_orders_pi_first(tmp_path):
    _write(str(tmp_path), *_REAL_NAMES)
    rows = qt.discover_rows(str(tmp_path))
    assert [r.label for r in rows][:3] == ["rpi5/backend", "rpi5/frontend", "rpi5/pki"]
    assert {r.label for r in rows[3:]} == {"x86/be", "x86/omnibus"}


def test_discover_rows_prefers_decompressed_over_xz(tmp_path):
    """A row must not re-expand 20GB it already has on disk."""
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img")
    rows = qt.discover_rows(str(tmp_path))
    assert len(rows) == 1
    assert not rows[0].compressed
    assert rows[0].image.endswith(".img")


def test_discover_rows_picks_newest_build_of_a_role(tmp_path):
    """A rebuilt role must supersede its predecessor, not lose to it.

    Entries are enumerated in sorted-name order, i.e. OLDEST first, so the old
    keep-the-incumbent rule pinned the row to the stale artifact: rebuilding a
    role produced a green run whose bits were never tested.
    """
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img",
           "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img")
    rows = qt.discover_rows(str(tmp_path))
    assert len(rows) == 1
    assert rows[0].basename == "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img"


def test_discover_rows_newest_wins_even_when_older_is_decompressed(tmp_path):
    """Freshness outranks the re-expansion shortcut.

    The stale build is the convenient one here — already decompressed, no xz
    pass needed — and picking it would still be wrong.
    """
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img",
           "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img.xz")
    rows = qt.discover_rows(str(tmp_path))
    assert len(rows) == 1
    assert rows[0].stamp == "20260814T160000Z"
    assert rows[0].compressed


def test_discover_rows_empty_for_missing_dir(tmp_path):
    assert qt.discover_rows(str(tmp_path / "nope")) == []


def test_discover_sessions_hides_empty_and_sorts_newest_first(tmp_path):
    sessions_root = tmp_path / "out" / "sessions"
    empty = sessions_root / "20260101-000000-aaaaaa"
    full = sessions_root / "20260807-071119-5c1ccb"
    for d in (empty, full):
        d.mkdir(parents=True)
    _write(str(full), *_REAL_NAMES)
    # A session dir is minted when a build STARTS, so empty ones are common.
    os.utime(full, (2_000_000_000, 2_000_000_000))
    os.utime(empty, (1_000_000_000, 1_000_000_000))

    sessions = qt.discover_sessions(str(tmp_path))
    assert [s.name for s in sessions] == [full.name]
    assert qt.newest_session(str(tmp_path)).name == full.name
    assert sessions[0].platforms == ["rpi5", "x86"]
    assert "5 image(s)" in sessions[0].summary()


def test_discover_sessions_can_include_empty(tmp_path):
    (tmp_path / "out" / "sessions" / "empty").mkdir(parents=True)
    sessions = qt.discover_sessions(str(tmp_path), only_with_images=False)
    assert [s.name for s in sessions] == ["empty"]
    assert not sessions[0].has_images


def test_runner_command_defaults_and_filters():
    opts = qt.QemuRunOptions(artifacts_dir="/art", work_dir="/work", platform="rpi5",
                             jobs=3, mem_mb=4096, timeout_s=1800)
    cmd = qt.runner_command("/gen", opts)
    assert cmd[0] == os.path.join("/gen", qt.RUNNER_SCRIPT)
    assert cmd[cmd.index("--artifacts") + 1] == "/art"
    assert cmd[cmd.index("--platform") + 1] == "rpi5"
    assert cmd[cmd.index("--jobs") + 1] == "3"
    assert cmd[cmd.index("--mem") + 1] == "4096"
    assert cmd[cmd.index("--timeout") + 1] == "1800"
    # golden is the runner's own default; not emitting it keeps the preview readable
    # and lets a future default change live in one place (the shell script).
    assert "--mode" not in cmd
    assert "--list" not in cmd


def test_runner_command_emits_mode_list_and_build_image():
    cmd = qt.runner_command("/gen", qt.QemuRunOptions(mode="stage4", list_only=True,
                                                      build_image=True, keep=True))
    assert cmd[cmd.index("--mode") + 1] == "stage4"
    assert "--list" in cmd and "--build-image" in cmd and "--keep" in cmd


def test_read_results_sorts_failures_first(tmp_path):
    results = tmp_path / "results"
    results.mkdir()
    for label, status in (("rpi5_frontend", "PASS"), ("rpi5_pki", "FAIL"),
                          ("x86_fe", "ERROR")):
        (results / f"{label}.json").write_text(json.dumps({
            "label": label.replace("_", "/"), "status": status,
            "assertions_passed": 1, "assertions_failed": 0, "duration_s": 5}))
    got = qt.read_results(str(tmp_path))
    assert [r["status"] for r in got] == ["FAIL", "ERROR", "PASS"]
    assert qt.results_summary(got) == (1, 2, 3)


def test_read_results_survives_a_corrupt_file(tmp_path):
    """A half-written result must not blank the whole table."""
    results = tmp_path / "results"
    results.mkdir()
    (results / "good.json").write_text(json.dumps({"label": "a", "status": "PASS"}))
    (results / "bad.json").write_text("{not json")
    assert [r["label"] for r in qt.read_results(str(tmp_path))] == ["a"]


def test_read_results_empty_without_dir(tmp_path):
    assert qt.read_results(str(tmp_path)) == []


@pytest.mark.skipif(not os.path.exists(RUNNER), reason="runner script not present")
def _shell_rows(tmp_path) -> set[tuple[str, str]]:
    """(label, image basename) pairs from the real runner's --list."""
    proc = subprocess.run(
        ["bash", RUNNER, "--artifacts", str(tmp_path), "--work", str(tmp_path / "w"), "--list"],
        capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    rows = set()
    for line in proc.stdout.splitlines():
        parts = line.split()
        # rows render as: "<n> <platform> <role> <env> <image>"
        if len(parts) >= 5 and parts[0].isdigit():
            rows.add((f"{parts[1]}/{parts[2]}", parts[4]))
    return rows


def _py_rows(tmp_path) -> set[tuple[str, str]]:
    return {(r.label, r.basename) for r in qt.discover_rows(str(tmp_path))}


def test_shell_and_python_agree_on_row_discovery(tmp_path):
    """The shell runner and this module must select the SAME rows.

    They parse artifact names independently (bash in run-qemu-docker.sh, Python here),
    so drift in either direction would silently boot the wrong image for a row. This is
    the only test that can catch that, and it needs no docker: --list enumerates and
    exits before the image build or any container starts.

    The comparison includes the chosen IMAGE, not just the label. Comparing labels
    alone is what let the two implementations diverge unnoticed: both agreed there
    was one ``rpi5/pki`` row while disagreeing about which artifact it meant.
    """
    _write(str(tmp_path), *_REAL_NAMES)
    assert _shell_rows(tmp_path) == _py_rows(tmp_path)


def test_shell_and_python_agree_on_which_build_wins(tmp_path):
    """Parity under ambiguity: same role rebuilt, and one artifact in both forms.

    Six files collapse to two rows. Before the fix bash emitted all six and Python
    emitted two stale ones — agreeing on neither count nor content.
    """
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img",
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
           "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img",
           "hugmesh-x86-amd64-be-test-20260814T112817Z.img",
           "hugmesh-x86-amd64-be-test-20260814T112817Z.img.xz",
           "hugmesh-x86-amd64-be-test-20260801T090000Z.img")

    expected = {
        ("rpi5/pki", "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img"),
        ("x86/be", "hugmesh-x86-amd64-be-test-20260814T112817Z.img"),
    }
    assert _py_rows(tmp_path) == expected
    assert _shell_rows(tmp_path) == expected


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not installed")
def test_docker_available_returns_a_reason():
    ok, why = qt.docker_available()
    assert isinstance(ok, bool) and why
