"""The NVD API key box — one widget, reused by the Fleet window's Pen-test harness
group and the Go-Live org-export step (never cloned).

Every word comes from :mod:`core.nvd_key`, so the TUI's ``nvd`` command and the CLI
print the same sentences. Inline only — no modal anywhere: Save/Verify/Forget and the
org-secret push report on labels under the box.

* the key box is a password field (``EchoMode.Password``) with a Show toggle; after
  Save it is cleared, so the key sits in no widget once stored;
* the two warnings are permanent (not tooltips): a new key needs NVD's activation
  click, and an empty value is refused;
* Verify is the only outside call, says so beside the button, runs on a worker
  thread with the button disabled, and reports the verdict in words and colour;
* the org-secret row runs ``gh secret set NVD_API_KEY --org ORG`` with the value on
  stdin, refuses an unverified key unless "set anyway" is ticked, and reads the
  secret's ``updated_at`` back.
"""
from __future__ import annotations

from ...core import nvd_key
from ..qt import QtCore, QtGui, QtWidgets, Signal
from .. import choice_icons
from ..styles import ERROR, OK, WARN, muted
from ._widgets import own_probe, probe_running

__all__ = ["NvdKeyWidget"]


class _Worker(QtCore.QThread):
    """Runs one blocking core call (verify / push) off the GUI thread. Never raises
    out of run(): an escaping exception would abort the Studio under PyQt6."""
    result = Signal(object)

    def __init__(self, fn):
        super().__init__()
        self._fn = fn

    def run(self):
        try:
            self.result.emit(self._fn())
        except Exception as exc:  # noqa: BLE001 - shown inline; never the key
            self.result.emit(exc)


def _link_label(url: str, text: str) -> QtWidgets.QLabel:
    """An explicit-click link that ALSO shows the URL as selectable text (an air-gapped
    reader can copy it), opened only by QDesktopServices on a click — the
    choice_cards.set_link pattern, with the anchor colour derived to clear 4.5:1."""
    lab = QtWidgets.QLabel()
    lab.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextBrowserInteraction
                                | QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
    lab.setOpenExternalLinks(False)
    lab.setWordWrap(True)
    lab.setProperty("nvd_url", url)
    lab.setProperty("nvd_text", text)
    lab.linkActivated.connect(
        lambda u: QtGui.QDesktopServices.openUrl(QtCore.QUrl(u)))
    _render_link(lab)
    return lab


def _render_link(lab: QtWidgets.QLabel) -> None:
    pal = lab.palette()
    role = QtGui.QPalette.ColorRole
    text, base, link = (pal.color(role.WindowText), pal.color(role.Window),
                        pal.color(role.Highlight))
    for _ in range(8):
        if choice_icons._contrast(link, base) >= 4.5:   # noqa: SLF001 - shared guard
            break
        link = QtGui.QColor(
            round(link.red() + (text.red() - link.red()) * 0.35),
            round(link.green() + (text.green() - link.green()) * 0.35),
            round(link.blue() + (text.blue() - link.blue()) * 0.35))
    else:
        link = text
    url, words = lab.property("nvd_url"), lab.property("nvd_text")
    lab.setText(f'<a href="{url}" style="color: {link.name()};">{words}</a> — {url}')


