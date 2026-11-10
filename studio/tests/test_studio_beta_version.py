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
* The AppStream metadata's newest ``<release>`` is the same version, spelt with ``~``,
  and every older entry sorts strictly below it.

NO RELEASE LINE IS SPELT HERE. ``.github/workflows/studio-release-cut.yml`` runs this
file AFTER ``release_version.py bump`` has rewritten the tree, so a test that names one
MAJOR.MINOR fails every cut that leaves it. On 2026-11-06 ``test_version_is_the_0_3_beta_line``
did exactly that, a hand edit then made one MSI expectation wrong, and the file was cut
from 21 tests to 1 to get 0.4.1-beta.1 out. Every fixture below is built from the line
``__version__`` is on (``_line()``) and the two lines after it, and every MSI
expectation is either spelt from that line by template or computed by ``_expected_msi``,
which restates the rule from msi_version.py's docstring rather than calling it.
``test_guards_hold_after_a_bump`` proves it: it bumps a copy of the tree to the next
MINOR and the next MAJOR with the real ``release_version.py bump`` and runs the cut's
own guard files there.
"""
from __future__ import annotations

import importlib.util
import os
import re
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


def _release_version():
    spec = importlib.util.spec_from_file_location("release_version", RELEASE_VERSION)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _parts(version: str) -> tuple[int, int, int, int | None]:
    """(MAJOR, MINOR, PATCH, N or None for a final), parsed here, not by the code under test."""
    match = BETA_VERSION.fullmatch(version)
    assert match, version
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    return major, minor, patch, int(match.group(4)) if match.group(4) else None


def _line() -> str:
    """The MAJOR.MINOR line __version__ is on. Every fixture is built from this."""
    major, minor = _parts(_version())[:2]
    return f"{major}.{minor}"


def _lines() -> list[str]:
    """This line, the next MINOR and the next MAJOR: what a cut can move to."""
    major, minor = _parts(_version())[:2]
    return [f"{major}.{minor}", f"{major}.{minor + 1}", f"{major + 1}.0"]


def _expected_msi(version: str) -> str:
    """The rule from msi_version.py's docstring, restated so the mapper never supplies its
    own expected value: ``build = PATCH * 100 + N`` for ``-beta.N``, ``PATCH * 100 + 99``
    for the final release; MAJOR and MINOR pass through."""
    major, minor, patch, beta = _parts(version)
    return f"{major}.{minor}.{patch * 100 + (99 if beta is None else beta)}"


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


def test_version_heads_the_release_history():
    """Replaces ``test_version_is_the_0_3_beta_line``, which named one MINOR and so refused
    every cut that moved it. What that lock was for (MAJOR/MINOR never moves by accident,
    never backwards) is checked against the tree's own history instead: the metainfo's
    entries, newest first, are strictly descending under release_version.py's ordering
    key, and the newest is __version__. A hand edit of __init__.py alone, a bump
    backwards, or an old entry put back on top (the never-published 1.0.0 once was) all
    break the order."""
    rv = _release_version()
    releases = ET.parse(METAINFO).getroot().find("releases").findall("release")
    history = [r.get("version").replace("~", "-", 1) for r in releases]
    assert history and history[0] == _version(), (history[:3], _version())
    keys = [rv.parse(v) for v in history]
    for newer, older, k_new, k_old in zip(history, history[1:], keys, keys[1:]):
        assert k_new > k_old, f"metainfo lists {newer} above {older}, which does not sort below it"


def test_python_metadata_normalises_the_beta_to_pep440():
    packaging_version = pytest.importorskip("packaging.version")
    version = packaging_version.Version(_version())
    assert version.is_prerelease == ("-" in _version())
    if "-" in _version():
        base, beta = _version().split("-beta.", 1)
        assert str(version) == f"{base}b{beta}"
        assert version < packaging_version.Version(base), "the beta must sort below its final"


# ── the MSI ProductVersion mapping ─────────────────────────────────────────────────
def test_mapper_documents_the_rule_this_file_restates():
    """``_expected_msi`` restates msi_version.py's rule. If the rule in its docstring
    changes, this fails first, so the restatement cannot quietly go stale."""
    doc = _mapper().__doc__
    assert "build = PATCH * 100 + N" in doc and "PATCH * 100 + 99" in doc, doc
    assert _mapper().FINAL_SLOT == 99


def test_mapper_docstring_examples_follow_the_rule():
    """The docstring's worked examples are part of the contract (an operator reads them
    to predict an MSI's ProductVersion). Each must follow the rule and match the code; a
    hand-edited example that disagrees with either is red here."""
    examples = re.findall(r"msi_version\.py (\S+)\s+->\s+(\S+)", _mapper().__doc__)
    assert len(examples) >= 4, examples
    for semver, msi in examples:
        assert _expected_msi(semver) == msi, (semver, msi)
        assert _mapper().msi_version(semver) == msi, (semver, msi)


def _templated_mapping() -> list[tuple[str, str]]:
    """Expectations SPELT from each line by template, independent of _expected_msi's
    arithmetic: X.Y.0-beta.N -> X.Y.N, the final X.Y.0 -> X.Y.99, X.Y.1-beta.1 -> X.Y.101."""
    cases = []
    for line in _lines():
        cases += [
            (f"{line}.0-beta.1", f"{line}.1"),
            (f"{line}.0-beta.2", f"{line}.2"),
            (f"{line}.0-beta.10", f"{line}.10"),
            (f"{line}.0-beta.98", f"{line}.98"),
            (f"{line}.0", f"{line}.99"),
            (f"{line}.1-beta.1", f"{line}.101"),
            (f"{line}.1", f"{line}.199"),
        ]
    # The largest version an MSI can carry (255.255 and build 65499 <= 65535).
    cases.append(("255.255.654", "255.255.65499"))
    return cases


@pytest.mark.parametrize("semver,msi", _templated_mapping())
def test_msi_version_mapping(semver, msi):
    assert _expected_msi(semver) == msi, "the restated rule disagrees with its own template"
    assert _mapper().msi_version(semver) == msi


def _refused() -> list[str]:
    line = _line()
    major, minor = _parts(_version())[:2]
    return [f"{line}.0-SNAPSHOT", f"{line}.0-rc.1", f"{line}.0-beta.0", f"{line}.0-beta.99",
            f"{line}.0-beta", f"{line}.0+build.1", line, f"256.{minor}.0", f"{major}.256.0",
            f"{line}.655", f"v{line}.0"]


@pytest.mark.parametrize("bad", _refused())
def test_msi_version_refuses_what_it_cannot_order(bad):
    with pytest.raises(ValueError):
        _mapper().msi_version(bad)


def _ordered() -> list[str]:
    """Versions in release order across this line and the two a cut can move to."""
    order = []
    for line in _lines():
        order += [f"{line}.0-beta.1", f"{line}.0-beta.2", f"{line}.0-beta.9", f"{line}.0-beta.10",
                  f"{line}.0-beta.98", f"{line}.0", f"{line}.1-beta.1", f"{line}.1"]
    return order


def test_msi_versions_only_ever_go_up():
    """Windows Installer compares the three fields numerically; a later SemVer must give a
    strictly larger triple, or the newer MSI refuses to replace the older one."""
    order = _ordered()
    msi = [tuple(int(x) for x in _mapper().msi_version(v).split(".")) for v in order]
    assert msi == sorted(msi) and len(set(msi)) == len(msi), list(zip(order, msi))


def test_msi_order_agrees_with_the_release_order():
    """__version__ itself sits in that order: sorted by release_version.py's key, the MSI
    triples come out strictly increasing too, so the version being cut upgrades the one
    before it on Windows."""
    rv = _release_version()
    versions = sorted(set(_ordered() + [_version()]), key=rv.parse)
    msi = [tuple(int(x) for x in _mapper().msi_version(v).split(".")) for v in versions]
    assert all(a < b for a, b in zip(msi, msi[1:])), list(zip(versions, msi))


def test_current_version_maps():
    assert _mapper().msi_version(_version()) == _expected_msi(_version())


def test_mapper_cli(capsys):
    mod = _mapper()
    line = _line()
    assert mod.main([f"{line}.0-beta.1"]) == 0 and capsys.readouterr().out == f"{line}.1\n"
    assert mod.main([_version()]) == 0 and capsys.readouterr().out == _expected_msi(_version()) + "\n"
    assert mod.main([f"{line}.0-SNAPSHOT"]) == 1
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
    (f"refs/tags/studio-v{_version()}", "push", "", "WILL publish (tag ref; push event)"),
    (f"refs/tags/studio-v{_version()}", "workflow_dispatch", "true", "WILL publish (tag ref; workflow_dispatch event, publish=true)"),
    (f"refs/tags/studio-v{_version()}", "workflow_dispatch", "false", "WILL NOT publish (tag ref, but publish was not ticked)"),
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
    assert (newest.get("type") == "development") == ("-" in _version()), newest.attrib
    # The never-published 1.0.0 entry once came back on top, so software centres showed
    # 1.0.0. That used to be a literal "!= 1.0.0", which would refuse the real 1.0.0 cut;
    # the version-free form: no entry is NEWER than __version__.
    rv = _release_version()
    for release in releases.findall("release"):
        version = release.get("version").replace("~", "-", 1)
        assert rv.compare(version, _version()) <= 0, (
            f"the metainfo lists {version}, which is newer than __version__ {_version()}")


TAG = f"studio-v{_version()}"
EXISTS = '{"tagName":"%s","assets":[{"updatedAt":"2026-10-23T07:35:52Z"},{"updatedAt":"2026-10-22T10:28:46Z"}]}' % TAG


@pytest.mark.parametrize("gh_rc,gh_out,republish,want_rc,want_output,want_text", [
    # the release exists and nobody asked to replace it: RED, names the way to do so
    (0, EXISTS, "false", 1, "", "--republish"),
    (0, EXISTS, "", 1, "", "--republish"),                       # a push event: no inputs at all
    # the release exists and republish was asked for: go on, loudly
    (0, EXISTS, "true", 0, "replaced=true\n", f"::warning::REPUBLISHING {TAG}: 2 files will be replaced (newest currently from 2026-10-23T07:35:52Z)"),
    (0, '{"tagName":"%s"}' % TAG, "true", 0, "replaced=true\n", "::warning::REPUBLISHING"),
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
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "VERSION": _version(), "REPUBLISH": republish,
           "GITHUB_REPOSITORY": "hugmesh/hugmesh-generator", "GITHUB_OUTPUT": str(out_file)}
    # GitHub runs a `run:` block as `bash -e {0}`.
    proc = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True)
    assert proc.returncode == want_rc, (proc.stdout, proc.stderr)
    assert out_file.read_text() == want_output
    assert want_text in proc.stdout + proc.stderr, (proc.stdout, proc.stderr)
    if want_rc == 1:
        assert "::error::" in proc.stdout


@pytest.mark.parametrize("version", [_version(), f"{_line()}.0-beta.2", f"{_line()}.0"])
@pytest.mark.parametrize("replaced", ["true", "false", ""])
def test_release_notes_say_when_files_were_replaced(tmp_path, replaced, version):
    import subprocess
    steps = _workflow()["jobs"]["publish"]["steps"]
    script = next(s for s in steps if s.get("name") == "Write the release notes")["run"]
    env = {"PATH": "/usr/bin:/bin", "VERSION": version, "GITHUB_REPOSITORY": "hugmesh/hugmesh-generator",
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
    # A beta says so in the first line; a final release does not.
    stage = " (beta, pre-release)" if "-" in version else ""
    assert notes.startswith(f"HugMesh Image Studio {version}{stage}.\n"), notes.splitlines()[0]
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
    line = _line()
    assert _rv("next", f"{line}.0").stdout.strip() == f"{line}.1-beta.1"
    assert _rv("validate", f"{line}.0-beta.2").returncode == 0
    for bad in (f"{line}.0-rc.1", f"{line}.0-SNAPSHOT", f"{line}.0+build.1", f"{line}.0-beta.0",
                f"{line}.0-beta.99", f"v{line}.0"):
        assert _rv("validate", bad).returncode == 1, bad
    tags = [f"refs/tags/studio-v{line}.0-beta.1", "refs/tags/studio-vgarbage"]
    assert _rv("validate", f"{line}.0-beta.1", "--after-tags", *tags).returncode == 1
    assert _rv("validate", f"{line}.0-beta.2", "--after-tags", *tags).returncode == 0
    assert _rv("validate", f"{line}.0", "--after-tags", *tags).returncode == 0
    # Re-cutting the version that is already tagged is refused.
    assert _rv("validate", _version(), "--after-tags", f"refs/tags/studio-v{_version()}").returncode == 1
    major, minor = _parts(_version())[:2]
    earlier = f"{major}.{minor - 1}.9" if minor else (f"{major - 1}.9.9" if major else None)
    if earlier is not None:
        assert _rv("validate", earlier, "--after-tags", *tags).returncode == 1, earlier
    assert _rv("validate", f"{line}.0-beta.2", "--after-tags").returncode == 0, "no tags yet: anything valid goes"
    order = [v for v in _ordered() if not v.endswith(("-beta.9", "-beta.98"))]
    for a, b in zip(order, order[1:]):
        assert _rv("compare", a, b).stdout.strip() == "lt", (a, b)
        assert _rv("compare", b, a).stdout.strip() == "gt", (a, b)
    assert _rv("compare", f"{line}.0", f"{line}.0").stdout.strip() == "eq"


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
    assert _rv("bump", f"{_line()}.0-rc.1", "--root", str(root)).returncode == 1


# ── the proof that nothing above names a release line ─────────────────────────────
# The files "Cut a Studio release" runs in its preflight, after the bump.
_CUT_GUARDS = ("test_studio_beta_version.py", "test_studio_release_signing.py")
_SIMULATING = "HUGMESH_STUDIO_GUARD_SIMULATION"


def _bump_targets() -> list[str]:
    major, minor = _parts(_version())[:2]
    return [f"{major}.{minor + 1}.0-beta.1", f"{major + 1}.0.0-beta.1", f"{major + 1}.0.0"]


def test_the_cut_runs_these_guard_files():
    """The simulation below runs _CUT_GUARDS; if the cut's preflight stops running one of
    them, or starts running another, the simulation is proving the wrong set."""
    cut = yaml.safe_load(_read(os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release-cut.yml")))
    steps = [s for s in cut["jobs"]["preflight"]["steps"]
             if s.get("name") == "Run the release guard tests against the tree that will execute"]
    assert len(steps) == 1, [s.get("name") for s in cut["jobs"]["preflight"]["steps"]]
    ran = set(re.findall(r"studio/tests/(test_\w+\.py)", steps[0]["run"]))
    assert ran == set(_CUT_GUARDS), sorted(ran)


@pytest.mark.skipif(os.environ.get(_SIMULATING) == "1", reason="already inside a simulated bump")
@pytest.mark.parametrize("target", _bump_targets())
def test_guards_hold_after_a_bump(tmp_path, target):
    """Copy what the guards read, bump the copy to the next MINOR, the next MAJOR and that
    MAJOR's final with the real ``release_version.py bump`` (the cut's own step), then run
    the cut's guard files inside the copy. Any test that spells this release line fails
    here, before a cut does."""
    root = tmp_path / "tree"
    shutil.copytree(os.path.join(GENERATOR_DIR, ".github", "workflows"), root / ".github" / "workflows")
    shutil.copytree(os.path.join(STUDIO_ROOT, "packaging"), root / "studio" / "packaging")
    # The whole package: the suite's conftest imports hugmesh_studio.core.
    shutil.copytree(os.path.join(STUDIO_ROOT, "hugmesh_studio"), root / "studio" / "hugmesh_studio",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy(os.path.join(STUDIO_ROOT, "pytest.ini"), root / "studio")  # the suite's markers
    (root / "studio" / "tests").mkdir()
    for name in ("conftest.py",) + _CUT_GUARDS:
        shutil.copy(os.path.join(STUDIO_ROOT, "tests", name), root / "studio" / "tests")
    bump = subprocess.run([sys.executable, str(root / "studio" / "packaging" / "release_version.py"),
                           "bump", target, "--root", str(root), "--date", "2026-12-24"],
                          capture_output=True, text=True)
    assert bump.returncode == 0, bump.stderr
    env = dict(os.environ, **{_SIMULATING: "1"})
    proc = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-rs",
                           *(f"studio/tests/{name}" for name in _CUT_GUARDS)],
                          cwd=root, env=env, capture_output=True, text=True, timeout=600)
    tail = "\n".join(proc.stdout.splitlines()[-40:])
    assert proc.returncode == 0, f"the guards fail after a bump to {target}:\n{tail}\n{proc.stderr[-2000:]}"
    assert " passed" in tail and " failed" not in tail, tail
