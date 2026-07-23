"""ProgressPage (design 3.13) — the terminal build screen driven by WorklistDriver.

Drives the REAL page on Qt's offscreen platform with BuildDriver + gen-provision-keys mocked
(no real build runs), then flushes the worker thread's queued signals and asserts the page
lifecycle: one row per image, Finish gated until every row is terminal, failure-tolerant
continue (a failed image does not abort the rest), Stop-all, and the once-per-worklist footer
(mesh manifest + per-node key-zips).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import Domain, ImageConfig, User    # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo              # noqa: E402
from hugmesh_studio.core import worklist_driver as wd               # noqa: E402
from hugmesh_studio.core.worklist import (                         # noqa: E402
    WorklistConfig, WorklistEntry, synthesize)
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                     # noqa: E402
from hugmesh_studio.gui.pages.progress import _display_safe         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # ProgressPage now writes a tray build-status file; keep it out of the real
    # ~/.hugmesh during tests.
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


# A captured x86 builder stdout stream: ANSI-wrapped `==>` phase banners (design 2.9 says
# strip ANSI first) hitting the x86 phase table in order, plus the `>>> Emerging (K of M)`
# counters that refine the emerge phase. Feeding this through ProgressPage's real slots must
# advance the bar 0 -> ... -> 100 (100 at finalize) — the regression that pins "the bars
# actually advance for real build output" so the symptom can't silently return.
_A = "\x1b[1;36m"
_R = "\x1b[0m"
CAPTURED_X86_STREAM = [
    f"{_A}==> Rebranding baked config{_R}",
    "  writing /etc/os-release",
    f"{_A}==> Verifying prerequisites{_R}",
    "==> Preparing build directories",
    "==> Fetching amd64 hardened stage3 seed",
    "  stage3-amd64-hardened.tar.xz  250M  100%",
    "==> Verifying stage3 seed signature",
    "==> Extracting stage3",
    "==> Installing spec files",
    "==> Branding desktop image",
    "==> Staging egress VPN",
    "==> Restoring toolchain static libs",
    "==> Native emerge inside chroot",
    ">>> Emerging (1 of 8) sys-apps/foo-1.0",
    ">>> Emerging (4 of 8) sys-libs/bar-2.3",
    ">>> Emerging (8 of 8) app-misc/baz-0.9",
    "==> Installing mesh VPN",
    "==> Building Gentoo hardened kernel",
    "==> Cleaning sysroot",
    "==> Packaging stage4 tarball",
    "==> Building raw .img",
    "==> Building bootable LIVE ISO",
    "==> Building installer ISO",
]


def _install_replay_builddriver(monkeypatch, lines, code=0):
    """A fake BuildDriver whose run() replays a captured stdout stream through on_line —
    drives the REAL ProgressPage end-to-end (parse -> _apply_state -> QProgressBar)."""
    class ReplayBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            if on_line:
                for ln in lines:
                    on_line(ln)
            return code

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", ReplayBuildDriver)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


# ── fakes (no real build / key generation) ───────────────────────────────────────────
def _install_fake_builddriver(monkeypatch, codes=None, on_run=None):
    codes = codes or {}

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            if on_line:
                on_line(f"==> building {cfg.role}")
            if on_run:
                on_run(self, cfg)
            return codes.get(cfg.role, 0)

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def preflight_warnings(self, cfg, backend):
            # the REAL warning source (host_resources), so a test can pin the meminfo
            # snapshot and see the genuine aggregate/dedupe/log-line path fire
            from hugmesh_studio.core import host_resources
            return host_resources.low_memory_warnings(backend=backend)

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)


def _install_fake_genkeys(monkeypatch):
    class FakeProc:
        def __init__(self):
            self.stdout = iter(["generating keys"])

        def wait(self):
            return 0

    monkeypatch.setattr(wd.subprocess, "Popen", lambda cmd, **kw: FakeProc())


# ── helpers ───────────────────────────────────────────────────────────────────────────
def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _run_to_completion(qapp, page, timeout_ms=5000):
    """Join the worker thread, then pump the event loop so its queued signals land."""
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


def _mesh_base(tmp_path):
    b = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    b.domains = [Domain(name="acme.example", title="Acme")]
    b.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
    return b


def _mesh_worklist(tmp_path, roles=(("pki", "x86"), ("be", "rpi5"),
                                    ("rpi5-desktop", "rpi5"))):
    return WorklistConfig(base=_mesh_base(tmp_path),
                          entries=[WorklistEntry(role=r, platform=p) for r, p in roles])


def _prime(wiz, worklist, generate_keys=True):
    wiz.worklist = worklist
    wiz.build_backend = None
    wiz.generate_node_keys = generate_keys


# ── tests ──────────────────────────────────────────────────────────────────────────────
def test_finish_disabled_before_any_build_runs(wiz):
    page = _progress_page(wiz)
    assert not page.isComplete()          # nothing terminal yet -> Finish disabled


def test_no_worklist_completes_immediately(wiz):
    _prime(wiz, None)
    page = _progress_page(wiz)
    page.initializePage()
    assert page._rows == []
    assert page.isComplete()


def test_single_entry_standalone_run(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert len(page._rows) == 1
    assert page._rows[0].terminal
    assert page.isComplete()
    assert page.driver.results[0].status == "ok"
    assert page._rows[0].bar.value() == 100


def test_all_succeed_rows_terminal_and_finish_enabled(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    assert len(page._rows) == 3
    _run_to_completion(qapp, page)
    assert [page.driver.results[i].status for i in range(3)] == ["ok", "ok", "ok"]
    assert all(r.terminal for r in page._rows)
    assert page.isComplete()


def test_failure_is_tolerated_and_run_still_completes(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch, codes={"be": 3})   # middle image fails
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert [page.driver.results[i].status for i in range(3)] == ["ok", "failed", "ok"]
    assert all(r.terminal for r in page._rows)   # a failure does not abort the rest
    assert page.isComplete()                     # every row terminal -> Finish enabled


def test_stop_all_marks_rows_stopped(monkeypatch, qapp, wiz, tmp_path):
    box = {}

    def on_run(fake, cfg):
        if cfg.role == "pki":                    # stop the whole run during the first image
            box["page"]._stop_all()
    _install_fake_builddriver(monkeypatch, on_run=on_run)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    box["page"] = page
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.driver.results[0].status == "stopped"
    assert all(r.status == "stopped" for r in page.driver.results)
    assert page.isComplete()


def test_mesh_manifest_and_node_keys_footer(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    footer = page.footer.text()
    assert "manifest" in footer.lower()
    # the two node images generated key-zips; the desktop image did not.
    assert "pki.x86" in footer and "be.rpi5" in footer
    assert "rpi5-desktop.rpi5" not in footer


# ── progress-bar advance (the "no progress bars at the end" symptom) ──────────────────
def test_captured_stream_advances_bar_monotonically_to_100(wiz):
    """Drive the REAL ProgressPage slots with a captured x86 builder stream (the exact path
    the worker uses: _on_line -> ProgressParser.feed -> _apply_state -> QProgressBar) and
    assert the bar climbs monotonically 0 -> ... and reaches 100 at terminal. Race-free:
    calls the slots directly rather than through the worker thread."""
    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    seen = []
    for ln in CAPTURED_X86_STREAM:
        page._on_line(0, ln)
        # only record determinate values; an indeterminate (busy) bar has maximum 0.
        if page._rows[0].bar.maximum() == 100:
            seen.append(page._rows[0].bar.value())
    assert seen, "the bar never left indeterminate mode for real banner output"
    assert seen == sorted(seen), f"bar value regressed: {seen}"
    assert seen[0] == 0 and seen[-1] < 100          # never fakes 100 before finalize
    page._on_entry_done(0, 0)                        # exit 0 -> ok -> finalize -> 100
    assert page._rows[0].bar.value() == 100
    assert page._rows[0].terminal


def test_captured_stream_end_to_end_through_worker_reaches_100(monkeypatch, qapp, wiz, tmp_path):
    """Same stream, but end-to-end through the real _WorklistWorker QThread + queued signals
    (proves the thread wiring, not just the slots): the bar ends at 100."""
    _install_replay_builddriver(monkeypatch, CAPTURED_X86_STREAM, code=0)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.isComplete()
    assert page.driver.results[0].status == "ok"
    assert page._rows[0].bar.value() == 100
    assert page._rows[0].bar.maximum() == 100


def test_failed_row_leaves_indeterminate_busy_mode(wiz):
    """The real correctness fix: a failed/stopped row that never saw a phase banner (e.g. a
    broken-docker build) used to stay a perpetual busy spinner (range 0,0). It must become a
    stalled DETERMINATE bar instead — otherwise nothing ever reads as settled = the user's
    'no progress bars at the end'."""
    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._on_line(0, "docker: error while creating mount source path")   # no banner
    assert page._rows[0].bar.maximum() == 0          # honest indeterminate while running
    page._on_entry_done(0, 1)                        # exit 1 -> failed
    assert page._rows[0].bar.maximum() == 100        # taken OUT of busy mode
    assert page._rows[0].phase.text() == "FAILED"
    assert page._rows[0].terminal


def test_build_status_file_written_and_completes(monkeypatch, qapp, wiz, tmp_path):
    """The tray build-status channel: a run publishes a 'complete' status the tray polls."""
    from hugmesh_studio.gui.tray import read_build_status
    _install_replay_builddriver(monkeypatch, CAPTURED_X86_STREAM, code=0)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    status = read_build_status()
    assert status is not None
    assert status["state"] == "complete"
    assert status["percent"] == 100


def test_build_status_file_reports_error_on_failure(monkeypatch, qapp, wiz, tmp_path):
    from hugmesh_studio.gui.tray import read_build_status
    _install_replay_builddriver(monkeypatch, ["docker: no such image"], code=1)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    status = read_build_status()
    assert status is not None
    assert status["state"] == "error"


# ── OVERALL/TOTAL bar (a pure reader of _aggregate_percent) ───────────────────────────
def test_total_bar_exists_and_tracks_aggregate_percent(wiz):
    """The overall bar is IN ADDITION to the per-image PART bars and reads the SAME
    _aggregate_percent() the #339 tray badge uses — so it can never invent a second
    number or drift from the tray status file."""
    page = _progress_page(wiz)
    assert page.total_bar is not None and page.total_label is not None
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    for ln in CAPTURED_X86_STREAM:
        page._on_line(0, ln)
        if page.total_bar.maximum() == 100:      # determinate: must equal the aggregate
            assert page.total_bar.value() == page._aggregate_percent()
    page._on_entry_done(0, 0)                     # all ok -> overall 100, per-row 100
    assert page.total_bar.value() == 100
    assert page._rows[0].bar.value() == 100       # per-image PART bar preserved


def test_total_bar_advances_across_multiple_images(monkeypatch, qapp, wiz, tmp_path):
    """K-of-N overall progress: with 3 images the overall bar + label track the whole
    worklist, not a single image."""
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    assert "of 3" in page.total_label.text()      # N reflected before completion
    _run_to_completion(qapp, page)
    assert page.total_bar.value() == 100
    assert "done" in page.total_label.text().lower()


def test_flash_group_hidden_until_all_ok_and_window_is_left_alone(monkeypatch, qapp, wiz,
                                                                  tmp_path):
    """The post-build 'Flash to a device' group stays hidden until an all-ok run, and
    landing on the terminal page does NOT resize the window.

    This page used to ratchet the window up to >=1040x780 "for readability", which this
    test pinned. That ratchet was the second root cause of the wildly-resizing wizard:
    it only ever grew (so every page after stayed oversized) and it ignored the screen
    entirely — on a display smaller than 1040x780 it made the window bigger than the
    display, which is why the old assertion could not simply be kept. Readability is now
    a property of the wizard's screen-clamped default size (gui.wizard.medium_size), so
    the requirement is inverted: this page must leave the geometry exactly as it found
    it."""
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets", lambda: [])
    _install_replay_builddriver(monkeypatch, CAPTURED_X86_STREAM, code=0)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    before = wiz.size()
    page.initializePage()
    # (the progress fixture doesn't show() the wizard, so assert the explicit hidden flag)
    assert page.flash_group.isHidden()            # never before completion
    assert wiz.size() == before, "the terminal page resized the window (the old ratchet)"
    _run_to_completion(qapp, page)
    assert page.flash_group.isHidden()             # no targets attached -> stays hidden
    assert wiz.size() == before                    # and it stays put across the build


def test_flash_group_reveals_on_ok_with_a_fake_target(monkeypatch, qapp, wiz, tmp_path):
    """With a (stubbed) attached target, an all-ok build reveals the flash dropdown and
    the Flash argv targets flash-disk.sh with SAFE args — no real dd is invoked."""
    from hugmesh_studio.core.flash_targets import FlashTarget
    fake = FlashTarget(path="/dev/sdz", size=16 * (1 << 30), model="Test SD",
                       transport="usb", removable=True, kind="usb")
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets", lambda: [fake])
    _install_replay_builddriver(monkeypatch, CAPTURED_X86_STREAM, code=0)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert not page.flash_group.isHidden()         # revealed on an all-ok run
    assert page.flash_combo.count() == 1
    argv = page._flash_argv_for(fake)
    assert argv[-1] == "/dev/sdz" and "--no-confirm" in argv
    assert any(a.endswith("scripts/flash-disk.sh") for a in argv)
    assert "dd" not in argv                        # never re-implemented here


def test_failed_build_never_reveals_flash_group(monkeypatch, qapp, wiz, tmp_path):
    from hugmesh_studio.core.flash_targets import FlashTarget
    fake = FlashTarget(path="/dev/sdz", size=16 * (1 << 30), model="Test SD",
                       transport="usb", removable=True, kind="usb")
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets", lambda: [fake])
    _install_replay_builddriver(monkeypatch, ["docker: no such image"], code=1)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.flash_group.isHidden()             # a failed build never offers to flash


def test_total_bar_chunk_resets_to_blue_on_a_second_run(monkeypatch, qapp, wiz, tmp_path):
    """A first all-ok run turns the overall chunk GREEN; a second build on the SAME page
    instance (initializePage -> _reset) must put it back to BLUE, so the new run never
    renders green (or stays green under an 'Overall FAILED' label)."""
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets", lambda: [])
    _install_replay_builddriver(monkeypatch, CAPTURED_X86_STREAM, code=0)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert "#188038" in page.total_bar.styleSheet()   # green after an all-ok run
    page._reset()                                   # second run on the same instance
    assert "#1a73e8" in page.total_bar.styleSheet()   # back to blue
    assert "#188038" not in page.total_bar.styleSheet()


# ── auto-flash TOCTOU identity guard ─────────────────────────────────────────────────
def test_auto_flash_skips_when_device_identity_changed(monkeypatch, wiz):
    """The device combo is captured at build start, but a build can run for hours and
    /dev/sdX is enumeration-order dependent. If a DIFFERENT removable disk takes the same
    node before completion, auto-flash must NOT write it (no human at the write): the
    re-scanned target's size/model must match the stashed identity."""
    from hugmesh_studio.core.flash_targets import FlashTarget
    selected = FlashTarget("/dev/sdb", 16 * (1 << 30), "SanDisk Ultra", "usb", True, "usb")
    swapped = FlashTarget("/dev/sdb", 32 * (1 << 30), "Some Other Stick", "usb", True, "usb")
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: [swapped])          # same /dev path, different device
    page = _progress_page(wiz)
    wiz.flash_after = (True, selected)
    started = []
    page._start_flash = lambda t: started.append(t)  # type: ignore[assignment]
    page._maybe_auto_flash()
    assert started == []                            # refused: identity changed
    assert "identity changed" in page.log.toPlainText()


