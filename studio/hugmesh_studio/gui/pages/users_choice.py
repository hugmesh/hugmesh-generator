"""UsersChoicePage — ASK 20, "users at launch".

    "a big icon button to proceed with the MINIMAL needed users in the default config
     — AND THE BUTTON ITSELF must state which users get generated and where the
     credentials will be found when it is done — plus another big icon button to the
     configure-superusers / domain-users TABLE screen. On the default internal-only
     path, go to SYSTEM IDENTITY."

The load-bearing half of this ask is the CARD TEXT, and it is only worth anything if it
is true. Every claim below is read off the real key channel rather than written to
sound reassuring:

* the accounts are minted by ``scripts/gen-provision-keys.sh``, which
  :class:`~...core.worklist_driver.WorklistDriver._generate_keys` runs after each
  successful NODE build with ``--role <profile> --out <out>/keys-<entry id> --random``;
* only the ``pki`` PROFILE writes ``users.json`` — one privileged account, ``admin``
  (gen-provision-keys.sh:50 ``ADMIN="admin"``). ``omnibus`` and jetson ``full`` map onto
  that profile too (``worklist_driver.KEY_PROFILE``); every other node role is a WORKER,
  and its arm ends ``rm -f "${OUT_DIR}/users.json"`` — keys only, NO accounts (:993);
* the password is ``openssl rand -base64 18``, stored SALTED+HASHED and deliberately
  never printed (:894-896) — so the credential an operator actually uses is the PRIVATE
  SSH KEY written beside it, ``ssh/admin_ed25519`` (:1000);
* root login is LOCKED unless ``--root-password`` is passed, which the Studio does not
  pass (:923);
* per-DOMAIN admins are a different channel again: they are issued at provisioning from
  the mesh manifest, which is why they are named on the Domains step, not here;
* and the FOLDER is composed from the same two functions the runtime uses —
  ``build_sessions.session_workdir`` (what ProgressPage hands the driver as ``workdir``)
  and ``worklist_driver.keys_dir`` (what ``_generate_keys`` joins onto it). It used to
  print ``<out>/keys-<id>``, which is where the keys land on a HEADLESS run and nowhere
  a GUI operator would ever look: every GUI dispatch passes a per-session workdir, so
  the real folder is ``<out>/sessions/<id>/keys-<entry id>``.

So the card names the account, the file, the folder and the caveat — and
:meth:`initializePage` recomputes it from the CURRENT worklist every visit, so the ids
it prints are the rows the operator actually checked.

The second card commits ``cfg.configure_users = True``, which is the only thing that
makes the Users TABLE reachable in mesh (``config.users_table_applies``). Choosing the
generated accounts CLEARS ``cfg.users`` — the same emission guard the domains choice
screen carries, for the same reason (the table's channel is the mesh manifest, which has
no skip contract of its own).

MESH ONLY (MODE_SKIPPED_PAGES): a cloud client's Users table carries the FD-08
person-role/domain tie and stays unconditional.
"""
from __future__ import annotations

import os
import sys
import traceback

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..qt import QtWidgets
from ._scroll import scrollable
from ...core.build_sessions import session_workdir
from ...core.config import image_class
from ...core.worklist_driver import key_profile, keys_dir

_ICONS = {"generated": "users-generated", "table": "users-table"}

# The gen-provision-keys.sh profile that writes users.json at all (its `pki` arm); every
# other profile is a worker and deletes it. Mirrored here, not guessed: KEY_PROFILE maps
# the Studio role ids onto the script's profiles.
_ACCOUNT_PROFILE = "pki"
# gen-provision-keys.sh:50 — ADMIN="admin", the -u/--admin default the Studio never
# overrides (worklist_driver builds the argv without -u).
_ADMIN_ACCOUNT = "admin"

# The one path segment this card CANNOT know yet: the build session's id is minted at
# dispatch (ProgressPage -> build_sessions.new_session), long after this screen. Naming
# the folder without it would be a lie of omission — every GUI run lands its keys under
# <out>/sessions/<id>/, never <out>/ — so the placeholder is spelled out and explained
# instead of quietly dropped.
_SESSION_ID_PLACEHOLDER = "<session id>"


