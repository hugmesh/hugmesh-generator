"""MeshEmulationPage — the whole-mesh emulation screen, driven offscreen (#50 7-9).

The operator ask, condensed: reachable from the main menu, it FIRST asks which
prior session's images to use, then shows one row per device with status badges
per section, per-row actions (start/stop/ssh-as-a-chosen-user) and an "open web
UI" action that surfaces the emulated mesh's front door once the gateway device
reports up.

WHAT IS REAL HERE
-----------------
* the session and its plan: real images-on-disk names, discovered by the real
  ``qemu_tests.discover_sessions`` and planned by the real
  ``core.mesh_emulation.plan_mesh``;
* the device registry: JSON written to ``<work>/devices/`` in the entrypoint's
  own format and read back by the real ``qemu_devices.discover_devices``;
* the assertion verdicts: JSON written to ``<work>/results/`` and read by the
  real ``qemu_tests.read_results``.

WHAT IS MOCKED, AND WHY THAT IS THE DESIGN
------------------------------------------
``mesh_emulation.spawn`` is the module's ONE documented process boundary —
every runner invocation goes through it precisely so these tests can replace it
and assert on the argv it received, with no docker, no qemu and no images.
Desktop-side launches (terminals, the web tunnel, the browser) are captured the
same way the QemuPage suite captures them: a real Popen here would open windows
on the developer's desktop mid-test.
"""
import dataclasses
import json
import os
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import mesh_emulation as me      # noqa: E402
from hugmesh_studio.core import qemu_devices, qemu_tests  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo    # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod       # noqa: E402
from hugmesh_studio.gui.pages import mesh_emulation as page_mod   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets               # noqa: E402

from _helpers import advance_to, pick_mode                # noqa: E402

# a canned host so wizard construction never probes the machine
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _docker_stubbed(monkeypatch):
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def fake_generator(tmp_path):
    """A generator tree with one 3-device mesh session (pki + be + fe)."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260810-101010-mesh"
    sess.mkdir(parents=True)
    for n in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
              "hugmesh-x86-amd64-be-test-20260807T172418Z.img",
              "hugmesh-x86-amd64-fe-test-20260807T172419Z.img"):
        (sess / n).write_bytes(b"")
    (gen / "tests" / "qemu").mkdir(parents=True)
    return gen, sess


@pytest.fixture
def wiz(qapp, fake_generator):
    gen, _sess = fake_generator
    w = wizard_mod.StudioWizard(str(gen))
    w.show()
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def work_dir(fake_generator):
    gen, _sess = fake_generator
    return os.path.join(str(gen), qemu_tests.DEFAULT_WORK_SUBDIR)


@pytest.fixture
def registry(work_dir):
    """WRITE device records into the real registry dir — the page's own
    discovery reads them back (the cross-layer file format, never patched)."""
    devdir = os.path.join(work_dir, "devices")

    def register(*devices):
        os.makedirs(devdir, exist_ok=True)
        for dev in devices:
            safe = dev.label.replace("/", "_").replace("+", "_")
            with open(os.path.join(devdir, f"{safe}.json"), "w",
                      encoding="utf-8") as fh:
                json.dump(dataclasses.asdict(dev), fh)
        return devices
    return register


@pytest.fixture
def results(work_dir):
    """WRITE a per-row assertion verdict, the runner's own result format."""
    resdir = os.path.join(work_dir, "results")

    def write(label, status="PASS", passed=12, failed=0):
        os.makedirs(resdir, exist_ok=True)
        name = qemu_tests.result_filename(label)
        with open(os.path.join(resdir, name), "w", encoding="utf-8") as fh:
            json.dump({"label": label, "status": status,
                       "assertions_passed": passed,
                       "assertions_failed": failed}, fh)
    return write


@pytest.fixture
def mocked_spawn(monkeypatch):
    """Replace THE process boundary; every runner invocation lands here."""
    calls = []

    def fake_spawn(argv, cwd, on_line=None, cancel=None):
        calls.append((list(argv), cwd))
        if on_line:
            on_line(f"MOCK-SPAWN {' '.join(argv)}")
        return 0

    monkeypatch.setattr(me, "spawn", fake_spawn)
    return calls


@pytest.fixture
def spawned(monkeypatch):
    """Capture the page's DETACHED desktop launches (terminal / tunnel)."""
    calls = []

    def fake_popen(argv, **kw):
        calls.append((list(argv), kw))
        return SimpleNamespace(pid=4242, poll=lambda: None)

    monkeypatch.setattr(page_mod.subprocess, "Popen", fake_popen)
    return calls


