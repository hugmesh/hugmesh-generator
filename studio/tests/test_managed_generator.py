"""The generator copy an installed Studio carries: written by
packaging/make_generator_seed.py, placed and upgraded by core/managed_generator.py, found
by core/generator_dir.resolve(). Qt-free; needs git.

What matters to the operator, each pinned below: a fresh Flatpak finds a working
generator tree with no clone and no picker; an upgrade replaces the release's files and
NEVER the operator's own (out/, keys-out/, tests/stack/.env survive); a damaged seed is
refused before anything in the copy changes; and their own clone always wins.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys

import pytest

from hugmesh_studio.core import flatpak_host, generator_dir, managed_generator, self_check

STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "make_generator_seed", os.path.join(STUDIO, "packaging", "make_generator_seed.py"))
seedmaker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seedmaker)

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def _git(repo, *args):
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


def _repo(tmp_path, version="9.9.9", files=None):
    repo = tmp_path / "gen-repo"
    if not repo.exists():
        repo.mkdir()
        _git(repo, "init", "-q")
    files = files if files is not None else {
        generator_dir.MARKER: "#!/bin/bash\necho build\n",
        "scripts/old.sh": "#!/bin/bash\necho old\n",
        "Makefile": "stack-up:\n\techo up\n",
    }
    for rel in list(_tracked(repo)):
        if rel not in files and rel != seedmaker.VERSION_FILE:
            _git(repo, "rm", "-q", rel)
    for rel, text in files.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if rel.endswith(".sh"):
            path.chmod(0o755)
    version_file = repo / seedmaker.VERSION_FILE
    version_file.parent.mkdir(parents=True, exist_ok=True)
    version_file.write_text(f'__version__ = "{version}"\n')
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", version)
    return repo


def _tracked(repo):
    out = subprocess.run(["git", "-C", str(repo), "ls-files"], capture_output=True,
                         text=True).stdout
    return [line for line in out.splitlines() if line]


@pytest.fixture
def placed(tmp_path, monkeypatch):
    seed = tmp_path / "seed"
    target = tmp_path / "home" / ".local" / "share" / "hugmesh-studio" / "generator"
    monkeypatch.setenv(managed_generator.SEED_ENV, str(seed))
    monkeypatch.setenv(managed_generator.TARGET_ENV, str(target))
    return seed, target


def test_a_seed_is_placed_as_a_working_checkout(tmp_path, placed):
    seed, target = placed
    repo = _repo(tmp_path)
    meta = seedmaker.make(str(seed), str(repo), log=open(os.devnull, "w"))
    assert meta["version"] == "9.9.9" and not meta["dirty"]
    assert set(meta["files"]) == set(seedmaker.seed_files(str(repo)))

    result = managed_generator.ensure()
    assert (result.action, result.error, result.path) == ("seeded", "", str(target))
    assert generator_dir.is_checkout(str(target))
    assert os.access(target / generator_dir.MARKER, os.X_OK), "the builder lost its x bit"
    if os.name != "nt":   # Windows has no x bit: os.access(X_OK) is true for any file
        assert not os.access(target / "Makefile", os.X_OK)
    assert managed_generator.ensure().action == "current"


def test_an_upgrade_replaces_the_release_and_keeps_the_operators_files(tmp_path, placed):
    seed, target = placed
    seedmaker.make(str(seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    assert managed_generator.ensure().action == "seeded"
    # what the Studio and the operator keep inside the tree
    mine = {"out/sessions/s1.json": "{}", "keys-out/node.key": "k",
            "tests/stack/.env": "ROUTE_ACCESS_DB_PASSWORD=x", "scripts/my-own.sh": "mine"}
    for rel, text in mine.items():
        (target / rel).parent.mkdir(parents=True, exist_ok=True)
        (target / rel).write_text(text)
    (target / "Makefile").write_text("edited by hand\n")

    repo = _repo(tmp_path, "9.9.10", {generator_dir.MARKER: "#!/bin/bash\necho build v2\n",
                                      "Makefile": "stack-up:\n\techo up2\n",
                                      "scripts/new.sh": "#!/bin/bash\n"})
    seedmaker.make(str(seed), str(repo), log=open(os.devnull, "w"))
    result = managed_generator.ensure()
    assert (result.action, result.error, result.version) == ("upgraded", "", "9.9.10")
    assert (target / generator_dir.MARKER).read_text().endswith("v2\n")
    assert (target / "Makefile").read_text() == "stack-up:\n\techo up2\n"
    assert (target / "scripts" / "new.sh").is_file()
    assert not (target / "scripts" / "old.sh").exists(), "a file the release dropped stayed"
    for rel, text in mine.items():
        assert (target / rel).read_text() == text, f"the upgrade touched the operator's {rel}"


def test_a_damaged_seed_changes_nothing(tmp_path, placed):
    seed, target = placed
    seedmaker.make(str(seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    managed_generator.ensure()
    before = (target / generator_dir.MARKER).read_text()
    repo = _repo(tmp_path, "9.9.11", {generator_dir.MARKER: "#!/bin/bash\necho NEW\n",
                                      "Makefile": "x:\n"})
    seedmaker.make(str(seed), str(repo), log=open(os.devnull, "w"))
    meta = json.loads((seed / seedmaker.META).read_text())
    meta["files"][generator_dir.MARKER] = "0" * 64
    (seed / seedmaker.META).write_text(json.dumps(meta))

    result = managed_generator.ensure()
    assert result.path == "" and "does not match its sha256" in result.error
    assert "free there" in result.error and str(target) in result.error
    assert (target / generator_dir.MARKER).read_text() == before
    assert json.loads((target / managed_generator.RECORD).read_text())["version"] == "9.9.9"
    assert not [p for p in os.listdir(target.parent) if p.startswith(".generator-staging-")]


def test_resolve_uses_the_copy_only_when_the_operator_has_no_checkout(tmp_path, placed,
                                                                      monkeypatch):
    seed, target = placed
    seedmaker.make(str(seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    cwd = tmp_path / "somewhere"
    cwd.mkdir()
    monkeypatch.chdir(cwd)
    monkeypatch.delenv(generator_dir.ENV, raising=False)
    assert generator_dir.resolve(str(tmp_path / "no-repo")) == str(target)

    clone = tmp_path / "my-clone"
    clone.mkdir()
    (clone / generator_dir.MARKER).write_text("#!/bin/bash\n")
    generator_dir.save(str(clone))
    assert generator_dir.resolve(str(tmp_path / "no-repo")) == str(clone), (
        "the operator's picked clone must outrank the bundled copy")
    monkeypatch.setenv(generator_dir.ENV, str(clone))
    assert generator_dir.resolve(str(tmp_path / "no-repo")) == str(clone)


def test_a_failed_placement_is_explained_where_the_picker_shows_it(tmp_path, placed,
                                                                   monkeypatch):
    seed, _target = placed
    seedmaker.make(str(seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    blocker = tmp_path / "a-file"
    blocker.write_text("")
    monkeypatch.setenv(managed_generator.TARGET_ENV, str(blocker / "generator"))
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv(generator_dir.ENV, raising=False)
    assert generator_dir.resolve(str(tmp_path / "no-repo")) == str(tmp_path)
    message = generator_dir.not_a_checkout_message(str(tmp_path))
    assert "carries its own copy" in message and str(blocker) in message
    assert "free there" in message
    assert "does not include them" not in message, "the old sentence is false for this install"


def test_without_a_seed_nothing_changes(tmp_path, monkeypatch):
    _isolate_install(tmp_path, monkeypatch, tmp_path / "src" / "studio" / "hugmesh_studio")
    monkeypatch.setenv(managed_generator.SEED_ENV, str(tmp_path / "none"))
    assert managed_generator.seed_dir() == ""
    assert managed_generator.ensure().path == ""
    assert "does not include them" in generator_dir.not_a_checkout_message(str(tmp_path))


def test_the_home_default_is_refused_under_pytest(monkeypatch):
    monkeypatch.delenv(managed_generator.TARGET_ENV, raising=False)
    with pytest.raises(RuntimeError):
        managed_generator.target_dir()


def test_the_copy_lives_under_the_real_home_not_xdg_data_home(monkeypatch, tmp_path):
    """$XDG_DATA_HOME is ~/.var/app/<id>/data inside the Flatpak: a checkout run would
    never look there, which is the 'sessions don't appear' split."""
    monkeypatch.delenv(managed_generator.TARGET_ENV, raising=False)
    monkeypatch.setenv("HUGMESH_STUDIO_ALLOW_HOME_STATE_DIR", "1")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("USERPROFILE", str(tmp_path / "home"))   # expanduser on Windows
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "var-app-data"))
    assert managed_generator.target_dir() == str(
        tmp_path / "home" / ".local" / "share" / "hugmesh-studio" / "generator")


