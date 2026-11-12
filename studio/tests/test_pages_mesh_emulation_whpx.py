"""MeshEmulationPage under the QEMU for Windows (WHPX) backend.

The operator ask (2026-11-04): QEMU's own Windows build as an emulation option on
Windows, in the GUI, the TUI and the CLI — "only small thin desktop device images or
single nodes". On this page that is a backend chooser built from
``qemu_windows.BACKENDS``: under it each x86 row's Start/Stop call
``qemu_windows.start``/``stop`` off the GUI thread, ARM rows and every Docker-runner
verb (whole-mesh start, QMP, saves, replicas) are greyed with the reason on them, and
the availability note is ``qemu_windows.blocker()`` or its ready line.

WHAT IS FAKED, AND HOW
----------------------
No real QEMU and no Windows: a QEMU folder of empty files in tmp_path is the install
``find_qemu`` answers with, ``_WHPX_DLL`` points at an empty file there, and
``blocker`` answers as ``os.name == "nt"`` would. ``qemu_windows.start``/``stop``/
``running`` are replaced at the module boundary — the page calls them and nothing
else, which is what these tests pin. The Docker lane's own fixtures (the pinned Linux
host, the stubbed docker probe and registry shell-outs) are the ones
test_pages_mesh_emulation.py uses, so the page is built exactly as there.
"""
import functools
import html
import os
import threading

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import emulation, platform_info              # noqa: E402
from hugmesh_studio.core import qemu_devices, qemu_tests              # noqa: E402
from hugmesh_studio.core import qemu_windows as qw                     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import mesh_emulation as page_mod        # noqa: E402
from hugmesh_studio.gui.pages.qemu import QemuPage                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402

from _helpers import advance_to, pick_mode                             # noqa: E402

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

_REAL_NATIVE_BLOCKER = platform_info.native_windows_blocker
_REAL_QW_BLOCKER = qw.blocker


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    # The Docker lane's WSL2 refusal reads the REAL os.name; answer as the pinned
    # Linux host does unless a test says it is a native Windows Studio.
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_NATIVE_BLOCKER, osname="posix"))
    # ...and for the backend chooser, which a Mac is offered a shorter one of
    # (qemu_windows.backends): on a developer's Mac this file still answers as Linux.
    real_kind = platform_info.host_kind
    monkeypatch.setattr(platform_info, "host_kind",
                        lambda osname=None, sysplatform=None:
                        real_kind(osname, sysplatform or "linux"))


@pytest.fixture(autouse=True)
def _docker_stubbed(monkeypatch):
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


@pytest.fixture(autouse=True)
def _status_reads_only_the_registry(monkeypatch):
    monkeypatch.setattr(emulation, "_runner_devices", lambda *_a, **_k: None)
    monkeypatch.setattr(emulation, "_docker_running_names", lambda: None)


