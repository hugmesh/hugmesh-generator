"""The Studio's version follows the org's beta scheme, end to end.

What this pins, and why each one matters:

* ``__version__`` is ``MAJOR.MINOR.PATCH`` or ``MAJOR.MINOR.PATCH-beta.N``. It feeds the
  installer file names, the About box and the ``studio-v*`` release tag.
* An MSI cannot carry ``-beta.N``, so ``packaging/wix/msi_version.py`` maps it to a
  numeric ProductVersion that always goes up (``0.3.0-beta.1`` -> ``0.3.1``, final
  ``0.3.0`` -> ``0.3.99``). Both the release workflow and ``build-msi-wine.sh`` must
  hand WiX THAT number: ``-define Version=0.3.0-beta.1`` makes WiX fail the build.
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
"""
from __future__ import annotations

import ast
import glob
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
RELEASE_VERSION = os.path.join(STUDIO_ROOT, "packaging", "release_version.py")
METAINFO = os.path.join(STUDIO_ROOT, "packaging", "flatpak", "org.hugmesh.ImageStudio.metainfo.xml")

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


# There is deliberately NO test that pins the MAJOR.MINOR line. One did
# (``_version().startswith("0.3.")``) and it refused every 0.4 cut until the release
# tests were hand-edited and then gutted on main (20a65769 .. 07e8c40b). Ordering is the
# cut's job (``release_version.py validate --after-tags``), and
# ``test_no_test_locks_the_version_line`` below keeps such a lock from coming back.


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


@pytest.mark.parametrize("ref, event, publish, want", [
    # A hand-pushed tag: inputs.publish is EMPTY on a push event. This combination once
    # exited 1 under `bash -e` (a false `[ ]` inside a `$( )` failed the assignment) and
    # killed the job every build job needs, so a documented release path was dead.
    ("refs/tags/studio-v0.3.0-beta.2", "push", "", "WILL publish (tag ref; push event)"),
    ("refs/tags/studio-v0.3.0-beta.2", "workflow_dispatch", "true", "WILL publish (tag ref; workflow_dispatch event, publish=true)"),
    ("refs/tags/studio-v0.3.0-beta.2", "workflow_dispatch", "false", "WILL NOT publish (tag ref, but publish was not ticked)"),
    ("refs/heads/main", "workflow_dispatch", "", "WILL NOT publish (refs/heads/main is not a studio-v* tag"),
    ("refs/heads/main", "push", "", "WILL NOT publish (refs/heads/main is not a studio-v* tag"),
])
def test_verdict_step_runs_to_the_end_for_every_event(tmp_path, ref, event, publish, want):
    import subprocess
    steps = _workflow()["jobs"]["version"]["steps"]
    script = next(s for s in steps if s.get("name") == "Say whether this run will publish")["run"]
    summary = tmp_path / "summary"
    summary.write_text("")
    env = {"PATH": "/usr/bin:/bin", "REF": ref, "EVENT": event, "PUBLISH": publish, "REPUBLISH": "",
           "GITHUB_STEP_SUMMARY": str(summary)}
    # GitHub runs a `run:` block as `bash -e {0}`.
    proc = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True)
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
    if "-" in _version():
        assert newest.get("type") == "development"
    # No entry may name a version LATER than __version__: software centres show the
    # highest <release>, so a never-published one (the old 1.0.0 entry) would be what
    # users see. Ordered, not spelt: a real 1.0.0, once it is __version__, passes.
    spec = importlib.util.spec_from_file_location("release_version", RELEASE_VERSION)
    rv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rv)
    later = [r.get("version") for r in releases.findall("release")
             if rv.compare(r.get("version").replace("~", "-", 1), _version()) > 0]
    assert not later, f"metainfo <release> entries later than __version__ {_version()}: {later}"


EXISTS = '{"tagName":"studio-v0.3.0-beta.1","assets":[{"updatedAt":"2026-10-23T07:35:52Z"},{"updatedAt":"2026-10-22T10:28:46Z"}]}'


