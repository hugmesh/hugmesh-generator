"""The Resource limits setting must reach every lane the dialog says it reaches.

Found 2026-10-21: an operator saved a 2-CPU limit, started the mesh node from the
tray, and the node's container ran with NanoCpus=0 (no cap at all) while the dialog
promised the limit applied to "emulated meshes and Kubernetes nodes started from this
Studio" and printed "Emulated devices boot with 2 vCPUs each". Nothing read the
setting for the mesh node, for QEMU or for kind.

Two kinds of test here:
  * the mesh node now READS the setting: start() hands compose an overlay with the cap;
  * the dialog and the tray notice may only CLAIM a lane that has code reading the
    setting. A lane the text names as limited with no consumer turns these red.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess

import pytest

from hugmesh_studio.core import mesh_node, resource_limits as rl

STUDIO = pathlib.Path(__file__).resolve().parents[1]
PKG = STUDIO / "hugmesh_studio"
GENERATOR = STUDIO.parent


@pytest.fixture
def saved_limits(monkeypatch, tmp_path):
    """Point the saved-setting file at tmp and clear the env knobs, so the SAVED tray
    setting is what decides (the path an operator uses)."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    for k in (rl.CPUS_ENV, rl.MEMORY_ENV, rl.GPUS_ENV):
        monkeypatch.delenv(k, raising=False)

    def _save(limits):
        rl.save(limits)
        return limits
    return _save


def _start_recording(monkeypatch, tmp_path):
    """Run MeshNode.start() against a recorded `docker compose`; return (node, argvs)."""
    calls = []

    def fake_run(argv, **kw):
        calls.append(list(argv))
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(mesh_node, "_compose_base", lambda: ["docker", "compose"])
    monkeypatch.setattr(mesh_node.subprocess, "run", fake_run)
    monkeypatch.setenv("TS_AUTHKEY", "test-key-not-real")
    node = mesh_node.MeshNode(str(GENERATOR), workdir=str(tmp_path / "node"))
    ok, why = node.start()
    assert ok, why
    ups = [a for a in calls if a[-2:] == ["up", "-d"]]
    assert len(ups) == 1, calls
    return node, ups[0]


def _overlay_files(argv):
    return [argv[i + 1] for i, a in enumerate(argv) if a == "-f"]


# ── the mesh node reads the setting ───────────────────────────────────────────────
def test_tray_mesh_node_start_carries_the_saved_cpu_and_memory_cap(
        monkeypatch, tmp_path, saved_limits):
    saved_limits(rl.ResourceLimits(cpus=2.0, memory="1g"))
    node, up = _start_recording(monkeypatch, tmp_path)
    files = _overlay_files(up)
    overlay = os.path.join(node.workdir, mesh_node.LIMITS_OVERLAY)
    assert files[-1] == overlay, up
    body = pathlib.Path(overlay).read_text()
    assert "  tailscale:" in body
    assert "cpus: '2'" in body
    assert "memory: '1g'" in body
    assert "memswap_limit: '1g'" in body


def test_env_knob_beats_the_saved_setting_for_the_mesh_node(
        monkeypatch, tmp_path, saved_limits):
    saved_limits(rl.ResourceLimits(cpus=6.0))
    monkeypatch.setenv(rl.CPUS_ENV, "1.5")
    node, up = _start_recording(monkeypatch, tmp_path)
    body = pathlib.Path(_overlay_files(up)[-1]).read_text()
    assert "cpus: '1.5'" in body


def test_limits_off_keeps_the_mesh_node_argv_unchanged_and_removes_a_stale_overlay(
        monkeypatch, tmp_path, saved_limits):
    saved_limits(rl.ResourceLimits())            # explicit "no limits"
    stale = tmp_path / "node" / mesh_node.LIMITS_OVERLAY
    stale.parent.mkdir(parents=True)
    stale.write_text("services: {}\n")
    node, up = _start_recording(monkeypatch, tmp_path)
    assert not stale.exists()
    assert _overlay_files(up) == [os.path.join(node.workdir, "docker-compose.mesh.yml")]


def test_the_mesh_node_is_never_handed_a_gpu(monkeypatch, tmp_path, saved_limits):
    saved_limits(rl.ResourceLimits(cpus=2.0, gpus="all"))
    node, up = _start_recording(monkeypatch, tmp_path)
    assert _overlay_files(up)[-1].endswith(mesh_node.LIMITS_OVERLAY), up
    body = pathlib.Path(_overlay_files(up)[-1]).read_text()
    assert "cpus: '2'" in body
    assert "gpu" not in body.lower() and "devices" not in body


