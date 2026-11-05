"""The tray's "HugMesh token…" dialog — paste a shared, signed HugMesh token so the
tray's mesh node runs with exactly the access domain, role and shell access it grants
(core/mesh_token.py says what is enforced and what only the server can enforce).

Trust is never implied: a token from an issuer this computer has not trusted is
refused until the operator compares the issuer's fingerprint with the one the issuer
gave them and confirms it. The flow itself is Qt-free (:func:`core.mesh_token.
import_token`), so tests drive it without a dialog.
"""
from __future__ import annotations

from .qt import QtWidgets
from ..core import mesh_token as mt

TITLE = "HugMesh token"

TRUST_QUESTION = (
    "This token is signed by an issuer this computer does not trust yet:\n\n"
    "    {fingerprint}\n\n"
    "Trust it only if that matches, character for character, the fingerprint the "
    "issuer gave you some other way (in person, by phone, in a message you trust). "
    "Trust this issuer?")


class MeshTokenDialog(QtWidgets.QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle(TITLE)
        self.resize(560, 300)
        lay = QtWidgets.QVBoxLayout(self)
        self.summary = QtWidgets.QLabel(mt.summary())
        self.summary.setWordWrap(True)
        lay.addWidget(self.summary)
        lay.addWidget(QtWidgets.QLabel("Paste a token you were given:"))
        self.paste = QtWidgets.QPlainTextEdit()
        self.paste.setPlaceholderText(f"{mt.FORMAT}.…")
        lay.addWidget(self.paste)
        self.result = QtWidgets.QLabel("")
        self.result.setWordWrap(True)
        lay.addWidget(self.result)
        row = QtWidgets.QHBoxLayout()
        self.import_btn = QtWidgets.QPushButton("Import")
        self.forget_btn = QtWidgets.QPushButton("Forget token")
        close = QtWidgets.QPushButton("Close")
        row.addWidget(self.import_btn)
        row.addWidget(self.forget_btn)
        row.addStretch(1)
        row.addWidget(close)
        lay.addLayout(row)
        self.import_btn.clicked.connect(self._import)
        self.forget_btn.clicked.connect(self._forget)
        close.clicked.connect(self.accept)
        self.forget_btn.setEnabled(mt.token_stored())

    def _confirm_trust(self, fingerprint: str) -> bool:
        answer = QtWidgets.QMessageBox.question(
            self, TITLE, TRUST_QUESTION.format(fingerprint=fingerprint),
            QtWidgets.QMessageBox.StandardButton.Yes | QtWidgets.QMessageBox.StandardButton.No,
            QtWidgets.QMessageBox.StandardButton.No)
        return answer == QtWidgets.QMessageBox.StandardButton.Yes

    def _import(self) -> None:
        g, why = mt.import_token(self.paste.toPlainText(), self._confirm_trust)
        self.result.setText(
            f"Imported. The mesh node will run as {g.describe()}. Restart it if it is "
            f"running." if g else why)
        if g:
            self.paste.clear()
        self.summary.setText(mt.summary())
        self.forget_btn.setEnabled(mt.token_stored())

    def _forget(self) -> None:
        mt.forget_token()
        self.result.setText("The token was removed from this computer. A mesh node "
                            "running under it is stopped when the tray next refreshes.")
        self.summary.setText(mt.summary())
        self.forget_btn.setEnabled(False)


def open_mesh_token_dialog(parent=None) -> None:
    MeshTokenDialog(parent).exec()


__all__ = ["MeshTokenDialog", "open_mesh_token_dialog", "TRUST_QUESTION"]
