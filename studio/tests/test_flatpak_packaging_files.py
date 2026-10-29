"""The Flatpak packaging has to be COMPLETE, CONSISTENT and SAFE to run, not just present.

Why this file exists. The release workflow's flatpak job (.github/workflows/studio-release.yml)
was written, and the manifest it builds named ``python-deps.json`` as its first module, but
that file had never been committed. ``flatpak-builder`` therefore stopped before it built
anything, and nothing noticed because no test looks at ``studio/packaging/flatpak/`` and
the job itself only runs on a tag or by hand. Building the Flatpak by hand on a machine
with no sudo (``studio/packaging/build-flatpak-local.sh``) is what found it; these tests
keep the next gap of that kind from waiting for a release to be seen:

  * every file the manifest, the desktop entry and the metainfo point at exists;
  * the app id is one string in the manifest, both file names, both file bodies and the
    icon names, and the launch command is the console script pyproject really installs;
  * ``python-deps.json`` is pinned (a hash per wheel, every architecture, no floating
    version) and its PySide6 is the same minor release as the runtime's Qt;
  * the runtime branch the manifest builds against is the one the release workflow
    installs (change one and not the other and the release job fails on a missing SDK);
  * the manifest copies studio/ without what a used checkout piles up (a stale
    ``build/lib`` would otherwise be packaged), and never skips what the build needs;
    its own ``pip3 install`` is offline, and its permissions are the ones the metainfo
    text promises the user (narrow them and the promise has to change with them);
  * the local build script is executable IN GIT (a fresh clone takes its mode from the
    commit, not from your disk), never calls sudo or a package manager in any of the
    forms the scanner below reads (the list is at ``_FORBIDDEN``; what is outside it is
    pinned as outside, not assumed covered), refuses to touch a flatpak directory
    somebody already uses, and names the one broken-helper state that otherwise shows
    up only as an opaque bwrap error;
  * run against a scripted fake ``flatpak``, the script sends EVERY call to the private
    directory and never to ``--system``, grants the Builder that directory (and the host
    wrapper that pins it) and keeps its state where a long checkout path cannot break it,
    runs the same flatpak-builder flags, validators, build-bundle call, file names and
    bundle install and run as the release workflow's flatpak job (read back from the
    workflow, not from copies here), stops at a failed build or export without leaving an
    old bundle that looks new, checks the bundle against its own checksum, and refuses
    what each of its three smoke tests must refuse. (A mutation battery showed all of
    that could be lost with the static checks alone still green.) The same fake answers a
    flatpak call that does not name ``--user`` with a failure, so a call that loses it
    fails the run, and a static reading of the whole script holds every installation call
    to the same rule on the lines the run never reaches; a second run takes the re-run
    branches, smoke test 2's python is run against a stub Qt, and a canary in the fake
    HOME shows the script writes nothing outside its two directories.

Qt-free and offline: it reads files and runs the script against fakes only, and never
starts the real flatpak.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from configparser import ConfigParser

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
PACKAGING = os.path.join(STUDIO_ROOT, "packaging")
FLATPAK = os.path.join(PACKAGING, "flatpak")
MANIFEST = os.path.join(FLATPAK, "org.hugmesh.ImageStudio.yml")
DESKTOP = os.path.join(FLATPAK, "org.hugmesh.ImageStudio.desktop")
METAINFO = os.path.join(FLATPAK, "org.hugmesh.ImageStudio.metainfo.xml")
PYTHON_DEPS = os.path.join(FLATPAK, "python-deps.json")
README = os.path.join(FLATPAK, "README.md")
SCRIPT = os.path.join(PACKAGING, "build-flatpak-local.sh")
RELEASE_WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")
PYPROJECT = os.path.join(STUDIO_ROOT, "pyproject.toml")
#: Where a bundle says its runtime comes from (build-bundle --runtime-repo). Flathub's
#: own .flatpakrepo, on the host Flathub documents for it.
RUNTIME_REPO_URL = "https://dl.flathub.org/repo/flathub.flatpakrepo"

BASH = shutil.which("bash")
needs_bash = pytest.mark.skipif(
    BASH is None or sys.platform == "win32",
    reason="runs the bash build script's own refusals; no bash on this platform")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _manifest_scalar(key: str) -> str:
    """A top-level ``key: value`` line of the manifest, quotes and trailing comment off.

    Deliberately NOT the script's own sed and not PyYAML (the CI job that runs this file
    installs it, a bare checkout does not): two independent readings of one manifest
    cannot both be wrong the same way.
    """
    match = re.search(rf"(?m)^{re.escape(key)}:[ \t]*[\"']?([^\"'#\s]+)[\"']?[ \t]*(?:#.*)?$",
                      _read(MANIFEST))
    assert match, f"{MANIFEST} has no top-level '{key}:' line"
    return match.group(1)


APP_ID = _manifest_scalar("app-id")


# ---------------------------------------------------------------------------------------
# Presence
# ---------------------------------------------------------------------------------------
@pytest.mark.parametrize("path, why", [
    pytest.param(MANIFEST, "the manifest flatpak-builder builds", id="manifest"),
    pytest.param(DESKTOP, "the launcher the manifest installs", id="desktop-entry"),
    pytest.param(METAINFO, "the AppStream metadata the manifest installs", id="metainfo"),
    pytest.param(PYTHON_DEPS,
                 "the manifest's first module: without it flatpak-builder stops before it "
                 "builds anything, which is exactly how this packaging shipped broken",
                 id="python-deps"),
    pytest.param(README, "how to build, regenerate and read the sandbox's limits", id="readme"),
    pytest.param(SCRIPT, "the one-command local build (no sudo, no apt)", id="build-script"),
])
def test_every_packaging_file_exists(path, why):
    assert os.path.isfile(path), f"missing {os.path.relpath(path, GENERATOR_DIR)}: {why}"


def test_manifest_points_only_at_files_that_exist():
    """Includes, the source directory and every file its build commands install."""
    text = _read(MANIFEST)
    modules = text.split("\nmodules:\n", 1)[1]

    # A bare `- something.json` entry under modules: is an include, resolved next to the
    # manifest.
    includes = re.findall(r"(?m)^  - ([\w.\-]+\.(?:json|ya?ml))\s*$", modules)
    assert includes, "the manifest includes no module file (expected python-deps.json)"
    for name in includes:
        assert os.path.isfile(os.path.join(FLATPAK, name)), (
            f"the manifest includes {name} but studio/packaging/flatpak/{name} does not exist")

    # `type: dir` + `path: ../..` is studio/, the build context every other path below is
    # relative to.
    source = re.search(r"type: dir\s+path: (\S+)", modules)
    assert source, "the manifest has no `type: dir` source"
    context = os.path.normpath(os.path.join(FLATPAK, source.group(1)))
    assert os.path.isfile(os.path.join(context, "pyproject.toml")), (
        f"the source directory {source.group(1)} resolves to {context}, which has no "
        "pyproject.toml: `pip3 install .` would have nothing to install")

    joined = re.sub(r"\n\s+", " ", modules)      # a folded YAML scalar is one command
    for relative in re.findall(r"install -Dm644 (packaging/\S+)", joined) + \
            re.findall(r"python3 (packaging/\S+\.py)", joined):
        assert os.path.isfile(os.path.join(context, relative)), (
            f"a build command uses {relative}, which is not under {context}")


def _dir_source_skips() -> list[str]:
    modules = _read(MANIFEST).split("\nmodules:\n", 1)[1]
    block = re.search(r"type: dir\n\s+path: \S+\n(?:\s*#[^\n]*\n)*\s+skip:\n((?:[ \t]+- [^\n]+\n)+)",
                      modules)
    assert block, "the manifest's `type: dir` source has no skip: list (see the comment there)"
    return [line.strip()[2:].strip() for line in block.group(1).splitlines()]


def test_dir_source_skips_what_a_checkout_piles_up_and_nothing_the_build_needs():
    """``build/lib`` left by an earlier build is packaged by ``pip3 install .``.

    The manifest copies all of studio/, so without a skip list a stale module in
    ``studio/build/lib`` ships in the Flatpak after it is gone from the source (measured:
    it was inside the built app). The list is exact paths relative to studio/: flatpak-builder
    takes no globs and no bare names, and a glob does not fail, it silently matches nothing.
    """
    skipped = _dir_source_skips()
    # The last three are what the release workflow's own in-tree build leaves behind;
    # flatpak-builder skips build-dir and .flatpak-builder by itself but not repo/, so a
    # second in-tree build would copy the first one's OSTree repository into the app.
    for piled_up in ("build", "dist", ".venv", ".venv-studio", ".pytest_cache",
                     "hugmesh_image_studio.egg-info", "packaging/flatpak/build-dir",
                     "packaging/flatpak/repo"):
        assert piled_up in skipped, f"{piled_up!r} is not skipped: a used checkout would leak it"
    for entry in skipped:
        assert not set(entry) & set("*?[]!"), (
            f"skip entry {entry!r} is a glob; flatpak-builder matches exact paths only, so it "
            "would silently skip nothing")
        assert not entry.startswith("/") and ".." not in entry.split("/"), (
            f"skip entry {entry!r} must be a path relative to studio/")

    joined = re.sub(r"\n\s+", " ", _read(MANIFEST))
    needed = {"pyproject.toml", "README.md", "hugmesh_studio"}
    needed |= set(re.findall(r"install -Dm644 (packaging/\S+)", joined))
    needed |= set(re.findall(r"python3 (packaging/\S+\.py)", joined))
    for path in sorted(needed):
        assert os.path.exists(os.path.join(STUDIO_ROOT, path)), f"test premise: {path} exists"
        for entry in skipped:
            assert not (path == entry or path.startswith(entry + "/")), (
                f"skip entry {entry!r} removes {path}, which the build needs")


# ---------------------------------------------------------------------------------------
# One app id, one launch command
# ---------------------------------------------------------------------------------------
def test_app_id_is_the_same_everywhere():
    desktop = ConfigParser(interpolation=None, strict=False)
    desktop.optionxform = str                       # .desktop keys are case sensitive
    desktop.read_string(_read(DESKTOP))
    entry = desktop["Desktop Entry"]
    component = ET.parse(METAINFO).getroot()

    assert os.path.basename(DESKTOP) == f"{APP_ID}.desktop", "desktop file name != app-id"
    assert os.path.basename(METAINFO) == f"{APP_ID}.metainfo.xml", "metainfo file name != app-id"
    assert os.path.basename(MANIFEST) == f"{APP_ID}.yml", "manifest file name != app-id"
    assert (component.findtext("id") or "").strip() == APP_ID, "metainfo <id> != app-id"
    launchable = component.find("launchable[@type='desktop-id']")
    assert launchable is not None and (launchable.text or "").strip() == f"{APP_ID}.desktop", (
        "metainfo <launchable> does not name the desktop file the manifest installs")
    assert entry.get("Icon") == APP_ID, "desktop Icon= != app-id, so the launcher has no icon"

    # What the manifest installs must land under those same names.
    text = re.sub(r"\n\s+", " ", _read(MANIFEST))
    assert f"share/applications/{APP_ID}.desktop" in text
    assert f"share/metainfo/{APP_ID}.metainfo.xml" in text
    assert f"apps/{APP_ID}.png" in text, "the icons are not installed under the app id"


def test_launch_command_is_the_console_script_pyproject_installs():
    command = _manifest_scalar("command")
    desktop = ConfigParser(interpolation=None, strict=False)
    desktop.optionxform = str
    desktop.read_string(_read(DESKTOP))
    exec_line = desktop["Desktop Entry"].get("Exec", "")
    assert shlex.split(exec_line)[0] == command, (
        f"desktop Exec={exec_line!r} does not start with the manifest command {command!r}")

    block = re.search(r"(?ms)^\[project\.scripts\]\n(.*?)(?=^\[|\Z)", _read(PYPROJECT))
    assert block, "pyproject.toml has no [project.scripts]"
    scripts = dict(re.findall(r'(?m)^([\w.\-]+)\s*=\s*"([^"]+)"', block.group(1)))
    assert command in scripts, (
        f"the manifest runs {command!r} but pyproject installs only {sorted(scripts)}")
    module, _, function = scripts[command].partition(":")
    module_file = os.path.join(STUDIO_ROOT, *module.split(".")) + ".py"
    assert os.path.isfile(module_file) and re.search(
        rf"(?m)^def {re.escape(function)}\(", _read(module_file)), (
        f"console script target {scripts[command]} does not exist")


# ---------------------------------------------------------------------------------------
# The pinned wheels
# ---------------------------------------------------------------------------------------
def _wheel_sources() -> list[dict]:
    """Every ``type: file`` source in python-deps.json, however deeply modules nest."""
    found: list[dict] = []

    def walk(node):
        for source in node.get("sources", []):
            if source.get("type") == "file":
                found.append(source)
        for child in node.get("modules", []):
            walk(child)

    walk(json.loads(_read(PYTHON_DEPS)))
    return found


def test_python_deps_is_pinned_and_offline():
    sources = _wheel_sources()
    assert sources, "python-deps.json lists no files to download"
    for source in sources:
        name = source.get("url", "")
        assert name.startswith("https://"), f"{name!r}: a source must be an https URL"
        assert re.fullmatch(r"[0-9a-f]{64}", source.get("sha256", "")), (
            f"{os.path.basename(name)} has no sha256: a release could silently pick up "
            "different bytes than the ones that were tested")

    def commands(node):
        yield from node.get("build-commands", [])
        for child in node.get("modules", []):
            yield from commands(child)

    pips = [c for c in commands(json.loads(_read(PYTHON_DEPS))) if "pip3 install" in c]
    assert pips, "python-deps.json installs nothing"
    for command in pips:
        assert "--no-index" in command, (
            f"{command!r} may go to PyPI at build time; the build is meant to be offline")


def test_pyside6_is_pinned_to_the_runtimes_qt_minor_release():
    """Wheels carry their own Qt; keep it the same release as the runtime's.

    org.kde.Platform//6.11 ships Qt 6.11.x, so PySide6 must be 6.11.y (the branch is read
    from the manifest, not held here). A runtime bump that forgets to regenerate
    python-deps.json fails here, not on a user's desktop.
    """
    runtime_version = _manifest_scalar("runtime-version")
    wheels: dict[str, dict[str, str]] = {}                    # arch -> dist -> version
    for source in _wheel_sources():
        match = re.match(r"(?P<dist>[A-Za-z0-9_]+)-(?P<version>\d[^-]*)-.*"
                         r"(?P<arch>x86_64|aarch64)\.whl$", os.path.basename(source["url"]))
        if match:
            wheels.setdefault(match["arch"], {})[match["dist"].lower()] = match["version"]

    needed = {"pyside6", "pyside6_essentials", "pyside6_addons", "shiboken6"}
    for arch in ("x86_64", "aarch64"):
        have = wheels.get(arch, {})
        assert needed <= set(have), (
            f"python-deps.json has no complete PySide6 set for {arch}: missing "
            f"{sorted(needed - set(have))}")
        versions = {have[dist] for dist in needed}
        assert len(versions) == 1, f"the {arch} PySide6 wheels disagree on a version: {have}"
        version = versions.pop()
        assert version.startswith(runtime_version + "."), (
            f"PySide6 {version} is not a {runtime_version}.x release, but the manifest builds "
            f"against runtime {runtime_version}. Regenerate python-deps.json (the recipe is "
            "in the manifest and in README.md).")


def test_python_deps_pins_agree_with_their_wheels():
    """The pip line names a version and the wheels carry one; they must be the same one.

    ``pip3 install --no-index "PySide6==6.8.4"`` with 6.8.3 wheels on disk fails at build
    time, after the runtimes have been downloaded. And a wheel whose ``only-arches`` is not
    the architecture in its own file name is installed on the wrong machine (or on none).
    """
    for module in json.loads(_read(PYTHON_DEPS))["modules"]:
        pinned = {dist.lower().replace("-", "_"): version
                  for command in module.get("build-commands", [])
                  for dist, version in re.findall(r'"([A-Za-z0-9_.\-]+)==([^"]+)"', command)}
        for source in module.get("sources", []):
            if source.get("type") != "file":
                continue
            wheel = os.path.basename(source["url"])
            match = re.match(r"(?P<dist>[A-Za-z0-9_]+)-(?P<version>\d[^-]*)-", wheel)
            assert match, f"{wheel} is not a wheel file name"
            dist = match["dist"].lower()
            if dist in pinned:
                assert match["version"] == pinned[dist], (
                    f"{module['name']} pins {dist}=={pinned[dist]} but downloads {wheel}")
            arches = source.get("only-arches")
            if arches:
                assert len(arches) == 1 and wheel.endswith(f"_{arches[0]}.whl"), (
                    f"{wheel} is marked only-arches={arches}, which is not its own architecture")


def _manifest_build_commands() -> list[str]:
    """The app module's build-commands, each folded YAML scalar joined into one line."""
    block = re.search(r"(?ms)^    build-commands:\n(.*?)^    \S", _read(MANIFEST) + "\n    end")
    assert block, "the manifest's app module has no build-commands"
    commands: list[str] = []
    for line in block.group(1).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            commands.append(stripped[2:])
        else:
            commands[-1] += " " + stripped
    return commands