def test_the_seed_refuses_a_symlink(tmp_path):
    repo = _repo(tmp_path)
    (repo / "link").symlink_to(generator_dir.MARKER)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "link")
    with pytest.raises(seedmaker.SeedError, match="plain files only"):
        seedmaker.seed_files(str(repo))


@pytest.mark.parametrize("flag", ["--print-command", "--print-commands"])
def test_print_command_refuses_a_folder_that_is_no_checkout(tmp_path, capsys, flag):
    """It printed `sudo bash ./build-x86-host-stage4.sh ...` and exited 0 for a folder with
    no builder in it (measured in the installed 0.4.1 Flatpak)."""
    from hugmesh_studio import app
    assert app.main([flag, "--generator-dir", str(tmp_path)]) == 2
    out = capsys.readouterr()
    assert out.out == "", "stdout is the argv channel: nothing may be printed on a refusal"
    assert "not a hugmesh-generator checkout" in out.err


def test_self_check_reports_a_folder_that_is_no_checkout(tmp_path, capsys):
    from hugmesh_studio import app
    assert app.main(["--self-check", "--json", "--generator-dir", str(tmp_path)]) == 1
    report = json.loads(capsys.readouterr().out)
    assert report["ok"] is False and "not a hugmesh-generator checkout" in report["problems"][0]


