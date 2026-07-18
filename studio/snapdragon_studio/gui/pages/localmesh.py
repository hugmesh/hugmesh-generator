"""LocalMeshPage — the wizard page behind ModePage's fourth first-screen choice
("Local Docker mesh"). It runs a dockerized Snapdragon mesh on THIS machine (no
image build, no server hardware) — IN the wizard flow, not a popout.

Formerly a modal ``LocalMeshDialog(QDialog).exec()`` launched from ModePage; the
operator rejected exactly that ("should follow the same gui wizard and not pop out
a new window"), so the surface is now a real registered QWizardPage:
  - ModePage's localmesh radio sets ``wiz.localmesh_selected`` (transient, NEVER in
    cfg — ModePage.initializePage documents why cfg.mode stays an IMAGE mode);
  - ``applies_to()`` reads that flag, so the page is dynamically skipped on every
    image-mode flow (it emits ZERO ImageConfig fields — the nextId() ALL-OPTIONS
    guard holds trivially);
  - the page is TERMINAL for its branch (``nextId() == -1`` + setFinalPage): after
    running a docker mesh there is no image to build. Back returns to ModePage; the
    stack lives in docker, not in the page, so navigation never disturbs it.

TWO mutually-exclusive paths, surfaced as tabs (unchanged from the dialog):
  - JOIN an existing mesh with a key — collect a tailnet/headscale auth key + node
    knobs into a LocalMeshConfig and drive LocalMeshNode start/stop/logs.
  - GENERATE & START a NEW local mesh FROM SCRATCH — mint ALL credentials + bring
    up the full platform stack seeded with a fresh superadmin, via LocalMeshBootstrap.
    Nothing runs until the operator acknowledges the read-only plan preview.

NEW on the bootstrap tab (the operator's other two asks):
  - BRAND — the GUI was strictly less capable than its own CLI: collect_bootstrap()
    never passed ``brand=``, pinning every GUI run to secret/snapdragon/ while
    ``--brand`` worked fine. The picker lists the real brands/ catalog
    (discover_brands) and stays editable; validate() DNS-label-gates the slug
    exactly as gen-keystores.sh does.
  - SOURCE — where the buildable repo files come from: download/update all repos
    into ./.stack-src (the default; exactly what `make stack-up` has always done,
    now VISIBLE), or an existing tree (STACK_SRC=<dir> + STACK_NO_CLONE=1 so the
    operator's checkouts are never fetched/updated/git-reset — clone-all-repos.sh's
    update path is a `git reset --hard`). The third option (render from templates)
    is a permanently DISABLED radio with the reason inline: it answers "why isn't
    rendering here?" in-product, and a disabled control can never lie.

All verbs (join start/stop, bootstrap up/down) run on a _MeshWorker QThread — the
golive _DriverWorker precedent. up() shells `make stack-up`, a multi-minute docker
build; on the GUI thread it froze the old dialog solid (operator-reported). The
thread buys a RESPONSIVE WIZARD, not live progress: LocalStackNode buffers output
until exit (subprocess.run), so lines arrive at the end. That limitation is stated
in the status text, not faked with a progress bar.

``LocalMeshDialog`` survives as a thin standalone-host shim wrapping the page
(``LocalMeshDialog(generator_dir).exec()`` still works, per its original promise).
"""
from __future__ import annotations

import types

from ..qt import QtCore, QtWidgets, Signal
from ...core.local_mesh import LocalMeshConfig, LocalMeshNode
from ...core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig, _parse_web_locales,
    discover_brands)
from ._scroll import scrollable
from ._widgets import _row


class _MeshWorker(QtCore.QThread):
    """Runs ONE mesh verb (a zero-arg callable returning (ok, lines-or-msg)) off the
    GUI thread. Hold a reference on the page (self.worker) — a local would be GC'd
    mid-run and take the thread with it."""
    line = Signal(str)
    done = Signal(bool)

    def __init__(self, fn, parent=None):
        super().__init__(parent)
        self._fn = fn

    def run(self):  # noqa: D102 — QThread contract
        try:
            ok, out = self._fn()
        except Exception as e:  # a worker exception must NEVER abort the app
            ok, out = False, [f"!! {type(e).__name__}: {e}"]
        for ln in (out if isinstance(out, (list, tuple)) else [out]):
            if ln:
                self.line.emit(str(ln))
        self.done.emit(bool(ok))


class LocalMeshPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.generator_dir = wiz.generator_dir
        self.node = LocalMeshNode(self.generator_dir, LocalMeshConfig())
        self.boot = LocalMeshBootstrap(self.generator_dir, LocalMeshBootstrapConfig())
        self.worker: _MeshWorker | None = None
        self._running = False
        self.setTitle("Local Docker mesh")
        self.setSubTitle("Run a Snapdragon mesh on THIS machine in Docker — no image "
                         "build, no server hardware. This is the end of this path: "
                         "Finish closes the wizard; the mesh keeps running in Docker.")
        self.setFinalPage(True)

        # the bootstrap tab stacks ~15 rows + a plan preview — by far the tallest
        # page in the wizard (minimum ~670px). Wrap in the shared scroll area so a
        # tall page SCROLLS instead of growing the window (the _scroll.py contract;
        # Role/Network/Build/Home do the same) — without this, showing the page
        # grew the wizard ~50px and the jitter guard (#400) rightly failed.
        lay = scrollable(self)
        self.tabs = QtWidgets.QTabWidget()
        self.tabs.addTab(self._build_join_tab(), "Join an existing mesh with a key")
        self.tabs.addTab(self._build_bootstrap_tab(),
                         "Generate && start a NEW local mesh from scratch")
        lay.addWidget(self.tabs)

        # Shared status + log pane (used by BOTH tabs).
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        lay.addWidget(self.status)

        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)

    # ── wizard-flow contract ─────────────────────────────────────────────────────
    def nextId(self) -> int:
        # Terminal branch: no image follows a docker mesh. SnapdragonWizard.nextId's
        # skip walk is -1-safe (_dynamically_skipped returns False for nid < 0).
        return -1

    def applies_to(self, cfg) -> bool:  # noqa: ARG002 — the hook's fixed signature
        # localmesh is a WIZARD-transient choice, deliberately absent from cfg
        # (ModePage.initializePage: "cfg.mode is only ever an IMAGE mode"), so this
        # reads the wizard, not cfg. The page emits ZERO ImageConfig fields — it
        # drives LocalMeshBootstrapConfig, which never reaches builder argv — so the
        # ALL-OPTIONS skip guard holds trivially.
        return bool(getattr(self.wiz, "localmesh_selected", False))

    def isComplete(self) -> bool:
        # Finish stays disabled while a verb runs — leaving mid-up would orphan the
        # worker's signals into a destroyed page.
        return not self._running

    def initializePage(self):
        self._refresh_status()
        self._refresh_plan()

    # ── JOIN tab (handlers now threaded; widget names unchanged) ─────────────────
    def _build_join_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        intro = QtWidgets.QLabel(
            "Join an EXISTING mesh: run a Snapdragon mesh node on THIS machine in "
            "Docker — no separate server hardware and no image build. Provide a "
            "tailnet/headscale auth key; the dockerized node joins the mesh and serves "
            "locally.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        self.auth_key = QtWidgets.QLineEdit()
        self.auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.auth_key.setPlaceholderText("tskey-… (required — the tailnet/headscale auth key)")
        self.auth_key.setToolTip(
            "The pre-auth key the node's tailscale container joins with (staged as "
            "TS_AUTHKEY). Never saved to disk by this page beyond the local compose "
            "project's .env.")
        lay.addWidget(_row("Auth key", self.auth_key))

        self.node_name = QtWidgets.QLineEdit()
        self.node_name.setPlaceholderText("optional hostname on the tailnet (default: snapdragon-node)")
        lay.addWidget(_row("Node name", self.node_name))

        self.login_server = QtWidgets.QLineEdit()
        self.login_server.setPlaceholderText(
            "optional self-hosted headscale URL, e.g. https://headscale.example.com")
        self.login_server.setToolTip(
            "For a self-hosted headscale control plane — appended to TS_EXTRA_ARGS as "
            "--login-server=<url>. Leave empty to use Tailscale's default coordinator.")
        lay.addWidget(_row("Login server", self.login_server))

        btns = QtWidgets.QHBoxLayout()
        self.start_btn = QtWidgets.QPushButton("Start")
        self.stop_btn = QtWidgets.QPushButton("Stop")
        self.logs_btn = QtWidgets.QPushButton("View logs…")
        self.start_btn.clicked.connect(self._start)
        self.stop_btn.clicked.connect(self._stop)
        self.logs_btn.clicked.connect(self._logs)
        btns.addWidget(self.start_btn)
        btns.addWidget(self.stop_btn)
        btns.addWidget(self.logs_btn)
        btns.addStretch(1)
        lay.addLayout(btns)
        lay.addStretch(1)
        return w

    # ── BOOTSTRAP tab ────────────────────────────────────────────────────────────
    def _build_bootstrap_tab(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        intro = QtWidgets.QLabel(
            "Generate ALL credentials from scratch and start a NEW superadmin-"
            "controlled mesh on THIS machine: mint the Casdoor/DB/observability "
            "secrets + a fresh superadmin, bring up the full platform stack, and (in "
            "prod) attach the tailscale overlay. Nothing runs until you acknowledge "
            "the plan below.")
        intro.setWordWrap(True)
        lay.addWidget(intro)

        # ENV test/prod.
        self.env_group = QtWidgets.QButtonGroup(self)
        self.env_test = QtWidgets.QRadioButton("test — LAN-only / offline (safe default)")
        self.env_prod = QtWidgets.QRadioButton("prod — real public domain")
        self.env_test.setChecked(True)
        self.env_group.addButton(self.env_test)
        self.env_group.addButton(self.env_prod)
        envrow = QtWidgets.QHBoxLayout()
        envrow.addWidget(self.env_test)
        envrow.addWidget(self.env_prod)
        envrow.addStretch(1)
        lay.addWidget(_row("Environment", self._wrap(envrow)))

        # BRAND — the real catalog + an editable slug. Fixes the GUI-narrower-than-
        # CLI bug: collect_bootstrap() used to omit brand=, pinning every GUI run to
        # secret/snapdragon/ and the wrong <brand>-pki superadmin lookup.
        self.brand = QtWidgets.QComboBox()
        self.brand.setEditable(True)
        self.brand.addItems(discover_brands(self.generator_dir))
        self.brand.setToolTip(
            "The Vault base path segment (secret/<brand>/) AND the profile selector "
            "(brands/<brand>.conf, sourced by gen-cluster-secrets.sh when present). "
            "Must be a DNS label — the same gate gen-keystores.sh applies.")
        lay.addWidget(_row("Brand", self.brand))
        self.brand_note = QtWidgets.QLabel("")
        self.brand_note.setWordWrap(True)
        self.brand_note.setStyleSheet("color: gray;")
        lay.addWidget(self.brand_note)

        # SOURCE — where the buildable repo files come from. Radio labels derive
        # their count from the compose file compose actually reads — never a
        # hardcoded "all repos" claim.
        src_box = QtWidgets.QGroupBox("Repo source (what the stack builds from)")
        sl = QtWidgets.QVBoxLayout(src_box)
        n = len(self.boot.expected_contexts())
        self.src_clone = QtWidgets.QRadioButton(
            f"Download the source for all {n} repos into ./.stack-src and build from "
            f"there  [default]")
        self.src_clone.setToolTip(
            "What runs today: `make stack-clone` clones/updates each snapdragon-* repo "
            "from GIT_BASE, then compose builds every service from those files. Needs "
            "network on the first run.")
        self.src_clone.setChecked(True)
        sl.addWidget(self.src_clone)

        self.src_existing = QtWidgets.QRadioButton("Build from a source tree I already have:")
        sl.addWidget(self.src_existing)
        row = QtWidgets.QHBoxLayout()
        self.src_dir = QtWidgets.QLineEdit()
        self.src_dir.setPlaceholderText("directory holding snapdragon-<name> checkouts")
        self.src_browse = QtWidgets.QPushButton("Browse…")
        self.src_browse.clicked.connect(self._browse_src)
        row.addWidget(self.src_dir, 1)
        row.addWidget(self.src_browse)
        sl.addLayout(row)
        self.src_coverage = QtWidgets.QLabel("")
        self.src_coverage.setWordWrap(True)
        self.src_coverage.setStyleSheet("color: gray;")
        sl.addWidget(self.src_coverage)
        guard = QtWidgets.QLabel(
            "Your checkouts are NEVER fetched, updated, or git-reset in this mode "
            "(STACK_NO_CLONE=1 skips the clone/update step entirely).")
        guard.setWordWrap(True)
        guard.setStyleSheet("color: gray;")
        sl.addWidget(guard)

        # The honest deferral: a DISABLED radio can never lie.
        self.src_render = QtWidgets.QRadioButton(
            "Render repo source from templates — not available")
        self.src_render.setEnabled(False)
        sl.addWidget(self.src_render)
        why = QtWidgets.QLabel(
            "scripts/render-tenant-set.sh needs `cd scripts/tooling && npm install` "
            "(node deps absent), and only 3 archetypes exist for the fleet — the Spring "
            "BFFs and gateways render to a placeholder README with no buildable source. "
            "Use 'Download the source' above: it produces real, buildable files for "
            "every repo.")
        why.setWordWrap(True)
        why.setStyleSheet("color: gray;")
        sl.addWidget(why)
        lay.addWidget(src_box)

        self.superadmin = QtWidgets.QLineEdit("superadmin")
        self.superadmin.setToolTip(
            "The platform superadmin login to mint. Its password is generated fresh "
            "and written ONLY to the offline secrets bundle — never shown here.")
        lay.addWidget(_row("Superadmin", self.superadmin))

        self.social = QtWidgets.QCheckBox("Also bring up the social (Matrix/Mastodon) profile")
        lay.addWidget(self.social)

        # Web login languages. NOT a desktop-theming knob (those are x86-only and
        # skipped in mesh mode) — the web login is served to browsers BY the mesh,
        # so this is a cluster-plane fact and belongs here, on the config that
        # brings up the stack that builds the login-ui image. EMPTY = English-only
        # (the source language; smallest artifact; zero catalog requests).
        self.web_locales = QtWidgets.QLineEdit()
        self.web_locales.setPlaceholderText("English only — e.g. de, fr, pt-BR to add catalogs")
        self.web_locales.setToolTip(
            "Translation catalogs the web login IMAGE ships (comma-separated locale "
            "tags). English is the source language and always works with no catalog, "
            "so leaving this empty ships the smallest image and issues zero catalog "
            "requests. A locale here must have a catalog in the login-ui repo, or the "
            "login-ui image build fails loudly.")
        lay.addWidget(_row("Web login languages", self.web_locales))

        # prod-only overlay group.
        self.prod_group = QtWidgets.QGroupBox("Mesh overlay (prod only)")
        pg = QtWidgets.QVBoxLayout(self.prod_group)
        self.boot_domain = QtWidgets.QLineEdit()
        self.boot_domain.setPlaceholderText("public apex domain, e.g. example.com (required in prod)")
        pg.addWidget(_row("Domain", self.boot_domain))
        self.boot_auth_key = QtWidgets.QLineEdit()
        self.boot_auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.boot_auth_key.setPlaceholderText("tskey-… (required in prod — attaches the overlay)")
        pg.addWidget(_row("Auth key", self.boot_auth_key))
        self.boot_login_server = QtWidgets.QLineEdit()
        self.boot_login_server.setPlaceholderText("optional self-hosted headscale URL")
        pg.addWidget(_row("Login server", self.boot_login_server))
        lay.addWidget(self.prod_group)

        # Plan preview (read-only) — the confirm-before-run surface.
        lay.addWidget(QtWidgets.QLabel("Plan preview (what will be generated + started):"))
        self.plan_view = QtWidgets.QPlainTextEdit()
        self.plan_view.setReadOnly(True)
        self.plan_view.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        f = self.plan_view.font()
        f.setStyleHint(f.StyleHint.Monospace)
        f.setFamily("monospace")
        self.plan_view.setFont(f)
        lay.addWidget(self.plan_view, 1)

        self.ack = QtWidgets.QCheckBox(
            "I understand this will MINT credentials and START containers on this machine.")
        lay.addWidget(self.ack)

        brow = QtWidgets.QHBoxLayout()
        self.boot_start_btn = QtWidgets.QPushButton("Generate && start")
        self.boot_down_btn = QtWidgets.QPushButton("Stop")
        self.boot_start_btn.clicked.connect(self._bootstrap_up)
        self.boot_down_btn.clicked.connect(self._bootstrap_down)
        brow.addWidget(self.boot_start_btn)
        brow.addWidget(self.boot_down_btn)
        brow.addStretch(1)
        lay.addLayout(brow)

        # Live-refresh the plan + gate the start button on the acknowledgement.
        self.env_test.toggled.connect(self._refresh_plan)
        self.env_prod.toggled.connect(self._refresh_plan)
        self.brand.currentTextChanged.connect(self._refresh_plan)
        self.src_clone.toggled.connect(self._refresh_plan)
        self.src_existing.toggled.connect(self._refresh_plan)
        self.src_dir.textChanged.connect(self._refresh_plan)
        self.superadmin.textChanged.connect(self._refresh_plan)
        self.social.toggled.connect(self._refresh_plan)
        self.web_locales.textChanged.connect(self._refresh_plan)
        self.boot_domain.textChanged.connect(self._refresh_plan)
        self.boot_auth_key.textChanged.connect(self._refresh_plan)
        self.boot_login_server.textChanged.connect(self._refresh_plan)
        self.ack.toggled.connect(self._sync_boot_gate)
        self._refresh_plan()
        return w

    @staticmethod
    def _wrap(inner_layout) -> QtWidgets.QWidget:
        holder = QtWidgets.QWidget()
        holder.setLayout(inner_layout)
        return holder

    def _browse_src(self):
        d = QtWidgets.QFileDialog.getExistingDirectory(
            self, "Source tree holding snapdragon-<name> checkouts", self.src_dir.text())
        if d:
            self.src_dir.setText(d)

    # ── config collection ────────────────────────────────────────────────────────
    def collect(self) -> LocalMeshConfig:
        """JOIN-tab widgets -> LocalMeshConfig."""
        return LocalMeshConfig(
            auth_key=self.auth_key.text().strip(),
            node_name=self.node_name.text().strip(),
            login_server=self.login_server.text().strip(),
        )

    def collect_bootstrap(self) -> LocalMeshBootstrapConfig:
        """BOOTSTRAP-tab widgets -> LocalMeshBootstrapConfig — EVERY operator-visible
        control, so none can silently do nothing (the dead-default class: ``brand``
        was declared on the config but never passed here, making the GUI strictly
        less capable than the CLI's ``--brand``)."""
        return LocalMeshBootstrapConfig(
            env=("prod" if self.env_prod.isChecked() else "test"),
            superadmin_username=self.superadmin.text().strip() or "superadmin",
            social=self.social.isChecked(),
            cluster_domain=self.boot_domain.text().strip(),
            auth_key=self.boot_auth_key.text().strip(),
            login_server=self.boot_login_server.text().strip(),
            brand=self.brand.currentText().strip(),
            source_mode=("existing" if self.src_existing.isChecked() else "clone"),
            source_dir=self.src_dir.text().strip(),
            web_locales=_parse_web_locales(self.web_locales.text()),
        )

    # ── worker plumbing (the no-freeze fix) ──────────────────────────────────────
    def _launch(self, label: str, fn):
        """Run one verb off the GUI thread; buttons + Finish re-arm on done. The
        status text states the honest limitation: output arrives when the verb
        FINISHES (LocalStackNode buffers via subprocess.run) — the thread buys a
        responsive wizard, not live progress."""
        if self._running:
            return
        self._running = True
        self._set_verbs_enabled(False)
        self.status.setText(f"{label} — this can take several minutes; the wizard "
                            f"stays responsive. Output appears when the step finishes.")
        self.worker = _MeshWorker(fn, parent=self)
        self.worker.line.connect(self.log.appendPlainText)
        self.worker.done.connect(self._verb_done)
        self.completeChanged.emit()
        self.worker.start()

    def _verb_done(self, ok: bool):
        self._running = False
        self._set_verbs_enabled(True)
        self.status.setText("Done." if ok else "FAILED (see log).")
        self._refresh_status()
        self.completeChanged.emit()

    def _set_verbs_enabled(self, on: bool):
        for b in (self.start_btn, self.stop_btn, self.logs_btn, self.boot_down_btn):
            b.setEnabled(on)
        # the bootstrap start additionally requires the acknowledgement
        self.boot_start_btn.setEnabled(on and self.ack.isChecked())

    # ── JOIN handlers ────────────────────────────────────────────────────────────
    def _refresh_status(self):
        st = self.node.status()
        self.status.setText(f"Status: {'running' if st.running else 'stopped'} ({st.detail})")
        if not self._running:
            self.stop_btn.setEnabled(st.running)

    def _start(self):
        self.node = LocalMeshNode(self.generator_dir, self.collect())
        ok, why = self.node.available()
        if not ok:
            self.status.setText(f"Cannot start: {why}")
            return
        self.log.appendPlainText("[local-mesh] docker compose up -d …")
        self._launch("Starting the mesh node", self.node.start)

    def _stop(self):
        self._launch("Stopping the mesh node", self.node.stop)

    def _logs(self):
        self.log.setPlainText(self.node.logs() or "(no logs — node not started?)")

    # ── BOOTSTRAP handlers ───────────────────────────────────────────────────────
    def _refresh_plan(self):
        prod = self.env_prod.isChecked()
        self.prod_group.setVisible(prod)
        self.src_dir.setEnabled(self.src_existing.isChecked())
        self.src_browse.setEnabled(self.src_existing.isChecked())
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        # live, never-rounded-up coverage for the existing-tree mode
        if self.src_existing.isChecked():
            found, missing = self.boot.source_coverage()
            total = len(found) + len(missing)
            if not self.src_dir.text().strip():
                self.src_coverage.setText("")
            elif missing:
                head = ", ".join(missing[:4]) + (", …" if len(missing) > 4 else "")
                self.src_coverage.setText(
                    f"{len(found)} of {total} build contexts found. Missing: {head} — "
                    f"compose will fail when it builds those services.")
            else:
                self.src_coverage.setText(f"{total} of {total} build contexts found.")
        else:
            self.src_coverage.setText("")
        self.brand_note.setText(
            "" if self.boot.brand_has_conf() or not self.brand.currentText().strip()
            else f"No brands/{self.brand.currentText().strip()}.conf — runs with "
                 f"built-in defaults (profile presets stay unset).")
        self.plan_view.setPlainText(self.boot.plan())
        self._sync_boot_gate()

    def _sync_boot_gate(self):
        # The from-scratch start is gated behind the explicit acknowledgement — nothing
        # is generated or started on mere selection (non-destructive by default).
        self.boot_start_btn.setEnabled(self.ack.isChecked() and not self._running)

    def _bootstrap_up(self):
        if not self.ack.isChecked():
            self.status.setText("Acknowledge the plan first.")
            return
        self.boot = LocalMeshBootstrap(self.generator_dir, self.collect_bootstrap())
        problems = self.boot.validate()
        if problems:
            self.status.setText("Cannot start: " + "; ".join(problems))
            return
        for warn in self.boot.warnings():
            self.log.appendPlainText(f"WARNING: {warn}")
        self.log.appendPlainText("[bootstrap] generating credentials + starting the "
                                 "full platform stack from scratch …")
        self._launch("Bootstrapping", self.boot.up)

    def _bootstrap_down(self):
        self._launch("Stopping the stack", self.boot.down)


class LocalMeshDialog(QtWidgets.QDialog):
    """Thin standalone-host shim: ``LocalMeshDialog(generator_dir).exec()`` still
    works without any wizard, hosting the SAME LocalMeshPage (one implementation,
    two frames). The wizard flow itself never opens this — ModePage flows into the
    page via Next now."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Run a local Docker mesh")
        self.resize(720, 620)
        shim = types.SimpleNamespace(generator_dir=generator_dir,
                                     localmesh_selected=True)
        self.page = LocalMeshPage(shim)
        lay = QtWidgets.QVBoxLayout(self)
        lay.addWidget(self.page, 1)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.accept)
        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        row.addWidget(close)
        lay.addLayout(row)
        self.page.initializePage()

    def __getattr__(self, name):
        # FULL backward compatibility for the dialog's former surface: every widget
        # and handler (auth_key, tabs, plan_view, _start, _bootstrap_up, …) now lives
        # on the hosted page — delegate so pre-conversion callers keep working
        # unchanged. __getattr__ fires only when normal lookup MISSES, so the
        # dialog's own attributes (page, windowTitle, …) are never shadowed; the
        # __dict__ guard keeps a mid-__init__ lookup (before self.page exists) an
        # honest AttributeError instead of infinite recursion.
        page = self.__dict__.get("page")
        if page is None:
            raise AttributeError(name)
        return getattr(page, name)