def test_manifest_pip_install_is_offline():
    """The app module's own pip line, not only the generated ones in python-deps.json."""
    commands = [c for c in _manifest_build_commands() if c.startswith("pip3 install")]
    assert commands, "the manifest's app module does not pip3 install anything"
    for command in commands:
        for flag in ("--no-index", '--find-links="file://${PWD}"', "--no-build-isolation"):
            assert flag in command, (
                f"the manifest's {command!r} lacks {flag}: the build could reach PyPI or "
                "build a wheel with whatever is on the SDK")


def _finish_args() -> list[str]:
    block = re.search(r"(?ms)^finish-args:\n(.*?)^\S", _read(MANIFEST) + "\nend")
    assert block, "the manifest has no finish-args"
    return [line.strip()[2:] for line in block.group(1).splitlines()
            if line.strip().startswith("- ")]


def test_finish_args_grant_what_the_metainfo_promises():
    """The metainfo tells the user the app reads a checkout on the host and drives host
    tools, and the manifest's comments say why no narrower grant works. Narrowing one of
    these silently turns that text into a lie, so the two are held together here: change
    the permission, the reason in the manifest and the promise in the metainfo as one.
    """
    granted = set(_finish_args())
    for needed, why in [
        ("--filesystem=host", "the hugmesh-generator checkout is wherever the user put it"),
        ("--talk-name=org.freedesktop.Flatpak", "host tools run through flatpak-spawn --host"),
        ("--share=network", "a local mesh, a registry and the readiness probes"),
        ("--socket=wayland", "the display"),
        ("--socket=fallback-x11", "the display, where there is no Wayland"),
    ]:
        assert needed in granted, f"finish-args lost {needed} ({why}); see the manifest comments"


def test_runtime_branch_matches_what_the_release_workflow_installs():
    # The workflow installs the KDE runtime and SDK by name; if the manifest ever moves to
    # another runtime this test has to learn it, so say so rather than compare nothing.
    assert (_manifest_scalar("runtime"), _manifest_scalar("sdk")) == (
        "org.kde.Platform", "org.kde.Sdk"), "the manifest no longer builds on the KDE runtime"
    version = _manifest_scalar("runtime-version")
    workflow = _read(RELEASE_WORKFLOW)
    for ref in ("org.kde.Platform", "org.kde.Sdk"):
        branches = re.findall(rf"{re.escape(ref)}//([\w.\-]+)", workflow)
        assert branches, f"the release workflow never installs {ref}"
        assert set(branches) == {version}, (
            f"the manifest builds against {ref}//{version} but the release workflow "
            f"installs {sorted(set(branches))}: the job would stop at a missing runtime")


def test_release_bundle_names_where_its_runtime_comes_from():
    """``flatpak build-bundle --runtime-repo=<flathub.flatpakrepo>``.

    The published 0.3.0-beta.1 bundle was exported without it, and on a machine with no
    Flatpak remotes ``flatpak install --user ./hugmesh-studio-0.3.0-beta.1-x86_64.flatpak``
    stopped with "requires the runtime org.kde.Platform/x86_64/6.8 which was not found"
    (2026-10-29). With the key in the bundle, flatpak adds that remote to the same
    installation and pulls the runtime first. The local script is held to the same
    option by test_script_runs_the_same_commands_as_the_release_workflows_flatpak_job.
    """
    lines = [ln for ln in _workflow_flatpak_lines() if ln.startswith("flatpak build-bundle ")]
    assert len(lines) == 1, lines
    words = _words_of(lines[0])
    assert f"--runtime-repo={RUNTIME_REPO_URL}" in words, (
        "the release workflow exports the bundle without --runtime-repo: a machine "
        "without the KDE runtime cannot install it")
    # One Flathub, not two: the job installs the runtime from the remote it adds, and
    # the bundle sends users to Flathub for the same runtime.
    assert any(ln.startswith("flatpak remote-add ") and "flathub.flatpakrepo" in ln
               for ln in _workflow_flatpak_lines())


def _workflow_flatpak_lines() -> list[str]:
    """The commands of the release workflow's ``flatpak`` job, one per entry: backslash
    continuations joined, YAML and shell comments dropped, ``${VERSION}`` kept as written.
    Fails when the job or the commands this file compares are not found, so a renamed job
    cannot turn the comparison into one against nothing."""
    text = _read(RELEASE_WORKFLOW)
    match = re.search(r"(?ms)^  flatpak:\n(.*?)(?=^  \S|\Z)", text)
    assert match, "the release workflow no longer has a job called flatpak"
    kept = [ln.strip() for ln in match.group(1).splitlines()
            if ln.strip() and not ln.strip().startswith("#")]
    joined = re.sub(r"\\\n\s*", " ", "\n".join(kept))
    lines = [ln for ln in joined.splitlines()
             if ln.split(" ", 1)[0] in {"flatpak", "flatpak-builder", "desktop-file-validate",
                                         "appstreamcli", "sha256sum"}]
    assert any(ln.startswith("flatpak-builder ") for ln in lines), lines
    return lines


