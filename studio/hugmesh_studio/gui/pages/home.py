"""HomePage — split into its two natural groups: HOME PROVISIONING (home mode/
device/backup + archive/seed extras + the per-user eCryptfs home) which is a
DESKTOP-class surface gated by ``home_options_allowed`` (spec 7 — nodes are root-
encrypted, they have no separately-provisioned home), and DISK ENCRYPTION (LUKS2
root + unlock factors) plus the local-login group, which stay in ALL modes. The
external media-data device keeps its own x86-only platform gate."""
from __future__ import annotations

from dataclasses import MISSING

from ..qt import QtWidgets
from ._scroll import scrollable
from ...core import cross_dracut
from ...core.config import (
    HOME_DESKTOP_FIELDS, PLATFORM_LABELS, ImageConfig, encrypt_root_always,
    external_media_applies, home_options_allowed, image_class, local_login_applies,
)
from ...core.worklist import resolve_encrypt_root
from ._gating import (
    capability_allows_flow,
    clear_unsupported,
    gate_widgets,
    gate_widgets_role_class,
    out_of_scope_note_flow,
    platform_supports,
    scope_allows_flow,
)
# Two axis rules this page must ANSWER THE SAME WAY as the pages that own them, rather
# than re-implement: "is this image unaffiliated" (BrandingPage, which gates the whole
# identity/look split on it) and "is --local-user already this image's default account"
# (SystemPage, which hides its own -u row on exactly that predicate).
from .branding import unaffiliated_image
from .system import default_user_is_local_user
from ._widgets import _file_picker, _row

# the media-data combo's leave-the-builder-default sentinel (the builder default is
# ON — an explicit "on" still emits --media-data so a brand.conf override loses)
_MEDIA_DEFAULT = "(builder default: on)"

# HOME_DESKTOP_FIELDS is desktop-class (spec 7): greyed+cleared on node/mesh images.
_HOME_ROLE_CLASS_REASON = (
    "Home provisioning applies to desktops only — nodes are root-encrypted; homes "
    "are not separately provisioned or encrypted. Cleared when you leave the page.")

# ASK 11, verbatim: "your login/standalone account doesnt belong on mesh builds, keep that
# to the desktop mesh track". The group is hidden, not greyed, for the same reason the
# home group is: a greyed control still advertises a decision, and there is no decision
# here — a cluster node's console credentials are SystemPage's "Node fallback login (mesh
# nodes)" group, which is a different pair of flags with a different lifetime.
_LOCAL_LOGIN_REASON = (
    "This is the DESKTOP login for a personal image — the account you sit down at. The "
    "images in this build are cluster nodes, which log in over SSO and keep their "
    "console/rescue credentials on the System step's \"Node fallback login\" group "
    "instead. Not offered here so one concept is not asked twice.")

# The Steam/Vaults media device: desktop-class for the same builder reason as the egress
# VPN row (see core.config.external_media_applies) — a node would emerge the package set
# for a session it does not have.
_MEDIA_ROLE_CLASS_REASON = (
    "An external Steam-library / Vaults data device belongs to a desktop image. On a "
    "cluster node the builder still emerges the media-data package set "
    "(packages-media-data.list) for a desktop session that never exists, so the wizard "
    "does not offer it here. Cleared when you leave the page.")

# ── the stack seed on an UNAFFILIATED image (operator report, 2026-08-26) ────────────
# "Seed stack code" offers none|repos|stack|mesh, and anything but "none" seeds the
# HugMesh stack into the home — which is affiliation, not look. It was visible AND
# enabled on the unaffiliated flow, where every non-"none" value makes to_cli_args()
# raise (config.py:3517 "home_seed_code (seeds the HugMesh stack into the home)")
# and the builder exits 1 (build-x86-host-stage4.sh:1591). A control whose only outcomes
# are "leave it alone" or "break the build" is not a choice: hidden, and reset to the
# dataclass default in validatePage.
_UNAFFILIATED_SEED_REASON = (
    "An unaffiliated image carries no HugMesh stack to seed — the builder hard-errors "
    "on any --home-seed-code but 'none' for this role. Not offered here; reset to "
    "'none' when you leave the page.")

# ASK: HomePage and SystemPage were asking for one account twice (see
# system.default_user_is_local_user). SystemPage's "Default user" row is hidden wherever
# --local-user really becomes the image's default account, so THIS group has to say what
# became of it — otherwise the -u knob just disappears with no account of where the value
# comes from.
#
# Shown on EXACTLY that predicate, never on "is this a desktop": on a plain ARM desktop
# --local-user is not emitted at all (config.py:3175's condition is false), so the first
# cut of this note claimed a flag the argv did not contain while the image quietly kept
# the builder's own DEFAULT_USER ("pi" on rpi5). The row is still offered on SystemPage
# there, so there is nothing for this note to explain either.
_LOCAL_USER_IS_DEFAULT_NOTE = (
    "This account is also the image's BAKED DEFAULT USER: this build passes it as "
    "--local-user and the builder makes that the image's DEFAULT_USER, so the System "
    "step does not ask for a second name.")

