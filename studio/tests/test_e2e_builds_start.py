"""GUI ALL-BUILDS-START e2e — walk the REAL wizard headlessly for EACH of the four
first-screen choices and assert the build actually STARTS with the right dispatch.

This is a pure mock-bounded e2e (no real build, no cluster): the OS-image builds run
through the REAL ProgressPage / _WorklistWorker / WorklistDriver pipeline with a
CAPTURING fake BuildDriver at the run() boundary. The fake records the (cfg, backend)
each image was dispatched with and returns 0 with a `==> building` banner so the whole
page lifecycle runs to terminal — then the test rebuilds a GENUINE BuildDriver and
asserts the materialized argv the WIZARD dispatched equals the exact contract
test_build_driver.py pins (`["bash", f"./{script}", "-w", out, "-j", jobs, *cli]`).

The four choices (design step1Taxonomy / ModePage):
  1. MESH NODE           — a multi-image worklist (be.rpi5 + omnibus.x86)
  2. MESH DESKTOP CLIENT — cloud, single x86 image (tailnet + SSO defaults)
  3. STANDALONE GENTOO   — standalone, single x86 image (admin pages skipped)
  4. LOCAL DOCKER MESH   — the non-image side-flow: it does NOT reach ProgressPage, it
                           launches a dockerized node. Path (4b) drives the REAL
                           LocalMeshNode.start() to a real `docker compose up -d`
                           dispatch (the boundary mocked), which is the #340-class
                           "a first-screen choice that dead-ends on start" regression.

Skipped whole when no Qt binding is present (importorskip), exactly like the sibling GUI
tests, so the pure-core / build-matrix columns stay unaffected.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.build_driver import BuildDriver as RealBuildDriver  # noqa: E402
from hugmesh_studio.core.config import UNAFFILIATED_ROLE, WIZARD_PAGE_SLUGS   # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode                            # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                        # noqa: E402
from hugmesh_studio.core import mesh_node as mesh_node_mod                    # noqa: E402
from hugmesh_studio.core import worklist_driver as wd                         # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                           # noqa: E402
from hugmesh_studio.gui.pages import ModePage                                 # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod               # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                               # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# is_root=True is LOAD-BEARING: a native worklist preflight otherwise fails "needs root"
# and the build would never start (mirrors test_pages_progress's HOST). Native backend so
# the dispatched argv is `bash ./<script> …` with no sudo prefix.
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


# ── shared fixtures (copied from test_pages_progress.py / test_wizard.py) ──────────────
@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # ProgressPage writes a tray build-status file — keep it out of the real ~/.hugmesh.
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible()/isVisibleTo() meaningful
    yield w
    w.close()
    w.deleteLater()


# ── wizard-drive helpers (lifted verbatim from test_wizard.py) ─────────────────────────
def advance_to(wiz, page_cls):
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def back_to(wiz, page_cls):
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        wiz.back()
    raise AssertionError(f"never reached {page_cls.__name__} going back")


def pick_mode(wiz, mode):
    page = advance_to(wiz, wizard_mod.ModePage)
    idx = [m for m, _, _ in page.modes].index(mode)
    page.group.button(idx).setChecked(True)
    return page


def pick_role(wiz, role):
    page = advance_to(wiz, wizard_mod.RolePage)
    if not page.select_role(role):     # machine-first: selects the supporting card too
        raise AssertionError(f"role {role} not offered on RolePage")
    return page


def pick_platform(role_page, plat):
    if plat not in role_page._machine_buttons:
        raise AssertionError(f"machine card {plat} not present on RolePage")
    role_page.select_machine(plat)


# ── the builder mock boundary (image paths 1-3) ────────────────────────────────────────
def _install_capturing_builddriver(monkeypatch):
    """A CAPTURING fake BuildDriver installed at worklist_driver.BuildDriver: it records the
    (cfg, backend) run() was dispatched with per image, AND still returns 0 with a
    `==> building` line so the REAL ProgressPage/_WorklistWorker/WorklistDriver pipeline
    runs to terminal. preflight() returns clean (the real repo has all four scripts)."""
    captured: list[tuple] = []

    class CapturingBuildDriver:
        # graphical=... is threaded by WorklistDriver since the GUI-safe-sudo change
        # (a GUI-launched native build elevates via a password dialog, not a terminal).
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            captured.append((cfg, backend))
            if on_line:
                on_line(f"==> building {cfg.role}")
            return 0

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", CapturingBuildDriver)
    return captured


def _install_fake_genkeys(monkeypatch):
    """Mesh footer path never shells out (mirrors test_pages_progress)."""
    class FakeProc:
        def __init__(self):
            self.stdout = iter(["generating keys"])

        def wait(self):
            return 0

    monkeypatch.setattr(wd.subprocess, "Popen", lambda cmd, **kw: FakeProc())


def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _run_to_completion(qapp, page, timeout_ms=5000):
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


def _expected_native_argv(cfg):
    """The exact BuildDriver.command contract (test_build_driver.py) for a root native run.

    Build-PHASE plumbing first (-w, -j, the shared build-asset root), then the CONFIG
    args. The shared root is spelled out literally here rather than imported from the
    driver so this stays an INDEPENDENT statement of the contract — a driver-side change
    to where the root lands must fail this test, not silently follow it."""
    out = cfg.output_dir or os.path.join(GENERATOR_DIR, "out")
    return ["bash", f"./{cfg.builder_script}", "-w", out, "-j", str(cfg.jobs),
            "--shared-assets", os.path.join(out, "shared"),
            *cfg.to_cli_args()]


def _assert_dispatched_argv(cfg, backend):
    """The materialized argv the WIZARD dispatched equals what a genuine BuildDriver would
    run for that exact cfg — the single-sourced flag-translation contract, on the config the
    wizard actually built."""
    real = RealBuildDriver(GENERATOR_DIR, HOST)
    argv = real.command(cfg, backend)
    assert argv == _expected_native_argv(cfg)
    return argv


def _assert_no_start_error(page):
    log = page.log.toPlainText()
    assert "Cannot start" not in log, log
    assert "Preflight FAILED" not in log, log


# ── (1) MESH NODE — multi-image worklist ───────────────────────────────────────────────
def test_mesh_node_worklist_starts_all_images(monkeypatch, qapp, wiz):
    captured = _install_capturing_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)

    pick_mode(wiz, "mesh")
    wl_page = advance_to(wiz, wizard_mod.WorklistPage)
    # check exactly two node images across two platforms; uncheck everything else so the
    # pre-checked mode-default row can't sneak a third image in.
    want = {"omnibus.x86", "be.rpi5"}
    for rid, item in wl_page.rows.items():
        item.setCheckState(0, Qt.CheckState.Checked if rid in want
                           else Qt.CheckState.Unchecked)

    build = advance_to(wiz, wizard_mod.BuildPage)   # Next through Worklist→…→Build commits the worklist
    assert build.gen_keys.isChecked()               # node key-zips on by default
    assert build.validatePage()                     # commit worklist / backend / gen-keys

    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    # one row per checked image; the run settled cleanly with every image OK
    assert len(page._rows) == 2
    assert {r.label for r in page._rows} == want
    _assert_no_start_error(page)
    assert page.isComplete()
    assert [r.status for r in page.driver.results] == ["ok", "ok"]

    # both images were dispatched; assert the exact per-platform builder + argv the wizard
    # materialized. (Row/entry order is ROLE_CHOICES order — be.rpi5 precedes omnibus.x86 —
    # so assert by platform, not position.)
    assert len(captured) == 2
    by_platform = {cfg.platform: (cfg, backend) for cfg, backend in captured}
    assert set(by_platform) == {"x86", "rpi5"}
    x86_cfg, x86_backend = by_platform["x86"]
    rpi5_cfg, rpi5_backend = by_platform["rpi5"]
    assert x86_cfg.builder_script == "build-x86-host-stage4.sh"
    assert rpi5_cfg.builder_script == "build-rpi5-stage4.sh"
    _assert_dispatched_argv(x86_cfg, x86_backend)
    _assert_dispatched_argv(rpi5_cfg, rpi5_backend)

    # the once-per-worklist mesh steps also STARTED: manifest written once, per-node
    # key-zips fired for BOTH node rows (reuses the test_pages_progress footer contract).
    footer = page.footer.text()
    assert "manifest" in footer.lower()
    assert "omnibus.x86" in footer and "be.rpi5" in footer


# ── (2) MESH DESKTOP CLIENT — cloud, single image ──────────────────────────────────────
def test_cloud_desktop_client_starts(monkeypatch, qapp, wiz):
    captured = _install_capturing_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)

    pick_mode(wiz, "cloud")
    role_page = pick_role(wiz, "desktop")
    pick_platform(role_page, "x86")
    # admin pages (keyzip/domains/users) are visited but need no data for a build-start.
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert build.validatePage()

    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    assert len(page._rows) == 1
    _assert_no_start_error(page)
    assert page.isComplete()
    assert page.driver.results[0].status == "ok"

    assert len(captured) == 1
    cfg, backend = captured[0]
    assert cfg.mode == "cloud"
    assert cfg.builder_script == "build-x86-host-stage4.sh"
    cli = cfg.to_cli_args()
    assert "--with-tailscale" in cli and "--with-sso" in cli   # cloud desktop defaults
    _assert_dispatched_argv(cfg, backend)


# ── (3) STANDALONE GENTOO desktop — single image, admin pages skipped ──────────────────
@pytest.mark.parametrize("role", ["standalone-thick", UNAFFILIATED_ROLE])
def test_standalone_desktop_starts(monkeypatch, qapp, wiz, role):
    captured = _install_capturing_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)

    pick_mode(wiz, "standalone")           # default, but be explicit
    pick_role(wiz, role)
    build = advance_to(wiz, wizard_mod.BuildPage)   # admin pages skipped (MODE_SKIPPED_PAGES)
    assert build.validatePage()                     # command_string must NOT raise (unaffiliated too)

    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)

    assert len(page._rows) == 1
    _assert_no_start_error(page)
    assert page.isComplete()
    assert page.driver.results[0].status == "ok"

    assert len(captured) == 1
    cfg, backend = captured[0]
    assert cfg.mode == "standalone"
    assert cfg.builder_script == "build-x86-host-stage4.sh"
    cli = cfg.to_cli_args()
    if role == UNAFFILIATED_ROLE:
        # unaffiliated hard-conflicts with bundling the generator source AND the tailnet —
        # neither flag pair reaches the argv at all (not even --no-*), and the run still
        # starts cleanly (command_string never raised the conflict).
        assert "--bundle-source" not in cli and "--no-bundle-source" not in cli
        for flag in ("--with-tailscale", "--no-tailscale", "--with-sso", "--no-sso"):
            assert flag not in cli
        assert ("--role", UNAFFILIATED_ROLE) in zip(cli, cli[1:])
    else:
        # a branded standalone image has no tailnet either (spec 3): tailscale/sso forced
        # off, and it self-hosts the generator source by default.
        assert "--no-tailscale" in cli and "--no-sso" in cli
        assert "--bundle-source" in cli
    _assert_dispatched_argv(cfg, backend)


# ── (4a) LOCAL DOCKER MESH — the non-image GATE (does not dead-end the wizard) ──────────
def test_localmesh_choice_gates_next_without_dead_end(wiz):
    # page-flow contract (the popout is gone): the localmesh radio ENABLES Next,
    # validatePage raises the transient wizard flag, cfg.mode stays an image mode,
    # and the registered LocalMeshPage is in-flow and terminal.
    mp = next(p for p in wiz._pages if isinstance(p, ModePage))
    mp._buttons["localmesh"].setChecked(True)
    mp._on_mode_toggled()
    before = wiz.cfg.mode
    assert mp.isComplete() is True
    assert mp.validatePage() is True
    assert wiz.localmesh_selected is True and wiz.cfg.mode == before
    lm = wiz.page(wiz._page_ids["localmesh"])
    assert lm.applies_to(wiz.cfg) is True and lm.nextId() == -1


# ── (4b) LOCAL DOCKER MESH — LAUNCH to a REAL dispatched `docker compose up -d` ─────────
def test_localmesh_launch_dispatches_compose_up(qapp, tmp_path, monkeypatch):
    """Drives the REAL LocalMeshNode.start() (which test_local_mesh.py masks by
    monkeypatching start()/available() wholesale) to a real compose dispatch. The compose
    BOUNDARY is mocked (no docker probed / run); the node lifecycle itself is real.

    Regression this pins (the #340-class dead-end): LocalMeshNode.available() accepts the
    auth key typed into the dialog, but MeshNode.start() used to gate on os.environ
    TS_AUTHKEY — so with the key in the field (and none in the environment) start()
    dead-ended and never dispatched `up -d`. This asserts the fixed hook path: start()
    dispatches with NO TS_AUTHKEY in os.environ, and the effective key reaches the
    subprocess env."""
    monkeypatch.delenv("TS_AUTHKEY", raising=False)   # prove start() no longer needs it in env
    monkeypatch.setenv("HOME", str(tmp_path))         # isolate the default ~/.hugmesh workdir
    monkeypatch.setattr(mesh_node_mod, "_compose_base", lambda: ["docker", "compose"])

    calls = []

    class _Completed:
        returncode = 0
        stderr = ""
        stdout = "started"

    def _fake_run(cmd, **kw):
        calls.append((cmd, kw))
        return _Completed()

    monkeypatch.setattr(mesh_node_mod.subprocess, "run", _fake_run)

    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.auth_key.setText("tskey-live")
    dlg.node_name.setText("mynode")
    dlg._start()
    # verbs run on a _MeshWorker thread since the page conversion (the no-freeze
    # fix) — join it and pump the loop so its queued signals land before asserting.
    if dlg.page.worker is not None:
        dlg.page.worker.wait(5000)
    for _ in range(200):
        qapp.processEvents()

    # the node lifecycle STARTED (a real dispatch, not a crash / dead-end). _start() flashes
    # "Started." then _refresh_status() replaces it with the live status — so the terminal
    # label reads "running" (the mocked `ps -q` reports one container), proving the node
    # both dispatched AND came up rather than dead-ending on the old env-key gate.
    assert isinstance(dlg.node, MeshNode)
    assert "running" in dlg.status.text().lower()
    up_calls = [(cmd, kw) for cmd, kw in calls if isinstance(cmd, list) and cmd[-2:] == ["up", "-d"]]
    assert len(up_calls) == 1, calls
    up_cmd, up_kw = up_calls[0]
    expected = ["docker", "compose", "--profile", "mesh", "-p", dlg.node.project, "-f",
                os.path.join(dlg.node.workdir, "docker-compose.mesh.yml"), "up", "-d"]
    assert up_cmd == expected
    # the effective auth key (from the dialog field, NOT the environment) reached the
    # subprocess env — the second half of the fix (inherited _env used to inject only a
    # teardown placeholder, shadowing the staged real key).
    assert up_kw.get("env", {}).get("TS_AUTHKEY") == "tskey-live"
