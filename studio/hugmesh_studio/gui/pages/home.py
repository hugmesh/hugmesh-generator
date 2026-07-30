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
from ...core.config import (
    HOME_DESKTOP_FIELDS, PLATFORM_LABELS, ImageConfig, home_options_allowed, image_class,
)
from ._gating import (
    clear_unsupported,
    gate_widgets,
    gate_widgets_role_class,
    out_of_scope_note,
    platform_supports,
    scope_allows,
)
from ._widgets import _file_picker, _row

# the media-data combo's leave-the-builder-default sentinel (the builder default is
# ON — an explicit "on" still emits --media-data so a brand.conf override loses)
_MEDIA_DEFAULT = "(builder default: on)"

# HOME_DESKTOP_FIELDS is desktop-class (spec 7): greyed+cleared on node/mesh images.
_HOME_ROLE_CLASS_REASON = (
    "Home provisioning applies to desktops only — nodes are root-encrypted; homes "
    "are not separately provisioned or encrypted. Cleared when you leave the page.")

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
        hl.addWidget(_row("Seed stack code", self.seed))
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
                              self.seed, self.include_archive_row, self.seed_code_from_row,
                              self.seed_packages_row)
        # external media-data device (G32): Steam library + gocryptfs Vaults set —
        # x86 standalone surface; only --steam was fielded before.
        media = QtWidgets.QGroupBox("External media-data device (Steam library + gocryptfs Vaults)")
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
        # to the standalone checkbox (G28): the ARM builders accept --local-user/
        # --local-pass independently (rename/hash the image's default account), and
        # x86 always bakes the local user.
        self.login = QtWidgets.QGroupBox("Your login & standalone account")
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
        self.standalone = QtWidgets.QCheckBox(
            "Standalone: no mesh/SSO, local user below logs in with a build-time password "
            "(--standalone; client roles only — laptop/chromebook/desktop, rpi5-desktop/"
            "frite/orangepi5/orangepizero2[w]/orangepizero3. NOT jetson — --encrypt-root is hard-blocked "
            "on that platform, see docs/STANDALONE-DESKTOP.md)")
        ll.addWidget(self.standalone)
        self.local_note = QtWidgets.QLabel(
            "User/password below also compose WITHOUT Standalone: on ARM a "
            "customized name or password renames/hashes the image's default account; "
            "x86 always bakes the local user.")
        self.local_note.setWordWrap(True)
        ll.addWidget(self.local_note)
        self.local_user = QtWidgets.QLineEdit()
        ll.addWidget(_row("Local user", self.local_user))
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
        self.encrypt_root = QtWidgets.QCheckBox(
            "Encrypt the target root (--encrypt-root; installer prompts for a passphrase)")
        el.addWidget(self.encrypt_root)
        # device-cannot-encrypt note (spec 4): shown INSTEAD of the checkbox when the
        # target platform has no full-disk-encryption path (jetson's single boot+root
        # partition — see docs/STANDALONE-DESKTOP.md). Dormant in standalone (jetson is
        # not a standalone platform) but correct if reached, and shares the predicate
        # with the mesh worklist's per-row jetson handling.
        self.no_enc_note = QtWidgets.QLabel("")
        self.no_enc_note.setWordWrap(True)
        self.no_enc_note.setStyleSheet("color: #a65d00;")
        el.addWidget(self.no_enc_note)
        self.luks_pass = QtWidgets.QLineEdit()
        self.luks_pass.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.luks_pass.setPlaceholderText("optional unattended passphrase; NOT saved to configs")
        el.addWidget(_row("LUKS passphrase", self.luks_pass))
        self.unlock_keyfile = QtWidgets.QComboBox()
        self.unlock_keyfile.addItems(["(off)", "boot", "login"])
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
        branch (build-x86-host-stage4.sh:3174-3175), so on a cluster-node role
        `--unlock-keyfile login` produces NO marker: the factor silently does not exist.
        The flag is still PARSED and validated (:1220), so nothing errs — and
        `--unlock-yubikey login` even adds sys-auth/pam-u2f to the package set at :3561,
        which is NOT role-gated. So a node paid to emerge a PAM module for a login factor
        it was never going to have.

        Per-ITEM rather than per-field on purpose: "boot" is genuinely valid on a node (the
        installer enrolls it as a LUKS keyslot, :4796-4802), so this removes exactly the one
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
        self.standalone.setChecked(c.standalone)
        self.local_user.setText(c.local_user)
        self.local_pass.setText(c.local_pass)
        self.encrypt_root.setChecked(c.encrypt_root)
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
        home_allowed = home_options_allowed(c)
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
        # --standalone is a DESKTOP posture and a contradiction in mesh, where every image
        # exists to join the cluster (finding 1). HomePage is visited in mesh — mode-skip
        # only drops role/hardware/branding — and this checkbox sat inside the login group
        # ungated by anything, so a single tick rode the deepcopied worklist base onto
        # EVERY node entry. The x86 builder then takes --standalone on a pki role without
        # complaint: ROLE_K8S=none, so no kubelet/kubeadm/containerd and no cluster GitOps
        # tree, yet the full desktop stack IS built — an image that can never join the mesh
        # it was built for, found out hours later at deploy. HIDE (not grey) it out of
        # scope, matching the home-group idiom above, so it cannot be set at all.
        standalone_ok = scope_allows("standalone", c)
        gate_widgets_role_class(self.standalone, standalone_ok,
                                out_of_scope_note("standalone", c), hide=True)
        # device-cannot-encrypt (spec 4): hide the --encrypt-root checkbox and show a
        # plain reason when the target platform has no FDE path (jetson). luks_pass is
        # _ALL_PLATFORMS and emits regardless, so it is NOT hidden/cleared here.
        can_encrypt = platform_supports("encrypt_root", c.platform)
        self.encrypt_root.setVisible(can_encrypt)
        self.no_enc_note.setVisible(not can_encrypt)
        if not can_encrypt:
            label = PLATFORM_LABELS.get(c.platform, c.platform or "x86")
            self.no_enc_note.setText(
                f"This device ({label}) cannot do full-disk encryption — the Orin's "
                "single boot+root partition has no separate LUKS path yet "
                "(docs/STANDALONE-DESKTOP.md).")
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
        c.include_home_archive = self.include_archive.text().strip()
        c.home_seed_code_from = self.seed_code_from.text().strip()
        c.seed_packages_from = self.seed_packages.text().strip()
        md = self.media_data.currentText()
        c.media_data = "" if md == _MEDIA_DEFAULT else md
        c.media_label = self.media_label.text().strip()
        c.no_vaults = self.no_vaults.isChecked()
        # Mirrors the encrypt_root line below: the collect itself carries the scope gate,
        # so a stale tick made on a standalone/cloud desktop can never survive a switch to
        # a mesh/node image (the hidden widget keeps its checked state; cfg is the source
        # of truth that initializePage re-reads). This is the emission-preserving half of
        # the hide above — on an in-scope image the value collects exactly as before.
        c.standalone = self.standalone.isChecked() and scope_allows("standalone", c)
        c.local_user = self.local_user.text().strip() or c.local_user
        c.local_pass = self.local_pass.text()
        # encrypt_root only where the platform can do FDE (the checkbox is hidden on
        # jetson). Byte-identical: _ENC_PLATFORMS platforms are unchanged; jetson is
        # already excluded from encrypt_root emission (and to_cli_args RAISES on a
        # jetson image with encrypt_root set), so forcing False there is both safe and
        # required if the branch is ever reached.
        c.encrypt_root = self.encrypt_root.isChecked() and platform_supports(
            "encrypt_root", c.platform)
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
        # so reset HOME_DESKTOP_FIELDS to defaults regardless of platform.
        if not home_options_allowed(c):
            for fld in HOME_DESKTOP_FIELDS:
                f = ImageConfig.__dataclass_fields__[fld]
                setattr(c, fld, f.default_factory() if f.default is MISSING else f.default)
        return True
