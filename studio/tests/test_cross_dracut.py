"""ASK 21's ARM cost — "root disk encryption should always be enabled" is not free on a
cross-built board, and the Studio must both KNOW that and SAY it.

The regression this pins: before it, a mesh worklist row like ``be.rpi5`` that built
fine without ``--encrypt-root`` started emitting it, and every ARM builder answers that
flag with ``BUILD_INSTALLER=true`` plus a fail-FAST cross-dracut preflight that
``exit 1``s before any work when qemu-aarch64 is not registered for binfmt. The wizard
changed what those builds produce AND whether they can start, and said neither.

Three layers, each with its own guard:

1. the FACTS (``core/cross_dracut.py``) are transcribed from the shell and re-read from
   it here, so the platform set and the two binfmt constants cannot drift;
2. the PREDICATE mirrors ``dracut_cross_preflight_ok`` arm for arm;
3. the three surfaces an operator passes through before a build starts — the Home step
   where the posture is stated, the Review summary, and the Launch screen where Continue
   actually dispatches — carry the cost, naming the affected rows, and ONLY when a row
   is affected.
"""
import os
import re
import stat
import subprocess

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import cross_dracut                    # noqa: E402
from hugmesh_studio.core.config import BUILDER_SCRIPTS, ImageConfig   # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo          # noqa: E402
from hugmesh_studio.core.worklist import WorklistEntry, resolve_encrypt_root  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod             # noqa: E402
from hugmesh_studio.gui.pages.launch import launch_summary      # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                     # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
DRACUT_LIB = os.path.join(GENERATOR_DIR, "scripts", "_dracut-cross-lib.sh")

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="module")
def qapp():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def mesh_flow(wiz, *ids):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *ids)
    return wl


# ══════════════════════════════════════════════════════════════════════════════════
# 1 — the facts, re-read from the shell
# ══════════════════════════════════════════════════════════════════════════════════

def test_binfmt_constants_match_the_shell_library():
    """The node path and the interpreter are the shell library's, not a guess."""
    src = open(DRACUT_LIB, encoding="utf-8").read()
    node = re.search(r'^DRACUT_CROSS_BINFMT_NODE="([^"]+)"', src, re.M)
    interp = re.search(r'^DRACUT_CROSS_QEMU_INTERP="([^"]+)"', src, re.M)
    assert node and interp, "the shell library no longer pins these — retranscribe"
    assert cross_dracut.BINFMT_NODE == node.group(1)
    assert cross_dracut.DEFAULT_INTERP == interp.group(1)


#: The flags of a plain ``--encrypt-root`` image build (installer / ISO medium, kernel
#: built, not --packages-only), as the builders spell them. A preflight gate is
#: evaluated against these, so it counts only if it fires on exactly such a build.
_ENCRYPT_ROOT_BUILD = {"ENCRYPT_ROOT": "true", "BUILD_INSTALLER": "true",
                       "BUILD_ISO": "true", "BUILD_LIVE": "false", "SKIP_KERNEL": "false",
                       "IMAGE_ONLY": "false", "PACKAGES_ONLY": "false"}


def _fail_fast_preflights(src: str) -> list:
    """The gates of the builder's fail-FAST preflights: every top-level
    ``if <gate>; then ... fi`` whose body holds ``if ! dracut_cross_preflight_ok; then``
    with ``exit 1`` directly in that branch (not under a further ``if``).

    The gate is whatever the builder chose. It used to be ``${ENCRYPT_ROOT} &&
    ${BUILD_...}`` on every ARM builder; frite's now fires on every real build
    (``! ${PACKAGES_ONLY}``: its sysroot is SELinux-labelled in the qemu chroot even
    without --encrypt-root). The waf-family block that follows it does not count: its
    preflight call is the top-level ``if`` itself and its ``exit 1`` sits under the
    blocker check, so a missing qemu there only WARNs for a waf-free package set."""
    gates = []
    for blk in re.finditer(r"^if ([^\n]+?); then\n(.*?)^fi$", src, re.M | re.S):
        inner = re.search(r"^(?P<ind>[ \t]+)if ! dracut_cross_preflight_ok; then\n"
                          r"(?P<branch>.*?)^(?P=ind)fi$", blk.group(2), re.M | re.S)
        if not inner:
            continue
        branch = [ln for ln in inner.group("branch").splitlines() if ln.strip()]
        level = re.match(r"[ \t]*", branch[0]).group(0) if branch else ""
        if any(ln == f"{level}exit 1" for ln in branch):
            gates.append(blk.group(1))
    return gates


