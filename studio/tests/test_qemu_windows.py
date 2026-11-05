"""core/qemu_windows.py — the QEMU for Windows (WHPX) backend, Qt-free.

Windows is FAKED everywhere (``osname="nt"``, a QemuInstall of empty files under
tmp_path, ``_WHPX_DLL`` pointed at a tmp file, fake popen / qmp / alive), so this
runs the same on the Linux CI job and never needs, finds or starts a real QEMU.
"""
import json
import lzma
import os
import socket
import subprocess

import pytest

from hugmesh_studio.core import qemu_tests
from hugmesh_studio.core import qemu_windows as qw


# ── fakes ────────────────────────────────────────────────────────────────────────────
def _make_install(root, *, firmware="share", img=True):
    """A QEMU folder of empty files; ``firmware`` is "share", "root" or ""."""
    os.makedirs(os.path.join(root, "share"), exist_ok=True)
    open(os.path.join(root, qw.QEMU_EXE), "wb").close()
    if img:
        open(os.path.join(root, qw.QEMU_IMG_EXE), "wb").close()
    fw = {"share": os.path.join(root, "share"), "root": root}.get(firmware)
    if fw:
        with open(os.path.join(fw, qw.CODE_FD), "wb") as fh:
            fh.write(b"code")
        with open(os.path.join(fw, qw.VARS_FD), "wb") as fh:
            fh.write(b"vars")
    return str(root)


@pytest.fixture
def install(tmp_path):
    d = _make_install(str(tmp_path / "qemu"))
    return qw.QemuInstall(d, os.path.join(d, qw.QEMU_EXE), os.path.join(d, qw.QEMU_IMG_EXE),
                          os.path.join(d, "share", qw.CODE_FD),
                          os.path.join(d, "share", qw.VARS_FD))


@pytest.fixture
def whpx_on(tmp_path, monkeypatch):
    dll = tmp_path / "WinHvPlatform.dll"
    dll.write_bytes(b"")
    monkeypatch.setattr(qw, "_WHPX_DLL", str(dll))
    return str(dll)


@pytest.fixture
def no_lookup(monkeypatch):
    """find_qemu sees only what a test puts in env: no registry, nothing on PATH."""
    monkeypatch.setattr(qw, "_registry_dir", lambda: "")
    monkeypatch.setattr(qw.shutil, "which", lambda name: None)


def _opts(tmp_path, **kw):
    image = tmp_path / "thin.img"
    if not image.exists():
        image.write_bytes(b"\0" * 512)
    base = dict(label="x86/standalone-thin", image=str(image), work_dir=str(tmp_path / "work"))
    base.update(kw)
    return qw.NativeOptions(**base)


def _after(argv, flag):
    return [argv[i + 1] for i, a in enumerate(argv) if a == flag]


def _write_record(work_dir, label, **fields):
    # pid and creation time of THIS test process by default: a live, matching record
    rec = {"label": label, "pid": os.getpid(), "started": qw.process_started(os.getpid()),
           "qmp_port": 5555, "ssh_port": 2222,
           "run_dir": os.path.join(work_dir, qw.NATIVE_RUNS_SUBDIR, qw.safe_label(label))}
    rec.update(fields)
    os.makedirs(qw.devices_dir(work_dir), exist_ok=True)
    with open(qw._record_path(work_dir, label), "w", encoding="utf-8") as fh:
        json.dump(rec, fh)
    return rec


class _Proc:
    def __init__(self, pid=4242, code=None):
        self.pid, self.returncode = pid, code

    def poll(self):
        return self.returncode


def _never_popen(*a, **kw):
    raise AssertionError("a refused start must not launch QEMU")


# ── find_qemu ────────────────────────────────────────────────────────────────────────
def test_find_qemu_prefers_the_registry_folder(tmp_path, monkeypatch):
    reg = _make_install(str(tmp_path / "reg"))
    _make_install(str(tmp_path / "pf" / "qemu"))
    monkeypatch.setattr(qw, "_registry_dir", lambda: reg)
    monkeypatch.setattr(qw.shutil, "which", lambda name: None)
    inst = qw.find_qemu({"ProgramFiles": str(tmp_path / "pf")})
    assert inst.dir == reg
    assert inst.code_fd == os.path.join(reg, "share", qw.CODE_FD)


def test_find_qemu_program_files(tmp_path, no_lookup):
    d = _make_install(str(tmp_path / "pf" / "qemu"))
    inst = qw.find_qemu({"ProgramFiles": str(tmp_path / "pf")})
    assert inst == qw.QemuInstall(d, os.path.join(d, qw.QEMU_EXE),
                                  os.path.join(d, qw.QEMU_IMG_EXE),
                                  os.path.join(d, "share", qw.CODE_FD),
                                  os.path.join(d, "share", qw.VARS_FD))


