"""Turn terminal output into something a Qt console can render honestly.

The Studio runs real terminal tools — emerge, docker, make, playwright — and pipes them
into ``QPlainTextEdit``. Those tools do not emit plain text. They emit SGR colour, cursor
moves, erase-line, and carriage-return redraws, and a widget that just appends the raw
string shows the operator this:

    ``\\x1b[32;01m*\\x1b[0m dev-libs/foo``   instead of a green ``*``
    ``[ 43%]\\r[ 67%]\\r[ 91%]``              three stacked bars instead of one at 91%

which is both ugly and actively misleading — the escape noise obscures the very lines an
operator is scanning for, and a progress redraw that should occupy ONE line instead
floods the scrollback and pushes real output out of the bounded document.

This module is deliberately PURE and lives in ``core`` rather than ``gui``: it has no Qt
import, so it is testable headless (this repo's full GUI suite segfaults under the
offscreen platform, so anything that can be tested without Qt should be).

``\\r`` HANDLING is the part worth stating outright. A terminal treats carriage return as
"go back to column 0 and overwrite", so ``a\\rb`` displays as ``b``, not ``ab`` and not
two lines. Progress bars rely on it. Reproducing that faithfully is what collapses a
10 000-line emerge progress spew into the single line the operator actually wants.
"""

from __future__ import annotations

import html
import re

# Any CSI sequence. The final byte identifies the kind: 'm' is SGR (colour/style, which
# we render); everything else is cursor movement or erasure, which a scrollback widget
# has no cursor to honour and so is dropped.
_CSI_RE = re.compile(r"\x1b\[([0-9;:?]*)([A-Za-z])")
# OSC (window title etc.) — terminated by BEL or ST. Never renderable here.
_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
# Lone escapes and other two-byte sequences left over after the above.
_ESC_RE = re.compile(r"\x1b[@-Z\\-_]")
# Residual C0 controls after the sequence-level passes: a bare ESC that formed no
# complete sequence, plus BEL/BS/VT/FF/DEL. Qt has NO GLYPH for these and paints a box
# for each (an operator reported exactly that; one real 53 MB session log carried 351
# stray ESCs). TAB is spared — it is real layout in builder output and Qt renders it —
# and so is LF, which the reader has already split on but which must stay safe if a
# whole block is ever passed in. CR is handled before this, by the overwrite pass.
_C0_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

#: The 16 ANSI colours. Chosen to stay legible on BOTH a light and a dark console
#: background — notably the plain (non-bright) yellow and cyan, whose textbook values
#: (#808000-ish and pure #00ffff) are unreadable on one end or the other.
_BASE = {
    30: "#2e3436", 31: "#cc3333", 32: "#2e8b45", 33: "#a67c00",
    34: "#3465a4", 35: "#8b3a8b", 36: "#0f7b8a", 37: "#d3d7cf",
}
_BRIGHT = {
    90: "#6b6b6b", 91: "#ef5350", 92: "#4caf50", 93: "#d4a017",
    94: "#5c9ce6", 95: "#c86fc9", 96: "#26a69a", 97: "#ffffff",
}