@pytest.fixture(autouse=True)
def live(monkeypatch):
    """The QEMU for Windows devices ``qemu_windows.running`` reports — none until a
    test (or a fake start) puts one here."""
    records: list[dict] = []
    monkeypatch.setattr(qw, "running", lambda work_dir, alive=None: list(records))
    return records


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def fake_generator(tmp_path):
    """One COMPLETE session: an ARM (rpi5) image and two x86 ones."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260810-101010-mesh"
    sess.mkdir(parents=True)
    for n in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
              "hugmesh-x86-amd64-be-test-20260807T172418Z.img",
              "hugmesh-x86-amd64-fe-test-20260807T172419Z.img"):
        (sess / n).write_bytes(b"\0")
    for i in range(3):
        (sess / f"build-image{i}.log").write_text("ok\n")
    (gen / "tests" / "qemu").mkdir(parents=True)
    return gen


@pytest.fixture
def fake_install(tmp_path):
    """A QEMU for Windows folder of empty files — enough for every file check."""
    qdir = tmp_path / "qemu"
    (qdir / "share").mkdir(parents=True)
    for n in (qw.QEMU_EXE, qw.QEMU_IMG_EXE):
        (qdir / n).write_bytes(b"")
    for n in (qw.CODE_FD, qw.VARS_FD):
        (qdir / "share" / n).write_bytes(b"")
    return qw.QemuInstall(str(qdir), str(qdir / qw.QEMU_EXE), str(qdir / qw.QEMU_IMG_EXE),
                          str(qdir / "share" / qw.CODE_FD),
                          str(qdir / "share" / qw.VARS_FD))


def _as_windows(monkeypatch, install):
    """qemu_windows answers as a native Windows host with ``install`` (or none)."""
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: install)
    monkeypatch.setattr(qw, "blocker", functools.partial(_REAL_QW_BLOCKER, "nt"))


@pytest.fixture
def whpx_ready(tmp_path, monkeypatch, fake_install):
    dll = tmp_path / "WinHvPlatform.dll"
    dll.write_bytes(b"")
    monkeypatch.setattr(qw, "_WHPX_DLL", str(dll))
    _as_windows(monkeypatch, fake_install)
    return fake_install


@pytest.fixture
def wiz(qapp, fake_generator):
    w = wizard_mod.StudioWizard(str(fake_generator))
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _page(wiz):
    pick_mode(wiz, "meshemu")
    return advance_to(wiz, wizard_mod.MeshEmulationPage)


@pytest.fixture
def stock_mac(monkeypatch):
    """This process is a Mac without Homebrew's GNU tools (set up BEFORE the wizard
    builds its pages: name it ahead of ``wiz``)."""
    real = platform_info.host_kind
    # a Mac is posix AND darwin: on a Windows runner os.name is "nt", which host_kind
    # answers before it looks at sys.platform, so both are given
    monkeypatch.setattr(platform_info, "host_kind",
                        lambda osname=None, sysplatform=None:
                        real(osname or "posix", sysplatform or "darwin"))
    monkeypatch.setattr(platform_info, "_GNU_MISSING", ["bash", "gnu-sed", "coreutils"])


def test_a_mac_is_offered_the_docker_backend_alone(stock_mac, wiz, qapp):
    """QEMU for Windows cannot boot anything on a Mac, so the chooser does not offer
    it, and neither its tooltip nor the availability note says anything Windows: the
    note is the Mac's sentence, with the brew command on a line of its own."""
    from hugmesh_studio.core import macos_host
    page = _page(wiz)
    qapp.processEvents()
    combo = page.backend_combo
    assert [combo.itemData(i) for i in range(combo.count())] == [qw.BACKEND_DOCKER]
    assert combo.itemText(0) == qw.DOCKER_LABEL_MACOS
    assert not page._whpx and not page.whpx_opts.isVisible()
    for where, text in (("the chooser's tooltip", combo.toolTip()),
                        ("the availability note", page.docker_note.text())):
        for word in ("Windows", "WSL", "WHPX", "this PC"):
            assert word not in text, (where, word, text)
    assert f"<tt>{macos_host.BREW_INSTALL}</tt>" in page.docker_note.text()
    assert not page._docker_ok                        # every verb stays disabled


def test_the_chooser_is_unchanged_off_a_mac(wiz):
    page = _page(wiz)
    combo = page.backend_combo
    assert tuple((combo.itemData(i), combo.itemText(i)) for i in range(combo.count())) \
        == qw.BACKENDS
    assert "QEMU for Windows (WHPX): ONE x86 device at a time" in combo.toolTip()


def _choose(page, backend):
    page.backend_combo.setCurrentIndex(page.backend_combo.findData(backend))
    assert page.backend_combo.currentData() == backend


def _x86(page):
    return [r for r in page._rows if r.planned.platform == "x86"]


def _arm(page):
    return [r for r in page._rows if r.planned.platform != "x86"]


def _finish(page, qapp, ms=15000):
    assert page.worker is not None, "no verb was started"
    assert page.worker.wait(ms), "the verb never finished"
    qapp.processEvents()


def _rec(row, **over):
    rec = {"label": row.label, "platform": "x86", "pid": 4321, "qmp_port": 4444,
           "ssh_port": 2222, "ui_port": 8443, "http_port": 8080,
           "run_dir": os.path.join("w", "native-runs", "x"), "display": "none",
           "mem_mb": qw.DEFAULT_MEM_MB}
    rec.update(over)
    return rec


# ---- the chooser -------------------------------------------------------------------

def test_the_chooser_lists_exactly_the_core_backends(wiz):
    combo = _page(wiz).backend_combo
    got = tuple((combo.itemData(i), combo.itemText(i)) for i in range(combo.count()))
    assert got == qw.BACKENDS


