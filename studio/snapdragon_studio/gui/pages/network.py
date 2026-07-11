"""NetworkPage — three role-class groupboxes up top (brand identity & domain, the
tailnet/SSO toggles, the mesh control plane incl. the orchestration superdomain),
then egress VPN, the security stack, edge-AI, Tor, Character Studio and the optional
cluster-services checklist (with the explicit-none / all-services sentinels and the
subtractive exclude list).

The tailnet/SSO group is user-editable ONLY for cloud branded desktops
(``tailnet_sso_visible``, spec 3): standalone and mesh hide it (mesh forces
tailscale=sso on off-UI in enter_mesh_defaults/materialize — never here). The mesh
control plane (incl. the superdomain, spec 5) shows for cloud AND mesh."""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core.config import (
    OPTIONAL_SERVICES_BY_PLATFORM,
    OPTIONAL_SERVICES_CHOICES,
    RELEASE_STATE_CHOICES,
    RPI5_ROLE_MAP,
    SERVICES_ALL,
    SERVICES_NONE,
    X86_NODE_ROLES,
    tailnet_sso_visible,
)
from ._gating import clear_unsupported, gate_widgets, platform_supports
from ._widgets import _file_picker, _row

# The three-state checkboxes (G34): a plain checkbox could only ever emit the
# positive flag, so a brand-profile (-C) default could never be forced OFF from
# the GUI. State map — Checked = --with-* / Unchecked = --no-* / PartiallyChecked
# (the square) = emit neither and leave the brand.conf/builder default.
_TRI_TIP = ("3-state: checked = force ON (--with-…), unchecked = force OFF (--no-…), "
            "part-checked square = leave the brand-profile/builder default.")


