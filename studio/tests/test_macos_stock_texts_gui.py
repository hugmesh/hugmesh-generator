"""The window's half of tests/test_macos_stock_texts.py: a Mac that has not installed
Homebrew's GNU tools is told Mac things on every page that shows the refusal, and the
``brew install`` command is on a line of its own, where it can be seen and copied.

Two defects, both LOOKED at here (offscreen), not only read:

* the QEMU page's note added "To boot ONE x86 device image ... on this PC without WSL2,
  open Mesh emulation and choose the backend "QEMU for Windows (WHPX)"" to the Mac
  sentence; the tray said "needs WSL2 on Windows"; the local-mesh page, the saved
  meshes and the Kubernetes gate sent the Mac to "the Studio inside WSL2"; the Studio
  panel said "Ollama for Windows runs in the background";
* the notes are RichText, which drops a bare newline, so the sentence read "... with
  Homebrew (https://brew.sh): brew install bash coreutils gnu-sed findutils grep make
  then restart the Studio." as one run of text. ``_emulation_common.blocker_html``
  breaks the lines; the real page is laid out at 1200x800 and 942x552 and the command
  must be a visual line by itself, inside the window. ``HUGMESH_STUDIO_SHOTS`` names a
  folder to keep the pictures in.
"""
from __future__ import annotations

import html
import os
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import emulation, local_ai_status as lai       # noqa: E402
from hugmesh_studio.core import macos_host, platform_info, qemu_tests   # noqa: E402
from hugmesh_studio.core import ollama_docker as odk                    # noqa: E402
from hugmesh_studio.core.build_driver import BuildDriver                # noqa: E402
from hugmesh_studio.core.local_stack_node import LocalStackNode         # noqa: E402
from hugmesh_studio.core.platform_info import SESSION_COCOA, HostInfo   # noqa: E402
from hugmesh_studio.gui import tray as tray_mod                         # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.pages import _emulation_common as common       # noqa: E402
from hugmesh_studio.gui.pages import _saved_meshes_widget as saved_mod  # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as lc_mod         # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                # noqa: E402
from hugmesh_studio.gui.pages import mesh_emulation as me_page          # noqa: E402
from hugmesh_studio.gui.pages import qemu as qemu_page                  # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets              # noqa: E402

from _helpers import advance_to, pick_mode                              # noqa: E402
from test_macos_stock_texts import MISSING, WINDOWS_WORDS, _as_a_mac    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SIZES = ((1200, 800), (942, 552))
MAC = HostInfo(os="darwin", is_gentoo=False, has_docker=True, has_bash=True, has_kvm=False,
               is_root=False, builder_image="hugmesh-builder", session=SESSION_COCOA,
               mac_arch="arm64", docker_runtime="colima", docker_vm_mem=16 * 2**30,
               docker_vm_cpus=8, gnu_missing=tuple(MISSING))
WINDOWS_SENTENCE = platform_info.host_script_blocker(
    "QEMU device tests and mesh emulation", osname="nt", runs="bash scripts")


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def stock_mac(monkeypatch):
    _as_a_mac(monkeypatch, MISSING)


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _no_windows_words(text: str, where: str) -> None:
    found = sorted({m.group(0) for m in WINDOWS_WORDS.finditer(text)})
    assert not found, f"{where} says {found} on a Mac:\n{text}"


def _settle(app, n: int = 5) -> None:
    for _ in range(n):
        app.processEvents()


# ── the sentence as RichText ────────────────────────────────────────────────────────
def test_blocker_html_keeps_the_command_on_its_own_line():
    mac = platform_info.host_script_blocker("X", sysplatform="darwin", gnu_missing=MISSING)
    lines = common.blocker_html(mac).split("<br>")
    assert len(lines) == 3
    assert lines[0].endswith("Install them with Homebrew (https://brew.sh):")
    assert lines[1] == f"&nbsp;&nbsp;&nbsp;&nbsp;<tt>{macos_host.BREW_INSTALL}</tt>"
    assert lines[2].startswith("then restart the Studio.")


def test_blocker_html_is_html_escape_for_the_windows_sentence():
    """One line, nothing to break: the Windows note's markup is what it was."""
    assert common.blocker_html(WINDOWS_SENTENCE) == html.escape(WINDOWS_SENTENCE)
    assert common.blocker_html("a <distro> & b") == html.escape("a <distro> & b")