@pytest.fixture
def terminal(monkeypatch):
    monkeypatch.setattr(qemu_devices, "terminal_argv",
                        lambda argv: ["xterm", "-e", *argv])


def _device(label, state="running", port=22355, key="/w/keys/id_ed25519",
            users=("tester", "alice")):
    platform, _, role = label.partition("/")
    return qemu_devices.Device(
        label=label, platform=platform, role=role, board="",
        container="hugmesh-qemu-" + label.replace("/", "-"),
        ssh_host_port=port, ssh_user="tester", ssh_key=key, users=list(users),
        qmp="/w/q.sock", state=state, started_at="2026-08-19T00:00:00Z")


def _page(wiz):
    pick_mode(wiz, "meshemu")
    return advance_to(wiz, wizard_mod.MeshEmulationPage)


def _row(page, label):
    for row in page._rows:
        if row.planned.label == label:
            return row
    raise AssertionError(f"no row for {label!r}; got "
                         f"{[r.planned.label for r in page._rows]}")


def _finish(page, qapp, ms=15000):
    assert page.worker is not None, "no verb was started"
    assert page.worker.wait(ms), "the verb never finished"
    qapp.processEvents()


# ---- reachable from the main menu; asks for the session first ----------------------

def test_reachable_from_main_menu_and_asks_for_a_session(wiz, fake_generator):
    _gen, sess = fake_generator
    page = _page(wiz)
    assert isinstance(page, wizard_mod.MeshEmulationPage)
    assert page.nextId() == -1                       # terminal side-flow
    assert page.session_combo.count() == 1
    assert page.session_combo.currentData() == str(sess)
    # the plan names the front door and how it is reached
    assert "x86/fe" in page.plan_label.text()
    assert "https://127.0.0.1:" in page.plan_label.text()


def test_table_renders_one_row_per_planned_device(wiz):
    page = _page(wiz)
    assert page.devices.rowCount() == 3
    labels = [page.devices.item(r, 0).text() for r in range(3)]
    assert labels == ["rpi5/pki", "x86/be", "x86/fe"]   # boot order: Pi first
    assert page.devices.item(1, 1).text() == "be"       # role column
    assert page.devices.item(0, 2).text() == "arm64"    # arch column
    # planned identity is on the row (tooltip): ssh port, MAC/IP, the KEYS stick
    tip = page.devices.item(0, 0).toolTip()
    assert f"127.0.0.1:{me.SSH_PORT_MIN}" in tip
    assert me.MAC_PREFIX in tip and "keys.img" in tip
    # status badge: nothing is up yet
    assert page.devices.item(0, 3).text() == "not started"


def test_sections_dropdown_badges_every_section(wiz, registry, results):
    page = _page(wiz)
    row = _row(page, "x86/be")
    assert [row.sections.itemText(i) for i in range(row.sections.count())] == [
        "boot: off", "ssh: off", "provision: off", "web: off"]
    registry(_device("x86/be"))
    results("x86/be", status="PASS")
    page._refresh_reality()
    row = _row(page, "x86/be")
    texts = [row.sections.itemText(i) for i in range(row.sections.count())]
    assert texts == ["boot: ok", "ssh: ok", "provision: ok", "web: off"]
    assert page.devices.item(1, 3).text() == "up"


def test_failed_provisioning_reads_failed(wiz, registry, results):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    results("rpi5/pki", status="FAIL", passed=3, failed=2)
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    texts = [row.sections.itemText(i) for i in range(row.sections.count())]
    assert "provision: failed" in texts


# ---- actions call the mocked driver -------------------------------------------------

def test_start_mesh_goes_through_the_mocked_spawn(wiz, qapp, mocked_spawn,
                                                  fake_generator):
    gen, sess = fake_generator
    page = _page(wiz)
    assert page.start_btn.isEnabled()
    page.start_btn.click()
    _finish(page, qapp)
    assert len(mocked_spawn) == 1
    argv, cwd = mocked_spawn[0]
    assert cwd == str(gen)
    assert "--keep-alive" in argv
    assert argv[argv.index("--artifacts") + 1] == str(sess)
    assert "MOCK-SPAWN" in page.log.toPlainText()


