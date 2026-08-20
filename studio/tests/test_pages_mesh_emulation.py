"""MeshEmulationPage — the DEPLOY face: a standing mesh, its console, its saves.

The operator ask (#50), condensed: reachable from the main menu, it FIRST asks which
prior session's images to use, then shows one row per device with status badges per
section, per-row actions (start/stop/ssh-as-a-chosen-user), an "open web UI" action
that surfaces the emulated mesh's front door, and — item 10 — a way to save the whole
emulated mesh back.

WHAT T3 ADDED, AND WHY EACH TEST IS HERE
-----------------------------------------
The device CONSOLE moved here from the test page in the same change that deleted it
there, so the tests moved with it: QMP pause/resume/status/power-off, the ``reset``
that is armed inline because under ``-no-reboot`` it ENDS the guest, the PAUSED
rendering that greys the shell, and per-device Save copy / Overwrite with the
arm-tick and the ON-DISK verification. Two of those tests were red on main by design
— the per-device Start they drove was the runner's newest-session guess, which
``core.qemu_devices`` now refuses to author — and they are green here against
``emulation.start_device_argv``'s ``--only-exact`` contract.

New with it:

* THE WHOLE-MESH SAVE, previewed before it runs — always. A save is 9.5-20.5 GB PER
  DEVICE, so the first press only shows what would be written and whether it fits,
  and the refusal path (with its remedies) is asserted head-on. Skipping to execution
  is the failure this cannot be allowed to have.
* THE POLL. A booting record must make its row appear NOW rather than after the many
  minutes an emulated boot takes, and the table must stop polling once nothing is
  moving.
* THE TUNNEL LIFECYCLE. This is the operator's "cannot reach the web console while
  emulating devices" path: the tunnel is tracked, its reuse is STATED, and it is torn
  down when the gateway stops, when the mesh stops and when the page is left.

WHAT IS REAL HERE
-----------------
* the session and its plan: real image names on disk, discovered by the real
  ``qemu_tests.discover_sessions`` and planned by the real ``core.emulation.plan``
  (which wraps ``mesh_emulation.plan_mesh``);
* the device registry: JSON written to ``<work>/devices/`` in the entrypoint's own
  format and read back through the real ``core.emulation.status()``, which is also
  what GRADES the verdicts;
* the assertion verdicts: JSON in ``<work>/results/``;
* the save rules: real ``qemu_devices.save_argv`` / ``emulation_save.plan_mesh_save``
  — the GUI re-derives no path and no naming rule of its own.

WHAT IS MOCKED, AND WHY THAT IS THE DESIGN
------------------------------------------
``emulation.spawn`` is the facade's ONE documented process boundary — every runner
invocation goes through it precisely so these tests can replace it and assert on the
argv it received, with no docker, no qemu and no images. ``emulation.status``'s two
shell-outs (the runner's ``--devices`` probe and ``docker ps``) are stubbed to "did
not answer" so the on-disk registry is the only source. Desktop-side launches
(terminals, the web tunnel, the browser) are captured: a real Popen here would open
windows on the developer's desktop mid-test.
"""
import dataclasses
import inspect
import json
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import emulation, emulation_save              # noqa: E402
from hugmesh_studio.core import mesh_emulation as me                   # noqa: E402
from hugmesh_studio.core import qemu_devices, qemu_tests               # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import _emulation_common as common       # noqa: E402
from hugmesh_studio.gui.pages import mesh_emulation as page_mod        # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402

from _helpers import advance_to, pick_mode                             # noqa: E402

# a canned host so wizard construction never probes the machine
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

GIB = 1024 ** 3


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


@pytest.fixture(autouse=True)
def _status_reads_only_the_registry(monkeypatch):
    """``emulation.status`` must not shell out from a unit test — see the twin
    fixture in test_pages_qemu.py for the reasoning."""
    monkeypatch.setattr(emulation, "_runner_devices", lambda *_a, **_k: None)
    monkeypatch.setattr(emulation, "_docker_running_names", lambda: None)