@pytest.mark.parametrize("gh_rc,gh_out,republish,want_rc,want_output,want_text", [
    # the release exists and nobody asked to replace it: RED, names the way to do so
    (0, EXISTS, "false", 1, "", "--republish"),
    (0, EXISTS, "", 1, "", "--republish"),                       # a push event: no inputs at all
    # the release exists and republish was asked for: go on, loudly
    (0, EXISTS, "true", 0, "replaced=true\n", "::warning::REPUBLISHING studio-v0.3.0-beta.1: 2 files will be replaced (newest currently from 2026-10-23T07:35:52Z)"),
    (0, '{"tagName":"studio-v0.3.0-beta.1"}', "true", 0, "replaced=true\n", "::warning::REPUBLISHING"),
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
    import subprocess
    steps = _workflow()["jobs"]["publish"]["steps"]
    script = next(s for s in steps if s.get("id") == "exists")["run"]
    bindir = tmp_path / "bin"
    bindir.mkdir()
    fake = bindir / "gh"
    fake.write_text(f"#!/bin/sh\nprintf '%s\\n' '{gh_out}' >&2\nexit {gh_rc}\n")
    fake.chmod(0o755)
    out_file = tmp_path / "github_output"
    out_file.write_text("")
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "VERSION": "0.3.0-beta.1", "REPUBLISH": republish,
           "GITHUB_REPOSITORY": "hugmesh/hugmesh-generator", "GITHUB_OUTPUT": str(out_file)}
    # GitHub runs a `run:` block as `bash -e {0}`.
    proc = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True)
    assert proc.returncode == want_rc, (proc.stdout, proc.stderr)
    assert out_file.read_text() == want_output
    assert want_text in proc.stdout + proc.stderr, (proc.stdout, proc.stderr)
    if want_rc == 1:
        assert "::error::" in proc.stdout