def test_auto_flash_fires_when_identity_matches(monkeypatch, wiz):
    from hugmesh_studio.core.flash_targets import FlashTarget
    selected = FlashTarget("/dev/sdb", 16 * (1 << 30), "SanDisk Ultra", "usb", True, "usb")
    monkeypatch.setattr("hugmesh_studio.core.flash_targets.list_targets",
                        lambda: [FlashTarget("/dev/sdb", 16 * (1 << 30), "SanDisk Ultra",
                                             "usb", True, "usb")])
    page = _progress_page(wiz)
    wiz.flash_after = (True, selected)
    started = []
    page._start_flash = lambda t: started.append(t)  # type: ignore[assignment]
    page._maybe_auto_flash()
    assert len(started) == 1 and started[0].path == "/dev/sdb"


# ── nested, drillable job/stage tree (GitHub-Actions style) ───────────────────────────
_RED = "#c5221f"
_GREEN = "#188038"


def _install_streaming_builddriver(monkeypatch, lines, codes=None, default=0):
    """A BuildDriver that replays a captured banner stream per image and returns a
    per-role (or default) exit code — drives the REAL ProgressPage nested tree end to end."""
    codes = codes or {}

    class StreamDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            if on_line:
                for ln in lines:
                    on_line(ln)
            return codes.get(cfg.role, default)

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", StreamDriver)


