"""ModePage — STEP 1: pick ONE of four clearly-distinct things to build.

The four first-screen choices map onto the EXISTING three emission modes plus one
non-image side-flow (design step1Taxonomy):

  - MESH NODE            -> cfg.mode="mesh"        (superadmin builds node images)
  - LOCAL DOCKER MESH    -> NO cfg.mode            (side-flow: run a dockerized mesh HERE)
  - MESH DESKTOP CLIENT  -> cfg.mode="cloud"       (branded tailnet + SSO client)
  - STANDALONE GENTOO    -> cfg.mode="standalone"  (hardened/unaffiliated personal desktop)

cfg.mode stays exactly {"standalone","cloud","mesh"} — unchanged — so to_cli_args() /
materialize() / the mesh manifest stay byte-identical for equivalent selections. The
LOCAL DOCKER MESH choice builds no image, so it never sets cfg.mode: it disables
Next/Finish (isComplete False) and runs from an inline modal launcher instead.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ...core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, UNAFFILIATED_ROLE, enter_mesh_defaults,
)


class ModePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("What do you want to build?")
        self.setSubTitle(
            "Pick one. Three of these build an image; LOCAL DOCKER MESH instead runs a "
            "mesh on this machine right now.")
        lay = QtWidgets.QVBoxLayout(self)
        self.group = QtWidgets.QButtonGroup(self)
        # FOUR clearly-distinct choices, in the spec's STEP-1 order. Each carries
        # property("mode"): the three IMAGE choices commit cfg.mode in validatePage
        # exactly as before; "localmesh" is a transient side-flow that never touches
        # cfg.mode. The DEFAULT is chosen by id (standalone) below, NOT by index, so a
        # visual reorder can't change which choice the no-pick default flow exercises.
        self.modes = [
            ("mesh", "Mesh node",
             "Superadmin: build the server node image(s) — PKI, backend, frontend, GPU, "
             "edge-AI — that run a mesh on dedicated hardware."),
            ("localmesh", "Local Docker mesh",
             "Run a mesh on THIS machine in Docker — no separate server hardware. "
             "Configure it and launch the dockerized node right here."),
            ("cloud", "Mesh desktop client",
             "Build a branded desktop that JOINS an existing mesh (tailnet + SSO). "
             "Load your admin-provided key-zip or configuration link."),
            ("standalone", "Standalone Gentoo desktop",
             "A personal hardened LUKS/SELinux desktop — or a plain UNAFFILIATED Gentoo "
             "desktop with zero Snapdragon branding/tooling. No mesh, no SSO."),
        ]
        self._buttons = {}
        for i, (mid, label, desc) in enumerate(self.modes):
            rb = QtWidgets.QRadioButton(label)
            rb.setProperty("mode", mid)
            sub = QtWidgets.QLabel(desc)
            sub.setWordWrap(True)
            sub.setStyleSheet("color: gray;")
            sub.setContentsMargins(24, 0, 0, 8)
            self.group.addButton(rb, i)          # button id == index in self.modes
            self._buttons[mid] = rb
            lay.addWidget(rb)
            lay.addWidget(sub)
        # DEFAULT is standalone BY ID (not index) — test_standalone_flow_skips_admin_pages
        # relies on the no-pick default resolving to standalone (ImageConfig.mode default).
        self._buttons["standalone"].setChecked(True)

        # LOCAL DOCKER MESH builds no image: its radio disables Next/Finish (isComplete
        # False) and reveals this inline launcher instead. The launcher opens the
        # self-contained LocalMeshDialog (deferred import — the FleetDialog/golive
        # precedent), which reuses core/mesh_node.py to run the local dockerized node.
        self.local_btn = QtWidgets.QPushButton("Configure & run local mesh…")
        self.local_btn.setToolTip(
            "Runs a mesh on this machine via docker compose — no server hardware. "
            "Provide a tailnet/headscale auth key; the node joins and serves locally.")
        self.local_btn.clicked.connect(self._launch_local_mesh)
        self.local_btn.setVisible(False)
        lay.addWidget(self.local_btn)

        # keep Next's enabled state (isComplete) and the launcher's visibility live as the
        # selection changes — connected AFTER the default check so it fires only on change.
        self.group.buttonToggled.connect(self._on_mode_toggled)
        lay.addStretch(1)

    def _selected_mode(self):
        btn = self.group.checkedButton()
        return btn.property("mode") if btn is not None else None

    def _on_mode_toggled(self, *_):
        self.local_btn.setVisible(self._selected_mode() == "localmesh")
        self.completeChanged.emit()

    def isComplete(self):
        # LOCAL DOCKER MESH has no image to advance to — the run happens in the modal
        # launcher, so Next/Finish stay disabled while it is selected. Every IMAGE choice
        # is always complete.
        return self._selected_mode() != "localmesh"

    def _launch_local_mesh(self):
        # deferred import: LocalMeshDialog is self-contained (FleetDialog/golive
        # precedent) and only needed if the operator actually opens it.
        from .localmesh import LocalMeshDialog
        LocalMeshDialog(self.wiz.generator_dir, parent=self.wiz).exec()

    def initializePage(self):
        # reflect the config's mode in the radios (a loaded config / back-navigation)
        # — otherwise the constructor's standalone default would silently clobber it
        # on the next validatePage. cfg.mode is only ever an IMAGE mode
        # (standalone/cloud/mesh); the transient localmesh radio is never restored from
        # cfg (it holds no cfg.mode), so a loaded config always re-selects a real choice.
        rb = self._buttons.get(self.wiz.cfg.mode)
        if rb is not None:
            rb.setChecked(True)
        self._on_mode_toggled()

    def validatePage(self):
        btn = self.group.checkedButton()
        if btn is None:
            return False
        mid = btn.property("mode")
        # LOCAL DOCKER MESH is a side-flow, not an image build: it commits NOTHING to
        # cfg.mode and never advances (isComplete gates Next off; this guard makes the
        # no-advance explicit even if validatePage is reached some other way).
        if mid == "localmesh":
            return False
        prev = self.wiz.cfg.mode
        self.wiz.cfg.mode = mid
        # a role from another mode is meaningless here — reset to the mode default
        # (RolePage preselects it and lets the user pick any role in the catalog; mesh
        # uses the WorklistPage, whose default row derives from this reset role)
        if self.wiz.cfg.role not in {r for r, _, _ in ROLE_CHOICES[mid]}:
            self.wiz.cfg.role = MODE_DEFAULT_ROLE[mid]
        # bundle the generator source only for standalone (self-hosting appliance);
        # cloud/mesh client images keep it off, mirroring the build script's default.
        # The UNAFFILIATED role must stay clear: bundling the Snapdragon source is a
        # builder hard-conflict there (RolePage clears it again when it's picked).
        self.wiz.cfg.bundle_source = (mid == "standalone"
                                      and self.wiz.cfg.role != UNAFFILIATED_ROLE)
        if mid == "mesh":
            # entering mesh: clear the desktop-class surfaces (theming/home/tailnet-SSO)
            # and force tailscale=sso on off-UI (materialize re-forces them per image),
            # so a mesh node can never carry a theme or a stale desktop option (I4).
            enter_mesh_defaults(self.wiz.cfg)
            if prev != "mesh":
                self.wiz.worklist = None      # fresh worklist on transition into mesh
        else:
            if prev == "mesh":
                # leaving mesh (any direction): stranded worklist rows must not survive a
                # mode switch (same rationale as the standalone admin-plane clear below).
                self.wiz.worklist = None
            if mid == "standalone":
                # standalone SKIPS the worklist/key-zip/domains/users pages
                # (MODE_SKIPPED_PAGES) — clear anything a previously visited cloud/mesh
                # flow parked in the config, so pages the user can no longer reach can't
                # strand stale state into save() or the emitted argv. Spec 3: standalone
                # images have no tailnet, so tailscale/sso are forced off (always emitted
                # as --no-tailscale/--no-sso).
                self.wiz.cfg.keyzip = ""
                self.wiz.cfg.domains = []
                self.wiz.cfg.users = []
                self.wiz.cfg.tailscale = False
                self.wiz.cfg.sso = False
        return True
