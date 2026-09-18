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
* ``gui/pages/localmesh.py`` refuses the docker mesh start,

both through the single seam ``core.domain_services.gate_reason`` so a test can drive
the refusal with a bare ``ImageConfig``.

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

WHERE #499 (per-service source forge + credentials) GOES: each service row is a
QTreeWidgetItem in ``self._rows`` keyed by slug, and the table already carries a
per-row settings column that is empty today. A forge/repo/branch control per row hangs
off ``_SVC_COL_SETTING`` with no restructure; a per-DOMAIN credential belongs in the
header block beside ``self.head``, which is already per-domain state.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ..styles import MUTED, WARN, muted
from ._scroll import scrollable
from ...core.config import superadmin_plane_applies
from ...core.domain_services import (
    DOMAIN_CATALOGUE, ENFORCEMENT_NOTE, SCOPE_DOMAIN, carried_over_slugs, describe,
    describe_carried_over, grouped_domain_catalogue, normalise_slugs,
    record_reviewed, reviewed_names, scope_of, unconfigured_domains,
)

#: Table columns. ``_SVC_COL_SETTING`` is deliberately present and empty: it is where
#: the per-service source forge / credential fields of #499 land without another
#: restructure (see the module docstring).
_COL_ON, _COL_NAME, _COL_SETTING, _COL_DESC = range(4)
_HEADERS = ("On", "Service", "", "What it does for this domain")

#: The label a carried-over slug wears — one this build's catalogue does not offer.
#: The row's DESCRIPTION says the rest (core.domain_services.describe_carried_over),
#: which keeps whatever the slug's own catalogue line says instead of replacing it.
_EXTRA_NOTE = "  (kept from your config)"



class DomainServicesPage(QtWidgets.QWizardPage):
    """One domain's services, one domain at a time."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Domain services")
        #: domain name -> the slugs chosen for it (the working copy; cfg is written
        #: at validatePage, which is also what ``collect_all`` calls).
        self._selection: dict[str, list[str]] = {}
        #: the domain names actually walked in this wizard run, plus whatever a loaded
        #: config already recorded.
        self._reviewed: set[str] = set()
        self._names: list[str] = []
        self._index = 0
        self._rows: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._boxes: dict[str, QtWidgets.QCheckBox] = {}

        lay = scrollable(self)

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
        for c in (_COL_ON, _COL_NAME, _COL_SETTING):
            hdr.setSectionResizeMode(
                c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        lay.addWidget(self.table)

        # ── how far through the domains this walk is ──────────────────────────────
        self.remaining = QtWidgets.QLabel("")
        self.remaining.setWordWrap(True)
        lay.addWidget(self.remaining)
        lay.addStretch(1)

    # ── flow ──────────────────────────────────────────────────────────────────────
    def applies_to(self, cfg) -> bool:
        """Shown wherever the Domains table is, and only when there is at least one
        NAMED domain to configure.

        Emission-neutral when skipped, in the strong sense the nextId() ALL-OPTIONS
        guard asks for: with no named domain there is nothing to record, nothing to
        write to cfg — and nothing for the build/mesh-start gate to refuse either, so
        skipping cannot smuggle a domain past it."""
        if not superadmin_plane_applies(cfg):
            return False
        return any((getattr(d, "name", "") or "").strip()
                   for d in (getattr(cfg, "domains", None) or []))

    def initializePage(self):
        cfg = self.wiz.cfg
        self._names = [d.name for d in (cfg.domains or [])
                       if (d.name or "").strip()]
        # Seed from cfg every entry: the Domains table may have added, renamed or
        # dropped rows since the last visit. A name that survived keeps its working
        # selection; a new one starts from whatever the manifest already carried.
        fresh: dict[str, list[str]] = {}
        for d in (cfg.domains or []):
            if not (d.name or "").strip():
                continue
            fresh[d.name] = (self._selection.get(d.name)
                             if d.name in self._selection
                             else normalise_slugs(d.optional_services))
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
            self.remaining.setText("")
            self.prev_btn.setEnabled(False)
            self.next_btn.setEnabled(False)
            return
        # BEING HERE IS GOING THROUGH IT. The operator is looking at this domain's
        # catalogue with its current selection ticked; that is the step the ask asks
        # for, and demanding a second "confirm" click would be a ceremony that adds no
        # information. Domains never shown stay unconfigured and the gate names them.
        self._reviewed.add(name)
        self.setTitle(f"Services for {name}")
        self.setSubTitle(
            f"Domain {self._index + 1} of {total} — every domain gets its own "
            "service page, and a domain you never open is refused at build time.")
        self.head.setText(
            f"<b>{name}</b> &nbsp;·&nbsp; domain {self._index + 1} of {total}")
        self.prev_btn.setEnabled(self._index > 0)
        self.next_btn.setEnabled(self._index < total - 1)
        self._rebuild(name)
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

    def validatePage(self):
        """RECORD, never refuse. Writes the per-domain selections onto ``cfg.domains``
        and the walked names onto ``cfg.domain_services_reviewed``.

        Always returns True on purpose. ``collect_all()`` re-runs a visited page's
        validatePage to harvest it, so a False here would make saving a config depend
        on where the operator happened to be standing — and the refusal the ask asks
        for belongs at the build/mesh-start screens, where it can be acted on, not on
        the page that is trying to collect the answer. The gate itself is
        ``core.domain_services.gate_reason``.

        Writes by NAME, never by index: the Domains table may have renamed, added or
        dropped rows between this page's last visit and this call."""
        self._capture()
        cfg = self.wiz.cfg
        for d in (cfg.domains or []):
            if d.name in self._selection:
                d.optional_services = list(self._selection[d.name])
        # REBUILT from the domains that still exist (record_reviewed does the
        # restriction), so a renamed or deleted domain cannot leave a stranded marker
        # that would let the gate pass for a domain nobody configured.
        record_reviewed(cfg, self._reviewed)
        return True

    # ── introspection for the gate's own callers/tests ───────────────────────────
    def unconfigured(self) -> list[str]:
        """The domains this walk has not been through yet, in table order."""
        return [n for n in self._names if n not in self._reviewed]


def pending_gate_domains(cfg) -> list[str]:
    """Thin re-export so a caller holding only this module can ask the gate's
    question without reaching past it into core."""
    return unconfigured_domains(cfg)
