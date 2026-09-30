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

TWO GUARDS THAT DID NOT MOVE WITH IT
------------------------------------
The port kept both of the save reporting's ON-DISK verifications but not the tests
that pinned them, so from PR #90 until now the code was right and nothing said so.
Commit 3c241381 had added them to test_pages_qemu.py for exactly the reason they are
easy to lose: each was written against a surviving MUTANT, and each stayed green in
the whole file until the device under test already HAD a save. They are restored
below as test_save_copy_does_not_report_an_OLD_save_as_the_new_one and
test_overwrite_reports_a_target_that_is_no_longer_there, with that commit's
``existing_save`` fixture and its ``STUB_SAVE_REMOVE`` arm (now ``mocked_spawn``'s
``move_save_aside``, since the shell stub runner did not come to this page).

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
import threading
import time

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import emulation, emulation_save              # noqa: E402
from hugmesh_studio.core import mesh_emulation as me                   # noqa: E402
from hugmesh_studio.core import mesh_monitor as mm                     # noqa: E402
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
        (sess / n).write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row
    for i in range(3):
        (sess / f"build-image{i}.log").write_text("ok\n")

    abort = gen / "out" / "sessions" / "20260812-000000-abort"
    abort.mkdir(parents=True)
    (abort / "hugmesh-rpi5-arm64-pki-test-20260812T010101Z.img").write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row
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


@pytest.fixture
def existing_save(work_dir):
    """Put a stand-in EARLIER save on disk for a device and hand back its path.

    A device that ALREADY has a save is the state both on-disk verifications below
    need and that no other test here reaches: the page's own Save button can only
    produce one by running, and a save produced by the run under test cannot stand in
    for one that predates it.

    The path comes from ``qemu_devices.new_save_target`` rather than being spelled
    here, because the page arms Overwrite from ``qemu_devices.saved_copies`` and names
    the file it is about to destroy from the same call — a fake save has to land
    somewhere that function will actually find it, and a second, private copy of the
    naming rule in this file would drift out from under these tests silently.

    No sidecar is written: this is deliberately the pre-sidecar shape, which
    ``saved_copies`` still claims by name, so the fixture depends on the smaller of
    the two ownership rules.
    """
    def make(dev, stamp="20260814T210000Z", data=b"an earlier save"):
        path = qemu_devices.new_save_target(work_dir, dev, stamp=stamp)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path
    return make


