"""The Windows installer's build inputs must exist, be tracked, and say what the app needs.

``.github/workflows/studio-release.yml`` runs ``pyinstaller packaging/hugmesh-studio.spec``.
That file did not exist in any checkout: ``studio/.gitignore`` carried a blanket
``*.spec`` that ignored it, so the job could not have got past its freeze step on any
runner. Nothing in the suite looked, because nothing in the suite ever runs the
installer build. This file is the part of that build that can be checked in a second,
with no Qt, no Wine, no Docker and no network:

  * the spec exists, git would not ignore it, and it names the frozen entry shim
    (``__main__.py`` is the wrong entry: a relative import fails when frozen);
  * RUN as Python against a stand-in for PyInstaller, it asks for what the app needs:
    every ``[tool.setuptools.package-data]`` file (the four non-Python files whose
    absence kills the app at import), tzdata, no second Qt binding, a windowed exe;
  * ``build-msi-wine.sh`` exists, is executable IN GIT (mode 100755, not just on this
    disk) and refuses to go near ``~/.wine``;
  * the MSI verifier (``wix/verify_msi.py``) turns red for each thing it claims to
    check, and the pip lock and the Wine ICU shim are what their docstrings say.

What none of it proves: that the frozen app starts or that the MSI installs. Those need
the Wine run in ``build-msi-wine.sh`` (and a real Windows machine for the second one).
"""
from __future__ import annotations

import ast
import importlib.util
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import types
import xml.dom.minidom

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(STUDIO_ROOT)
PACKAGING = os.path.join(STUDIO_ROOT, "packaging")
WIX = os.path.join(PACKAGING, "wix")
SPEC = os.path.join(PACKAGING, "hugmesh-studio.spec")
SCRIPT = os.path.join(PACKAGING, "build-msi-wine.sh")
SPEC_REL = "studio/packaging/hugmesh-studio.spec"
SCRIPT_REL = "studio/packaging/build-msi-wine.sh"

needs_tomllib = pytest.mark.skipif(
    sys.version_info < (3, 11),
    reason="the spec reads pyproject.toml with tomllib (Python 3.11+); the installer build uses 3.12")