def _visual_lines(label: QtWidgets.QLabel) -> list[str]:
    """The label's text as it is LAID OUT at its current width: one string per line on
    screen. Built with the label's own font and width, as QLabel lays RichText out."""
    doc = QtGui.QTextDocument()
    doc.setDefaultFont(label.font())
    doc.setDocumentMargin(0)
    doc.setHtml(label.text())
    doc.setTextWidth(max(1, label.contentsRect().width()))
    doc.size()                                   # lay it out: lines exist only after
    out = []
    block = doc.begin()
    while block.isValid():
        layout, text = block.layout(), block.text()
        for i in range(layout.lineCount()):
            line = layout.lineAt(i)
            out.append(text[line.textStart():line.textStart() + line.textLength()]
                       .replace(" ", " ").replace(" ", "").strip())
        block = block.next()
    return out


# ── the QEMU device-tests page, as a stock Mac sees it ──────────────────────────────
@pytest.fixture
def mac_qemu_page(qapp, monkeypatch, stock_mac):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": MAC)
    monkeypatch.setattr(qemu_tests, "docker_available", lambda: (True, "docker is available."))
    monkeypatch.setattr(LocalStackNode, "e2e_ready",
                        lambda self, environment="docker": ["stubbed probe"])
    monkeypatch.setattr(emulation, "_runner_devices", lambda *a, **k: None)
    monkeypatch.setattr(emulation, "_docker_running_names", lambda: None)
    monkeypatch.setattr(BuildDriver, "builder_image_missing", lambda self, backend=None: False)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    _settle(qapp)
    pick_mode(wiz, "e2e")
    advance_to(wiz, wizard_mod.E2EPage).arm_qemu.setChecked(True)
    page = advance_to(wiz, wizard_mod.QemuPage)
    _settle(qapp, 10)
    yield wiz, page
    probe = getattr(page, "docker_probe", None)
    if probe is not None and hasattr(probe, "wait"):
        try:
            probe.wait(5000)
        except (RuntimeError, TypeError):
            pass
    wiz.close()
    wiz.deleteLater()
    _settle(qapp)


def test_the_qemu_page_note_is_the_macs_and_the_command_is_a_line_by_itself(
        qapp, mac_qemu_page, tmp_path):
    wiz, page = mac_qemu_page
    note = page.docker_note
    _no_windows_words(note.text(), "the QEMU page's availability note")
    assert macos_host.BREW_INSTALL in note.text()
    assert not page._docker_ok                       # the lanes stay disabled
    shots = os.environ.get("HUGMESH_STUDIO_SHOTS") or str(tmp_path)
    os.makedirs(shots, exist_ok=True)
    for width, height in SIZES:
        wiz.resize(width, height)
        _settle(qapp)
        area = note.parentWidget()
        while area is not None and not isinstance(area, QtWidgets.QScrollArea):
            area = area.parentWidget()
        if area is not None:
            area.ensureWidgetVisible(note)
            _settle(qapp)
        assert note.isVisible()
        rect = QtCore.QRect(note.mapTo(wiz, QtCore.QPoint(0, 0)), note.size())
        assert wiz.rect().contains(rect), (width, height, rect, wiz.rect())
        lines = _visual_lines(note)
        assert macos_host.BREW_INSTALL in lines, (
            f"at {width}x{height} the brew command is not a line by itself: {lines}")
        at = lines.index(macos_host.BREW_INSTALL)
        assert lines[at - 1].endswith("(https://brew.sh):")
        assert lines[at + 1].startswith("then restart the Studio.")
        # tall enough for what it shows (Qt's own answer for this width): nothing is
        # clipped off the bottom, and three lines are not squeezed into one
        assert note.height() >= note.heightForWidth(note.width()) > 0, (
            width, height, note.height(), note.heightForWidth(note.width()))
        assert note.height() >= 3 * note.fontMetrics().height()
        path = os.path.join(shots, f"qemu-page-stock-mac-{width}x{height}.png")
        assert wiz.grab().save(path), path
        assert os.path.getsize(path) > 1000


def test_the_qemu_chain_note_breaks_the_command_out_too(stock_mac):
    text = qemu_page.QemuPage._chain_note_text()
    _no_windows_words(text, "the build-first note")
    assert f"<br>&nbsp;&nbsp;&nbsp;&nbsp;<tt>{macos_host.BREW_INSTALL}</tt><br>" in text
    assert "will <b>not</b> run after it here" in text


