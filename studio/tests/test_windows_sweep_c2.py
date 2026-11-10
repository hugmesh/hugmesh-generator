"""Windows sweep, cluster c2: the this-machine hardware scan on native Windows.

core/hw_scan.py ran three cold ``powershell`` starts (15 s timeout each) and decoded
their OEM-code-page output as ANSI (``text=True``): a German 'für' raised
UnicodeDecodeError in the reader thread and then AttributeError on ``None``, 'Gerät'
came back as 'GerÃ¤t', and a probe that timed out was reported as "(none detected)"
with recommendations derived from it. These tests drive ``_ps_scan`` with a fake
``subprocess.run`` (so they run on Linux CI too); the last two run real PowerShell.
"""
from __future__ import annotations

import base64
import os
import subprocess

import pytest

from hugmesh_studio.core import hw_scan
from hugmesh_studio.core.hw_scan import Gpu, HwScan


def _line(tag: str, name: str) -> bytes:
    """One name as the PowerShell script's E function prints it."""
    return f"{tag} ".encode() + base64.b64encode(name.encode("utf-8")) + b"\r\n"


def _ok(*tags: str) -> bytes:
    return b"".join(f"OK {t}\r\n".encode() for t in tags)


class _FakeRun:
    """Stands in for subprocess.run: records argv, returns bytes or raises."""

    def __init__(self, stdout: bytes = b"", exc: BaseException | None = None):
        self.stdout, self.exc, self.calls = stdout, exc, []

    def __call__(self, cmd, **kw):
        self.calls.append((cmd, kw))
        if self.exc is not None:
            raise self.exc
        return subprocess.CompletedProcess(cmd, 0, self.stdout, b"")


GERMAN = (_line("CPU", "Intel(R) Core(TM) i7-10510U CPU @ 1.80GHz") + _ok("CPU")
          + _line("GPU", "Intel(R) UHD Graphics für Notebooks") + _ok("GPU")
          + _line("NET", "Intel Wi-Fi 6 AX201 für Notebooks")
          + _line("NET", "Bluetooth-Gerät (PAN)") + _ok("NET"))


def test_one_powershell_start_ascii_only_argv():
    run = _FakeRun(GERMAN)
    hw_scan._scan_windows(run)
    assert len(run.calls) == 1                      # was three cold starts
    cmd, kw = run.calls[0]
    assert cmd[:4] == ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand"]
    assert all(a.isascii() for a in cmd)
    # bytes, decoded here: no text=True locale decoding of the child's output
    assert "text" not in kw and "encoding" not in kw
    assert kw["timeout"] == hw_scan._WIN_TIMEOUT
    script = base64.b64decode(cmd[4]).decode("utf-16-le")
    for cls in ("Win32_Processor", "Win32_VideoController", "Win32_NetworkAdapter"):
        assert cls in script


def test_non_ascii_names_come_back_intact():
    s = hw_scan._scan_windows(_FakeRun(GERMAN))
    assert s.wifi == "Intel Wi-Fi 6 AX201 für Notebooks"
    assert s.bluetooth == "Bluetooth-Gerät (PAN)"
    assert [g.name for g in s.gpus] == ["Intel(R) UHD Graphics für Notebooks"]
    assert s.recommended_gpu_driver == "intel-free"
    assert s.recommend_wifi and s.recommend_bluetooth
    assert s.probe_errors == {} and s.notes == []


def test_undecodable_output_degrades_never_raises():
    # raw OEM bytes (0x81 = 'ü' in cp437) plus a broken base64 line: no traceback
    junk = b"Intel Wi-Fi f\x81r Notebooks\r\nNET !!notbase64\r\n" + _ok("CPU", "GPU", "NET")
    s = hw_scan._scan_windows(_FakeRun(junk))
    assert s.wifi == "" and s.gpus == [] and s.cpu == ""
    assert s.probe_errors == {}
    hw_scan.format_table(s)
    hw_scan.to_dict(s)


def test_timeout_is_reported_not_shown_as_absent():
    # the CPU query finished before the limit; GPU and network did not
    partial = _line("CPU", "AMD Ryzen 7 3700U") + _ok("CPU")
    exc = subprocess.TimeoutExpired(["powershell"], 45, output=partial)
    s = hw_scan._scan_windows(_FakeRun(exc=exc))
    assert s.cpu == "AMD Ryzen 7 3700U" and s.scanned("cpu")
    assert not s.scanned("gpu") and not s.scanned("network")
    assert s.probe_errors["gpu"] == "timed out after 45 s"
    assert any("GPU scan timed out after 45 s" in n for n in s.notes)
    assert any("Wi-Fi and Bluetooth were not checked" in n for n in s.notes)
    assert not any(n.startswith("No GPU detected") for n in s.notes)
    table = hw_scan.format_table(s)
    assert "(none detected)" not in table
    assert "(scan timed out after 45 s)" in table
    assert "(no recommendation: GPU not scanned)" in table
    rows = dict(ln.split("  ", 1) for ln in table.splitlines() if not ln.startswith("note:"))
    rows = {k.strip(): v.strip() for k, v in rows.items()}
    assert rows["recommend --enable-wifi"] == "(no recommendation: not scanned)"
    assert rows["recommend --enable-bluetooth"] == "(no recommendation: not scanned)"
    assert rows["cpu"] == "AMD Ryzen 7 3700U"
    # --json keeps its pinned schema; the reason reaches it through notes
    d = hw_scan.to_dict(s)
    assert "probe_errors" not in d
    assert any("timed out" in n for n in d["notes"])


