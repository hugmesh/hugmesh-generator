"""tui — the Mesh emulation screen's QEMU for Windows (WHPX) backend, and the WSL2
sentence the Docker backend owes a native Windows Studio.

The TUI twin of test_pages_mesh_emulation_whpx.py. :data:`meshemu.BACKEND_KEY` cycles
``qemu_windows.BACKENDS``; under WHPX an x86 row's detail is ``qemu_windows``' own
preview plus the ``--qemu-windows`` CLI lines, an ARM row is ``row_refusal``'s
sentence and the whole-mesh verbs give way to the one-device-at-a-time sentence. Under
Docker on native Windows every bash hint gives way to ``qemu_tests.native_blocker``.

Host-independent and Qt-free: Windows is answered through ``osname="nt"`` (the
screen's ``osname`` and ``native_windows_blocker``'s), QEMU is a folder of empty
files in tmp_path, WHPX is a file standing in for WinHvPlatform.dll, and
``qemu_windows.running`` is a list the test fills. Nothing is spawned — one test walks
the whole screen over a subprocess landmine.
"""
import argparse
import functools
import os
import shlex
import subprocess

import pytest

from hugmesh_studio.core import emulation as emu
from hugmesh_studio.core import platform_info, qemu_tests
from hugmesh_studio.core import qemu_windows as qw
from hugmesh_studio.tui import journey, meshemu
from hugmesh_studio.tui import qemu as tui_qemu

SESSION = "20260810-101010-mesh"
_REAL_NATIVE_BLOCKER = platform_info.native_windows_blocker


def _answer_as(monkeypatch, osname):
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        functools.partial(_REAL_NATIVE_BLOCKER, osname=osname))


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    """Linux unless a test says otherwise — for the Docker lane's sentence AND for
    qemu_windows (whose ``os.name`` default would read the real host)."""
    _answer_as(monkeypatch, "posix")
    monkeypatch.setattr(meshemu.MeshEmuScreen, "osname", "posix")
    # ...and for the backend chooser, which a Mac is offered a shorter one of
    # (qemu_windows.backends): on a developer's Mac this file still answers as Linux.
    real_kind = platform_info.host_kind
    monkeypatch.setattr(platform_info, "host_kind",
                        lambda osname=None, sysplatform=None:
                        real_kind(osname, sysplatform or "linux"))
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: None)


@pytest.fixture(autouse=True)
def _no_probes(monkeypatch):
    monkeypatch.setattr(emu, "_runner_devices", lambda *_a, **_k: None)
    monkeypatch.setattr(emu, "_docker_running_names", lambda: None)


@pytest.fixture(autouse=True)
def live(monkeypatch):
    """The devices ``qemu_windows.running`` reports — none until a test adds one."""
    records: list[dict] = []
    monkeypatch.setattr(qw, "running", lambda work_dir, alive=None: list(records))
    return records


