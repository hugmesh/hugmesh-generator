"""The "Cut a Studio release" workflow: one button (or scripts/release-studio.sh) that
bumps __version__ on main, creates the studio-v<version> tag on GitHub and dispatches
studio-release.yml on that tag.

What this pins, and why:

* dispatch-only, exactly four inputs (version, republish, confirm, dry_run), and the
  republish input states its consequence where the operator ticks it;
* the file is contents: read; only the `cut` job writes (contents + actions), and no
  job here can sign (no id-token, no attestations);
* every action is pinned to a commit SHA, nothing reads RUNS_ON;
* the dispatch runs studio-release.yml ON the tag ref with publish=true, passing only
  inputs that workflow declares (GitHub rejects unknown inputs at dispatch time);
* the `run:` blocks are EXECUTED with a fake gh/git against a tmp tree: tag absent /
  present / annotated / elsewhere, release present with and without republish,
  republish without confirm, the b7edc89c trap (a tag whose workflow file predates
  the republish input), a 502 (never guessed), a refused push, main moved.
"""
from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import sys

import pytest
import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOWS = os.path.join(GENERATOR_DIR, ".github", "workflows")
CUT = os.path.join(WORKFLOWS, "studio-release-cut.yml")
RELEASE = os.path.join(WORKFLOWS, "studio-release.yml")
REPO = "hugmesh/hugmesh-generator"
OLD_SHA = "1111111111111111111111111111111111111111"
NEW_SHA = "2222222222222222222222222222222222222222"
TAGOBJ_SHA = "3333333333333333333333333333333333333333"
B7 = "b7edc89cdb61fe5f1d14fcb1a6dfbbab85b78571"  # the live studio-v0.3.0-beta.1 commit


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _doc(path: str) -> dict:
    doc = yaml.safe_load(_read(path))
    doc["on"] = doc.pop(True, doc.get("on"))  # PyYAML reads the bare key `on` as True
    return doc


def _cut() -> dict:
    return _doc(CUT)


def _step(job: str, name: str) -> dict:
    hits = [s for s in _cut()["jobs"][job]["steps"] if s.get("name") == name]
    assert len(hits) == 1, (job, name, len(hits))
    return hits[0]


# ── static contract ────────────────────────────────────────────────────────────────
def test_dispatch_only_with_exactly_the_four_inputs():
    on = _cut()["on"]
    assert list(on) == ["workflow_dispatch"], on
    inputs = on["workflow_dispatch"]["inputs"]
    assert sorted(inputs) == ["confirm", "dry_run", "republish", "version"]
    assert inputs["version"]["required"] is True and inputs["version"]["type"] == "string"
    assert inputs["republish"]["type"] == "boolean" and inputs["republish"]["default"] is False
    assert inputs["dry_run"]["type"] == "boolean" and inputs["dry_run"]["default"] is False
    assert inputs["confirm"]["type"] == "string" and inputs["confirm"]["default"] == ""
    assert "can no longer verify" in inputs["republish"]["description"]
    assert "Requires confirm" in inputs["republish"]["description"]
    assert "Type the version again" in inputs["confirm"]["description"]
    assert "create and change nothing" in inputs["dry_run"]["description"]


def test_permissions_only_the_cut_job_writes_and_nothing_signs():
    doc = _cut()
    assert doc["permissions"] == {"contents": "read"}
    jobs = doc["jobs"]
    assert set(jobs) == {"preflight", "cut"}
    assert "permissions" not in jobs["preflight"]
    assert jobs["cut"]["permissions"] == {"contents": "write", "actions": "write"}
    assert jobs["cut"]["needs"] == "preflight"
    assert jobs["cut"]["if"] == "${{ !inputs.dry_run }}"
    code = re.sub(r"(?m)#.*$", "", _read(CUT))  # the header comment names what is absent
    assert "id-token" not in code and "attestations" not in code
    assert not re.search(r"vars\.RUNS_ON", code)
    for job in jobs.values():
        assert job["runs-on"] == "ubuntu-latest"
        assert job["timeout-minutes"] <= 15
    assert doc["concurrency"] == {"group": "studio-release-cut", "cancel-in-progress": False}


