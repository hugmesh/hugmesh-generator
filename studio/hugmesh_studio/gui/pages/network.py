"""NetworkPage — the domain/mesh/services step, as COLLAPSIBLE sections (identity &
domain, tailnet/SSO, the mesh control plane incl. the orchestration superdomain,
egress VPN, the security stack, edge-AI, and the optional cluster services — Tor,
Character Studio, edge-ai-tts and the slug checklist with its explicit-none /
all-services sentinels and subtractive exclude list).

The tailnet/SSO group is user-editable ONLY for cloud branded desktops
(``tailnet_sso_visible``, spec 3): standalone and mesh hide it (mesh forces
tailscale=sso on off-UI in enter_mesh_defaults/materialize — never here). The mesh
control plane (incl. the superdomain, spec 5) shows for cloud AND mesh.

Two things a reader must not conflate, because they look alike and are not:

* COLLAPSING (``_widgets.Collapsible``) is presentation only. It never touches
  enabled-ness, and it cannot change what the page collects or emits: validatePage()
  reads widget VALUES, which a hidden widget keeps.
* PLATFORM/ROLE GATING (``_gating``) greys or hides a surface the builder has no flag
  for, and ``clear_unsupported`` RESETS those fields in validatePage. It keys on
  ``platform_supports(field, platform)`` — the capability table — never on widget
  visibility, so a folded section is never mistaken for an unsupported one.

Services are MESH-WIDE (see _SERVICES_SCOPE_NOTE): they are baked into the cluster
GitOps tree every node shares, so there is deliberately no per-node service table."""
from __future__ import annotations

from dataclasses import MISSING

from ..qt import Qt, QtWidgets
from ._scroll import scrollable
from ...core.config import (
    ImageConfig,
    MANAGED_SERVICE_TIER3_BLOCKER,
    MANAGED_SERVICE_TIER3_IDS,
    MANAGED_SERVICE_TIER12_IDS,
    OPTIONAL_SERVICES_BY_PLATFORM,
    OPTIONAL_SERVICES_CHOICES,
    RELEASE_STATE_CHOICES,
    RPI5_ROLE_MAP,
    SERVICES_ALL,
    SERVICES_NONE,
    UNAFFILIATED_ROLE,
    X86_NODE_ROLES,
    tailnet_sso_visible,
)
from ._gating import (
    clear_unsupported,
    gate_widgets,
    gate_widgets_role_class,
    out_of_scope_note,
    platform_supports,
    scope_allows,
)
from ._widgets import _file_picker, _row, collapsible

# The three-state checkboxes (G34): a plain checkbox could only ever emit the
# positive flag, so a brand-profile (-C) default could never be forced OFF from
# the GUI. State map — Checked = --with-* / Unchecked = --no-* / PartiallyChecked
# (the square) = emit neither and leave the brand.conf/builder default.
_TRI_TIP = ("3-state: checked = force ON (--with-…), unchecked = force OFF (--no-…), "
            "part-checked square = leave the brand-profile/builder default.")

# The same explanation as _TRI_TIP, but VISIBLE. The tri-state was reported as
# "options like tor, character studio and edge ai are partially selected but it's not
# clear why" — the meaning existed only as a hover tooltip, which nobody hovers when
# they do not already know there is something to learn. The square is the DEFAULT
# state for these boxes, so the first thing the operator sees needs to explain itself
# on the page. Same styled-QLabel idiom as services_role_note / _hint().
_TRI_LEGEND = (
    "These are 3-state boxes: ■ part-checked (the default) leaves the brand "
    "profile's / builder's own choice alone · ☑ checked forces the service ON · "
    "☐ unchecked forces it OFF. The square is why some boxes start part-selected — "
    "it means \"don't override\", not \"partly enabled\"."
)

