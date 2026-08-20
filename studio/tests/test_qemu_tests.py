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


def test_session_summary_names_the_roles_under_each_platform(tmp_path):
    """``summary()`` is the picker line (gui/pages/_emulation_common.py builds the
    session combo out of it), so it is the ONLY place an operator sees WHAT a
    session can boot before choosing it. A line that says "2 image(s): rpi5; x86"
    cannot be told apart from a different session with the same platform spread,
    which is exactly how the wrong session gets picked.

    Three platforms on purpose: ``frite`` sorts BEFORE ``rpi5`` alphabetically but
    AFTER it by ``platform_rank`` (Pi first, other ARM next, x86 last), so the
    positional assertion below fails if the grouping ever falls back to plain
    name order instead of the boot order the runner will actually use.
    """
    sess = tmp_path / "out" / "sessions" / "20260807-071119-5c1ccb"
    sess.mkdir(parents=True)
    _write(str(sess),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
           "hugmesh-rpi5-arm64-backend-test-20260807T185415Z.img.xz",
           "hugmesh-frite-arm64-be-test-20260807T190000Z.img.xz",
           "hugmesh-x86-amd64-standalone-thin-prod-20260807T172418Z.img")

    session, = qt.discover_sessions(str(tmp_path))
    text = session.summary()

    assert "4 image(s)" in text
    # roles, grouped under their platform — not a bare platform list, and not one
    # flat role list that loses which device each role belongs to
    assert "rpi5 (backend, pki)" in text
    assert "frite (be)" in text
    assert "x86 (standalone-thin)" in text
    # ...in platform_rank order, which is NOT alphabetical here
    assert text.index("rpi5 (") < text.index("frite (") < text.index("x86 (")
    # .platforms stays the plain alphabetical set the pickers filter on
    assert session.platforms == ["frite", "rpi5", "x86"]


# ---- session completeness ------------------------------------------------------------
# The shape of out/sessions/20260819-125930-89bb8e: a mesh build that ABORTED with
# 1 bootable image where 4 per-image build logs (and a 7-image manifest) say more
# was intended. Offering it as "the session" silently emulates a fraction of the
# configured mesh, so pickers badge it and the default selection skips it.

def _partial_session(root, name, *, images, logs=(), manifest_images=0, mtime=None):
    sess = root / "out" / "sessions" / name
    sess.mkdir(parents=True)
    _write(str(sess), *images)
    for log in logs:
        (sess / log).write_text("…")
    if manifest_images:
        (sess / qt.MESH_MANIFEST_NAME).write_text(json.dumps(
            {"format": 2, "images": [{"id": f"img{i}"} for i in range(manifest_images)]}))
    if mtime is not None:
        os.utime(sess, (mtime, mtime))
    return sess


def test_expected_image_count_prefers_build_logs_over_the_manifest(tmp_path):
    """A per-image log exists only for a build that STARTED, so the log count is
    what the run attempted — the aborted 08-19 session reads "1 of 4", not
    "1 of 7", because three manifest images never even began. The shared build.log
    is not a per-image log and must not count."""
    sess = _partial_session(
        tmp_path, "20260819-125930-89bb8e",
        images=["hugmesh-x86-amd64-pki-test-20260819T195951Z.img.xz"],
        logs=["build.log", "build-pki.x86.log", "build-pki.rpi5.log",
              "build-be.x86.log", "build-be.rpi5.log"],
        manifest_images=7)
    assert qt.expected_image_count(str(sess)) == 4
    session, = qt.discover_sessions(str(tmp_path))
    assert session.expected_images == 4
    assert session.is_partial
    assert session.completeness_badge() == "PARTIAL — 1 of 4 image(s)"
    assert "[PARTIAL — 1 of 4 image(s)]" in session.summary()