def test_every_action_is_pinned_to_a_commit_with_its_tag_as_a_comment():
    uses = re.findall(r"(?m)^\s*(?:-\s+)?uses:\s*(\S+)(.*)$", _read(CUT))
    assert len(uses) >= 3, uses
    for ref, rest in uses:
        action, _, sha = ref.partition("@")
        assert re.fullmatch(r"[0-9a-f]{40}", sha), f"{ref} is not pinned to a commit SHA"
        assert re.fullmatch(r"\s+#\s+v\d+(\.\d+)*\s*", rest), f"{action}: no '# vX.Y.Z' comment: {rest!r}"
    # The actionlint image is pinned by digest, not by a floating tag.
    assert re.search(r"rhysd/actionlint@sha256:[0-9a-f]{64}", _read(CUT))
    assert "rhysd/actionlint:" not in _read(CUT).replace("rhysd/actionlint:1.7.7 as resolved", "")


def test_dispatch_runs_the_release_workflow_on_the_tag_with_declared_inputs_only():
    run = _step("cut", "Dispatch the signed build and publish on the tag")["run"]
    assert "gh workflow run studio-release.yml" in run
    assert "--ref refs/tags/studio-v" in run
    assert "-f publish=true" in run and "-f republish=" in run
    passed = set(re.findall(r"-f (\w+)=", run))
    declared = set(_doc(RELEASE)["on"]["workflow_dispatch"]["inputs"])
    assert passed <= declared, f"the cut passes inputs studio-release.yml does not declare: {passed - declared}"
    assert passed == {"publish", "republish"}
    assert _step("cut", "Dispatch the signed build and publish on the tag")["env"]["GH_TOKEN"] == "${{ github.token }}"
    assert "Release run:" in run and "GITHUB_STEP_SUMMARY" in run


def test_preflight_runs_the_guard_tests_and_actionlint_against_the_tree_that_executes():
    names = [s.get("name") for s in _cut()["jobs"]["preflight"]["steps"]]
    tests = _step("preflight", "Run the release guard tests against the tree that will execute")["run"]
    assert "studio/tests/test_studio_beta_version.py" in tests
    assert "studio/tests/test_studio_release_signing.py" in tests
    lint = _step("preflight", "actionlint the release workflow that will execute, and this one")["run"]
    assert ".github/workflows/studio-release.yml" in lint and ".github/workflows/studio-release-cut.yml" in lint
    bump = _step("preflight", "Apply the bump to the working tree (not committed here)")
    assert bump["if"] == "${{ !inputs.republish && steps.main.outputs.bump_needed == 'true' }}"
    assert names.index("Apply the bump to the working tree (not committed here)") < names.index(
        "Run the release guard tests against the tree that will execute")
    tag_checkout = _step("preflight", "Check out the tag that will be rebuilt")
    assert tag_checkout["if"] == "${{ inputs.republish }}"
    assert names.index("Check out the tag that will be rebuilt") < names.index(
        "Run the release guard tests against the tree that will execute")
    checkout = next(s for s in _cut()["jobs"]["preflight"]["steps"] if s.get("uses", "").startswith("actions/checkout@"))
    assert checkout["with"]["persist-credentials"] is False and checkout["with"]["ref"] == "main"
    for name in ("Read main and decide the bump",):
        assert _step("preflight", name)["if"] == "${{ !inputs.republish }}"


def test_cut_job_mutates_nothing_on_a_republish():
    for name in ("main must not have moved since the preflight", "Bump __version__ on main",
                 "Create (or keep, or move) the tag on GitHub"):
        assert _step("cut", name)["if"] == "${{ !inputs.republish }}", name
    checkout = next(s for s in _cut()["jobs"]["cut"]["steps"] if s.get("uses", "").startswith("actions/checkout@"))
    assert checkout["if"] == "${{ !inputs.republish }}"
    assert checkout["with"]["persist-credentials"] is True, "the bump push needs the token"
    bump = _step("cut", "Bump __version__ on main")["run"]
    assert "git push origin HEAD:main" in bump and "Open a PR" in bump and "run again" in bump
    assert "Co-Authored-By" not in bump
    tag = _step("cut", "Create (or keep, or move) the tag on GitHub")["run"]
    assert "git tag" not in tag, "the tag is created through the API, never by a local git"
    assert "-X DELETE" not in _read(CUT), "the cut never deletes anything"


