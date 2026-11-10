"""The Studio's version follows the org's beta scheme, end to end.

What this pins, and why each one matters:

* ``__version__`` is ``MAJOR.MINOR.PATCH`` or ``MAJOR.MINOR.PATCH-beta.N``. It feeds the
  installer file names, the About box and the ``studio-v*`` release tag.
* An MSI cannot carry ``-beta.N``, so ``packaging/wix/msi_version.py`` maps it to a
  numeric ProductVersion that always goes up (``X.Y.0-beta.1`` -> ``X.Y.1``, final
  ``X.Y.0`` -> ``X.Y.99``). Both the release workflow and ``build-msi-wine.sh`` must
  hand WiX THAT number: ``-define Version=X.Y.0-beta.1`` makes WiX fail the build.
* The release workflow publishes only from a ``studio-v*`` tag ref, marks a beta as a
  pre-release that is never "latest", and runs every job on a GitHub-hosted runner
  (operator rule 2026-10-21: published downloads are built and signed on GitHub's
  runners; this replaces the scheme's RUNS_ON_PUBLISH line for this workflow). It has
  no pull_request trigger at all.
* RED IS THE CONTRACT for an existing release: the publish job fails unless the run was
  dispatched with ``republish=true``, and then it says loudly that every checksum
  changes. A green run that published nothing is how the gates were hand-deleted on
  2026-10-22 without anyone noticing, so no step carries a ``skip`` output any more.
* ``packaging/release_version.py`` is the one place that spells the version rules
  (format, ordering, the bump of the two files); the cut workflow and the release
  script call it rather than re-implementing them.
* The AppStream metadata's newest ``<release>`` is the same version, spelt with ``~``.

NO VERSION LITERALS. ``.github/workflows/studio-release-cut.yml`` runs this file AFTER
``release_version.py bump`` has rewritten the tree, so every expectation here is derived
from ``__version__`` (or from synthetic versions built around its MAJOR.MINOR). A test
that spelt one release line failed every cut that moved the version (eight red cuts on
2026-11-06), and the file was then hand-cut to one test to get 0.4.1-beta.1 out. The
mapping and ordering rules are restated below (``_expected_msi``, ``_key``) from the
docstrings of msi_version.py and release_version.py, so the functions under test never
supply their own expected values.
"""
from __future__ import annotations

import importlib.util
import os
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

import pytest
import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")
MSI_SCRIPT = os.path.join(STUDIO_ROOT, "packaging", "build-msi-wine.sh")
MAPPER = os.path.join(STUDIO_ROOT, "packaging", "wix", "msi_version.py")
RELEASE_VERSION = os.path.join(STUDIO_ROOT, "packaging", "release_version.py")
METAINFO = os.path.join(STUDIO_ROOT, "packaging", "flatpak", "org.hugmesh.ImageStudio.metainfo.xml")

BETA_VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?")