@pytest.mark.parametrize("replaced", ["true", "false", ""])
def test_release_notes_say_when_files_were_replaced(tmp_path, replaced):
    import subprocess
    steps = _workflow()["jobs"]["publish"]["steps"]
    script = next(s for s in steps if s.get("name") == "Write the release notes")["run"]
    env = {"PATH": "/usr/bin:/bin", "VERSION": "0.3.0-beta.2", "GITHUB_REPOSITORY": "hugmesh/hugmesh-generator",
           "AUTHENTICODE": "false", "REPLACED": replaced, "GITHUB_SHA": "abc123", "GITHUB_RUN_ID": "42",
           "GITHUB_SERVER_URL": "https://github.com"}
    proc = subprocess.run(["bash", "-e", "-c", script], env=env, cwd=tmp_path, capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    notes = (tmp_path / "release-notes.md").read_text()
    assert ("Files replaced on" in notes) == (replaced == "true")
    if replaced == "true":
        assert "every checksum, signature and attestation changed" in notes
        assert "from abc123 by run https://github.com/hugmesh/hugmesh-generator/actions/runs/42" in notes
        assert "must re-download to verify" in notes
    assert notes.startswith("HugMesh Image Studio 0.3.0-beta.2 (beta, pre-release).\n")
    assert "**Windows**" in notes


# ── release_version.py: the one place the version rules are spelt ─────────────────
def _rv(*args, **kwargs):
    import subprocess
    return subprocess.run(["python3", RELEASE_VERSION, *args], capture_output=True, text=True, **kwargs)


def test_release_version_cli_current_next_validate_compare():
    assert _rv("current").stdout.strip() == _version()
    base = _version().split("-")[0]
    if "-" in _version():
        n = int(_version().rsplit(".", 1)[1])
        assert _rv("next").stdout.strip() == f"{base}-beta.{n + 1}"
        assert _rv("next", "--final").stdout.strip() == base
    assert _rv("next", "0.3.0").stdout.strip() == "0.3.1-beta.1"
    assert _rv("validate", "0.3.0-beta.2").returncode == 0
    for bad in ("0.3.0-rc.1", "0.3.0-SNAPSHOT", "0.3.0+build.1", "0.3.0-beta.0", "0.3.0-beta.99", "v0.3.0"):
        assert _rv("validate", bad).returncode == 1, bad
    tags = ["refs/tags/studio-v0.3.0-beta.1", "refs/tags/studio-vgarbage"]
    assert _rv("validate", "0.3.0-beta.1", "--after-tags", *tags).returncode == 1
    assert _rv("validate", "0.3.0-beta.2", "--after-tags", *tags).returncode == 0
    assert _rv("validate", "0.3.0", "--after-tags", *tags).returncode == 0
    assert _rv("validate", "0.2.9", "--after-tags", *tags).returncode == 1
    assert _rv("validate", "0.3.0-beta.2", "--after-tags").returncode == 0, "no tags yet: anything valid goes"
    order = ["0.3.0-beta.1", "0.3.0-beta.2", "0.3.0-beta.10", "0.3.0", "0.3.1-beta.1", "0.3.1", "0.4.0-beta.1"]
    for a, b in zip(order, order[1:]):
        assert _rv("compare", a, b).stdout.strip() == "lt", (a, b)
        assert _rv("compare", b, a).stdout.strip() == "gt", (a, b)
    assert _rv("compare", "0.3.0", "0.3.0").stdout.strip() == "eq"


@pytest.mark.parametrize("base,flags,want", [
    # Pure functions of their input: version-independent, they hold at any __version__.
    ("0.3.0-beta.4", [], "0.3.0-beta.5"),
    ("0.3.0-beta.4", ["--final"], "0.3.0"),
    ("0.3.0", [], "0.3.1-beta.1"),
    ("0.3.0-beta.4", ["--minor"], "0.4.0-beta.1"),
    ("0.3.2", ["--minor"], "0.4.0-beta.1"),
    ("0.3.0-beta.4", ["--minor", "--final"], "0.4.0"),
    ("0.3.0-beta.4", ["--major"], "1.0.0-beta.1"),
    ("0.9.9", ["--major", "--final"], "1.0.0"),
])
def test_release_version_next_steps_patch_minor_major_and_final(base, flags, want):
    proc = _rv("next", base, *flags)
    assert proc.returncode == 0 and proc.stdout.strip() == want, (base, flags, proc.stdout, proc.stderr)
    assert _rv("compare", base, want).stdout.strip() == "lt", "next must always go up"


@pytest.mark.parametrize("base,flags,why", [
    ("0.3.0", ["--final"], "already a final release"),
    ("0.255.0", ["--minor"], "MSI"),                 # 0.256.0 cannot be an MSI ProductVersion
    ("255.0.0", ["--major"], "MSI"),
])
def test_release_version_next_refuses_what_cannot_follow(base, flags, why):
    proc = _rv("next", base, *flags)
    assert proc.returncode == 1 and why in proc.stderr, (proc.stdout, proc.stderr)
    assert _rv("next", "0.3.0", "--minor", "--major").returncode == 2, "--minor and --major exclude each other"


def test_release_version_next_from_the_tree():
    # Derived from __version__, so it holds after every bump (0.4.1-beta.1, 0.5.0, 1.0.0-beta.1...).
    ma, mi, _ = (int(x) for x in _version().split("-")[0].split("."))
    assert _rv("next", "--minor").stdout.strip() == f"{ma}.{mi + 1}.0-beta.1"
    assert _rv("next", "--major").stdout.strip() == f"{ma + 1}.0.0-beta.1"
    assert _rv("next", "--minor", "--final").stdout.strip() == f"{ma}.{mi + 1}.0"


TAGS_03 = ["refs/tags/studio-v0.3.0-beta.1", "refs/tags/studio-v0.3.0-beta.3", "refs/tags/studio-vjunk"]


@pytest.mark.parametrize("spec,flags,main,want", [
    # Keywords count from the newest TAG (what was released) ...
    ("next", [], "0.3.0-beta.3", "0.3.0-beta.4"),
    ("next-beta", [], "0.3.0-beta.3", "0.3.0-beta.4"),
    ("next-minor", [], "0.3.0-beta.3", "0.4.0-beta.1"),
    ("next-major", [], "0.3.0-beta.3", "1.0.0-beta.1"),
    ("next", ["--final"], "0.3.0-beta.3", "0.3.0"),
    ("next-minor", ["--final"], "0.3.0-beta.3", "0.4.0"),
    # ... except when main was bumped past every tag and never released (567a5a60):
    # that pending version, not a number main is already later than.
    ("next", [], "0.4.0-beta.2", "0.4.0-beta.2"),
    ("next-minor", [], "0.4.0-beta.2", "0.4.0-beta.2"),
    ("next", ["--final"], "0.4.0-beta.2", "0.4.0"),
    ("next-major", [], "0.4.0-beta.2", "1.0.0-beta.1"),
    # explicit versions pass through when they fit the channel
    ("0.5.0-beta.1", [], "0.3.0-beta.3", "0.5.0-beta.1"),
    ("0.5.0", ["--final"], "0.3.0-beta.3", "0.5.0"),
])
def test_release_version_resolve(spec, flags, main, want):
    proc = _rv("resolve", spec, *flags, "--main", main, "--after-tags", *TAGS_03)
    assert proc.returncode == 0 and proc.stdout.strip() == want, (spec, flags, main, proc.stdout, proc.stderr)
    # Whatever it resolves to, the cut's own ordering check accepts it.
    assert _rv("validate", want, "--after-tags", *TAGS_03).returncode == 0


@pytest.mark.parametrize("spec,flags,why", [
    ("0.5.0", [], "--final"),                 # a final is the LATEST release: say so
    ("0.5.0-beta.1", ["--final"], "is a beta"),
    ("0.5.0-rc.1", [], "not MAJOR.MINOR.PATCH"),
    ("nextminor", [], "not MAJOR.MINOR.PATCH"),
])
def test_release_version_resolve_refuses(spec, flags, why):
    proc = _rv("resolve", spec, *flags, "--main", "0.3.0-beta.3", "--after-tags", *TAGS_03)
    assert proc.returncode == 1 and why in proc.stderr, (proc.stdout, proc.stderr)
    proc = _rv("resolve", "next", "--final", "--main", "0.4.0", "--after-tags", "refs/tags/studio-v0.4.0")
    assert proc.returncode == 1 and "already a final release" in proc.stderr and "next-minor" in proc.stderr
    assert _rv("resolve", "next").returncode == 1, "no tag and no main: nothing to count from"
    assert _rv("newest", *TAGS_03, "refs/tags/studio-v0.3.0").stdout.strip() == "0.3.0"
    assert _rv("newest").stdout == "\n"


def test_bump_version_edits_both_files(tmp_path):
    import shutil
    import subprocess
    root = tmp_path / "tree"
    (root / "studio" / "hugmesh_studio").mkdir(parents=True)
    (root / "studio" / "packaging" / "flatpak").mkdir(parents=True)
    shutil.copy(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), root / "studio" / "hugmesh_studio")
    shutil.copy(METAINFO, root / "studio" / "packaging" / "flatpak")
    before = ET.parse(METAINFO).getroot().find("releases").findall("release")
    # Targets are derived from the tree, never spelt: the cut's preflight runs this
    # test AFTER bumping the working tree, so a literal target is already present
    # there from the second cut on (0.3.0-beta.2 in the metainfo once beta.3 is cut).
    target = _rv("next", "--root", str(root)).stdout.strip()
    final = _rv("next", target, "--final").stdout.strip() if "-" in target else _rv("next", target).stdout.strip()
    assert f'<release version="{target.replace("-", "~")}"' not in _read(METAINFO), target
    assert f'<release version="{final.replace("-", "~")}"' not in _read(METAINFO), final
    proc = _rv("bump", target, "--root", str(root), "--date", "2026-10-28")
    assert proc.returncode == 0, proc.stderr
    assert _rv("current", "--root", str(root)).stdout.strip() == target
    meta = root / "studio" / "packaging" / "flatpak" / "org.hugmesh.ImageStudio.metainfo.xml"
    releases = ET.parse(meta).getroot().find("releases").findall("release")
    assert releases[0].get("version") == target.replace("-", "~") and releases[0].get("type") == "development"
    assert releases[0].get("date") == "2026-10-28"
    assert [r.get("version") for r in releases[1:]] == [r.get("version") for r in before], "an old entry was lost"
    text = meta.read_text()
    assert "AppStream spells a pre-release with" in text, "the explanatory comment was lost"
    assert "<p>First beta.</p>" in text
    # Idempotent: a second bump to the same version changes nothing.
    snapshot = {p.name: p.read_bytes() for p in (meta, root / "studio" / "hugmesh_studio" / "__init__.py")}
    proc = _rv("bump", target, "--root", str(root), "--date", "2026-11-01")
    assert proc.returncode == 0 and "nothing changed" in proc.stdout
    assert {p.name: p.read_bytes() for p in (meta, root / "studio" / "hugmesh_studio" / "__init__.py")} == snapshot
    # A bump BACKWARDS is refused and changes nothing (the files would disagree).
    proc = _rv("bump", _version(), "--root", str(root), "--date", "2026-11-02")
    assert proc.returncode == 1 and "never goes backwards" in proc.stderr
    assert {p.name: p.read_bytes() for p in (meta, root / "studio" / "hugmesh_studio" / "__init__.py")} == snapshot
    # A final release gets no type="development"; a later beta.1 gets it back.
    proc = _rv("bump", final, "--root", str(root), "--date", "2026-12-01")
    assert proc.returncode == 0, proc.stderr
    newest = ET.parse(meta).getroot().find("releases").find("release")
    assert newest.get("version") == final.replace("-", "~")
    assert (newest.get("type") == "development") == ("-" in final)
    assert _rv("bump", "0.3.0-rc.1", "--root", str(root)).returncode == 1