def _load(path: str, name: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module          # dataclass/annotation lookups want it registered
    spec.loader.exec_module(module)
    return module


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", REPO_ROOT, *args], capture_output=True, text=True)


def _in_git_checkout() -> bool:
    return os.path.exists(os.path.join(REPO_ROOT, ".git")) and shutil.which("git") is not None


# ── the spec exists, is tracked-able, and names the frozen entry shim ───────────────────
def test_the_spec_exists():
    assert os.path.isfile(SPEC), (
        f"{SPEC} is missing. The workflow's `pyinstaller packaging/hugmesh-studio.spec` "
        "has nothing to run without it.")


def test_git_does_not_ignore_the_spec():
    """THE DEFECT. ``*.spec`` in studio/.gitignore ignored this hand-written file, so it
    could never be committed. ``--no-index`` asks what the rules say about the path even
    once it is tracked (a tracked file is exempt from the rules, which would hide the
    day somebody deletes the negation and the NEXT regenerated spec cannot be added)."""
    if not _in_git_checkout():
        pytest.skip("not a git checkout (a source tarball): there are no ignore rules to ask")
    r = _git("check-ignore", "--no-index", "-q", SPEC_REL)
    # 1 = not ignored. 0 = ignored. Anything else (128) is git failing, NOT a pass.
    assert r.returncode == 1, (
        f"git check-ignore exited {r.returncode} for {SPEC_REL}: "
        + ("it IS ignored. studio/.gitignore needs `!packaging/hugmesh-studio.spec` after "
           "`*.spec`" if r.returncode == 0 else f"git itself failed: {r.stderr.strip()}"))


def test_the_ignore_rule_is_narrow():
    """The negation names ONE file. PyInstaller still writes throwaway specs wherever it
    is run, and those must stay ignored."""
    if not _in_git_checkout():
        pytest.skip("not a git checkout")
    for stray in ("studio/other.spec", "studio/packaging/other.spec", "studio/hugmesh-studio.spec"):
        r = _git("check-ignore", "--no-index", "-q", stray)
        assert r.returncode == 0, f"{stray} should still be ignored (git check-ignore exited {r.returncode})"


def _spec_text() -> str:
    with open(SPEC, encoding="utf-8") as fh:
        return fh.read()


def test_the_spec_is_valid_python_and_names_the_entry_shim():
    ast.parse(_spec_text())                              # a syntax error is a dead installer job
    assert re.search(r'ENTRY\s*=\s*os\.path\.join\(PACKAGING_DIR,\s*"run_studio\.py"\)', _spec_text()), (
        "the spec must take packaging/run_studio.py as its entry script (hugmesh_studio/__main__.py "
        "does a relative import and cannot be a frozen entry point)")


def test_the_entry_shim_exists_and_imports_absolutely():
    shim = os.path.join(PACKAGING, "run_studio.py")
    assert os.path.isfile(shim)
    body = open(shim, encoding="utf-8").read()
    assert "from hugmesh_studio.app import main" in body
    assert not re.search(r"^from \.", body, re.M), "a relative import in the entry script fails when frozen"


# ── the spec, RUN against a stand-in for PyInstaller ────────────────────────────────────
class _Rec:
    """Stands in for Analysis/PYZ/EXE/COLLECT: remembers how it was called."""
    log: list = []

    def __init__(self, kind):
        self.kind = kind
        self.pure, self.scripts, self.binaries, self.datas = [], [], [], []

    def __call__(self, *args, **kwargs):
        rec = _Rec(self.kind)
        rec.args, rec.kwargs = args, kwargs
        _Rec.log.append(rec)
        return rec


def _run_spec(monkeypatch, icon=None, tz=("datas", "binaries", "hidden"), spec=None,
              platform="linux"):
    """Execute the spec and return {kind: FIRST recorded call}, plus "EXES": every EXE
    in order. ``tz`` is what collect_all ("tzdata") hands back: a truthy datas list is
    "tzdata is installed". ``platform`` is the sys.platform the spec sees (the console
    twin exists only on "win32"), so the answer does not depend on the test host."""
    monkeypatch.setattr(sys, "platform", platform)
    _Rec.log = []
    hooks = types.ModuleType("PyInstaller.utils.hooks")
    hooks.collect_all = lambda name: (
        ([("tzdata-file", "tzdata")] if tz[0] else []),
        [("tzdata-bin", ".")] if tz[1] else [], ["tzdata.zoneinfo"] if tz[2] else [])
    for name, mod in (("PyInstaller", types.ModuleType("PyInstaller")),
                      ("PyInstaller.utils", types.ModuleType("PyInstaller.utils")),
                      ("PyInstaller.utils.hooks", hooks)):
        monkeypatch.setitem(sys.modules, name, mod)
    if icon is None:
        monkeypatch.delenv("HUGMESH_STUDIO_ICON", raising=False)
    else:
        monkeypatch.setenv("HUGMESH_STUDIO_ICON", icon)
    path = spec or SPEC
    namespace = {"SPECPATH": os.path.dirname(path), "__name__": "spec",
                 **{k: _Rec(k) for k in ("Analysis", "PYZ", "EXE", "COLLECT")}}
    exec(compile(open(path, encoding="utf-8").read(), path, "exec"), namespace)
    calls = {}
    for r in _Rec.log:
        calls.setdefault(r.kind, r)
    calls["EXES"] = [r for r in _Rec.log if r.kind == "EXE"]
    return calls


def _package_data_files() -> set[tuple[str, str]]:
    import glob
    import tomllib
    with open(os.path.join(STUDIO_ROOT, "pyproject.toml"), "rb") as fh:
        table = tomllib.load(fh)["tool"]["setuptools"]["package-data"]
    out = set()
    for package, patterns in table.items():
        pkg_dir = os.path.join(STUDIO_ROOT, *package.split("."))
        for pattern in patterns:
            for hit in glob.glob(os.path.join(pkg_dir, pattern)):
                out.add((os.path.relpath(hit, STUDIO_ROOT).replace(os.sep, "/"), package.replace(".", "/")))
    return out


@needs_tomllib
def test_the_spec_freezes_the_entry_shim_as_a_windowed_onedir(monkeypatch):
    calls = _run_spec(monkeypatch)
    analysis, exe, coll = calls["Analysis"], calls["EXE"], calls["COLLECT"]
    assert analysis.args[0] == [os.path.join(PACKAGING, "run_studio.py")]
    assert exe.kwargs["console"] is False, "windowed: no console window"
    assert exe.kwargs["name"] == "hugmesh-studio"
    assert exe.kwargs["exclude_binaries"] is True, "onedir (binaries go in COLLECT), not onefile"
    assert exe.kwargs["upx"] is False
    assert coll.kwargs["name"] == "hugmesh-studio", "dist/hugmesh-studio/ is where the MSI harvests"
    assert [e.kwargs["name"] for e in calls["EXES"]] == ["hugmesh-studio"], (
        "Linux freezes one executable: the tarball has no subsystem split")


@needs_tomllib
def test_windows_also_freezes_a_console_twin_into_the_same_tree(monkeypatch):
    """The windowed exe has no stdout when started from a shell, so every CLI flag
    printed nothing on Windows. The twin is the same app with a console."""
    calls = _run_spec(monkeypatch, platform="win32")
    gui, cli = calls["EXES"]
    assert (gui.kwargs["name"], gui.kwargs["console"]) == ("hugmesh-studio", False)
    assert (cli.kwargs["name"], cli.kwargs["console"]) == ("hugmesh-studio-cli", True)
    assert cli.kwargs["exclude_binaries"] is True and cli.kwargs["upx"] is False
    assert cli.args[:2] == gui.args[:2], "same PYZ and scripts: one app, two subsystems"
    assert cli in calls["COLLECT"].args and gui in calls["COLLECT"].args, (
        "both must land in dist/hugmesh-studio/, the tree Files.wxs packs")


@needs_tomllib
def test_the_spec_bundles_every_package_data_file(monkeypatch):
    """The frozen app reads these four files from beside its own modules and does not
    degrade without them: it fails in `import hugmesh_studio.core.config`."""
    wanted = _package_data_files()
    assert len(wanted) >= 4, "pyproject.toml's package-data table shrank; this test needs reading"
    datas = {(os.path.relpath(src, STUDIO_ROOT).replace(os.sep, "/"), dest.replace(os.sep, "/"))
             for src, dest in _run_spec(monkeypatch)["Analysis"].kwargs["datas"]
             if os.path.isabs(src)}
    missing = sorted(wanted - datas)
    assert not missing, f"datas does not carry: {missing}"
    for src, dest in wanted:                       # and each lands beside the module that reads it
        assert dest.startswith("hugmesh_studio/")


@needs_tomllib
def test_the_spec_bundles_the_whole_package(monkeypatch):
    modules = set(_run_spec(monkeypatch)["Analysis"].kwargs["hiddenimports"])
    for must in ("hugmesh_studio.app", "hugmesh_studio.core.config", "hugmesh_studio.core.roles",
                 "hugmesh_studio.gui.wizard", "hugmesh_studio.gui.pages.welcome", "hugmesh_studio.tui"):
        assert must in modules, f"{must} is not in the frozen package"
    on_disk = 0
    for root, dirs, files in os.walk(os.path.join(STUDIO_ROOT, "hugmesh_studio")):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        on_disk += sum(1 for f in files if f.endswith(".py"))
    assert len(modules) >= on_disk - 1, "the spec skipped some of the package's modules"


@needs_tomllib
def test_the_spec_never_freezes_a_second_qt_binding(monkeypatch):
    """pyproject.toml: "the PyInstaller spec excludes PyQt6". PyQt6 is GPL; PySide6 is LGPL."""
    excludes = set(_run_spec(monkeypatch)["Analysis"].kwargs["excludes"])
    assert {"PyQt6", "PyQt5", "PySide2"} <= excludes


@needs_tomllib
def test_the_spec_collects_tzdata_and_refuses_to_build_without_it(monkeypatch):
    analysis = _run_spec(monkeypatch)["Analysis"].kwargs
    assert ("tzdata-file", "tzdata") in analysis["datas"]
    assert "tzdata.zoneinfo" in analysis["hiddenimports"]
    with pytest.raises(SystemExit) as exc:         # core/timezones.py would silently shrink to 50 zones
        _run_spec(monkeypatch, tz=(None, None, None))
    assert "tzdata" in str(exc.value)


@needs_tomllib
def test_the_icon_comes_from_the_environment_and_a_missing_one_is_an_error(monkeypatch, tmp_path):
    assert _run_spec(monkeypatch)["EXE"].kwargs["icon"] is None
    ico = tmp_path / "x.ico"
    ico.write_bytes(b"\0")
    monkeypatch.chdir(tmp_path)                    # resolved against the WORKING directory, as CI passes it
    assert _run_spec(monkeypatch, icon="x.ico")["EXE"].kwargs["icon"] == str(ico)
    with pytest.raises(SystemExit) as exc:         # not a quiet fallback to the generic icon
        _run_spec(monkeypatch, icon="nope.ico")
    assert "does not exist" in str(exc.value)


@needs_tomllib
def test_a_package_data_row_that_matches_nothing_fails_the_build(monkeypatch, tmp_path):
    """setuptools ignores such a row and ships nothing; a frozen app missing the file cannot start."""
    studio = tmp_path / "studio"
    (studio / "packaging").mkdir(parents=True)
    (studio / "hugmesh_studio" / "core").mkdir(parents=True)
    (studio / "pyproject.toml").write_text(
        '[tool.setuptools.package-data]\n"hugmesh_studio.core" = ["gone.json"]\n')
    shutil.copy(SPEC, studio / "packaging" / "hugmesh-studio.spec")
    with pytest.raises(SystemExit) as exc:
        _run_spec(monkeypatch, spec=str(studio / "packaging" / "hugmesh-studio.spec"))
    assert "matches no file" in str(exc.value)


# ── the build script ────────────────────────────────────────────────────────────────────
def test_the_build_script_exists_and_is_executable_on_disk():
    assert os.path.isfile(SCRIPT), f"{SCRIPT} is missing"
    assert os.access(SCRIPT, os.X_OK), f"{SCRIPT} is not executable (chmod +x)"


def test_the_build_script_is_executable_in_git():
    """A mode that is right on this disk and 100644 in the index ships a script that
    cannot be run from a fresh clone."""
    if not _in_git_checkout():
        pytest.skip("not a git checkout")
    r = _git("ls-files", "-s", "--", SCRIPT_REL)
    if not r.stdout.strip():
        pytest.skip("build-msi-wine.sh is not tracked yet (git add it); the on-disk check above still ran")
    assert r.stdout.split()[0] == "100755", f"git has {SCRIPT_REL} as {r.stdout.split()[0]}, want 100755"


def test_the_build_script_parses_with_bash():
    r = subprocess.run(["bash", "-n", SCRIPT], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def _sandbox_path(tmp_path) -> str:
    """A PATH whose first folder holds look-alikes of the tools the script drives, each of
    which refuses to run. These tests may only ever reach the script's own guards and its
    functions. They once could do more: a mutation that let `main` run while the file was
    merely sourced started the REAL build in seven pytest temp directories (a Wine prefix,
    downloads, about 5 GB in /tmp) and filled the root filesystem. Now `curl`, `wine`,
    `docker` and `Xvfb` cannot start from here, whatever the script under test does."""
    shims = tmp_path / "shims"
    shims.mkdir(exist_ok=True)
    for tool in ("wine", "wineserver", "wineboot", "curl", "docker", "Xvfb", "xdotool", "import"):
        shim = shims / tool
        shim.write_text(f'#!/bin/sh\necho "SHIM: {tool} must not run inside a unit test" >&2\nexit 99\n')
        shim.chmod(0o755)
    return f"{shims}{os.pathsep}{os.environ['PATH']}"


def _run_script(tmp_path, *args, **env):
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    base = {"PATH": _sandbox_path(tmp_path), "HOME": str(home),
            "HUGMESH_MSI_WORKDIR": str(tmp_path / "work")}
    base.update({k: str(v) for k, v in env.items()})
    return subprocess.run(["bash", SCRIPT, *args], capture_output=True, text=True, env=base, timeout=60)


def test_the_build_script_refuses_the_default_wine_prefix(tmp_path):
    """Before the first wine call, and however the path is spelled."""
    (tmp_path / "home" / ".wine").mkdir(parents=True)
    for spelling in ("{h}/.wine", "{h}/./.wine/../.wine", "{h}/.wine/inner"):
        r = _run_script(tmp_path, "fetch", HUGMESH_WINE_PREFIX=spelling.format(h=tmp_path / "home"))
        assert r.returncode != 0, spelling
        assert "default Wine prefix" in r.stderr, (spelling, r.stderr)
    assert not (tmp_path / "work").exists(), "it must stop before creating anything"


def test_the_build_script_refuses_a_wine_prefix_it_did_not_create(tmp_path):
    foreign = tmp_path / "somebodys-prefix"
    foreign.mkdir()
    (foreign / "system.reg").write_text("WINE REGISTRY Version 2\n")
    r = _run_script(tmp_path, "fetch", HUGMESH_WINE_PREFIX=foreign)
    assert r.returncode != 0 and "was not created by this script" in r.stderr, r.stderr
    assert (foreign / "system.reg").exists()


def test_the_build_script_help_and_unknown_phase(tmp_path):
    ok = _run_script(tmp_path, "--help")
    assert ok.returncode == 0 and "PHASES" in ok.stdout + ok.stderr
    bad = _run_script(tmp_path, "frobnicate")
    assert bad.returncode != 0 and "unknown phase" in bad.stderr


def test_every_download_in_the_build_script_is_pinned_by_hash():
    text = open(SCRIPT, encoding="utf-8").read()
    for url_var, hash_var, length in (("PYTHON_URL", "PYTHON_SHA256", 64), ("DOTNET_URL", "DOTNET_SHA512", 128),
                                      ("WIX_URL", "WIX_SHA512", 128), ("WIXUI_URL", "WIXUI_SHA512", 128)):
        assert re.search(rf"^{url_var}=https://\S+$", text, re.M), url_var
        assert re.search(rf"^{hash_var}=[0-9a-f]{{{length}}}$", text, re.M), f"{hash_var} is not a {length}-hex pin"
    assert re.search(r"^MSITOOLS_IMAGE=debian@sha256:[0-9a-f]{64}$", text, re.M), "the msitools image must be pinned by digest"
    assert "WIX_VERSION=6.0.2" in text, "WiX 7 needs an EULA acceptance; this build pins the last release without one"
    for line in text.splitlines():                  # no `latest`, no unpinned dotnet tool install
        if line.lstrip().startswith("#"):
            continue
        assert "dotnet tool install" not in line and "wix harvest" not in line, line


def _bash(snippet, tmp_path, **env):
    """Run a snippet with build-msi-wine.sh SOURCED: its functions exist, `main` does not run."""
    base = {"PATH": _sandbox_path(tmp_path), "HOME": str(tmp_path), "HUGMESH_MSI_WORKDIR": str(tmp_path / "work")}
    base.update({k: str(v) for k, v in env.items()})
    return subprocess.run(["bash", "-c", f'source "{SCRIPT}"; {snippet}'], capture_output=True, text=True,
                          env=base, timeout=60)


def test_sourcing_the_build_script_runs_nothing(tmp_path):
    r = _bash("true", tmp_path)
    assert r.returncode == 0 and r.stdout == "" and r.stderr == ""
    assert not (tmp_path / "work").exists(), "sourcing must not create the work directory"


def test_the_ui_font_is_found_in_the_first_folder_that_has_both_faces(tmp_path):
    only_regular, both, also_both = tmp_path / "a", tmp_path / "b", tmp_path / "c"
    for d in (only_regular, both, also_both):
        d.mkdir()
    (only_regular / "tahoma.ttf").write_bytes(b"x")
    for d in (both, also_both):
        (d / "tahoma.ttf").write_bytes(b"x")
        (d / "tahomabd.ttf").write_bytes(b"x")
    found = _bash(f'find_wine_fonts_dir "{tmp_path}/nope" "{only_regular}" "{both}" "{also_both}"', tmp_path)
    assert found.returncode == 0 and found.stdout == str(both)
    none = _bash(f'find_wine_fonts_dir "{tmp_path}/nope" "{only_regular}"', tmp_path)
    assert none.returncode == 1 and none.stdout == "", "a folder with only the regular face must not be accepted"


def test_the_font_override_is_tried_first(tmp_path):
    r = _bash("wine_fonts_candidates | head -n 1", tmp_path, HUGMESH_WINE_FONT_DIR="/somewhere/else")
    assert r.stdout.strip() == "/somewhere/else"


def test_stage_ui_font_copies_both_faces_where_the_icon_step_looks(tmp_path):
    fonts = tmp_path / "wine-fonts"
    fonts.mkdir()
    (fonts / "tahoma.ttf").write_bytes(b"regular")
    (fonts / "tahomabd.ttf").write_bytes(b"bold")
    r = _bash("guard_prefix; stage_ui_font", tmp_path, HUGMESH_WINE_FONT_DIR=fonts)
    staged = tmp_path / "work" / "build" / "fonts"
    assert r.returncode == 0, r.stderr
    assert (staged / "tahoma.ttf").read_bytes() == b"regular" and (staged / "tahomabd.ttf").read_bytes() == b"bold"


def test_stage_ui_font_refuses_when_wine_has_no_tahoma(tmp_path):
    # The candidate list is replaced: on a machine with Wine installed the real system folders
    # would (rightly) be found after the override.
    r = _bash(f'wine_fonts_candidates() {{ echo "{tmp_path}/nowhere"; }}; stage_ui_font', tmp_path)
    assert r.returncode != 0 and "cannot find Wine's tahoma.ttf and tahomabd.ttf" in r.stderr, r.stderr


def test_the_icon_wrapper_checks_its_fonts_before_touching_qt(tmp_path):
    """It must fail fast and clearly, not as an ImportError for a Qt this machine lacks."""
    wrapper = os.path.join(WIX, "render_icon_wine.py")
    r = subprocess.run([sys.executable, wrapper, "--out", str(tmp_path / "icons")], capture_output=True,
                       text=True, env={"PATH": os.environ["PATH"], "HUGMESH_ICON_FONT_DIR": str(tmp_path)})
    assert r.returncode == 2 and "tahoma.ttf, tahomabd.ttf not found" in r.stderr, (r.returncode, r.stderr)
    assert "Traceback" not in r.stderr


def test_the_icon_wrapper_sets_up_what_wine_lacks_and_runs_gen_icons_unchanged():
    """Its Qt half cannot run in this suite, so pin what it must do by reading it: Qt's
    windows platform (offscreen has no fonts), both Tahoma faces loaded, an application font
    set, and the real gen_icons.py run as written rather than a copy of it."""
    text = open(os.path.join(WIX, "render_icon_wine.py"), encoding="utf-8").read()
    ast.parse(text)
    assert 'os.environ["QT_QPA_PLATFORM"] = "windows"' in text
    assert 'FACES = ("tahoma.ttf", "tahomabd.ttf")' in text and "addApplicationFont" in text
    assert 'app.setFont(QtGui.QFont("Tahoma"' in text
    assert 'runpy.run_path(gen_icons, run_name="__main__")' in text
    assert os.path.isfile(os.path.join(PACKAGING, "gen_icons.py")), "the wrapper runs this file"


def _wine_stub(tmp_path):
    """A stand-in for `wine` that converts paths like winepath and otherwise records the
    environment the Windows process would have seen. Referenced by absolute path, so the
    sandbox's refusing shims (which sit first on PATH) are not involved."""
    out = tmp_path / "stub.env"
    stub = tmp_path / "stubwine"
    stub.write_text('#!/bin/sh\nif [ "$1" = winepath ]; then printf "Z:%s\\n" "$3"; exit 0; fi\n'
                    'env | sort > "$STUB_OUT"\nexit 0\n')
    stub.chmod(0o755)
    return stub, out


def _seen_by_windows(out) -> dict[str, str]:
    return dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)


def test_the_icon_step_hands_the_windows_process_its_font_folder(tmp_path):
    """The first version set this with a command-prefix array assignment, which bash does not
    apply: the wrapper got no font folder and the freeze died at the icon step."""
    stub, out = _wine_stub(tmp_path)
    r = _bash('guard_prefix; mkdir -p "$LOGS"; render_icon', tmp_path, HUGMESH_WINE=stub, STUB_OUT=out)
    assert r.returncode == 0, r.stderr
    seen = _seen_by_windows(out)
    assert seen.get("HUGMESH_ICON_FONT_DIR") == f"Z:{tmp_path}/work/build/fonts", seen.get("HUGMESH_ICON_FONT_DIR")


def test_wine_run_scrubs_the_callers_environment_but_keeps_what_was_asked_for(tmp_path):
    """HUGMESH_ROLES_LIB would point a frozen app at a checkout, and an ambient QT_QPA_PLATFORM=xcb
    is wrong for Windows Qt; neither may reach the Windows process. Extras are applied AFTER
    the scrub, so a variable can be both exported by the user and deliberately passed."""
    stub, out = _wine_stub(tmp_path)
    r = _bash('refresh_scrub; WINE_ENV_EXTRA=(HUGMESH_KEEP=yes); wine_run anything', tmp_path, HUGMESH_WINE=stub,
              STUB_OUT=out, HUGMESH_ROLES_LIB="/leak/roles.sh", HUGMESH_KEEP="no", QT_QPA_PLATFORM="xcb")
    assert r.returncode == 0, r.stderr
    seen = _seen_by_windows(out)
    assert "HUGMESH_ROLES_LIB" not in seen and "QT_QPA_PLATFORM" not in seen, seen
    assert seen.get("HUGMESH_KEEP") == "yes"
    assert seen.get("WINEPREFIX") == f"{tmp_path}/work/wine-prefix"
    assert seen.get("WINEDLLOVERRIDES") == "mshtml=,winemenubuilder.exe=d", "winemenubuilder must stay off"


def _smoke_stub(tmp_path):
    """A stand-in for wine that plays the part of the frozen exe: for `cmd /c run.cmd` it
    leaves whatever $STUB_SPECS names in specs.json (nothing if unset), for
    `cmd /c run-source.cmd` it writes $STUB_SOURCE to source-specs.json, and it exits
    $STUB_RC. winepath is a pass-through."""
    stub = tmp_path / "smokewine"
    stub.write_text(
        '#!/bin/sh\n'
        'case "$1" in\n'
        '  winepath) printf "Z:%s\\n" "$3"; exit 0 ;;\n'
        '  cmd) case "$3" in\n'
        '         run.cmd) [ -n "${STUB_SPECS:-}" ] && cp "$STUB_SPECS" specs.json; exit "${STUB_RC:-0}" ;;\n'
        '         run-source.cmd) [ -n "${STUB_SOURCE:-}" ] && cp "$STUB_SOURCE" source-specs.json; exit 0 ;;\n'
        '       esac ;;\n'
        'esac\n'
        'exit 0\n')
    stub.chmod(0o755)
    return stub


GOOD_SPECS = '{"brand": "hugmesh", "platform": "x86", "jobs": 2}\r\n'


@pytest.mark.parametrize("scenario,specs,source,rc,verdict", [
    ("passes when the frozen output equals the source output", GOOD_SPECS, GOOD_SPECS, 0, "== from-source"),
    ("an EMPTY --print-specs fails", "", GOOD_SPECS, 0, "specs.json is empty"),
    ("no output file at all fails", None, GOOD_SPECS, 0, "specs.json is empty"),
    ("text that is not JSON fails", "Traceback (most recent call last)\r\n", GOOD_SPECS, 0, "not JSON"),
    ("an empty JSON object fails", "{}\r\n", GOOD_SPECS, 0, "non-empty JSON object"),
    ("JSON that differs from the source's fails", '{"brand": "other"}\r\n', GOOD_SPECS, 0, "differ in"),
    ("nothing to compare with fails (a smoke that cannot compare proves less)", GOOD_SPECS, None, 0, "nothing to compare"),
    ("a hang (timeout's 124) fails", GOOD_SPECS, GOOD_SPECS, 124, "124 = hung"),
    ("a crash exit fails even with output", GOOD_SPECS, GOOD_SPECS, 3, "exited 3"),
])
def test_the_print_specs_smoke_passes_only_on_non_empty_json_equal_to_the_source(tmp_path, scenario, specs, source, rc, verdict):
    stub = _smoke_stub(tmp_path)
    env = {"HUGMESH_WINE": stub, "STUB_RC": rc}
    for key, content in (("STUB_SPECS", specs), ("STUB_SOURCE", source)):
        if content is not None:
            path = tmp_path / key
            path.write_text(content)
            env[key] = path
    app = tmp_path / "app"
    app.mkdir()
    (app / "hugmesh-studio.exe").write_bytes(b"MZ")
    r = _bash(f'refresh_scrub; SRC="{tmp_path}/src"; mkdir -p "$SRC/studio" "$BUILD"; wine_stop() {{ :; }}; smoke_cli "{app}"',
              tmp_path, **env)
    # stdout only: the script's ERR trap writes to stderr and (before it was shortened) echoed
    # the whole failing here-document, which contained these very phrases.
    out = r.stdout
    if scenario.startswith("passes"):
        assert r.returncode == 0 and verdict in out, (r.returncode, out, r.stderr)
    else:
        assert r.returncode == 1 and verdict in out, (scenario, r.returncode, out, r.stderr)


def _onedir(root, extra=()):
    """A minimal frozen tree that tree_check accepts."""
    files = ["hugmesh-studio.exe", "_internal/hugmesh_studio/core/progress-tables.json",
             "_internal/tzdata/zoneinfo/Europe/Berlin", "_internal/tzdata/zones",
             "_internal/PySide6/plugins/platforms/qwindows.dll", "_internal/PySide6/MSVCP140.dll", *extra]
    for rel in files:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")
    return root


def _tree_check(tmp_path, app):
    # expected_data_files normally asks the Windows Python under Wine; here: one known file.
    return _bash(f'expected_data_files() {{ echo hugmesh_studio/core/progress-tables.json; }}; tree_check "{app}"', tmp_path)


def test_tree_check_accepts_a_complete_tree(tmp_path):
    r = _tree_check(tmp_path, _onedir(tmp_path / "good"))
    assert r.returncode == 0 and r.stdout == "", r.stdout


@pytest.mark.parametrize("missing,says", [
    ("hugmesh-studio.exe", "hugmesh-studio.exe"),
    ("_internal/hugmesh_studio/core/progress-tables.json", "package data"),
    ("_internal/tzdata/zoneinfo/Europe/Berlin", "tzdata"),
    ("_internal/tzdata/zones", "tzdata/zones"),
    ("_internal/PySide6/plugins/platforms/qwindows.dll", "qwindows.dll"),
    ("_internal/PySide6/MSVCP140.dll", "msvcp140")])
def test_tree_check_names_each_missing_file(tmp_path, missing, says):
    app = _onedir(tmp_path / "app")
    (app / missing).unlink()
    r = _tree_check(tmp_path, app)
    assert r.returncode == 1 and says in r.stdout, (missing, r.stdout)


@pytest.mark.parametrize("extra,says", [
    ("_internal/PySide6/icuuc.dll", "icuuc.dll"), ("_internal/ICUUC.DLL", "icuuc.dll"),
    ("_internal/PyQt6/QtCore.pyd", "PyQt")])
def test_tree_check_refuses_what_must_never_ship(tmp_path, extra, says):
    """The Wine-only ICU forwarder must not reach the installer, and PyQt6 is GPL."""
    r = _tree_check(tmp_path, _onedir(tmp_path / "app", extra=[extra]))
    assert r.returncode == 1 and says in r.stdout, r.stdout


# ── the WiX sources agree with each other ───────────────────────────────────────────────
def test_files_wxs_harvests_into_the_group_package_wxs_references():
    xml.dom.minidom.parse(os.path.join(WIX, "Files.wxs"))          # well-formed (XML bans `--` in comments)
    files = open(os.path.join(WIX, "Files.wxs"), encoding="utf-8").read()
    package = open(os.path.join(WIX, "Package.wxs"), encoding="utf-8").read()
    assert re.search(r'<ComponentGroup Id="AppFiles" Directory="INSTALLFOLDER">\s*<Files Include="\$\(AppDir\)\\\*\*"\s*/>', files)
    assert '<ComponentGroupRef Id="AppFiles"' in package
    assert 'Directory Id="INSTALLFOLDER"' in package
    assert "..\\..\\dist\\hugmesh-studio" in files, "the default AppDir must be the layout the workflow produces"
    for var in ("Version", "IconFile", "LicenseFile"):
        assert f"$(var.{var})" in package
    assert "SourceDir" not in package.split("-->", 1)[1], "Package.wxs still reads a SourceDir nothing defines"


def test_package_wxs_keeps_the_permanent_upgrade_code():
    package = open(os.path.join(WIX, "Package.wxs"), encoding="utf-8").read()
    assert 'UpgradeCode="7a3b6f18-2c94-4f0d-9a51-6d8e2b4c7f31"' in package, \
        "the UpgradeCode identifies the product across every release; it must never change"


# ── the pip lock ────────────────────────────────────────────────────────────────────────
def _lock_module():
    return _load(os.path.join(WIX, "lock_windows_build.py"), "lock_windows_build")


def test_the_committed_lock_hashes_every_package():
    mod = _lock_module()
    text = open(os.path.join(WIX, "windows-build-requirements.txt"), encoding="utf-8").read()
    entries = mod.parse_lock(text)
    names = {mod.normalize(n) for n, _v, _h in entries}
    assert {"pyside6", "pyinstaller", "pillow", "tzdata"} <= names, "a top-level build dependency is not locked"
    for name, version, hashes in entries:
        assert hashes, f"{name}=={version} has no hash, so pip --require-hashes would refuse the whole file"
        assert all(re.fullmatch(r"[0-9a-f]{64}", h) for h in hashes)
    assert [mod.normalize(n) for n, _v, _h in entries] == sorted(mod.normalize(n) for n, _v, _h in entries)


def test_the_lock_helper_reads_freeze_output_and_picks_installable_wheels():
    mod = _lock_module()
    assert mod.parse_freeze("pip==25.0\nPySide6_Addons==6.11.2\n# c\n\ntzdata==2026.4\n") == [
        ("PySide6_Addons", "6.11.2"), ("tzdata", "2026.4")]
    with pytest.raises(SystemExit):
        mod.parse_freeze("hugmesh @ git+https://example.invalid/x\n")
    ok = ["pyside6-6.11.2-cp310-abi3-win_amd64.whl", "tzdata-2026.4-py2.py3-none-any.whl",
          "pillow-12.3.0-cp312-cp312-win_amd64.whl", "pyinstaller-6.22.3-py3-none-win_amd64.whl"]
    no = ["pillow-12.3.0-cp311-cp311-win_amd64.whl", "pillow-12.3.0-cp312-cp312-win32.whl",
          "pillow-12.3.0-cp312-cp312-manylinux_2_28_x86_64.whl", "x-1.0-cp313-abi3-win_amd64.whl",
          "x-1.0.tar.gz"]
    assert all(mod.wheel_installs_here(f) for f in ok)
    assert not any(mod.wheel_installs_here(f) for f in no)


def test_the_lock_helper_renders_what_it_parses(monkeypatch):
    mod = _lock_module()
    monkeypatch.setattr(mod, "hashes_for", lambda n, v: ["a" * 64, "b" * 64])
    text = mod.render([("PySide6_Addons", "6.11.2"), ("tzdata", "2026.4")])
    assert mod.parse_lock(text) == [("pyside6-addons", "6.11.2", ["a" * 64, "b" * 64]),
                                    ("tzdata", "2026.4", ["a" * 64, "b" * 64])]


# ── the Wine ICU forwarder ──────────────────────────────────────────────────────────────
def _export_table(blob: bytes) -> tuple[str, list[tuple[str, str]], int, int]:
    """An independent reader of a PE export table (the module under test is not used to
    check itself): (dll name, [(export name, forwarder string)], machine, #sections)."""
    pe = struct.unpack_from("<I", blob, 0x3C)[0]
    assert blob[:2] == b"MZ" and blob[pe:pe + 4] == b"PE\0\0"
    machine, nsec = struct.unpack_from("<HH", blob, pe + 4)
    opt, opt_size = pe + 24, struct.unpack_from("<H", blob, pe + 20)[0]
    assert struct.unpack_from("<H", blob, opt)[0] == 0x20B
    exp_rva, exp_size = struct.unpack_from("<II", blob, opt + 112)
    secs = []
    for i in range(nsec):
        vs, va, rs, rp = struct.unpack_from("<IIII", blob, opt + opt_size + i * 40 + 8)
        secs.append((va, max(vs, rs), rp))

    def off(rva):
        return next(rva - va + rp for va, size, rp in secs if va <= rva < va + size)

    def cstr(o):
        return blob[o:blob.index(b"\0", o)].decode()

    d = off(exp_rva)
    name_rva, _base, nfuncs, nnames, eat, ent, eot = struct.unpack_from("<IIIIIII", blob, d + 12)
    out = []
    for i in range(nnames):
        ordinal = struct.unpack_from("<H", blob, off(eot) + 2 * i)[0]
        func_rva = struct.unpack_from("<I", blob, off(eat) + 4 * ordinal)[0]
        assert exp_rva <= func_rva < exp_rva + exp_size, "a forwarder must point INSIDE the export directory"
        out.append((cstr(off(struct.unpack_from("<I", blob, off(ent) + 4 * i)[0])), cstr(off(func_rva))))
    return cstr(off(name_rva)), out, machine, nsec


def test_the_icu_shim_is_a_loadable_forwarder_dll(tmp_path):
    mod = _load(os.path.join(WIX, "wine_icu_shim.py"), "wine_icu_shim")
    names = ["ucnv_open", "ucnv_close", "UCNV_FROM_U_CALLBACK_SUBSTITUTE", "ucnv_open"]
    blob = mod.build_forwarder_dll("icuuc.dll", "icu", names)
    dll, exports, machine, nsec = _export_table(blob)
    assert (dll, machine, nsec) == ("icuuc.dll", 0x8664, 1)
    assert [n for n, _f in exports] == sorted(set(names)), "the loader binary-searches: names must be sorted and unique"
    assert all(fwd == f"icu.{n}" for n, fwd in exports)
    assert len(blob) % 0x200 == 0
    with pytest.raises(ValueError):
        mod.build_forwarder_dll("icuuc.dll", "icu", [])


def test_the_icu_shim_reads_a_pe_and_refuses_a_non_pe(tmp_path):
    mod = _load(os.path.join(WIX, "wine_icu_shim.py"), "wine_icu_shim")
    dll = tmp_path / "x.dll"
    dll.write_bytes(mod.build_forwarder_dll("icuuc.dll", "icu", ["ucnv_open"]))
    assert mod._Pe(dll.read_bytes()).imports("icuuc.dll") == []           # a forwarder imports nothing
    assert mod.main(["--qt-dll", str(dll), "--out", str(tmp_path / "o.dll")]) == 3
    with pytest.raises(ValueError):
        mod._Pe(b"not a pe file at all, just text")


# ── the MSI verifier turns red for each thing it claims to check ────────────────────────
LICENSE_TEXT = "MIT License\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\n"


def _idt(columns, rows, table):
    keys = columns[0]
    return "\n".join(["\t".join(columns), "\t".join("s72" for _ in columns), f"{table}\t{keys}",
                      *("\t".join(r) for r in rows)]) + "\n"


@pytest.fixture
def msi(tmp_path):
    """A tiny, CORRECT stand-in for the msitools output of a good MSI, with a hook to break
    one thing at a time."""
    tables, extract, dist = tmp_path / "tables", tmp_path / "extract", tmp_path / "dist"
    root = extract / "LocalApp" / "HugMesh" / "Image Studio"
    files = {"hugmesh-studio.exe": b"MZ-exe", "_internal/a.dll": b"dll", "_internal/sub/b.txt": b"b"}
    for rel, data in files.items():
        for base in (root, dist):
            (base / rel).parent.mkdir(parents=True, exist_ok=True)
            (base / rel).write_bytes(data)
    tables.mkdir()
    (tables / "Property.idt").write_text(_idt(
        ["Property", "Value"],
        [["ProductVersion", "1.0.0"], ["UpgradeCode", "{7A3B6F18-2C94-4F0D-9A51-6D8E2B4C7F31}"],
         ["ProductName", "HugMesh Image Studio"]], "Property"))
    (tables / "File.idt").write_text(_idt(["File", "FileName"], [[f"f{i}", n] for i, n in enumerate(files)], "File"))
    (tables / "Shortcut.idt").write_text(_idt(
        ["Shortcut", "Target"], [["s", "[INSTALLFOLDER]hugmesh-studio.exe"]], "Shortcut"))
    (tables / "Media.idt").write_text(_idt(["DiskId", "Cabinet"], [["1", "#cab1.cab"]], "Media"))
    (tables / "Control.idt").write_text(
        "Dialog_\tControl\n" + "LicenseAgreementDlg\tLicenseText\t{\\rtf1 " + LICENSE_TEXT.splitlines()[2] + "}\n")
    (tables / "streams.txt").write_text("cab1.cab\nIcon.AppIcon\n")
    (tables / "Icon.AppIcon").write_bytes(b"ICO-bytes")
    icon = tmp_path / "x.ico"
    icon.write_bytes(b"ICO-bytes")
    lic = tmp_path / "LICENSE"
    lic.write_text(LICENSE_TEXT)
    wxs = tmp_path / "Package.wxs"
    wxs.write_text('<Package UpgradeCode="7a3b6f18-2c94-4f0d-9a51-6d8e2b4c7f31" />')
    mod = _load(os.path.join(WIX, "verify_msi.py"), "verify_msi")

    def run(version="1.0.0"):
        return mod.verify(tables=str(tables), extract=str(extract), dist=str(dist), version=version,
                          package_wxs=str(wxs), icon=str(icon), license_file=str(lic))
    run.paths = types.SimpleNamespace(tables=tables, root=root, dist=dist, icon=icon, lic=lic, wxs=wxs)
    return run


def _failed(results):
    return [m for ok, m in results if not ok]


def test_the_verifier_passes_a_good_msi(msi):
    assert _failed(msi()) == []


# (what we break, the check that must say so). Naming the check matters: several breakages
# trip more than one, so "something failed" would let a check be deleted unnoticed.
BREAKAGES = [
    ("version", "ProductVersion"), ("upgrade-code", "UpgradeCode"), ("all-users", "per-user package"),
    ("file-rows", "File table has"), ("no-exe", "hugmesh-studio.exe is in the MSI"),
    ("no-exe", "is installed under"), ("extra-file", "file list equals"), ("content", "SHA-256"),
    ("shortcut", "a shortcut targets"), ("icon-stream", "Icon.AppIcon"), ("icon-bytes", "Icon.AppIcon"),
    ("licence", "licence page"), ("external-cabinet", "cabinet is embedded")]


@pytest.mark.parametrize("what,check_name", BREAKAGES, ids=[f"{w}->{c}" for w, c in BREAKAGES])
def test_the_verifier_turns_red_for_each_thing_it_checks(msi, what, check_name):
    p = msi.paths
    version = "1.0.0"
    if what == "version":
        version = "2.0.0"
    elif what == "upgrade-code":
        p.wxs.write_text('<Package UpgradeCode="11111111-2222-3333-4444-555555555555" />')
    elif what == "all-users":
        (p.tables / "Property.idt").write_text(
            (p.tables / "Property.idt").read_text() + "ALLUSERS\t1\n")
    elif what == "file-rows":
        (p.tables / "File.idt").write_text(_idt(["File", "FileName"], [["f0", "hugmesh-studio.exe"]], "File"))
    elif what == "no-exe":
        (p.root / "hugmesh-studio.exe").unlink()
    elif what == "extra-file":
        (p.root / "_internal" / "surprise.dll").write_bytes(b"x")
    elif what == "content":
        (p.root / "_internal" / "a.dll").write_bytes(b"tampered")
    elif what == "shortcut":
        (p.tables / "Shortcut.idt").write_text(_idt(["Shortcut", "Target"], [["s", "[INSTALLFOLDER]other.exe"]], "Shortcut"))
    elif what == "icon-stream":
        (p.tables / "streams.txt").write_text("cab1.cab\n")
    elif what == "icon-bytes":
        (p.tables / "Icon.AppIcon").write_bytes(b"a different icon")
    elif what == "licence":
        p.lic.write_text("Some other licence text that is not on the page, long enough to matter\n")
    elif what == "external-cabinet":
        (p.tables / "Media.idt").write_text(_idt(["DiskId", "Cabinet"], [["1", "files.cab"]], "Media"))
    failed = _failed(msi(version))
    assert any(check_name in message for message in failed), (
        f"breaking {what!r} should fail the '{check_name}' check; what failed: {failed}")


def test_the_verifier_cli_exits_nonzero_when_a_check_fails(msi, capsys):
    mod = sys.modules["verify_msi"]
    p = msi.paths
    args = ["--tables", str(p.tables), "--extract", str(p.root.parents[2]), "--dist", str(p.dist),
            "--package-wxs", str(p.wxs), "--icon", str(p.icon), "--license", str(p.lic)]
    assert mod.main([*args, "--version", "1.0.0"]) == 0
    assert mod.main([*args, "--version", "9.9.9"]) == 1
    assert "FAIL  ProductVersion is 1.0.0 (want 9.9.9)" in capsys.readouterr().out
