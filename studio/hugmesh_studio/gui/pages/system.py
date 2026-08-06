"""SystemPage — the identity BAKED INTO THIS IMAGE.

Three families, in the order an operator meets them:

1. **Host identity** (``-H``/``-T``/``-u``; G26) — hostname, timezone, default account.
   ASK 9: all three arrive PRESELECTED with what the build would produce anyway
   (``core.config.derive_hostname`` / ``derive_default_user`` transcribe the builders'
   own role switches; the timezone comes from this build host via ``core.timezones``),
   and the timezone is a DROPDOWN over the host's real tz database rather than a free
   text box a typo can ruin.
2. **Who the image is built for** (``--person-role``; G18) — ASK 7. Moved here from the
   bottom of the superadmin Users TABLE, where a per-IMAGE build-time control sat under
   an "Add user / Remove selected" button row and read as "which of the accounts above
   owns this". It belongs with the other things baked into the image; see
   ``_PERSON_ROLE_*`` below for the label/description rewrite and
   ``config.person_role_applies`` for the reachability gate that replaces "show it and
   let the builder warn-and-ignore it".
3. **Node fallback login** (``--user-password``/``--root-password``; G27) — ASK 10: an
   explicit OPT-IN, unchecked by default, whose password fields do not exist on screen
   until it is ticked and are wiped the moment it is un-ticked.

Kept separate from NetworkPage (mesh/brand plane) and HomePage (local login /
encryption). Registration: StudioWizard/WIZARD_PAGE_SLUGS register this page under the
slug "system" (between "users" and "home") — the page itself only needs a wiz-like
object exposing ``.cfg``, so tests can instantiate it directly.

Qt duality: the venv is PySide6 but the operator runs PyQt6, where an exception escaping
a slot calls qFatal and kills the Studio. Every slot here (`_optin_toggled`,
`_person_role_changed`) is exception-guarded for that reason.
"""
from __future__ import annotations

import sys
import traceback
from types import SimpleNamespace

from ..qt import Qt, QtWidgets
from ...core import timezones
from ...core.config import (
    PERSON_ROLE_CHOICES, derive_default_user, derive_hostname, image_class,
    person_role_applies,
)
from ._gating import clear_unsupported, gate_widgets, gate_widgets_role_class, platform_supports
from ._widgets import _row

# Node fallback creds are only MEANINGFUL when an x86 node-class image is being built
# (the mesh flow — gated on the worklist's checked entries, see _node_creds_apply). On
# a personal Standalone or a cloud desktop — all desktop-class — the group is HIDDEN
# entirely (spec 3, mirroring #348's "hide inapplicable options"), not shown
# greyed/irrelevant.
_NODE_CREDS_REASON = (
    "Node fallback login applies to mesh NODE images only — a desktop image logs in "
    "with the local user set on the Home step. Hidden here; reappears on the mesh flow.")

# ── ask 7 — the person-role rewrite ──────────────────────────────────────────────────
# Old label, verbatim: "This device's person role". Nothing on the page said what a
# "person role" was, what it decided, or that it is baked at BUILD time; the only
# explanation was a tooltip, which is the exact failure mode NetworkPage's tri-state
# legend already documents ("the meaning existed only as a hover tooltip, which nobody
# hovers").
#
# What the value ACTUALLY does today, verified against origin/main rather than against
# the intent in the docs:
#   * build-x86-host-stage4.sh:4102 writes it to /etc/hugmesh/identity-role inside the
#     `elif ${ROLE_CLIENT}` branch — i.e. person-device images only;
#   * `superadmin` (and only superadmin, and only when NOT --standalone) ALSO bakes
#     /etc/hugmesh/device-password-required (:4121-4122). That marker IS consumed:
#     specs/etc/keys-provision/provision.sh:394 makes the device demand a SEPARATE
#     device password at first boot from a salted+hashed value on the KEYS USB. A real
#     hardening behaviour, not a label;
#   * it tags the ARTIFACT FILENAME: ROLE_TAG="${ROLE}-${PERSON_ROLE}${-domain}" (:5732,
#     and the build plan line :1839);
#   * on a cluster NODE role the builder warns "--person-role/--domains are ignored"
#     (:1594-1595), and --unaffiliated hard-CONFLICTS with it (:1340).
#
# AND WHAT IT DOES NOT DO, which the first cut of this page claimed: the identity-role
# marker is NOT read by the shipped first-boot path. `git grep identity-role` finds one
# writer (the builder), one reader (tests/qemu/verify-client.sh:199, a verification
# probe), and nothing in specs/etc/keys-provision/provision.sh — which reads the SIBLING
# `domains` marker, not this one, to render the desktop-governance tie
# (docs/CLIENT-IMAGES.md:98). CLIENT-IMAGES.md is explicit that the Casdoor desktop
# login is still future work ("A later provision_casdoor_desktop() will wire the OIDC
# desktop login"). So the text below says "stamped ... nothing reads it yet", because
# telling an operator it binds their account today would be inventing a semantic — the
# exact thing ask 7 asks us not to do.
_PERSON_ROLE_LABEL = "Account tier of the person this image is for"

