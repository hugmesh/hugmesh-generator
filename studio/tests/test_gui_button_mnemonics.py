"""Button and group-box labels must not carry a bare '&' (GUI-23).

Qt reads a single '&' in the text of a QPushButton, QCheckBox or QRadioButton, and in
the title of a QGroupBox, as a MNEMONIC marker: the ampersand is not drawn, the next
character is underlined, and Alt+<that character> is bound. The key-zip step's
"Import & apply" button rendered as "Import _apply" (the space underlined, Alt+Space
grabbed) on both the cloud and the mesh path. No label in this GUI is an accelerator,
so a literal ampersand is always spelled '&&' ("Generate && start", "Vaults && volumes…").

This extends test_pages_network_sections.py::test_section_titles_are_not_eaten_as_mnemonics.
That test pins the Collapsible header and the "Services && Apps" group box one widget
at a time, so it could not see a third case on a page it never builds. The scan below
reads every literal handed to one of the four constructors under hugmesh_studio/gui/.
It is pure AST and needs no Qt binding, so it runs in the Qt-free GitHub job, where the
network-sections module is skipped. The behavioural check on the real KeyZipPage at
the bottom needs a binding and skips without one.

REACH, stated: the scan reads string literals passed directly to a constructor, either
positionally or as text=/title=. That covers a plain constant, f-string text, both arms
of a conditional, '+' concatenation, a '%' template and a "...".format() template. It
does NOT read text set later through setText()/setTitle(). A receiver-blind setter scan
is all false positives here: QWizardPage.setTitle and QLabel.setText draw '&' as-is.
It also does not read a name bound elsewhere (QRadioButton(IMAGE_MODE_TITLES[mid])), a
label passed through a helper that builds the button (_local_ai_dock's QPushButton(text)),
a constructor reached through an alias (Btn = QtWidgets.QCheckBox), or the result of any
other call ("Services & Apps".replace("&", "&&") is correct and must not be flagged).
"""
from __future__ import annotations

import ast
import os
from collections import Counter
from types import SimpleNamespace

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUI_DIR = os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui")

#: The widgets whose label Qt parses for a mnemonic. QAbstractButton.setText binds
#: QKeySequence.mnemonic(text); QGroupBox paints its title with Qt.TextShowMnemonic.
MNEMONIC_CLASSES = frozenset({"QPushButton", "QCheckBox", "QGroupBox", "QRadioButton"})

#: Stands in for any part of a label the source does not spell out (an f-string hole,
#: a variable, a call). It is not '&', so it can neither create nor hide a marker.
_HOLE = "\x00"


def has_bare_ampersand(text: str) -> bool:
    """True when Qt would take an '&' in ``text`` as a mnemonic marker.

    '&&' is the escape for one literal ampersand. Any '&' left once those pairs are
    removed is a marker: "&&&x" draws "&" and then binds Alt+X."""
    return "&" in text.replace("&&", "")


def _label_texts(node: ast.expr) -> list[str]:
    """Every literal text ``node`` can evaluate to, with unknown parts as _HOLE."""
    if isinstance(node, ast.Constant):
        return [node.value] if isinstance(node.value, str) else [_HOLE]
    if isinstance(node, ast.JoinedStr):
        return ["".join(v.value if isinstance(v, ast.Constant) else _HOLE
                        for v in node.values)]
    if isinstance(node, ast.IfExp):
        return _label_texts(node.body) + _label_texts(node.orelse)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return [a + b for a in _label_texts(node.left) for b in _label_texts(node.right)]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
        return _label_texts(node.left)               # the "%s" template is the label
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "format"
            and isinstance(node.func.value, (ast.Constant, ast.JoinedStr))):
        return _label_texts(node.func.value)         # "... {} ...".format(x)
    return [_HOLE]                                   # any other call, name, subscript…


def scan_source(source: str, filename: str = "<src>") -> list[tuple[int, str, str]]:
    """(line, class, text) for every literal label handed to a MNEMONIC_CLASSES
    constructor in ``source``. Labels with no literal part at all are left out."""
    seen = []
    for node in ast.walk(ast.parse(source, filename)):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = (func.attr if isinstance(func, ast.Attribute)
                else func.id if isinstance(func, ast.Name) else None)
        if name not in MNEMONIC_CLASSES:
            continue
        exprs = list(node.args) + [k.value for k in node.keywords
                                   if k.arg in ("text", "title")]
        for expr in exprs:
            for text in _label_texts(expr):
                if text.strip(_HOLE):
                    seen.append((node.lineno, name, text))
    return seen


