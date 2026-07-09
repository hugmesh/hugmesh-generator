"""The Snapdragon go-live wizard — the Studio GUI front door to scripts/go-live.sh.

Step flow (design v1): preflight status → exposure model → provider pick (deep
links, open-in-browser) → inputs (CLUSTER_DOMAIN autofill) → generate/download →
verify → explicit human-confirm flip. Every action dispatches the ENGINE's flags
via core.golive_driver.GoLiveDriver; this page set adds NOTHING to the engine —
the same contract scripts/go-live-menu.sh keeps for the console.

The flip stays double-confirmed by design: the GUI arms its button only after the
domain is typed here, and the engine then runs its OWN typed-domain confirm on a
real TTY (the GUI opens it in a terminal emulator — there is no bypass flag, and
this wizard does not add one; unattended go-live is a v1 non-goal).

Secrets: tokens are taken in masked fields, staged into 0600 temp files handed to
the engine as --token-file/--cf-api-token-file, deleted right after the run, and
never persisted or placed in argv — mirroring the console menu exactly.
"""
from __future__ import annotations

import os

from ..qt import QtCore, QtGui, QtWidgets, Signal
from ..wizard import _file_picker, _row
from ...core.golive_driver import GoLiveDriver, GoLiveOptions

# exactly one page per slug, same order — mirrors WIZARD_PAGE_SLUGS' role for the
# build wizard (tests pin each slug to its page class)
GOLIVE_PAGE_SLUGS = ("preflight", "exposure", "provider", "inputs",
                     "generate", "verify", "flip")

# labels/blurbs for the exposure-model radios; the model LIST itself comes from
# the provider catalog, so a catalog-only provider addition still shows up here.
MODEL_LABELS = {
    "tunnel": ("Outbound tunnel (no open inbound ports)",
               "cloudflared dials OUT to the edge and serves your hostnames — nothing "
               "listens on the WAN. The flagship path; works behind CGNAT."),
    "public-dns": ("Public DNS records (bring your own domain)",
                   "Point A/AAAA/CNAME records at a reachable public IP at any "
                   "registrar — copy-paste record set, no registrar API."),
    "ddns": ("Dynamic DNS (home / dynamic IP)",
             "A thin single-token updater keeps a hostname pointed at your current "
             "IP — the realistic path for home connections."),
    "funnel": ("Tailscale Funnel (no DNS records at all)",
               "Public HTTPS via the tailnet edge on the node's ts.net name — "
               "tailscale.com-joined nodes only (self-hosted headscale has no Funnel)."),
    "router": ("Router port-forward (instructions only)",
               "Forward WAN 80/443 to the ingress node yourself — the wizard renders "
               "the exact checklist and never touches the router."),
}