@pytest.fixture(autouse=True)
def _roomy_filesystem(monkeypatch):
    """A filesystem with room for the fleet, unless a test says otherwise.

    The per-device budget is each disk's FULL virtual size (16 GiB ARM / 32 GiB
    x86), so a 3-device mesh budgets 80 GiB — more than the free space on the
    machine this suite runs on. Left real, EVERY preview would refuse and the
    refusal test would pass for the wrong reason.
    """
    monkeypatch.setattr(emulation_save, "_disk_usage",
                        lambda _p: dataclasses.make_dataclass(
                            "Usage", ["total", "used", "free"])(
                                500 * GIB, 100 * GIB, 400 * GIB))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def fake_generator(tmp_path):
    """A generator tree with a COMPLETE 3-device mesh session and a newer PARTIAL one.

    The partial session is the shape that made nine of ten device Starts fail on
    2026-08-19: a build that died after one image, sitting at the top of a
    newest-first picker.
    """
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260810-101010-mesh"
    sess.mkdir(parents=True)
    for n in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
              "hugmesh-x86-amd64-be-test-20260807T172418Z.img",
              "hugmesh-x86-amd64-fe-test-20260807T172419Z.img"):
        (sess / n).write_bytes(b"")
    for i in range(3):
        (sess / f"build-image{i}.log").write_text("ok\n")

    abort = gen / "out" / "sessions" / "20260812-000000-abort"
    abort.mkdir(parents=True)
    (abort / "hugmesh-rpi5-arm64-pki-test-20260812T010101Z.img").write_bytes(b"")
    for i in range(4):
        (abort / f"build-image{i}.log").write_text("started\n")

    os.utime(sess, (1_700_000_000, 1_700_000_000))
    os.utime(abort, (1_800_000_000, 1_800_000_000))
    (gen / "tests" / "qemu").mkdir(parents=True)
    return gen, sess, abort


@pytest.fixture
def wiz(qapp, fake_generator):
    gen, _sess, _abort = fake_generator
    w = wizard_mod.StudioWizard(str(gen))
    w.show()
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def work_dir(fake_generator):
    gen, _sess, _abort = fake_generator
    return os.path.join(str(gen), qemu_tests.DEFAULT_WORK_SUBDIR)


@pytest.fixture
def registry(work_dir):
    """WRITE device records into the real registry dir — the page's own discovery
    (through emulation.status) reads them back."""
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

    def write(label, status="PASS", passed=12, failed=0,
              started_at="2999-01-01T00:00:00Z"):
        os.makedirs(resdir, exist_ok=True)
        name = qemu_tests.result_filename(label)
        with open(os.path.join(resdir, name), "w", encoding="utf-8") as fh:
            json.dump({"label": label, "status": status,
                       "assertions_passed": passed, "assertions_failed": failed,
                       "started_at": started_at}, fh)
    return write


class _Spawns(list):
    """Captured (argv, cwd) pairs, plus the lines the fake spawn should echo."""

    def __init__(self):
        super().__init__()
        self.lines: list[str] = []
        self.write_saves = True
        self.rc = 0

    @property
    def last(self):
        assert self, "nothing was spawned"
        return self[-1][0]


@pytest.fixture
def mocked_spawn(monkeypatch):
    """Replace THE process boundary; every runner invocation lands here.

    It honours ``--save-to`` the way the real runner does — creating the file it was
    told to write — because the page's save reporting deliberately checks the
    FILESYSTEM rather than the exit status, and a stub that wrote nothing would make
    that check fire on every save.
    """
    spawns = _Spawns()

    def fake_spawn(argv, cwd, on_line=None, cancel=None):
        argv = list(argv)
        spawns.append((argv, cwd))
        if on_line:
            on_line(f"MOCK-SPAWN {' '.join(argv)}")
            for line in spawns.lines:
                on_line(line)
        if "--save-to" in argv and spawns.write_saves:
            target = argv[argv.index("--save-to") + 1]
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as fh:
                fh.write(b"a stand-in for a qcow2 backup\n")
        return spawns.rc

    monkeypatch.setattr(emulation, "spawn", fake_spawn)
    return spawns


class _FakeProc:
    """A detached desktop launch (terminal / tunnel) that never really ran."""

    def __init__(self, argv, kw, pid=4242):
        self.argv, self.kw, self.pid = argv, kw, pid
        self.terminated = False

    def poll(self):
        return None if not self.terminated else -15

    def terminate(self):
        self.terminated = True


@pytest.fixture
def spawned(monkeypatch):
    calls: list[_FakeProc] = []

    def fake_popen(argv, **kw):
        proc = _FakeProc(list(argv), kw, pid=4242 + len(calls))
        calls.append(proc)
        return proc

    monkeypatch.setattr(page_mod.subprocess, "Popen", fake_popen)
    return calls


@pytest.fixture
def terminal(monkeypatch):
    monkeypatch.setattr(qemu_devices, "terminal_argv",
                        lambda argv: ["xterm", "-e", *argv])


_DEFAULT = object()