def test_find_qemu_on_path(tmp_path, monkeypatch):
    d = _make_install(str(tmp_path / "onpath"))
    monkeypatch.setattr(qw, "_registry_dir", lambda: "")
    monkeypatch.setattr(qw.shutil, "which",
                        lambda name: os.path.join(d, qw.QEMU_EXE) if "qemu" in name else None)
    assert qw.find_qemu({"ProgramFiles": str(tmp_path / "nothing")}).dir == d


def test_find_qemu_root_firmware_of_an_older_build(tmp_path, no_lookup):
    d = _make_install(str(tmp_path / "pf" / "qemu"), firmware="root")
    inst = qw.find_qemu({"ProgramFiles": str(tmp_path / "pf")})
    assert inst.code_fd == os.path.join(d, qw.CODE_FD)
    assert inst.vars_fd == os.path.join(d, qw.VARS_FD)


def test_find_qemu_needs_img_and_firmware(tmp_path, no_lookup):
    env = {"ProgramFiles": str(tmp_path / "pf")}
    _make_install(str(tmp_path / "pf" / "qemu"), firmware="")
    assert qw.find_qemu(env) is None
    _make_install(str(tmp_path / "pf2" / "qemu"), img=False)
    assert qw.find_qemu({"ProgramFiles": str(tmp_path / "pf2")}) is None


# ── blocker / row_refusal ────────────────────────────────────────────────────────────
def test_blocker_off_windows_points_at_docker(install):
    why = qw.blocker("posix", install=install)
    assert "Docker backend" in why and "Windows Studio" in why


def test_blocker_not_installed_gives_the_winget_command():
    why = qw.blocker("nt", install=False)
    assert "not installed" in why and qw.INSTALL_HINT in why
    assert "winget install --id SoftwareFreedomConservancy.QEMU -e" in why


def test_blocker_whpx_off_gives_the_dism_command(tmp_path, install):
    why = qw.blocker("nt", install=install, whpx_dll=str(tmp_path / "missing.dll"))
    assert "Windows Hypervisor Platform is off" in why
    assert "/FeatureName:HypervisorPlatform" in why


def test_blocker_reads_the_module_dll_path(tmp_path, monkeypatch, install):
    monkeypatch.setattr(qw, "_WHPX_DLL", str(tmp_path / "missing.dll"))
    assert "Hypervisor Platform" in qw.blocker("nt", install=install)


def test_blocker_tcg_skips_the_dll_check(tmp_path, install):
    assert qw.blocker("nt", install=install, whpx_dll=str(tmp_path / "missing.dll"),
                      accel="tcg") == ""


def test_blocker_ready(install, whpx_on):
    assert qw.blocker("nt", install=install) == ""


def test_row_refusal_x86_only():
    assert qw.row_refusal("x86") == ""
    for platform in ("rpi5", "aarch64"):
        why = qw.row_refusal(platform)
        assert why.startswith(f"{platform} images cannot boot on QEMU for Windows")
        assert "only x86_64 guests" in why and "Docker backend in WSL2" in why


def test_options_for_row(tmp_path):
    row = qemu_tests.DeviceRow(platform="x86", arch="amd64", role="standalone-thin",
                               env="", image=str(tmp_path / "a.img"))
    o = qw.options_for_row(row, str(tmp_path), mem_mb=1024)
    assert (o.label, o.platform, o.role, o.mem_mb) == ("x86/standalone-thin", "x86",
                                                       "standalone-thin", 1024)
    arm = qemu_tests.DeviceRow(platform="rpi5", arch="arm64", role="node", env="",
                               image=str(tmp_path / "b.img"))
    with pytest.raises(qw.NativeError, match="rpi5 images cannot boot"):
        qw.options_for_row(arm, str(tmp_path))