class _EngineWorker(QtCore.QThread):
    """Runs one GoLiveDriver action the same way _BuildWorker runs a build."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, opts, action_flags):
        super().__init__()
        self.driver, self.opts, self.action_flags = driver, opts, action_flags

    def run(self):
        code = self.driver.run(self.opts, self.action_flags,
                               on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


def _open_url(url):
    QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))


# ── pages ────────────────────────────────────────────────────────────────────
class GoLivePreflightPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Preflight — current release posture")
        self.setSubTitle("Where this device stands before anything changes (read-only).")
        lay = QtWidgets.QVBoxLayout(self)
        info = QtWidgets.QLabel(
            "The internal→public mechanism already exists on the device: "
            "snapdragon-firewall-reconcile watches /etc/snapdragon/release-state and "
            "the /etc/snapdragon/go-live marker (60s convergence, fail-closed). This "
            "wizard only provisions the public edge, verifies it, and then writes that "
            "marker — rollback is deleting it.")
        info.setWordWrap(True)
        lay.addWidget(info)
        self.status = QtWidgets.QPlainTextEdit()
        self.status.setReadOnly(True)
        lay.addWidget(self.status, 1)
        btn = QtWidgets.QPushButton("Refresh status")
        btn.clicked.connect(self._refresh)
        lay.addWidget(btn)

    def initializePage(self):
        self._refresh()

    def _refresh(self):
        self.status.setPlainText(self.wiz.driver.status_text())


class GoLiveExposurePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Pick the exposure model")
        self.setSubTitle("How should the public internet reach this brand?")
        lay = QtWidgets.QVBoxLayout(self)
        self.group = QtWidgets.QButtonGroup(self)
        self.models = wiz.driver.models()
        for i, model in enumerate(self.models):
            label, desc = MODEL_LABELS.get(model, (model, ""))
            rb = QtWidgets.QRadioButton(label)
            rb.setProperty("model", model)
            sub = QtWidgets.QLabel(desc)
            sub.setWordWrap(True)
            sub.setStyleSheet("color: gray;")
            sub.setContentsMargins(24, 0, 0, 8)
            self.group.addButton(rb, i)
            lay.addWidget(rb)
            lay.addWidget(sub)
        if self.models:
            self.group.button(0).setChecked(True)
        lay.addStretch(1)

    def initializePage(self):
        # reflect an earlier choice on back-navigation (the ModePage pattern)
        for i, model in enumerate(self.models):
            if model == self.wiz.model:
                self.group.button(i).setChecked(True)

    def validatePage(self):
        btn = self.group.checkedButton()
        if btn is None:
            return False
        model = btn.property("model")
        if model != self.wiz.model:
            # a provider from another model is meaningless — let ProviderPage reselect
            self.wiz.opts.provider = ""
        self.wiz.model = model
        return True


class GoLiveProviderPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Pick the provider")
        self.setSubTitle("Deep links open the EXACT pages you need in your browser.")
        lay = QtWidgets.QVBoxLayout(self)
        self.list = QtWidgets.QListWidget()
        self.list.setMaximumHeight(110)
        lay.addWidget(self.list)
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        lay.addWidget(self.summary)
        self.links_box = QtWidgets.QGroupBox("Provider pages (deep links)")
        self.links_lay = QtWidgets.QVBoxLayout(self.links_box)
        lay.addWidget(self.links_box)
        self.open_all = QtWidgets.QPushButton("Open all in browser")
        self.open_all.clicked.connect(self._open_all)
        lay.addWidget(self.open_all)
        self.notes = QtWidgets.QLabel("")
        self.notes.setWordWrap(True)
        self.notes.setStyleSheet("color: #a65d00;")
        lay.addWidget(self.notes)
        lay.addStretch(1)
        self.list.currentRowChanged.connect(self._changed)

    def initializePage(self):
        self.list.blockSignals(True)
        self.list.clear()
        for p in self.wiz.driver.providers():
            if self.wiz.model and p.model != self.wiz.model:
                continue
            it = QtWidgets.QListWidgetItem(f"{p.id} — {p.title}")
            it.setData(QtCore.Qt.ItemDataRole.UserRole, p.id)
            self.list.addItem(it)
            if p.id == self.wiz.opts.provider:
                self.list.setCurrentItem(it)
        self.list.blockSignals(False)
        if self.list.currentRow() < 0 and self.list.count():
            self.list.setCurrentRow(0)
        else:
            self._changed(self.list.currentRow())

    def _current(self):
        it = self.list.currentItem()
        if it is None:
            return None
        return self.wiz.driver.provider(it.data(QtCore.Qt.ItemDataRole.UserRole))

    def _changed(self, _row_idx):
        p = self._current()
        while self.links_lay.count():
            w = self.links_lay.takeAt(0).widget()
            if w:
                w.deleteLater()
        if p is None:
            self.summary.setText("")
            self.notes.setText("")
            return
        req = ", ".join(p.inputs) or "none"
        opt = ", ".join(p.optional) or "none"
        self.summary.setText(f"{p.summary}\n\nRequired inputs: {req}  ·  Optional: {opt}")
        for url, label in p.links:
            row = QtWidgets.QWidget()
            h = QtWidgets.QHBoxLayout(row)
            h.setContentsMargins(0, 0, 0, 0)
            lab = QtWidgets.QLabel(f"{label}\n{url}")
            lab.setWordWrap(True)
            btn = QtWidgets.QPushButton("Open")
            btn.clicked.connect(lambda _=False, u=url: _open_url(u))
            h.addWidget(lab, 1)
            h.addWidget(btn)
            self.links_lay.addWidget(row)
        self.notes.setText("\n".join(f"• {n}" for n in p.notes))

    def _open_all(self):
        p = self._current()
        for url, _label in (p.links if p else []):
            _open_url(url)

    def validatePage(self):
        p = self._current()
        if p is None:
            return False
        self.wiz.opts.provider = p.id
        return True


class GoLiveInputsPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Inputs")
        self.setSubTitle("Everything autofillable is autofilled — the domain comes from "
                         "the device's baked cluster domain when present.")
        lay = QtWidgets.QVBoxLayout(self)
        self.domain = QtWidgets.QLineEdit()
        self.domain.setPlaceholderText("example.org (autofilled from /etc/snapdragon/cluster-domain when baked)")
        lay.addWidget(_row("Public domain", self.domain))
        self.domain_hint = QtWidgets.QLabel("")
        self.domain_hint.setStyleSheet("color: gray;")
        lay.addWidget(self.domain_hint)
        self.record_ip = QtWidgets.QLineEdit()
        self.record_ip.setPlaceholderText("public A/AAAA record value (e.g. 203.0.113.7)")
        self.record_row = _row("Record IP", self.record_ip)
        lay.addWidget(self.record_row)
        self.tunnel_id = QtWidgets.QLineEdit()
        self.tunnel_id.setPlaceholderText("Cloudflare tunnel UUID — CNAME target <uuid>.cfargotunnel.com")
        self.tunnel_row = _row("Tunnel UUID", self.tunnel_id)
        lay.addWidget(self.tunnel_row)
        self.ddns_service = QtWidgets.QComboBox()
        self.ddns_service.addItems(["duckdns", "cloudflare"])
        self.ddns_service_row = _row("DDNS service", self.ddns_service)
        lay.addWidget(self.ddns_service_row)
        self.ddns_subdomain = QtWidgets.QLineEdit()
        self.ddns_subdomain.setPlaceholderText("hostname label, e.g. 'home' → home.duckdns.org / home.<domain>")
        self.ddns_sub_row = _row("DDNS subdomain", self.ddns_subdomain)
        lay.addWidget(self.ddns_sub_row)
        # secrets: masked value OR a token file; the file wins (engine semantics).
        # The masked value is staged to a 0600 temp file at generate time, deleted
        # after the run, and never persisted — it deliberately has no place in opts.
        self.token_box = QtWidgets.QGroupBox("Provider token (never persisted, never in argv)")
        tl = QtWidgets.QVBoxLayout(self.token_box)
        self.token_secret = QtWidgets.QLineEdit()
        self.token_secret.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.token_secret.setPlaceholderText("paste the token (staged via a 0600 temp file, deleted after the run)")
        tl.addWidget(_row("Token", self.token_secret))
        self.token_file = QtWidgets.QLineEdit()
        tfb = _file_picker(self, self.token_file, "Token file")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.token_file, 1); h.addWidget(tfb)
        tl.addWidget(_row("…or token file", w))
        lay.addWidget(self.token_box)
        # optional Cloudflare thin driver (--create-dns) — cloudflare-tunnel only
        self.cf_box = QtWidgets.QGroupBox("Optional: create the tunnel CNAMEs (--create-dns, thin Cloudflare driver)")
        cfl = QtWidgets.QVBoxLayout(self.cf_box)
        self.create_dns = QtWidgets.QCheckBox(
            "Create/refresh the CNAMEs via the Cloudflare API (needs the tunnel UUID above)")
        cfl.addWidget(self.create_dns)
        self.cf_secret = QtWidgets.QLineEdit()
        self.cf_secret.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.cf_secret.setPlaceholderText("Cloudflare API token, scope Zone.DNS Edit (staged via 0600 temp file)")
        cfl.addWidget(_row("CF API token", self.cf_secret))
        lay.addWidget(self.cf_box)
        self.out_dir = QtWidgets.QLineEdit()
        odb = _file_picker(self, self.out_dir, "Artifact dir", directory=True)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.out_dir, 1); h.addWidget(odb)
        lay.addWidget(_row("Artifact dir", w))
        self.keys_dir = QtWidgets.QLineEdit()
        kdb = _file_picker(self, self.keys_dir, "Keys layout dir", directory=True)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.keys_dir, 1); h.addWidget(kdb)
        lay.addWidget(_row("Keys layout dir", w))
        lay.addStretch(1)

    def initializePage(self):
        o = self.wiz.opts
        p = self.wiz.driver.provider(o.provider)
        if not self.domain.text().strip():
            baked = o.domain or self.wiz.driver.autofill_domain()
            self.domain.setText(baked)
            self.domain_hint.setText(
                "autofilled from the device's baked cluster domain" if baked and not o.domain
                else "")
        offers = p.offers if p else (lambda _name: True)
        self.record_row.setVisible(offers("record-ip"))
        self.tunnel_row.setVisible(offers("tunnel-id") or (p is not None and p.id == "cloudflare-tunnel"))
        self.ddns_service_row.setVisible(offers("subdomain"))
        self.ddns_sub_row.setVisible(offers("subdomain"))
        self.token_box.setVisible(offers("token"))
        self.cf_box.setVisible(offers("cf-api-token"))
        self.record_ip.setText(o.record_ip)
        self.tunnel_id.setText(o.tunnel_id)
        self.ddns_service.setCurrentText(o.ddns_service or "duckdns")
        self.ddns_subdomain.setText(o.ddns_subdomain)
        self.token_file.setText(o.token_file)
        self.out_dir.setText(o.out_dir)
        self.keys_dir.setText(o.keys_dir)
        self.create_dns.setChecked(self.wiz.create_dns)

    def validatePage(self):
        o = self.wiz.opts
        o.domain = self.domain.text().strip()
        if not o.domain:
            QtWidgets.QMessageBox.warning(
                self, "Domain required",
                "Every downstream step needs the public domain — no baked cluster "
                "domain was found to autofill it, so enter it here.")
            return False
        o.record_ip = self.record_ip.text().strip()
        o.tunnel_id = self.tunnel_id.text().strip()
        o.ddns_service = self.ddns_service.currentText()
        o.ddns_subdomain = self.ddns_subdomain.text().strip()
        o.token_file = self.token_file.text().strip()
        o.out_dir = self.out_dir.text().strip()
        o.keys_dir = self.keys_dir.text().strip()
        # masked secrets live on the wizard (never on opts/argv), staged at run time
        self.wiz.token_secret = self.token_secret.text()
        self.wiz.cf_token_secret = self.cf_secret.text()
        self.wiz.create_dns = (self.create_dns.isChecked() and self.cf_box.isVisible())
        return True


class GoLiveGeneratePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Generate & download")
        self.setSubTitle("Renders the autofilled record set / zone file / checklist / DDNS "
                         "updater into the artifact dir, and stores the token in the keys layout.")
        lay = QtWidgets.QVBoxLayout(self)
        self.cmd = QtWidgets.QPlainTextEdit()
        self.cmd.setReadOnly(True)
        self.cmd.setMaximumHeight(90)
        lay.addWidget(QtWidgets.QLabel("Command:"))
        lay.addWidget(self.cmd)
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.generate_btn = QtWidgets.QPushButton("Generate artifacts now")
        self.open_btn = QtWidgets.QPushButton("Open artifacts folder")
        self.preview_btn.clicked.connect(self._preview)
        self.generate_btn.clicked.connect(self._generate)
        self.open_btn.clicked.connect(self._open_folder)
        bl = QtWidgets.QHBoxLayout()
        bl.addWidget(self.preview_btn); bl.addWidget(self.generate_btn)
        bl.addWidget(self.open_btn); bl.addStretch(1)
        lay.addLayout(bl)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)
        self.worker = None
        self._staged = []

    def _action_flags(self):
        flags = ["--emit"]
        if self.wiz.create_dns and self.wiz.opts.provider == "cloudflare-tunnel":
            flags.append("--create-dns")
        return flags

    def initializePage(self):
        self._preview()

    def _preview(self):
        d, o = self.wiz.driver, self.wiz.opts
        self.cmd.setPlainText(d.command_string(o, self._action_flags())
                              + ("" if o.token_file or not self.wiz.token_secret
                                 else "  # --token-file <staged 0600 temp file> added at run time"))
        problems = d.preflight(o, self._action_flags(),
                               has_secret=bool(self.wiz.token_secret),
                               has_cf_secret=bool(self.wiz.cf_token_secret))
        self.log.setPlainText("Preflight:\n  - " + "\n  - ".join(problems)
                              if problems else "Preflight OK.")

    def _generate(self):
        self._preview()
        if self.worker and self.worker.isRunning():
            return
        d, o = self.wiz.driver, self.wiz.opts
        import copy
        run_opts = copy.deepcopy(o)
        # stage masked secrets → 0600 temp files (deleted in _finished); an explicit
        # token FILE from the inputs page wins, mirroring the engine's own precedence
        if not run_opts.token_file and self.wiz.token_secret:
            run_opts.token_file = d.stage_token(self.wiz.token_secret)
            self._staged.append(run_opts.token_file)
        if "--create-dns" in self._action_flags() and not run_opts.cf_api_token_file \
                and self.wiz.cf_token_secret:
            run_opts.cf_api_token_file = d.stage_token(self.wiz.cf_token_secret)
            self._staged.append(run_opts.cf_api_token_file)
        self.generate_btn.setEnabled(False)
        self.log.appendPlainText("\n=== generating go-live artifacts ===")
        self.worker = _EngineWorker(d, run_opts, self._action_flags())
        self.worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.worker.done.connect(self._finished)
        self.worker.start()

    def _finished(self, code):
        for p in self._staged:
            try:
                os.unlink(p)
            except OSError:
                pass
        self._staged = []
        self.log.appendPlainText(f"=== emit exited {code} ===")
        if code == 0:
            out = self.wiz.opts.out_dir or self.wiz.driver.default_out_dir
            self.log.appendPlainText(f"artifacts in {out} — 'Open artifacts folder' shows them")
        self.generate_btn.setEnabled(True)

    def _open_folder(self):
        out = self.wiz.opts.out_dir or self.wiz.driver.default_out_dir
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(out))


class GoLiveVerifyPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Verify the edge")
        self.setSubTitle("Probes DNS/HTTP/tunnel per the provider's catalog row — BEFORE anything flips.")
        lay = QtWidgets.QVBoxLayout(self)
        self.run_btn = QtWidgets.QPushButton("Run verify now")
        self.run_btn.clicked.connect(self._verify)
        lay.addWidget(self.run_btn)
        self.result = QtWidgets.QLabel("")
        self.result.setWordWrap(True)
        lay.addWidget(self.result)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)
        self.worker = None

    def initializePage(self):
        self.result.setText("Not verified yet — the engine re-runs this gate before any flip anyway.")
        self.result.setStyleSheet("color: gray;")

    def _verify(self):
        if self.worker and self.worker.isRunning():
            return
        self.run_btn.setEnabled(False)
        self.log.appendPlainText("=== verify ===")
        self.worker = _EngineWorker(self.wiz.driver, self.wiz.opts, ["--verify"])
        self.worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.worker.done.connect(self._finished)
        self.worker.start()

    def _finished(self, code):
        self.wiz.verify_ok = (code == 0)
        self.log.appendPlainText(f"=== verify exited {code} ===")
        if code == 0:
            self.result.setText("Verify passed — the edge answers.")
            self.result.setStyleSheet("color: #2e7d32;")
        else:
            self.result.setText("Verify FAILED — fix the failing probes before flipping "
                                "(the engine will refuse the flip on the same failures).")
            self.result.setStyleSheet("color: #c62828;")
        self.run_btn.setEnabled(True)


class GoLiveFlipPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Go live — flip the release posture")
        self.setSubTitle("The ONLY step that changes the device. Human confirm, twice — by design.")
        lay = QtWidgets.QVBoxLayout(self)
        self.warning = QtWidgets.QLabel("")
        self.warning.setWordWrap(True)
        self.warning.setStyleSheet("color: #c62828; font-weight: bold;")
        lay.addWidget(self.warning)
        info = QtWidgets.QLabel(
            "The flip writes /etc/snapdragon/go-live (root); snapdragon-firewall-reconcile "
            "converges within 60s — no reboot. It opens in a TERMINAL because the engine "
            "requires its own typed-domain confirmation on a real TTY, with no bypass flag "
            "— this wizard does not add one. Rollback: delete the marker (button below).")
        info.setWordWrap(True)
        lay.addWidget(info)
        self.status = QtWidgets.QPlainTextEdit()
        self.status.setReadOnly(True)
        self.status.setMaximumHeight(110)
        lay.addWidget(self.status)
        self.confirm = QtWidgets.QLineEdit()
        self.confirm.setPlaceholderText("type the domain exactly to arm the flip")
        self.confirm.textChanged.connect(self._armed)
        lay.addWidget(_row("Confirm domain", self.confirm))
        self.persist = QtWidgets.QCheckBox(
            "Also persist release-state=public (survives marker deletion; rollback "
            "then needs the persist step too)")
        lay.addWidget(self.persist)
        self.flip_btn = QtWidgets.QPushButton("GO LIVE — open the flip in a terminal")
        self.flip_btn.setEnabled(False)
        self.flip_btn.clicked.connect(self._flip)
        self.rollback_btn = QtWidgets.QPushButton("Rollback — delete the marker (back to internal)")
        self.rollback_btn.clicked.connect(self._rollback)
        self.refresh_btn = QtWidgets.QPushButton("Refresh status")
        self.refresh_btn.clicked.connect(self._refresh)
        bl = QtWidgets.QHBoxLayout()
        bl.addWidget(self.flip_btn); bl.addWidget(self.rollback_btn)
        bl.addWidget(self.refresh_btn); bl.addStretch(1)
        lay.addLayout(bl)
        self.out = QtWidgets.QLabel("")
        self.out.setWordWrap(True)
        lay.addWidget(self.out)
        # shown only when no terminal emulator exists — the exact command to run by hand
        self.manual = QtWidgets.QLineEdit()
        self.manual.setReadOnly(True)
        self.manual.setVisible(False)
        lay.addWidget(self.manual)
        lay.addStretch(1)

    def initializePage(self):
        d = self.wiz.opts.domain
        self.warning.setText(f"ABOUT TO GO PUBLIC: {d} will accept public 80/443 "
                             "within 60s of the flip.")
        self.confirm.clear()
        self.flip_btn.setEnabled(False)
        self.out.setText("")
        self.manual.setVisible(False)
        self._refresh()

    def _refresh(self):
        self.status.setPlainText(self.wiz.driver.status_text())

    def _armed(self, text):
        d = self.wiz.opts.domain
        self.flip_btn.setEnabled(bool(d) and text.strip() == d)

    def _report(self, ok, msg):
        self.out.setText(msg)
        # no terminal emulator → surface the exact manual command, copyable
        show_manual = not ok and "yourself: " in msg
        self.manual.setVisible(show_manual)
        if show_manual:
            self.manual.setText(msg.split("yourself: ", 1)[1])

    def _flip(self):
        ok, msg = self.wiz.driver.run_flip_in_terminal(self.wiz.opts,
                                                       persist=self.persist.isChecked())
        self._report(ok, msg)

    def _rollback(self):
        if QtWidgets.QMessageBox.question(
                self, "Rollback",
                "Delete the go-live marker (device reverts to INTERNAL within 60s)?"
        ) != QtWidgets.QMessageBox.StandardButton.Yes:
            return
        persist = QtWidgets.QMessageBox.question(
            self, "Rollback",
            "ALSO reset release-state=internal?\n(Needed if you flipped with "
            "'persist' — otherwise the device stays public.)"
        ) == QtWidgets.QMessageBox.StandardButton.Yes
        ok, msg = self.wiz.driver.run_rollback_in_terminal(persist=persist)
        self._report(ok, msg)


class GoLiveWizard(QtWidgets.QWizard):
    """Internal-only → publicly live, in seven guided steps — the Studio face of
    the one shared engine (make go-live / go-live-menu.sh drive the same flags)."""

    def __init__(self, generator_dir, parent=None):
        super().__init__(parent)
        self.generator_dir = os.path.abspath(generator_dir)
        self.driver = GoLiveDriver(self.generator_dir)
        self.opts = GoLiveOptions()
        self.model = ""             # chosen exposure model (catalog `model` value)
        self.token_secret = ""      # masked provider token — staged per run, never saved
        self.cf_token_secret = ""   # masked CF API token — same lifecycle
        self.create_dns = False
        self.verify_ok = False
        self.setWindowTitle("Snapdragon Go-Live Wizard")
        self.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
        self.resize(820, 640)
        self._pages = [
            GoLivePreflightPage(self), GoLiveExposurePage(self), GoLiveProviderPage(self),
            GoLiveInputsPage(self), GoLiveGeneratePage(self), GoLiveVerifyPage(self),
            GoLiveFlipPage(self),
        ]
        assert len(self._pages) == len(GOLIVE_PAGE_SLUGS), (
            f"go-live pages ({len(self._pages)}) drifted from "
            f"GOLIVE_PAGE_SLUGS ({len(GOLIVE_PAGE_SLUGS)})")
        for p in self._pages:
            self.addPage(p)
        self._page_ids = dict(zip(GOLIVE_PAGE_SLUGS, self.pageIds()))
