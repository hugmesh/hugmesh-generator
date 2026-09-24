"""DomainsPage — the superadmin domains table (spec 4/5).

Each row is a :class:`~...core.config.Domain`: a name, a title, the per-domain
``optional_services`` slugs (G19) consumed by cluster provisioning via the mesh
manifest, and — in mesh mode — the worklist images it attaches to (``Domain.images``).
The services cell is READ-ONLY since issue #495 (``_ServicesCell``). It was a freeform
cell whose typos went into the manifest verbatim, then a checkable MENU (#227,
``_ServicesButton``) — but nothing obliged the operator to OPEN that menu, so most
builds never answered "what does this domain provide". The choice now has its own step,
``pages/domain_services.py``, which gives every domain its own service page and is what
the build/mesh-start gate requires; this cell REPORTS what that step recorded. It is a
MIRROR, not a store — ``validatePage`` takes each row's slugs from ``cfg`` by name and
falls back to the cell only for a row ``cfg`` does not know yet, because
``collect_all()`` re-enters itself through ``BuildPage._preview`` and would otherwise
make this page the last writer and discard the step's whole recording. This table
remains the sole writer of WHICH domains exist and of every other column. Those slugs are provisioning INPUT only — nothing in this repo reads
``domains[].optional_services`` back, they do not change which services the image bakes,
and #496 is why they do not yet decide what the cluster runs either.
The Games checkbox is GONE: a truthy legacy ``games`` is migrated to
``optional_services += ["games"]`` by ``ImageConfig.from_dict`` on load, so loaded rows
arrive pre-migrated and this page never sees a games flag again.

Row order is load-bearing: the first attached domain is the PRIMARY one (the first
``--domains`` element, which lands in ROLE_TAG / the filename). The page prefills row 0
with the cluster domain on a fresh cloud/mesh flow so a superadmin starts from a valid
primary domain (spec 4). The Tailscale root domain (spec 5) is shown read-only in
the header — every mesh node joins it, it is never a table row and never attachable.

The mesh-only 'Sign-in' column (issue #47) is each row's ``Domain.idp``: superdomain
(the mesh's central Casdoor — the default, today's behavior) vs own (this domain runs
its OWN Casdoor instance). It reaches provisioning via the mesh manifest and the local
compose lane via core/own_casdoor.py; an untouched/hidden combo always collects the
superdomain default, so pre-#47 flows and manifests are byte-identical.

The mesh-only 'Base CA' column (issue #335) is the per-domain half of the Vault
step's certificate list: it offers ``cfg.base_ca_certs`` and writes the choice to
``cfg.domain_ca[<domain name>]``. Two things about it are stated plainly rather than
implied:

* RECORDED, NOT YET CONSUMED. No builder parses a CA flag and no manifest emitter
  carries the choice, so picking a CA here changes no image and no provisioning
  input today — it records which authority a domain is meant to chain to. That is
  the same honest label the Vault page's KV mount and base path already wear.
* THE LIST IS FILLED ONE STEP LATER. ``WIZARD_PAGE_SLUGS`` puts "domains" before
  "vault", so on a first forward pass the certificate list is still empty and every
  row's picker offers only "None"; the cell says so instead of looking broken. The
  column repopulates from cfg on every entry, so Back from the Secrets store (or
  re-opening a saved config, where the certificates are already there) fills it. The
  page order was left alone on purpose — moving it is a wizard-wide change, not a
  column-wide one.

Removing a certificate on the Vault step clears every domain that pointed at it
(VaultPage.validatePage), and this page rebuilds ``cfg.domain_ca`` from the table
alone, so a renamed or deleted domain cannot leave a stranded entry behind.

ROW 0 IS THE MESH'S OWN DOMAIN (issue #494, reported 2026-09-23: "the checkbox doesn't
seem to be present on each domain page"). In mesh mode the table now opens with the
cluster domain as a DISPLAY-ONLY first row — name and title fixed (they are the Network
and Branding steps' fields), Applies-to / Sign-in / Base CA rendered as the facts they
are for the apex (every image, the central Casdoor, the mesh default) — so the operator
sees every domain this mesh serves in one place. It is NOT a ``cfg.domains`` row:
``validatePage`` skips it, ``_remove`` refuses it, and its services summary mirrors
``cfg.cluster_domain_services`` (written by the Domain services step, which walks the
own domain first — ``core.domain_services.implicit_own_domain``). So the ASK-8 guard is
untouched: an untouched flow emits no ``--domains`` and no manifest ``domains`` entry.

ONE TABLE, TWO HOSTS. The table, its cells and its row rules live on
:class:`DomainsTableBody`, a plain mixin: this page hosts it in the image flow and
:class:`DomainsTableWidget` hosts the SAME body on the generate-a-new-local-mesh route
(``pages/localmesh.py``), where the rows feed ``LocalMeshBootstrapConfig`` instead of
``ImageConfig``. Nothing is forked: the columns, the cell widgets, the read-only
services mirror and the own-row rules are one implementation.
"""
from __future__ import annotations

import os

from ..qt import Qt, QtWidgets
from ..styles import WARN, muted
from ...core.config import (CLIENT_CA_INHERITANCE_NOTE, DOMAIN_IDP_OWN,
                            DOMAIN_IDP_SUPERDOMAIN, Domain, image_class,
                            superadmin_plane_applies)
from ...core.domain_services import (implicit_own_domain, normalise_slugs,
                                     reviewed_names, services_summary, split_services)

