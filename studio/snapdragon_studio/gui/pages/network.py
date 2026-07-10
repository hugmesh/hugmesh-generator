"""NetworkPage — tailnet/SSO (incl. the headscale URL/version knobs), brand identity
(profile/org/domains/release state), egress VPN, security stack, edge-AI, Tor,
Character Studio and the optional cluster services checklist (with the explicit-none /
all-services sentinels and the subtractive exclude list)."""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.config import (
    OPTIONAL_SERVICES_BY_PLATFORM,
    OPTIONAL_SERVICES_CHOICES,
    RELEASE_STATE_CHOICES,
    SERVICES_ALL,
    SERVICES_NONE,
)
from ._gating import clear_unsupported, gate_widgets, platform_supports
from ._widgets import _file_picker, _row

# The three-state checkboxes (G34): a plain checkbox could only ever emit the
# positive flag, so a brand-profile (-C) default could never be forced OFF from
# the GUI. State map — Checked = --with-* / Unchecked = --no-* / PartiallyChecked
# (the square) = emit neither and leave the brand.conf/builder default.
_TRI_TIP = ("3-state: checked = force ON (--with-…), unchecked = force OFF (--no-…), "
            "part-checked square = leave the brand-profile/builder default.")


def _tri_state(value):
    """config tri-state value ('', 'on', 'off', or a back-compat bool) -> CheckState."""
    if value is True or value == "on":
        return Qt.CheckState.Checked
    if value == "off":
        return Qt.CheckState.Unchecked
    return Qt.CheckState.PartiallyChecked


