"""Small form-building helpers shared by every wizard page (build + go-live flows).

Kept in their own module (not __init__) so page modules can import them without
touching the package registry — and re-exported from gui.wizard for golive.py's
established ``from ..wizard import _file_picker, _row`` import.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets


class NoWheelComboBox(QtWidgets.QComboBox):
    """A QComboBox that IGNORES wheel events unless it has focus — mandatory for any
    combo embedded in a scrollable view (setItemWidget in a tree/table, a combo
    inside a scroll area).

    Qt's default combo (focusPolicy=WheelFocus) EATS wheel events and changes the
    selection whenever the cursor passes over it mid-scroll. In a scrolling table of
    embedded combos that is silent data corruption: wave-1 forensics on issue #46
    found the only board=rpi4 image ever recorded (rpi5-desktop.rpi5, session
    20260815-154029-05f5d2) in a fleet with no Pi 4 hardware, every sibling row at
    its default — rpi4 is exactly ONE wheel notch below the rpi5 default in the
    worklist board combo, and the flip re-keyed that image's binpkg pool to
    snap-build-pi4 (0% reuse from the populated pi5 pool). The same silent flip on
    the encrypt_root combo would toggle a node's disk encryption.

    A DELIBERATE wheel edit still works: click the combo (focusing it), then
    scroll. An unfocused combo ignores the event, so the container scrolls instead
    — the standard fix for the combo-in-scroll-area trap.
    """

    def __init__(self, *args) -> None:
        super().__init__(*args)
        # StrongFocus = click/tab focus WITHOUT wheel-grabs-focus (the default
        # WheelFocus lets the first stray scroll both focus AND edit the combo).
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def wheelEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if self.hasFocus():
            super().wheelEvent(event)
        else:
            event.ignore()   # propagate: the scroll belongs to the view, not the value


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


# ── tri-state checkbox helpers ────────────────────────────────────────────────────────
# These used to live on NetworkPage, which is where the 3-state idiom was introduced (G34)
# and where every consumer was. That page has none left — the operator's asks 1/4 turned
# every service box two-state with a definite default — so they moved HERE rather than
# lingering in a module whose whole point is now that it does not do this. The SOLE
# remaining consumer is RolePage's `sunshine` box, which is a different page and a
# different lane; it keeps the third state until someone makes the same call for it.
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


def own_probe(owner, attr: str, thread):
    """Hold a background QThread on ``owner.<attr>`` so it is neither GC'd nor LEAKED.

    Both halves matter, and getting one right without the other is how this went wrong:

    * A QThread whose last PYTHON reference is dropped is garbage-collected mid-run and
      takes its running thread with it — which is why these probes are held on the page
      at all rather than in a local.
    * But holding them with ``parent=page`` and then rebinding the attribute for the
      next probe leaks every previous one: dropping the Python reference does NOT
      destroy the C++ object, because Qt's parent owns it. Measured on the local-mesh
      page: **50 QThread children accumulated after 50 verb cycles**, unbounded over a
      session, since the e2e gate re-probes on every verb start, every verb end and
      every page entry.

      The leak's real cost is not memory. These probes are parented to the page, and a
      probe still running when its page is destroyed takes the Studio down with a Qt
      qFatal — so every stranded thread widens that window.

    So: ``finished`` both schedules the C++ deletion and CLEARS the attribute. Clearing
    is what keeps the ``isRunning()`` in-flight guards correct — a rebound-but-deleted
    wrapper would raise RuntimeError from inside a Qt slot, which on PyQt6 aborts the
    process rather than raising into Python.
    """
    setattr(owner, attr, thread)

    def _release():
        if getattr(owner, attr, None) is thread:
            setattr(owner, attr, None)

    thread.finished.connect(_release)
    thread.finished.connect(thread.deleteLater)
    return thread


def probe_running(owner, attr: str) -> bool:
    """Is the probe on ``owner.<attr>`` still in flight?

    Guarded: ``own_probe`` clears the attribute on finish, but a page torn down between
    the two can still leave a wrapper whose C++ object is gone, and ``isRunning()`` on
    that raises RuntimeError — inside a Qt slot, that aborts the Studio.
    """
    probe = getattr(owner, attr, None)
    if probe is None:
        return False
    try:
        return bool(probe.isRunning())
    except RuntimeError:
        return False