def _package_version() -> str:
    return re.search(r'(?m)^__version__ = "([^"]+)"',
                     _read(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"))).group(1)


def _words_of(line: str) -> list[str]:
    """A workflow command's words up to its first pipe or redirection."""
    words = shlex.split(line)
    for index, word in enumerate(words):
        if word in {"|", ">", ">>"}:
            return words[:index]
    return words


# ---------------------------------------------------------------------------------------
# The local build script
# ---------------------------------------------------------------------------------------
def test_build_script_is_executable_here_and_in_git():
    if sys.platform != "win32":
        assert os.access(SCRIPT, os.X_OK), f"{SCRIPT} is not executable"
    git = shutil.which("git")
    if git is None:
        pytest.skip("git is not installed: the mode a fresh clone gets cannot be read")
    listed = subprocess.run([git, "-C", GENERATOR_DIR, "ls-files", "-s", "--", SCRIPT],
                            capture_output=True, text=True)
    if listed.returncode != 0:
        pytest.skip("not a git checkout: the mode a fresh clone gets cannot be read")
    if not listed.stdout.strip():
        pytest.skip("build-flatpak-local.sh is not tracked yet (it is checked once committed)")
    assert listed.stdout.split()[0] == "100755", (
        "build-flatpak-local.sh is tracked as mode "
        f"{listed.stdout.split()[0]}; a fresh clone would get a script it cannot run. "
        "Fix with: git update-index --chmod=+x studio/packaging/build-flatpak-local.sh")
    assert _read(SCRIPT).startswith("#!/usr/bin/env bash\n")


#: What the script must never run. A word inside a message or a comment is fine; only a
#: word in COMMAND position counts. The scanner is a static reading of the forms listed
#: here and nothing more; ``test_the_forbidden_command_scanner_sees_what_it_must`` pins
#: each form it reads AND a set of forms outside it, so that nobody mistakes it for a
#: complete reading of shell. It follows a command: behind an environment assignment, a
#: redirection, a full path, a prefix such as env, timeout, coproc, busybox or unshare
#: (and past the prefix options in ``_VALUE_OPTIONS`` that take a separate value, such
#: as ``exec -a NAME`` or ``env -u VAR``; ``env -S 'CMDLINE'`` is read as a command line),
#: past the lock operand of flock and the root of
#: chroot, into a shell's -c string (flock's too), ``eval``, the action string of
#: ``trap``, a here-string fed to a shell or python, ``find -exec``, flatpak-spawn
#: --host, a --command= option and the app id that follows it (``--command=sh APP -c
#: '...'`` and ``--command=flatpak-spawn APP --host ...``, the two forms this script
#: itself uses), a ``function`` definition, a $( ), <( ) or >( ) substitution (in an
#: unquoted heredoc too), ANSI-C quoting (``$'...'``), and a process call in embedded
#: Python, read whole (a call split over lines, ``import subprocess as sp``, ``from
#: subprocess import run``). What it cannot read it reports instead of passing: a
#: sourced file, and a shell or python taking its commands from a pipe, a file or a
#: process substitution. A heredoc is read by whatever consumes it: as Python after
#: ``python3 - <<'PY'``, as shell after ``sh -s <<'EOS'``, as prose after ``cat``.
#: Outside it, by construction of a static reading: a program named through a variable
#: (``"$elevate"``), an alias, a program written in another language (awk, perl, sed),
#: a command run on another machine (ssh), and a wrapper it does not know (taskset,
#: script, strace, ...). (The first version checked the first word of a line only, the
#: second missed the two --command= forms above, the third a process substitution: three
#: mutation batteries put sudo behind each and every one survived.)
_FORBIDDEN = {"sudo", "doas", "pkexec", "run0", "su", "apt", "apt-get", "dpkg", "dnf", "yum",
              "pacman", "zypper", "emerge", "brew", "nix-env", "snap",
              # Found by a mutation round: these installed software, or entered another
              # namespace, and the test only failed because the tool happened to be absent
              # from the test's PATH. A language's package manager is a package manager.
              "apk", "pip", "pip3", "pipx", "conda", "cargo", "gem", "npm", "nsenter"}
#: After these the command position is still open: the next word is run, not consumed.
_PREFIXES = {"exec", "command", "builtin", "env", "nohup", "xargs", "time", "nice", "ionice",
             "timeout", "setsid", "stdbuf", "chroot", "flatpak-spawn", "coproc", "busybox",
             "unshare", "flock",
             "then", "do", "else", "elif", "if", "while", "until", "!", "{"}
#: Options of a prefix that take their value as the NEXT token, so that value is not
#: mistaken for the command (``exec -a flatpak sudo`` runs sudo under the name flatpak).
_VALUE_OPTIONS = {
    "exec": {"-a"},
    "env": {"-u", "--unset", "-C", "--chdir"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "--pid"},
    "xargs": {"-I", "-d", "--delimiter", "-a", "--arg-file", "-E", "-L", "--max-lines",
              "-n", "--max-args", "-P", "--max-procs", "-s", "--max-chars"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "flock": {"-w", "--wait", "--timeout", "-E", "--conflict-exit-code"},
    "chroot": {"--userspec", "--groups"},
    "unshare": {"-S", "--setuid", "-G", "--setgid", "--setgroups", "--propagation", "--root",
                "--wd", "--map-user", "--map-group"},
}
#: These take an operand (the lock file or descriptor, the new root) BEFORE the command.
_OPERAND_FIRST = {"flock", "chroot"}
#: find's -exec and friends open a command position in the middle of find's own arguments.
_FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
#: These run the string after -c as a command line of its own, or read stdin after - / -s.
_SHELLS = {"sh", "bash", "dash", "zsh", "ksh", "ash"}
_PYTHONS = {"python", "python3"}
#: These run a file the scanner cannot see.
_SOURCE = {"source", "."}
_UNREADABLE_SOURCE = "<a sourced file>"
_PROCESS_SUBSTITUTION = {"<(", ">("}
_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
_COUNT = re.compile(r"\d+(?:\.\d+)?[smhd]?")               # nice -n 10, timeout 30s
_C_OPTION = re.compile(r"-[a-zA-Z]*c[a-zA-Z]*")             # -c, -ec, -xc
_COMMAND_OPTION = re.compile(r"--?(?:command|exec)=(.+)")   # flatpak run --command=X
_ENV_SPLIT_LONG = re.compile(r"--split-string(?:=(.*))?", re.DOTALL)   # env --split-string=STR
_ENV_SPLIT_SHORT = re.compile(r"-[a-zA-Z]*S(.*)", re.DOTALL)           # env -S STR, -iS STR, -S'STR'
#: A heredoc opener, and not the three < of a here-string.
_HEREDOC_OPENER = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)(\w+)\1")
_STRING_LITERAL = re.compile(r"""(['"])(.*?)\1""")
_IMPORT_ALIAS = re.compile(r"\bimport\s+subprocess\s+as\s+(\w+)")
_FROM_IMPORT = re.compile(r"\bfrom\s+subprocess\s+import\s+\(?([^)\n]+)")
_PROCESS_FUNCTIONS = {"run", "call", "check_call", "check_output", "Popen", "getoutput",
                      "getstatusoutput"}


def _unreadable_stdin(program: str) -> str:
    return f"<{program} reading its commands from a pipe or a file>"


def _program(token: str) -> str:
    """The program a token names: its base name, and the first word if it is a string."""
    words = token.split()
    return (words[0] if words else token).rsplit("/", 1)[-1]


def _env_split_string(token: str) -> str | None:
    """env's -S / --split-string takes a command line in ONE string: None when the token is
    not that option, else the string if it is attached to the option ('' if it is the next
    token)."""
    for pattern in (_ENV_SPLIT_LONG, _ENV_SPLIT_SHORT):
        match = pattern.fullmatch(token)
        if match:
            return match.group(1) or ""
    return None


def _is_separator(token: str) -> bool:
    return bool(token) and set(token) <= set("();|&")


def _is_redirection(token: str) -> bool:
    bare = token.strip("0123456789")           # shlex hands 2>/dev/null over as 2, >, /dev/null
    return bool(bare) and set(bare) <= set("<>&|") and ("<" in bare or ">" in bare)


def _tokens(line: str) -> list[str]:
    # $'...' is a quoted string with C escapes; shlex would read the $ into the word.
    line = line.replace("$'", "'")
    # A quote that closes on a later line (the -c '...' body of smoke test 3) is closed
    # here instead, so the words before it are still read as words and not as one lump.
    for tail in ("", "'", '"'):
        try:
            lexer = shlex.shlex(line + tail, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            return list(lexer)
        except ValueError:
            continue
    return line.split()


def _substitutions(line: str):
    """The text inside each ``$( ... )``, ``<( ... )``, ``>( ... )`` and backtick pair,
    nested ones included. A process substitution runs its commands like ``$( )`` does;
    what the command around it then reads from them is another matter (``_scan_line``)."""
    for opener in ("$(", *_PROCESS_SUBSTITUTION):
        start = line.find(opener)
        while start >= 0:
            depth, end = 0, start + 1
            while end < len(line):
                depth += {"(": 1, ")": -1}.get(line[end], 0)
                if depth == 0:
                    break
                end += 1
            yield line[start + 2:end]
            start = line.find(opener, start + 2)
    yield from re.findall(r"`([^`]*)`", line)


def _python_calls(text: str):
    """Each process call in a piece of Python, as (line offset, the call's text).

    The text runs from the call's name to the parenthesis that closes it, so a call split
    over several lines is one call. Names: ``subprocess.<anything>(``, the same through
    ``import subprocess as <alias>``, the functions ``from subprocess import`` binds,
    ``os.system`` and the ``os.exec*`` / ``os.spawn*`` / ``os.popen`` family, and
    ``Popen`` / ``check_call`` / ``check_output`` on their own.
    """
    modules = ["subprocess", *_IMPORT_ALIAS.findall(text)]
    bare = {"Popen", "check_call", "check_output"}
    for imported in _FROM_IMPORT.findall(text):
        for name, alias in re.findall(r"(\w+)(?:\s+as\s+(\w+))?", imported):
            if name in _PROCESS_FUNCTIONS:
                bare.add(alias or name)
    pattern = re.compile(r"\b(?:(?:%s)\.\w+|os\.(?:system|exec\w*|spawn\w*|popen)|%s)\s*\(" % (
        "|".join(map(re.escape, modules)), "|".join(map(re.escape, sorted(bare)))))
    for match in pattern.finditer(text):
        depth, end = 0, match.end() - 1
        while end < len(text):
            depth += {"(": 1, ")": -1}.get(text[end], 0)
            if depth == 0:
                break
            end += 1
        yield text.count("\n", 0, match.start()), text[match.start():end + 1]


def _python_call_words(text: str):
    """(line offset, program) for each string argument of a process call: subprocess.run(["sudo"])."""
    for offset, call in _python_calls(text):
        for _quote, literal in _STRING_LITERAL.findall(call):
            if literal.strip():
                yield offset, _program(literal)


def _after_command(word: str):
    """What follows a command word: is the position still open, and what the word reads."""
    if word == "eval":
        return True, ("eval", "eval")
    if word == "trap":                         # trap 'ACTION' SIGNAL...: the action is shell
        return False, ("next", "trap")
    if word in _SHELLS | _PYTHONS:
        return False, ("await-c", word)
    if word in _OPERAND_FIRST:
        return False, ("operand", word)
    if word in _PREFIXES:
        return True, ("prefix", word)
    return False, None


def _scan_line(line: str) -> tuple[list[str], str | None]:
    """The words one line of shell puts in command position, and the shell or python (if
    any) left reading its commands from standard input at the end of the line, which is
    what a heredoc on that line feeds."""
    words: list[str] = []
    expecting = True        # the next word is run
    skip_next = False       # the next word is a redirection target or a function name
    piped = False           # this pipeline segment reads what the previous one wrote
    from_file = False       # this segment has a < redirection
    substitution = 0        # inside <( ) or >( ): its commands are read by _substitutions
    inner = None            # ("app", X): --command=X seen, the app id still to come;
                            # ("await-c", X): a shell or python X was named, its -c string
                            # or script may follow; ("next", X): the string X runs is next;
                            # ("stdin", X): X reads standard input; ("eval", "eval");
                            # ("prefix", X): behind the prefix X, its options still to come;
                            # ("operand", X): X takes an operand before its command

    def unreadable():
        if inner and inner[0] in ("await-c", "stdin") and (piped or from_file):
            words.append(_unreadable_stdin(inner[1]))

    for token in _tokens(line):
        if skip_next:
            skip_next = False
            continue
        if substitution:
            # shlex hands a separator or a redirection glued to the closing parenthesis over
            # as ONE token: `);`, `)&&`, `)|`, `)>`. Count every parenthesis of a punctuation
            # token; where the substitution closes, what is left of the token is read as a
            # token of its own, so `cat <(ls); sudo x` still has a command after the `;`.
            if not token or not set(token) <= set("();<>|&"):
                continue
            for at, char in enumerate(token):
                substitution += {"(": 1, ")": -1}.get(char, 0)
                if substitution == 0:
                    token = token[at + 1:]
                    break
            else:
                continue
            if not token:
                continue
        if token in _PROCESS_SUBSTITUTION:
            # A shell or python handed <( ) reads commands another program wrote.
            if inner and inner[0] in ("await-c", "stdin"):
                words.append(_unreadable_stdin(inner[1]))
                inner = None
            substitution = 1
            continue
        if _is_redirection(token):
            if token.endswith("<<<") and inner and inner[0] in ("await-c", "stdin"):
                inner = ("next", inner[1])     # a here-string is the script X reads
                continue
            if "<" in token and "<<" not in token:
                from_file = True
            skip_next = True
            continue
        if _is_separator(token):
            unreadable()
            expecting, inner = True, None
            piped, from_file = token in ("|", "|&"), False
            continue
        option = _COMMAND_OPTION.fullmatch(token)
        if option:                             # --command=X runs X wherever the option sits
            word = _program(option.group(1))
            words.append(word)
            inner = ("app", word)
            continue
        if token in _FIND_EXEC:                # find ... -exec CMD {} \;
            expecting, inner = True, None
            continue
        if inner and inner[0] == "app":
            if not token.startswith("-"):      # the app id: X's own command line follows
                expecting, inner = _after_command(inner[1])
            continue
        if inner and inner[0] in ("next", "eval"):
            if not token.startswith("-"):
                if inner[1] in _PYTHONS:
                    words.extend(word for _offset, word in _python_call_words(token))
                else:
                    words.extend(_scan_line(token)[0])
                inner = inner if inner[0] == "eval" else None
            continue
        if inner and inner[0] == "await-c":
            if _C_OPTION.fullmatch(token):
                inner = ("next", inner[1])
            elif token == "-" or (token == "-s" and inner[1] in _SHELLS):
                inner = ("stdin", inner[1])    # the script comes on stdin; the rest are its arguments
            elif not token.startswith("-"):    # bash script.sh: a file, not a string
                inner = None
            continue
        if inner and inner[0] == "stdin":
            continue
        if inner and inner[0] == "operand":    # flock [-n] LOCK CMD; chroot [opts] ROOT CMD
            if token in _VALUE_OPTIONS[inner[1]]:
                skip_next = True
            elif not token.startswith("-"):
                expecting, inner = True, ("prefix", inner[1])
            continue
        if not expecting:
            continue
        if token.startswith("-") or _ASSIGNMENT.match(token) or _COUNT.fullmatch(token):
            if inner and inner[0] == "prefix":
                attached = _env_split_string(token) if inner[1] == "env" else None
                if attached is not None:        # env -S 'sudo -n true': a command line in one string
                    if attached:
                        words.extend(_scan_line(attached)[0])
                    else:
                        inner = ("next", "env")
                elif token in _VALUE_OPTIONS.get(inner[1], ()):
                    skip_next = True
                elif inner[1] == "flock" and _C_OPTION.fullmatch(token):
                    inner = ("next", "flock")  # flock LOCK -c 'COMMANDS'
            continue                           # an option, an assignment or a count: still to come
        word = _program(token)
        if word == "function":                 # function NAME { ... }: the name is not run
            skip_next = True
            continue
        if word in _SOURCE:
            words.append(_UNREADABLE_SOURCE)
            expecting = False
            continue
        # coproc NAME { ...; }: the name is not run, the compound command after it is.
        named_coprocess = inner == ("prefix", "coproc")
        words.append(word)
        expecting, inner = _after_command(word)
        expecting = expecting or named_coprocess
    unreadable()
    reader = inner[1] if inner and inner[0] in ("await-c", "stdin") and not (piped or from_file) else None
    return words, reader


def _line_command_words(line: str):
    """Yield each word one line of shell puts in command position."""
    yield from _scan_line(line)[0]


def _heredoc_words(reader: str | None, first_line: int, body: list[str]):
    if reader in _PYTHONS:
        for offset, word in _python_call_words("\n".join(body)):
            yield first_line + offset, word
    elif reader in _SHELLS:
        for offset, line in enumerate(body):
            for word in _line_command_words(line.strip()):
                yield first_line + offset, word


def _command_words(text: str):
    """Yield ``(line, word)`` for each word the script puts where a command goes.

    Skips comments, joins backslash continuations, scans substitutions on their own (a
    quoted string is otherwise one opaque token and ``x="$(sudo foo)"`` would sail
    through), and hands a heredoc body to what reads it: embedded Python is read whole
    for process calls, a shell script fed to ``sh -s`` line by line as shell, and an
    unquoted body's ``$( )`` as shell whatever reads it, so the usage text may say "sudo"
    and ``subprocess.run(["sudo"])`` may not.
    """
    text = text.replace("\\\n", " ")
    heredoc = None          # (end marker, quoted, reader, first body line, body lines)
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if heredoc is not None:
            end, quoted, reader, first_line, body = heredoc
            if line == end:
                heredoc = None
                yield from _heredoc_words(reader, first_line, body)
            else:
                body.append(raw)
                if not quoted:                 # $( ) expands in an unquoted heredoc
                    for piece in _substitutions(line):
                        for word in _line_command_words(piece):
                            yield number, word
            continue
        if not line or line.startswith("#"):
            continue
        seen: list[str] = []
        readers: list[str | None] = []
        for piece in [*_substitutions(line), line]:
            words, reader = _scan_line(piece)
            readers.append(reader)
            for word in words:
                if word not in seen:           # a nested $( ) is scanned once per level
                    seen.append(word)
                    yield number, word
        opener = _HEREDOC_OPENER.search(line)
        if opener:
            heredoc = (opener.group(2), bool(opener.group(1)),
                       next((r for r in readers if r), None), number + 1, [])
    if heredoc is not None:                    # never closed: read what there is
        yield from _heredoc_words(heredoc[2], heredoc[3], heredoc[4])


def _forbidden_in(text: str) -> list[tuple[int, str]]:
    return [(n, w) for n, w in _command_words(text) if w in _FORBIDDEN or w.startswith("<")]


def test_build_script_never_runs_sudo_or_a_package_manager():
    hits = _forbidden_in(_read(SCRIPT))
    assert not hits, (
        "build-flatpak-local.sh must work on a machine with no sudo and no apt, but it runs, "
        "or hides from the scanner: "
        + ", ".join(f"{word} (line {line})" for line, word in hits))


@pytest.mark.parametrize("snippet, expected", [
    ("sudo flatpak install foo", ["sudo"]),
    ("flatpak info x && apt-get install -y flatpak-builder", ["apt-get"]),
    ("if ! command -v sudo >/dev/null; then :; fi", ["sudo"]),
    ('x="$(sudo true)"', ["sudo"]),
    ('x="$(true && sudo true)"', ["sudo"]),
    ("exec sudo -n true", ["sudo"]),
    ("echo 'run it without sudo or apt'", []),
    ("# sudo apt-get install flatpak-builder", []),
    ("die \"flatpak-builder, sudo and apt are not needed\"", []),
    ("flatpak run --user \\\n   apt org.flatpak.Builder", []),
    ("true \\\n  && sudo true", ["sudo"]),
    ("cat <<'EOF'\nsudo apt-get install foo\nEOF\nflatpak --version", []),
    ("flatpak --version  # sudo would be wrong here", []),
    # Behind an environment assignment, a prefix, a full path, a shell's -c, eval,
    # flatpak-spawn --host, a redirection, a count, a --command= option.
    ("DEBIAN_FRONTEND=noninteractive apt-get install -y flatpak-builder", ["apt-get"]),
    ("LC_ALL=C sudo -n true", ["sudo"]),
    ("env LC_ALL=C sudo -n true", ["sudo"]),
    ("/usr/bin/sudo -n true", ["sudo"]),
    ("bash -c 'sudo -n true'", ["sudo"]),
    ("sh -ec 'apt-get install -y x'", ["apt-get"]),
    ("bash script.sh sudo", []),
    ("eval 'sudo -n true'", ["sudo"]),
    ("flatpak-spawn --host sudo -n true", ["sudo"]),
    ("2>/dev/null sudo -n true", ["sudo"]),
    (">/dev/null 2>&1 sudo -n true", ["sudo"]),
    ("timeout 30 sudo -n true", ["sudo"]),
    ("nice -n 10 sudo -n true", ["sudo"]),
    ("flatpak run --command=sudo org.flatpak.Builder -n true", ["sudo"]),
    ("flatpak run --user --command=flatpak-builder org.flatpak.Builder --user", []),
    ("python3 - <<'PY'\nimport subprocess\nsubprocess.run([\"sudo\", \"-n\", \"true\"])\nPY",
     ["sudo"]),
    ("python3 - <<'PY'\nprint(\"sudo is not needed\")\nPY", []),
    ("python3 -c 'import os; os.system(\"sudo -n true\")'", ["sudo"]),
    ("run0 true", ["run0"]),
    # The script's own two forms: a shell named by --command= with the app id before its
    # -c string, and flatpak-spawn named by --command= with the app id before --host. A
    # second battery put sudo in both and the scanner, which took the app id for a script
    # file, saw neither.
    ("flatpak run --user --nofilesystem=host --command=sh \"$app_id\" -c 'sudo -n true' _ x y",
     ["sudo"]),
    ("flatpak run --user --nofilesystem=host --command=sh \"$app_id\" -c 'exit 0' _ x y", []),
    ("flatpak run --command=bash org.x -lc 'apt-get install y'", ["apt-get"]),
    ('"${builder[@]}" --command=flatpak-spawn org.flatpak.Builder --host sudo -n "$wrapper" --version',
     ["sudo"]),
    ('"${builder[@]}" --command=flatpak-spawn org.flatpak.Builder --host "$wrapper" --version', []),
    ("flatpak run --command=sh org.x -c 'sudo -n true' 2>&1 | tee log", ["sudo"]),
    # A shell fed a heredoc reads it as commands; python fed one is read for process
    # calls, whole, so a call over two lines, an aliased import and a from-import count,
    # and a message beside a harmless call does not.
    ("flatpak run --command=sh org.x -s <<'EOS'\nsudo -n true\nEOS", ["sudo"]),
    ("flatpak run --command=sh org.x -s <<'EOS'\necho 'no sudo here'\nEOS", []),
    ("python3 - <<'PY'\nimport subprocess\nsubprocess.run(\n    [\"sudo\", \"-n\", \"true\"])\nPY",
     ["sudo"]),
    ("python3 - <<'PY'\nimport subprocess as sp\nsp.run([\"sudo\", \"-n\", \"true\"])\nPY", ["sudo"]),
    ("python3 - <<'PY'\nfrom subprocess import run\nrun([\"sudo\"])\nPY", ["sudo"]),
    ("python3 - \"$specs\" <<'PY'\nimport os\nos.system(\"sudo -n true\")\nPY", ["sudo"]),
    ("python3 - <<'PY'\nimport subprocess\nsubprocess.run([\"flatpak\", \"--version\"])\n"
     "print(\"sudo is not needed\")\nPY", []),
    # An unquoted heredoc expands $( ) whatever reads it; a quoted one does not.
    ("cat <<EOF\n$(sudo -n true)\nEOF", ["sudo"]),
    ("cat <<'EOF'\n$(sudo -n true)\nEOF", []),
    ("cat <<EOF\nno sudo needed\nEOF", []),
    ("function elevate { sudo -n true; }", ["sudo"]),
    # What the scanner cannot read it reports, so the test fails instead of passing blind.
    (". ./elevate.sh", [_UNREADABLE_SOURCE]),
    ("source elevate.sh", [_UNREADABLE_SOURCE]),
    ("echo 'sudo -n true' | sh", [_unreadable_stdin("sh")]),
    ("sh < commands.txt", [_unreadable_stdin("sh")]),
    ("bash --version", []),
    ("python3 -m pip --version", []),
    # A third battery found `bash <(printf ... "sudo")` survived the whole suite, and a
    # probe of forty-two snippets found fifteen more silent forms. The ones a script
    # like this could plausibly grow (two of them, trap and flock, are idioms it already
    # uses) are read now: a process substitution runs its own commands, and a shell or
    # python handed one reads what another program wrote, which is reported; a
    # here-string is the script of the shell or python it feeds and prose for anything
    # else; trap's action string and flock's command or -c string are shell; coproc,
    # busybox and unshare are prefixes; exec -a NAME, env -u VAR, timeout -s SIG,
    # xargs -I X and stdbuf -o MODE take a value the scanner must not run; flock and
    # chroot take an operand first; find -exec opens a command position; $'...' is a
    # quoted string.
    ('bash <(printf "%s" "sudo -n true") || true', [_unreadable_stdin("bash")]),
    ("sh <(printf 'apt-get install -y x')", [_unreadable_stdin("sh")]),
    ("python3 <(cat gen.py)", [_unreadable_stdin("python3")]),
    ("diff <(sudo ls) <(ls)", ["sudo"]),
    ("diff <(ls) <(ls -a)", []),
    ("tee >(sudo -n true)", ["sudo"]),
    ("while read -r f; do sudo rm \"$f\"; done < <(ls)", ["sudo"]),
    ("sh <<< 'sudo -n true'", ["sudo"]),
    ("sh - <<< 'sudo -n true'", ["sudo"]),
    ("python3 - <<< 'import os; os.system(\"sudo -n true\")'", ["sudo"]),
    ("cat <<< 'sudo is fine as prose'", []),
    ("trap 'sudo -n true; on_exit' EXIT", ["sudo"]),
    ("trap on_exit EXIT", []),
    ('flock "$lock" sudo -n true', ["sudo"]),
    ('flock -n "$lock" -c "echo hi; sudo -n true"', ["sudo"]),
    ('flock -w 5 "$lock" sudo -n true', ["sudo"]),
    ("flock -n 9 || die 'another build is running'", []),
    ("chroot /newroot sudo -n true", ["sudo"]),
    ("coproc sudo -n true", ["sudo"]),
    ("coproc helper { sudo -n true; }", ["sudo"]),
    ("exec -a flatpak sudo -n true", ["sudo"]),
    ("env -u GH_TOKEN sudo -n true", ["sudo"]),
    ("env -u GH_TOKEN -u GITHUB_TOKEN gh pr list", []),
    ("timeout -s KILL 30 sudo -n true", ["sudo"]),
    ("xargs -I {} sudo rm {}", ["sudo"]),
    ("stdbuf -o L sudo -n true", ["sudo"]),
    (r"find . -exec sudo rm {} \;", ["sudo"]),
    ("unshare -r apt-get install x", ["apt-get"]),
    ("busybox sh -c 'sudo -n true'", ["sudo"]),
    ("sh -c $'sudo -n true'", ["sudo"]),
    # The fourth skeptic round found two things the fix round took away: env -S STRING (a
    # whole command line in one string, stepped over as the VALUE of a prefix option) and
    # a separator glued to the closing parenthesis of a process substitution (`);` `)&&`
    # `)|` `)>`, one token to shlex, which ended the command position that follows).
    ("env -S 'sudo -n true'", ["sudo"]),
    ("env -S sudo -n true", ["sudo"]),
    ("env -i -S 'sudo -n true'", ["sudo"]),
    ("env -iS 'sudo -n true'", ["sudo"]),
    ("env -S'sudo -n true'", ["sudo"]),
    ("env --split-string 'sudo -n true'", ["sudo"]),
    ("env --split-string='sudo -n true'", ["sudo"]),
    ("env -S 'true'", []),
    ("env -u GH_TOKEN -S 'gh pr list'", []),
    ("cat <(ls); sudo -n true", ["sudo"]),
    ("cat <(ls)&& sudo -n true", ["sudo"]),
    ("cat <(ls)| sudo tee x", ["sudo"]),
    ("tee >(cat)>/dev/null; sudo -n true", ["sudo"]),
    ("diff <(ls) <(ls -a); sudo -n true", ["sudo"]),
    ("diff <(ls)<(ls -a); sudo -n true", ["sudo"]),
    ("cat <(ls); true", []),
    ("tee >(cat)>/dev/null; true", []),
    ("busybox ash -c 'sudo -n true'", ["sudo"]),
    ("ash -c 'sudo -n true'", ["sudo"]),
    # A language's package manager, and nsenter (a mutation round put each after the last
    # step: the suite failed only because the tool was not on the test's PATH).
    ("pip install requests", ["pip"]),
    ("pip3 install --user requests", ["pip3"]),
    ("env PIP_NO_INPUT=1 pipx install x", ["pipx"]),
    ("npm install -g x", ["npm"]),
    ("cargo install x", ["cargo"]),
    ("apk add flatpak-builder", ["apk"]),
    ("nsenter -t 1 -m -u -i -n sudo -n true", ["nsenter"]),
    ("python3 -m pip --version", []),
    ("echo 'pip install is not run here'", []),
    # Outside the scanner, pinned so nobody mistakes it for more than it is: a program
    # named through a variable (invisible to any static reading), a command run on
    # another machine, a program in another language, an alias, and a wrapper it does
    # not know. Teach it one and move that line up, with its expected hit.
    ('elevate=sudo; "$elevate" -n true', []),
    ("ssh host sudo -n true", []),
    ("awk 'BEGIN { system(\"sudo -n true\") }'", []),
    ("perl -e 'system(\"sudo -n true\")'", []),
    ("alias s='sudo -n true'; s", []),
    ("taskset -c 0 sudo -n true", []),
    ("script -qc 'sudo -n true' /dev/null", []),
    # Nor does it read what a command DOES to files: a deletion of the real flatpak
    # directory and a write to a shell startup file are plain commands. The scripted run
    # covers them instead, by planting a canary in the fake HOME and checking afterwards
    # that nothing there changed (``_home_untouched``): only on the path the run takes.
    # unshare -r only maps the caller to a root inside a new user namespace: it grants
    # nothing, so it is a prefix to read through (the command after it is judged), not a
    # forbidden word of its own. A skeptic listed it as "not caught"; what follows it is.
    ("unshare -r true", []),
    ("unshare -r sudo -n true", ["sudo"]),
    ("rm -rf \"$HOME/.local/share/flatpak\"", []),
    ("echo 'export PATH=x' >> \"$HOME/.bashrc\"", []),
], ids=["plain", "after-and", "probe", "substitution", "substitution-after-and",
        "exec-prefix", "in-string", "in-comment", "in-message", "argument-on-continuation",
        "command-on-continuation", "in-heredoc", "trailing-comment",
        "env-assignment", "env-assignment-sudo", "env-prefix", "full-path", "bash-c", "sh-ec",
        "bash-script-argument", "eval", "flatpak-spawn", "redirection-prefix",
        "two-redirections", "timeout", "nice", "command-option", "command-option-benign",
        "python-subprocess", "python-message", "python-c", "run0",
        "command-option-sh-c", "command-option-sh-c-benign", "command-option-bash-lc",
        "command-option-flatpak-spawn-host", "command-option-flatpak-spawn-host-benign",
        "command-option-sh-c-piped",
        "sh-s-heredoc", "sh-s-heredoc-benign", "python-call-over-two-lines",
        "python-aliased-import", "python-from-import", "python-stdin-with-argument",
        "python-message-beside-a-call",
        "unquoted-heredoc-substitution", "quoted-heredoc-substitution", "unquoted-heredoc-prose",
        "function-keyword", "sourced-file", "source-keyword", "shell-from-pipe",
        "shell-from-file", "shell-version", "python-m",
        "shell-from-process-substitution", "sh-from-process-substitution",
        "python-from-process-substitution", "process-substitution-command",
        "process-substitution-benign", "output-process-substitution",
        "loop-fed-by-process-substitution", "here-string", "here-string-after-dash",
        "python-here-string", "here-string-as-prose", "trap-action", "trap-benign",
        "flock-command", "flock-c-string", "flock-wait-value", "flock-lock-only",
        "chroot-command", "coproc", "coproc-named", "exec-a-name", "env-unset-value",
        "env-unset-benign", "timeout-signal-value", "xargs-replace-value",
        "stdbuf-mode-value", "find-exec", "unshare", "busybox-sh-c", "ansi-c-quoting",
        "env-S-quoted", "env-S-bare", "env-i-S", "env-iS-bundled", "env-S-attached",
        "env-split-string", "env-split-string-equals", "env-S-benign", "env-S-after-unset-benign",
        "substitution-then-semicolon", "substitution-then-and", "substitution-then-pipe",
        "output-substitution-then-redirect", "two-substitutions-then-semicolon",
        "adjacent-substitutions-then-semicolon", "substitution-then-benign",
        "output-substitution-benign", "busybox-ash-c", "ash-c",
        "pip", "pip3", "pipx-behind-env", "npm", "cargo", "apk", "nsenter",
        "python-m-pip-version", "pip-in-message",
        "outside-variable", "outside-ssh", "outside-awk", "outside-perl",
        "outside-alias", "outside-unknown-wrapper", "outside-script-command",
        "unshare-alone-is-not-forbidden", "unshare-then-sudo-is-read",
        "outside-rm-real-flatpak-dir", "outside-write-to-shell-rc"])
def test_the_forbidden_command_scanner_sees_what_it_must(snippet, expected):
    """The scanner is what the test above stands on, so it is pinned in both directions:
    what it reads, and what is outside it (the ``outside-*`` cases expect nothing, and
    must be moved up with a hit when the scanner learns the form)."""
    assert [word for _line, word in _forbidden_in(snippet)] == expected


_SYSTEM_INSTALLATION = re.compile(r"--system|--installation=.*")


def _system_installation_in(text: str) -> list[tuple[int, str]]:
    """Every ``--system`` / ``--installation=`` token outside a comment, as (line, token)."""
    text = text.replace("\\\n", " ")
    return [(number, token)
            for number, line in enumerate(text.splitlines(), 1)
            if line.strip() and not line.strip().startswith("#")
            for token in _tokens(line.strip()) if _SYSTEM_INSTALLATION.fullmatch(token)]


def test_build_script_never_names_the_system_installation():
    """Everything goes into the private user directory. ``--system`` (or
    ``--installation=``) on any flatpak call would write to /var/lib/flatpak, which needs
    root and is shared with everything else on the machine. The scripted-fake test below
    sees the calls the script makes up to its first smoke test; this sees every line.
    """
    hits = _system_installation_in(_read(SCRIPT))
    assert not hits, ("build-flatpak-local.sh names the system installation: "
                      + ", ".join(f"{token} (line {line})" for line, token in hits))


@pytest.mark.parametrize("snippet, expected", [
    ("flatpak install --system -y flathub org.foo.Bar", ["--system"]),
    ("flatpak --installation=extra install org.foo.Bar", ["--installation=extra"]),
    ("flatpak install --user -y flathub org.foo.Bar", []),
    ("# never --system here", []),
    ("die 'this never uses --system'", []),
], ids=["system", "installation", "user", "comment", "message"])
def test_the_system_installation_scanner_sees_what_it_must(snippet, expected):
    assert [token for _line, token in _system_installation_in(snippet)] == expected


#: The flatpak subcommands that read or change an installation. Without --user they act on
#: the SYSTEM installation (install, run) or look through every installation (info, list,
#: remotes), whatever FLATPAK_USER_DIR says; the script's re-run logic depends on that: on a
#: host with a system-wide flathub, a `flatpak remotes` without --user would see it, skip
#: the private remote-add, and fail late. ``build-bundle`` is not here: it reads a
#: repository directory and no installation. A subcommand not listed is not checked.
_INSTALLATION_SUBCOMMANDS = (
    "install", "uninstall", "update", "remote-add", "remote-delete", "remote-modify",
    "remote-ls", "remote-info", "remotes", "info", "list", "run", "repair", "override",
    "mask", "pin", "make-current", "history", "search", "ps", "kill", "config")
_FLATPAK_CALL = re.compile(
    r"(?<![\w./$-])flatpak\s+((?:-\S+\s+)*)(" + "|".join(sorted(_INSTALLATION_SUBCOMMANDS, key=len,
                                                                reverse=True))
    + r")(?![\w-])([^;&|)\n]*)")


def _flatpak_calls_in(text: str) -> list[tuple[int, str, bool]]:
    """Every ``flatpak <installation subcommand> ...`` outside a comment, as (line,
    subcommand, whether --user comes among its options). The options are the words before
    the first operand: for ``run`` that is the app id, so the flatpak-builder's own --user
    after it does not count for flatpak. A call is read up to the next ``;`` ``&`` ``|``
    ``)`` or line end, backslash continuations joined; a call hidden in a variable or an
    array (``"${builder[@]}" ...``) is not seen here: the scripted run covers those."""
    found: list[tuple[int, str, bool]] = []
    logical, start = "", 0
    for number, line in enumerate(text.splitlines(), 1):
        if not logical:
            start = number
        if line.rstrip().endswith("\\"):
            logical += line.rstrip()[:-1] + " "
            continue
        logical += line
        stripped = logical.strip()
        logical = ""
        if not stripped or stripped.startswith("#"):
            continue
        for match in _FLATPAK_CALL.finditer(stripped):
            words = match.group(1).split() + match.group(3).split()
            user = False
            for word in words:
                if word == "--user":
                    user = True
                    break
                if not word.startswith("-"):
                    break
            found.append((start, match.group(2), user))
    return found


def test_every_flatpak_call_in_the_build_script_names_the_private_user_installation():
    """The scripted-fake test below sees the calls the script makes on the path that run
    takes; this reads every line, including the ones that path never reaches (the
    validator that falls back to the Builder's copy, the re-run's uninstall). A mutation
    round removed --user from five calls one at a time and the suite stayed green."""
    calls = _flatpak_calls_in(_read(SCRIPT))
    seen = {sub for _line, sub, _user in calls}
    assert {"remotes", "remote-add", "info", "install", "uninstall", "run"} <= seen, (
        f"the reading found only {sorted(seen)}: the pattern no longer matches the script")
    bare = [f"flatpak {sub} (line {line})" for line, sub, user in calls if not user]
    assert not bare, ("these calls do not name --user, so they act on the system installation "
                      "or on every installation: " + ", ".join(bare))


@pytest.mark.parametrize("snippet, expected", [
    ("flatpak install --user -y flathub org.foo.Bar", [("install", True)]),
    ("flatpak install -y flathub org.foo.Bar", [("install", False)]),
    ("flatpak remotes --columns=name", [("remotes", False)]),
    ("remotes=\"$(flatpak remotes --user --columns=name)\"", [("remotes", True)]),
    ("if flatpak info \"$app_id\" >/dev/null 2>&1; then", [("info", False)]),
    ("flatpak list >/dev/null", [("list", False)]),
    ("flatpak run --user \\\n   --command=x app", [("run", True)]),
    ("flatpak run --command=flatpak-builder org.flatpak.Builder --user", [("run", False)]),
    ("flatpak uninstall -y --noninteractive org.foo.Bar", [("uninstall", False)]),
    ("flatpak --user install -y flathub org.foo.Bar", [("install", True)]),
    ("flatpak --version", []),
    ("flatpak --default-arch", []),
    ("flatpak build-bundle repo out.flatpak org.foo.Bar", []),
    ("# flatpak install -y flathub org.foo.Bar", []),
    ("die 'the flatpak program is not installed'", []),
    ("die 'it needs the flatpak session helper'", []),
    ("flatpak info --user a && flatpak info b", [("info", True), ("info", False)]),
    ("x=\"$(flatpak info --user --show-commit \"$app_id\")\"", [("info", True)]),
], ids=["user", "no-user", "remotes-no-user", "remotes-in-substitution", "info-no-user",
        "list-no-user", "continuation", "builders-own-user-flag-does-not-count",
        "uninstall-no-user", "global-option-before-subcommand", "version", "default-arch",
        "build-bundle", "comment", "message", "message-session", "two-calls", "show-commit"])
def test_the_user_installation_reading_sees_what_it_must(snippet, expected):
    assert [(sub, user) for _line, sub, user in _flatpak_calls_in(snippet)] == expected


def _run_script(tmp_path, *args, extra_env=None, path=None):
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    env = {"PATH": path if path is not None else os.environ["PATH"], "HOME": str(home)}
    env.update(extra_env or {})
    return subprocess.run([BASH, SCRIPT, *args], env=env, capture_output=True, text=True,
                          timeout=60)


def _fake_flatpak(tmp_path, exit_code=0):
    """A `flatpak` that records every call and exits ``exit_code``; returns (bin dir, log)."""
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir(exist_ok=True)
    log = tmp_path / "flatpak-calls.log"
    program = bin_dir / "flatpak"
    program.write_text(f'#!/bin/sh\necho "$*" >> "{log}"\nexit {exit_code}\n')
    program.chmod(0o755)
    return str(bin_dir), log


@needs_bash
def test_script_help_lists_every_setting_it_reads(tmp_path):
    result = _run_script(tmp_path, "--help")
    assert result.returncode == 0, result.stderr
    settings = set(re.findall(r"HUGMESH_STUDIO_FLATPAK_[A-Z_]+", _read(SCRIPT)))
    assert {"HUGMESH_STUDIO_FLATPAK_USER_DIR", "HUGMESH_STUDIO_FLATPAK_OUT"} <= settings
    readme = _read(README)
    for setting in sorted(settings):
        assert setting in result.stdout, f"--help does not mention {setting}"
        assert setting in readme, f"README.md does not mention {setting}"


@needs_bash
def test_script_rejects_an_unknown_argument(tmp_path):
    result = _run_script(tmp_path, "--no-such-option")
    assert result.returncode == 2
    assert "--no-such-option" in result.stderr and "Usage:" in result.stderr


@needs_bash
@pytest.mark.parametrize("where", [
    ".local/share/flatpak",             # the directory itself
    ".local/share/flatpak/private",     # inside it
    ".local/share",                     # contains it
], ids=["same", "inside", "contains"])
def test_script_refuses_to_use_the_users_own_flatpak_directory(tmp_path, where):
    fake_bin, log = _fake_flatpak(tmp_path)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": str(tmp_path / "home" / where)})
    assert result.returncode == 1
    assert "private directory" in result.stderr, result.stderr
    assert not log.exists() or not log.read_text().strip(), (
        f"flatpak was called before the refusal: {log.read_text()!r}")


def _refused_without_a_flatpak_call(result, log):
    assert result.returncode == 1, (result.returncode, result.stderr)
    assert "private directory" in result.stderr, result.stderr
    assert not log.exists() or not log.read_text().strip(), (
        f"flatpak was called before the refusal: {log.read_text()!r}")


@needs_bash
@pytest.mark.parametrize("spelling", ["dotdot", "symlink"])
def test_the_refusal_sees_through_a_path_spelled_another_way(tmp_path, spelling):
    """The guard compares normalised paths. A ``..`` or a symlink must not get round it.

    Without the normalisation the literal text of these paths differs from the protected
    directory's, so a plain string comparison lets them through to flatpak.
    """
    home = tmp_path / "home"
    (home / ".local" / "share" / "flatpak").mkdir(parents=True)
    if spelling == "dotdot":
        given = home / "x" / ".." / ".local" / "share" / "flatpak"
    else:
        given = home / "alias"
        given.symlink_to(home / ".local" / "share" / "flatpak")
    fake_bin, log = _fake_flatpak(tmp_path)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": str(given)})
    _refused_without_a_flatpak_call(result, log)


@needs_bash
@pytest.mark.parametrize("spelling", ["dotdot", "symlink"])
def test_the_output_directory_inside_the_private_one_is_refused_in_any_spelling(
        tmp_path, spelling):
    """Same for the build output: spelled to look elsewhere, it still sits in the private dir."""
    private = tmp_path / "private"
    private.mkdir()
    if spelling == "dotdot":
        out = tmp_path / "elsewhere" / ".." / "private" / "out"
    else:
        alias = tmp_path / "alias"
        alias.symlink_to(private)
        out = alias / "out"
    fake_bin, log = _fake_flatpak(tmp_path)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": str(private),
                   "HUGMESH_STUDIO_FLATPAK_OUT": str(out)})
    assert result.returncode == 1, (result.returncode, result.stderr)
    assert "private flatpak directory" in result.stderr, result.stderr
    assert not log.exists() or not log.read_text().strip()


@needs_bash
@pytest.mark.parametrize("where", ["flatpak", "flatpak/private", "."],
                         ids=["same", "inside", "contains"])
def test_script_refuses_the_flatpak_directory_under_a_custom_xdg_data_home(tmp_path, where):
    """XDG_DATA_HOME moves where flatpak keeps the user installation, away from
    $HOME/.local/share/flatpak; the guard must follow it, or a user with a non-default
    data home would get the toolchain installed into their own flatpak directory."""
    data_home = tmp_path / "elsewhere" / "data"
    data_home = type(tmp_path)(os.path.realpath(data_home))
    fake_bin, log = _fake_flatpak(tmp_path)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"XDG_DATA_HOME": str(data_home),
                   "HUGMESH_STUDIO_FLATPAK_USER_DIR": str(data_home / where)})
    _refused_without_a_flatpak_call(result, log)
    assert str(data_home / "flatpak") in result.stderr, (
        "the refusal does not name the XDG_DATA_HOME flatpak directory: " + result.stderr)


