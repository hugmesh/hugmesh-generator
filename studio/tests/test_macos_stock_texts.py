"""A Mac that has not installed Homebrew's GNU tools is told Mac things, everywhere.

``platform_info.native_windows_blocker`` (and ``host_script_blocker`` under it) refuses
two hosts: the Windows MSI, and a Mac whose bash is 3.2 and whose sed/find/grep are BSD.
Its callers were written when a non-empty answer MEANT native Windows, and many of them
add advice of their own to the sentence. On a stock Mac those callers went on adding
the Windows advice:

* the text UI's emulation screens said "! not from this Windows Studio:" and offered
  the backend "QEMU for Windows (WHPX)" to get round WSL2;
* the local assistant said "Or keep this Windows build: start Ollama for Windows";
* the vault remedies said the route "needs the `vault` CLI installed on Windows";
* the Docker-mode start said "run the Studio inside WSL2".

The blocker now carries its host (``platform_info.HostBlocker`` / ``blocker_kind``) and
each of those callers has a Mac branch. This file makes the whole process answer as a
stock Mac (the way a real one does: ``host_kind`` says darwin, the GNU probe names what
is missing) and reads every Qt-free consumer's text. tests/test_macos_stock_texts_gui.py
does the same for the window's.

Runs the same on Linux and on a Mac; the ``macos`` job of studio-tests.yml runs it on
both runners.
"""
from __future__ import annotations

import ast
import os
import re
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import (emulation, local_ai_status as lai, macos_host,
                                 ollama_docker as odk, platform_info, qemu_tests,
                                 qemu_windows, vaults)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap
from hugmesh_studio.core.local_stack_node import LocalStackNode
from hugmesh_studio.tui import local_ai as tui_lai
from hugmesh_studio.tui import meshemu
from hugmesh_studio.tui import qemu as tui_qemu

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")

#: Words that are only true of the Windows build of the Studio.
WINDOWS_WORDS = re.compile(r"Windows|WSL|this PC|PowerShell|WHPX|Start menu|winget|\.exe\b",
                           re.IGNORECASE)
#: The same words as they are WRITTEN in a sentence, for reading the source: the
#: lower-case "windows" of ``host.os == "windows"`` is a value, not advice.
WINDOWS_WORDS_IN_SOURCE = re.compile(WINDOWS_WORDS.pattern)
MISSING = ["bash", "gnu-sed", "coreutils", "findutils", "grep"]
LINUX_REMEDY = "Press 'Resume DevOps lane' on the local-mesh page."


def _as_a_mac(monkeypatch, missing):
    real = platform_info.host_kind
    monkeypatch.setattr(platform_info, "host_kind",
                        lambda osname=None, sysplatform=None:
                        real(osname, sysplatform or "darwin"))
    monkeypatch.setattr(platform_info, "_GNU_MISSING", list(missing))


@pytest.fixture
def stock_mac(monkeypatch):
    """This process is a Mac with macOS's own bash 3.2 and BSD tools."""
    _as_a_mac(monkeypatch, MISSING)


@pytest.fixture
def brewed_mac(monkeypatch):
    """This process is a Mac that has run the ``brew install`` line."""
    _as_a_mac(monkeypatch, [])


def _docker_start_message(**kw) -> str:
    """ollama_docker.start_assistant in Docker mode, with the container 'up': what the
    person is told about the queue worker."""
    res = odk.start_assistant(
        GENERATOR_DIR, odk.DOCKER, environ={}, runner=None,
        starter=lambda runner, environ=None: SimpleNamespace(ok=True, message="", argv=[]),
        ready=lambda env, timeout: True,
        spawn=lambda *a, **k: (_ for _ in ()).throw(AssertionError("script spawned")),
        **kw)
    return res.message


#: name -> (text on this host, does the Mac text carry the brew line itself)
CONSUMERS = {
    "qemu_tests.native_blocker": (lambda: qemu_tests.native_blocker(), True),
    "emulation.playwright_root_blocker": (lambda: emulation.playwright_root_blocker(), True),
    "tui.meshemu.native_blocker_lines": (
        lambda: "\n".join(meshemu.native_blocker_lines("press b for the backend")), True),
    "tui.meshemu.backend_lines(docker)": (
        lambda: "\n".join(meshemu.backend_lines(qemu_windows.BACKEND_DOCKER)), True),
    "tui.qemu.native_lines": (lambda: "\n".join(tui_qemu.native_lines()), True),
    "local_ai_status.windows_refusal": (lambda: lai.windows_refusal(), True),
    "local_ai_status.windows_worker_note": (lambda: lai.windows_worker_note(), True),
    "local_ai_status.start_tooltip": (lambda: lai.start_tooltip(), True),
    "local_ai_status.system_ollama_note": (lambda: lai.system_ollama_note(), False),
    "local_ai_status.start_assistant": (
        lambda: lai.start_assistant(GENERATOR_DIR, env={}).message, True),
    "ollama_docker.start_assistant(docker)": (_docker_start_message, True),
    "tui.local_ai help": (
        lambda: "\n".join(tui_lai._help_lines(
            bool(lai.windows_worker_note()),
            platform_info.blocker_kind(lai.windows_worker_note()))), False),
    "vaults._lane_remedy": (lambda: vaults._lane_remedy(LINUX_REMEDY), True),
    "LocalMeshBootstrap.teardown_refusal": (lambda: LocalMeshBootstrap.teardown_refusal(),
                                            True),
    "LocalStackNode.available": (lambda: LocalStackNode(GENERATOR_DIR).available()[1], True),
}