def _device(label, state="running", port=22355, key="/w/keys/id_ed25519",
            users=("tester", "alice"), container=_DEFAULT, qmp="/w/q.sock",
            started_at="2999-01-01T00:00:00Z"):
    platform, _, role = label.partition("/")
    # A sentinel, not "" or None: container="" is a REAL registry shape (a record
    # written before the container was named) and the save tests below depend on
    # being able to spell it.
    if container is _DEFAULT:
        container = "hugmesh-qemu-" + label.replace("/", "-")
    return qemu_devices.Device(
        label=label, platform=platform, role=role, board="",
        container=container,
        ssh_host_port=port, ssh_user="tester", ssh_key=key, users=list(users),
        qmp=qmp, state=state, started_at=started_at)


def _page(wiz):
    pick_mode(wiz, "meshemu")
    return advance_to(wiz, wizard_mod.MeshEmulationPage)


def _row(page, label):
    for row in page._rows:
        if row.label == label:
            return row
    raise AssertionError(f"no row for {label!r}; got "
                         f"{[r.label for r in page._rows]}")


def _index(page, label):
    return [r.label for r in page._rows].index(label)


def _cell(page, label, col):
    return page.devices.item(_index(page, label), col)


def _finish(page, qapp, ms=15000):
    assert page.worker is not None, "no verb was started"
    assert page.worker.wait(ms), "the verb never finished"
    qapp.processEvents()


def _saves_dir(work_dir):
    return os.path.join(work_dir, qemu_devices.SAVES_SUBDIR)


# ---- reachable from the main menu; asks for the session first ----------------------

def test_reachable_from_main_menu_and_asks_for_a_session(wiz, fake_generator):
    _gen, sess, _abort = fake_generator
    page = _page(wiz)
    assert isinstance(page, wizard_mod.MeshEmulationPage)
    assert page.nextId() == -1                       # terminal side-flow
    assert page.session_combo.count() == 2
    # the plan names the front door and how it is reached
    assert "x86/fe" in page.plan_label.text()
    assert "https://127.0.0.1:" in page.plan_label.text()
    assert page.plan.session_path == str(sess)


def test_picker_defaults_to_the_newest_COMPLETE_session(wiz, fake_generator):
    """The aborted-session default trap, on the mesh face: emulating "the mesh" from
    a build that died after one image emulates a fraction of it, silently."""
    _gen, sess, abort = fake_generator
    page = _page(wiz)
    assert page.session_combo.currentData() == str(sess)
    assert page.session_combo.currentData() != str(abort)
    assert page.session_note.text() == ""
    idx = next(i for i in range(page.session_combo.count())
               if page.session_combo.itemData(i) == str(abort))
    page.session_combo.setCurrentIndex(idx)
    assert "PARTIAL — 1 of 4 image(s)" in page.session_note.text()
    assert page.devices.rowCount() == 1               # and the plan shrinks with it


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
    # and nothing is up yet
    assert _cell(page, "rpi5/pki", page_mod._MCOL_STATE).text() \
        == emulation.STATE_PLANNED


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
    assert _cell(page, "x86/be", page_mod._MCOL_STATE).text() \
        == emulation.STATE_RUNNING


def test_failed_provisioning_reads_failed(wiz, registry, results):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    results("rpi5/pki", status="FAIL", passed=3, failed=2)
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    texts = [row.sections.itemText(i) for i in range(row.sections.count())]
    assert "provision: failed" in texts


# ---- verdict integrity travels with the row ----------------------------------------

def test_a_suspect_verdict_is_never_green_here_either(wiz, registry, results):
    """A PASS with zero assertions is graded once, by core.emulation, so the two
    emulation screens cannot disagree about the same row."""
    registry(_device("x86/be"))
    results("x86/be", status="PASS", passed=0, failed=0)
    page = _page(wiz)
    cell = _cell(page, "x86/be", page_mod._MCOL_VERDICT)
    assert cell.text() == emulation.VERDICT_SUSPECT
    assert cell.foreground().color().name() != common.GREEN


def test_a_verdict_older_than_the_boot_is_stale(wiz, registry, results):
    """The plan's epoch is "" here (this page inspects meshes it did not start), so
    the gate is the DEVICE's own boot stamp — which is the right rule for a standing
    mesh, and catches last week's verdict for a device booted five minutes ago."""
    registry(_device("x86/be", started_at="2026-08-19T12:00:00Z"))
    results("x86/be", status="PASS", passed=12,
            started_at="2026-08-12T09:00:00Z")
    page = _page(wiz)
    assert _cell(page, "x86/be", page_mod._MCOL_VERDICT).text() \
        == emulation.VERDICT_STALE


# ---- mesh-wide actions ---------------------------------------------------------------

def test_start_mesh_goes_through_the_mocked_spawn(wiz, qapp, mocked_spawn,
                                                  fake_generator):
    gen, sess, _abort = fake_generator
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


