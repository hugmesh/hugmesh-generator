"""core/open_path — opening a folder is VERIFIED, never assumed (issue #689).

Every mechanism a desktop offers reports "dispatched", not "a window appeared".
These tests drive :func:`open_folder` through an injected :class:`Host` (no
subprocess, no desktop) and pin the one contract the GUI relies on: a failed
dispatch is never reported as opened, and a dispatch nothing can confirm is
reported as opened-but-unverified, with a reason. Qt-free.
"""
import os

import pytest

from hugmesh_studio.core import open_path as op


class FakeHost:
    """A recording Host: ``installed`` names the executables ``which`` finds,
    ``exits`` maps argv[0] -> exit code (None = still running), ``outputs`` maps
    argv[0] -> stdout for a captured run."""

    def __init__(self, kind, installed=(), exits=None, outputs=None, startfile=None,
                 wsl_distro=""):
        self.kind = kind
        self.installed = set(installed)
        self.exits = dict(exits or {})
        self.outputs = dict(outputs or {})
        self.startfile = startfile
        self.wsl_distro = wsl_distro
        self.environ = {}
        self.calls = []
        self.waits = []
        #: seconds of a fake clock each still-running call burns (see _clock below)
        self.burn = 0.0
        self.clock = None

    def which(self, name):
        return f"/usr/bin/{name}" if name in self.installed else None

    def run(self, argv, capture, wait_s):
        self.calls.append(list(argv))
        self.waits.append(wait_s)
        tool = os.path.basename(argv[0])
        code = self.exits.get(tool, 1)
        if code is None and self.clock is not None:
            self.clock[0] += wait_s            # a still-running opener spends the wait
        return code, self.outputs.get(tool, "")


@pytest.fixture
def folder(tmp_path):
    d = tmp_path / "hugmesh-gateway"
    d.mkdir()
    return str(d)


# ── Linux ───────────────────────────────────────────────────────────────────────
def test_xdg_open_exit_0_is_a_verified_open(folder):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open", "gio"], exits={"xdg-open": 0})
    res = op.open_folder(folder, host=host)
    assert (res.opened, res.verified) == (True, True)
    assert res.how.startswith("xdg-open")
    assert res.reason == ""
    assert res.path == folder
    assert host.calls == [["/usr/bin/xdg-open", folder]]       # gio never needed


def test_xdg_open_exit_2_falls_through_to_gio(folder):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open", "gio"],
                    exits={"xdg-open": 2, "gio": 0})
    res = op.open_folder(folder, host=host)
    assert (res.opened, res.verified) == (True, True)
    assert res.how.startswith("gio")
    assert host.calls == [["/usr/bin/xdg-open", folder], ["/usr/bin/gio", "open", folder]]


def test_every_cli_opener_failing_reaches_the_last_resort_as_unverified(folder):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open", "gio"],
                    exits={"xdg-open": 2, "gio": 4})
    seen = []
    res = op.open_folder(folder, last_resort=lambda p: seen.append(p) or True, host=host)
    assert seen == [folder]
    assert res.opened is True
    assert res.verified is False, "a desktop-portal True is dispatch, not display"
    assert "QDesktopServices" in res.how
    assert "copy the path" in res.reason


def test_no_handler_at_all_is_reported_not_opened_with_every_attempt_named(folder):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": 2})
    res = op.open_folder(folder, last_resort=lambda p: False, host=host)
    assert res.opened is False and res.verified is False
    assert "xdg-open exited 2" in res.reason
    assert "gio is not installed" in res.reason
    assert "desktop fallback declined" in res.reason
    assert res.summary().startswith("could not open")


def test_nothing_installed_and_no_last_resort(folder):
    host = FakeHost(op.HOST_LINUX)
    res = op.open_folder(folder, host=host)
    assert res.opened is False
    assert "xdg-open is not installed" in res.reason
    assert host.calls == []


def test_an_opener_still_running_after_the_grace_is_asked_but_not_verified(folder):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": None})
    res = op.open_folder(folder, host=host)
    assert res.opened is True
    assert res.verified is False, "a running opener confirmed nothing"
    assert "still running" in res.how
    assert "nothing confirmed a window" in res.reason
    assert "copy the path" in res.reason
    assert host.waits == [op.OPENER_WAIT_S]


def test_a_zero_wait_hands_the_request_over_and_says_it_did_not_wait(folder):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": None})
    res = op.open_folder(folder, host=host, wait_s=0)
    assert (res.opened, res.verified) == (True, False)
    assert "not waited for" in res.how
    assert host.waits == [0]


