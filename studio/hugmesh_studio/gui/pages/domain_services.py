"""DomainServicesPage — the per-domain Services step (issues #494 / #495).

    "make sure that the service configuration is integrated into the domain setup
     instead of its own separate thing. make sure that for each domain, the service
     page needs to be config, so there's basically a service page per domain you make
     you have to go through before building or starting a mesh in docker or nodes"
                                                        — the operator, 2026-09-17

WHAT THIS REPLACES. The per-domain choice used to be ONE TOOLBUTTON in a table row
(``pages/domains.py`` ``_ServicesButton``, #227). It was already per-domain and it was
already honest about scope — but it was a menu behind a cell, and NOTHING obliged the
operator to open it, so "the services this domain provides" was a question most builds
never answered. That cell is now READ-ONLY (``pages/domains.py`` ``_ServicesCell``) and
says where the choice is made; this page is where it is made.

ONE PAGE PER DOMAIN, in the literal sense the ask means: the page shows exactly ONE
domain at a time and you step through them (‘Next domain’). ``QWizardPage`` instances
are constructed once, at wizard build time, and the domain count is not known until the
Domains table has run — so N Qt pages cannot exist. What the operator gets is the thing
they asked for: their domains, one service screen each, walked in order.

WHAT COUNTS AS CONFIGURED. Going through a domain's screen is what records it —
``cfg.domain_services_reviewed`` gains the name (core/domain_services.py owns that
bookkeeping and explains why emptiness could not stand in for it). A domain nobody
walked stays UNCONFIGURED, keeps whatever slugs its manifest already carried, and is
named by the gate:

* ``gui/pages/launch.py`` refuses the image build,
* ``gui/pages/localmesh.py`` refuses BOTH docker mesh-start doors — the bring-up
  (``_bootstrap_up``) and Saved meshes -> Start/Restore (``_start_saved``), which come
  up on the same compose project from the same ``wiz.cfg``,
* ``gui/pages/sessions_widget.py`` refuses a previous-builds RESTART, narrowly — see
  ``core.domain_services.restart_gate_reason`` for why that one door is not blanket.

All four through the single seam ``core.domain_services.gate_reason`` so a test can
drive the refusal with a bare ``ImageConfig``.

SCOPE IS NAMED, NOT IMPLIED (#497). Every row on the checkbox table carries a Scope
column reading "Domain" — on the row, not in a tooltip, because "the operator can see
without reading source which of their choices binds what" is the requirement and a
hover is not seeing. Below it sits a READ-ONLY table of the choices this page shows but
does not own: the four infra slugs with the scope they really have, where each one IS
set, and what it is doing right now (the image-wide selection, plus any per-node opt-in
in the worklist). They are DATA, never controls — see the next paragraph — and a legend
spells out all three scopes with where each is chosen and what each binds.

SCOPE IS NOT FLATTENED. The catalogue offered here is ``DOMAIN_CATALOGUE``
(= ``OPTIONAL_SERVICES_CHOICES``, what ``--all-services`` expands to): the only slugs
whose own descriptions are ``<domain>``-scoped. The INFRA slugs (tor, egress-vpn,
workloadConsole, anubis) are node- or cluster-plane scoped and are NOT offered as
per-domain checkboxes — ``domains.py`` has said since #227 that that "would be a new
lie", and a required page is a worse place to tell it than a menu was. An assert in
``_rebuild`` pins that nothing node-scoped can reach the checkbox list.

NO MODAL ANYWHERE. Every refusal and every hint on this page is an inline QLabel; the
only interactive controls are checkboxes and two step buttons. ``validatePage`` opens
nothing and blocks nothing — it RECORDS, and the gates downstream refuse. (A page that
refused its own Next would strand an operator who cannot see why; the build screen is
where the refusal can be acted on, beside the ‘back to the main menu’ card.)

HONESTY, and it is on the page rather than in this docstring: the selection does not
yet reach the cluster (``ENFORCEMENT_NOTE`` / issue #496).

THE MESH'S OWN DOMAIN GETS A PAGE TOO (reported 2026-09-23: "the checkbox doesn't
seem to be present on each domain page"). Ask 19's default card — "Just this mesh's own
domain" — skips the Domains table, and until now that skipped this step with it, so the
one domain every mesh serves (``cfg.cluster_domain``) never had a services page. Now
``applies_to`` is True on every mesh flow and the walk starts with the own domain
(``core.domain_services.implicit_own_domain``), then the table rows. The own domain is
IMPLICIT — never a ``cfg.domains`` row, so the ASK-8 emission guard holds (an untouched
flow emits no ``--domains`` and no manifest ``domains`` entry); its selection is
``cfg.cluster_domain_services``, which both manifests carry only when non-empty. The
gate (``unconfigured_domains``) still names TABLE rows only: the own domain's page is
enforced by being unavoidable on the flow, not by the gate, because a gate that refused
a mesh-mode config for its own domain would also refuse the local-docker route an
operator reaches after clicking "Mesh node" first — a flow that has no such step.

ONE BODY, TWO HOSTS. ``DomainServicesBody`` is the surface and its logic as a plain
mixin; this page hosts it in the image flow, and ``DomainServicesWidget`` hosts the
SAME body on the generate-a-new-local-mesh route (``pages/localmesh.py``), where the
"config" is ``core.local_mesh_domains.LocalMeshDomains`` rather than an ImageConfig.
Nothing is forked: the catalogue, the scope tables, the recording and the reviewed
bookkeeping are one implementation.

WHERE #499 (per-service source forge + credentials) GOES: each service row is a
QTreeWidgetItem in ``self._rows`` keyed by slug, and the table already carries a
per-row settings column that is empty today. A forge/repo/branch control per row hangs
off ``_COL_SETTING`` with no restructure; a per-DOMAIN credential belongs in the
header block beside ``self.head``, which is already per-domain state.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ..styles import MUTED, WARN, muted
from ._scroll import scrollable
from ...core.domain_services import (
    DOMAIN_CATALOGUE, ENFORCEMENT_NOTE, OTHER_SCOPE_HEADERS, SCOPE_BINDS,
    SCOPE_DOMAIN, SCOPE_IMAGE, SCOPE_LABELS, SCOPE_NODE, SCOPE_WHERE,
    carried_over_slugs, describe, describe_carried_over, domain_names_for_services,
    grouped_domain_catalogue, implicit_own_domain, normalise_slugs,
    other_scope_rows, record_reviewed, reviewed_names, scope_of,
    services_page_applies, unconfigured_domains,
)

#: Table columns. ``_COL_SCOPE`` (#497) says what each row BINDS, on the row itself and
#: not in a tooltip — "the operator can see, without reading source, which of their
#: choices binds the domain, which binds the image, and which binds a node", and a hover
#: is not seeing. ``_COL_SETTING`` is deliberately present and empty: it is where the
#: per-service source forge / credential fields of #499 land without another restructure
#: (see the module docstring).
_COL_ON, _COL_NAME, _COL_SCOPE, _COL_SETTING, _COL_DESC = range(5)
_HEADERS = ("On", "Service", "Scope", "", "What it does for this domain")

#: The label a carried-over slug wears — one this build's catalogue does not offer.
#: The row's DESCRIPTION says the rest (core.domain_services.describe_carried_over),
#: which keeps whatever the slug's own catalogue line says instead of replacing it.
_EXTRA_NOTE = "  (kept from your config)"


def _scope_legend() -> str:
    """The three scopes, each with where it is chosen and what it binds (#497).

    Built from ``core.domain_services`` rather than retyped, so a scope whose wording
    changes there cannot leave a stale sentence behind on this page."""
    return "  ·  ".join(
        f"{SCOPE_LABELS[k]}: set {SCOPE_WHERE[k]}, binds {SCOPE_BINDS[k]}"
        for k in (SCOPE_DOMAIN, SCOPE_IMAGE, SCOPE_NODE))


class DomainServicesBody:
    """The per-domain services surface and its logic, as a plain-Python mixin.

    A host calls :meth:`_init_body` with the layout to fill, overrides the three
    hooks (:meth:`_set_titles`, :meth:`_scope_cfg`, :meth:`_entries`) and drives
    :meth:`_load` / :meth:`_record` from its own entry/exit points. Every widget and
    every piece of working state lives directly on the host object — no delegation —
    so ``DomainServicesPage`` keeps the attributes its tests read."""

    def _init_body(self, lay) -> None:
        #: domain name -> the slugs chosen for it (the working copy; cfg is written
        #: at _record, which is what validatePage and ``collect_all`` reach).
        self._selection: dict[str, list[str]] = {}
        #: the domain names actually walked in this wizard run, plus whatever a loaded
        #: config already recorded.
        self._reviewed: set[str] = set()
        #: the ImageConfig object the working state above belongs to. Load/Save replaces
        #: wiz.cfg wholesale (``load_config`` / ``load_session`` / ``start_build_from_
        #: session``), and the page's state is per-CONFIG, not per-page: without this,
        #: walking acme.example in one config and then LOADING a different file that
        #: also names acme.example would land on the new file with acme.example already
        #: marked reviewed — a domain nobody configured passing the gate. Identity, not
        #: equality: two configs can be equal and still be different sessions.
        self._cfg_seen = None
        self._names: list[str] = []
        #: the mesh's OWN domain when it is on the walk (implicit_own_domain), so the
        #: header can say so and _record knows which field takes its selection.
        self._own_name = ""
        self._index = 0
        self._rows: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._boxes: dict[str, QtWidgets.QCheckBox] = {}
        #: the read-only #497 rows, keyed the same way — data, never controls.
        self._other_rows: dict[str, QtWidgets.QTreeWidgetItem] = {}

        # ── which domain this screen is ────────────────────────────────────────────
        self.head = QtWidgets.QLabel("")
        self.head.setWordWrap(True)
        self.head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.head)

        step = QtWidgets.QHBoxLayout()
        self.prev_btn = QtWidgets.QPushButton("◀  Previous domain")
        self.next_btn = QtWidgets.QPushButton("Next domain  ▶")
        self.prev_btn.clicked.connect(lambda: self._step(-1))
        self.next_btn.clicked.connect(lambda: self._step(1))
        step.addWidget(self.prev_btn)
        step.addWidget(self.next_btn)
        step.addStretch(1)
        lay.addLayout(step)

        # ── the honesty banner (#496) — on the page, not in a tooltip ──────────────
        self.enforcement = QtWidgets.QLabel(ENFORCEMENT_NOTE)
        self.enforcement.setWordWrap(True)
        self.enforcement.setStyleSheet(f"color: {WARN};")
        lay.addWidget(self.enforcement)

        # What THIS lane does with the selection, when the host has a sentence to add
        # (the local docker mesh: recorded with the mesh, not what picks the compose
        # profiles). Hidden while empty so the image flow's page is unchanged.
        self.lane_note = QtWidgets.QLabel("")
        self.lane_note.setWordWrap(True)
        self.lane_note.setStyleSheet(f"color: {WARN};")
        self.lane_note.setVisible(False)
        lay.addWidget(self.lane_note)

        self.help = QtWidgets.QLabel(
            "Tick the services THIS domain provides. They ride the mesh manifest as "
            "per-domain provisioning input (domains[].optional_services); they do not "
            "change which services the image bakes — that is the ‘Network & services’ "
            "step. Ticking nothing is a real answer: it means the cluster-wide set "
            "applies to this domain.")
        self.help.setWordWrap(True)
        self.help.setStyleSheet(muted())
        lay.addWidget(self.help)

        self.table = QtWidgets.QTreeWidget()
        self.table.setColumnCount(len(_HEADERS))
        self.table.setHeaderLabels(list(_HEADERS))
        self.table.setRootIsDecorated(True)
        self.table.setAlternatingRowColors(True)
        self.table.setUniformRowHeights(False)
        self.table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        self.table.setMinimumHeight(300)
        hdr = self.table.header()
        hdr.setStretchLastSection(True)
        for c in (_COL_ON, _COL_NAME, _COL_SCOPE, _COL_SETTING):
            hdr.setSectionResizeMode(
                c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hdr.setToolTip(_scope_legend())
        lay.addWidget(self.table)

        # ── the choices this page SHOWS but does not own (#497) ───────────────────
        self.other_head = QtWidgets.QLabel(
            "<b>Not domain-scoped</b> — shown here so you do not have to hunt for "
            "them, and shown as DATA rather than as tick-boxes because none of them "
            "binds one domain. Each row says where it is set and what it is doing "
            "right now.")
        self.other_head.setWordWrap(True)
        self.other_head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.other_head)

        self.other_table = QtWidgets.QTreeWidget()
        self.other_table.setColumnCount(len(OTHER_SCOPE_HEADERS))
        self.other_table.setHeaderLabels(list(OTHER_SCOPE_HEADERS))
        self.other_table.setRootIsDecorated(False)
        self.other_table.setAlternatingRowColors(True)
        self.other_table.setUniformRowHeights(False)
        self.other_table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        other_hdr = self.other_table.header()
        other_hdr.setStretchLastSection(True)
        for c in range(len(OTHER_SCOPE_HEADERS) - 1):
            other_hdr.setSectionResizeMode(
                c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        lay.addWidget(self.other_table)

        self.legend = QtWidgets.QLabel(_scope_legend())
        self.legend.setWordWrap(True)
        self.legend.setStyleSheet(muted())
        lay.addWidget(self.legend)

        # ── how far through the domains this walk is ──────────────────────────────
        self.remaining = QtWidgets.QLabel("")
        self.remaining.setWordWrap(True)
        lay.addWidget(self.remaining)
        lay.addStretch(1)

    # ── host hooks ────────────────────────────────────────────────────────────────
    def _set_titles(self, title: str, subtitle: str) -> None:
        """Where the host shows "Services for <domain>" (a wizard page's title bar, a
        widget's header label)."""

    def _scope_cfg(self):
        """The config the read-only "not domain-scoped" table reads the mesh-wide
        state off (``other_scope_rows``); None renders the state column empty."""
        return None

    def _entries(self):
        """The worklist rows the host is carrying, or () — the per-node half of the
        state column."""
        return ()

    # ── flow ──────────────────────────────────────────────────────────────────────
    def _load(self, cfg, names, own_name: str = "") -> None:
        """Enter the walk for ``cfg``: ``names`` in walk order, ``own_name`` the
        implicit own domain among them (or "")."""
        if cfg is not self._cfg_seen:
            # A DIFFERENT configuration object — Load config / Load session / a restart
            # from the previous-builds manager. Drop every working answer: they belong
            # to the config they were given for, and carrying a reviewed marker across
            # would let a domain nobody looked at satisfy the gate. cfg's OWN
            # domain_services_reviewed is still honoured below, which is the only
            # record that travels with a configuration.
            self._selection = {}
            self._reviewed = set()
            self._index = 0
            self._cfg_seen = cfg
        self._names = [n for n in names if n]
        self._own_name = (own_name or "").strip()
        # Seed from cfg every entry: the Domains table may have added, renamed or
        # dropped rows since the last visit. A name that survived keeps its working
        # selection; a new one starts from whatever the manifest already carried —
        # the row's slugs, or ``cluster_domain_services`` for the own domain.
        rows = {(getattr(d, "name", "") or "").strip(): d
                for d in (getattr(cfg, "domains", None) or [])}
        fresh: dict[str, list[str]] = {}
        for name in self._names:
            if name in self._selection:
                fresh[name] = self._selection[name]
            elif name == self._own_name and name not in rows:
                fresh[name] = normalise_slugs(
                    getattr(cfg, "cluster_domain_services", None))
            else:
                row = rows.get(name)
                fresh[name] = normalise_slugs(
                    getattr(row, "optional_services", None) if row else None)
        # ASSIGNED, never merged into what was there: a domain dropped from the table
        # must not keep a working selection that a later re-add would silently restore.
        self._selection = fresh
        # A config loaded from disk brings its own record of what was configured —
        # re-walking it must not be demanded twice. Names that no longer exist drop.
        self._reviewed = {n for n in (self._reviewed | reviewed_names(cfg))
                          if n in self._selection}
        # Land on the first domain that still needs walking, so a Back into the page
        # resumes where the work is rather than at the top.
        pending = [i for i, n in enumerate(self._names) if n not in self._reviewed]
        self._index = pending[0] if pending else 0
        self._show()

    def _step(self, delta: int) -> None:
        """Move one domain. Guarded: PyQt6 qFatals on an exception escaping a slot."""
        try:
            self._capture()
            if not self._names:
                return
            self._index = max(0, min(len(self._names) - 1, self._index + delta))
            self._show()
        except Exception:                      # noqa: BLE001
            pass

    def current_domain(self) -> str:
        """The domain this screen is showing ("" when there are none)."""
        if not self._names:
            return ""
        return self._names[max(0, min(len(self._names) - 1, self._index))]

    # ── rendering ────────────────────────────────────────────────────────────────
    def _show(self) -> None:
        name = self.current_domain()
        total = len(self._names)
        if not name:
            self.head.setText("No domains to configure.")
            self.table.clear()
            self._rows, self._boxes = {}, {}
            self.other_table.clear()
            self._other_rows = {}
            self.remaining.setText("")
            self.prev_btn.setEnabled(False)
            self.next_btn.setEnabled(False)
            return
        # BEING HERE IS GOING THROUGH IT. The operator is looking at this domain's
        # catalogue with its current selection ticked; that is the step the ask asks
        # for, and demanding a second "confirm" click would be a ceremony that adds no
        # information. Domains never shown stay unconfigured and the gate names them.
        self._reviewed.add(name)
        own = " (this mesh's own domain)" if name == self._own_name else ""
        self._set_titles(
            f"Services for {name}",
            f"Domain {self._index + 1} of {total} — every domain gets its own "
            "service page, and a domain you never open is refused at build time.")
        self.head.setText(
            f"<b>{name}</b>{own} &nbsp;·&nbsp; domain {self._index + 1} of {total}")
        self.prev_btn.setEnabled(self._index > 0)
        self.next_btn.setEnabled(self._index < total - 1)
        self._rebuild(name)
        self._rebuild_other_scopes()
        left = [n for n in self._names if n not in self._reviewed]
        if left:
            self.remaining.setText(
                f"{total - len(left)} of {total} domains configured. Still to go: "
                + ", ".join(left)
                + " — use ‘Next domain’. An image build or a mesh start will refuse "
                  "while any domain is unconfigured, and will name it.")
            self.remaining.setStyleSheet(f"color: {WARN};")
        else:
            self.remaining.setText(
                f"All {total} domain{'s' if total != 1 else ''} configured.")
            self.remaining.setStyleSheet(f"color: {MUTED};")

    def _rebuild(self, name: str) -> None:
        """Rebuild the checkbox table for ``name``. Cheap (8 rows plus any carried-over
        slug), and rebuilding is what keeps a per-domain extra from leaking onto the
        next domain's screen."""
        self.table.clear()
        self._rows, self._boxes = {}, {}
        chosen = set(self._selection.get(name, []))
        for group, slugs in grouped_domain_catalogue():
            gitem = self._group_row(group)
            for slug in slugs:
                # The scope rule of #227, kept as an assert rather than a comment: a
                # node/cluster-plane slug must never become a per-domain checkbox.
                assert scope_of(slug) == SCOPE_DOMAIN, \
                    f"{slug} is not domain-scoped and must not be offered per domain"
                self._svc_row(gitem, slug, slug, describe(slug), slug in chosen)
        extras = carried_over_slugs(self._selection.get(name, []))
        if extras:
            gitem = self._group_row("From your config")
            for slug in extras:
                self._svc_row(gitem, slug, slug + _EXTRA_NOTE,
                              describe_carried_over(slug), True)

    def _rebuild_other_scopes(self) -> None:
        """Fill the read-only table of choices this page shows but does not own (#497).

        DATA, NEVER CONTROLS. Nothing here gets a checkbox: the four infra slugs are
        node- or cluster-plane scoped, and ``domains.py`` has said since #227 that a
        per-DOMAIN checkbox for them "would be a new lie". Showing them read-only is
        what satisfies the other half of the ask — that they stay reachable from this
        flow instead of the operator having to hunt for where anubis is configured.

        Rebuilt on every _show() because the state column is LIVE: it reads the
        image-wide selection and the worklist's per-node opt-ins, either of which the
        operator may have changed since this page was last painted."""
        self.other_table.clear()
        self._other_rows = {}
        for slug, scope, where, state in other_scope_rows(self._scope_cfg(),
                                                          self._entries()):
            item = QtWidgets.QTreeWidgetItem(self.other_table)
            # NOT CHECKABLE, explicitly. A QTreeWidgetItem carries ItemIsUserCheckable
            # by default and renders no box only because nobody set a check state —
            # which makes "this row is data" an accident of omission rather than a
            # decision. Clearing the flag makes it the decision it is: a per-DOMAIN
            # tick-box for a node- or cluster-plane slug would be a new lie, and the
            # next person to add a setCheckState here should have to remove this line
            # first.
            item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsUserCheckable)
            item.setText(0, slug)
            item.setText(1, SCOPE_LABELS[scope])
            item.setToolTip(1, f"Binds {SCOPE_BINDS[scope]}.")
            item.setText(2, where)
            item.setToolTip(2, where)
            item.setText(3, state)
            item.setToolTip(3, state)
            desc = describe(slug)
            if desc:
                item.setToolTip(0, desc)
            self._other_rows[slug] = item

    def _group_row(self, title: str) -> "QtWidgets.QTreeWidgetItem":
        item = QtWidgets.QTreeWidgetItem(self.table)
        item.setText(_COL_NAME, title)
        font = item.font(_COL_NAME)
        font.setBold(True)
        item.setFont(_COL_NAME, font)
        item.setExpanded(True)
        return item

    def _svc_row(self, parent, slug: str, label: str, desc: str,
                 checked: bool) -> None:
        """One service row: a checkbox, the slug the builders parse (NOT a prettified
        display name — it is what docs, brand.conf and --print-plan all say), and the
        one line saying what it does."""
        item = QtWidgets.QTreeWidgetItem(parent)
        item.setText(_COL_NAME, label)
        # EVERY row on this table is domain-scoped — the catalogue is the domain
        # catalogue and _rebuild asserts it — so the column is not decoration: it is
        # what makes the read-only table below legible as "and these are not".
        item.setText(_COL_SCOPE, SCOPE_LABELS[SCOPE_DOMAIN])
        item.setToolTip(_COL_SCOPE,
                        f"Set {SCOPE_WHERE[SCOPE_DOMAIN]}; binds "
                        f"{SCOPE_BINDS[SCOPE_DOMAIN]}.")
        item.setText(_COL_DESC, desc)
        item.setToolTip(_COL_DESC, desc)
        box = QtWidgets.QCheckBox()
        box.setChecked(checked)
        self.table.setItemWidget(item, _COL_ON, box)
        self._rows[slug] = item
        self._boxes[slug] = box

    # ── state ────────────────────────────────────────────────────────────────────
    def _capture(self) -> None:
        """Read the visible checkboxes back into the working selection, in CATALOGUE
        order (never widget order — see core/domain_services.normalise_slugs)."""
        name = self.current_domain()
        if not name or not self._boxes:
            return
        self._selection[name] = normalise_slugs(
            [slug for slug, box in self._boxes.items() if box.isChecked()])

    def selected_slugs(self, name: str | None = None) -> list[str]:
        """The slugs recorded for ``name`` (the current domain by default) — the API
        tests read the page through, the twin of ``_ServicesButton.selected_slugs``."""
        if name is None:
            self._capture()
            name = self.current_domain()
        return list(self._selection.get(name, []))

    def _record(self, cfg) -> None:
        """RECORD, never refuse. Writes the per-domain selections onto ``cfg.domains``
        (and the own domain's onto ``cfg.cluster_domain_services``) and the walked
        names onto ``cfg.domain_services_reviewed``.

        Always returns True on purpose. ``collect_all()`` re-runs a visited page's
        validatePage to harvest it, so a False here would make saving a config depend
        on where the operator happened to be standing — and the refusal the ask asks
        for belongs at the build/mesh-start screens, where it can be acted on, not on
        the page that is trying to collect the answer. The gate itself is
        ``core.domain_services.gate_reason``.

        Writes by NAME, never by index: the Domains table may have renamed, added or
        dropped rows between this page's last visit and this call.

        WRITES ONLY TO THE CONFIG IT WAS GIVEN. ``initializePage`` records which
        ImageConfig object this page's working state belongs to; if wiz.cfg has been
        replaced since (Load config / Load session / a restart from the previous-builds
        manager), this is a no-op rather than a write of one configuration's answers
        onto another's domains. ``QWizard::restart()`` calls ``cleanupPage`` on every
        visited page, and ``load_config`` calls ``restart()``, so that is not a
        hypothetical ordering."""
        if cfg is not self._cfg_seen:
            return
        self._capture()
        rows = [(d, (getattr(d, "name", "") or "").strip())
                for d in (getattr(cfg, "domains", None) or [])]
        for d, name in rows:
            if name in self._selection:
                d.optional_services = list(self._selection[name])
        own = self._own_name
        if own and own in self._selection and own not in {n for _d, n in rows}:
            cfg.cluster_domain_services = list(self._selection[own])
        # REBUILT from the domains that still exist (record_reviewed does the
        # restriction), so a renamed or deleted domain cannot leave a stranded marker
        # that would let the gate pass for a domain nobody configured.
        record_reviewed(cfg, self._reviewed)

    # ── introspection for the gate's own callers/tests ───────────────────────────
    def unconfigured(self) -> list[str]:
        """The domains this walk has not been through yet, in table order."""
        return [n for n in self._names if n not in self._reviewed]


class DomainServicesPage(QtWidgets.QWizardPage, DomainServicesBody):
    """One domain's services, one domain at a time — the image flow's host."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Domain services")
        self._init_body(scrollable(self))

    # ── body hooks ────────────────────────────────────────────────────────────────
    def _set_titles(self, title: str, subtitle: str) -> None:
        self.setTitle(title)
        self.setSubTitle(subtitle)

    def _scope_cfg(self):
        return self.wiz.cfg

    def _entries(self):
        """The worklist rows this wizard is carrying, or () — the per-node half of the
        state column. Tolerant on purpose: pages are constructed before WorklistPage has
        ever run, and a cloud flow has no worklist at all."""
        wl = getattr(self.wiz, "worklist", None)
        return list(getattr(wl, "entries", None) or ())

    # ── flow ──────────────────────────────────────────────────────────────────────
    def applies_to(self, cfg) -> bool:
        """On EVERY mesh flow (the mesh's own domain always has a services page —
        ``implicit_own_domain``), and otherwise wherever the Domains table is, when
        it names at least one domain.

        Emission-neutral when skipped, in the strong sense the nextId() ALL-OPTIONS
        guard asks for: a cloud node names no domain, so there is nothing to record,
        nothing to write to cfg — and nothing for the build/mesh-start gate to refuse
        either, so skipping cannot smuggle a domain past it. Standalone is skipped
        statically (MODE_SKIPPED_PAGES). The predicate is core's
        (``services_page_applies``) so the TUI walk asks the same question."""
        return services_page_applies(cfg)

    def initializePage(self):
        cfg = self.wiz.cfg
        self._load(cfg, domain_names_for_services(cfg), implicit_own_domain(cfg))

    def validatePage(self):
        """Record (see ``DomainServicesBody._record``); always True — the refusal
        belongs at the build/mesh-start screens, where it can be acted on."""
        self._record(self.wiz.cfg)
        return True

    def cleanupPage(self):
        """Qt calls this on the page the operator is leaving by clicking BACK.

        Record there too. ``QWizard`` calls ``validatePage`` only going FORWARD, so
        without this a Back out of this step left the Domains table's read-only cell
        reading "not configured yet" for a domain the operator had just walked, and
        the reviewed marker unwritten until something else happened to call
        ``collect_all()``. Recording is this page's whole job and it never refuses, so
        doing it in both directions is the same operation, not a new one.

        The base implementation resets registered fields; this page registers none.
        """
        self.validatePage()


class DomainServicesWidget(QtWidgets.QWidget, DomainServicesBody):
    """The SAME body as a plain widget, for a host that is not a wizard page of the
    image flow — the generate-a-new-local-mesh route embeds it on its ‘Domain
    services’ step (``pages/localmesh.py``) and drives :meth:`load` / :meth:`record`
    with a ``core.local_mesh_domains.LocalMeshDomains``.

    ``scope_cfg`` / ``entries`` are callables returning what the read-only
    "not domain-scoped" table reads its state column from; ``lane_note`` is the one
    sentence saying what this lane does with the selection."""

    def __init__(self, scope_cfg=None, entries=None, lane_note: str = "",
                 parent=None):
        super().__init__(parent)
        self._scope_cfg_fn = scope_cfg
        self._entries_fn = entries
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.title_label = QtWidgets.QLabel("")
        self.title_label.setStyleSheet("font-weight: bold;")
        self.title_label.setWordWrap(True)
        lay.addWidget(self.title_label)
        self.subtitle_label = QtWidgets.QLabel("")
        self.subtitle_label.setWordWrap(True)
        self.subtitle_label.setStyleSheet(muted())
        lay.addWidget(self.subtitle_label)
        self._init_body(lay)
        if lane_note:
            self.lane_note.setText(lane_note)
            self.lane_note.setVisible(True)

    def _set_titles(self, title: str, subtitle: str) -> None:
        self.title_label.setText(title)
        self.subtitle_label.setText(subtitle)

    def _scope_cfg(self):
        return self._scope_cfg_fn() if self._scope_cfg_fn else None

    def _entries(self):
        return list(self._entries_fn() or ()) if self._entries_fn else []

    def load(self, cfg) -> None:
        """Enter the walk for ``cfg`` (its named rows, in table order). A state that
        names its own domain as a REAL row (``LocalMeshDomains.own_name``) gets the
        "(this mesh's own domain)" header on it; an ImageConfig's is implicit."""
        own = implicit_own_domain(cfg) or (getattr(cfg, "own_name", "") or "").strip()
        self._load(cfg, domain_names_for_services(cfg), own)

    def record(self, cfg) -> None:
        """Write the working selections and the reviewed marker onto ``cfg``."""
        self._record(cfg)

    def reload(self, cfg) -> None:
        """Drop every working answer and re-enter the walk from ``cfg``.

        For a host that REPLACED the rows under the stepper (a saved-mesh record
        applied to the form): ``load`` keeps the working copy while the config object
        is the same, which is right for the Domains step's edits and wrong for a
        wholesale replacement — the stale copy would be written back over the loaded
        rows on the step's next record."""
        self._cfg_seen = None
        self.load(cfg)


def pending_gate_domains(cfg) -> list[str]:
    """Thin re-export so a caller holding only this module can ask the gate's
    question without reaching past it into core."""
    return unconfigured_domains(cfg)
