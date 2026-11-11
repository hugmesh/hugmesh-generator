"""The macOS app's build inputs: the spec's BUNDLE step, the pins, the icon set, the
bundle checker and build-macos-app.sh, all checked on Linux in seconds.

What none of this proves is that the app starts on a Mac. That is the ``macos`` job in
``.github/workflows/studio-tests.yml``, which runs this file on a real Mac and then
runs build-macos-app.sh there: freeze, check_macos_bundle.py, codesign, --print-specs
and --self-check under Finder's PATH, a real cocoa window, and the .dmg.
"""
from __future__ import annotations

import os
import plistlib
import re
import struct
import subprocess
import sys

import pytest
import yaml

from test_windows_packaging_files import (  # noqa: F401 (the spec harness)
    PACKAGING, REPO_ROOT, STUDIO_ROOT, _git, _in_git_checkout, _load, _run_spec,
    needs_tomllib)

SCRIPT = os.path.join(PACKAGING, "build-macos-app.sh")
SCRIPT_REL = "studio/packaging/build-macos-app.sh"
CHECKER = os.path.join(PACKAGING, "check_macos_bundle.py")
MAC_REQS = os.path.join(PACKAGING, "macos-build-requirements.txt")
WIN_LOCK = os.path.join(PACKAGING, "wix", "windows-build-requirements.txt")
STUDIO_TESTS = os.path.join(REPO_ROOT, ".github", "workflows", "studio-tests.yml")
APP = "HugMesh Image Studio.app"


def _version() -> str:
    with open(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), encoding="utf-8") as fh:
        return re.search(r'(?m)^__version__ = "([^"]+)"', fh.read()).group(1)


VERSION = _version()


def _checker():
    return _load(CHECKER, "check_macos_bundle")


def _msi_version(version: str) -> str:
    return _load(os.path.join(PACKAGING, "wix", "msi_version.py"), "msi_version").msi_version(version)


# ── the spec's darwin branch ────────────────────────────────────────────────────────
@needs_tomllib
def test_darwin_wraps_the_onedir_tree_in_an_app_bundle(monkeypatch, tmp_path):
    icns = tmp_path / "hugmesh-studio.icns"
    icns.write_bytes(b"icns")
    monkeypatch.chdir(tmp_path)
    calls = _run_spec(monkeypatch, icon="hugmesh-studio.icns", platform="darwin")
    bundle = calls["BUNDLE"]
    assert bundle.args == (calls["COLLECT"],), "the .app wraps the whole onedir tree"
    kw = bundle.kwargs
    assert kw["name"] == APP
    assert kw["bundle_identifier"] == "org.hugmesh.ImageStudio"
    assert kw["icon"] == str(icns)
    # Finder's version string is numbers only; the build number is the MSI's monotonic
    # mapping, so beta.2 sorts above beta.1 for Launch Services as it does for msiexec.
    assert kw["version"] == VERSION.split("-", 1)[0]
    plist = kw["info_plist"]
    assert plist["CFBundleVersion"] == _msi_version(VERSION)
    assert plist["HugMeshStudioVersion"] == VERSION
    assert plist["LSMinimumSystemVersion"] == _checker().MACOS_MINIMUM == "13.0"
    assert plist["NSHighResolutionCapable"] is True
    assert plist["CFBundleName"] == "HugMesh Image Studio"
    # One executable: macOS has no subsystem split, so no console twin.
    assert [e.kwargs["name"] for e in calls["EXES"]] == ["hugmesh-studio"]


@needs_tomllib
@pytest.mark.parametrize("platform", ["linux", "win32"])
def test_no_bundle_step_off_darwin(monkeypatch, platform):
    assert "BUNDLE" not in _run_spec(monkeypatch, platform=platform)