# Plain-language description of each home mode (the four values were opaque; each is a
# different way the local user's home is provisioned into the built image). Keyed by the
# combo's stored value strings — DO NOT change the keys (they are the emitted --home-mode).
_HOME_MODE_HELP = {
    "create": "create — provision a FRESH empty home for the local user (the default).",
    "adopt": "adopt — reuse an EXISTING home partition/device already on the target "
             "(set 'Home device' below to a LABEL= / UUID= / /dev path).",
    "archive": "archive — bake a home TARBALL straight into the image (set 'Home archive "
               "(bake in)' below). Use this to copy THIS machine's home into the build.",
    "restore": "restore — restore the home from a backup archive at install time "
               "(set 'Home backup (restore)' below).",
}


class HomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Home folder, encryption & login")
        self.setSubTitle("Provision the user's home folder, encrypt the target root disk "
                         "(LUKS2), and set the local login for this desktop.")
        lay = scrollable(self)
        # ---- Home provisioning (desktop-class; role-class gated) -----------------
        self.home_box = QtWidgets.QGroupBox("Home provisioning")
        hl = QtWidgets.QVBoxLayout(self.home_box)
        self.mode = QtWidgets.QComboBox()
        self.mode.addItems(["create", "adopt", "archive", "restore"])
        hl.addWidget(_row("Home mode", self.mode))
        # per-mode plain-language help (updates on selection) — the four modes were opaque
        self.mode_help = QtWidgets.QLabel("")
        self.mode_help.setWordWrap(True)
        self.mode_help.setStyleSheet("color: gray;")
        hl.addWidget(self.mode_help)
        self.mode.currentTextChanged.connect(self._mode_changed)
        # one-click preset for the reported "copy this machine's home folder" flow: it
        # selects archive mode (bake a home tarball INTO the image) and points at the
        # include-home-archive / seed-packages-from fields below. It only nudges the
        # controls — the user still picks the tarball, so nothing runs or copies here.
        self.copy_home_btn = QtWidgets.QPushButton("Copy this machine's home folder…")
        self.copy_home_btn.setToolTip(
            "Preset: sets Home mode = archive and points you at 'Home archive (bake in)' "
            "(a tarball of an existing home, e.g. tar czf home.tgz -C /home you) and, "
            "optionally, 'Seed packages from' (a package list to reinstall your apps).")
        self.copy_home_btn.clicked.connect(self._preset_copy_home)
        hl.addWidget(self.copy_home_btn)
        self.device = QtWidgets.QLineEdit()
        self.device.setPlaceholderText("LABEL=… | UUID=… | /dev/… (adopt)")
        hl.addWidget(_row("Home device", self.device))
        self.backup = QtWidgets.QLineEdit()
        bbtn = _file_picker(self, self.backup, "Home backup", "Backup (*.tar* *.gpg *.enc)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.backup, 1); h.addWidget(bbtn)
        self.backup_row = w   # greyed as one unit (line edit + Browse…) per platform
        hl.addWidget(_row("Home backup (restore)", w))
        self.encrypted = QtWidgets.QCheckBox("Per-user eCryptfs home (on top of LUKS root)")
        hl.addWidget(self.encrypted)
        self.seed = QtWidgets.QComboBox()
        self.seed.addItems(["none", "repos", "stack", "mesh"])
        # the ROW is a gate target too (the unaffiliated hide below, and the role-class
        # hide via _home_widgets): hiding the bare combo strands its "Seed stack code"
        # caption over an empty slot — network.py's orphan-caption rule, stated on the
        # egress section there ("_row()'s 'Egress VPN' caption … is not a gate member");
        # named rather than cited by line so it cannot rot on that module's next edit.
        self.seed_row = _row("Seed stack code", self.seed)
        hl.addWidget(self.seed_row)
        # home extras (G31): bake a home archive into the image (what makes
        # home_mode=archive actually work), seed code from a local checkout instead
        # of cloning, and seed the binpkg set from a package list — x86-only, greyed
        # as line-edit+Browse… row units like the backup row above.
        self.include_archive = QtWidgets.QLineEdit()
        abtn = _file_picker(self, self.include_archive, "Home archive to bake in",
                            "Archive (*.tar* *.tgz *.gpg *.enc)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.include_archive, 1); h.addWidget(abtn)
        self.include_archive_row = w
        hl.addWidget(_row("Home archive (bake in)", w))
        self.seed_code_from = QtWidgets.QLineEdit()
        sbtn = _file_picker(self, self.seed_code_from, "Seed home code from a local checkout",
                            directory=True)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.seed_code_from, 1); h.addWidget(sbtn)
        self.seed_code_from_row = w
        hl.addWidget(_row("Seed code from (dir)", w))
        self.seed_packages = QtWidgets.QLineEdit()
        pbtn = _file_picker(self, self.seed_packages, "Seed packages list",
                            "Package list (*.txt *.list);;All files (*)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.seed_packages, 1); h.addWidget(pbtn)
        self.seed_packages_row = w
        hl.addWidget(_row("Seed packages from", w))
        lay.addWidget(self.home_box)
        # the home-provisioning widgets role-class gating targets (individually, so
        # each widget's own enabled flag is set — never ancestor-shadowed).
        self._home_widgets = (self.mode, self.device, self.backup_row, self.encrypted,
                              self.seed, self.seed_row, self.include_archive_row,
                              self.seed_code_from_row, self.seed_packages_row)
        # external media-data device (G32): Steam library + gocryptfs Vaults set —
        # x86 standalone surface; only --steam was fielded before.
        media = QtWidgets.QGroupBox("External media-data device (Steam library + gocryptfs Vaults)")
        self.media_box = media          # gate target (ask 3): hidden on node-class flows
        ml = QtWidgets.QVBoxLayout(media)
        # tri-state like the proxy stack: leaving the builder default must round-trip,
        # so a plain checkbox (which collapses to explicit on/off) won't do.
        self.media_data = QtWidgets.QComboBox()
        self.media_data.addItems([_MEDIA_DEFAULT, "on", "off"])
        ml.addWidget(_row("Media-data device", self.media_data))
        self.media_label = QtWidgets.QLineEdit()
        self.media_label.setPlaceholderText("partition label ('' = builder default)")
        ml.addWidget(_row("Media label", self.media_label))
        self.no_vaults = QtWidgets.QCheckBox("No Vaults — drop the gocryptfs Vaults set")
        ml.addWidget(self.no_vaults)
        lay.addWidget(media)
        # local login account (--local-user / --local-pass). The password is hashed by
        # the builder at build time and is NEVER written to a saved config. NOT tied
        # to the standalone posture (G28): the ARM builders accept --local-user/
        # --local-pass independently (rename/hash the image's default account), and
        # x86 always bakes the local user.
        #
        # ASK 21 — "REMOVE the standalone user option from the Home-folder / encryption /
        # login step — there is no reason for it there". The --standalone CHECKBOX that
        # used to head this group is gone; it now sits on the RolePage beside the other
        # composable posture flags (--capable / --unaffiliated), which is where an
        # operator chooses what KIND of image this is. Nothing about the flag changed —
        # same field, same scope gate, same emission — and the Qt-free clear that used to
        # ride this page's collect moved into config.clear_role_class_fields, so a stale
        # tick still cannot survive a mode/role switch into a node's argv.
        self.login = QtWidgets.QGroupBox("Your login")
        login = self.login
        ll = QtWidgets.QVBoxLayout(login)
        # standalone framing (spec 4): on the standalone path the local user + root-disk
        # password ARE the primary action — say so plainly at the top of the group.
        self.standalone_helper = QtWidgets.QLabel(
            "This is your standalone login and full-disk-encryption setup — the account "
            "you log in with, and the passphrase that encrypts the whole disk.")
        self.standalone_helper.setWordWrap(True)
        self.standalone_helper.setStyleSheet("color: gray;")
        ll.addWidget(self.standalone_helper)
        self.local_note = QtWidgets.QLabel(
            "User/password below also compose WITHOUT Standalone: on ARM a "
            "customized name or password renames/hashes the image's default account; "
            "x86 always bakes the local user.")
        self.local_note.setWordWrap(True)
        ll.addWidget(self.local_note)
        self.local_user = QtWidgets.QLineEdit()
        ll.addWidget(_row("Local user", self.local_user))
        # ...and what happened to SystemPage's "Default user" (see the constant).
        self.local_user_note = QtWidgets.QLabel(_LOCAL_USER_IS_DEFAULT_NOTE)
        self.local_user_note.setWordWrap(True)
        self.local_user_note.setStyleSheet("color: gray;")
        ll.addWidget(self.local_user_note)
        self.local_pass = QtWidgets.QLineEdit()
        self.local_pass.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.local_pass.setPlaceholderText("hashed at build time; NOT saved to configs")
        ll.addWidget(_row("Local password", self.local_pass))
        lay.addWidget(login)
        # root-disk encryption (installer LUKS2 FDE) + unlock factors — the node-relevant
        # remainder: stays live in ALL modes (in mesh it becomes the worklist
        # encrypt_root default; jetson entries are auto-exempted in materialize()).
        enc = QtWidgets.QGroupBox("Root-disk encryption (LUKS2 full-disk)")
        el = QtWidgets.QVBoxLayout(enc)
        # ASK 21 — "root disk encryption should always be enabled". This is no longer a
        # choice, so it is no longer offered as one: the box is CHECKED and DISABLED, a
        # statement of what the image will do rather than a knob that happens to default
        # on. It stays a checkbox (not a bare label) because that is the shape operators
        # scan for the answer to "is this disk encrypted?", and because every established
        # test + the platform gate below address it by that name. The one platform that
        # genuinely cannot is jetson, and it is handled the same way it always was: the
        # box is HIDDEN and no_enc_note says why (see initializePage).
        self.encrypt_root = QtWidgets.QCheckBox(
            "Encrypt the target root (--encrypt-root; installer prompts for a passphrase)")
        self.encrypt_root.setChecked(True)
        self.encrypt_root.setEnabled(False)
        self.encrypt_root.setToolTip(
            "Always on: every image the Studio builds encrypts its installed root with "
            "LUKS2. The only exception is a platform whose builder has no FDE path "
            "(jetson), where this row is replaced by a plain explanation.")
        el.addWidget(self.encrypt_root)
        # The consequence, stated in EVERY mode — not only mesh. On x86 the builder
        # turns --encrypt-root into INSTALLER_ISO=true unconditionally
        # (build-x86-host-stage4.sh:1780), so a cloud desktop client that never asked
        # for an installer ISO now gets one; and with no passphrase the installer
        # prompts at install time, which stalls an unattended install. The mesh-specific
        # note below adds only the fleet-scale framing.
        self.enc_always_note = QtWidgets.QLabel(
            "Always on. Two consequences on x86: the build ALSO produces an installer "
            "ISO (the encrypted root is created by the installer), and unless you set a "
            "passphrase below the installer asks for one at install time.")
        self.enc_always_note.setWordWrap(True)
        self.enc_always_note.setStyleSheet("color: gray;")
        el.addWidget(self.enc_always_note)
        # device-cannot-encrypt note (spec 4): shown INSTEAD of the checkbox when the
        # target platform has no full-disk-encryption path (jetson's single boot+root
        # partition — see docs/STANDALONE-DESKTOP.md). Dormant in standalone (jetson is
        # not a standalone platform) but correct if reached, and shares the predicate
        # with the mesh worklist's per-row jetson handling.
        self.no_enc_note = QtWidgets.QLabel("")
        self.no_enc_note.setWordWrap(True)
        self.no_enc_note.setStyleSheet("color: #a65d00;")
        el.addWidget(self.no_enc_note)
        # ASK 12 — encrypted root is now the MESH DEFAULT (config.enter_mesh_defaults,
        # applied on arrival in mesh). That changes what the build PRODUCES, so say so
        # here rather than let an operator discover it from the artifact list: on x86
        # --encrypt-root also forces INSTALLER_ISO=true (build-x86-host-stage4.sh:1780),
        # and with no passphrase supplied the installer asks for one interactively.
        self.enc_mesh_note = QtWidgets.QLabel(
            "Mesh: node disks hold the cluster's PKI material, so root encryption is on "
            "for every node in the worklist (jetson rows are exempt — that builder has "
            "no FDE path; a single row can still be exempted in the worklist step's "
            "Encryption column). Two consequences: each x86 node ALSO produces an "
            "installer ISO, and unless you set a passphrase below the installer prompts "
            "for one at install time — which stalls an unattended fleet install.")
        self.enc_mesh_note.setWordWrap(True)
        self.enc_mesh_note.setStyleSheet("color: gray;")
        self.enc_mesh_note.setVisible(False)
        el.addWidget(self.enc_mesh_note)
        # ASK 21, the half the x86 note cannot state: on the eight ARM platforms
        # --encrypt-root is not just "an extra artifact". It forces the installer
        # artifact on AND drags in the arm64 disk-boot initramfs, whose absence makes
        # the builder exit 1 at its cross-dracut preflight before any work happens
        # (core/cross_dracut.py names the exact call sites). Filled + shown per visit
        # from the rows this flow actually builds; empty (and hidden) on an all-x86
        # flow, so it never degrades into boilerplate.
        self.enc_cross_note = QtWidgets.QLabel("")
        self.enc_cross_note.setWordWrap(True)
        self.enc_cross_note.setStyleSheet("color: #a65d00;")
        self.enc_cross_note.setVisible(False)
        el.addWidget(self.enc_cross_note)
        self.luks_pass = QtWidgets.QLineEdit()
        self.luks_pass.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.luks_pass.setPlaceholderText("optional unattended passphrase; NOT saved to configs")
        el.addWidget(_row("LUKS passphrase", self.luks_pass))
        self.unlock_keyfile = QtWidgets.QComboBox()
        self.unlock_keyfile.addItems(["(off)", "boot", "login"])
        # Provenance is otherwise invisible from this page, so spell it out here
        # (build-x86:7212 generates the 4 KiB keyfile onto the installer ISO;
        # specs-x86/installer/install-x86.sh:175 luksAddKey's it as a 2nd keyslot and
        # :201 installs it to the ESP as /boot/cryptroot.key).
        self.unlock_keyfile.setToolTip(
            "Where the keyfile comes from:\n"
            "  boot — the BUILD generates a random 4 KiB keyfile (build host\n"
            "    /dev/urandom) onto the installer ISO; the installer enrolls it as a\n"
            "    SECOND LUKS keyslot and installs it to the ESP as /boot/cryptroot.key\n"
            "    for unattended unlock. A recovery copy lands in the work dir\n"
            "    (<image>.luks-keyfile — stash it on a KEYS USB). The install-time\n"
            "    passphrase keyslot still works. Note: the ESP is unencrypted, so a\n"
            "    stolen whole disk auto-unlocks — choose (off) for theft protection.\n"
            "  login — no keyfile is generated at build; a marker makes it a PAM\n"
            "    factor enrolled at first login (desktop images only).\n"
            "  (off) — no keyfile anywhere; boot prompts for the passphrase chosen\n"
            "    at install time.")
        el.addWidget(_row("Keyfile unlock", self.unlock_keyfile))
        self.unlock_yubikey = QtWidgets.QComboBox()
        self.unlock_yubikey.addItems(["(off)", "boot", "login"])
        el.addWidget(_row("YubiKey unlock", self.unlock_yubikey))
        self._unlock_combos = (self.unlock_keyfile, self.unlock_yubikey)
        lay.addWidget(enc)
        lay.addStretch(1)

    def _mode_changed(self, _text: str = "") -> None:
        self.mode_help.setText(_HOME_MODE_HELP.get(self.mode.currentText(), ""))

    def _sync_unlock_choices(self, c) -> None:
        """Offer the "login" unlock factor only on a desktop-class image (finding 8).

        The builder writes the login-factor marker from inside its `elif ${ROLE_CLIENT}`
        branch (build-x86-host-stage4.sh:4368-4369), so on a cluster-node role
        `--unlock-keyfile login` produces NO marker: the factor silently does not exist.
        The flag is still PARSED (:1068) and validated (:1595), so nothing errs — and
        `--unlock-yubikey login` even adds sys-auth/pam-u2f to the package set at :5107,
        which is NOT role-gated. So a node paid to emerge a PAM module for a login factor
        it was never going to have.

        Per-ITEM rather than per-field on purpose: "boot" is genuinely valid on a node (the
        installer enrolls it as a LUKS keyslot — specs-x86/installer/install-x86.sh:175),
        so this removes exactly the one
        choice the builder cannot honour and leaves the rest of the row working. FIELD_SCOPE
        is a field-level model and cannot express this, which is why it is a page-local rule
        and not a scope declaration — recording that rather than bending the model.
        """
        want = ["(off)", "boot"] + (["login"] if image_class(c.mode, c.role) == "desktop" else [])
        for combo in self._unlock_combos:
            if [combo.itemText(i) for i in range(combo.count())] == want:
                continue
            prev = combo.currentText()
            combo.blockSignals(True)
            combo.clear()
            combo.addItems(want)
            # A stale "login" picked while this was a desktop must not survive the switch;
            # fall back to "(off)" rather than silently re-reading as "boot" (which would
            # invent a boot-time factor the operator never asked for).
            combo.setCurrentText(prev if prev in want else "(off)")
            combo.blockSignals(False)

    def _preset_copy_home(self) -> None:
        # Nudge into the copy-an-existing-home flow (archive bakes a home tarball in);
        # the archive/seed fields below are the ones the user then fills. No I/O here.
        self.mode.setCurrentText("archive")
        self._mode_changed()

    def _cross_fde_ids(self, c) -> list[str]:
        """The ids of the images THIS flow builds that will hit the ARM cross-dracut
        preflight. Reads the worklist in mesh (each row carries its own platform and its
        own encrypt_root override) and the single image otherwise. Pure: no widget
        writes, no disk."""
        # what validatePage is about to commit — the posture, not the widget
        base_enc = encrypt_root_always(c)
        wl = getattr(self.wiz, "worklist", None)
        if c.mode == "mesh" and wl is not None and wl.entries:
            rows = [(e.id, e.platform, resolve_encrypt_root(e, base_enc))
                    for e in wl.entries]
        else:
            rows = [(f"{c.role or 'image'}.{c.platform or 'x86'}", c.platform, base_enc)]
        return cross_dracut.cross_fde_rows(rows)

    def initializePage(self):
        c = self.wiz.cfg
        self.mode.setCurrentText(c.home_mode)
        self._mode_changed()   # seed the help even when the mode == the default (no signal)
        self.device.setText(c.home_device)
        self.backup.setText(c.home_backup)
        self.encrypted.setChecked(c.home_encrypted)
        self.seed.setCurrentText(c.home_seed_code)
        self.include_archive.setText(c.include_home_archive)
        self.seed_code_from.setText(c.home_seed_code_from)
        self.seed_packages.setText(c.seed_packages_from)
        md = ImageConfig._tri(c.media_data)
        self.media_data.setCurrentText(md if md in ("on", "off") else _MEDIA_DEFAULT)
        self.media_label.setText(c.media_label)
        self.no_vaults.setChecked(c.no_vaults)
        self.local_user.setText(c.local_user)
        self.local_pass.setText(c.local_pass)
        # ask 21: a STATEMENT, re-asserted every visit. Reading the box back off cfg
        # would let a loaded config that predates this posture (encrypt_root=false)
        # render an unchecked, disabled box that the collect below then overrides — the
        # GUI would be lying about the image it is going to build.
        self.encrypt_root.setChecked(True)
        self.luks_pass.setText(c.luks_pass)
        # Finding 8: the "login" unlock factor is a DESKTOP-only choice, and unlike every
        # other finding here the scope is per-ITEM, not per-field — "boot" stays perfectly
        # valid on a node (the installer enrolls it into a LUKS keyslot), so hiding the
        # whole row would remove a working option. Only the one meaningless choice goes.
        self._sync_unlock_choices(c)
        self.unlock_keyfile.setCurrentText(c.unlock_keyfile or "(off)")
        self.unlock_yubikey.setCurrentText(c.unlock_yubikey or "(off)")
        # --home-* provisioning (incl. the archive/seed extras), the media-data set
        # and --unlock-keyfile/--unlock-yubikey are x86-only (config.py only emits
        # them from _x86_args(); no ARM builder parses any of them) — unlike
        # --encrypt-root/--luks-pass and the local-login group, which land on every
        # platform. Greyed per the capability table (G10) instead of silently
        # dropping the values from an ARM build's argv.
        gate_widgets(c.platform, {
            "home_mode": self.mode,
            "home_device": self.device,
            "home_backup": self.backup_row,
            "home_encrypted": self.encrypted,
            "home_seed_code": self.seed,
            "include_home_archive": self.include_archive_row,
            "home_seed_code_from": self.seed_code_from_row,
            "seed_packages_from": self.seed_packages_row,
            "media_data": self.media_data,
            "media_label": self.media_label,
            "no_vaults": self.no_vaults,
            "unlock_keyfile": self.unlock_keyfile,
            "unlock_yubikey": self.unlock_yubikey,
        })
        # role-class gate (spec 7): home provisioning is desktop-only — on a node/mesh
        # image HIDE the whole group (overriding any platform-enable) rather than
        # greying it, with the reason as the group tooltip. Emission stays preserved by
        # the role-class clear in validatePage (HOME_DESKTOP_FIELDS reset to defaults)
        # plus the every-visit re-gate that restores + collects the group again when a
        # desktop role is later selected. On desktop images the per-platform greying
        # above is left untouched.
        #
        # ASK 3 ("options for standalone desktops shouldnt appear in the mesh wizard"):
        # the predicate is asked of the FLOW, not of the shared mesh base. home_options_
        # allowed reads image_class(cfg.mode, cfg.role), and WorklistPage stamps cfg.role
        # from entries[0] — so a mesh worklist whose first checked row happened to be
        # rpi5-desktop or jetson-desktop (both are in ROLE_CHOICES["mesh"]) turned home
        # mode / device / backup / eCryptfs / seed back on for every node in it. Probe,
        # before this landed: base role='pki' -> hidden, base role='rpi5-desktop' -> shown,
        # SAME worklist. capability_allows_flow asks every row.
        home_allowed = capability_allows_flow(home_options_allowed, c, self.wiz)
        if not home_allowed:
            gate_widgets_role_class(list(self._home_widgets), False,
                                    _HOME_ROLE_CLASS_REASON, hide=True)
        else:
            # desktop role: the group is live — make sure a prior node-visit's hide is
            # undone (leave the per-platform greying + its tooltips above untouched).
            for w in self._home_widgets:
                w.setVisible(True)
        # standalone framing (spec 4): show the "this is your login + FDE" helper only on
        # the standalone path (a personal desktop), where the local user + root-disk
        # password ARE the primary action.
        self.standalone_helper.setVisible(c.mode == "standalone")
        # ASK 21 moved the --standalone CHECKBOX to RolePage, beside the other composable
        # posture flags, so HomePage no longer owns that widget and the gate that used to
        # sit here went with it (RolePage._sync_standalone_gate scopes it; RolePage's
        # collect writes c.standalone). The ASK 11 and ASK 3 gates below are NOT part of
        # that move and stay exactly as they are: without them local_user/local_pass and
        # the Steam media device return to every mesh node's screen.

        # ── ASK 11: the whole "Your login & standalone account" group ────────────────
        # The standalone CHECKBOX above was already scoped. The GROUP around it never was:
        # it is a bare QGroupBox added to the layout, nothing ever called setVisible on it,
        # and its title says "standalone account" on every mesh node's screen. Inside it
        # sit local_user (default: the invoking user, emitted as --local-user on EVERY x86 build) and
        # local_pass — which on a mesh flow rides the shared base that _materialize_one
        # deepcopies onto every entry, i.e. a desktop password baked into every node image.
        #
        # Emission-neutral by construction, which is why this is a hide and not a
        # narrowing of the FIELD: local_user stays at its dataclass default (so
        # --local-user <invoking user> is emitted exactly as before — the x86 builder honours it on
        # every role, :1732 — `if ${STANDALONE} || [ -n "${LOCAL_USER}" ] || …`, with no
        # role test in it — and inventing a class rule there would repeat the mistake
        # _STANDALONE_CLASS_GATED_PLATFORMS records), and local_pass is empty by default,
        # so the only thing that stops reaching a node is a password the operator typed on
        # a screen they should not have been shown.
        login_ok = capability_allows_flow(local_login_applies, c, self.wiz)
        gate_widgets_role_class(self.login, login_ok, _LOCAL_LOGIN_REASON, hide=True)
        # Say it only where it is TRUE: SystemPage still asks for the default account
        # itself on a node-class flow AND on a desktop whose builder never receives
        # --local-user (a plain ARM desktop), and claiming otherwise here would be a lie
        # about the argv — a measured one, the pre-fix rpi5-desktop walk carried neither
        # flag. Same predicate FUNCTION as the gate that hides that row, so the note and
        # the row cannot drift apart.
        #
        # ORDERING, stated because it is visible and NOT a defect: on an ARM desktop the
        # predicate depends on `local_user`, which THIS page collects — one page AFTER
        # SystemPage has already gated. So typing a custom name here (or a local
        # password) makes --local-user start being emitted mid-flow, and SystemPage's row
        # only catches up on its next initializePage (Qt does not re-init a page reached
        # by Back). The worst case is a redundant `--user pi --local-user dana` in ONE
        # argv, never a wrong image: every builder applies LOCAL_USER AFTER -u
        # (build-rpi5-stage4.sh:1022 parses -u, :1311 overrides it with LOCAL_USER;
        # build-x86-host-stage4.sh:1913 is that same line), so the account is `dana`
        # either way. Left alone rather than "fixed" by having this page reach over and
        # clear SystemPage's field — that would discard a -u the operator typed in the
        # same pass, on a page that does not own it.
        self.local_user_note.setVisible(default_user_is_local_user(c, self.wiz))
        # ── ASK 3: the external media-data device (Steam library + gocryptfs Vaults) ──
        # Had NO role-class gate at all — only the x86 platform one, which a mesh flow
        # passes unconditionally because WorklistPage forces the base platform to "x86".
        # So it was visible on every mesh node in BOTH probe runs, node-first and
        # desktop-first alike. It is the most literally "standalone desktop" surface on
        # the page: a Steam library.
        media_ok = capability_allows_flow(external_media_applies, c, self.wiz)
        gate_widgets_role_class(self.media_box, media_ok, _MEDIA_ROLE_CLASS_REASON,
                                hide=True)
        # device-cannot-encrypt (spec 4): hide the --encrypt-root checkbox and show a
        # plain reason when the target platform has no FDE path (jetson). luks_pass is
        # _ALL_PLATFORMS and emits regardless, so it is NOT hidden/cleared here.
        can_encrypt = platform_supports("encrypt_root", c.platform)
        self.encrypt_root.setVisible(can_encrypt)
        self.enc_always_note.setVisible(can_encrypt)
        self.no_enc_note.setVisible(not can_encrypt)
        # ask 12/21: the mesh consequence note rides WITH the checkbox — shown wherever
        # the box is on a mesh flow. No longer conditioned on cfg.encrypt_root: the
        # posture is unconditional now, so hiding the note when the value happened to be
        # false would hide it exactly when a loaded config most needs to be corrected.
        self.enc_mesh_note.setVisible(can_encrypt and c.mode == "mesh")
        # ask 21's ARM cost, computed from the rows this flow will actually build.
        cross = cross_dracut.cross_fde_note(self._cross_fde_ids(c),
                                            cross_dracut.preflight_ok())
        self.enc_cross_note.setText(cross)
        self.enc_cross_note.setVisible(bool(cross))
        if not can_encrypt:
            label = PLATFORM_LABELS.get(c.platform, c.platform or "x86")
            self.no_enc_note.setText(
                f"This device ({label}) cannot do full-disk encryption — the Orin's "
                "single boot+root partition has no separate LUKS path yet "
                "(docs/STANDALONE-DESKTOP.md).")
        # ── the stack seed on an unaffiliated image (see _UNAFFILIATED_SEED_REASON) ──
        # LAST WRITER on this row, so the predicate has to be the COMPOSED one: the
        # home_allowed block above re-shows every _home_widgets member (seed_row among
        # them) on a desktop flow, and a bare `not unaffiliated` here would then un-hide
        # the row on a mesh NODE — measured, before this composition: node flow showed
        # "Seed stack code" with an invisible combo under it. The REASON follows the
        # cause that actually rejected, never a blanket one (the "wrong why" trap
        # _gating.out_of_scope_note records). Re-gated every visit, so a switch back to
        # a branded desktop restores the row and its collectable value.
        unaffiliated = unaffiliated_image(c)
        seed_ok = home_allowed and not unaffiliated
        gate_widgets_role_class(
            self.seed_row, seed_ok,
            "" if seed_ok else (_UNAFFILIATED_SEED_REASON if unaffiliated
                                else _HOME_ROLE_CLASS_REASON),
            hide=True)
        self.mode_help.setVisible(home_allowed)
        self.copy_home_btn.setVisible(home_allowed)
        # the copy-home preset only makes sense where home provisioning is live — track
        # the (now fully gated) home-mode combo so it greys with it on ARM and on nodes.
        self.copy_home_btn.setEnabled(home_allowed and self.mode.isEnabled())

    def validatePage(self):
        c = self.wiz.cfg
        c.home_mode = self.mode.currentText()
        c.home_device = self.device.text().strip()
        c.home_backup = self.backup.text().strip()
        c.home_encrypted = self.encrypted.isChecked()
        c.home_seed_code = self.seed.currentText()
        # emission half of the unaffiliated seed gate: back to the ImageConfig default
        # ("none"), so a value picked before the role switch cannot reach a to_cli_args()
        # that raises on it. The gate decides the argv, not what the hidden widget holds.
        if unaffiliated_image(c):
            c.home_seed_code = ImageConfig.__dataclass_fields__["home_seed_code"].default
        c.include_home_archive = self.include_archive.text().strip()
        c.home_seed_code_from = self.seed_code_from.text().strip()
        c.seed_packages_from = self.seed_packages.text().strip()
        # Scope-gated collect for the media-data trio, mirroring the standalone line
        # below: the HIDDEN widgets keep their values, so without this a Steam device
        # picked while the flow was a desktop would ride a later switch to a node
        # worklist. Fields reset to their dataclass defaults rather than to the widget
        # state, so the gate is what decides the argv, not what happens to be on screen.
        media_ok = capability_allows_flow(external_media_applies, c, self.wiz)
        md = self.media_data.currentText()
        # MEDIA (ask 3): main's gated collect, kept verbatim. The fields lane predates
        # it and collected these ungated, which would put the Steam library + Vaults back
        # into every mesh node's config even with the widget hidden.
        c.media_data = ("" if md == _MEDIA_DEFAULT else md) if media_ok else ""
        c.media_label = self.media_label.text().strip() if media_ok else ""
        c.no_vaults = self.no_vaults.isChecked() and media_ok
        # (ask 21) c.standalone is NOT collected here any more — the checkbox moved to
        # the RolePage. The out-of-scope clear this line used to provide now lives in
        # config.clear_role_class_fields, which runs Qt-free at mesh entry AND inside
        # materialize() for every worklist row, so it covers the mesh flow this page
        # could only ever patch up after the fact.
        # ASK 11's emission half, also kept from main. `local_user` is collected
        # UNCONDITIONALLY on purpose: the x86 builder honours --local-user on every role,
        # the field defaults to the invoking user and is emitted on every x86 build, so blanking it
        # would change the argv of every existing mesh flow. `local_pass` is the one that
        # matters and the one that is gated: it is a SECRET_FIELD that would otherwise
        # ride the shared mesh base onto every node image.
        login_ok = capability_allows_flow(local_login_applies, c, self.wiz)
        c.local_user = self.local_user.text().strip() or c.local_user
        c.local_pass = self.local_pass.text() if login_ok else ""
        # ASK 21/22 — root encryption is ALWAYS enabled, so this is not a read of the
        # widget: it is the posture, asserted. This SUPERSEDES main's checkbox-driven
        # line. encrypt_root_always is False on exactly one platform (jetson, whose
        # builder hard-blocks --encrypt-root and whose to_cli_args RAISES if the flag is
        # set), which is also the platform whose checkbox is hidden above — so the
        # platform_supports guard main applied is subsumed, not dropped.
        c.encrypt_root = encrypt_root_always(c)
        c.luks_pass = self.luks_pass.text()
        # "login" is desktop-only (see _sync_unlock_choices): drop a stale one rather than
        # emit a factor the builder's ROLE_CLIENT branch will never write a marker for.
        # The combo is already repopulated on a node, so this only catches a value that
        # arrived from a loaded config rather than from this page.
        _factors_ok = image_class(c.mode, c.role) == "desktop"
        kf = self.unlock_keyfile.currentText()
        c.unlock_keyfile = "" if kf == "(off)" or (kf == "login" and not _factors_ok) else kf
        yk = self.unlock_yubikey.currentText()
        c.unlock_yubikey = "" if yk == "(off)" or (yk == "login" and not _factors_ok) else yk
        # x86-only fields (see initializePage) — force-clear on every other platform
        # so a stale choice picked while platform was x86 (or "") can never linger
        # into a saved config or a generated command for an ARM build.
        clear_unsupported(c, ("home_mode", "home_device", "home_backup",
                              "home_encrypted", "home_seed_code",
                              "include_home_archive", "home_seed_code_from",
                              "seed_packages_from",
                              "media_data", "media_label", "no_vaults",
                              "unlock_keyfile", "unlock_yubikey"))
        # role-class clear (spec 7, belt & braces mirroring materialize's
        # clear_role_class_fields I4): a node/mesh image carries no home provisioning,
        # so reset HOME_DESKTOP_FIELDS to defaults regardless of platform. FLOW-keyed to
        # match the gate above — clearing on the base while the gate showed the group (or
        # the reverse) is how a hidden field keeps a value, or a visible one loses it.
        if not capability_allows_flow(home_options_allowed, c, self.wiz):
            for fld in HOME_DESKTOP_FIELDS:
                f = ImageConfig.__dataclass_fields__[fld]
                setattr(c, fld, f.default_factory() if f.default is MISSING else f.default)
        return True
