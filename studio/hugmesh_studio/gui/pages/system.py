"""SystemPage — baked host identity (-H/--hostname, -T/--timezone, -u/--user; G26)
and the x86 node FALLBACK credentials --user-password/--root-password (G27).

Kept separate from NetworkPage (mesh/brand plane) and HomePage (local login /
encryption): these fields describe the IMAGE's baked system identity, which every
builder parses, plus the credentials a GUI-built mesh fleet would otherwise ship
as builder defaults.

Registration: StudioWizard/WIZARD_PAGE_SLUGS register this page under the slug
"system" (between "users" and "home") — the page itself only needs a wiz-like
object exposing ``.cfg``, so tests can instantiate it directly.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.config import image_class
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


class SystemPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("System identity")
        self.setSubTitle("The host identity baked into this node/desktop image — "
                         "hostname, timezone and default account. Blank fields keep the "
                         "builder's role-derived hostname, UTC and default account.")
        lay = QtWidgets.QVBoxLayout(self)
        self.hostname = QtWidgets.QLineEdit()
        self.hostname.setPlaceholderText("Leave blank to use the role-derived hostname")
        self.hostname.setToolTip("Sets the baked hostname — the -H/--hostname builder flag.")
        lay.addWidget(_row("Hostname", self.hostname))
        self.timezone = QtWidgets.QLineEdit()
        self.timezone.setPlaceholderText("Area/Location, e.g. Europe/Berlin (leave blank for UTC)")
        self.timezone.setToolTip("Sets the system timezone — the -T/--timezone builder flag.")
        lay.addWidget(_row("Timezone", self.timezone))
        self.user = QtWidgets.QLineEdit()
        self.user.setPlaceholderText("Default account name (leave blank for the builder default)")
        self.user.setToolTip("The baked default account — the -u/--user builder flag "
                             "(distinct from --local-user).")
        lay.addWidget(_row("Default user", self.user))
        # node FALLBACK credentials (G27): without these, a GUI-built mesh fleet
        # ships the builder's DEFAULT credentials. x86 only — rpi5's equivalents
        # are deprecated no-ops. Shown ONLY on the mesh (node-class) flow; hidden on
        # desktop images (spec 3 clarity narrowing).
        self.creds = QtWidgets.QGroupBox("Node fallback login (mesh nodes)")
        cl = QtWidgets.QVBoxLayout(self.creds)
        self.creds_note = QtWidgets.QLabel(
            "Sets the baked USER and ROOT account passwords for the mesh node images "
            "you are building. WHEN USED: only if a node ever needs a local "
            "console/rescue login — the mesh itself uses SSO. Leave blank to keep the "
            "builder's defaults. x86 nodes only; hashed at build time; never written "
            "to a saved config.")
        self.creds_note.setWordWrap(True)
        cl.addWidget(self.creds_note)
        self.user_password = QtWidgets.QLineEdit()
        self.user_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.user_password.setPlaceholderText("hashed at build time; NOT saved to configs")
        cl.addWidget(_row("User password", self.user_password))
        self.root_password = QtWidgets.QLineEdit()
        self.root_password.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.root_password.setPlaceholderText("hashed at build time; NOT saved to configs")
        cl.addWidget(_row("Root password", self.root_password))
        lay.addWidget(self.creds)
        lay.addStretch(1)

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
        self.hostname.setText(c.hostname)
        self.timezone.setText(c.timezone)
        self.user.setText(c.user)
        self.user_password.setText(c.user_password)
        self.root_password.setText(c.root_password)
        # hostname/timezone/user are all-platform (-H/-T/-u, every builder); only
        # the fallback credentials are x86-only — greyed per the capability table
        # (G10 pattern) instead of silently dropping the values from an ARM argv.
        gate_widgets(c.platform, {
            "user_password": self.user_password,
            "root_password": self.root_password,
        })
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
        c.timezone = self.timezone.text().strip()
        c.user = self.user.text().strip()
        c.user_password = self.user_password.text()
        c.root_password = self.root_password.text()
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