@needs_bash
def test_script_refuses_the_system_flatpak_directory(tmp_path):
    fake_bin, log = _fake_flatpak(tmp_path)
    result = _run_script(tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
                         extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": "/var/lib/flatpak"})
    assert result.returncode == 1 and "private directory" in result.stderr
    assert not log.exists() or not log.read_text().strip()


@needs_bash
def test_script_gets_past_the_guard_for_a_private_directory(tmp_path):
    """The positive control: the refusals above are not simply refusing everything."""
    fake_bin, log = _fake_flatpak(tmp_path, exit_code=77)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": str(tmp_path / "private"),
                   "HUGMESH_STUDIO_FLATPAK_OUT": str(tmp_path / "out")})
    assert "private directory" not in result.stderr, result.stderr
    assert result.returncode != 0                       # the fake flatpak fails on purpose
    assert log.read_text().splitlines()[0] == "--default-arch", log.read_text()


def _failing_script_run(tmp_path, *, monitor_dir_exists, helper_running):
    """Run the script until the fake flatpak makes it fail, with the helper situation set."""
    fake_bin, _log = _fake_flatpak(tmp_path, exit_code=77)
    pgrep = os.path.join(fake_bin, "pgrep")
    with open(pgrep, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n" + ('echo 4242\nexit 0\n' if helper_running else "exit 1\n"))
    os.chmod(pgrep, 0o755)
    run_dir = tmp_path / "run"
    (run_dir / ".flatpak-helper" / ("monitor" if monitor_dir_exists else "other")).mkdir(
        parents=True)
    return _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"XDG_RUNTIME_DIR": str(run_dir),
                   "HUGMESH_STUDIO_FLATPAK_USER_DIR": str(tmp_path / "private"),
                   "HUGMESH_STUDIO_FLATPAK_OUT": str(tmp_path / "out")})


