"""QemuPage + the two ends of the qemu_e2e chain, driven offscreen.

Covers the operator ask verbatim ("run these tests containerized with qemu using
images built in other sessions or start a new build and then run these emulations
after; also … an option for when test environment is enabled on builds to run all
e2e tests with qemu emulated devices"):

* QemuPage "use existing" — the session picker offers only image-holding sessions,
  previews the exact runner command, and List/Run stream the runner's output;
* QemuPage "build first" — rejoins the image flow and arms cfg.qemu_e2e, the SAME
  non-argv field BuildPage's checkbox drives;
* BuildPage — the checkbox is gated on --env test (greyed + unticked on prod, and
  the collect re-enforces it against a programmatic bypass);
* ProgressPage — an all-ok build with the opt-in launches the containerized runner
  against the session's own workdir.

And the DEVICE CONSOLE the operator asked for on top of it ("they can be logged
into with a terminal by shell with a single button using the default bash terminal
application on the desktop as the superuser or another user that can be selected
from available users in all domains by dropdown per device … and that it has the
same local mesh start and stop options with additional buttons to control the qemu
options on each running emulated device"): the per-device table, its shell button,
its start/stop and QMP controls, and the --keep-alive tick that leaves the guests
up for it.

WHAT IS REAL HERE, AND WHY IT MATTERS
-------------------------------------
Everything this layer owns is exercised unpatched:

* the device registry is written to DISK as ``<work>/devices/<safe-label>.json``,
  the actual cross-layer file format, and the page discovers it with the real
  ``core.qemu_devices.discover_devices``;
* the device subcommands run the generator tree's real
  ``tests/qemu/run-qemu-docker.sh``, which here is a stub that echoes its own argv —
  so an assertion about "--stop-device rpi5/pki" is an assertion about the argv a
  CHILD PROCESS received, not about a string this page built;
* ``--keep-alive`` is asserted on the line the stub echoed, for the same reason: a
  preview that says the flag while the spawn omits it is precisely the failure this
  console cannot survive, since nothing else leaves a guest up to register itself.

Hermetic all the same: no docker daemon, no qemu, no images, and nothing is ever
really launched into a desktop terminal.
"""
import dataclasses
import json
import os
import time
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")