_COL_NAME, _COL_TITLE, _COL_SERVICES, _COL_APPLIES = range(4)
# The per-domain sign-in column (issue #47) is APPENDED so the four pre-existing
# indices stay stable for every test/caller that pins them.
_COL_IDP = 4
# The per-domain base-CA column (issue #335) is APPENDED for the same reason — every
# earlier index, _COL_IDP included, keeps the position its tests already pin.
_COL_CA = 5
#: The combo's "this domain names no base CA" row. Its DATA is the empty string, which
#: is what ``cfg.domain_ca`` stores for "absent" — so the default row and a missing
#: key are the same fact, and an untouched table writes an empty dict.
_CA_NONE_LABEL = "None (mesh default)"
# node-role images take no --domains — the attachment is manifest/provisioning data
# only, so the menu never implies argv it cannot emit.
_NODE_NOTE = "  (manifest only — nodes take no --domains)"
#: The name item's UserRole marker on the mesh's OWN domain row (row 0 in mesh mode).
#: Tests and both hosts read it through :meth:`DomainsTableBody.is_own_row`.
_OWN_ROW = "own"
#: What the own row's three per-domain pickers READ AS for the apex: it attaches to
#: every image, its sign-in is the mesh's central Casdoor by definition, and it chains
#: to the mesh default. Rendered as labels, never as pickers with one legal answer.
_OWN_APPLIES = "All images (this mesh's own domain)"
_OWN_IDP = "Superdomain Casdoor (the mesh's central one)"
_OWN_CA = "Mesh default"
_OWN_TIP = ("This mesh's OWN domain — the cluster domain. It is always served, cannot "
            "be removed here, and its services are picked on the ‘Domain services’ "
            "step like every other domain's (it is that step's first page).")

# (schema value, combo label, per-item tooltip) for the Sign-in column. The DATA
# role carries the schema value — labels are free to change, tests read the data.
_IDP_ITEMS = (
    (DOMAIN_IDP_SUPERDOMAIN, "Superdomain Casdoor (default)",
     "Sign-in via the mesh's central Casdoor on the superdomain — today's "
     "behavior, nothing extra to run."),
    (DOMAIN_IDP_OWN, "Own Casdoor",
     "This domain runs its OWN Casdoor instance, provisioned just for it "
     "(its users sign in against that instance, not the mesh's central one)."),
)


class _IdpCombo(QtWidgets.QComboBox):
    """Per-row sign-in picker (issue #47): which Casdoor serves this domain.
    Tests read/write the choice through :meth:`selected_idp` / the data role."""

    def __init__(self, selected=DOMAIN_IDP_SUPERDOMAIN):
        super().__init__()
        for i, (value, label, tip) in enumerate(_IDP_ITEMS):
            self.addItem(label, value)
            self.setItemData(i, tip, Qt.ItemDataRole.ToolTipRole)
        idx = self.findData(selected or DOMAIN_IDP_SUPERDOMAIN)
        self.setCurrentIndex(idx if idx >= 0 else 0)

    def selected_idp(self) -> str:
        return self.currentData() or DOMAIN_IDP_SUPERDOMAIN


class _BaseCaCombo(QtWidgets.QComboBox):
    """Per-row base-CA picker (issue #335): which of the Vault step's certificates
    this domain chains to. Row 0 is always "None" with EMPTY data, so an untouched
    picker collects "" — the same fact as an absent ``cfg.domain_ca`` key.

    ``certs`` is ``cfg.base_ca_certs`` (absolute paths); the label is the file's base
    name and the DATA is the full path, so tests and the config read the path while
    the label stays free to change. A ``selected`` path no longer in ``certs`` falls
    back to None rather than being kept as a phantom row — the certificate really is
    gone, and VaultPage.validatePage has already cleared it from cfg."""

    def __init__(self, certs=(), selected=""):
        super().__init__()
        certs = list(certs)
        self.addItem(_CA_NONE_LABEL if certs else
                     "None — add certificates on the Secrets store step", "")
        self.setItemData(
            0,
            "This domain names no base CA: it chains to whatever the mesh already "
            "trusts. The default, and what every config written before this column "
            "existed carries.", Qt.ItemDataRole.ToolTipRole)
        for i, path in enumerate(certs, start=1):
            self.addItem(os.path.basename(path), path)
            self.setItemData(i, path, Qt.ItemDataRole.ToolTipRole)
        idx = self.findData(selected) if selected else 0
        self.setCurrentIndex(idx if idx >= 0 else 0)

    def selected_ca(self) -> str:
        """The chosen certificate PATH, or "" for None."""
        return self.currentData() or ""


class _AppliesToButton(QtWidgets.QToolButton):
    """Per-row 'Applies to' control (mesh only): a checkable menu of the worklist entry
    ids this domain attaches to. Empty selection = attach to every eligible image
    (``Domain.images == []``, rendered as 'All images'). Tests read/write the selection
    through :meth:`selected_ids`."""

    def __init__(self, entries, selected):
        super().__init__()
        self.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
        self.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        menu = QtWidgets.QMenu(self)
        self._actions: dict = {}          # entry id -> checkable QAction
        chosen = set(selected or [])
        for e in entries:
            label = e.id + (_NODE_NOTE if image_class("mesh", e.role) == "node" else "")
            act = menu.addAction(label)
            act.setCheckable(True)
            act.setChecked(e.id in chosen)
            act.setData(e.id)
            act.toggled.connect(self._refresh)
            self._actions[e.id] = act
        self.setMenu(menu)
        self._refresh()

    def selected_ids(self) -> list[str]:
        """The checked entry ids, in menu (worklist) order; [] = all eligible images."""
        return [rid for rid, a in self._actions.items() if a.isChecked()]

    def _refresh(self, *_):
        n = len(self.selected_ids())
        self.setText("All images ▾" if n == 0
                     else f"{n} image{'s' if n != 1 else ''} ▾")