def test_a_last_resort_that_raises_cannot_break_the_click(folder):
    def boom(_p):
        raise RuntimeError("portal down")
    host = FakeHost(op.HOST_LINUX)
    res = op.open_folder(folder, last_resort=boom, host=host)
    assert res.opened is False
    assert "portal down" in res.reason


# ── refusals before any opener runs ─────────────────────────────────────────────
def test_a_missing_folder_is_refused_without_running_anything(tmp_path):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": 0})
    res = op.open_folder(str(tmp_path / "nope"), host=host)
    assert res.opened is False and "does not exist" in res.reason
    assert host.calls == []


def test_a_file_is_not_a_folder(tmp_path):
    f = tmp_path / "x.txt"
    f.write_text("x")
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": 0})
    res = op.open_folder(str(f), host=host)
    assert res.opened is False and "not a folder" in res.reason
    assert host.calls == []


# ── WSL2 ────────────────────────────────────────────────────────────────────────
def test_wsl_uses_explorer_exe_on_the_wslpath_spelling_and_reports_it_unverified(folder):
    host = FakeHost(op.HOST_WSL, installed=["xdg-open", "wslpath", "explorer.exe"],
                    exits={"xdg-open": 2, "wslpath": 0, "explorer.exe": 1},
                    outputs={"wslpath": "\\\\wsl$\\Ubuntu\\tmp\\hugmesh-gateway\n"})
    res = op.open_folder(folder, host=host)
    assert host.calls[0] == ["/usr/bin/xdg-open", folder]             # Linux first
    assert host.calls[1] == ["/usr/bin/wslpath", "-w", folder]
    assert host.calls[2] == ["/usr/bin/explorer.exe", "\\\\wsl$\\Ubuntu\\tmp\\hugmesh-gateway"]
    assert res.opened is True
    assert res.verified is False, "explorer.exe exits 1 either way — never 'verified'"
    assert res.how == "explorer.exe"
    assert "\\\\wsl$\\Ubuntu" in res.reason


def test_wsl_without_wslpath_uses_the_unc_spelling_from_the_distro_name(folder):
    host = FakeHost(op.HOST_WSL, installed=["explorer.exe"], exits={"explorer.exe": 1},
                    wsl_distro="Ubuntu")
    res = op.open_folder(folder, host=host)
    assert res.opened and not res.verified
    assert host.calls[-1] == ["/usr/bin/explorer.exe",
                              "\\\\wsl$\\Ubuntu" + folder.replace("/", "\\")]


def test_wsl_without_interop_falls_through_to_the_last_resort(folder):
    host = FakeHost(op.HOST_WSL, installed=["xdg-open"], exits={"xdg-open": 3})
    res = op.open_folder(folder, last_resort=lambda p: True, host=host)
    assert res.opened and not res.verified
    assert "QDesktopServices" in res.how
    res2 = op.open_folder(folder, host=host)
    assert res2.opened is False
    assert "explorer.exe is not reachable" in res2.reason


def test_wsl_a_verified_linux_opener_wins_before_explorer(folder):
    host = FakeHost(op.HOST_WSL, installed=["xdg-open", "explorer.exe"],
                    exits={"xdg-open": 0})
    res = op.open_folder(folder, host=host)
    assert res.verified and res.how.startswith("xdg-open")
    assert all("explorer.exe" not in c[0] for c in host.calls)


# ── Windows and macOS ───────────────────────────────────────────────────────────
def test_windows_startfile_is_verified_and_runs_no_command(folder):
    seen = []
    host = FakeHost(op.HOST_WINDOWS, startfile=lambda p: seen.append(p))
    res = op.open_folder(folder, host=host)
    assert seen == [folder]
    assert (res.opened, res.verified) == (True, True)
    assert res.how == "os.startfile"
    assert host.calls == []


def test_windows_startfile_raising_is_not_an_open(folder):
    def no_assoc(_p):
        raise OSError("No application is associated")
    host = FakeHost(op.HOST_WINDOWS, startfile=no_assoc)
    res = op.open_folder(folder, host=host)
    assert res.opened is False
    assert "os.startfile failed" in res.reason
    res2 = op.open_folder(folder, last_resort=lambda p: True, host=host)
    assert res2.opened and not res2.verified


