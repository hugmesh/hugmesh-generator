"""RolePage — ARCH-FIRST device picker: choose the ARCHITECTURE (x86-64 / ARM64 / …),
browse the family-grouped DEVICE CATALOG (searchable, with honest status badges), then
the IMAGE TYPE (role) that device really supports, with the per-machine
board/flavor/desktop knobs inline underneath. The x86 devices additionally carry the
machine-profile PRESET (seeds GPU/Wi-Fi/kernel defaults; never emits a flag itself),
so the target machine is defined in exactly ONE place across the flow.

The browser is driven by ``core.device_catalog``: a catalog device IS a
``(platform, board)`` pair — exactly the two cfg fields the previous machine card +
per-platform board combo produced — and its roles are DERIVED from the same
``ROLE_CHOICES``/``rpi_boards_for_role`` predicates, so for every board/role selectable
before, the emitted cfg (platform/board/role/flavor) and argv are unchanged by
construction. The #351 honesty rule is structural: UNSUPPORTED devices are listed but
not selectable (reason shown); EXPERIMENTAL ones are labelled; a device only ever
offers the roles its builder really accepts.

Emission is UNCHANGED: validatePage writes the SAME cfg fields via the SAME
platform-branch cascade — the selected device supplies the platform (and pins the
board combo), and the reachable (role, platform) set is the same ROLE_CHOICES[mode]
catalog merely pivoted (device→roles instead of role→machines).
"""
from __future__ import annotations

from .. import choice_icons
from ..qt import Qt, QtCore, QtGui, QtWidgets
from ._scroll import scrollable
from ...core import device_catalog, hw_scan, profiles
from ...core.config import (
    FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, GPU_DRIVER_ALIASES, GPU_DRIVER_CHOICES,
    JETSON_BOARDS, KERNEL_FLAVOR_CHOICES, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, ORANGEPIZERO2W_FLAVORS, ORANGEPIZERO3_FLAVORS, ORANGEPI3LTS_FLAVORS,
    ORANGEPI4LTS_FLAVORS,
    ROLE_CHOICES, RPI_BOARDS,
    UNAFFILIATED_ROLE,
    rpi_boards_for_role, x86_desktop_axis,
)
from ._widgets import _row, status_badge
from ._widgets import _tri_state, _tri_value

# canonical machine order — x86 first (the default platform), matching today's
# default-platform behaviour; ARM boards follow in a stable order.
_MACHINE_ORDER = ("x86", "rpi5", "frite", "orangepi5", "orangepizero2", "orangepizero2w",
                  "orangepizero3", "orangepi3-lts", "jetson")


def _machine_sort_key(plat: str) -> int:
    return _MACHINE_ORDER.index(plat) if plat in _MACHINE_ORDER else len(_MACHINE_ORDER)


