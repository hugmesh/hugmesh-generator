"""Windows sweep, cluster c10: the local-AI sentences, the --print-command fallback,
UTF-8 output under ``python -m``, the local-mesh teardown refusals and the Vault
remedies.

Each check pins ``osname`` instead of patching ``os.name``, so the Windows sentences are
proven on Linux CI too and the Linux ones stay as they were. The few that need the real
Windows streams or process are skipped elsewhere.
"""
from __future__ import annotations

import io
import os
import subprocess
import sys

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.core import ollama_docker as odk
from hugmesh_studio.core import platform_info
from hugmesh_studio.core import vaults
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap,
    LocalMeshBootstrapConfig,
)

STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
windows_only = pytest.mark.skipif(os.name != "nt", reason="native Windows streams/process")

WSL2 = platform_info.native_windows_blocker("x", osname="nt").split(" runs ", 1)[1]


def _down_probe():
    return False, [], [], ""


def _snapshot(tmp_path, osname, installed, monkeypatch):
    monkeypatch.setattr(lai.shutil, "which",
                        lambda name, *a, **k: "ollama" if installed else None)
    env = {lai.STATE_ENV: str(tmp_path / "lai")}
    return lai.read_snapshot(env, probe=_down_probe, builds=lambda: [], osname=osname)


# ── local AI: the snapshot's fix and the not-answering sentence ─────────────────────
def test_not_installed_on_windows_names_the_installer_not_the_bash_script(tmp_path, monkeypatch):
    snap = _snapshot(tmp_path, "nt", False, monkeypatch)
    assert snap.problem == "Ollama is not installed on this machine."
    assert "local-ai.sh" not in snap.fix and "see the link" not in snap.fix
    assert lai.OLLAMA_DOWNLOAD in snap.fix
    # the doc the MSI does not ship becomes one it can open
    assert snap.doc == lai.DOC_URL and snap.doc.startswith("https://")
    text = lai.format_status(snap)
    assert "local-ai.sh" not in text and "docs/LOCAL-AI" not in text.replace(lai.DOC_URL, "")


def test_installed_but_down_on_windows_says_start_ollama_for_windows(tmp_path, monkeypatch):
    snap = _snapshot(tmp_path, "nt", True, monkeypatch)
    assert "not answering" in snap.problem
    assert snap.fix == "Start Ollama for Windows from the Start menu."


def test_linux_snapshot_sentences_are_unchanged(tmp_path, monkeypatch):
    snap = _snapshot(tmp_path, "posix", False, monkeypatch)
    assert snap.fix == "Install it (see the link), then run: scripts/local-ai.sh up"
    assert snap.doc == lai.DOC
    snap = _snapshot(tmp_path, "posix", True, monkeypatch)
    assert snap.fix == "Start it with: scripts/local-ai.sh up"


def test_down_message_on_windows_says_not_installed_when_it_is_not(monkeypatch):
    monkeypatch.setattr(lai.shutil, "which", lambda *a, **k: None)
    said = lai._down_message({}, osname="nt")
    assert "not installed" in said and "Start it" not in said
    assert "local-ai.sh" not in said and lai.OLLAMA_DOWNLOAD in said and lai.DOC_URL in said


def test_down_message_on_windows_installed_and_docker_mode(monkeypatch):
    monkeypatch.setattr(lai.shutil, "which", lambda *a, **k: "C:\\ollama.exe")
    assert "Start Ollama for Windows" in lai._down_message({}, osname="nt")
    # Docker mode points OLLAMA_HOST at the Studio's container: that is the fix there
    env = {"OLLAMA_HOST": odk.endpoint(odk.DOCKER, {})}
    said = lai._down_message(env, osname="nt")
    assert "Ollama container" in said and "Ollama for Windows" not in said


@pytest.mark.parametrize("installed", [False, True])
def test_docker_mode_snapshot_on_windows_names_the_container(tmp_path, monkeypatch, installed):
    # Docker mode: the snapshot's host is the Studio's container, so neither installing
    # nor starting Ollama for Windows is the fix, and what the TUI/dock show keeps it
    # (both faces pass the read through odk.adjust_snapshot in Docker mode and rewrite
    # nothing else).
    monkeypatch.setattr(lai.shutil, "which",
                        lambda name, *a, **k: "ollama" if installed else None)
    env = odk.assistant_env(odk.DOCKER, {lai.STATE_ENV: str(tmp_path / "lai")})
    snap = lai.read_snapshot(env, probe=_down_probe, builds=lambda: [], osname="nt")
    assert snap.host == odk.endpoint(odk.DOCKER, env)
    assert "Ollama container" in snap.fix and "Ollama for Windows" not in snap.fix
    assert "not installed" not in snap.problem and "container" in snap.problem
    # same sentence as the not-answering message in that mode
    assert snap.fix in lai._down_message(env, osname="nt")
    shown = odk.adjust_snapshot(snap, odk.DOCKER)
    assert "Docker Ollama" in shown.problem and "not installed" not in shown.problem
    assert "container" in shown.fix and "Start local assistant" in shown.fix
    assert "Ollama for Windows" not in shown.fix and "local-ai.sh" not in shown.fix