def default_accounts_keys_dir(wiz, entry_id: str) -> str:
    """Where ``keys-<entry id>`` will actually be written for a GUI run, with the
    not-yet-minted session id left as :data:`_SESSION_ID_PLACEHOLDER`.

    Composed from the SAME two functions the runtime uses — ``build_sessions
    .session_workdir`` (what ProgressPage passes to the driver as ``workdir``) and
    ``worklist_driver.keys_dir`` (what ``_generate_keys`` joins onto ``_output_dir()``)
    — so the card cannot drift from the writer. It previously named
    ``<out>/keys-<id>``, which is where the keys land only on a headless run with no
    session workdir; on the GUI path, the only path that reaches this card, they never
    land there.
    """
    out = (wiz.cfg.output_dir or os.path.join(getattr(wiz, "generator_dir", ""), "out"))
    return keys_dir(session_workdir(out, _SESSION_ID_PLACEHOLDER), entry_id)


def _log_swallowed(where: str) -> None:
    print(f"users_choice: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


def default_accounts_summary(wiz) -> str:
    """The generated-accounts card's text: WHICH accounts, and WHERE the credentials
    land, for the worklist actually selected. Pure (reads config/worklist, touches no
    widget and no disk) so a test can assert the claim without painting anything."""
    cfg = wiz.cfg
    wl = getattr(wiz, "worklist", None)
    entries = list(wl.entries) if wl is not None else []
    nodes = [e for e in entries if image_class(cfg.mode, e.role) == "node"]
    with_accounts = [e.id for e in nodes if key_profile(e.role, e.platform) == _ACCOUNT_PROFILE]
    keys_only = [e.id for e in nodes if e.id not in with_accounts]
    where = with_accounts[0] if with_accounts else "<control-plane node>"
    parts = [
        f"Creates ONE login: ‘{_ADMIN_ACCOUNT}’ on "
        + (", ".join(with_accounts) if with_accounts
           else "the control-plane (pki/omnibus) node — none is selected yet, so no "
                "account would be created")
        + ". Its password is generated at random, stored salted + hashed and never "
          "printed. In this generated key set root login stays LOCKED "
          "(users.json .root.locked) — separate from the optional baked root password "
          "on the System step, which is a different channel.",
        f"You will find the credentials in {default_accounts_keys_dir(wiz, where)}/ — "
        f"users.json (the hashes) and ssh/{_ADMIN_ACCOUNT}_ed25519, the private key you "
        f"actually log in with: ssh -i ssh/{_ADMIN_ACCOUNT}_ed25519 "
        f"{_ADMIN_ACCOUNT}@<node>. Each run gets its own folder — "
        f"{_SESSION_ID_PLACEHOLDER} is minted when the build starts and appears in the "
        f"-w path of the build command on the Review screen.",
    ]
    if keys_only:
        parts.append("The other nodes (" + ", ".join(keys_only) +
                     ") get keys only — no accounts; they take their config from the "
                     "control-plane node.")
    parts.append("Needs ‘Generate node key-zips’ left on at the Review step, which is "
                 "the default.")
    return " ".join(parts)


class UsersChoicePage(QtWidgets.QWizardPage):
    """Mesh: the generated default accounts, or name your own."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Users")
        self.setSubTitle(
            "Who can sign in to this mesh once it is up. The default needs no table: "
            "the key folder built beside each node image carries the accounts.")
        lay = scrollable(self)
        self.group = ChoiceCardGroup(self)
        self.choices = [
            ("generated", "Use the accounts generated with the node keys",
             ""),       # per-config: initializePage fills it from the real key channel
            ("table", "Name superusers and domain users myself",
             "Open the users table: add named accounts, pick each one's domain and role "
             "(superadmins are locked to the orchestration domain), and choose how each "
             "first signs in — Discord, Gmail, or a password issued at provisioning. "
             "These are seeded into the mesh's identity provider, alongside the "
             "generated node login above."),
        ]
        self._buttons: dict[str, ChoiceCard] = {}
        for i, (cid, title, desc) in enumerate(self.choices):
            card = ChoiceCard(title, desc, icon_name=_ICONS.get(cid, ""))
            card.setProperty("choice", cid)
            self.group.add_card(card, i)
            self._buttons[cid] = card
            lay.addWidget(card)
        # default = the generated accounts (ImageConfig.configure_users default False),
        # by id rather than index — same rule as every other choice screen.
        self._buttons["generated"].setChecked(True)
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
        # recomputed EVERY visit: a Back to the worklist step changes which node ids
        # (and therefore which key folders) this card is talking about.
        self._buttons["generated"].set_description(default_accounts_summary(self.wiz))
        self._buttons["table" if c.configure_users else "generated"].setChecked(True)

    def validatePage(self):
        c = self.wiz.cfg
        c.configure_users = (self._selected() == "table")
        if not c.configure_users:
            # emission guard (ask 8's rule, ask 20's screen): the table is skipped, so
            # rows typed before the choice changed must not reach the mesh manifest.
            c.users = []
        return True