def test_docker_is_the_default_off_native_windows_even_with_qemu_ready(wiz, whpx_ready):
    page = _page(wiz)
    assert page.backend_combo.currentData() == qw.BACKEND_DOCKER
    assert page.whpx_opts.isHidden()                 # the WHPX options are WHPX's
    assert "privileged Docker container" in page.docker_note.text()


def test_a_native_windows_studio_opens_on_whpx_only_when_it_is_ready(
        qapp, fake_generator, monkeypatch, whpx_ready):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_NATIVE_BLOCKER, osname="nt"))
    w = wizard_mod.StudioWizard(str(fake_generator))
    w.show()
    try:
        page = _page(w)
        assert page.backend_combo.currentData() == qw.BACKEND_WHPX
        assert page.whpx_mem.value() == qw.DEFAULT_MEM_MB
        assert not page.whpx_window.isChecked()
    finally:
        w.close()
        w.deleteLater()


# ---- arming under WHPX ---------------------------------------------------------------

def test_whpx_arms_start_only_for_x86_rows_and_greys_the_runner_verbs(wiz, whpx_ready):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    assert not page.whpx_opts.isHidden()
    assert "ready in" in page.docker_note.text()
    assert html.escape(whpx_ready.dir) in page.docker_note.text()

    assert _x86(page) and _arm(page)
    for row in _x86(page):
        assert row.start.isEnabled(), row.start.toolTip()
        assert "QEMU for Windows" in row.start.toolTip()
        assert not row.stop.isEnabled() and not row.ssh_btn.isEnabled()
    for row in _arm(page):
        assert not row.start.isEnabled()
        assert qw.row_refusal(row.planned.platform) in row.start.toolTip()

    for b in (page.start_btn, page.stop_btn):
        assert not b.isEnabled()
        assert "one" in b.toolTip().lower() and "at a time" in b.toolTip()
    assert not page.mesh_save_btn.isEnabled()
    assert "Not available on QEMU for Windows" in page.mesh_save_btn.toolTip()
    for row in page._rows:
        for button in row.qmp.values():
            assert not button.isEnabled()
            assert "Not available on QEMU for Windows" in button.toolTip()
        assert not row.save.isEnabled() and not row.overwrite.isEnabled()
        assert "Not available on QEMU for Windows" in row.save.toolTip()
        assert not row.replicas.plus.isEnabled()
        assert "at a time" in row.replicas.plus.toolTip()


def test_a_running_native_device_greys_every_other_start(wiz, whpx_ready, live):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    first, second = _x86(page)[:2]
    live.append(_rec(first))
    page._refresh_reality()
    assert first.stop.isEnabled() and first.ssh_btn.isEnabled()
    assert not first.start.isEnabled()
    assert not second.start.isEnabled()
    assert "one device at a time" in second.start.toolTip()
    assert first.label in second.start.toolTip()
    assert "https://127.0.0.1:8443/" in page.web_note.text()


def test_the_blocker_is_the_note_when_qemu_is_missing(wiz, monkeypatch):
    _as_windows(monkeypatch, None)
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    why = qw.blocker(install=False)
    assert qw.INSTALL_HINT in why
    assert qw.INSTALL_HINT in page.docker_note.text()
    for row in _x86(page):
        assert not row.start.isEnabled()
        assert qw.INSTALL_HINT in row.start.toolTip()


def test_on_linux_the_whpx_choice_shows_its_own_refusal(wiz, monkeypatch):
    monkeypatch.setattr(qw, "blocker", functools.partial(_REAL_QW_BLOCKER, "posix"))
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    assert "use the Docker backend" in page.docker_note.text()
    assert not any(row.start.isEnabled() for row in page._rows)


def test_switching_back_to_docker_restores_the_docker_tooltips(wiz, whpx_ready):
    page = _page(wiz)
    before = page.start_btn.toolTip()
    _choose(page, qw.BACKEND_WHPX)
    assert page.start_btn.toolTip() != before
    _choose(page, qw.BACKEND_DOCKER)
    assert page.start_btn.toolTip() == before
    assert page.start_btn.isEnabled()
    row = _x86(page)[0]
    assert row.qmp["pause"].toolTip() == page_mod._QMP_TOOLTIPS["pause"]
    assert row.replicas.plus.toolTip() == page_mod._REPLICAS_PLUS_TIP


# ---- the verbs -----------------------------------------------------------------------