@needs_tomllib
def test_darwin_refuses_an_icon_that_is_not_icns(monkeypatch, tmp_path):
    (tmp_path / "x.ico").write_bytes(b"\0")
    monkeypatch.chdir(tmp_path)
    with pytest.raises(SystemExit) as exc:
        _run_spec(monkeypatch, icon="x.ico", platform="darwin")
    assert ".icns" in str(exc.value)


@needs_tomllib
def test_darwin_bundle_without_an_icon_still_builds(monkeypatch):
    """A developer without iconutil output can still freeze (the checker then says the
    icon is missing, which build-macos-app.sh never lets happen)."""
    assert _run_spec(monkeypatch, platform="darwin")["BUNDLE"].kwargs["icon"] is None


# ── the pins ────────────────────────────────────────────────────────────────────────
def _pins(path: str) -> dict:
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^([A-Za-z0-9._-]+)==([^\s\\]+)", line)
        if m:
            out[m.group(1).lower()] = m.group(2)
    return out


def test_macos_pins_are_the_windows_lock_minus_windows_only_plus_macholib():
    win, mac = _pins(WIN_LOCK), _pins(MAC_REQS)
    assert mac, "macos-build-requirements.txt pins nothing"
    assert set(win) - set(mac) == {"pefile", "pywin32-ctypes", "pillow"}, set(win) - set(mac)
    assert set(mac) - set(win) == {"macholib"}, set(mac) - set(win)
    for name, version in mac.items():
        if name != "macholib":
            assert win[name] == version, f"{name}: macos {version} != windows {win[name]}"


# ── the icon set ────────────────────────────────────────────────────────────────────
def test_the_iconset_names_are_the_ten_iconutil_reads():
    gen = _load(os.path.join(PACKAGING, "gen_icons.py"), "gen_icons")
    names = [name for name, _ in gen.ICONSET]
    assert len(names) == len(set(names)) == 10
    for name, size in gen.ICONSET:
        m = re.fullmatch(r"icon_(\d+)x\1(@2x)?\.png", name)
        assert m, name
        assert size == int(m.group(1)) * (2 if m.group(2) else 1), (name, size)
    assert {int(re.search(r"\d+", n).group()) for n in names} == {16, 32, 128, 256, 512}


def _png_size(path) -> tuple[int, int]:
    with open(path, "rb") as fh:
        head = fh.read(24)
    assert head[:8] == b"\x89PNG\r\n\x1a\n", path
    return struct.unpack(">II", head[16:24])


def test_gen_icons_writes_an_iconset_of_the_right_pixel_sizes(tmp_path):
    pytest.importorskip("hugmesh_studio.gui.qt", reason="gen_icons renders with the Studio's Qt painter")
    env = {**os.environ, "QT_QPA_PLATFORM": "offscreen"}
    proc = subprocess.run([sys.executable, os.path.join(PACKAGING, "gen_icons.py"),
                           "--out", str(tmp_path), "--iconset"],
                          capture_output=True, text=True, env=env, cwd=STUDIO_ROOT, timeout=120)
    assert proc.returncode == 0, proc.stderr
    gen = _load(os.path.join(PACKAGING, "gen_icons.py"), "gen_icons")
    for name, size in gen.ICONSET:
        assert _png_size(tmp_path / "hugmesh-studio.iconset" / name) == (size, size), name
    proc = subprocess.run([sys.executable, os.path.join(PACKAGING, "gen_icons.py"),
                           "--out", str(tmp_path / "plain")],
                          capture_output=True, text=True, env=env, cwd=STUDIO_ROOT, timeout=120)
    assert proc.returncode == 0 and not (tmp_path / "plain" / "hugmesh-studio.iconset").exists()


# ── the bundle checker ──────────────────────────────────────────────────────────────
ARM64_EXE = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"\0" * 24
X86_EXE = struct.pack("<II", 0xFEEDFACF, 0x01000007) + b"\0" * 24
FAT_EXE = (struct.pack(">II", 0xCAFEBABE, 2) + struct.pack(">IIIII", 0x01000007, 3, 0, 0, 0)
           + struct.pack(">IIIII", 0x0100000C, 0, 0, 0, 0))


