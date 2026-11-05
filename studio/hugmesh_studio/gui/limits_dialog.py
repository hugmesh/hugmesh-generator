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
import re
import threading

from .qt import Qt, QtCore, QtWidgets, Signal
from ..core import resource_limits as rl
from ..core import stack_limits as sl

#: Shown when the operator has picked "no limit" on the CPU slider.
UNLIMITED_LABEL = "No limit"

#: The dialog's opening paragraph. Every lane it names as LIMITED must have code that
#: reads the setting (tests/test_limits_reach_lanes.py checks that); lanes that do not
#: yet are named as such, so the operator is never told a cap exists that nothing applies.
BLURB = (
    "How much of this machine HugMesh may use while it runs in the background. "
    "These apply to image and fleet builds, the local Docker stack and the mesh node "
    "started from this tray. Emulated devices (QEMU) and Kubernetes (kind) nodes are "
    "not limited by this setting yet.")

#: The lanes the setting does NOT reach yet, stated in the per-lane effect list.
NOT_YET_LIMITED = ("Not limited by this setting yet: emulated devices (QEMU) and "
                   "Kubernetes (kind) nodes.")


#: Docker's smallest accepted ``--memory`` (the daemon refuses anything below 6 MiB).
_MIN_MEMORY_BYTES = 6 * 1024 ** 2

# The intersection of what docker (go-units RAMInBytes) and the compose overlay's
# stack_limits.parse_size both read: digits, an optional fraction, one optional unit
# letter. Docker alone would also take "16 GB", which parse_size cannot divide across
# services, so that spelling would silently drop the stack's memory cap.
_MEMORY_RE = re.compile(r"\d+(\.\d+)?[bkmgt]?", re.IGNORECASE)


def memory_error(text: str) -> str:
    """Why ``text`` cannot be saved as the memory limit, or "" when it can.

    The value is handed verbatim to ``docker run --memory`` and the compose overlay,
    so an unreadable one used to be saved without a word and every later build and
    stack start then failed on docker's "invalid size". Empty means no limit."""
    raw = text.strip()
    if not raw:
        return ""
    if not _MEMORY_RE.fullmatch(raw):
        # Not "Docker cannot read it": Docker also takes "16 GB" and "16GiB". The same
        # value feeds the mesh stack's compose overlay, which reads only the short form.
        return (f"Memory '{raw}' is not a size the Studio can apply to both Docker and "
                "the mesh stack: write a number with an optional single-letter unit "
                "and no space, e.g. 16g, 8192m or 1.5g, or leave it empty for no limit.")
    if (sl.parse_size(raw) or 0) < _MIN_MEMORY_BYTES:
        return (f"Memory '{raw}' is below Docker's 6 MiB minimum (a bare number is "
                "bytes): use e.g. 16g or 8192m, or leave it empty for no limit.")
    return ""


#: Shown on native Windows instead of the runtime probe's result. Docker Desktop
#: delivers ``--gpus`` through its WSL 2 engine without registering an "nvidia"
#: runtime, so the probe always said "no GPU runtime" and sent the user to the Linux
#: NVIDIA Container Toolkit, which Docker Desktop does not use.
WINDOWS_GPU_NOTE = (
    "On Windows, Docker Desktop gives a container a GPU only with its WSL 2 engine "
    "and an NVIDIA GPU on a current NVIDIA Windows driver; Docker cannot report this "
    "in advance, so a build asked for a GPU without one fails to start.")


def gpu_messages(limits: rl.ResourceLimits, runtime: bool | None,
                 osname: str | None = None) -> list[str]:
    """The GPU advisory for ``limits``. ``runtime`` is the probe's answer, None while
    it is still running (nothing is claimed yet). ``osname`` is ``os.name`` unless a
    test passes another."""
    if limits.gpus is None:
        return []
    if (osname or os.name) == "nt":
        return [WINDOWS_GPU_NOTE]
    if runtime is None:
        return []
    return rl.gpu_warnings(limits, probe=lambda: runtime)


