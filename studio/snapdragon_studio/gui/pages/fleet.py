"""FleetPage — the multi-role fan-out channel (G39): a Studio front-end for
scripts/build-all-roles.sh's fleet targets (the menu's build-all / build-everything /
rpi / x86) and their env knobs (X86_OMNIBUS / X86_STANDALONE / RPI_ROLES / FRITE=1 /
JETSON=1 / ORANGEPI5=1 / ORANGEPIZERO2=1 / PENTEST=1 / SKIP_KEYS=1 / …).

Deliberately SELF-CONTAINED (like golive.py): ``FleetDialog(generator_dir).exec()``
works without any wizard-page registration, so the single-image wizard's page
registry (gui/wizard.py) does not need to know about the fleet channel to ship it.
All option logic lives Qt-free in core.fleet (FleetConfig/FleetDriver) — this
module only collects widgets into a FleetConfig and streams the run.
"""
from __future__ import annotations

from ..qt import QtCore, QtWidgets, Signal
from ...core.config import (
    ENV_CHOICES, FRITE_BOARDS, FRITE_DESKTOPS, FRITE_FLAVORS, JETSON_BOARDS,
    KERNEL_FLAVOR_CHOICES, ORANGEPI5_BOARDS, ORANGEPI5_FLAVORS,
    ORANGEPIZERO2_FLAVORS, RPI_BOARDS,
)
from ...core.fleet import FleetConfig, FleetDriver
from ._widgets import _file_picker, _row


class _FleetWorker(QtCore.QThread):
    """Runs FleetDriver.run() off the GUI thread (mirrors build.py's _BuildWorker)."""
    line = Signal(str)
    done = Signal(int)

    def __init__(self, driver, cfg, backend):
        super().__init__()
        self.driver, self.cfg, self.backend = driver, cfg, backend

    def run(self):
        code = self.driver.run(self.cfg, self.backend, on_line=lambda s: self.line.emit(s))
        self.done.emit(code)


def _default_combo(choices, tooltip=""):
    """A combo whose FIRST entry is the script-default sentinel '' (shown as
    '(default)') — mirrors ImageConfig's only-non-defaults emission rule."""
    c = QtWidgets.QComboBox()
    c.addItem("(default)", "")
    for x in choices:
        c.addItem(x, x)
    if tooltip:
        c.setToolTip(tooltip)
    return c


