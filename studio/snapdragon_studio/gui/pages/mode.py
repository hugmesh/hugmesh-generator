"""ModePage — the standalone / cloud / mesh Studio-mode radios."""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.config import MODE_DEFAULT_ROLE, ROLE_CHOICES, UNAFFILIATED_ROLE


class ModePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("What are you building?")
        lay = QtWidgets.QVBoxLayout(self)
        self.group = QtWidgets.QButtonGroup(self)
        self.modes = [
            ("standalone", "Standalone hardened desktop",
             "A personal LUKS-encrypted Gentoo+SELinux desktop. No mesh, no SSO — or an "
             "UNAFFILIATED plain Gentoo desktop — zero Snapdragon branding/tooling."),
            ("cloud", "Branded cloud image", "A tailnet client tied to a domain (mesh + SSO). Drop in an admin-provided key-zip."),
            ("mesh", "Superadmin mesh", "Set up domains and attach users, then build mesh node image(s)."),
        ]
        for i, (mid, label, desc) in enumerate(self.modes):
            rb = QtWidgets.QRadioButton(label)
            rb.setProperty("mode", mid)
            sub = QtWidgets.QLabel(desc)
            sub.setStyleSheet("color: gray;")
            sub.setContentsMargins(24, 0, 0, 8)
            self.group.addButton(rb, i)
            lay.addWidget(rb)
            lay.addWidget(sub)
        self.group.button(0).setChecked(True)
        lay.addStretch(1)

    def initializePage(self):
        # reflect the config's mode in the radios (a loaded config / back-navigation)
        # — otherwise the constructor's standalone default would silently clobber it
        # on the next validatePage.
        for i, (mid, _label, _desc) in enumerate(self.modes):
            if mid == self.wiz.cfg.mode:
                self.group.button(i).setChecked(True)

    def validatePage(self):
        btn = self.group.checkedButton()
        if btn is None:
            return False
        mid = btn.property("mode")
        self.wiz.cfg.mode = mid
        # a role from another mode is meaningless here — reset to the mode default
        # (RolePage preselects it and lets the user pick any role in the catalog)
        if self.wiz.cfg.role not in {r for r, _, _ in ROLE_CHOICES[mid]}:
            self.wiz.cfg.role = MODE_DEFAULT_ROLE[mid]
        # bundle the generator source only for standalone (self-hosting appliance);
        # cloud/mesh client images keep it off, mirroring the build script's default.
        # The UNAFFILIATED role must stay clear: bundling the Snapdragon source is a
        # builder hard-conflict there (RolePage clears it again when it's picked).
        self.wiz.cfg.bundle_source = (mid == "standalone"
                                      and self.wiz.cfg.role != UNAFFILIATED_ROLE)
        if mid == "standalone":
            # standalone SKIPS the key-zip/domains/users pages (MODE_SKIPPED_PAGES) —
            # clear anything a previously visited cloud/mesh flow parked in the
            # config, so pages the user can no longer reach can't strand stale state
            # into save() or the emitted argv.
            self.wiz.cfg.keyzip = ""
            self.wiz.cfg.domains = []
            self.wiz.cfg.users = []
        return True
