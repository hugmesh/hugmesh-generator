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
    sys.exit(main())
