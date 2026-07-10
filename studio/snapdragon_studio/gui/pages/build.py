"""BuildPage — backend/env/output knobs, command preview/preflight, and the build
worker threads (native or docker via BuildDriver)."""
from __future__ import annotations

import os

from ..qt import QtCore, QtWidgets, Signal
from ...core.config import ENV_CHOICES, ImageConfig, UNAFFILIATED_ROLE
from ._gating import clear_unsupported, gate_widgets
from ._widgets import _file_picker, _row


def _tri_combo(default_label="(builder default)"):
    """A tri-state flag-pair combo (the NetworkPage proxy-stack pattern): '' leaves
    the builder default, 'on'/'off' emit the --flag / --no-flag pair. A checkbox
    would collapse the default to an explicit on/off the first time the page is
    visited, so the builder's own default could never round-trip."""
    box = QtWidgets.QComboBox()
    box.addItem(default_label, "")
    box.addItem("on", "on")
    box.addItem("off", "off")
    return box


def _set_tri(box, value):
    """Select the combo entry for a tri-state config value (bools normalize the
    same way config.py's emission does)."""
    box.setCurrentIndex(max(0, box.findData(ImageConfig._tri(value))))


def _picker_row(parent, line_edit, caption, file_filter="All files (*)", directory=False):
    """A line edit + Browse… button as one row widget, greyed as one unit per
    platform (the NetworkPage egress_row pattern)."""
    btn = _file_picker(parent, line_edit, caption, file_filter, directory=directory)
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    h.addWidget(line_edit, 1)
    h.addWidget(btn)
    return w