def test_darwin_uses_open_verified_by_exit_status(folder):
    host = FakeHost(op.HOST_DARWIN, installed=["open"], exits={"open": 0})
    res = op.open_folder(folder, host=host)
    assert res.verified and res.how.startswith("open")
    assert host.calls == [["/usr/bin/open", folder]]


# ── detection and the shared grace period ──────────────────────────────────────
def test_detect_on_this_linux_box_is_linux_or_wsl(monkeypatch):
    host = op.Host.detect()
    assert host.kind in (op.HOST_LINUX, op.HOST_WSL, op.HOST_DARWIN, op.HOST_WINDOWS)
    assert callable(host.which) and callable(host.run)


def test_the_grace_period_is_the_one_open_in_browser_uses():
    from hugmesh_studio.core import login_preview
    assert op.OPENER_WAIT_S == login_preview._OPENER_WAIT_S


def test_the_default_runner_reads_a_real_exit_code(tmp_path):
    code, out = op._run_and_wait(["sh", "-c", "echo hi; exit 3"], True)
    assert code == 3 and out.strip() == "hi"
    code, _ = op._run_and_wait(["/nonexistent/opener"], False)
    assert code == 127


# ── Open all: ONE waiting budget for any number of folders ─────────────────────
@pytest.fixture
def folders(tmp_path):
    out = []
    for i in range(25):
        d = tmp_path / f"hugmesh-app{i}"
        d.mkdir()
        out.append(str(d))
    return out


@pytest.fixture
def clock(monkeypatch):
    t = [0.0]
    monkeypatch.setattr(op, "_now", lambda: t[0])
    return t


def test_25_still_running_openers_cost_one_wait_not_25(folders, clock):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": None})
    host.clock = clock
    results = op.open_folders(folders, host=host)
    assert len(results) == 25
    assert sum(host.waits) <= op.OPENER_WAIT_S, (
        f"the waits add up to {sum(host.waits)}s for 25 folders — a frozen window")
    assert host.waits[0] == op.OPENER_WAIT_S and set(host.waits[1:]) == {0.0}
    assert all(r.opened and not r.verified for r in results)
    assert [r.path for r in results] == folders


def test_quick_openers_leave_the_budget_so_every_folder_stays_verified(folders, clock):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": 0})
    host.clock = clock                  # exit 0 burns no fake time
    results = op.open_folders(folders, host=host)
    assert all(r.opened and r.verified for r in results)
    assert host.waits == [op.OPENER_WAIT_S] * 25


def test_a_first_folder_nothing_can_open_stops_the_rest(folders, clock):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": 2})
    results = op.open_folders(folders, host=host)
    assert len(results) == 1 and results[0].opened is False
    assert len(host.calls) == 1


def test_the_budget_is_a_parameter(folders, clock):
    host = FakeHost(op.HOST_LINUX, installed=["xdg-open"], exits={"xdg-open": None})
    host.clock = clock
    op.open_folders(folders[:3], host=host, budget_s=1.5)
    assert host.waits == [1.5, 0.0, 0.0]


def test_open_folders_with_a_real_still_running_opener_is_bounded(tmp_path, monkeypatch):
    """The measurement the skeptic made, kept as a test: a REAL process that stays
    running (a fake xdg-open that sleeps), the real runner, five real folders."""
    import time
    bindir = tmp_path / "bin"
    bindir.mkdir()
    fake = bindir / "xdg-open"
    fake.write_text("#!/bin/sh\nexec sleep 3\n")      # ends by itself; nothing is killed
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    dirs = []
    for i in range(5):
        d = tmp_path / f"f{i}"
        d.mkdir()
        dirs.append(str(d))
    started = time.monotonic()
    results = op.open_folders(dirs, host=op.Host(kind=op.HOST_LINUX), budget_s=0.4)
    elapsed = time.monotonic() - started
    assert len(results) == 5 and all(r.opened and not r.verified for r in results)
    assert elapsed < 2.0, f"{elapsed:.1f}s for 5 folders at a 0.4s budget"


def test_module_is_qt_free():
    import subprocess
    import sys
    studio = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    proc = subprocess.run(
        [sys.executable, "-c",
         "import sys; import hugmesh_studio.core.open_path, "
         "hugmesh_studio.core.code_folders; "
         "print(sorted(m for m in sys.modules if m.startswith(('PySide6', 'PyQt6'))))"],
        cwd=studio, capture_output=True, text=True, check=True)
    assert proc.stdout.strip() == "[]", proc.stdout