# Services are MESH-WIDE, not per-node — stated on the page because the operator
# reasonably asked whether they were selectable per node (as the worklist's per-node
# columns are). Grounded in the builders, not in UI convenience:
#   * build-rpi5-stage4.sh:1376 gate_optional_services() prunes each unselected slug's
#     Argo apps/*.yaml + manifests/ + gateway routes out of the baked CLUSTER GitOps
#     tree at ${SYSROOT}/var/lib/hugmesh/cluster — it is not a node package set;
#   * build-rpi5-stage4.sh:2958 bakes that tree into EVERY cluster-class node (only
#     ROLE_CLIENT desktops skip it), and specs/cluster/app-of-apps.yaml recurses with
#     prune:true — so two nodes with different service sets would be two conflicting
#     desired states for ONE cluster, and the surviving tree would DELETE the other's
#     services. Per-node service sets would produce a broken cluster, not a choice.
#   * Studio's own model already agrees: core/worklist.py WorklistEntry carries no
#     service field, and _materialize_one deepcopies the shared base into every node.
_SERVICES_SCOPE_NOTE = (
    "Chosen ONCE for the whole mesh — not per node. These selections are baked into "
    "the cluster GitOps tree that every cluster node shares, so a single set of "
    "services is what makes a coherent cluster (per-node sets would fight each other). "
    "What IS per node is on the earlier node-images step: the node's ROLE (an edge-AI "
    "node is chosen there) and its hardware."
)

# The honest exception, stated rather than papered over: two slugs really are
# node-scoped in the registry (specs/cluster/optional-services.yaml:498 egress-vpn and
# :534 tor both carry `scope: node`), but Studio has no per-node service field and
# adding one would change the emitted argv — out of scope for a presentation fix.
# Queued as a real feature rather than silently omitted.
_SERVICES_NODE_SCOPE_CAVEAT = (
    "Note: tor and egress-vpn are node-scoped services in the platform registry, but "
    "Studio applies them mesh-wide today (every cluster node gets the same setting)."
)

# Managed backing services (I8/M2). Honest inline note: 'managed' points ONE in-mesh
# datastore/infra at a hosted cloud endpoint INSTEAD of running it in-cluster. Self-hosted
# is the default for every service — leaving every box unchecked is byte-identical to
# today. Creds are operator-supplied via ESO/Vault (never entered here, never on argv).
_MANAGED_SCOPE_NOTE = (
    "Point an in-mesh backing service (a datastore/infra the mesh normally runs itself) "
    "at a HOSTED cloud endpoint (AWS / Azure) INSTEAD of running it in-cluster. "
    "Self-hosted is the default for every service — leave a box unchecked to keep the "
    "in-mesh workload byte-identically. Endpoints are non-secret coordinates; credentials "
    "are supplied separately via the KEYS USB (ESO/Vault), never here. "
    "See docs/MANAGED-SERVICES.md."
)


def _hint(text: str) -> "QtWidgets.QLabel":
    """A small word-wrapped gray helper label (the page-clarity pattern used across the
    wizard: says what a group of fields is FOR, in plain language)."""
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet("color: gray;")
    return lab


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