def test_failed_query_and_missing_powershell():
    out = _line("CPU", "x") + _ok("CPU") + b"ERR GPU\r\n" + _ok("NET")
    s = hw_scan._scan_windows(_FakeRun(out))
    assert s.probe_errors == {"gpu": "failed (Win32_VideoController query error)"}
    assert "(scan failed (Win32_VideoController query error))" in hw_scan.format_table(s)
    s = hw_scan._scan_windows(_FakeRun(exc=FileNotFoundError("powershell")))
    assert set(s.probe_errors) == {"cpu", "gpu", "network"}
    assert s.probe_errors["cpu"].startswith("failed: PowerShell could not start")
    assert "(not detected)" not in hw_scan.format_table(s)


def test_scan_that_ran_still_says_none_detected():
    # the Linux path never sets probe_errors: its table is unchanged
    s = hw_scan._finalize(HwScan(os="linux", cpu="c", cpu_vendor="other"))
    table = hw_scan.format_table(s)
    assert "(none detected)" in table
    assert "recommend --enable-wifi       no" in table
    assert s.notes == ["No GPU detected by the scan — verify the --gpu-driver choice manually."]
    s = hw_scan._finalize(HwScan(os="linux", gpus=[Gpu("amd", "Radeon")]))
    assert "amd-free" in hw_scan.format_table(s)


