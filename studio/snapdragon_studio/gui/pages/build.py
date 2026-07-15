"""BuildPage → "Review & Build" (slug "build"; design 3.12).

The page keeps every build knob (backend / env / output / artifact matrix / Secure Boot /
plumbing / the command + preflight panes) but no longer runs the build itself: the in-form
"Build now" button is gone. Instead the wizard's Finish becomes a Build action — leaving this
(commit) page commits a WorklistConfig and lands on the terminal ProgressPage, which drives
the WorklistDriver. Standalone/cloud commit a 1-entry worklist synthesized from the config so
the driver / progress / manifest code path has exactly one shape; mesh commits the
WorklistPage's selection.

The retired free-text extra-packages field is replaced by a "Packages…" button opening the
per-image :class:`~.packages_dialog.PackagesDialog` (mesh gets one per worklist row, in a
summary table). "Build builder image now" stays — it builds the Docker builder image, not an
OS image.
"""
from __future__ import annotations

import copy
import os

from ..qt import QtCore, QtWidgets, Signal
from ._scroll import scrollable
from ...core import worklist as worklist_mod
from ...core.config import (ENV_CHOICES, ImageConfig, UNAFFILIATED_ROLE, image_class,
                            resolve_platform_defaults)
from ...core.worklist_driver import WorklistDriver
from ._gating import clear_unsupported, gate_widgets
from ._widgets import _file_picker, _row
from .packages_dialog import PackagesDialog

# mesh roles whose image carries a GPU stack (the summary "GPU" chip).
_GPU_MESH_ROLES = ("be+gpu", "edge_ai", "gpu-host")


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