def _paint_docker_note(qapp) -> str:
    fake = SimpleNamespace(docker_note=QtWidgets.QLabel(""), _docker_ok=True,
                           _sync_controls=lambda: None)
    qemu_page.QemuPage._docker_answered_paint(fake, (True, "docker is available."))
    text = fake.docker_note.text()
    assert fake._docker_ok is False
    fake.docker_note.deleteLater()
    return text


def test_the_windows_qemu_note_is_unchanged(qapp, monkeypatch):
    """The MSI still gets its WSL2 sentence and the way round it."""
    monkeypatch.setattr(qemu_tests, "native_blocker", lambda: WINDOWS_SENTENCE)
    text = _paint_docker_note(qapp)
    assert text == (
        f'<span style="color:{qemu_page.WARN}">{html.escape(WINDOWS_SENTENCE)}</span><br>'
        "To boot ONE x86 device image (a thin desktop or a single node) on "
        "this PC without WSL2, open Mesh emulation and choose the backend "
        "“QEMU for Windows (WHPX)”.")


def test_a_stand_in_sentence_still_gets_the_windows_note(qapp, monkeypatch):
    """A plain str blocker is what the Windows tests (and any caller) pass."""
    monkeypatch.setattr(qemu_tests, "native_blocker", lambda: "REFUSED HERE")
    assert "QEMU for Windows (WHPX)" in _paint_docker_note(qapp)


def test_the_mac_qemu_note_offers_no_windows_backend(qapp, stock_mac):
    text = _paint_docker_note(qapp)
    _no_windows_words(text, "the QEMU page's availability note")
    assert text == (f'<span style="color:{qemu_page.WARN}">'
                    f"{common.blocker_html(qemu_tests.native_blocker())}</span>")


def test_the_playwright_lane_note_breaks_the_command_out(stock_mac):
    blocker = emulation.playwright_root_blocker()
    assert platform_info.blocker_kind(blocker) == "darwin"
    assert qemu_page._root_blocker_html(blocker) == common.blocker_html(blocker)
    # the Linux "needs root" sentence and a Windows one are shown as they always were
    assert qemu_page._root_blocker_html("needs root: a <b>plain</b> one") == \
        "needs root: a <b>plain</b> one"
    assert qemu_page._root_blocker_html(WINDOWS_SENTENCE) == WINDOWS_SENTENCE


# ── Mesh emulation: the chooser and its note ────────────────────────────────────────
def test_the_mesh_emulation_note_is_the_macs(qapp, stock_mac):
    fake = SimpleNamespace(_whpx=False, docker_note=QtWidgets.QLabel(""),
                           _docker_answer=(True, "ok"), _sync_controls=lambda: None)
    me_page.MeshEmulationPage._paint_note(fake)
    text = fake.docker_note.text()
    fake.docker_note.deleteLater()
    _no_windows_words(text, "the Mesh emulation page's availability note")
    assert f"<tt>{macos_host.BREW_INSTALL}</tt>" in text


# ── tray ────────────────────────────────────────────────────────────────────────────
class _Node:
    started = 0

    def status(self):
        return SimpleNamespace(running=False, detail="not started")

    def start(self):
        self.started += 1
        return False, "should not be reached"


def _section(blocker):
    sec = tray_mod._Section(_Node(), label="local stack", blocker=blocker)
    menu = QtWidgets.QMenu()
    sec.add_to_menu(menu)
    sec.tray = SimpleNamespace(_notify=lambda *a: None, _refresh=lambda: None)
    return sec, menu


def test_the_tray_says_gnu_tools_on_a_mac_and_wsl2_on_windows(qapp, stock_mac):
    said = tray_mod._stack_section(GENERATOR_DIR).blocker()
    assert platform_info.blocker_kind(said) == "darwin"
    sec, _menu = _section(lambda: said)
    sec.refresh()
    assert sec.status_act.text() == \
        "local stack: needs the GNU tools on this Mac (hover for how)"
    assert sec.start_act.toolTip() == said and not sec.start_act.isEnabled()
    win = platform_info.native_windows_blocker("The local stack", osname="nt")
    sec, _menu = _section(lambda: win)
    sec.refresh()
    assert sec.status_act.text() == "local stack: needs WSL2 on Windows (hover for why)"


# ── local mesh: the running-mesh sentences ──────────────────────────────────────────
def _mesh_state_text(qapp) -> str:
    fake = SimpleNamespace(
        _mesh_state_label=QtWidgets.QLabel(""), _running=True, _saved_stale=False,
        _monitor=None, _monitor_stale=False, _refresh_monitor=lambda why: False,
        _sync_monitor_gate=lambda: None,
        monitor_section=SimpleNamespace(is_expanded=lambda: False))
    lm_mod.LocalMeshPage._on_mesh_state(fake, True, "12 containers")
    text = fake._mesh_state_label.text()
    fake._mesh_state_label.deleteLater()
    return text