# ── no test may lock the version line ─────────────────────────────────────────────
CUT_WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release-cut.yml")
# MAJOR.MINOR, optionally followed by more of a version (".", "-beta.N", end). A regex
# spelling ("0\.3\.") counts too: backslashes are dropped before matching.
VERSION_LINE_LITERAL = re.compile(r"v?\d+\.\d+(?:[.\-~]|$)")


def _reads_version(node: ast.AST, tainted: set[str]) -> bool:
    """True when the expression reads the running version: ``_version()``, any
    ``__version__``, or a local name assigned from one of those."""
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name) and sub.func.id == "_version":
            return True
        if isinstance(sub, ast.Attribute) and sub.attr == "__version__":
            return True
        if isinstance(sub, ast.Name) and (sub.id == "__version__" or sub.id in tainted):
            return True
    return False


def _has_version_literal(node: ast.AST) -> bool:
    return any(isinstance(sub, ast.Constant) and isinstance(sub.value, str)
               and VERSION_LINE_LITERAL.match(sub.value.replace("\\", ""))
               for sub in ast.walk(node))


def _version_line_locks(source: str, filename: str = "<test>") -> list[str]:
    """Every place a test compares the RUNNING version with a spelt MAJOR.MINOR.

    Fixtures that spell versions for pure functions (the MSI mapper, the CLI's
    validate/compare) are fine: they hold at any ``__version__``. What is not fine is
    ``_version()`` (or ``__version__``, or a name holding it) on one side and a literal
    like ``"0.3."`` on the other, because that fails the cut the day MINOR moves.
    """
    hits = []
    for func in ast.walk(ast.parse(source, filename)):
        if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        tainted: set[str] = set()
        while True:  # names assigned from the version, to a fixpoint
            grown = {t.id for n in ast.walk(func)
                     if isinstance(n, (ast.Assign, ast.AnnAssign)) and n.value is not None
                     and _reads_version(n.value, tainted)
                     for t in (n.targets if isinstance(n, ast.Assign) else [n.target])
                     for t in ast.walk(t) if isinstance(t, ast.Name)} | tainted
            if grown == tainted:
                break
            tainted = grown
        for node in ast.walk(func):
            if isinstance(node, ast.Compare):
                sides = [node.left, *node.comparators]
            elif isinstance(node, ast.Call):
                # x.startswith("0.3."), re.match(r"0\.3", x), x.find("0.4"), ...
                sides = [*([node.func.value] if isinstance(node.func, ast.Attribute) else []),
                         *node.args, *(k.value for k in node.keywords)]
            else:
                continue
            if any(_reads_version(a, tainted) and any(_has_version_literal(b)
                                                      for b in sides if b is not a)
                   for a in sides):
                hits.append(f"{filename}:{node.lineno} in {func.name}(): {ast.unparse(node)}")
    return hits