def _good_app(root, version=VERSION, exe=ARM64_EXE):
    checker = _checker()
    app = root / APP
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    plist = {"CFBundleIdentifier": "org.hugmesh.ImageStudio", "CFBundleExecutable": "hugmesh-studio",
             "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "13.0",
             "NSHighResolutionCapable": True, "CFBundleShortVersionString": version.split("-")[0],
             "HugMeshStudioVersion": version, "CFBundleIconFile": "hugmesh-studio.icns"}
    with open(contents / "Info.plist", "wb") as fh:
        plistlib.dump(plist, fh)
    (contents / "Resources" / "hugmesh-studio.icns").write_bytes(b"icns")
    binary = contents / "MacOS" / "hugmesh-studio"
    binary.write_bytes(exe)
    binary.chmod(0o755)
    plugin = contents / "Frameworks" / "PySide6" / "Qt" / "plugins" / "platforms"
    plugin.mkdir(parents=True)
    (plugin / "libqcocoa.dylib").write_bytes(b"dylib")
    for rel in checker.package_data():
        dest = contents / "Resources" / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text("x")
    return app


@needs_tomllib
def test_the_checker_passes_a_good_bundle(tmp_path):
    app = _good_app(tmp_path)
    assert _checker().check(str(app), version=VERSION, arch="arm64") == []
    # a universal executable carries both
    fat = _good_app(tmp_path / "fat", exe=FAT_EXE)
    assert _checker().check(str(fat), version=VERSION, arch="x86_64") == []


def _break(app, what):
    contents = app / "Contents"
    plist_path = contents / "Info.plist"

    def edit(**changes):
        with open(plist_path, "rb") as fh:
            data = plistlib.load(fh)
        for k, v in changes.items():
            if v is None:
                data.pop(k, None)
            else:
                data[k] = v
        with open(plist_path, "wb") as fh:
            plistlib.dump(data, fh)

    if what == "plist":
        plist_path.write_text("not a plist")
    elif what == "identifier":
        edit(CFBundleIdentifier="org.example.Other")
    elif what == "minimum":
        edit(LSMinimumSystemVersion="10.13")
    elif what == "hidpi":
        edit(NSHighResolutionCapable=None)
    elif what == "version":
        edit(HugMeshStudioVersion="0.0.1")
    elif what == "icon-key":
        edit(CFBundleIconFile=None)
    elif what == "icon-file":
        (contents / "Resources" / "hugmesh-studio.icns").unlink()
    elif what == "exe-missing":
        (contents / "MacOS" / "hugmesh-studio").unlink()
    elif what == "exe-mode":
        (contents / "MacOS" / "hugmesh-studio").chmod(0o644)
    elif what == "exe-not-macho":
        (contents / "MacOS" / "hugmesh-studio").write_bytes(b"\x7fELF" + b"\0" * 28)
    elif what == "exe-arch":
        (contents / "MacOS" / "hugmesh-studio").write_bytes(X86_EXE)
    elif what == "cocoa":
        (contents / "Frameworks" / "PySide6" / "Qt" / "plugins" / "platforms"
         / "libqcocoa.dylib").unlink()
    elif what == "package-data":
        (contents / "Resources" / "hugmesh_studio" / "core" / "progress-tables.json").unlink()
    elif what == "pyqt6":
        (contents / "Frameworks" / "PyQt6").mkdir()
    else:
        raise AssertionError(what)