def test_start_and_stop_call_the_core_off_the_gui_thread(wiz, qapp, whpx_ready, live,
                                                         monkeypatch):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    row = _x86(page)[0]
    started, stopped = [], []

    def fake_start(o, **kw):
        started.append((o, kw, threading.get_ident()))
        kw["on_line"]("qemu-system-x86_64.exe …")
        rec = _rec(row, mem_mb=o.mem_mb, display=o.display)
        live.append(rec)
        return rec

    def fake_stop(work_dir, label, **_kw):
        stopped.append((work_dir, label, threading.get_ident()))
        live.clear()
        return f"{label}: powered off."

    monkeypatch.setattr(qw, "start", fake_start)
    monkeypatch.setattr(qw, "stop", fake_stop)
    page.whpx_mem.setValue(1024)
    page.whpx_window.setChecked(True)

    row.start.click()
    _finish(page, qapp)
    (o, kw, tid), = started
    assert tid != threading.get_ident(), "the start ran ON the GUI thread"
    assert o == qw.options_for_row(row.planned, page.plan.work_dir, mem_mb=1024,
                                   display="window")
    assert o.image == row.planned.image and o.platform == "x86"
    assert "Started" in page.note.text() and "127.0.0.1:2222" in page.note.text()
    assert "qemu-system-x86_64.exe" in page.log.toPlainText()
    assert row.stop.isEnabled() and not row.start.isEnabled()

    row.stop.click()
    _finish(page, qapp)
    (work, label, tid), = stopped
    assert (work, label) == (page.plan.work_dir, row.label)
    assert tid != threading.get_ident(), "the stop ran ON the GUI thread"
    assert "powered off" in page.note.text()
    assert row.start.isEnabled() and not row.stop.isEnabled()


def test_a_refused_start_reports_the_core_sentence(wiz, qapp, whpx_ready, monkeypatch):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    why = qw.memory_refusal(2048, 300)

    def refuse(o, **kw):
        raise qw.NativeError(why)

    monkeypatch.setattr(qw, "start", refuse)
    _x86(page)[0].start.click()
    _finish(page, qapp)
    assert "Only 300 MiB of memory is free" in page.note.text()
    assert "REFUSED: Only 300 MiB" in page.log.toPlainText()
    assert page.isComplete()


def test_an_arm_row_start_reached_anyway_is_refused_without_the_core(
        wiz, whpx_ready, monkeypatch):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    monkeypatch.setattr(qw, "start", lambda *_a, **_k: pytest.fail("start was called"))
    arm = _arm(page)[0]
    page._start_device(page._rows.index(arm))
    assert not page._running
    assert "cannot boot on QEMU for Windows" in page.note.text()


def test_runner_verbs_reached_under_whpx_are_refused_inline(wiz, whpx_ready, monkeypatch):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    monkeypatch.setattr(emulation, "spawn",
                        lambda *_a, **_k: pytest.fail("the runner was spawned"))
    page._start_mesh()
    assert "at a time" in page.note.text()
    page._device_qmp(0, "status")
    assert "QMP console" in page.note.text()
    page._save_mesh_clicked()
    assert "Saving the whole mesh" in page.note.text()


def test_ssh_opens_windows_ssh_into_the_forwarded_port(wiz, whpx_ready, live,
                                                       monkeypatch):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    row = _x86(page)[0]
    live.append(_rec(row))
    page._refresh_reality()
    row.user.setEditText("alice")
    calls = []
    monkeypatch.setattr(qemu_devices, "terminal_argv",
                        lambda argv: ["xterm", "-e", *argv])
    monkeypatch.setattr(page_mod.subprocess, "Popen",
                        lambda argv, **kw: calls.append((list(argv), kw)))
    row.ssh_btn.click()
    (argv, kw), = calls
    want = qw.ssh_argv(_rec(row), "alice")
    assert argv[-len(want):] == want
    if os.name == "nt":
        assert kw.get("creationflags")              # a console of its own
    assert "Opened ssh" in page.note.text()


# ---- what the page says under WHPX ---------------------------------------------------

def test_the_verdict_cell_is_a_non_verdict_not_pending(wiz, whpx_ready, live):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    live.append(_rec(_x86(page)[0]))
    page._refresh_reality()
    for r in range(len(page._rows)):
        cell = page.devices.item(r, page_mod._MCOL_VERDICT)
        assert cell.text() == page_mod._WHPX_NO_VERDICT != page_mod.common.PENDING_TEXT
        assert "no verdict on this backend" in cell.toolTip()