# ── executing the run: blocks with a fake gh and git ──────────────────────────────
FAKE_GH = r'''#!/bin/bash
# Fake gh for the cut workflow tests. Every call is logged; answers come from env.
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view")
    case "$FAKE_RELEASE" in
      present) printf '%s\n' '{"tagName":"studio-vX","assets":[{"updatedAt":"2026-10-23T07:35:52Z"},{"updatedAt":"2026-10-22T10:28:46Z"}]}'; exit 0 ;;
      absent) echo "release not found" >&2; exit 1 ;;
      *) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    esac ;;
  "api -X")
    case "$*" in
      *git/tags*) [ "$FAKE_API_RC" = "0" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; echo "$FAKE_TAGOBJ"; exit 0 ;;
      *) [ "$FAKE_API_RC" = "0" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; echo "refs/tags/x"; exit 0 ;;
    esac ;;
  "api repos/$GITHUB_REPOSITORY/git/matching-refs/tags/studio-v")
    [ "$FAKE_RELEASE" = "502" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    printf '%s\n' $FAKE_ALL_TAGS; exit 0 ;;
  "api repos/$GITHUB_REPOSITORY/git/matching-refs/tags/studio-v"*)
    [ "$FAKE_RELEASE" = "502" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    [ -n "$FAKE_TAG" ] && printf '%s\n' "$FAKE_TAG"; exit 0 ;;
  "api repos/$GITHUB_REPOSITORY/git/tags/"*)
    echo "$FAKE_TAG_DEREF"; exit 0 ;;
  "run list")
    case "$*" in
      *--event\ workflow_dispatch*) echo "https://github.com/$GITHUB_REPOSITORY/actions/runs/777"; exit 0 ;;
      *) echo "${FAKE_BUSY:-0}"; exit 0 ;;
    esac ;;
  "workflow run") exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 99
'''

FAKE_GIT = r'''#!/bin/bash
printf '%s\n' "$*" >> "$GIT_LOG"
case "$*" in
  "rev-parse HEAD") cat "$GIT_HEAD_FILE"; exit 0 ;;
  "rev-parse origin/main") echo "$FAKE_ORIGIN_MAIN"; exit 0 ;;
  fetch*|checkout*|add*) exit 0 ;;
  *commit*) echo "$FAKE_NEW_SHA" > "$GIT_HEAD_FILE"; exit 0 ;;
  "push origin HEAD:main") [ "${FAKE_PUSH_RC:-0}" = "0" ] && exit 0; echo "! [rejected] main -> main (non-fast-forward)" >&2; exit "$FAKE_PUSH_RC" ;;
esac
echo "fake git: unexpected call: $*" >&2
exit 99
'''


