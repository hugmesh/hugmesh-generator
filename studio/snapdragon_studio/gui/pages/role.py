"""RolePage — MACHINE-FIRST image picker: choose the target MACHINE as a card, then
the IMAGE TYPE (role) that machine supports, with the per-machine board/flavor/desktop
knobs inline underneath. The x86 card additionally carries the machine-profile PRESET
(seeds GPU/Wi-Fi/kernel defaults; never emits a flag itself), so the target machine is
defined in exactly ONE place across the flow.

Emission is UNCHANGED: validatePage writes the SAME cfg fields via the SAME
platform-branch cascade the role→platform combo produced — the machine card IS the
platform, and the reachable (role, platform) set is the same ROLE_CHOICES[mode]
catalog merely pivoted (machine→roles instead of role→machines).
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ._scroll import scrollable
from ...core import hw_scan, profiles
from ...core.config import (
    FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, GPU_DRIVER_ALIASES, GPU_DRIVER_CHOICES,
    JETSON_BOARDS, KERNEL_FLAVOR_CHOICES, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, PLATFORM_LABELS, ROLE_CHOICES, RPI_BOARDS, UNAFFILIATED_ROLE,
    rpi_boards_for_role,
)
from ._widgets import _row

# canonical machine-card order — x86 first (the default platform), matching today's
# default-platform behaviour; ARM boards follow in a stable order.
_MACHINE_ORDER = ("x86", "rpi5", "frite", "orangepi5", "orangepizero2", "jetson")

# Short, friendly card names for the machine tier; the detailed PLATFORM_LABELS text
# (which carries #351's "EXPERIMENTAL: hardware validation pending" tags) rides through
# as the card's gray sub-description, so the experimental tagging is unchanged.
_MACHINE_CARD_NAME = {
    "x86": "x86 PC / laptop",
    "rpi5": "Raspberry Pi 3 / 4 / 5",
    "frite": "La Frite (Amlogic)",
    "orangepi5": "Orange Pi 5",
    "orangepizero2": "Orange Pi Zero 2",
    "jetson": "Jetson Orin",
}


def _machine_sort_key(plat: str) -> int:
    return _MACHINE_ORDER.index(plat) if plat in _MACHINE_ORDER else len(_MACHINE_ORDER)


class RolePage(QtWidgets.QWizardPage):
    """Machine-first single-image picker. Mesh skips this page (the WorklistPage owns
    role × platform); standalone/cloud build ONE image here."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Target machine & image type")
        # initializePage() sets a path-aware subtitle (standalone vs. mesh client);
        # this is the fallback before the mode is known.
        self.setSubTitle("Pick the machine you're building for, then the image type it runs.")
        lay = scrollable(self)

        # ── machine tier: one card per platform in the UNION of ROLE_CHOICES for the
        # two single-image modes (standalone/cloud share the same union; the current
        # mode's subset is shown per-visit). The card IS the platform axis. ─────────
        self._all_machines = sorted(
            {p for m in ("standalone", "cloud")
             for _r, plats, _l in ROLE_CHOICES[m] for p in plats},
            key=_machine_sort_key)
        self.machine_box = QtWidgets.QGroupBox("Target machine")
        mbl = QtWidgets.QVBoxLayout(self.machine_box)
        self.machine_group = QtWidgets.QButtonGroup(self)
        self._machine_buttons: dict[str, QtWidgets.QRadioButton] = {}
        self._machine_rows: dict[str, QtWidgets.QWidget] = {}
        for i, plat in enumerate(self._all_machines):
            rb = QtWidgets.QRadioButton(_MACHINE_CARD_NAME.get(plat, plat))
            rb.setProperty("machine", plat)
            sub = QtWidgets.QLabel(PLATFORM_LABELS[plat])   # rides #351's EXPERIMENTAL tags
            sub.setWordWrap(True)
            sub.setStyleSheet("color: gray;")
            sub.setContentsMargins(24, 0, 0, 8)
            self.machine_group.addButton(rb, i)
            self._machine_buttons[plat] = rb
            container = QtWidgets.QWidget()
            cvl = QtWidgets.QVBoxLayout(container)
            cvl.setContentsMargins(0, 0, 0, 0)
            cvl.addWidget(rb)
            cvl.addWidget(sub)
            self._machine_rows[plat] = container
            mbl.addWidget(container)
        lay.addWidget(self.machine_box)

        # ── image-type tier: the roles the CHOSEN machine supports (filtered from the
        # same ROLE_CHOICES[mode] catalog). Selecting a card repopulates this list. ──
        lay.addWidget(QtWidgets.QLabel("Image type"))
        self.roles = QtWidgets.QListWidget()
        # Keep a healthy visible height for the role list inside the scroll area
        # (a stretch factor collapses to sizeHint once the page itself scrolls).
        self.roles.setMinimumHeight(240)
        lay.addWidget(self.roles, 1)

        # ── machine-profile PRESET — folded here from the Hardware page (spec fold 2):
        # a preset only, shown inline UNDER the x86 card (profiles.json is all-x86). It
        # pre-fills the GPU/Wi-Fi/Bluetooth fields the Hardware step finalises and never
        # emits a builder flag itself. Hidden on non-x86 cards (no profiles there). ──
        self.profiles = profiles.load(getattr(wiz, "generator_dir", ""))
        self.profile = QtWidgets.QComboBox()
        self.profile.addItem("(none / generic)", "")
        for p in self.profiles:
            self.profile.addItem(p.label, p.id)
        self.profile.setToolTip(
            "A preset only — picking a profile pre-fills the GPU driver and "
            "Wi-Fi/Bluetooth fields on the Hardware step and never emits a builder flag "
            "itself; the fields it set are what reach the build command.")
        self.profile_row = _row("Machine profile (preset — never emits a flag itself)",
                                self.profile)
        lay.addWidget(self.profile_row)
        self.profile_note = QtWidgets.QLabel(
            "Pre-fills this x86 machine's GPU / Wi-Fi / Bluetooth defaults — or scan the "
            "machine on the next Hardware step. The preset never emits a flag itself.")
        self.profile_note.setWordWrap(True)
        self.profile_note.setStyleSheet("color: gray;")
        lay.addWidget(self.profile_note)
        self.scan_out = QtWidgets.QLabel("")
        self.scan_out.setWordWrap(True)
        self.scan_out.setStyleSheet("color: #3f5b8c;")
        lay.addWidget(self.scan_out)

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
        client_help = QtWidgets.QLabel(
            "Desktop weight overrides the role's baseline: thin = light LXDE desktop, "
            "full = full Plasma desktop. Leave at (default) to keep the role's built-in weight.")
        client_help.setWordWrap(True)
        client_help.setStyleSheet("color: gray;")
        cl.addWidget(client_help)
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
        self.machine_group.buttonToggled.connect(self._on_machine_toggled)
        self.profile.currentIndexChanged.connect(self._profile_changed)

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

    # ---- machine / role plumbing -------------------------------------------------
    def _platforms_for_role(self, mode: str, role: str):
        for r, plats, _l in ROLE_CHOICES[mode]:
            if r == role:
                return plats
        return None

    def _selected_machine(self):
        btn = self.machine_group.checkedButton()
        return btn.property("machine") if btn is not None else None

    def _current_role(self):
        it = self.roles.currentItem()
        return (it.data(Qt.ItemDataRole.UserRole) if it
                else (self.wiz.cfg.role, (self._selected_machine() or "x86",)))

    def _current_role_id(self):
        it = self.roles.currentItem()
        return it.data(Qt.ItemDataRole.UserRole)[0] if it else None

    def _populate_roles(self, machine: str, prefer: str) -> None:
        """Fill the image-type list with the roles the chosen MACHINE supports (the
        same ROLE_CHOICES[mode] catalog pivoted machine→roles); pre-select ``prefer``."""
        self.roles.blockSignals(True)
        self.roles.clear()
        target = None
        for role, platforms, label in ROLE_CHOICES[self.wiz.cfg.mode]:
            if machine not in platforms:
                continue
            it = QtWidgets.QListWidgetItem(f"{role} — {label}")
            it.setData(Qt.ItemDataRole.UserRole, (role, platforms))
            self.roles.addItem(it)
            if role == prefer:
                target = it
        if target is not None:
            self.roles.setCurrentItem(target)
        elif self.roles.count():
            self.roles.setCurrentRow(0)
        self.roles.blockSignals(False)

    def _on_machine_toggled(self, btn, checked) -> None:
        if not checked:
            return
        machine = btn.property("machine")
        prefer = self._current_role_id() or self.wiz.cfg.role
        self._populate_roles(machine, prefer)
        self._update_boxes(machine)
        self._role_changed(self.roles.currentRow())

    def _update_boxes(self, machine: str) -> None:
        """Machine-driven inline knob visibility (same setVisible cascade the old
        combo drove, now keyed on the selected card)."""
        self.frite_box.setVisible(machine == "frite")
        self.jetson_box.setVisible(machine == "jetson")
        self.rpi5_box.setVisible(machine == "rpi5")
        self.orangepi5_box.setVisible(machine == "orangepi5")
        self.orangepizero2_box.setVisible(machine == "orangepizero2")
        # desktop weight / Steam are x86 desktop-image knobs (client + standalone)
        self.client_box.setVisible(machine == "x86"
                                   and self.wiz.cfg.mode in ("standalone", "cloud"))
        # the machine-profile preset lives with the x86 card only (profiles.json is x86)
        x86 = machine == "x86"
        self.profile_row.setVisible(x86)
        self.profile_note.setVisible(x86)
        self.scan_out.setVisible(x86)
        self.note.setText("EXPERIMENTAL — hardware validation pending (specs-jetson/README.md); "
                          "the Jetson builder is being brought up." if machine == "jetson" else "")

    # ---- test / navigation entry points ------------------------------------------
    def select_machine(self, plat: str) -> None:
        """Select the machine card for ``plat`` (repopulates the image-type list)."""
        self._machine_buttons[plat].setChecked(True)

    def select_role(self, role: str) -> bool:
        """Select the machine that supports ``role`` (if the current one doesn't), then
        the role in the image-type list. Returns True on success."""
        plats = self._platforms_for_role(self.wiz.cfg.mode, role)
        if plats and self._selected_machine() not in plats:
            self.select_machine(plats[0])
        for i in range(self.roles.count()):
            it = self.roles.item(i)
            if it.data(Qt.ItemDataRole.UserRole)[0] == role:
                self.roles.setCurrentItem(it)
                return True
        return False

    def initializePage(self):
        c = self.wiz.cfg
        # mesh builds its image set on the WorklistPage (a role x platform multi-select),
        # NOT this single-select — the page is skipped in mesh (MODE_SKIPPED_PAGES). Guard
        # defensively so the mesh catalog is never presented here even if the page is
        # somehow reached (the WorklistPage owns mesh role x platform).
        if c.mode == "mesh":
            return
        # Path-aware subtitle (spec step 2): this page IS the desktop-TYPE picker — say
        # which choice the user is making on the path they took at the first screen.
        if c.mode == "standalone":
            self.setSubTitle(
                "Choose the target machine, then the desktop type — thick (full desktop) / "
                "thin (light desktop) / unaffiliated (plain Gentoo, no Snapdragon).")
        else:  # cloud — the mesh desktop CLIENT that joins an existing mesh
            self.setSubTitle(
                "Choose the target machine, then the client desktop type it runs.")
        # machine cards = the UNION of THIS mode's ROLE_CHOICES platforms (#351 gating
        # rides through the shared card labels).
        mode_machines = {p for _r, plats, _l in ROLE_CHOICES[c.mode] for p in plats}
        for plat, container in self._machine_rows.items():
            container.setVisible(plat in mode_machines)
        # resolve the default machine EXACTLY as the old page did: c.platform if it is a
        # supported platform of c.role, else the role's first platform (c.platform-or-
        # platforms[0]). Falls back to the first mode machine if the role is unknown.
        role_plats = self._platforms_for_role(c.mode, c.role)
        if role_plats:
            default_machine = c.platform if c.platform in role_plats else role_plats[0]
        else:
            default_machine = next((p for p in self._all_machines if p in mode_machines),
                                   "x86")
        self.machine_group.blockSignals(True)
        self._machine_buttons[default_machine].setChecked(True)
        self.machine_group.blockSignals(False)
        self._populate_roles(default_machine, c.role)
        self._update_boxes(default_machine)
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
        # only restore where the compose is legal (_role_changed may have just
        # disabled + cleared the checkbox for this mode/role)
        self.unaffiliated.setChecked(c.unaffiliated and self.unaffiliated.isEnabled())

    def _role_changed(self, _row):
        role, _platforms = self._current_role()
        machine = self._selected_machine() or "x86"
        # rpi3 is DESKTOP-ONLY (1GB RAM): a node/appliance rpi5 role (generic) must not
        # offer it — mirror the builder's hard-error at the SELECTION layer so the pick
        # can't dead-end. Repopulate the board list per role-class, preserving a still-
        # valid selection (rpi5/rpi4) across a role switch.
        if machine == "rpi5":
            boards = rpi_boards_for_role(role)
            if [self.rpi5_board.itemText(i) for i in range(self.rpi5_board.count())] != list(boards):
                keep = self.rpi5_board.currentText()
                self.rpi5_board.blockSignals(True)
                self.rpi5_board.clear()
                self.rpi5_board.addItems(list(boards))
                if keep in boards:
                    self.rpi5_board.setCurrentText(keep)
                self.rpi5_board.blockSignals(False)
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

    # ---- machine-profile preset (folded from the Hardware page) ------------------
    def _seed_gpu(self, c, value: str) -> None:
        """Seed cfg.gpu_driver with the normalized driver, mirroring HardwarePage._set_gpu
        (builder vendor aliases like 'intel' fold to the canonical id). Only a valid
        choice is written, matching setCurrentText's no-op-on-miss semantics, so the
        Hardware step's later _set_gpu(c.gpu_driver) is idempotent — same final value."""
        norm = GPU_DRIVER_ALIASES.get(value, value) or "auto"
        if norm in GPU_DRIVER_CHOICES:
            c.gpu_driver = norm

    def _profile_changed(self, _idx=0):
        """A profile is a PRESET: pre-fill cfg's GPU/Wi-Fi/Bluetooth (which the Hardware
        step reads into its widgets and finalises) — exactly what HardwarePage._profile_changed
        did to the widgets, but written to cfg so a page BEFORE Hardware can seed them.
        hw_profile itself is NON_ARGV (never emitted); RolePage.validatePage records it."""
        c = self.wiz.cfg
        pid = self.profile.currentData()
        if pid == "this-machine-scan":
            s = hw_scan.scan()
            self._seed_gpu(c, s.recommended_gpu_driver)
            c.enable_wifi = s.recommend_wifi
            c.enable_bluetooth = s.recommend_bluetooth
            gpus = ", ".join(g.name for g in s.gpus) or "none"
            self.scan_out.setText(f"CPU: {s.cpu or '?'}  ·  GPU: {gpus}  ·  "
                                  f"recommended driver: {s.recommended_gpu_driver}")
            return
        p = next((x for x in self.profiles if x.id == pid), None)
        if p:
            self._seed_gpu(c, p.gpu_driver)
            c.enable_wifi = p.enable_wifi
            c.enable_bluetooth = p.enable_bluetooth

    def validatePage(self):
        c = self.wiz.cfg
        role, _platforms = self._current_role()
        c.role = role
        c.platform = self._selected_machine() or "x86"
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
        # machine-profile preset (folded from Hardware): NON_ARGV round-trip field.
        # x86-only (the picker is hidden on ARM cards) so a stale x86 profile can't
        # linger on an ARM build's saved config.
        c.hw_profile = (self.profile.currentData() or "") if c.platform == "x86" else ""
        return True