_PERSON_ROLE_INTRO = (
    "Stamped into the image at build time as /etc/hugmesh/identity-role and into the "
    "artifact's filename, so you can tell whose device an image is. It GRANTS nothing: "
    "the actual rights live on the account in the identity provider, and nothing in the "
    "first-boot provisioning reads this marker yet. The ONE tier that changes what gets "
    "built is superadmin — see below.")

# Per-option prose. Shown live under the picker (and as the item tooltip) — never
# tooltip-only. 'derive' is listed first because it is the historical default.
_PERSON_ROLE_HELP = {
    "derive": ("Decide it for me — the first user's role from the Users step on a mesh "
               "desktop client, or superadmin on a mesh build. Nothing is passed to the "
               "builder, which defaults a client image to 'user'."),
    "user": ("Ordinary member. Signs in and uses the mesh; no administrative surfaces. "
             "Label only — this tier changes nothing about the image."),
    "mod": ("Moderator. Community/content moderation powers on top of an ordinary "
            "member. Label only — this tier changes nothing about the image."),
    "admin": ("Domain administrator. Runs ONE domain — its users, its services. Label "
              "only — this tier changes nothing about the image."),
    "superadmin": ("Whole-mesh owner. THE ONE TIER THAT CHANGES THE IMAGE: the device "
                   "demands a SEPARATE device password at first boot, taken from a "
                   "salted+hashed value on the KEYS USB and never baked into the image. "
                   "(Not applied to a standalone desktop, which has no mesh account.)"),
}

_PERSON_ROLE_HIDDEN_REASON = (
    "Only person-device images carry an account tier. This image is a cluster node (or "
    "an unaffiliated/standalone desktop), where the builder warns that --person-role is "
    "ignored — so the wizard does not offer a knob whose value would be discarded.")

# ── ask 9 — what the three identity fields say when they are prefilled ────────────────
_IDENTITY_HINT = (
    "Prefilled with exactly what this build would produce if you left them blank — the "
    "hostname and account name come from the builder's own defaults for this role and "
    "board, the timezone from this machine. Edit any of them to override.")

_MESH_HOSTNAME_NOTE = (
    "Mesh builds bake ONE hostname per image and the worklist builds several, so this "
    "is left blank on purpose: each node takes its own role-derived name — {names}. "
    "Typing a hostname here would give EVERY node in the worklist that same name.")

_MESH_USER_NOTE = (
    "Mesh builds bake ONE default account per image and the boards in this worklist do "
    "not agree on it, so this is left blank on purpose: each node keeps its own "
    "builder DEFAULT_USER — {names}. Typing a name here would give EVERY node in the "
    "worklist that same account, overriding each board's own default.")


def _muted(text: str) -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet("color: gray;")
    return lab


