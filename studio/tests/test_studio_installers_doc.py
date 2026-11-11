"""docs/STUDIO-INSTALLERS.md tells a user to clone hugmesh-generator only for a package
that does not carry it.

Which packages carry the generator tree is a fact of the release workflow, not of the
doc: a build job carries it when it has the step "Record whether the bundle carries the
generator it placed", whose output the publish job turns into ``generatorSeed`` in
releases.json (the Downloads page drops its clone step on that field). The doc's
"What a package gives you" table must put every package on the row its job earns, so
when the MSI and the tarball gain the seed (hugmesh-generator#977) this goes red until
the doc stops telling their users to clone. The site vendors this page as
/studio/installers.
"""
from __future__ import annotations

import os
import re

import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
DOC = os.path.join(GENERATOR_DIR, "docs", "STUDIO-INSTALLERS.md")
WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")

SEED_STEP = "Record whether the bundle carries the generator it placed"
#: Each build job and the words its package goes by in the doc's table.
JOB_LABELS = {
    "flatpak": "Flatpak",
    "flatpak-aarch64": "Flatpak",
    "msi": "Windows MSI",
    "linux": "Linux tarball",
}


def _doc() -> str:
    with open(DOC, encoding="utf-8") as handle:
        return handle.read()


def _section(title: str) -> str:
    text = _doc()
    match = re.search(rf"(?m)^## {re.escape(title)}\n(.*?)(?=^## |\Z)", text, re.S)
    assert match, f"docs/STUDIO-INSTALLERS.md has no '## {title}' section"
    return match.group(1)


def _seeded_jobs() -> set[str]:
    with open(WORKFLOW, encoding="utf-8") as handle:
        jobs = yaml.safe_load(handle)["jobs"]
    return {job for job in JOB_LABELS
            if any(step.get("name") == SEED_STEP for step in jobs[job]["steps"])}


def test_the_package_table_follows_the_jobs_that_prove_a_seed():
    seeded = _seeded_jobs()
    assert seeded, "no build job records a seed: the Flatpak jobs lost their step"
    rows = [line for line in _section("What a package gives you").splitlines()
            if line.startswith("| ") and "---" not in line]
    included = [r for r in rows if "**Included.**" in r]
    missing = [r for r in rows if "**Not included yet**" in r]
    assert len(included) == 1, rows
    for job, label in JOB_LABELS.items():
        first_cell = (included[0] if job in seeded else (missing or [""])[0]).split("|")[1]
        assert label in first_cell, (
            f"{label} ({job}) belongs on the "
            f"{'Included' if job in seeded else 'Not included yet'} row: {rows}")
    if seeded == set(JOB_LABELS):
        assert not missing, "every package carries the tree: drop the 'Not included yet' row"
    else:
        assert len(missing) == 1, rows
        assert "git clone https://github.com/hugmesh/hugmesh-generator" in missing[0]
    # The packages that carry it tell their users there is nothing to clone.
    assert "nothing to clone" in included[0]


def test_a_flatpak_start_line_never_needs_a_generator_dir():
    # The Flatpak places its own copy; a --generator-dir on the start line told users to
    # clone into a fixed path first (the text before #936 shipped the seed).
    starts = [line for line in _doc().splitlines()
              if line.strip().startswith("flatpak run org.hugmesh.ImageStudio")]
    assert starts, "the doc lost its Flatpak start line"
    for line in starts:
        assert "--generator-dir" not in line, line


def test_the_developer_checkout_section_is_separate_and_says_when_it_is_needed():
    body = _section("Developer: run the Studio from a checkout")
    assert "A packaged Studio needs none of this." in body
    assert "git clone https://github.com/hugmesh/hugmesh-generator" in body
    for reason in ("sudo", "devices", "macOS"):
        assert reason in body, reason
    # The page opens on the packages and points developers down to this section.
    intro = _doc().split("\n## ", 1)[0]
    assert "(#developer-run-the-studio-from-a-checkout)" in intro
    assert "That is still the main way" not in intro