def test_expected_image_count_falls_back_to_the_manifest(tmp_path):
    """A builder that died before minting a single per-image log still declared its
    intent in the mesh manifest."""
    sess = _partial_session(
        tmp_path, "20260819-000000-dead00",
        images=["hugmesh-x86-amd64-pki-test-20260819T000000Z.img"],
        logs=["build.log"], manifest_images=3)
    assert qt.expected_image_count(str(sess)) == 3
    session, = qt.discover_sessions(str(tmp_path))
    assert session.is_partial and "1 of 3" in session.completeness_badge()


def test_sessions_without_intent_witnesses_read_complete(tmp_path):
    """No logs, no manifest: nothing can accuse the session of missing images, and
    a corrupt manifest is 'unknown', never a crash or a false PARTIAL."""
    sess = _partial_session(tmp_path, "20260101-000000-bare00",
                            images=["hugmesh-x86-amd64-pki-test-20260101T000000Z.img"])
    assert qt.expected_image_count(str(sess)) == 0
    (sess / qt.MESH_MANIFEST_NAME).write_text("{not json")
    assert qt.expected_image_count(str(sess)) == 0
    session, = qt.discover_sessions(str(tmp_path))
    assert not session.is_partial and session.completeness_badge() == ""


def test_default_session_is_the_newest_complete_one(tmp_path):
    """The newest session being an aborted build must not become the default: its
    images are individually runnable, but 'the whole mesh' from it is a fraction of
    what was configured. Only when EVERY session is partial does the newest partial
    win — runnable-with-a-badge beats nothing."""
    _partial_session(
        tmp_path, "20260810-000000-comple",
        images=["hugmesh-x86-amd64-pki-test-20260810T000000Z.img"],
        logs=["build-pki.x86.log"], mtime=1_000_000_000)
    _partial_session(
        tmp_path, "20260819-125930-89bb8e",
        images=["hugmesh-x86-amd64-pki-test-20260819T195951Z.img.xz"],
        logs=["build-pki.x86.log", "build-pki.rpi5.log",
              "build-be.x86.log", "build-be.rpi5.log"],
        mtime=2_000_000_000)
    # newest_session keeps its historical meaning: literally the newest.
    assert qt.newest_session(str(tmp_path)).name == "20260819-125930-89bb8e"
    assert qt.default_session(str(tmp_path)).name == "20260810-000000-comple"

    # All partial: the newest partial is still offered rather than nothing.
    import shutil as _shutil
    _shutil.rmtree(tmp_path / "out" / "sessions" / "20260810-000000-comple")
    assert qt.default_session(str(tmp_path)).name == "20260819-125930-89bb8e"
    assert qt.default_session(str(tmp_path / "nowhere")) is None


def test_manifest_and_log_spellings_match_their_authors():
    """qemu_tests spells the manifest/log names locally to stay import-light; the
    OWNING modules are worklist_driver (manifest) and build_sessions (logs). Drift
    in either direction silently turns every session into 'complete'."""
    from hugmesh_studio.core import build_sessions, worklist_driver
    assert qt.MESH_MANIFEST_NAME == worklist_driver.MANIFEST_NAME
    assert qt.SHARED_BUILD_LOG == build_sessions.LOG_NAME
    assert build_sessions.image_log_name("pki.x86") == \
        qt.IMAGE_LOG_PREFIX + "pki.x86" + qt.IMAGE_LOG_SUFFIX


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


def test_runner_command_defaults_the_work_dir_under_the_generator():
    """``--work`` is the one envelope flag with a computed default, and it is always
    emitted: the runner caches multi-GB decompressed images, per-row results and the
    device registry under it, and core/qemu_devices.py resolves saves against the
    SAME directory (its ``default_work_dir``). A drifted default does not fail — it
    quietly splits the run and the saves across two trees.
    """
    from hugmesh_studio.core import qemu_devices

    cmd = qt.runner_command("/gen", qt.QemuRunOptions())
    assert cmd[cmd.index("--work") + 1] == os.path.join("/gen", qt.DEFAULT_WORK_SUBDIR)
    assert cmd[cmd.index("--work") + 1] == qemu_devices.default_work_dir("/gen")
    # an explicit work dir still wins
    explicit = qt.runner_command("/gen", qt.QemuRunOptions(work_dir="/scratch"))
    assert explicit[explicit.index("--work") + 1] == "/scratch"