# ── argv (pure) ──────────────────────────────────────────────────────────────────────
def test_launch_argv_headless(tmp_path, install):
    o = _opts(tmp_path)
    rd = qw.run_dir(o)
    argv = qw.launch_argv(o, install, 4711)
    assert argv[0] == install.system
    assert _after(argv, "-machine") == ["q35"]
    assert _after(argv, "-accel") == ["whpx"]
    assert _after(argv, "-cpu") == ["Nehalem"]          # x86-64-v2, not qemu64
    assert _after(argv, "-m") == ["2048"] and _after(argv, "-smp") == ["2"]
    assert "-no-reboot" in argv
    assert _after(argv, "-drive") == [
        f"if=pflash,format=raw,readonly=on,file={install.code_fd}",
        f"if=pflash,format=raw,file={os.path.join(rd, 'vars.fd')}",
        f"file={os.path.join(rd, 'run.qcow2')},format=qcow2,if=none,id=hd0"]
    assert _after(argv, "-netdev") == [
        "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8443-:443,"
        "hostfwd=tcp:127.0.0.1:8080-:80"]
    assert _after(argv, "-qmp") == ["tcp:127.0.0.1:4711,server=on,wait=off"]
    assert _after(argv, "-serial") == [f"file:{os.path.join(rd, 'console.log')}"]
    assert _after(argv, "-pidfile") == [os.path.join(rd, "qemu.pid")]
    assert _after(argv, "-display") == ["none"]
    assert "virtio-gpu-pci" not in argv
    assert "-kernel" not in argv and "-daemonize" not in argv


def test_launch_argv_window_and_tcg(tmp_path, install):
    o = _opts(tmp_path, display="window", accel="tcg", ssh_port=2300, mem_mb=1024)
    argv = qw.launch_argv(o, install, 1)
    assert _after(argv, "-display") == ["sdl"]
    assert "virtio-gpu-pci" in _after(argv, "-device")
    assert _after(argv, "-accel") == ["tcg"] and _after(argv, "-m") == ["1024"]
    assert _after(argv, "-cpu") == ["max"]              # launch-x86.sh's TCG model
    assert "hostfwd=tcp:127.0.0.1:2300-:22" in _after(argv, "-netdev")[0]


def test_relative_paths_are_made_absolute_once(tmp_path, monkeypatch, install):
    """QEMU runs with the run dir as cwd and qemu-img reads -b against the overlay's
    folder: a relative --work or image must never reach either."""
    monkeypatch.chdir(tmp_path)
    o = qw.NativeOptions(label="x86/thin", image="thin.img.xz", work_dir="runs")
    assert o.work_dir == str(tmp_path / "runs") and o.image == str(tmp_path / "thin.img.xz")
    assert qw.run_dir(o) == os.path.join(str(tmp_path), "runs", qw.NATIVE_RUNS_SUBDIR,
                                         "x86_thin")
    assert os.path.isabs(qw.base_image(o))
    assert all(os.path.isabs(p.split("file=")[-1].split(",")[0])
               for p in _after(qw.launch_argv(o, install, 1), "-drive"))
    ns = qw._parser("t").parse_args(["status", "--work", "runs"])
    assert qw._work(ns) == str(tmp_path / "runs")
    ns = qw._parser("t").parse_args(["status", "--generator-dir", "."])
    assert qw._work(ns) == os.path.join(str(tmp_path), "out", "qemu-runs")


def test_launch_argv_doubles_commas_in_paths(tmp_path):
    d = str(tmp_path / "q,emu")
    inst = qw.QemuInstall(d, os.path.join(d, qw.QEMU_EXE), os.path.join(d, qw.QEMU_IMG_EXE),
                          os.path.join(d, qw.CODE_FD), os.path.join(d, qw.VARS_FD))
    o = _opts(tmp_path, work_dir=str(tmp_path / "w,ork"))
    drives = _after(qw.launch_argv(o, inst, 1), "-drive")
    assert drives[0].endswith("file=" + os.path.join(d, qw.CODE_FD).replace(",", ",,"))
    assert os.path.join(qw.run_dir(o), "run.qcow2").replace(",", ",,") in drives[2]
    assert all(",," in x for x in drives)


def test_prepare_argvs(tmp_path, install):
    o = _opts(tmp_path, overlay_size="16G")
    overlay = os.path.join(qw.run_dir(o), "run.qcow2")
    assert qw.prepare_argvs(o, install) == [
        [install.img, "create", "-q", "-f", "qcow2", "-b", o.image, "-F", "raw", overlay],
        [install.img, "resize", "-q", overlay, "16G"]]


def test_preview_lines_unpacks_an_xz_first(tmp_path, install):
    o = _opts(tmp_path, image=str(tmp_path / "thin.img.xz"))
    base = os.path.join(o.work_dir, qw.NATIVE_IMAGES_SUBDIR, "thin.img")
    assert qw.base_image(o) == base
    lines = qw.preview_lines(o, install, qmp_port=4444, osname="posix")
    assert lines[0] == f"# unpack once: {o.image} -> {base}"
    assert "-b" in lines[1] and base in lines[1] and "-F raw" in lines[1]
    assert lines[3].startswith("# copy ")
    assert "-accel whpx -cpu Nehalem" in lines[4] and "tcp:127.0.0.1:4444" in lines[4]
    plain = qw.preview_lines(_opts(tmp_path), install, osname="posix")
    assert not plain[0].startswith("# unpack") and len(plain) == 4


