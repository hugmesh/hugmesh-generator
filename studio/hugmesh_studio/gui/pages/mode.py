"""ModePage — STEP 1: pick ONE of seven clearly-distinct things to build.

The first-screen choices map onto the EXISTING three emission modes plus four
non-image side-flows (design step1Taxonomy):

  - MESH NODE            -> cfg.mode="mesh"        (superadmin builds node images)
  - LOCAL DOCKER MESH    -> NO cfg.mode            (side-flow: run a dockerized mesh HERE)
  - MESH DESKTOP CLIENT  -> cfg.mode="cloud"       (branded tailnet + SSO client)
  - STANDALONE GENTOO    -> cfg.mode="standalone"  (hardened/unaffiliated personal desktop)
  - MDM PHONE            -> NO cfg.mode            (side-flow: flash+enroll a Pixel HERE)
  - MDM QUEST HEADSET    -> NO cfg.mode            (side-flow: enroll a Meta Quest 3/3S HERE)
  - CLOUD DEPLOY         -> NO cfg.mode            (side-flow: publish a packaged image to a cloud)

cfg.mode stays exactly {"standalone","cloud","mesh"} — unchanged — so to_cli_args() /
materialize() / the mesh manifest stay byte-identical for equivalent selections. The
LOCAL DOCKER MESH, MDM PHONE, MDM QUEST HEADSET and CLOUD DEPLOY choices build no
image, so they never set cfg.mode: validatePage raises the transient
``wiz.localmesh_selected`` / ``wiz.phone_selected`` / ``wiz.quest_selected`` /
``wiz.deploy_selected`` flag and Next flows into the registered LocalMeshPage /
PhonePage / QuestPage / DeployPage (the operator rejected the old modal popout),
each dynamically skipping itself on every image-mode flow via applies_to().
"""
from __future__ import annotations

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ..qt import QtWidgets
from ._scroll import scrollable
from ...core.config import (
    MODE_DEFAULT_ROLE, ROLE_CHOICES, UNAFFILIATED_ROLE, enter_mesh_defaults,
)

# option id -> choice_icons registry name (PRESENTATION only — the option ids the
# selection/emission plumbing reads stay exactly the historical mode ids).
_MODE_ICONS = {
    "mesh": "mesh",                 # three Pi boards under a cloud
    "localmesh": "localmesh",       # one desktop under a cloud
    "cloud": "mesh-desktop",        # a desktop beside peers + a board, under a cloud
    "standalone": "gentoo",         # our swirl-and-'g' gesture + the gentoo.org link
    "phone": "phone",               # a handset under a cloud
    "quest": "quest",               # a VR headset under a cloud
    "deploy": "cloud-deploy",       # three-way arrow up to AWS / AZURE / CF marks
}

_GENTOO_URL = "https://www.gentoo.org/"


class ModePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("What do you want to build?")
        self.setSubTitle(
            "Pick one. Three of these build an image; LOCAL DOCKER MESH runs a mesh on "
            "this machine right now, MDM PHONE flashes + enrolls a USB Pixel, MDM "
            "QUEST HEADSET enrolls a Meta Quest 3/3S, and CLOUD DEPLOY publishes an "
            "already-packaged image to a cloud provider.")
        # seven cards are taller than seven radios were: scroll, never clip
        lay = scrollable(self)
        self.group = ChoiceCardGroup(self)
        # SEVEN clearly-distinct choices, in the spec's STEP-1 order. Each carries
        # property("mode"): the three IMAGE choices commit cfg.mode in validatePage
        # exactly as before; "localmesh", "phone", "quest" and "deploy" are transient
        # side-flows that never touch cfg.mode. The DEFAULT is chosen by id
        # (standalone) below, NOT by index, so a visual reorder can't change which
        # choice the no-pick default flow exercises.
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
            ("quest", "MDM Quest headset",
             "Enroll a USB Meta Quest 3/3S as an MDM-managed mesh device (Headwind + "
             "tailnet + XR-chat URL) — no image build, no flash. Same driver, quest "
             "device class."),
            ("deploy", "Cloud deploy",
             "Publish an already-built, cloud-packaged x86 image to a cloud provider "
             "(AWS / Azure / OpenShift / any qcow2 host) — no image build. Plans are "
             "rendered offline; apply is confirmed by the driver."),
        ]
        self._buttons = {}
        for i, (mid, label, desc) in enumerate(self.modes):
            # one large clickable CARD per option (title + muted description in the
            # left column, the drawn-in-code icon right-aligned opposite them)
            card = ChoiceCard(label, desc, icon_name=_MODE_ICONS.get(mid, ""))
            card.setProperty("mode", mid)
            if mid == "standalone":
                # the Gentoo card names its upstream: EXPLICIT click hands the URL
                # to the desktop browser (QDesktopServices.openUrl inside the
                # card's guarded slot); the URL is also visible as selectable text
                # so an air-gapped operator can read it without clicking.
                card.set_link(_GENTOO_URL, "gentoo.org")
            self.group.add_card(card, i)         # button id == index in self.modes
            self._buttons[mid] = card
            lay.addWidget(card)
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
        # MDM QUEST HEADSET mirrors the phone side-flow: same driver, quest device
        # class — commits NOTHING to cfg.mode, advancing into the registered QuestPage.
        self.wiz.quest_selected = (mid == "quest")
        # CLOUD DEPLOY is the third side-flow: it publishes an EXISTING packaged image
        # and commits NOTHING to cfg.mode, advancing into the registered DeployPage.
        self.wiz.deploy_selected = (mid == "deploy")
        if mid in ("localmesh", "phone", "quest", "deploy"):
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
            #
            # fresh= distinguishes ARRIVING in mesh from re-walking the Mode step of a
            # flow that is already mesh. Only the arrival seeds the ask-12 encrypted-root
            # default: re-walking must never re-tick a box the operator has since
            # un-ticked on the Home step (which stepping Back through here would
            # otherwise do on every pass).
            enter_mesh_defaults(self.wiz.cfg, fresh=(prev != "mesh"))
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
                # ...and the two ask-19/20 FLOW flags that gate their tables. They are
                # mesh-only state; a standalone flow sees neither choice screen, so a
                # True left over from a mesh detour would be unreachable-but-saved.
                self.wiz.cfg.additional_domains = False
                self.wiz.cfg.configure_users = False
                self.wiz.cfg.tailscale = False
                self.wiz.cfg.sso = False
        return True
