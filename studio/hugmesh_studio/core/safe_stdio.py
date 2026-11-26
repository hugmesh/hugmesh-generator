"""Make the Studio's text output survive a stream that cannot spell it (Qt-free, stdlib only).

The command lines and the text UI print "·", "—", "→", box lines, and whatever a person
typed into a label or a path. On a stream whose encoding is ASCII (``LANG=C`` with
Python's UTF-8 mode off, ``PYTHONIOENCODING=ascii``) or a legacy 8-bit code page
(latin-1, cp1252 on a redirected Windows stream), the first character the stream cannot
encode raised ``UnicodeEncodeError`` out of ``print()``:

    ``--show-session``   died on the "·" of every session label,
    the text UI          died on the "—" of its own welcome line.

Python's default error handler for a text stream is ``strict`` (``surrogateescape`` in the C
locale), and neither survives a character the codec lacks. :func:`install` swaps it, on
stdout and stderr, for one that never raises:

* a stream that can spell every character (UTF-8, UTF-16, ...) keeps its handler, except
  that ``strict`` becomes ``replace`` (a lone surrogate from an undecodable file name
  printed as ``?``, not as a traceback);
* any other stream gets :data:`HANDLER`, which writes the ASCII look-alike of the
  character (``—`` as ``-``, ``→`` as ``->``, ``é`` as ``e``) and ``?`` for what has none
  (``Ł``, Cyrillic, CJK). The same idea as scripts/build-menu.sh's ``_u``, which folds
  its menu labels for a non-UTF-8 locale.

The ENCODING is never changed here: a terminal that does take UTF-8 keeps getting it, and
Windows keeps its own switch to UTF-8 (``app.utf8_stdio``). Only what happens to a
character the stream cannot encode changes. ``core/entry.bootstrap()`` calls
:func:`install`, so every process entry (the window, the text UI, each module command
line) gets it from the one hook that tests/test_entry_bootstrap.py already makes them all
call.
"""
from __future__ import annotations

import codecs
import sys
import unicodedata

__all__ = ["HANDLER", "ascii_text", "install"]

#: The codec error handler's name, usable as ``errors=`` on any text stream or encode().
HANDLER = "hugmesh-ascii"

#: Characters the Studio's own text uses (measured over app.py, core/ and tui/), with the
#: ASCII it folds to. Anything not listed folds through its Unicode decomposition
#: (``é`` to ``e``, ``²`` to ``2``) and then to ``?``.
_FOLD = {
    "\u2500": "-", "\u2550": "=", "\u2502": "|", "\u2551": "|",  # box lines
    "\u2014": "-", "\u2013": "-", "\u2212": "-",  # em/en dash, minus
    "\u2026": "...", "\u00b7": "|", "\u2022": "*",  # ellipsis, middle dot, bullet
    "\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"',  # curly quotes
    "\u2192": "->", "\u2190": "<-", "\u21d2": "=>",  # arrows
    "\u00d7": "x", "\u2265": ">=", "\u2264": "<=", "\u2208": "in",  # maths
    "\u2044": "/", "\u00a7": "sec.",  # fraction slash, section sign
    "\u2714": "+", "\u2718": "x",  # check mark, ballot x
    "\u00a0": " ",  # no-break space
}


def _ascii_for(ch: str) -> str:
    """The ASCII spelling of one character: its table entry, else what it decomposes to
    with the accents dropped, else ``?``."""
    if ch in _FOLD:
        return _FOLD[ch]
    out = []
    for part in unicodedata.normalize("NFKD", ch):
        if part in _FOLD:
            out.append(_FOLD[part])
        elif ord(part) < 128:
            out.append(part)
        elif not unicodedata.combining(part):
            out.append("?")
    return "".join(out) or "?"


def _fold_error(exc: UnicodeError):
    """The codec error handler behind :data:`HANDLER`."""
    if not isinstance(exc, UnicodeEncodeError):
        raise exc
    return "".join(_ascii_for(ch) for ch in exc.object[exc.start:exc.end]), exc.end


codecs.register_error(HANDLER, _fold_error)


def ascii_text(text: str) -> str:
    """``text`` as pure ASCII, folded the way :data:`HANDLER` folds a stream's output."""
    return text.encode("ascii", HANDLER).decode("ascii")


def _spells_everything(encoding: str) -> bool:
    """True for a codec that can encode every character (the UTF family, GB 18030)."""
    try:
        name = codecs.lookup(encoding).name
    except (LookupError, TypeError):
        return False
    return name.startswith("utf-") or name == "gb18030"


def install(streams=None) -> None:
    """Make stdout and stderr (or ``streams``) never raise on a character they cannot
    encode. See the module docstring for the rule. Idempotent, and a no-op on a stream
    that is missing (the windowed exe's ``None``) or cannot be reconfigured (a test's
    ``StringIO``). ``streams`` is for the tests."""
    for stream in (sys.stdout, sys.stderr) if streams is None else streams:
        encoding = getattr(stream, "encoding", None)
        errors = getattr(stream, "errors", None)
        if not encoding or not errors:
            continue
        if _spells_everything(encoding):
            wanted = "replace" if errors == "strict" else errors
        else:
            wanted = HANDLER
        if wanted == errors:
            continue
        try:
            stream.reconfigure(errors=wanted)
        except (AttributeError, ValueError, OSError):
            pass
