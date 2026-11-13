"""Split a typed TUI command line into words, keeping a Windows path whole.

``shlex.split`` is POSIX shell syntax: a backslash escapes the next character, so on
native Windows ``k 1 C:\\Users\\ann\\root.crt`` reached the Domain CA keys step as
``C:Usersannroot.crt`` ("cannot read ..."), and the Desktop step's ``pass=FILE`` the
same way (found 2026-11-13 by running the suite on Windows 11). There a backslash is
the path separator, never an escape: quotes still group a path with spaces
(``"C:\\My Keys\\ca.key"``) and are removed, as they are on Linux, where nothing
changes. ``osname`` is ``os.name`` unless a test passes another.
"""
from __future__ import annotations

import os
import shlex


def split(line: str, osname: str | None = None) -> list[str]:
    """The words of ``line``. Raises ``ValueError`` on an unclosed quote, as
    ``shlex.split`` does."""
    if (os.name if osname is None else osname) != "nt":
        return shlex.split(line)
    lex = shlex.shlex(line, posix=True)
    lex.whitespace_split = True
    lex.commenters = ""
    lex.escape = ""          # a backslash is a path separator here, not an escape
    return list(lex)