def test_stop_all_goes_through_the_mocked_spawn(wiz, qapp, registry, mocked_spawn):
    page = _page(wiz)
    registry(_device("x86/fe"))
    page._refresh_reality()
    assert page.stop_btn.isEnabled()
    page.stop_btn.click()
    _finish(page, qapp)
    assert mocked_spawn.last[-1] == "--stop-all-devices"
    assert "--work" in mocked_spawn.last, \
        "a stop that lets the runner default aims at a registry the devices never " \
        "registered in"


# ---- the per-device START contract (#86/#87) -----------------------------------------

def test_row_start_uses_the_only_exact_contract(wiz, qapp, mocked_spawn,
                                                fake_generator):
    """The spelling this replaced let the runner guess its newest session and matched
    the label by SUBSTRING — so restarting ``x86/be`` could boot a different build
    than the row was planned from, and drag be+gpu/be-ha along with it."""
    _gen, sess, _abort = fake_generator
    page = _page(wiz)
    row = _row(page, "x86/be")
    assert row.start.isEnabled() and not row.stop.isEnabled()
    row.start.click()
    _finish(page, qapp)
    argv = mocked_spawn.last
    assert argv[argv.index("--only-exact") + 1] == "x86/be"
    assert "--only" not in argv, "the substring filter must not be emitted"
    assert argv[argv.index("--artifacts") + 1] == str(sess)
    assert "--work" in argv and "--keep-alive" in argv


def test_row_stop_addresses_the_row_and_carries_the_work_dir(wiz, qapp, registry,
                                                             mocked_spawn):
    page = _page(wiz)
    registry(_device("x86/be"))
    page._refresh_reality()
    row = _row(page, "x86/be")
    assert row.stop.isEnabled() and not row.start.isEnabled()
    row.stop.click()
    _finish(page, qapp)
    argv = mocked_spawn.last
    assert argv[-2:] == ["--stop-device", "x86/be"]
    assert "--work" in argv


# ---- the QMP console, ported --------------------------------------------------------

def test_qmp_buttons_are_built_from_the_exported_verb_tuple(wiz, registry):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert list(row.qmp) == list(qemu_devices.QMP_COMMANDS)
    assert all(b.isEnabled() for verb, b in row.qmp.items()
               if verb != "reset")


def test_reset_says_it_ends_the_guest_rather_than_restarting_it(wiz, registry):
    """Every launcher runs qemu with -no-reboot, and under that flag a QMP
    system_reset makes the emulator shut down and exit."""
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert "ends guest" in row.qmp["reset"].text()
    assert "-no-reboot" in row.qmp["reset"].toolTip()


def test_reset_is_armed_inline_before_it_can_fire(wiz, qapp, registry,
                                                  mocked_spawn):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert not row.qmp["reset"].isEnabled(), "reset must not be armed by default"

    # The guard in front of the ACTION, not the one in front of the pixels: called
    # directly, because a disabled button's click() never reaches the slot at all.
    page._device_qmp(_index(page, "rpi5/pki"), "reset")
    assert not mocked_spawn, "an unarmed reset became a command"
    assert "Reset is not armed" in page.note.text()
    assert "-no-reboot" in page.note.text()      # the loud inline warning
    assert "refused: reset" in page.log.toPlainText()

    row.arm_reset.setChecked(True)
    # arming is what PRINTS the warning — read before the button lights up
    assert "Reset is armed" in page.note.text()
    assert "host-qmp-system-reset" in page.note.text()
    assert row.qmp["reset"].isEnabled()
    row.qmp["reset"].click()
    _finish(page, qapp)
    assert mocked_spawn.last[-2:] == ["rpi5/pki", "reset"]


def test_powerdown_needs_no_arming_because_it_is_the_orderly_one(wiz, qapp,
                                                                 registry,
                                                                 mocked_spawn):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").qmp["powerdown"].click()
    _finish(page, qapp)
    assert mocked_spawn.last[-2:] == ["rpi5/pki", "powerdown"]


def test_pause_makes_the_row_say_paused_instead_of_running(wiz, qapp, registry,
                                                           mocked_spawn):
    """A paused guest keeps its registry record at "running" forever — pausing is a
    QMP verb the entrypoint never sees — so a State column that only read the record
    would call a frozen device healthy."""
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert row.can_shell and row.ssh_btn.isEnabled()

    row.qmp["pause"].click()
    _finish(page, qapp)
    row = _row(page, "rpi5/pki")
    assert row.paused
    assert _cell(page, "rpi5/pki", page_mod._MCOL_STATE).text() == "PAUSED"
    assert not row.ssh_btn.isEnabled(), "sshd cannot answer in a frozen guest"
    assert "Resume first" in row.ssh_btn.toolTip()
    assert not row.qmp["pause"].isEnabled()
    assert row.qmp["resume"].isEnabled(), \
        "Resume must never be greyed by a belief — this page's belief can be stale"

    row.qmp["resume"].click()
    _finish(page, qapp)
    row = _row(page, "rpi5/pki")
    assert not row.paused and row.ssh_btn.isEnabled()


