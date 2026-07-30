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

ONE WIDGET IDIOM PER KIND OF CONTROL (operator report, 2026-07-29: "there's a mixture of
sections in the build area that are dropdowns instead of buttons for the same kinds of
thing, organize this build page better"). The reported mixture was real: the Artifacts box
interleaved three '(builder default)/on/off' DROPDOWNS (root image / live ISO / rootfs tar)
among five CHECKBOX siblings answering the same kind of question ("do I get this
artifact?"), and Secure Boot was a fourth such dropdown. The page's rule, stated once and
applied everywhere:

* pick-one VALUE enumerations (backend engine, --env, installer front-end, --grow policy)
  are DROPDOWNS — they choose one named value among several, exactly what a combo is for
  (the grow combo stays editable: a size cap like "16G" types straight in);
* on/off build toggles are CHECKBOXES — tri-state where the builder has a --flag/--no-flag
  pair (the NetworkPage G34 idiom: the part-checked square = leave the builder default,
  which is the property the old dropdowns existed for — see _tri_check);
* actions (Packages… / Preview / Refresh preview / Build builder image now) are PUSH
  BUTTONS.

Related controls are grouped into the wizard's Collapsible sections (_widgets.collapsible
— the NetworkPage house pattern): Build execution / mesh worklist / Image options /
Artifacts / Secure Boot / Build plumbing. Collapsing is PRESENTATION ONLY (see
_widgets.Collapsible): validatePage/_preview read widget VALUES, which a folded widget
keeps, and clear_unsupported keys on the capability table, never on visibility.
"""
from __future__ import annotations

import copy
import os

from dataclasses import MISSING

from ..qt import Qt, QtCore, QtWidgets, Signal
from ._scroll import scrollable
from ...core import build_sessions
from ...core import flash_targets
from ...core import worklist as worklist_mod
from ...core.build_driver import BuildDriver
from ...core.config import (ENV_CHOICES, ImageConfig, UNAFFILIATED_ROLE,
                            effective_installer_ui, image_class,
                            resolve_installer_ui_default, resolve_platform_defaults)
from ...core.worklist_driver import WorklistDriver
from ._device_table import DeviceTable
from ._gating import (clear_unsupported, gate_widgets, gate_widgets_role_class,
                      platform_supports, unsupported_note)
from ._widgets import _file_picker, _row, collapsible
from .packages_dialog import PackagesDialog

# mesh roles whose image carries a GPU stack (the summary "GPU" chip).
_GPU_MESH_ROLES = ("be+gpu", "edge_ai", "gpu-host")

# Why the Installer-UI combo is greyed on a headless node image. Two DIFFERENT true
# statements, because the resolver's rewrite is CONDITIONAL: it only replaces the
# calamares-triggering values (all/calamares). Claiming "pinned to CLI" for a node whose
# config already says "ncurses" would be a lie — ncurses needs no desktop USE closure and
# really is what gets built. The row is greyed for EVERY node either way (a node's
# front-end is a role consequence, not an interactive choice), but the stated reason must
# match what actually happens. core.config.effective_installer_ui is the single authority.
_INSTALLER_UI_REWRITTEN_REASON = (
    "Headless node images install unattended (CLI). The graphical Calamares front-end "
    "needs the desktop USE closure the builder only ships for client/standalone roles "
    "(ROLE_CLIENT), so a node image cannot build it — choose a client or standalone "
    "role to pick an installer front-end.")


def _installer_ui_reason(shown: str, rewritten: bool) -> str:
    """The greyed-combo tooltip for a node: why it shows `shown` and can't be changed."""
    if rewritten:
        return _INSTALLER_UI_REWRITTEN_REASON
    return (f"Node images do not choose an installer front-end interactively — the role "
            f"decides it. {shown!r} is already a headless front-end (it pulls no "
            f"Calamares), so the image is built with it as-is — choose a client or "
            f"standalone role to pick a different front-end.")


# The same meaning as _TRI_TIP below, but VISIBLE on the page. NetworkPage learned this
# the hard way (its tri-state services were reported as "partially selected but it's not
# clear why" when the explanation lived only in a hover tooltip) — so the legend ships
# with the boxes from day one here, not after the same report a second time.
_TRI_LEGEND = (
    "3-state boxes: ■ part-checked (the default) leaves the builder's own choice alone · "
    "☑ checked forces the flag ON · ☐ unchecked forces it OFF (the --flag / --no-flag "
    "pair). The square means \"don't override\", not \"partly enabled\"."
)

_TRI_TIP = ("3-state: checked = force ON (--flag), unchecked = force OFF (--no-flag), "
            "part-checked square = leave the builder default.")

# config tri-state value <-> Qt CheckState. The config domain stays byte-identical to
# what the old dropdowns' currentData() carried ('' / 'on' / 'off'), so nothing about
# emission or save/load changes — only the widget changed shape.
_TRI_STATES = {
    "": Qt.CheckState.PartiallyChecked,
    "on": Qt.CheckState.Checked,
    "off": Qt.CheckState.Unchecked,
}


def _tri_check(text):
    """A tri-state flag-pair CHECKBOX (the NetworkPage G34 idiom): part-checked square =
    leave the builder default (emit neither flag), checked = --flag, unchecked = --no-flag.

    Replaces this page's old '(builder default)/on/off' _tri_combo DROPDOWNS. The combo
    existed for one property — the builder's own default must round-trip, which a
    two-state box can never do (it collapses the default to an explicit on/off on first
    visit) — but it bought that property at the cost the operator reported (2026-07-29):
    the Artifacts box interleaved three dropdowns among five checkbox siblings that
    answer the SAME KIND of question, "do I get this artifact?". A tri-state checkbox
    keeps the round-trip property (the square is the emit-nothing state) while looking
    like what it is: an on/off toggle, same as its neighbours."""
    box = QtWidgets.QCheckBox(text)
    box.setTristate(True)
    box.setCheckState(Qt.CheckState.PartiallyChecked)   # default: leave the builder's own
    box.setToolTip(_TRI_TIP)
    return box


def _set_tri(box, value):
    """Show a tri-state config value on its checkbox (bools normalize the same way
    config.py's emission does — ImageConfig._tri is the single authority)."""
    box.setCheckState(_TRI_STATES.get(ImageConfig._tri(value),
                                      Qt.CheckState.PartiallyChecked))


def _tri_value(box):
    """Checkbox state -> the tri-state config value ('' / 'on' / 'off') — the exact
    domain the old combos' currentData() emitted, so config/argv semantics are
    untouched by the widget change."""
    s = box.checkState()
    if s == Qt.CheckState.Checked:
        return "on"
    if s == Qt.CheckState.Unchecked:
        return "off"
    return ""


def _hint(text):
    """A small word-wrapped gray helper label (the page-clarity pattern used across the
    wizard — same as NetworkPage._hint)."""
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet("color: gray;")
    return lab


def _field_default(name):
    """An ImageConfig field's declared default (mirrors NetworkPage._field_default and
    _gating.clear_unsupported's lookup) — the default-expansion rule compares against
    the dataclass's own truth, never literals restated in the GUI."""
    f = ImageConfig.__dataclass_fields__[name]
    return f.default_factory() if f.default is MISSING else f.default


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


class _PreflightWorker(QtCore.QThread):
    """Runs the two BLOCKING docker probes off the GUI thread (the freeze fix): the
    aggregate WorklistDriver.preflight() (per-entry `docker image inspect`) and
    BuildDriver.builder_image_missing() (another `docker image inspect`). Both used to
    run on the Qt main event loop from BuildPage._preview(), stalling the wizard AND the
    shared-process tray for up to ~16s on a slow docker daemon. Carries a monotonically
    increasing req_id so the GUI slot can drop stale results from rapid config changes."""
    # (problems: list[str], image_missing: bool, req_id, warnings: list[str]) — warnings
    # ride LAST so pre-existing 3-arg callers/tests of the slot stay valid.
    done = Signal(object, bool, int, object)

    def __init__(self, generator_dir, worklist, host, backend, driver, req_id):
        super().__init__()
        self._generator_dir = generator_dir
        self._worklist = worklist
        self._host = host
        self._backend = backend
        self._driver = driver
        self._req_id = req_id

    def run(self):
        warnings: list[str] = []
        try:
            drv = WorklistDriver(self._generator_dir, self._worklist,
                                 host=self._host, backend=self._backend)
            problems = drv.preflight()
        except Exception as e:
            problems = [f"cannot assemble the build: {e}"]
        else:
            # advisory low-memory warnings (2026-07-15 freeze guard) — a PARALLEL
            # channel: rendered under the problems pane, never fed to _set_problems,
            # so the Build button never gates on one. A warning-channel failure must
            # never clobber the problems result — warnings just stay empty.
            try:
                warnings = drv.preflight_warnings()
            except Exception:
                warnings = []
        try:
            image_missing = self._driver.builder_image_missing(self._backend)
        except Exception:
            image_missing = False
        self.done.emit(problems, image_missing, self._req_id, warnings)


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
        # the keys-USB dir last written through the keys_usb field by a device-table
        # assignment (so un-assigning never clobbers a hand-typed path)
        self._assigned_keys_dir = ""

        lay = scrollable(self)

        # ── section: Build execution — HOW and WHERE the build runs (backend engine,
        # stack env, output dir, parallelism). Each Collapsible carries the section
        # title, so the group boxes underneath are untitled — the NetworkPage pattern.
        # Backend / env are pick-one VALUE enumerations, so they stay DROPDOWNS (the
        # page's idiom rule, module docstring): a radio row per engine would spend a
        # line per value on choices that are almost never touched.
        self.exec_box = QtWidgets.QGroupBox("")
        ex = QtWidgets.QVBoxLayout(self.exec_box)
        self.backend = QtWidgets.QComboBox()
        self.backend.addItems(["auto", "native", "docker"])
        ex.addWidget(_row("Backend", self.backend))
        # --env: which stack environment the image bakes (every builder parses it)
        self.env = QtWidgets.QComboBox()
        self.env.addItems(list(ENV_CHOICES))
        ex.addWidget(_row("Environment (--env)", self.env))
        self.outdir = QtWidgets.QLineEdit()
        obtn = _file_picker(self, self.outdir, "Output dir", directory=True)
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.outdir, 1); h.addWidget(obtn)
        ex.addWidget(_row("Output dir", w))
        self.jobs = QtWidgets.QSpinBox(); self.jobs.setRange(1, 256); self.jobs.setValue(8)
        ex.addWidget(_row("Parallel jobs", self.jobs))
        # Expanded and never auto-folded: backend/outdir are the first things preflight
        # problems point at, so they must be on screen when the page loads.
        self.exec_section = collapsible("Build execution", self.exec_box)
        lay.addWidget(self.exec_section)

        # ── mesh worklist summary (design 3.12) — one row per image with per-entry
        # Packages…/Preview and the node key-zip opt-out. Shown only in mesh: the
        # SECTION is mode-gated alongside the group in initializePage (the NetworkPage
        # tailnet pattern — hiding only the content would leave an orphan header).
        self.worklist_group = QtWidgets.QGroupBox("")
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
        self.worklist_section = collapsible("Mesh worklist — one image per row",
                                            self.worklist_group)
        lay.addWidget(self.worklist_section)

        # ── section: Image options — WHAT the image contains / how it is stamped
        # (installer front-end, root size, packages, the x86 ISO finish knobs, grow
        # policy, version stamps). These sat LOOSE on the page — six bare checkboxes
        # and five bare rows between the boxed groups, which is the "flat wall" half
        # of the operator's organize-this-better report.
        self.image_box = QtWidgets.QGroupBox("")
        im = QtWidgets.QVBoxLayout(self.image_box)
        self.installer_ui = QtWidgets.QComboBox()
        self.installer_ui.addItems(["all", "cli", "ncurses", "calamares"])
        # Keep the ROW (label + combo): the role-class gate below greys the label with
        # its widget — gating the bare combo would strand a live "Installer UI" label
        # beside a dead control.
        self.installer_ui_row = _row("Installer UI", self.installer_ui)
        im.addWidget(self.installer_ui_row)
        # --img-size MiB: every builder parses it; 0 = "(role default)" emits nothing
        # (the builders size the compact root per role/desktop payload themselves).
        self.img_size = QtWidgets.QSpinBox()
        self.img_size.setRange(0, 1 << 20)
        self.img_size.setSuffix(" MiB")
        self.img_size.setSpecialValueText("(role default)")
        im.addWidget(_row("Root image size", self.img_size))
        # single-image Packages… (standalone/cloud) — replaces the retired free-text
        # extra-packages field with the per-image tri-tier dialog. An ACTION, so a
        # push button (idiom rule). The whole ROW is mode-gated in initializePage:
        # gating only the button used to leave an orphan "Packages" label in mesh.
        self.packages_btn = QtWidgets.QPushButton("Packages…")
        self.packages_btn.clicked.connect(self._open_packages_single)
        self.packages_row = _row("Packages", self.packages_btn)
        im.addWidget(self.packages_row)
        # x86 ISO finish knobs (like the installer-UI choice, the arm builders parse
        # none of these — the widgets grey out off-x86, and config.py emits x86-only).
        # Single-direction flags -> plain two-state checkboxes (idiom rule).
        self.cached = QtWidgets.QCheckBox(
            "Cached ISO — embed the binpkg cache (+distfiles) for offline rebuild / fast reinstall")
        self.live_toram = QtWidgets.QCheckBox(
            'Live ISO "Copy to RAM (removable)" boot entry')
        self.bundle_source = QtWidgets.QCheckBox(
            "Bundle the generator source — self-hosting image (standalone default)")
        # shown INSTEAD of an enabled checkbox when the unaffiliated role is selected
        self.bundle_note = QtWidgets.QLabel(
            "Source bundling does not apply — unaffiliated build (bundling the HugMesh "
            "generator source is a builder hard-conflict; the role presets it off).")
        self.bundle_note.setWordWrap(True)
        self.bundle_note.setStyleSheet("color: #a65d00;")
        self.bundle_note.setVisible(False)
        self.compress = QtWidgets.QCheckBox("Compress the finished image(s) (xz -9)")
        self.resume = QtWidgets.QCheckBox("Resume — reuse an existing sysroot")
        im.addWidget(self.cached)
        im.addWidget(self.live_toram)
        im.addWidget(self.bundle_source)
        im.addWidget(self.bundle_note)
        im.addWidget(self.compress)
        im.addWidget(self.resume)
        # --grow fill|none|<size> first-boot root-growth policy (G25): a dropdown by
        # the idiom rule (named values fill/none), kept EDITABLE so a size cap ("16G",
        # "50%") types straight in; "" leaves the builder default.
        self.grow = QtWidgets.QComboBox()
        self.grow.setEditable(True)
        self.grow.addItems(["", "fill", "none"])
        self.grow.lineEdit().setPlaceholderText("fill | none | <size e.g. 16G, 50%>  (empty = builder default)")
        im.addWidget(_row("First-boot root growth (--grow)", self.grow))
        # image stamps (G30): -v/--version is all-platform, --release-tag x86-only
        self.version = QtWidgets.QLineEdit()
        self.version.setPlaceholderText("-v/--version image stamp (empty = builder default)")
        self.release_tag = QtWidgets.QLineEdit()
        self.release_tag.setPlaceholderText("--release-tag image stamp (empty = deterministic build stamp)")
        im.addWidget(_row("Version stamp", self.version))
        im.addWidget(_row("Release tag", self.release_tag))
        # Expanded and never auto-folded: it carries the per-mode musts (the Packages…
        # entry point, the installer-UI honesty combo) and the unaffiliated bundle note.
        self.image_section = collapsible("Image options", self.image_box)
        lay.addWidget(self.image_section)

        # ── section: Artifacts — the selection matrix (G23 x86 / G24 ARM), per-field
        # platform-gated so exactly the axes THIS builder parses stay live. EVERY
        # control here answers one kind of question — "do I get this artifact?" — so
        # every control is a CHECKBOX: tri-state (G34) where the builder has a
        # --flag/--no-flag pair, two-state where it has a single flag. This box is
        # where the reported dropdown/checkbox mixture lived (three _tri_combo
        # dropdowns between five checkboxes).
        art = QtWidgets.QGroupBox("")
        arl = QtWidgets.QVBoxLayout(art)
        self.artifacts_box = art
        self.tri_legend = _hint(_TRI_LEGEND)
        arl.addWidget(self.tri_legend)
        self.build_img = _tri_check("Root image (--img / --no-img)")
        arl.addWidget(self.build_img)
        self.live_iso = _tri_check("Live ISO (--live-iso / --no-live-iso)")
        arl.addWidget(self.live_iso)
        self.installer_iso = QtWidgets.QCheckBox(
            "Installer ISO (--installer-iso — direct, no longer only an encrypt-root side effect)")
        arl.addWidget(self.installer_iso)
        self.build_iso = QtWidgets.QCheckBox(
            "Bootable installer ISO for an UNencrypted image (--iso; rpi5 — with the "
            "root image too = the builder's --both)")
        arl.addWidget(self.build_iso)
        self.sd_only = QtWidgets.QCheckBox("SD-card image only (--sd-only; rpi5)")
        arl.addWidget(self.sd_only)
        self.build_tar = _tri_check("Rootfs tar (--tar / --no-tar)")
        arl.addWidget(self.build_tar)
        self.skip_iso = QtWidgets.QCheckBox("Skip the ISO stage (--skip-iso)")
        arl.addWidget(self.skip_iso)
        self.image_only = QtWidgets.QCheckBox(
            "Image only — skip the live/installer media (--image-only; frite/jetson/orangepi*)")
        arl.addWidget(self.image_only)
        self.artifacts_section = collapsible("Artifacts", art)
        lay.addWidget(self.artifacts_section)

        # per-device flash / keys assignment table (replaces the old single-target
        # flash-with-build checkbox+dropdown). Every row defaults to "(none)" so no
        # flashing is ever the commit default; the actual write still goes through
        # scripts/flash-disk.sh on the ProgressPage (post-build, TOCTOU re-checked),
        # and a Keys-USB assignment writes through the existing keys_usb field below.
        # Deliberately NOT wrapped in a Collapsible: DeviceTable is already its own
        # titled QGroupBox with a live scan lifecycle (refresh-on-entry, Scanning…
        # button state, hot-plug re-scan), and folding a hardware-discovery surface
        # would hide a just-plugged USB stick behind a closed header at exactly the
        # moment the operator plugged it in to be seen. Its per-row Image/Role combos
        # are table-CELL enumerations — the dropdown idiom is correct there.
        self.device_table = DeviceTable(images_provider=self._flash_image_choices,
                                        keys_gate=self._keys_gate,
                                        on_assignment_changed=self._on_device_assignment)
        lay.addWidget(self.device_table)

        # ── section: Secure Boot + KEYS-USB signing chain (G5; x86 only). The builder
        # default is ON with a THROWAWAY org key — threading the existing fleet
        # key/cert PATHS here is what keeps GUI images in the fleet's SB chain. Paths
        # only: the Studio never reads the key material itself. The platform gate in
        # initializePage targets the SECTION (not this box), so hiding on ARM takes
        # the header too — no orphan "Secure Boot signing" header over nothing (the
        # NetworkPage egress-section lesson).
        sb = QtWidgets.QGroupBox("")
        sbl = QtWidgets.QVBoxLayout(sb)
        self.sb_box = sb
        # The on/off/default toggle is a tri-state CHECKBOX like its Artifacts kin
        # (it was the fourth _tri_combo dropdown); the old combo's default label
        # "(builder default: on — throwaway org key)" moves to a visible hint so the
        # information survives the widget change.
        sbl.addWidget(_hint("Builder default: ON, signed with a throwaway org key — "
                            "supply the fleet paths below to stay in the fleet chain."))
        self.secure_boot = _tri_check("Secure Boot (--secure-boot / --no-secure-boot)")
        sbl.addWidget(self.secure_boot)
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
        self.sb_section = collapsible("Secure Boot signing (x86)", sb)
        lay.addWidget(self.sb_section)

        # ── section: build plumbing (G38) — phases / seed / distfiles knobs that
        # change baked content, not artifacts. The formerly-loose PENTEST env toggle
        # and the extra-flags escape hatch are consolidated here (they are the same
        # kind of rarely-touched build-input knob, and they sat bare on the page
        # directly under this box anyway — consolidation, not relocation). The one
        # section that FOLDS by default: everything in it ships a sane default, and
        # _apply_default_expansion re-opens it whenever a loaded config carries a
        # non-default value (the NetworkPage security-section rule).
        plumb = QtWidgets.QGroupBox("")
        pl = QtWidgets.QVBoxLayout(plumb)
        self.plumbing_box = plumb
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
        # OWASP pen-test bake (G40) — PENTEST=1 is a FLEET/ENV knob the build driver
        # forwards to the build environment, never a per-builder argv flag.
        self.pentest = QtWidgets.QCheckBox(
            "OWASP pen-test bake (PENTEST=1 — env knob forwarded to the build, not a builder flag)")
        pl.addWidget(self.pentest)
        # escape hatch: EVERY builder CLI option stays expressible, fielded or not
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText(
            "appended verbatim, shell-quoted (for any builder flag without a field)")
        pl.addWidget(_row("Extra builder flags", self.extra_flags))
        self.plumbing_section = collapsible("Build plumbing (advanced)", plumb,
                                            expanded=False)
        lay.addWidget(self.plumbing_section)

        # The command / preflight / log panes and their action buttons stay UNsectioned
        # at the bottom: they are the Review page's OUTPUT — the thing the page exists
        # to show — not an option group anyone should be able to fold away and then
        # commit blind.
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
        # ── off-thread docker-probe plumbing (freeze fix) ──────────────────────────
        # _preview() splits into an INSTANT part (widgets -> cfg + command pane, no
        # daemon touch) and an OFF-THREAD part (the two docker probes) run by a
        # _PreflightWorker. A debounced single-shot timer collapses rapid config
        # changes; a monotonically-rising req_id drops stale worker results.
        self._recompute_gen = 0
        self._recompute_busy = False
        self._preflight_worker: _PreflightWorker | None = None
        self._recompute_timer = QtCore.QTimer(self)
        self._recompute_timer.setSingleShot(True)
        self._recompute_timer.setInterval(250)
        self._recompute_timer.timeout.connect(self._run_recompute)
        # a docker-backend change is the classic freeze trigger — debounce it off-thread
        self.backend.currentIndexChanged.connect(lambda _=0: self._schedule_recompute())
        # never leave a probe thread running past the wizard
        self.wiz.finished.connect(self._join_preflight_worker)
        self.wiz.finished.connect(lambda *_a: self.device_table.join())

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
        # Role-class honesty (#355 idiom): a headless x86 NODE cannot build the graphical
        # Calamares front-end — the desktop USE closure it needs is ROLE_CLIENT-gated in
        # build-x86-host-stage4.sh:2496 — so materialize rewrites installer_ui to "cli"
        # (core.config.resolve_installer_ui_default). Show THAT, not a stale "all" the
        # image will never honour: without the setCurrentText the combo would lie, and
        # validatePage would write the lie back into the config.
        # ASK the resolver, never RESTATE it: its rewrite is CONDITIONAL (calamares/all
        # only), so hard-coding "a node shows cli" lied for a node carrying "ncurses" —
        # that value pulls no calamares, is left alone by the resolver, and really is what
        # the image gets. effective_installer_ui() is the same authority materialize uses,
        # so the combo cannot drift from the argv if that rule ever changes.
        # Disable-with-reason rather than home.py's hide=True on purpose: the field stays
        # APPLICABLE to x86 (the builder parses --installer-ui) — it is the ROLE that
        # decides it, and hiding it would leave a node operator with no way to see WHY the
        # graphical installer is gone. The tooltip is the whole point.
        node = image_class(c.mode, c.role) == "node" and (c.platform or "x86") == "x86"
        shown = effective_installer_ui(c) if node else (c.installer_ui or "all")
        if node:
            self.installer_ui.setCurrentText(shown)   # what materialize actually emits
        # Gate the ROW, never the combo itself: gate_widgets_role_class setEnabled(True)s
        # when allowed, so passing the combo would CLOBBER the ARM platform gate set just
        # above (an ARM image is not node-class here, so it would be re-enabled). Qt
        # composes the two (effective = parent AND own), so the row gate stacks safely.
        # Every-visit re-gate (the _gating contract): flipping role back to a client
        # restores the combo, so this can never strand a desktop on "cli".
        reason = _installer_ui_reason(shown, rewritten=shown != (c.installer_ui or "all")) if node else ""
        gate_widgets_role_class(self.installer_ui_row, not node, reason)
        # ...and put the reason on the combo too — the row's tooltip only covers the
        # label, and the control itself is what a confused operator hovers.
        self.installer_ui.setToolTip(reason)
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
        # The worklist SECTION is gated alongside its group (the NetworkPage tailnet
        # pattern): hiding only the content would leave an orphan collapsible header.
        # The packages ROW is gated as one unit — gating just the button used to leave
        # a stray "Packages" label on the mesh page.
        self.worklist_group.setVisible(mesh)
        self.worklist_section.setVisible(mesh)
        self.packages_row.setVisible(not mesh)
        if mesh:
            self._refresh_worklist_table()
        # per-platform capability gating for the new fields (grow / version /
        # skip-kernel / skip-clean / build-subdir / seed-url / pentest are
        # all-platform or out-of-band, so they never gate). hide=True HIDES the
        # inapplicable options rather than greying them; clear_unsupported() (below,
        # in _preview/validatePage) still resets a hidden field to its default and the
        # every-visit re-gate restores it when the platform supports it again, so
        # emission is preserved (build-matrix stays 746/0).
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
            # the SECTION, not sb_box: sb_box is now the section's collapsible CONTENT,
            # and Collapsible.set_expanded drives the content's setVisible — a gate
            # pinned on the content would be fought by every expand. Hiding the section
            # also takes the header with it (no orphan header on ARM), and the gate's
            # every-visit setVisible(True) restores it the moment the platform supports
            # Secure Boot again.
            "secure_boot": self.sb_section,
            "distdir": self.distdir_row,
        }, hide=True)
        # gate_widgets blanks the tooltip on every SUPPORTED widget it gates — restore
        # the 3-state explanation on the live tri-state boxes (an unsupported one keeps
        # the platform note the gate set), the NetworkPage restore idiom. secure_boot's
        # gate rides its SECTION, so the box's own tooltip is never blanked — set it
        # anyway so all four tri-boxes stay uniform whatever the gate map becomes.
        for tri_fld, tri_box in (("build_img", self.build_img),
                                 ("live_iso", self.live_iso),
                                 ("build_tar", self.build_tar),
                                 ("secure_boot", self.secure_boot)):
            if platform_supports(tri_fld, c.platform):
                tri_box.setToolTip(_TRI_TIP)
        self.device_table.refresh()          # auto-refresh the device table on entry
        self._apply_default_expansion()
        self._preview()

    def _apply_default_expansion(self):
        """Fold the advanced plumbing section when EVERY field it carries is at its
        dataclass default, and only then (the NetworkPage security-section rule,
        applied through set_default_expanded so a section the operator opened by hand
        is never re-folded underneath them). Compared against ImageConfig's OWN
        declared defaults (_field_default), never restated literals, and re-derived on
        every visit so a loaded config's --skip-kernel or a stashed extra-flags line is
        opened INTO view, not folded out of it. The other sections never auto-fold:
        execution/image/artifacts/Secure Boot all carry things a Review page must show
        (and existing tests read e.g. sb_box.isVisible() as the PLATFORM gate's signal,
        which a default-fold would alias — the exact collapse-vs-gate confusion
        _widgets.Collapsible exists to avoid)."""
        c = self.wiz.cfg
        plumbing_default = all(
            getattr(c, f) == _field_default(f)
            for f in ("skip_kernel", "skip_clean", "distdir", "build_subdir",
                      "seed_url", "pentest", "extra_flags"))
        self.plumbing_section.set_default_expanded(not plumbing_default)

    def _backend(self):
        b = self.backend.currentText()
        return None if b == "auto" else b

    def _pending_session_workdir(self) -> str:
        """The per-session artifact dir the NEXT dispatch will use. Mints the session id
        ONCE per build attempt (lazily): Back-and-forth reuses the same id, and
        ProgressPage clears wiz.pending_session_id at finish so a second run mints a
        new one. Runtime driver state only — never written into cfg.output_dir."""
        if not getattr(self.wiz, "pending_session_id", None):
            self.wiz.pending_session_id = build_sessions.new_session_id()
        out = self.wiz.cfg.output_dir or os.path.join(self.wiz.generator_dir, "out")
        return build_sessions.session_workdir(out, self.wiz.pending_session_id)

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
        # installer_ui: on a NODE the combo is a READ-ONLY REPORT of what
        # resolve_installer_ui_default() will emit ("cli"), not a user choice — so it must
        # NOT be written back. Writing it back persisted "cli" into the config, and a
        # LATER desktop image then inherited it (initializePage restores from c.installer_ui),
        # silently stripping the graphical installer from an image that wants and can build
        # one. The resolver at materialize is the authority for nodes; the user's real
        # preference is preserved untouched across a node detour.
        if image_class(c.mode, c.role) != "node" or (c.platform or "x86") != "x86":
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
        # tri-state checkboxes collect through _tri_value — the same ''/'on'/'off'
        # domain the retired _tri_combo dropdowns' currentData() carried, so the
        # emission (and every save/load round-trip) is byte-identical to before the
        # widget change.
        c.build_img = _tri_value(self.build_img)
        c.live_iso = _tri_value(self.live_iso)
        c.installer_iso = self.installer_iso.isChecked()
        c.build_iso = self.build_iso.isChecked()
        c.sd_only = self.sd_only.isChecked()
        c.build_tar = _tri_value(self.build_tar)
        c.skip_iso = self.skip_iso.isChecked()
        c.image_only = self.image_only.isChecked()
        c.secure_boot = _tri_value(self.secure_boot)
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
            # ...and the role-class twin, for the same reason: the real build path applies
            # BOTH resolvers, so without this the pane rendered `--installer-ui all` for an
            # x86 node while the build ran `--installer-ui cli`. The pane is copy-pasteable:
            # that stale argv, run by hand, is exactly the WANT_CALAMARES=true (:1246) ->
            # app-admin/calamares (:3532) -> unsatisfiable libpwquality[python] wall this
            # change exists to prevent. `pc` is already a deepcopy, so the user's stored
            # preference still survives a node detour untouched. The note is dropped on
            # purpose — this is a GUI pane, not app.py's stderr channel; the greyed combo
            # and its tooltip already carry the reason.
            resolve_installer_ui_default(pc)
            # Session-aware preview honesty: the GUI dispatch runs with the per-session
            # workdir (-w <out>/sessions/<id>/ — ProgressPage consumes the same pending
            # id), so the pane must show LITERALLY that argv. Headless --print-command
            # keeps the default because a headless run really uses the default.
            cmdline = BuildDriver(self.wiz.generator_dir, self.wiz.host, graphical=True,
                                  workdir=self._pending_session_workdir()
                                  ).command_string(pc, self._backend())
        except ValueError as e:  # e.g. unbalanced quotes in the extra-flags escape hatch
            self.cmd.setPlainText("")
            self.log.setPlainText(f"Command error: {e}")
            self._set_problems([str(e)])
            return
        self.cmd.setPlainText(cmdline)
        # The command pane above updated INSTANTLY (pure argv assembly, no daemon).
        # The AGGREGATE preflight + builder-image probe are the two docker subprocess
        # calls that used to freeze the wizard + tray here — kick them off-thread.
        self._schedule_recompute()

    # ---- off-thread preflight (freeze fix) -------------------------------------
    def _schedule_recompute(self) -> None:
        """(Re)start the debounce so a burst of config changes collapses into ONE
        off-thread probe. Bumps the req_id (stale results are dropped) and shows the
        Build button's busy state until the worker returns."""
        self._recompute_gen += 1
        self._set_busy(True)
        self.log.setPlainText("Checking Docker availability…")
        self._recompute_timer.start()

    def _run_recompute(self) -> None:
        """Debounce fired: launch the probe worker unless one is already in flight (it
        will be re-fired from _on_preflight_done when it finishes, against the newest
        req_id)."""
        if self._preflight_worker is not None and self._preflight_worker.isRunning():
            # a probe is still finishing (e.g. the just-superseded one whose done signal
            # re-fired this timer): re-arm rather than return, so we can never end with a
            # pending recompute and no trigger left = a permanently-stuck busy Build button.
            self._recompute_timer.start()
            return
        try:
            worklist = self._current_worklist()      # pure assembly, no daemon touch
        except Exception as e:
            self._on_preflight_done([f"cannot assemble the build: {e}"], False,
                                    self._recompute_gen)
            return
        self._preflight_worker = _PreflightWorker(
            self.wiz.generator_dir, worklist, self.wiz.host, self._backend(),
            self.wiz.driver, self._recompute_gen)
        self._preflight_worker.done.connect(self._on_preflight_done)
        self._preflight_worker.start()

    def _on_preflight_done(self, problems, image_missing: bool, req_id: int,
                           warnings=()) -> None:
        """GUI-thread slot: apply the probe result, or drop it (and re-fire) if a newer
        config change has superseded this req_id. ``warnings`` are advisory (low-memory
        guard): rendered as text ONLY — never routed through _set_problems, so
        isComplete()/the Build button never gate on one."""
        if req_id != self._recompute_gen:
            self._recompute_timer.start()            # a newer request is pending — run it
            return
        self._set_problems(list(problems))
        self.build_image_btn.setVisible(bool(image_missing))
        if self._problems:
            text = "Preflight:\n  - " + "\n  - ".join(self._problems)
        else:
            text = "Preflight OK."
        warns = list(warnings)
        if warns:
            text += ("\nWarnings (advisory — the build is not blocked):\n  - "
                     + "\n  - ".join(warns))
        self.log.setPlainText(text)
        self._set_busy(False)

    def _set_busy(self, busy: bool) -> None:
        """Disable + spinner-text the wizard's Commit/Build button while a docker probe
        is in flight (isComplete() reads _recompute_busy)."""
        self._recompute_busy = busy
        try:
            self.wiz.setButtonText(QtWidgets.QWizard.WizardButton.CommitButton,
                                   "Checking Docker…" if busy else "Build")
        except Exception:
            pass
        self.completeChanged.emit()

    def _join_preflight_worker(self, *_a) -> None:
        if self._preflight_worker is not None and self._preflight_worker.isRunning():
            self._preflight_worker.wait(3000)

    def _aggregate_preflight(self) -> list[str]:
        """WorklistDriver.preflight over the would-be-committed worklist. Materialize can
        raise on an invalid identity — surface that as the single blocking problem.
        Kept for direct/synchronous callers; the live page path runs it off-thread via
        _PreflightWorker so the docker subprocess never stalls the event loop."""
        try:
            drv = WorklistDriver(self.wiz.generator_dir, self._current_worklist(),
                                 host=self.wiz.host, backend=self._backend())
            return drv.preflight()
        except Exception as e:
            return [f"cannot assemble the build: {e}"]

    # ---- device table (flash / keys assignment) ----------------------------------
    def _flash_image_choices(self) -> list[tuple]:
        """[(entry_id, role, platform, domains)] for the per-device Image combo — the
        would-be-committed worklist (mesh = the WorklistPage selection; standalone/
        cloud = the synthesized 1-entry shape, so the combo shows exactly one image
        and the single-image case degrades gracefully). ``domains`` are the cluster
        Domain names attached to the entry (a Domain with an empty images list
        attaches to every image — config.Domain), so the combo reads "be.rpi5
        (beta.example)" and a device is assigned a node WITH its domain, not a bare
        id."""
        try:
            wl = self._current_worklist()
        except Exception:
            return []
        domains = list(getattr(self.wiz.cfg, "domains", ()) or ())
        out = []
        for e in wl.entries:
            attached = tuple(
                d.name for d in domains
                if getattr(d, "name", "") and (
                    not getattr(d, "images", None) or e.id in d.images))
            out.append((e.id, e.role, e.platform, attached))
        return out

    def _keys_gate(self) -> tuple:
        """(allowed, reason) for the table's Keys-USB role: keys_usb is platform-gated
        (x86-only today per PLATFORM_FIELD_SUPPORT) — an assignment the builder would
        silently drop is never offered (the hide-inapplicable honesty rule)."""
        platform = self.wiz.cfg.platform
        return (platform_supports("keys_usb", platform), unsupported_note(platform))

    def _on_device_assignment(self) -> None:
        """A Keys-USB assignment writes THROUGH the existing keys_usb line edit, so
        cfg.keys_usb flows down the pre-existing --keys-usb emission and the command
        preview updates immediately (no new argv path). Un-assigning clears the field
        only while it still equals the assigned dir — never a hand-typed path."""
        ka = self.device_table.keys_assignment()
        assigned = ka[1] if ka else ""
        if assigned:
            if self.keys_usb.text().strip() != assigned:
                self.keys_usb.setText(assigned)
                self._preview()
        elif self._assigned_keys_dir and \
                self.keys_usb.text().strip() == self._assigned_keys_dir:
            self.keys_usb.setText("")
            self._preview()
        self._assigned_keys_dir = assigned

    def _set_problems(self, problems: list[str]) -> None:
        self._problems = problems
        self.completeChanged.emit()

    # ---- mesh worklist summary --------------------------------------------------
    def _refresh_worklist_table(self):
        try:
            # workdir: the per-entry Preview buttons must show the session -w the real
            # dispatch will use (same honesty rule as the main command pane above).
            self._wl_driver = WorklistDriver(self.wiz.generator_dir, self._current_worklist(),
                                             host=self.wiz.host, backend=self._backend(),
                                             workdir=self._pending_session_workdir())
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
        """Build/Finish is enabled only when the aggregate preflight is clean (design 3.12)
        AND no docker probe is in flight (the freeze-fix busy state — the button reads
        'Checking Docker…' and is disabled until the off-thread recompute returns)."""
        return not self._problems and not self._recompute_busy

    def validatePage(self) -> bool:
        """Commit the WorklistConfig and stash the run parameters ProgressPage reads, then
        advance (commit) to the terminal ProgressPage."""
        self._preview()
        self.wiz.worklist = self._current_worklist()
        self.wiz.build_backend = self._backend()
        self.wiz.generate_node_keys = (self.gen_keys.isChecked()
                                       if self.wiz.cfg.mode == "mesh" else True)
        # per-device post-build flash plan (default: EMPTY — every row's Role combo
        # defaults to "(none)", so no flashing is ever the commit default). Each
        # assignment stashes the full FlashTarget identity (path + size + model) so
        # ProgressPage can re-run the TOCTOU identity check before writing anything.
        entries = {e.id: e for e in self.wiz.worklist.entries}
        work_dir = (self.wiz.cfg.output_dir
                    or os.path.join(self.wiz.generator_dir, "out"))
        plan = []
        for target, entry_id, flavor in self.device_table.flash_assignments():
            entry = entries.get(entry_id)
            if entry is None:
                continue                # image no longer in the committed worklist
            role = (entry.role if entry.role in flash_targets.FLASH_ROLE_TOKENS
                    else "host")        # flash-disk.sh's --role token set
            plan.append(flash_targets.FlashAssignment(
                target=target, entry_id=entry_id, role=role,
                arch=flash_targets.arch_for_platform(entry.platform),
                work_dir=work_dir, flavor=flavor))
        self.wiz.flash_plan = plan
        # legacy single-target stash kept (always OFF — the table superseded it) so
        # ProgressPage's legacy tuple branch and its tests are untouched.
        self.wiz.flash_after = (False, None)
        return True
