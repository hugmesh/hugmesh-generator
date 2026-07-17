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

_PKG = pathlib.Path(__file__).resolve().parents[1] / "snapdragon_studio"

# Qt classes whose enum members are commonly reached unscoped. The VALUE is the scoped
# enum type the member really lives under, i.e. what the fix looks like.
_UNSCOPED = {
    "QWizard": ("WizardButton", ("BackButton", "NextButton", "CommitButton",
                                 "FinishButton", "CancelButton", "HelpButton",
                                 "CustomButton1", "CustomButton2", "CustomButton3",
                                 "Stretch", "NoButton")),
    "QDialogButtonBox": ("StandardButton", ("Ok", "Cancel", "Yes", "No", "Apply",
                                            "Close", "Save", "Reset")),
    "QMessageBox": ("StandardButton", ("Ok", "Cancel", "Yes", "No")),
}


def _sources():
    return sorted(_PKG.rglob("*.py"))


@pytest.mark.parametrize("cls,scope_members", sorted(_UNSCOPED.items()))
def test_no_unscoped_qt_enum_access(cls, scope_members):
    scope, members = scope_members
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


def test_the_guard_itself_bites():
    """Non-vacuity: the pattern must actually match the shape that shipped the crash."""
    scope, members = _UNSCOPED["QWizard"]
    pat = re.compile(rf"\bQWizard\.(?!{scope}\b)({'|'.join(members)})\b")
    assert pat.search("btn = wiz.button(QtWidgets.QWizard.BackButton)")      # the bug
    assert not pat.search("btn = wiz.button(QtWidgets.QWizard.WizardButton.BackButton)")  # the fix