def _client_class_role(role: str, platform: str) -> bool:
    """True when the selected role builds a CLIENT-class (desktop) image — the
    class for which the builders accept --optional-services but never bake it
    (no cluster GitOps tree on a desktop: build-x86 skips the specs/cluster copy
    for ROLE_CLIENT and its plan echoes OPTIONAL_SERVICES 'none'; build-rpi5's
    plan echoes 'n/a (role=desktop; no cluster GitOps tree baked)').

    Mirrors the builders' own ROLE_CLIENT derivation, the same way config.py
    gates --person-role/--domains on the role class (G18 / X86_NODE_ROLES):

    * x86 — ROLE_CLIENT is every role NOT in X86_NODE_ROLES (build-x86's role
      switch sets ROLE_CLIENT=true for laptop/chromebook/desktop AND all the
      standalone-* desktops);
    * rpi5 — ONLY builder --role desktop (Studio id rpi5-desktop, RPI5_ROLE_MAP)
      is ROLE_CLIENT; generic/pki/backend/frontend are cluster-node class —
      notably standalone 'generic' DOES bake the tree (G16), so it must NOT
      count as client here.

    Only x86 + rpi5 parse --optional-services at all (PLATFORM_FIELD_SUPPORT);
    on every other platform the services box is greyed by gate_widgets with its
    own explanation, so this note never applies there.
    """
    p = platform or "x86"
    if p == "rpi5":
        return RPI5_ROLE_MAP.get(role, role) == "desktop"
    if p == "x86":
        return role not in X86_NODE_ROLES
    return False


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

        # ---- Group 1: brand identity & domain (visited in ALL modes) -------------
        self.identity_box = QtWidgets.QGroupBox("Identity & domain")
        il = QtWidgets.QVBoxLayout(self.identity_box)
        # brand profile (G3): -C/--config brands/*.conf — the sole carrier of the
        # HEADSCALE_URL / RELEASE_STATE / ADMIN_EMAILS / MAIL_* / EXCLUDE_SERVICES
        # presets; sourced by every builder before its CLI flags (CLI wins).
        self.brand_profile = QtWidgets.QLineEdit()
        self.brand_profile.setPlaceholderText("brands/<brand>.conf  (empty = no preset profile)")
        bbtn = _file_picker(self, self.brand_profile, "Brand profile", "Brand profile (*.conf)")
        bw = QtWidgets.QWidget(); bh = QtWidgets.QHBoxLayout(bw); bh.setContentsMargins(0, 0, 0, 0)
        bh.addWidget(self.brand_profile, 1); bh.addWidget(bbtn)
        il.addWidget(_row("Brand profile (-C)", bw))
        self.brand = QtWidgets.QLineEdit()
        self.brand_title = QtWidgets.QLineEdit()
        self.org = QtWidgets.QLineEdit()          # --org (G7): emitted on every platform
        self.domain = QtWidgets.QLineEdit()
        il.addWidget(_row("Brand id", self.brand))
        il.addWidget(_row("Brand title", self.brand_title))
        il.addWidget(_row("Org", self.org))
        # --cluster-domain is the PUBLIC apex (the go-live target), distinct from the
        # permanently-internal orchestration superdomain in the mesh control plane below.
        il.addWidget(_row("Public apex domain", self.domain))
        # games domain (G6, x86+rpi5): the games.<domain> host + games OIDC issuer.
        self.games_domain = QtWidgets.QLineEdit()
        self.games_domain.setPlaceholderText("games.<cluster domain>  (empty = builder default)")
        il.addWidget(_row("Games domain", self.games_domain))
        # release state (G4, x86+rpi5): the baked Layer-3 nftables / go-live posture.
        self.release_state = QtWidgets.QComboBox()
        self.release_state.addItems(("default", *RELEASE_STATE_CHOICES))
        il.addWidget(_row("Release state (--release-state)", self.release_state))
        lay.addWidget(self.identity_box)

        # ---- Group 2: tailnet + SSO (cloud branded desktops only, spec 3) --------
        self.tailnet_box = QtWidgets.QGroupBox("Tailnet + SSO")
        tl = QtWidgets.QVBoxLayout(self.tailnet_box)
        self.tailscale = QtWidgets.QCheckBox("Join the tailnet (tailscale/headscale)")
        self.sso = QtWidgets.QCheckBox("Enable SSO login (Casdoor)")
        tl.addWidget(self.tailscale)
        tl.addWidget(self.sso)
        lay.addWidget(self.tailnet_box)
        # shown INSTEAD of the group when it is hidden (standalone/mesh), explaining why.
        self.tailnet_reason = QtWidgets.QLabel()
        self.tailnet_reason.setWordWrap(True)
        self.tailnet_reason.setStyleSheet("color: gray;")
        self.tailnet_reason.setVisible(False)
        lay.addWidget(self.tailnet_reason)

        # ---- Group 3: mesh control plane (cloud AND mesh) ------------------------
        self.mesh_box = QtWidgets.QGroupBox("Mesh control plane")
        cp = QtWidgets.QVBoxLayout(self.mesh_box)
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
        cp.addWidget(_row("Headscale URL", self.headscale_url))
        # mesh agent version pins + the headscale-only posture (G29; all builders)
        self.headscale_version = QtWidgets.QLineEdit()
        self.headscale_version.setPlaceholderText("--headscale-version pin  (empty = builder default)")
        self.tailscale_version = QtWidgets.QLineEdit()
        self.tailscale_version.setPlaceholderText("--tailscale-version pin  (empty = builder default)")
        cp.addWidget(_row("Headscale version", self.headscale_version))
        cp.addWidget(_row("Tailscale version", self.tailscale_version))
        self.skip_tailscale = QtWidgets.QCheckBox(
            "Skip the tailscale agent (--skip-tailscale: headscale-only posture — "
            "distinct from not joining the mesh)")
        cp.addWidget(self.skip_tailscale)
        # orchestration superdomain (spec 5): the permanently-internal <brand>.internal
        # every mesh node joins (NON_ARGV: manifest + KEYS channel, never a builder
        # flag; distinct from the public apex above, I7). Editable in mesh; a read-only
        # derived display in cloud (so the Users-page superadmin lock is explicable).
        self.superdomain = QtWidgets.QLineEdit()
        self.superdomain.setToolTip(
            "The internal orchestration domain all mesh nodes join (empty = derived "
            "<brand>.internal). Delivered via the mesh manifest + the KEYS channel — "
            "never a builder flag, never the go-live apex.")
        self.superdomain_row = _row("Orchestration superdomain", self.superdomain)
        cp.addWidget(self.superdomain_row)
        lay.addWidget(self.mesh_box)

        # ---- egress VPN ----------------------------------------------------------
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
        # UX-honesty note (PR #304 verify pass): on a CLIENT-class role the builders
        # ACCEPT these selections but never bake them — a desktop image carries no
        # cluster GitOps tree, so the build plan echoes OPTIONAL_SERVICES as
        # none / "n/a (role=desktop; no cluster GitOps tree baked)". Same styled-
        # QLabel pattern as BrandingPage.unaffiliated_note / BuildPage.bundle_note.
        # Deliberately a HINT, not a gate: nothing greys, nothing clears, and the
        # emission is untouched (the builders take the flags fine on any role).
        self.services_role_note = QtWidgets.QLabel("")
        self.services_role_note.setWordWrap(True)
        self.services_role_note.setStyleSheet("color: #a65d00;")
        self.services_role_note.setVisible(False)
        svl.addWidget(self.services_role_note)
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
        # Tailnet + SSO is a cloud-branded-DESKTOP surface (spec 3). The group is shown
        # + user-editable only there; standalone/mesh HIDE it (mesh forces tailscale=sso
        # on off-UI in enter_mesh_defaults/materialize — this page never force-checks).
        # When shown, default the toggles CHECKED (a fresh cloud client joins the mesh);
        # sso keeps its x86-only platform gate below.
        ss_visible = tailnet_sso_visible(c)
        self.tailnet_box.setVisible(ss_visible)
        self.tailnet_reason.setVisible(not ss_visible)
        if not ss_visible:
            self.tailnet_reason.setText(
                "Standalone images have no tailnet — no mesh, no SSO."
                if c.mode == "standalone" else
                "Mesh nodes join the superdomain tailnet implicitly (tailscale + SSO on)."
                if c.mode == "mesh" else
                "This image class has no user-facing tailnet / SSO toggle.")
        self.tailscale.setChecked(c.tailscale or ss_visible)
        self.sso.setChecked((c.sso or ss_visible) and platform_supports("sso", c.platform))
        # mesh control plane (incl. the superdomain) — cloud AND mesh, hidden standalone.
        show_cp = c.mode in ("cloud", "mesh")
        self.mesh_box.setVisible(show_cp)
        self.headscale_url.setText(c.headscale_url)
        self.headscale_version.setText(c.headscale_version)
        self.tailscale_version.setText(c.tailscale_version)
        self.skip_tailscale.setChecked(c.skip_tailscale)
        # superdomain: editable in mesh (explicit text, empty = derived); a read-only
        # derived display in cloud (never write the derived value back to the config).
        mesh = c.mode == "mesh"
        self.superdomain.setReadOnly(not mesh)
        if mesh:
            self.superdomain.setText(c.superdomain)
            self.superdomain.setPlaceholderText(
                f"{c.brand or 'snapdragon'}.internal  (empty = derived)")
        else:
            self.superdomain.setText(c.effective_superdomain())
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
        # CLIENT-class role (builder ROLE_CLIENT — see _client_class_role): the
        # services are accepted but IGNORED (no cluster GitOps tree in a desktop
        # image; the plan echoes OPTIONAL_SERVICES as n/a). Show the honesty note;
        # keep everything enabled and the emission unchanged. Hidden wherever the
        # platform has no --optional-services flag at all — there gate_widgets'
        # greyed-box tooltip is the (different) explanation.
        client = (platform_supports("optional_services", c.platform)
                  and _client_class_role(c.role, c.platform))
        if client:
            self.services_role_note.setText(
                f"Heads-up: role '{c.role}' builds a client/desktop image — no "
                "cluster GitOps tree is baked, so services picked here are accepted "
                "but IGNORED by the builder (the build plan shows OPTIONAL_SERVICES "
                "as n/a). They only take effect on cluster NODE roles.")
        self.services_role_note.setVisible(client)
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
        # superdomain is user-set ONLY in mesh (editable); in cloud the field shows the
        # DERIVED value read-only — never write it back (would pin the derived string).
        if c.mode == "mesh":
            c.superdomain = self.superdomain.text().strip()
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