def _split_services(services) -> list[str]:
    """Accept either a list of slugs or the legacy space/comma-separated string that
    every existing ``_add`` caller (and three test files) still passes. The rule itself
    lives in core (``domain_services.split_services``) now that the TUI step, the gate
    and this table all have to read a row the same way; this stays as the name the
    page's callers already import."""
    return split_services(services)


class _ServicesCell(QtWidgets.QLabel):
    """Per-row 'Optional services' cell — READ-ONLY since #495.

    It used to be ``_ServicesButton``, a checkable QMenu behind a toolbutton (#227).
    The menu was already per-domain and already honest about scope, but NOTHING
    obliged the operator to open it, so most builds never answered "what does this
    domain provide". The operator asked for the opposite: "for each domain, the
    service page needs to be config … a service page per domain you make you have to
    go through before building or starting a mesh in docker or nodes".

    So the choice moved to its own step (``pages/domain_services.py``) and this cell
    REPORTS it. It still carries the row's slugs, and ``DomainsPage.validatePage`` falls
    back to them for a row ``cfg`` does not know yet — a row just added, or renamed —
    but ``cfg`` is what it reads first, because this cell is refreshed only when the
    page becomes current and the step writes to ``cfg`` after that. A row added,
    renamed or removed here still decides which domains exist. It also distinguishes
    the state ``optional_services`` alone
    cannot express: ``[]`` means "the cluster-wide set applies", which is a real
    answer, and is NOT the same fact as "nobody has been through this domain's
    services yet" (the gate's, recorded in ``cfg.domain_services_reviewed``).

    Tests read/write the row through :meth:`selected_slugs` / :meth:`set_slugs` — the
    same two verbs the button offered."""

    _SET_ON_STEP = ("Picked on the ‘Domain services’ step, which gives every domain "
                    "its own service page. This cell shows what is recorded for this "
                    "row; an image build or a docker mesh start refuses while any "
                    "domain here has never been through that step.")

    def __init__(self, selected=None, reviewed: bool = False):
        super().__init__()
        self.setWordWrap(True)
        self.setToolTip(self._SET_ON_STEP)
        self._slugs: list[str] = []
        self.set_slugs(selected, reviewed)

    def set_slugs(self, selected=None, reviewed: bool = False) -> None:
        """Render the row. The WORDS come from ``core.domain_services.services_summary``
        and are not restated here: this cell used to carry its own copy of the same
        three branches, so the wording the whole honesty argument rests on had two
        sources of truth and the tested one was not the one on screen."""
        self._slugs = normalise_slugs(selected)
        self._reviewed = bool(reviewed)
        self.setText(services_summary(self._slugs, self._reviewed))
        # Never "None" and never a bare count: an unconfigured row must not read like a
        # configured empty one, so it is WARN-coloured as well as differently worded.
        # The reviewed-and-empty state is muted because "cluster default" is a real
        # answer, not an omission.
        self.setStyleSheet(f"color: {WARN};" if not self._reviewed
                           else (muted() if not self._slugs else ""))

    def selected_slugs(self) -> list[str]:
        """The row's slugs in CATALOGUE order, carried-over extras last.

        The order comes from the catalogue and deliberately NOT from any widget order —
        see ``core/domain_services.normalise_slugs`` for why a presentation regrouping
        must not be able to rewrite the bytes of ``domains[].optional_services``."""
        return list(self._slugs)