def _install_fake_qemu_devices():
    """Return core.qemu_devices, standing one in ONLY if this tree has none yet.

    QemuPage imports that module unconditionally and it belongs to ANOTHER layer, so
    in a tree where it has not landed the wizard import below would fail before a
    single test ran. The stand-in is a transcription of that layer's published API
    (Device, SSH_HOST, QMP_COMMANDS, DEVICE_ACTIONS, discover_devices, ssh_argv,
    terminal_argv, qmp_argv, device_control_argv, stop_all_argv, available_logins) —
    including reading the on-disk registry, so the tests below hand the page real
    files either way. It is installed only when the real module is absent, so these
    tests exercise the real one the moment it lands.

    Nothing here stands in for anything THIS layer owns: the page, its options and
    core.qemu_tests.runner_command are always the real code.
    """
    import importlib
    import importlib.util
    import shutil
    import sys
    import types
    from dataclasses import dataclass, field

    name = "hugmesh_studio.core.qemu_devices"
    if importlib.util.find_spec(name) is not None:
        return importlib.import_module(name)

    from hugmesh_studio.core import cloud_deploy

    SSH_HOST = "127.0.0.1"
    SSH_OPTIONS = ("-o", "StrictHostKeyChecking=no",
                   "-o", "UserKnownHostsFile=/dev/null")
    SUPERUSER_COMMAND = "sudo -i"
    QMP_COMMANDS = ("pause", "resume", "reset", "powerdown", "status")
    DEVICE_ACTIONS = ("start", "stop")
    DEVICES_SUBDIR = "devices"
    RUNNER = os.path.join("tests", "qemu", "run-qemu-docker.sh")

    @dataclass
    class Device:
        label: str = ""
        platform: str = ""
        role: str = ""
        board: str = ""
        container: str = ""
        ssh_host_port: int = 0
        ssh_user: str = ""
        ssh_key: str = ""
        users: list = field(default_factory=list)
        qmp: str = ""
        state: str = ""
        started_at: str = ""

        @property
        def is_running(self) -> bool:
            return self.state not in ("stopped", "")

    def devices_dir(work_dir):
        return os.path.join(work_dir, DEVICES_SUBDIR)

    def discover_devices(work_dir):
        root = devices_dir(work_dir)
        if not os.path.isdir(root):
            return []
        found = []
        for entry in sorted(os.listdir(root)):
            if not entry.endswith(".json"):
                continue
            path = os.path.join(root, entry)
            try:
                with open(path, encoding="utf-8") as fh:
                    raw = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(raw, dict) or not str(raw.get("label") or "").strip():
                continue
            dev = Device(**{f.name: raw.get(f.name, getattr(Device(), f.name))
                            for f in dataclasses.fields(Device)})
            dev.ssh_host_port = int(dev.ssh_host_port or 0)
            found.append((os.path.getmtime(path), dev))
        found.sort(key=lambda pair: pair[1].label)
        found.sort(key=lambda pair: (pair[1].started_at, pair[0]), reverse=True)
        return [dev for _m, dev in found]

    def ssh_argv(dev, user, *, superuser=False):
        argv = ["ssh", "-i", dev.ssh_key, "-p", str(dev.ssh_host_port),
                *SSH_OPTIONS, f"{user}@{SSH_HOST}"]
        return argv + ["-t", SUPERUSER_COMMAND] if superuser else argv

    def terminal_argv(cmd_argv):
        for binary, exec_args in cloud_deploy._TERMINALS:
            if shutil.which(binary):
                return [binary, *exec_args, *cmd_argv]
        return None

    def _runner(generator_dir):
        return os.path.join(generator_dir, RUNNER)

    def qmp_argv(generator_dir, dev, command):
        if command not in QMP_COMMANDS:
            raise ValueError(command)
        return [_runner(generator_dir), "--qmp", dev.label, command]

    def device_control_argv(generator_dir, dev, action):
        if action not in DEVICE_ACTIONS:
            raise ValueError(action)
        if action == "stop":
            return [_runner(generator_dir), "--stop-device", dev.label]
        return [_runner(generator_dir), "--keep-alive", "--only", dev.label]

    def stop_all_argv(generator_dir):
        return [_runner(generator_dir), "--stop-all-devices"]

    def available_logins(dev, cfg_users):
        domains = {}
        for u in cfg_users or ():
            uname = str(getattr(u, "username", "") or "").strip()
            if uname and uname not in domains:
                domains[uname] = str(getattr(u, "domain", "") or "").strip()
        logins = []
        for login in [dev.ssh_user, *dev.users]:
            if login and login not in logins:
                logins.append(login)
        return [(l, f"{l} @ {domains[l]}" if domains.get(l) else l) for l in logins]

    mod = types.ModuleType(name)
    mod.SSH_HOST = SSH_HOST
    mod.SSH_OPTIONS = SSH_OPTIONS
    mod.SUPERUSER_COMMAND = SUPERUSER_COMMAND
    mod.QMP_COMMANDS = QMP_COMMANDS
    mod.DEVICE_ACTIONS = DEVICE_ACTIONS
    mod.DEVICES_SUBDIR = DEVICES_SUBDIR
    for obj in (Device, devices_dir, discover_devices, ssh_argv, terminal_argv,
                qmp_argv, device_control_argv, stop_all_argv, available_logins):
        setattr(mod, obj.__name__, obj)
    sys.modules[name] = mod
    # `from ...core import qemu_devices` reads the package ATTRIBUTE first, and a
    # hand-installed sys.modules entry does not set it.
    setattr(importlib.import_module("hugmesh_studio.core"), "qemu_devices", mod)
    return mod


qemu_devices = _install_fake_qemu_devices()               # noqa: E402

from hugmesh_studio.core import qemu_tests               # noqa: E402
from hugmesh_studio.core.config import User              # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo   # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod      # noqa: E402
from hugmesh_studio.gui.pages import qemu as qemu_page   # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets              # noqa: E402

from _helpers import advance_to, pairs, pick_mode        # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

