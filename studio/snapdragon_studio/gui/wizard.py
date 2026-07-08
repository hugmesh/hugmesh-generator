"""The Snapdragon Image Studio wizard — a Calamares-style page-based flow that surfaces
the WHOLE build flag surface (mode, hardware, branding, network/SSO, admin key-zip,
superadmin domains+users, home, build) and runs the build natively or via Docker.
"""
from __future__ import annotations

import os

from .qt import Qt, QtCore, QtGui, QtWidgets, Signal
from ..core import hw_scan, keyzip, profiles
from ..core.build_driver import BuildDriver
from ..core.config import (
    Domain, ImageConfig, MODE_DEFAULT_ROLE, User,
    ENV_CHOICES, FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS,
    GPU_DRIVER_ALIASES, GPU_DRIVER_CHOICES, JETSON_BOARDS,
    OPTIONAL_SERVICES_CHOICES, PLATFORM_LABELS, ROLE_CHOICES, UNAFFILIATED_ROLE,
)
from ..core.platform_info import detect


# ── small helpers ────────────────────────────────────────────────────────────
def _row(label, widget):
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    lab = QtWidgets.QLabel(label)
    lab.setMinimumWidth(150)
    h.addWidget(lab)
    h.addWidget(widget, 1)
    return w


def _file_picker(parent, line_edit, caption, file_filter="All files (*)", directory=False):
    def pick():
        if directory:
            p = QtWidgets.QFileDialog.getExistingDirectory(parent, caption)
        else:
            p, _ = QtWidgets.QFileDialog.getOpenFileName(parent, caption, "", file_filter)
        if p:
            line_edit.setText(p)
    btn = QtWidgets.QPushButton("Browse…")
    btn.clicked.connect(pick)
    return btn


# ── pages ────────────────────────────────────────────────────────────────────
class WelcomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Snapdragon Image Studio")
        self.setSubTitle("Build a hardened Gentoo desktop, a branded cloud image, or a mesh node.")
        lay = QtWidgets.QVBoxLayout(self)
        info = QtWidgets.QLabel(
            "This studio assembles and runs a Snapdragon image build.\n\n"
            f"Backend: <b>{wiz.host.default_backend}</b> ({wiz.host.summary()})\n\n"
            "On Gentoo it can build natively; everywhere else (including Windows) it drives "
            "the dockerized build. Everything you set here maps to the generator's flags.")
        info.setWordWrap(True)
        info.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(info)
        btns = QtWidgets.QHBoxLayout()
        load = QtWidgets.QPushButton("Load config…")
        save = QtWidgets.QPushButton("Save config…")
        load.clicked.connect(self._load)
        save.clicked.connect(self._save)
        btns.addWidget(load)
        btns.addWidget(save)
        btns.addStretch(1)
        lay.addLayout(btns)
        lay.addStretch(1)

    def _load(self):
        p, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Load config", "", "JSON (*.json)")
        if p:
            self.wiz.cfg = ImageConfig.load(p)
            QtWidgets.QMessageBox.information(self, "Loaded", f"Loaded {p}")
            # already-constructed pages won't repopulate on their own — restart the wizard
            # so each page's initializePage() re-reads from the freshly loaded config.
            self.wiz.restart()

    def _save(self):
        p, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Save config", "snapdragon-image.json", "JSON (*.json)")
        if p:
            self.wiz.collect_all()
            warnings = self.wiz.cfg.save(p)
            if warnings:  # plaintext secrets are blanked on save — tell the user
                QtWidgets.QMessageBox.warning(self, "Passwords not saved", "\n".join(warnings))


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
        return True


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
        lay.addWidget(self.frite_box)

        # jetson board knob (visible only when platform == jetson)
        self.jetson_box = QtWidgets.QGroupBox("Jetson Orin board options")
        jl = QtWidgets.QVBoxLayout(self.jetson_box)
        self.jetson_board = QtWidgets.QComboBox()
        self.jetson_board.addItems(list(JETSON_BOARDS))
        jl.addWidget(_row("Board", self.jetson_board))
        lay.addWidget(self.jetson_box)

        # x86 client knobs: desktop weight + Steam delivery
        self.client_box = QtWidgets.QGroupBox("Client desktop options")
        cl = QtWidgets.QVBoxLayout(self.client_box)
        self.desktop = QtWidgets.QComboBox()
        self.desktop.addItems(["(default)", "thin", "full"])
        self.steam = QtWidgets.QComboBox()
        self.steam.addItems(["(default)", "native", "flatpak", "none"])
        cl.addWidget(_row("Desktop weight", self.desktop))
        cl.addWidget(_row("Steam delivery", self.steam))
        lay.addWidget(self.client_box)

        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color: #a65d00;")
        lay.addWidget(self.note)
        lay.addStretch(1)
        self.roles.currentRowChanged.connect(self._role_changed)
        self.platform.currentIndexChanged.connect(self._platform_changed)

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
            else:
                self.board.setCurrentText(c.board)
        if c.flavor:
            self.flavor.setCurrentText(c.flavor)
        if c.platform == "frite" and c.desktop:
            self.frite_desktop.setCurrentText(c.desktop)
        elif c.desktop:
            self.desktop.setCurrentText(c.desktop)
        if c.steam:
            self.steam.setCurrentText(c.steam)

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
        # desktop weight / Steam are x86 desktop-image knobs (client + standalone)
        self.client_box.setVisible(plat == "x86" and self.wiz.cfg.mode in ("standalone", "cloud"))
        self.note.setText("EXPERIMENTAL — hardware validation pending (specs-jetson/README.md); "
                          "the Jetson builder is being brought up." if plat == "jetson" else "")

    def validatePage(self):
        c = self.wiz.cfg
        role, _platforms = self._current_role()
        c.role = role
        c.platform = self.platform.currentData() or "x86"
        # Unaffiliated build: ModePage defaults bundle_source ON for standalone mode,
        # but bundling the Snapdragon generator source is a builder HARD CONFLICT on
        # this role — clear it here so the wizard default cannot poison the argv.
        if c.role == UNAFFILIATED_ROLE:
            c.bundle_source = False
        if c.platform == "frite":
            c.board = self.board.currentText()
            c.flavor = self.flavor.currentText()
            c.desktop = self.frite_desktop.currentText()
        else:
            # jetson carries a board axis of its own; every other platform has none
            c.board = self.jetson_board.currentText() if c.platform == "jetson" else ""
            c.flavor = ""
            weight = self.desktop.currentText()
            c.desktop = "" if (weight == "(default)" or not self.client_box.isVisible()) else weight
        steam = self.steam.currentText()
        c.steam = "" if (steam == "(default)" or not self.client_box.isVisible()) else steam
        return True


class HardwarePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Target hardware")
        self.setSubTitle("Pick a machine, or scan the one you're on.")
        lay = QtWidgets.QVBoxLayout(self)
        self.profile = QtWidgets.QComboBox()
        self.profiles = profiles.load(wiz.generator_dir)
        self.profile.addItem("(none / generic)", "")
        for p in self.profiles:
            self.profile.addItem(p.label, p.id)
        lay.addWidget(_row("Machine profile", self.profile))

        self.scan_btn = QtWidgets.QPushButton("Scan THIS machine")
        self.scan_btn.clicked.connect(self._scan)
        lay.addWidget(self.scan_btn)
        self.scan_out = QtWidgets.QLabel("")
        self.scan_out.setWordWrap(True)
        self.scan_out.setStyleSheet("color: #3f5b8c;")
        lay.addWidget(self.scan_out)

        # the builder's FULL documented --gpu-driver matrix (canonical names; the
        # builder's vendor aliases like "intel" are normalized via _set_gpu below)
        self.gpu = QtWidgets.QComboBox()
        self.gpu.addItems(list(GPU_DRIVER_CHOICES))
        lay.addWidget(_row("GPU driver", self.gpu))
        self.wifi = QtWidgets.QCheckBox("Enable Wi-Fi (off by default — hardened)")
        self.bt = QtWidgets.QCheckBox("Enable Bluetooth (off by default — hardened)")
        self.builtin = QtWidgets.QCheckBox("Compile most everything into the kernel (built-in, not modules)")
        lay.addWidget(self.wifi)
        lay.addWidget(self.bt)
        lay.addWidget(self.builtin)
        lay.addStretch(1)
        self.profile.currentIndexChanged.connect(self._profile_changed)

    def _set_gpu(self, value):
        """Select a combo entry; builder vendor aliases (hwprofiles say 'intel')
        normalize to the canonical id so they can't silently fail to match."""
        self.gpu.setCurrentText(GPU_DRIVER_ALIASES.get(value, value) or "auto")

    def _profile_changed(self):
        pid = self.profile.currentData()
        if pid == "this-machine-scan":
            self._scan()
            return
        p = next((x for x in self.profiles if x.id == pid), None)
        if p:
            self._set_gpu(p.gpu_driver)
            self.wifi.setChecked(p.enable_wifi)
            self.bt.setChecked(p.enable_bluetooth)

    def _scan(self):
        s = hw_scan.scan()
        self._set_gpu(s.recommended_gpu_driver)
        self.wifi.setChecked(s.recommend_wifi)
        self.bt.setChecked(s.recommend_bluetooth)
        gpus = ", ".join(g.name for g in s.gpus) or "none"
        self.scan_out.setText(f"CPU: {s.cpu or '?'}  ·  GPU: {gpus}  ·  "
                              f"recommended driver: {s.recommended_gpu_driver}"
                              + (f"  ·  Wi-Fi: {s.wifi}" if s.wifi else ""))

    def initializePage(self):
        c = self.wiz.cfg
        self._set_gpu(c.gpu_driver)
        self.wifi.setChecked(c.enable_wifi)
        self.bt.setChecked(c.enable_bluetooth)
        self.builtin.setChecked(c.kernel_builtin)

    def validatePage(self):
        c = self.wiz.cfg
        c.gpu_driver = self.gpu.currentText()
        c.enable_wifi = self.wifi.isChecked()
        c.enable_bluetooth = self.bt.isChecked()
        c.kernel_builtin = self.builtin.isChecked()
        c.hw_profile = self.profile.currentData() or ""
        return True


class BrandingPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Branding")
        self.setSubTitle("Boot screen, login, wallpaper, accent — consistent across the desktop.")
        lay = QtWidgets.QVBoxLayout(self)
        # shown INSTEAD of the (disabled) form when the unaffiliated role is selected
        self.unaffiliated_note = QtWidgets.QLabel(
            "Branding does not apply — unaffiliated build (plain Gentoo, zero brand identity).")
        self.unaffiliated_note.setWordWrap(True)
        self.unaffiliated_note.setStyleSheet("color: #a65d00;")
        self.unaffiliated_note.setVisible(False)
        lay.addWidget(self.unaffiliated_note)
        # every branding widget lives in one container so the unaffiliated role can
        # disable the whole surface (line edits AND their Browse… buttons) at once
        self.form = QtWidgets.QWidget()
        form_lay = QtWidgets.QVBoxLayout(self.form)
        form_lay.setContentsMargins(0, 0, 0, 0)
        self.theme = QtWidgets.QComboBox()
        self.theme.setEditable(True)
        self.theme.addItem("")
        for t in self._themes():
            self.theme.addItem(t)
        form_lay.addWidget(_row("Theme preset", self.theme))
        self.fields = {}
        for key, label, flt in (
            ("wallpaper", "Wallpaper", "Images (*.png *.jpg *.jpeg)"),
            ("grub_background", "GRUB background", "Images (*.png)"),
            ("login_background", "Login background", "Images (*.png *.jpg)"),
            ("brand_logo", "Brand logo", "Images (*.png)"),
        ):
            le = QtWidgets.QLineEdit()
            btn = _file_picker(self, le, label, flt)
            w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(le, 1); h.addWidget(btn)
            form_lay.addWidget(_row(label, w))
            self.fields[key] = le
        self.accent = QtWidgets.QLineEdit()
        self.accent.setPlaceholderText("#3f5b8c")
        form_lay.addWidget(_row("Accent colour", self.accent))
        self.locked = QtWidgets.QCheckBox("Lock branding (user cannot re-theme — managed image)")
        form_lay.addWidget(self.locked)
        lay.addWidget(self.form)
        lay.addStretch(1)

    def _themes(self):
        d = os.path.join(self.wiz.generator_dir, "specs-x86", "branding", "themes")
        try:
            return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x)))
        except OSError:
            return ["boogiepop"]

    def initializePage(self):
        c = self.wiz.cfg
        unaffiliated = c.role == UNAFFILIATED_ROLE
        self.unaffiliated_note.setVisible(unaffiliated)
        self.form.setEnabled(not unaffiliated)
        self.theme.setCurrentText(c.theme)
        self.fields["wallpaper"].setText(c.wallpaper)
        self.fields["grub_background"].setText(c.grub_background)
        self.fields["login_background"].setText(c.login_background)
        self.fields["brand_logo"].setText(c.brand_logo)
        self.accent.setText(c.accent_color)
        self.locked.setChecked(c.brand_locked)

    def validatePage(self):
        c = self.wiz.cfg
        if c.role == UNAFFILIATED_ROLE:
            # branding is a builder HARD CONFLICT on the unaffiliated role — clear
            # anything left over from a previously selected role instead of collecting
            # the (disabled) widgets, so a role switch cannot poison the argv.
            c.theme = c.wallpaper = c.grub_background = ""
            c.login_background = c.brand_logo = c.accent_color = ""
            c.brand_locked = False
            return True
        c.theme = self.theme.currentText().strip()
        c.wallpaper = self.fields["wallpaper"].text().strip()
        c.grub_background = self.fields["grub_background"].text().strip()
        c.login_background = self.fields["login_background"].text().strip()
        c.brand_logo = self.fields["brand_logo"].text().strip()
        c.accent_color = self.accent.text().strip()
        c.brand_locked = self.locked.isChecked()
        return True


class NetworkPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Network, identity & egress")
        lay = QtWidgets.QVBoxLayout(self)
        self.tailscale = QtWidgets.QCheckBox("Join the tailnet (tailscale/headscale)")
        self.sso = QtWidgets.QCheckBox("Enable SSO login (Casdoor)")
        lay.addWidget(self.tailscale)
        lay.addWidget(self.sso)
        self.brand = QtWidgets.QLineEdit()
        self.brand_title = QtWidgets.QLineEdit()
        self.domain = QtWidgets.QLineEdit()
        lay.addWidget(_row("Brand id", self.brand))
        lay.addWidget(_row("Brand title", self.brand_title))
        lay.addWidget(_row("Cluster domain", self.domain))
        # egress VPN
        self.egress = QtWidgets.QLineEdit()
        ebtn = _file_picker(self, self.egress, "Egress VPN conf", "VPN (*.conf *.ovpn *.nmconnection)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.egress, 1); h.addWidget(ebtn)
        lay.addWidget(_row("Egress VPN", w))
        self.egress_locked = QtWidgets.QCheckBox("Lock egress VPN (managed node — user cannot remove)")
        lay.addWidget(self.egress_locked)
        # network/host security stack
        sec = QtWidgets.QGroupBox("Security stack")
        sl = QtWidgets.QVBoxLayout(sec)
        self.proxy_stack = QtWidgets.QCheckBox("Proxy stack — Squid (cache) + Privoxy (filter), wired into Firefox (desktops)")
        self.snort = QtWidgets.QCheckBox("Snort IDS (network intrusion detection)")
        self.aide = QtWidgets.QCheckBox("AIDE file-integrity IDS (DB baselined at first boot)")
        sl.addWidget(self.proxy_stack); sl.addWidget(self.snort); sl.addWidget(self.aide)
        # Root SSH login — hardened DEFAULT is "no" (root locked; the non-root KEYS admin
        # is the entry point). Tri-state, matching --permit-root-login / the build-menu.
        self.root_login = QtWidgets.QComboBox()
        self.root_login.addItems(["no", "prohibit-password", "yes"])
        sl.addWidget(_row("Root SSH login", self.root_login))
        lay.addWidget(sec)
        # edge-AI inference (GPU cluster roles — cloud/mesh). Serves an OpenAI-compatible
        # model API to the mesh; the model library (runtime/preload/default) is tunable.
        self.edge_ai_box = QtWidgets.QGroupBox("Edge-AI inference (GPU model API to the mesh)")
        el = QtWidgets.QVBoxLayout(self.edge_ai_box)
        self.edge_ai = QtWidgets.QCheckBox(
            "Serve an OpenAI-compatible model API on the GPU node (edge_ai role / be+gpu / omnibus)")
        el.addWidget(self.edge_ai)
        self.edge_ai_runtime = QtWidgets.QComboBox()
        self.edge_ai_runtime.addItems(["ollama", "vllm"])
        el.addWidget(_row("Runtime", self.edge_ai_runtime))
        self.edge_ai_models = QtWidgets.QLineEdit()
        self.edge_ai_models.setPlaceholderText("llama3.2:3b,nomic-embed-text  (empty = builder default)")
        el.addWidget(_row("Preload models", self.edge_ai_models))
        self.edge_ai_default = QtWidgets.QLineEdit()
        self.edge_ai_default.setPlaceholderText("llama3.2:3b  (empty = builder default)")
        el.addWidget(_row("Default model", self.edge_ai_default))
        self.edge_ai_analysis = QtWidgets.QCheckBox(
            "Analysis API — image NSFW/abuse classify + perceptual-hash, log triage (separate image)")
        el.addWidget(self.edge_ai_analysis)
        lay.addWidget(self.edge_ai_box)
        # Tor v3 onion (hidden) service (node-scoped; cloud/mesh cluster node builds).
        self.tor_onion = QtWidgets.QCheckBox(
            "Tor v3 onion service — expose the cluster gateway as a .onion (default off)")
        lay.addWidget(self.tor_onion)
        # Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate).
        # Cloud/mesh cluster builds only (it is a frontend cluster service).
        self.character_studio = QtWidgets.QCheckBox(
            "Character Studio (VN) — character creator + chat remote at /character-studio (default off)")
        lay.addWidget(self.character_studio)
        # cluster optional services (--optional-services multi-select) + the games stack
        self.services_box = QtWidgets.QGroupBox("Optional cluster services (--optional-services)")
        svl = QtWidgets.QVBoxLayout(self.services_box)
        self.services = QtWidgets.QListWidget()
        self.services.setMaximumHeight(140)
        for slug in OPTIONAL_SERVICES_CHOICES:
            it = QtWidgets.QListWidgetItem(slug)
            it.setFlags(it.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            it.setCheckState(Qt.CheckState.Unchecked)
            self.services.addItem(it)
        svl.addWidget(self.services)
        self.games = QtWidgets.QCheckBox(
            "Enable games — bake the Snapdragon Game Studio + the games.<domain> service")
        svl.addWidget(self.games)
        lay.addWidget(self.services_box)
        lay.addStretch(1)

    def initializePage(self):
        c = self.wiz.cfg
        self.proxy_stack.setChecked(c.proxy_stack in ("on", "auto"))
        self.snort.setChecked(c.snort)
        self.aide.setChecked(c.aide)
        self.root_login.setCurrentText(c.root_login or "no")
        self.tailscale.setChecked(c.tailscale or c.mode in ("cloud", "mesh"))
        self.sso.setChecked(c.sso or c.mode in ("cloud", "mesh"))
        self.brand.setText(c.brand)
        self.brand_title.setText(c.brand_title)
        self.domain.setText(c.cluster_domain)
        self.egress.setText(c.egress_vpn)
        self.egress_locked.setChecked(c.egress_vpn_locked)
        self.edge_ai.setChecked(c.edge_ai_service or c.role == "edge_ai")
        self.edge_ai_runtime.setCurrentText(c.edge_ai_runtime or "ollama")
        self.edge_ai_models.setText(c.edge_ai_models)
        self.edge_ai_default.setText(c.edge_ai_model_default)
        self.edge_ai_analysis.setChecked(c.edge_ai_analysis)
        # edge-AI is a GPU CLUSTER service — only meaningful for cloud/mesh node builds.
        self.edge_ai_box.setVisible(c.mode in ("cloud", "mesh"))
        self.tor_onion.setChecked(c.tor_onion_service)
        # Tor is a k8s-NODE service — only meaningful for cloud/mesh cluster builds.
        self.tor_onion.setVisible(c.mode in ("cloud", "mesh"))
        self.character_studio.setChecked(c.character_studio)
        # Character Studio is a frontend CLUSTER service — cloud/mesh builds only.
        self.character_studio.setVisible(c.mode in ("cloud", "mesh"))
        for i in range(self.services.count()):
            it = self.services.item(i)
            it.setCheckState(Qt.CheckState.Checked if it.text() in c.optional_services
                             else Qt.CheckState.Unchecked)
        self.games.setChecked(c.enable_games)
        # optional services live on CLUSTER nodes — cloud/mesh builds only.
        self.services_box.setVisible(c.mode in ("cloud", "mesh"))

    def validatePage(self):
        c = self.wiz.cfg
        c.tailscale = self.tailscale.isChecked()
        c.sso = self.sso.isChecked()
        c.brand = self.brand.text().strip() or "snapdragon"
        c.brand_title = self.brand_title.text().strip() or "Snapdragon Systems"
        c.cluster_domain = self.domain.text().strip() or "snapdragon.systems"
        c.egress_vpn = self.egress.text().strip()
        c.egress_vpn_locked = self.egress_locked.isChecked()
        c.proxy_stack = "on" if self.proxy_stack.isChecked() else "off"
        c.snort = self.snort.isChecked()
        c.aide = self.aide.isChecked()
        c.root_login = self.root_login.currentText()
        c.edge_ai_service = self.edge_ai.isChecked()
        c.edge_ai_runtime = self.edge_ai_runtime.currentText()
        c.edge_ai_models = self.edge_ai_models.text().strip()
        c.edge_ai_model_default = self.edge_ai_default.text().strip()
        c.edge_ai_analysis = self.edge_ai_analysis.isChecked()
        c.tor_onion_service = self.tor_onion.isChecked()
        c.character_studio = self.character_studio.isChecked()
        c.optional_services = [self.services.item(i).text() for i in range(self.services.count())
                               if self.services.item(i).checkState() == Qt.CheckState.Checked]
        c.enable_games = self.games.isChecked()
        return True


class KeyZipPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Admin key-zip (optional)")
        self.setSubTitle("Drop in the zip your domain admin generated for you (keys, certs, egress, branding).")
        lay = QtWidgets.QVBoxLayout(self)
        self.path = QtWidgets.QLineEdit()
        btn = _file_picker(self, self.path, "Admin key-zip", "Zip (*.zip)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.path, 1); h.addWidget(btn)
        lay.addWidget(_row("Key-zip", w))
        imp = QtWidgets.QPushButton("Import & apply")
        imp.clicked.connect(self._import)
        lay.addWidget(imp)
        self.out = QtWidgets.QLabel("")
        self.out.setWordWrap(True)
        lay.addWidget(self.out)
        lay.addStretch(1)

    def _import(self):
        p = self.path.text().strip()
        if not p or not os.path.exists(p):
            self.out.setText("Pick a .zip first.")
            return
        try:
            staging = os.path.join(os.path.expanduser("~"), ".snapdragon", "keyzip")
            c = keyzip.extract(p, staging)
            c.apply_to(self.wiz.cfg)
            self.wiz.cfg.keyzip = p
            self.out.setText(f"Imported: {c.summary()}"
                             + (f"  ·  warnings: {'; '.join(c.warnings)}" if c.warnings else ""))
        except (OSError, ValueError) as e:
            self.out.setText(f"Failed: {e}")

    def isComplete(self):
        return True


class DomainsPage(QtWidgets.QWizardPage):
    """Superadmin: define domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Domains (superadmin)")
        lay = QtWidgets.QVBoxLayout(self)
        self.table = QtWidgets.QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["Domain", "Title", "Games"])
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        btns = QtWidgets.QHBoxLayout()
        add = QtWidgets.QPushButton("Add domain")
        rem = QtWidgets.QPushButton("Remove selected")
        add.clicked.connect(lambda: self._add())
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)

    def _add(self, name="", title="", games=False):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, 0, QtWidgets.QTableWidgetItem(name))
        self.table.setItem(r, 1, QtWidgets.QTableWidgetItem(title))
        chk = QtWidgets.QTableWidgetItem()
        chk.setCheckState(Qt.CheckState.Checked if games else Qt.CheckState.Unchecked)
        self.table.setItem(r, 2, chk)

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)

    def initializePage(self):
        if self.table.rowCount() == 0:
            for d in self.wiz.cfg.domains:
                self._add(d.name, d.title, d.games)

    def validatePage(self):
        out = []
        for r in range(self.table.rowCount()):
            name = self.table.item(r, 0).text().strip() if self.table.item(r, 0) else ""
            if not name:
                continue
            title = self.table.item(r, 1).text().strip() if self.table.item(r, 1) else ""
            games = self.table.item(r, 2).checkState() == Qt.CheckState.Checked if self.table.item(r, 2) else False
            out.append(Domain(name=name, title=title or name, games=games))
        self.wiz.cfg.domains = out
        return True


class UsersPage(QtWidgets.QWizardPage):
    """Superadmin: attach users to domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Users (superadmin)")
        lay = QtWidgets.QVBoxLayout(self)
        self.table = QtWidgets.QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Username", "Domain", "Role", "Email"])
        self.table.horizontalHeader().setStretchLastSection(True)
        lay.addWidget(self.table)
        btns = QtWidgets.QHBoxLayout()
        add = QtWidgets.QPushButton("Add user")
        rem = QtWidgets.QPushButton("Remove selected")
        add.clicked.connect(lambda: self._add())
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)

    def _add(self, username="", domain="", role="user", email=""):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, 0, QtWidgets.QTableWidgetItem(username))
        self.table.setItem(r, 1, QtWidgets.QTableWidgetItem(domain))
        combo = QtWidgets.QComboBox(); combo.addItems(["superadmin", "admin", "mod", "user"])
        combo.setCurrentText(role)
        self.table.setCellWidget(r, 2, combo)
        self.table.setItem(r, 3, QtWidgets.QTableWidgetItem(email))

    def _remove(self):
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            self.table.removeRow(idx)

    def initializePage(self):
        if self.table.rowCount() == 0:
            for u in self.wiz.cfg.users:
                self._add(u.username, u.domain, u.role, u.email)

    def validatePage(self):
        out = []
        for r in range(self.table.rowCount()):
            username = self.table.item(r, 0).text().strip() if self.table.item(r, 0) else ""
            if not username:
                continue
            domain = self.table.item(r, 1).text().strip() if self.table.item(r, 1) else ""
            role = self.table.cellWidget(r, 2).currentText() if self.table.cellWidget(r, 2) else "user"
            email = self.table.item(r, 3).text().strip() if self.table.item(r, 3) else ""
            out.append(User(username=username, domain=domain, role=role, email=email))
        self.wiz.cfg.users = out
        return True


class HomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Home & encryption")
        lay = QtWidgets.QVBoxLayout(self)
        self.mode = QtWidgets.QComboBox()
        self.mode.addItems(["create", "adopt", "archive", "restore"])
        lay.addWidget(_row("Home mode", self.mode))
        self.device = QtWidgets.QLineEdit()
        self.device.setPlaceholderText("LABEL=… | UUID=… | /dev/… (adopt)")
        lay.addWidget(_row("Home device", self.device))
        self.backup = QtWidgets.QLineEdit()
        bbtn = _file_picker(self, self.backup, "Home backup", "Backup (*.tar* *.gpg *.enc)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.backup, 1); h.addWidget(bbtn)
        lay.addWidget(_row("Home backup (restore)", w))
        self.encrypted = QtWidgets.QCheckBox("Per-user eCryptfs home (on top of LUKS root)")
        lay.addWidget(self.encrypted)
        self.seed = QtWidgets.QComboBox()
        self.seed.addItems(["none", "repos", "stack", "mesh"])
        lay.addWidget(_row("Seed stack code", self.seed))
        # local login account (--local-user / --local-pass). The password is hashed by
        # the builder at build time and is NEVER written to a saved config.
        login = QtWidgets.QGroupBox("Local login")
        ll = QtWidgets.QVBoxLayout(login)
        self.local_user = QtWidgets.QLineEdit()
        ll.addWidget(_row("Local user", self.local_user))
        self.local_pass = QtWidgets.QLineEdit()
        self.local_pass.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.local_pass.setPlaceholderText("hashed at build time; NOT saved to configs")
        ll.addWidget(_row("Local password", self.local_pass))
        lay.addWidget(login)
        # root-disk encryption (installer LUKS2 FDE) + unlock factors
        enc = QtWidgets.QGroupBox("Root-disk encryption (LUKS2)")
        el = QtWidgets.QVBoxLayout(enc)
        self.encrypt_root = QtWidgets.QCheckBox(
            "Encrypt the target root (--encrypt-root; installer prompts for a passphrase)")
        el.addWidget(self.encrypt_root)
        self.luks_pass = QtWidgets.QLineEdit()
        self.luks_pass.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.luks_pass.setPlaceholderText("optional unattended passphrase; NOT saved to configs")
        el.addWidget(_row("LUKS passphrase", self.luks_pass))
        self.unlock_keyfile = QtWidgets.QComboBox()
        self.unlock_keyfile.addItems(["(off)", "boot", "login"])
        el.addWidget(_row("Keyfile unlock", self.unlock_keyfile))
        self.unlock_yubikey = QtWidgets.QComboBox()
        self.unlock_yubikey.addItems(["(off)", "boot", "login"])
        el.addWidget(_row("YubiKey unlock", self.unlock_yubikey))
        lay.addWidget(enc)
        lay.addStretch(1)

    def initializePage(self):
        c = self.wiz.cfg
        self.mode.setCurrentText(c.home_mode)
        self.device.setText(c.home_device)
        self.backup.setText(c.home_backup)
        self.encrypted.setChecked(c.home_encrypted)
        self.seed.setCurrentText(c.home_seed_code)
        self.local_user.setText(c.local_user)
        self.local_pass.setText(c.local_pass)
        self.encrypt_root.setChecked(c.encrypt_root)
        self.luks_pass.setText(c.luks_pass)
        self.unlock_keyfile.setCurrentText(c.unlock_keyfile or "(off)")
        self.unlock_yubikey.setCurrentText(c.unlock_yubikey or "(off)")

    def validatePage(self):
        c = self.wiz.cfg
        c.home_mode = self.mode.currentText()
        c.home_device = self.device.text().strip()
        c.home_backup = self.backup.text().strip()
        c.home_encrypted = self.encrypted.isChecked()
        c.home_seed_code = self.seed.currentText()
        c.local_user = self.local_user.text().strip() or c.local_user
        c.local_pass = self.local_pass.text()
        c.encrypt_root = self.encrypt_root.isChecked()
        c.luks_pass = self.luks_pass.text()
        kf = self.unlock_keyfile.currentText()
        c.unlock_keyfile = "" if kf == "(off)" else kf
        yk = self.unlock_yubikey.currentText()
        c.unlock_yubikey = "" if yk == "(off)" else yk
        return True


class _BuildWorker(QtCore.QThread):
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, cfg, backend):
        super().__init__()
        self.driver, self.cfg, self.backend = driver, cfg, backend

    def run(self):
        code = self.driver.run(self.cfg, self.backend, on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


class _BuilderImageWorker(QtCore.QThread):
    """Runs BuildDriver.build_builder_image() the same way _BuildWorker runs a build."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver):
        super().__init__()
        self.driver = driver

    def run(self):
        code = self.driver.build_builder_image(on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


class BuildPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Build")
        self.setSubTitle("Review the command, then build natively or via Docker.")
        lay = QtWidgets.QVBoxLayout(self)
        self.backend = QtWidgets.QComboBox()
        self.backend.addItems(["auto", "native", "docker"])
        lay.addWidget(_row("Backend", self.backend))
        # --env: which stack environment the image bakes (every builder parses it)
        self.env = QtWidgets.QComboBox()
        self.env.addItems(list(ENV_CHOICES))
        lay.addWidget(_row("Environment (--env)", self.env))
        self.outdir = QtWidgets.QLineEdit()
        obtn = _file_picker(self, self.outdir, "Output dir", directory=True)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.outdir, 1); h.addWidget(obtn)
        lay.addWidget(_row("Output dir", w))
        self.jobs = QtWidgets.QSpinBox(); self.jobs.setRange(1, 256); self.jobs.setValue(8)
        lay.addWidget(_row("Parallel jobs", self.jobs))
        self.installer_ui = QtWidgets.QComboBox()
        self.installer_ui.addItems(["all", "cli", "ncurses", "calamares"])
        lay.addWidget(_row("Installer UI", self.installer_ui))
        self.compress = QtWidgets.QCheckBox("Compress the finished image(s) (xz -9)")
        self.resume = QtWidgets.QCheckBox("Resume — reuse an existing sysroot")
        lay.addWidget(self.compress)
        lay.addWidget(self.resume)
        # escape hatch: EVERY builder CLI option stays expressible, fielded or not
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText('appended verbatim, shell-quoted (e.g. --grow none --seed-url "https://…")')
        lay.addWidget(_row("Extra builder flags", self.extra_flags))
        self.cmd = QtWidgets.QPlainTextEdit(); self.cmd.setReadOnly(True); self.cmd.setMaximumHeight(120)
        lay.addWidget(QtWidgets.QLabel("Command:")); lay.addWidget(self.cmd)
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.build_btn = QtWidgets.QPushButton("Build now")
        self.build_image_btn = QtWidgets.QPushButton("Build builder image now")
        self.build_image_btn.setVisible(False)
        self.preview_btn.clicked.connect(self._preview)
        self.build_btn.clicked.connect(self._build)
        self.build_image_btn.clicked.connect(self._build_builder_image)
        bl = QtWidgets.QHBoxLayout(); bl.addWidget(self.preview_btn); bl.addWidget(self.build_btn)
        bl.addWidget(self.build_image_btn); bl.addStretch(1)
        lay.addLayout(bl)
        self.log = QtWidgets.QPlainTextEdit(); self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)
        self.worker = None
        self.image_worker = None

    def initializePage(self):
        self.wiz.collect_all()
        c = self.wiz.cfg
        if not self.outdir.text():
            self.outdir.setText(c.output_dir or os.path.join(self.wiz.generator_dir, "out"))
        self.env.setCurrentText(c.env or "test")
        self.installer_ui.setCurrentText(c.installer_ui or "all")
        # the installer-UI choice is an x86 ISO knob; the arm builders have no flag
        self.installer_ui.setEnabled(c.platform in ("", "x86"))
        self.compress.setChecked(c.compress)
        self.resume.setChecked(c.resume)
        self.extra_flags.setText(c.extra_flags)
        self._preview()

    def _backend(self):
        b = self.backend.currentText()
        return None if b == "auto" else b

    def _preview(self):
        self.wiz.collect_all()
        c = self.wiz.cfg
        c.output_dir = self.outdir.text().strip()
        c.jobs = self.jobs.value()
        c.env = self.env.currentText()
        c.installer_ui = self.installer_ui.currentText()
        c.compress = self.compress.isChecked()
        c.resume = self.resume.isChecked()
        c.extra_flags = self.extra_flags.text().strip()
        try:
            cmdline = self.wiz.driver.command_string(c, self._backend())
        except ValueError as e:  # e.g. unbalanced quotes in the extra-flags escape hatch
            self.cmd.setPlainText("")
            self.log.setPlainText(f"Command error: {e}")
            return
        problems = self.wiz.driver.preflight(c, self._backend())
        self.cmd.setPlainText(cmdline)
        if problems:
            self.log.setPlainText("Preflight:\n  - " + "\n  - ".join(problems))
        else:
            self.log.setPlainText("Preflight OK.")
        self.build_image_btn.setVisible(self.wiz.driver.builder_image_missing(self._backend()))

    def _build_builder_image(self):
        if self.image_worker and self.image_worker.isRunning():
            return
        self.build_image_btn.setEnabled(False)
        self.build_btn.setEnabled(False)
        self.log.appendPlainText("\n=== building the docker builder image ===")
        self.image_worker = _BuilderImageWorker(self.wiz.driver)
        self.image_worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.image_worker.done.connect(self._builder_image_finished)
        self.image_worker.start()

    def _builder_image_finished(self, code):
        self.log.appendPlainText(f"=== builder image build exited {code} ===")
        self.build_image_btn.setEnabled(True)
        self.build_btn.setEnabled(True)
        self._preview()

    def _build(self):
        self._preview()
        if self.worker and self.worker.isRunning():
            return
        # superadmin mesh: emit the domains+users manifest as a build artifact
        if self.wiz.cfg.mode == "mesh" and (self.wiz.cfg.domains or self.wiz.cfg.users):
            try:
                mpath = self.wiz.cfg.write_mesh_manifest(self.wiz.cfg.output_dir or
                                                         os.path.join(self.wiz.generator_dir, "out"))
                self.log.appendPlainText(f"wrote mesh manifest: {mpath}")
            except OSError as e:
                self.log.appendPlainText(f"mesh manifest write failed: {e}")
        self.build_btn.setEnabled(False)
        self.log.appendPlainText("\n=== starting build ===")
        self.worker = _BuildWorker(self.wiz.driver, self.wiz.cfg, self._backend())
        self.worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.worker.done.connect(self._finished)
        self.worker.start()

    def _finished(self, code):
        self.log.appendPlainText(f"=== build exited {code} ===")
        self.build_btn.setEnabled(True)


class StudioWizard(QtWidgets.QWizard):
    def __init__(self, generator_dir, parent=None):
        super().__init__(parent)
        self.generator_dir = os.path.abspath(generator_dir)
        self.host = detect()
        self.cfg = ImageConfig()
        self.driver = BuildDriver(self.generator_dir, self.host)
        self.setWindowTitle("Snapdragon Image Studio")
        self.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
        self.resize(820, 640)
        self._pages = [
            WelcomePage(self), ModePage(self), RolePage(self), HardwarePage(self),
            BrandingPage(self), NetworkPage(self), KeyZipPage(self), DomainsPage(self),
            UsersPage(self), HomePage(self), BuildPage(self),
        ]
        for p in self._pages:
            self.addPage(p)

    def collect_all(self):
        """Pull values out of every VISITED page into self.cfg. Only visited pages are
        collected — an unvisited page's widgets hold construction defaults, so collecting
        them would wipe loaded/earlier values (this also lets Domains/Users be collected,
        which the old blanket exclusion silently dropped on save + the mesh build path)."""
        for pid in self.pageIds():
            if not self.hasVisitedPage(pid):
                continue
            p = self.page(pid)
            if hasattr(p, "validatePage"):
                try:
                    p.validatePage()
                except Exception:
                    pass
