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

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core.config import Domain, ImageConfig, User    # noqa: E402
from snapdragon_studio.core.platform_info import HostInfo              # noqa: E402
from snapdragon_studio.core import worklist_driver as wd               # noqa: E402
from snapdragon_studio.core.worklist import (                         # noqa: E402
    WorklistConfig, WorklistEntry, synthesize)
from snapdragon_studio.gui import wizard as wizard_mod                 # noqa: E402
from snapdragon_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="snapdragon-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="snapdragon-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # ProgressPage now writes a tray build-status file; keep it out of the real
    # ~/.snapdragon during tests.
    monkeypatch.setenv("SNAPDRAGON_STUDIO_STATE_DIR", str(tmp_path / "state"))


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
        def __init__(self, gen, host, graphical=False):
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
            or QtWidgets.QApplication(["snapdragon-studio-tests"]))


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
        def __init__(self, gen, host, graphical=False):
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
    from snapdragon_studio.gui.tray import read_build_status
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
    from snapdragon_studio.gui.tray import read_build_status
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
