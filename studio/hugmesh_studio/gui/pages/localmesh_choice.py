"""LocalMeshChoicePage — issue #334, part 1 of #333: "two buttons, not two tabs".

The local-mesh surface was the last pick-one control in the Studio still wearing a
QTabWidget. Everything else that forks a path — ModePage, IdpPage, DomainsChoicePage,
UsersChoicePage, LaunchPage, WelcomePage — is a screen of big clickable
:class:`~..choice_cards.ChoiceCard` tiles, and a tab bar is a worse control for the
same job: it is small, it reads as a view switch rather than a decision, and it
carries no room for the sentence that says what each path actually does.

Two cards, and they are the two things the tabs were:

* **Join an existing mesh with a key** — the token-based local node. Raises
  ``wiz.localmesh_join_selected`` and Next lands on ``LocalMeshJoinPage``, which is
  terminal (a joined node is the end of this path).
* **Generate a new mesh** — raises nothing, and Next walks the nine bring-up steps
  (Environment & brand -> Domains -> Domain services -> Repo source -> Services ->
  Identity provider -> Mesh overlay -> Saved meshes & review -> Bring-up & monitor).

WHAT THIS SCREEN COMMITS is one wizard-transient flag and nothing else. Like
``wiz.localmesh_selected`` (ModePage) it is deliberately NOT an ImageConfig field:
running a docker mesh is not an image mode, so cfg — and therefore every saved config
and every builder argv — never learns this screen exists. That is also why the whole
branch is skipped DYNAMICALLY (``applies_to``) rather than through
``MODE_SKIPPED_PAGES``, which is keyed by image mode.

THE DEFAULT IS "JOIN", by id. It is what the QTabWidget defaulted to (tab 0), so a
flow that walks straight through with no click lands where it always did. Selecting by
id rather than by position means a visual reorder cannot silently change which path
the no-pick default exercises — DomainsChoicePage's rule, same reason.

Choosing is proceeding (``choice_nav.advance_on_choice``): a real click on either card
commits and advances. It hangs off ``buttonClicked``, never ``buttonToggled``, so
``initializePage`` restoring an earlier answer never walks the wizard forward on its
own.

Qt duality: the venv is PySide6, the operator runs PyQt6 where an exception escaping a
slot calls qFatal — the one slot here is exception-guarded.
"""
from __future__ import annotations

import sys
import traceback

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..choice_nav import advance_on_choice
from ..qt import QtWidgets
from ._scroll import scrollable

# Existing registry glyphs, deliberately: "mesh" is the mesh you are joining, and
# "localmesh" is the local docker mesh this machine would generate. No new icon is
# added for this screen — a card whose meaning is already drawn should reuse the
# drawing rather than fork a near-identical one.
_ICONS = {"join": "mesh", "generate": "localmesh"}


def _log_swallowed(where: str) -> None:
    print(f"localmesh_choice: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class LocalMeshChoicePage(QtWidgets.QWizardPage):
    """Local Docker mesh: join one with a key, or generate a new one."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Local Docker mesh")
        self.setSubTitle(
            "Run a HugMesh mesh on THIS machine in Docker — no image build, no "
            "server hardware. Two ways in; pick one.")
        lay = scrollable(self)
        self.group = ChoiceCardGroup(self)
        self.choices = [
            ("join", "Join an existing mesh with a key",
             "Run a mesh NODE here and attach it to a mesh that already exists. Needs "
             "a tailnet/headscale auth key from that mesh. Nothing is generated and no "
             "credentials are minted — the mesh you join owns those."),
            ("generate", "Generate a new mesh",
             "Mint every credential from scratch and bring up the whole platform stack "
             "here, seeded with a fresh superadmin. A few steps of setup follow — "
             "environment, domains and their services, source, services, identity, "
             "then a plan you read before anything runs."),
        ]
        self._buttons: dict[str, ChoiceCard] = {}
        for i, (cid, title, desc) in enumerate(self.choices):
            card = ChoiceCard(title, desc, icon_name=_ICONS.get(cid, ""))
            card.setProperty("choice", cid)
            self.group.add_card(card, i)
            self._buttons[cid] = card
            lay.addWidget(card)
        # DEFAULT by id (see the module docstring): the tab bar this replaces opened
        # on the join tab, so an untouched flow keeps landing on the join surface.
        self._buttons["join"].setChecked(True)
        self.group.buttonToggled.connect(self._on_toggled)
        advance_on_choice(self, self.group)
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

    # ---- flow --------------------------------------------------------------------
    def applies_to(self, cfg) -> bool:      # noqa: ARG002 — the hook's fixed signature
        """On the flow only when ModePage picked the local docker mesh. Reads the
        wizard rather than cfg for the reason LocalMeshPage.applies_to gives: cfg.mode
        is only ever an IMAGE mode, and this branch emits no ImageConfig field at all,
        so the nextId() ALL-OPTIONS skip guard holds trivially."""
        return bool(getattr(self.wiz, "localmesh_selected", False))

    def isComplete(self) -> bool:
        return bool(self._selected())

    def initializePage(self):
        self._buttons["join" if getattr(self.wiz, "localmesh_join_selected", True)
                      else "generate"].setChecked(True)

    def validatePage(self):
        self.wiz.localmesh_join_selected = (self._selected() == "join")
        return True
