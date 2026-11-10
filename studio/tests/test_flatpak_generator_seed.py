"""The installed Studio must carry every generator script and make target it runs.

The 0.4.1 Flatpak shipped the Studio package alone, so on a fresh install it had no
build-*-stage4.sh, no scripts/, no tests/qemu/ and no Makefile, and said "<home> is not
a hugmesh-generator checkout". Nothing failed before release: the release smoke test ran
only ``--print-specs``, which never touches the generator tree.

These guards run on every pull request (Qt-free; they need git and this checkout):

  * the list of what the Studio uses is DERIVED from its source by
    core/generator_refs.py (string literals that are generator paths, the literal tails
    of os.path.join, ``["make", target]`` and ``self._make(target)``), never typed here;
  * every one of those paths is in the seed the bundle ships
    (packaging/make_generator_seed.py's own file selection), or is runtime state the
    Studio writes (git-ignored), or is named in self_check.NOT_GENERATOR_PATHS with its
    reason; every make target is defined in the shipped Makefile;
  * the manifest installs the seed where core/managed_generator.py looks for it, and the
    release workflow and the local build script write it before flatpak-builder runs;
  * a real seed of this checkout is written, placed and self-checked end to end.

A mutation that cuts a directory from the seed (``EXCLUDE = ("scripts",)``) or names a
script that does not exist is shown to turn the guard red, at the bottom.
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess

import pytest

from hugmesh_studio import __version__
from hugmesh_studio.core import generator_dir, generator_refs, managed_generator, self_check

STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(STUDIO)
PACKAGE = os.path.join(STUDIO, "hugmesh_studio")
MANIFEST = os.path.join(STUDIO, "packaging", "flatpak", "org.hugmesh.ImageStudio.yml")
RELEASE = os.path.join(REPO, ".github", "workflows", "studio-release.yml")
LOCAL_BUILD = os.path.join(STUDIO, "packaging", "build-flatpak-local.sh")
SEED_OUT = "studio/packaging/flatpak/generator-seed"

_spec = importlib.util.spec_from_file_location(
    "make_generator_seed", os.path.join(STUDIO, "packaging", "make_generator_seed.py"))
seedmaker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seedmaker)


def _is_git_checkout() -> bool:
    if shutil.which("git") is None:
        return False
    result = subprocess.run(["git", "-C", REPO, "rev-parse", "--verify", "HEAD"],
                            capture_output=True)
    return result.returncode == 0


pytestmark = pytest.mark.skipif(not _is_git_checkout(),
                                reason="needs git and a hugmesh-generator checkout")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _ignored(rel: str) -> bool:
    """Runtime state: git ignores the path itself, or anything inside it."""
    for probe in (rel, rel + "/x"):
        result = subprocess.run(["git", "-C", REPO, "check-ignore", "-q", "--no-index", probe],
                                capture_output=True)
        if result.returncode == 0:
            return True
    return False


def unshipped_references(files: list[str]) -> dict[str, list[str]]:
    """The guard: generator paths the Studio names that the seed ``files`` lacks and
    that are neither runtime state nor a named non-generator path."""
    shipped = set(files)
    dirs = self_check._dirs_of(shipped)
    # The REPOSITORY's top level, not the seed's: a cut directory must still be looked
    # for (a mutation that cut scripts/ passed while this read the seed).
    top = set(subprocess.run(["git", "-C", REPO, "ls-tree", "--name-only", "HEAD"],
                             capture_output=True, text=True, check=True).stdout.split())
    refs = generator_refs.scan(top, PACKAGE)
    return {rel: where for rel, where in sorted(refs.paths.items())
            if rel not in shipped and rel not in dirs
            and rel not in self_check.NOT_GENERATOR_PATHS and not _ignored(rel)}


@pytest.fixture(scope="module")
def seed_files() -> list[str]:
    return seedmaker.seed_files(REPO)


@pytest.fixture(scope="module")
def refs(seed_files):
    return generator_refs.scan({rel.split("/", 1)[0] for rel in seed_files}, PACKAGE)


def test_the_scan_sees_what_the_studio_runs(refs):
    """Against a vacuous pass: a scanner that found nothing would clear every guard."""
    for rel in ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh",
                "tests/qemu/run-qemu-docker.sh", "scripts/gen-provision-keys.sh",
                "scripts/build-all-roles.sh", "tests/stack/compose.local.yaml",
                "specs/usr/sbin/hugmesh-go-live", "specs-x86/hwprofiles/profiles.json"):
        assert rel in refs.paths, f"generator_refs no longer sees {rel}"
    for target in ("stack-up", "kind-up", "stack-halt"):
        assert target in refs.make_targets, f"generator_refs no longer sees make {target}"
    assert len(refs.paths) > 80, len(refs.paths)


def test_every_generator_path_the_studio_names_is_in_the_seed(seed_files):
    missing = unshipped_references(seed_files)
    assert not missing, (
        "the Studio names generator paths the Flatpak's seed does not ship (and git does "
        "not ignore them as runtime state):\n" + "\n".join(
            f"  {rel}  (at {', '.join(where[:3])})" for rel, where in missing.items()))


def test_every_make_target_the_studio_runs_is_in_the_shipped_makefile(refs, seed_files):
    assert "Makefile" in seed_files
    defined = generator_refs.makefile_targets(_read(os.path.join(REPO, "Makefile")))
    missing = {t: w for t, w in refs.make_targets.items() if t not in defined}
    assert not missing, f"make targets the Studio runs that the Makefile lacks: {missing}"


def test_non_generator_paths_are_still_named_by_the_source(refs):
    stale = sorted(set(self_check.NOT_GENERATOR_PATHS) - set(refs.paths))
    assert not stale, f"self_check.NOT_GENERATOR_PATHS lists paths no code names: {stale}"


def test_the_seed_is_the_whole_committed_tree(seed_files):
    assert seedmaker.EXCLUDE == (), (
        "make_generator_seed.EXCLUDE cuts the seed; the guards above decide whether the "
        "cut is safe, then update this pin and the docstring that explains the choice")
    tracked = subprocess.run(["git", "-C", REPO, "ls-tree", "-r", "--name-only",
                              "--full-tree", "HEAD"], capture_output=True, text=True,
                             check=True).stdout.split()
    assert seed_files == sorted(tracked)


# ---------------------------------------------------------------------------------------
# The packaging carries the seed to where the Studio looks for it
# ---------------------------------------------------------------------------------------
def test_the_manifest_ships_the_seed_where_the_studio_looks():
    text = _read(MANIFEST)
    folded = re.sub(r"\n\s+", " ", text)
    for name in (managed_generator.SEED_ARCHIVE, managed_generator.SEED_META):
        assert re.search(rf"type: file\s+path: generator-seed/{re.escape(name)}\b", text), (
            f"the manifest has no `type: file` source for generator-seed/{name}")
        dest = "${FLATPAK_DEST}/" + managed_generator.SEED_SUBDIR.replace(os.sep, "/") + "/" + name
        assert f"install -Dm644 {name} {dest}" in folded, (
            f"the manifest does not install {name} to {dest}")
    assert re.search(r"(?m)^\s+- packaging/flatpak/generator-seed\s*$", text), (
        "the studio/ dir source must skip packaging/flatpak/generator-seed")
    assert seedmaker.ARCHIVE == managed_generator.SEED_ARCHIVE
    assert seedmaker.META == managed_generator.SEED_META


def _job(name: str) -> str:
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)", _read(RELEASE))
    assert match, f"the release workflow has no job {name}"
    return match.group(1)


@pytest.mark.parametrize("job", ["flatpak", "flatpak-aarch64"])
def test_the_release_jobs_write_the_seed_before_building_and_check_it_after(job):
    body = _job(job)
    seed = body.find(f"make_generator_seed.py --force \\\n            --out {SEED_OUT}")
    build = body.find("flatpak-builder --user")
    check = body.find("--self-check --json")
    install = body.find("flatpak install --user -y --noninteractive")
    assert seed != -1, f"the {job} job never writes the generator seed"
    assert 0 < seed < build, f"the {job} job writes the seed after flatpak-builder"
    assert check > install > build, f"the {job} job does not run --self-check on the bundle"


def test_the_local_build_writes_the_same_seed():
    text = _read(LOCAL_BUILD)
    assert 'make_generator_seed.py" --out "$flatpak_src/generator-seed"' in text
    assert '--self-check --json' in text


def test_git_ignores_the_written_seed():
    assert _ignored(f"{SEED_OUT}/{managed_generator.SEED_ARCHIVE}")


# ---------------------------------------------------------------------------------------
# End to end: this checkout's seed, placed, self-checked
# ---------------------------------------------------------------------------------------
def test_a_seed_of_this_checkout_places_a_tree_the_self_check_accepts(tmp_path, monkeypatch,
                                                                       seed_files):
    seed = tmp_path / "seed"
    target = tmp_path / "home" / ".local" / "share" / "hugmesh-studio" / "generator"
    meta = seedmaker.make(str(seed), REPO, log=open(os.devnull, "w"))
    assert meta["version"] == __version__, "the seed's version is not this Studio's"
    assert sorted(meta["files"]) == seed_files

    monkeypatch.setenv(managed_generator.SEED_ENV, str(seed))
    monkeypatch.setenv(managed_generator.TARGET_ENV, str(target))
    monkeypatch.setattr(managed_generator, "last", managed_generator.Placed())
    placed = managed_generator.ensure()
    assert placed.error == "" and generator_dir.is_checkout(placed.path)
    report = self_check.check(placed.path)
    assert report["problems"] == [], report["problems"]
    assert report["checked_paths"] > 80 and report["scripts_parsed"] > 10, report


# ---------------------------------------------------------------------------------------
# The guards go red when they should
# ---------------------------------------------------------------------------------------
def test_cutting_a_directory_from_the_seed_turns_the_guard_red(monkeypatch):
    monkeypatch.setattr(seedmaker, "EXCLUDE", ("scripts",))
    missing = unshipped_references(seedmaker.seed_files(REPO))
    assert "scripts/gen-provision-keys.sh" in missing, sorted(missing)


def test_naming_a_script_that_does_not_exist_turns_the_guard_red(tmp_path, seed_files):
    fake = tmp_path / "hugmesh_studio"
    shutil.copytree(PACKAGE, fake, ignore=shutil.ignore_patterns("__pycache__", "assets"))
    (fake / "core" / "zz_new_lane.py").write_text(
        'import os\nRUNNER = os.path.join("tests", "qemu", "run-qemu-renamed.sh")\n'
        'TARGETS = ["make", "stack-renamed"]\n')
    refs = generator_refs.scan({rel.split("/", 1)[0] for rel in seed_files}, str(fake))
    assert "tests/qemu/run-qemu-renamed.sh" in refs.paths
    assert "tests/qemu/run-qemu-renamed.sh" not in seed_files
    assert not _ignored("tests/qemu/run-qemu-renamed.sh")
    defined = generator_refs.makefile_targets(_read(os.path.join(REPO, "Makefile")))
    assert "stack-renamed" in refs.make_targets and "stack-renamed" not in defined
