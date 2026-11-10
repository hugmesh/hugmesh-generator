"""The Build screen's "Save this mesh" strip and the progress page's local-mesh panel
(gui/pages/_images_mesh.py) — on the REAL wizard, offscreen.

Operator ask (2026-11-09): "when someone makes a mesh in the mesh node images studio
path, they should have the option to save that mesh before proceeding to the build as
well as starting that mesh locally as the build proceeds".

What a person sees is asserted as geometry (the strip is drawn, above the Continue
card, with a status line after a save), and a render is written when
``HUGMESH_SHOT_DIR`` is set so the screen can be looked at, not only queried.
"""
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6)")

from hugmesh_studio.core import images_mesh, saved_meshes  # noqa: E402
from hugmesh_studio.core import host_resources as hr  # noqa: E402
from hugmesh_studio.core import resource_limits as rl  # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig, User  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import _images_mesh as im_gui  # noqa: E402
from hugmesh_studio.gui.pages import launch as launch_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(736, 736)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_cfg(tmp_path) -> ImageConfig:
    c = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    cluster_domain="acme.example", output_dir=str(tmp_path / "out"))
    c.domains = [Domain(name="chat.acme.example", title="Chat",
                        optional_services=["tuwunel"])]
    c.additional_domains = True
    c.domain_services_reviewed = ["acme.example", "chat.acme.example"]
    c.users = [User(username="root-admin", role="superadmin")]
    return c