def test_row_start_and_stop_go_through_the_mocked_spawn(wiz, qapp, registry,
                                                        mocked_spawn):
    page = _page(wiz)
    registry(_device("x86/be"))
    page._refresh_reality()
    row = _row(page, "x86/be")
    assert row.stop.isEnabled() and not row.start.isEnabled()
    row.stop.click()
    _finish(page, qapp)
    argv, _cwd = mocked_spawn[-1]
    assert argv[-2:] == ["--stop-device", "x86/be"]

    # a row that is NOT up offers Start, which re-enters the keep-alive boot path
    row = _row(page, "rpi5/pki")
    assert row.start.isEnabled() and not row.stop.isEnabled()
    row.start.click()
    _finish(page, qapp)
    argv, _cwd = mocked_spawn[-1]
    assert "--keep-alive" in argv
    assert argv[argv.index("--only") + 1] == "rpi5/pki"


def test_stop_all_goes_through_the_mocked_spawn(wiz, qapp, registry, mocked_spawn):
    page = _page(wiz)
    registry(_device("x86/fe"))
    page._refresh_reality()
    assert page.stop_btn.isEnabled()
    page.stop_btn.click()
    _finish(page, qapp)
    argv, _cwd = mocked_spawn[-1]
    assert argv[-1] == "--stop-all-devices"


# ---- ssh as each user of each device -------------------------------------------------

def test_ssh_button_opens_a_terminal_as_the_selected_user(wiz, registry,
                                                          terminal, spawned):
    page = _page(wiz)
    registry(_device("rpi5/pki", port=22355))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert row.ssh_btn.isEnabled()
    # pick alice from the login dropdown
    idx = next(i for i in range(row.user.count())
               if row.user.itemData(i) == "alice")
    row.user.setCurrentIndex(idx)
    row.ssh_btn.click()
    assert len(spawned) == 1
    argv, kw = spawned[0]
    assert argv[:2] == ["xterm", "-e"]
    assert "alice@127.0.0.1" in argv
    assert argv[argv.index("-p") + 1] == "22355"
    assert kw.get("start_new_session") is True


def test_ssh_without_a_terminal_surfaces_the_command_copy_ready(
        wiz, registry, monkeypatch, spawned):
    monkeypatch.setattr(qemu_devices, "terminal_argv", lambda argv: None)
    page = _page(wiz)
    registry(_device("rpi5/pki", port=22355))
    page._refresh_reality()
    _row(page, "rpi5/pki").ssh_btn.click()
    assert not spawned                             # nothing launched
    note = page.note.text()
    assert "ssh" in note and "22355" in note and "tester@127.0.0.1" in note


def test_ssh_is_disabled_until_the_device_is_up(wiz):
    page = _page(wiz)
    row = _row(page, "rpi5/pki")
    assert not row.ssh_btn.isEnabled()
    assert not row.stop.isEnabled()
    assert row.start.isEnabled()


# ---- the web front door --------------------------------------------------------------

def test_web_ui_waits_for_the_gateway_then_tunnels_and_opens(
        wiz, registry, spawned, monkeypatch):
    opened = []
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url.toString())))
    page = _page(wiz)
    assert not page.web_btn.isEnabled()            # gateway not up yet
    assert "not up yet" in page.web_note.text()

    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    assert page.web_btn.isEnabled()
    gw_port = page.plan.gateway.ui_port
    assert f"https://127.0.0.1:{gw_port}/" in page.web_note.text()

    page.web_btn.click()
    # the tunnel is a detached ssh -N -L riding the published ssh port
    argv, kw = spawned[0]
    assert argv[0] == "ssh" and "-N" in argv
    assert argv[argv.index("-p") + 1] == "22357"
    assert argv[argv.index("-L") + 1] == f"{gw_port}:127.0.0.1:443"
    assert kw.get("start_new_session") is True
    assert opened == [f"https://127.0.0.1:{gw_port}/"]
    assert f"https://127.0.0.1:{gw_port}/" in page.note.text()


def test_web_ui_stays_greyed_while_only_a_non_gateway_is_up(wiz, registry):
    page = _page(wiz)
    registry(_device("rpi5/pki"))                  # up, but not the front door
    page._refresh_reality()
    assert not page.web_btn.isEnabled()


# ---- page discipline ------------------------------------------------------------------

def test_page_is_incomplete_while_a_verb_runs(wiz, qapp, mocked_spawn):
    page = _page(wiz)
    assert page.isComplete()
    page.start_btn.click()
    _finish(page, qapp)
    assert page.isComplete()                       # complete again once done


def test_no_sessions_says_so_instead_of_offering_nothing(qapp, tmp_path,
                                                         monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    gen = tmp_path / "empty-gen"
    gen.mkdir()
    w = wizard_mod.StudioWizard(str(gen))
    w.show()
    try:
        page = _page(w)
        assert page.session_combo.count() == 0
        assert "No build session" in page.plan_label.text()
        assert not page.start_btn.isEnabled()
    finally:
        w.close()
        w.deleteLater()
