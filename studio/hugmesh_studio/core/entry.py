"""What EVERY process entry of the Studio does first (Qt-free, stdlib only).

The Studio has more than one front door: the window (``app.main``), the text UI
(``python -m hugmesh_studio.tui`` -> ``tui/app.py:main``) and the module command lines
(``python -m hugmesh_studio.core.emulation``, ``...core.cloud_deploy`` and the rest:
every file with an ``if __name__ == "__main__"`` block). They all probe for tools and
start the generator's scripts, so they all need the same process environment.

On a Mac that environment is not the one the process was given. Homebrew does not put
its GNU tools on a shell's PATH: they live in ``<prefix>/opt/<formula>/libexec/gnubin``,
and an app opened from Finder does not even get Homebrew's ``bin``.
``macos_host.install()`` puts them back, and it used to be called from ``app.main``
only. So a Mac that HAD run the ``brew install`` line was still refused by the text UI
and by every module command line ("this Mac is missing gnu-sed, coreutils, ..."), in a
sentence that ends "you do not need to change your shell or PATH: the Studio puts
Homebrew's GNU tools first", which was untrue there. And past the gate, the scripts
those entries start would have run BSD sed and find.

:func:`bootstrap` is that call, in one place, so a second per-host fix has one place
to go and every entry gets it. tests/test_entry_bootstrap.py reads every ``__main__``
block in the package and fails when one does not call it.

The PATH half is deliberately macOS-only today. The window's other two hooks
(``no_console`` for the MSI, ``flatpak_host`` for the sandbox) stay where they are in
``app.main``: moving them here would change what the text UI does on Windows and inside
the Flatpak, which is a separate decision with its own proof.

The other half is every host's: ``safe_stdio.install()``, so that a stdout or stderr that
cannot encode a character (``LANG=C``, ``PYTHONIOENCODING=ascii``, a legacy code page)
prints an ASCII look-alike instead of raising ``UnicodeEncodeError`` out of ``print()``.
It changes only what happens to a character the stream cannot spell, never the stream's
encoding, so it is safe in every entry. The command lines and the text UI died on their
own "·" and "—" before it; tests/test_safe_stdio.py.
"""
from __future__ import annotations

from . import macos_host, safe_stdio

__all__ = ["bootstrap"]


def bootstrap() -> list[str]:
    """Run before anything prints, looks a tool up on PATH or starts a process.
    Idempotent. Makes stdout/stderr unable to raise on a character they cannot encode,
    and on macOS puts Homebrew's tools on PATH. Returns what ``macos_host.install()``
    added to PATH (empty off macOS)."""
    safe_stdio.install()
    return macos_host.install()
