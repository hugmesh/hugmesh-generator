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

All four through the single override point ``core.domain_services.gate_reason`` so a test can
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

ONE EXCEPTION, BY RULING: THE TOR FRONT DOOR (#582, decision 68 = A on #347). "A Tor
domain = its own HiddenService stanza fronting the SAME gateway, distinguished by the
onion Host." So every domain but the mesh's own gets a ‘Tor front door’ row with scope
"onion (per domain)", writing ``Domain.tor`` — never ``optional_services``. The node
still has to RUN Tor, which stays node-scoped and read-only below (the ``tor`` row);
the inline ``tor_note`` says when it is off, which login the onion will serve (a
domain on the superdomain's sign-in serves the default brand over its onion), and WHAT
THIS ROUTE DOES WITH THE TICK — only the local docker mesh acts on it today; node
images record it in the mesh manifest and no builder reads it yet
(``core.domain_services.TOR_REACH``). The assert admits ``PER_DOMAIN_INFRA`` and
nothing else; egress-vpn, workloadConsole and anubis are unchanged.

THE SELECTION COLUMN HAS ITS OWN WIDTH RULE (#647). The operator could not see where to
tick a service: the column holding the checkboxes was sized to its header text, and a
service row's cell starts two indentation steps in (the group row, then the row), so
under the old two-letter header the cell was ZERO pixels wide and the checkbox was never
drawn. They renamed the header to "Selection" (PR #646), which made the column wide
enough at the default font and no more. ``fit_selection_column`` replaces the guess:
the column is as wide as its header OR the deepest checkbox row needs, whichever is
more, on both tables of this body and therefore on every host of it (this page, the
local docker mesh's step, the fleet's step). It is re-applied when the style or font
changes, and a click anywhere in a row's Selection cell ticks that row.

THE TWO CHECKBOX TABLES ARE AS TALL AS THEIR ROWS (#647, looked at again). The
services table floored at 300 px while its eleven rows end near 180 px, and the
front-door table took 90 px for one row — about 170 px of blank table, which pushed
the front door's state line (``tor_note``: which login the onion serves, that Tor must
be on for the mesh, what THIS route does with the tick) under the fold of the local
docker mesh step and the fleet step at the wizard's default size. ``fit_table_height``
gives each of the two tables a fixed height of exactly its header plus its rows (and
its frame), re-applied on every rebuild and clear (a domain carrying a slug this
catalogue does not offer has one group and one row more than its neighbour), on a
style or font change and when a group row is folded — so the page scrolls only for
what is really below, and a squeezed window scrolls the page rather than shrinking
a table onto an inner scrollbar. The read-only "not domain-scoped" table keeps Qt's default height: it
sits below the state line, and its wide "where" column shows a horizontal scrollbar at
the default width, which this rule does not account for. The state line is laid out as
the front-door table's CAPTION — directly under it, with no layout gap — because it
describes that one row and the two read as one thing.

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
BUILD gate names the own domain too (#631 — ``core.domain_services.
OWN_DOMAIN_GATED_ACTIONS``), because a config LOADED on the Sessions screen that never
opened this page used to build; the docker MESH START and the previous-builds RESTART
stay rows-only — the first because the local-docker route an operator reaches after
clicking "Mesh node" first has no such step (a dead end), the second because a recorded
session from before the own domain had a page must not be refused over it.

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

from types import SimpleNamespace

from ..qt import Qt, QtCore, QtWidgets
from ..styles import MUTED, WARN, muted
from ._scroll import scrollable
from .brand_screen import BrandSettingsTabs
from ...core import plain_words
from ...tui.brand_step import brand_view
from ...core.domain_services import (
    DOMAIN_CATALOGUE, ENFORCEMENT_NOTE, OTHER_SCOPE_HEADERS, PER_DOMAIN_INFRA,
    SCOPE_BINDS, SCOPE_DOMAIN, SCOPE_IMAGE, SCOPE_LABELS, SCOPE_NODE, SCOPE_ONION,
    SCOPE_WHERE, TOR_OWN_DOMAIN_NOTE, TOR_ROW_DESC, TOR_ROW_LABEL,
    carried_over_slugs, describe, describe_carried_over, domain_names_for_services,
    grouped_domain_catalogue, implicit_own_domain, normalise_slugs,
    other_scope_rows, record_reviewed, reviewed_names, scope_of,
    services_page_applies, tor_row_state, tor_row_warns, unconfigured_domains,
)

#: Table columns. ``_COL_SCOPE`` (#497) says what each row BINDS, on the row itself and
#: not in a tooltip — "the operator can see, without reading source, which of their
#: choices binds the domain, which binds the image, and which binds a node", and a hover
#: is not seeing. ``_COL_SETTING`` is deliberately present and empty: it is where the
#: per-service source forge / credential fields of #499 land without another restructure
#: (see the module docstring).
_COL_ON, _COL_NAME, _COL_SCOPE, _COL_SETTING, _COL_DESC = range(5)
_HEADERS = ("Selection", "Service", "Scope", "", "What it does for this domain")

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
        for k in (SCOPE_DOMAIN, SCOPE_ONION, SCOPE_IMAGE, SCOPE_NODE))


#: Clear space, in pixels, kept on each side of a Selection-column checkbox (#647).
_SELECTION_PAD = 4


def _cell_offset(table, item) -> int:
    """How far ``item``'s first-column cell starts from the column's left edge. Qt's
    own rule (QTreeView::indentationForItem): one indentation step per ancestor, plus
    one more when the root is decorated."""
    depth = 1 if table.rootIsDecorated() else 0
    parent = item.parent()
    while parent is not None:
        depth += 1
        parent = parent.parent()
    return depth * table.indentation()


def _all_items(item):
    yield item
    for i in range(item.childCount()):
        yield from _all_items(item.child(i))


def selection_column_width(table) -> int:
    """The width the Selection column needs (#647): its header's own width, or what
    the most indented checkbox row needs to show its whole checkbox, whichever is more.

    A row's checkbox is a widget placed in the cell (``setItemWidget``), and the view's
    content-sized columns do not add the row's indentation to such a widget's width —
    which is how a column exactly as wide as the indentation came to hide it. So the
    need is computed here, from the row's real offset and the checkbox's own size hint
    (never less than the style's indicator width), and it follows whatever style,
    font scale or stylesheet is in force."""
    indicator = table.style().pixelMetric(
        QtWidgets.QStyle.PixelMetric.PM_IndicatorWidth, None, table)
    need = 0
    for i in range(table.topLevelItemCount()):
        for item in _all_items(table.topLevelItem(i)):
            box = table.itemWidget(item, _COL_ON)
            if box is None:
                continue
            need = max(need, _cell_offset(table, item)
                       + max(indicator, box.sizeHint().width())
                       + 2 * _SELECTION_PAD)
    return max(table.header().sectionSizeHint(_COL_ON), need)


def fit_selection_column(table) -> None:
    """Apply the Selection column's width rule to ``table`` — a fixed section of
    :func:`selection_column_width`, so neither the header text nor a content-sized
    guess decides whether the checkboxes can be seen."""
    hdr = table.header()
    hdr.setSectionResizeMode(_COL_ON, QtWidgets.QHeaderView.ResizeMode.Fixed)
    hdr.resizeSection(_COL_ON, selection_column_width(table))


def table_content_height(table) -> int:
    """The height that shows every row of ``table`` at once: its header, every row
    that is on screen (a folded group's children count for nothing) and its frame.
    Row heights are the view's own (``visualItemRect``), so a checkbox widget in a
    row, a bigger font or another style's taller rows are all counted."""
    hdr = table.header()
    h = 0 if hdr.isHidden() else hdr.sizeHint().height()
    for i in range(table.topLevelItemCount()):
        for item in _all_items(table.topLevelItem(i)):
            h += table.visualItemRect(item).height()
    return h + 2 * table.frameWidth()


def fit_table_height(table) -> None:
    """Give ``table`` a fixed height of exactly :func:`table_content_height` (#647): no
    blank rows below the last one, no inner scrollbar hiding the last one, and a page
    that scrolls for what is really there. Set only when it changed, so a refit
    triggered by the resize it causes is a no-op rather than a loop.

    Not accounted for: a horizontal scrollbar inside the table, which would cover
    the bottom of the last row. On the two checkbox tables that needs a window
    narrower than their four fixed columns (about 330 px), below the wizard's own
    minimum width."""
    h = table_content_height(table)
    if table.minimumHeight() != h or table.maximumHeight() != h:
        table.setFixedHeight(h)


def fit_table(table) -> None:
    """Both rules of a checkbox table (#647): the Selection column's width and the
    table's height."""
    fit_selection_column(table)
    fit_table_height(table)


class _TableFitKeeper(QtCore.QObject):
    """Re-applies :func:`fit_table` when the table's style or font changes (a theme
    switch, a stylesheet with a bigger checkbox: the width that fitted the old
    checkbox would clip the new one, and the height that fitted the old rows would
    hide the last of the new ones) and when a group row is folded or unfolded.
    Deferred to the next event-loop turn, because a style or font change reaches
    the table before it reaches the checkboxes inside it. A plain resize is not
    watched: no row's height depends on the table's width (nothing wraps)."""

    def __init__(self, table):
        super().__init__(table)
        self._table = table
        table.installEventFilter(self)
        table.itemExpanded.connect(self._later)
        table.itemCollapsed.connect(self._later)

    def _later(self, *_args) -> None:
        QtCore.QTimer.singleShot(0, self.refit)

    def eventFilter(self, obj, event):          # noqa: N802 (Qt override)
        # Guarded: PyQt6 aborts the process on an exception escaping a Qt override.
        try:
            if event.type() in (QtCore.QEvent.Type.StyleChange,
                                QtCore.QEvent.Type.FontChange):
                self._later()
        except Exception:                      # noqa: BLE001
            pass
        return False

    def refit(self) -> None:
        try:
            fit_table(self._table)
        except Exception:                      # noqa: BLE001 — the table is gone
            pass


def _layout_widgets(layout, start: int = 0) -> list:
    """Every widget in ``layout`` from item ``start`` on, nested layouts included, in
    layout order (the services tab's content: see ``BrandSettingsTabs``)."""
    out = []
    for i in range(start, layout.count()):
        item = layout.itemAt(i)
        w = item.widget()
        if w is not None:
            out.append(w)
            continue
        inner = item.layout()
        if inner is not None:
            out += _layout_widgets(inner)
    return out


def _offerable(slug: str) -> bool:
    """Whether ``slug`` may become a per-domain CHECKBOX on this page: a domain-scoped
    catalogue slug, or one of the per-domain infra slugs (``tor`` alone — decision 68
    = A on #347, #582). The #227 rule for every other infra slug is unchanged."""
    return scope_of(slug) == SCOPE_DOMAIN or slug in PER_DOMAIN_INFRA


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
        #: domain name -> its own Tor front door (#582, ``Domain.tor``). Kept APART
        #: from ``_selection`` on purpose: the front door is a field of its own and
        #: must never land in ``optional_services`` (the unread slot it replaced).
        self._tor: dict[str, bool] = {}
        #: the front-door row + its checkbox for the domain on screen (None for the
        #: mesh's own domain, whose front door IS the primary onion — no control).
        self._tor_item: QtWidgets.QTreeWidgetItem | None = None
        self._tor_box: QtWidgets.QCheckBox | None = None

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

        # ── BRAND SETTINGS: the four tabs (#654, D9) ─────────────────────────────────
        # Identity | Look | Services | Ways to reach it. The tab bar and the three other
        # tabs' pages sit HERE, in this layout; everything the body has always drawn
        # below this point IS the Services tab (it stays in this layout, under this
        # parent, in this order — #647's looks pin all three) and is the tab that is
        # open when the step opens, so the page a person has always walked is the page
        # they see. A host with no brand record on offer (``_brand_session`` is None)
        # draws no tab bar: just the services body, exactly as before.
        self.brand_tabs = BrandSettingsTabs(route=self._brand_route())
        self.brand_tabs.mount(lay)
        self.brand_tabs.bar.setToolTip(
            f"The settings of one brand under the {plain_words.term('superbrand')}")
        # The Ways tab's Tor tick and the Services tab's front door are ONE choice: the
        # working value lives here (``_tor``, recorded onto ``Domain.tor`` by _record),
        # and each control shows what the other set.
        self.brand_tabs.tor_changed.connect(self._on_tabs_tor)
        self.brand_tabs.row_changed.connect(self._on_tabs_row_changed)
        _services_from = lay.count()

        # ── the domain's FRONT DOOR (#582, decision 68 = A) ────────────────────────
        # Its own table, not a group in the services table below: that table IS the
        # per-domain service catalogue (every row a domain-scoped service, grouped by
        # SERVICE_GROUPS), and the Tor front door is not a service of the domain — it
        # is how the domain is REACHED. Same columns, so the Scope column still says
        # what it binds on the row itself.
        #
        # ABOVE the services, right under the domain navigation, on purpose (#647,
        # looked at again at a 120 and 144 font DPI): the catalogue is a dozen rows
        # plus three paragraphs of prose, and anything laid out under it is the first
        # thing a shorter viewport pushes below the fold — measured at the wizard's
        # default size, the front door's row and its state line were off screen at a
        # 13.5 pt face (what a forced font DPI of 144 gives a 9 pt face) and on any
        # logical screen shorter than about 700 px (a 1366x768 laptop at 125 %
        # scaling). One row and one line, placed before the long list, are on screen
        # at every one of those; the list, which is expected to scroll, scrolls. The
        # TUI step prints the same order (decision 71 = A).
        self.front_door_table = QtWidgets.QTreeWidget()
        self.front_door_table.setColumnCount(len(_HEADERS))
        # The SAME header word as the services table's checkbox column — the
        # operator's own (PR #646) — never a second spelling of it.
        self.front_door_table.setHeaderLabels([_HEADERS[_COL_ON], "Front door",
                                               "Scope", "",
                                               "What it does for this domain"])
        self.front_door_table.setRootIsDecorated(False)
        self.front_door_table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        # No maximum height either: one row, one row's height (fit_table_height).
        fd_hdr = self.front_door_table.header()
        fd_hdr.setStretchLastSection(True)
        for c in (_COL_NAME, _COL_SCOPE, _COL_SETTING):
            fd_hdr.setSectionResizeMode(
                c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)

        # The front door's live state — inline, never a modal: which login the
        # domain's onion serves, and whether Tor runs on this mesh at all. Repainted
        # on every toggle of the row's checkbox. Laid out as the table's CAPTION: the
        # two share one block with no gap between them, so the line reads as part of
        # the row it describes and sits as high on the page as the row itself.
        self.tor_note = QtWidgets.QLabel("")
        self.tor_note.setWordWrap(True)
        self.tor_note.setStyleSheet(muted())
        front_door_block = QtWidgets.QVBoxLayout()
        front_door_block.setSpacing(0)
        front_door_block.setContentsMargins(0, 0, 0, 0)
        front_door_block.addWidget(self.front_door_table)
        front_door_block.addWidget(self.tor_note)
        lay.addLayout(front_door_block)

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
        # No minimum height: the table is as tall as its rows (fit_table_height),
        # never a 300 px floor with blank space under eleven rows.
        hdr = self.table.header()
        hdr.setStretchLastSection(True)
        for c in (_COL_NAME, _COL_SCOPE, _COL_SETTING):
            hdr.setSectionResizeMode(
                c, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hdr.setToolTip(_scope_legend())
        lay.addWidget(self.table)

        # ── the two rules of a checkbox table (#647), on BOTH tables ───────────────
        # The Selection column's width and the table's height. Applied here (so even
        # an empty table has them), again after every rebuild (the rows decide both)
        # and on a style or font change or a folded group (the keepers).
        # A click anywhere in a row's Selection cell ticks that row: ``itemClicked``
        # fires for a real mouse click only, never for a programmatic change, and a
        # click the checkbox itself takes never reaches the table — so no click is
        # ever counted twice.
        self._fit_keepers = []
        for t in (self.table, self.front_door_table):
            fit_table(t)
            self._fit_keepers.append(_TableFitKeeper(t))
            t.itemClicked.connect(
                lambda item, column, _t=t: self._on_cell_clicked(_t, item, column))

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
        self.brand_tabs.adopt_services(_layout_widgets(lay, _services_from))
        self.brand_tabs.set_active(False)

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

    def _brand_session(self):
        """The superbrand session of this host (``tui.superbrand_step.BrandSession``),
        or None when the host offers no brand record: the four tabs then stay hidden."""
        return None

    def _brand_route(self) -> str:
        """Which start path this host is on ("image", "docker" or "fleet"): the look
        editor draws a brand's own look enabled only where something can show it."""
        return "image"

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
            self._tor = {}
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
        # The Tor front door, by the same rule: a surviving name keeps its working
        # answer, a new one starts from its row's ``tor``. The mesh's OWN domain has
        # none — implicit (image flow) or row 0 (local mesh) alike, its front door is
        # the primary onion, so there is nothing to choose and nothing to record.
        self._tor = {name: (self._tor[name] if name in self._tor
                            else bool(getattr(rows.get(name), "tor", False)))
                     for name in self._names if name != self._own_name}
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
            self.front_door_table.clear()
            self._tor_item = self._tor_box = None
            self.tor_note.setText("")
            self.other_table.clear()
            self._other_rows = {}
            self.remaining.setText("")
            self.prev_btn.setEnabled(False)
            self.next_btn.setEnabled(False)
            self.brand_tabs.set_active(False)
            fit_table(self.table)
            fit_table(self.front_door_table)
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
        self._refresh_brand_tabs(name)
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

    def _refresh_brand_tabs(self, name: str) -> None:
        """Point the four tabs at the domain on screen (the mesh's own domain is the
        superbrand's row). Never raises: a slot must not take the Studio down."""
        try:
            session = self._brand_session()
            self.brand_tabs.set_active(session is not None)
            if session is None:
                self.brand_tabs.set_view(None)
                return
            self.brand_tabs.set_view(brand_view(
                session, name, own=bool(name) and name == self._own_name))
            self.brand_tabs.show_tor(name in self._tor, bool(self._tor.get(name, False)))
        except Exception:                       # noqa: BLE001 — PyQt6 qFatal guard
            import sys
            import traceback
            print("domain_services: swallowed exception in _refresh_brand_tabs",
                  file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def commit_brand(self, *, save: bool = False) -> list[str]:
        """Write what the Brand settings tabs changed (a brand's look is written as it
        is edited; the superbrand block and the record file here). Returns the problems,
        which the host shows; recording never refuses (see ``_record``)."""
        session = self._brand_session()
        if session is None:
            return []
        try:
            return session.commit(save=save)
        except Exception:                       # noqa: BLE001
            return []

    def _rebuild(self, name: str) -> None:
        """Rebuild the checkbox table for ``name``. Cheap (8 rows plus any carried-over
        slug), and rebuilding is what keeps a per-domain extra from leaking onto the
        next domain's screen."""
        self.table.clear()
        self._rows, self._boxes = {}, {}
        self._tor_item = self._tor_box = None
        chosen = set(self._selection.get(name, []))
        for group, slugs in grouped_domain_catalogue():
            gitem = self._group_row(group)
            for slug in slugs:
                # The scope rule of #227, kept as an assert rather than a comment: a
                # node/cluster-plane slug must never become a per-domain checkbox.
                # RELAXED for ``tor`` ALONE (decision 68 = A, #582) — see _offerable.
                assert _offerable(slug), \
                    f"{slug} is not domain-scoped and must not be offered per domain"
                self._svc_row(gitem, slug, slug, describe(slug), slug in chosen)
        extras = carried_over_slugs(self._selection.get(name, []))
        if extras:
            gitem = self._group_row("From your config")
            for slug in extras:
                self._svc_row(gitem, slug, slug + _EXTRA_NOTE,
                              describe_carried_over(slug), True)
        # ── the per-domain infra slugs: today exactly one, the Tor front door ──────
        self.front_door_table.clear()
        for slug in PER_DOMAIN_INFRA:
            assert _offerable(slug), \
                f"{slug} is not domain-scoped and must not be offered per domain"
            self._front_door_row(name)
        self._paint_tor_note()
        fit_table(self.table)
        fit_table(self.front_door_table)

    def _on_cell_clicked(self, table, item, column: int) -> None:
        """A click in a row's Selection cell, outside the checkbox itself (#647)."""
        try:
            if column != _COL_ON:
                return
            box = table.itemWidget(item, _COL_ON)
            if isinstance(box, QtWidgets.QCheckBox) and box.isEnabled():
                box.toggle()
        except Exception:                      # noqa: BLE001 — a Qt slot must not raise
            pass

    def _front_door_row(self, name: str) -> None:
        """The domain's own Tor front door (#582). A checkbox for every domain except
        the mesh's OWN one, whose front door is the primary onion — that row is data,
        exactly like the #497 rows (the check flag is cleared, not merely unset)."""
        item = QtWidgets.QTreeWidgetItem(self.front_door_table)
        item.setText(_COL_NAME, TOR_ROW_LABEL)
        item.setText(_COL_SCOPE, SCOPE_LABELS[SCOPE_ONION])
        item.setToolTip(_COL_SCOPE, f"Set {SCOPE_WHERE[SCOPE_ONION]}; binds "
                                    f"{SCOPE_BINDS[SCOPE_ONION]}.")
        self._tor_item = item
        if name not in self._tor:
            item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsUserCheckable)
            item.setText(_COL_DESC, TOR_OWN_DOMAIN_NOTE)
            item.setToolTip(_COL_DESC, TOR_OWN_DOMAIN_NOTE)
            return
        item.setText(_COL_DESC, TOR_ROW_DESC)
        item.setToolTip(_COL_DESC, TOR_ROW_DESC)
        box = QtWidgets.QCheckBox()
        box.setChecked(bool(self._tor.get(name, False)))
        box.toggled.connect(self._on_tor_toggled)
        self.front_door_table.setItemWidget(item, _COL_ON, box)
        self._tor_box = box

    def _on_tor_toggled(self, checked: bool) -> None:
        """Repaint the inline state, and the Ways tab's tick (the same choice).
        Guarded: PyQt6 qFatals on a slot exception."""
        try:
            name = self.current_domain()
            if name in self._tor:
                self._tor[name] = bool(checked)
            self._paint_tor_note()
            self.brand_tabs.show_tor(name in self._tor, bool(checked))
        except Exception:                      # noqa: BLE001
            pass

    def _on_tabs_tor(self, on: bool) -> None:
        """The Ways tab's Tor tick: the same working value as the front door, which
        repaints its own state line; the row's ``tor`` follows at once so the Ways tab's
        summary says it too (``_record`` writes the same value again)."""
        try:
            name = self.current_domain()
            if name not in self._tor:
                return
            self._tor[name] = bool(on)
            if self._tor_box is not None:
                self._tor_box.setChecked(bool(on))
            view = self.brand_tabs.view
            if view is not None and not view.own:
                view.set_tor(bool(on))
            self._paint_tor_note()
        except Exception:                      # noqa: BLE001
            pass

    def _on_tabs_row_changed(self) -> None:
        """A sign-in or reach change on the tabs: the front door's line names which
        login the domain's onion opens, so it is repainted."""
        try:
            self._paint_tor_note()
        except Exception:                      # noqa: BLE001
            pass

    def _tor_view(self, name: str):
        """A row-shaped view of ``name``'s front door AS IT STANDS ON SCREEN (the box,
        not the last recorded value), for core's wording functions."""
        cfg = self._cfg_seen
        row = next((d for d in (getattr(cfg, "domains", None) or [])
                    if (getattr(d, "name", "") or "").strip() == name), None)
        on = (self._tor_box.isChecked() if self._tor_box is not None
              else bool(self._tor.get(name, False)))
        return SimpleNamespace(name=name, tor=on, idp=getattr(row, "idp", ""))

    def _tor_rows(self, current):
        """Every walked domain's front door as it stands in this walk, in walk order —
        what core needs to see two domains that would share one key directory."""
        return [current if n == current.name
                else SimpleNamespace(name=n, tor=bool(self._tor.get(n, False)))
                for n in self._names]

    def _paint_tor_note(self) -> None:
        name = self.current_domain()
        if not name:
            self.tor_note.setText("")
            return
        view = self._tor_view(name)
        args = (view, self._scope_cfg(), self._entries(), self._own_name)
        kw = {"walked": self._cfg_seen, "domains": self._tor_rows(view)}
        text = tor_row_state(*args, **kw)
        self.tor_note.setText(f"{TOR_ROW_LABEL}: {text}")
        self.tor_note.setStyleSheet(
            f"color: {WARN};" if tor_row_warns(*args, **kw) else muted())
        if self._tor_item is not None:
            self._tor_item.setToolTip(_COL_NAME, text)

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
        if self._tor_box is not None and name in self._tor:
            self._tor[name] = self._tor_box.isChecked()

    def selected_slugs(self, name: str | None = None) -> list[str]:
        """The slugs recorded for ``name`` (the current domain by default) — the API
        tests read the page through, the twin of ``_ServicesButton.selected_slugs``."""
        if name is None:
            self._capture()
            name = self.current_domain()
        return list(self._selection.get(name, []))

    def tor_front_door(self, name: str | None = None) -> bool:
        """Whether ``name`` (the current domain by default) has its own Tor front door
        in this walk — the API tests read the row through (#582)."""
        if name is None:
            self._capture()
            name = self.current_domain()
        return bool(self._tor.get(name, False))

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
            if name in self._tor:
                d.tor = bool(self._tor[name])
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

    def _brand_session(self):
        """The image route's superbrand session — on a mesh only (a standalone image
        has no brands to configure per domain)."""
        from ...tui.superbrand_step import session_for
        cfg = self.wiz.cfg
        if getattr(cfg, "mode", "") != "mesh":
            return None
        return session_for(self.wiz, "image", cfg,
                           getattr(self.wiz, "generator_dir", "") or "")

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

        Leaves the output unchanged when skipped, in the strong sense the nextId() ALL-OPTIONS
        guard asks for: a cloud node names no domain, so there is nothing to record,
        nothing to write to cfg — and nothing for the build/mesh-start gate to refuse
        either, so skipping cannot smuggle a domain past it. Standalone is skipped
        statically (MODE_SKIPPED_PAGES). The predicate is core's
        (``services_page_applies``) so the TUI walk asks the same question."""
        return services_page_applies(cfg)

    def initializePage(self):
        cfg = self.wiz.cfg
        self._load(cfg, domain_names_for_services(cfg), implicit_own_domain(cfg))

    def forget_answers(self) -> None:
        """Drop every working answer: the rows were REPLACED under this page on the
        SAME configuration object (the ``DomainServicesWidget.reload`` case, for the
        wizard host). ``_load`` keeps a surviving name's working selection and unions
        the working reviewed set with the configuration's, which is right for the
        Domains table's edits and wrong for a wholesale replacement — after a second
        "Create nodes for local cloud" import an earlier walk's selection would be
        written back over the record's, and its marker would let a domain the record
        says nobody walked pass the build gate (post-merge review of PR #644). Until
        the page is next entered ``_record`` writes nothing (its own guard), so a
        ``collect_all()`` re-run cannot carry the stale answers across either."""
        self._cfg_seen = None

    def validatePage(self):
        """Record (see ``DomainServicesBody._record``); always True — the refusal
        belongs at the build/mesh-start screens, where it can be acted on."""
        self._record(self.wiz.cfg)
        self.commit_brand(save=True)
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
                 brand_session=None, route: str = "docker", parent=None):
        super().__init__(parent)
        self._scope_cfg_fn = scope_cfg
        self._entries_fn = entries
        #: ``brand_session`` is a callable returning the host's superbrand session (or
        #: None); ``route`` names its start path. A host with neither shows no tabs.
        self._brand_session_fn = brand_session
        self._route = route
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

    def _brand_session(self):
        return self._brand_session_fn() if self._brand_session_fn else None

    def _brand_route(self) -> str:
        return self._route

    def set_brand_session(self, brand_session, route: str | None = None) -> None:
        """Give a host that built this widget without one (the Docker route's step) its
        superbrand session after the fact, and re-draw the tabs for the domain on screen."""
        self._brand_session_fn = brand_session
        if route:
            self._route = route
            self.brand_tabs.route = route
        if self._names:
            self._show()

    def load(self, cfg) -> None:
        """Enter the walk for ``cfg`` (its named rows, in table order). A state that
        names its own domain as a REAL row (``LocalMeshDomains.own_name``) gets the
        "(this mesh's own domain)" header on it; an ImageConfig's is implicit."""
        own = implicit_own_domain(cfg) or (getattr(cfg, "own_name", "") or "").strip()
        self._load(cfg, domain_names_for_services(cfg), own)

    def record(self, cfg) -> None:
        """Write the working selections and the reviewed marker onto ``cfg``."""
        self._record(cfg)
        self.commit_brand()

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
