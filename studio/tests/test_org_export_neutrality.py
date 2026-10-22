"""The neutrality guard for the Go-Live "Export to GitHub org" feature.

The feature is GENERIC: it takes the domain, the organisation slug, the brand and the
rename map from configuration and arguments, and names no real organisation or domain
anywhere — only the placeholders mesh.example / exampleorg / example. A private
target's setup lives in a folder outside every repository, never here.

Two things are pinned, both case-insensitively:

* no file the feature owns (the engine, the templates, the pages, the steps, the
  tests, the fixtures, the docs) contains any of the forbidden strings;
* the engine's built-in defaults (ExportConfig(), the default rename rules) name no
  concrete organisation, brand or domain.

The forbidden string is spelled from PARTS in this file, because this file is one of
the owned files the guard reads — and it is the ONE short stem only: a substring check
on it catches every longer spelling (the domain, the organisation slug), so writing
those out here would add no check and would put the private names into the
repository, which is the very thing this guard exists to stop. Longer private
spellings, if wanted, live with the operator's setup OUTSIDE the repository: a file
named by ``HUGMESH_ORG_EXPORT_PRIVATE_NAMES`` (one string per line) is read when set.
The mutation test plants a forbidden spelling into a COPY of an owned file and shows
the checker refuses it, then the copy is discarded.
"""
from __future__ import annotations

import os
import shutil

import pytest

from hugmesh_studio.core import org_export as oe

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(STUDIO_ROOT)

# the private target's name stem, assembled so it never appears whole in this file
_A = "snap" + "dragon"


def _private_names() -> tuple[str, ...]:
    """Extra forbidden strings from the operator's folder outside the repository
    (``HUGMESH_ORG_EXPORT_PRIVATE_NAMES``: a file, one string per line, ``#`` comments);
    none when the variable is unset or the file is unreadable."""
    path = os.environ.get("HUGMESH_ORG_EXPORT_PRIVATE_NAMES", "").strip()
    if not path:
        return ()
    try:
        with open(path, encoding="utf-8") as fh:
            lines = [ln.strip().lower() for ln in fh]
    except OSError:
        return ()
    return tuple(ln for ln in lines if ln and not ln.startswith("#"))


FORBIDDEN = (_A, *_private_names())

#: Every file this feature owns (repo-relative). A path that does not exist is
#: skipped, so the list can name the whole owns list; directories are walked.
OWNED = (
    "studio/hugmesh_studio/core/org_export.py",
    "studio/hugmesh_studio/core/org_export_site",
    "studio/hugmesh_studio/core/golive_domains.py",
    "studio/hugmesh_studio/core/golive_driver.py",
    "studio/hugmesh_studio/core/config.py",
    "studio/hugmesh_studio/core/local_mesh_domains.py",
    "studio/hugmesh_studio/core/local_mesh_bootstrap.py",
    "studio/hugmesh_studio/core/worklist_driver.py",
    "studio/hugmesh_studio/gui/pages/golive.py",
    "studio/hugmesh_studio/gui/pages/domains.py",
    "studio/hugmesh_studio/gui/pages/localmesh.py",
    "studio/hugmesh_studio/tui/domains_step.py",
    "studio/hugmesh_studio/tui/localmesh.py",
    "studio/hugmesh_studio/tui/golive.py",
    "studio/hugmesh_studio/app.py",
    "studio/tests/test_org_export.py",
    "studio/tests/test_org_export_gui.py",
    "studio/tests/test_org_export_tui.py",
    "studio/tests/test_org_export_neutrality.py",
    "studio/tests/_org_export_helpers.py",
    "studio/tests/fixtures/org_export",
    "studio/tests/test_worklist_driver.py",
    "studio/tests/test_golive_wizard.py",
    "studio/tests/test_pages_domains_ca.py",
    "studio/README.md",
    "docs/GOLIVE-ORG-EXPORT.md",
    "docs/README.md",
    "docs/STUDIO-WALKTHROUGH.md",
    "tests/e2e/features/studio-org-export",
    "tests/e2e/steps/studio-org-export.steps.ts",
    "tests/e2e/studio-org-export-driver.py",
)


def owned_files() -> list[str]:
    out: list[str] = []
    for rel in OWNED:
        full = os.path.join(REPO_ROOT, rel)
        if os.path.isdir(full):
            for dirpath, _dirs, files in os.walk(full):
                out.extend(os.path.join(dirpath, f) for f in sorted(files))
        elif os.path.isfile(full):
            out.append(full)
    return out


def forbidden_hits(path: str, needles=None) -> list[str]:
    """``["<path>:<line no>: <string>", ...]`` for every forbidden string in the file,
    read as bytes (a NUL byte must not make the check skip the file)."""
    with open(path, "rb") as fh:
        data = fh.read()
    text = data.decode("utf-8", "replace").lower()
    hits: list[str] = []
    for needle in (needles or FORBIDDEN):
        if needle not in text:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if needle in line:
                hits.append(f"{path}:{i}: {needle}")
    return hits