# ── host checks ──────────────────────────────────────────────────────────────────────
def test_memory_refusal_maths():
    assert qw.memory_refusal(2048, None) == ""
    assert qw.memory_refusal(2048, 2048 + qw.HOST_RESERVE_MB) == ""
    why = qw.memory_refusal(2048, 2048 + qw.HOST_RESERVE_MB - 1)
    assert why.startswith(f"Only {2048 + qw.HOST_RESERVE_MB - 1} MiB of memory is free")
    assert "needs 2048 MiB" in why and f"{qw.HOST_RESERVE_MB} MiB for Windows" in why


# ── registry ─────────────────────────────────────────────────────────────────────────
def test_running_ignores_dead_pids_and_junk(tmp_path):
    work = str(tmp_path)
    _write_record(work, "x86/a", pid=101)
    _write_record(work, "x86/b", pid=202)
    with open(os.path.join(qw.devices_dir(work), "junk.json"), "w") as fh:
        fh.write("{not json")
    with open(os.path.join(qw.devices_dir(work), "nopid.json"), "w") as fh:
        json.dump({"label": "x86/c"}, fh)
    assert [r["label"] for r in qw.records(work)] == ["x86/a", "x86/b"]
    assert [r["label"] for r in qw.running(work, alive=lambda rec: rec["pid"] == 202)] == \
        ["x86/b"]
    assert qw.running(str(tmp_path / "none")) == []


def test_process_started_names_this_process():
    if os.name == "nt" or os.path.isdir("/proc"):
        assert qw.process_started(os.getpid()) is not None
    assert qw.process_started(0) is None


def test_a_reused_pid_is_not_the_recorded_qemu(tmp_path):
    """Windows hands a dead QEMU's pid on quickly: the record is bound to the creation
    time too, so another process at that pid is not 'running'."""
    work = str(tmp_path)
    rec = _write_record(work, "x86/thin", pid=77, started=1000)
    assert qw.record_alive(rec, alive=lambda pid: True, started=lambda pid: 1000)
    assert not qw.record_alive(rec, alive=lambda pid: True, started=lambda pid: 2000)
    assert not qw.record_alive(rec, alive=lambda pid: True, started=lambda pid: None)
    assert not qw.record_alive(dict(rec, started=None), alive=lambda pid: True,
                               started=lambda pid: None)
    assert not qw.record_alive(rec, alive=lambda pid: False, started=lambda pid: 1000)
    # this test's own (live) pid under another creation time: not this record's QEMU
    _write_record(work, "x86/stale", started=-1)
    assert qw.running(work) == []


# ── start() refusals, in order ───────────────────────────────────────────────────────
@pytest.fixture
def ports_free(monkeypatch):
    monkeypatch.setattr(qw, "_port_free", lambda port: True)


def _start(o, install, **kw):
    base = dict(install=install, osname="nt", free_mb=lambda: 100_000, popen=_never_popen,
                settle_s=0, on_line=lambda line: None)
    base.update(kw)
    return qw.start(o, **base)


def test_start_refuses_off_windows_first(tmp_path, install, whpx_on):
    o = _opts(tmp_path, platform="rpi5", image=str(tmp_path / "missing.img"))
    _write_record(o.work_dir, "x86/other")
    with pytest.raises(qw.NativeError, match="Docker backend"):
        _start(o, install, osname="posix", free_mb=lambda: 1)


def test_start_refuses_an_arm_row_next(tmp_path, install, whpx_on):
    o = _opts(tmp_path, platform="rpi5", image=str(tmp_path / "missing.img"))
    _write_record(o.work_dir, "x86/other")
    with pytest.raises(qw.NativeError, match="rpi5 images cannot boot"):
        _start(o, install, free_mb=lambda: 1)


def test_start_runs_one_device_at_a_time(tmp_path, install, whpx_on):
    o = _opts(tmp_path, image=str(tmp_path / "missing.img"))
    _write_record(o.work_dir, "x86/other")            # our own pid: alive
    with pytest.raises(qw.NativeError, match="x86/other is already running. This "
                                             "backend runs one device at a time"):
        _start(o, install, free_mb=lambda: 1)


def test_start_refuses_short_memory(tmp_path, install, whpx_on):
    o = _opts(tmp_path, image=str(tmp_path / "missing.img"))
    _write_record(o.work_dir, "x86/other", pid=0)     # a dead record does not count
    with pytest.raises(qw.NativeError, match="Only 1000 MiB of memory is free"):
        _start(o, install, free_mb=lambda: 1000)


