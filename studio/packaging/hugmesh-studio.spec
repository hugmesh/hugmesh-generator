# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the Windows build of HugMesh Image Studio.

    cd studio
    HUGMESH_STUDIO_ICON=<path to a .ico> pyinstaller --noconfirm packaging/hugmesh-studio.spec

Output: ``dist/hugmesh-studio/hugmesh-studio.exe`` plus its ``_internal/`` tree (a
"onedir" bundle: the MSI wraps the whole folder, and a onefile exe would unpack ~200 MB
into %TEMP% on every start). It is a WINDOWED executable (no console window).

THIS FILE IS COMMITTED ON PURPOSE. It used to be missing: ``studio/.gitignore`` carried
a blanket ``*.spec`` (the pattern PyInstaller's own ``.gitignore`` template uses for
generated specs) which silently ignored this hand-written one, so the Windows installer
job in ``.github/workflows/studio-release.yml`` called ``pyinstaller`` on a path that
did not exist in any checkout. ``tests/test_windows_packaging_files.py`` holds both
halves: the file exists, and git would not ignore it.

WHAT THE BUNDLE MUST CARRY. ``hugmesh_studio`` reads four non-Python files from beside
its own modules (``core/progress-tables.json`` at import time, ``core/_roles-lib.sh``
on the way to ``core/config.py``, ``core/device-catalog.json`` and
``assets/login-preview.html``). PyInstaller only follows ``import`` statements, so none
of them would ship unless named here, and the app does not degrade without them: it
dies in ``import hugmesh_studio.core.config``. The list is NOT repeated in this file. It
is read from ``[tool.setuptools.package-data]`` in pyproject.toml, the table the wheel
and the Flatpak are built from, so there is one list and ``tests/test_roles_lib_packaging.py``
already holds it to both directions.

WHAT THE FROZEN APP IS NOT. It is a front end over the scripts in a hugmesh-generator
checkout (build-*.sh, scripts/, specs/, tests/), and none of those are bundled. See
``wix/README.md`` ("What a frozen Studio can and cannot do") before promising users more.
"""
import glob
import os

from PyInstaller.utils.hooks import collect_all

# SPECPATH is injected by PyInstaller: the absolute directory this file lives in. Every
# path below hangs off it, so the build gives the same answer from any working directory
# (the CI job runs from studio/, a developer may not).
PACKAGING_DIR = os.path.abspath(SPECPATH)  # noqa: F821
STUDIO_DIR = os.path.dirname(PACKAGING_DIR)
PACKAGE_DIR = os.path.join(STUDIO_DIR, "hugmesh_studio")
ENTRY = os.path.join(PACKAGING_DIR, "run_studio.py")

NAME = "hugmesh-studio"

# Never freeze a second Qt binding. pyproject.toml makes PySide6 (LGPL) the dependency
# and says "the PyInstaller spec excludes PyQt6" because PyQt6 is GPL: a bundle that
# picked it up would relicense the whole installer. gui/qt.py imports PyQt6 in an
# `except ImportError`, which PyInstaller's analysis cannot tell from a real import, so
# on a machine that happens to have PyQt6 installed it would be collected, and PyInstaller
# aborts a build that finds two bindings. PyQt5/PySide2 are listed for the same reason.
EXCLUDES = ["PyQt5", "PyQt6", "PySide2"]


def _package_data():
    """``[(source file, bundle directory), ...]`` for every file the wheel's
    ``[tool.setuptools.package-data]`` table declares."""
    try:
        import tomllib
    except ModuleNotFoundError:
        raise SystemExit(
            "hugmesh-studio.spec reads pyproject.toml with tomllib, which needs "
            "Python 3.11 or newer (the installer build uses 3.12).")
    with open(os.path.join(STUDIO_DIR, "pyproject.toml"), "rb") as fh:
        table = tomllib.load(fh)["tool"]["setuptools"]["package-data"]
    found = []
    for package, patterns in sorted(table.items()):
        package_dir = os.path.join(STUDIO_DIR, *package.split("."))
        for pattern in patterns:
            hits = sorted(glob.glob(os.path.join(package_dir, pattern)))
            if not hits:
                # setuptools ignores a row that matches nothing and ships nothing; a
                # frozen app missing one of these files cannot start. Fail the build.
                raise SystemExit(
                    "package-data row %s = %r matches no file under %s, so the frozen "
                    "app would be missing it" % (package, pattern, package_dir))
            for hit in hits:
                found.append((hit, os.path.relpath(os.path.dirname(hit), STUDIO_DIR)))
    return found


def _all_modules():
    """Every module in the package, by dotted name. Bundling the whole package (as the
    wheel does) rather than only what static analysis reaches from the entry shim means
    a page that is one day loaded by name is not silently absent from the installer."""
    modules = []
    for root, dirs, files in os.walk(PACKAGE_DIR):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for filename in sorted(files):
            if not filename.endswith(".py"):
                continue
            rel = os.path.relpath(os.path.join(root, filename), STUDIO_DIR)[:-3]
            parts = rel.split(os.sep)
            if parts[-1] == "__init__":
                parts.pop()
            modules.append(".".join(parts))
    return modules


# tzdata: Windows ships no system timezone database. core/timezones.available() asks
# zoneinfo and, finding nothing, quietly returns a 50-zone fallback list, so a bundle
# without it still starts and just shows a short timezone menu. PyInstaller's own
# zoneinfo hook would pull it in on Windows, but a silent dependency on a hook is how
# this goes missing unnoticed: collect it here, and refuse to build without it.
tz_datas, tz_binaries, tz_hidden = collect_all("tzdata")
if not tz_datas:
    raise SystemExit(
        "tzdata is not installed in this Python, so the installer would silently lose "
        "most of the timezone list. Install the Windows extra: pip install ./studio[win]")

# The icon comes from the environment so a developer without one can still freeze. It is
# resolved against the WORKING DIRECTORY (the workflow passes build/icons/... from studio/).
# A path that is set but does not exist is an error and not a quiet fallback to the
# generic icon: that fallback ships an installer with the wrong face and no warning.
icon = None
icon_setting = os.environ.get("HUGMESH_STUDIO_ICON", "").strip()
if icon_setting:
    icon = os.path.abspath(icon_setting)
    if not os.path.isfile(icon):
        raise SystemExit(
            "HUGMESH_STUDIO_ICON=%s does not exist (resolved to %s, relative to the "
            "working directory). Render it first: python packaging/gen_icons.py --out "
            "build/icons" % (icon_setting, icon))

a = Analysis(  # noqa: F821
    [ENTRY],
    # The checkout's own copy of the package wins over any hugmesh_studio already
    # installed in site-packages, so what is frozen is what is in this tree.
    pathex=[STUDIO_DIR],
    binaries=tz_binaries,
    datas=_package_data() + tz_datas,
    hiddenimports=_all_modules() + tz_hidden,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=EXCLUDES,
    noarchive=False,
)
pyz = PYZ(a.pure)  # noqa: F821

exe = EXE(  # noqa: F821
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=NAME,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    # No UPX: it makes antivirus products flag the exe, and saves little next to Qt.
    upx=False,
    console=False,
    icon=icon,
)

coll = COLLECT(  # noqa: F821
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name=NAME,
)
