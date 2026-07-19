"""Small form-building helpers shared by every wizard page (build + go-live flows).

Kept in their own module (not __init__) so page modules can import them without
touching the package registry — and re-exported from gui.wizard for golive.py's
established ``from ..wizard import _file_picker, _row`` import.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets


class Collapsible(QtWidgets.QWidget):
    """A titled section whose CONTENT can be collapsed to just its header row.

    A long page (NetworkPage) reads as a flat wall of group-boxes; wrapping each in
    one of these lets the operator fold the parts they are not editing. Adopt it on
    other long pages by wrapping their existing container — it is deliberately a
    WRAPPER, so no page has to restructure its layout to use it.

    Deliberately NOT a checkable QGroupBox (the obvious idiom): unchecking one
    DISABLES its children, which in this wizard means greying — the exact signal
    ``_gating.gate_widgets`` uses for "your platform cannot do this". A collapsed
    section would then be indistinguishable from a platform-gated one. This toggles
    ``setVisible`` on a content container instead, so enabled-ness is never touched.

    Collapsing is PRESENTATION ONLY and cannot change emission. Two independent
    reasons, both structural rather than a convention to remember:

    * validatePage()/collect_all() read widget VALUES (isChecked/text), which a
      hidden widget keeps intact; and
    * ``_gating.clear_unsupported`` keys on ``platform_supports(field, platform)``
      — the capability table — never on widget visibility.

    Collapsing also cannot leak a gate-HIDDEN child back into view: the gates drive
    setVisible on the children themselves, and Qt tracks the explicit hidden flag
    per widget, so expanding this container does not resurrect a child the gate hid
    (and re-gating a child visible while collapsed does not show it).
    """

    def __init__(self, title: str, content: QtWidgets.QWidget, expanded: bool = True,
                 parent=None):
        super().__init__(parent)
        self.content = content
        self.toggle = QtWidgets.QToolButton()
        self.toggle.setCheckable(True)
        self.toggle.setChecked(expanded)
        # Escape '&': QToolButton is a QAbstractButton, so an ampersand in its text is
        # eaten as a MNEMONIC — "Identity & domain" renders as "Identity _domain" with
        # the d underlined. Section titles are prose, never accelerators.
        self.toggle.setText(title.replace("&", "&&"))
        self.toggle.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.toggle.setArrowType(Qt.ArrowType.DownArrow if expanded
                                 else Qt.ArrowType.RightArrow)
        self.toggle.setAutoRaise(True)
        self.toggle.setStyleSheet("QToolButton { border: none; font-weight: bold; }")
        self.toggle.toggled.connect(self.set_expanded)
        # `clicked` fires ONLY on real user interaction, where `toggled` also fires on
        # every programmatic setChecked — so this is what distinguishes "the operator
        # opened this" from "the page folded it". See set_default_expanded().
        self._touched_by_user = False
        self.toggle.clicked.connect(self._mark_touched)

        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        lay.addWidget(self.toggle)
        lay.addWidget(content)
        content.setVisible(expanded)

    def set_expanded(self, on: bool) -> None:
        """Expand/collapse the content. Visibility only — never setEnabled (see class
        docstring: enabled-ness is the platform gate's signal, not ours)."""
        on = bool(on)
        if self.toggle.isChecked() != on:
            self.toggle.setChecked(on)      # keep the header in sync on a programmatic call
        self.toggle.setArrowType(Qt.ArrowType.DownArrow if on else Qt.ArrowType.RightArrow)
        self.content.setVisible(on)

    def _mark_touched(self, _checked: bool) -> None:
        self._touched_by_user = True

    def set_default_expanded(self, on: bool) -> None:
        """Apply a page's COMPUTED default fold state — unless the operator has already
        folded this section by hand, in which case their choice wins for the session.

        A page re-derives its default fold state from the config on every visit (so a
        change made on an earlier page can still open the section that shows it). Doing
        that unconditionally would also throw away a manual expansion every time the
        operator stepped Next/Back over the page. Keying on ``clicked`` splits the two:
        a section the operator has never touched keeps tracking the config; one they
        have touched stops being re-folded underneath them."""
        if self._touched_by_user:
            return
        self.set_expanded(on)

    def is_expanded(self) -> bool:
        return self.toggle.isChecked()

    def title(self) -> str:
        """The section title as given (the display text is '&'-escaped, see __init__)."""
        return self.toggle.text().replace("&&", "&")


def collapsible(title: str, content: QtWidgets.QWidget, expanded: bool = True):
    """Wrap ``content`` in a collapsible titled section. See :class:`Collapsible`."""
    return Collapsible(title, content, expanded)


def _row(label, widget):
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    lab = QtWidgets.QLabel(label)
    lab.setMinimumWidth(150)
    # Accessibility, wired from the one choke point every form row goes through (146×):
    # the label BUDDIES its field, and the field carries the label as its accessible
    # name, so a screen reader can announce "Hostname, edit" instead of a bare edit box.
    # Pure a11y metadata — no visual change, no effect on layout or emission.
    lab.setBuddy(widget)
    widget.setAccessibleName(label)
    h.addWidget(lab)
    h.addWidget(widget, 1)
    return w


# Device-catalog status badges (shared by RolePage's device browser and the mesh
# WorklistPage group rows): (badge text, color). SUPPORTED carries no badge —
# buildability is the default claim; the non-default statuses must be explicit (#351).
_STATUS_BADGES = {
    "supported": ("", ""),
    "experimental": ("EXPERIMENTAL — hardware validation pending; fail-loud preflight",
                     "#a65d00"),
    "unsupported": ("NOT BUILDABLE", "#777777"),
}


def status_badge(status):
    """(badge text, css color) for a device-catalog status."""
    return _STATUS_BADGES[status]


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