def test_a_running_mesh_on_a_stock_mac_is_told_the_brew_line(qapp, stock_mac):
    text = _mesh_state_text(qapp)
    _no_windows_words(text, "the local-mesh state line")
    assert text.startswith("Mesh state: RUNNING — 12 containers. This Mac cannot stop it yet")
    assert f"`{macos_host.BREW_INSTALL}`" in text
    said = saved_mod.native_windows_running_mesh()
    _no_windows_words(said, "the saved-meshes refusal")
    assert "this Mac cannot stop it yet" in said and f"`{macos_host.BREW_INSTALL}`" in said


def test_a_running_mesh_on_windows_keeps_its_sentences(qapp, monkeypatch):
    win = platform_info.native_windows_blocker("The local stack", osname="nt")
    monkeypatch.setattr(lm_mod.LocalMeshBootstrap, "teardown_refusal",
                        staticmethod(lambda osname=None: win))
    assert _mesh_state_text(qapp) == (
        "Mesh state: RUNNING — 12 containers. The Windows build of the Studio "
        "cannot stop it (Stop runs `make` and bash scripts); stop it where it "
        "was started, such as the Studio inside WSL2.")
    assert "such as the Studio inside WSL2" in saved_mod.native_windows_running_mesh()


def test_a_running_mesh_where_stop_works_is_unchanged(qapp, monkeypatch):
    monkeypatch.setattr(lm_mod.LocalMeshBootstrap, "teardown_refusal",
                        staticmethod(lambda osname=None: ""))
    assert "stop it first if you want a clean bring-up" in _mesh_state_text(qapp)
    assert saved_mod.native_windows_running_mesh() == ""


# ── the local Kubernetes gate ───────────────────────────────────────────────────────
def _gate_text(blocker: str) -> str:
    fake = SimpleNamespace(_running=False, _k8s_up=True,
                           _teardown_blocker=lambda: blocker)
    return lc_mod.LocalCloudNodesPage._gate_text(fake)


def test_the_kubernetes_gate_does_not_send_a_mac_to_wsl2(stock_mac):
    said = lc_mod.k8s_teardown_blocker()
    assert platform_info.blocker_kind(said) == "darwin"
    text = _gate_text(said)
    _no_windows_words(text, "the Kubernetes gate")
    assert macos_host.BREW_INSTALL in text
    assert "this page can delete the cluster itself" in text


def test_the_kubernetes_gate_on_windows_is_unchanged():
    win = lc_mod.k8s_teardown_blocker("nt")
    text = _gate_text(win)
    assert win in text and "delete the cluster from WSL2" in text and "Back and Next" in text


# ── the Studio panel ────────────────────────────────────────────────────────────────
def _down_snapshot():
    return odk.adjust_snapshot(
        lai.read_snapshot({"OLLAMA_HOST": "127.0.0.1:1"}, builds=lambda: [],
                          probe=lambda: (False, [], [], "")), odk.SYSTEM)


def test_the_studio_panel_names_no_windows_ollama_on_a_stock_mac(qapp, stock_mac,
                                                                 monkeypatch):
    real = lai.shutil.which
    monkeypatch.setattr(lai.shutil, "which",
                        lambda name, *a, **k: None if name == "ollama" else real(name, *a, **k))
    from hugmesh_studio.gui import _local_ai_dock as dock_mod
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=_down_snapshot, auto_poll=False)
    work = dock_mod.LocalWorkWindow(GENERATOR_DIR, snapshot_fn=_down_snapshot)
    try:
        tip = dock.start_btn.toolTip()
        _no_windows_words(tip, "the Start local assistant tooltip")
        assert tip == lai.start_tooltip() and macos_host.BREW_INSTALL in tip
        dock.ollama_mode = odk.SYSTEM
        dock._render_instance()
        _no_windows_words(dock.docker_label.text(), "the system-Ollama line")
        assert dock.docker_label.text() == lai.system_ollama_note()
        work.show_snapshot(_down_snapshot())
        _no_windows_words(work.commands.text(), "the run-it-yourself line")
        assert macos_host.BREW_INSTALL in work.commands.text()
    finally:
        dock.deleteLater()
        work.deleteLater()
        qapp.processEvents()