def scan_tree(root: str) -> list[tuple[str, int, str, str]]:
    """(path relative to ``root``, line, class, text) over every .py file under it."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith(".py"):
                continue
            path = os.path.join(dirpath, fn)
            with open(path, encoding="utf-8") as fh:
                source = fh.read()
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            found += [(rel, line, cls, text)
                      for line, cls, text in scan_source(source, path)]
    return found


# ------------------------------------------------------------------- the tree-wide pin

def test_no_button_or_group_box_literal_carries_a_bare_ampersand():
    bare = [f"  {rel}:{line}: {cls}({text!r})"
            for rel, line, cls, text in scan_tree(GUI_DIR) if has_bare_ampersand(text)]
    assert not bare, (
        "Qt reads a single '&' in these labels as a mnemonic: the ampersand is not "
        "drawn and the next character is underlined (\"Import & apply\" rendered as "
        "\"Import _apply\"). Spell a literal ampersand '&&':\n" + "\n".join(bare))


def test_the_scan_is_not_vacuous():
    """A scan that silently reads nothing passes forever. Pin that it reaches all four
    classes, the known escaped labels, and the GUI-23 site itself."""
    seen = scan_tree(GUI_DIR)
    per_class = Counter(cls for _rel, _line, cls, _text in seen)
    # spelled out, not MNEMONIC_CLASSES: dropping a class from that set must go red here
    assert set(per_class) == {"QPushButton", "QCheckBox", "QGroupBox", "QRadioButton"}, \
        per_class
    # Measured 2026-11-11: 365 literals (QPushButton 200, QCheckBox 85, QGroupBox 72,
    # QRadioButton 8). The floor is loose on purpose; it catches "found nothing".
    assert len(seen) >= 150, per_class
    labels = {(rel, cls, text) for rel, _line, cls, text in seen}
    assert ("pages/localmesh.py", "QPushButton", "Generate && start") in labels
    assert ("pages/localmesh.py", "QPushButton", "Vaults && volumes…") in labels
    assert ("pages/keyzip.py", "QPushButton", "Import && apply") in labels, (
        "the GUI-23 button is no longer a literal the scan can read")


@pytest.mark.parametrize("snippet", [
    'QtWidgets.QPushButton("Import & apply")',
    'QtWidgets.QCheckBox("Keys & certs")',
    'QtWidgets.QGroupBox("Services & Apps", self)',
    'QtWidgets.QRadioButton("Paste & go")',
    'QPushButton("Import & apply")',                       # imported by name
    'QtWidgets.QPushButton(icon, "Import & apply")',       # the (icon, text) overload
    'QtWidgets.QGroupBox(title="Services & Apps")',
    'QtWidgets.QPushButton(text="Import & apply")',
    'QtWidgets.QPushButton(f"{n} keys & certs")',
    'QtWidgets.QPushButton("Stop" if up else "Start & watch")',
    'QtWidgets.QPushButton("Import " + what + " & apply")',
    'QtWidgets.QPushButton("Import %s & apply" % what)',
    'QtWidgets.QPushButton("Import {} & apply".format(what))',
    'QtWidgets.QPushButton("A &&& B")',
])
def test_the_scan_flags_every_shape(snippet):
    seen = scan_source(snippet)
    assert seen and any(has_bare_ampersand(t) for _l, _c, t in seen), seen


@pytest.mark.parametrize("snippet", [
    'QtWidgets.QPushButton("Import && apply")',
    'QtWidgets.QPushButton(f"{a} && {b}")',
    # a call's RESULT is not a literal: this is network.py's correct escape
    'QtWidgets.QGroupBox("Services & Apps".replace("&", "&&"))',
    'QtWidgets.QLabel("Keys & certs")',                    # a QLabel draws '&' as-is
    'QtWidgets.QPushButton("Import", toolTip="keys & certs")',   # a tooltip is not text
    'page.setTitle("Domains & their services")',           # QWizardPage title
])
def test_the_scan_leaves_correct_labels_alone(snippet):
    assert not any(has_bare_ampersand(t) for _l, _c, t in scan_source(snippet))


@pytest.mark.parametrize("text, bare", [
    ("Import & apply", True), ("Import && apply", False), ("&&&x", True),
    ("A &&&& B", False), ("&Next", True), ("no ampersand", False), ("", False),
])
def test_has_bare_ampersand(text, bare):
    assert has_bare_ampersand(text) is bare


# ------------------------------------------------- the real page, where Qt is present

def test_the_key_zip_import_button_draws_its_ampersand():
    """Behavioural, on the real KeyZipPage: the button shows "Import & apply", binds no
    shortcut, and is measured as wide as that text, not as "Import  apply"."""
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.gui.pages.keyzip import KeyZipPage
    from hugmesh_studio.gui.qt import QtGui, QtWidgets, Qt

    _app = (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))
    page = KeyZipPage(SimpleNamespace(cfg=ImageConfig(), generator_dir="."))
    try:
        imports = [b for b in page.findChildren(QtWidgets.QPushButton)
                   if b.text().replace("&", "").startswith("Import")]
        assert len(imports) == 1, [b.text() for b in imports]
        btn = imports[0]
        assert btn.text() == "Import && apply"
        # QAbstractButton.setText binds QKeySequence.mnemonic(text): Alt+Space for the
        # bare '&' (macOS turns mnemonics off, but this suite does not run there).
        assert btn.shortcut().isEmpty(), btn.shortcut().toString()
        # Geometry: QPushButton.sizeHint measures its text with Qt.TextShowMnemonic, so
        # this is the width the button actually reserves and draws.
        fm = QtGui.QFontMetrics(btn.font())
        drawn = fm.size(int(Qt.TextFlag.TextShowMnemonic.value), btn.text()).width()
        assert drawn == fm.size(0, "Import & apply").width()
        assert drawn != fm.size(0, "Import  apply").width(), "font cannot tell them apart"
        # …and no other button or group box on the page binds a mnemonic either.
        for b in page.findChildren(QtWidgets.QAbstractButton):
            assert b.shortcut().isEmpty(), (b.text(), b.shortcut().toString())
        for g in page.findChildren(QtWidgets.QGroupBox):
            assert not has_bare_ampersand(g.title()), g.title()
    finally:
        page.deleteLater()
