"""The HugMesh go-live wizard — the Studio GUI front-end to the CANONICAL
driver (specs/usr/sbin/hugmesh-go-live).

Step flow (design v1): preflight status → exposure model → provider pick → inputs
(CLUSTER_DOMAIN autofill) → generate (driver `plan`) → verify (edge checklist +
posture recheck) → explicit human-confirm commit. Every action is a driver
subcommand dispatched via core.golive_driver.GoLiveDriver; this page set is a THIN
front-end — exactly like hugmesh-go-live-cli and the ncurses
hugmesh-go-live-menu, it only ever calls `hugmesh-go-live <verb>` and adds
NO logic of its own.

The commit stays double-confirmed by design: the GUI arms its button only after the
domain is typed here, and the driver then runs its OWN confirmation prompt on a
real TTY (the GUI opens it in a terminal emulator). There is deliberately no bypass
flag, and this wizard does not add one (no -y/--yes) — unattended go-live is a v1
non-goal.

Secrets: tokens are taken in masked fields, staged into a 0600 temp file handed to
the driver as --token-file, deleted right after the run, and never persisted or
placed in argv — GoLiveOptions has no field for a secret value at all.
"""
from __future__ import annotations

import os

from ..qt import QtCore, QtGui, QtWidgets, Signal
from ..branding_icon import brand_icon
from ..wizard import _file_picker, _row
from ...core.golive_driver import GoLiveDriver, GoLiveOptions, _NO_DOMAIN_MECHANISMS
from ...core.progress_parse import ProgressParser, track_phases

# exactly one page per slug, same order — mirrors WIZARD_PAGE_SLUGS' role for the
# build wizard (tests pin each slug to its page class)
GOLIVE_PAGE_SLUGS = ("preflight", "exposure", "provider", "inputs",
                     "generate", "verify", "flip")

# labels/blurbs for the exposure-model radios; the model LIST itself comes from
# the driver's provider registry (mechanism -> model), so a registry-only provider
# addition still shows up here.
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
    "onion": ("Tor v3 onion (hidden service — no public IP/DNS/ports)",
              "The node's own Tor daemon serves a stable .onion, reachable in Tor "
              "Browser. No public IP, no DNS records, no open inbound ports — needs "
              "the node built with --with-tor. The onion is live with the firewall "
              "CLOSED, so it needs no 'go-live' flip at all."),
}

# one-line description of what each mechanism's `plan` emits (the registry does not
# expose per-provider prose via `list`, so the front-end names it by mechanism).
MECH_EMITS = {
    "deeplink": "a Zero-Trust deep-link, a token-drop guide, and the autofilled public "
                "hostnames / CNAME record set.",
    "files": "a copy-paste record set, a BIND zone + CSV (A/AAAA/CNAME), and registrar "
             "DNS deep-links.",
    "ddns": "a real single-token DDNS updater + a cron drop-in (no dashboard).",
    "funnel": "the tailnet-native funnel enable commands (no public DNS records at all).",
    "instructions": "printed port-forward instructions + router deep-links (no mutation).",
    "onion": "the node's minted .onion address + a Tor Browser reachability card "
             "(no public DNS/IP/ports; needs --with-tor baked on the node).",
}


