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

PER DOMAIN (#587): the Inputs step offers every domain the device has BAKED
(``core.golive_domains.baked_domains`` — the cluster domain first, then
/etc/hugmesh/domains) in a picker that fills the single Public domain field, which
stays the default; the Generate step shows the plan for EVERY domain and the node's
onions (``core.golive_domains.plan_rows``) — which one this run exposes, and that the
others need a run of their own, because the driver takes one --domain per plan.

Secrets: tokens are taken in masked fields, staged into a 0600 temp file handed to
the driver as --token-file, deleted right after the run, and never persisted or
placed in argv — GoLiveOptions has no field for a secret value at all.
"""
from __future__ import annotations

import os

from ..qt import QtCore, QtGui, QtWidgets, Signal
from .. import console
from ..branding_icon import brand_icon
from ..choice_cards import ChoiceCard, ChoiceCardGroup
from .. import choice_nav
from ._scroll import scrollable
from ..wizard import _file_picker, _row
from ._widgets import label_finish_as_exit
from ...core.golive_domains import (NO_EXPORT_DOMAINS_NOTE, NO_EXTRA_DOMAINS_NOTE,
                                    baked_domains, export_candidates,
                                    export_step_applies, exposure_lines, plan_rows)
from ...core.golive_driver import GoLiveDriver, GoLiveOptions, _NO_DOMAIN_MECHANISMS
from ...core import org_export
from ...core.progress_parse import ProgressParser, track_phases

# exactly one page per slug, same order — mirrors WIZARD_PAGE_SLUGS' role for the
# build wizard (tests pin each slug to its page class). "org-export" is the optional
# step: GoLiveWizard.nextId skips it unless some domain names a GitHub org.
GOLIVE_PAGE_SLUGS = ("preflight", "exposure", "provider", "inputs",
                     "generate", "org-export", "verify", "flip")

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
        self.status = console.attach(QtWidgets.QPlainTextEdit())
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
        # six cards are taller than six radios were: scroll, never clip
        lay = scrollable(self)
        self.group = ChoiceCardGroup(self)
        self.models = wiz.driver.models()
        for i, model in enumerate(self.models):
            label, desc = MODEL_LABELS.get(model, (model, ""))
            # icon names mirror the registry's model ids ("golive-<model>"); a
            # registry-only model without a drawn icon renders card-without-icon
            # (choice_icons.paint ignores unknown names — never a crash).
            card = ChoiceCard(label, desc, icon_name=f"golive-{model}")
            card.setProperty("model", model)
            self.group.add_card(card, i)
            lay.addWidget(card)
        if self.models:
            self.group.button(0).setChecked(True)
        # ASK 14 — picking an exposure model IS proceeding. buttonClicked only, so
        # initializePage's reflect-an-earlier-choice setChecked never navigates.
        choice_nav.advance_on_choice(self, self.group)
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
        # PER DOMAIN (#587): every domain the device has baked, cluster domain first.
        # Picking one FILLS the field below (which stays the default and stays
        # editable) — the driver takes one --domain per run.
        self.domain_pick = QtWidgets.QComboBox()
        self.domain_pick.setToolTip(
            "The domains baked on this device: /etc/hugmesh/cluster-domain first, then "
            "/etc/hugmesh/domains. Each Go-Live run exposes ONE of them.")
        self.domain_pick.currentIndexChanged.connect(self._picked)
        # ``activated`` too: after typing another domain below, picking the entry the
        # combo ALREADY shows changes no index, so currentIndexChanged alone did
        # nothing and the field kept the typed text (the post-merge review of #645).
        self.domain_pick.activated.connect(self._picked)
        lay.addWidget(_row("Baked domains", self.domain_pick))
        self.domain_list_note = QtWidgets.QLabel("")
        self.domain_list_note.setWordWrap(True)
        self.domain_list_note.setStyleSheet("color: gray;")
        lay.addWidget(self.domain_list_note)
        self.domain = QtWidgets.QLineEdit()
        self.domain.setPlaceholderText("example.org (autofilled from /etc/hugmesh/cluster-domain when baked)")
        lay.addWidget(_row("Public domain", self.domain))
        self.domain_hint = QtWidgets.QLabel("")
        self.domain_hint.setStyleSheet("color: gray;")
        lay.addWidget(self.domain_hint)
        # The blocking-problem line. INLINE, never a QMessageBox: validatePage is called
        # by QWizard on Next, and a modal there spins a nested event loop that a headless
        # test can neither see nor dismiss — the run hangs until it is killed (the house
        # rule; build.py:359 states the same for its own validatePage). An inline red
        # label says the same sentence, next to the field it is about, and is readable by
        # a test as ordinary widget state.
        self.problem = QtWidgets.QLabel("")
        self.problem.setWordWrap(True)
        self.problem.setStyleSheet("color: #c62828;")
        self.problem.setVisible(False)
        lay.addWidget(self.problem)
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

    def _picked(self, idx: int) -> None:
        """A baked domain picked -> it becomes the Public domain (typed text wins
        until the operator picks again). Guarded: PyQt6 qFatals on a slot raise."""
        try:
            name = self.domain_pick.itemData(idx) if idx >= 0 else ""
            if name:
                self.domain.setText(name)
                self.domain_hint.setText("picked from the domains baked on this device")
        except Exception:                      # noqa: BLE001
            pass

    def _fill_domain_pick(self) -> None:
        baked = baked_domains(self.wiz.driver.autofill_domain())
        self.domain_pick.blockSignals(True)
        self.domain_pick.clear()
        for i, name in enumerate(baked):
            self.domain_pick.addItem(name + (" (cluster domain)" if i == 0 else ""), name)
        cur = self.domain.text().strip().lower() or self.wiz.opts.domain
        at = self.domain_pick.findData(cur)
        self.domain_pick.setCurrentIndex(at if at >= 0 else (0 if baked else -1))
        self.domain_pick.blockSignals(False)
        self.domain_pick.setEnabled(len(baked) > 1)
        self.domain_list_note.setText("" if len(baked) > 1 else NO_EXTRA_DOMAINS_NOTE)

    def initializePage(self):
        o = self.wiz.opts
        p = self.wiz.driver.provider(o.provider)
        # a stale block from a previous Next must not greet the operator on re-entry
        self.problem.setVisible(False)
        self.problem.setText("")
        if not self.domain.text().strip():
            baked = o.domain or self.wiz.driver.autofill_domain()
            self.domain.setText(baked)
            self.domain_hint.setText(
                "autofilled from the device's baked cluster domain" if baked and not o.domain
                else "")
        self._fill_domain_pick()
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
            self.problem.setText(
                "Domain required — every downstream step needs the public domain, and "
                "no baked cluster domain was found to autofill it. Enter it above.")
            self.problem.setVisible(True)
            self.domain.setFocus()
            return False
        self.problem.setVisible(False)          # the block is cleared
        self.problem.setText("")
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


#: The exposure pane fits its wrapped rows up to this height, then scrolls (and still
#: takes its share of any extra window height). A fixed 180 px box (the first post-merge
#: fix) cut the sixth row of a six-row plan at Fusion 9 pt behind a scrollbar.
EXPOSURE_PANE_MAX_PX = 320
#: ...and never shrinks below this many lines, so a one-row plan is still a pane.
EXPOSURE_PANE_MIN_LINES = 3


class _FittingPane(QtWidgets.QPlainTextEdit):
    """A read-only prose pane whose MINIMUM height follows its wrapped content: every
    row is read whole at the wizard's default size, up to :data:`EXPOSURE_PANE_MAX_PX`.

    The wrap depends on the width, so the fit is redone on every resize. It is
    measured on a clone of the document laid out at the width the pane has WITHOUT a
    vertical scrollbar — never on the live layout, whose wrap moves with that
    scrollbar (it appears, the viewport narrows, more lines wrap, more height is
    needed, it disappears: a fit read off the live layout oscillates on that edge,
    and read during a resize it is simply stale). The measure depends on the width
    alone, so setting the minimum height from it cannot feed back into it."""

    def setPlainText(self, text):
        super().setPlainText(text)
        self.fit_to_content()

    def resizeEvent(self, ev):
        super().resizeEvent(ev)
        self.fit_to_content()

    def content_height(self) -> int:
        """Pixels the wrapped text needs at the current width (no scrollbar), frame
        included; never less than :data:`EXPOSURE_PANE_MIN_LINES` lines."""
        src = self.document()
        probe = src.clone()
        try:
            probe.setDefaultFont(self.font())
            probe.setDocumentMargin(src.documentMargin())
            probe.setTextWidth(max(1, self.width() - 2 * self.frameWidth()))
            text_px = probe.size().height()
        finally:
            probe.deleteLater()
        floor = (EXPOSURE_PANE_MIN_LINES * self.fontMetrics().lineSpacing()
                 + 2 * src.documentMargin())
        return int(max(text_px, floor) + 2 * self.frameWidth() + 2)

    def fit_to_content(self):
        self.setMinimumHeight(min(self.content_height(), EXPOSURE_PANE_MAX_PX))


class GoLiveGeneratePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Generate & download")
        self.setSubTitle("Runs the driver's `plan` (dry-run — posture is NOT touched): renders "
                         "the autofilled record set / zone / checklist / DDNS updater into the "
                         "artifact dir, and stores the token in the keys layout.")
        lay = QtWidgets.QVBoxLayout(self)
        self.cmd = console.attach(QtWidgets.QPlainTextEdit())
        self.cmd.setReadOnly(True)
        self.cmd.setMaximumHeight(90)
        lay.addWidget(QtWidgets.QLabel("Command:"))
        lay.addWidget(self.cmd)
        # PER DOMAIN (#587): what EVERY domain on the device gets — this run's, the
        # ones that need a run of their own, and the node's onions.
        lay.addWidget(QtWidgets.QLabel("Per-domain exposure (this device):"))
        self.exposure = console.attach(_FittingPane())
        self.exposure.setReadOnly(True)
        # PROSE rows (each one's "how" is a sentence; the unreadable-export row carries
        # its remedy), not column-aligned build output: wrap at the widget's width so
        # the end of a row is read without scrolling sideways (the post-merge review
        # of #645 saw every onion row cut at the right edge). The box's height follows
        # its rows (a fixed 180 px cut the sixth row of a six-row plan behind a
        # scrollbar at 9 pt), and it grows with the window (the same stretch as the
        # run log) instead of stopping at a fixed maximum.
        self.exposure.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.WidgetWidth)
        lay.addWidget(self.exposure, 1)
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
        self.log = console.attach(QtWidgets.QPlainTextEdit())
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
        self.exposure.setPlainText("\n".join(exposure_lines(plan_rows(d, o))))
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
        console.write(self.log, "\n=== generating go-live artifacts (plan) ===")
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
        console.write(self.log, line)
        if self._parser is not None:
            self._apply_progress_state(self._parser.feed(line))

    def _finished(self, code):
        for p in self._staged:
            try:
                os.unlink(p)
            except OSError:
                pass
        self._staged = []
        console.write(self.log, f"=== plan exited {code} ===")
        if self._parser is not None:
            self._apply_progress_state(self._parser.finalize(code))
            self.progress_label.setText("done" if code == 0 else "FAILED")
        if code == 0:
            out = self.wiz.opts.out_dir or self.wiz.driver.default_out_dir
            console.write(self.log, f"artifacts in {out} — 'Open artifacts folder' shows them")
        self.generate_btn.setEnabled(True)

    def _open_folder(self):
        out = self.wiz.opts.out_dir or self.wiz.driver.default_out_dir
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(out))


class _ExportWorker(QtCore.QThread):
    """Runs org_export.plan / apply off the GUI thread (git archive of thirty
    repositories and pushes take minutes). ``done`` carries ("ok", value) or
    ("error", message); ``progress`` one line per repository as apply finishes it."""
    progress = Signal(object)
    done = Signal(object)

    def __init__(self, fn):
        super().__init__()
        self._fn = fn

    def run(self):
        try:
            self.done.emit(("ok", self._fn(lambda r: self.progress.emit(r))))
        except Exception as exc:                 # noqa: BLE001 — reported inline
            self.done.emit(("error", f"{type(exc).__name__}: {exc}"))


# the plan table's columns (tests pin the header words)
EXPORT_COLUMNS = ("Source", "Target", "Action", "Kind", "Files", "Rewritten",
                  "Excluded", "Result")
_UPDATE_LABELS = (
    (org_export.UPDATE_REFUSE, "Refuse an existing non-empty repository"),
    (org_export.UPDATE_BRANCH, "Push an existing repository to export/<stamp> instead"),
)


class GoLiveOrgExportPage(QtWidgets.QWizardPage):
    """The optional step: export a domain's repositories to its GitHub org.

    Shown only when some domain names an org (``applies``; the wizard's nextId skips
    it otherwise, so every existing flow is unchanged). Plan is the default and
    touches no repository; Apply is armed only by TYPING the org name (inline, never
    a modal) and runs on a worker. The plan text is ``org_export.plan_lines`` — the
    same lines the TUI step and the CLI print."""

    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Export to GitHub org")
        self.setSubTitle("Copy this domain's repositories into its GitHub organisation as "
                         "fresh single-commit snapshots, renamed for the org, plus a "
                         "<domain>.github.io site that builds them all. Plan first; "
                         "Apply only after typing the org name.")
        # a scroll area, never clipping: the table and the plan text grow with the
        # repository count, and the window's smallest size must still show every
        # control (the buttons and the confirmation sit ABOVE the table for that).
        lay = scrollable(self)
        self.intro = QtWidgets.QLabel(
            "Every git and gh call runs as YOU (your `gh auth login` and git credential "
            "helper): no token is stored or passed. Nothing is force-pushed, deleted or "
            "mirrored; an existing non-empty repository is refused unless it already "
            "holds the same tree, or you choose the export/<stamp> branch below.")
        self.intro.setWordWrap(True)
        self.intro.setStyleSheet("color: gray;")
        lay.addWidget(self.intro)
        self.source = QtWidgets.QComboBox()
        self.source.setToolTip("The domains that name a GitHub org: from the saved "
                               "meshes on this machine, and from config files you add.")
        self.source.currentIndexChanged.connect(self._source_picked)
        lay.addWidget(_row("Domain -> org", self.source))
        self.config_path = QtWidgets.QLineEdit()
        self.config_path.setPlaceholderText(
            "an export config, image config or saved-mesh JSON with a GitHub org")
        pick = _file_picker(self, self.config_path, "Config file")
        self.add_btn = add = QtWidgets.QPushButton("Add")
        add.clicked.connect(self._add_config)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.config_path, 1); h.addWidget(pick); h.addWidget(add)
        lay.addWidget(_row("Config file", w))
        self.visibility = QtWidgets.QComboBox()
        self.visibility.addItems(list(org_export.VISIBILITY_CHOICES))
        self.visibility.setToolTip("Visibility of the repositories the export CREATES "
                                   "(private by default); existing ones are never changed.")
        self.update_mode = QtWidgets.QComboBox()
        for value, label in _UPDATE_LABELS:
            self.update_mode.addItem(label, value)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.visibility); h.addWidget(self.update_mode, 1)
        lay.addWidget(_row("Visibility / existing", w))
        self.source_dir = QtWidgets.QLineEdit()
        self.source_dir.setPlaceholderText("folder holding the hugmesh-* checkouts "
                                           "(empty = the mesh's clone root, .stack-src)")
        lay.addWidget(_row("Source folder", self.source_dir))
        self.out_dir = QtWidgets.QLineEdit()
        self.out_dir.setPlaceholderText("where the plan, work trees and result go "
                                        "(default <generator>/out/org-export/<domain>)")
        lay.addWidget(_row("Plan / work folder", self.out_dir))
        # extra rename rules and exclusions (the CLI's --rename-map): the way to drop
        # a file a banned-marker refusal points at without a terminal
        self.rename_map = QtWidgets.QLineEdit()
        self.rename_map.setPlaceholderText(
            "optional: a rename-map JSON (repos, tokens, skip_rewrite, exclude) merged "
            "over the defaults")
        self.rename_map.setToolTip(
            "Extra rename rules merged over the defaults, the CLI's --rename-map. Its "
            "'exclude' globs drop files from the snapshot — what a 'refused: banned "
            "marker' row points at (\"<repo>:<path>\").")
        self.rename_map.editingFinished.connect(self._refresh_cmd)
        pick = _file_picker(self, self.rename_map, "Rename map", "JSON (*.json);;All files (*)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.rename_map, 1); h.addWidget(pick)
        lay.addWidget(_row("Rename map", w))
        # the verbs: Plan always; Apply armed by the typed org name AND a clean plan
        self.plan_btn = QtWidgets.QPushButton("Plan (dry run — touches nothing)")
        self.plan_btn.clicked.connect(self._plan)
        self.confirm = QtWidgets.QLineEdit()
        self.confirm.setPlaceholderText("type the org name to arm Apply")
        self.confirm.textChanged.connect(self._armed)
        self.apply_btn = QtWidgets.QPushButton("Apply — create and push")
        self.apply_btn.setEnabled(False)
        self.apply_btn.clicked.connect(self._apply)
        bl = QtWidgets.QHBoxLayout()
        bl.addWidget(self.plan_btn); bl.addWidget(self.confirm, 1); bl.addWidget(self.apply_btn)
        lay.addLayout(bl)
        # INLINE status — never a message box (the headless-test rule, build.py:359)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setStyleSheet("color: #c62828;")
        self.status.setVisible(False)
        lay.addWidget(self.status)
        prow = QtWidgets.QHBoxLayout()
        self.progress_bar = QtWidgets.QProgressBar()
        self.progress_bar.setVisible(False)
        prow.addWidget(self.progress_bar, 1)
        self.progress_label = QtWidgets.QLabel("")
        self.progress_label.setVisible(False)
        prow.addWidget(self.progress_label)
        lay.addLayout(prow)
        self.table = QtWidgets.QTableWidget(0, len(EXPORT_COLUMNS))
        self.table.setHorizontalHeaderLabels(list(EXPORT_COLUMNS))
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setMinimumHeight(140)
        lay.addWidget(self.table)
        lay.addWidget(QtWidgets.QLabel("Plan (the same text the terminal step prints):"))
        self.plan_text = console.attach(QtWidgets.QPlainTextEdit())
        self.plan_text.setReadOnly(True)
        self.plan_text.setMinimumHeight(120)
        lay.addWidget(self.plan_text)
        self.cmd = QtWidgets.QLineEdit()
        self.cmd.setReadOnly(True)
        self.cmd.setToolTip("The same export from a terminal.")
        lay.addWidget(_row("Terminal", self.cmd))
        self.candidates: list = []
        self.plan = None
        self.result = None
        self.worker = None
        self._applying = None
        self._planning = False
        # every picker that changes the plan re-spells the Terminal line at once, so
        # what a person copies before Plan is what Plan would run (the rename-map
        # field used to be the only one wired, and a typed Source folder went stale).
        # The two folders go on textChanged, not editingFinished: nothing validates
        # them here, and a value set without a focus change (a driver, a paste) must
        # reach the line too — the e2e walk caught a stale line that way. The
        # rename-map field stays on editingFinished: it reads the file and would
        # otherwise say "cannot be read" on every half-typed character.
        #
        # They also DROP the plan on screen: Apply runs the plan it was armed by, not
        # whatever the pickers read now, so a plan made as public and then flipped
        # to private must not stay armed (it would create public repositories under
        # a screen that says private). Changing any picker means plan again.
        self.visibility.currentIndexChanged.connect(self._inputs_changed)
        self.update_mode.currentIndexChanged.connect(self._inputs_changed)
        self.source_dir.textChanged.connect(self._inputs_changed)
        self.out_dir.textChanged.connect(self._inputs_changed)
        self.rename_map.textChanged.connect(self._drop_plan)
        self.source.currentIndexChanged.connect(self._inputs_changed)
        self._pickers = (self.source, self.visibility, self.update_mode, self.source_dir,
                         self.out_dir, self.rename_map)
        self._plan_stale = False   # set by a dropped plan while a Plan runs: its result is for old inputs

    # ── the step applies only when some domain names an org ───────────────────────
    def applies(self) -> bool:
        return export_step_applies(self._candidates())

    def _candidates(self) -> list:
        return export_candidates(self.wiz.generator_dir, self.wiz.export_config_files)

    def initializePage(self):
        self._say("")                    # BEFORE the refresh: it may have something to say
        self.plan, self.result = None, None
        self.table.setRowCount(0)
        self.plan_text.setPlainText("")
        self.confirm.clear()
        self.apply_btn.setEnabled(False)
        self.progress_bar.setVisible(False)
        self.progress_label.setVisible(False)
        self._refresh_candidates()

    def _drop_plan(self, *_args) -> None:
        """Forget the plan on screen and disarm Apply (the TUI's ``export_plan = None``).
        A Plan still running when a picker changes is for the OLD inputs: its result
        is discarded when it arrives (``_plan_stale``). While an Apply runs the
        pickers are locked (see ``_apply``), so nothing can drop its plan."""
        had_plan = self.plan is not None
        if self._planning:                 # between Plan's click and its result being delivered
            self._plan_stale = True
        self.plan, self.result = None, None
        # a typed name arms the plan it was typed for, not whichever plan comes next:
        # without this a name typed under a private plan armed a later PUBLIC one
        self.confirm.clear()
        self.apply_btn.setEnabled(False)
        self.table.setRowCount(0)
        self.plan_text.setPlainText("")
        if had_plan:
            self._say("")                  # the blocked / skipped note was about that plan

    def _inputs_changed(self, *_args) -> None:
        self._drop_plan()
        self._refresh_cmd()                # the Terminal line is the PLAN line again

    def _refresh_candidates(self):
        self.candidates = self._candidates()
        self._drop_plan()                  # the combo's signals are blocked below
        self.source.blockSignals(True)
        self.source.clear()
        for i, c in enumerate(self.candidates):
            self.source.addItem(c.label(), i)
        self.source.blockSignals(False)
        if self.candidates:
            self.source.setCurrentIndex(0)
            self._source_picked(0)
        else:
            self._say(NO_EXPORT_DOMAINS_NOTE)

    def _source_picked(self, idx: int) -> None:
        try:
            c = self.candidates[idx] if 0 <= idx < len(self.candidates) else None
            if c is not None:
                self.source_dir.setText(c.source_dir if c.source_mode == "existing" else "")
                # a generic config file's own choices seed the pickers, so the plan
                # made here is the plan the file describes (the pickers stay editable)
                if c.config is not None:
                    self.visibility.setCurrentText(c.config.visibility)
                    at = self.update_mode.findData(c.config.update)
                    if at >= 0:
                        self.update_mode.setCurrentIndex(at)
                    self.out_dir.setText(c.config.out_dir)
                self._refresh_cmd()
        except Exception:                      # noqa: BLE001 — PyQt6 qFatals on a slot raise
            pass

    def _add_config(self):
        path = self.config_path.text().strip()
        if not path:
            return
        try:
            cands = org_export.candidates_from_file(path, self.wiz.generator_dir)
        except (OSError, ValueError) as exc:
            # the engine's own messages already start with the path: say it once
            self._say(str(exc) if str(exc).startswith(path) else f"{path}: {exc}")
            return
        if not cands:
            self._say(f"{path}: no domain in it names a GitHub org")
            return
        if path not in self.wiz.export_config_files:
            self.wiz.export_config_files.append(path)
        self._refresh_candidates()
        self.source.setCurrentIndex(self.source.count() - 1)
        self._say("")

    def _say(self, text: str) -> None:
        self.status.setText(text)
        self.status.setVisible(bool(text))

    # ── config -> plan -> apply ────────────────────────────────────────────────────
    def current_candidate(self):
        idx = self.source.currentIndex()
        return self.candidates[idx] if 0 <= idx < len(self.candidates) else None

    def export_config(self) -> org_export.ExportConfig | None:
        """The config a Plan here runs: the candidate's (a generic config file's own
        rules included), the pickers over it, and the rename-map file merged over
        its rename map. Raises ValueError/OSError for a rename map that cannot be
        read; the callers say so inline."""
        c = self.current_candidate()
        if c is None:
            return None
        src = self.source_dir.text().strip()
        # an empty Source folder is the clone root (.stack-src), as the field's
        # placeholder says — also for a saved mesh that recorded a folder and had
        # it cleared here; 'existing' with no folder would plan every source missing
        cfg = c.to_config(
            visibility=self.visibility.currentText(),
            update=self.update_mode.currentData() or org_export.UPDATE_REFUSE,
            out_dir=self.out_dir.text().strip(),
            source_mode="existing" if src else "clone",
            source_dir=src, generator_dir=c.generator_dir or self.wiz.generator_dir)
        rm = self.rename_map.text().strip()
        if rm:
            cfg.rename_map = org_export.merge_rename_maps(cfg.rename_map or {},
                                                          org_export.load_rename_map(rm))
        if self.wiz.export_remote_base:
            cfg.remote_base = self.wiz.export_remote_base
        return cfg

    def _cli_command(self, cfg, verb: str) -> str:
        c = self.current_candidate()
        return org_export.cli_command(
            cfg, verb,
            # EVERY candidate's file is handed over as --config: a saved mesh's or an
            # image config's selected services live only there, and a line spelling
            # just --domain/--org planned (and with --apply exported) fewer repositories
            config_path=c.path if c is not None else "",
            rename_map_path=self.rename_map.text().strip())

    def _refresh_cmd(self):
        try:
            cfg = self.export_config()
        except (OSError, ValueError) as exc:
            self._say(f"{self.rename_map.text().strip()}: {exc}")
            self._rename_map_said = True
            self.cmd.setText("")
            return
        if getattr(self, "_rename_map_said", False):
            self._say("")                     # the file reads now: the stale line goes
            self._rename_map_said = False
        self.cmd.setText(self._cli_command(cfg, "PLAN") if cfg else "")

    def _runner(self):
        return self.wiz.export_runner or org_export.SubprocessRunner()

    def _plan(self):
        if self.worker and self.worker.isRunning():
            return
        try:
            cfg = self.export_config()
            problems = cfg.problems() if cfg is not None else []
        except (OSError, ValueError) as exc:               # the rename-map file
            self._say(f"{self.rename_map.text().strip()}: {exc}")
            self._rename_map_said = True       # so a fixed field clears this line too
            return
        except Exception as exc:               # noqa: BLE001 — PyQt6 aborts the whole
            # process on an exception that leaves a slot; say it inline instead
            self._say(f"The export settings could not be read: {exc}")
            return
        if cfg is None:
            self._say(NO_EXPORT_DOMAINS_NOTE)
            return
        if problems:
            self._say("\n".join(problems))
            return
        self._say("")
        self.confirm.clear()               # a name typed for an earlier plan arms nothing
        self.plan, self.result = None, None
        self._plan_stale = False
        self._planning = True
        self.apply_btn.setEnabled(False)
        self.plan_btn.setEnabled(False)
        self.progress_bar.setRange(0, 0)
        self.progress_bar.setVisible(True)
        self.progress_label.setText("planning…")
        self.progress_label.setVisible(True)
        runner = self._runner()
        self.worker = _ExportWorker(lambda _progress: org_export.plan(cfg, runner))
        self.worker.done.connect(self._planned)
        self.worker.start()

    def _planned(self, outcome):
        kind, value = outcome
        self._planning = False
        self.plan_btn.setEnabled(True)
        self.progress_bar.setVisible(False)
        self.progress_label.setVisible(False)
        if self._plan_stale:
            # a picker changed while this ran: it planned inputs the screen no longer
            # shows, and arming Apply from it would export what nobody is looking at
            self._say("An input changed while the plan was running: plan again.")
            return
        if kind != "ok":
            self._say(f"Plan failed: {value}")
            return
        self.plan = value
        # whatever was typed while the plan ran was typed before the plan could be read
        self.confirm.clear()
        self._fill_table(self.plan)
        self.plan_text.setPlainText("\n".join(org_export.plan_lines(self.plan)))
        self.cmd.setText(self._cli_command(self.plan.config, "APPLY"))
        if self.plan.blocked:
            self._say("The plan is blocked (see the table): nothing is applied until every "
                      "repository is clean.")
        self._armed(self.confirm.text())

    def _fill_table(self, p):
        rows = [*p.repos, p.site]
        self.table.setRowCount(len(rows))
        for r, rp in enumerate(rows):
            cells = (rp.source or "(generated)", rp.target_full, rp.action, rp.kind,
                     str(rp.files), str(len(rp.rewrites)), str(len(rp.excluded)), "")
            for c, text in enumerate(cells):
                item = QtWidgets.QTableWidgetItem(text)
                if c == 2 and rp.blocked:
                    item.setForeground(QtGui.QColor("#c62828"))
                    item.setToolTip("\n".join([*rp.banned, *rp.notes]))
                self.table.setItem(r, c, item)
        # Sized from EVERY row's text, not resizeColumnsToContents(): that measures
        # only the rows inside the viewport, so with a 140 px table the last rows
        # (the site repository, the longest name) were elided once scrolled into view.
        fm = self.table.fontMetrics()
        for c in range(len(EXPORT_COLUMNS) - 1):            # the last one stretches
            texts = [EXPORT_COLUMNS[c]] + [self.table.item(r, c).text()
                                           for r in range(self.table.rowCount())]
            self.table.setColumnWidth(c, max(fm.horizontalAdvance(t) for t in texts) + 16)

    def _armed(self, text):
        p = self.plan
        ok = (p is not None and not p.blocked and self.result is None
              and bool(text.strip()) and text.strip().lower() == p.config.org.lower())
        self.apply_btn.setEnabled(ok)

    def _apply(self):
        p = self.plan
        if p is None or p.blocked or (self.worker and self.worker.isRunning()):
            return
        if self.result is not None:         # the plan is spent: plan again to run again
            self._say("This plan was applied. Plan again to run again.")
            return
        if self.confirm.text().strip().lower() != p.config.org.lower():
            self._say("Type the org name to arm Apply (letter case does not matter).")   # inline, never modal
            self.apply_btn.setEnabled(False)
            return
        self._say("")
        self.apply_btn.setEnabled(False)
        self.plan_btn.setEnabled(False)
        self._set_inputs_enabled(False)    # what is applied is the plan above: no picker moves now
        self._applying = p
        total = len(p.repos) + 1
        self.progress_bar.setRange(0, total)
        self.progress_bar.setValue(0)
        self.progress_bar.setVisible(True)
        self.progress_label.setText(f"0 / {total}")
        self.progress_label.setVisible(True)
        runner = self._runner()
        self.worker = _ExportWorker(lambda progress: org_export.apply(p, runner,
                                                                       progress=progress))
        self.worker.progress.connect(self._repo_done)
        self.worker.done.connect(self._applied)
        self.worker.start()

    def _repo_done(self, res):
        try:
            for r in range(self.table.rowCount()):
                if self.table.item(r, 1) and self.table.item(r, 1).text() == res.target:
                    text = res.action + (f" — SKIPPED: {res.skipped}" if res.skipped
                                         else f"  {res.branch} {res.commit[:12]}")
                    self.table.setItem(r, 7, QtWidgets.QTableWidgetItem(text))
            self.progress_bar.setValue(self.progress_bar.value() + 1)
            self.progress_label.setText(
                f"{self.progress_bar.value()} / {self.progress_bar.maximum()}")
        except Exception:                      # noqa: BLE001 — never raise in a slot
            pass

    def _set_inputs_enabled(self, on: bool) -> None:
        for w in (*self._pickers, self.config_path, self.add_btn):
            w.setEnabled(on)

    def _applied(self, outcome):
        kind, value = outcome
        p, self._applying = self._applying, None
        self.plan_btn.setEnabled(True)
        self._set_inputs_enabled(True)
        if kind != "ok" or p is None:
            self._say(f"Apply failed: {value}")
            return
        self.result = value
        self.plan_text.setPlainText("\n".join([*org_export.plan_lines(p), "",
                                               *org_export.result_lines(value)]))
        self.progress_label.setText("done" if not value.failures
                                    else f"done, {len(value.failures)} skipped")
        if value.failures:
            self._say("Some repositories were skipped — see the Result column and "
                      f"{value.result_path}.")
        self.apply_btn.setEnabled(False)       # one apply per plan: re-plan to run again


class GoLiveVerifyPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Verify the edge")
        self.setSubTitle("Confirm the public edge answers BEFORE flipping — the driver has no "
                         "verify subcommand, so this is an off-device checklist + a posture recheck.")
        lay = QtWidgets.QVBoxLayout(self)
        self.checklist = console.attach(QtWidgets.QPlainTextEdit())
        self.checklist.setReadOnly(True)
        lay.addWidget(QtWidgets.QLabel("Verify from OFF this network (the wizard cannot see your WAN):"))
        lay.addWidget(self.checklist, 1)
        self.refresh_btn = QtWidgets.QPushButton("Recheck posture (driver status)")
        self.refresh_btn.clicked.connect(self._recheck)
        lay.addWidget(self.refresh_btn)
        self.status = console.attach(QtWidgets.QPlainTextEdit())
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
        # LAST page of the go-live wizard, and its final button does nothing but close
        # the window: the flip is the in-page "GO LIVE" button below (it opens the
        # driver's own TTY confirmation), never the wizard button. So the wizard button
        # says Exit (_widgets.label_finish_as_exit).
        label_finish_as_exit(self)
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
        self.status = console.attach(QtWidgets.QPlainTextEdit())
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
        # the optional "Export to GitHub org" step: config files the person added on
        # it (candidates beyond the saved meshes), and two test seams — a runner that
        # stands in for git/gh, and a remote prefix other than github.com
        self.export_config_files: list[str] = []
        self.export_runner = None
        self.export_remote_base = ""
        self.setWindowTitle("HugMesh Go-Live Wizard")
        self.setWindowIcon(brand_icon())
        self.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
        self.resize(820, 640)
        self._pages = [
            GoLivePreflightPage(self), GoLiveExposurePage(self), GoLiveProviderPage(self),
            GoLiveInputsPage(self), GoLiveGeneratePage(self), GoLiveOrgExportPage(self),
            GoLiveVerifyPage(self), GoLiveFlipPage(self),
        ]
        assert len(self._pages) == len(GOLIVE_PAGE_SLUGS), (
            f"go-live pages ({len(self._pages)}) drifted from "
            f"GOLIVE_PAGE_SLUGS ({len(GOLIVE_PAGE_SLUGS)})")
        for p in self._pages:
            self.addPage(p)
        self._page_ids = dict(zip(GOLIVE_PAGE_SLUGS, self.pageIds()))

    def nextId(self):
        """The default order, except that the export step is SKIPPED when no domain
        names a GitHub org — so a flow with none sees exactly the pages it always
        did (the build wizard's applies_to idiom, for one page)."""
        nid = super().nextId()
        export_id = self._page_ids.get("org-export")
        if nid == export_id and export_id is not None:
            page = self.page(export_id)
            if not page.applies():
                ids = list(self.pageIds())
                i = ids.index(export_id)
                return ids[i + 1] if i + 1 < len(ids) else -1
        return nid

    # ── opened from a brand's Ways tab ─────────────────────────────────────────────
    def preselect_domain(self, name: str) -> None:
        """Fill the Inputs step's Public domain with ``name`` (the brand whose Ways tab
        asked). The typed field is what carries it: the picker above it lists only the
        domains baked on THIS device, which on a dev box is usually none, and the
        Inputs step autofills only an empty field. An empty name changes nothing."""
        name = (name or "").strip().lower()
        if not name:
            return
        self.opts.domain = name
        inputs = self._pages[GOLIVE_PAGE_SLUGS.index("inputs")]
        inputs.domain.setText(name)
        inputs.domain_hint.setText(FROM_WAYS_TAB_HINT)

    def before_inputs(self) -> bool:
        """True while the person has not gone past the Inputs step (a new domain can
        still be filled in without throwing away anything they did)."""
        ids = list(self.pageIds())
        cur = self.currentId()
        at = ids.index(cur) if cur in ids else 0
        return at <= GOLIVE_PAGE_SLUGS.index("inputs")


#: the Public domain's hint when a brand's Ways tab filled it in
FROM_WAYS_TAB_HINT = "filled in from the brand's ‘Ways to reach it’ tab"


def open_go_live(generator_dir: str, domain: str = "", current=None):
    """Show the Go-Live wizard with ``domain`` filled in, and return it — the receiver
    of every Brand settings ‘Set up ways to reach this brand’ button (image, Docker
    and Fleet routes alike).

    ``current`` is the wizard this caller opened last time, if any: while it is still
    open and has not gone past the Inputs step it is reused (the new domain filled
    in, the window raised); otherwise a new wizard opens, so a run already past the
    Inputs step is never thrown away. The caller keeps the returned wizard (a
    top-level window with no parent is closed by Python's garbage collector the
    moment nothing holds it). Shown, never exec()'d: no modal."""
    wiz = current
    reuse = False
    try:
        reuse = (wiz is not None and wiz.isVisible() and wiz.before_inputs()
                 and os.path.abspath(generator_dir) == wiz.generator_dir)
    except RuntimeError:                         # its C++ side was deleted
        reuse = False
    if not reuse:
        wiz = GoLiveWizard(generator_dir)
    wiz.preselect_domain(domain)
    wiz.show()
    wiz.raise_()
    wiz.activateWindow()
    return wiz
