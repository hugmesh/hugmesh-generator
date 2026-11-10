"""studio-tests.yml must run on a push to main that touches a Studio release guard.

Why this exists: the push trigger in studio-tests.yml was added after studio-release.yml
was hand-edited on main through the web UI (2026-10-22/23) and three release guard tests
went red with nothing showing it. But the trigger listed only the release MACHINERY, not
the guards. On 2026-11-05/06 the guards themselves were hand-edited and then deleted
on main through the web UI (test_studio_beta_version.py went from 21 tests to 1). Every
one of those commits touched only studio/tests/*, so "Studio tests" never ran on any of
them.

What this pins:

* every test file the cut workflow's guard step runs is a push path (derived from
  studio-release-cut.yml, so a guard added to the cut must be added here too);
* the other release guard files (this one included) are push paths;
* every repo file a guard reads via a literal ``os.path.join(STUDIO_ROOT|GENERATOR_DIR,
  ...)`` is a push path. Example: msi_version.py, whose mapping the guards check;
* the push trigger is still limited to main.

What it does NOT pin: a guard that reads a file through a computed path (a glob, a loop
over a directory). test_studio_release_signing.py scans every file in
.github/workflows/, and a push touching only some other workflow will not fire this.
"""
from __future__ import annotations

import ast
import fnmatch
import os
import re

import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOWS = os.path.join(GENERATOR_DIR, ".github", "workflows")
STUDIO_TESTS = os.path.join(WORKFLOWS, "studio-tests.yml")
CUT = os.path.join(WORKFLOWS, "studio-release-cut.yml")
THIS = "studio/tests/" + os.path.basename(__file__)

# Release guards that the cut does not run itself but that pin the release machinery.
OTHER_GUARDS = {
    "studio/tests/test_studio_release_cut.py",
    "studio/tests/test_release_studio_script.py",
    THIS,
}

# The paths listed in the 0.4 release post-mortem, kept explicitly as well as derived.
# If a derivation below breaks silently, these still have to be there.
REQUIRED = {
    "studio/tests/test_studio_beta_version.py",
    "studio/tests/test_studio_release_signing.py",
    "studio/tests/test_studio_release_cut.py",
    "studio/packaging/wix/msi_version.py",
    "studio/packaging/build-msi-wine.sh",
}


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _on(path: str) -> dict:
    doc = yaml.safe_load(_read(path))
    return doc.get(True, doc.get("on"))  # PyYAML reads the bare key `on` as True


def _push() -> dict:
    push = _on(STUDIO_TESTS).get("push")
    assert isinstance(push, dict), "studio-tests.yml has no push trigger"
    return push


def _push_paths() -> list[str]:
    paths = _push().get("paths")
    assert isinstance(paths, list) and paths, "studio-tests.yml push trigger lists no paths"
    return paths


def _fires(path: str, patterns: list[str]) -> bool:
    # Exact or glob. GitHub's '**' crosses '/', and so does fnmatch's '*', which is
    # looser than GitHub but only in the direction of saying "fires" for a glob, and
    # nothing in the push list is a glob today.
    return any(path == p or fnmatch.fnmatchcase(path, p) for p in patterns)


def _cut_guard_files() -> set[str]:
    runs = "\n".join(step.get("run", "") for job in yaml.safe_load(_read(CUT))["jobs"].values()
                     for step in job.get("steps", []))
    files = set(re.findall(r"studio/tests/[\w/]+\.py", runs))
    assert files, "found no guard test files in studio-release-cut.yml's run steps"
    return files


def _guard_files() -> set[str]:
    return _cut_guard_files() | OTHER_GUARDS


_ROOTS = {"STUDIO_ROOT": "studio", "GENERATOR_DIR": ""}


