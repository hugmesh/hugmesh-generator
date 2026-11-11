"""Every Studio wizard step's header subtitle, read from the source (GUI-14).

Qt's ModernStyle wizard header is sized for TWO lines of subtitle: ``QWizardHeader::setup``
measures the label holding "Pq\\nPq" and pins the header's maximum height to that, and a
longer subtitle is clipped mid-sentence with no ellipsis, scroll bar or tooltip. The Mode
step stopped at "…test lanes), MESH", Domains at "…with a generated random" and the
Secrets store at "…so first-boot".

A page's constructor subtitle can be measured on a live wizard, but several pages set
another one later — per mode in ``initializePage`` (key-zip, role, network, branding), or
a docked variant once the bottom panel holds the run view (the local mesh steps) — and
those exist only on the path that reaches them. This module finds them in the source
WITHOUT importing Qt, so the Qt-free GitHub job can hold a character budget
(``test_wizard_subtitle_budget.py``) and the Qt suite can measure every one of them in
the real header (``test_wizard.py``).

What it reads: every ``setSubTitle(<expr>)`` call in ``gui/pages/*.py`` whose argument is
a string literal, a conditional or ``+`` of them, a module-level constant of the same
file, a class constant (``self.X``) defined in the same file, or a constant of a module
the file imports by alias (``dca.STEP_SUBTITLE``); plus every class constant whose name
ends in ``SUBTITLE`` (the local mesh steps' ``SUBTITLE`` / ``DOCKED_SUBTITLE``). Anything
else is returned as unresolved, so a caller can pin the known ones and fail on a new one.
"""
from __future__ import annotations

import ast
import os

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE_DIR = os.path.join(STUDIO_ROOT, "hugmesh_studio")
PAGES_DIR = os.path.join(PACKAGE_DIR, "gui", "pages")

#: Page modules that are not steps of the Studio wizard. Their pages live in another
#: QWizard with its own size, so the Studio wizard's header is the wrong ruler for them.
NOT_STUDIO_WIZARD = {
    "golive.py": "GoLiveWizard's pages (an 820x640 wizard of its own, not the Studio's)",
}


def _concat(parts):
    out = [""]
    for alts in parts:
        out = [a + b for a in out for b in alts]
    return out


class _File:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            self.tree = ast.parse(f.read(), filename=path)
        self.module_consts: dict[str, list[str]] = {}
        self.class_consts: dict[str, list[str]] = {}
        self.aliases: dict[str, str] = {}
        self.class_subtitles: list[tuple[int, str, ast.AST]] = []
        for node in self.tree.body:
            if isinstance(node, ast.ImportFrom) and node.level:
                # from ...core import domain_ca_keys as dca -> dca = <package>/core/domain_ca_keys.py
                base = os.path.dirname(path)
                for _ in range(node.level - 1):
                    base = os.path.dirname(base)
                if node.module:
                    base = os.path.join(base, *node.module.split("."))
                for alias in node.names:
                    target = os.path.join(base, alias.name + ".py")
                    if os.path.isfile(target):
                        self.aliases[alias.asname or alias.name] = target
        for node in self.tree.body:
            self._collect_assign(node, self.module_consts)
        for cls in (n for n in ast.walk(self.tree) if isinstance(n, ast.ClassDef)):
            for node in cls.body:
                self._collect_assign(node, self.class_consts)
                for tgt in _assign_targets(node):
                    if tgt.endswith("SUBTITLE"):
                        self.class_subtitles.append((node.lineno, f"{cls.name}.{tgt}",
                                                     node.value))

    def _collect_assign(self, node, into):
        for tgt in _assign_targets(node):
            texts = self.resolve(node.value)
            if texts:
                into.setdefault(tgt, []).extend(texts)

    def resolve(self, node) -> list[str]:
        """The text(s) ``node`` evaluates to, or [] when it is not a constant."""
        if isinstance(node, ast.Constant):
            return [node.value] if isinstance(node.value, str) else []
        if isinstance(node, ast.IfExp):
            a, b = self.resolve(node.body), self.resolve(node.orelse)
            return a + b if a and b else []
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            a, b = self.resolve(node.left), self.resolve(node.right)
            return _concat([a, b]) if a and b else []
        if isinstance(node, ast.Name):
            return list(self.module_consts.get(node.id, []))
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            if node.value.id == "self":
                return list(self.class_consts.get(node.attr, []))
            target = self.aliases.get(node.value.id)
            if target:
                return list(_File(target).module_consts.get(node.attr, []))
        return []


def _assign_targets(node):
    if isinstance(node, ast.Assign):
        return [t.id for t in node.targets if isinstance(t, ast.Name)]
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value:
        return [node.target.id]
    return []


def scan():
    """``(found, unresolved)``.

    ``found``: ``[(where, text)]`` — every subtitle text the source spells out, where
    ``where`` is ``"file.py:line"``, or ``"file.py:line Class.CONST"`` for a class
    constant (deduplicated by text per file; empty strings dropped, an empty subtitle
    hides nothing).
    ``unresolved``: ``{(file, expression)}`` — subtitle sources this scan cannot read as
    text (a parameter, a local variable, an f-string)."""
    found: list[tuple[str, str]] = []
    unresolved: set[tuple[str, str]] = set()
    for name in sorted(os.listdir(PAGES_DIR)):
        if not name.endswith(".py") or name in NOT_STUDIO_WIZARD:
            continue
        f = _File(os.path.join(PAGES_DIR, name))
        seen: set[str] = set()

        def add(where, texts, f=f, seen=seen):
            for t in texts:
                if t and t not in seen:
                    seen.add(t)
                    found.append((f"{f.name}:{where}", t))

        # class constants first, so a text that is also reached through
        # setSubTitle(self.SUBTITLE) is reported where it is written
        for line, qualname, value in f.class_subtitles:
            texts = f.resolve(value)
            if texts:
                add(f"{line} {qualname}", texts)
            else:
                unresolved.add((f.name, qualname))
        for node in ast.walk(f.tree):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "setSubTitle" and node.args):
                texts = f.resolve(node.args[0])
                if texts:
                    add(node.lineno, texts)
                else:
                    unresolved.add((f.name, ast.unparse(node.args[0])))
    return found, unresolved
