"""The Resource limits dialog — how much of this machine the mesh may use.

Reached from the tray, because that is where the setting matters: the tray is what
somebody has running on their desktop while they use the machine for something else,
and "the mesh made my laptop unusable" is the failure this exists to prevent.

The Qt here is deliberately thin. Every decision — the auto formula, the three-way
knob contract, precedence between an env override and a saved setting, what a limit
renders as in each lane — lives in :mod:`hugmesh_studio.core.resource_limits`, which
is Qt-free and directly tested. This file only collects numbers and shows what they
will mean.

NO MODAL IN PAGE LOGIC. This is a tray-invoked settings dialog, not a wizard page:
it is never opened from ``validatePage`` or an ``itemChanged`` handler, which is where
a modal deadlocks the headless tests. :func:`limits_summary` and
:func:`describe_effect` are pure and are what the tests drive.
"""
from __future__ import annotations

import os

from .qt import Qt, QtCore, QtWidgets
from ..core import resource_limits as rl
from ..core import stack_limits as sl

#: Shown when the operator has picked "no limit" on the CPU slider.
UNLIMITED_LABEL = "No limit"


def limits_summary(limits: rl.ResourceLimits) -> str:
    """The one-line status the tray tooltip and the dialog header both show."""
    if limits.is_unlimited():
        return "No limits — the mesh may use the whole machine."
    return f"Limited to {limits.describe()}."


def describe_effect(limits: rl.ResourceLimits, *, service_count: int = 0) -> list[str]:
    """Per-lane, plain-language statements of what these limits will actually do.

    A settings dialog that shows only numbers makes the operator guess which lanes
    honour them. The five lanes deliver limits by five different mechanisms and two of
    them (compose, QEMU) transform the number, so the dialog states the transformed
    value rather than repeating the input back.
    """
    if limits.is_unlimited():
        return ["Builds, the local stack and emulated meshes run unbounded, "
                "as they did before limits existed."]

    out: list[str] = []

    if limits.cpus is not None or limits.memory is not None:
        flags = " ".join(rl.docker_run_args(limits))
        out.append(f"Image and fleet builds run with: {flags}")

    if service_count and limits.cpus is not None:
        per_cpu = sl.per_service_cpus(limits.cpus, service_count)
        per_mem = sl.per_service_memory(limits.memory, service_count) if limits.memory else None
        detail = f"{per_cpu:g} CPU"
        if per_mem:
            detail += f" and {per_mem} of memory"
        else:
            detail += " (memory left unlimited — the share would be too small to start a service)"
        out.append(f"Each of the {service_count} local-stack services is capped at {detail}.")

    smp = rl.qemu_smp(limits)
    if smp is not None:
        out.append(f"Emulated devices boot with {smp} vCPU{'s' if smp != 1 else ''} each.")

    if limits.gpus:
        out.append(f"Containers are offered GPU: {limits.gpus}.")
    else:
        out.append("No lane is given GPU access.")

    return out