def test_runner_command_emits_every_row_filter():
    """--platform / --role / --only / --only-exact are four DIFFERENT ways to narrow
    the matrix, and each is silently ignorable: a filter that never reaches the argv
    boots the whole fan-out (hours of TCG guests) instead of the one row asked for.
    Absent from a default argv, verbatim when set.
    """
    default = qt.runner_command("/gen", qt.QemuRunOptions())
    for flag in ("--platform", "--role", "--only", "--only-exact"):
        assert flag not in default

    cmd = qt.runner_command("/gen", qt.QemuRunOptions(
        platform="rpi5", role="pki", only="rpi5/pki", only_exact="rpi5/pki"))
    assert cmd[cmd.index("--platform") + 1] == "rpi5"
    assert cmd[cmd.index("--role") + 1] == "pki"
    assert cmd[cmd.index("--only") + 1] == "rpi5/pki"
    assert cmd[cmd.index("--only-exact") + 1] == "rpi5/pki"


def test_runner_command_emits_mode_list_and_build_image():
    cmd = qt.runner_command("/gen", qt.QemuRunOptions(mode="stage4", list_only=True,
                                                      build_image=True, keep=True))
    assert cmd[cmd.index("--mode") + 1] == "stage4"
    assert "--list" in cmd and "--build-image" in cmd and "--keep" in cmd


def test_runner_command_emits_the_t1_knobs_only_when_asked():
    """--only-exact / --assert-timeout / --cache-max-gb / --extra-user are all
    non-default knobs: absent from a default argv (the shell stays the home of the
    defaults) and emitted verbatim when set."""
    default = qt.runner_command("/gen", qt.QemuRunOptions())
    for flag in ("--only-exact", "--assert-timeout", "--cache-max-gb", "--extra-user"):
        assert flag not in default

    cmd = qt.runner_command("/gen", qt.QemuRunOptions(
        only_exact="x86/be", assert_timeout_s=900, cache_max_gb=120,
        extra_users=("alice", "bob")))
    assert cmd[cmd.index("--only-exact") + 1] == "x86/be"
    assert cmd[cmd.index("--assert-timeout") + 1] == "900"
    assert cmd[cmd.index("--cache-max-gb") + 1] == "120"
    users = [cmd[i + 1] for i, a in enumerate(cmd) if a == "--extra-user"]
    assert users == ["alice", "bob"]


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


def test_read_results_scopes_to_this_runs_labels(tmp_path):
    """Rows from an earlier run must not be reported as this run's outcome.

    The results dir lives under the persistent work dir (it caches multi-GB
    decompressed images and is never wiped), so it accumulates every row ever
    run. Reading it wholesale showed a one-image session as an 8-device matrix,
    mixing artifacts and days.
    """
    results = tmp_path / "results"
    results.mkdir()
    for name, label, status in (("rpi5_pki.json", "rpi5/pki", "PASS"),
                                ("x86_be.json", "x86/be", "FAIL"),
                                ("x86_omnibus.json", "x86/omnibus", "PASS")):
        (results / name).write_text(json.dumps({"label": label, "status": status}))

    scoped = qt.read_results(str(tmp_path), labels=["rpi5/pki"])
    assert [r["label"] for r in scoped] == ["rpi5/pki"]
    # No labels = legacy whole-dir read, still supported for ad-hoc inspection.
    assert len(qt.read_results(str(tmp_path))) == 3
    # An empty label list is "this run had no rows", NOT "show me everything".
    assert qt.read_results(str(tmp_path), labels=[]) == []


def test_result_filename_matches_the_runner(tmp_path):
    """Mirrors RESULT_JSON in docker-entrypoint.sh: label -> <platform>_<role>.json."""
    assert qt.result_filename("rpi5/pki") == "rpi5_pki.json"
    assert qt.result_filename("x86/standalone-thin") == "x86_standalone-thin.json"