class _DriverWorker(QtCore.QThread):
    """Runs one GoLiveDriver subcommand the same way _BuildWorker runs a build."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, subcommand, opts):
        super().__init__()
        self.driver, self.subcommand, self.opts = driver, subcommand, opts

    def run(self):
        code = self.driver.run(self.subcommand, self.opts,
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
            "hugmesh-firewall-reconcile watches /etc/hugmesh/release-state and "
            "the /etc/hugmesh/go-live marker (60s convergence, fail-closed). This "
            "wizard only provisions the public edge, verifies it, and then writes that "
            "marker (driver `commit`) — rollback is deleting it.")
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
        self.setSubTitle("The driver's registry is the source of truth — deep-links and the "
                         "record set / checklist are written into the artifacts at Generate.")
        lay = QtWidgets.QVBoxLayout(self)
        self.list = QtWidgets.QListWidget()
        self.list.setMaximumHeight(110)
        lay.addWidget(self.list)
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        lay.addWidget(self.summary)
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
        if p is None:
            self.summary.setText("")
            return
        req = ", ".join(p.inputs) or "none"
        opt = ", ".join(p.optional) or "none"
        emits = MECH_EMITS.get(p.mechanism, "")
        self.summary.setText(
            f"{p.title}\n\nMechanism: {p.mechanism}  ·  Required inputs: {req}  ·  "
            f"Optional: {opt}\n\nPlan emits: {emits}")

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
        self.domain.setPlaceholderText("example.org (autofilled from /etc/hugmesh/cluster-domain when baked)")
        lay.addWidget(_row("Public domain", self.domain))
        self.domain_hint = QtWidgets.QLabel("")
        self.domain_hint.setStyleSheet("color: gray;")
        lay.addWidget(self.domain_hint)
        self.ingress_ip = QtWidgets.QLineEdit()
        self.ingress_ip.setPlaceholderText("public A record value (e.g. 203.0.113.7)")
        self.ingress_row = _row("Ingress IP", self.ingress_ip)
        lay.addWidget(self.ingress_row)
        self.ingress_ipv6 = QtWidgets.QLineEdit()
        self.ingress_ipv6.setPlaceholderText("optional public AAAA record value (e.g. 2001:db8::7)")
        self.ipv6_row = _row("Ingress IPv6", self.ingress_ipv6)
        lay.addWidget(self.ipv6_row)
        self.tunnel_cname = QtWidgets.QLineEdit()
        self.tunnel_cname.setPlaceholderText("CNAME target, e.g. <tunnel-id>.cfargotunnel.com")
        self.tunnel_row = _row("Tunnel CNAME", self.tunnel_cname)
        lay.addWidget(self.tunnel_row)
        self.ddns_service = QtWidgets.QComboBox()
        self.ddns_service.addItems(["duckdns", "cloudflare"])
        self.ddns_service_row = _row("DDNS service", self.ddns_service)
        lay.addWidget(self.ddns_service_row)
        self.ddns_subdomain = QtWidgets.QLineEdit()
        self.ddns_subdomain.setPlaceholderText("hostname label, e.g. 'home' → home.duckdns.org / home.<domain>")
        self.ddns_sub_row = _row("DDNS subdomain", self.ddns_subdomain)
        lay.addWidget(self.ddns_sub_row)
        # secrets: masked value OR a token file; the file wins (driver semantics).
        # The masked value is staged to a 0600 temp file at generate time, deleted
        # after the run, and never persisted — it deliberately has no place in opts.
        self.token_box = QtWidgets.QGroupBox("Provider token (never saved, never in argv)")
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
        self.ingress_row.setVisible(offers("ingress-ip"))
        self.ipv6_row.setVisible(offers("ingress-ipv6"))
        self.tunnel_row.setVisible(offers("tunnel-cname"))
        self.ddns_service_row.setVisible(offers("subdomain"))
        self.ddns_sub_row.setVisible(offers("subdomain"))
        self.token_box.setVisible(offers("token"))
        self.ingress_ip.setText(o.ingress_ip)
        self.ingress_ipv6.setText(o.ingress_ipv6)
        self.tunnel_cname.setText(o.tunnel_cname)
        self.ddns_service.setCurrentText(o.ddns_service or "duckdns")
        self.ddns_subdomain.setText(o.ddns_subdomain)
        self.token_file.setText(o.token_file)
        self.out_dir.setText(o.out_dir)
        self.keys_dir.setText(o.keys_dir)

    def validatePage(self):
        o = self.wiz.opts
        o.domain = self.domain.text().strip()
        p = self.wiz.driver.provider(o.provider)
        # Onion has no public DNS name (the .onion IS the endpoint) — don't demand a
        # domain for it; every other mechanism still needs one downstream.
        domain_required = not (p and p.mechanism in _NO_DOMAIN_MECHANISMS)
        if domain_required and not o.domain:
            QtWidgets.QMessageBox.warning(
                self, "Domain required",
                "Every downstream step needs the public domain — no baked cluster "
                "domain was found to autofill it, so enter it here.")
            return False
        o.ingress_ip = self.ingress_ip.text().strip()
        o.ingress_ipv6 = self.ingress_ipv6.text().strip()
        o.tunnel_cname = self.tunnel_cname.text().strip()
        o.ddns_service = self.ddns_service.currentText()
        o.ddns_subdomain = self.ddns_subdomain.text().strip()
        o.token_file = self.token_file.text().strip()
        o.out_dir = self.out_dir.text().strip()
        o.keys_dir = self.keys_dir.text().strip()
        # masked secret lives on the wizard (never on opts/argv), staged at run time
        self.wiz.token_secret = self.token_secret.text()
        return True


class GoLiveGeneratePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Generate & download")
        self.setSubTitle("Runs the driver's `plan` (dry-run — posture is NOT touched): renders "
                         "the autofilled record set / zone / checklist / DDNS updater into the "
                         "artifact dir, and stores the token in the keys layout.")
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
        # ── determinate progress (the honest banner-phase parser, ProgressPage's
        # exact bar+label convention) — `plan` emits the two `==> ` banners
        # hugmesh-go-live's cmd_plan() carries (see progress-tables.json's
        # "golive-plan" track); hidden until a run actually starts, and indeterminate
        # (busy) until the first known banner lands, exactly like the build page.
        prow = QtWidgets.QHBoxLayout()
        self.progress_bar = QtWidgets.QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.progress_bar.setVisible(False)
        prow.addWidget(self.progress_bar, 1)
        self.progress_label = QtWidgets.QLabel("")
        self.progress_label.setVisible(False)
        prow.addWidget(self.progress_label)
        lay.addLayout(prow)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)
        self.worker = None
        self._staged = []
        self._parser: ProgressParser | None = None

    def initializePage(self):
        self._preview()

    def _preview(self):
        d, o = self.wiz.driver, self.wiz.opts
        self.cmd.setPlainText(d.command_string("plan", o)
                              + ("" if o.token_file or not self.wiz.token_secret
                                 else "  # --token-file <staged 0600 temp file> added at run time"))
        problems = d.preflight(o, has_secret=bool(self.wiz.token_secret))
        self.log.setPlainText("Preflight:\n  - " + "\n  - ".join(problems)
                              if problems else "Preflight OK.")

    def _generate(self):
        self._preview()
        if self.worker and self.worker.isRunning():
            return
        d, o = self.wiz.driver, self.wiz.opts
        import copy
        run_opts = copy.deepcopy(o)
        # stage the masked secret → a 0600 temp file (deleted in _finished); an
        # explicit token FILE from the inputs page wins, mirroring the driver's
        # own precedence (GL_TOKEN_FILE is read from a file, never argv)
        if not run_opts.token_file and self.wiz.token_secret:
            run_opts.token_file = d.stage_token(self.wiz.token_secret)
            self._staged.append(run_opts.token_file)
        self.generate_btn.setEnabled(False)
        self.log.appendPlainText("\n=== generating go-live artifacts (plan) ===")
        self._parser = ProgressParser(phases=track_phases("golive-plan"))
        self._reset_progress()
        self.worker = _DriverWorker(d, "plan", run_opts)
        self.worker.line.connect(self._on_line)
        self.worker.done.connect(self._finished)
        self.worker.start()

    # ── determinate progress (mirrors ProgressPage._apply_state, one row's worth) ──
    def _reset_progress(self) -> None:
        self.progress_bar.setVisible(True)
        self.progress_label.setVisible(True)
        self.progress_bar.setRange(0, 0)      # indeterminate/busy until the first banner
        self.progress_bar.setValue(0)
        self.progress_label.setText("starting…")

    def _apply_progress_state(self, state) -> None:
        if state.percent is None:
            self.progress_bar.setRange(0, 0)  # honest: no known phase yet
        else:
            self.progress_bar.setRange(0, 100)
            self.progress_bar.setValue(state.percent)
        if state.phase_label:
            self.progress_label.setText(state.phase_label)

    def _on_line(self, line: str) -> None:
        self.log.appendPlainText(line)
        if self._parser is not None:
            self._apply_progress_state(self._parser.feed(line))

    def _finished(self, code):
        for p in self._staged:
            try:
                os.unlink(p)
            except OSError:
                pass
        self._staged = []
        self.log.appendPlainText(f"=== plan exited {code} ===")
        if self._parser is not None:
            self._apply_progress_state(self._parser.finalize(code))
            self.progress_label.setText("done" if code == 0 else "FAILED")
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
        self.setSubTitle("Confirm the public edge answers BEFORE flipping — the driver has no "
                         "verify subcommand, so this is an off-device checklist + a posture recheck.")
        lay = QtWidgets.QVBoxLayout(self)
        self.checklist = QtWidgets.QPlainTextEdit()
        self.checklist.setReadOnly(True)
        lay.addWidget(QtWidgets.QLabel("Verify from OFF this network (the wizard cannot see your WAN):"))
        lay.addWidget(self.checklist, 1)
        self.refresh_btn = QtWidgets.QPushButton("Recheck posture (driver status)")
        self.refresh_btn.clicked.connect(self._recheck)
        lay.addWidget(self.refresh_btn)
        self.status = QtWidgets.QPlainTextEdit()
        self.status.setReadOnly(True)
        self.status.setMaximumHeight(120)
        lay.addWidget(self.status)

    def initializePage(self):
        o = self.wiz.opts
        d = o.domain or "<domain>"
        self.checklist.setPlainText(
            "  1. dig +short {d}         # resolves to your ingress IP / tunnel target\n"
            "  2. dig +short api.{d}\n"
            "  3. curl -I https://{d}/   # answers over TLS from the public edge\n"
            "  4. (tunnel) confirm cloudflared shows the tunnel HEALTHY;\n"
            "     (funnel)  tailscale funnel status shows it live.\n\n"
            "When all of the above pass, continue to the flip step. The driver's `commit`\n"
            "only writes the marker — it does not probe the edge, so this gate is yours."
            .replace("{d}", d))
        self.wiz.verify_ok = False
        self._recheck()

    def _recheck(self):
        self.status.setPlainText(self.wiz.driver.status_text())
        self.wiz.verify_ok = True   # advisory only; the flip arms on the typed domain


class GoLiveFlipPage(QtWidgets.QWizardPage):
    """NOTE — deliberately NO progress bar here (unlike GoLiveGeneratePage): the flip
    runs ``commit`` via :meth:`GoLiveDriver.run_commit_in_terminal`, which launches a
    DETACHED terminal emulator (``Popen(..., start_new_session=True)``, no piped
    stdout) — by design, since the driver's confirmation gate requires a real TTY and
    this front-end adds no -y/--yes bypass. There is therefore no line stream to feed a
    :class:`~...core.progress_parse.ProgressParser`, and the commit itself (write a
    marker file, optionally one more file) is near-instantaneous once confirmed — a bar
    with nothing honest to show would be exactly the fabricated-percent this module's
    design explicitly refuses. If a future change makes commit observable (e.g. an
    embedded pty pane), wire it the same way GoLiveGeneratePage does."""

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
            "The flip runs the driver's `commit`, which writes /etc/hugmesh/go-live "
            "(root); hugmesh-firewall-reconcile converges within 60s — no reboot. It "
            "opens in a TERMINAL because the driver runs its own confirmation prompt on a "
            "real TTY, with no bypass flag — this wizard passes no -y/--yes and adds no "
            "bypass. Rollback: `rollback` deletes the marker (button below).")
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
            "then needs the revert step too)")
        lay.addWidget(self.persist)
        self.flip_btn = QtWidgets.QPushButton("GO LIVE — open commit in a terminal")
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
        p = self.wiz.driver.provider(self.wiz.opts.provider)
        if p and p.mechanism in _NO_DOMAIN_MECHANISMS:
            # Onion needs NO flip — it is already reachable over Tor with the firewall
            # closed. Committing here would additionally open public 80/443, which a
            # Tor-only operator explicitly does not want. Say so plainly.
            self.warning.setText(
                "TOR ONION NEEDS NO FLIP: your .onion is already reachable with the "
                "host INTERNAL. Committing here would ALSO open public 80/443 — only "
                "do it if you additionally want a clearnet edge. For Tor-only exposure, "
                "skip the flip and just share the .onion.")
            self.confirm.setPlaceholderText(
                "type the domain to arm the (optional) clearnet flip — Tor needs none")
        else:
            self.warning.setText(f"ABOUT TO GO PUBLIC: {d} will accept public 80/443 "
                                 "within 60s of the flip.")
            self.confirm.setPlaceholderText("type the domain exactly to arm the flip")
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
        ok, msg = self.wiz.driver.run_commit_in_terminal(self.wiz.opts,
                                                         persist=self.persist.isChecked())
        self._report(ok, msg)

    def _rollback(self):
        if QtWidgets.QMessageBox.question(
                self, "Rollback",
                "Delete the go-live marker (device reverts to INTERNAL within 60s)?"
        ) != QtWidgets.QMessageBox.StandardButton.Yes:
            return
        revert = QtWidgets.QMessageBox.question(
            self, "Rollback",
            "ALSO reset release-state=internal?\n(Needed if you flipped with "
            "'persist' — otherwise the device stays public.)"
        ) == QtWidgets.QMessageBox.StandardButton.Yes
        ok, msg = self.wiz.driver.run_rollback_in_terminal(revert_release_state=revert)
        self._report(ok, msg)


class GoLiveWizard(QtWidgets.QWizard):
    """Internal-only → publicly live, in seven guided steps — the Studio face of
    the one shared driver (hugmesh-go-live-cli / -menu drive the same
    subcommands)."""

    def __init__(self, generator_dir, parent=None):
        super().__init__(parent)
        self.generator_dir = os.path.abspath(generator_dir)
        self.driver = GoLiveDriver(self.generator_dir)
        self.opts = GoLiveOptions()
        self.model = ""             # chosen exposure model (mechanism -> model)
        self.token_secret = ""      # masked provider token — staged per run, never saved
        self.verify_ok = False
        self.setWindowTitle("HugMesh Go-Live Wizard")
        self.setWindowIcon(brand_icon())
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