def _x86_worklist(tmp_path, roles=("pki", "be", "fe")):
    return WorklistConfig(base=_mesh_base(tmp_path),
                          entries=[WorklistEntry(role=r, platform="x86") for r in roles])


def test_job_tree_lists_all_images_up_front_and_advances_states(monkeypatch, qapp, wiz,
                                                                tmp_path):
    """(a) the job list is fully populated the moment initializePage runs (GH-Actions lists
    every job up front) and each job reaches passed/failed as the driver dispatches it."""
    _install_streaming_builddriver(monkeypatch, CAPTURED_X86_STREAM, codes={"be": 3})
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _x86_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    assert page.tree.topLevelItemCount() == 3           # all jobs listed immediately
    assert all(page._rows[i].job_item is not None for i in range(3))
    _run_to_completion(qapp, page)
    assert [page.driver.results[i].status for i in range(3)] == ["ok", "failed", "ok"]
    # the passed jobs are green, the failed job is red — in the tree item itself
    assert page._rows[0].job_item.foreground(0).color().name() == _GREEN
    assert page._rows[1].job_item.foreground(0).color().name() == _RED
    assert page._rows[2].job_item.foreground(0).color().name() == _GREEN


def test_stages_appear_under_job_from_phase_table_as_banners_cross(wiz):
    """(b) each job's children are the honest phase-table stages, and they advance
    done/running as the parser crosses the `==> ` banners (no invented taxonomy)."""
    from hugmesh_studio.core.progress_parse import platform_phases
    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    job = page._rows[0].job_item
    assert job.childCount() == len(platform_phases("x86"))     # all stages present, pending
    for ln in CAPTURED_X86_STREAM[:6]:
        page._on_line(0, ln)
    states = [s.state for s in page._rows[0].tracker.stages]
    assert "done" in states and "running" in states            # crossed -> done, current -> running
    assert page._rows[0].stage_items[0].text(1) in ("done", "skipped", "running")