@needs_tomllib
@pytest.mark.parametrize("what, says", [
    ("plist", "Info.plist: cannot be read"),
    ("identifier", "CFBundleIdentifier"),
    ("minimum", "LSMinimumSystemVersion"),
    ("hidpi", "NSHighResolutionCapable"),
    ("version", "HugMeshStudioVersion"),
    ("icon-key", "CFBundleIconFile"),
    ("icon-file", "hugmesh-studio.icns (CFBundleIconFile) is missing"),
    ("exe-missing", "Contents/MacOS/hugmesh-studio is missing"),
    ("exe-mode", "is not executable"),
    ("exe-not-macho", "is not a Mach-O executable"),
    ("exe-arch", "is built for x86_64, not arm64"),
    ("cocoa", "libqcocoa.dylib"),
    ("package-data", "progress-tables.json (package-data) is not in the bundle"),
    ("pyqt6", "PyQt6 was frozen"),
])
def test_the_checker_turns_red_for_each_thing_it_checks(tmp_path, what, says):
    app = _good_app(tmp_path)
    _break(app, what)
    problems = _checker().check(str(app), version=VERSION, arch="arm64")
    assert any(says in p for p in problems), problems


@needs_tomllib
def test_a_package_data_file_in_frameworks_counts(tmp_path):
    """PyInstaller 6 keeps data under Resources and links it into Frameworks
    (sys._MEIPASS); a file found only in Frameworks is still in the bundle."""
    app = _good_app(tmp_path)
    rel = os.path.join("hugmesh_studio", "core", "progress-tables.json")
    src = app / "Contents" / "Resources" / rel
    dst = app / "Contents" / "Frameworks" / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(src, dst)
    assert _checker().check(str(app), version=VERSION, arch="arm64") == []


def test_macho_archs_reads_thin_fat_and_refuses_everything_else(tmp_path):
    checker = _checker()
    for name, data, want in (("a", ARM64_EXE, {"arm64"}), ("x", X86_EXE, {"x86_64"}),
                             ("f", FAT_EXE, {"arm64", "x86_64"}), ("e", b"\x7fELF" + b"\0" * 12, set()),
                             ("s", b"\xcf", set())):
        (tmp_path / name).write_bytes(data)
        assert checker.macho_archs(str(tmp_path / name)) == want, name
    assert checker.macho_archs(str(tmp_path / "missing")) == set()


@needs_tomllib
def test_the_checker_cli_exit_codes(tmp_path, capsys):
    checker = _checker()
    app = _good_app(tmp_path)
    assert checker.main([str(app), "--version", VERSION, "--arch", "arm64"]) == 0
    assert "bundle OK" in capsys.readouterr().out
    assert checker.main([str(app), "--arch", "x86_64"]) == 1
    assert "FAIL: " in capsys.readouterr().out
    assert checker.main([str(tmp_path / "nope.app")]) == 2


# ── build-macos-app.sh ──────────────────────────────────────────────────────────────
def _bash(script: str, *args, env=None, cwd=None) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", script, "bash", *args], capture_output=True,
                          text=True, env=env, cwd=cwd, timeout=60)


def test_the_build_script_exists_parses_and_is_executable():
    assert os.access(SCRIPT, os.X_OK)
    assert subprocess.run(["bash", "-n", SCRIPT]).returncode == 0
    if _in_git_checkout():
        listed = _git("ls-files", "-s", "--", SCRIPT_REL).stdout.split()
        assert listed and listed[0] == "100755", listed


def test_sourcing_the_build_script_runs_nothing():
    proc = _bash(f'source "{SCRIPT}"; dmg_name 1.2.3-beta.4 arm64; dmg_name 1.2.3 x86_64')
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.split() == ["hugmesh-studio-1.2.3-beta.4-macos-arm64.dmg",
                                   "hugmesh-studio-1.2.3-macos-x86_64.dmg"]
    assert "==>" not in proc.stdout


def test_the_build_script_reads_the_studio_version():
    proc = _bash(f'source "{SCRIPT}"; studio_version')
    assert proc.stdout.strip() == VERSION