def _log_swallowed(where: str) -> None:
    """A guarded slot failed: record it loudly on stderr but keep the Studio alive —
    under PyQt6 the alternative is qFatal killing the whole process."""
    print(f"system page: swallowed exception in {where}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)


class SystemPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("System identity")
        self.setSubTitle("The host identity baked into this node/desktop image — "
                         "hostname, timezone, default account and who the image is for.")
        lay = QtWidgets.QVBoxLayout(self)
        lay.addWidget(_muted(_IDENTITY_HINT))
        self.hostname = QtWidgets.QLineEdit()
        self.hostname.setPlaceholderText("Leave blank to use the role-derived hostname")
        self.hostname.setToolTip("Sets the baked hostname — the -H/--hostname builder flag.")
        lay.addWidget(_row("Hostname", self.hostname))
        # Shown only on a multi-image mesh worklist, where prefilling ONE hostname would
        # name every node the same thing (ask 9's honest arm — see _seed_hostname).
        self.hostname_note = QtWidgets.QLabel("")
        self.hostname_note.setWordWrap(True)
        self.hostname_note.setStyleSheet("color: #a65d00;")
        self.hostname_note.setVisible(False)
        lay.addWidget(self.hostname_note)
        # ASK 9: a DROPDOWN over the host's real tz database (core/timezones reads
        # /usr/share/zoneinfo through the stdlib at runtime — no network, no bundled
        # list), not a free-text box. Non-editable on purpose: an editable combo is
        # still free text, which is what the operator asked to be rid of. Qt's
        # type-ahead search makes a ~600-entry list navigable from the keyboard.
        self.timezone = QtWidgets.QComboBox()
        self._zones = timezones.available()
        self.timezone.addItems(self._zones)
        self.timezone.setToolTip("Sets the system timezone — the -T/--timezone builder flag.")
        lay.addWidget(_row("Timezone", self.timezone))
        self.user = QtWidgets.QLineEdit()
        self.user.setPlaceholderText("Default account name (leave blank for the builder default)")
        self.user.setToolTip("The baked default account — the -u/--user builder flag "
                             "(distinct from --local-user).")
        lay.addWidget(_row("Default user", self.user))
        # The default-account twin of hostname_note: shown only where the worklist's
        # boards derive DIFFERENT accounts, which is exactly where a single prefilled
        # value would override each ARM builder's own DEFAULT_USER (see _seed_user).
        self.user_note = QtWidgets.QLabel("")
        self.user_note.setWordWrap(True)
        self.user_note.setStyleSheet("color: #a65d00;")
        self.user_note.setVisible(False)
        lay.addWidget(self.user_note)

        # ── ask 7: the person-role picker, in its own titled group ───────────────────
        self.person_box = QtWidgets.QGroupBox("Who this image is for")
        pl = QtWidgets.QVBoxLayout(self.person_box)
        pl.addWidget(_muted(_PERSON_ROLE_INTRO))
        self.person_role = QtWidgets.QComboBox()
        self.person_role.addItems(("derive", *PERSON_ROLE_CHOICES))
        for i in range(self.person_role.count()):
            self.person_role.setItemData(
                i, _PERSON_ROLE_HELP.get(self.person_role.itemText(i), ""),
                Qt.ItemDataRole.ToolTipRole)
        self.person_role.setToolTip(
            "The person-role this CLIENT image is tied to at build time "
            "(--person-role). 'derive' = users[0]'s role in cloud mode, "
            "superadmin in mesh mode. Ignored by the builder on cluster NODE roles.")
        self.person_role_row = _row(_PERSON_ROLE_LABEL, self.person_role)
        pl.addWidget(self.person_role_row)
        # The chosen option's consequence, ON THE PAGE — the whole point of ask 7.
        self.person_role_help = _muted("")
        pl.addWidget(self.person_role_help)
        self.person_role.currentTextChanged.connect(self._person_role_changed)
        lay.addWidget(self.person_box)

        # ── node FALLBACK credentials (G27) ──────────────────────────────────────────
        # Without these, a GUI-built mesh fleet ships the builder's DEFAULT credentials.
        # x86 only — rpi5's equivalents are deprecated no-ops. Shown ONLY on the mesh
        # (node-class) flow; hidden on desktop images (spec 3 clarity narrowing).
        self.creds = QtWidgets.QGroupBox("Node fallback login (mesh nodes)")
        cl = QtWidgets.QVBoxLayout(self.creds)
        # ASK 10: the OPT-IN. Unchecked by default; the password fields below do not
        # exist on screen until it is ticked. Never pre-filled, never logged, and
        # un-ticking wipes both boxes (see _optin_toggled) so a value typed and then
        # abandoned cannot be submitted from a hidden field.
        self.creds_optin = QtWidgets.QCheckBox(
            "Set console/rescue passwords for these node images")
        cl.addWidget(self.creds_optin)
        cl.addWidget(_muted(
            "Off by default: the mesh signs in through SSO, so a node normally needs no "
            "local login at all. Tick this only if you want a fallback console/rescue "
            "login on the node images you are building."))
        self.creds_fields = QtWidgets.QWidget()
        fl = QtWidgets.QVBoxLayout(self.creds_fields)
        fl.setContentsMargins(0, 0, 0, 0)
        self.creds_note = QtWidgets.QLabel(
            "Sets the baked USER and ROOT account passwords for the mesh node images "
            "you are building. x86 nodes only; hashed at build time; never written to a "
            "saved config, and cleared if you un-tick the box above.")
        self.creds_note.setWordWrap(True)
        fl.addWidget(self.creds_note)
        self.user_password = QtWidgets.QLineEdit()
        self.user_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.user_password.setPlaceholderText("hashed at build time; NOT saved to configs")
        fl.addWidget(_row("User password", self.user_password))
        self.root_password = QtWidgets.QLineEdit()
        self.root_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.root_password.setPlaceholderText("hashed at build time; NOT saved to configs")
        fl.addWidget(_row("Root password", self.root_password))
        self.creds_fields.setVisible(False)          # ask 10: hidden until opted in
        cl.addWidget(self.creds_fields)
        self.creds_optin.toggled.connect(self._optin_toggled)
        lay.addWidget(self.creds)
        lay.addStretch(1)

    # ---- slots (guarded: PyQt6 qFatals on an exception escaping a slot) --------------
    def _optin_toggled(self, on: bool) -> None:
        """Show/hide the credential fields, and WIPE them when the opt-in goes off.

        The wipe is the security half of ask 10: without it a password typed, then
        de-selected, would sit invisible in the widget and be collected by
        validatePage/collect_all on the next Next — submitted from a control the
        operator can no longer see."""
        try:
            on = bool(on)
            self.creds_fields.setVisible(on)
            if not on:
                self.user_password.clear()
                self.root_password.clear()
        except Exception:                    # noqa: BLE001 — see the module docstring
            _log_swallowed("_optin_toggled")

    def _person_role_changed(self, text: str = "") -> None:
        """Refresh the on-page description of the selected account tier (ask 7)."""
        try:
            self.person_role_help.setText(_PERSON_ROLE_HELP.get(text or "", ""))
        except Exception:                    # noqa: BLE001 — see the module docstring
            _log_swallowed("_person_role_changed")

    # ---- ask 9: honest seeds ---------------------------------------------------------
    def _worklist_hostnames(self, c) -> list[tuple[str, str]]:
        """``(entry id, derived hostname)`` for each worklist row — [] outside mesh.

        Each row is probed with ITS OWN role/platform/board, not the shared base: the
        WorklistPage pins the base role to the first checked row and forces the base
        platform to "x86", so deriving off the base would report one node's name for
        all of them."""
        wl = getattr(self.wiz, "worklist", None)
        if c.mode != "mesh" or wl is None or not wl.entries:
            return []
        return [(e.id, derive_hostname(SimpleNamespace(
                    brand=c.brand, role=e.role, platform=e.platform, board=e.board,
                    unaffiliated=False)))
                for e in wl.entries]

    def _seed_hostname(self, c) -> None:
        """Prefill the hostname with what the build would derive — EXCEPT on a mesh
        worklist that builds more than one distinct hostname, where one baked value
        would name every node the same thing. There the field stays blank (which is
        also what keeps the mesh argv byte-identical) and the derivation is shown."""
        if c.hostname:
            self.hostname.setText(c.hostname)
            self.hostname_note.setVisible(False)
            return
        names = [n for _id, n in self._worklist_hostnames(c)]
        if len(set(names)) > 1:
            self.hostname.clear()
            self.hostname_note.setText(
                _MESH_HOSTNAME_NOTE.format(names=", ".join(sorted(set(names)))))
            self.hostname_note.setVisible(True)
            return
        self.hostname_note.setVisible(False)
        self.hostname.setText(names[0] if names else derive_hostname(c))

    def _worklist_default_users(self, c) -> list[tuple[str, str]]:
        """``(entry id, derived default account)`` for each worklist row — [] outside
        mesh. Probed per row with ITS OWN platform, for the same reason
        ``_worklist_hostnames`` is: the WorklistPage forces the base platform to "x86",
        and ``derive_default_user`` is platform-keyed (x86 resolves to --local-user,
        every ARM board to its own DEFAULT_USER)."""
        wl = getattr(self.wiz, "worklist", None)
        if c.mode != "mesh" or wl is None or not wl.entries:
            return []
        return [(e.id, derive_default_user(SimpleNamespace(
                    platform=e.platform, local_user=c.local_user,
                    standalone=bool(getattr(c, "standalone", False)),
                    local_pass=c.local_pass)))
                for e in wl.entries]

    def _seed_user(self, c) -> None:
        """Prefill the default account with what the build would derive — EXCEPT on a
        mesh worklist whose rows do not agree, where one baked value would override
        every ARM board's own DEFAULT_USER.

        This is the hostname field's guard, applied to the field that was missing it.
        Seeding off the BASE config (which the WorklistPage pins to x86) resolved to
        cfg.local_user and then rode `-u magus` onto every row — a be.rpi5 row that
        emitted nothing before, and whose builder defaults to 'pi', silently changed
        account. derive_default_user's own docstring says the ARM builders "keep the
        platform account otherwise"; that is only true while nothing bakes -u."""
        if c.user:
            self.user.setText(c.user)
            self.user_note.setVisible(False)
            return
        names = [n for _id, n in self._worklist_default_users(c)]
        if len(set(names)) > 1:
            self.user.clear()
            self.user_note.setText(
                _MESH_USER_NOTE.format(names=", ".join(sorted(set(names)))))
            self.user_note.setVisible(True)
            return
        self.user_note.setVisible(False)
        self.user.setText(names[0] if names else derive_default_user(c))

    def _seed_timezone(self, c) -> None:
        """Preselect the config's zone, else this host's (``core.timezones``). A loaded
        zone the host's tz database does not know is APPENDED rather than silently
        rewritten — the same rule the Users page uses for an undefined domain."""
        want = c.timezone or timezones.default_timezone()
        i = self.timezone.findText(want)
        if i < 0:
            self.timezone.addItem(want)
            i = self.timezone.count() - 1
        self.timezone.setCurrentIndex(i)

    def _node_creds_apply(self, c) -> bool:
        """True when the node fallback credentials are meaningful for this FLOW: some
        image being built is a node-class role on a builder that actually parses
        --user-password/--root-password (x86 today, per PLATFORM_FIELD_SUPPORT).

        Mesh keys on the WORKLIST ENTRIES, never the base config: WorklistPage sets
        the base role to the FIRST checked row (catalog order — a desktop row like
        rpi5-desktop can precede an x86 node row like edge_ai) and forces the base
        platform to "x86" regardless of the rows. Keying on the base would therefore
        (a) hide+clear the creds while an x86 node image that CONSUMES them is being
        built (emission loss, order-dependent), and (b) show them on an all-ARM
        worklist where no entry receives the flags. Per-entry, both stay honest."""
        wl = getattr(self.wiz, "worklist", None)
        if c.mode == "mesh" and wl is not None and wl.entries:
            return any(image_class(c.mode, e.role) == "node"
                       and platform_supports("user_password", e.platform)
                       for e in wl.entries)
        return (image_class(c.mode, c.role) == "node"
                and platform_supports("user_password", c.platform))

    def initializePage(self):
        c = self.wiz.cfg
        self._seed_hostname(c)
        self._seed_timezone(c)
        self._seed_user(c)
        # ask 7: the tier round-trips; an out-of-range value falls back to 'derive'
        self.person_role.setCurrentText(c.person_role if c.person_role in PERSON_ROLE_CHOICES
                                        else "derive")
        self._person_role_changed(self.person_role.currentText())
        # ask 10: the opt-in reflects whether a credential is actually held. Secrets are
        # never saved (SECRET_FIELDS), so a reloaded config always arrives un-opted-in —
        # which is the correct, safe reading of "no credentials are set".
        self.creds_optin.setChecked(bool(c.user_password or c.root_password))
        self._optin_toggled(self.creds_optin.isChecked())
        self.user_password.setText(c.user_password)
        self.root_password.setText(c.root_password)
        # hostname/timezone/user are all-platform (-H/-T/-u, every builder); only
        # the fallback credentials are x86-only — greyed per the capability table
        # (G10 pattern) instead of silently dropping the values from an ARM argv.
        gate_widgets(c.platform, {
            "user_password": self.user_password,
            "root_password": self.root_password,
        })
        # person-role: HIDE (not grey) wherever the builder would discard it — a cluster
        # node, an unaffiliated/standalone desktop, or a platform with no --person-role
        # flag at all. Two axes, so both reasons stay accurate.
        gate_widgets_role_class(self.person_box, person_role_applies(c),
                                _PERSON_ROLE_HIDDEN_REASON, hide=True)
        gate_widgets(c.platform, {"person_role": self.person_role_row})
        # role-class + platform HIDE (spec 3, #348 idiom): the whole group is shown ONLY
        # when the fallback creds are meaningful — a node-class image (mesh flow) on the
        # x86 builder. Hidden entirely on desktop images (standalone/cloud) and on ARM,
        # rather than showing a greyed/irrelevant field. Re-gated every visit so it
        # reappears if a node role is later in scope; emission preserved by the clear
        # in validatePage plus clear_unsupported.
        gate_widgets_role_class(self.creds, self._node_creds_apply(c),
                                _NODE_CREDS_REASON, hide=True)

    def validatePage(self):
        c = self.wiz.cfg
        c.hostname = self.hostname.text().strip()
        c.timezone = self.timezone.currentText().strip()
        c.user = self.user.text().strip()
        # ask 10: nothing about the credentials is collected unless the operator opted
        # in. Belt & braces with the wipe in _optin_toggled — the collect itself carries
        # the gate, so even a widget left populated by some other path emits nothing.
        if self.creds_optin.isChecked():
            c.user_password = self.user_password.text()
            c.root_password = self.root_password.text()
        else:
            c.user_password = ""
            c.root_password = ""
        # ask 7: the tier, and the same platform clear the Users page used to apply —
        # a value picked while an x86 platform was selected must not linger once the
        # platform has no --person-role flag.
        pr = self.person_role.currentText()
        c.person_role = "" if pr == "derive" else pr
        clear_unsupported(c, ("person_role",))
        # ...and the role-class/mode clear: person_role_applies is the same predicate
        # to_cli_args uses, so a tier picked before a mode/role change can never survive
        # into a flow that would discard it (or, for --unaffiliated, hard-conflict).
        if not person_role_applies(c):
            c.person_role = ""
        # x86-only fields — force-clear on every other platform so a stale secret
        # typed while platform was x86 can never linger into the live command for
        # an ARM build (never saved to configs regardless: SECRET_FIELDS).
        clear_unsupported(c, ("user_password", "root_password"))
        # role-class clear (belt & braces, mirroring the HomePage node/desktop clear):
        # blank the creds ONLY when NO image in this flow consumes them — a desktop
        # image, or a mesh worklist with no x86 node row (per-entry strip would drop
        # them silently anyway). NEVER cleared while any x86 node entry is checked,
        # even when the base role is a desktop row (emission guard). Emission-safe:
        # no desktop golden sets these (they default "" there), and to_cli_args only
        # emits them non-empty + x86.
        if not self._node_creds_apply(c):
            c.user_password = ""
            c.root_password = ""
        return True
