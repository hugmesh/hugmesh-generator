"""DomainCAKeysPage: the "Domain CA keys" step of the domain configuration.

Operator ask (2026-11-09): "we need another section step of the domain config to add
the private keys to the CA so everything is ready to go live in the sticks".

The page is a face over :mod:`core.domain_ca_keys`: the same rows, the same imports,
the same refusals and the same go-live checklist the TUI screen and the CLI print.
The material lives in that module's in-memory store, never in the config, so the
page commits nothing to ``wiz.cfg`` and an untouched step changes no output.

No message box anywhere (page validation must never block on a modal): a refusal is
the inline note under the buttons. The file pickers are module-level override points
so tests drive the imports without a dialog.
"""
from __future__ import annotations

from ..qt import Qt, QtWidgets
from ..styles import muted
from ...core import domain_ca_keys as dca
from ...core.worklist_driver import node_key_profiles
from ._scroll import scrollable

#: File pickers, as MODULE-LEVEL OVERRIDE POINTS (tests monkeypatch them; production
#: keeps Qt's own). Called only from the click handlers below.
pick_file = QtWidgets.QFileDialog.getOpenFileName

_CERT_FILTER = "Certificates (*.pem *.crt *.cer *.der);;All files (*)"
_KEY_FILTER = "Private keys (*.key *.pem *.der);;All files (*)"
_P12_FILTER = "PKCS#12 (*.p12 *.pfx);;All files (*)"