class _Spawns(list):
    """Captured (argv, cwd) pairs, plus the lines the fake spawn should echo."""

    def __init__(self):
        super().__init__()
        self.lines: list[str] = []
        self.write_saves = True
        #: Successor to the old shell stub's ``STUB_SAVE_REMOVE`` arm: exit 0 having
        #: MOVED the target aside, which is what the real runner does to a save that
        #: died after creating its file. See ``mocked_spawn``.
        self.move_save_aside = False
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

    Two arms turn that honesty off, and each one reproduces a REAL runner outcome
    that still exits 0:

    * ``write_saves = False`` — a save that wrote nothing at all;
    * ``move_save_aside = True`` — a save that died AFTER creating its target, which
      the runner then renames to ``<name>.partial``. The path the operator was just
      told about is therefore missing afterwards, and only the filesystem can say so.
      This is the shell stub's old ``STUB_SAVE_REMOVE`` (commit 3c241381), carried
      over to this fixture when the save UI moved pages.
    """
    spawns = _Spawns()

    def fake_spawn(argv, cwd, on_line=None, cancel=None):
        argv = list(argv)
        spawns.append((argv, cwd))
        if on_line:
            on_line(f"MOCK-SPAWN {' '.join(argv)}")
            for line in spawns.lines:
                on_line(line)
        if "--save-to" in argv:
            target = argv[argv.index("--save-to") + 1]
            if spawns.move_save_aside:
                if os.path.exists(target):
                    os.replace(target, target + ".partial")
            elif spawns.write_saves:
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
    assert "x86/frontend" in page.plan_label.text()
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


# ── the branded (non-default --brand) session ────────────────────────────────────
# out/sessions/20260830-185641-8e88a6 on the operator's workstation: a FINISHED
# three-image Pi mesh that this page showed as nothing at all — an empty dropdown
# under "No build session under out/sessions/ holds a bootable image yet". The one
# thing separating it from every fixture above is its BRAND: built `--brand sdhm`,
# so the artifacts are named sdhm-… and the parser (which required the DEFAULT
# brand's `hugmesh-` prefix) resolved zero rows, zero images, no session.
#
# Driven through the real page rather than the core alone because the core failure
# was invisible from here in exactly the way that mattered: the page did not error,
# it rendered a tidy, plausible "you have not built anything yet".

_SDHM_PI_IMAGES = (
    "sdhm-rpi5-arm64-pki-test-20260831T015954Z.img.xz",
    "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img.xz",
    "sdhm-rpi5-arm64-frontend-test-20260831T033915Z.img.xz",
)


@pytest.fixture
def branded_generator(tmp_path):
    """A generator tree holding ONLY the operator's sdhm Pi session.

    Only that session, on purpose: with a hugmesh-named session beside it the page
    would still have something to show, and "the dropdown is empty" — the reported
    symptom — could not be asserted.
    """
    gen = tmp_path / "branded-gen"
    sess = gen / "out" / "sessions" / "20260830-185641-8e88a6"
    sess.mkdir(parents=True)
    for name in _SDHM_PI_IMAGES:
        (sess / name).write_bytes(b"\0")
        stem = name[: -len(".img.xz")]
        # the non-bootable siblings that sit beside every image on disk
        for ext in (".iso", ".stage4.tar.xz", ".fs.tar.xz"):
            (sess / (stem + ext)).write_bytes(b"\0")
    for log in ("build-pki.rpi5.log", "build-be.rpi5.log", "build-fe.rpi5.log"):
        (sess / log).write_text("=== Post-install ===\n")
    (sess / qemu_tests.MESH_MANIFEST_NAME).write_text(json.dumps({
        "format": 2, "brand": "sdhm", "brand_title": "Snapdragon Hugmesh",
        "org": "sdhm", "cluster_domain": "snapdragon.systems",
        "superdomain": "snapdragon.local", "domains": [], "users": [],
        "images": [{"id": "pki.rpi5", "role": "pki", "platform": "rpi5",
                    "board": "rpi5", "flavor": "", "encrypt_root": True},
                   # ids keep their real on-disk spelling; the `role` values are
                   # canonical because test-role-key-spelling.sh bans emitting an
                   # alias as a `"role":` JSON value (and nothing reads it here)
                   {"id": "be.rpi5", "role": "backend", "platform": "rpi5",
                    "board": "rpi5", "flavor": "", "encrypt_root": True},
                   {"id": "fe.rpi5", "role": "frontend", "platform": "rpi5",
                    "board": "rpi5", "flavor": "", "encrypt_root": True}]}))
    (gen / "tests" / "qemu").mkdir(parents=True)
    return gen, sess


@pytest.fixture
def branded_wiz(qapp, branded_generator):
    gen, _sess = branded_generator
    w = wizard_mod.StudioWizard(str(gen))
    w.show()
    yield w
    w.close()
    w.deleteLater()


def test_a_branded_session_is_offered_and_planned(branded_wiz, branded_generator):
    """THE REPORTED DEFECT: the finished 3-image Pi session must be IN the dropdown,
    selected, badged complete, and planned into three bootable rows."""
    _gen, sess = branded_generator
    page = _page(branded_wiz)

    # the picker is not empty, and the session is the one selected
    assert page.session_combo.count() == 1
    assert page.session_combo.currentIndex() == 0
    assert page.session_combo.currentData() == str(sess)
    # ...and it reads COMPLETE: no PARTIAL badge in the entry, no inline warning
    assert "PARTIAL" not in page.session_combo.itemText(0)
    assert page.session_note.text() == ""
    assert "no bootable image" not in page.plan_label.text().lower()

    # three devices, in boot order, each pinned to its own sdhm artifact
    assert page.devices.rowCount() == 3
    labels = [page.devices.item(r, 0).text() for r in range(3)]
    assert labels == ["rpi5/backend", "rpi5/frontend", "rpi5/pki"]
    assert page.plan.session_path == str(sess)
    assert sorted(os.path.basename(r.image) for r in page.plan.rows) == \
        sorted(_SDHM_PI_IMAGES)
    # the frontend is a gateway role, so the mesh has a front door to open
    assert page.plan.gateway_label == "rpi5/frontend"
    assert page.plan.front_door.startswith("https://127.0.0.1:")


def test_a_branded_session_is_launch_resolvable(branded_wiz, branded_generator):
    """Listing it is only half the ask — every row must also produce a start argv.

    Before the fix this raised ``'rpi5/pki' is not a row of this plan``: the plan
    had no rows to address. The argv is checked for the ``--only-exact`` pin and
    the session it was planned from, because a row that starts from the runner's
    own newest-session guess boots a different build than the operator chose.
    """
    _gen, sess = branded_generator
    page = _page(branded_wiz)

    for label in ("rpi5/pki", "rpi5/backend", "rpi5/frontend"):
        argv = emulation.start_device_argv(page.plan, label)
        assert argv[argv.index("--only-exact") + 1] == label
        assert argv[argv.index("--artifacts") + 1] == str(sess)


def test_table_renders_one_row_per_planned_device(wiz):
    page = _page(wiz)
    assert page.devices.rowCount() == 3
    labels = [page.devices.item(r, 0).text() for r in range(3)]
    assert labels == ["rpi5/pki", "x86/backend", "x86/frontend"]   # boot order: Pi first
    assert page.devices.item(1, 1).text() == "backend"       # role column
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
    row = _row(page, "x86/backend")
    assert [row.sections.itemText(i) for i in range(row.sections.count())] == [
        "boot: off", "ssh: off", "provision: off", "web: off"]
    registry(_device("x86/backend"))
    results("x86/backend", status="PASS")
    page._refresh_reality()
    row = _row(page, "x86/backend")
    texts = [row.sections.itemText(i) for i in range(row.sections.count())]
    assert texts == ["boot: ok", "ssh: ok", "provision: ok", "web: off"]
    assert _cell(page, "x86/backend", page_mod._MCOL_STATE).text() \
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
    registry(_device("x86/backend"))
    results("x86/backend", status="PASS", passed=0, failed=0)
    page = _page(wiz)
    cell = _cell(page, "x86/backend", page_mod._MCOL_VERDICT)
    assert cell.text() == emulation.VERDICT_SUSPECT
    assert cell.foreground().color().name() != common.GREEN


def test_a_verdict_older_than_the_boot_is_stale(wiz, registry, results):
    """The plan's epoch is "" here (this page inspects meshes it did not start), so
    the gate is the DEVICE's own boot stamp — which is the right rule for a standing
    mesh, and catches last week's verdict for a device booted five minutes ago."""
    registry(_device("x86/backend", started_at="2026-08-19T12:00:00Z"))
    results("x86/backend", status="PASS", passed=12,
            started_at="2026-08-12T09:00:00Z")
    page = _page(wiz)
    assert _cell(page, "x86/backend", page_mod._MCOL_VERDICT).text() \
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
    registry(_device("x86/frontend"))
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
    row = _row(page, "x86/backend")
    assert row.start.isEnabled() and not row.stop.isEnabled()
    row.start.click()
    _finish(page, qapp)
    argv = mocked_spawn.last
    assert argv[argv.index("--only-exact") + 1] == "x86/backend"
    assert "--only" not in argv, "the substring filter must not be emitted"
    assert argv[argv.index("--artifacts") + 1] == str(sess)
    assert "--work" in argv and "--keep-alive" in argv