def test_clicking_a_stage_shows_that_stage_log_slice(wiz):
    """(c) drilling into a stage loads only THAT stage's captured log slice; the job node
    still shows the full raw log."""
    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    for ln in CAPTURED_X86_STREAM:
        page._on_line(0, ln)
    tracker = page._rows[0].tracker
    ej = next(j for j, s in enumerate(tracker.stages)
              if any("Emerging" in ln for ln in s.lines))       # the emerge stage
    page._on_item_clicked(page._rows[0].stage_items[ej])
    text = page.log.toPlainText()
    assert "Emerging" in text                                   # the stage's own lines
    assert "stage3-amd64" not in text                           # NOT the whole job log
    assert "▸" in page.log_header.text()                        # header retitled to the stage
    # clicking the JOB node shows the full raw log (nothing is lost)
    page._on_item_clicked(page._rows[0].job_item)
    assert "stage3-amd64" in page.log.toPlainText()
    assert "Emerging" in page.log.toPlainText()


def test_failed_run_no_stage_renders_green_and_page_stays_responsive(monkeypatch, qapp,
                                                                     wiz, tmp_path):
    """(d)+(e) a build that fails partway reds its running stage and NEVER paints a
    pending/skipped stage green; and the page settles (isComplete) — proof the GUI thread
    never blocked on the build (no freeze)."""
    partial = CAPTURED_X86_STREAM[:13]                          # stops mid-emerge
    _install_streaming_builddriver(monkeypatch, partial, default=1)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.isComplete()                                    # settled -> main thread stayed live
    assert page.driver.results[0].status == "failed"
    row = page._rows[0]
    fj = row.tracker.failed_index()
    assert fj is not None
    assert row.stage_items[fj].foreground(0).color().name() == _RED
    # trailing stages stay pending (never fabricated done/green)
    assert all(s.state == "pending" for s in row.tracker.stages[fj + 1:])
    for s, item in zip(row.tracker.stages, row.stage_items):
        if s.state in ("pending", "skipped", "stopped"):
            assert item.foreground(0).color().name() != _GREEN   # neutral, never green


def test_next_failure_cycles_across_failed_images(monkeypatch, qapp, wiz, tmp_path):
    """(d) the Next-failure affordance cycles through every failed job, expanding it and
    loading its failing stage's log — GH-Actions failure list."""
    _install_streaming_builddriver(monkeypatch, CAPTURED_X86_STREAM,
                                   codes={"pki": 2, "fe": 5})
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _x86_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.next_fail_btn.isEnabled()
    assert len(page._failures) == 2
    seen = []
    for _ in range(2):
        page._next_failure()
        i, j = page._failures[page._fail_ptr]
        seen.append(i)
        row = page._rows[i]
        item = row.job_item if j is None else row.stage_items[j]
        assert page.tree.currentItem() is item                 # landed on the failed node
        if j is not None:
            assert row.stage_items[j].foreground(0).color().name() == _RED
    assert set(seen) == {0, 2}                                  # both failed images visited


def test_pre_banner_failure_reds_job_with_no_failed_child_stage(wiz):
    """#339 honesty: a build that dies before any banner (broken docker) has NO running
    stage, so no child stage is faked-failed — the JOB itself goes red and its drill-down
    is the raw log where the error actually is; the failure is still navigable."""
    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._on_line(0, "docker: error while creating mount source path")   # no banner
    page._on_entry_done(0, 1)
    row = page._rows[0]
    assert row.job_item.foreground(0).color().name() == _RED             # JOB is red
    assert row.tracker.failed_index() is None                           # no faked stage
    assert all(s.state == "pending" for s in row.tracker.stages)
    assert page._failures == [(0, None)]                               # navigable, points at the job
    assert page.next_fail_btn.isEnabled()
    assert "mount source path" in page.log.toPlainText()               # focus = the raw log


def test_stopping_a_running_image_settles_its_stage_neutral_not_red(monkeypatch, qapp,
                                                                    wiz, tmp_path):
    """A user Stop of a RUNNING image: proc.wait() returns the killed process's nonzero code
    (e.g. 143/SIGTERM) while the driver records res.status='stopped'. The currently-running
    STAGE must settle NEUTRAL (grey 'stopped') under a grey STOPPED job — never red FAILED.
    Before the fix the raw 143 reached tracker.finalize and painted the active stage red,
    contradicting the StageTracker cancel contract and telling the user a *cancelled* build
    'failed'."""
    box = {}
    banners = CAPTURED_X86_STREAM[:13]              # advance into the running emerge stage

    class StopMidStageDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            if on_line:
                for ln in banners:
                    on_line(ln)
            if cfg.role == "pki":                   # user hits Stop while this image runs
                box["page"]._stop_all()
                return 143                          # killed process exit code (SIGTERM)
            return 0

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", StopMidStageDriver)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _x86_worklist(tmp_path))
    page = _progress_page(wiz)
    box["page"] = page
    page.initializePage()
    _run_to_completion(qapp, page)

    row = page._rows[0]
    assert page.driver.results[0].status == "stopped"          # driver saw a user cancel
    assert row.job_item.foreground(0).color().name() != _RED   # JOB neutral (grey), not red
    # the running stage settled NEUTRAL (stopped) — NOT red FAILED
    assert row.tracker.failed_index() is None
    assert not any(s.state == "failed" for s in row.tracker.stages)
    assert any(s.state == "stopped" for s in row.tracker.stages)
    for s, item in zip(row.tracker.stages, row.stage_items):
        assert item.foreground(0).color().name() != _RED       # no red stage anywhere
    # a Stop is not a failure -> no failure-navigation entry is fabricated
    assert page._failures == []
    assert not page.next_fail_btn.isEnabled()