def _launch(wiz, cfg):
    """The LaunchPage as the mesh flow reaches it: cfg + committed worklist."""
    wiz.cfg = cfg
    wiz.worklist = WorklistConfig(base=cfg, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5")])
    page = wiz.page(wiz._page_ids["launch"])
    wiz.setStartId(wiz._page_ids["launch"])
    wiz.restart()
    assert wiz.currentPage() is page
    return page


def _pump(qapp, until, timeout=30.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        qapp.processEvents()
        if until():
            return True
        time.sleep(0.01)
    return False


def _top_in(page, w) -> int:
    return w.mapTo(page, w.rect().topLeft()).y()


def _settle(qapp, rounds=5):
    for _ in range(rounds):
        qapp.processEvents()


def _fully_drawn(label) -> bool:
    """A word-wrapped label is given at least the height its text needs at its width
    (a clipped label still answers text() — only geometry says it is cut off)."""
    need = label.heightForWidth(label.width()) if label.hasHeightForWidth() else \
        label.sizeHint().height()
    return label.height() >= need


def _shot(widget, name):
    d = os.environ.get("HUGMESH_SHOT_DIR")
    if d:
        os.makedirs(d, exist_ok=True)
        widget.grab().save(os.path.join(d, name))


# ── LaunchPage ────────────────────────────────────────────────────────────────
def test_strip_is_drawn_above_the_cards_on_the_mesh_flow(qapp, wiz, tmp_path):
    page = _launch(wiz, _mesh_cfg(tmp_path))
    qapp.processEvents()
    strip = page.mesh_strip
    assert strip.isVisible()
    assert strip.height() > 60 and strip.save_btn.width() > 40
    assert _top_in(page, strip) < _top_in(page, page.continue_card)
    assert strip.name_edit.placeholderText()          # the derived name is offered
    assert strip.autosave_cb.isChecked() and not strip.start_cb.isChecked()
    assert page.continue_card.isEnabled()
    _shot(wiz, "launch-save-strip.png")


def test_strip_is_hidden_off_the_mesh_flow(qapp, wiz, tmp_path):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      output_dir=str(tmp_path / "out"))
    page = _launch(wiz, cfg)
    qapp.processEvents()
    assert not page.mesh_strip.isVisible()


def test_save_then_save_again_updates_one_record(qapp, wiz, tmp_path):
    page = _launch(wiz, _mesh_cfg(tmp_path))
    strip = page.mesh_strip
    strip.name_edit.setText("acme from the images")
    strip.save_btn.click()
    assert _pump(qapp, lambda: strip._save_probe is None and strip.status.text()
                 and not strip.status.text().startswith("Saving"))
    assert "Saved mesh" in strip.status.text() and "not run yet" in strip.status.text()
    assert strip.status.isVisible() and strip.status.height() > 0
    rid = wiz.saved_mesh_id
    assert rid and strip.save_btn.text() == "Save again (update)"
    _shot(wiz, "launch-save-strip-saved.png")
    strip.save_btn.click()
    assert _pump(qapp, lambda: strip._save_probe is None
                 and "updated" in strip.status.text())
    recs = saved_meshes.scan()[0]
    assert [r.id for r in recs] == [rid]
    assert recs[0].label == "acme from the images"
    assert recs[0].build_text() == "from node images (2 images)"
    assert recs[0].run_state() == "draft"


def test_a_failed_save_says_so_inline(qapp, wiz, tmp_path, monkeypatch):
    monkeypatch.setattr(images_mesh, "save", lambda *a, **k: images_mesh.SaveResult(
        False, "the disk is full"))
    page = _launch(wiz, _mesh_cfg(tmp_path))
    page.mesh_strip.save_btn.click()
    assert _pump(qapp, lambda: "disk is full" in page.mesh_strip.status.text())
    assert "Not saved" in page.mesh_strip.status.text()
    assert not getattr(wiz, "saved_mesh_id", "")


def test_the_services_gate_still_bites_with_the_strip(qapp, wiz, tmp_path, monkeypatch):
    """Saving is not a way past the per-domain services gate (#495)."""
    page = _launch(wiz, _mesh_cfg(tmp_path))
    monkeypatch.setattr(launch_mod, "gate_reason", lambda cfg, action: "refused: x")
    page.mesh_strip.save_btn.click()
    _pump(qapp, lambda: page.mesh_strip._save_probe is None)
    assert page.validatePage() is False
    assert not page.continue_card.isEnabled()
    assert page.gate_err.isVisible()


def test_ticking_start_shows_the_gate_verdict(qapp, wiz, tmp_path, monkeypatch):
    """A 31 GiB host while the build holds its cap: the strip says the local copy
    would NOT start, and that the build runs either way."""
    real = images_mesh.plan_alongside
    mi = {"MemTotal": int(31.1 * hr.GIB), "MemAvailable": 24 * hr.GIB}
    seen = []

    def fake(boot, building, backend=None):
        seen.append(backend)
        return real(boot, building=building, backend=backend, env={}, meminfo=mi,
                    limits=rl.auto_limits(nproc=8, meminfo=mi),
                    is_free=lambda p: True, holder=lambda p: "")
    monkeypatch.setattr(images_mesh, "plan_alongside", fake)
    page = _launch(wiz, _mesh_cfg(tmp_path))
    wiz.build_backend = "docker"                 # the Build screen's backend choice
    page.mesh_strip.start_cb.setChecked(True)
    assert wiz.images_mesh_start_local is True
    assert _pump(qapp, lambda: page.mesh_strip._gate_probe is None
                 and "NOT start" in page.mesh_strip.gate.text())
    assert "not enough memory" in page.mesh_strip.gate.text()
    assert "build itself runs either way" in page.mesh_strip.gate.text()
    assert page.mesh_strip.gate.isVisible()
    _settle(qapp)
    for lab in (page.mesh_strip.gate, page.mesh_strip.note):
        assert _fully_drawn(lab), (lab.text()[:40], lab.height(),
                                   lab.heightForWidth(lab.width()))
    assert _top_in(page, page.mesh_strip.gate) + page.mesh_strip.gate.height() <= \
        _top_in(page, page.continue_card)
    _shot(wiz, "launch-start-refused.png")
    page.mesh_strip.autosave_cb.setChecked(False)
    assert wiz.images_mesh_autosave is False
    assert seen == ["docker"]                    # the build's backend reached the gate


def test_the_gate_refuses_beside_a_native_build_whatever_the_memory(qapp, wiz,
                                                                    tmp_path,
                                                                    monkeypatch):
    """PR #937 round 2: the default backend on a Gentoo host is NATIVE, which runs with
    no memory cap at all (build_driver: native has no cgroup cap). The gate used to
    subtract HUGMESH_BUILD_MEMORY's auto value anyway and say a 128 GiB host 'fits'.
    The strip now hands the gate the wizard's backend, and a native build refuses."""
    real = images_mesh.plan_alongside
    mi = {"MemTotal": 128 * hr.GIB, "MemAvailable": 120 * hr.GIB}
    seen = []

    def fake(boot, building, backend=None):
        seen.append(backend)
        return real(boot, building=building, backend=backend, env={}, meminfo=mi,
                    is_free=lambda p: True, holder=lambda p: "")
    monkeypatch.setattr(images_mesh, "plan_alongside", fake)
    page = _launch(wiz, _mesh_cfg(tmp_path))
    wiz.build_backend = None                     # "auto": the host default
    assert wiz.host.default_backend == "native"
    page.mesh_strip.start_cb.setChecked(True)
    assert _pump(qapp, lambda: page.mesh_strip._gate_probe is None
                 and "NOT start" in page.mesh_strip.gate.text())
    assert seen == ["native"]
    assert "native build" in page.mesh_strip.gate.text()
    assert "no memory cap" in page.mesh_strip.gate.text()
    _settle(qapp)
    assert _fully_drawn(page.mesh_strip.gate)
    _shot(wiz, "launch-start-refused-native.png")


# ── ProgressPage panel ─────────────────────────────────────────────────────────
class _Session:
    id = "20261110-020202-abcdef"


def test_dispatch_save_writes_the_session_into_the_flows_record(qapp, wiz, tmp_path):
    cfg = _mesh_cfg(tmp_path)
    page = _launch(wiz, cfg)
    page.mesh_strip.save_btn.click()
    assert _pump(qapp, lambda: bool(getattr(wiz, "saved_mesh_id", "")))
    rid = wiz.saved_mesh_id
    panel = im_gui.LocalMeshPanel()
    panel.begin(wiz, _Session())
    assert _pump(qapp, lambda: "points at this build" in panel.status.text())
    rec = saved_meshes.find(rid)
    assert rec.build["session_id"] == _Session.id
    assert len(saved_meshes.scan()[0]) == 1
    assert not panel.stop_btn.isVisible()          # nothing was started


def test_no_panel_when_neither_choice_is_on(qapp, wiz, tmp_path):
    _launch(wiz, _mesh_cfg(tmp_path))
    wiz.images_mesh_autosave = False
    wiz.images_mesh_start_local = False
    panel = im_gui.LocalMeshPanel()
    panel.begin(wiz, _Session())
    qapp.processEvents()
    assert panel.isHidden()
    assert saved_meshes.scan()[0] == []


def test_a_failed_local_start_is_a_line_not_a_failed_build(qapp, wiz, tmp_path,
                                                            monkeypatch):
    _launch(wiz, _mesh_cfg(tmp_path))
    wiz.images_mesh_start_local = True

    def refused(self, *, building, on_line=None, cancel=None, **_k):
        on_line("This mesh will NOT start beside the build:")
        on_line("  - host port 8000 is already in use by hugmesh-local-casdoor-1")
        return False, []
    monkeypatch.setattr(images_mesh.AlongsideMesh, "start", refused)
    panel = im_gui.LocalMeshPanel()
    panel.resize(700, 300)
    panel.begin(wiz, _Session())
    panel.show()
    assert _pump(qapp, lambda: "did NOT start" in panel.run_status.text())
    assert "8000" in panel.tail.toPlainText()
    assert "build is not affected" in panel.run_status.text()
    assert not panel.stop_btn.isVisible()          # the gate refused: nothing to stop
    assert panel.status.text().count("acme") == 1  # the name is said once
    _shot(panel, "progress-local-mesh-refused.png")


def test_the_panel_starts_with_the_sessions_backend(qapp, wiz, tmp_path, monkeypatch):
    """The dispatch-time start gates on the backend the build was DISPATCHED with
    (the session's), so the cap it subtracts is the one the build really has."""
    _launch(wiz, _mesh_cfg(tmp_path))
    wiz.images_mesh_start_local = True
    wiz.build_backend = None
    seen = []

    def start(self, *, building, backend=None, on_line=None, cancel=None, **_k):
        seen.append((building, backend))
        return False, []
    monkeypatch.setattr(images_mesh.AlongsideMesh, "start", start)

    class _DockerSession(_Session):
        backend = "docker"
    panel = im_gui.LocalMeshPanel()
    panel.begin(wiz, _DockerSession())
    assert _pump(qapp, lambda: bool(seen))
    assert seen == [(True, "docker")]
    seen.clear()
    panel2 = im_gui.LocalMeshPanel()
    panel2.begin(wiz, _Session())                # no session backend: the host's
    assert _pump(qapp, lambda: bool(seen))
    assert seen == [(True, "native")]


def test_start_then_stop_from_the_panel(qapp, wiz, tmp_path, monkeypatch):
    _launch(wiz, _mesh_cfg(tmp_path))
    wiz.images_mesh_start_local = True
    calls = []
    monkeypatch.setattr(images_mesh.AlongsideMesh, "start",
                        lambda self, **k: (k["on_line"]("[local mesh] up"), (True, []))[1])
    monkeypatch.setattr(images_mesh.AlongsideMesh, "stop",
                        lambda self: calls.append(self.project) or
                        (True, [f"[local mesh] stopped {self.project}"]))
    panel = im_gui.LocalMeshPanel()
    panel.begin(wiz, _Session())
    panel.show()
    assert _pump(qapp, lambda: "is UP" in panel.run_status.text())
    assert panel.stop_btn.isVisible() and panel.stop_btn.isEnabled()
    panel.stop_btn.click()
    assert _pump(qapp, lambda: panel.stop_btn.text() == "Stopped")
    assert calls == [images_mesh.project_for(wiz.saved_mesh_id)]


def test_progress_dispatch_survives_a_panel_that_raises(monkeypatch, qapp, wiz,
                                                        tmp_path):
    """The build's dispatch calls the panel inside a guard: a panel that blows up
    must not stop the worker from starting."""
    from hugmesh_studio.core import worklist_driver as wd

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            return 0

        def cancel(self):
            pass

        def preflight(self, cfg, backend):
            return []

        def preflight_warnings(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return "cmd"
    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)

    class _P:
        def __init__(self):
            self.stdout = iter([])

        def wait(self):
            return 0
    monkeypatch.setattr(wd.subprocess, "Popen", lambda cmd, **kw: _P())
    cfg = _mesh_cfg(tmp_path)
    wiz.cfg = cfg
    wiz.worklist = WorklistConfig(base=cfg, entries=[WorklistEntry(role="pki",
                                                                   platform="x86")])
    wiz.build_backend = None
    wiz.generate_node_keys = False
    page = wiz.page(wiz._page_ids["progress"])

    def boom(*_a, **_k):
        raise RuntimeError("panel exploded")
    monkeypatch.setattr(page.local_mesh, "begin", boom)
    page.initializePage()
    assert page.worker is not None
    page.worker.wait(5000)
    assert _pump(qapp, page.isComplete)
    assert page.driver.results[0].status == "ok"


def test_look_at_the_progress_page_with_the_panel(monkeypatch, qapp, wiz, tmp_path):
    """The whole progress page of a mesh build whose local copy was refused: the panel
    sits between the overall bar and the image rows, and its status is fully drawn."""
    from hugmesh_studio.core import worklist_driver as wd

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            return 0

        def cancel(self):
            pass

        def preflight(self, cfg, backend):
            return []

        def preflight_warnings(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return "cmd"
    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)

    def refused(self, *, building, on_line=None, cancel=None, **_k):
        on_line("This mesh will NOT start beside the build:")
        on_line("  - host port 8000 is already in use by hugmesh-local-casdoor-1")
        return False, []
    monkeypatch.setattr(images_mesh.AlongsideMesh, "start", refused)
    cfg = _mesh_cfg(tmp_path)
    wiz.cfg = cfg
    wiz.worklist = WorklistConfig(base=cfg, entries=[WorklistEntry(role="pki",
                                                                   platform="x86")])
    wiz.build_backend = None
    wiz.generate_node_keys = False
    wiz.images_mesh_start_local = True
    wiz.setStartId(wiz._page_ids["progress"])
    wiz.restart()
    page = wiz.currentPage()
    assert page is wiz.page(wiz._page_ids["progress"])
    page.worker.wait(5000)
    assert _pump(qapp, lambda: page.isComplete()
                 and "did NOT start" in page.local_mesh.run_status.text())
    _settle(qapp)
    panel = page.local_mesh
    assert panel.isVisible() and _fully_drawn(panel.status) and \
        _fully_drawn(panel.run_status)
    assert _top_in(page, page.total_bar) < _top_in(page, panel) < _top_in(page, page.tree)
    assert page.driver.results[0].status == "ok"
    rec = saved_meshes.scan()[0][0]
    assert rec.build["session_id"] == page._session.id
    _shot(wiz, "progress-page-local-mesh.png")