class DomainsTableBody:
    """The domains TABLE — columns, cell widgets, row rules — as a plain-Python mixin.

    A host calls :meth:`_init_table` with the layout to fill and overrides the hooks
    (:meth:`_cfg`, :meth:`_entries`, :meth:`_certs`, :meth:`_own_name_editable`).
    Every widget and every verb lives directly on the host object — no delegation —
    so ``DomainsPage`` keeps the attributes its tests read (``table``, ``_add``,
    ``_remove``, ``_refresh_*``) and ``DomainsTableWidget`` gets the same ones.

    THE OWN ROW. :meth:`_add_own` inserts the mesh's own domain as a display-only
    row 0 (marked ``_OWN_ROW`` on its name item); :meth:`rows` never returns it,
    :meth:`_remove` refuses it, and :meth:`_refresh_services_cells` mirrors its
    services from the host's ``cluster_domain_services`` (an ImageConfig) or from its
    own ``Domain`` row (the local-mesh state, where it IS a real row — see
    ``core/local_mesh_domains.py``)."""

    def _init_table(self, lay, *, with_applies: bool = True, with_ca: bool = True) -> None:
        self._with_applies = with_applies
        self._with_ca = with_ca
        # 'Optional services' fills Domain.optional_services (G19) — the per-domain
        # service slugs consumed by cluster provisioning via the mesh manifest (empty =
        # the cluster-wide set applies). Since #495 it is READ-ONLY (_ServicesCell):
        # the choice is made on the 'Domain services' step, one page per domain, which
        # is the step the build/mesh-start gate requires. 'Applies to' fills Domain.images
        # (mesh only; hidden in cloud where the single image attaches implicitly).
        self.table = QtWidgets.QTableWidget(0, 6)
        self.table.setHorizontalHeaderLabels(
            ["Domain", "Title", "Optional services", "Applies to", "Sign-in",
             "Base CA"])
        title_hdr = self.table.horizontalHeaderItem(_COL_TITLE)
        title_hdr.setToolTip(
            "This domain's display name. Written to the mesh manifest "
            "(domains[].title) for cluster provisioning to read when it sets up "
            "the domain — not emitted anywhere on a cloud build. Empty = the "
            "domain name itself.")
        svc_hdr = self.table.horizontalHeaderItem(_COL_SERVICES)
        svc_hdr.setToolTip(
            "The services this domain provides. READ-ONLY here: each domain gets its "
            "own page on the ‘Domain services’ step that follows, and that is where "
            "they are picked. They ride the mesh manifest as provisioning input "
            "(domains[].optional_services); they do NOT change which services the image "
            "bakes — that is the services step — and they do not yet decide what the "
            "cluster runs either (the services page says so in full). Empty = the "
            "cluster-wide set applies; ‘not configured yet’ is a DIFFERENT fact, and is "
            "what an image build or a docker mesh start refuses on, naming the domain.")
        hdr = self.table.horizontalHeaderItem(_COL_APPLIES)
        hdr.setToolTip("Which worklist images this domain attaches to (empty = all "
                       "eligible). Node-role images take no --domains — the attachment "
                       "is manifest/provisioning data only.")
        idp_hdr = self.table.horizontalHeaderItem(_COL_IDP)
        idp_hdr.setToolTip(
            "Which Casdoor serves this domain's sign-in. Superdomain = "
            "the mesh's one central Casdoor (default — today's behavior). Own = a "
            "Casdoor instance provisioned for this domain alone; reaches cluster "
            "provisioning via the mesh manifest, and the local compose lane stands "
            "it up next to the central one.")
        ca_hdr = self.table.horizontalHeaderItem(_COL_CA)
        ca_hdr.setToolTip(
            "Which of the certificate authorities from the Secrets store step this "
            "domain's certificates chain to. RECORDED ONLY: no builder parses a CA "
            "flag and no manifest carries the choice, so it changes no image and no "
            "provisioning input today — it records the intent with the domain. Add "
            "the PEM files on the Secrets store step (later in this wizard); until "
            "you have, every row here offers only ‘None’.")
        self.table.horizontalHeader().setStretchLastSection(True)
        # A host with no worklist (the local docker mesh) hides Applies-to; one with
        # no Secrets-store step hides Base CA — the column would offer one answer
        # ("None") and name a step the route does not have.
        self.table.setColumnHidden(_COL_APPLIES, not with_applies)
        self.table.setColumnHidden(_COL_CA, not with_ca)
        lay.addWidget(self.table)
        btns = QtWidgets.QHBoxLayout()
        add = QtWidgets.QPushButton("Add domain")
        rem = QtWidgets.QPushButton("Remove selected")
        add.clicked.connect(lambda: self._add())
        rem.clicked.connect(self._remove)
        btns.addWidget(add); btns.addWidget(rem); btns.addStretch(1)
        lay.addLayout(btns)
        # Inline, never a modal: where "that row cannot be removed" is said.
        self.row_note = QtWidgets.QLabel("")
        self.row_note.setWordWrap(True)
        self.row_note.setStyleSheet(f"color: {WARN};")
        self.row_note.setVisible(False)
        lay.addWidget(self.row_note)

    # ── host hooks ────────────────────────────────────────────────────────────────
    def _cfg(self):
        """The object the reviewed markers and the own domain's services are read
        off (an ImageConfig, or a LocalMeshDomains). None renders every row as
        unconfigured."""
        return None

    def _entries(self):
        """The current worklist entries (mesh); empty when no worklist is set."""
        return []

    def _certs(self):
        """The certificate paths the Vault step has collected ([] before it runs)."""
        return []

    def _own_name_editable(self) -> bool:
        """Whether the own row's NAME may be typed. False on the image flow (it is
        the Network step's cluster domain); True on a prod local mesh, where row 0
        IS the public apex the operator must name."""
        return False

    # ── rows ──────────────────────────────────────────────────────────────────────
    def _reviewed(self) -> set[str]:
        return reviewed_names(self._cfg())

    def _add(self, name="", title="", services="", images=None,
             idp=DOMAIN_IDP_SUPERDOMAIN, base_ca=""):
        r = self.table.rowCount()
        self.table.insertRow(r)
        self.table.setItem(r, _COL_NAME, QtWidgets.QTableWidgetItem(name))
        self.table.setItem(r, _COL_TITLE, QtWidgets.QTableWidgetItem(title))
        self.table.setCellWidget(
            r, _COL_SERVICES,
            _ServicesCell(services, reviewed=(name in self._reviewed())))
        self.table.setCellWidget(r, _COL_APPLIES,
                                 _AppliesToButton(self._entries(), images or []))
        self.table.setCellWidget(r, _COL_IDP, _IdpCombo(idp))
        self.table.setCellWidget(r, _COL_CA, _BaseCaCombo(self._certs(), base_ca))

    def _add_own(self, name: str, title: str = "", services=None,
                 reviewed: bool = False) -> None:
        """Insert the mesh's OWN domain as display-only row 0 (see the class doc)."""
        self.table.insertRow(0)
        item = QtWidgets.QTableWidgetItem(name)
        item.setData(Qt.ItemDataRole.UserRole, _OWN_ROW)
        item.setToolTip(_OWN_TIP)
        if not self._own_name_editable():
            item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
        self.table.setItem(0, _COL_NAME, item)
        titem = QtWidgets.QTableWidgetItem(title or "")
        titem.setFlags(titem.flags() & ~Qt.ItemFlag.ItemIsEditable)
        titem.setToolTip("The brand title — set on the Branding step, shown here.")
        self.table.setItem(0, _COL_TITLE, titem)
        self.table.setCellWidget(0, _COL_SERVICES,
                                 _ServicesCell(services, reviewed=reviewed))
        for col, text in ((_COL_APPLIES, _OWN_APPLIES), (_COL_IDP, _OWN_IDP),
                          (_COL_CA, _OWN_CA)):
            lab = QtWidgets.QLabel(text)
            lab.setStyleSheet(muted())
            lab.setToolTip(_OWN_TIP)
            self.table.setCellWidget(0, col, lab)

    def is_own_row(self, r: int) -> bool:
        item = self.table.item(r, _COL_NAME)
        return bool(item) and item.data(Qt.ItemDataRole.UserRole) == _OWN_ROW

    def _added_row_named(self, name: str) -> bool:
        """True when a row other than the own row already carries ``name``."""
        for r in range(self.table.rowCount()):
            item = self.table.item(r, _COL_NAME)
            if (not self.is_own_row(r) and item is not None
                    and item.text().strip() == name):
                return True
        return False

    def own_row_name(self) -> str:
        """The own row's name as typed (editable hosts), or "" when there is none."""
        for r in range(self.table.rowCount()):
            if self.is_own_row(r):
                item = self.table.item(r, _COL_NAME)
                return item.text().strip() if item else ""
        return ""

    def _remove(self):
        refused = False
        for idx in sorted({i.row() for i in self.table.selectedIndexes()}, reverse=True):
            if self.is_own_row(idx):
                refused = True
                continue
            self.table.removeRow(idx)
        self.row_note.setText(
            "Row 0 is this mesh's own domain — it is always served and cannot be "
            "removed here." if refused else "")
        self.row_note.setVisible(refused)

    def _refresh_applies_to(self):
        """Rebuild every row's applies-to menu against the current worklist (back-nav:
        the worklist may have gained/lost entries), preserving each row's selection."""
        for r in range(self.table.rowCount()):
            btn = self.table.cellWidget(r, _COL_APPLIES)
            if isinstance(btn, _AppliesToButton):
                self.table.setCellWidget(
                    r, _COL_APPLIES,
                    _AppliesToButton(self._entries(), btn.selected_ids()))

    def _refresh_base_ca(self):
        """Rebuild every row's base-CA picker against the CURRENT certificate list,
        preserving each row's choice. Needed because "domains" runs BEFORE "vault":
        the list is empty on the first forward pass and only fills when the operator
        reaches the Secrets store, so a Back into this page must re-offer it. A
        selection whose certificate has since been removed drops to None (the combo's
        own fallback) rather than surviving as a path cfg no longer carries."""
        for r in range(self.table.rowCount()):
            combo = self.table.cellWidget(r, _COL_CA)
            if isinstance(combo, _BaseCaCombo):
                self.table.setCellWidget(
                    r, _COL_CA, _BaseCaCombo(self._certs(), combo.selected_ca()))

    def _refresh_services_cells(self):
        """Re-read every row's services cell from the host's config (#495).

        The Domain services step runs AFTER this table and writes the per-domain
        selection back onto the rows (and the own domain's onto
        ``cluster_domain_services``); ``initializePage`` only fills the table when it
        is empty, so without this a Back into this page would show the pre-edit slugs
        and the 'not configured yet' state of a domain the operator had just
        configured."""
        cfg = self._cfg()
        by_name = {(getattr(d, "name", "") or "").strip(): d
                   for d in (getattr(cfg, "domains", None) or [])}
        done = self._reviewed()
        for r in range(self.table.rowCount()):
            item = self.table.item(r, _COL_NAME)
            name = item.text().strip() if item else ""
            cell = self.table.cellWidget(r, _COL_SERVICES)
            if not isinstance(cell, _ServicesCell):
                continue
            dom = by_name.get(name)
            if dom is not None:
                cell.set_slugs(dom.optional_services, reviewed=(name in done))
            elif self.is_own_row(r):
                cell.set_slugs(getattr(cfg, "cluster_domain_services", None),
                               reviewed=(name in done))

    def rows(self) -> "tuple[list[Domain], dict[str, str]]":
        """The table's ADDED domains as ``Domain`` rows (never the own row), plus the
        per-domain base-CA choices. Services come from the host's config BY NAME when
        it knows the domain (the services step is the writer), and from the cell only
        for a row the config does not know yet — see ``DomainsPage.validatePage``."""
        cfg = self._cfg()
        recorded = {(getattr(d, "name", "") or "").strip(): list(d.optional_services)
                    for d in (getattr(cfg, "domains", None) or [])
                    if (getattr(d, "name", "") or "").strip()}
        out: list[Domain] = []
        base_ca: dict[str, str] = {}
        for r in range(self.table.rowCount()):
            if self.is_own_row(r):
                continue
            name = self.table.item(r, _COL_NAME).text().strip() if self.table.item(r, _COL_NAME) else ""
            if not name:
                continue
            title = self.table.item(r, _COL_TITLE).text().strip() if self.table.item(r, _COL_TITLE) else ""
            svc_cell = self.table.cellWidget(r, _COL_SERVICES)
            services = recorded.get(name)
            if services is None:
                services = (svc_cell.selected_slugs()
                            if isinstance(svc_cell, _ServicesCell) else [])
            btn = self.table.cellWidget(r, _COL_APPLIES)
            images = btn.selected_ids() if isinstance(btn, _AppliesToButton) else []
            combo = self.table.cellWidget(r, _COL_IDP)
            idp = (combo.selected_idp() if isinstance(combo, _IdpCombo)
                   else DOMAIN_IDP_SUPERDOMAIN)
            ca_combo = self.table.cellWidget(r, _COL_CA)
            ca = ca_combo.selected_ca() if isinstance(ca_combo, _BaseCaCombo) else ""
            if ca:
                base_ca[name] = ca
            out.append(Domain(name=name, title=title or name,
                              optional_services=services, images=images, idp=idp))
        return out, base_ca