def test_start_refuses_a_busy_port(tmp_path, install, whpx_on):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        busy = s.getsockname()[1]
        o = _opts(tmp_path, image=str(tmp_path / "missing.img"), ssh_port=busy)
        with pytest.raises(qw.NativeError, match=f"Port {busy} on 127.0.0.1 is in use: "
                                                 f"free it, or choose other ports with "
                                                 f"the CLI's --ssh-port"):
            _start(o, install)


def test_start_refuses_a_missing_image(tmp_path, install, whpx_on, ports_free):
    o = _opts(tmp_path, image=str(tmp_path / "missing.img"))
    with pytest.raises(qw.NativeError, match="does not exist"):
        _start(o, install)


def test_start_refuses_unknown_display(tmp_path, install, whpx_on, ports_free):
    with pytest.raises(qw.NativeError, match="Unknown accel"):
        _start(_opts(tmp_path, display="vnc"), install)


# ── start() success / failure ────────────────────────────────────────────────────────
@pytest.fixture
def quiet_img(monkeypatch):
    ran = []
    monkeypatch.setattr(qw, "_run_quiet", ran.append)
    return ran


def test_start_writes_the_record(tmp_path, install, whpx_on, ports_free, quiet_img):
    o = _opts(tmp_path)
    calls, lines = [], []

    def popen(argv, **kw):
        calls.append((argv, kw))
        return _Proc()

    rec = _start(o, install, popen=popen, on_line=lines.append)
    rd = qw.run_dir(o)
    assert quiet_img == qw.prepare_argvs(o, install)
    with open(os.path.join(rd, "vars.fd"), "rb") as fh:
        assert fh.read() == b"vars"
    (argv, kw), = calls
    assert argv == qw.launch_argv(o, install, rec["qmp_port"])
    assert kw["cwd"] == rd and kw["stdin"] == subprocess.DEVNULL
    assert kw["creationflags"] & 0x08000000             # headless: no console window
    assert rec["pid"] == 4242 and rec["backend"] == qw.BACKEND_WHPX
    assert "started" in rec                             # the pid's creation time
    assert (rec["label"], rec["ssh_port"], rec["run_dir"]) == (o.label, 2222, rd)
    assert qw.records(o.work_dir) == [rec]
    assert lines[-1].startswith("Started x86/standalone-thin: ssh -p 2222")


def test_a_window_start_gets_no_console_either(tmp_path, install, whpx_on, ports_free,
                                              quiet_img):
    """QEMU is a console program: without CREATE_NO_WINDOW the windowed Studio opens an
    empty console beside the SDL window, and closing it kills the guest."""
    calls = []
    _start(_opts(tmp_path, display="window"), install,
           popen=lambda argv, **kw: calls.append(kw) or _Proc())
    (kw,) = calls
    assert kw["creationflags"] & 0x08000000 and kw["creationflags"] & 0x200


def test_the_record_is_bound_to_the_started_process(tmp_path, install, whpx_on,
                                                     ports_free, quiet_img, monkeypatch):
    monkeypatch.setattr(qw, "process_started", lambda pid: 123456 if pid == 4242 else None)
    rec = _start(_opts(tmp_path), install, popen=lambda argv, **kw: _Proc())
    assert rec["started"] == 123456


def test_a_second_start_in_progress_is_refused(tmp_path, install, whpx_on, ports_free):
    """The slot is claimed before the slow steps, so two faces starting at once cannot
    both pass the one-device and free-memory checks."""
    o = _opts(tmp_path)
    os.makedirs(qw.devices_dir(o.work_dir))
    claim = os.path.join(qw.devices_dir(o.work_dir), qw._START_CLAIM)
    with open(claim, "w", encoding="utf-8") as fh:        # this live test process
        json.dump({"pid": os.getpid(), "started": qw.process_started(os.getpid())}, fh)
    with pytest.raises(qw.NativeError, match="Another QEMU for Windows start is in "
                                             "progress"):
        _start(o, install)
    assert os.path.isfile(claim)                          # not ours to remove