def _tree(tmp_path, version="0.3.0-beta.1", workflow_text=None):
    """A tmp generator tree with the real release_version.py, a controlled __version__
    and a controlled .github/workflows/studio-release.yml."""
    root = tmp_path / "tree"
    (root / "studio" / "hugmesh_studio").mkdir(parents=True)
    (root / "studio" / "packaging" / "wix").mkdir(parents=True)
    (root / "studio" / "packaging" / "flatpak").mkdir(parents=True)
    (root / ".github" / "workflows").mkdir(parents=True)
    shutil.copy(os.path.join(STUDIO_ROOT, "packaging", "release_version.py"), root / "studio" / "packaging")
    shutil.copy(os.path.join(STUDIO_ROOT, "packaging", "wix", "msi_version.py"), root / "studio" / "packaging" / "wix")
    shutil.copy(os.path.join(STUDIO_ROOT, "packaging", "flatpak", "org.hugmesh.ImageStudio.metainfo.xml"),
                root / "studio" / "packaging" / "flatpak")
    init = _read(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"))
    init = re.sub(r'(?m)^__version__ = "[^"]+"$', f'__version__ = "{version}"', init)
    (root / "studio" / "hugmesh_studio" / "__init__.py").write_text(init)
    (root / ".github" / "workflows" / "studio-release.yml").write_text(workflow_text or _read(RELEASE))

    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in (("gh", FAKE_GH), ("git", FAKE_GIT), ("sleep", "#!/bin/sh\nexit 0\n")):
        path = bindir / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
    # The run: blocks call `python3`; the one running these tests has PyYAML.
    os.symlink(sys.executable, bindir / "python3")
    (tmp_path / "gh.log").write_text("")
    (tmp_path / "git.log").write_text("")
    (tmp_path / "head").write_text(OLD_SHA + "\n")
    return root


def _run(tmp_path, script: str, **env_over) -> tuple[subprocess.CompletedProcess, str, str, str]:
    out_file = tmp_path / "github_output"
    summary = tmp_path / "summary"
    out_file.write_text("")
    summary.write_text("")
    env = {
        "PATH": f"{tmp_path / 'bin'}:/usr/bin:/bin",
        "GITHUB_REPOSITORY": REPO, "GITHUB_OUTPUT": str(out_file), "GITHUB_STEP_SUMMARY": str(summary),
        "GITHUB_SERVER_URL": "https://github.com", "GITHUB_RUN_ID": "123",
        "GITHUB_ACTOR": "someone", "GITHUB_ACTOR_ID": "42",
        "GH_LOG": str(tmp_path / "gh.log"), "GIT_LOG": str(tmp_path / "git.log"),
        "GIT_HEAD_FILE": str(tmp_path / "head"), "FAKE_NEW_SHA": NEW_SHA, "FAKE_TAGOBJ": TAGOBJ_SHA,
        "FAKE_API_RC": "0", "FAKE_ORIGIN_MAIN": OLD_SHA,
        "VERSION": "0.3.0-beta.2", "REPUBLISH": "false", "CONFIRM": "", "DRY_RUN": "false",
        "FAKE_RELEASE": "absent", "FAKE_TAG": "", "FAKE_ALL_TAGS": "refs/tags/studio-v0.3.0-beta.1",
    }
    env.update({k: str(v) for k, v in env_over.items()})
    # GitHub runs a `run:` block as `bash -e {0}`.
    proc = subprocess.run(["bash", "-e", "-c", script], env=env, cwd=tmp_path / "tree",
                          capture_output=True, text=True)
    return proc, out_file.read_text(), (tmp_path / "gh.log").read_text(), (tmp_path / "git.log").read_text()


PROBE = "Look at what already exists (release, tag, runs in progress)"
DECIDE = "Read main and decide the bump"
KNOWS = "The workflow file at the tag must know republish"
MOVED = "main must not have moved since the preflight"
BUMP = "Bump __version__ on main"
TAG = "Create (or keep, or move) the tag on GitHub"
DISPATCH = "Dispatch the signed build and publish on the tag"


def _outputs(text: str) -> dict:
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


# -- preflight: probe --
def test_probe_normal_cut_with_nothing_there(tmp_path):
    _tree(tmp_path)
    proc, out, gh, _ = _run(tmp_path, _step("preflight", PROBE)["run"])
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert _outputs(out) == {"release_state": "absent", "tag_state": "absent", "tag_sha": ""}
    assert "matching-refs/tags/studio-v --jq" in gh, "the ordering check must look at every studio-v* tag"
    assert "-X POST" not in gh and "-X PATCH" not in gh and "workflow run" not in gh


@pytest.mark.parametrize("fake_tag,deref,want", [
    (f"commit {OLD_SHA}", "", f"present@{OLD_SHA}"),           # a lightweight tag (the live one)
    (f"tag {TAGOBJ_SHA}", NEW_SHA, f"present@{NEW_SHA}"),      # an annotated tag: dereferenced
])
def test_probe_reports_an_existing_tag_by_its_commit(tmp_path, fake_tag, deref, want):
    _tree(tmp_path)
    proc, out, gh, _ = _run(tmp_path, _step("preflight", PROBE)["run"], FAKE_TAG=fake_tag, FAKE_TAG_DEREF=deref)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert _outputs(out)["tag_state"] == want
    assert (f"git/tags/{TAGOBJ_SHA}" in gh) == fake_tag.startswith("tag ")


def test_probe_refuses_an_existing_release_without_republish(tmp_path):
    _tree(tmp_path)
    proc, out, gh, _ = _run(tmp_path, _step("preflight", PROBE)["run"], FAKE_RELEASE="present",
                            FAKE_TAG=f"commit {OLD_SHA}")
    assert proc.returncode == 1
    assert "already exists" in proc.stdout and "--republish" in proc.stdout
    assert out == ""


def test_probe_republish_needs_release_confirm_and_tag(tmp_path):
    _tree(tmp_path)
    ok = dict(REPUBLISH="true", CONFIRM="0.3.0-beta.2", FAKE_RELEASE="present", FAKE_TAG=f"commit {OLD_SHA}")
    proc, out, gh, _ = _run(tmp_path, _step("preflight", PROBE)["run"], **ok)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert "::warning::REPUBLISHING studio-v0.3.0-beta.2" in proc.stdout
    assert "2 assets" in proc.stdout and "2026-10-23T07:35:52Z" in proc.stdout
    assert _outputs(out)["release_state"].startswith("present(2 assets")
    assert "matching-refs/tags/studio-v --jq" not in gh, "a republish skips the ordering check"

    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], **{**ok, "CONFIRM": ""})
    assert proc.returncode == 1 and "type the version into confirm" in proc.stdout and out == ""
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], **{**ok, "CONFIRM": "0.3.0-beta.3"})
    assert proc.returncode == 1 and out == ""
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], **{**ok, "FAKE_RELEASE": "absent"})
    assert proc.returncode == 1 and "run a normal release" in proc.stdout and out == ""
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], **{**ok, "FAKE_TAG": ""})
    assert proc.returncode == 1 and "its tag does not" in proc.stdout and out == ""