class RolePage(QtWidgets.QWizardPage):
    """Arch-first single-image picker. Mesh skips this page (the WorklistPage owns
    role × platform); standalone/cloud build ONE image here."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Target machine & image type")
        # initializePage() sets a path-aware subtitle (standalone vs. mesh client);
        # this is the fallback before the mode is known.
        self.setSubTitle("Pick the architecture and the device you're building for, "
                         "then the image type it runs.")
        lay = scrollable(self)

        self._catalog = device_catalog.load_catalog()
        # the platform union of the two single-image modes (standalone/cloud share the
        # same union; the current mode's subset gates role derivation per-visit).
        self._all_machines = sorted(
            {p for m in ("standalone", "cloud")
             for _r, plats, _l in ROLE_CHOICES[m] for p in plats},
            key=_machine_sort_key)
        # compat shim for the established pick_platform/select_machine test entry
        # points: platform id -> its default catalog device (the same (platform,
        # board) pair the old card + default board combo produced).
        self._machine_buttons = {p: device_catalog.default_device_for_platform(p)
                                 for p in self._all_machines}

        # ── machine tier: architecture selector + searchable, family-grouped device
        # browser (the device IS the platform+board axes; #351 statuses ride on the
        # rows: UNSUPPORTED visible-but-unselectable, EXPERIMENTAL labelled). ────────
        self.machine_box = QtWidgets.QGroupBox("Target machine")
        mbl = QtWidgets.QVBoxLayout(self.machine_box)

        arch_row = QtWidgets.QWidget()
        arch_lay = QtWidgets.QHBoxLayout(arch_row)
        arch_lay.setContentsMargins(0, 0, 0, 0)
        arch_lay.addWidget(QtWidgets.QLabel("Architecture:"))
        self.arch_group = QtWidgets.QButtonGroup(self)
        self._arch_buttons: dict[str, QtWidgets.QRadioButton] = {}
        for i, arch in enumerate(self._catalog.archs):
            # extensible enum: render only archs that actually carry >=1 device
            if not self._catalog.devices_for_arch(arch.id):
                continue
            rb = QtWidgets.QRadioButton(arch.label)
            rb.setProperty("arch", arch.id)
            self.arch_group.addButton(rb, i)
            self._arch_buttons[arch.id] = rb
            arch_lay.addWidget(rb)
        arch_lay.addStretch(1)
        mbl.addWidget(arch_row)

        self.device_search = QtWidgets.QLineEdit()
        self.device_search.setPlaceholderText(
            "Search devices — name, SoC, or family (e.g. \"potato\", \"RK3588\")")
        self.device_search.setClearButtonEnabled(True)
        mbl.addWidget(self.device_search)

        self.device_tree = QtWidgets.QTreeWidget()
        self.device_tree.setHeaderLabels(["Device", "SoC / details", "Status"])
        self.device_tree.setRootIsDecorated(True)
        self.device_tree.setMinimumHeight(240)
        self.device_tree.setColumnWidth(0, 300)
        self.device_tree.setColumnWidth(1, 260)
        self._family_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._device_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        for fam in self._catalog.families:
            fitem = QtWidgets.QTreeWidgetItem(self.device_tree)
            fitem.setText(0, f"{fam.label} — {fam.vendor}")
            fitem.setFlags(Qt.ItemFlag.ItemIsEnabled)   # a header, never selectable
            font = fitem.font(0)
            font.setBold(True)
            fitem.setFont(0, font)
            self._family_items[fam.id] = fitem
            for dev in self._catalog.devices_in_family(fam.id):
                ditem = QtWidgets.QTreeWidgetItem(fitem)
                ditem.setText(0, dev.label)
                ditem.setText(1, dev.soc)
                ditem.setData(0, Qt.ItemDataRole.UserRole, dev.id)
                self._device_items[dev.id] = ditem
            fitem.setExpanded(True)
        mbl.addWidget(self.device_tree)
        lay.addWidget(self.machine_box)

        # ── image-type tier: the roles the CHOSEN device supports (DERIVED from the
        # same ROLE_CHOICES[mode] catalog). Selecting a device repopulates this list. ──
        lay.addWidget(QtWidgets.QLabel("Image type"))
        self.roles = QtWidgets.QListWidget()
        # Keep a healthy visible height for the role list inside the scroll area
        # (a stretch factor collapses to sizeHint once the page itself scrolls).
        self.roles.setMinimumHeight(240)
        # role-family glyph per row (server rack / bare board / desktop / mesh
        # desktop) — drawn in code + memoised by choice_icons; presentation only.
        self.roles.setIconSize(QtCore.QSize(24, 24))
        lay.addWidget(self.roles, 1)

        # ── machine-profile PRESET — folded here from the Hardware page (spec fold 2):
        # a preset only, shown inline for x86 devices (profiles.json is all-x86). It
        # pre-fills the GPU/Wi-Fi/Bluetooth fields the Hardware step finalises and never
        # emits a builder flag itself. Hidden on non-x86 devices (no profiles there). ──
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

        # orange pi zero 2w flavor-only knob (visible only when platform ==
        # orangepizero2w — headless appliance, no board/role axis at all; the
        # Zero 2's H618 template sibling)
        self.orangepizero2w_box = QtWidgets.QGroupBox("Orange Pi Zero 2W options")
        oz2wl = QtWidgets.QVBoxLayout(self.orangepizero2w_box)
        self.orangepizero2w_flavor = QtWidgets.QComboBox()
        self.orangepizero2w_flavor.addItems(list(ORANGEPIZERO2W_FLAVORS))
        self.orangepizero2w_flavor.setCurrentText("both")
        oz2wl.addWidget(_row("Flavor", self.orangepizero2w_flavor))
        # opz2w's u-boot override is optional convenience, not flashability-critical (G35)
        (self.orangepizero2w_uboot_url, self.orangepizero2w_uboot_defconfig,
         self.orangepizero2w_skip_uboot) = self._uboot_rows(
            oz2wl, "prebuilt U-Boot URL (optional; empty = builder default)")
        lay.addWidget(self.orangepizero2w_box)

        # orange pi zero 3 flavor-only knob (visible only when platform ==
        # orangepizero3 — headless appliance, no board/role axis at all; the
        # Zero 2's H618 template sibling)
        self.orangepizero3_box = QtWidgets.QGroupBox("Orange Pi Zero 3 options")
        oz3l = QtWidgets.QVBoxLayout(self.orangepizero3_box)
        self.orangepizero3_flavor = QtWidgets.QComboBox()
        self.orangepizero3_flavor.addItems(list(ORANGEPIZERO3_FLAVORS))
        self.orangepizero3_flavor.setCurrentText("both")
        oz3l.addWidget(_row("Flavor", self.orangepizero3_flavor))
        # opz3's u-boot override is optional convenience, not flashability-critical (G35)
        (self.orangepizero3_uboot_url, self.orangepizero3_uboot_defconfig,
         self.orangepizero3_skip_uboot) = self._uboot_rows(
            oz3l, "prebuilt U-Boot URL (optional; empty = builder default)")
        lay.addWidget(self.orangepizero3_box)

        # orange pi 3 lts flavor-only knob (visible only when platform ==
        # orangepi3-lts — headless appliance, no board/role axis at all;
        # Allwinner H6, a SoC generation BEFORE the Zero 2's H616 (NOT its
        # sibling), and it boots the PLAIN OPi3's mainline DTB)
        self.orangepi3lts_box = QtWidgets.QGroupBox("Orange Pi 3 LTS options")
        o3ll = QtWidgets.QVBoxLayout(self.orangepi3lts_box)
        self.orangepi3lts_flavor = QtWidgets.QComboBox()
        self.orangepi3lts_flavor.addItems(list(ORANGEPI3LTS_FLAVORS))
        self.orangepi3lts_flavor.setCurrentText("both")
        o3ll.addWidget(_row("Flavor", self.orangepi3lts_flavor))
        # opi3-lts's u-boot override is optional convenience, not flashability-critical (G35)
        (self.orangepi3lts_uboot_url, self.orangepi3lts_uboot_defconfig,
         self.orangepi3lts_skip_uboot) = self._uboot_rows(
            o3ll, "prebuilt U-Boot URL (optional; empty = builder default)")
        lay.addWidget(self.orangepi3lts_box)

        # orange pi 4 lts flavor-only knob (visible only when platform ==
        # orangepi4-lts). Rockchip RK3399 LIGHT DESKTOP — the one Orange Pi
        # platform here that is NOT a headless appliance (enabled Mali-T860
        # GPU + HDMI in the mainline DTB it boots). Still no board axis:
        # mainline ships one Orange Pi RK3399 DTB/defconfig for the whole
        # 4/4B/4 LTS family. No --desktop toggle either, same as orangepi5.
        self.orangepi4lts_box = QtWidgets.QGroupBox("Orange Pi 4 LTS options")
        o4ll = QtWidgets.QVBoxLayout(self.orangepi4lts_box)
        self.orangepi4lts_flavor = QtWidgets.QComboBox()
        self.orangepi4lts_flavor.addItems(list(ORANGEPI4LTS_FLAVORS))
        self.orangepi4lts_flavor.setCurrentText("both")
        o4ll.addWidget(_row("Flavor", self.orangepi4lts_flavor))
        # opi4-lts's u-boot override is optional convenience, not flashability-critical (G35)
        (self.orangepi4lts_uboot_url, self.orangepi4lts_uboot_defconfig,
         self.orangepi4lts_skip_uboot) = self._uboot_rows(
            o4ll, "prebuilt U-Boot URL (optional; empty = builder default)")
        lay.addWidget(self.orangepi4lts_box)

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
        # Thin-desktop stream host (Sunshine; §8b) — tri-state like the Network
        # page's service toggles (G34: on / force-off / leave builder default).
        self.sunshine = QtWidgets.QCheckBox(
            "Thin-desktop stream host (Sunshine) — stream this desktop to mesh "
            "headsets over the tailnet only (default off)")
        self.sunshine.setTristate(True)
        self.sunshine.setToolTip(
            "Bakes Sunshine + a mesh-scoped nftables fence (stream ports admitted "
            "ONLY on the tailscale interface from 100.64/10; pairing web UI "
            "loopback-only) + an in-session autostart, so a mesh-enrolled Quest "
            "running Moonlight (the MDM Quest wizard's thin-desktop toggle) can "
            "open this desktop. Tailnet CLIENT desktops only — the builder "
            "warn-drops it on cluster roles and on tailnet-less desktops "
            "(standalone needs --with-tailscale). See docs/MDM.md 'Thin desktop'.")
        cl.addWidget(self.sunshine)
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
            "Unaffiliated (--unaffiliated) — plain Gentoo, zero HugMesh "
            "branding/tooling (composable)")
        cl.addWidget(self.unaffiliated)
        lay.addWidget(self.client_box)

        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: #a65d00;")
        lay.addWidget(self.note)
        lay.addStretch(1)
        self.roles.currentRowChanged.connect(self._role_changed)
        self.device_tree.currentItemChanged.connect(self._on_device_item_changed)
        self.arch_group.buttonToggled.connect(self._on_arch_toggled)
        self.device_search.textChanged.connect(self._apply_device_filter)
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

    # ---- device browser plumbing ---------------------------------------------------
    def _mode(self) -> str:
        mode = getattr(self.wiz.cfg, "mode", "") or "standalone"
        return mode if mode in ROLE_CHOICES else "standalone"

    def _refresh_device_statuses(self) -> None:
        """Per-mode honesty pass over every device row: status badge + selectability.
        UNSUPPORTED rows are visible but never selectable (reason shown, #351); a
        selectable device with zero roles in THIS mode is likewise unselectable here,
        with an inline explanation instead of a dead-end (e.g. rpi3 in standalone,
        the mesh-only Jetson boards in standalone/cloud)."""
        mode = self._mode()
        for did, item in self._device_items.items():
            dev = self._catalog.device(did)
            roles = device_catalog.roles_for(did, mode)
            if dev.status == "unsupported":
                badge, color = status_badge("unsupported")
                text = f"{badge} — {dev.reason}"
                pickable = False
            elif not roles:
                others = [m for m in ROLE_CHOICES if device_catalog.roles_for(did, m)]
                text = (f"no {mode} image — " + (dev.notes or
                        f"offered on the {'/'.join(others) or 'other'} path"))
                color = "#777777"
                pickable = False
            else:
                text, color = status_badge(dev.status)
                pickable = True
            item.setText(2, text)
            if color:
                item.setForeground(2, QtGui.QBrush(QtGui.QColor(color)))
            tip = device_catalog.status_reason(did) or dev.notes
            for col in range(3):
                item.setToolTip(col, tip)
            item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable
                          if pickable else Qt.ItemFlag.NoItemFlags)

    def _current_arch(self) -> str | None:
        btn = self.arch_group.checkedButton()
        return btn.property("arch") if btn is not None else None

    def _apply_device_filter(self, _text: str = "") -> None:
        """Arch + search filtering (presentation only — never touches cfg)."""
        arch = self._current_arch()
        hits = {d.id for d in self._catalog.search(self.device_search.text())}
        for fam in self._catalog.families:
            fitem = self._family_items[fam.id]
            any_visible = False
            for dev in self._catalog.devices_in_family(fam.id):
                show = (arch is None or dev.arch == arch) and dev.id in hits
                self._device_items[dev.id].setHidden(not show)
                any_visible = any_visible or show
            fitem.setHidden(not any_visible)

    def _on_arch_toggled(self, btn, checked) -> None:
        if not checked:
            return
        self._apply_device_filter()
        # keep the selection coherent with the arch tier: if the current device is now
        # filtered out, hop to the arch's first selectable device (cfg only changes at
        # validatePage, so this is presentation-safe).
        did = self._selected_device()
        arch = btn.property("arch")
        if did is not None and self._catalog.device(did).arch == arch:
            return
        for dev in self._catalog.devices_for_arch(arch):
            item = self._device_items[dev.id]
            if not item.isHidden() and item.flags() & Qt.ItemFlag.ItemIsSelectable:
                self.device_tree.setCurrentItem(item)
                return
        # an all-unsupported arch (ARMv7 / RISC-V today): NOTHING is selectable, so the
        # hidden prior device must not stay armed with its contradictory role list —
        # clear the selection outright (the item-changed handler disarms the role list
        # and Next) and say so honestly instead of a silent dead screen.
        self.device_tree.setCurrentItem(None)
        self.note.setText("No buildable device on this architecture yet — each row's "
                          "status column says why.")

    def _selected_device(self) -> str | None:
        it = self.device_tree.currentItem()
        return it.data(0, Qt.ItemDataRole.UserRole) if it is not None else None

    def _on_device_item_changed(self, cur, _prev) -> None:
        did = cur.data(0, Qt.ItemDataRole.UserRole) if cur is not None else None
        if did is None or not device_catalog.selectable(did):
            # KEYBOARD nav lands current on family HEADERS (they keep ItemIsEnabled so
            # they render normally, and QTreeView's moveCursor stops on enabled rows);
            # the arch tier may also clear the selection outright. Either way there is
            # NO chosen device now — DISARM the image-type list so isComplete() and
            # validatePage() both gate Next. Leaving the previous device's roles armed
            # would let a stale role pair with a fallback platform and emit an argv the
            # builder is guaranteed to hard-error on (#351).
            self._disarm_roles()
            return
        dev = self._catalog.device(did)
        prefer = (self._current_role_id() or self._role_pref
                  or self.wiz.cfg.role)
        self._populate_roles(did, prefer)
        self._update_boxes(dev.builder_platform)
        self._role_changed(self.roles.currentRow())
        self._apply_device_pin(dev)
        self.note.setText(device_catalog.status_reason(did)
                          if dev.status == "experimental" else "")
        self.completeChanged.emit()

    # last role the user actually picked in the list this visit — survives a keyboard
    # pass over a family header (the disarm clears the list) so re-landing on a device
    # restores the same image-type choice.
    _role_pref: str | None = None

    def _disarm_roles(self) -> None:
        """No device is chosen (current is a family header / cleared): empty the
        image-type list and re-evaluate isComplete(), disabling Next. The stale
        previous-device role list must never stay armed without its device (#351)."""
        pref = self._current_role_id()
        if pref is not None:
            self._role_pref = pref
        if self.roles.count():
            self.roles.blockSignals(True)
            self.roles.clear()
            self.roles.blockSignals(False)
        self.completeChanged.emit()

    _BOARD_COMBO_ATTR = {"rpi5": "rpi5_board", "jetson": "jetson_board",
                         "frite": "board", "orangepi5": "orangepi5_board"}

    def _apply_device_pin(self, dev) -> None:
        """The device pins the board axis: the per-platform board combo becomes a
        read-only identity display (one machine picker per flow — the browser)."""
        attr = self._BOARD_COMBO_ATTR.get(dev.builder_platform)
        if attr is None:
            return
        combo = getattr(self, attr)
        if dev.builder_board:
            combo.setCurrentText(dev.builder_board)
            combo.setEnabled(False)
            combo.setToolTip("Board pinned by the selected device — pick a different "
                             "device in the browser above to change it.")
        else:  # a platform-default device without a pinned board: keep it editable
            combo.setEnabled(True)
            combo.setToolTip("")

    # ---- machine / role plumbing -------------------------------------------------
    def _platforms_for_role(self, mode: str, role: str):
        for r, plats, _l in ROLE_CHOICES[mode]:
            if r == role:
                return plats
        return None

    def _selected_machine(self):
        did = self._selected_device()
        return self._catalog.device(did).builder_platform if did else None

    def _current_role(self):
        it = self.roles.currentItem()
        return (it.data(Qt.ItemDataRole.UserRole) if it
                else (self.wiz.cfg.role, (self._selected_machine() or "x86",)))

    def _current_role_id(self):
        it = self.roles.currentItem()
        return it.data(Qt.ItemDataRole.UserRole)[0] if it else None

    def _populate_roles(self, device_id: str, prefer: str) -> None:
        """Fill the image-type list with the roles the chosen DEVICE really supports
        (DERIVED: device_catalog.roles_for — the same ROLE_CHOICES[mode] catalog,
        narrowed by the device's board/role_allow gates); pre-select ``prefer``."""
        self.roles.blockSignals(True)
        self.roles.clear()
        target = None
        mode = self._mode()
        for role, label in device_catalog.roles_for(device_id, mode):
            platforms = self._platforms_for_role(mode, role)
            it = QtWidgets.QListWidgetItem(f"{role} — {label}")
            it.setData(Qt.ItemDataRole.UserRole, (role, platforms))
            try:
                # role-family glyph (presentation only — the row TEXT and UserRole
                # payload above are the selection/emission surface and stay
                # byte-identical). Guarded: an icon bug must never break the
                # role list, and under PyQt6 an escape here would qFatal.
                it.setIcon(choice_icons.icon(
                    choice_icons.role_icon_name(role, mode), 24,
                    choice_icons.style_for(self.palette()),
                    self.devicePixelRatioF()))
            except Exception:
                pass
            self.roles.addItem(it)
            if role == prefer:
                target = it
        if target is not None:
            self.roles.setCurrentItem(target)
        elif self.roles.count():
            self.roles.setCurrentRow(0)
        self.roles.blockSignals(False)

    def _update_boxes(self, machine: str) -> None:
        """Machine-driven inline knob visibility (same setVisible cascade the old
        card drove, now keyed on the selected device's platform)."""
        self.frite_box.setVisible(machine == "frite")
        self.jetson_box.setVisible(machine == "jetson")
        self.rpi5_box.setVisible(machine == "rpi5")
        self.orangepi5_box.setVisible(machine == "orangepi5")
        self.orangepizero2_box.setVisible(machine == "orangepizero2")
        self.orangepizero2w_box.setVisible(machine == "orangepizero2w")
        self.orangepizero3_box.setVisible(machine == "orangepizero3")
        self.orangepi3lts_box.setVisible(machine == "orangepi3-lts")
        self.orangepi4lts_box.setVisible(machine == "orangepi4-lts")
        # desktop weight / Steam are x86 desktop-image knobs (client + standalone)
        self.client_box.setVisible(machine == "x86"
                                   and self.wiz.cfg.mode in ("standalone", "cloud"))
        # the machine-profile preset lives with the x86 devices only (profiles.json is x86)
        x86 = machine == "x86"
        self.profile_row.setVisible(x86)
        self.profile_note.setVisible(x86)
        self.scan_out.setVisible(x86)

    # ---- test / navigation entry points ------------------------------------------
    def select_device(self, device_id: str) -> None:
        """Select a catalog device in the browser (aligns the arch tier, repopulates
        the image-type list). Raises KeyError for an unknown id; a non-selectable
        (unsupported / no-role-in-mode) device is left unselected — honesty gate."""
        dev = self._catalog.device(device_id)
        ab = self._arch_buttons.get(dev.arch)
        if ab is not None and not ab.isChecked():
            self.arch_group.blockSignals(True)
            ab.setChecked(True)
            self.arch_group.blockSignals(False)
            self._apply_device_filter()
        self.device_tree.setCurrentItem(self._device_items[device_id])

    def select_machine(self, plat: str) -> None:
        """Select the DEFAULT device for ``plat`` (compat shim for the established
        machine-first entry point; repopulates the image-type list)."""
        self.select_device(self._machine_buttons[plat])

    def select_role(self, role: str) -> bool:
        """Select a device that supports ``role`` (if the current one doesn't), then
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

    def isComplete(self) -> bool:
        """Next requires a real, SELECTABLE catalog device with >=1 derived role.
        Keyboard focus on a family header, an all-unsupported arch screen, or a
        zero-role device all leave Next disabled — the #351 gate at the button."""
        did = self._selected_device()
        return (did is not None and device_catalog.selectable(did)
                and self.roles.count() > 0)

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
                "Choose the architecture and target device, then the desktop type — "
                "thick (full desktop) / thin (light desktop) / unaffiliated (plain "
                "Gentoo, no HugMesh).")
        else:  # cloud — the mesh desktop CLIENT that joins an existing mesh
            self.setSubTitle(
                "Choose the architecture and target device, then the client desktop "
                "type it runs.")
        # per-mode honesty pass over the browser rows (role derivation is mode-scoped)
        self._refresh_device_statuses()
        # resolve the default machine EXACTLY as before: c.platform if it is a
        # supported platform of c.role, else the role's first platform; then map the
        # (platform, board) axes back to their catalog device (supported preferred,
        # so (rpi5, rpi4) resolves to the Pi 4 itself, not an experimental alias).
        role_plats = self._platforms_for_role(c.mode, c.role)
        mode_machines = {p for _r, plats, _l in ROLE_CHOICES[c.mode] for p in plats}
        if role_plats:
            default_machine = c.platform if c.platform in role_plats else role_plats[0]
        else:
            default_machine = next((p for p in self._all_machines if p in mode_machines),
                                   "x86")
        try:
            did = device_catalog.device_for_axes(
                default_machine, c.board if c.platform == default_machine else "")
        except ValueError:   # stale/foreign board value: fall back to the default device
            did = self._machine_buttons.get(default_machine) \
                or device_catalog.default_device_for_platform(default_machine)
        # device_for_axes prefers the SUPPORTED device for shared axes — but if THIS
        # page committed an experimental alias with the same axes (Pi 400 → (rpi5,
        # rpi4)), restore the alias itself on Back-navigation so its EXPERIMENTAL
        # label and fail-loud note survive the round-trip.
        last = getattr(self, "_committed_device", None)
        if last is not None and last != did:
            ldev = self._catalog.device(last)
            if (device_catalog.selectable(last)
                    and ldev.builder_platform == default_machine
                    and ldev.builder_board ==
                        self._catalog.device(did).builder_board):
                did = last
        dev = self._catalog.device(did)
        ab = self._arch_buttons.get(dev.arch)
        if ab is not None:
            self.arch_group.blockSignals(True)
            ab.setChecked(True)
            self.arch_group.blockSignals(False)
        self._apply_device_filter()
        self.device_tree.blockSignals(True)
        self.device_tree.setCurrentItem(self._device_items[did])
        self.device_tree.blockSignals(False)
        self._populate_roles(did, c.role)
        self._update_boxes(default_machine)
        self._role_changed(self.roles.currentRow())
        self.note.setText(device_catalog.status_reason(did)
                          if dev.status == "experimental" else "")
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
            elif c.platform == "orangepizero2w":
                self.orangepizero2w_flavor.setCurrentText(c.flavor)
            elif c.platform == "orangepizero3":
                self.orangepizero3_flavor.setCurrentText(c.flavor)
            elif c.platform == "orangepi3-lts":
                self.orangepi3lts_flavor.setCurrentText(c.flavor)
            elif c.platform == "orangepi4-lts":
                self.orangepi4lts_flavor.setCurrentText(c.flavor)
            else:
                self.flavor.setCurrentText(c.flavor)
        if c.platform == "frite" and c.desktop:
            self.frite_desktop.setCurrentText(c.desktop)
        elif c.desktop:
            self.desktop.setCurrentText(c.desktop)
        if c.steam:
            self.steam.setCurrentText(c.steam)
        self.sunshine.setCheckState(_tri_state(c.sunshine))
        # one config field triple mirrored into every box's u-boot widget set (G35)
        for url_w, defconfig_w, skip_w in (
                (self.frite_uboot_url, self.frite_uboot_defconfig, self.frite_skip_uboot),
                (self.orangepi5_uboot_url, self.orangepi5_uboot_defconfig,
                 self.orangepi5_skip_uboot),
                (self.orangepizero2_uboot_url, self.orangepizero2_uboot_defconfig,
                 self.orangepizero2_skip_uboot),
                (self.orangepizero2w_uboot_url, self.orangepizero2w_uboot_defconfig,
                 self.orangepizero2w_skip_uboot),
                (self.orangepizero3_uboot_url, self.orangepizero3_uboot_defconfig,
                 self.orangepizero3_skip_uboot),
                (self.orangepi3lts_uboot_url, self.orangepi3lts_uboot_defconfig,
                 self.orangepi3lts_skip_uboot),
                (self.orangepi4lts_uboot_url, self.orangepi4lts_uboot_defconfig,
                 self.orangepi4lts_skip_uboot)):
            url_w.setText(c.uboot_url)
            defconfig_w.setText(c.uboot_defconfig)
            skip_w.setChecked(c.skip_uboot)
        self.kernel_flavor.setCurrentIndex(max(0, self.kernel_flavor.findData(c.kernel_flavor or "")))
        self.capable.setChecked(c.capable)
        # only restore where the compose is legal (_role_changed may have just
        # disabled + cleared the checkbox for this mode/role)
        self.unaffiliated.setChecked(c.unaffiliated and self.unaffiliated.isEnabled())
        # the device pins the board combo LAST (after the c.board restore above — the
        # restore and the pin agree by construction, device_for_axes ate c.board).
        self._apply_device_pin(dev)

    def _role_changed(self, _row):
        role, _platforms = self._current_role()
        machine = self._selected_machine() or "x86"
        # rpi3 is DESKTOP-ONLY (1GB RAM): a node/appliance rpi5 role (generic) must not
        # offer it — mirror the builder's hard-error at the SELECTION layer so the pick
        # can't dead-end. Repopulate the board list per role-class, preserving a still-
        # valid selection (rpi5/rpi4) across a role switch. (With the device browser
        # this is structural anyway — the rpi3 DEVICE derives no node roles at all.)
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
        # x86 desktop-weight combo per role (same honesty rule / same repopulate
        # pattern as the rpi3 board gate above): client roles take thin|full, a
        # weight-pinning standalone role offers ONLY its own weight — the builder
        # hard-errors a contradictory explicit --desktop, so the combo must never
        # offer a pick that dead-ends there. "(default)" (= the role's built-in
        # weight) always stays. Node roles reduce to just "(default)" — moot, the
        # client box is hidden outside standalone/cloud anyway.
        if machine == "x86":
            weights = ["(default)"] + list(x86_desktop_axis(role))
            if [self.desktop.itemText(i) for i in range(self.desktop.count())] != weights:
                keep = self.desktop.currentText()
                self.desktop.blockSignals(True)
                self.desktop.clear()
                self.desktop.addItems(weights)
                if keep in weights:
                    self.desktop.setCurrentText(keep)
                self.desktop.blockSignals(False)
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
        # #351 gate (belt & braces under isComplete): REFUSE to commit unless a real
        # selectable device is current — never fall back to a default platform, which
        # would pair a stale role with the wrong builder and emit a guaranteed-broken
        # argv (e.g. '--role rpi5-desktop' at build-x86-host-stage4.sh). Returning
        # False before any cfg write keeps the last committed config intact.
        did = self._selected_device()
        if did is None or not device_catalog.selectable(did):
            return False
        c = self.wiz.cfg
        role, _platforms = self._current_role()
        c.role = role
        c.platform = self._selected_machine()
        # remember the exact DEVICE committed (an experimental alias like the Pi 400
        # shares its supported sibling's (platform, board) axes — initializePage
        # restores the alias itself on Back-navigation, keeping its label + note).
        self._committed_device = did
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
        # defaults bundle_source ON for standalone mode, but bundling the HugMesh
        # generator source is a builder HARD CONFLICT on an unaffiliated image —
        # clear it here so the wizard default cannot poison the argv.
        if c.role == UNAFFILIATED_ROLE or c.unaffiliated:
            c.bundle_source = False
            # Every branding field is a builder HARD CONFLICT on an unaffiliated
            # image (_check_unaffiliated_conflicts: "branding assets (… — nothing
            # to theme against)"), so clear them HERE, at the moment the role is
            # committed, rather than relying on the BrandingPage's own
            # validatePage. That page is now SKIPPED for this role (applies_to),
            # and a skipped page never validates — so an operator who set a theme
            # and then switched to unaffiliated would otherwise carry the stale
            # value straight into a ValueError at preview/build time. Clearing at
            # the commit point is also what makes the skip emission-neutral, the
            # documented precondition for applies_to() returning False.
            c.theme = c.branding_dir = c.wallpaper = c.grub_background = ""
            c.grub_theme = c.login_background = c.brand_logo = ""
            c.accent_color = c.color_scheme = ""
            c.brand_locked = False
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
        elif c.platform == "orangepizero2w":
            c.board = ""
            c.flavor = self.orangepizero2w_flavor.currentText()
            c.desktop = ""
            c.uboot_url = self.orangepizero2w_uboot_url.text().strip()
            c.uboot_defconfig = self.orangepizero2w_uboot_defconfig.text().strip()
            c.skip_uboot = self.orangepizero2w_skip_uboot.isChecked()
        elif c.platform == "orangepizero3":
            c.board = ""
            c.flavor = self.orangepizero3_flavor.currentText()
            c.desktop = ""
            c.uboot_url = self.orangepizero3_uboot_url.text().strip()
            c.uboot_defconfig = self.orangepizero3_uboot_defconfig.text().strip()
            c.skip_uboot = self.orangepizero3_skip_uboot.isChecked()
        elif c.platform == "orangepi3-lts":
            c.board = ""
            c.flavor = self.orangepi3lts_flavor.currentText()
            c.desktop = ""
            c.uboot_url = self.orangepi3lts_uboot_url.text().strip()
            c.uboot_defconfig = self.orangepi3lts_uboot_defconfig.text().strip()
            c.skip_uboot = self.orangepi3lts_skip_uboot.isChecked()
        elif c.platform == "orangepi4-lts":
            c.board = ""
            c.flavor = self.orangepi4lts_flavor.currentText()
            # no --desktop axis (one role, no headless variant) — same as orangepi5
            c.desktop = ""
            c.uboot_url = self.orangepi4lts_uboot_url.text().strip()
            c.uboot_defconfig = self.orangepi4lts_uboot_defconfig.text().strip()
            c.skip_uboot = self.orangepi4lts_skip_uboot.isChecked()
        else:
            c.board = ""
            c.flavor = ""
            weight = self.desktop.currentText()
            c.desktop = "" if (weight == "(default)" or not x86_client) else weight
        steam = self.steam.currentText()
        c.steam = "" if (steam == "(default)" or not x86_client) else steam
        # sunshine: tri-state (True / "off" / False-as-default); False when the
        # client box is not on this build's surface — mirrors steam's x86_client
        # blanking so a stale value never rides a server/ARM argv.
        c.sunshine = _tri_value(self.sunshine) if x86_client else False
        # machine-profile preset (folded from Hardware): NON_ARGV round-trip field.
        # x86-only (the picker is hidden on ARM devices) so a stale x86 profile can't
        # linger on an ARM build's saved config.
        c.hw_profile = (self.profile.currentData() or "") if c.platform == "x86" else ""
        return True
