"""Read a JSON file the operator may have edited by hand (Qt-free).

On Windows the editors at hand do not write plain UTF-8: Notepad saves UTF-8 WITH a byte
order mark, and Windows PowerShell's ``Out-File`` / ``>`` write UTF-16. ``open(path,
encoding="utf-8")`` then hands json a leading U+FEFF (or a NUL every other byte) and the
load fails, which "Load config" reported as nothing at all. The Studio still WRITES plain
UTF-8; this only widens what it accepts.
"""
from __future__ import annotations

import codecs
import json


def decode(raw: bytes) -> str:
    """UTF-16 when the file says so with a BOM, otherwise UTF-8 with an optional BOM."""
    if raw.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        return raw.decode("utf-16")
    return raw.decode("utf-8-sig")


def load(path: str):
    with open(path, "rb") as fh:
        return json.loads(decode(fh.read()))


def load_problem(path: str, exc: BaseException) -> str:
    """The sentence a "Load config" gives when ``path`` did not load. A file that is not
    UTF-8 gets a fix as well as the codec's words: Windows PowerShell 5.1's
    ``Set-Content`` writes the ANSI code page, which a hostname with an accent breaks.
    It names what :func:`decode` accepts, not "UTF-16": a UTF-16 file without a byte
    order mark is read as UTF-8 too, and fails here with an accent in it. One sentence
    for every face (the window's dialog and the text UI's status line)."""
    if isinstance(exc, UnicodeDecodeError):
        return (f"{path} could not be loaded: it is not UTF-8 text, nor UTF-16 with a "
                f"byte order mark ({exc}). Save it again as UTF-8 and load it once more.")
    return f"{path} could not be loaded: {exc}"
