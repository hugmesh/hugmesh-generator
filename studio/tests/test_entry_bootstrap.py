"""Every process entry of the Studio installs the Mac PATH hook, not just the window.

Homebrew does not put its GNU tools on a shell's PATH: ``brew install coreutils
gnu-sed findutils grep make`` leaves them in ``<prefix>/opt/<formula>/libexec/gnubin``.
``macos_host.install()`` puts those folders (and Homebrew's ``bin``, where bash 5 is) in
front of the system ones, and it was called from ``app.main`` only. So on a Mac that
HAD run the brew line:

* the window found the tools and worked;
* the text UI (``python -m hugmesh_studio.tui``) and every module command line
  (``python -m hugmesh_studio.core.emulation``, ``...cloud_deploy``) refused: gnu-sed,
  coreutils, findutils, grep and make all "missing", in a sentence ending "You do not
  need to change your shell or PATH: the Studio puts Homebrew's GNU tools first".

``core/entry.bootstrap()`` is now the one call, and every entry makes it. Proven here
three ways: the text UI's real ``main`` against a fake Homebrew tree (refused without
the hook, not refused with it), the order inside each ``main``, and a reading of every
``if __name__ == "__main__"`` block in the package, so an entry added later cannot
forget.

Runs the same on Linux and on a Mac (the tree's tools are scripts that print the
banners the probe reads); the ``macos`` job of studio-tests.yml also drives the text
UI and a module command line against the runner's real Homebrew.
"""
from __future__ import annotations

import ast
import inspect
import io
import os

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import entry, macos_host, platform_info
from hugmesh_studio.tui import app as tui_app

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")

#: What each GNU tool prints for ``--version`` (macos_host.GNU_TOOLS reads the banner).
_GNU_BANNERS = {"sed": "sed (GNU sed) 4.9", "stat": "stat (GNU coreutils) 9.7",
                "find": "find (GNU findutils) 4.10.0", "grep": "grep (GNU grep) 3.12",
                "make": "GNU Make 4.4.1"}
_FORMULA = {"sed": "gnu-sed", "stat": "coreutils", "find": "findutils", "grep": "grep",
            "make": "make"}


