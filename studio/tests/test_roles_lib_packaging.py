"""The role vocabulary must survive INSTALLATION, not just a checkout.

core/roles.py reads the role vocabulary out of ``scripts/_roles-lib.sh``, resolved
four dirnames up from its own ``__file__``. That is right in a checkout and wrong
everywhere else: ``pip install ./studio`` copies ``hugmesh_studio/`` into
site-packages with NO repo above it, so the same expression resolves to
``<prefix>/lib/python3.x/scripts/_roles-lib.sh`` — a path that does not exist. Both
installers are built that way (the Flatpak manifest's build context is ``studio/``
and cannot even see the repo root; the MSI freezes the same install).

That is fatal rather than degraded, on both halves:

  * ``core/config.py`` builds ``RPI5_ROLE_MAP``/``JETSON_ROLE_MAP`` from
    ``roles.composite_aliases()`` at MODULE IMPORT time, and
  * ``roles._lib_text()`` raises ``RoleVocabularyError`` on purpose rather than
    defaulting (every historical bug in this area was a silent fallback).

So a bundle built without the vocabulary does not lose the role menu — it dies in
``import hugmesh_studio.core.config``, and with it the wizard, the worklist, the
build page and the Qt-free ``--print-specs`` smoke path. Nothing caught it: the
studio suite runs from the checkout, where the file is always there, and the Flatpak
release job has no smoke test at all.

THE FIX THIS PINS: a byte-identical mirror of the declaration ships inside the
package (``core/_roles-lib.sh``, declared in ``[tool.setuptools.package-data]``), and
``roles.roles_lib_path()`` prefers the checkout copy, then the packaged one.

The regression test below builds THE SHIPPED TREE — every ``*.py`` plus only the
files ``[tool.setuptools.package-data]`` actually declares — into a directory with no
repository above it, and imports it in a subprocess. It is deliberately derived from
pyproject.toml rather than from a copy of the file list: dropping the package-data
entry, or the file, or the reader's fallback puts this test straight back to red.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

import pytest

from hugmesh_studio.core import roles

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
DECLARATION = os.path.join(GENERATOR_DIR, "scripts", "_roles-lib.sh")
MIRROR = os.path.join(STUDIO_ROOT, "hugmesh_studio", "core", "_roles-lib.sh")
PYPROJECT = os.path.join(STUDIO_ROOT, "pyproject.toml")


def _package_data() -> dict[str, list[str]]:
    """``{package: [glob, ...]}`` out of ``[tool.setuptools.package-data]``.

    tomllib is 3.11+, the package supports 3.10, and a SKIP here would silently
    delete the regression test on the older interpreter — so the fallback parses the
    one table this file needs rather than skipping.
    """
    text = open(PYPROJECT, encoding="utf-8").read()
    try:
        import tomllib
    except ModuleNotFoundError:                                # pragma: no cover - 3.10
        block = re.search(r"(?ms)^\[tool\.setuptools\.package-data\]\n(.*?)(?=^\[|\Z)",
                          text)
        assert block, "[tool.setuptools.package-data] not found in pyproject.toml"
        out: dict[str, list[str]] = {}
        for line in block.group(1).splitlines():
            m = re.match(r'^\s*"?([\w.]+)"?\s*=\s*\[(.*)\]\s*$', line)
            if m:
                out[m.group(1)] = re.findall(r'"([^"]+)"', m.group(2))
        return out
    return tomllib.loads(text)["tool"]["setuptools"]["package-data"]


# ── the mirror is a mirror ──────────────────────────────────────────────────────
def test_the_packaged_copy_is_byte_identical_to_the_declaration():
    """One declaration, two files. The checkout copy is the one a checkout reads, so
    a drifted mirror is invisible until an installed bundle behaves differently from
    every test that has ever run — which is the failure mode this asserts away."""
    assert os.path.isfile(MIRROR), (
        f"{MIRROR} is missing — an installed Studio has no scripts/ dir above it and "
        f"dies at `import hugmesh_studio.core.config`. Run:\n"
        f"    cp scripts/_roles-lib.sh studio/hugmesh_studio/core/_roles-lib.sh")
    want = open(DECLARATION, "rb").read()
    got = open(MIRROR, "rb").read()
    assert got == want, (
        "the packaged role vocabulary has drifted from scripts/_roles-lib.sh. The "
        "shell file is THE declaration; re-run:\n"
        "    cp scripts/_roles-lib.sh studio/hugmesh_studio/core/_roles-lib.sh")


def test_package_data_declares_the_vocabulary():
    """The file existing on disk is not enough — setuptools ships only what this
    table names, and the wheel that broke the Flatpak contained the .py files and
    nothing else new."""
    globs = _package_data().get("hugmesh_studio.core", [])
    assert "_roles-lib.sh" in globs, (
        "core/_roles-lib.sh is not in [tool.setuptools.package-data] "
        f"(hugmesh_studio.core = {globs}) — it exists in the tree but would not be "
        "installed, which is exactly the shape of the bug this file pins")


# ── reader precedence ───────────────────────────────────────────────────────────
def test_the_checkout_declaration_wins_over_the_mirror():
    """So an edit to scripts/_roles-lib.sh takes effect immediately in a checkout and
    the mirror can never quietly become the file the Studio actually obeys."""
    assert roles.roles_lib_path() == roles.CHECKOUT_ROLES_LIB


def test_the_mirror_is_used_when_there_is_no_checkout_above_the_package(monkeypatch,
                                                                       tmp_path):
    """THE INSTALLED CASE, at unit granularity: the checkout path is gone, and the
    vocabulary still resolves instead of raising."""
    monkeypatch.setattr(roles, "CHECKOUT_ROLES_LIB", str(tmp_path / "nope.sh"))
    roles._vocab.cache_clear()
    try:
        assert roles.roles_lib_path() == roles.PACKAGED_ROLES_LIB
        assert roles.composite_aliases()["rpi5-desktop"] == ("desktop", "platform", "rpi5")
    finally:
        roles._vocab.cache_clear()


def test_the_env_override_wins_over_both(monkeypatch, tmp_path):
    """$HUGMESH_ROLES_LIB aims a frozen bundle at an operator's own checkout."""
    lib = tmp_path / "custom-roles-lib.sh"
    lib.write_bytes(open(DECLARATION, "rb").read())
    monkeypatch.setenv(roles.ROLES_LIB_ENV, str(lib))
    assert roles.roles_lib_path() == str(lib)