def _literal_join_targets(source: str) -> set[str]:
    """Repo-relative paths of every ``os.path.join(STUDIO_ROOT|GENERATOR_DIR, "lit", ...)``,
    following module-level names bound to such a join (``WORKFLOWS = os.path.join(...)``)."""
    tree = ast.parse(source)
    known = dict(_ROOTS)

    def resolve(node: ast.AST) -> str | None:
        if isinstance(node, ast.Name):
            return known.get(node.id)
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "join" and ast.unparse(node.func.value) == "os.path"
                and node.args):
            base = resolve(node.args[0])
            rest = node.args[1:]
            if base is None or not all(isinstance(a, ast.Constant) and isinstance(a.value, str)
                                       for a in rest):
                return None
            return "/".join([p for p in [base, *(a.value for a in rest)] if p])
        return None

    for stmt in tree.body:  # module-level aliases first, in order
        if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
            value = resolve(stmt.value)
            if value is not None:
                known[stmt.targets[0].id] = value

    found = set()
    for node in ast.walk(tree):
        value = resolve(node) if isinstance(node, ast.Call) else None
        if value:
            found.add(value)
    return found


def _read_targets(rel: str) -> set[str]:
    """Files (not directories) a guard reads by a literal path."""
    path = os.path.join(GENERATOR_DIR, rel)
    if not os.path.isfile(path):
        return set()
    return {t for t in _literal_join_targets(_read(path))
            if os.path.isfile(os.path.join(GENERATOR_DIR, t))}


# ── the trigger ─────────────────────────────────────────────────────────────────────
def test_push_trigger_is_main_only():
    assert _push().get("branches") == ["main"], _push()


def test_post_mortem_paths_are_push_paths():
    missing = sorted(p for p in REQUIRED if not _fires(p, _push_paths()))
    assert not missing, f"a hand edit of these on main runs no Studio tests: {missing}"


def test_every_release_guard_file_is_a_push_path():
    missing = sorted(p for p in _guard_files() if not _fires(p, _push_paths()))
    assert not missing, f"a hand edit or deletion of these guards on main runs no Studio tests: {missing}"


def test_every_file_a_guard_reads_is_a_push_path():
    patterns = _push_paths()
    missing = sorted({f"{t}  (read by {g})" for g in sorted(_guard_files())
                      for t in _read_targets(g) if not _fires(t, patterns)})
    assert not missing, "a push changing these runs no Studio tests:\n" + "\n".join(missing)


def test_every_push_path_still_exists():
    # A rename that leaves a dead entry behind makes the trigger look complete while the
    # renamed file is unguarded.
    dead = [p for p in _push_paths() if not any(ch in p for ch in "*?[")
            and not os.path.exists(os.path.join(GENERATOR_DIR, p))]
    assert not dead, dead


# ── the derivations, so a broken one cannot pass vacuously ───────────────────────────
def test_cut_guard_derivation_finds_both_files():
    assert {"studio/tests/test_studio_beta_version.py",
            "studio/tests/test_studio_release_signing.py"} <= _cut_guard_files()


def test_read_target_derivation_sees_the_wix_mapper():
    targets = set()
    for guard in _guard_files():
        targets |= _read_targets(guard)
    assert {"studio/packaging/wix/msi_version.py",
            ".github/workflows/studio-release.yml",
            "studio/packaging/release_version.py"} <= targets, targets


def test_literal_join_detector():
    src = (
        "import os\n"
        "STUDIO_ROOT = 'x'\nGENERATOR_DIR = 'y'\n"
        "W = os.path.join(GENERATOR_DIR, '.github', 'workflows')\n"
        "A = os.path.join(W, 'a.yml')\n"
        "B = os.path.join(STUDIO_ROOT, 'packaging', 'b.py')\n"
        "def f(n):\n"
        "    os.path.join(STUDIO_ROOT, 'hugmesh_studio', '__init__.py')\n"
        "    os.path.join(STUDIO_ROOT, n)\n"
        "    os.path.join(OTHER, 'z.py')\n"
    )
    assert _literal_join_targets(src) == {
        ".github/workflows", ".github/workflows/a.yml", "studio/packaging/b.py",
        "studio/hugmesh_studio/__init__.py"}


def test_fires_matcher():
    assert _fires("studio/tests/a.py", ["studio/tests/a.py"])
    assert _fires("studio/tests/a.py", ["studio/**"])
    assert not _fires("studio/tests/a.py", ["studio/tests/b.py", "scripts/**"])