#: The stub runner. It echoes its own argv — that echo is what the device-console
#: assertions read, so they are about the argv a CHILD received. The one branch that
#: is not instant stands in for the device Start path (`--keep-alive --only LABEL`),
#: which in production is a full emulated boot: the sleep gives Cancel a real process
#: GROUP to terminate, and it is a child of this shell rather than this shell itself
#: so that a cancel which fails to signal the group leaves the pipe open and hangs.
_STUB_RUNNER = """#!/usr/bin/env bash
echo "STUB-RUNNER $*"
if [ "$1" = "--keep-alive" ] && [ "$2" = "--only" ]; then
    sleep 120
fi
exit 0
"""


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _docker_stubbed(monkeypatch):
    # QemuPage states docker availability up-front; the REAL probe would make every
    # test here depend on the host's daemon. Stubbed to available — the unavailable
    # arm is asserted explicitly in test_qemu_page_says_when_docker_is_missing.
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def fake_generator(tmp_path):
    """A generator tree with one image-holding session and a STUB runner script
    that echoes its argv — the full launch path runs, nothing containerized does."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260201-000000-full"
    sess.mkdir(parents=True)
    for n in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
              "hugmesh-x86-amd64-be-test-20260807T172418Z.img"):
        (sess / n).write_bytes(b"")
    qdir = gen / "tests" / "qemu"
    qdir.mkdir(parents=True)
    stub = qdir / "run-qemu-docker.sh"
    stub.write_text(_STUB_RUNNER)
    stub.chmod(0o755)
    return gen, sess


@pytest.fixture
def wiz(qapp, fake_generator):
    gen, _sess = fake_generator
    w = wizard_mod.StudioWizard(str(gen))
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def real_wiz(qapp):
    # the BuildPage-gate tests walk the full standalone flow, whose pages read
    # real generator-tree data — they get the real tree, no qemu stub needed
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _qemu_page(wiz):
    pick_mode(wiz, "qemu")
    return advance_to(wiz, wizard_mod.QemuPage)


# ---- device-console fixtures ------------------------------------------------------

def _device(label="rpi5/pki", state="running", port=22301,
            users=("tester", "alice"), started_at="2026-08-15T00:00:00Z"):
    """One registry record in the A2 shape, as core.qemu_devices hands it over."""
    platform, _, role = label.partition("/")
    return qemu_devices.Device(
        label=label, platform=platform, role=role, board="",
        container="hugmesh-qemu-" + label.replace("/", "-"),
        ssh_host_port=port, ssh_user="tester",
        ssh_key="/home/op/gen/out/qemu-runs/keys/id_ed25519",
        users=list(users), qmp=f"/home/op/gen/out/qemu-runs/{role}-qmp.sock",
        state=state, started_at=started_at)


@pytest.fixture
def registry(fake_generator):
    """WRITE the given devices into the real registry directory.

    The registry IS the cross-layer interface (``<work>/devices/<safe-label>.json``,
    safe-label = the label with / and + replaced by _), so these tests hand the page
    files on disk and let its own discovery read them. Nothing about device discovery
    is monkeypatched — an assertion about a row is an assertion about the page
    parsing the same bytes the harness writes.
    """
    gen, _sess = fake_generator
    devdir = os.path.join(str(gen), qemu_tests.DEFAULT_WORK_SUBDIR, "devices")

    def register(*devices):
        os.makedirs(devdir, exist_ok=True)
        for dev in devices:
            safe = dev.label.replace("/", "_").replace("+", "_")
            with open(os.path.join(devdir, f"{safe}.json"), "w", encoding="utf-8") as fh:
                json.dump(dataclasses.asdict(dev), fh)
        return devices
    return register


@pytest.fixture
def terminal(monkeypatch):
    """A KNOWN terminal wrapper. The real terminal_argv answers what happens to be
    installed on the machine running the tests, so asserting on the launched argv
    would otherwise depend on whether this box has konsole."""
    monkeypatch.setattr(qemu_devices, "terminal_argv",
                        lambda argv: ["xterm", "-e", *argv])


@pytest.fixture
def spawned(monkeypatch):
    """Capture every DETACHED launch instead of running it — a real Popen here
    would open a terminal window on the developer's desktop mid-test."""
    calls = []

    def fake_popen(argv, **kw):
        calls.append((list(argv), kw))
        return SimpleNamespace(pid=4242)

    monkeypatch.setattr(qemu_page.subprocess, "Popen", fake_popen)
    return calls


def _find_row(page, label):
    """The device row for ``label`` — by label, never by position, because the
    registry's own newest-first ordering is not this page's business."""
    for row in page._device_rows:
        if row.dev.label == label:
            return row
    raise AssertionError(f"no device row for {label!r}; got "
                         f"{[r.dev.label for r in page._device_rows]}")


def _echoed(page):
    """Every line the STUB RUNNER printed — i.e. the argv a child actually got."""
    return [ln for ln in page.log.toPlainText().splitlines()
            if ln.startswith("STUB-RUNNER")]