class NvdKeyWidget(QtWidgets.QWidget):
    """The masked NVD key box with links, warnings, Save/Verify/Forget and the
    optional org-secret row. ``opener`` / ``runner`` are injectable (tests)."""

    #: emitted after the stored state changed (save / forget / a recorded verdict)
    changed = Signal()

    def __init__(self, parent=None, *, org: str = "", opener=None, runner=None):
        super().__init__(parent)
        self._opener = opener
        self._runner = runner
        self._verify_probe = None
        self._push_probe = None
        #: the last Verify result for a TYPED (unsaved) key: Save carries it over when
        #: the saved key is that same key, so Verify -> Save needs no second Verify
        self._typed_result = None
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 4, 0, 0)

        self.need_label = QtWidgets.QLabel(nvd_key.NEED_LINE)
        self.need_label.setWordWrap(True)
        lay.addWidget(self.need_label)
        self.request_link = _link_label(nvd_key.REQUEST_URL, "Request a key")
        self.request_link.setAccessibleName("Request an NVD API key")
        lay.addWidget(self.request_link)
        self.guide_link = _link_label(nvd_key.GUIDE_URL, "Setup guide")
        self.guide_link.setAccessibleName("NVD API key setup guide")
        lay.addWidget(self.guide_link)

        row = QtWidgets.QHBoxLayout()
        self.key_edit = QtWidgets.QLineEdit()
        self.key_edit.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.key_edit.setPlaceholderText("paste the NVD API key (UUID)")
        self.key_edit.setAccessibleName("NVD API key")
        # never offer the key to an input method's history/prediction
        self.key_edit.setInputMethodHints(
            QtCore.Qt.InputMethodHint.ImhSensitiveData
            | QtCore.Qt.InputMethodHint.ImhNoPredictiveText)
        self.key_edit.setMinimumWidth(260)
        row.addWidget(self.key_edit, 1)
        self.show_btn = QtWidgets.QToolButton()
        self.show_btn.setText("Show")
        self.show_btn.setCheckable(True)
        self.show_btn.setAccessibleName("Show the NVD API key")
        self.show_btn.toggled.connect(self._toggle_show)
        row.addWidget(self.show_btn)
        lay.addLayout(row)

        self.activation_label = QtWidgets.QLabel(nvd_key.ACTIVATION_WARNING)
        self.activation_label.setWordWrap(True)
        self.activation_label.setStyleSheet(f"color: {WARN};")
        lay.addWidget(self.activation_label)
        self.empty_label = QtWidgets.QLabel(nvd_key.EMPTY_REFUSED)
        self.empty_label.setWordWrap(True)
        self.empty_label.setStyleSheet(muted())
        lay.addWidget(self.empty_label)

        btns = QtWidgets.QHBoxLayout()
        self.save_btn = QtWidgets.QPushButton("Save")
        self.verify_btn = QtWidgets.QPushButton("Verify")
        self.forget_btn = QtWidgets.QPushButton("Forget")
        self.save_btn.clicked.connect(self._save)
        self.verify_btn.clicked.connect(self._verify)
        self.forget_btn.clicked.connect(self._forget)
        for b in (self.save_btn, self.verify_btn, self.forget_btn):
            btns.addWidget(b)
        btns.addStretch(1)
        lay.addLayout(btns)
        self.consent_label = QtWidgets.QLabel(nvd_key.VERIFY_CONSENT)
        self.consent_label.setWordWrap(True)
        self.consent_label.setStyleSheet(muted())
        lay.addWidget(self.consent_label)
        self.status_label = QtWidgets.QLabel()
        self.status_label.setWordWrap(True)
        self.status_label.setAccessibleName("NVD API key status")
        self.status_label.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.status_label)

        # ── optional: the GitHub org secret every CI template reads ──
        self.org_tick = QtWidgets.QCheckBox(nvd_key.ORG_SECRET_LABEL + "…")
        self.org_tick.toggled.connect(self._org_visible)
        lay.addWidget(self.org_tick)
        self.org_box = QtWidgets.QWidget()
        ol = QtWidgets.QVBoxLayout(self.org_box)
        ol.setContentsMargins(18, 0, 0, 0)
        orow = QtWidgets.QHBoxLayout()
        orow.addWidget(QtWidgets.QLabel("GitHub org"))
        self.org_edit = QtWidgets.QLineEdit(org)
        self.org_edit.setPlaceholderText("organisation name, e.g. my-org")
        self.org_edit.setAccessibleName("GitHub organisation for the NVD_API_KEY secret")
        orow.addWidget(self.org_edit, 1)
        self.org_btn = QtWidgets.QPushButton("Set org secret")
        self.org_btn.clicked.connect(self._push)
        orow.addWidget(self.org_btn)
        ol.addLayout(orow)
        self.set_anyway = QtWidgets.QCheckBox(
            "set anyway (the stored key's last Verify was not OK)")
        ol.addWidget(self.set_anyway)
        self.org_note = QtWidgets.QLabel(
            f"Runs gh secret set {nvd_key.SECRET_NAME} --org ORG --visibility all as you "
            "(needs admin:org); the value goes on gh's stdin, never the command line. "
            + nvd_key.ACTIVATION_WARNING)
        self.org_note.setWordWrap(True)
        self.org_note.setStyleSheet(muted())
        ol.addWidget(self.org_note)
        self.org_status = QtWidgets.QLabel()
        self.org_status.setWordWrap(True)
        self.org_status.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        ol.addWidget(self.org_status)
        lay.addWidget(self.org_box)
        self.org_box.setVisible(False)
        self.refresh()

    # ── state ────────────────────────────────────────────────────────────────────
    def changeEvent(self, ev):  # noqa: N802 - Qt override
        super().changeEvent(ev)
        if ev.type() == QtCore.QEvent.Type.PaletteChange and hasattr(self, "guide_link"):
            _render_link(self.request_link)
            _render_link(self.guide_link)

    def set_org(self, org: str) -> None:
        if not self.org_edit.text().strip():
            self.org_edit.setText(org or "")

    def _say(self, label: QtWidgets.QLabel, text: str, tone: str = "") -> None:
        label.setText(text)
        label.setStyleSheet({"ok": f"color: {OK};", "bad": f"color: {ERROR};"}.get(
            tone, muted()))

    def refresh(self) -> None:
        """Re-read the stored state into the status line."""
        st = nvd_key.status()
        line = "NVD API key: " + nvd_key.status_line(st)
        tone = "ok" if st.verified else ("bad" if not st.stored
                                         or st.last_verdict == nvd_key.NOT_ACCEPTED else "")
        self._say(self.status_label, line, tone)
        self.forget_btn.setEnabled(st.stored)

    def _toggle_show(self, on: bool) -> None:
        self.key_edit.setEchoMode(QtWidgets.QLineEdit.EchoMode.Normal if on
                                  else QtWidgets.QLineEdit.EchoMode.Password)
        self.show_btn.setText("Hide" if on else "Show")

    def _org_visible(self, on: bool) -> None:
        self.org_box.setVisible(on)

    # ── actions ──────────────────────────────────────────────────────────────────
    def _save(self) -> None:
        try:
            st = nvd_key.save(self.key_edit.text())
        except nvd_key.NvdKeyError as e:
            self._say(self.status_label, f"Not saved — {e.sentence}", "bad")
            return
        except OSError as e:
            self._say(self.status_label, f"Not saved — {e.strerror or e}", "bad")
            return
        self.key_edit.clear()
        self.show_btn.setChecked(False)
        res, self._typed_result = self._typed_result, None
        if res is not None and res.fingerprint == st.fingerprint:
            try:
                nvd_key.record_verdict(res)
                st = nvd_key.status()
            except OSError:
                pass
        tail = "" if st.verified else " — press Verify to check it with NVD."
        self._say(self.status_label, "NVD API key: " + nvd_key.status_line(st) + tail,
                  "ok" if st.verified else "")
        self.forget_btn.setEnabled(True)
        self.changed.emit()

    def _forget(self) -> None:
        nvd_key.forget()
        self.refresh()
        self.changed.emit()

    def _verify(self) -> None:
        if probe_running(self, "_verify_probe"):
            return
        typed = self.key_edit.text()
        raw = typed if typed.strip() else nvd_key.load()
        if not typed.strip() and not raw:
            self._say(self.status_label, "Nothing to verify — "
                      + nvd_key.EMPTY_REFUSED + " Paste a key first.", "bad")
            return
        try:
            nvd_key.check(raw)
        except nvd_key.NvdKeyError as e:       # refused locally: no request is made
            self._say(self.status_label, f"{nvd_key.VERDICT_LABELS[e.verdict]}: "
                      f"{e.sentence}", "bad")
            return
        stored = not typed.strip()
        opener = self._opener
        self.verify_btn.setEnabled(False)
        self._say(self.status_label, "Verifying with services.nvd.nist.gov…")
        w = _Worker(lambda: nvd_key.verify(raw, opener=opener))
        w.result.connect(lambda res, _stored=stored: self._verified(res, _stored))
        own_probe(self, "_verify_probe", w)
        w.start()

    def _verified(self, res, stored: bool) -> None:
        self.verify_btn.setEnabled(True)
        if isinstance(res, Exception):
            self._say(self.status_label, f"Verify failed: {type(res).__name__}", "bad")
            return
        if stored:
            try:
                nvd_key.record_verdict(res)
            except OSError:
                pass
            self.changed.emit()
        if not stored:
            self._typed_result = res
        tail = "" if stored or not res.ok else " Press Save to keep it."
        self._say(self.status_label, res.line() + tail, "ok" if res.ok else "bad")
        self.forget_btn.setEnabled(nvd_key.status().stored)

    def _push(self) -> None:
        if probe_running(self, "_push_probe"):
            return
        org = self.org_edit.text().strip()
        anyway = self.set_anyway.isChecked()
        # refuse before spawning anything: the same checks push_org_secret makes, so
        # the inline answer is immediate and no worker starts for a refused push
        refusal = nvd_key.push_refusal(org, set_anyway=anyway)
        if refusal:
            self._say(self.org_status, f"Not set — {refusal}", "bad")
            return
        runner = self._runner
        self.org_btn.setEnabled(False)
        self._say(self.org_status, f"Setting {nvd_key.SECRET_NAME} on {org}…")
        w = _Worker(lambda: nvd_key.push_org_secret(org, runner=runner, set_anyway=anyway))
        w.result.connect(self._pushed)
        own_probe(self, "_push_probe", w)
        w.start()

    def _pushed(self, res) -> None:
        self.org_btn.setEnabled(True)
        if isinstance(res, Exception):
            self._say(self.org_status, f"Not set: {type(res).__name__}", "bad")
            return
        self._say(self.org_status, res.sentence, "ok" if res.ok else "bad")