@needs_bash
def test_a_lost_helper_directory_is_named_not_left_as_a_bwrap_error(tmp_path):
    """Seen once while building this: the session helper kept running, its directory under
    XDG_RUNTIME_DIR vanished, and every flatpak sandbox then died with only "bwrap: Can't
    find source path .../.flatpak-helper/monitor". The fix is a restart, so the script says so.
    """
    result = _failing_script_run(tmp_path, monitor_dir_exists=False, helper_running=True)
    assert result.returncode != 0
    assert "FAILED during:" in result.stderr
    assert "session helper is running (pid 4242)" in result.stderr, result.stderr
    assert "kill 4242" in result.stderr


@needs_bash
@pytest.mark.parametrize("monitor_dir_exists, helper_running", [
    pytest.param(True, True, id="helper-and-directory-fine"),
    pytest.param(False, False, id="no-helper-running-yet"),
])
def test_the_helper_hint_stays_quiet_when_nothing_is_wrong(tmp_path, monitor_dir_exists,
                                                           helper_running):
    result = _failing_script_run(tmp_path, monitor_dir_exists=monitor_dir_exists,
                                 helper_running=helper_running)
    assert result.returncode != 0 and "FAILED during:" in result.stderr
    assert "session helper" not in result.stderr, result.stderr