@pytest.mark.skipif(os.name != "nt", reason="real PowerShell on native Windows")
def test_real_powershell_round_trips_non_ascii():
    """The E function, run by real PowerShell in a fresh windowless console (the MSI's
    OEM code page 437), hands back 'für' / 'Gerät' unmangled."""
    enc_fn = hw_scan._WIN_SCRIPT.splitlines()[0]
    script = enc_fn + "\nE NET 'Bluetooth-Gerät für Notebooks'\n'OK CPU'\n'OK GPU'\n'OK NET'"
    cmd = ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand",
           base64.b64encode(script.encode("utf-16-le")).decode("ascii")]
    out = subprocess.run(cmd, capture_output=True, timeout=60,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout

    def run(_cmd, **kw):
        return subprocess.CompletedProcess(_cmd, 0, out, b"")

    s = hw_scan._scan_windows(run)
    assert s.bluetooth == "Bluetooth-Gerät für Notebooks"
    assert s.probe_errors == {}


@pytest.mark.skipif(os.name != "nt", reason="real PowerShell on native Windows")
def test_real_scan_runs_every_probe():
    s = hw_scan.scan()
    assert s.os == "windows"
    # A loaded PC can push CIM past the limit, so a timeout is not a failure here;
    # what must hold is that every probe either answered or says why it did not.
    for probe in ("cpu", "gpu", "network"):
        reason = s.probe_errors.get(probe, "")
        assert s.scanned(probe) or reason.startswith(("timed out", "failed")), (probe, reason)
    assert s.cpu or "cpu" in s.probe_errors


# ── the wizard's HardwarePage: off the GUI thread, and honest about a timeout ─────────
def _hardware_page():
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from hugmesh_studio.gui.qt import QtWidgets
    from hugmesh_studio.gui.pages.hardware import HardwarePage
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    return app, HardwarePage(wiz=None)


def _timed_out_scan():
    partial = _line("CPU", "AMD Ryzen 7 3700U") + _ok("CPU")
    exc = subprocess.TimeoutExpired(["powershell"], 45, output=partial)
    return hw_scan._scan_windows(_FakeRun(exc=exc))


def test_a_timed_out_scan_keeps_the_settings_and_says_not_checked():
    """A timeout used to read 'GPU: none', reset the GPU driver to auto and untick
    Wi-Fi/Bluetooth the operator had set; the notes were never shown."""
    _app, page = _hardware_page()
    page._set_gpu("nvidia")
    page.wifi.setChecked(True)
    page.bt.setChecked(True)
    page._scanned(_timed_out_scan(), "")
    assert page.gpu.currentText() == "nvidia"
    assert page.wifi.isChecked() and page.bt.isChecked()
    text = page.scan_out.text()
    assert "GPU: not checked" in text and "GPU: none" not in text
    assert "recommended driver" not in text
    assert "GPU scan timed out after 45 s" in text
    assert "Wi-Fi and Bluetooth were not checked" in text
    assert "CPU: AMD Ryzen 7 3700U" in text
    assert page.scan_btn.isEnabled()
    # the page's own control names, never the CLI flags it does not show
    assert "'GPU driver' was left as it was" in text
    assert "'Enable Wi-Fi' and 'Enable Bluetooth' were left as they were" in text
    assert "--" not in text


def test_a_gpu_probe_cut_short_after_some_names_is_still_not_checked():
    """A timeout after one GPU name was printed used to show 'GPU: <name>' and a
    recommended driver next to 'the GPU was not checked', and applied that driver."""
    _app, page = _hardware_page()
    page._set_gpu("nvidia")
    partial = (_line("CPU", "AMD Ryzen 7 3700U") + _ok("CPU")
               + _line("GPU", "AMD Radeon Vega 10"))
    exc = subprocess.TimeoutExpired(["powershell"], 45, output=partial)
    s = hw_scan._scan_windows(_FakeRun(exc=exc))
    assert s.gpus and not s.scanned("gpu")
    page._scanned(s, "")
    assert page.gpu.currentText() == "nvidia"
    text = page.scan_out.text()
    assert "GPU: not checked" in text and "Radeon" not in text
    assert "recommended driver" not in text


def test_fields_changed_during_the_scan_are_kept_and_next_waits(monkeypatch):
    """The scan runs off the GUI thread, so the operator can edit while it runs: the
    result must not overwrite those edits, and Next must not commit pre-scan values."""
    import threading
    app, page = _hardware_page()
    release = threading.Event()

    def slow_scan():
        release.wait(10)
        # recommends amd-free and no Wi-Fi/Bluetooth
        return hw_scan._finalize(HwScan(os="linux", gpus=[Gpu("amd", "Radeon")]))

    monkeypatch.setattr(hw_scan, "scan", slow_scan)
    page._set_gpu("auto")
    page.bt.setChecked(True)
    assert page.isComplete()
    page._scan()
    assert not page.isComplete()                     # Next waits for the scan
    page._set_gpu("nvidia")                          # edited while it runs
    page.wifi.setChecked(True)
    release.set()
    worker = page._scan_worker
    assert worker is not None and worker.wait(10_000)
    for _ in range(50):                              # deliver the queued signal
        app.processEvents()
        if page.isComplete():
            break
    assert page.isComplete() and page.scan_btn.isEnabled()
    assert page.gpu.currentText() == "nvidia" and page.wifi.isChecked()
    assert not page.bt.isChecked()                   # untouched, so the scan set it
    assert ("You changed 'GPU driver' and 'Enable Wi-Fi' while the scan ran, so the "
            "scan left them as you set them.") in page.scan_out.text()


def test_a_scan_that_ran_applies_as_before():
    # the Linux path never fills probe_errors, so this is its unchanged behaviour
    _app, page = _hardware_page()
    page._set_gpu("nvidia")
    page.wifi.setChecked(True)
    s = hw_scan._finalize(HwScan(os="linux", cpu="c", cpu_vendor="other"))
    page._scanned(s, "")
    assert page.gpu.currentText() == "auto"
    assert not page.wifi.isChecked() and not page.bt.isChecked()
    assert page.scan_out.text() == "CPU: c  ·  GPU: none  ·  recommended driver: auto"


def test_the_scan_runs_off_the_gui_thread(monkeypatch):
    import threading
    app, page = _hardware_page()
    seen = {}

    def fake_scan():
        seen["thread"] = threading.get_ident()
        return hw_scan._finalize(HwScan(os="linux", gpus=[Gpu("amd", "Radeon")]))

    monkeypatch.setattr(hw_scan, "scan", fake_scan)
    page._scan()
    assert not page.scan_btn.isEnabled()            # one scan at a time
    assert "Scanning this machine" in page.scan_out.text()
    worker = page._scan_worker
    assert worker is not None and worker.wait(10_000)
    for _ in range(50):                              # deliver the queued signal
        app.processEvents()
        if page.scan_btn.isEnabled():
            break
    assert seen["thread"] != threading.get_ident()
    assert page.gpu.currentText() == "amd-free" and "GPU: Radeon" in page.scan_out.text()


def test_a_scan_that_raises_says_so_and_rearms():
    _app, page = _hardware_page()
    page._scanned(None, "OSError: boom")
    assert page.scan_out.text() == "The scan failed: OSError: boom"
    assert page.scan_btn.isEnabled()