class LimitsDialog(QtWidgets.QDialog):
    """Collect a :class:`~hugmesh_studio.core.resource_limits.ResourceLimits`."""

    def __init__(self, parent=None, *, generator_dir: str = "",
                 settings_path: str | None = None):
        super().__init__(parent)
        self.setWindowTitle("HugMesh — resource limits")
        self._settings_path = settings_path
        self._service_count = _stack_service_count(generator_dir)
        self._cores = os.cpu_count() or 2

        current = rl.effective(path=settings_path)
        env_pinned = _env_pinned()

        layout = QtWidgets.QVBoxLayout(self)

        blurb = QtWidgets.QLabel(
            "How much of this machine HugMesh may use while it runs in the background. "
            "These apply to image builds, the local Docker stack, emulated meshes and "
            "Kubernetes nodes started from this Studio.")
        blurb.setWordWrap(True)
        layout.addWidget(blurb)

        form = QtWidgets.QFormLayout()

        # CPU: a spin box over whole/half cores, with 0 meaning "no limit". A slider
        # would look nicer and would make it impossible to type an exact number,
        # which is the thing an operator tuning a build host actually wants to do.
        self.cpu_spin = QtWidgets.QDoubleSpinBox()
        self.cpu_spin.setDecimals(1)
        self.cpu_spin.setSingleStep(0.5)
        self.cpu_spin.setRange(0.0, float(self._cores))
        self.cpu_spin.setSpecialValueText(UNLIMITED_LABEL)   # shown at the 0.0 minimum
        self.cpu_spin.setValue(current.cpus or 0.0)
        self.cpu_spin.setSuffix(f" of {self._cores} cores")
        form.addRow("CPU", self.cpu_spin)

        self.mem_edit = QtWidgets.QLineEdit(current.memory or "")
        self.mem_edit.setPlaceholderText("e.g. 16g — leave empty for no limit")
        form.addRow("Memory", self.mem_edit)

        self.gpu_edit = QtWidgets.QLineEdit(current.gpus or "")
        self.gpu_edit.setPlaceholderText("empty = no GPU · all · device=0")
        form.addRow("GPU", self.gpu_edit)

        layout.addLayout(form)

        # Inline, never a message box: the no-modals rule, and an explanation the
        # operator can read while still editing the value it describes.
        self.effect = QtWidgets.QLabel()
        self.effect.setWordWrap(True)
        self.effect.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.effect)

        self.warning = QtWidgets.QLabel()
        self.warning.setWordWrap(True)
        self.warning.setStyleSheet("color: #b26a00;")
        self.warning.setVisible(False)
        layout.addWidget(self.warning)

        if env_pinned:
            pinned = QtWidgets.QLabel(
                "Note: " + ", ".join(env_pinned) + " is set in the environment and "
                "overrides whatever is saved here, for as long as it is set.")
            pinned.setWordWrap(True)
            pinned.setStyleSheet("color: #b26a00;")
            layout.addWidget(pinned)

        buttons = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.StandardButton.Save
            | QtWidgets.QDialogButtonBox.StandardButton.Cancel)
        reset = buttons.addButton("Recommended for this machine",
                                  QtWidgets.QDialogButtonBox.ButtonRole.ResetRole)
        reset.clicked.connect(self._apply_recommended)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

        for widget in (self.cpu_spin,):
            widget.valueChanged.connect(self._refresh)
        for widget in (self.mem_edit, self.gpu_edit):
            widget.textChanged.connect(self._refresh)
        self._refresh()

    # ---- state ------------------------------------------------------------------

    def limits(self) -> rl.ResourceLimits:
        """What the dialog currently expresses."""
        cpus = self.cpu_spin.value()
        return rl.ResourceLimits(
            cpus=cpus if cpus > 0 else None,
            memory=self.mem_edit.text().strip() or None,
            gpus=self.gpu_edit.text().strip() or None,
        )

    def _apply_recommended(self) -> None:
        auto = rl.auto_limits()
        self.cpu_spin.setValue(auto.cpus or 0.0)
        self.mem_edit.setText(auto.memory or "")
        self.gpu_edit.setText(auto.gpus or "")

    def _refresh(self) -> None:
        limits = self.limits()
        self.effect.setText("\n".join(
            f"• {line}" for line in describe_effect(limits, service_count=self._service_count)))

        messages = rl.gpu_warnings(limits)
        self.warning.setText(" ".join(messages))
        self.warning.setVisible(bool(messages))

    def accept(self) -> None:
        rl.save(self.limits(), self._settings_path)
        super().accept()


def _env_pinned() -> list[str]:
    return [k for k in (rl.CPUS_ENV, rl.MEMORY_ENV, rl.GPUS_ENV)
            if (os.environ.get(k) or "").strip()]


def _stack_service_count(generator_dir: str) -> int:
    if not generator_dir:
        return 0
    compose = os.path.join(generator_dir, "tests", "stack", "compose.local.yaml")
    return len(sl.compose_services(compose))


def open_limits_dialog(parent=None, *, generator_dir: str = "") -> rl.ResourceLimits | None:
    """Show the dialog; returns the saved limits, or None if it was cancelled."""
    dlg = LimitsDialog(parent, generator_dir=generator_dir)
    if dlg.exec() == QtWidgets.QDialog.DialogCode.Accepted:
        return dlg.limits()
    return None


__all__ = ["LimitsDialog", "open_limits_dialog", "limits_summary", "describe_effect",
           "UNLIMITED_LABEL"]