@needs_bash
def test_script_without_flatpak_says_so_and_stops(tmp_path):
    empty = tmp_path / "emptybin"
    empty.mkdir()
    result = _run_script(tmp_path, path=str(empty))
    assert result.returncode == 1
    assert "flatpak program is not installed" in result.stderr, result.stderr


def _scripted_flatpak(tmp_path, validators=True):
    """A ``flatpak`` that answers like a machine with nothing installed yet, plus both
    validators (unless ``validators`` is false); every call is logged as
    ``tool<TAB>FLATPAK_USER_DIR<TAB>arguments`` (the -c script of smoke test 3 spans
    lines; ``_calls`` joins them back into one call).

    Nothing is installed until the bundle is: ``info`` fails before that, so the script
    has to install the toolchain and must not uninstall an app that is not there. After
    the bundle is installed a second run sees everything installed and flathub added:
    the branches a re-run takes (no remote-add, no toolchain install, an uninstall of
    the old app first) are reached by running the script twice in one directory.

    Every call that reads or changes an installation must carry ``--user`` among the
    options before its first operand; one that does not is logged as a ``violation`` and
    answered with exit 99, and ``_scripted_run`` fails the test on any violation. (A
    mutation round removed --user from five calls one at a time with the suite green:
    the fake used to answer them all alike.) The Qt check is RUN, not answered: the
    script's own python is executed against a stub ``hugmesh_studio`` package (see
    ``_qt_stub``). ``df`` answers ``FAKE_DF_GIB`` GiB free when that is set. What
    the three smoke tests see is set per run: ``FAKE_FLATPAK_SPECS`` is what
    ``--print-specs`` prints (empty: nothing at all), ``FAKE_FLATPAK_QT`` what the Qt
    check prints, ``FAKE_FLATPAK_FILES`` names one file the sandbox shell does not find
    (``none``: it finds nothing; empty: it finds all of them), and ``FAKE_FLATPAK_EXPORT``
    set to ``none`` makes the bundle install export no launcher. ``FAKE_FLATPAK_BUILD_EXIT``
    and ``FAKE_FLATPAK_BUNDLE_EXIT`` are the exit status of the flatpak-builder run and of
    ``build-bundle`` (both succeed unless set).

    Smoke test 3 is not answered, it is RUN: the script's own ``-c`` body is executed by
    the host's ``sh`` against a stand-in ``/app`` under the private directory that holds
    every wanted file but the one ``FAKE_FLATPAK_FILES`` names, so the one line that
    looks for the files is exercised here and not only by a real build (a mutation
    that echoed every file without looking survived the earlier answer-from-a-list fake).
    """
    bin_dir = tmp_path / "scriptedbin"
    bin_dir.mkdir(exist_ok=True)
    log = tmp_path / "scripted-calls.log"
    (bin_dir / "flatpak").write_text(
        "#!/bin/sh\n"
        f"printf 'flatpak\\t%s\\t%s\\n' \"${{FLATPAK_USER_DIR-unset}}\" \"$*\" >> \"{log}\"\n"
        "installed=\"${FLATPAK_USER_DIR-/nonexistent}/.fake-installed\"\n"
        "case \"$1\" in\n"
        "    install|uninstall|update|remote-*|remotes|info|list|run|repair|override|mask|pin|history|search|ps|kill|config)\n"
        "        ( shift; for a in \"$@\"; do case \"$a\" in --user) exit 0 ;; -*) ;; *) exit 1 ;; esac; done; exit 1 ) || {\n"
        f"            printf 'violation\\t-\\tflatpak %s\\n' \"$*\" >> \"{log}\"; exit 99; }} ;;\n"
        "esac\n"
        "case \"$1\" in\n"
        "    --default-arch) echo x86_64 ;;\n"
        "    --version) echo 'Flatpak 0.0-fake' ;;\n"
        "    remotes) [ ! -e \"$installed\" ] || echo flathub ;;\n"
        "    info)\n"
        "        [ -e \"$installed\" ] || exit 1\n"
        "        case \"$*\" in *--show-commit*) echo 0123abcd ;; esac ;;\n"
        "    build-bundle)\n"                         # not empty: a checksum of nothing must not pass for this one
        "        [ \"${FAKE_FLATPAK_BUNDLE_EXIT-0}\" = 0 ] || exit \"$FAKE_FLATPAK_BUNDLE_EXIT\"\n"
        # The bundle path is the SECOND operand after the options (--runtime-repo=...),
        # wherever the script puts those.
        "        shift; out=; n=0\n"
        "        for a in \"$@\"; do case \"$a\" in -*) ;; *) n=$((n + 1)); [ \"$n\" -ne 2 ] || out=\"$a\" ;; esac; done\n"
        "        printf 'fake flatpak bundle %s\\n' \"$$\" > \"$out\" ;;\n"
        "    install)\n"
        "        case \"$*\" in *--bundle*)\n"
        f"            mkdir -p \"$FLATPAK_USER_DIR/exports/share/applications\"\n"
        "            [ \"${FAKE_FLATPAK_EXPORT-}\" = none ] ||\n"
        f"                : > \"$FLATPAK_USER_DIR/exports/share/applications/{APP_ID}.desktop\"\n"
        "            : > \"$installed\" ;;\n"
        "        esac ;;\n"
        "    run)\n"
        "        case \"$*\" in\n"
        "            *' --command=flatpak-builder '*) exit \"${FAKE_FLATPAK_BUILD_EXIT-0}\" ;;\n"
        "            *' --print-specs')\n"
        "                [ -z \"${FAKE_FLATPAK_SPECS-}\" ] || printf '%s\\n' \"$FAKE_FLATPAK_SPECS\" ;;\n"
        "            *' --command=python3 '*)\n"
        "                if [ \"${FAKE_FLATPAK_QT+set}\" = set ]; then printf '%s\\n' \"$FAKE_FLATPAK_QT\"\n"
        "                else cd \"$FAKE_QT_PYTHONPATH\" && \"$FAKE_QT_PYTHON\" -; fi ;;\n"
        "            *' --command=sh '*)\n"
        "                while [ \"$#\" -gt 0 ] && [ \"$1\" != -c ]; do shift; done\n"
        "                body=\"$2\"; shift 3\n"            # -c, the body, the `_` that is $0 in it
        "                root=\"$FLATPAK_USER_DIR/fake-app\"\n"
        "                for f in \"$@\"; do\n"
        "                    [ \"${FAKE_FLATPAK_FILES-}\" = none ] || [ \"$f\" = \"${FAKE_FLATPAK_FILES-}\" ] ||\n"
        "                        { mkdir -p \"$root$(dirname \"$f\")\" && : > \"$root$f\"; }\n"
        "                    set -- \"$@\" \"$root$f\"; shift\n"      # /app/x becomes $root/app/x
        "                done\n"
        "                sh -c \"$body\" _ \"$@\" | sed \"s#^$root##\" ;;\n"
        "        esac ;;\n"
        "esac\n"
        "exit 0\n")
    for tool in ("desktop-file-validate", "appstreamcli") if validators else ():
        (bin_dir / tool).write_text(
            f"#!/bin/sh\nprintf '{tool}\\t-\\t%s\\n' \"$*\" >> \"{log}\"\nexit 0\n")
    real_df = shutil.which("df") or "/usr/bin/df"
    (bin_dir / "df").write_text(
        "#!/bin/sh\n"
        "if [ -z \"${FAKE_DF_GIB-}\" ]; then exec " + shlex.quote(real_df) + " \"$@\"; fi\n"
        "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'\n"
        "echo \"fake 0 0 $((FAKE_DF_GIB * 1048576)) 0% /\"\n")
    for program in bin_dir.iterdir():
        program.chmod(0o755)
    return str(bin_dir), log


def _calls(log) -> list[tuple[str, str, str]]:
    """Every logged call as (tool, FLATPAK_USER_DIR seen, arguments); a line that does not
    start a call continues the previous one's arguments (the -c script of smoke test 3)."""
    calls: list[list[str]] = []
    if log.exists():
        for line in log.read_text().splitlines():
            if line.count("\t") >= 2 and line.split("\t", 1)[0] in (
                    "flatpak", "desktop-file-validate", "appstreamcli", "violation"):
                calls.append(line.split("\t", 2))
            elif calls:
                calls[-1][2] += " " + line.strip()
    return [tuple(call) for call in calls]


#: What a working sandbox answers smoke tests 1 and 3 with. Smoke test 2 is not answered:
#: the script's own python runs against ``_qt_stub``.
_SMOKE_OK = {"FAKE_FLATPAK_SPECS": '{"os": "linux"}',
             "FAKE_FLATPAK_FILES": ""}

#: Stands in for ``hugmesh_studio.gui.qt`` in the sandbox. The script's smoke test 2 is
#: python that imports it, checks the binding, the platform and a rendered grab, and
#: looks for the package's data files; the answers come from the environment.
_QT_STUB = '''\
import os
BINDING = os.environ.get("FAKE_QT_BINDING", "PySide6")


class _Shot:
    def __init__(self, width, height):
        self._size = (width, height)

    def isNull(self):
        return os.environ.get("FAKE_QT_GRAB_NULL") == "1"

    def width(self):
        return self._size[0]

    def height(self):
        return self._size[1]


class QtCore:
    @staticmethod
    def qVersion():
        return "0.0-stub"


class QtWidgets:
    class QApplication:
        def __init__(self, argv):
            pass

        def platformName(self):
            return os.environ.get("FAKE_QT_PLATFORM", "offscreen")

    class QLabel:
        def __init__(self, text):
            self._size = (0, 0)

        def resize(self, width, height):
            self._size = (width, height)

        def show(self):
            pass

        def grab(self):
            return _Shot(*self._size)
'''


def _smoke_2_data_files() -> list[str]:
    """The package data files smoke test 2 looks for, read from the script's own list."""
    match = re.search(r"expected = \[(.*?)\]", _read(SCRIPT), re.DOTALL)
    assert match, "build-flatpak-local.sh no longer lists the package data files it checks"
    return re.findall(r'"([^"]+)"', match.group(1))


def _qt_stub(tmp_path, missing=None, html=True):
    """A ``hugmesh_studio`` package holding ``_QT_STUB`` and the data files smoke test 2
    looks for (all but ``missing``; one assets/*.html unless ``html`` is false)."""
    root = tmp_path / "qtstub"
    package = root / "hugmesh_studio"
    (package / "gui").mkdir(parents=True, exist_ok=True)
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "gui" / "__init__.py").write_text("", encoding="utf-8")
    (package / "gui" / "qt.py").write_text(_QT_STUB, encoding="utf-8")
    (package / "assets").mkdir(exist_ok=True)
    for rel in _smoke_2_data_files():
        if rel != missing:
            (package / rel).parent.mkdir(parents=True, exist_ok=True)
            (package / rel).write_text("", encoding="utf-8")
    if html:
        (package / "assets" / "index.html").write_text("<html></html>", encoding="utf-8")
    return str(root)


def _path_without(tmp_path, names):
    """A PATH holding every program the ordinary one does, except ``names``."""
    farm = tmp_path / "pathfarm"
    farm.mkdir(exist_ok=True)
    for directory in os.environ["PATH"].split(os.pathsep):
        try:
            entries = list(os.scandir(directory))
        except OSError:
            continue
        for entry in entries:
            if entry.name in names or (farm / entry.name).is_symlink():
                continue
            try:
                (farm / entry.name).symlink_to(entry.path)
            except OSError:
                pass
    return str(farm)


#: What a fake HOME holds before the script runs and must hold, unchanged, after it: a
#: file in the place the user's own flatpak data lives.
_CANARY = os.path.join(".local", "share", "flatpak", "canary")


def _home_untouched(tmp_path):
    home = tmp_path / "home"
    found = sorted(os.path.relpath(os.path.join(d, f), home)
                   for d, _dirs, files in os.walk(home) for f in files)
    assert found == [_CANARY], (
        f"the script changed the user's home directory; it holds {found}, expected only {_CANARY}")
    assert (home / _CANARY).read_text(encoding="utf-8") == "mine", "the canary file was rewritten"


def _scripted_run(tmp_path, *, qt_missing=None, qt_html=True, validators=True, **answers):
    """The whole script against the scripted flatpak, with the smoke tests answered as
    ``_SMOKE_OK`` unless ``answers`` says otherwise (a value of None removes the setting);
    returns (result, calls, private, out). The fake HOME holds a canary where the user's
    own flatpak data lives, and the run fails if that changed or if a flatpak call
    reached an installation without --user. Run twice in one ``tmp_path`` it is a re-run."""
    fake_bin, log = _scripted_flatpak(tmp_path, validators=validators)
    home = tmp_path / "home"
    if not (home / _CANARY).exists():
        (home / _CANARY).parent.mkdir(parents=True, exist_ok=True)
        (home / _CANARY).write_text("mine", encoding="utf-8")
    private = os.path.realpath(str(tmp_path / "private"))
    out = os.path.realpath(str(tmp_path / "out"))
    run_dir = tmp_path / "run"
    (run_dir / ".flatpak-helper" / "monitor").mkdir(parents=True, exist_ok=True)
    env = {"HUGMESH_STUDIO_FLATPAK_USER_DIR": private,
           "HUGMESH_STUDIO_FLATPAK_OUT": out,
           "HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB": "0",
           "XDG_RUNTIME_DIR": str(run_dir),
           "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(tmp_path / "no-such-bus"),
           "FAKE_QT_PYTHONPATH": _qt_stub(tmp_path, missing=qt_missing, html=qt_html),
           "FAKE_QT_PYTHON": sys.executable,
           **_SMOKE_OK, **answers}
    env = {key: value for key, value in env.items() if value is not None}
    path = fake_bin + os.pathsep + (os.environ["PATH"] if validators
                                    else _path_without(tmp_path, {"desktop-file-validate",
                                                                  "appstreamcli"}))
    result = _run_script(tmp_path, path=path, extra_env=env)
    calls = _calls(log)
    violations = [args for tool, _seen, args in calls if tool == "violation"]
    assert not violations, ("a flatpak call reached an installation without --user: "
                            + "; ".join(violations))
    _home_untouched(tmp_path)
    return result, calls, private, out