@pytest.mark.parametrize("lock", [
    'assert _version().startswith("0.3."), _version()',
    'assert _version() == "0.4.1-beta.1"',
    'assert "0.4" in _version()',
    'assert _version()[:3] == "0.4"',
    'assert _version().split("-")[0] != "1.0.0"',
    'assert re.match(r"0\\.4\\.", _version())',
    'assert hugmesh_studio.__version__.startswith(("0.3.", "0.4."))',
    'v = _version()\n    base = v.split("-")[0]\n    assert base == "0.4.1"',
])
def test_the_lock_detector_sees_a_lock(lock):
    # The detector itself is mutation-tested here: if it stops seeing these, the guard
    # below passes on everything and protects nothing.
    assert _version_line_locks(f"def test_x():\n    {lock}\n"), lock


@pytest.mark.parametrize("fine", [
    'assert BETA_VERSION.fullmatch(_version())',
    'assert _mapper().msi_version("0.3.0-beta.1") == "0.3.1"',
    'assert _rv("current").stdout.strip() == _version()',
    'assert newest.get("version") == _version().replace("-", "~", 1)',
    'base = _version().split("-")[0]\n    assert _rv("next").stdout.strip() == f"{base}-beta.2"',
    'proc = _rv("bump", _version(), "--root", "r", "--date", "2026-11-02")',
])
def test_the_lock_detector_passes_version_free_assertions(fine):
    assert not _version_line_locks(f"def test_x():\n    {fine}\n"), fine