def _pump_until(qapp, page, needle, seconds=15):
    """Deliver queued signals until ``needle`` shows up in the log (or time out)."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        qapp.processEvents()
        if needle in page.log.toPlainText():
            return True
        time.sleep(0.05)
    return False


# ---- QemuPage: "use existing images" ---------------------------------------------

def test_qemu_page_offers_sessions_and_previews_the_command(wiz, fake_generator):
    _gen, sess = fake_generator
    page = _qemu_page(wiz)
    assert page.use_existing.isChecked()                # the common case is default
    assert page.session_combo.count() == 1
    assert "2 image(s)" in page.session_combo.currentText()
    rows = page.rows_label.text()
    assert rows.index("rpi5/pki") < rows.index("x86/be")  # boot order: Pi first
    assert "decompressed" in rows                       # the .xz row says so
    # platform filter: all + the session's two platforms, Pi ranked first
    assert [page.platform_combo.itemData(i)
            for i in range(page.platform_combo.count())] == ["", "rpi5", "x86"]
    cmd = page.cmd_view.toPlainText()
    assert "run-qemu-docker.sh" in cmd
    assert f"--artifacts {sess}" in cmd
    assert "--jobs 2" in cmd and "--list" not in cmd    # preview shows the RUN argv


def test_qemu_list_devices_streams_the_stub_runner(wiz, qapp):
    page = _qemu_page(wiz)
    page._launch(list_only=True)
    assert page.worker is not None
    assert not page.run_btn.isEnabled()                 # running: no double-launch
    assert page.worker.wait(15000)
    qapp.processEvents()                                # deliver the queued signals
    log = page.log.toPlainText()
    assert "STUB-RUNNER" in log and "--list" in log and "--artifacts" in log
    assert "== device tests passed ==" in log
    assert page.run_btn.isEnabled() and not page.cancel_btn.isEnabled()


def test_qemu_use_existing_is_terminal_and_arms_nothing(wiz):
    page = _qemu_page(wiz)
    assert page.nextId() == -1 and page.isFinalPage()
    assert page.validatePage() is True
    assert wiz.cfg.qemu_e2e is False   # "test what exists" must not arm the hook


def test_qemu_page_says_when_docker_is_missing(wiz, monkeypatch):
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (False, "docker was not found on PATH."))
    page = _qemu_page(wiz)
    assert not page.run_btn.isEnabled() and not page.list_btn.isEnabled()
    assert "cannot run on this machine" in page.docker_note.text()


# ---- QemuPage: "build first, then test" ------------------------------------------

def test_qemu_build_first_rejoins_the_image_flow_and_arms_the_hook(wiz):
    page = _qemu_page(wiz)
    page.build_first.setChecked(True)
    assert page.nextId() != -1                          # rejoins, not terminal
    assert not page.session_box.isVisible()             # picker is the other arm's
    assert wiz.cfg.qemu_e2e is False
    wiz.next()
    assert wiz.cfg.qemu_e2e is True                     # armed on the way out
    assert not isinstance(wiz.currentPage(), wizard_mod.QemuPage)


def test_qemu_page_without_sessions_forces_build_first(wiz, monkeypatch):
    monkeypatch.setattr(qemu_tests, "discover_sessions", lambda *_a, **_k: [])
    page = _qemu_page(wiz)
    assert not page.use_existing.isEnabled()
    assert page.build_first.isChecked()
    assert page.nextId() != -1


# ---- BuildPage: the --env test gate ----------------------------------------------

def test_build_qemu_e2e_gate_follows_env(real_wiz):
    """The checkbox lives and dies with --env: greyed + unticked on prod (a prod
    image prunes the in-cluster test runner, so the assertions would target a stack
    the build removed on purpose), reversible on test — and never an argv token."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    assert build.env.currentText() == "test"            # the builders' own default
    assert build.qemu_e2e.isEnabled()
    build.qemu_e2e.setChecked(True)
    build.env.setCurrentText("prod")
    assert not build.qemu_e2e.isEnabled()
    assert not build.qemu_e2e.isChecked()               # prod may not carry the flag
    assert "prod" in build.qemu_e2e.toolTip()           # the WHY is on the widget
    build.env.setCurrentText("test")
    assert build.qemu_e2e.isEnabled()                   # reversible, not destroyed
    build.qemu_e2e.setChecked(True)
    build._preview()
    assert real_wiz.cfg.qemu_e2e is True
    assert not any("qemu" in a.lower() for a in real_wiz.cfg.to_cli_args())