def test_a_missing_vocabulary_names_every_path_it_tried(monkeypatch, tmp_path):
    """The original failure said only `cannot read ... /lib/python3.13/scripts/…`,
    a path nobody recognises. The message has to say what it looked for."""
    monkeypatch.setattr(roles, "CHECKOUT_ROLES_LIB", str(tmp_path / "a.sh"))
    monkeypatch.setattr(roles, "PACKAGED_ROLES_LIB", str(tmp_path / "b.sh"))
    roles._vocab.cache_clear()
    try:
        with pytest.raises(roles.RoleVocabularyError) as exc:
            roles.canonical_roles()
        msg = str(exc.value)
        assert "a.sh" in msg and "b.sh" in msg and roles.ROLES_LIB_ENV in msg
    finally:
        roles._vocab.cache_clear()


# ── the regression: the SHIPPED tree, with no repo above it ─────────────────────
def _install_the_shipped_tree(dest: str) -> None:
    """Copy exactly what a wheel would carry: the package's Python plus the files
    [tool.setuptools.package-data] declares, and nothing else."""
    import shutil

    src_root = os.path.join(STUDIO_ROOT, "hugmesh_studio")
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        rel = os.path.relpath(dirpath, STUDIO_ROOT)
        os.makedirs(os.path.join(dest, rel), exist_ok=True)
        for name in filenames:
            if name.endswith(".py"):
                shutil.copy2(os.path.join(dirpath, name), os.path.join(dest, rel, name))

    import fnmatch
    for package, globs in _package_data().items():
        pkg_rel = package.replace(".", os.sep)
        pkg_dir = os.path.join(STUDIO_ROOT, pkg_rel)
        if not os.path.isdir(pkg_dir):
            continue
        for name in sorted(os.listdir(pkg_dir)):
            if any(fnmatch.fnmatch(name, g) for g in globs):
                os.makedirs(os.path.join(dest, pkg_rel), exist_ok=True)
                shutil.copy2(os.path.join(pkg_dir, name),
                             os.path.join(dest, pkg_rel, name))


