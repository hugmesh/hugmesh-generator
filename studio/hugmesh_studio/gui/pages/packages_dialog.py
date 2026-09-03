"""PackagesDialog — the per-image package multi-select (spec 9; design 3.14).

A modal dialog opened from the Review page (and the Progress page) for ONE image: it
receives the MATERIALIZED per-image :class:`~...core.config.ImageConfig`, so the role /
desktop / GPU / service options that image actually carries drive exactly which packages
appear and which are locked. The three tiers are the honest, builder-derived model from
:mod:`...core.package_catalog` — always expressed as +add / -drop DELTAS against the set
the builder would install by default, never an absolute list (the builder stays the single
source of truth):

* **essential** — the base list, the k8s payload on node images, the option-required adhoc
  adds and the SNAP_ROLE_BINS mandatory floor: checked and LOCKED (greyed, a tooltip names
  why). Never a delta.
* **default-removable** — the rest of the default install set: checked; unchecking one
  compiles to ``packages_drop`` (labelled "may return as a dependency" — honest about
  transitive pulls).
* **available extras** — atoms from lists NOT gated in for this image: unchecked; checking
  one compiles to ``packages_add``. A validated free-atom entry adds anything else.

Legacy ``extra_packages`` (the retired free-text field, kept frozen for save/load/emission
byte-identity — design 2.1) is shown as a locked, informational "Legacy extra packages"
group so the operator sees what the old field bakes, WITHOUT the dialog silently migrating
it into ``packages_add`` (that would change the emitted argv — I1). The dialog only ever
writes ``packages_add`` / ``packages_drop``; the caller decides what to persist them onto
(the base ImageConfig for a single image, or the WorklistEntry for a mesh row).

Capability note (design 3.14): the fields exist from WS-CORE as NON_ARGV, so the dialog
stores deltas regardless of platform; the Review preview only shows ``--packages-add`` /
``--packages-drop`` once WS-BUILDER flips their emission. Any merge order is safe.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ...core import package_catalog as pc
from ...core.config import ImageConfig, image_class
from ...core.validate import IdentityValidationError, validate_package_atoms

# tier id -> (group label, is-locked). Order fixes the top-level row order.
_TIER_LABELS = {
    "essential": ("Essential — required (locked)", True),
    "removable": ("Default (removable — uncheck to drop)", False),
    "available": ("Available extras (check to add)", False),
    "legacy": ("Legacy extra packages (frozen — from the old field)", True),
}
_LOCKED_TIERS = {"essential", "legacy"}


class PackagesDialog(QtWidgets.QDialog):
    """Per-image package tri-tier picker. Read :attr:`packages_add` / :attr:`packages_drop`
    after ``exec()`` returns accepted (they are also kept live for the footer counter, so a
    test can toggle a row and read them without pressing OK)."""

    def __init__(self, generator_dir: str, cfg: ImageConfig,
                 packages_add: str = "", packages_drop: str = "",
                 extra_packages: str = "", parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        self.cfg = cfg
        self.setWindowTitle(f"Packages — {cfg.role or 'image'} · {cfg.platform or 'x86'}")
        self.resize(640, 620)

        # live results (read by the caller and the footer counter).
        self.packages_add = ""
        self.packages_drop = ""

        # atom -> (leaf item, tier id); (tier, section) -> section header item.
        self.items: dict[str, tuple[QtWidgets.QTreeWidgetItem, str]] = {}
        self._tier_items: dict[str, QtWidgets.QTreeWidgetItem] = {}
        self._sections: dict[tuple[str, str], QtWidgets.QTreeWidgetItem] = {}

        lay = QtWidgets.QVBoxLayout(self)
        hdr = QtWidgets.QLabel(
            f"These are the packages baked into the <b>{cfg.role or 'image'}</b> image on "
            f"<b>{cfg.platform or 'x86'}</b>. Essentials are locked; unchecking a default "
            "removes it (may return as a dependency); checking an extra adds it.")
        hdr.setWordWrap(True)
        hdr.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(hdr)

        self.filter_edit = QtWidgets.QLineEdit()
        self.filter_edit.setPlaceholderText("Filter atoms…")
        self.filter_edit.textChanged.connect(self._apply_filter)
        lay.addWidget(self.filter_edit)

        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderHidden(True)
        lay.addWidget(self.tree, 1)

        self._build_tree()
        self._apply_initial(packages_add, packages_drop)
        self._add_legacy(extra_packages)
        self.tree.itemChanged.connect(self._on_item_changed)

        # free-atom entry (tier-3 add) — validated against the same allowlist as every surface.
        self.free_atom_edit = QtWidgets.QLineEdit()
        # Short on purpose: a QLineEdit elides its placeholder, and this one lives in a
        # dialog column narrow enough that a full sentence would be cut mid-word.
        self.free_atom_edit.setPlaceholderText(
            "Gentoo atom, e.g. app-editors/neovim (space-separated)")
        self.add_free_btn = QtWidgets.QPushButton("Add")
        self.add_free_btn.clicked.connect(self._add_free)
        self.free_atom_edit.returnPressed.connect(self._add_free)
        frow = QtWidgets.QHBoxLayout()
        frow.addWidget(self.free_atom_edit, 1)
        frow.addWidget(self.add_free_btn)
        lay.addLayout(frow)
        # The format hint has to OUTLIVE the placeholder. A placeholder disappears on the
        # first keystroke — precisely the moment the user is mid-atom and wants to know
        # what shape it takes — so the naming rule and where to look a name up are stated
        # persistently, in the page, as a label. Not a tooltip (invisible until hovered)
        # and not a dialog (this file already knows better; see error_label).
        self.atom_hint_label = QtWidgets.QLabel(
            "Gentoo atom format: category/package — e.g. app-editors/neovim. "
            "Look names up at packages.gentoo.org.")
        self.atom_hint_label.setWordWrap(True)
        self.atom_hint_label.setStyleSheet("color: palette(mid);")
        lay.addWidget(self.atom_hint_label)
        self.error_label = QtWidgets.QLabel("")
        self.error_label.setWordWrap(True)
        self.error_label.setStyleSheet("color: #b00020;")
        self.error_label.setVisible(False)
        lay.addWidget(self.error_label)

        self.counter_label = QtWidgets.QLabel("+0 added / −0 dropped")
        lay.addWidget(self.counter_label)

        buttons = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.StandardButton.Ok
            | QtWidgets.QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        lay.addWidget(buttons)

        self._recompute()

    # ---- tree construction ------------------------------------------------------
    def _atom_sections(self) -> dict[str, str]:
        """atom -> its list section title (best-effort, from the parsed catalog). Atoms with
        no list home (adhoc/mandatory/legacy) fall back to a synthetic section by the caller."""
        out: dict[str, str] = {}
        for _list_id, tree in pc.catalog_for_platform(
                self.generator_dir, self.cfg.platform or "x86").items():
            for sec in tree["sections"]:
                for atom in sec["atoms"]:
                    out.setdefault(atom, sec["title"] or "General")
        return out

    def _build_tree(self) -> None:
        self.tree.blockSignals(True)
        tiers = pc.tiers(self.generator_dir, self.cfg)
        sections = self._atom_sections()
        for tier in ("essential", "removable", "available"):
            self._tier_items[tier] = self._make_tier_item(tier)
        for tier in ("essential", "removable", "available"):
            for atom in tiers[tier]:
                title = sections.get(atom) or ("Payload" if tier == "essential" else "General")
                self._add_atom_item(tier, title, atom,
                                    checked=(tier != "available"),
                                    tooltip=self._essential_tooltip(atom) if tier == "essential" else "")
        self.tree.expandAll()
        self.tree.blockSignals(False)

    def _make_tier_item(self, tier: str) -> QtWidgets.QTreeWidgetItem:
        label, _locked = _TIER_LABELS[tier]
        item = QtWidgets.QTreeWidgetItem(self.tree, [label])
        # a plain header row (no checkbox): remove selectability, keep it non-checkable.
        item.setFlags(Qt.ItemFlag.ItemIsEnabled)
        f = item.font(0)
        f.setBold(True)
        item.setFont(0, f)
        return item

    def _ensure_section(self, tier: str, title: str) -> QtWidgets.QTreeWidgetItem:
        key = (tier, title)
        sec = self._sections.get(key)
        if sec is None:
            sec = QtWidgets.QTreeWidgetItem(self._tier_items[tier], [title])
            sec.setFlags(Qt.ItemFlag.ItemIsEnabled)
            self._sections[key] = sec
        return sec

    def _add_atom_item(self, tier: str, section: str, atom: str,
                       checked: bool, tooltip: str = "") -> QtWidgets.QTreeWidgetItem:
        sec = self._ensure_section(tier, section)
        it = QtWidgets.QTreeWidgetItem(sec, [atom])
        base = Qt.ItemFlag.ItemIsUserCheckable | Qt.ItemFlag.ItemIsSelectable
        if tier in _LOCKED_TIERS:
            # locked: keep a rendered checkbox but disabled (greyed, non-interactive) so a
            # user can never uncheck an essential / edit the frozen legacy list.
            it.setFlags(Qt.ItemFlag.ItemIsUserCheckable)
        else:
            it.setFlags(base | Qt.ItemFlag.ItemIsEnabled)
        it.setCheckState(0, Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked)
        it.setData(0, Qt.ItemDataRole.UserRole, atom)
        if tooltip:
            it.setToolTip(0, tooltip)
        self.items[atom] = (it, tier)
        return it

    def _essential_tooltip(self, atom: str) -> str:
        cls = image_class(self.cfg.mode, self.cfg.role)
        if cls == "node" and atom in (pc.list_atoms(self.generator_dir, self.cfg.platform, "packages-k8s")
                                      + [pc.BIN_ATOM.get(b, "") for b in pc.MANDATORY_NODE_BINS]):
            return "required cluster payload on a node image — cannot be removed"
        return "essential for this image's role/options — cannot be removed"

    # ---- initial deltas + legacy ------------------------------------------------
    def _apply_initial(self, packages_add: str, packages_drop: str) -> None:
        """Re-apply a prior selection (re-opening the dialog): check the added extras,
        uncheck the dropped defaults, and surface any add-atom not in the catalog as a
        checked custom extra."""
        self.tree.blockSignals(True)
        for atom in packages_drop.split():
            hit = self.items.get(atom)
            if hit and hit[1] == "removable":
                hit[0].setCheckState(0, Qt.CheckState.Unchecked)
        for atom in packages_add.split():
            hit = self.items.get(atom)
            if hit and hit[1] == "available":
                hit[0].setCheckState(0, Qt.CheckState.Checked)
            elif hit is None:
                self._add_atom_item("available", "Custom", atom, checked=True)
        self.tree.blockSignals(False)

    def _add_legacy(self, extra_packages: str) -> None:
        atoms = extra_packages.split()
        if not atoms:
            return
        self.tree.blockSignals(True)
        self._tier_items["legacy"] = self._make_tier_item("legacy")
        for atom in atoms:
            # a legacy atom already represented in a real tier stays there; only genuinely
            # unknown legacy atoms get an informational locked row (no add/drop effect).
            if atom in self.items:
                continue
            self._add_atom_item("legacy", "Frozen", atom, checked=True,
                                tooltip="from the retired --extra-packages field; kept frozen "
                                        "for save/load/emission byte-identity")
        self.tree.expandAll()
        self.tree.blockSignals(False)

    # ---- live delta accounting --------------------------------------------------
    def _on_item_changed(self, _item, _col) -> None:
        self._recompute()

    def _recompute(self) -> None:
        add, drop = [], []
        for atom, (item, tier) in self.items.items():
            checked = item.checkState(0) == Qt.CheckState.Checked
            if tier == "available" and checked:
                add.append(atom)
            elif tier == "removable" and not checked:
                drop.append(atom)
        self.packages_add = " ".join(sorted(add))
        self.packages_drop = " ".join(sorted(drop))
        self.counter_label.setText(f"+{len(add)} added / −{len(drop)} dropped")

    # ---- free-atom add ----------------------------------------------------------
    def _add_free(self) -> None:
        text = self.free_atom_edit.text().strip()
        if not text:
            return
        try:
            validate_package_atoms(text)
        except IdentityValidationError as e:
            # core.validate's message explains WHY the value was refused (it would be
            # written into a root-sourced config) and says nothing about what a valid
            # atom looks like — which is the half the user needs to fix their input. The
            # format sentence is appended HERE, at the call site, and not inside
            # validate._require: that helper is shared by validate_brand and every other
            # identity validator, where "Gentoo atom" would be nonsense.
            self.error_label.setText(
                f"{e} Expected Gentoo atom format: category/package — "
                "e.g. app-editors/neovim.")
            self.error_label.setVisible(True)
            return
        self.error_label.setVisible(False)
        self.tree.blockSignals(True)
        for atom in text.split():
            hit = self.items.get(atom)
            if hit is not None:
                if hit[1] == "available":
                    hit[0].setCheckState(0, Qt.CheckState.Checked)
                continue
            self._add_atom_item("available", "Custom", atom, checked=True)
        self.tree.expandAll()
        self.tree.blockSignals(False)
        self.free_atom_edit.clear()
        self._recompute()

    # ---- filter -----------------------------------------------------------------
    def _apply_filter(self, text: str) -> None:
        needle = text.strip().lower()
        for atom, (item, _tier) in self.items.items():
            item.setHidden(bool(needle) and needle not in atom.lower())
        # hide a section / tier group with no visible atom left.
        for sec in self._sections.values():
            sec.setHidden(all(sec.child(i).isHidden() for i in range(sec.childCount())))
        for tier_item in self._tier_items.values():
            tier_item.setHidden(all(tier_item.child(i).isHidden()
                                    for i in range(tier_item.childCount())))

    # ---- api --------------------------------------------------------------------
    def row_for_atom(self, atom: str) -> QtWidgets.QTreeWidgetItem:
        """The leaf item for an atom (KeyError if the atom is not in this image's catalog)."""
        return self.items[atom][0]

    def accept(self) -> None:
        self._recompute()
        super().accept()