class DomainsPage(QtWidgets.QWizardPage, DomainsTableBody):
    """Superadmin: define domains."""
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        #: The CONFIGURATION OBJECT this table was last filled from (#542). Identity,
        #: not equality: ``load_config`` / ``load_session`` / ``start_build_from_session``
        #: replace ``wiz.cfg`` wholesale and then call ``restart()``, which re-runs
        #: ``initializePage`` — and a table that is already populated must be refilled
        #: from the NEW configuration, not left holding the previous flow's rows.
        #: Leaving them is not a display bug: ``validatePage`` rebuilds ``cfg.domains``
        #: from the table, so the loaded domains are ERASED from the configuration, and
        #: the #495 per-domain services gate can never refuse a domain that is no longer
        #: in ``cfg.domains``. A ``restart()`` on the SAME object keeps today's
        #: behaviour (in-progress edits survive), which is what this identity check
        #: buys over an unconditional refill. Same idiom as
        #: ``pages/domain_services.py``, for the same reason.
        self._cfg_seen = None
        self.setTitle("Domains & their services")
        self.setSubTitle(
            "Every domain this mesh serves: its own domain first, then the OTHER "
            "domains you add. Which optional services each one provides is picked on "
            "the next step, which gives every domain its own page; this table SHOWS "
            "what is recorded. "
            "Every domain you add here is given its own default admin with a "
            "generated random password (surfaced on the next, Users, step).")
        lay = QtWidgets.QVBoxLayout(self)
        # read-only header naming the Tailscale root domain (spec 5): all mesh nodes
        # join it, it is never a table row and is never attachable.
        self.header = QtWidgets.QLabel("")
        self.header.setWordWrap(True)
        self.header.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.header)
        # STEP 5 clarity: what the two editable columns are FOR (the 'Applies to' column
        # is mesh-only and hidden in cloud — see initializePage).
        self.table_help = QtWidgets.QLabel(
            "Row 0 is this mesh's OWN domain (the cluster domain from the Network "
            "step): always served, never removable, its services picked on the next "
            "step like every other domain's. "
            "‘Title’ = this domain's display name, read by cluster provisioning from "
            "the mesh manifest — it is not shown anywhere on a cloud build. ‘Optional "
            "services’ = the per-domain service slugs this domain provides, READ-ONLY "
            "here: they are picked on the ‘Domain services’ step that follows, which "
            "gives every domain its own service page (empty = the cluster-wide set "
            "applies, which is a real answer and not the same as a domain nobody has "
            "configured — a build or a docker mesh start refuses while any domain is "
            "unconfigured, and names it); these slugs are provisioning input carried "
            "in the mesh manifest — they are not baked into the image, which ships the "
            "services you chose on the services step. ‘Applies to’ = which built node images the domain attaches "
            "to. ‘Sign-in’ = which Casdoor serves this domain's login: Superdomain "
            "(its users sign in via the mesh's central Casdoor — the default) or Own "
            "(this domain runs its own Casdoor instance, provisioned just for it). "
            "‘Base CA’ = which certificate authority from the Secrets store step this "
            "domain chains to; it is recorded with your config and consumed by nothing "
            "yet, and the list it offers is the one you fill in on that later step.")
        self.table_help.setWordWrap(True)
        self.table_help.setStyleSheet("color: gray;")
        lay.addWidget(self.table_help)
        # CLOUD ONLY (#588): where a desktop client's certificate authorities really
        # come from — the KEYS stick, mesh-wide — said on the step, because this flow
        # hides the Base CA column and skips the Secrets store step (config.py
        # CLIENT_CA_INHERITANCE_NOTE says why both would be dead knobs on a client).
        self.client_ca_note = QtWidgets.QLabel(CLIENT_CA_INHERITANCE_NOTE)
        self.client_ca_note.setWordWrap(True)
        self.client_ca_note.setVisible(False)
        lay.addWidget(self.client_ca_note)
        self._init_table(lay)
        # STEP 6 surfacing: each domain gets a default admin whose credentials are
        # generated + presented at provisioning — not entered or stored here.
        self.admin_note = QtWidgets.QLabel(
            "Each domain automatically gets a default admin account. Its random "
            "password is generated and shown at provisioning time — you never type or "
            "store it here. Add named users to each domain on the next step.")
        self.admin_note.setWordWrap(True)
        self.admin_note.setStyleSheet("color: gray;")
        lay.addWidget(self.admin_note)
        # Re-offer the base-CA list whenever this page becomes current (#335).
        # initializePage is NOT enough: Qt calls it when a page is entered going
        # FORWARD, and the operator's route here is the other one — Domains, on to
        # the Secrets store, add a PEM, BACK. Qt fires no initializePage on that, so
        # without this the picker would still offer only "None" and the column would
        # look broken for exactly the operator who had just filled the list.
        # currentIdChanged fires on every transition in both directions; the guard
        # keeps the work to the one that lands here. Rebuilding combos only — no
        # dialog, no cfg write, nothing page validation can reach.
        wiz.currentIdChanged.connect(self._on_page_changed)

    def _on_page_changed(self, _page_id=None):
        if self.wiz.currentPage() is self:
            self._refresh_base_ca()
            self._refresh_services_cells()

    # ── body hooks ────────────────────────────────────────────────────────────────
    def _cfg(self):
        return self.wiz.cfg

    def _entries(self):
        """The current worklist entries (mesh); empty when no worklist is set."""
        wl = getattr(self.wiz, "worklist", None)
        return list(wl.entries) if wl is not None else []

    def _certs(self):
        """The certificate paths the Vault step has collected ([] before it runs)."""
        return list(getattr(self.wiz.cfg, "base_ca_certs", None) or [])

    def applies_to(self, cfg) -> bool:
        """Dynamic-skip predicate (wizard.nextId): a cloud NODE image emits no
        --domains and writes no manifest, so this table contributes nothing and is
        skipped (emission-neutral). Mesh and cloud client images still apply.

        ASK 8: in MESH mode this now also requires ``cfg.additional_domains`` — the
        "this mesh also hosts other domains" opt-in on the Network step. Unticked, this
        step and the Users step that follows it are skipped outright rather than shown
        empty, and NetworkPage.validatePage clears cfg.domains so a table filled in
        before the opt-in was turned off cannot reach the mesh manifest. The CLOUD arm
        is untouched: a client image's --domains tie is what it is built around."""
        return superadmin_plane_applies(cfg)

    def initializePage(self):
        c = self.wiz.cfg
        if c is not self._cfg_seen:
            # A DIFFERENT configuration object (#542) — Load config, Load session, or a
            # restart from the previous-builds manager. The rows below belong to the
            # configuration they were filled from; keeping them would DROP every domain
            # the operator just loaded, and not only from the display: validatePage
            # rebuilds cfg.domains from this table, so the loaded domains are erased
            # from the configuration, after which the per-domain services gate has
            # nothing left to refuse. Clear, then fall into the fill below. A restart()
            # that does NOT replace the object takes neither branch, so in-progress
            # edits are still preserved.
            self.table.setRowCount(0)
            self._cfg_seen = c
        self.header.setText(
            "Tailscale root domain: "
            f"<b>{c.effective_superdomain()}</b> — joined by all mesh nodes; "
            "not listed below, never attachable.")
        # the applies-to picker is a worklist-of-images concept — meaningful only in
        # mesh; cloud attaches its single image implicitly, so hide the column there.
        self.table.setColumnHidden(_COL_APPLIES, c.mode != "mesh")
        # the sign-in choice is a MESH provisioning concept too (the superdomain's
        # central Casdoor vs a per-domain one — cloud writes no manifest and hosts
        # no Casdoor), so it hides in cloud the same way; a hidden combo still
        # collects its untouched superdomain default, never anything else.
        self.table.setColumnHidden(_COL_IDP, c.mode != "mesh")
        # the base CA is a MESH provisioning intent for domains this operator runs, so
        # it hides in cloud for exactly the reason Sign-in does (a cloud client image
        # provisions no domains). A hidden combo still collects its untouched "None",
        # which is the absent-key default — emission-neutral either way.
        self.table.setColumnHidden(_COL_CA, c.mode != "mesh")
        self.client_ca_note.setVisible(c.mode == "cloud")
        # Row 0 is derived state, so it is re-derived on EVERY forward entry, not
        # only when the table is empty (#494 fix round): a same-object Back (no
        # _cfg_seen change) may have switched the mode to cloud, or renamed the
        # cluster domain on the Network step, since the table was filled.
        # Only a table that already has rows is reconciled: an empty one takes the
        # fill branch, which adds the own row itself. The table can only become
        # empty HERE when a mode switch dropped the own row (cloud / standalone),
        # and then the fill below — the cloud prefill — is exactly main's behaviour.
        if self.table.rowCount() > 0:
            self._reconcile_own_row(c)
        if self.table.rowCount() == 0:
            # ROW 0: the mesh's own domain, display-only (mesh mode; see module doc).
            # A cfg.domains row already named after it makes it a real row instead.
            own = implicit_own_domain(c)
            if own:
                self._add_own(own, c.brand_title, c.cluster_domain_services,
                              reviewed=(own in reviewed_names(c)))
            for d in c.domains:
                self._add(d.name, d.title, list(d.optional_services), d.images,
                          d.idp, (c.domain_ca or {}).get(d.name, ""))
            # default prefill (spec 4): seed row 0 with the cluster domain so a fresh
            # cloud superadmin starts from a valid PRIMARY domain (table position =
            # first --domains element). Scoped to CLOUD: in mesh the own domain is the
            # display-only row above, never a --domains element, so the manifest and
            # argv of an untouched mesh flow stay byte-identical (ASK 8).
            if not c.domains and c.mode == "cloud":
                self._add(c.cluster_domain, c.brand_title, "", [])
        else:
            self._refresh_applies_to()
            self._refresh_base_ca()

    def _reconcile_own_row(self, c) -> None:
        """Make the display-only own row agree with ``implicit_own_domain(c)`` NOW.

        The table is only REFILLED on an empty table or a new config object, so
        without this the own row survives whatever changed since it was drawn:

        * mesh -> Back to Mode -> cloud: the stale mesh own row kept the table
          non-empty, so the cloud prefill (the FD-08 ``--domains`` primary) never
          ran, and ``rows()`` skipped the own row — a cloud client built with NO
          ``--domains`` while the table showed the domain, as a row it refused to
          remove. Removing the row here leaves the table empty again, so the fill
          branch below runs exactly as it does on main.
        * the cluster domain renamed on the Network step: row 0 kept the old name
          while the Domain services step named the new one.

        Only row 0 is touched (it carries no operator input — every cell is a
        fact); the ADDED rows, and so every in-progress edit, are left alone."""
        own = implicit_own_domain(c)
        for r in range(self.table.rowCount() - 1, -1, -1):
            if self.is_own_row(r):
                self.table.removeRow(r)
        # An ADDED row already carrying the own name is that domain's row (a cloud
        # prefill kept across Back -> mesh, before any Next wrote it to cfg.domains):
        # drawing the own row too would list the same domain twice (PR #595 skeptics).
        if own and not self._added_row_named(own):
            self._add_own(own, c.brand_title, c.cluster_domain_services,
                          reviewed=(own in reviewed_names(c)))

    def validatePage(self):
        """Rebuild ``cfg.domains`` from the table.

        THE SERVICES COLUMN IS A MIRROR, NOT A STORE (#495). The Domain services step
        runs AFTER this page and writes ``cfg.domains[].optional_services``; this
        page's cells are only re-read from cfg when it becomes current
        (``_refresh_services_cells``), so on a forward walk they still hold the
        pre-step slugs. And this validatePage does NOT run only when the operator
        leaves this page: ``collect_all()`` re-runs every visited page's validatePage,
        ``BuildPage._preview`` calls ``collect_all()``, and ``BuildPage.validatePage``
        calls ``_preview`` — so collect_all re-enters itself and the LAST writer in
        one Build->Launch transition is this method, hundreds of times over. Reading
        the cached cell back would therefore discard the operator's whole selection
        somewhere they never look, while the gate still passed because the reviewed
        marker survives: the required page satisfied, its answer thrown away.

        So the slugs come from ``cfg`` BY NAME whenever that domain is still there,
        and from the cell only for a row cfg does not know yet — a row just added, or
        renamed, where the cell is the only carrier (``DomainsTableBody.rows``). The
        table stays the sole writer of WHICH domains exist, their titles, images,
        sign-in and base CA. The own row (row 0) is never written: it is not a
        ``domains`` row, so an untouched mesh flow still emits none."""
        out, base_ca = self.rows()
        self.wiz.cfg.domains = out
        # REBUILT from the table, never merged into what was there: a renamed or
        # deleted domain must not leave a stranded entry, and an untouched table
        # (every picker on None) leaves the empty dict the native default already is —
        # so a config that never met this column is byte-identical after a round trip.
        # A HIDDEN column (cloud, #588) is not an answer, though: its pickers only offer
        # cfg.base_ca_certs, which the skipped Secrets store step never fills here, so
        # rebuilding from them would silently erase a loaded config's record. Keep what
        # cfg recorded instead — pruned to the domains still in the table, so the
        # stranded-entry rule holds either way.
        if self.table.isColumnHidden(_COL_CA):
            names = {d.name for d in out}
            base_ca = {k: v for k, v in (self.wiz.cfg.domain_ca or {}).items()
                       if k in names}
        self.wiz.cfg.domain_ca = base_ca
        # Keep the mirror honest: a row whose slugs came from cfg above must not still
        # be displaying the pre-step text if the operator navigates back here without
        # a page change firing.
        self._refresh_services_cells()
        return True