# ---------------------------------------------------------------------------------------
# Finding the seed in the INSTALLED bundle, with no $HUGMESH_STUDIO_GENERATOR_SEED
#
# The Flatpak pip-installs the package under /app (/app/lib/python3.13/site-packages)
# and the seed in /app/share/hugmesh-studio, but runs on the KDE runtime's
# /usr/bin/python3, so sys.prefix is /usr there. Until 2026-11-10 the seed was looked
# for only under sys.prefix: the built bundle's --self-check said "this Flatpak carries
# no generator seed (/usr/share/hugmesh-studio)" and the GUI opened the "is not a
# hugmesh-generator checkout" picker on a fresh install. Every test above sets the env
# var, which is why none of them saw it; none below does.
# ---------------------------------------------------------------------------------------
def _isolate_install(tmp_path, monkeypatch, package_dir, flatpak=False):
    """No env override, an interpreter prefix that is NOT the install prefix (a /usr
    with nothing under share/), the package at ``package_dir``."""
    usr = tmp_path / "usr"
    (usr / "share").mkdir(parents=True, exist_ok=True)
    monkeypatch.delenv(managed_generator.SEED_ENV, raising=False)
    monkeypatch.setattr(sys, "prefix", str(usr))
    monkeypatch.setattr(sys, "base_prefix", str(usr))
    monkeypatch.setattr(managed_generator, "PACKAGE_DIR", str(package_dir))
    monkeypatch.setattr(managed_generator, "FLATPAK_PREFIX", str(tmp_path / "app"))
    monkeypatch.setattr(flatpak_host, "in_flatpak", lambda *a, **k: flatpak)
    monkeypatch.setattr(managed_generator, "last", managed_generator.Placed())
    return usr


def _app_layout(tmp_path):
    app = tmp_path / "app"
    package = app / "lib" / "python3.13" / "site-packages" / "hugmesh_studio"
    package.mkdir(parents=True)
    return app, package, app / managed_generator.SEED_SUBDIR


