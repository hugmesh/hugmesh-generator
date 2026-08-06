"""ASK 14 — "studio options should be buttons not checkmarks to proceed".

The #507 lane already turned the wizard's pick-one screens into big clickable cards.
What it did not change is what a click MEANS: you picked a card, and then you still had
to find Next. This module closes that gap — on a pick-one page, **choosing is
proceeding**.

One function, deliberately: :func:`advance_on_choice`. It hangs off the group's
``buttonClicked`` — not ``buttonToggled`` — and that distinction is the whole design:

* ``buttonClicked`` fires only on a real activation (a mouse click, or Space/Enter on a
  focused card, which :class:`~.choice_cards.ChoiceCard` routes through ``click()``), so
  it means "the operator decided";
* ``buttonToggled`` also fires on ``setChecked(True)`` — which is how
  ``initializePage`` reflects a loaded config, how a Back-navigation restores an earlier
  answer, and how essentially every existing test selects an option. Navigating off
  those would make a config reload walk the wizard forward on its own.

Two guards make it safe to attach anywhere:

* **current-page only.** A click on a page the wizard is not showing (a test poking a
  constructed page, a stale window) never navigates.
* **isComplete() only.** Advancing never bypasses a page's own gate; if Next would be
  refused, the click selects and stops, exactly as before.

Qt duality: PySide6 in the venv, PyQt6 for the operator — the slot is exception-guarded
because an escaping exception in a PyQt6 slot calls qFatal and kills the Studio.
"""
from __future__ import annotations

import sys
import traceback

__all__ = ["advance_on_choice"]


def _log_swallowed(where: str) -> None:
    print(f"choice_nav: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def advance_on_choice(page, group, *, when=None) -> None:
    """Make a CLICK on any card in ``group`` commit ``page`` and advance the wizard.

    ``when(card) -> bool`` is an optional per-card veto for pages where some options
    mean "configure me first" rather than "go" (the IdP page's external providers are
    the live example — they open a window and only then proceed). Returning False
    leaves the card selected and the flow where it is.
    """
    def _on_clicked(card=None):
        try:
            wiz = page.wizard()
            if wiz is None or wiz.currentPage() is not page:
                return                      # not the page on screen: never navigate
            if when is not None and not when(card):
                return
            if not page.isComplete():
                return                      # never bypass the page's own gate
            wiz.next()
        except Exception:                   # pragma: no cover - defence in depth
            _log_swallowed("advance_on_choice")

    group.buttonClicked.connect(_on_clicked)