def _xterm256(n: int) -> str:
    """The xterm 256-colour cube, as CSS."""
    if n < 8:
        return _BASE[30 + n]
    if n < 16:
        return _BRIGHT[90 + (n - 8)]
    if n < 232:
        n -= 16
        levels = (0, 95, 135, 175, 215, 255)
        return "#%02x%02x%02x" % (levels[n // 36], levels[(n // 6) % 6], levels[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


class _Style:
    __slots__ = ("fg", "bg", "bold", "italic", "underline", "inverse")

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.fg = self.bg = ""
        self.bold = self.italic = self.underline = self.inverse = False

    def css(self) -> str:
        fg, bg = self.fg, self.bg
        if self.inverse:
            # Inverse with only one side set still has to flip: falling back to the
            # widget's own colours is what makes `\x1b[7m` visible at all.
            fg, bg = bg or "#ffffff", fg or "#000000"
        parts = []
        if fg:
            parts.append(f"color:{fg}")
        if bg:
            parts.append(f"background-color:{bg}")
        if self.bold:
            parts.append("font-weight:600")
        if self.italic:
            parts.append("font-style:italic")
        if self.underline:
            parts.append("text-decoration:underline")
        return ";".join(parts)

    def apply(self, params: str) -> None:
        # An empty parameter list means SGR 0 (`\x1b[m` == `\x1b[0m`).
        codes = [int(p) for p in params.replace(":", ";").split(";") if p.isdigit()] or [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0:
                self.reset()
            elif c == 1:
                self.bold = True
            elif c == 3:
                self.italic = True
            elif c == 4:
                self.underline = True
            elif c == 7:
                self.inverse = True
            elif c in (21, 22):
                self.bold = False
            elif c == 23:
                self.italic = False
            elif c == 24:
                self.underline = False
            elif c == 27:
                self.inverse = False
            elif c in _BASE:
                self.fg = _BASE[c]
            elif c in _BRIGHT:
                self.fg = _BRIGHT[c]
            elif 40 <= c <= 47:
                self.bg = _BASE[c - 10]
            elif 100 <= c <= 107:
                self.bg = _BRIGHT[c - 10]
            elif c == 39:
                self.fg = ""
            elif c == 49:
                self.bg = ""
            elif c in (38, 48):
                # Extended colour: 5;N (256) or 2;R;G;B (truecolor).
                target = "fg" if c == 38 else "bg"
                if i + 1 < len(codes) and codes[i + 1] == 5 and i + 2 < len(codes):
                    setattr(self, target, _xterm256(codes[i + 2]))
                    i += 2
                elif i + 1 < len(codes) and codes[i + 1] == 2 and i + 4 < len(codes):
                    setattr(self, target, "#%02x%02x%02x"
                            % (codes[i + 2], codes[i + 3], codes[i + 4]))
                    i += 4
            i += 1


def strip_ansi(text: str) -> str:
    """Every printable character, no escapes. The plain-text fallback."""
    return _C0_RE.sub("", _ESC_RE.sub("", _CSI_RE.sub("", _OSC_RE.sub("", text))))


def collapse_carriage_returns(line: str) -> str:
    """Apply terminal overwrite semantics within ONE line.

    ``a\\rb`` is ``b``: the tool went back to column 0 and drew over what was there. A
    partial overwrite keeps the tail it did not reach, so ``12345\\rab`` is ``ab345`` —
    which matters because that is exactly how a shrinking progress counter behaves, and
    dropping the tail would silently truncate the line instead.
    """
    if "\r" not in line:
        return line
    out = ""
    for seg in line.split("\r"):
        out = seg + out[len(seg):] if len(seg) < len(out) else seg
    return out


def has_escapes(text: str) -> bool:
    """Cheap pre-check so the common (plain) line skips conversion entirely.

    Worth having: the merge console takes tens of thousands of lines from a long emerge,
    most of them uncoloured, and ``appendHtml`` costs materially more than
    ``appendPlainText``. This keeps the expensive path for the lines that need it.
    """
    return "\x1b" in text or "\r" in text


def to_html(text: str) -> str:
    """SGR-coloured text as HTML suitable for ``QPlainTextEdit.appendHtml``.

    Non-SGR sequences are dropped rather than rendered: a scrollback pane has no cursor
    for ``\\x1b[2A`` to move and no screen for ``\\x1b[2J`` to clear, so honouring them is
    meaningless while SHOWING them is noise.
    """
    text = collapse_carriage_returns(_OSC_RE.sub("", text))
    style = _Style()
    out: list[str] = []
    open_span = False
    pos = 0
    for m in _CSI_RE.finditer(text):
        chunk = _C0_RE.sub("", text[pos:m.start()])
        if chunk:
            out.append(html.escape(chunk))
        if m.group(2) == "m":
            css = None
            style.apply(m.group(1))
            css = style.css()
            if open_span:
                out.append("</span>")
                open_span = False
            if css:
                out.append(f'<span style="{css}">')
                open_span = True
        pos = m.end()
    tail = _C0_RE.sub("", _ESC_RE.sub("", text[pos:]))
    if tail:
        out.append(html.escape(tail))
    if open_span:
        out.append("</span>")
    # Leading/'  ' runs collapse in HTML, and build output is full of meaningful
    # indentation (nested make, portage's aligned columns), so preserve it explicitly.
    return "".join(out).replace("  ", "&nbsp; ")