class DomainsTableWidget(QtWidgets.QWidget, DomainsTableBody):
    """The SAME table as a plain widget, for a host that is not the image flow's
    wizard page — the generate-a-new-local-mesh route embeds it on its ‘Domains’ step
    (``pages/localmesh.py``) over a ``core.local_mesh_domains.LocalMeshDomains``.

    ``cfg`` is a callable returning that state; ``own_name_editable`` one returning
    whether row 0's name may be typed (a prod local mesh: row 0 IS the public apex).
    No worklist and no Secrets-store step on that route, so Applies-to and Base CA
    are hidden rather than offered with one legal answer."""

    def __init__(self, cfg, own_name_editable=None, parent=None):
        super().__init__(parent)
        self._cfg_fn = cfg
        self._own_editable_fn = own_name_editable
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self._init_table(lay, with_applies=False, with_ca=False)

    def _cfg(self):
        return self._cfg_fn() if self._cfg_fn else None

    def _own_name_editable(self) -> bool:
        return bool(self._own_editable_fn()) if self._own_editable_fn else False

    def fill(self, domains, own_name: str, own_title: str = "") -> None:
        """Rebuild the table from ``domains`` (Domain rows; the one named
        ``own_name`` becomes the display-only row 0, or an empty own row is added
        when none is)."""
        self.table.setRowCount(0)
        self.row_note.setVisible(False)
        done = self._reviewed()
        own_name = (own_name or "").strip()
        domains = list(domains)
        # The own row is ROW 0 of the state by construction (seed / commit / apply all
        # keep it there), matched by name so a blank prod apex is still the own row
        # and never a second, added row.
        own_row = (domains[0] if domains
                   and (domains[0].name or "").strip() == own_name else None)
        if own_row is not None:
            self._add_own(own_name, own_row.title or own_title, own_row.optional_services,
                          reviewed=(own_name in done))
        else:
            self._add_own(own_name, own_title, None, reviewed=(own_name in done))
        for d in domains:
            if d is own_row:
                continue
            self._add(d.name, d.title, list(d.optional_services), [], d.idp)