@pytest.mark.parametrize("name", sorted(CONSUMERS))
def test_a_stock_mac_is_told_nothing_windows(stock_mac, name):
    text, has_brew_line = CONSUMERS[name]
    said = text()
    assert said, f"{name}: a Mac missing the GNU tools was not refused"
    found = sorted({m.group(0) for m in WINDOWS_WORDS.finditer(said)})
    assert not found, f"{name} says {found} on a Mac:\n{said}"
    if has_brew_line:
        assert macos_host.BREW_INSTALL in said, f"{name} does not give the brew line:\n{said}"


#: What each consumer says on a host that CAN run the scripts (a Mac with the GNU tools,
#: like Linux): "" for a refusal, or its ordinary text. None = not a refusal function.
@pytest.mark.parametrize("name", [
    "qemu_tests.native_blocker", "tui.meshemu.native_blocker_lines", "tui.qemu.native_lines",
    "local_ai_status.windows_refusal", "local_ai_status.windows_worker_note",
    "local_ai_status.start_tooltip", "local_ai_status.system_ollama_note",
    "LocalMeshBootstrap.teardown_refusal",
])
def test_a_mac_with_the_gnu_tools_is_refused_nothing(brewed_mac, name):
    assert CONSUMERS[name][0]() == ""


def test_a_mac_with_the_gnu_tools_gets_the_linux_text(brewed_mac):
    assert vaults._lane_remedy(LINUX_REMEDY) == LINUX_REMEDY
    assert tui_lai._help_lines(False) == list(tui_lai._HELP)
    # one backend on a Mac, so no "(b = switch)" either
    assert meshemu.backend_lines(qemu_windows.BACKEND_DOCKER) == [
        f"backend   {qemu_windows.DOCKER_LABEL_MACOS}"]


# ── the blocker carries its host ────────────────────────────────────────────────────
def test_the_blocker_says_which_host_it_refuses():
    win = platform_info.host_script_blocker("X", osname="nt")
    mac = platform_info.host_script_blocker("X", osname="posix", sysplatform="darwin",
                                            gnu_missing=["grep"])
    assert platform_info.blocker_kind(win) == "windows" and "WSL2" in win
    assert platform_info.blocker_kind(mac) == "darwin" and "WSL2" not in mac
    assert platform_info.blocker_kind("") == ""
    assert platform_info.blocker_kind(platform_info.host_script_blocker(
        "X", osname="posix", sysplatform="linux")) == ""
    # still a str to everything that shows it
    assert isinstance(win, str) and win == str(win) and win.startswith("X runs")


def test_a_plain_sentence_still_means_windows():
    """What a non-empty blocker meant before a Mac could be refused, and what ~25 test
    files' stand-in sentences (and any caller's own) still mean."""
    assert platform_info.blocker_kind("The Windows build cannot run this.") == "windows"


def test_formatting_a_blocker_loses_its_host_so_it_is_read_first():
    mac = platform_info.host_script_blocker("X", sysplatform="darwin", gnu_missing=["grep"])
    assert platform_info.blocker_kind(f"{mac}") == "windows"      # the trap
    assert platform_info.blocker_kind(mac) == "darwin"            # the rule
    # the composed local-assistant sentences re-wrap, so their callers can still ask
    assert platform_info.blocker_kind(platform_info.HostBlocker(f"{mac} more", "darwin")) \
        == "darwin"


def test_the_mac_sentence_keeps_its_command_on_a_line_of_its_own():
    mac = platform_info.host_script_blocker("X", sysplatform="darwin", gnu_missing=["grep"])
    lines = platform_info.blocker_lines(mac)
    assert len(lines) == 3
    assert lines[1].strip() == macos_host.BREW_INSTALL
    win = platform_info.host_script_blocker("X", osname="nt")
    assert platform_info.blocker_lines(win) == [win]