def _env(tmp_path) -> dict[str, str]:
    """A minimal environment. ``-I`` already ignores PYTHONPATH and the user site dir
    (the shipped tree is put on sys.path explicitly instead, so nothing else can be),
    but HOME and the state dir are still pinned inside tmp_path: the Studio must not
    touch the operator's real ~/.hugmesh from a subprocess the leak guard cannot see.
    """
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(tmp_path / "home"),
            "HUGMESH_STUDIO_STATE_DIR": str(tmp_path / "state")}


@pytest.mark.parametrize("module", [
    "hugmesh_studio.core.config",
    "hugmesh_studio.core.roles",
    "hugmesh_studio.core.worklist",
    "hugmesh_studio.core.worklist_driver",
])
def test_the_installed_package_imports_with_no_repository_above_it(tmp_path, module):
    """THE REGRESSION. Before the fix every one of these raised RoleVocabularyError at
    import, because config.py's RPI5_ROLE_MAP is built at import time out of a shell
    file that was never packaged. Run in a subprocess with an empty environment and a
    cwd outside the repo, so nothing can leak the checkout back in."""
    site = tmp_path / "site-packages"
    site.mkdir()
    _install_the_shipped_tree(str(site))

    # The whole point: four dirnames up from the installed roles.py there is no
    # scripts/ dir — the same shape as <prefix>/lib/python3.x/.
    assert not os.path.exists(tmp_path / "scripts"), "fixture leaked a checkout"

    code = (f"import sys; sys.path.insert(0, {str(site)!r}); "
            f"import {module}; "
            "from hugmesh_studio.core import config, roles; "
            "print(config.RPI5_ROLE_MAP); print(roles.roles_lib_path())")
    res = subprocess.run([sys.executable, "-I", "-c", code], cwd=str(tmp_path),
                         env=_env(tmp_path), capture_output=True, text=True)
    assert res.returncode == 0, (
        f"an INSTALLED Studio cannot import {module}:\n{res.stderr}")
    assert "'rpi5-desktop': 'desktop'" in res.stdout, res.stdout
    # And it read the PACKAGED copy, not something that leaked in from the checkout.
    assert res.stdout.strip().splitlines()[-1] == str(
        site / "hugmesh_studio" / "core" / "_roles-lib.sh"), res.stdout


def test_the_installed_package_serves_the_qt_free_smoke_path(tmp_path):
    """`--print-specs` is what the MSI job smoke-tests the frozen binary with, and the
    Flatpak job has no equivalent. It went down with the same import."""
    site = tmp_path / "site-packages"
    site.mkdir()
    _install_the_shipped_tree(str(site))
    res = subprocess.run(
        [sys.executable, "-I", "-c",
         f"import sys; sys.path.insert(0, {str(site)!r}); "
         "from hugmesh_studio.app import main; raise SystemExit(main(['--print-specs']))"],
        cwd=str(tmp_path), env=_env(tmp_path), capture_output=True, text=True)
    assert res.returncode == 0, f"--print-specs died in an installed bundle:\n{res.stderr}"
    assert res.stdout.strip(), "no output from --print-specs"