def _script(path, body: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


@pytest.fixture
def brewed_mac(tmp_path, monkeypatch):
    """A Mac that has run the brew line, as its SHELL sees it.

    ``<tmp>/usr-bin`` stands in for /usr/bin: bash 3.2 and BSD tools that reject
    ``--version``. ``<tmp>/homebrew`` is the Homebrew prefix: each GNU tool in its
    formula's ``libexec/gnubin``, bash 5 in ``bin``. PATH holds only the system
    folder, which is Homebrew's default for the gnubin folders (and launchd's for
    everything). Returns (system dir, brew prefix)."""
    sysdir = str(tmp_path / "usr-bin")
    brew = str(tmp_path / "homebrew")
    _script(f"{sysdir}/bash", "echo 3")
    for tool in _GNU_BANNERS:
        _script(f"{sysdir}/{tool}", f'echo "{tool}: illegal option -- -" >&2; exit 1')
    for tool, banner in _GNU_BANNERS.items():
        _script(f"{brew}/opt/{_FORMULA[tool]}/libexec/gnubin/{tool}", f'echo "{banner}"')
    _script(f"{brew}/bin/bash", "echo 5")
    monkeypatch.setattr(macos_host, "is_macos", lambda sysplatform=None: True)
    monkeypatch.setattr(macos_host, "BREW_PREFIXES", (brew,))
    monkeypatch.setattr(macos_host, "SYSTEM_DIRS", (sysdir,) + macos_host.SYSTEM_DIRS)
    monkeypatch.setattr(macos_host, "DOCKER_DIRS", ())
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("PATH", sysdir)
    monkeypatch.setattr(platform_info, "_GNU_MISSING", None)      # nobody has probed yet
    return sysdir, brew


def _refusal() -> str:
    """What the text UI's emulation screens (and every bash verb) would say now."""
    return platform_info.host_script_blocker("Mesh emulation", osname="posix",
                                             sysplatform="darwin")


def _run_text_ui() -> int:
    """The text UI's real entry, on its shortest path: a session that does not exist."""
    return tui_app.main(["--worklist", "no-such-session"],
                        inp=io.StringIO(""), out=io.StringIO())


# ── the text UI, against a fake Homebrew tree ───────────────────────────────────────
def test_the_fixture_is_a_mac_whose_shell_path_has_no_gnu_tools(brewed_mac):
    """Without the hook this Mac IS refused: the test below is not vacuous."""
    assert macos_host.gnu_userland_missing() == [
        "bash", "gnu-sed", "coreutils", "findutils", "grep", "make"]
    said = _refusal()
    assert "this Mac is missing" in said and macos_host.BREW_INSTALL in said


def test_the_text_ui_finds_homebrews_gnu_tools(brewed_mac):
    sysdir, brew = brewed_mac
    assert _run_text_ui() == 2                       # "no readable session record"
    path = os.environ["PATH"].split(os.pathsep)
    gnubin = [f"{brew}/opt/{formula}/libexec/gnubin" for formula in macos_host.GNUBIN_FORMULAE]
    assert path[:len(gnubin)] == gnubin              # GNU tools first...
    assert path.index(f"{brew}/bin") < path.index(sysdir)     # ...then bash 5, then BSD
    assert macos_host.gnu_userland_missing() == []
    assert _refusal() == ""


def test_without_the_hook_the_text_ui_is_refused(brewed_mac, monkeypatch):
    """The defect, reproduced by taking the call back out."""
    sysdir, _brew = brewed_mac
    monkeypatch.setattr(entry, "bootstrap", lambda: [])
    assert _run_text_ui() == 2
    assert os.environ["PATH"] == sysdir
    assert "this Mac is missing" in _refusal()


def test_the_window_entry_makes_the_same_call(brewed_mac):
    sysdir, brew = brewed_mac
    assert entry.bootstrap()                         # what app.main calls
    assert os.environ["PATH"].split(os.pathsep)[-1] == sysdir
    assert entry.bootstrap() == []                   # idempotent
    assert _refusal() == ""


def test_bootstrap_does_nothing_off_macos(monkeypatch):
    monkeypatch.setattr(macos_host, "is_macos", lambda sysplatform=None: False)
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    assert entry.bootstrap() == []
    assert os.environ["PATH"] == "/usr/bin:/bin"


# ── the order inside each main ──────────────────────────────────────────────────────
def test_the_text_ui_installs_the_hook_before_it_parses_or_probes():
    src = inspect.getsource(tui_app.main)
    hook = src.index("entry.bootstrap()")
    assert src.index("crashlog.install()") < hook < src.index("ap = argparse.ArgumentParser")
    assert hook < src.index("secret_files.startup_sweep()")


def test_the_window_installs_the_hook_before_it_parses_or_probes():
    src = inspect.getsource(app.main)
    assert src.index("flatpak_host.install()") < src.index("entry.bootstrap()") \
        < src.index("ap = argparse.ArgumentParser")


# ── every __main__ block in the package ─────────────────────────────────────────────
#: Entries whose ``__main__`` block only calls a ``main`` that makes the call itself.
#: file -> (module holding that main, its name).
_DELEGATES = {
    "__main__.py": (app, "main"),
    "app.py": (app, "main"),
    "tui/__main__.py": (tui_app, "main"),
    "tui/app.py": (tui_app, "main"),
}


def _main_blocks():
    """(relative path, the ``if __name__ == "__main__"`` node) for every module-level
    one in the package."""
    for root, _dirs, files in os.walk(PACKAGE):
        for name in sorted(files):
            if not name.endswith(".py"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as fh:
                tree = ast.parse(fh.read())
            for node in tree.body:
                if (isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
                        and isinstance(node.test.left, ast.Name)
                        and node.test.left.id == "__name__"):
                    yield os.path.relpath(path, PACKAGE).replace(os.sep, "/"), node


def _calls_bootstrap(node: ast.AST) -> bool:
    """The block imports ``bootstrap`` from core/entry and calls it."""
    imported = set()
    for sub in ast.walk(node):
        if isinstance(sub, ast.ImportFrom) and (sub.module or "").endswith("entry"):
            imported |= {a.asname or a.name for a in sub.names if a.name == "bootstrap"}
    return any(isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name)
               and sub.func.id in imported for sub in ast.walk(node))


def test_every_main_block_in_the_package_installs_the_hook():
    blocks = dict(_main_blocks())
    # the scan sees the entries the finding named, and the rest
    assert {"core/emulation.py", "core/cloud_deploy.py", "tui/app.py", "app.py",
            "core/local_mesh_bootstrap.py"} <= set(blocks), sorted(blocks)
    assert len(blocks) >= 22, sorted(blocks)
    missing = []
    for rel, node in sorted(blocks.items()):
        if rel in _DELEGATES:
            module, fn = _DELEGATES[rel]
            if "entry.bootstrap()" not in inspect.getsource(getattr(module, fn)):
                missing.append(f"{rel} (its {fn}() does not call entry.bootstrap())")
        elif not _calls_bootstrap(node):
            missing.append(rel)
    assert not missing, (
        "these entries start without core/entry.bootstrap(), so on a Mac they do not "
        f"find Homebrew's GNU tools: {missing}")
    assert set(_DELEGATES) <= set(blocks), sorted(set(_DELEGATES) - set(blocks))


def test_the_hook_is_the_first_statement_of_each_module_main_block():
    """Before the block's own ``main()``: a probe made first would cache "missing"."""
    late = []
    for rel, node in _main_blocks():
        if rel in _DELEGATES:
            continue
        first_two = node.body[:2]
        if not (len(first_two) == 2 and isinstance(first_two[0], ast.ImportFrom)
                and isinstance(first_two[1], ast.Expr)
                and isinstance(first_two[1].value, ast.Call)
                and getattr(first_two[1].value.func, "id", "") == "_bootstrap"):
            late.append(rel)
    assert not late, late