@needs_bash
def test_script_sends_every_flatpak_call_to_the_private_directory(tmp_path):
    """The whole script against a scripted flatpak, through all three smoke tests.

    What the fake is told is what the real flatpak would be told: no call may reach the
    user's own installation (--system, a missing --user, FLATPAK_USER_DIR not exported, or
    the host-side wrapper not pinning it), the Builder must be granted the private
    directory it cannot otherwise see and run with the build state directory as its
    working directory and no --state-dir (with one, its cache ref is named after the
    manifest's absolute path and an encrypted home refuses the name for a long checkout
    path), the build must use the release workflow's flags, both validators must run on
    the real files, and the exported launcher must be checked.
    """
    result, calls, private, out = _scripted_run(tmp_path)
    assert result.returncode == 0, result.stderr
    assert "==> Done in" in result.stdout, result.stdout

    flatpak = [(seen, args) for tool, seen, args in calls if tool == "flatpak"]
    assert flatpak and flatpak[0][1] == "--default-arch", calls
    for seen, args in flatpak[1:]:
        assert seen == private, f"flatpak {args!r} ran with FLATPAK_USER_DIR={seen!r}"
    args = [a for _seen, a in flatpak]
    for line in args:
        assert "--system" not in shlex.split(line), f"a call went to the system installation: {line!r}"

    version = _manifest_scalar("runtime-version")
    assert "remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" in args
    assert (f"install --user -y --noninteractive flathub org.flatpak.Builder//stable "
            f"org.kde.Platform//{version} org.kde.Sdk//{version}") in args, args
    assert ("desktop-file-validate", "-", os.path.realpath(DESKTOP)) in calls
    assert ("appstreamcli", "-", f"validate --no-net {os.path.realpath(METAINFO)}") in calls

    work = os.path.join(out, "flatpak-work")
    builder = [shlex.split(a) for a in args if a.startswith("run ") and "org.flatpak.Builder" in a]
    assert len(builder) == 2, args                      # the round-trip probe, then the build
    for words in builder:
        # FLATPAK_BINARY names the host-side wrapper checked at the end of this test:
        # without it the Builder's host commands start from the host environment and
        # look for the runtime in the user's own flatpak directory.
        # The output directory is a second grant: the Builder's working directory, repo and
        # build directory all live under it, and the sandbox cannot see an arbitrary path.
        assert out != private and not out.startswith(private + os.sep)
        for grant in ("--user", f"--filesystem={private}", f"--filesystem={out}",
                      f"--env=FLATPAK_USER_DIR={private}",
                      f"--env=FLATPAK_BINARY={work}/bin/flatpak-private", f"--cwd={work}"):
            assert grant in words, f"the Builder ran without {grant}: {words}"
    build = next(w for w in builder if "--command=flatpak-builder" in w)
    tail = build[build.index("org.flatpak.Builder") + 1:]
    for flag in ("--user", "--disable-rofiles-fuse", "--force-clean"):
        assert flag in tail, f"flatpak-builder ran without {flag} (the release workflow's flags): {tail}"
    assert not [w for w in tail if w.startswith("--state-dir")], (
        f"flatpak-builder ran with --state-dir, which names its cache ref after the manifest's "
        f"absolute path (see the script): {tail}")
    assert tail[-2:] == [os.path.join(work, "build-dir"), os.path.realpath(MANIFEST)]

    studio_version = re.search(r'(?m)^__version__ = "([^"]+)"',
                               _read(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"))).group(1)
    bundle = os.path.join(out, f"hugmesh-studio-{studio_version}-x86_64.flatpak")
    assert (f"build-bundle --runtime-repo={RUNTIME_REPO_URL} {work}/repo {bundle}.partial "
            f"{APP_ID}") in args, args
    assert os.path.isfile(bundle) and os.path.isfile(bundle + ".sha256")
    assert not os.path.exists(bundle + ".partial"), (
        "the bundle was copied, not renamed, from its .partial name: a copy that is cut "
        "short leaves the .partial behind and one that is not leaves two bundles")
    with open(bundle, "rb") as handle:
        content = handle.read()
    assert content, "the fake wrote an empty bundle: a hard-coded empty-file checksum would pass"
    digest = hashlib.sha256(content).hexdigest()
    assert _read(bundle + ".sha256").split() == [digest, os.path.basename(bundle)], (
        "the .sha256 file does not name the bundle's own checksum in sha256sum's format")
    assert f"{os.path.basename(bundle)}: OK" in result.stdout, (
        "the checksum was written but never read back (sha256sum -c): a bundle that does "
        "not match its own .sha256 would be installed and reported as built")
    assert f"install --user -y --noninteractive --bundle {bundle}" in args, args
    assert not [a for a in args if a.startswith("uninstall")], "nothing was installed to uninstall"
    assert f"run --user --command={_manifest_scalar('command')} {APP_ID} --print-specs" in args
    smoke = [a for a in args if a.startswith("run ")]
    assert "--command=python3" in smoke[-2] and "--nofilesystem=host" in smoke[-2], smoke
    assert "--command=sh" in smoke[-1] and "--nofilesystem=host" in smoke[-1], smoke
    assert smoke[-1].endswith(f"/app/share/icons/hicolor/256x256/apps/{APP_ID}.png"), smoke[-1]
    assert f"ok       {private}/exports/share/applications/{APP_ID}.desktop" in result.stdout

    # The wrapper the Builder hands to the host must pin the private directory itself:
    # the host command does not inherit the Builder's environment.
    fake_bin = str(tmp_path / "scriptedbin")
    wrapper = os.path.join(work, "bin", "flatpak-private")
    assert os.access(wrapper, os.X_OK), "the host-side flatpak wrapper was not written"
    log = tmp_path / "scripted-calls.log"
    subprocess.run([wrapper, "--version"], env={"PATH": fake_bin}, check=True,
                   capture_output=True, timeout=30)
    assert _calls(log)[-1] == ("flatpak", private, "--version"), (
        "the host-side wrapper does not pin FLATPAK_USER_DIR to the private directory")


@needs_bash
@pytest.mark.parametrize("answer, message", [
    pytest.param("", "no output from --print-specs", id="nothing"),
    pytest.param(" ", "printed only blank lines", id="blank"),
    pytest.param("not json", "is not JSON", id="not-json"),
    pytest.param("[]", "not a non-empty JSON object", id="not-an-object"),
    pytest.param("[1]", "not a non-empty JSON object", id="a-list-with-content"),
    pytest.param("{}", "not a non-empty JSON object", id="empty-object"),
])
def test_smoke_test_1_refuses_an_empty_or_wrong_print_specs(tmp_path, answer, message):
    """An installed bundle whose --print-specs prints nothing is incomplete, not built."""
    result, calls, _private, _out = _scripted_run(tmp_path, FAKE_FLATPAK_SPECS=answer)
    assert result.returncode == 1, result.stderr
    assert message in result.stderr, result.stderr
    assert "Smoke test 1 of 3" in result.stderr, result.stderr
    assert not [a for _t, _s, a in calls if "--command=python3" in a], "smoke test 2 ran anyway"


@needs_bash
def test_script_runs_the_same_commands_as_the_release_workflows_flatpak_job(tmp_path):
    """The point of the script is that a green local build predicts the release job, so
    the commands the script runs are read back against the workflow's, not against copies
    kept in this file: the flatpak-builder flags and positional arguments, both
    validators, the build-bundle call and the bundle and checksum names, and the install
    and run of the bundle. What is DELIBERATELY different (the script's --user on the run,
    --bundle on the install, a .partial name the bundle is renamed from, absolute paths)
    is spelled out below; anything else that differs fails."""
    result, calls, _private, out = _scripted_run(tmp_path)
    assert result.returncode == 0, result.stderr
    args = [a for tool, _seen, a in calls if tool == "flatpak"]
    lines = _workflow_flatpak_lines()
    version = _package_version()
    name = f"hugmesh-studio-{version}-x86_64.flatpak"      # the fake flatpak's arch

    def workflow_one(predicate, what):
        found = [ln for ln in lines if predicate(ln)]
        assert len(found) == 1, f"expected one {what} in the workflow's flatpak job, found {found}"
        return found[0]

    # flatpak-builder: the same flags, the same directories by name, the same manifest.
    builder_words = _words_of(workflow_one(lambda ln: ln.startswith("flatpak-builder "), "build"))
    script_build = next(shlex.split(a) for a in args if "--command=flatpak-builder" in a)
    script_tail = script_build[script_build.index("org.flatpak.Builder") + 1:]

    def flags(words):
        return sorted(w for w in words if w.startswith("--") and not w.startswith("--repo="))
    assert flags(script_tail) == flags(builder_words), (
        f"flatpak-builder flags differ: script {flags(script_tail)}, workflow {flags(builder_words)}")
    repo_of = lambda words: [os.path.basename(w[len("--repo="):]) for w in words if w.startswith("--repo=")]
    assert repo_of(script_tail) == repo_of(builder_words) == ["repo"], (script_tail, builder_words)
    assert [os.path.basename(w) for w in script_tail[-2:]] == builder_words[-2:] == [
        "build-dir", os.path.basename(MANIFEST)], (script_tail, builder_words)

    # The two validators: the same program, options and file names.
    from_workflow = [" ".join(_words_of(ln)) for ln in lines
                     if ln.split(" ", 1)[0] in {"desktop-file-validate", "appstreamcli"}]
    from_script = [tool + " " + " ".join(os.path.basename(w) for w in a.split())
                   for tool, _seen, a in calls if tool in {"desktop-file-validate", "appstreamcli"}]
    assert len(from_workflow) == 2, from_workflow
    assert sorted(from_script) == sorted(from_workflow), (from_script, from_workflow)

    # build-bundle: the same options (--runtime-repo above all: without it the bundle
    # does not say where its runtime comes from, and a machine with no remotes stops at
    # "requires the runtime ... which was not found") and the names it produces.
    bundle_words = _words_of(workflow_one(lambda ln: ln.startswith("flatpak build-bundle "), "export"))
    script_bundle = next(shlex.split(a) for a in args if a.startswith("build-bundle "))
    options = lambda words: sorted(w for w in words if w.startswith("--"))
    operands = lambda words: [w for w in words if not w.startswith("--")]
    assert options(script_bundle) == options(bundle_words[1:]), (script_bundle, bundle_words)
    assert f"--runtime-repo={RUNTIME_REPO_URL}" in options(bundle_words), bundle_words
    wf_repo, wf_bundle, wf_app = operands(bundle_words)[2:]
    assert wf_bundle.replace("${VERSION}", version) == name, bundle_words
    sc_repo, sc_bundle, sc_app = operands(script_bundle)[1:]
    assert os.path.basename(sc_repo) == wf_repo == "repo", (script_bundle, bundle_words)
    assert os.path.basename(sc_bundle) == name + ".partial", script_bundle
    assert sc_app == wf_app == APP_ID, (script_bundle, bundle_words)
    checksum = workflow_one(lambda ln: ln.startswith("sha256sum "), "checksum")
    assert checksum.replace("${VERSION}", version).endswith(f'tee "{name}.sha256"'), checksum
    assert os.path.isfile(os.path.join(out, name + ".sha256")), "the script wrote no .sha256 of that name"

    # Install and run of the bundle (the workflow's smoke test).
    install = _words_of(workflow_one(lambda ln: ln.startswith("flatpak install ") and ".flatpak" in ln,
                                     "bundle install"))
    script_install = next(shlex.split(a) for a in args if a.startswith("install ") and "--bundle" in a)
    assert install[0] == "flatpak" and install[1] == "install"
    assert [w for w in script_install[1:-1] if w != "--bundle"] == install[2:-1], (script_install, install)
    assert install[-1].replace("${VERSION}", version) == name == os.path.basename(script_install[-1])
    run_words = _words_of(workflow_one(lambda ln: ln.startswith("flatpak run "), "smoke test"))
    script_run = next(shlex.split(a) for a in args if a.endswith(" --print-specs"))
    assert [w for w in script_run if w != "--user"] == run_words[1:], (script_run, run_words)


@needs_bash
def test_a_failed_build_stops_the_script_before_it_exports_anything(tmp_path):
    """flatpak-builder's output goes through ``tee``; without pipefail its failure would
    vanish behind tee's exit status, and --force-clean empties only the build directory,
    so ``build-bundle`` would export the repository of the PREVIOUS build and the script
    would report a fresh, verified bundle."""
    result, calls, _private, out = _scripted_run(tmp_path, FAKE_FLATPAK_BUILD_EXIT="1")
    assert result.returncode == 1, result.stderr
    assert "FAILED during: Building" in result.stderr, result.stderr
    names = [a.split()[0] for tool, _s, a in calls if tool == "flatpak"]
    assert "build-bundle" not in names and "install" not in names[names.index("run"):], names
    assert not [f for f in os.listdir(out) if f.endswith((".flatpak", ".sha256", ".partial"))]


@needs_bash
def test_a_failed_export_leaves_no_old_bundle_to_be_mistaken_for_the_new_one(tmp_path):
    """A bundle from an earlier run is removed before the new one is exported: if
    build-bundle then fails, nothing named like a finished build is left in the output."""
    out = tmp_path / "out"
    out.mkdir()
    bundle = f"hugmesh-studio-{_package_version()}-x86_64.flatpak"
    for name in (bundle, bundle + ".sha256"):
        (out / name).write_text("from an earlier run")
    result, _calls, _private, _out = _scripted_run(tmp_path, FAKE_FLATPAK_BUNDLE_EXIT="1")
    assert result.returncode == 1, result.stderr
    assert "FAILED during: Exporting" in result.stderr, result.stderr
    assert not [f for f in os.listdir(out) if f.endswith((".flatpak", ".sha256"))], os.listdir(out)


@needs_bash
@pytest.mark.parametrize("answer", ["", "Traceback (most recent call last): ImportError: PySide6",
                                    "qt-ok binding=PyQt6 qt=6.8.3 platform=offscreen"],
                         ids=["nothing", "traceback", "wrong-binding"])
def test_smoke_test_2_refuses_a_qt_that_did_not_report_qt_ok(tmp_path, answer):
    """--print-specs never loads Qt, so this is the only check that sees PySide6 missing,
    and it has to report the one binding the licensing decision allows."""
    result, calls, _private, _out = _scripted_run(tmp_path, FAKE_FLATPAK_QT=answer)
    assert result.returncode == 1, result.stderr
    assert "did not report qt-ok" in result.stderr, result.stderr
    assert "Smoke test 2 of 3" in result.stderr, result.stderr
    assert not [a for _t, _s, a in calls if "--command=sh" in a], "smoke test 3 ran anyway"


@needs_bash
@pytest.mark.parametrize("answers, qt_missing, qt_html, message", [
    pytest.param({"FAKE_QT_BINDING": "PyQt6"}, None, True, "binding=PyQt6", id="wrong-binding"),
    pytest.param({"FAKE_QT_PLATFORM": "xcb"}, None, True, "platform=xcb", id="wrong-platform"),
    pytest.param({"FAKE_QT_GRAB_NULL": "1"}, None, True, "grab_null=True", id="nothing-rendered"),
    pytest.param({}, "core/_roles-lib.sh", True,
                 "package data missing from the install: ['core/_roles-lib.sh']", id="data-file"),
    pytest.param({}, None, False, "package data missing from the install: assets/*.html",
                 id="no-html-asset"),
])
def test_smoke_test_2_python_refuses_what_it_checks_itself(tmp_path, answers, qt_missing,
                                                           qt_html, message):
    """Smoke test 2's python runs here against a stub Qt. The shell's ``qt-ok`` guard is
    a second line behind it and would also stop a wrong binding, so the message the
    PYTHON gives is what is asserted: remove the check in the python and the shell guard
    still stops the run, but not with this message (and a wrong platform, an empty
    grab or a missing data file would then pass the shell guard unnoticed)."""
    result, calls, _private, _out = _scripted_run(tmp_path, qt_missing=qt_missing,
                                                  qt_html=qt_html, **answers)
    assert result.returncode == 1, (result.returncode, result.stderr)
    assert message in result.stderr, result.stderr
    assert "Smoke test 2 of 3" in result.stderr, result.stderr
    assert not [a for _t, _s, a in calls if "--command=sh" in a], "smoke test 3 ran anyway"


@needs_bash
def test_smoke_test_2_python_passes_on_a_sandbox_that_is_right(tmp_path):
    """The positive control for the refusals above."""
    result, _calls, _private, _out = _scripted_run(tmp_path)
    assert result.returncode == 0, result.stderr
    assert "qt-ok binding=PySide6 qt=0.0-stub platform=offscreen grab=120x40 html_assets=1" in result.stdout


def test_the_package_data_smoke_test_2_looks_for_is_in_the_package():
    """The list is the script's own; the stub above holds whatever it names, so this is
    what ties it to the real package (a file renamed or dropped from the source tree
    would otherwise be looked for in the sandbox for ever)."""
    listed = _smoke_2_data_files()
    assert len(listed) >= 3, listed
    for rel in listed:
        assert os.path.isfile(os.path.join(STUDIO_ROOT, "hugmesh_studio", rel)), (
            f"smoke test 2 looks for {rel}, which hugmesh_studio does not hold")
    assert [f for f in os.listdir(os.path.join(STUDIO_ROOT, "hugmesh_studio", "assets"))
            if f.endswith(".html")], "smoke test 2 wants one assets/*.html and there is none"


@needs_bash
def test_a_second_run_takes_the_re_run_path(tmp_path):
    """Run twice in one directory: nothing is added or installed again (flathub and the
    three refs are there), and the app installed by the first run is uninstalled, with
    --user, before the new bundle goes in; an install over the top would keep the old
    commit's files."""
    first, _calls_1, _private, _out = _scripted_run(tmp_path)
    assert first.returncode == 0, first.stderr
    (tmp_path / "scripted-calls.log").write_text("", encoding="utf-8")
    second, calls, _private, _out = _scripted_run(tmp_path)
    assert second.returncode == 0, second.stderr
    assert "already installed in the private directory" in second.stdout, second.stdout
    args = [a for tool, _s, a in calls if tool == "flatpak"]
    assert not [a for a in args if a.startswith("remote-add")], args
    assert [a for a in args if a.startswith("install")] == [
        a for a in args if a.startswith("install") and "--bundle" in a], args
    uninstall = f"uninstall --user -y --noninteractive {APP_ID}"
    assert args.count(uninstall) == 1, args
    bundle = next(a for a in args if a.startswith("install") and "--bundle" in a)
    assert args.index(uninstall) < args.index(bundle), args


@needs_bash
def test_the_validators_fall_back_to_the_builders_copy_in_the_private_directory(tmp_path):
    """On a host without desktop-file-validate or appstreamcli the script runs the copies
    inside org.flatpak.Builder, which must be the private installation's (--user) with the
    private directory granted; the fallback is a line the other runs never reach."""
    result, calls, private, _out = _scripted_run(tmp_path, validators=False)
    assert result.returncode == 0, result.stderr
    assert "is not installed here; using the copy inside org.flatpak.Builder" in result.stdout
    runs = {}
    for tool, seen, args in calls:
        words = shlex.split(args) if tool == "flatpak" else []
        for name in ("desktop-file-validate", "appstreamcli"):
            if f"--command={name}" in words:
                runs[name] = (seen, words)
    assert set(runs) == {"desktop-file-validate", "appstreamcli"}, calls
    for name, (seen, words) in runs.items():
        assert seen == private, (name, seen)
        assert words[0] == "run" and "--user" in words, (name, words)
        assert f"--filesystem={private}" in words and f"--env=FLATPAK_USER_DIR={private}" in words
        assert words[words.index("org.flatpak.Builder") + 1:][-1].endswith(
            (".desktop", ".metainfo.xml")), (name, words)
    assert "--no-net" in runs["appstreamcli"][1], runs["appstreamcli"]


@needs_bash
def test_a_first_run_with_too_little_room_stops_before_it_installs(tmp_path):
    """The first run wants 14 GiB (runtimes 9.5, build state 1.9, bundle 0.2 and room to
    spare) and says so under its own step before any download."""
    result, calls, _private, _out = _scripted_run(
        tmp_path, FAKE_DF_GIB="5", HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB=None)
    assert result.returncode == 1, result.stderr
    assert "only 5 GiB free" in result.stderr and "wants 14 GiB" in result.stderr, result.stderr
    assert "FAILED during: Checking free space" in result.stderr, result.stderr
    assert not [a for _t, _s, a in calls if a.startswith("install")], "it installed anyway"


@needs_bash
def test_a_re_run_wants_only_what_the_build_itself_needs(tmp_path):
    """Once the runtimes are there a run needs 4 GiB: 5 GiB free is enough, 3 is not."""
    first, *_ = _scripted_run(tmp_path)
    assert first.returncode == 0, first.stderr
    enough, *_ = _scripted_run(tmp_path, FAKE_DF_GIB="5", HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB=None)
    assert enough.returncode == 0, enough.stderr
    short, *_ = _scripted_run(tmp_path, FAKE_DF_GIB="3", HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB=None)
    assert short.returncode == 1, short.stderr
    assert "only 3 GiB free" in short.stderr and "wants 4 GiB" in short.stderr, short.stderr


@needs_bash
@pytest.mark.parametrize("missing, count", [
    pytest.param(f"/app/share/icons/hicolor/256x256/apps/{APP_ID}.png", 1, id="one-icon"),
    pytest.param("none", 5, id="every-file"),
])
def test_smoke_test_3_refuses_an_install_with_a_file_missing(tmp_path, missing, count):
    """The sandbox shell reports what it finds; a file it did not name is missing, and a
    shell that names nothing (an empty answer) is five missing files, not a pass."""
    result, _calls, _private, _out = _scripted_run(tmp_path, FAKE_FLATPAK_FILES=missing)
    assert result.returncode == 1, result.stderr
    assert f"{count} of 5 files are missing" in result.stderr, result.stderr
    assert "Smoke test 3 of 3" in result.stderr, result.stderr
    reported = re.findall(r"(?m)^MISSING  (\S+)$", result.stdout)
    assert len(reported) == count and (missing in reported or missing == "none"), result.stdout


@needs_bash
def test_smoke_test_3_refuses_an_install_that_exported_no_launcher(tmp_path):
    """flatpak writes the launcher into <private dir>/exports; the desktop sees the app
    through that file, so an install that left none is not a usable install."""
    result, _calls, private, _out = _scripted_run(tmp_path, FAKE_FLATPAK_EXPORT="none")
    assert result.returncode == 1, result.stderr
    assert f"did not export {APP_ID}.desktop into {private}/exports" in result.stderr, result.stderr
    assert "Smoke test 3 of 3" in result.stderr, result.stderr


@needs_bash
def test_a_second_run_against_the_same_output_directory_is_refused(tmp_path):
    """Two runs at once would fight over one build directory and one bundle file."""
    fcntl = pytest.importorskip("fcntl")
    out = tmp_path / "out"
    out.mkdir()
    with open(out / ".build-flatpak-local.lock", "w", encoding="utf-8") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result, calls, _private, _out = _scripted_run(tmp_path)
    assert result.returncode == 1, result.stderr
    assert "another build-flatpak-local.sh is already using" in result.stderr, result.stderr
    assert [a for tool, _seen, a in calls if tool == "flatpak"] == ["--default-arch"], calls


@needs_bash
def test_script_without_a_session_bus_stops_before_it_installs_anything(tmp_path):
    """The Builder reaches the host through the session helper, a D-Bus session service.
    With no bus the long install would be wasted, so the script says so first."""
    fake_bin, log = _scripted_flatpak(tmp_path)
    run_dir = tmp_path / "run"
    run_dir.mkdir()                             # no `bus` socket, and no DBUS_SESSION_BUS_ADDRESS
    result = _run_script(tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
                         extra_env={"XDG_RUNTIME_DIR": str(run_dir),
                                    "HUGMESH_STUDIO_FLATPAK_USER_DIR": str(tmp_path / "private"),
                                    "HUGMESH_STUDIO_FLATPAK_OUT": str(tmp_path / "out")})
    assert result.returncode == 1 and "no D-Bus session bus" in result.stderr, result.stderr
    assert [a for tool, _seen, a in _calls(log) if tool == "flatpak"] == ["--default-arch"]


@needs_bash
def test_a_bad_free_space_setting_is_refused_under_its_own_step(tmp_path):
    """``[ 671 -ge abc ]`` used to fail under the previous step's label ("Adding the
    flathub remote"), so a first run that stopped for space named the wrong step."""
    result, calls, _private, _out = _scripted_run(tmp_path, HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB="abc")
    assert result.returncode == 1, result.stderr
    assert "HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB must be a whole number" in result.stderr, result.stderr
    assert "FAILED during: Checking free space" in result.stderr, result.stderr
    assert not [a for _t, _s, a in calls if a.startswith("install")], "it installed anyway"


@needs_bash
@pytest.mark.parametrize("where", [
    "private",              # the private directory itself
    "private/out",          # inside it
    "",                     # contains it (tmp_path itself)
], ids=["same", "inside", "contains"])
def test_build_output_may_not_live_in_the_private_flatpak_directory(tmp_path, where):
    fake_bin, log = _fake_flatpak(tmp_path)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": str(tmp_path / "private"),
                   "HUGMESH_STUDIO_FLATPAK_OUT": str(tmp_path / where)})
    assert result.returncode == 1
    assert "HUGMESH_STUDIO_FLATPAK_OUT" in result.stderr and "private flatpak directory" in result.stderr, result.stderr
    assert not log.exists() or not log.read_text().strip()


