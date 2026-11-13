"""A non-root operator on a Gentoo host can start a native fleet build (GUI-04).

On the operator's own machine "auto" resolves to native (HostInfo.default_backend), and
a GUI Studio is never root. Three stacked causes kept every native fleet from starting
there, while the single-image path (BuildDriver) had been fixed since 2026-07-17:

1. ``FleetDriver.preflight`` refused any non-root native run with "Native build needs
   root (the Studio will prepend sudo)." — the exact check BuildDriver removed (#382).
   The rule now is BuildDriver's: refuse only when nothing can elevate, and refuse a
   native run from the Flatpak, where the native backend cannot work.
2. ``FleetDriver.command`` hard-coded ``["sudo"]`` instead of
   ``BuildDriver._elevation_prefix()``, so the build and its kill-tree
   (``_kill_native_group``, which uses the prefix) could diverge.
3. The fleet page built ``FleetDriver(generator_dir)``, not ``graphical=True``, so even
   the shared prefix was a bare ``sudo`` whose password prompt goes to a terminal the
   GUI does not have.

NEVER ELEVATE: nothing here may start sudo or pkexec. The dispatch tests set
HUGMESH_STUDIO_NO_ELEVATION and either replace ``_spawn`` (nothing reaches subprocess)
or make ``subprocess.Popen`` fail the test, and assert the ElevationRefused that
``guard_elevation`` raises BEFORE any spawn. The ALLOW-under-test opt-out is never set.

The core half is Qt-free and runs in the GitHub pre-merge job (which installs no Qt);
the two route tests import Qt inside the test, so only they skip there.
"""
from __future__ import annotations

import ast
import functools
import os
import time

import pytest

from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core import flatpak_host, platform_info
from hugmesh_studio.core.fleet import FLEET_SCRIPT, FleetConfig, FleetDriver
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
FLEET_PAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui", "pages", "fleet.py")

#: The sentence this file exists to keep out of a non-root preflight.
OLD_ROOT_SENTENCE = "Native build needs root (the Studio will prepend sudo)."
#: BuildDriver's dead-end sentence (no sudo, no pkexec), which the fleet now shares.
NO_HELPER = "no elevation helper is available"


def _mesh_cfg(**kw) -> FleetConfig:
    """A fleet config the PKI LAN rule (core/pki_lan.py, #1004) accepts: these tests are
    about elevation, so the pki node's fixed LAN address is given, as an operator must."""
    return FleetConfig(pki_lan_ip="192.168.1.10", pki_lan_ip_fixed=True, **kw)


def _host(**kw) -> HostInfo:
    """The operator's machine: Gentoo, not root, no docker — "auto" is native."""
    base = dict(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    base.update(kw)
    return HostInfo(**base)


@pytest.fixture(autouse=True)
def _posix_native(monkeypatch):
    """Answer the platform refusals as the pinned Linux host does, whatever OS runs
    the suite (the native refusals read the PROCESS's os.name too)."""
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(platform_info.native_windows_blocker,
                                          osname="posix"))
    if hasattr(platform_info, "native_build_blocker"):      # the macOS layer's seam
        monkeypatch.setattr(platform_info, "native_build_blocker",
                            functools.partial(platform_info.native_build_blocker,
                                              osname="posix", sysplatform="linux"))


def _force_sudo_a(monkeypatch, askpass="/run/studio-askpass.sh"):
    """sudo present + an askpass helper -> the graphical ``sudo -A`` path. Also keeps
    the helper from being written into the real ~/.cache."""
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: askpass)


def _force_pkexec(monkeypatch):
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: None)
    monkeypatch.setattr(bd.shutil, "which",
                        lambda name: "/usr/bin/pkexec" if name == "pkexec" else None)


def _no_helper(monkeypatch):
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: None)
    monkeypatch.setattr(bd.shutil, "which", lambda name: None)


def _never_elevate(monkeypatch):
    """The operator's knob ON, the test opt-out OFF: a sudo/pkexec spawn is refused."""
    monkeypatch.setenv(bd.NO_ELEVATION_ENV, "1")
    monkeypatch.delenv(bd.ALLOW_ELEVATION_UNDER_TEST_ENV, raising=False)