class _BuilderImageWorker(QtCore.QThread):
    """Runs BuildDriver.build_builder_image() off the GUI thread (mirrors the old
    _BuildWorker — the OS-image build itself now runs on ProgressPage's WorklistDriver)."""
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
        self.setTitle("Review & Build")
        self.setSubTitle("Review the command and preflight, then Build — the build runs on "
                         "the next screen.")
        # commit page: leaving it commits the worklist and lands on ProgressPage; Back is
        # then disabled for the duration of the run (design 3.12/3.13).
        self.setCommitPage(True)
        try:
            self.wiz.setButtonText(QtWidgets.QWizard.WizardButton.CommitButton, "Build")
        except Exception:
            pass
        self._problems: list[str] = []
        # mesh run state (populated in initializePage when mode == mesh)
        self._wl_driver: WorklistDriver | None = None
        self._materialized: list = []

        lay = scrollable(self)
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

        # ── mesh worklist summary (design 3.12) — one row per image with per-entry
        # Packages…/Preview and the node key-zip opt-out. Shown only in mesh.
        self.worklist_group = QtWidgets.QGroupBox("Mesh worklist — one image per row")
        wg = QtWidgets.QVBoxLayout(self.worklist_group)
        self.worklist_table = QtWidgets.QTableWidget(0, 4)
        self.worklist_table.setHorizontalHeaderLabels(["Image", "Facts", "", ""])
        self.worklist_table.horizontalHeader().setStretchLastSection(False)
        self.worklist_table.verticalHeader().setVisible(False)
        self.worklist_table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        wg.addWidget(self.worklist_table)
        self.gen_keys = QtWidgets.QCheckBox(
            "Generate node key-zips after each successful node build (mesh)")
        self.gen_keys.setChecked(True)
        wg.addWidget(self.gen_keys)
        lay.addWidget(self.worklist_group)

        # ── single-image Packages… (standalone/cloud) — replaces the retired free-text
        # extra-packages field with the per-image tri-tier dialog.
        self.packages_btn = QtWidgets.QPushButton("Packages…")
        self.packages_btn.clicked.connect(self._open_packages_single)
        lay.addWidget(_row("Packages", self.packages_btn))

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
        self.build_image_btn = QtWidgets.QPushButton("Build builder image now")
        self.build_image_btn.setVisible(False)
        self.preview_btn.clicked.connect(self._preview)
        self.build_image_btn.clicked.connect(self._build_builder_image)
        bl = QtWidgets.QHBoxLayout(); bl.addWidget(self.preview_btn)
        bl.addWidget(self.build_image_btn); bl.addStretch(1)
        lay.addLayout(bl)
        self.log = QtWidgets.QPlainTextEdit(); self.log.setReadOnly(True)
        lay.addWidget(self.log, 1)
        self.image_worker = None

    def initializePage(self):
        self.wiz.collect_all()
        c = self.wiz.cfg
        mesh = c.mode == "mesh"
        if not self.outdir.text():
            self.outdir.setText(c.output_dir or os.path.join(self.wiz.generator_dir, "out"))
        self.env.setCurrentText(c.env or "test")
        self.installer_ui.setCurrentText(c.installer_ui or "all")
        # the installer-UI choice is an x86 ISO knob; the arm builders have no flag
        self.installer_ui.setEnabled(c.platform in ("", "x86"))
        self.img_size.setValue(c.img_size)
        # Restore the parallel-jobs spinbox from the loaded config — validatePage writes
        # c.jobs = self.jobs.value() back, so without this a saved non-default jobs value is
        # silently overwritten with the widget's construction default (8) on Review & Build.
        self.jobs.setValue(c.jobs)
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
        self.pentest.setChecked(c.pentest)
        self.extra_flags.setText(c.extra_flags)
        # mesh shows the per-image worklist summary + node-key opt-out; standalone/cloud
        # show the single-image Packages… button (each image's tri-tier package dialog).
        self.worklist_group.setVisible(mesh)
        self.packages_btn.setVisible(not mesh)
        if mesh:
            self._refresh_worklist_table()
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
        })
        self._preview()

    def _backend(self):
        b = self.backend.currentText()
        return None if b == "auto" else b

    # ---- worklist assembly (the commit shape) ----------------------------------
    def _current_worklist(self):
        """The WorklistConfig this Review page would commit RIGHT NOW: the mesh selection
        from the WorklistPage, or a 1-entry worklist synthesized from the single-image
        config (design 2.3) so the driver/progress/manifest have exactly one shape."""
        wl = getattr(self.wiz, "worklist", None)
        if self.wiz.cfg.mode == "mesh" and wl is not None and wl.entries:
            wl.base = self.wiz.cfg          # keep the shared identity plane current
            return wl
        return worklist_mod.synthesize(self.wiz.cfg)

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
        c.pentest = self.pentest.isChecked()
        c.extra_flags = self.extra_flags.text().strip()
        # the greyed (platform-unsupported) widgets were still collected above —
        # reset those fields to their defaults so a value picked while another
        # platform was selected can't linger into save() or the emitted argv.
        # extra_packages is deliberately NOT listed: its free-text UI is retired and the
        # frozen field must round-trip byte-identically (I1) — only its emission gate lives
        # in config.py.
        clear_unsupported(c, (
            "release_tag", "build_img", "live_iso", "installer_iso", "build_iso",
            "sd_only", "build_tar", "skip_iso", "image_only", "secure_boot",
            "keys_usb", "secureboot_key", "secureboot_cert", "distdir",
        ))
        try:
            # DISPLAY the same command the real build will run: the actual build path
            # (WorklistDriver over synthesize->materialize) applies resolve_platform_defaults,
            # so a standalone frite/orangepi5/orangepizero2 with an unset flavor builds a
            # single ISO (--flavor installer), not `both`. Resolve on a DEEPCOPY — self.wiz.cfg
            # is shared and re-edited/saved, so it must never be mutated by a preview render.
            pc = copy.deepcopy(c)
            resolve_platform_defaults(pc)
            cmdline = self.wiz.driver.command_string(pc, self._backend())
        except ValueError as e:  # e.g. unbalanced quotes in the extra-flags escape hatch
            self.cmd.setPlainText("")
            self.log.setPlainText(f"Command error: {e}")
            self._set_problems([str(e)])
            return
        self.cmd.setPlainText(cmdline)
        # isComplete() gates the Build/Finish button on the AGGREGATE worklist preflight
        # (one entry for standalone/cloud) — the FleetPage refuse-on-problem precedent.
        self._set_problems(self._aggregate_preflight())
        if self._problems:
            self.log.setPlainText("Preflight:\n  - " + "\n  - ".join(self._problems))
        else:
            self.log.setPlainText("Preflight OK.")
        self.build_image_btn.setVisible(self.wiz.driver.builder_image_missing(self._backend()))

    def _aggregate_preflight(self) -> list[str]:
        """WorklistDriver.preflight over the would-be-committed worklist. Materialize can
        raise on an invalid identity — surface that as the single blocking problem."""
        try:
            drv = WorklistDriver(self.wiz.generator_dir, self._current_worklist(),
                                 host=self.wiz.host, backend=self._backend())
            return drv.preflight()
        except Exception as e:
            return [f"cannot assemble the build: {e}"]

    def _set_problems(self, problems: list[str]) -> None:
        self._problems = problems
        self.completeChanged.emit()

    # ---- mesh worklist summary --------------------------------------------------
    def _refresh_worklist_table(self):
        try:
            self._wl_driver = WorklistDriver(self.wiz.generator_dir, self._current_worklist(),
                                             host=self.wiz.host, backend=self._backend())
            self._materialized = self._wl_driver.materialize()
        except Exception as e:
            self._materialized = []
            self.worklist_table.setRowCount(0)
            self.log.setPlainText(f"Cannot assemble the worklist: {e}")
            return
        self.worklist_table.setRowCount(len(self._materialized))
        for i, (entry, mcfg) in enumerate(self._materialized):
            self.worklist_table.setItem(i, 0, QtWidgets.QTableWidgetItem(entry.id))
            self.worklist_table.setItem(i, 1, QtWidgets.QTableWidgetItem(self._facts(entry, mcfg)))
            pkg_btn = QtWidgets.QPushButton("Packages…")
            pkg_btn.clicked.connect(lambda _=False, idx=i: self._open_packages_entry(idx))
            self.worklist_table.setCellWidget(i, 2, pkg_btn)
            prev_btn = QtWidgets.QPushButton("Preview")
            prev_btn.clicked.connect(lambda _=False, idx=i: self._preview_entry(idx))
            self.worklist_table.setCellWidget(i, 3, prev_btn)
        self.worklist_table.resizeColumnsToContents()

    def _facts(self, entry, mcfg) -> str:
        chips = ["encrypt-root ON" if mcfg.encrypt_root else "encrypt-root off"]
        if entry.role in _GPU_MESH_ROLES:
            chips.append("GPU")
        chips.append(f"{len(mcfg.domains)} domain(s)")
        addn, dropn = len(entry.packages_add.split()), len(entry.packages_drop.split())
        if addn or dropn:
            chips.append(f"+{addn}/−{dropn} pkgs")
        return " · ".join(chips)

    def _preview_entry(self, idx: int):
        if self._wl_driver is None or idx >= len(self._materialized):
            return
        _entry, mcfg = self._materialized[idx]
        try:
            self.cmd.setPlainText(self._wl_driver.command_string(mcfg))
        except ValueError as e:
            self.cmd.setPlainText(f"Command error: {e}")

    def _open_packages_entry(self, idx: int):
        if idx >= len(self._materialized):
            return
        entry, mcfg = self._materialized[idx]
        dlg = PackagesDialog(self.wiz.generator_dir, mcfg,
                             packages_add=entry.packages_add, packages_drop=entry.packages_drop,
                             parent=self)
        if dlg.exec():
            entry.packages_add = dlg.packages_add
            entry.packages_drop = dlg.packages_drop
            self._refresh_worklist_table()      # re-materialize with the new deltas
            self._preview()

    def _open_packages_single(self):
        self._preview()
        c = self.wiz.cfg
        dlg = PackagesDialog(self.wiz.generator_dir, c,
                             packages_add=c.packages_add, packages_drop=c.packages_drop,
                             extra_packages=c.extra_packages, parent=self)
        if dlg.exec():
            c.packages_add = dlg.packages_add
            c.packages_drop = dlg.packages_drop
            self._preview()

    # ---- builder image ----------------------------------------------------------
    def _build_builder_image(self):
        if self.image_worker and self.image_worker.isRunning():
            return
        self.build_image_btn.setEnabled(False)
        self.log.appendPlainText("\n=== building the docker builder image ===")
        self.image_worker = _BuilderImageWorker(self.wiz.driver)
        self.image_worker.line.connect(lambda s: self.log.appendPlainText(s))
        self.image_worker.done.connect(self._builder_image_finished)
        self.image_worker.start()

    def _builder_image_finished(self, code):
        self.log.appendPlainText(f"=== builder image build exited {code} ===")
        self.build_image_btn.setEnabled(True)
        self._preview()

    # ---- commit -----------------------------------------------------------------
    def isComplete(self) -> bool:
        """Build/Finish is enabled only when the aggregate preflight is clean (design 3.12)."""
        return not self._problems

    def validatePage(self) -> bool:
        """Commit the WorklistConfig and stash the run parameters ProgressPage reads, then
        advance (commit) to the terminal ProgressPage."""
        self._preview()
        self.wiz.worklist = self._current_worklist()
        self.wiz.build_backend = self._backend()
        self.wiz.generate_node_keys = (self.gen_keys.isChecked()
                                       if self.wiz.cfg.mode == "mesh" else True)
        return True