@needs_bash
def test_script_refuses_an_incomplete_checkout_before_calling_flatpak(tmp_path):
    """The script is run from a copy of the checkout with python-deps.json gone: the
    file the manifest needs first, and the one that had never been committed."""
    copy = tmp_path / "checkout" / "studio"
    shutil.copytree(PACKAGING, copy / "packaging",
                    ignore=shutil.ignore_patterns("wix", "build-dir", "repo", ".flatpak-builder"))
    (copy / "hugmesh_studio").mkdir()
    shutil.copy(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), copy / "hugmesh_studio")
    os.remove(copy / "packaging" / "flatpak" / "python-deps.json")
    fake_bin, log = _fake_flatpak(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    result = subprocess.run(
        [BASH, str(copy / "packaging" / "build-flatpak-local.sh")],
        env={"PATH": fake_bin + os.pathsep + os.environ["PATH"], "HOME": str(home),
             "HUGMESH_STUDIO_FLATPAK_USER_DIR": str(tmp_path / "private"),
             "HUGMESH_STUDIO_FLATPAK_OUT": str(tmp_path / "out")},
        capture_output=True, text=True, timeout=60)
    assert result.returncode == 1, result.stderr
    assert "missing" in result.stderr and "python-deps.json" in result.stderr, result.stderr
    assert "complete checkout" in result.stderr, result.stderr
    assert not log.exists() or not log.read_text().strip(), "flatpak was called first"


def test_script_takes_its_facts_from_the_manifest_not_from_itself():
    """Bump the runtime in the manifest and the script must follow, so it holds no copy."""
    code = "\n".join(line for line in _read(SCRIPT).splitlines()
                     if not line.lstrip().startswith("#"))
    version = _manifest_scalar("runtime-version")
    for literal in (f"//{version}", "org.kde.", _manifest_scalar("command") + " "):
        assert literal not in code, (
            f"build-flatpak-local.sh hard-codes {literal!r}; read it from the manifest")
    # ``runtime_version=6.8`` in place of the manifest read has none of those literals.
    bare = re.search(rf"(?<![\d.]){re.escape(version)}(?![\d.])", code)
    assert not bare, (
        f"build-flatpak-local.sh holds the runtime version {version!r} as a number of its "
        "own; read it from the manifest")
