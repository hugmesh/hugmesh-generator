"""scripts/release-studio.sh: the one command that cuts a Studio release.

Run with a fake `gh` on PATH. The script must preflight read-only, refuse what the cut
workflow would refuse (in the same words), print the plan under --dry-run and never
reach `gh workflow run`, make a republish type the version back even under --yes,
and run every gh call with GH_TOKEN/GITHUB_TOKEN unset (an exported read-only token
shadows the keyring login on this fleet).
"""
from __future__ import annotations

import base64
import os
import re
import shutil
import stat
import subprocess

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SCRIPT = os.path.join(GENERATOR_DIR, "scripts", "release-studio.sh")
RELEASE = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")
REPO = "hugmesh/hugmesh-generator"

FAKE_GH = r'''#!/bin/bash
# The script must unset both; a call that still sees them is the bug this guards.
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then echo "fake gh: token leaked into gh" >&2; exit 97; fi
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status") exit 0 ;;
  "api user") echo "someone"; exit 0 ;;
  "api repos/$R") echo "${FAKE_VISIBILITY:-public}"; exit 0 ;;
  "api repos/$R/git/matching-refs/tags/studio-v") printf '%s\n' $FAKE_ALL_TAGS; exit 0 ;;
  "api repos/$R/contents/studio/hugmesh_studio/__init__.py?ref=main") echo "$FAKE_INIT_B64"; exit 0 ;;
  "api repos/$R/contents/.github/workflows/studio-release.yml?ref=refs/tags/"*) echo "$FAKE_WORKFLOW_B64"; exit 0 ;;
  "release view")
    case "$FAKE_RELEASE" in
      present) echo '{"tagName":"x"}'; exit 0 ;;
      absent) echo "release not found" >&2; exit 1 ;;
      *) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    esac ;;
  "run list")
    case "$*" in *studio-release-cut.yml*) [ "${FAKE_CUT_EXISTS:-1}" = "1" ] || { echo "HTTP 404: workflow studio-release-cut.yml not found on the default branch" >&2; exit 1; } ;; esac
    echo "${FAKE_BUSY:-0}"; exit 0 ;;
  "workflow run") exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 99
'''


def _b64(text: str) -> str:
    return base64.b64encode(text.encode()).decode()


def _workflow_without_republish() -> str:
    lines = open(RELEASE, encoding="utf-8").read().splitlines(keepends=True)
    start = next(i for i, l in enumerate(lines) if l.rstrip() == "      republish:")
    end = next(i for i in range(start + 1, len(lines)) if re.match(r"^ {2}\S", lines[i]))
    return "".join(lines[:start] + lines[end:])


@pytest.fixture
def fake(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    gh = bindir / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    log = tmp_path / "gh.log"
    log.write_text("")
    init = open(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), encoding="utf-8").read()
    main_init = re.sub(r'(?m)^__version__ = "[^"]+"$', '__version__ = "0.3.0-beta.1"', init)
    env = {
        "PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(tmp_path), "TMPDIR": str(tmp_path),
        "GH_LOG": str(log), "R": REPO,
        # Exported on purpose: the script must unset them before every gh call.
        "GH_TOKEN": "not-a-token", "GITHUB_TOKEN": "not-a-token",
        "FAKE_RELEASE": "absent", "FAKE_ALL_TAGS": "refs/tags/studio-v0.3.0-beta.1",
        "FAKE_INIT_B64": _b64(main_init),
        "FAKE_WORKFLOW_B64": _b64(open(RELEASE, encoding="utf-8").read()),
    }

    def run(*args, stdin="", **over):
        e = dict(env)
        e.update({k: str(v) for k, v in over.items()})
        proc = subprocess.run([SCRIPT, *args], env=e, input=stdin, capture_output=True, text=True, timeout=60)
        return proc, log.read_text()

    return run


def test_shellcheck_clean():
    if shutil.which("shellcheck") is None:
        pytest.skip("shellcheck is not installed here (ubuntu-latest has it)")
    proc = subprocess.run(["shellcheck", "-S", "warning", SCRIPT], capture_output=True, text=True)
    assert proc.returncode == 0 and proc.stdout == "", proc.stdout


def test_dry_run_prints_the_plan_and_never_dispatches(fake):
    proc, log = fake("0.3.0-beta.2", "--dry-run")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert "tag studio-v0.3.0-beta.2" in proc.stdout
    assert "commit the bump of __version__ from 0.3.0-beta.1 to 0.3.0-beta.2 on main" in proc.stdout
    assert "PRE-RELEASE" in proc.stdout and "Dry run: stopping here" in proc.stdout
    assert "workflow run" not in log
    assert "-X " not in log, "a dry run makes no mutating call"
    assert "auth status" in log and "release view studio-v0.3.0-beta.2" in log
    # The unset is proven by the fake gh itself (exit 97 on a leaked token).


def test_dry_run_with_no_version_proposes_the_next_beta(fake):
    expected = subprocess.run(["python3", os.path.join(STUDIO_ROOT, "packaging", "release_version.py"), "next"],
                              capture_output=True, text=True).stdout.strip()
    proc, log = fake("--dry-run", stdin="y\n")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert f"the next beta is {expected}" in proc.stdout
    assert f"Release {expected}? [Y/n]" in proc.stdout
    assert "workflow run" not in log
    proc, _ = fake("--dry-run", stdin="n\n")
    assert proc.returncode == 0 and "Nothing done." in proc.stdout