def test_the_flatpak_layout_finds_its_seed_without_the_env(tmp_path, monkeypatch):
    app, package, app_seed = _app_layout(tmp_path)
    usr = _isolate_install(tmp_path, monkeypatch, package)
    seedmaker.make(str(app_seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    target = tmp_path / "home" / ".local" / "share" / "hugmesh-studio" / "generator"
    monkeypatch.setenv(managed_generator.TARGET_ENV, str(target))

    assert sys.prefix == str(usr) and not str(app_seed).startswith(sys.prefix)
    assert managed_generator.install_prefix() == str(app)
    assert managed_generator.seed_dir() == str(app_seed)
    placed = managed_generator.ensure()
    assert (placed.action, placed.error, placed.path) == ("seeded", "", str(target))
    assert generator_dir.is_checkout(placed.path)


def test_the_self_check_in_the_flatpak_layout_sees_the_seed(tmp_path, monkeypatch):
    app, package, app_seed = _app_layout(tmp_path)
    _isolate_install(tmp_path, monkeypatch, package, flatpak=True)
    seedmaker.make(str(app_seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    monkeypatch.setenv(managed_generator.TARGET_ENV, str(tmp_path / "generator"))
    report = self_check.check(managed_generator.ensure().path)
    assert report["in_flatpak"] is True
    assert report["seed"] and report["seed"]["dir"] == str(app_seed), report
    assert not [p for p in report["problems"] if "carries no generator seed" in p], report


def test_inside_a_flatpak_the_app_prefix_is_searched_wherever_the_package_is(
        tmp_path, monkeypatch):
    """Belt and braces: a package outside a site-packages layout (here a source-like
    tree) still finds /app/share/hugmesh-studio when /.flatpak-info says Flatpak."""
    app_seed = tmp_path / "app" / managed_generator.SEED_SUBDIR
    seedmaker.make(str(app_seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    package = tmp_path / "src" / "studio" / "hugmesh_studio"
    _isolate_install(tmp_path, monkeypatch, package, flatpak=True)
    assert managed_generator.install_prefix() == ""
    assert managed_generator.seed_dir() == str(app_seed)
    _isolate_install(tmp_path, monkeypatch, package, flatpak=False)
    assert managed_generator.seed_dir() == "", "outside a Flatpak /app is not searched"


def test_no_seed_anywhere_names_every_folder_searched(tmp_path, monkeypatch):
    app, package, app_seed = _app_layout(tmp_path)
    usr = _isolate_install(tmp_path, monkeypatch, package, flatpak=True)
    assert managed_generator.seed_dir() == ""
    report = self_check.check(str(tmp_path / "no-repo"))
    [problem] = [p for p in report["problems"] if "carries no generator seed" in p]
    assert str(app_seed) in problem and str(usr / managed_generator.SEED_SUBDIR) in problem


def test_the_env_and_the_interpreter_prefix_still_work(tmp_path, monkeypatch):
    app, package, app_seed = _app_layout(tmp_path)
    usr = _isolate_install(tmp_path, monkeypatch, tmp_path / "src" / "hugmesh_studio")
    repo = _repo(tmp_path)
    usr_seed = usr / managed_generator.SEED_SUBDIR
    seedmaker.make(str(usr_seed), str(repo), log=open(os.devnull, "w"))
    assert managed_generator.seed_dir() == str(usr_seed), "a pip/venv install lost its seed"
    own = tmp_path / "own-seed"
    seedmaker.make(str(own), str(repo), log=open(os.devnull, "w"))
    monkeypatch.setenv(managed_generator.SEED_ENV, str(own))
    assert managed_generator.seed_dir() == str(own), "the env override no longer wins"


@pytest.mark.parametrize("layout, prefix", [
    ("app/lib/python3.13/site-packages/hugmesh_studio", "app"),
    ("usr/local/lib64/python3.12/site-packages/hugmesh_studio", "usr/local"),
    ("usr/lib/python3/dist-packages/hugmesh_studio", "usr"),
    ("venv/lib/python3.13/site-packages/hugmesh_studio/", "venv"),
    ("Github/hugmesh-generator/studio/hugmesh_studio", ""),
    ("site-packages/hugmesh_studio", ""),
    ("x/lib/notpython/site-packages/hugmesh_studio", ""),
])
def test_install_prefix_is_read_from_the_package_location(tmp_path, layout, prefix):
    expected = str(tmp_path / prefix) if prefix else ""
    assert managed_generator.install_prefix(str(tmp_path / layout)) == expected


def test_a_real_copy_of_the_package_under_app_finds_the_app_seed(tmp_path):
    """No monkeypatching of the code under test: the package is COPIED into an
    /app/lib/python3.13/site-packages layout and imported from there by a fresh
    interpreter whose sys.prefix is not that /app, with the env var removed."""
    app, package, app_seed = _app_layout(tmp_path)
    package.rmdir()
    shutil.copytree(os.path.join(STUDIO, "hugmesh_studio"), package,
                    ignore=shutil.ignore_patterns("__pycache__", "assets"))
    seedmaker.make(str(app_seed), str(_repo(tmp_path)), log=open(os.devnull, "w"))
    env = {k: v for k, v in os.environ.items()
           if k not in (managed_generator.SEED_ENV, "PYTHONPATH", "PYTEST_CURRENT_TEST")}
    code = ("import json, sys; sys.path.insert(0, sys.argv[1]); "
            "from hugmesh_studio.core import managed_generator as m; "
            "print(json.dumps({'prefix': sys.prefix, 'file': m.__file__, "
            "'seed': m.seed_dir()}))")
    out = subprocess.run([sys.executable, "-I", "-c", code, str(package.parent)],
                         env=env, capture_output=True, text=True, check=True, cwd=tmp_path)
    got = json.loads(out.stdout)
    assert got["file"].startswith(str(package)), got
    assert not str(app_seed).startswith(got["prefix"]), got
    assert got["seed"] == str(app_seed), got