# ── cause 1: preflight follows BuildDriver's rule ────────────────────────────────────
def test_non_root_native_fleet_is_not_refused_when_it_can_elevate(monkeypatch):
    _force_sudo_a(monkeypatch)
    d = FleetDriver(GENERATOR_DIR, _host(), graphical=True)
    assert d.host.default_backend == "native"       # what "auto" means on this host
    assert d.preflight(_mesh_cfg()) == []         # auto -> native, nothing refused
    assert d.preflight(_mesh_cfg(), "native") == []


def test_non_root_native_fleet_with_only_pkexec_is_not_refused(monkeypatch):
    _force_pkexec(monkeypatch)
    d = FleetDriver(GENERATOR_DIR, _host(), graphical=True)
    assert d.preflight(_mesh_cfg(), "native") == []


def test_non_root_native_fleet_is_refused_only_when_nothing_can_elevate(monkeypatch):
    _no_helper(monkeypatch)
    problems = FleetDriver(GENERATOR_DIR, _host(), graphical=True).preflight(
        FleetConfig(), "native")
    said = [p for p in problems if NO_HELPER in p]
    assert len(said) == 1, problems
    assert "install sudo or pkexec" in said[0]
    assert OLD_ROOT_SENTENCE not in problems


def test_the_fleet_and_the_single_image_route_agree_on_the_dead_end(monkeypatch, tmp_path):
    """The same host, the same missing helper: the fleet says what BuildDriver says."""
    _no_helper(monkeypatch)
    from hugmesh_studio.core.config import ImageConfig
    single = bd.BuildDriver(GENERATOR_DIR, _host(), graphical=True)
    single_said = [p for p in single.preflight(
        ImageConfig(mode="mesh", role="pki", platform="x86",
                    output_dir=str(tmp_path / "out")), "native") if NO_HELPER in p]
    fleet_said = [p for p in FleetDriver(GENERATOR_DIR, _host(), graphical=True).preflight(
        FleetConfig(), "native") if NO_HELPER in p]
    assert fleet_said == single_said and len(fleet_said) == 1


def test_root_native_fleet_is_unchanged(monkeypatch):
    _no_helper(monkeypatch)                           # root needs no helper at all
    d = FleetDriver(GENERATOR_DIR, _host(is_root=True), graphical=True)
    assert d.preflight(_mesh_cfg(), "native") == []


def test_native_fleet_from_the_flatpak_is_refused_with_the_flatpak_reason(monkeypatch):
    """An EXPLICIT native choice in the Flatpak ("auto" is docker there): BuildDriver's
    refusal, not a root sentence and not a dispatch that cannot work."""
    _force_sudo_a(monkeypatch)
    host = _host(in_flatpak=True, has_docker=True, docker_state="ok")
    assert host.default_backend == "docker"
    problems = FleetDriver(GENERATOR_DIR, host, graphical=True).preflight(
        FleetConfig(), "native")
    assert flatpak_host.native_build_blocker() in problems, problems
    assert not any("needs root" in p for p in problems), problems


# ── cause 2: command() uses the shared elevation prefix ──────────────────────────────
def _native(d: FleetDriver, cfg: FleetConfig | None = None) -> list[str]:
    return d.command(cfg or FleetConfig(output_dir="/fleet-out"), "native")


def test_gui_native_fleet_elevates_through_sudo_dash_A(monkeypatch):
    _force_sudo_a(monkeypatch)
    d = FleetDriver(GENERATOR_DIR, _host(), graphical=True)
    cmd = _native(d)
    assert cmd[:4] == ["sudo", "-A", "bash", f"./{FLEET_SCRIPT}"], cmd
    assert cmd[:2] == d._elevation_prefix()


def test_env_knobs_ride_inside_the_graphical_prefix(monkeypatch):
    """sudo -A / pkexec reset the environment: the `env K=V` wrapper must come AFTER
    the prefix, exactly as it did after a plain sudo."""
    _force_sudo_a(monkeypatch)
    cmd = _native(FleetDriver(GENERATOR_DIR, _host(), graphical=True),
                  FleetConfig(output_dir="/fleet-out", pentest=True))
    assert cmd[:5] == ["sudo", "-A", "env", "PENTEST=1", "bash"], cmd