def test_no_test_locks_the_version_line():
    """No Studio test may compare the running version with a spelt MAJOR.MINOR.

    The cut runs these files AFTER bumping the tree, so such a test refuses every cut of
    a new minor (it did: runs 42179167289 .. 42186743391). Not caught: a lock spelt
    without a ``N.N`` string, e.g. ``_version().split(".")[:2] == ["0", "3"]``.
    """
    cut_files = set(re.findall(r"studio/tests/[\w/]+\.py",
                               "\n".join(l for l in _read(CUT_WORKFLOW).splitlines() if "pytest" in l)))
    # The cut's guard step runs exactly these two files; this test lives in one of them so
    # the lock check runs where a lock does its damage.
    assert {"studio/tests/test_studio_beta_version.py",
            "studio/tests/test_studio_release_signing.py"} <= cut_files, cut_files
    files = sorted(set(glob.glob(os.path.join(STUDIO_ROOT, "tests", "**", "*.py"), recursive=True))
                   | {os.path.join(GENERATOR_DIR, f) for f in cut_files})
    assert len(files) > 10, files
    hits = [h for path in files
            for h in _version_line_locks(_read(path), os.path.relpath(path, GENERATOR_DIR))]
    assert not hits, (
        "these tests pin the Studio to one MAJOR.MINOR line and will refuse the next minor "
        "cut; derive the version from __version__ / release_version.py instead:\n"
        + "\n".join(hits))