def _gate_fires(gate: str) -> tuple:
    """(fired, stderr): run the gate in bash against :data:`_ENCRYPT_ROOT_BUILD` under
    ``set -u``, so a gate on a variable this table does not set fails loudly instead of
    reading as "does not fire"."""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **_ENCRYPT_ROOT_BUILD}
    proc = subprocess.run(
        ["bash", "-c", f"set -u; if {gate}; then echo FIRES; else echo QUIET; fi"],
        env=env, capture_output=True, text=True, timeout=10)
    return proc.stdout.strip() == "FIRES", proc.stderr.strip()


def test_every_cross_fde_platform_really_has_the_fail_fast_preflight():
    """CROSS_FDE_PLATFORMS is the set whose builder REFUSES on --encrypt-root without a
    usable qemu-aarch64. Read that claim off each builder rather than trusting the list:
    the builder has a gated block that calls ``dracut_cross_preflight_ok`` and
    ``exit 1``s when it fails, and that gate FIRES on a plain --encrypt-root build
    (bash evaluates it; the gate's wording is the builder's own)."""
    assert cross_dracut.CROSS_FDE_PLATFORMS, "the set went empty"
    assert "x86" not in cross_dracut.CROSS_FDE_PLATFORMS
    assert "jetson" not in cross_dracut.CROSS_FDE_PLATFORMS   # no FDE path at all
    for plat in cross_dracut.CROSS_FDE_PLATFORMS:
        path = os.path.join(GENERATOR_DIR, BUILDER_SCRIPTS[plat])
        src = open(path, encoding="utf-8").read()
        gates = _fail_fast_preflights(src)
        assert gates, (f"{plat}: no gated `if ! dracut_cross_preflight_ok; then ... exit 1` "
                       f"block in {path}")
        verdicts = [(gate, *_gate_fires(gate)) for gate in gates]
        assert any(fired for _g, fired, _e in verdicts), (
            f"{plat}: no fail-fast preflight fires on an --encrypt-root build: {verdicts}")


def test_the_preflight_reader_counts_only_a_gated_unconditional_refusal():
    """The reader above, on fixtures: the shape it must find (either gate the builders
    use), and the shapes it must NOT count: the waf-family block (its exit is under the
    blocker check), a preflight that only warns, and a gate that is never true on an
    --encrypt-root build."""
    refuse = ("    dracut_cross_register_qemu || true\n"
              "    if ! dracut_cross_preflight_ok; then\n"
              "        err \"no qemu\"\n"
              "        exit 1\n"
              "    fi\n")
    enc = "if ${ENCRYPT_ROOT} && ${BUILD_INSTALLER} && { ! ${SKIP_KERNEL} || ${IMAGE_ONLY}; }; then\n"
    assert _fail_fast_preflights(enc + refuse + "fi\n") == [enc[3:-7]]
    assert _gate_fires(enc[3:-7])[0]
    assert _fail_fast_preflights("if ! ${PACKAGES_ONLY}; then\n" + refuse + "fi\n") \
        == ["! ${PACKAGES_ONLY}"]
    assert _gate_fires("! ${PACKAGES_ONLY}")[0]
    waf = ("if ! dracut_cross_preflight_ok; then\n"
           "    if [ -n \"${_exec_blockers}\" ]; then\n"
           "        exit 1\n"
           "    fi\n"
           "    warn \"continuing\"\n"
           "fi\n")
    assert _fail_fast_preflights(waf) == []
    nested = enc + ("    if ! dracut_cross_preflight_ok; then\n"
                    "        if ${STRICT}; then\n"
                    "            exit 1\n"
                    "        fi\n"
                    "    fi\n") + "fi\n"
    assert _fail_fast_preflights(nested) == []
    warn_only = enc + refuse.replace("exit 1", "warn \"continuing\"") + "fi\n"
    assert _fail_fast_preflights(warn_only) == []
    assert not _gate_fires("${PACKAGES_ONLY}")[0]
    assert not _gate_fires("${ENCRYPT_ROOT} && ${SKIP_KERNEL}")[0]
    fired, err = _gate_fires("${NOT_A_BUILDER_FLAG}")
    assert not fired and "unbound" in err