def test_row_stop_addresses_the_row_and_carries_the_work_dir(wiz, qapp, registry,
                                                             mocked_spawn):
    page = _page(wiz)
    registry(_device("x86/backend"))
    page._refresh_reality()
    row = _row(page, "x86/backend")
    assert row.stop.isEnabled() and not row.start.isEnabled()
    row.stop.click()
    _finish(page, qapp)
    argv = mocked_spawn.last
    assert argv[-2:] == ["--stop-device", "x86/backend"]
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


def test_no_consent_tick_is_labelled_as_an_architecture(wiz, registry):
    """The consent ticks must not read as an ARCHITECTURE choice.

    An operator read the QMP cell's checkbox — then labelled ``arm`` — as picking the
    guest's CPU architecture, in a table whose very next-door column is ``Arch`` and
    in a project that builds ARM (rpi5/jetson) and x86 images side by side. It never
    was: every one of these ticks is per-click CONSENT for a destructive verb, and
    architecture follows the selected image into the Arch column with no control on
    this page able to change it.

    Asserted on the RENDERED widget (``.text()``), not on the constructor call, so a
    label that is overwritten later — by a repaint, a retranslation, an ``_arm_row``
    pass — still fails this. And asserted as an EXCLUSION of every architecture
    spelling rather than only as an equality, so the next label to be invented here
    cannot quietly reintroduce the confusion.
    """
    page = _page(wiz)
    registry(_device("rpi5/pki"), _device("x86/backend"))
    page._refresh_reality()

    ticks = {"mesh save": page.mesh_save_arm}
    for label in ("rpi5/pki", "x86/backend"):
        row = _row(page, label)
        ticks[f"{label} reset"] = row.arm_reset
        ticks[f"{label} overwrite"] = row.arm_save

    for where, tick in ticks.items():
        text = tick.text()
        assert text.startswith("confirm "), (
            f"{where}: consent tick reads {text!r}, not a confirmation")
        for arch in ("arm", "arm64", "aarch64", "x86", "x86_64", "amd64", "arch"):
            assert arch not in text.lower().split(), (
                f"{where}: consent tick reads {text!r} — that is an ARCHITECTURE "
                "name, and this table already has an Arch column")

    # each names the verb it consents to, because the Save cell holds TWO buttons
    # and a bare "confirm" there cannot say which of them it unlocks
    assert _row(page, "rpi5/pki").arm_reset.text() == "confirm reset"
    assert _row(page, "rpi5/pki").arm_save.text() == "confirm overwrite"
    assert page.mesh_save_arm.text() == "confirm mesh save"

    # ...and the surfaces that tell the operator to tick it agree with the label
    assert "confirm reset" in _row(page, "rpi5/pki").qmp["reset"].toolTip()
    assert "confirm mesh save" in page.mesh_save_btn.toolTip()

    # the Arch column is where architecture actually lives, and it follows the image
    assert page_mod._HEADERS[page_mod._MCOL_ARCH] == "Arch"
    arches = {label: _cell(page, label, page_mod._MCOL_ARCH).text()
              for label in ("rpi5/pki", "x86/backend")}
    assert all(arches.values()), f"the Arch column is empty: {arches}"


