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
* on/off build toggles are CHECKBOXES — two-state, always, with a DEFINITE default. The
  --flag/--no-flag pairs were tri-state until ask 13 ("cached iso, live iso, bundle,
  compress and resume should all be default on"): the square meant "leave the builder's
  default", and for every one of them that default is ON, so checked already said it —
  see _flag_check;
* actions (Packages… / Preview / Refresh preview / Build builder image now) are PUSH
  BUTTONS.

Related controls are grouped into the wizard's Collapsible sections (_widgets.collapsible
— the NetworkPage house pattern): Build execution / mesh worklist / Image options /
Artifacts & build options / Secure Boot / Build plumbing. "Image options" and "Artifacts"
used to be two of those, which is what ask 13's "should include the artifacts as they're
the same thing side by side" is about — an option and the artifact it yields are now ONE
row, not two sections. Collapsing is PRESENTATION ONLY (see
_widgets.Collapsible): validatePage/_preview read widget VALUES, which a folded widget
keeps, and clear_unsupported keys on the capability table, never on visibility.
"""
from __future__ import annotations

import copy
import os

from dataclasses import MISSING

from ..qt import Qt, QtCore, QtWidgets, Signal
from .. import console
from ._scroll import reveal, scrollable
from ...core import build_sessions
from ...core import cross_dracut
from ...core import flash_targets
from ...core import root_size_floor
from ...core import secret_files
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


# ── DEFINITE DEFAULTS: why the part-checked square is gone from this page too ─────────
# Ask 13, verbatim: "cached iso, live iso, bundle, compress and resume should all be
# default on and should include the artifacts as they're the same thing side by side".
# The first half is ask 1's complaint inverted — the operator wants these DEFINITELY
# checked, not part-checked — so the flag-pair boxes here became two-state alongside the
# NetworkPage service boxes, and the tri-state legend that explained the square went with
# them.
#
# UNSET READS AS CHECKED, and that is not a guess: every flag-pair on this page has a
# builder default of TRUE on every builder that parses it —
#   BUILD_IMG=true   build-x86-host-stage4.sh:231, build-rpi5-stage4.sh:173, build-jetson-stage4.sh:154
#   LIVE_ISO=true    build-x86-host-stage4.sh:236
#   BUILD_TAR=true   build-x86-host-stage4.sh:238, build-rpi5-stage4.sh:175
#   SECURE_BOOT=true build-x86-host-stage4.sh:484
# so "leave the builder's default" and "checked" were always the same PICTURE; the square
# only ever advertised a distinction in the argv, not in the image. Making it explicit
# adds --img/--live-iso/--tar/--secure-boot to the emitted command and changes nothing
# about what is built. tests/test_pages_build_sections.py pins that equivalence.
_FLAG_TIP = ("Two-state: checked = --flag, unchecked = --no-flag. There is no "
             "\"leave the builder's default\" state — the builder's default for this "
             "one is ON, which is what checked already means.")


def _flag_check(text):
    """A --flag / --no-flag pair as an ordinary two-state checkbox.

    Was ``_tri_check``. That existed to preserve one property — the builder's own default
    must round-trip — which is only worth a third state when the builder's default is
    something a two-state box cannot show. For all four boxes on this page it is not: the
    default is ON (see the block above), so checked says it exactly."""
    box = QtWidgets.QCheckBox(text)
    box.setChecked(True)
    box.setToolTip(_FLAG_TIP)
    return box


def _set_flag(box, value):
    """Show a flag-pair config value. Only an explicit "off" unchecks — '' (never set),
    True and "on" all read as checked, because the builder's unset behaviour for every
    field using this helper is ON. ImageConfig._tri stays the single normalizer so bools
    from a loaded config resolve exactly as the emission resolves them."""
    box.setChecked(ImageConfig._tri(value) != "off")


def _flag_value(box):
    """Checkbox -> the config value. Always DEFINITE ('on' | 'off') — the wizard no longer
    has a way to say '' (leave unspecified), which is the whole of ask 13's first half.
    The config DOMAIN is unchanged, so a --config JSON or headless caller carrying '' is
    still accepted and still emits neither flag."""
    return "on" if box.isChecked() else "off"


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
        # ASK 22 — "Simplify the review screen and make the build screen separate". The
        # page is REVIEW now, nothing else: it no longer promises "Build" in its title or
        # on its button, because leaving it no longer starts anything — it lands on the
        # separate LaunchPage, whose Continue is what dispatches. What it gained is a
        # plain-language SUMMARY at the top (see _refresh_summary): the answer to "what
        # will this produce" used to be available only by reading a 500-character argv in
        # the Command pane, which is exactly the thing an operator should not have to
        # parse to sanity-check a build.
        self.setTitle("Review")
        self.setSubTitle("Check what will be built. Nothing starts here — the next "
                         "screen has the Continue button.")
        # commit page: leaving it commits the worklist (design 3.12/3.13). Back is
        # disabled from here on, which is WHY the launch screen offers an explicit
        # "back to the main menu" instead.
        self.setCommitPage(True)
        try:
            self.wiz.setButtonText(QtWidgets.QWizard.WizardButton.CommitButton, "Continue")
        except Exception:
            pass
        self._problems: list[str] = []
        # ask 21: whether THIS host can satisfy the ARM cross-dracut preflight an
        # encrypted root drags in. Sampled once per page visit (initializePage) and
        # cached, so review_summary() stays the pure, probe-free function its docstring
        # promises — the summary is recomputed on every widget change.
        self._cross_dracut_ready = False
        # mesh run state (populated in initializePage when mode == mesh)
        self._wl_driver: WorklistDriver | None = None
        self._materialized: list = []
        # the keys-USB dir last written through the keys_usb field by a device-table
        # assignment (so un-assigning never clobbers a hand-typed path)
        self._assigned_keys_dir = ""

        lay = scrollable(self)

        # ── ASK 22: the summary — the review, in one block, above the knobs ────────
        # Plain text (it interpolates an output PATH and entry ids, which must render as
        # themselves) and refreshed by _preview(), so it always describes the config the
        # command pane below it was just rendered from.
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        self.summary.setTextFormat(Qt.TextFormat.PlainText)
        lay.addWidget(self.summary)

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
        self.img_size.setToolTip(
            "Compact ext4 root size baked into the .img (growroot expands it to "
            "the disk on first boot). 0 = the builder's role default, sized from "
            "MEASURED payloads (x86 thin desktop 16384, full 24576, capable "
            "51200; nodes 14336/20480; ARM installers 2048-9216). An explicit "
            "size below that floor is refused on Build — it would abort in the "
            ".img pre-flight only after the full emerge.")
        im.addWidget(_row("Root image size", self.img_size))
        # inline (NEVER a modal QMessageBox: validatePage runs headless in tests and
        # a modal would hang them) — set by validatePage when the size is undersized.
        self.img_size_err = QtWidgets.QLabel("")
        self.img_size_err.setWordWrap(True)
        self.img_size_err.setStyleSheet("color: #c62828;")
        self.img_size_err.setVisible(False)
        im.addWidget(self.img_size_err)
        # single-image Packages… (standalone/cloud) — replaces the retired free-text
        # extra-packages field with the per-image tri-tier dialog. An ACTION, so a
        # push button (idiom rule). The whole ROW is mode-gated in initializePage:
        # gating only the button used to leave an orphan "Packages" label in mesh.
        self.packages_btn = QtWidgets.QPushButton("Packages…")
        self.packages_btn.clicked.connect(self._open_packages_single)
        self.packages_row = _row("Packages", self.packages_btn)
        im.addWidget(self.packages_row)
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

        # ── section: Artifacts & build options ────────────────────────────────────────
        # ASK 13's second half, verbatim: the artifact options "should include the
        # artifacts as they're the same thing side by side".
        #
        # They were two sections. "Image options" held cached / live-toram / bundle-source
        # / compress / resume; "Artifacts" held the .img / .iso / .tar toggles those five
        # options act ON. So "Cached ISO" lived in one box and "Live ISO" — the ISO it
        # caches into — lived in another, and the operator had to hold the pairing in
        # their head. They are now ONE section of rows, each row saying the option and the
        # artifact it yields side by side, with the two live-ISO modifiers indented under
        # the Live ISO row they modify.
        #
        # The right-hand column is not decoration: it is where "does turning this on change
        # what I get?" gets answered on screen. Ask 13 names five options, and they do NOT
        # divide the way a first reading suggests — transcribed from the builders rather
        # than assumed, because getting this wrong means quietly changing what a build
        # produces while claiming to have changed a checkbox:
        #
        #   cached    ISO_CACHED=false   (build-x86-host-stage4.sh:403)  -> CHANGES the
        #             build. Embeds the binpkg cache + distfiles in the live ISO: a
        #             materially larger ISO that can rebuild offline.
        #   compress  COMPRESS_IMG=false (x86:242, rpi5:186, jetson:165) -> CHANGES the
        #             build. xz -9 over every finished artifact; a long build tail.
        #   resume    RESUME=false       (x86:207, rpi5:174, jetson:156) -> CHANGES the
        #             build. Reuses the previous sysroot instead of wiping it.
        #   live_iso  LIVE_ISO=true      (x86:243)                       -> no change.
        #             The box now emits --live-iso explicitly where it used to emit
        #             nothing; the builder was already doing it.
        #   bundle_source                                                -> no change BY
        #             THIS LANE, and deliberately not claimed as "the builder was already
        #             doing it": ImageConfig.bundle_source has defaulted True since long
        #             before ask 13, so nothing here moved. The builder's own default is
        #             BUNDLE_SOURCE="" resolved at x86:1495 to standalone?true:false — so
        #             on a NODE build Studio has always overridden it to true. That is
        #             pre-existing behaviour, out of this lane's scope, and recorded here
        #             rather than smoothed over.
        #
        # So three of the five genuinely change output and two do not. That distinction was
        # not visible anywhere before; it is now a caption beside each box, and
        # tests/test_pages_build.py::test_ask13_defaults_that_change_the_build_are_the_
        # single_flags pins it.
        art = QtWidgets.QGroupBox("")
        arl = QtWidgets.QVBoxLayout(art)
        self.artifacts_box = art
        arl.addWidget(_hint(
            "Each row is an option and the artifact it produces. Ticked = you get it."))
        grid = QtWidgets.QGridLayout()
        grid.setColumnStretch(0, 1)
        grid.setHorizontalSpacing(18)
        self.artifact_labels: dict[str, QtWidgets.QLabel] = {}

        def _art_row(box, artifact, key, indent=False):
            """One [checkbox] ── [→ artifact] row. `key` names it for the tests and for
            the per-platform gate, which drives the WHOLE row (a live checkbox beside a
            greyed artifact caption would be the orphan-caption bug the NetworkPage egress
            section already paid for)."""
            row = grid.rowCount()
            if indent:
                box.setStyleSheet("margin-left: 18px;")
            grid.addWidget(box, row, 0)
            lab = QtWidgets.QLabel(artifact)
            lab.setWordWrap(True)
            lab.setStyleSheet("color: gray;")
            self.artifact_labels[key] = lab
            grid.addWidget(lab, row, 1)
            return box

        self.build_img = _art_row(
            _flag_check("Root image"), "→ <brand>.img — the flashable raw disk image "
            "(--img / --no-img)", "build_img")
        self.live_iso = _art_row(
            _flag_check("Live ISO"), "→ live.iso — self-booting live squashfs "
            "(--live-iso / --no-live-iso)", "live_iso")
        # The two live-ISO modifiers, indented under the artifact they modify. Both were
        # in the OTHER section, one scroll away from the ISO they are about.
        self.cached = _art_row(
            QtWidgets.QCheckBox("…with the binpkg cache and distfiles embedded"),
            "→ a MATERIALLY LARGER live.iso that can rebuild offline (--cached; "
            "unticked emits --uncached)", "cached", indent=True)
        self.live_toram = _art_row(
            QtWidgets.QCheckBox('…with a "Copy to RAM (removable)" boot entry'),
            "→ an extra entry in that ISO's boot menu (--live-toram)", "live_toram",
            indent=True)
        self.installer_iso = _art_row(
            QtWidgets.QCheckBox("Installer ISO"),
            "→ installer.iso — direct, no longer only an --encrypt-root side effect "
            "(--installer-iso)", "installer_iso")
        self.build_iso = _art_row(
            QtWidgets.QCheckBox("Installer ISO for an UNencrypted image (rpi5)"),
            "→ installer.iso; with the root image too this is the builder's --both "
            "(--iso)", "build_iso")
        self.sd_only = _art_row(
            QtWidgets.QCheckBox("SD-card image only (rpi5)"),
            "→ the SD image and nothing else (--sd-only)", "sd_only")
        self.build_tar = _art_row(
            _flag_check("Rootfs tar"), "→ fs.tar.xz — the mounted-filesystem tarball "
            "(--tar / --no-tar)", "build_tar")
        self.bundle_source = _art_row(
            QtWidgets.QCheckBox("Bundle the generator source into the image"),
            "→ the generator tree + /usr/sbin/hugmesh-regenerate INSIDE every artifact "
            "— a self-hosting image (--bundle-source)", "bundle_source")
        # shown INSTEAD of an enabled checkbox when the unaffiliated role is selected
        self.bundle_note = QtWidgets.QLabel(
            "Source bundling does not apply — unaffiliated build (bundling the HugMesh "
            "generator source is a builder hard-conflict; the role presets it off).")
        self.bundle_note.setWordWrap(True)
        self.bundle_note.setStyleSheet("color: #a65d00;")
        self.bundle_note.setVisible(False)
        self.compress = _art_row(
            QtWidgets.QCheckBox("Compress the finished image(s) — xz -9"),
            "→ every artifact above gains .xz; smaller files, a long build tail "
            "(--compress)", "compress")
        self.resume = _art_row(
            QtWidgets.QCheckBox("Resume — reuse the existing sysroot instead of wiping it"),
            "→ the SAME artifacts, built incrementally over whatever tree the last run "
            "left behind (--resume)", "resume")
        self.skip_iso = _art_row(
            QtWidgets.QCheckBox("Skip the ISO stage"),
            "→ no ISO artifacts at all (--skip-iso)", "skip_iso")
        self.image_only = _art_row(
            QtWidgets.QCheckBox("Image only — skip the live/installer media"),
            "→ the .img alone; frite/jetson/orangepi* (--image-only)", "image_only")
        arl.addLayout(grid)
        arl.addWidget(self.bundle_note)
        # --resume is the one default in ask 13 that can surprise: a run WITHOUT it
        # deliberately wipes the sysroot (scripts/build-menu.sh:644-649 documents that),
        # so defaulting it ON makes every build incremental over whatever the last one
        # left. That is what was asked for, and it is said out loud rather than shipped
        # quietly — the honesty rule this codebase applies to builder contracts.
        self.resume_note = _hint(
            "Note: Resume is on by default, so a build continues from the previous "
            "sysroot rather than starting from a clean one. Untick it when you want a "
            "guaranteed-from-scratch build.")
        arl.addWidget(self.resume_note)
        self.artifacts_section = collapsible("Artifacts & build options", art)
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
        # key/cert here is what keeps GUI images in the fleet's SB chain. The
        # platform gate in initializePage targets the SECTION (not this box), so
        # hiding on ARM takes the header too — no orphan "Secure Boot signing"
        # header over nothing (the NetworkPage egress-section lesson).
        #
        # SECRET-FILE RETENTION (2026-07-29 operator ask, verbatim: "instead of just
        # browsing for keys usb or signing key or cert, once the file is selected its
        # held in memory until the build is completed, if the build is restarted, a
        # prompt appears to reenter when it is needed"): BROWSING the KEYS USB dir or
        # the signing key now also holds its CONTENT in the process vault
        # (core/secret_files.py), so the build consumes the in-memory copy (via a
        # private 0600 tmp file at dispatch) and survives the USB being unplugged.
        # The row shows filename + sha256 fingerprint + the retention promise. A
        # hand-TYPED path keeps today's plain-path semantics (the textEdited hook
        # drops any held copy — the selection changed). The signing CERT stays a
        # plain path on purpose: it is the PUBLIC half, baked into the image rootfs
        # for enrollment (build-x86-host-stage4.sh installs it to
        # ${SB_ETC_DIR}/sb.crt), so it is not material that must not linger.
        sb = QtWidgets.QGroupBox("")
        sbl = QtWidgets.QVBoxLayout(sb)
        self.sb_box = sb
        # The on/off/default toggle is a tri-state CHECKBOX like its Artifacts kin
        # (it was the fourth _tri_combo dropdown); the old combo's default label
        # "(builder default: on — throwaway org key)" moves to a visible hint so the
        # information survives the widget change.
        sbl.addWidget(_hint("Builder default: ON, signed with a throwaway org key — "
                            "supply the fleet paths below to stay in the fleet chain."))
        self.secure_boot = _flag_check("Secure Boot (--secure-boot / --no-secure-boot)")
        sbl.addWidget(self.secure_boot)
        self.keys_usb = QtWidgets.QLineEdit()
        self.keys_usb.setPlaceholderText("KEYS USB dir providing Keys/kernel_key.{pem,der} (--keys-usb)")
        sbl.addWidget(_row("KEYS USB dir", self._vault_picker_row(
            "keys_usb", self.keys_usb, "KEYS USB dir", directory=True)))
        self.keys_usb_held = self._held_label()
        sbl.addWidget(self.keys_usb_held)
        self.secureboot_key = QtWidgets.QLineEdit()
        self.secureboot_key.setPlaceholderText("SB signing private key PEM path (--secureboot-key)")
        sbl.addWidget(_row("Signing key", self._vault_picker_row(
            "secureboot_key", self.secureboot_key, "SB signing key",
            "Keys (*.pem *.key);;All files (*)")))
        self.secureboot_key_held = self._held_label()
        sbl.addWidget(self.secureboot_key_held)
        self.secureboot_cert = QtWidgets.QLineEdit()
        self.secureboot_cert.setPlaceholderText("SB signing cert PEM/DER path (--secureboot-cert)")
        sbl.addWidget(_row("Signing cert", _picker_row(self, self.secureboot_cert, "SB signing cert",
                                                       "Certs (*.pem *.der *.crt);;All files (*)")))
        cert_note = QtWidgets.QLabel(
            "The cert is the PUBLIC half — it stays a path (the builder bakes it "
            "into the image for Secure Boot enrollment), so it is never held in "
            "memory like the private key.")
        cert_note.setWordWrap(True)
        cert_note.setStyleSheet("color: gray;")
        sbl.addWidget(cert_note)
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
        # Post-build QEMU emulated-device tests. Like PENTEST this is a driver-level
        # step, not a builder flag (NON_ARGV_FIELDS), so it changes no argv.
        #
        # Gated on --env test: a prod build has the in-cluster test runner pruned out
        # of its ArgoCD app tree, so booting one would assert against a stack that was
        # deliberately removed. Greyed rather than hidden, because the reason is a
        # decision the operator made one dropdown above and can reverse.
        self.qemu_e2e = QtWidgets.QCheckBox(
            "After the build, run the QEMU emulated-device tests in Docker "
            "(all platforms, Pi first)")
        pl.addWidget(self.qemu_e2e)
        self.env.currentTextChanged.connect(self._sync_qemu_e2e_gate)
        # escape hatch: EVERY builder CLI option stays expressible, fielded or not
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText(
            "appended verbatim, shell-quoted (for any builder flag without a field)")
        pl.addWidget(_row("Extra builder flags", self.extra_flags))
        self.plumbing_section = collapsible("Build plumbing (advanced)", plumb,
                                            expanded=False)
        lay.addWidget(self.plumbing_section)

        # The exact builder invocation. It used to sit UNsectioned at the bottom on the
        # reasoning that it is "the Review page's OUTPUT — the thing the page exists to
        # show". Ask 22 retires that reasoning rather than the pane: the summary at the
        # top is now the thing the page exists to show, in words, and a 500-character
        # argv is developer output — kept verbatim, one click away, folded by default so
        # the review reads as a review. Folding is presentation only (_widgets.
        # Collapsible), so _preview()/validatePage and every test that reads cmd's text
        # are untouched, and the PROBLEMS pane below stays outside it: a preflight
        # failure must never be foldable.
        self.cmd = console.attach(QtWidgets.QPlainTextEdit()); self.cmd.setReadOnly(True); self.cmd.setMaximumHeight(120)
        cmd_box = QtWidgets.QGroupBox("")
        cb = QtWidgets.QVBoxLayout(cmd_box)
        # Whose command is in the pane. Hidden while it holds the whole-config argv (the
        # normal state, which needs no caption); shown when a mesh worklist row's Preview
        # has replaced it with THAT image's command, because the two are indistinguishable
        # by eye — both are 500 characters of builder argv.
        self.cmd_caption = QtWidgets.QLabel("")
        self.cmd_caption.setWordWrap(True)
        self.cmd_caption.setVisible(False)
        cb.addWidget(self.cmd_caption)
        cb.addWidget(self.cmd)
        self.cmd_section = collapsible("Exact builder command (advanced)", cmd_box,
                                       expanded=False)
        lay.addWidget(self.cmd_section)
        # The two ACTIONS stay outside the fold. "Build builder image now" is shown by
        # _on_preflight_done exactly when the docker builder image is missing — i.e. the
        # moment it is the fix for a blocking problem — so burying it inside a
        # collapsed section would hide the remedy along with the argv.
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.build_image_btn = QtWidgets.QPushButton("Build builder image now")
        self.build_image_btn.setVisible(False)
        self.preview_btn.clicked.connect(self._preview)
        self.build_image_btn.clicked.connect(self._build_builder_image)
        bl = QtWidgets.QHBoxLayout(); bl.addWidget(self.preview_btn)
        bl.addWidget(self.build_image_btn); bl.addStretch(1)
        lay.addLayout(bl)
        self.log = console.attach(QtWidgets.QPlainTextEdit()); self.log.setReadOnly(True)
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

        # Selection-changed honesty for the vaulted fields: a USER edit of the path
        # text means any held copy no longer corresponds to the visible selection —
        # drop it (Browse re-holds; typing means plain-path semantics, the
        # pre-existing contract). textEdited fires on user input only, so the
        # programmatic setText in initializePage/_on_device_assignment routes through
        # _refresh_held_labels' origin check instead.
        self.keys_usb.textEdited.connect(lambda _t: self._drop_held("keys_usb"))
        self.secureboot_key.textEdited.connect(
            lambda _t: self._drop_held("secureboot_key"))

    # ---- held-in-memory secret files (core/secret_files.py) ---------------------
    def _held_label(self) -> QtWidgets.QLabel:
        lbl = QtWidgets.QLabel("")
        lbl.setWordWrap(True)
        lbl.setStyleSheet("color: gray;")
        return lbl

    def _vault_picker_row(self, field, line_edit, caption,
                          file_filter="All files (*)", directory=False):
        """_picker_row's vault-aware twin: Browse… ALSO reads the selection's CONTENT
        into the process vault (the 2026-07-29 ask — "once the file is selected its
        held in memory until the build is completed"), so the dispatch consumes the
        in-memory copy and the selection survives the source USB being unplugged."""
        btn = QtWidgets.QPushButton("Browse…")

        def pick():
            if directory:
                p = QtWidgets.QFileDialog.getExistingDirectory(self, caption)
            else:
                p, _sel = QtWidgets.QFileDialog.getOpenFileName(
                    self, caption, "", file_filter)
            if p:
                self._browse_held(field, line_edit, p)
        btn.clicked.connect(pick)
        w = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(line_edit, 1)
        h.addWidget(btn)
        return w

    def _browse_held(self, field: str, line_edit, path: str) -> None:
        """A browse landed: hold the content NOW, then show the path. A refused hold
        (unreadable / oversized / a keys-USB dir carrying no kernel_key.*) falls back
        HONESTLY to today's plain-path semantics with the reason on the row — never a
        silent partial hold."""
        try:
            entry = secret_files.vault().hold(field, path)
        except (OSError, ValueError) as e:
            secret_files.vault().drop(field)
            line_edit.setText(path)
            self._refresh_held_labels(hold_errors={field: str(e)})
            self._preview()
            return
        line_edit.setText(entry.origin)     # abspath — keeps origin == collected cfg path
        self._refresh_held_labels()
        self._preview()

    def _drop_held(self, field: str) -> None:
        if secret_files.vault().drop(field):
            self._refresh_held_labels()

    def _refresh_held_labels(self, hold_errors: dict | None = None) -> None:
        """Sync the two held-status rows with the vault. Origin-pinned: a held copy
        whose origin no longer equals the visible path (a loaded config, a
        device-table Keys-USB assignment) corresponds to nothing on screen — it is
        DROPPED here, mirroring build_driver's consumption rule, so what the row
        says is always what the dispatch will do."""
        v = secret_files.vault()
        for field, edit, lbl in (
                ("keys_usb", self.keys_usb, self.keys_usb_held),
                ("secureboot_key", self.secureboot_key, self.secureboot_key_held)):
            err = (hold_errors or {}).get(field, "")
            text = edit.text().strip()
            held = v.get(field)
            if held is not None and held.origin != text:
                v.drop(field)
                held = None
            if err:
                lbl.setStyleSheet("color: #a65d00;")
                lbl.setText(f"Not held in memory — {err}. The path is passed to the "
                            f"builder as-is and must still exist at dispatch.")
            elif held is not None:
                lbl.setStyleSheet("color: #188038;")
                lbl.setText(held.summary())
            elif text:
                lbl.setStyleSheet("color: gray;")
                lbl.setText("Plain path (typed/loaded) — not held in memory; "
                            "Browse… to hold the file content for this session.")
            else:
                lbl.setText("")

    def initializePage(self):
        self.wiz.collect_all()
        c = self.wiz.cfg
        mesh = c.mode == "mesh"
        # two stats on /proc — no subprocess, never blocks (unlike the docker probe)
        self._cross_dracut_ready = cross_dracut.preflight_ok()
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
        # cached / live-toram / bundle-source are x86 ISO knobs (config.py emits them only
        # through _x86_args). The per-platform gating is NOT done with a hand-written
        # `c.platform in ("", "x86")` any more: they joined the artifact-row gate map
        # below, which HIDES the whole row (checkbox + its "→ artifact" caption) off-x86.
        # Two mechanisms on one widget was a live bug waiting to happen — setEnabled here
        # and setVisible there do not compose into anything a reader can predict.
        self.cached.setChecked(c.cached)
        self.live_toram.setChecked(c.live_toram)
        # bundling the generator source is a builder HARD CONFLICT on an unaffiliated
        # image (the dedicated role OR the composable --unaffiliated flag, G22) —
        # disable + clear the checkbox and show the note (mirroring the BrandingPage
        # pattern), so the wizard can never re-set what RolePage cleared
        # (config.py suppresses the flag pair for unaffiliated as the final guard).
        unaffiliated = c.role == UNAFFILIATED_ROLE or c.unaffiliated
        self.bundle_source.setEnabled(not unaffiliated)   # platform half: the gate map below
        self.bundle_source.setChecked(False if unaffiliated else c.bundle_source)
        self.bundle_note.setVisible(unaffiliated)
        self.compress.setChecked(c.compress)
        self.resume.setChecked(c.resume)
        self.grow.setCurrentText(c.grow)
        self.version.setText(c.version)
        self.release_tag.setText(c.release_tag)
        _set_flag(self.build_img, c.build_img)
        _set_flag(self.live_iso, c.live_iso)
        self.installer_iso.setChecked(c.installer_iso)
        self.build_iso.setChecked(c.build_iso)
        self.sd_only.setChecked(c.sd_only)
        _set_flag(self.build_tar, c.build_tar)
        self.skip_iso.setChecked(c.skip_iso)
        self.image_only.setChecked(c.image_only)
        _set_flag(self.secure_boot, c.secure_boot)
        self.keys_usb.setText(c.keys_usb)
        self.secureboot_key.setText(c.secureboot_key)
        self.secureboot_cert.setText(c.secureboot_cert)
        # held-status rows: vault state may have changed since the last visit (a
        # completed build drops its entries; a loaded config changes the paths, which
        # the refresh's origin check turns into a drop)
        self._refresh_held_labels()
        self.skip_kernel.setChecked(c.skip_kernel)
        self.skip_clean.setChecked(c.skip_clean)
        self.distdir.setText(c.distdir)
        self.build_subdir.setText(c.build_subdir)
        self.seed_url.setText(c.seed_url)
        self.pentest.setChecked(c.pentest)
        self.qemu_e2e.setChecked(c.qemu_e2e)
        self._sync_qemu_e2e_gate()
        # From here on this checkbox is the SOLE writer of cfg.qemu_e2e. QemuPage's radio
        # seeds the field on the way in, but collect_all() re-runs the validatePage of
        # every visited page, so without this latch a revisit of THIS page re-asserted the
        # radio over an opt-out the operator had just made here — and line above then
        # re-ticked the box from it. Latched on the wizard rather than read back from
        # hasVisitedPage(), which back() pops and which therefore silently fails to hold.
        self.wiz.qemu_e2e_owned_by_build = True
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
        #
        # ASK 13 pairing: each artifact row's "→ artifact" caption is gated WITH its
        # checkbox, as one unit. Gating only the box would leave a live caption promising
        # an installer.iso next to a hidden control on a builder that produces none —
        # exactly the orphan-caption bug the NetworkPage egress section already paid for.
        _A = self.artifact_labels
        gate_widgets(c.platform, {
            "release_tag": self.release_tag,
            "build_img": (self.build_img, _A["build_img"]),
            "live_iso": (self.live_iso, _A["live_iso"]),
            "cached": (self.cached, _A["cached"]),
            "live_toram": (self.live_toram, _A["live_toram"]),
            "installer_iso": (self.installer_iso, _A["installer_iso"]),
            "build_iso": (self.build_iso, _A["build_iso"]),
            "sd_only": (self.sd_only, _A["sd_only"]),
            "build_tar": (self.build_tar, _A["build_tar"]),
            "skip_iso": (self.skip_iso, _A["skip_iso"]),
            "image_only": (self.image_only, _A["image_only"]),
            "compress": (self.compress, _A["compress"]),
            "resume": (self.resume, _A["resume"]),
            # bundle_source's ROW is platform-gated here; its UNAFFILIATED half stays a
            # setEnabled above, because that one is a builder HARD CONFLICT the operator
            # must be able to read the reason for (bundle_note) — hiding it would delete
            # the explanation along with the control.
            "bundle_source": (self.bundle_source, _A["bundle_source"]),
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
        # the flag-pair explanation on the live boxes (an unsupported one keeps the
        # platform note the gate set), the NetworkPage restore idiom. secure_boot's gate
        # rides its SECTION, so the box's own tooltip is never blanked — set it anyway so
        # all four stay uniform whatever the gate map becomes.
        for flag_fld, flag_box in (("build_img", self.build_img),
                                   ("live_iso", self.live_iso),
                                   ("build_tar", self.build_tar),
                                   ("secure_boot", self.secure_boot)):
            if platform_supports(flag_fld, c.platform):
                flag_box.setToolTip(_FLAG_TIP)
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
                      "seed_url", "pentest", "qemu_e2e", "extra_flags"))
        self.plumbing_section.set_default_expanded(not plumbing_default)

    def _sync_qemu_e2e_gate(self, *_a):
        """Enable the post-build device tests only for --env test.

        A prod build prunes the in-cluster test runner out of its app tree, so the
        emulated-device assertions would be checking for a stack the build removed on
        purpose. Greying (not hiding) keeps the reason legible: the operator set --env
        one row above and can set it back. Unticking on the way out stops a config
        saved as prod from carrying a flag its own env forbids."""
        is_test = self.env.currentText() == "test"
        self.qemu_e2e.setEnabled(is_test)
        if not is_test:
            self.qemu_e2e.setChecked(False)
        self.qemu_e2e.setToolTip(
            "Boots each image this build produces as an emulated device in Docker and "
            "runs the assertions — Pi roles first, then x86."
            if is_test else
            "Only available for --env test: a prod image has the test runner pruned "
            "from its app tree, so the assertions would check for a stack that was "
            "deliberately removed.")

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
        # flag-pair checkboxes collect through _flag_value — the same 'on'/'off' domain
        # the retired tri-state carried, minus the '' arm the wizard no longer offers
        # (ask 13). The config DOMAIN still accepts '', so a --config JSON or a headless
        # caller that carries it round-trips and emits neither flag exactly as before.
        c.build_img = _flag_value(self.build_img)
        c.live_iso = _flag_value(self.live_iso)
        c.installer_iso = self.installer_iso.isChecked()
        c.build_iso = self.build_iso.isChecked()
        c.sd_only = self.sd_only.isChecked()
        c.build_tar = _flag_value(self.build_tar)
        c.skip_iso = self.skip_iso.isChecked()
        c.image_only = self.image_only.isChecked()
        c.secure_boot = _flag_value(self.secure_boot)
        c.keys_usb = self.keys_usb.text().strip()
        c.secureboot_key = self.secureboot_key.text().strip()
        c.secureboot_cert = self.secureboot_cert.text().strip()
        c.skip_kernel = self.skip_kernel.isChecked()
        c.skip_clean = self.skip_clean.isChecked()
        c.distdir = self.distdir.text().strip()
        c.build_subdir = self.build_subdir.text().strip()
        c.seed_url = self.seed_url.text().strip()
        c.pentest = self.pentest.isChecked()
        # Only a test-env build can carry the post-build device tests (see the gate);
        # collecting the raw checkbox would let a test->prod switch strand a True.
        c.qemu_e2e = self.qemu_e2e.isChecked() and self.env.currentText() == "test"
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
            # so a standalone frite/orangepi5/orangepizero2[w]/orangepizero3/orangepi3-lts with an unset flavor builds a
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
            self._set_cmd_caption("")
            self.summary.setText(f"Cannot assemble this build: {e}")
            self.log.setPlainText(f"Command error: {e}")
            self._set_problems([str(e)])
            return
        self.cmd.setPlainText(cmdline)
        # This render is the WHOLE config's argv, so any per-entry caption a worklist
        # Preview left behind is now false and goes with it.
        self._set_cmd_caption("")
        self._refresh_summary()
        # The command pane above updated INSTANTLY (pure argv assembly, no daemon).
        # The AGGREGATE preflight + builder-image probe are the two docker subprocess
        # calls that used to freeze the wizard + tray here — kick them off-thread.
        self._schedule_recompute()

    # ---- ask 22: the plain-language review ------------------------------------
    def review_summary(self) -> str:
        """What this build will produce, in words — the review the page is named for.

        Every line is read off the SAME committed state the command pane renders from
        (``_current_worklist`` / ``cfg``), so it can never describe a different build
        than the one Continue dispatches. Pure: no widget writes, no disk, no probes."""
        c = self.wiz.cfg
        try:
            wl = self._current_worklist()
            entries = list(wl.entries)
        except Exception:                      # a config that cannot even synthesize
            entries = []
        images = ", ".join(e.id for e in entries) or f"{c.role or 'image'}.{c.platform}"
        out = c.output_dir.strip() or os.path.join(self.wiz.generator_dir, "out")
        backend = self._backend() or self.wiz.host.default_backend
        lines = [
            f"Building {len(entries) or 1} image(s): {images}",
            f"Into: {out}",
            f"With: {backend} backend, --env {self.env.currentText()}, "
            f"{self.jobs.value()} parallel jobs",
        ]
        # The artifact set, named rather than implied by the boxes. Reads _flag_value,
        # not the tri-state accessor this summary was first written against: ask 13 made
        # these boxes two-state, so '' is no longer reachable and every box now
        # contributes a definite phrase.
        arts = []
        for box, name in ((self.build_img, "disk image"), (self.live_iso, "live ISO"),
                          (self.build_tar, "rootfs tarball")):
            state = _flag_value(box)
            if state == "on":
                arts.append(name)
            elif state == "off":
                arts.append(f"no {name}")
        if self.installer_iso.isChecked():
            arts.append("installer ISO")
        if c.encrypt_root:
            # ask 21's consequence, stated where the operator is deciding to proceed
            arts.append("LUKS2-encrypted root (always on; x86 also yields an installer ISO)")
        if arts:
            lines.append("Artifacts: " + ", ".join(arts))
        else:
            lines.append("Artifacts: the builder's own defaults for each image")
        # ask 21's OTHER consequence: on a cross-built ARM row --encrypt-root forces the
        # installer artifact AND gates the whole build behind the arm64 cross-dracut
        # preflight, which exits 1 before any work happens. Named per affected row, and
        # only when a row is actually affected — see core/cross_dracut.py. Reads the
        # SAME per-entry resolution the driver will apply (worklist.resolve_encrypt_root
        # against this page's committed cfg, which _current_worklist just pinned as
        # wl.base), so the warning can never describe a different set than the argv.
        cross = cross_dracut.cross_fde_note(
            cross_dracut.cross_fde_rows(
                [(e.id, e.platform,
                  worklist_mod.resolve_encrypt_root(e, c.encrypt_root)) for e in entries]),
            self._cross_dracut_ready)
        if cross:
            lines.append(cross)
        if c.mode == "mesh":
            lines.append("Node key folders: "
                         + ("generated beside each node image"
                            if self.gen_keys.isChecked() else "NOT generated"))
        return "\n".join(lines)

    def _refresh_summary(self) -> None:
        self.summary.setText(self.review_summary())

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
        # setText above is programmatic (no textEdited): the refresh's origin check
        # is what drops a held copy the assignment just displaced. A device-table
        # assignment is deliberately NOT auto-held — the device is a live mounted
        # USB chosen for flashing, and holding is the Browse gesture's contract.
        self._refresh_held_labels()

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
            prev_btn.setToolTip("Show this image's exact builder command in the "
                                "'Exact builder command' pane below.")
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
        """Render ONE worklist row's builder command into the command pane — and REVEAL it.

        The button was reported as "doing nothing". It was in fact wired and correct: it
        has always written that row's real argv into ``self.cmd``. What it never did was
        make that observable. ``self.cmd`` lives in the "Exact builder command (advanced)"
        section, which ask 22 folded BY DEFAULT and which sits ~1100px below the worklist
        on a page whose viewport is ~600px tall — so every click landed in a collapsed,
        off-screen pane. Wiring is not the same thing as feedback: expand the section,
        scroll it into view, and caption it with the row's id.
        """
        if self._wl_driver is None or idx >= len(self._materialized):
            return
        entry, mcfg = self._materialized[idx]
        try:
            self.cmd.setPlainText(self._wl_driver.command_string(mcfg))
        except ValueError as e:
            self.cmd.setPlainText(f"Command error: {e}")
        self._set_cmd_caption(
            f"Showing the builder command for worklist image {entry.id}. "
            "Editing any option below re-renders this pane for the whole build.")
        self._reveal_cmd_pane()

    def _set_cmd_caption(self, text: str) -> None:
        """Caption the argv pane, or clear it when empty. It names WHOSE command is on
        screen, so every whole-config render must clear it: a caption still claiming
        "be.rpi5" over a cfg-wide argv is a worse lie than no caption at all."""
        self.cmd_caption.setText(text)
        self.cmd_caption.setVisible(bool(text))

    def _reveal_cmd_pane(self) -> None:
        """Open the folded argv section and scroll to it.

        ``set_expanded`` and not ``set_default_expanded``: the latter defers to a fold the
        operator made by hand, which is right for a page re-deriving its own defaults and
        wrong here — this IS a direct operator action, and the section is the answer to
        it. They can fold it again, and the next visit re-folds it as ask 22 intends."""
        self.cmd_section.set_expanded(True)
        reveal(self, self.cmd_section)

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
        console.write(self.log, "\n=== building the docker builder image ===")
        self.image_worker = _BuilderImageWorker(self.wiz.driver)
        self.image_worker.line.connect(lambda s: console.write(self.log, s))
        self.image_worker.done.connect(self._builder_image_finished)
        self.image_worker.start()

    def _builder_image_finished(self, code):
        console.write(self.log, f"=== builder image build exited {code} ===")
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
        # Refuse an explicit root size below the builder's own derived payload
        # floor (core/root_size_floor.py mirrors the builder tables) — otherwise
        # the doom lands hours later in the .img pre-flight ("Payload NNNN MiB
        # exceeds the ... root partition"). 0 = role default, always accepted;
        # experts can still pass --img-size via Extra builder flags.
        c = self.wiz.cfg
        self.img_size_err.setVisible(False)
        if c.img_size:
            for entry in self.wiz.worklist.entries:
                err = root_size_floor.img_size_error(
                    entry.platform, c.mode, entry.role, c.img_size,
                    desktop=entry.desktop or c.desktop, capable=bool(c.capable))
                if err:
                    self.img_size_err.setText(err)
                    self.img_size_err.setVisible(True)
                    return False
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