def test_the_x86_builder_has_no_such_preflight():
    """The set must not be over-broad: x86 builds natively, so an encrypted x86 root
    never needs a cross interpreter and must never be warned about."""
    src = open(os.path.join(GENERATOR_DIR, BUILDER_SCRIPTS["x86"]), encoding="utf-8").read()
    assert "dracut_cross_preflight_ok" not in src


# ══════════════════════════════════════════════════════════════════════════════════
# 2 — the predicate, arm for arm with the shell
# ══════════════════════════════════════════════════════════════════════════════════

def _fake_node(tmp_path, interp_path):
    node = tmp_path / "qemu-aarch64"
    node.write_text("enabled\ninterpreter %s\nflags: OC\n" % interp_path)
    return str(node)


def test_preflight_is_false_without_a_registration(tmp_path):
    assert cross_dracut.preflight_ok(str(tmp_path / "absent")) is False


def test_preflight_is_false_when_the_interpreter_is_missing(tmp_path):
    """Registered but the interpreter path does not exist — the exact shape of a
    container whose image never shipped a static qemu."""
    node = _fake_node(tmp_path, str(tmp_path / "no-such-qemu"))
    assert cross_dracut.preflight_ok(node) is False


def test_preflight_is_false_when_the_interpreter_is_not_executable(tmp_path):
    interp = tmp_path / "qemu"
    interp.write_text("#!/bin/sh\n")
    interp.chmod(0o644)
    assert cross_dracut.preflight_ok(_fake_node(tmp_path, str(interp))) is False


def test_preflight_is_true_with_a_registered_executable_interpreter(tmp_path):
    interp = tmp_path / "qemu"
    interp.write_text("#!/bin/sh\n")
    interp.chmod(interp.stat().st_mode | stat.S_IXUSR)
    node = _fake_node(tmp_path, str(interp))
    assert cross_dracut.qemu_interp(node) == str(interp)
    assert cross_dracut.preflight_ok(node) is True


def test_qemu_interp_falls_back_to_the_pinned_default(tmp_path):
    """A node with no ^interpreter line (or no node at all) reports the pinned path,
    exactly as ``dracut_cross_qemu_interp`` does — never "" ."""
    node = tmp_path / "qemu-aarch64"
    node.write_text("enabled\nflags: OC\n")
    assert cross_dracut.qemu_interp(str(node)) == cross_dracut.DEFAULT_INTERP
    assert cross_dracut.qemu_interp(str(tmp_path / "absent")) == cross_dracut.DEFAULT_INTERP


# ══════════════════════════════════════════════════════════════════════════════════
# 3 — which rows are affected
# ══════════════════════════════════════════════════════════════════════════════════

def test_only_encrypted_cross_built_rows_are_named():
    rows = [("pki.x86", "x86", True),            # native — never affected
            ("backend.rpi5", "rpi5", True),           # the regression
            ("frontend.rpi5", "rpi5", False),          # row exempted in the worklist
            ("edge-ai.jetson", "jetson", True)]  # no FDE path at all
    assert cross_dracut.cross_fde_rows(rows) == ["backend.rpi5"]


def test_the_note_is_empty_when_nothing_is_affected():
    assert cross_dracut.cross_fde_note([], ready=False) == ""
    assert cross_dracut.cross_fde_note([], ready=True) == ""


def test_the_note_says_refuse_only_when_the_host_cannot_do_it():
    """The two arms must differ: on a host that cannot run the cross-dracut the operator
    is told the build will REFUSE and how to fix it; on one that can, it is told the
    preflight should pass. A note that read the same either way would be decoration."""
    bad = cross_dracut.cross_fde_note(["backend.rpi5"], ready=False)
    good = cross_dracut.cross_fde_note(["backend.rpi5"], ready=True)
    assert "REFUSE TO START" in bad and "REFUSE TO START" not in good
    assert "--privileged" in bad and "make docker-image" in bad
    assert "'off'" in bad                       # the worklist escape hatch
    assert "should pass" in good
    for note in (bad, good):
        assert "backend.rpi5" in note
        assert "installer artifact" in note     # the artifact set CHANGES
        assert "qemu-aarch64" in note