# ── low-memory preflight WARNING at dispatch (2026-07-15 freeze guard) ─────────────────
def test_low_memory_warning_logged_but_dispatch_proceeds(monkeypatch, qapp, wiz, tmp_path):
    """A memory-tight host at dispatch WARNS (leading log lines, incident wording) but
    the worker still starts and the run completes — a warning is never a block.

    Deliberately the exact incident shape: only the DISPATCH-TIME seam (_meminfo_fresh)
    reads tight, while the process-launch snapshot (_meminfo_cached, conftest-pinned)
    still says healthy — a Studio launched on a healthy host that got tight while the
    user configured must warn anyway."""
    from hugmesh_studio.core import host_resources as hr
    tight = {"MemTotal": 32 * hr.GIB, "MemAvailable": 2 * hr.GIB,
             "SwapTotal": 4 * hr.GIB, "SwapFree": 0}
    monkeypatch.setattr(hr, "_meminfo_fresh", lambda: dict(tight))
    _install_fake_builddriver(monkeypatch)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    log = page.log.toPlainText()
    assert "WARNING: Low host memory" in log
    assert "a heavy compile can freeze the host" in log
    _run_to_completion(qapp, page)                    # the build ran despite the warning
    assert page.driver.results[0].status == "ok"
    assert page.isComplete()


def test_no_warning_lines_on_a_healthy_host(monkeypatch, qapp, wiz, tmp_path):
    from hugmesh_studio.core import host_resources as hr
    healthy = {"MemTotal": 32 * hr.GIB, "MemAvailable": 24 * hr.GIB,
               "SwapTotal": 4 * hr.GIB, "SwapFree": 4 * hr.GIB}
    monkeypatch.setattr(hr, "_meminfo_fresh", lambda: dict(healthy))
    _install_fake_builddriver(monkeypatch)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    _prime(wiz, synthesize(cfg))
    page = _progress_page(wiz)
    page.initializePage()
    assert "WARNING" not in page.log.toPlainText()
    _run_to_completion(qapp, page)
    assert page.driver.results[0].status == "ok"


# ── Back after a settled run (2026-07-17: "there's no way to go back after a build fails")
# BuildPage is a Qt commit page, so Qt disables Back on ProgressPage. Correct mid-build;
# a DEAD END once the run has failed — the operator could not return to Review & Build to
# fix the config and rebuild. Back must re-arm exactly when the run settles.
def _back_btn(wiz):
    # SCOPED enum on purpose: PyQt6 has no QWizard.BackButton (only
    # QWizard.WizardButton.BackButton), while PySide6 accepts both — so a test using
    # the unscoped form passes under PySide6 and the shipped code still crashes every
    # PyQt6 user. Mirror exactly what progress.py calls.
    from hugmesh_studio.gui.qt import QtWidgets
    return wiz.button(QtWidgets.QWizard.WizardButton.BackButton)