class FleetPage(QtWidgets.QWidget):
    """Widget collecting one FleetConfig; host it in FleetDialog or any container."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.generator_dir = generator_dir
        self.driver = FleetDriver(generator_dir)
        self.worker = None
        outer = QtWidgets.QVBoxLayout(self)

        # ── x86 + rpi5 role sets ──
        roles = QtWidgets.QGroupBox("Role sets (default fleet: rpi5 pki/backend/frontend + x86 pki/be/fe/be+gpu)")
        rl = QtWidgets.QVBoxLayout(roles)
        self.skip_x86 = QtWidgets.QCheckBox("Skip x86 entirely (SKIP_X86=1)")
        self.x86_omnibus = QtWidgets.QCheckBox("Append the x86 omnibus all-in-one role (X86_OMNIBUS=1)")
        self.x86_all = QtWidgets.QCheckBox("Every x86 role incl. omnibus (X86_ALL=1)")
        self.x86_standalone = QtWidgets.QCheckBox(
            "Append the x86 standalone desktops — thin + thick + unaffiliated (X86_STANDALONE=1)")
        self.x86_standalone_only = QtWidgets.QCheckBox(
            "ONLY the x86 standalone desktops (X86_STANDALONE_ONLY=1 — skips the cluster roles)")
        for w in (self.skip_x86, self.x86_omnibus, self.x86_all,
                  self.x86_standalone, self.x86_standalone_only):
            rl.addWidget(w)
        self.x86_roles = QtWidgets.QLineEdit()
        self.x86_roles.setPlaceholderText("explicit x86 subset, space-separated (X86_ROLES=\"pki omnibus\")")
        rl.addWidget(_row("x86 roles", self.x86_roles))
        self.skip_rpi = QtWidgets.QCheckBox("Skip the Raspberry Pi roles (SKIP_RPI=1)")
        rl.addWidget(self.skip_rpi)
        self.rpi_roles = QtWidgets.QLineEdit()
        self.rpi_roles.setPlaceholderText(
            "RPi role subset (RPI_ROLES=\"pki backend frontend desktop\"; desktop is opt-in)")
        rl.addWidget(_row("RPi roles", self.rpi_roles))
        self.rpi_board = _default_combo(
            RPI_BOARDS, "RPI_BOARD — rpi3 is DESKTOP-ONLY (pair with RPI_ROLES=desktop)")
        rl.addWidget(_row("RPi board", self.rpi_board))
        outer.addWidget(roles)

        # ── opt-in ARM client/edge platforms ──
        optin = QtWidgets.QGroupBox("Opt-in platforms (each mirrors the FRITE=1 knob family)")
        ol = QtWidgets.QVBoxLayout(optin)
        self.frite = QtWidgets.QCheckBox("La/Le Frite light desktop (FRITE=1)")
        self.frite_only = QtWidgets.QCheckBox("ONLY the Frite (FRITE_ONLY=1)")
        self.frite_board = _default_combo(FRITE_BOARDS)
        self.frite_flavor = _default_combo(FRITE_FLAVORS)
        self.frite_desktop = _default_combo(FRITE_DESKTOPS)
        ol.addWidget(self.frite); ol.addWidget(self.frite_only)
        ol.addWidget(_row("Frite board", self.frite_board))
        ol.addWidget(_row("Frite flavor", self.frite_flavor))
        ol.addWidget(_row("Frite desktop", self.frite_desktop))
        self.jetson = QtWidgets.QCheckBox("Jetson Orin edge-AI (JETSON=1 — EXPERIMENTAL)")
        self.jetson_only = QtWidgets.QCheckBox("ONLY the Jetson (JETSON_ONLY=1)")
        self.jetson_roles = QtWidgets.QLineEdit()
        self.jetson_roles.setPlaceholderText("JETSON_ROLES subset (default: edge_ai)")
        self.jetson_board = _default_combo(JETSON_BOARDS)
        self.jetson_kernel_flavor = _default_combo(
            KERNEL_FLAVOR_CHOICES, "JETSON_KERNEL_FLAVOR — the l4t BUILD is a stub that hard-errors today")
        ol.addWidget(self.jetson); ol.addWidget(self.jetson_only)
        ol.addWidget(_row("Jetson roles", self.jetson_roles))
        ol.addWidget(_row("Jetson board", self.jetson_board))
        ol.addWidget(_row("Jetson kernel", self.jetson_kernel_flavor))
        self.orangepi5 = QtWidgets.QCheckBox("Orange Pi 5 / 5 Plus (ORANGEPI5=1 — EXPERIMENTAL)")
        self.orangepi5_only = QtWidgets.QCheckBox("ONLY the Orange Pi 5 (ORANGEPI5_ONLY=1)")
        self.orangepi5_board = _default_combo(ORANGEPI5_BOARDS)
        self.orangepi5_flavor = _default_combo(ORANGEPI5_FLAVORS)
        ol.addWidget(self.orangepi5); ol.addWidget(self.orangepi5_only)
        ol.addWidget(_row("OPi5 board", self.orangepi5_board))
        ol.addWidget(_row("OPi5 flavor", self.orangepi5_flavor))
        self.orangepizero2 = QtWidgets.QCheckBox(
            "Orange Pi Zero 2 headless appliance (ORANGEPIZERO2=1 — EXPERIMENTAL)")
        self.orangepizero2_only = QtWidgets.QCheckBox("ONLY the Zero 2 (ORANGEPIZERO2_ONLY=1)")
        self.orangepizero2_flavor = _default_combo(ORANGEPIZERO2_FLAVORS)
        ol.addWidget(self.orangepizero2); ol.addWidget(self.orangepizero2_only)
        ol.addWidget(_row("OPZ2 flavor", self.orangepizero2_flavor))
        outer.addWidget(optin)

        # ── keys + pen-test + shared pass-through ──
        shared = QtWidgets.QGroupBox("Fleet-wide")
        sl = QtWidgets.QVBoxLayout(shared)
        self.skip_keys = QtWidgets.QCheckBox(
            "Skip the per-role KEYS folder generation (SKIP_KEYS=1 — folders are the default)")
        self.pentest = QtWidgets.QCheckBox("Run the OWASP pen-test harness after the build (PENTEST=1)")
        self.pentest_only = QtWidgets.QCheckBox("Pen-test ONLY, no image builds (PENTEST_ONLY=1)")
        sl.addWidget(self.skip_keys); sl.addWidget(self.pentest); sl.addWidget(self.pentest_only)
        self.pentest_env = _default_combo(("compose", "local", "cluster"))
        self.pentest_scan = _default_combo(("baseline", "full"))
        self.pentest_pipeline = _default_combo(("main", "games"))
        sl.addWidget(_row("Pen-test env", self.pentest_env))
        sl.addWidget(_row("Pen-test scan", self.pentest_scan))
        sl.addWidget(_row("Pen-test pipeline", self.pentest_pipeline))
        self.env = _default_combo(ENV_CHOICES, "--env forwarded to every builder (default test)")
        sl.addWidget(_row("Build env", self.env))
        self.brand_profile = QtWidgets.QLineEdit()
        bp_btn = _file_picker(self, self.brand_profile, "Brand profile", "Brand profile (*.conf)")
        bp = QtWidgets.QWidget(); bh = QtWidgets.QHBoxLayout(bp); bh.setContentsMargins(0, 0, 0, 0)
        bh.addWidget(self.brand_profile, 1); bh.addWidget(bp_btn)
        sl.addWidget(_row("Brand profile", bp))
        self.cluster_domain = QtWidgets.QLineEdit()
        self.cluster_domain.setPlaceholderText("--cluster-domain forwarded to every builder")
        sl.addWidget(_row("Cluster domain", self.cluster_domain))
        self.headscale_url = QtWidgets.QLineEdit()
        self.headscale_url.setPlaceholderText(
            "brand mesh control server (HEADSCALE_URL env — baked to /etc/snapdragon/headscale-url)")
        sl.addWidget(_row("Headscale URL", self.headscale_url))
        self.output_dir = QtWidgets.QLineEdit()
        od_btn = _file_picker(self, self.output_dir, "Output directory", directory=True)
        od = QtWidgets.QWidget(); oh = QtWidgets.QHBoxLayout(od); oh.setContentsMargins(0, 0, 0, 0)
        oh.addWidget(self.output_dir, 1); oh.addWidget(od_btn)
        sl.addWidget(_row("Output dir", od))
        self.jobs = QtWidgets.QSpinBox(); self.jobs.setRange(1, 128); self.jobs.setValue(8)
        sl.addWidget(_row("Jobs", self.jobs))
        self.backend = QtWidgets.QComboBox(); self.backend.addItems(["auto", "native", "docker"])
        sl.addWidget(_row("Backend", self.backend))
        self.extra_flags = QtWidgets.QLineEdit()
        self.extra_flags.setPlaceholderText("extra pass-through builder flags, appended verbatim")
        sl.addWidget(_row("Extra flags", self.extra_flags))
        outer.addWidget(shared)

        # ── preview + run ──
        self.cmd = QtWidgets.QPlainTextEdit(); self.cmd.setReadOnly(True); self.cmd.setMaximumHeight(100)
        outer.addWidget(QtWidgets.QLabel("Command:")); outer.addWidget(self.cmd)
        self.preview_btn = QtWidgets.QPushButton("Refresh preview")
        self.start_btn = QtWidgets.QPushButton("Build fleet now")
        self.stop_btn = QtWidgets.QPushButton("Stop"); self.stop_btn.setEnabled(False)
        self.preview_btn.clicked.connect(self.refresh_preview)
        self.start_btn.clicked.connect(self._start)
        self.stop_btn.clicked.connect(self._stop)
        bl = QtWidgets.QHBoxLayout()
        bl.addWidget(self.preview_btn); bl.addWidget(self.start_btn); bl.addWidget(self.stop_btn)
        bl.addStretch(1)
        outer.addLayout(bl)
        self.log = QtWidgets.QPlainTextEdit(); self.log.setReadOnly(True)
        outer.addWidget(self.log, 1)

    # ---- widget -> FleetConfig collection (the page's whole contract) --------
    def collect(self) -> FleetConfig:
        return FleetConfig(
            skip_x86=self.skip_x86.isChecked(),
            x86_omnibus=self.x86_omnibus.isChecked(),
            x86_all=self.x86_all.isChecked(),
            x86_roles=self.x86_roles.text().strip(),
            x86_standalone=self.x86_standalone.isChecked(),
            x86_standalone_only=self.x86_standalone_only.isChecked(),
            skip_rpi=self.skip_rpi.isChecked(),
            rpi_roles=self.rpi_roles.text().strip(),
            rpi_board=self.rpi_board.currentData(),
            frite=self.frite.isChecked(), frite_only=self.frite_only.isChecked(),
            frite_board=self.frite_board.currentData(),
            frite_flavor=self.frite_flavor.currentData(),
            frite_desktop=self.frite_desktop.currentData(),
            jetson=self.jetson.isChecked(), jetson_only=self.jetson_only.isChecked(),
            jetson_roles=self.jetson_roles.text().strip(),
            jetson_board=self.jetson_board.currentData(),
            jetson_kernel_flavor=self.jetson_kernel_flavor.currentData(),
            orangepi5=self.orangepi5.isChecked(),
            orangepi5_only=self.orangepi5_only.isChecked(),
            orangepi5_board=self.orangepi5_board.currentData(),
            orangepi5_flavor=self.orangepi5_flavor.currentData(),
            orangepizero2=self.orangepizero2.isChecked(),
            orangepizero2_only=self.orangepizero2_only.isChecked(),
            orangepizero2_flavor=self.orangepizero2_flavor.currentData(),
            skip_keys=self.skip_keys.isChecked(),
            pentest=self.pentest.isChecked(), pentest_only=self.pentest_only.isChecked(),
            pentest_env=self.pentest_env.currentData(),
            pentest_scan=self.pentest_scan.currentData(),
            pentest_pipeline=self.pentest_pipeline.currentData(),
            headscale_url=self.headscale_url.text().strip(),
            env=self.env.currentData(),
            brand_profile=self.brand_profile.text().strip(),
            cluster_domain=self.cluster_domain.text().strip(),
            output_dir=self.output_dir.text().strip(),
            jobs=self.jobs.value(),
            extra_flags=self.extra_flags.text().strip(),
        )

    def _backend(self):
        b = self.backend.currentText()
        return None if b == "auto" else b

    def refresh_preview(self):
        try:
            cfg = self.collect()
            self.cmd.setPlainText(self.driver.command_string(cfg, self._backend()))
        except Exception as e:  # IdentityValidationError etc. — show, never crash
            self.cmd.setPlainText(f"INVALID: {e}")
            return
        problems = self.driver.preflight(cfg, self._backend())
        if problems:
            self.log.setPlainText("Preflight:\n" + "\n".join(f"  - {p}" for p in problems))

    def _start(self):
        try:
            cfg = self.collect()
        except Exception as e:
            self.log.appendPlainText(f"INVALID: {e}")
            return
        problems = self.driver.preflight(cfg, self._backend())
        if problems:
            self.log.setPlainText("Preflight FAILED:\n" + "\n".join(f"  - {p}" for p in problems))
            return
        self.refresh_preview()
        self.start_btn.setEnabled(False); self.stop_btn.setEnabled(True)
        self.worker = _FleetWorker(self.driver, cfg, self._backend())
        self.worker.line.connect(self.log.appendPlainText)
        self.worker.done.connect(self._done)
        self.worker.start()

    def _stop(self):
        self.driver.cancel()

    def _done(self, code):
        self.start_btn.setEnabled(True); self.stop_btn.setEnabled(False)
        self.log.appendPlainText(f"\n[fleet] exited with code {code}")


class FleetDialog(QtWidgets.QDialog):
    """Standalone host: FleetDialog(generator_dir).exec() — no wizard needed."""

    def __init__(self, generator_dir: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Snapdragon fleet build (build-all-roles)")
        lay = QtWidgets.QVBoxLayout(self)
        scroll = QtWidgets.QScrollArea(); scroll.setWidgetResizable(True)
        self.page = FleetPage(generator_dir)
        scroll.setWidget(self.page)
        lay.addWidget(scroll)
        self.resize(760, 900)
        self.page.refresh_preview()
