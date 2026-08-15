"""How the Studio decodes the output of the tools it runs.

WHY THIS EXISTS. Every console in the Studio is fed by a ``subprocess`` opened in text
mode. ``text=True`` alone does NOT mean UTF-8 — it means
``locale.getpreferredencoding(False)``, which is whatever the process that launched the
Studio happened to have set. A desktop launcher, a systemd unit, an ssh session or a
``su`` all routinely hand it ``C``/``POSIX``, and then Python decodes tool output as
**ASCII** and raises

    UnicodeDecodeError: 'ascii' codec can't decode byte 0xe2 in position 31

the first time a byte above 0x7F appears. Iterating ``for line in proc.stdout`` raises
that from inside the read, so the failure is not a garbled character — it TEARS DOWN the
reader mid-build, and the console simply stops.

That is not a rare input. GCC quotes every diagnostic with U+2018/U+2019
(``warning: unused variable 'x'`` is really ``'x'`` in curly quotes), portage draws box
characters, and ebuild metadata carries accented author names — so an emerge build hits
it almost immediately, and a plain ``docker build`` usually does not. That asymmetry is
why it reads as intermittent.

The emerge LOG tailer already got this right (``emerge_packages._poll_pkg`` reads bytes
and decodes per line with ``errors="replace"``, on the stated rule that a mis-encoded
byte "must degrade one cell, never raise into the caller's timer"). The live PROCESS
streams never received the same treatment. This module is that rule, in one place, so
the two paths cannot drift again.

USE ``TEXT_IO`` for anything whose output reaches a console or is parsed line-by-line.
It is deliberately NOT a wrapper around ``Popen``/``run``: the call sites differ too much
(pipes, timeouts, process groups, askpass env) and hiding those behind a helper would be
a worse trade than passing three explicit kwargs.
"""

from __future__ import annotations

#: Decoding for every subprocess whose output the Studio reads as text.
#:
#: ``errors="replace"`` rather than ``"strict"``: a build tool that emits one bad byte
#: has not failed, and losing the rest of a two-hour emerge because of it is a far worse
#: outcome than one U+FFFD in the log. Rather than ``"ignore"`` because a visible
#: replacement character is a signal the operator can act on, where silent deletion turns
#: a corrupted line into a plausible-looking wrong one.
TEXT_IO = {"encoding": "utf-8", "errors": "replace"}