class _GpuProbeBridge(QtCore.QObject):
    """Carries the off-thread GPU probe's answer back to the GUI thread (queued)."""
    done = Signal(bool)


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
        return ["Builds, the local stack and the mesh node run unbounded, "
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

    node = []
    if limits.cpus is not None:
        node.append(f"{limits.cpus:g} CPU")
    if limits.memory is not None:
        node.append(f"{limits.memory} of memory, no swap")
    if node:
        out.append("The mesh node started from the tray is capped at "
                   + " and ".join(node) + ".")

    if limits.gpus:
        out.append(f"Image and fleet builds are offered GPU: {limits.gpus}. "
                   "The mesh node is never given one.")
    else:
        out.append("No lane is given GPU access.")

    out.append(NOT_YET_LIMITED)
    return out


class LimitsDialog(QtWidgets.QDialog):
    """Collect a :class:`~hugmesh_studio.core.resource_limits.ResourceLimits`."""

    def __init__(self, parent=None, *, generator_dir: str = "",
                 settings_path: str | None = None, gpu_probe=None,
                 osname: str | None = None):
        super().__init__(parent)
        self.setWindowTitle("HugMesh — resource limits")
        self._settings_path = settings_path
        self._osname = osname
        # `docker info` takes seconds (8-20 s against a busy Docker Desktop) and its
        # answer cannot change while the dialog is open: ask once, off the GUI thread,
        # never per keystroke. None = not asked yet / still running.
        self._gpu_probe = gpu_probe or rl.gpu_runtime_available
        self._gpu_runtime: bool | None = None
        self._gpu_probe_started = False
        self._gpu_bridge = _GpuProbeBridge(self)
        self._gpu_bridge.done.connect(self._on_gpu_probed)
        self._service_count = _stack_service_count(generator_dir)
        self._cores = os.cpu_count() or 2

        current = rl.effective(path=settings_path)
        env_pinned = _env_pinned()

        layout = QtWidgets.QVBoxLayout(self)

        blurb = QtWidgets.QLabel(BLURB)
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

        # The memory refusal sits apart from the GPU advisory: this one blocks Save.
        self.mem_error = QtWidgets.QLabel()
        self.mem_error.setWordWrap(True)
        self.mem_error.setTextFormat(Qt.TextFormat.PlainText)
        self.mem_error.setStyleSheet("color: #c5221f;")
        self.mem_error.setVisible(False)
        layout.addWidget(self.mem_error)

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
        self._save_btn = buttons.button(QtWidgets.QDialogButtonBox.StandardButton.Save)
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
        err = memory_error(self.mem_edit.text())
        self.mem_error.setText(err)
        self.mem_error.setVisible(bool(err))
        self._save_btn.setEnabled(not err)
        if err:
            # describe_effect would echo the unreadable value back as a real cap.
            self.effect.setText("• The memory value has to be fixed before these "
                                "limits can be saved.")
        else:
            self.effect.setText("\n".join(
                f"• {line}"
                for line in describe_effect(limits, service_count=self._service_count)))

        if limits.gpus is not None and (self._osname or os.name) != "nt":
            self._start_gpu_probe()
        messages = gpu_messages(limits, self._gpu_runtime, self._osname)
        self.warning.setText(" ".join(messages))
        self.warning.setVisible(bool(messages))

    def _start_gpu_probe(self) -> None:
        if self._gpu_probe_started:
            return
        self._gpu_probe_started = True
        probe, bridge = self._gpu_probe, self._gpu_bridge

        def run() -> None:
            try:
                ok = bool(probe())
            except Exception:
                ok = False
            try:
                bridge.done.emit(ok)
            except RuntimeError:
                pass                    # the dialog (and its bridge) closed first

        # A daemon thread, not a QThread: a QThread still running when a cancelled
        # dialog is destroyed aborts the process; this one just finishes unheard.
        threading.Thread(target=run, name="limits-gpu-probe", daemon=True).start()

    def _on_gpu_probed(self, ok: bool) -> None:
        self._gpu_runtime = ok
        self._refresh()

    def accept(self) -> None:
        if memory_error(self.mem_edit.text()):
            return                      # Save is greyed; Enter must not save it either
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
           "UNLIMITED_LABEL", "BLURB", "NOT_YET_LIMITED"]