@pytest.mark.parametrize("republish", ["false", "true"])
def test_probe_never_guesses_on_a_502(tmp_path, republish):
    _tree(tmp_path)
    proc, out, gh, _ = _run(tmp_path, _step("preflight", PROBE)["run"], FAKE_RELEASE="502",
                            REPUBLISH=republish, CONFIRM="0.3.0-beta.2")
    assert proc.returncode == 1 and "could not tell" in proc.stdout
    assert out == ""
    assert "-X POST" not in gh and "-X PATCH" not in gh and "workflow run" not in gh


def test_probe_refuses_while_a_release_run_is_in_progress(tmp_path):
    _tree(tmp_path)
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], FAKE_BUSY="1")
    assert proc.returncode == 1 and "run again" in proc.stdout and out == ""


def test_probe_refuses_a_version_that_does_not_sort_after_the_newest_tag(tmp_path):
    _tree(tmp_path)
    tags = "refs/tags/studio-v0.3.0-beta.1\nrefs/tags/studio-v0.3.0-beta.2"
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], VERSION="0.3.0-beta.1", FAKE_ALL_TAGS=tags)
    assert proc.returncode == 1 and "strictly after" in proc.stderr and out == ""
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], VERSION="0.3.0-beta.3", FAKE_ALL_TAGS=tags)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    # The re-run case: this version's own tag exists (a build died after tagging) and
    # no release does. Its own tag must not count against it.
    proc, out, _, _ = _run(tmp_path, _step("preflight", PROBE)["run"], VERSION="0.3.0-beta.2", FAKE_ALL_TAGS=tags,
                           FAKE_TAG=f"commit {OLD_SHA}")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert _outputs(out)["tag_state"] == f"present@{OLD_SHA}"


# -- preflight: decide the bump --
@pytest.mark.parametrize("tree_version,want_rc,want_bump", [
    ("0.3.0-beta.1", 0, "true"),    # main is behind: bump
    ("0.3.0-beta.2", 0, "false"),   # main already there: no bump (the re-run case)
    ("0.3.0-beta.3", 1, None),      # main is past it: refuse
])
def test_decide_the_bump(tmp_path, tree_version, want_rc, want_bump):
    _tree(tmp_path, version=tree_version)
    proc, out, _, _ = _run(tmp_path, _step("preflight", DECIDE)["run"], TAG_STATE="absent", TAG_SHA="")
    assert proc.returncode == want_rc, (proc.stdout, proc.stderr)
    if want_rc:
        assert "choose a later version" in proc.stdout and out == ""
    else:
        assert _outputs(out) == {"sha": OLD_SHA, "bump_needed": want_bump}