# ── the composed sentences keep their host, and Windows keeps its words ─────────────
def test_local_assistant_sentences_carry_their_host(stock_mac):
    for said in (lai.windows_refusal(), lai.windows_worker_note()):
        assert platform_info.blocker_kind(said) == "darwin"
        assert said.endswith(lai.MACOS_NATIVE_PATH)
        assert "ollama serve" in said and "127.0.0.1:11434" in said


def test_windows_local_assistant_text_is_unchanged():
    base = platform_info.native_windows_blocker(
        "Starting the local assistant", osname="nt",
        runs="the bash script scripts/local-ai.sh")
    assert lai.windows_refusal("nt") == f"{base} {lai.WINDOWS_NATIVE_PATH}"
    assert platform_info.blocker_kind(lai.windows_refusal("nt")) == "windows"
    assert lai.start_tooltip("nt") == (
        "In Docker mode: start the Studio's Ollama container and wait until it "
        "answers. With the system Ollama there is nothing to start from here: "
        "Ollama for Windows runs in the background once installed.\n\n"
        + lai.windows_worker_note("nt"))
    assert lai.system_ollama_note("nt") == (
        "The Studio does not start or stop the system Ollama from here: "
        "Ollama for Windows runs in the background once installed (start it "
        "from the Start menu when it is not answering; get it from "
        f"{lai.OLLAMA_DOWNLOAD}).")
    assert tui_lai._help_lines(True) == [
        tui_lai._WINDOWS_START_HELP if ln.startswith("  start ") else ln
        for ln in tui_lai._HELP]


def test_windows_vault_remedy_is_unchanged():
    base = platform_info.native_windows_blocker("The DevOps (Kubernetes) lane", osname="nt")
    assert vaults._lane_remedy(LINUX_REMEDY, "nt", first="Press Refresh. ") == (
        f"Press Refresh. {base} {vaults._WINDOWS_HOST_ROUTE}")
    assert vaults._lane_remedy(LINUX_REMEDY, "posix") in (LINUX_REMEDY,) or \
        platform_info.host_kind() == "darwin"


def test_the_mac_vault_route_names_this_mac(stock_mac):
    said = vaults._lane_remedy(LINUX_REMEDY, first="Press Refresh. ")
    assert said.startswith("Press Refresh. The DevOps (Kubernetes) lane runs")
    assert said.endswith(vaults._MACOS_HOST_ROUTE)
    assert "VAULT_ADDR" in said and "this Mac" in said


def test_windows_docker_mode_start_is_unchanged():
    assert "Windows build of the Studio cannot run (run the Studio inside WSL2 for it)" \
        in _docker_start_message(osname="nt")


def test_docker_mode_on_a_stock_mac_starts_the_container_and_no_script(stock_mac):
    """The container starts and the panel can use it; the queue worker (the bash
    script) is not spawned, and the reason is the Mac's."""
    said = _docker_start_message()          # its spawn stand-in raises if reached
    assert "is answering on" in said and "bash 4 and the GNU tools" in said
    assert f"`{macos_host.BREW_INSTALL}`" in said


def test_windows_text_screen_lines_are_unchanged(monkeypatch):
    sentence = platform_info.host_script_blocker(
        "QEMU device tests and mesh emulation", osname="nt", runs="bash scripts")
    monkeypatch.setattr(qemu_tests, "native_blocker", lambda: sentence)
    assert meshemu.native_blocker_lines("press b for the backend") == [
        "! not from this Windows Studio:", "  " + sentence,
        "  To boot ONE x86 device image (a thin desktop or a single node) on this "
        "PC without WSL2: press b for the backend “QEMU for Windows (WHPX)”."]


def test_the_mac_text_screen_lines_are_the_sentence_line_by_line(stock_mac):
    lines = meshemu.native_blocker_lines("press b for the backend")
    assert lines[0] == "! not on this Mac yet:"
    assert all(line.startswith("  ") and "\n" not in line for line in lines[1:])
    assert lines[2].strip() == macos_host.BREW_INSTALL
    # the emulation screens open on Docker there: QEMU for Windows cannot boot anything
    assert meshemu.default_backend() == qemu_windows.BACKEND_DOCKER


def test_a_mac_is_offered_the_docker_backend_alone(stock_mac):
    """QEMU for Windows cannot boot anything on a Mac. The text UI's switch key used
    to land on it, where the screen refused and pointed back at Docker, which a stock
    Mac refuses too: a loop with no way out in it."""
    assert qemu_windows.backends() == (
        (qemu_windows.BACKEND_DOCKER, qemu_windows.DOCKER_LABEL_MACOS),)
    assert meshemu.next_backend(qemu_windows.BACKEND_DOCKER) == qemu_windows.BACKEND_DOCKER
    assert meshemu.next_backend(qemu_windows.BACKEND_WHPX) == qemu_windows.BACKEND_DOCKER
    assert meshemu.switch_hint() == ""
    assert meshemu.default_backend() == qemu_windows.BACKEND_DOCKER
    _no_words = WINDOWS_WORDS.search("\n".join(
        meshemu.backend_lines(qemu_windows.BACKEND_DOCKER)))
    assert not _no_words, _no_words