def test_the_build_script_help_unknown_option_and_bad_arch():
    proc = subprocess.run(["bash", SCRIPT, "--help"], capture_output=True, text=True)
    assert proc.returncode == 0 and "--gui-smoke" in proc.stdout and "--python" in proc.stdout
    proc = subprocess.run(["bash", SCRIPT, "--bogus"], capture_output=True, text=True)
    assert proc.returncode == 2 and "unknown option --bogus" in proc.stderr
    proc = subprocess.run(["bash", SCRIPT, "--arch", "riscv64"], capture_output=True, text=True)
    assert proc.returncode == 1 and "--arch must be arm64 or x86_64" in proc.stderr


@pytest.mark.skipif(sys.platform == "darwin", reason="the refusal is for every OS but macOS")
def test_the_build_script_refuses_off_a_mac():
    proc = subprocess.run(["bash", SCRIPT], capture_output=True, text=True)
    assert proc.returncode == 1
    assert "needs a Mac" in proc.stderr and "packaging/hugmesh-studio.spec" in proc.stderr


def _code(path: str) -> str:
    """The script without comment lines, so the prose may name what the code avoids."""
    lines = []
    for line in open(path, encoding="utf-8"):
        if not line.lstrip().startswith("#"):
            lines.append(line)
    return "".join(lines)


def test_the_build_script_stays_inside_bash_3_2():
    """It runs under macOS's /bin/bash, which is 3.2 (GPLv2) on every Mac."""
    code = _code(SCRIPT)
    for pattern, what in ((r"\bdeclare\s+-[a-zA-Z]*A", "associative arrays"),
                          (r"\$\{[A-Za-z_]+(,,|\^\^)", "case-changing expansions"),
                          (r"\b(mapfile|readarray)\b", "mapfile/readarray"),
                          (r"\|&", "|& pipes"), (r";;&|;&\s*$", "case fall-through"),
                          (r"\$\{[A-Za-z_]+\[@\]:-", "empty-array guards"),
                          (r"\bcoproc\b", "coproc"), (r"&>>", "&>> redirection")):
        assert not re.search(pattern, code, re.M), f"bash 4+ construct: {what}"


def test_the_smoke_runs_under_finders_path():
    """The smoke steps prove the startup PATH hook only if they run with launchd's
    PATH; with the runner's own (Homebrew first) they would pass without it."""
    code = _code(SCRIPT)
    assert 'FINDER_PATH="/usr/bin:/bin:/usr/sbin:/sbin"' in code
    assert re.search(r'env -i HOME="\$SMOKE_HOME" PATH="\$FINDER_PATH"', code)
    smoke = code[code.index("phase_smoke()"):code.index("phase_gui()")]
    assert smoke.count("finder_env ") == 2 and "--print-specs" in smoke and "--self-check" in smoke


# ── the CI job ──────────────────────────────────────────────────────────────────────
def _macos_job() -> dict:
    with open(STUDIO_TESTS, encoding="utf-8") as fh:
        return yaml.safe_load(fh)["jobs"]["macos"]


def test_the_pull_request_gate_builds_on_apple_silicon_and_intel():
    job = _macos_job()
    pairs = {(m["runner"], m["arch"]) for m in job["strategy"]["matrix"]["include"]}
    assert pairs == {("macos-15", "arm64"), ("macos-15-intel", "x86_64")}
    assert job["strategy"]["fail-fast"] is False
    assert job["runs-on"] == "${{ matrix.runner }}"
    runs = "\n".join(s.get("run", "") for s in job["steps"])
    assert "-r studio/packaging/macos-build-requirements.txt" in runs
    assert "bash studio/packaging/build-macos-app.sh" in runs
    assert "--gui-smoke" in runs and "--arch ${{ matrix.arch }}" in runs


def test_every_file_the_macos_contract_names_exists():
    job = _macos_job()
    step = next(s for s in job["steps"] if s.get("name") == "Run the macOS contract")
    named = re.findall(r"tests/[\w./-]+\.py", step["run"])
    assert "tests/test_macos_packaging.py" in named
    for rel in named:
        assert os.path.isfile(os.path.join(STUDIO_ROOT, rel)), rel