def test_status_resyncs_a_device_paused_outside_the_studio(wiz, qapp, registry,
                                                           mocked_spawn):
    """The only way this table can tell the truth about a device someone paused from
    a terminal. The reply is read off the STREAM, verbatim, as the runner's QMP
    client prints QEMU's own query-status answer."""
    mocked_spawn.lines.append('{"return": {"status": "paused", "running": false}}')
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").qmp["status"].click()
    _finish(page, qapp)
    assert _row(page, "rpi5/pki").paused
    assert _cell(page, "rpi5/pki", page_mod._MCOL_STATE).text() == "PAUSED"


def test_an_unparsed_status_line_leaves_the_run_state_unknown(wiz, qapp, registry,
                                                              mocked_spawn):
    """Nothing is INFERRED: rounding an unrecognized reply to "running" is how a
    wedged guest comes to read as a healthy one."""
    mocked_spawn.lines.append("some unrelated chatter from the runner")
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").qmp["status"].click()
    _finish(page, qapp)
    row = _row(page, "rpi5/pki")
    assert row.run_state == ""
    assert _cell(page, "rpi5/pki", page_mod._MCOL_STATE).text() \
        == emulation.STATE_RUNNING


def test_a_device_that_went_away_does_not_stay_paused(wiz, qapp, registry,
                                                      mocked_spawn, work_dir):
    """A run-state belongs to a GUEST, and a label outlives its guests: a device
    booted again must not inherit "paused" from the run before it."""
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").qmp["pause"].click()
    _finish(page, qapp)
    assert _row(page, "rpi5/pki").paused

    registry(_device("rpi5/pki", state="stopped"))
    page._refresh_reality()
    assert _row(page, "rpi5/pki").run_state == ""


# ---- per-device save, ported ---------------------------------------------------------

def test_save_column_holds_both_actions_and_their_arming(wiz, registry):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert row.save.isEnabled()
    assert not row.overwrite.isEnabled()          # nothing to overwrite yet
    assert not row.arm_save.isEnabled()
    assert "CRASH-CONSISTENT" in row.save.toolTip()
    assert "never written to" in row.save.toolTip()


def test_save_copy_writes_a_new_file_and_verifies_it_on_disk(wiz, qapp, registry,
                                                             mocked_spawn, work_dir):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").save.click()
    _finish(page, qapp)
    argv = mocked_spawn.last
    assert argv[argv.index("--save-device") + 1] == "rpi5/pki"
    assert "--overwrite" not in argv
    target = argv[argv.index("--save-to") + 1]
    assert target.startswith(_saves_dir(work_dir))
    assert target.endswith(".qcow2")
    assert os.path.exists(target)
    assert "Saved" in page.note.text() and "crash-consistent" in page.note.text()


def test_a_save_that_wrote_nothing_is_reported_as_not_saved(wiz, qapp, registry,
                                                            mocked_spawn):
    """"the runner exited 0" and "there is a save you can restore from" are different
    statements, and only the filesystem can answer the second."""
    mocked_spawn.write_saves = False
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").save.click()
    _finish(page, qapp)
    note = page.note.text()
    assert "no new file appeared" in note
    assert "Do not treat this device as saved" in note


def test_overwrite_must_be_armed_inline_before_it_can_fire(wiz, qapp, registry,
                                                           mocked_spawn):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    _row(page, "rpi5/pki").save.click()           # make a first save to overwrite
    _finish(page, qapp)

    row = _row(page, "rpi5/pki")
    assert row.saves, "the first save did not land"
    assert row.arm_save.isEnabled()
    assert not row.overwrite.isEnabled()          # armed per click, never a mode

    before = len(mocked_spawn)
    # Called directly: a disabled button's click() never reaches the slot, and the
    # guard that matters is the one in front of the ACTION.
    page._device_save(_index(page, "rpi5/pki"), "overwrite")
    assert len(mocked_spawn) == before, "an unarmed overwrite became a command"
    assert "Overwrite is not armed" in page.note.text()
    assert "not armed" in page.log.toPlainText()

    row.arm_save.setChecked(True)
    assert row.overwrite.isEnabled()
    row.overwrite.click()
    _finish(page, qapp)
    argv = mocked_spawn.last
    assert "--overwrite" in argv
    assert argv[argv.index("--save-to") + 1] == row.saves[0]
    assert "Overwrote" in page.note.text()
    # ...and the tick disarmed itself for the next click
    assert not _row(page, "rpi5/pki").arm_save.isChecked()