def test_the_owned_files_exist_and_the_list_is_not_vacuous():
    files = owned_files()
    assert len(files) >= 20, files
    assert any(f.endswith("core/org_export.py") for f in files)
    assert any("fixtures/org_export/sources" in f for f in files)
    assert any(f.endswith("docs/GOLIVE-ORG-EXPORT.md") for f in files)


def test_no_owned_file_names_the_private_target():
    hits: list[str] = []
    for path in owned_files():
        hits.extend(forbidden_hits(path))
    assert hits == [], "\n".join(hits)


def test_the_engines_defaults_name_no_concrete_organisation():
    cfg = oe.ExportConfig()
    assert (cfg.domain, cfg.org, cfg.brand) == ("", "", "")
    assert cfg.rename_map == {}
    assert cfg.remote_base == "https://github.com/"
    for value in (cfg.author_name, cfg.author_email, *oe.BUILD_LIBRARY_REPOS,
                  oe.GENERATOR_REPO, *oe.NOT_RENAMED, *oe.EXCLUDED_DIRS,
                  *oe.EXCLUDED_NAMES, *oe.SECRET_GLOBS):
        for needle in FORBIDDEN:
            assert needle not in value.lower(), value
    # the default rules are built from the org/brand GIVEN, nothing else
    rules = oe.rename_rules(oe.ExportConfig(org="exampleorg"), ["hugmesh-parent"])
    for rx, rep, note in rules:
        for needle in FORBIDDEN:
            assert needle not in (rx.pattern + rep + note).lower(), (rx.pattern, rep)
        assert "exampleorg" in rep or "example-" in rep
    from hugmesh_studio.core.org_export_site import TEMPLATES
    for _path, text in TEMPLATES:
        for needle in FORBIDDEN:
            assert needle not in text.lower()


def test_the_checker_catches_a_planted_name_in_a_copy_of_an_owned_file(tmp_path):
    """The mutation: plant each forbidden spelling (in mixed case) into a COPY of the
    engine and show the checker refuses it. The copy lives in tmp and is discarded;
    the owned file is never touched."""
    src = os.path.join(REPO_ROOT, "studio/hugmesh_studio/core/org_export.py")
    assert forbidden_hits(src) == []
    for needle in FORBIDDEN:
        copy = tmp_path / "org_export_mutated.py"
        shutil.copyfile(src, copy)
        with open(copy, "a", encoding="utf-8") as fh:
            fh.write(f"\nDEFAULT_ORG = '{needle.title()}'\n")
        hits = forbidden_hits(str(copy))
        assert hits and all(h.endswith(f": {_A}") or needle in h for h in hits), hits
        os.unlink(copy)
    # a NUL byte in the file does not blind the check (the grep trap)
    nul = tmp_path / "with_nul.txt"
    nul.write_bytes(b"x\0y\n" + _A.encode() + b"\n")
    assert forbidden_hits(str(nul))


def test_the_guard_itself_spells_only_the_assembled_stem():
    """The built-in list is the one assembled stem: any longer private spelling written
    out here would be the leak the guard exists to stop."""
    assert tuple(FORBIDDEN[:1]) == (_A,)
    with open(os.path.abspath(__file__), encoding="utf-8") as fh:
        me = fh.read().lower()
    assert _A not in me                         # never whole, even in a comment
    assembled = '"snap" + ' + '"dragon"'        # (built here so this line is not a hit)
    assert me.count(assembled) == 1             # assembled exactly once


def test_private_spellings_come_from_a_file_outside_the_repository(tmp_path, monkeypatch):
    """The operator's longer spellings are read from ``HUGMESH_ORG_EXPORT_PRIVATE_NAMES``
    when set — a file in their folder, never a line in this repository — and the
    checker refuses them like the built-in stem. Every check here names its needles
    explicitly (the stem, or the spellings this test wrote), so the test is independent
    of the import-time ``FORBIDDEN``: when the variable was set at import to a file
    naming a string the tree contains, only the guard proper fails, not this test."""
    monkeypatch.delenv("HUGMESH_ORG_EXPORT_PRIVATE_NAMES", raising=False)
    assert _private_names() == ()
    names = tmp_path / "private-names.txt"
    names.write_text("# the operator's own spellings\nPlaceholder-Private-Org\n\n"
                     "placeholder.private.example\n")
    monkeypatch.setenv("HUGMESH_ORG_EXPORT_PRIVATE_NAMES", str(names))
    extra = _private_names()
    assert extra == ("placeholder-private-org", "placeholder.private.example")
    monkeypatch.setenv("HUGMESH_ORG_EXPORT_PRIVATE_NAMES", str(tmp_path / "missing.txt"))
    assert _private_names() == ()              # unreadable: none, the guard still runs
    src = os.path.join(REPO_ROOT, "studio/hugmesh_studio/core/org_export.py")
    copy = tmp_path / "org_export_mutated.py"
    shutil.copyfile(src, copy)
    with open(copy, "a", encoding="utf-8") as fh:
        fh.write("\nDEFAULT_ORG = 'Placeholder-Private-Org'\n")
    assert forbidden_hits(str(copy), (_A,)) == []            # the stem alone misses it
    hits = forbidden_hits(str(copy), (_A, *extra))
    assert hits and all(h.endswith(": placeholder-private-org") for h in hits), hits
    me = os.path.abspath(__file__)                           # this test spells them
    for path in owned_files():                               # the tree is clean of them too
        if os.path.abspath(path) != me:
            assert forbidden_hits(path, extra) == []