def test_the_docker_plan_facts_are_left_out_under_whpx(wiz, whpx_ready):
    page = _page(wiz)
    docker_label = page.plan_label.text()
    docker_tip = page.devices.item(0, page_mod._MCOL_LABEL).toolTip()
    assert "Front door" in docker_label and "planned ssh" in docker_tip
    _choose(page, qw.BACKEND_WHPX)
    assert "Front door" not in page.plan_label.text()
    assert "emulated device(s)</b> planned." in page.plan_label.text()
    for r in range(len(page._rows)):
        tip = page.devices.item(r, page_mod._MCOL_LABEL).toolTip()
        assert tip.startswith("image ")
        assert "planned ssh" not in tip and "mesh identity" not in tip
        assert "KEYS" not in tip
    _choose(page, qw.BACKEND_DOCKER)
    assert page.plan_label.text() == docker_label
    assert page.devices.item(0, page_mod._MCOL_LABEL).toolTip() == docker_tip


def test_refresh_and_the_save_tick_say_what_they_do_under_whpx(wiz, whpx_ready):
    page = _page(wiz)
    docker = (page.refresh_btn.toolTip(), page.mesh_save_arm.toolTip())
    _choose(page, qw.BACKEND_WHPX)
    assert page.refresh_btn.isEnabled()
    assert page.refresh_btn.toolTip() == page_mod._WHPX_REFRESH
    assert "core.emulation.status()" not in page.refresh_btn.toolTip()
    assert not page.mesh_save_arm.isEnabled()
    assert page.mesh_save_arm.toolTip() == page_mod._whpx_not_here("Saving the whole mesh")
    _choose(page, qw.BACKEND_DOCKER)
    assert (page.refresh_btn.toolTip(), page.mesh_save_arm.toolTip()) == docker


def test_the_poll_does_not_rebuild_the_login_combo_under_the_operator(wiz, whpx_ready,
                                                                      live):
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    row = _x86(page)[0]
    live.append(_rec(row))
    page._refresh_reality()
    assert row.user.isEditable()
    row.user.setEditText("ali")                     # half-typed
    cleared = []
    row.user.clear = lambda: cleared.append(True)   # what a rebuild would call
    page._refresh_reality()                         # the 4 s poll, while it runs
    page._refresh_reality()
    assert cleared == [] and row.user.currentText() == "ali"


# ---- the QEMU device tests page points here ------------------------------------------

def test_the_test_page_points_native_windows_at_this_backend(wiz, monkeypatch):
    page = next(wiz.page(pid) for pid in wiz.pageIds()
                if isinstance(wiz.page(pid), QemuPage))
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_NATIVE_BLOCKER, osname="nt"))
    page._docker_answered_paint((True, "docker is available."))
    text = page.docker_note.text()
    assert "WSL2" in text and "Mesh emulation" in text
    assert dict(qw.BACKENDS)[qw.BACKEND_WHPX] in text
    assert not page._docker_ok and not page.run_btn.isEnabled()   # gating unchanged


# ---- go live from this mesh under WHPX: the NATIVE record is the target ---------------

def test_go_live_under_whpx_needs_an_ssh_identity_in_the_native_record(
        wiz, whpx_ready, live, monkeypatch):
    from hugmesh_studio.gui.pages import golive as golive_page
    opened = []
    monkeypatch.setattr(golive_page, "open_go_live",
                        lambda gen, domain="", current=None, target=None, work_dir="":
                        opened.append(target) or object())
    page = _page(wiz)
    _choose(page, qw.BACKEND_WHPX)
    gw = next(r for r in page._rows if r.label == page.plan.gateway_label)
    live.append(_rec(gw))                             # today's record: no key, no user
    page._refresh_reality()
    assert not page.golive_btn.isEnabled()
    assert "QEMU for Windows" in page.golive_note.text()
    assert "no ssh key or user" in page.golive_note.text()
    # it does NOT repeat the bash / WSL2 blocker: this path needs only ssh
    assert "WSL" not in page.golive_note.text()
    live[:] = [_rec(gw, ssh_key=r"C:\keys\id_ed25519", ssh_user="hugmesh")]
    page._refresh_reality()
    assert page.golive_btn.isEnabled(), page.golive_note.text()
    page.golive_btn.click()
    (t,) = opened
    assert t.kind == "emulated-whpx" and t.label == gw.label and t.ssh_port == 2222
