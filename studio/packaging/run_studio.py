"""PyInstaller entry script.

``hugmesh_studio/__main__.py`` CANNOT be used as the frozen entry point: it does
``from .app import main``, and PyInstaller runs its entry script as a TOP-LEVEL
module, where a relative import raises

    ImportError: attempted relative import with no known parent package

The recipe in studio/README.md pointed at ``__main__.py`` and failed on exactly this.
This shim imports absolutely instead, which works both frozen and from a checkout.
"""
import sys

from hugmesh_studio.app import main

if __name__ == "__main__":
    # Redirected to a file or pipe on Windows, stdout is the ANSI code page (cp1252)
    # with strict errors, so the first non-ASCII character (an em dash in a status
    # line, a model's answer) raised UnicodeEncodeError mid-output. UTF-8, as on Linux.
    # A console keeps its own Unicode writer, and the windowed exe has no stream at all.
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and not stream.isatty():
            stream.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
