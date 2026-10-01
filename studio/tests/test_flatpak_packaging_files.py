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
  * the local build script is executable IN GIT (a fresh clone takes its mode from the
    commit, not from your disk), never calls sudo or a package manager, refuses to touch
    a flatpak directory somebody already uses, and names the one broken-helper state
    that otherwise shows up only as an opaque bwrap error.

Qt-free and offline: it reads files and runs the script's early refusals only, and never
starts flatpak.
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
    for piled_up in ("build", "dist", ".venv", ".venv-studio", ".pytest_cache"):
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
#: word in COMMAND position counts.
_FORBIDDEN = {"sudo", "doas", "pkexec", "su", "apt", "apt-get", "dpkg", "dnf", "yum",
              "pacman", "zypper", "emerge", "brew", "nix-env", "snap"}
_PREFIXES = {"exec", "command", "env", "nohup", "xargs", "time", "then", "do", "else",
             "elif", "if", "while", "until", "!", "{"}
_SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", ";;", "|&"}


def _command_words(text: str):
    """Yield ``(line, word)`` for each word the script puts where a command goes.

    Skips comments and heredoc bodies (the usage text, the embedded Python), joins
    backslash continuations, and treats ``$( ... )``/backtick substitutions inside a
    double-quoted string as commands too, since a quoted string is otherwise one opaque
    token and ``x="$(sudo foo)"`` would sail through.
    """
    text = text.replace("\\\n", " ")
    heredoc_end = None
    for number, raw in enumerate(text.splitlines(), 1):
        if heredoc_end is not None:
            if raw.strip() == heredoc_end:
                heredoc_end = None
            continue
        line = raw.strip()
        if not line:
            continue
        opener = re.search(r"<<-?\s*(['\"]?)(\w+)\1", line)
        for inner in re.findall(r"(?:\$\(|`)\s*(?:command\s+-v\s+)?([\w.\-]+)", line):
            yield number, inner
        try:
            lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:                     # a quote that closes on a later line
            tokens = line.split()
        expecting = True
        for token in tokens:
            if token in _SEPARATORS:
                expecting = True
            elif expecting:
                if not token.startswith("-"):
                    yield number, token
                expecting = token in _PREFIXES or token.startswith("-")
            else:
                expecting = False
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
    ("exec sudo -n true", ["sudo"]),
    ("echo 'run it without sudo or apt'", []),
    ("# sudo apt-get install flatpak-builder", []),
    ("die \"flatpak-builder, sudo and apt are not needed\"", []),
    ("flatpak run --user \\\n   apt org.flatpak.Builder", []),
    ("true \\\n  && sudo true", ["sudo"]),
    ("cat <<'EOF'\nsudo apt-get install foo\nEOF\nflatpak --version", []),
    ("flatpak --version  # sudo would be wrong here", []),
], ids=["plain", "after-and", "probe", "substitution", "exec-prefix", "in-string",
        "in-comment", "in-message", "argument-on-continuation", "command-on-continuation",
        "in-heredoc", "trailing-comment"])
def test_the_forbidden_command_scanner_sees_what_it_must(snippet, expected):
    """The scanner is what the test above stands on, so it is pinned in both directions."""
    assert [word for _line, word in _forbidden_in(snippet)] == expected


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


def test_script_takes_its_facts_from_the_manifest_not_from_itself():
    """Bump the runtime in the manifest and the script must follow, so it holds no copy."""
    code = "\n".join(line for line in _read(SCRIPT).splitlines()
                     if not line.lstrip().startswith("#"))
    version = _manifest_scalar("runtime-version")
    for literal in (f"//{version}", "org.kde.", _manifest_scalar("command") + " "):
        assert literal not in code, (
            f"build-flatpak-local.sh hard-codes {literal!r}; read it from the manifest")