def test_gui_native_fleet_falls_back_to_pkexec(monkeypatch):
    _force_pkexec(monkeypatch)
    cmd = _native(FleetDriver(GENERATOR_DIR, _host(), graphical=True))
    assert cmd[:3] == ["pkexec", "bash", f"./{FLEET_SCRIPT}"], cmd


def test_terminal_and_root_previews_are_unchanged(monkeypatch):
    """The copy-pasteable preview (graphical=False: the TUI, --print-* and the unit
    goldens) keeps the plain sudo; root keeps no prefix at all."""
    _force_sudo_a(monkeypatch)
    assert _native(FleetDriver(GENERATOR_DIR, _host()))[:2] == ["sudo", "bash"]
    assert _native(FleetDriver(GENERATOR_DIR, _host(is_root=True), graphical=True))[0] == "bash"


# ── dispatch: the prefix reaches the spawn and the kill — and nothing is spawned ─────
class _FakeProc:
    stdout = iter(())
    pid = 4321

    def wait(self, timeout=None):
        return 0


def test_dispatch_spawns_the_graphical_prefix_with_the_askpass_env(monkeypatch, tmp_path):
    """A mocked ``_spawn`` (nothing reaches subprocess) records what run() would start:
    the sudo -A argv, and the SUDO_ASKPASS env sudo needs to show the dialog."""
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _never_elevate(monkeypatch)
    seen = {}

    def spawn(self, cmd, backend):
        seen.update(cmd=list(cmd), backend=backend, env=self._elevation_env())
        return _FakeProc()

    monkeypatch.setattr(FleetDriver, "_spawn", spawn)
    d = FleetDriver(GENERATOR_DIR, _host(), graphical=True)
    assert d.run(FleetConfig(output_dir=str(tmp_path / "out"))) == 0   # auto -> native
    assert seen["backend"] == "native"
    assert seen["cmd"][:3] == ["sudo", "-A", "bash"], seen["cmd"]
    assert seen["env"]["SUDO_ASKPASS"] == "/run/ap.sh"


def test_real_spawn_is_refused_before_popen_under_no_elevation(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch)
    _never_elevate(monkeypatch)
    monkeypatch.setattr(bd.subprocess, "Popen", lambda *a, **k: pytest.fail(
        "subprocess.Popen was reached — the refusal must come first"))
    d = FleetDriver(GENERATOR_DIR, _host(), graphical=True)
    with pytest.raises(bd.ElevationRefused,
                       match=rf"refusing to spawn sudo \({bd.NO_ELEVATION_ENV} is set\).*"
                             rf"command starts: sudo -A bash \./{FLEET_SCRIPT}"):
        d.run(FleetConfig(output_dir=str(tmp_path / "out")), "native")


def test_the_kill_tree_uses_the_same_prefix_as_the_build(monkeypatch):
    """_kill_native_group signals the root-owned tree through _elevation_prefix: the
    fleet's build now goes through the same one, so Stop can reach what it started."""
    _force_sudo_a(monkeypatch)
    _never_elevate(monkeypatch)
    monkeypatch.setattr(bd.subprocess, "run", lambda *a, **k: pytest.fail(
        "subprocess.run was reached — the refusal must come first"))
    d = FleetDriver(GENERATOR_DIR, _host(), graphical=True)
    build_prefix = _native(d)[:2]
    d._pgid = 4321
    with pytest.raises(bd.ElevationRefused, match=r"command starts: sudo -A kill -TERM "):
        d._kill_native_group("TERM")
    assert build_prefix == ["sudo", "-A"]


# ── cause 3: the GUI builds its driver graphical ─────────────────────────────────────
def test_the_fleet_page_constructs_a_graphical_driver_source():
    """Qt-free pin (the GitHub job has no Qt): every FleetDriver the fleet page builds
    passes graphical=True."""
    with open(FLEET_PAGE, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), FLEET_PAGE)
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
             and getattr(n.func, "id", getattr(n.func, "attr", None)) == "FleetDriver"]
    assert calls, "gui/pages/fleet.py no longer constructs a FleetDriver"
    for c in calls:
        kw = {k.arg: k.value for k in c.keywords}
        assert isinstance(kw.get("graphical"), ast.Constant) and kw["graphical"].value is True, (
            f"gui/pages/fleet.py:{c.lineno} builds FleetDriver without graphical=True")