def _tri_value(box):
    """CheckState -> config tri-state value (True / 'off' / False-as-default)."""
    s = box.checkState()
    if s == Qt.CheckState.Checked:
        return True
    if s == Qt.CheckState.Unchecked:
        return "off"
    return False


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
        # Headscale URL (G2) — the brand mesh control-server URL baked to
        # /etc/snapdragon/headscale-url. NOT a builder flag on any platform
        # (NON_ARGV_FIELDS): build_driver delivers it as the HEADSCALE_URL env var
        # (docker -e / native env), so it is never greyed per platform.
        self.headscale_url = QtWidgets.QLineEdit()
        self.headscale_url.setPlaceholderText(
            "https://headscale.example.org  (empty = local-first: control node uses its LAN IP)")
        self.headscale_url.setToolTip(
            "Baked to /etc/snapdragon/headscale-url. Delivered to the builder as the "
            "HEADSCALE_URL environment variable — not a CLI flag.")
        lay.addWidget(_row("Headscale URL", self.headscale_url))
        # mesh agent version pins + the headscale-only posture (G29; all builders)
        self.headscale_version = QtWidgets.QLineEdit()
        self.headscale_version.setPlaceholderText("--headscale-version pin  (empty = builder default)")
        self.tailscale_version = QtWidgets.QLineEdit()
        self.tailscale_version.setPlaceholderText("--tailscale-version pin  (empty = builder default)")
        lay.addWidget(_row("Headscale version", self.headscale_version))
        lay.addWidget(_row("Tailscale version", self.tailscale_version))
        self.skip_tailscale = QtWidgets.QCheckBox(
            "Skip the tailscale agent (--skip-tailscale: headscale-only posture — "
            "distinct from not joining the mesh)")
        lay.addWidget(self.skip_tailscale)
        # brand profile (G3): -C/--config brands/*.conf — the sole carrier of the
        # HEADSCALE_URL / RELEASE_STATE / ADMIN_EMAILS / MAIL_* / EXCLUDE_SERVICES
        # presets; sourced by every builder before its CLI flags (CLI wins).
        self.brand_profile = QtWidgets.QLineEdit()
        self.brand_profile.setPlaceholderText("brands/<brand>.conf  (empty = no preset profile)")
        bbtn = _file_picker(self, self.brand_profile, "Brand profile", "Brand profile (*.conf)")
        bw = QtWidgets.QWidget(); bh = QtWidgets.QHBoxLayout(bw); bh.setContentsMargins(0, 0, 0, 0)
        bh.addWidget(self.brand_profile, 1); bh.addWidget(bbtn)
        lay.addWidget(_row("Brand profile (-C)", bw))
        self.brand = QtWidgets.QLineEdit()
        self.brand_title = QtWidgets.QLineEdit()
        self.org = QtWidgets.QLineEdit()          # --org (G7): emitted on every platform
        self.domain = QtWidgets.QLineEdit()
        lay.addWidget(_row("Brand id", self.brand))
        lay.addWidget(_row("Brand title", self.brand_title))
        lay.addWidget(_row("Org", self.org))
        lay.addWidget(_row("Cluster domain", self.domain))
        # games domain (G6, x86+rpi5): the games.<domain> host + games OIDC issuer.
        self.games_domain = QtWidgets.QLineEdit()
        self.games_domain.setPlaceholderText("games.<cluster domain>  (empty = builder default)")
        lay.addWidget(_row("Games domain", self.games_domain))
        # release state (G4, x86+rpi5): the baked Layer-3 nftables / go-live posture.
        self.release_state = QtWidgets.QComboBox()
        self.release_state.addItems(("default", *RELEASE_STATE_CHOICES))
        lay.addWidget(_row("Release state (--release-state)", self.release_state))
        # egress VPN
        self.egress = QtWidgets.QLineEdit()
        ebtn = _file_picker(self, self.egress, "Egress VPN conf", "VPN (*.conf *.ovpn *.nmconnection)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.egress, 1); h.addWidget(ebtn)
        self.egress_row = w   # greyed as one unit (line edit + Browse…) per platform
        lay.addWidget(_row("Egress VPN", w))
        self.egress_locked = QtWidgets.QCheckBox("Lock egress VPN (managed node — user cannot remove)")
        lay.addWidget(self.egress_locked)
        # network/host security stack
        sec = QtWidgets.QGroupBox("Security stack")
        sl = QtWidgets.QVBoxLayout(sec)
        # Proxy stack is TRI-STATE like the builder's flag pair: auto (emit nothing —
        # the builder enables it on client desktops itself) | on | off. A checkbox
        # would collapse "auto" to an explicit on/off the first time the page is
        # visited, so the builder's per-role default could never round-trip.
        self.proxy_stack = QtWidgets.QComboBox()
        self.proxy_stack.addItems(["auto", "on", "off"])
        sl.addWidget(_row("Proxy stack — Squid (cache) + Privoxy (filter), "
                          "wired into Firefox (desktops)", self.proxy_stack))
        self.snort = QtWidgets.QCheckBox("Snort IDS (network intrusion detection)")
        # AIDE is TRI-STATE (G34): a brand profile (-C) may default it ON, and the old
        # two-state box could never force it back OFF (--no-aide).
        self.aide = QtWidgets.QCheckBox("AIDE file-integrity IDS (DB baselined at first boot)")
        self.aide.setTristate(True)
        sl.addWidget(self.snort); sl.addWidget(self.aide)
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
        self.edge_ai.setTristate(True)   # G34: --with-edge-ai / --no-edge-ai / leave default
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
        self.tor_onion.setTristate(True)   # G34: --with-tor / --no-tor / leave default
        lay.addWidget(self.tor_onion)
        # Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate).
        # Cloud/mesh cluster builds only (it is a frontend cluster service).
        self.character_studio = QtWidgets.QCheckBox(
            "Character Studio (VN) — character creator + chat remote at /character-studio (default off)")
        self.character_studio.setTristate(True)   # G34: --with-/--no-character-studio / default
        lay.addWidget(self.character_studio)
        # cluster optional services (--optional-services multi-select) + the games stack.
        # An empty checklist emits NOTHING (the builder default akkoma tuwunel phpbb
        # applies), so the two sentinels get their own mutually-exclusive checkboxes:
        # explicit none (G13) and the full user-level set (G14).
        self.services_box = QtWidgets.QGroupBox("Optional cluster services (--optional-services)")
        svl = QtWidgets.QVBoxLayout(self.services_box)
        self.services_none = QtWidgets.QCheckBox(
            'NO optional services — emits --optional-services "" (suppresses the '
            "builder's akkoma tuwunel phpbb default)")
        self.services_all = QtWidgets.QCheckBox(
            "ALL user-level services (--all-services; infra slugs stay opt-in below)")
        self.services_none.toggled.connect(lambda on: self._sentinel_toggled(self.services_none, on))
        self.services_all.toggled.connect(lambda on: self._sentinel_toggled(self.services_all, on))
        svl.addWidget(self.services_none)
        svl.addWidget(self.services_all)
        self.services = QtWidgets.QListWidget()
        self.services.setMaximumHeight(140)
        for slug in OPTIONAL_SERVICES_CHOICES:
            it = QtWidgets.QListWidgetItem(slug)
            it.setFlags(it.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            it.setCheckState(Qt.CheckState.Unchecked)
            self.services.addItem(it)
        svl.addWidget(self.services)
        # subtractive --exclude-services list, applied LAST — the only way to subtract
        # slugs a brand profile (-C) injected (G14).
        self.exclude = QtWidgets.QLineEdit()
        self.exclude.setPlaceholderText(
            "slugs to subtract, applied last — e.g. akkoma phpbb  (empty = none)")
        svl.addWidget(_row("Exclude services", self.exclude))
        self.games = QtWidgets.QCheckBox(
            "Enable games — bake the Snapdragon Game Studio + the games.<domain> service")
        svl.addWidget(self.games)
        lay.addWidget(self.services_box)
        lay.addStretch(1)

    def _sentinel_toggled(self, box, on):
        """Keep the explicit-none / all-services sentinels mutually exclusive and grey
        the slug checklist while either is active (the sentinel replaces the list)."""
        if on:
            other = self.services_all if box is self.services_none else self.services_none
            other.setChecked(False)
        self.services.setEnabled(
            not (self.services_none.isChecked() or self.services_all.isChecked()))

    def initializePage(self):
        c = self.wiz.cfg
        self.proxy_stack.setCurrentText(c.proxy_stack if c.proxy_stack in ("auto", "on", "off")
                                        else "auto")
        self.snort.setChecked(c.snort)
        # tri-states (G34): part-checked = leave the brand.conf/builder default; on an
        # unsupported platform show fully-unchecked (never a misleading auto-check) —
        # gate_widgets below greys them and validatePage clears the field anyway.
        self.aide.setCheckState(_tri_state(c.aide)
                                if platform_supports("aide", c.platform)
                                else Qt.CheckState.Unchecked)
        self.root_login.setCurrentText(c.root_login or "no")
        self.tailscale.setChecked(c.tailscale or c.mode in ("cloud", "mesh"))
        # only force-check SSO where the platform's builder actually takes the flag —
        # an ARM cloud/mesh build used to show it force-checked, then silently drop it
        self.sso.setChecked((c.sso or c.mode in ("cloud", "mesh"))
                            and platform_supports("sso", c.platform))
        self.headscale_url.setText(c.headscale_url)
        self.headscale_version.setText(c.headscale_version)
        self.tailscale_version.setText(c.tailscale_version)
        self.skip_tailscale.setChecked(c.skip_tailscale)
        self.brand_profile.setText(c.brand_profile)
        self.brand.setText(c.brand)
        self.brand_title.setText(c.brand_title)
        self.org.setText(c.org)
        self.domain.setText(c.cluster_domain)
        self.games_domain.setText(c.games_domain)
        self.release_state.setCurrentText(c.release_state or "default")
        self.egress.setText(c.egress_vpn)
        self.egress_locked.setChecked(c.egress_vpn_locked)
        # same rule for the edge_ai role's auto-check (G11: jetson greys out too)
        edge_state = _tri_state(c.edge_ai_service)
        if c.role == "edge_ai":
            edge_state = Qt.CheckState.Checked      # the role auto-selects the service
        if not platform_supports("edge_ai_service", c.platform):
            edge_state = Qt.CheckState.Unchecked
        self.edge_ai.setCheckState(edge_state)
        self.edge_ai_runtime.setCurrentText(c.edge_ai_runtime or "ollama")
        self.edge_ai_models.setText(c.edge_ai_models)
        self.edge_ai_default.setText(c.edge_ai_model_default)
        self.edge_ai_analysis.setChecked(c.edge_ai_analysis)
        # edge-AI is a GPU CLUSTER service — only meaningful for cloud/mesh node builds.
        self.edge_ai_box.setVisible(c.mode in ("cloud", "mesh"))
        self.tor_onion.setCheckState(_tri_state(c.tor_onion_service)
                                     if platform_supports("tor_onion_service", c.platform)
                                     else Qt.CheckState.Unchecked)
        # Tor is a k8s-NODE service — only meaningful for cloud/mesh cluster builds.
        self.tor_onion.setVisible(c.mode in ("cloud", "mesh"))
        self.character_studio.setCheckState(_tri_state(c.character_studio)
                                            if platform_supports("character_studio", c.platform)
                                            else Qt.CheckState.Unchecked)
        # rebuild the slug checklist for THIS platform's catalog (G15: rpi5 adds the
        # infra slugs tor/egress-vpn/workloadConsole/anubis, which --all-services does
        # NOT include and x86 covers via dedicated flags instead)
        choices = tuple(OPTIONAL_SERVICES_BY_PLATFORM.get(c.platform or "x86",
                                                          OPTIONAL_SERVICES_CHOICES))
        if tuple(self.services.item(i).text() for i in range(self.services.count())) != choices:
            self.services.clear()
            for slug in choices:
                it = QtWidgets.QListWidgetItem(slug)
                it.setFlags(it.flags() | Qt.ItemFlag.ItemIsUserCheckable)
                it.setCheckState(Qt.CheckState.Unchecked)
                self.services.addItem(it)
        picked = [s for s in c.optional_services if s not in (SERVICES_NONE, SERVICES_ALL)]
        for i in range(self.services.count()):
            it = self.services.item(i)
            it.setCheckState(Qt.CheckState.Checked if it.text() in picked
                             else Qt.CheckState.Unchecked)
        self.services_none.setChecked(c.optional_services == [SERVICES_NONE])
        self.services_all.setChecked(SERVICES_ALL in c.optional_services)
        self._sentinel_toggled(self.services_none, self.services_none.isChecked())
        self.exclude.setText(" ".join(c.exclude_services))
        self.games.setChecked(c.enable_games)
        # optional services / games / Character Studio gate on PLATFORM capability,
        # not mode (G16): x86 AND rpi5 parse them on every role — notably standalone
        # rpi5 'generic', the one standalone role that could never reach them while
        # these boxes were mode-gated. gate_widgets() below greys them wherever the
        # builder has no flag (G12: frite/orangepi5/orangepizero2/jetson).
        self.character_studio.setVisible(True)
        self.services_box.setVisible(True)
        # per-platform capability greying (G10/G11/G12): x86-only emission fields
        # used to sit un-greyed on ARM and silently drop their values from the argv.
        # validatePage() clears whatever is greyed here (clear_unsupported).
        gate_widgets(c.platform, {
            "sso": self.sso,
            "games_domain": self.games_domain,
            "release_state": self.release_state,
            "egress_vpn": self.egress_row,
            "egress_vpn_locked": self.egress_locked,
            "proxy_stack": self.proxy_stack,
            "snort": self.snort,
            "aide": self.aide,
            "edge_ai_service": self.edge_ai_box,
            "tor_onion_service": self.tor_onion,
            "character_studio": self.character_studio,
            "optional_services": self.services_box,
            "enable_games": self.games,
        })
        # gate_widgets blanks the tooltip on every ENABLED widget — restore the
        # 3-state legend on the live tri-state boxes (disabled ones keep the
        # unsupported-platform note it set).
        for w in (self.aide, self.edge_ai, self.tor_onion, self.character_studio):
            if w.isEnabled():
                w.setToolTip(_TRI_TIP)

    def validatePage(self):
        c = self.wiz.cfg
        c.tailscale = self.tailscale.isChecked()
        c.sso = self.sso.isChecked()
        c.headscale_url = self.headscale_url.text().strip()
        c.headscale_version = self.headscale_version.text().strip()
        c.tailscale_version = self.tailscale_version.text().strip()
        c.skip_tailscale = self.skip_tailscale.isChecked()
        c.brand_profile = self.brand_profile.text().strip()
        c.brand = self.brand.text().strip() or "snapdragon"
        c.brand_title = self.brand_title.text().strip() or "Snapdragon Systems"
        c.org = self.org.text().strip() or "Snapdragon-Systems"
        c.cluster_domain = self.domain.text().strip() or "snapdragon.systems"
        c.games_domain = self.games_domain.text().strip()
        rs = self.release_state.currentText()
        c.release_state = "" if rs == "default" else rs
        c.egress_vpn = self.egress.text().strip()
        c.egress_vpn_locked = self.egress_locked.isChecked()
        c.proxy_stack = self.proxy_stack.currentText()
        c.snort = self.snort.isChecked()
        c.aide = _tri_value(self.aide)
        c.root_login = self.root_login.currentText()
        c.edge_ai_service = _tri_value(self.edge_ai)
        c.edge_ai_runtime = self.edge_ai_runtime.currentText()
        c.edge_ai_models = self.edge_ai_models.text().strip()
        c.edge_ai_model_default = self.edge_ai_default.text().strip()
        c.edge_ai_analysis = self.edge_ai_analysis.isChecked()
        c.tor_onion_service = _tri_value(self.tor_onion)
        c.character_studio = _tri_value(self.character_studio)
        # the sentinels replace the checklist (see _services_args: [none] emits
        # --optional-services "" and [all] emits --all-services); an empty custom
        # list emits nothing, leaving the builder default (G13/G14)
        if self.services_none.isChecked():
            c.optional_services = [SERVICES_NONE]
        elif self.services_all.isChecked():
            c.optional_services = [SERVICES_ALL]
        else:
            c.optional_services = [self.services.item(i).text()
                                   for i in range(self.services.count())
                                   if self.services.item(i).checkState() == Qt.CheckState.Checked]
        c.exclude_services = self.exclude.text().replace(",", " ").split()
        c.enable_games = self.games.isChecked()
        # the greyed (platform-unsupported) widgets were still collected above —
        # reset those fields to their defaults so a value picked while another
        # platform was selected can't linger into save() or the emitted argv.
        clear_unsupported(c, (
            "sso", "games_domain", "release_state", "egress_vpn", "egress_vpn_locked",
            "proxy_stack", "snort", "aide",
            "edge_ai_service", "edge_ai_runtime", "edge_ai_models",
            "edge_ai_model_default", "edge_ai_analysis", "tor_onion_service",
            "character_studio", "optional_services", "exclude_services", "enable_games",
        ))
        return True