# GitHub runs a `run:` block as `bash -e {0}`. shutil.which, not a bare "bash": on
# Windows a bare name resolves to System32's WSL stub before PATH is searched.
BASH = shutil.which("bash") or "bash"


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _version() -> str:
    return re.search(r'(?m)^__version__ = "([^"]+)"',
                     _read(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"))).group(1)


def _script(path, body: str) -> None:
    """A fake tool for a `run:` block: LF endings even on Windows, executable."""
    path.write_text(body, newline="\n")
    path.chmod(0o755)


# ── the documented rules, restated independently of the code under test ───────────
def _key(version: str) -> tuple[int, int, int, int, int]:
    """release_version.py's ordering key: (major, minor, patch, 1 if final else 0, N)."""
    major, minor, patch, beta = BETA_VERSION.fullmatch(version).groups()
    return (int(major), int(minor), int(patch), 0 if beta else 1, int(beta) if beta else 0)


def _expected_msi(version: str) -> str:
    """msi_version.py's rule: build = PATCH * 100 + N for -beta.N, PATCH * 100 + 99 for
    the final release."""
    major, minor, patch, beta = BETA_VERSION.fullmatch(version).groups()
    return f"{major}.{minor}.{int(patch) * 100 + (int(beta) if beta else 99)}"


# The same docstring's cap: beta.99 is the final's slot, so a PATCH has betas 1..98.
_LAST_BETA = 98


# Synthetic versions around the tree's MAJOR.MINOR. They move with every bump, so no
# expectation below names a release line.
_MAJ, _MIN, _PATCH = (int(x) for x in BETA_VERSION.fullmatch(_version()).groups()[:3])
_BASE = f"{_MAJ}.{_MIN}.{_PATCH}"            # the current version without -beta.N


def _beta(patch: int, n: int, major: int = _MAJ, minor: int = _MIN) -> str:
    return f"{major}.{minor}.{patch}-beta.{n}"


def _final(patch: int, major: int = _MAJ, minor: int = _MIN) -> str:
    return f"{major}.{minor}.{patch}"


def _mapper():
    spec = importlib.util.spec_from_file_location("msi_version", MAPPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _workflow() -> dict:
    doc = yaml.safe_load(_read(WORKFLOW))
    # PyYAML reads the bare key `on` as the boolean True.
    doc["on"] = doc.pop(True, doc.get("on"))
    return doc


# ── the version itself ──────────────────────────────────────────────────────────────
def test_version_is_a_beta_scheme_version():
    version = _version()
    assert BETA_VERSION.fullmatch(version), (
        f"__version__ {version!r} is not MAJOR.MINOR.PATCH(-beta.N): the org's beta scheme "
        "allows no other form (no +build, no -SNAPSHOT, no -rc)")


# DROPPED: test_version_is_the_0_3_beta_line asserted __version__.startswith("0.3.").
# It pinned one historical line, so it could only fail a legitimate MINOR bump (it did,
# on 2026-11-06). It has no derived form; the ordering guards below cover the real rule
# (a release never goes backwards).


def test_python_metadata_normalises_the_beta_to_pep440():
    packaging_version = pytest.importorskip("packaging.version")
    version = packaging_version.Version(_version())
    assert version.is_prerelease == ("-" in _version())
    if "-" in _version():
        base, beta = _version().split("-beta.", 1)
        assert str(version) == f"{base}b{beta}"
        assert version < packaging_version.Version(base), "the beta must sort below its final"


# ── the MSI ProductVersion mapping ─────────────────────────────────────────────────
@pytest.mark.parametrize("semver,msi", [
    (_beta(0, 1), f"{_MAJ}.{_MIN}.1"),
    (_beta(0, 2), f"{_MAJ}.{_MIN}.2"),
    (_beta(0, 10), f"{_MAJ}.{_MIN}.10"),
    (_beta(0, 98), f"{_MAJ}.{_MIN}.98"),
    (_final(0), f"{_MAJ}.{_MIN}.99"),
    (_beta(1, 1), f"{_MAJ}.{_MIN}.101"),
    (_beta(0, 1, minor=_MIN + 1), f"{_MAJ}.{_MIN + 1}.1"),
    (_beta(0, 1, major=_MAJ + 1, minor=0), f"{_MAJ + 1}.0.1"),
    # The format's ceiling (MSI major/minor <= 255, build <= 65535), not a release line.
    ("255.255.654", "255.255.65499"),
    (_version(), _expected_msi(_version())),
])
def test_msi_version_mapping(semver, msi):
    assert _expected_msi(semver) == msi, "the test's own restatement of the rule drifted"
    assert _mapper().msi_version(semver) == msi


@pytest.mark.parametrize("bad", [
    f"{_BASE}-SNAPSHOT", f"{_BASE}-rc.1", f"{_BASE}-beta.0", f"{_BASE}-beta.99", f"{_BASE}-beta",
    f"{_BASE}+build.1", f"{_MAJ}.{_MIN}", "256.0.0", "0.256.0", f"{_MAJ}.{_MIN}.655", f"v{_BASE}",
])
def test_msi_version_refuses_what_it_cannot_order(bad):
    with pytest.raises(ValueError):
        _mapper().msi_version(bad)


def _ladder() -> list[str]:
    """A strictly increasing run of versions around the tree's MAJOR.MINOR, with the
    current version placed by the documented key (not by the code under test)."""
    order = [_beta(0, 1), _beta(0, 2), _beta(0, 9), _beta(0, 10), _beta(0, 98), _final(0),
             _beta(1, 1), _final(1), _beta(0, 1, minor=_MIN + 1),
             _beta(0, 1, major=_MAJ + 1, minor=0), _final(0, major=_MAJ + 1, minor=0)]
    if _version() not in order:
        order.append(_version())
    return sorted(order, key=_key)


def test_msi_versions_only_ever_go_up():
    """Windows Installer compares the three fields numerically; a later SemVer must give a
    strictly larger triple, or the newer MSI refuses to replace the older one."""
    order = _ladder()
    msi = [tuple(int(x) for x in _mapper().msi_version(v).split(".")) for v in order]
    assert msi == sorted(msi) and len(set(msi)) == len(msi), list(zip(order, msi))


def test_current_version_maps():
    assert _mapper().msi_version(_version()) == _expected_msi(_version())


def test_mapper_cli(capsys):
    mod = _mapper()
    assert mod.main([_beta(0, 1)]) == 0 and capsys.readouterr().out == f"{_MAJ}.{_MIN}.1\n"
    assert mod.main([f"{_BASE}-SNAPSHOT"]) == 1
    assert mod.main([]) == 2


# ── build-msi-wine.sh hands WiX the mapped number ──────────────────────────────────
def test_wine_build_defines_the_msi_version_not_the_semver():
    text = _read(MSI_SCRIPT)
    assert '-define "Version=$MSI_VERSION"' in text
    assert '-define "Version=$VERSION"' not in text
    assert 'MSI_VERSION=$(python3 "$WIX_SRC_DIR/msi_version.py" "$VERSION")' in text
    # The verifier compares the MSI's ProductVersion, so it must expect the mapped number.
    calls = re.findall(r'run_verifier "[^"]+" "\$(\w+)"', text)
    assert calls and set(calls) == {"MSI_VERSION"}, calls
    # The file name keeps the SemVer the user recognises.
    assert "MSI_NAME=hugmesh-studio-$VERSION-x64.msi" in text


# ── the release workflow ───────────────────────────────────────────────────────────
def test_workflow_has_no_pull_request_trigger():
    on = _workflow()["on"]
    assert set(on) == {"workflow_dispatch", "push"}, on
    # 'main' in a TAG filter (added by hand on 2026-10-23) can never match a branch.
    assert on["push"] == {"tags": ["studio-v*"]}, on["push"]
    inputs = on["workflow_dispatch"]["inputs"]
    assert set(inputs) == {"publish", "republish"}, sorted(inputs)
    for name in inputs:
        assert inputs[name]["type"] == "boolean" and inputs[name]["default"] is False, name
    assert "can no longer verify" in inputs["republish"]["description"], (
        "the republish input must state its consequence where the operator ticks it")
    assert "release-studio.sh" in inputs["publish"]["description"]


def test_every_job_is_github_hosted():
    jobs = _workflow()["jobs"]
    assert jobs["version"]["runs-on"] == "ubuntu-latest"
    assert jobs["publish"]["runs-on"] == "ubuntu-latest"
    assert jobs["msi"]["runs-on"] == "windows-latest"
    assert jobs["linux"]["runs-on"] == "ubuntu-24.04"
    # flatpak installs its tooling with `sudo apt-get`; the local runner is Gentoo.
    assert jobs["flatpak"]["runs-on"] == "ubuntu-latest"
    # The aarch64 twin: GitHub's hosted arm64 image, free for public repositories.
    assert jobs["flatpak-aarch64"]["runs-on"] == "ubuntu-24.04-arm"
    text = _read(WORKFLOW)
    assert not re.search(r"vars\.RUNS_ON", text), (
        "the release workflow reads a RUNS_ON* variable, which can move the build or the "
        "signing onto the self-hosted runner")


def test_publish_runs_only_on_a_studio_tag_ref():
    cond = _workflow()["jobs"]["publish"]["if"]
    assert "startsWith(github.ref, 'refs/tags/studio-v')" in cond
    # `inputs.publish` alone (a dispatch on main with the box ticked) must not publish.
    assert re.search(r"startsWith\(github\.ref, 'refs/tags/studio-v'\)\s*&&", cond), cond
    assert "permissions" in _workflow()["jobs"]["publish"]
    assert _workflow()["jobs"]["publish"]["permissions"] == {
        "contents": "write", "id-token": "write", "attestations": "write"}


def test_version_job_guards_ref_tag_and_snapshot():
    steps = _workflow()["jobs"]["version"]["steps"]
    runs = "\n".join(s.get("run", "") for s in steps)
    assert 'tag="${GITHUB_REF_NAME#studio-v}"' in runs, "the tag-must-match-__version__ gate is gone"
    assert "refs/heads/main|refs/tags/studio-v*)" in runs, "the ref gate is gone"
    assert "*-SNAPSHOT*)" in runs
    assert "python3 studio/packaging/wix/msi_version.py" in runs
    outputs = _workflow()["jobs"]["version"]["outputs"]
    assert set(outputs) == {"version", "msi_version"}
    # publish=true off a tag fails in seconds, not after a 40-minute build that skips.
    refusal = next(s for s in steps if s.get("name") == "A publish from main is impossible")
    assert refusal["if"] == "inputs.publish == true && !startsWith(github.ref, 'refs/tags/studio-v')"
    assert "which never publishes" in refusal["run"] and "release-studio.sh" in refusal["run"]
    assert "exit 1" in refusal["run"]
    verdict = next(s for s in steps if s.get("name") == "Say whether this run will publish")
    assert verdict["if"] == "always()"
    assert "WILL NOT publish" in verdict["run"] and "WILL publish" in verdict["run"]
    assert "GITHUB_STEP_SUMMARY" in verdict["run"]


_TAG_REF = f"refs/tags/studio-v{_version()}"


@pytest.mark.parametrize("ref, event, publish, want", [
    # A hand-pushed tag: inputs.publish is EMPTY on a push event. This combination once
    # exited 1 under `bash -e` (a false `[ ]` inside a `$( )` failed the assignment) and
    # killed the job every build job needs, so a documented release path was dead.
    (_TAG_REF, "push", "", "WILL publish (tag ref; push event)"),
    (_TAG_REF, "workflow_dispatch", "true", "WILL publish (tag ref; workflow_dispatch event, publish=true)"),
    (_TAG_REF, "workflow_dispatch", "false", "WILL NOT publish (tag ref, but publish was not ticked)"),
    ("refs/heads/main", "workflow_dispatch", "", "WILL NOT publish (refs/heads/main is not a studio-v* tag"),
    ("refs/heads/main", "push", "", "WILL NOT publish (refs/heads/main is not a studio-v* tag"),
])
def test_verdict_step_runs_to_the_end_for_every_event(tmp_path, ref, event, publish, want):
    steps = _workflow()["jobs"]["version"]["steps"]
    script = next(s for s in steps if s.get("name") == "Say whether this run will publish")["run"]
    summary = tmp_path / "summary"
    summary.write_text("")
    env = {"PATH": "/usr/bin:/bin", "REF": ref, "EVENT": event, "PUBLISH": publish, "REPUBLISH": "",
           "GITHUB_STEP_SUMMARY": str(summary)}
    proc = subprocess.run([BASH, "-e", "-c", script], env=env, capture_output=True, text=True)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert want in proc.stdout, proc.stdout
    assert want in summary.read_text()


def test_msi_job_defines_the_numeric_version():
    job = _workflow()["jobs"]["msi"]
    assert job["env"]["MSI_VERSION"] == "${{ needs.version.outputs.msi_version }}"
    wix = next(s["run"] for s in job["steps"] if s.get("name") == "Build the MSI")
    assert "-define Version=$env:MSI_VERSION" in wix
    assert "-define Version=$env:VERSION " not in wix
    assert '-out "hugmesh-studio-$env:VERSION-x64.msi"' in wix


def test_release_is_a_prerelease_never_latest_and_never_overwritten():
    """RED is the contract: a green run that published nothing is how the gates were
    hand-deleted on 10-22. An existing release fails the job unless republish=true was
    dispatched, so there is no `skip` output for a hand edit to remove any more."""
    steps = _workflow()["jobs"]["publish"]["steps"]
    release = next(s for s in steps if s.get("uses", "").startswith("softprops/action-gh-release"))
    assert release["with"]["prerelease"] == "${{ contains(env.VERSION, '-') }}"
    assert release["with"]["make_latest"] == "${{ contains(env.VERSION, '-') && 'false' || 'true' }}"
    exists = next(s for s in steps if s.get("id") == "exists")
    assert 'gh release view "studio-v$VERSION"' in exists["run"]
    assert steps[0] is exists, "the overwrite check must run before anything is built or uploaded"
    assert exists["env"]["REPUBLISH"] == "${{ inputs.republish }}"
    assert "exit 1" in exists["run"] and "--republish" in exists["run"]
    assert "::warning::REPUBLISHING" in exists["run"]
    # Second: the ref IS the tag of this version (the gate deleted by hand on 10-23).
    ref = steps[1]
    assert ref["name"] == "The ref must be the tag of this version", ref
    assert '[ "$GITHUB_REF" != "refs/tags/studio-v$VERSION" ]' in ref["run"] and "exit 1" in ref["run"]
    # No step anywhere reads or writes a `skip`: a skip is a green run that did nothing.
    for step in steps:
        assert "skip" not in str(step.get("if", "")), step.get("name")
        assert "skip=" not in step.get("run", ""), step.get("name")
    assert "outputs.skip" not in _read(WORKFLOW)
    notes = next(s for s in steps if s.get("name") == "Write the release notes")
    assert notes["env"]["REPLACED"] == "${{ steps.exists.outputs.replaced }}"
    summarise = next(s for s in steps if s.get("name") == "Summarise")
    assert "if" not in summarise
    assert summarise["env"]["REPLACED"] == "${{ steps.exists.outputs.replaced }}"
    assert "REPUBLISHED: all checksums changed" in summarise["run"]
    # The site notification stays last and ungated.
    assert steps[-1]["name"] == "Tell hugmesh.github.io to rebuild its downloads data"


# ── AppStream ──────────────────────────────────────────────────────────────────────
def test_metainfo_newest_release_is_this_version():
    releases = ET.parse(METAINFO).getroot().find("releases")
    newest = releases.find("release")
    assert newest.get("version") == _version().replace("-", "~", 1), (
        "the metainfo's newest <release> does not name __version__ (AppStream spells "
        "a pre-release with '~' so it sorts below its final release)")
    # release_version.py bump: a beta is type="development", a final carries no type.
    assert (newest.get("type") == "development") == ("-" in _version()), newest.attrib
    # ADAPTED: this used to refuse a literal "1.0.0" entry (the never-published 1.0.0
    # that made software centres show 1.0.0). That literal would fail the day 1.0.0 is
    # really cut, so the rule is now the general one: no entry sorts above __version__.
    for entry in releases.findall("release"):
        spelt = entry.get("version").replace("~", "-", 1)
        assert BETA_VERSION.fullmatch(spelt), f"metainfo entry {entry.get('version')!r} is not a scheme version"
        assert _key(spelt) <= _key(_version()), (
            f"metainfo entry {entry.get('version')} is newer than __version__ {_version()}: "
            "software centres would show it")


_RELEASE_ID = f"studio-v{_version()}"
EXISTS = ('{"tagName":"' + _RELEASE_ID + '","assets":[{"updatedAt":"2026-10-23T07:35:52Z"},'
          '{"updatedAt":"2026-10-22T10:28:46Z"}]}')


@pytest.mark.parametrize("gh_rc,gh_out,republish,want_rc,want_output,want_text", [
    # the release exists and nobody asked to replace it: RED, names the way to do so
    (0, EXISTS, "false", 1, "", "--republish"),
    (0, EXISTS, "", 1, "", "--republish"),                       # a push event: no inputs at all
    # the release exists and republish was asked for: go on, loudly
    (0, EXISTS, "true", 0, "replaced=true\n",
     f"::warning::REPUBLISHING {_RELEASE_ID}: 2 files will be replaced (newest currently from 2026-10-23T07:35:52Z)"),
    (0, '{"tagName":"' + _RELEASE_ID + '"}', "true", 0, "replaced=true\n", "::warning::REPUBLISHING"),
    # it does not exist: a republish is an error, a normal publish goes on
    (1, "release not found", "true", 1, "", "does not exist; run a normal release"),
    (1, "release not found", "false", 0, "replaced=false\n", ""),
    # cannot tell: stop, never guess, whatever was asked
    (1, "HTTP 502: Bad Gateway", "false", 1, "", "could not tell"),
    (1, "HTTP 502: Bad Gateway", "true", 1, "", "could not tell"),
    (4, "authentication required", "false", 1, "", "could not tell"),
    (4, "authentication required", "true", 1, "", "could not tell"),
])
def test_overwrite_check_fails_closed(tmp_path, gh_rc, gh_out, republish, want_rc, want_output, want_text):
    """Run the real step script with a fake `gh`. Only gh's own "release not found" may
    count as absent: treating a network or auth failure as absent would send the publish
    step at a release that may exist, and it replaces same-named files. An existing
    release is RED unless REPUBLISH=true, and then the warning names what is replaced."""
    steps = _workflow()["jobs"]["publish"]["steps"]
    script = next(s for s in steps if s.get("id") == "exists")["run"]
    bindir = tmp_path / "bin"
    bindir.mkdir()
    _script(bindir / "gh", f"#!/bin/sh\nprintf '%s\\n' '{gh_out}' >&2\nexit {gh_rc}\n")
    # The step counts the assets with `python3 -c`; hand it this interpreter, so the
    # check does not depend on what /usr/bin happens to hold.
    _script(bindir / "python3", f"#!/bin/sh\nexec {shlex.quote(sys.executable)} \"$@\"\n")
    out_file = tmp_path / "github_output"
    out_file.write_text("")
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "VERSION": _version(), "REPUBLISH": republish,
           "GITHUB_REPOSITORY": "hugmesh/hugmesh-generator", "GITHUB_OUTPUT": str(out_file)}
    proc = subprocess.run([BASH, "-e", "-c", script], env=env, capture_output=True, text=True)
    assert proc.returncode == want_rc, (proc.stdout, proc.stderr)
    assert out_file.read_text() == want_output
    assert want_text in proc.stdout + proc.stderr, (proc.stdout, proc.stderr)
    if want_rc == 1:
        assert "::error::" in proc.stdout


def _counterpart() -> str:
    """A version of the other kind: the final of a beta, or the next beta of a final."""
    return _BASE if "-" in _version() else _beta(_PATCH + 1, 1)


@pytest.mark.parametrize("version", [_version(), _counterpart()])
@pytest.mark.parametrize("replaced", ["true", "false", ""])
def test_release_notes_say_when_files_were_replaced(tmp_path, replaced, version):
    steps = _workflow()["jobs"]["publish"]["steps"]
    script = next(s for s in steps if s.get("name") == "Write the release notes")["run"]
    env = {"PATH": "/usr/bin:/bin", "VERSION": version, "GITHUB_REPOSITORY": "hugmesh/hugmesh-generator",
           "AUTHENTICODE": "false", "REPLACED": replaced, "GITHUB_SHA": "abc123", "GITHUB_RUN_ID": "42",
           "GITHUB_SERVER_URL": "https://github.com"}
    proc = subprocess.run([BASH, "-e", "-c", script], env=env, cwd=tmp_path, capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    notes = (tmp_path / "release-notes.md").read_text(encoding="utf-8")
    assert ("Files replaced on" in notes) == (replaced == "true")
    if replaced == "true":
        assert "every checksum, signature and attestation changed" in notes
        assert "from abc123 by run https://github.com/hugmesh/hugmesh-generator/actions/runs/42" in notes
        assert "must re-download to verify" in notes
    stage = " (beta, pre-release)" if "-" in version else ""
    assert notes.startswith(f"HugMesh Image Studio {version}{stage}.\n"), notes[:120]
    assert "**Windows**" in notes
    assert f"hugmesh-studio-{version}-x64.msi" in notes


# ── release_version.py: the one place the version rules are spelt ─────────────────
def _rv(*args, **kwargs):
    return subprocess.run([sys.executable, RELEASE_VERSION, *args], capture_output=True, text=True, **kwargs)


def test_release_version_cli_current_next_validate_compare():
    assert _rv("current").stdout.strip() == _version()
    if "-" in _version():
        n = int(_version().rsplit(".", 1)[1])
        if n < _LAST_BETA:
            assert _rv("next").stdout.strip() == _beta(_PATCH, n + 1)
        else:
            # The last beta slot: there is no next beta of this PATCH (see below).
            assert _rv("next").returncode == 1
        assert _rv("next", "--final").stdout.strip() == _BASE
    else:
        # After a final release the next beta is the next PATCH's beta.1, and a final
        # has no "final" of its own.
        assert _rv("next").stdout.strip() == _beta(_PATCH + 1, 1)
        proc = _rv("next", "--final")
        assert proc.returncode == 1 and "already a final release" in proc.stderr
    assert _rv("next", _final(0)).stdout.strip() == _beta(1, 1)
    assert _rv("next", _beta(0, 9)).stdout.strip() == _beta(0, 10)
    assert _rv("next", _beta(0, _LAST_BETA - 1)).stdout.strip() == _beta(0, _LAST_BETA)
    # `next` never proposes a version `validate` refuses: after the last beta slot it
    # fails (printing nothing) and names the two ways on, the final and the next PATCH.
    proc = _rv("next", _beta(0, _LAST_BETA))
    assert proc.returncode == 1 and proc.stdout == "", proc.stdout
    assert "--final" in proc.stderr and _beta(1, 1) in proc.stderr, proc.stderr
    assert _rv("validate", _beta(0, _LAST_BETA + 1)).returncode == 1
    assert _rv("next", _beta(0, _LAST_BETA), "--final").stdout.strip() == _final(0)
    # Whatever `next` prints validates; where it prints nothing it must say so with exit 1.
    for base in (_version(), _final(0), _beta(0, 1), _beta(0, _LAST_BETA - 1), _beta(0, _LAST_BETA)):
        proc = _rv("next", base)
        if proc.returncode == 0:
            assert _rv("validate", proc.stdout.strip()).returncode == 0, (base, proc.stdout)
        else:
            assert proc.returncode == 1 and proc.stdout == "" and base == _beta(_key(base)[2], _LAST_BETA), base
    assert _rv("validate", _beta(0, 2)).returncode == 0
    assert _rv("validate", _version()).returncode == 0
    for bad in (f"{_BASE}-rc.1", f"{_BASE}-SNAPSHOT", f"{_BASE}+build.1", f"{_BASE}-beta.0",
                f"{_BASE}-beta.99", f"v{_BASE}"):
        assert _rv("validate", bad).returncode == 1, bad
    # A new release must sort strictly after the newest valid studio-v* tag; a tag that
    # is not a version is ignored.
    tags = [f"refs/tags/studio-v{_beta(0, 2)}", f"studio-v{_beta(0, 1)}", "refs/tags/studio-vgarbage"]
    assert _rv("validate", _beta(0, 2), "--after-tags", *tags).returncode == 1, "equal to the newest tag"
    assert _rv("validate", _beta(0, 1), "--after-tags", *tags).returncode == 1, "below the newest tag"
    assert _rv("validate", _beta(0, 3), "--after-tags", *tags).returncode == 0
    assert _rv("validate", _final(0), "--after-tags", *tags).returncode == 0
    assert _rv("validate", _beta(0, 2), "--after-tags").returncode == 0, "no tags yet: anything valid goes"
    order = [_beta(0, 1), _beta(0, 2), _beta(0, 10), _final(0), _beta(1, 1), _final(1),
             _beta(0, 1, minor=_MIN + 1)]
    assert order == sorted(order, key=_key), "the test's own ladder is out of order"
    for a, b in zip(order, order[1:]):
        assert _rv("compare", a, b).stdout.strip() == "lt", (a, b)
        assert _rv("compare", b, a).stdout.strip() == "gt", (a, b)
    assert _rv("compare", _final(0), _final(0)).stdout.strip() == "eq"
    assert _rv("compare", _version(), _version()).stdout.strip() == "eq"


def test_bump_version_edits_both_files(tmp_path):
    root = tmp_path / "tree"
    (root / "studio" / "hugmesh_studio").mkdir(parents=True)
    (root / "studio" / "packaging" / "flatpak").mkdir(parents=True)
    shutil.copy(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), root / "studio" / "hugmesh_studio")
    shutil.copy(METAINFO, root / "studio" / "packaging" / "flatpak")
    before_text = _read(METAINFO)
    before = ET.parse(METAINFO).getroot().find("releases").findall("release")
    # Targets are derived from the tree, never spelt: the cut's preflight runs this
    # test AFTER bumping the working tree, so a literal target is already present
    # there from the second cut on.
    # At the last beta slot `next` has no beta to propose, so the next valid version is
    # the final (`next --final`); a cut to X.Y.Z-beta.98 must not turn this test red.
    def next_valid(*base):
        proc = _rv("next", *base)
        return (proc if proc.returncode == 0 else _rv("next", *base, "--final")).stdout.strip()

    target = next_valid("--root", str(root))
    assert target, "release_version.py next printed nothing"
    final = _rv("next", target, "--final").stdout.strip() if "-" in target else next_valid(target)
    assert final, "release_version.py next printed nothing"
    assert f'<release version="{target.replace("-", "~")}"' not in before_text, target
    assert f'<release version="{final.replace("-", "~")}"' not in before_text, final
    proc = _rv("bump", target, "--root", str(root), "--date", "2026-10-28")
    assert proc.returncode == 0, proc.stderr
    assert _rv("current", "--root", str(root)).stdout.strip() == target
    meta = root / "studio" / "packaging" / "flatpak" / "org.hugmesh.ImageStudio.metainfo.xml"
    releases = ET.parse(meta).getroot().find("releases").findall("release")
    assert releases[0].get("version") == target.replace("-", "~")
    assert (releases[0].get("type") == "development") == ("-" in target)
    assert releases[0].get("date") == "2026-10-28"
    assert [r.get("version") for r in releases[1:]] == [r.get("version") for r in before], "an old entry was lost"
    text = meta.read_text(encoding="utf-8")
    assert "AppStream spells a pre-release with" in text, "the explanatory comment was lost"
    # Every older <release> block survives as it was (this used to look for the first
    # entry's "<p>First beta.</p>"; the derived form checks all of them).
    for block in re.findall(r"(?s)<release\b.*?</release>", before_text):
        assert block in text, block[:80]
    # Idempotent: a second bump to the same version changes nothing.
    snapshot = {p.name: p.read_bytes() for p in (meta, root / "studio" / "hugmesh_studio" / "__init__.py")}
    proc = _rv("bump", target, "--root", str(root), "--date", "2026-11-01")
    assert proc.returncode == 0 and "nothing changed" in proc.stdout
    assert {p.name: p.read_bytes() for p in (meta, root / "studio" / "hugmesh_studio" / "__init__.py")} == snapshot
    # A bump BACKWARDS is refused and changes nothing (the files would disagree).
    proc = _rv("bump", _version(), "--root", str(root), "--date", "2026-11-02")
    assert proc.returncode == 1 and "never goes backwards" in proc.stderr
    assert {p.name: p.read_bytes() for p in (meta, root / "studio" / "hugmesh_studio" / "__init__.py")} == snapshot
    # A final release gets no type="development".
    proc = _rv("bump", final, "--root", str(root), "--date", "2026-12-01")
    assert proc.returncode == 0, proc.stderr
    newest = ET.parse(meta).getroot().find("releases").find("release")
    assert newest.get("version") == final.replace("-", "~")
    assert (newest.get("type") == "development") == ("-" in final)
    assert _rv("bump", f"{_BASE}-rc.1", "--root", str(root)).returncode == 1