@pytest.mark.parametrize("tree_version,tag_sha,want_moved", [
    ("0.3.0-beta.2", OLD_SHA, False),   # tag at main's head, main already at the version: kept
    ("0.3.0-beta.2", NEW_SHA, True),    # tag elsewhere: moved (no release exists, by the probe)
    ("0.3.0-beta.1", OLD_SHA, True),    # tag at main's head but __version__ there differs: moved
])
def test_decide_reports_a_tag_that_will_move(tmp_path, tree_version, tag_sha, want_moved):
    _tree(tmp_path, version=tree_version)
    proc, _, _, _ = _run(tmp_path, _step("preflight", DECIDE)["run"], TAG_STATE=f"present@{tag_sha}", TAG_SHA=tag_sha)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert ("MOVED" in proc.stdout) == want_moved
    assert ("::warning::" in proc.stdout) == want_moved
    assert ("kept" in proc.stdout) == (not want_moved)


# -- preflight: the b7edc89c trap --
def _workflow_without_republish() -> str:
    """The workflow file at the live studio-v0.3.0-beta.1 tag (b7edc89c), which has
    only the `publish` input. From git when the history is there; otherwise the
    current file with its republish input cut out (a shallow CI checkout), never a
    skip: the check this fixture feeds is the one that keeps a bare publish=true
    dispatch off that tag."""
    proc = subprocess.run(["git", "show", f"{B7}:.github/workflows/studio-release.yml"],
                          cwd=GENERATOR_DIR, capture_output=True, text=True)
    if proc.returncode == 0:
        text = proc.stdout
    else:
        lines = _read(RELEASE).splitlines(keepends=True)
        start = next(i for i, l in enumerate(lines) if l.rstrip() == "      republish:")
        end = next(i for i in range(start + 1, len(lines)) if re.match(r"^ {2}\S", lines[i]) or lines[i].rstrip() == "      publish:")
        text = "".join(lines[:start] + lines[end:])
    assert "republish" not in yaml.safe_load(text)[True]["workflow_dispatch"]["inputs"]
    return text


def test_republish_refuses_a_tag_whose_workflow_predates_the_input(tmp_path):
    _tree(tmp_path, workflow_text=_workflow_without_republish())
    proc, _, gh, _ = _run(tmp_path, _step("preflight", KNOWS)["run"], REPUBLISH="true", CONFIRM="0.3.0-beta.1",
                          VERSION="0.3.0-beta.1")
    assert proc.returncode == 1, (proc.stdout, proc.stderr)
    assert "predates the republish input" in proc.stdout
    assert "workflow run" not in gh


def test_republish_accepts_a_tag_whose_workflow_knows_the_input(tmp_path):
    _tree(tmp_path)
    proc, _, _, _ = _run(tmp_path, _step("preflight", KNOWS)["run"], REPUBLISH="true", CONFIRM="0.3.0-beta.2")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)


# -- cut --
def test_cut_refuses_when_main_moved_after_the_preflight(tmp_path):
    _tree(tmp_path)
    proc, _, _, git = _run(tmp_path, _step("cut", MOVED)["run"], PREFLIGHT_SHA=OLD_SHA, FAKE_ORIGIN_MAIN=OLD_SHA)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert "fetch origin main" in git
    proc, _, _, _ = _run(tmp_path, _step("cut", MOVED)["run"], PREFLIGHT_SHA=OLD_SHA, FAKE_ORIGIN_MAIN=NEW_SHA)
    assert proc.returncode == 1 and "main moved" in proc.stdout and "run again" in proc.stdout


