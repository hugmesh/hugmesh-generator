"""hugmesh_studio.tui — the host-side terminal UI (parity lane, issue #51 phase 1).

A thin terminal face over :mod:`hugmesh_studio.core` — the same Qt-free model and
CLI-arg composer the GUI drives — mirroring the on-device whiptail pattern
(``scripts/build-menu.sh``): decide ONCE whether the rich renderer is usable, and
when it is not, degrade to a plain numbered-prompt loop instead of crashing.

The rich renderer here is **urwid** and it is OPTIONAL — a soft dependency, exactly
like whiptail is for the menu:

* ``NO_TUI=1`` forces the plain fallback (the menu's own env knob, reused verbatim);
* no interactive TTY, ``TERM=dumb``, or urwid not importable all degrade the same way;
* importing this package NEVER imports urwid (or Qt) — the urwid face lives in
  :mod:`.urwid_ui` and is imported lazily, only after :func:`.app.have_tui` said yes.

On Gentoo urwid is ~arch-keyworded; accepting it is one line::

    echo "dev-python/urwid ~amd64" >> /etc/portage/package.accept_keywords/hugmesh-studio

Entry point::

    python -m hugmesh_studio.tui              # sessions review (build history)
    python -m hugmesh_studio.tui --worklist SESSION_ID   # read-only worklist table
    NO_TUI=1 python -m hugmesh_studio.tui     # force the plain-prompt fallback

Phase-1 flows (the #49 audit's GUI-only capabilities, closed here first):

* **sessions review** — the durable build-session records (core/build_sessions.py):
  per-session status (crash-honest, ``is_stale`` rendered but never written back),
  the artifact listing, and delete-with-confirm;
* **worklist table** — a read-only view of an existing session's mesh worklist
  (rows + per-image status). The full wizard is a later phase.
"""