@pytest.mark.parametrize("rel", [r for r in OWNED if r.endswith(".py")])
def test_each_owned_python_file_is_clean(rel):
    path = os.path.join(REPO_ROOT, rel)
    if not os.path.isfile(path):
        pytest.skip(f"{rel} is not in this tree")
    assert forbidden_hits(path) == []


# ── THE WHOLE REPOSITORY, not only the files this feature owns ───────────────
# The repository goes public, so the private target's stem must not appear in ANY
# tracked file — code, docs, fixtures, built bundles, certificates. Two shapes are
# checked: the stem itself (case-insensitive, read as bytes so a NUL byte cannot
# blind it), and the stem inside BASE64, which is how it hid in the dev keys and the
# DER bodies of the old test certificates where no plain grep could see it.
#
# This file runs only when studio/** changes. The same whole-tree scan, with more
# shapes (UTF-16, hex, URL-safe base64, PNG text chunks), runs on EVERY pull request
# as section 10 of tests/scripts/test-image-builder-always-on.sh, through
# tests/scripts/private_name_neutrality.py. Neither can read text drawn as pixels.

def _b64_cores(word: str) -> tuple[str, ...]:
    """The stable base64 substrings ``word`` produces at each of the three byte
    alignments, in lower, Title and UPPER case. A substring check on these finds
    the word inside any base64 blob, whatever precedes it."""
    import base64
    cores: set[str] = set()
    for variant in {word.lower(), word.title(), word.upper()}:
        for pad in range(3):
            enc = base64.b64encode(b"\0" * pad + variant.encode()).decode()
            # drop the chars that depend on the padding prefix / trailing bytes
            lead = {0: 0, 1: 2, 2: 3}[pad]
            core = enc[lead:]
            core = core[: len(core) - (len(core) % 4 or 4)]
            if len(core) >= 8:
                cores.add(core)
    return tuple(sorted(cores))


def tracked_files() -> list[str]:
    """Every file git tracks in this checkout (absolute paths)."""
    import subprocess
    out = subprocess.run(["git", "-C", REPO_ROOT, "ls-files", "-z"],
                         capture_output=True, check=True).stdout
    return [os.path.join(REPO_ROOT, p) for p in out.decode("utf-8").split("\0") if p]


def repo_hits(paths) -> list[str]:
    stems = [s.encode() for s in FORBIDDEN]
    cores = [c.encode() for s in FORBIDDEN for c in _b64_cores(s)]
    hits: list[str] = []
    for path in paths:
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            continue                                  # a submodule dir or a dangling link
        low = data.lower()
        for stem in stems:
            if stem in low:
                hits.append(f"{os.path.relpath(path, REPO_ROOT)}: plain")
        for core in cores:
            if core in data:
                hits.append(f"{os.path.relpath(path, REPO_ROOT)}: base64")
    return hits


def test_no_tracked_file_in_the_repository_names_the_private_target():
    files = tracked_files()
    assert len(files) > 1000, "git ls-files returned too little — the scan would be vacuous"
    hits = repo_hits(files)
    assert hits == [], "\n".join(sorted(set(hits)))


def test_the_repository_scan_catches_plain_and_base64_plants(tmp_path):
    """The mutation for the whole-repo scan: a plain mixed-case plant, one behind a NUL
    byte, and a base64 plant at every alignment must each be reported."""
    import base64
    plain = tmp_path / "plain.txt"
    plain.write_text("host: registry." + _A.title() + ".example\n")
    nul = tmp_path / "nul.bin"
    nul.write_bytes(b"\0\0" + _A.upper().encode() + b"\0")
    plants = [str(plain), str(nul)]
    for pad in range(3):
        f = tmp_path / f"b64-{pad}.yaml"
        blob = base64.b64encode(b"x" * pad + (_A + "-dev-key-32byte").encode()).decode()
        f.write_text(f"KEY: ${{KEY:-{blob}}}\n")
        plants.append(str(f))
    for path in plants:
        assert repo_hits([path]), path
    clean = tmp_path / "clean.txt"
    clean.write_text("snap dragon snapper dragonfly " + base64.b64encode(b"hugmesh-dev").decode())
    assert repo_hits([str(clean)]) == []