@pytest.mark.skipif(not mesh_node._compose_base(), reason="docker compose unavailable")
def test_compose_itself_reads_the_cap_from_the_overlay(tmp_path):
    """The overlay is not just text we wrote: compose resolves it onto the service."""
    node = mesh_node.MeshNode(str(GENERATOR), workdir=str(tmp_path))
    node._stage()
    (tmp_path / mesh_node.LIMITS_OVERLAY).write_text(
        mesh_node.render_limits_overlay(rl.ResourceLimits(cpus=2.0, memory="1g")))
    r = subprocess.run(node._compose("config", "--format", "json"), cwd=tmp_path,
                       env={**os.environ, "TS_AUTHKEY": "x"},
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    svc = json.loads(r.stdout)["services"]["tailscale"]
    assert float(svc["deploy"]["resources"]["limits"]["cpus"]) == 2.0
    assert int(svc["deploy"]["resources"]["limits"]["memory"]) == 1024 ** 3
    assert int(svc["memswap_limit"]) == 1024 ** 3


# ── the dialog only claims lanes that have a consumer ─────────────────────────────
def _modules_reading(pattern: str) -> list[str]:
    """Studio modules (other than the limits module and the dialog itself) whose code
    matches the regex ``pattern`` — i.e. the lane's consumer, if it has one. Comments and
    docstrings do not count: a docstring that says "docker update" is not a consumer."""
    found = []
    for path in PKG.rglob("*.py"):
        if path.name in ("resource_limits.py", "limits_dialog.py"):
            continue
        code = []
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            code.append(line)
        text = re.sub(r'"""[\s\S]*?"""', "", "\n".join(code))
        if re.search(pattern, text):
            found.append(str(path.relative_to(PKG)))
    return found


#: lane -> (words that name it in user-facing text, the code that would read the cap)
_UNWIRED_CANDIDATES = {
    "QEMU emulation": (("emulated", "qemu", "vcpu"), r"\bqemu_smp\("),
    # the designed delivery is `docker update --cpus` on the kind node container
    "kind / Kubernetes": (("kubernetes", "kind node", "kind)"),
                          r"""["']docker["']\s*,\s*["']update["']"""),
}


def _claims(sentence: str, words) -> bool:
    """A sentence CLAIMS a lane when it names it without saying it is not limited."""
    low = sentence.lower()
    return any(w in low for w in words) and " not " not in f" {low} "


def _sentences(text: str) -> list[str]:
    return [s for s in re.split(r"(?<=[.!?])\s+|\n", text) if s.strip()]


def _limits_dialog():
    """gui/limits_dialog imports Qt at module level (it is the dialog, not only its
    text), so these wording pins can run only where a binding is installed: the
    Studio venv and GitLab's PySide6 job, not the Qt-free pull-request job. A skip,
    not an error — the same rule every other GUI-reading test file states."""
    return pytest.importorskip("hugmesh_studio.gui.limits_dialog",
                               reason="no Qt binding (PySide6/PyQt6) installed")


def _user_facing_limits_text() -> list[str]:
    """Every sentence the tray + dialog show about where the limit applies."""
    limits_dialog = _limits_dialog()
    from hugmesh_studio.gui import tray
    lines = []
    lines += _sentences(limits_dialog.BLURB)
    lines += _sentences(tray.LIMITS_SAVED_NOTICE)
    for limits in (rl.ResourceLimits(cpus=1.0), rl.ResourceLimits(cpus=2.0, memory="4g"),
                   rl.ResourceLimits(cpus=2.0, gpus="all")):
        for line in limits_dialog.describe_effect(limits, service_count=43):
            lines += _sentences(line)
    return lines


@pytest.mark.parametrize("lane", sorted(_UNWIRED_CANDIDATES))
def test_dialog_never_claims_a_lane_that_has_no_consumer(lane):
    words, consumer = _UNWIRED_CANDIDATES[lane]
    claiming = [s for s in _user_facing_limits_text() if _claims(s, words)]
    if claiming:
        assert _modules_reading(consumer), (
            f"the limits text claims the {lane} lane is limited, but no Studio code "
            f"reads the setting for it ({consumer!r} is used nowhere): {claiming}")


def test_dialog_names_the_lanes_it_does_not_reach():
    limits_dialog = _limits_dialog()
    text = " ".join(limits_dialog.describe_effect(rl.ResourceLimits(cpus=2.0)))
    assert "emulated devices" in text.lower() and "kind" in text.lower()
    assert "not limited" in text.lower()


def test_dialog_states_the_mesh_node_cap():
    limits_dialog = _limits_dialog()
    lines = limits_dialog.describe_effect(rl.ResourceLimits(cpus=2.0, memory="1g"))
    assert any("mesh node" in l and "2 CPU" in l and "1g" in l for l in lines), lines


# ── the dialog shows it: rendered, not only computed ─────────────────────────────
def test_rendered_dialog_shows_the_honest_lane_list(saved_limits):
    """The operator once could not SEE a control green tests said existed: build the
    real dialog offscreen and check the paragraph and the effect list are on screen,
    readable, and say what the setting reaches and what it does not."""
    qt = pytest.importorskip("hugmesh_studio.gui.qt")
    QtWidgets = qt.QtWidgets
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["limits-test"])
    from hugmesh_studio.gui import limits_dialog
    saved_limits(rl.ResourceLimits(cpus=2.0, memory="1g"))
    dlg = limits_dialog.LimitsDialog(generator_dir=str(GENERATOR))
    try:
        dlg.resize(640, dlg.sizeHint().height())
        dlg.show()
        app.processEvents()
        labels = {lbl.text(): lbl for lbl in dlg.findChildren(QtWidgets.QLabel)}
        blurb = labels.get(limits_dialog.BLURB)
        assert blurb is not None, list(labels)
        for widget in (blurb, dlg.effect, dlg.cpu_spin):
            assert widget.isVisible() and widget.isEnabled()
            assert widget.width() >= 200 and widget.height() >= 16, widget.size()
        assert dlg.cpu_spin.value() == 2.0
        effect = dlg.effect.text()
        assert "mesh node started from the tray is capped at 2 CPU" in effect
        assert "Not limited by this setting yet" in effect
        assert "vCPU" not in effect
    finally:
        dlg.close()
        dlg.deleteLater()