def _qt():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    from hugmesh_studio.gui.qt import QtWidgets
    return QtWidgets, (QtWidgets.QApplication.instance()
                       or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def test_the_fleet_page_driver_is_graphical(monkeypatch):
    QtWidgets, app = _qt()
    from hugmesh_studio.gui.pages import fleet as fleet_mod
    monkeypatch.setattr(bd, "detect", lambda *a, **k: _host())
    page = fleet_mod.FleetPage(GENERATOR_DIR)
    try:
        assert page.driver.graphical is True
    finally:
        page.deleteLater()
        app.processEvents()


def test_route_sessions_fleet_review_build_reaches_the_dispatch(monkeypatch, tmp_path):
    """The route, as the operator walks it: Sessions -> "Fleet build…" (expert mode)
    -> Review -> "Build fleet now", on a non-root Gentoo host with "auto" selected.
    Review says Preflight: OK and previews the sudo -A command; the click reaches the
    Run step and the dispatch stops at the NO_ELEVATION refusal, which names the argv
    the build would have started. Nothing is spawned."""
    QtWidgets, app = _qt()
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages import fleet as fleet_mod

    _force_sudo_a(monkeypatch)
    _never_elevate(monkeypatch)
    monkeypatch.setattr(wizard_mod, "detect", lambda *a, **k: _host())
    monkeypatch.setattr(bd, "detect", lambda *a, **k: _host())
    monkeypatch.setenv("HUGMESH_STUDIO_ADVANCED", "1")

    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        sessions = wiz.page(wiz._page_ids["sessions"])
        btn = next(b for b in sessions.findChildren(QtWidgets.QPushButton)
                   if b.text().replace("&", "") == "Fleet build…")
        btn.click()
        page = wiz.fleet_window.page
        assert page.backend.currentText() == "auto"
        page.output_dir.setText(str(tmp_path / "out"))
        page.pki_lan_ip.setText("192.168.1.10")       # core/pki_lan.py: KEYS need it
        page.pki_lan_fixed.setChecked(True)
        page._goto(fleet_mod.STEP_REVIEW)
        assert page.problems.toPlainText() == "Preflight: OK"
        assert page.cmd.toPlainText().startswith(
            f"sudo -A env PKI_LAN_IP=192.168.1.10 bash ./{FLEET_SCRIPT} ")
        assert page.next_btn.text() == "Build fleet now" and page.next_btn.isEnabled()

        # From here on, a sudo/pkexec or build-all-roles start is a failure: the
        # dispatch must stop at the refusal. (Patched only now, and only for those:
        # the wizard's own pages run read-only probes, which pass through.)
        spawned = []
        real_popen = bd.subprocess.Popen

        def popen(args, *a, **k):
            argv = [str(x) for x in (args if isinstance(args, (list, tuple)) else [args])]
            if (argv and os.path.basename(argv[0]) in bd.ELEVATION_PROGRAMS) or any(
                    FLEET_SCRIPT in x for x in argv):
                spawned.append(argv)
                raise RuntimeError("the fleet dispatch reached subprocess.Popen")
            return real_popen(args, *a, **k)

        monkeypatch.setattr(bd.subprocess, "Popen", popen)
        page.next_btn.click()
        assert page.stack.currentIndex() == fleet_mod.STEP_RUN
        deadline = time.time() + 15
        while (page.worker.isRunning() or page._session is not None) \
                and time.time() < deadline:
            app.processEvents()
            time.sleep(0.01)
        assert page._session is None, "the run never finalized its session record"
        log = page.log.toPlainText()
        assert "refusing to spawn sudo" in log, log
        assert f"command starts: sudo -A bash ./{FLEET_SCRIPT}" in log, log
        assert spawned == []
        (s,) = bs.load_all()
        assert s.kind == "fleet" and s.status == "failed"
    finally:
        fw = getattr(wiz, "fleet_window", None)
        if fw is not None:
            fw.hide()
            fw.deleteLater()
        wiz.close()
        wiz.deleteLater()
        app.processEvents()
