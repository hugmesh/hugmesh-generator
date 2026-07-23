"""Qt enum scoping — PyQt6 vs PySide6 (the 2026-07-17 crash-on-Build class).

PySide6 exposes enum members BOTH on the class (``QWizard.BackButton``) and on the
scoped type (``QWizard.WizardButton.BackButton``). **PyQt6 exposes only the scoped
form.** This repo supports both bindings (studio/README: "PySide6 (or use an existing
PyQt6)") and the test venv runs PySide6 — so an unscoped access sails through CI and
then AttributeErrors on a PyQt6 user's machine. Because an unhandled exception inside a
Qt slot ABORTS the process, that is not a soft failure: it crashed the Studio on Build
for every PyQt6 user, with a green suite.

This guard is a SOURCE GREP, deliberately binding-independent: it fails under PySide6
too, which is the only way it could have caught the original bug.
"""
import pathlib
import re

import pytest

_PKG = pathlib.Path(__file__).resolve().parents[1] / "hugmesh_studio"

# (class, scoped enum type, members) triples: the enum members most easily reached
# unscoped, and the scope they really live under (i.e. what the fix looks like). A class
# may appear more than once — ``Qt`` alone carries many scopes.
_UNSCOPED = [
    ("QWizard", "WizardButton", ("BackButton", "NextButton", "CommitButton",
                                 "FinishButton", "CancelButton", "HelpButton",
                                 "CustomButton1", "CustomButton2", "CustomButton3",
                                 "Stretch", "NoButton")),
    ("QDialogButtonBox", "StandardButton", ("Ok", "Cancel", "Yes", "No", "Apply",
                                            "Close", "Save", "Reset")),
    ("QMessageBox", "StandardButton", ("Ok", "Cancel", "Yes", "No")),
    # ── Qt.* scopes exercised by the progress page's log panel (2026-07-17) ──
    ("Qt", "ArrowType", ("NoArrow", "UpArrow", "DownArrow", "LeftArrow", "RightArrow")),
    ("Qt", "Orientation", ("Horizontal", "Vertical")),
    ("Qt", "WindowType", ("Window", "Dialog", "Tool", "Popup", "SubWindow",
                          "FramelessWindowHint", "WindowStaysOnTopHint")),
    ("Qt", "TextInteractionFlag", ("NoTextInteraction", "TextSelectableByMouse",
                                   "TextSelectableByKeyboard", "TextEditorInteraction",
                                   "TextBrowserInteraction", "LinksAccessibleByMouse")),
    ("Qt", "WidgetAttribute", ("WA_DeleteOnClose", "WA_StyledBackground",
                               "WA_TransparentForMouseEvents")),
    ("QSizePolicy", "Policy", ("Fixed", "Minimum", "Maximum", "Preferred",
                               "Expanding", "MinimumExpanding", "Ignored")),
    # ── added by fix/studio-wizard-ux (2026-07-17): worklist columns + collapsibles ──
    ("QHeaderView", "ResizeMode", ("Interactive", "Fixed", "Stretch", "ResizeToContents",
                                   "Custom")),
    ("QToolButton", "ToolButtonPopupMode", ("DelayedPopup", "MenuButtonPopup",
                                            "InstantPopup")),
    ("Qt", "ToolButtonStyle", ("ToolButtonIconOnly", "ToolButtonTextOnly",
                               "ToolButtonTextBesideIcon", "ToolButtonTextUnderIcon",
                               "ToolButtonFollowStyle")),
    ("Qt", "CheckState", ("Unchecked", "PartiallyChecked", "Checked")),
    # ── added with the web-login-theme group (2026-07-18): swatch alignment ──
    ("Qt", "AlignmentFlag", ("AlignLeft", "AlignRight", "AlignHCenter", "AlignVCenter",
                             "AlignCenter", "AlignTop", "AlignBottom", "AlignJustify")),
]


def _sources():
    return sorted(_PKG.rglob("*.py"))


@pytest.mark.parametrize("cls,scope,members", _UNSCOPED)
def test_no_unscoped_qt_enum_access(cls, scope, members):
    # `QWizard.BackButton` but NOT `QWizard.WizardButton.BackButton`
    pat = re.compile(rf"\b{cls}\.(?!{scope}\b)({'|'.join(members)})\b")
    bad = []
    for f in _sources():
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue                      # a comment naming the bad form is fine
            m = pat.search(line)
            if m:
                bad.append(f"{f.relative_to(_PKG.parent)}:{i}: {cls}.{m.group(1)} "
                           f"-> use {cls}.{scope}.{m.group(1)} (PyQt6 has no {cls}.{m.group(1)})")
    assert not bad, "unscoped Qt enum access crashes PyQt6 at runtime:\n  " + "\n  ".join(bad)


# NOTE (conflict resolution, 2026-07-17): fix/studio-wizard-ux carried a SECOND
# structure (_UNSCOPED_QT_NS) + its own scanning test for the Qt.* namespace. #399
# landed first and folds Qt.* into the SINGLE _UNSCOPED list as ("Qt", scope,
# members) entries, which the parametrized test above already scans with the
# identical regex — so that test was an exact duplicate and is dropped, and this
# branch's four new Qt scopes were folded into the list instead. The Qt.* NON-
# VACUITY check below is kept: it hardcodes its pattern and guards the Qt.* half.


def test_the_qt_namespace_guard_bites():
    """Non-vacuity for the Qt.* half."""
    pat = re.compile(r"\bQt\.(?!ArrowType\b)(DownArrow|RightArrow)\b")
    assert pat.search("btn.setArrowType(Qt.DownArrow)")                  # the bug shape
    assert not pat.search("btn.setArrowType(Qt.ArrowType.DownArrow)")    # the fix


def test_the_guard_itself_bites():
    """Non-vacuity: the pattern must actually match the shape that shipped the crash."""
    scope, members = next((s, m) for c, s, m in _UNSCOPED if c == "QWizard")
    pat = re.compile(rf"\bQWizard\.(?!{scope}\b)({'|'.join(members)})\b")
    assert pat.search("btn = wiz.button(QtWidgets.QWizard.BackButton)")      # the bug
    assert not pat.search("btn = wiz.button(QtWidgets.QWizard.WizardButton.BackButton)")  # the fix


def test_the_guard_covers_the_new_log_panel_enums():
    """Non-vacuity for the Qt.* scopes the detachable log panel added: the unscoped form
    of each must be caught (PyQt6 exposes only the scoped one)."""
    for cls, scope, member, bad in (
            ("Qt", "ArrowType", "DownArrow", "btn.setArrowType(Qt.DownArrow)"),
            ("Qt", "Orientation", "Vertical", "QSplitter(Qt.Vertical)"),
            ("Qt", "WindowType", "Window", "QWidget(parent, Qt.Window)"),
            ("Qt", "TextInteractionFlag", "TextSelectableByMouse",
             "lb.setTextInteractionFlags(Qt.TextSelectableByMouse)")):
        members = next(m for c, s, m in _UNSCOPED if c == cls and s == scope)
        pat = re.compile(rf"\b{cls}\.(?!{scope}\b)({'|'.join(members)})\b")
        assert pat.search(bad), bad
        assert not pat.search(bad.replace(f"{cls}.{member}", f"{cls}.{scope}.{member}"))