class _BuildWorker(QtCore.QThread):
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, cfg, backend):
        super().__init__()
        self.driver, self.cfg, self.backend = driver, cfg, backend

    def run(self):
        code = self.driver.run(self.cfg, self.backend, on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


class _BuilderImageWorker(QtCore.QThread):
    """Runs BuildDriver.build_builder_image() the same way _BuildWorker runs a build."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver):
        super().__init__()
        self.driver = driver

    def run(self):
        code = self.driver.build_builder_image(on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


class BuildPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Build")
        self.setSubTitle("Review the command, then build natively or via Docker.")
        lay = QtWidgets.QVBoxLayout(self)
        self.backend = QtWidgets.QComboBox()
        self.backend.addItems(["auto", "native", "docker"])
        lay.addWidget(_row("Backend", self.backend))
        # --env: which stack environment the image bakes (every builder parses it)
        self.env = QtWidgets.QComboBox()
        self.env.addItems(list(ENV_CHOICES))
        lay.addWidget(_row("Environment (--env)", self.env))
        self.outdir = QtWidgets.QLineEdit()
        obtn = _file_picker(self, self.outdir, "Output dir", directory=True)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.outdir, 1); h.addWidget(obtn)
        lay.addWidget(_row("Output dir", w))
        self.jobs = QtWidgets.QSpinBox(); self.jobs.setRange(1, 256); self.jobs.setValue(8)
        lay.addWidget(_row("Parallel jobs", self.jobs))
        self.installer_ui = QtWidgets.QComboBox()
        self.installer_ui.addItems(["all", "cli", "ncurses", "calamares"])
        lay.addWidget(_row("Installer UI", self.installer_ui))
        # --img-size MiB: every builder parses it; 0 = "(role default)" emits nothing
        # (the builders size the compact root per role/desktop payload themselves).
        self.img_size = QtWidgets.QSpinBox()
        self.img_size.setRange(0, 1 << 20)
        self.img_size.setSuffix(" MiB")
        self.img_size.setSpecialValueText("(role default)")
        lay.addWidget(_row("Root image size", self.img_size))
        # x86 ISO finish knobs (like the installer-UI choice, the arm builders parse
        # none of these — the widgets grey out off-x86, and config.py emits x86-only)
        self.cached = QtWidgets.QCheckBox(
            "Cached ISO — embed the binpkg cache (+distfiles) for offline rebuild / fast reinstall")
        self.live_toram = QtWidgets.QCheckBox(
            'Live ISO "Copy to RAM (removable)" boot entry')
        self.bundle_source = QtWidgets.QCheckBox(
            "Bundle the generator source — self-hosting image (standalone default)")
        # shown INSTEAD of an enabled checkbox when the unaffiliated role is selected
        self.bundle_note = QtWidgets.QLabel(
            "Source bundling does not apply — unaffiliated build (bundling the Snapdragon "
            "generator source is a builder hard-conflict; the role presets it off).")
        self.bundle_note.setWordWrap(True)
        self.bundle_note.setStyleSheet("color: #a65d00;")
        self.bundle_note.setVisible(False)
        self.compress = QtWidgets.QCheckBox("Compress the finished image(s) (xz -9)")
        self.resume = QtWidgets.QCheckBox("Resume — reuse an existing sysroot")
        lay.addWidget(self.cached)
        lay.addWidget(self.live_toram)
        lay.addWidget(self.bundle_source)
        lay.addWidget(self.bundle_note)
        lay.addWidget(self.compress)
        lay.addWidget(self.resume)
        # --grow fill|none|<size> first-boot root-growth policy (G25): editable so a
        # size cap ("16G", "50%") types straight in; "" leaves the builder default.
        self.grow = QtWidgets.QComboBox()
        self.grow.setEditable(True)
        self.grow.addItems(["", "fill", "none"])
        self.grow.lineEdit().setPlaceholderText("fill | none | <size e.g. 16G, 50%>  (empty = builder default)")
        lay.addWidget(_row("First-boot root growth (--grow)", self.grow))
        # image stamps (G30): -v/--version is all-platform, --release-tag x86-only
        self.version = QtWidgets.QLineEdit()
        self.version.setPlaceholderText("-v/--version image stamp (empty = builder default)")
        self.release_tag = QtWidgets.QLineEdit()
        self.release_tag.setPlaceholderText("--release-tag image stamp (empty = deterministic build stamp)")
        lay.addWidget(_row("Version stamp", self.version))
        lay.addWidget(_row("Release tag", self.release_tag))

        # artifact selection matrix (G23 x86 / G24 ARM) — per-field platform-gated,
        # so exactly the axes THIS builder parses stay live
        art = QtWidgets.QGroupBox("Artifacts")
        arl = QtWidgets.QVBoxLayout(art)
        self.build_img = _tri_combo()
        arl.addWidget(_row("Root image (--img/--no-img)", self.build_img))
        self.live_iso = _tri_combo()
        arl.addWidget(_row("Live ISO (--live-iso/--no-live-iso)", self.live_iso))
        self.installer_iso = QtWidgets.QCheckBox(
            "Installer ISO (--installer-iso — direct, no longer only an encrypt-root side effect)")
        arl.addWidget(self.installer_iso)
        self.build_iso = QtWidgets.QCheckBox(
            "Bootable installer ISO for an UNencrypted image (--iso; rpi5 — with the "
            "root image too = the builder's --both)")
        arl.addWidget(self.build_iso)
        self.sd_only = QtWidgets.QCheckBox("SD-card image only (--sd-only; rpi5)")
        arl.addWidget(self.sd_only)
        self.build_tar = _tri_combo()
        arl.addWidget(_row("Rootfs tar (--tar/--no-tar)", self.build_tar))
        self.skip_iso = QtWidgets.QCheckBox("Skip the ISO stage (--skip-iso)")
        arl.addWidget(self.skip_iso)
        self.image_only = QtWidgets.QCheckBox(
            "Image only — skip the live/installer media (--image-only; frite/jetson/orangepi*)")
        arl.addWidget(self.image_only)
        lay.addWidget(art)

        # Secure Boot + KEYS-USB signing chain (G5; x86 only). The builder default is
        # ON with a THROWAWAY org key — threading the existing fleet key/cert PATHS
        # here is what keeps GUI images in the fleet's SB chain. Paths only: the
        # Studio never reads the key material itself.
        sb = QtWidgets.QGroupBox("Secure Boot signing (x86)")
        sbl = QtWidgets.QVBoxLayout(sb)
        self.sb_box = sb
        self.secure_boot = _tri_combo("(builder default: on — throwaway org key)")
        sbl.addWidget(_row("Secure Boot (--secure-boot/--no-secure-boot)", self.secure_boot))
        self.keys_usb = QtWidgets.QLineEdit()
        self.keys_usb.setPlaceholderText("KEYS USB dir providing Keys/kernel_key.{pem,der} (--keys-usb)")
        sbl.addWidget(_row("KEYS USB dir", _picker_row(self, self.keys_usb, "KEYS USB dir",
                                                       directory=True)))
        self.secureboot_key = QtWidgets.QLineEdit()
        self.secureboot_key.setPlaceholderText("SB signing private key PEM path (--secureboot-key)")
        sbl.addWidget(_row("Signing key", _picker_row(self, self.secureboot_key, "SB signing key",
                                                      "Keys (*.pem *.key);;All files (*)")))
        self.secureboot_cert = QtWidgets.QLineEdit()
        self.secureboot_cert.setPlaceholderText("SB signing cert PEM/DER path (--secureboot-cert)")
        sbl.addWidget(_row("Signing cert", _picker_row(self, self.secureboot_cert, "SB signing cert",
                                                       "Certs (*.pem *.der *.crt);;All files (*)")))
        lay.addWidget(sb)

        # build plumbing (G38) — phases / seed / distfiles knobs that change baked
        # content, not artifacts
        plumb = QtWidgets.QGroupBox("Build plumbing (advanced)")
        pl = QtWidgets.QVBoxLayout(plumb)
        self.skip_kernel = QtWidgets.QCheckBox("Skip the kernel build (--skip-kernel)")
        self.skip_clean = QtWidgets.QCheckBox("Keep docs/headers/symbols (--skip-clean)")
        pl.addWidget(self.skip_kernel)
        pl.addWidget(self.skip_clean)
        self.distdir = QtWidgets.QLineEdit()
        self.distdir.setPlaceholderText("reuse a Gentoo distfiles cache dir (--distdir; x86)")
        self.distdir_row = _picker_row(self, self.distdir, "Distfiles cache dir", directory=True)
        pl.addWidget(_row("Distfiles cache", self.distdir_row))
        self.build_subdir = QtWidgets.QLineEdit()
        self.build_subdir.setPlaceholderText("per-arch subdir under the work dir (--build-subdir)")
        pl.addWidget(_row("Build subdir", self.build_subdir))
        self.seed_url = QtWidgets.QLineEdit()
        self.seed_url.setPlaceholderText("stage3 seed index URL (--seed-url)")
        pl.addWidget(_row("Seed URL", self.seed_url))
        self.extra_packages = QtWidgets.QLineEdit()
        self.extra_packages.setPlaceholderText("extra packages to bake (-p/--extra-packages; ARM only)")
        pl.addWidget(_row("Extra packages", self.extra_packages))
        lay.addWidget(plumb)

        # OWASP pen-test bake (G40) — PENTEST=1 is a FLEET/ENV knob the build driver
        # forwards to the build environment, never a per-builder argv flag.
        self.pentest = QtWidgets.QCheckBox(
            "OWASP pen-test bake (PENTEST=1 — env knob forwarded to the build, not a builder flag)")
        lay.addWidget(self.pentest)
        # escape hatch: EVERY builder CLI option stays expressible, fielded or not
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText(
            "appended verbatim, shell-quoted (for any builder flag without a field)")
        lay.addWidget(_row("Extra builder flags", self.extra_flags))
        self.cmd = QtWidgets.QPlainTextEdit(); self.cmd.setReadOnly(True); self.cmd.setMaximumHeight(120)
        lay.addWidget(QtWidgets.QLabel("Command:")); lay.addWidget(self.cmd)
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.build_btn = QtWidgets.QPushButton("Build now")
        self.build_image_btn = QtWidgets.QPushButton("Build builder image now")
        self.build_image_btn.setVisible(False)
        self.preview_btn.clicked.connect(self._preview)
        self.build_btn.clicked.connect(self._build)
        self.build_image_btn.clicked.connect(self._build_builder_image)
        bl = QtWidgets.QHBoxLayout(); bl.addWidget(self.preview_btn); bl.addWidget(self.build_btn)
        bl.addWidget(self.build_image_btn); bl.addStretch(1)
        lay.addLayout(bl)
        self.log = QtWidgets.QPlainTextEdit(); self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)
        self.worker = None
        self.image_worker = None

    def initializePage(self):
        self.wiz.collect_all()
        c = self.wiz.cfg
        if not self.outdir.text():
            self.outdir.setText(c.output_dir or os.path.join(self.wiz.generator_dir, "out"))
        self.env.setCurrentText(c.env or "test")
        self.installer_ui.setCurrentText(c.installer_ui or "all")
        # the installer-UI choice is an x86 ISO knob; the arm builders have no flag
        self.installer_ui.setEnabled(c.platform in ("", "x86"))
        self.img_size.setValue(c.img_size)
        # cached / live-toram / bundle-source are x86 ISO knobs too (config.py only
        # emits them through _x86_args)
        self.cached.setEnabled(c.platform in ("", "x86"))
        self.cached.setChecked(c.cached)
        self.live_toram.setEnabled(c.platform in ("", "x86"))
        self.live_toram.setChecked(c.live_toram)
        # bundling the generator source is a builder HARD CONFLICT on an unaffiliated
        # image (the dedicated role OR the composable --unaffiliated flag, G22) —
        # disable + clear the checkbox and show the note (mirroring the BrandingPage
        # pattern), so the wizard can never re-set what RolePage cleared
        # (config.py suppresses the flag pair for unaffiliated as the final guard).
        unaffiliated = c.role == UNAFFILIATED_ROLE or c.unaffiliated
        self.bundle_source.setEnabled(c.platform in ("", "x86") and not unaffiliated)
        self.bundle_source.setChecked(False if unaffiliated else c.bundle_source)
        self.bundle_note.setVisible(unaffiliated)
        self.compress.setChecked(c.compress)
        self.resume.setChecked(c.resume)
        self.grow.setCurrentText(c.grow)
        self.version.setText(c.version)
        self.release_tag.setText(c.release_tag)
        _set_tri(self.build_img, c.build_img)
        _set_tri(self.live_iso, c.live_iso)
        self.installer_iso.setChecked(c.installer_iso)
        self.build_iso.setChecked(c.build_iso)
        self.sd_only.setChecked(c.sd_only)
        _set_tri(self.build_tar, c.build_tar)
        self.skip_iso.setChecked(c.skip_iso)
        self.image_only.setChecked(c.image_only)
        _set_tri(self.secure_boot, c.secure_boot)
        self.keys_usb.setText(c.keys_usb)
        self.secureboot_key.setText(c.secureboot_key)
        self.secureboot_cert.setText(c.secureboot_cert)
        self.skip_kernel.setChecked(c.skip_kernel)
        self.skip_clean.setChecked(c.skip_clean)
        self.distdir.setText(c.distdir)
        self.build_subdir.setText(c.build_subdir)
        self.seed_url.setText(c.seed_url)
        self.extra_packages.setText(c.extra_packages)
        self.pentest.setChecked(c.pentest)
        self.extra_flags.setText(c.extra_flags)
        # per-platform capability greying for the new fields (grow / version /
        # skip-kernel / skip-clean / build-subdir / seed-url / pentest are
        # all-platform or out-of-band, so they never grey)
        gate_widgets(c.platform, {
            "release_tag": self.release_tag,
            "build_img": self.build_img,
            "live_iso": self.live_iso,
            "installer_iso": self.installer_iso,
            "build_iso": self.build_iso,
            "sd_only": self.sd_only,
            "build_tar": self.build_tar,
            "skip_iso": self.skip_iso,
            "image_only": self.image_only,
            "secure_boot": self.sb_box,
            "distdir": self.distdir_row,
            "extra_packages": self.extra_packages,
        })
        self._preview()

    def _backend(self):
        b = self.backend.currentText()
        return None if b == "auto" else b

    def _preview(self):
        self.wiz.collect_all()
        c = self.wiz.cfg
        c.output_dir = self.outdir.text().strip()
        c.jobs = self.jobs.value()
        c.env = self.env.currentText()
        c.installer_ui = self.installer_ui.currentText()
        c.img_size = self.img_size.value()
        c.cached = self.cached.isChecked()
        c.live_toram = self.live_toram.isChecked()
        # unaffiliated (dedicated role or composable flag): the checkbox is disabled +
        # cleared in initializePage — force the field too, so a stale standalone
        # default can never linger in the config.
        c.bundle_source = (False if (c.role == UNAFFILIATED_ROLE or c.unaffiliated)
                           else self.bundle_source.isChecked())
        c.compress = self.compress.isChecked()
        c.resume = self.resume.isChecked()
        c.grow = self.grow.currentText().strip()
        c.version = self.version.text().strip()
        c.release_tag = self.release_tag.text().strip()
        c.build_img = self.build_img.currentData()
        c.live_iso = self.live_iso.currentData()
        c.installer_iso = self.installer_iso.isChecked()
        c.build_iso = self.build_iso.isChecked()
        c.sd_only = self.sd_only.isChecked()
        c.build_tar = self.build_tar.currentData()
        c.skip_iso = self.skip_iso.isChecked()
        c.image_only = self.image_only.isChecked()
        c.secure_boot = self.secure_boot.currentData()
        c.keys_usb = self.keys_usb.text().strip()
        c.secureboot_key = self.secureboot_key.text().strip()
        c.secureboot_cert = self.secureboot_cert.text().strip()
        c.skip_kernel = self.skip_kernel.isChecked()
        c.skip_clean = self.skip_clean.isChecked()
        c.distdir = self.distdir.text().strip()
        c.build_subdir = self.build_subdir.text().strip()
        c.seed_url = self.seed_url.text().strip()
        c.extra_packages = self.extra_packages.text().strip()
        c.pentest = self.pentest.isChecked()
        c.extra_flags = self.extra_flags.text().strip()
        # the greyed (platform-unsupported) widgets were still collected above —
        # reset those fields to their defaults so a value picked while another
        # platform was selected can't linger into save() or the emitted argv.
        clear_unsupported(c, (
            "release_tag", "build_img", "live_iso", "installer_iso", "build_iso",
            "sd_only", "build_tar", "skip_iso", "image_only", "secure_boot",
            "keys_usb", "secureboot_key", "secureboot_cert", "distdir",
            "extra_packages",
        ))
        try:
            cmdline = self.wiz.driver.command_string(c, self._backend())
        except ValueError as e:  # e.g. unbalanced quotes in the extra-flags escape hatch
            self.cmd.setPlainText("")
            self.log.setPlainText(f"Command error: {e}")
            return
        problems = self.wiz.driver.preflight(c, self._backend())
        self.cmd.setPlainText(cmdline)
        if problems:
            self.log.setPlainText("Preflight:\n  - " + "\n  - ".join(problems))
        else:
            self.log.setPlainText("Preflight OK.")
        self.build_image_btn.setVisible(self.wiz.driver.builder_image_missing(self._backend()))

    def _build_builder_image(self):
        if self.image_worker and self.image_worker.isRunning():
            return
        self.build_image_btn.setEnabled(False)
        self.build_btn.setEnabled(False)
        self.log.appendPlainText("\n=== building the docker builder image ===")
        self.image_worker = _BuilderImageWorker(self.wiz.driver)
        self.image_worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.image_worker.done.connect(self._builder_image_finished)
        self.image_worker.start()

    def _builder_image_finished(self, code):
        self.log.appendPlainText(f"=== builder image build exited {code} ===")
        self.build_image_btn.setEnabled(True)
        self.build_btn.setEnabled(True)
        self._preview()

    def _build(self):
        self._preview()
        if self.worker and self.worker.isRunning():
            return
        # superadmin mesh: emit the domains+users manifest as a build artifact
        if self.wiz.cfg.mode == "mesh" and (self.wiz.cfg.domains or self.wiz.cfg.users):
            try:
                mpath = self.wiz.cfg.write_mesh_manifest(self.wiz.cfg.output_dir or
                                                         os.path.join(self.wiz.generator_dir, "out"))
                self.log.appendPlainText(f"wrote mesh manifest: {mpath}")
            except OSError as e:
                self.log.appendPlainText(f"mesh manifest write failed: {e}")
        self.build_btn.setEnabled(False)
        self.log.appendPlainText("\n=== starting build ===")
        self.worker = _BuildWorker(self.wiz.driver, self.wiz.cfg, self._backend())
        self.worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.worker.done.connect(self._finished)
        self.worker.start()

    def _finished(self, code):
        self.log.appendPlainText(f"=== build exited {code} ===")
        self.build_btn.setEnabled(True)
