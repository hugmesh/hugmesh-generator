"""Headless CLI parity (#49): --scan-hardware + the build-session history flags.

Pure-core paths through app.main() — no Qt, no display. Pins the STABLE --json
schemas (core/hw_scan.to_dict, core/build_sessions.session_row), the human
one-line-per-session list format, and the delete guard: refuses without --yes,
refuses an in-progress build, artifacts removed only on explicit
--delete-artifacts.
"""
import json
import os
import sys

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core import hw_scan
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.hw_scan import Gpu, HwScan
from hugmesh_studio.core.worklist import synthesize


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    # Same env override as tray.build_status_path — session records share the family.
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _make_session(tmp_path, *, status=bs.COMPLETE, artifacts=0):
    """A persisted fixture session with a real <out>/sessions/<id>/ workdir."""
    wl = synthesize(ImageConfig(mode="standalone", role="standalone-thick",
                                platform="x86", brand="acme",
                                output_dir=str(tmp_path / "out")))
    s = bs.new_session(wl, str(tmp_path))
    bs.start(s)
    if status != bs.RUNNING:
        bs.finish(s, status)
    os.makedirs(s.workdir, exist_ok=True)
    for i in range(artifacts):
        with open(os.path.join(s.workdir, f"artifact-{i}.img"), "w",
                  encoding="utf-8") as fh:
            fh.write("x")
    return s


FAKE_SCAN = HwScan(os="linux", cpu="AMD Ryzen 7 7840U", cpu_vendor="amd",
                   gpus=[Gpu(vendor="amd", name="Radeon 780M", pci_id="1002:15bf")],
                   wifi="MEDIATEK MT7922", bluetooth="",
                   recommended_gpu_driver="amd-free", recommend_wifi=True,
                   recommend_bluetooth=False, hw_profile_guess="framework-13-amd",
                   notes=["a note"])