def test_docker_mode_snapshot_on_linux_is_unchanged(tmp_path, monkeypatch):
    monkeypatch.setattr(lai.shutil, "which", lambda *a, **k: None)
    env = odk.assistant_env(odk.DOCKER, {lai.STATE_ENV: str(tmp_path / "lai")})
    snap = lai.read_snapshot(env, probe=_down_probe, builds=lambda: [], osname="posix")
    assert snap.problem == "Ollama is not installed on this machine."
    assert snap.fix == "Install it (see the link), then run: scripts/local-ai.sh up"


def test_down_message_on_linux_is_unchanged(monkeypatch):
    monkeypatch.setattr(lai.shutil, "which", lambda *a, **k: None)
    assert lai._down_message({}, osname="posix") == (
        "Ollama is not answering on 127.0.0.1:11434. Start it with scripts/local-ai.sh up "
        f"(see {lai.DOC}).")


@windows_only
def test_cli_local_ai_status_and_prompt_on_windows_give_no_bash_advice(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv(lai.STATE_ENV, str(tmp_path / "lai"))
    monkeypatch.setenv("OLLAMA_HOST", "127.0.0.1:9")      # discard port: refused at once
    monkeypatch.setattr(lai.shutil, "which", lambda *a, **k: None)
    assert app.main(["--local-ai-status"]) == 1
    out, err = capsys.readouterr()
    assert "local-ai.sh" not in out + err and lai.OLLAMA_DOWNLOAD in err
    assert app.main(["--local-ai-prompt", "hello"]) == 1
    err = capsys.readouterr().err
    assert "local-ai.sh" not in err and "not installed" in err


# ── --print-command / --print-commands with Docker not answering ────────────────────
def test_print_backend_on_windows_falls_back_to_docker_not_sudo_bash():
    assert app.print_backend("auto", "none", osname="nt") == "docker"
    assert app.print_backend("auto", "docker", osname="nt") is None
    assert app.print_backend("native", "none", osname="nt") == "native"


def test_print_backend_on_linux_is_unchanged():
    assert app.print_backend("auto", "none", osname="posix") == "native"
    assert app.print_backend("auto", "native", osname="posix") is None
    assert app.print_backend("docker", "none", osname="posix") == "docker"


def test_explicit_native_on_windows_notes_it_on_stderr_only(capsys, monkeypatch):
    app._native_print_note("native", osname="nt")
    out, err = capsys.readouterr()
    assert out == "" and "cannot do" in err and "WSL2" in err
    app._native_print_note("native", osname="posix")
    app._native_print_note("docker", osname="nt")
    assert capsys.readouterr() == ("", "")


# ── UTF-8 stdout/stderr under python -m hugmesh_studio ──────────────────────────────
def _cp1252():
    return io.TextIOWrapper(io.BytesIO(), encoding="cp1252", newline="")


def test_utf8_stdio_makes_a_cp1252_stream_utf8_on_windows_only():
    w = _cp1252()
    app.utf8_stdio(osname="nt", streams=[w, None, io.StringIO()])   # odd streams: no raise
    w.write("C:\\Users\\Łukasz Иван")
    w.flush()
    assert w.buffer.getvalue().decode("utf-8") == "C:\\Users\\Łukasz Иван"
    linux = _cp1252()
    app.utf8_stdio(osname="posix", streams=[linux])
    assert linux.encoding == "cp1252"


@windows_only
def test_print_command_with_a_non_cp1252_path_prints_it_not_a_false_bad_input(tmp_path, monkeypatch):
    gen = tmp_path / "Łukasz Иван gen"
    gen.mkdir()
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    stdout = _cp1252()
    monkeypatch.setattr(sys, "stdout", stdout)
    rc = app.main(["--print-command", "--backend", "docker", "--generator-dir", str(gen)])
    stdout.flush()
    assert rc == 0
    assert "Łukasz Иван gen" in stdout.buffer.getvalue().decode("utf-8")


@windows_only
def test_core_main_under_python_m_writes_utf8_to_a_pipe(tmp_path):
    where = tmp_path / "Łukasz Иван"
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONIOENCODING", "PYTHONUTF8")}
    env.update({lai.STATE_ENV: str(where), "HUGMESH_STUDIO_STATE_DIR": str(tmp_path / "s")})
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.local_ai_status", "dir"],
                       cwd=STUDIO, env=env, capture_output=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert r.stdout.decode("utf-8").strip() == str(where)


# ── local mesh: Stop / Stop && clean / Restore refuse with the WSL2 sentence ────────
class _Boom:
    """A stack/mesh node that must not be touched."""

    def __getattr__(self, name):
        raise AssertionError(f"touched {name} after a refusal")


class _Node:
    def __init__(self, calls):
        self.calls = calls

    def status(self):
        class S:
            running, detail = False, "not started"
        return S()

    def stop(self):
        self.calls.append("stop")
        return True, "stopped"

    def clean(self, on_line=None, cancel=None):
        self.calls.append("clean")
        return True, "cleaned"


def _boot(monkeypatch, node):
    b = LocalMeshBootstrap(os.path.join(STUDIO, "no-such-checkout"), LocalMeshBootstrapConfig())
    monkeypatch.setattr(b, "_stack_node", lambda: node)
    monkeypatch.setattr(b, "_mesh_node", lambda: node)
    return b


def test_stop_and_clean_refuse_on_windows_before_touching_anything(monkeypatch):
    b = _boot(monkeypatch, _Boom())
    sentence = platform_info.native_windows_blocker("The local stack", osname="nt")
    assert b.teardown_refusal("nt") == sentence and WSL2 in sentence
    assert b.down(osname="nt") == (False, [sentence])
    streamed = []
    assert b.clean(on_line=streamed.append, osname="nt") == (False, [sentence])
    assert streamed == [sentence]
    assert not any("WinError" in s for s in streamed)


def test_restore_refuses_on_windows_with_the_wsl2_sentence_first(monkeypatch):
    b = _boot(monkeypatch, _Boom())
    ok, log = b.restore(_Boom(), osname="nt")      # the record is not even read
    assert not ok and log == [b.teardown_refusal("nt")]
    assert "Generate && start" not in log[0]


def test_the_page_refuses_stop_and_clean_before_its_confirmation(monkeypatch):
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    from hugmesh_studio.gui.pages import localmesh
    from hugmesh_studio.gui.qt import QtWidgets
    sentence = platform_info.native_windows_blocker("The local stack", osname="nt")
    monkeypatch.setattr(localmesh.LocalMeshBootstrap, "teardown_refusal",
                        staticmethod(lambda osname=None: sentence))
    asked = []
    monkeypatch.setattr(QtWidgets.QMessageBox, "question",
                        lambda *a, **k: asked.append(a))

    class _Page:
        refused: list = []

        def _refuse(self, text):
            self.refused.append(text)
    page = _Page()
    localmesh.LocalMeshPage._bootstrap_clean(page)
    assert page.refused == [sentence] and asked == []


def test_stop_and_clean_on_linux_still_run_the_stack(monkeypatch):
    calls = []
    b = _boot(monkeypatch, _Node(calls))
    assert b.teardown_refusal("posix") == ""
    ok, _log = b.down(osname="posix")
    ok2, _log = b.clean(osname="posix")
    assert ok and ok2 and calls == ["stop", "stop", "stop", "clean"]


# ── Vaults: the remedies that drive the DevOps lane ─────────────────────────────────
def _docker_ps(names):
    def run(args, **_kw):
        return subprocess.CompletedProcess(args, 0, names, "")
    return run


def test_vault_lane_not_up_on_windows_gives_wsl2_and_vault_addr(monkeypatch):
    monkeypatch.setattr(vaults, "_run", _docker_ps(""))
    remedy = vaults._kind_route(osname="nt").cap.remedy
    assert WSL2 in remedy and "VAULT_ADDR" in remedy
    assert "make kind-up" not in remedy and "Start DevOps lane" not in remedy


def test_vault_kubectl_missing_on_windows_gives_no_install_button(monkeypatch):
    monkeypatch.setattr(vaults, "_run", _docker_ps("hugmesh-local-control-plane\n"))
    monkeypatch.setattr(vaults, "_kubectl_path", lambda: "")
    remedy = vaults._kind_route(osname="nt").cap.remedy
    assert "Install DevOps prerequisites" not in remedy and WSL2 in remedy


def test_vault_api_down_on_windows_gives_no_make(monkeypatch):
    def run(args, **_kw):
        if args[0] == "docker":
            return subprocess.CompletedProcess(args, 0, "hugmesh-local-control-plane\n", "")
        return subprocess.CompletedProcess(args, 1, "", "connection refused")
    monkeypatch.setattr(vaults, "_run", run)
    monkeypatch.setattr(vaults, "_kubectl_path", lambda: "kubectl")
    remedy = vaults._kind_route(osname="nt").cap.remedy
    assert "make kind-doctor" not in remedy and WSL2 in remedy


def test_vault_remedies_on_linux_are_unchanged(monkeypatch):
    monkeypatch.setattr(vaults, "_run", _docker_ps(""))
    assert vaults._kind_route(osname="posix").cap.remedy == vaults._REMEDY_START_LANE
    monkeypatch.setattr(vaults, "_run", _docker_ps("hugmesh-local-control-plane\n"))
    monkeypatch.setattr(vaults, "_kubectl_path", lambda: "")
    assert vaults._kind_route(osname="posix").cap.remedy == (
        "Press 'Install DevOps prerequisites' on the local-mesh page.")