def test_a_consent_tick_still_gates_its_verb_after_the_relabel(wiz, registry):
    """The relabel is WORDING only — the gate itself must be exactly as shut.

    Named separately from the destructive-path tests above so that a future edit to
    the LABELS cannot pass by having quietly loosened the guard they describe.
    """
    page = _page(wiz)
    registry(_device("rpi5/pki"))
    page._refresh_reality()
    row = _row(page, "rpi5/pki")

    assert not row.arm_reset.isChecked()
    assert not row.qmp["reset"].isEnabled(), "reset is live without its tick"
    row.arm_reset.setChecked(True)
    assert row.qmp["reset"].isEnabled()
    row.arm_reset.setChecked(False)
    assert not row.qmp["reset"].isEnabled(), "unticking did not re-shut the gate"

    # overwrite has no previous save yet, so its tick is not even offered
    assert not row.arm_save.isChecked()
    assert not row.overwrite.isEnabled()
    # and the whole-mesh tick starts shut, with no preview to consent to
    assert not page.mesh_save_arm.isChecked()
    assert not page.mesh_save_arm.isEnabled()


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
    assert "Reset is not confirmed" in page.note.text()
    assert "confirm reset" in page.note.text()   # the refusal names the tick
    assert "-no-reboot" in page.note.text()      # the loud inline warning
    assert "refused: reset" in page.log.toPlainText()

    row.arm_reset.setChecked(True)
    # ticking is what PRINTS the warning — read before the button lights up
    assert "Reset is confirmed" in page.note.text()
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


def test_save_copy_does_not_report_an_OLD_save_as_the_new_one(
        wiz, qapp, registry, mocked_spawn, existing_save):
    """"No new file appeared" has to survive the device ALREADY having a save.

    The test above it runs against an empty saves dir, so ``after`` is empty whether
    or not the diff against ``before`` is computed — which is why replacing
    ``[p for p in after if p not in before]`` with ``list(after)`` keeps this whole
    file green. On a device that already has one save, that mutant reports "Saved
    <label> to <THE OLD FILE>" for a copy that wrote nothing: a green result naming a
    file the operator could restore from and lose data by trusting.

    Restored from commit 3c241381, which added it to test_pages_qemu.py; PR #90 moved
    the save UI to this page and dropped the guard without replacing it.
    """
    page = _page(wiz)
    dev = _device("rpi5/pki")
    registry(dev)
    old = existing_save(dev)
    mocked_spawn.write_saves = False               # exits 0, writes nothing
    page._refresh_reality()

    assert _row(page, "rpi5/pki").saves == [old], "the earlier save was not found"
    _row(page, "rpi5/pki").save.click()
    _finish(page, qapp)

    note = page.note.text()
    assert "no new file appeared" in note, note
    assert "Do not treat this device as saved" in note
    assert old not in note, \
        "the pre-existing save was reported as if this run had produced it"


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
    assert "Overwrite is not confirmed" in page.note.text()
    assert "confirm overwrite" in page.note.text()   # the refusal names the tick
    assert "not confirmed" in page.log.toPlainText()

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


