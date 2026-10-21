"""The Studio's version follows the org's beta scheme, end to end.

What this pins, and why each one matters:

* ``__version__`` is ``MAJOR.MINOR.PATCH`` or ``MAJOR.MINOR.PATCH-beta.N``. It feeds the
  installer file names, the About box and the ``studio-v*`` release tag.
* An MSI cannot carry ``-beta.N``, so ``packaging/wix/msi_version.py`` maps it to a
  numeric ProductVersion that always goes up (``0.3.0-beta.1`` -> ``0.3.1``, final
  ``0.3.0`` -> ``0.3.99``). Both the release workflow and ``build-msi-wine.sh`` must
  hand WiX THAT number: ``-define Version=0.3.0-beta.1`` makes WiX fail the build.
* The release workflow publishes only from a ``studio-v*`` tag ref, marks a beta as a
  pre-release that is never "latest", and puts only its version and publish jobs on
  the self-hosted runner, and only when ``RUNS_ON_PUBLISH`` is set and the run is not a
  pull request. It has no pull_request trigger at all.
* The AppStream metadata's newest ``<release>`` is the same version, spelt with ``~``.
"""
from __future__ import annotations

import importlib.util
import os
import re
import xml.etree.ElementTree as ET

import pytest
import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")
MSI_SCRIPT = os.path.join(STUDIO_ROOT, "packaging", "build-msi-wine.sh")
MAPPER = os.path.join(STUDIO_ROOT, "packaging", "wix", "msi_version.py")
METAINFO = os.path.join(STUDIO_ROOT, "packaging", "flatpak", "org.hugmesh.ImageStudio.metainfo.xml")

# The org's publish-runner line (beta SCHEME.md section 3.1), character for character.
PUBLISH_RUNS_ON = (
    "${{ fromJSON(github.event_name != 'pull_request' && github.event_name != "
    "'pull_request_target' && (github.ref == 'refs/heads/main' || startsWith(github.ref, "
    "'refs/tags/v') || startsWith(github.ref, 'refs/tags/studio-v')) && "
    "vars.RUNS_ON_PUBLISH || '\"ubuntu-latest\"') }}")
BETA_VERSION = re.compile(r"\d+\.\d+\.\d+(?:-beta\.[1-9]\d*)?")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _version() -> str:
    return re.search(r'(?m)^__version__ = "([^"]+)"',
                     _read(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"))).group(1)


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


def test_version_is_the_0_3_beta_line():
    # The scheme lowered an unpublished 1.0.0 to the 0.3 line (in daily use, open
    # defects). Raising MAJOR/MINOR is a deliberate decision, so it must edit this test.
    assert _version().startswith("0.3."), _version()


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
    ("0.3.0-beta.1", "0.3.1"),
    ("0.3.0-beta.2", "0.3.2"),
    ("0.3.0-beta.10", "0.3.10"),
    ("0.3.0-beta.98", "0.3.98"),
    ("0.3.0", "0.3.99"),
    ("0.3.1-beta.1", "0.3.101"),
    ("1.0.0-beta.1", "1.0.1"),
    ("255.255.654", "255.255.65499"),
])
def test_msi_version_mapping(semver, msi):
    assert _mapper().msi_version(semver) == msi


@pytest.mark.parametrize("bad", [
    "0.3.0-SNAPSHOT", "0.3.0-rc.1", "0.3.0-beta.0", "0.3.0-beta.99", "0.3.0-beta",
    "0.3.0+build.1", "0.3", "256.0.0", "0.256.0", "0.3.655", "v0.3.0",
])
def test_msi_version_refuses_what_it_cannot_order(bad):
    with pytest.raises(ValueError):
        _mapper().msi_version(bad)


def test_msi_versions_only_ever_go_up():
    """Windows Installer compares the three fields numerically; a later SemVer must give a
    strictly larger triple, or the newer MSI refuses to replace the older one."""
    order = ["0.3.0-beta.1", "0.3.0-beta.2", "0.3.0-beta.9", "0.3.0-beta.10", "0.3.0-beta.98",
             "0.3.0", "0.3.1-beta.1", "0.3.1", "0.4.0-beta.1", "1.0.0-beta.1", "1.0.0"]
    msi = [tuple(int(x) for x in _mapper().msi_version(v).split(".")) for v in order]
    assert msi == sorted(msi) and len(set(msi)) == len(msi), list(zip(order, msi))