def test_a_stale_claim_is_taken_over_and_released(tmp_path, install, whpx_on, ports_free,
                                                  quiet_img, monkeypatch):
    o = _opts(tmp_path)
    os.makedirs(qw.devices_dir(o.work_dir))
    claim = os.path.join(qw.devices_dir(o.work_dir), qw._START_CLAIM)
    with open(claim, "w", encoding="utf-8") as fh:        # a start that died
        json.dump({"pid": 0, "started": None}, fh)
    seen = []

    def popen(argv, **kw):
        with open(claim, encoding="utf-8") as fh:         # held during the start
            seen.append(json.load(fh)["pid"])
        return _Proc()

    _start(o, install, popen=popen)
    assert seen == [os.getpid()] and not os.path.exists(claim)
    os.remove(qw._record_path(o.work_dir, o.label))       # fake pid 4242 may be real
    with pytest.raises(qw.NativeError, match="does not exist"):
        _start(_opts(tmp_path, image=str(tmp_path / "missing.img")), install)
    assert not os.path.exists(claim)                      # a refusal releases it too


def test_an_interrupted_settle_leaves_a_record_stop_can_use(tmp_path, install, whpx_on,
                                                            ports_free, quiet_img,
                                                            monkeypatch):
    """Ctrl+C on the CLI does not reach QEMU's own process group: the device must be
    recorded before the settle, or nothing could stop it."""
    def interrupt(_s):
        raise KeyboardInterrupt

    monkeypatch.setattr(qw.time, "sleep", interrupt)
    o = _opts(tmp_path)
    with pytest.raises(KeyboardInterrupt):
        _start(o, install, popen=lambda argv, **kw: _Proc(), settle_s=5)
    assert [r["pid"] for r in qw.records(o.work_dir)] == [4242]
    assert not os.path.exists(os.path.join(qw.devices_dir(o.work_dir), qw._START_CLAIM))


def test_start_unpacks_an_xz_once(tmp_path, install, whpx_on, ports_free, quiet_img):
    xz = tmp_path / "thin.img.xz"
    with lzma.open(str(xz), "wb") as fh:
        fh.write(b"raw disk")
    o = _opts(tmp_path, image=str(xz))
    _start(o, install, popen=lambda argv, **kw: _Proc())
    with open(qw.base_image(o), "rb") as fh:
        assert fh.read() == b"raw disk"
    assert quiet_img[0][quiet_img[0].index("-b") + 1] == qw.base_image(o)


def test_a_failed_unpack_leaves_no_part_file(tmp_path, monkeypatch):
    src = tmp_path / "thin.img.xz"
    src.write_bytes(b"not xz at all")
    dst = str(tmp_path / "imgs" / "thin.img")
    with pytest.raises(qw.NativeError, match="thin.img.xz could not be unpacked into"):
        qw._unpack(str(src), dst, lambda line: None)
    assert os.listdir(os.path.dirname(dst)) == []

    with lzma.open(str(src), "wb") as fh:
        fh.write(b"raw disk")

    def full_disk(fin, fout, size):
        fout.write(b"part")
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(qw.shutil, "copyfileobj", full_disk)
    with pytest.raises(qw.NativeError, match="No space left on device"):
        qw._unpack(str(src), dst, lambda line: None)
    assert os.listdir(os.path.dirname(dst)) == []

    def interrupted(fin, fout, size):
        fout.write(b"part")
        raise KeyboardInterrupt

    monkeypatch.setattr(qw.shutil, "copyfileobj", interrupted)
    with pytest.raises(KeyboardInterrupt):
        qw._unpack(str(src), dst, lambda line: None)
    assert os.listdir(os.path.dirname(dst)) == []


def test_start_reports_a_qemu_that_exits_at_once(tmp_path, install, whpx_on, ports_free,
                                                 quiet_img):
    def popen(argv, **kw):
        kw["stdout"].write(b"qemu-system-x86_64.exe: WHPX: No accelerator found\n")
        return _Proc(code=1)

    o = _opts(tmp_path)
    with pytest.raises(qw.NativeError, match=r"QEMU stopped at once \(exit 1\): .*"
                                             r"No accelerator found"):
        _start(o, install, popen=popen)
    assert qw.records(o.work_dir) == []


def test_start_reports_a_popen_oserror(tmp_path, install, whpx_on, ports_free, quiet_img):
    def popen(argv, **kw):
        raise OSError("no such file")

    with pytest.raises(qw.NativeError, match="QEMU could not be started: no such file"):
        _start(_opts(tmp_path), install, popen=popen)


def test_run_quiet_raises_the_tool_output(monkeypatch):
    monkeypatch.setattr(qw.subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(
        argv, 1, stdout="", stderr="Could not open 'x.img'\n"))
    with pytest.raises(qw.NativeError, match="qemu-img.exe failed: Could not open 'x.img'"):
        qw._run_quiet([r"C:\qemu\qemu-img.exe", "create"])