@pytest.fixture
def gen(tmp_path):
    """One 3-device session: rpi5/pki (ARM), x86/be, x86/fe."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / SESSION
    sess.mkdir(parents=True)
    for name in ("hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
                 "hugmesh-x86-amd64-be-test-20260807T172418Z.img",
                 "hugmesh-x86-amd64-fe-test-20260807T172419Z.img"):
        (sess / name).write_bytes(b"\0")
    return str(gen)


@pytest.fixture
def windows(monkeypatch):
    """A native Windows Studio: the Docker lane refused, qemu_windows asked as "nt"."""
    _answer_as(monkeypatch, "nt")
    monkeypatch.setattr(meshemu.MeshEmuScreen, "osname", "nt")


@pytest.fixture
def fake_install(tmp_path):
    qdir = tmp_path / "qemu"
    (qdir / "share").mkdir(parents=True)
    for n in (qw.QEMU_EXE, qw.QEMU_IMG_EXE):
        (qdir / n).write_bytes(b"")
    for n in (qw.CODE_FD, qw.VARS_FD):
        (qdir / "share" / n).write_bytes(b"")
    return qw.QemuInstall(str(qdir), str(qdir / qw.QEMU_EXE), str(qdir / qw.QEMU_IMG_EXE),
                          str(qdir / "share" / qw.CODE_FD),
                          str(qdir / "share" / qw.VARS_FD))


@pytest.fixture
def whpx_ready(tmp_path, monkeypatch, fake_install):
    dll = tmp_path / "WinHvPlatform.dll"
    dll.write_bytes(b"")
    monkeypatch.setattr(qw, "_WHPX_DLL", str(dll))
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: fake_install)
    return fake_install


def _at_table(gen) -> journey.Journey:
    j = journey.Journey(gen)
    j.feed("")            # welcome -> mode
    j.feed("5")           # the meshemu card
    assert j.slug == "meshemu"
    j.feed("1")           # the only session
    return j


def _screen(j) -> meshemu.MeshEmuScreen:
    return j._screens["meshemu"]


def _to(j, backend):
    for _ in qw.BACKENDS:
        if _screen(j)._backend == backend:
            return
        j.feed(meshemu.BACKEND_KEY)
    raise AssertionError(f"{meshemu.BACKEND_KEY} never reached {backend}")


def _detail(j, label) -> str:
    plan = _screen(j)._plan
    j.feed(str([d.label for d in plan.devices].index(label) + 1))
    return "\n".join(j.lines())


def _planned(j, label):
    return next(d for d in _screen(j)._plan.devices if d.label == label)


def _rec(label, **over):
    rec = {"label": label, "platform": "x86", "pid": 4321, "qmp_port": 4444,
           "ssh_port": 2222, "ui_port": 8443, "http_port": 8080,
           "run_dir": os.path.join("w", "native-runs", "x"), "display": "none",
           "mem_mb": qw.DEFAULT_MEM_MB}
    rec.update(over)
    return rec


# ── the toggle: the core's tuple, in its order ──────────────────────────────────────
def test_the_key_cycles_exactly_the_core_backends_with_their_labels(gen):
    j = _at_table(gen)
    seen = []
    for _ in qw.BACKENDS:
        backend = _screen(j)._backend
        seen.append((backend, meshemu.backend_label(backend)))
        assert f"backend   {meshemu.backend_label(backend)}" in "\n".join(j.lines())
        j.feed(meshemu.BACKEND_KEY)
        assert j.status == f"backend: {meshemu.backend_label(_screen(j)._backend)}"
    assert tuple(seen) == qw.BACKENDS
    assert _screen(j)._backend == qw.BACKEND_DOCKER          # wrapped round


def test_on_a_mac_the_key_stays_on_docker_and_nothing_on_the_screen_is_windows(
        gen, monkeypatch):
    """A Mac missing Homebrew's GNU tools is refused by the same sentence function as
    the MSI. The screen said "! not from this Windows Studio:", offered the backend
    "QEMU for Windows (WHPX)", and the key went there: a second refusal, pointing back
    at Docker. A Mac has the one backend, and its refusal is the brew line."""
    from hugmesh_studio.core import macos_host
    real = platform_info.host_kind
    monkeypatch.setattr(platform_info, "host_kind",
                        lambda osname=None, sysplatform=None:
                        real(osname, sysplatform or "darwin"))
    monkeypatch.setattr(platform_info, "_GNU_MISSING", ["bash", "gnu-sed", "coreutils"])
    j = _at_table(gen)
    assert _screen(j)._backend == qw.BACKEND_DOCKER
    for _ in range(3):
        j.feed(meshemu.BACKEND_KEY)
        assert _screen(j)._backend == qw.BACKEND_DOCKER
        assert j.status == (f"backend: {qw.DOCKER_LABEL_MACOS} (the only emulation "
                            "backend on this host)")
    for text in ("\n".join(j.lines()), _detail(j, "x86/backend")):
        for word in ("Windows", "WSL", "WHPX", "this PC"):
            assert word not in text, (word, text)
        assert f"{meshemu.BACKEND_KEY} = switch" not in text
        assert "! not on this Mac yet:" in text
        assert macos_host.BREW_INSTALL in text


def test_the_key_is_free_on_this_screen():
    assert meshemu.BACKEND_KEY not in ("q", "r", "") and not meshemu.BACKEND_KEY.isdigit()


def test_docker_stays_the_default_off_native_windows_even_with_qemu_ready(gen, whpx_ready):
    assert _screen(_at_table(gen))._backend == qw.BACKEND_DOCKER


def test_a_native_windows_studio_opens_on_whpx_only_when_it_is_ready(
        gen, windows, monkeypatch, fake_install):
    assert _screen(_at_table(gen))._backend == qw.BACKEND_DOCKER  # no QEMU yet
    dll = os.path.join(os.path.dirname(fake_install.dir), "WinHvPlatform.dll")
    open(dll, "wb").close()
    monkeypatch.setattr(qw, "_WHPX_DLL", dll)
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: fake_install)
    assert _screen(_at_table(gen))._backend == qw.BACKEND_WHPX    # the GUI's rule


def test_the_toggle_and_the_cli_choose_from_the_same_core_ids():
    """The TUI walks qemu_windows.BACKENDS; the CLI the WHPX lines name is the one
    qemu_windows.add_cli_arguments puts on the Studio's parser, and the module form is
    that very module — so every face reaches the same backend by the same id."""
    walked, backend = [], qw.BACKENDS[0][0]
    for _ in qw.BACKENDS:
        walked.append((backend, meshemu.backend_label(backend)))
        backend = meshemu.next_backend(backend)
    assert tuple(walked) == qw.BACKENDS
    studio, module = meshemu.WHPX_CLI_PREFIXES
    ap = argparse.ArgumentParser()
    qw.add_cli_arguments(ap)
    ns = ap.parse_args([studio[1], "status", "--generator-dir", "g"])
    assert ns.qemu_windows == ["status", "--generator-dir", "g"]
    assert module[-1] == qw.__name__


# ── WHPX: an x86 row is the core's preview plus the CLI ─────────────────────────────
def test_an_x86_row_shows_the_core_preview_and_the_cli_lines(gen, windows, whpx_ready):
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    table = "\n".join(j.lines())
    assert f"ready: QEMU for Windows in {whpx_ready.dir}" in table
    assert meshemu.WHPX_ONE_AT_A_TIME in table
    assert "front door" not in table                        # the Docker tunnel's
    text = _detail(j, "x86/backend")
    eplan = _screen(j)._eplan
    opts = qw.options_for_row(_planned(j, "x86/backend"), eplan.work_dir)
    for line in qw.preview_lines(opts, osname="nt"):
        assert "  " + line in text, line
    gen_arg = subprocess.list2cmdline([gen])
    for prefix in ("hugmesh-studio --qemu-windows",
                   "python -m hugmesh_studio.core.qemu_windows"):
        assert (f"{prefix} start --session {SESSION} --row x86/backend "
                f"--generator-dir {gen_arg}") in text
        assert f"{prefix} stop --row x86/backend --generator-dir {gen_arg}" in text
        assert f"{prefix} status --generator-dir {gen_arg}" in text
    assert meshemu.WHPX_ONE_AT_A_TIME in text and meshemu.WHPX_NOT_HERE in text
    # none of the Docker backend's runner verbs
    assert "run-qemu-docker.sh" not in text
    assert "start the WHOLE mesh with:" not in text and "save-mesh" not in text


def test_the_printed_cli_plans_exactly_the_preview_shown(gen, whpx_ready, capsys):
    """The single-author pin for this backend: the args the TUI prints, run through
    qemu_windows' own CLI with ``plan``, print the preview the TUI shows — through the
    module's main and through the Studio's flag alike."""
    eplan = emu.plan(gen, qemu_tests.discover_sessions(gen)[0], emu.EmulationMode.DEPLOY,
                     epoch="")
    planned = next(d for d in eplan.mesh.devices if d.label == "x86/frontend")
    want = "\n".join(qw.preview_lines(qw.options_for_row(planned, eplan.work_dir)))
    args = meshemu.whpx_cli_args(eplan, "start", planned.label)
    args[0] = "plan"
    assert qw.main(args) == 0
    assert capsys.readouterr().out.strip() == want
    assert qw.run_studio_cli(args, "/not/this/checkout") == 0
    assert capsys.readouterr().out.strip() == want


def test_a_custom_work_dir_is_carried_to_the_cli(gen):
    eplan = emu.plan(gen, SESSION, emu.EmulationMode.DEPLOY, work_dir="/elsewhere",
                     epoch="")
    args = meshemu.whpx_cli_args(eplan, "status")
    assert args[args.index("--work") + 1] == os.path.abspath("/elsewhere")
    default = emu.plan(gen, SESSION, emu.EmulationMode.DEPLOY, epoch="")
    assert "--work" not in meshemu.whpx_cli_args(default, "status")


def test_a_relative_generator_dir_is_pasted_absolute(gen, monkeypatch):
    """The pasted line runs in another terminal, whose folder need not be this one."""
    monkeypatch.chdir(os.path.dirname(gen))
    eplan = emu.plan(os.path.basename(gen), SESSION, emu.EmulationMode.DEPLOY,
                     work_dir="runs", epoch="")
    args = meshemu.whpx_cli_args(eplan, "status")
    assert args[args.index("--generator-dir") + 1] == os.path.abspath(gen)
    assert args[args.index("--work") + 1] == os.path.abspath("runs")


def test_an_arm_row_is_its_refusal_and_nothing_to_paste(gen, windows, whpx_ready):
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    platform = _planned(j, "rpi5/pki").platform
    table = "\n".join(j.lines())
    assert f"refused: {qw.row_refusal(platform)}" in table
    text = _detail(j, "rpi5/pki")
    assert "! refused: " + qw.row_refusal(platform) in text
    assert "qemu-system" not in text and "--qemu-windows start" not in text
    assert "--qemu-windows stop" not in text


# ── WHPX: the blocker when it cannot boot ───────────────────────────────────────────
def test_off_windows_whpx_is_its_refusal_alone(gen):
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    why = qw.blocker("posix")
    assert "! not ready: " + why in "\n".join(j.lines())
    text = _detail(j, "x86/backend")
    assert "! not ready: " + why in text
    assert "qemu-system" not in text and "--qemu-windows" not in text


def test_no_qemu_on_windows_names_the_winget_command(gen, windows):
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    assert qw.INSTALL_HINT in "\n".join(j.lines())
    text = _detail(j, "x86/backend")
    assert "! not ready: " in text and qw.INSTALL_HINT in text
    # what to run once it is installed is still on screen, under the sentence
    assert "--qemu-windows start" in text


def test_the_hypervisor_platform_off_names_the_dism_command(gen, windows, monkeypatch,
                                                            fake_install, tmp_path):
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: fake_install)
    monkeypatch.setattr(qw, "_WHPX_DLL", str(tmp_path / "absent.dll"))
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    assert qw.WHPX_HINT in _detail(j, "x86/backend")


# ── WHPX: a running device, one at a time ───────────────────────────────────────────
def test_a_running_device_shows_its_access_and_holds_the_others(gen, windows, whpx_ready,
                                                                live):
    live.append(_rec("x86/backend", display="window"))
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    rows = [ln for ln in j.lines() if "x86/backend" in ln and "127.0.0.1:2222" in ln]
    assert rows and "running" in rows[0]
    text = _detail(j, "x86/backend")
    assert "pid 4321" in text and "desktop window" in text
    assert "https://127.0.0.1:8443/" in text
    assert subprocess.list2cmdline(qw.ssh_argv(live[0], "<user>")) in text
    assert "--qemu-windows stop --row x86/backend" in text
    assert "qemu-system" not in text                         # it is up: no start
    j.feed("q")
    other = _detail(j, "x86/frontend")
    assert ("! x86/backend is running, and this backend runs one device at a time"
            in other)


# ── #637 holds on this backend too ──────────────────────────────────────────────────
from _session_records import write_build_record  # noqa: E402


def test_a_refused_session_shows_no_whpx_start(gen, windows, whpx_ready):
    write_build_record(SESSION, domains=("a.example", "b.example"),
                       reviewed=("hugmesh.net", "a.example"))
    j = _at_table(gen)
    _to(j, qw.BACKEND_WHPX)
    text = _detail(j, "x86/backend")
    assert "! refused: " in text and "b.example" in text
    assert "qemu-system" not in text and "--qemu-windows start" not in text
    assert "--qemu-windows stop" in text and "--qemu-windows status" in text


# ── Docker on native Windows: the WSL2 sentence, not bash argv ─────────────────────
def test_the_docker_backend_on_native_windows_is_the_wsl2_sentence(gen, windows):
    j = _at_table(gen)
    assert _screen(j)._backend == qw.BACKEND_DOCKER          # QEMU is not ready
    blocker = qemu_tests.native_blocker()
    assert blocker and "WSL2" in blocker
    assert blocker in "\n".join(j.lines())
    text = _detail(j, "x86/backend")
    assert blocker in text
    assert f"press {meshemu.BACKEND_KEY} for the backend" in text
    assert meshemu.backend_label(qw.BACKEND_WHPX) in text
    for bash in ("run-qemu-docker.sh", "--only-exact", "--stop-all-devices",
                 "save-mesh"):
        assert bash not in text, bash


def test_the_qemu_screen_says_wsl2_on_native_windows(gen, windows):
    sess = qemu_tests.discover_sessions(gen)[0]
    plan = tui_qemu.plan_for(gen, sess)
    blocker = qemu_tests.native_blocker()
    hint = "\n".join(tui_qemu.run_hint_lines(plan))
    assert blocker in hint and "open Mesh emulation" in hint
    assert "run-qemu-docker.sh" not in hint and tui_qemu.MAKE_TARGET not in hint
    detail = "\n".join(tui_qemu.row_detail_lines(plan, emu.status(plan), plan.labels[0]))
    assert blocker in detail
    assert "--only-exact" not in detail
    assert shlex.join(emu.avc_argv(plan, plan.labels[0])) not in detail


def test_off_windows_neither_screen_carries_the_sentence(gen):
    sess = qemu_tests.discover_sessions(gen)[0]
    plan = tui_qemu.plan_for(gen, sess)
    assert tui_qemu.native_lines() == []
    assert "run-qemu-docker.sh" in "\n".join(tui_qemu.run_hint_lines(plan))
    j = _at_table(gen)
    assert "Windows Studio" not in "\n".join(j.lines())


# ── this screen spawns nothing, on either backend ──────────────────────────────────
def test_the_screen_spawns_nothing(gen, windows, whpx_ready, live, monkeypatch):
    def landmine(*_a, **_k):
        raise AssertionError("the TUI spawned a process")

    for name in ("Popen", "run", "call", "check_call", "check_output"):
        monkeypatch.setattr(subprocess, name, landmine)
    live.append(_rec("x86/frontend"))
    j = _at_table(gen)
    for _ in qw.BACKENDS:
        j.lines()
        for n in range(len(_screen(j)._plan.devices)):
            j.feed(str(n + 1))
            j.lines()
            j.feed("q")
        j.feed(meshemu.BACKEND_KEY)


def test_the_readme_sends_the_operator_to_the_screen_with_the_backend_key():
    """``--meshemu SESSION`` prints the Docker plan and exits; the backend key lives on
    the journey's Mesh emulation screen, and the README must point there."""
    readme = os.path.join(os.path.dirname(__file__), os.pardir, "README.md")
    with open(readme, encoding="utf-8") as fh:
        text = fh.read()
    tui = " ".join(next(item for item in text.split("\n- ")
                        if item.startswith("**TUI:**")).split())
    assert "`python -m hugmesh_studio.tui`" in tui
    assert f"press **{meshemu.BACKEND_KEY}** there" in tui
    # the two picks it names are the journey's own titles
    welcome = dict((cid, title) for cid, title, _ in journey.WELCOME_CHOICES)
    mode = dict((cid, title) for cid, title, _ in journey.MODE_CHOICES)
    assert f"pick **{welcome['build']}**, then the **{mode['meshemu']}** card" in tui
    assert "(`--meshemu SESSION` only prints the Docker plan and exits" in tui