class DomainCAKeysPage(QtWidgets.QWizardPage):
    """One row per domain; the mesh's own domain takes a signing key."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle(dca.STEP_TITLE)
        self.setSubTitle(dca.STEP_SUBTITLE)
        lay = scrollable(self)

        self.table = QtWidgets.QTableWidget(0, len(dca.TABLE_HEADERS))
        self.table.setHorizontalHeaderLabels(list(dca.TABLE_HEADERS))
        self.table.setEditTriggers(
            QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(
            QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(
            QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
        self.table.verticalHeader().setVisible(False)
        hdr = self.table.horizontalHeader()
        hdr.setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hdr.setStretchLastSection(True)
        self.table.itemSelectionChanged.connect(self._sync_buttons)
        lay.addWidget(self.table)

        form = QtWidgets.QHBoxLayout()
        form.addWidget(QtWidgets.QLabel("Key passphrase"))
        self.passphrase = QtWidgets.QLineEdit()
        self.passphrase.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.passphrase.setPlaceholderText("only if the key or PKCS#12 file is encrypted")
        self.passphrase.setToolTip(
            "Used once to open the key, then cleared. The key is held decrypted in "
            "this Studio's memory only; the passphrase is never saved or logged.")
        form.addWidget(self.passphrase, 1)
        lay.addLayout(form)

        btns = QtWidgets.QHBoxLayout()
        self.import_files = QtWidgets.QPushButton("Import certificate + key…")
        self.import_files.setToolTip(
            "Pick the signing CA certificate (PEM or DER), then its private key "
            "(PEM or DER, encrypted or not). Another domain takes the certificate "
            "only.")
        self.import_p12 = QtWidgets.QPushButton("Import PKCS#12…")
        self.import_p12.setToolTip(
            "A .p12/.pfx holding the signing CA's certificate and key (and, if it is "
            "there, the root certificate it chains to).")
        self.import_root = QtWidgets.QPushButton("Root certificate…")
        self.import_root.setToolTip(
            "The root CA CERTIFICATE the signing CA chains to. A root key is never "
            "taken: the root stays offline.")
        self.remove_btn = QtWidgets.QPushButton("Remove")
        self.remove_btn.setToolTip("Forget this domain's CA (nothing on disk changes).")
        for b, slot in ((self.import_files, self._import_files),
                        (self.import_p12, self._import_p12),
                        (self.import_root, self._import_root),
                        (self.remove_btn, self._remove)):
            b.clicked.connect(slot)
            btns.addWidget(b)
        btns.addStretch(1)
        lay.addLayout(btns)

        self.note = QtWidgets.QLabel("")
        self.note.setWordWrap(True)
        self.note.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.note)

        self.checklist_box = QtWidgets.QGroupBox("Ready to go live?")
        cl = QtWidgets.QVBoxLayout(self.checklist_box)
        self.checklist = QtWidgets.QLabel("")
        self.checklist.setWordWrap(True)
        self.checklist.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse)
        cl.addWidget(self.checklist)
        lay.addWidget(self.checklist_box)

        not_taken = QtWidgets.QLabel(
            "Not taken here:\n" + "\n".join(f"• {what}: {why}"
                                             for what, why in dca.NOT_TAKEN))
        not_taken.setWordWrap(True)
        not_taken.setStyleSheet(muted())
        lay.addWidget(not_taken)
        lay.addStretch(1)

        self.crypto_note = dca.crypto_problem()
        self.refresh()

    # ── state ────────────────────────────────────────────────────────────────────
    def rows(self) -> list[tuple[str, bool]]:
        return dca.domain_rows(self.wiz.cfg)

    def selected(self) -> tuple[str, bool] | None:
        r = self.table.currentRow()
        rows = self.rows()
        return rows[r] if 0 <= r < len(rows) else None

    def checklist_lines(self) -> list[str]:
        return dca.readiness_lines(self.wiz.cfg, dca.store(),
                                   node_key_profiles(getattr(self.wiz, "worklist", None)))

    def refresh(self) -> None:
        cfg = self.wiz.cfg
        dca.rekey_own(cfg)
        keep = max(0, self.table.currentRow())
        cells = dca.row_cells(cfg, dca.store(),
                              node_key_profiles(getattr(self.wiz, "worklist", None)))
        self.table.setRowCount(len(cells))
        for r, row in enumerate(cells):
            for c, text in enumerate(row):
                item = QtWidgets.QTableWidgetItem(text)
                item.setToolTip(text)
                self.table.setItem(r, c, item)
        self.table.selectRow(min(keep, len(cells) - 1))
        # as tall as its rows (up to six), so one domain is not a mostly empty box
        shown = max(1, min(6, len(cells)))
        # (room for a sideways scrollbar is kept: a long file name may need one)
        self.table.setFixedHeight(
            self.table.horizontalHeader().sizeHint().height()
            + 2 * self.table.frameWidth()
            + shown * self.table.verticalHeader().defaultSectionSize()
            + self.table.horizontalScrollBar().sizeHint().height() + 2)
        self.checklist.setText("\n".join(self.checklist_lines()))
        if self.crypto_note:
            self.note.setText("Cannot take a CA key: " + self.crypto_note)
        self._sync_buttons()

    def _sync_buttons(self) -> None:
        sel = self.selected()
        able = sel is not None and not self.crypto_note
        own = bool(sel and sel[1])
        self.import_files.setEnabled(able)
        self.import_files.setText("Import certificate + key…" if own
                                  else "Import certificate…")
        self.import_p12.setEnabled(able)
        self.import_root.setEnabled(able)
        self.remove_btn.setEnabled(sel is not None
                                   and dca.store().get(sel[0]) is not None)

    def _done(self, text: str) -> None:
        self.passphrase.clear()
        self.refresh()
        self.note.setText(text)

    def _pick(self, title: str, flt: str) -> str:
        path, _sel = pick_file(self, title, "", flt)
        return path or ""

    # ── click handlers (the only callers of the pickers) ─────────────────────────
    def _import_files(self) -> None:
        sel = self.selected()
        if sel is None:
            return
        domain, own = sel
        cert = self._pick("Signing CA certificate", _CERT_FILTER)
        if not cert:
            return
        key = self._pick("Signing CA private key", _KEY_FILTER) if own else ""
        if own and not key:
            self.note.setText("Not imported: no key file was chosen.")
            return
        self._run(lambda: dca.import_signing(
            dca.store(), domain, own, cert_path=cert, key_path=key,
            passphrase=self.passphrase.text() or None))

    def _import_p12(self) -> None:
        sel = self.selected()
        if sel is None:
            return
        p12 = self._pick("PKCS#12 file", _P12_FILTER)
        if not p12:
            return
        self._run(lambda: dca.import_signing(
            dca.store(), sel[0], sel[1], p12_path=p12,
            passphrase=self.passphrase.text() or None))

    def _import_root(self) -> None:
        sel = self.selected()
        if sel is None:
            return
        path = self._pick("Root CA certificate", _CERT_FILTER)
        if not path:
            return
        self._run(lambda: dca.import_root(dca.store(), sel[0], sel[1], path))

    def _remove(self) -> None:
        sel = self.selected()
        if sel is None:
            return
        gone = dca.remove(dca.store(), sel[0])
        self._done(f"Removed the CA for {sel[0] or 'this mesh'}." if gone
                   else "Nothing to remove.")

    def _run(self, fn) -> None:
        try:
            e = fn()
        except dca.CAImportError as err:
            self._done(f"Not imported: {err}.")
            return
        finally:
            # whatever happened (an unexpected error included), the passphrase does
            # not stay in the field
            self.passphrase.clear()
        extra = ("" if not e.warnings else " Note: " + "; ".join(e.warnings) + ".")
        self._done(f"Imported for {e.domain or 'this mesh'}: "
                   f"{e.signing_name or e.root_name}.{extra}")

    # ── wizard contract ──────────────────────────────────────────────────────────
    def initializePage(self) -> None:
        self.refresh()

    def validatePage(self) -> bool:
        # Nothing to commit: the material is the store's, never the config's. Leaving
        # with a NOT-ready checklist is allowed (the build then mints a throwaway CA,
        # as it always has); the checklist says so on this page.
        return True
