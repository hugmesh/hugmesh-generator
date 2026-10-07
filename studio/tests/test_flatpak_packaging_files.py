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
    ways a person would actually write that, refuses to touch a flatpak directory
    somebody already uses, and names the one broken-helper state that otherwise shows
    up only as an opaque bwrap error;
  * run against a scripted fake ``flatpak``, the script sends EVERY call to the private
    directory and never to ``--system``, grants the Builder that directory, builds with
    the release workflow's flags, runs both validators, and refuses an empty
    ``--print-specs``. (A mutation battery showed all of that could be lost with the
    static checks alone still green.)

Qt-free and offline: it reads files and runs the script against fakes only, and never
starts the real flatpak.
"""
from __future__ import annotations

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

    org.kde.Platform//6.8 ships Qt 6.8.x, so PySide6 must be 6.8.y. A runtime bump that
    forgets to regenerate python-deps.json fails here, not on a user's desktop.
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
#: word in COMMAND position counts. The scanner follows a command into the places a
#: person would really put one: behind an environment assignment, a redirection, a full
#: path, a prefix such as env or timeout, a shell's -c, flatpak-spawn --host, a
#: --command= option, a $( ) substitution, and a process call in embedded Python.
#: (The first version checked the first word of a line only: a mutation battery put sudo
#: behind each of those and every one survived.)
_FORBIDDEN = {"sudo", "doas", "pkexec", "run0", "su", "apt", "apt-get", "dpkg", "dnf", "yum",
              "pacman", "zypper", "emerge", "brew", "nix-env", "snap"}
#: After these the command position is still open: the next word is run, not consumed.
_PREFIXES = {"exec", "command", "builtin", "env", "nohup", "xargs", "time", "nice", "ionice",
             "timeout", "setsid", "stdbuf", "chroot", "flatpak-spawn",
             "then", "do", "else", "elif", "if", "while", "until", "!", "{"}
#: These run the string after -c as a command line of its own.
_SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
_PYTHONS = {"python", "python3"}
_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
_COUNT = re.compile(r"\d+(?:\.\d+)?[smhd]?")               # nice -n 10, timeout 30s
_C_OPTION = re.compile(r"-[a-zA-Z]*c[a-zA-Z]*")             # -c, -ec, -xc
_COMMAND_OPTION = re.compile(r"--?(?:command|exec)=(.+)")   # flatpak run --command=X
_PROCESS_CALL = re.compile(
    r"subprocess\.|os\.(?:system|exec\w*|spawn\w*|popen)|Popen|check_call|check_output")
_STRING_LITERAL = re.compile(r"""(['"])(.*?)\1""")


def _program(token: str) -> str:
    """The program a token names: its base name, and the first word if it is a string."""
    words = token.split()
    return (words[0] if words else token).rsplit("/", 1)[-1]


def _is_separator(token: str) -> bool:
    return bool(token) and set(token) <= set("();|&")


def _is_redirection(token: str) -> bool:
    bare = token.strip("0123456789")           # shlex hands 2>/dev/null over as 2, >, /dev/null
    return bool(bare) and set(bare) <= set("<>&|") and ("<" in bare or ">" in bare)


def _tokens(line: str) -> list[str]:
    try:
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:                         # a quote that closes on a later line
        return line.split()


def _substitutions(line: str):
    """The text inside each ``$( ... )`` and backtick pair, nested ones included."""
    start = line.find("$(")
    while start >= 0:
        depth, end = 0, start + 1
        while end < len(line):
            depth += {"(": 1, ")": -1}.get(line[end], 0)
            if depth == 0:
                break
            end += 1
        yield line[start + 2:end]
        start = line.find("$(", start + 2)
    yield from re.findall(r"`([^`]*)`", line)


def _python_call_words(text: str):
    """The program each string argument of a process call names: subprocess.run(["sudo"])."""
    if _PROCESS_CALL.search(text):
        for _quote, literal in _STRING_LITERAL.findall(text):
            if literal.strip():
                yield _program(literal)


def _line_command_words(line: str):
    """Yield each word one line of shell puts in command position."""
    expecting = True        # the next word is run
    skip_target = False     # the next word is a redirection target
    inner = None            # a shell or python was named: "await-c", then "next"; or "eval"
    for token in _tokens(line):
        if skip_target:
            skip_target = False
            continue
        if _is_redirection(token):
            skip_target = True
            continue
        if _is_separator(token):
            expecting, inner = True, None
            continue
        option = _COMMAND_OPTION.fullmatch(token)
        if option:                             # --command=X runs X wherever the option sits
            word = _program(option.group(1))
            yield word
            inner = ("await-c", word) if word in _SHELLS | _PYTHONS else inner
            continue
        if inner and inner[0] in ("next", "eval"):
            if not token.startswith("-"):
                if inner[1] in _PYTHONS:
                    yield from _python_call_words(token)
                else:
                    yield from _line_command_words(token)
                inner = inner if inner[0] == "eval" else None
            continue
        if inner and inner[0] == "await-c":
            if _C_OPTION.fullmatch(token):
                inner = ("next", inner[1])
            elif not token.startswith("-"):    # bash script.sh: a file, not a string
                inner = None
            continue
        if not expecting:
            continue
        if token.startswith("-") or _ASSIGNMENT.match(token) or _COUNT.fullmatch(token):
            continue                           # an option, an assignment or a count: still to come
        word = _program(token)
        yield word
        expecting = word in _PREFIXES
        if word == "eval":
            inner = ("eval", "eval")
        elif word in _SHELLS | _PYTHONS:
            inner = ("await-c", word)


def _command_words(text: str):
    """Yield ``(line, word)`` for each word the script puts where a command goes.

    Skips comments, joins backslash continuations, scans substitutions on their own (a
    quoted string is otherwise one opaque token and ``x="$(sudo foo)"`` would sail
    through), and inside a heredoc body (the usage text, the embedded Python) looks only at
    process calls, so prose there may say "sudo" and ``subprocess.run(["sudo"])`` may not.
    """
    text = text.replace("\\\n", " ")
    heredoc_end = None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if heredoc_end is not None:
            if line == heredoc_end:
                heredoc_end = None
            else:
                for word in _python_call_words(line):
                    yield number, word
            continue
        if not line or line.startswith("#"):
            continue
        seen: list[str] = []
        for piece in [*_substitutions(line), line]:
            for word in _line_command_words(piece):
                if word not in seen:           # a nested $( ) is scanned once per level
                    seen.append(word)
                    yield number, word
        opener = re.search(r"<<-?\s*(['\"]?)(\w+)\1", line)
        if opener:
            heredoc_end = opener.group(2)


def _forbidden_in(text: str) -> list[tuple[int, str]]:
    return [(n, w) for n, w in _command_words(text) if w in _FORBIDDEN]


def test_build_script_never_runs_sudo_or_a_package_manager():
    hits = _forbidden_in(_read(SCRIPT))
    assert not hits, (
        "build-flatpak-local.sh must work on a machine with no sudo and no apt, but it runs: "
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
    # The spellings the first scanner missed (the skeptics' mutations S31-S36 and more).
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
    # Known blind spot, pinned so nobody mistakes the scanner for more than it is: a
    # program named through a variable is invisible to any static reading.
    ('elevate=sudo; "$elevate" -n true', []),
], ids=["plain", "after-and", "probe", "substitution", "substitution-after-and",
        "exec-prefix", "in-string", "in-comment", "in-message", "argument-on-continuation",
        "command-on-continuation", "in-heredoc", "trailing-comment",
        "env-assignment", "env-assignment-sudo", "env-prefix", "full-path", "bash-c", "sh-ec",
        "bash-script-argument", "eval", "flatpak-spawn", "redirection-prefix",
        "two-redirections", "timeout", "nice", "command-option", "command-option-benign",
        "python-subprocess", "python-message", "python-c", "run0", "variable-blind-spot"])
def test_the_forbidden_command_scanner_sees_what_it_must(snippet, expected):
    """The scanner is what the test above stands on, so it is pinned in both directions."""
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


def _scripted_flatpak(tmp_path):
    """A `flatpak` that answers like a machine with nothing installed yet, plus both
    validators; every call is logged as ``tool<TAB>FLATPAK_USER_DIR<TAB>arguments``."""
    bin_dir = tmp_path / "scriptedbin"
    bin_dir.mkdir(exist_ok=True)
    log = tmp_path / "scripted-calls.log"
    (bin_dir / "flatpak").write_text(
        "#!/bin/sh\n"
        f"printf 'flatpak\\t%s\\t%s\\n' \"${{FLATPAK_USER_DIR-unset}}\" \"$*\" >> \"{log}\"\n"
        "case \"$1\" in\n"
        "    --default-arch) echo x86_64 ;;\n"
        "    --version) echo 'Flatpak 0.0-fake' ;;\n"
        "    info) exit 1 ;;\n"                     # nothing is installed: the script must install
        "    build-bundle) : > \"$3\" ;;\n"          # an empty bundle is enough to reach the install step
        "esac\n"
        "exit 0\n")
    for tool in ("desktop-file-validate", "appstreamcli"):
        (bin_dir / tool).write_text(
            f"#!/bin/sh\nprintf '{tool}\\t-\\t%s\\n' \"$*\" >> \"{log}\"\nexit 0\n")
    for program in bin_dir.iterdir():
        program.chmod(0o755)
    return str(bin_dir), log


def _calls(log) -> list[tuple[str, ...]]:
    if not log.exists():
        return []
    return [tuple(line.split("\t", 2)) for line in log.read_text().splitlines()]


@needs_bash
def test_script_sends_every_flatpak_call_to_the_private_directory(tmp_path):
    """The whole script against a scripted flatpak, up to the first smoke test.

    What the fake is told is what the real flatpak would be told: no call may reach the
    user's own installation (--system, a missing --user, FLATPAK_USER_DIR not exported, or
    the host-side wrapper not pinning it), the Builder must be granted the private
    directory it cannot otherwise see, the build must use the release workflow's flags,
    both validators must run on the real files, and an empty --print-specs must be
    refused rather than reported as a built app.
    """
    fake_bin, log = _scripted_flatpak(tmp_path)
    private = os.path.realpath(str(tmp_path / "private"))
    out = os.path.realpath(str(tmp_path / "out"))
    run_dir = tmp_path / "run"
    (run_dir / ".flatpak-helper" / "monitor").mkdir(parents=True)
    result = _run_script(
        tmp_path, path=fake_bin + os.pathsep + os.environ["PATH"],
        extra_env={"HUGMESH_STUDIO_FLATPAK_USER_DIR": private,
                   "HUGMESH_STUDIO_FLATPAK_OUT": out,
                   "HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB": "0",
                   "XDG_RUNTIME_DIR": str(run_dir),
                   "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(tmp_path / "no-such-bus")})
    assert result.returncode == 1, result.stderr
    assert "no output from --print-specs" in result.stderr, result.stderr

    calls = _calls(log)
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

    builder = [shlex.split(a) for a in args if a.startswith("run ") and "org.flatpak.Builder" in a]
    assert len(builder) == 2, args                      # the round-trip probe, then the build
    for words in builder:
        for grant in ("--user", f"--filesystem={private}", f"--env=FLATPAK_USER_DIR={private}"):
            assert grant in words, f"the Builder ran without {grant}: {words}"
    build = next(w for w in builder if "--command=flatpak-builder" in w)
    tail = build[build.index("org.flatpak.Builder") + 1:]
    for flag in ("--user", "--disable-rofiles-fuse", "--force-clean"):
        assert flag in tail, f"flatpak-builder ran without {flag} (the release workflow's flags): {tail}"
    assert tail[-2:] == [os.path.join(out, "flatpak-work", "build-dir"), os.path.realpath(MANIFEST)]

    studio_version = re.search(r'(?m)^__version__ = "([^"]+)"',
                               _read(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"))).group(1)
    bundle = os.path.join(out, f"hugmesh-studio-{studio_version}-x86_64.flatpak")
    assert f"build-bundle {out}/flatpak-work/repo {bundle}.partial {APP_ID}" in args, args
    assert os.path.isfile(bundle) and os.path.isfile(bundle + ".sha256")
    assert f"install --user -y --noninteractive --bundle {bundle}" in args, args
    assert args[-1] == f"run --user --command={_manifest_scalar('command')} {APP_ID} --print-specs"

    # The wrapper the Builder hands to the host must pin the private directory itself:
    # the host command does not inherit the Builder's environment.
    wrapper = os.path.join(out, "flatpak-work", "bin", "flatpak-private")
    assert os.access(wrapper, os.X_OK), "the host-side flatpak wrapper was not written"
    subprocess.run([wrapper, "--version"], env={"PATH": fake_bin}, check=True,
                   capture_output=True, timeout=30)
    assert _calls(log)[-1] == ("flatpak", private, "--version"), (
        "the host-side wrapper does not pin FLATPAK_USER_DIR to the private directory")


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


def test_script_takes_its_facts_from_the_manifest_not_from_itself():
    """Bump the runtime in the manifest and the script must follow, so it holds no copy."""
    code = "\n".join(line for line in _read(SCRIPT).splitlines()
                     if not line.lstrip().startswith("#"))
    version = _manifest_scalar("runtime-version")
    for literal in (f"//{version}", "org.kde.", _manifest_scalar("command") + " "):
        assert literal not in code, (
            f"build-flatpak-local.sh hard-codes {literal!r}; read it from the manifest")