def _field_default(name: str):
    """An ImageConfig field's declared default.

    Used by the default-expansion rule so it compares against the dataclass's own
    truth rather than literals restated in the GUI (``snort`` defaults to True, for
    example, which a hand-written "off means default" check gets exactly backwards).
    Mirrors _gating.clear_unsupported's default lookup.
    """
    f = ImageConfig.__dataclass_fields__[name]
    return f.default_factory() if f.default is MISSING else f.default


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
        # Title/subtitle are set path-aware in initializePage (a standalone desktop has
        # no mesh/tailnet, so this page IS its network-identity + egress + security step,
        # while cloud/mesh use it for the domain, superdomain and cluster services).
        self.setTitle("Network, identity & egress")
        lay = scrollable(self)

        # The 3-state legend lives at PAGE level, not per section: tri-state boxes are
        # spread across three sections (aide in Security, edge_ai in Edge-AI, tor /
        # character-studio / edge-ai-tts in Services), so a per-section legend would be
        # both repeated and invisible whenever that section is collapsed. One always-on
        # line at the top explains the square wherever it turns up.
        self.tri_legend = _hint(_TRI_LEGEND)
        lay.addWidget(self.tri_legend)

        # ---- Group 1: brand identity & domain (visited in ALL modes) -------------
        # Each group is wrapped in a Collapsible (see _widgets.Collapsible) whose header
        # carries the section title — hence the untitled QGroupBoxes here: the name is
        # set once, on the collapsible() call right after each group is built.
        self.identity_box = QtWidgets.QGroupBox("")
        il = QtWidgets.QVBoxLayout(self.identity_box)
        self.identity_help = _hint(
            "Brand identity plus the PUBLIC apex domain the image serves — the go-live "
            "target (distinct from the internal superdomain below).")
        il.addWidget(self.identity_help)
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
        # Identity carries the REQUIRED fields (brand id, the public apex domain), so it
        # is never collapsed by default — default expansion must not hide a must-set field.
        self.identity_section = collapsible("Identity & domain", self.identity_box)
        lay.addWidget(self.identity_section)

        # ---- Group 2: tailnet + SSO (cloud branded desktops only, spec 3) --------
        self.tailnet_box = QtWidgets.QGroupBox("")
        tl = QtWidgets.QVBoxLayout(self.tailnet_box)
        self.tailscale = QtWidgets.QCheckBox("Join the tailnet (tailscale/headscale)")
        self.sso = QtWidgets.QCheckBox("Enable SSO login (Casdoor)")
        tl.addWidget(self.tailscale)
        tl.addWidget(self.sso)
        # Two checkboxes and a real join decision — expanded.
        self.tailnet_section = collapsible("Tailnet + SSO", self.tailnet_box)
        lay.addWidget(self.tailnet_section)
        # shown INSTEAD of the group when it is hidden (standalone/mesh), explaining why.
        # Deliberately a PAGE-level sibling of the section, not inside it: it is the
        # replacement for the whole hidden section, so it must survive the section's
        # own visibility gate.
        self.tailnet_reason = QtWidgets.QLabel()
        self.tailnet_reason.setWordWrap(True)
        self.tailnet_reason.setStyleSheet("color: gray;")
        self.tailnet_reason.setVisible(False)
        lay.addWidget(self.tailnet_reason)

        # ---- Group 3: mesh control plane (cloud AND mesh) ------------------------
        self.mesh_box = QtWidgets.QGroupBox("")
        cp = QtWidgets.QVBoxLayout(self.mesh_box)
        cp.addWidget(_hint(
            "The internal orchestration superdomain every mesh node joins "
            "(headscale/tailnet control plane). Permanently internal; never the "
            "go-live apex above."))
        # Headscale URL (G2) — the brand mesh control-server URL baked to
        # /etc/hugmesh/headscale-url. NOT a builder flag on any platform
        # (NON_ARGV_FIELDS): build_driver delivers it as the HEADSCALE_URL env var
        # (docker -e / native env), so it is never greyed per platform.
        self.headscale_url = QtWidgets.QLineEdit()
        self.headscale_url.setPlaceholderText(
            "https://headscale.example.org  (empty = local-first: control node uses its LAN IP)")
        self.headscale_url.setToolTip(
            "Baked to /etc/hugmesh/headscale-url. Delivered to the builder as the "
            "HEADSCALE_URL environment variable — not a CLI flag.")
        cp.addWidget(_row("Headscale URL", self.headscale_url))
        # mesh agent version pins + the headscale-only posture (G29; all builders)
        self.headscale_version = QtWidgets.QLineEdit()
        self.headscale_version.setPlaceholderText("Pin a Headscale version (leave blank for the builder default)")
        self.headscale_version.setToolTip("Pins the Headscale agent version — the --headscale-version builder flag.")
        self.tailscale_version = QtWidgets.QLineEdit()
        self.tailscale_version.setPlaceholderText("Pin a Tailscale version (leave blank for the builder default)")
        self.tailscale_version.setToolTip("Pins the Tailscale agent version — the --tailscale-version builder flag.")
        cp.addWidget(_row("Headscale version", self.headscale_version))
        cp.addWidget(_row("Tailscale version", self.tailscale_version))
        self.skip_tailscale = QtWidgets.QCheckBox(
            "Skip the tailscale agent (--skip-tailscale: headscale-only posture — "
            "distinct from not joining the mesh)")
        cp.addWidget(self.skip_tailscale)
        # orchestration superdomain (spec 5): the permanently-internal <brand>.internal
        # every mesh node joins (manifest + KEYS channel, plus the WS-SUPER-B builder
        # bake: --superdomain on a mesh build writes <etc>/superdomain + the headscale
        # MagicDNS suffix; distinct from the public apex above, I7). Editable in mesh; a
        # read-only derived display in cloud (so the Users-page superadmin lock is explicable).
        self.superdomain = QtWidgets.QLineEdit()
        self.superdomain.setToolTip(
            "The internal orchestration domain all mesh nodes join (empty = derived "
            "<brand>.internal). Baked into mesh images via --superdomain + the mesh "
            "manifest + the KEYS channel — never the go-live apex.")
        self.superdomain_row = _row("Orchestration superdomain", self.superdomain)
        cp.addWidget(self.superdomain_row)
        # Carries the superdomain, which on a MESH build is a field the operator may
        # genuinely need to set — expanded rather than folded away.
        self.mesh_section = collapsible("Mesh control plane", self.mesh_box)
        lay.addWidget(self.mesh_section)

        # ---- egress VPN ----------------------------------------------------------
        self.egress = QtWidgets.QLineEdit()
        ebtn = _file_picker(self, self.egress, "Egress VPN conf", "VPN (*.conf *.ovpn *.nmconnection)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.egress, 1); h.addWidget(ebtn)
        self.egress_row = w   # greyed as one unit (line edit + Browse…) per platform
        # The egress widgets were loose on the page; they get a plain container purely
        # so the section has one thing to fold. The container is NEVER gated itself —
        # gate_widgets_role_class still drives egress_row/egress_locked directly, so the
        # role-class hide keeps working exactly as before.
        self.egress_box = QtWidgets.QWidget()
        eg = QtWidgets.QVBoxLayout(self.egress_box)
        eg.setContentsMargins(0, 0, 0, 0)
        eg.addWidget(_hint(
            "Egress VPN — route this image's outbound traffic through a provided VPN "
            "profile (optional). Lock it to stop a managed node's user removing it."))
        eg.addWidget(_row("Egress VPN", w))
        self.egress_locked = QtWidgets.QCheckBox("Lock egress VPN (managed node — user cannot remove)")
        eg.addWidget(self.egress_locked)
        self.egress_section = collapsible("Egress VPN", self.egress_box)
        lay.addWidget(self.egress_section)
        # network/host security stack
        sec = QtWidgets.QGroupBox("")
        self.security_box = sec
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
        # Every control here ships a sane hardened default (proxy auto / snort off /
        # aide "leave default" / root-login no), so this folds away when it is all
        # default — initializePage re-expands it if anything is overridden or gated.
        self.security_section = collapsible("Security stack", sec, expanded=False)
        lay.addWidget(self.security_section)
        # edge-AI inference (GPU cluster roles — cloud/mesh). Serves an OpenAI-compatible
        # model API to the mesh; the model library (runtime/preload/default) is tunable.
        self.edge_ai_box = QtWidgets.QGroupBox("")
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
        # Default-off service with builder-default runtime/models — folds away until it
        # is actually in play (initializePage expands it when the tri-state is overridden,
        # which includes the edge_ai role's auto-check).
        self.edge_ai_section = collapsible(
            "Edge-AI inference (GPU model API to the mesh)", self.edge_ai_box, expanded=False)
        lay.addWidget(self.edge_ai_section)
        # ---- the optional-services section --------------------------------------
        # tor / character-studio / edge-ai-tts were loose on the page, directly above the
        # services box they belong with; they are grouped into that SECTION now. They are
        # deliberately kept as SIBLINGS of services_box, not children of it: gate_widgets
        # maps "optional_services" -> services_box and disables it as a unit (G12), and
        # reparenting these three into it would silently drag them into that grey.
        svc_content = QtWidgets.QWidget()
        sv_outer = QtWidgets.QVBoxLayout(svc_content)
        sv_outer.setContentsMargins(0, 0, 0, 0)
        self.services_scope_note = _hint(_SERVICES_SCOPE_NOTE)
        sv_outer.addWidget(self.services_scope_note)
        self.services_node_scope_note = _hint(_SERVICES_NODE_SCOPE_CAVEAT)
        sv_outer.addWidget(self.services_node_scope_note)
        # Tor v3 onion (hidden) service (node-scoped; cloud/mesh cluster node builds).
        self.tor_onion = QtWidgets.QCheckBox(
            "Tor v3 onion service — expose the cluster gateway as a .onion (default off)")
        self.tor_onion.setTristate(True)   # G34: --with-tor / --no-tor / leave default
        sv_outer.addWidget(self.tor_onion)
        # Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate).
        # Cloud/mesh cluster builds only (it is a frontend cluster service).
        self.character_studio = QtWidgets.QCheckBox(
            "Character Studio (VN) — character creator + chat remote at /character-studio (default off)")
        self.character_studio.setTristate(True)   # G34: --with-/--no-character-studio / default
        sv_outer.addWidget(self.character_studio)
        # Character Forge (3D) multi-app slug — OPTIONAL, DEFAULT-OFF (admin gate).
        # BFF db + BFF api + UI remote (the 3D character maker + XR chat avatars;
        # docs/XR-CHAT.md). Cloud/mesh cluster builds only; gated exactly like
        # character_studio above (PLATFORM capability, not mode).
        self.character_forge = QtWidgets.QCheckBox(
            "Character Forge (3D) — 3D character maker (BFF db+api + remote at /character-forge; default off)")
        self.character_forge.setTristate(True)   # G34: --with-/--no-character-forge / default
        sv_outer.addWidget(self.character_forge)
        # edge-ai-tts (VN voice synthesis) — OPTIONAL, DEFAULT-OFF. CPU-only,
        # self-contained (NO edge-ai/GPU dependency, unlike the Analysis API inside
        # edge_ai_box above) — deliberately placed OUTSIDE edge_ai_box (which hides
        # outside cloud/mesh mode) and gated like character_studio: PLATFORM
        # capability only, not mode (G16) — reachable on any build that bakes a
        # cluster tree, incl. standalone rpi5 'generic'.
        self.edge_ai_tts = QtWidgets.QCheckBox(
            "Edge AI — voice synthesis (TTS) — Piper TTS + viseme timeline for VN voice (default off)")
        self.edge_ai_tts.setTristate(True)   # G34: --with-/--no-edge-ai-tts / default
        sv_outer.addWidget(self.edge_ai_tts)
        # cluster optional services (--optional-services multi-select) + the games stack.
        # An empty checklist emits NOTHING (the builder default akkoma tuwunel phpbb
        # applies), so the two sentinels get their own mutually-exclusive checkboxes:
        # explicit none (G13) and the full user-level set (G14).
        self.services_box = QtWidgets.QGroupBox("Optional cluster services (--optional-services)")
        svl = QtWidgets.QVBoxLayout(self.services_box)
        svl.addWidget(_hint(
            "Which optional services this mesh runs (akkoma / tuwunel / phpbb "
            "…). Leave everything unticked to keep the builder default set."))
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
            "Enable games — bake the HugMesh Game Studio + the games.<domain> service")
        svl.addWidget(self.games)
        sv_outer.addWidget(self.services_box)
        # EXPANDED by default and not folded away: this section is where the tri-state
        # boxes the operator asked about live, and the legend + the mesh-wide scope
        # answer are only useful if they are on screen when the page loads.
        self.services_section = collapsible("Optional cluster services", svc_content)
        lay.addWidget(self.services_section)

        # ---- managed backing services (I8/M2) -----------------------------------
        # Per tier-1/2 backing service: a self-hosted(default)/managed toggle + an
        # endpoint line-edit enabled ONLY when managed. Tier-3 ids are shown read-only
        # with their blocker note (the builder REFUSES a managed swap for them in v1).
        # Platform-gated to x86/rpi5 via gate_widgets("managed_services", managed_box) —
        # the only two builders that parse --managed-service / bake a cluster tree.
        self.managed_box = QtWidgets.QGroupBox("Managed backing services (--managed-service)")
        mgl = QtWidgets.QVBoxLayout(self.managed_box)
        mgl.addWidget(_hint(_MANAGED_SCOPE_NOTE))
        # id -> (managed-checkbox, endpoint line-edit)
        self.managed_rows: dict[str, tuple] = {}
        for sid in MANAGED_SERVICE_TIER12_IDS:
            chk = QtWidgets.QCheckBox(f"{sid} — managed (hosted endpoint)")
            ep = QtWidgets.QLineEdit()
            ep.setPlaceholderText("hosted endpoint, e.g. host:port | https://host | aws")
            ep.setEnabled(False)
            # endpoint is live only while 'managed' is checked (self-hosted = no endpoint)
            chk.toggled.connect(lambda on, e=ep: e.setEnabled(on))
            mgl.addWidget(chk)
            mgl.addWidget(_row("  endpoint", ep))
            self.managed_rows[sid] = (chk, ep)
        # tier-3: named but REFUSED in v1 — read-only, with the blocker (why not yet).
        mgl.addWidget(_hint(
            "The following are named in the registry but stay self-hosted in v1 (the "
            "builder refuses a managed swap for them — the reason is shown):"))
        for sid in MANAGED_SERVICE_TIER3_IDS:
            lab = QtWidgets.QLabel(
                f"{sid}: self-hosted only — {MANAGED_SERVICE_TIER3_BLOCKER.get(sid, '')}")
            lab.setWordWrap(True)
            lab.setEnabled(False)
            mgl.addWidget(lab)
        self.managed_section = collapsible("Managed backing services", self.managed_box,
                                           expanded=False)
        lay.addWidget(self.managed_section)
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
        # Path-aware header (spec 3-7): a standalone desktop has no mesh/tailnet, so this
        # page IS its network-identity / egress / security step; cloud/mesh use it for the
        # domain, the orchestration superdomain and the cluster services.
        if c.mode == "standalone":
            self.setTitle("Network identity, egress & security")
            self.setSubTitle(
                "Brand identity, the optional egress VPN and the host security "
                "stack for this standalone desktop. No mesh, no tailnet, no SSO.")
        else:
            self.setTitle("Domain, mesh & services")
            self.setSubTitle(
                "The cluster services this mesh runs, the public apex domain "
                "it serves, and the internal orchestration superdomain every node joins."
                if c.mode == "mesh" else
                "The domain this client joins, its tailnet + SSO login, egress "
                "and the optional services it can reach.")
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
        # Hide the SECTION alongside its content, or a mode-gated-away group leaves an
        # orphan header behind that expands to nothing. The gate above still drives the
        # box itself, so every existing isVisible() gate assertion keeps its meaning.
        self.tailnet_section.setVisible(ss_visible)
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
        self.mesh_section.setVisible(show_cp)
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
                f"{c.brand or 'hugmesh'}.internal  (empty = derived)")
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
        # The gate is pinned on the SECTION, never on edge_ai_box: the box is the
        # section's collapsible CONTENT, so set_expanded() drives its setVisible() too.
        # Setting the mode gate there as well would make edge_ai_box.isVisible() mean
        # "applicable AND expanded" — two meanings on one flag, exactly the confusion
        # between collapse and the platform/mode gate this page must not have (a
        # collapsed section would read as an inapplicable one). The section is the
        # gate's only carrier; the box's visibility means "expanded" and nothing else.
        self.edge_ai_section.setVisible(c.mode in ("cloud", "mesh"))
        self.tor_onion.setCheckState(_tri_state(c.tor_onion_service)
                                     if platform_supports("tor_onion_service", c.platform)
                                     else Qt.CheckState.Unchecked)
        # Tor is a k8s-NODE service — only meaningful for cloud/mesh cluster builds.
        self.tor_onion.setVisible(c.mode in ("cloud", "mesh"))
        self.character_studio.setCheckState(_tri_state(c.character_studio)
                                            if platform_supports("character_studio", c.platform)
                                            else Qt.CheckState.Unchecked)
        self.character_forge.setCheckState(_tri_state(c.character_forge)
                                           if platform_supports("character_forge", c.platform)
                                           else Qt.CheckState.Unchecked)
        self.edge_ai_tts.setCheckState(_tri_state(c.edge_ai_tts)
                                       if platform_supports("edge_ai_tts", c.platform)
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
        self.character_forge.setVisible(True)
        self.edge_ai_tts.setVisible(True)
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
        # …and on an UNAFFILIATED image, HIDE the cluster-services picker outright
        # rather than merely captioning it. Operator report: "the unaffiliated
        # desktop image wizard still shows options like mesh services and branding
        # and login when it shouldn't". For every other client-class role the
        # heads-up note above is the right call — the flags ARE parsed, they just
        # do nothing on a desktop, and a branded desktop can legitimately be
        # re-rolled as a node later. Unaffiliated is categorically different: the
        # role exists to bake ZERO HugMesh affiliation, and cluster services are
        # the platform machinery it is defined by NOT having. Offering a mesh
        # service list on that screen is offering a choice that cannot mean
        # anything. Values are cleared below so hiding changes no argv.
        unaffiliated = (c.role == UNAFFILIATED_ROLE or getattr(c, "unaffiliated", False))
        if unaffiliated:
            # Clear to the UNSET state, NOT to the "none" sentinel: SERVICES_NONE is
            # an explicit choice that emits `--optional-services none`, so checking it
            # here would ADD a flag the operator never picked — hiding a control must
            # not change the build. (Caught by
            # test_hiding_the_services_box_leaves_the_emission_neutral, which failed on
            # exactly that first attempt.)
            self.services_none.setChecked(False)
            self.services_all.setChecked(False)
            self.services.clearSelection()
            self.services_box.setVisible(False)
            self.services_role_note.setVisible(False)
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
            "character_forge": self.character_forge,
            "edge_ai_tts": self.edge_ai_tts,
            "optional_services": self.services_box,
            "enable_games": self.games,
            "managed_services": self.managed_box,
        })
        # Managed backing services (I8/M2): a cluster concern — shown for cloud/mesh
        # builds (a standalone desktop bakes no cluster tree), platform-gated to x86/rpi5
        # by gate_widgets above. Populate each tier-1/2 row from cfg.managed_services;
        # an id present => managed (checked) with its endpoint, else self-hosted (default).
        self.managed_section.setVisible(c.mode in ("cloud", "mesh"))
        for sid, (chk, ep) in self.managed_rows.items():
            endpoint = c.managed_services.get(sid, "")
            chk.setChecked(bool(endpoint))
            ep.setText(endpoint)
            ep.setEnabled(bool(endpoint))
        # Egress VPN is desktop-class ONLY, and the platform gate above cannot say so:
        # egress_vpn is x86-supported, and the mesh worklist base forces platform="x86"
        # (the option superset), so on a mesh flow that gate passes and the row stayed live
        # on every cluster node. The builder warns "--egress-vpn given for a non-desktop
        # role ... ignoring" — but "ignoring" covers only the staging leg; the VPN userspace
        # packages and the CONFIG_WIREGUARD kernel fragment are NOT role-gated, so a node
        # paid for a VPN it will never use. HIDE the row (same idiom as the home group and
        # the standalone checkbox) so it cannot be set on a node-class image at all.
        egress_ok = scope_allows("egress_vpn", c)
        gate_widgets_role_class([self.egress_row, self.egress_locked], egress_ok,
                                out_of_scope_note("egress_vpn", c), hide=True)
        # Fold the whole SECTION away with its content: the gate above hides the field
        # and the lock box, but _row()'s "Egress VPN" caption and this section's header
        # are not gate members, so a node-class image was left with an Egress VPN header
        # over an empty body. (The orphan caption predates the sections; hiding the
        # section takes it with it.) The gate still drives the widgets themselves, so
        # every existing egress gate assertion keeps its meaning.
        self.egress_section.setVisible(egress_ok)
        # gate_widgets blanks the tooltip on every ENABLED widget — restore the
        # 3-state legend on the live tri-state boxes (disabled ones keep the
        # unsupported-platform note it set).
        for w in (self.aide, self.edge_ai, self.tor_onion, self.character_studio,
                  self.character_forge, self.edge_ai_tts):
            if w.isEnabled():
                w.setToolTip(_TRI_TIP)
        self._apply_default_expansion()

    def _apply_default_expansion(self):
        """Fold away the optional sections that are entirely at their defaults, and only
        those. Re-evaluated on every visit, from the CONFIG — never from widget
        visibility, so it can never be confused with (or interfere with) the platform
        gate: collapsing changes nothing about what the page collects or emits.

        Applied through set_default_expanded(), so this is a DEFAULT and not a command:
        re-deriving on every visit is what lets a change made on an earlier page open
        the section that shows it (picking the edge_ai role auto-checks the service),
        but a section the operator opened by hand is never re-folded underneath them.

        A section is force-expanded when it holds something the operator should see: an
        overridden tri-state (i.e. one that is not the leave-the-default square), a
        non-default value, or a greyed control whose gate note explains itself. The
        sections carrying required or must-set fields (identity, mesh/superdomain) and
        the ones the reports were about (services) are never collapsed by default."""
        # Compared against ImageConfig's OWN declared defaults, never against restated
        # literals: `snort` for instance defaults to True, so a hand-written "snort is
        # off when default" would fold the section away on a config that had actually
        # overridden it to off. _field_default() cannot drift from the dataclass.
        sec_default = (self.proxy_stack.currentText() == _field_default("proxy_stack")
                       and self.snort.isChecked() == _field_default("snort")
                       and self.aide.checkState() == _tri_state(_field_default("aide"))
                       and self.root_login.currentText() == _field_default("root_login"))
        # A greyed control means a gate note the operator should be able to read.
        sec_gated = not (self.proxy_stack.isEnabled() and self.snort.isEnabled()
                         and self.aide.isEnabled())
        self.security_section.set_default_expanded(not sec_default or sec_gated)
        # Edge-AI: the tri-state is the section's switch — expanded whenever it is
        # overridden either way (the edge_ai ROLE auto-checks it, which must show), or
        # when any of its tuning fields carry a value.
        edge_default = (
            self.edge_ai.checkState() == _tri_state(_field_default("edge_ai_service"))
            and self.edge_ai_analysis.isChecked() == _field_default("edge_ai_analysis")
            and self.edge_ai_models.text().strip() == _field_default("edge_ai_models")
            and self.edge_ai_default.text().strip() == _field_default("edge_ai_model_default")
            and self.edge_ai_runtime.currentText() == _field_default("edge_ai_runtime"))
        self.edge_ai_section.set_default_expanded(not edge_default)
        # Managed backing services: all-default (nothing managed) folds away; a live
        # managed selection forces it open so the endpoints are visible on load.
        self.managed_section.set_default_expanded(bool(self.wiz.cfg.managed_services))

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
        c.brand = self.brand.text().strip() or "hugmesh"
        c.brand_title = self.brand_title.text().strip() or "HugMesh Systems"
        c.org = self.org.text().strip() or "Snapdragon-Systems"
        c.cluster_domain = self.domain.text().strip() or "hugmesh.systems"
        c.games_domain = self.games_domain.text().strip()
        rs = self.release_state.currentText()
        c.release_state = "" if rs == "default" else rs
        # Scope-gated collect, mirroring HomePage's standalone line: the hidden widget
        # KEEPS its text/checked state, so without this a conf picked while the role was a
        # desktop would silently ride a later switch to a node role. cfg is the source of
        # truth initializePage re-reads, so an in-scope image collects exactly as before.
        egress_ok = scope_allows("egress_vpn", c)
        c.egress_vpn = self.egress.text().strip() if egress_ok else ""
        c.egress_vpn_locked = self.egress_locked.isChecked() and egress_ok
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
        c.character_forge = _tri_value(self.character_forge)
        c.edge_ai_tts = _tri_value(self.edge_ai_tts)
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
        # Managed backing services (I8/M2): a row contributes id -> endpoint ONLY when
        # 'managed' is checked AND an endpoint is entered — a checked-but-empty row is an
        # incomplete selection, dropped so the default (no boxes checked) stays byte-
        # identical. Endpoint SHAPE is fail-closed later by to_cli_args/validate_identity
        # (tier-3 refused, no shell metachars), the same boundary the idp fields use.
        c.managed_services = {
            sid: ep.text().strip()
            for sid, (chk, ep) in self.managed_rows.items()
            if chk.isChecked() and ep.text().strip()
        }
        # the greyed (platform-unsupported) widgets were still collected above —
        # reset those fields to their defaults so a value picked while another
        # platform was selected can't linger into save() or the emitted argv.
        clear_unsupported(c, (
            "sso", "games_domain", "release_state", "egress_vpn", "egress_vpn_locked",
            "proxy_stack", "snort", "aide",
            "edge_ai_service", "edge_ai_runtime", "edge_ai_models",
            "edge_ai_model_default", "edge_ai_analysis", "edge_ai_tts", "tor_onion_service",
            "character_studio", "character_forge",
            "optional_services", "exclude_services", "enable_games",
            "managed_services",
        ))
        return True