def test_build_qemu_e2e_collect_reenforces_the_env_gate(real_wiz):
    """Belt and braces: even a programmatic check while prod is selected (the greyed
    widget still accepts setChecked) must not let a prod config carry the flag."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    build.env.setCurrentText("prod")
    build.qemu_e2e.setChecked(True)                     # bypasses the greyed gate
    build._preview()
    assert real_wiz.cfg.qemu_e2e is False


# ---- ProgressPage: the post-build hook -------------------------------------------

def test_progress_runs_the_device_tests_after_an_all_ok_build(wiz, fake_generator,
                                                              qapp):
    _gen, sess = fake_generator
    prog = wiz.page(wiz._page_ids["progress"])
    wiz.cfg.qemu_e2e = True
    prog._session = SimpleNamespace(workdir=str(sess))
    prog._maybe_qemu_tests()
    assert prog.qemu_worker is not None
    assert prog.qemu_worker.wait(15000)
    qapp.processEvents()                                # deliver the queued signals
    log = prog.log.toPlainText()
    assert "STUB-RUNNER" in log
    assert f"--artifacts {sess}" in log                 # tests THIS build's images
    assert "=== QEMU device tests passed ===" in log


def test_progress_skips_the_device_tests_without_the_opt_in(wiz):
    prog = wiz.page(wiz._page_ids["progress"])
    wiz.cfg.qemu_e2e = False
    prog._session = SimpleNamespace(workdir="/nowhere")
    prog._maybe_qemu_tests()
    assert prog.qemu_worker is None


def test_qemu_opt_out_on_buildpage_survives_a_page_revisit(real_wiz):
    """Unticking the BuildPage checkbox must STAY unticked across a page revisit.

    This is the operator-visible bug and it is the PRIMARY forward route, not an
    exotic one. QemuPage.validatePage() only ever SETS cfg.qemu_e2e True, and
    BuildPage.initializePage() calls wiz.collect_all(), which re-runs the
    validatePage of every VISITED page. QemuPage is still visited on this route, so
    it re-arms the flag the operator just cleared, and build.py:888 re-ticks the
    checkbox from it — the post-build device tests then run after an explicit opt-out.

    Driven through the UI only. A test that calls validatePage() directly pins the
    mechanism and passes while this route stays broken.
    """
    qp = _qemu_page(real_wiz)
    qp.build_first.setChecked(True)
    real_wiz.next()
    assert real_wiz.cfg.qemu_e2e is True, "build-first should arm the hook"

    build = advance_to(real_wiz, wizard_mod.BuildPage)
    build.env.setCurrentText("test")          # the checkbox is gated on --env test
    build.qemu_e2e.setChecked(False)          # the operator opts OUT
    build._preview()
    assert real_wiz.cfg.qemu_e2e is False, "unticking must clear the flag"

    real_wiz.back()                           # leave BuildPage...
    real_wiz.next()                           # ...and walk straight back into it

    page = real_wiz.currentPage()
    assert isinstance(page, wizard_mod.BuildPage), \
        f"expected to land back on BuildPage, got {type(page).__name__}"
    assert real_wiz.cfg.qemu_e2e is False, (
        "revisiting BuildPage re-armed qemu_e2e — the operator's opt-out was silently "
        "reverted, so the post-build device tests would run anyway")
    assert build.qemu_e2e.isChecked() is False, "the checkbox re-ticked itself"


# ---- --keep-alive: the tick that makes the console possible ----------------------

def test_qemu_keep_alive_is_a_real_option_field(wiz):
    """The tick must be a FIELD on QemuRunOptions, because runner_command is the one
    argv author for both the preview and the spawn and it can only emit fields it
    knows about. An option object carrying a stray attribute previews and runs a
    command with no --keep-alive in it — which leaves no guest up, so the device
    console below can never have a single row."""
    assert "keep_alive" in {f.name
                            for f in dataclasses.fields(qemu_tests.QemuRunOptions)}
    page = _qemu_page(wiz)
    assert not page.keep_alive.isChecked()                  # default: unchanged
    off = qemu_tests.runner_command(wiz.generator_dir, page._options(list_only=False))
    assert "--keep-alive" not in off                        # byte-identical default
    page.keep_alive.setChecked(True)
    on = qemu_tests.runner_command(wiz.generator_dir, page._options(list_only=False))
    assert "--keep-alive" in on
    assert off == [a for a in on if a != "--keep-alive"]     # the ONLY difference


def test_qemu_keep_alive_tick_reaches_the_previewed_command(wiz):
    page = _qemu_page(wiz)
    assert "--keep-alive" not in page.cmd_view.toPlainText()
    page.keep_alive.setChecked(True)
    assert "--keep-alive" in page.cmd_view.toPlainText()
    page.keep_alive.setChecked(False)
    assert "--keep-alive" not in page.cmd_view.toPlainText()


@pytest.mark.parametrize("ticked", [False, True])
def test_qemu_keep_alive_tick_reaches_the_spawned_runner(wiz, qapp, ticked):
    """The end of the chain: what the CHILD PROCESS was given.

    The stub echoes its own argv, so this reads the flag off the spawned command
    rather than off anything this page printed — the preview agreeing with itself is
    exactly the failure mode this replaces."""
    page = _qemu_page(wiz)
    page.keep_alive.setChecked(ticked)
    page._launch(list_only=True)
    assert page.worker.wait(15000)
    qapp.processEvents()
    echoed = _echoed(page)
    assert echoed, "the stub runner never ran"
    assert ("--keep-alive" in echoed[0]) is ticked


# ---- QemuPage: the device console ------------------------------------------------

def test_qemu_device_table_says_when_nothing_is_up(wiz):
    page = _qemu_page(wiz)
    assert page.devices.rowCount() == 0
    assert "No emulated device is registered" in page.dev_note.text()
    assert not page.devices_stop_all_btn.isEnabled()


def test_qemu_device_table_lists_the_registry_with_a_login_dropdown(wiz, registry):
    """One row per registered device, and the dropdown offers the logins that exist
    ON THAT GUEST — labelled with the domain they were configured for — plus the
    root row, which is last so a single Shell click never hands out root by
    default."""
    registry(_device(users=("tester", "alice")))
    page = _qemu_page(wiz)
    wiz.cfg.users = [User(username="alice", domain="example.org")]
    page.devices_refresh_btn.click()          # the operator's own re-read

    assert page.devices.rowCount() == 1
    assert page.devices.item(0, qemu_page._DCOL_LABEL).text() == "rpi5/pki"
    assert page.devices.item(0, qemu_page._DCOL_WHAT).text() == "rpi5/pki"
    assert page.devices.item(0, qemu_page._DCOL_STATE).text() == "running"

    combo = _find_row(page, "rpi5/pki").user
    logins = [combo.itemData(i) for i in range(combo.count())]
    labels = [combo.itemText(i) for i in range(combo.count())]
    assert logins[:2] == ["tester", "alice"]
    assert "alice @ example.org" in labels                   # the domain is shown
    assert labels[-1] == "root (via sudo -i)"
    assert combo.currentIndex() == 0 and combo.currentData() == "tester"


def test_qemu_device_columns_hold_what_their_headers_promise(wiz, registry):
    """Every column says what is in it — the container NAME is a column of its own,
    and the cell holding Start/Stop is headed as such rather than as 'Container'."""
    registry(_device())
    page = _qemu_page(wiz)
    headers = [page.devices.horizontalHeaderItem(c).text()
               for c in range(page.devices.columnCount())]
    assert headers[qemu_page._DCOL_CONTAINER] == "Container"
    assert (page.devices.item(0, qemu_page._DCOL_CONTAINER).text()
            == "hugmesh-qemu-rpi5-pki")
    assert headers[qemu_page._DCOL_SSH] == "SSH"
    assert page.devices.item(0, qemu_page._DCOL_SSH).text() == "127.0.0.1:22301"
    assert headers[qemu_page._DCOL_POWER] == "Start/Stop"
    assert page.devices.cellWidget(0, qemu_page._DCOL_POWER) is not None
    # the remaining HOST paths are on the label's tooltip, where they are copyable
    tip = page.devices.item(0, qemu_page._DCOL_LABEL).toolTip()
    assert "/home/op/gen/out/qemu-runs/keys/id_ed25519" in tip


def test_qemu_shell_button_opens_a_terminal_as_the_selected_user(
        wiz, registry, terminal, spawned):
    """The single button the ask is about: pick a login, click Shell, and a desktop
    terminal is launched DETACHED with an ssh to that guest as that login."""
    registry(_device(users=("tester", "alice")))
    page = _qemu_page(wiz)
    row = _find_row(page, "rpi5/pki")
    row.user.setCurrentIndex(row.user.findData("alice"))
    row.shell.click()

    assert len(spawned) == 1
    argv, kwargs = spawned[0]
    assert argv[:3] == ["xterm", "-e", "ssh"]                # wrapped in the terminal
    assert ("-p", "22301") in pairs(argv)                    # the published host port
    assert ("-i", "/home/op/gen/out/qemu-runs/keys/id_ed25519") in pairs(argv)
    assert ("-o", "StrictHostKeyChecking=no") in pairs(argv)
    assert "alice@127.0.0.1" in argv                         # loopback, as the pick
    assert "sudo -i" not in argv                             # a plain login is NOT root
    assert kwargs.get("start_new_session") is True           # detached: no GUI block
    assert "alice" in page.dev_note.text()


def test_qemu_shell_root_row_elevates_through_a_wheel_user(
        wiz, registry, terminal, spawned):
    """"Superuser" cannot mean `ssh root@`: the guest ships PermitRootLogin no and
    the assertions check it. The root row must therefore log in as the wheel user
    and sudo -i there."""
    registry(_device())
    page = _qemu_page(wiz)
    row = _find_row(page, "rpi5/pki")
    row.user.setCurrentIndex(row.user.count() - 1)           # "root (via sudo -i)"
    row.shell.click()

    argv, _kwargs = spawned[0]
    assert "tester@127.0.0.1" in argv
    assert not any(a.startswith("root@") for a in argv)
    assert "-t" in argv and argv[-1] == "sudo -i"
    assert "sudo -i" in page.dev_note.text()


def test_qemu_shell_is_disabled_when_the_device_published_no_port(
        wiz, registry, terminal, spawned):
    """A RUNNING device may still have ssh_host_port 0 — that record published
    nothing. ssh_argv emits the 0 verbatim (there is deliberately no fallback to 22,
    which on this host is the operator's own workstation sshd), so a live Shell
    button here would spawn a terminal running `ssh -p 0` and then claim a session
    had been opened. It is DISABLED, the SSH column says why, and the handler
    refuses even when called directly."""
    registry(_device(port=0))
    page = _qemu_page(wiz)
    row = _find_row(page, "rpi5/pki")

    assert row.dev.is_running                                # up, but unreachable
    assert not row.shell.isEnabled()
    assert "ssh_host_port 0" in row.shell.toolTip()
    assert page.devices.item(0, qemu_page._DCOL_SSH).text() == "not published"

    row.shell.click()                                        # disabled: ignored
    page._open_shell(0)                                      # and guarded underneath
    assert spawned == []
    assert "no SSH login" in page.dev_note.text()

    # the guest IS up, so everything that does not need a port stays live
    assert row.stop.isEnabled() and row.qmp["pause"].isEnabled()


def test_qemu_shell_is_disabled_when_the_record_names_no_key(
        wiz, registry, terminal, spawned):
    """A published port is not enough — the login also needs an identity.

    The entrypoint writes the record from several states, so a running device with a
    real port and an empty ``ssh_key`` is reachable on disk. ``ssh -i ''`` does not
    quietly fall back to the agent or to ~/.ssh; it fails on the identity file. So a
    live button here would open a terminal that only ever prints an error, which
    looks like a broken device rather than an incomplete record. The row is DISABLED
    and its tooltip names the missing key."""
    registry(dataclasses.replace(_device(), ssh_key=""))
    page = _qemu_page(wiz)
    row = _find_row(page, "rpi5/pki")

    assert row.dev.is_running and row.dev.ssh_host_port > 0   # up AND published...
    assert not row.can_shell                                  # ...but not loginable
    assert not row.shell.isEnabled()
    assert "no ssh key" in row.shell.toolTip()

    row.shell.click()
    page._open_shell(0)                                       # guarded underneath too
    assert spawned == []


def test_qemu_cancel_stays_armed_so_a_second_press_re_signals(wiz, registry, qapp):
    """Cancel sends SIGTERM and nothing escalates to SIGKILL.

    A runner that ignores the first signal — qemu wedged in TCG, a docker pull
    mid-layer — would be uncancellable from the GUI for the rest of the run if the
    first press disarmed the button. Re-sending is the only escalation the operator
    has, so the button stays armed while the work is still in flight and the log
    distinguishes the repeat."""
    registry(_device(label="x86/be", state="stopped", port=0))
    page = _qemu_page(wiz)
    row = _find_row(page, "x86/be")
    row.start.click()
    assert _pump_until(qapp, page, "STUB-RUNNER --keep-alive --only x86/be"), \
        "the boot stand-in never started"

    # Called directly rather than clicked: no event loop turn runs between the two,
    # so the worker cannot finish in between and the second press is guaranteed to
    # land while the work is still running — which is the case under test.
    page._cancel()
    assert page.cancel_btn.isEnabled(), "Cancel disarmed itself; SIGTERM cannot be re-sent"
    assert "cancelling" in page.log.toPlainText()

    page._cancel()
    assert "re-sending" in page.log.toPlainText()

    assert page.worker.wait(20000), "Cancel did not stop the boot"
    qapp.processEvents()
    assert not page.cancel_btn.isEnabled()       # ...but greyed once work really ends


def test_qemu_controls_are_disabled_for_a_device_that_is_not_running(
        wiz, registry, terminal, spawned):
    """A control fired at a dead guest cannot succeed, so it must not be clickable.
    Start is the mirror image — it is the one thing a stopped row is for."""
    registry(_device(),
             _device(label="x86/be", state="stopped", port=22302,
                     started_at="2026-08-15T00:00:01Z"))
    page = _qemu_page(wiz)
    live, dead = _find_row(page, "rpi5/pki"), _find_row(page, "x86/be")

    assert live.shell.isEnabled() and live.stop.isEnabled()
    assert all(b.isEnabled() for b in live.qmp.values())
    assert not live.start.isEnabled()                # already running

    assert not dead.shell.isEnabled() and not dead.stop.isEnabled()
    assert not any(b.isEnabled() for b in dead.qmp.values())
    assert not dead.user.isEnabled()
    assert dead.start.isEnabled()
    assert "not running" in dead.qmp["pause"].toolTip()

    dead.shell.click()                               # a disabled button ignores it
    assert spawned == []


def test_qemu_shell_without_a_terminal_says_so_inline(
        wiz, registry, monkeypatch, spawned):
    """No emulator on the desktop is a fact to READ — printed inline with the
    command to run by hand, never a modal (a modal in page logic hangs headless)."""
    registry(_device())
    monkeypatch.setattr(qemu_devices, "terminal_argv", lambda argv: None)
    page = _qemu_page(wiz)
    _find_row(page, "rpi5/pki").shell.click()

    assert spawned == []
    note = page.dev_note.text()
    assert "No terminal emulator" in note
    assert "ssh" in note and "22301" in note          # the command, to run by hand
    assert "ssh" in page.log.toPlainText()


def test_qemu_stop_button_streams_the_runner_subcommand(wiz, registry, qapp):
    """Stop mirrors LocalMeshPage's: the verb runs off the GUI thread, its output
    lands in the log live, and the page re-arms when it finishes. The argv asserted
    on is the one the stub runner echoed back, i.e. what a child really received."""
    registry(_device())
    page = _qemu_page(wiz)
    _find_row(page, "rpi5/pki").stop.click()

    assert page.worker is not None
    assert not page.run_btn.isEnabled()                # busy: no second verb on top
    assert page.worker.wait(15000)
    qapp.processEvents()                               # deliver the queued signals
    assert "STUB-RUNNER --stop-device rpi5/pki" in _echoed(page)
    assert "== stop rpi5/pki: done ==" in page.log.toPlainText()
    assert page.run_btn.isEnabled() and page.devices_refresh_btn.isEnabled()


def test_qemu_stop_all_is_gated_on_something_being_up(wiz, registry, qapp):
    registry(_device())
    page = _qemu_page(wiz)
    assert page.devices_stop_all_btn.isEnabled()
    page.devices_stop_all_btn.click()
    assert page.worker.wait(15000)
    qapp.processEvents()
    assert "STUB-RUNNER --stop-all-devices" in _echoed(page)


def test_qemu_qmp_buttons_are_built_from_the_exported_verb_tuple(
        wiz, registry, qapp):
    """core.qemu_devices.QMP_COMMANDS is the vocabulary; this page must not keep a
    second copy of it, so every verb in the tuple has a button, in that order, and
    a click sends exactly that verb for that row."""
    registry(_device())
    page = _qemu_page(wiz)
    row = _find_row(page, "rpi5/pki")
    assert list(row.qmp) == list(qemu_devices.QMP_COMMANDS)

    row.qmp["pause"].click()
    assert page.worker is not None and page.worker.wait(15000)
    qapp.processEvents()
    assert "STUB-RUNNER --qmp rpi5/pki pause" in _echoed(page)
    assert "== qmp pause rpi5/pki: done ==" in page.log.toPlainText()


def test_qemu_reset_button_does_not_pretend_the_guest_survives(wiz, registry):
    """Every launcher runs qemu with -no-reboot (tests/qemu/launch-pi.sh,
    launch-arm.sh and launch-x86.sh each pass it), and under that flag a QMP
    system_reset does not reboot: qemu shuts down and the process exits. A control
    labelled plain "Reset" would therefore destroy the device it appears to restart,
    so this layer presents it as the destructive action it is."""
    registry(_device())
    page = _qemu_page(wiz)
    reset = _find_row(page, "rpi5/pki").qmp["reset"]
    assert reset.text() != "Reset"
    assert "ends guest" in reset.text()
    tip = reset.toolTip()
    assert "DESTRUCTIVE" in tip and "-no-reboot" in tip


def test_qemu_device_verb_cancel_really_stops_it(wiz, registry, qapp):
    """Cancel must reach a live process GROUP, not just log a sentence.

    Start is the verb that needs it: a stopped device has no container to resume, so
    core.qemu_devices.device_control_argv re-enters the boot path
    (`--keep-alive --only LABEL`) — a full emulated boot, run with Next greyed. The
    stub stands in for that with a `sleep` CHILD, which makes this a real
    discriminator: signalling only the direct child would leave the sleep holding
    the stdout pipe open and the worker would still be reading it when the wait
    below expires. Passing therefore proves the spawn used start_new_session and the
    cancel killed the group."""
    registry(_device(label="x86/be", state="stopped", port=0))
    page = _qemu_page(wiz)
    row = _find_row(page, "x86/be")
    assert row.start.isEnabled()
    row.start.click()

    assert page.cancel_btn.isEnabled()
    assert not page.isComplete()                     # the page is locked meanwhile
    assert _pump_until(qapp, page, "STUB-RUNNER --keep-alive --only x86/be"), \
        "the boot stand-in never started"

    page.cancel_btn.click()
    assert page.worker.wait(20000), "Cancel did not stop the boot"
    qapp.processEvents()
    assert "== start x86/be: cancelled ==" in page.log.toPlainText()
    assert page.isComplete() and page.run_btn.isEnabled()


def test_qemu_build_first_hides_the_device_console(wiz, registry):
    """The console drives what THIS page's run leaves up; on the build-first arm
    that run has not happened yet, so it goes with the rest of that arm."""
    registry(_device())
    page = _qemu_page(wiz)
    assert page.devices_box.isVisible()
    page.build_first.setChecked(True)
    assert not page.devices_box.isVisible()
