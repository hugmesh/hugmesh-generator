"""DomainsChoicePage — ASK 19, "domains at launch".

    "a choice-icon-button screen like the other major path screens — proceed with
     the single initial INTERNAL domain, or a button to the table screen for adding
     domains. On the default (internal only) go straight to the USERS button-choice
     screen."

Ask 8 already made the Domains/Users TABLES conditional; the opt-in itself was a
checkbox tucked into the Network step's mesh-control-plane group ("This mesh also
hosts other domains"). Ask 19 promotes that decision to its own screen in the
ModePage / IdpPage idiom: two big :class:`~..choice_cards.ChoiceCard` tiles with
right-aligned drawn-in-code icons. The checkbox is GONE — one decision, one place;
two controls for one flag is exactly the muddle these asks are about.

What each card commits:

* **Just this mesh's own domain** — ``cfg.additional_domains = False``. The Domains
  TABLE is skipped (``DomainsPage.applies_to`` -> ``superadmin_plane_applies``) and
  Next lands on the users choice screen, per the ask.
* **Add more domains** — ``cfg.additional_domains = True``; the table is reachable.

The emission guard ask 8 established stays here, in :meth:`validatePage`: choosing
"just this mesh's own domain" CLEARS ``cfg.domains``. The wizard may only skip a page
whose fields are at their mode-correct default (wizard.nextId's contract), and these
rows reach the cluster through the mesh MANIFEST, which has no such guard — so rows
typed while the other card was selected must be actively dropped, not merely hidden.

MESH ONLY (MODE_SKIPPED_PAGES): a cloud desktop client's domain is the FD-08
``--domains`` tie the image is built around, not an "additional" domain, so that flow
keeps its table unconditionally and never sees this screen.

Qt duality: the venv is PySide6, the operator runs PyQt6 where an exception escaping a
slot calls qFatal — the one slot here is exception-guarded.
"""
from __future__ import annotations

import sys
import traceback

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..qt import QtWidgets
from ._scroll import scrollable
from ...core.config import effective_domain_note

_ICONS = {"internal": "domain-internal", "more": "domain-add"}


def _log_swallowed(where: str) -> None:
    print(f"domains_choice: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class DomainsChoicePage(QtWidgets.QWizardPage):
    """Mesh: one internal domain, or a table of more."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Domains")
        self.setSubTitle(
            "This mesh already has its own domain. Choose whether it also hosts "
            "others — that is the only thing this screen decides.")
        lay = scrollable(self)
        self.group = ChoiceCardGroup(self)
        self.choices = [
            ("internal", "Just this mesh's own domain",
             ""),      # description is per-config: initializePage fills it in
            ("more", "Add more domains",
             "Open the domains table: name each additional domain this mesh serves, "
             "pick the optional services it provides, and choose which node images it "
             "attaches to. Each one automatically gets its own admin account."),
        ]
        self._buttons: dict[str, ChoiceCard] = {}
        for i, (cid, title, desc) in enumerate(self.choices):
            card = ChoiceCard(title, desc, icon_name=_ICONS.get(cid, ""))
            card.setProperty("choice", cid)
            self.group.add_card(card, i)
            self._buttons[cid] = card
            lay.addWidget(card)
        # DEFAULT is the internal-only path, BY ID (a visual reorder must not change
        # which choice the no-pick default exercises) — it is also ImageConfig's
        # additional_domains default, so an untouched flow emits exactly what it did.
        self._buttons["internal"].setChecked(True)
        self.group.buttonToggled.connect(self._on_toggled)
        lay.addStretch(1)

    # ---- slots (guarded: PyQt6 qFatals on an exception escaping a slot) -----------
    def _on_toggled(self, *_):
        try:
            self.completeChanged.emit()
        except Exception:                     # noqa: BLE001 — see module docstring
            _log_swallowed("_on_toggled")

    def _selected(self) -> str:
        btn = self.group.checkedButton()
        return btn.property("choice") if btn is not None else ""

    def isComplete(self) -> bool:
        return bool(self._selected())

    def initializePage(self):
        c = self.wiz.cfg
        # The internal card NAMES the domains it means, so "internal only" is never an
        # abstraction: the cluster domain the Network step set, and the Tailscale
        # root domain every node joins (derived <brand>.internal when left blank).
        self._buttons["internal"].setAccessibleDescription(effective_domain_note(c))
        self._buttons["internal"].set_description(effective_domain_note(c))
        self._buttons["more" if c.additional_domains else "internal"].setChecked(True)

    def validatePage(self):
        c = self.wiz.cfg
        c.additional_domains = (self._selected() == "more")
        if not c.additional_domains:
            # ASK 8's emission guard, now owned by the screen that owns the decision:
            # a skipped table must leave nothing behind for mesh_manifest() to publish.
            c.domains = []
        return True
