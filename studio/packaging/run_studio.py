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
    # Redirected to a file, a pipe or NUL on Windows, stdout is the ANSI code page
    # (cp1252), so the first character outside it (an arrow in a status line, a model's
    # answer) raised UnicodeEncodeError mid-output. UTF-8, as on Linux. NOT gated on
    # isatty(): NUL is a character device, so isatty() is True there and the stream is
    # still cp1252. A real console's writer is already UTF-16 inside, so reconfiguring
    # it changes nothing; the windowed exe has no stream at all. Linux is left as is.
    if sys.platform == "win32":
        for stream in (sys.stdout, sys.stderr):
            if stream is not None:
                stream.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