# ── stop() ───────────────────────────────────────────────────────────────────────────
@pytest.fixture
def no_sleep(monkeypatch):
    monkeypatch.setattr(qw.time, "sleep", lambda s: None)


def _stoppable(tmp_path, **fields):
    work = str(tmp_path / "work")
    rec = _write_record(work, "x86/thin", pid=77, **fields)
    os.makedirs(rec["run_dir"], exist_ok=True)
    return work, rec


def test_stop_powers_off_and_cleans_up(tmp_path, no_sleep):
    work, rec = _stoppable(tmp_path)
    state, asked = {"alive": True}, []

    def ask(port, cmd):
        asked.append((port, cmd))
        state["alive"] = False
        return {"return": {}}

    assert qw.stop(work, "x86/thin", alive=lambda pid: state["alive"], ask=ask) == \
        "x86/thin: powered off."
    assert asked == [(5555, "system_powerdown")]
    assert qw.records(work) == []
    assert not os.path.exists(rec["run_dir"])


def test_stop_keep_leaves_the_run_dir(tmp_path, no_sleep):
    work, rec = _stoppable(tmp_path, keep=True)
    assert qw.stop(work, "x86/thin", alive=lambda pid: False) == "x86/thin: was not running."
    assert os.path.isdir(rec["run_dir"]) and qw.records(work) == []


def test_stop_quits_when_power_off_is_ignored(tmp_path, no_sleep):
    work, _ = _stoppable(tmp_path)
    state, asked = {"alive": True}, []

    def ask(port, cmd):
        asked.append(cmd)
        if cmd == "quit":
            state["alive"] = False

    assert qw.stop(work, "x86/thin", timeout_s=0, alive=lambda pid: state["alive"],
                   ask=ask) == "x86/thin: quit (it did not power off in time)."
    assert asked == ["system_powerdown", "quit"]


def test_stop_kills_when_qmp_does_not_answer(tmp_path, monkeypatch, no_sleep):
    work, _ = _stoppable(tmp_path)
    state, killed = {"alive": True}, []

    def kill(pid):
        killed.append(pid)
        state["alive"] = False

    def ask(port, cmd):
        raise ConnectionRefusedError("refused")

    monkeypatch.setattr(qw, "_kill", kill)
    assert qw.stop(work, "x86/thin", alive=lambda pid: state["alive"], ask=ask) == \
        "x86/thin: killed (QMP did not answer)."
    assert killed == [77] and qw.records(work) == []


def test_stop_kills_when_quit_is_ignored(tmp_path, monkeypatch, no_sleep):
    work, _ = _stoppable(tmp_path)
    killed = []
    monkeypatch.setattr(qw, "_kill", killed.append)
    assert qw.stop(work, "x86/thin", timeout_s=0, alive=lambda pid: not killed,
                   ask=lambda port, cmd: None) == "x86/thin: killed."
    assert killed == [77]


def test_stop_never_kills_a_process_that_reused_the_pid(tmp_path, monkeypatch, no_sleep):
    """The guest powered itself off and Windows gave its pid to another program: Stop
    removes the record and asks or kills nothing."""
    work, rec = _stoppable(tmp_path, started=1000)
    monkeypatch.setattr(qw, "pid_alive", lambda pid: True)
    monkeypatch.setattr(qw, "process_started", lambda pid: 2000)
    monkeypatch.setattr(qw, "_kill", lambda pid: pytest.fail("killed an unrelated pid"))

    def ask(port, cmd):
        pytest.fail("asked an unrelated process's port")

    assert qw.stop(work, "x86/thin", alive=lambda r: qw.record_alive(
        r, alive=qw.pid_alive, started=qw.process_started), ask=ask) == \
        "x86/thin: was not running."
    assert qw.records(work) == [] and not os.path.exists(rec["run_dir"])


def test_kill_is_not_a_tree_kill(monkeypatch):
    ran = []
    monkeypatch.setattr(qw.subprocess, "run", lambda argv, **kw: ran.append(argv))
    qw._kill(4242, osname="nt")
    assert ran == [["taskkill", "/PID", "4242", "/F"]]


def test_stop_unknown_device(tmp_path):
    with pytest.raises(qw.NativeError, match="No QEMU for Windows device named x86/nope"):
        qw.stop(str(tmp_path), "x86/nope")


def test_ssh_argv():
    assert qw.ssh_argv({"ssh_port": 2222}, "admin")[:3] == ["ssh", "-p", "2222"]
    assert qw.ssh_argv({"ssh_port": 2222}, "admin")[-1] == "admin@127.0.0.1"


