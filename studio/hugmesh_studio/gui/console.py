"""One consistent look — and one consistent write path — for every console pane.

The Studio grew about a dozen output panes independently (build, progress, deploy,
phone, fleet, quest, golive, localmesh, sessions, tray). They were all a bare
``QPlainTextEdit`` fed by ``appendPlainText``, which meant three things:

  * escape codes showed as literal ``\\x1b[32;01m`` garbage, worst exactly where an
    operator is scanning for the coloured lines a tool went to the trouble of colouring;
  * carriage-return progress redraws stacked into thousands of lines, pushing real
    output out of the bounded document;
  * each pane picked its own font (or none), so the same emerge output rendered in a
    proportional face in one place and monospace in another — and portage's aligned
    columns are unreadable in a proportional face.

``attach`` fixes all three in one call and is the only thing a page needs to adopt.

PERFORMANCE IS PART OF THE DESIGN, not an afterthought. ``appendHtml`` parses rich text
and costs materially more than ``appendPlainText``, and this pane takes tens of thousands
of lines from a long emerge. So ``write`` checks for escapes first and takes the plain
path for the overwhelming majority of lines that have none — the expensive path is
reserved for lines that actually carry colour.
"""

from __future__ import annotations

from ..core import ansi
from .qt import QtGui, QtWidgets

#: Scrollback cap. A QPlainTextEdit document grows without bound otherwise, and every
#: repaint pays for the whole document — an hours-long emerge is millions of blocks.
DEFAULT_MAX_BLOCKS = 5000


def console_font() -> QtGui.QFont:
    """A real fixed-pitch face.

    ``StyleHint(Monospace)`` alone is not enough on every platform, so the family is
    also asked for explicitly and ``setFixedPitch`` set — portage aligns USE-flag columns
    with spaces, and those columns are meaningless in a proportional face.
    """
    font = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
    font.setStyleHint(QtGui.QFont.StyleHint.Monospace)
    font.setFixedPitch(True)
    return font


def attach(widget: QtWidgets.QPlainTextEdit,
           max_blocks: int = DEFAULT_MAX_BLOCKS) -> QtWidgets.QPlainTextEdit:
    """Make ``widget`` a console: monospace, read-only, bounded, no word wrap.

    Wrapping is off because build output is column-aligned and a wrapped 200-character
    compiler line destroys that alignment; a horizontal scrollbar is the honest trade.
    Returns the widget so it can be used inline at construction.
    """
    widget.setReadOnly(True)
    widget.setFont(console_font())
    widget.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
    widget.setMaximumBlockCount(max_blocks)
    return widget


def write(widget: QtWidgets.QPlainTextEdit, text: str) -> None:
    """Append one line, rendering colour and honouring carriage-return overwrite.

    Safe to call with anything a build tool emits. Falls back to plain text whenever the
    line has no escapes at all, which is the common case.
    """
    if not ansi.has_escapes(text):
        widget.appendPlainText(text)
        return
    widget.appendHtml(ansi.to_html(text))


def write_batch(widget: QtWidgets.QPlainTextEdit,
                raw_lines: list[str], plain_lines: list[str]) -> None:
    """Append a whole drained batch, colouring only if the batch actually needs it.

    The merge console drains on a timer and appends the batch in ONE call, because one
    append per line is what made an earlier version stutter under a parallel emerge. That
    property has to survive colour: when no line in the batch carries an escape — the
    overwhelming majority of batches — this is byte-for-byte the single
    ``appendPlainText`` it replaced. Only a batch with real colour in it pays per line.

    ``plain_lines`` is passed alongside rather than re-derived so the caller's ALREADY
    sanitised text is reused; that text also feeds the session record and the stage
    tracker, and those must keep receiving plain text, not markup.
    """
    if not plain_lines:
        return
    if not any(ansi.has_escapes(r) for r in raw_lines):
        widget.appendPlainText("\n".join(plain_lines))
        return
    for raw, plain in zip(raw_lines, plain_lines):
        if ansi.has_escapes(raw):
            widget.appendHtml(ansi.to_html(raw))
        else:
            widget.appendPlainText(plain)


def write_plain(widget: QtWidgets.QPlainTextEdit, text: str) -> None:
    """Append with escapes STRIPPED rather than rendered.

    For panes whose content is later read back as text (copied into a bug report, diffed,
    or matched by a test): rendering to HTML would make the document's plain text differ
    from what was written.
    """
    widget.appendPlainText(ansi.strip_ansi(ansi.collapse_carriage_returns(text)))