def test_overwrite_reports_a_target_that_is_no_longer_there(
        wiz, qapp, registry, mocked_spawn, existing_save):
    """The overwrite arm verifies on disk too, and nothing here proved it.

    Replacing its ``if not os.path.exists(target)`` with ``if False`` leaves this
    file green, so an overwrite whose file had gone would still say "Overwrote ...".
    That is the realistic failure, not a contrived one: when a save fails after
    creating its target, the runner renames it to ``<name>.partial`` — so the exact
    path the operator was just told about is missing afterwards, while the exit
    status still reads 0.

    Restored from commit 3c241381, which added it to test_pages_qemu.py; PR #90 moved
    the save UI to this page and dropped the guard without replacing it.
    """
    page = _page(wiz)
    dev = _device("rpi5/pki")
    registry(dev)
    target = existing_save(dev)
    mocked_spawn.move_save_aside = True            # exits 0, moves it aside
    page._refresh_reality()

    row = _row(page, "rpi5/pki")
    assert row.overwrite_target == target
    row.arm_save.setChecked(True)
    row.overwrite.click()
    _finish(page, qapp)

    note = page.note.text()
    assert "not there now" in note, note
    assert "NOT saved" in note
    assert "Overwrote" not in note
    # ...and the file really did go where a failed save leaves it
    assert not os.path.exists(target)
    assert os.path.exists(target + ".partial")


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
    registry(_device("rpi5/pki"), _device("x86/backend"), _device("x86/frontend"))
    page._refresh_reality()
    assert not page.mesh_save_arm.isEnabled(), "armed with no preview"

    page.mesh_save_btn.click()
    assert not mocked_spawn, "the preview ran a command"
    note = page.mesh_save_note.text()
    assert "Mesh save preview" in note
    for label in ("rpi5/pki", "x86/backend", "x86/frontend"):
        assert label in note
    assert "16.0 GB" in note and "32.0 GB" in note      # per-device budgets
    assert "Fleet total 80.0 GB" in note                # 16 + 32 + 32
    assert "KEYS" in note
    assert page.mesh_save_arm.isEnabled()
    assert not page.mesh_save_arm.isChecked()


