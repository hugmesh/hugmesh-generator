"""Which generator files and make targets the Studio uses, read from its own source
(Qt-free, stdlib only).

Nothing here is a hand-kept list. The Studio's ``.py`` files are parsed and two things
are collected:

  * PATHS: a string literal that IS a generator-relative path
    (``"scripts/gen-provision-keys.sh"``, ``"build-x86-host-stage4.sh"``), and the
    literal tail of an ``os.path.join(...)`` (``os.path.join(gen, "tests", "qemu",
    "run-qemu-docker.sh")`` gives ``tests/qemu/run-qemu-docker.sh``). Only paths whose
    first component is a top-level entry of the generator tree count, so prose and
    unrelated strings never match.
  * MAKE TARGETS: the first operand of ``["make", <target>, ...]`` and of a
    ``self._make("<target>", ...)`` call, a module-level constant included.

Two readers use it. tests/test_flatpak_generator_seed.py holds every path to the seed
the Flatpak ships (``studio/packaging/make_generator_seed.py``) and every target to the
Makefile in it, so a reference to something the bundle does not carry fails on the pull
request. ``core/self_check.py`` runs the same scan over the INSTALLED package and checks
each path in the generator tree the Studio resolved, inside the built Flatpak.
"""
from __future__ import annotations

import ast
import os
import re
from dataclasses import dataclass, field

PACKAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_PATHISH = re.compile(r"^[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)*/?$")


@dataclass
class Refs:
    #: generator-relative path -> ["module.py:line", ...]
    paths: dict[str, list[str]] = field(default_factory=dict)
    #: make target -> ["module.py:line", ...]
    make_targets: dict[str, list[str]] = field(default_factory=dict)


def _str(node, constants: dict[str, str]) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return constants.get(node.id)
    return None


def _module_constants(tree: ast.Module) -> dict[str, str]:
    """Module-level ``NAME = "text"`` and ``NAME = os.path.join("a", "b")``."""
    out: dict[str, str] = {}
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            value = node.value
            text = _str(value, out) if value is not None else None
            if text is None and isinstance(value, ast.Call) and _is_join(value):
                parts = [_str(a, out) for a in value.args]
                if parts and all(p is not None for p in parts):
                    text = "/".join(parts)  # type: ignore[arg-type]
            if text is None:
                continue
            for target in targets:
                if isinstance(target, ast.Name):
                    out[target.id] = text
    return out


def _is_join(call: ast.Call) -> bool:
    func = call.func
    return (isinstance(func, ast.Attribute) and func.attr == "join"
            and isinstance(func.value, ast.Attribute) and func.value.attr == "path")


def _normal(path: str) -> str:
    return path.replace("\\", "/").strip("/")


def scan(top_level: set[str], package_dir: str = PACKAGE_DIR) -> Refs:
    """Every generator path and make target the package at ``package_dir`` names.
    ``top_level`` is the set of top-level names in the generator tree."""
    refs = Refs()

    def add(table: dict[str, list[str]], key: str, where: str) -> None:
        table.setdefault(key, []).append(where)

    for directory, _dirs, files in os.walk(package_dir):
        for name in sorted(files):
            if not name.endswith(".py"):
                continue
            path = os.path.join(directory, name)
            rel_module = os.path.relpath(path, package_dir)
            try:
                with open(path, encoding="utf-8") as fh:
                    tree = ast.parse(fh.read(), filename=path)
            except (OSError, SyntaxError, ValueError):
                continue
            constants = _module_constants(tree)
            for node in ast.walk(tree):
                where = f"{rel_module}:{getattr(node, 'lineno', 0)}"
                candidate = None
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    candidate = node.value
                elif isinstance(node, ast.Call) and _is_join(node):
                    tail: list[str] = []
                    for arg in reversed(node.args):
                        text = _str(arg, constants)
                        if text is None:
                            break
                        tail.insert(0, text)
                    if tail:
                        candidate = "/".join(tail)
                if candidate is not None and _PATHISH.match(candidate):
                    rel = _normal(candidate)
                    first = rel.split("/", 1)[0]
                    if rel and first in top_level and ("/" in rel or rel in top_level):
                        add(refs.paths, rel, where)
                # make targets
                if isinstance(node, (ast.List, ast.Tuple)) and len(node.elts) >= 2 \
                        and _str(node.elts[0], {}) == "make":
                    target = _str(node.elts[1], constants)
                    if target and not target.startswith("-"):
                        add(refs.make_targets, target, where)
                if isinstance(node, ast.Call) and node.args:
                    func = node.func
                    fname = func.attr if isinstance(func, ast.Attribute) else (
                        func.id if isinstance(func, ast.Name) else "")
                    if fname == "_make":
                        target = _str(node.args[0], constants)
                        if target:
                            add(refs.make_targets, target, where)
    return refs


#: ``target: deps`` / ``a b: deps`` / ``target:: deps``, not ``VAR := value``.
_RULE = re.compile(r"^([A-Za-z0-9_.%/$(){} -]+?)\s*::?(?!=)")


def makefile_targets(makefile_text: str) -> set[str]:
    targets: set[str] = set()
    for line in makefile_text.splitlines():
        if not line or line[0] in "\t #":
            continue
        match = _RULE.match(line)
        if match:
            targets.update(t for t in match.group(1).split() if t)
    return targets