def test_cut_bumps_commits_and_pushes_only_when_needed(tmp_path):
    root = _tree(tmp_path)
    proc, out, _, git = _run(tmp_path, _step("cut", BUMP)["run"], BUMP_NEEDED="true")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert f'__version__ = "0.3.0-beta.2"' in (root / "studio" / "hugmesh_studio" / "__init__.py").read_text()
    assert '0.3.0~beta.2' in (root / "studio" / "packaging" / "flatpak" / "org.hugmesh.ImageStudio.metainfo.xml").read_text()
    assert "commit -q -m Studio 0.3.0-beta.2" in git and "push origin HEAD:main" in git
    assert "user.name=someone" in git and "user.email=42+someone@users.noreply.github.com" in git
    assert _outputs(out) == {"sha": NEW_SHA}
    (tmp_path / "git.log").write_text("")
    proc, out, _, git = _run(tmp_path, _step("cut", BUMP)["run"], BUMP_NEEDED="false")
    assert proc.returncode == 0 and "commit" not in git and "push" not in git
    assert _outputs(out) == {"sha": NEW_SHA}


def test_cut_push_refused_is_loud_and_final(tmp_path):
    _tree(tmp_path)
    proc, out, _, git = _run(tmp_path, _step("cut", BUMP)["run"], BUMP_NEEDED="true", FAKE_PUSH_RC="1")
    assert proc.returncode == 1
    assert "push to main refused" in proc.stdout and "non-fast-forward" in proc.stdout
    assert "Open a PR" in proc.stdout and "run again" in proc.stdout
    assert out == ""
    assert git.count("push origin HEAD:main") == 1, "no retry loop"


@pytest.mark.parametrize("tag_state,want_post,want_patch,want_text", [
    ("absent", True, False, "created tag studio-v0.3.0-beta.2"),
    (f"present@{NEW_SHA}", False, False, "kept"),
    (f"present@{OLD_SHA}", False, True, "moved tag studio-v0.3.0-beta.2"),
])
def test_cut_tag_create_keep_or_move(tmp_path, tag_state, want_post, want_patch, want_text):
    _tree(tmp_path)
    proc, _, gh, _ = _run(tmp_path, _step("cut", TAG)["run"], TAG_STATE=tag_state, TAG_SHA=OLD_SHA, SHA=NEW_SHA)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert want_text in proc.stdout
    calls = gh.splitlines()
    posts = [c for c in calls if c.startswith("api -X POST")]
    patches = [c for c in calls if c.startswith("api -X PATCH")]
    if want_post:
        assert len(posts) == 2 and "git/tags" in posts[0] and "git/refs" in posts[1], calls
        assert f"object={NEW_SHA}" in posts[0] and "type=commit" in posts[0]
        assert f"sha={TAGOBJ_SHA}" in posts[1] and "ref=refs/tags/studio-v0.3.0-beta.2" in posts[1]
    else:
        assert not posts, calls
    if want_patch:
        assert len(patches) == 1 and "git/refs/tags/studio-v0.3.0-beta.2" in patches[0] and "force=true" in patches[0]
        assert f"sha={NEW_SHA}" in patches[0]
        assert "::warning::" in proc.stdout and "never published" in proc.stdout
    else:
        assert not patches, calls
    assert "-X DELETE" not in gh and "workflow run" not in gh


def test_cut_tag_creation_stops_on_an_api_error(tmp_path):
    _tree(tmp_path)
    proc, _, gh, _ = _run(tmp_path, _step("cut", TAG)["run"], TAG_STATE="absent", TAG_SHA="", SHA=NEW_SHA, FAKE_API_RC="1")
    assert proc.returncode != 0
    assert "git/refs" not in gh, "no ref is created when the tag object failed"


@pytest.mark.parametrize("republish", ["false", "true"])
def test_cut_dispatches_on_the_tag_and_links_the_run(tmp_path, republish):
    _tree(tmp_path)
    proc, _, gh, _ = _run(tmp_path, _step("cut", DISPATCH)["run"], REPUBLISH=republish)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert (f"workflow run studio-release.yml --repo {REPO} --ref refs/tags/studio-v0.3.0-beta.2 "
            f"-f publish=true -f republish={republish}") in gh
    assert gh.count("workflow run") == 1
    assert "Release run: https://github.com/hugmesh/hugmesh-generator/actions/runs/777" in (tmp_path / "summary").read_text()
    assert "--branch studio-v0.3.0-beta.2 --event workflow_dispatch" in gh