@pytest.mark.parametrize("bad", ["0.3.0-rc.1", "0.3.0-SNAPSHOT", "v0.3.0", "0.3.0-beta.0"])
def test_bad_version_exits_2(fake, bad):
    proc, log = fake(bad, "--dry-run")
    assert proc.returncode == 2, (proc.stdout, proc.stderr)
    assert "not a releasable version" in proc.stderr
    assert "workflow run" not in log


def test_existing_release_without_republish_exits_2(fake):
    proc, log = fake("0.3.0-beta.1", "--dry-run", FAKE_RELEASE="present")
    assert proc.returncode == 2
    assert "already exists" in proc.stderr and "--republish" in proc.stderr
    assert "workflow run" not in log


def test_version_not_after_the_newest_tag_exits_2(fake):
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_ALL_TAGS="refs/tags/studio-v0.3.0-beta.1\nrefs/tags/studio-v0.3.0-beta.2\nrefs/tags/studio-v0.3.0-beta.3",
                   FAKE_RELEASE="absent")
    # Its own tag is ignored (a failed build's tag), but beta.3 exists: refuse.
    assert proc.returncode == 2 and "does not sort after" in proc.stderr
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_ALL_TAGS="refs/tags/studio-v0.3.0-beta.1\nrefs/tags/studio-v0.3.0-beta.2")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)


def test_main_already_past_the_version_exits_2(fake):
    init = open(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), encoding="utf-8").read()
    later = re.sub(r'(?m)^__version__ = "[^"]+"$', '__version__ = "0.3.0-beta.5"', init)
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_INIT_B64=_b64(later), FAKE_ALL_TAGS="")
    assert proc.returncode == 2 and "choose a later version" in proc.stderr
    same = re.sub(r'(?m)^__version__ = "[^"]+"$', '__version__ = "0.3.0-beta.2"', init)
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_INIT_B64=_b64(same))
    assert proc.returncode == 0 and "no bump: main is already at 0.3.0-beta.2" in proc.stdout


def test_republish_on_a_tag_whose_workflow_predates_the_input_exits_2(fake):
    proc, log = fake("0.3.0-beta.1", "--republish", "--dry-run", FAKE_RELEASE="present",
                     FAKE_WORKFLOW_B64=_b64(_workflow_without_republish()))
    assert proc.returncode == 2, (proc.stdout, proc.stderr)
    assert "predates the republish input" in proc.stderr
    assert "workflow run" not in log


def test_republish_dry_run_states_the_consequence(fake):
    proc, log = fake("0.3.0-beta.1", "--republish", "--dry-run", FAKE_RELEASE="present")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    assert "REPLACE every file of release studio-v0.3.0-beta.1" in proc.stdout
    assert "can no longer verify" in proc.stdout
    assert "workflow run" not in log


def test_republish_without_a_release_exits_2(fake):
    proc, _ = fake("0.3.0-beta.2", "--republish", "--dry-run", FAKE_RELEASE="absent")
    assert proc.returncode == 2 and "run a normal release" in proc.stderr


def test_republish_with_yes_still_makes_you_type_the_version(fake):
    proc, log = fake("0.3.0-beta.1", "--republish", "--yes", stdin="0.3.0-beta.2\n", FAKE_RELEASE="present")
    assert proc.returncode == 2, (proc.stdout, proc.stderr)
    assert "Type 0.3.0-beta.1 to confirm:" in proc.stdout
    assert "confirmation did not match" in proc.stderr
    assert "workflow run" not in log


def test_cannot_tell_whether_the_release_exists_exits_2(fake):
    proc, log = fake("0.3.0-beta.2", "--dry-run", FAKE_RELEASE="502")
    assert proc.returncode == 2 and "could not tell" in proc.stderr
    assert "workflow run" not in log


def test_private_repository_exits_2(fake):
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_VISIBILITY="private")
    assert proc.returncode == 2 and "private" in proc.stderr


def test_a_release_run_in_progress_exits_2(fake):
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_BUSY="1")
    assert proc.returncode == 2 and "in progress" in proc.stderr


def test_cut_workflow_not_yet_on_main_is_not_a_run_in_progress(fake):
    # Before this change is merged the cut workflow 404s; that is zero runs, not an error.
    proc, _ = fake("0.3.0-beta.2", "--dry-run", FAKE_CUT_EXISTS="0")
    assert proc.returncode == 0, (proc.stdout, proc.stderr)


def test_the_script_never_tags_or_pushes():
    text = open(SCRIPT, encoding="utf-8").read()
    code = re.sub(r"(?m)^\s*#.*$", "", text)
    assert "git tag" not in code and "git push" not in code
    assert "gh release create" not in code and "gh release upload" not in code
    assert "-X POST" not in code and "-X PATCH" not in code and "-X DELETE" not in code
    assert "env -u GH_TOKEN -u GITHUB_TOKEN gh" in code
    assert "studio-release-cut.yml" in code and "--ref main" in code
    assert "-f republish=true" in code and '-f "confirm=$VERSION"' in code
    assert 'gh_ workflow run studio-release.yml' not in code, "the script drives the cut, never the release workflow"