def test_current_version_maps():
    assert re.fullmatch(r"\d+\.\d+\.\d+", _mapper().msi_version(_version()))


def test_mapper_cli(capsys):
    mod = _mapper()
    assert mod.main(["0.3.0-beta.1"]) == 0 and capsys.readouterr().out == "0.3.1\n"
    assert mod.main(["0.3.0-SNAPSHOT"]) == 1
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
    assert on["push"] == {"tags": ["studio-v*"]}, on["push"]


def test_publishing_jobs_use_the_publish_runner_line_and_builds_stay_hosted():
    jobs = _workflow()["jobs"]
    assert jobs["version"]["runs-on"] == PUBLISH_RUNS_ON
    assert jobs["publish"]["runs-on"] == PUBLISH_RUNS_ON
    assert jobs["msi"]["runs-on"] == "windows-latest"
    # flatpak installs its tooling with `sudo apt-get`; the local runner is Gentoo.
    assert jobs["flatpak"]["runs-on"] == "ubuntu-latest"
    text = _read(WORKFLOW)
    assert not re.search(r"vars\.RUNS_ON\b(?!_PUBLISH)", text), (
        "the release workflow reads vars.RUNS_ON, which is set to the self-hosted runner "
        "for pull-request CI; publish jobs read RUNS_ON_PUBLISH only")


def test_publish_runs_only_on_a_studio_tag_ref():
    cond = _workflow()["jobs"]["publish"]["if"]
    assert "startsWith(github.ref, 'refs/tags/studio-v')" in cond
    # `inputs.publish` alone (a dispatch on main with the box ticked) must not publish.
    assert re.search(r"startsWith\(github\.ref, 'refs/tags/studio-v'\)\s*&&", cond), cond
    assert "permissions" in _workflow()["jobs"]["publish"]
    assert _workflow()["jobs"]["publish"]["permissions"] == {"contents": "write"}


def test_version_job_guards_ref_tag_and_snapshot():
    steps = _workflow()["jobs"]["version"]["steps"]
    runs = "\n".join(s.get("run", "") for s in steps)
    assert 'tag="${GITHUB_REF_NAME#studio-v}"' in runs, "the tag-must-match-__version__ gate is gone"
    assert "refs/heads/main|refs/tags/studio-v*)" in runs, "the ref gate is gone"
    assert "*-SNAPSHOT*)" in runs
    assert "python3 studio/packaging/wix/msi_version.py" in runs
    outputs = _workflow()["jobs"]["version"]["outputs"]
    assert set(outputs) == {"version", "msi_version"}


def test_msi_job_defines_the_numeric_version():
    job = _workflow()["jobs"]["msi"]
    assert job["env"]["MSI_VERSION"] == "${{ needs.version.outputs.msi_version }}"
    wix = next(s["run"] for s in job["steps"] if s.get("name") == "Build the MSI")
    assert "-define Version=$env:MSI_VERSION" in wix
    assert "-define Version=$env:VERSION " not in wix
    assert '-out "hugmesh-studio-$env:VERSION-x64.msi"' in wix


def test_release_is_a_prerelease_never_latest_and_never_overwritten():
    steps = _workflow()["jobs"]["publish"]["steps"]
    release = next(s for s in steps if s.get("uses", "").startswith("softprops/action-gh-release"))
    assert release["with"]["prerelease"] == "${{ contains(env.VERSION, '-') }}"
    assert release["with"]["make_latest"] == "${{ contains(env.VERSION, '-') && 'false' || 'true' }}"
    exists = next(s for s in steps if s.get("id") == "exists")
    assert 'gh release view "studio-v$VERSION"' in exists["run"]
    assert steps[0] is exists, "the overwrite check must run before anything is built or uploaded"
    for step in steps[1:]:
        assert step.get("if") == "steps.exists.outputs.skip != 'true'", step


# ── AppStream ──────────────────────────────────────────────────────────────────────
def test_metainfo_newest_release_is_this_version():
    releases = ET.parse(METAINFO).getroot().find("releases")
    newest = releases.find("release")
    assert newest.get("version") == _version().replace("-", "~", 1), (
        "the metainfo's newest <release> does not name __version__ (AppStream spells "
        "a pre-release with '~' so it sorts below its final release)")
    if "-" in _version():
        assert newest.get("type") == "development"
    assert all(r.get("version") != "1.0.0" for r in releases.findall("release")), (
        "the never-published 1.0.0 entry is back: software centres would show 1.0.0")