# ── CLI ─────────────────────────────────────────────────────────────────────────────
def _cli(*argv):
    return qw.run_cli(qw._parser("test").parse_args(list(argv)))


def test_cli_check_ready_and_refused(monkeypatch, capsys, install):
    asked = []
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: install)
    monkeypatch.setattr(qw, "blocker", lambda accel="whpx": asked.append(accel) or "")
    assert _cli("check") == 0
    assert capsys.readouterr().out.strip() == f"Ready: {install.system} with WHPX."
    assert _cli("check", "--tcg") == 0
    assert "with TCG (no acceleration)." in capsys.readouterr().out
    assert asked == ["whpx", "tcg"]
    monkeypatch.setattr(qw, "blocker", lambda accel="whpx": "QEMU for Windows is not installed")
    assert _cli("check") == 2
    assert "not installed" in capsys.readouterr().out


def test_cli_plan_prints_the_preview(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(qw, "find_qemu", lambda env=None: None)    # the placeholder
    img = tmp_path / "standalone-thin.img.xz"
    assert _cli("plan", "--img", str(img), "--work", str(tmp_path / "w"), "--window") == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0].startswith("# unpack once: ")
    assert "-accel whpx" in out[-1] and "virtio-gpu-pci" in out[-1]
    assert "x86_standalone-thin" in out[-1]                         # the --img label


def test_cli_plan_needs_a_source(capsys):
    assert _cli("plan") == 2
    assert "REFUSED: Give --session (and --row) or --img." in capsys.readouterr().err


def test_cli_rows_unknown_session_is_a_sentence(tmp_path, capsys):
    assert _cli("rows", "--generator-dir", str(tmp_path), "--session", "nope") == 2
    assert "REFUSED: no such build session" in capsys.readouterr().err


def test_cli_start_maps_the_options(tmp_path, monkeypatch, capsys):
    seen = []
    monkeypatch.setattr(qw, "start", lambda o: seen.append(o) or {"label": o.label})
    img = tmp_path / "thin.img"
    assert _cli("start", "--img", str(img), "--work", str(tmp_path), "--mem", "1024",
                "--smp", "1", "--tcg", "--keep", "--ssh-port", "2300", "--json") == 0
    (o,) = seen
    assert (o.label, o.image, o.work_dir) == ("x86/thin", str(img), str(tmp_path))
    assert (o.mem_mb, o.smp, o.accel, o.display, o.keep, o.ssh_port) == \
        (1024, 1, "tcg", "none", True, 2300)
    assert json.loads(capsys.readouterr().out) == {"label": "x86/thin"}


def test_cli_start_words_an_oserror_as_a_refusal(tmp_path, monkeypatch, capsys):
    def full(o):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(qw, "start", full)
    assert _cli("start", "--img", str(tmp_path / "thin.img")) == 2
    err = capsys.readouterr().err
    assert "REFUSED: [Errno 28] No space left on device" in err and "Traceback" not in err
    monkeypatch.setattr(qw, "start", lambda o: (_ for _ in ()).throw(
        subprocess.TimeoutExpired(["taskkill"], 30)))
    assert _cli("start", "--img", str(tmp_path / "thin.img")) == 2
    assert "REFUSED: Command '['taskkill']' timed out" in capsys.readouterr().err


def test_cli_status(tmp_path, capsys):
    work = str(tmp_path)
    assert _cli("status", "--work", work) == 0
    assert capsys.readouterr().out.strip() == "no device running"
    _write_record(work, "x86/thin")                     # our own pid: alive
    _write_record(work, "x86/dead", pid=0)
    assert _cli("status", "--work", work) == 0
    assert capsys.readouterr().out.strip() == \
        f"x86/thin\trunning (pid {os.getpid()}, ssh 127.0.0.1:2222)"
    assert _cli("status", "--work", work, "--json") == 0
    assert [r["label"] for r in json.loads(capsys.readouterr().out)] == ["x86/thin"]


def test_cli_stop(tmp_path, monkeypatch, capsys):
    work = str(tmp_path)
    real = qw.stop
    monkeypatch.setattr(qw, "stop", lambda w, label: real(w, label, alive=lambda pid: False))
    assert _cli("stop", "--work", work) == 2
    assert "Give --row LABEL" in capsys.readouterr().err
    assert _cli("stop", "--work", work, "--row", "x86/thin") == 2
    assert "No QEMU for Windows device named x86/thin" in capsys.readouterr().err
    _write_record(work, "x86/thin", pid=77)
    assert _cli("stop", "--work", work, "--row", "x86/thin") == 0
    assert capsys.readouterr().out.strip() == "x86/thin: was not running."
    assert qw.records(work) == []