def test_save_is_disabled_for_a_device_that_is_not_running(wiz, registry):
    page = _page(wiz)
    registry(_device("rpi5/pki", state="stopped"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert not row.save.isEnabled() and not row.overwrite.isEnabled()
    assert "write LOCK" in row.save.toolTip()


@pytest.mark.parametrize("missing", ["qmp", "container"])
def test_save_is_disabled_when_the_record_cannot_support_one(wiz, registry, missing):
    """A record can say ``state: running`` with either field empty — a device
    started without --qmp, or one whose record predates the container name — and a
    row that only checked "running" enabled Save on it, which then died in the
    runner with "device has no qmp socket recorded"."""
    page = _page(wiz)
    registry(_device("rpi5/pki", **{missing: ""}))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert not row.can_save and not row.save.isEnabled()
    assert missing in row.save.toolTip()


# ---- the whole-mesh save (issue #50 item 10) ------------------------------------------

def test_save_mesh_previews_before_it_runs_anything(wiz, registry, mocked_spawn):
    """A mesh save is 9.5-20.5 GB PER DEVICE. The first press must show what would be
    written and what it costs; nothing may be paused or copied until an arm-tick."""
    page = _page(wiz)
    registry(_device("rpi5/pki"), _device("x86/be"), _device("x86/fe"))
    page._refresh_reality()
    assert not page.mesh_save_arm.isEnabled(), "armed with no preview"

    page.mesh_save_btn.click()
    assert not mocked_spawn, "the preview ran a command"
    note = page.mesh_save_note.text()
    assert "Mesh save preview" in note
    for label in ("rpi5/pki", "x86/be", "x86/fe"):
        assert label in note
    assert "16.0 GB" in note and "32.0 GB" in note      # per-device budgets
    assert "Fleet total 80.0 GB" in note                # 16 + 32 + 32
    assert "KEYS" in note
    assert page.mesh_save_arm.isEnabled()
    assert not page.mesh_save_arm.isChecked()


def test_save_mesh_runs_only_once_armed_and_streams_into_the_log(
        wiz, qapp, registry, mocked_spawn, work_dir):
    page = _page(wiz)
    registry(_device("rpi5/pki"), _device("x86/be"), _device("x86/fe"))
    page._refresh_reality()
    page.mesh_save_btn.click()                          # preview
    session = page._mesh_save_preview["session"]
    page.mesh_save_arm.setChecked(True)
    page.mesh_save_btn.click()                          # run
    _finish(page, qapp)

    saved = [argv for argv, _cwd in mocked_spawn if "--save-device" in argv]
    assert len(saved) == 3, "a mesh save saves the planned fleet"
    for argv in saved:
        target = argv[argv.index("--save-to") + 1]
        # The PREVIEWED save-set, not a freshly minted one: a run that stamps its own
        # name writes into a directory nobody previewed.
        assert os.path.dirname(target) == os.path.join(_saves_dir(work_dir), session)
        assert os.path.exists(target)
    assert "saved rpi5/pki ->" in page.log.toPlainText()
    assert "Mesh save complete" in page.note.text()
    # spent: the preview is gone and the tick is disarmed
    assert page._mesh_save_preview is None
    assert not page.mesh_save_arm.isChecked()


def test_save_mesh_refuses_when_the_filesystem_cannot_hold_it(
        wiz, registry, mocked_spawn, monkeypatch):
    """The refusal fires in the PREVIEW, before anything is paused. Running out
    mid-fleet leaves earlier saves landed, the current one a giant .partial, and — on
    this workstation — can take the live mesh's own volumes down with it."""
    monkeypatch.setattr(emulation_save, "_disk_usage",
                        lambda _p: dataclasses.make_dataclass(
                            "Usage", ["total", "used", "free"])(
                                100 * GIB, 98 * GIB, 2 * GIB))
    page = _page(wiz)
    registry(_device("rpi5/pki"), _device("x86/be"), _device("x86/fe"))
    page._refresh_reality()
    page.mesh_save_btn.click()
    note = page.mesh_save_note.text()
    assert "REFUSED — nothing will be saved." in note
    assert "short" in note
    # the remedies travel with the refusal, from the core that authored it
    assert "Free space" in note and "bigger filesystem" in note
    assert not page.mesh_save_arm.isEnabled(), "a refused preview must not be armable"
    assert not mocked_spawn


def test_save_mesh_preview_names_a_device_it_cannot_save(wiz, registry,
                                                         mocked_spawn):
    page = _page(wiz)
    registry(_device("rpi5/pki"), _device("x86/be", state="stopped"),
             _device("x86/fe"))
    page._refresh_reality()
    page.mesh_save_btn.click()
    note = page.mesh_save_note.text()
    assert "will NOT be saved" in note and "x86/be" in note
    assert "Fleet total 48.0 GB" in note        # the blocked device is not budgeted


# ---- the poll -------------------------------------------------------------------------

def test_a_booting_record_makes_its_row_appear_at_once_and_starts_the_poll(
        wiz, registry):
    """A row used to be empty for the many minutes an emulated boot takes, because
    nothing was registered until the guest answered ssh. #86's BOOTING record is
    written at the moment of qemu launch, and the poll is what shows it."""
    registry(_device("rpi5/pki", state="booting"))
    page = _page(wiz)
    assert _cell(page, "rpi5/pki", page_mod._MCOL_STATE).text() \
        == emulation.STATE_BOOTING
    assert not _row(page, "rpi5/pki").settled
    assert page.poll.isActive(), "a booting mesh must repaint itself"


def test_the_poll_repaints_the_row_and_then_stops(wiz, registry, results):
    registry(_device("rpi5/pki", state="booting"))
    page = _page(wiz)
    assert page.poll.isActive()

    registry(_device("rpi5/pki", state="running"))
    results("rpi5/pki", status="PASS", passed=12)
    page._poll_tick()                       # what the timer does, without the clock
    assert _cell(page, "rpi5/pki", page_mod._MCOL_STATE).text() \
        == emulation.STATE_RUNNING
    assert _cell(page, "rpi5/pki", page_mod._MCOL_VERDICT).text() == "PASS"
    assert not page.poll.isActive(), "an idle mesh must not poll forever"


def test_an_idle_plan_does_not_poll(wiz):
    page = _page(wiz)
    assert not page.poll.isActive()


def test_leaving_the_page_stops_the_poll(wiz, registry):
    registry(_device("rpi5/pki", state="booting"))
    page = _page(wiz)
    assert page.poll.isActive()
    page.cleanupPage()
    assert not page.poll.isActive()


def test_hiding_the_page_stops_the_poll_and_showing_it_resumes(wiz, qapp, registry):
    """A timer that outlives its page is a slot firing into a half-destroyed widget
    tree — and polling behind a screen nobody is looking at is a ``docker ps``
    treadmill."""
    registry(_device("rpi5/pki", state="booting"))
    page = _page(wiz)
    assert page.poll.isActive()
    page.hide()
    qapp.processEvents()
    assert not page.poll.isActive()
    page.show()
    qapp.processEvents()
    assert page.poll.isActive()


# ---- ssh as each user of each device ---------------------------------------------------

def test_ssh_button_opens_a_terminal_as_the_selected_user(wiz, registry, terminal,
                                                          spawned):
    page = _page(wiz)
    registry(_device("rpi5/pki", port=22355))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert row.ssh_btn.isEnabled()
    idx = next(i for i in range(row.user.count())
               if row.user.itemData(i) == "alice")
    row.user.setCurrentIndex(idx)
    row.ssh_btn.click()
    assert len(spawned) == 1
    proc = spawned[0]
    assert proc.argv[:2] == ["xterm", "-e"]
    assert "alice@127.0.0.1" in proc.argv
    assert proc.argv[proc.argv.index("-p") + 1] == "22355"
    assert proc.kw.get("start_new_session") is True


def test_the_login_choice_survives_a_repaint(wiz, registry, terminal, spawned):
    """The table repaints on a TIMER now; resetting the dropdown under the operator's
    cursor every few seconds would make the SSH button unusable on a booting mesh."""
    page = _page(wiz)
    registry(_device("rpi5/pki", port=22355))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    row.user.setCurrentIndex(next(i for i in range(row.user.count())
                                  if row.user.itemData(i) == "alice"))
    page._refresh_reality()
    assert _row(page, "rpi5/pki").user.currentData() == "alice"


def test_root_is_offered_last_and_never_preselected(wiz, registry):
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")
    assert row.user.itemData(row.user.count() - 1) == page_mod._ROOT_ROW
    assert row.user.currentIndex() == 0


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


# ---- the web front door and its tunnel --------------------------------------------------

def test_web_ui_waits_for_the_gateway_then_tunnels_and_opens(
        wiz, registry, spawned, monkeypatch):
    opened = []
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: opened.append(url.toString())))
    page = _page(wiz)
    assert not page.web_btn.isEnabled()            # gateway not up yet
    assert "not up yet" in page.web_note.text()
    assert "No web tunnel is open" in page.tunnel_note.text()

    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    assert page.web_btn.isEnabled()
    gw_port = page.plan.mesh.gateway.ui_port
    assert f"https://127.0.0.1:{gw_port}/" in page.web_note.text()

    page.web_btn.click()
    proc = spawned[0]
    assert proc.argv[0] == "ssh" and "-N" in proc.argv
    assert proc.argv[proc.argv.index("-p") + 1] == "22357"
    assert proc.argv[proc.argv.index("-L") + 1] == f"{gw_port}:127.0.0.1:443"
    assert proc.kw.get("start_new_session") is True
    assert opened == [f"https://127.0.0.1:{gw_port}/"]
    assert "Started a web tunnel" in page.note.text()
    # ...and the tunnel's state is ON the page, not something to go and find out
    assert "Web tunnel open for" in page.tunnel_note.text()
    assert str(proc.pid) in page.tunnel_note.text()
    assert page.tunnel_close_btn.isEnabled()