def test_save_mesh_runs_only_once_armed_and_streams_into_the_log(
        wiz, qapp, registry, mocked_spawn, work_dir):
    page = _page(wiz)
    registry(_device("rpi5/pki"), _device("x86/backend"), _device("x86/frontend"))
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
    registry(_device("rpi5/pki"), _device("x86/backend"), _device("x86/frontend"))
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
    registry(_device("rpi5/pki"), _device("x86/backend", state="stopped"),
             _device("x86/frontend"))
    page._refresh_reality()
    page.mesh_save_btn.click()
    note = page.mesh_save_note.text()
    assert "will NOT be saved" in note and "x86/backend" in note
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

    registry(_device("x86/frontend", port=22357))
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
    registry(_device("x86/frontend", port=22357))
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
    registry(_device("x86/frontend", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    assert not spawned[0].terminated

    _row(page, "x86/frontend").stop.click()
    _finish(page, qapp)
    assert spawned[0].terminated, "the gateway's tunnel outlived the gateway"
    assert "closed the x86/frontend web tunnel" in page.log.toPlainText()
    assert "No web tunnel is open" in page.tunnel_note.text()


def test_stop_all_takes_every_tunnel_down(wiz, qapp, registry, spawned,
                                          mocked_spawn, monkeypatch):
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/frontend", port=22357))
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
    registry(_device("x86/frontend", port=22357))
    page._refresh_reality()
    page.web_btn.click()
    page.cleanupPage()
    assert spawned[0].terminated
    assert not page._tunnels
    assert "left the mesh emulation page" in page.log.toPlainText()


def test_closing_the_studio_takes_the_tunnels_down(wiz, registry, spawned,
                                                   monkeypatch):
    """Qt calls cleanupPage() on Back, never on Exit or a window close — so the
    third way out of this page needs its own hook, or a tunnel survives the Studio
    and the next session finds its loopback port taken."""
    monkeypatch.setattr(page_mod.QtGui.QDesktopServices, "openUrl",
                        staticmethod(lambda url: None))
    page = _page(wiz)
    registry(_device("x86/frontend", port=22357))
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


# ══════════════════════════════════════════════════════════════════════════════════
# THE REPLICAS COLUMN AND THE RUNNING-MESH MONITOR (#336)
#
# Written after a refutation ran a 13-mutation battery against the original branch and
# every mutation survived. Two of those mutations live on this page — raising the
# emulated-device ceiling from 1 to 5, and dropping the QEMU page's hide_view_controls
# — and both are covered here and in test_pages_qemu.py.
#
# THE COLUMN IS DELIBERATELY A SECOND SPELLING OF Start/Stop, and these tests pin that
# rather than paper over it: Apply(1) must produce the byte-identical argv the Start
# button produces, because a replica control that grew its own process lane is exactly
# the divergence T3 removed from this page. See _REPLICAS_TIP.
# ══════════════════════════════════════════════════════════════════════════════════

def test_the_device_replica_ceiling_is_one_and_the_header_says_so(wiz):
    """M10. An emulated device is ONE guest per built image: its MAC, mesh IP, ssh
    port and container name are allocated per PLAN ROW, so a second instance collides
    on all four and the runner has no verb to ask for one. Raising the ceiling offers
    a number the runner would refuse. The ceiling is also in the HEADER text, because
    a tooltip on the cell widget is unreachable until a session is picked."""
    page = _page(wiz)
    assert page_mod._HEADERS[page_mod._MCOL_REPLICAS] == "Replicas (0/1)"
    head = page.devices.horizontalHeaderItem(page_mod._MCOL_REPLICAS)
    assert head is not None and "no verb to ask for one" in head.toolTip()
    assert "ADDS NO NEW CAPABILITY" in head.toolTip()
    for row in page._rows:
        assert row.replicas is not None
        assert row.replicas.ceiling == 1
        for _ in range(6):
            row.replicas.bump(+1)
        assert row.replicas.target == 1, "a device row offered more than one guest"


def test_apply_one_runs_the_byte_identical_argv_the_start_button_runs(wiz, qapp,
                                                                      mocked_spawn):
    """The column's whole honesty claim, measured. If these two argvs ever differ,
    the page has grown a second per-device start — the divergence T3 deleted."""
    page = _page(wiz)
    row = _row(page, "x86/backend")
    row.start.click()
    _finish(page, qapp)
    via_button = list(mocked_spawn.last)

    page2 = _page(wiz) if False else page          # same page, second press
    idx = _index(page2, "x86/backend")
    row.replicas.bump(+1)
    assert row.replicas.target == 1
    page2._apply_replicas(idx)
    _finish(page2, qapp)
    via_apply = list(mocked_spawn.last)
    assert via_apply == via_button, (
        "Apply(1) is supposed to BE the Start button, not a second spelling of it\n"
        f"  button: {via_button}\n  apply : {via_apply}")


def test_apply_zero_runs_the_stop_button_and_nothing_else(wiz, qapp, registry,
                                                          mocked_spawn):
    page = _page(wiz)
    registry(_device("x86/backend"))
    page._refresh_reality()
    row = _row(page, "x86/backend")
    assert row.up and row.replicas.target == 1
    row.stop.click()
    _finish(page, qapp)
    via_button = list(mocked_spawn.last)

    page._refresh_reality()
    row = _row(page, "x86/backend")
    row.replicas.target = 1                 # reality still says up in the registry
    row.replicas.bump(-1)
    page._apply_replicas(_index(page, "x86/backend"))
    _finish(page, qapp)
    assert list(mocked_spawn.last) == via_button
    assert mocked_spawn.last[-2:] == ["--stop-device", "x86/backend"]


def test_apply_with_nothing_to_change_runs_nothing(wiz, qapp, mocked_spawn):
    """A press whose target already matches reality must not re-run a verb: on a
    running device that would be a second `--only-exact` boot of a container that is
    already up."""
    page = _page(wiz)
    row = _row(page, "x86/backend")
    assert row.replicas.target == 0 and not row.up
    page._apply_replicas(_index(page, "x86/backend"))
    qapp.processEvents()
    assert list(mocked_spawn) == [], "Apply ran a verb with nothing to change"


def test_the_replica_target_follows_reality_until_the_operator_moves_it(wiz, registry):
    """The observed count is the row's OWN liveness — the same answer Start and Stop
    are armed from — so the two controls can never disagree about whether the device
    is up."""
    page = _page(wiz)
    row = _row(page, "x86/backend")
    assert row.replicas.observed == 0 and row.replicas.target == 0
    registry(_device("x86/backend"))
    page._refresh_reality()
    row = _row(page, "x86/backend")
    assert row.up and row.replicas.observed == 1 and row.replicas.target == 1
    assert not row.replicas.apply.isEnabled()
    row.replicas.bump(-1)                          # operator is mid-decision
    page._refresh_reality()                        # a poll tick lands
    row = _row(page, "x86/backend")
    assert row.replicas.target == 0, "the poll took the operator's target away"
    assert row.replicas.count.text() == "1 → 0"


def test_a_finished_verb_clears_the_replica_target(wiz, qapp, registry, mocked_spawn):
    """One press, one ask. Cleared rather than snapped to a count, because the count
    is re-read AFTER this and a target set from the pre-verb truth would re-arm Apply
    against the post-verb one."""
    page = _page(wiz)
    row = _row(page, "x86/backend")
    row.replicas.bump(+1)
    assert row.replicas.pending
    page._apply_replicas(_index(page, "x86/backend"))
    _finish(page, qapp)
    assert not _row(page, "x86/backend").replicas.pending


def test_no_replica_control_is_live_while_a_verb_owns_the_page(wiz, registry):
    page = _page(wiz)
    registry(_device("x86/backend"))
    page._refresh_reality()
    page._set_running(True)
    page._sync_controls()
    for row in page._rows:
        assert not row.replicas.apply.isEnabled()
        assert not row.replicas.plus.isEnabled()
        assert not row.replicas.minus.isEnabled()


# ---- the running-mesh monitor mounted on this page --------------------------------

def test_the_monitor_is_mounted_collapsed_greyed_and_starts_no_shell(wiz):
    """PR #291's contract, on a second page: collapsed by default, greyed until
    something is up, and MOUNTING IT STARTS NOTHING — no probe, no timer, no shell."""
    page = _page(wiz)
    sec = page.monitor
    assert sec.monitor.scaling is True
    assert sec.monitor.table.columnCount() == 7
    assert not sec.section.is_expanded()
    assert not sec.monitor.isEnabled()
    assert not sec.timer.isActive()
    assert getattr(sec, "_probe", None) is None, "mounting the monitor started a probe"
    assert getattr(sec, "_scale_worker", None) is None


def test_the_monitor_says_it_is_not_the_table_above_it(wiz):
    """Two tables on one screen that both mean "the mesh": the rows above are emulated
    QEMU guests this page boots, the section is the compose project and the kind
    cluster on THIS workstation. Neither is a view of the other."""
    page = _page(wiz)
    note = page.monitor.monitor.note.text()
    assert "not the emulated guests in the table above" in note
    assert "THIS" in note


def test_this_page_offers_no_second_make_view_launcher(wiz):
    """M9's twin. `make view` binds loopback ports behind ONE session-owner guard;
    a second launcher on a second page fights it for one session lock."""
    page = _page(wiz)
    w = page.monitor.monitor
    assert not w.view_up_btn.isVisibleTo(w)
    assert not w.view_down_btn.isVisibleTo(w)
    assert "local-mesh page" in w.view_up_btn.toolTip()


def test_leaving_and_hiding_the_page_stop_the_monitors_clock(wiz, qapp, registry):
    page = _page(wiz)
    page.monitor.section.toggle.setChecked(True)
    qapp.processEvents()
    assert page.monitor.timer.isActive()
    page.hide()
    qapp.processEvents()
    assert not page.monitor.timer.isActive()
    page.show()
    qapp.processEvents()
    page.monitor.timer.start()
    page.cleanupPage()
    assert not page.monitor.timer.isActive()


def test_nothing_on_this_page_can_reach_a_modal(wiz):
    """The repo's standing rule, re-checked over the code #336 added: a QMessageBox
    reachable from validatePage / isComplete / initializePage / itemChanged hangs the
    headless suite."""
    import re
    src = inspect.getsource(page_mod)
    for name in ("validatePage", "isComplete", "initializePage", "itemChanged",
                 "_arm_replicas", "_bump_replicas", "_apply_replicas"):
        m = re.search(rf"\n    def {name}\b.*?(?=\n    def |\nclass |\Z)", src,
                      re.S)
        if m:
            assert "QMessageBox" not in m.group(0)
            assert ".exec(" not in m.group(0)


# ══════════════════════════════════════════════════════════════════════════════════
# RESIDUE FROM THE ADJUDICATION OF WORKTREE studio/c-336 (#336, #341). Matched against
# this file by what each test asserts; the three below pin what nothing above pinned,
# each proven by a production mutation that survived this whole file and is killed
# here:
#
#   X9   _arm_replicas drops the docker gate on + / Apply
#   X12  this page's _monitor_node raises (a broken node factory)
#
# The QEMU page's twin of X12 is already caught there by
# test_the_monitor_node_is_built_once_and_is_a_plain_local_stack_node; this page had no
# test that ever called its factory, and MeshMonitorSection's own tests cannot — they
# build their own.
# ══════════════════════════════════════════════════════════════════════════════════

def _mon_unit(name="casdoor-1", ns="hugmesh-pki", workload="casdoor"):
    return mm.MeshUnit(
        lane="kind", namespace=ns, name=name, owner="rs", phase="Running 1/1",
        ready=True, reason="", state="ok", door=mm.Door(blocked="no door"),
        scale=mm.ScaleTarget("deployment", workload, ns, refused=""))


def _mon_snapshot(*units):
    return mm.MonitorSnapshot(
        taken_at="11:00:00", compose=mm.LaneState(False, "not started"),
        kind=mm.LaneState(True, "cluster hugmesh-local · 1 pod(s)"),
        units=tuple(units))


def _mon_wait(qapp, pred, seconds=10):
    deadline = time.time() + seconds
    while not pred() and time.time() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    qapp.processEvents()
    return pred()


def test_without_docker_a_start_is_refused_but_a_stop_is_not(wiz, registry):
    """X9. Stopping never needs a healthy daemon; starting always does — the same gate
    the Start button is armed from. Asserted on a STOPPED device, deliberately: on a
    running one the ceiling of 1 already disables +, so the same assertion there
    passes with the docker gate deleted (measured — that version survived)."""
    page = _page(wiz)
    page._docker_paint((False, "docker was not found on PATH."))
    stopped = _row(page, "x86/backend")
    assert stopped.replicas.observed == 0
    assert stopped.replicas.plus.isEnabled() is False, "a start offered with no daemon"
    stopped.replicas.bump(+1)          # as if the target predated the daemon dying
    page._sync_controls()
    assert stopped.replicas.apply.isEnabled() is False

    registry(_device("rpi5/pki"))
    page._refresh_reality()
    running = _row(page, "rpi5/pki")
    running.replicas.minus.click()
    assert running.replicas.apply.isEnabled() is True, "a stop must stay reachable"


def test_expanding_the_monitor_reads_once_off_the_gui_thread_through_this_pages_node(
        qapp, wiz, monkeypatch):
    """X12. MeshMonitorSection's own tests pin the off-thread read; what they cannot
    pin is THIS page's node factory. A factory that raises is folded by ``refresh()``
    into a "could not read" snapshot — collapsed and greyed forever, with every
    section-level test green — so the read has to be driven from the page's own
    toggle, through the page's own factory."""
    threads = []

    def fake(gen, node, **kw):
        threads.append(threading.get_ident())
        return _mon_snapshot(_mon_unit())

    monkeypatch.setattr(mm, "snapshot", fake)
    page = _page(wiz)
    assert page.monitor.snapshot is None and threads == [], "mounting read the mesh"
    page.monitor.section.toggle.setChecked(True)
    try:
        assert _mon_wait(qapp, lambda: page.monitor.snapshot is not None)
    finally:
        page.monitor.shutdown()
    assert len(threads) == 1, f"{len(threads)} reads for one expand"
    assert threads[0] != threading.get_ident(), "the read ran ON the GUI thread"
    assert page.monitor.monitor.isEnabled() is True


def test_a_scale_from_this_page_runs_off_the_gui_thread_behind_the_busy_guard(
        qapp, wiz, monkeypatch):
    """X12's other half: the whole path an operator presses on THIS screen — expand,
    +, Apply — through the page's mount and the page's node, with
    ``mesh_monitor.scale`` stubbed so nothing shells out."""
    unit = _mon_unit()
    monkeypatch.setattr(mm, "snapshot", lambda gen, node, **kw: _mon_snapshot(unit))
    seen = {}

    def fake_scale(gen, node, u, n, **kw):
        seen["thread"] = threading.get_ident()
        seen["ask"] = (u.key, n)
        return True, f"asked for {n} replica(s)"

    monkeypatch.setattr(mm, "scale", fake_scale)
    page = _page(wiz)
    page.monitor.section.toggle.setChecked(True)
    try:
        assert _mon_wait(qapp, lambda: page.monitor.snapshot is not None)
        cell = page.monitor.monitor.scale_cell(unit.key)
        assert cell is not None, "the running row offered no Replicas control"
        cell.plus.click()
        cell.apply.click()
        assert _mon_wait(qapp, lambda: "ask" in seen
                         and not page.monitor.monitor._scale_busy)
    finally:
        page.monitor.shutdown()
    assert seen["ask"] == (unit.key, 2)
    assert seen["thread"] != threading.get_ident(), "the scale ran ON the GUI thread"
    assert "asked for 2 replica(s)" in page.monitor.monitor.scale_status_text()


# ---- #637: a session whose recorded config names an unwalked domain is not booted ----
from _session_records import write_build_record  # noqa: E402

_MESH_SESSION = "20260810-101010-mesh"


def test_an_unwalked_domain_refuses_every_start_inline(wiz, qapp, mocked_spawn):
    write_build_record(_MESH_SESSION, domains=("a.example", "b.example"),
                       reviewed=("hugmesh.net", "a.example"))
    page = _page(wiz)
    assert page._current_session().name == _MESH_SESSION
    note = page.domain_gate_note
    assert note.isVisible() and "b.example" in note.text()
    assert "a.example" not in note.text().split("—")[1]
    assert not page.start_btn.isEnabled()
    assert all(not row.start.isEnabled() for row in page._rows)
    # defence in depth: the slots themselves refuse, not only the greyed buttons
    page._start_mesh()
    page._start_device(0)
    assert len(mocked_spawn) == 0, "a refused session booted anyway"
    assert "refused" in page.log.toPlainText() and "b.example" in page.note.text()


def test_a_walked_or_pre_495_session_still_starts(wiz, qapp, mocked_spawn):
    write_build_record(_MESH_SESSION, domains=("a.example",), reviewed=())
    page = _page(wiz)
    assert not page.domain_gate_note.isVisible()
    assert page.start_btn.isEnabled()
    page.start_btn.click()
    _finish(page, qapp)
    assert len(mocked_spawn) == 1
