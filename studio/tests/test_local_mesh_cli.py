"""Qt-free coverage for the shared Local-Docker-mesh entrypoint (core/local_mesh.main).

This is the SAME object graph the GUI's LocalMeshDialog and the ncurses local_mesh_screen
drive — a LocalMeshConfig -> LocalMeshNode. Unlike test_local_mesh.py these tests import
NO Qt (core.local_mesh imports only .mesh_node), so they run in the Qt-free system-python
environment CI uses for the build-matrix, proving the ncurses/Makefile channels' backend
works there.

Pins in particular the REQUIRED FIX: main() must export os.environ["TS_AUTHKEY"] before
node.start(), so MeshNode.start()'s inherited `${TS_AUTHKEY}` guard passes.
"""
import os

from snapdragon_studio.core import local_mesh
from snapdragon_studio.core.local_mesh import LocalMeshNode, main
from snapdragon_studio.core.mesh_node import MeshStatus


def test_up_reads_authkey_file_and_exports_ts_authkey(tmp_path, monkeypatch):
    monkeypatch.delenv("TS_AUTHKEY", raising=False)
    seen = {}

    def _fake_available(self):
        return True, ""

    def _fake_start(self):
        # the whole point: TS_AUTHKEY must be in the ENV by the time start() runs
        seen["env_key"] = os.environ.get("TS_AUTHKEY")
        seen["cfg_key"] = self.cfg.auth_key
        return True, "up"

    monkeypatch.setattr(LocalMeshNode, "available", _fake_available, raising=True)
    monkeypatch.setattr(LocalMeshNode, "start", _fake_start, raising=True)

    keyfile = tmp_path / "authkey"
    keyfile.write_text("tskey-fromfile\n")          # trailing newline must be stripped
    rc = main(["up", "--authkey-file", str(keyfile),
               "--node-name", "n1", "--generator-dir", str(tmp_path)])
    assert rc == 0
    assert seen["cfg_key"] == "tskey-fromfile"
    assert seen["env_key"] == "tskey-fromfile"      # the REQUIRED FIX: exported pre-start


def test_up_without_key_is_gated_and_never_starts(tmp_path, monkeypatch):
    monkeypatch.delenv("TS_AUTHKEY", raising=False)
    started = {"called": False}
    monkeypatch.setattr(LocalMeshNode, "start",
                        lambda self: started.__setitem__("called", True) or (True, ""),
                        raising=True)
    rc = main(["up", "--generator-dir", str(tmp_path)])
    assert rc == 2                       # available() gate -> non-zero, distinct from a run failure
    assert started["called"] is False    # start() must NOT have run


def test_inline_authkey_flag_is_accepted(tmp_path, monkeypatch):
    monkeypatch.delenv("TS_AUTHKEY", raising=False)
    seen = {}
    monkeypatch.setattr(LocalMeshNode, "available", lambda self: (True, ""), raising=True)
    monkeypatch.setattr(LocalMeshNode, "start",
                        lambda self: (seen.__setitem__("k", self.cfg.auth_key), (True, "up"))[1],
                        raising=True)
    rc = main(["up", "--authkey", "  tskey-inline  ", "--generator-dir", str(tmp_path)])
    assert rc == 0
    assert seen["k"] == "tskey-inline"   # stripped


def test_status_and_logs_are_read_only(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(LocalMeshNode, "status",
                        lambda self: MeshStatus(running=True, detail="1 container(s)"),
                        raising=True)
    monkeypatch.setattr(LocalMeshNode, "logs", lambda self, tail=200: "hello-logs",
                        raising=True)
    assert main(["status", "--generator-dir", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "running" in out and "1 container(s)" in out
    assert main(["logs", "--generator-dir", str(tmp_path)]) == 0
    assert "hello-logs" in capsys.readouterr().out


def test_module_imports_no_qt():
    # the entrypoint must be usable in the Qt-free CI environment. Proven in a FRESH
    # interpreter (this suite itself imports Qt elsewhere, so an in-process sys.modules
    # check would be meaningless): importing core.local_mesh + running --help must pull
    # in NO Qt binding.
    import subprocess
    import sys
    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    probe = (
        "import snapdragon_studio.core.local_mesh as m, sys;"
        "assert callable(m.main);"
        "assert m.ENV_AUTHKEY == 'TS_AUTHKEY';"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad;"
        "assert 'snapdragon_studio.gui' not in sys.modules"
    )
    env = dict(os.environ, PYTHONPATH=studio_root)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