def test_resolve_encrypt_root_is_the_one_implementation():
    """The GUI asks the same function the driver's per-row resolution now delegates to,
    so a note can never disagree with the argv."""
    base = ImageConfig(mode="mesh", platform="x86", encrypt_root=True)
    from hugmesh_studio.core.worklist import WorklistConfig
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="backend", platform="rpi5"),
        WorklistEntry(role="frontend", platform="rpi5", encrypt_root="off"),
        WorklistEntry(role="edge-ai", platform="jetson"),
    ])
    for e in wl.entries:
        assert wl._resolve_encrypt_root(e) is resolve_encrypt_root(e, base.encrypt_root)


# ══════════════════════════════════════════════════════════════════════════════════
# 4 — the three surfaces, driven through the REAL wizard
# ══════════════════════════════════════════════════════════════════════════════════

def test_an_arm_mesh_row_states_the_cost_on_home_review_and_launch(wiz, monkeypatch):
    """The whole finding: the wizard now says, on every screen before dispatch, that
    these rows gained an installer artifact and a builder precondition."""
    monkeypatch.setattr(cross_dracut, "preflight_ok", lambda *a, **k: False)
    mesh_flow(wiz, "pki.x86", "backend.rpi5")
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.enc_cross_note.isVisible()
    assert "backend.rpi5" in home.enc_cross_note.text()
    assert "REFUSE TO START" in home.enc_cross_note.text()
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert "backend.rpi5" in build.review_summary()
    assert "REFUSE TO START" in build.review_summary()
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    assert "REFUSE TO START" in launch.summary.text()
    # and the row really is emitting the flag that costs this
    by_id = {e.id: cfg for e, cfg in build._materialized}
    assert "--encrypt-root" in by_id["backend.rpi5"].to_cli_args()


def test_an_all_x86_mesh_flow_is_not_warned(wiz, monkeypatch):
    """Not boilerplate: an x86-only worklist builds natively and must see none of it,
    on any of the three surfaces — even on a host with no qemu at all."""
    monkeypatch.setattr(cross_dracut, "preflight_ok", lambda *a, **k: False)
    mesh_flow(wiz, "pki.x86", "backend.x86")
    home = advance_to(wiz, wizard_mod.HomePage)
    assert not home.enc_cross_note.isVisible()
    assert home.enc_cross_note.text() == ""
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert "cross-built ARM" not in build.review_summary()
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    assert "cross-built ARM" not in launch.summary.text()


def test_a_row_exempted_in_the_worklist_drops_out_of_the_warning(wiz, monkeypatch):
    """The escape hatch the note points at actually works: setting the row's Encryption
    override to "off" removes both the flag and the warning."""
    monkeypatch.setattr(cross_dracut, "preflight_ok", lambda *a, **k: False)
    wl_page = mesh_flow(wiz, "pki.x86", "backend.rpi5")
    # the real control the note points at — the worklist row's Encryption column
    wl_page._enc_combos["backend.rpi5"].setCurrentText("off")
    build = advance_to(wiz, wizard_mod.BuildPage)
    by_id = {e.id: cfg for e, cfg in build._materialized}
    assert "--encrypt-root" not in by_id["backend.rpi5"].to_cli_args()
    assert "cross-built ARM" not in build.review_summary()


def test_a_single_image_arm_flow_is_warned_too(wiz, monkeypatch):
    """Not a mesh-only concern — ask 21 put the posture on the standalone path as well,
    so a single arm64 image built on its own carries the same cost."""
    monkeypatch.setattr(cross_dracut, "preflight_ok", lambda *a, **k: False)
    pick_mode(wiz, "standalone")
    role = advance_to(wiz, wizard_mod.RolePage)
    assert role.select_role("generic"), "the rpi5 standalone role is not offered"
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.enc_cross_note.isVisible()
    assert "REFUSE TO START" in home.enc_cross_note.text()
