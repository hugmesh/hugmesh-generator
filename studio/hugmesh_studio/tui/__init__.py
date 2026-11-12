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

    python -m hugmesh_studio.tui              # the guided journey (welcome first)
    python -m hugmesh_studio.tui --sessions   # sessions review (build history)
    python -m hugmesh_studio.tui --worklist SESSION_ID   # read-only worklist table
    python -m hugmesh_studio.tui --meshemu SESSION_NAME  # whole-mesh emulation list
    NO_TUI=1 python -m hugmesh_studio.tui     # force the plain-prompt fallback

Phase-1 flows (the #49 audit's GUI-only capabilities, closed here first):

* **sessions review** — the durable build-session records (core/build_sessions.py):
  per-session status (crash-honest, ``is_stale`` rendered but never written back),
  the artifact listing, and delete-with-confirm;
* **worklist table** — a read-only view of an existing session's mesh worklist
  (rows + per-image status).

Phase 2 — the JOURNEY (:mod:`.journey`): the GUI wizard's canonical page order
(``config.WIZARD_PAGE_SLUGS``, consumed — never copied) walked as one prompt
flow, catching the TUI up to the GUI features merged after the scaffold:

* the **welcome flow** with its three journey entry points and the
  journey-ordered mode menu (GUI PR #67);
* the **Themes screen** (:mod:`.themes` — a screen, not a popup; GUI PR #63);
* the **Local AI** status line on every screen and the Local AI screen (:mod:`.local_ai`;
  F2 in the urwid face, ``local-ai`` in either) — the terminal twin of the Studio window's
  Local AI bar, over the same Qt-free ``core.local_ai_status``;
* the **create-nodes-for-local-cloud** abbreviated wizard (:mod:`.localcloud`,
  GUI PR #65) with the laptop+node worklist restriction;
* the **whole-mesh emulation** per-device status list with copy-ready ssh /
  web-tunnel / whole-mesh-save hints (:mod:`.meshemu`, GUI PR #69) — the DEPLOY
  lane of an emulation plan;
* the **run e2e tests** screen (:mod:`.e2e`) — the mode-menu card that replaced
  "QEMU device tests" on 2026-08-27: the three catalogued e2e environments
  (docker / kind / qemu) with each one's copy-ready ``SNAP_ENV=… make …`` line
  and start hint, all authored by ``core.e2e_environments``;
* the **QEMU device tests** screen (:mod:`.qemu`) — the TEST lane of that same
  plan: planned rows, the exact runner argv, and the verdict table
  ``core.emulation`` grades (PASS / FAIL / NO-RESULT / SUSPECT / STALE). Its own
  menu card is gone; the e2e screen's ``d`` key is its door, mirroring the GUI's
  second radio arm exactly;
* the per-domain **Sign-in choice** on the domains step (:mod:`.domains_step`,
  GUI PR #71).

Both emulation screens are READ-ONLY toward the host by design: they plan and
they read, and everything that would spawn a guest, a container or an ssh is
printed as a copy-ready command built by ``core.emulation``'s single argv
authors. That is a deliberate scope decision for a terminal face, not a gap.

Steps not ported yet say so honestly and keep the config's defaults — the walk
still ends in a saveable config the GUI/CLI can build.
"""
