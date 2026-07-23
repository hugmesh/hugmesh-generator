"""ModePage — STEP 1: pick ONE of six clearly-distinct things to build.

The first-screen choices map onto the EXISTING three emission modes plus three
non-image side-flows (design step1Taxonomy):

  - MESH NODE            -> cfg.mode="mesh"        (superadmin builds node images)
  - LOCAL DOCKER MESH    -> NO cfg.mode            (side-flow: run a dockerized mesh HERE)
  - MESH DESKTOP CLIENT  -> cfg.mode="cloud"       (branded tailnet + SSO client)
  - STANDALONE GENTOO    -> cfg.mode="standalone"  (hardened/unaffiliated personal desktop)
  - MDM PHONE            -> NO cfg.mode            (side-flow: flash+enroll a Pixel HERE)
  - CLOUD DEPLOY         -> NO cfg.mode            (side-flow: publish a packaged image to a cloud)

cfg.mode stays exactly {"standalone","cloud","mesh"} — unchanged — so to_cli_args() /
materialize() / the mesh manifest stay byte-identical for equivalent selections. The
LOCAL DOCKER MESH, MDM PHONE and CLOUD DEPLOY choices build no image, so they never
set cfg.mode: validatePage raises the transient ``wiz.localmesh_selected`` /
``wiz.phone_selected`` / ``wiz.deploy_selected`` flag and Next flows into the
registered LocalMeshPage / PhonePage / DeployPage (the operator rejected the old
modal popout), each dynamically skipping itself on every image-mode flow via
applies_to().
"""
from __future__ import annotations

from ..qt import QtWidgets
from ..styles import muted
from ...core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, UNAFFILIATED_ROLE, enter_mesh_defaults,
)


class ModePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("What do you want to build?")
        self.setSubTitle(
            "Pick one. Three of these build an image; LOCAL DOCKER MESH runs a mesh on "
            "this machine right now, MDM PHONE flashes + enrolls a USB Pixel, and "
            "CLOUD DEPLOY publishes an already-packaged image to a cloud provider.")
        lay = QtWidgets.QVBoxLayout(self)
        self.group = QtWidgets.QButtonGroup(self)
        # SIX clearly-distinct choices, in the spec's STEP-1 order. Each carries
        # property("mode"): the three IMAGE choices commit cfg.mode in validatePage
        # exactly as before; "localmesh", "phone" and "deploy" are transient side-flows
        # that never touch cfg.mode. The DEFAULT is chosen by id (standalone) below,
        # NOT by index, so a visual reorder can't change which choice the no-pick
        # default flow exercises.
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
             "desktop with zero HugMesh branding/tooling. No mesh, no SSO."),
            ("phone", "MDM phone",
             "Flash a USB Pixel with VERIFIED GrapheneOS and enroll it in the mesh — "
             "no image build. Runs the same driver right here."),
            ("deploy", "Cloud deploy",
             "Publish an already-built, cloud-packaged x86 image to a cloud provider "
             "(AWS / Azure / OpenShift / any qcow2 host) — no image build. Plans are "
             "rendered offline; apply is confirmed by the driver."),
        ]
        self._buttons = {}
        for i, (mid, label, desc) in enumerate(self.modes):
            rb = QtWidgets.QRadioButton(label)
            rb.setProperty("mode", mid)
            sub = QtWidgets.QLabel(desc)
            sub.setWordWrap(True)
            # muted (not bare "gray", which goes near-invisible on some dark palettes)
            sub.setStyleSheet(muted())
            sub.setContentsMargins(24, 0, 0, 8)
            self.group.addButton(rb, i)          # button id == index in self.modes
            self._buttons[mid] = rb
            lay.addWidget(rb)
            lay.addWidget(sub)
        # DEFAULT is standalone BY ID (not index) — test_standalone_flow_skips_admin_pages
        # relies on the no-pick default resolving to standalone (ImageConfig.mode default).
        self._buttons["standalone"].setChecked(True)

        # every choice now has a next page (localmesh flows into LocalMeshPage), so the
        # only live wiring left is keeping Next's enabled state fresh on change —
        # connected AFTER the default check so it fires only on change.
        self.group.buttonToggled.connect(self._on_mode_toggled)
        lay.addStretch(1)

    def _selected_mode(self):
        btn = self.group.checkedButton()
        return btn.property("mode") if btn is not None else None

    def _on_mode_toggled(self, *_):
        self.completeChanged.emit()

    def isComplete(self):
        # every choice has a next page now: the three image modes continue as before,
        # and LOCAL DOCKER MESH flows into the registered LocalMeshPage (the old modal
        # launcher premise — "the run happens in the popout" — is gone).
        return self._selected_mode() is not None

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
        # cfg.mode. It advances into the registered LocalMeshPage via the transient
        # wizard flag its applies_to() reads (never persisted — a loaded config always
        # re-selects a real image mode; see initializePage).
        self.wiz.localmesh_selected = (mid == "localmesh")
        # MDM PHONE is likewise a side-flow, not an image build: it commits NOTHING to
        # cfg.mode, advancing into the registered PhonePage via its own transient flag.
        self.wiz.phone_selected = (mid == "phone")
        # CLOUD DEPLOY is the third side-flow: it publishes an EXISTING packaged image
        # and commits NOTHING to cfg.mode, advancing into the registered DeployPage.
        self.wiz.deploy_selected = (mid == "deploy")
        if mid == "localmesh":
            return True
        if mid == "phone":
            return True
        if mid == "deploy":
            return True
        prev = self.wiz.cfg.mode
        self.wiz.cfg.mode = mid
        # a role from another mode is meaningless here — reset to the mode default
        # (RolePage preselects it and lets the user pick any role in the catalog; mesh
        # uses the WorklistPage, whose default row derives from this reset role)
        if self.wiz.cfg.role not in {r for r, _, _ in ROLE_CHOICES[mid]}:
            self.wiz.cfg.role = MODE_DEFAULT_ROLE[mid]
        # bundle the generator source only for standalone (self-hosting appliance);
        # cloud/mesh client images keep it off, mirroring the build script's default.
        # The UNAFFILIATED role must stay clear: bundling the HugMesh source is a
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
