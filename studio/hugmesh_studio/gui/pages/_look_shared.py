"""Two helpers the look editor shares with nothing else any more, kept apart from it
so the open-path lesson below lives in one small module.

History: these lived in ``_logintheme.py`` beside ``LoginThemeGroup`` (the old
mesh-wide "Themes" group) and its modeless ``ThemeEditorDialog``. On 2026-10-21 the
look moved to the Look tab of each domain (row 0 is the mesh's own), both hosts of the
group were removed, and the group and the dialog were deleted as dead code; only these
two functions were still used, by ``_lookeditor.py``.

HONESTY (unchanged): the "Preview in your browser" button writes ONE themed platform
page (the captured real login page plus representative panes painted from the same
``--sd-*`` tokens) and opens it in the operator's REAL browser, not QtWebEngine: that
exists under PySide6 (the test venv) and not under the operator's PyQt6, so a WebEngine
preview would pass every test and be dead on the machine that matters.
"""
from __future__ import annotations

from ..qt import QtCore, QtGui, QtWidgets
from ...core import login_preview, platform_preview, theme_presets


def populate_preset_combo(combo: QtWidgets.QComboBox) -> None:
    """Fill ``combo`` with the Custom row + the grouped presets (notes as tooltips).

    One population point, so no surface can offer a preset set the model would
    reject (the "GUI offers what the model rejects" defect class)."""
    combo.addItem("Custom (type colours below)", "")
    for group in theme_presets.groups():
        combo.insertSeparator(combo.count())
        for pr in theme_presets.PRESETS:
            if pr.group == group:
                combo.addItem(f"{group}: {pr.label}", pr.preset_id)
                if pr.note:
                    combo.setItemData(combo.count() - 1, pr.note,
                                      QtCore.Qt.ItemDataRole.ToolTipRole)


def open_platform_preview(css: str, note: QtWidgets.QLabel,
                          error_note: QtWidgets.QLabel, writer=None) -> None:
    """Write the themed PLATFORM preview for ``css`` and open it in the operator's
    browser, reporting what happened in ``note`` (green = verified, amber = dispatched
    but unverifiable, red = nothing launched) and a write failure in ``error_note``.

    Used by the LookEditor (the window's one look editor, on every route). The
    open-path lesson (this button's history IS "the preview isn't working"
    reports): the old order trusted QDesktopServices.openUrl FIRST and reported its True
    as success — but on Linux that True means "the launch was dispatched", not
    "something rendered" (xdg-open can exit 2 'no handler' a beat after Qt already
    returned true), so the Qt-free fallback never ran and the note lied green while the
    operator saw nothing. New order:
      1. login_preview.open_in_browser — VERIFIED openers (waits for the opener's own
         exit code);
      2. QDesktopServices.openUrl only as the LAST resort (portal-only desktops with no
         CLI opener), and its success is reported as UNVERIFIED;
      3. the note ALWAYS carries the file path + the mechanism used, so even a browser
         that never appears leaves the operator one manual open away — never a silent
         no-op, and the mechanism name makes the next failure report diagnosable.
    The file lands in login_preview.preview_out_dir() (~/.cache), NOT gettempdir():
    $TMPDIR can point into build scratch that portage sweeps mid-session, which deletes
    the preview before/while the browser reads it.

    ``writer(css, out_dir) -> path`` writes the page; the default is the platform
    preview, and the brand LookEditor passes the one that also draws the two web
    pictures."""
    note.setVisible(False)
    out_dir = login_preview.preview_out_dir()
    try:
        path = (writer or platform_preview.write_platform_preview)(css, out_dir)
    except (OSError, RuntimeError) as exc:
        error_note.setText(f"preview failed: {exc}")
        error_note.setVisible(True)
        return
    opened, how = login_preview.open_in_browser(path)
    if not opened and bool(
            QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(path))):
        opened, how = True, ("unverified: QDesktopServices.openUrl — Qt reports "
                             "the launch was dispatched, not that a browser "
                             "rendered anything")
    if opened and how.startswith("verified"):
        note.setStyleSheet("color: #2e7d32;")
        note.setText(f"Platform preview opened ({how}).\nFile: {path}")
    elif opened:
        # Dispatched but unverifiable — the historical lie, now labelled amber
        # with the manual path instead of claimed green.
        note.setStyleSheet("color: #a65d00;")
        note.setText(
            f"A browser open was dispatched but cannot be confirmed ({how}).\n"
            f"If no tab appeared, open this file manually:\n{path}\n"
            "(Linux: check `xdg-settings get default-web-browser` — a missing or "
            "non-browser handler is the usual cause of a silent no-op.)")
    else:
        note.setStyleSheet("color: #b00020;")
        note.setText(
            f"Could not launch a browser automatically ({how}).\n"
            f"Open this file manually:\n{path}")
    note.setVisible(True)