def test_a_second_press_reuses_the_tunnel_and_says_so(wiz, registry, spawned,
                                                      monkeypatch):
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    page.web_btn.click()
    assert len(spawned) == 1, "a second tunnel was started over the first"
    assert "Reusing the tunnel already open" in page.note.text()
    assert "reusing the web tunnel" in page.log.toPlainText()


def test_stopping_the_gateway_takes_its_tunnel_down(wiz, qapp, registry, spawned,
                                                    mocked_spawn, monkeypatch):
    """A tunnel whose far end is gone is worse than no tunnel: the local port still
    binds and still accepts, so the browser hangs on a connection nothing answers."""
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    assert not spawned[0].terminated

    _row(page, "x86/fe").stop.click()
    _finish(page, qapp)
    assert spawned[0].terminated, "the gateway's tunnel outlived the gateway"
    assert "closed the x86/fe web tunnel" in page.log.toPlainText()
    assert "No web tunnel is open" in page.tunnel_note.text()


def test_stop_all_takes_every_tunnel_down(wiz, qapp, registry, spawned,
                                          mocked_spawn, monkeypatch):
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    page.stop_btn.click()
    _finish(page, qapp)
    assert spawned[0].terminated
    assert not page._tunnels


def test_leaving_the_page_takes_the_tunnels_down(wiz, registry, spawned,
                                                 monkeypatch):
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    page.cleanupPage()
    assert spawned[0].terminated
    assert not page._tunnels
    assert "left the mesh emulation page" in page.log.toPlainText()