def test_back_is_disabled_while_a_build_is_in_flight(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    assert not page._all_terminal
    assert not _back_btn(wiz).isEnabled()      # in flight -> no stepping back
    # DRAIN the run before returning: an abandoned worker thread outlives this test,
    # and its session record then lands in whatever $HUGMESH_STUDIO_STATE_DIR the
    # NEXT test has isolated to (each test gets its own tmp_path) — a cross-file
    # poisoner that surfaces as a wrong session count somewhere else entirely.
    _run_to_completion(qapp, page)


def test_back_is_rearmed_after_a_FAILED_run_so_the_operator_can_fix_and_retry(
        monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch, codes={"be": 3})
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert "failed" in [page.driver.results[i].status for i in range(3)]
    assert page._all_terminal
    assert _back_btn(wiz).isEnabled(), "a failed build must not be a dead end"


def test_back_is_rearmed_after_a_successful_run_too(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert _back_btn(wiz).isEnabled()


def test_back_goes_off_again_when_a_new_run_starts(monkeypatch, qapp, wiz, tmp_path):
    _install_fake_builddriver(monkeypatch, codes={"be": 3})
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert _back_btn(wiz).isEnabled()
    page.initializePage()                       # operator went back, fixed cfg, rebuilt
    assert not _back_btn(wiz).isEnabled()
    _run_to_completion(qapp, page)              # drain (see the in-flight test's note)


def test_auto_backend_is_resolved_before_it_lands_in_the_session_record(
        monkeypatch, qapp, wiz, tmp_path):
    """"auto" must be RESOLVED to the backend that actually runs before it is persisted.

    Regression (operator's 2026-07-17 native run, session 20260717-043931-afb54a): the
    Backend combo defaults to "auto"; BuildPage._backend maps "auto" -> None; that None
    was handed STRAIGHT to new_session, so the durable record said ``backend: None``
    while WorklistDriver separately resolved ``backend or host.default_backend`` and
    really ran NATIVE. The record therefore could not say what ran, and a restart
    (HugMeshWizard restores ``build_backend = session.backend``) would re-resolve
    against whatever the host default happened to be THEN — silently switching backends.

    The pinned HOST fixture is Gentoo without docker -> default_backend == "native".
    """
    _install_fake_builddriver(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path))        # _prime sets build_backend = None ("auto")
    assert wiz.host.default_backend == "native"  # the fixture's premise, pinned
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    # the in-memory record and the driver agree on the RESOLVED backend...
    assert page._session.backend == "native"
    assert page.driver.backend == "native"
    # ...and so does the artifact on disk, which is what the sessions list / tray read.
    import json
    from hugmesh_studio.core import build_sessions
    with open(page._session.path()) as fh:
        assert json.load(fh)["backend"] == "native"


# ══ the log panel: proportions, collapse, detach, watch-help ══════════════════════════
# The report: "the final build screen should show mainly the tree of the build with the
# current log below it taking up at most 1/3 of the vertical screen and that log should be
# minimizable, detachable, and there should be greyed help text with a command to watch it
# build in terminal".
#
# Every assertion below MEASURES a real, shown, laid-out page — asserting stretch factors
# or setSizes() calls would just restate intent, and the original defect (a missing stretch
# on addWidget(self.tree)) was invisible at that level while being 44%-of-the-screen
# obvious on-screen.

def _shown_progress_page(qapp, wiz, h=780):
    """The REAL progress page, actually DISPLAYED and laid out at a realistic size.

    Showing it matters: the wizard opens on page 0, so without navigating here every
    widget reports its unlaid-out 640x480 default and any ratio measured off it is
    meaningless (a live-fire lesson while building this — the first harness "measured"
    100% for both panes).
    """
    wiz.setStartId(wiz._page_ids["progress"])
    wiz.restart()
    wiz.resize(1040, h)
    wiz.show()
    page = _progress_page(wiz)
    for _ in range(20):
        qapp.processEvents()
    assert wiz.currentPage() is page
    return page


def test_tree_dominates_and_log_is_at_most_one_third(qapp, wiz):
    """(1) PROPORTIONS — measured after a real show+resize, at every realistic height.

    Pre-fix this page measured tree 31% / log 44% at its own 1040x780, worsening to
    21%/61% at 900: `lay.addWidget(self.tree)` had no stretch (so the tree was pinned to
    its ~192px sizeHint forever) while `lay.addWidget(self.log, 1)` ate every spare pixel.
    """
    page = _shown_progress_page(qapp, wiz)
    tree_pane = page.splitter.widget(0)
    for h in (620, 780, 900, 1100):
        wiz.resize(1040, h)
        for _ in range(20):
            qapp.processEvents()
        ph, lp, tp = page.height(), page.log_panel.height(), tree_pane.height()
        assert lp <= ph / 3, f"at wizard h={h}: log {lp}px > 1/3 of page {ph}px"
        assert tp >= 1.5 * lp, f"at wizard h={h}: tree {tp}px does not dominate log {lp}px"
        assert page.tree.height() > 192, (
            f"at wizard h={h}: tree {page.tree.height()}px is still stuck at its sizeHint")


def test_tree_is_not_capped_and_grows_with_the_window(qapp, wiz):
    """The second, unreported defect found by measuring: self.tree.setMaximumHeight(340)
    capped the tree even once it WAS stretched, leaving a growing band of dead grey space
    under it inside its own pane. The cap had to go, not just the stretch be fixed."""
    page = _shown_progress_page(qapp, wiz, h=620)
    for _ in range(20):
        qapp.processEvents()
    short = page.tree.height()
    wiz.resize(1040, 1100)
    for _ in range(20):
        qapp.processEvents()
    tall = page.tree.height()
    assert tall > short, f"tree did not grow with the window: {short} -> {tall}"
    assert tall > 340, f"tree still capped at the old 340px maximum ({tall})"
    # and it fills its pane — no dead space under it (footer aside)
    pane = page.splitter.widget(0)
    assert tall >= pane.height() - page.footer.height() - 12


def test_log_is_collapsible_and_the_tree_takes_the_space(qapp, wiz):
    """(2) MINIMIZABLE — the pane must really shrink to the header, not just blank out.
    Hiding self.log alone left the splitter pane at full size (QSplitter does not re-lay a
    pane when a GRANDCHILD hides) = an empty grey box, which is why _set_log_collapsed
    resizes the pane too."""
    page = _shown_progress_page(qapp, wiz)
    tree_pane = page.splitter.widget(0)
    open_tree, open_log = tree_pane.height(), page.log_panel.height()

    page.log_collapse_btn.setChecked(True)
    for _ in range(20):
        qapp.processEvents()
    assert page.log_panel.height() < open_log / 2, "the log pane did not actually collapse"
    assert tree_pane.height() > open_tree, "the tree did not get the collapsed space"
    assert not page.log.isVisible()
    # the header survives as the restore handle — a collapse you cannot undo is a bug
    assert page.log_header.isVisible()
    assert page.log_collapse_btn.isVisible()

    page.log_collapse_btn.setChecked(False)
    for _ in range(20):
        qapp.processEvents()
    assert page.log.isVisible()
    assert page.log_panel.height() == open_log, "expand did not restore the previous share"
    assert tree_pane.height() == open_tree


def test_output_appended_while_collapsed_is_all_there_on_expand(qapp, wiz):
    """(2) Collapsing must NEVER lose output: the reader is not stopped and nothing
    branches on collapsed state — appendPlainText is a QTextDocument operation, entirely
    independent of widget visibility."""
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page.log_collapse_btn.setChecked(True)
    for _ in range(10):
        qapp.processEvents()
    assert not page.log.isVisible()

    for ln in CAPTURED_X86_STREAM:                 # a real build streaming while collapsed
        page._on_line(0, ln)
    page.log_collapse_btn.setChecked(False)
    for _ in range(10):
        qapp.processEvents()

    shown = page.log.toPlainText()
    for ln in CAPTURED_X86_STREAM:
        # compare against the DISPLAYED form: _on_line sanitises builder escapes
        # (they painted boxes in the pane) — the no-loss guarantee is unchanged.
        assert _display_safe(ln) in shown, f"line lost while the log was collapsed: {ln!r}"
    # and the build state itself advanced normally underneath
    assert page._rows[0].bar.value() > 0


def test_detach_while_collapsed_shows_the_log_body_not_an_empty_window(qapp, wiz):
    """(2)x(3) COLLAPSE x DETACH — the interaction, not either alone.

    Collapse then Detach used to hand back a 900x500 top-level window containing nothing
    but the header row: _set_log_collapsed had hidden the body and _detach_log never
    reconciled that state. "Put the log in its own window" and "hide the log body" are
    contradictory; the operator asked for the former, so detaching force-expands.
    """
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page.log_collapse_btn.setChecked(True)
    for _ in range(10):
        qapp.processEvents()
    assert not page.log.isVisible()

    page._toggle_detach()
    for _ in range(10):
        qapp.processEvents()

    assert page._log_window is not None
    assert page.log.isVisible(), "detached window is empty — the log body stayed hidden"
    assert page.log_help_row.isVisible(), "the watch-command help vanished in the window"
    assert not page.log_collapse_btn.isChecked(), "detach must clear the collapse flag"
    # collapse is meaningless in a dedicated window — don't offer the trap
    assert not page.log_collapse_btn.isVisible()
    # and the stream still lands in the (now visible) detached body
    page._on_line(0, "==> streamed after detach-while-collapsed")
    assert "==> streamed after detach-while-collapsed" in page.log.toPlainText()


def test_collapse_while_detached_then_redock_does_not_leave_a_dead_pane(qapp, wiz):
    """(1)x(2)x(3) — re-dock must not hand a body-hidden panel its full 1/3 share.

    _redock_log used to call _restore_sizes() unconditionally, so a panel collapsed while
    detached came back as 187px (28% of the page) of grey nothing — the exact dead-space
    defect this change set out to remove. The docked layout is now a pure function of the
    collapse flag, so this holds however the flag was set.
    """
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page._detach_log()
    for _ in range(10):
        qapp.processEvents()

    # setChecked directly: the button is hidden while detached, so this is the only way in
    # — and the invariant must hold for it too, not merely be unreachable by mouse.
    page.log_collapse_btn.setChecked(True)
    for _ in range(10):
        qapp.processEvents()
    # collapse does NOT blank the detached window while it is still detached
    assert page.log.isVisible()

    page._redock_log()
    for _ in range(10):
        qapp.processEvents()

    header_h = page.log_panel.minimumSizeHint().height()
    assert not page.log.isVisible(), "the collapse flag was ignored on re-dock"
    assert page.log_panel.height() <= header_h + 4, (
        f"re-docked collapsed panel is {page.log_panel.height()}px of dead space "
        f"(header is {header_h}px)")
    assert page.log_panel.height() < page.height() / 4
    assert page.log_header.isVisible(), "no handle left to restore the log"
    assert page.log_collapse_btn.isVisible(), "the collapse control never came back"

    # ...and it expands normally afterwards, back to a real ~1/3 share
    page.log_collapse_btn.setChecked(False)
    for _ in range(10):
        qapp.processEvents()
    assert page.log.isVisible()
    assert page.log_panel.height() > header_h * 2


def test_detached_log_keeps_receiving_the_stream(qapp, wiz):
    """(3a) Detach mid-build with output still streaming. self.log never moves (only its
    PANEL does), so the _on_line append target is invariant under detach."""
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page._on_line(0, CAPTURED_X86_STREAM[0])
    docked_tree = page.splitter.widget(0).height()

    page._toggle_detach()
    for _ in range(10):
        qapp.processEvents()
    assert page._log_window is not None
    assert page._log_window.isVisible()
    assert page.splitter.indexOf(page.log_panel) == -1        # out of the splitter
    assert page.log.parent() is page.log_panel                # the log itself never moved
    # no empty pane is left behind: the tree is the splitter's only pane and fills it
    assert page.splitter.count() == 1
    assert page.splitter.widget(0).height() == page.splitter.height()
    assert page.splitter.widget(0).height() > docked_tree      # and it really did grow

    for ln in CAPTURED_X86_STREAM[1:]:            # still streaming, now into the window
        page._on_line(0, ln)
    for ln in CAPTURED_X86_STREAM:
        assert _display_safe(ln) in page.log.toPlainText(), \
            f"line lost while detached: {ln!r}"


def test_closing_the_detached_window_redocks_and_the_stream_continues(qapp, wiz):
    """(3b) Closing the detached window must RE-DOCK, never orphan the widget or lose the
    stream — and must not destroy self.log out from under the running build."""
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page._detach_log()
    for _ in range(10):
        qapp.processEvents()
    win = page._log_window

    win.close()                                    # the operator clicks the window's X
    for _ in range(20):
        qapp.processEvents()
    assert page._log_window is None
    assert page.splitter.indexOf(page.log_panel) == 1, "the panel did not go back"
    assert page.log_panel.isVisible() and page.log.isVisible()
    # the stream survives the close — this is the assertion that catches the
    # reparent-then-destroy trap (a deleted C++ log under a live Python wrapper)
    page._on_line(0, "==> after the window closed")
    assert "==> after the window closed" in page.log.toPlainText()
    # and Detach re-opens it
    page._toggle_detach()
    for _ in range(10):
        qapp.processEvents()
    assert page._log_window is not None


def test_reset_while_detached_redocks_without_crashing(qapp, wiz):
    """(3c) Page teardown/reset while detached — "where Qt bites". _reset must re-dock
    first, so the panel is never left parented to a window the page no longer tracks."""
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page._detach_log()
    for _ in range(10):
        qapp.processEvents()

    page._reset()                                  # a second build starts while detached
    for _ in range(20):
        qapp.processEvents()
    assert page._log_window is None
    assert page.splitter.indexOf(page.log_panel) == 1
    # self.log's C++ object is ALIVE: appending after teardown must not RuntimeError
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page._on_line(0, "==> second run line")
    assert "==> second run line" in page.log.toPlainText()


def test_wizard_close_while_detached_leaves_no_orphan_window(qapp, wiz):
    """(3c) The wizard closing while detached must not orphan a top-level window, and must
    not take self.log's C++ object with it (_abort_run re-docks before teardown)."""
    page = _shown_progress_page(qapp, wiz)
    page._reset()
    page._build_row(0, "acme-x86", "x86")
    page._select_row(0)
    page._detach_log()
    for _ in range(10):
        qapp.processEvents()
    win = page._log_window

    page._abort_run()                              # what wiz.finished fires
    for _ in range(20):
        qapp.processEvents()
    assert page._log_window is None
    assert page.splitter.indexOf(page.log_panel) == 1
    assert not win.isVisible(), "the detached window was orphaned on the wizard's close"
    page._on_line(0, "==> alive after abort")      # no RuntimeError = the log survived
    assert "==> alive after abort" in page.log.toPlainText()


def test_watch_help_names_the_real_per_image_log_file(monkeypatch, qapp, wiz, tmp_path):
    """(4) The help must name the REAL file — derived from the same helpers the builders
    and the session record use, never a hardcoded guess. The builders write
    IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log"; build_sessions is the twin.
    """
    from hugmesh_studio.core import build_sessions
    _install_streaming_builddriver(monkeypatch, CAPTURED_X86_STREAM)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _x86_worklist(tmp_path))
    page = _shown_progress_page(qapp, wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    workdir = page._session.workdir
    expect = os.path.join(workdir, build_sessions.image_log_name(page._rows[0].label))
    txt = page.log_help.text()
    assert expect in txt, f"help does not name the selected job's real log:\n{txt}"
    assert page._session.log_path in txt, "help does not offer the whole-run log"
    # -F (not -f): a queued job's file does not exist yet and `tail -f` would just exit
    assert f"tail -F -n +1 {expect}" in txt
    # says plainly that the pane and the file are ONE stream
    assert "Same stream" in txt
    # greyed AND actually selectable — help you cannot copy is useless
    assert "color: gray" in page.log_help.styleSheet()
    flags = page.log_help.textInteractionFlags()
    assert flags & Qt.TextInteractionFlag.TextSelectableByMouse
    # the Copy button really puts the command on the clipboard
    page._copy_watch_command()
    assert QtWidgets.QApplication.clipboard().text() == f"tail -F -n +1 {expect}"


def test_watch_help_follows_the_selected_job(monkeypatch, qapp, wiz, tmp_path):
    """(4) "updating with the selected job" — through the real selection funnel."""
    from hugmesh_studio.core import build_sessions
    _install_streaming_builddriver(monkeypatch, CAPTURED_X86_STREAM)
    _install_fake_genkeys(monkeypatch)
    _prime(wiz, _x86_worklist(tmp_path))
    page = _shown_progress_page(qapp, wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    def path_for(i):
        return os.path.join(page._session.workdir,
                            build_sessions.image_log_name(page._rows[i].label))

    page._focus_node(0, None)
    assert path_for(0) in page.log_help.text()
    page._focus_node(1, None)                       # select another JOB
    assert path_for(1) in page.log_help.text()
    assert path_for(0) not in page.log_help.text()
    # a STAGE shows its JOB's file: stages are slices of that one file, so naming a
    # per-stage path would be a fabrication
    page._focus_node(1, 0)
    assert path_for(1) in page.log_help.text()


def test_watch_help_is_honest_before_any_dispatch(qapp, wiz):
    """(4) No dispatch (no worklist / preflight failure / pre-dispatch) => no builder has
    opened a log file. Naming a path that does not and will not exist would be a lie."""
    page = _shown_progress_page(qapp, wiz)
    page.initializePage()                           # no worklist primed
    assert "No build session yet" in page.log_help.text()
    assert "tail" not in page.log_help.text()
    assert not page.log_copy_btn.isEnabled()


def test_watch_command_matches_the_host_os(qapp, wiz):
    """(4) Never offer a command that cannot exist on the host: Windows has no tail."""
    page = _shown_progress_page(qapp, wiz)
    assert page._watch_command("/o/build-pki.x86.log") == "tail -F -n +1 /o/build-pki.x86.log"
    # paths with spaces are quoted, not concatenated into a broken command
    assert page._watch_command("/o/My Builds/b.log") == "tail -F -n +1 '/o/My Builds/b.log'"
    wiz.host = HostInfo(os="windows", is_gentoo=False, has_docker=True, has_bash=False,
                        has_kvm=False, is_root=False, builder_image="b")
    assert page._watch_command(r"C:\o\b.log") == 'Get-Content -Wait -Tail 50 "C:\\o\\b.log"'


def test_ansi_escapes_never_reach_any_operator_visible_surface(
        monkeypatch, qapp, wiz, tmp_path):
    """Builder colour/cursor escapes must not paint BOXES in the GUI.

    Operator report (2026-07-17): "the logs in the gui are showing boxes for
    undisplayable chars". Root cause: the builders colour output unconditionally, so
    real lines arrive wrapped in SGR escapes, and the x86 emerge stream also emits
    cursor moves ("\x1b[A", "\x1b[72C") — a real 53 MB session log carries 351 ESC
    bytes. ProgressParser strip_ansi()es internally, so the phase table was fine, but
    _on_line appended the RAW line, and Qt has no glyph for ESC -> a box each.

    Three operator-visible surfaces consumed that raw line, and this pins all three:
      1. the log pane, 2. row.buffer (-> error_tail -> the session record shown in the
      sessions list), 3. the stage tracker's per-stage drill-down slices.
    The on-disk build.log is NOT covered here and must KEEP its colours — the driver
    writes it, and the watch command's `tail -f` renders them.
    """
    _install_fake_builddriver(monkeypatch)
    _prime(wiz, _mesh_worklist(tmp_path, roles=(("pki", "x86"),)))
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    # a REAL captured shape: an SGR-wrapped banner + a cursor-move status line.
    page._selected, page._selected_stage = 0, None
    page._on_line(0, "\x1b[1;36m==> Rebranding baked config\x1b[0m")
    page._on_line(0, "\x1b[A\x1b[72C \x1b[34;01m[ \x1b[31;01m!!\x1b[34;01m ]\x1b[0m")
    qapp.processEvents()

    assert "\x1b" not in page.log.toPlainText()                 # 1. the log pane
    assert "==> Rebranding baked config" in page.log.toPlainText()   # text survives
    assert not any("\x1b" in b for b in page._rows[0].buffer)   # 2. buffer -> error_tail
    tracker = page._rows[0].tracker
    slices = "".join("".join(st.lines) for st in tracker.stages)
    assert "\x1b" not in slices                                  # 3. per-stage slices


def test_display_safe_strips_escapes_but_keeps_real_text():
    """_display_safe is lossless for real text: it removes only bytes Qt cannot paint.
    TAB is deliberately kept (real layout in builder output, and Qt renders it)."""
    from hugmesh_studio.gui.pages.progress import _display_safe
    assert _display_safe("\x1b[1;36m==> Rebranding\x1b[0m") == "==> Rebranding"
    assert _display_safe("\x1b[A\x1b[72C [ !! ]") == " [ !! ]"      # cursor moves
    assert _display_safe("plain line") == "plain line"              # untouched
    assert _display_safe("col1\tcol2") == "col1\tcol2"              # TAB KEPT
    assert _display_safe("bar 50%\r") == "bar 50%"                  # CR dropped
    assert _display_safe("\x1b") == ""                              # bare ESC dropped
    assert _display_safe(_display_safe("\x1b[0ma")) == "a"          # idempotent
