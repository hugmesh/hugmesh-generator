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

The forbidden strings are spelled from PARTS in this file, because this file is one
of the owned files the guard reads. The mutation test plants one into a COPY of an
owned file and shows the checker refuses it, then the copy is discarded.
"""
from __future__ import annotations

import os
import shutil

import pytest

from hugmesh_studio.core import org_export as oe

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(STUDIO_ROOT)

# the private target's names, assembled so they never appear whole in this file
_A = "snap" + "dragon"
FORBIDDEN = (
    _A,                      # any case, any form: covers the three longer spellings too
    _A + ".systems",
    _A + "-systems",
    "lavender-" + _A,
)

#: Every file this feature owns (repo-relative). A path that does not exist is
#: skipped, so the list can name the whole owns list; directories are walked.
OWNED = (
    "studio/hugmesh_studio/core/org_export.py",
    "studio/hugmesh_studio/core/org_export_site",
    "studio/hugmesh_studio/core/golive_domains.py",
    "studio/hugmesh_studio/core/golive_driver.py",
    "studio/hugmesh_studio/core/config.py",
    "studio/hugmesh_studio/core/local_mesh_domains.py",
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
    "studio/README.md",
    "docs/GOLIVE-ORG-EXPORT.md",
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


def forbidden_hits(path: str) -> list[str]:
    """``["<path>:<line no>: <string>", ...]`` for every forbidden string in the file,
    read as bytes (a NUL byte must not make the check skip the file)."""
    with open(path, "rb") as fh:
        data = fh.read()
    text = data.decode("utf-8", "replace").lower()
    hits: list[str] = []
    for needle in FORBIDDEN:
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


@pytest.mark.parametrize("rel", [r for r in OWNED if r.endswith(".py")])
def test_each_owned_python_file_is_clean(rel):
    path = os.path.join(REPO_ROOT, rel)
    if not os.path.isfile(path):
        pytest.skip(f"{rel} is not in this tree")
    assert forbidden_hits(path) == []