# ── --scan-hardware ────────────────────────────────────────────────────────────────────
def test_scan_hardware_json_schema_stable(monkeypatch, capsys):
    monkeypatch.setattr(hw_scan, "scan", lambda: FAKE_SCAN)
    assert app.main(["--scan-hardware", "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    # the STABLE schema — extending it is a deliberate contract change
    assert set(d) == {"os", "cpu", "cpu_vendor", "gpus", "wifi", "bluetooth",
                      "recommended_gpu_driver", "recommend_wifi",
                      "recommend_bluetooth", "hw_profile_guess", "notes"}
    assert d["gpus"] == [{"vendor": "amd", "name": "Radeon 780M",
                          "pci_id": "1002:15bf"}]
    assert d["recommended_gpu_driver"] == "amd-free"
    assert d["recommend_wifi"] is True and d["recommend_bluetooth"] is False


def test_scan_hardware_human_table(monkeypatch, capsys):
    monkeypatch.setattr(hw_scan, "scan", lambda: FAKE_SCAN)
    assert app.main(["--scan-hardware"]) == 0
    out = capsys.readouterr().out
    assert "AMD Ryzen 7 7840U" in out
    assert "recommended --gpu-driver" in out and "amd-free" in out
    assert "note: a note" in out


def test_scan_hardware_real_probe_smoke(capsys):
    """The unmocked probe is best-effort on any host (missing lspci etc. degrade to
    empty fields, never a crash) — the CLI must exit 0 and print SOMETHING."""
    assert app.main(["--scan-hardware", "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    assert d["os"] in ("linux", "windows")


def test_scan_hardware_never_imports_qt(monkeypatch, capsys):
    monkeypatch.setattr(hw_scan, "scan", lambda: FAKE_SCAN)
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert app.main(["--scan-hardware"]) == 0
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before
    capsys.readouterr()


# ── --list-sessions ────────────────────────────────────────────────────────────────────
def test_list_sessions_human_one_line_per_session(tmp_path, capsys):
    a = _make_session(tmp_path, artifacts=2)
    b = _make_session(tmp_path, status=bs.FAILED)
    assert app.main(["--list-sessions"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 2
    by_id = {ln.split()[0]: ln for ln in lines}
    assert set(by_id) == {a.id, b.id}
    # one line per session: id, date, roles, status, artifact count
    assert "standalone-thick" in by_id[a.id]
    assert "complete" in by_id[a.id] and "2 artifact(s)" in by_id[a.id]
    assert "failed" in by_id[b.id] and "0 artifact(s)" in by_id[b.id]
    assert a.started.split("T")[0] in by_id[a.id]


def test_list_sessions_json_schema_stable(tmp_path, capsys):
    s = _make_session(tmp_path, artifacts=3)
    assert app.main(["--list-sessions", "--json"]) == 0
    rows = json.loads(capsys.readouterr().out)
    assert isinstance(rows, list) and len(rows) == 1
    row = rows[0]
    # the STABLE row schema — extending it is a deliberate contract change
    assert set(row) == {"id", "created", "started", "finished", "kind", "label",
                        "status", "stale", "roles", "platforms", "workdir",
                        "artifact_count"}
    assert row["id"] == s.id and row["status"] == "complete"
    assert row["roles"] == ["standalone-thick"] and row["platforms"] == ["x86"]
    assert row["artifact_count"] == 3 and row["stale"] is False


def test_list_sessions_empty_store_is_quiet(capsys):
    assert app.main(["--list-sessions"]) == 0
    assert capsys.readouterr().out == ""


# ── --show-session / --session-artifacts ──────────────────────────────────────────────
def test_show_session_json_and_human(tmp_path, capsys):
    s = _make_session(tmp_path, artifacts=1)
    assert app.main(["--show-session", s.id, "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    assert d["id"] == s.id and d["status"] == "complete"
    assert d["artifact_count"] == 1 and d["stale"] is False
    assert d["images"][0]["role"] == "standalone-thick"
    assert app.main(["--show-session", s.id]) == 0
    out = capsys.readouterr().out
    assert s.id in out and "workdir:" in out and "standalone-thick" in out


def test_session_artifacts_lists_files(tmp_path, capsys):
    s = _make_session(tmp_path, artifacts=2)
    os.makedirs(os.path.join(s.workdir, "keys-omnibus"), exist_ok=True)
    with open(os.path.join(s.workdir, "keys-omnibus", "k.pem"), "w",
              encoding="utf-8") as fh:
        fh.write("x")
    assert app.main(["--session-artifacts", s.id, "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    assert set(d) == {"id", "workdir", "artifacts"}
    assert d["artifacts"] == ["artifact-0.img", "artifact-1.img",
                              os.path.join("keys-omnibus", "k.pem")]
    # human mode prints absolute paths, one per line
    assert app.main(["--session-artifacts", s.id]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines == [os.path.join(s.workdir, rel) for rel in d["artifacts"]]


@pytest.mark.parametrize("flag", ["--show-session", "--session-artifacts",
                                  "--delete-session"])
def test_unknown_session_id_exits_2(flag, capsys):
    assert app.main([flag, "nope-000000-ffffff", "--yes"]) == 2
    err = capsys.readouterr().err
    assert "no build session" in err


# ── --delete-session guards ────────────────────────────────────────────────────────────
def test_delete_refuses_without_yes(tmp_path, capsys):
    s = _make_session(tmp_path, artifacts=1)
    assert app.main(["--delete-session", s.id]) == 2
    assert "--yes" in capsys.readouterr().err
    assert os.path.isfile(s.path())          # record untouched
    assert os.path.isdir(s.workdir)          # artifacts untouched


def test_delete_with_yes_removes_record_only(tmp_path, capsys):
    s = _make_session(tmp_path, artifacts=1)
    assert app.main(["--delete-session", s.id, "--yes"]) == 0
    assert "deleted session" in capsys.readouterr().out
    assert not os.path.isfile(s.path())
    assert os.path.isdir(s.workdir)          # artifacts kept without --delete-artifacts


def test_delete_with_delete_artifacts_removes_tree(tmp_path, capsys):
    s = _make_session(tmp_path, artifacts=2)
    assert app.main(["--delete-session", s.id, "--yes", "--delete-artifacts"]) == 0
    capsys.readouterr()
    assert not os.path.isfile(s.path())
    assert not os.path.isdir(s.workdir)


def test_delete_refuses_an_active_build(tmp_path, capsys):
    # status running + THIS live pid (bs.start records os.getpid()) = active
    s = _make_session(tmp_path, status=bs.RUNNING)
    assert app.main(["--delete-session", s.id, "--yes"]) == 1
    assert "in progress" in capsys.readouterr().err
    assert os.path.isfile(s.path())


def test_sessions_cli_never_imports_qt(tmp_path, capsys):
    _make_session(tmp_path)
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert app.main(["--list-sessions", "--json"]) == 0
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before
    capsys.readouterr()