def test_the_backends_and_the_switch_key_are_unchanged_off_a_mac(monkeypatch):
    assert qemu_windows.backends("posix", "linux") is qemu_windows.BACKENDS
    assert qemu_windows.backends("nt", "win32") is qemu_windows.BACKENDS
    real = platform_info.host_kind
    monkeypatch.setattr(platform_info, "host_kind",
                        lambda osname=None, sysplatform=None:
                        real(osname or "posix", sysplatform or "linux"))
    assert meshemu.next_backend(qemu_windows.BACKEND_DOCKER) == qemu_windows.BACKEND_WHPX
    assert meshemu.next_backend(qemu_windows.BACKEND_WHPX) == qemu_windows.BACKEND_DOCKER
    assert meshemu.switch_hint() == f"{meshemu.BACKEND_KEY} = switch backend · "
    assert meshemu.backend_label(qemu_windows.BACKEND_DOCKER) == \
        "Docker container (Linux or WSL2)"


# ── the guard: a new consumer cannot add Windows advice without asking the host ─────
#: Calls that return (or forward) a host-script blocker.
_BLOCKER_CALLS = {
    "native_windows_blocker", "host_script_blocker", "native_blocker", "teardown_refusal",
    "windows_refusal", "windows_worker_note", "k8s_teardown_blocker", "_teardown_blocker",
    "_windows_blocker", "_native_windows_refusal", "playwright_root_blocker", "blocker",
}
#: Functions that call one of those and contain Windows wording for another reason.
#: Each entry says why it is not a Mac's text.
_NOT_A_MAC_TEXT = {
    # qemu_windows.blocker() is the WHPX backend's OWN refusal ("QEMU for Windows is the
    # Windows Studio's emulation backend"), shown when that backend is chosen, on Linux
    # exactly as on a Mac; these functions describe that backend.
    ("core/qemu_windows.py", "run_cli"),
    ("gui/pages/mesh_emulation.py", "__init__"),
    ("gui/pages/mesh_emulation.py", "_paint_whpx_note"),
    ("tui/meshemu.py", "backend_lines"),
    ("tui/meshemu.py", "whpx_detail_lines"),
}


def _functions_adding_windows_words_to_a_blocker():
    found = []
    for root, _dirs, files in os.walk(PACKAGE):
        for name in sorted(files):
            if not name.endswith(".py"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as fh:
                tree = ast.parse(fh.read())
            rel = os.path.relpath(path, PACKAGE).replace(os.sep, "/")
            for fn in ast.walk(tree):
                if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                doc = (fn.body[0].value if fn.body and isinstance(fn.body[0], ast.Expr)
                       and isinstance(fn.body[0].value, ast.Constant) else None)
                calls, names, windows = set(), set(), []
                for node in ast.walk(fn):
                    if isinstance(node, ast.Call):
                        f = node.func
                        calls.add(f.attr if isinstance(f, ast.Attribute)
                                  else getattr(f, "id", ""))
                    if isinstance(node, ast.Attribute):
                        names.add(node.attr)
                    elif isinstance(node, ast.Name):
                        names.add(node.id)
                    elif (isinstance(node, ast.Constant) and isinstance(node.value, str)
                          and node is not doc
                          and WINDOWS_WORDS_IN_SOURCE.search(node.value)):
                        windows.append(node.lineno)
                if calls & _BLOCKER_CALLS and windows:
                    found.append((rel, fn.name, bool(names & {"blocker_kind", "host_kind"}),
                                  windows[0]))
    return found


def test_every_function_that_adds_windows_words_to_a_blocker_asks_which_host():
    """The defect's shape, read from the source: a function calls a blocker and has
    Windows wording of its own. It must ask ``blocker_kind`` (or ``host_kind``), or a
    Mac missing the GNU tools gets that wording too."""
    found = _functions_adding_windows_words_to_a_blocker()
    assert len(found) >= 8, found          # the scan still sees the known consumers
    unasked = [(rel, fn, line) for rel, fn, asks, line in found
               if not asks and (rel, fn) not in _NOT_A_MAC_TEXT]
    assert not unasked, (
        "these functions add Windows-only advice to a host-script blocker without "
        f"asking platform_info.blocker_kind which host it refuses: {unasked}")
    stale = _NOT_A_MAC_TEXT - {(rel, fn) for rel, fn, _a, _l in found}
    assert not stale, f"no longer needed in _NOT_A_MAC_TEXT: {sorted(stale)}"