def test_read_results_empty_without_dir(tmp_path):
    assert qt.read_results(str(tmp_path)) == []


#: The two cross-checks below shell out to the real script; both carry this mark.
#: It used to sit on ``_shell_rows`` instead, where pytest never reads it — a mark
#: on a plain helper is inert, so a missing runner ERRORed the tests it was meant
#: to skip.
_needs_runner = pytest.mark.skipif(not os.path.exists(RUNNER),
                                   reason="runner script not present")


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


@_needs_runner
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


@_needs_runner
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


def test_runner_script_is_executable():
    """run-qemu-docker.sh must keep its +x bit.

    The Studio spawns it as argv[0] (``QemuRunner.run`` -> ``subprocess.Popen``,
    and every ``*_argv`` builder in core/emulation.py and core/qemu_devices.py puts
    the script path first), NOT as ``bash <script>``. Strip the mode bit and every
    one of those becomes OSError -> "could not start the runner", at the moment an
    operator tries to boot a device.

    Nothing else in the suite can see this: the two ``--list`` cross-checks above
    invoke it through ``bash``, which runs a non-executable file happily. A lost
    mode bit is also invisible in a review diff and survives a merge, so the check
    covers BOTH the file on disk and the mode git has recorded — a commit that drops
    it to 100644 leaves this developer's checkout executable and only breaks on the
    next fresh clone.
    """
    assert os.path.isfile(RUNNER), f"missing runner: {RUNNER}"
    assert os.access(RUNNER, os.X_OK), "run-qemu-docker.sh must keep its +x bit"
    with open(RUNNER, "rb") as fh:
        assert fh.read(2) == b"#!", "run-qemu-docker.sh must keep its shebang"

    try:
        tracked = subprocess.run(
            ["git", "ls-files", "-s", "--", qt.RUNNER_SCRIPT],
            cwd=GENERATOR_DIR, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:   # pragma: no cover
        pytest.skip(f"git unavailable: {exc}")
    if tracked.returncode != 0 or not tracked.stdout.strip():   # pragma: no cover
        pytest.skip("not a git checkout")
    assert tracked.stdout.split()[0] == "100755", \
        f"git has run-qemu-docker.sh as mode {tracked.stdout.split()[0]}, not 100755"


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not installed")
def test_docker_available_returns_a_reason():
    ok, why = qt.docker_available()
    assert isinstance(ok, bool) and why


def test_docker_available_async_probes_off_thread(monkeypatch):
    """The pages froze 15s in initializePage running docker_available inline. The
    async variant must return a started daemon thread immediately, run the SAME
    probe with the SHORT timeout, and deliver (ok, reason) through the callback —
    including when the probe itself blows up (a mute probe thread is a page that
    says 'checking…' forever)."""
    import threading

    seen = {}

    def _fake_available(timeout_s=15.0):
        seen["timeout"] = timeout_s
        return False, "no daemon here"

    monkeypatch.setattr(qt, "docker_available", _fake_available)
    delivered = []
    done = threading.Event()

    def _cb(ok, why):
        delivered.append((ok, why))
        done.set()

    thread = qt.docker_available_async(_cb)
    assert thread.daemon
    assert done.wait(10), "the probe callback never fired"
    thread.join(10)
    assert delivered == [(False, "no daemon here")]
    assert seen["timeout"] == qt.DOCKER_PROBE_TIMEOUT_S
    assert qt.DOCKER_PROBE_TIMEOUT_S < 15   # the whole point: shorter than inline

    def _boom(timeout_s=15.0):
        raise RuntimeError("docker exploded")

    monkeypatch.setattr(qt, "docker_available", _boom)
    delivered.clear()
    done.clear()
    qt.docker_available_async(_cb).join(10)
    assert delivered and delivered[0][0] is False
    assert "docker exploded" in delivered[0][1]
