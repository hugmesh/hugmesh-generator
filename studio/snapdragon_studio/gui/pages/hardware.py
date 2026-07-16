"""HardwarePage — the this-machine scan and the GPU/radio/kernel TUNING knobs.

The machine-defining PROFILE PRESET moved to the RolePage's x86 machine card (spec fold
2): the target machine is chosen in ONE place. The GPU/Wi-Fi/Bluetooth/kernel controls
here are TUNING (the profile only pre-fills them), and the this-machine scan stays."""
from __future__ import annotations

from ..qt import QtWidgets
from ...core import hw_scan
from ...core.config import GPU_DRIVER_ALIASES, GPU_DRIVER_CHOICES
from ._gating import clear_unsupported, gate_widgets
from ._widgets import _row


class HardwarePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Target hardware")
        self.setSubTitle("Tune the GPU, Wi-Fi/Bluetooth and kernel for the target — "
                         "or scan this machine to autofill them. The machine profile "
                         "preset is chosen with the machine on the earlier step.")
        lay = QtWidgets.QVBoxLayout(self)

        self.scan_btn = QtWidgets.QPushButton("Scan THIS machine")
        self.scan_btn.clicked.connect(self._scan)
        lay.addWidget(self.scan_btn)
        self.scan_out = QtWidgets.QLabel("")
        self.scan_out.setWordWrap(True)
        self.scan_out.setStyleSheet("color: #3f5b8c;")
        lay.addWidget(self.scan_out)

        # the builder's FULL documented --gpu-driver matrix (canonical names; the
        # builder's vendor aliases like "intel" are normalized via _set_gpu below)
        self.gpu = QtWidgets.QComboBox()
        self.gpu.addItems(list(GPU_DRIVER_CHOICES))
        lay.addWidget(_row("GPU driver", self.gpu))
        # --nvidia-cuda (G33): CUDA bake for GPU/edge-AI images. The builder
        # hard-errors unless --gpu-driver nvidia (the proprietary driver) — its
        # check is the authoritative safety net, same as every other combo rule.
        self.nvidia_cuda = QtWidgets.QCheckBox(
            "Bake the CUDA toolkit (--nvidia-cuda — requires GPU driver 'nvidia', the proprietary one)")
        lay.addWidget(self.nvidia_cuda)
        self.wifi = QtWidgets.QCheckBox("Enable Wi-Fi (off by default — hardened)")
        self.bt = QtWidgets.QCheckBox("Enable Bluetooth (off by default — hardened)")
        self.builtin = QtWidgets.QCheckBox("Compile most everything into the kernel (built-in, not modules)")
        lay.addWidget(self.wifi)
        lay.addWidget(self.bt)
        lay.addWidget(self.builtin)
        # ARM kernel/board overrides (G37) — per-field gated below: -c/-d are
        # all-ARM, --dtb is frite/jetson/orangepi*, --dtb-prefix/--kernel-img/
        # --pcie-gen3 are rpi5-family; the whole box hides on x86.
        self.arm_box = QtWidgets.QGroupBox("ARM kernel/board overrides (advanced)")
        al = QtWidgets.QVBoxLayout(self.arm_box)
        self.cpu = QtWidgets.QLineEdit()
        self.cpu.setPlaceholderText("-c/--cpu kernel/toolchain CPU (empty = builder default)")
        self.defconfig = QtWidgets.QLineEdit()
        self.defconfig.setPlaceholderText("-d/--defconfig kernel defconfig (empty = builder default)")
        self.dtb = QtWidgets.QLineEdit()
        self.dtb.setPlaceholderText("--dtb device-tree blob (frite/jetson/orangepi*)")
        self.dtb_prefix = QtWidgets.QLineEdit()
        self.dtb_prefix.setPlaceholderText("--dtb-prefix (rpi5 family)")
        self.kernel_img = QtWidgets.QLineEdit()
        self.kernel_img.setPlaceholderText("--kernel-img e.g. kernel_2712.img (rpi5 family)")
        self.pcie_gen3 = QtWidgets.QCheckBox(
            "PCIe Gen3 (--pcie-gen3 — Pi 5 NVMe; the builder warns+ignores it on rpi4/rpi3 boards)")
        al.addWidget(_row("CPU", self.cpu))
        al.addWidget(_row("Defconfig", self.defconfig))
        al.addWidget(_row("DTB", self.dtb))
        al.addWidget(_row("DTB prefix", self.dtb_prefix))
        al.addWidget(_row("Kernel image", self.kernel_img))
        al.addWidget(self.pcie_gen3)
        lay.addWidget(self.arm_box)
        lay.addStretch(1)

    def _set_gpu(self, value):
        """Select a combo entry; builder vendor aliases (hwprofiles say 'intel')
        normalize to the canonical id so they can't silently fail to match."""
        self.gpu.setCurrentText(GPU_DRIVER_ALIASES.get(value, value) or "auto")

    def _scan(self):
        s = hw_scan.scan()
        self._set_gpu(s.recommended_gpu_driver)
        self.wifi.setChecked(s.recommend_wifi)
        self.bt.setChecked(s.recommend_bluetooth)
        gpus = ", ".join(g.name for g in s.gpus) or "none"
        self.scan_out.setText(f"CPU: {s.cpu or '?'}  ·  GPU: {gpus}  ·  "
                              f"recommended driver: {s.recommended_gpu_driver}"
                              + (f"  ·  Wi-Fi: {s.wifi}" if s.wifi else ""))

    def initializePage(self):
        c = self.wiz.cfg
        self._set_gpu(c.gpu_driver)
        self.nvidia_cuda.setChecked(c.nvidia_cuda)
        self.wifi.setChecked(c.enable_wifi)
        self.bt.setChecked(c.enable_bluetooth)
        self.builtin.setChecked(c.kernel_builtin)
        self.cpu.setText(c.cpu)
        self.defconfig.setText(c.defconfig)
        self.dtb.setText(c.dtb)
        self.dtb_prefix.setText(c.dtb_prefix)
        self.kernel_img.setText(c.kernel_img)
        self.pcie_gen3.setChecked(c.pcie_gen3)
        # the ARM overrides box has nothing an x86 build can use — hide it whole
        # (the per-field gating below still greys the wrong-ARM fields inside it)
        self.arm_box.setVisible(c.platform not in ("", "x86"))
        # --gpu-driver/--nvidia-cuda/--kernel-builtin are x86-only flags (no ARM
        # builder parses them) — grey per platform instead of silently dropping the
        # value (G10); the ARM kernel/board overrides gate the opposite way (G37).
        # Wi-Fi/Bluetooth (and the profile presets that seed them) are all-platform.
        gate_widgets(c.platform, {"gpu_driver": self.gpu,
                                  "nvidia_cuda": self.nvidia_cuda,
                                  "kernel_builtin": self.builtin,
                                  "cpu": self.cpu,
                                  "defconfig": self.defconfig,
                                  "dtb": self.dtb,
                                  "dtb_prefix": self.dtb_prefix,
                                  "kernel_img": self.kernel_img,
                                  "pcie_gen3": self.pcie_gen3})

    def validatePage(self):
        c = self.wiz.cfg
        c.gpu_driver = self.gpu.currentText()
        c.nvidia_cuda = self.nvidia_cuda.isChecked()
        c.enable_wifi = self.wifi.isChecked()
        c.enable_bluetooth = self.bt.isChecked()
        c.kernel_builtin = self.builtin.isChecked()
        # hw_profile is set on the RolePage (the machine card owns the profile preset);
        # HardwarePage no longer touches it, so a revisit here cannot clobber it back to "".
        c.cpu = self.cpu.text().strip()
        c.defconfig = self.defconfig.text().strip()
        c.dtb = self.dtb.text().strip()
        c.dtb_prefix = self.dtb_prefix.text().strip()
        c.kernel_img = self.kernel_img.text().strip()
        c.pcie_gen3 = self.pcie_gen3.isChecked()
        # greyed platform-unsupported fields (see initializePage) reset to their
        # defaults so a choice made on another platform can't linger into this build.
        clear_unsupported(c, ("gpu_driver", "nvidia_cuda", "kernel_builtin",
                              "cpu", "defconfig", "dtb", "dtb_prefix",
                              "kernel_img", "pcie_gen3"))
        return True
