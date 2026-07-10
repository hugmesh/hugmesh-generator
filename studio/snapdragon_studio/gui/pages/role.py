"""RolePage — the role catalog + platform picker and per-platform board/flavor knobs."""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.config import (
    FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, JETSON_BOARDS, KERNEL_FLAVOR_CHOICES,
    ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS, ORANGEPIZERO2_FLAVORS, PLATFORM_LABELS,
    ROLE_CHOICES, RPI_BOARDS, UNAFFILIATED_ROLE,
)
from ._widgets import _row


class RolePage(QtWidgets.QWizardPage):
    """Explicit role + platform picker — EVERY documented image option, grouped by
    mode (the all-options-in-all-menus rule). The platform axis picks the builder:
    x86 / rpi5 / frite / jetson (jetson is EXPERIMENTAL — hardware validation pending).
    """
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Role & platform")
        self.setSubTitle("Pick the image role, then the hardware platform that builds it.")
        lay = QtWidgets.QVBoxLayout(self)
        self.roles = QtWidgets.QListWidget()
        lay.addWidget(self.roles, 1)
        self.platform = QtWidgets.QComboBox()
        lay.addWidget(_row("Platform", self.platform))

        # frite board/flavor/desktop knobs (visible only when platform == frite)
        self.frite_box = QtWidgets.QGroupBox("La Frite board options")
        fl = QtWidgets.QVBoxLayout(self.frite_box)
        self.board = QtWidgets.QComboBox(); self.board.addItems(list(FRITE_BOARDS))
        self.flavor = QtWidgets.QComboBox(); self.flavor.addItems(list(FRITE_FLAVORS))
        self.flavor.setCurrentText("both")
        self.frite_desktop = QtWidgets.QComboBox(); self.frite_desktop.addItems(list(FRITE_DESKTOPS))
        fl.addWidget(_row("Board", self.board))
        fl.addWidget(_row("Flavor", self.flavor))
        fl.addWidget(_row("Desktop", self.frite_desktop))
        # frite needs a FIP/BL31-SIGNED prebuilt U-Boot — without the right one the
        # image may not be flashable at all (G35), hence rows here, not extra-flags.
        (self.frite_uboot_url, self.frite_uboot_defconfig,
         self.frite_skip_uboot) = self._uboot_rows(
            fl, "prebuilt FIP/BL31-signed U-Boot URL (flashability-critical; empty = builder default)")
        lay.addWidget(self.frite_box)

        # jetson board knob (visible only when platform == jetson)
        self.jetson_box = QtWidgets.QGroupBox("Jetson Orin board options")
        jl = QtWidgets.QVBoxLayout(self.jetson_box)
        self.jetson_board = QtWidgets.QComboBox()
        self.jetson_board.addItems(list(JETSON_BOARDS))
        jl.addWidget(_row("Board", self.jetson_board))
        # --kernel-flavor mainline|l4t (G36): a plan-valid axis — the matrix and
        # --print-plan accept it — surfaced with the l4t caveat spelled out.
        self.kernel_flavor = QtWidgets.QComboBox()
        self.kernel_flavor.addItem("(builder default: mainline)", "")
        for kf in KERNEL_FLAVOR_CHOICES:
            self.kernel_flavor.addItem(kf, kf)
        self.kernel_flavor.setToolTip(
            "--kernel-flavor mainline|l4t. CAVEAT: the l4t kernel BUILD is a stub "
            "that hard-errors today — the plan/matrix (--print-plan) accept the "
            "axis, but a real l4t image build fails until the L4T path lands.")
        jl.addWidget(_row("Kernel flavor", self.kernel_flavor))
        lay.addWidget(self.jetson_box)

        # rpi5-family board knob (visible only when platform == rpi5; applies
        # to every rpi5 role, not just desktop — rpi3 is desktop-only, enforced
        # by the builder itself, not pre-validated here)
        self.rpi5_box = QtWidgets.QGroupBox("Raspberry Pi 5 family board options")
        r5l = QtWidgets.QVBoxLayout(self.rpi5_box)
        self.rpi5_board = QtWidgets.QComboBox()
        self.rpi5_board.addItems(list(RPI_BOARDS))
        r5l.addWidget(_row("Board", self.rpi5_board))
        lay.addWidget(self.rpi5_box)

        # orange pi 5 board+flavor knobs (visible only when platform == orangepi5)
        self.orangepi5_box = QtWidgets.QGroupBox("Orange Pi 5 board options")
        o5l = QtWidgets.QVBoxLayout(self.orangepi5_box)
        self.orangepi5_board = QtWidgets.QComboBox()
        self.orangepi5_board.addItems(list(ORANGEPI5_BOARDS))
        self.orangepi5_flavor = QtWidgets.QComboBox()
        self.orangepi5_flavor.addItems(list(ORANGEPI5_FLAVORS))
        self.orangepi5_flavor.setCurrentText("both")
        o5l.addWidget(_row("Board", self.orangepi5_board))
        o5l.addWidget(_row("Flavor", self.orangepi5_flavor))
        # opi5 needs a prebuilt with rkbin DDR-init + TF-A BL31 to be flashable (G35)
        (self.orangepi5_uboot_url, self.orangepi5_uboot_defconfig,
         self.orangepi5_skip_uboot) = self._uboot_rows(
            o5l, "prebuilt U-Boot URL — rkbin DDR-init + TF-A BL31 (flashability-critical; "
                 "empty = builder default)")
        lay.addWidget(self.orangepi5_box)

        # orange pi zero 2 flavor-only knob (visible only when platform ==
        # orangepizero2 — headless appliance, no board/role axis at all)
        self.orangepizero2_box = QtWidgets.QGroupBox("Orange Pi Zero 2 options")
        oz2l = QtWidgets.QVBoxLayout(self.orangepizero2_box)
        self.orangepizero2_flavor = QtWidgets.QComboBox()
        self.orangepizero2_flavor.addItems(list(ORANGEPIZERO2_FLAVORS))
        self.orangepizero2_flavor.setCurrentText("both")
        oz2l.addWidget(_row("Flavor", self.orangepizero2_flavor))
        # opz2's u-boot override is optional convenience, not flashability-critical (G35)
        (self.orangepizero2_uboot_url, self.orangepizero2_uboot_defconfig,
         self.orangepizero2_skip_uboot) = self._uboot_rows(
            oz2l, "prebuilt U-Boot URL (optional; empty = builder default)")
        lay.addWidget(self.orangepizero2_box)

        # x86 client knobs: desktop weight + Steam delivery + the composable
        # payload/affiliation flags (G21/G22)
        self.client_box = QtWidgets.QGroupBox("Client desktop options")
        cl = QtWidgets.QVBoxLayout(self.client_box)
        self.desktop = QtWidgets.QComboBox()
        self.desktop.addItems(["(default)", "thin", "full"])
        self.steam = QtWidgets.QComboBox()
        self.steam.addItems(["(default)", "native", "flatpak", "none"])
        cl.addWidget(_row("Desktop weight", self.desktop))
        cl.addWidget(_row("Steam delivery", self.steam))
        # --capable composes onto ANY client/standalone role (G21) — before this
        # checkbox it was only implicit via role standalone-thick.
        self.capable = QtWidgets.QCheckBox(
            "Most-capable payload (--capable) — full Plasma desktop, 50 GiB root (composable)")
        cl.addWidget(self.capable)
        # --unaffiliated composes onto the other standalone roles (G22): an
        # unaffiliated laptop/chromebook/thin was inexpressible before. The builder
        # HARD-ERRORS on any brand/mesh/SSO flag combined with it — config.py raises
        # the same conflicts, so the preview fails loudly rather than at build time.
        self.unaffiliated = QtWidgets.QCheckBox(
            "Unaffiliated (--unaffiliated) — plain Gentoo, zero Snapdragon "
            "branding/tooling (composable)")
        cl.addWidget(self.unaffiliated)
        lay.addWidget(self.client_box)

        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: #a65d00;")
        lay.addWidget(self.note)
        lay.addStretch(1)
        self.roles.currentRowChanged.connect(self._role_changed)
        self.platform.currentIndexChanged.connect(self._platform_changed)

    def _uboot_rows(self, box_layout, url_hint):
        """--uboot-url / --uboot-defconfig / --skip-uboot rows for one board box
        (G35). Each box gets its own widget set (a widget has one parent), all
        mirroring the same three config fields — initializePage seeds every set,
        validatePage reads the selected platform's."""
        url = QtWidgets.QLineEdit()
        url.setPlaceholderText(url_hint)
        defconfig = QtWidgets.QLineEdit()
        defconfig.setPlaceholderText("U-Boot defconfig name (empty = builder default)")
        skip = QtWidgets.QCheckBox("Skip the U-Boot build/flash step (--skip-uboot)")
        box_layout.addWidget(_row("U-Boot URL", url))
        box_layout.addWidget(_row("U-Boot defconfig", defconfig))
        box_layout.addWidget(skip)
        return url, defconfig, skip

    def initializePage(self):
        c = self.wiz.cfg
        self.roles.blockSignals(True)
        self.roles.clear()
        for role, platforms, label in ROLE_CHOICES[c.mode]:
            it = QtWidgets.QListWidgetItem(f"{role} — {label}")
            it.setData(Qt.ItemDataRole.UserRole, (role, platforms))
            self.roles.addItem(it)
            if role == c.role:
                self.roles.setCurrentItem(it)
        self.roles.blockSignals(False)
        if self.roles.currentRow() < 0:
            self.roles.setCurrentRow(0)
        else:
            self._role_changed(self.roles.currentRow())
        if c.board:
            if c.platform == "jetson":
                self.jetson_board.setCurrentText(c.board)
            elif c.platform == "rpi5":
                self.rpi5_board.setCurrentText(c.board)
            elif c.platform == "orangepi5":
                self.orangepi5_board.setCurrentText(c.board)
            else:
                self.board.setCurrentText(c.board)
        if c.flavor:
            if c.platform == "orangepi5":
                self.orangepi5_flavor.setCurrentText(c.flavor)
            elif c.platform == "orangepizero2":
                self.orangepizero2_flavor.setCurrentText(c.flavor)
            else:
                self.flavor.setCurrentText(c.flavor)
        if c.platform == "frite" and c.desktop:
            self.frite_desktop.setCurrentText(c.desktop)
        elif c.desktop:
            self.desktop.setCurrentText(c.desktop)
        if c.steam:
            self.steam.setCurrentText(c.steam)
        # one config field triple mirrored into every box's u-boot widget set (G35)
        for url_w, defconfig_w, skip_w in (
                (self.frite_uboot_url, self.frite_uboot_defconfig, self.frite_skip_uboot),
                (self.orangepi5_uboot_url, self.orangepi5_uboot_defconfig,
                 self.orangepi5_skip_uboot),
                (self.orangepizero2_uboot_url, self.orangepizero2_uboot_defconfig,
                 self.orangepizero2_skip_uboot)):
            url_w.setText(c.uboot_url)
            defconfig_w.setText(c.uboot_defconfig)
            skip_w.setChecked(c.skip_uboot)
        self.kernel_flavor.setCurrentIndex(max(0, self.kernel_flavor.findData(c.kernel_flavor or "")))
        self.capable.setChecked(c.capable)
        # only restore where the compose is legal (_platform_changed may have just
        # disabled + cleared the checkbox for this mode/role)
        self.unaffiliated.setChecked(c.unaffiliated and self.unaffiliated.isEnabled())

    def _current_role(self):
        it = self.roles.currentItem()
        return it.data(Qt.ItemDataRole.UserRole) if it else (self.wiz.cfg.role, ("x86",))

    def _role_changed(self, _row):
        role, platforms = self._current_role()
        self.platform.blockSignals(True)
        self.platform.clear()
        for p in platforms:
            self.platform.addItem(PLATFORM_LABELS[p], p)
        want = self.wiz.cfg.platform if self.wiz.cfg.platform in platforms else platforms[0]
        self.platform.setCurrentIndex(list(platforms).index(want))
        self.platform.blockSignals(False)
        self._platform_changed(self.platform.currentIndex())

    def _platform_changed(self, _idx):
        role, _platforms = self._current_role()
        plat = self.platform.currentData() or "x86"
        self.frite_box.setVisible(plat == "frite")
        self.jetson_box.setVisible(plat == "jetson")
        self.rpi5_box.setVisible(plat == "rpi5")
        self.orangepi5_box.setVisible(plat == "orangepi5")
        self.orangepizero2_box.setVisible(plat == "orangepizero2")
        # desktop weight / Steam are x86 desktop-image knobs (client + standalone)
        self.client_box.setVisible(plat == "x86" and self.wiz.cfg.mode in ("standalone", "cloud"))
        # composable --unaffiliated is standalone-only (cloud/mesh bake person-device
        # identity — a builder hard-conflict, mirrored by config.py) and redundant on
        # the dedicated role id, which presets it in the builder's own role switch.
        composable_ok = self.wiz.cfg.mode == "standalone" and role != UNAFFILIATED_ROLE
        self.unaffiliated.setEnabled(composable_ok)
        if not composable_ok:
            self.unaffiliated.setChecked(False)
        self.unaffiliated.setToolTip(
            "" if composable_ok else
            "Composable --unaffiliated applies to a STANDALONE build on a role other "
            "than standalone-unaffiliated (that role already presets it); cloud/mesh "
            "person-device identity is a builder hard-conflict.")
        self.note.setText("EXPERIMENTAL — hardware validation pending (specs-jetson/README.md); "
                          "the Jetson builder is being brought up." if plat == "jetson" else "")

    def validatePage(self):
        c = self.wiz.cfg
        role, _platforms = self._current_role()
        c.role = role
        c.platform = self.platform.currentData() or "x86"
        # composable payload/affiliation flags (G21/G22) — x86-client-box-only, so a
        # value picked before a platform/mode switch can never linger into the argv.
        # isVisibleTo(self), not isVisible(): collect_all() re-validates this page
        # while ANOTHER page is current (the whole page hidden), and plain
        # isVisible() would read False then and wipe the collected values.
        x86_client = self.client_box.isVisibleTo(self)
        c.capable = self.capable.isChecked() if x86_client else False
        c.unaffiliated = (self.unaffiliated.isChecked()
                          if x86_client and self.unaffiliated.isEnabled() else False)
        # Unaffiliated build (the dedicated role OR the composable flag): ModePage
        # defaults bundle_source ON for standalone mode, but bundling the Snapdragon
        # generator source is a builder HARD CONFLICT on an unaffiliated image —
        # clear it here so the wizard default cannot poison the argv.
        if c.role == UNAFFILIATED_ROLE or c.unaffiliated:
            c.bundle_source = False
        # per-platform-only axes default clear; the selected platform's branch
        # below overrides (same lingering-value rule as the composable flags)
        c.kernel_flavor = ""
        c.uboot_url = ""
        c.uboot_defconfig = ""
        c.skip_uboot = False
        if c.platform == "frite":
            c.board = self.board.currentText()
            c.flavor = self.flavor.currentText()
            c.desktop = self.frite_desktop.currentText()
            c.uboot_url = self.frite_uboot_url.text().strip()
            c.uboot_defconfig = self.frite_uboot_defconfig.text().strip()
            c.skip_uboot = self.frite_skip_uboot.isChecked()
        elif c.platform == "jetson":
            c.board = self.jetson_board.currentText()
            c.flavor = ""
            c.desktop = ""
            c.kernel_flavor = self.kernel_flavor.currentData() or ""
        elif c.platform == "rpi5":
            c.board = self.rpi5_board.currentText()
            c.flavor = ""
            c.desktop = ""
        elif c.platform == "orangepi5":
            c.board = self.orangepi5_board.currentText()
            c.flavor = self.orangepi5_flavor.currentText()
            c.desktop = ""
            c.uboot_url = self.orangepi5_uboot_url.text().strip()
            c.uboot_defconfig = self.orangepi5_uboot_defconfig.text().strip()
            c.skip_uboot = self.orangepi5_skip_uboot.isChecked()
        elif c.platform == "orangepizero2":
            c.board = ""
            c.flavor = self.orangepizero2_flavor.currentText()
            c.desktop = ""
            c.uboot_url = self.orangepizero2_uboot_url.text().strip()
            c.uboot_defconfig = self.orangepizero2_uboot_defconfig.text().strip()
            c.skip_uboot = self.orangepizero2_skip_uboot.isChecked()
        else:
            c.board = ""
            c.flavor = ""
            weight = self.desktop.currentText()
            c.desktop = "" if (weight == "(default)" or not x86_client) else weight
        steam = self.steam.currentText()
        c.steam = "" if (steam == "(default)" or not x86_client) else steam
        return True