def test_closing_the_studio_takes_the_tunnels_down(wiz, registry, spawned,
                                                   monkeypatch):
    """Qt calls cleanupPage() on Back, never on Finish or a window close — so the
    third way out of this page needs its own hook, or a tunnel survives the Studio
    and the next session finds its loopback port taken."""
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/fe", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    assert not spawned[0].terminated
    wiz.finished.emit(0)
    assert spawned[0].terminated
    assert not page._tunnels


def test_web_ui_stays_greyed_while_only_a_non_gateway_is_up(wiz, registry):
    page = _page(wiz)
    registry(_device("rpi5/pki"))                  # up, but not the front door
    page._refresh_reality()
    assert not page.web_btn.isEnabled()


# ---- page discipline --------------------------------------------------------------------

def test_page_is_incomplete_while_a_verb_runs(wiz, qapp, mocked_spawn):
    page = _page(wiz)
    assert page.isComplete()
    page.start_btn.click()
    _finish(page, qapp)
    assert page.isComplete()                       # complete again once done


def test_every_runner_invocation_goes_through_the_facade_spawn():
    """The page starts exactly two kinds of process: runner invocations through
    ``emulation.spawn``, and DETACHED desktop launches (a terminal, an ssh tunnel)
    that own their own tty and are tracked by handle. A third lane would be invisible
    to every mock in this file."""
    src = inspect.getsource(page_mod)
    assert "emulation.spawn(" in src
    assert "QemuTestRunner" not in src
    for own_argv in ("subprocess.run(", "subprocess.call(", "stdout=subprocess.PIPE"):
        assert own_argv not in src, f"{own_argv} is a second, unmockable spawn lane"


def test_page_offers_no_modal_dialogs_at_all():
    src = inspect.getsource(page_mod)
    for forbidden in ("QMessageBox", ".exec()", "QDialog"):
        assert forbidden not in src, f"{forbidden} in page logic"


def test_no_gui_page_still_calls_the_removed_start_shim():
    """``qemu_devices.device_control_argv`` RAISES for 'start' (T2). Its last caller
    was the old console on the test page, and this change is what removes it — a
    merged commit must not leave a Qt slot that raises."""
    from hugmesh_studio.gui.pages import qemu as qemu_page_mod
    for mod in (page_mod, qemu_page_mod):
        assert "device_control_argv" not in inspect.getsource(mod)


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
