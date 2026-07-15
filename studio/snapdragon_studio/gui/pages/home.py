"""HomePage — split into its two natural groups: HOME PROVISIONING (home mode/
device/backup + archive/seed extras + the per-user eCryptfs home) which is a
DESKTOP-class surface gated by ``home_options_allowed`` (spec 7 — nodes are root-
encrypted, they have no separately-provisioned home), and DISK ENCRYPTION (LUKS2
root + unlock factors) plus the local-login group, which stay in ALL modes. The
external media-data device keeps its own x86-only platform gate."""
from __future__ import annotations

from dataclasses import MISSING

from ..qt import QtWidgets
from ...core.config import HOME_DESKTOP_FIELDS, ImageConfig, home_options_allowed
from ._gating import clear_unsupported, gate_widgets, gate_widgets_role_class
from ._widgets import _file_picker, _row

# the media-data combo's leave-the-builder-default sentinel (the builder default is
# ON — an explicit "on" still emits --media-data so a brand.conf override loses)
_MEDIA_DEFAULT = "(builder default: on)"

# HOME_DESKTOP_FIELDS is desktop-class (spec 7): greyed+cleared on node/mesh images.
_HOME_ROLE_CLASS_REASON = (
    "Home provisioning applies to desktops only — nodes are root-encrypted; homes "
    "are not separately provisioned or encrypted. Cleared when you leave the page.")


class HomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Home & encryption")
        lay = QtWidgets.QVBoxLayout(self)
        # ---- Home provisioning (desktop-class; role-class gated) -----------------
        self.home_box = QtWidgets.QGroupBox("Home provisioning")
        hl = QtWidgets.QVBoxLayout(self.home_box)
        self.mode = QtWidgets.QComboBox()
        self.mode.addItems(["create", "adopt", "archive", "restore"])
        hl.addWidget(_row("Home mode", self.mode))
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
        login = QtWidgets.QGroupBox("Local login")
        ll = QtWidgets.QVBoxLayout(login)
        self.standalone = QtWidgets.QCheckBox(
            "Standalone: no mesh/SSO, local user below logs in with a build-time password "
            "(--standalone; client roles only — laptop/chromebook/desktop, rpi5-desktop/"
            "frite/orangepi5/orangepizero2. NOT jetson — --encrypt-root is hard-blocked "
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
        enc = QtWidgets.QGroupBox("Root-disk encryption (LUKS2)")
        el = QtWidgets.QVBoxLayout(enc)
        self.encrypt_root = QtWidgets.QCheckBox(
            "Encrypt the target root (--encrypt-root; installer prompts for a passphrase)")
        el.addWidget(self.encrypt_root)
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
        lay.addWidget(enc)
        lay.addStretch(1)

    def initializePage(self):
        c = self.wiz.cfg
        self.mode.setCurrentText(c.home_mode)
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
        # image grey the WHOLE group (overriding any platform-enable), with the reason.
        # On desktop images leave the per-platform greying above untouched.
        if not home_options_allowed(c):
            gate_widgets_role_class(list(self._home_widgets), False, _HOME_ROLE_CLASS_REASON)

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
        c.standalone = self.standalone.isChecked()
        c.local_user = self.local_user.text().strip() or c.local_user
        c.local_pass = self.local_pass.text()
        c.encrypt_root = self.encrypt_root.isChecked()
        c.luks_pass = self.luks_pass.text()
        kf = self.unlock_keyfile.currentText()
        c.unlock_keyfile = "" if kf == "(off)" else kf
        yk = self.unlock_yubikey.currentText()
        c.unlock_yubikey = "" if yk == "(off)" else yk
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
