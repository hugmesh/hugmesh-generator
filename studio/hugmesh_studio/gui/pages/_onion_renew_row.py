"""The Ways tab's "New Tor address" row (hugmesh-generator#652): one domain of the running
Docker mesh gets a new onion address.

Two clicks, both inline: the first shows what happens (``onion_renew.CONFIRM_SENTENCE``)
with "Make a new address" and "Cancel"; the second runs ``core.onion_renew`` on a worker
thread and shows the new address, selectable. No modal anywhere; slots never raise.
"""
from __future__ import annotations

import html
import sys
import traceback

from ..qt import QtCore, QtWidgets, Signal
from ...core import onion_renew

__all__ = ["OnionRenewRow"]

_WARN = "color: #a65d00;"
_MUTED = "color: gray;"


class _Worker(QtCore.QThread):
    result = Signal(object)

    def __init__(self, fn):
        super().__init__()
        self._fn = fn

    def run(self):
        try:
            self.result.emit(self._fn())
        except Exception as exc:                # noqa: BLE001 — shown inline
            self.result.emit(onion_renew.RenewOutcome(False, f"{type(exc).__name__}: {exc}"))


class OnionRenewRow(QtWidgets.QWidget):
    """The row. ``set_domain(name, stored_id)`` names the domain it acts on."""

    #: a new address was made (the host repaints what reads the published onions)
    renewed = Signal(str)

    def __init__(self, parent=None, renew=onion_renew.renew_domain_onion):
        super().__init__(parent)
        self.setObjectName("brand_onion_renew")
        self._renew = renew
        self._name = ""
        self._stored_id = ""
        self._worker: _Worker | None = None
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        row = QtWidgets.QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        self.button = QtWidgets.QPushButton("New Tor address…")
        self.button.setObjectName("brand_onion_renew_button")
        self.button.setMinimumHeight(28)
        self.button.setToolTip("Replace this domain's Tor address on the running mesh")
        self.button.clicked.connect(self._ask)
        row.addWidget(self.button)
        row.addStretch(1)
        lay.addLayout(row)
        self.confirm = QtWidgets.QWidget()
        self.confirm.setObjectName("brand_onion_renew_confirm")
        cl = QtWidgets.QVBoxLayout(self.confirm)
        cl.setContentsMargins(0, 0, 0, 0)
        self.confirm_text = QtWidgets.QLabel(onion_renew.CONFIRM_SENTENCE)
        self.confirm_text.setWordWrap(True)
        self.confirm_text.setStyleSheet(_WARN)
        cl.addWidget(self.confirm_text)
        cb = QtWidgets.QHBoxLayout()
        cb.setContentsMargins(0, 0, 0, 0)
        self.go = QtWidgets.QPushButton("Make a new address")
        self.go.setObjectName("brand_onion_renew_go")
        self.go.setMinimumHeight(28)
        self.go.clicked.connect(self._go)
        self.cancel = QtWidgets.QPushButton("Cancel")
        self.cancel.setObjectName("brand_onion_renew_cancel")
        self.cancel.setMinimumHeight(28)
        self.cancel.clicked.connect(self._cancel)
        cb.addWidget(self.go)
        cb.addWidget(self.cancel)
        cb.addStretch(1)
        cl.addLayout(cb)
        self.confirm.setVisible(False)
        lay.addWidget(self.confirm)
        self.status = QtWidgets.QLabel("")
        self.status.setObjectName("brand_onion_renew_status")
        self.status.setWordWrap(True)
        self.status.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.status.setVisible(False)          # no reserved gap while there is nothing to say
        lay.addWidget(self.status)

    # ── the domain ──────────────────────────────────────────────────────────────────
    def set_domain(self, name: str, stored_id: str = "") -> None:
        if (name, stored_id) != (self._name, self._stored_id):
            self._say("")
            self.confirm.setVisible(False)
        self._name, self._stored_id = name or "", stored_id or ""

    def _say(self, text: str, style: str = "") -> None:
        self.status.setStyleSheet(style)
        self.status.setText(text)
        self.status.setVisible(bool(text))

    def busy(self) -> bool:
        return self._worker is not None

    def wait(self, ms: int = 30000) -> None:
        """Tests: let a running worker finish and its result land."""
        w = self._worker
        if w is not None:
            w.wait(ms)
            QtCore.QCoreApplication.processEvents()

    # ── the two clicks ──────────────────────────────────────────────────────────────
    def _ask(self) -> None:
        try:
            if self._worker is None:
                self.confirm.setVisible(True)
                self._say("")
        except Exception:                       # noqa: BLE001
            self._swallow("_ask")

    def _cancel(self) -> None:
        try:
            self.confirm.setVisible(False)
        except Exception:                       # noqa: BLE001
            self._swallow("_cancel")

    def _go(self) -> None:
        try:
            if self._worker is not None or not self._name:
                return
            self.confirm.setVisible(False)
            self.button.setEnabled(False)
            self._say(f"Making a new Tor address for {self._name} … (Tor can take a "
                      "minute)", _MUTED)
            name, sid, renew = self._name, self._stored_id, self._renew
            w = _Worker(lambda: renew(name, sid))
            self._worker = w

            def done(out, _w=w):
                try:
                    self._worker = None
                    self.button.setEnabled(True)
                    if out.ok:
                        self._say(
                            html.escape(out.message)
                            + f"<br>New: <code>https://{html.escape(out.new)}/</code>"
                            + f"<br>Retired: <code>{html.escape(out.old)}</code>")
                        self.renewed.emit(out.new)
                    else:
                        self._say(html.escape("Not changed: " + out.message), _WARN)
                except Exception:               # noqa: BLE001
                    self._swallow("done")
                _w.deleteLater()

            w.result.connect(done)
            w.start()
        except Exception:                       # noqa: BLE001
            self._swallow("_go")

    @staticmethod
    def _swallow(where: str) -> None:
        print(f"_onion_renew_row: swallowed exception in {where}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
