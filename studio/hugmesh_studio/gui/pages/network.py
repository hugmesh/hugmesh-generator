"""NetworkPage — the domain/mesh/services step, as COLLAPSIBLE sections (identity &
domain, tailnet/SSO, the mesh control plane incl. the orchestration superdomain,
egress VPN, the security stack, edge-AI, and the cluster SERVICES list).

The services surface was rebuilt for the operator's asks 1-5 and then again for ask 23
(2026-08). What it is now: ONE TABLE (``services_table``, a QTreeWidget) carrying every
service AND app the image can run — the --optional-services catalogue, the dedicated-flag
services, edge-AI with its sub-options, and the managed backing services — with the OPTIONS
as columns (On / Hosting-mode / Setting / What enabling it does) and the groups as
expandable rows. What it stopped being: four loose 3-state checkboxes, a scrolling slug
list, a free-text subtractive line edit and TWO further page sections of its own, with
`character-forge` on screen twice. There is no part-checked state anywhere on this page any
more; see the _OFF_TIP block below for what "definitely off" emits per flag and why that is
honest rather than theatre. See the ASK 23 block in __init__ for the table's design.

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


# NOT `from ..qt import Qt, QtWidgets` any more, and the missing name is the point: this
# module used to be where the wizard's 3-state checkbox idiom lived (it owned _tri_state /
# _tri_value, which RolePage imported from here). Asks 1 and 4 removed the last
# part-checked box on the page, so nothing here touches Qt.CheckState at all — the helpers
# moved to _widgets.py for their one remaining consumer. Importing Qt "just in case" would
# leave the next reader a working import for the very idiom this page is now defined by
# not having.
from ..qt import QtWidgets
from ._scroll import scrollable
# Imported as a MODULE, not by name, purely so this page can prefer core.config's named
# predicate the moment it exists without an import-time hard dependency on it — see
# _cluster_identity_applies() for why both routes are the same rule and neither is a
# page-local copy of it.
from ...core import config as _config
from ...core.config import (
    BUILTIN_DEFAULT_SERVICES,
    ImageConfig,
    MANAGED_SERVICE_TIER3_BLOCKER,
    MANAGED_SERVICE_TIER3_IDS,
    MANAGED_SERVICE_TIER12_IDS,
    OPTIONAL_SERVICES_BY_PLATFORM,
    RELEASE_STATE_CHOICES,
    RPI5_ROLE_MAP,
    SERVICE_DESCRIPTIONS,
    SERVICE_GROUPS,
    SERVICES_ALL,
    SERVICES_NONE,
    UNAFFILIATED_ROLE,
    USER_LEVEL_SERVICES,
    X86_NODE_ROLES,
    field_default,
    tailnet_sso_visible,
)
from ._gating import (
    clear_unsupported,
    gate_widgets,
    gate_widgets_role_class,
    out_of_scope_note_flow,
    platform_supports,
    scope_allows,
    scope_allows_flow,
)
from ._widgets import _file_picker, _row, collapsible

# ── DEFINITE OFF: why there is no tri-state left on this page ────────────────────────
# Operator, verbatim (asks 1 + 4): "gui studio should leave optional services and edge ai
# unchecked instead of half checked for default no" / "tor onion services are optional and
# off and unchecked by default".
#
# The boxes used to be 3-state, where the part-checked SQUARE meant "emit neither flag,
# leave the brand-profile/builder default alone" and was the INITIAL state. That state is
# gone. Every service box here is an ordinary two-state checkbox with a DEFINITE default,
# and unchecked means OFF — not "unspecified".
#
# WHAT "DEFINITELY OFF" EMITS, per flag — derived once, here, so the next reader does not
# have to re-derive it from the builders:
#
#   box unchecked  ->  the config's "off" value  ->  --no-tor / --no-character-studio /
#                      --no-character-forge / --no-edge-ai-tts / --no-edge-ai / --no-aide
#
# and that is the right call even though four of those six are no-ops in the common case:
#
#   * build-x86-host-stage4.sh acts ONLY on the `true` arm for tor (:1150),
#     character-studio (:1166), character-forge (:1182) and edge-ai-tts (:1218) — there is
#     no `= false` arm at all — and the builder's own default set (:141,
#     OPTIONAL_SERVICES="akkoma tuwunel phpbb") contains none of them. So with no brand
#     profile in play, --no-tor changes nothing;
#   * BUT brand.conf is sourced at :888, BEFORE the arg loop at :891. A brand profile that
#     sets WANT_TOR=true IS overridden by --no-tor. Emitting nothing there would leave the
#     service ON while this page showed an unchecked box — the checkbox would be lying,
#     which is precisely the ambiguity the operator asked us to remove. So we emit the
#     strongest "off" the flag can express and the box's claim stays true.
#   * --no-aide (:486 WANT_AIDE=false, consumed as a plain bool at :4786/:5139) and
#     --no-edge-ai (:932, the only way to suppress the edge_ai ROLE's auto-selection) are
#     REAL subtraction, so for those two "definitely off" is load-bearing on every build.
#
# The one thing --no-* cannot do is remove a slug a brand.conf put directly into
# OPTIONAL_SERVICES; only EXCLUDE_SERVICES (applied last, :1234-1246) does that. The
# services checklist covers that case instead — see _SERVICES_OVERRIDE_NOTE.
_OFF_TIP = ("Two-state: checked = ON for this build (--with-…), unchecked = OFF "
            "(--no-…, which also overrides a brand profile that switched it on).")

# Services are MESH-WIDE, not per-node — stated on the page because the operator
# reasonably asked whether they were selectable per node (as the worklist's per-node
# columns are). Grounded in the builders, not in UI convenience:
#   * build-rpi5-stage4.sh:1712 gate_optional_services() prunes each unselected slug's
#     Argo apps/*.yaml + manifests/ + gateway routes out of the baked CLUSTER GitOps
#     tree at ${SYSROOT}/var/lib/hugmesh/cluster — it is not a node package set;
#   * build-rpi5-stage4.sh:3898-3900 bakes that tree into EVERY cluster-class node (only
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
# node-scoped in the registry (specs/cluster/optional-services.yaml:560 egress-vpn and
# :636 tor both carry `scope: node`), but Studio has no per-node service field and
# adding one would change the emitted argv — out of scope for a presentation fix.
# Queued as a real feature rather than silently omitted.
_SERVICES_NODE_SCOPE_CAVEAT = (
    "Note: tor and egress-vpn are node-scoped services in the platform registry, but "
    "Studio applies them mesh-wide today (every cluster node gets the same setting)."
)

# Why "tick anything and the default set is gone" is the honest headline, and why ask 2
# ("remove the exclude services field, it makes no sense") is safe to satisfy in the GUI.
# The builders resolve this precedence themselves — build-x86-host-stage4.sh:138-141 and
# build-rpi5-stage4.sh:243-245, both verbatim "built-in < brand.conf < flag":
#
#     OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"
#
# i.e. --optional-services does not ADD to the built-in default, it REPLACES it. So an
# explicit tick-list is already a complete subtraction: to build "forum-less" you tick
# akkoma and tuwunel and leave phpbb alone. That is what --exclude-services was for from
# this screen, and it is why a free-text slug field sitting next to a checklist that
# already expresses the same thing "makes no sense". The flag itself is untouched and
# still reachable from a brand profile (-C) or extra flags — it is the only knob that can
# subtract from a brand.conf-injected OPTIONAL_SERVICES, so removing the FIELD would have
# left the platform with no subtraction at all.
_SERVICES_OVERRIDE_NOTE = (
    "What is ticked is what gets built. {default} arrive ticked because they are the "
    "builders' own default set — untick one and it is genuinely not built, because this "
    "list REPLACES the default outright rather than adding to it (built-in &lt; brand "
    "profile &lt; this list). That is also why there is no separate \"exclude\" field: "
    "ticking the ones you want IS the subtraction."
).format(default=", ".join(BUILTIN_DEFAULT_SERVICES))

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


# ── THE CLUSTER-IDENTITY AXIS (apex domain / games domain / release state) ───────────
# Operator report, 2026-08-26, verbatim: "There should also be no inbetween menu for
# configuring domain" — on an image measured as role=standalone-unaffiliated /
# platform=x86 (out/sessions/20260826-151356-64070a/build-standalone-unaffiliated.x86.log),
# which arrived at this page with a prefilled "hugmesh.net" apex-domain box.
#
# WHY THE GATE IS NOT `cfg.mode == "standalone"`, which is what the report reads like.
# The two arg builders disagree ON PURPOSE, and a blanket mode test would have regressed
# every ARM standalone build:
#
#   * core/config.py::_x86_args — --cluster-domain, --games-domain and --release-state
#     all sit INSIDE `if self.mode in ("cloud", "mesh")`. On a standalone x86 image not
#     one of them can reach the argv, so the box the operator saw was collecting a value
#     the builder would never be told. THAT is the defect.
#   * core/config.py::_arm_common_args — `if self.cluster_domain != "hugmesh.net"` with
#     NO mode fork, shared by all NINE arm64 builders; and _rpi5_args emits
#     --release-state / --games-domain the same unconditional way. A standalone rpi5
#     'generic' image really does carry a cluster domain (build-rpi5-stage4.sh:3863) —
#     'generic' is the one standalone role that bakes a cluster GitOps tree (G16; see
#     _client_class_role). Hiding the row there would have blanked a live field.
#
# So the rule is a MODE narrowing that is true on x86 ONLY, and it lives in core/config.py
# with every other axis rule — FIELD_SCOPE's `mode_platforms` twin of `class_platforms`,
# _CLUSTER_IDENTITY_FIELDS / _CLUSTER_PLANE_MODE_GATED_PLATFORMS. This page must not own
# a second spelling of it (the _gating.py module note: one implementation, so the wizard
# and the Qt-free consumers cannot disagree).
def _cluster_identity_applies(cfg) -> bool:
    """Does this image bake a cluster identity plane at all?

    ONE rule, reachable by two names, because two lanes landed it in the same checkout:
    core.config's named predicate if it is present, else the generic composed field gate
    over ``cluster_domain``. They are not alternatives — the named predicate reads the
    same FIELD_SCOPE entry — and ``cluster_domain`` is the right field to ask through:
    it is declared for ALL TEN builders (every build-*-stage4.sh has exactly one
    ``--cluster-domain|--domain)`` arm), so its scope carries the mode axis alone with
    no platform or class term to muddy the answer.

    Deliberately NOT asked per-field for the other two. ``games_domain`` and
    ``release_state`` are x86+rpi5-only, and their PLATFORM axis is already answered
    downstream by ``gate_widgets`` — which GREYS with a "cleared when you leave the page"
    tooltip rather than hiding, the established treatment for "this builder has no flag"
    (tests/test_pages_identity.py::test_release_state_and_games_domain_grey_and_clear_
    off_x86_rpi5 pins that grey on a frite cloud build). Routing the platform axis through
    this hide would have silently converted that explained grey into a disappearance."""
    named = getattr(_config, "cluster_identity_applies", None)
    if named is not None:
        return bool(named(cfg))
    return scope_allows("cluster_domain", cfg)


# The reason shown on the hidden cluster rows. Hand-written rather than taken from
# ``out_of_scope_note``: that helper's MODE arm says "every image in this flow exists to
# join the cluster, which is exactly what this option turns off" — true of the flows it
# was written for, and the exact opposite of the truth here, where the flow is standalone
# and it is the CLUSTER that is absent. A wrong why is worse than none (the lesson
# out_of_scope_note itself records).
_CLUSTER_IDENTITY_NOTE = (
    "Not applicable to this image: the x86 builder bakes the cluster plane "
    "(--cluster-domain / --games-domain / --release-state) only for cloud and mesh "
    "images, so a value here would be dropped from the build. ARM builds keep the row — "
    "they bake a cluster domain in every mode.")

# The reason shown when the brand-identity rows are hidden. DECISION 1 (operator,
# 2026-08-26) is split into two halves and this text must carry both, or it reads as
# "no theming at all" and contradicts the branding step the operator asked for:
#   IDENTITY stays forbidden — --brand / --brand-title / --org / --brand-logo /
#     --brand-locked / a -C brand profile. core/config.py::_check_unaffiliated_conflicts
#     raises ValueError on any of them, mirroring build-x86-host-stage4.sh, which exits
#     non-zero on the same flags. A brand IS an affiliation.
#   LOOK is now allowed — theme / branding-dir / wallpaper / grub background + theme /
#     login background / accent colour / colour scheme, baked under NEUTRAL names.
_BRAND_IDENTITY_NOTE = (
    "This image bakes NO HugMesh brand identity — brand id, brand title, org and a "
    "brand profile (-C) are what make an image affiliated, and the builder exits "
    "non-zero if it is given any of them for this role. Its LOOK is still yours: theme, "
    "wallpaper, accent colour and the login/GRUB backgrounds are set on the branding "
    "step and bake under neutral names.")


def _identity_help_text(brand: bool, cluster: bool, superdomain_on_screen: bool) -> str:
    """The "Identity & domain" help line, COMPOSED from what the section still contains.

    Defect (2): the fixed sentence said "...distinct from the internal superdomain below",
    but the superdomain row lives in ``mesh_box``, which every standalone flow hides — so
    on the operator's image the help pointed at a control that was not on the page, and
    then went on to describe an apex-domain box that (defect 1) should not have been
    either. Same treatment as ``tailnet_reason``: say only what is true of THIS visit.

    Returns "" when neither half survives, which is the whole-section-hidden case."""
    if brand and cluster:
        head = ("Brand identity plus the PUBLIC apex domain the image serves — the "
                "go-live target")
    elif brand:
        head = "The brand identity baked into this image"
    elif cluster:
        head = "The PUBLIC apex domain this image serves — the go-live target"
    else:
        return ""
    # The "below" reference is only honest while the superdomain row is actually below.
    return head + (" (distinct from the internal superdomain below)." if
                   cluster and superdomain_on_screen else ".")


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


#: An ImageConfig field's declared default — ``core.config.field_default``, imported
#: under this module's historical name rather than reimplemented.
#:
#: This was a byte-identical copy of config's own lookup until 2026-08-26. Three pages
#: had grown one (here, build.py, and role.py via the underscore import), which is one
#: implementation too many for a rule every emission-neutral hide depends on: each hide
#: added on this page resets its field to THIS value, so a page whose idea of "default"
#: drifts from the dataclass's silently starts emitting on a hidden control. The public
#: name landed in core.config for exactly that reason; the alias keeps the ~20 call
#: sites below unchanged.
_field_default = field_default


def _on_off(value) -> bool:
    """A service field's config value -> is the box CHECKED?

    The config domain is unchanged (True/'on' | 'off' | ''/False), because the '' value is
    still what a loaded JSON, a --config channel or a headless caller may carry and
    to_cli_args still honours all three. What changed is how the GUI READS it: '' (and the
    False dataclass default) now shows as UNCHECKED, because on every one of these flags
    the builder's own unset behaviour IS off — the default OPTIONAL_SERVICES set
    (build-x86-host-stage4.sh:141) contains none of them, WANT_AIDE defaults false (:486)
    and EDGE_AI is set true only by the edge_ai role (:1289). So "unspecified" and "off"
    were always the same picture; the square only ever advertised a distinction the
    operator could not act on."""
    return value is True or value == "on"


def _off_value(box):
    """Checked box -> True ('on'); unchecked box -> 'off' (DEFINITELY off).

    Never returns '' — the wizard no longer has a way to say "leave it unspecified",
    which is the whole of asks 1 and 4. See the _OFF_TIP block at the top of this module
    for what 'off' emits per flag and why that is the honest mapping rather than theatre."""
    return True if box.isChecked() else "off"


# Services that have their OWN builder flag as well as (or instead of) a catalogue slug.
#   slug -> (ImageConfig field, does the field use the '' / True / 'off' tri-DOMAIN?)
# The tri-DOMAIN note matters and is not cosmetic: `enable_games` is a plain bool, so
# writing the string "off" into it would emit --enable-games (a non-empty string is
# truthy). Recorded here rather than discovered again.
_FLAG_SERVICE_FIELDS: dict[str, tuple[str, bool]] = {
    "tor": ("tor_onion_service", True),
    "character-studio": ("character_studio", True),
    "character-forge": ("character_forge", True),
    "edge-ai-tts": ("edge_ai_tts", True),
    "games": ("enable_games", False),
}


def _service_channel(slug: str, platform: str, catalog: tuple) -> str:
    """Which builder channel this platform reaches ``slug`` through: ``"flag"``,
    ``"slug"`` or ``""`` (unreachable — the row is hidden and nothing is emitted).

    The dedicated flag wins wherever the builder parses it, because that is what the
    wizard emitted before this redo and keeping it keeps every golden argv intact; the
    catalogue slug is the fallback that makes `tor` reachable on rpi5, whose builder has
    no --with-tor at all. A service reachable BOTH ways emits exactly one of them."""
    fld = _FLAG_SERVICE_FIELDS.get(slug)
    if fld is not None and platform_supports(fld[0], platform):
        return "flag"
    if slug in catalog:
        return "slug"
    return ""


# ── the services TABLE's column grid (ask 23) ────────────────────────────────────────
# "columns as options": the four option columns are the four kinds of answer a service row
# can carry. Index constants rather than literals so inserting a column is one edit, and so
# a test can name the column it reads instead of asserting on a magic number.
#   NAME    — the slug the builders parse (see _svc_row for why it is not prettified)
#   ON      — the two-state checkbox: the whole of asks 1 and 4
#   MODE    — the row's dropdown, where the question has NAMED values rather than on/off
#             (edge-AI runtime; a backing service's self-hosted/managed hosting)
#   SETTING — the row's free field (preload models, default model, hosted endpoint)
#   DESC    — one line saying what ENABLING this row does (ask 5)
_SVC_COL_NAME, _SVC_COL_ON, _SVC_COL_MODE, _SVC_COL_SETTING, _SVC_COL_DESC = range(5)
_SVC_HEADERS = ("Service / app", "On", "Hosting / mode", "Setting",
                "What enabling it does")

# The two table groups that are NOT --optional-services catalogue slugs, and each of which
# used to be a whole page section of its own. Named constants because initializePage hides
# them on their own axes (edge-AI is a cloud/mesh cluster concern; so are the backing
# services) and the tests address them by name.
_AI_GROUP = "AI & inference"
_BACKING_GROUP = "Backing services"

# services_preset indices — the whole-set shortcuts (G13/G14). CUSTOM is the default and
# means "read the table"; the other two REPLACE the table's slug rows entirely.
_PRESET_CUSTOM, _PRESET_NONE, _PRESET_ALL = range(3)

# Hosting dropdown for a backing service. Self-hosted is index 0 == the default, so a fresh
# page emits no --managed-service at all and is byte-identical to before the table landed.
_HOSTING_CHOICES = ("Self-hosted (in-cluster)", "Managed (hosted endpoint)")
_HOSTING_SELF, _HOSTING_MANAGED = range(2)


class NetworkPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        # Set by initializePage; read by validatePage to keep the UNAFFILIATED hide
        # emission-neutral. Seeded here so a collect that somehow precedes a visit cannot
        # AttributeError inside a Qt callback (which under PyQt6 is a qFatal, not a
        # traceback).
        self._services_hidden = False
        self._service_offered: dict[str, bool] = {}
        # The operator's own CUSTOM ticks while a whole-set preset is overriding them
        # (None = we are in CUSTOM and nothing is being held). Seeded here for the same
        # PyQt6 reason as the two above: _preset_changed is a slot.
        self._custom_checked: dict[str, bool] | None = None
        # Title/subtitle are set path-aware in initializePage (a standalone desktop has
        # no mesh/tailnet, so this page IS its network-identity + egress + security step,
        # while cloud/mesh use it for the domain, superdomain and cluster services).
        self.setTitle("Network, identity & egress")
        lay = scrollable(self)

        # There is no tri-state legend any more, and its absence is the fix rather than an
        # omission. The page used to open with a paragraph explaining what a part-checked
        # square meant, because six boxes started in that state; the operator's report
        # ("unchecked instead of half checked for default no") is that a screen needing a
        # paragraph to explain its own checkboxes has the wrong checkboxes. Every box is
        # two-state with a definite default now, so there is nothing left to explain — see
        # the _OFF_TIP block at the top of this module for the per-flag emission mapping
        # that replaced it.

        # ---- Group 1: brand identity & domain (visited in ALL modes) -------------
        # Each group is wrapped in a Collapsible (see _widgets.Collapsible) whose header
        # carries the section title — hence the untitled QGroupBoxes here: the name is
        # set once, on the collapsible() call right after each group is built.
        self.identity_box = QtWidgets.QGroupBox("")
        il = QtWidgets.QVBoxLayout(self.identity_box)
        # Text is COMPOSED per visit in initializePage (_identity_help_text): with the
        # brand rows and the cluster rows now gated on two independent axes, a fixed
        # sentence describes a section that is often not on screen — see defect (2).
        self.identity_help = _hint("")
        il.addWidget(self.identity_help)
        # brand profile (G3): -C/--config brands/*.conf — the sole carrier of the
        # HEADSCALE_URL / RELEASE_STATE / ADMIN_EMAILS / MAIL_* / EXCLUDE_SERVICES
        # presets; sourced by every builder before its CLI flags (CLI wins).
        self.brand_profile = QtWidgets.QLineEdit()
        self.brand_profile.setPlaceholderText("brands/<brand>.conf  (empty = no preset profile)")
        bbtn = _file_picker(self, self.brand_profile, "Brand profile", "Brand profile (*.conf)")
        bw = QtWidgets.QWidget(); bh = QtWidgets.QHBoxLayout(bw); bh.setContentsMargins(0, 0, 0, 0)
        bh.addWidget(self.brand_profile, 1); bh.addWidget(bbtn)
        # EVERY row below is captured on the page, the way self.superdomain_row and
        # self.egress_row already were, because a bare `il.addWidget(_row(...))` throws
        # the caption away: _row() builds a label + widget container, so gating the inner
        # QLineEdit alone leaves "Public apex domain" floating over nothing. The two gates
        # that consume these are BRAND IDENTITY (defect 3) and CLUSTER IDENTITY
        # (defect 1) — two independent axes, hence two tuples rather than one.
        self.brand_profile_row = _row("Brand profile (-C)", bw)
        il.addWidget(self.brand_profile_row)
        self.brand = QtWidgets.QLineEdit()
        self.brand_title = QtWidgets.QLineEdit()
        self.org = QtWidgets.QLineEdit()          # --org (G7): emitted on every platform
        self.domain = QtWidgets.QLineEdit()
        self.brand_row = _row("Brand id", self.brand)
        self.brand_title_row = _row("Brand title", self.brand_title)
        self.org_row = _row("Org", self.org)
        il.addWidget(self.brand_row)
        il.addWidget(self.brand_title_row)
        il.addWidget(self.org_row)
        # --cluster-domain is the PUBLIC apex (the go-live target), distinct from the
        # permanently-internal orchestration superdomain in the mesh control plane below.
        self.domain_row = _row("Public apex domain", self.domain)
        il.addWidget(self.domain_row)
        # games domain (G6, x86+rpi5): the games.<domain> host + games OIDC issuer.
        self.games_domain = QtWidgets.QLineEdit()
        self.games_domain.setPlaceholderText("games.<cluster domain>  (empty = builder default)")
        self.games_domain_row = _row("Games domain", self.games_domain)
        il.addWidget(self.games_domain_row)
        # release state (G4, x86+rpi5): the baked Layer-3 nftables / go-live posture.
        self.release_state = QtWidgets.QComboBox()
        self.release_state.addItems(("default", *RELEASE_STATE_CHOICES))
        self.release_state_row = _row("Release state (--release-state)", self.release_state)
        il.addWidget(self.release_state_row)
        # Identity carries the REQUIRED fields (brand id, the public apex domain), so it
        # is never collapsed by default — default expansion must not hide a must-set field.
        self.identity_section = collapsible("Identity & domain", self.identity_box)
        lay.addWidget(self.identity_section)
        # Shown INSTEAD of the rows this page gates away, and deliberately a PAGE-LEVEL
        # SIBLING of the section rather than a child of identity_box — exactly the
        # tailnet_reason placement, and for exactly the same reason: on a standalone
        # UNAFFILIATED x86 image BOTH axes reject, every row inside the box is hidden,
        # and initializePage hides identity_section itself (the orphan-header rule). A
        # note living inside the section would vanish with it, leaving the operator a
        # wizard that silently lost its brand fields.
        self.identity_reason = QtWidgets.QLabel()
        self.identity_reason.setWordWrap(True)
        self.identity_reason.setStyleSheet("color: gray;")
        self.identity_reason.setVisible(False)
        lay.addWidget(self.identity_reason)

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
        # ASK 8's "this mesh also hosts other domains" CHECKBOX used to sit here, under
        # the superdomain row. ASK 19 promoted that decision to its own choice-card
        # screen (gui/pages/domains_choice.py) in the ModePage idiom — "proceed with the
        # single initial INTERNAL domain, or a button to the table screen for adding
        # domains" — so it is gone from this page entirely. One decision, one place: a
        # checkbox here AND a card there would be two controls for one flag, which is
        # the class of muddle these asks exist to remove. The gate itself is unchanged
        # (cfg.additional_domains -> DomainsPage.applies_to), and the emission guard
        # that makes the skip safe moved with it to that page's validatePage.
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
        # AIDE was the sixth tri-state on this page. It is two-state now like the rest —
        # and unlike tor/character-*/edge-ai-tts its unchecked arm is REAL subtraction
        # (WANT_AIDE is consumed as a plain bool at build-x86-host-stage4.sh:4786 and
        # :5139), so "definitely off" here strips app-forensics/aide outright rather than
        # merely declining to add it. Converted with them because the page cannot keep one
        # lone square without keeping the legend that explains it, and the legend is what
        # the operator was objecting to.
        self.aide = QtWidgets.QCheckBox("AIDE file-integrity IDS (DB baselined at first boot)")
        self.aide.setToolTip(_OFF_TIP)
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
        # ── ASK 23: ONE TABLE FOR SERVICES *AND* APPS ─────────────────────────────────
        # Operator, verbatim: "services as a table ... consolidate services AND apps into a
        # TABLE layout — columns as options, with dropdowns, fields and submenus as makes
        # sense", which SUPERSEDES ask 5 ("redo entire services section") — the earlier,
        # vaguer form of the same complaint.
        #
        # WHAT IT REPLACED. One question — "do I want this service?" — asked in SIX widget
        # idioms spread across THREE separate collapsible page sections:
        #   * four loose 3-state checkboxes (tor / character-studio / character-forge /
        #     edge-ai-tts) inside the Services box;
        #   * a 140px scrolling QListWidget of bare slugs with its own check interaction;
        #   * two mutually-exclusive sentinel checkboxes;
        #   * a free-text subtractive line edit (removed outright — ask 2);
        #   * a whole separate "Edge-AI inference" SECTION with a checkbox, a combo and
        #     three line edits;
        #   * a whole separate "Managed backing services" SECTION of checkbox+endpoint pairs.
        # `character-forge` appeared TWICE on one screen (once as a dedicated-flag box, once
        # as a list row) with nothing saying they were the same service, and no row anywhere
        # said what any of them actually was.
        #
        # WHAT IT IS NOW. ONE QTreeWidget. Rows are services; the COLUMNS are the options
        # (On / Hosting / Setting / What enabling it does); the top-level rows are the
        # GROUPS — a real expander, which is the "submenu" the ask names, rather than a bold
        # label pretending to be one; and a service that has sub-options (Edge-AI) carries
        # them as CHILD rows beneath it, so "runtime", "preload models", "default model" and
        # the analysis API are visibly part of the edge-AI row instead of a page section of
        # their own.
        #
        # WHY A TREE AND NOT QTableWidget: this table needs group bands AND per-service
        # sub-rows. QTableWidget can fake the first with setSpan and cannot do the second at
        # all. QTreeWidget gives both and is still a column grid.
        #
        # WHY NOT THE #507 CHOICE-CARD IDIOM: a choice card is a pick-ONE affordance — one
        # big tappable card per option, exactly one selected; its whole visual grammar says
        # "these are alternatives". Services are INDEPENDENT toggles: a mesh that runs
        # Akkoma does not thereby not run Matrix. Cards would have made fifteen independent
        # yes/no questions look like one fifteen-way choice. The cards ARE right for the
        # pick-one surfaces (ask 14) and deliberately wrong here.
        #
        # GATING NOTE. Everything lives inside `services_box` now, including the
        # dedicated-flag rows that used to be siblings of it. That is safe only because it
        # is provable: gate_widgets("optional_services", services_box) greys the group as a
        # unit on a platform with no --optional-services, and every dedicated flag's
        # platform set is a SUBSET of optional_services' (x86+rpi5) — tor is x86;
        # character_studio / character_forge / edge_ai_tts are x86+rpi5 — so the group grey
        # can never over-grey a box whose own builder would have taken it. Edge-AI and the
        # backing services keep their OWN gate_widgets entries (their platform sets differ)
        # and are greyed per widget rather than by the group.
        # (tests/test_services_section.py::test_group_grey_never_over_greys_a_supported_service.)
        svc_content = QtWidgets.QWidget()
        sv_outer = QtWidgets.QVBoxLayout(svc_content)
        sv_outer.setContentsMargins(0, 0, 0, 0)
        self.services_scope_note = _hint(_SERVICES_SCOPE_NOTE)
        sv_outer.addWidget(self.services_scope_note)
        self.services_node_scope_note = _hint(_SERVICES_NODE_SCOPE_CAVEAT)
        sv_outer.addWidget(self.services_node_scope_note)
        self.services_box = QtWidgets.QGroupBox("Services & apps")
        svl = QtWidgets.QVBoxLayout(self.services_box)
        self.services_override_note = _hint(_SERVICES_OVERRIDE_NOTE)
        svl.addWidget(self.services_override_note)
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

        # The two whole-set shortcuts, as ONE dropdown instead of two checkboxes that had
        # to be kept mutually exclusive by hand. They say something the per-service rows
        # genuinely cannot, which is why they survive the redo at all:
        #   * "none" emits --optional-services "" — ONE click for what the table can also
        #     say the long way round (untick all eight), and the shape the config keeps
        #     either way: validatePage maps an all-unticked table to the same sentinel,
        #     because with the default set arriving ticked "nothing ticked" is an answer
        #     rather than an absence (G13).
        #   * "all" is NOT "tick every row": --all-services expands USER_LEVEL_SERVICES,
        #     which EXCLUDES the infra slugs this catalog also offers (tor, egress-vpn,
        #     anubis, workloadConsole — build-rpi5-stage4.sh:743-744), so the two are not
        #     the same argv (G14). It is also the ONE selection this table cannot express
        #     row-by-row on rpi5, where those infra rows exist.
        # A combo also states the mutual exclusion structurally instead of enforcing it in a
        # slot: three values, one selected, nothing to keep in sync.
        self.services_preset = QtWidgets.QComboBox()
        self.services_preset.addItems([
            "Pick services individually in the table below",
            "No optional services at all — suppress even the builders' default set "
            "(akkoma, tuwunel, phpbb)",
            "Every user-level service — the full catalogue (its rows tick and lock "
            "below; infra services such as tor stay opt-in in the table)",
        ])
        self.services_preset.currentIndexChanged.connect(self._preset_changed)
        svl.addWidget(_row("Selection", self.services_preset))

        self.services_table = QtWidgets.QTreeWidget()
        self.services_table.setColumnCount(len(_SVC_HEADERS))
        self.services_table.setHeaderLabels(list(_SVC_HEADERS))
        self.services_table.setRootIsDecorated(True)
        self.services_table.setAlternatingRowColors(True)
        self.services_table.setUniformRowHeights(False)
        self.services_table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        self.services_table.setMinimumHeight(340)
        _hdr = self.services_table.header()
        _hdr.setStretchLastSection(True)
        for _c in (_SVC_COL_NAME, _SVC_COL_ON, _SVC_COL_MODE, _SVC_COL_SETTING):
            _hdr.setSectionResizeMode(
                _c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        svl.addWidget(self.services_table)

        # ONE row per service, in SERVICE_GROUPS order, keyed by the slug the builders know
        # it as. `service_boxes` is the single registry every later loop reads; `_svc_items`
        # is its row twin (a row is hidden by hiding the ITEM — see initializePage).
        #
        # Which CHANNEL a row emits on is decided per platform at collect time, not by which
        # pile the widget was built in — because for two slugs it genuinely differs per
        # builder, and the old page expressed that by showing the service twice:
        #   * `tor` on x86 is the dedicated --with-tor / --no-tor pair; on rpi5 there is no
        #     such flag at all and listing the slug in --optional-services is the ONLY way to
        #     bake a Tor-onion node (build-rpi5-stage4.sh:746-748, G15);
        #   * `character-studio` / `character-forge` / `games` have BOTH a dedicated flag and
        #     a catalogue slug on x86 and rpi5 — one service, two spellings, which is why the
        #     operator met `character-forge` twice on one screen.
        # See _service_channel() for the rule. One row, right flag, per platform.
        self.service_boxes: dict[str, QtWidgets.QCheckBox] = {}
        self._svc_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self.group_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        for group_title, slugs in SERVICE_GROUPS:
            gitem = self._group_row(group_title)
            for slug in slugs:
                item = self._svc_row(gitem, slug, SERVICE_DESCRIPTIONS.get(slug, ""))
                box = QtWidgets.QCheckBox()
                box.setToolTip(_OFF_TIP)
                self.services_table.setItemWidget(item, _SVC_COL_ON, box)
                self.service_boxes[slug] = box
                self._svc_items[slug] = item
        # Named handles for the services other pages/tests/gates refer to by name. Same
        # widget objects as service_boxes[...] — an alias, never a second checkbox.
        self.tor_onion = self.service_boxes["tor"]
        self.character_studio = self.service_boxes["character-studio"]
        self.character_forge = self.service_boxes["character-forge"]
        self.edge_ai_tts = self.service_boxes["edge-ai-tts"]
        self.games = self.service_boxes["games"]

        # ---- AI & inference: the ex-"Edge-AI inference" SECTION, now a table group ----
        # This is the clearest case for ask 23's "submenus": the service is one yes/no with
        # a runtime (dropdown), a preload list (field) and two sub-options, and it used to
        # be a whole page section for that. The sub-options are CHILD rows of the edge-AI
        # row, so the tree says "these belong to edge-AI" instead of the operator having to
        # infer it from adjacency.
        ai_group = self._group_row(_AI_GROUP)
        self.edge_ai_item = self._svc_row(
            ai_group, "edge-ai",
            "OpenAI-compatible model API served from the GPU node (edge_ai role / be+gpu / "
            "omnibus) to every workload on the mesh.")
        self.edge_ai = QtWidgets.QCheckBox()
        # ASK 1, verbatim: "leave optional services and edge ai unchecked instead of half
        # checked for default no". Two-state, default UNCHECKED — and unchecked here is the
        # load-bearing kind: --no-edge-ai at build-x86-host-stage4.sh:932 is the ONLY way
        # to suppress the edge_ai ROLE's automatic selection of the service.
        self.edge_ai.setToolTip(_OFF_TIP)
        self.services_table.setItemWidget(self.edge_ai_item, _SVC_COL_ON, self.edge_ai)
        self.edge_ai_runtime = QtWidgets.QComboBox()
        self.edge_ai_runtime.addItems(["ollama", "vllm"])
        self.edge_ai_runtime.setToolTip("Model runtime the node serves with (--edge-ai-runtime).")
        self.services_table.setItemWidget(self.edge_ai_item, _SVC_COL_MODE, self.edge_ai_runtime)
        self.edge_ai_models = QtWidgets.QLineEdit()
        self.edge_ai_models.setPlaceholderText(
            "preload: llama3.2:3b,nomic-embed-text  (empty = builder default)")
        self.services_table.setItemWidget(self.edge_ai_item, _SVC_COL_SETTING, self.edge_ai_models)
        _ai_default_item = self._svc_row(
            self.edge_ai_item, "default model",
            "Which preloaded model answers a request that names none.")
        self.edge_ai_default = QtWidgets.QLineEdit()
        self.edge_ai_default.setPlaceholderText("llama3.2:3b  (empty = builder default)")
        self.services_table.setItemWidget(_ai_default_item, _SVC_COL_SETTING, self.edge_ai_default)
        _ai_analysis_item = self._svc_row(
            self.edge_ai_item, "analysis API",
            "Image NSFW/abuse classification + perceptual hashing and log triage "
            "(a separate image on the same node).")
        self.edge_ai_analysis = QtWidgets.QCheckBox()
        self.services_table.setItemWidget(_ai_analysis_item, _SVC_COL_ON, self.edge_ai_analysis)
        # The edge-AI ROW is always on screen — it is one service among the others, which
        # is the whole point of the table. What folds is its SUB-OPTIONS, and that is the
        # surviving half of the old section's "an all-default optional section folds away"
        # rule: collapsed while everything is at its default, opened by
        # _apply_default_expansion the moment anything is not (the edge_ai ROLE
        # auto-checking its own service is the case that matters).
        self.edge_ai_item.setExpanded(False)

        # ---- Backing services: the ex-"Managed backing services" SECTION (I8/M2) ------
        # Per tier-1/2 backing service: a self-hosted(default) / managed DROPDOWN plus an
        # endpoint field live only while 'Managed' is picked. Tier-3 ids are listed
        # read-only with their blocker in the description column (the builder REFUSES a
        # managed swap for them in v1). The dropdown replaces a checkbox labelled
        # "managed" because the question has two NAMED values, which is what a combo is
        # for — the same rule BuildPage states for its own controls.
        backing = self._group_row(_BACKING_GROUP, _MANAGED_SCOPE_NOTE)
        self.managed_rows: dict[str, tuple] = {}
        for sid in MANAGED_SERVICE_TIER12_IDS:
            item = self._svc_row(
                backing, sid,
                "Runs in-cluster unless pointed at a hosted endpoint.")
            combo = QtWidgets.QComboBox()
            combo.addItems(list(_HOSTING_CHOICES))
            ep = QtWidgets.QLineEdit()
            ep.setPlaceholderText("hosted endpoint, e.g. host:port | https://host | aws")
            ep.setEnabled(False)
            combo.currentIndexChanged.connect(
                lambda idx, e=ep: self._hosting_changed(e, idx))
            self.services_table.setItemWidget(item, _SVC_COL_MODE, combo)
            self.services_table.setItemWidget(item, _SVC_COL_SETTING, ep)
            self.managed_rows[sid] = (combo, ep)
        for sid in MANAGED_SERVICE_TIER3_IDS:
            item = self._svc_row(
                backing, sid,
                f"Self-hosted only in v1 — {MANAGED_SERVICE_TIER3_BLOCKER.get(sid, '')}")
            item.setDisabled(True)
        sv_outer.addWidget(self.services_box)
        # EXPANDED by default and not folded away: this section is the one every operator
        # report was about, and the mesh-wide scope answer is only useful on screen.
        self.services_section = collapsible("Services & apps", svc_content)
        lay.addWidget(self.services_section)
        lay.addStretch(1)

    # ---- services-table row builders ---------------------------------------------
    def _group_row(self, title: str, desc: str = "") -> "QtWidgets.QTreeWidgetItem":
        """A top-level GROUP row — the table's "submenu" (a real expander, registered in
        ``group_items`` so initializePage can hide a group whose every child is
        unreachable on this platform)."""
        item = QtWidgets.QTreeWidgetItem(self.services_table)
        item.setText(_SVC_COL_NAME, title)
        item.setText(_SVC_COL_DESC, desc)
        font = item.font(_SVC_COL_NAME)
        font.setBold(True)
        item.setFont(_SVC_COL_NAME, font)
        item.setExpanded(True)
        self.group_items[title] = item
        return item

    def _svc_row(self, parent, name: str, desc: str) -> "QtWidgets.QTreeWidgetItem":
        """One service row: its builder-facing NAME in column 0 and the one line saying
        what enabling it does in the last column (ask 5's "a clear name and a one-line
        description", now a column rather than a run-on label). The name is the slug the
        builders parse, deliberately — it is what docs, brand.conf and --print-plan all
        say, so a prettified display name would only make the two impossible to match up."""
        item = QtWidgets.QTreeWidgetItem(parent)
        item.setText(_SVC_COL_NAME, name)
        item.setText(_SVC_COL_DESC, desc)
        item.setToolTip(_SVC_COL_DESC, desc)
        return item

    def _preset_takes_over(self, slug: str, idx: int) -> bool:
        """Does the whole-set preset `idx` DECIDE this row, leaving the operator no say?

        The rule is builder truth, per preset, and it is NOT "the slug channel" — that was
        the bug:

        * NONE emits ``--optional-services ""``. It rewrites the slug list and nothing
          else, so a service this platform reaches through its own ``--with-<x>`` stays
          live underneath it: the fold at build-x86-host-stage4.sh:1166 runs AFTER the arg
          loop, so ``--optional-services "" --with-character-studio`` really does build
          character-studio alone. Only SLUG-channel rows are taken over.
        * ALL emits ``--all-services``, which at build-x86-host-stage4.sh:1106-1111
          replaces OPTIONAL_SERVICES with USER_LEVEL_SERVICES **before** those folds. So it
          takes over TWO kinds of row:
            - every slug-channel row (the list is replaced wholesale — an rpi5 `anubis`
              tick is discarded by the sentinel and anubis is NOT built), and
            - every row whose slug is in USER_LEVEL_SERVICES **whatever its channel**,
              because the expansion bakes the slug and the dedicated flag cannot take it
              back out: --no-character-studio / --no-character-forge only SKIP a fold-in
              (:1166-1171, :1182-1187 are `if [ "${WANT_…}" = "true" ]` with no false arm),
              and `games` has no --no- flag at all.
          What it does NOT take over is a flag-channel row outside that set — `tor` on x86
          and `edge-ai-tts` — which is the (true) half of the claim this method's
          predecessor generalised from and got wrong for the other three.
        """
        if idx == _PRESET_CUSTOM:
            return False
        if self._channel(slug) == "slug":
            return True
        return idx == _PRESET_ALL and slug in USER_LEVEL_SERVICES

    def _preset_changed(self, idx):
        """Show, on the rows themselves, exactly what the whole-set preset builds.

        A row the preset decides is set to the state the preset PRODUCES and greyed; a row
        it leaves alone stays live. Before this, only the slug rows greyed and the
        dedicated-flag rows sat enabled-and-unchecked underneath ``--all-services``, so
        `games`, `character-studio` and `character-forge` read OFF (and emitted
        ``--no-…``) while the build baked all three — the operator's own complaint,
        inverted. See _preset_takes_over for the per-preset rule.

        The operator's CUSTOM ticks are saved on the way in and restored on the way back,
        so glancing at "every user-level service" and changing your mind cannot silently
        rewrite a selection you made by hand.

        "All except one" is still expressible — in the TABLE, not here: with the builders'
        default set pre-ticked, ticking the seven you want emits them as an explicit
        allow-list (--optional-services REPLACES, it does not add). The preset is the
        shortcut; the table is the fine grain.

        PyQt6 SAFETY: this is a `currentIndexChanged` SLOT. An exception escaping a slot
        under PyQt6 calls qFatal and takes the whole Studio down (PySide6 merely prints
        it), so the body is wrapped — the worst outcome of a bad state here must be a stale
        grey, not a dead wizard."""
        try:
            if idx == _PRESET_CUSTOM:
                saved, self._custom_checked = self._custom_checked, None
                for slug, box in self.service_boxes.items():
                    if saved is not None and slug in saved:
                        box.setChecked(saved[slug])
                    box.setEnabled(True)
                return
            # Snapshot ONCE per departure from CUSTOM: flipping none->all must not
            # overwrite the operator's ticks with the previous preset's forced state.
            if self._custom_checked is None:
                self._custom_checked = {s: b.isChecked()
                                        for s, b in self.service_boxes.items()}
            for slug, box in self.service_boxes.items():
                if not self._preset_takes_over(slug, idx):
                    box.setEnabled(True)
                    continue
                box.setChecked(idx == _PRESET_ALL and slug in USER_LEVEL_SERVICES)
                box.setEnabled(False)
        except Exception:            # noqa: BLE001 — see the PyQt6 note above
            pass

    def _hosting_changed(self, ep, idx):
        """Endpoint field is live only while this backing service is 'Managed'.

        Deliberately does NOT clear the text: an operator who flips back and forth must not
        lose a typed endpoint, and validatePage already drops a self-hosted row's endpoint
        from the collected dict, so a stale string cannot reach the argv.

        PyQt6 SAFETY: `currentIndexChanged` SLOT — see _preset_changed."""
        try:
            ep.setEnabled(idx == _HOSTING_MANAGED)
        except Exception:            # noqa: BLE001
            pass

    def _channel(self, slug: str) -> str:
        """``_service_channel`` for the CURRENT config (flag | slug | unreachable)."""
        c = self.wiz.cfg
        catalog = tuple(OPTIONAL_SERVICES_BY_PLATFORM.get(c.platform or "x86", ()))
        return _service_channel(slug, c.platform, catalog)

    def initializePage(self):
        c = self.wiz.cfg
        # UNAFFILIATED, computed FIRST because three surfaces below need the same answer
        # and one spelling of the flag is itself part of the operator's ask (it used to be
        # recomputed inline at the services gate). Both routes count: the dedicated ROLE
        # id and the composable --unaffiliated flag on any client role (config.py
        # _x86_args, G22) — _check_unaffiliated_conflicts refuses a brand identity for
        # either, so a gate that knew only the role id would have left the flag path
        # inviting an entry the builder then rejects.
        unaffiliated = (c.role == UNAFFILIATED_ROLE or getattr(c, "unaffiliated", False))
        # Path-aware header (spec 3-7): a standalone desktop has no mesh/tailnet, so this
        # page IS its network-identity / egress / security step; cloud/mesh use it for the
        # domain, the orchestration superdomain and the cluster services.
        if c.mode == "standalone":
            self.setTitle("Network identity, egress & security")
            # …and on an unaffiliated image it is not a BRAND identity step either: the
            # brand rows are gated away below (defect 3), so a subtitle promising "Brand
            # identity" would describe a section this visit does not have — the same
            # orphan-prose defect as the identity help line (defect 2), one level up.
            self.setSubTitle(
                ("The optional egress VPN and the host security stack for this "
                 "unaffiliated desktop. No brand, no mesh, no tailnet, no SSO."
                 if unaffiliated else
                 "Brand identity, the optional egress VPN and the host security "
                 "stack for this standalone desktop. No mesh, no tailnet, no SSO."))
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
        # Two-state now (asks 1/4). Unsupported platform still shows UNCHECKED — which is
        # no longer a special case, because unchecked and "the builder would not do it
        # anyway" have become the same picture; gate_widgets below greys it and
        # validatePage clears the field regardless.
        self.aide.setChecked(_on_off(c.aide)
                             and platform_supports("aide", c.platform))
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
        # ── DEFECT 1: the "inbetween menu for configuring domain" ───────────────────
        # The three rows are HIDDEN (not greyed) when this image bakes no cluster plane —
        # the spec's treatment for a surface that is inapplicable rather than
        # unsupported, and the same call shape the egress row and the home group use.
        # Re-run on EVERY visit, so an image that becomes cloud/mesh (or moves to an ARM
        # platform) on an earlier page gets the rows — and their emission — straight back.
        # See _cluster_identity_applies for why the predicate is platform-scoped.
        cluster_ok = _cluster_identity_applies(c)
        gate_widgets_role_class(
            [self.domain_row, self.games_domain_row, self.release_state_row],
            cluster_ok, _CLUSTER_IDENTITY_NOTE, hide=True)
        # ── DEFECT 3: the brand trio hard-blocks an UNAFFILIATED build ──────────────
        # Measured before this landed (standalone / standalone-unaffiliated / x86): the
        # whole identity section was visible+enabled with brand='hugmesh',
        # org='hugmesh', domain='hugmesh.net'. Type anything into Brand id / Brand title
        # / Org and cfg.to_cli_args() raises ValueError out of
        # core/config.py::_check_unaffiliated_conflicts — the wizard was inviting an
        # entry that then REFUSES to build. build-x86-host-stage4.sh exits non-zero on
        # the same flags, so this is the builder's contract, not a Studio preference.
        # The brand profile (-C) goes with them: brands/*.conf is a brand identity in a
        # file, and _brand_args emits --config from it.
        #
        # `unaffiliated` is computed ONCE at the top of this method (it used to be
        # recomputed inline at the services gate) — the page subtitle, this gate and the
        # services gate are three readings of one flag, not three rules.
        brand_ok = not unaffiliated
        gate_widgets_role_class(
            [self.brand_profile_row, self.brand_row, self.brand_title_row, self.org_row],
            brand_ok, _BRAND_IDENTITY_NOTE, hide=True)
        # ── DEFECT 2: the orphan help text ─────────────────────────────────────────
        # Path-aware, exactly as tailnet_reason is: the sentence named the superdomain
        # "below", which lives in mesh_box and is on screen only for cloud/mesh
        # (show_cp, computed above) — so every standalone visit pointed at a control
        # that was not there. Composed from what the section still HOLDS.
        self.identity_help.setText(_identity_help_text(brand_ok, cluster_ok, show_cp))
        self.identity_help.setVisible(bool(self.identity_help.text()))
        # Hide the SECTION when both axes reject, or the page keeps a bold
        # "Identity & domain" header over an empty body — the orphan-header rule the
        # tailnet and egress sections already follow (and which
        # test_mode_gated_sections_hide_their_header_too pins). On a standalone
        # unaffiliated x86 image that is exactly the state: every row inside is hidden.
        self.identity_section.setVisible(brand_ok or cluster_ok)
        # …and say WHY, page-level so it survives the section's own hide. One label, two
        # independent causes, joined only when both fired.
        reasons = ([_BRAND_IDENTITY_NOTE] if not brand_ok else []) + \
                  ([_CLUSTER_IDENTITY_NOTE] if not cluster_ok else [])
        self.identity_reason.setText("  ".join(reasons))
        self.identity_reason.setVisible(bool(reasons))
        self.egress.setText(c.egress_vpn)
        self.egress_locked.setChecked(c.egress_vpn_locked)
        # same rule for the edge_ai role's auto-check (G11: jetson greys out too)
        edge_on = _on_off(c.edge_ai_service)
        if c.role == "edge_ai":
            edge_on = True                          # the role auto-selects the service
        if not platform_supports("edge_ai_service", c.platform):
            edge_on = False
        self.edge_ai.setChecked(edge_on)
        self.edge_ai_runtime.setCurrentText(c.edge_ai_runtime or "ollama")
        self.edge_ai_models.setText(c.edge_ai_models)
        self.edge_ai_default.setText(c.edge_ai_model_default)
        self.edge_ai_analysis.setChecked(c.edge_ai_analysis)
        # edge-AI is a GPU CLUSTER service — only meaningful for cloud/mesh node builds.
        # The gate now hides the table's AI GROUP ROW, which takes the edge-AI row and its
        # two child rows with it. Hiding the ROW rather than the widgets is what keeps
        # "inapplicable" and "collapsed" distinguishable now that the section is gone: a
        # collapsed GROUP still shows its header row, a gated one is not in the table at
        # all. The widgets keep their values either way, so the gate changes no emission
        # (validatePage reads values, and clear_unsupported keys on the capability table).
        self.group_items[_AI_GROUP].setHidden(c.mode not in ("cloud", "mesh"))
        # ── the service rows ────────────────────────────────────────────────────────
        # ONE pass over service_boxes, seeding each row from whichever channel this
        # platform reaches it through. G15 lives here now instead of in a rebuilt list
        # widget: rpi5 has no --with-tor, so `tor` seeds from the optional_services SLUG
        # list there and from tor_onion_service on x86 — one row either way.
        # ── the picker's HIDE, decided ONCE and decided HERE ────────────────────────
        # Computed before the seeding below rather than beside the setVisible() calls it
        # drives, because the un-hide has to undo the sentinel BEFORE `picked` and
        # `seed_builtin_defaults` are read off the config — the seeder is what turns
        # cfg.optional_services into ticked boxes, and it runs first.
        #
        # Both arms hide the whole cluster-services picker: an unaffiliated image (no
        # HugMesh plane at all) and a standalone CLIENT-class desktop (no cluster GitOps
        # tree is baked, so a selection here is accepted and ignored). `_client_class_role`
        # — not a mode test — is what keeps standalone rpi5 'generic' OUT of the hide:
        # generic is cluster-node class and DOES bake the tree (G16).
        hide_services = (
            (c.role == UNAFFILIATED_ROLE or getattr(c, "unaffiliated", False))
            or (c.mode == "standalone"
                and platform_supports("optional_services", c.platform)
                and _client_class_role(c.role, c.platform)))
        # THE HIDE IS NOT ONE-WAY. validatePage writes the [SERVICES_NONE] sentinel while
        # the picker is hidden (that is the D6 fix — emitting NOTHING would hand the
        # selection to whatever OPTIONAL_SERVICES a brand.conf carries). But the seeder
        # below reads that sentinel back at face value as an operator decision, so without
        # this it rides OUT of the standalone flow into the next one. Measured, with the
        # operator never touching the services picker — they just walked the default path:
        #     standalone-thick -> Back to Mode -> cloud desktop
        #         --optional-services            (was: akkoma tuwunel phpbb)
        #     standalone-thick -> Back to Mode -> mesh omnibus
        #         --optional-services            (was: akkoma tuwunel phpbb)
        # An untouched [] round-trips; the ["none"] the HIDE wrote did not.
        #
        # Provenance is PAGE state, not a cfg field, on purpose: the sentinel is a correct
        # and persistable answer FOR A STANDALONE IMAGE, so it must survive save/load. What
        # must not survive is INHERITING it into a flow that never hid the picker.
        if hide_services:
            self._services_none_is_ours = True
        elif (getattr(self, "_services_none_is_ours", False)
              and c.optional_services == [SERVICES_NONE]):
            # Back on screen carrying OUR answer: drop it so `seed_builtin_defaults` below
            # re-ticks BUILTIN_DEFAULT_SERVICES exactly as it does for a never-hidden flow.
            # Cleared after one use — a none the operator picks from the VISIBLE picker on
            # a later visit is theirs, and must round-trip untouched.
            c.optional_services = []
            self._services_none_is_ours = False
        else:
            self._services_none_is_ours = False
        catalog = tuple(OPTIONAL_SERVICES_BY_PLATFORM.get(c.platform or "x86", ()))
        picked = [s for s in c.optional_services if s not in (SERVICES_NONE, SERVICES_ALL)]
        # ── the builders' OWN default set arrives TICKED ──────────────────────────────
        # Ask 23's rule, verbatim: "anything off by default is UNCHECKED; only pre-check
        # what is genuinely on by default" — and akkoma / tuwunel / phpbb are genuinely on
        # by default. `OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"`
        # (build-x86-host-stage4.sh:141, build-rpi5-stage4.sh:245) means an untouched mesh
        # ships all three, so three unticked boxes over three running services is the same
        # lie as a part-checked square, merely spelled differently — and it made unticking
        # `phpbb` a no-op, because --optional-services REPLACES rather than subtracts, so
        # "nothing ticked" emitted nothing and left the forum up.
        #
        # Seeded ONLY when the config carries no selection of its own ([] — the "never been
        # chosen" state). An explicit [none]/[all]/[slug,…] is the operator's answer and is
        # shown as-is.
        #
        # THIS CHANGES THE ARGV of an untouched mesh flow, on purpose, and it is worth
        # saying exactly how far: a default build now emits
        # `--optional-services "akkoma tuwunel phpbb"` where it emitted nothing. Same three
        # services, byte-identical image — EXCEPT when a brand profile (-C) sets its own
        # OPTIONAL_SERVICES, which the explicit flag now overrides (built-in < brand.conf <
        # flag). That is the same trade this page already makes for --no-tor and states in
        # _OFF_TIP: the box beats the brand profile, because a box that a profile can
        # silently contradict is the ambiguity the whole redo was asked to remove.
        seed_builtin_defaults = not c.optional_services
        # Which rows this flow actually OFFERS. validatePage collects exactly these and
        # leaves the rest at their dataclass defaults — the hiding-must-not-change-the-
        # build rule, which two-state boxes make sharper than tri-state ones did: an
        # unoffered row left "unchecked" would now collect "off" and put a --no-<x> on the
        # argv for a decision the operator was never shown.
        self._service_offered: dict[str, bool] = {}
        for slug, box in self.service_boxes.items():
            channel = _service_channel(slug, c.platform, catalog)
            offered = bool(channel)
            # Tor's x86 dedicated flag is a k8s-NODE service — only meaningful on a
            # cloud/mesh cluster build. The mode gate rides the FLAG channel only: on rpi5
            # there is no --with-tor and `tor` is an ordinary catalogue slug, which
            # standalone rpi5 'generic' legitimately reaches (G16 — it is the one
            # standalone role that DOES bake a cluster GitOps tree). Gating the slug too
            # was the first cut and it hid the only way to build a Tor-onion Pi node.
            if slug == "tor" and channel == "flag" and c.mode not in ("cloud", "mesh"):
                offered = False
            if channel == "flag":
                fld, tri = _FLAG_SERVICE_FIELDS[slug]
                value = getattr(c, fld)
                box.setChecked(offered and (_on_off(value) if tri else bool(value)))
            elif channel == "slug":
                box.setChecked(slug in picked
                               or (seed_builtin_defaults
                                   and slug in BUILTIN_DEFAULT_SERVICES))
            else:
                box.setChecked(False)
            # A service this builder cannot express at all is HIDDEN, not greyed: there is
            # no flag to explain, and gate_widgets' "cleared when you leave the page"
            # tooltip would be describing a control that never had a value. The rows the
            # builder DOES parse but the role makes pointless keep their grey + note.
            #
            # Hide the ROW, not the checkbox. In a QTreeWidget the checkbox is an ITEM
            # WIDGET the view positions inside a cell, so hiding it alone would leave an
            # empty row with a name and a description and no way to act on it — and
            # setVisible(True) on a widget whose row is hidden is a stale-geometry bug
            # waiting to happen. setHidden on the item takes the whole line with it.
            self._svc_items[slug].setHidden(not offered)
            self._service_offered[slug] = offered
        # A group whose every row is unreachable on this platform loses its header too,
        # or the section shows a bold "Network & access" over nothing (the orphan-header
        # lesson the egress section already learned). Reads the flags we just computed,
        # NOT isVisible() — a widget on a non-current QWizardPage reports isVisible()
        # False regardless of its own flag, which would have collapsed every header the
        # moment the page was built rather than shown.
        for group_title, slugs in SERVICE_GROUPS:
            self.group_items[group_title].setHidden(
                not any(self._service_offered.get(s) for s in slugs))
        if c.optional_services == [SERVICES_NONE]:
            preset = _PRESET_NONE
        elif SERVICES_ALL in c.optional_services:
            preset = _PRESET_ALL
        else:
            preset = _PRESET_CUSTOM
        self.services_preset.setCurrentIndex(preset)
        # setCurrentIndex only emits currentIndexChanged when the index actually MOVES, so
        # the grey has to be applied unconditionally — otherwise a revisit that lands on the
        # same preset leaves the slug rows in whatever enabled-ness the last visit left.
        self._preset_changed(preset)
        # Forget any held-back CUSTOM ticks, AFTER the preset ran — deliberately after,
        # and it is the difference between two behaviours:
        #   * held ticks from the PREVIOUS visit are stale (the rows were just re-seeded
        #     from the config) and must not be restored over the fresh seed;
        #   * a page ARRIVING on a whole-set preset has nothing of the operator's to hold,
        #     so switching to "pick individually" should hand them the rows exactly as the
        #     preset left them — all eight ticked and now editable, which is how "all
        #     except the forge" is reached in one untick. Resetting BEFORE the call instead
        #     would snapshot the pre-forced (empty) state and blank the table on that
        #     switch, i.e. turn a fine-tuning gesture into "no services at all".
        self._custom_checked = None
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
        # …and on an image with no cluster to serve, HIDE the picker outright rather
        # than merely captioning it. Two roles reach that state, and the first one has
        # been here since the earlier report ("the unaffiliated desktop image wizard
        # still shows options like mesh services and branding and login when it
        # shouldn't"):
        #
        #   * UNAFFILIATED — the role exists to bake ZERO HugMesh affiliation, and
        #     cluster services are the platform machinery it is defined by NOT having.
        #     (`unaffiliated` is computed ONCE, at the top of this method with the brand
        #     gate — one spelling of the flag, which is itself part of the operator's ask.)
        #   * DEFECT 4, new: EVERY standalone CLIENT-class role. Measured on
        #     standalone / standalone-thick / x86 before this landed: the nine-row picker
        #     was live with akkoma/tuwunel/phpbb PRE-TICKED, and the argv the wizard
        #     produced really carried `--optional-services akkoma tuwunel phpbb` — for a
        #     role whose build PLAN reports the selection as NONE
        #     (build-x86-host-stage4.sh:2054,
        #     `_plan OPTIONAL_SERVICES "$(${ROLE_CLIENT} && echo none || …)"`), on an
        #     image that gets no cluster GitOps tree at all — the
        #     `cp -r "${SHARED_SPECS}/cluster" "${SYSROOT}/var/lib/hugmesh/cluster"` at
        #     :4621 sits in the non-client arm, whose own comment reads "a client is a
        #     desktop, not a node" (:4591). Nine rows of a choice that cannot mean
        #     anything, and three of them pre-ticked.
        #
        # THE HIDE STAYS — WHAT IT EMITS IS NOT "NOTHING" (DEFECT 6, the regression this
        # replaced). The first cut of this hide dropped --optional-services AND the
        # --no-<x> definitely-offs from every standalone client argv, and justified it
        # with a proof that is FALSE. It claimed the builder performs the client-role
        # override itself at :1130 / :1146 / :1162 / :1178 / :1214. Those five guards
        # exist and read as advertised — but every one of them tests ${ROLE_CLIENT} while
        # it is still FALSE:
        #     :92   ROLE_CLIENT=false   EARLY bound default, whose own comment says "the
        #                               opt-in guards for --with-tor /
        #                               --with-character-studio / --with-edge-ai-tts run
        #                               BEFORE that derivation"
        #     :1259 ROLE_CLIENT=false   re-set, immediately above `case "${ROLE}" in`
        #     :1299/:1302/:1318/:1328/:1338  ROLE_CLIENT=true — INSIDE that role case
        #                               (laptop|chromebook / desktop / standalone-thin /
        #                               standalone-thick|full / standalone-unaffiliated)
        #     :1438 ROLE_CLIENT=true    the composable --standalone fold, later still
        # All five guards sit at :1130-:1214, i.e. BEFORE :1259. Demonstrated — the
        # override never fires, and not one "has no effect" warning is printed:
        #     ./build-x86-host-stage4.sh --role standalone-thick --with-tor \
        #         --with-character-studio --with-edge-ai-tts --print-plan
        #     -> PLAN_OPTIONAL_SERVICES=none, zero warnings
        # PLAN_OPTIONAL_SERVICES is a DISPLAY (`${ROLE_CLIENT} && echo none || …`, :2054)
        # computed after the role case; the variable the BUILD reads is untouched by the
        # role. Measured on a node role, which unmasks the same resolution because the
        # folds never see ROLE_CLIENT true either way — brand profile b.conf holding
        # OPTIONAL_SERVICES="akkoma tor":
        #     --config b.conf                           -> akkoma tor
        #     --config b.conf --optional-services ""    -> none
        # and b2.conf holding WANT_TOR=true / WANT_CHARACTER_STUDIO=true instead:
        #     --config b2.conf                          -> …phpbb tor character-studio
        #     --config b2.conf --optional-services ""    -> tor character-studio
        #     --config b2.conf --optional-services ""
        #                      --no-tor --no-character-studio  -> none
        # so BOTH channels have to be answered: the allow-list AND the per-service
        # definitely-offs. And `tor` is not academic — the PKGS line
        # `_opt_selected tor && PKGS="${PKGS} net-vpn/tor"` (:5134) carries NO ROLE_CLIENT
        # guard, unlike its runlevel neighbour at :4833, so a leaked slug really does
        # emerge net-vpn/tor into a standalone desktop image that never carried it.
        #
        # SO THE HIDE CLEARS THE PICKER TO ITS "NO SERVICES" STATE AND validatePage
        # COLLECTS THAT, exactly as if the operator had unticked every row by hand:
        # --optional-services "" plus the --no-<x> of every row the builder can express
        # here. That is this page's OWN established trade, already stated above for the
        # pre-ticked default set — "the box beats the brand profile, because a box that a
        # profile can silently contradict is the ambiguity the whole redo was asked to
        # remove". A hidden box has an answer too, and its answer is none. Absent a
        # profile the added tokens are provably inert (measured, node role):
        #     --no-tor --no-character-studio --no-character-forge --no-edge-ai-tts
        #     -> akkoma tuwunel phpbb, byte-identical to emitting none of them
        # `--no-edge-ai` is untouched by any of this: the edge-AI widgets are not rows of
        # this table (the AI GROUP row carries its own mode gate), and its unchecked arm
        # is real subtraction on every build.
        #
        # ONE ANSWER FOR BOTH ARMS, and it is measured rather than symmetry for its own
        # sake. The unaffiliated arm emits no --config at all (validatePage clears
        # brand_profile — DEFECT 3), so it looks immune. It is not: the builder
        # auto-detects `$(pwd)/brand.conf` whenever no -C is given (:884), and Studio runs
        # the builder with cwd=generator_dir (core/build_driver.py, _spawn) — the very
        # directory brand.conf.example ships in. Measured from a directory holding that
        # same profile:
        #     --role standalone-unaffiliated                        -> akkoma tor
        #     --role standalone-unaffiliated --optional-services ""  -> none  (exit 0)
        # An unaffiliated image silently emerging net-vpn/tor is the exact inverse of the
        # role's definition, so this arm needs the explicit answer at least as much as the
        # branded one — hence one rule, not two.
        #
        # KNOWN RESIDUE, stated rather than papered over: `games` is a flag row whose OFF
        # arm has no builder flag to emit (there is no --no-games; ENABLE_GAMES=true in a
        # profile folds `games` in at :1117-1122 and nothing on the Studio side can
        # override it). That gap predates this change set and hits the VISIBLE picker on
        # cloud/mesh identically, so it is a builder ask, not something this hide can close.
        #
        # WHY `standalone AND client`, NOT `client` ALONE. The CLOUD desktop path is
        # deliberately left exactly as it was: a branded cloud client can legitimately be
        # re-rolled as a node later, so there the heads-up note above is the honest
        # treatment — the flags ARE parsed, they just do nothing on today's role. A
        # standalone image has no mesh to be re-rolled into; the cluster is not "not
        # yet", it is absent.
        #
        # And `_client_class_role` — not a mode test — is what keeps standalone rpi5
        # 'generic' OUT of this hide: generic is cluster-node class and DOES bake the
        # tree (G16), which is the whole reason that helper exists.
        #
        # Re-gated on EVERY visit, and the clear below is what validatePage then collects.
        # `hide_services` was decided (and its sentinel reconciled) ABOVE THE SEEDER — see
        # "the picker's HIDE, decided ONCE" for why it cannot be computed here. `client`
        # and `unaffiliated` above are the same two terms, recomputed for the notes; this
        # block reads the hoisted decision so the rule has exactly ONE implementation.
        #
        # No assert restating that equality: an exception escaping initializePage is a
        # qFatal under the PyQt6 the operator runs (the venv is PySide6, so a test run
        # would never show it), and a duplicated predicate is the thing being avoided, not
        # a thing to check twice.
        if hide_services:
            # Clear to the "no services" state — the NONE preset, not CUSTOM. The widget
            # state has to MATCH the emission (--optional-services "" plus the unticked
            # rows' --no-<x>), or a later un-hide on the same wizard — Back, switch to a
            # cloud client — would re-seed the picker from a config that says one thing
            # while the argv said another. _PRESET_NONE also makes the emission
            # independent of the CUSTOM/`slug_rows_offered` fallback in validatePage,
            # which is bookkeeping rather than an answer.
            #
            # This REPLACES the earlier "clear to the UNSET state, never to the
            # SERVICES_NONE sentinel" rule, which read hiding-must-not-change-the-build as
            # hiding-must-emit-nothing. Emitting nothing is not neutral here: it hands the
            # selection to whatever OPTIONAL_SERVICES a brand.conf happens to carry (see
            # the measurements above). The house rule is that the ARGV must not change for
            # a config the operator did not touch, and absent a profile these tokens are
            # measurably byte-identical to emitting none of them.
            self.services_preset.setCurrentIndex(_PRESET_NONE)
            for box in self.service_boxes.values():
                box.setChecked(False)
            self.services_role_note.setVisible(False)
        # ── DEFECT 5: the ORPHAN SERVICES HEADER ───────────────────────────────────
        # services_scope_note and services_node_scope_note sit in `svc_content`, OUTSIDE
        # services_box, and it is svc_content that the collapsible wraps. Hiding only the
        # box therefore left an unaffiliated run with the "Services & apps" header and
        # two paragraphs of mesh-wide prose ("Chosen ONCE for the whole mesh…", "tor and
        # egress-vpn are node-scoped…") over nothing. Hide the SECTION — the house rule,
        # and the idiom the tailnet and egress sections already use.
        #
        # setVisible on BOTH, not just the section: every existing gate assertion is
        # written against services_box (and gate_widgets still greys that box per
        # platform), so the box keeps carrying the answer to "is the picker on screen".
        self.services_box.setVisible(not hide_services)
        self.services_section.setVisible(not hide_services)
        # Remembered on the page so validatePage knows the picker's answer was SETTLED
        # rather than merely left at its defaults: it collects the cleared rows (every
        # definitely-off the builder parses here) and writes the explicit-none sentinel,
        # instead of reading a screen the operator never saw. Kept as page state rather
        # than recomputed there because it is the ONE place the hide is decided.
        self._services_hidden = hide_services
        # …and remember that WE authored any explicit-none now in the config, so an
        # un-hide can undo it. Without this the hide is ONE-WAY: validatePage writes the
        # [SERVICES_NONE] sentinel, the seeder above reads it back at face value as an
        # operator decision (`if c.optional_services == [SERVICES_NONE]: preset =
        # _PRESET_NONE`, which runs BEFORE this gate), and it rides out of the standalone
        # flow into the next one. Measured, before this flag existed — the operator never
        # touched the services picker, they just walked the default path:
        #     standalone-thick -> Back to Mode -> cloud desktop
        #         --optional-services            (was: akkoma tuwunel phpbb)
        #     standalone-thick -> Back to Mode -> mesh omnibus
        #         --optional-services            (was: akkoma tuwunel phpbb)
        # An untouched `[]` round-trips; the `["none"]` the HIDE wrote did not. Page state
        # rather than a cfg field on purpose: the sentinel is a correct, persistable answer
        # FOR A STANDALONE IMAGE (that is the D6 fix), so it must survive save/load — what
        # must not survive is inheriting it into a flow that never hid the picker.
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
            # Edge-AI and the backing services lost their group BOXES to the table, so
            # their platform gate now names the widgets directly (gate_widgets takes a
            # tuple). Same grey, same tooltip, same clear_unsupported partner in
            # validatePage — only the carrier changed. It must NOT be folded into the
            # services_box entry above: edge_ai_service is x86-ONLY while optional_services
            # is x86+rpi5, so the group grey would under-grey edge-AI on an rpi5 mesh.
            "edge_ai_service": (self.edge_ai, self.edge_ai_runtime, self.edge_ai_models,
                                self.edge_ai_default, self.edge_ai_analysis),
            # NO per-field entries for tor / character-studio / character-forge /
            # edge-ai-tts / games any more, and their absence is a BUG FIX, not an
            # oversight. Each of those rows is reachable through TWO channels and
            # _service_channel picks per platform; a gate keyed on the DEDICATED FLAG
            # therefore greyed the row wherever only the SLUG channel exists. `tor` on
            # rpi5 is exactly that case — tor_onion_service is x86-only, so the flag gate
            # greyed the rpi5 tor row, which is the ONLY way to bake a Tor-onion Pi node
            # (build-rpi5-stage4.sh:746-748, G15). Probe, before this line went:
            #     mesh/pki/rpi5   tor  ON=_/dis      <- greyed, unbuildable
            #     mesh/pki/rpi5   tor  ON=_          <- after
            # The row-level `offered` flag computed above already covers everything this
            # gate was for and is CHANNEL-AWARE: an unreachable row is hidden outright,
            # and a row that is offered is by construction emittable on this platform
            # (_service_channel only returns a channel the builder parses). validatePage's
            # clear_unsupported still resets every one of these fields per platform, so
            # nothing stale can reach the argv either way.
            # (tests/test_pages_identity.py::test_rpi5_tor_row_is_live_not_greyed.)
            "optional_services": self.services_box,
            "managed_services": tuple(
                w for row in self.managed_rows.values() for w in row),
        })
        # Managed backing services (I8/M2): a cluster concern — shown for cloud/mesh
        # builds (a standalone desktop bakes no cluster tree), platform-gated to x86/rpi5
        # by gate_widgets above. Populate each tier-1/2 row from cfg.managed_services;
        # an id present => Managed with its endpoint, else Self-hosted (index 0, default).
        self.group_items[_BACKING_GROUP].setHidden(c.mode not in ("cloud", "mesh"))
        for sid, (combo, ep) in self.managed_rows.items():
            endpoint = c.managed_services.get(sid, "")
            combo.setCurrentIndex(_HOSTING_MANAGED if endpoint else _HOSTING_SELF)
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
        #
        # ASK 3 ("options for standalone desktops shouldnt appear in the mesh wizard"):
        # scope_allows_FLOW, not scope_allows. The old base-keyed call read
        # image_class(cfg.mode, cfg.role) off a base whose role WorklistPage had stamped
        # from entries[0] — so a mesh worklist whose first checked row happened to be
        # rpi5-desktop or jetson-desktop put the egress row back on every node in it.
        egress_ok = scope_allows_flow("egress_vpn", c, self.wiz)
        gate_widgets_role_class([self.egress_row, self.egress_locked], egress_ok,
                                out_of_scope_note_flow("egress_vpn", c, self.wiz), hide=True)
        # Fold the whole SECTION away with its content: the gate above hides the field
        # and the lock box, but _row()'s "Egress VPN" caption and this section's header
        # are not gate members, so a node-class image was left with an Egress VPN header
        # over an empty body. (The orphan caption predates the sections; hiding the
        # section takes it with it.) The gate still drives the widgets themselves, so
        # every existing egress gate assertion keeps its meaning.
        self.egress_section.setVisible(egress_ok)
        # gate_widgets blanks the tooltip on every ENABLED widget — restore the
        # definite-off explanation on the live service boxes (disabled ones keep the
        # unsupported-platform note it set).
        for w in (self.aide, self.edge_ai, *self.service_boxes.values()):
            if w.isEnabled():
                w.setToolTip(_OFF_TIP)
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

        A section is force-expanded when it holds something the operator should see: a
        non-default value, or a greyed control whose gate note explains itself. The
        sections carrying required or must-set fields (identity, mesh/superdomain) and
        the ones the reports were about (services) are never collapsed by default."""
        # Compared against ImageConfig's OWN declared defaults, never against restated
        # literals: `snort` for instance defaults to True, so a hand-written "snort is
        # off when default" would fold the section away on a config that had actually
        # overridden it to off. _field_default() cannot drift from the dataclass.
        sec_default = (self.proxy_stack.currentText() == _field_default("proxy_stack")
                       and self.snort.isChecked() == _field_default("snort")
                       and self.aide.isChecked() == _on_off(_field_default("aide"))
                       and self.root_login.currentText() == _field_default("root_login"))
        # A greyed control means a gate note the operator should be able to read.
        sec_gated = not (self.proxy_stack.isEnabled() and self.snort.isEnabled()
                         and self.aide.isEnabled())
        self.security_section.set_default_expanded(not sec_default or sec_gated)
        # Edge-AI and the backing services no longer have SECTIONS to expand — they are
        # groups inside the services table (ask 23), and the services section itself is
        # never folded by default. What survives of the rule is the part that carried
        # information: a group holding a NON-DEFAULT value must be expanded so the operator
        # sees it on arrival. The edge_ai ROLE auto-checking its own service is the case
        # this exists for; it must not land inside a collapsed group row.
        edge_default = (
            self.edge_ai.isChecked() == _on_off(_field_default("edge_ai_service"))
            and self.edge_ai_analysis.isChecked() == _field_default("edge_ai_analysis")
            and self.edge_ai_models.text().strip() == _field_default("edge_ai_models")
            and self.edge_ai_default.text().strip() == _field_default("edge_ai_model_default")
            and self.edge_ai_runtime.currentText() == _field_default("edge_ai_runtime"))
        if not edge_default:
            self.group_items[_AI_GROUP].setExpanded(True)
            self.edge_ai_item.setExpanded(True)
        if self.wiz.cfg.managed_services:
            self.group_items[_BACKING_GROUP].setExpanded(True)

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
        # ── the identity rows, collected ONLY while their axis has them on screen ──
        # THE HOUSE RULE, both halves. initializePage hides a row it does not apply to,
        # and a hidden QLineEdit KEEPS its text — so a scope-blind collect here would let
        # a brand typed while the role was standalone-thick ride a later switch to
        # standalone-unaffiliated straight into to_cli_args(), which raises ValueError on
        # it. The reset arm is what makes the hide emission-neutral in the OTHER
        # direction too: the field goes back to its ImageConfig dataclass default, read
        # from the dataclass rather than restated as a literal (_field_default — the same
        # lookup clear_unsupported uses), so hiding a control can neither add nor remove
        # an argv token. The predicates are recomputed rather than cached off
        # initializePage: validatePage must be correct for a headless caller that never
        # drew the page, and cfg is the source of truth initializePage re-reads anyway.
        #
        # DEFECT 3 — brand identity is FORBIDDEN on an unaffiliated image (a brand IS an
        # affiliation; core/config.py::_check_unaffiliated_conflicts and
        # build-x86-host-stage4.sh both refuse it). Its LOOK is NOT: theme / wallpaper /
        # accent colour / colour scheme are the branding step's business now, per the
        # operator's 2026-08-26 split, and nothing here touches them.
        if not (c.role == UNAFFILIATED_ROLE or getattr(c, "unaffiliated", False)):
            c.brand_profile = self.brand_profile.text().strip()
            c.brand = self.brand.text().strip() or _field_default("brand")
            c.brand_title = self.brand_title.text().strip() or _field_default("brand_title")
            c.org = self.org.text().strip() or _field_default("org")
        else:
            c.brand_profile = _field_default("brand_profile")     # ""
            c.brand = _field_default("brand")                     # "hugmesh"
            c.brand_title = _field_default("brand_title")         # "HugMesh Systems"
            c.org = _field_default("org")                         # "hugmesh"
        # DEFECT 1 — the cluster plane. COLLECT only when the rows are on screen; when
        # they are hidden, LEAVE THE FIELDS ALONE. Platform-scoped: a standalone rpi5
        # 'generic' image keeps the rows and collects them, because its builder really
        # does bake them (build-rpi5-stage4.sh writes /etc/hugmesh/cluster-domain
        # unconditionally).
        #
        # NO RESET ARM — this is the REDUNDANT axis, not the inapplicable one, and the
        # distinction is the whole lesson of the 2026-08-26 review. `cluster_domain` is
        # ONE field shared across the wizard session, while `_cluster_identity_applies`
        # is a function of (platform, mode). A reset arm therefore let an x86 DETOUR
        # reach over and destroy a domain typed for a Pi image the operator was still
        # building. Measured, before this was removed:
        #     rpi5 visit, operator types example.org  -> --cluster-domain example.org
        #     flip the device to x86 on RolePage      -> cluster_domain = hugmesh.net
        #     flip back to rpi5                       -> STILL hugmesh.net, widget blank
        # i.e. the clear REMOVED an argv token from an image the operator never touched,
        # which is precisely what the emission-neutrality rule forbids.
        #
        # Dropping it is emission-neutral for the hidden image too: `_x86_args` gates the
        # whole trio behind its own `mode in ("cloud", "mesh")` test, so an x86 standalone
        # emits none of them whatever the field holds. The clear bought nothing there and
        # cost the ARM lane its value. This is the same REDUNDANT treatment role.py gives
        # --capable and --standalone, for the same stated reason: clearing would silently
        # rewrite a loaded config on a mere page visit.
        if _cluster_identity_applies(c):
            c.cluster_domain = self.domain.text().strip() or _field_default("cluster_domain")
            c.games_domain = self.games_domain.text().strip()
            rs = self.release_state.currentText()
            c.release_state = "" if rs == "default" else rs
        # Scope-gated collect, mirroring HomePage's standalone line: the hidden widget
        # KEEPS its text/checked state, so without this a conf picked while the role was a
        # desktop would silently ride a later switch to a node role. cfg is the source of
        # truth initializePage re-reads, so an in-scope image collects exactly as before.
        egress_ok = scope_allows_flow("egress_vpn", c, self.wiz)
        c.egress_vpn = self.egress.text().strip() if egress_ok else ""
        c.egress_vpn_locked = self.egress_locked.isChecked() and egress_ok
        c.proxy_stack = self.proxy_stack.currentText()
        c.snort = self.snort.isChecked()
        c.aide = _off_value(self.aide)
        c.root_login = self.root_login.currentText()
        c.edge_ai_service = _off_value(self.edge_ai)
        c.edge_ai_runtime = self.edge_ai_runtime.currentText()
        c.edge_ai_models = self.edge_ai_models.text().strip()
        c.edge_ai_model_default = self.edge_ai_default.text().strip()
        c.edge_ai_analysis = self.edge_ai_analysis.isChecked()
        # ── the service rows, collected through whichever channel this platform uses ──
        # A row is written to its dedicated field OR contributed to the optional-services
        # allow-list, never both, and never to a channel this builder does not parse (see
        # _service_channel). Unreachable rows are left at the dataclass default rather
        # than at "off": emitting --no-<x> for a flag this builder never had would be a
        # lie in the other direction, and clear_unsupported would strip it anyway.
        catalog = tuple(OPTIONAL_SERVICES_BY_PLATFORM.get(c.platform or "x86", ()))
        picked: list[str] = []
        # Was the slug channel on screen at all on this flow? Distinguishes "the operator
        # cleared every service" from "this platform's builder parses no --optional-services
        # and there was never a row to clear" — see the empty-picked branch below.
        slug_rows_offered = False
        offered = self._service_offered
        # DEFECT 6. The HIDDEN picker is not an unanswered one — the role settles it, and
        # initializePage cleared every row to that answer, so those cleared rows are
        # collected exactly as a hand-unticked visible picker would be. The earlier shape
        # blanked `offered` here (`… if not self._services_hidden else {}`) and emitted
        # nothing at all, which handed the whole selection to whatever OPTIONAL_SERVICES /
        # WANT_<x> a brand.conf carried — measured leak, comment on the hide above.
        # `tor` is the row this matters most for, and it is the row a hide that collects
        # only what was OFFERED still misses: --no-tor was never on a standalone argv even
        # before the hide, because the flag row is mode-gated off outside cloud/mesh (the
        # `slug == "tor"` gate in initializePage). So tor is the one token the fix ADDS
        # rather than restores — and it is exactly the token that stops a profile's
        # WANT_TOR=true from emerging net-vpn/tor (:5134, unguarded) into a standalone
        # desktop. Measured, --role standalone-thick, a profile holding WANT_TOR=true /
        # WANT_CHARACTER_STUDIO=true, `--exclude-services zzz` used only to force the
        # builder's own `final selection:` line (:1244, idempotent no-op):
        #     -C b2.conf                                        -> akkoma tuwunel phpbb
        #                                                          tor character-studio
        #     -C b2.conf --optional-services ""                 -> tor character-studio
        #     -C b2.conf --optional-services "" --no-tor
        #        --no-character-studio --no-character-forge
        #        --no-edge-ai-tts                               -> none
        # i.e. the explicit-none sentinel ALONE leaves tor selected. Identical on
        # standalone-unaffiliated, where the profile arrives WITHOUT a -C at all — the
        # builder auto-detects `$(pwd)/brand.conf` (:884) and Studio spawns it with
        # cwd=generator_dir (core/build_driver.py `_spawn`), the directory
        # brand.conf.example ships in. Measured from a directory holding that same
        # profile, feeding the builder the WHOLE argv this page now emits:
        #     --role standalone-unaffiliated (bare, profile auto-detected)
        #                                              -> akkoma tor character-studio
        #     …the pre-fix wizard argv (no --no-tor)   -> tor
        #     …the post-fix wizard argv                -> none
        # and with no profile anywhere the post-fix argv is still `none`, while the CLOUD
        # desktop argv is byte-identical either way (akkoma tuwunel phpbb).
        hidden = self._services_hidden
        for slug, box in self.service_boxes.items():
            channel = _service_channel(slug, c.platform, catalog)
            if channel == "slug" and offered.get(slug):
                slug_rows_offered = True
            # Was this row ANSWERED on this flow? Normally that is "it was on screen".
            # Under the WHOLE-PICKER hide it is wider by exactly one row: the ROLE answered
            # every flag the builder parses here, tor included, even though the mode gate
            # had already taken tor's row off screen. The hide's clear above unticked that
            # box with all the others, so widget state and emission still agree.
            # Restricted to the FLAG channel on purpose — `offered` starts life as
            # bool(channel), so a catalogue slug can never be un-offered, and a row with no
            # channel has no flag to emit in the first place.
            answered = bool(offered.get(slug)) or (hidden and channel == "flag")
            if not answered:
                # Not answered on this flow (unreachable flag, or off-mode tor while the
                # picker IS on screen): leave the field at its dataclass default. Hiding a
                # single ROW must change no argv, and with two-state boxes "collect what is
                # on screen" would emit --no-tor for a decision this flow never showed —
                # different from the whole-picker hide above, where the role has answered
                # for every row at once.
                if channel == "flag":
                    fld, _tri = _FLAG_SERVICE_FIELDS[slug]
                    setattr(c, fld, _field_default(fld))
                continue
            if channel == "flag":
                fld, tri = _FLAG_SERVICE_FIELDS[slug]
                setattr(c, fld, (_off_value(box) if tri else box.isChecked()))
            elif channel == "slug" and box.isChecked():
                picked.append(slug)
        # the whole-set preset replaces the slug rows (see _services_args: [none] emits
        # --optional-services "" and [all] emits --all-services) (G13/G14)
        preset = self.services_preset.currentIndex()
        if hidden:
            # EXPLICIT none — `--optional-services ""`, which is what the builder's own
            # plan claims a client role gets (:2054) and, unlike emitting nothing, is what
            # it actually gets. Stated here rather than left to the preset chain so the
            # invariant survives a headless caller that never drew the page: hidden picker
            # => explicit empty selection, full stop. (initializePage sets the preset
            # widget to _PRESET_NONE too, so the two agree.)
            c.optional_services = [SERVICES_NONE]
        elif preset == _PRESET_NONE:
            c.optional_services = [SERVICES_NONE]
        elif preset == _PRESET_ALL:
            c.optional_services = [SERVICES_ALL]
        elif picked or not slug_rows_offered:
            c.optional_services = picked
        else:
            # CUSTOM with every offered slug row UNTICKED is now a real answer, and it is
            # "none" — because the builders' default set arrives TICKED (see
            # initializePage). Emitting [] here would emit no flag at all, so the builders'
            # `${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}` would put the three back: the
            # operator would have cleared every box and got a forum anyway, and the state
            # would not even round-trip (the empty list re-ticks the defaults on the next
            # visit). Guarded on slug_rows_offered so a platform that never showed a slug
            # row — frite/jetson, whose builders parse no --optional-services — keeps
            # emitting nothing rather than an unsupported explicit "none" that
            # clear_unsupported would strip anyway.
            c.optional_services = [SERVICES_NONE]
        # ASK 2, verbatim: "remove the exclude services field, it makes no sense". The
        # widget is gone; the FIELD and the --exclude-services flag are deliberately kept
        # (it is the only knob that can subtract a slug a brand.conf injected directly
        # into OPTIONAL_SERVICES — build-x86-host-stage4.sh:1234-1246, applied last — and
        # tests/build-matrix/flag-coverage.sh would need two "no longer a GUI knob"
        # allowlist entries if it went). It is now reachable only from a brand profile
        # (-C) or extra flags. NOT reset here: a value loaded from a saved config or set
        # through those channels must survive a trip through this page, which a blind
        # `c.exclude_services = []` would have silently blanked on every Next.
        #
        # `enable_games` is NOT collected here — `games` is one of the service rows above
        # and the channel loop already wrote it. Setting it twice was the first cut, and
        # it broke exactly where it matters: on a platform whose builder has no
        # --enable-games, the loop correctly leaves the field alone and the second write
        # put the widget's state back.
        # ASK 8's gate + its emission clear used to live here, beside the checkbox. Both
        # moved WITH the decision to the ask-19/20 choice screens (domains_choice.py /
        # users_choice.py), which is also where that state is now entered. All that stays
        # here is the non-mesh reset: the two flow flags are MESH concepts, and a
        # cloud/standalone flow never sees either screen, so a value left over from an
        # earlier mesh flow must not linger into its config.
        if c.mode != "mesh":
            c.additional_domains = False
            c.configure_users = False

        # Managed backing services (I8/M2): a row contributes id -> endpoint ONLY when its
        # hosting dropdown says Managed AND an endpoint is entered — a Managed row with an
        # empty endpoint is an incomplete selection, dropped so the default (every row
        # Self-hosted) stays byte-identical. This is also why _hosting_changed does not
        # clear the field on switching back to Self-hosted: a stale string on a Self-hosted
        # row cannot reach the argv, so keeping it costs nothing and losing it would annoy.
        # Endpoint SHAPE is fail-closed later by to_cli_args/validate_identity (tier-3
        # refused, no shell metachars), the same boundary the idp fields use.
        c.managed_services = {
            sid: ep.text().strip()
            for sid, (combo, ep) in self.managed_rows.items()
            if combo.currentIndex() == _HOSTING_MANAGED and ep.text().strip()
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
